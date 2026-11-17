package tests

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"

import "../engine"
import catalog "haati:engine/catalog"
import gfx "haati:engine/gfx"
import ow "haati:engine/overwatch_ipc"
import vs "haati:editor/visual_script"

// Out-of-process Overwatch shared-memory ring ABI locks.
#assert(size_of(ow.Overwatch_Frame_Sample) == 64)
#assert(size_of(ow.Overwatch_Event) == 256)

@(private = "file")
_parallel_write_worker :: proc(start_idx, end_idx: int, userdata: rawptr) {
	buf := (cast(^[]int)userdata)^
	for i in start_idx ..< end_idx {
		buf[i] = i * 3 + 7
	}
}

@(test)
test_multicore_job_system_parallel_for :: proc(t: ^testing.T) {
	engine.job_system_init()
	defer engine.job_system_shutdown()
	engine.job_system_reset_telemetry()

	N :: 1024
	data: [N]int
	slice_view := data[:]
	engine.job_parallel_for(N, 32, _parallel_write_worker, &slice_view)

	for i in 0 ..< N {
		testing.expect_value(t, data[i], i * 3 + 7)
	}
	snap := engine.job_system_telemetry()
	testing.expect(t, snap.total_jobs > 0, "expected job_parallel_for to dispatch jobs")
}

