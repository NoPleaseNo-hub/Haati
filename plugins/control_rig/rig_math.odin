package control_rig

// Pure Math Library for Procedural Animation & Control Rig Solvers.
// Ported and enhanced from Godot's RigFunctions (Zero-iteration analytical IK).

import "core:math"
import "core:math/linalg"
import engine "moonhug:engine"

TwoBoneResult :: struct {
	root_pos: [3]f32,
	root_rot: [4]f32,
	mid_pos:  [3]f32,
	mid_rot:  [4]f32,
	tip_pos:  [3]f32,
	reached:  bool,
}

// Computes rotation aiming forward at target with given up reference
look_rotation :: proc(forward, up: [3]f32) -> [4]f32 {
	f_len2 := linalg.length2(forward)
	if f_len2 < 0.000001 do return engine.QUAT_IDENTITY

	f := linalg.normalize(forward)
	u := up
	u_len2 := linalg.length2(u)
	if u_len2 < 0.000001 do u = [3]f32{0, 1, 0}
	else do u = linalg.normalize(u)

	r := linalg.cross(u, f)
	if linalg.length2(r) < 0.0001 {
		r = linalg.cross([3]f32{1, 0, 0}, f)
		if linalg.length2(r) < 0.0001 {
			r = linalg.cross([3]f32{0, 0, 1}, f)
		}
	}
	r = linalg.normalize(r)
	u = linalg.cross(f, r)

	m := linalg.Matrix3f32{
		r.x, u.x, f.x,
		r.y, u.y, f.y,
		r.z, u.z, f.z,
	}
	q := linalg.quaternion_from_matrix3(m)
	return engine.quat_from_native(linalg.normalize(q))
}

// Shortest rotation from vector 'from' to vector 'to'
from_to_rotation :: proc(from, to: [3]f32) -> [4]f32 {
	f_len2 := linalg.length2(from)
	t_len2 := linalg.length2(to)
	if f_len2 < 0.000001 || t_len2 < 0.000001 do return engine.QUAT_IDENTITY

	f := linalg.normalize(from)
	t := linalg.normalize(to)
	dot := linalg.dot(f, t)

	if dot > 0.99999 do return engine.QUAT_IDENTITY
	if dot < -0.99999 {
		perp := abs(f.y) < 0.9 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
		axis := linalg.normalize(linalg.cross(f, perp))
		q := linalg.quaternion_angle_axis(math.PI, axis)
		return engine.quat_from_native(q)
	}

	c := linalg.cross(f, t)
	q := quaternion(x = c.x, y = c.y, z = c.z, w = 1.0 + dot)
	return engine.quat_from_native(linalg.normalize(q))
}

// Aim from_pos toward toward_pos
look_at :: proc(from_pos, toward_pos, world_up: [3]f32) -> [4]f32 {
	forward := toward_pos - from_pos
	if linalg.length2(forward) < 0.000001 do return engine.QUAT_IDENTITY
	return look_rotation(forward, world_up)
}

// Aim with pitch and yaw clamping in degrees relative to base_rot
look_at_clamped :: proc(
	from_pos, toward_pos, world_up: [3]f32,
	base_rot: [4]f32,
	yaw_limit_deg, pitch_limit_deg: f32,
) -> [4]f32 {
	full_rot := look_at(from_pos, toward_pos, world_up)
	if yaw_limit_deg <= 0 && pitch_limit_deg <= 0 do return full_rot

	base_q := engine.quat_to_native(base_rot)
	full_q := engine.quat_to_native(full_rot)
	inv_base := linalg.quaternion_inverse(base_q)
	delta := inv_base * full_q

	rx, ry, rz := linalg.euler_angles_from_quaternion(delta, .YXZ)
	yaw_rad := ry
	pitch_rad := rx

	if yaw_limit_deg > 0 {
		max_yaw := math.to_radians(yaw_limit_deg)
		yaw_rad = math.clamp(yaw_rad, -max_yaw, max_yaw)
	}
	if pitch_limit_deg > 0 {
		max_pitch := math.to_radians(pitch_limit_deg)
		pitch_rad = math.clamp(pitch_rad, -max_pitch, max_pitch)
	}

	clamped_delta := linalg.quaternion_from_euler_angles(pitch_rad, yaw_rad, rz, .YXZ)
	final_q := linalg.normalize(base_q * clamped_delta)
	return engine.quat_from_native(final_q)
}

