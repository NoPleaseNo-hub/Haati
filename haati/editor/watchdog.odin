package editor

// Out-of-Process Crash Watchdog Guardian & Kernel RAM Vault integration.
// Spawns an idle 0% CPU child process (`--watchdog-guardian <pid> <vault>`) that monitors
// editor termination via Win32 `WaitForSingleObject`, resurrects the editor from the
// 16 MB Kernel RAM Vault (`Local\Haati_WD_*`), quarantines hot scripts on recovery, and
// displays a non-intrusive top-center recovery banner.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import im "haati:external/odin-imgui"
import "../engine"
import crash_journal "../engine/crash_journal"
import "../engine/log"
import cs "haati:editor/code_studio"
import "haati:editor/editor_visuals"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import "undo"

@(private = "file")
_wd: struct {
	initialized:              bool,
	want_enabled:             bool,
	seq:                      int,
	uptime_sec:               f32,
	vault:                    engine.Watchdog_Vault_Handle,
	guardian_proc:            engine.BG_Process,
	meta_timer:               f32,
	last_meta_hash:           u64,
	last_tabs_rev:            u64,
	tabs_idle_sec:            f32,
	last_scene_mut_seq:       u64,
	last_scene_sid:           u32,
	last_scene_dirty:         bool,
	scene_idle_sec:           f32,
	has_pending_restore:      bool,
	has_pending_tabs_restore: bool,
	staged_tabs_bytes:        int,
	pending_snap:             engine.Relaunch_SHM_Snapshot,
	pending_tabs_json:        []byte,
	show_banner:              bool,
	exit_code_buf:            [32]u8,
	exit_code_len:            int,
	restored_scene_bytes:     int,
	restored_tabs_count:      int,
	safe_hub_triggered:       bool,
}

// Intercepts `--watchdog-guardian <pid> <vault_name> [restart_args...]` before GPU/SDL init
// so the child process runs as an ultra-lightweight 0% CPU OS guardian.
watchdog_check_guardian_cli :: proc() -> bool {
	args := os.args
	for i := 1; i < len(args); i += 1 {
		if args[i] == "--watchdog-guardian" {
			if i + 2 >= len(args) {
				os.exit(0)
			}
			pid, ok := strconv.parse_int(args[i + 1])
			vault_name := args[i + 2]
			if !ok || pid <= 0 || vault_name == "" {
				os.exit(0)
			}
			restart_args: []string = nil
			if i + 3 < len(args) {
				restart_args = args[i + 3:]
			}
			exe_path, eerr := os.get_executable_path(context.temp_allocator)
			if eerr != nil || exe_path == "" {
				os.exit(0)
			}
			code := engine.watchdog_run_guardian_blocking(pid, vault_name, exe_path, restart_args)
			os.exit(code)
		}
	}
	return false
}

@(private = "file")
_watchdog_has_skip_flag :: proc() -> bool {
	for a in os.args[1:] {
		if a == "--headless" || a == "--crash-test" {
			return true
		}
	}
	return false
}

@(private = "file")
_watchdog_start_guardian :: proc() {
	if _wd.vault != nil || _watchdog_has_skip_flag() do return

	exe_path, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil || exe_path == "" do return

	pid := os.get_pid()
	_wd.seq += 1
	vault_name := fmt.tprintf("Local\\Haati_WD_%d_%d", pid, _wd.seq)
	v, vok := engine.watchdog_vault_create(vault_name)
	if !vok || v == nil do return

	_wd.vault = v
	_wd.meta_timer = 0.45
	_wd.tabs_idle_sec = 0
	_wd.scene_idle_sec = 0
	_wd.last_meta_hash = 0
	_wd.last_tabs_rev = 0
	_wd.last_scene_dirty = false

	cmd := make([dynamic]string, 0, 5, context.temp_allocator)
	append(&cmd, exe_path, "--watchdog-guardian", fmt.tprintf("%d", pid), vault_name)
	if engine.is_project_hub_startup() {
		append(&cmd, "--project-hub")
	} else if proj := engine.active_project_root(); proj != "" {
		append(&cmd, fmt.tprintf("--project=%s", proj))
	}

	env := make([dynamic]string, context.temp_allocator)
	if cur, cerr := os.environ(context.temp_allocator); cerr == nil {
		for kv in cur {
			if strings.has_prefix(kv, "HAATI_WATCHDOG_VAULT=") ||
			   strings.has_prefix(kv, "HAATI_WATCHDOG_EXIT_CODE=") {
				continue
			}
			append(&env, kv)
		}
	}

	proc_out, started := engine.bg_process_start_to_file(
		filepath.dir(exe_path),
		cmd[:],
		env[:],
		"",
	)
	if started {
		_wd.guardian_proc = proc_out
	} else {
		engine.watchdog_vault_close(_wd.vault)
		_wd.vault = nil
	}
}

