import Scene.shading;
import Scene.Scene;
import Scene.Raytracing;
import Scene.Intersection;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Materials.MaterialShading;
import Rendering.Materials.StandardMaterial;
import GIReservoir;
import Params;
import LoadShadingData;
import HashBuildStructure;
import ReconnectionData;


struct ResampleManager
{
    static const float largeFloat = 1e20f;

    static const float roughnessThreshold = GI_ROUGHNESS_THRESHOLD;
    static const uint targetPdfMode = GI_TARGET_PDF;

    Texture2D<float> depth;
    Texture2D<float3> norm;

    Texture2D<PackedHitInfo> vbuffer;

    StructuredBuffer<ReconnectionData> reconnectionDataBuffer;

    StructuredBuffer<Reservoir> preReservoirs;
    RWStructuredBuffer<Reservoir> initialReservoirs;
    RWStructuredBuffer<Reservoir> currentReservoirs;

    StructuredBuffer<uint> cellStorage;
    ByteAddressBuffer indexBuffer;
    ByteAddressBuffer checkSum;
    ByteAddressBuffer cellCounters;

    uint numInstance;
    
    float depthThreshold = 0.01f;
    float normalThreshold = 0.8f;

    float4x4 prevViewProj;
    float3 cameraPrePos;

    GIParameter params;


    uint ToLinearIndex(uint2 pixel)
    {
        return pixel.y * params.frameDim.x + pixel.x;
    }

    bool IgnoreReSTIRGI(ShadingData sd)
    {
        float diffuseComponent = Luminance(sd.diffuse);
        float specularWeight = Luminance(sd.specular);

        float specularComponent = specularWeight * specularWeight / (4 * sd.linearRoughness * sd.linearRoughness);
        float totalWeight = diffuseComponent + specularComponent;
        return diffuseComponent < roughnessThreshold * totalWeight;
    }

    float EvalTargetPdf(float3 Li, float3 vPos, float3 sPos, ShadingData sd)
    {
        if (targetPdfMode == 1)
        {
            float3 dir = normalize(sPos - vPos);
            float3 radiance = max(0.1f, evalBSDFCosine(sd, dir)) * Li;
            return Luminance(radiance);
        }
        else
        {
            return Luminance(Li);
        }
    }

    bool CompareSimilarity(uint2 this, uint2 neighbor)
    {
        if (abs(depth[this] - depth[neighbor]) > depthThreshold * depth[this])
            return false;
        if (dot(norm[this], norm[neighbor]) < normalThreshold)
            return false;
        return true;
    }

    bool TraceVisibilityRay(float3 origin, float3 dst)
    {

        float3 dir = normalize(dst - origin);
        Ray ray = Ray(origin, dir, 0.001, 0.999 * length(dst - origin));
        SceneRayQuery < 1 > sceneQuery;
        bool V = sceneQuery.traceVisibilityRay(ray.toRayDesc(), RAY_FLAG_NONE, 0xff);
        return V;
    }
 
