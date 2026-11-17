package tests

import "base:intrinsics"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"
import editor "../editor"
import "../engine"
import "haati:engine/crash_journal"
import hot "haati:engine/hot_api"
import cs "haati:editor/code_studio"
import "haati:editor/icons"
import mcp "haati:editor/mcp"
import vs "haati:editor/visual_script"
import widgets "haati:editor/widgets"

// 1. Verifies 3-Zone Chimera `.bodin` lossless authoring:
//    - Multiple custom Odin structs + enum + defer + context.temp_allocator + []f32 in Zone 1
//      are preserved verbatim across re-bakes.
//    - AST sync discovers ALL structs & enums in Zone 1 as `code_authored` without duplicating
//      their definitions in Zone 2.
//    - Shared imports already declared in Zone 1 (`"core:math"`) are deduplicated cleanly.
@(test)
test_chimera_bodin_3zone_lossless_and_multi_struct :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	zone1 := `#+feature using-stmt
package hot_scripts

import "core:math"
import hot "haati:engine/hot_api"

Gait_Phase :: enum u8 {
	Stance = 0,
	Swing  = 1,
}

Recoil_Curve_Node :: struct {
	pitch_kick: f32,
	decay_rate: f32,
}

Procedural_Pelvis_Spring :: struct {
	stiffness: f32,
	damping:   f32,
	phase:     Gait_Phase,
}

helper_weighted_samples :: proc(scale: f32) -> f32 {
	scratch := make([]f32, 4, context.temp_allocator)
	defer { scratch[0] = 0 }
	scratch[1] = math.sin(scale)
	return scratch[1]
}
`

	g: engine.Visual_Graph
	engine.vg_init_default_demo_graph(&g, "chimera_test_bp")
	defer engine.vg_destroy_graph(&g)

	vs.sync_bodin_user_ast_into_graph(&g, zone1)

	found_phase  := false
	found_recoil := false
	found_pelvis := false
	for ed in g.enums {
		if ed.name == "Gait_Phase" && ed.code_authored && ed.source_line > 0 {
			found_phase = true
		}
	}
	for sd in g.structs {
		if sd.name == "Recoil_Curve_Node" && sd.code_authored && len(sd.fields) == 2 {
			found_recoil = true
		}
		if sd.name == "Procedural_Pelvis_Spring" && sd.code_authored && len(sd.fields) == 3 {
			found_pelvis = true
		}
	}
	testing.expect(t, found_phase, "Zone 1 enum Gait_Phase must sync into Visual_Graph.enums")
	testing.expect(t, found_recoil && found_pelvis, "Zone 1 MUST support multiple structs simultaneously in Blueprint Graph")

	combined, main_proc := vs.assemble_bodin_odin_sections(&g, zone1, true, context.temp_allocator)
	testing.expect_value(t, main_proc, "mhgraph_chimera_test_bp")

	extracted, has_z1 := engine.vg_extract_bodin_user_zone(combined, context.temp_allocator)
	testing.expect(t, has_z1, "assembled .bodin must contain // @BODIN_GENERATED_BEGIN marker")
	testing.expect_value(t, strings.trim_right_space(extracted), strings.trim_right_space(zone1))

	z2, _ := vs.transpile_graph_zone2(&g, zone1, context.temp_allocator)
	testing.expect(t, !strings.contains(z2, "Recoil_Curve_Node :: struct"), "Zone 2 must NOT duplicate code_authored Zone 1 structs")
	testing.expect(t, !strings.contains(z2, "Procedural_Pelvis_Spring :: struct"), "Zone 2 must NOT duplicate second Zone 1 struct")
	testing.expect(t, !strings.contains(z2, "Gait_Phase :: enum"), "Zone 2 must NOT duplicate code_authored Zone 1 enums")
	testing.expect(t, !strings.contains(z2, `import "core:math"`), "Zone 2 must deduplicate imports already present in Zone 1")
	testing.expect(t, strings.contains(z2, "context = hot.make_script_context(api)"), "Zone 2 @(hot_proc) entries must bind host Script Context")
	testing.expect(t, strings.contains(z2, "_body :: #force_inline proc("), "Scoped Odin node bodies must compile as full Odin procs supporting defer/allocators/slices")
	testing.expect(t, !strings.contains(z2, "_body :: #force_inline proc \"c\""), "Scoped Odin node bodies must NOT be trapped inside contextless proc \"c\"")

	// Verify roundtrip on disk preserves Zone 1 verbatim!
	tmp_dir, terr := os.temp_dir(context.temp_allocator)
	testing.expect(t, terr == nil, "temp_dir must succeed")
	tmp_bodin, _ := filepath.join({tmp_dir, "chimera_roundtrip_test.bodin"}, context.temp_allocator)
	_ = os.remove(tmp_bodin)
	defer _ = os.remove(tmp_bodin)

	saved := engine.vg_save_bodin_file(&g, tmp_bodin, combined)
	testing.expect(t, saved, "vg_save_bodin_file must succeed")

	loaded_raw, rerr := os.read_entire_file(tmp_bodin, context.temp_allocator)
	testing.expect(t, rerr == nil, "reading saved .bodin must succeed")
	disk_z1, disk_has_z1 := engine.vg_extract_bodin_user_zone(string(loaded_raw), context.temp_allocator)
	testing.expect(t, disk_has_z1 && strings.trim_right_space(disk_z1) == strings.trim_right_space(zone1), "disk .bodin roundtrip must preserve Zone 1 bytes")
}

