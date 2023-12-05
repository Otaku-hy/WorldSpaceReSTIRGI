#include "Scene/ScenePrimitiveDefines.slangh"
#include "Scene/Material/MaterialDefines.slangh"

import Scene.shading;
import Scene.Raytracing;
import Scene.Intersection;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Materials.MaterialShading;
import Params;
import LoadShadingData;

//import PathState;
import Experimental.WorldSpaceReSTIRGI.ReconnectionData;

static const float kRayTMax = 1e20f;

enum class PathFlags
{
    active = 0x0001,

    specular = 0x0002,          ///currentVertexState
    delta = 0x0004,             ///currentVertexState
    diffuseBounce = 0x0008,
    specularBounce = 0x0010,

    lastVertexlightSampled = 0x0020,

    pathHasSpecularBounce = 0x0040,
};

struct PathPayLoad
{
    uint flags;
    uint currentVertexIndex; //vertexIndex along the path, intialized value is 1
    uint rcVertexLength;

    bool isLastVertexClassifiedAsRough;

    float3 origin;
    float3 norm;
    float3 direction;
    
    float pdf;

    float3 prefixThp;
    float3 thp;
    float3 radiance;

    float3 LoForDelta;

    float3 prefixPathRadiance;
    float3 rcVertexRadiance;

    PackedHitInfo preRcVertexHit;
    float3 preRcVertexWo;

    float3 rcVertexPos;
    float3 rcVertexNorm;
    float rcPdf;

    SampleGenerator sg;

    [mutating]void SetActive()
    {
        SetFlag(PathFlags::active);
    }
    [mutating]void SetTerminate()
    {
        SetFlag(PathFlags::active, false);
    }
    [mutating]void SetSpecular(bool value = true)
    {
        SetFlag(PathFlags::specular, value);
    }
    [mutating]void SetDelta(bool value = true)
    {
        SetFlag(PathFlags::delta, value);
    }
    [mutating]void SetSpecularBounce(bool value = true)
    {
        SetFlag(PathFlags::specularBounce, value);
    }
    [mutating]void SetDiffuseBounce(bool value = true)
    {
        SetFlag(PathFlags::diffuseBounce, value);
    }
    [mutating]void SetSpecularPath(bool value = true)    ///indicate the whole path has at least one specular scatter event
    {
        SetFlag(PathFlags::pathHasSpecularBounce, value);
    }
    [mutating]void SetLightSampled(bool value = true)
    {
        SetFlag(PathFlags::lastVertexlightSampled, value);
    }

    bool IsActive()
    {
        return HasFlag(PathFlags::active);
    }
    bool IsTerminate()
    {
        return !IsActive();
    }
    bool IsDelta()
    {
        return HasFlag(PathFlags::delta);
    }
    bool IsSpecular()
    {
        return HasFlag(PathFlags::specular);
    }
    bool IsSpecularBounce()
    {
        return HasFlag(PathFlags::specularBounce);
    }
    bool IsDiffuseBounce()
    {
        return HasFlag(PathFlags::diffuseBounce);
    }
    bool IsSpecularPath()
    {
        return HasFlag(PathFlags::pathHasSpecularBounce);
    }
    bool IsLightSampled()
    {
        return HasFlag(PathFlags::lastVertexlightSampled);
    }
     
    float3 GetCurrentThp()
    {
        return prefixThp * thp;
    }

    [mutating]void UpdatePrefixThp()    ///for vertex not reach preRcVertex
    {
        prefixThp *= thp;
        thp = 1.f;
    }
    [mutating]void ResetThp()      /// Reset throughput at rcVertex
    {
        thp = 1.f;
    }

    bool HasFlag(PathFlags flag)
    {
        return (flags & uint(flag)) != 0;
    }

    [mutating]void SetFlag(PathFlags flag, bool value = true)
    {
        if (value)
            flags |= (uint(flag));
        else
            flags &= ~(uint(flag));
    }

    [mutating]void ClearEventFlags()
    {
        flags &= ~(uint(PathFlags::specular) | uint(PathFlags::delta) | uint(PathFlags::diffuseBounce) | uint(PathFlags::specularBounce));
    }

    Ray GenerateScatterRay()
    {
        return Ray(origin, direction, 0.f, 1e20f);
    }
};


struct PathTracer
{
    static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
    static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
    static const bool kUseEnvLight = USE_ENV_LIGHT;

    static const bool kUsedReSTIRDI = USE_RESTIRDI;
    static const bool kUsedNEE = USE_NEE;
    static const bool kUsedMIS = USE_MIS;
    static const uint kMaxBounces = MAX_GI_BOUNCE;

