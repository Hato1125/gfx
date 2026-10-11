#version 300 es

out vec2 v0;

void main()
{
    vec2 _27 = vec2(float(uint(gl_VertexID) & 1u), float(uint(gl_VertexID) >> uint(1)));
    gl_Position = vec4((_27 * 2.0) - vec2(1.0), 0.0, 1.0);
    v0 = _27;
}

