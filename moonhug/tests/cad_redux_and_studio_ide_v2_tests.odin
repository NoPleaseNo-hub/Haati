package tests

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../engine"
import cs "moonhug:editor/code_studio"
import hot "moonhug:engine/hot_api"
import cad_ed "moonhug:packages/cad_csg/editor"

// 1. Regression guard: before Point 1 is clicked (`has_anchor == false`), polar angle snap
//    MUST NEVER snap cursor coordinates toward world origin `{0, 0}`!
@(test)
test_cad_polar_snap_never_snaps_to_origin_without_anchor :: proc(t: ^testing.T) {
	// Near 45° from `{0,0}`: `{12.0, 11.75}` would have collapsed onto `{12, 12}` under the old `{0,0}` fallback!
	r1 := cad_ed.compute_cad_polar_snap({
		raw_uv         = {12.0, 11.75},
		anchor_uv      = {0, 0},
		has_anchor     = false,
		snap_step      = 0.25,
		polar_enabled  = true,
		polar_step_deg = 15.0,
	})
	testing.expect(t, !r1.polar_snapped, "expected polar_snapped == false when has_anchor == false")
	testing.expect(t, abs(r1.uv.x - 12.0) < 1e-4 && abs(r1.uv.y - 11.75) < 1e-4, "expected pure metric grid snap at {12.0, 11.75} without snapping toward {0,0}")

	// Near World V-axis (`x = 0.24, y = 8.50`): must snap to `{0.25, 8.50}` on the 0.25m grid, NOT collapse `x -> 0.0`!
	r2 := cad_ed.compute_cad_polar_snap({
		raw_uv         = {0.24, 8.50},
		anchor_uv      = {0, 0},
		has_anchor     = false,
		snap_step      = 0.25,
		polar_enabled  = true,
		polar_step_deg = 15.0,
	})
	testing.expect(t, !r2.polar_snapped, "expected polar_snapped == false before Point 1 is clicked")
	testing.expect(t, abs(r2.uv.x - 0.25) < 1e-4 && abs(r2.uv.y - 8.50) < 1e-4, "expected x=0.24 to grid-snap to 0.25m, NOT snap onto world X=0 ray")
}

