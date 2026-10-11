#version 300 es
precision mediump float;
precision highp int;

layout(std140) uniform SLANG_ParameterGroup_Filter_std140
{
    highp vec2 half_texel;
    int mode;
} Filter;

uniform highp sampler2D source;

in highp vec2 v0;
layout(location = 0) out highp vec4 entryPointParam_fragmentMain;

void main()
{
    do
    {
        if (Filter.mode == 1)
        {
            entryPointParam_fragmentMain = ((texture(source, v0) * 4.0) + (((texture(source, v0 + (vec2(-1.0) * Filter.half_texel)) + texture(source, v0 + Filter.half_texel)) + texture(source, v0 + (vec2(1.0, -1.0) * Filter.half_texel))) + texture(source, v0 + (vec2(-1.0, 1.0) * Filter.half_texel)))) * vec4(0.125);
            break;
        }
        if (Filter.mode == 2)
        {
            entryPointParam_fragmentMain = ((((texture(source, v0 + (vec2(-2.0, 0.0) * Filter.half_texel)) + texture(source, v0 + (vec2(0.0, 2.0) * Filter.half_texel))) + texture(source, v0 + (vec2(2.0, 0.0) * Filter.half_texel))) + texture(source, v0 + (vec2(0.0, -2.0) * Filter.half_texel))) + ((((texture(source, v0 + (vec2(-1.0, 1.0) * Filter.half_texel)) + texture(source, v0 + Filter.half_texel)) + texture(source, v0 + (vec2(1.0, -1.0) * Filter.half_texel))) + texture(source, v0 + (vec2(-1.0) * Filter.half_texel))) * 2.0)) * vec4(0.083333335816860198974609375);
            break;
        }
        entryPointParam_fragmentMain = texture(source, v0);
        break;
    } while(false);
}

