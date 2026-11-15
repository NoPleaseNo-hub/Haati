package widgets

// Shared Popup Headers, Copy Menu Items, and Copyable Diagnostic Rows.
// Centralizes right-click menu headers, clipboard actions, and copyable compiler/script errors
// so Inspector, Scene, Explorer, Console, Odin Micro-Studio, and Blueprint Studio share one UX.

import "core:fmt"
import "core:strings"
import im "haati:external/odin-imgui"
import icons "haati:editor/icons"
import thm "haati:editor/theme"

// Draws a consistent themed header inside a context menu or popup.
popup_header :: proc(icon: cstring, title: string, accent := im.Vec4{}) {
	col := accent.w > 0 ? accent : thm.palette().accent
	if icon != nil && len(string(icon)) > 0 {
		text_coloredf(col, "%s %s", icon, title)
	} else {
		text_colored(col, title)
	}
	im.Separator()
}

// Standard copy menu item inside a popup/context menu.
// Copies `copy_text` via `set_clipboard_with_feedback` when clicked.
menu_copy_item :: proc(
	label: cstring,
	copy_text: string,
	feedback_id := "ctx_copy",
	shortcut: cstring = "",
) -> bool {
	if copy_text == "" do return false
	item_lbl := fmt.ctprintf("%s  %s", icons.ICON_MD_CONTENT_COPY, label)
	clicked := false
	if shortcut != nil && len(string(shortcut)) > 0 {
		clicked = im.MenuItem(item_lbl, shortcut)
	} else {
		clicked = im.MenuItem(item_lbl)
	}
	if clicked {
		set_clipboard_with_feedback(feedback_id, copy_text)
		return true
	}
	return false
}

// Draws a diagnostic / compiler error row that can be clicked to jump AND
// copied either via its inline copy button or right-click context menu.
diagnostic_row :: proc(
	id: string,
	severity_color: im.Vec4,
	severity_icon: cstring,
	severity_label: string,
	location: string,
	message: string,
	copy_payload := "",
) -> (jumped: bool, copied: bool) {
	im.PushID(strings.clone_to_cstring(id, context.temp_allocator))
	defer im.PopID()

	full_copy := copy_payload
	if full_copy == "" {
		if location != "" {
			full_copy = fmt.tprintf("[%s] %s: %s", severity_label, location, message)
		} else {
			full_copy = fmt.tprintf("[%s] %s", severity_label, message)
		}
	}

	avail_w := im.GetContentRegionAvail().x
	copy_btn_w := im.GetFrameHeight()
	row_w := max(f32(80.0), avail_w - copy_btn_w - im.GetStyle().ItemSpacing.x)

	im.PushStyleColorImVec4(.Header, thm.with_alpha(severity_color, 0.14))
	im.PushStyleColorImVec4(.HeaderHovered, thm.with_alpha(severity_color, 0.24))
	im.PushStyleColorImVec4(.HeaderActive, thm.with_alpha(severity_color, 0.34))

	row_title := fmt.ctprintf("%s %s", severity_icon, severity_label)
	if location != "" {
		row_title = fmt.ctprintf("%s %s  %s", severity_icon, severity_label, location)
	}

	if im.Selectable(row_title, false, {}, {row_w, 0}) {
		jumped = true
	}
	im.PopStyleColor(3)

	if im.BeginPopupContextItem("##diag_ctx") {
		popup_header(severity_icon, location != "" ? location : severity_label, severity_color)
		if menu_copy_item("Copy Message", message, id) do copied = true
		if menu_copy_item("Copy Full Diagnostic", full_copy, id) do copied = true
		im.EndPopup()
	}
	tooltip("Click to jump to location  |  Right-click for Copy menu")

	im.SameLine(0, im.GetStyle().ItemSpacing.x)
	if copy_flash_button(id, full_copy, btn_id = "##copy_diag", tooltip_idle = "Copy diagnostic to clipboard") {
		copied = true
	}

	im.Indent(14.0)
	text_colored(severity_color, message)
	im.Unindent(14.0)

	return
}

// Renders a single colored ImGui MenuItem safely (always pops style color before returning).
menu_item_colored :: proc(
	label: cstring,
	text_color: im.Vec4,
	shortcut: cstring = nil,
	selected := false,
	enabled := true,
) -> bool {
	im.PushStyleColorImVec4(.Text, text_color)
	clicked := im.MenuItem(label, shortcut, selected, enabled)
	im.PopStyleColor(1)
	return clicked
}

