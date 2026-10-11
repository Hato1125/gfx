#version 300 es
precision mediump float;
precision highp int;

uniform highp sampler2D atlas;
uniform highp sampler2D color_atlas;

in highp vec2 v1;
flat in highp vec4 v6;
flat in highp vec4 v10;
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
        highp vec2 _237 = (v6.zw - v6.xy) * 0.5;
        highp vec2 _239 = (v1 - v6.xy) - _237;
        highp vec2 _243;
        if (_239.x < 0.0)
        {
            _243 = v10.xw;
        }
        else
        {
            _243 = v10.yz;
        }
        highp float _244;
        if (_239.y < 0.0)
        {
            _244 = _243.x;
        }
        else
        {
            _244 = _243.y;
        }
        highp vec2 _267 = abs(_239) - (_237 - vec2(_244));
        highp float _242 = clamp(0.5 - ((min(max(_267.x, _267.y), 0.0) + length(max(_267, vec2(0.0)))) - _244), 0.0, 1.0);
        if (v9 == 1.0)
        {
            uvec2 _283 = uvec2(textureSize(atlas, 0));
            entryPointParam_fragmentMain = (vec4(v3.xyz * v3.w, v3.w) * texture(atlas, v8 / vec2(float(_283.x), float(_283.y))).x) * _242;
            break;
        }
        if (v9 == 2.0)
        {
            uvec2 _304 = uvec2(textureSize(color_atlas, 0));
            entryPointParam_fragmentMain = (texture(color_atlas, v8 / vec2(float(_304.x), float(_304.y))) * v3.w) * _242;
            break;
        }
        highp vec2 _313;
        if (v0.x < 0.0)
        {
            _313 = v4.xw;
        }
        else
        {
            _313 = v4.yz;
        }
        highp float _314;
        if (v0.y < 0.0)
        {
            _314 = _313.x;
        }
        else
        {
            _314 = _313.y;
        }
        highp vec2 _337 = abs(v0) - (v2 - vec2(_314));
        highp float _346 = (min(max(_337.x, _337.y), 0.0) + length(max(_337, vec2(0.0)))) - _314;
        highp vec4 _352 = vec4(v3.xyz * v3.w, v3.w);
        highp vec4 paint;
        if (v7 > 0.0)
        {
            paint = mix(vec4(v5.xyz * v5.w, v5.w), _352, vec4(clamp(0.5 - (_346 + v7), 0.0, 1.0)));
        }
        else
        {
            paint = _352;
        }
        entryPointParam_fragmentMain = (paint * clamp(0.5 - _346, 0.0, 1.0)) * _242;
        break;
    } while(false);
}

