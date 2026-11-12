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
import "core:strings"
import "../components_gen"
import db "../gen_db"
import "../gen_facts"

HotProcRow :: struct {
	proc_name:   string,
	pkg_alias:   string,
	import_path: string, // e.g. "moonhug:hot_scripts" or "moonhug:packages/app/hot_scripts"
	rel_file:    string,
	owner_root:  string, // "" for moonhug/hot_scripts, "<pkg>" for moonhug/packages/<pkg>/hot_scripts
}

HotProc_GenComp :: struct {
	row: HotProcRow,
}

@(init)
_register :: proc "contextless" () {
	db.provider("hot_cartridge/provide", provide)
	db.generator("hot_cartridge/generate", generate)
}

_is_hot_script_pkg :: proc(pkg_path: string) -> (import_path: string, owner_root: string, ok: bool) {
	if pkg_path == "moonhug/hot_scripts" {
		return "moonhug:hot_scripts", "", true
	}
	if strings.has_prefix(pkg_path, "moonhug/packages/") && strings.has_suffix(pkg_path, "/hot_scripts") {
		rest := pkg_path[len("moonhug/packages/"):]
		slash := strings.index(rest, "/")
		root := slash >= 0 ? rest[:slash] : rest
		return fmt.tprintf("moonhug:%s", pkg_path[len("moonhug/"):]), root, true
	}
	return "", "", false
}

provide :: proc(w: ^db.World) -> bool {
	store := db.get_or_create_comps(w, HotProc_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs))
	defer db.matcher_destroy(&m)

	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)
		if _, has_hot := gen_facts.attr_find(attr_set, "hot_proc"); !has_hot do continue

		imp_path, owner_root, valid_pkg := _is_hot_script_pkg(decl.pkg_path)
		if !valid_pkg {
			fmt.eprintf(
				"hot_cartridge_gen: @(hot_proc) `%s` in `%s` must live in `moonhug/hot_scripts` or `moonhug/packages/<pkg>/hot_scripts` to stay typeid-isolated!\n",
				decl.name,
				decl.pkg_path,
			)
			return false
		}

		alias, _ := strings.replace_all(decl.pkg_path[len("moonhug/"):], "/", "_")
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
	runnables: []gen_facts.Runnable_Pkg,
	schema_hash: u64,
) {
	included :: proc(r: HotProcRow, host_name: string, runnables: []gen_facts.Runnable_Pkg) -> bool {
		if r.owner_root == "" || host_name == "" do return true
		return r.owner_root == host_name || !gen_facts.is_runnable(runnables, r.owner_root)
	}

	seen_imports := make(map[string]string, context.temp_allocator)
	active_rows := make([dynamic]HotProcRow, context.temp_allocator)
	for r in rows {
		if !included(r, host_name, runnables) do continue
		seen_imports[r.pkg_alias] = r.import_path
		append(&active_rows, r)
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
	strings.write_string(&b, "}\n")

	db.emit(w, out_path, strings.to_string(b))
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
	strings.write_string(&b, "import hot \"moonhug:engine/hot_api\"\n")
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
	rows: [dynamic]HotProcRow
	defer delete(rows)

	if store != nil {
		for i in 0 ..< db.comps_len(store) {
			e := db.get_entity(store, i)
			append(&rows, db.get(store, e).row)
		}
	}
	slice.sort_by(rows[:], proc(a, b: HotProcRow) -> bool {
		if a.proc_name != b.proc_name do return a.proc_name < b.proc_name
		return a.pkg_alias < b.pkg_alias
	})

	schema_hash := _compute_component_schema_hash(w)
	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)

	// 1. Central registration (imported by editor & core tests)
	_emit_static_registration(
		w,
		"moonhug/engine/registration/hot_procs_generated.odin",
		"registration",
		"moonhug:engine",
		"",
		rows[:],
		runnables[:],
		schema_hash,
	)

	// 2. Per-runnable-package registration (`packages/app`, etc.)
	for rpkg in runnables {
		_emit_static_registration(
			w,
			fmt.tprintf("%s/hot_procs_generated.odin", rpkg.path),
			rpkg.name,
			"moonhug:engine",
			rpkg.name,
			rows[:],
			runnables[:],
			schema_hash,
		)
	}

	// 3. Fast C-ABI Cartridge DLL source (`builds/hot_cartridge_src/cartridge_generated.odin`)
	_emit_dll_cartridge_wrapper(w, rows[:], schema_hash)
	return true
}
