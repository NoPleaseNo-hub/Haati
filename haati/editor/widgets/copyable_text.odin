package widgets

// Copyable Text & Code Block Widgets.
// Enables mouse drag-to-highlight text selection, Ctrl+C copying,
// and one-click clipboard buttons for developer guides, code snippets, and telemetry.

import "core:fmt"
import "core:strings"
import im "haati:external/odin-imgui"
import icons "haati:editor/icons"
import thm "haati:editor/theme"

@(private = "file")
_copied_feedback_id: string
@(private = "file")
_copied_feedback_until: f64

// Copies text to the OS clipboard and triggers visual "Copied!" feedback for 1.8s
set_clipboard_with_feedback :: proc(id: string, text: string) {
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	im.SetClipboardText(cstr)
	_copied_feedback_id = id
	_copied_feedback_until = im.GetTime() + 1.8
}

is_copied_feedback_active :: proc(id: string) -> bool {
	return _copied_feedback_id == id && im.GetTime() < _copied_feedback_until
}

// Single-line drag-to-highlight copyable text.
// Supports mouse drag selection, Ctrl+A to select all, Ctrl+C to copy,
// plus an optional one-click "Copy" icon button on the right.
copyable_text :: proc(
	id: string,
	text: string,
	copy_button: bool = true,
	loc := #caller_location,
) -> bool {
	im.PushID(strings.clone_to_cstring(id, context.temp_allocator))
	defer im.PopID()

	btn_w: f32 = copy_button ? 30.0 : 0.0
	spacing := im.GetStyle().ItemSpacing.x
	avail_w := im.GetContentRegionAvail().x
	text_w := max(f32(60.0), avail_w - (copy_button ? (btn_w + spacing) : 0.0))

	p := thm.palette()
	im.PushStyleColorImVec4(.FrameBg, p.bg_recessed)
	im.PushStyleColorImVec4(.FrameBgHovered, p.bg_hover)
	im.PushStyleColorImVec4(.FrameBgActive, p.bg_active)
	im.PushStyleColorImVec4(.Text, p.accent)
	im.PushStyleVar(.FrameRounding, 4.0)

	im.SetNextItemWidth(text_w)
	buf_cstr := strings.clone_to_cstring(text, context.temp_allocator)
	im.InputText("##Text", buf_cstr, uint(len(text) + 1), {.ReadOnly, .AutoSelectAll})
	tooltip("Drag to select text, Ctrl+C to copy, or double-click to select word", {}, loc)

	im.PopStyleVar()
	im.PopStyleColor(4)

	copied := false
	if copy_button {
		im.SameLine(0, spacing)
		copied = copy_flash_button(id, text, btn_id = "##CopyBtn", btn_w = btn_w, use_text_button = true, tooltip_idle = "Copy text to clipboard", tooltip_copied = "Copied to clipboard!", loc = loc)
	}

	return copied
}

// Reusable clipboard copy button with temporary green "Copied!" flash state.
copy_flash_button :: proc(
	id: string,
	copy_payload: string,
	btn_id: cstring = "##CopyFlash",
	small := false,
	show_label := false,
	btn_w: f32 = 0,
	use_text_button := false,
	tooltip_idle: cstring = "Copy to clipboard",
	tooltip_copied: cstring = "Copied!",
	loc := #caller_location,
) -> bool {
	p := thm.palette()
	is_copied := is_copied_feedback_active(id)
	clicked := false

	if small || show_label || use_text_button {
		lbl: cstring
		if show_label {
			lbl = is_copied ? fmt.ctprintf("%s Copied!%s", icons.ICON_MD_CHECK, btn_id) : fmt.ctprintf("%s Copy%s", icons.ICON_MD_CONTENT_COPY, btn_id)
		} else {
			lbl = is_copied ? fmt.ctprintf("%s%s", icons.ICON_MD_CHECK, btn_id) : fmt.ctprintf("%s%s", icons.ICON_MD_CONTENT_COPY, btn_id)
		}
		if is_copied {
			im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_success, 0.28))
			im.PushStyleColorImVec4(.Text, p.status_success)
			clicked = small ? im.SmallButton(lbl) : im.Button(lbl, {btn_w, 0})
			im.PopStyleColor(2)
		} else {
			im.PushStyleColorImVec4(.Button, p.bg_elevated)
			im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
			im.PushStyleColorImVec4(.Text, p.text_secondary)
			clicked = small ? im.SmallButton(lbl) : im.Button(lbl, {btn_w, 0})
			im.PopStyleColor(3)
		}
		tooltip(is_copied ? tooltip_copied : tooltip_idle, {}, loc)
	} else {
		btn_icon := cstring(is_copied ? icons.ICON_MD_CHECK : icons.ICON_MD_CONTENT_COPY)
		if is_copied do im.PushStyleColorImVec4(.Text, p.status_success)
		clicked = icon_button(btn_icon, btn_id, is_copied ? tooltip_copied : tooltip_idle, size = btn_w, loc = loc)
		if is_copied do im.PopStyleColor()
	}

	if clicked {
		set_clipboard_with_feedback(id, copy_payload)
	}
	return clicked
}

