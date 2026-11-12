package control_rig_tests

import "core:math/linalg"
import "core:testing"
import "core:encoding/uuid"
import engine "moonhug:engine"
import "moonhug:editor/handles"
import physics3d "moonhug:packages/physics3d"
import crig "moonhug:packages/control_rig"
import crig_editor "moonhug:packages/control_rig/editor"
import common "moonhug:tests/common"

@(test)
test_control_rig_pose_presets :: proc(t: ^testing.T) {
	rest := crig.default_rest_pose()
	testing.expect(t, rest.pelvis_pos.y > 0.8, "Pelvis should be above ground in rest pose")
	testing.expect(t, rest.head_pos.y > rest.chest_pos.y, "Head should be higher than chest")

	crouch := crig.pose_crouch()
	testing.expect(t, crouch.pelvis_pos.y < rest.pelvis_pos.y, "Pelvis should drop in crouch")

	prone := crig.pose_prone_brace()
	testing.expect(t, prone.pelvis_pos.y < 0.4, "Pelvis should be low in prone brace")
	testing.expect(t, prone.left_hand_pos.y <= 0.1, "Hands should be grounded in prone brace")

	blended := crig.procedural_pose_lerp(rest, crouch, 0.5)
	expected_y := (rest.pelvis_pos.y + crouch.pelvis_pos.y) * 0.5
	testing.expect(t, abs(blended.pelvis_pos.y - expected_y) < 0.001, "Pose lerp should linearly interpolate positions")
}

@(test)
test_control_rig_two_bone_ik :: proc(t: ^testing.T) {
	root := [3]f32{0, 1.0, 0}
	mid  := [3]f32{0, 0.5, 0}
	tip  := [3]f32{0, 0.0, 0}

	target := [3]f32{0, 0.2, 0.3}
	pole   := [3]f32{0, 0.5, 1.0}

	ik := crig.two_bone_ik(root, mid, tip, target, pole)

	testing.expect(t, ik.reached, "Target within reach should be marked reached")
	d_upper := linalg.distance(ik.root_pos, ik.mid_pos)
	d_lower := linalg.distance(ik.mid_pos, ik.tip_pos)
	testing.expect(t, abs(d_upper - 0.5) < 0.01, "Upper limb length should be preserved")
	testing.expect(t, abs(d_lower - 0.5) < 0.01, "Lower limb length should be preserved")
}

@(test)
test_control_rig_spring_damper_dynamics :: proc(t: ^testing.T) {
	rest := crig.default_rest_pose()
	dyn: crig.ControlRig_Dynamics
	crig.dynamics_init(&dyn, rest)

	// Inject hit impulse to chest
	crig.dynamics_add_impulse(&dyn, .Chest, [3]f32{0, 0, -15.0})
	testing.expect(t, dyn.chest.linear_vel.z < -0.1, "Impulse should immediately accelerate chest")

	// Step physics for 0.4 seconds
	dt: f32 = 1.0 / 60.0
	for _ in 0 ..< 24 {
		crig.dynamics_update(&dyn, rest, dt, 0.0, 180.0, 22.0, {}, 0.0, 1.0)
	}

	// Spring-damper should be dampening chest velocity back toward 0
	testing.expect(t, abs(dyn.chest.linear_vel.z) < 15.0, "Damping should suppress impulse velocity")
}

@(test)
test_control_rig_fatigue_scaling :: proc(t: ^testing.T) {
	rest := crig.default_rest_pose()
	dyn_fresh: crig.ControlRig_Dynamics
	dyn_tired: crig.ControlRig_Dynamics
	crig.dynamics_init(&dyn_fresh, rest)
	crig.dynamics_init(&dyn_tired, rest)

	// Apply identical impulse to both
	impulse := [3]f32{0, 0, -10.0}
	crig.dynamics_add_impulse(&dyn_fresh, .Chest, impulse)
	crig.dynamics_add_impulse(&dyn_tired, .Chest, impulse)

	// Step 10 frames: fresh has fatigue 0.0, tired has fatigue 1.0
	dt: f32 = 1.0 / 60.0
	for _ in 0 ..< 10 {
		crig.dynamics_update(&dyn_fresh, rest, dt, 0.0, 180.0, 22.0, {}, 0.0, 1.0)
		crig.dynamics_update(&dyn_tired, rest, dt, 1.0, 180.0, 22.0, {}, 0.0, 1.0)
	}

	// Tired character should yield significantly more displacement due to lower stiffness
	disp_fresh := abs(dyn_fresh.chest.pos.z - rest.chest_pos.z)
	disp_tired := abs(dyn_tired.chest.pos.z - rest.chest_pos.z)
	testing.expect(t, disp_tired > disp_fresh, "Fatigued character should displace more under impact")
}

