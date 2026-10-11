// Distances to rounded rectangles, shared by the shaders.
module sdf;

// Signed distance to the edge: negative inside, positive outside. `p` is
// relative to the center, y pointing down. `radii` is top left, top right,
// bottom right, bottom left.
public float roundedBox(float2 p, float2 half_size, float4 radii)
{
    float2 side = p.x < 0.0 ? radii.xw : radii.yz;
    float radius = p.y < 0.0 ? side.x : side.y;
    float2 q = abs(p) - (half_size - radius);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

// How much of the pixel at `pixel` lies inside `bounds`, which is left,
// top, right, bottom.
public float coverage(float2 pixel, float4 bounds, float4 radii)
{
    float2 half_size = (bounds.zw - bounds.xy) * 0.5;
    return saturate(0.5 - roundedBox(pixel - bounds.xy - half_size, half_size, radii));
}
