__exported import Utils.Sampling.SampleGenerator;

struct Reservoir
{
    float3 vPos;
    float3 vNorm;
    float3 sPos;
    float3 sNorm;
    float3 radiance;

    uint M;
    float weightF; //the weight use for compute final illuminance W = Weight / (Mount * pdf)
    int age; //age the sample  > maxSampleAge will be discard


    [mutating]bool Merge(inout SampleGenerator sg, Reservoir r, float pdf, inout float weightS)
    {
        float weight = r.M * max(0.f, r.weightF) * pdf;

        weightS += weight;
        M += r.M;
    
        float random = sampleNext1D(sg);
        bool isUpdate = random * weightS <= weight;
        if (isUpdate)
        {
            sPos = r.sPos;
            sNorm = r.sNorm;
            radiance = r.radiance;
            age = r.age;
        }
        return isUpdate;
    };

    [mutating]void ComputeFinalWeight(float targetPdf, float weightS)
    {
        float weight = targetPdf * M;
        this.weightF = weight > 0.f ? weightS / weight : 0.f;
    }

};

float Luminance(float3 color)
{
    return dot(color, float3(0.299f, 0.587f, 0.114f));
}


bool IsValidPixel(int2 pixel, uint2 frameDim)
{
    if (all(pixel < frameDim) && all(pixel >= 0))
    {
        return true;
    }
    return false;
}

Reservoir GetReservoirs(StructuredBuffer<Reservoir> buffer, uint baseIndex, uint sampleIndex, uint elementCount)
{
    uint index = baseIndex + sampleIndex * elementCount;
    return buffer[index];
}

Reservoir GetReservoirs(RWStructuredBuffer<Reservoir> buffer, uint baseIndex, uint sampleIndex, uint elementCount)
{
    uint index = baseIndex + sampleIndex * elementCount;
    return buffer[index];
}

void SetReservoirs(RWStructuredBuffer<Reservoir> buffer, uint baseIndex, uint sampleIndex, uint elementCount, Reservoir reservoir)
{
    uint index = baseIndex + sampleIndex * elementCount;
    buffer[index] = reservoir;
}

