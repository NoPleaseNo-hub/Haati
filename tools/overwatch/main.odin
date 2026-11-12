package overwatch_app

// =============================================================================
// MoonHug Overwatch — Out-of-Process Flight Recorder & Crash/Spike Autopsy
// =============================================================================
// Runs as a completely separate OS process (`builds/MoonHug_Overwatch.exe`).
// Reads lock-free OS Shared Memory (`moonhug:engine/overwatch_ipc`) written by
// `MoonHug.exe` only while engine hooks are EXTENDED.
//
// Why out-of-process?
// - Zero GPU contention (uses lightweight Win32 GDI or `--headless`, 0% GPU).
// - Survives instant engine segfaults (`EXCEPTION_ACCESS_VIOLATION`), stack
//   overflows, aborts, AND detects infinite-loop freezes (`> 2.5s` heartbeat stall)!
// - Writes both a high-rate CSV (`perf_record_<ts>.csv`) and an AI- & human-readable
//   Flight Autopsy Report (`overwatch_latest.md` + `overwatch_<ts>.md`) combining:
//     1. "What You Did" (every window, button, selection, undo/redo, hot-swap)
//     2. Exact Frame Spikes & Per-Phase Millisecond Breakdown
//     3. In-Flight Stuck Phase + Embedded `crash_<pid>.log` if the engine died!

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import ow "moonhug:engine/overwatch_ipc"

Engine_Health :: enum u8 {
	Connecting = 0,
	Recording  = 1,
	Frozen     = 2,
	Crashed    = 3,
	Stopped    = 4,
}

SPARKLINE_CAP :: 220
RECENT_EVENTS_CAP :: 512
TOP_SPIKES_CAP :: 24

Recorder_Session :: struct {
	shm_name:          string,
	repo_root:         string,
	out_dir_abs:       string,
	csv_path:          string,
	md_latest_path:    string,
	md_session_path:   string,
	csv_file:          ^os.File,

	mapping:           ow.SHM_Mapping,
	engine_pid:        u32,
	engine_exit_code:  u32,
	health:            Engine_Health,

	frame_read_seq:    u64,
	event_read_seq:    u64,

	// Rolling sparkline & statistics
	sparkline_ms:      [SPARKLINE_CAP]f32,
	sparkline_flags:   [SPARKLINE_CAP]u8,
	sparkline_head:    int,
	sparkline_count:   int,

	latest_frame:      ow.Overwatch_Frame_Sample,
	total_frames:      u64,
	total_spikes:      u32,
	severe_spikes:     u32,
	max_dt_ms:         f32,
	sum_dt_ms:         f64,
	min_mem_mb:        f32,
	max_mem_mb:        f32,

	// Histogram / sample reservoir for p50 / p95 / p99
	dt_samples:        [dynamic]f32,
	top_spikes:        [dynamic]ow.Overwatch_Frame_Sample,
	events_log:        [dynamic]ow.Overwatch_Event,

	// Last observed engine header snapshot (survives even after SHM closes)
	last_phase:        ow.Overwatch_Phase,
	last_context:      string,
	last_scene:        string,
	last_selected:     string,
	last_pawn_state:   string,
	alert_thresh_ms:   f32,
	hang_duration_ms:  f64,
	crash_log_excerpt: string,

	last_md_flush:     time.Tick,
	finalized:         bool,
}

g_session: Recorder_Session

@(private = "file")
_flag_val :: proc(args: []string, key: string) -> string {
	pref := fmt.tprintf("%s=", key)
	for a in args {
		if strings.has_prefix(a, pref) {
			return a[len(pref):]
		}
	}
	return ""
}

@(private = "file")
_has_flag :: proc(args: []string, key: string) -> bool {
	for a in args do if a == key do return true
	return false
}

