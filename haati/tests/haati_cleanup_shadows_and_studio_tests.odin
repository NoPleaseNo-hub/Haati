package tests

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../engine"
import gfx "../engine/gfx"
import hot "../engine/hot_api"
import "haati:engine_editor/asset_pipeline"
import cs "haati:editor/code_studio"
import nc "haati:editor/node_canvas"
import vs "haati:editor/visual_script"

_repo_join :: proc(repo, rel: string) -> string {
	joined, _ := filepath.join({repo, rel}, context.temp_allocator)
	return joined
}

// 1. Haati branding, legal notices, CLI/mannequin relocation, and legacy cleanup.
@(test)
test_haati_branding_cleanup_and_relocated_assets :: proc(t: ^testing.T) {
	repo := engine.resolve_repo_root(context.temp_allocator)

	required := []string{
		"LICENSE",
		"THIRD_PARTY_NOTICES.md",
		"README.md",
		"MANUAL.md",
		"tools/haati/haati.odin",
		"tools/launcher/main.odin",
		"plugins/control_rig/assets/meshes/characters/Mannequin_F.glb",
		"haati/editor/node_canvas/node_block.odin",
		"haati/engine/gfx/shaders/lighting_common.glsl",
	}
	for rel in required {
		p := _repo_join(repo, rel)
		testing.expectf(t, os.exists(p), "expected required Haati file to exist: %s", rel)
	}

	lic_bytes, lic_err := os.read_entire_file(_repo_join(repo, "LICENSE"), context.temp_allocator)
	testing.expect(t, lic_err == nil, "expected LICENSE to be readable")
	if lic_err == nil {
		lic_text := string(lic_bytes)
		testing.expect(t, strings.contains(lic_text, "Haati"), "expected LICENSE to identify Haati")
		testing.expect(t, strings.contains(lic_text, "MoonHug"), "expected LICENSE to retain MoonHug zlib notice")
	}

	removed := []string{
		".idea",
		"moonhug",
		"haati/editor/node_canvas/niagara_block.odin",
		"haati/editor/view_hierarchy.odin",
		"haati/editor/view_project.odin",
	}
	for rel in removed {
		p := _repo_join(repo, rel)
		testing.expectf(t, !os.exists(p), "expected removed legacy path not to exist: %s", rel)
	}
}

// 2. 4096x4096 16-tile shadow atlas constants and point cubemap face selection/projection math.
@(test)
test_shadow_atlas_16_tile_and_point_cubemap_math :: proc(t: ^testing.T) {
	testing.expect_value(t, gfx.SHADOW_ATLAS_SIZE, 4096)
	testing.expect_value(t, gfx.SHADOW_TILE_SIZE, 1024)
	testing.expect_value(t, gfx.SHADOW_SAMPLER_SLOT, 7)
	testing.expect_value(t, engine.SHADER_SHADOW_SAMPLER_BINDING, 7)
	testing.expect_value(t, engine.SHADER_ARTIFACT_MAGIC, "MHSHDR5\x00")

	testing.expect_value(t, gfx.shadow_select_point_face({5, 1, -2}), 0)
	testing.expect_value(t, gfx.shadow_select_point_face({-5, 1, 2}), 1)
	testing.expect_value(t, gfx.shadow_select_point_face({1, 6, -1}), 2)
	testing.expect_value(t, gfx.shadow_select_point_face({-1, -6, 1}), 3)
	testing.expect_value(t, gfx.shadow_select_point_face({1, -2, 7}), 4)
	testing.expect_value(t, gfx.shadow_select_point_face({1, 2, -7}), 5)

	dirs := [6][3]f32{
		{1, 0, 0},
		{-1, 0, 0},
		{0, 1, 0},
		{0, -1, 0},
		{0, 0, 1},
		{0, 0, -1},
	}
	light_pos := [3]f32{2, 3, -4}
	for f in 0 ..< 6 {
		vp := gfx.shadow_point_face_vp(light_pos, f, 20.0)
		det := linalg.determinant(vp)
		testing.expectf(t, abs(det) > 1e-12, "point face %d shadow matrix must be non-singular", f)

		p := light_pos + dirs[f] * 5.0
		clip := vp * [4]f32{p.x, p.y, p.z, 1.0}
		testing.expect(t, clip.w > 0, "center point along cubemap face must be in front of light")
		ndc := clip.xyz / clip.w
		testing.expectf(t, abs(ndc.x) < 1e-4 && abs(ndc.y) < 1e-4 && ndc.z > 0.0 && ndc.z < 1.0,
			"face %d center projected unexpectedly: %v", f, ndc)
	}
}

