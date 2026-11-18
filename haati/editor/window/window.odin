package window

// Plugin-openable editor windows (docs/Plugins.md). A window is DECLARED with
// @(editor_window={id, title, width, height}) on its content-draw proc —
// prebuild registers every declaration here — and OPENED by id, usually from a
// @(menu_item) proc, the way Unity's [MenuItem] calls EditorWindow.GetWindow.
//
// State: the registry and open list live here for the process lifetime (reopen
// from the menu after a restart). imgui.ini persists dock position and size by
// title; width/height from the attribute apply only when imgui.ini has no
// entry yet (Cond.FirstUseEver). Window CONTENTS live in the owning plugin.
//
// An editor subpackage like menu/inspector/undo: plugin editor/ packages import
// it, the editor root draws it once per frame (draw_all).

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:fmt"
import "core:math"
import im "haati:external/odin-imgui"
import "haati:engine/log"
import icons "haati:editor/icons"
import thm "haati:editor/theme"
import widgets "haati:editor/widgets"

Draw_Proc :: proc()

_Registered :: struct {
	id:           string,  // stable handle from the attribute
	plain_title:  string,  // the title as declared, without icon or id
	icon:         string,  // icon rune string declared on the window
	title:        cstring, // the imgui window name: "<icon> <title>###<id>"
	draw:         Draw_Proc,
	default_size: im.Vec2, // {} = imgui's default
	// The @(editor_window) that declared it, with its file and line, as
	// rendered by the generator. Shown on the tab's menu button with debug tooltips on.
	origin:       string,
}

_Open :: struct {
	reg:  int, // index into _registry
	open: bool,
}

_registry: [dynamic]_Registered
_open_windows: [dynamic]_Open
_closed_window_ids: [dynamic]string // LIFO stack for Ctrl+Shift+T reopen closed tab
_focus_request: int = -1 // registry index to focus next frame
main_dockspace_id: im.ID
main_central_dock_id: im.ID
// Extendable telemetry hook (nil when Overwatch recorder is stopped -> 0ns overhead).
on_window_event_hook: proc(action: string, id: string)

// Records a closed window ID so Ctrl+Shift+T can reopen it in LIFO order.
push_closed :: proc(id: string) {
	if id == "" do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	for i := len(_closed_window_ids) - 1; i >= 0; i -= 1 {
		if _closed_window_ids[i] == id {
			delete(_closed_window_ids[i])
			ordered_remove(&_closed_window_ids, i)
		}
	}
	if len(_closed_window_ids) >= 32 {
		delete(_closed_window_ids[0])
		ordered_remove(&_closed_window_ids, 0)
	}
	append(&_closed_window_ids, strings.clone(id))
}

reopen_last_closed :: proc() -> (reopened_id: string, ok: bool) {
	for len(_closed_window_ids) > 0 {
		idx := len(_closed_window_ids) - 1
		id := _closed_window_ids[idx]
		ordered_remove(&_closed_window_ids, idx)
		if !is_open(id) {
			open(id)
			reopened_id = strings.clone(id, context.temp_allocator)
			delete(id, runtime.default_allocator())
			return reopened_id, true
		}
		delete(id, runtime.default_allocator())
	}
	return "", false
}

// Called by the generated _register_editor_windows (editor_window_gen). The
// imgui window name is "<icon> <title>###<id>": the icon and title show, the
// id stays the imgui id whatever they are.
register :: proc(id: string, title: string, icon: string, draw: Draw_Proc, width, height: f32, origin := "") {
	for &r in _registry {
		if r.id == id {
			log.errorf("editor_window: duplicate id %q (%s ignored)", id, title)
			return
		}
	}
	append(&_registry, _Registered{
		id           = id,
		plain_title  = title,
		icon         = icon,
		title        = strings.clone_to_cstring(fmt.tprintf("%s %s###%s", icon, title, id), runtime.default_allocator()),
		draw         = draw,
		default_size = {width, height},
		origin       = origin,
	})
}

// Looks up the registered icon rune for a window by its plain title (e.g. for Window menu entries).
icon_by_plain_title :: proc(plain_title: string) -> string {
	for &r in _registry {
		if r.plain_title == plain_title do return r.icon
	}
	return ""
}