main :: proc() {
	args := os.args[1:]
	shm_name  := _flag_val(args, "--shm")
	pid_s     := _flag_val(args, "--pid")
	repo_root := _flag_val(args, "--repo")
	max_ms_s  := _flag_val(args, "--max-ms")
	headless  := _has_flag(args, "--headless")

	if repo_root == "" {
		if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
			repo_root = strings.clone(cwd)
		} else {
			repo_root = "."
		}
	}

	parsed_pid := 0
	if pid_s != "" {
		if p, ok := strconv.parse_int(pid_s); ok do parsed_pid = p
	}
	if shm_name == "" && parsed_pid > 0 {
		shm_name = fmt.tprintf("%s%d", ow.OW_DEFAULT_SHM_PREFIX, parsed_pid)
	}

	g_session.shm_name        = strings.clone(shm_name)
	g_session.repo_root       = strings.clone(repo_root)
	g_session.engine_pid      = u32(parsed_pid)
	g_session.health          = .Connecting
	g_session.alert_thresh_ms = 16.6667
	g_session.last_md_flush   = time.tick_now()

	// Try connecting to Shared Memory (retry up to 2.5s in case launched concurrently)
	deadline := time.now()._nsec + i64(2500 * time.Millisecond)
	for time.now()._nsec < deadline {
		if m, ok := ow.shm_open(g_session.shm_name); ok && m.block != nil {
			if m.block.header.magic == ow.OW_MAGIC {
				g_session.mapping = m
				break
			}
			ow.shm_close(&m)
		}
		time.sleep(15 * time.Millisecond)
	}

	if g_session.mapping.block != nil {
		blk := g_session.mapping.block
		if g_session.engine_pid == 0 {
			g_session.engine_pid = blk.header.engine_pid
		}
		intrinsics.atomic_store_explicit(&blk.header.recorder_pid, u32(os.get_pid()), .Release)
		g_session.health = .Recording
	}

	_init_output_files(&g_session)

	max_ms := 0
	if max_ms_s != "" {
		if m, ok := strconv.parse_int(max_ms_s); ok do max_ms = m
	}

	if headless {
		start_t := time.tick_now()
		for {
			session_poll_and_drain(&g_session)
			if g_session.health == .Stopped || g_session.health == .Crashed {
				break
			}
			if max_ms > 0 && time.duration_milliseconds(time.tick_since(start_t)) >= f64(max_ms) {
				session_request_stop(&g_session)
				session_poll_and_drain(&g_session)
				break
			}
			time.sleep(8 * time.Millisecond)
		}
		session_finalize(&g_session)
	} else {
		run_overwatch_gui(&g_session)
		session_finalize(&g_session)
	}
}

@(private = "file")
_init_output_files :: proc(s: ^Recorder_Session) {
	rel_out := "logs/overwatch"
	if s.mapping.block != nil {
		cfg_out := ow.read_fixed_str(s.mapping.block.header.output_dir[:])
		if cfg_out != "" do rel_out = cfg_out
	}

	// Place under `<repo_root>/moonhug/<rel_out>` if `<repo_root>/moonhug` exists, else `<repo_root>/<rel_out>`
	mh_sub, _ := filepath.join({s.repo_root, "moonhug"}, context.temp_allocator)
	base_dir := os.exists(mh_sub) ? mh_sub : s.repo_root
	out_abs, _ := filepath.join({base_dir, rel_out}, context.temp_allocator)
	os.make_directory_all(out_abs)
	s.out_dir_abs = strings.clone(out_abs)

	ts_ms := time.now()._nsec / 1_000_000
	s.csv_path        = strings.clone(fmt.tprintf("%s/perf_record_%d.csv", out_abs, ts_ms))
	s.md_latest_path  = strings.clone(fmt.tprintf("%s/overwatch_latest.md", out_abs))
	s.md_session_path = strings.clone(fmt.tprintf("%s/overwatch_%d.md", out_abs, ts_ms))

	if f, err := os.open(s.csv_path, os.File_Flags{.Write, .Create, .Trunc}); err == nil {
		s.csv_file = f
		_, _ = os.write_string(f, "frame,elapsed_ms,dt_ms,fps,sim_ms,ui_ms,render_ms,present_ms,mem_mb,transforms,raycasts,culprit_phase,spike_flag\n")
	}
}

