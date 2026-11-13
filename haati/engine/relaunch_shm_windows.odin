#+build windows
package engine

// =============================================================================
// ZERO-DISK OS SHARED-MEMORY RELAUNCH SNAPSHOT (`relaunch_shm_windows.odin`)
// =============================================================================
// Uses Win32 `CreateFileMappingW(INVALID_HANDLE_VALUE, ...)` pagefile/RAM-backed
// kernel sections so an editor restart hands its live unsaved scene bytes, 3D
// camera state, and entity selection across processes in RAM with 0 disk writes.

import "base:intrinsics"
import "core:mem"
import "core:strings"
import "core:time"
import win "core:sys/windows"

RELAUNCH_SHM_MAGIC   :: u64(0x4D48_5348_4D30_3031) // "MHSHM001"
RELAUNCH_SHM_MAX_SEL :: 64

Relaunch_SHM_Header :: struct #packed {
	magic:            u64,
	total_bytes:      u32,
	bridged:          u32, // Set to 1 by `mh_relaunch` once it pins the kernel handle
	consumed:         u32, // Set to 1 by the new `MoonHug.exe` once restored
	has_scene_bytes:  u32,

	// 3D / 2D Scene Camera state
	cam_pos:          [3]f32,
	cam_yaw:          f32,
	cam_pitch:        f32,
	cam_dist:         f32,
	cam_target:       [3]f32,
	cam_ortho:        u32,
	cam_2d_mode:      u32,

	// Active scene identity & selection (`Local_ID` survives handle re-allocation!)
	scene_guid:       [16]u8,
	selected_count:   u32,
	selected_lids:    [RELAUNCH_SHM_MAX_SEL]u64,

	scene_path_len:   u32,
	scene_bytes_len:  u32,
	// Followed immediately in RAM by:
	//   [scene_path_len]byte
	//   [scene_bytes_len]byte
}

Relaunch_SHM_Snapshot :: struct {
	has_scene_bytes: bool,
	cam_pos:         [3]f32,
	cam_yaw:         f32,
	cam_pitch:       f32,
	cam_dist:        f32,
	cam_target:      [3]f32,
	cam_ortho:       bool,
	cam_2d_mode:     bool,
	scene_guid:      [16]u8,
	selected_lids:   []u64,
	scene_path:      string,
	scene_bytes:     []byte,
}

Relaunch_SHM_Handle :: distinct rawptr

relaunch_shm_snapshot_destroy :: proc(snap: ^Relaunch_SHM_Snapshot, allocator := context.allocator) {
	if snap == nil do return
	if snap.selected_lids != nil do delete(snap.selected_lids, allocator)
	if snap.scene_path    != ""  do delete(snap.scene_path, allocator)
	if snap.scene_bytes   != nil do delete(snap.scene_bytes, allocator)
	snap^ = {}
}

// Allocates a named kernel RAM section (`Local\MoonHug_SHM_<pid>`) and copies `snap` into it.
relaunch_shm_create :: proc(shm_name: string, snap: Relaunch_SHM_Snapshot) -> (Relaunch_SHM_Handle, bool) {
	if shm_name == "" do return nil, false

	hdr_sz   := size_of(Relaunch_SHM_Header)
	path_sz  := len(snap.scene_path)
	bytes_sz := len(snap.scene_bytes)
	total_sz := hdr_sz + path_sz + bytes_sz
	if total_sz <= 0 || u64(total_sz) > 256 * 1024 * 1024 {
		return nil, false
	}

	wname := win.utf8_to_wstring(shm_name, context.temp_allocator)
	h_map := win.CreateFileMappingW(
		win.INVALID_HANDLE_VALUE,
		nil,
		win.PAGE_READWRITE,
		0,
		win.DWORD(total_sz),
		wname,
	)
	if h_map == nil || h_map == win.INVALID_HANDLE_VALUE {
		return nil, false
	}

	view := win.MapViewOfFile(h_map, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(total_sz))
	if view == nil {
		win.CloseHandle(h_map)
		return nil, false
	}
	defer win.UnmapViewOfFile(view)

	mem.zero(view, total_sz)
	hdr := cast(^Relaunch_SHM_Header)view
	hdr.magic           = RELAUNCH_SHM_MAGIC
	hdr.total_bytes     = u32(total_sz)
	hdr.bridged         = 0
	hdr.consumed        = 0
	hdr.has_scene_bytes = 1 if snap.has_scene_bytes else 0
	hdr.cam_pos         = snap.cam_pos
	hdr.cam_yaw         = snap.cam_yaw
	hdr.cam_pitch       = snap.cam_pitch
	hdr.cam_dist        = snap.cam_dist
	hdr.cam_target      = snap.cam_target
	hdr.cam_ortho       = 1 if snap.cam_ortho else 0
	hdr.cam_2d_mode     = 1 if snap.cam_2d_mode else 0
	hdr.scene_guid      = snap.scene_guid

	sel_n := min(len(snap.selected_lids), RELAUNCH_SHM_MAX_SEL)
	hdr.selected_count = u32(sel_n)
	for i in 0 ..< sel_n {
		hdr.selected_lids[i] = snap.selected_lids[i]
	}

	hdr.scene_path_len  = u32(path_sz)
	hdr.scene_bytes_len = u32(bytes_sz)

	base := uintptr(view) + uintptr(hdr_sz)
	if path_sz > 0 {
		mem.copy(rawptr(base), raw_data(snap.scene_path), path_sz)
	}
	if bytes_sz > 0 {
		mem.copy(rawptr(base + uintptr(path_sz)), raw_data(snap.scene_bytes), bytes_sz)
	}

	return Relaunch_SHM_Handle(h_map), true
}

