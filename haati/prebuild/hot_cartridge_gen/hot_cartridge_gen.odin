package hot_cartridge_gen

// =============================================================================
// PREBUILD GENERATOR: `@(hot_proc)` STATIC TABLE & `hot_cartridge` DLL SOURCE
// =============================================================================
// Scans `@(hot_proc)` declarations in `moonhug/hot_scripts` and `moonhug/packages/*/hot_scripts`,
// computes a deterministic FNV-1a 64-bit schema hash over all `@(component)` structs, and emits:
//   1. `moonhug/engine/registration/hot_procs_generated.odin` (static registration for editor & tests)
//   2. `moonhug/packages/<runnable>/hot_procs_generated.odin` (static registration for standalone apps)
//   3. `builds/hot_cartridge_src/cartridge_generated.odin` (zero-engine-import C-ABI DLL wrapper
//      compiled in ~130 ms by `odin build builds/hot_cartridge_src -build-mode:dll`!)

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../components_gen"
import db "../gen_db"
import "../gen_facts"

HotProcRow :: struct {
	proc_name:   string,
	pkg_alias:   string,
	import_path: string, // e.g. "haati:hot_scripts" or "haati:packages/app/hot_scripts"
	rel_file:    string,
	owner_root:  string, // "" for moonhug/hot_scripts, "<pkg>" for moonhug/packages/<pkg>/hot_scripts
}

HotProc_GenComp :: struct {
	row: HotProcRow,
}

BpParamRole :: enum {
	User_Pin,
	Ctx_API,
	Ctx_Self,
	Ctx_DT,
}

BpNodeParam :: struct {
	role:          BpParamRole,
	name:          string,
	hot_pin_name:  string,
	slot_field:    string,
	odin_type:     string,
	by_ref:        bool,
	default_raw:   string,
	default_f32:   f32,
	default_i64:   i64,
	default_bool:  bool,
}

BpNodeRow :: struct {
	proc_name:      string,
	wrapper_name:   string,
	pkg_alias:      string,
	pkg_path:       string,
	pkg_name:       string,
	import_path:    string,
	rel_file:       string,
	owner_root:     string,
	display_title:  string,
	namespace_name: string,
	doc_comment:    string,
	is_pure:        bool,
	params:         []BpNodeParam,
	results:        []BpNodeParam,
}

BpNode_GenComp :: struct {
	row: BpNodeRow,
}

@(init)
_register :: proc "contextless" () {
	db.provider("hot_cartridge/provide", provide)
	db.generator("hot_cartridge/generate", generate)
}

_is_hot_script_pkg :: proc(pkg_path: string) -> (import_path: string, owner_root: string, ok: bool) {
	if pkg_path == "haati/hot_scripts" {
		return "haati:hot_scripts", "", true
	}
	if strings.has_prefix(pkg_path, "haati/packages/") && strings.has_suffix(pkg_path, "/hot_scripts") {
		rest := pkg_path[len("haati/packages/"):]
		slash := strings.index(rest, "/")
		root := slash >= 0 ? rest[:slash] : rest
		return fmt.tprintf("haati:%s", pkg_path[len("haati/"):]), root, true
	}
	return "", "", false
}

