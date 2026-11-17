package menu

import im "haati:external/odin-imgui"
import "../inspector"
import "haati:engine"
import "haati:engine_editor/asset_pipeline"
import "haati:editor/icons"
import thm "haati:editor/theme"
import wnd "haati:editor/window"

Theme :: thm.Theme_Id

active_theme: Theme = .Antigravity_Dark

apply_theme :: proc() {
	active_theme = thm.active()
	thm.apply()
}

set_theme :: proc(t: Theme) {
	active_theme = t
	thm.set(t)
}

quit_requested := false

// Window menu, Unity's layout: General holds the everyday views in Unity's
// order, domain submenus (Animation) follow. The undo History view lives
// under Edit, right below Undo/Redo (Unity's Edit > Undo History).
//
// Entries are OPEN commands, not toggles (Unity): selecting one shows the
// view and fronts its dock tab. Windows close from the tab's X button,
// which writes the same show_* flag through Begin's p_open pointer.
// Shortcuts match Unity (Ctrl+1..6 = Cmd+1..6 on macOS): Scene, Game,
// Inspector, Hierarchy, Project, Animation, and Cmd+Shift+C for Console.

show_scene := true
show_scene_2d := true
show_game := true
show_console := true
show_output := true
show_history := false
show_animation := false
show_playable_graph := false

@(private = "file")
_open_window :: proc(show: ^bool, title: cstring) {
	show^ = true
	im.SetWindowFocusStr(title)
}

// The open flag behind a built-in view's window title, so the tab menu can
// close the tab it is opened on. Plugin windows keep their own list
// (window/window.odin), so this returns nil for them.
view_show_flag :: proc(title: cstring) -> ^bool {
	switch title {
	case icons.TITLE_SCENE, icons.ICON_MD_LANDSCAPE + " Scene3D *###Scene": return &show_scene
	case icons.TITLE_SCENE_2D:          return &show_scene_2d
	case icons.TITLE_GAME:              return &show_game
	case icons.TITLE_CONSOLE:           return &show_console
	case icons.TITLE_OUTPUT:            return &show_output
	case icons.TITLE_HISTORY:           return &show_history
	case icons.TITLE_ANIMATION:         return &show_animation
	case icons.TITLE_PLAYABLE_GRAPH:    return &show_playable_graph
	}
	return nil
}

// Note: Originally "Window/General/Scene"; renamed to "Window/General/Scene3D".
@(menu_item={path="Window/General/Scene3D", order=0, shortcut="Ctrl+1"})
window_menu_scene :: proc() { _open_window(&show_scene, icons.TITLE_SCENE) }

@(menu_item={path="Window/General/Scene 2D", order=1, shortcut="Ctrl+Shift+2"})
window_menu_scene_2d :: proc() { _open_window(&show_scene_2d, icons.TITLE_SCENE_2D) }

@(menu_item={path="Window/General/Game", order=2, shortcut="Ctrl+2"})
window_menu_game :: proc() { _open_window(&show_game, icons.TITLE_GAME) }

@(menu_item={path="Window/General/Void Inspector", order=2, shortcut="Ctrl+3"})
window_menu_inspector :: proc() { wnd.open("void_inspector") }

@(menu_item={path="Window/General/Void Hierarchy", order=4, shortcut="Ctrl+4"})
window_menu_hierarchy :: proc() { wnd.open("void_hierarchy") }

@(menu_item={path="Window/General/Void File Explorer", order=5, shortcut="Ctrl+5"})
window_menu_project :: proc() { wnd.open("void_file_explorer") }

@(menu_item={path="Window/General/Console", order=7, shortcut="Ctrl+Shift+C"})
window_menu_console :: proc() { _open_window(&show_console, icons.TITLE_CONSOLE) }

@(menu_item={path="Window/General/Output", order=8, shortcut=""})
window_menu_output :: proc() { _open_window(&show_output, icons.TITLE_OUTPUT) }

@(menu_item={path="Edit/Undo History", order=-98, shortcut=""})
window_menu_history :: proc() { _open_window(&show_history, icons.TITLE_HISTORY) }

@(menu_item={path="Window/Animation/Animation", order=0, shortcut="Ctrl+6"})
window_menu_animation :: proc() { _open_window(&show_animation, icons.TITLE_ANIMATION) }

@(menu_item={path="Window/Animation/Playable Graph", order=1, shortcut=""})
window_menu_playable_graph :: proc() { _open_window(&show_playable_graph, icons.TITLE_PLAYABLE_GRAPH) }

