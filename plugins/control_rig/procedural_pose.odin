package control_rig

// Procedural Rig Pose representation for bipedal characters.
// Stores all key effector targets and pole vectors in character local space.

import "core:math/linalg"
import engine "haati:engine"

Procedural_Pose :: struct {
	pelvis_pos:       [3]f32,
	pelvis_rot:       [4]f32,
	chest_pos:        [3]f32,
	chest_rot:        [4]f32,
	head_pos:         [3]f32,
	head_rot:         [4]f32,

	left_foot_pos:    [3]f32,
	left_foot_rot:    [4]f32,
	left_knee_pole:   [3]f32,

	right_foot_pos:   [3]f32,
	right_foot_rot:   [4]f32,
	right_knee_pole:  [3]f32,

	left_hand_pos:    [3]f32,
	left_hand_rot:    [4]f32,
	left_elbow_pole:  [3]f32,

	right_hand_pos:   [3]f32,
	right_hand_rot:   [4]f32,
	right_elbow_pole: [3]f32,
}

default_rest_pose :: proc() -> Procedural_Pose {
	p: Procedural_Pose
	p.pelvis_pos = {0.0, 0.95, 0.0}
	p.pelvis_rot = engine.QUAT_IDENTITY

	p.chest_pos  = {0.0, 1.35, 0.0}
	p.chest_rot  = engine.QUAT_IDENTITY

	p.head_pos   = {0.0, 1.65, 0.0}
	p.head_rot   = engine.QUAT_IDENTITY

	p.left_foot_pos   = {0.18, 0.0, 0.0}
	p.left_foot_rot   = engine.QUAT_IDENTITY
	p.left_knee_pole  = {0.18, 0.5, 0.6}

	p.right_foot_pos  = {-0.18, 0.0, 0.0}
	p.right_foot_rot  = engine.QUAT_IDENTITY
	p.right_knee_pole = {-0.18, 0.5, 0.6}

	p.left_hand_pos   = {0.42, 0.95, 0.0}
	p.left_hand_rot   = engine.QUAT_IDENTITY
	p.left_elbow_pole = {0.55, 1.15, -0.4}

	p.right_hand_pos   = {-0.42, 0.95, 0.0}
	p.right_hand_rot   = engine.QUAT_IDENTITY
	p.right_elbow_pole = {-0.55, 1.15, -0.4}

	return p
}

_quat_nlerp :: proc(a, b: [4]f32, t: f32) -> [4]f32 {
	qa := engine.quat_to_native(a)
	qb := engine.quat_to_native(b)
	q := linalg.quaternion_nlerp(qa, qb, t)
	return engine.quat_from_native(q)
}

procedural_pose_lerp :: proc(a, b: Procedural_Pose, t: f32) -> Procedural_Pose {
	res: Procedural_Pose
	res.pelvis_pos = linalg.lerp(a.pelvis_pos, b.pelvis_pos, t)
	res.pelvis_rot = _quat_nlerp(a.pelvis_rot, b.pelvis_rot, t)

	res.chest_pos  = linalg.lerp(a.chest_pos, b.chest_pos, t)
	res.chest_rot  = _quat_nlerp(a.chest_rot, b.chest_rot, t)

	res.head_pos   = linalg.lerp(a.head_pos, b.head_pos, t)
	res.head_rot   = _quat_nlerp(a.head_rot, b.head_rot, t)

	res.left_foot_pos   = linalg.lerp(a.left_foot_pos, b.left_foot_pos, t)
	res.left_foot_rot   = _quat_nlerp(a.left_foot_rot, b.left_foot_rot, t)
	res.left_knee_pole  = linalg.lerp(a.left_knee_pole, b.left_knee_pole, t)

	res.right_foot_pos  = linalg.lerp(a.right_foot_pos, b.right_foot_pos, t)
	res.right_foot_rot  = _quat_nlerp(a.right_foot_rot, b.right_foot_rot, t)
	res.right_knee_pole = linalg.lerp(a.right_knee_pole, b.right_knee_pole, t)

	res.left_hand_pos   = linalg.lerp(a.left_hand_pos, b.left_hand_pos, t)
	res.left_hand_rot   = _quat_nlerp(a.left_hand_rot, b.left_hand_rot, t)
	res.left_elbow_pole = linalg.lerp(a.left_elbow_pole, b.left_elbow_pole, t)

	res.right_hand_pos   = linalg.lerp(a.right_hand_pos, b.right_hand_pos, t)
	res.right_hand_rot   = _quat_nlerp(a.right_hand_rot, b.right_hand_rot, t)
	res.right_elbow_pole = linalg.lerp(a.right_elbow_pole, b.right_elbow_pole, t)

	return res
}

Pose_Preset :: enum {
	Rest_Idle,
	Crouch,
	Prone_Brace,
	Combat_Stance,
	Hang_Ledge,
}

Effector_Id :: enum {
	Pelvis,
	Chest,
	Head,
	Left_Foot,
	Right_Foot,
	Left_Hand,
	Right_Hand,
}

pose_preset_get :: proc(preset: Pose_Preset) -> Procedural_Pose {
	switch preset {
	case .Rest_Idle:     return default_rest_pose()
	case .Crouch:        return pose_crouch()
	case .Prone_Brace:   return pose_prone_brace()
	case .Combat_Stance: return pose_combat_stance()
	case .Hang_Ledge:    return pose_hang_ledge()
	}
	return default_rest_pose()
}

