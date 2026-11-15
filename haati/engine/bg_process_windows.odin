#+build windows
package engine

// =============================================================================
// SILENT BACKGROUND COMPILER SUBPROCESS RUNNER (Windows `CREATE_NO_WINDOW`)
// =============================================================================
// Spawns background `odin build`, `odin check`, and `mh relaunch` processes with
// `CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT` and `SW_HIDE` so Windows 10/11
// (`conhost.exe` / Windows Terminal) NEVER flashes a console window over the editor!

import "core:strings"
import win "core:sys/windows"

BG_Process :: struct {
	handle: rawptr,
	pid:    int,
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file")
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: uintptr(0x00020002)

@(private = "file")
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(default_calling_convention = "system")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList:  rawptr,
		dwAttributeCount: win.DWORD,
		dwFlags:          win.DWORD,
		lpSize:           ^win.SIZE_T,
	) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: rawptr,
		dwFlags:         win.DWORD,
		Attribute:       uintptr,
		lpValue:         rawptr,
		cbSize:          win.SIZE_T,
		lpPreviousValue: rawptr,
		lpReturnSize:    ^win.SIZE_T,
	) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(
		lpAttributeList: rawptr,
	) ---
}

@(private = "file")
_quote_win32_arg :: proc(arg: string, b: ^strings.Builder) {
	if len(arg) == 0 {
		strings.write_string(b, `""`)
		return
	}
	needs_quotes := false
	for i := 0; i < len(arg); i += 1 {
		c := arg[i]
		if c == ' ' || c == '\t' || c == '"' {
			needs_quotes = true
			break
		}
	}
	if !needs_quotes {
		strings.write_string(b, arg)
		return
	}
	strings.write_byte(b, '"')
	backslashes := 0
	for i := 0; i < len(arg); i += 1 {
		c := arg[i]
		if c == '\\' {
			backslashes += 1
		} else if c == '"' {
			for _ in 0 ..< (backslashes * 2 + 1) {
				strings.write_byte(b, '\\')
			}
			strings.write_byte(b, '"')
			backslashes = 0
		} else {
			for _ in 0 ..< backslashes {
				strings.write_byte(b, '\\')
			}
			backslashes = 0
			strings.write_byte(b, c)
		}
	}
	for _ in 0 ..< (backslashes * 2) {
		strings.write_byte(b, '\\')
	}
	strings.write_byte(b, '"')
}

@(private = "file")
_build_env_block_utf16 :: proc(env: []string) -> rawptr {
	if len(env) == 0 do return nil
	buf := make([dynamic]u16, 0, 1024, context.temp_allocator)
	for kv in env {
		if len(kv) == 0 do continue
		w := win.utf8_to_utf16(kv, context.temp_allocator)
		append(&buf, ..w)
		append(&buf, 0)
	}
	append(&buf, 0)
	append(&buf, 0)
	return raw_data(buf[:])
}

