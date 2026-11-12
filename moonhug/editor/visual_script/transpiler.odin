package visual_script

// =============================================================================
// DETERMINISTIC BLUEPRINT & NIAGARA `.mhgraph` -> NATIVE `.odin` TRANSPILER V3
// =============================================================================
// Compiles a `Visual_Graph` Blueprint into clean, human-readable, `-vet-unused`
// safe Data-Oriented Odin machine code (`moonhug/hot_scripts/<name>_mhgraph_generated.odin`):
//   - Flat `<Name>_Blueprint_State` struct (`using bp: ^<Name>_Blueprint_State` Pseudo-OOP!)
//   - Persistent per-entity variable state across `On_Init`, `On_Tick`, AND bound
//     Odin Delegate / Input Manager callbacks (`hot.var_ptr(api, self, idx)`)
//   - Opt-In `Event_Tick` (`0.00 ns` per-frame cost when `Event_Tick` is omitted!)
//   - Native `@(hot_proc)` exports for `__on_init`, `__on_destroy`, and every
//     `Custom_Proc_Entry` (`mhgraph_<name>__proc_<Event>`) so `F7` hot-swaps
//     already-bound `input_manager` & custom delegates in ~240 ms without re-binding!

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "moonhug:engine"

sanitize_odin_ident :: proc(raw: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(raw) {
		c := raw[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (i > 0 && c >= '0' && c <= '9') {
			strings.write_byte(&sb, c)
		} else {
			strings.write_byte(&sb, '_')
		}
	}
	res := strings.to_string(sb)
	return len(res) > 0 ? res : "unnamed"
}

@(private = "file")
_node_has_var_pin_collision :: proc(g: ^engine.Visual_Graph, n: ^engine.VG_Node) -> bool {
	if g == nil || n == nil do return false
	for v in g.variables {
		vid := sanitize_odin_ident(v.name, context.temp_allocator)
		if vid == "api" || vid == "self" || vid == "bp" || vid == "dt" do return true
		for p in n.inputs {
			if p.pin_type != .Exec && sanitize_odin_ident(p.name, context.temp_allocator) == vid {
				return true
			}
		}
		for p in n.outputs {
			if p.pin_type != .Exec && sanitize_odin_ident(p.name, context.temp_allocator) == vid {
				return true
			}
		}
	}
	return false
}

// Formats the locked Odin signature banner displayed at the top of the Scoped Node Popup Micro-IDE!
build_scoped_node_signature :: proc(n: ^engine.VG_Node, g: ^engine.Visual_Graph = nil, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	fn_name := sanitize_odin_ident(n.title, context.temp_allocator)
	use_self := g != nil && len(g.variables) > 0 && engine.vg_has_using_space(g, "self") && !_node_has_var_pin_collision(g, n)
	state_t := g != nil ? fmt.tprintf("%s_Blueprint_State", sanitize_odin_ident(g.name != "" ? g.name : "Blueprint", context.temp_allocator)) : "Blueprint_State"

	if g != nil && len(g.variables) > 0 {
		fmt.sbprintf(&sb, "%s :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, %sbp: ^%s, dt: f32", fn_name, use_self ? "using " : "", state_t)
	} else {
		fmt.sbprintf(&sb, "%s :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32", fn_name)
	}
	for p in n.inputs {
		if p.pin_type == .Exec do continue
		pname := sanitize_odin_ident(p.name, context.temp_allocator)
		ptype := engine.vg_pin_odin_type(p.pin_type)
		if p.pass_mode == .By_Reference {
			fmt.sbprintf(&sb, ", %s: ^%s", pname, ptype)
		} else {
			fmt.sbprintf(&sb, ", %s: %s", pname, ptype)
		}
	}
	strings.write_byte(&sb, ')')

	has_ret := false
	for p in n.outputs {
		if p.pin_type != .Exec {
			has_ret = true
			break
		}
	}
	if has_ret {
		strings.write_string(&sb, " -> (")
		first := true
		for p in n.outputs {
			if p.pin_type == .Exec do continue
			if !first do strings.write_string(&sb, ", ")
			first = false
			fmt.sbprintf(&sb, "%s: %s", sanitize_odin_ident(p.name, context.temp_allocator), engine.vg_pin_odin_type(p.pin_type))
		}
		strings.write_byte(&sb, ')')
	}
	return strings.to_string(sb)
}

@(private = "file")
_emit_pin_default_expr :: proc(p: engine.VG_Pin_Def) -> string {
	#partial switch p.pin_type {
	case .Bool:     return p.default_bool ? "true" : "false"
	case .Int:      return fmt.tprintf("i32(%d)", p.default_int)
	case .Float:    return fmt.tprintf("f32(%.5f)", p.default_f32)
	case .Vec2:     return "[2]f32{0, 0}"
	case .Vec3:     return fmt.tprintf("[3]f32{{%.4f, %.4f, %.4f}}", p.default_vec3.x, p.default_vec3.y, p.default_vec3.z)
	case .Quat:     return "[4]f32{0, 0, 0, 1}"
	case .Entity:   return "self"
	case .Delegate: return "hot.Hot_Delegate{}"
	}
	return "f32(0)"
}

