package visual_script

// =============================================================================
// DETERMINISTIC BLUEPRINT & NIAGARA `.bodin` -> NATIVE `.odin` TRANSPILER V6
// =============================================================================
// Compiles a `Visual_Graph` Blueprint into clean, human-readable, `-vet-unused`
// safe Data-Oriented Odin machine code (`haati/hot_scripts/<name>_mhgraph_generated.odin`):
//   - User-declared Odin `enum u8`, `bit_set[Enum; u8]`, POD `struct` (`using`),
//     exact bit-widths (`u8`, `i8`, `u16`, `i16`, `u32`, `u64`, `f64`),
//     Fixed `[N]T` (preserving `[8]f32`), & C-ABI `BP_Bounded_<T>_<Cap>`
//   - Universal 4-mode `For_Loop` (`0..=N`, `0..<N`, `For_In_Value`, `For_In_Ref`,
//     `Condition`) + `#reverse`, `Break_Loop`, `Continue_Loop`, & `10_000` fuse
//   - Exhaustive `Switch_Value`, `BitSet_Op`, `Make_Struct`/`Break_Struct`,
//     `Array_Op`, `Defer_Exec` (`defer { ... }`), `Or_Branch`, `Auto_Cast`,
//     `Reroute_Knot`, Split/Recombine inline sub-pins, real V3 `hot.*` bridges,
//     & zero-boilerplate `@(bp_node)` `Call_Hot_Proc` exports.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import cs "haati:editor/code_studio"
import "haati:engine"
import hot "haati:engine/hot_api"

sanitize_odin_ident :: cs.sanitize_odin_ident

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

@(private)
_pin_odin_type_in_graph :: proc(g: ^engine.Visual_Graph, p: engine.VG_Pin_Def, allocator := context.temp_allocator) -> string {
	ck := engine.vg_pin_container_kind(p)
	v_tmp := engine.VG_Var_Decl{
		pin_type         = p.pin_type,
		is_array         = p.is_array || ck != .Single,
		container_kind   = ck,
		custom_type_name = p.custom_type_name,
	}
	return engine.vg_var_odin_type_ex(g, v_tmp, allocator)
}

@(private = "file")
_pin_def_from_var_decl :: #force_inline proc(v: engine.VG_Var_Decl) -> engine.VG_Pin_Def {
	return engine.VG_Pin_Def{
		pin_type         = v.pin_type,
		custom_type_name = v.custom_type_name,
		default_f32      = v.default_f32,
		default_int      = v.default_int,
		default_i64      = v.default_i64,
		default_u64      = v.default_u64,
		default_f64      = v.default_f64,
		default_bool     = v.default_bool,
		default_vec2     = v.default_vec2,
		default_vec3     = v.default_vec3,
		default_vec4     = v.default_vec4,
		default_str      = v.default_str,
	}
}

@(private = "file")
_emit_hot_call_frame_inputs :: proc(
	b:            ^strings.Builder,
	g:            ^engine.Visual_Graph,
	clean_graph:  string,
	n:            ^engine.VG_Node,
	indent:       string,
	frame_expr:   string,
	start_pin:    int,
	start_slot:   int,
	use_in_param: bool,
) -> int {
	arg_idx := start_slot
	for pi in start_pin ..< len(n.inputs) {
		if arg_idx >= hot.HOT_MAX_ARGS do break
		p := n.inputs[pi]
		if p.pin_type == .Exec || p.split_parent_name != "" do continue
		exp := use_in_param ? fmt.tprintf("in_%d", pi) : _transpile_input_expr(g, clean_graph, n, pi, 0)
		if p.pass_mode == .By_Reference {
			fmt.sbprintf(b, "%s%s.inputs[%d] = {{pin_type = .%v, pass_mode = .By_Reference, ref_ptr = %s}}\n", indent, frame_expr, arg_idx, p.pin_type, exp)
		} else if engine.vg_pin_container_kind(p) == .Slice {
			fmt.sbprintf(b, "%s%s.inputs[%d] = {{pin_type = .%v, pass_mode = .Copy_Value, ref_ptr = rawptr(raw_data(%s)), slice_len = i32(len(%s)), slice_cap = -1}}\n", indent, frame_expr, arg_idx, p.pin_type, exp, exp)
		} else if p.pin_type == .Enum_U8 || p.pin_type == .BitSet_U8 {
			fmt.sbprintf(b, "%s%s.inputs[%d] = {{pin_type = .%v, pass_mode = .Copy_Value, val_u8 = u8(%s)}}\n", indent, frame_expr, arg_idx, p.pin_type, exp)
		} else {
			fmt.sbprintf(b, "%s%s.inputs[%d] = {{pin_type = .%v, pass_mode = .Copy_Value, %s = %s}}\n", indent, frame_expr, arg_idx, p.pin_type, _slot_field_for_pin(p.pin_type), exp)
		}
		arg_idx += 1
	}
	return arg_idx
}

@(private = "file")
_emit_lifecycle_event_proc :: proc(
	b:          ^strings.Builder,
	g:          ^engine.Visual_Graph,
	clean_name: string,
	kind:       engine.VG_Node_Kind,
	proc_sym:   string,
	is_trigger: bool = false,
) {
	for n in g.nodes {
		if n.kind == kind && n.enabled {
			_emit_proc_entry_boilerplate(b, clean_name, proc_sym, false, is_trigger = is_trigger)
			entry_next := 0
			for w in g.wires do if w.from_uid == n.uid && w.from_pin == 0 { entry_next = w.to_uid; break }
			visited := make(map[int]bool, context.temp_allocator)
			_emit_exec_chain(b, g, clean_name, entry_next, "\t", &visited, 0)
			_emit_proc_exit_boilerplate(b, false)
			break
		}
	}
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
		if p.pin_type == .Exec || p.split_parent_name != "" do continue
		pname := sanitize_odin_ident(p.name, context.temp_allocator)
		ptype := _pin_odin_type_in_graph(g, p, context.temp_allocator)
		if p.pass_mode == .By_Reference {
			fmt.sbprintf(&sb, ", %s: ^%s", pname, ptype)
		} else {
			fmt.sbprintf(&sb, ", %s: %s", pname, ptype)
		}
	}
	strings.write_byte(&sb, ')')

	has_ret := false
	for p in n.outputs {
		if p.pin_type != .Exec && p.split_parent_name == "" {
			has_ret = true
			break
		}
	}
	if has_ret {
		strings.write_string(&sb, " -> (")
		first := true
		for p in n.outputs {
			if p.pin_type == .Exec || p.split_parent_name != "" do continue
			if !first do strings.write_string(&sb, ", ")
			first = false
			fmt.sbprintf(&sb, "%s: %s", sanitize_odin_ident(p.name, context.temp_allocator), _pin_odin_type_in_graph(g, p, context.temp_allocator))
		}
		strings.write_byte(&sb, ')')
	}
	return strings.to_string(sb)
}

@(private = "file")
_emit_pin_default_expr :: proc(p: engine.VG_Pin_Def, g: ^engine.Visual_Graph = nil) -> string {
	pck := engine.vg_pin_container_kind(p)
	if pck == .Slice || pck == .Dynamic_Array {
		return "nil"
	}
	if p.is_array {
		return fmt.tprintf("%s{{}}", _pin_odin_type_in_graph(g, p, context.temp_allocator))
	}
	#partial switch p.pin_type {
	case .Raw_Ptr:        return "nil"
	case .Bool:           return p.default_bool ? "true" : "false"
	case .Int:            return fmt.tprintf("i32(%d)", p.default_int)
	case .Int64:          return fmt.tprintf("i64(%d)", p.default_i64)
	case .U8:             return fmt.tprintf("u8(%d)", u8(p.default_u64 != 0 ? p.default_u64 : u64(max(p.default_int, 0))))
	case .I8:             return fmt.tprintf("i8(%d)", i8(p.default_int))
	case .U16:            return fmt.tprintf("u16(%d)", u16(p.default_u64 != 0 ? p.default_u64 : u64(max(p.default_int, 0))))
	case .I16:            return fmt.tprintf("i16(%d)", i16(p.default_int))
	case .U32:            return fmt.tprintf("u32(%d)", u32(p.default_u64 != 0 ? p.default_u64 : u64(max(p.default_int, 0))))
	case .U64:            return fmt.tprintf("u64(%d)", p.default_u64)
	case .Float:          return fmt.tprintf("f32(%.5f)", p.default_f32)
	case .F64:            return fmt.tprintf("f64(%.8f)", p.default_f64 != 0 ? p.default_f64 : f64(p.default_f32))
	case .Vec2:           return fmt.tprintf("[2]f32{{%.4f, %.4f}}", p.default_vec2.x, p.default_vec2.y)
	case .Vec3:           return fmt.tprintf("[3]f32{{%.4f, %.4f, %.4f}}", p.default_vec3.x, p.default_vec3.y, p.default_vec3.z)
	case .Vec4:           return fmt.tprintf("[4]f32{{%.4f, %.4f, %.4f, %.4f}}", p.default_vec4.x, p.default_vec4.y, p.default_vec4.z, p.default_vec4.w)
	case .Quat:
		q := p.default_vec4
		if q == ([4]f32{}) do q = {0, 0, 0, 1}
		return fmt.tprintf("[4]f32{{%.4f, %.4f, %.4f, %.4f}}", q.x, q.y, q.z, q.w)
	case .String, .Asset: return fmt.tprintf("cstring(%q)", p.default_str)
	case .Entity:         return "self"
	case .Delegate:       return "hot.Hot_Delegate{}"
	case .Enum_U8:
		if ed := engine.vg_find_enum_decl(g, p.custom_type_name); ed != nil {
			ename := sanitize_odin_ident(ed.name, context.temp_allocator)
			if len(ed.variants) > 0 {
				vi := clamp(int(p.default_u64), 0, len(ed.variants) - 1)
				return fmt.tprintf("%s.%s", ename, sanitize_odin_ident(ed.variants[vi], context.temp_allocator))
			}
			return fmt.tprintf("%s(0)", ename)
		}
		return p.custom_type_name != "" ? fmt.tprintf("%s(0)", sanitize_odin_ident(p.custom_type_name, context.temp_allocator)) : "u8(0)"
	case .BitSet_U8:
		bs_type := _pin_odin_type_in_graph(g, p, context.temp_allocator)
		if bs_type == "" || bs_type == "u8" do return "u8(0)"
		if ed := engine.vg_find_enum_decl(g, p.custom_type_name); ed != nil && p.default_u64 != 0 {
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "%s{{", bs_type)
			first := true
			for v, vi in ed.variants {
				if vi >= 8 do break
				if (p.default_u64 & (u64(1) << u64(vi))) != 0 {
					if !first do strings.write_string(&sb, ", ")
					first = false
					fmt.sbprintf(&sb, ".%s", sanitize_odin_ident(v, context.temp_allocator))
				}
			}
			strings.write_byte(&sb, '}')
			return strings.to_string(sb)
		}
		return fmt.tprintf("%s{{}}", bs_type)
	case .Struct_Val:
		st_name := p.custom_type_name != "" ? sanitize_odin_ident(p.custom_type_name, context.temp_allocator) : ""
		return st_name != "" ? fmt.tprintf("%s{{}}", st_name) : "struct{}{}"
	}
	return "f32(0)"
}

@(private = "file")
_emit_var_default_expr :: proc(v: engine.VG_Var_Decl, g: ^engine.Visual_Graph) -> string {
	ck := engine.vg_resolve_container_kind(v)
	if ck == .Slice || ck == .Dynamic_Array {
		return "nil"
	}
	if ck != .Single {
		v_type := engine.vg_var_odin_type_ex(g, v, context.temp_allocator)
		if ck == .Fixed_Array && v.pin_type == .Float && len(v.default_f32_list) > 0 {
			max_n := v.array_count > 0 ? v.array_count : 8
			n := min(len(v.default_f32_list), max_n)
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "%s{{", v_type)
			for i in 0 ..< n {
				if i > 0 do strings.write_string(&sb, ", ")
				fmt.sbprintf(&sb, "f32(%.5f)", v.default_f32_list[i])
			}
			strings.write_byte(&sb, '}')
			return strings.to_string(sb)
		}
		if ck == .Bounded_Array && v.pin_type == .Float && len(v.default_f32_list) > 0 {
			max_n := v.array_count > 0 ? v.array_count : 8
			n := min(len(v.default_f32_list), max_n)
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "%s{{data = {{", v_type)
			for i in 0 ..< n {
				if i > 0 do strings.write_string(&sb, ", ")
				fmt.sbprintf(&sb, "f32(%.5f)", v.default_f32_list[i])
			}
			fmt.sbprintf(&sb, "}}, count = %d}}", n)
			return strings.to_string(sb)
		}
		return fmt.tprintf("%s{{}}", v_type)
	}
	return _emit_pin_default_expr(_pin_def_from_var_decl(v), g)
}

