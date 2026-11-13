package editor

// =============================================================================
// EDITOR DEFAULTS (`view_editor_defaults.odin`)
// =============================================================================
// Personal machine-local defaults persisted to `UserSettings/editor_defaults.json`
// (gitignored so personal UI scale, IDE pane zooms, tooltip hover delay, and graph
// preferences never pollute repository commits).
// Accessible from `Edit -> Editor Defaults...` AND as a tab in `Edit -> Project Settings`.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import im "haati:external/odin-imgui"
import cs "haati:editor/code_studio"
import "haati:editor/icons"
import thm "haati:editor/theme"
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

@(private = "file")
_defaults_dirty := false

@(private = "file")
_on_global_wire_style_changed :: proc(style: nc.Canvas_Wire_Style) {
	editor_defaults.graph_wire_style        = clamp(i32(style), 0, 2)
	editor_defaults.graph_wire_style_v2_set = true
	editor_defaults.graph_electronic_wires  = (style == .Electronic_45)
	_defaults_dirty = true
	_ = editor_defaults_save()
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

editor_defaults_apply :: proc(sync_ide_panes := false) {
	editor_defaults.ui_scale               = math.clamp(editor_defaults.ui_scale, 0.70, 2.00)
	editor_defaults.tooltip_idle_delay_sec = math.clamp(editor_defaults.tooltip_idle_delay_sec, 0.05, 2.50)
	editor_defaults.ide_explorer_zoom      = math.clamp(editor_defaults.ide_explorer_zoom, 0.70, 2.40)
	editor_defaults.ide_code_zoom          = math.clamp(editor_defaults.ide_code_zoom, 0.70, 2.60)
	editor_defaults.ide_problems_zoom      = math.clamp(editor_defaults.ide_problems_zoom, 0.70, 2.40)
	editor_defaults.background_fps_cap     = clamp(editor_defaults.background_fps_cap, 15, 240)

	wnd.set_main_scale(editor_defaults.ui_scale)
	widgets.tooltip_idle_delay_sec = editor_defaults.tooltip_idle_delay_sec
	cs.configure_ide_defaults(
		editor_defaults.ide_explorer_zoom,
		editor_defaults.ide_code_zoom,
		editor_defaults.ide_problems_zoom,
		editor_defaults.ide_show_breadcrumbs,
		editor_defaults.ide_show_error_lens,
		sync_ide_panes,
	)
	if !editor_defaults.graph_wire_style_v2_set {
		editor_defaults.graph_wire_style        = editor_defaults.graph_electronic_wires ? 1 : 0
		editor_defaults.graph_wire_style_v2_set = true
	}
	editor_defaults.graph_wire_style = clamp(editor_defaults.graph_wire_style, 0, 2)
	nc.on_global_wire_style_changed = _on_global_wire_style_changed
	nc.set_global_wire_style(nc.Canvas_Wire_Style(editor_defaults.graph_wire_style), false)
	vs.configure_graph_studio_defaults(
		editor_defaults.graph_electronic_wires,
		editor_defaults.graph_auto_bake_on_save,
	)
}

editor_defaults_load :: proc() {
	editor_defaults_reset_struct(&editor_defaults)
	if data, err := os.read_entire_file(EDITOR_DEFAULTS_PATH, context.temp_allocator); err == nil && len(data) > 0 {
		_ = json.unmarshal(data, &editor_defaults, allocator = context.temp_allocator)
	}
	editor_defaults_apply(true)
}

editor_defaults_save :: proc() -> bool {
	_ = os.make_directory("UserSettings")
	bytes, err := json.marshal(editor_defaults, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil do return false
	ok := os.write_entire_file(EDITOR_DEFAULTS_PATH, bytes) == nil
	if ok do _defaults_dirty = false
	return ok
}

editor_defaults_init :: proc() {
	editor_defaults_load()
	settings_add_custom_tab("Editor Defaults", draw_editor_defaults_panel)
}

editor_defaults_shutdown :: proc() {
	if _defaults_dirty {
		_ = editor_defaults_save()
	}
}

editor_defaults_background_delay_ms :: proc() -> u32 {
	cap := clamp(editor_defaults.background_fps_cap, 15, 240)
	ms := 1000 / cap
	return u32(clamp(ms, 4, 50))
}

draw_editor_defaults_panel :: proc() {
	p := thm.palette()
	changed := false
	sync_panes := false

	im.TextColored(p.accent, fmt.ctprintf("%s Personal Editor Defaults (UserSettings/editor_defaults.json)", icons.ICON_MD_SETTINGS))
	im.TextDisabled("Machine-local settings (gitignored) controlling UI scale, hover tooltip idle delay, IDE zoom panes, and Graph Studio.")
	im.Separator()
	im.Spacing()

	// 1. General UI & Windowing
	if im.CollapsingHeader(fmt.ctprintf("%s Interface, Tooltips & Multi-Window Lifeline", icons.ICON_MD_TUNE), {.DefaultOpen}) {
		if im.SliderFloat("Global Editor UI Scale", &editor_defaults.ui_scale, 0.75, 1.75, "%.2fx") {
			changed = true
		}
		widgets.tooltip("Base font & widget scale for standard docked/floating editor panels")

		if im.SliderFloat("Idle Hover Tooltip Delay (sec)", &editor_defaults.tooltip_idle_delay_sec, 0.10, 2.00, "%.2f s") {
			changed = true
		}
		widgets.tooltip("How long the mouse must rest calmly on a Graph Node or IDE symbol before showing its doc-comment tooltip")

		if im.Checkbox("Keep Popped-Out Windows Live When Main Window Is Minimized", &editor_defaults.keep_secondary_alive_min) {
			changed = true
		}
		widgets.tooltip("Prevents minimizing the main MoonHug/Haati window from cutting off secondary OS windows on other monitors")

		if im.SliderInt("Unfocused / Minimized Pacing Cap (FPS)", &editor_defaults.background_fps_cap, 15, 144, "%d FPS") {
			changed = true
		}
		widgets.tooltip("Frame pacing cap used when the main swapchain is minimized and no editor window is actively focused")
		im.Spacing()
	}

	// 2. Odin Micro-Studio (Independent Segment Zooms & JetBrains/VS Features)
	if im.CollapsingHeader(fmt.ctprintf("%s Odin Micro-Studio (Independent Pane Zoom & Diagnostics)", icons.ICON_MD_CODE), {.DefaultOpen}) {
		im.TextDisabled("Each IDE pane zooms independently with Ctrl + MouseWheel so headers and buttons never clip!")
		if im.SliderFloat("Explorer / Structure Pane Zoom", &editor_defaults.ide_explorer_zoom, 0.75, 2.00, "%.2fx") {
			changed    = true
			sync_panes = true
		}
		if im.SliderFloat("Code Surface Zoom", &editor_defaults.ide_code_zoom, 0.75, 2.40, "%.2fx") {
			changed    = true
			sync_panes = true
		}
		if im.SliderFloat("Problems & Output Console Zoom", &editor_defaults.ide_problems_zoom, 0.75, 2.00, "%.2fx") {
			changed    = true
			sync_panes = true
		}
		if im.Checkbox("Show Breadcrumb Scope Bar (file > proc / struct)", &editor_defaults.ide_show_breadcrumbs) {
			changed = true
		}
		if im.Checkbox("Show Inline Error Lens Diagnostics Next to Code Lines", &editor_defaults.ide_show_error_lens) {
			changed = true
		}
		im.Spacing()
	}

	// 3. Unified Graph Studio
	if im.CollapsingHeader(fmt.ctprintf("%s Unified Graph Studio (BP / Motion / Material / VFX / Audio)", icons.ICON_MD_ACCOUNT_TREE), {.DefaultOpen}) {
		if nc.draw_wire_style_combo("##ed_def_wire_style", 220.0) {
			changed = true
		}
		im.SameLine()
		im.TextUnformatted("Default Global Wire Routing Style")
		if im.Checkbox("Auto-Bake .bodin Native Odin Code on Graph Save", &editor_defaults.graph_auto_bake_on_save) {
			changed = true
		}
		im.Spacing()
	}

	if changed {
		_defaults_dirty = true
		editor_defaults_apply(sync_panes)
		_ = editor_defaults_save()
	}

	im.Separator()
	if im.Button(fmt.ctprintf("%s Save Defaults Now", icons.ICON_MD_SAVE)) {
		_ = editor_defaults_save()
	}
	im.SameLine()
	if im.Button(fmt.ctprintf("%s Reset All to Factory Defaults", icons.ICON_MD_REFRESH)) {
		editor_defaults_reset_struct(&editor_defaults)
		editor_defaults_apply(true)
		_ = editor_defaults_save()
		engine.overwatch_record_event(.User_Action, "EditorDefaults", "Reset Editor Defaults to factory values")
	}
}

@(editor_window={id="editor_defaults", title="Editor Defaults", icon="SETTINGS", width=760, height=580})
editor_defaults_window_draw :: proc() {
	draw_editor_defaults_panel()
}

@(menu_item={path="Edit/Editor Defaults...", order=91})
menu_open_editor_defaults :: proc() {
	wnd.open("editor_defaults")
}
