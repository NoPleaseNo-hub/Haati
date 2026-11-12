package control_rig

// Physical Velocity Pose & Second-Order Dynamic Spring-Damper Engine.
// Simulates muscular lag, fatigue, body inertia, centrifugal turns, and active recoil.

import "core:math"
import "core:math/linalg"
import engine "moonhug:engine"

Effector_Dynamic_State :: struct {
	pos:         [3]f32,
	rot:         [4]f32,
	linear_vel:  [3]f32,
	angular_vel: [3]f32,
}

ControlRig_Dynamics :: struct {
	pelvis:          Effector_Dynamic_State,
	chest:           Effector_Dynamic_State,
	head:            Effector_Dynamic_State,
	left_foot:       Effector_Dynamic_State,
	right_foot:      Effector_Dynamic_State,
	left_hand:       Effector_Dynamic_State,
	right_hand:      Effector_Dynamic_State,

	mass:            f32,
	lean_roll:       f32,
	lean_pitch:      f32,
	lean_roll_vel:   f32,
	lean_pitch_vel:  f32,
	prev_root_pos:   [3]f32,
	prev_root_yaw:   f32,
	initialized:     bool,
}

dynamics_init :: proc(dyn: ^ControlRig_Dynamics, initial: Procedural_Pose) {
	dyn.mass = 75.0 // 75 kg standard humanoid body mass

	dyn.pelvis.pos = initial.pelvis_pos
	dyn.pelvis.rot = initial.pelvis_rot
	dyn.pelvis.linear_vel = {}
	dyn.pelvis.angular_vel = {}

	dyn.chest.pos = initial.chest_pos
	dyn.chest.rot = initial.chest_rot
	dyn.chest.linear_vel = {}
	dyn.chest.angular_vel = {}

	dyn.head.pos = initial.head_pos
	dyn.head.rot = initial.head_rot
	dyn.head.linear_vel = {}
	dyn.head.angular_vel = {}

	dyn.left_foot.pos = initial.left_foot_pos
	dyn.left_foot.rot = initial.left_foot_rot
	dyn.left_foot.linear_vel = {}
	dyn.left_foot.angular_vel = {}

	dyn.right_foot.pos = initial.right_foot_pos
	dyn.right_foot.rot = initial.right_foot_rot
	dyn.right_foot.linear_vel = {}
	dyn.right_foot.angular_vel = {}

	dyn.left_hand.pos = initial.left_hand_pos
	dyn.left_hand.rot = initial.left_hand_rot
	dyn.left_hand.linear_vel = {}
	dyn.left_hand.angular_vel = {}

	dyn.right_hand.pos = initial.right_hand_pos
	dyn.right_hand.rot = initial.right_hand_rot
	dyn.right_hand.linear_vel = {}
	dyn.right_hand.angular_vel = {}

	dyn.lean_roll = 0.0
	dyn.lean_pitch = 0.0
	dyn.lean_roll_vel = 0.0
	dyn.lean_pitch_vel = 0.0
	dyn.prev_root_pos = {}
	dyn.prev_root_yaw = 0.0
	dyn.initialized = true
}

