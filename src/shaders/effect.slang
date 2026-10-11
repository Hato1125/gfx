// Draws one image into another, covering the whole destination.

struct Varyings
{
    float4 position : SV_Position;
    float2 uv;
};

static const int mode_copy = 0;
static const int mode_downsample = 1;
static const int mode_upsample = 2;

cbuffer Filter
{
    // Half a texel of the source, times the blur offset.
    float2 half_texel;
    int mode;
};

Sampler2D source;

[shader("vertex")]
Varyings vertexMain(uint vertex : SV_VulkanVertexID)
{
    Varyings output;
    output.uv = float2(float(vertex & 1), float(vertex >> 1));
    output.position = float4(output.uv * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

float4 at(float2 uv, float x, float y)
{
    return source.Sample(uv + float2(x, y) * half_texel);
}

// The two blur modes are the passes of dual Kawase blur. The sample
// positions and weights are the ones from Marius Bjørge's
// "Bandwidth-Efficient Rendering" (SIGGRAPH 2015).
[shader("fragment")]
float4 fragmentMain(Varyings input) : SV_Target
{
    float2 uv = input.uv;
    if (mode == mode_downsample)
    {
        float4 corners = at(uv, -1, -1) + at(uv, 1, 1) + at(uv, 1, -1) + at(uv, -1, 1);
        return (source.Sample(uv) * 4.0 + corners) / 8.0;
    }
    if (mode == mode_upsample)
    {
        float4 edges = at(uv, -2, 0) + at(uv, 0, 2) + at(uv, 2, 0) + at(uv, 0, -2);
        float4 corners = at(uv, -1, 1) + at(uv, 1, 1) + at(uv, 1, -1) + at(uv, -1, -1);
        return (edges + corners * 2.0) / 12.0;
    }
    return source.Sample(uv);
}
