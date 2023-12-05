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
import Experimental.WorldSpaceReSTIRGI.ReconnectionData;
import Params;
import LoadShadingData;
import PathTracer;

struct FinalShading
{
    Texture2D<PackedHitInfo> vbuffer;
    StructuredBuffer<FinalSample> finalSample;
    StructuredBuffer<ReconnectionData> reconnectionDataBuffer;

    RWTexture2D<float3> outputColor;

    PTRuntimeParams params;

    void execute(uint2 pixel)
    {
        uint linearID = pixel.y * params.frameDim.x + pixel.x;
        ReconnectionData data = reconnectionDataBuffer[linearID];

        HitInfo hit = HitInfo(data.preRcVertexHitInfo);
        if (!hit.isValid())
            return;
        float flag = 1.f;
        float lod = 0.f;
        bool adjustShadingNormal = data.pathLength <= 1 ? true : false;
        ShadingData sd = LoadShadingData(hit, data.preRcVertexWo, lod, adjustShadingNormal);
                 
       
        FinalSample sample = finalSample[linearID];
        if (sd.linearRoughness < 0.2 && data.pathLength == 1)
        {
            
            //sample.Li = 0.f;
            //flag = sd.p
            FalcorBSDF bsdf;
            bsdf.setup(sd);
            flag = bsdf.pDiffuseReflection;
            sd.setActiveLobes((uint) LobeType::Diffuse);
        }

        outputColor[pixel] += (data.pathPreRadiance + data.pathPreThp * evalBSDFCosine(sd, sample.dir) * sample.Li /flag ) / params.numGIInstance;
        //outputColor[pixel] = sample.Li;
        //outputColor[pixel] += sample.Li;

    }
};

ParameterBlock<FinalShading> finalShading;

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    finalShading.execute(dispatchThreadId.xy);
}