@(test)
test_smart_collider_placer :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("CharacterActor")
	pelvis := engine.transform_new("pelvis", root)
	thigh_l := engine.transform_new("thigh_l", pelvis)
	calf_l := engine.transform_new("calf_l", thigh_l)
	foot_l := engine.transform_new("foot_l", calf_l)
	head := engine.transform_new("head", pelvis)

	// Set test positions
	t_pelvis := engine.pool_get(&tc.world.transforms, engine.Handle(pelvis))
	if t_pelvis != nil do t_pelvis.position = {0, 1.0, 0}

	t_head := engine.pool_get(&tc.world.transforms, engine.Handle(head))
	if t_head != nil do t_head.position = {0, 0.7, 0}

	t_thigh := engine.pool_get(&tc.world.transforms, engine.Handle(thigh_l))
	if t_thigh != nil do t_thigh.position = {-0.15, 0.0, 0}

	t_calf := engine.pool_get(&tc.world.transforms, engine.Handle(calf_l))
	if t_calf != nil do t_calf.position = {0, -0.45, 0}

	t_foot := engine.pool_get(&tc.world.transforms, engine.Handle(foot_l))
	if t_foot != nil do t_foot.position = {0, -0.45, 0}

	// Place smart colliders
	count := crig.smart_collider_place_humanoid(root)
	testing.expect(t, count >= 4, "Should have placed colliders on pelvis, head, thigh, calf, foot")

	// Verify head capsule collider
	_, head_cap := engine.transform_get_comp(head, physics3d.CapsuleCollider)
	testing.expect(t, head_cap != nil, "Head should have a CapsuleCollider")
	if head_cap != nil {
		testing.expect(t, head_cap.radius > 0.05, "Head capsule radius should be reasonable")
		testing.expect(t, head_cap.height > 0.15, "Head capsule height should fit skull")
	}

	// Verify foot box collider
	_, foot_box := engine.transform_get_comp(foot_l, physics3d.BoxCollider)
	testing.expect(t, foot_box != nil, "Foot should have a BoxCollider")

	// Remove colliders
	crig.smart_collider_remove_humanoid(root)
	_, head_cap_removed := engine.transform_get_comp(head, physics3d.CapsuleCollider)
	testing.expect(t, head_cap_removed == nil, "Head CapsuleCollider should be removed")
}

@(test)
test_individual_bone_collider_add_and_remove :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	bone := engine.transform_new("TestBone")

	// Add Capsule
	crig.smart_collider_add_capsule(bone, radius = 0.1, height = 0.4, dir = .Y_Axis, center = {0, 0.2, 0})
	_, cap := engine.transform_get_comp(bone, physics3d.CapsuleCollider)
	testing.expect(t, cap != nil, "Capsule should be added")
	if cap != nil {
		testing.expect(t, cap.radius == 0.1, "Capsule radius should be 0.1")
		testing.expect(t, cap.height == 0.4, "Capsule height should be 0.4")
	}

	// Add Box
	crig.smart_collider_add_box(bone, size = {0.2, 0.3, 0.4}, center = {0, 0, 0})
	_, box := engine.transform_get_comp(bone, physics3d.BoxCollider)
	testing.expect(t, box != nil, "Box should be added")

	// Add Sphere
	crig.smart_collider_add_sphere(bone, radius = 0.15, center = {0, 0, 0})
	_, sph := engine.transform_get_comp(bone, physics3d.SphereCollider)
	testing.expect(t, sph != nil, "Sphere should be added")

	// Remove all colliders from bone
	crig.smart_collider_remove_from_bone(bone)
	_, cap_del := engine.transform_get_comp(bone, physics3d.CapsuleCollider)
	_, box_del := engine.transform_get_comp(bone, physics3d.BoxCollider)
	_, sph_del := engine.transform_get_comp(bone, physics3d.SphereCollider)
	testing.expect(t, cap_del == nil, "Capsule should be removed")
	testing.expect(t, box_del == nil, "Box should be removed")
	testing.expect(t, sph_del == nil, "Sphere should be removed")
}