@(private = "file")
_resolve_transpiled_delegate_sym :: proc(g: ^engine.Visual_Graph, clean_graph: string, dst_node: ^engine.VG_Node, del_pin_idx: int) -> string {
	for w in g.wires {
		if w.to_uid == dst_node.uid && w.to_pin == del_pin_idx {
			if src_n := engine.vg_find_node(g, w.from_uid); src_n != nil && src_n.kind == .Custom_Proc_Entry {
				p_clean := sanitize_odin_ident(src_n.hot_proc_target != "" ? src_n.hot_proc_target : src_n.title, context.temp_allocator)
				return fmt.tprintf("mhgraph_%s__proc_%s", clean_graph, p_clean)
			}
		}
	}
	if dst_node.hot_proc_target != "" {
		if pn := engine.vg_find_custom_proc_node(g, dst_node.hot_proc_target); pn != nil {
			p_clean := sanitize_odin_ident(pn.hot_proc_target != "" ? pn.hot_proc_target : pn.title, context.temp_allocator)
			return fmt.tprintf("mhgraph_%s__proc_%s", clean_graph, p_clean)
		}
		return sanitize_odin_ident(dst_node.hot_proc_target, context.temp_allocator)
	}
	return ""
}

@(private = "file")
_transpile_pure_expr :: proc(g: ^engine.Visual_Graph, node_uid: int, out_pin: int, want_ref: bool, depth: int) -> string {
	if depth > 20 do return "f32(0)"
	n := engine.vg_find_node(g, node_uid)
	if n == nil || !n.enabled do return "f32(0)"

	#partial switch n.kind {
	case .Event_Tick:
		if out_pin == 1 do return "raw_dt"
		if out_pin == 2 do return "dt"
		return "dt"

	case .Custom_Proc_Entry:
		if out_pin == 2 do return "_payload_f32"
		if out_pin == 3 do return "_payload_v2"
		if out_pin == 4 do return "_pressed"
		return "f32(0)"

	case .Get_Variable:
		if engine.vg_find_var_index(g, n.var_name) >= 0 {
			v_field := fmt.tprintf("_bp.%s", sanitize_odin_ident(n.var_name))
			if want_ref do return fmt.tprintf("&%s", v_field)
			return v_field
		}
		return want_ref ? "&_dummy_f32" : "f32(0)"

	case .Get_Transform_Pos:
		if want_ref do return "_pos_ptr"
		return "(_pos_ptr != nil ? _pos_ptr^ : [3]f32{})"

	case .Math_Float:
		a := _transpile_input_expr(g, n, 0, depth + 1)
		b := _transpile_input_expr(g, n, 1, depth + 1)
		switch n.math_op {
		case .Add:      return fmt.tprintf("(%s + %s)", a, b)
		case .Sub:      return fmt.tprintf("(%s - %s)", a, b)
		case .Mul:      return fmt.tprintf("(%s * %s)", a, b)
		case .Div:      return fmt.tprintf("(abs(%s) > 1e-6 ? (%s / %s) : f32(0))", b, a, b)
		case .Sin_Wave: return fmt.tprintf("(math.sin((%s) * math.TAU) * (%s))", a, b)
		case .Damp:     return fmt.tprintf("hot.damp_f32(%s, %s, 8.0, dt)", a, b)
		}

	case .Vec3_Scale_Add:
		base  := _transpile_input_expr(g, n, 0, depth + 1)
		axis  := _transpile_input_expr(g, n, 1, depth + 1)
		scale := _transpile_input_expr(g, n, 2, depth + 1)
		return fmt.tprintf("(%s + (%s) * (%s))", base, axis, scale)

	case .Set_Variable, .Set_Transform_Pos, .Branch_If, .Set_Time_Scale, .Call_Hot_Proc, .Odin_Function_Node:
		return fmt.tprintf("_out_%d_%d", n.uid, out_pin)
	}
	return "f32(0)"
}

@(private = "file")
_transpile_input_expr :: proc(g: ^engine.Visual_Graph, dst_node: ^engine.VG_Node, in_pin: int, depth: int) -> string {
	if in_pin < 0 || in_pin >= len(dst_node.inputs) do return "f32(0)"
	pdef := dst_node.inputs[in_pin]
	want_ref := pdef.pass_mode == .By_Reference

	for w in g.wires {
		if w.to_uid == dst_node.uid && w.to_pin == in_pin {
			return _transpile_pure_expr(g, w.from_uid, w.from_pin, want_ref, depth)
		}
	}

	if want_ref {
		return fmt.tprintf("&_scratch_%d_%d", dst_node.uid, in_pin)
	}
	return _emit_pin_default_expr(pdef)
}

