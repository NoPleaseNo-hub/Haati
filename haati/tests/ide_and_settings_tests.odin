package tests

import "core:encoding/json"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import stbtt "vendor:stb/truetype"

import editor "../editor"
import "../editor/menu"
import "../engine"
import cs "haati:editor/code_studio"
import fe "haati:editor/file_explorer"
import "haati:editor/icons"
import mcp "haati:editor/mcp"
import widgets "haati:editor/widgets"
import wnd "haati:editor/window"

@(test)
test_utf8_safe_prefix_preserves_multibyte_runes :: proc(t: ^testing.T) {
	sample := "📁✓—Hello 世界"
	testing.expect_value(t, widgets.utf8_safe_prefix(sample, -5), "")
	testing.expect_value(t, widgets.utf8_safe_prefix(sample, 0), "")
	for limit in 0 ..= len(sample) + 2 {
		pref := widgets.utf8_safe_prefix(sample, limit)
		testing.expect(t, len(pref) <= limit, "prefix must not exceed byte budget")
		testing.expect(t, utf8.valid_string(pref), "truncated prefix must remain valid UTF-8")
		testing.expect(t, strings.has_prefix(sample, pref), "prefix must be a true leading slice")
	}
}

@(test)
test_problem_check_delay_clamping_and_roundtrip :: proc(t: ^testing.T) {
	orig := cs.get_problem_check_delay_sec()
	defer cs.set_problem_check_delay_sec(orig)

	testing.expect(t, orig >= 0.15 && orig <= 5.0, "default delay should be within valid bounds")

	cs.set_problem_check_delay_sec(0.01)
	testing.expect(t, math.abs(cs.get_problem_check_delay_sec() - 0.15) < 0.002, "delay below min should clamp to 0.15s")

	cs.set_problem_check_delay_sec(99.0)
	testing.expect(t, math.abs(cs.get_problem_check_delay_sec() - 5.0) < 0.002, "delay above max should clamp to 5.0s")

	cs.set_problem_check_delay_sec(1.25)
	testing.expect(t, math.abs(cs.get_problem_check_delay_sec() - 1.25) < 0.002, "valid delay should round-trip accurately")
}

@(test)
test_script_jump_routing_and_two_root_source_resolution :: proc(t: ^testing.T) {
	k1, _ := fe.classify_script_jump_target("assets/scripts/hero.bodin", context.temp_allocator)
	testing.expect_value(t, k1, fe.Script_Jump_Target.Blueprint_Graph)

	k2, _ := fe.classify_script_jump_target("assets/scripts/hero.mhgraph", context.temp_allocator)
	testing.expect_value(t, k2, fe.Script_Jump_Target.Blueprint_Graph)

	k3, _ := fe.classify_script_jump_target("assets/hot_scripts/hero_mhgraph_generated.odin", context.temp_allocator)
	testing.expect_value(t, k3, fe.Script_Jump_Target.Blueprint_Graph)

	k4, _ := fe.classify_script_jump_target("haati/engine/project_settings.odin", context.temp_allocator)
	testing.expect_value(t, k4, fe.Script_Jump_Target.Odin_Code)

	res_haati, ok_haati := fe.resolve_source_file_path("haati/engine/project_settings.odin", context.temp_allocator)
	testing.expect(t, ok_haati && os.exists(res_haati), "should resolve haati engine source path")

	res_alias, ok_alias := fe.resolve_source_file_path("moonhug/engine/project_settings.odin", context.temp_allocator)
	testing.expect(t, ok_alias && os.exists(res_alias), "should resolve legacy moonhug/ source alias")
}

