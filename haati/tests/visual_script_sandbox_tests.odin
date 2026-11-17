package tests

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../engine"
import "haati:engine/crash_journal"
import hot "haati:engine/hot_api"
import cs "haati:editor/code_studio"
import vs "haati:editor/visual_script"

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

// 4. Verifies universal all-type Slice (`[]Vec3`), Dynamic Array (`[dynamic]i32`),
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

// 5. Verifies `hot.validate_raw_ptr` pointer safety checks and `cs.predict_unsafe_odin_hazards`
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

// 6. Verifies in-process heap canary + NaN Transform scrubber (`visual_script_verify_and_repair_entity`).
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

// 7. Verifies full-declaration Odin procedure extraction/splicing AND 3-tier smart pin/wire remapping.
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

// 8. Verifies exporting a hybrid `.bodin` Blueprint script strips `@BODIN_GRAPH_V1` metadata
//    and writes a clean standalone `.odin` file beside it.
@(test)
test_ux_bodin_export_to_standalone_odin_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	tmp_dir, terr := os.temp_dir(context.temp_allocator)
	testing.expect(t, terr == nil, "os.temp_dir must succeed")
	bodin_p, _ := filepath.join({tmp_dir, "ux_roundtrip_test_bp.bodin"}, context.temp_allocator)
	exp_odin_p, _ := filepath.join({tmp_dir, "ux_roundtrip_test_bp.odin"}, context.temp_allocator)
	_ = os.remove(bodin_p)
	_ = os.remove(exp_odin_p)
	defer {
		_ = os.remove(bodin_p)
		_ = os.remove(exp_odin_p)
	}

	bodin_body := strings.concatenate({
		"package hot_scripts\n\nmy_bp_proc :: proc() -> int {\n\treturn 42\n}\n\n",
		engine.BODIN_GRAPH_BEGIN,
		"\n// {\"name\": \"ux_roundtrip_test_bp\"}\n",
		engine.BODIN_GRAPH_END,
		"\n",
	}, context.temp_allocator)
	werr := os.write_entire_file(bodin_p, transmute([]u8)bodin_body)
	testing.expect(t, werr == nil, "setup write of temp .bodin must succeed")

	out_odin, ok := vs.export_bodin_to_standalone_odin(bodin_p, context.temp_allocator)
	testing.expect(t, ok, "export_bodin_to_standalone_odin must succeed on valid .bodin")
	testing.expect(t, os.exists(out_odin), "exported .odin file must exist on disk")

	raw_out, rerr := os.read_entire_file(out_odin, context.temp_allocator)
	testing.expect(t, rerr == nil, "reading exported .odin must succeed")
	out_str := string(raw_out)
	testing.expect(t, strings.contains(out_str, "my_bp_proc :: proc() -> int"), "exported .odin must retain Odin procedures")
	testing.expect(t, !strings.contains(out_str, engine.BODIN_GRAPH_BEGIN), "exported .odin must strip embedded @BODIN_GRAPH_V1 block")
}

// 9. Verifies Blueprint `.Delegate` pin drop target collection gathers local
//    `.Custom_Proc_Entry` events and `@(hot_proc)` targets and filters cleanly by query.
@(test)
test_blueprint_delegate_pin_collect_bind_targets :: proc(t: ^testing.T) {
	g: engine.Visual_Graph
	g.name = strings.clone("delegate_target_test_bp")
	defer engine.vg_destroy_graph(&g)

	append(&g.nodes, engine.VG_Node{
		uid             = 10,
		kind            = .Custom_Proc_Entry,
		title           = strings.clone("On Custom Jump"),
		hot_proc_target = strings.clone("On_Custom_Jump"),
	})
	append(&g.nodes, engine.VG_Node{
		uid             = 11,
		kind            = .Custom_Proc_Entry,
		title           = strings.clone("On Dash Start"),
		hot_proc_target = strings.clone("On_Dash_Start"),
	})

	extra := [?]string{"play_explosion_vfx", "apply_damage"}

	all_targets := vs.collect_delegate_pin_bind_targets(&g, "", extra[:], context.temp_allocator)
	has_jump := false
	has_dash := false
	has_vfx := false
	for tgt in all_targets {
		if tgt.kind == .Custom_Event && tgt.name == "On_Custom_Jump" && tgt.node_uid == 10 do has_jump = true
		if tgt.kind == .Custom_Event && tgt.name == "On_Dash_Start" && tgt.node_uid == 11 do has_dash = true
		if tgt.kind == .Hot_Proc && tgt.name == "play_explosion_vfx" do has_vfx = true
	}
	testing.expect(t, has_jump, "expected On_Custom_Jump custom event target")
	testing.expect(t, has_dash, "expected On_Dash_Start custom event target")
	testing.expect(t, has_vfx, "expected extra hot_proc target play_explosion_vfx")

	jump_only := vs.collect_delegate_pin_bind_targets(&g, "jump", extra[:], context.temp_allocator)
	testing.expect(t, len(jump_only) >= 1, "expected query 'jump' to match On_Custom_Jump")
	for tgt in jump_only {
		testing.expect(t, strings.contains(strings.to_lower(tgt.name, context.temp_allocator), "jump"), "filtered targets must match query")
	}

	vfx_only := vs.collect_delegate_pin_bind_targets(&g, "explosion", extra[:], context.temp_allocator)
	found_vfx := false
	for tgt in vfx_only {
		if tgt.kind == .Hot_Proc && tgt.name == "play_explosion_vfx" do found_vfx = true
	}
	testing.expect(t, found_vfx, "expected query 'explosion' to return play_explosion_vfx")
}

