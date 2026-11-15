package engine

import gfx "gfx"

Camera_Projection_Mode :: enum u8 {
    Perspective  = 0,
    Orthographic = 1,
}

@(component={max=32, menu="Rendering/Camera"})
@(typ_guid={guid = "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d"})
Camera :: struct {
    using base: CompData `inspect:"-"`,
    order:             i32,
    projection:        Camera_Projection_Mode,
    fov:               f32 `decor:range(1, 179)`,
    orthographic_size: f32,
    near_clip:         f32,
    far_clip:          f32,
    clear_color:       [4]f32 `decor:color()`,
    render_layer_mask: u32, // TODO: use bit_set[RenderLayer]
    bloom_enabled:     bool,
    bloom_threshold:   f32 `decor:range(0, 16)`,
    bloom_intensity:   f32 `decor:range(0, 4)`,
    bloom_scatter:     f32 `decor:range(0, 1)`,
    exposure:          f32 `decor:range(0.05, 16)`,
    tonemap_enabled:   bool,
}

reset_Camera :: proc(cam: ^Camera) {
    cam.order = 0
    cam.projection = .Perspective
    cam.fov = 60
    cam.orthographic_size = 5
    cam.near_clip = 0.3
    cam.far_clip = 1000
    cam.clear_color = {0.19, 0.30, 0.47, 1.0}
    cam.render_layer_mask = 0xFFFFFFFF
    cam.bloom_enabled = true
    cam.bloom_threshold = 1.0
    cam.bloom_intensity = 0.08
    cam.bloom_scatter = 0.72
    cam.exposure = 1.0
    cam.tonemap_enabled = true
}

on_validate_Camera :: proc(cam: ^Camera) {
    if cam.orthographic_size <= 0 do cam.orthographic_size = 5
    // Backfill Post-FX defaults on legacy .scene files predating HDR bloom fields.
    if cam.exposure <= 0 {
        cam.exposure = 1.0
        cam.bloom_enabled = true
        cam.bloom_threshold = 1.0
        cam.bloom_intensity = 0.08
        cam.bloom_scatter = 0.72
        cam.tonemap_enabled = true
    }
}

camera_post_fx_config :: proc(cam: ^Camera) -> gfx.Post_FX_Config {
    if cam == nil do return gfx.POST_FX_DEFAULT
    return gfx.Post_FX_Config{
        bloom_enabled   = cam.bloom_enabled,
        bloom_threshold = max(cam.bloom_threshold, 0.0),
        bloom_intensity = max(cam.bloom_intensity, 0.0),
        bloom_scatter   = clamp(cam.bloom_scatter, 0.0, 1.0),
        exposure        = cam.exposure > 0 ? cam.exposure : 1.0,
        tonemap_enabled = cam.tonemap_enabled,
    }
}

