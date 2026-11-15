#+build !darwin
#+build !linux
package crash_journal

// Windows Crash Journal: `SetUnhandledExceptionFilter` (+ stack-overflow VEH),
// SIGABRT, `RtlCaptureStackBackTrace` + `DbgHelp` symbolication (`SymFromAddrW`
// / `SymGetLineFromAddrW64`), and zero-heap Win32 `WriteFile` flushing to both
// `logs/crash_<pid>.log` and `logs/crash_last.log`.

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
	_win_veh_handler :: proc "system" (ep: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
		if ep == nil || ep.ExceptionRecord == nil {
			return win32.EXCEPTION_CONTINUE_SEARCH
		}
		if ep.ExceptionRecord.ExceptionCode != win32.EXCEPTION_STACK_OVERFLOW {
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
