#include "Scene/ScenePrimitiveDefines.slangh"

import Scene.Scene;
import Utils.Math.MathHelpers;
import Rendering.Materials.TexLODHelpers;
import Rendering.Materials.IBxDF;
__exported import Scene.HitInfo;
__exported import Scene.Shading;

VertexData LoadVertexData(const HitInfo hit)
{
    const TriangleHit thit = hit.getTriangleHit();
    VertexData vd = gScene.getVertexData(thit);

    return vd;
}


ShadingData LoadShadingData(const HitInfo hit,const float3 viewDir, const float lod, const bool isPrimary)
{
    
    const TriangleHit thit = hit.getTriangleHit();
    VertexData vd = gScene.getVertexData(thit);
    uint materialID = gScene.getMaterialID(thit.instanceID);
    ShadingData sd = prepareShadingData(vd, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -viewDir, lod);

    //sd.setActiveLobes((uint) LobeType::Diffuse);

    if (isPrimary)
        adjustShadingNormal(sd, vd);

    return sd;
}
