// Draws one image into another, covering the whole destination.

import sdf;

struct Varyings
{
    float4 position : SV_Position;
    float2 uv;
};

static const int mode_copy = 0;
static const int mode_downsample = 1;
static const int mode_upsample = 2;
static const int mode_composite = 3;

// The fields are ordered so that none needs padding in front of it.
cbuffer Filter
{
    // Half a texel of the source, times the blur offset.
    float2 half_texel;
    int mode;

    // The rest is for compositing a layer onto what is under it. The layer
    // is shown `scale` times its size around `origin`.
    float scale;
    float2 size;
    float2 origin;
    // Left, top, right, bottom and the four radii. The layer's own clip
    // is in the layer's pixels; the outer one is in the destination's.
    float4 clip;
    float4 clip_radii;
    float4 outer_clip;
    float4 outer_clip_radii;
    float opacity;
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
    if (mode == mode_composite)
    {
        // Pixels count from the top left, texture coordinates from the
        // bottom left.
        float2 pixel = float2(uv.x, 1.0 - uv.y) * size;
        float2 inner = origin + (pixel - origin) / scale;
        float2 inner_uv = float2(inner.x, size.y - inner.y) / size;
        float visible = coverage(inner, clip, clip_radii) *
            coverage(pixel, outer_clip, outer_clip_radii);
        return source.Sample(inner_uv) * visible * opacity;
    }
    return source.Sample(uv);
}
