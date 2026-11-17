package stress_tests

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import cs "haati:editor/code_studio"
import vs "haati:editor/visual_script"
import engine "haati:engine"
import cad_csg "haati:packages/cad_csg"
import physics3d "haati:packages/physics3d"
import common "haati:tests/common"

@(private = "file")
vec3_finite :: proc(v: [3]f32) -> bool {
	return !math.is_nan(v.x) && !math.is_inf(v.x) &&
	       !math.is_nan(v.y) && !math.is_inf(v.y) &&
	       !math.is_nan(v.z) && !math.is_inf(v.z)
}

// 1. High-churn Jolt physics + CSG soak test:
//    8 waves x 30 fixed steps (240 ticks) destroying/spawning mixed dynamic colliders
//    (Box/Sphere/Capsule), Hinge PhysicsJoint3D pendulums, CharacterController3D movers,
//    masked raycasts, glass shattering, CSG blast carving, and crater resets.
@(test)
stress_jolt_csg_and_entity_churn_soak :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)

	vol_h := engine.transform_new("Stress_CSG_Arena", root_h)
	_, vol_ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)vol_ptr
	testing.expect(t, vol != nil, "CSGVolume component must be created")
	if vol == nil do return
	cad_csg.reset_CSGVolume(vol)

	cad_csg.csg_volume_add_brush(vol, "Floor", .Add, .Box, {0, -0.5, -2.0}, {24.0, 1.0, 20.0}, 0, {130, 135, 145, 255}, destructible = false, anchored = true)
	cad_csg.csg_volume_add_brush(vol, "Front_Wall", .Add, .Box, {0, 2.0, 0.0}, {14.0, 4.0, 0.8}, 0, {185, 190, 200, 255}, destructible = true, anchored = false)
	cad_csg.csg_volume_add_brush(vol, "Window_Cut", .Subtract, .Box, {0, 2.0, 0.0}, {2.6, 1.8, 1.6}, 0, {90, 90, 90, 255}, destructible = true, anchored = false)
	cad_csg.csg_volume_add_brush(vol, "Backstop_Wall", .Add, .Box, {0, 2.0, -5.0}, {14.0, 4.0, 0.8}, 0, {175, 180, 190, 255}, destructible = true, anchored = false)

	added_pillars := cad_csg.csg_volume_add_detail_wall_array(
		vol, "Stress_Pillar", .Gothic_Pillar,
		{0, 1.8, 0.42}, {0, 0, 1}, {1, 0, 0},
		6, 2.0,
	)
	testing.expect(t, added_pillars == 6, "expected 6 stamped pillars along stress CSG wall")

	cad_csg.csg_volume_rebuild(vol)

	dt :: f32(1.0 / 60.0)
	live_handles := make([dynamic]engine.Transform_Handle, 0, 32)
	defer delete(live_handles)

	total_ticks := 0
	for wave in 0 ..< 8 {
		for h in live_handles {
			engine.transform_destroy(h)
		}
		clear(&live_handles)
		free_all(context.temp_allocator)

		if (wave % 2) == 1 {
			cad_csg.csg_volume_reset_craters(vol)
		}
		if len(vol.glass_panes) == 0 {
			_ = cad_csg.csg_volume_add_glass_pane(vol, "Stress_Glass", {0, 2.0, 0.0}, {2.6, 1.8}, {0, 0, 1}, 5, 4)
			cad_csg.csg_volume_rebuild(vol)
		}

		// Spawn 20 mixed dynamic Rigidbodies across Box, Sphere, and Capsule colliders
		for idx in 0 ..< 20 {
			name := fmt.tprintf("Churn_Body_%d_%d", wave, idx)
			h := engine.transform_new(name, root_h)
			x := f32(idx % 5) * 1.4 - 2.8
			y := f32(3.0 + f32(idx / 5) * 1.2)
			z := f32(-2.0 + f32(idx % 3) * 0.9)
			engine.transform_set_world_position(h, {x, y, z})

			_, rb_ptr := engine.transform_add_comp(h, .Rigidbody)
			rb := cast(^physics3d.Rigidbody)rb_ptr
			rb.enabled = true
			rb.use_gravity = true

			switch idx % 3 {
			case 0:
				_, c_ptr := engine.transform_add_comp(h, .BoxCollider)
				bc := cast(^physics3d.BoxCollider)c_ptr
				bc.enabled = true
				bc.size = {0.5, 0.5, 0.5}
				bc.density = 1.0
				bc.friction = 0.5
			case 1:
				_, c_ptr := engine.transform_add_comp(h, .SphereCollider)
				sc := cast(^physics3d.SphereCollider)c_ptr
				sc.enabled = true
				sc.radius = 0.35
				sc.density = 1.0
				sc.friction = 0.4
			case 2:
				_, c_ptr := engine.transform_add_comp(h, .CapsuleCollider)
				cc := cast(^physics3d.CapsuleCollider)c_ptr
				cc.enabled = true
				cc.radius = 0.3
				cc.height = 1.1
				cc.direction = .Y_Axis
				cc.density = 1.0
				cc.friction = 0.5
			}
			append(&live_handles, h)
		}

		// Spawn 2 Hinge Joint pendulums (anchor + pendulum)
		for j in 0 ..< 2 {
			anchor_h := engine.transform_new(fmt.tprintf("Churn_Anchor_%d_%d", wave, j), root_h)
			ax := -4.0 + f32(j) * 8.0
			engine.transform_set_world_position(anchor_h, {ax, 5.5, -2.5})
			_, a_rb_ptr := engine.transform_add_comp(anchor_h, .Rigidbody)
			a_rb := cast(^physics3d.Rigidbody)a_rb_ptr
			a_rb.enabled = true
			a_rb.is_kinematic = true
			_, a_col_ptr := engine.transform_add_comp(anchor_h, .BoxCollider)
			a_col := cast(^physics3d.BoxCollider)a_col_ptr
			a_col.enabled = true
			a_col.size = {0.6, 0.6, 0.6}

			pend_h := engine.transform_new(fmt.tprintf("Churn_Pendulum_%d_%d", wave, j), root_h)
			engine.transform_set_world_position(pend_h, {ax + 0.8, 4.5, -2.5})
			_, p_rb_ptr := engine.transform_add_comp(pend_h, .Rigidbody)
			p_rb := cast(^physics3d.Rigidbody)p_rb_ptr
			p_rb.enabled = true
			p_rb.use_gravity = true
			_, p_col_ptr := engine.transform_add_comp(pend_h, .BoxCollider)
			p_col := cast(^physics3d.BoxCollider)p_col_ptr
			p_col.enabled = true
			p_col.size = {0.4, 1.2, 0.4}
			_, jnt_ptr := engine.transform_add_comp(pend_h, .PhysicsJoint3D)
			jnt := cast(^physics3d.PhysicsJoint3D)jnt_ptr
			jnt.enabled = true
			jnt.kind = .Hinge
			jnt.connected_body = engine.Ref{handle = engine.Handle(anchor_h)}

			append(&live_handles, anchor_h, pend_h)
		}

		// Spawn 2 CharacterController3D walkers
		for c in 0 ..< 2 {
			ch_h := engine.transform_new(fmt.tprintf("Churn_Char_%d_%d", wave, c), root_h)
			engine.transform_set_world_position(ch_h, {-3.5 + f32(c) * 7.0, 1.2, 3.0})
			_, cc_ptr := engine.transform_add_comp(ch_h, .CharacterController3D)
			cc := cast(^physics3d.CharacterController3D)cc_ptr
			cc.enabled = true
			cc.desired_velocity = {f32(c == 0 ? 1.5 : -1.5), 0, -1.0}
			append(&live_handles, ch_h)
		}

		for tick in 0 ..< 30 {
			cad_csg.csg_fixed_step(dt)
			physics3d.physics_step(dt)
			total_ticks += 1

			if tick == 8 {
				_, _ = physics3d.raycast_masked({0, 2.0, 3.0}, {0, 0, -1}, 20.0, physics3d.MASK_WEAPON_TRACE)
				_, _ = physics3d.raycast_masked({0, 2.0, 3.0}, {0, 0, -1}, 20.0, physics3d.MASK_VISION_LOS)
				_ = cad_csg.csg_damage_glass_at_point({0, 2.0, 0.0}, 1.25, 10.0)
			}
			if tick == 16 {
				bx := -3.0 + f32(wave % 3) * 3.0
				cad_csg.csg_trigger_blast({bx, 1.8, 0.0}, 1.4, 10.0)
			}
		}

		for h in live_handles {
			pos := engine.transform_world_position(h)
			testing.expectf(t, vec3_finite(pos), "entity position became non-finite on wave %d: %v", wave, pos)
		}
	}

	for h in live_handles {
		engine.transform_destroy(h)
	}
	clear(&live_handles)
	free_all(context.temp_allocator)
	testing.expect_value(t, total_ticks, 240)
}

