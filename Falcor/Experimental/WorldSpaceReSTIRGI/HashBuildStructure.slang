import Utils.Math.HashUtils;
import Params;

struct HashAppendData
{
    uint isValid;
    uint reservoirIdx;
    uint cellIdx;
    uint inCellIdx;
};


uint pcg32(uint input)
{
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

uint BinaryNorm(float3 norm)
{
    uint a = norm.x > 0.f ? 1 : 0;
    uint b = norm.y > 0.f ? 1 : 0;
    uint c = norm.z > 0.f ? 1 : 0;
    return a * 100 + b * 10 + c;
}

float CalculateCellSize(float3 pos, float3 cameraPos, GIParameter params)
{
    float cellSizeStep = length(pos - cameraPos) * tan(65 * params.fov * max(1.0 / params.frameDim.y, params.frameDim.y / float((params.frameDim.x * params.frameDim.x))));
    int logStep = floor(log2(cellSizeStep / params.minCellSize));
   
    return params.minCellSize * max(0.01f, exp2(logStep));
}

int FindOrInsertCell(float3 pos, float3 norm, float cellSize, GIParameter params, RWByteAddressBuffer checkSumBuffer)
{
    uint3 p = floor((pos - params.sceneBBMin) / cellSize);
    uint normprint = BinaryNorm(norm);

    uint cellIndex = pcg32(normprint + pcg32(cellSize + pcg32(p.z + pcg32(p.y + pcg32(p.x))))) % 100000;
    uint checkSum = max(jenkinsHash(normprint + jenkinsHash(cellSize + jenkinsHash(p.z + jenkinsHash(p.y + jenkinsHash(p.x))))), 1);

    for (uint i = 0; i < 32; i++)
    {
        uint idx = cellIndex * 32 + i;
        uint checkSumPre;

        checkSumBuffer.InterlockedCompareExchange(idx, 0, checkSum, checkSumPre);
        if (checkSumPre == 0 || checkSumPre == checkSum)
            return idx;
    }

    return -1;
}

int FindCell(float3 pos, float3 norm, float cellSize, GIParameter params, RWByteAddressBuffer checkSumBuffer)
{
    uint3 p = floor((pos - params.sceneBBMin) / cellSize);
    uint normprint = BinaryNorm(norm);

    uint cellIndex = pcg32(normprint + pcg32(cellSize + pcg32(p.z + pcg32(p.y + pcg32(p.x))))) % 100000;
    uint checkSum = max(jenkinsHash(normprint + jenkinsHash(cellSize + jenkinsHash(p.z + jenkinsHash(p.y + jenkinsHash(p.x))))), 1);


    for (uint i = 0; i < 32; i++)
    {
        uint idx = cellIndex * 32 + i;

        if (checkSumBuffer.Load(idx) == checkSum)
            return idx;
    }

    return -1;
}

int FindCell(float3 pos, float3 norm, float cellSize, GIParameter params, ByteAddressBuffer checkSumBuffer)
{
    uint3 p = floor((pos - params.sceneBBMin) / cellSize);
    uint normprint = BinaryNorm(norm);

    uint cellIndex = pcg32(normprint + pcg32(cellSize + pcg32(p.z + pcg32(p.y + pcg32(p.x))))) % 100000;
    uint checkSum = max(jenkinsHash(normprint + jenkinsHash(cellSize + jenkinsHash(p.z + jenkinsHash(p.y + jenkinsHash(p.x))))), 1);


    for (uint i = 0; i < 32; i++)
    {
        uint idx = cellIndex * 32 + i;

        if (checkSumBuffer.Load(idx) == checkSum)
            return idx;
    }

    return -1;
}
/*
int FindCellPre(float3 pos, float3 norm)
{
    float cellSize = CalculateCellSize(pos, true);
    uint3 p = floor((pos - params.sceneBBMin) / cellSize);
    uint normprint = BinaryNorm(norm);

    uint cellIndex = pcg32(normprint + pcg32(cellSize + pcg32(p.z + pcg32(p.y + pcg32(p.x))))) % 100000;
    uint checkSum = max(xxhash32(normprint + xxhash32(cellSize + xxhash32(p.z + xxhash32(p.y + xxhash32(p.x))))), 1);

    //uint cellIndex = pcg32(cellSize+pcg32(p.z + pcg32(p.y + pcg32(p.x)))) % 100000;
    //uint checkSum = max(xxhash32(cellSize + xxhash32(p.z + xxhash32(p.y + xxhash32(p.x)))),1);

    for (uint i = 0; i < 32; i++)
    {
        uint idx = cellIndex * 32 + i;

        if (checksumBufferPre.Load(idx) == checkSum)
            return idx;
    }

    return -1;
}*/
