package engine

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
}

on_validate_Camera :: proc(cam: ^Camera) {
    if cam.orthographic_size <= 0 do cam.orthographic_size = 5
}