// 2. Deterministic mutation fuzzing against `HTSCN001` binary scene parser and
//    Code Studio's in-RAM Odin AST / scratch / call-site parsers.
@(test)
stress_fuzz_htscn001_binary_scene_and_odin_ast_parsers :: proc(t: ^testing.T) {
	rng_state := rand.create(0xC0FFEE_2026)
	rng := rand.default_random_generator(&rng_state)

	// Part A: HTSCN001 Binary Scene Fuzzer (500 rounds)
	prefab_id, _ := uuid.read("22222222-3333-4444-8555-666666666666")
	prefab_guid := engine.Asset_GUID(prefab_id)

	sf: engine.SceneFile
	sf.schema_version = engine.SCENE_SCHEMA_VERSION
	sf.root = 10

	tr := engine.Transform{
		local_id     = 10,
		name         = strings.clone("StressFuzzRoot"),
		is_active    = true,
		position     = {1, 2, 3},
		rotation     = {0, 0, 0, 1},
		scale        = {1, 1, 1},
		render_layer = 1,
	}
	append(&tr.components, engine.Owned{local_id = 30})
	append(&sf.transforms, tr)

	comp_obj := make(json.Object)
	comp_obj[strings.clone("__type")] = json.String(strings.clone("9f36ee91-34b6-4636-a360-ee872af0436b"))
	comp_base := make(json.Object)
	comp_base[strings.clone("local_id")] = json.Integer(30)
	comp_obj[strings.clone("base")] = comp_base
	comp_obj[strings.clone("power")] = json.Float(7.5)
	append(&sf.components, comp_obj)

	ns := engine.NestedScene{
		local_id           = 50,
		local_id_in_parent = 50,
		source_prefab      = prefab_guid,
		transform_parent   = 10,
		sibling_index      = 0,
	}
	append(&ns.overrides, engine.Override{
		target        = engine.PPtr{guid = prefab_guid, local_id = 99},
		property_path = strings.clone("hp"),
		value         = json.Integer(250),
	})
	append(&sf.nested_scenes, ns)
	append(&sf.breadcrumbs, engine.Breadcrumb{
		local_id       = 70,
		scene_source   = engine.PPtr{guid = prefab_guid, local_id = 99},
		scene_instance = 50,
	})
	defer engine.scene_file_destroy(&sf)

	bin, bok := engine.scene_binary_encode(&sf)
	testing.expect(t, bok && len(bin) > engine.SCENE_BINARY_HEADER_SIZE, "seed scene_binary_encode must succeed")
	if !bok do return
	defer delete(bin)

	sum_off_u, _ := endian.get_u32(bin[20:24], .Little)
	sum_len_u, _ := endian.get_u32(bin[24:28], .Little)
	payload_off := int(sum_off_u) + int(sum_len_u)
	testing.expect(t, payload_off < len(bin), "seed binary scene must contain a non-empty payload")

	for round in 0 ..< 500 {
		free_all(context.temp_allocator)

		mut: []byte
		switch round % 4 {
		case 0:
			// Truncation fuzzing across header + payload boundaries
			cut := int(rand.uint64(rng) % u64(len(bin)))
			mut = make([]byte, cut, context.temp_allocator)
			copy(mut, bin[:cut])
		case 1:
			// Corrupt header bytes while keeping magic prefix intermittently
			mut = make([]byte, len(bin), context.temp_allocator)
			copy(mut, bin)
			flips := 1 + int(rand.uint64(rng) % 6)
			for _ in 0 ..< flips {
				pos := int(rand.uint64(rng) % u64(len(mut)))
				mut[pos] ~= u8(1 + (rand.uint64(rng) % 255))
			}
		case 2:
			// Payload bit-flip after summary keeping HTSCN001 header intact: CRC32 guard MUST reject unmarshal!
			mut = make([]byte, len(bin), context.temp_allocator)
			copy(mut, bin)
			if payload_off < len(mut) {
				span := len(mut) - payload_off
				pos := payload_off + int(rand.uint64(rng) % u64(span))
				mut[pos] ~= u8(1 + (rand.uint64(rng) % 254))

				dec_crc: engine.SceneFile
				uerr := engine.scene_file_unmarshal(mut, &dec_crc)
				engine.scene_file_destroy(&dec_crc)
				testing.expect(t, uerr != nil, "CRC32 guard must reject corrupted HTSCN001 payload")
			}
		case 3:
			// Pure random noise buffer
			nlen := int(rand.uint64(rng) % 512)
			mut = make([]byte, nlen, context.temp_allocator)
			for i in 0 ..< nlen {
				mut[i] = u8(rand.uint64(rng) & 0xFF)
			}
		}

		_, _ = engine.scene_extract_summary(mut, context.temp_allocator)
		dec: engine.SceneFile
		_ = engine.scene_file_unmarshal(mut, &dec)
		engine.scene_file_destroy(&dec)
	}

	// Part B: Odin AST / Scratch / Call-Site Parser Fuzzer (400 rounds)
	orig_alloc := context.allocator
	corpus := [?]string{
		"package fuzz\ntarget_fn :: proc(a: int, b: f32) -> (ok: bool) {\n\tfor i in 0 ..< 10 {\n\t\tif a > 0 { target_fn(i, 1.0) }\n\t}\n\treturn true\n}\n",
		"package fuzz\ntarget_fn :: proc(x: ^u8, s: string = `unterminated raw\n{\n\t// comment target_fn()\n\t/* nested /* target_fn() */ still comment */\n",
		":: target_fn :: proc(a: [dynamic]f32, z: string) -> int { return len(z) }",
		"health : f32 = 100.0; pos := [3]f32{1, 2, 3}; target_fn(1, \"quoted string\")",
		"for i in ",
		"if ((((((a + b",
		"/// Ünicode comment €漢字\n@(bp_node)\ntarget_fn :: proc(d: u8, s: string) -> bool { return true }",
	}

	for round in 0 ..< 400 {
		free_all(context.temp_allocator)
		base := corpus[round % len(corpus)]

		// Cut at arbitrary byte boundary (including mid-UTF-8 sequences and mid-tokens)
		raw_cut := int(rand.uint64(rng) % u64(len(base) + 1))
		mut_buf := make([]byte, raw_cut + 8, context.temp_allocator)
		copy(mut_buf[:raw_cut], base[:raw_cut])
		for k in 0 ..< 4 {
			mut_buf[raw_cut + k] = u8(0x80 + (rand.uint64(rng) % 64))
		}
		if raw_cut > 4 && (round % 3) == 0 {
			flip_i := int(rand.uint64(rng) % u64(raw_cut))
			mut_buf[flip_i] = u8(rand.uint64(rng) % 128)
		}
		mut_len := raw_cut + int(rand.uint64(rng) % 5)
		mut := string(mut_buf[:mut_len])

		_, _ = cs.check_odin_syntax_in_ram(mut, false, context.temp_allocator)
		_, _ = cs.check_odin_syntax_in_ram(mut, true, context.temp_allocator)
		_, _, _, _, _ = cs.parse_odin_proc_decl_header(mut, context.temp_allocator)
		_, _, _, _ = cs.analyze_odin_scratch_snippet(mut, context.temp_allocator)
		_ = cs.find_odin_proc_call_sites(mut, "fuzz.odin", "target_fn", context.temp_allocator)
		if sliced, ok := cs.extract_full_odin_procedure_decl(mut, "target_fn", context.temp_allocator); ok {
			cs.destroy_proc_full_decl_slice(&sliced, context.temp_allocator)
		}

		testing.expect(t, context.allocator.procedure == orig_alloc.procedure, "parser error path must preserve context.allocator")
	}
}

