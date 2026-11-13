package editor

// Relaunch: rebuild and restart the editor the same way it was started.
//
// tools/mh launches the editor with MH_LAUNCH=<mode> ("run" or "debug"). The
// Relaunch button spawns `odin run tools/mh -- <mode>` with MH_RELAUNCH_PID
// set to this process, and the editor keeps running while that builds. mh
// writes builds/relaunch_ready once the build succeeds, this editor sees the
// file and quits through the normal path (settings saved), mh waits for the
// exit and launches the new binary. A failed build writes no marker, so the
// editor stays up and the compiler output is in the terminal mh runs in.
//
// Without MH_LAUNCH (a bare binary started by hand) the mode comes from how
// this binary was compiled: ODIN_DEBUG picks `debug`, otherwise `run`. Both
// produce the same builds/MoonHug, so the restart still rebuilds and runs the
// editor the way it is running now.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "menu"
import "../engine"
import "../engine/log"

RELAUNCH_MARKER :: "builds/relaunch_ready" // relative to the repository root

@(private = "file")
_relaunch: struct {
	pending:   bool,
	process:   engine.BG_Process,
	marker:    string, // absolute path of the ready marker
	log_file:  string, // compiler output log (`builds/relaunch_build.log`)
	repo_root: string,
	shm_name:  string, // OS kernel RAM section name (`Local\MoonHug_SHM_<pid>`)
}

@(private = "file")
_relaunch_seq: int

@(private = "file")
_relaunch_shm_out_handle: engine.Relaunch_SHM_Handle

@(private = "file")
_relaunch_shm_restore_checked: bool

// The mh mode that rebuilds and runs the editor the way it is running now:
// the one that started it, or, for a bare binary, the one matching its build.
relaunch_mode :: proc() -> string {
	if mode, ok := os.lookup_env("MH_LAUNCH", context.temp_allocator); ok && mode != "" {
		return mode
	}
	return "debug" when ODIN_DEBUG else "run"
}

// The exact command Relaunch runs, for the tooltip.
relaunch_command :: proc() -> string {
	return fmt.tprintf("odin run tools/mh -- %s", relaunch_mode())
}

relaunch_pending :: proc() -> bool {
	return _relaunch.pending
}

// The repository root: the working directory is normalized to moonhug/ at
// startup, so the root is one level up.
@(private = "file")
_repo_root :: proc() -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return ".."
	return filepath.dir(cwd)
}

// Resolves the Odin compiler binary: checks PATH first, falling back to the
// compile-time ODIN_ROOT installation directory (e.g. D:/Odin/odin.exe on Windows).
@(private = "file")
_odin_bin :: proc() -> string {
	exe_ext :: ".exe" when ODIN_OS == .Windows else ""
	if path_env, found := os.lookup_env("PATH", context.temp_allocator); found {
		sep := ";" when ODIN_OS == .Windows else ":"
		name := strings.concatenate({"odin", exe_ext}, context.temp_allocator)
		for dir in strings.split(path_env, sep, context.temp_allocator) {
			if dir == "" do continue
			p, err := filepath.join({dir, name}, context.temp_allocator)
			if err == nil && os.exists(p) do return p
		}
	}
	root_odin, _ := filepath.join({ODIN_ROOT, "odin" + exe_ext}, context.temp_allocator)
	if os.exists(root_odin) do return root_odin
	return "odin"
}

// Opportunistically removes any stale unlocked `builds/mh_relaunch*` or `builds/MoonHug_relaunch*`
// binaries left over from earlier sessions so `builds/` never accumulates helper executables.
@(private = "file")
_sweep_stale_relaunch_bins :: proc(root: string) {
	builds_dir, err := filepath.join({root, "builds"}, context.temp_allocator)
	if err != nil do return
	entries, derr := os.read_all_directory_by_path(builds_dir, context.temp_allocator)
	if derr != nil do return
	for fi in entries {
		if strings.has_prefix(fi.name, "mh_relaunch") || strings.has_prefix(fi.name, "MoonHug_relaunch") || strings.has_prefix(fi.name, "Haati_relaunch") {
			_ = os.remove(fi.fullpath) // silently ignored if still locked by an exiting helper
		}
	}
}