@(private = "file")
_emit_exec_chain :: proc(b: ^strings.Builder, g: ^engine.Visual_Graph, clean_graph: string, start_uid: int, indent: string, visited: ^map[int]bool, depth: int) {
	if start_uid == 0 || depth > 48 || visited^[start_uid] do return
	visited^[start_uid] = true

	n := engine.vg_find_node(g, start_uid)
	if n == nil do return

	next_pin := 0
	if n.enabled {
		#partial switch n.kind {
		case .Set_Variable:
			val_exp := _transpile_input_expr(g, n, 1, 0)
			if engine.vg_find_var_index(g, n.var_name) >= 0 {
				v_field := fmt.tprintf("_bp.%s", sanitize_odin_ident(n.var_name))
				fmt.sbprintf(b, "%s%s = %s\n", indent, v_field, val_exp)
				fmt.sbprintf(b, "%s_out_%d_1 := %s; _ = _out_%d_1\n", indent, n.uid, v_field, n.uid)
			}

		case .Set_Transform_Pos:
			val_exp := _transpile_input_expr(g, n, 1, 0)
			fmt.sbprintf(b, "%shot.set_pos(api, self, %s)\n", indent, val_exp)

		case .Set_Time_Scale:
			sc_exp := _transpile_input_expr(g, n, 1, 0)
			if n.per_object_ts {
				fmt.sbprintf(b, "%shot.set_object_timescale(api, self, %s)\n", indent, sc_exp)
			} else {
				fmt.sbprintf(b, "%sif api != nil && api.set_time_scale != nil {{ api.set_time_scale(%s) }}\n", indent, sc_exp)
			}

		case .Bind_Input_Action:
			tsym := _resolve_transpiled_delegate_sym(g, clean_graph, n, 1)
			if tsym != "" && n.action_name != "" {
				fmt.sbprintf(b, "%shot.bind_action(api, self, %q, %q, .%v, %d, %v)\n", indent, n.action_name, tsym, n.trigger_edge, n.input_priority, n.consume_input)
			}

		case .Unbind_Input_Action:
			if n.action_name != "" {
				fmt.sbprintf(b, "%shot.unbind_action(api, self, %q)\n", indent, n.action_name)
			}

		case .Bind_Input_Vector:
			tsym := _resolve_transpiled_delegate_sym(g, clean_graph, n, 1)
			if tsym != "" {
				fmt.sbprintf(b, "%shot.bind_vector(api, self, %v, %q, %d, %v)\n", indent, n.is_look_vector, tsym, n.input_priority, n.consume_input)
			}

		case .Unbind_Input_Vector:
			fmt.sbprintf(b, "%shot.unbind_vector(api, self, %v)\n", indent, n.is_look_vector)

		case .Bind_Debug_Key:
			tsym := _resolve_transpiled_delegate_sym(g, clean_graph, n, 1)
			if tsym != "" && n.debug_key_code > 0 {
				fmt.sbprintf(b, "%shot.bind_debug_key(api, self, %d, %q, .%v)\n", indent, n.debug_key_code, tsym, n.trigger_edge)
			}

		case .Unbind_Debug_Key:
			fmt.sbprintf(b, "%shot.unbind_debug_key(api, self, %d)\n", indent, n.debug_key_code)

		case .Unbind_All_Inputs:
			fmt.sbprintf(b, "%shot.unbind_all(api, self)\n", indent)

		case .Delegate_Bind:
			tsym := _resolve_transpiled_delegate_sym(g, clean_graph, n, 1)
			if tsym != "" && n.delegate_name != "" {
				fmt.sbprintf(b, "%shot.bind_delegate(api, self, %q, %q)\n", indent, n.delegate_name, tsym)
			}

		case .Delegate_Unbind:
			if n.delegate_name != "" {
				fmt.sbprintf(b, "%shot.unbind_delegate(api, self, %q)\n", indent, n.delegate_name)
			}

		case .Delegate_Broadcast:
			if n.delegate_name != "" {
				pay_exp := _transpile_input_expr(g, n, 1, 0)
				fmt.sbprintf(b, "%s_save_%s_state(api, self, frame, &_bp)\n", indent, clean_graph)
				fmt.sbprintf(b, "%shot.broadcast_delegate(api, self, %q, %s)\n", indent, n.delegate_name, pay_exp)
				fmt.sbprintf(b, "%s_bp = _load_%s_state(api, self, frame)\n", indent, clean_graph)
			}

		case .Call_Blueprint_Proc:
			if pn := engine.vg_find_custom_proc_node(g, n.hot_proc_target); pn != nil {
				pay_exp := _transpile_input_expr(g, n, 1, 0)
				p_clean := sanitize_odin_ident(pn.hot_proc_target != "" ? pn.hot_proc_target : pn.title, context.temp_allocator)
				fmt.sbprintf(b, "%s{{\n", indent)
				fmt.sbprintf(b, "%s\t_save_%s_state(api, self, frame, &_bp)\n", indent, clean_graph)
				fmt.sbprintf(b, "%s\t_call_f: hot.Hot_Call_Frame\n", indent)
				fmt.sbprintf(b, "%s\t_call_f.inputs[0] = {{pin_type = .Float, val_f32 = %s}}\n", indent, pay_exp)
				fmt.sbprintf(b, "%s\t_call_f.input_count = 1\n", indent)
				fmt.sbprintf(b, "%s\tmhgraph_%s__proc_%s(api, self, dt, &_call_f)\n", indent, clean_graph, p_clean)
				fmt.sbprintf(b, "%s\t_bp = _load_%s_state(api, self, frame)\n", indent, clean_graph)
				fmt.sbprintf(b, "%s}}\n", indent)
			}

		case .Branch_If:
			cond_exp := _transpile_input_expr(g, n, 1, 0)
			t_uid := 0
			f_uid := 0
			for w in g.wires {
				if w.from_uid == n.uid && w.from_pin == 0 do t_uid = w.to_uid
				if w.from_uid == n.uid && w.from_pin == 1 do f_uid = w.to_uid
			}
			fmt.sbprintf(b, "%sif %s {{\n", indent, cond_exp)
			sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
			_emit_exec_chain(b, g, clean_graph, t_uid, sub_indent, visited, depth + 1)
			fmt.sbprintf(b, "%s}} else {{\n", indent)
			_emit_exec_chain(b, g, clean_graph, f_uid, sub_indent, visited, depth + 1)
			fmt.sbprintf(b, "%s}}\n", indent)
			return

		case .Call_Hot_Proc:
			fmt.sbprintf(b, "%s{{\n", indent)
			fmt.sbprintf(b, "%s\t_sub_f: hot.Hot_Call_Frame\n", indent)
			arg_idx := 0
			for pi in 1 ..< len(n.inputs) {
				p := n.inputs[pi]
				if p.pin_type == .Exec do continue
				exp := _transpile_input_expr(g, n, pi, 0)
				if p.pass_mode == .By_Reference {
					fmt.sbprintf(b, "%s\t_sub_f.inputs[%d] = {{pin_type = .%v, pass_mode = .By_Reference, ref_ptr = %s}}\n", indent, arg_idx, p.pin_type, exp)
				} else {
					field := "val_f32"
					#partial switch p.pin_type {
					case .Bool: field = "val_bool"
					case .Int:  field = "val_int"
					case .Vec2: field = "val_vec2"
					case .Vec3: field = "val_vec3"
					}
					fmt.sbprintf(b, "%s\t_sub_f.inputs[%d] = {{pin_type = .%v, pass_mode = .Copy_Value, %s = %s}}\n", indent, arg_idx, p.pin_type, field, exp)
				}
				arg_idx += 1
			}
			fmt.sbprintf(b, "%s\t_sub_f.input_count = %d\n", indent, arg_idx)
			target_fn := n.hot_proc_target != "" ? sanitize_odin_ident(n.hot_proc_target) : "hot_harmonic_hover"
			fmt.sbprintf(b, "%s\t%s(api, self, dt, &_sub_f)\n", indent, target_fn)
			fmt.sbprintf(b, "%s}}\n", indent)

		case .Odin_Function_Node:
			for pi in 1 ..< len(n.inputs) {
				p := n.inputs[pi]
				if p.pin_type == .Exec || p.pass_mode != .By_Reference do continue
				wired := false
				for w in g.wires do if w.to_uid == n.uid && w.to_pin == pi { wired = true; break }
				if !wired {
					fmt.sbprintf(b, "%s_scratch_%d_%d := %s\n", indent, n.uid, pi, _emit_pin_default_expr(p))
				}
			}

			out_names := make([dynamic]string, context.temp_allocator)
			for po, oi in n.outputs {
				if po.pin_type == .Exec do continue
				append(&out_names, fmt.tprintf("_out_%d_%d", n.uid, oi))
			}

			fmt.sbprintf(b, "%s", indent)
			if len(out_names) > 0 {
				for on, idx in out_names {
					if idx > 0 do strings.write_string(b, ", ")
					strings.write_string(b, on)
				}
				strings.write_string(b, " := ")
			}
			fmt.sbprintf(b, "_node_%s_%d_body(api, self, &_bp, dt", clean_graph, n.uid)
			for pi in 1 ..< len(n.inputs) {
				if n.inputs[pi].pin_type == .Exec do continue
				fmt.sbprintf(b, ", %s", _transpile_input_expr(g, n, pi, 0))
			}
			strings.write_string(b, ")\n")
			for on in out_names {
				fmt.sbprintf(b, "%s_ = %s\n", indent, on)
			}
		}
	}

	next_uid := 0
	for w in g.wires {
		if w.from_uid == n.uid && w.from_pin == next_pin {
			next_uid = w.to_uid
			break
		}
	}
	_emit_exec_chain(b, g, clean_graph, next_uid, indent, visited, depth + 1)
}

