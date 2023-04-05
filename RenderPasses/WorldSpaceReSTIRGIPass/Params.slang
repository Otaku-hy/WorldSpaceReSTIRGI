#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

struct PTRuntimeParams
{
    uint2 frameDim = { };
    uint frameCount = 0u;
    uint numGIInstance = 1u;
    uint currentGIInstance = 1u;
};

END_NAMESPACE_FALCOR
