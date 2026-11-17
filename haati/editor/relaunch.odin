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
import "core:strconv"
import "core:strings"
import im "haati:external/odin-imgui"
import "menu"
import "../engine"
import "../engine/log"
import "../engine/registration"
import cs "haati:editor/code_studio"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import wnd "haati:editor/window"

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

@(private = "file")
_pending_direct_switch_buf: [1024]u8
@(private = "file")
_pending_direct_switch_len: int
@(private = "file")
_pending_hub_switch: bool

@(private = "file")
_relaunch_err: struct {
	visible:   bool,
	exit_code: int,
	headline:  [256]u8,
	head_len:  int,
	full_log:  string,
	err_file:  string,
	err_line:  int,
}

@(private = "file")
_relaunch_err_clear :: proc() {
	if _relaunch_err.full_log != "" do delete(_relaunch_err.full_log)
	if _relaunch_err.err_file != "" do delete(_relaunch_err.err_file)
	_relaunch_err = {}
}

@(private = "file")
_parse_odin_error_loc :: proc(detail: string, allocator := context.temp_allocator) -> (file: string, line: int) {
	for raw_ln in strings.split_lines(detail, context.temp_allocator) {
		ln := strings.trim_space(raw_ln)
		if ln == "" do continue
		for ext in ([2]string{".odin(", ".bodin("}) {
			idx := strings.index(ln, ext)
			if idx < 0 do continue
			path_end := idx + len(ext) - 1 // include .odin / .bodin, exclude '('
			loc_start := idx + len(ext)
			rest := ln[loc_start:]
			col_i := strings.index_any(rest, ":)")
			if col_i <= 0 do continue
			if ln_num, lok := strconv.parse_int(rest[:col_i]); lok && ln_num > 0 {
				return strings.clone(strings.trim_space(ln[:path_end]), allocator), ln_num
			}
		}
	}
	return "", 0
}

@(private = "file")
_relaunch_err_set :: proc(exit_code: int, headline: string, detail: string) {
	_relaunch_err_clear()
	_relaunch_err.visible   = true
	_relaunch_err.exit_code = exit_code
	hl := strings.trim_space(headline)
	if hl == "" do hl = "Check Console for Odin compiler diagnostics."
	_relaunch_err.head_len  = copy(_relaunch_err.headline[:len(_relaunch_err.headline) - 1], hl)
	if detail != "" {
		_relaunch_err.full_log = strings.clone(detail)
		f, l := _parse_odin_error_loc(detail, context.temp_allocator)
		if f != "" {
			_relaunch_err.err_file = strings.clone(f)
			_relaunch_err.err_line = l
		}
	}
}

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
	return engine.resolve_repo_root(context.temp_allocator)
}

