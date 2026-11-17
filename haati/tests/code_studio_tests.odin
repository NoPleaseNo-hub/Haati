package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "../engine"
import cs "haati:editor/code_studio"

// 1. Verifies incomplete Odin `for` headers (`for i, ` / `for k, v {`) do not trigger
//    `core/odin/parser/parser.odin:938` `assert(as.op.kind == .In)`, preserve caller
//    `context.allocator`, and leak 0 heap allocations.
@(test)
test_parser_incomplete_for_header_no_assert_and_allocator_preserved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)
		orig_proc := context.allocator.procedure

		d1, _ := cs.check_odin_syntax_in_ram("package demo\nf :: proc() {\n\tfor i, \n}\n", false, context.allocator)
		testing.expect(t, context.allocator.procedure == orig_proc, "check_odin_syntax_in_ram must preserve caller context.allocator on incomplete `for i, `")
		testing.expect(t, len(d1) > 0 && !d1[0].is_warning, "expected syntax error diagnostic on incomplete `for i, `")
		for d in d1 {
			delete(d.file)
			delete(d.message)
		}
		delete(d1)

		d2, _ := cs.check_odin_syntax_in_ram("package demo\nf :: proc() {\n\tfor k, v {\n\t}\n}\n", false, context.allocator)
		testing.expect(t, context.allocator.procedure == orig_proc, "check_odin_syntax_in_ram must preserve caller context.allocator on incomplete `for k, v {`")
		testing.expect(t, len(d2) > 0, "expected diagnostic on incomplete `for k, v {` without `in`")
		for d in d2 {
			delete(d.file)
			delete(d.message)
		}
		delete(d2)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaked allocations after syntax parse, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees after syntax parse, got %d", len(track.bad_free_array))
}

// 2. Verifies Odin `-json-errors` fatal error severity elevation (even when tagged `"type": "warning"`
//    with `"error_count": 1`) and legacy `moonhug:` -> `haati:` / `project:` import migration.
@(test)
test_odin_json_error_severity_and_moonhug_migration :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fatal_warn_json := `{"error_count": 1, "errors": [{"type": "warning", "pos": {"file": "demo.odin", "line": 8, "column": 1, "end_column": 42}, "msgs": ["Syntax Error: Invalid path: moonhug:packages/demo_proj/Scenes/CamPawn"]}]}`
	fdiags := cs.parse_odin_json_errors(fatal_warn_json, context.temp_allocator)
	testing.expect_value(t, len(fdiags), 1)
	if len(fdiags) == 1 {
		testing.expect(t, !fdiags[0].is_warning, "fatal import syntax error with error_count=1 must elevate to hard error")
		testing.expect_value(t, fdiags[0].line, 8)
	}

	real_warn_json := `{"error_count": 0, "errors": [{"type": "warning", "pos": {"file": "demo.odin", "line": 3, "column": 1, "end_column": 10}, "msgs": ["Unused import"]}]}`
	wdiags := cs.parse_odin_json_errors(real_warn_json, context.temp_allocator)
	testing.expect_value(t, len(wdiags), 1)
	if len(wdiags) == 1 {
		testing.expect(t, wdiags[0].is_warning, "non-fatal warning with error_count=0 must stay is_warning=true")
	}

	m1, ok1 := cs.compute_haati_import_migration("moonhug:engine", "", context.temp_allocator)
	testing.expect(t, ok1 && m1 == "haati:engine", "moonhug:engine must migrate to haati:engine")
	m2, ok2 := cs.compute_haati_import_migration("moonhug:app/helpers", "", context.temp_allocator)
	testing.expect(t, ok2 && m2 == "haati:packages/app/helpers", "moonhug:app/* must migrate to haati:packages/app/*")
	m3, ok3 := cs.compute_haati_import_migration("moonhug:packages/control_rig", "my_game", context.temp_allocator)
	testing.expect(t, ok3 && m3 == "haati:packages/control_rig", "plugin package must migrate to haati:packages/*")
	m4, ok4 := cs.compute_haati_import_migration("moonhug:packages/my_game/Scenes/CamPawn", "my_game", context.temp_allocator)
	testing.expect(t, ok4 && m4 == "project:Scenes/CamPawn", "active project self-import must migrate to project:*")

	legacy_src := "package p\n// import \"moonhug:ignored_comment\"\nimport \"moonhug:engine\"\nimport cam \"moonhug:packages/my_game/Scenes/CamPawn\"\n"
	lints := cs.lint_legacy_moonhug_imports(legacy_src, "p.odin", "my_game", context.temp_allocator)
	testing.expect_value(t, len(lints), 2)
	migrated, cnt := cs.migrate_all_legacy_moonhug_imports(legacy_src, "my_game", context.temp_allocator)
	testing.expect_value(t, cnt, 2)
	testing.expect(t, strings.contains(migrated, "// import \"moonhug:ignored_comment\""), "commented import lines must remain untouched")
	testing.expect(t, strings.contains(migrated, "import \"haati:engine\""), "engine import must migrate to haati:engine")
	testing.expect(t, strings.contains(migrated, "import cam \"project:Scenes/CamPawn\""), "project import must migrate to project:Scenes/CamPawn")
}