@(test)
test_armature_deformed_mesh_reset_bind_pose :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	mesh_guid_raw, _ := uuid.read("ea8331b2-faec-4dcf-9a4b-e83c37f7ba6d")
	engine._register_asset("plugins/control_rig/assets/skeletons/UAL1_Standard.glb", mesh_guid_raw)
	defer engine.asset_db_shutdown()

	scene_root := engine.Transform_Handle(tc.scene.root.handle)
	actor := engine.transform_new("CharacterActor", scene_root)
	_, raw_adm := engine.transform_add_comp(actor, .ArmatureDeformedMesh)
	adm := cast(^crig.ArmatureDeformedMesh)raw_adm
	testing.expect(t, adm != nil, "ArmatureDeformedMesh should exist")
	adm.mesh = engine.Asset_GUID(mesh_guid_raw)

	_, raw_rig := engine.transform_add_comp(actor, .ControlRig)
	rig := cast(^crig.ControlRig)raw_rig
	testing.expect(t, rig != nil, "ControlRig should exist")
	rig.active = true
	adm.bound_ready = true

	// Call reset bind pose
	crig.armature_deformed_mesh_reset_bind_pose(adm)

	testing.expect(t, !adm.bound_ready, "adm bound_ready should be reset so it cleanly re-binds")

	// Scene Root must NEVER be modified or rotated by reset_bind_pose!
	root_t := engine.pool_get(&tc.world.transforms, engine.Handle(scene_root))
	testing.expect(t, root_t.rotation == [4]f32{0, 0, 0, 1}, "Scene Root must remain identity")
	actor_t := engine.pool_get(&tc.world.transforms, engine.Handle(actor))
	testing.expect(t, actor_t.rotation == [4]f32{0, 0, 0, 1}, "Actor transform must remain identity")

	// Verify skeleton was spawned and is upright (+Y Up)
	pelvis_h, pelvis_ok := crig.skeleton_find_bone_by_name(actor, "pelvis")
	testing.expect(t, pelvis_ok, "pelvis bone should exist under actor")
	if pelvis_ok {
		pelvis_pos := engine.transform_world_position(pelvis_h)
		testing.expect(t, pelvis_pos.y > 0.8, "Pelvis must be upright along +Y (Y > 0.8m)")
		testing.expect(t, abs(pelvis_pos.z) < 0.2, "Pelvis must NOT lay down along Z (|Z| < 0.2m)")
	}

	head_h, head_ok := crig.skeleton_find_bone_by_name(actor, "Head")
	testing.expect(t, head_ok, "Head bone should exist under actor")
	if head_ok {
		head_pos := engine.transform_world_position(head_h)
		testing.expect(t, head_pos.y > 1.4, "Head must be at top along +Y (Y > 1.4m)")
		testing.expect(t, abs(head_pos.z) < 0.2, "Head must NOT lay down along Z (|Z| < 0.2m)")
	}
}

@(test)
test_control_rig_swing_twist_decomposition :: proc(t: ^testing.T) {
	axis := [3]f32{1, 0, 0}

	// 1. Pure twist rotation around X axis (45 degrees)
	twist_angle: f32 = 0.785398
	pure_twist := linalg.quaternion_angle_axis(twist_angle, axis)
	swing, twist := crig.swing_twist_decompose(pure_twist, axis)

	// Swing should be identity, twist should match input
	testing.expect(t, abs(swing.w - 1.0) < 0.01, "Pure twist should yield identity swing (w == 1)")
	testing.expect(t, abs(twist.x - pure_twist.x) < 0.01, "Twist component should match along axis")

	// 2. Pure swing rotation around Y axis (30 degrees perpendicular to axis)
	swing_angle: f32 = 0.523598
	pure_swing := linalg.quaternion_angle_axis(swing_angle, [3]f32{0, 1, 0})
	s_out, t_out := crig.swing_twist_decompose(pure_swing, axis)

	testing.expect(t, abs(t_out.w - 1.0) < 0.01, "Pure swing should yield identity twist (w == 1)")
	testing.expect(t, abs(s_out.y - pure_swing.y) < 0.01, "Swing component should match input")

	// 3. Combined rotation: reconstruct original from swing * twist
	combined := pure_swing * pure_twist
	s_comb, t_comb := crig.swing_twist_decompose(combined, axis)
	reconstructed := s_comb * t_comb

	testing.expect(t, abs(reconstructed.w - combined.w) < 0.01, "Reconstructed quaternion should match combined input (w)")
	testing.expect(t, abs(reconstructed.x - combined.x) < 0.01, "Reconstructed quaternion should match combined input (x)")
	testing.expect(t, abs(reconstructed.y - combined.y) < 0.01, "Reconstructed quaternion should match combined input (y)")
	testing.expect(t, abs(reconstructed.z - combined.z) < 0.01, "Reconstructed quaternion should match combined input (z)")
}