@(private = "file")
_watchdog_stop_guardian :: proc() {
	if _wd.vault != nil {
		engine.watchdog_vault_mark_clean_exit(_wd.vault)
	}
	if _wd.guardian_proc.handle != nil {
		engine.bg_process_kill(&_wd.guardian_proc)
	} else {
		_wd.guardian_proc = {}
	}
	if _wd.vault != nil {
		engine.watchdog_vault_close(_wd.vault)
		_wd.vault = nil
	}
}

// Consumes any Kernel RAM Vault left behind by an unexpected crash and quarantines Studio/hot-scripts.
// Note: Guardian arming is deferred until after startup warmup (frames_presented >= 120 && uptime_sec >= 3.0)
// so a startup fault can never trigger an infinite crash-restart loop.
watchdog_init :: proc() {
	if _wd.initialized do return
	_wd.initialized = true
	_wd.uptime_sec  = 0

	if safe_env, has_safe := os.lookup_env("HAATI_WD_SAFE_HUB", context.temp_allocator); has_safe && safe_env == "1" {
		_wd.safe_hub_triggered = true
		_wd.show_banner        = true
		wnd.close("odin_micro_studio")
		wnd.close("mh_visual_script")
	}

	if vault_env, has_v := os.lookup_env("HAATI_WATCHDOG_VAULT", context.temp_allocator); has_v && vault_env != "" {
		// Prevent auto-reopened Code Studio / Blueprint Studio from immediately faulting on frame 1 during crash recovery.
		wnd.close("odin_micro_studio")
		wnd.close("mh_visual_script")
		snap, tabs_json, rok := engine.watchdog_vault_read_and_consume(vault_env, context.allocator)
		engine.hot_cartridge_set_quarantined(true)
		_wd.show_banner = true
		_wd.exit_code_len = 0
		if ec, has_ec := os.lookup_env("HAATI_WATCHDOG_EXIT_CODE", context.temp_allocator); has_ec && ec != "" {
			_wd.exit_code_len = copy(_wd.exit_code_buf[:len(_wd.exit_code_buf) - 1], ec)
		}
		exit_str := _wd.exit_code_len > 0 ? string(_wd.exit_code_buf[:_wd.exit_code_len]) : "unknown"
		if rok {
			_wd.has_pending_restore      = true
			_wd.has_pending_tabs_restore = len(tabs_json) > 0
			_wd.staged_tabs_bytes        = len(tabs_json)
			_wd.pending_snap             = snap
			_wd.pending_tabs_json        = tabs_json
			_wd.restored_scene_bytes     = len(snap.scene_bytes)
			log.warningf("[watchdog] Resurrected after unexpected exit (%s); staged %d scene bytes + %d tab bytes; hot scripts & Studio quarantined.", exit_str, len(snap.scene_bytes), len(tabs_json))
		} else {
			engine.relaunch_shm_snapshot_destroy(&snap, context.allocator)
			if tabs_json != nil do delete(tabs_json, context.allocator)
			log.warningf("[watchdog] Resurrected after unexpected exit (%s); hot scripts & Studio quarantined.", exit_str)
		}
	}

	_wd.want_enabled = editor_visuals.code_ide_settings.enable_crash_watchdog
}

watchdog_set_enabled :: proc(enabled: bool) {
	_wd.want_enabled = enabled
	if !_wd.initialized do return
	if enabled {
		if _wd.uptime_sec >= 3.0 {
			_watchdog_start_guardian()
		}
	} else {
		_watchdog_stop_guardian()
	}
}

watchdog_is_armed :: proc() -> bool {
	return _wd.vault != nil
}

watchdog_want_enabled :: proc() -> bool {
	return _wd.want_enabled
}

watchdog_notify_clean_exit :: proc() {
	if _wd.vault != nil {
		engine.watchdog_vault_mark_clean_exit(_wd.vault)
	}
}

watchdog_shutdown :: proc() {
	if !_wd.initialized do return
	if _wd.has_pending_restore {
		engine.relaunch_shm_snapshot_destroy(&_wd.pending_snap, context.allocator)
		_wd.has_pending_restore = false
	}
	if _wd.pending_tabs_json != nil {
		delete(_wd.pending_tabs_json, context.allocator)
		_wd.pending_tabs_json = nil
	}
	_wd.has_pending_tabs_restore = false
	_watchdog_stop_guardian()
	_wd.initialized = false
}