// 3. Shader importer `#include "lighting_common.glsl"` compilation & slot-7 shadow sampler exclusion.
@(test)
test_shader_importer_lighting_common_and_shadow_slot_exclusion :: proc(t: ^testing.T) {
	if !_toolchain_available() {
		testing.expect(t, true)
		return
	}

	repo := engine.resolve_repo_root(context.temp_allocator)
	tmp_dir, _ := os.temp_directory(context.temp_allocator)

	cases := [2]struct {
		src_rel: string,
		out_bin: string,
	}{
		{"plugins/essentials/assets/shaders/pbr.glsl", "_haati_test_pbr_artifact.bin"},
		{"plugins/app/assets/shaders/specular.glsl", "_haati_test_spec_artifact.bin"},
	}

	for c in cases {
		src := _repo_join(repo, c.src_rel)
		artifact, _ := filepath.join({tmp_dir, c.out_bin}, context.temp_allocator)
		defer os.remove(artifact)

		ok := asset_pipeline._import_shader(src, artifact, nil)
		testing.expectf(t, ok, "expected _import_shader to succeed for %s", c.src_rel)
		if !ok do continue

		blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
		testing.expect(t, read_err == nil, "expected shader artifact file to be readable")
		if read_err != nil do continue

		header, _, _, _, texs, parse_ok := engine._shader_artifact_parse(blob, context.temp_allocator)
		testing.expect(t, parse_ok, "expected MHSHDR5 artifact to parse cleanly")
		testing.expect_value(t, header.num_samplers, u32(8))
		testing.expect_value(t, header.num_uniform_buffers, u32(2))
		for st in texs {
			testing.expect(t, st.binding != engine.SHADER_SHADOW_SAMPLER_BINDING && st.name != "u_shadow_map",
				"reserved shadow map binding 7 must not be exposed as a Material texture row")
		}
	}
}

// 4. Pitch-black 0-light defaults and per-view Lit/Unlit lighting resolution.
@(test)
test_zero_light_pitch_black_and_view_lighting_resolution :: proc(t: ^testing.T) {
	l: engine.Light
	engine.reset_Light(&l)
	testing.expect_value(t, l.ambient, f32(0.0))

	apply, n, amb := engine.render_resolve_view_lighting(.Preview, 0, 0.0, false)
	testing.expect(t, !apply && n == 0 && amb == 0.0, "Preview must leave caller headlight/default intact")

	apply, n, amb = engine.render_resolve_view_lighting(.Game, 0, 0.0, true)
	testing.expect(t, apply && n == 0 && amb == 0.0, "Game view must ignore SceneView unlit override and stay pitch black at 0 lights")

	apply, n, amb = engine.render_resolve_view_lighting(.SceneView, 0, 0.0, false)
	testing.expect(t, apply && n == 0 && amb == 0.0, "Lit SceneView must be pitch black at 0 lights")

	apply, n, amb = engine.render_resolve_view_lighting(.SceneView, 3, 0.2, true)
	testing.expect(t, apply && n == 0 && amb == 1.0, "Unlit SceneView must force flat 1.0 ambient with 0 lights")

	apply, n, amb = engine.render_resolve_view_lighting(.SceneView, 2, 0.15, false)
	testing.expect(t, apply && n == 2 && abs(amb - 0.15) < 1e-6, "Lit SceneView must forward active scene lights & ambient")
}

