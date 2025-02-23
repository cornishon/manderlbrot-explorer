#version 430

layout(set=1, binding=0) uniform readonly Uniforms {
    mat4 mvp;
};

layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec4 color;

layout(location=0) out vec2 texcoord;
layout(location=1) out vec4 out_color;

void main() {
    texcoord = uv;
    out_color = color;
    gl_Position = mvp * vec4(pos, 0, 1);
}

