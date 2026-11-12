package editor_visuals

// Editor Visuals & Accessibility Plugin for MoonHug.
// Provides global/per-window font scaling, Ctrl + Mouse Wheel zoom,
// and Unreal Engine / Godot style folder color marking.

import "core:strings"

Editor_Visuals_Settings :: struct {
	enable_ctrl_scroll_zoom: bool,
	enable_folder_colors:    bool,
	outline_color:           [4]f32,
	outline_scale:           f32,
	outline_thickness:       f32,
	outline_cross_size:      f32,
}

@(project_settings={name="Editor Visuals"})
settings := Editor_Visuals_Settings{
	enable_ctrl_scroll_zoom = true,
	enable_folder_colors    = true,
	outline_color           = {1.0, 0.60, 0.10, 1.0},
	outline_scale           = 1.02,
	outline_thickness       = 1.0,
	outline_cross_size      = 0.8,
}

get_outline_color :: proc() -> [4]f32 {
	if settings.outline_color.a <= 0.01 do return {1.0, 0.60, 0.10, 1.0}
	return settings.outline_color
}

get_outline_scale :: proc() -> f32 {
	if settings.outline_scale <= 0.01 do return 1.02
	return settings.outline_scale
}

get_outline_thickness :: proc() -> f32 {
	if settings.outline_thickness <= 0.01 do return 1.0
	return settings.outline_thickness
}

get_outline_cross_size :: proc() -> f32 {
	if settings.outline_cross_size <= 0.01 do return 0.8
	return settings.outline_cross_size
}

Folder_Color_Entry :: struct {
	folder_key: string,
	color:      [4]f32,
}

@(private = "file")
_folder_colors: [dynamic]Folder_Color_Entry

@(private = "file")
_initialized: bool = false

_ensure_initialized :: proc() {
	if _initialized do return
	_initialized = true

	// Default Unreal/Godot-style folder color markings
	set_folder_color("void_odin",     {0.75, 0.45, 1.0, 1.0})  // Royal Purple (Our Game)
	set_folder_color("physics3d",     {0.20, 0.85, 0.95, 1.0}) // Cyan (Jolt Physics)
	set_folder_color("input_manager", {0.30, 0.92, 0.50, 1.0}) // Emerald Green (Input)
	set_folder_color("control_rig",   {1.00, 0.60, 0.20, 1.0}) // Amber Orange (Control Rig)
	set_folder_color("assets",        {0.95, 0.85, 0.30, 1.0}) // Goldenrod
	set_folder_color("skeletons",     {0.90, 0.40, 0.55, 1.0}) // Rose
	set_folder_color("scenes",        {0.35, 0.65, 1.0, 1.0})  // Sapphire Blue
	set_folder_color("editor",        {0.55, 0.70, 0.85, 1.0}) // Slate
}

get_folder_color :: proc(path: string) -> (col: [4]f32, found: bool) {
	_ensure_initialized()
	if !settings.enable_folder_colors do return {}, false

	for entry in _folder_colors {
		if strings.contains(path, entry.folder_key) {
			return entry.color, true
		}
	}
	return {}, false
}

set_folder_color :: proc(folder_key: string, col: [4]f32) {
	_ensure_initialized()
	for &entry in _folder_colors {
		if entry.folder_key == folder_key {
			entry.color = col
			return
		}
	}
	append(&_folder_colors, Folder_Color_Entry{
		folder_key = strings.clone(folder_key),
		color = col,
	})
}

clear_folder_color :: proc(folder_key: string) {
	_ensure_initialized()
	for i in 0 ..< len(_folder_colors) {
		if _folder_colors[i].folder_key == folder_key {
			delete(_folder_colors[i].folder_key)
			ordered_remove(&_folder_colors, i)
			return
		}
	}
}

get_all_folder_colors :: proc() -> []Folder_Color_Entry {
	_ensure_initialized()
	return _folder_colors[:]
}

// Bundled high-compatibility TrueType font for plugins and editor widgets
SEGOE_UI_TTF_DATA := #load("assets/fonts/segoeui.ttf")

get_shared_font_data :: proc() -> []byte {
	return SEGOE_UI_TTF_DATA
}

get_shared_font_name :: proc() -> string {
	return "Segoe UI"
}