// 5. Node namespaces, styling accents, and vg_pin_odin_type lookup table accuracy.
@(test)
test_node_namespaces_and_vg_pin_odin_type_lut :: proc(t: ^testing.T) {
	ns_cases := []struct {
		kind:  engine.VG_Node_Kind,
		badge: string,
	}{
		{.Event_Tick, "EVENT"},
		{.Branch_If, "FLOW"},
		{.Bind_Input_Action, "INPUT"},
		{.Math_Float, "MATH"},
		{.Get_Transform_Pos, "TRANSFORM"},
		{.Anim_Clip_Eval, "ANIM"},
		{.VFX_GPU_Curl_Force, "VFX"},
		{.Audio_Play_Spatial_3D, "AUDIO"},
		{.AI_Find_Path_Move, "AI"},
		{.Delegate_Bind, "DELEGATE"},
		{.Get_Variable, "VARIABLE"},
	}
	for nc in ns_cases {
		badge, accent := vs.vg_namespace_style(vs.vg_node_namespace(nc.kind))
		testing.expect_value(t, badge, nc.badge)
		testing.expect(t, accent.a > 0.9, "namespace accent alpha should be opaque")
	}

	testing.expect_value(t, vs.vg_node_namespace(.Call_Hot_Proc, "vfx_sparks"), vs.VG_Namespace.VFX)
	testing.expect_value(t, vs.vg_node_namespace(.Call_Hot_Proc, "audio_cue"), vs.VG_Namespace.Audio)

	pin_cases := []struct {
		pt:     hot.Hot_Pin_Type,
		scalar: string,
		arr:    string,
	}{
		{.Exec, "exec", "exec"},
		{.Bool, "bool", "[8]bool"},
		{.Int, "i32", "[8]i32"},
		{.Int64, "i64", "[8]i64"},
		{.Float, "f32", "[8]f32"},
		{.Vec2, "[2]f32", "[8][2]f32"},
		{.Vec3, "[3]f32", "[8][3]f32"},
		{.Vec4, "[4]f32", "[8][4]f32"},
		{.Quat, "[4]f32", "[8][4]f32"},
		{.String, "cstring", "[8]cstring"},
		{.Asset, "cstring", "[8]cstring"},
		{.Entity, "hot.Hot_Entity", "[8]hot.Hot_Entity"},
		{.Delegate, "hot.Hot_Delegate", "hot.Hot_Delegate"},
	}
	for pc in pin_cases {
		testing.expect_value(t, engine.vg_pin_odin_type(pc.pt, false), pc.scalar)
		testing.expect_value(t, engine.vg_pin_odin_type(pc.pt, true), pc.arr)
	}
}

// 6. 64-step bounded Text IDE & Blueprint Graph Undo/Redo stacks.
@(test)
test_studio_64_step_text_and_graph_undo_redo :: proc(t: ^testing.T) {
	// Text IDE Undo/Redo
	st: cs.Code_Undo_Stack
	defer cs.code_undo_free(&st)

	cs.code_undo_reset(&st, "v0", 2)
	for i in 1 ..= 70 {
		cs.code_undo_record_edit(&st, fmt.tprintf("v%d", i), i, f64(i), immediate = true)
	}
	testing.expect_value(t, len(st.undo), cs.CODE_UNDO_MAX)
	testing.expect_value(t, len(st.undo), 64)

	last_text := ""
	for _ in 0 ..< 64 {
		entry, ok := cs.code_undo_step_undo(&st)
		testing.expect(t, ok, "expected undo step to succeed")
		last_text = entry.text
	}
	testing.expect_value(t, last_text, "v6")
	testing.expect(t, !cs.code_undo_can_undo(&st), "expected undo stack exhausted after 64 steps")

	for _ in 0 ..< 64 {
		entry, ok := cs.code_undo_step_redo(&st)
		testing.expect(t, ok, "expected redo step to succeed")
		last_text = entry.text
	}
	testing.expect_value(t, last_text, "v70")
	testing.expect(t, !cs.code_undo_can_redo(&st), "expected redo stack exhausted after 64 steps")

	// Blueprint Graph Undo/Redo (headless safe)
	vs.shutdown_visual_script_studio()
	defer vs.shutdown_visual_script_studio()

	g := vs.active_visual_graph()
	vs.vs_clear_undo()
	n0 := len(g.nodes)
	for i in 0 ..< 68 {
		vs.vs_push_undo()
		vs.vs_add_node(.Math_Float, {f32(i * 12), 0})
	}
	u_n, r_n := vs.vs_undo_depth()
	testing.expect_value(t, u_n, vs.VS_UNDO_MAX)
	testing.expect_value(t, u_n, 64)
	testing.expect_value(t, r_n, 0)

	testing.expect(t, vs.vs_undo(), "expected vs_undo to succeed")
	testing.expect_value(t, len(vs.active_visual_graph().nodes), n0 + 67)

	testing.expect(t, vs.vs_redo(), "expected vs_redo to succeed")
	testing.expect_value(t, len(vs.active_visual_graph().nodes), n0 + 68)
}