// 3. Verifies indexing a large multi-file package (`haati/engine`, 90+ `.odin` files) does not
//    wrap or corrupt the 4 MB `context.temp_allocator` ring buffer, preserves caller allocator,
//    and frees with zero leaked heap allocations or invalid string bytes.
@(test)
test_autocomplete_large_engine_package_index_no_ring_wrap_or_leak :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	sym_count := 0
	all_valid_utf8 := true
	{
		context.allocator = mem.tracking_allocator(&track)
		orig_proc := context.allocator.procedure

		syms := cs.index_package_dir_symbols("haati/engine", context.allocator)
		testing.expect(t, context.allocator.procedure == orig_proc, "index_package_dir_symbols must preserve caller context.allocator")
		sym_count = len(syms)
		for s in syms {
			if s.name == "" || !utf8.valid_string(s.name) ||
			   !utf8.valid_string(s.insert_text) ||
			   !utf8.valid_string(s.detail) ||
			   !utf8.valid_string(s.receiver) {
				all_valid_utf8 = false
			}
			if s.name        != "" do delete(s.name)
			if s.insert_text != "" do delete(s.insert_text)
			if s.detail      != "" do delete(s.detail)
			if s.receiver    != "" do delete(s.receiver)
		}
		delete(syms)
	}

	testing.expectf(t, sym_count >= 100, "expected >= 100 indexed symbols across haati/engine, got %d", sym_count)
	testing.expect(t, all_valid_utf8, "every indexed symbol must hold intact valid UTF-8 strings with zero ring-buffer overwrite")
	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaked allocations after indexing haati/engine, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees after indexing haati/engine, got %d", len(track.bad_free_array))
}

// 4. Verifies `submit_async_check` and `set_checker_dirty_overlays` persist normalized paths
//    on the heap so wiping & overwriting `context.temp_allocator` cannot cause a worker UAF.
@(test)
test_async_checker_norm_path_heap_lifetime_no_uaf :: proc(t: ^testing.T) {
	defer cs.shutdown_checker()
	defer free_all(context.temp_allocator)

	cs.set_problem_check_delay_sec(0.05)
	defer cs.set_problem_check_delay_sec(0.9)

	for i in 0 ..< 5 {
		temp_ov := fmt.tprintf("C:/Haati_Temp_Test\\dir_%d\\overlay_script_%d.bodin", i, i)
		temp_sub := fmt.tprintf("C:/Haati_Temp_Test\\dir_%d\\active_script_%d.bodin", i, i)
		cs.set_checker_dirty_overlays([]cs.Dirty_File_Overlay{
			{abs_path = temp_ov, code = "package hot_scripts\n", is_bodin = true},
		})
		cs.submit_async_check("package hot_scripts\n// valid syntax\n", false, "", false, temp_sub)

		free_all(context.temp_allocator)
		poison := make([]u8, 16 * 1024, context.temp_allocator)
		mem.set(raw_data(poison), 0xAA, len(poison))

		time.sleep(5 * time.Millisecond)
		snap := cs.read_checker_snapshot(context.temp_allocator)
		testing.expect(t, utf8.valid_string(snap.summary_label), "checker snapshot summary must stay valid UTF-8")
	}
	cs.set_checker_dirty_overlays(nil)
}