@(test)
test_unified_3_tier_settings_cascade :: proc(t: ^testing.T) {
	tmp_root := "haati/tests/_tmp_unified_settings_cascade"
	_ = os.remove_all(tmp_root)
	defer _ = os.remove_all(tmp_root)
	defer engine.project_settings_shutdown()

	eng_dir := strings.concatenate({tmp_root, "/engine_settings"}, context.temp_allocator)
	proj_a  := strings.concatenate({tmp_root, "/proj_a"}, context.temp_allocator)
	proj_b  := strings.concatenate({tmp_root, "/proj_b"}, context.temp_allocator)

	Cascade_Probe :: struct {
		speed:   f32,
		count:   int,
		enabled: bool,
	}
	tab_name :: "Cascade Test Tab"

	engine.project_settings_set_tiered_mode(true)
	engine.project_settings_set_dirs_for_test(eng_dir, proj_a)

	// Fresh load registers Tier 1 Factory Defaults Backdrop.
	va := Cascade_Probe{speed = 10.0, count = 3, enabled = true}
	testing.expect(t, !engine.project_settings_load(tab_name, &va), "missing files should preserve defaults")

	// Saving non-overridden field writes Tier 2 Engine Settings shared across projects.
	va.speed = 25.0
	testing.expect(t, engine.project_settings_save(tab_name, &va, typeid_of(Cascade_Probe)))
	testing.expect(t, !engine.project_settings_has_field_override(tab_name, "speed"))

	// Enabling [P] override on `count` stores only `count` in Project A's overrides.
	va.count = 99
	testing.expect(t, engine.project_settings_set_field_override(tab_name, "count", true, &va, typeid_of(Cascade_Probe)))
	testing.expect(t, engine.project_settings_has_field_override(tab_name, "count"))
	testing.expect_value(t, engine.project_settings_tab_override_count(tab_name), 1)

	cur_json, jerr := json.marshal(va, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, jerr == nil)
	testing.expect(t, engine.project_settings_is_field_modified_from_default(tab_name, "speed", cur_json))
	testing.expect(t, !engine.project_settings_is_field_modified_from_default(tab_name, "enabled", cur_json))

	// Switching to Project B inherits Engine Settings (`speed = 25.0`) without Project A's override (`count = 3`).
	engine.project_settings_shutdown()
	engine.project_settings_set_tiered_mode(true)
	engine.project_settings_set_dirs_for_test(eng_dir, proj_b)

	vb := Cascade_Probe{speed = 10.0, count = 3, enabled = true}
	testing.expect(t, engine.project_settings_load(tab_name, &vb), "Project B should load shared Engine Settings")
	testing.expect_value(t, vb.speed, f32(25.0))
	testing.expect_value(t, vb.count, 3)

	// Switching back to Project A restores both Engine Setting and Project Override.
	engine.project_settings_shutdown()
	engine.project_settings_set_tiered_mode(true)
	engine.project_settings_set_dirs_for_test(eng_dir, proj_a)

	va2 := Cascade_Probe{speed = 10.0, count = 3, enabled = true}
	testing.expect(t, engine.project_settings_load(tab_name, &va2), "Project A should restore Tier 2 + Tier 3")
	testing.expect_value(t, va2.speed, f32(25.0))
	testing.expect_value(t, va2.count, 99)

	// Disabling [P] override reverts `count` to Tier 2 Engine Default (3).
	testing.expect(t, engine.project_settings_set_field_override(tab_name, "count", false, &va2, typeid_of(Cascade_Probe)))
	testing.expect(t, !engine.project_settings_has_field_override(tab_name, "count"))
	testing.expect_value(t, va2.count, 3)

	// Resetting `speed` to default restores Tier 1 Factory Backdrop (10.0).
	testing.expect(t, engine.project_settings_reset_field_to_default(tab_name, "speed", &va2, typeid_of(Cascade_Probe)))
	testing.expect_value(t, va2.speed, f32(10.0))
}

// Verifies Settings label humanizer + MCP discovery constant conventions.
@(test)
test_settings_humanizer_and_mcp_discovery :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	testing.expect_value(t, editor.humanize_setting_label("problem_check_delay_sec"), "Problem Check Delay (s)")
	testing.expect_value(t, editor.humanize_setting_label("ui_scale"), "UI Scale")
	testing.expect_value(t, editor.humanize_setting_label("target_fps_hz"), "Target FPS (Hz)")
	testing.expect_value(t, editor.humanize_setting_label("ide_sandbox_mode"), "IDE Sandbox Mode")
	testing.expect_value(t, editor.humanize_setting_label("enable_csg_vfs_mcp"), "Enable CSG VFS MCP")
	testing.expect_value(t, mcp.BRIDGE_FILE_USER_SETTINGS, "UserSettings/mcp_bridge.json")
}

