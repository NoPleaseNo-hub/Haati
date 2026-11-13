package physics3d_tests

import "core:math/linalg"
import "core:testing"
import "haati:engine"
import common "haati:tests/common"
import physics3d "haati:packages/physics3d"

@(test)
test_physics3d_pose_interpolation_and_joints_controllers :: proc(t: ^testing.T) {
	// 1. Mid-step pose interpolation & >5.0m teleport snap.
	rb_dummy := physics3d.Rigidbody{
		interpolate   = true,
		has_prev_pose = true,
		prev_pos      = {0, 0, 0},
		curr_pos      = {1, 2, 2},
		prev_rot      = engine.QUAT_IDENTITY,
		curr_rot      = engine.QUAT_IDENTITY,
	}
	mid_pos, _ := physics3d.physics_interpolate_pose(&rb_dummy, 0.5)
	testing.expect(t, linalg.distance(mid_pos, [3]f32{0.5, 1, 1}) < 1e-4, "expected linear midpoint at alpha=0.5")

	rb_dummy.curr_pos = {10, 0, 0}
	snap_pos, _ := physics3d.physics_interpolate_pose(&rb_dummy, 0.5)
	testing.expect(t, linalg.distance(snap_pos, [3]f32{10, 0, 0}) < 1e-4, "expected >5m teleport snap without smearing")

	alpha := engine.fixed_interpolation_alpha()
	testing.expect(t, alpha >= 0.0 && alpha <= 1.0, "expected fixed_interpolation_alpha within [0, 1]")

	// 2. Live Jolt world with CharacterController3D + PhysicsJoint3D (Hinge) across 3 fixed steps.
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	anchor := engine.transform_new("Anchor")
	engine.transform_set_world_position(anchor, {0, 5, 0})
	_, a_rb_ptr := engine.transform_add_comp(anchor, .Rigidbody)
	a_rb := cast(^physics3d.Rigidbody)a_rb_ptr
	a_rb.enabled = true
	a_rb.is_kinematic = true
	_, a_col_ptr := engine.transform_add_comp(anchor, .BoxCollider)
	a_col := cast(^physics3d.BoxCollider)a_col_ptr
	a_col.enabled = true
	a_col.size = {1, 1, 1}
	a_col.density = 1.0
	a_col.friction = 0.5

	pendulum := engine.transform_new("Pendulum")
	engine.transform_set_world_position(pendulum, {1, 4, 0})
	_, p_rb_ptr := engine.transform_add_comp(pendulum, .Rigidbody)
	p_rb := cast(^physics3d.Rigidbody)p_rb_ptr
	p_rb.enabled = true
	p_rb.use_gravity = true
	_, p_col_ptr := engine.transform_add_comp(pendulum, .BoxCollider)
	p_col := cast(^physics3d.BoxCollider)p_col_ptr
	p_col.enabled = true
	p_col.size = {0.5, 1.5, 0.5}
	p_col.density = 1.0
	p_col.friction = 0.5
	_, jnt_ptr := engine.transform_add_comp(pendulum, .PhysicsJoint3D)
	jnt := cast(^physics3d.PhysicsJoint3D)jnt_ptr
	jnt.enabled = true
	jnt.kind = .Hinge
	jnt.connected_body = engine.Ref{handle = engine.Handle(anchor)}

	player := engine.transform_new("Player")
	engine.transform_set_world_position(player, {5, 1, 0})
	_, cc_ptr := engine.transform_add_comp(player, .CharacterController3D)
	cc := cast(^physics3d.CharacterController3D)cc_ptr
	cc.enabled = true
	cc.desired_velocity = {2, 0, 0}

	for _ in 0 ..< 3 {
		physics3d.physics_step(1.0 / 60.0)
	}
	testing.expect(t, jnt.constraint != nil, "expected live Jolt Hinge constraint")
	testing.expect(t, cc.character != nil, "expected live Jolt CharacterVirtual")
	testing.expect(t, engine.pool_valid(&tc.world.transforms, engine.Handle(pendulum)), "pendulum survived physics steps")
	testing.expect(t, engine.pool_valid(&tc.world.transforms, engine.Handle(player)), "character controller survived physics steps")
}
