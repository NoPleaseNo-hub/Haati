// Built-in "lit" shader: texture * color with a lambert term per light,
// plus 16-tile 4096x4096 shadow atlas sampling (tiles 0..2 Dir CSM, 3 Spot,
// 4..9 Point0 cubemap, 10..15 Point1 cubemap) with 9-tap PCF via lighting_common.glsl.
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2,
// fragment uniform buffers in set 3.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

#include "lighting_common.glsl"

layout(set = 3, binding = 1) uniform LitMaterialUBO {
    vec4 u_emission; // rgb = pre-linearized emission color * intensity, w = intensity
};

layout(location = 0) out vec4 out_color;

void main() {
    vec4 base = texture(tex, frag_uv) * frag_color;
    vec3 albedo = srgb_to_linear(base.rgb);
    vec3 emissive = max(u_emission.rgb, vec3(0.0));
    float ambient = ambient_count.x;
    int count = int(ambient_count.y);
    if (count <= 0 && ambient >= 0.999) {
        out_color = vec4(albedo + emissive, base.a);
        return;
    }
    if (count <= 0 && ambient <= 0.0001) {
        out_color = vec4(emissive, base.a);
        return;
    }

    const float PI = 3.14159265359;
    vec3 n = normalize(frag_normal);
    vec3 v = normalize(cam_pos.xyz - frag_world_pos);
    float nov = max(dot(n, v), 1e-4);
    const vec3 f0 = vec3(0.04);
    const float rough = 0.65;
    const float a = rough * rough;
    const float a2 = a * a;
    const float k = ((rough + 1.0) * (rough + 1.0)) / 8.0;

    bool dir_shadow_used = false;
    vec3 lo = albedo * ambient + emissive;
    for (int i = 0; i < count; ++i) {
        GpuLight gl = lights[i];
        vec3 l;         // unit vector from fragment toward light
        vec3 L_to_frag; // direction light travels toward fragment
        float dist = 0.0;
        if (gl.pos_type.w < 0.5) {
            L_to_frag = gl.dir_range.xyz;
            l = -L_to_frag;
        } else {
            vec3 d = gl.pos_type.xyz - frag_world_pos;
            dist = length(d);
            l = d / max(dist, 1e-6);
            L_to_frag = -l;
        }
        float nol = max(dot(n, l), 0.0);
        float atten = light_attenuation(gl, L_to_frag, dist);
        if (nol <= 0.0 || atten <= 1e-4) continue;

        float shadow = 1.0;
        if (gl.pos_type.w >= 0.5 || !dir_shadow_used) {
            shadow = eval_light_shadow(i, gl, frag_world_pos, n, L_to_frag, nol);
            if (gl.pos_type.w < 0.5 && gl.params.y < -1.5) dir_shadow_used = true;
        }

        vec3 h = normalize(v + l);
        float noh = max(dot(n, h), 0.0);
        float denom = noh * noh * (a2 - 1.0) + 1.0;
        float D = a2 / (PI * denom * denom);
        float G = (nol / (nol * (1.0 - k) + k)) * (nov / (nov * (1.0 - k) + k));
        vec3 F = f0 + (1.0 - f0) * pow(1.0 - max(dot(h, v), 0.0), 5.0);
        vec3 spec = (D * G * F) / max(4.0 * nol * nov, 1e-4);
        vec3 diffuse_brdf = (1.0 - F) * albedo;
        lo += (diffuse_brdf + spec) * gl.color_outer.rgb * (nol * atten * shadow);
    }

    // Emit pure linear HDR radiance; single-pass ACES + linear_to_srgb runs in post-FX.
    out_color = vec4(max(lo, vec3(0.0)), base.a);
}