// 2. Verifies Float Slice (`[]f32`) & Dynamic Array (`[dynamic]f32`) variables across
//    Odin type emission, JSON serialization, transpiled bridge calls, and live VM Array_Op!
@(test)
test_float_slice_and_dynamic_array_variables_and_vm :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	g: engine.Visual_Graph
	g.name = strings.clone("seq_test_bp")
	g.next_uid = 1
	defer engine.vg_destroy_graph(&g)

	v_sl := engine.VG_Var_Decl{
		name              = strings.clone("weights_slice"),
		pin_type          = .Float,
		is_array          = true,
		container_kind    = .Slice,
		instance_editable = true,
	}
	append(&v_sl.default_f32_list, 1.5, 2.5, 4.0)
	append(&g.variables, v_sl)

	v_da := engine.VG_Var_Decl{
		name              = strings.clone("trail_samples"),
		pin_type          = .Float,
		is_array          = true,
		container_kind    = .Dynamic_Array,
		instance_editable = true,
	}
	append(&v_da.default_f32_list, 0.25, 0.75)
	append(&g.variables, v_da)

	testing.expect_value(t, engine.vg_var_odin_type_ex(&g, g.variables[0], context.temp_allocator), "[]f32")
	testing.expect_value(t, engine.vg_var_odin_type_ex(&g, g.variables[1], context.temp_allocator), "[dynamic]f32")

	src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(src, "weights_slice: []f32,"), "Blueprint_State must emit []f32 slice field")
	testing.expect(t, strings.contains(src, "trail_samples: [dynamic]f32,"), "Blueprint_State must emit [dynamic]f32 dynamic array field")
	testing.expect(t, strings.contains(src, "hot.var_f32_seq_ptr("), "State loader must fetch runtime f32 sequence ptrs")
	testing.expect(t, strings.contains(src, "hot.var_f32_seq_sync("), "State saver must sync runtime f32 sequences back")

	// Live VM Array_Op (.Append & .Pop) on Dynamic_Array!
	u_init := engine.vg_add_node(&g, .Event_Init, {0, 0})
	u_app  := engine.vg_add_node(&g, .Array_Op, {200, 0}, "trail_samples")
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, u_app), .Append, "trail_samples")
	engine.vg_find_node(&g, u_app).inputs[1].default_f32 = 9.5
	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_app, to_pin = 0})

	bb: engine.VG_Runtime_Blackboard
	defer engine.vg_destroy_blackboard(&bb)
	engine.vg_sync_blackboard(&g, &bb)
	engine.vg_eval_event_live(&g, &bb, {}, 0.016, .Event_Init)

	seq := bb.var_f32_seqs["trail_samples"]
	testing.expect_value(t, len(seq), 3)
	testing.expect_value(t, seq[2], f32(9.5))

	// Temp file JSON roundtrip preserves container_kind + default_f32_list
	tmp_dir, _ := os.temp_dir(context.temp_allocator)
	tmp_json, _ := filepath.join({tmp_dir, "seq_var_roundtrip.mhgraph"}, context.temp_allocator)
	_ = os.remove(tmp_json)
	defer _ = os.remove(tmp_json)
	testing.expect(t, engine.vg_save_to_file(&g, tmp_json), "vg_save_to_file must succeed")

	g2: engine.Visual_Graph
	defer engine.vg_destroy_graph(&g2)
	testing.expect(t, engine.vg_load_from_file(&g2, tmp_json), "vg_load_from_file must succeed")
	testing.expect_value(t, engine.vg_resolve_container_kind(g2.variables[0]), engine.VG_Container_Kind.Slice)
	testing.expect_value(t, engine.vg_resolve_container_kind(g2.variables[1]), engine.VG_Container_Kind.Dynamic_Array)
	testing.expect_value(t, len(g2.variables[0].default_f32_list), 3)
}

@(private = "file")
_test_report_fault_cb :: proc "c" (msg, file, proc_name: cstring, line: i32) {
	crash_journal.sandbox_record_assertion_fault(msg, file, proc_name, line)
}

@(private = "file")
_test_trigger_assertion_fault :: proc "c" (_arg: rawptr) {
	api := hot.Engine_Hot_API{
		report_sandbox_fault = _test_report_fault_cb,
	}
	context = hot.make_script_context(&api)
	assert(false, "synthetic sandbox bounds panic")
}

when ODIN_OS == .Windows {
	@(private = "file", optimization_mode = "none")
	_test_trigger_veh_access_violation :: proc "c" (_arg: rawptr) {
		bad_ptr := (^u32)(uintptr(0x10))
		intrinsics.volatile_store(bad_ptr, u32(0xDEAD))
	}
}

// 3. Verifies 2-Layer Sandbox Crash Guard (Odin Assertion Trap + Windows VEH Recovery).
@(test)
test_sandbox_exec_layer1_assertion_and_layer2_veh :: proc(t: ^testing.T) {
	fault1, ok1 := crash_journal.sandbox_exec(_test_trigger_assertion_fault, nil)
	testing.expect(t, !ok1, "Layer 1 assertion inside sandbox_exec must fail safely without aborting test runner")
	testing.expect(t, fault1.occurred, "Layer 1 must populate fault1.occurred")
	testing.expect(t, fault1.line > 0, "Layer 1 must capture faulting Odin source line")
	testing.expect(t, strings.contains(crash_journal.sandbox_fault_reason(&fault1), "synthetic sandbox bounds panic"), "Layer 1 must preserve panic reason")

	when ODIN_OS == .Windows {
		fault2, ok2 := crash_journal.sandbox_exec(_test_trigger_veh_access_violation, nil)
		testing.expect(t, !ok2, "Layer 2 Win64 VEH must catch volatile unmapped write safely")
		testing.expect(t, fault2.occurred, "Layer 2 must mark fault2.occurred")
		testing.expect_value(t, fault2.code, u32(0xC0000005))
	}
}

// 4. Verifies Settings label humanizer + MCP discovery constant conventions.
@(test)
test_settings_humanizer_and_mcp_discovery :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	testing.expect_value(t, editor.humanize_setting_label("problem_check_delay_sec"), "Problem Check Delay (s)")
	testing.expect_value(t, editor.humanize_setting_label("ui_scale"), "UI Scale")
	testing.expect_value(t, editor.humanize_setting_label("target_fps_hz"), "Target FPS (Hz)")
	testing.expect_value(t, editor.humanize_setting_label("ide_sandbox_mode"), "IDE Sandbox Mode")
	testing.expect_value(t, editor.humanize_setting_label("enable_csg_vfs_mcp"), "Enable CSG VFS MCP")
	testing.expect_value(t, mcp.BRIDGE_FILE_USER_SETTINGS, "UserSettings/mcp_bridge.json")
}

