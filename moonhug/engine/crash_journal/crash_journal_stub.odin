#+build !darwin
#+build !linux
package crash_journal

// Windows Crash Journal (STUB-02 Remediation):
// Allocation-free crash journal for Windows with Win32 Vectored Exception Handling
// (`AddVectoredExceptionHandler`), `RtlCaptureStackBackTrace`, UTC timestamping,
// breadcrumb tracking, and full parity with POSIX `crash_journal.odin`.

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:time"
import win32 "core:sys/windows"

CRASH_MAX_FRAMES     :: 64
CRASH_BREADCRUMB_MAX :: 256
CRASH_DIR            :: "logs"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	RtlCaptureStackBackTrace :: proc(
		FramesToSkip:      win32.DWORD,
		FramesToCapture:   win32.DWORD,
		BackTrace:         [^]rawptr,
		BackTraceHash:     ^win32.DWORD,
	) -> win32.WORD ---
}

@(private = "file")
_crash: struct {
	installed:      bool,
	in_handler:     bool,
	veh_handle:     rawptr,
	frames:         [CRASH_MAX_FRAMES]rawptr,
	breadcrumb:     [CRASH_BREADCRUMB_MAX]byte,
	breadcrumb_len: int,
	path:           [256]byte, // logs/crash_<pid>.log
	path_len:       int,
	version:        [64]byte,
	version_len:    int,
	out_buf:        [8192]byte,
	out_len:        int,
}

init :: proc(version := "") {
	v := version
	for len(v) > 0 && (v[len(v) - 1] == '\n' || v[len(v) - 1] == '\r' || v[len(v) - 1] == ' ') {
		v = v[:len(v) - 1]
	}
	n := min(len(v), len(_crash.version))
	copy(_crash.version[:n], v[:n])
	_crash.version_len = n

	if _crash.installed do return
	_crash.installed = true

	_ = os.make_directory(CRASH_DIR)
	_crash_build_path()

	when ODIN_OS == .Windows {
		_crash.veh_handle = win32.AddVectoredExceptionHandler(0, _win_veh_handler)
	}
}

breadcrumb :: proc(text: string) {
	n := min(len(text), CRASH_BREADCRUMB_MAX)
	copy(_crash.breadcrumb[:n], text[:n])
	_crash.breadcrumb_len = n
}

breadcrumb_clear :: proc() {
	_crash.breadcrumb_len = 0
}

assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	if !_crash.in_handler {
		_crash.in_handler = true
		_crash_write_assert(prefix, message, loc)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

when ODIN_OS == .Windows {
	@(private = "file")
	_win_veh_handler :: proc "system" (ep: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
		if ep == nil || ep.ExceptionRecord == nil {
			return win32.EXCEPTION_CONTINUE_SEARCH
		}
		code := ep.ExceptionRecord.ExceptionCode
		reason: string
		switch code {
		case win32.EXCEPTION_ACCESS_VIOLATION:     reason = "EXCEPTION_ACCESS_VIOLATION (invalid memory reference)"
		case win32.EXCEPTION_IN_PAGE_ERROR:        reason = "EXCEPTION_IN_PAGE_ERROR (bad memory access)"
		case win32.EXCEPTION_ILLEGAL_INSTRUCTION:  reason = "EXCEPTION_ILLEGAL_INSTRUCTION (illegal instruction)"
		case win32.EXCEPTION_INT_DIVIDE_BY_ZERO:   reason = "EXCEPTION_INT_DIVIDE_BY_ZERO (integer divide by zero)"
		case win32.EXCEPTION_FLT_DIVIDE_BY_ZERO:   reason = "EXCEPTION_FLT_DIVIDE_BY_ZERO (float divide by zero)"
		case win32.EXCEPTION_STACK_OVERFLOW:       reason = "EXCEPTION_STACK_OVERFLOW (stack overflow)"
		case win32.EXCEPTION_ARRAY_BOUNDS_EXCEEDED:reason = "EXCEPTION_ARRAY_BOUNDS_EXCEEDED"
		case win32.EXCEPTION_DATATYPE_MISALIGNMENT:reason = "EXCEPTION_DATATYPE_MISALIGNMENT"
		case:
			// Ignore non-fatal exceptions (e.g. OutputDebugString, C++ exceptions, thread naming)
			return win32.EXCEPTION_CONTINUE_SEARCH
		}

		if !_crash.in_handler {
			_crash.in_handler = true
			context = runtime.default_context()
			addr := ep.ExceptionRecord.ExceptionAddress
			_crash_write(reason, addr, addr)
		}
		return win32.EXCEPTION_CONTINUE_SEARCH
	}
}

@(private = "file")
_buf_reset :: proc "contextless" () {
	_crash.out_len = 0
}

@(private = "file")
_w :: proc "contextless" (s: string) {
	if len(s) == 0 do return
	rem := len(_crash.out_buf) - _crash.out_len
	if rem <= 0 do return
	n := min(len(s), rem)
	copy(_crash.out_buf[_crash.out_len:_crash.out_len + n], s[:n])
	_crash.out_len += n
}

@(private = "file")
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

@(private = "file")
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

@(private = "file")
_w_2d :: proc "contextless" (v: int) {
	buf := [2]byte{byte('0' + v / 10 % 10), byte('0' + v % 10)}
	_w(string(buf[:]))
}

// YYYY-MM-DD HH:MM:SS from unix seconds (Hinnant's civil_from_days).
@(private = "file")
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

@(private = "file")
_crash_write_header :: proc() {
	_w("=== MoonHug crash ===\n")
	if _crash.version_len > 0 {
		_w("version: ")
		_w(string(_crash.version[:_crash.version_len]))
		_w("\n")
	}
	now_ns := time.now()._nsec
	epoch_sec := now_ns / 1_000_000_000
	if epoch_sec <= 0 do epoch_sec = 1794240000
	_w("time: ")
	_w_utc(epoch_sec)
	_w(" UTC\n")
}

@(private = "file")
_crash_write_breadcrumb :: proc "contextless" () {
	if _crash.breadcrumb_len <= 0 do return
	_w("doing: ")
	_w(string(_crash.breadcrumb[:_crash.breadcrumb_len]))
	_w("\n")
}

@(private = "file")
_crash_write_stack :: proc(fault_pc: rawptr) {
	_w("stack:\n")
	n := 0
	if fault_pc != nil {
		_crash.frames[n] = fault_pc
		n += 1
	}
	when ODIN_OS == .Windows {
		scratch: [CRASH_MAX_FRAMES]rawptr
		captured := int(RtlCaptureStackBackTrace(2, CRASH_MAX_FRAMES, raw_data(scratch[:]), nil))
		for i in 0 ..< captured {
			if n >= CRASH_MAX_FRAMES do break
			f := scratch[i]
			if f == nil || f == fault_pc do continue
			_crash.frames[n] = f
			n += 1
		}
	}
	if n <= 0 {
		_w("  <unavailable; see 'at:' above>\n")
		return
	}
	for i in 0 ..< n {
		_w("  #")
		_w_int(i)
		_w(" 0x")
		_w_hex(u64(uintptr(_crash.frames[i])))
		_w("\n")
	}
}

@(private = "file")
_crash_flush_file :: proc() {
	if _crash.path_len <= 0 || _crash.out_len <= 0 do return
	p := string(_crash.path[:_crash.path_len])
	_ = os.write_entire_file(p, _crash.out_buf[:_crash.out_len])
}

@(private = "file")
_crash_write :: proc(reason: string, addr: rawptr, fault_pc: rawptr = nil) {
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
	_crash_write_stack(fault_pc)
	_crash_flush_file()
}

@(private = "file")
_crash_write_assert :: proc(prefix, message: string, loc: runtime.Source_Code_Location) {
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
	_crash_write_stack(nil)
	_crash_flush_file()
}

@(private = "file")
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
}

write_test_entry :: proc(reason: string) {
	if !_crash.installed {
		init()
	}
	was := _crash.in_handler
	_crash.in_handler = true
	defer _crash.in_handler = was
	_crash_write(reason, nil, nil)
}

path :: proc() -> string {
	if _crash.path_len <= 0 do return ""
	return string(_crash.path[:_crash.path_len])
}

@(optimization_mode = "none")
test_crash :: proc() {
	breadcrumb("test_crash (deliberate)")
	addr: uintptr = 0x8
	p := (^int)(intrinsics.volatile_load(&addr))
	intrinsics.volatile_store(p, 1)
}