session_request_stop :: proc(s: ^Recorder_Session) {
	if s.mapping.block != nil {
		intrinsics.atomic_store_explicit(&s.mapping.block.header.stop_requested, true, .Release)
	}
	if s.health == .Recording || s.health == .Connecting || s.health == .Frozen {
		s.health = .Stopped
	}
}

session_request_bookmark :: proc(s: ^Recorder_Session) {
	if s.mapping.block != nil {
		intrinsics.atomic_store_explicit(&s.mapping.block.header.marker_requested, true, .Release)
	}
}

session_poll_and_drain :: proc(s: ^Recorder_Session) {
	blk := s.mapping.block
	if blk == nil do return

	// 1. Snapshot live header context strings
	s.alert_thresh_ms = blk.header.alert_threshold_ms > 1.0 ? blk.header.alert_threshold_ms : 16.6667
	s.last_phase      = ow.Overwatch_Phase(intrinsics.atomic_load_explicit(&blk.header.inflight_phase, .Acquire))

	delete(s.last_context)
	s.last_context = strings.clone(ow.read_fixed_str(blk.header.inflight_context[:]))
	delete(s.last_scene)
	s.last_scene = strings.clone(ow.read_fixed_str(blk.header.active_scene[:]))
	delete(s.last_selected)
	s.last_selected = strings.clone(ow.read_fixed_str(blk.header.selected_object[:]))
	delete(s.last_pawn_state)
	s.last_pawn_state = strings.clone(ow.read_fixed_str(blk.header.pawn_state[:]))

	// 2. Drain lock-free Frame Ring Buffer
	f_write := intrinsics.atomic_load_explicit(&blk.header.frame_write_seq, .Acquire)
	if f_write > s.frame_read_seq + ow.OW_FRAME_RING_CAP {
		s.frame_read_seq = f_write - ow.OW_FRAME_RING_CAP
	}
	for s.frame_read_seq < f_write {
		next_seq := s.frame_read_seq + 1
		slot := &blk.frames[next_seq & ow.OW_FRAME_RING_MASK]
		slot_seq := intrinsics.atomic_load_explicit(&slot.seq, .Acquire)
		if slot_seq == next_seq {
			sample := slot^
			_ingest_frame(s, sample)
		}
		s.frame_read_seq = next_seq
	}

	// 3. Drain lock-free User Action & Spike Event Ring Buffer
	e_write := intrinsics.atomic_load_explicit(&blk.header.event_write_seq, .Acquire)
	if e_write > s.event_read_seq + ow.OW_EVENT_RING_CAP {
		s.event_read_seq = e_write - ow.OW_EVENT_RING_CAP
	}
	for s.event_read_seq < e_write {
		next_seq := s.event_read_seq + 1
		slot := &blk.events[next_seq & ow.OW_EVENT_RING_MASK]
		slot_seq := intrinsics.atomic_load_explicit(&slot.seq, .Acquire)
		if slot_seq == next_seq {
			ev := slot^
			if len(s.events_log) >= RECENT_EVENTS_CAP {
				ordered_remove(&s.events_log, 0)
			}
			append(&s.events_log, ev)
		}
		s.event_read_seq = next_seq
	}

	// 4. Check Graceful Retraction vs Engine Crash vs Infinite-Loop Freeze!
	hooks_ext := bool(intrinsics.atomic_load_explicit(&blk.header.hooks_extended, .Acquire))
	stop_req  := bool(intrinsics.atomic_load_explicit(&blk.header.stop_requested, .Acquire))

	if !hooks_ext || stop_req {
		if s.health != .Crashed && s.health != .Stopped {
			s.health = .Stopped
			_write_markdown_report(s)
		}
		return
	}

	if s.engine_pid != 0 && s.health != .Crashed && s.health != .Stopped {
		alive, exit_code := ow.is_pid_alive(s.engine_pid)
		if !alive {
			s.engine_exit_code = exit_code
			s.health = (exit_code == 0) ? .Stopped : .Crashed
			if s.health == .Crashed {
				// Give `crash_journal` a brief moment to finish flushing `logs/crash_<pid>.log`
				time.sleep(80 * time.Millisecond)
				_try_attach_crash_log(s)
				crash_md := fmt.tprintf("%s/overwatch_%d_CRASH.md", s.out_dir_abs, time.now()._nsec / 1_000_000)
				delete(s.md_session_path)
				s.md_session_path = strings.clone(crash_md)
			}
			_write_markdown_report(s)
			return
		}

		// Alive — check heartbeat for infinite loop / deadlock hang!
		hb_ns := intrinsics.atomic_load_explicit(&blk.header.engine_heartbeat_ns, .Acquire)
		if hb_ns > 0 {
			stall_ms := f64(time.now()._nsec - hb_ns) / 1_000_000.0
			if stall_ms >= 2500.0 {
				was_frozen := s.health == .Frozen
				s.health = .Frozen
				s.hang_duration_ms = stall_ms
				if !was_frozen {
					_write_markdown_report(s)
				}
			} else if s.health == .Frozen {
				s.health = .Recording
				s.hang_duration_ms = 0
			}
		}
	}

	// Periodic live flush every 750ms so `overwatch_latest.md` is always fresh on disk!
	if time.duration_milliseconds(time.tick_since(s.last_md_flush)) >= 750.0 {
		s.last_md_flush = time.tick_now()
		_write_markdown_report(s)
	}
}

