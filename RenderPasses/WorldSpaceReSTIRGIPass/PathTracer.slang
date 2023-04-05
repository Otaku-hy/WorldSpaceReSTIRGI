#include "Scene/ScenePrimitiveDefines.slangh"
#include "Scene/Material/MaterialDefines.slangh"

import Scene.shading;
import Scene.Raytracing;
import Scene.Intersection;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Materials.MaterialShading;
import Params;
import LoadShadingData;

__exported import PathState;
__exported import Experimental.WorldSpaceReSTIRGI.ReconnectionData;


static const float kRayTMax = 1e20f;

struct PathTracer
{
    static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
    static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
    static const bool kUseEnvLight = USE_ENV_LIGHT;

    static const bool kUsedReSTIRDI = USE_RESTIRDI;
    static const bool kUsedNEE = USE_NEE;
    static const bool kUsedMIS = USE_MIS;
    static const uint kMaxBounces = MAX_GI_BOUNCE;

    EnvMapSampler envMapSampler;            
    EmissiveLightSampler emissiveSampler;

    PTRuntimeParams params;

    enum class LightType
    {
        EnvMap,
        Emissive,
        Analytic
    };

    struct LightSample
    {
        float3 Li;
        float pdf;
        float3 origin;
        float distance;
        float3 dir;

        uint lightType;

        Ray GetVisibilityRay()
        {
            return Ray(origin,dir,0,distance);
        }
    };

    struct PathVertex
    {
        float3 pos;
        float3 normal;
        float3 faceNormal;

        __init(float3 pos,float3 normal,float3 faceNormal)
        {
            this.pos = pos;
            this.normal = normal;
            this.faceNormal = faceNormal;
        }

        float3 GetRayOrigin(float3 rayDir)
        {
            return computeRayOrigin(pos,dot(faceNormal,rayDir) >=0 ? faceNormal : -faceNormal);
        }
    };

    bool TraceVisibilityRay(const Ray ray)
    {
        SceneRayQuery<1> sceneRayQuery;
        return sceneRayQuery.traceVisibilityRay(ray.toRayDesc(), RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff);

    }

    float3 GetBackGroundColor(float3 dir)
    {
        float3 color = {};
        if(kUseEnvLight) color = gScene.envMap.eval(dir);
        return color;
    }

    bool HasFinishedScatter(PathPayLoad pathState)
    {
        return pathState.currentVertexIndex-1 >= kMaxBounces;
    }

    void AddToPathContribution(inout PathPayLoad pathState,float3 radiance)
    {
        pathState.radiance += pathState.thp * radiance;
    }

    float EvalMisWeight(int count0,float pdf0,int count1,float pdf1)
    {
        float w0 = count0 * pdf0;
        float w1 = count1 * pdf1;

        return w0 / (w0 + w1);
    }

    void GetLightProbabilities(out float p[3])
    {
        p[0] = kUseEnvLight ? 1.f: 0;
        p[1] = kUseEmissiveLights ? 1.f : 0;
        p[2] = kUseAnalyticLights ? 1.f : 0;
        
        float sum = p[0] + p[1] + p[2];
        if (sum == 0.f) return;

        float invsum = 1.f / sum;
        p[0] *= invsum;
        p[1] *= invsum;
        p[2] *= invsum;
    }

    float GetEnvLightProbabilities() {float p[3]; GetLightProbabilities(p); return p[0];}
    float GetEmissiveLightProbabilities() {float p[3]; GetLightProbabilities(p); return p[1];}
    float GetAnalyticLightProbabilities() {float p[3]; GetLightProbabilities(p); return p[2];}
    
    bool SelectLightType(out uint lightType, out float pdf,inout SampleGenerator sg)
    {
        float p[3];
        GetLightProbabilities(p);

        float u = sampleNext1D(sg);

        for(lightType=0;lightType<3;lightType++)
        {
            if(u < p[lightType])
            {
                pdf = p[lightType];
                return true;
            }
            u -= p[lightType];
        }
        return false;
    }