_map_bp_pin_type :: proc(raw_type: string) -> (hot_pin_name, slot_field, odin_type: string, by_ref: bool, ok: bool) {
	is_ptr := strings.has_prefix(raw_type, "^")
	base := is_ptr ? raw_type[1:] : raw_type
	switch base {
	case "bool":                           return "Bool",   "val_bool", "bool",           is_ptr, true
	case "i32":                            return "Int",    "val_int",  "i32",            is_ptr, true
	case "int":                            return "Int",    "val_int",  "int",            is_ptr, true
	case "i64":                            return "Int64",  "val_i64",  "i64",            is_ptr, true
	case "u8":                             return "U8",     "val_u8",   "u8",             is_ptr, true
	case "i8":                             return "I8",     "val_i8",   "i8",             is_ptr, true
	case "u16":                            return "U16",    "val_u16",  "u16",            is_ptr, true
	case "i16":                            return "I16",    "val_i16",  "i16",            is_ptr, true
	case "u32":                            return "U32",    "val_u32",  "u32",            is_ptr, true
	case "u64":                            return "U64",    "val_u64",  "u64",            is_ptr, true
	case "f32":                            return "Float",  "val_f32",  "f32",            is_ptr, true
	case "f64":                            return "F64",    "val_f64",  "f64",            is_ptr, true
	case "[2]f32":                         return "Vec2",   "val_vec2", "[2]f32",         is_ptr, true
	case "[3]f32":                         return "Vec3",   "val_vec3", "[3]f32",         is_ptr, true
	case "[4]f32":                         return "Vec4",   "val_vec4", "[4]f32",         is_ptr, true
	case "quaternion128":                  return "Quat",   "val_quat", "quaternion128",  is_ptr, true
	case "cstring":                        return "String", "val_cstr", "cstring",        is_ptr, true
	case "hot.Hot_Entity", "Hot_Entity":   return "Entity", "val_ent",  "hot.Hot_Entity", is_ptr, true
	}
	return "", "", "", false, false
}

_parse_bp_defaults :: proc(raw_def: string, pin_name: string) -> (df32: f32, di64: i64, dbool: bool) {
	if raw_def == "" do return 0, 0, false
	if raw_def == "true" {
		dbool = true
		return
	}
	if i_v, ok_i := strconv.parse_i64(raw_def); ok_i {
		di64 = i_v
		df32 = f32(i_v)
		return
	}
	if f_v, ok_f := strconv.parse_f32(raw_def); ok_f {
		df32 = f_v
		return
	}
	_ = pin_name
	return
}