// 3. Rapid typing contention between UI thread and async checker + autocomplete worker threads,
//    wiping & poisoning `context.temp_allocator` immediately after each submission.
@(test)
stress_async_checker_and_autocomplete_rapid_typing_contention :: proc(t: ^testing.T) {
	cs.ensure_checker_started()
	cs.ensure_autocomplete_started()
	defer {
		cs.shutdown_checker()
		cs.shutdown_autocomplete()
		free_all(context.temp_allocator)
	}

	cs.set_problem_check_delay_sec(0.02)
	defer cs.set_problem_check_delay_sec(0.9)
	defer cs.set_checker_dirty_overlays(nil)

	pins := [?]cs.Scoped_Pin_Badge{
		{name = "delta_time", odin_type = "f32"},
		{name = "player_pos", odin_type = "[3]f32"},
		{name = "is_grounded", odin_type = "bool"},
	}

	for iter in 0 ..< 250 {
		ov_path := fmt.tprintf("C:/Haati_Stress_Tmp/dir_%d/ov_%d.bodin", iter % 8, iter)
		sub_path := fmt.tprintf("C:/Haati_Stress_Tmp/dir_%d/main_%d.bodin", iter % 8, iter)

		is_scoped := (iter % 2) == 0
		code := fmt.tprintf(
			"package hot_scripts\nimport \"core:math\"\nstep_%d :: proc(x: f32) -> f32 {\n\tv := math.sin(x) + delta_\n\treturn v\n}\n",
			iter,
		)
		ov_code := fmt.tprintf("package hot_scripts\nhelper_%d :: proc() -> int { return %d }\n", iter, iter)

		cs.set_checker_dirty_overlays([]cs.Dirty_File_Overlay{
			{abs_path = ov_path, code = ov_code, is_bodin = true},
		})
		cs.submit_async_check(code, is_scoped, "", false, sub_path)
		cs.submit_async_autocomplete_index(code, is_scoped, "")

		// Wipe and poison temp_allocator immediately: workers holding uncloned slices will corrupt/crash.
		free_all(context.temp_allocator)
		poison := make([]u8, 8192, context.temp_allocator)
		mem.set(raw_data(poison), 0xAA, len(poison))

		snap := cs.read_checker_snapshot(context.temp_allocator)
		testing.expect(t, utf8.valid_string(snap.summary_label), "checker summary_label must remain valid UTF-8 under contention")

		probe_src := fmt.tprintf("delta_%s", "t" if (iter % 2) == 0 else "")
		items, rep_start := cs.query_autocomplete_suggestions(probe_src, len(probe_src), pins[:], true, true, context.temp_allocator)
		testing.expect(t, rep_start >= 0 && rep_start <= len(probe_src), "replace_start must remain in bounds")
		_ = items

		if (iter % 25) == 0 {
			time.sleep(5 * time.Millisecond)
		}
	}
}

