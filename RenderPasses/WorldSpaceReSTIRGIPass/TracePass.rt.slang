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
import Params;
import LoadShadingData;
import PathTracer;


struct SampleInitializer
{
    Texture2D<PackedHitInfo> vbuffer;

    RWStructuredBuffer<InitialSample> initialSamples;
    RWStructuredBuffer<ReconnectionData> reconnectionDataBuffer;  /// store reconnection data used for multiple bounce resampling

    RWTexture2D<float3> outputColor;

    void TraceScatterRay(inout PathPayLoad pathState)
    {
        Ray ray = pathState.GenerateScatterRay();
        TraceRay(gScene.rtAccel, RAY_FLAG_NONE, 0xff, 0, rayTypeCount, 0, ray.toRayDesc(), pathState);
    };

    void TracePass(uint2 pixel,out InitialSample sample)
    {
        sample = {};
        HitInfo hit = HitInfo(vbuffer[pixel]);

        float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel,pathtracer.params.frameDim).dir;
        float3 vColor = 0.f;

        if(hit.isValid())
        {
            const float lod = 0.f;
            ShadingData sd = LoadShadingData(hit,primaryRayDir,lod,true);

            SampleGenerator sg = SampleGenerator(pixel, pathtracer.params.frameCount * pathtracer.params.numGIInstance + pathtracer.params.currentGIInstance);

            PathPayLoad pathState = PathPayLoad(sg);
            pathState.direction = primaryRayDir;
            pathState.pdf = 1;

            pathtracer.HandleHit(pathState,hit);

            float3 thp = pathState.thp;

            sample.preRcVertexPos = sd.posW;
            sample.preRcVertexNorm = pathState.norm;

            pathState.thp = 1.f;
            pathState.pdf = 1.f;
            pathState.radiance = 0.f;

            while(!pathState.isTerminated)
            {
                TraceScatterRay(pathState);
                if(pathState.currentVertexIndex == 2u)
                {
                    sample.rcVertexPos = pathState.origin;
                    sample.rcVertexNorm = pathState.norm;
                }
            }

            sample.rcVertexLo += pathState.radiance;

            vColor += pathState.lForDelta * thp;
            float3 wo = normalize(sample.rcVertexPos - sample.preRcVertexPos);
            float3 testColor = 0.5f * wo + 0.5f;
            sample.pdf = evalPdfBSDF(sd, wo);
            //float invPdf = evalPdfBSDF(sd, wo) > 0.f ? 1.f / evalPdfBSDF(sd, wo) : 0.f;
            //vColor += evalBSDFCosine(sd, wo) * ss.rcVertexLo * invPdf;
            //sample.vColor += sample.sColor * thp;
            if (pathtracer.params.currentGIInstance == 0)
                outputColor[pixel] = vColor / pathtracer.params.numGIInstance;
            else
                outputColor[pixel] += vColor / pathtracer.params.numGIInstance;
        }
        else
        {
            float3 color = pathtracer.GetBackGroundColor(primaryRayDir);
            if (pathtracer.params.currentGIInstance == 0)
                outputColor[pixel] = color/ pathtracer.params.numGIInstance;
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

    pathState.currentVertexIndex++;
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
    pathState.currentVertexIndex++;
    pathtracer.HandleHit(pathState,hit);  
}

[shader("raygeneration")]
void RayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    InitialSample sample;
    sampleInitializer.TracePass(pixel,sample);
    uint linearIdx = pixel.y * pathtracer.params.frameDim.x + pixel.x;
    sampleInitializer.initialSamples[linearIdx] = sample;
}