@(private = "file")
_integrate_effector :: proc(
	cur: ^Effector_Dynamic_State,
	target_pos: [3]f32,
	target_rot: [4]f32,
	dt: f32,
	fatigue: f32,
	stiffness: f32,
	damping: f32,
) {
	if dt <= 0.0001 do return

	// Fatigue scaling: tired muscles have less spring tension and yield more to velocity
	eff_fatigue := math.clamp(fatigue, 0.0, 1.0)
	eff_k := stiffness * math.max(f32(0.12), 1.0 - eff_fatigue * 0.75)
	eff_d := damping * math.max(f32(0.25), 1.0 - eff_fatigue * 0.40)

	// 1. Second-order linear spring-damper:
	// a = k * (target - current) - d * velocity
	pos_error := target_pos - cur.pos
	accel := pos_error * eff_k - cur.linear_vel * eff_d

	cur.linear_vel += accel * dt
	speed := linalg.length(cur.linear_vel)
	max_speed: f32 = 40.0
	if speed > max_speed {
		cur.linear_vel = (cur.linear_vel / speed) * max_speed
	}
	cur.pos += cur.linear_vel * dt

	// 2. Second-order angular spring-damper:
	cur_q := engine.quat_to_native(cur.rot)
	tgt_q := engine.quat_to_native(target_rot)
	if cur_q == {} do cur_q = engine.quat_to_native(engine.QUAT_IDENTITY)
	if tgt_q == {} do tgt_q = engine.quat_to_native(engine.QUAT_IDENTITY)

	// Shortest arc on 4D hypersphere
	dot := cur_q.w * tgt_q.w + cur_q.x * tgt_q.x + cur_q.y * tgt_q.y + cur_q.z * tgt_q.z
	if dot < 0.0 {
		tgt_q = -tgt_q
	}

	inv_cur := linalg.quaternion_inverse(cur_q)
	delta_q := inv_cur * tgt_q

	axis := [3]f32{delta_q.x, delta_q.y, delta_q.z}
	sin_half := linalg.length(axis)
	angle: f32 = 0.0
	if sin_half > 0.00001 {
		axis /= sin_half
		angle = 2.0 * math.atan2(sin_half, delta_q.w)
	}

	torque := axis * (angle * eff_k * 0.45) - cur.angular_vel * eff_d
	cur.angular_vel += torque * dt
	ang_speed := linalg.length(cur.angular_vel)
	max_ang: f32 = 30.0
	if ang_speed > max_ang {
		cur.angular_vel = (cur.angular_vel / ang_speed) * max_ang
		ang_speed = max_ang
	}

	if ang_speed > 0.0001 {
		step_angle := ang_speed * dt
		step_axis := cur.angular_vel / ang_speed
		step_q := linalg.quaternion_angle_axis(step_angle, step_axis)
		cur_q = linalg.quaternion_normalize(cur_q * step_q)
		cur.rot = engine.quat_from_native(cur_q)
	}
}