// 5. Verifies universal all-type Slice (`[]Vec3`), Dynamic Array (`[dynamic]i32`),
//    `Sub_Slice` (`arr[start:end]`), and zero-cost guarded `rawptr` transpilation + VM sequences.
@(test)
test_universal_sequences_subslice_and_rawptr_bodin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	g: engine.Visual_Graph
	g.name = strings.clone("uni_seq_rawptr_bp")
	g.next_uid = 1
	defer engine.vg_destroy_graph(&g)

	append(&g.variables, engine.VG_Var_Decl{
		name           = strings.clone("waypoints"),
		pin_type       = .Vec3,
		is_array       = true,
		container_kind = .Slice,
	})
	append(&g.variables, engine.VG_Var_Decl{
		name           = strings.clone("ids"),
		pin_type       = .Int,
		is_array       = true,
		container_kind = .Dynamic_Array,
	})
	append(&g.variables, engine.VG_Var_Decl{
		name     = strings.clone("scratch_ptr"),
		pin_type = .Raw_Ptr,
	})
	append(&g.variables, engine.VG_Var_Decl{
		name     = strings.clone("out_val"),
		pin_type = .Float,
	})

	testing.expect_value(t, engine.vg_var_odin_type_ex(&g, g.variables[0], context.temp_allocator), "[][3]f32")
	testing.expect_value(t, engine.vg_var_odin_type_ex(&g, g.variables[1], context.temp_allocator), "[dynamic]i32")
	testing.expect_value(t, engine.vg_var_odin_type_ex(&g, g.variables[2], context.temp_allocator), "rawptr")

	u_init := engine.vg_add_node(&g, .Event_Init, {0, 0})
	u_app  := engine.vg_add_node(&g, .Array_Op, {180, 0}, "ids")
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, u_app), .Append, "ids")
	engine.vg_find_node(&g, u_app).inputs[1].default_int = 42
	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_app, to_pin = 0})

	u_sub := engine.vg_add_node(&g, .Array_Op, {360, 0}, "waypoints")
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, u_sub), .Sub_Slice, "waypoints")
	engine.vg_find_node(&g, u_sub).inputs[0].default_int = 1
	engine.vg_find_node(&g, u_sub).inputs[1].default_int = 3

	u_get_ptr := engine.vg_add_node(&g, .Get_Variable, {180, 120}, "scratch_ptr")
	u_cast    := engine.vg_add_node(&g, .Auto_Cast, {360, 120}, "rawptr->f32")
	if nc := engine.vg_find_node(&g, u_cast); nc != nil {
		if len(nc.inputs) > 0 do nc.inputs[0].pin_type = .Raw_Ptr
		if len(nc.outputs) > 0 do nc.outputs[0].pin_type = .Float
	}
	append(&g.wires, engine.VG_Wire{from_uid = u_get_ptr, from_pin = 0, to_uid = u_cast, to_pin = 0})

	u_set_val := engine.vg_add_node(&g, .Set_Variable, {540, 0}, "out_val")
	if nsv := engine.vg_find_node(&g, u_set_val); nsv != nil && len(nsv.inputs) > 1 {
		nsv.inputs[1].pin_type = .Float
	}
	append(&g.wires, engine.VG_Wire{from_uid = u_app, from_pin = 0, to_uid = u_set_val, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_cast, from_pin = 0, to_uid = u_set_val, to_pin = 1})

	u_fn := engine.vg_add_node(&g, .Odin_Function_Node, {720, 0}, "ConsumeSlice")
	if nfn := engine.vg_find_node(&g, u_fn); nfn != nil {
		if nfn.odin_body != "" do delete(nfn.odin_body)
		nfn.odin_body = strings.clone("_ = len(wp_sub)")
		append(&nfn.inputs, engine.VG_Pin_Def{
			name           = strings.clone("wp_sub"),
			pin_type       = .Vec3,
			is_array       = true,
			container_kind = .Slice,
		})
		append(&g.wires, engine.VG_Wire{from_uid = u_set_val, from_pin = 0, to_uid = u_fn, to_pin = 0})
		append(&g.wires, engine.VG_Wire{from_uid = u_sub, from_pin = 0, to_uid = u_fn, to_pin = len(nfn.inputs) - 1})
	}

	src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(src, "waypoints: [][3]f32,"), "Blueprint_State must emit [][3]f32 slice field")
	testing.expect(t, strings.contains(src, "ids: [dynamic]i32,"), "Blueprint_State must emit [dynamic]i32 dynamic array field")
	testing.expect(t, strings.contains(src, "scratch_ptr: rawptr,"), "Blueprint_State must emit rawptr field")
	testing.expect(t, strings.contains(src, "hot.var_seq_ptr("), "State loader must fetch runtime universal sequence ptrs")
	testing.expect(t, strings.contains(src, "hot.var_seq_sync("), "State saver must sync runtime universal sequences back")
	testing.expect(t, strings.contains(src, "hot.validate_raw_ptr("), "Raw_Ptr Auto_Cast must emit guarded hot.validate_raw_ptr check")
	testing.expect(t, strings.contains(src, "return s[lo:hi]"), "Sub_Slice node must emit Odin s[lo:hi] slice view expression")

	// Verify runtime `visual_script_get_entity_var_seq_ptr` & `visual_script_sync_entity_var_seq` roundtrip
	tH := engine.Transform_Handle(engine.Handle{index = 9001, generation = 1, type_key = .Transform})
	defer engine.visual_script_destroy_entity_state(tH)

	d0, l0, c0 := engine.visual_script_get_entity_var_seq_ptr(tH, "waypoints", i32(size_of([3]f32)), i32(align_of([3]f32)))
	testing.expect(t, d0 != nil && l0 == 0 && c0 >= 8, "var_seq_ptr must initialize backing storage for non-Float sequences")

	pts := [3][3]f32{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}
	engine.visual_script_sync_entity_var_seq(tH, "waypoints", &pts[0], i32(size_of([3]f32)), i32(align_of([3]f32)), 3, -1)
	d1, l1, _ := engine.visual_script_get_entity_var_seq_ptr(tH, "waypoints", i32(size_of([3]f32)), i32(align_of([3]f32)))
	testing.expect_value(t, l1, i32(3))
	testing.expect(t, d1 != nil && (cast([^][3]f32)d1)[1] == [3]f32{4, 5, 6}, "var_seq_sync slice clone must preserve Vec3 elements")

	// Live VM Array_Op (.Append) on `[dynamic]i32`
	bb: engine.VG_Runtime_Blackboard
	defer engine.vg_destroy_blackboard(&bb)
	engine.vg_sync_blackboard(&g, &bb)
	engine.vg_eval_event_live(&g, &bb, tH, 0.016, .Event_Init)
	id_seq := bb.var_seqs["ids"]
	testing.expect_value(t, id_seq.length, 1)
	testing.expect(t, id_seq.data != nil && (cast(^i32)id_seq.data)^ == 42, "VM Array_Op.Append must write i32 element into var_seqs")
}

