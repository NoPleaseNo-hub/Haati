package widgets

// Type-safe, format-bug-proof ImGui text helpers.
// Routes through im.TextUnformatted(start, end) + Odin fmt.tprintf(..any)
// so untyped Odin strings (icons.ICON_MD_*, MIXED_VALUE_TEXT), 64-bit ints,
// and arbitrary runtime text containing '%' (compiler diagnostics, URLs, paths)
// can never trigger C #c_varargs ABI corruption or vsnprintf crashes.

import "core:fmt"
import im "haati:external/odin-imgui"

text :: proc(s: string) {
	if len(s) == 0 {
		im.TextUnformatted("")
		return
	}
	raw := raw_data(s)
	start := cstring(raw)
	end := cstring(rawptr(uintptr(raw) + uintptr(len(s))))
	im.TextUnformatted(start, end)
}

textf :: proc(format: string, args: ..any) {
	text(fmt.tprintf(format, ..args))
}

text_colored :: proc(col: im.Vec4, s: string) {
	im.PushStyleColorImVec4(.Text, col)
	text(s)
	im.PopStyleColor()
}

text_coloredf :: proc(col: im.Vec4, format: string, args: ..any) {
	text_colored(col, fmt.tprintf(format, ..args))
}

text_disabled :: proc(s: string) {
	im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
	text(s)
	im.PopStyleColor()
}

text_disabledf :: proc(format: string, args: ..any) {
	text_disabled(fmt.tprintf(format, ..args))
}

text_wrapped :: proc(s: string) {
	im.PushTextWrapPos(0.0)
	text(s)
	im.PopTextWrapPos()
}

text_wrappedf :: proc(format: string, args: ..any) {
	text_wrapped(fmt.tprintf(format, ..args))
}

// Truncates `s` to at most `max_bytes` bytes without splitting a multi-byte UTF-8 sequence.
utf8_safe_prefix :: proc(s: string, max_bytes: int) -> string {
	if max_bytes <= 0 do return ""
	if len(s) <= max_bytes do return s
	end := max_bytes
	for end > 0 && (s[end] & 0xC0) == 0x80 {
		end -= 1
	}
	return s[:end]
}
