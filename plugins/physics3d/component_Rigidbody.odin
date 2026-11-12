package physics3d

// Unity-literal Rigidbody (3D): authored as plain data, synced to a Jolt
// body by the fixed step. Unity's 3D model — no body-type enum: a collider
// WITHOUT a Rigidbody is static, is_kinematic switches dynamic/kinematic.
// The live Jolt BodyID is runtime-only — for anything not wrapped here
// (forces, joints, mass overrides) use body_of(tH) and moonhug:external/jolt.

import jolt "moonhug:external/jolt"
import "moonhug:engine"

@(component={menu="Physics/Rigidbody"})
@(typ_guid={guid = "82976d39-c450-4464-87e2-c260c430c157"})
Rigidbody :: struct {
	using base:      engine.CompData `inspect:"-"`,
	channel:         Collision_Channel,
	use_gravity:     bool,
	is_kinematic:    bool,
	linear_damping:  f32,
	angular_damping: f32,
	continuous:      bool, // continuous collision detection (Jolt LinearCast)
	freeze_position: [3]bool,
	freeze_rotation: [3]bool,

	body:                 jolt.BodyID `json:"-" inspect:"-"`,
	last_synced_pos:      [3]f32      `json:"-" inspect:"-"`,
	last_synced_rot:      [4]f32      `json:"-" inspect:"-"`,
	has_synced_transform: bool        `json:"-" inspect:"-"`,

	// Relativistic Jolt Pre/Post-Step Time Dilation Bridge state (runtime-only)
	true_linear_vel:      [3]f32      `json:"-" inspect:"-"`,
	true_angular_vel:     [3]f32      `json:"-" inspect:"-"`,
	applied_time_scale:   f32         `json:"-" inspect:"-"`,
	has_dilated_vel:      bool        `json:"-" inspect:"-"`,
	frozen_by_time_scale: bool        `json:"-" inspect:"-"`,
}

reset_Rigidbody :: proc(comp: ^Rigidbody) {
	cleanup_Rigidbody(comp)
	comp.channel            = .Dynamic_Body
	comp.use_gravity        = true
	comp.applied_time_scale = 1.0
}

cleanup_Rigidbody :: proc(comp: ^Rigidbody) {
	_destroy_body(&comp.body)
	engine.comp_zero(comp)
}

// Live destroy (transform_destroy_components) — the body must die with the
// component or it keeps colliding as a ghost.
on_destroy_Rigidbody :: proc(comp: ^Rigidbody) {
	_destroy_body(&comp.body)
}

// Sets the real-world linear (and optional angular) velocity on a `Rigidbody`.
rb_set_velocity :: proc(rb: ^Rigidbody, lin_vel: [3]f32, ang_vel: [3]f32 = {0, 0, 0}) {
	if rb == nil do return
	rb.true_linear_vel  = lin_vel
	rb.true_angular_vel = ang_vel
	if _state.world_ready && _state.body_interface != nil && is_body_valid(rb.body) && !rb.frozen_by_time_scale {
		lv := lin_vel
		av := ang_vel
		jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &lv, &av)
	}
}

// Returns the real-world (un-dilated) linear velocity of a `Rigidbody`.
rb_get_velocity :: proc(rb: ^Rigidbody) -> [3]f32 {
	if rb == nil do return {}
	if rb.frozen_by_time_scale do return rb.true_linear_vel
	if _state.world_ready && _state.body_interface != nil && is_body_valid(rb.body) {
		lv, av: [3]f32
		jolt.BodyInterface_GetLinearAndAngularVelocity(_state.body_interface, rb.body, &lv, &av)
		return lv
	}
	return rb.true_linear_vel
}