// 7. Scene 3D [Lit | Unlit | FakeLight] viewport resolution & Game-view isolation.
@(test)
test_scene_lighting_modes_lit_unlit_fakelight :: proc(t: ^testing.T) {
	prev_mode  := engine.render_scene_lighting_mode
	prev_unlit := engine.render_scene_unlit_override
	defer {
		engine.render_scene_lighting_mode  = prev_mode
		engine.render_scene_unlit_override = prev_unlit
	}

	apply, cnt, amb, fake := engine.render_resolve_view_lighting_mode(.SceneView, 0, 0.2, .Lit)
	testing.expect(t, apply && cnt == 0 && amb == 0.0 && !fake, "SceneView Lit with 0 lights must be true pitch black")

	apply, cnt, amb, fake = engine.render_resolve_view_lighting_mode(.SceneView, 2, 0.2, .Unlit)
	testing.expect(t, apply && cnt == 0 && amb == 1.0 && !fake, "SceneView Unlit must override to flat full-bright ambient 1.0")

	apply, cnt, amb, fake = engine.render_resolve_view_lighting_mode(.SceneView, 0, 0.0, .FakeLight)
	testing.expect(t, apply && cnt == 1 && abs(amb - 0.35) < 0.001 && fake, "SceneView FakeLight must activate studio light + 0.35 ambient")

	apply, cnt, amb, fake = engine.render_resolve_view_lighting_mode(.Game, 0, 0.0, .FakeLight)
	testing.expect(t, apply && cnt == 0 && amb == 0.0 && !fake, "Game view must ignore SceneView FakeLight and remain true Lit pitch black")

	apply, cnt, amb, fake = engine.render_resolve_view_lighting_mode(.Preview, 0, 0.0, .FakeLight)
	testing.expect(t, !apply && !fake, "Preview view must keep its own preview headlight")

	studio := engine.render_fake_studio_light()
	testing.expect_value(t, studio.kind, gfx.Light_Kind.Directional)
	testing.expect(t, studio.cast_shadows, "FakeLight studio directional light must cast CSM shadows")
	testing.expect(t, studio.shadow_strength > 0.0, "FakeLight shadow_strength must be > 0")

	engine.render_set_scene_lighting_mode(.FakeLight)
	testing.expect_value(t, engine.render_effective_scene_lighting_mode(), engine.Scene_Lighting_Mode.FakeLight)
	engine.render_set_scene_lighting_mode(.Unlit)
	testing.expect_value(t, engine.render_effective_scene_lighting_mode(), engine.Scene_Lighting_Mode.Unlit)
	engine.render_set_scene_lighting_mode(.Lit)
	testing.expect_value(t, engine.render_effective_scene_lighting_mode(), engine.Scene_Lighting_Mode.Lit)
}

// 8. Canonical BP_Node aliases & Unreal-style context-sensitive pin-drag node probing.
@(test)
test_bp_node_aliases_and_context_pin_matching :: proc(t: ^testing.T) {
	testing.expect_value(t, nc.BP_NODE_HEADER_H, nc.NODE_HEADER_H)
	testing.expect_value(t, size_of(nc.BP_Node_Spec), size_of(nc.Node_Block_Spec))

	g: engine.Visual_Graph
	defer engine.vg_destroy_graph(&g)
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("speed"), pin_type = .Float})
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("grounded"), pin_type = .Bool})

	float_out := engine.VG_Pin_Def{pin_type = .Float, pass_mode = .Copy_Value, is_addressable = false}
	testing.expect(t, engine.vg_probe_compatible_pin(&g, .Math_Float, "", true, float_out) >= 0, "Math_Float must accept green Float output")
	testing.expect_value(t, engine.vg_probe_compatible_pin(&g, .Set_Variable, "speed", true, float_out), 1)
	testing.expect_value(t, engine.vg_probe_compatible_pin(&g, .Set_Variable, "grounded", true, float_out), -1)
	testing.expect_value(t, engine.vg_probe_compatible_pin(&g, .Branch_If, "", true, float_out), -1)

	del_in := engine.VG_Pin_Def{pin_type = .Delegate}
	testing.expect_value(t, engine.vg_probe_compatible_pin(&g, .Custom_Proc_Entry, "On_Jump", false, del_in), 0)
	testing.expect_value(t, engine.vg_probe_compatible_pin(&g, .Math_Float, "", false, del_in), -1)
}