    static const float kRoughnessThreshold = GI_ROUGHNESS_THRESHOLD;

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

    bool IsSpecular(ShadingData sd)
    {
        float diffuseComponent = luminance(sd.diffuse);
        float specularWeight = luminance(sd.specular);

        float specularComponent = specularWeight * specularWeight / (4 * sd.linearRoughness * sd.linearRoughness);
        float totalWeight = diffuseComponent + specularComponent;
        return diffuseComponent < kRoughnessThreshold * totalWeight;
    }

    void GeneratePathState(uint2 pixel,out PathPayLoad pathState)
    {
        pathState = {};
        pathState.currentVertexIndex = 0;
        pathState.rcVertexLength = kMaxBounces;

        pathState.isLastVertexClassifiedAsRough = false;

        pathState.prefixThp = pathState.thp = 1.f;
        pathState.SetActive();

        pathState.sg = SampleGenerator(pixel, params.frameCount * params.numGIInstance + params.currentGIInstance);
    }

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
            //pathState.thp *= bsdfSample.weight;
            pathState.direction = bsdfSample.wi;
            pathState.origin = rayOrigin;
            pathState.pdf = bsdfSample.pdf;

            float3 weight = bsdfSample.weight;

            /// handle event
            if (bsdfSample.isLobe(LobeType::Delta))
                pathState.SetDelta();
            else if (bsdfSample.isLobe(LobeType::SpecularReflection))
                pathState.SetSpecular();
            else if (bsdfSample.isLobe(LobeType::DiffuseReflection))
                pathState.SetDiffuseBounce();

            if (pathState.IsDelta() || pathState.IsSpecular())
                pathState.SetSpecularBounce();

            /// update thp
            
            bool vertexClassifiedAsRough = !(sd.linearRoughness < kRoughnessThreshold && pathState.IsSpecularBounce());
            pathState.isLastVertexClassifiedAsRough = vertexClassifiedAsRough;

            if (pathState.currentVertexIndex < pathState.rcVertexLength && vertexClassifiedAsRough)
                pathState.rcVertexLength = pathState.currentVertexIndex + 1;

            if (pathState.currentVertexIndex == 1 && sd.linearRoughness < kRoughnessThreshold)
            {
                const uint activeLobes = sd.getActiveLobes();
                if ((activeLobes & (uint) LobeType::DiffuseReflection) && (activeLobes & (uint) LobeType::SpecularReflection))
                {
                    if (pathState.IsDiffuseBounce())
                    {
                        sd.setActiveLobes((uint) LobeType::Diffuse);
                        pathState.pdf = evalPdfBSDF(sd, bsdfSample.wi);
                        weight = evalBSDFCosine(sd, bsdfSample.wi) / pathState.pdf;
                    }
                    if (pathState.IsSpecularBounce())
                    {
                        FalcorBSDF bsdf;
                        bsdf.setup(sd);
                        sd.setActiveLobes((uint) LobeType::SpecularReflection);
                        pathState.pdf = evalPdfBSDF(sd, bsdfSample.wi,-1,true);
                        weight = evalBSDFCosine(sd, bsdfSample.wi, -1, true) / (pathState.pdf * bsdf.pSpecularReflection);
                }
            }   
            }   

            pathState.thp *= weight;

            bool valid = any(pathState.thp > 0.f);
            if(valid)
            {
                if (pathState.currentVertexIndex +1 < pathState.rcVertexLength)
                {
                    pathState.UpdatePrefixThp();
                }
            }

