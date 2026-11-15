package property_drawer_gen

// property_drawer_gen: ECS prebuild module.
//
//   provide  - iterate the decls, recognise proc declarations carrying a
//              @property_drawer attribute, add a PropertyDrawer_GenComp (carrying
//              type_name / priority / proc_name / source_pkg).
//   generate - iterate the {decls, property_drawers} join view, sort by
//              priority, build property_drawer_generated.odin, emit it as a
//              GeneratedFile.
//
// String-building output is identical to the previous collect/generate version.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

// PropertyDrawer_GenComp marks a DeclInfo entity as a property_drawer proc and
// carries the facts the generator needs.
PropertyDrawer_GenComp :: struct {
	type_name:  string, // type expression for typeid_of(...), e.g. "f32" or "pkg.MyType"
	priority:   int,    // lower first, higher later
	proc_name:   string,
	source_pkg:  string, // package where the procedure is defined; empty or same as output => use bare proc_name
	source_path: string, // that package's scan path, for the import
	// Where the drawer was declared, rendered by gen_facts.attr_origin. A
	// drawer draws a whole field row, so debug tooltips show this on every row of
	// the drawn type.
	origin:      string,
}


@(init)
_register :: proc "contextless" () {
	db.provider("property_drawer/provide", provide)
	db.generator("property_drawer/generate", generate)
}


provide :: proc(w: ^db.World) -> bool {
	_property_drawers := db.get_or_create_comps(w, PropertyDrawer_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)
		args, found := gen_facts.attr_find(attr_set, "property_drawer")
		if !found do continue
		type_name := args.fields["type"]
		if type_name == "" do continue
		db.set(_property_drawers, entity, PropertyDrawer_GenComp{
			type_name  = type_name,
			priority   = gen_facts.attr_int(args, "priority"),
			proc_name   = decl.name,
			source_pkg  = decl.pkg.name,
			source_path = decl.pkg_path,
			origin      = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
		})
	}
	return true
}

_PropertyDrawerRow :: struct {
	type_name:   string,
	priority:    int,
	proc_name:   string,
	source_pkg:  string,
	source_path: string,
	origin:      string,
}

_OUT_DIR :: "haati/editor/inspector"

generate :: proc(w: ^db.World) -> bool {
	pkg_name := "inspector"

	entries: [dynamic]_PropertyDrawerRow
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_property_drawers := db.get_comps(w, PropertyDrawer_GenComp)
	m := db.all_of(db.r(decls), db.r(_property_drawers)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		drawer := db.get(_property_drawers, entity)
		append(&entries, _PropertyDrawerRow{
			type_name   = drawer.type_name,
			priority    = drawer.priority,
			proc_name   = drawer.proc_name,
			source_pkg  = drawer.source_pkg,
			source_path = drawer.source_path,
			origin      = drawer.origin,
		})
	}

	// Preserve previous collect_finalize ordering: sort by priority (lower first, higher later).
	// Total order — same-priority drawers must not depend on entity iteration
	// order under an unstable sort, or the emitted file churns between builds.
	slice.sort_by(entries[:], proc(a, b: _PropertyDrawerRow) -> bool {
		if a.priority != b.priority do return a.priority < b.priority
		if a.type_name != b.type_name do return a.type_name < b.type_name
		return a.proc_name < b.proc_name
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Collect external packages: from type names (typeid_of(pkg.T)) and from procedure locations (pkg.draw_proc).
	imports := gen_facts.import_set_make(pkg_name, _OUT_DIR)
	defer gen_facts.import_set_destroy(&imports)
	for e in entries {
		gen_facts.import_set_add_type_and_source(&imports, e.type_name, e.source_pkg, e.source_path)
	}
	gen_facts.write_gen_header(&b, &imports, {pkg_name = pkg_name, gen_name = "property_drawer_gen"})
	strings.write_string(&b, "init_property_drawer_map :: proc() {\n")

	for e in entries {
		rhs := gen_facts.qualified_ident(pkg_name, e.source_pkg, e.proc_name)
		fmt.sbprintf(&b, "\tmapPropertyDrawer[typeid_of(%s)] = %s\n", e.type_name, rhs)
		fmt.sbprintf(&b, "\tmapPropertyDrawerOrigin[typeid_of(%s)] = %q\n", e.type_name, e.origin)
	}

	strings.write_string(&b, "}\n")

	db.emit(w, "haati/editor/inspector/property_drawer_generated.odin", strings.to_string(b))
	return true
}
