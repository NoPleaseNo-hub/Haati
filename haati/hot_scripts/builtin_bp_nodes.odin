package hot_scripts

// =============================================================================
// ZERO-BOILERPLATE `@(bp_node)` ODIN PROCS
// =============================================================================
// Drop any `@(bp_node)` proc into `haati/hot_scripts/` (or `packages/<pkg>/hot_scripts/`),
// run prebuild (or live-compile), and its pins, defaults, ^Ref pointers, and // docs
// automatically appear inside the BP_Node Studio palette!

import "core:math"
import hot "haati:engine/hot_api"

// Remaps `x` from `[in_a, in_b]` into `[out_a, out_b]`, clamped to `[0, 1]` before scaling.
@(bp_node={title="Remap Clamped", namespace="Math", pure=true})
bp_remap_clamped :: proc(x: f32, in_a: f32 = 0.0, in_b: f32 = 1.0, out_a: f32 = 0.0, out_b: f32 = 100.0) -> f32 {
	span := in_b - in_a
	if abs(span) < 1e-6 do return out_a
	t := clamp((x - in_a) / span, 0.0, 1.0)
	return out_a + (out_b - out_a) * t
}

// Saturating 8-bit unsigned addition (`200 + 100 -> 255` without wraparound).
@(bp_node={title="U8 Saturating Add", namespace="Math", pure=true})
bp_u8_saturating_add :: proc(a: u8, b: u8) -> u8 {
	sum := u16(a) + u16(b)
	return sum > 255 ? 255 : u8(sum)
}

// Converts four 8-bit unsigned color channels (`0..255`) into a normalized `[4]f32` RGBA vector.
@(bp_node={title="Pack RGBA8 -> Vec4", namespace="Math", pure=true})
bp_u8_pack_rgba :: proc(r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255) -> [4]f32 {
	return [4]f32{f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, f32(a) / 255.0}
}

// Mutates `val^` and `vel^` in place using an analytical critically damped spring toward `target`.
@(bp_node={title="Critically Damped Spring (^Ref)", namespace="Anim"})
bp_spring_f32_inplace :: proc(dt: f32, val: ^f32, vel: ^f32, target: f32, omega: f32 = 12.0) {
	hot.spring_f32_critically_damped(val, vel, target, omega, dt)
}

// Mutates `val^` and `vel^` in place using an analytical critically damped `[3]f32` spring toward `target`.
@(bp_node={title="Critically Damped Spring Vec3 (^Ref)", namespace="Anim"})
bp_spring_vec3_inplace :: proc(dt: f32, val: ^[3]f32, vel: ^[3]f32, target: [3]f32, omega: f32 = 12.0) {
	hot.spring_vec3_critically_damped(val, vel, target, omega, dt)
}

// Computes normalized horizontal XZ direction (`y == 0`) and XZ distance from `from_pos` to `to_pos`.
@(bp_node={title="Horizontal Direction XZ", namespace="Transform", pure=true})
bp_vec3_horizontal_dir :: proc(from_pos: [3]f32, to_pos: [3]f32) -> (dir: [3]f32, dist: f32) {
	delta := [3]f32{to_pos.x - from_pos.x, 0, to_pos.z - from_pos.z}
	dist = math.sqrt(delta.x * delta.x + delta.z * delta.z)
	if dist > 1e-6 {
		dir = delta / dist
	} else {
		dir = {0, 0, 1}
	}
	return
}

// Builds an orientation quaternion facing `forward` (+Z forward, +Y up).
@(bp_node={title="Quat Look Direction", namespace="Transform", pure=true})
bp_quat_look_dir :: proc(forward: [3]f32) -> quaternion128 {
	len_sq := forward.x * forward.x + forward.y * forward.y + forward.z * forward.z
	if len_sq < 1e-8 {
		return quaternion(x = f32(0), y = f32(0), z = f32(0), w = f32(1))
	}
	inv := f32(1.0) / math.sqrt(len_sq)
	fx, fy, fz := forward.x * inv, forward.y * inv, forward.z * inv
	yaw := math.atan2(fx, fz)
	horiz := math.sqrt(fx * fx + fz * fz)
	pitch := math.atan2(-fy, max(horiz, 1e-6))
	cy, sy := math.cos(yaw * 0.5), math.sin(yaw * 0.5)
	cp, sp := math.cos(pitch * 0.5), math.sin(pitch * 0.5)
	// q_yaw(0, sy, 0, cy) * q_pitch(sp, 0, 0, cp)
	return quaternion(
		x = cy * sp,
		y = sy * cp,
		z = -sy * sp,
		w = cy * cp,
	)
}