@(menu_item={path="File/Save", order=0, shortcut="Ctrl+S"})
file_save_menu :: proc() {
	// Everything pending: the open document, every other dirty asset
	// document, and every loaded scene edited since its last save. One
	// shortcut, no per-view Save buttons.
	inspector.save_to_file()
	sm := engine.ctx_scene_manager()
	if sm == nil do return
	for i in 0 ..< sm.count {
		scene := sm.loaded[i]
		if scene == nil || !scene.dirty || len(scene.path) == 0 do continue
		engine.scene_save(scene, scene.path)
	}
}

@(menu_separator={path="File", order=5})
file_separator_menu :: proc() {}

@(menu_separator={path="Window", order=-7})
file_separator_menu2 :: proc() {}

@(menu_item={path="File/Quit", order=10, shortcut="Alt+F4"})
file_quit_menu :: proc() { quit_requested = true }

@(menu_item={path="Tools/Refresh AssetDB", order=20, shortcut=""})
refresh_asset_db_menu :: proc() {
	asset_pipeline.asset_db_refresh()
}

show_about := false

@(menu_item={path="Help/About", order=1000, shortcut=""})
help_about_menu :: proc() {
	show_about = true
}

// Diagnostics for the "keyboard input dies until restart" bug — see
// editor/view_input_debug.odin. Mouse-only operable on purpose.
@(menu_item={path="Help/Input Debug", order=999})
show_input_debug := false

// ─────────────────────────────────────────────────────────────────────────────
// Window / Theme Radio Group (Antigravity Clean Studio Presets)
// ─────────────────────────────────────────────────────────────────────────────

@(menu_item={path="Window/Theme/Antigravity Dark (Default)", order=-20, shortcut="", checked=theme_is_antigravity_dark})
menu_item_view_theme_antigravity_dark :: proc() { set_theme(.Antigravity_Dark) }
theme_is_antigravity_dark :: proc() -> bool { return thm.active() == .Antigravity_Dark }

@(menu_item={path="Window/Theme/Antigravity Light", order=-19, shortcut="", checked=theme_is_antigravity_light})
menu_item_view_theme_antigravity_light :: proc() { set_theme(.Antigravity_Light) }
theme_is_antigravity_light :: proc() -> bool { return thm.active() == .Antigravity_Light }

@(menu_item={path="Window/Theme/Antigravity Midnight (OLED)", order=-18, shortcut="", checked=theme_is_antigravity_midnight})
menu_item_view_theme_antigravity_midnight :: proc() { set_theme(.Antigravity_Midnight) }
theme_is_antigravity_midnight :: proc() -> bool { return thm.active() == .Antigravity_Midnight }

@(menu_separator={path="Window/Theme", order=-17})
theme_separator_studio :: proc() {}

@(menu_item={path="Window/Theme/Void Obsidian", order=-16, shortcut="", checked=theme_is_void_obsidian})
menu_item_view_theme_void_obsidian :: proc() { set_theme(.Void_Obsidian) }
theme_is_void_obsidian :: proc() -> bool { return thm.active() == .Void_Obsidian }

@(menu_item={path="Window/Theme/Nordic Slate", order=-15, shortcut="", checked=theme_is_nordic_slate})
menu_item_view_theme_nordic_slate :: proc() { set_theme(.Nordic_Slate) }
theme_is_nordic_slate :: proc() -> bool { return thm.active() == .Nordic_Slate }

@(menu_item={path="Window/Theme/Spectrum Neutral", order=-14, shortcut="", checked=theme_is_spectrum_neutral})
menu_item_view_theme_spectrum_neutral :: proc() { set_theme(.Spectrum_Neutral) }
theme_is_spectrum_neutral :: proc() -> bool { return thm.active() == .Spectrum_Neutral }

@(menu_item={path="Window/Theme/Catppuccin Mocha", order=-13, shortcut="", checked=theme_is_catppuccin_mocha})
menu_item_view_theme_catppuccin_mocha :: proc() { set_theme(.Catppuccin_Mocha) }
theme_is_catppuccin_mocha :: proc() -> bool { return thm.active() == .Catppuccin_Mocha }

@(menu_item={path="Window/Theme/Paper & Ink", order=-12, shortcut="", checked=theme_is_paper_and_ink})
menu_item_view_theme_paper_and_ink :: proc() { set_theme(.Paper_And_Ink) }
theme_is_paper_and_ink :: proc() -> bool { return thm.active() == .Paper_And_Ink }

@(menu_separator={path="Window/Theme", order=-5})
theme_separator_customize :: proc() {}

@(menu_item={path="Window/Theme/Customize Themes & Visuals...", order=-4, shortcut=""})
menu_item_customize_themes :: proc() {
	wnd.open("editor_visuals")
}
