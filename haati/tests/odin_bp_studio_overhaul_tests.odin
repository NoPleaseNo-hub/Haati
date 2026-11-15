package tests

import "../engine"
import hot "haati:engine/hot_api"
import thm "haati:editor/theme"
import vs "haati:editor/visual_script"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

_v6_wire :: proc(g: ^engine.Visual_Graph, from_uid, from_pin, to_uid, to_pin: int) {
	append(&g.wires, engine.VG_Wire{
		from_uid = from_uid,
		from_pin = from_pin,
		to_uid   = to_uid,
		to_pin   = to_pin,
	})
}

_v6_var_decl :: proc(g: ^engine.Visual_Graph, name: string, pt: hot.Hot_Pin_Type, custom_type: string = "") -> int {
	v := engine.VG_Var_Decl{
		name             = strings.clone(name),
		pin_type         = pt,
		custom_type_name = custom_type != "" ? strings.clone(custom_type) : "",
	}
	append(&g.variables, v)
	return len(g.variables) - 1
}

_v6_node_set_var :: proc(g: ^engine.Visual_Graph, var_name: string, val_pt: hot.Hot_Pin_Type, pos: [2]f32) -> int {
	uid := engine.vg_add_node(g, .Set_Variable, pos, var_name)
	if n := engine.vg_find_node(g, uid); n != nil && len(n.inputs) >= 2 {
		n.inputs[1].pin_type = val_pt
	}
	return uid
}

_v6_node_get_var :: proc(g: ^engine.Visual_Graph, var_name: string, val_pt: hot.Hot_Pin_Type, pos: [2]f32) -> int {
	uid := engine.vg_add_node(g, .Get_Variable, pos, var_name)
	if n := engine.vg_find_node(g, uid); n != nil && len(n.outputs) >= 1 {
		n.outputs[0].pin_type = val_pt
	}
	return uid
}

_v6_sync_entity_bb :: proc(g: ^engine.Visual_Graph, tH: engine.Transform_Handle) -> ^engine.VG_Runtime_Blackboard {
	_ = engine.visual_script_get_entity_var_ptr(tH, 0)
	bb := engine.visual_script_get_entity_bb(tH)
	engine.vg_sync_blackboard(g, bb)
	return bb
}

@(test)
test_bp_v6_exact_bitwidths_and_autocast :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()

	g: engine.Visual_Graph
	g.name = strings.clone("v6_bitwidth_autocast")
	defer engine.vg_destroy_graph(&g)

	// 1. Verify exact bit-width sizes & alignments
	sz, al := engine.vg_scalar_type_size(&g, .U8)
	testing.expect(t, sz == 1 && al == 1, "U8 must be 1 byte aligned to 1")
	sz, al = engine.vg_scalar_type_size(&g, .I8)
	testing.expect(t, sz == 1 && al == 1, "I8 must be 1 byte aligned to 1")
	sz, al = engine.vg_scalar_type_size(&g, .U16)
	testing.expect(t, sz == 2 && al == 2, "U16 must be 2 bytes aligned to 2")
	sz, al = engine.vg_scalar_type_size(&g, .I16)
	testing.expect(t, sz == 2 && al == 2, "I16 must be 2 bytes aligned to 2")
	sz, al = engine.vg_scalar_type_size(&g, .U32)
	testing.expect(t, sz == 4 && al == 4, "U32 must be 4 bytes aligned to 4")
	sz, al = engine.vg_scalar_type_size(&g, .U64)
	testing.expect(t, sz == 8 && al == 8, "U64 must be 8 bytes aligned to 8")
	sz, al = engine.vg_scalar_type_size(&g, .F64)
	testing.expect(t, sz == 8 && al == 8, "F64 must be 8 bytes aligned to 8")
	sz, al = engine.vg_scalar_type_size(&g, .Enum_U8)
	testing.expect(t, sz == 1 && al == 1, "Enum_U8 must be 1 byte aligned to 1")
	sz, al = engine.vg_scalar_type_size(&g, .BitSet_U8)
	testing.expect(t, sz == 1 && al == 1, "BitSet_U8 must be 1 byte aligned to 1")

	// 2. Verify pin auto-cast rules
	direct_ok, needs_cast, _ := engine.vg_can_connect_or_autocast_pins(
		engine.VG_Pin_Def{pin_type = .U8},
		engine.VG_Pin_Def{pin_type = .Float},
	)
	testing.expect(t, !direct_ok && needs_cast, "U8 -> Float must offer Auto_Cast")

	direct_ok, needs_cast, _ = engine.vg_can_connect_or_autocast_pins(
		engine.VG_Pin_Def{pin_type = .Vec3},
		engine.VG_Pin_Def{pin_type = .Vec2},
	)
	testing.expect(t, !direct_ok && needs_cast, "Vec3 -> Vec2 must offer Auto_Cast")

	direct_ok, needs_cast, _ = engine.vg_can_connect_or_autocast_pins(
		engine.VG_Pin_Def{pin_type = .Int},
		engine.VG_Pin_Def{pin_type = .Int},
	)
	testing.expect(t, direct_ok && !needs_cast, "Int -> Int must connect directly without Auto_Cast")

	// 3. Evaluate Auto_Cast in Tier-1 VM: u8 -> f32 and Vec3 -> Vec2
	i_u8 := _v6_var_decl(&g, "raw_u8", .U8)
	g.variables[i_u8].default_u64 = 200
	_v6_var_decl(&g, "cast_f32", .Float)
	i_v3 := _v6_var_decl(&g, "src_v3", .Vec3)
	g.variables[i_v3].default_vec3 = {3.5, 7.25, 9.0}
	_v6_var_decl(&g, "cast_v2", .Vec2)

	evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
	get_u8 := _v6_node_get_var(&g, "raw_u8", .U8, {100, 0})

	cast_uf := engine.vg_add_node(&g, .Auto_Cast, {200, 0})
	n_uf := engine.vg_find_node(&g, cast_uf)
	n_uf.inputs[0].pin_type = .U8
	n_uf.outputs[0].pin_type = .Float

	set_f32 := _v6_node_set_var(&g, "cast_f32", .Float, {320, 0})

	get_v3 := _v6_node_get_var(&g, "src_v3", .Vec3, {200, 120})
	cast_v32 := engine.vg_add_node(&g, .Auto_Cast, {320, 120})
	n_v32 := engine.vg_find_node(&g, cast_v32)
	n_v32.inputs[0].pin_type = .Vec3
	n_v32.outputs[0].pin_type = .Vec2
	set_v2 := _v6_node_set_var(&g, "cast_v2", .Vec2, {440, 120})

	_v6_wire(&g, get_u8, 0, cast_uf, 0)
	_v6_wire(&g, cast_uf, 0, set_f32, 1)
	_v6_wire(&g, get_v3, 0, cast_v32, 0)
	_v6_wire(&g, cast_v32, 0, set_v2, 1)
	_v6_wire(&g, evt, 0, set_f32, 0)
	_v6_wire(&g, set_f32, 0, set_v2, 0)

	tH := engine.transform_new("bp_v6_bitwidth_ent")
	bb := _v6_sync_entity_bb(&g, tH)
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

	f32_idx := engine.vg_find_var_index(&g, "cast_f32")
	v2_idx := engine.vg_find_var_index(&g, "cast_v2")
	testing.expect(t, math.abs(bb.slots[f32_idx].val_f32 - 200.0) < 0.001, "Auto_Cast U8(200) -> Float should equal 200.0")
	testing.expect(t, math.abs(bb.slots[v2_idx].val_vec2.x - 3.5) < 0.001 && math.abs(bb.slots[v2_idx].val_vec2.y - 7.25) < 0.001, "Auto_Cast Vec3 -> Vec2 should preserve XY")

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "u8"), "Transpiler output must preserve u8 type")
	testing.expect(t, strings.contains(odin_src, "f32(") && strings.contains(odin_src, "[2]f32"), "Transpiler output must emit Auto_Cast conversion")
}

