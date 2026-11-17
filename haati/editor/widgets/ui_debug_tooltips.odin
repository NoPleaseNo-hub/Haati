package widgets

// Debug tooltips: a toggle that makes every UI element say what created it.
// Hovering shows the element's normal tooltip, a rule, and then — dimmed, so
// provenance never competes with the tooltip's own message — where it came
// from.
//
// Two kinds of element, two kinds of answer:
//
//   - REGISTERED through a prebuild attribute: the attribute as written, the
//     file and line it sits on, and the declaration's name. A generator renders
//     that string at build time (gen_core.AttrOrigin) and emits it into the
//     registration call, the owning registry stores it and pushes it as an
//     ambient value around the element's draw, and tooltip() reads it.
//   - HAND-DRAWN, nothing registered it: "built-in" and the file:line of the
//     tooltip call itself, from #caller_location. Free, compile-time, and it
//     means a toolbar button drawn straight in view_toolbar.odin is one hover
//     from its source the same as a registered one.
//
// This file lives in widgets because widgets imports nothing from the editor,
// so every registry — menu included — can reach it without an import cycle.

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import im "haati:external/odin-imgui"
import "haati:editor/icons"
import thm "haati:editor/theme"
import core "haati:engine/core"

// @(menu_item) on a bool variable is a toggle, and this package is inside a
// scan root, so the menu entry costs nothing beyond the attribute.
@(menu_item={path="Help/Debug Tooltips", order=998})
ui_debug_tooltips := false

// Configurable stationary mouse-hover idle delay (in seconds) used by IDE & Graph node tooltips
// (`Editor Defaults` updates this live; default = `0.55s` so moving across nodes never spams popups).
tooltip_idle_delay_sec: f32 = 0.55

@(private = "file") _idle_hover_key:        u64
@(private = "file") _idle_hover_last_frame: i32 = -10
@(private = "file") _idle_hover_elapsed:    f32
@(private = "file") _idle_hover_anchor:     im.Vec2

// Hook wired by editor/component_open_source.odin at startup so right-clicking
// any tool button or widget can open its Odin script directly in Rider / VS Code.
open_source_in_ide_fn: proc(file_path: string, line: int) -> bool

@(private = "file") _ui_origin: string

// Optional secondary implementation script and interactive settings UI callback associated with the next widget/tool tooltip call.
@(private = "file") _next_impl_file:     string
@(private = "file") _next_impl_line:     int
@(private = "file") _next_impl_label:    string
@(private = "file") _next_settings_proc: proc()

@(private = "file")
_Code_Jump_State :: struct {
	wants_open:    bool,
	title:         string,
	call_file:     string,
	call_line:     int,
	call_proc:     string,
	origin_attr:   string,
	origin_file:   string,
	origin_line:   int,
	origin_proc:   string,
	impl_file:     string,
	impl_line:     int,
	impl_label:    string,
	settings_proc: proc(),
}

@(private = "file") _code_jump: _Code_Jump_State

// Associates a core implementation script, line, and optional interactive settings UI callback
// with the very next tool button / tooltip call.
// Right-clicking the tool button opens a dropdown containing BOTH the tool's interactive sliders/toggles
// and the Script Inspector / Jump-to-Code section!
ui_tool_script :: proc(script_path: string, line: int = 1, label: string = "Tool Implementation", settings_proc: proc() = nil) {
	_next_impl_file  = script_path
	_next_impl_line  = max(line, 1)
	_next_impl_label = label
	if settings_proc != nil {
		_next_settings_proc = settings_proc
	}
}

// Associates an interactive settings UI callback (`proc()`) with the very next tool button / tooltip call.
ui_tool_settings :: proc(settings_proc: proc()) {
	_next_settings_proc = settings_proc
}

// Like `ui_tool_script`, but takes the implementation's real source location — pass
// `#location(some_proc)` so "Jump to Tool Script" always lands on the procedure even after edits
// (hard-coded line numbers go stale). Call it right BEFORE the `widgets.tooltip` of its button.
ui_tool_script_loc :: proc(impl: runtime.Source_Code_Location, label: string = "Tool Implementation", settings_proc: proc() = nil) {
	@(static) path_buf: [512]u8
	rel := _repo_relative(impl.file_path)
	saved := core.buf_set(path_buf[:], rel)
	ui_tool_script(saved, int(impl.line), label, settings_proc)
}

