package physics3d

// PhysicsJoint3D: Jolt TwoBodyConstraint component supporting Fixed, Hinge,
// and SwingTwist joints between two Rigidbodies (or anchored to the world).

import "core:math"
import "core:math/linalg"
import jolt "haati:external/jolt"
import "haati:engine"

PhysicsJoint_Kind :: enum u8 {
	Fixed       = 0,
	Hinge       = 1,
	Swing_Twist = 2,
}

@(component={menu="Physics/PhysicsJoint3D"})
@(typ_guid={guid = "e4f5a6b7-2233-4d4e-9f00-112233445566"})
PhysicsJoint3D :: struct {
	using base:          engine.CompData `inspect:"-"`,
	kind:                PhysicsJoint_Kind,
	connected_body:      engine.Ref,
	anchor_local:        [3]f32,
	axis:                [3]f32,
	normal_axis:         [3]f32,
	use_limits:          bool,
	min_angle_deg:       f32,
	max_angle_deg:       f32,
	swing_half_cone_deg: f32 `decor:range(1,175)`,
	twist_min_deg:       f32 `decor:range(-180,0)`,
	twist_max_deg:       f32 `decor:range(0,180)`,
	max_friction_torque: f32 `decor:min(0)`,
	break_force:         f32 `decor:min(0)`,

	is_broken:           bool `json:"-"`,

	constraint:          ^jolt.Constraint `json:"-" inspect:"-"`,
	bound_kind:          PhysicsJoint_Kind `json:"-" inspect:"-"`,
	bound_body_a:        jolt.BodyID      `json:"-" inspect:"-"`,
	bound_body_b:        jolt.BodyID      `json:"-" inspect:"-"`,
}

reset_PhysicsJoint3D :: proc(joint: ^PhysicsJoint3D) {
	cleanup_PhysicsJoint3D(joint)
	joint.kind                = .Hinge
	joint.axis                = {1, 0, 0}
	joint.normal_axis         = {0, 1, 0}
	joint.min_angle_deg       = -45.0
	joint.max_angle_deg       = 45.0
	joint.swing_half_cone_deg = 45.0
	joint.twist_min_deg       = -30.0
	joint.twist_max_deg       = 30.0
}

_destroy_joint_runtime :: proc(joint: ^PhysicsJoint3D) {
	if joint == nil do return
	if joint.constraint != nil {
		if _state.world_ready && _state.system != nil {
			jolt.PhysicsSystem_RemoveConstraint(_state.system, joint.constraint)
		}
		jolt.Constraint_Destroy(joint.constraint)
		joint.constraint = nil
	}
	joint.bound_body_a = 0
	joint.bound_body_b = 0
}

cleanup_PhysicsJoint3D :: proc(joint: ^PhysicsJoint3D) {
	_destroy_joint_runtime(joint)
	engine.comp_zero(joint)
}

on_destroy_PhysicsJoint3D :: proc(joint: ^PhysicsJoint3D) {
	_destroy_joint_runtime(joint)
}

_resolve_joint_axes :: proc(axis, normal_axis: [3]f32) -> (ax, norm: [3]f32) {
	ax = linalg.normalize0(axis)
	if linalg.length2(ax) < 1e-6 do ax = {1, 0, 0}
	norm = linalg.normalize0(normal_axis)
	if linalg.length2(norm) < 1e-6 || abs(linalg.dot(ax, norm)) > 0.99 {
		fallback := [3]f32{0, 1, 0}
		if abs(linalg.dot(ax, fallback)) > 0.99 do fallback = {0, 0, 1}
		norm = linalg.normalize0(linalg.cross(ax, fallback))
	} else {
		norm = linalg.normalize0(norm - ax * linalg.dot(ax, norm))
	}
	return ax, norm
}