@(test)
test_bp_v6_enum_u8_bitset_and_exhaustive_switch :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()

	g: engine.Visual_Graph
	g.name = strings.clone("v6_enum_bitset_switch")
	defer engine.vg_destroy_graph(&g)

	ed := engine.VG_Enum_Decl{
		name = strings.clone("Move_Flag"),
	}
	append(&ed.variants, strings.clone("Idle"), strings.clone("Walk"), strings.clone("Dash"))
	append(&g.enums, ed)

	_v6_var_decl(&g, "flags", .BitSet_U8, "Move_Flag")
	i_mode := _v6_var_decl(&g, "mode", .Enum_U8, "Move_Flag")
	g.variables[i_mode].default_u64 = 1 // Walk
	_v6_var_decl(&g, "has_walk", .Bool)
	_v6_var_decl(&g, "is_empty_end", .Bool)
	_v6_var_decl(&g, "branch_hit", .Int)

	evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
	get_flags_1 := _v6_node_get_var(&g, "flags", .BitSet_U8, {50, 0})
	set_flags_1 := _v6_node_set_var(&g, "flags", .BitSet_U8, {350, 0})

	// Set Walk (bit 1)
	bs_set := engine.vg_add_node(&g, .BitSet_Op, {180, 0})
	n_bs_set := engine.vg_find_node(&g, bs_set)
	engine.vg_configure_bitset_op(&g, n_bs_set, .Set_Flag, "Move_Flag")
	n_bs_set.inputs[2].default_u64 = 1

	// Has_Flag Walk -> Bool var
	get_flags_2 := _v6_node_get_var(&g, "flags", .BitSet_U8, {350, 120})
	bs_has := engine.vg_add_node(&g, .BitSet_Op, {480, 120})
	n_bs_has := engine.vg_find_node(&g, bs_has)
	engine.vg_configure_bitset_op(&g, n_bs_has, .Has_Flag, "Move_Flag")
	n_bs_has.inputs[1].default_u64 = 1
	set_has := _v6_node_set_var(&g, "has_walk", .Bool, {620, 0})

	// Toggle Dash (bit 2 -> bits 1|2), Toggle Walk (bit 1 -> bit 2), Clear Dash (bit 2 -> 0)
	bs_tog_dash := engine.vg_add_node(&g, .BitSet_Op, {760, 0})
	n_td := engine.vg_find_node(&g, bs_tog_dash)
	engine.vg_configure_bitset_op(&g, n_td, .Toggle_Flag, "Move_Flag")
	n_td.inputs[2].default_u64 = 2
	set_flags_2 := _v6_node_set_var(&g, "flags", .BitSet_U8, {900, 0})

	bs_tog_walk := engine.vg_add_node(&g, .BitSet_Op, {1040, 0})
	n_tw := engine.vg_find_node(&g, bs_tog_walk)
	engine.vg_configure_bitset_op(&g, n_tw, .Toggle_Flag, "Move_Flag")
	n_tw.inputs[2].default_u64 = 1
	set_flags_3 := _v6_node_set_var(&g, "flags", .BitSet_U8, {1180, 0})

	bs_clr_dash := engine.vg_add_node(&g, .BitSet_Op, {1320, 0})
	n_cd := engine.vg_find_node(&g, bs_clr_dash)
	engine.vg_configure_bitset_op(&g, n_cd, .Clear_Flag, "Move_Flag")
	n_cd.inputs[2].default_u64 = 2
	set_flags_4 := _v6_node_set_var(&g, "flags", .BitSet_U8, {1460, 0})

	// Is_Empty check
	get_flags_end := _v6_node_get_var(&g, "flags", .BitSet_U8, {1460, 120})
	bs_empty := engine.vg_add_node(&g, .BitSet_Op, {1600, 120})
	n_em := engine.vg_find_node(&g, bs_empty)
	engine.vg_configure_bitset_op(&g, n_em, .Is_Empty, "Move_Flag")
	set_empty := _v6_node_set_var(&g, "is_empty_end", .Bool, {1740, 0})

	// Switch_Value on `mode`
	get_mode := _v6_node_get_var(&g, "mode", .Enum_U8, {1740, 220})
	sw := engine.vg_add_node(&g, .Switch_Value, {1900, 0})
	n_sw := engine.vg_find_node(&g, sw)
	engine.vg_configure_switch_node(&g, n_sw, "Move_Flag")

	set_hit_0 := _v6_node_set_var(&g, "branch_hit", .Int, {2100, -100})
	engine.vg_find_node(&g, set_hit_0).inputs[1].default_int = 100
	set_hit_1 := _v6_node_set_var(&g, "branch_hit", .Int, {2100, 0})
	engine.vg_find_node(&g, set_hit_1).inputs[1].default_int = 200
	set_hit_2 := _v6_node_set_var(&g, "branch_hit", .Int, {2100, 100})
	engine.vg_find_node(&g, set_hit_2).inputs[1].default_int = 300
	set_hit_def := _v6_node_set_var(&g, "branch_hit", .Int, {2100, 200})
	engine.vg_find_node(&g, set_hit_def).inputs[1].default_int = -1

	_v6_wire(&g, evt, 0, bs_set, 0)
	_v6_wire(&g, get_flags_1, 0, bs_set, 1)
	_v6_wire(&g, bs_set, 0, set_flags_1, 0)
	_v6_wire(&g, bs_set, 1, set_flags_1, 1)

	_v6_wire(&g, get_flags_2, 0, bs_has, 0)
	_v6_wire(&g, set_flags_1, 0, set_has, 0)
	_v6_wire(&g, bs_has, 0, set_has, 1)

	_v6_wire(&g, set_has, 0, bs_tog_dash, 0)
	_v6_wire(&g, get_flags_2, 0, bs_tog_dash, 1)
	_v6_wire(&g, bs_tog_dash, 0, set_flags_2, 0)
	_v6_wire(&g, bs_tog_dash, 1, set_flags_2, 1)

	_v6_wire(&g, set_flags_2, 0, bs_tog_walk, 0)
	_v6_wire(&g, get_flags_2, 0, bs_tog_walk, 1)
	_v6_wire(&g, bs_tog_walk, 0, set_flags_3, 0)
	_v6_wire(&g, bs_tog_walk, 1, set_flags_3, 1)

	_v6_wire(&g, set_flags_3, 0, bs_clr_dash, 0)
	_v6_wire(&g, get_flags_2, 0, bs_clr_dash, 1)
	_v6_wire(&g, bs_clr_dash, 0, set_flags_4, 0)
	_v6_wire(&g, bs_clr_dash, 1, set_flags_4, 1)

	_v6_wire(&g, get_flags_end, 0, bs_empty, 0)
	_v6_wire(&g, set_flags_4, 0, set_empty, 0)
	_v6_wire(&g, bs_empty, 0, set_empty, 1)

	_v6_wire(&g, set_empty, 0, sw, 0)
	_v6_wire(&g, get_mode, 0, sw, 1)
	_v6_wire(&g, sw, 0, set_hit_0, 0)
	_v6_wire(&g, sw, 1, set_hit_1, 0)
	_v6_wire(&g, sw, 2, set_hit_2, 0)
	_v6_wire(&g, sw, 3, set_hit_def, 0)

	tH := engine.transform_new("bp_v6_enum_ent")
	bb := _v6_sync_entity_bb(&g, tH)
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "has_walk")].val_bool == true, "Set_Flag(Walk) + Has_Flag(Walk) must be true")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "is_empty_end")].val_bool == true, "Clear_Flag after toggles must leave bitset empty")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "branch_hit")].val_int == 200, "Switch_Value on Walk(1) must hit case 1 (200)")

	mode_idx := engine.vg_find_var_index(&g, "mode")
	bb.slots[mode_idx].val_u8 = 99
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "branch_hit")].val_int == -1, "Switch_Value out-of-range must hit Default branch (-1)")

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "enum u8"), "Transpiler must emit enum u8 declaration")
	testing.expect(t, strings.contains(odin_src, "bit_set["), "Transpiler must emit bit_set declaration")
	testing.expect(t, strings.contains(odin_src, "switch "), "Transpiler must emit Odin switch statement")
}

@(test)
test_bp_v6_pod_structs_using_and_pin_splitting :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()

	g: engine.Visual_Graph
	g.name = strings.clone("v6_structs_split")
	defer engine.vg_destroy_graph(&g)

	hdr := engine.VG_Struct_Decl{name = strings.clone("Entity_Header")}
	append(&hdr.fields,
		engine.VG_Struct_Field{name = strings.clone("id"), pin_type = .U32},
		engine.VG_Struct_Field{name = strings.clone("active"), pin_type = .Bool},
	)
	append(&g.structs, hdr)

	stats := engine.VG_Struct_Decl{
		name              = strings.clone("Player_Stats"),
		using_parent_name = strings.clone("Entity_Header"),
	}
	append(&stats.fields,
		engine.VG_Struct_Field{name = strings.clone("hp"), pin_type = .Float},
		engine.VG_Struct_Field{name = strings.clone("stamina"), pin_type = .U16},
	)
	append(&g.structs, stats)

	fields, total_sz, total_align := engine.vg_struct_layout(&g, "Player_Stats", context.temp_allocator)
	testing.expect(t, len(fields) == 4, "Flattened using layout of Player_Stats must have 4 fields")
	testing.expect(t, total_sz >= 12 && total_align >= 4, "Flattened struct size/align must cover u32 + bool + f32 + u16")
	testing.expect(t, fields[0].name == "id" && fields[1].name == "active" && fields[2].name == "hp" && fields[3].name == "stamina", "using parent fields must precede child fields")

	_v6_var_decl(&g, "out_id", .U32)
	_v6_var_decl(&g, "out_active", .Bool)
	_v6_var_decl(&g, "out_hp", .Float)
	_v6_var_decl(&g, "out_stam", .U16)

	evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
	mk := engine.vg_add_node(&g, .Make_Struct, {100, 0}, "Player_Stats")
	n_mk := engine.vg_find_node(&g, mk)
	n_mk.inputs[0].default_u64 = 42
	n_mk.inputs[1].default_bool = true
	n_mk.inputs[2].default_f32 = 87.5
	n_mk.inputs[3].default_u64 = 250

	brk := engine.vg_add_node(&g, .Break_Struct, {300, 0}, "Player_Stats")

	s0 := _v6_node_set_var(&g, "out_id", .U32, {500, -90})
	s1 := _v6_node_set_var(&g, "out_active", .Bool, {500, 0})
	s2 := _v6_node_set_var(&g, "out_hp", .Float, {500, 90})
	s3 := _v6_node_set_var(&g, "out_stam", .U16, {500, 180})

	_v6_wire(&g, mk, 0, brk, 0)
	_v6_wire(&g, brk, 0, s0, 1)
	_v6_wire(&g, brk, 1, s1, 1)
	_v6_wire(&g, brk, 2, s2, 1)
	_v6_wire(&g, brk, 3, s3, 1)
	_v6_wire(&g, evt, 0, s0, 0)
	_v6_wire(&g, s0, 0, s1, 0)
	_v6_wire(&g, s1, 0, s2, 0)
	_v6_wire(&g, s2, 0, s3, 0)

	tH := engine.transform_new("bp_v6_struct_ent")
	bb := _v6_sync_entity_bb(&g, tH)
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "out_id")].val_u32 == 42, "Struct round-trip u32 id must equal 42")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "out_active")].val_bool == true, "Struct round-trip bool active must equal true")
	testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "out_hp")].val_f32 - 87.5) < 0.001, "Struct round-trip f32 hp must equal 87.5")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "out_stam")].val_u16 == 250, "Struct round-trip u16 stamina must equal 250")

	// Inline pin splitting & recombination on Vec3 pin (Set_Transform_Pos input 1) and Make_Struct output 0
	st_pos := engine.vg_add_node(&g, .Set_Transform_Pos, {0, 300})
	testing.expect(t, engine.vg_split_pin_inline(&g, st_pos, false, 1), "Splitting Vec3 input pin must succeed")
	n_stpos := engine.vg_find_node(&g, st_pos)
	testing.expect(t, len(n_stpos.inputs) == 5, "Split Vec3 input pin must append 3 Float sub-pins (total 5 inputs)")
	testing.expect(t, engine.vg_recombine_split_pin(&g, st_pos, false, 1), "Recombining split Vec3 sub-pins must succeed")
	testing.expect(t, len(n_stpos.inputs) == 2 && n_stpos.inputs[1].pin_type == .Vec3, "Recombined node must restore original 2 inputs")

	testing.expect(t, engine.vg_split_pin_inline(&g, mk, true, 0), "Splitting Struct_Val output pin must succeed")
	n_mk_after := engine.vg_find_node(&g, mk)
	testing.expect(t, len(n_mk_after.outputs) == 5, "Split Player_Stats pin must expose 4 sub-pins alongside collapsed parent")
	testing.expect(t, engine.vg_recombine_split_pin(&g, mk, true, 0), "Recombining split Struct_Val sub-pins must succeed")
	testing.expect(t, len(n_mk_after.outputs) == 1 && n_mk_after.outputs[0].pin_type == .Struct_Val, "Recombined output must restore single Struct_Val pin")

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "Entity_Header :: struct"), "Transpiler must emit Entity_Header struct")
	testing.expect(t, strings.contains(odin_src, "using _base: Entity_Header"), "Transpiler must emit `using _base: Entity_Header` inside Player_Stats")
}