// ui_origin_push / ui_origin_pop bracket the draw of one registered element.
// Immediate mode makes an ambient value enough: the element's draw runs to
// completion before the next one starts, so anything calling tooltip() inside
// it belongs to that element. Save and restore rather than set and clear, so a
// registered element that draws nested registered elements does not leave the
// inner origin behind.
ui_origin_push :: proc(origin: string) -> (prev: string) {
	prev = _ui_origin
	_ui_origin = origin
	return
}

ui_origin_pop :: proc(prev: string) {
	_ui_origin = prev
}

// The element's regular tooltip, plus its origin while debug tooltips are on.
// Also captures Right-Click on the hovered tool/widget so the user can adjust
// tool parameters and/or jump straight to its `.odin` script in Rider / VS Code.
tooltip :: proc(text: cstring, flags: im.HoveredFlags = {}, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	if !im.IsItemHovered(flags) do return
	_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil)

	if im.IsMouseClicked(.Right) {
		_capture_code_jump(text, loc, impl_file, impl_line, impl_label, settings_proc)
	}
}

// Same, for a caller that hit-tests itself: a widget painted into the draw
// list has no imgui item to ask about, so it decides when the pointer is on it.
tooltip_unchecked :: proc(text: cstring, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil)
	if im.IsMouseClicked(.Right) {
		_capture_code_jump(text, loc, impl_file, impl_line, impl_label, settings_proc)
	}
}

// Pins the next tooltip to the currently hosted ImGui viewport so hover tooltips
// near panel/window edges never spawn/destroy secondary Vulkan swapchains.
pin_tooltip_to_current_viewport :: proc() {
	if vp := im.GetWindowViewport(); vp != nil && vp.ID_ != 0 {
		im.SetNextWindowViewport(vp.ID_)
	}
}

// Pins an active drag-and-drop source preview tooltip to whichever ImGui platform viewport
// currently contains the cursor (falling back to the source window viewport), avoiding
// per-frame swapchain thrashing across viewport borders.
pin_active_drag_drop_tooltip :: proc() {
	g := im.GetCurrentContext()
	if g == nil || !g.DragDropActive || g.DragDropPayload.SourceId != im.GetItemID() {
		return
	}
	mp := im.GetMousePos()
	pio := im.GetPlatformIO()
	if pio != nil && pio.Viewports.Size > 0 && pio.Viewports.Data != nil {
		vps := ([^]^im.Viewport)(pio.Viewports.Data)[:pio.Viewports.Size]
		for vp in vps {
			if vp == nil || vp.ID_ == 0 do continue
			if mp.x >= vp.Pos.x && mp.y >= vp.Pos.y && mp.x <= vp.Pos.x + vp.Size.x && mp.y <= vp.Pos.y + vp.Size.y {
				im.SetNextWindowViewport(vp.ID_)
				return
			}
		}
	}
	pin_tooltip_to_current_viewport()
}

// Stationary mouse-hover idle-delay check: resets timer while the pointer is actively moving
// (`> 2px` jitter tolerance), and returns `true` once the pointer rests calmly on `hover_key` for `delay_sec`.
@(private = "file")
_check_idle_hover_ready :: proc(hover_key: u64, delay_sec: f32) -> bool {
	if im.IsMouseDown(.Left) || im.IsMouseDown(.Middle) {
		_idle_hover_elapsed = 0
		return false
	}
	eff_delay := delay_sec >= 0 ? delay_sec : tooltip_idle_delay_sec
	if eff_delay <= 0.01 do return true

	cur_frame := im.GetFrameCount()
	mp        := im.GetMousePos()
	dx        := mp.x - _idle_hover_anchor.x
	dy        := mp.y - _idle_hover_anchor.y
	moved_far := (dx * dx + dy * dy) > 4.0

	if hover_key != _idle_hover_key || (cur_frame - _idle_hover_last_frame) > 1 || moved_far {
		_idle_hover_key     = hover_key
		_idle_hover_anchor  = mp
		_idle_hover_elapsed = 0
	} else if cur_frame != _idle_hover_last_frame {
		dt := clamp(im.GetIO().DeltaTime, 0.0, 0.1)
		_idle_hover_elapsed += dt
	}
	_idle_hover_last_frame = cur_frame
	return _idle_hover_elapsed >= eff_delay
}

