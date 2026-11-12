package tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import cs "moonhug:editor/code_studio"
import vs "moonhug:editor/visual_script"
import "../engine"
import hot "moonhug:engine/hot_api"

@(private = "file")
_local_pos :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	w := engine.ctx_world()
	if w == nil do return {}
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	return t != nil ? t.position : {}
}

@(test)
test_studio_in_ram_syntax_and_proc_splicer :: proc(t: ^testing.T) {
	// 1. Stage-A In-RAM `core:odin/parser` syntax check on valid scoped node body
	valid_body := "next_phase = phase + dt * 2.0\nif pos_ref != nil {\n\tpos_ref.y += next_phase\n}\n"
	ok_diags, _ := cs.check_odin_syntax_in_ram(valid_body, true, context.temp_allocator)
	testing.expect_value(t, len(ok_diags), 0)

	// 2. Stage-A catches broken syntax and maps back to exact 1-based scoped body line!
	bad_body := "x := 1.0\ny := 2.0 + * ;\nz := x\n"
	bad_diags, _ := cs.check_odin_syntax_in_ram(bad_body, true, context.temp_allocator)
	testing.expect(t, len(bad_diags) > 0, "expected Stage-A in-RAM parser to report syntax error on broken expression")
	if len(bad_diags) > 0 {
		testing.expect_value(t, bad_diags[0].line, 2)
	}

	// 3. Tokenizer produces syntax roles for keywords, types, and comments
	sample_src := "package demo\n// hello\nfoo :: proc(x: f32) { return }\n"
	ls := cs.compute_line_starts(sample_src, context.temp_allocator)
	spans := cs.tokenize_odin_lines(sample_src, ls, context.temp_allocator)
	testing.expect(t, len(spans) >= 6, "expected Odin tokenizer to produce token spans")

	// 4. AST Procedure Slicer & Body Splicer roundtrip
	full_file := `package hot_scripts

alpha :: proc(v: f32) -> f32 {
	return v + 1.0
}

beta :: proc(p: ^[3]f32, dt: f32) {
	p.x += dt
}
`
	sl, found := cs.slice_odin_procedure(full_file, "beta", context.temp_allocator)
	testing.expect(t, found, "expected slice_odin_procedure to locate `beta`")
	testing.expect(t, strings.contains(sl.body_text, "p.x += dt"), "expected sliced body to contain `p.x += dt`")

	spliced, sp_ok := cs.splice_odin_procedure_body(full_file, "beta", "p.y += dt * 4.0", context.temp_allocator)
	testing.expect(t, sp_ok, "expected splice_odin_procedure_body to succeed")
	testing.expect(t, strings.contains(spliced, "return v + 1.0"), "expected neighboring `alpha` proc to remain untouched")
	testing.expect(t, strings.contains(spliced, "p.y += dt * 4.0"), "expected `beta` body to be updated")
	post_diags, _ := cs.check_odin_syntax_in_ram(spliced, false, context.temp_allocator)
	testing.expect_value(t, len(post_diags), 0)

	// 5. Odin `-json-errors` parser
	json_sample := `{"error_count": 1, "errors": [{"type": "error", "pos": {"file": "demo.odin", "line": 14, "column": 9, "end_column": 15}, "msgs": ["Undeclared name: bogus_var"]}]}`
	j_diags := cs.parse_odin_json_errors(json_sample, context.temp_allocator)
	testing.expect_value(t, len(j_diags), 1)
	if len(j_diags) == 1 {
		testing.expect_value(t, j_diags[0].line, 14)
		testing.expect_value(t, j_diags[0].column, 9)
		testing.expect(t, strings.contains(j_diags[0].message, "bogus_var"), "expected diagnostic message from json-errors")
	}
}