@(private = "file")
_wd_hash_meta_snap :: proc(snap: engine.Relaunch_SHM_Snapshot) -> u64 {
	h := u64(14695981039346656037)
	vals := [11]f32{
		snap.cam_pos.x, snap.cam_pos.y, snap.cam_pos.z,
		snap.cam_yaw, snap.cam_pitch, snap.cam_dist,
		snap.cam_target.x, snap.cam_target.y, snap.cam_target.z,
		snap.cam_ortho ? 1.0 : 0.0, snap.cam_2d_mode ? 1.0 : 0.0,
	}
	h = hash.fnv64a(mem.byte_slice(&vals[0], size_of(vals)), h)
	guid := snap.scene_guid
	h = hash.fnv64a(guid[:], h)
	if len(snap.scene_path) > 0 {
		h = hash.fnv64a(transmute([]u8)snap.scene_path, h)
	}
	if len(snap.selected_lids) > 0 {
		h = hash.fnv64a(mem.byte_slice(raw_data(snap.selected_lids), len(snap.selected_lids) * size_of(u64)), h)
	}
	return h
}

// Applies any staged scene recovery snapshot once scenes settle, and updates the 3 disjoint
// Watchdog Vault zones strictly on dirty revisions with zero periodic `scene_serialize` hitches.
watchdog_tick :: proc(frames_presented: int, dt: f32) {
	dt_c := clamp(dt, 0.0, 0.25)
	_wd.uptime_sec += dt_c

	if _wd.has_pending_restore && frames_presented >= 4 && len(_pending_scene_loads) == 0 {
		relaunch_apply_snapshot(&_wd.pending_snap)
		engine.relaunch_shm_snapshot_destroy(&_wd.pending_snap, context.allocator)
		_wd.has_pending_restore = false
	}

	// Startup crash-loop circuit breaker: only arm the Guardian after surviving 120 frames AND 3s of interactive uptime.
	if _wd.want_enabled && _wd.vault == nil && frames_presented >= 120 && _wd.uptime_sec >= 3.0 {
		_watchdog_start_guardian()
	}

	if _wd.vault == nil || frames_presented < 5 do return

	// Zone 0: Camera, selection & active scene path/GUID (~200 ns, only when changed)
	_wd.meta_timer += dt_c
	if _wd.meta_timer >= 0.5 && !sim_is_active() {
		_wd.meta_timer = 0
		lids := make([dynamic]u64, 0, 8, context.temp_allocator)
		if w := engine.ctx_world(); w != nil {
			for tH in sel_scene_inspected() {
				if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil && t.local_id != 0 {
					append(&lids, u64(t.local_id))
				}
			}
		}
		active_sc := engine.sm_scene_get_active()
		sc_path := active_sc != nil ? active_sc.path : ""
		sc_guid: [16]u8 = {}
		if sc_path != "" {
			if g, gok := engine.asset_db_get_guid(sc_path); gok {
				sc_guid = ([16]u8)(g)
			}
		}
		meta_snap := engine.Relaunch_SHM_Snapshot{
			cam_pos       = scene_cam_pos,
			cam_yaw       = scene_cam_yaw,
			cam_pitch     = scene_cam_pitch,
			cam_dist      = scene_cam_dist,
			cam_target    = scene_cam_target,
			cam_ortho     = scene_cam_ortho,
			cam_2d_mode   = scene_2d_mode,
			scene_guid    = sc_guid,
			selected_lids = lids[:],
			scene_path    = sc_path,
		}
		mh := _wd_hash_meta_snap(meta_snap)
		if mh != _wd.last_meta_hash {
			if engine.watchdog_vault_write_meta(_wd.vault, meta_snap) {
				_wd.last_meta_hash = mh
			}
		}
	}

	// Zone 1: Dirty Code Studio tabs (`0.00 ms` unless an actual tab edit happened, debounced 1.2s)
	cur_tabs_rev := cs.dirty_tabs_revision()
	if cur_tabs_rev != _wd.last_tabs_rev {
		_wd.tabs_idle_sec += dt_c
		if _wd.tabs_idle_sec >= 1.2 {
			_wd.tabs_idle_sec = 0
			tabs_json := cs.export_dirty_tabs_json(context.temp_allocator)
			if engine.watchdog_vault_write_tabs(_wd.vault, tabs_json) {
				_wd.last_tabs_rev = cur_tabs_rev
			}
		}
	} else {
		_wd.tabs_idle_sec = 0
	}

	// Zone 2: Unsaved Scene Bytes (`0.00 ms` unless scene actually mutated via Undo/Edit)
	active_sc := engine.sm_scene_get_active()
	cur_mut   := undo.current_scene_mutation_seq()
	sc_dirty  := active_sc != nil && active_sc.dirty
	sc_sid    := active_sc != nil ? active_sc.session_id : 0
	if !sc_dirty {
		_wd.scene_idle_sec = 0
		if _wd.last_scene_dirty || sc_sid != _wd.last_scene_sid {
			_ = engine.watchdog_vault_write_scene(_wd.vault, false, nil)
			_wd.last_scene_dirty   = false
			_wd.last_scene_mut_seq = cur_mut
			_wd.last_scene_sid     = sc_sid
		}
	} else if cur_mut != _wd.last_scene_mut_seq || sc_sid != _wd.last_scene_sid || !_wd.last_scene_dirty {
		if !sim_is_active() && !im.IsMouseDown(.Left) && !im.IsMouseDown(.Right) {
			_wd.scene_idle_sec += dt_c
			if _wd.scene_idle_sec >= 2.5 {
				_wd.scene_idle_sec = 0
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				raw, sok := engine.scene_serialize(active_sc)
				context.allocator = prev_alloc
				if sok && len(raw) > 0 {
					_ = engine.watchdog_vault_write_scene(_wd.vault, true, raw)
				} else {
					_ = engine.watchdog_vault_write_scene(_wd.vault, false, nil)
				}
				if sok && raw != nil {
					delete(raw, runtime.default_allocator())
				}
				_wd.last_scene_dirty   = true
				_wd.last_scene_mut_seq = cur_mut
				_wd.last_scene_sid     = sc_sid
			}
		}
	} else {
		_wd.scene_idle_sec = 0
	}
}

