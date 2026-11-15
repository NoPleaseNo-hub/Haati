package project_settings_gen

// project_settings_gen: settings tabs for the editor's Project Settings
// window (docs/Plugins.md "Project settings").
//
//   @(project_settings={name="Physics 2D"})
//   physics2d_settings := Physics2D_Settings{gravity = GRAVITY_DEFAULT}
//
// The attribute sits on a package-level VAR — the data is the registration.
// The window draws it through the inspector, undo and persistence ride the
// struct, and the owning system consumes the var by polling.
//
//   generate - moonhug/editor/project_settings_generated.odin:
//              _register_project_settings(), one settings_add_tab call per
//              declaration.

import "core:fmt"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

@(init)
_register :: proc "contextless" () {
	db.generator("project_settings/generate", generate)
}

generate :: proc(w: ^db.World) -> bool {
	out_dir :: "haati/editor"

	entries := gen_facts.collect_settings_entries(w, "project_settings", include_origin = true)
	defer delete(entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Always import __engine alias so settings owned by engine don't collide with engine package import.
	gen_facts.emit_settings_header(&b, out_dir, "project_settings_gen", entries[:], always_import_engine = true)
	strings.write_string(&b, "_register_project_settings :: proc() {\n")
	for e in entries {
		q := gen_facts.qualified_ident("editor", e.source_pkg, e.name)
		fmt.sbprintf(&b, "\t__engine.project_settings_load(%q, &%s)\n", e.tab_name, q)
		fmt.sbprintf(&b, "\tsettings_add_tab(%q, &%s, typeid_of(type_of(%s)), origin = %q)\n", e.tab_name, q, q, e.origin)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "haati/editor/project_settings_generated.odin", strings.to_string(b))
	return true
}