    void execute(uint2 pixel)
    {
        // get shadingdata
        uint currentIDx = ToLinearIndex(pixel);
        ReconnectionData rcData = reconnectionDataBuffer[currentIDx];
        HitInfo hit = HitInfo(rcData.preRcVertexHitInfo);
        if (!hit.isValid())
            return;

        float lod = 0.f;
        bool adjustShadingNormal = rcData.pathLength <= 1 ? true : false;
        ShadingData sd = LoadShadingData(hit, rcData.preRcVertexWo, lod, adjustShadingNormal);
        ShadingData sd1 = LoadShadingData(HitInfo(vbuffer[pixel]), float3(0, 1, 0), lod, true);
        SampleGenerator sg = SampleGenerator(pixel, params.frameCount * numInstance + params.instanceID);

        // get sample
        Reservoir initialSample = initialReservoirs[currentIDx];
        if ( /*IgnoreReSTIRGI(sd) */sd.linearRoughness < roughnessThreshold && false)
        {
            SetReservoirs(currentReservoirs, currentIDx, 0, params.frameDim.x * params.frameDim.y, initialSample);
            SetReservoirs(currentReservoirs, currentIDx, 1, params.frameDim.x * params.frameDim.y, initialSample);
            return;
        }

        //get pre sample
        float4 preClip = mul(float4(sd1.posW, 1.f), prevViewProj);
        float3 preScreen = preClip.xyz / preClip.w;
        float2 preUV = preScreen.xy * float2(0.5f, -0.5f) + 0.5f;
        uint2 preID = clamp(preUV * params.frameDim, 0, params.frameDim - 1);
        uint preIDx = ToLinearIndex(preID);

        bool isPreValid = params.frameCount > 0 && all(preUV > 0.f) && all(preUV < 1.f);
        Reservoir temporalReservoir = GetReservoirs(preReservoirs, preIDx, 0, params.frameDim.x * params.frameDim.y);

        if (isPreValid)
        {
            isPreValid &= length(temporalReservoir.vPos - sd.posW) < 0.1f && dot(temporalReservoir.vNorm, sd.N) > 0.8f;
            float viewDepth = length(sd.posW - gScene.camera.data.posW);
            float prevViewDepth = length(sd.posW - cameraPrePos);
            float rand = sampleNext1D(sg);
            if (viewDepth / prevViewDepth < 0.98f && rand < 0.15f)
                isPreValid = false;
        }

        //temporal reuse
        temporalReservoir.M = clamp(temporalReservoir.M, 0, 30);
        if (!isPreValid || temporalReservoir.age > 100)
        {
            temporalReservoir.M = 0;
        }

        float tp = EvalTargetPdf(temporalReservoir.radiance, initialSample.vPos, temporalReservoir.sPos, sd);
        float wSum = temporalReservoir.M * tp * max(0.f, temporalReservoir.weightF);

        float tpCurrent = EvalTargetPdf(initialSample.radiance, initialSample.vPos, initialSample.sPos, sd);
        temporalReservoir.Merge(sg, initialSample, tpCurrent, wSum);
       
        float tpNew = EvalTargetPdf(temporalReservoir.radiance, initialSample.vPos, temporalReservoir.sPos, sd);
        temporalReservoir.ComputeFinalWeight(tpNew, wSum);
        temporalReservoir.M = clamp(temporalReservoir.M, 0, 30);
        temporalReservoir.age++;
 
        temporalReservoir.vPos = initialSample.vPos;
        temporalReservoir.vNorm = initialSample.vNorm;
        SetReservoirs(currentReservoirs, currentIDx, 0, params.frameDim.x * params.frameDim.y, temporalReservoir);
        //SetReservoirs(currentReservoirs, currentIDx, 1, params.frameDim.x * params.frameDim.y, temporalReservoir);
        //return;

        //spatial Reuse
        Reservoir spatialReservoir = GetReservoirs(preReservoirs, preIDx, 0, params.frameDim.x * params.frameDim.y);
        
        spatialReservoir.vPos = sd.posW;
        spatialReservoir.vNorm = sd.N;

        float cellSize = CalculateCellSize(sd.posW, gScene.camera.data.posW, params);
        float3 jitteredPos = sd.posW + (sampleNext3D(sg) * 2.0f - 1.0f) * 0.1f * cellSize;
        //cellSize = CalculateCellSize(jitteredPos, gScene.camera.data.posW, params);

        int cellIdx = FindCell(jitteredPos, sd.N, cellSize, params, checkSum);
        if (cellIdx == -1)
        {
           // spatialReservoir.radiance = float3(10, 0, 10);
            SetReservoirs(currentReservoirs, currentIDx, 1, params.frameDim.x * params.frameDim.y, spatialReservoir);
            return;
        }
        uint cellBaseIdx = indexBuffer.Load(cellIdx);
        uint sampleCount = cellCounters.Load(cellIdx);

        spatialReservoir.M = clamp(spatialReservoir.M, 0, 100);
        if ( spatialReservoir.age > 100)
        {
            spatialReservoir.M = 0;
        }

        uint maxSpatialIteration = 3u; //spatialReservoir.M > 10 ? 3u : 10u;
    
        uint increment = (sampleCount + maxSpatialIteration - 1) / maxSpatialIteration;
        uint offset = round(sampleNext1D(sg) * (increment - 1));

        float3 positionList[10];
        float3 normalList[10];
        int MList[10];
        uint nReuse = 0;
        positionList[nReuse] = sd.posW;
        normalList[nReuse] = sd.N;
        MList[nReuse] = spatialReservoir.M;
        nReuse++;

        float wSumS = spatialReservoir.M * EvalTargetPdf(spatialReservoir.radiance, spatialReservoir.vPos, spatialReservoir.sPos, sd) * max(0.f, spatialReservoir.weightF);

        uint reuseID = 0;
        int count = 0;
        
        for (uint i = 0; i < sampleCount; i+= increment)
        {
            count++;
            /*float2 offset = sampleNext2D(sg) * 2.f - 1.f;
            offset *= 100u;
            int2 neighbor = preID + offset;

            uint2 neighborPixel = clamp(neighbor, 0, params.frameDim.xy - 1);
            uint neighborPixelIndex = ToLinearIndex(neighborPixel); 
            if (!CompareSimilarity(pixel, neighborPixel))
                continue;*/

            uint neighborPixelIndex = cellStorage[cellBaseIdx + (offset + i)%sampleCount];
            Reservoir neighborReservoir = GetReservoirs(preReservoirs, neighborPixelIndex, (count + 1)%2, params.frameDim.x * params.frameDim.y);

            if (neighborReservoir.M <= 0 || dot(spatialReservoir.vNorm, neighborReservoir.vNorm) < normalThreshold)
            {
                continue;
            }

            float targetPdf = EvalTargetPdf(neighborReservoir.radiance, spatialReservoir.vPos, neighborReservoir.sPos, sd);

            float3 offsetB = neighborReservoir.sPos - neighborReservoir.vPos;
            float3 offsetA = neighborReservoir.sPos - spatialReservoir.vPos;
                // Discard back-face.
            if (dot(spatialReservoir.vNorm, offsetA) <= 0.f)
            {
                targetPdf = 0.f;
            }

            float RB2 = dot(offsetB, offsetB);
            float RA2 = dot(offsetA, offsetA);
            offsetB = normalize(offsetB);
            offsetA = normalize(offsetA);
            float cosA = dot(spatialReservoir.vNorm, offsetA);
            float cosB = dot(neighborReservoir.vNorm, offsetB);
            float cosPhiA = -dot(offsetA, neighborReservoir.sNorm);
            float cosPhiB = -dot(offsetB, neighborReservoir.sNorm);
            if (cosB <= 0.f || cosPhiB <= 0.f)
            {  
                continue;
            }
            if (cosA <= 0.f || cosPhiA <= 0.f || RA2 <= 0.f || RB2 <= 0.f)
            {
                targetPdf = 0.f;
            }
            float jacobi = RA2 *  cosPhiB <= 0.f ? 0.f : clamp(RB2 * cosPhiA / (RA2 * cosPhiB), 0.f, 10.f);

            targetPdf *= jacobi;
            bool V = TraceVisibilityRay(computeRayOrigin(spatialReservoir.vPos, spatialReservoir.vNorm), neighborReservoir.sPos);
            if (!V)
            {
                targetPdf = 0.f;
            }
            //targetPdf *= dot(spatialReservoir.vNorm, neighborReservoir.vNorm);
            bool updated = spatialReservoir.Merge(sg, neighborReservoir, targetPdf, wSumS);
            if (updated)
                reuseID = count;

            positionList[nReuse] = neighborReservoir.vPos;
            normalList[nReuse] = neighborReservoir.vNorm;
            MList[nReuse] = neighborReservoir.M;
            nReuse++;
        }

        float z = 0;
        float chosenWeight = 0.f;
        float totalWeight = 0.f;

        for (uint i = 0; i < nReuse; i++)
        {
            bool shouldTest = true;
            bool isVisible = true;
            float3 dir = spatialReservoir.sPos - positionList[i];
            if (dot(dir, normalList[i]) < 0.f)
            {
                shouldTest = false;
                isVisible = false;
            }
            if (shouldTest)
            {
                isVisible = TraceVisibilityRay(computeRayOrigin(positionList[i], normalList[i]), spatialReservoir.sPos);
            }
            if (isVisible)
            {
                 //float misWeight = saturate(dot(normalList[i], normalize(dir))) * Luminance(spatialReservoir.radiance);
                //totalWeight += misWeight * MList[i];
                //if (reuseID == i)
                //    chosenWeight = misWeight;
                z += MList[i];
            }
            else if (i == 0)
                break;
        }

        //z = totalWeight <= 0.f ? 0.f : chosenWeight / totalWeight;

        float tpNewS = EvalTargetPdf(spatialReservoir.radiance, spatialReservoir.vPos, spatialReservoir.sPos, sd); /* dot(normalList[reuseID], spatialReservoir.vNorm);*/
        float weight = tpNewS * z;
        //float weight = tpNewS * spatialReservoir.M;
        float avgWeight = weight > 0.f ? wSumS / weight: 0.f;
        spatialReservoir.M = clamp(spatialReservoir.M, 0, 100);
        spatialReservoir.weightF = clamp(avgWeight, 0.f, 10.f);
        spatialReservoir.age++;

        //float3 color = float3(sin(cellIdx), cos(cellIdx), cos(cellIdx * 2.7445f + 1.4212f));
        //float3 color = float3(sin(sampleCount), cos(sampleCount), cos(sampleCount * 2.7445f + 1.4212f));
        //spatialReservoir.radiance = count * 0.33;
        //spatialReservoir.weightF = 1.0f;

        SetReservoirs(currentReservoirs, currentIDx, 1, params.frameDim.x * params.frameDim.y, spatialReservoir);
    }
    

}

ParameterBlock<ResampleManager> resampleManager;

[numthreads(16,16,1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    resampleManager.execute(dispatchThreadId.xy);
    //resampleManager.TemporalResample(dispatchThreadId.xy);

}