@(test)
test_visual_script_copy_vs_ref_and_transpiler :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// 1. Strict `● Copy_Value` vs `◆ By_Reference` pin validation
	rvalue_float_out := engine.VG_Pin_Def{name = "Result", pin_type = .Float, pass_mode = .Copy_Value, is_addressable = false}
	lvalue_float_out := engine.VG_Pin_Def{name = "Ref",    pin_type = .Float, pass_mode = .By_Reference, is_addressable = true}
	ref_float_in     := engine.VG_Pin_Def{name = "Target", pin_type = .Float, pass_mode = .By_Reference}
	copy_float_in    := engine.VG_Pin_Def{name = "Value",  pin_type = .Float, pass_mode = .Copy_Value}

	ok_rval_to_ref, _ := engine.vg_can_connect_pins(rvalue_float_out, ref_float_in)
	testing.expect(t, !ok_rval_to_ref, "rvalue output MUST be rejected on a `◆ By_Reference` input pin")

	ok_lval_to_ref, _ := engine.vg_can_connect_pins(lvalue_float_out, ref_float_in)
	testing.expect(t, ok_lval_to_ref, "addressable lvalue `◆ ^Ref` MUST connect to a `◆ By_Reference` input pin")

	ok_lval_to_copy, _ := engine.vg_can_connect_pins(lvalue_float_out, copy_float_in)
	testing.expect(t, ok_lval_to_copy, "addressable pin MUST auto-dereference cleanly into a `● Copy_Value` input pin")

	// 2. Tier-1 Live Graph Evaluator + Deterministic Native `.odin` Transpiler
	g: engine.Visual_Graph
	engine.vg_init_default_demo_graph(&g, "hover_oscillator")
	defer engine.vg_destroy_graph(&g)

	bb: engine.VG_Runtime_Blackboard
	defer delete(bb.last_exec_path)

	tH := engine.transform_new("BuoyancyProbe")
	engine.transform_set_local_position(tH, {1.0, 2.0, 3.0})

	engine.vg_eval_graph_live(&g, &bb, tH, 0.05)
	pos_after := _local_pos(tH)
	testing.expect(t, math.abs(pos_after.y - 2.0) > 1e-4, "expected Tier-1 live graph evaluation to mutate `Transform.position.y` via `◆ ^Ref`")

	// 3. Transpile `.mhgraph` -> pure `.odin` and verify zero syntax errors in-RAM!
	odin_code, proc_name := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect_value(t, proc_name, "mhgraph_hover_oscillator")
	testing.expect(t, strings.contains(odin_code, "pos: ^[3]f32") && strings.contains(odin_code, "phase: ^f32"), "expected transpiled Odin signature to emit `^f32` and `^[3]f32` for `◆ By_Reference` pins")
	syn_diags, _ := cs.check_odin_syntax_in_ram(odin_code, false, context.temp_allocator)
	testing.expect_value(t, len(syn_diags), 0)
}