// 6. Verifies `hot.validate_raw_ptr` pointer safety checks and `cs.predict_unsafe_odin_hazards`
//    static detection of dangling stack slices, rawptr integer casts, and append-invalidated views.
@(test)
test_validate_raw_ptr_and_unsafe_hazard_predictor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ok_nil, _ := hot.validate_raw_ptr(nil)
	testing.expect(t, !ok_nil, "nil rawptr must be rejected")

	ok_low, _ := hot.validate_raw_ptr(rawptr(uintptr(0x400)))
	testing.expect(t, !ok_low, "null-page address < 0x10000 must be rejected")

	ok_kern, _ := hot.validate_raw_ptr(rawptr(uintptr(0xFFFF800000001000)))
	testing.expect(t, !ok_kern, "non-canonical/kernel address must be rejected")

	aligned_u64: u64 = 123456
	misaligned := rawptr(uintptr(&aligned_u64) + 1)
	ok_mis, _ := hot.validate_raw_ptr(misaligned, align_of(u64))
	testing.expect(t, !ok_mis, "misaligned pointer must be rejected for align_of(u64)")

	ok_good, reason_good := hot.validate_raw_ptr(&aligned_u64, align_of(u64))
	testing.expect(t, ok_good && reason_good == "", "valid aligned pointer must pass hot.validate_raw_ptr")

	hazard_code := `package test_hazards
bad_stack_slice :: proc() -> []f32 {
	local_arr := [4]f32{1, 2, 3, 4}
	return local_arr[:]
}
bad_cast_and_append :: proc() {
	items := make([dynamic]f32)
	sub := items[0:]
	append(&items, 99.0)
	_ = sub
	p := rawptr(uintptr(0x1234))
	_ = p
}
`
	diags := cs.predict_unsafe_odin_hazards(hazard_code, "test_hazards.odin", context.temp_allocator)
	saw_stack  := false
	saw_append := false
	saw_cast   := false
	for d in diags {
		testing.expect(t, d.is_warning, "static hazard predictor must emit warnings (not compiler errors)")
		if strings.contains(d.message, "stack-local array") do saw_stack = true
		if strings.contains(d.message, "append(&items)") do saw_append = true
		if strings.contains(d.message, "rawptr(uintptr") || strings.contains(d.message, "raw integer") do saw_cast = true
	}
	testing.expect(t, saw_stack && saw_append && saw_cast, "predict_unsafe_odin_hazards must catch stack slice return, append invalidation, and rawptr(uintptr)")
}

// 7. Verifies in-process heap canary + NaN Transform scrubber (`visual_script_verify_and_repair_entity`).
@(test)
test_in_process_canary_and_nan_transform_scrubber :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	w := new(engine.World)
	defer free(w)
	engine.w_init(w)
	defer engine.world_destroy_all(w)

	uc := engine.UserContext{world = w}
	prev_uc := context.user_ptr
	context.user_ptr = &uc
	defer context.user_ptr = prev_uc

	tH := engine.transform_new("ScrubberEntity")
	defer engine.visual_script_destroy_entity_state(tH)

	blob_ptr := engine.visual_script_get_entity_var_blob_ptr(tH, "spring_cfg", 16)
	testing.expect(t, blob_ptr != nil, "var_blob_ptr must allocate canary-guarded storage")
	if blob_ptr == nil do return

	pre_pos   := [3]f32{1, 2, 3}
	pre_rot   := [4]f32{0, 0, 0, 1}
	pre_scale := [3]f32{1, 1, 1}

	tr := engine.pool_get(&w.transforms, engine.Handle(tH))
	testing.expect(t, tr != nil, "transform handle must resolve in world pool")
	if tr == nil do return
	tr.position = {math.nan_f32(), 5, 6}

	// Smash 1 byte immediately past the 16-byte payload (overwriting tail canary)
	(cast([^]u8)blob_ptr)[16] = 0xAA

	bad_var, nan_fixed := engine.visual_script_verify_and_repair_entity(tH, pre_pos, pre_rot, pre_scale)
	testing.expect_value(t, bad_var, "spring_cfg")
	testing.expect(t, nan_fixed, "scrubber must detect and repair NaN transform position")
	testing.expect(t, tr.position == pre_pos, "repaired transform position must restore pre-call coordinates")

	bad_var2, nan_fixed2 := engine.visual_script_verify_and_repair_entity(tH, pre_pos, pre_rot, pre_scale)
	testing.expect_value(t, bad_var2, "")
	testing.expect(t, !nan_fixed2, "after auto-repair, subsequent scrubber pass must report clean state")
}

// 8. Verifies out-of-process Watchdog 16 MB Kernel RAM Vault write + read_and_consume roundtrip on Windows.
@(test)
test_watchdog_kernel_ram_vault_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	when ODIN_OS == .Windows {
		vault_name := fmt.tprintf("Local\\Haati_WD_UnitTest_%d", os.get_pid())
		vh, vok := engine.watchdog_vault_create(vault_name)
		testing.expect(t, vok && vh != nil, "watchdog_vault_create must create Windows pagefile section")
		if !vok || vh == nil do return
		defer engine.watchdog_vault_close(vh)

		scene_str := "{\"root\":1,\"entities\":4}"
		tabs_str  := "[{\"path\":\"hot_scripts/player.odin\",\"text\":\"package hot_scripts\"}]"
		lids      := [?]u64{101, 202}
		snap := engine.Relaunch_SHM_Snapshot{
			has_scene_bytes = true,
			cam_pos         = {12.5, 4.0, -8.5},
			cam_yaw         = 0.75,
			cam_pitch       = -0.25,
			cam_dist        = 15.0,
			cam_target      = {1, 2, 3},
			cam_ortho       = false,
			cam_2d_mode     = true,
			selected_lids   = lids[:],
			scene_path      = "assets/scenes/arena.scene",
			scene_bytes     = transmute([]byte)scene_str,
		}

		testing.expect(t, engine.watchdog_vault_write(vh, snap, transmute([]byte)tabs_str), "watchdog_vault_write must succeed")

		rsnap, rtabs, rok := engine.watchdog_vault_read_and_consume(vault_name, context.temp_allocator)
		testing.expect(t, rok, "watchdog_vault_read_and_consume must restore staged snapshot")
		testing.expect(t, rsnap.has_scene_bytes && rsnap.cam_2d_mode, "camera and scene flags must roundtrip through Kernel RAM Vault")
		testing.expect(t, rsnap.cam_pos == snap.cam_pos, "cam_pos must roundtrip accurately")
		testing.expect_value(t, len(rsnap.selected_lids), 2)
		testing.expect_value(t, rsnap.selected_lids[1], u64(202))
		testing.expect_value(t, rsnap.scene_path, "assets/scenes/arena.scene")
		testing.expect_value(t, string(rsnap.scene_bytes), scene_str)
		testing.expect_value(t, string(rtabs), tabs_str)
	}
}