@(test)
test_control_rig_modular_controls :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	actor := engine.transform_new("RigActor")
	_, raw_rig := engine.transform_add_comp(actor, .ControlRig)
	rig := cast(^crig.ControlRig)raw_rig
	testing.expect(t, rig != nil, "ControlRig component should be added")

	// Verify defaults
	testing.expect(t, rig.active == true, "Rig should default active")

	// Verify left (+X) and right (-X) coordinate orientation
	testing.expect(t, rig.left_foot.position.x > 0.0, "Left foot must be on +X")
	testing.expect(t, rig.right_foot.position.x < 0.0, "Right foot must be on -X")
	testing.expect(t, rig.left_hand.position.x > 0.0, "Left hand must be on +X")
	testing.expect(t, rig.right_hand.position.x < 0.0, "Right hand must be on -X")
}

@(test)
test_humanoid_ik_solver_component :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	actor := engine.transform_new("SolverActor")
	_, raw_solver := engine.transform_add_comp(actor, .HumanoidIkSolver)
	solver := cast(^crig.HumanoidIkSolver)raw_solver
	testing.expect(t, solver != nil, "HumanoidIkSolver component should be added")

	testing.expect(t, solver.active == true, "Solver should default active")
	testing.expect(t, solver.look_at_max_angle == 85.0, "Look at max angle default 85")
	testing.expect(t, solver.wrist_twist_ratio == 0.5, "Wrist twist ratio default 0.5")
}

@(test)
test_multi_skeleton_bone_binding :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Test 1: Mixamo naming (with mixamorig: namespace prefix)
	mixamo_actor := engine.transform_new("MixamoActor")
	m_hips := engine.transform_new("mixamorig:Hips", mixamo_actor)
	m_thigh_l := engine.transform_new("mixamorig:LeftUpLeg", m_hips)
	m_calf_l := engine.transform_new("mixamorig:LeftLeg", m_thigh_l)
	m_foot_l := engine.transform_new("mixamorig:LeftFoot", m_calf_l)
	m_arm_l := engine.transform_new("mixamorig:LeftArm", m_hips)
	m_forearm_l := engine.transform_new("mixamorig:LeftForeArm", m_arm_l)
	m_hand_l := engine.transform_new("mixamorig:LeftHand", m_forearm_l)

	mixamo_bones: crig.Humanoid_Bones
	ok_mixamo := crig.skeleton_bind_humanoid(&mixamo_bones, mixamo_actor)
	testing.expect(t, ok_mixamo, "Mixamo skeleton should bind successfully")
	testing.expect(t, mixamo_bones.pelvis == m_hips, "Mixamo hips should bind to pelvis")
	testing.expect(t, mixamo_bones.left_thigh == m_thigh_l, "Mixamo LeftUpLeg should bind to left_thigh")
	testing.expect(t, mixamo_bones.left_calf == m_calf_l, "Mixamo LeftLeg should bind to left_calf")
	testing.expect(t, mixamo_bones.left_foot == m_foot_l, "Mixamo LeftFoot should bind to left_foot")
	testing.expect(t, mixamo_bones.left_upperarm == m_arm_l, "Mixamo LeftArm should bind to left_upperarm")
	testing.expect(t, mixamo_bones.left_lowerarm == m_forearm_l, "Mixamo LeftForeArm should bind to left_lowerarm")
	testing.expect(t, mixamo_bones.left_hand == m_hand_l, "Mixamo LeftHand should bind to left_hand")

	// Test 2: Blender Rigify naming (with DEF- prefix and .L / .R suffix)
	rigify_actor := engine.transform_new("RigifyActor")
	r_root := engine.transform_new("DEF-pelvis", rigify_actor)
	r_thigh_l := engine.transform_new("DEF-thigh.L", r_root)
	r_calf_l := engine.transform_new("DEF-shin.L", r_thigh_l)
	r_foot_l := engine.transform_new("DEF-foot.L", r_calf_l)

	rigify_bones: crig.Humanoid_Bones
	ok_rigify := crig.skeleton_bind_humanoid(&rigify_bones, rigify_actor)
	testing.expect(t, ok_rigify, "Rigify skeleton should bind successfully")
	testing.expect(t, rigify_bones.pelvis == r_root, "Rigify DEF-pelvis should bind to pelvis")
	testing.expect(t, rigify_bones.left_thigh == r_thigh_l, "Rigify DEF-thigh.L should bind to left_thigh")
	testing.expect(t, rigify_bones.left_calf == r_calf_l, "Rigify DEF-shin.L should bind to left_calf")
	testing.expect(t, rigify_bones.left_foot == r_foot_l, "Rigify DEF-foot.L should bind to left_foot")

	// Test 3: Portuguese Character3D naming
	pt_actor := engine.transform_new("PtActor")
	pt_root := engine.transform_new("BARRIGA", pt_actor)
	pt_thigh_l := engine.transform_new("PERNA_L", pt_root)
	pt_calf_l := engine.transform_new("ANTPERNA_L", pt_thigh_l)
	pt_foot_l := engine.transform_new("PE_L", pt_calf_l)

	pt_bones: crig.Humanoid_Bones
	ok_pt := crig.skeleton_bind_humanoid(&pt_bones, pt_actor)
	testing.expect(t, ok_pt, "Portuguese skeleton should bind successfully")
	testing.expect(t, pt_bones.pelvis == pt_root, "BARRIGA should bind to pelvis")
	testing.expect(t, pt_bones.left_thigh == pt_thigh_l, "PERNA_L should bind to left_thigh")
	testing.expect(t, pt_bones.left_calf == pt_calf_l, "ANTPERNA_L should bind to left_calf")
	testing.expect(t, pt_bones.left_foot == pt_foot_l, "PE_L should bind to left_foot")

	// Test 4: Anatomical / FgcSkeleton naming
	anat_actor := engine.transform_new("AnatActor")
	a_root := engine.transform_new("PELVIS", anat_actor)
	a_thigh_l := engine.transform_new("FEMUR.L", a_root)
	a_calf_l := engine.transform_new("TIBIA.L", a_thigh_l)
	a_foot_l := engine.transform_new("FOOT.L", a_calf_l)

	anat_bones: crig.Humanoid_Bones
	ok_anat := crig.skeleton_bind_humanoid(&anat_bones, anat_actor)
	testing.expect(t, ok_anat, "Anatomical skeleton should bind successfully")
	testing.expect(t, anat_bones.pelvis == a_root, "PELVIS should bind to pelvis")
	testing.expect(t, anat_bones.left_thigh == a_thigh_l, "FEMUR.L should bind to left_thigh")
	testing.expect(t, anat_bones.left_calf == a_calf_l, "TIBIA.L should bind to left_calf")
	testing.expect(t, anat_bones.left_foot == a_foot_l, "FOOT.L should bind to left_foot")
}

