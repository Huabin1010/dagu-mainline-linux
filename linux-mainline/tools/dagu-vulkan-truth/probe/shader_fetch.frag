#version 450
layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput u_in;
layout(location = 0) out vec4 o_color;
void main()
{
    vec4 prev = subpassLoad(u_in);
    o_color = vec4(prev.r, prev.g, 1.0 - prev.b, 1.0);
}