@(test)
test_csm_spot_shadows_and_draw_command_sorting :: proc(t: ^testing.T) {
	testing.expect_value(t, gfx.MAX_LIGHTS, 64)
	testing.expect_value(t, gfx.SHADOW_ATLAS_SIZE, 4096)
	testing.expect_value(t, gfx.SHADOW_TILE_SIZE, 1024)

	mats := gfx.shadow_compute_directional_csm({0, -1, 0}, {10, 5, -3})
	for m in mats {
		det := linalg.determinant(m)
		testing.expect(t, !math.is_nan(det) && !math.is_inf(det) && abs(det) > 1e-12, "CSM cascade matrix must be non-singular")
	}

	spot := gfx.shadow_compute_spot_matrix({0, 10, 0}, {0, -1, 0}, 0.85, 25.0)
	sdet := linalg.determinant(spot)
	testing.expect(t, !math.is_nan(sdet) && !math.is_inf(sdet) && abs(sdet) > 1e-12, "spot shadow matrix must be non-singular")

	// Prepare Draw_Quad + Draw_Mesh commands with shared material; meshes must sort before quads,
	// and front-to-back relative to camera position {0, 0, 0}.
	mat_a := [1]engine.Asset_GUID{{1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
	far_m := engine.Render_Command{
		variant = engine.Draw_Mesh{
			materials = mat_a[:],
			model     = matrix[4, 4]f32{
				1, 0, 0, 0,
				0, 1, 0, 0,
				0, 0, 1, -20,
				0, 0, 0, 1,
			},
		},
	}
	near_m := engine.Render_Command{
		variant = engine.Draw_Mesh{
			materials = mat_a[:],
			model     = matrix[4, 4]f32{
				1, 0, 0, 0,
				0, 1, 0, 0,
				0, 0, 1, -5,
				0, 0, 0, 1,
			},
		},
	}
	quad_hi := engine.Render_Command{
		key     = {20, 0, 0, 0},
		variant = engine.Draw_Quad{},
	}
	quad_lo := engine.Render_Command{
		key     = {10, 0, 0, 0},
		variant = engine.Draw_Quad{},
	}

	cmds := [4]engine.Render_Command{quad_hi, far_m, quad_lo, near_m}
	engine.render_sort_commands(cmds[:], {0, 0, 0})

	m0, ok0 := cmds[0].variant.(engine.Draw_Mesh)
	m1, ok1 := cmds[1].variant.(engine.Draw_Mesh)
	_, ok2 := cmds[2].variant.(engine.Draw_Quad)
	_, ok3 := cmds[3].variant.(engine.Draw_Quad)
	testing.expect(t, ok0 && ok1, "expected meshes to sort ahead of quads")
	testing.expect(t, ok2 && ok3, "expected quads to sort after meshes")
	if ok0 && ok1 {
		testing.expect(t, m0.model[2, 3] == -5 && m1.model[2, 3] == -20, "expected front-to-back mesh sorting")
	}
	testing.expect(t, cmds[2].key[0] == 10 && cmds[3].key[0] == 20, "expected back-to-front quad key order")
}

@(test)
test_soundscape_and_ai_bodin_transpiler :: proc(t: ^testing.T) {
	g := engine.Visual_Graph{
		name           = strings.clone("soundscape_ai_test"),
		domain         = .Audio_SoundScape,
		package_target = strings.clone("haati/hot_scripts"),
		next_uid       = 1,
	}
	defer engine.vg_destroy_graph(&g)
	engine.vg_ensure_default_spaces(&g)

	u_init := engine.vg_add_node(&g, .Event_Init, {0, 0})
	u_rand := engine.vg_add_node(&g, .Audio_Random_Container, {120, 120})
	u_mod  := engine.vg_add_node(&g, .Audio_Modulate_Pitch_Vol, {280, 120})
	u_bus  := engine.vg_add_node(&g, .Audio_Bus_Send, {280, 0}, "Ambience")
	u_play := engine.vg_add_node(&g, .Audio_Play_Spatial_3D, {520, 0}, "Footstep")
	u_move := engine.vg_add_node(&g, .AI_Find_Path_Move, {760, 0})
	u_arr  := engine.vg_add_node(&g, .AI_Check_Arrival, {760, 160})
	_ = u_arr

	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_bus,  to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_bus,  from_pin = 0, to_uid = u_play, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_rand, from_pin = 0, to_uid = u_mod,  to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_mod,  from_pin = 0, to_uid = u_play, to_pin = 2})
	append(&g.wires, engine.VG_Wire{from_uid = u_play, from_pin = 0, to_uid = u_move, to_pin = 0})

	odin_src, main_proc := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, main_proc != "", "expected non-empty transpiled entry name")
	testing.expect(t, len(odin_src) > 0 && strings.contains(odin_src, "soundscape_ai_test"), "expected generated Odin source")

	tmp_path := fmt.tprintf("builds/_tmp_soundscape_%d.bodin", os.get_pid())
	defer _ = os.remove(tmp_path)
	testing.expect(t, engine.vg_save_bodin_file(&g, tmp_path, odin_src), "expected vg_save_bodin_file to succeed")

	loaded: engine.Visual_Graph
	defer engine.vg_destroy_graph(&loaded)
	testing.expect(t, engine.vg_load_from_file(&loaded, tmp_path), "expected vg_load_from_file to parse .bodin")
	testing.expect_value(t, loaded.domain, engine.VG_Graph_Domain.Audio_SoundScape)
	testing.expect_value(t, len(loaded.nodes), len(g.nodes))
	testing.expect_value(t, len(loaded.wires), len(g.wires))
}

