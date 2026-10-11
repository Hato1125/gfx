#version 300 es

layout(std140) uniform SLANG_ParameterGroup_Frame_std140
{
    vec2 viewport;
} Frame;

layout(location = 0) in vec4 instance_rect;
layout(location = 1) in vec4 instance_fill;
layout(location = 2) in vec4 instance_radii;
layout(location = 3) in vec4 instance_border_color;
layout(location = 4) in vec4 instance_clip;
layout(location = 5) in float instance_border_width;
layout(location = 6) in vec4 instance_uv;
layout(location = 7) in float instance_kind;
layout(location = 8) in vec4 instance_clip_radii;
out vec2 v0;
out vec2 v1;
flat out vec2 v2;
flat out vec4 v3;
flat out vec4 v4;
flat out vec4 v5;
flat out vec4 v6;
flat out float v7;
out vec2 v8;
flat out float v9;
flat out vec4 v10;

void main()
{
    vec2 _33 = instance_rect.zw * 0.5;
    vec2 _44 = ((vec2(float(uint(gl_VertexID) & 1u), float(uint(gl_VertexID) >> uint(1))) * 2.0) - vec2(1.0)) * (_33 + vec2(1.0));
    vec2 _51 = (instance_rect.xy + _33) + _44;
    vec2 ndc = ((_51 / Frame.viewport) * 2.0) - vec2(1.0);
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    v0 = _44;
    v1 = _51;
    v2 = _33;
    v3 = instance_fill;
    v4 = instance_radii;
    v5 = instance_border_color;
    v6 = instance_clip;
    v7 = instance_border_width;
    v8 = mix(instance_uv.xy, instance_uv.zw, (_44 / max(instance_rect.zw, vec2(0.001000000047497451305389404296875))) + vec2(0.5));
    v9 = instance_kind;
    v10 = instance_clip_radii;
}