@(test)
test_bp_v6_fixed_8_lock_and_bounded_array :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()

	g: engine.Visual_Graph
	g.name = strings.clone("v6_arrays")
	defer engine.vg_destroy_graph(&g)

	v_legacy := engine.VG_Var_Decl{name = strings.clone("legacy_arr"), pin_type = .Float, is_array = true, array_count = 0, array_is_bounded = false}
	v_fixed := engine.VG_Var_Decl{name = strings.clone("bytes_16"), pin_type = .U8, is_array = true, array_count = 16, array_is_bounded = false}
	v_bounded := engine.VG_Var_Decl{name = strings.clone("scores"), pin_type = .Float, is_array = true, array_count = 8, array_is_bounded = true}
	append(&g.variables, v_legacy, v_fixed, v_bounded)

	testing.expect(t, engine.vg_var_odin_type_ex(&g, g.variables[0]) == "[8]f32", "Legacy array_count==0 must lock to [8]f32")
	testing.expect(t, engine.vg_var_odin_type_ex(&g, g.variables[1]) == "[16]u8", "Fixed [16]u8 must format properly")
	testing.expect(t, engine.vg_var_odin_type_ex(&g, g.variables[2]) == "BP_Bounded_f32_8", "Bounded array must use BP_Bounded_f32_8")

	_v6_var_decl(&g, "arr_len", .Int)
	_v6_var_decl(&g, "arr_elem_1", .Float)
	_v6_var_decl(&g, "pop_val", .Float)
	_v6_var_decl(&g, "pop_ok", .Bool)

	evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
	op_app1 := engine.vg_add_node(&g, .Array_Op, {100, 0})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_app1), .Append, "scores")
	engine.vg_find_node(&g, op_app1).inputs[1].default_f32 = 10.0

	op_app2 := engine.vg_add_node(&g, .Array_Op, {240, 0})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_app2), .Append, "scores")
	engine.vg_find_node(&g, op_app2).inputs[1].default_f32 = 20.0

	op_app3 := engine.vg_add_node(&g, .Array_Op, {380, 0})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_app3), .Append, "scores")
	engine.vg_find_node(&g, op_app3).inputs[1].default_f32 = 30.0

	op_len := engine.vg_add_node(&g, .Array_Op, {520, 120})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_len), .Len, "scores")
	set_len := _v6_node_set_var(&g, "arr_len", .Int, {640, 0})

	op_get := engine.vg_add_node(&g, .Array_Op, {760, 120})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_get), .Get_Copy, "scores")
	engine.vg_find_node(&g, op_get).inputs[0].default_int = 1
	set_elem := _v6_node_set_var(&g, "arr_elem_1", .Float, {880, 0})

	op_swap := engine.vg_add_node(&g, .Array_Op, {1020, 0})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_swap), .Swap_Remove, "scores")
	engine.vg_find_node(&g, op_swap).inputs[1].default_int = 0

	op_pop := engine.vg_add_node(&g, .Array_Op, {1180, 0})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_pop), .Pop, "scores")
	set_pv := _v6_node_set_var(&g, "pop_val", .Float, {1320, 0})
	set_pok := _v6_node_set_var(&g, "pop_ok", .Bool, {1460, 0})

	op_clr := engine.vg_add_node(&g, .Array_Op, {1600, 0})
	engine.vg_configure_array_op(&g, engine.vg_find_node(&g, op_clr), .Clear, "scores")

	_v6_wire(&g, evt, 0, op_app1, 0)
	_v6_wire(&g, op_app1, 0, op_app2, 0)
	_v6_wire(&g, op_app2, 0, op_app3, 0)
	_v6_wire(&g, op_app3, 0, set_len, 0)
	_v6_wire(&g, op_len, 0, set_len, 1)
	_v6_wire(&g, set_len, 0, set_elem, 0)
	_v6_wire(&g, op_get, 0, set_elem, 1)
	_v6_wire(&g, set_elem, 0, op_swap, 0)
	_v6_wire(&g, op_swap, 0, op_pop, 0)
	_v6_wire(&g, op_pop, 0, set_pv, 0)
	_v6_wire(&g, op_pop, 1, set_pv, 1)
	_v6_wire(&g, set_pv, 0, set_pok, 0)
	_v6_wire(&g, op_pop, 2, set_pok, 1)
	_v6_wire(&g, set_pok, 0, op_clr, 0)

	tH := engine.transform_new("bp_v6_arr_ent")
	bb := _v6_sync_entity_bb(&g, tH)
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "arr_len")].val_int == 3, "Bounded array Len after 3 Appends must be 3")
	testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "arr_elem_1")].val_f32 - 20.0) < 0.001, "Get_Copy(1) must be 20.0")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "pop_ok")].val_bool == true, "Pop after Swap_Remove must succeed")
	testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "pop_val")].val_f32 - 20.0) < 0.001, "Pop after Swap_Remove(0) on [10,20,30] leaves [30,20], popping 20.0")

	scores_idx := engine.vg_find_var_index(&g, "scores")
	cnt_off := engine.vg_bounded_array_count_offset(&g, g.variables[scores_idx])
	blob := bb.var_blobs["scores"]
	testing.expect(t, len(blob) >= cnt_off + 4, "Bounded array blob must include trailing count i32")
	cur_cnt := (^i32)(&blob[cnt_off])^
	testing.expect(t, cur_cnt == 0, "Clear must reset bounded array count to 0")

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "[8]f32") && strings.contains(odin_src, "[16]u8") && strings.contains(odin_src, "BP_Bounded_f32_8"), "Transpiler must emit [8]f32, [16]u8, and BP_Bounded_f32_8")
}

