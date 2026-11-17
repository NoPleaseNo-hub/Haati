#+build !darwin
#+build !linux
package crash_journal

// Windows Crash Journal: `SetUnhandledExceptionFilter` (+ stack-overflow VEH),
// SIGABRT, `RtlCaptureStackBackTrace` + `DbgHelp` symbolication (`SymFromAddrW`
// / `SymGetLineFromAddrW64`), and zero-heap Win32 `WriteFile` flushing to both
// `logs/crash_<pid>.log` and `logs/crash_last.log`.

import "base:runtime"
import "core:c"
import "core:c/libc"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import dbghelp "system:Dbghelp.lib"

SYMOPT_UNDNAME :: win32.DWORD(0x00000002)

@(default_calling_convention = "system")
foreign kernel32 {
	RtlCaptureStackBackTrace :: proc(
		FramesToSkip:    win32.DWORD,
		FramesToCapture: win32.DWORD,
		BackTrace:       [^]rawptr,
		BackTraceHash:   ^win32.DWORD,
	) -> win32.WORD ---
}

@(default_calling_convention = "system")
foreign dbghelp {
	SymRefreshModuleList :: proc(hProcess: win32.HANDLE) -> win32.BOOL ---
}

@(private = "file")
_win_veh_handle: rawptr
@(private = "file")
_syms_ready: bool
@(private = "file")
_in_stack_overflow: bool
@(private = "file")
_win_path_w: [260]u16
@(private = "file")
_win_last_path_w: [260]u16
@(private = "file")
_sym_buf: [size_of(win32.SYMBOL_INFOW) + 256 * size_of(u16)]byte
@(private = "file")
_line_info: win32.IMAGEHLP_LINE64

@(private = "file")
_copy_ascii_w :: proc(dst: []u16, src: []byte) {
	if len(dst) == 0 do return
	n := min(len(src), len(dst) - 1)
	for i in 0 ..< n {
		dst[i] = u16(src[i])
	}
	dst[n] = 0
}

init :: proc(version := "") {
	if _crash_common_init(version) do return

	when ODIN_OS == .Windows {
		if _crash.path_len > 0 {
			_copy_ascii_w(_win_path_w[:], _crash.path[:_crash.path_len])
		}
		if _crash.last_path_len > 0 {
			_copy_ascii_w(_win_last_path_w[:], _crash.last_path[:_crash.last_path_len])
		}
		win32.SymSetOptions(win32.SYMOPT_LOAD_LINES | win32.SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME)
		_syms_ready = bool(win32.SymInitialize(win32.GetCurrentProcess(), nil, win32.TRUE))
		// Primary fatal handler: UnhandledExceptionFilter avoids first-chance
		// exceptions caught intentionally by drivers or OS libraries.
		win32.SetUnhandledExceptionFilter(_win_unhandled_filter)
		// Stack overflow cannot unwind to the top-level filter, so keep a
		// narrow VEH strictly for EXCEPTION_STACK_OVERFLOW.
		_win_veh_handle = win32.AddVectoredExceptionHandler(1, _win_veh_handler)
	}
	libc.signal(libc.SIGABRT, _c_sigabrt_handler)
}

refresh_symbols :: proc() {
	when ODIN_OS == .Windows {
		if _syms_ready {
			_ = SymRefreshModuleList(win32.GetCurrentProcess())
		}
	}
}

@(private = "package")
_ensure_sandbox_veh_installed :: proc() {
	when ODIN_OS == .Windows {
		if _win_veh_handle == nil {
			_win_veh_handle = win32.AddVectoredExceptionHandler(1, _win_veh_handler)
		}
	}
}

@(private = "file")
_c_sigabrt_handler :: proc "c" (_sig: c.int) {
	if !_crash.in_handler {
		_crash.in_handler = true
		_crash_write("SIGABRT (C/C++ abort or assertion failure)", nil, nil)
	}
}

