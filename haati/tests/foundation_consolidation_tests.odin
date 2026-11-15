package tests

import "core:mem"
import "core:testing"

import "../engine"
import clip "haati:editor/clipboard"
import cs "haati:editor/code_studio"
import widgets "haati:editor/widgets"

@(test)
test_foundation_search_query_and_widget_terms :: proc(t: ^testing.T) {
	raw_lo, norm := engine.normalize_search_key("Player_Controller-01.odin", context.temp_allocator)
	testing.expect_value(t, raw_lo, "player_controller-01.odin")
	testing.expect_value(t, norm, "playercontroller01odin")

	pq_node := engine.prepare_search_query("node3", context.temp_allocator)
	testing.expect(t, engine.search_match_fields_primary(&pq_node, "node_3.odin", "assets/scripts/node_3.odin"), "delimiter-insensitive match should hit node_3.odin")

	pq_folder := engine.prepare_search_query("assets", context.temp_allocator)
	testing.expect(t, !engine.search_match_fields_primary(&pq_folder, "player.odin", "assets/scripts/player.odin"), "primary-required match must not match folder name alone")
	testing.expect(t, engine.search_match_fields(&pq_folder, "player.odin", "assets/scripts/player.odin"), "general field match should include secondary fields")

	pq_path := engine.prepare_search_query("assets/player", context.temp_allocator)
	testing.expect(t, engine.search_match_fields_primary(&pq_path, "player.odin", "assets/player.odin"), "explicit path query should match secondary path")

	testing.expect(t, engine.can_narrow_search_query("spr", "sprite"), "can_narrow_search_query should accept strict refinement")
	testing.expect(t, !engine.can_narrow_search_query("sprite", "spr"), "can_narrow_search_query should reject backspace widening")
	testing.expect(t, !engine.can_narrow_search_query("", "spr"), "can_narrow_search_query should reject empty previous query")

	terms := widgets.search_terms("spring camera")
	testing.expect(t, len(terms) == 2, "search_terms should split whitespace tokens")
	testing.expect(t, widgets.search_match("SpringArmCameraComponent", terms), "widget search_match should match all terms")
	testing.expect(t, !widgets.search_match("CameraComponent", terms), "widget search_match should reject missing terms")
}

@(test)
test_foundation_fixed_c_buffer_helpers :: proc(t: ^testing.T) {
	buf: [8]u8
	written := widgets.buf_set(buf[:], "0123456789", zero_tail = true)
	testing.expect_value(t, written, "0123456")
	testing.expect_value(t, buf[7], u8(0))
	testing.expect_value(t, widgets.buf_str(buf[:]), "0123456")

	widgets.buf_set(buf[:], "  abc  ", zero_tail = true)
	testing.expect_value(t, widgets.buf_str(buf[:]), "  abc  ")
	testing.expect_value(t, widgets.buf_str(buf[:], trim_space = true), "abc")

	widgets.buf_clear(buf[:], zero_all = true)
	testing.expect_value(t, widgets.buf_str(buf[:]), "")
	for b in buf {
		testing.expect_value(t, b, u8(0))
	}
}

@(test)
test_foundation_clipboard_paste_component_values :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	clip.init()
	defer clip.shutdown()

	root := engine.transform_new("Root")
	engine.scene_set_root(tc_mem.scene, root)
	a := engine.transform_new("LightA")
	b := engine.transform_new("LightB")
	engine.transform_set_parent(a, root)
	engine.transform_set_parent(b, root)

	_, src := engine.transform_get_or_add_comp(a, engine.Light)
	_, dst := engine.transform_get_or_add_comp(b, engine.Light)
	testing.expect(t, src != nil && dst != nil, "both Light components should exist")
	if src == nil || dst == nil do return

	src.enabled = true
	src.type = .Spot
	src.intensity = 4.5
	src.range = 32.0
	src.spot_angle = 55.0

	dst_owner := dst.owner
	dst_lid := dst.local_id
	dst.enabled = false
	dst.type = .Directional
	dst.intensity = 1.0

	testing.expect(t, clip.copy(any{src, typeid_of(engine.Light)}), "clip.copy should serialize Light component")
	testing.expect(t, clip.paste_component_values(dst, typeid_of(engine.Light), .Light), "paste_component_values should succeed")

	testing.expect_value(t, dst.type, engine.Light_Type.Spot)
	testing.expect(t, abs(dst.intensity - 4.5) < 1e-4, "paste_component_values should copy intensity payload")
	testing.expect(t, abs(dst.range - 32.0) < 1e-4, "paste_component_values should copy range payload")
	testing.expect(t, abs(dst.spot_angle - 55.0) < 1e-4, "paste_component_values should copy spot_angle payload")

	testing.expect_value(t, dst.owner, dst_owner)
	testing.expect_value(t, dst.local_id, dst_lid)
	testing.expect_value(t, dst.enabled, false)
}

@(test)
test_foundation_code_studio_ident_and_arena_parser :: proc(t: ^testing.T) {
	testing.expect(t, cs.is_valid_odin_ident("player_speed2"), "valid Odin ident should pass")
	testing.expect(t, !cs.is_valid_odin_ident("2fast"), "leading digit should fail ident check")
	testing.expect(t, !cs.is_valid_odin_ident(""), "empty ident should fail")

	testing.expect_value(t, cs.sanitize_odin_ident("99-my event!", context.temp_allocator), "_9_my_event_")

	src := "hero^.move_speed = 1.0; for i in 0..10 {}"
	testing.expect_value(t, cs.extract_dot_receiver_before(src, len("hero^.")), "hero")
	testing.expect_value(t, cs.extract_dot_receiver_before(src, len(src) - len("10 {}")), "")

	id1, rec1, ok1 := cs.odin_ident_at("player.jump(dt)", 8)
	testing.expect(t, ok1, "odin_ident_at should find method ident")
	testing.expect_value(t, id1, "jump")
	testing.expect_value(t, rec1, "player")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	file, parsed_ok, used_src := cs.parse_odin_in_arena(
		"package demo\nstep :: proc(dt: f32) -> f32 { return dt * 2.0 }\n",
		"demo.odin",
		false,
		&arena,
	)
	testing.expect(t, parsed_ok, "parse_odin_in_arena full-file mode should parse cleanly")
	testing.expect(t, len(file.decls) == 1 && len(used_src) > 0, "parsed full file should contain 1 decl")

	mem.dynamic_arena_free_all(&arena)
	scoped_file, scoped_ok, scoped_src := cs.parse_odin_in_arena(
		"x := dt * 3.0\napi.log(x)",
		"scoped.odin",
		true,
		&arena,
	)
	testing.expect(t, scoped_ok, "parse_odin_in_arena scoped mode should wrap & parse body cleanly")
	testing.expect(t, len(scoped_file.decls) >= 1 && len(scoped_src) > 0, "wrapped scoped body should parse _mh_body decl")
}
