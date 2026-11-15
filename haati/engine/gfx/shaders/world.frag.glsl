// texture * vertex color. Untextured draws bind the 1x1 white texture.
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 c = texture(tex, frag_uv) * frag_color;
    // Emit linear color into the HDR target so single-pass composite linear_to_srgb stays exact.
    out_color = vec4(pow(max(c.rgb, vec3(0.0)), vec3(2.2)), c.a);
}
