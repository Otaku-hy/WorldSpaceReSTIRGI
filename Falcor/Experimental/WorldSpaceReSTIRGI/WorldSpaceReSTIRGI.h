#pragma once

#include "Falcor.h"
#include "Utils/Sampling/AliasTable.h"
#include "Utils/Debug/PixelDebug.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Utils/Algorithm/PrefixSum.h"
#include "Params.slang"


namespace Falcor
{
    class dlldecl WorldSpaceReSTIRGI
    {
    public:
        using SharedPtr = std::shared_ptr<WorldSpaceReSTIRGI>;

        enum class TargetPdf
        {
            IncomingRadiance = 0,
            OutgoingRadiance = 1
        };

        /// <summary>
        /// some of the options will be added as macros in GIStaticParams
        /// </summary>

        struct Options
        {
            using SharedPtr = std::shared_ptr<Options>;

            static SharedPtr create() { return SharedPtr(new Options); }
            static SharedPtr create(const Options& other) { return SharedPtr(new Options(other)); }

            Options() {};
            Options(const Options& other) { *this = other; }

            float normalThreshold = 0.9f;
            float depthThreshold = 0.1f;

            /// <summary>
            /// static params -> changed requires recomplie
            /// </summary>
            float roughnessThreshold = 0.2f;
            uint sceneGridDimension = 80u;
            TargetPdf resamplingTargetPdf = TargetPdf::IncomingRadiance;
        };

        static SharedPtr create(const Scene::SharedPtr& pScene, const Options::SharedPtr& options, uint instanceID, uint numInstance);

        Program::DefineList getDefines() const;

        bool renderUI(Gui::Widgets& widget);

        void BeginFrame(RenderContext* pRenderContext, uint2 frameDim);
        void UpdateReSTIRGI(RenderContext* pRenderContext, const Buffer::SharedPtr& initialSample, const Texture::SharedPtr& vNormW, const Texture::SharedPtr& vDepth, const Buffer::SharedPtr& reconnectionData, const Texture::SharedPtr& vbuffer);
        void EndFrame(RenderContext* pRenderContext);

        void CopyRecompileState(SharedPtr other);

        Buffer::SharedPtr mpFinalSample;
        GIParameter params;

    private:
        WorldSpaceReSTIRGI(const Scene::SharedPtr& pScene, const Options::SharedPtr& options, uint instanceID, uint numInstance);

        void UpdateResources(uint2 frameDim);
        void UpdateProgram();
        void InitReservoirPass(RenderContext* pRenderContext, const Buffer::SharedPtr& initialSample);
        void BuildHashGridPass(RenderContext* pRenderContext);
        void ResamplingPass(RenderContext* pRenderContext, const Texture::SharedPtr& vDepth, const Texture::SharedPtr& vNormW, const Buffer::SharedPtr& reconnectionData, const Texture::SharedPtr& vbuffer);
        void FinalShadingPass(RenderContext* pRenderContext);

        Options::SharedPtr mOptions;
        Scene::SharedPtr mpScene;
        

        SampleGenerator::SharedPtr mpSampleGenerator;

        ComputePass::SharedPtr mpInitReservoirPass;
        ComputePass::SharedPtr mpGIResamplingPass;
        ComputePass::SharedPtr mpFinalShadingPass;
        ComputePass::SharedPtr mpBuildHashGridPass;

        ComputePass::SharedPtr mpReflectTypes;

        Buffer::SharedPtr mpInitialReservoir;
        Buffer::SharedPtr mpReservoirs[2];             /// store for both temporal and spatial reservoir

        Buffer::SharedPtr mpAppendBuffer;

        Buffer::SharedPtr mpCellStorage[2];
        Buffer::SharedPtr mpIndexBuffer[2];
        Buffer::SharedPtr mpCheckSumBuffer[2];
        Buffer::SharedPtr mpCellCounter[2];

        PrefixSum::SharedPtr mpPrexfixSumPass;

        float3 mPreCameraPos;
        glm::float4x4 mPreViewProj;

        bool mRecompile = true;
        bool mOptionChanged = false;

        uint giInstanceNum = 1u;
    };

}