// 9. Verifies incomplete Odin `for` headers (`for i, ` / `for k, v {`) do not trigger
//    `core/odin/parser/parser.odin:938` `assert(as.op.kind == .In)`, preserve caller
//    `context.allocator`, and leak 0 heap allocations.
@(test)
test_parser_incomplete_for_header_no_assert_and_allocator_preserved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)
		orig_proc := context.allocator.procedure

		d1, _ := cs.check_odin_syntax_in_ram("package demo\nf :: proc() {\n\tfor i, \n}\n", false, context.allocator)
		testing.expect(t, context.allocator.procedure == orig_proc, "check_odin_syntax_in_ram must preserve caller context.allocator on incomplete `for i, `")
		testing.expect(t, len(d1) > 0 && !d1[0].is_warning, "expected syntax error diagnostic on incomplete `for i, `")
		for d in d1 {
			delete(d.file)
			delete(d.message)
		}
		delete(d1)

		d2, _ := cs.check_odin_syntax_in_ram("package demo\nf :: proc() {\n\tfor k, v {\n\t}\n}\n", false, context.allocator)
		testing.expect(t, context.allocator.procedure == orig_proc, "check_odin_syntax_in_ram must preserve caller context.allocator on incomplete `for k, v {`")
		testing.expect(t, len(d2) > 0, "expected diagnostic on incomplete `for k, v {` without `in`")
		for d in d2 {
			delete(d.file)
			delete(d.message)
		}
		delete(d2)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaked allocations after syntax parse, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees after syntax parse, got %d", len(track.bad_free_array))
}

// 10. Verifies Odin `-json-errors` fatal error severity elevation (even when tagged `"type": "warning"`
//     with `"error_count": 1`) and legacy `moonhug:` -> `haati:` / `project:` import migration.
@(test)
test_odin_json_error_severity_and_moonhug_migration :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fatal_warn_json := `{"error_count": 1, "errors": [{"type": "warning", "pos": {"file": "demo.odin", "line": 8, "column": 1, "end_column": 42}, "msgs": ["Syntax Error: Invalid path: moonhug:packages/demo_proj/Scenes/CamPawn"]}]}`
	fdiags := cs.parse_odin_json_errors(fatal_warn_json, context.temp_allocator)
	testing.expect_value(t, len(fdiags), 1)
	if len(fdiags) == 1 {
		testing.expect(t, !fdiags[0].is_warning, "fatal import syntax error with error_count=1 must elevate to hard error")
		testing.expect_value(t, fdiags[0].line, 8)
	}

	real_warn_json := `{"error_count": 0, "errors": [{"type": "warning", "pos": {"file": "demo.odin", "line": 3, "column": 1, "end_column": 10}, "msgs": ["Unused import"]}]}`
	wdiags := cs.parse_odin_json_errors(real_warn_json, context.temp_allocator)
	testing.expect_value(t, len(wdiags), 1)
	if len(wdiags) == 1 {
		testing.expect(t, wdiags[0].is_warning, "non-fatal warning with error_count=0 must stay is_warning=true")
	}

	m1, ok1 := cs.compute_haati_import_migration("moonhug:engine", "", context.temp_allocator)
	testing.expect(t, ok1 && m1 == "haati:engine", "moonhug:engine must migrate to haati:engine")
	m2, ok2 := cs.compute_haati_import_migration("moonhug:app/helpers", "", context.temp_allocator)
	testing.expect(t, ok2 && m2 == "haati:packages/app/helpers", "moonhug:app/* must migrate to haati:packages/app/*")
	m3, ok3 := cs.compute_haati_import_migration("moonhug:packages/control_rig", "my_game", context.temp_allocator)
	testing.expect(t, ok3 && m3 == "haati:packages/control_rig", "plugin package must migrate to haati:packages/*")
	m4, ok4 := cs.compute_haati_import_migration("moonhug:packages/my_game/Scenes/CamPawn", "my_game", context.temp_allocator)
	testing.expect(t, ok4 && m4 == "project:Scenes/CamPawn", "active project self-import must migrate to project:*")

	legacy_src := "package p\n// import \"moonhug:ignored_comment\"\nimport \"moonhug:engine\"\nimport cam \"moonhug:packages/my_game/Scenes/CamPawn\"\n"
	lints := cs.lint_legacy_moonhug_imports(legacy_src, "p.odin", "my_game", context.temp_allocator)
	testing.expect_value(t, len(lints), 2)
	migrated, cnt := cs.migrate_all_legacy_moonhug_imports(legacy_src, "my_game", context.temp_allocator)
	testing.expect_value(t, cnt, 2)
	testing.expect(t, strings.contains(migrated, "// import \"moonhug:ignored_comment\""), "commented import lines must remain untouched")
	testing.expect(t, strings.contains(migrated, "import \"haati:engine\""), "engine import must migrate to haati:engine")
	testing.expect(t, strings.contains(migrated, "import cam \"project:Scenes/CamPawn\""), "project import must migrate to project:Scenes/CamPawn")
}

