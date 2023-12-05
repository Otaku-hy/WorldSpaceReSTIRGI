#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

struct GIParameter
{
    uint2 frameDim = { };
    uint frameCount = 0u;
    uint instanceID = 0u;

    float3 sceneBBMin = { };
    float fov = 0.f;

    float4 _pad = { };
    float minCellSize = 0.0f;   
};

END_NAMESPACE_FALCOR
