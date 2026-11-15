package user_settings_gen

// user_settings_gen: per-developer preferences (engine/user_settings.odin).
//
//   @(user_settings={name="Animation"})
//   anim_view_prefs := Anim_View_Prefs{ends_on_last_frame = false}
//
// The attribute sits on a package-level VAR — the data is the registration,
// the same shape project_settings_gen uses. A plugin keeps a preference
// without the editor's own settings struct having a field for it.
//
// No settings TAB: these are not project configuration, so they do not belong
// in a window every developer shares. A view puts its own preferences in its
// menu (@(view_menu)).
//
//   generate - moonhug/editor/user_settings_generated.odin:
//              _load_user_settings() and _save_user_settings(), one call per
//              declaration.

import "core:fmt"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

@(init)
_register :: proc "contextless" () {
	db.generator("user_settings/generate", generate)
}

generate :: proc(w: ^db.World) -> bool {
	out_dir :: "haati/editor"

	entries := gen_facts.collect_settings_entries(w, "user_settings", include_origin = false)
	defer delete(entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// No entries means no __engine.user_settings_* calls, so omit __engine import.
	gen_facts.emit_settings_header(&b, out_dir, "user_settings_gen", entries[:], always_import_engine = false)
	strings.write_string(&b, "_load_user_settings :: proc() {\n")
	for e in entries {
		fmt.sbprintf(&b, "\t__engine.user_settings_load(%q, &%s)\n", e.tab_name, gen_facts.qualified_ident("editor", e.source_pkg, e.name))
	}
	strings.write_string(&b, "}\n\n")
	strings.write_string(&b, "_save_user_settings :: proc() {\n")
	for e in entries {
		q := gen_facts.qualified_ident("editor", e.source_pkg, e.name)
		fmt.sbprintf(&b, "\t__engine.user_settings_save(%q, &%s, typeid_of(type_of(%s)))\n", e.tab_name, q, q)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "haati/editor/user_settings_generated.odin", strings.to_string(b))
	return true
}