@(test)
test_hot_cartridge_dll_load_and_invoke :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.hot_cartridge_unload_all()

	// Static `@(hot_proc)`s are registered automatically via `@(init)` in `hot_procs_generated.odin`!
	testing.expect(t, engine.hot_proc_exists("hot_spring_vec3_ref"), "expected static `@(hot_proc)` `hot_spring_vec3_ref` to be registered")
	testing.expect(t, engine.hot_proc_exists("mhgraph_hover_oscillator"), "expected transpiled `mhgraph_hover_oscillator` to be registered")

	// Load the real compiled C-ABI `hot_cartridge_latest.dll` (copied to an isolated test DLL so Windows never locks `latest`)!
	dll_ext :: ".dll" when ODIN_OS == .Windows else (".dylib" when ODIN_OS == .Darwin else ".so")
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	src_dll, _ := filepath.join({repo_root, "builds", "hot_cartridge_latest" + dll_ext}, context.temp_allocator)
	test_dll, _ := filepath.join({repo_root, "builds", fmt.tprintf("hot_cartridge_test_%d%s", os.get_pid(), dll_ext)}, context.temp_allocator)
	defer _ = os.remove(test_dll)

	if os.exists(src_dll) {
		if raw_dll, rerr := os.read_entire_file(src_dll, context.temp_allocator); rerr == nil {
			_ = os.write_entire_file(test_dll, raw_dll)
			swapped, load_ok := engine.hot_cartridge_load_dll(test_dll)
			testing.expect(t, load_ok, "expected `hot_cartridge_load_dll` to load compiled cartridge DLL cleanly")
			testing.expect(t, swapped >= 3, "expected at least 3 `@(hot_proc)` symbols in cartridge DLL")
		}
	}

	// Invoke `hot_spring_vec3_ref` across the C-ABI boundary mutating `cur_vec` By-Reference (`◆ ^[3]f32`)!
	tH := engine.transform_new("HotTarget")
	engine.transform_set_local_position(tH, {0.0, 5.0, 0.0})

	cur_vec := [3]f32{0.0, 0.0, 0.0}
	frame: hot.Hot_Call_Frame
	frame.inputs[0] = {pin_type = .Vec3,  pass_mode = .By_Reference, ref_ptr = &cur_vec}
	frame.inputs[1] = {pin_type = .Vec3,  pass_mode = .Copy_Value,   val_vec3 = {10.0, 20.0, -5.0}}
	frame.inputs[2] = {pin_type = .Float, pass_mode = .Copy_Value,   val_f32 = 12.0}
	frame.input_count = 3

	invoked := engine.hot_proc_invoke("hot_spring_vec3_ref", tH, 0.05, &frame)
	testing.expect(t, invoked, "expected `hot_spring_vec3_ref` invocation to succeed")
	testing.expect(t, cur_vec.x > 1.0 && cur_vec.y > 2.0 && cur_vec.z < -0.5, "expected `◆ By_Reference` `[3]f32` pointer to be mutated in-place across DLL boundary")

	// Invoke `VisualScriptRunner` tick driving `mhgraph_hover_oscillator` on `tH`!
	_, comp_ptr := engine.transform_add_comp(tH, .VisualScriptRunner)
	runner := cast(^engine.VisualScriptRunner)comp_ptr
	testing.expect(t, runner != nil, "expected `VisualScriptRunner` component to attach")
	engine.visual_script_runners_tick(0.05)
	pos_after := _local_pos(tH)
	testing.expect(t, math.abs(pos_after.y - 5.0) > 1e-4, "expected `VisualScriptRunner` tick to drive `mhgraph_hover_oscillator`")

	// Unload DLL explicitly before `defer os.remove(test_dll)` runs on Windows!
	engine.hot_cartridge_unload_all()
}

