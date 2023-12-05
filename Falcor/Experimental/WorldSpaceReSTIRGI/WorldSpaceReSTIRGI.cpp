#include "stdafx.h"
#include "WorldSpaceReSTIRGI.h"
#include "Utils/Color/ColorHelpers.slang"

namespace Falcor
{
    namespace {
        const std::string& kReflectTypeFilePath = "Experimental/WorldSpaceReSTIRGI/ReflectTypes.cs.slang";
        const std::string& kInitialReservoirFilePath = "Experimental/WorldSpaceReSTIRGI/InitialReservoirs.cs.slang";
        const std::string& kBuildHashGridFilePath = "Experimental/WorldSpaceReSTIRGI/BuildHashGrid.cs.slang";
        const std::string& kGIResamplingFilePath = "Experimental/WorldSpaceReSTIRGI/SpatiotemporalResampling.cs.slang";
        const std::string& kFinalSampleFilePath = "Experimental/WorldSpaceReSTIRGI/FinalSample.cs.slang";

        const Gui::DropdownList kReSTIRGIModeList =
        {
            {(uint32_t)WorldSpaceReSTIRGI::TargetPdf::IncomingRadiance, "incoming radiance"},
            {(uint32_t)WorldSpaceReSTIRGI::TargetPdf::OutgoingRadiance, "outgoing radiance"},
        };

        const std::string& kShaderMode = "6_5";
    }