@(private = "file")
_slot_field_for_pin :: proc(pt: hot.Hot_Pin_Type) -> string {
	#partial switch pt {
	case .Bool:                   return "val_bool"
	case .Int:                    return "val_int"
	case .Int64:                  return "val_i64"
	case .U8, .Enum_U8, .BitSet_U8: return "val_u8"
	case .I8:                     return "val_i8"
	case .U16:                    return "val_u16"
	case .I16:                    return "val_i16"
	case .U32:                    return "val_u32"
	case .U64:                    return "val_u64"
	case .Float:                  return "val_f32"
	case .F64:                    return "val_f64"
	case .Vec2:                   return "val_vec2"
	case .Vec3:                   return "val_vec3"
	case .Vec4:                   return "val_vec4"
	case .Quat:                   return "val_quat"
	case .String, .Asset:         return "val_cstr"
	case .Entity:                 return "val_ent"
	case .Delegate:               return "val_delegate"
	case .Raw_Ptr:                return "val_ptr"
	}
	return "val_f32"
}

@(private = "file")
_slot_read_call_for_pin :: proc(p: engine.VG_Pin_Def, slot_expr: string, is_ref: bool = false, g: ^engine.Visual_Graph = nil) -> string {
	if engine.vg_pin_container_kind(p) == .Slice {
		elem_t := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = p.pin_type, custom_type_name = p.custom_type_name}, context.temp_allocator)
		return fmt.tprintf("(proc(s: ^hot.Hot_Slot) -> []%s {{ d, l := hot.slot_read_slice_raw(s); return (d != nil && l > 0) ? ([^]%s)(d)[:l] : nil }})(%s)", elem_t, elem_t, slot_expr)
	}
	#partial switch p.pin_type {
	case .Raw_Ptr:        return is_ref ? fmt.tprintf("hot.slot_ref_rawptr(%s)", slot_expr) : fmt.tprintf("hot.slot_read_rawptr(%s)", slot_expr)
	case .Float:          return is_ref ? fmt.tprintf("hot.slot_ref_f32(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_f32(%s)", slot_expr)
	case .F64:            return is_ref ? fmt.tprintf("hot.slot_ref_f64(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_f64(%s)", slot_expr)
	case .Vec2:           return is_ref ? fmt.tprintf("hot.slot_ref_vec2(%s)", slot_expr)   : fmt.tprintf("hot.slot_read_vec2(%s)", slot_expr)
	case .Vec3:           return is_ref ? fmt.tprintf("hot.slot_ref_vec3(%s)", slot_expr)   : fmt.tprintf("hot.slot_read_vec3(%s)", slot_expr)
	case .Vec4:           return is_ref ? fmt.tprintf("hot.slot_ref_vec4(%s)", slot_expr)   : fmt.tprintf("hot.slot_read_vec4(%s)", slot_expr)
	case .Quat:           return is_ref ? fmt.tprintf("hot.slot_ref_quat(%s)", slot_expr)   : fmt.tprintf("hot.slot_read_quat(%s)", slot_expr)
	case .Int:            return is_ref ? fmt.tprintf("hot.slot_ref_int(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_int(%s)", slot_expr)
	case .Int64:          return is_ref ? fmt.tprintf("hot.slot_ref_i64(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_i64(%s)", slot_expr)
	case .U8:             return is_ref ? fmt.tprintf("hot.slot_ref_u8(%s)", slot_expr)     : fmt.tprintf("hot.slot_read_u8(%s)", slot_expr)
	case .I8:             return is_ref ? fmt.tprintf("hot.slot_ref_i8(%s)", slot_expr)     : fmt.tprintf("hot.slot_read_i8(%s)", slot_expr)
	case .U16:            return is_ref ? fmt.tprintf("hot.slot_ref_u16(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_u16(%s)", slot_expr)
	case .I16:            return is_ref ? fmt.tprintf("hot.slot_ref_i16(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_i16(%s)", slot_expr)
	case .U32:            return is_ref ? fmt.tprintf("hot.slot_ref_u32(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_u32(%s)", slot_expr)
	case .U64:            return is_ref ? fmt.tprintf("hot.slot_ref_u64(%s)", slot_expr)    : fmt.tprintf("hot.slot_read_u64(%s)", slot_expr)
	case .Bool:           return is_ref ? fmt.tprintf("hot.slot_ref_bool(%s)", slot_expr)   : fmt.tprintf("hot.slot_read_bool(%s)", slot_expr)
	case .Entity:         return is_ref ? fmt.tprintf("hot.slot_ref_entity(%s)", slot_expr) : fmt.tprintf("hot.slot_read_entity(%s)", slot_expr)
	case .String, .Asset: return fmt.tprintf("hot.slot_read_cstr(%s)", slot_expr)
	case .Enum_U8, .BitSet_U8:
		tname := _pin_odin_type_in_graph(g, p, context.temp_allocator)
		if is_ref {
			return fmt.tprintf("(cast(^%s)hot.slot_ref_u8(%s))", tname, slot_expr)
		}
		return fmt.tprintf("%s(hot.slot_read_u8(%s))", tname, slot_expr)
	case .Struct_Val:
		tname := _pin_odin_type_in_graph(g, p, context.temp_allocator)
		if is_ref {
			return fmt.tprintf("(cast(^%s)hot.slot_ref_struct_bytes(%s))", tname, slot_expr)
		}
		return fmt.tprintf("(cast(^%s)hot.slot_ref_struct_bytes(%s))^", tname, slot_expr)
	}
	return "f32(0)"
}

