#version 300 es
precision mediump float;
precision highp int;

uniform highp sampler2D atlas;
uniform highp sampler2D color_atlas;

in highp vec2 v1;
flat in highp vec4 v6;
flat in highp float v9;
in highp vec2 v8;
flat in highp vec4 v3;
layout(location = 0) out highp vec4 entryPointParam_fragmentMain;
in highp vec2 v0;
flat in highp vec2 v2;
flat in highp vec4 v4;
flat in highp float v7;
flat in highp vec4 v5;

void main()
{
    do
    {
        highp vec2 _29 = min(v1 - v6.xy, v6.zw - v1);
        highp float _36 = clamp(min(_29.x, _29.y) + 0.5, 0.0, 1.0);
        if (v9 == 1.0)
        {
            uvec2 _231 = uvec2(textureSize(atlas, 0));
            entryPointParam_fragmentMain = (vec4(v3.xyz * v3.w, v3.w) * texture(atlas, v8 / vec2(float(_231.x), float(_231.y))).x) * _36;
            break;
        }
        if (v9 == 2.0)
        {
            uvec2 _252 = uvec2(textureSize(color_atlas, 0));
            entryPointParam_fragmentMain = (texture(color_atlas, v8 / vec2(float(_252.x), float(_252.y))) * v3.w) * _36;
            break;
        }
        highp vec2 _261;
        if (v0.x < 0.0)
        {
            _261 = v4.xw;
        }
        else
        {
            _261 = v4.yz;
        }
        highp float _262;
        if (v0.y < 0.0)
        {
            _262 = _261.x;
        }
        else
        {
            _262 = _261.y;
        }
        highp vec2 _285 = abs(v0) - (v2 - vec2(_262));
        highp float _294 = (min(max(_285.x, _285.y), 0.0) + length(max(_285, vec2(0.0)))) - _262;
        highp vec4 _300 = vec4(v3.xyz * v3.w, v3.w);
        highp vec4 paint;
        if (v7 > 0.0)
        {
            paint = mix(vec4(v5.xyz * v5.w, v5.w), _300, vec4(clamp(0.5 - (_294 + v7), 0.0, 1.0)));
        }
        else
        {
            paint = _300;
        }
        entryPointParam_fragmentMain = (paint * clamp(0.5 - _294, 0.0, 1.0)) * _36;
        break;
    } while(false);
}

