#version 450
// The vertex shader: three vertices, positions and colors built in, rotated by the angle the
// program pushes each frame. gl_VertexIndex is 0, 1, 2 for the three invocations of a draw of 3.

layout(push_constant) uniform Push {
    float angle;
    float aspect;
} push;

layout(location = 0) out vec3 color;

const vec2 positions[3] = vec2[](vec2(0.0, -0.6), vec2(0.55, 0.5), vec2(-0.55, 0.5));
const vec3 colors[3] = vec3[](vec3(1.0, 0.2, 0.2), vec3(0.2, 1.0, 0.3), vec3(0.3, 0.4, 1.0));

void main() {
    float c = cos(push.angle);
    float s = sin(push.angle);
    vec2 p = positions[gl_VertexIndex];
    vec2 rotated = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    // Divide x by the aspect ratio so the triangle isn't stretched by a non-square window.
    gl_Position = vec4(rotated.x / push.aspect, rotated.y, 0.0, 1.0);
    color = colors[gl_VertexIndex];
}
