#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

struct GIParameter
{
    uint2 frameDim = { };
    uint frameCount = 0u;
    uint instanceID = 0u;

    float fov = 0.f;
    float minCellSize = 0.f;
    float3 sceneBBMin = { };

    uint _pad;
};

END_NAMESPACE_FALCOR