// Non-intrusive top-center recovery banner shown after Watchdog Guardian resurrection.
watchdog_draw_recovery_banner :: proc() {
	if !_wd.show_banner do return

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
	if im.Begin("##wd_recovery_banner", nil, flags) {
		exit_str := _wd.exit_code_len > 0 ? string(_wd.exit_code_buf[:_wd.exit_code_len]) : "unknown"
		quarantined := engine.hot_cartridge_is_quarantined()

		widgets.watch_wolf_draw(36.0, p.status_warning)
		im.SameLine(0, 12)
		im.BeginGroup()
		widgets.text_coloredf(p.status_error, "%s Watch-Wolf Recovery -- Restored From Kernel RAM Vault", icons.ICON_MD_WARNING)
		if _wd.safe_hub_triggered {
			widgets.text_coloredf(p.status_warning, "Watch-Wolf Safe Mode: 2 rapid crashes detected (<90s) -- booted safely into Project Hub.")
		}
		if _wd.has_pending_tabs_restore && len(_wd.pending_tabs_json) > 0 {
			widgets.textf("Unexpected exit (code %s): recovered %d scene byte(s) + staged %d unsaved script byte(s).", exit_str, _wd.restored_scene_bytes, _wd.staged_tabs_bytes)
		} else {
			widgets.textf("Unexpected exit (code %s): recovered %d scene byte(s) and %d dirty script tab(s).", exit_str, _wd.restored_scene_bytes, _wd.restored_tabs_count)
		}
		if quarantined {
			widgets.text_coloredf(p.status_warning, "Hot scripts are QUARANTINED to prevent repeat crashes. Fix/Recompile (F7) or Re-Arm manually.")
		} else {
			widgets.text_disabledf("Hot scripts re-armed.")
		}
		im.EndGroup()

		im.Spacing()
		if _wd.has_pending_tabs_restore && len(_wd.pending_tabs_json) > 0 {
			if im.Button("Restore Unsaved Script Tabs") {
				_wd.restored_tabs_count = cs.restore_dirty_tabs_json(_wd.pending_tabs_json)
				delete(_wd.pending_tabs_json, context.allocator)
				_wd.pending_tabs_json = nil
				_wd.has_pending_tabs_restore = false
				if _wd.restored_tabs_count > 0 {
					wnd.open("odin_micro_studio")
				}
			}
			im.SameLine(0, 8)
			if im.Button("Discard Unsaved Tabs") {
				delete(_wd.pending_tabs_json, context.allocator)
				_wd.pending_tabs_json = nil
				_wd.has_pending_tabs_restore = false
			}
			im.SameLine(0, 8)
		}
		if im.Button("Open Crash Log") {
			lp := crash_journal.last_path()
			if lp == "" || !os.exists(lp) {
				lp = "logs/crash_last.log"
			}
			if os.exists(lp) {
				engine.os_open_in_os(lp)
			}
		}
		if quarantined {
			im.SameLine(0, 8)
			if im.Button("Re-Arm Scripts") {
				engine.hot_cartridge_clear_faults()
			}
		}
		if !engine.is_project_hub_startup() {
			im.SameLine(0, 8)
			if im.Button("Open Project Hub") {
				relaunch_boot_to_project_hub()
			}
		}
		im.SameLine(0, 8)
		if im.Button("Dismiss") {
			_wd.show_banner = false
		}
	}
	im.End()
}
