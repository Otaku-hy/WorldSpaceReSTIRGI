/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "WorldSpaceReSTIRGIPass.h"


namespace
{
    const char kDesc[] = "Insert pass description here";    

    const std::string& kShaderMode = "6_5";
    const std::string& kTracePassFilePath = "RenderPasses/WorldSpaceReSTIRGIPass/TracePass.rt.slang";
    const std::string& kFinalShadingFilePath = "RenderPasses/WorldSpaceReSTIRGIPass/FinalShading.cs.slang";
    const std::string& kReflectTypeFilePath = "RenderPasses/WorldSpaceReSTIRGIPass/ReflectTypes.cs.slang";

    const std::string& kInputVBuffer = "vbuffer";
    const std::string& kInputDepthBuffer = "vDepth";
    const std::string& kInputNormBuffer = "vNormW";

    const std::string& kOutputColor = "outputColor";

    ChannelList InputChannel
    {
        {kInputVBuffer,"vbuffer","",false,ResourceFormat::Unknown},
        {kInputDepthBuffer,"depth","",false,ResourceFormat::Unknown},
        {kInputNormBuffer,"vNormW","",false,ResourceFormat::Unknown}
    };

    ChannelList OutputChannel
    {
        {kOutputColor,"outputColor","",false,ResourceFormat::RGBA32Float}
    };

    const uint32_t kMaxPayloadSizeBytes = 256u;
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" __declspec(dllexport) const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" __declspec(dllexport) void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerClass("WorldSpaceReSTIRGIPass", kDesc, WorldSpaceReSTIRGIPass::create);
}

WorldSpaceReSTIRGIPass::SharedPtr WorldSpaceReSTIRGIPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new WorldSpaceReSTIRGIPass);
    return pPass;
}

WorldSpaceReSTIRGIPass::WorldSpaceReSTIRGIPass()
{
    mOptions = WorldSpaceReSTIRGI::Options::create();
}

std::string WorldSpaceReSTIRGIPass::getDesc() { return kDesc; }

Dictionary WorldSpaceReSTIRGIPass::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection WorldSpaceReSTIRGIPass::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, InputChannel);
    addRenderPassOutputs(reflector, OutputChannel);
    return reflector;
}

void WorldSpaceReSTIRGIPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    params.frameDim = compileData.defaultTexDims;
}

void WorldSpaceReSTIRGIPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();

    const auto& pOutputColor = renderData[kOutputColor]->asTexture();
    assert(pOutputColor);

    if (!mpScene)
    {
        auto clear = [&](const ChannelDesc& channel)
        {
            auto pTex = renderData[channel.name]->asTexture();
            if (pTex) pRenderContext->clearUAV(pTex->getUAV().get(), float4(0.f));
        };
        for (const auto& channel : OutputChannel) clear(channel);
        return;
    }

    if (mOptionChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionChanged = false;
    }

    params.frameDim = uint2(pOutputColor->getWidth(), pOutputColor->getHeight());

    for (uint32_t i = 0; i < reSTIRInstances.size(); i++)
    {
        params.currentGIInstance = i;
        UpdateResource();
        UpdateProgram();
        //std::cout << "heer";
        reSTIRInstances[i]->BeginFrame(pRenderContext, params.frameDim);
        PrepareGIData(pRenderContext, renderData);
        //reSTIRInstances[i]->params._pad = float3(pad, 0, 0);
        reSTIRInstances[i]->UpdateReSTIRGI(pRenderContext, mpInitialSample,renderData[kInputNormBuffer]->asTexture(), renderData[kInputDepthBuffer]->asTexture(), mpReconnectionData,renderData[kInputVBuffer]->asTexture());
        FinalShading(pRenderContext, renderData, i);
        reSTIRInstances[i]->EndFrame(pRenderContext);
    }

    params.frameCount++;
}