// Idle-delayed tooltip for standard ImGui widgets (waits until mouse rests calmly for `tooltip_idle_delay_sec`).
tooltip_delayed :: proc(text: cstring, delay_sec: f32 = -1.0, flags: im.HoveredFlags = {}, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	if !im.IsItemHovered(flags) do return
	if im.IsMouseClicked(.Right) {
		_capture_code_jump(text, loc, impl_file, impl_line, impl_label, settings_proc)
	}
	item_key := u64(im.GetItemID())
	if item_key == 0 do item_key = u64(uintptr(rawptr(text))) ~ u64(loc.line)
	if _check_idle_hover_ready(item_key, delay_sec) {
		_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil)
	}
}

// Immediate tooltip with an attached red `UNSAFE:` hazard callout block explaining exact crash/corruption failure modes.
tooltip_unsafe :: proc(text: cstring, unsafe_warning: cstring, flags: im.HoveredFlags = {}, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	if !im.IsItemHovered(flags) do return
	_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil, unsafe_warning)
	if im.IsMouseClicked(.Right) {
		_capture_code_jump(text, loc, impl_file, impl_line, impl_label, settings_proc)
	}
}

// Idle-delayed tooltip with an attached red `UNSAFE:` hazard callout block.
tooltip_unsafe_delayed :: proc(text: cstring, unsafe_warning: cstring, delay_sec: f32 = -1.0, flags: im.HoveredFlags = {}, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	if !im.IsItemHovered(flags) do return
	if im.IsMouseClicked(.Right) {
		_capture_code_jump(text, loc, impl_file, impl_line, impl_label, settings_proc)
	}
	item_key := u64(im.GetItemID())
	if item_key == 0 do item_key = u64(uintptr(rawptr(text))) ~ u64(loc.line)
	if _check_idle_hover_ready(item_key, delay_sec) {
		_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil, unsafe_warning)
	}
}

// Idle-delayed tooltip for custom DrawList items (e.g. Graph Studio node cards & pins).
tooltip_unchecked_delayed :: proc(hover_key: u64, text: cstring, delay_sec: f32 = -1.0, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	if _check_idle_hover_ready(hover_key ~ 0x9e3779b97f4a7c15, delay_sec) {
		_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil)
	}
}

// Idle-delayed custom DrawList tooltip with an attached red `UNSAFE:` hazard callout block.
tooltip_unchecked_unsafe_delayed :: proc(hover_key: u64, text: cstring, unsafe_warning: cstring, delay_sec: f32 = -1.0, loc := #caller_location) {
	impl_file     := _next_impl_file
	impl_line     := _next_impl_line
	impl_label    := _next_impl_label
	settings_proc := _next_settings_proc
	_next_impl_file     = ""
	_next_impl_line     = 0
	_next_impl_label    = ""
	_next_settings_proc = nil

	if _check_idle_hover_ready(hover_key ~ 0x9e3779b97f4a7c15, delay_sec) {
		_tooltip_show(text, loc, impl_file, impl_line, impl_label, settings_proc != nil, unsafe_warning)
	}
}

@(private = "file")
_parse_file_and_line :: proc(s: string) -> (file: string, line: int, ok: bool) {
	colon := strings.last_index_byte(s, ':')
	if colon <= 0 || colon + 1 >= len(s) do return "", 0, false
	l, lok := strconv.parse_int(s[colon + 1:])
	if !lok || l <= 0 do return "", 0, false
	return s[:colon], l, true
}

