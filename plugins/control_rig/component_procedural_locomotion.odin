package control_rig

// ProceduralLocomotion: Optional Procedural Bipedal Gait & Dynamics Component.
// Separated from ControlRig so characters can use IK rig controls and solvers
// without unintended procedural monster locomotion.
// Features:
// 1. Procedural walking gait and stride simulation.
// 2. Euphoria-style physical dynamics, impulses, fatigue, and recoil.
// 3. Head look-at tracking.

import "core:math/linalg"
import engine "haati:engine"

@(component={menu="Animation/ProceduralLocomotion"})
@(typ_guid={guid = "d87a4192-36c1-4b78-9e51-64d8a1f28e93"})
ProceduralLocomotion :: struct {
	using base:         engine.CompData `inspect:"-"`,
	active:             bool,
	mode:               Gait_Mode,
	preset:             Pose_Preset,
	speed:              f32,
	config:             Gait_Config,
	look_target:        [3]f32,
	enable_look_at:     bool,
	enable_dynamics:    bool,
	drive_skeleton:     bool, // When true, procedural gait articulates skeleton bones

	// Euphoria Muscle Fatigue & Second-Order Physics
	fatigue:            f32, // 0.0 = rested, 1.0 = exhausted
	stiffness:          f32, // Spring tension k (default 180.0)
	damping:            f32, // Damping ratio d (default 22.0)
	body_lean_strength: f32, // Dynamic turning lean multiplier

	gait_state:         Gait_State `inspect:"-"`,
	rest_pose:          Procedural_Pose `inspect:"-"`,
	target_pose:        Procedural_Pose `inspect:"-"`,
	dynamic_pose:       Procedural_Pose `inspect:"-"`,
	dynamics:           ControlRig_Dynamics `inspect:"-"`,
}

reset_ProceduralLocomotion :: proc(loco: ^ProceduralLocomotion) {
	loco.active = false
	loco.mode = .Walk
	loco.preset = .Rest_Idle
	loco.speed = 2.0
	loco.config = default_gait_config()
	loco.look_target = {0, 1.6, 5.0}
	loco.enable_look_at = false
	loco.enable_dynamics = true
	loco.drive_skeleton = false
	loco.fatigue = 0.0
	loco.stiffness = 180.0
	loco.damping = 22.0
	loco.body_lean_strength = 1.0

	gait_init(&loco.gait_state)
	loco.rest_pose = default_rest_pose()
	loco.target_pose = loco.rest_pose
	loco.dynamic_pose = loco.rest_pose
	dynamics_init(&loco.dynamics, loco.rest_pose)
}

cleanup_ProceduralLocomotion :: proc(loco: ^ProceduralLocomotion) {
	engine.comp_zero(loco)
}

on_destroy_ProceduralLocomotion :: proc(loco: ^ProceduralLocomotion) {
	cleanup_ProceduralLocomotion(loco)
}

@(inspector_button={label="Test Recoil Impulse", row=-1})
procedural_locomotion_test_recoil :: proc(loco: ^ProceduralLocomotion) {
	dynamics_add_body_impulse(&loco.dynamics, [3]f32{0, 2.0, -18.0})
}

procedural_locomotion_add_impulse :: proc(loco: ^ProceduralLocomotion, effector: Effector_Id, impulse: [3]f32) {
	dynamics_add_impulse(&loco.dynamics, effector, impulse)
}

procedural_locomotion_add_body_impulse :: proc(loco: ^ProceduralLocomotion, impulse: [3]f32) {
	dynamics_add_body_impulse(&loco.dynamics, impulse)
}

@(update={order=1})
procedural_locomotion_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(procedural_locomotions(w))
	for loco, _ in engine.pool_next(&it) {
		if !loco.active do continue
		loco_dt := engine.transform_dt(loco.owner, dt)
		if loco_dt <= 1e-6 do continue

		// 1. Evaluate Intended Kinematic Target Pose
		switch loco.mode {
		case .Idle, .Walk:
			loco.gait_state.config = loco.config
			loco.gait_state.mode = loco.mode
			loco.gait_state.speed = loco.speed
			gait_update(&loco.gait_state, loco_dt, loco.rest_pose)
			loco.target_pose = loco.gait_state.current_pose

		case .Custom:
			if loco.preset != .Rest_Idle {
				loco.target_pose = pose_preset_get(loco.preset)
			}
		}

		// 2. Head LookAt tracking
		if loco.enable_look_at {
			head_pos := loco.target_pose.head_pos
			loco.target_pose.head_rot = look_at_clamped(
				head_pos,
				loco.look_target,
				[3]f32{0, 1, 0},
				loco.rest_pose.head_rot,
				yaw_limit_deg = 70.0,
				pitch_limit_deg = 45.0,
			)
		}

		// 3. Physical Velocity & Euphoria Dynamics Simulation
		if loco.enable_dynamics {
			char_tw := engine.transform_world(loco.owner)
			char_pos := char_tw.position
			char_q := engine.quat_to_native(char_tw.rotation)
			_, ry, _ := linalg.euler_angles_from_quaternion(char_q, .YXZ)
			char_yaw := ry

			stiff := loco.stiffness > 0 ? loco.stiffness : 180.0
			damp := loco.damping > 0 ? loco.damping : 22.0
			loco.dynamic_pose = dynamics_update(
				&loco.dynamics,
				loco.target_pose,
				loco_dt,
				loco.fatigue,
				stiff,
				damp,
				char_pos,
				char_yaw,
				loco.body_lean_strength,
			)
		} else {
			loco.dynamic_pose = loco.target_pose
		}

		// 4. Write directly into ControlRig controls (never touching bones directly!)
		if loco.drive_skeleton {
			if _, rig := engine.transform_get_comp(loco.owner, ControlRig); rig != nil {
				control_rig_update_from_pose(rig, loco.dynamic_pose)
			}
		}
	}
}
