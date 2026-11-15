package tests

import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import "../engine"
import cs "haati:editor/code_studio"
import file_exp "haati:editor/file_explorer"
import vs "haati:editor/visual_script"
import "haati:editor/widgets"
import wnd "haati:editor/window"

// 1. Verifies `resolve_odin_binary` resolves the standalone bundled `<repo>/tools/odin/`
//    compiler executable first before falling back to `ODIN_ROOT` or `PATH`.
@(test)
test_bundled_toolchain_resolution_prefers_tools_odin :: proc(t: ^testing.T) {
	odin_exe := engine.resolve_odin_binary(context.temp_allocator)
	testing.expect(t, len(odin_exe) > 0, "resolve_odin_binary must return a non-empty path")
	testing.expectf(t, os.exists(odin_exe), "resolved Odin binary must exist on disk: %s", odin_exe)

	norm, _ := strings.replace_all(odin_exe, "\\", "/", context.temp_allocator)
	expected_suffix := "tools/odin/odin.exe" when ODIN_OS == .Windows else "tools/odin/odin"
	testing.expectf(
		t,
		strings.has_suffix(norm, expected_suffix),
		"expected resolve_odin_binary to prefer bundled %s, got %s",
		expected_suffix,
		norm,
	)
}

// 2. Verifies Odin tokenizer-backed unused import detection and one-click commenting
//    for Odin Micro-Studio without disturbing used imports or already-commented imports.
@(test)
test_code_studio_unused_import_detection_and_comment_fix :: proc(t: ^testing.T) {
	src := `package gameplay

import "core:fmt"
import "core:math"
import input "haati:engine/input"
import "core:strings"

update_actor :: proc(x: f32, name: string) -> f32 {
	if strings.contains(name, "hero") {
		return math.sin(x)
	}
	return 0
}
`
	unused := cs.detect_unused_odin_imports(src, context.temp_allocator)
	testing.expect_value(t, len(unused), 2)
	if len(unused) == 2 {
		testing.expect_value(t, unused[0].alias, "fmt")
		testing.expect_value(t, unused[0].import_path, "core:fmt")
		testing.expect_value(t, unused[0].line, 3)

		testing.expect_value(t, unused[1].alias, "input")
		testing.expect_value(t, unused[1].import_path, "haati:engine/input")
		testing.expect_value(t, unused[1].line, 5)
	}

	updated, count := cs.comment_out_unused_odin_imports(src, context.temp_allocator)
	testing.expect_value(t, count, 2)
	testing.expect(t, strings.contains(updated, `// import "core:fmt"`), "expected unused core:fmt to be commented out")
	testing.expect(t, strings.contains(updated, `// import input "haati:engine/input"`), "expected unused input alias to be commented out")
	testing.expect(t, strings.contains(updated, "\nimport \"core:math\"\n"), "expected used core:math to stay active")
	testing.expect(t, strings.contains(updated, "\nimport \"core:strings\"\n"), "expected used core:strings to stay active")

	remaining := cs.detect_unused_odin_imports(updated, context.temp_allocator)
	testing.expect_value(t, len(remaining), 0)
}