@(private = "file")
_emit_proc_entry_boilerplate :: proc(b: ^strings.Builder, clean_name: string, proc_sym: string, is_custom_proc: bool) {
	fmt.sbprintf(b, "@(hot_proc)\n%s :: proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, raw_dt: f32, frame: ^hot.Hot_Call_Frame) {{\n", proc_sym)
	strings.write_string(b, "\tdt := api != nil && api.get_object_dt != nil ? api.get_object_dt(self, raw_dt) : raw_dt\n")
	strings.write_string(b, "\t_dummy_pos := [3]f32{}\n")
	strings.write_string(b, "\t_dummy_f32 := f32(0)\n")
	strings.write_string(b, "\t_pos_ptr := hot.pos_ref(api, self)\n")
	strings.write_string(b, "\tif _pos_ptr == nil do _pos_ptr = &_dummy_pos\n")
	if is_custom_proc {
		strings.write_string(b, "\t_payload_f32 := frame != nil && frame.input_count > 0 ? hot.slot_read_f32(&frame.inputs[0]) : f32(0)\n")
		strings.write_string(b, "\t_payload_v2  := frame != nil && frame.input_count > 1 ? hot.slot_read_vec2(&frame.inputs[1]) : [2]f32{}\n")
		strings.write_string(b, "\t_pressed     := frame != nil && frame.input_count > 2 ? hot.slot_read_bool(&frame.inputs[2]) : true\n")
	}
	fmt.sbprintf(b, "\t_bp := _load_%s_state(api, self, frame)\n", clean_name)
	fmt.sbprintf(b, "\tdefer _save_%s_state(api, self, frame, &_bp)\n\n", clean_name)
}