_sync_joints :: proc(w: ^engine.World) {
	pool := physics_joint3_ds(w)
	if pool == nil || !_state.world_ready || _state.system == nil do return

	it := engine.pool_iterator(pool)
	for joint, _ in engine.pool_next(&it) {
		if !joint.enabled || joint.is_broken {
			if joint.constraint != nil do _destroy_joint_runtime(joint)
			continue
		}
		if !engine.pool_valid(&w.transforms, engine.Handle(joint.owner)) || !engine.transform_active_in_hierarchy(joint.owner) {
			if joint.constraint != nil do _destroy_joint_runtime(joint)
			continue
		}

		body_a_id, has_a := body_of(joint.owner)
		if !has_a || !is_body_valid(body_a_id) {
			if joint.constraint != nil do _destroy_joint_runtime(joint)
			continue
		}

		body_b_id: jolt.BodyID = 0
		body_b_ptr: ^jolt.Body = jolt.Body_GetFixedToWorldBody()
		other_h: engine.Transform_Handle
		if engine.pool_valid(&w.transforms, joint.connected_body.handle) {
			other_h = engine.Transform_Handle(joint.connected_body.handle)
		}
		if other_h != {} && other_h != joint.owner {
			if bid, has_b := body_of(other_h); has_b && is_body_valid(bid) {
				body_b_id = bid
				body_b_ptr = jolt.PhysicsSystem_GetBodyPtr(_state.system, bid)
			} else {
				// Connected target has no live Rigidbody yet — wait before creating constraint.
				if joint.constraint != nil do _destroy_joint_runtime(joint)
				continue
			}
		}

		if joint.constraint != nil &&
		   joint.bound_kind == joint.kind &&
		   joint.bound_body_a == body_a_id &&
		   joint.bound_body_b == body_b_id {
			continue
		}

		_destroy_joint_runtime(joint)

		body_a_ptr := jolt.PhysicsSystem_GetBodyPtr(_state.system, body_a_id)
		if body_a_ptr == nil || body_b_ptr == nil do continue

		tw := engine.transform_world(joint.owner)
		q := engine.quat_to_native(tw.rotation)
		world_anchor := tw.position + linalg.quaternion128_mul_vector3(q, joint.anchor_local)
		ax_local, norm_local := _resolve_joint_axes(joint.axis, joint.normal_axis)
		ax_world := linalg.quaternion128_mul_vector3(q, ax_local)
		norm_world := linalg.quaternion128_mul_vector3(q, norm_local)

		c: ^jolt.Constraint
		switch joint.kind {
		case .Fixed:
			cfg: jolt.FixedConstraintSettings
			jolt.FixedConstraintSettings_Init(&cfg)
			cfg.space = .WorldSpace
			cfg.point1 = world_anchor
			cfg.axisX1 = ax_world
			cfg.axisY1 = norm_world
			cfg.point2 = world_anchor
			cfg.axisX2 = ax_world
			cfg.axisY2 = norm_world
			c = auto_cast jolt.FixedConstraint_Create(&cfg, body_a_ptr, body_b_ptr)

		case .Hinge:
			cfg: jolt.HingeConstraintSettings
			jolt.HingeConstraintSettings_Init(&cfg)
			cfg.space = .WorldSpace
			cfg.point1 = world_anchor
			cfg.hingeAxis1 = ax_world
			cfg.normalAxis1 = norm_world
			cfg.point2 = world_anchor
			cfg.hingeAxis2 = ax_world
			cfg.normalAxis2 = norm_world
			cfg.maxFrictionTorque = max(joint.max_friction_torque, 0.0)
			if joint.use_limits {
				cfg.limitsMin = math.to_radians(joint.min_angle_deg)
				cfg.limitsMax = math.to_radians(joint.max_angle_deg)
			} else {
				cfg.limitsMin = -math.PI
				cfg.limitsMax = math.PI
			}
			c = auto_cast jolt.HingeConstraint_Create(&cfg, body_a_ptr, body_b_ptr)

		case .Swing_Twist:
			cfg: jolt.SwingTwistConstraintSettings
			jolt.SwingTwistConstraintSettings_Init(&cfg)
			cfg.space = .WorldSpace
			cfg.position1 = world_anchor
			cfg.twistAxis1 = ax_world
			cfg.planeAxis1 = norm_world
			cfg.position2 = world_anchor
			cfg.twistAxis2 = ax_world
			cfg.planeAxis2 = norm_world
			half_cone := math.to_radians(clamp(joint.swing_half_cone_deg > 0 ? joint.swing_half_cone_deg : f32(45.0), f32(1.0), f32(175.0)))
			cfg.normalHalfConeAngle = half_cone
			cfg.planeHalfConeAngle = half_cone
			cfg.twistMinAngle = math.to_radians(joint.twist_min_deg)
			cfg.twistMaxAngle = math.to_radians(joint.twist_max_deg)
			cfg.maxFrictionTorque = max(joint.max_friction_torque, 0.0)
			c = auto_cast jolt.SwingTwistConstraint_Create(&cfg, body_a_ptr, body_b_ptr)
		}

		if c != nil {
			jolt.PhysicsSystem_AddConstraint(_state.system, c)
			joint.constraint = c
			joint.bound_kind = joint.kind
			joint.bound_body_a = body_a_id
			joint.bound_body_b = body_b_id
		}
	}
}

_step_joints :: proc(w: ^engine.World) {
	pool := physics_joint3_ds(w)
	if pool == nil || !_state.world_ready || _state.system == nil do return

	it := engine.pool_iterator(pool)
	for joint, _ in engine.pool_next(&it) {
		if joint.constraint == nil || joint.is_broken || joint.break_force <= 0.0 do continue
		lambda_v: jolt.Vec3
		switch joint.bound_kind {
		case .Fixed:
			jolt.FixedConstraint_GetTotalLambdaPosition(auto_cast joint.constraint, &lambda_v)
		case .Hinge:
			jolt.HingeConstraint_GetTotalLambdaPosition(auto_cast joint.constraint, &lambda_v)
		case .Swing_Twist:
			jolt.SwingTwistConstraint_GetTotalLambdaPosition(auto_cast joint.constraint, &lambda_v)
		}
		if linalg.length(lambda_v) > joint.break_force {
			joint.is_broken = true
			_destroy_joint_runtime(joint)
		}
	}
}