@(test)
test_pool_overflow_pointer_stability_and_free :: proc(t: ^testing.T) {
	p: engine.Pool([3]f32, 4)
	engine.pool_init(&p)
	defer engine.pool_free(&p)

	handles: [24]engine.Handle
	for i in 0 ..< 24 {
		h, ptr := engine.pool_create(&p)
		testing.expect(t, ptr != nil, "expected pool_create to overflow cleanly without panic")
		ptr^ = {f32(i), f32(i * 2), 1.0}
		handles[i] = h
	}
	testing.expect_value(t, p.count, 24)

	p0 := engine.pool_get(&p, handles[0])
	p3 := engine.pool_get(&p, handles[3])
	p19 := engine.pool_get(&p, handles[19])
	testing.expect(t, p0 != nil && p3 != nil && p19 != nil, "expected initial and overflow handles valid")

	// Grow further and confirm existing pointers remain invariant.
	extra: [8]engine.Handle
	for i in 0 ..< 8 {
		eh, ep := engine.pool_create(&p)
		ep^ = {99, f32(i), 0}
		extra[i] = eh
	}
	testing.expect(t, engine.pool_get(&p, handles[0]) == p0, "expected inline slot pointer stability")
	testing.expect(t, engine.pool_get(&p, handles[3]) == p3, "expected inline slot pointer stability")
	testing.expect(t, engine.pool_get(&p, handles[19]) == p19, "expected overflow slab pointer stability")
	testing.expect_value(t, p.count, 32)

	// Iterator visits every live slot across inline + overflow storage.
	visited := 0
	it := engine.pool_iterator(&p)
	for _, _ in engine.pool_next(&it) {
		visited += 1
	}
	testing.expect_value(t, visited, 32)

	// Destroy and re-create slots across both inline and overflow regions.
	for i in 0 ..< 6 {
		engine.pool_destroy(&p, handles[i * 3])
	}
	testing.expect_value(t, p.count, 26)
	for _ in 0 ..< 6 {
		nh, np := engine.pool_create(&p)
		testing.expect(t, engine.pool_valid(&p, nh) && np != nil, "expected recycled slot creation")
	}
	testing.expect_value(t, p.count, 32)

	for i in 0 ..< 8 {
		engine.pool_destroy(&p, extra[i])
	}
}

@(test)
test_scene_schema_migration_v1_to_v2 :: proc(t: ^testing.T) {
	defer engine.scene_migration_shutdown()

	legacy := transmute([]u8)string(`{"root": 42, "entities": []}`)
	migrated, from_ver, changed, ok := engine.scene_migrate_json_bytes(legacy, context.temp_allocator)
	testing.expect(t, ok, "expected v0->v2 migration to succeed")
	testing.expect_value(t, from_ver, 0)
	testing.expect(t, changed, "expected legacy scene to be rewritten")
	testing.expect(t, strings.contains(string(migrated), `"schema_version"`), "expected schema_version stamped")

	current := transmute([]u8)string(`{"schema_version": 2, "root": 42, "entities": []}`)
	same, cur_ver, cur_changed, cur_ok := engine.scene_migrate_json_bytes(current, context.temp_allocator)
	testing.expect(t, cur_ok, "expected v2 scene check to succeed")
	testing.expect_value(t, cur_ver, engine.SCENE_SCHEMA_VERSION)
	testing.expect(t, !cur_changed, "expected zero-copy fast path for current schema version")
	testing.expect_value(t, len(same), len(current))
}

