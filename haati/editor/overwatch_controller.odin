package editor

// =============================================================================
// Out-of-Process Overwatch Flight Recorder Controller & Corner Island Button
// =============================================================================
// Connects the top-right Corner Button Island (`zone="right", order=18`) to:
// 1. Dynamic engine & editor data hook EXTENSION (`overwatch_extend_hooks`) when
//    started, and full RETRACTION (`overwatch_retract_hooks` -> 0ns cost) when stopped.
// 2. Spawning & monitoring the standalone `builds/MoonHug_Overwatch.exe` process
//    over lock-free OS Shared Memory (`moonhug:engine/overwatch_ipc`), so a hard
//    crash (`EXCEPTION_ACCESS_VIOLATION`) or infinite-loop freeze is captured
//    alongside "What You Did" and per-phase frame spikes!

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import im "haati:external/odin-imgui"
import "../engine"
import "../engine/log"
import ow "haati:engine/overwatch_ipc"
import cs "haati:editor/code_studio"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/undo"
import wnd "haati:editor/window"
import "widgets"

@(private = "file")
_ow_ctrl: struct {
	proc_handle:        os.Process,
	has_proc_handle:    bool,
	last_sel_handle:    engine.Transform_Handle,
	last_sim_active:    bool,
	last_hot_gen:       int,
	last_moving_window: bool,
	last_drag_drop:     bool,
	started_grace_sec:  f32,
}

@(private = "file")
_on_window_hook :: proc(action: string, id: string) {
	engine.overwatch_record_event(.Window_Tab, "Window", fmt.tprintf("%s: %s", action, id))
}

@(private = "file")
_on_undo_hook :: proc(action: string, label: string) {
	engine.overwatch_record_event(.Undo_Redo, action, fmt.tprintf("%s: %s", action, label))
}

overwatch_recorder_is_active :: proc() -> bool {
	return engine.overwatch_hooks_extended()
}

overwatch_recorder_start :: proc(headless := false) -> bool {
	if engine.overwatch_hooks_extended() do return true

	if engine.g_overwatch_state_sync_hook != nil {
		engine.g_overwatch_state_sync_hook(true, &engine.g_overwatch_output_dir, &engine.g_overwatch_alert_threshold_ms)
	}
	out_dir := engine.g_overwatch_output_dir
	if out_dir == "" do out_dir = "logs/overwatch"
	thresh := engine.g_overwatch_alert_threshold_ms
	if thresh <= 1.0 do thresh = 16.6667

	// 1. EXTEND engine & editor data hooks!
	shm_name, ok := engine.overwatch_extend_hooks("", out_dir, thresh)
	if !ok {
		log.error("[Overwatch] Failed to create OS Shared Memory segment for Flight Recorder.")
		return false
	}

	wnd.on_window_event_hook = _on_window_hook
	undo.on_undo_event_hook  = _on_undo_hook
	_ow_ctrl.started_grace_sec  = 3.0
	_ow_ctrl.last_sel_handle    = {}
	_ow_ctrl.last_sim_active    = sim_is_active()
	_, hot_gen, _, _, _ := engine.hot_cartridge_status()
	_ow_ctrl.last_hot_gen       = hot_gen
	_ow_ctrl.last_moving_window = false
	_ow_ctrl.last_drag_drop     = false

	// 2. Locate (or auto-build if missing) `builds/Haati_Overwatch.exe` and spawn detached!
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	exe_ext :: ".exe" when ODIN_OS == .Windows else ""
	bin_abs, _ := filepath.join({repo_root, "builds", "Haati_Overwatch" + exe_ext}, context.temp_allocator)

	if !os.exists(bin_abs) {
		odin_exe := engine.resolve_odin_binary(context.temp_allocator)
		if bp, started := engine.bg_process_start_to_file(repo_root, {odin_exe, "run", "tools/haati", "--", "overwatch"}); started {
			_, _ = engine.bg_process_wait(&bp, 30000)
		}
	}

	cmd := make([dynamic]string, 0, 5, context.temp_allocator)
	append(&cmd, bin_abs)
	append(&cmd, fmt.tprintf("--shm=%s", shm_name))
	append(&cmd, fmt.tprintf("--pid=%d", os.get_pid()))
	append(&cmd, fmt.tprintf("--repo=%s", repo_root))
	if headless do append(&cmd, "--headless")

	p, perr := os.process_start(os.Process_Desc{
		working_dir = repo_root,
		command     = cmd[:],
	})
	if perr != nil {
		log.errorf("[Overwatch] Failed to launch external recorder %s: %v — retracting hooks", bin_abs, perr)
		overwatch_recorder_stop("Failed to spawn external recorder")
		return false
	}

	if _ow_ctrl.has_proc_handle {
		_, _ = os.process_wait(_ow_ctrl.proc_handle, 0)
	}
	_ow_ctrl.proc_handle     = p
	_ow_ctrl.has_proc_handle = true

	log.infof("[Overwatch] Out-of-process Flight Recorder started (SHM: %s) — Engine hooks EXTENDED", shm_name)
	return true
}

