package engine

// Per-developer settings persistence, the UserSettings half of
// project_settings.odin.
//
// A user setting is a package-level var marked @(user_settings={name="..."}):
//
//   @(user_settings={name="Animation"})
//   anim_view_prefs := Anim_View_Prefs{ends_on_last_frame = false}
//
// The generator loads every marked var at editor start and saves them at
// shutdown, so a plugin keeps a preference without the editor's own settings
// struct having a field for it.
//
// WHICH ONE TO USE:
//
// - @(project_settings) is about the PROJECT. Committed, shared by everyone on
//   the checkout, and the game binary reads the same file. Physics gravity.
// - @(user_settings) is about the PERSON. Never committed, editor only. Where
//   your playhead stops, which panel you left open.
//
// Putting a personal preference in ProjectSettings commits it and hands it to
// the game, which is the wrong file and the wrong reader.
//
// The editor's own window geometry and panel flags stay in EditorSettings
// (editor/window.odin): one struct, one file, hand-copied fields. That is
// older than this and not worth churning — but nothing new needs to go there.

// Never committed: .gitignore covers the directory, the same as Unity's
// UserSettings. Editor/window.odin writes its own file in here too.
USER_SETTINGS_DIR :: "UserSettings"

// "Animation" -> "UserSettings/animation.json". Temp-allocated.
user_settings_file :: proc(name: string) -> string {
    return _settings_file_in(USER_SETTINGS_DIR, name)
}

// Reads the file into the settings struct. A missing or unreadable file leaves
// the struct as-is — its var initializer is the default — so a fresh checkout,
// a deleted UserSettings/ and a first run all behave the same.
user_settings_load :: proc(name: string, v: ^$T) -> bool {
    return _settings_load_in(USER_SETTINGS_DIR, name, v)
}

user_settings_save :: proc(name: string, ptr: rawptr, tid: typeid) -> bool {
    return _settings_save_in(USER_SETTINGS_DIR, name, ptr, tid)
}