provide :: proc(w: ^db.World) -> bool {
	store := db.get_or_create_comps(w, HotProc_GenComp)
	bp_store := db.get_or_create_comps(w, BpNode_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs))
	defer db.matcher_destroy(&m)

	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		// Skip our own generated `@(bp_node)` wrapper file for idempotent prebuilds!
		if strings.has_prefix(decl.name, "__bpwrap_") || strings.has_suffix(decl.file_path, "bp_nodes_wrappers_generated.odin") {
			continue
		}

		attr_set := db.get(attrs, entity)
		_, has_hot := gen_facts.attr_find(attr_set, "hot_proc")
		bp_attr, has_bp := gen_facts.attr_find(attr_set, "bp_node")
		if !has_hot && !has_bp do continue

		imp_path, owner_root, valid_pkg := _is_hot_script_pkg(decl.pkg_path)
		if !valid_pkg {
			attr_lbl := has_hot ? "@(hot_proc)" : "@(bp_node)"
			fmt.eprintf(
				"hot_cartridge_gen: %s `%s` in `%s` must live in `haati/hot_scripts` or `haati/packages/<pkg>/hot_scripts` to stay typeid-isolated!\n",
				attr_lbl,
				decl.name,
				decl.pkg_path,
			)
			return false
		}

		alias, _ := strings.replace_all(decl.pkg_path[len("haati/"):], "/", "_")
		if has_hot {
			db.set(store, entity, HotProc_GenComp{
				row = HotProcRow{
					proc_name   = decl.name,
					pkg_alias   = alias,
					import_path = imp_path,
					rel_file    = gen_facts.decl_rel_path(decl),
					owner_root  = owner_root,
				},
			})
		}

		if has_bp {
			proc_comp := db.get(procs, entity)
			sig := proc_comp.sig
			params_dyn := make([dynamic]BpNodeParam, 0, len(sig.params))
			results_dyn := make([dynamic]BpNodeParam, 0, len(sig.results))
			user_pins_started := false
			for sp in sig.params {
				if !user_pins_started {
					if sp.type_str == "^hot.Engine_Hot_API" || sp.type_str == "^Engine_Hot_API" {
						append(&params_dyn, BpNodeParam{role = .Ctx_API, name = sp.name, odin_type = sp.type_str})
						continue
					}
					if sp.name == "self" && (sp.type_str == "hot.Hot_Entity" || sp.type_str == "Hot_Entity") {
						append(&params_dyn, BpNodeParam{role = .Ctx_Self, name = sp.name, odin_type = sp.type_str})
						continue
					}
					if sp.name == "dt" && sp.type_str == "f32" {
						append(&params_dyn, BpNodeParam{role = .Ctx_DT, name = sp.name, odin_type = sp.type_str})
						continue
					}
					user_pins_started = true
				}
				pin_kind, s_field, o_type, by_ref, map_ok := _map_bp_pin_type(sp.type_str)
				if !map_ok {
					fmt.eprintf(
						"hot_cartridge_gen: @(bp_node) `%s` parameter `%s: %s` is unsupported across C-ABI Hot_Slot!\n",
						decl.name,
						sp.name,
						sp.type_str,
					)
					return false
				}
				df32, di64, dbool := _parse_bp_defaults(sp.default_val, pin_kind)
				append(&params_dyn, BpNodeParam{
					role         = .User_Pin,
					name         = sp.name,
					hot_pin_name = pin_kind,
					slot_field   = s_field,
					odin_type    = o_type,
					by_ref       = by_ref,
					default_raw  = sp.default_val,
					default_f32  = df32,
					default_i64  = di64,
					default_bool = dbool,
				})
			}
			for sr in sig.results {
				pin_kind, s_field, o_type, by_ref, map_ok := _map_bp_pin_type(sr.type_str)
				if !map_ok || by_ref {
					fmt.eprintf(
						"hot_cartridge_gen: @(bp_node) `%s` result `%s: %s` is unsupported across C-ABI Hot_Slot!\n",
						decl.name,
						sr.name,
						sr.type_str,
					)
					return false
				}
				append(&results_dyn, BpNodeParam{
					role         = .User_Pin,
					name         = sr.name,
					hot_pin_name = pin_kind,
					slot_field   = s_field,
					odin_type    = o_type,
				})
			}

			title := bp_attr.fields["title"]
			if title == "" do title = decl.name
			ns := bp_attr.fields["namespace"]
			if ns == "" do ns = "Odin_Hot"
			is_pure := bp_attr.fields["pure"] == "true"
			pkg_name := (decl.file != nil && decl.file.pkg_name != "") ? decl.file.pkg_name : "hot_scripts"

			db.set(bp_store, entity, BpNode_GenComp{
				row = BpNodeRow{
					proc_name      = decl.name,
					wrapper_name   = fmt.tprintf("__bpwrap_%s", decl.name),
					pkg_alias      = alias,
					pkg_path       = decl.pkg_path,
					pkg_name       = pkg_name,
					import_path    = imp_path,
					rel_file       = gen_facts.decl_rel_path(decl),
					owner_root     = owner_root,
					display_title  = title,
					namespace_name = ns,
					doc_comment    = sig.doc_comment,
					is_pure        = is_pure,
					params         = params_dyn[:],
					results        = results_dyn[:],
				},
			})
		}
	}
	return true
}

_compute_component_schema_hash :: proc(w: ^db.World) -> u64 {
	decls := db.get_comps_DeclInfo()
	comps := db.get_comps(w, components_gen.Component_GenComp)
	if comps == nil do return 0xcbf29ce484222325

	sigs: [dynamic]string
	defer {
		for s in sigs do delete(s)
		delete(sigs)
	}

	m := db.all_of(db.r(decls), db.r(comps))
	defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		comp := db.get(comps, entity)
		sb := strings.builder_make()
		fmt.sbprintf(&sb, "%s.%s:", comp.pkg, decl.name)
		for ft in comp.field_types {
			strings.write_string(&sb, ft)
			strings.write_byte(&sb, ';')
		}
		append(&sigs, strings.to_string(sb))
	}
	slice.sort(sigs[:])

	// Deterministic 64-bit FNV-1a hash
	h: u64 = 0xcbf29ce484222325
	for sig in sigs {
		for i in 0 ..< len(sig) {
			h ~= u64(sig[i])
			h *= 0x100000001b3
		}
	}
	if h == 0 do h = 1
	return h
}

