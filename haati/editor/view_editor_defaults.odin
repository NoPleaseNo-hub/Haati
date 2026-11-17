package editor

// =============================================================================
// EDITOR DEFAULTS SYNC & LEGACY MIGRATION (`view_editor_defaults.odin`)
// =============================================================================
// Bridges the unified `@(project_settings)` structs in `editor_visuals`
// ("Editor & Appearance" and "Code & Script IDE") to live editor subsystems
// (UI scale, tooltip delay, Micro-Studio zooms/problem delay, Graph Studio
// wire style/auto-bake, and External IDE preset/path), and performs one-time
// migration from legacy `UserSettings/editor_defaults.json`.

import "core:encoding/json"
import "core:math"
import "core:os"
import "core:strings"
import cs "haati:editor/code_studio"
import editor_visuals "editor_visuals"
import file_explorer "file_explorer"
import nc "haati:editor/node_canvas"
import vs "haati:editor/visual_script"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import "../engine"

Editor_Defaults_Data :: struct {
	ui_scale:                  f32,
	tooltip_idle_delay_sec:    f32,
	ide_explorer_zoom:         f32,
	ide_code_zoom:             f32,
	ide_problems_zoom:         f32,
	ide_show_breadcrumbs:      bool,
	ide_show_error_lens:       bool,
	graph_electronic_wires:    bool,
	graph_wire_style:          i32, // 0 = Smooth Bezier, 1 = Electronic 45°, 2 = Electric Jagged
	graph_wire_style_v2_set:   bool,
	graph_auto_bake_on_save:   bool,
	keep_secondary_alive_min:  bool,
	background_fps_cap:        i32,
}

EDITOR_DEFAULTS_PATH :: "UserSettings/editor_defaults.json"

editor_defaults := Editor_Defaults_Data{
	ui_scale                 = 1.00,
	tooltip_idle_delay_sec   = 0.55,
	ide_explorer_zoom        = 1.00,
	ide_code_zoom            = 1.00,
	ide_problems_zoom        = 1.00,
	ide_show_breadcrumbs     = true,
	ide_show_error_lens      = true,
	graph_electronic_wires   = true,
	graph_wire_style         = 1,
	graph_wire_style_v2_set  = true,
	graph_auto_bake_on_save  = true,
	keep_secondary_alive_min = true,
	background_fps_cap       = 60,
}

editor_defaults_reset_struct :: proc(d: ^Editor_Defaults_Data) {
	d^ = Editor_Defaults_Data{
		ui_scale                 = 1.00,
		tooltip_idle_delay_sec   = 0.55,
		ide_explorer_zoom        = 1.00,
		ide_code_zoom            = 1.00,
		ide_problems_zoom        = 1.00,
		ide_show_breadcrumbs     = true,
		ide_show_error_lens      = true,
		graph_electronic_wires   = true,
		graph_wire_style         = 1,
		graph_wire_style_v2_set  = true,
		graph_auto_bake_on_save  = true,
		keep_secondary_alive_min = true,
		background_fps_cap       = 60,
	}
}

@(private = "file")
_on_ide_sandbox_toggled :: proc(enabled: bool) {
	editor_visuals.code_ide_settings.ide_sandbox_mode = enabled
	_ = engine.project_settings_save(
		"Code & Script IDE",
		&editor_visuals.code_ide_settings,
		typeid_of(editor_visuals.Code_IDE_Settings),
	)
}

@(private = "file")
_on_global_wire_style_changed :: proc(style: nc.Canvas_Wire_Style) {
	editor_visuals.code_ide_settings.graph_wire_style = editor_visuals.Graph_Wire_Style_Choice(clamp(int(style), 0, 2))
	editor_defaults_sync_from_settings(false)
	_ = engine.project_settings_save(
		"Code & Script IDE",
		&editor_visuals.code_ide_settings,
		typeid_of(editor_visuals.Code_IDE_Settings),
	)
}