overwatch_recorder_stop :: proc(reason := "Stopped from Corner Island Button") {
	// 1. RETRACT editor & engine hooks immediately -> back to 0ns cost!
	wnd.on_window_event_hook = nil
	undo.on_undo_event_hook  = nil
	if engine.g_overwatch_state_sync_hook != nil {
		engine.g_overwatch_state_sync_hook(false, &engine.g_overwatch_output_dir, &engine.g_overwatch_alert_threshold_ms)
	}

	if engine.overwatch_hooks_extended() {
		engine.overwatch_retract_hooks(reason)
		log.info("[Overwatch] Flight Recording saved to logs/overwatch/overwatch_latest.md — Engine hooks RETRACTED (0ns)")
	}

	if _ow_ctrl.has_proc_handle {
		if st, werr := os.process_wait(_ow_ctrl.proc_handle, 0); werr == nil && st.exited {
			_ow_ctrl.has_proc_handle = false
		}
	}
}

overwatch_recorder_shutdown :: proc() {
	if engine.overwatch_hooks_extended() {
		overwatch_recorder_stop("Editor clean shutdown")
	} else if _ow_ctrl.has_proc_handle {
		_, _ = os.process_wait(_ow_ctrl.proc_handle, 0)
		_ow_ctrl.has_proc_handle = false
	}
}

