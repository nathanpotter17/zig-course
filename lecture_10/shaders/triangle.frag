#version 450
// The fragment shader: the color interpolated across the triangle from the three vertices.

layout(location = 0) in vec3 color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(color, 1.0);
}