// Every registered window's plain title and id, for imgui.ini migration
// (the ini names a window "###<id>" now that titles carry icons).
Title_Id :: struct {
	title: string,
	id:    string,
}

registered :: proc(allocator := context.temp_allocator) -> []Title_Id {
	out := make([]Title_Id, len(_registry), allocator)
	for r, i in _registry do out[i] = {r.plain_title, r.id}
	return out
}

// The ids of every currently open window — the editor persists these in
// editor_settings so a session reopens what was open (imgui.ini already
// keeps position and size, but not whether the window existed).
open_ids :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(_open_windows), allocator)
	for &e in _open_windows {
		if e.open do append(&out, _registry[e.reg].id)
	}
	return out[:]
}

// Reopen the windows named by a previous open_ids — unknown ids (a package
// that is no longer installed) are skipped quietly, unlike `open`.
open_saved :: proc(ids: []string) {
	for id in ids {
		resolved_id := id == "editor_defaults" ? "project_settings" : id
		for &r, ri in _registry {
			if r.id != resolved_id do continue
			already := false
			for &e in _open_windows do if e.reg == ri do already = true
			if !already do append(&_open_windows, _Open{reg = ri, open = true})
			break
		}
	}
}

@(private = "file")
_pending_settings_tab: string

// Open the unified Settings window pre-selected on a specific tab name (e.g. "Code & Script IDE").
open_settings_tab :: proc(tab_name: string) {
	if len(_pending_settings_tab) > 0 {
		delete(_pending_settings_tab, runtime.default_allocator())
		_pending_settings_tab = ""
	}
	if len(tab_name) > 0 {
		_pending_settings_tab = strings.clone(tab_name, runtime.default_allocator())
	}
	open("project_settings")
}

// Consume any pending tab selection queued for the unified Settings window.
consume_pending_settings_tab :: proc(allocator := context.temp_allocator) -> string {
	if len(_pending_settings_tab) == 0 do return ""
	out := strings.clone(_pending_settings_tab, allocator)
	delete(_pending_settings_tab, runtime.default_allocator())
	_pending_settings_tab = ""
	return out
}

// Show the window declared under `id`, or focus it if already open.
open :: proc(id: string) {
	resolved_id := id == "editor_defaults" ? "project_settings" : id
	for &r, ri in _registry {
		if r.id != resolved_id do continue
		for &e in _open_windows {
			if e.reg == ri {
				e.open = true
				_focus_request = ri
				if on_window_event_hook != nil do on_window_event_hook("Focus Window", resolved_id)
				return
			}
		}
		append(&_open_windows, _Open{reg = ri, open = true})
		if on_window_event_hook != nil do on_window_event_hook("Open Window", resolved_id)
		return
	}
	log.errorf("editor_window: unknown id %q (declare it with @(editor_window={{id=...}}))", id)
}

close :: proc(id: string) {
	for &e in _open_windows {
		if _registry[e.reg].id == id {
			e.open = false
			push_closed(id)
			if on_window_event_hook != nil do on_window_event_hook("Close Window", id)
		}
	}
}

// The origin of the window declared under `id`, for debug tooltips. Unknown ids
// (a built-in view, which is not a registered window) answer "".
origin_of :: proc(id: string) -> string {
	for &r in _registry {
		if r.id == id do return r.origin
	}
	return ""
}

is_open :: proc(id: string) -> bool {
	for &e in _open_windows {
		if _registry[e.reg].id == id && e.open do return true
	}
	return false
}

// Returns the ImGui window title ("<icon> <title>###<id>") for a registered id.
title_of :: proc(id: string) -> cstring {
	for &r in _registry {
		if r.id == id do return r.title
	}
	return nil
}

// Main UI scale factor (1.0 = default 100%)
main_scale: f32 = 1.0

@(private = "file")
_window_scales: map[string]f32

get_main_scale :: proc() -> f32 {
	return main_scale
}

set_main_scale :: proc(scale: f32) {
	main_scale = math.clamp(scale, 0.6, 2.5)
}

get_window_scale :: proc(id: string) -> f32 {
	if _window_scales == nil do return 1.0
	s, ok := _window_scales[id]
	if !ok || s <= 0.01 do return 1.0
	return s
}

set_window_scale :: proc(id: string, scale: f32) {
	if _window_scales == nil {
		_window_scales = make(map[string]f32)
	}
	_window_scales[id] = math.clamp(scale, 0.6, 2.5)
}