// Polled once per frame in `main.odin`: 1 predicted branch when stopped!
overwatch_recorder_tick :: proc(dt_sec: f32) {
	if !engine.overwatch_hooks_extended() do return

	if _ow_ctrl.started_grace_sec > 0 {
		_ow_ctrl.started_grace_sec = max(_ow_ctrl.started_grace_sec - dt_sec, 0)
	}

	// 1. Auto-retract if the external Overwatch window clicked "Stop & Save" or was closed!
	if engine.overwatch_stop_requested_by_recorder() {
		overwatch_recorder_stop("Stopped from external Overwatch Recorder window")
		return
	}
	rec_pid := engine.overwatch_recorder_pid()
	if rec_pid != 0 && _ow_ctrl.started_grace_sec <= 0 {
		alive, _ := ow.is_pid_alive(rec_pid)
		if !alive {
			overwatch_recorder_stop("External Overwatch process closed")
			return
		}
	}

	// 2. Capture "What You Did" milestones automatically while hooks are extended!
	// 2a. Scene & Active Selection Diff
	sc := engine.sm_scene_get_active()
	sc_path := (sc != nil && sc.path != "") ? sc.path : "(unsaved scene)"
	sel_h := sel_scene_active()
	sel_name := "(none)"
	if sel_h != {} {
		if uc := engine.ctx_get(); uc != nil && uc.world != nil {
			if t := engine.pool_get(&uc.world.transforms, engine.Handle(sel_h)); t != nil {
				sel_name = t.name
			}
		}
	}
	engine.overwatch_set_context_snapshot(sc_path, sel_name)

	if sel_h != _ow_ctrl.last_sel_handle {
		_ow_ctrl.last_sel_handle = sel_h
		if sel_h != {} {
			engine.overwatch_record_event(.Selection, "Selection", fmt.tprintf("Selected entity '%s'", sel_name))
		} else {
			engine.overwatch_record_event(.Selection, "Selection", "Cleared scene selection")
		}
	}

	// 2b. Simulation Play / Stop Transitions
	sim_now := sim_is_active()
	if sim_now != _ow_ctrl.last_sim_active {
		_ow_ctrl.last_sim_active = sim_now
		engine.overwatch_record_event(.Simulation, "Simulation", sim_now ? "Entered Play / Simulate Mode" : "Exited Play / Simulate Mode")
	}

	// 2c. Hot Cartridge Swap Milestones
	hot_st, hot_gen, hot_ms, hot_msg, _ := engine.hot_cartridge_status()
	if hot_gen != _ow_ctrl.last_hot_gen && hot_gen > 0 {
		_ow_ctrl.last_hot_gen = hot_gen
		engine.overwatch_record_event(.Hot_Reload, "Hot Cartridge", hot_msg, f32(hot_ms))
	} else if hot_st == .Compile_Failed && _ow_ctrl.last_hot_gen != -1 {
		_ow_ctrl.last_hot_gen = -1
		engine.overwatch_record_event(.Warning_Error, "Hot Cartridge", hot_msg, f32(hot_ms))
	}

	// 2d. Key Chords & Clicked UI Controls ("what I clicked / pressed")
	io := im.GetIO()
	if io.KeyCtrl && im.IsKeyPressed(.S, false) {
		engine.overwatch_record_event(.User_Action, "Shortcut", "Pressed Ctrl+S (Save)")
	}
	if im.IsKeyPressed(.F7, false) {
		engine.overwatch_record_event(.User_Action, "Shortcut", "Pressed F7 (Hot-Swap / Bake)")
	}
	if !io.WantTextInput && im.IsKeyPressed(.Delete, false) {
		engine.overwatch_record_event(.User_Action, "Shortcut", fmt.tprintf("Pressed Delete (Selected: %s)", sel_name))
	}

	// 2e. Window Drag & Asset Drag-and-Drop Milestones
	g_ctx := im.GetCurrentContext()
	moving_now := g_ctx != nil && g_ctx.MovingWindow != nil
	if moving_now != _ow_ctrl.last_moving_window {
		_ow_ctrl.last_moving_window = moving_now
		if moving_now {
			w_name := g_ctx.MovingWindow.Name != nil ? string(g_ctx.MovingWindow.Name) : "(window)"
			engine.overwatch_record_event(.User_Action, "WindowDrag", fmt.tprintf("Started dragging window '%s'", w_name))
		} else {
			engine.overwatch_record_event(.User_Action, "WindowDrag", "Ended window drag")
		}
	}
	drag_drop_now := g_ctx != nil && g_ctx.DragDropActive
	if drag_drop_now != _ow_ctrl.last_drag_drop {
		_ow_ctrl.last_drag_drop = drag_drop_now
		engine.overwatch_record_event(.User_Action, "DragDrop", drag_drop_now ? "Started drag-and-drop operation" : "Ended drag-and-drop operation")
	}
}

@(private = "file")
_open_latest_overwatch_report :: proc() {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	out_dir := engine.g_overwatch_output_dir
	if out_dir == "" do out_dir = "logs/overwatch"
	report_abs, _ := filepath.join({repo_root, "haati", out_dir, "overwatch_latest.md"}, context.temp_allocator)
	if os.exists(report_abs) {
		cs.open_file_in_studio(report_abs)
		wnd.open("odin_micro_studio")
	} else {
		log.info("[Overwatch] No overwatch_latest.md report recorded yet — click the Corner Record button first!")
	}
}

// =============================================================================
// Top-Right Corner Button Island Widget (`zone="right", order=18`)
// =============================================================================
// Sits directly inside the right-hand corner island (`[run_debug ▼] [🔧] [🎨] [●] | [⟳]`).

