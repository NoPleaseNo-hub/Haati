package control_rig

// HumanoidIkSolver: Modular Full-Body Humanoid IK Solver Component.
// Decoupled from the ControlRig data container so character skeletons have a dedicated,
// high-performance solver that articulates skeleton bones in a single unified top-to-bottom pass:
// 1. Pelvis translation and additive rotation relative to rest bind pose.
// 2. Spine & Chest 3-point spline crouch, arch, and axial twist.
// 3. Head neck tilt and LookAt vision aiming (aiming smoothly toward look_at_target when set).
// 4. Two-Bone IK for arms and legs with geometric pole vectors and toe pitch roll.
// 5. Forearm / Wrist twist simulation distributing wrist rotation to forearm bones.
//
// State machines (locomotion, procedural pose) write to ControlRig controls,
// and HumanoidIkSolver executes the full-body IK solver math directly.

import "core:math"
import "core:math/linalg"
import engine "haati:engine"

@(component={menu="Animation/HumanoidIkSolver"})
@(typ_guid={guid = "9b4c7d2e-5a6b-4e1a-8c3d-7f1e0a2b3c4d"})
HumanoidIkSolver :: struct {
	using base:              engine.CompData `inspect:"-"`,
	active:                  bool,

	// --- HEAD & VISION AIMING TUNING ---
	look_at_max_angle:       f32, // Maximum head look angle in degrees (default 85.0)

	// --- FOREARM / WRIST TWIST TUNING ---
	wrist_twist_ratio:       f32, // Ratio of wrist twist sent to forearm/elbow (0.0 to 1.0, default 0.5)
}

reset_HumanoidIkSolver :: proc(solver: ^HumanoidIkSolver) {
	solver.active = true
	solver.look_at_max_angle = 85.0
	solver.wrist_twist_ratio = 0.5
}

cleanup_HumanoidIkSolver :: proc(solver: ^HumanoidIkSolver) {
	engine.comp_zero(solver)
}

on_destroy_HumanoidIkSolver :: proc(solver: ^HumanoidIkSolver) {
	cleanup_HumanoidIkSolver(solver)
}