@(private = "file")
_Vault_Writer_Args :: struct {
	vh:      engine.Watchdog_Vault_Handle,
	tabs_a:  string,
	tabs_b:  string,
	scene_a: string,
	scene_b: string,
	stop:    bool,
}

@(private = "file")
_vault_writer_proc :: proc(t_ptr: ^thread.Thread) {
	// Isolated default context so worker never touches main thread Tracking_Allocator!
	context = runtime.default_context()
	args := cast(^_Vault_Writer_Args)t_ptr.data

	lids_a := [?]u64{101, 102}
	lids_b := [?]u64{201, 202, 203}

	snap_a := engine.Relaunch_SHM_Snapshot{
		has_scene_bytes = true,
		cam_pos         = {11.0, 2.0, 3.0},
		cam_yaw         = 11.0,
		selected_lids   = lids_a[:],
		scene_path      = "assets/stress_a.scene",
		scene_bytes     = transmute([]byte)args.scene_a,
	}
	snap_b := engine.Relaunch_SHM_Snapshot{
		has_scene_bytes = true,
		cam_pos         = {22.0, 4.0, 6.0},
		cam_yaw         = 22.0,
		selected_lids   = lids_b[:],
		scene_path      = "assets/stress_b.scene",
		scene_bytes     = transmute([]byte)args.scene_b,
	}

	step := 0
	for !intrinsics.atomic_load(&args.stop) {
		if (step % 2) == 0 {
			_ = engine.watchdog_vault_write(args.vh, snap_a, transmute([]byte)args.tabs_a)
		} else {
			_ = engine.watchdog_vault_write(args.vh, snap_b, transmute([]byte)args.tabs_b)
		}
		step += 1
		if (step % 8) == 0 {
			time.sleep(50 * time.Microsecond)
		}
	}
}