// 3. Verifies Blueprint `.Delegate` pin drop target collection gathers local
//    `.Custom_Proc_Entry` events and `@(hot_proc)` targets and filters cleanly by query.
@(test)
test_blueprint_delegate_pin_collect_bind_targets :: proc(t: ^testing.T) {
	g: engine.Visual_Graph
	g.name = strings.clone("delegate_target_test_bp")
	defer engine.vg_destroy_graph(&g)

	append(&g.nodes, engine.VG_Node{
		uid             = 10,
		kind            = .Custom_Proc_Entry,
		title           = strings.clone("On Custom Jump"),
		hot_proc_target = strings.clone("On_Custom_Jump"),
	})
	append(&g.nodes, engine.VG_Node{
		uid             = 11,
		kind            = .Custom_Proc_Entry,
		title           = strings.clone("On Dash Start"),
		hot_proc_target = strings.clone("On_Dash_Start"),
	})

	extra := [?]string{"play_explosion_vfx", "apply_damage"}

	all_targets := vs.collect_delegate_pin_bind_targets(&g, "", extra[:], context.temp_allocator)
	has_jump := false
	has_dash := false
	has_vfx := false
	for tgt in all_targets {
		if tgt.kind == .Custom_Event && tgt.name == "On_Custom_Jump" && tgt.node_uid == 10 do has_jump = true
		if tgt.kind == .Custom_Event && tgt.name == "On_Dash_Start" && tgt.node_uid == 11 do has_dash = true
		if tgt.kind == .Hot_Proc && tgt.name == "play_explosion_vfx" do has_vfx = true
	}
	testing.expect(t, has_jump, "expected On_Custom_Jump custom event target")
	testing.expect(t, has_dash, "expected On_Dash_Start custom event target")
	testing.expect(t, has_vfx, "expected extra hot_proc target play_explosion_vfx")

	jump_only := vs.collect_delegate_pin_bind_targets(&g, "jump", extra[:], context.temp_allocator)
	testing.expect(t, len(jump_only) >= 1, "expected query 'jump' to match On_Custom_Jump")
	for tgt in jump_only {
		testing.expect(t, strings.contains(strings.to_lower(tgt.name, context.temp_allocator), "jump"), "filtered targets must match query")
	}

	vfx_only := vs.collect_delegate_pin_bind_targets(&g, "explosion", extra[:], context.temp_allocator)
	found_vfx := false
	for tgt in vfx_only {
		if tgt.kind == .Hot_Proc && tgt.name == "play_explosion_vfx" do found_vfx = true
	}
	testing.expect(t, found_vfx, "expected query 'explosion' to return play_explosion_vfx")
}

// 4. Verifies `wnd.show_confirm_dialog` / `close_confirm_dialog` delegates cleanly to the
//    unified `widgets.dialog_open` / `dialog_close` stack (preserving `is_danger`, `is_default`,
//    and `is_cancel` button semantics).
@(test)
test_window_confirm_dialog_delegates_to_widgets_dialog :: proc(t: ^testing.T) {
	defer wnd.close_confirm_dialog()

	wnd.show_confirm_dialog("Delete Node?", "Cannot undo.", "Delete", nil, true, "Keep", nil)
	d, ok := widgets.dialog_current()
	testing.expect(t, ok, "confirm dialog should be open via widgets.dialog_open")
	if ok {
		testing.expect_value(t, d.title, "Delete Node?")
		testing.expect_value(t, d.description, "Cannot undo.")
		testing.expect_value(t, len(d.buttons), 2)
		if len(d.buttons) == 2 {
			testing.expect_value(t, d.buttons[0].label, "Delete")
			testing.expect_value(t, d.buttons[0].is_danger, true)
			testing.expect_value(t, d.buttons[0].is_default, false)
			testing.expect_value(t, d.buttons[1].label, "Keep")
			testing.expect_value(t, d.buttons[1].is_cancel, true)
		}
	}

	wnd.close_confirm_dialog()
	_, closed_ok := widgets.dialog_current()
	testing.expect(t, !closed_ok, "close_confirm_dialog must close widgets dialog")

	wnd.show_confirm_dialog("Save Layout?", "Overwrite?", "Save", nil, false)
	d2, ok2 := widgets.dialog_current()
	testing.expect(t, ok2, "non-danger confirm dialog should be open")
	if ok2 && len(d2.buttons) == 2 {
		testing.expect_value(t, d2.buttons[0].is_danger, false)
		testing.expect_value(t, d2.buttons[0].is_default, true)
		testing.expect_value(t, d2.buttons[1].label, "Cancel")
		testing.expect_value(t, d2.buttons[1].is_cancel, true)
	}
}

