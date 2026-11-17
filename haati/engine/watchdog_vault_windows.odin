#+build windows
package engine

// =============================================================================
// OUT-OF-PROCESS WATCHDOG KERNEL RAM VAULT (`watchdog_vault_windows.odin`)
// =============================================================================
// Maintains a 16 MB Win32 `CreateFileMappingW(INVALID_HANDLE_VALUE)` split into
// 3 independently seqlocked zones so updating Camera/Selection (~200 ns) or
// Dirty Code Studio Tabs (~2 us) NEVER serializes or re-copies the Scene:
//   - Zone 0 `[0 .. 4 KB)`:      Header, Camera, Selection & Scene Path/GUID (`meta_seq`)
//   - Zone 1 `[4 KB .. 2 MB)`:   Dirty Code Studio Tabs JSON (`tabs_seq`)
//   - Zone 2 `[2 MB .. 16 MB)`:  Serialized Unsaved Scene Bytes (`scene_seq`)

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"

WATCHDOG_VAULT_MAGIC          :: u64(0x4854_5744_564C_5432) // "HTWDVLT2"
WATCHDOG_VAULT_CAP            :: 16 * 1024 * 1024
WATCHDOG_VAULT_HDR_ZONE_CAP   :: 4096
WATCHDOG_VAULT_TABS_ZONE_OFF  :: WATCHDOG_VAULT_HDR_ZONE_CAP
WATCHDOG_VAULT_TABS_ZONE_CAP  :: 2 * 1024 * 1024 - WATCHDOG_VAULT_TABS_ZONE_OFF
WATCHDOG_VAULT_SCENE_ZONE_OFF :: 2 * 1024 * 1024
WATCHDOG_VAULT_SCENE_ZONE_CAP :: WATCHDOG_VAULT_CAP - WATCHDOG_VAULT_SCENE_ZONE_OFF

Watchdog_Vault_Header :: struct #packed {
	magic:             u64,
	clean_exit:        u32, // Set to 1 on graceful quit / Relaunch so guardian stands down
	guardian_attached: u32,
	consumed:          u32, // Set to 1 by resurrected editor once snapshot is restored

	// Zone 0: Lightweight Camera + Selection + Scene Meta (`meta_seq` even = stable)
	meta_seq:          u32,
	cam_pos:           [3]f32,
	cam_yaw:           f32,
	cam_pitch:         f32,
	cam_dist:          f32,
	cam_target:        [3]f32,
	cam_ortho:         u32,
	cam_2d_mode:       u32,
	scene_guid:        [16]u8,
	selected_count:    u32,
	selected_lids:     [RELAUNCH_SHM_MAX_SEL]u64,
	scene_path_len:    u32,
	scene_path_buf:    [512]u8,

	// Zone 1: Dirty Code Studio Tabs (`tabs_seq` even = stable)
	tabs_seq:          u32,
	tabs_json_len:     u32,

	// Zone 2: Unsaved Scene Bytes (`scene_seq` even = stable)
	scene_seq:         u32,
	has_scene_bytes:   u32,
	scene_bytes_len:   u32,
}

Watchdog_Vault_Handle :: distinct rawptr

@(private = "file")
_WD_Vault_Box :: struct {
	h_map: win.HANDLE,
	view:  rawptr,
}

watchdog_vault_create :: proc(vault_name: string) -> (Watchdog_Vault_Handle, bool) {
	if vault_name == "" do return nil, false
	wname := win.utf8_to_wstring(vault_name, context.temp_allocator)
	h_map := win.CreateFileMappingW(
		win.INVALID_HANDLE_VALUE,
		nil,
		win.PAGE_READWRITE,
		0,
		win.DWORD(WATCHDOG_VAULT_CAP),
		wname,
	)
	if h_map == nil || h_map == win.INVALID_HANDLE_VALUE {
		return nil, false
	}
	view := win.MapViewOfFile(h_map, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(WATCHDOG_VAULT_CAP))
	if view == nil {
		win.CloseHandle(h_map)
		return nil, false
	}
	mem.zero(view, size_of(Watchdog_Vault_Header))
	hdr := cast(^Watchdog_Vault_Header)view
	hdr.magic = WATCHDOG_VAULT_MAGIC

	box := new(_WD_Vault_Box)
	box.h_map = h_map
	box.view  = view
	return Watchdog_Vault_Handle(box), true
}