@(private = "file")
_emit_proc_exit_boilerplate :: proc(b: ^strings.Builder, is_custom_proc: bool) {
	if is_custom_proc {
		strings.write_string(b, "\t_ = _payload_f32; _ = _payload_v2; _ = _pressed\n")
	}
	strings.write_string(b, "\t_ = raw_dt; _ = dt; _ = _pos_ptr; _ = _dummy_f32; _ = frame; _ = _bp\n")
	strings.write_string(b, "}\n\n")
}

// Generates the complete, `-vet-unused` clean `.odin` source string for `g`!
transpile_graph_to_odin :: proc(g: ^engine.Visual_Graph, allocator := context.allocator) -> (odin_source: string, main_proc_name: string) {
	clean_name := sanitize_odin_ident(g.name != "" ? g.name : "custom_graph", context.temp_allocator)
	main_proc_name = strings.clone(fmt.tprintf("mhgraph_%s", clean_name), allocator)
	state_struct := fmt.tprintf("%s_Blueprint_State", clean_name)

	b := strings.builder_make(allocator)
	strings.write_string(&b, "#+feature using-stmt\n")
	strings.write_string(&b, "package hot_scripts\n\n")
	fmt.sbprintf(&b, "// =============================================================================\n")
	fmt.sbprintf(&b, "// AUTO-TRANSPILED BY HAATI BLUEPRINT STUDIO (`%s.bodin`)\n", clean_name)
	fmt.sbprintf(&b, "// =============================================================================\n")
	strings.write_string(&b, "// Flat Data-Oriented Odin struct + `@(hot_proc)` C-ABI machine code (0.00 ms VM tax!)\n\n")

	strings.write_string(&b, "@(require) import \"core:math\"\n")
	strings.write_string(&b, "@(require) import \"core:math/linalg\"\n")
	if engine.vg_has_using_space(g, "ease") {
		strings.write_string(&b, "@(require) import \"core:math/ease\"\n")
	}
	if engine.vg_has_using_space(g, "rand") {
		strings.write_string(&b, "@(require) import \"core:math/rand\"\n")
	}
	strings.write_string(&b, "import hot \"moonhug:engine/hot_api\"\n\n")

	// 1. Flat Data-Oriented Blueprint State Struct (`Pseudo-OOP` `using bp` backing!)
	fmt.sbprintf(&b, "%s :: struct {{\n", state_struct)
	if len(g.variables) == 0 {
		strings.write_string(&b, "\t_reserved: u8,\n")
	} else {
		for v in g.variables {
			fmt.sbprintf(&b, "\t%s: %s,\n", sanitize_odin_ident(v.name, context.temp_allocator), engine.vg_pin_odin_type(v.pin_type))
		}
	}
	strings.write_string(&b, "}\n\n")

	// State loader & writer bridging persistent per-entity `hot.var_ptr(api, self, vi)` AND `Hot_Call_Frame` slots!
	fmt.sbprintf(&b, "_load_%s_state :: #force_inline proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, frame: ^hot.Hot_Call_Frame) -> (st: %s) {{\n", clean_name, state_struct)
	for v, vi in g.variables {
		v_id := sanitize_odin_ident(v.name, context.temp_allocator)
		ptype := engine.vg_pin_odin_type(v.pin_type)
		def_p := engine.VG_Pin_Def{pin_type = v.pin_type, default_f32 = v.default_f32, default_int = v.default_int, default_bool = v.default_bool, default_vec3 = v.default_vec3}
		fmt.sbprintf(&b, "\tif vp := hot.var_ptr(api, self, %d); vp != nil {{\n", vi)
		fmt.sbprintf(&b, "\t\tst.%s = (cast(^%s)vp)^\n", v_id, ptype)
		if vi == 0 && v.pin_type == .Float {
			fmt.sbprintf(&b, "\t}} else if frame != nil && frame.input_count > 0 {{\n\t\tst.%s = hot.slot_read_f32(&frame.inputs[0])\n", v_id)
		} else if vi == 1 && v.pin_type == .Float {
			fmt.sbprintf(&b, "\t}} else if frame != nil && frame.input_count > 1 {{\n\t\tst.%s = hot.slot_read_f32(&frame.inputs[1])\n", v_id)
		} else if vi == 2 && v.pin_type == .Float {
			fmt.sbprintf(&b, "\t}} else if frame != nil && frame.input_count > 2 {{\n\t\tst.%s = hot.slot_read_f32(&frame.inputs[2])\n", v_id)
		}
		fmt.sbprintf(&b, "\t}} else {{\n\t\tst.%s = %s\n\t}}\n", v_id, _emit_pin_default_expr(def_p))
	}
	strings.write_string(&b, "\t_ = api; _ = self; _ = frame\n\treturn\n}\n\n")

	fmt.sbprintf(&b, "_save_%s_state :: #force_inline proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, frame: ^hot.Hot_Call_Frame, st: ^%s) {{\n", clean_name, state_struct)
	for v, vi in g.variables {
		v_id := sanitize_odin_ident(v.name, context.temp_allocator)
		ptype := engine.vg_pin_odin_type(v.pin_type)
		fmt.sbprintf(&b, "\tif vp := hot.var_ptr(api, self, %d); vp != nil {{ (cast(^%s)vp)^ = st.%s }}\n", vi, ptype, v_id)
		if vi == 2 && v.pin_type == .Float {
			fmt.sbprintf(&b, "\tif frame != nil && frame.input_count > 2 {{ if ap := hot.slot_ref_f32(&frame.inputs[2]); ap != nil {{ ap^ = st.%s }} }}\n", v_id)
		}
	}
	strings.write_string(&b, "\t_ = api; _ = self; _ = frame; _ = st\n}\n\n")

	// 2. Emit each `Odin_Function_Node` as both a `#force_inline` typed Odin proc AND a hot-callable `@(hot_proc)` wrapper!
	use_self_global := len(g.variables) > 0 && engine.vg_has_using_space(g, "self")
	use_math_ns     := engine.vg_has_using_space(g, "using_math")
	use_linalg_ns   := engine.vg_has_using_space(g, "using_linalg")

	for &n in g.nodes {
		if n.kind != .Odin_Function_Node do continue

		use_self_here := use_self_global && !_node_has_var_pin_collision(g, &n)
		fmt.sbprintf(&b, "// Scoped Odin Node #%d: %s\n", n.uid, n.title)
		fmt.sbprintf(
			&b,
			"_node_%s_%d_body :: #force_inline proc \"c\" (\n\tapi: ^hot.Engine_Hot_API,\n\tself: hot.Hot_Entity,\n\t%sbp: ^%s,\n\tdt: f32",
			clean_name,
			n.uid,
			use_self_here ? "using " : "",
			state_struct,
		)
		for p in n.inputs {
			if p.pin_type == .Exec do continue
			pname := sanitize_odin_ident(p.name, context.temp_allocator)
			ptype := engine.vg_pin_odin_type(p.pin_type)
			if p.pass_mode == .By_Reference {
				fmt.sbprintf(&b, ",\n\t%s: ^%s", pname, ptype)
			} else {
				fmt.sbprintf(&b, ",\n\t%s: %s", pname, ptype)
			}
		}
		strings.write_string(&b, ",\n)")

		ret_pins := make([dynamic]engine.VG_Pin_Def, context.temp_allocator)
		for p in n.outputs {
			if p.pin_type != .Exec do append(&ret_pins, p)
		}
		if len(ret_pins) > 0 {
			strings.write_string(&b, " -> (")
			for rp, ri in ret_pins {
				if ri > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "%s: %s", sanitize_odin_ident(rp.name, context.temp_allocator), engine.vg_pin_odin_type(rp.pin_type))
			}
			strings.write_byte(&b, ')')
		}
		strings.write_string(&b, " {\n")
		if use_math_ns   do strings.write_string(&b, "\tusing math\n")
		if use_linalg_ns do strings.write_string(&b, "\tusing linalg\n")

		for ln in strings.split_lines(n.odin_body, context.temp_allocator) {
			trimmed_cr := strings.trim_suffix(ln, "\r")
			if len(strings.trim_space(trimmed_cr)) > 0 {
				fmt.sbprintf(&b, "\t%s\n", trimmed_cr)
			}
		}

		strings.write_string(&b, "\t_ = api; _ = self; _ = bp; _ = dt\n")
		for p in n.inputs {
			if p.pin_type == .Exec do continue
			fmt.sbprintf(&b, "\t_ = %s\n", sanitize_odin_ident(p.name, context.temp_allocator))
		}
		strings.write_string(&b, "\treturn\n}\n\n")

		node_sym := fmt.tprintf("_mhnode_%s_%d", clean_name, n.uid)
		if n.hot_proc_target != "" && !strings.has_prefix(n.hot_proc_target, "_mhnode_") {
			node_sym = sanitize_odin_ident(n.hot_proc_target, context.temp_allocator)
		}
		fmt.sbprintf(&b, "@(hot_proc)\n%s :: proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, frame: ^hot.Hot_Call_Frame) {{\n", node_sym)
		strings.write_string(&b, "\tif frame == nil do return\n")
		fmt.sbprintf(&b, "\t_bp := _load_%s_state(api, self, frame)\n", clean_name)
		fmt.sbprintf(&b, "\tdefer _save_%s_state(api, self, frame, &_bp)\n", clean_name)
		arg_i := 0
		call_args := make([dynamic]string, context.temp_allocator)
		for p in n.inputs {
			if p.pin_type == .Exec do continue
			is_ref := p.pass_mode == .By_Reference
			expr := "f32(0)"
			#partial switch p.pin_type {
			case .Float: expr = is_ref ? fmt.tprintf("hot.slot_ref_f32(&frame.inputs[%d])", arg_i)  : fmt.tprintf("hot.slot_read_f32(&frame.inputs[%d])", arg_i)
			case .Vec2:  expr = is_ref ? fmt.tprintf("hot.slot_ref_vec2(&frame.inputs[%d])", arg_i) : fmt.tprintf("hot.slot_read_vec2(&frame.inputs[%d])", arg_i)
			case .Vec3:  expr = is_ref ? fmt.tprintf("hot.slot_ref_vec3(&frame.inputs[%d])", arg_i) : fmt.tprintf("hot.slot_read_vec3(&frame.inputs[%d])", arg_i)
			case .Int:   expr = is_ref ? fmt.tprintf("hot.slot_ref_int(&frame.inputs[%d])", arg_i)  : fmt.tprintf("hot.slot_read_int(&frame.inputs[%d])", arg_i)
			case .Bool:  expr = is_ref ? fmt.tprintf("hot.slot_ref_bool(&frame.inputs[%d])", arg_i) : fmt.tprintf("hot.slot_read_bool(&frame.inputs[%d])", arg_i)
			}
			append(&call_args, expr)
			arg_i += 1
		}
		strings.write_string(&b, "\t")
		if len(ret_pins) > 0 {
			for _, ri in ret_pins {
				if ri > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "_r%d", ri)
			}
			strings.write_string(&b, " := ")
		}
		fmt.sbprintf(&b, "_node_%s_%d_body(api, self, &_bp, dt", clean_name, n.uid)
		for ca in call_args do fmt.sbprintf(&b, ", %s", ca)
		strings.write_string(&b, ")\n")
		for rp, ri in ret_pins {
			field := "val_f32"
			#partial switch rp.pin_type {
			case .Bool: field = "val_bool"
			case .Int:  field = "val_int"
			case .Vec2: field = "val_vec2"
			case .Vec3: field = "val_vec3"
			}
			fmt.sbprintf(&b, "\tframe.outputs[%d] = {{pin_type = .%v, %s = _r%d}}\n", ri, rp.pin_type, field, ri)
		}
		fmt.sbprintf(&b, "\tframe.output_count = %d\n}}\n\n", len(ret_pins))
	}

	// 3. Emit every `Custom_Proc_Entry` as its own hot-swappable `@(hot_proc)` Delegate target!
	emitted_procs := make(map[string]bool, 16, context.temp_allocator)
	for n in g.nodes {
		if n.kind != .Custom_Proc_Entry || !n.enabled do continue
		p_clean := sanitize_odin_ident(n.hot_proc_target != "" ? n.hot_proc_target : n.title, context.temp_allocator)
		proc_sym := fmt.tprintf("mhgraph_%s__proc_%s", clean_name, p_clean)
		if proc_sym in emitted_procs do continue
		emitted_procs[proc_sym] = true

		_emit_proc_entry_boilerplate(&b, clean_name, proc_sym, true)
		entry_next := 0
		for w in g.wires {
			if w.from_uid == n.uid && w.from_pin == 1 {
				entry_next = w.to_uid
				break
			}
		}
		visited := make(map[int]bool, context.temp_allocator)
		_emit_exec_chain(&b, g, clean_name, entry_next, "\t", &visited, 0)
		_emit_proc_exit_boilerplate(&b, true)
	}

	// 4. Emit `Event_Init` (`__on_init`) when present!
	for n in g.nodes {
		if n.kind == .Event_Init && n.enabled {
			_emit_proc_entry_boilerplate(&b, clean_name, fmt.tprintf("%s__on_init", main_proc_name), false)
			entry_next := 0
			for w in g.wires do if w.from_uid == n.uid && w.from_pin == 0 { entry_next = w.to_uid; break }
			visited := make(map[int]bool, context.temp_allocator)
			_emit_exec_chain(&b, g, clean_name, entry_next, "\t", &visited, 0)
			_emit_proc_exit_boilerplate(&b, false)
			break
		}
	}

	// 5. Emit `Event_Destroy` (`__on_destroy`) when present!
	for n in g.nodes {
		if n.kind == .Event_Destroy && n.enabled {
			_emit_proc_entry_boilerplate(&b, clean_name, fmt.tprintf("%s__on_destroy", main_proc_name), false)
			entry_next := 0
			for w in g.wires do if w.from_uid == n.uid && w.from_pin == 0 { entry_next = w.to_uid; break }
			visited := make(map[int]bool, context.temp_allocator)
			_emit_exec_chain(&b, g, clean_name, entry_next, "\t", &visited, 0)
			_emit_proc_exit_boilerplate(&b, false)
			break
		}
	}

	// 6. Opt-In `Event_Tick` (`mhgraph_<name>`): ONLY emitted when an enabled `Event_Tick` node exists!
	//    Event-only Blueprints omit `mhgraph_<name>` completely -> `0.00 ns` per-frame runtime cost!
	for n in g.nodes {
		if n.kind == .Event_Tick && n.enabled {
			_emit_proc_entry_boilerplate(&b, clean_name, main_proc_name, false)
			entry_next := 0
			for w in g.wires do if w.from_uid == n.uid && w.from_pin == 0 { entry_next = w.to_uid; break }
			visited := make(map[int]bool, context.temp_allocator)
			_emit_exec_chain(&b, g, clean_name, entry_next, "\t", &visited, 0)
			_emit_proc_exit_boilerplate(&b, false)
			break
		}
	}

	return strings.to_string(b), main_proc_name
}

