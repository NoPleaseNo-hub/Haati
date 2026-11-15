package crash_journal

// Shared signal-safe crash journal state, path builder, fixed-buffer writers,
// and UTC date formatting shared across OS-specific handlers.

import "base:intrinsics"
import "base:runtime"
import "core:os"

CRASH_MAX_FRAMES     :: 64
CRASH_BREADCRUMB_MAX :: 256
CRASH_DIR            :: "logs"

@(private = "package")
_crash: struct {
	installed:      bool,
	in_handler:     bool,
	frames:         [CRASH_MAX_FRAMES]rawptr,
	breadcrumb:     [CRASH_BREADCRUMB_MAX]byte,
	breadcrumb_len: int,
	path:           [256]byte, // logs/crash_<pid>.log, built once at init
	path_len:       int,
	last_path:      [256]byte, // logs/crash_last.log, built once at init
	last_path_len:  int,
	version:        [64]byte, // handed to init, written in the header
	version_len:    int,
	out_buf:        [16384]byte,
	out_len:        int,
}

@(private = "package")
_crash_common_init :: proc(version: string) -> (already_installed: bool) {
	// The version updates even on a repeat call — only handler install is once-only.
	v := version
	for len(v) > 0 && (v[len(v) - 1] == '\n' || v[len(v) - 1] == '\r' || v[len(v) - 1] == ' ') {
		v = v[:len(v) - 1]
	}
	n := min(len(v), len(_crash.version))
	copy(_crash.version[:n], v[:n])
	_crash.version_len = n

	if _crash.installed do return true
	_crash.installed = true

	_ = os.make_directory(CRASH_DIR)
	_crash_build_path()
	return false
}

// Records what the process is currently doing. Overwrites the previous one —
// this is the "last known activity", not a trail. Cheap enough to call per
// operation (a copy into fixed storage, no allocation). Safe from any thread
// in the sense that a torn breadcrumb is still better than none.
breadcrumb :: proc(text: string) {
	n := min(len(text), CRASH_BREADCRUMB_MAX)
	copy(_crash.breadcrumb[:n], text[:n])
	_crash.breadcrumb_len = n
}

breadcrumb_clear :: proc() {
	_crash.breadcrumb_len = 0
}