relaunch_request :: proc() {
	if _relaunch.pending do return
	root := _repo_root()
	mode := relaunch_mode()

	_sweep_stale_relaunch_bins(root)

	marker, _ := filepath.join({root, RELAUNCH_MARKER}, context.temp_allocator)
	if os.exists(marker) do _ = os.remove(marker) // stale from an interrupted run

	pid := os.get_pid()
	_relaunch_seq += 1
	shm_name := fmt.tprintf("Local\\Haati_SHM_%d_%d", pid, _relaunch_seq)

	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") || strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") || strings.has_prefix(kv, "MH_SHM_NAME=") || strings.has_prefix(kv, "MH_SHM_HANDOFF=") do continue
			append(&env, kv)
		}
	}
	append(&env, fmt.tprintf("MH_RELAUNCH_PID=%d", pid))
	append(&env, fmt.tprintf("MH_RELAUNCH_SEQ=%d", _relaunch_seq))
	append(&env, fmt.tprintf("MH_SHM_NAME=%s", shm_name))

	odin_exe := _odin_bin()
	// Unique PID + sequence output path prevents MSVC `LNK1104` even if a prior relaunch
	// helper is still finishing its SHM handoff!
	mh_out := fmt.tprintf("-out:builds/mh_relaunch_%d_%d.exe", pid, _relaunch_seq) when ODIN_OS == .Windows else fmt.tprintf("-out:builds/mh_relaunch_%d_%d", pid, _relaunch_seq)
	builds_dir, _ := filepath.join({root, "builds"}, context.temp_allocator)
	_ = os.make_directory_all(builds_dir)
	log_path, _ := filepath.join({builds_dir, fmt.tprintf("relaunch_%d_%d.log", pid, _relaunch_seq)}, context.temp_allocator)

	process, started := engine.bg_process_start_to_file(
		root,
		{odin_exe, "run", "tools/mh", mh_out, "--", mode},
		env[:],
		log_path,
	)
	if !started {
		log.errorf("[relaunch] cannot start `%s` (odin resolved as %s)", relaunch_command(), odin_exe)
		return
	}
	_relaunch = {
		pending   = true,
		process   = process,
		marker    = strings.clone(marker),
		log_file  = strings.clone(log_path),
		repo_root = strings.clone(root),
		shm_name  = strings.clone(shm_name),
	}
	log.infof("[relaunch] building silently with `%s`, the editor restarts with zero-disk RAM handoff when it succeeds", relaunch_command())
}

// Once per frame. Quits when the replacement is built, or drops the request
// when the build fails.
relaunch_tick :: proc() {
	if !_relaunch.pending do return

	if os.exists(_relaunch.marker) {
		_relaunch_capture_to_shm(_relaunch.shm_name)
		log.infof("[relaunch] build ready, restarting (RAM snapshot bridged)")
		_relaunch_clear()
		menu.quit_requested = true
		return
	}

	// A finished mh with no marker means the build failed (a success only
	// exits after this editor is gone).
	exited, exit_code := engine.bg_process_poll(&_relaunch.process)
	if exited {
		detail := ""
		if _relaunch.log_file != "" {
			if raw, rerr := os.read_entire_file(_relaunch.log_file, context.temp_allocator); rerr == nil {
				detail = strings.trim_space(string(raw))
			}
			_ = os.remove(_relaunch.log_file)
		}
		if detail != "" {
			first_err := detail
			for ln in strings.split_lines(detail, context.temp_allocator) {
				tl := strings.trim_space(ln)
				if tl == "" || strings.has_prefix(tl, "timing:") do continue
				first_err = tl
				break
			}
			log.errorf("[relaunch] build failed (mh exit %d): %s\n%s", exit_code, first_err, detail)
		} else {
			log.errorf("[relaunch] build failed (mh exit %d), editor keeps running", exit_code)
		}
		_relaunch_clear()
	}
}

@(private = "file")
_relaunch_clear :: proc() {
	delete(_relaunch.marker)
	delete(_relaunch.log_file)
	delete(_relaunch.repo_root)
	delete(_relaunch.shm_name)
	_relaunch = {}
}