// Aim local axis at toward_pos
aim_axis :: proc(
	from_pos, toward_pos: [3]f32,
	local_aim_axis, local_up_axis, world_up: [3]f32,
) -> [4]f32 {
	forward := toward_pos - from_pos
	if linalg.length2(forward) < 0.000001 do return engine.QUAT_IDENTITY

	base_look := look_rotation(forward, world_up)
	default_forward := [3]f32{0, 0, 1}
	aim_norm := linalg.normalize(local_aim_axis)

	correction := from_to_rotation(aim_norm, default_forward)
	c_q := engine.quat_to_native(correction)
	b_q := engine.quat_to_native(base_look)
	inv_c := linalg.quaternion_inverse(c_q)

	final_q := linalg.normalize(b_q * inv_c)
	return engine.quat_from_native(final_q)
}

// Analytical Two-Bone IK via Law of Cosines
two_bone_ik :: proc(
	root_pos, mid_pos, tip_pos: [3]f32,
	target_pos, pole_pos: [3]f32,
	extension_clamp: f32 = 0.001,
) -> TwoBoneResult {
	res: TwoBoneResult
	res.root_pos = root_pos

	upper_len := linalg.distance(root_pos, mid_pos)
	lower_len := linalg.distance(mid_pos, tip_pos)

	if upper_len < 0.0001 || lower_len < 0.0001 {
		res.mid_pos = mid_pos
		res.tip_pos = tip_pos
		res.root_rot = engine.QUAT_IDENTITY
		res.mid_rot = engine.QUAT_IDENTITY
		res.reached = false
		return res
	}

	to_target := target_pos - root_pos
	dist := linalg.length(to_target)
	max_dist := (upper_len + lower_len) * (1.0 - extension_clamp)

	res.reached = dist <= max_dist
	dist = math.min(dist, max_dist)
	if dist < 0.0001 {
		res.mid_pos = mid_pos
		res.tip_pos = tip_pos
		res.root_rot = engine.QUAT_IDENTITY
		res.mid_rot = engine.QUAT_IDENTITY
		return res
	}

	target_dir := linalg.normalize(to_target)

	// Law of Cosines: angle at root
	cos_angle := (upper_len * upper_len + dist * dist - lower_len * lower_len) / (2.0 * upper_len * dist)
	cos_angle = math.clamp(cos_angle, -1.0, 1.0)
	root_angle := math.acos(cos_angle)

	// Bending plane from pole vector
	to_pole := linalg.normalize(pole_pos - root_pos)
	bend_normal := linalg.cross(target_dir, to_pole)
	if linalg.length2(bend_normal) < 0.000001 {
		cur_mid_dir := linalg.normalize(mid_pos - root_pos)
		bend_normal = linalg.cross(target_dir, cur_mid_dir)
		if linalg.length2(bend_normal) < 0.000001 {
			bend_normal = linalg.cross(target_dir, [3]f32{0, 1, 0})
		}
	}
	bend_normal = linalg.normalize(bend_normal)

	// Rotate target_dir by root_angle around bend_normal to find mid
	root_q := linalg.quaternion_angle_axis(root_angle, bend_normal)
	new_mid_dir := linalg.quaternion128_mul_vector3(root_q, target_dir)
	new_mid_pos := root_pos + new_mid_dir * upper_len

	// Calculate rotations
	root_fwd := new_mid_pos - root_pos
	root_up := linalg.cross(bend_normal, root_fwd)
	if linalg.length2(root_up) < 0.0001 do root_up = [3]f32{0, 1, 0}
	else do root_up = linalg.normalize(root_up)

	mid_fwd := target_pos - new_mid_pos
	mid_up := linalg.cross(bend_normal, mid_fwd)
	if linalg.length2(mid_up) < 0.0001 do mid_up = [3]f32{0, 1, 0}
	else do mid_up = linalg.normalize(mid_up)

	res.mid_pos = new_mid_pos
	res.tip_pos = target_pos
	res.root_rot = look_rotation(root_fwd, root_up)
	res.mid_rot = look_rotation(mid_fwd, mid_up)

	return res
}