_emit_static_registration :: proc(
	w: ^db.World,
	out_path: string,
	pkg_name: string,
	engine_import: string,
	host_name: string,
	rows: []HotProcRow,
	bp_rows: []BpNodeRow,
	runnables: []gen_facts.Runnable_Pkg,
	schema_hash: u64,
) {
	seen_imports := make(map[string]string, context.temp_allocator)
	active_rows := make([dynamic]HotProcRow, context.temp_allocator)
	for r in rows {
		if !gen_facts.is_included_for_host(runnables, host_name, r.owner_root) do continue
		seen_imports[r.pkg_alias] = r.import_path
		append(&active_rows, r)
	}

	active_bps := make([dynamic]BpNodeRow, context.temp_allocator)
	for bp in bp_rows {
		if !gen_facts.is_included_for_host(runnables, host_name, bp.owner_root) do continue
		append(&active_bps, bp)
	}

	aliases := make([dynamic]string, context.temp_allocator)
	for k in seen_imports do append(&aliases, k)
	slice.sort(aliases[:])

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintf(&b, "package %s\n\n", pkg_name)
	strings.write_string(&b, "// Code generated by hot_cartridge_gen. Do not edit.\n\n")
	strings.write_string(&b, "import \"base:runtime\"\n")
	if engine_import != "" {
		fmt.sbprintf(&b, "import __hot_eng \"%s\"\n", engine_import)
	}
	if len(active_bps) > 0 {
		strings.write_string(&b, "import __hot_api \"haati:engine/hot_api\"\n")
	}
	for a in aliases {
		fmt.sbprintf(&b, "import %s \"%s\"\n", a, seen_imports[a])
	}
	strings.write_string(&b, "\n@(init)\n")
	strings.write_string(&b, "_register_static_hot_procs :: proc \"contextless\" () {\n")
	strings.write_string(&b, "\tcontext = runtime.default_context()\n")
	eng_prefix := engine_import != "" ? "__hot_eng." : ""
	fmt.sbprintf(&b, "\t%shot_cartridge_set_boot_schema_hash(0x%016x)\n", eng_prefix, schema_hash)
	for r in active_rows {
		fmt.sbprintf(
			&b,
			"\t%shot_proc_register_static(%q, %s.%s, %q)\n",
			eng_prefix,
			r.proc_name,
			r.pkg_alias,
			r.proc_name,
			r.rel_file,
		)
	}
	for bp in active_bps {
		fmt.sbprintf(&b, "\t%shot_proc_register_sig_meta(__hot_api.Hot_Proc_Sig_Meta{{\n", eng_prefix)
		fmt.sbprintf(&b, "\t\tproc_name        = %q,\n", bp.wrapper_name)
		fmt.sbprintf(&b, "\t\tdisplay_title    = %q,\n", bp.display_title)
		fmt.sbprintf(&b, "\t\tnamespace_name   = %q,\n", bp.namespace_name)
		fmt.sbprintf(&b, "\t\tdoc_comment      = %q,\n", bp.doc_comment)
		fmt.sbprintf(&b, "\t\tsource_proc_name = %q,\n", bp.proc_name)
		fmt.sbprintf(&b, "\t\tis_pure          = %s,\n", bp.is_pure ? "true" : "false")
		strings.write_string(&b, "\t\tpins             = []__hot_api.Hot_Proc_Pin_Meta{\n")
		for p in bp.params {
			if p.role != .User_Pin do continue
			fmt.sbprintf(
				&b,
				"\t\t\t{{name = %q, pin_type = .%s, is_output = false, by_ref = %s, default_f32 = %f, default_i64 = %d, default_bool = %s}},\n",
				p.name,
				p.hot_pin_name,
				p.by_ref ? "true" : "false",
				p.default_f32,
				p.default_i64,
				p.default_bool ? "true" : "false",
			)
		}
		for r in bp.results {
			fmt.sbprintf(
				&b,
				"\t\t\t{{name = %q, pin_type = .%s, is_output = true}},\n",
				r.name,
				r.hot_pin_name,
			)
		}
		strings.write_string(&b, "\t\t},\n")
		strings.write_string(&b, "\t})\n")
	}
	strings.write_string(&b, "}\n")

	db.emit(w, out_path, strings.to_string(b))
}