// Verifies embedded Phosphor & Material icon TTF font bytes and that sampled icon glyph
// constants decode to single PUA runes and map to real glyph indices inside the TTF font.
@(test)
test_phosphor_and_material_icon_glyphs_valid_pua :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ph_font: stbtt.fontinfo
	init_ok := bool(stbtt.InitFont(&ph_font, raw_data(editor.PHOSPHOR_FONT_DATA), 0))
	testing.expect(t, init_ok, "Phosphor.ttf must parse cleanly via stb_truetype")
	if !init_ok do return

	ph_samples := [?]string{
		icons.ICON_PH_VECTOR_THREE,
		icons.ICON_PH_BLUEPRINT,
		icons.ICON_PH_UNITE,
		icons.ICON_PH_SUBTRACT,
		icons.ICON_PH_INTERSECT,
		icons.ICON_PH_BONE,
		icons.ICON_PH_SWORD,
		icons.ICON_PH_CUBE,
	}
	for g in ph_samples {
		r, n := utf8.decode_rune_in_string(g)
		testing.expect(t, n == len(g) && r >= icons.ICON_PH_MIN && r <= icons.ICON_PH_MAX, "Phosphor constant must be a single PUA rune")
		glyph_idx := stbtt.FindGlyphIndex(&ph_font, r)
		testing.expectf(t, glyph_idx != 0, "Phosphor.ttf missing glyph index for codepoint U+%04X", u32(r))
	}

	md_samples := [?]string{
		icons.ICON_MD_LIGHTBULB,
		icons.ICON_MD_WB_SUNNY,
		icons.ICON_MD_SKELETON,
		icons.ICON_MD_PSYCHOLOGY,
		icons.ICON_MD_SMART_TOY,
		icons.ICON_MD_MEMORY,
		icons.ICON_MD_BUG_REPORT,
		icons.ICON_MD_ROCKET_LAUNCH,
	}
	for g in md_samples {
		r, n := utf8.decode_rune_in_string(g)
		testing.expect(t, n == len(g) && r >= icons.ICON_MD_MIN && r <= icons.ICON_MD_MAX, "Material icon constant must be a single PUA rune")
	}
}

// Verifies portable bundled Odin toolchain resolution picks `tools/odin/odin.exe` next to the
// compiler executable first before falling back to `ODIN_ROOT` or `PATH`.
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

// Verifies `wnd.show_confirm_dialog` routes cleanly into `widgets.dialog_open` (`is_danger`
// and `is_cancel` button semantics).
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

// Verifies Studio/Browser windows (`file_explorer`, `material_editor`,
// `odin_micro_studio`, `mh_visual_script`) opt out of whole-window DPI Ctrl+MouseWheel
// scaling so their toolbars, buttons, and sidebars stay crisp.
@(test)
test_window_independent_pane_zoom_exemptions :: proc(t: ^testing.T) {
	testing.expect(t, wnd.uses_independent_pane_zoom("odin_micro_studio"), "odin_micro_studio must use independent pane zoom")
	testing.expect(t, wnd.uses_independent_pane_zoom("mh_visual_script"), "mh_visual_script must use independent pane zoom")
	testing.expect(t, wnd.uses_independent_pane_zoom("file_explorer"), "file_explorer must use independent pane zoom")
	testing.expect(t, wnd.uses_independent_pane_zoom("material_editor"), "material_editor must use independent pane zoom")
	testing.expect(t, !wnd.uses_independent_pane_zoom("inspector"), "standard inspector window should allow whole-window scale")
	testing.expect(t, !wnd.uses_independent_pane_zoom("hierarchy"), "standard hierarchy window should allow whole-window scale")
}

// Verifies File Explorer's expanded `48px..256px` tile zoom range, list density scale,
// and UTF-8-safe middle-ellipsis filename fitting for compact cards.
@(test)
test_file_explorer_zoom_range_and_middle_ellipsis :: proc(t: ^testing.T) {
	testing.expect_value(t, fe.CARD_SIZE_MIN, f32(48.0))
	testing.expect_value(t, fe.CARD_SIZE_MAX, f32(256.0))

	// Zero / unset legacy values fall back cleanly to defaults
	testing.expect_value(t, fe.clamp_card_size(0), fe.CARD_SIZE_DEFAULT)
	testing.expect_value(t, fe.clamp_list_scale(0), fe.LIST_SCALE_DEFAULT)

	// Bounds clamping and stepping across full range
	testing.expect_value(t, fe.clamp_card_size(12.0), f32(48.0))
	testing.expect_value(t, fe.clamp_card_size(512.0), f32(256.0))
	testing.expect_value(t, fe.step_card_size(104.0, 1.0), f32(116.0))
	testing.expect_value(t, fe.step_card_size(104.0, -1.0), f32(92.0))
	testing.expect_value(t, fe.step_card_size(52.0, -5.0), f32(48.0))
	testing.expect_value(t, fe.step_card_size(60.0, -5.0), f32(48.0))
	testing.expect_value(t, fe.step_card_size(248.0, 5.0), f32(256.0))

	testing.expect_value(t, fe.clamp_list_scale(0.10), fe.LIST_SCALE_MIN)
	testing.expect_value(t, fe.clamp_list_scale(3.00), fe.LIST_SCALE_MAX)
	testing.expect_value(t, fe.step_list_scale(1.00, 1.0), f32(1.10))
	testing.expect_value(t, fe.step_list_scale(1.00, -1.0), f32(0.90))
	testing.expect_value(t, fe.step_list_scale(0.85, -10.0), fe.LIST_SCALE_MIN)

	// Middle-ellipsis preserves extensions on normal files and handles directories / ultra-short cards
	long_fbx := fe.format_middle_ellipsis("FERRA_Rigged_NonConstraint.fbx", ".fbx", false, 14, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(long_fbx, "...fbx"), "extension and ellipsis should stay visible at 14 chars, got: %s", long_fbx)
	testing.expect(t, utf8.rune_count_in_string(long_fbx) <= 14, "truncated name must respect max_runes")

	dir_trunc := fe.format_middle_ellipsis("Character_Textures_HighRes", "", true, 8, context.temp_allocator)
	testing.expect_value(t, dir_trunc, "Charac..")

	tiny := fe.format_middle_ellipsis("player_controller.odin", ".odin", false, 4, context.temp_allocator)
	testing.expect_value(t, tiny, "pl..")

	// Multi-byte UTF-8 safety across arbitrary rune limits
	utf8_name := "Ferra_Übersicht_Mesh.glb"
	for lim in 1 ..= 20 {
		out := fe.format_middle_ellipsis(utf8_name, ".glb", false, lim, context.temp_allocator)
		testing.expectf(t, utf8.valid_string(out), "middle-ellipsis output must be valid UTF-8 at max_runes=%d: %s", lim, out)
		testing.expectf(t, utf8.rune_count_in_string(out) <= lim, "output rune count exceeded limit %d", lim)
	}
}