// 2. True Anchor-Origin Polar Projection (`15°/30°/45°/90°` + `⊥ 90°` inference) & Box Footprint Aspect Lock
@(test)
test_cad_polar_snap_true_anchor_rays_and_box_aspect :: proc(t: ^testing.T) {
	anchor := [2]f32{7.30, -4.10}

	// A) 30-degree ray from arbitrary off-origin anchor `{7.30, -4.10}` at ~4.0m length (slightly off-angle at 32.5°)
	rad32 := f32(32.5 * (math.PI / 180.0))
	raw_32 := anchor + [2]f32{math.cos(rad32), math.sin(rad32)} * 4.02
	res_30 := cad_ed.compute_cad_polar_snap({
		raw_uv         = raw_32,
		anchor_uv      = anchor,
		has_anchor     = true,
		snap_step      = 0.25,
		polar_enabled  = true,
		polar_step_deg = 15.0,
	})
	testing.expect(t, res_30.polar_snapped, "expected 32.5° cursor from anchor to snap onto 30° polar ray")
	testing.expect(t, abs(res_30.snapped_deg - 30.0) < 1e-3, "expected snapped_deg == 30.0")
	testing.expect(t, abs(res_30.radial_len - 4.0) < 1e-3, "expected Euclidean radial length quantized to 4.00m")
	rel := res_30.uv - anchor
	expected_rel := [2]f32{math.cos(f32(30.0 * math.PI / 180.0)) * 4.0, math.sin(f32(30.0 * math.PI / 180.0)) * 4.0}
	testing.expect(t, linalg.length(rel - expected_rel) < 1e-3, "expected snapped point to lie strictly on anchor + 30° * 4.0m ray")

	// B) Previous-segment perpendicular (`⊥ 90°`) inference on a non-cardinal wall (`prev_dir = {0.8, 0.6}` ~ 36.87°)
	prev_dir := linalg.normalize([2]f32{0.8, 0.6})
	perp_dir := [2]f32{-prev_dir.y, prev_dir.x} // +90° CCW (~126.87°)
	// Place cursor 2° away from exact perpendicular so `15°` world rays (120°, 135°) do not match closer than `⊥`!
	perp_ang := math.atan2(perp_dir.y, perp_dir.x) + f32(2.0 * math.PI / 180.0)
	raw_perp := anchor + [2]f32{math.cos(perp_ang), math.sin(perp_ang)} * 3.0
	res_perp := cad_ed.compute_cad_polar_snap({
		raw_uv         = raw_perp,
		anchor_uv      = anchor,
		has_anchor     = true,
		has_prev_dir   = true,
		prev_dir_uv    = prev_dir,
		snap_step      = 0.25,
		polar_enabled  = true,
		polar_step_deg = 45.0,
	})
	testing.expect(t, res_perp.polar_snapped && res_perp.is_perp_prev, "expected 90° perpendicular inference to previous non-cardinal wall segment")
	dot_check := linalg.dot(linalg.normalize(res_perp.uv - anchor), prev_dir)
	testing.expect(t, abs(dot_check) < 1e-3, "expected perpendicular-snapped segment to have 0 dot product with previous segment")

	// C) 2-Corner Box Footprint MUST NEVER collapse width/depth to zero on `0°/90°` rays; `Shift` locks `1:1` Square!
	box_free := cad_ed.compute_cad_polar_snap({
		raw_uv           = anchor + {3.0, 0.25}, // Very shallow angle (~4.76°) that would collapse `dv -> 0` if polar-snapped!
		anchor_uv        = anchor,
		has_anchor       = true,
		snap_step        = 0.25,
		polar_enabled    = true,
		polar_step_deg   = 15.0,
		is_box_footprint = true,
		shift_held       = false,
	})
	testing.expect(t, abs((box_free.uv.y - anchor.y) - 0.25) < 1e-4, "expected Box_Primitive footprint NOT to collapse narrow 0.25m depth onto 0° ray")

	box_sq := cad_ed.compute_cad_polar_snap({
		raw_uv           = anchor + {3.0, -1.75},
		anchor_uv        = anchor,
		has_anchor       = true,
		snap_step        = 0.25,
		polar_enabled    = true,
		polar_step_deg   = 15.0,
		is_box_footprint = true,
		shift_held       = true,
	})
	testing.expect(t, abs((box_sq.uv.x - anchor.x) - 3.0) < 1e-4 && abs((box_sq.uv.y - anchor.y) - (-3.0)) < 1e-4, "expected Shift during Box footprint drag to lock 1:1 Square aspect")

	// D) `Alt` momentary bypass returns exact unsnapped `raw_uv`
	raw_exact := [2]f32{5.137, -2.891}
	res_alt := cad_ed.compute_cad_polar_snap({
		raw_uv         = raw_exact,
		anchor_uv      = anchor,
		has_anchor     = true,
		snap_step      = 0.50,
		polar_enabled  = true,
		polar_step_deg = 15.0,
		alt_held       = true,
	})
	testing.expect(t, !res_alt.polar_snapped && linalg.length(res_alt.uv - raw_exact) < 1e-6, "expected Alt modifier to bypass both polar and grid snap")
}

