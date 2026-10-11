#version 300 es
precision mediump float;
precision highp int;

uniform highp sampler2D atlas;
uniform highp sampler2D color_atlas;
uniform highp sampler2D picture;

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
        highp vec2 _259 = (v6.zw - v6.xy) * 0.5;
        highp vec2 _261 = (v1 - v6.xy) - _259;
        highp vec2 _265;
        if (_261.x < 0.0)
        {
            _265 = v10.xw;
        }
        else
        {
            _265 = v10.yz;
        }
        highp float _266;
        if (_261.y < 0.0)
        {
            _266 = _265.x;
        }
        else
        {
            _266 = _265.y;
        }
        highp vec2 _289 = abs(_261) - (_259 - vec2(_266));
        highp float _264 = clamp(0.5 - ((min(max(_289.x, _289.y), 0.0) + length(max(_289, vec2(0.0)))) - _266), 0.0, 1.0);
        if (v9 == 1.0)
        {
            uvec2 _305 = uvec2(textureSize(atlas, 0));
            entryPointParam_fragmentMain = (vec4(v3.xyz * v3.w, v3.w) * texture(atlas, v8 / vec2(float(_305.x), float(_305.y))).x) * _264;
            break;
        }
        if (v9 == 2.0)
        {
            uvec2 _326 = uvec2(textureSize(color_atlas, 0));
            entryPointParam_fragmentMain = (texture(color_atlas, v8 / vec2(float(_326.x), float(_326.y))) * v3.w) * _264;
            break;
        }
        highp vec2 _335;
        if (v0.x < 0.0)
        {
            _335 = v4.xw;
        }
        else
        {
            _335 = v4.yz;
        }
        highp float _336;
        if (v0.y < 0.0)
        {
            _336 = _335.x;
        }
        else
        {
            _336 = _335.y;
        }
        highp vec2 _359 = abs(v0) - (v2 - vec2(_336));
        highp float _368 = (min(max(_359.x, _359.y), 0.0) + length(max(_359, vec2(0.0)))) - _336;
        highp vec4 fill;
        if (v9 == 3.0)
        {
            fill = texture(picture, v8) * v3.w;
        }
        else
        {
            fill = vec4(v3.xyz * v3.w, v3.w);
        }
        highp vec4 paint;
        if (v7 > 0.0)
        {
            paint = mix(vec4(v5.xyz * v5.w, v5.w), fill, vec4(clamp(0.5 - (_368 + v7), 0.0, 1.0)));
        }
        else
        {
            paint = fill;
        }
        entryPointParam_fragmentMain = (paint * clamp(0.5 - _368, 0.0, 1.0)) * _264;
        break;
    } while(false);
}