dynamics_update :: proc(
	dyn: ^ControlRig_Dynamics,
	target_pose: Procedural_Pose,
	dt: f32,
	fatigue: f32,
	stiffness: f32,
	damping: f32,
	root_world_pos: [3]f32,
	root_world_yaw: f32,
	lean_strength: f32,
) -> Procedural_Pose {
	if !dyn.initialized {
		dynamics_init(dyn, target_pose)
	}
	if dt <= 0.0001 do return target_pose

	// Clamp dt to avoid explosion on hitch
	safe_dt := math.min(dt, 0.05)

	// Simulate each effector spring-damper
	_integrate_effector(&dyn.pelvis, target_pose.pelvis_pos, target_pose.pelvis_rot, safe_dt, fatigue, stiffness, damping)
	_integrate_effector(&dyn.chest, target_pose.chest_pos, target_pose.chest_rot, safe_dt, fatigue, stiffness, damping)
	_integrate_effector(&dyn.head, target_pose.head_pos, target_pose.head_rot, safe_dt, fatigue, stiffness, damping)
	_integrate_effector(&dyn.left_foot, target_pose.left_foot_pos, target_pose.left_foot_rot, safe_dt, fatigue, stiffness, damping)
	_integrate_effector(&dyn.right_foot, target_pose.right_foot_pos, target_pose.right_foot_rot, safe_dt, fatigue, stiffness, damping)
	_integrate_effector(&dyn.left_hand, target_pose.left_hand_pos, target_pose.left_hand_rot, safe_dt, fatigue, stiffness, damping)
	_integrate_effector(&dyn.right_hand, target_pose.right_hand_pos, target_pose.right_hand_rot, safe_dt, fatigue, stiffness, damping)

	// Dynamic Lean from root movement and turning
	root_vel := (root_world_pos - dyn.prev_root_pos) / safe_dt
	dyn.prev_root_pos = root_world_pos

	yaw_delta := root_world_yaw - dyn.prev_root_yaw
	for yaw_delta > math.PI do yaw_delta -= math.PI * 2.0
	for yaw_delta < -math.PI do yaw_delta += math.PI * 2.0
	dyn.prev_root_yaw = root_world_yaw
	yaw_vel := yaw_delta / safe_dt

	speed := linalg.length(root_vel)
	target_roll := -math.clamp(yaw_vel * speed * 0.03 * lean_strength, -0.4, 0.4)
	target_pitch := -math.clamp(speed * 0.035 * lean_strength, -0.3, 0.3)

	roll_err := target_roll - dyn.lean_roll
	dyn.lean_roll_vel += (roll_err * 60.0 - dyn.lean_roll_vel * 10.0) * safe_dt
	dyn.lean_roll += dyn.lean_roll_vel * safe_dt

	pitch_err := target_pitch - dyn.lean_pitch
	dyn.lean_pitch_vel += (pitch_err * 60.0 - dyn.lean_pitch_vel * 10.0) * safe_dt
	dyn.lean_pitch += dyn.lean_pitch_vel * safe_dt

	// Dynamic output pose
	out := target_pose
	out.pelvis_pos = dyn.pelvis.pos
	out.pelvis_rot = dyn.pelvis.rot

	// Lean applied to chest
	chest_q := engine.quat_to_native(dyn.chest.rot)
	lean_q := linalg.quaternion_from_euler_angles(dyn.lean_pitch, 0, dyn.lean_roll, .YZX)
	out.chest_rot = engine.quat_from_native(linalg.quaternion_normalize(chest_q * lean_q))
	out.chest_pos = dyn.chest.pos

	out.head_pos = dyn.head.pos
	out.head_rot = dyn.head.rot

	out.left_foot_pos = dyn.left_foot.pos
	out.left_foot_rot = dyn.left_foot.rot

	out.right_foot_pos = dyn.right_foot.pos
	out.right_foot_rot = dyn.right_foot.rot

	out.left_hand_pos = dyn.left_hand.pos
	out.left_hand_rot = dyn.left_hand.rot

	out.right_hand_pos = dyn.right_hand.pos
	out.right_hand_rot = dyn.right_hand.rot

	return out
}

dynamics_add_impulse :: proc(dyn: ^ControlRig_Dynamics, effector: Effector_Id, impulse: [3]f32) {
	if !dyn.initialized do return
	m := dyn.mass > 0 ? dyn.mass : 75.0
	delta_v := impulse / (m * 0.25) // effector mass fraction

	switch effector {
	case .Pelvis:     dyn.pelvis.linear_vel += delta_v
	case .Chest:      dyn.chest.linear_vel += delta_v
	case .Head:       dyn.head.linear_vel += delta_v * 1.5
	case .Left_Foot:  dyn.left_foot.linear_vel += delta_v
	case .Right_Foot: dyn.right_foot.linear_vel += delta_v
	case .Left_Hand:  dyn.left_hand.linear_vel += delta_v
	case .Right_Hand: dyn.right_hand.linear_vel += delta_v
	}
}

dynamics_add_angular_impulse :: proc(dyn: ^ControlRig_Dynamics, effector: Effector_Id, torque: [3]f32) {
	if !dyn.initialized do return
	switch effector {
	case .Pelvis:     dyn.pelvis.angular_vel += torque
	case .Chest:      dyn.chest.angular_vel += torque
	case .Head:       dyn.head.angular_vel += torque
	case .Left_Foot:  dyn.left_foot.angular_vel += torque
	case .Right_Foot: dyn.right_foot.angular_vel += torque
	case .Left_Hand:  dyn.left_hand.angular_vel += torque
	case .Right_Hand: dyn.right_hand.angular_vel += torque
	}
}

dynamics_add_body_impulse :: proc(dyn: ^ControlRig_Dynamics, impulse: [3]f32) {
	dynamics_add_impulse(dyn, .Chest, impulse * 0.6)
	dynamics_add_impulse(dyn, .Pelvis, impulse * 0.3)
	dynamics_add_impulse(dyn, .Head, impulse * 0.4)
}