// 3. Odin Micro-Studio IDE V2: Smart Autocomplete (Pins, `hot.*`, Vector Swizzles, AST Struct Fields) & Zoom
@(test)
test_studio_ide_v2_smart_autocomplete_and_zoom :: proc(t: ^testing.T) {
	// A) Code zoom clamping (`65%` .. `240%`)
	prev_zoom := cs.studio_code_zoom()
	defer cs.set_studio_code_zoom(prev_zoom)

	cs.set_studio_code_zoom(0.20)
	testing.expect(t, abs(cs.studio_code_zoom() - cs.CODE_ZOOM_MIN) < 1e-4, "expected zoom below 65% to clamp to CODE_ZOOM_MIN")
	cs.set_studio_code_zoom(5.00)
	testing.expect(t, abs(cs.studio_code_zoom() - cs.CODE_ZOOM_MAX) < 1e-4, "expected zoom above 240% to clamp to CODE_ZOOM_MAX")
	cs.set_studio_code_zoom(1.35)
	testing.expect(t, abs(cs.studio_code_zoom() - 1.35) < 1e-4, "expected valid zoom 135% to persist")

	// B) Scoped Pin Badges (`◆ ^Ref` + deref `^` & `● Copy`) ranked at top of free-identifier completion
	pins := [2]cs.Scoped_Pin_Badge{
		{name = "pos_ref",    odin_type = "[3]f32", pass_mode = hot.Hot_Pass_Mode.By_Reference, is_output = false},
		{name = "move_speed", odin_type = "f32",    pass_mode = hot.Hot_Pass_Mode.Copy_Value,   is_output = false},
	}
	src_pin := "speed_scale := 2.0\npos"
	items_pin, rep_pin := cs.query_autocomplete_suggestions(src_pin, len(src_pin), pins[:], false, true, context.temp_allocator)
	testing.expect_value(t, rep_pin, len("speed_scale := 2.0\n"))
	testing.expect(t, len(items_pin) >= 2, "expected `pos` prefix to match `pos_ref` and `pos_ref^`")
	if len(items_pin) > 0 {
		testing.expect_value(t, items_pin[0].label, "pos_ref")
		testing.expect_value(t, items_pin[0].kind, cs.Completion_Kind.Pin_Ref)
	}

	// C) Vector swizzle dot-completion (`pos_ref.` -> `x`, `y`, `z`, `xyz`)
	src_vec := "pos_ref."
	items_vec, _ := cs.query_autocomplete_suggestions(src_vec, len(src_vec), pins[:], false, true, context.temp_allocator)
	found_xyz := false
	for it in items_vec {
		if it.label == "xyz" && it.kind == .Field do found_xyz = true
	}
	testing.expect(t, found_xyz, "expected `pos_ref.` on `[3]f32` pin to suggest `.xyz` vector field")

	// D) `hot.` & `api.` dot-member completion -> suggests `hot.damp_vec3` and `api.log_info`
	src_hot := "hot.damp"
	items_hot, rep_hot := cs.query_autocomplete_suggestions(src_hot, len(src_hot), pins[:], false, true, context.temp_allocator)
	testing.expect_value(t, rep_hot, len("hot."))
	found_hot_damp := false
	for it in items_hot {
		if it.label == "damp_vec3" do found_hot_damp = true
	}
	testing.expect(t, found_hot_damp, "expected `hot.damp` to suggest `damp_vec3` from hot cartridge API")

	src_api := "api.log"
	items_api, rep_api := cs.query_autocomplete_suggestions(src_api, len(src_api), pins[:], false, true, context.temp_allocator)
	testing.expect_value(t, rep_api, len("api."))
	found_api_log := false
	for it in items_api {
		if it.label == "log_info" do found_api_log = true
	}
	testing.expect(t, found_api_log, "expected `api.log` to suggest `log_info` from Engine_Hot_API vtable")

	// E) Full-file AST struct field dot-completion (`cfg: Motor_Config` -> `cfg.` suggests `max_accel`)
	full_odin := `package sample_pkg

Motor_Config :: struct {
	max_accel: f32,
	damping:   f32,
}

step_motor :: proc() {
	cfg: Motor_Config
	cfg.max
}
`
	caret := strings.index(full_odin, "cfg.max") + len("cfg.max")
	items_struct, _ := cs.query_autocomplete_suggestions(full_odin, caret, nil, false, false, context.temp_allocator)
	found_field := false
	for it in items_struct {
		if it.label == "max_accel" && it.kind == .Field do found_field = true
	}
	testing.expect(t, found_field, "expected AST struct indexer to resolve `cfg: Motor_Config` and suggest `.max_accel`")
}

// 4. Silent Win32 `CREATE_NO_WINDOW` Background Subprocess Runner (`bg_process_start_to_file`)
@(test)
test_silent_bg_process_runner_zero_flash :: proc(t: ^testing.T) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	log_path, _ := filepath.join({repo_root, "builds", fmt.tprintf("mh_bg_proc_test_%d.log", os.get_pid())}, context.temp_allocator)
	defer _ = os.remove(log_path)

	bg, started := engine.bg_process_start_to_file(repo_root, {"odin", "version"}, nil, log_path)
	testing.expect(t, started, "expected silent bg_process_start_to_file(`odin version`) to start cleanly")
	if !started do return

	exited, code := engine.bg_process_wait(&bg)
	testing.expect(t, exited && code == 0, "expected `odin version` background process to exit with code 0")

	data, rerr := os.read_entire_file(log_path, context.temp_allocator)
	testing.expect(t, rerr == nil && strings.contains(string(data), "odin version"), "expected redirected log file to contain `odin version` output")
}

