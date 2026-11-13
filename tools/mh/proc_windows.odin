#+build windows
package mh

import win "core:sys/windows"

// process_alive reports whether a process with this pid exists and is currently running.
process_alive :: proc(pid: int) -> bool {
// SYNCHRONIZE allows waiting on the process object.
// PROCESS_QUERY_LIMITED_INFORMATION allows querying state without elevated rights.
	desired_access := win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION
	handle := win.OpenProcess(desired_access, false, win.DWORD(pid))

	if handle == nil {
	// If access is denied, the process exists and is active, but lacks permission to open.
		return win.GetLastError() == win.ERROR_ACCESS_DENIED
	}
	defer win.CloseHandle(handle)

	// A process object transitions to signaled when it terminates.
	// A timeout of 0 ms returns WAIT_TIMEOUT if the process is still running.
	return win.WaitForSingleObject(handle, 0) == win.WAIT_TIMEOUT
}