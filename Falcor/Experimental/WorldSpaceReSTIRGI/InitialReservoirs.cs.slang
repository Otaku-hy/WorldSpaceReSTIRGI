import InitialSamples;
import GIReservoir;
import HashBuildStructure;
import Params;
import GIFinalSample;

struct SampleManager
{
    StructuredBuffer<InitialSample> initialSamples;
    RWStructuredBuffer<Reservoir> initialReservoirs;
    RWStructuredBuffer<HashAppendData> appendBuffer;

    RWStructuredBuffer<FinalSample> finalSample;

    RWByteAddressBuffer checkSum;
    RWByteAddressBuffer cellCounters;

    GIParameter params;

    float3 cameraPos;

    uint ToLinearIndex(uint2 pixel)
    {
        return pixel.y * params.frameDim.x + pixel.x;
    }

    Reservoir SetGIReservoir(InitialSample s)
    {
        Reservoir initialReservoir = { };

        initialReservoir.vPos = s.preRcVertexPos;
        initialReservoir.vNorm = s.preRcVertexNorm;
        initialReservoir.sPos = s.rcVertexPos;
        initialReservoir.sNorm = s.rcVertexNorm;
        initialReservoir.radiance = s.rcVertexLo;

        /*if(dot(initialReservoir.z.vNorm,initialReservoir.z.sPos - initialReservoir.z.vPos) < 0)
        {
            initialReservoir.z.vNorm *= -1;
        }
        if(dot(initialReservoir.z.sNorm,initialReservoir.z.vPos - initialReservoir.z.sPos) < 0)
        {
            initialReservoir.z.sNorm *= -1;
        }*/

        initialReservoir.weightF = s.pdf > 0.f ? 1.f / s.pdf : 0.f;
        initialReservoir.M = 1u;
        initialReservoir.age = 0;

        return initialReservoir;
    }

    HashAppendData BuildHashAppendData(float3 pos, float3 norm, uint linearIdx)
    {
        HashAppendData data = { };
        data.reservoirIdx = linearIdx;
        if (any(norm != 0))
        {
            float cellSize = CalculateCellSize(pos, cameraPos, params);
            int cellIdx = FindOrInsertCell(pos, norm, cellSize, params, checkSum);

            if (cellIdx != -1)
            {
                uint inCellIdx;
                cellCounters.InterlockedAdd(cellIdx, 1, inCellIdx);
                data.isValid = 1;
                data.cellIdx = cellIdx;
                data.inCellIdx = inCellIdx;
            }
        }
    
        return data;
    }

    void execute(uint2 pixel)
    {
        uint linearIdx = ToLinearIndex(pixel);
        Reservoir r = SetGIReservoir(initialSamples[linearIdx]);
        HashAppendData data = BuildHashAppendData(r.vPos, r.vNorm, linearIdx);

        FinalSample s = { };
        s.Li = data.isValid > 0 ? float3(sin(data.cellIdx), cos(data.cellIdx), cos(data.cellIdx * 2.7445f + 1.4212f)) : 0.f;

        initialReservoirs[linearIdx] = r;
        appendBuffer[linearIdx] = data;
        //finalSample[linearIdx] = s;
    }
};

ParameterBlock<SampleManager> sampleManager;

[numthreads(16,16,1)]
void main(uint3 dispathThreadId : SV_DispatchThreadID)
{
    sampleManager.execute(dispathThreadId.xy);
}
