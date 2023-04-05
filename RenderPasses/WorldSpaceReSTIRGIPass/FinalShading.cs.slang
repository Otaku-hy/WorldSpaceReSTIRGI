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
import Experimental.WorldSpaceReSTIRGI.GIFinalSample;
import Params;
import LoadShadingData;
import PathTracer;

struct FinalShading
{
    Texture2D<PackedHitInfo> vbuffer;
    StructuredBuffer<FinalSample> finalSample;

    RWTexture2D<float3> outputColor;

    PTRuntimeParams params;

    void execute(uint2 pixel)
    {
        HitInfo hit = HitInfo(vbuffer[pixel]);
        if (!hit.isValid())
            return;

        float lod = 0.f;
        float3 rayDir = gScene.camera.computeRayPinhole(pixel, params.frameDim).dir;
        ShadingData sd = LoadShadingData(hit, rayDir, lod, true);

        uint linearID = pixel.y * params.frameDim.x + pixel.x;
        FinalSample sample = finalSample[linearID];

        if (params.currentGIInstance == 0)
            outputColor[pixel] += evalBSDFCosine(sd, sample.dir) * sample.Li / params.numGIInstance;
        else
            outputColor[pixel] += evalBSDFCosine(sd, sample.dir) * sample.Li / params.numGIInstance;
        
        //outputColor[pixel] += sample.Li;

    }
};

ParameterBlock<FinalShading> finalShading;

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    finalShading.execute(dispatchThreadId.xy);
}
