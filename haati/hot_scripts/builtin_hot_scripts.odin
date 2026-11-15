package hot_scripts

// =============================================================================
// MOONHUG HOT-SWAPPABLE GAMEPLAY & TRANSPILED VISUAL SCRIPTS (`hot_scripts`)
// =============================================================================
// Procedures marked `@(hot_proc)` here (and transpiled `*_mhgraph_generated.odin`
// visual scripts emitted next to this file) compile both:
//   1. Statically into `MoonHug.exe` and standalone `app.exe` (100% native speed, zero DLL needed to ship), AND
//   2. Dynamically into `builds/hot_cartridge_<N>.dll` (~130 ms background compile)
//      for zero-flicker mid-frame hot-swapping inside the editor!

import "core:math"
import hot "haati:engine/hot_api"

// Built-in Demo `@(hot_proc)`: Smooth harmonic hover bobbing along Y.
// Input[0] (`● Copy` f32): Amplitude in meters (default 0.25)
// Input[1] (`● Copy` f32): Frequency in Hz (default 2.0)
// Input[2] (`◆ ^Ref` f32): Mutable phase accumulator (`^f32`) mutated in-place!
@(hot_proc)
hot_harmonic_hover :: proc "c" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, frame: ^hot.Hot_Call_Frame) {
    if frame == nil do return
    amp   := hot.slot_read_f32(&frame.inputs[0])
    freq  := hot.slot_read_f32(&frame.inputs[1])
    phase := hot.slot_ref_f32(&frame.inputs[2])
    if amp <= 0.0 do amp = 0.25
    if freq <= 0.0 do freq = 2.0

    eff_dt := api != nil && api.get_object_dt != nil ? api.get_object_dt(self, dt) : dt
    phase^ += eff_dt * freq * math.TAU
    if phase^ > math.TAU do phase^ -= math.TAU

    offset_y := math.sin(phase^) * amp
    if pos_ptr := hot.pos_ref(api, self); pos_ptr != nil {
        pos_ptr.y += offset_y * eff_dt
    }
    frame.outputs[0] = {pin_type = .Float, val_f32 = offset_y}
    frame.output_count = 1
}

// Built-in Demo `@(hot_proc)`: Mutates any `^[3]f32` Reference Pin (`◆`) by damped spring toward a target `Vec3` (`● Copy`).
// Input[0] (`◆ ^Ref` Vec3): Mutable position / vector reference (`^[3]f32`)
// Input[1] (`● Copy` Vec3): Target vector (`[3]f32`)
// Input[2] (`● Copy` f32):  Spring speed (default 8.0)
@(hot_proc)
hot_spring_vec3_ref :: proc "c" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, frame: ^hot.Hot_Call_Frame) {
    if frame == nil do return
    vec_ref := hot.slot_ref_vec3(&frame.inputs[0])
    target  := hot.slot_read_vec3(&frame.inputs[1])
    speed   := hot.slot_read_f32(&frame.inputs[2])
    if speed <= 0.0 do speed = 8.0

    eff_dt := api != nil && api.get_object_dt != nil ? api.get_object_dt(self, dt) : dt
    vec_ref^ = hot.damp_vec3(vec_ref^, target, speed, eff_dt)
    frame.outputs[0] = {pin_type = .Vec3, val_vec3 = vec_ref^}
    frame.output_count = 1
}

// Built-in Demo `@(hot_proc)`: Per-Object Time-Dilation Field Helper (sets custom time scale on target entity).
@(hot_proc)
hot_apply_timescale_zone :: proc "c" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, _dt: f32, frame: ^hot.Hot_Call_Frame) {
    if frame == nil do return
    scale := hot.slot_read_f32(&frame.inputs[0])
    hot.set_object_timescale(api, self, scale)
}