@(test)
test_bp_v6_universal_for_loop_modes_reverse_break_continue_and_fuse :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()

	// Part A: Range_Inclusive (1..=5 => sum 15), Range_Half_Open with Continue_Loop & Break_Loop (=> sum 4), #reverse For_In_Value (=> 321), For_In_Ref
	{
		g: engine.Visual_Graph
		g.name = strings.clone("v6_for_modes")
		defer engine.vg_destroy_graph(&g)

		_v6_var_decl(&g, "sum_inc", .Float)
		_v6_var_decl(&g, "sum_ho", .Float)
		_v6_var_decl(&g, "rev_acc", .Float)
		append(&g.variables, engine.VG_Var_Decl{name = strings.clone("items"), pin_type = .Int, is_array = true, array_count = 4, array_is_bounded = true})

		evt := engine.vg_add_node(&g, .Event_Init, {0, 0})

		// Loop 1: Range_Inclusive 1..=5 -> sum_inc += f32(idx)
		fl1 := engine.vg_add_node(&g, .For_Loop, {100, 0})
		n1 := engine.vg_find_node(&g, fl1)
		engine.vg_configure_for_loop(&g, n1, .Range_Inclusive, "")
		n1.inputs[1].default_int = 1
		n1.inputs[2].default_int = 5

		c1_f := engine.vg_add_node(&g, .Auto_Cast, {200, 40})
		engine.vg_find_node(&g, c1_f).inputs[0].pin_type = .Int
		engine.vg_find_node(&g, c1_f).outputs[0].pin_type = .Float
		get_s1 := _v6_node_get_var(&g, "sum_inc", .Float, {240, -60})
		add_1 := engine.vg_add_node(&g, .Math_Float, {340, -20})
		engine.vg_find_node(&g, add_1).math_op = .Add
		set_s1 := _v6_node_set_var(&g, "sum_inc", .Float, {460, -20})

		_v6_wire(&g, evt, 0, fl1, 0)
		_v6_wire(&g, fl1, 1, c1_f, 0)
		_v6_wire(&g, fl1, 0, set_s1, 0)
		_v6_wire(&g, get_s1, 0, add_1, 0)
		_v6_wire(&g, c1_f, 0, add_1, 1)
		_v6_wire(&g, add_1, 0, set_s1, 1)

		// Loop 2: Range_Half_Open 0..<5; if idx == 2 -> Continue_Loop; if idx == 4 -> Break_Loop; else sum_ho += idx (0+1+3 = 4)
		fl2 := engine.vg_add_node(&g, .For_Loop, {600, 0})
		n2 := engine.vg_find_node(&g, fl2)
		engine.vg_configure_for_loop(&g, n2, .Range_Half_Open, "")
		n2.inputs[1].default_int = 0
		n2.inputs[2].default_int = 5

		c2_f := engine.vg_add_node(&g, .Auto_Cast, {680, 80})
		engine.vg_find_node(&g, c2_f).inputs[0].pin_type = .Int
		engine.vg_find_node(&g, c2_f).outputs[0].pin_type = .Float

		sub_2 := engine.vg_add_node(&g, .Math_Float, {760, -100})
		engine.vg_find_node(&g, sub_2).math_op = .Sub
		engine.vg_find_node(&g, sub_2).inputs[1].default_f32 = 2.0
		c_b2 := engine.vg_add_node(&g, .Auto_Cast, {840, -100})
		engine.vg_find_node(&g, c_b2).inputs[0].pin_type = .Float
		engine.vg_find_node(&g, c_b2).outputs[0].pin_type = .Bool
		br_cont := engine.vg_add_node(&g, .Branch_If, {920, -40})
		cont_n := engine.vg_add_node(&g, .Continue_Loop, {1060, -120})

		sub_4 := engine.vg_add_node(&g, .Math_Float, {760, 140})
		engine.vg_find_node(&g, sub_4).math_op = .Sub
		engine.vg_find_node(&g, sub_4).inputs[1].default_f32 = 4.0
		c_b4 := engine.vg_add_node(&g, .Auto_Cast, {840, 140})
		engine.vg_find_node(&g, c_b4).inputs[0].pin_type = .Float
		engine.vg_find_node(&g, c_b4).outputs[0].pin_type = .Bool
		br_brk := engine.vg_add_node(&g, .Branch_If, {1060, 60})
		brk_n := engine.vg_add_node(&g, .Break_Loop, {1200, 120})

		get_s2 := _v6_node_get_var(&g, "sum_ho", .Float, {1060, 220})
		add_2 := engine.vg_add_node(&g, .Math_Float, {1200, 20})
		engine.vg_find_node(&g, add_2).math_op = .Add
		set_s2 := _v6_node_set_var(&g, "sum_ho", .Float, {1340, 0})

		_v6_wire(&g, fl1, 2, fl2, 0)
		_v6_wire(&g, fl2, 1, c2_f, 0)
		_v6_wire(&g, c2_f, 0, sub_2, 0)
		_v6_wire(&g, sub_2, 0, c_b2, 0)
		_v6_wire(&g, fl2, 0, br_cont, 0)
		_v6_wire(&g, c_b2, 0, br_cont, 1)
		_v6_wire(&g, br_cont, 1, cont_n, 0) // idx == 2 => sub_2 == 0 => Bool(false) => Continue

		_v6_wire(&g, c2_f, 0, sub_4, 0)
		_v6_wire(&g, sub_4, 0, c_b4, 0)
		_v6_wire(&g, br_cont, 0, br_brk, 0)
		_v6_wire(&g, c_b4, 0, br_brk, 1)
		_v6_wire(&g, br_brk, 1, brk_n, 0) // idx == 4 => sub_4 == 0 => Bool(false) => Break

		_v6_wire(&g, br_brk, 0, set_s2, 0)
		_v6_wire(&g, get_s2, 0, add_2, 0)
		_v6_wire(&g, c2_f, 0, add_2, 1)
		_v6_wire(&g, add_2, 0, set_s2, 1)

		// Loop 3: Append 1, 2, 3 -> #reverse For_In_Value -> rev_acc = rev_acc*10 + elem => 321
		a1 := engine.vg_add_node(&g, .Array_Op, {1500, 0})
		engine.vg_configure_array_op(&g, engine.vg_find_node(&g, a1), .Append, "items")
		engine.vg_find_node(&g, a1).inputs[1].default_int = 1
		a2 := engine.vg_add_node(&g, .Array_Op, {1620, 0})
		engine.vg_configure_array_op(&g, engine.vg_find_node(&g, a2), .Append, "items")
		engine.vg_find_node(&g, a2).inputs[1].default_int = 2
		a3 := engine.vg_add_node(&g, .Array_Op, {1740, 0})
		engine.vg_configure_array_op(&g, engine.vg_find_node(&g, a3), .Append, "items")
		engine.vg_find_node(&g, a3).inputs[1].default_int = 3

		fl3 := engine.vg_add_node(&g, .For_Loop, {1880, 0})
		n3 := engine.vg_find_node(&g, fl3)
		engine.vg_configure_for_loop(&g, n3, .For_In_Value, "items")
		n3.loop_reverse = true

		get_rev := _v6_node_get_var(&g, "rev_acc", .Float, {2000, -80})
		mul_10 := engine.vg_add_node(&g, .Math_Float, {2120, -80})
		engine.vg_find_node(&g, mul_10).math_op = .Mul
		engine.vg_find_node(&g, mul_10).inputs[1].default_f32 = 10.0
		c3_ef := engine.vg_add_node(&g, .Auto_Cast, {2000, 80})
		engine.vg_find_node(&g, c3_ef).inputs[0].pin_type = .Int
		engine.vg_find_node(&g, c3_ef).outputs[0].pin_type = .Float
		add_rev := engine.vg_add_node(&g, .Math_Float, {2240, -40})
		engine.vg_find_node(&g, add_rev).math_op = .Add
		set_rev := _v6_node_set_var(&g, "rev_acc", .Float, {2360, -40})

		_v6_wire(&g, fl2, 2, a1, 0)
		_v6_wire(&g, a1, 0, a2, 0)
		_v6_wire(&g, a2, 0, a3, 0)
		_v6_wire(&g, a3, 0, fl3, 0)
		_v6_wire(&g, fl3, 0, set_rev, 0)
		_v6_wire(&g, get_rev, 0, mul_10, 0)
		_v6_wire(&g, mul_10, 0, add_rev, 0)
		_v6_wire(&g, fl3, 3, c3_ef, 0)
		_v6_wire(&g, c3_ef, 0, add_rev, 1)
		_v6_wire(&g, add_rev, 0, set_rev, 1)

		// Loop 4: For_In_Ref doubling each element via Array_Op Set_Elem(idx, elem*2)
		fl4 := engine.vg_add_node(&g, .For_Loop, {2500, 0})
		n4 := engine.vg_find_node(&g, fl4)
		engine.vg_configure_for_loop(&g, n4, .For_In_Ref, "items")

		c4_f := engine.vg_add_node(&g, .Auto_Cast, {2620, 80})
		engine.vg_find_node(&g, c4_f).inputs[0].pin_type = .Int
		engine.vg_find_node(&g, c4_f).outputs[0].pin_type = .Float
		mul_2 := engine.vg_add_node(&g, .Math_Float, {2720, 80})
		engine.vg_find_node(&g, mul_2).math_op = .Mul
		engine.vg_find_node(&g, mul_2).inputs[1].default_f32 = 2.0
		c4_i := engine.vg_add_node(&g, .Auto_Cast, {2820, 80})
		engine.vg_find_node(&g, c4_i).inputs[0].pin_type = .Float
		engine.vg_find_node(&g, c4_i).outputs[0].pin_type = .Int
		set_el := engine.vg_add_node(&g, .Array_Op, {2940, 0})
		engine.vg_configure_array_op(&g, engine.vg_find_node(&g, set_el), .Set_Elem, "items")

		_v6_wire(&g, fl3, 2, fl4, 0)
		_v6_wire(&g, fl4, 3, c4_f, 0)
		_v6_wire(&g, c4_f, 0, mul_2, 0)
		_v6_wire(&g, mul_2, 0, c4_i, 0)
		_v6_wire(&g, fl4, 0, set_el, 0)
		_v6_wire(&g, fl4, 1, set_el, 1)
		_v6_wire(&g, c4_i, 0, set_el, 2)

		tH := engine.transform_new("bp_v6_for_ent")
		bb := _v6_sync_entity_bb(&g, tH)
		engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

		testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "sum_inc")].val_f32 - 15.0) < 0.001, "Range_Inclusive 1..=5 sum must be 15")
		testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "sum_ho")].val_f32 - 4.0) < 0.001, "Range_Half_Open 0..<5 skipping 2 and breaking at 4 must sum to 4")
		testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "rev_acc")].val_f32 - 321.0) < 0.001, "#reverse For_In_Value over [1,2,3] must accumulate 321")

		blob := bb.var_blobs["items"]
		testing.expect(t, len(blob) >= 12, "items blob must be allocated")
		elems := (^[4]i32)(raw_data(blob[:]))
		testing.expect(t, elems[0] == 2 && elems[1] == 4 && elems[2] == 6, "For_In_Ref pass must update items to [2, 4, 6]")

		odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
		testing.expect(t, strings.contains(odin_src, "#reverse for "), "Transpiler must emit `#reverse for`")
		testing.expect(t, strings.contains(odin_src, "break") && strings.contains(odin_src, "continue"), "Transpiler must emit `break` and `continue`")
	}

	// Part B: 10,000 iteration loop safety fuse + reset
	{
		engine.visual_script_reset_runtime_state()
		g: engine.Visual_Graph
		g.name = strings.clone("v6_loop_fuse")
		defer engine.vg_destroy_graph(&g)

		_v6_var_decl(&g, "iters", .Float)
		evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
		fl := engine.vg_add_node(&g, .For_Loop, {120, 0})
		n_fl := engine.vg_find_node(&g, fl)
		engine.vg_configure_for_loop(&g, n_fl, .Condition, "")
		n_fl.inputs[1].default_bool = true

		get_it := _v6_node_get_var(&g, "iters", .Float, {260, -80})
		add_1 := engine.vg_add_node(&g, .Math_Float, {380, -80})
		engine.vg_find_node(&g, add_1).math_op = .Add
		engine.vg_find_node(&g, add_1).inputs[1].default_f32 = 1.0
		set_it := _v6_node_set_var(&g, "iters", .Float, {500, 0})

		_v6_wire(&g, evt, 0, fl, 0)
		_v6_wire(&g, fl, 0, set_it, 0)
		_v6_wire(&g, get_it, 0, add_1, 0)
		_v6_wire(&g, add_1, 0, set_it, 1)

		tH := engine.transform_new("bp_v6_fuse_ent")
		bb := _v6_sync_entity_bb(&g, tH)
		engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

		testing.expect(t, bb.loop_fuse_tripped_uid == fl, "Infinite Condition loop must trip fuse and record loop node UID")
		testing.expect(t, int(bb.slots[engine.vg_find_var_index(&g, "iters")].val_f32) == engine.VG_MAX_LOOP_ITERATIONS, "Loop must halt cleanly at VG_MAX_LOOP_ITERATIONS")

		engine.visual_script_reset_loop_fuse(tH)
		testing.expect(t, bb.loop_fuse_tripped_uid == 0, "visual_script_reset_loop_fuse must clear loop_fuse_tripped_uid")
	}
}

