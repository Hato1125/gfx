// One instance is one rectangle or one glyph. The four corners come from the
// vertex index, so there is no per-vertex buffer.

import sdf;

struct Instance
{
    [[vk::location(0)]] float4 rect;
    [[vk::location(1)]] float4 fill;
    // Top left, top right, bottom right, bottom left.
    [[vk::location(2)]] float4 radii;
    [[vk::location(3)]] float4 border_color;
    // Left, top, right, bottom.
    [[vk::location(4)]] float4 clip;
    [[vk::location(5)]] float border_width;
    // Where a glyph sits in its atlas: left, top, right, bottom, in pixels.
    [[vk::location(6)]] float4 uv;
    [[vk::location(7)]] float kind;
    // The corners of the clip.
    [[vk::location(8)]] float4 clip_radii;
};

static const float kind_shape = 0.0;
static const float kind_glyph = 1.0;
static const float kind_color_glyph = 2.0;

struct Varyings
{
    float4 position : SV_Position;
    // Relative to the center of the rectangle, y pointing down.
    float2 local;
    float2 pixel;
    nointerpolation float2 half_size;
    nointerpolation float4 fill;
    nointerpolation float4 radii;
    nointerpolation float4 border_color;
    nointerpolation float4 clip;
    nointerpolation float border_width;
    float2 uv;
    nointerpolation float kind;
    nointerpolation float4 clip_radii;
};

cbuffer Frame
{
    float2 viewport;
};

// One channel: how much of each pixel a glyph covers.
Sampler2D atlas;
// Glyphs that bring their own colors, premultiplied by alpha.
Sampler2D color_atlas;

float2 normalized(Sampler2D image, float2 pixel)
{
    uint width, height;
    image.GetDimensions(width, height);
    return pixel / float2(float(width), float(height));
}

[shader("vertex")]
Varyings vertexMain(Instance instance, uint vertex : SV_VulkanVertexID)
{
    Varyings output;
    float2 unit = float2(float(vertex & 1), float(vertex >> 1));

    // One pixel larger on every side to leave room for the antialiased edge.
    output.half_size = instance.rect.zw * 0.5;
    output.local = (unit * 2.0 - 1.0) * (output.half_size + 1.0);
    output.pixel = instance.rect.xy + output.half_size + output.local;

    float2 ndc = output.pixel / viewport * 2.0 - 1.0;
    output.position = float4(ndc.x, -ndc.y, 0.0, 1.0);

    output.fill = instance.fill;
    output.radii = instance.radii;
    output.border_color = instance.border_color;
    output.clip = instance.clip;
    output.border_width = instance.border_width;

    // The extra pixel around a glyph reads the empty gap the atlas leaves
    // between glyphs.
    float2 across = output.local / max(instance.rect.zw, 0.001) + 0.5;
    output.uv = lerp(instance.uv.xy, instance.uv.zw, across);
    output.kind = instance.kind;
    output.clip_radii = instance.clip_radii;
    return output;
}

float4 premultiply(float4 color)
{
    return float4(color.rgb * color.a, color.a);
}

// The result is premultiplied by alpha so that layers drawn offscreen keep a
// correct alpha and can be blended onto their parent.
[shader("fragment")]
float4 fragmentMain(Varyings input) : SV_Target
{
    float visible = coverage(input.pixel, input.clip, input.clip_radii);

    if (input.kind == kind_glyph)
    {
        float coverage = atlas.Sample(normalized(atlas, input.uv)).r;
        return premultiply(input.fill) * coverage * visible;
    }
    if (input.kind == kind_color_glyph)
    {
        return color_atlas.Sample(normalized(color_atlas, input.uv)) * input.fill.a * visible;
    }

    float d = roundedBox(input.local, input.half_size, input.radii);
    float shape = saturate(0.5 - d);

    float inside = saturate(0.5 - (d + input.border_width));
    float4 fill = premultiply(input.fill);
    float4 paint = input.border_width > 0.0
        ? lerp(premultiply(input.border_color), fill, inside)
        : fill;

    return paint * shape * visible;
}
