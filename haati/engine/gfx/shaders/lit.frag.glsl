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

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal);
    float ambient = ambient_count.x;
    int count = int(ambient_count.y);
    bool dir_shadow_used = false;

    vec3 light = vec3(ambient);
    for (int i = 0; i < count; ++i) {
        GpuLight l = lights[i];
        vec3 L; // direction the light travels at this fragment
        float dist = 0.0;
        if (l.pos_type.w < 0.5) {
            L = l.dir_range.xyz;
        } else {
            vec3 d = frag_world_pos - l.pos_type.xyz;
            dist = length(d);
            L = d / max(dist, 1e-6);
        }
        float diffuse = max(dot(n, -L), 0.0);
        float atten = light_attenuation(l, L, dist);
        float shadow = 1.0;
        if (l.pos_type.w >= 0.5 || !dir_shadow_used) {
            shadow = eval_light_shadow(i, l, frag_world_pos, n, L, diffuse);
            if (l.pos_type.w < 0.5 && l.params.y < -1.5) dir_shadow_used = true;
        }
        light += l.color_outer.rgb * ((1.0 - ambient) * diffuse * atten * shadow);
    }

    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = vec4(base.rgb * light, base.a);
}