@(test)
test_collider_local_rotation_and_floor_flattening :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Create a tilted foot bone pitched downward 30 degrees
	foot_h := engine.transform_new("foot_l")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(foot_h))
	testing.expect(t, ft != nil, "foot transform should exist")

	// 30 degree pitch down around X
	pitch_down := engine.quat_from_euler_xyz(30.0, 0.0, 0.0)
	ft.rotation = pitch_down

	// Compute flat floor rotation
	flat_q := crig.calculate_flat_floor_rotation(foot_h)
	testing.expect(t, flat_q != engine.QUAT_IDENTITY, "Tilted bone should produce non-identity leveling quaternion")

	// World orientation of collider = bone_rotation * flat_q
	cw_rot := engine.quat_to_native(ft.rotation) * engine.quat_to_native(flat_q)
	world_up := linalg.quaternion128_mul_vector3(cw_rot, [3]f32{0, 1, 0})

	// Up vector should now point vertically along world Y (0, 1, 0)
	testing.expect(t, abs(world_up.x) < 0.001, "Level collider world up X should be ~0")
	testing.expect(t, abs(world_up.y - 1.0) < 0.001, "Level collider world up Y should be ~1")
	testing.expect(t, abs(world_up.z) < 0.001, "Level collider world up Z should be ~0")

	// Add box collider with rotation
	crig.smart_collider_add_box(foot_h, size = {0.10, 0.08, 0.22}, center = {0, -0.04, 0.06}, rotation = flat_q)
	_, box := engine.transform_get_comp(foot_h, physics3d.BoxCollider)
	testing.expect(t, box != nil, "BoxCollider should be attached")
	testing.expect(t, box.rotation == flat_q, "BoxCollider rotation should match flat floor quaternion")
}

