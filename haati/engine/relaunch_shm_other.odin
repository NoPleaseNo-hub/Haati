#+build !windows
package engine

// POSIX / non-Windows stub for `relaunch_shm_*` (graceful no-op fallback to normal relaunch).

RELAUNCH_SHM_MAGIC   :: u64(0x4D48_5348_4D30_3031)
RELAUNCH_SHM_MAX_SEL :: 64

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

relaunch_shm_create :: proc(shm_name: string, snap: Relaunch_SHM_Snapshot) -> (Relaunch_SHM_Handle, bool) {
	return nil, false
}

relaunch_shm_wait_bridged :: proc(h: Relaunch_SHM_Handle, timeout_ms: int = 300) -> bool {
	return false
}

relaunch_shm_read :: proc(shm_name: string, allocator := context.allocator) -> (snap: Relaunch_SHM_Snapshot, ok: bool) {
	return {}, false
}

relaunch_shm_close :: proc(h: Relaunch_SHM_Handle) {}
