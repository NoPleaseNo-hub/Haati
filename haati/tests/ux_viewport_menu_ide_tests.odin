package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../engine"
import "../editor/menu"
import cs "haati:editor/code_studio"
import fe "haati:editor/file_explorer"
import vs "haati:editor/visual_script"

// 1. Verifies Folder Tree Ctrl+MouseWheel zoom range/step (`[0.80..2.00]`) is decoupled
//    from Folder Content List density zoom (`[0.75..2.00]`) and defaults legacy 0 values to 1.00.
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

// 2. Verifies cross-file diagnostic filtering prevents diagnostics from sibling Odin files
//    (e.g. CamPawn) from bleeding onto the active editor tab, while keeping Stage A in-RAM checks.
@(test)
test_ux_diagnostic_matches_active_file :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	active := "C:/moonhug-main/Void_Odin/Scenes/HumanoidPawn/component_HumanoidPawn.odin"
	testing.expect(t, cs.diagnostic_matches_active_file(active, active), "exact path must match")
	testing.expect(t, cs.diagnostic_matches_active_file("c:\\moonhug-main\\Void_Odin\\Scenes\\HumanoidPawn\\component_HumanoidPawn.odin", active), "case-insensitive backslash path must match")
	testing.expect(t, cs.diagnostic_matches_active_file("in_ram_buffer.odin", active), "Stage A in-RAM parser diagnostics must apply to active buffer")
	testing.expect(t, cs.diagnostic_matches_active_file("<ram>", active), "RAM synthetic path must apply")
	testing.expect(t, cs.diagnostic_matches_active_file("", active), "empty diag path must apply")
	testing.expect(t, cs.diagnostic_matches_active_file("Scenes/HumanoidPawn/component_HumanoidPawn.odin", active), "relative suffix boundary match must succeed")

	testing.expect(t, !cs.diagnostic_matches_active_file("moonhug:packages/void_odin/Scenes/CamPawn/component_CamPawn.odin", active), "other file diagnostic must NOT bleed into active tab")
	testing.expect(t, !cs.diagnostic_matches_active_file("haati/hot_scripts/other_HumanoidPawn.odin", active), "prefix-similar filename must NOT false-match suffix")
}

// 3. Verifies JetBrains-style deterministic Quick-Fix extraction (`build_line_quick_fixes`)
//    for unused imports, invalid import paths, `did you mean`, missing packages, and unused locals.
@(test)
test_ux_quick_fixes_jetbrains_suggestions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	src := strings.join({
		"package demo",
		"import campawn \"moonhug:packages/void_odin/Scenes/CamPawn\"",
		"import \"core:fmt\"",
		"update :: proc() {",
		"\tvel := math.sin(1.0)",
		"\tprnitln(\"hi\")",
		"}",
	}, "\n", context.temp_allocator)

	f_imp_bad := cs.build_line_quick_fixes(src, 2, "Syntax Error: Invalid path: moonhug:packages/void_odin/Scenes/CamPawn", false, context.temp_allocator)
	has_comment_bad := false
	has_open_popup  := false
	for a in f_imp_bad {
		if a.kind == .Comment_Line do has_comment_bad = true
		if a.kind == .Open_Imports_Popup do has_open_popup = true
	}
	testing.expect(t, has_comment_bad && has_open_popup, "broken import line must offer Comment + Import/Using popup quick-fixes")

	f_imp_unused := cs.build_line_quick_fixes(src, 3, "'fmt' imported and not used", true, context.temp_allocator)
	has_comment_unused := false
	has_remove_unused  := false
	for a in f_imp_unused {
		if a.kind == .Comment_Line do has_comment_unused = true
		if a.kind == .Remove_Line do has_remove_unused = true
	}
	testing.expect(t, has_comment_unused && has_remove_unused, "unused import must offer Comment + Remove line quick-fixes")

	f_var := cs.build_line_quick_fixes(src, 5, "'vel' declared and not used", false, context.temp_allocator)
	testing.expect(t, len(f_var) >= 1 && f_var[0].kind == .Suppress_Unused_Var && f_var[0].replacement == "vel", "unused local variable must offer `_ = vel` suppression")

	f_pkg := cs.build_line_quick_fixes(src, 5, "Undeclared name: math", false, context.temp_allocator)
	has_math_import := false
	for a in f_pkg {
		if a.kind == .Inject_Import && a.spec_id == "math" do has_math_import = true
	}
	testing.expect(t, has_math_import, "undeclared `math` must suggest injecting `core:math` import")

	f_dym := cs.build_line_quick_fixes(src, 6, "Undeclared name: prnitln, did you mean 'println'?", false, context.temp_allocator)
	has_dym := false
	for a in f_dym {
		if a.kind == .Replace_Ident && a.old_ident == "prnitln" && a.replacement == "println" do has_dym = true
	}
	testing.expect(t, has_dym, "compiler `did you mean` suggestion must produce Replace_Ident quick-fix")
}