// Writes unified `<graph>.bodin` (valid Odin code + `@BODIN_GRAPH_V1` layout block in ONE file,
// or legacy `.mhgraph` JSON if requested) AND syncs git-ignored `moonhug/hot_scripts/<name>_mhgraph_generated.odin`
// for instant `hot_cartridge.dll` hot-swap!
bake_graph_to_odin_file :: proc(g: ^engine.Visual_Graph, mhgraph_save_path: string = "") -> (gen_odin_abs: string, proc_name: string, ok: bool) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	odin_code, main_proc := transpile_graph_to_odin(g, context.temp_allocator)

	if mhgraph_save_path != "" {
		abs_g := mhgraph_save_path
		if !filepath.is_abs(abs_g) {
			abs_g, _ = filepath.join({repo_root, mhgraph_save_path}, context.temp_allocator)
		}
		dir_g: string
		{
			context.allocator = context.temp_allocator
			dir_g = filepath.dir(abs_g)
		}
		_ = os.make_directory_all(dir_g)
		if strings.has_suffix(strings.to_lower(abs_g, context.temp_allocator), ".bodin") {
			_ = engine.vg_save_bodin_file(g, abs_g, odin_code)
		} else {
			_ = engine.vg_save_to_file(g, abs_g)
		}
		engine.visual_script_invalidate_cached_graph(mhgraph_save_path)
	}

	clean_name := sanitize_odin_ident(g.name != "" ? g.name : "custom_graph", context.temp_allocator)
	rel_odin := fmt.tprintf("moonhug/hot_scripts/%s_mhgraph_generated.odin", clean_name)
	abs_odin, _ := filepath.join({repo_root, rel_odin}, context.temp_allocator)
	dir_odin: string
	{
		context.allocator = context.temp_allocator
		dir_odin = filepath.dir(abs_odin)
	}
	_ = os.make_directory_all(dir_odin)

	if os.write_entire_file(abs_odin, transmute([]u8)odin_code) != nil {
		return "", "", false
	}
	norm_abs, _ := strings.replace_all(abs_odin, "\\", "/", context.temp_allocator)
	return norm_abs, main_proc, true
}