@(private = "file")
_emit_autocast_expr :: proc(g: ^engine.Visual_Graph, src_expr: string, src_p, dst_p: engine.VG_Pin_Def) -> string {
	sp := src_p.pin_type
	dp := dst_p.pin_type
	if sp == dp do return src_expr

	// Zero-cost `^T` / addressable -> `rawptr` or guarded `rawptr` -> value cast
	if dp == .Raw_Ptr {
		if sp == .Entity do return fmt.tprintf("rawptr(uintptr((%s).index))", src_expr)
		if sp == .U64 || sp == .Int64 do return fmt.tprintf("rawptr(uintptr(%s))", src_expr)
		return fmt.tprintf("rawptr(%s)", src_expr)
	}
	if sp == .Raw_Ptr {
		dt_t := _pin_odin_type_in_graph(g, dst_p, context.temp_allocator)
		return fmt.tprintf(
			"(proc(p: rawptr, api: ^hot.Engine_Hot_API) -> %s {{ if pok, preason := hot.validate_raw_ptr(p, align_of(%s)); !pok {{ if api != nil && api.report_sandbox_fault != nil {{ api.report_sandbox_fault(preason, #file, #procedure, #line) }}; _z: %s; return _z }}; return (cast(^%s)p)^ }})(%s, api)",
			dt_t, dt_t, dt_t, dt_t, src_expr,
		)
	}

	// Scalar splat -> vector
	if (sp == .Float || sp == .F64) && (dp == .Vec2 || dp == .Vec3 || dp == .Vec4) {
		ncomp := dp == .Vec2 ? 2 : (dp == .Vec3 ? 3 : 4)
		if ncomp == 2 do return fmt.tprintf("(proc(s: f32) -> [2]f32 {{ return {{s, s}} }})(f32(%s))", src_expr)
		if ncomp == 3 do return fmt.tprintf("(proc(s: f32) -> [3]f32 {{ return {{s, s, s}} }})(f32(%s))", src_expr)
		return fmt.tprintf("(proc(s: f32) -> [4]f32 {{ return {{s, s, s, s}} }})(f32(%s))", src_expr)
	}

	// Vector narrowing -> smaller vector / scalar
	if (sp == .Vec4 || sp == .Vec3 || sp == .Vec2) {
		st_t := engine.vg_pin_odin_type(sp, false)
		dt_t := _pin_odin_type_in_graph(g, dst_p, context.temp_allocator)
		if dp == .Vec3   do return fmt.tprintf("(proc(v: %s) -> %s {{ return {{v.x, v.y, v.z}} }})(%s)", st_t, dt_t, src_expr)
		if dp == .Vec2   do return fmt.tprintf("(proc(v: %s) -> %s {{ return {{v.x, v.y}} }})(%s)", st_t, dt_t, src_expr)
		if dp == .Float  do return fmt.tprintf("(proc(v: %s) -> f32 {{ return v.x }})(%s)", st_t, src_expr)
		if dp == .F64    do return fmt.tprintf("f64((proc(v: %s) -> f32 {{ return v.x }})(%s))", st_t, src_expr)
	}

	// Bool <-> Numeric / Enum
	dt_t := _pin_odin_type_in_graph(g, dst_p, context.temp_allocator)
	if sp == .Bool {
		return fmt.tprintf("((%s) ? %s(1) : %s(0))", src_expr, dt_t, dt_t)
	}
	if dp == .Bool {
		if sp == .Enum_U8 {
			return fmt.tprintf("(u8(%s) != 0)", src_expr)
		}
		return fmt.tprintf("((%s) != 0)", src_expr)
	}
	if sp == .Enum_U8 {
		return fmt.tprintf("%s(u8(%s))", dt_t, src_expr)
	}
	if dp == .Enum_U8 {
		return fmt.tprintf("%s(u8(%s))", dt_t, src_expr)
	}
	return fmt.tprintf("%s(%s)", dt_t, src_expr)
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
_resolve_array_access :: proc(g: ^engine.Visual_Graph, var_name: string) -> (v_decl: engine.VG_Var_Decl, slice_expr: string, elem_default: string, ck: engine.VG_Container_Kind, ok: bool) {
	vi := engine.vg_find_var_index(g, var_name)
	if vi < 0 do return {}, "", "f32(0)", .Single, false
	v := g.variables[vi]
	v_id := sanitize_odin_ident(v.name, context.temp_allocator)
	ed := _emit_pin_default_expr(_pin_def_from_var_decl(v), g)
	res_ck := engine.vg_resolve_container_kind(v)
	if res_ck == .Bounded_Array {
		return v, fmt.tprintf("_bp.%s.data[:clamp(int(_bp.%s.count), 0, len(_bp.%s.data))]", v_id, v_id, v_id), ed, res_ck, true
	}
	return v, fmt.tprintf("_bp.%s[:]", v_id), ed, res_ck, true
}

@(private = "file")
_transpile_pure_expr :: proc(g: ^engine.Visual_Graph, clean_graph: string, node_uid: int, out_pin: int, want_ref: bool, depth: int) -> string {
	if depth > 24 do return "f32(0)"
	n := engine.vg_find_node(g, node_uid)
	if n == nil || !n.enabled do return "f32(0)"

	// Handle split output sub-pins cleanly (e.g. `HitLoc.x` or `DamageInfo.amount`)
	if out_pin >= 0 && out_pin < len(n.outputs) {
		op := n.outputs[out_pin]
		if op.split_parent_name != "" {
			for po, poi in n.outputs {
				if po.name == op.split_parent_name && po.split_expanded {
					p_expr := _transpile_pure_expr(g, clean_graph, node_uid, poi, false, depth + 1)
					p_type := _pin_odin_type_in_graph(g, po, context.temp_allocator)
					c_type := _pin_odin_type_in_graph(g, op, context.temp_allocator)
					field  := sanitize_odin_ident(op.split_field_name, context.temp_allocator)
					return fmt.tprintf("(proc(v: %s) -> %s {{ return v.%s }})(%s)", p_type, c_type, field, p_expr)
				}
			}
		}
	}

	#partial switch n.kind {
	case .Reroute_Knot:
		if len(n.inputs) > 0 && n.inputs[0].pin_type != .Exec {
			return _transpile_input_expr_ex(g, clean_graph, n, 0, want_ref, depth + 1)
		}
		return "f32(0)"

	case .Auto_Cast:
		src_p := len(n.inputs) > 0 ? n.inputs[0] : engine.VG_Pin_Def{pin_type = .Float}
		dst_p := len(n.outputs) > 0 ? n.outputs[0] : engine.VG_Pin_Def{pin_type = .Int}
		want_addr := (dst_p.pin_type == .Raw_Ptr && src_p.is_addressable)
		src_e := _transpile_input_expr_ex(g, clean_graph, n, 0, want_addr, depth + 1)
		return _emit_autocast_expr(g, src_e, src_p, dst_p)

	case .Event_Tick:
		if out_pin == 1 do return "raw_dt"
		if out_pin == 2 do return "dt"
		return "dt"

	case .Event_On_Trigger:
		if out_pin == 1 do return "_trigger_other"
		return "self"

	case .Custom_Proc_Entry:
		if out_pin == 2 do return "_payload_f32"
		if out_pin == 3 do return "_payload_v2"
		if out_pin == 4 do return "_pressed"
		if out_pin >= 5 && out_pin < len(n.outputs) {
			return fmt.tprintf("_proc_param_%d", out_pin)
		}
		return "f32(0)"

	case .For_Loop:
		if out_pin == 1 do return fmt.tprintf("_loop_i_%d", n.uid)
		if out_pin == 3 && (n.for_mode == .For_In_Value || n.for_mode == .For_In_Ref) {
			if n.for_mode == .For_In_Ref && want_ref {
				return fmt.tprintf("&_loop_elem_%d", n.uid)
			}
			return fmt.tprintf("_loop_elem_%d", n.uid)
		}
		return "i32(0)"

	case .Get_Variable:
		if vi := engine.vg_find_var_index(g, n.var_name); vi >= 0 {
			v_field := fmt.tprintf("_bp.%s", sanitize_odin_ident(n.var_name))
			if want_ref do return fmt.tprintf("&%s", v_field)
			return v_field
		}
		return want_ref ? "&_dummy_f32" : "f32(0)"

	case .Get_Transform_Pos:
		if want_ref do return "_pos_ptr"
		return "(_pos_ptr != nil ? _pos_ptr^ : [3]f32{})"

	case .Make_Struct:
		st_name := n.target_var_or_type
		if st_name == "" && len(n.outputs) > 0 do st_name = n.outputs[0].custom_type_name
		fl, _, _ := engine.vg_struct_layout(g, st_name, context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "_bp_make_%s_%s(", clean_graph, sanitize_odin_ident(st_name, context.temp_allocator))
		for _, fi in fl {
			if fi > 0 do strings.write_string(&sb, ", ")
			arg := fi < len(n.inputs) ? _transpile_input_expr(g, clean_graph, n, fi, depth + 1) : "0"
			strings.write_string(&sb, arg)
		}
		strings.write_byte(&sb, ')')
		return strings.to_string(sb)

	case .Break_Struct:
		st_expr := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		if out_pin >= 0 && out_pin < len(n.outputs) {
			st_p := len(n.inputs) > 0 ? n.inputs[0] : engine.VG_Pin_Def{pin_type = .Struct_Val, custom_type_name = n.target_var_or_type}
			op := n.outputs[out_pin]
			st_t := _pin_odin_type_in_graph(g, st_p, context.temp_allocator)
			out_t := _pin_odin_type_in_graph(g, op, context.temp_allocator)
			fld := sanitize_odin_ident(op.name, context.temp_allocator)
			return fmt.tprintf("(proc(s: %s) -> %s {{ return s.%s }})(%s)", st_t, out_t, fld, st_expr)
		}
		return "f32(0)"

	case .BitSet_Op:
		mode := engine.VG_BitSet_Op_Mode(n.sub_op)
		if mode == .Has_Flag {
			set_e  := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
			flag_e := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
			return fmt.tprintf("((%s) in (%s))", flag_e, set_e)
		} else if mode == .Is_Empty {
			set_e := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
			return fmt.tprintf("((%s) == {{}})", set_e)
		}
		return fmt.tprintf("_out_%d_%d", n.uid, out_pin)

	case .Array_Op:
		mode := engine.VG_Array_Op_Mode(n.sub_op)
		v, arr_slice_e, ed, ck, ok := _resolve_array_access(g, n.target_var_or_type)
		if !ok {
			return (mode == .Len) ? "i32(0)" : "f32(0)"
		}
		v_id := sanitize_odin_ident(v.name, context.temp_allocator)
		elem_t := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
		#partial switch mode {
		case .Len:
			return ck == .Bounded_Array ? fmt.tprintf("_bp.%s.count", v_id) : fmt.tprintf("i32(len(_bp.%s))", v_id)
		case .Sub_Slice:
			lo_e := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
			hi_e := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
			return fmt.tprintf("(proc(s: []%s, a, b: i32) -> []%s {{ lo := clamp(int(a), 0, len(s)); hi := clamp(int(b), lo, len(s)); return s[lo:hi] }})(%s, %s, %s)", elem_t, elem_t, arr_slice_e, lo_e, hi_e)
		case .Get_Copy:
			idx_e := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
			if ck == .Bounded_Array {
				return fmt.tprintf("(_bp.%s.count > 0 ? _bp.%s.data[clamp(int(%s), 0, int(_bp.%s.count) - 1)] : %s)", v_id, v_id, idx_e, v_id, ed)
			}
			return fmt.tprintf("(len(_bp.%s) > 0 ? _bp.%s[clamp(int(%s), 0, len(_bp.%s) - 1)] : %s)", v_id, v_id, idx_e, v_id, ed)
		case .Get_Ref:
			idx_e := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
			if ck == .Bounded_Array {
				if want_ref do return fmt.tprintf("&_bp.%s.data[clamp(int(%s), 0, max(len(_bp.%s.data) - 1, 0))]", v_id, idx_e, v_id)
				return fmt.tprintf("(_bp.%s.count > 0 ? _bp.%s.data[clamp(int(%s), 0, int(_bp.%s.count) - 1)] : %s)", v_id, v_id, idx_e, v_id, ed)
			}
			if want_ref {
				if (ck == .Slice || ck == .Dynamic_Array) {
					if v.pin_type == .Float {
						return fmt.tprintf("(len(_bp.%s) > 0 ? &_bp.%s[clamp(int(%s), 0, len(_bp.%s) - 1)] : &_dummy_f32)", v_id, v_id, idx_e, v_id)
					}
					return fmt.tprintf("(len(_bp.%s) > 0 ? &_bp.%s[clamp(int(%s), 0, len(_bp.%s) - 1)] : new(%s, context.temp_allocator))", v_id, v_id, idx_e, v_id, elem_t)
				}
				return fmt.tprintf("&_bp.%s[clamp(int(%s), 0, max(len(_bp.%s) - 1, 0))]", v_id, idx_e, v_id)
			}
			return fmt.tprintf("(len(_bp.%s) > 0 ? _bp.%s[clamp(int(%s), 0, len(_bp.%s) - 1)] : %s)", v_id, v_id, idx_e, v_id, ed)
		case .Pop, .Append:
			return fmt.tprintf("_out_%d_%d", n.uid, out_pin)
		}
		return "f32(0)"

	case .Call_Hot_Proc:
		is_exec_node := len(n.inputs) > 0 && n.inputs[0].pin_type == .Exec
		if !is_exec_node {
			// Pure `@(bp_node)` function call! Invoke `_bp_pure_call_<clean>_<uid>_out<out_pin>`
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "_bp_pure_%s_%d_out%d(api, self, dt", clean_graph, n.uid, out_pin)
			for _, pi in n.inputs {
				if n.inputs[pi].pin_type == .Exec || n.inputs[pi].split_parent_name != "" do continue
				fmt.sbprintf(&sb, ", %s", _transpile_input_expr(g, clean_graph, n, pi, depth + 1))
			}
			strings.write_byte(&sb, ')')
			return strings.to_string(sb)
		}
		return fmt.tprintf("_out_%d_%d", n.uid, out_pin)

	case .Math_Float:
		a := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		b := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		switch n.math_op {
		case .Add:      return fmt.tprintf("(%s + %s)", a, b)
		case .Sub:      return fmt.tprintf("(%s - %s)", a, b)
		case .Mul:      return fmt.tprintf("(%s * %s)", a, b)
		case .Div:      return fmt.tprintf("(abs(%s) > 1e-6 ? (%s / %s) : f32(0))", b, a, b)
		case .Sin_Wave: return fmt.tprintf("(math.sin((%s) * math.TAU) * (%s))", a, b)
		case .Damp:     return fmt.tprintf("hot.damp_f32(%s, %s, 8.0, dt)", a, b)
		}

	case .Vec3_Scale_Add:
		base  := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		axis  := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		scale := _transpile_input_expr(g, clean_graph, n, 2, depth + 1)
		return fmt.tprintf("(%s + (%s) * (%s))", base, axis, scale)

	case .Anim_Clip_Eval:
		spd  := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		norm := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		if out_pin == 1 do return fmt.tprintf("math.mod((%s) + dt * (%s), 1.0)", norm, spd)
		return "f32(1.0)"

	case .Anim_Blend_Layered:
		b0 := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		b1 := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		al := _transpile_input_expr(g, clean_graph, n, 2, depth + 1)
		return fmt.tprintf("math.lerp(%s, %s, clamp(%s, f32(0), f32(1)))", b0, b1, al)

	case .Anim_Spring_Damper:
		cur := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		tgt := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		spd := _transpile_input_expr(g, clean_graph, n, 2, depth + 1)
		return fmt.tprintf("hot.damp_f32(%s, %s, max(%s, f32(0.01)), dt)", cur, tgt, spd)

	case .VFX_GPU_Curl_Force:
		vel  := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		curl := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		drag := _transpile_input_expr(g, clean_graph, n, 2, depth + 1)
		return fmt.tprintf("((%s + [3]f32{{math.sin((%s).y * 1.7), math.cos((%s).x * 1.3), math.sin((%s).z * 1.5)}} * ((%s) * dt)) * math.exp(-max(f32(%s), f32(0.0)) * max(dt, f32(0.0))))", vel, vel, vel, vel, curl, drag)

	case .VFX_Color_Size_Life:
		age := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		s0  := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		s1  := _transpile_input_expr(g, clean_graph, n, 2, depth + 1)
		return fmt.tprintf("math.lerp(%s, %s, clamp(%s, f32(0), f32(1)))", s0, s1, age)

	case .Audio_Random_Container:
		seed := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		cnt  := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		return fmt.tprintf("i32(clamp(int(math.mod(abs(f32(%s)), f32(1.0)) * f32(max(int(%s), 1))), 0, max(int(%s), 1) - 1))", seed, cnt, cnt)

	case .Audio_Modulate_Pitch_Vol:
		base := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		rng  := _transpile_input_expr(g, clean_graph, n, 1, depth + 1)
		seed := _transpile_input_expr(g, clean_graph, n, 2, depth + 1)
		return fmt.tprintf("(f32(%s) + (math.mod(abs(f32(%s)), f32(1.0)) * 2.0 - 1.0) * f32(%s))", base, seed, rng)

	case .AI_Check_Arrival:
		tol := _transpile_input_expr(g, clean_graph, n, 0, depth + 1)
		return fmt.tprintf("hot.ai_check_arrival(api, self, hot.get_pos(api, self), f32(%s))", tol)

	case .Set_Variable, .Set_Transform_Pos, .Branch_If, .Set_Time_Scale, .Odin_Function_Node,
	     .Or_Branch, .Delay_Timer, .Cooldown_Gate, .Spawn_Prefab,
	     .Physics_Raycast, .Physics_Overlap_Sphere, .CSG_Brush_Stamp:
		return fmt.tprintf("_out_%d_%d", n.uid, out_pin)
	}
	return "f32(0)"
}

@(private = "file")
_transpile_input_expr_ex :: proc(g: ^engine.Visual_Graph, clean_graph: string, dst_node: ^engine.VG_Node, in_pin: int, want_ref_override: bool, depth: int) -> string {
	if in_pin < 0 || in_pin >= len(dst_node.inputs) do return "f32(0)"
	pdef := dst_node.inputs[in_pin]
	want_ref := want_ref_override || (pdef.pass_mode == .By_Reference)

	// Reassemble expanded split child pins when no wire targets the collapsed parent
	if pdef.split_expanded && !want_ref {
		child_exprs := make([dynamic]string, 0, 8, context.temp_allocator)
		for cp, cpi in dst_node.inputs {
			if cp.split_parent_name == pdef.name {
				append(&child_exprs, _transpile_input_expr(g, clean_graph, dst_node, cpi, depth + 1))
			}
		}
		if pdef.pin_type == .Vec2 && len(child_exprs) >= 2 {
			return fmt.tprintf("[2]f32{{%s, %s}}", child_exprs[0], child_exprs[1])
		} else if pdef.pin_type == .Vec3 && len(child_exprs) >= 3 {
			return fmt.tprintf("[3]f32{{%s, %s, %s}}", child_exprs[0], child_exprs[1], child_exprs[2])
		} else if (pdef.pin_type == .Vec4 || pdef.pin_type == .Quat) && len(child_exprs) >= 4 {
			return fmt.tprintf("[4]f32{{%s, %s, %s, %s}}", child_exprs[0], child_exprs[1], child_exprs[2], child_exprs[3])
		} else if pdef.pin_type == .Struct_Val && pdef.custom_type_name != "" {
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "_bp_make_%s_%s(", clean_graph, sanitize_odin_ident(pdef.custom_type_name, context.temp_allocator))
			for ce, ci in child_exprs {
				if ci > 0 do strings.write_string(&sb, ", ")
				strings.write_string(&sb, ce)
			}
			strings.write_byte(&sb, ')')
			return strings.to_string(sb)
		}
	}

	for w in g.wires {
		if w.to_uid == dst_node.uid && w.to_pin == in_pin {
			return _transpile_pure_expr(g, clean_graph, w.from_uid, w.from_pin, want_ref, depth)
		}
	}

	if want_ref {
		return fmt.tprintf("&_scratch_%d_%d", dst_node.uid, in_pin)
	}
	return _emit_pin_default_expr(pdef, g)
}

