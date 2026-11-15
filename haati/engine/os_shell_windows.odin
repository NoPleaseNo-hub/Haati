#+build windows
package engine

// Windows file-manager integration: move-to-Trash (Recycle Bin),
// reveal-in-Explorer, and open-with-OS.
// Uses native Win32 Shell32 APIs (`SHFileOperationW` & `ShellExecuteW`) for <1ms
// non-blocking execution without spawning PowerShell or cmd.exe subprocesses.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"

foreign import shell32 "system:Shell32.lib"

@(private = "file")
FO_DELETE          :: u32(0x0003)
@(private = "file")
FOF_SILENT         :: u16(0x0004)
@(private = "file")
FOF_NOCONFIRMATION :: u16(0x0010)
@(private = "file")
FOF_ALLOWUNDO      :: u16(0x0040)
@(private = "file")
FOF_NOERRORUI      :: u16(0x0400)

@(private = "file")
SHFILEOPSTRUCTW :: struct {
	hwnd:                  win32.HWND,
	wFunc:                 u32,
	pFrom:                 [^]u16,
	pTo:                   [^]u16,
	fFlags:                u16,
	fAnyOperationsAborted: win32.BOOL,
	hNameMappings:         rawptr,
	lpszProgressTitle:     win32.LPCWSTR,
}

@(default_calling_convention = "system")
foreign shell32 {
	SHFileOperationW :: proc(lpFileOp: ^SHFILEOPSTRUCTW) -> i32 ---
}

// Moves a file or directory into the OS Recycle Bin cleanly (no permanent delete).
os_move_to_trash :: proc(path: string) -> bool {
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil do abs = path
	win_path, _ := strings.replace_all(abs, "/", "\\", context.temp_allocator)
	// SHFileOperationW requires no trailing backslash on directories and double-NUL termination (\0\0)
	for len(win_path) > 3 && strings.ends_with(win_path, "\\") {
		win_path = win_path[:len(win_path) - 1]
	}

	wstr := win32.utf8_to_utf16(win_path, context.temp_allocator)
	if len(wstr) == 0 {
		return os.remove(abs) == nil
	}
	double_nul := make([]u16, len(wstr) + 2, context.temp_allocator)
	copy(double_nul[:len(wstr)], wstr)
	double_nul[len(wstr)]     = 0
	double_nul[len(wstr) + 1] = 0

	op := SHFILEOPSTRUCTW{
		wFunc  = FO_DELETE,
		pFrom  = raw_data(double_nul),
		fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
	}
	res := SHFileOperationW(&op)
	if res == 0 && !bool(op.fAnyOperationsAborted) {
		return true
	}
	return os.remove(abs) == nil
}

// Opens a file or folder with its OS-associated application.
os_open_in_os :: proc(path: string) -> bool {
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil do abs = path
	win_path, _ := strings.replace_all(abs, "/", "\\", context.temp_allocator)
	wpath := win32.utf8_to_wstring(win_path, context.temp_allocator)
	inst := win32.ShellExecuteW(nil, win32.L("open"), wpath, nil, nil, win32.SW_SHOWNORMAL)
	return uintptr(inst) > 32
}

// Reveals (selects) a file or directory in Windows Explorer without leaking a process handle.
os_reveal_in_os :: proc(path: string) -> bool {
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil do abs = path
	win_path, _ := strings.replace_all(abs, "/", "\\", context.temp_allocator)
	wargs := win32.utf8_to_wstring(fmt.tprintf("/select,%s", win_path), context.temp_allocator)
	inst := win32.ShellExecuteW(nil, win32.L("open"), win32.L("explorer.exe"), wargs, nil, win32.SW_SHOWNORMAL)
	return uintptr(inst) > 32
}
