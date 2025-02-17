#version 430

layout(set=2, binding=0) uniform texture2D Texture;
layout(set=2, binding=0) uniform sampler Sampler;

layout(location=0) in vec2 texcoord;

layout(location=0) out vec4 FinalColor;

void main() {
    FinalColor = texture(sampler2D(Texture, Sampler), texcoord);
}