@(test)
test_custom_bone_addition_and_spring_bone_dynamics :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Create character actor
	actor_h := engine.transform_new("Character")
	engine.transform_set_world_position(actor_h, {0, 0, 0})

	// Add ArmatureDeformedMesh
	_, adm_raw := engine.transform_add_comp(actor_h, .ArmatureDeformedMesh)
	testing.expect(t, adm_raw != nil, "ArmatureDeformedMesh should be created")
	adm := cast(^crig.ArmatureDeformedMesh)adm_raw

	// Build skeleton hierarchy under actor
	armature_h := engine.transform_new("Armature", actor_h)
	pelvis_h := engine.transform_new("pelvis", armature_h)
	engine.transform_set_local_position(pelvis_h, {0, 0.95, 0})
	spine_h := engine.transform_new("spine", pelvis_h)
	engine.transform_set_local_position(spine_h, {0, 0.20, 0})
	chest_h := engine.transform_new("chest", spine_h)
	engine.transform_set_local_position(chest_h, {0, 0.25, 0})

	adm.root_bone = engine.Ref_Local{handle = engine.Handle(armature_h)}

	// 1. Test adding bilateral chest bones
	l_h, r_h, ok := crig.armature_add_bilateral_chest_bones(adm)
	testing.expect(t, ok, "armature_add_bilateral_chest_bones should succeed")
	testing.expect(t, l_h != {}, "breast_l transform should be created")
	testing.expect(t, r_h != {}, "breast_r transform should be created")

	// Verify custom joint names
	testing.expect(t, len(adm.custom_joint_names) == 2, "custom_joint_names should contain 2 bones")
	testing.expect(t, adm.custom_joint_names[0] == "breast_l", "First bone should be breast_l")
	testing.expect(t, adm.custom_joint_names[1] == "breast_r", "Second bone should be breast_r")

	// Verify SpringBone component attached to both
	_, l_sb := engine.transform_get_comp(l_h, crig.SpringBone)
	_, r_sb := engine.transform_get_comp(r_h, crig.SpringBone)
	testing.expect(t, l_sb != nil, "breast_l should have SpringBone component")
	testing.expect(t, r_sb != nil, "breast_r should have SpringBone component")
	testing.expect(t, l_sb.max_angle_deg == 28.0, "SpringBone max safety cone should default to 28 degrees for chest bones")

	// 2. Test SpringBone length invariant & safety cone
	// Step physics simulation
	crig.spring_bone_tick(0.016)
	testing.expect(t, l_sb.initialized, "SpringBone should be initialized on first tick")

	// Bone length invariant check
	base_pos := engine.transform_world_position(l_h)
	dist := linalg.vector_length(l_sb.current_tip_pos - base_pos)
	testing.expect(t, abs(dist - l_sb.bone_length) < 0.001, "SpringBone tip distance must strictly match bone_length invariant")

	// 3. Test removing custom bone
	rem_ok := crig.armature_remove_custom_bone(adm, l_h)
	testing.expect(t, rem_ok, "armature_remove_custom_bone should succeed")
	testing.expect(t, len(adm.custom_joint_names) == 1, "custom_joint_names should have 1 remaining bone")
	testing.expect(t, adm.custom_joint_names[0] == "breast_r", "Remaining bone should be breast_r")
}

