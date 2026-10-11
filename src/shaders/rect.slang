// One instance is one rectangle. The four corners come from the vertex
// index, so there is no per-vertex buffer.

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
};

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
};

cbuffer Frame
{
    float2 viewport;
};

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
    return output;
}

// Signed distance to the edge: negative inside, positive outside.
float roundedBox(float2 p, float2 half_size, float4 radii)
{
    float2 side = p.x < 0.0 ? radii.xw : radii.yz;
    float radius = p.y < 0.0 ? side.x : side.y;
    float2 q = abs(p) - (half_size - radius);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
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
    float d = roundedBox(input.local, input.half_size, input.radii);
    float shape = saturate(0.5 - d);

    float inside = saturate(0.5 - (d + input.border_width));
    float4 fill = premultiply(input.fill);
    float4 paint = input.border_width > 0.0
        ? lerp(premultiply(input.border_color), fill, inside)
        : fill;

    float2 margin = min(input.pixel - input.clip.xy, input.clip.zw - input.pixel);
    float visible = saturate(min(margin.x, margin.y) + 0.5);

    return paint * shape * visible;
}
