// Single-pass HDR composite: merges linear scene HDR + bloom mip0, applies
// exposure and Narkowicz ACES fitted curve, then encodes linear -> sRGB.
// SDL_GPU SPIR-V convention: fragment samplers set=2, fragment UBO set=3.
#version 450

layout(location = 0) in vec2 frag_uv;

layout(set = 2, binding = 0) uniform sampler2D u_hdr;
layout(set = 2, binding = 1) uniform sampler2D u_bloom;

layout(set = 3, binding = 0) uniform CompositeUBO {
    vec4 params; // x = exposure, y = bloom_intensity, z = tonemap_enabled (>0.5), w = bloom_enabled (>0.5)
};

layout(location = 0) out vec4 out_color;

vec3 aces_fitted(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec4 hdr = texture(u_hdr, frag_uv);
    vec3 col = max(hdr.rgb, vec3(0.0));
    if (params.w > 0.5) {
        vec3 bloom = max(texture(u_bloom, frag_uv).rgb, vec3(0.0));
        col += bloom * params.y;
    }
    col *= params.x;
    if (params.z > 0.5) {
        col = aces_fitted(col);
    } else {
        col = clamp(col, vec3(0.0), vec3(1.0));
    }
    vec3 srgb = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
    out_color = vec4(srgb, clamp(hdr.a, 0.0, 1.0));
}