@(private = "file")
_transpile_input_expr :: proc(g: ^engine.Visual_Graph, clean_graph: string, dst_node: ^engine.VG_Node, in_pin: int, depth: int) -> string {
	return _transpile_input_expr_ex(g, clean_graph, dst_node, in_pin, false, depth)
}

@(private = "file")
_emit_unwired_ref_scratches :: proc(b: ^strings.Builder, g: ^engine.Visual_Graph, n: ^engine.VG_Node, indent: string) {
	for pi in 0 ..< len(n.inputs) {
		p := n.inputs[pi]
		if p.pin_type == .Exec || p.pass_mode != .By_Reference do continue
		wired := false
		for w in g.wires do if w.to_uid == n.uid && w.to_pin == pi { wired = true; break }
		if !wired {
			fmt.sbprintf(b, "%s_scratch_%d_%d := %s\n", indent, n.uid, pi, _emit_pin_default_expr(p, g))
		}
	}
}

@(private = "file")
_emit_exec_chain :: proc(b: ^strings.Builder, g: ^engine.Visual_Graph, clean_graph: string, start_uid: int, indent: string, visited: ^map[int]bool, depth: int) {
	if start_uid == 0 || depth > 48 || visited^[start_uid] do return
	visited^[start_uid] = true
	defer delete_key(visited, start_uid)

	n := engine.vg_find_node(g, start_uid)
	if n == nil do return

	next_pin := 0
	if n.enabled {
		#partial switch n.kind {
		case .Reroute_Knot:
			next_pin = 0

		case .Set_Variable:
			val_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			if engine.vg_find_var_index(g, n.var_name) >= 0 {
				v_field := fmt.tprintf("_bp.%s", sanitize_odin_ident(n.var_name))
				fmt.sbprintf(b, "%s%s = %s\n", indent, v_field, val_exp)
				fmt.sbprintf(b, "%s_out_%d_1 := %s; _ = _out_%d_1\n", indent, n.uid, v_field, n.uid)
			}

		case .Set_Transform_Pos:
			val_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			fmt.sbprintf(b, "%shot.set_pos(api, self, %s)\n", indent, val_exp)

		case .Set_Time_Scale:
			sc_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
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
				pay_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
				fmt.sbprintf(b, "%s_save_%s_state(api, self, frame, &_bp)\n", indent, clean_graph)
				fmt.sbprintf(b, "%shot.broadcast_delegate(api, self, %q, %s)\n", indent, n.delegate_name, pay_exp)
				fmt.sbprintf(b, "%s_bp = _load_%s_state(api, self, frame)\n", indent, clean_graph)
			}

		case .Call_Blueprint_Proc:
			if pn := engine.vg_find_custom_proc_node(g, n.hot_proc_target); pn != nil {
				pay_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
				p_clean := sanitize_odin_ident(pn.hot_proc_target != "" ? pn.hot_proc_target : pn.title, context.temp_allocator)
				fmt.sbprintf(b, "%s{{\n", indent)
				fmt.sbprintf(b, "%s\t_save_%s_state(api, self, frame, &_bp)\n", indent, clean_graph)
				fmt.sbprintf(b, "%s\t_call_f: hot.Hot_Call_Frame\n", indent)
				fmt.sbprintf(b, "%s\t_call_f.inputs[0] = {{pin_type = .Float, val_f32 = %s}}\n", indent, pay_exp)
				fmt.sbprintf(b, "%s\t_call_f.inputs[1] = {{pin_type = .Vec2}}\n", indent)
				fmt.sbprintf(b, "%s\t_call_f.inputs[2] = {{pin_type = .Bool, val_bool = true}}\n", indent)
				call_in_cnt := len(n.inputs) > 2 \
					? _emit_hot_call_frame_inputs(b, g, clean_graph, n, fmt.tprintf("%s\t", indent), "_call_f", 2, 3, false) \
					: 1
				fmt.sbprintf(b, "%s\t_call_f.input_count = %d\n", indent, call_in_cnt)
				fmt.sbprintf(b, "%s\tmhgraph_%s__proc_%s(api, self, dt, &_call_f)\n", indent, clean_graph, p_clean)
				fmt.sbprintf(b, "%s\t_bp = _load_%s_state(api, self, frame)\n", indent, clean_graph)
				fmt.sbprintf(b, "%s}}\n", indent)
			}

		case .Anim_IK_Target:
			eff_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			wt_exp  := _transpile_input_expr(g, clean_graph, n, 2, 0)
			fmt.sbprintf(b, "%shot.anim_set_ik_target(api, self, cstring(%q), %s, %s)\n", indent, n.action_name, eff_exp, wt_exp)

		case .VFX_Emitter_Spawn:
			rate_exp  := _transpile_input_expr(g, clean_graph, n, 1, 0)
			burst_exp := _transpile_input_expr(g, clean_graph, n, 2, 0)
			fmt.sbprintf(b, "%shot.vfx_emitter_spawn(api, self, cstring(%q), %s, i32(%s))\n", indent, n.action_name, rate_exp, burst_exp)

		case .Audio_Bus_Send:
			vol_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			cut_exp := _transpile_input_expr(g, clean_graph, n, 2, 0)
			fmt.sbprintf(b, "%shot.audio_set_bus_send(api, cstring(%q), %s, %s)\n", indent, n.action_name != "" ? n.action_name : "SFX", vol_exp, cut_exp)

		case .Audio_Play_Spatial_3D:
			pos_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			vol_exp := _transpile_input_expr(g, clean_graph, n, 2, 0)
			pit_exp := _transpile_input_expr(g, clean_graph, n, 3, 0)
			fmt.sbprintf(b, "%shot.audio_play_spatial_3d(api, self, cstring(%q), %s, %s, %s)\n", indent, n.action_name, pos_exp, vol_exp, pit_exp)

		case .AI_Find_Path_Move:
			pos_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			spd_exp := _transpile_input_expr(g, clean_graph, n, 2, 0)
			fmt.sbprintf(b, "%s{{ _ai_s := %s; _ = _ai_s; _ = hot.ai_find_path_move(api, self, %s) }}\n", indent, spd_exp, pos_exp)

		case .Branch_If:
			cond_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
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

		case .Sequence:
			for oi in 0 ..< len(n.outputs) {
				then_uid := 0
				for w in g.wires {
					if w.from_uid == n.uid && w.from_pin == oi {
						then_uid = w.to_uid
						break
					}
				}
				if then_uid > 0 {
					fmt.sbprintf(b, "%s// Sequence Then %d\n", indent, oi)
					fmt.sbprintf(b, "%s{{\n", indent)
					sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
					_emit_exec_chain(b, g, clean_graph, then_uid, sub_indent, visited, depth + 1)
					fmt.sbprintf(b, "%s}}\n", indent)
				}
			}
			return

		case .Defer_Exec:
			then_uid  := 0
			defer_uid := 0
			for w in g.wires {
				if w.from_uid == n.uid && w.from_pin == 0 do then_uid = w.to_uid
				if w.from_uid == n.uid && w.from_pin == 1 do defer_uid = w.to_uid
			}
			if defer_uid > 0 {
				fmt.sbprintf(b, "%sdefer {{\n", indent)
				sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
				_emit_exec_chain(b, g, clean_graph, defer_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)
			}
			_emit_exec_chain(b, g, clean_graph, then_uid, indent, visited, depth + 1)
			return

		case .Or_Branch:
			val_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
			ok_e  := _transpile_input_expr(g, clean_graph, n, 2, 0)
			valid_uid  := 0
			failed_uid := 0
			for w in g.wires {
				if w.from_uid == n.uid && w.from_pin == 0 do valid_uid = w.to_uid
				if w.from_uid == n.uid && w.from_pin == 1 do failed_uid = w.to_uid
			}
			fmt.sbprintf(b, "%s_out_%d_2 := %s; _ = _out_%d_2\n", indent, n.uid, val_e, n.uid)
			fmt.sbprintf(b, "%sif %s {{\n", indent, ok_e)
			sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
			_emit_exec_chain(b, g, clean_graph, valid_uid, sub_indent, visited, depth + 1)
			fmt.sbprintf(b, "%s}} else {{\n", indent)
			_emit_exec_chain(b, g, clean_graph, failed_uid, sub_indent, visited, depth + 1)
			fmt.sbprintf(b, "%s}}\n", indent)
			return

		case .For_Loop:
			body_uid := 0
			done_uid := 0
			for w in g.wires {
				if w.from_uid == n.uid && w.from_pin == 0 do body_uid = w.to_uid
				if w.from_uid == n.uid && w.from_pin == 2 do done_uid = w.to_uid
			}
			sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
			fmt.sbprintf(b, "%s_guard_%d := 0\n", indent, n.uid)
			switch n.for_mode {
			case .Range_Inclusive:
				first_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
				last_exp  := _transpile_input_expr(g, clean_graph, n, 2, 0)
				if !n.loop_reverse {
					fmt.sbprintf(b, "%sfor _loop_i_%d := i32(%s); _loop_i_%d <= i32(%s); _loop_i_%d += 1 {{\n", indent, n.uid, first_exp, n.uid, last_exp, n.uid)
				} else {
					fmt.sbprintf(b, "%sfor _loop_i_%d := i32(%s); _loop_i_%d >= i32(%s); _loop_i_%d -= 1 {{\n", indent, n.uid, last_exp, n.uid, first_exp, n.uid)
				}
				fmt.sbprintf(b, "%s\tif _guard_%d >= %d {{ hot.report_loop_fuse(api, self, %d); break }}\n", indent, n.uid, engine.VG_MAX_LOOP_ITERATIONS, n.uid)
				fmt.sbprintf(b, "%s\t_guard_%d += 1; _ = _loop_i_%d\n", indent, n.uid, n.uid)
				_emit_exec_chain(b, g, clean_graph, body_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)

			case .Range_Half_Open:
				first_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
				end_exp   := _transpile_input_expr(g, clean_graph, n, 2, 0)
				if !n.loop_reverse {
					fmt.sbprintf(b, "%sfor _loop_i_%d := i32(%s); _loop_i_%d < i32(%s); _loop_i_%d += 1 {{\n", indent, n.uid, first_exp, n.uid, end_exp, n.uid)
				} else {
					fmt.sbprintf(b, "%sfor _loop_i_%d := i32(%s) - 1; _loop_i_%d >= i32(%s); _loop_i_%d -= 1 {{\n", indent, n.uid, end_exp, n.uid, first_exp, n.uid)
				}
				fmt.sbprintf(b, "%s\tif _guard_%d >= %d {{ hot.report_loop_fuse(api, self, %d); break }}\n", indent, n.uid, engine.VG_MAX_LOOP_ITERATIONS, n.uid)
				fmt.sbprintf(b, "%s\t_guard_%d += 1; _ = _loop_i_%d\n", indent, n.uid, n.uid)
				_emit_exec_chain(b, g, clean_graph, body_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)

			case .For_In_Value, .For_In_Ref:
				_, slice_e, _, _, has_arr := _resolve_array_access(g, n.target_var_or_type)
				if has_arr {
					rev_kw := n.loop_reverse ? "#reverse " : ""
					ref_sigil := (n.for_mode == .For_In_Ref) ? "&" : ""
					fmt.sbprintf(b, "%s%sfor %s_loop_elem_%d, _loop_idx_%d in %s {{\n", indent, rev_kw, ref_sigil, n.uid, n.uid, slice_e)
					fmt.sbprintf(b, "%s\tif _guard_%d >= %d {{ hot.report_loop_fuse(api, self, %d); break }}\n", indent, n.uid, engine.VG_MAX_LOOP_ITERATIONS, n.uid)
					fmt.sbprintf(b, "%s\t_guard_%d += 1\n", indent, n.uid)
					fmt.sbprintf(b, "%s\t_loop_i_%d := i32(_loop_idx_%d); _ = _loop_i_%d; _ = _loop_elem_%d\n", indent, n.uid, n.uid, n.uid, n.uid)
					_emit_exec_chain(b, g, clean_graph, body_uid, sub_indent, visited, depth + 1)
					fmt.sbprintf(b, "%s}}\n", indent)
				} else {
					fmt.sbprintf(b, "%s_ = _guard_%d\n", indent, n.uid)
				}

			case .Condition:
				fmt.sbprintf(b, "%s_loop_i_%d := i32(0)\n", indent, n.uid)
				cond_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
				fmt.sbprintf(b, "%sfor %s {{\n", indent, cond_exp)
				fmt.sbprintf(b, "%s\tif _guard_%d >= %d {{ hot.report_loop_fuse(api, self, %d); break }}\n", indent, n.uid, engine.VG_MAX_LOOP_ITERATIONS, n.uid)
				fmt.sbprintf(b, "%s\t_guard_%d += 1; _ = _loop_i_%d\n", indent, n.uid, n.uid)
				_emit_exec_chain(b, g, clean_graph, body_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s\t_loop_i_%d += 1\n", indent, n.uid)
				fmt.sbprintf(b, "%s}}\n", indent)
			}
			_emit_exec_chain(b, g, clean_graph, done_uid, indent, visited, depth + 1)
			return

		case .Break_Loop:
			fmt.sbprintf(b, "%sbreak\n", indent)
			return

		case .Continue_Loop:
			fmt.sbprintf(b, "%scontinue\n", indent)
			return

		case .Switch_Value:
			sel_exp := _transpile_input_expr(g, clean_graph, n, 1, 0)
			sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
			ed := engine.vg_find_enum_decl(g, n.target_var_or_type)
			if ed != nil && len(ed.variants) > 0 {
				fmt.sbprintf(b, "%sswitch %s {{\n", indent, sel_exp)
				for v, vi in ed.variants {
					fmt.sbprintf(b, "%scase .%s:\n", indent, sanitize_odin_ident(v, context.temp_allocator))
					case_uid := 0
					for w in g.wires do if w.from_uid == n.uid && w.from_pin == vi { case_uid = w.to_uid; break }
					_emit_exec_chain(b, g, clean_graph, case_uid, sub_indent, visited, depth + 1)
				}
				fmt.sbprintf(b, "%scase:\n", indent)
				def_uid := 0
				def_pin := len(ed.variants)
				for w in g.wires do if w.from_uid == n.uid && w.from_pin == def_pin { def_uid = w.to_uid; break }
				_emit_exec_chain(b, g, clean_graph, def_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)
			} else {
				cnt := max(len(n.outputs) - 1, 1)
				fmt.sbprintf(b, "%sswitch i32(%s) {{\n", indent, sel_exp)
				for ci in 0 ..< cnt {
					fmt.sbprintf(b, "%scase %d:\n", indent, ci)
					case_uid := 0
					for w in g.wires do if w.from_uid == n.uid && w.from_pin == ci { case_uid = w.to_uid; break }
					_emit_exec_chain(b, g, clean_graph, case_uid, sub_indent, visited, depth + 1)
				}
				fmt.sbprintf(b, "%scase:\n", indent)
				def_uid := 0
				for w in g.wires do if w.from_uid == n.uid && w.from_pin == cnt { def_uid = w.to_uid; break }
				_emit_exec_chain(b, g, clean_graph, def_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)
			}
			return

		case .BitSet_Op:
			mode := engine.VG_BitSet_Op_Mode(n.sub_op)
			set_e  := _transpile_input_expr(g, clean_graph, n, 1, 0)
			flag_e := _transpile_input_expr(g, clean_graph, n, 2, 0)
			op_sym := "+"
			if mode == .Clear_Flag do op_sym = "-"
			else if mode == .Toggle_Flag do op_sym = "~"
			fmt.sbprintf(b, "%s_out_%d_1 := (%s %s {{%s}}); _ = _out_%d_1\n", indent, n.uid, set_e, op_sym, flag_e, n.uid)

		case .Array_Op:
			mode := engine.VG_Array_Op_Mode(n.sub_op)
			v, _, ed, ck, ok := _resolve_array_access(g, n.target_var_or_type)
			if ok {
				v_id := sanitize_odin_ident(v.name, context.temp_allocator)
				switch mode {
				case .Set_Elem:
					idx_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
					val_e := _transpile_input_expr(g, clean_graph, n, 2, 0)
					if ck == .Bounded_Array {
						fmt.sbprintf(b, "%sif _bp.%s.count > 0 {{ _bp.%s.data[clamp(int(%s), 0, int(_bp.%s.count) - 1)] = %s }}\n", indent, v_id, v_id, idx_e, v_id, val_e)
					} else {
						fmt.sbprintf(b, "%sif len(_bp.%s) > 0 {{ _bp.%s[clamp(int(%s), 0, len(_bp.%s) - 1)] = %s }}\n", indent, v_id, v_id, idx_e, v_id, val_e)
					}
				case .Append:
					val_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
					fmt.sbprintf(b, "%s_out_%d_1 := false\n", indent, n.uid)
					if ck == .Bounded_Array {
						fmt.sbprintf(b, "%sif int(_bp.%s.count) < len(_bp.%s.data) {{ _bp.%s.data[_bp.%s.count] = %s; _bp.%s.count += 1; _out_%d_1 = true }}\n", indent, v_id, v_id, v_id, v_id, val_e, v_id, n.uid)
					} else if ck == .Dynamic_Array {
						fmt.sbprintf(b, "%sappend(&_bp.%s, %s); _out_%d_1 = true\n", indent, v_id, val_e, n.uid)
					} else {
						fmt.sbprintf(b, "%s_ = %s\n", indent, val_e)
					}
					fmt.sbprintf(b, "%s_ = _out_%d_1\n", indent, n.uid)
				case .Pop:
					fmt.sbprintf(b, "%s_out_%d_1 := %s\n", indent, n.uid, ed)
					fmt.sbprintf(b, "%s_out_%d_2 := false\n", indent, n.uid)
					if ck == .Bounded_Array {
						fmt.sbprintf(b, "%sif _bp.%s.count > 0 {{ _bp.%s.count -= 1; _out_%d_1 = _bp.%s.data[_bp.%s.count]; _out_%d_2 = true }}\n", indent, v_id, v_id, n.uid, v_id, v_id, n.uid)
					} else if ck == .Dynamic_Array {
						fmt.sbprintf(b, "%sif len(_bp.%s) > 0 {{ _out_%d_1 = pop(&_bp.%s); _out_%d_2 = true }}\n", indent, v_id, n.uid, v_id, n.uid)
					}
					fmt.sbprintf(b, "%s_ = _out_%d_1; _ = _out_%d_2\n", indent, n.uid, n.uid)
				case .Clear:
					if ck == .Bounded_Array {
						fmt.sbprintf(b, "%s_bp.%s.count = 0\n", indent, v_id)
					} else if ck == .Dynamic_Array {
						fmt.sbprintf(b, "%sclear(&_bp.%s)\n", indent, v_id)
					} else if ck == .Slice {
						fmt.sbprintf(b, "%s_bp.%s = nil\n", indent, v_id)
					} else {
						fmt.sbprintf(b, "%s_bp.%s = {{}}\n", indent, v_id)
					}
				case .Swap_Remove:
					idx_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
					if ck == .Bounded_Array {
						fmt.sbprintf(b, "%s{{ _sr_i := int(%s); if _sr_i >= 0 && _sr_i < int(_bp.%s.count) {{ _bp.%s.data[_sr_i] = _bp.%s.data[_bp.%s.count - 1]; _bp.%s.count -= 1 }} }}\n", indent, idx_e, v_id, v_id, v_id, v_id, v_id)
					} else if ck == .Dynamic_Array {
						fmt.sbprintf(b, "%s{{ _sr_i := int(%s); if _sr_i >= 0 && _sr_i < len(_bp.%s) {{ unordered_remove(&_bp.%s, _sr_i) }} }}\n", indent, idx_e, v_id, v_id)
					} else {
						fmt.sbprintf(b, "%s_ = %s\n", indent, idx_e)
					}
				case .Get_Copy, .Get_Ref, .Len, .Sub_Slice:
					// pure modes
				}
			}

		case .Delay_Timer, .Cooldown_Gate:
			dur_e   := _transpile_input_expr(g, clean_graph, n, 1, 0)
			reset_e := _transpile_input_expr(g, clean_graph, n, 2, 0)
			is_cd   := (n.kind == .Cooldown_Gate)
			fmt.sbprintf(b, "%s_out_%d_2 := f32(0)\n", indent, n.uid)
			fmt.sbprintf(b, "%s_trig_%d := hot.timer_step(api, self, u32(%d), f32(%s), dt, %s, %v, &_out_%d_2)\n", indent, n.uid, n.uid, dur_e, reset_e, is_cd, n.uid)
			fmt.sbprintf(b, "%s_ = _out_%d_2\n", indent, n.uid)
			if n.kind == .Delay_Timer {
				active_uid := 0
				done_uid   := 0
				for w in g.wires {
					if w.from_uid == n.uid && w.from_pin == 0 do active_uid = w.to_uid
					if w.from_uid == n.uid && w.from_pin == 1 do done_uid = w.to_uid
				}
				sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
				fmt.sbprintf(b, "%sif _trig_%d {{\n", indent, n.uid)
				_emit_exec_chain(b, g, clean_graph, done_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}} else {{\n", indent)
				_emit_exec_chain(b, g, clean_graph, active_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)
			} else {
				ready_uid   := 0
				blocked_uid := 0
				for w in g.wires {
					if w.from_uid == n.uid && w.from_pin == 0 do ready_uid = w.to_uid
					if w.from_uid == n.uid && w.from_pin == 1 do blocked_uid = w.to_uid
				}
				sub_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
				fmt.sbprintf(b, "%sif _trig_%d {{\n", indent, n.uid)
				_emit_exec_chain(b, g, clean_graph, ready_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}} else {{\n", indent)
				_emit_exec_chain(b, g, clean_graph, blocked_uid, sub_indent, visited, depth + 1)
				fmt.sbprintf(b, "%s}}\n", indent)
			}
			return

		case .Spawn_Prefab:
			pref_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
			pos_e  := _transpile_input_expr(g, clean_graph, n, 2, 0)
			rot_e  := _transpile_input_expr(g, clean_graph, n, 3, 0)
			fmt.sbprintf(b, "%s_out_%d_1 := hot.spawn_prefab(api, %s, %s, %s)\n", indent, n.uid, pref_e, pos_e, rot_e)
			fmt.sbprintf(b, "%s_out_%d_2 := (_out_%d_1.index != 0 || _out_%d_1.generation != 0)\n", indent, n.uid, n.uid, n.uid)
			fmt.sbprintf(b, "%s_ = _out_%d_1; _ = _out_%d_2\n", indent, n.uid, n.uid)

		case .Destroy_Entity:
			tgt_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
			fmt.sbprintf(b, "%shot.destroy_entity(api, %s)\n", indent, tgt_e)

		case .Physics_Raycast:
			orig_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
			dir_e  := _transpile_input_expr(g, clean_graph, n, 2, 0)
			dist_e := _transpile_input_expr(g, clean_graph, n, 3, 0)
			mask_e := _transpile_input_expr(g, clean_graph, n, 4, 0)
			fmt.sbprintf(b, "%s_rh_%d: hot.Hot_Raycast_Hit\n", indent, n.uid)
			fmt.sbprintf(b, "%s_out_%d_1 := hot.physics_raycast(api, self, %s, %s, f32(%s), u32(%s), &_rh_%d)\n", indent, n.uid, orig_e, dir_e, dist_e, mask_e, n.uid)
			fmt.sbprintf(b, "%s_out_%d_2 := _rh_%d.position\n", indent, n.uid, n.uid)
			fmt.sbprintf(b, "%s_out_%d_3 := _rh_%d.normal\n", indent, n.uid, n.uid)
			fmt.sbprintf(b, "%s_out_%d_4 := _rh_%d.distance\n", indent, n.uid, n.uid)
			fmt.sbprintf(b, "%s_out_%d_5 := _rh_%d.entity\n", indent, n.uid, n.uid)
			fmt.sbprintf(b, "%s_ = _out_%d_1; _ = _out_%d_2; _ = _out_%d_3; _ = _out_%d_4; _ = _out_%d_5\n", indent, n.uid, n.uid, n.uid, n.uid, n.uid)

		case .Physics_Overlap_Sphere:
			ctr_e  := _transpile_input_expr(g, clean_graph, n, 1, 0)
			rad_e  := _transpile_input_expr(g, clean_graph, n, 2, 0)
			mask_e := _transpile_input_expr(g, clean_graph, n, 3, 0)
			fmt.sbprintf(b, "%s_out_%d_2: hot.Hot_Entity\n", indent, n.uid)
			fmt.sbprintf(b, "%s_out_%d_1 := hot.physics_overlap_sphere(api, self, %s, f32(%s), u32(%s), &_out_%d_2)\n", indent, n.uid, ctr_e, rad_e, mask_e, n.uid)
			fmt.sbprintf(b, "%s_ = _out_%d_1; _ = _out_%d_2\n", indent, n.uid, n.uid)

		case .Physics_Add_Impulse:
			tgt_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
			imp_e := _transpile_input_expr(g, clean_graph, n, 2, 0)
			vc_e  := _transpile_input_expr(g, clean_graph, n, 3, 0)
			fmt.sbprintf(b, "%shot.physics_add_impulse(api, %s, %s, %s)\n", indent, tgt_e, imp_e, vc_e)

		case .CSG_Brush_Stamp:
			pos_e := _transpile_input_expr(g, clean_graph, n, 1, 0)
			rad_e := _transpile_input_expr(g, clean_graph, n, 2, 0)
			imp_e := _transpile_input_expr(g, clean_graph, n, 3, 0)
			fmt.sbprintf(b, "%s_out_%d_1 := hot.csg_stamp_brush(api, %s, f32(%s), f32(%s), cstring(\"\"))\n", indent, n.uid, pos_e, rad_e, imp_e)
			fmt.sbprintf(b, "%s_ = _out_%d_1\n", indent, n.uid)

		case .Call_Hot_Proc:
			_emit_unwired_ref_scratches(b, g, n, indent)
			fmt.sbprintf(b, "%s_sub_f_%d: hot.Hot_Call_Frame\n", indent, n.uid)
			arg_idx := _emit_hot_call_frame_inputs(b, g, clean_graph, n, indent, fmt.tprintf("_sub_f_%d", n.uid), 0, 0, false)
			fmt.sbprintf(b, "%s_sub_f_%d.input_count = %d\n", indent, n.uid, arg_idx)
			target_fn := n.hot_proc_target != "" ? sanitize_odin_ident(n.hot_proc_target) : "hot_harmonic_hover"
			fmt.sbprintf(b, "%s%s(api, self, dt, &_sub_f_%d)\n", indent, target_fn, n.uid)
			out_slot := 0
			for po, oi in n.outputs {
				if po.pin_type == .Exec || po.split_parent_name != "" do continue
				read_e := _slot_read_call_for_pin(po, fmt.tprintf("&_sub_f_%d.outputs[%d]", n.uid, out_slot), false, g)
				fmt.sbprintf(b, "%s_out_%d_%d := %s; _ = _out_%d_%d\n", indent, n.uid, oi, read_e, n.uid, oi)
				out_slot += 1
			}

		case .Odin_Function_Node:
			_emit_unwired_ref_scratches(b, g, n, indent)

			out_names := make([dynamic]string, context.temp_allocator)
			for po, oi in n.outputs {
				if po.pin_type == .Exec || po.split_parent_name != "" do continue
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
				if n.inputs[pi].pin_type == .Exec || n.inputs[pi].split_parent_name != "" do continue
				fmt.sbprintf(b, ", %s", _transpile_input_expr(g, clean_graph, n, pi, 0))
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
_emit_proc_entry_boilerplate :: proc(b: ^strings.Builder, clean_name: string, proc_sym: string, is_custom_proc: bool, is_trigger: bool = false) {
	fmt.sbprintf(b, "@(hot_proc)\n%s :: proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, raw_dt: f32, frame: ^hot.Hot_Call_Frame) {{\n", proc_sym)
	strings.write_string(b, "\tcontext = hot.make_script_context(api)\n")
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
	if is_trigger {
		strings.write_string(b, "\t_trigger_other := frame != nil && frame.input_count > 0 ? hot.slot_read_entity(&frame.inputs[0]) : hot.Hot_Entity{}\n")
		strings.write_string(b, "\t_ = _trigger_other\n")
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

@(private = "file")
_struct_needs_constructor :: proc(g: ^engine.Visual_Graph, struct_name: string) -> bool {
	if g == nil || struct_name == "" do return false
	for &n in g.nodes {
		if !n.enabled do continue
		if n.kind == .Make_Struct && n.target_var_or_type == struct_name do return true
		for ip in n.inputs {
			if ip.split_expanded && ip.pin_type == .Struct_Val && ip.custom_type_name == struct_name {
				return true
			}
		}
	}
	return false
}

@(private = "file")
_emit_user_types_and_helpers :: proc(b: ^strings.Builder, g: ^engine.Visual_Graph, clean_name: string) {
	// User Enum u8 + optional bit_set[Enum; u8] (skip declarations already authored in Zone 1!)
	for ed in g.enums {
		if ed.name == "" || ed.code_authored do continue
		ename := sanitize_odin_ident(ed.name, context.temp_allocator)
		fmt.sbprintf(b, "%s :: enum u8 {{\n", ename)
		if len(ed.variants) == 0 {
			strings.write_string(b, "\t_None = 0,\n")
		} else {
			for v, vi in ed.variants {
				fmt.sbprintf(b, "\t%s = %d,\n", sanitize_odin_ident(v, context.temp_allocator), vi)
			}
		}
		strings.write_string(b, "}\n")

		need_bs := ed.has_bitset
		if !need_bs {
			for v in g.variables {
				if v.pin_type == .BitSet_U8 && v.custom_type_name == ed.name { need_bs = true; break }
			}
		}
		if need_bs {
			bs_name := ed.bitset_name != "" ? sanitize_odin_ident(ed.bitset_name, context.temp_allocator) : fmt.tprintf("%s_Set", ename)
			fmt.sbprintf(b, "%s :: bit_set[%s; u8]\n", bs_name, ename)
		}
		strings.write_byte(b, '\n')
	}

	// User POD Structs (supporting `using _base`; skip declarations already authored in Zone 1!)
	for sd in g.structs {
		if sd.name == "" do continue
		sname := sanitize_odin_ident(sd.name, context.temp_allocator)
		if !sd.code_authored {
			fmt.sbprintf(b, "%s :: struct {{\n", sname)
			has_member := false
			if sd.using_parent_name != "" && sd.using_parent_name != sd.name {
				fmt.sbprintf(b, "\tusing _base: %s,\n", sanitize_odin_ident(sd.using_parent_name, context.temp_allocator))
				has_member = true
			}
			for f in sd.fields {
				ft_pin := engine.VG_Pin_Def{pin_type = f.pin_type, custom_type_name = f.custom_type}
				fmt.sbprintf(b, "\t%s: %s,\n", sanitize_odin_ident(f.name, context.temp_allocator), _pin_odin_type_in_graph(g, ft_pin, context.temp_allocator))
				has_member = true
			}
			if !has_member {
				strings.write_string(b, "\t_reserved: u8,\n")
			}
			strings.write_string(b, "}\n")
		}

		if _struct_needs_constructor(g, sd.name) {
			fl, _, _ := engine.vg_struct_layout(g, sd.name, context.temp_allocator)
			fmt.sbprintf(b, "_bp_make_%s_%s :: #force_inline proc(", clean_name, sname)
			for f, fi in fl {
				if fi > 0 do strings.write_string(b, ", ")
				ft_pin := engine.VG_Pin_Def{pin_type = f.pin_type, custom_type_name = f.custom_type}
				fmt.sbprintf(b, "f_%s: %s", sanitize_odin_ident(f.name, context.temp_allocator), _pin_odin_type_in_graph(g, ft_pin, context.temp_allocator))
			}
			fmt.sbprintf(b, ") -> (res: %s) {{\n", sname)
			for f in fl {
				fn := sanitize_odin_ident(f.name, context.temp_allocator)
				fmt.sbprintf(b, "\tres.%s = f_%s\n", fn, fn)
			}
			strings.write_string(b, "\treturn res\n}\n")
		}
		if !sd.code_authored || _struct_needs_constructor(g, sd.name) {
			strings.write_byte(b, '\n')
		}
	}

	// Zero-heap C-ABI `BP_Bounded_<T>_<Cap>` structs
	emitted_bounded := make(map[string]bool, 8, context.temp_allocator)
	for v in g.variables {
		if engine.vg_resolve_container_kind(v) != .Bounded_Array do continue
		btype := engine.vg_var_odin_type_ex(g, v, context.temp_allocator)
		if btype in emitted_bounded do continue
		emitted_bounded[btype] = true
		elem_p := engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}
		elem_t := _pin_odin_type_in_graph(g, elem_p, context.temp_allocator)
		cap_n := v.array_count > 0 ? v.array_count : 8
		fmt.sbprintf(b, "%s :: struct {{\n\tdata:  [%d]%s,\n\tcount: i32,\n}}\n\n", btype, cap_n, elem_t)
	}

	// Pure `@(bp_node)` / `Call_Hot_Proc` wrappers (no Exec pins)
	for &n in g.nodes {
		if n.kind != .Call_Hot_Proc || !n.enabled do continue
		if len(n.inputs) > 0 && n.inputs[0].pin_type == .Exec do continue
		target_fn := n.hot_proc_target != "" ? sanitize_odin_ident(n.hot_proc_target, context.temp_allocator) : "hot_harmonic_hover"
		out_slot := 0
		for po, oi in n.outputs {
			if po.pin_type == .Exec || po.split_parent_name != "" do continue
			out_t := _pin_odin_type_in_graph(g, po, context.temp_allocator)
			fmt.sbprintf(b, "_bp_pure_%s_%d_out%d :: #force_inline proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32", clean_name, n.uid, oi)
			for p, pi in n.inputs {
				if p.pin_type == .Exec || p.split_parent_name != "" do continue
				pt := _pin_odin_type_in_graph(g, p, context.temp_allocator)
				if p.pass_mode == .By_Reference {
					fmt.sbprintf(b, ", in_%d: ^%s", pi, pt)
				} else {
					fmt.sbprintf(b, ", in_%d: %s", pi, pt)
				}
			}
			fmt.sbprintf(b, ") -> %s {{\n", out_t)
			strings.write_string(b, "\t_sub_f: hot.Hot_Call_Frame\n")
			arg_idx := _emit_hot_call_frame_inputs(b, g, clean_name, &n, "\t", "_sub_f", 0, 0, true)
			fmt.sbprintf(b, "\t_sub_f.input_count = %d\n", arg_idx)
			fmt.sbprintf(b, "\t%s(api, self, dt, &_sub_f)\n", target_fn)
			fmt.sbprintf(b, "\treturn %s\n}}\n\n", _slot_read_call_for_pin(po, fmt.tprintf("&_sub_f.outputs[%d]", out_slot), false, g))
			out_slot += 1
		}
	}
}

// Returns the default Zone 1 header for a new or migrated `.bodin` file.
// Everything above `// @BODIN_GENERATED_BEGIN` is user-owned raw Odin (multiple structs, enums,
// helper procs, `defer`, `context.temp_allocator`, `mem.Arena`, `[]f32`, `[dynamic]f32`).
default_bodin_zone1_header :: proc(clean_name: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "#+feature using-stmt\n")
	strings.write_string(&sb, "package hot_scripts\n\n")
	fmt.sbprintf(&sb, "// =============================================================================\n")
	fmt.sbprintf(&sb, "// CHIMERA `.bodin` USER ODIN ZONE (%s.bodin)\n", clean_name)
	fmt.sbprintf(&sb, "// =============================================================================\n")
	strings.write_string(&sb, "// Everything ABOVE `// @BODIN_GENERATED_BEGIN` is 100%% user-owned raw Odin:\n")
	strings.write_string(&sb, "//   - Multiple `struct` & `enum` declarations auto-sync to Blueprint Graph!\n")
	strings.write_string(&sb, "//   - Full `defer`, `context.temp_allocator`, `mem.Arena`, `[]f32`, `[dynamic]f32`, `@(bp_node)`!\n\n")
	strings.write_string(&sb, "@(require) import hot \"haati:engine/hot_api\"\n")
	return strings.to_string(sb)
}

@(private = "file")
_odin_body_ends_with_top_return :: proc(body: string) -> bool {
	trimmed := strings.trim_right_space(body)
	if trimmed == "" do return false
	lines := strings.split_lines(trimmed, context.temp_allocator)
	if len(lines) == 0 do return false
	last := strings.trim_suffix(lines[len(lines) - 1], "\r")
	// Only skip trailing `return` if the final line is an unindented top-level `return`.
	clean := strings.trim_left_space(last)
	if len(last) != len(clean) do return false
	return clean == "return" || strings.has_prefix(clean, "return ")
}

// Emits Zone 2 (Blueprint-managed Odin state, loaders, node bodies, and `@(hot_proc)` entry points)
// with import paths deduplicated against `zone1_src` for `-vet-unused` safety.
transpile_graph_zone2 :: proc(
	g:         ^engine.Visual_Graph,
	zone1_src: string,
	allocator := context.allocator,
) -> (zone2_source: string, main_proc_name: string) {
	clean_name := sanitize_odin_ident(g.name != "" ? g.name : "custom_graph", context.temp_allocator)
	main_proc_name = strings.clone(fmt.tprintf("mhgraph_%s", clean_name), allocator)
	state_struct := fmt.tprintf("%s_Blueprint_State", clean_name)

	need_runtime := false
	for v in g.variables {
		if engine.vg_resolve_container_kind(v) == .Dynamic_Array {
			need_runtime = true
			break
		}
	}

	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "// Auto-generated by Haati Blueprint Studio (`%s.bodin`) — edits to _node_*_body sync back on save.\n", clean_name)

	if need_runtime && !strings.contains(zone1_src, "\"base:runtime\"") {
		strings.write_string(&b, "@(require) import \"base:runtime\"\n")
	}
	if !strings.contains(zone1_src, "\"core:math\"") {
		strings.write_string(&b, "@(require) import \"core:math\"\n")
	}
	if !strings.contains(zone1_src, "\"core:math/linalg\"") {
		strings.write_string(&b, "@(require) import \"core:math/linalg\"\n")
	}
	if engine.vg_has_using_space(g, "ease") && !strings.contains(zone1_src, "\"core:math/ease\"") {
		strings.write_string(&b, "@(require) import \"core:math/ease\"\n")
	}
	if engine.vg_has_using_space(g, "rand") && !strings.contains(zone1_src, "\"core:math/rand\"") {
		strings.write_string(&b, "@(require) import \"core:math/rand\"\n")
	}
	if !strings.contains(zone1_src, "hot \"haati:engine/hot_api\"") {
		strings.write_string(&b, "@(require) import hot \"haati:engine/hot_api\"\n")
	}
	strings.write_byte(&b, '\n')

	// 0. User Enums, BitSets, POD Structs, Bounded Array Structs, & Pure Call Helpers
	_emit_user_types_and_helpers(&b, g, clean_name)

	// 1. Flat Data-Oriented Blueprint State Struct (`Pseudo-OOP` `using bp` backing!)
	fmt.sbprintf(&b, "%s :: struct {{\n", state_struct)
	if len(g.variables) == 0 {
		strings.write_string(&b, "\t_reserved: u8,\n")
	} else {
		for v in g.variables {
			vtype := engine.vg_var_odin_type_ex(g, v, context.temp_allocator)
			fmt.sbprintf(&b, "\t%s: %s,\n", sanitize_odin_ident(v.name, context.temp_allocator), vtype)
		}
	}
	strings.write_string(&b, "}\n\n")

	// State loader & writer bridging persistent per-entity `var_f32_seq_ptr`/`var_blob_ptr`/`var_ptr` AND `Hot_Call_Frame` slots!
	fmt.sbprintf(&b, "_load_%s_state :: #force_inline proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, frame: ^hot.Hot_Call_Frame) -> (st: %s) {{\n", clean_name, state_struct)
	for v, vi in g.variables {
		v_id := sanitize_odin_ident(v.name, context.temp_allocator)
		v_type := engine.vg_var_odin_type_ex(g, v, context.temp_allocator)
		def_expr := _emit_var_default_expr(v, g)
		ck := engine.vg_resolve_container_kind(v)
		if ck == .Slice && v.pin_type == .Float {
			fmt.sbprintf(&b, "\t{{\n\t\t_l, _c: i32\n\t\t_p := hot.var_f32_seq_ptr(api, self, %q, &_l, &_c)\n\t\tst.%s = (_p != nil && _l > 0) ? ([^]f32)(_p)[:_l] : nil\n\t}}\n", v.name, v_id)
		} else if ck == .Dynamic_Array && v.pin_type == .Float {
			fmt.sbprintf(&b, "\t{{\n\t\t_l, _c: i32\n\t\t_p := hot.var_f32_seq_ptr(api, self, %q, &_l, &_c)\n\t\t_al := (api != nil && api.host_allocator.procedure != nil) ? api.host_allocator : context.allocator\n\t\tst.%s = transmute([dynamic]f32)runtime.Raw_Dynamic_Array{{data = _p, len = int(max(_l, 0)), cap = int(max(_c, 0)), allocator = _al}}\n\t}}\n", v.name, v_id)
		} else if ck == .Slice {
			elem_t := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
			fmt.sbprintf(&b, "\t{{\n\t\t_l, _c: i32\n\t\t_p := hot.var_seq_ptr(api, self, %q, i32(size_of(%s)), i32(align_of(%s)), &_l, &_c)\n\t\tst.%s = (_p != nil && _l > 0) ? ([^]%s)(_p)[:_l] : nil\n\t}}\n", v.name, elem_t, elem_t, v_id, elem_t)
		} else if ck == .Dynamic_Array {
			elem_t := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
			fmt.sbprintf(&b, "\t{{\n\t\t_l, _c: i32\n\t\t_p := hot.var_seq_ptr(api, self, %q, i32(size_of(%s)), i32(align_of(%s)), &_l, &_c)\n\t\t_al := (api != nil && api.host_allocator.procedure != nil) ? api.host_allocator : context.allocator\n\t\tst.%s = transmute([dynamic]%s)runtime.Raw_Dynamic_Array{{data = _p, len = int(max(_l, 0)), cap = int(max(_c, 0)), allocator = _al}}\n\t}}\n", v.name, elem_t, elem_t, v_id, elem_t)
		} else if ck != .Single {
			fmt.sbprintf(&b, "\tst.%s = %s\n", v_id, def_expr)
			if ck == .Bounded_Array || v.pin_type == .Struct_Val {
				fmt.sbprintf(&b, "\tif bp_blob := hot.var_blob_ptr(api, self, %q, size_of(%s)); bp_blob != nil {{\n", v.name, v_type)
				fmt.sbprintf(&b, "\t\tst.%s = (cast(^%s)bp_blob)^\n\t}}\n", v_id, v_type)
			} else {
				scalar_type := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
				fmt.sbprintf(&b, "\tif bp_blob := hot.var_blob_ptr(api, self, %q, size_of(%s)); bp_blob != nil {{\n", v.name, v_type)
				fmt.sbprintf(&b, "\t\tst.%s = (cast(^%s)bp_blob)^\n", v_id, v_type)
				fmt.sbprintf(&b, "\t}} else if vp := hot.var_ptr(api, self, %d); vp != nil {{\n", vi)
				fmt.sbprintf(&b, "\t\tst.%s[0] = (cast(^%s)vp)^\n\t}}\n", v_id, scalar_type)
			}
		} else if v.pin_type == .Struct_Val {
			fmt.sbprintf(&b, "\tif bp_blob := hot.var_blob_ptr(api, self, %q, size_of(%s)); bp_blob != nil {{\n", v.name, v_type)
			fmt.sbprintf(&b, "\t\tst.%s = (cast(^%s)bp_blob)^\n\t}} else {{\n\t\tst.%s = %s\n\t}}\n", v_id, v_type, v_id, def_expr)
		} else {
			fmt.sbprintf(&b, "\tif vp := hot.var_ptr(api, self, %d); vp != nil {{\n", vi)
			fmt.sbprintf(&b, "\t\tst.%s = (cast(^%s)vp)^\n", v_id, v_type)
			if vi == 0 && v.pin_type == .Float {
				fmt.sbprintf(&b, "\t}} else if frame != nil && frame.input_count > 0 {{\n\t\tst.%s = hot.slot_read_f32(&frame.inputs[0])\n", v_id)
			} else if vi == 1 && v.pin_type == .Float {
				fmt.sbprintf(&b, "\t}} else if frame != nil && frame.input_count > 1 {{\n\t\tst.%s = hot.slot_read_f32(&frame.inputs[1])\n", v_id)
			} else if vi == 2 && v.pin_type == .Float {
				fmt.sbprintf(&b, "\t}} else if frame != nil && frame.input_count > 2 {{\n\t\tst.%s = hot.slot_read_f32(&frame.inputs[2])\n", v_id)
			}
			fmt.sbprintf(&b, "\t}} else {{\n\t\tst.%s = %s\n\t}}\n", v_id, def_expr)
		}
	}
	strings.write_string(&b, "\t_ = api; _ = self; _ = frame\n\treturn\n}\n\n")

	fmt.sbprintf(&b, "_save_%s_state :: #force_inline proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, frame: ^hot.Hot_Call_Frame, st: ^%s) {{\n", clean_name, state_struct)
	for v, vi in g.variables {
		v_id := sanitize_odin_ident(v.name, context.temp_allocator)
		v_type := engine.vg_var_odin_type_ex(g, v, context.temp_allocator)
		ck := engine.vg_resolve_container_kind(v)
		if ck == .Slice && v.pin_type == .Float {
			fmt.sbprintf(&b, "\thot.var_f32_seq_sync(api, self, %q, raw_data(st.%s), i32(len(st.%s)), -1)\n", v.name, v_id, v_id)
		} else if ck == .Dynamic_Array && v.pin_type == .Float {
			fmt.sbprintf(&b, "\thot.var_f32_seq_sync(api, self, %q, raw_data(st.%s), i32(len(st.%s)), i32(cap(st.%s)))\n", v.name, v_id, v_id, v_id)
		} else if ck == .Slice {
			elem_t := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
			fmt.sbprintf(&b, "\thot.var_seq_sync(api, self, %q, rawptr(raw_data(st.%s)), i32(size_of(%s)), i32(align_of(%s)), i32(len(st.%s)), -1)\n", v.name, v_id, elem_t, elem_t, v_id)
		} else if ck == .Dynamic_Array {
			elem_t := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
			fmt.sbprintf(&b, "\thot.var_seq_sync(api, self, %q, rawptr(raw_data(st.%s)), i32(size_of(%s)), i32(align_of(%s)), i32(len(st.%s)), i32(cap(st.%s)))\n", v.name, v_id, elem_t, elem_t, v_id, v_id)
		} else if ck != .Single {
			fmt.sbprintf(&b, "\tif bp_blob := hot.var_blob_ptr(api, self, %q, size_of(%s)); bp_blob != nil {{ (cast(^%s)bp_blob)^ = st.%s }}\n", v.name, v_type, v_type, v_id)
			if ck != .Bounded_Array && v.pin_type != .Struct_Val {
				scalar_type := _pin_odin_type_in_graph(g, engine.VG_Pin_Def{pin_type = v.pin_type, custom_type_name = v.custom_type_name}, context.temp_allocator)
				fmt.sbprintf(&b, "\tif vp := hot.var_ptr(api, self, %d); vp != nil {{ (cast(^%s)vp)^ = st.%s[0] }}\n", vi, scalar_type, v_id)
			}
		} else if v.pin_type == .Struct_Val {
			fmt.sbprintf(&b, "\tif bp_blob := hot.var_blob_ptr(api, self, %q, size_of(%s)); bp_blob != nil {{ (cast(^%s)bp_blob)^ = st.%s }}\n", v.name, v_type, v_type, v_id)
		} else {
			fmt.sbprintf(&b, "\tif vp := hot.var_ptr(api, self, %d); vp != nil {{ (cast(^%s)vp)^ = st.%s }}\n", vi, v_type, v_id)
			if vi == 2 && v.pin_type == .Float {
				fmt.sbprintf(&b, "\tif frame != nil && frame.input_count > 2 {{ if ap := hot.slot_ref_f32(&frame.inputs[2]); ap != nil {{ ap^ = st.%s }} }}\n", v_id)
			}
		}
	}
	strings.write_string(&b, "\t_ = api; _ = self; _ = frame; _ = st\n}\n\n")

	// 2. Emit each `Odin_Function_Node` as a standard Odin proc (full `defer`/allocators/slices) AND a `@(hot_proc)` wrapper!
	use_self_global := len(g.variables) > 0 && engine.vg_has_using_space(g, "self")
	use_math_ns     := engine.vg_has_using_space(g, "using_math")
	use_linalg_ns   := engine.vg_has_using_space(g, "using_linalg")

	for &n in g.nodes {
		if n.kind != .Odin_Function_Node do continue

		use_self_here := use_self_global && !_node_has_var_pin_collision(g, &n)
		fmt.sbprintf(&b, "// Scoped Odin Node #%d: %s\n", n.uid, n.title)
		fmt.sbprintf(
			&b,
			"_node_%s_%d_body :: #force_inline proc(\n\tapi: ^hot.Engine_Hot_API,\n\tself: hot.Hot_Entity,\n\t%sbp: ^%s,\n\tdt: f32",
			clean_name,
			n.uid,
			use_self_here ? "using " : "",
			state_struct,
		)
		for p in n.inputs {
			if p.pin_type == .Exec || p.split_parent_name != "" do continue
			pname := sanitize_odin_ident(p.name, context.temp_allocator)
			ptype := _pin_odin_type_in_graph(g, p, context.temp_allocator)
			if p.pass_mode == .By_Reference {
				fmt.sbprintf(&b, ",\n\t%s: ^%s", pname, ptype)
			} else {
				fmt.sbprintf(&b, ",\n\t%s: %s", pname, ptype)
			}
		}
		strings.write_string(&b, ",\n)")

		ret_pins := make([dynamic]engine.VG_Pin_Def, context.temp_allocator)
		for p in n.outputs {
			if p.pin_type != .Exec && p.split_parent_name == "" do append(&ret_pins, p)
		}
		if len(ret_pins) > 0 {
			strings.write_string(&b, " -> (")
			for rp, ri in ret_pins {
				if ri > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "%s: %s", sanitize_odin_ident(rp.name, context.temp_allocator), _pin_odin_type_in_graph(g, rp, context.temp_allocator))
			}
			strings.write_byte(&b, ')')
		}
		strings.write_string(&b, " {\n")
		if use_math_ns   do strings.write_string(&b, "\tusing math\n")
		if use_linalg_ns do strings.write_string(&b, "\tusing linalg\n")
		strings.write_string(&b, "\t_ = api; _ = self; _ = bp; _ = dt\n")
		for p in n.inputs {
			if p.pin_type == .Exec || p.split_parent_name != "" do continue
			fmt.sbprintf(&b, "\t_ = %s\n", sanitize_odin_ident(p.name, context.temp_allocator))
		}

		for ln in strings.split_lines(n.odin_body, context.temp_allocator) {
			trimmed_cr := strings.trim_suffix(ln, "\r")
			if len(strings.trim_space(trimmed_cr)) > 0 {
				fmt.sbprintf(&b, "\t%s\n", trimmed_cr)
			}
		}

		if !_odin_body_ends_with_top_return(n.odin_body) {
			strings.write_string(&b, "\treturn\n")
		}
		strings.write_string(&b, "}\n\n")

		node_sym := fmt.tprintf("_mhnode_%s_%d", clean_name, n.uid)
		if n.hot_proc_target != "" && !strings.has_prefix(n.hot_proc_target, "_mhnode_") {
			node_sym = sanitize_odin_ident(n.hot_proc_target, context.temp_allocator)
		}
		fmt.sbprintf(&b, "@(hot_proc)\n%s :: proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, frame: ^hot.Hot_Call_Frame) {{\n", node_sym)
		strings.write_string(&b, "\tcontext = hot.make_script_context(api)\n")
		strings.write_string(&b, "\tif frame == nil do return\n")
		fmt.sbprintf(&b, "\t_bp := _load_%s_state(api, self, frame)\n", clean_name)
		fmt.sbprintf(&b, "\tdefer _save_%s_state(api, self, frame, &_bp)\n", clean_name)
		arg_i := 0
		call_args := make([dynamic]string, context.temp_allocator)
		for p in n.inputs {
			if p.pin_type == .Exec || p.split_parent_name != "" do continue
			is_ref := p.pass_mode == .By_Reference
			expr := _slot_read_call_for_pin(p, fmt.tprintf("&frame.inputs[%d]", arg_i), is_ref, g)
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
			if engine.vg_pin_container_kind(rp) == .Slice {
				fmt.sbprintf(&b, "\tframe.outputs[%d] = {{pin_type = .%v, ref_ptr = rawptr(raw_data(_r%d)), slice_len = i32(len(_r%d)), slice_cap = -1}}\n", ri, rp.pin_type, ri, ri)
			} else if rp.pin_type == .Enum_U8 || rp.pin_type == .BitSet_U8 {
				fmt.sbprintf(&b, "\tframe.outputs[%d] = {{pin_type = .%v, val_u8 = u8(_r%d)}}\n", ri, rp.pin_type, ri)
			} else if rp.pin_type == .Struct_Val {
				fmt.sbprintf(&b, "\tframe.outputs[%d] = {{pin_type = .Struct_Val}}; if size_of(_r%d) <= hot.HOT_MAX_STRUCT_BYTES {{ (cast(^%s)raw_data(frame.outputs[%d].val_bytes[:]))^ = _r%d }}\n", ri, ri, _pin_odin_type_in_graph(g, rp, context.temp_allocator), ri, ri)
			} else {
				field := _slot_field_for_pin(rp.pin_type)
				fmt.sbprintf(&b, "\tframe.outputs[%d] = {{pin_type = .%v, %s = _r%d}}\n", ri, rp.pin_type, field, ri)
			}
		}
		fmt.sbprintf(&b, "\tframe.output_count = %d\n}}\n\n", len(ret_pins))
	}

	// 3. Emit every `Custom_Proc_Entry` as its own hot-swappable `@(hot_proc)` Delegate target!
	emitted_procs := make(map[string]bool, 16, context.temp_allocator)
	for &n in g.nodes {
		if n.kind != .Custom_Proc_Entry || !n.enabled do continue
		p_clean := sanitize_odin_ident(n.hot_proc_target != "" ? n.hot_proc_target : n.title, context.temp_allocator)
		proc_sym := fmt.tprintf("mhgraph_%s__proc_%s", clean_name, p_clean)
		if proc_sym in emitted_procs do continue
		emitted_procs[proc_sym] = true

		_emit_proc_entry_boilerplate(&b, clean_name, proc_sym, true)
		for oi in 5 ..< len(n.outputs) {
			slot_i := 3 + (oi - 5)
			if slot_i >= hot.HOT_MAX_ARGS do break
			op := n.outputs[oi]
			if op.split_parent_name != "" do continue
			read_e := _slot_read_call_for_pin(op, fmt.tprintf("&frame.inputs[%d]", slot_i), false, g)
			def_e  := _emit_pin_default_expr(op, g)
			fmt.sbprintf(&b, "\t_proc_param_%d := frame != nil && frame.input_count > %d ? %s : %s\n", oi, slot_i, read_e, def_e)
			fmt.sbprintf(&b, "\t_ = _proc_param_%d\n", oi)
		}
		if n.proc_use_odin_body {
			strings.write_string(&b, "\t{\n")
			if use_self_global && !_node_has_var_pin_collision(g, &n) {
				strings.write_string(&b, "\t\tusing &_bp\n")
			}
			if use_math_ns   do strings.write_string(&b, "\t\tusing math\n")
			if use_linalg_ns do strings.write_string(&b, "\t\tusing linalg\n")
			strings.write_string(&b, "\t\tpayload := _payload_f32; _ = payload\n")
			strings.write_string(&b, "\t\tinput_vec2 := _payload_v2; _ = input_vec2\n")
			strings.write_string(&b, "\t\tpressed := _pressed; _ = pressed\n")
			for oi in 5 ..< len(n.outputs) {
				if n.outputs[oi].split_parent_name != "" do continue
				p_ident := sanitize_odin_ident(n.outputs[oi].name, context.temp_allocator)
				fmt.sbprintf(&b, "\t\t%s := _proc_param_%d; _ = %s\n", p_ident, oi, p_ident)
			}
			for ln in strings.split_lines(n.odin_body, context.temp_allocator) {
				trimmed_cr := strings.trim_suffix(ln, "\r")
				if len(strings.trim_space(trimmed_cr)) > 0 {
					fmt.sbprintf(&b, "\t\t%s\n", trimmed_cr)
				}
			}
			strings.write_string(&b, "\t}\n")
		} else {
			entry_next := 0
			for w in g.wires {
				if w.from_uid == n.uid && w.from_pin == 1 {
					entry_next = w.to_uid
					break
				}
			}
			visited := make(map[int]bool, context.temp_allocator)
			_emit_exec_chain(&b, g, clean_name, entry_next, "\t", &visited, 0)
		}
		_emit_proc_exit_boilerplate(&b, true)
	}

	// 4-7. Lifecycle Entry Procedures (`__on_init`, `__on_destroy`, `__on_trigger`, and Opt-In `Event_Tick`)
	_emit_lifecycle_event_proc(&b, g, clean_name, .Event_Init,       fmt.tprintf("%s__on_init", main_proc_name))
	_emit_lifecycle_event_proc(&b, g, clean_name, .Event_Destroy,    fmt.tprintf("%s__on_destroy", main_proc_name))
	_emit_lifecycle_event_proc(&b, g, clean_name, .Event_On_Trigger, fmt.tprintf("%s__on_trigger", main_proc_name), is_trigger = true)
	_emit_lifecycle_event_proc(&b, g, clean_name, .Event_Tick,       main_proc_name)

	return strings.to_string(b), main_proc_name
}

// Assembles Zone 1 + Zone 2 Chimera `.bodin` Odin source cleanly from `zone1_src` (or default Zone 1).
assemble_bodin_odin_sections :: proc(
	g:             ^engine.Visual_Graph,
	zone1_src:     string,
	with_markers:  bool,
	allocator := context.allocator,
) -> (combined_odin: string, main_proc_name: string) {
	clean_name := sanitize_odin_ident(g.name != "" ? g.name : "custom_graph", context.temp_allocator)
	z1 := strings.trim_right_space(zone1_src)
	if z1 == "" {
		z1 = strings.trim_right_space(default_bodin_zone1_header(clean_name, context.temp_allocator))
	}
	z2, main_p := transpile_graph_zone2(g, z1, context.temp_allocator)
	z2_trim := strings.trim_space(z2)

	sb := strings.builder_make(0, len(z1) + len(z2_trim) + 96, allocator)
	strings.write_string(&sb, z1)
	strings.write_string(&sb, "\n\n")
	if with_markers {
		strings.write_string(&sb, engine.BODIN_GENERATED_BEGIN)
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, z2_trim)
	if with_markers {
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, engine.BODIN_GENERATED_END)
	}
	strings.write_byte(&sb, '\n')
	return strings.to_string(sb), strings.clone(main_p, allocator)
}

// Generates the complete, `-vet-unused` clean `.odin` source string for `g`!
transpile_graph_to_odin :: proc(g: ^engine.Visual_Graph, allocator := context.allocator) -> (odin_source: string, main_proc_name: string) {
	return assemble_bodin_odin_sections(g, "", false, allocator)
}

@(private = "file")
_read_existing_bodin_source :: proc(abs_g: string, allocator := context.temp_allocator) -> string {
	if open_txt, is_open := cs.get_open_tab_text(abs_g, allocator); is_open {
		return open_txt
	}
	if abs_g != "" && os.exists(abs_g) {
		if raw, err := os.read_entire_file(abs_g, context.temp_allocator); err == nil {
			return strings.clone(string(raw), allocator)
		}
	}
	return ""
}

// Writes unified `<graph>.bodin` (preserving Zone 1 raw Odin above `// @BODIN_GENERATED_BEGIN`)
// AND syncs `haati/hot_scripts/<name>_mhgraph_generated.odin` for instant `hot_cartridge.dll` hot-swap!
bake_graph_to_odin_file :: proc(g: ^engine.Visual_Graph, mhgraph_save_path: string = "") -> (gen_odin_abs: string, proc_name: string, ok: bool) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	abs_g := ""
	if mhgraph_save_path != "" {
		abs_g = _vs_resolve_graph_path(mhgraph_save_path, context.temp_allocator)
	}

	clean_name := sanitize_odin_ident(g.name != "" ? g.name : "custom_graph", context.temp_allocator)
	zone1 := ""
	has_z1 := false
	if g == &_vs.graph && _vs.ram_zone1_override != "" {
		zone1 = strings.clone(_vs.ram_zone1_override, context.temp_allocator)
		has_z1 = true
	} else {
		existing_src := _read_existing_bodin_source(abs_g, context.temp_allocator)
		zone1, has_z1 = engine.vg_extract_bodin_user_zone(existing_src, context.temp_allocator)
	}
	if !has_z1 || strings.trim_space(zone1) == "" {
		zone1 = default_bodin_zone1_header(clean_name, context.temp_allocator)
	}

	sync_bodin_user_ast_into_graph(g, zone1)

	bodin_odin, main_proc := assemble_bodin_odin_sections(g, zone1, true, context.temp_allocator)
	flat_odin, _          := assemble_bodin_odin_sections(g, zone1, false, context.temp_allocator)

	if abs_g != "" {
		dir_g: string
		{
			context.allocator = context.temp_allocator
			dir_g = filepath.dir(abs_g)
		}
		_ = os.make_directory_all(dir_g)
		if g == &_vs.graph {
			_sync_canvas_to_graph_comments(g)
		}
		if strings.has_suffix(strings.to_lower(abs_g, context.temp_allocator), ".bodin") {
			_ = engine.vg_save_bodin_file(g, abs_g, bodin_odin)
		} else {
			_ = engine.vg_save_to_file(g, abs_g)
		}
		engine.visual_script_invalidate_cached_graph(mhgraph_save_path)
		if g == &_vs.graph && _vs.ram_zone1_override != "" {
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			delete(_vs.ram_zone1_override)
			_vs.ram_zone1_override = ""
			context.allocator = prev_alloc
		}
		cs.reload_file_tab_from_disk(abs_g)
	}

	rel_odin := fmt.tprintf("haati/hot_scripts/%s_mhgraph_generated.odin", clean_name)
	abs_odin, _ := filepath.join({repo_root, rel_odin}, context.temp_allocator)
	dir_odin: string
	{
		context.allocator = context.temp_allocator
		dir_odin = filepath.dir(abs_odin)
	}
	_ = os.make_directory_all(dir_odin)

	if os.write_entire_file(abs_odin, transmute([]u8)flat_odin) != nil {
		return "", "", false
	}
	norm_abs, _ := strings.replace_all(abs_odin, "\\", "/", context.temp_allocator)
	return norm_abs, main_proc, true
}