@(inspector_button={label="Rebind Skeleton Bones", row=-1})
humanoid_ik_solver_rebind :: proc(solver: ^HumanoidIkSolver) {
	if solver == nil do return
	if _, adm := engine.transform_get_comp(solver.owner, ArmatureDeformedMesh); adm != nil {
		armature_deformed_mesh_reset_bind_pose(adm)
		return
	}
	if _, rig := engine.transform_get_comp(solver.owner, ControlRig); rig != nil {
		skeleton_bind_humanoid(&rig.bones, solver.owner)
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(update={order=3})
humanoid_ik_solver_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(humanoid_ik_solvers(w))
	for solver, _ in engine.pool_next(&it) {
		if !solver.active do continue

		// Retrieve ControlRig container on the same entity (single source of truth for controls + bones)
		_, rig := engine.transform_get_comp(solver.owner, ControlRig)
		if rig == nil || !rig.active do continue

		control_rig_sanitize(rig)
		bones := control_rig_ensure_bones(rig)
		if bones == nil || !bones.bound do continue

		// Execute full humanoid solve directly via pointer to rig.bones
		humanoid_ik_solve(
			bones,
			solver.owner,
			rig,
			solver.look_at_max_angle,
			solver.wrist_twist_ratio,
		)
	}
}

// -----------------------------------------------------------------------------
// Core Quaternion Math Helpers
// -----------------------------------------------------------------------------

safe_quat :: proc(q: [4]f32) -> [4]f32 {
	len2 := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
	if len2 < 0.0001 || math.is_nan(q.x) || math.is_nan(q.y) || math.is_nan(q.z) || math.is_nan(q.w) {
		return engine.QUAT_IDENTITY
	}
	inv_len := 1.0 / math.sqrt(len2)
	return {q.x * inv_len, q.y * inv_len, q.z * inv_len, q.w * inv_len}
}

safe_quat_native :: proc(q: quaternion128) -> quaternion128 {
	len2 := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
	if len2 < 0.0001 || math.is_nan(q.x) || math.is_nan(q.y) || math.is_nan(q.z) || math.is_nan(q.w) {
		return quaternion128(1)
	}
	return linalg.quaternion_normalize(q)
}

safe_quat_delta :: proc(q: [4]f32, char_rot: quaternion128) -> (world_delta: quaternion128, has_delta: bool) {
	len2 := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
	if len2 < 0.0001 || math.is_nan(q.x) || math.is_nan(q.y) || math.is_nan(q.z) || math.is_nan(q.w) {
		return quaternion128(1), false
	}
	if abs(abs(q.w) - 1.0) < 0.0001 && abs(q.x) < 0.0001 && abs(q.y) < 0.0001 && abs(q.z) < 0.0001 {
		return quaternion128(1), false
	}
	delta_native := safe_quat_native(engine.quat_to_native(q))
	inv_char := linalg.quaternion_inverse(char_rot)
	world_d := char_rot * delta_native * inv_char
	return safe_quat_native(world_d), true
}

// -----------------------------------------------------------------------------
// Two-Bone Analytical IK Solver
// -----------------------------------------------------------------------------

// Stateless Analytical Two-Bone Forward Solve (Godot / Unreal Control Rig architecture).
// Solves directly from the character bind rest pose with continuous orthogonal bend-plane alignment.
// Guarantees zero roll drift, zero helicopter spinning, and zero delta accumulation.
solve_two_bone_limb :: proc(
	root_bone, mid_bone, tip_bone: engine.Transform_Handle,
	rest: Limb_Rest_Pose,
	char_pos: [3]f32,
	char_rot: quaternion128,
	char_scale: [3]f32,
	target_pos: [3]f32,
	pole_pos: [3]f32,
	weight: f32 = 1.0,
	tip_rotation_weight: f32 = 1.0,
	target_rot_delta: Maybe(quaternion128) = nil,
	default_pole_dir: Maybe([3]f32) = nil,
	relative_rot: [4]f32 = engine.QUAT_IDENTITY,
) {
	w := engine.ctx_world()
	if w == nil || weight <= 0.0001 do return
	if !engine.pool_valid(&w.transforms, engine.Handle(root_bone)) ||
	   !engine.pool_valid(&w.transforms, engine.Handle(mid_bone))  ||
	   !engine.pool_valid(&w.transforms, engine.Handle(tip_bone)) {
		return
	}

	root_pos := engine.transform_world_position(root_bone)

	local_to_world_pos :: proc(p_local: [3]f32, c_pos: [3]f32, c_rot: quaternion128, c_scale: [3]f32) -> [3]f32 {
		scaled := p_local * c_scale
		return c_pos + linalg.quaternion128_mul_vector3(c_rot, scaled)
	}
	local_to_world_rot :: proc(q_local: [4]f32, c_rot: quaternion128) -> quaternion128 {
		q_l := engine.quat_to_native(q_local)
		return linalg.quaternion_normalize(c_rot * q_l)
	}

	rest_root_pos := local_to_world_pos(rest.root_pos, char_pos, char_rot, char_scale)
	rest_mid_pos  := local_to_world_pos(rest.mid_pos,  char_pos, char_rot, char_scale)
	rest_tip_pos  := local_to_world_pos(rest.tip_pos,  char_pos, char_rot, char_scale)

	rest_root_rot := local_to_world_rot(rest.root_rot, char_rot)
	rest_mid_rot  := local_to_world_rot(rest.mid_rot,  char_rot)
	rest_tip_rot  := local_to_world_rot(rest.tip_rot,  char_rot)

	upper_len := linalg.length(rest_mid_pos - rest_root_pos)
	lower_len := linalg.length(rest_tip_pos - rest_mid_pos)
	if upper_len < 0.0001 || lower_len < 0.0001 do return

	to_target := target_pos - root_pos
	dist := linalg.length(to_target)
	min_dist := max(0.001, abs(upper_len - lower_len))
	max_dist := (upper_len + lower_len) * 0.9999
	clamped_dist := clamp(dist, min_dist, max_dist)
	target_dir := linalg.normalize0(to_target)
	if linalg.length2(target_dir) < 0.0001 {
		target_dir = {0, 0, 1}
	}

	// 1. Law of Cosines: root angle (alpha)
	cos_alpha := (upper_len * upper_len + clamped_dist * clamped_dist - lower_len * lower_len) / (2.0 * upper_len * clamped_dist)
	cos_alpha = clamp(cos_alpha, -1.0, 1.0)
	sin_alpha := math.sqrt(max(0.0, 1.0 - cos_alpha * cos_alpha))

	// 2. Rest limb directions
	orig_upper_dir := linalg.normalize0(rest_mid_pos - rest_root_pos)
	orig_lower_dir := linalg.normalize0(rest_tip_pos - rest_mid_pos)

	// 3. Determine natural rest pole direction
	// When default_pole_dir is supplied (e.g. forward for legs, backward for arms), use it directly
	// to avoid collinear cross-product singularities and prevent 180-degree bend-plane flips.
	rest_pole_dir: [3]f32
	if def_pole, ok := default_pole_dir.?; ok && linalg.length2(def_pole) > 0.0001 {
		rest_pole_dir = linalg.normalize0(def_pole)
	} else {
		rest_bend := linalg.cross(orig_upper_dir, orig_lower_dir)
		if linalg.length2(rest_bend) < 0.0001 {
			fallback_axis: [3]f32 = {1, 0, 0} if abs(orig_upper_dir.y) > 0.9 else {0, 1, 0}
			rest_bend = linalg.cross(fallback_axis, orig_upper_dir)
		}
		rest_bend_norm := linalg.normalize0(rest_bend)
		rest_pole_dir = linalg.normalize0(linalg.cross(rest_bend_norm, orig_upper_dir))
	}

	// 4. Determine current Pole Direction (perpendicular to target_dir)
	to_pole := pole_pos - root_pos
	pole_perp := to_pole - target_dir * linalg.dot(to_pole, target_dir)
	pole_dir: [3]f32
	if linalg.length2(pole_perp) > 0.0001 {
		pole_dir = linalg.normalize0(pole_perp)
	} else {
		delta_to_target := engine.quat_to_native(from_to_rotation(orig_upper_dir, target_dir))
		candidate_pole := linalg.normalize0(linalg.quaternion128_mul_vector3(delta_to_target, rest_pole_dir))
		candidate_perp := candidate_pole - target_dir * linalg.dot(candidate_pole, target_dir)
		pole_dir = rest_pole_dir if linalg.length2(candidate_perp) < 0.0001 else linalg.normalize0(candidate_perp)
	}

	// 5. Solved Mid Position via geometric projection directly toward pole_dir
	proj_pos := root_pos + target_dir * (upper_len * cos_alpha)
	solved_mid_pos := proj_pos + pole_dir * (upper_len * sin_alpha)

	solved_upper_dir := linalg.normalize0(solved_mid_pos - root_pos)
	solved_lower_dir := linalg.normalize0(target_pos - solved_mid_pos)

	// 6. Delta Rotation for Upper Bone
	delta_upper_dir := engine.quat_to_native(from_to_rotation(orig_upper_dir, solved_upper_dir))

	orig_bend_plane_normal := linalg.normalize0(linalg.cross(orig_upper_dir, rest_pole_dir))
	solved_bend_normal    := linalg.normalize0(linalg.cross(target_dir, pole_dir))

	solved_upper_rot: quaternion128
	if linalg.length2(orig_bend_plane_normal) > 0.0001 && linalg.length2(solved_bend_normal) > 0.0001 {
		interim_normal := linalg.quaternion128_mul_vector3(delta_upper_dir, orig_bend_plane_normal)
		delta_twist := engine.quat_to_native(from_to_rotation(interim_normal, solved_bend_normal))
		solved_upper_rot = linalg.quaternion_normalize(delta_twist * delta_upper_dir * rest_root_rot)
	} else {
		solved_upper_rot = linalg.quaternion_normalize(delta_upper_dir * rest_root_rot)
	}

	if weight >= 0.999 {
		engine.transform_set_world_rotation(root_bone, engine.quat_from_native(solved_upper_rot))
	} else if weight > 0.001 {
		blended := linalg.quaternion_slerp(rest_root_rot, solved_upper_rot, weight)
		engine.transform_set_world_rotation(root_bone, engine.quat_from_native(blended))
	}

	// 7. Delta Rotation for Lower Bone
	upper_rot_change := solved_upper_rot * linalg.quaternion_inverse(rest_root_rot)
	current_lower_dir := linalg.normalize0(linalg.quaternion128_mul_vector3(upper_rot_change, orig_lower_dir))
	delta_lower_dir := engine.quat_to_native(from_to_rotation(current_lower_dir, solved_lower_dir))
	solved_lower_rot := linalg.quaternion_normalize(delta_lower_dir * upper_rot_change * rest_mid_rot)

	if weight >= 0.999 {
		engine.transform_set_world_rotation(mid_bone, engine.quat_from_native(solved_lower_rot))
	} else if weight > 0.001 {
		blended := linalg.quaternion_slerp(rest_mid_rot, solved_lower_rot, weight)
		engine.transform_set_world_rotation(mid_bone, engine.quat_from_native(blended))
	}

	// 8. Tip Bone (Hand or Foot) - Slerp blend between natural anatomical angle and control orientation
	lower_rot_change := solved_lower_rot * linalg.quaternion_inverse(rest_mid_rot)
	rel_q := safe_quat_native(engine.quat_to_native(safe_quat(relative_rot)))
	natural_tip_rot := linalg.quaternion_normalize(lower_rot_change * rest_tip_rot * rel_q)

	tgt_delta := target_rot_delta.? or_else quaternion128(1)
	control_tip_rot := linalg.quaternion_normalize(tgt_delta * rest_tip_rot * rel_q)
	blend_alpha := clamp(tip_rotation_weight, 0.0, 1.0)
	final_tip_rot: quaternion128
	if blend_alpha >= 0.999 {
		final_tip_rot = control_tip_rot
	} else if blend_alpha <= 0.015 {
		final_tip_rot = natural_tip_rot
	} else {
		final_tip_rot = linalg.quaternion_normalize(linalg.quaternion_slerp(natural_tip_rot, control_tip_rot, blend_alpha))
	}

	if weight >= 0.999 {
		engine.transform_set_world_rotation(tip_bone, engine.quat_from_native(final_tip_rot))
	} else if weight > 0.001 {
		b := linalg.quaternion_slerp(rest_tip_rot, final_tip_rot, weight)
		engine.transform_set_world_rotation(tip_bone, engine.quat_from_native(b))
	}
}

// -----------------------------------------------------------------------------
// Forearm / Wrist Twist Simulation
// -----------------------------------------------------------------------------

// Swing-Twist decomposition around an axis.
// Decomposes q into q_swing * q_twist where q_twist is a pure rotation around axis.
swing_twist_decompose :: proc(q: quaternion128, axis: [3]f32) -> (q_swing: quaternion128, q_twist: quaternion128) {
	identity_q := engine.quat_to_native(engine.QUAT_IDENTITY)
	norm_axis := linalg.normalize0(axis)
	if linalg.length2(norm_axis) < 0.0001 {
		return q, identity_q
	}

	v := [3]f32{q.x, q.y, q.z}
	p := linalg.dot(v, norm_axis)
	v_twist := norm_axis * p

	raw_twist := quaternion(x = v_twist.x, y = v_twist.y, z = v_twist.z, w = q.w)
	len2 := raw_twist.x * raw_twist.x + raw_twist.y * raw_twist.y + raw_twist.z * raw_twist.z + raw_twist.w * raw_twist.w
	if len2 < 0.000001 {
		return q, identity_q
	}
	twist := linalg.quaternion_normalize(raw_twist)
	swing := q * linalg.quaternion_inverse(twist)
	return swing, twist
}

// Forearm / Wrist twist simulation:
// Splits the wrist's axial rotation along the forearm axis and applies a ratio (default 50%)
// to the forearm bone, eliminating candy-wrapper pinching without extra physical twist bones.
// Only distributes *active* wrist twist beyond the neutral/weapon rest orientation.
apply_forearm_wrist_twist :: proc(
	forearm_h, wrist_h: engine.Transform_Handle,
	twist_ratio: f32,
	char_rot: quaternion128,
	arm_rest: Limb_Rest_Pose,
	relative_rot: [4]f32 = engine.QUAT_IDENTITY,
) {
	w := engine.ctx_world()
	if w == nil do return
	if !engine.pool_valid(&w.transforms, engine.Handle(forearm_h)) do return
	if !engine.pool_valid(&w.transforms, engine.Handle(wrist_h)) do return

	forearm_pos := engine.transform_world_position(forearm_h)
	wrist_pos := engine.transform_world_position(wrist_h)
	axis := wrist_pos - forearm_pos
	if linalg.length2(axis) < 0.0001 do return

	wrist_rot_native := engine.quat_to_native(engine.transform_world_rotation(wrist_h))
	forearm_rot_native := engine.quat_to_native(engine.transform_world_rotation(forearm_h))

	// Wrist rotation in forearm's coordinate space
	relative_wrist_rot := linalg.quaternion_inverse(forearm_rot_native) * wrist_rot_native
	local_axis := linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(forearm_rot_native), axis)

	// Rest relative orientation between forearm and wrist in actor space
	rest_mid_rot := safe_quat_native(engine.quat_to_native(safe_quat(arm_rest.mid_rot)))
	rest_tip_rot := safe_quat_native(engine.quat_to_native(safe_quat(arm_rest.tip_rot)))
	rest_mid_world := linalg.quaternion_normalize(char_rot * rest_mid_rot)
	rest_tip_world := linalg.quaternion_normalize(char_rot * rest_tip_rot)
	rel_q := safe_quat_native(engine.quat_to_native(safe_quat(relative_rot)))
	expected_rest_relative := linalg.quaternion_normalize(linalg.quaternion_inverse(rest_mid_world) * rest_tip_world * rel_q)

	// Active deviation from the expected neutral wrist angle:
	active_wrist_delta := relative_wrist_rot * linalg.quaternion_inverse(expected_rest_relative)

	_, twist := swing_twist_decompose(active_wrist_delta, local_axis)

	ratio := clamp(twist_ratio, 0.0, 1.0)
	identity_q := engine.quat_to_native(engine.QUAT_IDENTITY)
	forearm_twist := linalg.quaternion_slerp(identity_q, twist, ratio)

	new_forearm_rot := linalg.quaternion_normalize(forearm_rot_native * forearm_twist)
	engine.transform_set_world_rotation(forearm_h, engine.quat_from_native(new_forearm_rot))

	// Re-assert exact solved world orientation on the wrist so forearm twist doesn't invert/distort hand controls
	engine.transform_set_world_rotation(wrist_h, engine.quat_from_native(wrist_rot_native))
}