    WorldSpaceReSTIRGI::WorldSpaceReSTIRGI(const Scene::SharedPtr& pScene, const Options::SharedPtr& options, uint instanceID, uint numInstance) : mpScene(pScene), mOptions(options)
    {
        mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
        mpPrexfixSumPass = PrefixSum::create();
        assert(mpScene);

        auto defines = WorldSpaceReSTIRGI::getDefines();

        mpReflectTypes = ComputePass::create(Program::Desc(kReflectTypeFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);
        params.instanceID = instanceID;
        params.frameCount = 0u;
        giInstanceNum = numInstance;
    }

    WorldSpaceReSTIRGI::SharedPtr WorldSpaceReSTIRGI::create(const Scene::SharedPtr& pScene, const Options::SharedPtr& options, uint instanceID, uint numInstance)
    {
        return WorldSpaceReSTIRGI::SharedPtr(new WorldSpaceReSTIRGI(pScene, options, instanceID, numInstance));
    }

    Program::DefineList WorldSpaceReSTIRGI::getDefines() const
    {
        Program::DefineList defines = {};

        if (mpScene) defines.add(mpScene->getSceneDefines());
        if (mpSampleGenerator) defines.add(mpSampleGenerator->getDefines());

        defines.add("GI_ROUGHNESS_THRESHOLD", std::to_string(mOptions->roughnessThreshold));

        defines.add("GI_TARGET_PDF", std::to_string((int)mOptions->resamplingTargetPdf));

        return defines;
    }

    bool WorldSpaceReSTIRGI::renderUI(Gui::Widgets& widget)
    {
        bool staticDirty = false;
        bool runtimeDirty = false;

        if (auto group = widget.group("ReSTIRGI Options"))
        {
            runtimeDirty |= widget.var("Normal threshold", mOptions->normalThreshold, 0.f, 1.f);
            runtimeDirty |= widget.var("Depth threshold", mOptions->depthThreshold, 0.f, 1.f);
            runtimeDirty |= widget.var("Cells Dimension", mOptions->sceneGridDimension, 1u, 300u);

            staticDirty |= widget.var("Roughness threshold", mOptions->roughnessThreshold, 0.f, 1.2f);
            staticDirty |= widget.dropdown("Target pdf mode", kReSTIRGIModeList, reinterpret_cast<uint32_t&>(mOptions->resamplingTargetPdf));
        }

        if (staticDirty) mRecompile = true;
        bool dirty = staticDirty || runtimeDirty;
        if (dirty) mOptionChanged = true;

        return dirty;
    }

    void WorldSpaceReSTIRGI::BeginFrame(RenderContext* pRenderContext, uint2 frameDim)
    {
        UpdateResources(frameDim);
        params.frameDim = frameDim;
        params.fov = focalLengthToFovY(mpScene->getCamera()->getFocalLength(), Camera::kDefaultFrameHeight);
        params.sceneBBMin = mpScene->getSceneBounds().minPoint -float3(0.1, 0.1, 0.1);

        float3 boudingSize = abs((mpScene->getSceneBounds().maxPoint - mpScene->getSceneBounds().minPoint) / static_cast<float>(mOptions->sceneGridDimension));

        params._pad = float4(0, 0, 0,0);
        params.minCellSize = std::max(boudingSize.x, std::max(boudingSize.y, boudingSize.z));

        //std::cout << params.minCellSize <<" ";

        pRenderContext->clearUAV(mpCheckSumBuffer[(params.frameCount + 1) % 2]->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(mpCellCounter[(params.frameCount + 1) % 2]->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(mpIndexBuffer[(params.frameCount + 1) % 2]->getUAV().get(), uint4(0));
      
    }

    void WorldSpaceReSTIRGI::UpdateResources(uint2 frameDim)
    {
        uint32_t elementCount = frameDim.x * frameDim.y;

        if (!mpInitialReservoir || mpInitialReservoir->getElementCount() != elementCount)
        {
            mpInitialReservoir = Buffer::createStructured(mpReflectTypes["initialReservoirs"], elementCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
        }

        if (!mpFinalSample || mpFinalSample->getElementCount() != elementCount)
        {
            mpFinalSample = Buffer::createStructured(mpReflectTypes["finalSample"], elementCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
        }

        if (!mpAppendBuffer || mpAppendBuffer->getElementCount() != elementCount)
        {
            mpAppendBuffer = Buffer::createStructured(mpReflectTypes["appendBuffer"], elementCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
        }

        uint32_t reservoirCount = elementCount * 2;

        for (uint32_t i = 0; i < 2; i++)
        {
            if (!mpReservoirs[i] || mpReservoirs[i]->getElementCount() != reservoirCount)
            {
                mpReservoirs[i] = Buffer::createStructured(mpReflectTypes["spatiotemporalReservoirs"], reservoirCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
            }
        }

        uint32_t hashBufferCount = 3200000 * sizeof(uint32_t);
        for (uint32_t i = 0; i < 2; i++)
        {
            if (!mpCellCounter[i])
            {
                mpCellCounter[i] = Buffer::create(hashBufferCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
                mpCellCounter[i]->setName("cellCounter");
            }
            if (!mpIndexBuffer[i])
            {
                mpIndexBuffer[i] = Buffer::create(hashBufferCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
                mpIndexBuffer[i]->setName("indexBuffer");
            }
            if (!mpCheckSumBuffer[i])
            {
                mpCheckSumBuffer[i] = Buffer::create(hashBufferCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
                mpCheckSumBuffer[i]->setName("cellCounter");
            }
            if (!mpCellStorage[i] || mpCellStorage[i]->getElementCount() != elementCount)
            {
                mpCellStorage[i] = Buffer::createStructured(mpReflectTypes["cellStorage"], elementCount, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
            }
        }
    }

    void WorldSpaceReSTIRGI::EndFrame(RenderContext* pRenderContext)
    {
        params.frameCount++;

        mPreCameraPos = mpScene->getCamera()->getPosition();
        mPreViewProj = mpScene->getCamera()->getViewProjMatrixNoJitter();

    }

    void WorldSpaceReSTIRGI::UpdateReSTIRGI(RenderContext* pRenderContext, const Buffer::SharedPtr& initialSample, const Texture::SharedPtr& vNormW, const Texture::SharedPtr& vDepth, const Buffer::SharedPtr& reconnectionData, const Texture::SharedPtr& vbuffer)
    {
        UpdateProgram();
        InitReservoirPass(pRenderContext, initialSample);
        BuildHashGridPass(pRenderContext);
        ResamplingPass(pRenderContext, vDepth, vNormW, reconnectionData,vbuffer);
        FinalShadingPass(pRenderContext);
    }

    void WorldSpaceReSTIRGI::UpdateProgram()
    {
        if (!mRecompile) return;

        Program::DefineList defines = WorldSpaceReSTIRGI::getDefines();
        ///only resampling pass need recompile
        mpInitReservoirPass = ComputePass::create(Program::Desc(kInitialReservoirFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);
        mpBuildHashGridPass = ComputePass::create(Program::Desc(kBuildHashGridFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);
        mpGIResamplingPass = ComputePass::create(Program::Desc(kGIResamplingFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);
        mpFinalShadingPass = ComputePass::create(Program::Desc(kFinalSampleFilePath).setShaderModel(kShaderMode).csEntry("main"), defines);

        mRecompile = false;
    }

    void WorldSpaceReSTIRGI::InitReservoirPass(RenderContext* pRenderContext, const Buffer::SharedPtr& initialSample)
    {
        PROFILE("WorldSpaceReSTIR::InitReservoir");

        auto var = mpInitReservoirPass->getRootVar();
        var["sampleManager"]["initialSamples"] = initialSample;
        var["sampleManager"]["initialReservoirs"] = mpInitialReservoir;
        var["sampleManager"]["appendBuffer"] = mpAppendBuffer;
        var["sampleManager"]["checkSum"] = mpCheckSumBuffer[(params.frameCount + 1) % 2];
        var["sampleManager"]["cellCounters"] = mpCellCounter[(params.frameCount + 1) % 2];

        var["sampleManager"]["cameraPos"] = mpScene->getCamera()->getPosition();

        var["sampleManager"]["params"].setBlob(params);

        var["sampleManager"]["finalSample"] = mpFinalSample;

        mpInitReservoirPass->execute(pRenderContext, uint3(params.frameDim.x, params.frameDim.y, 1u));
    }

    void WorldSpaceReSTIRGI::BuildHashGridPass(RenderContext* pRenderContext)
    {
        PROFILE("WorldSpaceReSTIR::BuildHashGrid");

        pRenderContext->copyBufferRegion(mpIndexBuffer[(params.frameCount + 1) % 2].get(), 0, mpCellCounter[(params.frameCount + 1) % 2].get(), 0, mpCellCounter[(params.frameCount + 1) % 2]->getSize());
        mpPrexfixSumPass->execute(pRenderContext, mpIndexBuffer[(params.frameCount + 1) % 2], static_cast<uint32_t>(mpIndexBuffer[(params.frameCount + 1) % 2]->getSize()));

        auto var = mpBuildHashGridPass->getRootVar();
        var["gridBuilder"]["indexBuffer"] = mpIndexBuffer[(params.frameCount + 1) % 2];
        var["gridBuilder"]["appendBuffer"] = mpAppendBuffer;
        var["gridBuilder"]["cellStorage"] = mpCellStorage[(params.frameCount + 1) % 2];

        var["gridBuilder"]["params"].setBlob(params);

        mpBuildHashGridPass->execute(pRenderContext, uint3(params.frameDim.x, params.frameDim.y, 1u));
    }

    void WorldSpaceReSTIRGI::ResamplingPass(RenderContext* pRenderContext, const Texture::SharedPtr& vDepth, const Texture::SharedPtr& vNormW, const Buffer::SharedPtr& reconnectionData, const Texture::SharedPtr& vbuffer)
    {
        PROFILE("WorldSpaceReSTIR::ReSampling");

        auto var = mpGIResamplingPass->getRootVar();

        var["gScene"] = mpScene->getParameterBlock();

        var["resampleManager"]["depth"] = vDepth;
        var["resampleManager"]["norm"] = vNormW;
        var["resampleManager"]["reconnectionDataBuffer"] = reconnectionData;

        var["resampleManager"]["prevViewProj"] = mPreViewProj;
        var["resampleManager"]["cameraPrePos"] = mPreCameraPos;

        var["resampleManager"]["vbuffer"] = vbuffer;

        var["resampleManager"]["initialReservoirs"] = mpInitialReservoir;
        var["resampleManager"]["preReservoirs"] = mpReservoirs[(params.frameCount + 0) % 2];
        var["resampleManager"]["currentReservoirs"] = mpReservoirs[(params.frameCount + 1) % 2];

        var["resampleManager"]["cellStorage"] = mpCellStorage[(params.frameCount + 0) % 2];
        var["resampleManager"]["indexBuffer"] = mpIndexBuffer[(params.frameCount + 0) % 2];
        var["resampleManager"]["checkSum"] = mpCheckSumBuffer[(params.frameCount + 0) % 2];
        var["resampleManager"]["cellCounters"] = mpCellCounter[(params.frameCount + 0) % 2];

        var["resampleManager"]["numInstance"] = giInstanceNum;
        var["resampleManager"]["params"].setBlob(params);

        var["resampleManager"]["depthThreshold"] = mOptions->depthThreshold;
        var["resampleManager"]["normalThreshold"] = mOptions->normalThreshold;

        mpGIResamplingPass->execute(pRenderContext, uint3(params.frameDim.x, params.frameDim.y, 1u));

        mPreCameraPos = mpScene->getCamera()->getPosition();
        mPreViewProj = mpScene->getCamera()->getViewProjMatrixNoJitter();

    }

    void WorldSpaceReSTIRGI::FinalShadingPass(RenderContext* pRenderContext)
    {
        PROFILE("WorldSpaceReSTIR::FinalSample");
        auto var = mpFinalShadingPass->getRootVar();

        var["finalSampleGenerator"]["finalSample"] = mpFinalSample;
        var["finalSampleGenerator"]["currentReservoirs"] = mpReservoirs[(params.frameCount + 1) % 2];
        var["finalSampleGenerator"]["params"].setBlob(params);

        mpFinalShadingPass->execute(pRenderContext, uint3(params.frameDim.x, params.frameDim.y, 1u));
    }

    void WorldSpaceReSTIRGI::CopyRecompileState(SharedPtr other)
    {
        mRecompile = other->mRecompile;
    }
}
