package control_rig

// ControlRig: Unreal Engine-style Modular Skeletal Rig & Solver Component.
// Decoupled from procedural locomotion so character rigs have dedicated,
// clean controls for posing, animating, IK solving, and forearm twist simulation.
//
// Key Features:
// 1. Interactive Rig Controls: Local character-space targets for Pelvis, Feet, Hands, Head, Eye Level Socket.
// 2. Knee & Elbow Pole Controls for natural limb bend direction hints.
// 3. Ball/Toe pitch controls for natural foot roll.
// 4. Visual Styling: Shapes, colors, scales, and rotation weights for 3D viewport handles.
// 5. One-click bind pose synchronization ("Sync Controls from Skeleton Bind Pose").

import "core:math"
import "core:math/linalg"
import engine "moonhug:engine"

Control_Shape_Type :: enum {
	Circle,
	Circle_Normal,
	Ring,
	Square,
	Square_Normal,
	Diamond,
	Cross,
	Arrow,
	Cube,
	Sphere,
}

Rig_Control :: struct {
	position:          [3]f32,
	rotation:          [4]f32,
	relative_rotation: [4]f32, // Relaxed/local limb coordinate offset (e.g. holding hammer/rifle, relaxed wrist tilt)
	shape:             Control_Shape_Type,
	color:             [4]f32,
	scale:             f32,
	rotation_weight:   f32,
}

@(component={menu="Animation/ControlRig"})
@(typ_guid={guid = "81a21c0f-3252-4d1e-9e4b-325ef04d762f"})
ControlRig :: struct {
	using base:              engine.CompData `inspect:"-"`,
	active:                  bool,

	// --- RIG CONTROLS (Character Local Space) ---
	pelvis:                  Rig_Control,
	spine:                   Rig_Control,
	chest:                   Rig_Control,
	head:                    Rig_Control,
	eye_level_socket:        Rig_Control, // Eye level / Camera Pawn mount offset relative to head bone
	look_at_target:          [3]f32,

	left_foot:               Rig_Control,
	right_foot:              Rig_Control,
	left_toe_pitch:          f32, // Pitch angle in radians for ball/toe foot roll
	right_toe_pitch:         f32, // Pitch angle in radians for ball/toe foot roll

	// Pole controls (knee and elbow bend direction hints)
	left_knee_pole:          [3]f32,
	right_knee_pole:         [3]f32,

	left_hand:               Rig_Control,
	right_hand:              Rig_Control,
	left_elbow_pole:         [3]f32,
	right_elbow_pole:        [3]f32,

	// Single source of truth for resolved skeleton bones & rest poses on this character
	bones:                   Humanoid_Bones `json:"-" inspect:"-"`,
}

// Ensures the character's Humanoid_Bones cache on ControlRig is bound and returns a pointer to it.
control_rig_ensure_bones :: proc(rig: ^ControlRig) -> ^Humanoid_Bones {
	if rig == nil do return nil
	if !rig.bones.bound || !skeleton_bones_alive(&rig.bones) {
		skeleton_bind_humanoid(&rig.bones, rig.owner)
	}
	return &rig.bones
}

