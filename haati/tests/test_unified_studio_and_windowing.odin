package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../engine"
import cs "haati:editor/code_studio"
import vs "haati:editor/visual_script"

// 1. Verifies JetBrains / VS Symbol Outline extraction, `//` Doc-Comment extraction above
//    `@(hot_proc)` and standard Odin declarations (reused as stationary idle-hover tooltips in
//    BOTH Odin Micro-Studio and Unified Graph Studio), and Breadcrumb scope lookup!
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

		// Verify `extract_odin_proc_doc_comment` & Breadcrumb `enclosing_odin_symbol_at_line`
		doc := cs.extract_odin_proc_doc_comment(sample_src, "apply_landing_spring", context.temp_allocator)
		testing.expect(t, strings.contains(doc, "Applies damped vertical spring impulse"), "expected proc doc lookup to succeed")

		enc_name, enc_kind, enc_ok := cs.enclosing_odin_symbol_at_line(syms, syms[0].line + 2)
		testing.expect(t, enc_ok, "expected enclosing symbol inside apply_landing_spring body")
		testing.expect_value(t, enc_name, "apply_landing_spring")
		testing.expect_value(t, enc_kind, cs.Outline_Symbol_Kind.Hot_Proc)
	}
}

// 2. Verifies `Alt+Up` / `Alt+Down` line movement (`move_line_in_source`) and independent
//    3-pane `Ctrl + MouseWheel` zoom isolation (`explorer_zoom`, `code_zoom`, `problems_zoom`)!
@(test)
test_ide_move_line_and_independent_pane_zooms :: proc(t: ^testing.T) {
	src := "alpha := 1\nbeta := 2\ngamma := 3"
	// Caret on `"beta := 2"` at column 4 (index 11 + 4 = 15)
	moved_up, cur_up, ok_up := cs.move_line_in_source(src, 15, -1, context.temp_allocator)
	testing.expect(t, ok_up, "expected Alt+Up on line 2 to succeed")
	testing.expect_value(t, moved_up, "beta := 2\nalpha := 1\ngamma := 3")
	testing.expect_value(t, cur_up, 4)

	moved_down, cur_down, ok_down := cs.move_line_in_source(moved_up, cur_up, 1, context.temp_allocator)
	testing.expect(t, ok_down, "expected Alt+Down back to line 2 to succeed")
	testing.expect_value(t, moved_down, src)
	testing.expect_value(t, cur_down, 15)

	// Boundary guard: Alt+Up on line 0 is a clean no-op
	_, _, ok_top := cs.move_line_in_source(src, 2, -1, context.temp_allocator)
	testing.expect(t, !ok_top, "expected Alt+Up on first line to be a no-op")

	// Independent 3-segment zoom isolation: zooming code text MUST NOT scale Explorer or Problems!
	cs.configure_ide_defaults(1.00, 1.00, 1.00, true, true, true)
	cs.set_studio_code_zoom(1.85)
	cs.set_studio_explorer_zoom(0.95)
	cs.set_studio_problems_zoom(1.15)
	testing.expect(t, abs(cs.studio_code_zoom() - 1.85) < 1e-4, "expected code_zoom == 1.85")
	testing.expect(t, abs(cs.studio_explorer_zoom() - 0.95) < 1e-4, "expected explorer_zoom == 0.95 (isolated from code_zoom)")
	testing.expect(t, abs(cs.studio_problems_zoom() - 1.15) < 1e-4, "expected problems_zoom == 1.15 (isolated from code_zoom)")
	// Restore clean 1.0x defaults
	cs.configure_ide_defaults(1.00, 1.00, 1.00, true, true, true)
}

