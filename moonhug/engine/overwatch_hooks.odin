package engine

// =============================================================================
// Dynamic Extend & Retract Engine Data Hooks for Out-of-Process Overwatch
// =============================================================================
// Design Contract:
// - When Overwatch is STOPPED, `g_overwatch_hooks_extended` is `false` and all
//   hook function pointers in `_ow_hooks` are `nil`. Every hook call site in the
//   engine & editor reduces to a single predicted boolean check (~0.3 ns,
//   0 allocations, 0 syscalls, 0 disk I/O).
// - When Overwatch is STARTED (from the corner toolbar button or test harness),
//   `overwatch_extend_hooks(...)` maps the OS Shared Memory segment and wires
//   the live vtable callbacks.
// - When Overwatch is STOPPED (or the external `MoonHug_Overwatch.exe` process
//   exits/requests stop), `overwatch_retract_hooks()` tears down the vtable and
//   unmaps the segment immediately.

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import "crash_journal"
import ow "overwatch_ipc"

Overwatch_Hook_VTable :: struct {
	on_phase_begin: proc(phase: ow.Overwatch_Phase, ctx_label: string),
	on_phase_end:   proc(phase: ow.Overwatch_Phase),
	on_event:       proc(kind: ow.Overwatch_Event_Kind, category: string, detail: string, duration_ms: f32),
	on_frame_end:   proc(dt_sec: f32, sim_active: bool),
}

// Single cache-line hot flag: `false` by default (hooks RETRACTED -> 0ns cost).
g_overwatch_hooks_extended:     bool   = false
g_overwatch_output_dir:         string = "logs/overwatch"
g_overwatch_alert_threshold_ms: f32    = 16.6667
g_overwatch_state_sync_hook:    proc(active: bool, out_dir: ^string, thresh_ms: ^f32)

@(private = "file")
_ow_hooks: Overwatch_Hook_VTable

@(private = "file")
_ow_state: struct {
	mapping:             ow.SHM_Mapping,
	shm_name_buf:        [128]u8,
	shm_name_len:        int,
	session_start_tick:  time.Tick,
	frame_start_tick:    time.Tick,
	phase_start_tick:    time.Tick,
	active_phase:        ow.Overwatch_Phase,
	frame_number:        u64,
	accum_sim_ms:        f32,
	accum_ui_ms:         f32,
	accum_render_ms:     f32,
	accum_present_ms:    f32,
	frame_raycasts:      u16,
	mem_sample_cooldown: u32,
	cached_mem_mb:       f32,
	last_action_buf:     [128]u8,
	last_action_len:     int,
}

@(optimization_mode = "favor_size")
overwatch_hooks_extended :: #force_inline proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(&g_overwatch_hooks_extended, .Relaxed)
}

overwatch_shm_name :: proc() -> string {
	return string(_ow_state.shm_name_buf[:_ow_state.shm_name_len])
}

overwatch_spike_count :: proc() -> u32 {
	if !overwatch_hooks_extended() || _ow_state.mapping.block == nil do return 0
	return intrinsics.atomic_load_explicit(&_ow_state.mapping.block.header.total_spikes, .Relaxed)
}

overwatch_recorder_pid :: proc() -> u32 {
	if !overwatch_hooks_extended() || _ow_state.mapping.block == nil do return 0
	return intrinsics.atomic_load_explicit(&_ow_state.mapping.block.header.recorder_pid, .Acquire)
}

overwatch_stop_requested_by_recorder :: proc() -> bool {
	if !overwatch_hooks_extended() || _ow_state.mapping.block == nil do return false
	return bool(intrinsics.atomic_load_explicit(&_ow_state.mapping.block.header.stop_requested, .Acquire))
}