reset_ControlRig :: proc(rig: ^ControlRig) {
	rig.active = true

	rig.pelvis     = {{0.0, 0.95, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Ring,   {1.00, 0.85, 0.20, 0.95}, 0.25, 1.0}
	rig.spine      = {{0.0, 1.15, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Circle, {1.00, 0.85, 0.20, 0.95}, 0.22, 1.0}
	rig.chest      = {{0.0, 1.35, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Circle, {1.00, 0.85, 0.20, 0.95}, 0.24, 1.0}
	rig.head       = {{0.0, 1.65, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Sphere, {1.00, 0.90, 0.30, 0.95}, 0.12, 1.0}
	rig.eye_level_socket = {{0.0, 0.13, 0.14}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Sphere, {0.20, 0.85, 1.00, 0.95}, 0.08, 1.0}
	rig.look_at_target = {0.0, 1.65, 2.0}

	rig.left_foot  = {{0.18, 0.0, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Cube, {0.95, 0.25, 0.25, 0.95}, 0.20, 1.0}
	rig.right_foot = {{-0.18, 0.0, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Cube, {0.20, 0.90, 0.40, 0.95}, 0.20, 1.0}
	rig.left_toe_pitch = 0.0
	rig.right_toe_pitch = 0.0

	rig.left_knee_pole   = {0.18, 0.5, 0.6}
	rig.right_knee_pole  = {-0.18, 0.5, 0.6}

	rig.left_hand  = {{0.42, 0.95, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Cube, {0.95, 0.25, 0.25, 0.95}, 0.12, 1.0}
	rig.right_hand = {{-0.42, 0.95, 0.0}, engine.QUAT_IDENTITY, engine.QUAT_IDENTITY, .Cube, {0.20, 0.90, 0.40, 0.95}, 0.12, 1.0}

	rig.left_elbow_pole  = {0.55, 1.15, -0.4}
	rig.right_elbow_pole = {-0.55, 1.15, -0.4}

	rig.bones = {}
}

cleanup_ControlRig :: proc(rig: ^ControlRig) {
	engine.comp_zero(rig)
}

on_destroy_ControlRig :: proc(rig: ^ControlRig) {
	cleanup_ControlRig(rig)
}

@(inspector_button={label="Reset Controls to Rest Pose", row=-1})
control_rig_sync_from_skeleton :: proc(rig: ^ControlRig) {
	w := engine.ctx_world()
	if w == nil || rig == nil do return

	bones := control_rig_ensure_bones(rig)
	if bones == nil || !bones.bound do return

	// Always read from the authentic cached rest bind pose (NOT live posed bone transforms!)
	// and reset all control rotations to QUAT_IDENTITY (since HumanoidIkSolver applies control
	// rotations as additive deltas on top of rest_rot).
	if rig.bones.pelvis_rest.valid {
		rig.pelvis.position = rig.bones.pelvis_rest.pos
	}
	rig.pelvis.rotation = engine.QUAT_IDENTITY
	rig.pelvis.relative_rotation = engine.QUAT_IDENTITY

	if rig.bones.spine_rest.valid {
		rig.spine.position = rig.bones.spine_rest.pos
	}
	rig.spine.rotation = engine.QUAT_IDENTITY
	rig.spine.relative_rotation = engine.QUAT_IDENTITY

	if rig.bones.chest_rest.valid {
		rig.chest.position = rig.bones.chest_rest.pos
	}
	rig.chest.rotation = engine.QUAT_IDENTITY
	rig.chest.relative_rotation = engine.QUAT_IDENTITY

	if rig.bones.head_rest.valid {
		rig.head.position = rig.bones.head_rest.pos
		rig.look_at_target = rig.head.position + {0.0, 0.0, 2.0}
	}
	rig.head.rotation = engine.QUAT_IDENTITY
	rig.head.relative_rotation = engine.QUAT_IDENTITY

	if rig.bones.left_leg_rest.valid {
		rig.left_foot.position = rig.bones.left_leg_rest.tip_pos
		rig.left_knee_pole = {
			rig.bones.left_leg_rest.mid_pos.x,
			rig.bones.left_leg_rest.mid_pos.y,
			rig.bones.left_leg_rest.mid_pos.z + 0.55,
		}
	} else {
		rig.left_knee_pole = {rig.left_foot.position.x, (rig.pelvis.position.y + rig.left_foot.position.y) * 0.5, rig.left_foot.position.z + 0.6}
	}
	rig.left_foot.rotation = engine.QUAT_IDENTITY
	rig.left_foot.relative_rotation = engine.QUAT_IDENTITY

	if rig.bones.right_leg_rest.valid {
		rig.right_foot.position = rig.bones.right_leg_rest.tip_pos
		rig.right_knee_pole = {
			rig.bones.right_leg_rest.mid_pos.x,
			rig.bones.right_leg_rest.mid_pos.y,
			rig.bones.right_leg_rest.mid_pos.z + 0.55,
		}
	} else {
		rig.right_knee_pole = {rig.right_foot.position.x, (rig.pelvis.position.y + rig.right_foot.position.y) * 0.5, rig.right_foot.position.z + 0.6}
	}
	rig.right_foot.rotation = engine.QUAT_IDENTITY
	rig.right_foot.relative_rotation = engine.QUAT_IDENTITY

	rig.left_toe_pitch = 0.0
	rig.right_toe_pitch = 0.0

	if rig.bones.left_arm_rest.valid {
		rig.left_hand.position = rig.bones.left_arm_rest.tip_pos
		rig.left_elbow_pole = {
			rig.bones.left_arm_rest.mid_pos.x,
			rig.bones.left_arm_rest.mid_pos.y,
			rig.bones.left_arm_rest.mid_pos.z - 0.45,
		}
	} else {
		rig.left_elbow_pole = {rig.left_hand.position.x + 0.15, rig.left_hand.position.y + 0.2, rig.left_hand.position.z - 0.4}
	}
	rig.left_hand.rotation = engine.QUAT_IDENTITY
	rig.left_hand.relative_rotation = engine.QUAT_IDENTITY

	if rig.bones.right_arm_rest.valid {
		rig.right_hand.position = rig.bones.right_arm_rest.tip_pos
		rig.right_elbow_pole = {
			rig.bones.right_arm_rest.mid_pos.x,
			rig.bones.right_arm_rest.mid_pos.y,
			rig.bones.right_arm_rest.mid_pos.z - 0.45,
		}
	} else {
		rig.right_elbow_pole = {rig.right_hand.position.x - 0.15, rig.right_hand.position.y + 0.2, rig.right_hand.position.z - 0.4}
	}
	rig.right_hand.rotation = engine.QUAT_IDENTITY
	rig.right_hand.relative_rotation = engine.QUAT_IDENTITY

	rig.eye_level_socket.rotation = engine.QUAT_IDENTITY
	rig.eye_level_socket.relative_rotation = engine.QUAT_IDENTITY
	if linalg.length2(rig.eye_level_socket.position) < 0.001 {
		rig.eye_level_socket.position = {0.0, 0.13, 0.14}
	}

	if _, solver := engine.transform_get_comp(rig.owner, HumanoidIkSolver); solver != nil {
		if rig.active && solver.active {
			humanoid_ik_solve(&rig.bones, solver.owner, rig, solver.look_at_max_angle, solver.wrist_twist_ratio)
		}
	}
	if _, adm := engine.transform_get_comp(rig.owner, ArmatureDeformedMesh); adm != nil {
		adm.posed_frame = 0
	}

	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

control_rig_reset_controls :: proc(rig: ^ControlRig) {
	if rig == nil do return
	control_rig_sync_from_skeleton(rig)
}

@(inspector_button={label="Rebind Skeleton Bones", row=-2})
control_rig_rebind :: proc(rig: ^ControlRig) {
	if rig == nil do return
	// Restore authentic glTF bind pose before capturing rest pose so we never bake a deformed pose as rest!
	if _, adm := engine.transform_get_comp(rig.owner, ArmatureDeformedMesh); adm != nil {
		armature_deformed_mesh_reset_bind_pose(adm)
		return
	}
	skeleton_bind_humanoid(&rig.bones, rig.owner)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Backward-compatibility helpers for external tools or editor windows
control_rig_add_body_impulse :: proc(rig: ^ControlRig, impulse: [3]f32) {
	w := engine.ctx_world()
	if w == nil || rig == nil do return
	_, loco := engine.transform_get_comp(rig.owner, ProceduralLocomotion)
	if loco != nil {
		procedural_locomotion_add_body_impulse(loco, impulse)
	}
}

control_rig_add_impulse :: proc(rig: ^ControlRig, effector: Effector_Id, impulse: [3]f32) {
	w := engine.ctx_world()
	if w == nil || rig == nil do return
	_, loco := engine.transform_get_comp(rig.owner, ProceduralLocomotion)
	if loco != nil {
		procedural_locomotion_add_impulse(loco, effector, impulse)
	}
}

control_rig_sanitize_control :: proc(ctrl: ^Rig_Control, def_pos: [3]f32, def_shape: Control_Shape_Type, def_color: [4]f32, def_scale: f32) {
	// Sanitize position: fallback to default if uninitialized or NaN
	if (linalg.length2(ctrl.position) < 0.0001 && ctrl.scale < 0.01) || math.is_nan(ctrl.position.x) || math.is_nan(ctrl.position.y) || math.is_nan(ctrl.position.z) {
		ctrl.position = def_pos
	}

	// Sanitize rotation: fallback to QUAT_IDENTITY if zero, unnormalized, or NaN
	rot_len2 := ctrl.rotation.x * ctrl.rotation.x + ctrl.rotation.y * ctrl.rotation.y + ctrl.rotation.z * ctrl.rotation.z + ctrl.rotation.w * ctrl.rotation.w
	if rot_len2 < 0.0001 || math.is_nan(ctrl.rotation.x) || math.is_nan(ctrl.rotation.y) || math.is_nan(ctrl.rotation.z) || math.is_nan(ctrl.rotation.w) {
		ctrl.rotation = engine.QUAT_IDENTITY
	} else if abs(rot_len2 - 1.0) > 0.001 {
		inv_len := 1.0 / math.sqrt(rot_len2)
		ctrl.rotation.x *= inv_len
		ctrl.rotation.y *= inv_len
		ctrl.rotation.z *= inv_len
		ctrl.rotation.w *= inv_len
	}

	// Sanitize relative_rotation: fallback to QUAT_IDENTITY if zero, unnormalized, or NaN
	rel_len2 := ctrl.relative_rotation.x * ctrl.relative_rotation.x + ctrl.relative_rotation.y * ctrl.relative_rotation.y + ctrl.relative_rotation.z * ctrl.relative_rotation.z + ctrl.relative_rotation.w * ctrl.relative_rotation.w
	if rel_len2 < 0.0001 || math.is_nan(ctrl.relative_rotation.x) || math.is_nan(ctrl.relative_rotation.y) || math.is_nan(ctrl.relative_rotation.z) || math.is_nan(ctrl.relative_rotation.w) {
		ctrl.relative_rotation = engine.QUAT_IDENTITY
	} else if abs(rel_len2 - 1.0) > 0.001 {
		inv_rel := 1.0 / math.sqrt(rel_len2)
		ctrl.relative_rotation.x *= inv_rel
		ctrl.relative_rotation.y *= inv_rel
		ctrl.relative_rotation.z *= inv_rel
		ctrl.relative_rotation.w *= inv_rel
	}

	// Sanitize shape
	if ctrl.shape == .Circle && def_shape != .Circle && ctrl.scale < 0.01 {
		ctrl.shape = def_shape
	}

	// Sanitize color
	if ctrl.color.a < 0.1 || math.is_nan(ctrl.color.a) {
		ctrl.color = def_color
	}

	// Sanitize scale
	if ctrl.scale < 0.02 || math.is_nan(ctrl.scale) {
		ctrl.scale = def_scale
	}

	// Sanitize rotation_weight: initialize uninitialized (0) values to 1.0. User values are in [0.01, 1.0] so user settings are never overwritten!
	if ctrl.rotation_weight <= 0.001 || math.is_nan(ctrl.rotation_weight) {
		ctrl.rotation_weight = 1.0
	}
}

control_rig_sanitize :: proc(rig: ^ControlRig) {
	if rig == nil do return

	control_rig_sanitize_control(&rig.pelvis,           {0.0, 0.95, 0.0}, .Ring,   {1.00, 0.85, 0.20, 0.95}, 0.25)
	control_rig_sanitize_control(&rig.spine,            {0.0, 1.15, 0.0}, .Circle, {1.00, 0.85, 0.20, 0.95}, 0.22)
	control_rig_sanitize_control(&rig.chest,            {0.0, 1.35, 0.0}, .Circle, {1.00, 0.85, 0.20, 0.95}, 0.24)
	control_rig_sanitize_control(&rig.head,             {0.0, 1.65, 0.0}, .Sphere, {1.00, 0.90, 0.30, 0.95}, 0.12)
	control_rig_sanitize_control(&rig.eye_level_socket, {0.0, 0.13, 0.14}, .Sphere, {0.20, 0.85, 1.00, 0.95}, 0.08)

	control_rig_sanitize_control(&rig.left_foot,  {0.18, 0.0, 0.0},  .Cube,   {0.95, 0.25, 0.25, 0.95}, 0.20)
	control_rig_sanitize_control(&rig.right_foot, {-0.18, 0.0, 0.0}, .Cube,   {0.20, 0.90, 0.40, 0.95}, 0.20)
	control_rig_sanitize_control(&rig.left_hand,  {0.42, 0.95, 0.0}, .Cube,   {0.95, 0.25, 0.25, 0.95}, 0.12)
	control_rig_sanitize_control(&rig.right_hand, {-0.42, 0.95, 0.0},.Cube,   {0.20, 0.90, 0.40, 0.95}, 0.12)

	if linalg.length2(rig.look_at_target) < 0.001 || math.is_nan(rig.look_at_target.x) do rig.look_at_target = {0.0, 1.65, 2.0}

	if linalg.length2(rig.left_knee_pole) < 0.001 || math.is_nan(rig.left_knee_pole.x) do rig.left_knee_pole = {0.18, 0.5, 0.6}
	if linalg.length2(rig.right_knee_pole) < 0.001 || math.is_nan(rig.right_knee_pole.x) do rig.right_knee_pole = {-0.18, 0.5, 0.6}

	if linalg.length2(rig.left_elbow_pole) < 0.001 || math.is_nan(rig.left_elbow_pole.x) do rig.left_elbow_pole = {0.55, 1.15, -0.4}
	if linalg.length2(rig.right_elbow_pole) < 0.001 || math.is_nan(rig.right_elbow_pole.x) do rig.right_elbow_pole = {-0.55, 1.15, -0.4}
}

// Returns the head's world pivot and face orientation basis (right, up, fwd)
control_rig_get_head_face_basis :: proc(rig: ^ControlRig) -> (head_pos: [3]f32, right: [3]f32, up: [3]f32, fwd: [3]f32) {
	if rig == nil do return {}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}
	w := engine.ctx_world()
	owner_h := engine.Transform_Handle(rig.owner)
	tw := engine.transform_world(owner_h)
	char_rot := engine.quat_to_native(tw.rotation)
	char_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))
	char_up  := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 1, 0}))

	// Auto-bind bones if not bound so both Edit Mode and Play Mode share the exact same skeletal pivot
	if w != nil && (!rig.bones.bound || !skeleton_bones_alive(&rig.bones)) {
		skeleton_bind_humanoid(&rig.bones, rig.owner)
	}

	if w != nil && rig.bones.head != {} && engine.pool_valid(&w.transforms, engine.Handle(rig.bones.head)) && rig.bones.head_rest.valid {
		head_pos = engine.transform_world_position(rig.bones.head)
		cur_h_rot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(rig.bones.head)))
		rest_h_rot := safe_quat_native(char_rot * engine.quat_to_native(safe_quat(rig.bones.head_rest.rot)))

		head_local_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(rest_h_rot), char_fwd))
		head_local_up  := linalg.normalize0(linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(rest_h_rot), char_up))

		fwd = linalg.normalize0(linalg.quaternion128_mul_vector3(cur_h_rot, head_local_fwd))
		up  = linalg.normalize0(linalg.quaternion128_mul_vector3(cur_h_rot, head_local_up))
		right = linalg.normalize0(linalg.cross(up, fwd))
		return
	}

	actor_m := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	head_pos = (actor_m * [4]f32{rig.head.position.x, rig.head.position.y, rig.head.position.z, 1}).xyz
	head_rot_w := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.head.rotation))
	fwd = linalg.normalize0(linalg.quaternion128_mul_vector3(head_rot_w, [3]f32{0, 0, 1}))
	up  = linalg.normalize0(linalg.quaternion128_mul_vector3(head_rot_w, [3]f32{0, 1, 0}))
	right = linalg.normalize0(linalg.cross(up, fwd))
	return
}