// 10. Verifies Unified Graph Studio domains (`Anim_Motion`, `Particle_VFX`), Tier-1 live evaluation,
//     Tier-2 Data-Oriented `.bodin` Odin transpilation of Motion & GPU VFX nodes, AND legacy Unicode
//     pin-name sanitization (`◇` / `▷` stripped cleanly on load so `? ? Delegate` never appears)!
@(test)
test_unified_graph_studio_domains_transpiler_and_pin_sanitization :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	g: engine.Visual_Graph
	g.name           = strings.clone("unit_unified_motion_vfx")
	g.domain         = .Anim_Motion
	g.package_target = strings.clone("haati/hot_scripts")
	engine.vg_ensure_default_spaces(&g)
	defer engine.vg_destroy_graph(&g)

	append(&g.variables, engine.VG_Var_Decl{
		name        = strings.clone("blended_pose"),
		pin_type    = .Float,
		default_f32 = 0.0,
	})

	u_tick   := engine.vg_add_node(&g, .Event_Tick,          {0, 0})
	u_clip   := engine.vg_add_node(&g, .Anim_Clip_Eval,      {220, 0})
	u_blend  := engine.vg_add_node(&g, .Anim_Blend_Layered,  {440, 0})
	u_spring := engine.vg_add_node(&g, .Anim_Spring_Damper,  {660, 0})
	u_set    := engine.vg_add_node(&g, .Set_Variable,        {880, 0}, "blended_pose")
	u_ik     := engine.vg_add_node(&g, .Anim_IK_Target,      {1100, 0})
	u_vfx_sp := engine.vg_add_node(&g, .VFX_Emitter_Spawn,   {1320, 0})
	u_curl   := engine.vg_add_node(&g, .VFX_GPU_Curl_Force,  {880, 220})
	u_life   := engine.vg_add_node(&g, .VFX_Color_Size_Life, {880, 360})

	if nb := engine.vg_find_node(&g, u_blend); nb != nil && len(nb.inputs) >= 3 {
		nb.inputs[0].default_f32 = 0.20
		nb.inputs[1].default_f32 = 0.80
		nb.inputs[2].default_f32 = 0.50
	}
	if ns := engine.vg_find_node(&g, u_spring); ns != nil && len(ns.inputs) >= 3 {
		ns.inputs[0].default_f32 = 0.00
		ns.inputs[2].default_f32 = 20.0
	}
	if nc := engine.vg_find_node(&g, u_clip); nc != nil && len(nc.outputs) > 0 {
		delete(nc.outputs[0].name)
		nc.outputs[0].name = strings.clone("\u25c7 Pose Weight")
	}

	append(&g.wires, engine.VG_Wire{from_uid = u_tick, from_pin = 0, to_uid = u_set,    to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_set,  from_pin = 0, to_uid = u_ik,     to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_ik,   from_pin = 0, to_uid = u_vfx_sp, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_blend,  from_pin = 0, to_uid = u_spring, to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_spring, from_pin = 0, to_uid = u_set,    to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_curl, from_pin = 0, to_uid = u_ik,     to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_life, from_pin = 0, to_uid = u_vfx_sp, to_pin = 1})

	ent := engine.transform_new("UnifiedMotionEntity")
	bb: engine.VG_Runtime_Blackboard
	defer delete(bb.last_exec_path)
	engine.vg_eval_graph_live(&g, &bb, ent, 0.05)
	testing.expect(t, bb.initialized && bb.slots[0].val_f32 > 0.25 && bb.slots[0].val_f32 <= 0.50, "expected Tier-1 live Blend+Spring evaluation to advance blended_pose toward 0.5")

	odin_code, main_proc := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect_value(t, main_proc, "mhgraph_unit_unified_motion_vfx")
	testing.expect(t, strings.contains(odin_code, "math.lerp("), "expected Anim_Blend_Layered / VFX_Color_Size_Life math.lerp emission")
	testing.expect(t, strings.contains(odin_code, "hot.damp_f32("), "expected Anim_Spring_Damper hot.damp_f32 emission")

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_abs, _ := filepath.join({repo_root, fmt.tprintf("assets/scripts/_tmp_unified_%d.bodin", os.get_pid())}, context.temp_allocator)
	testing.expect(t, engine.vg_save_bodin_file(&g, tmp_abs, odin_code), "expected .bodin save to succeed")
	defer _ = os.remove(tmp_abs)

	loaded: engine.Visual_Graph
	defer engine.vg_destroy_graph(&loaded)
	testing.expect(t, engine.vg_load_from_file(&loaded, tmp_abs), "expected .bodin load to succeed")
	testing.expect_value(t, loaded.domain, engine.VG_Graph_Domain.Anim_Motion)
	if lc := engine.vg_find_node(&loaded, u_clip); lc != nil && len(lc.outputs) > 0 {
		testing.expect_value(t, lc.outputs[0].name, "Pose Weight")
	}
}
