package tests

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:testing"

import "../engine"
import catalog "haati:engine/catalog"
import gfx "haati:engine/gfx"
import hot "haati:engine/hot_api"
import serialization "haati:engine/serialization"

// =============================================================================
// 1. Read-Only .pak VFS & Legacy Material JSON Read-Only Guard
// =============================================================================

@(test)
test_vfs_pak_mount_read_and_readonly_serialization :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	pid := os.get_pid()
	src_dir := fmt.tprintf("builds/_tmp_vfs_src_%d", pid)
	pak_file := fmt.tprintf("builds/_tmp_vfs_arch_%d.pak", pid)
	_remove_tree(src_dir)
	_ = os.remove(pak_file)
	defer _remove_tree(src_dir)
	defer _ = os.remove(pak_file)
	defer engine.vfs_unmount()

	mat_dir := fmt.tprintf("%s/assets/materials", src_dir)
	_ = os.make_directory_all(mat_dir)

	// Legacy empty `"texture": ""` forces `material_sanitize_legacy_json` during load;
	// mounted `.pak` read-only mode must prevent rewriting back to disk.
	mat_rel := "assets/materials/__tmp_mine_glow_vfs_test__.mat"
	mat_disk := fmt.tprintf("%s/%s", src_dir, mat_rel)
	mat_json := `{
  "__type_guid": "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4",
  "shader": 1,
  "texture": "",
  "color": [1.0, 1.0, 1.0, 1.0],
  "emission_color": [1.0, 0.25, 0.1],
  "emission_intensity": 6.0
}`
	testing.expect(t, os.write_entire_file(mat_disk, transmute([]u8)mat_json) == nil, "expected legacy .mat fixture write to succeed")

	cnt, pok := catalog.pak_pack_directory(src_dir, pak_file)
	testing.expect(t, pok && cnt == 1, "expected pak_pack_directory to pack 1 entry")

	// Delete loose staging files so loads can only come from the mounted `.pak`.
	_remove_tree(src_dir)
	testing.expect(t, !os.exists(mat_rel), "expected unextracted .mat path not to exist on disk")

	testing.expect(t, engine.vfs_mount_pak(pak_file), "expected vfs_mount_pak to succeed")
	testing.expect(t, engine.vfs_is_mounted(), "expected vfs_is_mounted == true")
	testing.expect(t, engine.vfs_has_file(".\\assets\\sub\\..\\materials\\__tmp_mine_glow_vfs_test__.mat"), "expected normalized path lookup in VFS")
	testing.expect(t, engine.vfs_exists(mat_rel), "expected vfs_exists true for mounted entry")

	raw_bytes, rerr := engine.vfs_read_entire_file(mat_rel)
	defer if raw_bytes != nil { delete(raw_bytes) }
	testing.expect(t, rerr == nil && len(raw_bytes) > 0, "expected vfs_read_entire_file to stream bytes from .pak")

	loaded_any, lok := serialization.load_from_file(mat_rel)
	testing.expect(t, lok && loaded_any.data != nil, "expected serialization.load_from_file to read sanitized JSON from VFS")
	if lok && loaded_any.data != nil {
		mat := cast(^engine.Material)loaded_any.data
		testing.expect_value(t, mat.shader, engine.Material_Shader.Lit)
		testing.expect(t, abs(mat.emission_intensity - 6.0) < 1e-4, "expected packed HDR emission_intensity == 6.0")
		engine.cleanup_Material(mat)
		free(loaded_any.data)
	}
	testing.expect(t, !os.exists(mat_rel), "expected read-only VFS to skip writing sanitized .mat back to disk")

	engine.vfs_unmount()
	testing.expect(t, !engine.vfs_is_mounted(), "expected vfs_is_mounted == false after vfs_unmount")
}

// =============================================================================
// 2. SceneManager Slot Reuse & Loaded Count Across > MAX_SCENES Unloads
// =============================================================================