// Read-only multiline text field backed by a persistent byte buffer (`buf` must stay
// valid and null-terminated for the draw call).
readonly_multiline_buf :: proc(
	id: cstring,
	buf: []u8,
	size := im.Vec2{-1, -1},
	word_wrap := false,
	frame_pad := im.Vec2{-1, -1},
	bg_col := im.Vec4{-1, 0, 0, 0},
	text_col := im.Vec4{-1, 0, 0, 0},
) {
	if len(buf) == 0 do return
	flags: im.InputTextFlags = {.ReadOnly}
	if word_wrap do flags += {.WordWrap}

	var_cnt: i32 = 0
	if frame_pad.x >= 0 {
		im.PushStyleVarImVec2(.FramePadding, frame_pad)
		var_cnt += 1
	}
	col_cnt: i32 = 0
	if bg_col.x >= 0 {
		im.PushStyleColorImVec4(.FrameBg, bg_col)
		col_cnt += 1
	}
	if text_col.x >= 0 {
		im.PushStyleColorImVec4(.Text, text_col)
		col_cnt += 1
	}

	im.InputTextMultiline(id, cstring(raw_data(buf)), uint(len(buf)), size, flags)

	if col_cnt > 0 do im.PopStyleColor(col_cnt)
	if var_cnt > 0 do im.PopStyleVar(var_cnt)
}

// Read-only multiline text field cloned into temp storage for immediate drawing.
readonly_multiline :: proc(
	id: cstring,
	text: string,
	size := im.Vec2{-1, -1},
	word_wrap := false,
	frame_pad := im.Vec2{-1, -1},
	bg_col := im.Vec4{-1, 0, 0, 0},
	text_col := im.Vec4{-1, 0, 0, 0},
) {
	buf := make([]u8, len(text) + 1, context.temp_allocator)
	if len(text) > 0 do copy(buf[:len(text)], text)
	buf[len(text)] = 0
	readonly_multiline_buf(id, buf, size, word_wrap, frame_pad, bg_col, text_col)
}

// Multi-line code block with optional title header and "Copy Code" button.
// Users can drag-select any code snippet or click "Copy" to grab the entire block.
copyable_code_block :: proc(
	id: string,
	code: string,
	title: string = "",
	height: f32 = 0,
	loc := #caller_location,
) -> bool {
	im.PushID(strings.clone_to_cstring(id, context.temp_allocator))
	defer im.PopID()

	p := thm.palette()
	copied := false

	avail_w := im.GetContentRegionAvail().x
	btn_w: f32 = is_copied_feedback_active(id) ? 86.0 : 76.0

	// Header bar with title on left and Copy button on right
	if len(title) > 0 {
		text_colored(p.status_warning, title)
		im.SameLine(0, 0)
		if avail_w > btn_w + 40.0 {
			im.SetCursorPosX(im.GetCursorPosX() + avail_w - btn_w - 4.0)
		}
	} else {
		if avail_w > btn_w + 10.0 {
			im.SetCursorPosX(im.GetCursorPosX() + avail_w - btn_w - 4.0)
		}
	}

	if copy_flash_button(id, code, btn_id = "##CopyBlock", small = true, show_label = true, tooltip_idle = "Copy entire snippet to clipboard", loc = loc) {
		copied = true
	}

	// Calculate auto-height based on line count if not explicitly set
	line_count := strings.count(code, "\n") + 1
	line_h := im.GetTextLineHeightWithSpacing()
	auto_h := height > 0 ? height : max(f32(40.0), f32(line_count) * line_h + 16.0)

	im.PushStyleColorImVec4(.FrameBg, p.bg_recessed)
	im.PushStyleColorImVec4(.Text, p.text_primary)
	im.PushStyleVar(.FrameRounding, 4.0)

	readonly_multiline("##CodeBox", code, {-1, auto_h})
	tooltip("Drag across text to select and highlight, Ctrl+C to copy snippet", {}, loc)

	im.PopStyleVar()
	im.PopStyleColor(2)

	return copied
}