// One-time migration from legacy `UserSettings/editor_defaults.json` into
// `UserSettings/EngineSettings/{editor_&_appearance,code_&_script_ide}.json`.
// Runs BEFORE `_register_project_settings()` and writes local structs to disk
// without mutating `editor_visuals.*` in memory, so Tier 1 Factory Defaults
// Backdrop captures true compiled defaults.
editor_defaults_migrate_legacy :: proc() {
	eng_dir := engine.engine_settings_dir(context.temp_allocator)
	app_slug := engine.project_settings_slug("Editor & Appearance", context.temp_allocator)
	ide_slug := engine.project_settings_slug("Code & Script IDE", context.temp_allocator)
	app_path := strings.concatenate({eng_dir, "/", app_slug, ".json"}, context.temp_allocator)
	ide_path := strings.concatenate({eng_dir, "/", ide_slug, ".json"}, context.temp_allocator)
	if os.exists(app_path) || os.exists(ide_path) do return

	candidates := [3]string{
		engine.engine_file_path(EDITOR_DEFAULTS_PATH, context.temp_allocator),
		EDITOR_DEFAULTS_PATH,
		engine.has_active_project() ? engine.engine_file_path("haati/" + EDITOR_DEFAULTS_PATH, context.temp_allocator) : "",
	}
	var_data: []byte
	for c in candidates {
		if c == "" do continue
		if d, err := os.read_entire_file(c, context.temp_allocator); err == nil && len(d) > 0 {
			var_data = d
			break
		}
	}
	if len(var_data) == 0 do return

	leg: Editor_Defaults_Data
	editor_defaults_reset_struct(&leg)
	if json.unmarshal(var_data, &leg, allocator = context.temp_allocator) != nil do return

	mig_app := editor_visuals.appearance_settings
	mig_app.ui_scale                 = math.clamp(leg.ui_scale, 0.75, 1.75)
	mig_app.tooltip_idle_delay_sec   = math.clamp(leg.tooltip_idle_delay_sec, 0.10, 2.00)
	mig_app.keep_secondary_alive_min = leg.keep_secondary_alive_min
	mig_app.background_fps_cap       = clamp(int(leg.background_fps_cap), 15, 144)

	ws := leg.graph_wire_style_v2_set ? clamp(int(leg.graph_wire_style), 0, 2) : (leg.graph_electronic_wires ? 1 : 0)
	mig_ide := editor_visuals.code_ide_settings
	mig_ide.ide_explorer_zoom       = math.clamp(leg.ide_explorer_zoom, 0.75, 2.00)
	mig_ide.ide_code_zoom           = math.clamp(leg.ide_code_zoom, 0.75, 2.40)
	mig_ide.ide_problems_zoom       = math.clamp(leg.ide_problems_zoom, 0.75, 2.00)
	mig_ide.ide_show_breadcrumbs    = leg.ide_show_breadcrumbs
	mig_ide.ide_show_error_lens     = leg.ide_show_error_lens
	mig_ide.graph_wire_style        = editor_visuals.Graph_Wire_Style_Choice(ws)
	mig_ide.graph_auto_bake_on_save = leg.graph_auto_bake_on_save

	_ = os.make_directory_all(eng_dir)
	opts := json.Marshal_Options{spec = .JSON, pretty = true, use_spaces = true, spaces = 2}
	if ab, aerr := json.marshal(mig_app, opts, context.temp_allocator); aerr == nil && !os.exists(app_path) {
		_ = os.write_entire_file(app_path, ab)
	}
	if ib, ierr := json.marshal(mig_ide, opts, context.temp_allocator); ierr == nil && !os.exists(ide_path) {
		_ = os.write_entire_file(ide_path, ib)
	}
}