// 5. Verifies read-only protection blacklist rejects engine/editor/plugin paths while allowing project & user scripts.
@(test)
test_protected_readonly_script_blacklist :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	testing.expect(t, cs.is_protected_readonly_script_path("haati/engine/world.odin"), "haati/engine must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("C:/repo/Haati_Engine/haati/editor/main.odin"), "haati/editor must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("haati/hot_scripts/builtin_hot_scripts.odin"), "builtin_hot_scripts.odin must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("plugins/void_custom/foo.odin"), "plugins/ scripts must be read-only")
	testing.expect(t, cs.is_protected_readonly_script_path("tools/haati/cli.odin"), "tools/ scripts must be read-only")

	testing.expect(t, !cs.is_protected_readonly_script_path("assets/scripts/player.bodin"), "user .bodin scripts must be editable")
	testing.expect(t, !cs.is_protected_readonly_script_path("C:/Projects/MyGame/player_cam.bodin"), "project .bodin scripts must be editable")
}

// 6. Verifies AST-backed `find_odin_proc_call_sites` ignores strings, line comments, block comments, and declarations.
@(test)
test_ast_proc_call_sites_ignores_comments_and_strings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	src := `package test_calls

bobRoss :: proc(a: int, s: string = "") {
	_ = a; _ = s
}

caller :: proc() {
	fake := "bobRoss(1)"
	// bobRoss(2)
	/* bobRoss(3) */
	bobRoss(4, "hi")
	pkg.bobRoss(5)
	_ = fake
}
`
	sites := cs.find_odin_proc_call_sites(src, "caller.odin", "bobRoss", context.temp_allocator)
	testing.expect_value(t, len(sites), 2)
	if len(sites) == 2 {
		testing.expect_value(t, sites[0].line, 11)
		testing.expect_value(t, sites[0].arg_count, 2)
		testing.expect_value(t, sites[1].line, 12)
		testing.expect_value(t, sites[1].arg_count, 1)
	}
}

// 7. Verifies cross-file diagnostic filtering prevents diagnostics from sibling Odin files
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

// 8. Verifies JetBrains-style deterministic Quick-Fix extraction (`build_line_quick_fixes`)
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

// 9. Verifies Odin tokenizer-backed unused import detection and one-click commenting
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

// 10. Verifies Symbol Outline extraction, `//` Doc-Comment extraction above `@(hot_proc)` and
//     standard Odin declarations, and Breadcrumb scope lookup.
@(test)
test_ide_outline_doc_comments_and_breadcrumbs :: proc(t: ^testing.T) {
	sample_src := `package gameplay

// =============================================================================
// SECTION BANNER (must NOT be merged into doc-comment)
// =============================================================================

// Applies damped vertical spring impulse when the character lands.
// Safe for per-object timescale dilation.
@(hot_proc)
apply_landing_spring :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32) {
	_ = api
	_ = self
	_ = dt
}

// State container for procedural foot IK.
Foot_IK_State :: struct {
	weight: f32,
	offset: [3]f32,
}

helper_without_doc :: proc(v: f32) -> f32 {
	return v * 2.0
}
`
	testing.expect_value(t, cs.extract_odin_package_name(sample_src), "gameplay")

	syms := cs.extract_odin_outline_symbols(sample_src, context.temp_allocator)
	testing.expect_value(t, len(syms), 3)
	if len(syms) == 3 {
		testing.expect_value(t, syms[0].name, "apply_landing_spring")
		testing.expect_value(t, syms[0].kind, cs.Outline_Symbol_Kind.Hot_Proc)
		testing.expect(t, strings.contains(syms[0].doc_comment, "Applies damped vertical spring impulse"), "expected first doc line on @(hot_proc)")
		testing.expect(t, strings.contains(syms[0].doc_comment, "Safe for per-object timescale dilation."), "expected second doc line on @(hot_proc)")
		testing.expect(t, !strings.contains(syms[0].doc_comment, "SECTION BANNER"), "section divider must not leak into doc-comment")

		testing.expect_value(t, syms[1].name, "Foot_IK_State")
		testing.expect_value(t, syms[1].kind, cs.Outline_Symbol_Kind.Struct)
		testing.expect_value(t, syms[1].doc_comment, "State container for procedural foot IK.")

		testing.expect_value(t, syms[2].name, "helper_without_doc")
		testing.expect_value(t, syms[2].kind, cs.Outline_Symbol_Kind.Proc)
		testing.expect_value(t, syms[2].doc_comment, "")

		doc := cs.extract_odin_proc_doc_comment(sample_src, "apply_landing_spring", context.temp_allocator)
		testing.expect(t, strings.contains(doc, "Applies damped vertical spring impulse"), "expected proc doc lookup to succeed")

		enc_name, enc_kind, enc_ok := cs.enclosing_odin_symbol_at_line(syms, syms[0].line + 2)
		testing.expect(t, enc_ok, "expected enclosing symbol inside apply_landing_spring body")
		testing.expect_value(t, enc_name, "apply_landing_spring")
		testing.expect_value(t, enc_kind, cs.Outline_Symbol_Kind.Hot_Proc)
	}
}