@(private = "file")
_ingest_frame :: proc(s: ^Recorder_Session, sample: ow.Overwatch_Frame_Sample) {
	s.latest_frame = sample
	s.total_frames += 1
	s.sum_dt_ms += f64(sample.dt_ms)
	if sample.dt_ms > s.max_dt_ms do s.max_dt_ms = sample.dt_ms

	if sample.working_set_mb > 0 {
		if s.min_mem_mb == 0 || sample.working_set_mb < s.min_mem_mb do s.min_mem_mb = sample.working_set_mb
		if sample.working_set_mb > s.max_mem_mb do s.max_mem_mb = sample.working_set_mb
	}

	if (sample.flags & ow.OW_FLAG_SPIKE_WARN) != 0 && sample.frame_number > 5 {
		s.total_spikes += 1
		if (sample.flags & ow.OW_FLAG_SPIKE_SEVERE) != 0 {
			s.severe_spikes += 1
		}
		_record_top_spike(s, sample)
	}

	// Sparkline circular buffer
	s.sparkline_ms[s.sparkline_head]    = sample.dt_ms
	s.sparkline_flags[s.sparkline_head] = sample.flags
	s.sparkline_head = (s.sparkline_head + 1) % SPARKLINE_CAP
	if s.sparkline_count < SPARKLINE_CAP do s.sparkline_count += 1

	if len(s.dt_samples) < 36_000 {
		append(&s.dt_samples, sample.dt_ms)
	}

	if s.csv_file != nil {
		line := fmt.tprintf(
			"%d,%.2f,%.3f,%.1f,%.3f,%.3f,%.3f,%.3f,%.1f,%d,%d,%s,%d\n",
			sample.frame_number,
			sample.elapsed_ms,
			sample.dt_ms,
			sample.fps,
			sample.sim_ms,
			sample.ui_ms,
			sample.render_ms,
			sample.present_ms,
			sample.working_set_mb,
			sample.transform_count,
			sample.raycast_count,
			ow.phase_name(sample.culprit_phase),
			sample.flags,
		)
		_, _ = os.write_string(s.csv_file, line)
	}
}

@(private = "file")
_record_top_spike :: proc(s: ^Recorder_Session, sample: ow.Overwatch_Frame_Sample) {
	if len(s.top_spikes) < TOP_SPIKES_CAP {
		append(&s.top_spikes, sample)
	} else {
		min_i := 0
		for i in 1 ..< len(s.top_spikes) {
			if s.top_spikes[i].dt_ms < s.top_spikes[min_i].dt_ms do min_i = i
		}
		if sample.dt_ms > s.top_spikes[min_i].dt_ms {
			s.top_spikes[min_i] = sample
		}
	}
}