// 11. Verifies 3-Zone Watchdog Vault independent zone writes preserve untouched zones.
@(test)
test_watchdog_vault_3zone_independent_updates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	when ODIN_OS == .Windows {
		vault_name := fmt.tprintf("Local\\Haati_WD_3ZoneTest_%d", os.get_pid())
		vh, vok := engine.watchdog_vault_create(vault_name)
		testing.expect(t, vok && vh != nil, "watchdog_vault_create must succeed")
		if !vok || vh == nil do return
		defer engine.watchdog_vault_close(vh)

		scene_str := "{\"scene\":1}"
		tabs_v1   := "[{\"abs_path\":\"a.odin\",\"content\":\"v1\"}]"
		tabs_v2   := "[{\"abs_path\":\"a.odin\",\"content\":\"v2\"}]"

		m1 := engine.Relaunch_SHM_Snapshot{
			cam_pos    = {1, 2, 3},
			cam_yaw    = 1.0,
			scene_path = "assets/s1.scene",
		}
		testing.expect(t, engine.watchdog_vault_write_meta(vh, m1), "initial Zone 0 meta write must succeed")
		testing.expect(t, engine.watchdog_vault_write_tabs(vh, transmute([]byte)tabs_v1), "initial Zone 1 tabs write must succeed")
		testing.expect(t, engine.watchdog_vault_write_scene(vh, true, transmute([]byte)scene_str), "initial Zone 2 scene write must succeed")

		// Update ONLY Zone 0 and Zone 1 without re-writing Zone 2
		m2 := m1
		m2.cam_yaw = 2.5
		testing.expect(t, engine.watchdog_vault_write_meta(vh, m2), "updated Zone 0 meta write must succeed")
		testing.expect(t, engine.watchdog_vault_write_tabs(vh, transmute([]byte)tabs_v2), "updated Zone 1 tabs write must succeed")

		rsnap, rtabs, rok := engine.watchdog_vault_read_and_consume(vault_name, context.temp_allocator)
		testing.expect(t, rok, "watchdog_vault_read_and_consume must read updated 3-zone vault")
		testing.expect_value(t, rsnap.cam_yaw, f32(2.5))
		testing.expect_value(t, string(rtabs), tabs_v2)
		testing.expect(t, rsnap.has_scene_bytes, "Zone 2 has_scene_bytes must remain intact across Zone 0/1 writes")
		testing.expect_value(t, string(rsnap.scene_bytes), scene_str)
	}
}

// 12. Verifies indexing a large multi-file package (`haati/engine`, 90+ `.odin` files) does not
//     wrap or corrupt the 4 MB `context.temp_allocator` ring buffer, preserves caller allocator,
//     and frees with zero leaked heap allocations or invalid string bytes.
@(test)
test_autocomplete_large_engine_package_index_no_ring_wrap_or_leak :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	sym_count := 0
	all_valid_utf8 := true
	{
		context.allocator = mem.tracking_allocator(&track)
		orig_proc := context.allocator.procedure

		syms := cs.index_package_dir_symbols("haati/engine", context.allocator)
		testing.expect(t, context.allocator.procedure == orig_proc, "index_package_dir_symbols must preserve caller context.allocator")
		sym_count = len(syms)
		for s in syms {
			if s.name == "" || !utf8.valid_string(s.name) ||
			   !utf8.valid_string(s.insert_text) ||
			   !utf8.valid_string(s.detail) ||
			   !utf8.valid_string(s.receiver) {
				all_valid_utf8 = false
			}
			if s.name        != "" do delete(s.name)
			if s.insert_text != "" do delete(s.insert_text)
			if s.detail      != "" do delete(s.detail)
			if s.receiver    != "" do delete(s.receiver)
		}
		delete(syms)
	}

	testing.expectf(t, sym_count >= 100, "expected >= 100 indexed symbols across haati/engine, got %d", sym_count)
	testing.expect(t, all_valid_utf8, "every indexed symbol must hold intact valid UTF-8 strings with zero ring-buffer overwrite")
	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaked allocations after indexing haati/engine, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees after indexing haati/engine, got %d", len(track.bad_free_array))
}

// 13. Verifies embedded Phosphor Regular (`Phosphor.ttf`) and newly added Material Symbols
//     constants decode to single PUA runes and map to real glyph indices inside the TTF font.
@(test)
test_phosphor_and_material_icon_glyphs_valid_pua :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ph_font: stbtt.fontinfo
	init_ok := bool(stbtt.InitFont(&ph_font, raw_data(editor.PHOSPHOR_FONT_DATA), 0))
	testing.expect(t, init_ok, "Phosphor.ttf must parse cleanly via stb_truetype")
	if !init_ok do return

	ph_samples := [?]string{
		icons.ICON_PH_VECTOR_THREE,
		icons.ICON_PH_BLUEPRINT,
		icons.ICON_PH_UNITE,
		icons.ICON_PH_SUBTRACT,
		icons.ICON_PH_INTERSECT,
		icons.ICON_PH_BONE,
		icons.ICON_PH_SWORD,
		icons.ICON_PH_CUBE,
	}
	for g in ph_samples {
		r, n := utf8.decode_rune_in_string(g)
		testing.expect(t, n == len(g) && r >= icons.ICON_PH_MIN && r <= icons.ICON_PH_MAX, "Phosphor constant must be a single PUA rune")
		glyph_idx := stbtt.FindGlyphIndex(&ph_font, r)
		testing.expectf(t, glyph_idx != 0, "Phosphor.ttf missing glyph index for codepoint U+%04X", u32(r))
	}

	md_samples := [?]string{
		icons.ICON_MD_LIGHTBULB,
		icons.ICON_MD_WB_SUNNY,
		icons.ICON_MD_SKELETON,
		icons.ICON_MD_PSYCHOLOGY,
		icons.ICON_MD_SMART_TOY,
		icons.ICON_MD_MEMORY,
		icons.ICON_MD_BUG_REPORT,
		icons.ICON_MD_ROCKET_LAUNCH,
	}
	for g in md_samples {
		r, n := utf8.decode_rune_in_string(g)
		testing.expect(t, n == len(g) && r >= icons.ICON_MD_MIN && r <= icons.ICON_MD_MAX, "Material icon constant must be a single PUA rune")
	}
}