// 11. Verifies `Alt+Up` / `Alt+Down` line movement and independent 3-pane zoom isolation.
@(test)
test_ide_move_line_and_independent_pane_zooms :: proc(t: ^testing.T) {
	src := "alpha := 1\nbeta := 2\ngamma := 3"
	moved_up, cur_up, ok_up := cs.move_line_in_source(src, 15, -1, context.temp_allocator)
	testing.expect(t, ok_up, "expected Alt+Up on line 2 to succeed")
	testing.expect_value(t, moved_up, "beta := 2\nalpha := 1\ngamma := 3")
	testing.expect_value(t, cur_up, 4)

	moved_down, cur_down, ok_down := cs.move_line_in_source(moved_up, cur_up, 1, context.temp_allocator)
	testing.expect(t, ok_down, "expected Alt+Down back to line 2 to succeed")
	testing.expect_value(t, moved_down, src)
	testing.expect_value(t, cur_down, 15)

	_, _, ok_top := cs.move_line_in_source(src, 2, -1, context.temp_allocator)
	testing.expect(t, !ok_top, "expected Alt+Up on first line to be a no-op")

	cs.configure_ide_defaults(1.00, 1.00, 1.00, true, true, true)
	cs.set_studio_code_zoom(1.85)
	cs.set_studio_explorer_zoom(0.95)
	cs.set_studio_problems_zoom(1.15)
	testing.expect(t, abs(cs.studio_code_zoom() - 1.85) < 1e-4, "expected code_zoom == 1.85")
	testing.expect(t, abs(cs.studio_explorer_zoom() - 0.95) < 1e-4, "expected explorer_zoom == 0.95 (isolated from code_zoom)")
	testing.expect(t, abs(cs.studio_problems_zoom() - 1.15) < 1e-4, "expected problems_zoom == 1.15 (isolated from code_zoom)")
	cs.configure_ide_defaults(1.00, 1.00, 1.00, true, true, true)
}

// 12. Static UI Glyph Contract: ensures unbaked Unicode Dingbats / Geometric Shapes / Emoji never appear
//     in non-comment code lines of Studio IDE, Visual Script, Inspector, or CAD CSG editor.
@(test)
test_no_unbaked_unicode_glyphs_in_studio_and_cad_ui_code :: proc(t: ^testing.T) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	checked_files := [?]string{
		"haati/editor/visual_script/visual_script_editor.odin",
		"haati/editor/visual_script/vs_canvas.odin",
		"haati/editor/visual_script/vs_docks.odin",
		"haati/editor/code_studio/code_studio.odin",
		"haati/editor/code_studio/code_autocomplete.odin",
		"haati/editor/view_visual_script_inspector.odin",
		"plugins/cad_csg/editor/cad_csg_editor.odin",
		"haati/editor/file_explorer/editor/material_graph_editor.odin",
	}
	forbidden := [?]string{
		"\u25c7",
		"\u25b7",
		"\u25cf",
		"\u25c6",
		"\U0001f441",
		"\u2713",
		"\u2717",
		"\u26a1",
		"\u21bb",
		"\u2220",
	}

	for rel in checked_files {
		abs_p, _ := filepath.join({repo_root, rel}, context.temp_allocator)
		data, err := os.read_entire_file(abs_p, context.temp_allocator)
		testing.expectf(t, err == nil, "expected to read %s", rel)
		if err != nil do continue

		for raw_ln, li in strings.split_lines(string(data), context.temp_allocator) {
			trimmed := strings.trim_space(raw_ln)
			if strings.has_prefix(trimmed, "//") do continue
			code_part := trimmed
			if cidx := strings.index(code_part, "//"); cidx >= 0 {
				code_part = code_part[:cidx]
			}
			for glyph in forbidden {
				if strings.contains(code_part, glyph) {
					testing.expectf(t, false, "unbaked glyph %q found in UI code at %s:%d -> %s", glyph, rel, li + 1, code_part)
				}
			}
		}
	}
}