pose_crouch :: proc() -> Procedural_Pose {
	p := default_rest_pose()
	p.pelvis_pos = {0.0, 0.52, 0.05}
	p.chest_pos  = {0.0, 0.85, 0.12}
	p.head_pos   = {0.0, 1.15, 0.18}

	p.left_foot_pos   = {0.22, 0.0, 0.05}
	p.left_knee_pole  = {0.25, 0.35, 0.65}

	p.right_foot_pos  = {-0.22, 0.0, -0.10}
	p.right_knee_pole = {-0.25, 0.35, 0.55}

	p.left_hand_pos   = {0.30, 0.45, 0.25}
	p.right_hand_pos  = {-0.30, 0.45, 0.25}
	return p
}

// Euphoria-style active prone brace: body off the ground, arms braced, head looking up
pose_prone_brace :: proc() -> Procedural_Pose {
	p := default_rest_pose()
	p.pelvis_pos = {0.0, 0.22, -0.15}
	p.chest_pos  = {0.0, 0.35, 0.20}
	p.head_pos   = {0.0, 0.55, 0.45}

	// Active look-up tilt
	p.head_rot = engine.quat_from_native(linalg.quaternion_angle_axis(f32(-0.35), [3]f32{1, 0, 0}))

	p.left_foot_pos   = {0.20, 0.05, -0.85}
	p.left_knee_pole  = {0.22, 0.15, -0.40}

	p.right_foot_pos  = {-0.20, 0.05, -0.85}
	p.right_knee_pole = {-0.22, 0.15, -0.40}

	// Hands planted on the ground to push the torso up
	p.left_hand_pos   = {0.38, 0.05, 0.35}
	p.left_elbow_pole = {0.55, 0.30, 0.15}

	p.right_hand_pos   = {-0.38, 0.05, 0.35}
	p.right_elbow_pole = {-0.55, 0.30, 0.15}
	return p
}

pose_combat_stance :: proc() -> Procedural_Pose {
	p := default_rest_pose()
	p.pelvis_pos = {0.0, 0.88, 0.0}
	p.chest_pos  = {0.0, 1.28, 0.05}
	p.head_pos   = {0.0, 1.58, 0.08}

	// Staggered tactical footwork
	p.left_foot_pos   = {0.22, 0.0, 0.22}
	p.left_knee_pole  = {0.22, 0.45, 0.70}

	p.right_foot_pos  = {-0.22, 0.0, -0.22}
	p.right_knee_pole = {-0.22, 0.45, 0.50}

	// Raised ready hands
	p.left_hand_pos   = {0.22, 1.30, 0.42}
	p.left_elbow_pole = {0.45, 1.05, 0.10}

	p.right_hand_pos   = {-0.18, 1.25, 0.32}
	p.right_elbow_pole = {-0.40, 1.00, -0.05}
	return p
}

pose_hang_ledge :: proc() -> Procedural_Pose {
	p := default_rest_pose()
	p.pelvis_pos = {0.0, 0.90, -0.10}
	p.chest_pos  = {0.0, 1.35, -0.05}
	p.head_pos   = {0.0, 1.62, 0.02}

	// Arms reaching up to grip ledge
	p.left_hand_pos   = {0.25, 1.95, 0.05}
	p.left_elbow_pole = {0.35, 1.70, -0.15}

	p.right_hand_pos   = {-0.25, 1.95, 0.05}
	p.right_elbow_pole = {-0.35, 1.70, -0.15}

	// Dangling legs
	p.left_foot_pos   = {0.15, -0.15, -0.20}
	p.left_knee_pole  = {0.15, 0.40, 0.30}

	p.right_foot_pos  = {-0.15, -0.20, -0.15}
	p.right_knee_pole = {-0.15, 0.35, 0.30}
	return p
}

// Updates Rig Controls from a lightweight Procedural_Pose.
// Designed for locomotion state machines and procedural animation layers.
// Applies intent/targets directly to rig controls in a single fast pass with no matrix bloat.
control_rig_update_from_pose :: proc(rig: ^ControlRig, pose: Procedural_Pose) {
	if rig == nil do return

	rig.pelvis.position = pose.pelvis_pos
	rig.pelvis.rotation = pose.pelvis_rot
	rig.chest.position  = pose.chest_pos
	rig.chest.rotation  = pose.chest_rot
	rig.head.position   = pose.head_pos
	rig.head.rotation   = pose.head_rot

	rig.left_foot.position = pose.left_foot_pos
	rig.left_foot.rotation = pose.left_foot_rot
	rig.left_knee_pole     = pose.left_knee_pole

	rig.right_foot.position = pose.right_foot_pos
	rig.right_foot.rotation = pose.right_foot_rot
	rig.right_knee_pole     = pose.right_knee_pole

	rig.left_hand.position = pose.left_hand_pos
	rig.left_hand.rotation = pose.left_hand_rot
	rig.left_elbow_pole    = pose.left_elbow_pole

	rig.right_hand.position = pose.right_hand_pos
	rig.right_hand.rotation = pose.right_hand_rot
	rig.right_elbow_pole    = pose.right_elbow_pole
}