reset_window_scale :: proc(id: string) {
	if _window_scales != nil {
		delete_key(&_window_scales, id)
	}
}

reset_all_scales :: proc() {
	main_scale = 1.0
	if _window_scales != nil {
		clear(&_window_scales)
	}
}

get_all_window_scales :: proc(allocator := context.temp_allocator) -> map[string]f32 {
	out := make(map[string]f32, len(_window_scales), allocator)
	for k, v in _window_scales {
		out[strings.clone(k, allocator)] = v
	}
	return out
}

set_all_window_scales :: proc(scales: map[string]f32) {
	if _window_scales == nil {
		_window_scales = make(map[string]f32)
	}
	clear(&_window_scales)
	for k, v in scales {
		if v > 0.01 {
			_window_scales[strings.clone(k)] = v
		}
	}
}

get_effective_scale :: proc(id: string) -> f32 {
	return main_scale * get_window_scale(id)
}

// ─────────────────────────────────────────────────────────────
// CENTRALIZED MODAL DIALOGS (AUTORESIZING & ROOT SCALED)
// ─────────────────────────────────────────────────────────────

show_confirm_dialog :: proc(title: string, message: string, confirm_label: string = "Confirm", on_confirm: proc() = nil, is_danger: bool = true, cancel_label: string = "Cancel", on_cancel: proc() = nil) {
	buttons := [2]widgets.Dialog_Button{
		{label = confirm_label, action = on_confirm, is_default = !is_danger, is_danger = is_danger},
		{label = cancel_label, action = on_cancel, is_cancel = true},
	}
	widgets.dialog_open(widgets.Dialog{
		title       = title,
		description = message,
		icon        = is_danger ? icons.ICON_MD_WARNING : icons.ICON_MD_HELP,
		buttons     = buttons[:],
	})
}

close_confirm_dialog :: proc() {
	widgets.dialog_close()
}

Text_Dialog_Opts :: struct {
	title:            string,
	prompt:           string,
	initial_text:     string,
	confirm_label:    string,
	cancel_label:     string,
	select_stem_only: bool,
	on_apply:         proc(string),
	on_cancel:        proc(),
}

Rename_Dialog :: struct {
	open:             bool,
	title:            string,
	prompt:           string,
	confirm_label:    string,
	cancel_label:     string,
	select_stem_only: bool,
	stem_selected:    bool,
	buffer:           [256]u8,
	focus:            bool,
	on_apply:         proc(string),
	on_cancel:        proc(),
}

@(private = "file")
_active_rename: Rename_Dialog

open_scene_handler: proc(path: string, prompt_save: bool) -> bool

request_open_scene :: proc(path: string, prompt_save := true) -> bool {
	if open_scene_handler == nil do return false
	return open_scene_handler(path, prompt_save)
}

modal_scale: f32 = 1.0

get_modal_scale :: proc() -> f32 {
	return modal_scale
}

set_modal_scale :: proc(s: f32) {
	modal_scale = math.clamp(s, 0.7, 2.0)
}

show_text_input_dialog :: proc(opts: Text_Dialog_Opts) {
	close_rename_dialog()
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	_active_rename = Rename_Dialog{
		open             = true,
		title            = strings.clone(opts.title),
		prompt           = strings.clone(len(opts.prompt) > 0 ? opts.prompt : "New Name:"),
		confirm_label    = strings.clone(len(opts.confirm_label) > 0 ? opts.confirm_label : "Apply"),
		cancel_label     = strings.clone(len(opts.cancel_label) > 0 ? opts.cancel_label : "Cancel"),
		select_stem_only = opts.select_stem_only,
		focus            = true,
		on_apply         = opts.on_apply,
		on_cancel        = opts.on_cancel,
	}
	mem.zero(&_active_rename.buffer, len(_active_rename.buffer))
	name_bytes := transmute([]u8)opts.initial_text
	copy_len := min(len(name_bytes), len(_active_rename.buffer) - 1)
	if copy_len > 0 do copy(_active_rename.buffer[:], name_bytes[:copy_len])
}

show_rename_dialog :: proc(title: string, current_name: string, on_apply: proc(string), on_cancel: proc() = nil) {
	show_text_input_dialog(Text_Dialog_Opts{
		title        = title,
		initial_text = current_name,
		on_apply     = on_apply,
		on_cancel    = on_cancel,
	})
}

