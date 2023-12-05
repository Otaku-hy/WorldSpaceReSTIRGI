#include "Scene/ScenePrimitiveDefines.slangh"
#include "Scene/Material/MaterialDefines.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Scene.RaytracingInline;
import Scene.Shading;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Materials.MaterialShading;
import Experimental.WorldSpaceReSTIRGI.InitialSamples;
import Experimental.WorldSpaceReSTIRGI.ReconnectionData;

//import PathState;
import Params;
import LoadShadingData;
import PathTracer;


struct SampleInitializer
{
    Texture2D<PackedHitInfo> vbuffer;

    RWStructuredBuffer<InitialSample> initialSamples;
    RWStructuredBuffer<ReconnectionData> reconnectionDataBuffer;  /// store reconnection data used for multiple bounce resampling

    RWTexture2D<float3> outputColor;

    float roughnessThreshold;

    void TraceScatterRay(inout PathPayLoad pathState)
    {
        Ray ray = pathState.GenerateScatterRay();
 
        TraceRay(gScene.rtAccel, RAY_FLAG_NONE, 0xff, 0, rayTypeCount, 0, ray.toRayDesc(), pathState);
    };

    void TracePass(uint2 pixel,out InitialSample sample,out ReconnectionData rcData)
    {
        sample = {};
        rcData = {};
        HitInfo hit = HitInfo(vbuffer[pixel]);

        float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel,pathtracer.params.frameDim).dir;
        float3 vColor = 0.f;

        if(hit.isValid())
        {
            PathPayLoad pathState = { };
            pathtracer.GeneratePathState(pixel, pathState);

            pathState.direction = primaryRayDir;
            pathState.pdf = 1;

            pathtracer.HandleHit(pathState,hit);

            while (pathState.IsActive())
            {
                TraceScatterRay(pathState);
            }

            const float lod = 0.f;
            HitInfo preRcHitInfo = HitInfo(pathState.preRcVertexHit);
            if (preRcHitInfo.isValid())
            {
                ShadingData sd = LoadShadingData(preRcHitInfo, pathState.preRcVertexWo, lod, true);

                sample.preRcVertexPos = sd.posW;
                sample.preRcVertexNorm = sd.N;

                sample.rcVertexLo = pathState.rcVertexRadiance;

                sample.rcVertexPos = pathState.rcVertexPos;
                sample.rcVertexNorm = pathState.rcVertexNorm;

                float3 wo = normalize(sample.rcVertexPos - sample.preRcVertexPos);

                uint sampleFlag = -1;
                if (pathState.rcVertexLength == 2 && sd.linearRoughness < roughnessThreshold)
                {
                    
                   // sampleFlag = uint(SampledBSDFFlags::DiffuseReflection);
                    //sample.pdf = evalPdfBSDF(sd, wo, sampleFlag);
                    sd.setActiveLobes((uint) LobeType::Diffuse);
                }
                sample.pdf = evalPdfBSDF(sd, wo, sampleFlag);
            }

            rcData.preRcVertexHitInfo = pathState.preRcVertexHit;
            rcData.pathPreThp = pathState.prefixThp;
            rcData.pathPreRadiance = pathState.prefixPathRadiance;
            rcData.preRcVertexWo = pathState.preRcVertexWo;
            rcData.pathLength = pathState.rcVertexLength - 1;
            //float invPdf = evalPdfBSDF(sd, wo) > 0.f ? 1.f / evalPdfBSDF(sd, wo) : 0.f;
            //vColor += evalBSDFCosine(sd, wo) * ss.rcVertexLo * invPdf;
            //sample.vColor += sample.sColor * thp;
            vColor += pathState.LoForDelta;
            if (pathtracer.params.currentGIInstance == 0)
                outputColor[pixel] = vColor / pathtracer.params.numGIInstance;
            else
                outputColor[pixel] += vColor / pathtracer.params.numGIInstance;
            
        }
        else
        {
            float3 color = pathtracer.GetBackGroundColor(primaryRayDir);
            if (pathtracer.params.currentGIInstance == 0)
                outputColor[pixel] = color / pathtracer.params.numGIInstance;
            else
                outputColor[pixel] += color / pathtracer.params.numGIInstance;
        }

    }

};

ParameterBlock<SampleInitializer> sampleInitializer;

[shader("miss")]
void ScatterMiss(inout PathPayLoad pathState)
{
    pathtracer.HandleMiss(pathState);
}

[shader("anyhit")]
void ScatterTriangleAnyHit(inout PathPayLoad pathState, BuiltInTriangleIntersectionAttributes attribs)
{
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (alphaTest(v, gScene.materials[materialID], gScene.materialResources[materialID], 0.f))
        IgnoreHit();
}

[shader("closesthit")]
void ScatterTriangleClosestHit(inout PathPayLoad pathState,BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit thit;
    thit.instanceID = getGeometryInstanceID();
    thit.primitiveIndex = PrimitiveIndex();
    thit.barycentrics = attribs.barycentrics;
    HitInfo hit = HitInfo(thit);

    
    pathtracer.HandleHit(pathState,hit);   
}

[shader("intersection")]
void DisplacedTriangleMeshIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    DisplacedTriangleMeshIntersector::Attribs attribs;
    float t;
    if (DisplacedTriangleMeshIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), attribs, t))
    {
        ReportHit(t, 0, attribs);
    }
}

[shader("closesthit")]
void ScatterDisplacedTriangleMeshClosestHit(inout PathPayLoad pathState, DisplacedTriangleMeshIntersector::Attribs attribs)
{
    DisplacedTriangleHit displacedTriangleHit;
    displacedTriangleHit.instanceID = getGeometryInstanceID();
    displacedTriangleHit.primitiveIndex = PrimitiveIndex();
    displacedTriangleHit.barycentrics = attribs.barycentrics;
    displacedTriangleHit.displacement = attribs.displacement;

    HitInfo hit = HitInfo(displacedTriangleHit);
    pathtracer.HandleHit(pathState,hit);  
}

[shader("raygeneration")]
void RayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    InitialSample sample;
    ReconnectionData rcData;
    sampleInitializer.TracePass(pixel,sample,rcData);
    uint linearIdx = pixel.y * pathtracer.params.frameDim.x + pixel.x;
    sampleInitializer.initialSamples[linearIdx] = sample;
    sampleInitializer.reconnectionDataBuffer[linearIdx] = rcData;
}
