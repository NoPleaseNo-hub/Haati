package widgets

import "core:strings"
import im "haati:external/odin-imgui"
import engine "../../engine"

buf_str :: engine.buf_str
buf_set :: engine.buf_set
buf_clear :: engine.buf_clear

// Temp-allocated null-terminated string for immediate-mode ImGui calls.
temp_cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

input_text_buf :: proc(label: cstring, buf: []u8, flags: im.InputTextFlags = {}) -> bool {
	if len(buf) == 0 do return false
	return im.InputText(label, cstring(raw_data(buf)), len(buf), flags)
}