    bool GenerateEnvLightSample(PathVertex vertex,inout SampleGenerator sg,out LightSample ls)
    {
        ls = {};
        if(!kUseEnvLight) return false;
        EnvMapSample lightSample;
        if(!envMapSampler.sample(sampleNext2D(sg),lightSample)) return false;
        
        ls.Li = lightSample.pdf > 0.f ? lightSample.Le / lightSample.pdf : float3(0);
        ls.pdf = lightSample.pdf;
        ls.origin = vertex.GetRayOrigin(lightSample.dir);
        ls.distance = kRayTMax;
        ls.dir = lightSample.dir;

        return any(ls.Li > 0.f);
    }

    bool GenerateEmissiveLightSample(PathVertex vertex,inout SampleGenerator sg,out LightSample ls)
    {
        ls = {};
        if(!kUseEmissiveLights) return false;
        TriangleLightSample lightSample;
        if(!emissiveSampler.sampleLight(vertex.pos,vertex.normal,true,sg,lightSample)) return false;

        ls.Li = lightSample.pdf > 0.f ? lightSample.Le / lightSample.pdf : float3(0);
        ls.pdf = lightSample.pdf;

        float3 lightPos = computeRayOrigin(lightSample.posW,lightSample.normalW);
        ls.origin = vertex.GetRayOrigin(lightPos - vertex.pos);
        float3 toLight = lightPos - ls.origin;
        ls.distance = length(toLight);
        ls.dir = normalize(toLight);

        return true;
    }

    bool GenerateAnalyticLightSample(PathVertex vertex,inout SampleGenerator sg,out LightSample ls)
    {
        ls = {};

        uint lightCount = gScene.getLightCount();
        if(!kUseAnalyticLights || lightCount == 0) return false;

        uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
        AnalyticLightSample lightSample;
        if (!sampleLight(vertex.pos, gScene.getLight(lightIndex), sg, lightSample)) return false;

        ls.pdf = lightSample.pdf / lightCount;
        ls.Li = lightSample.Li * lightCount;
        ls.origin = vertex.GetRayOrigin(lightSample.dir);
        ls.distance = lightSample.distance;
        ls.dir = lightSample.dir;

        return any(ls.Li > 0.f);
    }

    bool GenerateLightSample(PathVertex vertex, inout SampleGenerator sg,out LightSample ls)
    {
        ls = {};
        uint lightType;
        float selectedPdf;
        bool valid = false;

        if(!SelectLightType(lightType, selectedPdf, sg)) return false;

        if(kUseEnvLight && lightType == uint(LightType::EnvMap))
            valid = GenerateEnvLightSample(vertex,sg,ls);
        if(kUseEmissiveLights && lightType == uint(LightType::Emissive))
            valid = GenerateEmissiveLightSample(vertex,sg,ls);
        if(kUseAnalyticLights && lightType == uint(LightType::Analytic))
            valid = GenerateAnalyticLightSample(vertex,sg,ls);

        if(!valid) return false;

        ls.lightType = lightType;
        ls.pdf *= selectedPdf;
        ls.Li /= selectedPdf;

        return true;
    }