_bp_default_literal :: proc(p: BpNodeParam) -> string {
	switch p.odin_type {
	case "bool":
		return p.default_bool ? "true" : "false"
	case "u8", "i8", "u16", "i16", "u32", "i32", "int", "i64", "u64":
		if p.default_raw != "" {
			if _, ok := strconv.parse_i64(p.default_raw); ok do return p.default_raw
		}
		return fmt.tprintf("%d", p.default_i64)
	case "f32", "f64":
		if p.default_raw != "" {
			if _, ok := strconv.parse_f64(p.default_raw); ok do return p.default_raw
		}
		return "0.0"
	case "quaternion128":
		return "quaternion(x = f32(0), y = f32(0), z = f32(0), w = f32(1))"
	case "cstring":
		return `""`
	}
	return "{}"
}

_emit_bp_node_wrappers :: proc(w: ^db.World, bp_rows: []BpNodeRow) {
	if len(bp_rows) == 0 do return
	pkgs := make(map[string][dynamic]BpNodeRow, context.temp_allocator)
	pkg_order := make([dynamic]string, context.temp_allocator)
	for bp in bp_rows {
		list, exists := &pkgs[bp.pkg_path]
		if !exists {
			pkgs[bp.pkg_path] = make([dynamic]BpNodeRow, 0, 8, context.temp_allocator)
			list = &pkgs[bp.pkg_path]
			append(&pkg_order, bp.pkg_path)
		}
		append(list, bp)
	}
	slice.sort(pkg_order[:])

	for pp in pkg_order {
		list := pkgs[pp]
		if len(list) == 0 do continue
		b := strings.builder_make()
		defer strings.builder_destroy(&b)

		fmt.sbprintf(&b, "package %s\n\n", list[0].pkg_name)
		strings.write_string(&b, "// Code generated by hot_cartridge_gen from @(bp_node) procs. Do not edit.\n\n")
		strings.write_string(&b, "import \"base:runtime\"\n")
		strings.write_string(&b, "import hot \"haati:engine/hot_api\"\n\n")

		for bp in list {
			strings.write_string(&b, "@(hot_proc)\n")
			fmt.sbprintf(
				&b,
				"%s :: proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32, frame: ^hot.Hot_Call_Frame) {{\n",
				bp.wrapper_name,
			)
			strings.write_string(&b, "\tcontext = runtime.default_context()\n")
			uses_api, uses_self, uses_dt := false, false, false
			for p in bp.params {
				switch p.role {
				case .Ctx_API:  uses_api = true
				case .Ctx_Self: uses_self = true
				case .Ctx_DT:   uses_dt = true
				case .User_Pin:
				}
			}
			if !uses_api  do strings.write_string(&b, "\t_ = api\n")
			if !uses_self do strings.write_string(&b, "\t_ = self\n")
			if !uses_dt   do strings.write_string(&b, "\t_ = dt\n")
			strings.write_string(&b, "\tif frame == nil do return\n")

			in_idx := 0
			call_args := make([dynamic]string, 0, len(bp.params), context.temp_allocator)
			ref_writebacks := make([dynamic]struct{ in_i: int, fb: string, slot_field: string, is_int: bool, is_quat: bool }, 0, 4, context.temp_allocator)
			for p in bp.params {
				switch p.role {
				case .Ctx_API:
					append(&call_args, "api")
				case .Ctx_Self:
					append(&call_args, "self")
				case .Ctx_DT:
					append(&call_args, "dt")
				case .User_Pin:
					def_lit := _bp_default_literal(p)
					if p.by_ref {
						fb_name := fmt.tprintf("_fb_%d", in_idx)
						ptr_name := fmt.tprintf("_ptr_%d", in_idx)
						if p.odin_type == "int" {
							fmt.sbprintf(
								&b,
								"\t%s: int = (%d < len(frame.inputs) && frame.input_count > %d) ? int(frame.inputs[%d].val_int) : (%s)\n",
								fb_name, in_idx, in_idx, in_idx, def_lit,
							)
							fmt.sbprintf(
								&b,
								"\t%s := &%s\n",
								ptr_name, fb_name,
							)
							append(&ref_writebacks, struct{ in_i: int, fb: string, slot_field: string, is_int: bool, is_quat: bool }{in_idx, fb_name, "val_int", true, false})
						} else if p.odin_type == "quaternion128" {
							fmt.sbprintf(
								&b,
								"\t_qraw_%d := (%d < len(frame.inputs) && frame.input_count > %d) ? frame.inputs[%d].val_quat : [4]f32{{0, 0, 0, 1}}\n",
								in_idx, in_idx, in_idx, in_idx,
							)
							fmt.sbprintf(
								&b,
								"\t%s := quaternion(x = _qraw_%d.x, y = _qraw_%d.y, z = _qraw_%d.z, w = _qraw_%d.w)\n",
								fb_name, in_idx, in_idx, in_idx, in_idx,
							)
							fmt.sbprintf(
								&b,
								"\t%s := (%d < len(frame.inputs) && frame.input_count > %d && frame.inputs[%d].ref_ptr != nil) ? cast(^quaternion128)frame.inputs[%d].ref_ptr : &%s\n",
								ptr_name, in_idx, in_idx, in_idx, in_idx, fb_name,
							)
							append(&ref_writebacks, struct{ in_i: int, fb: string, slot_field: string, is_int: bool, is_quat: bool }{in_idx, fb_name, "val_quat", false, true})
						} else {
							fmt.sbprintf(
								&b,
								"\t%s: %s = (%d < len(frame.inputs) && frame.input_count > %d) ? frame.inputs[%d].%s : (%s)\n",
								fb_name, p.odin_type, in_idx, in_idx, in_idx, p.slot_field, def_lit,
							)
							fmt.sbprintf(
								&b,
								"\t%s := (%d < len(frame.inputs) && frame.input_count > %d && frame.inputs[%d].ref_ptr != nil) ? cast(^%s)frame.inputs[%d].ref_ptr : &%s\n",
								ptr_name, in_idx, in_idx, in_idx, p.odin_type, in_idx, fb_name,
							)
							append(&ref_writebacks, struct{ in_i: int, fb: string, slot_field: string, is_int: bool, is_quat: bool }{in_idx, fb_name, p.slot_field, false, false})
						}
						append(&call_args, ptr_name)
					} else {
						arg_name := fmt.tprintf("_arg_%d", in_idx)
						if p.odin_type == "quaternion128" {
							fmt.sbprintf(
								&b,
								"\t_qraw_%d := (%d < len(frame.inputs) && frame.input_count > %d) ? frame.inputs[%d].val_quat : [4]f32{{0, 0, 0, 1}}\n",
								in_idx, in_idx, in_idx, in_idx,
							)
							fmt.sbprintf(
								&b,
								"\t%s := quaternion(x = _qraw_%d.x, y = _qraw_%d.y, z = _qraw_%d.z, w = _qraw_%d.w)\n",
								arg_name, in_idx, in_idx, in_idx, in_idx,
							)
						} else if p.odin_type == "int" {
							fmt.sbprintf(
								&b,
								"\t%s: int = (%d < len(frame.inputs) && frame.input_count > %d) ? int(frame.inputs[%d].val_int) : (%s)\n",
								arg_name, in_idx, in_idx, in_idx, def_lit,
							)
						} else {
							fmt.sbprintf(
								&b,
								"\t%s: %s = (%d < len(frame.inputs) && frame.input_count > %d) ? frame.inputs[%d].%s : (%s)\n",
								arg_name, p.odin_type, in_idx, in_idx, in_idx, p.slot_field, def_lit,
							)
						}
						append(&call_args, arg_name)
					}
					in_idx += 1
				}
			}

			arg_str := strings.join(call_args[:], ", ", context.temp_allocator)
			if len(bp.results) > 0 {
				res_names := make([dynamic]string, 0, len(bp.results), context.temp_allocator)
				for _, ri in bp.results {
					append(&res_names, fmt.tprintf("_res_%d", ri))
				}
				fmt.sbprintf(&b, "\t%s := %s(%s)\n", strings.join(res_names[:], ", ", context.temp_allocator), bp.proc_name, arg_str)
			} else {
				fmt.sbprintf(&b, "\t%s(%s)\n", bp.proc_name, arg_str)
			}

			for wb in ref_writebacks {
				if wb.is_int {
					fmt.sbprintf(&b, "\tif %d < len(frame.inputs) && frame.input_count > %d && frame.inputs[%d].ref_ptr != nil do (cast(^i32)frame.inputs[%d].ref_ptr)^ = i32(%s)\n", wb.in_i, wb.in_i, wb.in_i, wb.in_i, wb.fb)
					fmt.sbprintf(&b, "\tif %d < len(frame.inputs) && frame.input_count > %d && frame.inputs[%d].ref_ptr == nil do frame.inputs[%d].val_int = i32(%s)\n", wb.in_i, wb.in_i, wb.in_i, wb.in_i, wb.fb)
				} else if wb.is_quat {
					fmt.sbprintf(&b, "\tif %d < len(frame.inputs) && frame.input_count > %d && frame.inputs[%d].ref_ptr == nil do frame.inputs[%d].val_quat = [4]f32{{%s.x, %s.y, %s.z, %s.w}}\n", wb.in_i, wb.in_i, wb.in_i, wb.in_i, wb.fb, wb.fb, wb.fb, wb.fb)
				} else {
					fmt.sbprintf(&b, "\tif %d < len(frame.inputs) && frame.input_count > %d && frame.inputs[%d].ref_ptr == nil do frame.inputs[%d].%s = %s\n", wb.in_i, wb.in_i, wb.in_i, wb.in_i, wb.slot_field, wb.fb)
				}
			}

			fmt.sbprintf(&b, "\tframe.output_count = %d\n", len(bp.results))
			for r, ri in bp.results {
				fmt.sbprintf(&b, "\tif %d < len(frame.outputs) {{\n", ri)
				fmt.sbprintf(&b, "\t\tframe.outputs[%d].pin_type = .%s\n", ri, r.hot_pin_name)
				fmt.sbprintf(&b, "\t\tframe.outputs[%d].pass_mode = .Copy_Value\n", ri)
				if r.odin_type == "quaternion128" {
					fmt.sbprintf(&b, "\t\tframe.outputs[%d].val_quat = [4]f32{{_res_%d.x, _res_%d.y, _res_%d.z, _res_%d.w}}\n", ri, ri, ri, ri, ri)
				} else if r.odin_type == "int" {
					fmt.sbprintf(&b, "\t\tframe.outputs[%d].val_int = i32(_res_%d)\n", ri, ri)
				} else {
					fmt.sbprintf(&b, "\t\tframe.outputs[%d].%s = _res_%d\n", ri, r.slot_field, ri)
				}
				strings.write_string(&b, "\t}\n")
			}
			strings.write_string(&b, "}\n\n")
		}

		out_file := fmt.tprintf("%s/bp_nodes_wrappers_generated.odin", pp)
		db.emit(w, out_file, strings.to_string(b))
	}
}