// Install as context.assertion_failure_proc to journal panics and asserts.
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	if !_crash.in_handler {
		_crash.in_handler = true
		_crash_write_assert(prefix, message, loc)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

@(private = "package")
_buf_reset :: proc "contextless" () {
	_crash.out_len = 0
}

@(private = "package")
_w :: proc "contextless" (s: string) {
	if len(s) == 0 do return
	rem := len(_crash.out_buf) - _crash.out_len
	if rem <= 0 do return
	n := min(len(s), rem)
	copy(_crash.out_buf[_crash.out_len:_crash.out_len + n], s[:n])
	_crash.out_len += n
}

@(private = "package")
_w_hex :: proc "contextless" (v: u64) {
	digits := "0123456789abcdef"
	buf: [16]byte
	i := len(buf)
	val := v
	if val == 0 {
		i -= 1
		buf[i] = '0'
	}
	for val > 0 {
		i -= 1
		buf[i] = digits[val & 0xF]
		val >>= 4
	}
	_w(string(buf[i:]))
}

@(private = "package")
_w_int :: proc "contextless" (v: int) {
	buf: [20]byte
	i := len(buf)
	val := v
	if val < 0 {
		_w("-")
		val = -val
	}
	if val == 0 {
		i -= 1
		buf[i] = '0'
	}
	for val > 0 {
		i -= 1
		buf[i] = byte('0' + val % 10)
		val /= 10
	}
	_w(string(buf[i:]))
}

@(private = "package")
_w_utf16 :: proc "contextless" (ws: [^]u16, units := -1, limit := 512) {
	if ws == nil do return
	i := 0
	for i < limit {
		if units >= 0 && i >= units do break
		u := ws[i]
		if u == 0 do break
		i += 1
		cp := u32(u)
		if cp >= 0xD800 && cp <= 0xDBFF && (units < 0 || i < units) {
			lo := u32(ws[i])
			if lo >= 0xDC00 && lo <= 0xDFFF {
				cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
				i += 1
			}
		}
		buf: [4]byte
		if cp < 0x80 {
			buf[0] = byte(cp)
			_w(string(buf[:1]))
		} else if cp < 0x800 {
			buf[0] = byte(0xC0 | (cp >> 6))
			buf[1] = byte(0x80 | (cp & 0x3F))
			_w(string(buf[:2]))
		} else if cp < 0x10000 {
			buf[0] = byte(0xE0 | (cp >> 12))
			buf[1] = byte(0x80 | ((cp >> 6) & 0x3F))
			buf[2] = byte(0x80 | (cp & 0x3F))
			_w(string(buf[:3]))
		} else {
			buf[0] = byte(0xF0 | (cp >> 18))
			buf[1] = byte(0x80 | ((cp >> 12) & 0x3F))
			buf[2] = byte(0x80 | ((cp >> 6) & 0x3F))
			buf[3] = byte(0x80 | (cp & 0x3F))
			_w(string(buf[:4]))
		}
	}
}

@(private = "package")
_w_2d :: proc "contextless" (v: int) {
	buf := [2]byte{byte('0' + v / 10 % 10), byte('0' + v % 10)}
	_w(string(buf[:]))
}

// YYYY-MM-DD HH:MM:SS from unix seconds (Hinnant's civil_from_days).
@(private = "package")
_w_utc :: proc "contextless" (epoch: i64) {
	days := epoch / 86400
	secs := epoch % 86400
	if secs < 0 {
		secs += 86400
		days -= 1
	}
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	if m <= 2 do y += 1

	_w_int(int(y))
	_w("-")
	_w_2d(int(m))
	_w("-")
	_w_2d(int(d))
	_w(" ")
	_w_2d(int(secs / 3600))
	_w(":")
	_w_2d(int(secs / 60 % 60))
	_w(":")
	_w_2d(int(secs % 60))
}

@(private = "package")
_crash_write_header :: proc "contextless" () {
	_w("=== MoonHug crash ===\n")
	if _crash.version_len > 0 {
		_w("version: ")
		_w(string(_crash.version[:_crash.version_len]))
		_w("\n")
	}
	if epoch_sec, ok := _os_epoch_sec(); ok {
		_w("time: ")
		_w_utc(epoch_sec)
		_w(" UTC\n")
	}
}

@(private = "package")
_crash_write_breadcrumb :: proc "contextless" () {
	if _crash.breadcrumb_len <= 0 do return
	_w("doing: ")
	_w(string(_crash.breadcrumb[:_crash.breadcrumb_len]))
	_w("\n")
}

@(private = "package")
_crash_write :: proc "contextless" (reason: string, addr: rawptr, fault_pc: rawptr = nil, fault_lr: rawptr = nil) {
	_buf_reset()
	_crash_write_header()
	_w("reason: ")
	_w(reason)
	_w("\n")
	if addr != nil {
		_w("fault address: 0x")
		_w_hex(u64(uintptr(addr)))
		_w("\n")
	}
	_crash_write_breadcrumb()
	_os_flush_and_stack(fault_pc, fault_lr)
}

@(private = "package")
_crash_write_assert :: proc "contextless" (prefix, message: string, loc: runtime.Source_Code_Location) {
	_buf_reset()
	_crash_write_header()
	_w("reason: ")
	_w(prefix)
	if message != "" {
		_w(": ")
		_w(message)
	}
	_w("\n")
	_w("at: ")
	_w(loc.file_path)
	_w(":")
	_w_int(int(loc.line))
	if loc.procedure != "" {
		_w(" in ")
		_w(loc.procedure)
	}
	_w("\n")
	_crash_write_breadcrumb()
	_os_flush_and_stack(nil, nil)
}

// logs/crash_<pid>.log and logs/crash_last.log, built at init so the handler never formats a path.
@(private = "package")
_crash_build_path :: proc() {
	prefix := CRASH_DIR + "/crash_"
	n := copy(_crash.path[:], prefix)
	pid := os.get_pid()
	digits: [20]byte
	d := len(digits)
	v := pid if pid > 0 else 0
	if v == 0 {
		d -= 1
		digits[d] = '0'
	}
	for v > 0 {
		d -= 1
		digits[d] = byte('0' + v % 10)
		v /= 10
	}
	n += copy(_crash.path[n:], digits[d:])
	n += copy(_crash.path[n:], ".log")
	_crash.path[n] = 0
	_crash.path_len = n

	last_str := CRASH_DIR + "/crash_last.log"
	ln := copy(_crash.last_path[:], last_str)
	_crash.last_path[ln] = 0
	_crash.last_path_len = ln
}

// Test hook: writes a journal entry as if a signal had fired, without
// crashing. Used by the test suite and `crash_journal_selftest`.
write_test_entry :: proc(reason: string) {
	if !_crash.installed {
		init()
	}
	was := _crash.in_handler
	_crash.in_handler = true
	defer _crash.in_handler = was
	_crash_write(reason, nil, nil, nil)
}

path :: proc() -> string {
	if _crash.path_len <= 0 do return ""
	return string(_crash.path[:_crash.path_len])
}

last_path :: proc() -> string {
	if _crash.last_path_len <= 0 do return ""
	return string(_crash.last_path[:_crash.last_path_len])
}

// Deliberate fault — proves the handler works end to end. Only reachable
// from --crash-test.
//
// A plain null-pointer write is NOT usable here: that is undefined behaviour,
// and optimized builds delete it outright (the self-test then "passes" while
// testing nothing). Writing through a volatile-loaded address the compiler
// cannot reason about produces a real SIGSEGV in every build mode.
@(optimization_mode = "none")
test_crash :: proc() {
	breadcrumb("test_crash (deliberate)")
	addr: uintptr = 0x8 // never mapped
	p := (^int)(intrinsics.volatile_load(&addr))
	intrinsics.volatile_store(p, 1)
}