watchdog_vault_write_meta :: proc(h: Watchdog_Vault_Handle, snap: Relaunch_SHM_Snapshot) -> bool {
	if h == nil do return false
	box := cast(^_WD_Vault_Box)h
	if box.view == nil do return false

	hdr := cast(^Watchdog_Vault_Header)box.view
	intrinsics.atomic_add(&hdr.meta_seq, 1) // Odd = updating Zone 0
	hdr.cam_pos     = snap.cam_pos
	hdr.cam_yaw     = snap.cam_yaw
	hdr.cam_pitch   = snap.cam_pitch
	hdr.cam_dist    = snap.cam_dist
	hdr.cam_target  = snap.cam_target
	hdr.cam_ortho   = 1 if snap.cam_ortho else 0
	hdr.cam_2d_mode = 1 if snap.cam_2d_mode else 0
	hdr.scene_guid  = snap.scene_guid

	sel_n := min(len(snap.selected_lids), RELAUNCH_SHM_MAX_SEL)
	hdr.selected_count = u32(sel_n)
	for i in 0 ..< sel_n {
		hdr.selected_lids[i] = snap.selected_lids[i]
	}

	path_n := min(len(snap.scene_path), len(hdr.scene_path_buf))
	hdr.scene_path_len = u32(path_n)
	if path_n > 0 {
		mem.copy(&hdr.scene_path_buf[0], raw_data(snap.scene_path), path_n)
	}
	intrinsics.atomic_add(&hdr.meta_seq, 1) // Even = valid Zone 0
	return true
}

watchdog_vault_write_tabs :: proc(h: Watchdog_Vault_Handle, tabs_json: []byte) -> bool {
	if h == nil do return false
	box := cast(^_WD_Vault_Box)h
	if box.view == nil do return false
	tabs_sz := len(tabs_json)
	if tabs_sz > WATCHDOG_VAULT_TABS_ZONE_CAP {
		return false
	}

	hdr := cast(^Watchdog_Vault_Header)box.view
	intrinsics.atomic_add(&hdr.tabs_seq, 1) // Odd = updating Zone 1
	hdr.tabs_json_len = u32(tabs_sz)
	if tabs_sz > 0 {
		dst := rawptr(uintptr(box.view) + uintptr(WATCHDOG_VAULT_TABS_ZONE_OFF))
		mem.copy(dst, raw_data(tabs_json), tabs_sz)
	}
	intrinsics.atomic_add(&hdr.tabs_seq, 1) // Even = valid Zone 1
	return true
}

watchdog_vault_write_scene :: proc(h: Watchdog_Vault_Handle, has_scene_bytes: bool, scene_bytes: []byte) -> bool {
	if h == nil do return false
	box := cast(^_WD_Vault_Box)h
	if box.view == nil do return false
	bytes_sz := len(scene_bytes)
	if bytes_sz > WATCHDOG_VAULT_SCENE_ZONE_CAP {
		return false
	}

	hdr := cast(^Watchdog_Vault_Header)box.view
	intrinsics.atomic_add(&hdr.scene_seq, 1) // Odd = updating Zone 2
	hdr.has_scene_bytes = 1 if has_scene_bytes else 0
	hdr.scene_bytes_len = u32(bytes_sz)
	if bytes_sz > 0 {
		dst := rawptr(uintptr(box.view) + uintptr(WATCHDOG_VAULT_SCENE_ZONE_OFF))
		mem.copy(dst, raw_data(scene_bytes), bytes_sz)
	}
	intrinsics.atomic_add(&hdr.scene_seq, 1) // Even = valid Zone 2
	return true
}

watchdog_vault_write :: proc(h: Watchdog_Vault_Handle, snap: Relaunch_SHM_Snapshot, tabs_json: []byte) -> bool {
	ok_m := watchdog_vault_write_meta(h, snap)
	ok_t := watchdog_vault_write_tabs(h, tabs_json)
	ok_s := watchdog_vault_write_scene(h, snap.has_scene_bytes, snap.scene_bytes)
	return ok_m && ok_t && ok_s
}

watchdog_vault_mark_clean_exit :: proc(h: Watchdog_Vault_Handle) {
	if h == nil do return
	box := cast(^_WD_Vault_Box)h
	if box.view == nil do return
	hdr := cast(^Watchdog_Vault_Header)box.view
	intrinsics.atomic_store(&hdr.clean_exit, 1)
}

watchdog_vault_close :: proc(h: Watchdog_Vault_Handle) {
	if h == nil do return
	box := cast(^_WD_Vault_Box)h
	if box.view != nil {
		win.UnmapViewOfFile(box.view)
	}
	if box.h_map != nil && box.h_map != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(box.h_map)
	}
	free(box)
}