@(test)
test_relaunch_shared_memory_roundtrip :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		return
	}

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	sc := engine.sm_scene_get_active()
	testing.expect(t, sc != nil, "expected active scene in TestCtx")
	if sc == nil do return

	hero_h := engine.transform_new("UnsavedHero")
	engine.transform_set_local_position(hero_h, {42.5, 7.25, -13.0})
	hero_t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(hero_h))
	testing.expect(t, hero_t != nil && hero_t.local_id != 0, "expected authored `Local_ID` on `UnsavedHero`")
	hero_lid := u64(hero_t.local_id)

	scene_bytes, ser_ok := engine.scene_serialize(sc)
	testing.expect(t, ser_ok && len(scene_bytes) > 0, "expected `scene_serialize` to produce in-RAM bytes")
	defer if ser_ok do delete(scene_bytes)

	shm_name := fmt.tprintf("Local\\MoonHug_SHM_UnitTest_%d", os.get_pid())
	sel_lids := [1]u64{hero_lid}
	in_snap := engine.Relaunch_SHM_Snapshot{
		has_scene_bytes = true,
		cam_pos         = {11.0, 22.0, 33.0},
		cam_yaw         = 1.25,
		cam_pitch       = -0.42,
		cam_dist        = 14.5,
		cam_target      = {1.0, 2.0, 3.0},
		cam_ortho       = false,
		cam_2d_mode     = false,
		selected_lids   = sel_lids[:],
		scene_path      = "assets/unsaved_ram_test.scene",
		scene_bytes     = scene_bytes,
	}

	shm_h, create_ok := engine.relaunch_shm_create(shm_name, in_snap)
	testing.expect(t, create_ok && shm_h != nil, "expected Win32 `CreateFileMappingW` RAM section creation to succeed")
	defer engine.relaunch_shm_close(shm_h)

	// Mutate live world before restoring to prove the restore comes 100% from OS Shared Memory!
	engine.transform_set_local_position(hero_h, {0.0, 0.0, 0.0})

	out_snap, read_ok := engine.relaunch_shm_read(shm_name)
	testing.expect(t, read_ok, "expected `relaunch_shm_read` to map and deserialize RAM snapshot")
	defer engine.relaunch_shm_snapshot_destroy(&out_snap)

	testing.expect_value(t, out_snap.cam_pos, [3]f32{11.0, 22.0, 33.0})
	testing.expect_value(t, out_snap.cam_yaw, f32(1.25))
	testing.expect_value(t, len(out_snap.selected_lids), 1)
	testing.expect_value(t, out_snap.scene_path, "assets/unsaved_ram_test.scene")

	restored_sc := engine.scene_reload_in_place_bytes(sc, out_snap.scene_bytes, {}, out_snap.scene_path)
	testing.expect(t, restored_sc != nil, "expected `scene_reload_in_place_bytes` from shared-memory payload to succeed")
	if restored_sc != nil {
		rebound_h, lid_ok := engine.bimap_get(&restored_sc.local_ids, engine.Local_ID(out_snap.selected_lids[0]))
		testing.expect(t, lid_ok, "expected selected `Local_ID` to resolve in restored scene")
		if lid_ok {
			restored_pos := _local_pos(engine.Transform_Handle(rebound_h))
			testing.expect(t, math.abs(restored_pos.x - 42.5) < 1e-4 && math.abs(restored_pos.y - 7.25) < 1e-4 && math.abs(restored_pos.z - (-13.0)) < 1e-4, "expected unsaved entity position to survive zero-disk OS shared memory handoff")
		}
	}
}

@(test)
test_studio_imgui_c_varargs_cstring_safety :: proc(t: ^testing.T) {
	// Regression guard for `crash_36992.log` (`ImGui_TextColored -> vsprintf -> strnlen` segfault):
	// Odin `string` (`{data, len}`, nullable / non-NUL-terminated) MUST NEVER be passed directly
	// to `#c_varargs` ImGui text procs (`im.Text`, `im.TextColored`, `im.TextDisabled`, `im.TextWrapped`, `im.BulletText`)!
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	files := [3]string{
		"moonhug/editor/code_studio/code_studio.odin",
		"moonhug/editor/visual_script/visual_script_editor.odin",
		"moonhug/editor/overwatch_controller.odin",
	}
	for rel in files {
		abs_p, _ := filepath.join({repo_root, rel}, context.temp_allocator)
		raw, err := os.read_entire_file(abs_p, context.temp_allocator)
		testing.expectf(t, err == nil, "expected %s to be readable", rel)
		if err != nil do continue

		lines := strings.split_lines(string(raw), context.temp_allocator)
		for line, li in lines {
			trimmed := strings.trim_space(line)
			if strings.has_prefix(trimmed, "//") do continue
			is_vararg_txt := strings.contains(trimmed, "im.Text(") ||
			                 strings.contains(trimmed, "im.TextColored(") ||
			                 strings.contains(trimmed, "im.TextDisabled(") ||
			                 strings.contains(trimmed, "im.TextWrapped(") ||
			                 strings.contains(trimmed, "im.BulletText(")
			if !is_vararg_txt do continue
			if !strings.contains(trimmed, "%s") do continue

			// Every `%s` inside `#c_varargs` ImGui text calls in Studio/VisualScript must either:
			// 1. Format via Odin's safe `fmt.ctprintf` (with `"%s", fmt.ctprintf(...)`), or
			// 2. Pass only compile-time NUL-terminated `cstring` icon constants (`icons.ICON_`).
			safe := strings.contains(trimmed, "fmt.ctprintf(") || strings.contains(trimmed, "icons.ICON_")
			testing.expectf(t, safe, "%s:%d passes raw string to #c_varargs ImGui proc without cstring conversion: %s", rel, li + 1, trimmed)
		}
	}
}