@(private)
_derive_button_states :: proc(bg_color: im.Vec4) -> (hv, act: im.Vec4) {
	p := thm.palette()
	if bg_color.w < 0.85 {
		hv_a := clamp(bg_color.w + 0.14, bg_color.w, 0.92)
		act_a := clamp(bg_color.w + 0.24, bg_color.w, 0.98)
		tint := p.is_light ? thm.rgb(0x000000) : thm.rgb(0xFFFFFF)
		hv = thm.with_alpha(thm.lerp_col(bg_color, tint, 0.08), hv_a)
		act = thm.with_alpha(thm.lerp_col(bg_color, tint, 0.14), act_a)
		return
	}
	if p.is_light {
		hv = thm.with_alpha(thm.lerp_col(bg_color, thm.rgb(0x000000), 0.10), bg_color.w)
		act = thm.with_alpha(thm.lerp_col(bg_color, thm.rgb(0x000000), 0.20), bg_color.w)
		return
	}
	hv = thm.with_alpha(thm.lerp_col(bg_color, thm.rgb(0xFFFFFF), 0.14), bg_color.w)
	act = thm.with_alpha(thm.lerp_col(bg_color, thm.rgb(0x000000), 0.16), bg_color.w)
	return
}

@(private)
_contrast_button_fg :: proc(bg: im.Vec4) -> im.Vec4 {
	p := thm.palette()
	if bg.w < 0.85 do return p.text_primary
	white := im.Vec4{1, 1, 1, 1}
	return thm.contrast_ratio(white, bg) >= thm.contrast_ratio(p.text_primary, bg) ? white : p.text_primary
}

@(private)
_push_colored_button :: proc(bg_color, text_color: im.Vec4) -> i32 {
	hv, act := _derive_button_states(bg_color)
	im.PushStyleColorImVec4(.Button, bg_color)
	im.PushStyleColorImVec4(.ButtonHovered, hv)
	im.PushStyleColorImVec4(.ButtonActive, act)
	count: i32 = 3
	if text_color.w > 0 {
		im.PushStyleColorImVec4(.Text, text_color)
		count += 1
	}
	return count
}

@(private)
_push_toggle_style :: proc(active: bool, active_bg: im.Vec4, dim_inactive_text: bool) -> i32 {
	p := thm.palette()
	if active {
		bg := active_bg.w > 0 ? active_bg : p.accent_soft
		hv, act := _derive_button_states(bg)
		im.PushStyleColorImVec4(.Button, bg)
		im.PushStyleColorImVec4(.ButtonHovered, hv)
		im.PushStyleColorImVec4(.ButtonActive, act)
		im.PushStyleColorImVec4(.Text, _contrast_button_fg(bg))
		im.PushStyleColorImVec4(.Border, p.accent)
		return 5
	}
	if dim_inactive_text {
		im.PushStyleColorImVec4(.Text, p.text_muted)
		return 1
	}
	return 0
}

// Renders a themed colored ImGui Button safely (always pops style colors before returning).
button_colored :: proc(label: cstring, bg_color: im.Vec4, size := im.Vec2{}, text_color := im.Vec4{}) -> bool {
	n := _push_colored_button(bg_color, text_color)
	clicked := im.Button(label, size)
	im.PopStyleColor(n)
	return clicked
}

// Renders a colored ImGui SmallButton safely (always pops style colors before returning).
small_button_colored :: proc(label: cstring, bg_color: im.Vec4, text_color := im.Vec4{}) -> bool {
	n := _push_colored_button(bg_color, text_color)
	clicked := im.SmallButton(label)
	im.PopStyleColor(n)
	return clicked
}

// Renders a stateful toggle Button with 5 theme tokens when active.
toggle_button :: proc(
	label: cstring,
	active: bool,
	size := im.Vec2{},
	active_bg := im.Vec4{},
	dim_inactive_text := false,
) -> bool {
	n := _push_toggle_style(active, active_bg, dim_inactive_text)
	clicked := im.Button(label, size)
	if n > 0 do im.PopStyleColor(n)
	return clicked
}

// Renders a stateful toggle SmallButton with 5 theme tokens when active.
small_toggle_button :: proc(
	label: cstring,
	active: bool,
	active_bg := im.Vec4{},
	dim_inactive_text := false,
) -> bool {
	n := _push_toggle_style(active, active_bg, dim_inactive_text)
	clicked := im.SmallButton(label)
	if n > 0 do im.PopStyleColor(n)
	return clicked
}

@(private = "file")
_end_scoped_style_color :: proc(count: i32) {
	if count > 0 do im.PopStyleColor(count)
}

// Scoped style color push backed by Odin's `@(deferred_out)` so early `return`,
// `break`, or `continue` automatically pops the pushed style color on scope exit.
@(deferred_out = _end_scoped_style_color)
scoped_style_color :: proc(idx: im.Col, col: im.Vec4) -> i32 {
	im.PushStyleColorImVec4(idx, col)
	return 1
}
