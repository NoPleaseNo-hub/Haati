#+build windows
package overwatch_ipc

import "core:mem"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import psapi "system:Psapi.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	OpenFileMappingW :: proc(
		dwDesiredAccess: win32.DWORD,
		bInheritHandle:  win32.BOOL,
		lpName:          win32.LPCWSTR,
	) -> win32.HANDLE ---
}

PROCESS_MEMORY_COUNTERS :: struct {
	cb:                         win32.DWORD,
	PageFaultCount:             win32.DWORD,
	PeakWorkingSetSize:         uint,
	WorkingSetSize:             uint,
	QuotaPeakPagedPoolUsage:    uint,
	QuotaPagedPoolUsage:        uint,
	QuotaPeakNonPagedPoolUsage: uint,
	QuotaNonPagedPoolUsage:     uint,
	PagefileUsage:              uint,
	PeakPagefileUsage:          uint,
}

@(default_calling_convention = "system")
foreign psapi {
	K32GetProcessMemoryInfo :: proc(
		Process:  win32.HANDLE,
		ppsmemCounters: ^PROCESS_MEMORY_COUNTERS,
		cb:       win32.DWORD,
	) -> win32.BOOL ---
}

SHM_Mapping :: struct {
	handle: win32.HANDLE,
	block:  ^Overwatch_SHM_Block,
}

shm_create :: proc(name: string) -> (m: SHM_Mapping, ok: bool) {
	if name == "" do return {}, false
	wname := win32.utf8_to_wstring(name, context.temp_allocator)
	sz := uint(size_of(Overwatch_SHM_Block))
	h := win32.CreateFileMappingW(
		win32.INVALID_HANDLE_VALUE,
		nil,
		win32.PAGE_READWRITE,
		win32.DWORD(u64(sz) >> 32),
		win32.DWORD(u64(sz) & 0xFFFF_FFFF),
		wname,
	)
	if h == nil || h == win32.INVALID_HANDLE_VALUE do return {}, false

	already_existed := win32.GetLastError() == win32.ERROR_ALREADY_EXISTS
	view := win32.MapViewOfFile(h, win32.FILE_MAP_ALL_ACCESS, 0, 0, sz)
	if view == nil {
		win32.CloseHandle(h)
		return {}, false
	}
	blk := cast(^Overwatch_SHM_Block)view
	if !already_existed {
		mem.zero(blk, int(sz))
	}
	return SHM_Mapping{handle = h, block = blk}, true
}

shm_open :: proc(name: string) -> (m: SHM_Mapping, ok: bool) {
	if name == "" do return {}, false
	wname := win32.utf8_to_wstring(name, context.temp_allocator)
	h := OpenFileMappingW(win32.FILE_MAP_ALL_ACCESS, false, wname)
	if h == nil || h == win32.INVALID_HANDLE_VALUE do return {}, false

	view := win32.MapViewOfFile(h, win32.FILE_MAP_ALL_ACCESS, 0, 0, uint(size_of(Overwatch_SHM_Block)))
	if view == nil {
		win32.CloseHandle(h)
		return {}, false
	}
	return SHM_Mapping{handle = h, block = cast(^Overwatch_SHM_Block)view}, true
}

shm_close :: proc(m: ^SHM_Mapping) {
	if m == nil do return
	if m.block != nil {
		win32.UnmapViewOfFile(m.block)
		m.block = nil
	}
	if m.handle != nil && m.handle != win32.INVALID_HANDLE_VALUE {
		win32.CloseHandle(m.handle)
		m.handle = nil
	}
}

current_working_set_mb :: proc() -> f32 {
	pmc: PROCESS_MEMORY_COUNTERS
	pmc.cb = size_of(PROCESS_MEMORY_COUNTERS)
	if K32GetProcessMemoryInfo(win32.GetCurrentProcess(), &pmc, pmc.cb) {
		return f32(f64(pmc.WorkingSetSize) / (1024.0 * 1024.0))
	}
	return 0
}

is_pid_alive :: proc(pid: u32) -> (alive: bool, exit_code: u32) {
	if pid == 0 do return false, 0
	PROCESS_QUERY_LIMITED_INFORMATION :: win32.DWORD(0x1000)
	SYNCHRONIZE :: win32.DWORD(0x00100000)
	h := win32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, pid)
	if h == nil do return false, 0
	defer win32.CloseHandle(h)

	wait_res := win32.WaitForSingleObject(h, 0)
	if wait_res == win32.WAIT_TIMEOUT {
		return true, 259 // STILL_ACTIVE
	}
	code: win32.DWORD = 0
	_ = win32.GetExitCodeProcess(h, &code)
	return false, u32(code)
}