// EXTENDS all engine data hooks and opens the lock-free OS Shared Memory bridge.
overwatch_extend_hooks :: proc(shm_name := "", output_dir := "logs/overwatch", alert_threshold_ms: f32 = 16.6667) -> (actual_shm_name: string, ok: bool) {
	if overwatch_hooks_extended() {
		return overwatch_shm_name(), true
	}

	pid := u32(os.get_pid())
	resolved_name := shm_name
	if resolved_name == "" {
		resolved_name = fmt.tprintf("%s%d", ow.OW_DEFAULT_SHM_PREFIX, pid)
	}

	mapping, map_ok := ow.shm_create(resolved_name)
	if !map_ok || mapping.block == nil {
		return "", false
	}

	now_ns := time.now()._nsec
	blk := mapping.block
	blk.header.magic                 = ow.OW_MAGIC
	blk.header.version               = ow.OW_VERSION
	blk.header.engine_pid            = pid
	blk.header.recorder_pid          = 0
	blk.header.stop_requested        = false
	blk.header.marker_requested      = false
	blk.header.session_start_unix_ms = now_ns / 1_000_000
	blk.header.alert_threshold_ms    = alert_threshold_ms > 1.0 ? alert_threshold_ms : 16.6667
	blk.header.total_spikes          = 0
	blk.header.max_dt_ms_x100        = 0
	blk.header.inflight_phase        = u32(ow.Overwatch_Phase.Idle)
	ow.write_fixed_str(blk.header.output_dir[:], output_dir != "" ? output_dir : "logs/overwatch")
	ow.write_fixed_str(blk.header.inflight_context[:], "Hooks Extended")
	intrinsics.atomic_store_explicit(&blk.header.engine_heartbeat_ns, now_ns, .Release)
	intrinsics.atomic_store_explicit(&blk.header.hooks_extended, true, .Release)

	_ow_state.mapping            = mapping
	_ow_state.session_start_tick = time.tick_now()
	_ow_state.frame_start_tick   = _ow_state.session_start_tick
	_ow_state.phase_start_tick   = _ow_state.session_start_tick
	_ow_state.active_phase       = .Idle
	_ow_state.frame_number       = 0
	_ow_state.cached_mem_mb      = ow.current_working_set_mb()
	_ow_state.mem_sample_cooldown = 0

	n_copy := min(len(resolved_name), len(_ow_state.shm_name_buf))
	copy(_ow_state.shm_name_buf[:n_copy], transmute([]u8)resolved_name[:n_copy])
	_ow_state.shm_name_len = n_copy

	// Wire live hook vtable!
	_ow_hooks = Overwatch_Hook_VTable{
		on_phase_begin = _impl_phase_begin,
		on_phase_end   = _impl_phase_end,
		on_event       = _impl_event,
		on_frame_end   = _impl_frame_end,
	}
	intrinsics.atomic_store_explicit(&g_overwatch_hooks_extended, true, .Release)

	ow.push_event(blk, 0, 0.0, .Session_Lifecycle, .Idle, 0, "Overwatch", "Engine data hooks EXTENDED — Flight Recording started")
	return overwatch_shm_name(), true
}

// RETRACTS all engine data hooks back to 0ns no-ops and signals the external recorder.
overwatch_retract_hooks :: proc(reason := "User stopped recording") {
	if !overwatch_hooks_extended() do return

	// 1. Disarm fast-path guard FIRST so all hook sites immediately become no-ops
	intrinsics.atomic_store_explicit(&g_overwatch_hooks_extended, false, .Release)
	_ow_hooks = {}

	// 2. Push final lifecycle event and mark `hooks_extended = false` + `stop_requested = true`
	//    so `MoonHug_Overwatch.exe` drains any remaining buffered samples and finalizes cleanly!
	if blk := _ow_state.mapping.block; blk != nil {
		elapsed_ms := time.duration_milliseconds(time.tick_since(_ow_state.session_start_tick))
		ow.push_event(blk, _ow_state.frame_number, elapsed_ms, .Session_Lifecycle, .Idle, 0, "Overwatch", reason)
		intrinsics.atomic_store_explicit(&blk.header.hooks_extended, false, .Release)
		intrinsics.atomic_store_explicit(&blk.header.stop_requested, true, .Release)
	}

	ow.shm_close(&_ow_state.mapping)
	_ow_state.shm_name_len = 0
	crash_journal.breadcrumb_clear()
}

// =============================================================================
// Zero-Overhead Hook Entry Points (1 branch when retracted!)
// =============================================================================

overwatch_frame_begin :: #force_inline proc() {
	if !overwatch_hooks_extended() do return
	_ow_state.frame_start_tick = time.tick_now()
	_ow_state.accum_sim_ms     = 0
	_ow_state.accum_ui_ms      = 0
	_ow_state.accum_render_ms  = 0
	_ow_state.accum_present_ms = 0
	_ow_state.frame_raycasts   = 0
	if blk := _ow_state.mapping.block; blk != nil {
		intrinsics.atomic_store_explicit(&blk.header.engine_heartbeat_ns, time.now()._nsec, .Release)
		if bool(intrinsics.atomic_load_explicit(&blk.header.marker_requested, .Acquire)) {
			intrinsics.atomic_store_explicit(&blk.header.marker_requested, false, .Release)
			overwatch_record_event(.Bookmark, "Bookmark", "Manual marker dropped from Overwatch Recorder UI")
		}
	}
}

