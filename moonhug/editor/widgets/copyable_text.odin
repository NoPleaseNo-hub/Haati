package widgets

// Copyable Text & Code Block Widgets.
// Enables mouse drag-to-highlight text selection, Ctrl+C copying,
// and one-click clipboard buttons for developer guides, code snippets, and telemetry.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import icons "moonhug:editor/icons"

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

	im.PushStyleColorImVec4(.FrameBg, {0.10, 0.12, 0.16, 0.85})
	im.PushStyleColorImVec4(.FrameBgHovered, {0.13, 0.16, 0.22, 0.95})
	im.PushStyleColorImVec4(.FrameBgActive, {0.16, 0.20, 0.28, 1.0})
	im.PushStyleColorImVec4(.Text, {0.35, 0.85, 1.0, 1.0})
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
		is_copied := is_copied_feedback_active(id)

		if is_copied {
			im.PushStyleColorImVec4(.Button, {0.18, 0.55, 0.25, 0.85})
			im.PushStyleColorImVec4(.Text, {0.4, 1.0, 0.5, 1.0})
			if im.Button(fmt.ctprintf("%s##CopyBtn", icons.ICON_MD_CHECK), {btn_w, 0}) {
				set_clipboard_with_feedback(id, text)
				copied = true
			}
			tooltip("Copied to clipboard!", {}, loc)
			im.PopStyleColor(2)
		} else {
			im.PushStyleColorImVec4(.Button, {0.18, 0.22, 0.28, 0.85})
			im.PushStyleColorImVec4(.ButtonHovered, {0.28, 0.35, 0.45, 1.0})
			im.PushStyleColorImVec4(.Text, {0.8, 0.85, 0.9, 1.0})
			if im.Button(fmt.ctprintf("%s##CopyBtn", icons.ICON_MD_CONTENT_COPY), {btn_w, 0}) {
				set_clipboard_with_feedback(id, text)
				copied = true
			}
			tooltip("Copy text to clipboard", {}, loc)
			im.PopStyleColor(3)
		}
	}

	return copied
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

	copied := false
	is_copied := is_copied_feedback_active(id)

	avail_w := im.GetContentRegionAvail().x
	btn_w: f32 = is_copied ? 86.0 : 76.0

	// Header bar with title on left and Copy button on right
	if len(title) > 0 {
		im.TextColored({1.0, 0.82, 0.3, 1.0}, fmt.ctprintf("%s", title))
		im.SameLine(0, 0)
		if avail_w > btn_w + 40.0 {
			im.SetCursorPosX(im.GetCursorPosX() + avail_w - btn_w - 4.0)
		}
	} else {
		if avail_w > btn_w + 10.0 {
			im.SetCursorPosX(im.GetCursorPosX() + avail_w - btn_w - 4.0)
		}
	}

	if is_copied {
		im.PushStyleColorImVec4(.Button, {0.18, 0.55, 0.25, 0.85})
		im.PushStyleColorImVec4(.Text, {0.4, 1.0, 0.5, 1.0})
		if im.SmallButton(fmt.ctprintf("%s Copied!##CopyBlock", icons.ICON_MD_CHECK)) {
			set_clipboard_with_feedback(id, code)
			copied = true
		}
		im.PopStyleColor(2)
	} else {
		im.PushStyleColorImVec4(.Button, {0.20, 0.24, 0.32, 0.85})
		im.PushStyleColorImVec4(.ButtonHovered, {0.28, 0.36, 0.48, 1.0})
		im.PushStyleColorImVec4(.Text, {0.85, 0.90, 0.95, 1.0})
		if im.SmallButton(fmt.ctprintf("%s Copy##CopyBlock", icons.ICON_MD_CONTENT_COPY)) {
			set_clipboard_with_feedback(id, code)
			copied = true
		}
		tooltip("Copy entire snippet to clipboard", {}, loc)
		im.PopStyleColor(3)
	}

	// Calculate auto-height based on line count if not explicitly set
	line_count := strings.count(code, "\n") + 1
	line_h := im.GetTextLineHeightWithSpacing()
	auto_h := height > 0 ? height : max(f32(40.0), f32(line_count) * line_h + 16.0)

	im.PushStyleColorImVec4(.FrameBg, {0.09, 0.10, 0.14, 0.95})
	im.PushStyleColorImVec4(.Text, {0.40, 0.90, 0.65, 1.0})
	im.PushStyleVar(.FrameRounding, 4.0)

	code_cstr := strings.clone_to_cstring(code, context.temp_allocator)
	im.InputTextMultiline("##CodeBox", code_cstr, uint(len(code) + 1), {-1, auto_h}, {.ReadOnly})
	tooltip("Drag across text to select and highlight, Ctrl+C to copy snippet", {}, loc)

	im.PopStyleVar()
	im.PopStyleColor(2)

	return copied
}
