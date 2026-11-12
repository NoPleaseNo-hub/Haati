package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../engine"
import wnd "moonhug:editor/window"

@(private = "file")
_dummy_window_draw :: proc() {}

@(private = "file")
_captured_win_events: int

@(private = "file")
_test_win_hook :: proc(action: string, id: string) {
	if action != "" && id != "" {
		_captured_win_events += 1
	}
}

@(test)
test_overwatch_extend_retract_and_out_of_process_recorder :: proc(t: ^testing.T) {
	// 1. Default state MUST be RETRACTED (0 ns single-branch fast-path)
	testing.expect(t, !engine.overwatch_hooks_extended(), "expected Overwatch hooks to start RETRACTED")
	engine.overwatch_frame_begin()
	engine.overwatch_phase_begin(.Sim_Tick, "RetractedNoop")
	engine.overwatch_phase_end(.Sim_Tick)
	engine.overwatch_record_event(.User_Action, "Test", "Should be ignored while retracted")
	engine.overwatch_frame_end(0.016, false)
	testing.expect_value(t, engine.overwatch_spike_count(), u32(0))

	// 2. EXTEND hooks and spawn the real out-of-process `builds/MoonHug_Overwatch.exe --headless` binary!
	pid := os.get_pid()
	shm_name := fmt.tprintf("Local\\MoonHug_Overwatch_UnitTest_%d", pid)
	rel_out  := fmt.tprintf("logs/overwatch_unit_test_%d", pid)
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	out_abs, _ := filepath.join({repo_root, "moonhug", rel_out}, context.temp_allocator)
	defer {
		// Clean up temporary test output folder & files
		if dir_f, derr := os.open(out_abs); derr == nil {
			if entries, rerr := os.read_dir(dir_f, -1, context.temp_allocator); rerr == nil {
				for e in entries {
					fp, _ := filepath.join({out_abs, e.name}, context.temp_allocator)
					_ = os.remove(fp)
				}
			}
			os.close(dir_f)
		}
		_ = os.remove(out_abs)
	}

	mapped_shm, ext_ok := engine.overwatch_extend_hooks(shm_name, rel_out, 16.6667)
	testing.expect(t, ext_ok && mapped_shm == shm_name, "expected overwatch_extend_hooks to map OS Shared Memory")
	testing.expect(t, engine.overwatch_hooks_extended(), "expected overwatch_hooks_extended() == true after extending")
	defer if engine.overwatch_hooks_extended() do engine.overwatch_retract_hooks("Defer safety cleanup")

	exe_ext :: ".exe" when ODIN_OS == .Windows else ""
	ow_bin, _ := filepath.join({repo_root, "builds", "MoonHug_Overwatch" + exe_ext}, context.temp_allocator)
	testing.expectf(t, os.exists(ow_bin), "expected %s to exist before running out-of-process test", ow_bin)
	if !os.exists(ow_bin) do return

	child, perr := os.process_start(os.Process_Desc{
		working_dir = repo_root,
		command     = {
			ow_bin,
			fmt.tprintf("--shm=%s", shm_name),
			fmt.tprintf("--pid=%d", pid),
			fmt.tprintf("--repo=%s", repo_root),
			"--headless",
			"--max-ms=5000",
		},
	})
	testing.expectf(t, perr == nil, "expected MoonHug_Overwatch child process to spawn cleanly: %v", perr)
	if perr != nil do return

	// Wait up to 1.5s for external process to attach and publish its PID in SHM header
	wait_start := time.tick_now()
	for engine.overwatch_recorder_pid() == 0 && time.duration_milliseconds(time.tick_since(wait_start)) < 1500.0 {
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, engine.overwatch_recorder_pid() != 0, "expected external MoonHug_Overwatch process to attach via Shared Memory")

	// 3. Emit "What You Did" user actions, context snapshot, smooth frames, and 1 severe Sim_Tick spike!
	engine.overwatch_set_context_snapshot("assets/scenes/arena.scene", "HeroPawn")
	engine.overwatch_push_gameplay_sample(8, "Running | GAS:Dash")
	engine.overwatch_record_event(.Window_Tab, "Window", "Open Window: odin_micro_studio")
	engine.overwatch_record_event(.Selection, "Selection", "Selected entity 'HeroPawn'")
	engine.overwatch_record_event(.Undo_Redo, "Undo", "Undo: Move Transform")

	// 8 smooth frames (~4 ms each) so frame_number > 5 before the spike
	for _ in 0 ..< 8 {
		engine.overwatch_frame_begin()
		engine.overwatch_phase_begin(.Sim_Tick, "NormalSim")
		time.sleep(2 * time.Millisecond)
		engine.overwatch_phase_end(.Sim_Tick)
		engine.overwatch_phase_begin(.Scene_3D_View, "Scene3D")
		time.sleep(2 * time.Millisecond)
		engine.overwatch_phase_end(.Scene_3D_View)
		engine.overwatch_frame_end(0.004, true)
	}

	// Frame #9: deliberate ~42 ms severe spike inside `.Sim_Tick`!
	engine.overwatch_frame_begin()
	engine.overwatch_phase_begin(.Sim_Tick, "HeavyPhysicsStep")
	time.sleep(42 * time.Millisecond)
	engine.overwatch_phase_end(.Sim_Tick)
	engine.overwatch_frame_end(0.042, true)

	testing.expect(t, engine.overwatch_spike_count() >= 1, "expected severe 42ms frame to increment overwatch_spike_count")

	// Allow external process ~50 ms to drain SPSC ring buffers before retracting
	time.sleep(50 * time.Millisecond)

	// 4. RETRACT hooks -> signals external process to finalize report and exit!
	engine.overwatch_retract_hooks("Unit test clean stop")
	testing.expect(t, !engine.overwatch_hooks_extended(), "expected hooks to be RETRACTED immediately after overwatch_retract_hooks")

	st, werr := os.process_wait(child)
	testing.expectf(t, werr == nil && st.exit_code == 0, "expected MoonHug_Overwatch child process to exit 0 (got err=%v, code=%d)", werr, st.exit_code)

	// 5. Verify generated `overwatch_latest.md` flight autopsy report!
	md_path, _ := filepath.join({out_abs, "overwatch_latest.md"}, context.temp_allocator)
	md_bytes, rerr := os.read_entire_file(md_path, context.temp_allocator)
	testing.expectf(t, rerr == nil && len(md_bytes) > 0, "expected overwatch_latest.md to be written at %s", md_path)
	if rerr == nil {
		md := string(md_bytes)
		testing.expect(t, strings.contains(md, "COMPLETED CLEANLY (Hooks Retracted)"), "expected report to record clean hook retraction")
		testing.expect(t, strings.contains(md, "HeroPawn"), "expected report to include selected entity snapshot & event")
		testing.expect(t, strings.contains(md, "odin_micro_studio"), "expected report to include window open action")
		testing.expect(t, strings.contains(md, "Undo: Move Transform"), "expected report to include undo action")
		testing.expect(t, strings.contains(md, "Sim_Tick"), "expected report to attribute the 42ms spike to Sim_Tick")
	}
}