// Verifies File Explorer Left Tree zoom (`[0.75..2.00]`) is clamped & stepped independently
// from Folder Content List density zoom (`[0.75..2.00]`) and defaults legacy 0 values to 1.00.
@(test)
test_ux_independent_tree_vs_folder_zoom :: proc(t: ^testing.T) {
	testing.expect_value(t, fe.clamp_tree_scale(0), fe.TREE_SCALE_DEFAULT)
	testing.expect_value(t, fe.clamp_tree_scale(0.1), fe.TREE_SCALE_MIN)
	testing.expect_value(t, fe.clamp_tree_scale(5.0), fe.TREE_SCALE_MAX)
	testing.expect_value(t, fe.step_tree_scale(1.0, 2.0), f32(1.20))
	testing.expect_value(t, fe.step_tree_scale(1.95, 1.0), fe.TREE_SCALE_MAX)
	testing.expect_value(t, fe.step_tree_scale(0.85, -2.0), fe.TREE_SCALE_MIN)

	testing.expect_value(t, fe.clamp_list_scale(0), fe.LIST_SCALE_DEFAULT)
	testing.expect_value(t, fe.clamp_list_scale(3.0), fe.LIST_SCALE_MAX)
	testing.expect_value(t, fe.step_list_scale(1.60, 4.0), fe.LIST_SCALE_MAX)
}

// Verifies Window/Tools menu rename & Asset menu streamlining generated cleanly.
@(test)
test_ux_menu_searchable_window_tools_and_explorer_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	menu.init_menu()
	defer menu.shutdown_menu()
	menu.add_menu_item("Window/General/File Explorer", "Ctrl+5", proc() {})
	menu.add_menu_item("Tools/Refresh AssetDB", "", proc() {})
	paths := menu.collect_invokable_paths(context.temp_allocator)
	has_fe   := false
	has_ref  := false
	for p in paths {
		if p == "Window/General/File Explorer" do has_fe = true
		if p == "Tools/Refresh AssetDB" do has_ref = true
	}
	testing.expect(t, has_fe && has_ref, "menu tree must support searchable Window/General/File Explorer and Tools/Refresh AssetDB")

	repo := engine.resolve_repo_root(context.temp_allocator)
	gen_path, _ := filepath.join({repo, "haati/editor/menu_items_generated.odin"}, context.temp_allocator)
	gen_bytes, gerr := os.read_entire_file(gen_path, context.temp_allocator)
	testing.expect(t, gerr == nil, "menu_items_generated.odin must exist")
	gen_src := string(gen_bytes)
	testing.expect(t, strings.contains(gen_src, "\"Window/General/File Explorer\""), "generated menu items must expose File Explorer")
	testing.expect(t, strings.contains(gen_src, "\"Tools/Refresh AssetDB\""), "generated menu items must expose Tools/Refresh AssetDB")
	testing.expect(t, !strings.contains(gen_src, "\"Assets/Refresh AssetDB\""), "Assets/Refresh AssetDB must no longer live under top Assets menu")
}