    bool GenerateScatterRay(ShadingData sd,const float lod,float3 rayOrigin,inout PathPayLoad pathState)
    {
        BSDFSample_ bsdfSample;

        if (sampleBSDF(sd,pathState.sg,bsdfSample))
        {
            pathState.thp *= bsdfSample.weight;
            pathState.direction = bsdfSample.wi;
            pathState.origin = rayOrigin;
            pathState.pdf = bsdfSample.pdf;

            if (bsdfSample.isLobe(LobeType::Delta))
                pathState.isCurrentVertexDelta = true;

            return any(pathState.thp > 0.f);
        }

        return false;
    }

   
    void HandleHit(inout PathPayLoad pathState,HitInfo hit)
    {
        const HitType hitType = hit.getType();
        const bool isTriangleHit = hitType == HitType::Triangle;
        const bool isPrimaryHit = (pathState.currentVertexIndex == 1);

        const float lod = 0.f;
        ShadingData sd = LoadShadingData(hit,pathState.direction,lod,isPrimaryHit);
        
        pathState.norm = sd.N;

        bool computeEmissive = isPrimaryHit || (!kUsedNEE || kUsedMIS || !pathState.isLastVertexSampledLight);
        if(kUsedReSTIRDI && pathState.currentVertexIndex == 2) computeEmissive = false;

        float misWeight = 1.f;
        if(computeEmissive && any(sd.emissive > 0.f))
        {    
            if(!isPrimaryHit && isTriangleHit && kUsedMIS && pathState.isLastVertexSampledLight)
            {
                TriangleHit thit = hit.getTriangleHit();
                TriangleLightHit tlhit;
                tlhit.triangleIndex = gScene.lightCollection.getTriangleIndex(thit.instanceID, thit.primitiveIndex);
                tlhit.posW = sd.posW;
                tlhit.normalW = sd.frontFacing ? sd.faceN : -sd.faceN;

                float lightPdf = GetEmissiveLightProbabilities() * emissiveSampler.evalPdf(pathState.origin, pathState.norm, true, tlhit);
                misWeight = EvalMisWeight(1,pathState.pdf,1,lightPdf);    
            }
            AddToPathContribution(pathState,sd.emissive * misWeight);
        }
        if (kUsedReSTIRDI && pathState.currentVertexIndex == 2 && pathState.isCurrentVertexDelta)
            pathState.lForDelta += sd.emissive * misWeight;
        
        /// terminate path with mis
        if(pathState.currentVertexIndex > kMaxBounces+1)
        {
            pathState.isTerminated = true;
            return;
        }

        uint lobes = getBSDFLobes(sd);
        bool hasNonDeltaLobes = (lobes & (uint)LobeType::NonDelta) != 0;

        bool applyNEE = kUsedNEE && hasNonDeltaLobes;

        if(kUsedReSTIRDI && pathState.currentVertexIndex == 1) applyNEE = false;

        if(applyNEE)
        {
            PathVertex vertex = PathVertex(sd.posW,sd.N,sd.faceN);
            bool isValidSample = false;
            LightSample ls = {};

            pathState.isLastVertexSampledLight = (lobes & (uint)LobeType::NonDeltaReflection) != 0;
            if(pathState.isLastVertexSampledLight)
                isValidSample = GenerateLightSample(vertex,pathState.sg,ls);

            if(isValidSample)
            {
                if(kUsedMIS && ls.lightType != uint(LightType::Analytic))
                {
                    float scatterPdf = evalPdfBSDF(sd,ls.dir);
                    ls.Li *= EvalMisWeight(1,ls.pdf,1,scatterPdf);
                }
                float3 weight = evalBSDFCosine(sd,ls.dir);
                float3 Lr = ls.Li * weight;
                if(any(Lr > 0.f))
                {
                    Ray ray = ls.GetVisibilityRay();
                    bool visible = TraceVisibilityRay(ray);
                    if(visible) AddToPathContribution(pathState,Lr);
                }
            }
        }

        float3 rayOrigin = sd.computeNewRayOrigin();

        bool valid = GenerateScatterRay(sd,lod,rayOrigin,pathState);

        if(HasFinishedScatter(pathState) && kUsedNEE && !kUsedMIS && pathState.isLastVertexSampledLight) valid = false;

        if(!valid) pathState.isTerminated = true;
    }

    void HandleMiss(inout PathPayLoad pathState)
    {
        pathState.isTerminated = true;
        
        bool computeEnvironment = !kUsedNEE || kUsedMIS || !pathState.isLastVertexSampledLight;
        float3 envRadiance = envMapSampler.eval(pathState.direction);
        float misWeight = 1.f;

        if(kUsedReSTIRDI && pathState.currentVertexIndex == 1) computeEnvironment = false;

        if(kUseEnvLight && computeEnvironment)
        {
            if(kUsedNEE && kUsedMIS && pathState.isLastVertexSampledLight)
            {
                float lightPdf = GetEnvLightProbabilities() * envMapSampler.evalPdf(pathState.direction); 
                misWeight = EvalMisWeight(1,pathState.pdf,1,lightPdf);
            }

            AddToPathContribution(pathState,envRadiance*misWeight);
        }

        if (kUsedReSTIRDI && pathState.currentVertexIndex == 1 && pathState.isCurrentVertexDelta)
            pathState.lForDelta += envRadiance * misWeight;
}
};

ParameterBlock<PathTracer> pathtracer;