@(test)
test_bp_v6_defer_exec_and_or_branch :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()

	g: engine.Visual_Graph
	g.name = strings.clone("v6_defer_or")
	defer engine.vg_destroy_graph(&g)

	_v6_var_decl(&g, "trace", .Float)
	_v6_var_decl(&g, "or_out", .Int)

	append_digit := proc(g: ^engine.Visual_Graph, digit: f32, pos: [2]f32) -> int {
		get_t := _v6_node_get_var(g, "trace", .Float, pos + {-100, 80})
		mul := engine.vg_add_node(g, .Math_Float, pos + {0, 80})
		engine.vg_find_node(g, mul).math_op = .Mul
		engine.vg_find_node(g, mul).inputs[1].default_f32 = 10.0
		add := engine.vg_add_node(g, .Math_Float, pos + {100, 80})
		engine.vg_find_node(g, add).math_op = .Add
		engine.vg_find_node(g, add).inputs[1].default_f32 = digit
		set_t := _v6_node_set_var(g, "trace", .Float, pos)
		_v6_wire(g, get_t, 0, mul, 0)
		_v6_wire(g, mul, 0, add, 0)
		_v6_wire(g, add, 0, set_t, 1)
		return set_t
	}

	evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
	d1 := engine.vg_add_node(&g, .Defer_Exec, {100, 0})
	d2 := engine.vg_add_node(&g, .Defer_Exec, {300, 0})

	t1 := append_digit(&g, 1, {200, -120})
	t2 := append_digit(&g, 2, {480, -120})
	t3 := append_digit(&g, 3, {480, 120})
	t4 := append_digit(&g, 4, {200, 160})

	orb := engine.vg_add_node(&g, .Or_Branch, {680, 0})
	n_orb := engine.vg_find_node(&g, orb)
	n_orb.inputs[1].pin_type = .Int
	n_orb.outputs[2].pin_type = .Int
	n_orb.inputs[1].default_int = 77
	n_orb.inputs[2].default_bool = true

	set_ok := _v6_node_set_var(&g, "or_out", .Int, {880, -60})
	set_fail := _v6_node_set_var(&g, "or_out", .Int, {880, 100})
	engine.vg_find_node(&g, set_fail).inputs[1].default_int = -99

	_v6_wire(&g, evt, 0, d1, 0)
	_v6_wire(&g, d1, 0, t1, 0)
	_v6_wire(&g, t1, 0, d2, 0)
	_v6_wire(&g, d2, 0, t2, 0)
	_v6_wire(&g, t2, 0, orb, 0)
	_v6_wire(&g, orb, 0, set_ok, 0)
	_v6_wire(&g, orb, 2, set_ok, 1)
	_v6_wire(&g, orb, 1, set_fail, 0)
	_v6_wire(&g, d2, 1, t3, 0)
	_v6_wire(&g, d1, 1, t4, 0)

	tH := engine.transform_new("bp_v6_defer_ent")
	bb := _v6_sync_entity_bb(&g, tH)
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)

	// LIFO: d1 Then(1) -> d2 Then(2) -> (orb Valid=77) -> d2 Defer(3) -> d1 Defer(4)
	testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "trace")].val_f32 - 1234.0) < 0.001, "Nested Defer_Exec must unwind in strict LIFO order (1234)")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "or_out")].val_int == 77, "Or_Branch Valid path must forward value 77")

	n_orb.inputs[2].default_bool = false
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "or_out")].val_int == -99, "Or_Branch Failed path must execute output 1")

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect(t, strings.contains(odin_src, "defer {"), "Transpiler must emit `defer {` blocks")
}

@(test)
test_bp_v6_ast_bp_node_sig_meta_and_starters :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("bp_v6_ast_ent")

	starters := [6]string{
		"__bpwrap_bp_u8_saturating_add",
		"__bpwrap_bp_u8_pack_rgba",
		"__bpwrap_bp_remap_clamped",
		"__bpwrap_bp_spring_f32_inplace",
		"__bpwrap_bp_quat_look_dir",
		"__bpwrap_bp_vec3_horizontal_dir",
	}
	for s in starters {
		_, ok := engine.hot_proc_find_sig_meta(s)
		testing.expectf(t, ok, "Starter @(bp_node) %s must be registered with Hot_Proc_Sig_Meta", s)
	}

	m_sat, ok_sat := engine.hot_proc_find_sig_meta("__bpwrap_bp_u8_saturating_add")
	testing.expect(t, ok_sat && m_sat.source_proc_name == "bp_u8_saturating_add", "__bpwrap_bp_u8_saturating_add must record source_proc_name")
	testing.expect(t, len(m_sat.doc_comment) > 0, "@(bp_node) doc_comment must be extracted")
	testing.expect(t, m_sat.is_pure && len(m_sat.pins) == 3 && !m_sat.pins[0].is_output && !m_sat.pins[1].is_output && m_sat.pins[2].is_output, "bp_u8_saturating_add must have 2 inputs, 1 return")

	m_spr, ok_spr := engine.hot_proc_find_sig_meta("__bpwrap_bp_spring_f32_inplace")
	testing.expect(t, ok_spr && m_spr.source_proc_name == "bp_spring_f32_inplace", "__bpwrap_bp_spring_f32_inplace must record source_proc_name")
	testing.expect(t, !m_spr.is_pure && len(m_spr.pins) == 4 && m_spr.pins[0].by_ref && m_spr.pins[1].by_ref, "bp_spring_f32_inplace must declare 4 exposed pins (dt injected automatically)")

	// Invoke bp_u8_saturating_add(200, 100) -> 255
	f1: hot.Hot_Call_Frame
	f1.input_count = 2
	f1.inputs[0] = hot.Hot_Slot{pin_type = .U8, val_u8 = 200}
	f1.inputs[1] = hot.Hot_Slot{pin_type = .U8, val_u8 = 100}
	testing.expect(t, engine.hot_proc_invoke("__bpwrap_bp_u8_saturating_add", tH, 0.016, &f1), "Invoke __bpwrap_bp_u8_saturating_add must succeed")
	testing.expect(t, f1.outputs[0].val_u8 == 255, "Saturating add 200 + 100 must clamp to 255")

	// Invoke bp_spring_f32_inplace via By_Reference pointers (val, vel, target, stiffness)
	val: f32 = 0.0
	vel: f32 = 0.0
	f2: hot.Hot_Call_Frame
	f2.input_count = 4
	f2.inputs[0] = hot.Hot_Slot{pin_type = .Float, pass_mode = .By_Reference, ref_ptr = &val}
	f2.inputs[1] = hot.Hot_Slot{pin_type = .Float, pass_mode = .By_Reference, ref_ptr = &vel}
	f2.inputs[2] = hot.Hot_Slot{pin_type = .Float, val_f32 = 10.0}
	f2.inputs[3] = hot.Hot_Slot{pin_type = .Float, val_f32 = 12.0}
	testing.expect(t, engine.hot_proc_invoke("__bpwrap_bp_spring_f32_inplace", tH, 0.05, &f2), "Invoke __bpwrap_bp_spring_f32_inplace must succeed")
	testing.expect(t, val > 0.0 && vel > 0.0, "By_Reference spring update must move val and vel toward target 10.0")
}

