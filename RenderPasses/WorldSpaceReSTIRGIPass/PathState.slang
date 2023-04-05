import Utils.Math.PackedFormats;
import Scene.HitInfo;
import Utils.Sampling.SampleGenerator;

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
    uint16_t flags;
    uint8_t currentVertexIndex; //vertexIndex along the path, intialized value is 1
    
    bool isLastVertexClassifiedAsRough;

    float3 origin;
    float3 norm;
    float3 direction;
    
    float pdf;

    float3 prefixThp;
    float3 thp;

    float3 LiForDelta;

    float3 prefixPathRadiance;
    float3 rcVertexRadiance;

    PackedHitInfo preRcVertexHit;
    float3 preRcVertexWo;

    SampleGenerator sg;

    [mutating] void SetActive()
    {
        SetFlag(PathFlags::active);
    }
    [mutating] void SetTerminate()
    {
        SetFlag(PathFlags::active, false);
    }
    [mutating] void SetSpecular(bool value = true)
    {
        SetFlag(PathFlags::specular,value);
    }
    [mutating] void SetDelta(bool value = true)
    {
        SetFlag(PathFlags::delta,value);
    }
    [mutating] void SetSpecularBounce(bool value = true)
    {
        SetFlag(PathFlags::specularBounce, value);
    }
    [mutating] void SetDiffuseBounce(bool value = true)
    {
        SetFlag(PathFlags::diffuseBounce, value);
    }
    [mutating] void SetSpecularPath(bool value = true)    ///indicate the whole path has at least one specular scatter event
    {
        SetFlag(PathFlags::pathHasSpecularBounce, value);
    }
    [mutating] void SetLightSampled(bool value = true)
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
    bool IsSpecular()
    {
        return HasFlag(PathFlags::specular);
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
    bool 
    

    bool HasFlag(PathFlags flag)
    {
        return (flags & uint(flag)) != 0;
    }

    [mutating] void SetFlag(PathFlags flag, bool value = true)
    {
        if (value)
            flags |= uint16_t(uint(flag));
        else
            flags &= ~uint16_t(uint(flag));
    }

    Ray GenerateScatterRay()
    {
        return Ray(origin,direction,0.f,kRayTMax);
    }
};
