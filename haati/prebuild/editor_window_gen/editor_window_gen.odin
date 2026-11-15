package editor_window_gen

// editor_window_gen: plugin-declared editor windows (docs/Plugins.md).
//
//   @(editor_window={id="physics2d", title="Physics 2D", width=420, height=240})
//   draw_physics_debug :: proc() { ... }   // window CONTENT only
//
//   generate - moonhug/editor/editor_windows_generated.odin:
//              _register_editor_windows(), one window.register call per
//              declaration. Windows open by id (window.open), usually from a
//              @(menu_item) proc.
//
// width/height are the first-shown size, applied only when imgui.ini has no
// entry for the title yet. title defaults to the id.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

_PKG_NAME :: "editor"

WindowEntry :: struct {
	id:          string,
	title:       string,
	icon:        string, // icons.ICON_MD_<icon>; EXTENSION when the attribute has none
	name:        string, // draw proc
	width:       int,
	height:      int,
	source_pkg:  string,
	source_path: string,
	// Where the window was declared, rendered by gen_facts.attr_origin.
	// Emitted into the registration and shown on the tab's menu button in help
	// mode.
	origin:      string,
}

Window_GenComp :: struct {
	entries: [dynamic]WindowEntry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("editor_window/provide", provide)
	db.generator("editor_window/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	_windows := db.get_or_create_comps(w, Window_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)

		entries: [dynamic]WindowEntry
		for args in attr_set.attrs {
			if args.key != "editor_window" do continue
			id := args.fields["id"]
			if id == "" {
				fmt.eprintf("editor_window: %s.%s needs id=\"...\"\n", decl.pkg.name, decl.name)
				continue
			}
			title := args.fields["title"]
			if title == "" do title = id
			icon := args.fields["icon"]
			if icon == "" do icon = "EXTENSION"
			append(&entries, WindowEntry{
				id          = id,
				title       = title,
				icon        = icon,
				name        = decl.name,
				width       = gen_facts.attr_int(args, "width"),
				height      = gen_facts.attr_int(args, "height"),
				source_pkg  = decl.pkg.name,
				source_path = decl.pkg_path,
				origin      = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
			})
		}

		if len(entries) > 0 {
			db.set(_windows, entity, Window_GenComp{entries = entries})
		} else {
			delete(entries)
		}
	}
	return true
}

generate :: proc(w: ^db.World) -> bool {
	out_dir :: "haati/editor"

	entries: [dynamic]WindowEntry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_windows := db.get_comps(w, Window_GenComp)
	m := db.all_of(db.r(decls), db.r(_windows)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		tb := db.get(_windows, entity)
		for entry in tb.entries {
			append(&entries, entry)
		}
	}

	slice.sort_by(entries[:], proc(a, b: WindowEntry) -> bool {
		if a.id != b.id do return a.id < b.id
		return a.name < b.name
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	imports := gen_facts.import_set_make(_PKG_NAME, out_dir)
	defer gen_facts.import_set_destroy(&imports)
	for e in entries {
		gen_facts.import_set_add(&imports, e.source_pkg, e.source_path)
	}
	preamble := [?]gen_facts.Import_Entry{
		{alias = "__wnd", path = "haati:editor/window"},
		{alias = "__icons", path = "haati:editor/icons"},
	}
	gen_facts.write_gen_header(&b, &imports, {
		pkg_name         = "editor",
		gen_name         = "editor_window_gen",
		preamble_imports = preamble[:],
	})
	strings.write_string(&b, "_register_editor_windows :: proc() {\n")
	for e in entries {
		fmt.sbprintf(&b, "\t__wnd.register(%q, %q, __icons.ICON_MD_%s, %s, %d, %d, origin = %q)\n",
			e.id, e.title, e.icon, gen_facts.qualified_ident(_PKG_NAME, e.source_pkg, e.name), e.width, e.height, e.origin)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "haati/editor/editor_windows_generated.odin", strings.to_string(b))
	return true
}