watchdog_vault_read_and_consume :: proc(
	vault_name: string,
	allocator := context.allocator,
) -> (snap: Relaunch_SHM_Snapshot, tabs_json: []byte, ok: bool) {
	if vault_name == "" do return {}, nil, false
	wname := win.utf8_to_wstring(vault_name, context.temp_allocator)
	h_map := win.OpenFileMappingW(win.FILE_MAP_ALL_ACCESS, win.FALSE, wname)
	if h_map == nil || h_map == win.INVALID_HANDLE_VALUE {
		return {}, nil, false
	}
	defer win.CloseHandle(h_map)

	view := win.MapViewOfFile(h_map, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(WATCHDOG_VAULT_CAP))
	if view == nil do return {}, nil, false
	defer win.UnmapViewOfFile(view)

	hdr := cast(^Watchdog_Vault_Header)view
	if hdr.magic != WATCHDOG_VAULT_MAGIC {
		intrinsics.atomic_store(&hdr.consumed, 1)
		return {}, nil, false
	}

	any_valid := false

	// Zone 0: Camera, selection & scene path
	mseq := intrinsics.atomic_load(&hdr.meta_seq)
	if mseq > 0 && (mseq & 1) == 0 {
		any_valid = true
		snap.cam_pos     = hdr.cam_pos
		snap.cam_yaw     = hdr.cam_yaw
		snap.cam_pitch   = hdr.cam_pitch
		snap.cam_dist    = hdr.cam_dist
		snap.cam_target  = hdr.cam_target
		snap.cam_ortho   = hdr.cam_ortho != 0
		snap.cam_2d_mode = hdr.cam_2d_mode != 0
		snap.scene_guid  = hdr.scene_guid

		sel_n := min(int(hdr.selected_count), RELAUNCH_SHM_MAX_SEL)
		if sel_n > 0 {
			snap.selected_lids = make([]u64, sel_n, allocator)
			for i in 0 ..< sel_n {
				snap.selected_lids[i] = hdr.selected_lids[i]
			}
		}

		path_n := min(int(hdr.scene_path_len), len(hdr.scene_path_buf))
		if path_n > 0 {
			snap.scene_path = strings.clone(string(hdr.scene_path_buf[:path_n]), allocator)
		}
	}

	// Zone 1: Dirty Code Studio Tabs
	tseq := intrinsics.atomic_load(&hdr.tabs_seq)
	if tseq > 0 && (tseq & 1) == 0 {
		any_valid = true
		tabs_sz := int(hdr.tabs_json_len)
		if tabs_sz > 0 && tabs_sz <= WATCHDOG_VAULT_TABS_ZONE_CAP {
			tabs_json = make([]byte, tabs_sz, allocator)
			src := rawptr(uintptr(view) + uintptr(WATCHDOG_VAULT_TABS_ZONE_OFF))
			mem.copy(raw_data(tabs_json), src, tabs_sz)
		}
	}

	// Zone 2: Unsaved Scene Bytes
	sseq := intrinsics.atomic_load(&hdr.scene_seq)
	if sseq > 0 && (sseq & 1) == 0 {
		any_valid = true
		bytes_sz := int(hdr.scene_bytes_len)
		if hdr.has_scene_bytes != 0 && bytes_sz > 0 && bytes_sz <= WATCHDOG_VAULT_SCENE_ZONE_CAP {
			snap.has_scene_bytes = true
			snap.scene_bytes = make([]byte, bytes_sz, allocator)
			src := rawptr(uintptr(view) + uintptr(WATCHDOG_VAULT_SCENE_ZONE_OFF))
			mem.copy(raw_data(snap.scene_bytes), src, bytes_sz)
		}
	}

	intrinsics.atomic_store(&hdr.consumed, 1)
	return snap, tabs_json, any_valid
}