@(test)
test_bp_v6_gameplay_bridges_and_timers :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	defer engine.visual_script_reset_runtime_state()
	defer engine.visual_script_install_physics_bridge({})
	defer engine.visual_script_install_csg_bridge({})

	@(static) mock_impulses: int
	@(static) mock_csg_stamps: int
	mock_impulses = 0
	mock_csg_stamps = 0

	tH := engine.transform_new("bp_v6_bridge_ent")
	@(static) mock_entity_target: engine.Transform_Handle
	mock_entity_target = tH

	engine.visual_script_install_physics_bridge(engine.Visual_Script_Physics_Bridge{
		raycast_masked = proc(origin, dir: [3]f32, max_dist: f32, mask: u32, ignore_owner: engine.Transform_Handle) -> (hot.Hot_Raycast_Hit, bool) {
			return hot.Hot_Raycast_Hit{
				hit      = true,
				position = {1, 2, 3},
				normal   = {0, 1, 0},
				distance = 4.5,
				entity   = engine.transform_to_hot_entity(mock_entity_target),
			}, true
		},
		overlap_sphere = proc(center: [3]f32, radius: f32, mask: u32, ignore_owner: engine.Transform_Handle) -> (i32, engine.Transform_Handle) {
			return 3, mock_entity_target
		},
		add_impulse = proc(target: engine.Transform_Handle, impulse: [3]f32, is_velocity_change: bool) {
			mock_impulses += 1
		},
	})
	engine.visual_script_install_csg_bridge(engine.Visual_Script_CSG_Bridge{
		brush_stamp = proc(world_pos: [3]f32, radius, impulse: f32, cut_mat_str: string) -> i32 {
			mock_csg_stamps += 1
			return 2
		},
	})

	g: engine.Visual_Graph
	g.name = strings.clone("v6_bridges_timers")
	defer engine.vg_destroy_graph(&g)

	_v6_var_decl(&g, "delay_done", .Bool)
	_v6_var_decl(&g, "cd_ready_count", .Float)
	_v6_var_decl(&g, "cd_blocked_count", .Float)
	_v6_var_decl(&g, "ray_dist", .Float)
	_v6_var_decl(&g, "ov_count", .Int)
	_v6_var_decl(&g, "spawn_ok", .Bool)
	_v6_var_decl(&g, "csg_affected", .Int)

	init_n := engine.vg_add_node(&g, .Event_Init, {0, 0})
	rc_n := engine.vg_add_node(&g, .Physics_Raycast, {140, -180})
	set_rdist := _v6_node_set_var(&g, "ray_dist", .Float, {320, -180})
	ov_n := engine.vg_add_node(&g, .Physics_Overlap_Sphere, {500, -180})
	set_ovc := _v6_node_set_var(&g, "ov_count", .Int, {680, -180})
	imp_n := engine.vg_add_node(&g, .Physics_Add_Impulse, {840, -180})
	sp_n := engine.vg_add_node(&g, .Spawn_Prefab, {1000, -180}, "__empty_entity__")
	set_spok := _v6_node_set_var(&g, "spawn_ok", .Bool, {1140, -240})
	ds_n := engine.vg_add_node(&g, .Destroy_Entity, {1280, -180})
	csg_n := engine.vg_add_node(&g, .CSG_Brush_Stamp, {1440, -180})
	set_csg := _v6_node_set_var(&g, "csg_affected", .Int, {1600, -180})

	_v6_wire(&g, init_n, 0, rc_n, 0)
	_v6_wire(&g, rc_n, 0, set_rdist, 0)
	_v6_wire(&g, rc_n, 4, set_rdist, 1)
	_v6_wire(&g, set_rdist, 0, ov_n, 0)
	_v6_wire(&g, ov_n, 0, set_ovc, 0)
	_v6_wire(&g, ov_n, 1, set_ovc, 1)
	_v6_wire(&g, set_ovc, 0, imp_n, 0)
	_v6_wire(&g, imp_n, 0, sp_n, 0)
	_v6_wire(&g, sp_n, 0, set_spok, 0)
	_v6_wire(&g, sp_n, 2, set_spok, 1)
	_v6_wire(&g, set_spok, 0, ds_n, 0)
	_v6_wire(&g, sp_n, 1, ds_n, 1)
	_v6_wire(&g, ds_n, 0, csg_n, 0)
	_v6_wire(&g, csg_n, 0, set_csg, 0)
	_v6_wire(&g, csg_n, 1, set_csg, 1)

	tick := engine.vg_add_node(&g, .Event_Tick, {0, 120})
	dt_n := engine.vg_add_node(&g, .Delay_Timer, {140, 120})
	engine.vg_find_node(&g, dt_n).inputs[1].default_f32 = 0.5
	set_ddone := _v6_node_set_var(&g, "delay_done", .Bool, {320, 120})
	engine.vg_find_node(&g, set_ddone).inputs[1].default_bool = true
	_v6_wire(&g, tick, 0, dt_n, 0)
	_v6_wire(&g, dt_n, 1, set_ddone, 0)

	cd_proc := engine.vg_add_node(&g, .Custom_Proc_Entry, {0, 320}, "CdTest")
	cd_n := engine.vg_add_node(&g, .Cooldown_Gate, {140, 320})
	engine.vg_find_node(&g, cd_n).inputs[1].default_f32 = 0.5

	inc_ready_g := _v6_node_get_var(&g, "cd_ready_count", .Float, {300, 280})
	inc_ready_a := engine.vg_add_node(&g, .Math_Float, {400, 280})
	engine.vg_find_node(&g, inc_ready_a).math_op = .Add
	engine.vg_find_node(&g, inc_ready_a).inputs[1].default_f32 = 1.0
	inc_ready_s := _v6_node_set_var(&g, "cd_ready_count", .Float, {520, 280})

	inc_blk_g := _v6_node_get_var(&g, "cd_blocked_count", .Float, {300, 400})
	inc_blk_a := engine.vg_add_node(&g, .Math_Float, {400, 400})
	engine.vg_find_node(&g, inc_blk_a).math_op = .Add
	engine.vg_find_node(&g, inc_blk_a).inputs[1].default_f32 = 1.0
	inc_blk_s := _v6_node_set_var(&g, "cd_blocked_count", .Float, {520, 400})

	_v6_wire(&g, cd_proc, 1, cd_n, 0)
	_v6_wire(&g, cd_n, 0, inc_ready_s, 0)
	_v6_wire(&g, inc_ready_g, 0, inc_ready_a, 0)
	_v6_wire(&g, inc_ready_a, 0, inc_ready_s, 1)
	_v6_wire(&g, cd_n, 1, inc_blk_s, 0)
	_v6_wire(&g, inc_blk_g, 0, inc_blk_a, 0)
	_v6_wire(&g, inc_blk_a, 0, inc_blk_s, 1)

	bb := _v6_sync_entity_bb(&g, tH)
	engine.vg_eval_event_live(&g, bb, tH, 0.016, .Event_Init)
	testing.expect(t, math.abs(bb.slots[engine.vg_find_var_index(&g, "ray_dist")].val_f32 - 4.5) < 0.001, "Physics_Raycast bridge output dist must be 4.5")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "ov_count")].val_int == 3, "Physics_Overlap_Sphere bridge count must be 3")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "spawn_ok")].val_bool == true, "Spawn_Prefab must spawn entity cleanly")
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "csg_affected")].val_int == 2, "CSG_Brush_Stamp bridge must return affected count 2")
	testing.expect(t, mock_impulses == 1 && mock_csg_stamps == 1, "Physics AddImpulse & CSG BrushStamp callbacks must execute once")

	// Delay_Timer ticks
	engine.vg_eval_event_live(&g, bb, tH, 0.2, .Event_Tick)
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "delay_done")].val_bool == false, "Delay_Timer 0.2/0.5 must stay active")
	engine.vg_eval_event_live(&g, bb, tH, 0.2, .Event_Tick)
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "delay_done")].val_bool == false, "Delay_Timer 0.4/0.5 must still stay active")
	engine.vg_eval_event_live(&g, bb, tH, 0.2, .Event_Tick)
	testing.expect(t, bb.slots[engine.vg_find_var_index(&g, "delay_done")].val_bool == true, "Delay_Timer >= 0.5 must fire Completed")

	// Cooldown_Gate ticks
	engine.vg_eval_custom_proc_live(&g, bb, tH, 0.2, "CdTest")
	testing.expect(t, int(bb.slots[engine.vg_find_var_index(&g, "cd_ready_count")].val_f32) == 1, "Cooldown_Gate first call must fire Ready")
	engine.vg_eval_custom_proc_live(&g, bb, tH, 0.2, "CdTest")
	testing.expect(t, int(bb.slots[engine.vg_find_var_index(&g, "cd_blocked_count")].val_f32) == 1, "Cooldown_Gate while active must fire Blocked")
	engine.vg_eval_custom_proc_live(&g, bb, tH, 0.6, "CdTest")
	testing.expect(t, int(bb.slots[engine.vg_find_var_index(&g, "cd_ready_count")].val_f32) == 2, "Cooldown_Gate after elapsed duration must fire Ready again")
}