_emit_dll_cartridge_wrapper :: proc(w: ^db.World, rows: []HotProcRow, schema_hash: u64) {
	_ = os.make_directory_all("builds/hot_cartridge_src")

	seen_imports := make(map[string]string, context.temp_allocator)
	for r in rows do seen_imports[r.pkg_alias] = r.import_path
	aliases := make([dynamic]string, context.temp_allocator)
	for k in seen_imports do append(&aliases, k)
	slice.sort(aliases[:])

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package hot_cartridge_dll\n\n")
	strings.write_string(&b, "// Code generated by hot_cartridge_gen. Do not edit.\n")
	strings.write_string(&b, "// Zero-engine-import C-ABI cartridge compiled via `odin build builds/hot_cartridge_src -build-mode:dll`.\n\n")
	strings.write_string(&b, "import hot \"haati:engine/hot_api\"\n")
	for a in aliases {
		fmt.sbprintf(&b, "import %s \"%s\"\n", a, seen_imports[a])
	}
	strings.write_string(&b, "\n_Entry :: struct {\n\tname: cstring,\n\tfn:   hot.Hot_Proc_Fn,\n}\n\n")
	fmt.sbprintf(&b, "@(rodata)\n_ENTRIES := [%d]_Entry{{\n", len(rows))
	for r in rows {
		fmt.sbprintf(&b, "\t{{%q, %s.%s}},\n", r.proc_name, r.pkg_alias, r.proc_name)
	}
	strings.write_string(&b, "}\n\n")
	fmt.sbprintf(&b, "@(export)\nmh_hot_cartridge_schema_hash :: proc \"c\" () -> u64 {{\n\treturn 0x%016x\n}}\n\n", schema_hash)
	strings.write_string(&b, "@(export)\n")
	strings.write_string(&b, "mh_hot_cartridge_query :: proc \"c\" (index: i32, out_name: ^cstring, out_fn: ^hot.Hot_Proc_Fn) -> bool {\n")
	strings.write_string(&b, "\tif index < 0 || int(index) >= len(_ENTRIES) do return false\n")
	strings.write_string(&b, "\tif out_name != nil do out_name^ = _ENTRIES[index].name\n")
	strings.write_string(&b, "\tif out_fn   != nil do out_fn^   = _ENTRIES[index].fn\n")
	strings.write_string(&b, "\treturn true\n")
	strings.write_string(&b, "}\n")

	db.emit(w, "builds/hot_cartridge_src/cartridge_generated.odin", strings.to_string(b))
}