close_rename_dialog :: proc() {
	if _active_rename.open {
		prev := context.allocator
		context.allocator = runtime.default_allocator()
		defer context.allocator = prev
		delete(_active_rename.title)
		delete(_active_rename.prompt)
		delete(_active_rename.confirm_label)
		delete(_active_rename.cancel_label)
		_active_rename.open = false
		_active_rename.on_apply = nil
		_active_rename.on_cancel = nil
	}
}

@(private = "file")
_rename_input_callback :: proc "c" (data: ^im.InputTextCallbackData) -> i32 {
	if data == nil || data.UserData == nil do return 0
	dlg := cast(^Rename_Dialog)data.UserData
	if dlg.select_stem_only && !dlg.stem_selected && data.EventActivated && data.BufTextLen > 0 {
		buf := (cast([^]u8)data.Buf)[:data.BufTextLen]
		dot := -1
		for i := len(buf) - 1; i >= 0; i -= 1 {
			if buf[i] == '.' {
				dot = i
				break
			}
		}
		sel_end := i32(dot > 0 ? dot : int(data.BufTextLen))
		data.SelectionStart = 0
		data.SelectionEnd = sel_end
		data.CursorPos = sel_end
		dlg.stem_selected = true
	}
	return 0
}

uses_independent_pane_zoom :: proc(id: string) -> bool {
	// Studio workspaces & content browsers implement independent per-pane Ctrl+MouseWheel zoom
	// so toolbars, headers, trees & buttons never distort or clip!
	return id == "odin_micro_studio" ||
	       id == "mh_visual_script" ||
	       id == "file_explorer" ||
	       id == "material_editor"
}