// 4. Verifies exporting a hybrid `.bodin` Blueprint script strips `@BODIN_GRAPH_V1` metadata
//    and writes a clean standalone `.odin` file beside it.
@(test)
test_ux_bodin_export_to_standalone_odin_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	tmp_dir, terr := os.temp_dir(context.temp_allocator)
	testing.expect(t, terr == nil, "os.temp_dir must succeed")
	bodin_p, _ := filepath.join({tmp_dir, "ux_roundtrip_test_bp.bodin"}, context.temp_allocator)
	exp_odin_p, _ := filepath.join({tmp_dir, "ux_roundtrip_test_bp.odin"}, context.temp_allocator)
	_ = os.remove(bodin_p)
	_ = os.remove(exp_odin_p)
	defer {
		_ = os.remove(bodin_p)
		_ = os.remove(exp_odin_p)
	}

	bodin_body := strings.concatenate({
		"package hot_scripts\n\nmy_bp_proc :: proc() -> int {\n\treturn 42\n}\n\n",
		engine.BODIN_GRAPH_BEGIN,
		"\n// {\"name\": \"ux_roundtrip_test_bp\"}\n",
		engine.BODIN_GRAPH_END,
		"\n",
	}, context.temp_allocator)
	werr := os.write_entire_file(bodin_p, transmute([]u8)bodin_body)
	testing.expect(t, werr == nil, "setup write of temp .bodin must succeed")

	out_odin, ok := vs.export_bodin_to_standalone_odin(bodin_p, context.temp_allocator)
	testing.expect(t, ok, "export_bodin_to_standalone_odin must succeed on valid .bodin")
	testing.expect(t, os.exists(out_odin), "exported .odin file must exist on disk")

	raw_out, rerr := os.read_entire_file(out_odin, context.temp_allocator)
	testing.expect(t, rerr == nil, "reading exported .odin must succeed")
	out_str := string(raw_out)
	testing.expect(t, strings.contains(out_str, "my_bp_proc :: proc() -> int"), "exported .odin must retain Odin procedures")
	testing.expect(t, !strings.contains(out_str, engine.BODIN_GRAPH_BEGIN), "exported .odin must strip embedded @BODIN_GRAPH_V1 block")
}

// 5. Verifies Window/Tools menu rename & Asset menu streamlining generated cleanly.
@(test)
test_ux_menu_searchable_window_tools_and_explorer_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	menu.init_menu()
	defer menu.shutdown_menu()
	menu.add_menu_item("Window/General/Void File Explorer", "Ctrl+5", proc() {})
	menu.add_menu_item("Tools/Refresh AssetDB", "", proc() {})
	paths := menu.collect_invokable_paths(context.temp_allocator)
	has_fe   := false
	has_ref  := false
	for p in paths {
		if p == "Window/General/Void File Explorer" do has_fe = true
		if p == "Tools/Refresh AssetDB" do has_ref = true
	}
	testing.expect(t, has_fe && has_ref, "menu tree must support searchable Window/General/Void File Explorer and Tools/Refresh AssetDB")

	repo := engine.resolve_repo_root(context.temp_allocator)
	gen_path, _ := filepath.join({repo, "haati/editor/menu_items_generated.odin"}, context.temp_allocator)
	gen_bytes, gerr := os.read_entire_file(gen_path, context.temp_allocator)
	testing.expect(t, gerr == nil, "menu_items_generated.odin must exist")
	gen_src := string(gen_bytes)
	testing.expect(t, strings.contains(gen_src, "\"Window/General/Void File Explorer\""), "generated menu items must expose Void File Explorer")
	testing.expect(t, strings.contains(gen_src, "\"Tools/Refresh AssetDB\""), "generated menu items must expose Tools/Refresh AssetDB")
	testing.expect(t, !strings.contains(gen_src, "\"Assets/Refresh AssetDB\""), "Assets/Refresh AssetDB must no longer live under top Assets menu")
}