@(test)
test_bp_v6_transpiler_vet_unused_compile_gate :: proc(t: ^testing.T) {
	g: engine.Visual_Graph
	g.name = strings.clone("v6_vet_unused_gate")
	defer engine.vg_destroy_graph(&g)

	ed := engine.VG_Enum_Decl{name = strings.clone("Gate_Mode")}
	append(&ed.variants, strings.clone("Alpha"), strings.clone("Beta"))
	append(&g.enums, ed)

	st := engine.VG_Struct_Decl{name = strings.clone("Gate_Packet")}
	append(&st.fields, engine.VG_Struct_Field{name = strings.clone("seq"), pin_type = .U32}, engine.VG_Struct_Field{name = strings.clone("val"), pin_type = .F64})
	append(&g.structs, st)

	append(&g.variables,
		engine.VG_Var_Decl{name = strings.clone("g_mode"), pin_type = .Enum_U8, custom_type_name = strings.clone("Gate_Mode")},
		engine.VG_Var_Decl{name = strings.clone("g_bits"), pin_type = .BitSet_U8, custom_type_name = strings.clone("Gate_Mode")},
		engine.VG_Var_Decl{name = strings.clone("g_fixed"), pin_type = .Float, is_array = true, array_count = 0, array_is_bounded = false},
		engine.VG_Var_Decl{name = strings.clone("g_bounded"), pin_type = .Float, is_array = true, array_count = 4, array_is_bounded = true},
		engine.VG_Var_Decl{name = strings.clone("g_u8"), pin_type = .U8},
		engine.VG_Var_Decl{name = strings.clone("g_acc"), pin_type = .Int},
	)

	init_n := engine.vg_add_node(&g, .Event_Init, {0, 0})
	bs := engine.vg_add_node(&g, .BitSet_Op, {100, 0})
	engine.vg_configure_bitset_op(&g, engine.vg_find_node(&g, bs), .Set_Flag, "Gate_Mode")
	sw := engine.vg_add_node(&g, .Switch_Value, {260, 0})
	engine.vg_configure_switch_node(&g, engine.vg_find_node(&g, sw), "Gate_Mode")
	get_m := _v6_node_get_var(&g, "g_mode", .Enum_U8, {160, 120})
	fl := engine.vg_add_node(&g, .For_Loop, {420, 0})
	engine.vg_configure_for_loop(&g, engine.vg_find_node(&g, fl), .Range_Half_Open, "")
	engine.vg_find_node(&g, fl).inputs[2].default_int = 3
	set_a := _v6_node_set_var(&g, "g_acc", .Int, {560, 0})
	df := engine.vg_add_node(&g, .Defer_Exec, {700, 0})
	orb := engine.vg_add_node(&g, .Or_Branch, {860, 0})
	engine.vg_find_node(&g, orb).inputs[1].pin_type = .U8
	engine.vg_find_node(&g, orb).outputs[2].pin_type = .U8
	rc := engine.vg_add_node(&g, .Physics_Raycast, {1020, 0})

	_v6_wire(&g, init_n, 0, bs, 0)
	_v6_wire(&g, bs, 0, sw, 0)
	_v6_wire(&g, get_m, 0, sw, 1)
	_v6_wire(&g, sw, 0, fl, 0)
	_v6_wire(&g, fl, 0, set_a, 0)
	_v6_wire(&g, fl, 1, set_a, 1)
	_v6_wire(&g, fl, 2, df, 0)
	_v6_wire(&g, df, 0, orb, 0)
	_v6_wire(&g, orb, 0, rc, 0)

	raw_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	isolated_src, _ := strings.replace(raw_src, "package hot_scripts", "package bp_vet_test", 1, context.temp_allocator)

	base_tmp, _ := os.temp_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join({base_tmp, "haati_bp_v6_vet_gate"}, context.temp_allocator)
	_ = os.make_directory(tmp_dir)
	tmp_file, _ := filepath.join({tmp_dir, "vet_gate.odin"}, context.temp_allocator)
	log_file, _ := filepath.join({tmp_dir, "vet_check.log"}, context.temp_allocator)
	_ = os.remove(tmp_file)
	_ = os.remove(log_file)
	defer {
		_ = os.remove(tmp_file)
		_ = os.remove(log_file)
		_ = os.remove(tmp_dir)
	}

	ok_w := os.write_entire_file(tmp_file, transmute([]u8)isolated_src) == nil
	testing.expect(t, ok_w, "Writing isolated transpiled Odin file must succeed")

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	odin_exe  := engine.resolve_odin_binary(context.temp_allocator)
	args := [?]string{
		odin_exe,
		"check",
		tmp_dir,
		"-no-entry-point",
		"-vet-unused",
		"-collection:haati=haati",
		"-collection:moonhug=haati",
		"-ignore-unknown-attributes",
	}
	bg, started := engine.bg_process_start_to_file(repo_root, args[:], nil, log_file)
	testing.expect(t, started, "bg_process_start_to_file(odin check -vet-unused) must start cleanly")
	exited, exit_code := engine.bg_process_wait(&bg)
	log_bytes, _ := os.read_entire_file(log_file, context.temp_allocator)
	testing.expectf(t, exited && exit_code == 0, "Transpiled V6 graph must pass `odin check -vet-unused`, exit=%d output:\n%s", exit_code, string(log_bytes))
}