// Idle out-of-process guardian loop (`0.00%` CPU while waiting on editor PID via Win32 `WaitForSingleObject`).
// Resurrects the editor cleanly from the pinned Kernel RAM Vault only on unexpected non-zero termination.
watchdog_run_guardian_blocking :: proc(editor_pid: int, vault_name: string, restart_exe: string, restart_args: []string) -> int {
	if editor_pid <= 0 || vault_name == "" || restart_exe == "" do return 0

	wname := win.utf8_to_wstring(vault_name, context.temp_allocator)
	h_map := win.OpenFileMappingW(win.FILE_MAP_ALL_ACCESS, win.FALSE, wname)
	if h_map == nil || h_map == win.INVALID_HANDLE_VALUE {
		return 0
	}
	defer win.CloseHandle(h_map)

	hdr_view := win.MapViewOfFile(h_map, win.FILE_MAP_ALL_ACCESS, 0, 0, win.SIZE_T(size_of(Watchdog_Vault_Header)))
	if hdr_view == nil do return 0
	defer win.UnmapViewOfFile(hdr_view)

	hdr := cast(^Watchdog_Vault_Header)hdr_view
	if hdr.magic != WATCHDOG_VAULT_MAGIC do return 0
	intrinsics.atomic_store(&hdr.guardian_attached, 1)

	h_proc := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, win.DWORD(editor_pid))
	if h_proc == nil || h_proc == win.INVALID_HANDLE_VALUE {
		return 0
	}
	_ = win.WaitForSingleObject(h_proc, win.INFINITE)

	exit_code: win.DWORD = 0
	_ = win.GetExitCodeProcess(h_proc, &exit_code)
	win.CloseHandle(h_proc)

	if exit_code == 0 || intrinsics.atomic_load(&hdr.clean_exit) != 0 {
		return 0
	}

	// Crash-streak circuit breaker & Safe-Mode Project Hub fallback:
	//   - Crash #1 (fresh or > 90s gap): resurrect normally with `HAATI_WD_CRASH_STREAK=1`.
	//   - Crash #2 within 90s (`streak == 1`): strip `--project=...` and boot safely into `--project-hub` (`HAATI_WD_SAFE_HUB=1`).
	//   - Crash #3+ within 90s (`streak >= 2`): halt auto-resurrection completely.
	now_sec := i64(time.to_unix_nanoseconds(time.now()) / 1_000_000_000)
	prev_sec := i64(0)
	if cd_s, has_cd := os.lookup_env("HAATI_WD_COOLDOWN_EPOCH", context.temp_allocator); has_cd && cd_s != "" {
		if parsed_sec, lok := strconv.parse_i64(cd_s); lok && parsed_sec > 0 {
			prev_sec = parsed_sec
		}
	}
	prev_streak := 0
	if st_s, has_st := os.lookup_env("HAATI_WD_CRASH_STREAK", context.temp_allocator); has_st && st_s != "" {
		if parsed_st, sok := strconv.parse_int(st_s); sok && parsed_st > 0 {
			prev_streak = parsed_st
		}
	}

	in_window := prev_sec > 0 && (now_sec - prev_sec) >= 0 && (now_sec - prev_sec) < 90
	if in_window && prev_streak >= 2 {
		return 0
	}
	use_safe_hub := in_window && prev_streak == 1
	next_streak  := in_window ? (prev_streak + 1) : 1

	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") ||
			   strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") ||
			   strings.has_prefix(kv, "MH_SHM_NAME=") ||
			   strings.has_prefix(kv, "MH_SHM_HANDOFF=") ||
			   strings.has_prefix(kv, "HAATI_WATCHDOG_VAULT=") ||
			   strings.has_prefix(kv, "HAATI_WATCHDOG_EXIT_CODE=") ||
			   strings.has_prefix(kv, "HAATI_WD_COOLDOWN_EPOCH=") ||
			   strings.has_prefix(kv, "HAATI_WD_CRASH_STREAK=") ||
			   strings.has_prefix(kv, "HAATI_WD_SAFE_HUB=") {
				continue
			}
			append(&env, kv)
		}
	}
	append(&env, fmt.tprintf("HAATI_WATCHDOG_VAULT=%s", vault_name))
	append(&env, fmt.tprintf("HAATI_WATCHDOG_EXIT_CODE=0x%08X", u32(exit_code)))
	append(&env, fmt.tprintf("HAATI_WD_COOLDOWN_EPOCH=%d", now_sec))
	append(&env, fmt.tprintf("HAATI_WD_CRASH_STREAK=%d", next_streak))
	if use_safe_hub {
		append(&env, "HAATI_WD_SAFE_HUB=1")
	}

	cmd := make([dynamic]string, 0, 2 + len(restart_args), context.temp_allocator)
	append(&cmd, restart_exe)
	if use_safe_hub {
		for a in restart_args {
			if a != "" && a != "--project-hub" && !strings.has_prefix(a, "--project=") {
				append(&cmd, a)
			}
		}
		append(&cmd, "--project-hub")
	} else {
		for a in restart_args {
			if a != "" do append(&cmd, a)
		}
	}

	intrinsics.atomic_store(&hdr.consumed, 0)
	_, serr := os.process_start({
		command     = cmd[:],
		env         = env[:],
		working_dir = filepath.dir(restart_exe),
	})
	if serr != nil do return 0

	t0 := time.tick_now()
	for time.duration_milliseconds(time.tick_since(t0)) < 6000.0 {
		if intrinsics.atomic_load(&hdr.consumed) != 0 {
			break
		}
		time.sleep(25 * time.Millisecond)
	}
	return 0
}