// 3. Verifies Unified Graph Studio domains (`Anim_Motion`, `Particle_VFX`), Tier-1 live evaluation,
//    Tier-2 Data-Oriented `.bodin` Odin transpilation of Motion & GPU VFX nodes, AND legacy Unicode
//    pin-name sanitization (`◇` / `▷` stripped cleanly on load so `? ? Delegate` never appears)!
@(test)
test_unified_graph_studio_domains_transpiler_and_pin_sanitization :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	g: engine.Visual_Graph
	g.name           = strings.clone("unit_unified_motion_vfx")
	g.domain         = .Anim_Motion
	g.package_target = strings.clone("haati/hot_scripts")
	engine.vg_ensure_default_spaces(&g)
	defer engine.vg_destroy_graph(&g)

	append(&g.variables, engine.VG_Var_Decl{
		name        = strings.clone("blended_pose"),
		pin_type    = .Float,
		default_f32 = 0.0,
	})

	u_tick   := engine.vg_add_node(&g, .Event_Tick,          {0, 0})
	u_clip   := engine.vg_add_node(&g, .Anim_Clip_Eval,      {220, 0})
	u_blend  := engine.vg_add_node(&g, .Anim_Blend_Layered,  {440, 0})
	u_spring := engine.vg_add_node(&g, .Anim_Spring_Damper,  {660, 0})
	u_set    := engine.vg_add_node(&g, .Set_Variable,        {880, 0}, "blended_pose")
	u_ik     := engine.vg_add_node(&g, .Anim_IK_Target,      {1100, 0})
	u_vfx_sp := engine.vg_add_node(&g, .VFX_Emitter_Spawn,   {1320, 0})
	u_curl   := engine.vg_add_node(&g, .VFX_GPU_Curl_Force,  {880, 220})
	u_life   := engine.vg_add_node(&g, .VFX_Color_Size_Life, {880, 360})

	// Configure deterministic inputs: Blend(0.2, 0.8, alpha=0.5) -> 0.5 -> Spring toward 0.5
	if nb := engine.vg_find_node(&g, u_blend); nb != nil && len(nb.inputs) >= 3 {
		nb.inputs[0].default_f32 = 0.20
		nb.inputs[1].default_f32 = 0.80
		nb.inputs[2].default_f32 = 0.50
	}
	if ns := engine.vg_find_node(&g, u_spring); ns != nil && len(ns.inputs) >= 3 {
		ns.inputs[0].default_f32 = 0.00
		ns.inputs[2].default_f32 = 20.0
	}
	// Inject a legacy unbaked Unicode prefix on a pin to prove `.bodin` round-trip strips it!
	if nc := engine.vg_find_node(&g, u_clip); nc != nil && len(nc.outputs) > 0 {
		delete(nc.outputs[0].name)
		nc.outputs[0].name = strings.clone("\u25c7 Pose Weight")
	}

	// Exec chain: Tick -> Set_Variable -> Anim_IK_Target -> VFX_Emitter_Spawn
	append(&g.wires, engine.VG_Wire{from_uid = u_tick, from_pin = 0, to_uid = u_set,    to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_set,  from_pin = 0, to_uid = u_ik,     to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_ik,   from_pin = 0, to_uid = u_vfx_sp, to_pin = 0})
	// Pure chain: Blend -> Spring.Target (pin 1) -> Set_Variable.Value (pin 1)
	append(&g.wires, engine.VG_Wire{from_uid = u_blend,  from_pin = 0, to_uid = u_spring, to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_spring, from_pin = 0, to_uid = u_set,    to_pin = 1})
	// Wire Curl & Life into IK / Spawn so transpiler exercises their pure codegen too
	append(&g.wires, engine.VG_Wire{from_uid = u_curl, from_pin = 0, to_uid = u_ik,     to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_life, from_pin = 0, to_uid = u_vfx_sp, to_pin = 1})

	ent := engine.transform_new("UnifiedMotionEntity")
	bb: engine.VG_Runtime_Blackboard
	defer delete(bb.last_exec_path)
	engine.vg_eval_graph_live(&g, &bb, ent, 0.05)
	testing.expect(t, bb.initialized && bb.slots[0].val_f32 > 0.25 && bb.slots[0].val_f32 <= 0.50, "expected Tier-1 live Blend+Spring evaluation to advance blended_pose toward 0.5")

	// Transpile to native Odin & verify clean codegen for Motion + GPU VFX nodes
	odin_code, main_proc := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect_value(t, main_proc, "mhgraph_unit_unified_motion_vfx")
	testing.expect(t, strings.contains(odin_code, "math.lerp("), "expected Anim_Blend_Layered / VFX_Color_Size_Life math.lerp emission")
	testing.expect(t, strings.contains(odin_code, "hot.damp_f32("), "expected Anim_Spring_Damper hot.damp_f32 emission")

	// Round-trip `.bodin` save + load: verify `domain == .Anim_Motion` AND legacy `\u25c7 ` stripped!
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_abs, _ := filepath.join({repo_root, fmt.tprintf("assets/scripts/_tmp_unified_%d.bodin", os.get_pid())}, context.temp_allocator)
	testing.expect(t, engine.vg_save_bodin_file(&g, tmp_abs, odin_code), "expected .bodin save to succeed")
	defer _ = os.remove(tmp_abs)

	loaded: engine.Visual_Graph
	defer engine.vg_destroy_graph(&loaded)
	testing.expect(t, engine.vg_load_from_file(&loaded, tmp_abs), "expected .bodin load to succeed")
	testing.expect_value(t, loaded.domain, engine.VG_Graph_Domain.Anim_Motion)
	if lc := engine.vg_find_node(&loaded, u_clip); lc != nil && len(lc.outputs) > 0 {
		testing.expect_value(t, lc.outputs[0].name, "Pose Weight")
	}
}

// 4. Static UI Glyph Contract: ensures unbaked Unicode Dingbats / Geometric Shapes / Emoji
//    (`◇`, `▷`, `●`, `◆`, `👁`, `✓`, `✗`, `⚡`, `↻`, `∠`) never appear in non-comment code lines
//    of the Studio IDE, Unified Graph Studio, Inspector, or CAD CSG editor!
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
		"\u25c7", // ◇
		"\u25b7", // ▷
		"\u25cf", // ●
		"\u25c6", // ◆
		"\U0001f441", // 👁
		"\u2713", // ✓
		"\u2717", // ✗
		"\u26a1", // ⚡
		"\u21bb", // ↻
		"\u2220", // ∠
	}

	for rel in checked_files {
		abs_p, _ := filepath.join({repo_root, rel}, context.temp_allocator)
		data, err := os.read_entire_file(abs_p, context.temp_allocator)
		testing.expectf(t, err == nil, "expected to read %s", rel)
		if err != nil do continue

		for raw_ln, li in strings.split_lines(string(data), context.temp_allocator) {
			trimmed := strings.trim_space(raw_ln)
			if strings.has_prefix(trimmed, "//") do continue
			// Strip trailing `//` line comment before scanning code / string literals
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
