// Fullscreen triangle vertex shader for screen-space post-processing passes
// (bloom downsample/upsample and ACES composite). Zero vertex buffer inputs.
#version 450

layout(location = 0) out vec2 frag_uv;

void main() {
    vec2 pos = vec2((gl_VertexIndex == 1) ? 3.0 : -1.0,
                    (gl_VertexIndex == 2) ? 3.0 : -1.0);
    gl_Position = vec4(pos, 0.0, 1.0);
    // SDL_GPU top-left texture origin: NDC +Y maps to V=0, NDC -Y maps to V=1.
    frag_uv = vec2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
}
