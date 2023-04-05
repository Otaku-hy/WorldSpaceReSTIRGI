import GIFinalSample;
import Params;
import GIReservoir;
import InitialSamples;

struct FinalSampleGenerator
{
    StructuredBuffer<Reservoir> currentReservoirs;
    RWStructuredBuffer<FinalSample> finalSample;

    GIParameter params;

    uint ToLinearIndex(uint2 pixel)
    {
        return pixel.y * params.frameDim.x + pixel.x;
    }

    void execute(uint2 pixel)
    {
        uint linearIndex = ToLinearIndex(pixel);
        Reservoir r = GetReservoirs(currentReservoirs, linearIndex, 1, params.frameDim.x * params.frameDim.y);
        FinalSample s = { };
        s.dir = normalize(r.sPos - r.vPos);
        s.Li = r.radiance * max(0.f, r.weightF);

        finalSample[linearIndex] = s;
    }
};

ParameterBlock<FinalSampleGenerator> finalSampleGenerator;

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    finalSampleGenerator.execute(dispatchThreadId.xy);
}
