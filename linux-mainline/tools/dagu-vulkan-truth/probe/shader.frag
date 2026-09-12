#version 450
layout(location = 0) out vec4 o_color;
void main()
{
    uint x = uint(gl_FragCoord.x);
    uint y = uint(gl_FragCoord.y);
    o_color = vec4(float(x & 255u) / 255.0,
                   float(y & 255u) / 255.0,
                   float((x ^ y) & 255u) / 255.0,
                   1.0);
}
