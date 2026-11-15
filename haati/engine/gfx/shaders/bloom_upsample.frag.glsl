// 9-tap tent upsample for dual-filter bloom; rendered additively into target mip.
// SDL_GPU SPIR-V convention: fragment samplers set=2, fragment UBO set=3.
#version 450

layout(location = 0) in vec2 frag_uv;

layout(set = 2, binding = 0) uniform sampler2D u_src;

layout(set = 3, binding = 0) uniform BloomUpUBO {
    vec4 params; // xy = filter_radius * src_texel_size, z = scatter, w = unused
};

layout(location = 0) out vec4 out_color;

void main() {
    vec2 ts = params.xy;
    vec3 a = texture(u_src, frag_uv + vec2(-ts.x, -ts.y)).rgb;
    vec3 b = texture(u_src, frag_uv + vec2(  0.0, -ts.y)).rgb;
    vec3 c = texture(u_src, frag_uv + vec2( ts.x, -ts.y)).rgb;

    vec3 d = texture(u_src, frag_uv + vec2(-ts.x,   0.0)).rgb;
    vec3 e = texture(u_src, frag_uv).rgb;
    vec3 f = texture(u_src, frag_uv + vec2( ts.x,   0.0)).rgb;

    vec3 g = texture(u_src, frag_uv + vec2(-ts.x,  ts.y)).rgb;
    vec3 h = texture(u_src, frag_uv + vec2(  0.0,  ts.y)).rgb;
    vec3 i = texture(u_src, frag_uv + vec2( ts.x,  ts.y)).rgb;

    vec3 tent = (e * 4.0 + (b + d + f + h) * 2.0 + (a + c + g + i)) * (1.0 / 16.0);
    out_color = vec4(max(tent, vec3(0.0)) * params.z, 1.0);
}