// Waits briefly (up to `timeout_ms`) for `mh_relaunch` to pin the shared memory section (`bridged == 1`).
relaunch_shm_wait_bridged :: proc(h: Relaunch_SHM_Handle, timeout_ms: int = 300) -> bool {
	if h == nil do return false
	view := win.MapViewOfFile(win.HANDLE(h), win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(size_of(Relaunch_SHM_Header)))
	if view == nil do return false
	defer win.UnmapViewOfFile(view)

	hdr := cast(^Relaunch_SHM_Header)view
	steps := max(timeout_ms / 5, 1)
	for _ in 0 ..< steps {
		if intrinsics.atomic_load(&hdr.bridged) != 0 {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// Opens an existing kernel RAM section, deserializes `Relaunch_SHM_Snapshot`, and marks `consumed = 1`.
relaunch_shm_read :: proc(shm_name: string, allocator := context.allocator) -> (snap: Relaunch_SHM_Snapshot, ok: bool) {
	if shm_name == "" do return {}, false

	wname := win.utf8_to_wstring(shm_name, context.temp_allocator)
	h_map := win.OpenFileMappingW(win.FILE_MAP_ALL_ACCESS, win.FALSE, wname)
	if h_map == nil || h_map == win.INVALID_HANDLE_VALUE {
		return {}, false
	}
	defer win.CloseHandle(h_map)

	hdr_view := win.MapViewOfFile(h_map, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(size_of(Relaunch_SHM_Header)))
	if hdr_view == nil do return {}, false

	hdr_peek := (cast(^Relaunch_SHM_Header)hdr_view)^
	win.UnmapViewOfFile(hdr_view)

	if hdr_peek.magic != RELAUNCH_SHM_MAGIC || int(hdr_peek.total_bytes) < size_of(Relaunch_SHM_Header) {
		return {}, false
	}

	full_view := win.MapViewOfFile(h_map, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(hdr_peek.total_bytes))
	if full_view == nil do return {}, false
	defer win.UnmapViewOfFile(full_view)

	hdr := cast(^Relaunch_SHM_Header)full_view
	hdr_sz   := size_of(Relaunch_SHM_Header)
	path_sz  := int(hdr.scene_path_len)
	bytes_sz := int(hdr.scene_bytes_len)
	if hdr_sz + path_sz + bytes_sz > int(hdr.total_bytes) {
		return {}, false
	}

	snap.has_scene_bytes = hdr.has_scene_bytes != 0
	snap.cam_pos         = hdr.cam_pos
	snap.cam_yaw         = hdr.cam_yaw
	snap.cam_pitch       = hdr.cam_pitch
	snap.cam_dist        = hdr.cam_dist
	snap.cam_target      = hdr.cam_target
	snap.cam_ortho       = hdr.cam_ortho != 0
	snap.cam_2d_mode     = hdr.cam_2d_mode != 0
	snap.scene_guid      = hdr.scene_guid

	sel_n := min(int(hdr.selected_count), RELAUNCH_SHM_MAX_SEL)
	if sel_n > 0 {
		snap.selected_lids = make([]u64, sel_n, allocator)
		for i in 0 ..< sel_n {
			snap.selected_lids[i] = hdr.selected_lids[i]
		}
	}

	base := uintptr(full_view) + uintptr(hdr_sz)
	if path_sz > 0 {
		raw_str := string((cast([^]byte)rawptr(base))[:path_sz])
		snap.scene_path = strings.clone(raw_str, allocator)
	}
	if bytes_sz > 0 {
		snap.scene_bytes = make([]byte, bytes_sz, allocator)
		mem.copy(raw_data(snap.scene_bytes), rawptr(base + uintptr(path_sz)), bytes_sz)
	}

	intrinsics.atomic_store(&hdr.consumed, 1)
	return snap, true
}

relaunch_shm_close :: proc(h: Relaunch_SHM_Handle) {
	if h == nil do return
	win.CloseHandle(win.HANDLE(h))
}
