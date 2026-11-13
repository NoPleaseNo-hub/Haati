package control_rig

// SpringBone: High-Stability Second-Order Particle-Tip Spring Dynamics.
// Designed for soft & secondary bone animation (breasts, hair, ponytails, skirts, capes, ears, tails, accessories).
//
// Key Features:
// 1. Particle-Tip Simulation: Avoids Euler gimbal lock and trigonometric flipping.
// 2. Hard Bone Length Invariant: Tip distance strictly preserved (no rubber-banding).
// 3. Hard Safety Cone Constraint: Restricts deflection to max_angle_deg, preventing internal body penetration.
// 4. Roll-Preserving Delta Math: Maintains authentic joint bind orientation and roll angles.

import "core:math"
import "core:math/linalg"
import engine "haati:engine"

@(component={menu="Physics/SpringBone"})
@(typ_guid={guid = "7c3b9e14-2a5d-4f81-9b0e-6c8d1f2a3e54"})
SpringBone :: struct {
	using base:       engine.CompData `inspect:"-"`,

	// Physical simulation parameters
	stiffness:        f32,        // Restoring spring tension force (default 45.0, range 1.0 - 200.0)
	damping:          f32,        // Velocity dissipation coefficient (default 0.70, range 0.05 - 1.0)
	gravity:          [3]f32,     // Directional gravity pull in world space (default {0, -1.0, 0})
	drag:             f32,        // Aerodynamic drag / air resistance (default 0.05, range 0.0 - 0.5)
	max_angle_deg:    f32,        // Hard safety deflection limit cone in degrees (default 35.0, range 5.0 - 85.0)
	bone_length:      f32,        // Virtual tip length along local forward axis (default 0.10, range 0.01 - 0.50)
	forward_axis:     [3]f32,     // Local direction vector from base joint to tip (default {0, 0, 1})

	// Runtime simulation state (not serialized)
	current_tip_pos:  [3]f32      `json:"-" inspect:"-"`,
	prev_tip_pos:     [3]f32      `json:"-" inspect:"-"`,
	velocity:         [3]f32      `json:"-" inspect:"-"`,
	rest_local_rot:   [4]f32      `json:"-" inspect:"-"`,
	initialized:      bool        `json:"-" inspect:"-"`,
}

reset_SpringBone :: proc(sb: ^SpringBone) {
	sb.stiffness       = 45.0
	sb.damping         = 0.70
	sb.gravity         = {0, -1.0, 0}
	sb.drag            = 0.05
	sb.max_angle_deg   = 35.0
	sb.bone_length     = 0.10
	sb.forward_axis    = {0, 0, 1}
	sb.current_tip_pos = {}
	sb.prev_tip_pos    = {}
	sb.velocity        = {}
	sb.rest_local_rot  = {0, 0, 0, 1}
	sb.initialized     = false
}

cleanup_SpringBone :: proc(sb: ^SpringBone) {
	engine.comp_zero(sb)
}

on_destroy_SpringBone :: proc(sb: ^SpringBone) {
	cleanup_SpringBone(sb)
}

// Resets runtime state so the spring re-anchors to the current transform rest pose
spring_bone_reset_simulation :: proc(sb: ^SpringBone) {
	sb.initialized = false
}