// Spawns a hidden consoleless child process on Windows, optionally redirecting
// both stdout and stderr to `log_file_path` (with `bInheritHandles = TRUE` only when needed).
bg_process_start_to_file :: proc(
	working_dir:   string,
	command:       []string,
	env:           []string = nil,
	log_file_path: string   = "",
) -> (proc_out: BG_Process, ok: bool) {
	if len(command) == 0 do return {}, false

	cmd_builder := strings.builder_make(0, 512, context.temp_allocator)
	for arg, idx in command {
		if idx > 0 do strings.write_byte(&cmd_builder, ' ')
		_quote_win32_arg(arg, &cmd_builder)
	}
	cmd_utf8 := strings.to_string(cmd_builder)
	cmd_w := win.utf8_to_wstring(cmd_utf8, context.temp_allocator)

	cwd_w: win.wstring = nil
	if len(working_dir) > 0 {
		cwd_w = win.utf8_to_wstring(working_dir, context.temp_allocator)
	}

	out_handle: win.HANDLE = win.INVALID_HANDLE_VALUE
	inherit_handles: win.BOOL = win.FALSE

	if len(log_file_path) > 0 {
		sa := win.SECURITY_ATTRIBUTES{
			nLength              = size_of(win.SECURITY_ATTRIBUTES),
			lpSecurityDescriptor = nil,
			bInheritHandle       = win.TRUE,
		}
		log_w := win.utf8_to_wstring(log_file_path, context.temp_allocator)
		out_handle = win.CreateFileW(
			log_w,
			win.GENERIC_WRITE,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
			&sa,
			win.CREATE_ALWAYS,
			win.FILE_ATTRIBUTE_NORMAL,
			nil,
		)
		if out_handle == win.INVALID_HANDLE_VALUE {
			return {}, false
		}
		inherit_handles = win.TRUE
	}
	defer if out_handle != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(out_handle)
	}

	nul_in: win.HANDLE = win.INVALID_HANDLE_VALUE
	if inherit_handles == win.TRUE {
		sa_in := win.SECURITY_ATTRIBUTES{
			nLength        = size_of(win.SECURITY_ATTRIBUTES),
			bInheritHandle = win.TRUE,
		}
		nul_in = win.CreateFileW(
			win.L("NUL"),
			win.GENERIC_READ,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
			&sa_in,
			win.OPEN_EXISTING,
			win.FILE_ATTRIBUTE_NORMAL,
			nil,
		)
	}
	defer if nul_in != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(nul_in)
	}

	si_ex: STARTUPINFOEXW
	si_ex.StartupInfo.cb          = size_of(win.STARTUPINFOW)
	si_ex.StartupInfo.dwFlags     = win.STARTF_USESHOWWINDOW
	si_ex.StartupInfo.wShowWindow = u16(win.SW_HIDE)

	pi: win.PROCESS_INFORMATION
	creation_flags: win.DWORD = win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT
	env_block := _build_env_block_utf16(env)

	inherit_list: [2]win.HANDLE
	attr_buf: []byte
	attr_list_ready := false
	defer if attr_list_ready {
		DeleteProcThreadAttributeList(raw_data(attr_buf))
	}

	if inherit_handles == win.TRUE {
		si_ex.StartupInfo.dwFlags  |= win.STARTF_USESTDHANDLES
		si_ex.StartupInfo.hStdInput  = nul_in
		si_ex.StartupInfo.hStdOutput = out_handle
		si_ex.StartupInfo.hStdError  = out_handle

		// Restrict inherited handles to ONLY out_handle and nul_in (never
		// duplicate handles in PROC_THREAD_ATTRIBUTE_HANDLE_LIST).
		handle_count := 0
		inherit_list[handle_count] = out_handle
		handle_count += 1
		if nul_in != win.INVALID_HANDLE_VALUE && nul_in != out_handle {
			inherit_list[handle_count] = nul_in
			handle_count += 1
		}

		attr_size: win.SIZE_T = 0
		_ = InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
		if attr_size > 0 {
			attr_buf = make([]byte, int(attr_size), context.temp_allocator)
			if InitializeProcThreadAttributeList(raw_data(attr_buf), 1, 0, &attr_size) != win.FALSE {
				attr_list_ready = true
				if UpdateProcThreadAttribute(
					raw_data(attr_buf),
					0,
					PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
					&inherit_list[0],
					win.SIZE_T(handle_count * size_of(win.HANDLE)),
					nil,
					nil,
				) != win.FALSE {
					si_ex.StartupInfo.cb = size_of(STARTUPINFOEXW)
					si_ex.lpAttributeList = raw_data(attr_buf)
					creation_flags |= win.EXTENDED_STARTUPINFO_PRESENT
				}
			}
		}
	}

	started := win.CreateProcessW(
		nil,
		cmd_w,
		nil,
		nil,
		inherit_handles,
		creation_flags,
		env_block,
		cwd_w,
		&si_ex.StartupInfo,
		&pi,
	)
	if !started {
		return {}, false
	}

	if pi.hThread != nil && pi.hThread != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(pi.hThread)
	}
	return BG_Process{
		handle = rawptr(pi.hProcess),
		pid    = int(pi.dwProcessId),
	}, true
}

// Non-blocking poll (`0 ms`). Closes the kernel handle automatically when exited.
bg_process_poll :: proc(p: ^BG_Process) -> (exited: bool, exit_code: int) {
	if p == nil || p.handle == nil do return true, 0
	h := win.HANDLE(p.handle)
	res := win.WaitForSingleObject(h, 0)
	if res == win.WAIT_TIMEOUT {
		return false, 0
	}
	code: win.DWORD = 0
	_ = win.GetExitCodeProcess(h, &code)
	win.CloseHandle(h)
	p^ = {}
	return true, int(code)
}

// Blocking wait up to `timeout_ms`. Kills and closes handle on timeout.
bg_process_wait :: proc(p: ^BG_Process, timeout_ms: u32 = 25000) -> (exited: bool, exit_code: int) {
	if p == nil || p.handle == nil do return true, 0
	h := win.HANDLE(p.handle)
	res := win.WaitForSingleObject(h, timeout_ms)
	if res == win.WAIT_TIMEOUT {
		_ = win.TerminateProcess(h, 1)
		_ = win.WaitForSingleObject(h, 250)
		win.CloseHandle(h)
		p^ = {}
		return false, -1
	}
	code: win.DWORD = 0
	_ = win.GetExitCodeProcess(h, &code)
	win.CloseHandle(h)
	p^ = {}
	return true, int(code)
}

bg_process_kill :: proc(p: ^BG_Process) {
	if p == nil || p.handle == nil do return
	h := win.HANDLE(p.handle)
	_ = win.TerminateProcess(h, 1)
	win.CloseHandle(h)
	p^ = {}
}