// -----------------------------------------------------------------------------
// Full-Body Humanoid IK Solve
// -----------------------------------------------------------------------------

// Evaluates Pelvis, 3-Point Spline Spine/Chest, Head & LookAt Vision Aiming,
// Two-Bone IK for Limbs with geometric poles and toe roll, and Forearm Wrist Twist.
humanoid_ik_solve :: proc(
	bones: ^Humanoid_Bones,
	char_h: engine.Transform_Handle,
	rig: ^ControlRig,
	look_at_max_angle: f32 = 85.0,
	wrist_twist_ratio: f32 = 0.5,
) {
	w := engine.ctx_world()
	if w == nil || !bones.bound do return

	if !bones.left_leg_rest.valid {
		skeleton_capture_rest_pose(bones, char_h)
	}

	char_t := engine.pool_get(&w.transforms, engine.Handle(char_h))
	if char_t == nil do return
	char_tw := engine.transform_world(char_h)

	char_pos := char_tw.position
	char_rot := engine.quat_to_native(char_tw.rotation)
	char_scale := char_tw.scale

	local_to_world_pos :: proc(p_local: [3]f32, c_pos: [3]f32, c_rot: quaternion128, c_scale: [3]f32) -> [3]f32 {
		scaled := p_local * c_scale
		rotated := linalg.quaternion128_mul_vector3(c_rot, scaled)
		return c_pos + rotated
	}

	local_to_world_rot :: proc(q_local: [4]f32, c_rot: quaternion128) -> quaternion128 {
		safe_l := safe_quat(q_local)
		q_l := safe_quat_native(engine.quat_to_native(safe_l))
		return safe_quat_native(c_rot * q_l)
	}

	// 1. Pelvis (Position + Additive Rotation relative to rest bind pose)
	if engine.pool_valid(&w.transforms, engine.Handle(bones.pelvis)) {
		pelvis_world_pos := local_to_world_pos(rig.pelvis.position, char_pos, char_rot, char_scale)
		engine.transform_set_world_position(bones.pelvis, pelvis_world_pos)
		if bones.pelvis_rest.valid {
			rest_p_rot := local_to_world_rot(bones.pelvis_rest.rot, char_rot)
			if world_delta, has_delta := safe_quat_delta(rig.pelvis.rotation, char_rot); has_delta {
				engine.transform_set_world_rotation(bones.pelvis, engine.quat_from_native(safe_quat_native(world_delta * rest_p_rot)))
			} else {
				engine.transform_set_world_rotation(bones.pelvis, engine.quat_from_native(rest_p_rot))
			}
		}
	}

	// 2. Spine & Chest (3-Point Spline Crouch, Arch & Twist relative to rest bind pose)
	if bones.spine != {} && engine.pool_valid(&w.transforms, engine.Handle(bones.spine)) && bones.spine_rest.valid {
		rest_s_rot := local_to_world_rot(bones.spine_rest.rot, char_rot)
		cur_pelvis_pos := engine.transform_world_position(bones.pelvis) if engine.pool_valid(&w.transforms, engine.Handle(bones.pelvis)) else char_pos

		// Rest lower spine vector (from pelvis to spine)
		rest_spine_pos := local_to_world_pos(bones.spine_rest.pos, char_pos, char_rot, char_scale)
		rest_pelvis_pos := local_to_world_pos(bones.pelvis_rest.pos, char_pos, char_rot, char_scale) if bones.pelvis_rest.valid else char_pos
		rest_lower_dir := linalg.normalize0(rest_spine_pos - rest_pelvis_pos)
		if linalg.length2(rest_lower_dir) < 0.001 do rest_lower_dir = linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 1, 0})

		// Pelvis delta
		pelvis_delta := quaternion128(1)
		if bones.pelvis_rest.valid {
			rest_p_rot := local_to_world_rot(bones.pelvis_rest.rot, char_rot)
			cur_p_rot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(bones.pelvis)))
			pelvis_delta = cur_p_rot * linalg.quaternion_inverse(rest_p_rot)
		}
		natural_lower_dir := linalg.normalize0(linalg.quaternion128_mul_vector3(pelvis_delta, rest_lower_dir))

		// Target spine direction from rig.spine.position
		target_spine_pos := local_to_world_pos(rig.spine.position, char_pos, char_rot, char_scale)
		to_spine_target := target_spine_pos - cur_pelvis_pos
		target_lower_dir := linalg.normalize0(to_spine_target)
		if linalg.length2(to_spine_target) < 0.001 do target_lower_dir = natural_lower_dir

		lean_spine_delta := safe_quat_native(engine.quat_to_native(from_to_rotation(natural_lower_dir, target_lower_dir)))
		user_spine_delta, _ := safe_quat_delta(rig.spine.rotation, char_rot)
		total_spine_delta := safe_quat_native(lean_spine_delta * user_spine_delta)
		engine.transform_set_world_rotation(bones.spine, engine.quat_from_native(safe_quat_native(total_spine_delta * rest_s_rot)))
	}

	if bones.chest != {} && engine.pool_valid(&w.transforms, engine.Handle(bones.chest)) && bones.chest_rest.valid {
		rest_c_rot := local_to_world_rot(bones.chest_rest.rot, char_rot)
		cur_spine_pos := engine.transform_world_position(bones.spine) if bones.spine != {} && engine.pool_valid(&w.transforms, engine.Handle(bones.spine)) else char_pos

		rest_chest_pos := local_to_world_pos(bones.chest_rest.pos, char_pos, char_rot, char_scale)
		rest_spine_pos := local_to_world_pos(bones.spine_rest.pos, char_pos, char_rot, char_scale) if bones.spine_rest.valid else char_pos
		rest_upper_dir := linalg.normalize0(rest_chest_pos - rest_spine_pos)
		if linalg.length2(rest_upper_dir) < 0.001 do rest_upper_dir = linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 1, 0})

		spine_delta := quaternion128(1)
		if bones.spine_rest.valid {
			rest_s_rot := local_to_world_rot(bones.spine_rest.rot, char_rot)
			cur_s_rot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(bones.spine)))
			spine_delta = cur_s_rot * linalg.quaternion_inverse(rest_s_rot)
		}
		natural_upper_dir := linalg.normalize0(linalg.quaternion128_mul_vector3(spine_delta, rest_upper_dir))

		target_chest_pos := local_to_world_pos(rig.chest.position, char_pos, char_rot, char_scale)
		to_chest_target := target_chest_pos - cur_spine_pos
		target_upper_dir := linalg.normalize0(to_chest_target)
		if linalg.length2(to_chest_target) < 0.001 do target_upper_dir = natural_upper_dir

		lean_chest_delta := safe_quat_native(engine.quat_to_native(from_to_rotation(natural_upper_dir, target_upper_dir)))
		user_chest_delta, _ := safe_quat_delta(rig.chest.rotation, char_rot)
		total_chest_delta := safe_quat_native(lean_chest_delta * user_chest_delta)
		engine.transform_set_world_rotation(bones.chest, engine.quat_from_native(safe_quat_native(total_chest_delta * rest_c_rot)))
	}

	// 3. Head (Translation/Neck Tilt + Manual Rotation relative to rest + Vision Aiming)
	if engine.pool_valid(&w.transforms, engine.Handle(bones.head)) && bones.head_rest.valid {
		rest_h_rot := local_to_world_rot(bones.head_rest.rot, char_rot)
		cur_chest_pos := engine.transform_world_position(bones.chest) if bones.chest != {} && engine.pool_valid(&w.transforms, engine.Handle(bones.chest)) else char_pos

		rest_head_pos := local_to_world_pos(bones.head_rest.pos, char_pos, char_rot, char_scale)
		rest_chest_pos := local_to_world_pos(bones.chest_rest.pos, char_pos, char_rot, char_scale) if bones.chest_rest.valid else char_pos
		rest_neck_dir := linalg.normalize0(rest_head_pos - rest_chest_pos)
		if linalg.length2(rest_neck_dir) < 0.001 do rest_neck_dir = linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 1, 0})

		chest_delta := quaternion128(1)
		if bones.chest_rest.valid {
			rest_c_rot := local_to_world_rot(bones.chest_rest.rot, char_rot)
			cur_c_rot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(bones.chest)))
			chest_delta = cur_c_rot * linalg.quaternion_inverse(rest_c_rot)
		}
		natural_neck_dir := linalg.normalize0(linalg.quaternion128_mul_vector3(chest_delta, rest_neck_dir))

		target_head_pos := local_to_world_pos(rig.head.position, char_pos, char_rot, char_scale)
		to_head_target := target_head_pos - cur_chest_pos
		target_neck_dir := linalg.normalize0(to_head_target)
		if linalg.length2(to_head_target) < 0.001 do target_neck_dir = natural_neck_dir

		lean_neck_delta := safe_quat_native(engine.quat_to_native(from_to_rotation(natural_neck_dir, target_neck_dir)))
		user_head_delta, _ := safe_quat_delta(rig.head.rotation, char_rot)
		cur_head_rot := safe_quat_native(lean_neck_delta * user_head_delta * rest_h_rot)

		if linalg.length2(rig.look_at_target) > 0.001 {
			char_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))
			char_up := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 1, 0}))

			head_local_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(rest_h_rot), char_fwd))
			head_local_up := linalg.normalize0(linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(rest_h_rot), char_up))

			current_face_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(cur_head_rot, head_local_fwd))
			current_face_up := linalg.normalize0(linalg.quaternion128_mul_vector3(cur_head_rot, head_local_up))

			// Aim origin: derived from head bone pivot in world space.
			// Eliminates feedback loops and jitter during eye socket dragging or near-camera targeting.
			head_pos := engine.transform_world_position(bones.head)
			target_look_pos := local_to_world_pos(rig.look_at_target, char_pos, char_rot, char_scale)
			to_look := target_look_pos - head_pos
			dist2 := linalg.length2(to_look)

			if dist2 > 0.0001 {
				target_dir := linalg.normalize0(to_look)
				dot := clamp(linalg.dot(current_face_fwd, target_dir), -1.0, 1.0)
				angle_deg := linalg.to_degrees(linalg.acos(dot))
				max_deg := look_at_max_angle > 0 ? look_at_max_angle : 85.0

				// Clamp to maximum look angle instead of dropping out (avoids head snapping away up close)
				if angle_deg > max_deg {
					axis := linalg.normalize0(linalg.cross(current_face_fwd, target_dir))
					if linalg.length2(axis) < 0.0001 do axis = current_face_up
					clamp_q := linalg.quaternion_angle_axis_f32(linalg.to_radians(max_deg), axis)
					target_dir = linalg.normalize0(linalg.quaternion128_mul_vector3(clamp_q, current_face_fwd))
				}

				aim_q := safe_quat_native(engine.quat_to_native(from_to_rotation(current_face_fwd, target_dir)))
				cur_head_rot = safe_quat_native(aim_q * cur_head_rot)
			}
		}
		engine.transform_set_world_rotation(bones.head, engine.quat_from_native(cur_head_rot))
	}

	char_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))
	char_back := -char_fwd

	// 4. Left Leg Two-Bone IK + Toe Pitch
	if bones.left_leg_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_thigh)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_calf)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_foot)) {

		target_pos := local_to_world_pos(rig.left_foot.position, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(rig.left_knee_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if world_delta, has_delta := safe_quat_delta(rig.left_foot.rotation, char_rot); has_delta {
			rot_delta = world_delta
		}

		solve_two_bone_limb(
			bones.left_thigh, bones.left_calf, bones.left_foot,
			bones.left_leg_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0,
			rig.left_foot.rotation_weight,
			rot_delta,
			default_pole_dir = char_fwd,
		)

		if bones.left_toe != {} && engine.pool_valid(&w.transforms, engine.Handle(bones.left_toe)) && bones.left_toe_rest.valid {
			rest_foot_rot := local_to_world_rot(bones.left_leg_rest.tip_rot, char_rot)
			rest_toe_rot := local_to_world_rot(bones.left_toe_rest.rot, char_rot)
			rest_toe_rel := linalg.quaternion_inverse(rest_foot_rot) * rest_toe_rot

			cur_foot_rot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(bones.left_foot)))
			natural_toe_rot := safe_quat_native(cur_foot_rot * rest_toe_rel)

			if abs(rig.left_toe_pitch) > 0.001 {
				char_right := linalg.quaternion128_mul_vector3(cur_foot_rot, [3]f32{1, 0, 0})
				toe_rot := linalg.quaternion_angle_axis_f32(rig.left_toe_pitch, char_right)
				new_toe := safe_quat_native(toe_rot * natural_toe_rot)
				engine.transform_set_world_rotation(bones.left_toe, engine.quat_from_native(new_toe))
			} else {
				engine.transform_set_world_rotation(bones.left_toe, engine.quat_from_native(natural_toe_rot))
			}
		}
	}

	// 5. Right Leg Two-Bone IK + Toe Pitch
	if bones.right_leg_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_thigh)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_calf)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_foot)) {

		target_pos := local_to_world_pos(rig.right_foot.position, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(rig.right_knee_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if world_delta, has_delta := safe_quat_delta(rig.right_foot.rotation, char_rot); has_delta {
			rot_delta = world_delta
		}

		solve_two_bone_limb(
			bones.right_thigh, bones.right_calf, bones.right_foot,
			bones.right_leg_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0,
			rig.right_foot.rotation_weight,
			rot_delta,
			default_pole_dir = char_fwd,
		)

		if bones.right_toe != {} && engine.pool_valid(&w.transforms, engine.Handle(bones.right_toe)) && bones.right_toe_rest.valid {
			rest_foot_rot := local_to_world_rot(bones.right_leg_rest.tip_rot, char_rot)
			rest_toe_rot := local_to_world_rot(bones.right_toe_rest.rot, char_rot)
			rest_toe_rel := linalg.quaternion_inverse(rest_foot_rot) * rest_toe_rot

			cur_foot_rot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(bones.right_foot)))
			natural_toe_rot := safe_quat_native(cur_foot_rot * rest_toe_rel)

			if abs(rig.right_toe_pitch) > 0.001 {
				char_right := linalg.quaternion128_mul_vector3(cur_foot_rot, [3]f32{1, 0, 0})
				toe_rot := linalg.quaternion_angle_axis_f32(rig.right_toe_pitch, char_right)
				new_toe := safe_quat_native(toe_rot * natural_toe_rot)
				engine.transform_set_world_rotation(bones.right_toe, engine.quat_from_native(new_toe))
			} else {
				engine.transform_set_world_rotation(bones.right_toe, engine.quat_from_native(natural_toe_rot))
			}
		}
	}

	// 6. Left Arm Two-Bone IK
	if bones.left_arm_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_upperarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_lowerarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_hand)) {

		target_pos := local_to_world_pos(rig.left_hand.position, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(rig.left_elbow_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if world_delta, has_delta := safe_quat_delta(rig.left_hand.rotation, char_rot); has_delta {
			rot_delta = world_delta
		}

		solve_two_bone_limb(
			bones.left_upperarm, bones.left_lowerarm, bones.left_hand,
			bones.left_arm_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0,
			rig.left_hand.rotation_weight,
			rot_delta,
			default_pole_dir = char_back,
			relative_rot = rig.left_hand.relative_rotation,
		)

		apply_forearm_wrist_twist(bones.left_lowerarm, bones.left_hand, wrist_twist_ratio, char_rot, bones.left_arm_rest, rig.left_hand.relative_rotation)
	}

	// 7. Right Arm Two-Bone IK
	if bones.right_arm_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_upperarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_lowerarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_hand)) {

		target_pos := local_to_world_pos(rig.right_hand.position, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(rig.right_elbow_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if world_delta, has_delta := safe_quat_delta(rig.right_hand.rotation, char_rot); has_delta {
			rot_delta = world_delta
		}

		solve_two_bone_limb(
			bones.right_upperarm, bones.right_lowerarm, bones.right_hand,
			bones.right_arm_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0,
			rig.right_hand.rotation_weight,
			rot_delta,
			default_pole_dir = char_back,
			relative_rot = rig.right_hand.relative_rotation,
		)
		apply_forearm_wrist_twist(bones.right_lowerarm, bones.right_hand, wrist_twist_ratio, char_rot, bones.right_arm_rest, rig.right_hand.relative_rotation)
	}
}