@(test)
test_scene_manager_slot_reuse_and_loaded_count :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	// Unload bootstrap setup scene so count starts cleanly at 0.
	engine.sm_scene_unload(tc.scene)
	testing.expect_value(t, engine.sm_loaded_scene_count(), 0)

	total_cycles := engine.MAX_SCENES + 40
	for _ in 0 ..< total_cycles {
		s := engine.scene_new(.Scene3D)
		engine.sm_scene_set_active(s)
		testing.expect_value(t, engine.sm_loaded_scene_count(), 1)
		engine.sm_scene_unload(s)
		testing.expect_value(t, engine.sm_loaded_scene_count(), 0)
	}

	s0 := engine.scene_new(.Scene3D)
	s1 := engine.scene_new(.Scene3D)
	s2 := engine.scene_new(.Scene3D)
	engine.sm_scene_set_active(s0)
	engine.sm_scene_set_active(s1)
	engine.sm_scene_set_active(s2)
	testing.expect_value(t, engine.sm_loaded_scene_count(), 3)

	engine.sm_scene_unload(s1)
	testing.expect_value(t, engine.sm_loaded_scene_count(), 2)

	s3 := engine.scene_new(.Scene3D)
	engine.sm_scene_set_active(s3)
	testing.expect_value(t, engine.sm_loaded_scene_count(), 3)

	engine.sm_scene_unload(s0)
	engine.sm_scene_unload(s2)
	engine.sm_scene_unload(s3)
	testing.expect_value(t, engine.sm_loaded_scene_count(), 0)
}

// =============================================================================
// 3. Helldivers 2 HDR Bloom Config, Emission Conversion & CCW Negative-Scale Check
// =============================================================================

@(test)
test_hdr_bloom_camera_backfill_and_cull_handedness :: proc(t: ^testing.T) {
	id_q := [4]f32{0, 0, 0, 1}
	m_pos := engine.trs_matrix({1, 2, 3}, id_q, {2, 2, 2})
	m_flip_1 := engine.trs_matrix({0, 0, 0}, id_q, {-1, 1, 1})
	m_flip_2 := engine.trs_matrix({0, 0, 0}, id_q, {-1, -1, 1})
	m_flip_3 := engine.trs_matrix({0, 0, 0}, id_q, {-1, -1, -1})

	testing.expect(t, !gfx.model_has_negative_scale(m_pos), "uniform positive scale must keep CCW backface cull")
	testing.expect(t, gfx.model_has_negative_scale(m_flip_1), "odd negative scale (1 axis) must flip handedness")
	testing.expect(t, !gfx.model_has_negative_scale(m_flip_2), "even negative scale (2 axes) preserves handedness")
	testing.expect(t, gfx.model_has_negative_scale(m_flip_3), "odd negative scale (3 axes) must flip handedness")

	packed := engine.material_pack_lit_emission({1.0, 0.5, 0.0}, 4.0)
	testing.expect(t, abs(packed.x - 4.0) < 1e-4, "expected red linear emission == intensity")
	testing.expect(t, packed.y > 0.5 && packed.y < 1.2, "expected gamma-decoded linear green channel * 4")
	testing.expect(t, abs(packed.z) < 1e-6, "expected zero blue channel")
	testing.expect(t, abs(packed.w - 4.0) < 1e-4, "expected .w to carry raw emission_intensity")

	cam: engine.Camera
	engine.on_validate_Camera(&cam)
	testing.expect_value(t, cam.bloom_enabled, true)
	testing.expect_value(t, cam.tonemap_enabled, true)
	testing.expect(t, abs(cam.exposure - 1.0) < 1e-4, "expected legacy exposure backfill == 1.0")
	testing.expect(t, abs(cam.bloom_threshold - 1.0) < 1e-4, "expected bloom_threshold == 1.0")
	testing.expect(t, abs(cam.bloom_intensity - 0.08) < 1e-4, "expected bloom_intensity == 0.08")
	testing.expect(t, abs(cam.bloom_scatter - 0.72) < 1e-4, "expected bloom_scatter == 0.72")

	pfx := engine.camera_post_fx_config(&cam)
	testing.expect_value(t, pfx.bloom_enabled, true)
	testing.expect(t, abs(pfx.bloom_scatter - 0.72) < 1e-4, "expected camera_post_fx_config scatter == 0.72")
}

// =============================================================================
// 4. Slow-Mo & Framerate-Invariant Analytical Springs and Damping
// =============================================================================