// 5. Verifies Studio/Browser windows (`void_file_explorer`, `void_material_editor`,
//    `odin_micro_studio`, `mh_visual_script`) opt out of whole-window DPI Ctrl+MouseWheel
//    scaling so their toolbars, buttons, and sidebars stay crisp.
@(test)
test_window_independent_pane_zoom_exemptions :: proc(t: ^testing.T) {
	testing.expect(t, wnd.uses_independent_pane_zoom("odin_micro_studio"), "odin_micro_studio must use independent pane zoom")
	testing.expect(t, wnd.uses_independent_pane_zoom("mh_visual_script"), "mh_visual_script must use independent pane zoom")
	testing.expect(t, wnd.uses_independent_pane_zoom("void_file_explorer"), "void_file_explorer must use independent pane zoom")
	testing.expect(t, wnd.uses_independent_pane_zoom("void_material_editor"), "void_material_editor must use independent pane zoom")
	testing.expect(t, !wnd.uses_independent_pane_zoom("inspector"), "standard inspector window should allow whole-window scale")
}

// 6. Verifies Void File Explorer's expanded `48px..256px` tile zoom range, list density scale,
//    and UTF-8-safe middle-ellipsis filename fitting for compact cards.
@(test)
test_void_file_explorer_zoom_range_and_middle_ellipsis :: proc(t: ^testing.T) {
	testing.expect_value(t, file_exp.CARD_SIZE_MIN, f32(48.0))
	testing.expect_value(t, file_exp.CARD_SIZE_MAX, f32(256.0))

	// Zero / unset legacy values fall back cleanly to defaults
	testing.expect_value(t, file_exp.clamp_card_size(0), file_exp.CARD_SIZE_DEFAULT)
	testing.expect_value(t, file_exp.clamp_list_scale(0), file_exp.LIST_SCALE_DEFAULT)

	// Bounds clamping and stepping across full range
	testing.expect_value(t, file_exp.clamp_card_size(12.0), f32(48.0))
	testing.expect_value(t, file_exp.clamp_card_size(512.0), f32(256.0))
	testing.expect_value(t, file_exp.step_card_size(104.0, 1.0), f32(116.0))
	testing.expect_value(t, file_exp.step_card_size(104.0, -1.0), f32(92.0))
	testing.expect_value(t, file_exp.step_card_size(52.0, -5.0), f32(48.0))
	testing.expect_value(t, file_exp.step_card_size(60.0, -5.0), f32(48.0))
	testing.expect_value(t, file_exp.step_card_size(248.0, 5.0), f32(256.0))

	testing.expect_value(t, file_exp.clamp_list_scale(0.10), file_exp.LIST_SCALE_MIN)
	testing.expect_value(t, file_exp.clamp_list_scale(3.00), file_exp.LIST_SCALE_MAX)
	testing.expect_value(t, file_exp.step_list_scale(1.00, 1.0), f32(1.10))
	testing.expect_value(t, file_exp.step_list_scale(1.00, -1.0), f32(0.90))
	testing.expect_value(t, file_exp.step_list_scale(0.85, -10.0), file_exp.LIST_SCALE_MIN)

	// Middle-ellipsis preserves extensions on normal files and handles directories / ultra-short cards
	long_fbx := file_exp.format_middle_ellipsis("FERRA_Rigged_NonConstraint.fbx", ".fbx", false, 14, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(long_fbx, "...fbx"), "extension and ellipsis should stay visible at 14 chars, got: %s", long_fbx)
	testing.expect(t, utf8.rune_count_in_string(long_fbx) <= 14, "truncated name must respect max_runes")

	dir_trunc := file_exp.format_middle_ellipsis("Character_Textures_HighRes", "", true, 8, context.temp_allocator)
	testing.expect_value(t, dir_trunc, "Charac..")

	tiny := file_exp.format_middle_ellipsis("player_controller.odin", ".odin", false, 4, context.temp_allocator)
	testing.expect_value(t, tiny, "pl..")

	// Multi-byte UTF-8 safety across arbitrary rune limits
	utf8_name := "Ferra_Übersicht_Mesh.glb"
	for lim in 1 ..= 20 {
		out := file_exp.format_middle_ellipsis(utf8_name, ".glb", false, lim, context.temp_allocator)
		testing.expectf(t, utf8.valid_string(out), "middle-ellipsis output must be valid UTF-8 at max_runes=%d: %s", lim, out)
		testing.expectf(t, utf8.rune_count_in_string(out) <= lim, "output rune count exceeded limit %d", lim)
	}
}