void WorldSpaceReSTIRGIPass::renderUI(Gui::Widgets& widget)
{
    bool staticDirty = false;
    bool runtimeDirty = false;

    if (widget.group("path tracing options"))
    {
        staticDirty |= widget.checkbox("useReSTIRDI", mPtOptions.usedReSTIRDI);
        staticDirty |= widget.checkbox("useNEE", mPtOptions.usedNEE);
        if (mPtOptions.usedNEE)
            staticDirty |= widget.checkbox("useMIS", mPtOptions.usedMIS);
        staticDirty |= widget.var("gibounce", mPtOptions.maxBounces, 1u, 10u);
    }

    staticDirty |= widget.var("giInstance", numReSTIRInstances, 1u, 6u);

    if (!reSTIRInstances.empty() && reSTIRInstances[0])
    {
        mOptionChanged = reSTIRInstances[0]->renderUI(widget);
        staticDirty |= mOptionChanged;
        for (size_t i = 1; i < reSTIRInstances.size(); i++)
        {
            reSTIRInstances[i]->CopyRecompileState(reSTIRInstances[0]);
        }
    }

    runtimeDirty |= widget.var("11", pad, 0u, 2u);

    if (staticDirty) mRecompile = true;
    bool dirty = staticDirty || runtimeDirty;
    if (dirty) mOptionChanged = true;
}