// Returns the world-space position of the Eye Level Socket / camera pawn mount point.
// Follows the live animated/posed head bone transform in world space.
control_rig_get_eye_level_world_position :: proc(rig: ^ControlRig) -> [3]f32 {
	head_pos, right, up, fwd := control_rig_get_head_face_basis(rig)
	off := rig.eye_level_socket.position
	return head_pos + right * off.x + up * off.y + fwd * off.z
}

// Backward-compatible alias
control_rig_get_eye_world_position :: proc(rig: ^ControlRig) -> [3]f32 {
	return control_rig_get_eye_level_world_position(rig)
}

// Returns the full world-space transform (position and orientation) of the Eye Level Socket / camera pawn mount point.
control_rig_get_eye_level_world_transform :: proc(rig: ^ControlRig) -> (pos: [3]f32, rot: quaternion128) {
	head_pos, right, up, fwd := control_rig_get_head_face_basis(rig)
	off := rig.eye_level_socket.position
	pos = head_pos + right * off.x + up * off.y + fwd * off.z
	m := matrix[3, 3]f32{
		right.x, up.x, fwd.x,
		right.y, up.y, fwd.y,
		right.z, up.z, fwd.z,
	}
	face_rot := linalg.quaternion_from_matrix3(m)
	rot = linalg.quaternion_normalize(face_rot * engine.quat_to_native(rig.eye_level_socket.rotation))
	return
}

// Backward-compatible alias
control_rig_get_eye_world_transform :: proc(rig: ^ControlRig) -> (pos: [3]f32, rot: quaternion128) {
	return control_rig_get_eye_level_world_transform(rig)
}

@(update={order=2})
control_rig_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(control_rigs(w))
	for rig, _ in engine.pool_next(&it) {
		if !rig.active do continue

		// Always ensure healthy, non-zero, non-NaN controls
		control_rig_sanitize(rig)

		// Auto-bind bones if not bound or invalid
		if !rig.bones.bound || !skeleton_bones_alive(&rig.bones) {
			skeleton_bind_humanoid(&rig.bones, rig.owner)
		}

		// When HumanoidIkSolver is attached, it handles driving the skeleton (order=3).
		// Only run fallback solving if rig is active AND no HumanoidIkSolver is attached.
		_, solver := engine.transform_get_comp(rig.owner, HumanoidIkSolver)
		if solver == nil && rig.active && rig.bones.bound {
			skeleton_apply_controls(&rig.bones, rig.owner, rig)
		}
	}
}