// 5. Strict Core ABI Locks + Tooltip & `#c_varargs` ImGui CString Safety across all edited files
@(test)
test_cad_redux_and_ide_v2_abi_and_ui_contracts :: proc(t: ^testing.T) {
	// Core Hot-API ABI Lock (`void_odin` component ABI locks live in `plugins/void_odin/tests/`)
	testing.expect_value(t, size_of(hot.Hot_Delegate), 16)

	repo_root := engine.resolve_repo_root(context.temp_allocator)

	// Verify embedded Windows PE Icon assets (`moonhug.ico` + `moonhug.rc`) exist and have valid multi-DPI ICO header
	ico_abs, _ := filepath.join({repo_root, "moonhug/editor/moonhug.ico"}, context.temp_allocator)
	rc_abs, _  := filepath.join({repo_root, "moonhug/editor/moonhug.rc"}, context.temp_allocator)
	ico_bytes, ico_err := os.read_entire_file(ico_abs, context.temp_allocator)
	testing.expect(t, ico_err == nil && len(ico_bytes) > 1024, "expected moonhug/editor/moonhug.ico to exist and contain multi-DPI PNG frames")
	if ico_err == nil && len(ico_bytes) >= 6 {
		// ICONDIR header: Reserved=0, Type=1 (ICON), Count >= 4
		testing.expect(t, ico_bytes[0] == 0 && ico_bytes[1] == 0 && ico_bytes[2] == 1 && ico_bytes[3] == 0 && ico_bytes[4] >= 4, "expected valid Win32 ICONDIR header in moonhug.ico")
	}
	testing.expect(t, os.exists(rc_abs), "expected moonhug/editor/moonhug.rc resource script to exist")

	checked_files := [7]string{
		"moonhug/editor/code_studio/code_studio.odin",
		"moonhug/editor/code_studio/code_autocomplete.odin",
		"moonhug/editor/relaunch.odin",
		"moonhug/editor/overwatch_controller.odin",
		"moonhug/editor/view_scene_2d.odin",
		"plugins/cad_csg/editor/cad_csg_editor.odin",
		"plugins/cad_csg/editor/cad_mesh_editor.odin",
	}

	for rel in checked_files {
		abs_p, _ := filepath.join({repo_root, rel}, context.temp_allocator)
		raw, err := os.read_entire_file(abs_p, context.temp_allocator)
		testing.expectf(t, err == nil, "expected %s to be readable", rel)
		if err != nil do continue

		lines := strings.split_lines(string(raw), context.temp_allocator)
		for line, li in lines {
			trimmed := strings.trim_space(line)
			if strings.has_prefix(trimmed, "//") do continue

			// Tooltip Contract: NEVER call raw `im.SetTooltip` or `im.SetItemTooltip`
			has_raw_tip := strings.contains(trimmed, "im.SetTooltip(") || strings.contains(trimmed, "im.SetItemTooltip(")
			testing.expectf(t, !has_raw_tip, "%s:%d violates tooltip contract (must use widgets.tooltip): %s", rel, li + 1, trimmed)

			// `odin-imgui` `DrawList_AddRect` parameter order guard: `(dl, p_min, p_max, col, rounding, thickness, flags)`
			// Passing `{}, <float>` swaps `thickness` and `flags` and triggers `imgui_draw.cpp:1519` assertion!
			if strings.contains(trimmed, "DrawList_AddRect(") {
				swapped := strings.contains(trimmed, ", {}, ")
				testing.expectf(t, !swapped, "%s:%d swaps thickness and flags in DrawList_AddRect: %s", rel, li + 1, trimmed)
			}

			// ImGui `#c_varargs` CString Contract on Studio/Editor files
			is_vararg_txt := strings.contains(trimmed, "im.Text(") ||
			                 strings.contains(trimmed, "im.TextColored(") ||
			                 strings.contains(trimmed, "im.TextDisabled(") ||
			                 strings.contains(trimmed, "im.TextWrapped(") ||
			                 strings.contains(trimmed, "im.BulletText(")
			if is_vararg_txt && strings.contains(trimmed, "%s") {
				safe := strings.contains(trimmed, "fmt.ctprintf(") ||
				        strings.contains(trimmed, "card_title") ||
				        strings.contains(trimmed, "cstring(")
				testing.expectf(t, safe, "%s:%d passes potentially non-cstring to #c_varargs ImGui text proc: %s", rel, li + 1, trimmed)
			}
		}
	}
}
