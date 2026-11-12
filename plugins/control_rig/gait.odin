package control_rig

// Bipedal Locomotion & Gait Engine
// Ports WalkState and IdleState from the Godot project into a zero-allocation,
// cache-friendly procedural animator.

import "core:math"
import "core:math/linalg"
import engine "moonhug:engine"

Gait_Mode :: enum {
	Idle,
	Walk,
	Custom,
}

Gait_Config :: struct {
	stride_length:    f32,
	step_height:      f32,
	gait_frequency:   f32, // Steps per second
	pelvis_bounce:    f32,
	pelvis_sway:      f32,
	arm_swing_amount: f32,
	breath_speed:     f32,
	breath_amount:    f32,
}

default_gait_config :: proc() -> Gait_Config {
	return Gait_Config{
		stride_length    = 0.45,
		step_height      = 0.12,
		gait_frequency   = 2.4,
		pelvis_bounce    = 0.035,
		pelvis_sway      = 0.03,
		arm_swing_amount = 0.25,
		breath_speed     = 1.5,
		breath_amount    = 0.015,
	}
}

Gait_State :: struct {
	mode:         Gait_Mode,
	phase:        f32, // 0 to 2*PI
	breath_time:  f32,
	speed:        f32,
	config:       Gait_Config,
	current_pose: Procedural_Pose,
}

gait_init :: proc(state: ^Gait_State) {
	state.mode = .Idle
	state.phase = 0.0
	state.breath_time = 0.0
	state.speed = 1.8
	state.config = default_gait_config()
	state.current_pose = default_rest_pose()
}

gait_update :: proc(state: ^Gait_State, dt: f32, rest: Procedural_Pose) -> Procedural_Pose {
	pose := rest
	cfg := &state.config

	switch state.mode {
	case .Idle:
		state.breath_time += dt * cfg.breath_speed
		breathe := math.sin(state.breath_time) * cfg.breath_amount

		pose.pelvis_pos += [3]f32{0, breathe, 0}
		pose.chest_pos  += [3]f32{0, breathe * 1.2, 0}
		pose.head_pos   += [3]f32{0, breathe * 0.8, 0}

		pose.left_hand_pos  += [3]f32{0, breathe * 0.5, 0}
		pose.right_hand_pos += [3]f32{0, breathe * 0.5, 0}

	case .Walk:
		// Advance gait phase driven by velocity
		speed_ratio := math.clamp(state.speed / 2.0, 0.4, 2.0)
		state.phase += dt * cfg.gait_frequency * speed_ratio * math.PI * 2.0
		if state.phase > math.PI * 2.0 {
			state.phase -= math.PI * 2.0
		}

		ph := state.phase
		fwd := [3]f32{0, 0, 1}
		right := [3]f32{1, 0, 0}
		up := [3]f32{0, 1, 0}

		// 1. Pelvis Bobbing & Lateral Sway
		pelvis_vert := -abs(math.sin(ph)) * cfg.pelvis_bounce
		pelvis_horiz := math.sin(ph) * cfg.pelvis_sway
		pelvis_yaw := math.sin(ph) * 0.08

		pose.pelvis_pos = rest.pelvis_pos + up * pelvis_vert + right * pelvis_horiz
		pelvis_yaw_q := linalg.quaternion_angle_axis(pelvis_yaw, up)
		pose.pelvis_rot = engine.quat_from_native(engine.quat_to_native(rest.pelvis_rot) * pelvis_yaw_q)

		// 2. Chest Counter-Twist & Lean
		chest_yaw := -pelvis_yaw * 0.8
		pose.chest_pos = rest.chest_pos + up * (pelvis_vert * 0.6) - right * (pelvis_horiz * 0.4)
		chest_yaw_q := linalg.quaternion_angle_axis(chest_yaw, up)
		pose.chest_rot = engine.quat_from_native(engine.quat_to_native(rest.chest_rot) * chest_yaw_q)

		// 3. Foot Step Arcs
		left_prog := math.sin(ph)
		left_fwd := math.cos(ph) * cfg.stride_length
		left_lift := math.max(f32(0.0), left_prog) * cfg.step_height

		right_prog := math.sin(ph + math.PI)
		right_fwd := math.cos(ph + math.PI) * cfg.stride_length
		right_lift := math.max(f32(0.0), right_prog) * cfg.step_height

		pose.left_foot_pos = rest.left_foot_pos + fwd * left_fwd + up * left_lift
		pose.left_knee_pole = rest.left_knee_pole + fwd * (left_fwd * 0.5)

		pose.right_foot_pos = rest.right_foot_pos + fwd * right_fwd + up * right_lift
		pose.right_knee_pole = rest.right_knee_pole + fwd * (right_fwd * 0.5)

		// 4. Arm Counter-Swing
		left_arm_swing := right_fwd * cfg.arm_swing_amount
		right_arm_swing := left_fwd * cfg.arm_swing_amount

		pose.left_hand_pos = rest.left_hand_pos + fwd * left_arm_swing + up * (pelvis_vert * 0.3)
		pose.right_hand_pos = rest.right_hand_pos + fwd * right_arm_swing + up * (pelvis_vert * 0.3)

		pose.left_elbow_pole = rest.left_elbow_pole + fwd * (left_arm_swing * 0.5)
		pose.right_elbow_pole = rest.right_elbow_pole + fwd * (right_arm_swing * 0.5)

	case .Custom:
		// Custom authored/blended pose passes through
	}

	state.current_pose = pose
	return pose
}
