#+build windows
package mh

// Pins the OS kernel RAM mapping (`Local\MoonHug_SHM_<pid>`) across old-editor exit
// and new-editor startup so zero bytes touch disk during `Relaunch`.

import "base:intrinsics"
import "core:thread"
import "core:time"
import win "core:sys/windows"

@(private = "file")
_SHM_Bridge_Header :: struct #packed {
	magic:       u64,
	total_bytes: u32,
	bridged:     u32,
	consumed:    u32,
}

@(private = "file")
_SHM_MAGIC :: u64(0x4D48_5348_4D30_3031)

SHM_Pin :: distinct rawptr

@(private = "file")
_release_thread: ^thread.Thread

// Attempts to open the old editor's shared memory block and set `bridged = 1`.
shm_bridge_try_pin :: proc(shm_name: string) -> SHM_Pin {
	if shm_name == "" do return nil
	wname := win.utf8_to_wstring(shm_name, context.temp_allocator)
	h := win.OpenFileMappingW(win.FILE_MAP_ALL_ACCESS, win.FALSE, wname)
	if h == nil || h == win.INVALID_HANDLE_VALUE do return nil

	view := win.MapViewOfFile(h, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(size_of(_SHM_Bridge_Header)))
	if view == nil {
		win.CloseHandle(h)
		return nil
	}
	hdr := cast(^_SHM_Bridge_Header)view
	if hdr.magic != _SHM_MAGIC {
		win.UnmapViewOfFile(view)
		win.CloseHandle(h)
		return nil
	}
	intrinsics.atomic_store(&hdr.bridged, 1)
	win.UnmapViewOfFile(view)
	return SHM_Pin(h)
}

@(private = "file")
_shm_release_worker :: proc(t: ^thread.Thread) {
	h := win.HANDLE(t.user_args[0])
	if h == nil do return
	defer win.CloseHandle(h)

	view := win.MapViewOfFile(h, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(size_of(_SHM_Bridge_Header)))
	if view == nil do return
	defer win.UnmapViewOfFile(view)

	hdr := cast(^_SHM_Bridge_Header)view
	// Wait up to 12 seconds for the new `MoonHug.exe` to consume the snapshot, then unpin RAM!
	for _ in 0 ..< 240 {
		if intrinsics.atomic_load(&hdr.consumed) != 0 {
			return
		}
		time.sleep(50 * time.Millisecond)
	}
}

// Releases `mh`'s kernel handle asynchronously as soon as the new editor consumes the snapshot.
shm_bridge_release_when_consumed :: proc(pin: SHM_Pin) {
	if pin == nil do return
	t := thread.create(_shm_release_worker)
	if t == nil {
		win.CloseHandle(win.HANDLE(pin))
		return
	}
	t.user_args[0] = rawptr(pin)
	_release_thread = t
	thread.start(t)
}

shm_bridge_join :: proc() {
	if _release_thread != nil {
		thread.join(_release_thread)
		thread.destroy(_release_thread)
		_release_thread = nil
	}
}