@(test)
test_hand_pose_driver_calibration_and_dynamic_box_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	mesh_guid_raw, _ := uuid.read("ea8331b2-faec-4dcf-9a4b-e83c37f7ba6d")
	engine._register_asset("plugins/control_rig/assets/skeletons/UAL1_Standard.glb", mesh_guid_raw)
	defer engine.asset_db_shutdown()

	scene_root := engine.Transform_Handle(tc.scene.root.handle)
	actor := engine.transform_new("CharacterActor", scene_root)
	_, raw_adm := engine.transform_add_comp(actor, .ArmatureDeformedMesh)
	adm := cast(^crig.ArmatureDeformedMesh)raw_adm
	adm.mesh = engine.Asset_GUID(mesh_guid_raw)

	// Spawn UAL1_Standard.glb skeleton
	crig.armature_deformed_mesh_reset_bind_pose(adm)

	// Attach HandPoseDriver
	_, raw_hpd := engine.transform_add_comp(actor, .HandPoseDriver)
	hpd := cast(^crig.HandPoseDriver)raw_hpd
	testing.expect(t, hpd != nil, "HandPoseDriver should be created")
	hpd.mirror_hands = true

	// 1. Verify calibration on both Left and Right hands
	bound_ok := crig.hand_pose_driver_ensure_bound(hpd)
	testing.expect(t, bound_ok, "HandPoseDriver should bind and calibrate UAL1_Standard.glb hands")
	testing.expect(t, hpd.left_calib.bound, "Left hand should be calibrated")
	testing.expect(t, hpd.right_calib.bound, "Right hand should be calibrated")

	for d in 0 ..< 5 {
		for p in 0 ..< 3 {
			testing.expect(t, hpd.left_calib.phalanges[d][p] != {}, "Left hand phalanx should be bound")
			testing.expect(t, hpd.right_calib.phalanges[d][p] != {}, "Right hand phalanx should be bound")
		}
	}

	// Measure rest bone length of left and right index proximal phalanx (index_01 -> index_02)
	idx01_l := hpd.left_calib.phalanges[1][0]
	idx02_l := hpd.left_calib.phalanges[1][1]
	idx03_l := hpd.left_calib.phalanges[1][2]
	rest_len_l := linalg.distance(engine.transform_world_position(idx01_l), engine.transform_world_position(idx02_l))
	testing.expect(t, rest_len_l > 0.015, "Index proximal phalanx should have non-zero rest length")

	// 2. Apply Open_Palm preset and evaluate
	crig.hand_side_apply_preset(&hpd.left, .Open_Palm)
	crig.hand_pose_driver_evaluate(hpd, 0.0)

	_, l_box := engine.transform_get_comp(hpd.left_calib.hand_bone, physics3d.BoxCollider)
	_, r_box := engine.transform_get_comp(hpd.right_calib.hand_bone, physics3d.BoxCollider)
	testing.expect(t, l_box != nil, "Left hand should have dynamic BoxCollider attached")
	testing.expect(t, r_box != nil, "Right hand should have dynamic BoxCollider attached")

	open_size_l := l_box.size
	open_tip_dist_l := linalg.distance(
		engine.transform_world_position(hpd.left_calib.hand_bone),
		engine.transform_world_position(idx03_l),
	)

	// 3. Apply Fist preset and evaluate
	crig.hand_side_apply_preset(&hpd.left, .Fist)
	crig.hand_pose_driver_evaluate(hpd, 0.0)

	fist_size_l := l_box.size
	fist_tip_dist_l := linalg.distance(
		engine.transform_world_position(hpd.left_calib.hand_bone),
		engine.transform_world_position(idx03_l),
	)

	// Verify bone length invariance during curl
	curled_len_l := linalg.distance(engine.transform_world_position(idx01_l), engine.transform_world_position(idx02_l))
	testing.expect(t, abs(curled_len_l - rest_len_l) < 0.0005, "Finger phalanx bone length must remain strictly constant when curled into Fist")

	// Verify fingers curled closer to wrist in Fist than in Open_Palm
	testing.expect(t, fist_tip_dist_l < open_tip_dist_l * 0.80, "Fist should curl fingertip significantly closer to wrist than Open_Palm")

	// Verify Left/Right symmetry in Fist
	idx03_r := hpd.right_calib.phalanges[1][2]
	fist_tip_dist_r := linalg.distance(
		engine.transform_world_position(hpd.right_calib.hand_bone),
		engine.transform_world_position(idx03_r),
	)
	testing.expect(t, abs(fist_tip_dist_l - fist_tip_dist_r) < 0.003, "Left and Right hands must curl symmetrically into Fist")

	// 4. Verify Dynamic BoxCollider morphed between Open_Palm and Fist
	// Distal length of Open_Palm (0.185m) is much longer than Fist (0.095m)
	open_vol := open_size_l.x * open_size_l.y * open_size_l.z
	fist_vol := fist_size_l.x * fist_size_l.y * fist_size_l.z
	testing.expect(t, open_size_l != fist_size_l, "Dynamic Hand BoxCollider size must morph between Open_Palm and Fist")
	testing.expect(t, open_vol != fist_vol, "Dynamic Hand BoxCollider volume must change between Open_Palm and Fist")

	// 5. Verify smooth runtime pose & BoxCollider blending (Fist -> Open_Palm at 50%)
	crig.hand_side_blend_to_profile(&hpd.left, crig.hand_pose_preset_get(.Open_Palm), 1.0)
	crig.hand_pose_driver_evaluate(hpd, 0.5) // Step 0.5s (50% blend)
	mid_size_l := l_box.size
	testing.expect(t, mid_size_l.y > fist_size_l.y && mid_size_l.y < open_size_l.y, "Blended Hand BoxCollider distal length at 50% must lie strictly between Fist and Open_Palm")

	// 6. Verify Master Curl and Master Claw COMBO without overriding each other!
	crig.hand_side_apply_preset(&hpd.left, .Open_Palm)
	crig.hand_side_set_master_curl(&hpd.left, 0.50)
	curl_only_idx := hpd.left.pose.index_finger.xyz
	crig.hand_side_set_master_claw(&hpd.left, 0.40)
	combo_idx := hpd.left.pose.index_finger.xyz
	testing.expect(t, abs(hpd.left.master_curl - 0.50) < 0.001, "Master Claw must NOT overwrite Master Curl")
	testing.expect(t, combo_idx.x < curl_only_idx.x, "Adding Master Claw on top of Master Curl must extend the Base MCP knuckle backward")
	testing.expect(t, combo_idx.y > curl_only_idx.y && combo_idx.z > curl_only_idx.z, "Adding Master Claw on top of Master Curl must further hook Mid PIP and Tip DIP knuckles")

	// 7. Verify Dynamic Folder-Driven Pose Library seeds and scans flat binary .mhpose files (188 bytes each)
	testing.expect_value(t, size_of(crig.Hand_Pose_Binary_Record), 188)
	folder_entries := crig.hand_pose_scan_folder(crig.HAND_POSES_DIR, context.temp_allocator)
	testing.expect(t, len(folder_entries) >= 8, "Dynamic hand pose folder should auto-seed and scan at least 8 .mhpose binary files")
	if len(folder_entries) > 0 {
		loaded_prof, lok := crig.hand_pose_profile_load_from_disk(folder_entries[0].full_path)
		testing.expect(t, lok, "Flat binary .mhpose file should load via direct pointer cast")
		testing.expect(t, loaded_prof.index_finger == folder_entries[0].profile.index_finger, "Round-trip binary .mhpose finger vector must match")
		testing.expect(t, loaded_prof.collider_size == folder_entries[0].profile.collider_size, "Round-trip binary .mhpose collider size must match")
	}
}

