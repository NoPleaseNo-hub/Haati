// Shared lighting, attenuation, and 16-tile 4096x4096 shadow atlas sampling
// for Haati's built-in "lit" shader and custom surface shaders (PBR, Specular,
// Material Studio). Include after `#version 450` and set-2 texture bindings `0..6`.
//
// SDL_GPU SPIR-V convention:
//   - Fragment sampled textures: set = 2 (binding 7 reserved for u_shadow_map)
//   - Fragment uniform buffers:  set = 3 (binding 0 = LightUBO, binding 1 = MaterialUBO)

layout(set = 2, binding = 7) uniform sampler2D u_shadow_map;

#define MAX_LIGHTS 64

struct GpuLight {
    vec4 pos_type;    // xyz = position, w = kind (0 dir, 1 point, 2 spot)
    vec4 dir_range;   // xyz = normalized travel direction, w = range
    vec4 color_outer; // rgb premultiplied by intensity, w = cos outer half-angle
    vec4 params;      // x = cos inner half-angle, y = shadow flag (<-1.5 casts), z = shadow_strength, w = shadow_bias
};

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 ambient_count;     // x = ambient floor, y = light count
    vec4 cam_pos;           // xyz = camera world position
    GpuLight lights[MAX_LIGHTS];
    mat4 shadow_mats[16];   // 0..2 dir CSM, 3 spot, 4..9 point0, 10..15 point1
    vec4 cascade_splits;    // xyz = cascade max dists from cam, w = spot caster light index (<0 if none)
    vec4 shadow_atlas_info; // x = 1.0/atlas_dim, y = dir_enabled (>0.5), z = spot_enabled (>0.5), w = any_enabled (>0.5)
    vec4 point_shadow_info; // x = point0 light idx (<0 none), y = point1 light idx (<0 none), z = p0 en, w = p1 en
};

// Smooth falloff: 1 at the light, 0 at range.
float light_attenuation(GpuLight l, vec3 to_frag, float dist) {
    if (l.pos_type.w < 0.5) return 1.0; // directional
    float range = max(l.dir_range.w, 1e-4);
    float ratio = dist / range;
    float a = clamp(1.0 - ratio * ratio, 0.0, 1.0);
    a *= a;
    if (l.pos_type.w > 1.5) { // spot: fade between inner and outer cone
        float cos_a = dot(to_frag, l.dir_range.xyz);
        float inner = l.params.x;
        float outer = l.color_outer.w;
        a *= clamp((cos_a - outer) / max(inner - outer, 1e-4), 0.0, 1.0);
    }
    return a;
}

// Returns UV origin of tile 0..15 in the 4x4 shadow atlas (each tile is 0.25 x 0.25).
vec2 shadow_tile_offset(int tile) {
    int col = tile % 4;
    int row = tile / 4;
    return vec2(float(col) * 0.25, float(row) * 0.25);
}

// Selects cubemap face 0..5 (+X, -X, +Y, -Y, +Z, -Z) matching gfx.shadow_select_point_face.
int select_point_shadow_face(vec3 offset) {
    float ax = abs(offset.x);
    float ay = abs(offset.y);
    float az = abs(offset.z);
    if (ax >= ay && ax >= az) {
        return offset.x >= 0.0 ? 0 : 1;
    }
    if (ay >= az) {
        return offset.y >= 0.0 ? 2 : 3;
    }
    return offset.z >= 0.0 ? 4 : 5;
}

float sample_shadow_tile(int tile, vec3 world_pos, vec3 n, vec3 L, float base_bias, float strength, float bias_scale) {
    vec4 clip = shadow_mats[tile] * vec4(world_pos, 1.0);
    if (clip.w <= 1e-6) return 1.0;
    vec3 proj = clip.xyz / clip.w;
    // matrix4_*_z01 outputs Z in [0, 1]; framebuffer +Y is top -> V = 0.5 - 0.5*Y.
    vec2 tile_uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
    if (tile_uv.x <= 0.002 || tile_uv.x >= 0.998 || tile_uv.y <= 0.002 || tile_uv.y >= 0.998) return 1.0;
    if (proj.z <= 0.0 || proj.z >= 1.0) return 1.0;

    float ndotl = clamp(dot(n, -L), 0.0, 1.0);
    float bias = max(base_bias * (1.0 - ndotl), base_bias * 0.25) * bias_scale;

    float texel = shadow_atlas_info.x;
    vec2 offset = shadow_tile_offset(tile);
    vec2 uv_min = offset + vec2(0.5 * texel);
    vec2 uv_max = offset + vec2(0.25 - 0.5 * texel);
    vec2 center_uv = offset + tile_uv * 0.25;

    float lit_sum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 sample_uv = clamp(center_uv + vec2(float(x), float(y)) * texel, uv_min, uv_max);
            float stored_depth = texture(u_shadow_map, sample_uv).r;
            lit_sum += (proj.z - bias <= stored_depth) ? 1.0 : 0.0;
        }
    }
    return mix(1.0, lit_sum / 9.0, clamp(strength, 0.0, 1.0));
}

float eval_directional_shadow(vec3 world_pos, vec3 n, vec3 L, float bias, float strength) {
    float cam_dist = length(world_pos - cam_pos.xyz);
    int cascade = 2;
    if (cam_dist < cascade_splits.x) {
        cascade = 0;
    } else if (cam_dist < cascade_splits.y) {
        cascade = 1;
    } else if (cam_dist >= cascade_splits.z) {
        return 1.0;
    }
    float cascade_scale = 1.0 + float(cascade) * 0.35;
    return sample_shadow_tile(cascade, world_pos, n, L, bias, strength, cascade_scale);
}

float eval_light_shadow(int light_idx, GpuLight l, vec3 world_pos, vec3 n, vec3 L, float diffuse) {
    if (shadow_atlas_info.w <= 0.5 || diffuse <= 0.0 || l.params.y >= -1.5) {
        return 1.0;
    }
    float bias = l.params.w > 0.0 ? l.params.w : 0.0015;
    if (l.pos_type.w < 0.5) {
        if (shadow_atlas_info.y > 0.5) {
            return eval_directional_shadow(world_pos, n, L, bias, l.params.z);
        }
        return 1.0;
    }
    if (l.pos_type.w > 1.5) {
        int spot_caster = int(round(cascade_splits.w));
        if (light_idx == spot_caster && shadow_atlas_info.z > 0.5) {
            return sample_shadow_tile(3, world_pos, n, L, bias, l.params.z, 1.0);
        }
        return 1.0;
    }
    int face = select_point_shadow_face(world_pos - l.pos_type.xyz);
    int p0 = int(round(point_shadow_info.x));
    int p1 = int(round(point_shadow_info.y));
    if (light_idx == p0 && point_shadow_info.z > 0.5) {
        return sample_shadow_tile(4 + face, world_pos, n, L, bias, l.params.z, 1.0);
    }
    if (light_idx == p1 && point_shadow_info.w > 0.5) {
        return sample_shadow_tile(10 + face, world_pos, n, L, bias, l.params.z, 1.0);
    }
    return 1.0;
}