@(private = "file")
_integrate_spring :: proc(steps: int, dt: f32) -> [3]f32 {
	val := [3]f32{3.0, -2.0, 1.5}
	vel := [3]f32{0.0, 0.0, 0.0}
	for _ in 0 ..< steps {
		hot.spring_vec3_critically_damped(&val, &vel, {0, 0, 0}, 8.0, dt)
	}
	return val
}

@(test)
test_slowmo_spring_and_damping_dt_invariance :: proc(t: ^testing.T) {
	// Same 1.0 simulated second across 240Hz, 60Hz, 15Hz, and 0.1x slow-mo (10 real s).
	p_240 := _integrate_spring(240, 1.0 / 240.0)
	p_60  := _integrate_spring(60, 1.0 / 60.0)
	p_15  := _integrate_spring(15, 1.0 / 15.0)
	p_slomo := _integrate_spring(2400, (1.0 / 240.0) * 0.1)

	testing.expect(t, linalg.distance(p_240, p_60) < 1e-4, "critically damped spring must match between 240Hz and 60Hz")
	testing.expect(t, linalg.distance(p_240, p_15) < 1e-4, "critically damped spring must match between 240Hz and 15Hz")
	testing.expect(t, linalg.distance(p_240, p_slomo) < 1e-4, "critically damped spring must match under 0.1x slow-mo")

	v2_hi := [2]f32{10.0, -4.0}
	v2_lo := [2]f32{10.0, -4.0}
	for _ in 0 ..< 240 {
		v2_hi = hot.damp_vec2(v2_hi, {0, 0}, 5.0, 1.0 / 240.0)
	}
	for _ in 0 ..< 30 {
		v2_lo = hot.damp_vec2(v2_lo, {0, 0}, 5.0, 1.0 / 30.0)
	}
	testing.expect(t, linalg.distance(v2_hi, v2_lo) < 1e-4, "damp_vec2 must be dt-invariant between 240Hz and 30Hz")

	q_target := linalg.quaternion_angle_axis_f32(1.2, {0, 1, 0})
	q_hi := linalg.QUATERNIONF32_IDENTITY
	q_lo := linalg.QUATERNIONF32_IDENTITY
	for _ in 0 ..< 240 {
		q_hi = hot.damp_quat(q_hi, q_target, 6.0, 1.0 / 240.0)
	}
	for _ in 0 ..< 30 {
		q_lo = hot.damp_quat(q_lo, q_target, 6.0, 1.0 / 30.0)
	}
	dot := abs(q_hi.x * q_lo.x + q_hi.y * q_lo.y + q_hi.z * q_lo.z + q_hi.w * q_lo.w)
	testing.expect(t, dot > 0.9999, "damp_quat must match closely between 240Hz and 30Hz")
}

// =============================================================================
// 5. Two-Stage Tiled Jigsaw NavMesh, Destruction Quarantine & Agent Auto-Repath
// =============================================================================

@(private = "file")
_test_jigsaw_world: ^engine.World

@(private = "file")
_emit_quad_ccw :: proc(emit: engine.Nav_Geometry_Emit_Proc, user: rawptr, x0, z0, x1, z1: f32) {
	v00 := [3]f32{x0, 0, z0}
	v01 := [3]f32{x0, 0, z1}
	v11 := [3]f32{x1, 0, z1}
	v10 := [3]f32{x1, 0, z0}
	emit(user, v00, v01, v11)
	emit(user, v00, v11, v10)
}

@(private = "file")
_test_jigsaw_provider :: proc(
	w: ^engine.World,
	aabb_min, aabb_max: [3]f32,
	emit: engine.Nav_Geometry_Emit_Proc,
	emit_user: rawptr,
) {
	if w == nil || w != _test_jigsaw_world || emit == nil do return
	_ = aabb_min
	_ = aabb_max
	// Two jigsaw courtyards separated across the 16m tile border (`x = 16`) by two
	// parallel bridges (`z = 2..5` upper bridge, `z = 11..14` lower bridge).
	_emit_quad_ccw(emit, emit_user,  2,  2, 12, 14) // Left courtyard  (tile {0,0})
	_emit_quad_ccw(emit, emit_user, 20,  2, 30, 14) // Right courtyard (tile {1,0})
	_emit_quad_ccw(emit, emit_user, 12,  2, 20,  5) // Upper bridge spanning x=16
	_emit_quad_ccw(emit, emit_user, 12, 11, 20, 14) // Lower bridge spanning x=16
}