@(toolbar={zone="right", order=18})
_toolbar_overwatch_recorder :: proc() {
	p := thm.palette()
	active := engine.overwatch_hooks_extended()
	spikes := engine.overwatch_spike_count()

	if active {
		pulse := 0.5 + 0.5 * f32(math.sin(im.GetTime() * 5.0))
		rec_dark   := thm.lerp_col(p.status_error, p.bg_canvas, 0.25)
		rec_bright := thm.lerp_col(p.status_error, thm.rgb(0xFFFFFF), 0.14)
		btn_bg     := thm.with_alpha(thm.lerp_col(rec_dark, rec_bright, pulse), 0.92)
		btn_hv     := thm.with_alpha(rec_bright, 1.0)
		btn_act    := thm.with_alpha(thm.lerp_col(p.status_error, p.bg_canvas, 0.40), 1.0)
		text_col   := p.bg_canvas if p.is_light else p.text_primary
		im.PushStyleColorImVec4(.Button, btn_bg)
		im.PushStyleColorImVec4(.ButtonHovered, btn_hv)
		im.PushStyleColorImVec4(.ButtonActive, btn_act)
		im.PushStyleColorImVec4(.Text, text_col)
	} else {
		im.PushStyleColorImVec4(.Text, thm.with_alpha(p.status_error, 0.92))
	}

	lbl := (active && spikes > 0) \
		? fmt.ctprintf("%s %d###ToolbarOverwatchBtn", icons.ICON_MD_RECORD, spikes) \
		: cstring(icons.ICON_MD_RECORD + "###ToolbarOverwatchBtn")

	btn_sz := (active && spikes > 0) ? im.Vec2{0, _toolbar_button_size(BUTTON_PLAY_TEXT).y} : _toolbar_button_size(BUTTON_PLAY_TEXT)
	if im.Button(lbl, btn_sz) {
		if active {
			overwatch_recorder_stop("Stopped via Corner Island Button")
		} else {
			overwatch_recorder_start(false)
		}
	}

	if active {
		im.PopStyleColor(4)
	} else {
		im.PopStyleColor(1)
	}

	if im.IsItemClicked(.Right) {
		im.OpenPopup("##toolbar_overwatch_popup")
	}

	if active {
		widgets.tooltip(fmt.ctprintf(
			"Overwatch Out-of-Process Recorder: ACTIVE (%d spikes)\nEngine Hooks: EXTENDED -> Shared Memory Live\nLeft-Click: Stop Recording & Retract Hooks (0ns)\nRight-Click: Drop Marker / Open Report",
			spikes,
		))
	} else {
		widgets.tooltip(
			"Overwatch Flight & Performance Recorder (Separate Process)\nEngine Hooks: RETRACTED (0ns overhead)\nLeft-Click: Launch Out-of-Process Recorder & Extend Hooks\nRight-Click: Open Latest Report & Spike Settings",
		)
	}

	if im.BeginPopup("##toolbar_overwatch_popup") {
		im.TextColored(p.accent, icons.ICON_MD_RECORD + "  Overwatch Out-of-Process Recorder")
		im.Separator()

		if active {
			if im.MenuItem(icons.ICON_MD_STOP + "  Stop Recording & Retract Engine Hooks") {
				overwatch_recorder_stop("Stopped via Overwatch Popup Menu")
			}
			if im.MenuItem(icons.ICON_MD_ADD + "  Drop Bookmark Marker Now") {
				engine.overwatch_record_event(.Bookmark, "Bookmark", "Manual bookmark dropped from Corner Island Menu")
			}
		} else {
			if im.MenuItem(icons.ICON_MD_RECORD + "  Start Out-of-Process Flight Recording") {
				overwatch_recorder_start(false)
			}
		}

		im.Separator()
		if im.MenuItem(icons.ICON_MD_DESCRIPTION + "  Inspect Latest Report (overwatch_latest.md)") {
			_open_latest_overwatch_report()
		}

		im.Separator()
		im.TextDisabled("Spike Alert Threshold:")
		im.SetNextItemWidth(160)
		if im.SliderFloat("##ow_thresh_ms", &engine.g_overwatch_alert_threshold_ms, 8.33, 50.0, "%.1f ms") {
			if engine.g_overwatch_state_sync_hook != nil {
				engine.g_overwatch_state_sync_hook(active, nil, &engine.g_overwatch_alert_threshold_ms)
			}
		}
		im.EndPopup()
	}
}
