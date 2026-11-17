package editor_visuals

// Editor Visuals & Accessibility module for Haati.
// Provides global/per-window font scaling, Ctrl + Mouse Wheel zoom,
// and Unreal Engine / Godot style folder color marking.

import "base:runtime"
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

External_IDE_Choice :: enum {
	Auto_Detect = 0,
	VS_Code,
	Cursor,
	Antigravity,
	Rider,
	Custom,
}

Graph_Wire_Style_Choice :: enum {
	Smooth_Bezier = 0,
	Electronic_45 = 1,
	Electric_Jagged = 2,
}

Editor_Appearance_Settings :: struct {
	ui_scale:                 f32  `decor:header("Display & Tooltips") decor:range(0.75, 1.75) decor:tooltip(desc="Global font & widget scale across editor panels.")`,
	tooltip_idle_delay_sec:   f32  `decor:range(0.10, 2.00) decor:tooltip(desc="Seconds the mouse must rest calmly before showing IDE/Graph hover tooltips.")`,
	keep_secondary_alive_min: bool `decor:header("Multi-Window & Frame Pacing") decor:tooltip(desc="Keep popped-out secondary OS windows live when the main editor window is minimized.")`,
	background_fps_cap:       int  `decor:range(15, 144) decor:tooltip(desc="Frame pacing cap (FPS) when minimized or unfocused.")`,
}

@(project_settings={name="Editor & Appearance"})
appearance_settings := Editor_Appearance_Settings{
	ui_scale                 = 1.00,
	tooltip_idle_delay_sec   = 0.55,
	keep_secondary_alive_min = true,
	background_fps_cap       = 60,
}

Code_IDE_Settings :: struct {
	prefer_external_ide:     bool                     `decor:header("External IDE") decor:tooltip(desc="Open .odin source files in an external IDE instead of the built-in Odin Micro-Studio (.bodin/.mhgraph still open in Blueprint Studio).")`,
	external_ide:            External_IDE_Choice      `decor:tooltip(desc="External IDE preset used for .odin files when Prefer External IDE is enabled or Open in External IDE is clicked.")`,
	custom_ide_executable:   string                   `decor:tooltip(desc="Custom external IDE executable path (used when External IDE is Custom, or as fallback).")`,
	ide_sandbox_mode:        bool                     `decor:header("Odin Micro-Studio & Sandbox") decor:tooltip(desc="Stage unsaved scripts into builds/sandbox_cartridge/ on F7 without touching disk files, and trap runtime panics/exceptions safely.")`,
	enable_crash_watchdog:   bool                     `decor:tooltip(desc="Keep an idle 0% CPU out-of-process Crash Watchdog Guardian & Kernel RAM Vault active to resurrect unsaved scene, camera, and dirty Code Studio tabs after a hard crash and quarantine the crashing script.")`,
	problem_check_delay_sec: f32                      `decor:range(0.25, 3.00) decor:tooltip(desc="Repeatable idle delay (seconds) after your last keystroke before checking code for errors/warnings.")`,
	ide_explorer_zoom:       f32                      `decor:header("Pane Zooms") decor:range(0.75, 2.00) decor:tooltip(desc="Independent zoom scale for the Micro-Studio Explorer/Structure pane.")`,
	ide_code_zoom:           f32                      `decor:range(0.75, 2.40) decor:tooltip(desc="Independent zoom scale for the Micro-Studio code editor surface.")`,
	ide_problems_zoom:       f32                      `decor:range(0.75, 2.00) decor:tooltip(desc="Independent zoom scale for the Micro-Studio Problems & Output dock.")`,
	ide_show_breadcrumbs:    bool                     `decor:header("Blueprint & Graph Studio") decor:tooltip(desc="Show file > proc/struct breadcrumb scope bar above the code editor.")`,
	ide_show_error_lens:     bool                     `decor:tooltip(desc="Show inline diagnostic text next to lines once idle problem check finishes.")`,
	graph_wire_style:        Graph_Wire_Style_Choice  `decor:tooltip(desc="Default global wire routing style across Blueprint, Motion, VFX, and Audio graph studios.")`,
	graph_auto_bake_on_save: bool                     `decor:tooltip(desc="Automatically transpile/bake .bodin native Odin code when saving a Blueprint graph.")`,
}

@(project_settings={name="Code & Script IDE"})
code_ide_settings := Code_IDE_Settings{
	prefer_external_ide     = false,
	external_ide            = .Auto_Detect,
	custom_ide_executable   = "",
	ide_sandbox_mode        = true,
	enable_crash_watchdog   = true,
	problem_check_delay_sec = 0.90,
	ide_explorer_zoom       = 1.00,
	ide_code_zoom           = 1.00,
	ide_problems_zoom       = 1.00,
	ide_show_breadcrumbs    = true,
	ide_show_error_lens     = true,
	graph_wire_style        = .Electronic_45,
	graph_auto_bake_on_save = true,
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
	_folder_colors = make([dynamic]Folder_Color_Entry, runtime.default_allocator())

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
		folder_key = strings.clone(folder_key, runtime.default_allocator()),
		color = col,
	})
}

clear_folder_color :: proc(folder_key: string) {
	_ensure_initialized()
	for i in 0 ..< len(_folder_colors) {
		if _folder_colors[i].folder_key == folder_key {
			delete(_folder_colors[i].folder_key, runtime.default_allocator())
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