// Serializes the active authored scene, 3D camera, and selection directly into an OS
// shared-memory section (`CreateFileMappingW`) with 0 disk writes, and waits briefly
// for `mh_relaunch` to pin the kernel handle before this editor exits.
@(private = "file")
_relaunch_capture_to_shm :: proc(shm_name: string) {
	if shm_name == "" do return
	if _relaunch_shm_out_handle != nil {
		engine.relaunch_shm_close(_relaunch_shm_out_handle)
		_relaunch_shm_out_handle = nil
	}

	lids := make([dynamic]u64, context.temp_allocator)
	if w := engine.ctx_world(); w != nil {
		for tH in sel_scene_inspected() {
			if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil && t.local_id != 0 {
				append(&lids, u64(t.local_id))
			}
		}
	}

	scene_bytes: []byte
	has_bytes := false
	scene_path := ""
	scene_guid: [16]u8 = {}

	if !sim_is_active() {
		if active_sc := engine.sm_scene_get_active(); active_sc != nil {
			scene_path = active_sc.path
			if scene_path != "" {
				if g, gok := engine.asset_db_get_guid(scene_path); gok {
					scene_guid = ([16]u8)(g)
				}
			}
			if raw, ok := engine.scene_serialize(active_sc); ok {
				scene_bytes = raw
				has_bytes = true
			}
		}
	}
	defer if has_bytes && scene_bytes != nil do delete(scene_bytes)

	snap := engine.Relaunch_SHM_Snapshot{
		has_scene_bytes = has_bytes,
		cam_pos         = scene_cam_pos,
		cam_yaw         = scene_cam_yaw,
		cam_pitch       = scene_cam_pitch,
		cam_dist        = scene_cam_dist,
		cam_target      = scene_cam_target,
		cam_ortho       = scene_cam_ortho,
		cam_2d_mode     = scene_2d_mode,
		scene_guid      = scene_guid,
		selected_lids   = lids[:],
		scene_path      = scene_path,
		scene_bytes     = scene_bytes,
	}

	if h, ok := engine.relaunch_shm_create(shm_name, snap); ok {
		_relaunch_shm_out_handle = h
		_ = engine.relaunch_shm_wait_bridged(h, 300)
	}
}

// Consumes `MH_SHM_HANDOFF` once after initial scene loads settle, restoring unsaved
// in-RAM scene edits, 3D camera orientation, and selected entities with 0 disk I/O.
relaunch_shm_tick_restore :: proc(frames_presented: int) {
	if _relaunch_shm_restore_checked do return
	if frames_presented < 4 || len(_pending_scene_loads) > 0 do return
	_relaunch_shm_restore_checked = true

	handoff_name, found := os.lookup_env("MH_SHM_HANDOFF", context.temp_allocator)
	if !found || handoff_name == "" do return

	snap, ok := engine.relaunch_shm_read(handoff_name)
	if !ok do return
	defer engine.relaunch_shm_snapshot_destroy(&snap)

	// 1. Restore 3D / 2D Scene Camera state
	scene_cam_pos     = snap.cam_pos
	scene_cam_yaw     = snap.cam_yaw
	scene_cam_pitch   = snap.cam_pitch
	scene_cam_dist    = snap.cam_dist
	scene_cam_target  = snap.cam_target
	_fly_yaw_target   = snap.cam_yaw
	_fly_pitch_target = snap.cam_pitch
	scene_cam_ortho   = snap.cam_ortho
	scene_2d_mode     = snap.cam_2d_mode

	// 2. Restore live unsaved active scene bytes + `Local_ID` selection
	var_sc: ^engine.Scene = engine.sm_scene_get_active()
	if snap.has_scene_bytes && len(snap.scene_bytes) > 0 {
		target_sc: ^engine.Scene = nil
		guid := engine.Asset_GUID(snap.scene_guid)
		if guid != {} {
			target_sc = engine.sm_scene_find_by_guid(guid)
		}
		if target_sc == nil && snap.scene_path != "" {
			if sm := engine.ctx_scene_manager(); sm != nil {
				for i in 0 ..< sm.count {
					sc := sm.loaded[i]
					if sc != nil && sc.path == snap.scene_path {
						target_sc = sc
						break
					}
				}
			}
		}
		if target_sc == nil {
			target_sc = engine.sm_scene_get_active()
		}

		if target_sc != nil {
			var_sc = engine.scene_reload_in_place_bytes(target_sc, snap.scene_bytes, guid, snap.scene_path)
		} else {
			var_sc = engine.scene_load_single_bytes(snap.scene_bytes, guid, snap.scene_path)
		}
	}

	if var_sc != nil && len(snap.selected_lids) > 0 {
		handles := make([dynamic]engine.Transform_Handle, context.temp_allocator)
		for lid in snap.selected_lids {
			if h, hok := engine.bimap_get(&var_sc.local_ids, engine.Local_ID(lid)); hok {
				append(&handles, engine.Transform_Handle(h))
			}
		}
		if len(handles) > 0 {
			sel_scene_set(handles[:])
		}
	}

	log.infof("[relaunch] Restored live scene (%d bytes), 3D camera, and %d selected item(s) from OS RAM", len(snap.scene_bytes), len(snap.selected_lids))
}

relaunch_shm_cleanup :: proc() {
	if _relaunch_shm_out_handle != nil {
		engine.relaunch_shm_close(_relaunch_shm_out_handle)
		_relaunch_shm_out_handle = nil
	}
}

@(menu_item={path="File/Relaunch", order=9, shortcut=""})
file_relaunch_menu :: proc() { relaunch_request() }