// One call per editor frame, after the built-in views. Removal happens here,
// the frame after the close button flips `open`.
draw_all :: proc() {
	for i := len(_open_windows) - 1; i >= 0; i -= 1 {
		e := &_open_windows[i]
		if !e.open {
			push_closed(_registry[e.reg].id)
			ordered_remove(&_open_windows, i)
			continue
		}
		r := &_registry[e.reg]
		if r.default_size != {} {
			im.SetNextWindowSize(r.default_size, .FirstUseEver)
		}
		if _focus_request == e.reg {
			im.SetNextWindowFocus()
			_focus_request = -1
		}
		// NoCollapse matches every built-in view — no collapse triangle when
		// the window floats. Enable HorizontalScrollbar when zoomed up so narrow
		// docked panes never clip right-hand content off-screen.
		indep_zoom := uses_independent_pane_zoom(r.id)
		per_scale_pre := indep_zoom ? f32(1.0) : get_window_scale(r.id)
		win_flags := im.WindowFlags{.NoCollapse}
		if per_scale_pre > 1.05 {
			win_flags += {.HorizontalScrollbar}
		}
		if begin(r.title, &e.open, win_flags) {
			// Real-time Ctrl + Mouse Wheel zoom when hovering over this window
			io := im.GetIO()
			if !indep_zoom && io.KeyCtrl && io.MouseWheel != 0 && im.IsWindowHovered(im.HoveredFlags_RootWindow | im.HoveredFlags_ChildWindows) {
				curr := get_window_scale(r.id)
				new_scale := math.clamp(curr + io.MouseWheel * 0.05, 0.6, 2.5)
				set_window_scale(r.id, new_scale)
				io.MouseWheel = 0
			}

			per_scale := indep_zoom ? f32(1.0) : get_window_scale(r.id)
			eff_scale := indep_zoom ? get_main_scale() : get_effective_scale(r.id)
			has_per_scale := abs(per_scale - 1.0) > 0.01
			has_eff_scale := abs(eff_scale - 1.0) > 0.01

			st := im.GetStyle()
			if has_per_scale {
				im.PushFontFloat(nil, st.FontSizeBase * per_scale)
			}
			if has_eff_scale {
				im.PushStyleVarImVec2(.FramePadding, {st.FramePadding.x * eff_scale, st.FramePadding.y * eff_scale})
				im.PushStyleVarImVec2(.ItemSpacing, {st.ItemSpacing.x * eff_scale, st.ItemSpacing.y * eff_scale})
				im.PushStyleVarImVec2(.ItemInnerSpacing, {st.ItemInnerSpacing.x * eff_scale, st.ItemInnerSpacing.y * eff_scale})
				im.PushStyleVarImVec2(.CellPadding, {st.CellPadding.x * eff_scale, st.CellPadding.y * eff_scale})
				im.PushStyleVar(.IndentSpacing, st.IndentSpacing * eff_scale)
			}

			r.draw()

			if has_eff_scale {
				im.PopStyleVar(5)
			}
			if has_per_scale {
				im.PopFont()
			}

			// Title bar decorations for floating/undocked windows
			decorate_floating_window(r.title, &e.open)
		}
		im.End()
	}

	// Draw centralized modal dialogs at root viewport level (independent scale, always auto-resizes, no clipping!)
	st := im.GetStyle()
	has_modal_font := abs(modal_scale - 1.0) > 0.01

	// Centralized Rename Dialog (Auto-resizes cleanly at viewport root, independent scale)
	if _active_rename.open {
		if has_modal_font do im.PushFontFloat(nil, st.FontSizeBase * modal_scale)
		wpos, wsz := monitor_work_rect_at(im.GetMousePos(), true)
		im.SetNextWindowPos(wpos + wsz * 0.5, .Appearing, im.Vec2{0.5, 0.5})
		modal_flags := im.WindowFlags{.AlwaysAutoResize, .NoSavedSettings}
		modal_title := strings.clone_to_cstring(fmt.tprintf("%s###CentralRenameModal", _active_rename.title), context.temp_allocator)
		im.OpenPopup(modal_title)

		if im.BeginPopupModal(modal_title, &_active_rename.open, modal_flags) {
			io := im.GetIO()
			if io.KeyCtrl && io.MouseWheel != 0 {
				set_modal_scale(modal_scale + io.MouseWheel * 0.05)
			}

			widgets.text_coloredf(thm.palette().accent, "%s  %s", icons.ICON_MD_EDIT, _active_rename.title)
			im.Separator()
			im.Spacing()

			im.TextUnformatted(widgets.temp_cstr(_active_rename.prompt))
			im.SetNextItemWidth(320.0)
			if _active_rename.focus {
				im.SetKeyboardFocusHere()
				_active_rename.focus = false
			}
			in_flags: im.InputTextFlags = {.EnterReturnsTrue}
			enter_pressed := false
			if _active_rename.select_stem_only {
				in_flags += {.CallbackAlways}
				enter_pressed = im.InputText("##CentralRenameInput", cstring(raw_data(_active_rename.buffer[:])), len(_active_rename.buffer), in_flags, _rename_input_callback, &_active_rename)
			} else {
				in_flags += {.AutoSelectAll}
				enter_pressed = im.InputText("##CentralRenameInput", cstring(raw_data(_active_rename.buffer[:])), len(_active_rename.buffer), in_flags)
			}

			im.Spacing()
			im.Separator()
			im.Spacing()

			if im.Button(fmt.ctprintf("%s  %s", icons.ICON_MD_CHECK, _active_rename.confirm_label), {110, 30}) || enter_pressed {
				name := strings.string_from_null_terminated_ptr(raw_data(_active_rename.buffer[:]), len(_active_rename.buffer))
				cb := _active_rename.on_apply
				close_rename_dialog()
				im.CloseCurrentPopup()
				if cb != nil do cb(name)
			}
			im.SameLine(0, 15)
			if im.Button(fmt.ctprintf("%s  %s", icons.ICON_MD_CLOSE, _active_rename.cancel_label), {110, 30}) || im.IsKeyPressed(.Escape) || !_active_rename.open {
				cb := _active_rename.on_cancel
				close_rename_dialog()
				im.CloseCurrentPopup()
				if cb != nil do cb()
			}
			im.EndPopup()
		}
		if has_modal_font do im.PopFont()
	}
}

shutdown :: proc() {
	close_confirm_dialog()
	close_rename_dialog()
	delete(_registry)
	_registry = nil
	delete(_open_windows)
	_open_windows = nil
	for id in _closed_window_ids {
		delete(id, runtime.default_allocator())
	}
	delete(_closed_window_ids)
	_closed_window_ids = nil
	if _window_scales != nil {
		delete(_window_scales)
		_window_scales = nil
	}
	if len(_pending_settings_tab) > 0 {
		delete(_pending_settings_tab, runtime.default_allocator())
		_pending_settings_tab = ""
	}
	viewports_shutdown()
}