editor_defaults_sync_from_settings :: proc(sync_ide_panes := false) {
	app := &editor_visuals.appearance_settings
	app.ui_scale               = math.clamp(app.ui_scale, 0.75, 1.75)
	app.tooltip_idle_delay_sec = math.clamp(app.tooltip_idle_delay_sec, 0.10, 2.00)
	app.background_fps_cap     = clamp(app.background_fps_cap, 15, 144)

	ide := &editor_visuals.code_ide_settings
	ide.problem_check_delay_sec = math.clamp(ide.problem_check_delay_sec, 0.25, 3.00)
	ide.ide_explorer_zoom       = math.clamp(ide.ide_explorer_zoom, 0.75, 2.00)
	ide.ide_code_zoom           = math.clamp(ide.ide_code_zoom, 0.75, 2.40)
	ide.ide_problems_zoom       = math.clamp(ide.ide_problems_zoom, 0.75, 2.00)

	editor_defaults.ui_scale                 = app.ui_scale
	editor_defaults.tooltip_idle_delay_sec   = app.tooltip_idle_delay_sec
	editor_defaults.keep_secondary_alive_min = app.keep_secondary_alive_min
	editor_defaults.background_fps_cap       = i32(app.background_fps_cap)
	editor_defaults.ide_explorer_zoom        = ide.ide_explorer_zoom
	editor_defaults.ide_code_zoom            = ide.ide_code_zoom
	editor_defaults.ide_problems_zoom        = ide.ide_problems_zoom
	editor_defaults.ide_show_breadcrumbs     = ide.ide_show_breadcrumbs
	editor_defaults.ide_show_error_lens      = ide.ide_show_error_lens
	editor_defaults.graph_wire_style         = i32(ide.graph_wire_style)
	editor_defaults.graph_wire_style_v2_set  = true
	editor_defaults.graph_electronic_wires   = (ide.graph_wire_style == .Electronic_45)
	editor_defaults.graph_auto_bake_on_save  = ide.graph_auto_bake_on_save

	wnd.set_main_scale(app.ui_scale)
	widgets.tooltip_idle_delay_sec = app.tooltip_idle_delay_sec
	cs.configure_ide_defaults(
		ide.ide_explorer_zoom,
		ide.ide_code_zoom,
		ide.ide_problems_zoom,
		ide.ide_show_breadcrumbs,
		ide.ide_show_error_lens,
		sync_ide_panes,
		ide.problem_check_delay_sec,
	)
	cs.set_sandbox_mode(ide.ide_sandbox_mode)
	watchdog_set_enabled(ide.enable_crash_watchdog)
	nc.on_global_wire_style_changed = _on_global_wire_style_changed
	nc.set_global_wire_style(nc.Canvas_Wire_Style(ide.graph_wire_style), false)
	vs.configure_graph_studio_defaults(
		ide.graph_wire_style == .Electronic_45,
		ide.graph_auto_bake_on_save,
	)

	custom_exe := ide.custom_ide_executable
	if custom_exe == "" {
		custom_exe = file_explorer.settings.ide_executable
	} else {
		file_explorer.settings.ide_executable = custom_exe
	}
	file_explorer.set_external_ide_config(
		ide.prefer_external_ide,
		file_explorer.External_IDE_Preset(ide.external_ide),
		custom_exe,
	)
}

editor_defaults_init :: proc() {
	engine.register_pointer_type(editor_visuals.External_IDE_Choice)
	engine.register_pointer_type(editor_visuals.Graph_Wire_Style_Choice)
	cs.register_sandbox_toggle_hook(_on_ide_sandbox_toggled)
	editor_defaults_sync_from_settings(true)
}

editor_defaults_shutdown :: proc() {
	// Persistence is handled uniformly by `settings_save_all()`.
}

editor_defaults_background_delay_ms :: proc() -> u32 {
	cap := clamp(editor_defaults.background_fps_cap, 15, 240)
	ms := 1000 / cap
	return u32(clamp(ms, 4, 50))
}