overwatch_phase_begin :: #force_inline proc(phase: ow.Overwatch_Phase, ctx_label := "") {
	if !overwatch_hooks_extended() do return
	if fn := _ow_hooks.on_phase_begin; fn != nil do fn(phase, ctx_label)
}

overwatch_phase_end :: #force_inline proc(phase: ow.Overwatch_Phase) {
	if !overwatch_hooks_extended() do return
	if fn := _ow_hooks.on_phase_end; fn != nil do fn(phase)
}

overwatch_record_event :: #force_inline proc(kind: ow.Overwatch_Event_Kind, category: string, detail: string, duration_ms: f32 = 0) {
	if !overwatch_hooks_extended() do return
	if fn := _ow_hooks.on_event; fn != nil do fn(kind, category, detail, duration_ms)
}

overwatch_frame_end :: #force_inline proc(dt_sec: f32, sim_active: bool) {
	if !overwatch_hooks_extended() do return
	if fn := _ow_hooks.on_frame_end; fn != nil do fn(dt_sec, sim_active)
}

overwatch_set_context_snapshot :: #force_inline proc(scene_path: string, selected_name: string) {
	if !overwatch_hooks_extended() do return
	if blk := _ow_state.mapping.block; blk != nil {
		ow.write_fixed_str(blk.header.active_scene[:], scene_path)
		ow.write_fixed_str(blk.header.selected_object[:], selected_name)
	}
}

overwatch_push_gameplay_sample :: #force_inline proc(raycast_count: int, pawn_state: string) {
	if !overwatch_hooks_extended() do return
	_ow_state.frame_raycasts = u16(clamp(raycast_count, 0, 65535))
	if pawn_state != "" && _ow_state.mapping.block != nil {
		ow.write_fixed_str(_ow_state.mapping.block.header.pawn_state[:], pawn_state)
	}
}

// =============================================================================
// Private Extended Implementations (Only invoked while hooks are EXTENDED)
// =============================================================================

@(private = "file")
_impl_phase_begin :: proc(phase: ow.Overwatch_Phase, ctx_label: string) {
	_ow_state.active_phase     = phase
	_ow_state.phase_start_tick = time.tick_now()
	if blk := _ow_state.mapping.block; blk != nil {
		intrinsics.atomic_store_explicit(&blk.header.inflight_enter_ns, time.now()._nsec, .Relaxed)
		intrinsics.atomic_store_explicit(&blk.header.inflight_phase, u32(phase), .Release)
		if ctx_label != "" {
			ow.write_fixed_str(blk.header.inflight_context[:], ctx_label)
			crash_journal.breadcrumb(ctx_label)
		} else {
			crash_journal.breadcrumb(ow.phase_name(phase))
		}
	}
}

@(private = "file")
_impl_phase_end :: proc(phase: ow.Overwatch_Phase) {
	dur_ms := f32(time.duration_milliseconds(time.tick_since(_ow_state.phase_start_tick)))
	#partial switch phase {
	case .Sim_Tick:
		_ow_state.accum_sim_ms += dur_ms
	case .Editor_UI, .Plugin_Windows, .Asset_Refresh, .Hot_Cartridge:
		_ow_state.accum_ui_ms += dur_ms
	case .Thumbnails, .Gizmo_Pass, .Scene_3D_View, .Scene_2D_View, .Game_View:
		_ow_state.accum_render_ms += dur_ms
	case .Swapchain_Present:
		_ow_state.accum_present_ms += dur_ms
	}
	_ow_state.active_phase = .Idle
	if blk := _ow_state.mapping.block; blk != nil {
		intrinsics.atomic_store_explicit(&blk.header.inflight_phase, u32(ow.Overwatch_Phase.Idle), .Release)
	}
}

@(private = "file")
_impl_event :: proc(kind: ow.Overwatch_Event_Kind, category: string, detail: string, duration_ms: f32) {
	blk := _ow_state.mapping.block
	if blk == nil do return

	if kind != .Frame_Spike && kind != .Session_Lifecycle {
		n := min(len(detail), len(_ow_state.last_action_buf))
		copy(_ow_state.last_action_buf[:n], transmute([]u8)detail[:n])
		_ow_state.last_action_len = n
		crash_journal.breadcrumb(detail)
	}

	elapsed_ms := time.duration_milliseconds(time.tick_since(_ow_state.session_start_tick))
	ow.push_event(blk, _ow_state.frame_number, elapsed_ms, kind, _ow_state.active_phase, duration_ms, category, detail)
}

