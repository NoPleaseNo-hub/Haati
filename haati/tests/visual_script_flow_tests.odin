package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../engine"
import cs "haati:editor/code_studio"
import nc "haati:editor/node_canvas"
import vs "haati:editor/visual_script"

// 1. Expanded Blueprint Variables (Vec4, Int64, String, Asset, Array [8]) `.bodin` Round-Trip,
//    Instance Overrides & Leak-Free Lifecycle
@(test)
test_v3_expanded_var_types_bodin_roundtrip_and_overrides :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	orig_alloc := context.allocator
	defer {
		for _, le in track.allocation_map {
			testing.expectf(t, false, "Memory leak in expanded var round-trip: %v bytes @ %v", le.size, le.location)
		}
		for bf in track.bad_free_array {
			testing.expectf(t, false, "Bad free in expanded var round-trip: %v", bf.location)
		}
	}

	tmp_dir, _ := os.temp_directory(context.temp_allocator)
	bodin_path, _ := filepath.join({tmp_dir, "mh_v3_vars_roundtrip.bodin"}, context.temp_allocator)
	defer os.remove(bodin_path)

	{
		context.allocator = mem.tracking_allocator(&track)
		g: engine.Visual_Graph
		g.name     = strings.clone("v3_vars_test")
		g.domain   = .Gameplay_Ability
		g.next_uid = 1
		engine.vg_ensure_default_spaces(&g)

		append(&g.variables, engine.VG_Var_Decl{
			name              = strings.clone("tint_color"),
			pin_type          = .Vec4,
			default_vec4      = {0.25, 0.50, 0.75, 1.0},
			instance_editable = true,
			category          = strings.clone("Visual"),
		})
		append(&g.variables, engine.VG_Var_Decl{
			name              = strings.clone("entity_uuid"),
			pin_type          = .Int64,
			default_i64       = 9876543210,
			instance_editable = true,
			category          = strings.clone("IDs"),
		})
		append(&g.variables, engine.VG_Var_Decl{
			name              = strings.clone("tag_label"),
			pin_type          = .String,
			default_str       = strings.clone("player_hero"),
			instance_editable = true,
			category          = strings.clone("Gameplay"),
		})
		append(&g.variables, engine.VG_Var_Decl{
			name              = strings.clone("mesh_path"),
			pin_type          = .Asset,
			default_str       = strings.clone("assets/meshes/hero.glb"),
			instance_editable = true,
			category          = strings.clone("Assets"),
		})
		append(&g.variables, engine.VG_Var_Decl{
			name              = strings.clone("weights"),
			pin_type          = .Float,
			is_array          = true,
			default_f32       = 1.5,
			instance_editable = false,
			category          = strings.clone("Arrays"),
		})

		odin_code, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
		testing.expect(t, strings.contains(odin_code, "weights: [8]f32,"), "expected fixed [8]f32 array field in Blueprint State")
		testing.expect(t, strings.contains(odin_code, "st.weights[0] = (cast(^f32)vp)^"), "expected C-ABI bounds-safe scalar element[0] load for array variable")

		saved := engine.vg_save_bodin_file(&g, bodin_path, odin_code)
		testing.expect(t, saved, "expected vg_save_bodin_file to succeed")
		engine.vg_destroy_graph(&g)

		g2: engine.Visual_Graph
		loaded := engine.vg_load_from_file(&g2, bodin_path)
		testing.expect(t, loaded, "expected vg_load_from_file on .bodin to succeed")
		testing.expect_value(t, len(g2.variables), 5)
		testing.expect_value(t, g2.variables[1].default_i64, i64(9876543210))
		testing.expect_value(t, g2.variables[2].default_str, "player_hero")
		testing.expect_value(t, g2.variables[3].default_str, "assets/meshes/hero.glb")
		testing.expect(t, g2.variables[4].is_array, "expected weights variable is_array == true after round-trip")

		bb: engine.VG_Runtime_Blackboard
		engine.vg_sync_blackboard(&g2, &bb)
		testing.expect_value(t, bb.slots[1].val_i64, i64(9876543210))
		testing.expect_value(t, string(bb.slots[2].val_cstr), "player_hero")

		ov := engine.vg_set_instance_override_value("", "tint_color", "0.1,0.2,0.3,0.4", context.temp_allocator)
		ov  = engine.vg_set_instance_override_value(ov, "tag_label", "boss_knight", context.temp_allocator)
		ov  = engine.vg_set_instance_override_value(ov, "entity_uuid", "123456789012", context.temp_allocator)
		engine.vg_apply_instance_overrides(&g2, &bb, ov)
		testing.expect_value(t, bb.slots[1].val_i64, i64(123456789012))
		testing.expect_value(t, string(bb.slots[2].val_cstr), "boss_knight")
		testing.expect(t, abs(bb.slots[0].val_vec4.w - 0.4) < 1e-4, "expected Vec4 override applied cleanly")

		delete(bb.last_exec_path)
		engine.vg_destroy_graph(&g2)
		context.allocator = orig_alloc
	}
}

