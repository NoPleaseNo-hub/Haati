package core

import "core:bytes"
import "core:strings"

// Safe bounded readers and writers for fixed `[N]u8` / `[]u8` C-string buffers.
// All procs take `[]u8` (coerced via `buf[:]`) to avoid per-size monomorphization
// and always reserve 1 byte for the trailing NUL terminator on write.

// Reads a NUL-terminated string out of `buf` without ever scanning past `len(buf)`.
buf_str :: #force_inline proc(buf: []u8, trim_space := false) -> string {
	if len(buf) == 0 do return ""
	n := bytes.index_byte(buf, 0)
	s := string(buf[:n if n >= 0 else len(buf)])
	return strings.trim_space(s) if trim_space else s
}

// Copies up to `len(buf)-1` bytes of `src` into `buf`, writes a guaranteed NUL
// terminator at `buf[n]`, and optionally clears unused trailing bytes when `zero_tail` is true.
buf_set :: proc(buf: []u8, src: string, zero_tail := false) -> string {
	if len(buf) == 0 do return ""
	n := min(len(src), len(buf) - 1)
	if n > 0 do copy(buf[:n], src[:n])
	buf[n] = 0
	if zero_tail && n + 1 < len(buf) {
		for i in n + 1 ..< len(buf) {
			buf[i] = 0
		}
	}
	return string(buf[:n])
}

// Clears `buf` to an empty C-string in O(1) (or full zero when `zero_all` is true).
buf_clear :: #force_inline proc(buf: []u8, zero_all := false) {
	if len(buf) == 0 do return
	buf[0] = 0
	if zero_all {
		for i in 1 ..< len(buf) {
			buf[i] = 0
		}
	}
}
