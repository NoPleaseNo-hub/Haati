package control_rig

// Humanoid Skeleton Binding & Real-Time Analytical IK Application.
// Resolves standard humanoid armature bones and articulates them from Procedural_Pose.

import "core:math"
import "core:strings"
import "core:math/linalg"
import engine "moonhug:engine"

Bone_Rest_Transform :: struct {
	pos:   [3]f32, // character actor-local position
	rot:   [4]f32, // character actor-local rotation
	valid: bool,
}

Limb_Rest_Pose :: struct {
	root_pos: [3]f32, // character actor-local position
	root_rot: [4]f32, // character actor-local rotation
	mid_pos:  [3]f32, // character actor-local position
	mid_rot:  [4]f32, // character actor-local rotation
	tip_pos:  [3]f32, // character actor-local position
	tip_rot:  [4]f32, // character actor-local rotation
	valid:    bool,
}

Humanoid_Bones :: struct {
	pelvis:         engine.Transform_Handle,
	spine:          engine.Transform_Handle,
	chest:          engine.Transform_Handle,
	head:           engine.Transform_Handle,

	left_thigh:     engine.Transform_Handle,
	left_calf:      engine.Transform_Handle,
	left_foot:      engine.Transform_Handle,

	right_thigh:    engine.Transform_Handle,
	right_calf:     engine.Transform_Handle,
	right_foot:     engine.Transform_Handle,

	left_upperarm:  engine.Transform_Handle,
	left_lowerarm:  engine.Transform_Handle,
	left_hand:      engine.Transform_Handle,

	right_upperarm: engine.Transform_Handle,
	right_lowerarm: engine.Transform_Handle,
	right_hand:     engine.Transform_Handle,

	left_toe:       engine.Transform_Handle,
	right_toe:      engine.Transform_Handle,

	// Rest Bind Pose Caches (Stateless Analytical IK reference)
	pelvis_rest:    Bone_Rest_Transform,
	spine_rest:     Bone_Rest_Transform,
	chest_rest:     Bone_Rest_Transform,
	head_rest:      Bone_Rest_Transform,
	left_toe_rest:  Bone_Rest_Transform,
	right_toe_rest: Bone_Rest_Transform,

	left_leg_rest:  Limb_Rest_Pose,
	right_leg_rest: Limb_Rest_Pose,
	left_arm_rest:  Limb_Rest_Pose,
	right_arm_rest: Limb_Rest_Pose,

	bound:          bool,
	search_root:    engine.Transform_Handle,
}

skeleton_bones_alive :: proc(bones: ^Humanoid_Bones) -> bool {
	if !bones.bound do return false
	w := engine.ctx_world()
	if w == nil do return false

	if bones.pelvis != {} && !engine.pool_valid(&w.transforms, engine.Handle(bones.pelvis)) do return false
	if bones.left_thigh != {} && !engine.pool_valid(&w.transforms, engine.Handle(bones.left_thigh)) do return false
	if bones.right_thigh != {} && !engine.pool_valid(&w.transforms, engine.Handle(bones.right_thigh)) do return false
	return true
}

skeleton_find_bone_by_name :: proc(root: engine.Transform_Handle, name: string) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	if w == nil || root == {} do return {}, false

	queue := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	append(&queue, root)

	for len(queue) > 0 {
		curr := pop_front(&queue)
		t := engine.pool_get(&w.transforms, engine.Handle(curr))
		if t == nil do continue

		// Scene root can never be a bone
		if t.parent.handle != {} {
			if strings.equal_fold(t.name, name) {
				return curr, true
			}
		}

		for child in t.children {
			append(&queue, engine.Transform_Handle(child.handle))
		}
	}
	return {}, false
}