@(test)
test_closed_tab_reopen_lifo :: proc(t: ^testing.T) {
	defer wnd.shutdown()
	defer { wnd.on_window_event_hook = nil }

	_captured_win_events = 0
	wnd.on_window_event_hook = _test_win_hook

	wnd.register("unit_tab_alpha", "Alpha Tab", "", _dummy_window_draw, 300, 200)
	wnd.register("unit_tab_beta",  "Beta Tab",  "", _dummy_window_draw, 300, 200)

	wnd.open("unit_tab_alpha")
	wnd.open("unit_tab_beta")
	testing.expect(t, wnd.is_open("unit_tab_alpha"), "expected Alpha Tab to be open")
	testing.expect(t, wnd.is_open("unit_tab_beta"), "expected Beta Tab to be open")

	// Close Alpha first, then Beta -> Ctrl+Shift+T (`reopen_last_closed`) must reopen Beta first, then Alpha!
	wnd.close("unit_tab_alpha")
	wnd.close("unit_tab_beta")
	testing.expect(t, !wnd.is_open("unit_tab_alpha"), "expected Alpha Tab to be closed")
	testing.expect(t, !wnd.is_open("unit_tab_beta"), "expected Beta Tab to be closed")

	r1, ok1 := wnd.reopen_last_closed()
	testing.expect(t, ok1 && r1 == "unit_tab_beta", "expected first Ctrl+Shift+T to reopen most recently closed tab (unit_tab_beta)")
	testing.expect(t, wnd.is_open("unit_tab_beta"), "expected unit_tab_beta to be open again")

	r2, ok2 := wnd.reopen_last_closed()
	testing.expect(t, ok2 && r2 == "unit_tab_alpha", "expected second Ctrl+Shift+T to reopen unit_tab_alpha")
	testing.expect(t, wnd.is_open("unit_tab_alpha"), "expected unit_tab_alpha to be open again")

	testing.expect(t, _captured_win_events >= 6, "expected extended on_window_event_hook to receive open/close events")

	// Retract hook -> 0 events captured afterwards
	wnd.on_window_event_hook = nil
	prev_cnt := _captured_win_events
	wnd.close("unit_tab_alpha")
	testing.expect_value(t, _captured_win_events, prev_cnt)
}

@(test)
test_prefab_nested_scenes_prune_on_destroy :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	sc := engine.sm_scene_get_active()
	testing.expect(t, sc != nil, "expected active scene")
	if sc == nil do return

	branch_a := engine.transform_new("Branch_A")
	child_a  := engine.transform_new("PrefabHost_A")
	engine.transform_set_parent(child_a, branch_a)
	branch_b := engine.transform_new("Branch_B")

	lid_a := engine.scene_new_lid(sc)
	lid_b := engine.scene_new_lid(sc)

	append(&sc.nested_scenes, engine.NestedScene{
		local_id      = lid_a,
		expand_parent = child_a,
	})
	append(&sc.nested_scenes, engine.NestedScene{
		local_id      = lid_b,
		expand_parent = branch_b,
	})
	testing.expect_value(t, len(sc.nested_scenes), 2)

	// Deleting `branch_a` via `transform_destroy_with_records` must prune `lid_a` while keeping `lid_b`!
	engine.transform_destroy_with_records(branch_a)
	testing.expect_value(t, len(sc.nested_scenes), 1)
	if len(sc.nested_scenes) == 1 {
		testing.expect_value(t, sc.nested_scenes[0].local_id, lid_b)
	}
}
