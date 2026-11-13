// SPECULAR EXAMPLE — blinn-phong on top of the scene's FIRST light (kept a
// single-light sample; the multi-light loop lives in lit.frag.glsl and
// pbr.glsl).
// Demonstrates the view-dependent shading contract: `frag_world_pos`
// (vertex output, location 3) plus the camera position in the LightUBO.
//
// How to use:
//   1. Create a Material, set `custom_shader` to this file — a shiny
//      white highlight appears at once (fallbacks below).
//   2. Tweak the auto-filled properties:
//        spec_color  x,y,z = highlight RGB, w = strength (0..1, 0 falls back to 1)
//        shininess   highlight tightness (0 falls back to 32; try 8..256)
//   3. Orbit the scene camera — the highlight follows the view.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

#include "lighting_common.glsl"

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  spec_color;
    float shininess;
};

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal);
    vec3 to_cam = normalize(cam_pos.xyz - frag_world_pos);
    float ambient = ambient_count.x;
    int count = int(ambient_count.y);
    vec3 light = vec3(ambient);
    vec3 spec_contrib = vec3(0.0);

    vec4 sc = spec_color;
    if (sc == vec4(0.0)) sc = vec4(1.0); // unset: white, full strength
    float shiny = shininess <= 0.0 ? 32.0 : shininess;

    if (count > 0) {
        GpuLight l = lights[0];
        vec3 L;
        float dist = 0.0;
        if (l.pos_type.w < 0.5) {
            L = l.dir_range.xyz;
        } else {
            vec3 d = frag_world_pos - l.pos_type.xyz;
            dist = length(d);
            L = d / max(dist, 1e-6);
        }
        vec3 to_light = -L;
        float diffuse = max(dot(n, to_light), 0.0);
        float atten = light_attenuation(l, L, dist);
        float shadow = eval_light_shadow(0, l, frag_world_pos, n, L, diffuse);
        light += l.color_outer.rgb * ((1.0 - ambient) * diffuse * atten * shadow);

        vec3 half_dir = normalize(to_light + to_cam);
        float spec = pow(max(dot(n, half_dir), 0.0), shiny) * step(0.0, diffuse);
        spec_contrib = l.color_outer.rgb * sc.rgb * (spec * clamp(sc.a, 0.0, 1.0) * atten * shadow);
    }

    vec4 base = texture(tex, frag_uv) * frag_color;
    vec3 rgb = base.rgb * light + spec_contrib;
    out_color = vec4(rgb, base.a);
}