// 14. Verifies `submit_async_check` and `set_checker_dirty_overlays` persist normalized paths
//     on the heap so wiping & overwriting `context.temp_allocator` cannot cause a worker UAF.
@(test)
test_async_checker_norm_path_heap_lifetime_no_uaf :: proc(t: ^testing.T) {
	defer cs.shutdown_checker()
	defer free_all(context.temp_allocator)

	cs.set_problem_check_delay_sec(0.05)
	defer cs.set_problem_check_delay_sec(0.9)

	for i in 0 ..< 5 {
		temp_ov := fmt.tprintf("C:/Haati_Temp_Test\\dir_%d\\overlay_script_%d.bodin", i, i)
		temp_sub := fmt.tprintf("C:/Haati_Temp_Test\\dir_%d\\active_script_%d.bodin", i, i)
		cs.set_checker_dirty_overlays([]cs.Dirty_File_Overlay{
			{abs_path = temp_ov, code = "package hot_scripts\n", is_bodin = true},
		})
		cs.submit_async_check("package hot_scripts\n// valid syntax\n", false, "", false, temp_sub)

		// Wipe and poison temp_allocator immediately while worker holds queued strings!
		free_all(context.temp_allocator)
		poison := make([]u8, 16 * 1024, context.temp_allocator)
		mem.set(raw_data(poison), 0xAA, len(poison))

		time.sleep(5 * time.Millisecond)
		snap := cs.read_checker_snapshot(context.temp_allocator)
		testing.expect(t, utf8.valid_string(snap.summary_label), "checker snapshot summary must stay valid UTF-8")
	}
	cs.set_checker_dirty_overlays(nil)
}

// 15. Verifies HTSCN001 binary scene encoding, O(1) embedded UTF-8 summary (`deps:` + hierarchy),
//     lossless round-trip decode, and CRC32 corruption / truncation rejection without leaking.
@(test)
test_htscn001_binary_scene_roundtrip_summary_and_corruption_guard :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	prefab_id, _ := uuid.read("11111111-2222-4333-8444-555555555555")
	prefab_guid := engine.Asset_GUID(prefab_id)

	sf: engine.SceneFile
	sf.schema_version = engine.SCENE_SCHEMA_VERSION
	sf.root = 100

	tr := engine.Transform{
		local_id     = 100,
		name         = strings.clone("WatchWolfRoot"),
		is_active    = true,
		position     = {1.5, 2.25, -3.5},
		rotation     = {0, 0, 0, 1},
		scale        = {1, 1, 1},
		render_layer = 3,
	}
	append(&tr.children, engine.Ref{pptr = engine.PPtr{local_id = 200}})
	append(&tr.components, engine.Owned{local_id = 300})
	append(&sf.transforms, tr)

	comp_obj := make(json.Object)
	comp_obj[strings.clone("__type")] = json.String(strings.clone("9f36ee91-34b6-4636-a360-ee872af0436b"))
	comp_base := make(json.Object)
	comp_base[strings.clone("local_id")] = json.Integer(300)
	comp_obj[strings.clone("base")] = comp_base
	comp_obj[strings.clone("intensity")] = json.Float(2.5)
	append(&sf.components, comp_obj)

	ns := engine.NestedScene{
		local_id           = 500,
		local_id_in_parent = 500,
		source_prefab      = prefab_guid,
		transform_parent   = 100,
		sibling_index      = 1,
	}
	append(&ns.overrides, engine.Override{
		target        = engine.PPtr{guid = prefab_guid, local_id = 42},
		property_path = strings.clone("speed"),
		value         = json.Float(9.25),
	})
	append(&sf.nested_scenes, ns)

	append(&sf.breadcrumbs, engine.Breadcrumb{
		local_id       = 700,
		scene_source   = engine.PPtr{guid = prefab_guid, local_id = 42},
		scene_instance = 500,
	})
	defer engine.scene_file_destroy(&sf)

	bin, bok := engine.scene_binary_encode(&sf)
	testing.expect(t, bok && len(bin) >= engine.SCENE_BINARY_HEADER_SIZE, "scene_binary_encode must succeed")
	if !bok do return
	defer delete(bin)

	testing.expect(t, engine.scene_bytes_is_binary(bin), "encoded buffer must carry HTSCN001 magic")

	summary, sok := engine.scene_extract_summary(bin, context.temp_allocator)
	testing.expect(t, sok, "scene_extract_summary must succeed on encoded HTSCN001")
	testing.expect(t, strings.contains(summary, "WatchWolfRoot"), "summary must list transform name")
	testing.expect(t, strings.contains(summary, "deps: 11111111-2222-4333-8444-555555555555"), "summary must emit deps: cross-asset prefab GUID")

	dec_sf: engine.SceneFile
	uerr := engine.scene_file_unmarshal(bin, &dec_sf)
	testing.expect(t, uerr == nil, "scene_file_unmarshal must decode HTSCN001 cleanly")
	if uerr != nil do return
	defer engine.scene_file_destroy(&dec_sf)

	testing.expect_value(t, dec_sf.schema_version, sf.schema_version)
	testing.expect_value(t, dec_sf.root, sf.root)
	testing.expect_value(t, len(dec_sf.transforms), 1)
	testing.expect_value(t, dec_sf.transforms[0].name, "WatchWolfRoot")
	testing.expect_value(t, len(dec_sf.nested_scenes), 1)
	testing.expect(t, dec_sf.nested_scenes[0].source_prefab == prefab_guid, "prefab GUID round-trips bit-exact")
	testing.expect_value(t, len(dec_sf.breadcrumbs), 1)
	testing.expect_value(t, len(dec_sf.components), 1)

	// Flip 1 byte in payload -> CRC32 guard must reject cleanly without leaking.
	corrupt := make([]u8, len(bin), context.temp_allocator)
	copy(corrupt, bin)
	corrupt[len(corrupt) - 1] ~= 0x55
	corrupt_sf: engine.SceneFile
	testing.expect(t, !engine.scene_binary_decode(corrupt, &corrupt_sf), "CRC32 must reject 1-bit payload corruption")
	trunc_sf: engine.SceneFile
	testing.expect(t, !engine.scene_binary_decode(bin[:len(bin) - 4], &trunc_sf), "truncated payload must be rejected cleanly")
}

// 16. Verifies embedded Watch-Wolf mascot asset decodes as a valid 96x96 PNG.
@(test)
test_watch_wolf_png_asset_embedded_valid :: proc(t: ^testing.T) {
	png := widgets.watch_wolf_png_bytes()
	testing.expect(t, len(png) > 64, "watch_wolf_96.png bytes must be embedded non-empty")
	if len(png) < 8 do return
	sig := [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}
	testing.expect(t, mem.compare(png[:8], sig[:]) == 0, "embedded asset must start with valid PNG header")

	w, h, comp: i32
	ok := bool(stbi.info_from_memory(raw_data(png), i32(len(png)), &w, &h, &comp))
	testing.expect(t, ok, "stbi.info_from_memory must parse embedded Watch-Wolf PNG")
	testing.expect_value(t, w, 96)
	testing.expect_value(t, h, 96)
}