void WorldSpaceReSTIRGIPass::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mpScene = pScene;
    params.frameCount = 0u;

    mPathTracingPass.mpProgram = nullptr;
    mPathTracingPass.mpBindTable = nullptr;
    mPathTracingPass.mpVars = nullptr;

    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);

    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    if (mpScene->useEnvLight())
    {
        mpEnvMapSampler = EnvMapSampler::create(pRenderContext, mpScene->getEnvMap());
    }

    if (mpScene->useEmissiveLights())
    {
        mpEmissiveSampler = EmissiveUniformSampler::create(pRenderContext, mpScene);
    }

    RtProgram::Desc desc;
    desc.addShaderLibrary(kTracePassFilePath);
    desc.setShaderModel(kShaderMode);

    desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
    desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
    desc.setMaxTraceRecursionDepth(1);

    mPathTracingPass.mpBindTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
    mPathTracingPass.mpBindTable->setRayGen(desc.addRayGen("RayGen"));
    mPathTracingPass.mpBindTable->setMiss(0, desc.addMiss("ScatterMiss"));

    if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
    {
        mPathTracingPass.mpBindTable->setHitGroupByType(0, mpScene, Scene::GeometryType::TriangleMesh, desc.addHitGroup("ScatterTriangleClosestHit", "ScatterTriangleAnyHit"));
    }

    if (mpScene->hasGeometryType(Scene::GeometryType::DisplacedTriangleMesh))
    {
        mPathTracingPass.mpBindTable->setHitGroupByType(0, mpScene, Scene::GeometryType::DisplacedTriangleMesh, desc.addHitGroup("ScatterDisplacedTriangleMeshClosestHit", "", "DisplacedTriangleMeshIntersection"));
    }

    auto defines = GetDefines();

    desc = desc.addDefines(defines);
    mPathTracingPass.mpProgram = RtProgram::create(desc);
    mPathTracingPass.mpVars = RtProgramVars::create(mPathTracingPass.mpProgram, mPathTracingPass.mpBindTable);

    mpReflectTypePass = ComputePass::create(Program::Desc(kReflectTypeFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);
    mpFinalShadingPass = ComputePass::create(Program::Desc(kFinalShadingFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);

    {
        reSTIRInstances.clear();

        reSTIRInstances.resize(numReSTIRInstances);
        params.numGIInstance = numReSTIRInstances;
        for (uint32_t i = 0; i < numReSTIRInstances; i++)
        {
            reSTIRInstances[i] = WorldSpaceReSTIRGI::create(mpScene, mOptions, i, numReSTIRInstances);
        }
    }
}

void WorldSpaceReSTIRGIPass::UpdateProgram()
{
    if (!mRecompile) return;

    auto defines = GetDefines();

    RtProgram::Desc desc = mPathTracingPass.mpProgram->getRtDesc();
    desc = desc.addDefines(defines);
   
    mPathTracingPass.mpProgram = RtProgram::create(desc);
    
    mPathTracingPass.mpVars = RtProgramVars::create(mPathTracingPass.mpProgram, mPathTracingPass.mpBindTable);

    mRecompile = false;

    if (reSTIRInstances.size() != numReSTIRInstances)
    {
        reSTIRInstances.clear();

        reSTIRInstances.resize(numReSTIRInstances);
        params.numGIInstance = numReSTIRInstances;
        for (uint32_t i = 0; i < numReSTIRInstances; i++)
        {
            reSTIRInstances[i] = WorldSpaceReSTIRGI::create(mpScene, mOptions, i, numReSTIRInstances);
        }
    }
}

void WorldSpaceReSTIRGIPass::UpdateResource()
{
    uint32_t elementCount = params.frameDim.x * params.frameDim.y;
    if (!mpInitialSample || mpInitialSample->getElementCount() != elementCount)
    {
        mpInitialSample = Buffer::createStructured(mpReflectTypePass["initialSamples"], elementCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
    }
    if (!mpReconnectionData || mpReconnectionData->getElementCount() != elementCount)
    {
        mpReconnectionData = Buffer::createStructured(mpReflectTypePass["reconnectionDataBuffer"], elementCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
    }
}

Program::DefineList WorldSpaceReSTIRGIPass::GetDefines()
{
    Program::DefineList defines = {};

    if (mpSampleGenerator) defines.add(mpSampleGenerator->getDefines());
    if (mpEmissiveSampler) defines.add(mpEmissiveSampler->getDefines());

    if (mpScene)
    {
        defines.add(mpScene->getSceneDefines());
        defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
        defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    }

    defines.add("USE_RESTIRDI", mPtOptions.usedReSTIRDI ? "1" : "0");
    defines.add("USE_NEE", mPtOptions.usedNEE ? "1" : "0");
    defines.add("USE_MIS", mPtOptions.usedMIS ? "1" : "0");
    defines.add("MAX_GI_BOUNCE", std::to_string(mPtOptions.maxBounces));
    defines.add("GI_ROUGHNESS_THRESHOLD", std::to_string(mOptions->roughnessThreshold));

    return defines;
}

void WorldSpaceReSTIRGIPass::PrepareGIData(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto vars = mPathTracingPass.mpVars->getRootVar();

    vars["sampleInitializer"]["vbuffer"] = renderData[kInputVBuffer]->asTexture();
    vars["sampleInitializer"]["initialSamples"] = mpInitialSample;
    vars["sampleInitializer"]["outputColor"] = renderData[kOutputColor]->asTexture();
    vars["sampleInitializer"]["reconnectionDataBuffer"] = mpReconnectionData;
    vars["sampleInitializer"]["roughnessThreshold"] = mOptions->roughnessThreshold;

    vars["pathtracer"]["params"].setBlob(params);
    vars["gScene"] = mpScene->getParameterBlock();

    if (mpEnvMapSampler) mpEnvMapSampler->setShaderData(vars["pathtracer"]["envMapSampler"]);
    if (mpEmissiveSampler) mpEmissiveSampler->setShaderData(vars["pathtracer"]["emissiveSampler"]);

    mpScene->raytrace(pRenderContext, mPathTracingPass.mpProgram.get(), mPathTracingPass.mpVars, uint3(params.frameDim.x, params.frameDim.y, 1u));
}

void WorldSpaceReSTIRGIPass::FinalShading(RenderContext* pRenderContext, const RenderData& renderData, uint currentInstance)
{
    auto vars = mpFinalShadingPass->getRootVar();

    vars["finalShading"]["vbuffer"] = renderData[kInputVBuffer]->asTexture();
    vars["finalShading"]["reconnectionDataBuffer"] = mpReconnectionData;

    vars["finalShading"]["outputColor"] = renderData[kOutputColor]->asTexture();

    vars["finalShading"]["params"].setBlob(params);
    vars["finalShading"]["finalSample"] = reSTIRInstances[currentInstance]->mpFinalSample;

    vars["gScene"] = mpScene->getParameterBlock();

    mpFinalShadingPass->execute(pRenderContext, uint3(params.frameDim.x, params.frameDim.y, 1u));
}