            return valid;
        }

        return false;
    }

   
    void HandleHit(inout PathPayLoad pathState,HitInfo hit)
    {
        pathState.currentVertexIndex++;

        const HitType hitType = hit.getType();
        const bool isTriangleHit = hitType == HitType::Triangle;
        const bool isPrimaryHit = (pathState.currentVertexIndex == 1);

        const float lod = 0.f;
        ShadingData sd = LoadShadingData(hit,pathState.direction,lod,isPrimaryHit);
        
        pathState.norm = sd.N;

        bool isLightSamplable = !pathState.IsDelta();
        bool computeEmissive = isPrimaryHit || (!kUsedNEE || kUsedMIS || !pathState.IsLightSampled() || !isLightSamplable);
        if(kUsedReSTIRDI && pathState.currentVertexIndex == 2) computeEmissive = false;

        if (pathState.isLastVertexClassifiedAsRough && sd.linearRoughness <= kRoughnessThreshold)
        {
            sd.setActiveLobes((uint) LobeType::Diffuse);
        }

        /// when in a scene with emissive triangle, set computeEmissive false
    //if (pathState.currentVertexIndex == 1)
    //    computeEmissive = false;

        float misWeight = 1.f;
        if(computeEmissive && any(sd.emissive > 0.f))
        {    
            if (!isPrimaryHit && isTriangleHit && kUsedMIS && pathState.IsLightSampled() && isLightSamplable)
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
            if (pathState.currentVertexIndex <= pathState.rcVertexLength && !isPrimaryHit)
            {
                float3 thp = pathState.GetCurrentThp();
                pathState.prefixPathRadiance += thp * sd.emissive * misWeight;
            }
            else if (pathState.currentVertexIndex > pathState.rcVertexLength)
            {
            float3 thp = pathState.thp;
            pathState.rcVertexRadiance += thp * sd.emissive * misWeight;
        }
    }
        if (kUsedReSTIRDI && pathState.currentVertexIndex == 2 && !isLightSamplable)
            pathState.LoForDelta += pathState.GetCurrentThp() * sd.emissive * misWeight;

        bool connectabele = pathState.isLastVertexClassifiedAsRough && pathState.currentVertexIndex == pathState.rcVertexLength;
        /// set reconnection vertex

        if (connectabele)
        {
            pathState.rcVertexPos = sd.posW;
            pathState.rcVertexNorm = sd.N;
            pathState.rcPdf = pathState.pdf;
            pathState.ResetThp();
        }

        
        /// terminate path with mis
        if (pathState.currentVertexIndex > kMaxBounces + 1)
        {
            pathState.SetTerminate();
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

            pathState.SetLightSampled((lobes & (uint) LobeType::NonDeltaReflection) != 0);
            if (pathState.IsLightSampled())
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
                    if(visible)
                    {
                        AddToPathContribution(pathState, Lr);
                        if (pathState.currentVertexIndex < pathState.rcVertexLength)
                        {
                            float3 thp = pathState.GetCurrentThp();
                            pathState.prefixPathRadiance += thp * Lr;
                        }
                        else
                        {
                            float3 thp = pathState.thp;
                            pathState.rcVertexRadiance += thp * Lr;
                        }
                    }
                }
            }
        }
        float3 rayOrigin = sd.computeNewRayOrigin();

        //set pre rc vertex

        if (pathState.currentVertexIndex < pathState.rcVertexLength )
        {
            pathState.preRcVertexHit = hit.pack();
            pathState.preRcVertexWo = pathState.direction;
        }

        pathState.ClearEventFlags();
        bool valid = GenerateScatterRay(sd, lod, rayOrigin, pathState);

        if (HasFinishedScatter(pathState) && kUsedNEE && !kUsedMIS && pathState.IsLightSampled())
            valid = false;

        /*if (pathState.isLastVertexClassifiedAsRough && pathState.IsSpecularBounce())
        {
            valid = false;
        }*/
        
        if (!valid) pathState.SetTerminate();
    }

    void HandleMiss(inout PathPayLoad pathState)
    {
        pathState.SetTerminate();

        bool isLightSamplable = !pathState.IsDelta();
        bool computeEnvironment = !kUsedNEE || kUsedMIS || !pathState.IsLightSampled() || !isLightSamplable;
        float3 envRadiance = envMapSampler.eval(pathState.direction);
        float misWeight = 1.f;

        if(kUsedReSTIRDI && pathState.currentVertexIndex == 1) computeEnvironment = false;

        if(kUseEnvLight && computeEnvironment)
        {
            if (kUsedNEE && kUsedMIS && pathState.IsLightSampled() && isLightSamplable)
            {
                float lightPdf = GetEnvLightProbabilities() * envMapSampler.evalPdf(pathState.direction); 
                misWeight = EvalMisWeight(1,pathState.pdf,1,lightPdf);
            }

            AddToPathContribution(pathState,envRadiance*misWeight);

            if (pathState.currentVertexIndex < pathState.rcVertexLength)
            {
                float3 thp = pathState.GetCurrentThp();
                pathState.prefixPathRadiance += thp * envRadiance * misWeight;
            }
            else
            {
                float3 thp = pathState.thp;
                pathState.rcVertexRadiance += thp * envRadiance * misWeight;
            }
        }

        if (kUsedReSTIRDI && pathState.currentVertexIndex == 1 && !isLightSamplable)
            pathState.LoForDelta += pathState.GetCurrentThp() * envRadiance * misWeight;
}
};

ParameterBlock<PathTracer> pathtracer;
