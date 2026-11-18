package tests

import "base:runtime"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../engine"
import crash_journal "haati:engine/crash_journal"
import cs "haati:editor/code_studio"
import nc "haati:editor/node_canvas"
import im "haati:external/odin-imgui"

@(private = "file")
_wave4_trigger_assertion_c :: proc "c" (_arg: rawptr) {
	context = runtime.default_context()
	context.assertion_failure_proc = crash_journal.sandbox_assertion_failure_proc
	assert(false, "wave4 intentional sandbox assertion trap")
}

// 1. Verifies runtime NaN/Inf transform scrubbing, NaN component float survival across
//    scene_serialize -> scene_file_unmarshal, malformed [0x5b, 0xf8] rejection, and
//    nil context.user_ptr safety on ctx_scene_manager().
@(test)
test_wave4_nan_transform_scrub_component_save_and_nil_ctx :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Nil context.user_ptr safety check (restored immediately).
	{
		prev_ptr := context.user_ptr
		context.user_ptr = nil
		defer context.user_ptr = prev_ptr
		testing.expect(t, engine.ctx_scene_manager() == nil, "ctx_scene_manager() must return nil when context.user_ptr is nil")
		testing.expect_value(t, engine.sm_loaded_scene_count(), 0)
	}

	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	rootH := engine.Transform_Handle(tc.scene.root.handle)
	nodeH := engine.transform_new("ScrubNode", rootH)
	testing.expect(t, nodeH != {}, "transform_new must allocate ScrubNode")
	tr := engine.pool_get(&tc.world.transforms, engine.Handle(nodeH))
	testing.expect(t, tr != nil, "pool_get must resolve ScrubNode")
	if tr == nil do return

	tr.position = {math.nan_f32(), 4.0, math.inf_f32(1)}
	tr.rotation = {math.nan_f32(), 0, 0, 1}
	tr.scale    = {math.nan_f32(), math.inf_f32(-1), 2.5}

	repaired := engine.world_scrub_non_finite_transforms(tc.uc.world)
	testing.expect(t, repaired >= 1, "world_scrub_non_finite_transforms must repair non-finite TRS")
	testing.expect(t, !math.is_nan(tr.position.x) && !math.is_inf(tr.position.z), "scrubbed position must be finite")
	testing.expect_value(t, tr.rotation, engine.QUAT_IDENTITY)
	testing.expect(t, !math.is_nan(tr.scale.x) && abs(tr.scale.x - 1.0) < 0.01 && !math.is_inf(tr.scale.y) && abs(tr.scale.y - 1.0) < 0.01 && abs(tr.scale.z - 2.5) < 0.01, "scrubbed non-finite scale axes must reset to 1.0")

	// Non-finite component float must still serialize/unmarshal without crashing.
	_, lt := engine.transform_get_or_add_comp(nodeH, engine.Light)
	testing.expect(t, lt != nil, "Light component should attach")
	if lt != nil {
		lt.intensity = math.nan_f32()
	}

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok && len(bytes) > 0, "scene_serialize must succeed with NaN Light field scrubbed/sanitized")
	if ok {
		defer delete(bytes)
		dec: engine.SceneFile
		defer engine.scene_file_destroy(&dec)
		testing.expect(t, engine.scene_file_unmarshal(bytes, &dec) == nil, "scene_file_unmarshal must decode serialized scene")
	}

	// Malformed [0x5b, 0xf8] bytes must fail cleanly rather than asserting inside json parser.
	bad := [2]u8{0x5b, 0xf8}
	bad_sf: engine.SceneFile
	defer engine.scene_file_destroy(&bad_sf)
	testing.expect(t, engine.scene_file_unmarshal(bad[:], &bad_sf) != nil, "malformed [0x5b, 0xf8] must return unmarshal error")
}

// 2. Verifies sandbox_exec catches Layer 1 Odin assertions via sandbox_assertion_failure_proc.
@(test)
test_wave4_sandbox_exec_assertion_recovery :: proc(t: ^testing.T) {
	fault, ok := crash_journal.sandbox_exec(_wave4_trigger_assertion_c, nil)
	testing.expect(t, !ok, "sandbox_exec must return ok=false when assertion trips")
	testing.expect(t, fault.occurred, "Sandbox_Fault_Info.occurred must be true on caught assertion")
}

// 3. Verifies tokenized delimiter balance, string/comment-aware bracket matching, and exact
//    identifier end_column computation in Code Studio Stage A diagnostics.
@(test)
test_wave4_delimiter_balance_brackets_and_exact_span :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	clean_src := "package demo\nf :: proc() {\n\ts := \"{ [ )\"\n\t// }\n\ty := [2]int{1, 2}\n}\n"
	clean_errs := cs.check_odin_delimiter_balance(clean_src, context.temp_allocator)
	testing.expect_value(t, len(clean_errs), 0)

	b0 := strings.index_byte(clean_src, '{')
	b1 := strings.last_index_byte(clean_src, '}')
	p1, p2, bok := cs.find_matching_bracket_tokenized(clean_src, b0)
	testing.expect(t, bok && p1 == b0 && p2 == b1, "tokenized matcher must pair outer '{' with outer '}' skipping string/comment braces")

	unclosed_src := "package demo\nf :: proc() {\n\tx := 1\n"
	unclosed_errs := cs.check_odin_delimiter_balance(unclosed_src, context.temp_allocator)
	testing.expect(t, len(unclosed_errs) >= 1, "unclosed '{' must be detected")
	if len(unclosed_errs) > 0 {
		testing.expect_value(t, unclosed_errs[0].line, 2)
		testing.expect(t, strings.contains(unclosed_errs[0].message, "{"), "message must cite unclosed '{'")
	}

	mismatch_src := "package demo\nf :: proc() {\n\ta := [2]int{1, 2)\n}\n"
	mismatch_errs := cs.check_odin_delimiter_balance(mismatch_src, context.temp_allocator)
	testing.expect(t, len(mismatch_errs) >= 1, "mismatched ')' closing '{' must be detected")
	if len(mismatch_errs) > 0 {
		testing.expect_value(t, mismatch_errs[0].line, 3)
	}

	bad_span_src := "package demo\nf :: proc() {\n\talpha_long_token @ 1\n}\n"
	diags, _ := cs.check_odin_syntax_in_ram(bad_span_src, false, context.temp_allocator)
	testing.expect(t, len(diags) > 0, "expected Stage A diagnostic")
	for d in diags {
		testing.expect(t, d.end_column >= d.column + 1, "end_column must cover at least one character")
	}
}