@(test)
test_tiled_jigsaw_navmesh_quarantine_and_agent_repath :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	engine.job_system_init()
	defer engine.job_system_shutdown()
	defer engine.nav_tiled_reset()

	engine.nav_register_geometry_provider(_test_jigsaw_provider)
	_test_jigsaw_world = &tc.world
	defer { _test_jigsaw_world = nil }

	baked := engine.nav_tiled_rebake_bounds_sync(&tc.world, {2, 0, 2}, {30, 0, 14}, agent_radius = 0.35)
	testing.expect(t, baked, "expected nav_tiled_rebake_bounds_sync to produce active stitched NavMesh")

	nm := engine.navmesh_get_active()
	testing.expect(t, nm != nil && len(nm.polys) > 0, "expected non-empty active tiled NavMesh")
	if nm == nil do return

	path, pok := engine.navmesh_find_path(nm, {5, 0, 4}, {27, 0, 4}, context.temp_allocator, agent_radius = 0.35)
	testing.expect(t, pok && len(path) >= 2, "expected stitched path across 16m tile border")

	ent := engine.transform_new("JigsawBot")
	engine.transform_set_world_position(ent, {5, 0, 4})
	_, agent_ptr := engine.transform_add_comp(ent, .NavMeshAgent)
	agent := cast(^engine.NavMeshAgent)agent_ptr
	agent.enabled = true
	agent.speed = 6.0

	testing.expect(t, engine.nav_agent_set_destination(&tc.world, ent, {27, 0, 4}), "expected initial NavMeshAgent destination")
	v0 := agent.nav_version
	testing.expect(t, v0 > 0, "expected NavMeshAgent to record initial nm.version")
	initial_via_upper := true
	for wp in agent.waypoints {
		if wp.z > 6.5 {
			initial_via_upper = false
			break
		}
	}
	testing.expect(t, initial_via_upper, "expected initial shortest route to cross upper bridge")

	// Blast craters upper bridge at (16, 0, 3.5) and quarantines overlapping tiles for 0.5s.
	engine.nav_quarantine_begin({13, -1, 1}, {19, 2, 6}, settle_sec = 0.5, blast_center = {16, 0, 3.5}, blast_radius = 2.0)
	testing.expect(t, nm.version > v0, "expected T0 blast sphere cut to immediately bump nm.version")
	testing.expect(t, engine.nav_is_tile_quarantined({0, 0}), "expected tile {0,0} quarantined")
	testing.expect(t, engine.nav_is_tile_quarantined({1, 0}), "expected tile {1,0} quarantined")

	// Still inside active destruction window: Fine rebakes must stay suppressed,
	// while agent detects nm.version mismatch and reroutes around crater via lower bridge.
	engine.nav_tiled_update(0.1)
	testing.expect(t, engine.nav_is_tile_quarantined({1, 0}), "expected quarantine to persist before settle_sec expires")

	engine.nav_agents_update(0.05)
	testing.expect_value(t, agent.nav_version, nm.version)
	testing.expect(t, len(agent.waypoints) >= 2, "expected agent to recompute detour waypoints around blast")
	routed_via_lower_bridge := false
	for wp in agent.waypoints {
		if wp.z > 9.5 {
			routed_via_lower_bridge = true
			break
		}
	}
	testing.expect(t, routed_via_lower_bridge, "expected cratered upper bridge to force detour across lower bridge (z > 9.5)")

	// Settle quarantine and flush queued Fine pass.
	engine.nav_tiled_update(0.5)
	engine.nav_tiled_flush_all()
	testing.expect(t, !engine.nav_is_tile_quarantined({0, 0}), "expected tile {0,0} quarantine cleared after settle")
	testing.expect(t, !engine.nav_is_tile_quarantined({1, 0}), "expected tile {1,0} quarantine cleared after settle")

	nm_after := engine.navmesh_get_active()
	testing.expect(t, nm_after != nil && len(nm_after.polys) > 0, "expected active NavMesh rebuilt after quarantine settles")
}
