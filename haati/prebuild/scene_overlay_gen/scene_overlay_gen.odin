package scene_overlay_gen

// scene_overlay_gen: ECS prebuild module for scene_overlays_generated.odin.
//
//   provide  - query {DeclInfo, Proc}, recognise procs carrying a
//              @(scene_overlay={id="...", order=N}) attribute, tag each with
//              a Overlay_GenComp.
//   generate - query {DeclInfo, Overlay_GenComp}, sort by (order, id, name),
//              dedupe, build scene_overlays_generated.odin registering every
//              item into the editor's dockable overlays (dock.odin).
//
// The proc draws imgui items (signature `proc(vertical: bool)`). Items with the
// same id share one overlay; order sorts items inside it and — via the first
// item registered — the overlay's default stacking position in its dock zone.

import "core:fmt"
import "core:strings"
import "core:slice"
import db "../gen_db"
import "../gen_facts"

_PKG_NAME :: "editor"

OverlayEntry :: struct {
	id:          string,
	name:        string,
	order:       int,
	source_pkg:  string,
	source_path: string,
	// Where the item was declared, rendered by gen_facts.attr_origin. Emitted
	// into the registration call and shown in the item's tooltip with debug tooltips on.
	origin:      string,
}

Overlay_GenComp :: struct {
	entries: [dynamic]OverlayEntry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("scene_overlay/provide", provide)
	db.generator("scene_overlay/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	_overlays := db.get_or_create_comps(w, Overlay_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)

		entries: [dynamic]OverlayEntry
		for args in attr_set.attrs {
			if args.key != "scene_overlay" do continue
			id := args.fields["id"]
			if id == "" do continue
			append(&entries, OverlayEntry{
				id          = id,
				name        = decl.name,
				order       = gen_facts.attr_int(args, "order"),
				source_pkg  = decl.pkg.name,
				source_path = decl.pkg_path,
				origin      = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
			})
		}

		if len(entries) > 0 {
			db.set(_overlays, entity, Overlay_GenComp{entries = entries})
		} else {
			delete(entries)
		}
	}
	return true
}

// _qualified_name and _relative_import_path replaced by gen_facts helpers.

generate :: proc(w: ^db.World) -> bool {
	out_dir :: "haati/editor"

	entries: [dynamic]OverlayEntry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_overlays := db.get_comps(w, Overlay_GenComp)
	m := db.all_of(db.r(decls), db.r(_overlays)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		tb := db.get(_overlays, entity)
		for entry in tb.entries {
			append(&entries, entry)
		}
	}

	// (order, id, name): items sort inside their overlay by order; the first
	// emitted item of an id creates the overlay, so overlays stack in their
	// dock zone by lowest item order.
	slice.sort_by(entries[:], proc(a, b: OverlayEntry) -> bool {
		if a.order != b.order do return a.order < b.order
		if a.id != b.id do return a.id < b.id
		return a.name < b.name
	})

	i := 0
	for j in 0 ..< len(entries) {
		if j > 0 && entries[j].id == entries[j - 1].id && entries[j].name == entries[j - 1].name {
			continue
		}
		entries[i] = entries[j]
		i += 1
	}
	resize(&entries, i)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Explicit alias: qualified calls use the package NAME, which for editor
	// subpackages differs from the import path's last segment ("editor").
	imports := gen_facts.import_set_make(_PKG_NAME, out_dir)
	defer gen_facts.import_set_destroy(&imports)
	for e in entries {
		gen_facts.import_set_add(&imports, e.source_pkg, e.source_path)
	}
	gen_facts.write_gen_header(&b, &imports, {pkg_name = _PKG_NAME, gen_name = "scene_overlay_gen"})
	strings.write_string(&b, "_register_scene_overlays :: proc() {\n")
	for e in entries {
		fmt.sbprintf(&b, "\toverlay_add_item(\"%s\", %s, %d, origin = %q)\n",
			e.id, gen_facts.qualified_ident(_PKG_NAME, e.source_pkg, e.name), e.order, e.origin)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "haati/editor/scene_overlays_generated.odin", strings.to_string(b))
	return true
}