// 4. Verifies unbounded Node_Canvas (>64 ids), Electronic_45 / Orthogonal_90 wire hit-testing,
//    and .bodin @BODIN_GRAPH_V1 comment box round-trip persistence with 0 leaks.
@(test)
test_wave4_unbounded_node_canvas_wire_dist_and_bodin_comments :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cv: nc.Node_Canvas
	nc.canvas_init(&cv)
	defer nc.canvas_destroy(&cv)

	nc.canvas_set_selected(&cv, 128, true)
	nc.canvas_set_selected(&cv, 256, true)
	testing.expect(t, nc.canvas_is_selected(&cv, 128), "id 128 > 64 must select cleanly")
	testing.expect(t, nc.canvas_is_selected(&cv, 256), "id 256 > 64 must select cleanly")
	testing.expect_value(t, nc.canvas_selected_count(&cv), 2)

	nc.canvas_set_collapsed(&cv, 128, true)
	testing.expect(t, nc.canvas_is_collapsed(&cv, 128), "id 128 collapse must persist")
	nc.canvas_set_all_collapsed(&cv, true)
	nc.canvas_set_collapsed(&cv, 200, false)
	testing.expect(t, nc.canvas_is_collapsed(&cv, 129) && !nc.canvas_is_collapsed(&cv, 200), "bulk collapse + per-id override must work for any id")

	nc.canvas_set_node_size(&cv, 128, im.Vec2{320, 140})
	sz := nc.canvas_get_node_size(&cv, 128)
	testing.expect(t, abs(sz.x - 320.0) < 0.01 && abs(sz.y - 140.0) < 0.01, "node size for id 128 must persist")

	from := im.Vec2{100, 100}
	to   := im.Vec2{300, 200}
	d_orth_hit  := nc.canvas_dist_point_to_wire(im.Vec2{200, 150}, from, to, .Orthogonal_90, 1.0)
	d_orth_miss := nc.canvas_dist_point_to_wire(im.Vec2{200, 40},  from, to, .Orthogonal_90, 1.0)
	testing.expect(t, d_orth_hit < 1.0 && d_orth_miss > 40.0, "Orthogonal_90 hit-test must lie on vertical mid segment")

	d_45_hit  := nc.canvas_dist_point_to_wire(im.Vec2{200, 150}, from, to, .Electronic_45, 1.0)
	d_45_miss := nc.canvas_dist_point_to_wire(im.Vec2{200, 20},  from, to, .Electronic_45, 1.0)
	testing.expect(t, d_45_hit < 1.0 && d_45_miss > 40.0, "Electronic_45 hit-test must match polyline midpoint")

	// Comment box persistence inside .bodin (@BODIN_GRAPH_V1).
	g: engine.Visual_Graph
	defer engine.vg_destroy_graph(&g)
	g.name = strings.clone("wave4_comment_demo")
	g.next_uid = 2
	append(&g.comments, engine.VG_Comment_Box{
		title = strings.clone("Combat Loop"),
		pos   = {-120.5, 45.25},
		size  = {410.0, 230.0},
		color = {0.25, 0.55, 0.85, 0.35},
	})

	cloned := engine.vg_clone_graph(&g)
	defer engine.vg_destroy_graph(&cloned)
	testing.expect(t, engine.vg_graphs_equal(&g, &cloned), "vg_clone_graph + vg_graphs_equal must preserve VG_Comment_Box")

	tmp_path := "haati/tests/_tmp_wave4_comments.bodin"
	defer _ = os.remove(tmp_path)
	testing.expect(t, engine.vg_save_bodin_file(&g, tmp_path, "package hot_scripts\n"), "vg_save_bodin_file must succeed")

	loaded: engine.Visual_Graph
	defer engine.vg_destroy_graph(&loaded)
	testing.expect(t, engine.vg_load_from_file(&loaded, tmp_path), "vg_load_from_file must reload .bodin comment boxes")
	testing.expect_value(t, len(loaded.comments), 1)
	if len(loaded.comments) == 1 {
		testing.expect_value(t, loaded.comments[0].title, "Combat Loop")
		testing.expect(t, abs(loaded.comments[0].pos[0] - (-120.5)) < 0.01, "comment pos.x must round-trip")
		testing.expect(t, abs(loaded.comments[0].size[0] - 410.0) < 0.01, "comment size.x must round-trip")
	}
}