@(update={order=4})
spring_bone_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	if dt <= 0.0001 && engine.unscaled_dt() <= 0.0001 do return

	it := engine.pool_iterator(spring_bones(w))
	for sb, _ in engine.pool_next(&it) {
		if !sb.enabled do continue
		bone_h := engine.Transform_Handle(sb.owner)
		if bone_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do continue
		clamped_dt := min(engine.transform_dt(bone_h, dt), 0.0333)
		if clamped_dt <= 0.0001 do continue

		bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
		if bt == nil do continue

		// Base joint world position
		base_pos := engine.transform_world_position(bone_h)

		// Parent world rotation
		parent_world_rot := engine.QUAT_IDENTITY
		if bt.parent.handle != {} {
			parent_world_rot = engine.transform_world_rotation(engine.Transform_Handle(bt.parent.handle))
		}
		parent_world_q := engine.quat_to_native(parent_world_rot)
		rest_local_q   := engine.quat_to_native(sb.rest_local_rot)
		rest_world_q   := parent_world_q * rest_local_q

		// Initialize rest orientation and tip tracking
		if !sb.initialized {
			sb.rest_local_rot = bt.rotation
			rest_local_q = engine.quat_to_native(sb.rest_local_rot)
			rest_world_q = parent_world_q * rest_local_q

			fwd := linalg.vector_normalize0(sb.forward_axis)
			if linalg.vector_length2(fwd) < 0.001 do fwd = {0, 0, 1}
			sb.forward_axis = fwd
			if sb.bone_length < 0.01 do sb.bone_length = 0.10

			tip_offset := linalg.quaternion128_mul_vector3(rest_world_q, sb.forward_axis * sb.bone_length)
			sb.current_tip_pos = base_pos + tip_offset
			sb.prev_tip_pos = sb.current_tip_pos
			sb.velocity = {}
			sb.initialized = true
		}

		// Target rest tip position in world space this frame:
		rest_tip_dir := linalg.vector_normalize0(linalg.quaternion128_mul_vector3(rest_world_q, sb.forward_axis))
		target_tip_pos := base_pos + rest_tip_dir * sb.bone_length

		// 1. Spring restoring force towards target rest position
		disp := sb.current_tip_pos - target_tip_pos
		spring_force := -sb.stiffness * disp

		// 2. Velocity damping & aerodynamic drag
		damping_force := -sb.damping * sb.velocity
		drag_force := -sb.drag * sb.velocity

		// 3. Total acceleration: F = ma (assuming unit mass m = 1.0)
		accel := spring_force + damping_force + drag_force + sb.gravity

		// 4. Semi-implicit Euler integration
		sb.velocity += accel * clamped_dt
		sb.current_tip_pos += sb.velocity * clamped_dt

		// 5. Hard bone length constraint: preserve exact distance from base_pos
		delta := sb.current_tip_pos - base_pos
		curr_len := linalg.vector_length(delta)
		if curr_len > 0.0001 {
			sim_dir := delta / curr_len

			// 6. Hard safety cone constraint: clamp angle between sim_dir and rest_tip_dir
			max_rad := math.to_radians(clamp(sb.max_angle_deg, 5.0, 85.0))
			dot := linalg.vector_dot(rest_tip_dir, sim_dir)
			if dot < math.cos(max_rad) {
				// Tip has exceeded the safety cone! Clamp to cone boundary
				axis := linalg.vector_cross3(rest_tip_dir, sim_dir)
				if linalg.vector_length2(axis) > 0.0001 {
					axis = linalg.vector_normalize(axis)
					clamp_q := linalg.quaternion_angle_axis(max_rad, axis)
					sim_dir = linalg.quaternion128_mul_vector3(clamp_q, rest_tip_dir)
				} else {
					sim_dir = rest_tip_dir
				}
				// Damp velocity component pointing outside the cone
				sb.velocity *= 0.5
			}

			sb.current_tip_pos = base_pos + sim_dir * sb.bone_length

			// 7. Derive local rotation preserving rest roll:
			inv_parent_q := linalg.quaternion_inverse(parent_world_q)
			local_sim_dir := linalg.vector_normalize0(linalg.quaternion128_mul_vector3(inv_parent_q, sim_dir))

			rest_local_dir := linalg.vector_normalize0(linalg.quaternion128_mul_vector3(rest_local_q, sb.forward_axis))

			delta_rot := from_to_rotation(rest_local_dir, local_sim_dir)
			final_local_q := engine.quat_to_native(delta_rot) * rest_local_q
			bt.rotation = engine.quat_from_native(linalg.quaternion_normalize(final_local_q))
		}
	}
}