@(private = "file")
_capture_code_jump :: proc(text: cstring, loc: runtime.Source_Code_Location, impl_file: string, impl_line: int, impl_label: string, settings_proc: proc()) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if len(_code_jump.title) > 0       do delete(_code_jump.title)
	if len(_code_jump.call_file) > 0   do delete(_code_jump.call_file)
	if len(_code_jump.call_proc) > 0   do delete(_code_jump.call_proc)
	if len(_code_jump.origin_attr) > 0 do delete(_code_jump.origin_attr)
	if len(_code_jump.origin_file) > 0 do delete(_code_jump.origin_file)
	if len(_code_jump.origin_proc) > 0 do delete(_code_jump.origin_proc)
	if len(_code_jump.impl_file) > 0   do delete(_code_jump.impl_file)
	if len(_code_jump.impl_label) > 0  do delete(_code_jump.impl_label)
	_code_jump = {}

	raw_txt := string(text) if text != nil else ""
	if nl := strings.index_byte(raw_txt, '\n'); nl >= 0 {
		raw_txt = raw_txt[:nl]
	}
	raw_txt = utf8_safe_prefix(raw_txt, 72)
	_code_jump.title         = strings.clone(raw_txt)
	_code_jump.call_file     = strings.clone(_repo_relative(loc.file_path))
	_code_jump.call_line     = int(loc.line)
	_code_jump.call_proc     = strings.clone(loc.procedure)
	_code_jump.settings_proc = settings_proc

	if _ui_origin != "" {
		parts := strings.split(_ui_origin, "  ", context.temp_allocator)
		if len(parts) >= 1 {
			_code_jump.origin_attr = strings.clone(parts[0])
		}
		if len(parts) >= 2 {
			if f, l, ok := _parse_file_and_line(parts[1]); ok {
				_code_jump.origin_file = strings.clone(f)
				_code_jump.origin_line = l
			}
		}
		if len(parts) >= 3 {
			_code_jump.origin_proc = strings.clone(parts[2])
		}
	}

	if len(impl_file) > 0 {
		_code_jump.impl_file  = strings.clone(impl_file)
		_code_jump.impl_line  = max(impl_line, 1)
		_code_jump.impl_label = strings.clone(len(impl_label) > 0 ? impl_label : "Tool Implementation")
	}
	_code_jump.wants_open = true
}

// Drawn once per frame from the main editor loop (`main.odin`).
// Opens the Right-Click "Tool Settings & Script Inspector" dropdown whenever the user right-clicked
// a tool button or UI widget (unless another context menu popup already claimed the click).
code_jump_popup_draw :: proc() {
	if _code_jump.wants_open {
		_code_jump.wants_open = false
		has_explicit_target := len(_code_jump.origin_file) > 0 || len(_code_jump.impl_file) > 0 || _code_jump.settings_proc != nil
		if (!im.IsPopupOpen("", im.PopupFlags_AnyPopupId) || has_explicit_target) && len(_code_jump.call_file) > 0 {
			im.SetNextWindowPos(im.GetMousePos(), .Appearing)
			im.OpenPopup("###widget_code_jump_popup")
		}
	}

	if im.BeginPopup("###widget_code_jump_popup") {
		defer im.EndPopup()

		p := thm.palette()
		if len(_code_jump.title) > 0 {
			text_colored(p.accent, _code_jump.title)
		} else {
			im.TextColoredUnformatted(p.accent, "UI Tool / Widget")
		}

		// 0. Interactive Per-Tool Settings / Sliders (if this tool registered a settings callback)
		if _code_jump.settings_proc != nil {
			im.Separator()
			im.PushItemWidth(195)
			_code_jump.settings_proc()
			im.PopItemWidth()
			im.Spacing()
		}

		im.Separator()
		im.TextColoredUnformatted(p.text_secondary, "Script Inspector")
		if len(_code_jump.impl_file) > 0 {
			text_disabledf("Tool Script: %s:%d", _code_jump.impl_file, _code_jump.impl_line)
		}
		text_disabledf("UI Widget:   %s:%d  (%s)", _code_jump.call_file, _code_jump.call_line, _code_jump.call_proc)
		if len(_code_jump.origin_attr) > 0 {
			text_disabledf("Registered:  %s", _code_jump.origin_attr)
		}
		im.Separator()

		// 1. Primary Action: Jump to Tool Implementation Script (if specified)
		if len(_code_jump.impl_file) > 0 {
			lbl := fmt.ctprintf("Jump to %s (%s:%d)", _code_jump.impl_label, _code_jump.impl_file, _code_jump.impl_line)
			if im.MenuItem(lbl) {
				if open_source_in_ide_fn != nil {
					open_source_in_ide_fn(_code_jump.impl_file, _code_jump.impl_line)
				}
			}
		}

		// 2. Jump to UI Button / Widget Call Site
		if len(_code_jump.call_file) > 0 {
			lbl := fmt.ctprintf("Jump to UI Button Code (%s:%d)", _code_jump.call_file, _code_jump.call_line)
			if im.MenuItem(lbl) {
				if open_source_in_ide_fn != nil {
					open_source_in_ide_fn(_code_jump.call_file, _code_jump.call_line)
				}
			}
		}

		// 3. Jump to Overlay / Menu / Decorator Registration Attribute (if distinct from call site)
		if len(_code_jump.origin_file) > 0 && (_code_jump.origin_file != _code_jump.call_file || _code_jump.origin_line != _code_jump.call_line) {
			lbl := fmt.ctprintf("Jump to Attribute Registration (%s:%d)", _code_jump.origin_file, _code_jump.origin_line)
			if im.MenuItem(lbl) {
				if open_source_in_ide_fn != nil {
					open_source_in_ide_fn(_code_jump.origin_file, _code_jump.origin_line)
				}
			}
		}

		im.Separator()
		copy_target := len(_code_jump.impl_file) > 0 ? fmt.ctprintf("%s:%d", _code_jump.impl_file, _code_jump.impl_line) : fmt.ctprintf("%s:%d", _code_jump.call_file, _code_jump.call_line)
		if im.MenuItem("Copy Script Path & Line") {
			im.SetClipboardText(copy_target)
		}
		im.Checkbox("Always Show Script Info in Tooltips", &ui_debug_tooltips)
	}
}

