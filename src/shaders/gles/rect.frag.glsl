#version 300 es
precision mediump float;
precision highp int;

in highp vec2 v0;
flat in highp vec2 v2;
flat in highp vec4 v4;
flat in highp float v7;
flat in highp vec4 v3;
flat in highp vec4 v5;
in highp vec2 v1;
flat in highp vec4 v6;
layout(location = 0) out highp vec4 entryPointParam_fragmentMain;

void main()
{
    highp vec2 _135;
    if (v0.x < 0.0)
    {
        _135 = v4.xw;
    }
    else
    {
        _135 = v4.yz;
    }
    highp float _136;
    if (v0.y < 0.0)
    {
        _136 = _135.x;
    }
    else
    {
        _136 = _135.y;
    }
    highp vec2 _159 = abs(v0) - (v2 - vec2(_136));
    highp float _168 = (min(max(_159.x, _159.y), 0.0) + length(max(_159, vec2(0.0)))) - _136;
    highp vec4 _174 = vec4(v3.xyz * v3.w, v3.w);
    highp vec4 paint;
    if (v7 > 0.0)
    {
        paint = mix(vec4(v5.xyz * v5.w, v5.w), _174, vec4(clamp(0.5 - (_168 + v7), 0.0, 1.0)));
    }
    else
    {
        paint = _174;
    }
    highp vec2 _122 = min(v1 - v6.xy, v6.zw - v1);
    entryPointParam_fragmentMain = (paint * clamp(0.5 - _168, 0.0, 1.0)) * clamp(min(_122.x, _122.y) + 0.5, 0.0, 1.0);
}

