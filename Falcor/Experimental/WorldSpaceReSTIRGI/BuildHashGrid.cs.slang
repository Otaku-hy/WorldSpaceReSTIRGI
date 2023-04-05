import HashBuildStructure;
import Params;

struct GridBuilder
{
    ByteAddressBuffer indexBuffer;

    StructuredBuffer<HashAppendData> appendBuffer;
    RWStructuredBuffer<uint> cellStorage;

    GIParameter params;

    void execute(uint2 pixel)
    {
        uint linearIdx = pixel.y * params.frameDim.x + pixel.x;
        HashAppendData data = appendBuffer[linearIdx];
        if (data.isValid == 0)
            return;

        uint baseIdx = indexBuffer.Load(data.cellIdx);
        cellStorage[baseIdx + data.inCellIdx] = data.reservoirIdx;
    }

};

ParameterBlock<GridBuilder> gridBuilder;

[numthreads(16,16,1)]
void main(uint3 dispathThreadId : SV_DispatchThreadID)
{
    gridBuilder.execute(dispathThreadId.xy);
}