@(private = "file")
_tooltip_show :: proc(text: cstring, loc: runtime.Source_Code_Location, impl_file: string = "", impl_line: int = 0, impl_label: string = "", has_settings: bool = false, unsafe_warning: cstring = nil) {
	// Never spawn or update floating tooltip OS swapchains during active left-mouse drags (window/dock/splitter drag)!
	if im.IsMouseDown(.Left) do return
	has_text   := text != nil && text != ""
	has_unsafe := unsafe_warning != nil && unsafe_warning != ""
	pin_tooltip_to_current_viewport()
	if !ui_debug_tooltips && !has_settings && !has_unsafe {
		if has_text do im.SetTooltipUnformatted(text)
		return
	}
	if !im.BeginTooltip() do return
	defer im.EndTooltip()
	im.PushTextWrapPos(im.GetFontSize() * 34.0)
	defer im.PopTextWrapPos()
	if has_text {
		im.TextUnformatted(text)
	}
	if has_unsafe {
		if has_text do im.Separator()
		im.PushStyleColorImVec4(.Text, im.Vec4{1.0, 0.34, 0.34, 1.0})
		im.TextUnformatted(fmt.ctprintf("%s UNSAFE: ", icons.ICON_MD_WARNING))
		im.TextUnformatted(unsafe_warning)
		im.PopStyleColor()
	}
	if !ui_debug_tooltips && !has_settings do return
	if has_settings && !ui_debug_tooltips {
		_dim("(Right-Click to adjust tool settings & inspect script)")
		return
	}
	if has_text || has_unsafe {
		im.Separator()
	}
	if len(impl_file) > 0 {
		_dim(fmt.tprintf("%s: %s:%d", impl_label, impl_file, impl_line))
	}
	if _ui_origin != "" {
		_draw_origin(_ui_origin)
	} else {
		_dim("built-in")
		_dim(fmt.tprintf("%s:%d  %s", _repo_relative(loc.file_path), loc.line, loc.procedure))
	}
	_dim("(Right-Click to jump to script in IDE)")
}

// An origin reads "@(attr k=v ...)  file:line  name" — three parts, two spaces
// between. The attribute is the answer, so it keeps full strength. The
// location and name are where to go next, so they sit dimmed under it.
@(private = "file")
_draw_origin :: proc(origin: string) {
	parts := strings.split(origin, "  ", context.temp_allocator)
	im.TextUnformatted(strings.clone_to_cstring(parts[0], context.temp_allocator))
	for p in parts[1:] do _dim(p)
}

// Dimmed text through TextUnformatted rather than TextDisabled, which takes a
// format string and would misread a '%' in a path or a label.
@(private = "file")
_dim :: proc(s: string) {
	im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
	im.TextUnformatted(strings.clone_to_cstring(s, context.temp_allocator))
	im.PopStyleColor()
}

// #caller_location paths are absolute. The part from the repo's source roots
// on is what a reader wants, and it keeps a build machine's home directory out
// of a user-visible tooltip.
@(private = "file")
_repo_relative :: proc(path: string) -> string {
	norm, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	if i := strings.index(norm, "/Haati_Engine/"); i >= 0 {
		return norm[i + len("/Haati_Engine/"):]
	}
	for root in ([3]string{"/haati/", "/moonhug/", "/plugins/"}) {
		if i := strings.index(norm, root); i >= 0 do return norm[i + 1:]
	}
	return norm
}