@(test)
test_bp_v6_bodin_roundtrip_zero_leaks :: proc(t: ^testing.T) {
	base_tmp, _ := os.temp_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join({base_tmp, "haati_bp_v6_roundtrip"}, context.temp_allocator)
	_ = os.make_directory(tmp_dir)
	bodin_path, _ := filepath.join({tmp_dir, "v6_roundtrip.bodin"}, context.temp_allocator)
	_ = os.remove(bodin_path)
	defer {
		_ = os.remove(bodin_path)
		_ = os.remove(tmp_dir)
	}

	{
		g: engine.Visual_Graph
		g.name = strings.clone("v6_roundtrip")
		defer engine.vg_destroy_graph(&g)

		ed := engine.VG_Enum_Decl{name = strings.clone("RT_State")}
		append(&ed.variants, strings.clone("One"), strings.clone("Two"))
		append(&g.enums, ed)

		base_st := engine.VG_Struct_Decl{name = strings.clone("RT_Base")}
		append(&base_st.fields, engine.VG_Struct_Field{name = strings.clone("tag"), pin_type = .U8})
		sub_st := engine.VG_Struct_Decl{name = strings.clone("RT_Sub"), using_parent_name = strings.clone("RT_Base")}
		append(&sub_st.fields, engine.VG_Struct_Field{name = strings.clone("score"), pin_type = .F64})
		append(&g.structs, base_st, sub_st)

		append(&g.variables,
			engine.VG_Var_Decl{name = strings.clone("state_bits"), pin_type = .BitSet_U8, custom_type_name = strings.clone("RT_State")},
			engine.VG_Var_Decl{name = strings.clone("bounded_u16"), pin_type = .U16, is_array = true, array_count = 6, array_is_bounded = true},
		)

		evt := engine.vg_add_node(&g, .Event_Init, {0, 0})
		fl := engine.vg_add_node(&g, .For_Loop, {120, 20})
		engine.vg_configure_for_loop(&g, engine.vg_find_node(&g, fl), .For_In_Ref, "bounded_u16")
		engine.vg_find_node(&g, fl).loop_reverse = true

		stp := engine.vg_add_node(&g, .Set_Transform_Pos, {300, 80})
		_ = engine.vg_split_pin_inline(&g, stp, false, 1)
		_v6_wire(&g, evt, 0, fl, 0)

		ok_s := engine.vg_save_to_file(&g, bodin_path)
		testing.expect(t, ok_s, "vg_save_to_file(.bodin) must succeed")
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		loaded: engine.Visual_Graph
		ok_l := engine.vg_load_from_file(&loaded, bodin_path)
		defer engine.vg_destroy_graph(&loaded)
		testing.expect(t, ok_l, "vg_load_from_file must succeed")
		testing.expect(t, len(loaded.enums) == 1 && loaded.enums[0].name == "RT_State", "Loaded enum must round-trip")
		testing.expect(t, len(loaded.structs) == 2 && loaded.structs[1].using_parent_name == "RT_Base", "Loaded structs + using_parent_name must round-trip")
		testing.expect(t, len(loaded.variables) == 2 && loaded.variables[1].array_is_bounded && loaded.variables[1].array_count == 6, "Loaded bounded variable metadata must round-trip")
		testing.expect(t, len(loaded.nodes) >= 3 && len(loaded.wires) == 1, "Loaded nodes and wires must round-trip")
	}

	testing.expectf(t, len(track.allocation_map) == 0, "Zero leaked allocations expected after vg_destroy_graph, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "Zero bad frees expected, got %d", len(track.bad_free_array))
}

@(private = "file")
_v6_is_unit_color_component :: proc(s: string) -> bool {
	if s == "0" || s == "1" do return true
	if strings.has_prefix(s, "0.") && len(s) >= 3 {
		for ch in s[2:] {
			if ch < '0' || ch > '9' do return false
		}
		return true
	}
	if strings.has_prefix(s, "1.") && len(s) >= 3 {
		for ch in s[2:] {
			if ch != '0' do return false
		}
		return true
	}
	if strings.has_prefix(s, ".") && len(s) >= 2 {
		for ch in s[1:] {
			if ch < '0' || ch > '9' do return false
		}
		return true
	}
	return false
}

@(private = "file")
_v6_line_has_hardcoded_rgba_literal :: proc(code_part: string) -> bool {
	i := 0
	for i < len(code_part) {
		if code_part[i] != '{' {
			i += 1
			continue
		}
		j := i + 1
		nested := false
		for j < len(code_part) && code_part[j] != '}' {
			if code_part[j] == '{' || code_part[j] == '"' {
				nested = true
				break
			}
			j += 1
		}
		if nested || j >= len(code_part) {
			i += 1
			continue
		}
		inner := code_part[i + 1 : j]
		parts := strings.split(inner, ",", context.temp_allocator)
		if len(parts) == 3 || len(parts) == 4 {
			all_unit := true
			has_dot  := false
			for raw_p in parts {
				p := strings.trim_space(raw_p)
				if !_v6_is_unit_color_component(p) {
					all_unit = false
					break
				}
				if strings.contains(p, ".") do has_dot = true
			}
			if all_unit && has_dot do return true
		}
		i = j + 1
	}
	return false
}

// =============================================================================
// 11. Studio Palette, Icon Slot Registry & Split-Studio UI Safety Contracts
// =============================================================================
@(test)
test_bp_v6_studio_palette_icons_and_ui_contracts :: proc(t: ^testing.T) {
	// 1. Pin & Picker Registry
	for pt in hot.Hot_Pin_Type {
		vis := thm.STUDIO_PIN_TABLE[pt]
		testing.expectf(t, len(string(vis.odin_label)) > 0, "STUDIO_PIN_TABLE[%v] must have non-empty odin_label", pt)
		testing.expectf(t, len(string(vis.type_icon)) > 0, "STUDIO_PIN_TABLE[%v] must have non-empty type_icon", pt)
		testing.expectf(t, vis.dark_color[3] > 0, "STUDIO_PIN_TABLE[%v] must have positive alpha", pt)
	}
	testing.expect(t, !thm.STUDIO_PIN_TABLE[.Exec].in_picker, ".Exec must be excluded from data type pickers")
	testing.expect_value(t, len(thm.STUDIO_PICKER_TYPES), 22)

	seen_picker: [hot.Hot_Pin_Type]bool
	for pt in thm.STUDIO_PICKER_TYPES {
		testing.expectf(t, pt != .Exec, "STUDIO_PICKER_TYPES must not include .Exec")
		testing.expectf(t, !seen_picker[pt], "STUDIO_PICKER_TYPES contains duplicate %v", pt)
		seen_picker[pt] = true
		testing.expectf(t, thm.STUDIO_PIN_TABLE[pt].in_picker, "STUDIO_PICKER_TYPES[%v] must set in_picker=true", pt)
	}

	// 2. Container, Namespace, Syntax & Symbol Registries
	for ck in thm.Studio_Container_Kind {
		cv := thm.STUDIO_CONTAINER_TABLE[ck]
		testing.expectf(t, len(string(cv.icon)) > 0, "STUDIO_CONTAINER_TABLE[%v] must have icon", ck)
		testing.expectf(t, len(string(cv.short_badge)) > 0, "STUDIO_CONTAINER_TABLE[%v] must have short_badge", ck)
		testing.expectf(t, cv.dark_tint[3] > 0, "STUDIO_CONTAINER_TABLE[%v] must have positive alpha", ck)
		if ck != .Exec_Flow {
			testing.expectf(t, cv.wire_badge != nil && len(string(cv.wire_badge)) > 0, "STUDIO_CONTAINER_TABLE[%v] must have wire_badge", ck)
		}
	}

	ic_copy, ti_bool, _ := thm.studio_var_icon_and_color(.Bool, false, false, false)
	ic_ref,  _,       _ := thm.studio_var_icon_and_color(.Bool, false, false, true)
	ic_arr,  _,       _ := thm.studio_var_icon_and_color(.Bool, true,  false, false)
	ic_bnd,  _,       _ := thm.studio_var_icon_and_color(.Bool, true,  true,  false)
	testing.expect(t, len(string(ti_bool)) > 0, "studio_var_icon_and_color must return type icon")
	testing.expect(t, ic_copy != ic_ref && ic_copy != ic_arr && ic_copy != ic_bnd && ic_ref != ic_arr && ic_ref != ic_bnd && ic_arr != ic_bnd,
		"Scalar copy, ^Ref, [N] array, and Bounded array must have distinct container icons")

	for ns in thm.Studio_Namespace {
		badge, icon, accent := thm.studio_namespace_style(ns)
		testing.expectf(t, len(string(badge)) > 0 && len(string(icon)) > 0 && accent.w > 0, "STUDIO_NAMESPACE_TABLE[%v] incomplete", ns)
	}
	for role in thm.Studio_Syntax_Role {
		sv := thm.STUDIO_SYNTAX_TABLE[role]
		testing.expectf(t, sv.dark_color[3] > 0 && sv.light_color[3] > 0, "STUDIO_SYNTAX_TABLE[%v] alpha must be > 0", role)
	}
	for sk in thm.Studio_Symbol_Kind {
		icon, badge, col := thm.studio_symbol_visual(sk)
		testing.expectf(t, len(string(icon)) > 0 && len(string(badge)) > 0 && col.w > 0, "STUDIO_SYMBOL_TABLE[%v] incomplete", sk)
	}

	// 3. Dark vs Light Theme Adaptation
	defer thm.set(.Antigravity_Dark)

	thm.set(.Antigravity_Dark)
	dark_p    := thm.palette()
	dark_vec3 := thm.studio_pin_color(.Vec3)
	dark_tok  := thm.studio_tokens()
	dark_kw   := thm.studio_syntax_color(.Keyword, &dark_p)

	thm.set(.Antigravity_Light)
	light_p    := thm.palette()
	light_vec3 := thm.studio_pin_color(.Vec3)
	light_tok  := thm.studio_tokens()
	light_kw   := thm.studio_syntax_color(.Keyword, &light_p)

	testing.expect(t, !dark_p.is_light && light_p.is_light, "theme switch must update palette().is_light")
	testing.expect(t, light_vec3.x < dark_vec3.x && light_vec3.y < dark_vec3.y, "bright Vec3 pin hue must darken on Antigravity_Light")
	testing.expect(t, light_tok.code_child_bg.x > dark_tok.code_child_bg.x, "Studio code background must brighten on Antigravity_Light")
	testing.expect(t, light_kw != dark_kw, "Keyword highlight color must adapt between dark and light themes")
	testing.expect(t, thm.studio_exec_pulse_color(0.25).w > 0, "studio_exec_pulse_color must return visible alpha")

	// 4. Shared Slot Formatter (`vs.format_slot_override_value`)
	slot: hot.Hot_Slot
	slot.val_bool = true
	testing.expect_value(t, vs.format_slot_override_value(.Bool, &slot, "", context.temp_allocator), "true")
	slot.val_bool = false
	testing.expect_value(t, vs.format_slot_override_value(.Bool, &slot, "", context.temp_allocator), "false")
	slot.val_u8 = 200
	testing.expect_value(t, vs.format_slot_override_value(.U8, &slot, "", context.temp_allocator), "200")
	slot.val_int = -42
	testing.expect_value(t, vs.format_slot_override_value(.Int, &slot, "", context.temp_allocator), "-42")
	slot.val_f32 = 1.5
	testing.expect_value(t, vs.format_slot_override_value(.Float, &slot, "", context.temp_allocator), "1.5000")
	slot.val_f64 = 2.25
	testing.expect_value(t, vs.format_slot_override_value(.F64, &slot, "", context.temp_allocator), "2.25000000")
	slot.val_vec3 = {1, 2, 3}
	testing.expect_value(t, vs.format_slot_override_value(.Vec3, &slot, "", context.temp_allocator), "1.0000,2.0000,3.0000")
	testing.expect_value(t, vs.format_slot_override_value(.String, &slot, "hello_odin", context.temp_allocator), "hello_odin")

	// 5. Static UI Safety, Unbaked Glyph Ban & Zero-Hardcoded-RGBA Contract
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	checked_files := [?]string{
		"haati/editor/theme/studio_palette.odin",
		"haati/editor/code_studio/code_studio.odin",
		"haati/editor/code_studio/syntax.odin",
		"haati/editor/visual_script/visual_script_editor.odin",
		"haati/editor/visual_script/vs_docks.odin",
		"haati/editor/visual_script/vs_canvas.odin",
		"haati/editor/view_visual_script_inspector.odin",
	}
	forbidden_glyphs := [?]string{
		"\u25c7", "\u25b7", "\u25cf", "\u25c6", "\U0001f441",
		"\u2713", "\u2717", "\u26a1", "\u21bb", "\u2220",
	}

	for rel in checked_files {
		abs_p, _ := filepath.join({repo_root, rel}, context.temp_allocator)
		raw, err := os.read_entire_file(abs_p, context.temp_allocator)
		testing.expectf(t, err == nil, "expected %s to be readable", rel)
		if err != nil do continue

		lines := strings.split_lines(string(raw), context.temp_allocator)
		in_if_begin_child := false
		if_child_depth    := 0
		for raw_ln, li in lines {
			trimmed := strings.trim_space(raw_ln)
			if strings.has_prefix(trimmed, "//") do continue

			has_raw_tip := strings.contains(trimmed, "im.SetTooltip(") || strings.contains(trimmed, "im.SetItemTooltip(")
			testing.expectf(t, !has_raw_tip, "%s:%d violates widgets.tooltip contract: %s", rel, li + 1, trimmed)

			if strings.contains(trimmed, "DrawList_AddRect(") {
				testing.expectf(t, !strings.contains(trimmed, ", {}, "), "%s:%d swaps thickness and flags in DrawList_AddRect: %s", rel, li + 1, trimmed)
			}

			is_vararg_txt := strings.contains(trimmed, "im.Text(") ||
			                 strings.contains(trimmed, "im.TextColored(") ||
			                 strings.contains(trimmed, "im.TextDisabled(") ||
			                 strings.contains(trimmed, "im.TextWrapped(") ||
			                 strings.contains(trimmed, "im.BulletText(")
			if is_vararg_txt && strings.contains(trimmed, "%s") {
				safe := strings.contains(trimmed, "fmt.ctprintf(") || strings.contains(trimmed, "cstring(")
				testing.expectf(t, safe, "%s:%d passes raw Odin string to #c_varargs ImGui text proc: %s", rel, li + 1, trimmed)
			}

			if strings.has_prefix(trimmed, "if im.BeginChild(") {
				in_if_begin_child = true
				if_child_depth    = 0
			}
			if in_if_begin_child {
				for ch in trimmed {
					if ch == '{' do if_child_depth += 1
					if ch == '}' do if_child_depth -= 1
				}
				if trimmed == "return" || strings.has_prefix(trimmed, "return ") {
					testing.expectf(t, false, "%s:%d executes early `return` inside `if im.BeginChild(...)` without `defer im.EndChild()`!", rel, li + 1)
				}
				if if_child_depth <= 0 && strings.contains(trimmed, "}") {
					in_if_begin_child = false
				}
			}

			code_part := trimmed
			if cidx := strings.index(code_part, "//"); cidx >= 0 {
				code_part = code_part[:cidx]
			}
			for glyph in forbidden_glyphs {
				testing.expectf(t, !strings.contains(code_part, glyph), "unbaked glyph %q found at %s:%d -> %s", glyph, rel, li + 1, code_part)
			}
			if rel != "haati/editor/theme/studio_palette.odin" {
				testing.expectf(t, !_v6_line_has_hardcoded_rgba_literal(code_part), "hardcoded float color literal found at %s:%d -> %s", rel, li + 1, code_part)
			}
		}
	}
}