// 2. Flow Nodes `Sequence` (`+ Add Pin`) & `For_Loop` (`First..Last` + `Completed`) Live Eval & Transpiler
@(test)
test_v3_sequence_and_for_loop_eval_and_transpile :: proc(t: ^testing.T) {
	g: engine.Visual_Graph
	g.name     = strings.clone("seq_loop_test")
	g.domain   = .Gameplay_Ability
	g.next_uid = 1
	engine.vg_ensure_default_spaces(&g)
	defer engine.vg_destroy_graph(&g)

	append(&g.variables, engine.VG_Var_Decl{
		name        = strings.clone("accum"),
		pin_type    = .Float,
		default_f32 = 0.0,
	})

	u_init := engine.vg_add_node(&g, .Event_Init, {0, 0})
	u_seq  := engine.vg_add_node(&g, .Sequence, {200, 0})
	if seq_n := engine.vg_find_node(&g, u_seq); seq_n != nil {
		engine.vg_sequence_add_pin(seq_n) // Now has Then 0, Then 1, Then 2!
		testing.expect_value(t, len(seq_n.outputs), 3)
	}

	u_set0 := engine.vg_add_node(&g, .Set_Variable, {420, 0}, "accum")
	if n0 := engine.vg_find_node(&g, u_set0); n0 != nil && len(n0.inputs) > 1 { n0.inputs[1].default_f32 = 5.0 }

	u_set1 := engine.vg_add_node(&g, .Set_Variable, {420, 120}, "accum")
	if n1 := engine.vg_find_node(&g, u_set1); n1 != nil && len(n1.inputs) > 1 { n1.inputs[1].default_f32 = 12.5 }

	u_loop := engine.vg_add_node(&g, .For_Loop, {420, 240})
	if fl := engine.vg_find_node(&g, u_loop); fl != nil {
		fl.inputs[1].default_int = 1
		fl.inputs[2].default_int = 3
	}
	u_done := engine.vg_add_node(&g, .Set_Variable, {700, 260}, "accum")
	if nd := engine.vg_find_node(&g, u_done); nd != nil && len(nd.inputs) > 1 { nd.inputs[1].default_f32 = 42.0 }

	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_seq,  to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_seq,  from_pin = 0, to_uid = u_set0, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_seq,  from_pin = 1, to_uid = u_set1, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_seq,  from_pin = 2, to_uid = u_loop, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_loop, from_pin = 2, to_uid = u_done, to_pin = 0})

	bb: engine.VG_Runtime_Blackboard
	defer delete(bb.last_exec_path)
	engine.vg_sync_blackboard(&g, &bb)
	engine.vg_eval_event_live(&g, &bb, {}, 1.0 / 60.0, .Event_Init)
	testing.expect(t, abs(bb.slots[0].val_f32 - 42.0) < 1e-4, "expected Sequence Then 0..2 + For_Loop Completed to set accum == 42.0")

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "// Sequence Then 0"), "expected Sequence transpilation")
	testing.expect(t, strings.contains(odin_src, "// Sequence Then 2"), "expected added Sequence pin 2 transpilation")
	testing.expect(t, strings.contains(odin_src, "for _loop_i_"), "expected For_Loop transpilation")
}