@(private = "file")
_impl_frame_end :: proc(dt_sec: f32, sim_active: bool) {
	blk := _ow_state.mapping.block
	if blk == nil do return

	_ow_state.frame_number += 1
	measured_ms := f32(time.duration_milliseconds(time.tick_since(_ow_state.frame_start_tick)))
	dt_ms := max(dt_sec * 1000.0, measured_ms)
	fps: f32 = dt_ms > 0.001 ? (1000.0 / dt_ms) : 0.0

	// Query OS working set only once every 30 frames so even extended mode stays ~0 overhead!
	if _ow_state.mem_sample_cooldown == 0 {
		_ow_state.cached_mem_mb = ow.current_working_set_mb()
		_ow_state.mem_sample_cooldown = 30
	} else {
		_ow_state.mem_sample_cooldown -= 1
	}

	// Find dominant subsystem phase for this frame
	culprit := ow.Overwatch_Phase.Editor_UI
	best_p  := _ow_state.accum_ui_ms
	if _ow_state.accum_sim_ms > best_p {
		best_p  = _ow_state.accum_sim_ms
		culprit = .Sim_Tick
	}
	if _ow_state.accum_render_ms > best_p {
		best_p  = _ow_state.accum_render_ms
		culprit = .Scene_3D_View
	}
	if _ow_state.accum_present_ms > best_p {
		best_p  = _ow_state.accum_present_ms
		culprit = .Swapchain_Present
	}

	thresh := blk.header.alert_threshold_ms > 1.0 ? blk.header.alert_threshold_ms : 16.6667
	flags: u8 = 0
	if sim_active do flags |= ow.OW_FLAG_SIM_ACTIVE
	if dt_ms >= thresh do flags |= ow.OW_FLAG_SPIKE_WARN
	if dt_ms >= 33.333 do flags |= ow.OW_FLAG_SPIKE_SEVERE

	t_count: u32 = 0
	if uc := ctx_get(); uc != nil && uc.world != nil {
		t_count = u32(uc.world.transforms.count)
	}

	elapsed_ms := time.duration_milliseconds(time.tick_since(_ow_state.session_start_tick))
	ow.push_frame_sample(blk, ow.Overwatch_Frame_Sample{
		frame_number    = _ow_state.frame_number,
		elapsed_ms      = elapsed_ms,
		dt_ms           = dt_ms,
		fps             = fps,
		sim_ms          = _ow_state.accum_sim_ms,
		ui_ms           = _ow_state.accum_ui_ms,
		render_ms       = _ow_state.accum_render_ms,
		present_ms      = _ow_state.accum_present_ms,
		working_set_mb  = _ow_state.cached_mem_mb,
		transform_count = t_count,
		raycast_count   = _ow_state.frame_raycasts,
		culprit_phase   = culprit,
		flags           = flags,
	})

	dt_x100 := u32(dt_ms * 100.0)
	if dt_x100 > blk.header.max_dt_ms_x100 {
		blk.header.max_dt_ms_x100 = dt_x100
	}

	// Emit an explicit Spike Event when frame exceeds threshold (skipping warmup frames 1..5)
	if (flags & ow.OW_FLAG_SPIKE_WARN) != 0 && _ow_state.frame_number > 5 {
		new_spikes := intrinsics.atomic_add_explicit(&blk.header.total_spikes, 1, .Relaxed) + 1
		_ = new_spikes
		last_act := _ow_state.last_action_len > 0 ? string(_ow_state.last_action_buf[:_ow_state.last_action_len]) : "Idle / Viewport"
		spike_msg := fmt.tprintf(
			"%.2f ms (Sim:%.1f UI:%.1f Rnd:%.1f Prs:%.1f) | Culprit: %s | After: %s",
			dt_ms,
			_ow_state.accum_sim_ms,
			_ow_state.accum_ui_ms,
			_ow_state.accum_render_ms,
			_ow_state.accum_present_ms,
			ow.phase_name(culprit),
			last_act,
		)
		ow.push_event(blk, _ow_state.frame_number, elapsed_ms, .Frame_Spike, culprit, dt_ms, "Frame Spike", spike_msg)
	}

	intrinsics.atomic_store_explicit(&blk.header.engine_heartbeat_ns, time.now()._nsec, .Release)
}