// 17. Verifies read-only protection blacklist rejects engine/editor/plugin paths while allowing project & user scripts.
@(test)
test_protected_readonly_script_blacklist :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	testing.expect(t, cs.is_protected_readonly_script_path("haati/engine/world.odin"), "haati/engine must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("C:/repo/Haati_Engine/haati/editor/main.odin"), "haati/editor must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("haati/hot_scripts/builtin_hot_scripts.odin"), "builtin_hot_scripts.odin must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("plugins/void_custom/foo.odin"), "plugins/ scripts must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("tools/haati/cli.odin"), "tools/ scripts must be read-only")

	testing.expect(t, !cs.is_protected_readonly_script_path("assets/scripts/player.bodin"), "user .bodin scripts must be editable")
	testing.expect(t, !cs.is_protected_readonly_script_path("C:/Projects/MyGame/player_cam.bodin"), "project .bodin scripts must be editable")
}

// 18. Verifies full-declaration Odin procedure extraction/splicing AND 3-tier smart pin/wire remapping.
@(test)
test_full_proc_extract_splice_and_smart_wire_remap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	src := `package test_pkg

import hot "haati:engine/hot_api"

// Draws happy clouds on canvas.
@(bp_node)
bobRoss :: proc(d: u8, z: string, a: f32) -> (ok: bool) {
	_ = d; _ = z; _ = a
	return true
}
`
	sliced, ok := cs.extract_full_odin_procedure_decl(src, "bobRoss", context.temp_allocator)
	testing.expect(t, ok, "extract_full_odin_procedure_decl must extract @(bp_node) + doc comment + proc decl")
	defer cs.destroy_proc_full_decl_slice(&sliced, context.temp_allocator)
	testing.expect(t, strings.contains(sliced.full_decl_text, "@(bp_node)"), "extracted full decl must include @(bp_node)")
	testing.expect(t, strings.contains(sliced.full_decl_text, "Draws happy clouds"), "extracted full decl must include leading doc comment")
	testing.expect_value(t, len(sliced.params), 3)
	testing.expect_value(t, len(sliced.results), 1)

	new_decl := `// Draws happy clouds and trees.
@(bp_node)
bobRoss :: proc(damage: u8, z: string, a: f32, bonus: f32) -> (ok: bool) {
	return damage > 0 && bonus >= 0
}`
	spliced, sp_ok := cs.splice_full_odin_procedure_decl(src, "bobRoss", new_decl, context.temp_allocator)
	testing.expect(t, sp_ok, "splice_full_odin_procedure_decl must replace procedure cleanly")
	testing.expect(t, strings.contains(spliced, "bonus: f32"), "spliced file must carry updated signature")
	testing.expect(t, !strings.contains(spliced, "d: u8"), "spliced file must replace old parameter list cleanly")

	// Smart 3-tier wire remapping on an Odin_Function_Node
	g: engine.Visual_Graph
	engine.vg_init_default_demo_graph(&g, "remap_test")
	defer engine.vg_destroy_graph(&g)

	init_uid := g.nodes[0].uid
	fn_uid   := engine.vg_add_node(&g, .Odin_Function_Node, {240, 140}, "bobRoss")
	fn_n     := engine.vg_find_node(&g, fn_uid)
	testing.expect(t, fn_n != nil, "Odin_Function_Node must spawn cleanly")
	if fn_n == nil do return

	ok_init, err_init := vs.apply_full_odin_proc_to_node(&g, fn_n, `bobRoss :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, d: u8, z: string) -> (ok: bool) {
	return d > 0
}`)
	testing.expect(t, ok_init && err_init == "", "initial full-decl apply must populate pins")
	testing.expect_value(t, len(fn_n.inputs), 3)  // Exec + d + z
	testing.expect_value(t, len(fn_n.outputs), 2) // Exec + ok

	// Connect Exec (0->0) and `d` input (pin 1) + `ok` output (pin 1)
	math_uid := engine.vg_add_node(&g, .Math_Float, {40, 260}, "Math")
	append(&g.wires, engine.VG_Wire{from_uid = init_uid, from_pin = 0, to_uid = fn_uid, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = math_uid, from_pin = 0, to_uid = fn_uid, to_pin = 1})

	// Rename `d: u8` -> `damage: u8` AND add `bonus: f32` -> Tier 2 slot+type match preserves wire on pin 1!
	ok_edit, err_edit := vs.apply_full_odin_proc_to_node(&g, fn_n, `bobRoss :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, damage: u8, z: string, bonus: f32) -> (ok: bool) {
	return damage > 0
}`)
	testing.expect(t, ok_edit && err_edit == "", "editing full proc decl must succeed")
	testing.expect_value(t, len(fn_n.inputs), 4) // Exec + damage + z + bonus
	testing.expect_value(t, fn_n.inputs[1].name, "damage")
	testing.expect_value(t, fn_n.inputs[3].name, "bonus")

	kept_d_wire := false
	for w in g.wires {
		if w.from_uid == math_uid && w.to_uid == fn_uid && w.to_pin == 1 {
			kept_d_wire = true
		}
	}
	testing.expect(t, kept_d_wire, "Tier-2 smart slot+type wire remap must preserve wire when `d: u8` is renamed `damage: u8`")
}

// 19. Verifies AST-backed `find_odin_proc_call_sites` ignores strings, line comments, block comments, and declarations.
@(test)
test_ast_proc_call_sites_ignores_comments_and_strings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	src := `package test_calls

bobRoss :: proc(a: int, s: string = "") {
	_ = a; _ = s
}

caller :: proc() {
	fake := "bobRoss(1)"
	// bobRoss(2)
	/* bobRoss(3) */
	bobRoss(4, "hi")
	pkg.bobRoss(5)
	_ = fake
}
`
	sites := cs.find_odin_proc_call_sites(src, "caller.odin", "bobRoss", context.temp_allocator)
	testing.expect_value(t, len(sites), 2)
	if len(sites) == 2 {
		testing.expect_value(t, sites[0].line, 11)
		testing.expect_value(t, sites[0].arg_count, 2)
		testing.expect_value(t, sites[1].line, 12)
		testing.expect_value(t, sites[1].arg_count, 1)
	}
}