// 3. Sub-Graph `owner_proc` Inference, Custom Procedure Params, Pure Odin Body Mode, Rename & Delete,
//    plus Delegate Rename & Delete
@(test)
test_v3_custom_proc_inference_odin_body_rename_delete_and_delegates :: proc(t: ^testing.T) {
	g: engine.Visual_Graph
	g.name     = strings.clone("proc_v3_test")
	g.domain   = .Gameplay_Ability
	g.next_uid = 1
	engine.vg_ensure_default_spaces(&g)
	defer engine.vg_destroy_graph(&g)

	append(&g.variables, engine.VG_Var_Decl{
		name        = strings.clone("health"),
		pin_type    = .Float,
		default_f32 = 100.0,
	})
	append(&g.delegates, strings.clone("On_Hit"))

	u_proc := engine.vg_add_node(&g, .Custom_Proc_Entry, {0, 0}, "Apply_Damage")
	u_set  := engine.vg_add_node(&g, .Set_Variable, {280, 0}, "health")
	u_del  := engine.vg_add_node(&g, .Delegate_Bind, {0, 220}, "On_Hit")
	if sn := engine.vg_find_node(&g, u_set); sn != nil {
		// Simulate legacy graph missing `owner_proc`
		if sn.owner_proc != "" {
			delete(sn.owner_proc)
			sn.owner_proc = ""
		}
	}
	append(&g.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 1, to_uid = u_set, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 0, to_uid = u_del, to_pin = 1})

	engine.vg_infer_missing_owner_procs(&g)
	sn_chk := engine.vg_find_node(&g, u_set)
	testing.expect(t, sn_chk != nil && sn_chk.owner_proc == "Apply_Damage", "expected vg_infer_missing_owner_procs to tag downstream Set_Variable")

	testing.expect(t, engine.vg_custom_proc_add_param(&g, u_proc, "damage", .Float), "expected vg_custom_proc_add_param to succeed")
	if pe := engine.vg_find_node(&g, u_proc); pe != nil {
		testing.expect_value(t, len(pe.outputs), 6)
		pe.proc_use_odin_body = true
		delete(pe.odin_body)
		pe.odin_body = strings.clone("health -= damage")
	}

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "health -= damage"), "expected Pure Odin Procedure body emitted into mhgraph_*__proc_Apply_Damage")
	testing.expect(t, strings.contains(odin_src, "damage := _proc_param_5"), "expected custom proc param alias in Pure Odin body")

	testing.expect(t, engine.vg_rename_custom_proc(&g, u_proc, "Take_Hit"), "expected vg_rename_custom_proc to succeed")
	sn_chk = engine.vg_find_node(&g, u_set)
	testing.expect(t, sn_chk != nil && sn_chk.owner_proc == "Take_Hit", "expected child node owner_proc updated on rename")

	testing.expect(t, engine.vg_rename_delegate(&g, "On_Hit", "On_Damaged"), "expected vg_rename_delegate to succeed")
	dn_chk := engine.vg_find_node(&g, u_del)
	testing.expect(t, dn_chk != nil && dn_chk.delegate_name == "On_Damaged", "expected Delegate_Bind updated on delegate rename")

	testing.expect(t, engine.vg_delete_delegate(&g, "On_Damaged"), "expected vg_delete_delegate to succeed")
	testing.expect(t, engine.vg_find_node(&g, u_del) == nil, "expected Delegate_Bind removed when delegate deleted")

	testing.expect(t, engine.vg_delete_custom_proc(&g, u_proc), "expected vg_delete_custom_proc to succeed")
	testing.expect(t, engine.vg_find_node(&g, u_proc) == nil, "expected deleted Custom_Proc_Entry removed")
}

// 4. Node Block Deterministic Card Width Stability (0.0 px oscillation across 10 frames) + Import Autocomplete
@(test)
test_v3_node_block_width_determinism_and_import_autocomplete :: proc(t: ^testing.T) {
	// Even when caller renders at identical intrinsic content bounds across 10 frames,
	// `compute_node_block_width` must yield identical width with zero growth feedback loop!
	w0 := nc.compute_node_block_width(336.0, 212.0, 184.0, 290.0, 16.0)
	for _ in 0 ..< 10 {
		wk := nc.compute_node_block_width(336.0, 212.0, 184.0, 290.0, 16.0)
		testing.expect_value(t, wk, w0)
	}
	testing.expect_value(t, w0, f32(336.0))

	items, rep_s := cs.query_autocomplete_suggestions("import \"", 8, nil, false, false, context.temp_allocator)
	testing.expect_value(t, rep_s, 7)
	found_fmt := false
	for it in items {
		if strings.contains(it.label, "core:fmt") || strings.contains(it.insert_text, "core:fmt") {
			found_fmt = true
			break
		}
	}
	testing.expect(t, found_fmt, "expected `import \"` autocomplete to offer `core:fmt`")
}
