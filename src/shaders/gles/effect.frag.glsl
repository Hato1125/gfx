#version 300 es
precision mediump float;
precision highp int;

layout(std140) uniform SLANG_ParameterGroup_Filter_std140
{
    highp vec2 half_texel;
    int mode;
    highp float scale;
    highp vec2 size;
    highp vec2 origin;
    highp vec4 clip;
    highp vec4 clip_radii;
    highp vec4 outer_clip;
    highp vec4 outer_clip_radii;
    highp float opacity;
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
        if (Filter.mode == 3)
        {
            highp vec2 pixel = vec2(v0.x, 1.0 - v0.y) * Filter.size;
            highp vec2 inner = Filter.origin + ((pixel - Filter.origin) / vec2(Filter.scale));
            highp vec2 _364 = (Filter.clip.zw - Filter.clip.xy) * 0.5;
            highp vec2 _366 = (inner - Filter.clip.xy) - _364;
            highp vec2 _370;
            if (_366.x < 0.0)
            {
                _370 = Filter.clip_radii.xw;
            }
            else
            {
                _370 = Filter.clip_radii.yz;
            }
            highp float _371;
            if (_366.y < 0.0)
            {
                _371 = _370.x;
            }
            else
            {
                _371 = _370.y;
            }
            highp vec2 _394 = abs(_366) - (_364 - vec2(_371));
            highp vec2 _409 = (Filter.outer_clip.zw - Filter.outer_clip.xy) * 0.5;
            highp vec2 _411 = (pixel - Filter.outer_clip.xy) - _409;
            highp vec2 _415;
            if (_411.x < 0.0)
            {
                _415 = Filter.outer_clip_radii.xw;
            }
            else
            {
                _415 = Filter.outer_clip_radii.yz;
            }
            highp float _416;
            if (_411.y < 0.0)
            {
                _416 = _415.x;
            }
            else
            {
                _416 = _415.y;
            }
            highp vec2 _439 = abs(_411) - (_409 - vec2(_416));
            entryPointParam_fragmentMain = (texture(source, vec2(inner.x, Filter.size.y - inner.y) / Filter.size) * (clamp(0.5 - ((min(max(_394.x, _394.y), 0.0) + length(max(_394, vec2(0.0)))) - _371), 0.0, 1.0) * clamp(0.5 - ((min(max(_439.x, _439.y), 0.0) + length(max(_439, vec2(0.0)))) - _416), 0.0, 1.0))) * Filter.opacity;
            break;
        }
        entryPointParam_fragmentMain = texture(source, v0);
        break;
    } while(false);
}