when ODIN_OS == .Windows {
	@(private = "file")
	_fatal_exception_reason :: proc "contextless" (code: win32.DWORD) -> (reason: string, fatal: bool) {
		switch code {
		case win32.EXCEPTION_ACCESS_VIOLATION:      return "EXCEPTION_ACCESS_VIOLATION (invalid memory reference)", true
		case win32.EXCEPTION_IN_PAGE_ERROR:         return "EXCEPTION_IN_PAGE_ERROR (bad memory access)", true
		case win32.EXCEPTION_ILLEGAL_INSTRUCTION:   return "EXCEPTION_ILLEGAL_INSTRUCTION (illegal instruction)", true
		case win32.EXCEPTION_INT_DIVIDE_BY_ZERO:    return "EXCEPTION_INT_DIVIDE_BY_ZERO (integer divide by zero)", true
		case win32.EXCEPTION_FLT_DIVIDE_BY_ZERO:    return "EXCEPTION_FLT_DIVIDE_BY_ZERO (float divide by zero)", true
		case win32.EXCEPTION_STACK_OVERFLOW:        return "EXCEPTION_STACK_OVERFLOW (stack overflow)", true
		case win32.EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "EXCEPTION_ARRAY_BOUNDS_EXCEEDED", true
		case win32.EXCEPTION_DATATYPE_MISALIGNMENT: return "EXCEPTION_DATATYPE_MISALIGNMENT", true
		}
		return "", false
	}

	@(private = "file")
	_win_unhandled_filter :: proc "system" (ep: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
		if ep == nil || ep.ExceptionRecord == nil {
			return win32.EXCEPTION_CONTINUE_SEARCH
		}
		reason, fatal := _fatal_exception_reason(ep.ExceptionRecord.ExceptionCode)
		if !fatal {
			return win32.EXCEPTION_CONTINUE_SEARCH
		}
		if !_crash.in_handler {
			_crash.in_handler = true
			addr := ep.ExceptionRecord.ExceptionAddress
			_crash_write(reason, addr, addr)
		}
		return win32.EXCEPTION_CONTINUE_SEARCH
	}

	@(private = "file")
	_copy_utf8_from_utf16 :: proc "contextless" (dst: []byte, ws: [^]u16, units := -1) -> int {
		if len(dst) == 0 || ws == nil do return 0
		out_i := 0
		in_i  := 0
		for out_i < len(dst) - 4 {
			if units >= 0 && in_i >= units do break
			u := ws[in_i]
			if u == 0 do break
			in_i += 1
			cp := u32(u)
			if cp >= 0xD800 && cp <= 0xDBFF && (units < 0 || in_i < units) {
				lo := u32(ws[in_i])
				if lo >= 0xDC00 && lo <= 0xDFFF {
					cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
					in_i += 1
				}
			}
			if cp < 0x80 {
				dst[out_i] = byte(cp); out_i += 1
			} else if cp < 0x800 {
				dst[out_i] = byte(0xC0 | (cp >> 6)); out_i += 1
				dst[out_i] = byte(0x80 | (cp & 0x3F)); out_i += 1
			} else if cp < 0x10000 {
				dst[out_i] = byte(0xE0 | (cp >> 12)); out_i += 1
				dst[out_i] = byte(0x80 | ((cp >> 6) & 0x3F)); out_i += 1
				dst[out_i] = byte(0x80 | (cp & 0x3F)); out_i += 1
			} else {
				dst[out_i] = byte(0xF0 | (cp >> 18)); out_i += 1
				dst[out_i] = byte(0x80 | ((cp >> 12) & 0x3F)); out_i += 1
				dst[out_i] = byte(0x80 | ((cp >> 6) & 0x3F)); out_i += 1
				dst[out_i] = byte(0x80 | (cp & 0x3F)); out_i += 1
			}
		}
		dst[out_i] = 0
		return out_i
	}

	@(private = "file")
	_win_sandbox_abort_trampoline :: proc "c" () {
		context = runtime.default_context()
		libc.longjmp(&_sandbox_jmp_buf, 1)
	}

	@(private = "file")
	_win_veh_handler :: proc "system" (ep: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
		if ep == nil || ep.ExceptionRecord == nil {
			return win32.EXCEPTION_CONTINUE_SEARCH
		}
		code := ep.ExceptionRecord.ExceptionCode
		if _sandbox_active && ep.ContextRecord != nil && code != win32.EXCEPTION_STACK_OVERFLOW {
			reason, fatal := _fatal_exception_reason(code)
			is_trap := fatal || code == win32.EXCEPTION_BREAKPOINT
			if is_trap {
				if reason == "" && code == win32.EXCEPTION_BREAKPOINT {
					reason = "Runtime Trap / Bounds Check Failure (EXCEPTION_BREAKPOINT)"
				}
				_sandbox_active = false
				_sandbox_fault = {
					occurred = true,
					code     = u32(code),
				}
				_sandbox_fault.reason_len = _sandbox_copy_str(_sandbox_fault.reason[:], reason)
				addr := ep.ExceptionRecord.ExceptionAddress
				if _syms_ready && addr != nil {
					proc_h := win32.GetCurrentProcess()
					_sym_buf = {}
					sym := (^win32.SYMBOL_INFOW)(raw_data(_sym_buf[:]))
					sym.SizeOfStruct = size_of(win32.SYMBOL_INFOW)
					sym.MaxNameLen   = 255
					disp64: win32.DWORD64 = 0
					if win32.SymFromAddrW(proc_h, win32.DWORD64(uintptr(addr)), &disp64, sym) != win32.FALSE {
						_sandbox_fault.proc_len = _copy_utf8_from_utf16(_sandbox_fault.proc_name[:], &sym.Name[0], int(sym.NameLen))
					}
					_line_info = {}
					_line_info.SizeOfStruct = size_of(win32.IMAGEHLP_LINE64)
					disp32: win32.DWORD = 0
					if win32.SymGetLineFromAddrW64(proc_h, win32.DWORD64(uintptr(addr)), &disp32, &_line_info) != win32.FALSE && _line_info.FileName != nil {
						_sandbox_fault.file_len = _copy_utf8_from_utf16(_sandbox_fault.file[:], ([^]u16)(_line_info.FileName), -1)
						_sandbox_fault.line     = i32(_line_info.LineNumber)
					}
				}
				ep.ContextRecord.Rip = u64(uintptr(rawptr(_win_sandbox_abort_trampoline)))
				ep.ContextRecord.Rsp = (ep.ContextRecord.Rsp & ~u64(15)) - 8
				return win32.EXCEPTION_CONTINUE_EXECUTION
			}
		}
		if code != win32.EXCEPTION_STACK_OVERFLOW {
			return win32.EXCEPTION_CONTINUE_SEARCH
		}
		if !_crash.in_handler {
			_crash.in_handler = true
			_in_stack_overflow = true
			addr := ep.ExceptionRecord.ExceptionAddress
			_crash_write("EXCEPTION_STACK_OVERFLOW (stack overflow)", addr, addr)
			_in_stack_overflow = false
		}
		return win32.EXCEPTION_CONTINUE_SEARCH
	}

	@(private = "file")
	_win_write_file :: proc "contextless" (path_w: win32.wstring, data: []byte) {
		if path_w == nil || ([^]u16)(path_w)[0] == 0 || len(data) <= 0 do return
		h := win32.CreateFileW(
			path_w,
			win32.GENERIC_WRITE,
			win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
			nil,
			win32.CREATE_ALWAYS,
			win32.FILE_ATTRIBUTE_NORMAL,
			nil,
		)
		if h == win32.INVALID_HANDLE_VALUE do return
		defer win32.CloseHandle(h)
		written_total := 0
		for written_total < len(data) {
			chunk := min(len(data) - written_total, 65536)
			written: win32.DWORD = 0
			if win32.WriteFile(h, &data[written_total], win32.DWORD(chunk), &written, nil) == win32.FALSE || written == 0 {
				break
			}
			written_total += int(written)
		}
	}
}

