package serialization_gen

// serialization_gen: ECS prebuild module.
//
//   provide  - iterate the decls, recognise proc decls with a
//              @before_serialize or @after_deserialize attribute, add a
//              Serialization_GenComp (carrying kind / type_name / priority /
//              proc_name / source_pkg).
//   generate - iterate the {decls, serializations} join view, sort, build
//              serialization_generated.odin, emit it (gen_db writes it).
//
// String-building output is identical to the previous collect/generate version.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

SerializationCallbackKind :: enum {
	BeforeSerialize,
	AfterDeserialize,
}

// Serialization_GenComp marks a DeclInfo entity as a serialization callback proc and
// carries the facts the generator needs.
Serialization_GenComp :: struct {
	kind:       SerializationCallbackKind,
	type_name:  string,
	priority:   int,
	proc_name:  string,
	source_pkg:  string,
	source_path: string, // that package's scan path, for the import
}


@(init)
_register :: proc "contextless" () {
	db.provider("serialization/provide", provide)
	db.generator("serialization/generate", generate)
}


_attr_field :: proc(attr_set: ^gen_facts.Attrs_GenComp, key: string) -> (type_name: string, priority: int, found: bool) {
	args, ok := gen_facts.attr_find(attr_set, key)
	if !ok do return "", 0, false
	type_name = args.fields["type"]
	priority = gen_facts.attr_int(args, "priority")
	return type_name, priority, type_name != ""
}

provide :: proc(w: ^db.World) -> bool {
	_serializations := db.get_or_create_comps(w, Serialization_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)

		if type_name, priority, found := _attr_field(attr_set, "before_serialize"); found {
			db.set(_serializations, entity, Serialization_GenComp{
				kind       = .BeforeSerialize,
				type_name  = type_name,
				priority   = priority,
				proc_name  = decl.name,
				source_pkg = decl.pkg.name,
				source_path = decl.pkg_path,
			})
			continue
		}
		if type_name, priority, found := _attr_field(attr_set, "after_deserialize"); found {
			db.set(_serializations, entity, Serialization_GenComp{
				kind       = .AfterDeserialize,
				type_name  = type_name,
				priority   = priority,
				proc_name  = decl.name,
				source_pkg = decl.pkg.name,
				source_path = decl.pkg_path,
			})
		}
	}
	return true
}

_OUT_DIR :: "haati/engine/serialization"

_SerializationRow :: struct {
	kind:        SerializationCallbackKind,
	type_name:   string,
	priority:    int,
	proc_name:   string,
	source_pkg:  string,
	source_path: string,
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]_SerializationRow
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_serializations := db.get_comps(w, Serialization_GenComp)
	m := db.all_of(db.r(decls), db.r(_serializations)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		ser := db.get(_serializations, entity)
		append(&entries, _SerializationRow{
			kind       = ser.kind,
			type_name  = ser.type_name,
			priority   = ser.priority,
			proc_name  = ser.proc_name,
			source_pkg = ser.source_pkg,
			source_path = ser.source_path,
		})
	}

	// Preserve previous collect_finalize ordering: sort by (kind, priority).
	// Total order — see property_drawer_gen: ties on (kind, priority) would
	// otherwise emit in entity iteration order and churn between builds.
	slice.sort_by(entries[:], proc(a, b: _SerializationRow) -> bool {
		if a.kind != b.kind do return a.kind < b.kind
		if a.priority != b.priority do return a.priority < b.priority
		if a.type_name != b.type_name do return a.type_name < b.type_name
		return a.proc_name < b.proc_name
	})

	pkg_name := "serialization"

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	imports := gen_facts.import_set_make(pkg_name, _OUT_DIR)
	defer gen_facts.import_set_destroy(&imports)
	for e in entries {
		gen_facts.import_set_add_type_and_source(&imports, e.type_name, e.source_pkg, e.source_path)
	}
	gen_facts.write_gen_header(&b, &imports, {pkg_name = pkg_name, gen_name = "serialization_gen"})
	strings.write_string(&b, "init_serialization_callbacks :: proc() {\n")

	for e in entries {
		rhs := gen_facts.qualified_ident(pkg_name, e.source_pkg, e.proc_name)
		switch e.kind {
		case .BeforeSerialize:
			fmt.sbprintf(&b, "\tmapBeforeSerialize[typeid_of(%s)] = %s\n", e.type_name, rhs)
		case .AfterDeserialize:
			fmt.sbprintf(&b, "\tmapAfterDeserialize[typeid_of(%s)] = %s\n", e.type_name, rhs)
		}
	}

	strings.write_string(&b, "}\n")

	db.emit(w, "haati/engine/serialization/serialization_generated.odin", strings.to_string(b))
	return true
}