@(private = "file")
_try_attach_crash_log :: proc(s: ^Recorder_Session) {
	candidates := [2]string{
		fmt.tprintf("%s/moonhug/logs/crash_%d.log", s.repo_root, s.engine_pid),
		fmt.tprintf("%s/logs/crash_%d.log", s.repo_root, s.engine_pid),
	}
	for p in candidates {
		if raw, err := os.read_entire_file(p, context.temp_allocator); err == nil && len(raw) > 0 {
			delete(s.crash_log_excerpt)
			s.crash_log_excerpt = strings.clone(string(raw))
			return
		}
	}
}

@(private = "file")
_write_markdown_report :: proc(s: ^Recorder_Session) {
	b := strings.builder_make(0, 8192, context.temp_allocator)

	status_str := "RECORDING LIVE"
	switch s.health {
	case .Connecting: status_str = "CONNECTING"
	case .Recording:  status_str = "RECORDING LIVE"
	case .Frozen:     status_str = fmt.tprintf("WARNING — ENGINE HANG / FREEZE DETECTED (%.0f ms without heartbeat)", s.hang_duration_ms)
	case .Crashed:    status_str = fmt.tprintf("CRITICAL — ENGINE CRASHED (Exit Code: 0x%X / %d)", s.engine_exit_code, s.engine_exit_code)
	case .Stopped:    status_str = "COMPLETED CLEANLY (Hooks Retracted)"
	}

	fmt.sbprintfln(&b, "# MoonHug Overwatch Flight Recording & Performance Autopsy")
	fmt.sbprintln(&b)
	fmt.sbprintfln(&b, "- **Session Status:** %s", status_str)
	fmt.sbprintfln(&b, "- **Engine PID:** `%d` | **Recorder PID:** `%d`", s.engine_pid, os.get_pid())
	fmt.sbprintfln(&b, "- **Last In-Flight Engine Phase:** `%s` (`%s`)", ow.phase_name(s.last_phase), s.last_context)
	fmt.sbprintfln(&b, "- **Active Scene:** `%s` | **Selected Object:** `%s` | **Pawn/GAS State:** `%s`",
		s.last_scene != "" ? s.last_scene : "(none)",
		s.last_selected != "" ? s.last_selected : "(none)",
		s.last_pawn_state != "" ? s.last_pawn_state : "Idle",
	)
	fmt.sbprintfln(&b, "- **CSV Raw Stream:** `%s`", s.csv_path)
	fmt.sbprintln(&b)

	// Percentile calculation
	avg_ms := s.total_frames > 0 ? (s.sum_dt_ms / f64(s.total_frames)) : 0.0
	p50, p95, p99: f32 = 0, 0, 0
	if len(s.dt_samples) > 0 {
		sorted := slice.clone(s.dt_samples[:], context.temp_allocator)
		slice.sort(sorted)
		p50 = sorted[(len(sorted) - 1) * 50 / 100]
		p95 = sorted[(len(sorted) - 1) * 95 / 100]
		p99 = sorted[(len(sorted) - 1) * 99 / 100]
	}

	fmt.sbprintln(&b, "## 1. Frame Time & Memory Summary")
	fmt.sbprintln(&b)
	fmt.sbprintln(&b, "| Metric | Value |")
	fmt.sbprintln(&b, "| :--- | :--- |")
	fmt.sbprintfln(&b, "| Total Frames Recorded | `%d` |", s.total_frames)
	fmt.sbprintfln(&b, "| Average Frame Time | `%.2f ms` (`%.1f FPS`) |", avg_ms, avg_ms > 0.01 ? (1000.0 / avg_ms) : 0.0)
	fmt.sbprintfln(&b, "| Percentiles (`p50` / `p95` / `p99`) | `%.2f ms` / `%.2f ms` / `%.2f ms` |", p50, p95, p99)
	fmt.sbprintfln(&b, "| Worst Frame Spike (`max`) | `%.2f ms` |", s.max_dt_ms)
	fmt.sbprintfln(&b, "| Spikes (`>= %.1f ms` / `>= 33.3 ms`) | `%d` warn / `%d` severe |", s.alert_thresh_ms, s.total_spikes, s.severe_spikes)
	fmt.sbprintfln(&b, "| Process Working Set RAM | `%.1f MB` → `%.1f MB` |", s.min_mem_mb, s.max_mem_mb)
	fmt.sbprintln(&b)

	// Top Spikes Table
	fmt.sbprintln(&b, "## 2. Worst Performance Spikes (Subsystem Breakdown)")
	fmt.sbprintln(&b)
	if len(s.top_spikes) == 0 {
		fmt.sbprintln(&b, "_No frame spikes above threshold recorded in this session._")
	} else {
		spikes_sorted := slice.clone(s.top_spikes[:], context.temp_allocator)
		slice.sort_by(spikes_sorted, proc(a, b: ow.Overwatch_Frame_Sample) -> bool { return a.dt_ms > b.dt_ms })
		fmt.sbprintln(&b, "| Frame | Time (s) | Total `dt` | Sim/Phys | Editor UI | 3D/2D Render | Present | RAM (MB) | Dominant Culprit |")
		fmt.sbprintln(&b, "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |")
		for sp in spikes_sorted {
			fmt.sbprintfln(&b, "| `#%d` | `%.2fs` | **`%.2f ms`** | `%.2f ms` | `%.2f ms` | `%.2f ms` | `%.2f ms` | `%.1f` | `%s` |",
				sp.frame_number,
				sp.elapsed_ms / 1000.0,
				sp.dt_ms,
				sp.sim_ms,
				sp.ui_ms,
				sp.render_ms,
				sp.present_ms,
				sp.working_set_mb,
				ow.phase_name(sp.culprit_phase),
			)
		}
	}
	fmt.sbprintln(&b)

	// Chronological "What You Did + Spikes" Timeline
	fmt.sbprintln(&b, "## 3. Chronological \"What You Did\" & Spike Timeline")
	fmt.sbprintln(&b)
	if len(s.events_log) == 0 {
		fmt.sbprintln(&b, "_No user actions or spike events recorded yet._")
	} else {
		fmt.sbprintln(&b, "| Time (s) | Frame | Kind | Category | Detail |")
		fmt.sbprintln(&b, "| ---: | ---: | :--- | :--- | :--- |")
		for &ev in s.events_log {
			cat := ow.read_fixed_str(ev.category[:])
			det := ow.read_fixed_str(ev.detail[:])
			fmt.sbprintfln(&b, "| `%.2fs` | `#%d` | `%s` | %s | %s |",
				ev.elapsed_ms / 1000.0,
				ev.frame_number,
				ow.event_kind_name(ev.kind),
				cat,
				det,
			)
		}
	}
	fmt.sbprintln(&b)

	if s.crash_log_excerpt != "" {
		fmt.sbprintln(&b, "## 4. Attached Engine Crash Journal (`crash_<pid>.log`)")
		fmt.sbprintln(&b)
		fmt.sbprintln(&b, "```text")
		fmt.sbprintln(&b, s.crash_log_excerpt)
		fmt.sbprintln(&b, "```")
	}

	report_bytes := transmute([]u8)strings.to_string(b)
	_ = os.write_entire_file(s.md_latest_path, report_bytes)
	_ = os.write_entire_file(s.md_session_path, report_bytes)
}

session_finalize :: proc(s: ^Recorder_Session) {
	if s.finalized do return
	s.finalized = true
	session_poll_and_drain(s)
	if s.health == .Recording || s.health == .Connecting {
		s.health = .Stopped
	}
	_write_markdown_report(s)
	if s.csv_file != nil {
		os.close(s.csv_file)
		s.csv_file = nil
	}
	ow.shm_close(&s.mapping)
}