generate :: proc(w: ^db.World) -> bool {
	store := db.get_comps(w, HotProc_GenComp)
	bp_store := db.get_comps(w, BpNode_GenComp)
	rows: [dynamic]HotProcRow
	defer delete(rows)
	bp_rows: [dynamic]BpNodeRow
	defer delete(bp_rows)

	if store != nil {
		for i in 0 ..< db.comps_len(store) {
			e := db.get_entity(store, i)
			append(&rows, db.get(store, e).row)
		}
	}
	if bp_store != nil {
		for i in 0 ..< db.comps_len(bp_store) {
			e := db.get_entity(bp_store, i)
			bp := db.get(bp_store, e).row
			append(&bp_rows, bp)
			append(&rows, HotProcRow{
				proc_name   = bp.wrapper_name,
				pkg_alias   = bp.pkg_alias,
				import_path = bp.import_path,
				rel_file    = bp.rel_file,
				owner_root  = bp.owner_root,
			})
		}
	}

	slice.sort_by(rows[:], proc(a, b: HotProcRow) -> bool {
		if a.proc_name != b.proc_name do return a.proc_name < b.proc_name
		return a.pkg_alias < b.pkg_alias
	})
	slice.sort_by(bp_rows[:], proc(a, b: BpNodeRow) -> bool {
		if a.proc_name != b.proc_name do return a.proc_name < b.proc_name
		return a.pkg_path < b.pkg_path
	})

	_emit_bp_node_wrappers(w, bp_rows[:])

	schema_hash := _compute_component_schema_hash(w)
	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)

	// 1. Central registration (imported by editor & core tests)
	_emit_static_registration(
		w,
		"haati/engine/registration/hot_procs_generated.odin",
		"registration",
		"haati:engine",
		"",
		rows[:],
		bp_rows[:],
		runnables[:],
		schema_hash,
	)

	// 2. Per-runnable-package registration (`packages/app`, etc.)
	for rpkg in runnables {
		_emit_static_registration(
			w,
			fmt.tprintf("%s/hot_procs_generated.odin", rpkg.path),
			rpkg.name,
			"haati:engine",
			rpkg.name,
			rows[:],
			bp_rows[:],
			runnables[:],
			schema_hash,
		)
	}

	// 3. Fast C-ABI Cartridge DLL source (`builds/hot_cartridge_src/cartridge_generated.odin`)
	_emit_dll_cartridge_wrapper(w, rows[:], schema_hash)
	return true
}