@(private = "file")
_normalize_bone_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	s := strings.to_lower(name, allocator)
	prefixes := []string{
		"mixamorig:", "mixamorig1:", "mixamorig2:", "mixamorig3:", "mixamorig4:", "mixamorig5:", "mixamorig6:", "mixamorig7:", "mixamorig8:", "mixamorig9:",
		"mixamorig_", "mixamorig1_", "mixamorig2_",
		"def-", "def_", "org-", "org_", "mch-", "mch_",
		"bip01_", "bip01 ", "bip02_", "bip001_", "bip01-",
		"cc_base_", "cc_base-",
		"j_bip_c_", "j_bip_l_", "j_bip_r_", "j_bip_",
		"character1_", "character_", "char_",
		"root_", "bone_",
	}
	for p in prefixes {
		if strings.has_prefix(s, p) {
			s = s[len(p):]
			break
		}
	}
	b := strings.builder_make(allocator)
	for r in s {
		if r != '.' && r != '_' && r != '-' && r != ' ' && r != ':' {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

skeleton_find_bone_by_aliases :: proc(root: engine.Transform_Handle, aliases: []string) -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil || root == {} do return {}

	queue := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	append(&queue, root)

	all_nodes := make([dynamic]engine.Transform_Handle, context.temp_allocator)

	// Pass 1: Exact case-insensitive matching
	for len(queue) > 0 {
		curr := pop_front(&queue)
		t := engine.pool_get(&w.transforms, engine.Handle(curr))
		if t == nil do continue

		// Scene root can never be a bone
		if t.parent.handle != {} {
			append(&all_nodes, curr)
			for alias in aliases {
				if strings.equal_fold(t.name, alias) {
					return curr
				}
			}
		}

		for child in t.children {
			append(&queue, engine.Transform_Handle(child.handle))
		}
	}

	// Pass 2: Prefix-stripped and punctuation-stripped normalized matching
	norm_aliases := make([dynamic]string, context.temp_allocator)
	for alias in aliases {
		append(&norm_aliases, _normalize_bone_name(alias, context.temp_allocator))
	}

	for curr in all_nodes {
		t := engine.pool_get(&w.transforms, engine.Handle(curr))
		if t == nil do continue
		norm_name := _normalize_bone_name(t.name, context.temp_allocator)
		for na in norm_aliases {
			if norm_name == na {
				return curr
			}
		}
	}

	return {}
}

@(private = "file")
_find_bone_in_tree :: proc(root: engine.Transform_Handle, aliases: []string) -> engine.Transform_Handle {
	return skeleton_find_bone_by_aliases(root, aliases)
}

skeleton_bind_humanoid :: proc(bones: ^Humanoid_Bones, char_h: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	if w == nil do return false

	root_t := engine.pool_get(&w.transforms, engine.Handle(char_h))
	if root_t == nil do return false

	search_root := char_h

	// Resolve search root from ArmatureDeformedMesh if present on character, parent, or children
	_, adm := engine.transform_get_comp(char_h, ArmatureDeformedMesh)
	if adm == nil && root_t.parent.handle != {} {
		_, adm = engine.transform_get_comp(engine.Transform_Handle(root_t.parent.handle), ArmatureDeformedMesh)
	}
	if adm == nil {
		for child in root_t.children {
			_, cadm := engine.transform_get_comp(engine.Transform_Handle(child.handle), ArmatureDeformedMesh)
			if cadm != nil {
				adm = cadm
				break
			}
		}
	}

	if adm != nil && adm.root_bone.handle != {} && engine.pool_valid(&w.transforms, adm.root_bone.handle) {
		search_root = engine.Transform_Handle(adm.root_bone.handle)
	} else if len(root_t.children) == 0 && root_t.parent.handle != {} {
		search_root = engine.Transform_Handle(root_t.parent.handle)
	}

	_do_bind :: proc(bones: ^Humanoid_Bones, root: engine.Transform_Handle) {
		bones.pelvis = _find_bone_in_tree(root, {"pelvis", "hips", "hip", "root_bone", "bip01_pelvis", "bip01_hips", "def-pelvis", "def-hips", "mixamorig:hips", "barriga", "piv_hips", "bones_pelvis", "j_bip_c_hips", "cc_base_pelvis", "cc_base_hip", "cog"})
		bones.spine  = _find_bone_in_tree(root, {"spine_01", "spine", "spine1", "spine_02", "mixamorig:spine", "def-spine", "bip01_spine", "bip01_spine1", "barriga.001", "vertebrae", "bones_spine", "j_bip_c_spine", "cc_base_spine01", "abdomen"})
		bones.chest  = _find_bone_in_tree(root, {"spine_02", "spine_03", "chest", "upper_chest", "mixamorig:spine1", "mixamorig:spine2", "def-spine.001", "def-spine.002", "def-chest", "bip01_spine2", "peito", "peito.001", "piv_chest", "sternum", "j_bip_c_chest", "cc_base_spine02"})
		bones.head   = _find_bone_in_tree(root, {"head", "neck_01", "neck", "mixamorig:head", "def-head", "bip01_head", "cabeca", "bones_head", "j_bip_c_head", "cc_base_head"})

		bones.left_thigh = _find_bone_in_tree(root, {"thigh_l", "leftupleg", "upper_leg.l", "thigh.l", "leg_l", "upperleg_l", "femur.l", "perna_l", "mixamorig:leftupleg", "def-thigh.l", "def-upper_leg.l", "bip01_l_thigh", "j_bip_l_upperleg", "cc_base_l_thigh", "l_thigh", "l_upleg"})
		bones.left_calf  = _find_bone_in_tree(root, {"calf_l", "leftleg", "shin.l", "calf.l", "knee_l", "lowerleg_l", "tibia.l", "antperna_l", "mixamorig:leftleg", "def-shin.l", "def-calf.l", "bip01_l_calf", "j_bip_l_lowerleg", "cc_base_l_calf", "l_calf", "l_shin"})
		bones.left_foot  = _find_bone_in_tree(root, {"foot_l", "leftfoot", "foot.l", "ankle_l", "pe_l", "mixamorig:leftfoot", "def-foot.l", "def-ankle.l", "bip01_l_foot", "j_bip_l_foot", "cc_base_l_foot", "l_foot"})
		bones.left_toe   = _find_bone_in_tree(root, {"toe_l", "ball_l", "lefttoebase", "toe.l", "ball.l", "left_toe", "lefttoe", "ped_l", "mixamorig:lefttoebase", "def-toe.l", "bip01_l_toe0", "j_bip_l_toebase", "cc_base_l_toe", "l_toe"})

		bones.right_thigh = _find_bone_in_tree(root, {"thigh_r", "rightupleg", "upper_leg.r", "thigh.r", "leg_r", "upperleg_r", "femur.r", "perna_r", "mixamorig:rightupleg", "def-thigh.r", "def-upper_leg.r", "bip01_r_thigh", "j_bip_r_upperleg", "cc_base_r_thigh", "r_thigh", "r_upleg"})
		bones.right_calf  = _find_bone_in_tree(root, {"calf_r", "rightleg", "shin.r", "calf.r", "knee_r", "lowerleg_r", "tibia.r", "antperna_r", "mixamorig:rightleg", "def-shin.r", "def-calf.r", "bip01_r_calf", "j_bip_r_lowerleg", "cc_base_r_calf", "r_calf", "r_shin"})
		bones.right_foot  = _find_bone_in_tree(root, {"foot_r", "rightfoot", "foot.r", "ankle_r", "pe_r", "mixamorig:rightfoot", "def-foot.r", "def-ankle.r", "bip01_r_foot", "j_bip_r_foot", "cc_base_r_foot", "r_foot"})
		bones.right_toe   = _find_bone_in_tree(root, {"toe_r", "ball_r", "righttoebase", "toe.r", "ball.r", "right_toe", "righttoe", "ped_r", "mixamorig:righttoebase", "def-toe.r", "bip01_r_toe0", "j_bip_r_toebase", "cc_base_r_toe", "r_toe"})

		bones.left_upperarm = _find_bone_in_tree(root, {"upperarm_l", "leftarm", "upper_arm.l", "arm.l", "shoulder_l", "braco_l", "humerus.l", "mixamorig:leftarm", "def-upper_arm.l", "def-arm.l", "bip01_l_upperarm", "j_bip_l_upperarm", "cc_base_l_upperarm", "l_upperarm", "l_arm"})
		bones.left_lowerarm = _find_bone_in_tree(root, {"lowerarm_l", "forearm_l", "leftforearm", "forearm.l", "elbow_l", "antbraco_l", "radius.l", "ulna.l", "mixamorig:leftforearm", "def-forearm.l", "bip01_l_forearm", "j_bip_l_lowerarm", "cc_base_l_forearm", "l_lowerarm", "l_forearm"})
		bones.left_hand     = _find_bone_in_tree(root, {"hand_l", "lefthand", "hand.l", "wrist_l", "mao_l", "mixamorig:lefthand", "def-hand.l", "bip01_l_hand", "j_bip_l_hand", "cc_base_l_hand", "l_hand", "l_wrist"})

		bones.right_upperarm = _find_bone_in_tree(root, {"upperarm_r", "rightarm", "upper_arm.r", "arm.r", "shoulder_r", "braco_r", "humerus.r", "mixamorig:rightarm", "def-upper_arm.r", "def-arm.r", "bip01_r_upperarm", "j_bip_r_upperarm", "cc_base_r_upperarm", "r_upperarm", "r_arm"})
		bones.right_lowerarm = _find_bone_in_tree(root, {"lowerarm_r", "forearm_r", "rightforearm", "forearm.r", "elbow_r", "antbraco_r", "radius.r", "ulna.r", "mixamorig:rightforearm", "def-forearm.r", "bip01_r_forearm", "j_bip_r_lowerarm", "cc_base_r_forearm", "r_lowerarm", "r_forearm"})
		bones.right_hand     = _find_bone_in_tree(root, {"hand_r", "righthand", "hand.r", "wrist_r", "mao_r", "mixamorig:righthand", "def-hand.r", "bip01_r_hand", "j_bip_r_hand", "cc_base_r_hand", "r_hand", "r_wrist"})
	}

	bones.search_root = search_root
	_do_bind(bones, search_root)

	// If initial search root didn't bind, fall back to char_h or parent
	if bones.pelvis == {} && bones.left_thigh == {} && bones.right_thigh == {} {
		if search_root != char_h {
			bones.search_root = char_h
			_do_bind(bones, char_h)
		}
		if (bones.pelvis == {} && bones.left_thigh == {}) && root_t.parent.handle != {} {
			parent_h := engine.Transform_Handle(root_t.parent.handle)
			bones.search_root = parent_h
			_do_bind(bones, parent_h)
		}
	}

	bones.bound = (bones.pelvis != {} || bones.left_thigh != {} || bones.right_thigh != {})
	if bones.bound {
		skeleton_capture_rest_pose(bones, char_h)
	}
	return bones.bound
}


@(private)
_world_to_actor_local_pos :: proc(w_pos: [3]f32, c_pos: [3]f32, inv_r: quaternion128, c_scale: [3]f32) -> [3]f32 {
	delta := w_pos - c_pos
	unrot := linalg.quaternion128_mul_vector3(inv_r, delta)
	sx := c_scale.x != 0 ? c_scale.x : 1.0
	sy := c_scale.y != 0 ? c_scale.y : 1.0
	sz := c_scale.z != 0 ? c_scale.z : 1.0
	return {unrot.x / sx, unrot.y / sy, unrot.z / sz}
}

@(private)
_world_to_actor_local_rot :: proc(w_rot: [4]f32, inv_r: quaternion128) -> [4]f32 {
	q_w := safe_quat_native(engine.quat_to_native(safe_quat(w_rot)))
	return engine.quat_from_native(safe_quat_native(inv_r * q_w))
}

skeleton_capture_limb_rest :: proc(
	root_h, mid_h, tip_h: engine.Transform_Handle,
	char_h: engine.Transform_Handle,
) -> Limb_Rest_Pose {
	w := engine.ctx_world()
	if w == nil || char_h == {} do return {}
	if !engine.pool_valid(&w.transforms, engine.Handle(root_h)) do return {}
	if !engine.pool_valid(&w.transforms, engine.Handle(mid_h)) do return {}
	if !engine.pool_valid(&w.transforms, engine.Handle(tip_h)) do return {}

	char_tw := engine.transform_world(char_h)
	char_pos := char_tw.position
	char_rot := safe_quat_native(engine.quat_to_native(char_tw.rotation))
	char_scale := char_tw.scale
	inv_rot := linalg.quaternion_inverse(char_rot)

	r_pos := engine.transform_world_position(root_h)
	m_pos := engine.transform_world_position(mid_h)
	t_pos := engine.transform_world_position(tip_h)

	if math.is_nan(r_pos.x) || math.is_nan(m_pos.x) || math.is_nan(t_pos.x) {
		return {}
	}

	return Limb_Rest_Pose{
		root_pos = _world_to_actor_local_pos(r_pos, char_pos, inv_rot, char_scale),
		root_rot = _world_to_actor_local_rot(engine.transform_world_rotation(root_h), inv_rot),
		mid_pos  = _world_to_actor_local_pos(m_pos, char_pos, inv_rot, char_scale),
		mid_rot  = _world_to_actor_local_rot(engine.transform_world_rotation(mid_h), inv_rot),
		tip_pos  = _world_to_actor_local_pos(t_pos, char_pos, inv_rot, char_scale),
		tip_rot  = _world_to_actor_local_rot(engine.transform_world_rotation(tip_h), inv_rot),
		valid    = true,
	}
}

skeleton_capture_bone_rest :: proc(bone_h: engine.Transform_Handle, char_h: engine.Transform_Handle) -> Bone_Rest_Transform {
	w := engine.ctx_world()
	if w == nil || char_h == {} || bone_h == {} do return {}
	if !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return {}

	char_tw := engine.transform_world(char_h)
	char_pos := char_tw.position
	char_rot := safe_quat_native(engine.quat_to_native(char_tw.rotation))
	char_scale := char_tw.scale
	inv_rot := linalg.quaternion_inverse(char_rot)

	b_pos := engine.transform_world_position(bone_h)
	if math.is_nan(b_pos.x) || math.is_nan(b_pos.y) || math.is_nan(b_pos.z) {
		return {}
	}

	return Bone_Rest_Transform{
		pos   = _world_to_actor_local_pos(b_pos, char_pos, inv_rot, char_scale),
		rot   = _world_to_actor_local_rot(engine.transform_world_rotation(bone_h), inv_rot),
		valid = true,
	}
}

skeleton_capture_rest_pose :: proc(bones: ^Humanoid_Bones, char_h: engine.Transform_Handle) {
	if bones.pelvis != {} do bones.pelvis_rest = skeleton_capture_bone_rest(bones.pelvis, char_h)
	if bones.spine  != {} do bones.spine_rest  = skeleton_capture_bone_rest(bones.spine, char_h)
	if bones.chest  != {} do bones.chest_rest  = skeleton_capture_bone_rest(bones.chest, char_h)
	if bones.head   != {} do bones.head_rest   = skeleton_capture_bone_rest(bones.head, char_h)

	if bones.left_thigh != {} && bones.left_calf != {} && bones.left_foot != {} {
		bones.left_leg_rest = skeleton_capture_limb_rest(bones.left_thigh, bones.left_calf, bones.left_foot, char_h)
	}
	if bones.right_thigh != {} && bones.right_calf != {} && bones.right_foot != {} {
		bones.right_leg_rest = skeleton_capture_limb_rest(bones.right_thigh, bones.right_calf, bones.right_foot, char_h)
	}
	if bones.left_upperarm != {} && bones.left_lowerarm != {} && bones.left_hand != {} {
		bones.left_arm_rest = skeleton_capture_limb_rest(bones.left_upperarm, bones.left_lowerarm, bones.left_hand, char_h)
	}
	if bones.right_upperarm != {} && bones.right_lowerarm != {} && bones.right_hand != {} {
		bones.right_arm_rest = skeleton_capture_limb_rest(bones.right_upperarm, bones.right_lowerarm, bones.right_hand, char_h)
	}

	if bones.left_toe  != {} do bones.left_toe_rest  = skeleton_capture_bone_rest(bones.left_toe, char_h)
	if bones.right_toe != {} do bones.right_toe_rest = skeleton_capture_bone_rest(bones.right_toe, char_h)
}


skeleton_apply_pose :: proc(bones: ^Humanoid_Bones, char_h: engine.Transform_Handle, pose: Procedural_Pose) {
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

	local_to_world_rot :: proc(q_local: [4]f32, c_rot: quaternion128) -> [4]f32 {
		q_l := engine.quat_to_native(q_local)
		return engine.quat_from_native(linalg.quaternion_normalize(c_rot * q_l))
	}

	// 1. Pelvis
	if engine.pool_valid(&w.transforms, engine.Handle(bones.pelvis)) {
		pelvis_world_pos := local_to_world_pos(pose.pelvis_pos, char_pos, char_rot, char_scale)
		pelvis_world_rot := local_to_world_rot(pose.pelvis_rot, char_rot)
		engine.transform_set_world_position(bones.pelvis, pelvis_world_pos)
		engine.transform_set_world_rotation(bones.pelvis, pelvis_world_rot)
	}

	// 2. Spine / Chest
	if engine.pool_valid(&w.transforms, engine.Handle(bones.chest)) {
		chest_world_rot := local_to_world_rot(pose.chest_rot, char_rot)
		engine.transform_set_world_rotation(bones.chest, chest_world_rot)
	}

	// 3. Head
	if engine.pool_valid(&w.transforms, engine.Handle(bones.head)) {
		head_world_rot := local_to_world_rot(pose.head_rot, char_rot)
		engine.transform_set_world_rotation(bones.head, head_world_rot)
	}

	// 4. Left Leg IK
	if bones.left_leg_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_thigh)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_calf)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_foot)) {

		target_pos := local_to_world_pos(pose.left_foot_pos, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(pose.left_knee_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if pose.left_foot_rot != engine.QUAT_IDENTITY {
			rot_delta = engine.quat_to_native(pose.left_foot_rot)
		}

		char_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))

		solve_two_bone_limb(
			bones.left_thigh, bones.left_calf, bones.left_foot,
			bones.left_leg_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0, 1.0, rot_delta,
			default_pole_dir = char_fwd,
		)
	}

	// 5. Right Leg IK
	if bones.right_leg_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_thigh)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_calf)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_foot)) {

		target_pos := local_to_world_pos(pose.right_foot_pos, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(pose.right_knee_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if pose.right_foot_rot != engine.QUAT_IDENTITY {
			rot_delta = engine.quat_to_native(pose.right_foot_rot)
		}

		char_fwd := linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))
		solve_two_bone_limb(
			bones.right_thigh, bones.right_calf, bones.right_foot,
			bones.right_leg_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0, 1.0, rot_delta,
			default_pole_dir = char_fwd,
		)
	}

	// 6. Left Arm IK
	if bones.left_arm_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_upperarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_lowerarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.left_hand)) {

		target_pos := local_to_world_pos(pose.left_hand_pos, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(pose.left_elbow_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if pose.left_hand_rot != engine.QUAT_IDENTITY {
			rot_delta = engine.quat_to_native(pose.left_hand_rot)
		}

		char_back := -linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))
		solve_two_bone_limb(
			bones.left_upperarm, bones.left_lowerarm, bones.left_hand,
			bones.left_arm_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0, 1.0, rot_delta,
			default_pole_dir = char_back,
		)
	}

	// 7. Right Arm IK
	if bones.right_arm_rest.valid &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_upperarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_lowerarm)) &&
	   engine.pool_valid(&w.transforms, engine.Handle(bones.right_hand)) {

		target_pos := local_to_world_pos(pose.right_hand_pos, char_pos, char_rot, char_scale)
		pole_pos   := local_to_world_pos(pose.right_elbow_pole, char_pos, char_rot, char_scale)

		rot_delta: Maybe(quaternion128) = nil
		if pose.right_hand_rot != engine.QUAT_IDENTITY {
			rot_delta = engine.quat_to_native(pose.right_hand_rot)
		}

		char_back := -linalg.normalize0(linalg.quaternion128_mul_vector3(char_rot, [3]f32{0, 0, 1}))
		solve_two_bone_limb(
			bones.right_upperarm, bones.right_lowerarm, bones.right_hand,
			bones.right_arm_rest,
			char_pos, char_rot, char_scale,
			target_pos, pole_pos,
			1.0, 1.0, rot_delta,
			default_pole_dir = char_back,
		)
	}
}

// Backward-compatibility wrapper for ControlRig when HumanoidIkSolver is not attached
skeleton_apply_controls :: proc(bones: ^Humanoid_Bones, char_h: engine.Transform_Handle, rig: ^ControlRig) {
	humanoid_ik_solve(
		bones,
		char_h,
		rig,
		look_at_max_angle = 85.0,
		wrist_twist_ratio = 0.5,
	)
}