@(test)
test_control_rig_editor_contour_ring_handles_and_gizmo_tool_sync :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Verify Gizmo Tool Request / Consume synchronization bridge
	_, had_initial := crig_editor.consume_requested_gizmo_tool()
	_ = had_initial
	crig_editor.request_gizmo_tool(.Handles)
	testing.expect_value(t, crig_editor.current_gizmo_tool, handles.Tool.Handles)
	consumed, ok := crig_editor.consume_requested_gizmo_tool()
	testing.expect(t, ok && consumed == .Handles, "consume_requested_gizmo_tool must return requested .Handles once")
	_, ok_second := crig_editor.consume_requested_gizmo_tool()
	testing.expect(t, !ok_second, "Second consume without a new request must report false")
	crig_editor.request_gizmo_tool(.Translate)
	_, _ = crig_editor.consume_requested_gizmo_tool()

	// 2. Verify Left_Toe and Right_Toe rocker controls are first-class selectable channels
	actor_h := engine.transform_new("RigTestActor")
	crig_editor.select_rig_control(actor_h, .Left_Toe, false)
	testing.expect(t, crig_editor.is_rig_control_selected(actor_h, .Left_Toe), "Left_Toe must be selectable in Rig_Controls mode")
	crig_editor.select_rig_control(actor_h, .Right_Toe, true)
	testing.expect(t, card(crig_editor.selected_rig_controls) == 2, "Multi-selecting Left_Toe + Right_Toe must track 2 controls")
	crig_editor.clear_rig_selection()
	testing.expect_value(t, card(crig_editor.selected_rig_controls), 0)

	// 3. Verify 3D Contour Ring handle hit-testing & drag via handles.ring + handles.merge_drag
	_Ring_Drag_Case :: struct {
		started: bool,
		merged:  handles.Drag,
	}
	_ring_body :: proc(user: rawptr) {
		c := cast(^_Ring_Drag_Case)user
		d := handles.ring(0xC0FFEE_12, {0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 0.80, {0, 0, 1})
		if d.started do c.started = true
		if d.dragging || d.released do handles.merge_drag(&c.merged, d)
	}

	rc: _Ring_Drag_Case
	// Click directly on the 3D ring rim at (+0.80, 0, 0) — NOT the hollow center! — and drag to (+1.30, +0.25, 0)
	common.handles_drag(common.handles_test_view(), {0.80, 0.0, 0.0}, {1.30, 0.25, 0.0}, _ring_body, &rc)
	testing.expect(t, rc.started, "Clicking anywhere along the 3D ring rim must start the contour handle drag")
	testing.expect(t, rc.merged.released, "Releasing the ring contour drag must report released")
	testing.expect(t, linalg.length(rc.merged.delta - [3]f32{0.50, 0.25, 0.0}) < 1e-3,
		"Screen-plane contour drag on 3D ring rim must track exact world delta")
}