@(private = "package")
_os_epoch_sec :: proc "contextless" () -> (i64, bool) {
	when ODIN_OS == .Windows {
		ft: win32.FILETIME
		win32.GetSystemTimeAsFileTime(&ft)
		epoch_sec := win32.FILETIME_as_unix_nanoseconds(ft) / 1_000_000_000
		if epoch_sec <= 0 do return 0, false
		return epoch_sec, true
	}
	return 0, false
}

@(private = "package")
_os_flush_and_stack :: proc "contextless" (fault_pc: rawptr, _fault_lr: rawptr) {
	_w("stack:\n")
	n := 0
	if fault_pc != nil {
		_crash.frames[n] = fault_pc
		n += 1
	}
	when ODIN_OS == .Windows {
		scratch: [CRASH_MAX_FRAMES]rawptr
		captured := int(RtlCaptureStackBackTrace(3, CRASH_MAX_FRAMES, raw_data(scratch[:]), nil))
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
	} else {
		when ODIN_OS == .Windows {
			proc_h := win32.GetCurrentProcess()
		}
		for i in 0 ..< n {
			addr := u64(uintptr(_crash.frames[i]))
			_w("  #")
			_w_int(i)
			_w(" 0x")
			_w_hex(addr)
			when ODIN_OS == .Windows {
				if _syms_ready && !_in_stack_overflow {
					_sym_buf = {}
					sym := (^win32.SYMBOL_INFOW)(raw_data(_sym_buf[:]))
					sym.SizeOfStruct = size_of(win32.SYMBOL_INFOW)
					sym.MaxNameLen = 255
					disp64: win32.DWORD64 = 0
					if win32.SymFromAddrW(proc_h, win32.DWORD64(addr), &disp64, sym) != win32.FALSE {
						_w(" ")
						_w_utf16(&sym.Name[0], int(sym.NameLen), 255)
						if disp64 > 0 {
							_w("+0x")
							_w_hex(u64(disp64))
						}
					}
					_line_info = {}
					_line_info.SizeOfStruct = size_of(win32.IMAGEHLP_LINE64)
					disp32: win32.DWORD = 0
					if win32.SymGetLineFromAddrW64(proc_h, win32.DWORD64(addr), &disp32, &_line_info) != win32.FALSE && _line_info.FileName != nil {
						_w(" (")
						_w_utf16(([^]u16)(_line_info.FileName), -1, 512)
						_w(":")
						_w_int(int(_line_info.LineNumber))
						_w(")")
					}
				}
			}
			_w("\n")
		}
	}

	if _crash.out_len <= 0 do return
	when ODIN_OS == .Windows {
		payload := _crash.out_buf[:_crash.out_len]
		_win_write_file(win32.wstring(&_win_path_w[0]), payload)
		_win_write_file(win32.wstring(&_win_last_path_w[0]), payload)
	}
}
