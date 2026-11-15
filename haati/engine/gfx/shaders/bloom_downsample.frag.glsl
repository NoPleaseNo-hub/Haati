// Jimenez 13-tap dual-filter bloom downsample with soft-knee threshold and Karis
// average firefly suppression on the first pass (mip 0).
// SDL_GPU SPIR-V convention: fragment samplers set=2, fragment UBO set=3.
#version 450

layout(location = 0) in vec2 frag_uv;

layout(set = 2, binding = 0) uniform sampler2D u_src;

layout(set = 3, binding = 0) uniform BloomDownUBO {
    vec4 params;    // xy = src_texel_size, z = is_first_pass (>0.5), w = unused
    vec4 threshold; // x = thresh, y = thresh - knee, z = 2.0 * knee, w = 0.25 / max(knee, 1e-4)
};

layout(location = 0) out vec4 out_color;

vec3 sanitize_hdr(vec3 c) {
    // Reject NaNs/Infs and clamp extreme spikes so single pixels cannot blow up a mip pyramid.
    if (any(isnan(c)) || any(isinf(c))) return vec3(0.0);
    return clamp(c, vec3(0.0), vec3(64.0));
}

vec3 prefilter(vec3 c) {
    c = sanitize_hdr(c);
    float br = max(c.r, max(c.g, c.b));
    float soft = br - threshold.y;
    soft = clamp(soft, 0.0, threshold.z);
    soft = soft * soft * threshold.w;
    float contrib = max(soft, br - threshold.x) / max(br, 1e-4);
    return c * max(contrib, 0.0);
}

float karis_weight(vec3 col) {
    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    return 1.0 / (1.0 + max(luma, 0.0));
}

void main() {
    vec2 ts = params.xy;
    vec3 a = texture(u_src, frag_uv + vec2(-2.0, -2.0) * ts).rgb;
    vec3 b = texture(u_src, frag_uv + vec2( 0.0, -2.0) * ts).rgb;
    vec3 c = texture(u_src, frag_uv + vec2( 2.0, -2.0) * ts).rgb;
    vec3 d = texture(u_src, frag_uv + vec2(-1.0, -1.0) * ts).rgb;
    vec3 e = texture(u_src, frag_uv).rgb;
    vec3 f = texture(u_src, frag_uv + vec2( 1.0, -1.0) * ts).rgb;
    vec3 g = texture(u_src, frag_uv + vec2(-2.0,  0.0) * ts).rgb;
    vec3 h = texture(u_src, frag_uv + vec2( 2.0,  0.0) * ts).rgb;
    vec3 i = texture(u_src, frag_uv + vec2(-1.0,  1.0) * ts).rgb;
    vec3 j = texture(u_src, frag_uv + vec2( 0.0,  0.0) * ts).rgb; // inner center alias
    vec3 k = texture(u_src, frag_uv + vec2( 1.0,  1.0) * ts).rgb;
    vec3 l = texture(u_src, frag_uv + vec2(-2.0,  2.0) * ts).rgb;
    vec3 m = texture(u_src, frag_uv + vec2( 0.0,  2.0) * ts).rgb;
    vec3 n = texture(u_src, frag_uv + vec2( 2.0,  2.0) * ts).rgb;

    if (params.z > 0.5) {
        vec3 q0 = prefilter((d + f + i + k) * 0.25);
        vec3 q1 = prefilter((a + b + g + j) * 0.25);
        vec3 q2 = prefilter((b + c + j + h) * 0.25);
        vec3 q3 = prefilter((g + j + l + m) * 0.25);
        vec3 q4 = prefilter((j + h + m + n) * 0.25);

        float w0 = 0.500 * karis_weight(q0);
        float w1 = 0.125 * karis_weight(q1);
        float w2 = 0.125 * karis_weight(q2);
        float w3 = 0.125 * karis_weight(q3);
        float w4 = 0.125 * karis_weight(q4);
        float wsum = max(w0 + w1 + w2 + w3 + w4, 1e-5);
        vec3 res = (q0 * w0 + q1 * w1 + q2 * w2 + q3 * w3 + q4 * w4) / wsum;
        out_color = vec4(res, 1.0);
        return;
    }

    vec3 center = (d + f + i + k) * 0.25;
    vec3 tl     = (a + b + g + e) * 0.25;
    vec3 tr     = (b + c + e + h) * 0.25;
    vec3 bl     = (g + e + l + m) * 0.25;
    vec3 br     = (e + h + m + n) * 0.25;
    vec3 res = center * 0.5 + (tl + tr + bl + br) * 0.125;
    out_color = vec4(sanitize_hdr(res), 1.0);
}