// Resolves the Odin compiler binary via bundled `<repo>/tools/odin/` first.
@(private = "file")
_odin_bin :: proc() -> string {
	return engine.resolve_odin_binary(context.temp_allocator)
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

relaunch_has_explicit_project_arg :: proc(args: []string) -> bool {
	for a in args {
		if a == "--project-hub" || strings.has_prefix(a, "--project=") do return true
	}
	if env_p, ok := os.lookup_env("HAATI_PROJECT", context.temp_allocator); ok && strings.trim_space(env_p) != "" {
		return true
	}
	return false
}

relaunch_is_project_rebuilt_env :: proc() -> bool {
	if v, ok := os.lookup_env("MH_PROJECT_REBUILT", context.temp_allocator); ok {
		return v == "1"
	}
	return false
}

relaunch_needs_project_rebuild :: proc(proj_dir: string) -> bool {
	if proj_dir == "" do return false
	if !engine.project_dir_has_odin_code(proj_dir) do return false
	if registration.COMPILED_PROJECT_DIR == "" {
		// Pre-split transitional case: `plugins/void_odin` is already compiled
		// when permanently linked in `haati/packages/`.
		eng_plugins := engine.engine_plugins_dir(context.temp_allocator)
		void_legacy, _ := filepath.join({eng_plugins, "void_odin"}, context.temp_allocator)
		if eng_plugins != "" && os.is_dir(void_legacy) && engine.paths_equal(proj_dir, void_legacy) {
			return false
		}
		return true
	}
	return !engine.paths_equal(registration.COMPILED_PROJECT_DIR, proj_dir)
}

@(private = "file")
_relaunch_spawn :: proc(extra_mh_args: []string, mark_project_rebuilt: bool) {
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
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") ||
			   strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") ||
			   strings.has_prefix(kv, "MH_SHM_NAME=") ||
			   strings.has_prefix(kv, "MH_SHM_HANDOFF=") ||
			   strings.has_prefix(kv, "MH_PROJECT_REBUILT=") ||
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
	append(&env, fmt.tprintf("MH_RELAUNCH_PID=%d", pid))
	append(&env, fmt.tprintf("MH_RELAUNCH_SEQ=%d", _relaunch_seq))
	append(&env, fmt.tprintf("MH_SHM_NAME=%s", shm_name))
	if mark_project_rebuilt || relaunch_is_project_rebuilt_env() {
		append(&env, "MH_PROJECT_REBUILT=1")
	}

	odin_exe := _odin_bin()
	// Unique PID + sequence output path prevents MSVC `LNK1104` even if a prior relaunch
	// helper is still finishing its SHM handoff!
	mh_out := fmt.tprintf("-out:builds/mh_relaunch_%d_%d.exe", pid, _relaunch_seq) when ODIN_OS == .Windows else fmt.tprintf("-out:builds/mh_relaunch_%d_%d", pid, _relaunch_seq)
	builds_dir, _ := filepath.join({root, "builds"}, context.temp_allocator)
	_ = os.make_directory_all(builds_dir)
	log_path, _ := filepath.join({builds_dir, fmt.tprintf("relaunch_%d_%d.log", pid, _relaunch_seq)}, context.temp_allocator)

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_exe, "run", "tools/mh", mh_out, "--", mode)
	for a in extra_mh_args {
		if a != "" do append(&cmd, a)
	}

	process, started := engine.bg_process_start_to_file(
		root,
		cmd[:],
		env[:],
		log_path,
	)
	if !started {
		log.errorf("[relaunch] cannot start `%s` (odin resolved as %s)", relaunch_command(), odin_exe)
		return
	}
	_relaunch_err_clear()
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

relaunch_request :: proc() {
	if engine.is_project_hub_startup() {
		_relaunch_spawn({"--project-hub"}, false)
	} else if proj := engine.active_project_root(); proj != "" {
		_relaunch_spawn({fmt.tprintf("--project=%s", proj)}, false)
	} else {
		_relaunch_spawn(nil, false)
	}
}

relaunch_request_project :: proc(project_dir: string) {
	if project_dir == "" do return
	_relaunch_spawn({fmt.tprintf("--project=%s", project_dir)}, true)
}

open_or_switch_project :: proc(project_dir: string) -> (ok: bool, err_msg: string) {
	if project_dir == "" {
		return false, "Select or enter a project folder path first."
	}
	abs_dir, aerr := filepath.abs(project_dir, context.temp_allocator)
	if aerr != nil || abs_dir == "" {
		abs_dir = project_dir
	}
	norm, _ := strings.replace_all(abs_dir, "\\", "/", context.temp_allocator)
	norm = strings.trim_right(norm, "/")
	if !os.exists(norm) || !os.is_dir(norm) {
		return false, fmt.tprintf("Folder does not exist: %s", norm)
	}

	disp := engine.project_read_display_name(norm, context.temp_allocator)
	_ = engine.launcher_record_open_project(norm, disp)

	if relaunch_needs_project_rebuild(norm) {
		log.infof("[project] '%s' contains Odin scripts — compiling project package before switching...", norm)
		relaunch_request_project(norm)
		return true, ""
	}

	if len(norm) >= len(_pending_direct_switch_buf) {
		return false, "Project path is too long."
	}
	_pending_direct_switch_len = copy(_pending_direct_switch_buf[:], norm)
	watchdog_notify_clean_exit()
	menu.quit_requested = true
	return true, ""
}

relaunch_boot_to_project_hub :: proc() {
	_pending_hub_switch = true
	_pending_direct_switch_len = 0
	watchdog_notify_clean_exit()
	menu.quit_requested = true
}

relaunch_execute_pending_direct_switch :: proc() {
	if _pending_hub_switch {
		_pending_hub_switch = false
		exe_path, eerr := os.get_executable_path(context.temp_allocator)
		if eerr != nil || exe_path == "" do return
		env := make([dynamic]string, context.temp_allocator)
		if cur, err := os.environ(context.temp_allocator); err == nil {
			for kv in cur {
				if strings.has_prefix(kv, "MH_RELAUNCH_PID=") ||
				   strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") ||
				   strings.has_prefix(kv, "MH_SHM_NAME=") ||
				   strings.has_prefix(kv, "MH_SHM_HANDOFF=") ||
				   strings.has_prefix(kv, "HAATI_PROJECT=") ||
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
		p, perr := os.process_start({
			command     = {exe_path, "--project-hub"},
			env         = env[:],
			working_dir = filepath.dir(exe_path),
		})
		if perr != nil {
			fmt.eprintfln("[project] failed to launch Project Hub: %v", perr)
			return
		}
		_, _ = os.process_wait(p, 0)
		return
	}
	if _pending_direct_switch_len <= 0 do return
	target_dir := string(_pending_direct_switch_buf[:_pending_direct_switch_len])
	exe_path, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil || exe_path == "" {
		_pending_direct_switch_len = 0
		return
	}
	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") ||
			   strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") ||
			   strings.has_prefix(kv, "MH_SHM_NAME=") ||
			   strings.has_prefix(kv, "MH_SHM_HANDOFF=") ||
			   strings.has_prefix(kv, "HAATI_PROJECT=") ||
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
	proj_flag := fmt.tprintf("--project=%s", target_dir)
	p, perr := os.process_start({
		command     = {exe_path, proj_flag},
		env         = env[:],
		working_dir = filepath.dir(exe_path),
	})
	_pending_direct_switch_len = 0
	if perr != nil {
		fmt.eprintfln("[project] failed to launch replacement editor for %q: %v", target_dir, perr)
		return
	}
	_, _ = os.process_wait(p, 0)
}

relaunch_shutdown :: proc() {
	if _relaunch.pending {
		_relaunch_clear()
	}
	_relaunch_err_clear()
}

// Once per frame. Quits when the replacement is built, or drops the request
// when the build fails.
relaunch_tick :: proc() {
	if !_relaunch.pending do return

	if os.exists(_relaunch.marker) {
		_relaunch_capture_to_shm(_relaunch.shm_name)
		log.infof("[relaunch] build ready, restarting (RAM snapshot bridged)")
		_relaunch_clear()
		watchdog_notify_clean_exit()
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
			_relaunch_err_set(exit_code, first_err, detail)
		} else {
			log.errorf("[relaunch] build failed (mh exit %d), editor keeps running", exit_code)
			_relaunch_err_set(exit_code, "Relaunch compiler exited with errors (check Console).", "")
		}
		menu.show_console = true
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
// Captures current camera, unsaved active scene bytes, and `Local_ID` selection for zero-disk RAM handoff/vaults.
relaunch_capture_snapshot :: proc(allocator := context.temp_allocator) -> (snap: engine.Relaunch_SHM_Snapshot, ok: bool) {
	lids := make([dynamic]u64, allocator)
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
			if active_sc.path != "" {
				scene_path = strings.clone(active_sc.path, allocator)
				if g, gok := engine.asset_db_get_guid(active_sc.path); gok {
					scene_guid = ([16]u8)(g)
				}
			}
			if raw, sok := engine.scene_serialize(active_sc); sok {
				if len(raw) > 0 {
					scene_bytes = make([]byte, len(raw), allocator)
					copy(scene_bytes, raw)
				}
				delete(raw)
				has_bytes = true
			}
		}
	}

	snap = engine.Relaunch_SHM_Snapshot{
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
	return snap, true
}

// Applies a captured camera + scene bytes + selection snapshot back into the live editor.
relaunch_apply_snapshot :: proc(snap: ^engine.Relaunch_SHM_Snapshot) {
	if snap == nil do return

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
}

// for `mh_relaunch` to pin the kernel handle before this editor exits.
@(private = "file")
_relaunch_capture_to_shm :: proc(shm_name: string) {
	if shm_name == "" do return
	if _relaunch_shm_out_handle != nil {
		engine.relaunch_shm_close(_relaunch_shm_out_handle)
		_relaunch_shm_out_handle = nil
	}

	snap, snap_ok := relaunch_capture_snapshot(context.temp_allocator)
	if !snap_ok do return

	if h, ok := engine.relaunch_shm_create(shm_name, snap); ok {
		_relaunch_shm_out_handle = h
		_ = engine.relaunch_shm_wait_bridged(h, 3000)
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

	relaunch_apply_snapshot(&snap)

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

// Top-center non-intrusive diagnostic banner when a silent Relaunch build fails to compile.
relaunch_draw_error_banner :: proc() {
	if !_relaunch_err.visible do return

	if vp := im.GetMainViewport(); vp != nil {
		im.SetNextWindowViewport(vp.ID_)
		im.SetNextWindowPos({vp.WorkPos.x + vp.WorkSize.x * 0.5, vp.WorkPos.y + 42.0}, .Appearing, {0.5, 0.0})
	}

	p := thm.palette()
	im.PushStyleColorImVec4(.WindowBg, p.bg_elevated)
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.status_error, 0.90))
	im.PushStyleVar(.WindowRounding, 8.0)
	im.PushStyleVar(.WindowBorderSize, 1.5)
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{14, 10})
	defer {
		im.PopStyleVar(3)
		im.PopStyleColor(2)
	}

	flags := im.WindowFlags{.NoTitleBar, .NoResize, .NoScrollbar, .NoCollapse, .AlwaysAutoResize, .NoSavedSettings, .NoFocusOnAppearing, .NoNavInputs, .NoNavFocus, .NoDocking}
	if im.Begin("##relaunch_err_banner", nil, flags) {
		widgets.text_coloredf(p.status_error, "%s Relaunch Build Failed (mh exit %d)", icons.ICON_MD_ERROR, _relaunch_err.exit_code)
		head := _relaunch_err.head_len > 0 ? string(_relaunch_err.headline[:_relaunch_err.head_len]) : "Compilation failed."
		widgets.textf("%s", head)

		im.Spacing()
		if im.Button(fmt.ctprintf("%s Open Console", icons.ICON_MD_TERMINAL)) {
			menu.show_console = true
		}
		if _relaunch_err.err_file != "" {
			im.SameLine(0, 8)
			if im.Button(fmt.ctprintf("%s Jump to Problem", icons.ICON_MD_CODE)) {
				cs.open_file_in_studio(_relaunch_err.err_file, _relaunch_err.err_line)
				wnd.open("odin_micro_studio")
			}
		}
		im.SameLine(0, 8)
		if im.Button(fmt.ctprintf("%s Retry Relaunch", icons.ICON_MD_REFRESH)) {
			relaunch_request()
		}
		im.SameLine(0, 8)
		if im.Button("Dismiss##rl_err_dismiss") {
			_relaunch_err_clear()
		}
	}
	im.End()
}