// 4. Visual Script smart 3-tier wire-remap + transpiler torture (120 steps) AND
//    concurrent Watchdog Kernel RAM Vault seqlock contention (writer thread vs 400 reader probes).
@(test)
stress_visual_script_wire_remap_transpile_and_vault_seqlock_contention :: proc(t: ^testing.T) {
	// Part A: Visual Script wire-remap + transpiler torture (120 steps)
	{
		g: engine.Visual_Graph
		engine.vg_init_default_demo_graph(&g, "stress_wire_remap")
		defer engine.vg_destroy_graph(&g)

		init_uid := g.nodes[0].uid
		math_uid := engine.vg_add_node(&g, .Math_Float, {40, 240}, "Math")
		fn_uid   := engine.vg_add_node(&g, .Odin_Function_Node, {280, 120}, "bobRoss")

		decls := [?]string{
			`bobRoss :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, val: f32, tag: string) -> (ok: bool) { return val > 0 }`,
			`bobRoss :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, power: f32, tag: string, boost: f32) -> (ok: bool, score: f32) { return power > 0, boost }`,
			`bobRoss :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, count: i32, active: bool) -> (ratio: f32) { return active ? f32(count) : 0 }`,
			`bobRoss :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, damage: u8, z: string, factor: f32) -> (ok: bool) { return damage > 0 && factor >= 0 }`,
		}

		for iter in 0 ..< 120 {
			free_all(context.temp_allocator)
			fn_n := engine.vg_find_node(&g, fn_uid)
			testing.expect(t, fn_n != nil, "Odin_Function_Node must remain present")
			if fn_n == nil do break

			ok, err_msg := vs.apply_full_odin_proc_to_node(&g, fn_n, decls[iter % len(decls)])
			testing.expectf(t, ok && err_msg == "", "apply_full_odin_proc_to_node failed at iter %d: %s", iter, err_msg)

			if (iter % 3) == 0 {
				append(&g.wires, engine.VG_Wire{from_uid = init_uid, from_pin = 0, to_uid = fn_uid, to_pin = 0})
				if len(fn_n.inputs) > 1 {
					append(&g.wires, engine.VG_Wire{from_uid = math_uid, from_pin = 0, to_uid = fn_uid, to_pin = 1})
				}
			}

			// Verify graph wire referential integrity after every remap!
			for w in g.wires {
				from_n := engine.vg_find_node(&g, w.from_uid)
				to_n   := engine.vg_find_node(&g, w.to_uid)
				testing.expect(t, from_n != nil && to_n != nil, "wire endpoints must reference live nodes")
				if from_n != nil && to_n != nil {
					testing.expect(t, w.from_pin >= 0 && w.from_pin < len(from_n.outputs), "wire from_pin out of bounds")
					testing.expect(t, w.to_pin >= 0 && w.to_pin < len(to_n.inputs), "wire to_pin out of bounds")
				}
			}

			odin_src, main_name := vs.transpile_graph_to_odin(&g, context.temp_allocator)
			testing.expect(t, len(odin_src) > 0 && len(main_name) > 0, "transpile_graph_to_odin must emit valid source")
		}
	}

	// Part B: Watchdog Vault Seqlock Contention (Windows)
	when ODIN_OS == .Windows {
		vault_name := fmt.aprintf("Local\\Haati_WD_Stress_%d", os.get_pid())
		defer delete(vault_name)
		vh, vok := engine.watchdog_vault_create(vault_name)
		testing.expect(t, vok && vh != nil, "watchdog_vault_create must succeed for seqlock stress")
		if !vok || vh == nil do return
		defer engine.watchdog_vault_close(vh)

		pad_a := strings.repeat("A", 8192)
		pad_b := strings.repeat("B", 12288)
		defer delete(pad_a)
		defer delete(pad_b)

		tabs_a := fmt.aprintf("[{\"path\":\"a.odin\",\"pad\":\"%s\"}]", pad_a)
		tabs_b := fmt.aprintf("[{\"path\":\"b.odin\",\"pad\":\"%s\"}]", pad_b)
		scene_a := fmt.aprintf("SCENE_A_%s", pad_a[:4096])
		scene_b := fmt.aprintf("SCENE_B_%s", pad_b[:6144])
		defer {
			delete(tabs_a)
			delete(tabs_b)
			delete(scene_a)
			delete(scene_b)
		}

		// Seed initial valid A state before starting reader probes
		seed_lids := [?]u64{101, 102}
		_ = engine.watchdog_vault_write(vh, engine.Relaunch_SHM_Snapshot{
			has_scene_bytes = true,
			cam_pos         = {11.0, 2.0, 3.0},
			cam_yaw         = 11.0,
			selected_lids   = seed_lids[:],
			scene_path      = "assets/stress_a.scene",
			scene_bytes     = transmute([]byte)scene_a,
		}, transmute([]byte)tabs_a)

		w_args := new(_Vault_Writer_Args, runtime.default_allocator())
		w_args^ = _Vault_Writer_Args{
			vh      = vh,
			tabs_a  = tabs_a,
			tabs_b  = tabs_b,
			scene_a = scene_a,
			scene_b = scene_b,
		}

		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		wt := thread.create(_vault_writer_proc)
		context.allocator = prev_alloc
		testing.expect(t, wt != nil, "writer thread must be created")
		if wt == nil {
			free(w_args, runtime.default_allocator())
			return
		}
		wt.data = w_args
		thread.start(wt)
		defer {
			intrinsics.atomic_store(&w_args.stop, true)
			thread.join(wt)
			prev := context.allocator
			context.allocator = runtime.default_allocator()
			thread.destroy(wt)
			context.allocator = prev
			free(w_args, runtime.default_allocator())
		}

		valid_meta_reads  := 0
		valid_tabs_reads  := 0
		valid_scene_reads := 0
		for _ in 0 ..< 400 {
			free_all(context.temp_allocator)
			rsnap, rtabs, rok := engine.watchdog_vault_read_and_consume(vault_name, context.temp_allocator)
			if rok {
				if rsnap.cam_yaw != 0 {
					is_a := rsnap.cam_pos.x == 11.0 && rsnap.cam_yaw == 11.0 && rsnap.scene_path == "assets/stress_a.scene" &&
					        len(rsnap.selected_lids) == 2 && rsnap.selected_lids[0] == 101 && rsnap.selected_lids[1] == 102
					is_b := rsnap.cam_pos.x == 22.0 && rsnap.cam_yaw == 22.0 && rsnap.scene_path == "assets/stress_b.scene" &&
					        len(rsnap.selected_lids) == 3 && rsnap.selected_lids[0] == 201 && rsnap.selected_lids[1] == 202 && rsnap.selected_lids[2] == 203
					testing.expect(t, is_a || is_b, "Zone 0 metadata tore across concurrent seqlock write!")
					valid_meta_reads += 1
				}
				if len(rtabs) > 0 {
					got_t := string(rtabs)
					testing.expect(t, got_t == tabs_a || got_t == tabs_b, "Zone 1 tabs_json tore across concurrent seqlock write!")
					valid_tabs_reads += 1
				}
				if rsnap.has_scene_bytes && len(rsnap.scene_bytes) > 0 {
					got_s := string(rsnap.scene_bytes)
					testing.expect(t, got_s == scene_a || got_s == scene_b, "Zone 2 scene_bytes tore across concurrent seqlock write!")
					valid_scene_reads += 1
				}
			}
			time.sleep(25 * time.Microsecond)
		}

		testing.expectf(
			t,
			valid_meta_reads > 10 && valid_tabs_reads > 10 && valid_scene_reads > 10,
			"expected >10 coherent reads per zone under contention (meta=%d tabs=%d scene=%d)",
			valid_meta_reads, valid_tabs_reads, valid_scene_reads,
		)
	}
}