@(test)
test_multicore_navmesh_astar_and_agent :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	engine.job_system_init()
	defer engine.job_system_shutdown()
	defer engine.navmesh_clear_active()

	// 2 flat walkable floor triangles forming a 10x10 square + 1 vertical wall triangle (rejected).
	verts := [6][3]f32{
		{0, 0, 0},
		{0, 0, 10},
		{10, 0, 0},
		{10, 0, 10},
		{0, 5, 0},
		{10, 5, 0},
	}
	indices := [9]u32{
		0, 1, 2, // walkable floor 0 (n.y = +1)
		2, 1, 3, // walkable floor 1 (n.y = +1)
		0, 4, 5, // vertical wall (n.y = 0, rejected)
	}

	nm, ok := engine.navmesh_bake_triangles(verts[:], indices[:], 45.0)
	testing.expect(t, ok, "expected navmesh_bake_triangles to succeed")
	testing.expect_value(t, len(nm.polys), 2)
	if len(nm.polys) == 2 {
		has_link_0 := nm.polys[0].neighbors[0] == 1 || nm.polys[0].neighbors[1] == 1 || nm.polys[0].neighbors[2] == 1
		has_link_1 := nm.polys[1].neighbors[0] == 0 || nm.polys[1].neighbors[1] == 0 || nm.polys[1].neighbors[2] == 0
		testing.expect(t, has_link_0 && has_link_1, "expected adjacent floor triangles to share edge neighbor")
	}

	path, pok := engine.navmesh_find_path(&nm, {1, 0, 1}, {9, 0, 9}, context.temp_allocator)
	testing.expect(t, pok && len(path) >= 2, "expected A* path across floor corridor")

	engine.navmesh_set_active(nm)

	ent := engine.transform_new("Guard")
	engine.transform_set_world_position(ent, {1, 0, 1})
	_, agent_ptr := engine.transform_add_comp(ent, .NavMeshAgent)
	agent := cast(^engine.NavMeshAgent)agent_ptr
	agent.enabled = true
	agent.speed = 20.0
	agent.stopping_distance = 0.3

	testing.expect(t, engine.nav_agent_set_destination(&tc.world, ent, {9, 0, 9}), "expected destination assignment to succeed")
	for _ in 0 ..< 40 {
		engine.nav_agents_update(0.05)
	}
	testing.expect(t, engine.nav_agent_has_arrived(&tc.world, ent), "expected NavMeshAgent to arrive at destination")
	final_pos := engine.transform_world(ent).position
	testing.expect(t, linalg.distance(final_pos, [3]f32{9, 0, 9}) <= 0.5, "expected agent near goal")
}

@(test)
test_mhpak001_archive_roundtrip :: proc(t: ^testing.T) {
	pid := os.get_pid()
	src_dir  := fmt.tprintf("builds/_tmp_pak_src_%d", pid)
	dst_dir  := fmt.tprintf("builds/_tmp_pak_dst_%d", pid)
	pak_file := fmt.tprintf("builds/_tmp_pak_arch_%d.pak", pid)
	_remove_tree(src_dir)
	_remove_tree(dst_dir)
	_ = os.remove(pak_file)
	defer _remove_tree(src_dir)
	defer _remove_tree(dst_dir)
	defer _ = os.remove(pak_file)

	_ = os.make_directory_all(fmt.tprintf("%s/artifacts/ab", src_dir))
	cat_bytes  := transmute([]u8)string(`{"version": 1, "relocatable": true}`)
	blob_bytes := transmute([]u8)string("MHPAK001_BINARY_PAYLOAD_1234567890")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/catalog.json", src_dir), cat_bytes) == nil, "write catalog fixture")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/artifacts/ab/test_blob.bin", src_dir), blob_bytes) == nil, "write artifact fixture")

	cnt, pok := catalog.pak_pack_directory(src_dir, pak_file)
	testing.expect(t, pok, "expected pak_pack_directory to succeed")
	testing.expect_value(t, cnt, 2)

	ar, o_ok := catalog.pak_open(pak_file)
	testing.expect(t, o_ok, "expected pak_open to succeed")
	defer catalog.pak_close(&ar)

	read_blob, r_ok := catalog.pak_read_entry(&ar, "artifacts/ab/test_blob.bin", context.temp_allocator)
	testing.expect(t, r_ok, "expected pak_read_entry checksum verification to pass")
	testing.expect_value(t, string(read_blob), string(blob_bytes))

	testing.expect(t, catalog.pak_extract_directory(pak_file, dst_dir), "expected pak_extract_directory to succeed")
	ext_cat, cerr := os.read_entire_file(fmt.tprintf("%s/catalog.json", dst_dir), context.temp_allocator)
	ext_blob, berr := os.read_entire_file(fmt.tprintf("%s/artifacts/ab/test_blob.bin", dst_dir), context.temp_allocator)
	testing.expect(t, cerr == nil && string(ext_cat) == string(cat_bytes), "extracted catalog.json byte mismatch")
	testing.expect(t, berr == nil && string(ext_blob) == string(blob_bytes), "extracted blob byte mismatch")
}