_get_central_dock_target :: proc() -> im.ID {
	if main_central_dock_id != 0 {
		if leaf := resolve_leaf_dock_node(main_central_dock_id); leaf != 0 do return leaf
	}
	if main_dockspace_id != 0 {
		if central := im.DockBuilderGetCentralNode(main_dockspace_id); central != nil {
			if leaf := resolve_leaf_dock_node(central.ID_); leaf != 0 do return leaf
		}
		return resolve_leaf_dock_node(main_dockspace_id)
	}
	return 0
}

// Draws a pixel-crisp Maximize (`[□]`) or Restore (`[❐]`) vector glyph centered inside `[bmin, bmax]`.
draw_maximize_restore_icon :: proc(dl: ^im.DrawList, bmin, bmax: im.Vec2, is_maximized: bool, col: u32) {
	center := (bmin + bmax) * 0.5
	h := bmax.y - bmin.y
	r := max(h * 0.21, 4.0)
	if !is_maximized {
		im.DrawList_AddRect(dl, {center.x - r, center.y - r}, {center.x + r, center.y + r}, col, 1.0, 1.6)
		im.DrawList_AddLine(dl, {center.x - r, center.y - r + 1.0}, {center.x + r, center.y - r + 1.0}, col, 1.8)
	} else {
		// Back window top-right corner + front window square
		off := max(r * 0.34, 1.8)
		fmin := im.Vec2{center.x - r - off * 0.35, center.y - r + off * 0.55}
		fmax := im.Vec2{center.x + r - off * 0.35, center.y + r + off * 0.55}
		b0   := im.Vec2{fmin.x + off, fmin.y - off}
		b1   := im.Vec2{fmax.x + off, fmax.y - off}
		im.DrawList_AddLine(dl, {b0.x, fmin.y}, b0, col, 1.5)
		im.DrawList_AddLine(dl, b0, {b1.x, b0.y}, col, 1.5)
		im.DrawList_AddLine(dl, {b1.x, b0.y}, b1, col, 1.5)
		im.DrawList_AddLine(dl, {fmax.x, b1.y}, b1, col, 1.5)
		im.DrawList_AddRect(dl, fmin, fmax, col, 0.8, 1.6)
	}
}

decorate_floating_window :: proc(title: cstring, p_open: ^bool = nil) {
	// Docked or not: pop-out bookkeeping (dock slot, rect, OS window) is
	// recorded every frame so reunite knows where the panel came from.
	_track_current(title)
	if im.IsWindowDocked() do return

	win_pos := im.GetWindowPos()
	win_size := im.GetWindowSize()
	style := im.GetStyle()
	title_h := im.GetFrameHeight()
	btn_w := max(title_h * 1.22, 26.0)
	if win_size.x < btn_w * 2.5 do return

	right_x := win_pos.x + win_size.x - style.WindowBorderSize

	close_min := im.Vec2{right_x - btn_w, win_pos.y + style.WindowBorderSize}
	close_max := im.Vec2{right_x, win_pos.y + title_h}

	max_min := im.Vec2{close_min.x - btn_w - 2.0, win_pos.y + style.WindowBorderSize}
	max_max := im.Vec2{close_min.x - 2.0, win_pos.y + title_h}

	mouse_pos := im.GetMousePos()
	in_close := mouse_pos.x >= close_min.x && mouse_pos.x <= close_max.x && mouse_pos.y >= close_min.y && mouse_pos.y <= close_max.y
	in_max   := mouse_pos.x >= max_min.x   && mouse_pos.x <= max_max.x   && mouse_pos.y >= max_min.y   && mouse_pos.y <= max_max.y

	// AllowWhenBlockedByActiveItem allows hover and clicks to register even while the title bar dragging handler is active
	is_win_hovered := im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem | im.HoveredFlags_RootAndChildWindows)
	close_hovered := in_close && is_win_hovered
	max_hovered   := in_max   && is_win_hovered

	close_active := close_hovered && im.IsMouseDown(.Left)
	max_active   := max_hovered   && im.IsMouseDown(.Left)

	if close_hovered || max_hovered {
		im.SetMouseCursor(.Arrow)
		if im.IsMouseDown(.Left) || im.IsMouseClicked(.Left) {
			im.StopMouseMovingWindow()
		}
	}

	outside := viewports_enabled() && in_own_os_window(title)
	is_max  := is_window_maximized(title)

	in_title_bar := mouse_pos.x >= win_pos.x && mouse_pos.x < max_min.x && mouse_pos.y >= win_pos.y && mouse_pos.y <= win_pos.y + title_h
	if (max_hovered && im.IsMouseClicked(.Left)) || (in_title_bar && is_win_hovered && im.IsMouseDoubleClicked(.Left)) {
		im.StopMouseMovingWindow()
		im.ClearActiveID()
		toggle_maximize_window(title, win_pos, win_size, outside)
	}

	if close_hovered && im.IsMouseClicked(.Left) {
		im.StopMouseMovingWindow()
		im.ClearActiveID()
		if p_open != nil {
			p_open^ = false
		}
		s := string(title)
		if idx := strings.last_index(s, "###"); idx >= 0 {
			close(s[idx + 3:])
		} else {
			close(s)
		}
	}

	dl := im.GetWindowDrawList()
	im.DrawList_PushClipRect(dl, win_pos, win_pos + win_size, false)

	// 1. Maximize / Restore ("Make Window Big") button
	max_bg := max_active ? im.GetColorU32ImVec4(im.Vec4{0.18, 0.34, 0.42, 1.0}) : (max_hovered ? im.GetColorU32ImVec4(im.Vec4{0.26, 0.46, 0.58, 1.0}) : im.GetColorU32ImVec4(im.Vec4{0.20, 0.25, 0.34, 0.88}))
	im.DrawList_AddRectFilled(dl, max_min, max_max, max_bg, 2.0)
	max_icon_col := max_hovered ? im.GetColorU32ImVec4(im.Vec4{1.0, 1.0, 1.0, 1.0}) : im.GetColorU32ImVec4(im.Vec4{0.90, 0.94, 1.0, 0.95})
	draw_maximize_restore_icon(dl, max_min, max_max, is_max, max_icon_col)

	// 2. Red square Close button (distinct, high contrast red square with centered white X)
	close_bg := close_active ? im.GetColorU32ImVec4(im.Vec4{0.60, 0.10, 0.10, 1.0}) : (close_hovered ? im.GetColorU32ImVec4(im.Vec4{0.96, 0.22, 0.22, 1.0}) : im.GetColorU32ImVec4(im.Vec4{0.80, 0.16, 0.16, 0.92}))
	im.DrawList_AddRectFilled(dl, close_min, close_max, close_bg, 2.0)

	// Crisp centered white cross 'X'
	center := (close_min + close_max) * 0.5
	cross_r := title_h * 0.20
	white := im.GetColorU32ImVec4(im.Vec4{1.0, 1.0, 1.0, 1.0})
	im.DrawList_AddLine(dl, {center.x - cross_r, center.y - cross_r}, {center.x + cross_r, center.y + cross_r}, white, 2.0)
	im.DrawList_AddLine(dl, {center.x - cross_r, center.y + cross_r}, {center.x + cross_r, center.y - cross_r}, white, 2.0)

	im.DrawList_PopClipRect(dl)

	if !im.IsMouseDown(.Left) {
		if max_hovered   do widgets.tooltip_unchecked(is_max ? "Restore Window Size" : "Maximize Window")
		if close_hovered do widgets.tooltip_unchecked("Close Window")
	}

	// Allow Right-Click on a floating window's title bar to inspect its `.odin` source script
	// (only show hover tooltip when Debug Tooltips is explicitly enabled and not dragging, so normal drags never spawn tooltip OS windows!).
	if in_title_bar && is_win_hovered && (widgets.ui_debug_tooltips || im.IsMouseClicked(.Right)) && !im.IsMouseDown(.Left) {
		s := string(title)
		win_id := s
		disp := s
		if idx := strings.last_index(s, "###"); idx >= 0 {
			win_id = s[idx + 3:]
			disp = s[:idx]
		}
		orig := origin_of(win_id)
		if len(orig) > 0 {
			prev_orig := widgets.ui_origin_push(orig)
			widgets.tooltip_unchecked(strings.clone_to_cstring(disp, context.temp_allocator))
			widgets.ui_origin_pop(prev_orig)
		}
	}
}
