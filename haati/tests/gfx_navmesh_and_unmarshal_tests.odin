package tests

import "core:encoding/endian"
import "core:encoding/json"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:testing"

import "../engine"
import file_exp "haati:editor/file_explorer"
import core "haati:engine/core"
import gfx "haati:engine/gfx"

@(private = "file")
_Persona_Custom_Value_Target :: struct {
	raw_tag: i32,
	doubled: i32,
}

@(test)
test_value_unmarshaler_direct_and_defaults :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	// 1. Direct Value_Unmarshaler registration & dispatch (zero JSON text round-trip).
	core.register_value_unmarshaler(
		typeid_of(_Persona_Custom_Value_Target),
		proc(v: json.Value, dst: any, allocator: mem.Allocator) -> json.Unmarshal_Error {
			#partial switch val in v {
			case json.Integer:
				p := cast(^_Persona_Custom_Value_Target)dst.data
				p.raw_tag = i32(val)
				p.doubled = i32(val * 2)
				return nil
			case:
				return json.Unmarshal_Data_Error.Invalid_Data
			}
		},
	)
	target: _Persona_Custom_Value_Target
	uerr := core.unmarshal_value_over_reset(json.Integer(21), &target, typeid_of(_Persona_Custom_Value_Target))
	testing.expect(t, uerr == nil, "custom Value_Unmarshaler should succeed directly on json.Value")
	testing.expect_value(t, target.raw_tag, i32(21))
	testing.expect_value(t, target.doubled, i32(42))

	// 2. Direct struct decoding via unmarshal_value_over_reset preserves reset_Light defaults for omitted fields.
	raw_json := `{"intensity": 3.5}`
	val, perr := json.parse(transmute([]u8)raw_json, allocator = context.temp_allocator)
	testing.expect(t, perr == nil, "partial Light json.parse should succeed")

	light: engine.Light
	lerr := core.unmarshal_value_over_reset(val, &light, typeid_of(engine.Light))
	testing.expect(t, lerr == nil, "unmarshal_value_over_reset on Light should succeed")
	testing.expect(t, abs(light.intensity - 3.5) < 1e-4, "explicit JSON intensity should override reset default")
	testing.expect(t, light.range > 0.1, "omitted Light.range should preserve reset_Light default")
	testing.expect(t, light.spot_angle > 1.0, "omitted Light.spot_angle should preserve reset_Light default")
}

@(test)
test_vg_clone_equal_and_destroy_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	prev_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = prev_alloc

	src: engine.Visual_Graph
	src.name = strings.clone("Wave2_CloneTest")
	src.domain = .Gameplay_Ability
	src.package_target = strings.clone("haati/hot_scripts")
	src.next_uid = 42
	append(&src.using_spaces, strings.clone("self"))
	append(&src.using_spaces, strings.clone("math"))
	append(&src.delegates, strings.clone("On_Hit"))

	enum_decl := engine.VG_Enum_Decl{
		name        = strings.clone("State"),
		has_bitset  = true,
		bitset_name = strings.clone("States"),
	}
	append(&enum_decl.variants, strings.clone("Idle"))
	append(&enum_decl.variants, strings.clone("Active"))
	append(&src.enums, enum_decl)

	struct_decl := engine.VG_Struct_Decl{
		name              = strings.clone("Payload"),
		using_parent_name = strings.clone("Base"),
	}
	append(&struct_decl.fields, engine.VG_Struct_Field{
		name        = strings.clone("damage"),
		pin_type    = .Float,
		default_f32 = 25.0,
	})
	append(&src.structs, struct_decl)

	append(&src.variables, engine.VG_Var_Decl{
		name         = strings.clone("speed"),
		pin_type     = .Float,
		default_f32  = 6.5,
		category     = strings.clone("Movement"),
		tooltip_text = strings.clone("Horizontal move speed"),
	})

	node := engine.VG_Node{
		uid        = 1,
		kind       = .Custom_Proc_Entry,
		title      = strings.clone("Step"),
		owner_proc = strings.clone("Step"),
		odin_body  = strings.clone("x := 1.0"),
		enabled    = true,
	}
	append(&node.inputs, engine.VG_Pin_Def{
		name      = strings.clone("dt"),
		pin_type  = .Float,
		pass_mode = .Copy_Value,
	})
	append(&node.outputs, engine.VG_Pin_Def{
		name              = strings.clone("out_vec"),
		pin_type          = .Vec3,
		pass_mode         = .By_Reference,
		is_addressable    = true,
		split_parent_name = strings.clone(""),
	})
	append(&src.nodes, node)
	append(&src.wires, engine.VG_Wire{from_uid = 1, from_pin = 0, to_uid = 2, to_pin = 0})

	clone := engine.vg_clone_graph(&src)
	testing.expect(t, engine.vg_graphs_equal(&src, &clone), "cloned Visual_Graph must equal source")

	delete(clone.variables[0].name)
	clone.variables[0].name = strings.clone("modified_speed")
	testing.expect(t, !engine.vg_graphs_equal(&src, &clone), "mutated Visual_Graph must no longer compare equal")

	engine.vg_destroy_graph(&src)
	engine.vg_destroy_graph(&clone)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_render_sort_commands_mat_mesh_part_dist :: proc(t: ^testing.T) {
	mat_a := [1]engine.Asset_GUID{engine.Asset_GUID{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
	mat_b := [1]engine.Asset_GUID{engine.Asset_GUID{2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
	mesh_1 := engine.Asset_GUID{10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	mesh_2 := engine.Asset_GUID{20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

	make_mesh_cmd :: proc(id: u32, mat: []engine.Asset_GUID, mesh: engine.Asset_GUID, part: i32, z: f32) -> engine.Render_Command {
		m := linalg.MATRIX4F32_IDENTITY
		m[2, 3] = z
		return engine.Render_Command{
			owner = engine.Transform_Handle(engine.Handle{index = id, generation = 1}),
			variant = engine.Draw_Mesh{
				mesh      = mesh,
				part      = part,
				materials = mat,
				model     = m,
			},
		}
	}

	// Expected opaque order after sort:
	// 1: mat_a, mesh_1, part 0, dist 2 (owner 1)
	// 2: mat_a, mesh_1, part 0, dist 10 (owner 2)
	// 3: mat_a, mesh_1, part 1, dist 1 (owner 3)
	// 4: mat_a, mesh_2, part 0, dist 1 (owner 4)
	// 5: mat_b, mesh_1, part 0, dist 1 (owner 5)
	// 6: Quad far (owner 6) -> back-to-front
	// 7: Quad near (owner 7)
	far_key := engine.Sort_Key{engine.sort_key_word(0, 0, 20.0, 0), 0, 0, 0}
	near_key := engine.Sort_Key{engine.sort_key_word(0, 0, 3.0, 1), 0, 0, 0}
	cmds := [?]engine.Render_Command{
		{key = near_key, owner = engine.Transform_Handle(engine.Handle{index = 7, generation = 1}), variant = engine.Draw_Quad{}},
		make_mesh_cmd(5, mat_b[:], mesh_1, 0, -1),
		make_mesh_cmd(2, mat_a[:], mesh_1, 0, -10),
		make_mesh_cmd(4, mat_a[:], mesh_2, 0, -1),
		{key = far_key, owner = engine.Transform_Handle(engine.Handle{index = 6, generation = 1}), variant = engine.Draw_Quad{}},
		make_mesh_cmd(3, mat_a[:], mesh_1, 1, -1),
		make_mesh_cmd(1, mat_a[:], mesh_1, 0, -2),
	}

	engine.render_sort_commands(cmds[:], {0, 0, 0})
	expected := [?]u32{1, 2, 3, 4, 5, 6, 7}
	for want, idx in expected {
		got := engine.Handle(cmds[idx].owner).index
		testing.expectf(t, got == want, "render_sort_commands[%d]: got owner %d, want %d", idx, got, want)
	}
}

@(test)
test_gfx_frustum_planes_and_csm_skip_near :: proc(t: ^testing.T) {
	view := linalg.matrix4_look_at_f32({0, 0, 0}, {0, 0, -1}, {0, 1, 0})
	proj := gfx.matrix4_ortho_z01(-10, 10, -10, 10, 10, 50)
	planes, valid := gfx.frustum_extract_planes(proj * view)
	testing.expect(t, valid, "frustum_extract_planes should produce valid normalized planes")

	testing.expect(t, gfx.frustum_sphere_visible(planes, valid, {0, 0, -25}, 1.0, skip_near = false), "inside sphere visible")
	testing.expect(t, !gfx.frustum_sphere_visible(planes, valid, {0, 0, -2}, 1.0, skip_near = false), "behind-near sphere culled when skip_near=false")
	testing.expect(t, gfx.frustum_sphere_visible(planes, valid, {0, 0, -2}, 1.0, skip_near = true), "behind-near CSM caster retained when skip_near=true")
	testing.expect(t, !gfx.frustum_sphere_visible(planes, valid, {25, 0, -25}, 1.0, skip_near = true), "out-of-side sphere culled even when skip_near=true")
	testing.expect(t, !gfx.frustum_sphere_visible(planes, valid, {0, 0, -70}, 1.0, skip_near = true), "beyond-far sphere culled even when skip_near=true")
}

@(private = "file")
_make_test_dds :: proc(
	fourcc: u32,
	dxgi: u32,
	w, h: u32,
	mips: u32,
	block_bytes: u32,
	caps2: u32 = 0,
	misc: u32 = 0,
	delta_bytes: int = 0,
	allocator := context.temp_allocator,
) -> []u8 {
	hdr_len := 128 if fourcc != u32(0x30315844) else 148
	payload := 0
	mw, mh := w, h
	for _ in 0 ..< max(mips, 1) {
		bw := max((mw + 3) / 4, 1)
		bh := max((mh + 3) / 4, 1)
		payload += int(bw * bh * block_bytes)
		mw = max(mw >> 1, 1)
		mh = max(mh >> 1, 1)
	}
	total := max(hdr_len + payload + delta_bytes, 4)
	buf := make([]u8, total, allocator)
	if len(buf) >= 128 {
		_ = endian.put_u32(buf[0:4], .Little, u32(0x20534444))  // "DDS "
		_ = endian.put_u32(buf[4:8], .Little, u32(124))         // dwSize
		flags := u32(0x1007) | (mips > 1 ? u32(0x20000) : 0)
		_ = endian.put_u32(buf[8:12], .Little, flags)
		_ = endian.put_u32(buf[12:16], .Little, h)
		_ = endian.put_u32(buf[16:20], .Little, w)
		_ = endian.put_u32(buf[28:32], .Little, mips)
		_ = endian.put_u32(buf[76:80], .Little, u32(32))        // ddspf.dwSize
		_ = endian.put_u32(buf[80:84], .Little, u32(0x4))       // DDPF_FOURCC
		_ = endian.put_u32(buf[84:88], .Little, fourcc)
		_ = endian.put_u32(buf[112:116], .Little, caps2)
	}
	if fourcc == u32(0x30315844) && len(buf) >= 148 {
		_ = endian.put_u32(buf[128:132], .Little, dxgi)
		_ = endian.put_u32(buf[132:136], .Little, u32(3))       // D3D10_RESOURCE_DIMENSION_TEXTURE2D
		_ = endian.put_u32(buf[136:140], .Little, misc)
		_ = endian.put_u32(buf[140:144], .Little, u32(1))
	}
	return buf
}

@(test)
test_gfx_dds_parse_formats_and_errors :: proc(t: ^testing.T) {
	// BC1 ("DXT1") 16x16 with 5 mips: 16x16, 8x8, 4x4, 2x2, 1x1
	bc1 := _make_test_dds(0x31545844, 0, 16, 16, 5, 8)
	i1, ok1 := gfx.dds_parse(bc1)
	testing.expect(t, ok1, "DXT1/BC1 DDS with full mip chain should parse")
	testing.expect(t, i1.format == .BC1_RGBA_UNORM && i1.block_bytes == 8 && i1.mip_count == 5, "BC1 metadata mismatch")
	testing.expect(t, i1.mips[0].offset == 128 && i1.mips[0].size == 128 && i1.mips[4].width == 1 && i1.mips[4].size == 8, "BC1 mip chain mismatch")

	// BC3 ("DXT5") 8x8, 1 mip
	bc3 := _make_test_dds(0x35545844, 0, 8, 8, 1, 16)
	i3, ok3 := gfx.dds_parse(bc3)
	testing.expect(t, ok3 && i3.format == .BC3_RGBA_UNORM && i3.block_bytes == 16 && i3.mips[0].size == 64, "DXT5/BC3 parse mismatch")

	// BC5 ("BC5U") 4x4, 1 mip
	bc5 := _make_test_dds(0x55354342, 0, 4, 4, 1, 16)
	i5, ok5 := gfx.dds_parse(bc5)
	testing.expect(t, ok5 && i5.format == .BC5_RG_UNORM && i5.block_bytes == 16 && i5.mips[0].size == 16, "BC5U parse mismatch")

	// DX10 BC7 SRGB (dxgi=99) 8x8, 2 mips (starts at offset 148)
	bc7 := _make_test_dds(0x30315844, 99, 8, 8, 2, 16)
	i7, ok7 := gfx.dds_parse(bc7)
	testing.expect(t, ok7 && i7.format == .BC7_RGBA_UNORM_SRGB && i7.mip_count == 2 && i7.mips[0].offset == 148, "DX10 BC7_SRGB parse mismatch")

	// Rejection cases: bad magic, wrong dwSize, truncated payload, legacy cubemap, DX10 cubemap
	bad_magic := _make_test_dds(0x31545844, 0, 4, 4, 1, 8)
	bad_magic[0] = 'X'
	_, obm := gfx.dds_parse(bad_magic)
	testing.expect(t, !obm, "bad DDS magic must be rejected")

	bad_sz := _make_test_dds(0x31545844, 0, 4, 4, 1, 8)
	bad_sz[4] = 99
	_, osz := gfx.dds_parse(bad_sz)
	testing.expect(t, !osz, "invalid DDS dwSize must be rejected")

	trunc := _make_test_dds(0x35545844, 0, 8, 8, 1, 16, delta_bytes = -1)
	_, otr := gfx.dds_parse(trunc)
	testing.expect(t, !otr, "truncated mip payload must be rejected")

	_, ocube1 := gfx.dds_parse(_make_test_dds(0x31545844, 0, 4, 4, 1, 8, caps2 = 0x200))
	testing.expect(t, !ocube1, "legacy cubemap DDS must be rejected")

	_, ocube2 := gfx.dds_parse(_make_test_dds(0x30315844, 98, 4, 4, 1, 16, misc = 0x4))
	testing.expect(t, !ocube2, "DX10 cubemap DDS must be rejected")
}

@(test)
test_navmesh_csr_heap_ssfa_and_dirty_notify :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	prev_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = prev_alloc

	// 1. Straight 4-quad (8-tri) corridor along +X: x in [0, 8], z in [-1, 1]
	pos := make([dynamic][3]f32, 0, 10, context.temp_allocator)
	idx := make([dynamic]u32, 0, 24, context.temp_allocator)
	for qi in 0 ..= 4 {
		x := f32(qi) * 2.0
		append(&pos, [3]f32{x, 0, -1})
		append(&pos, [3]f32{x, 0, 1})
	}
	for q in 0 ..< 4 {
		b := u32(q * 2)
		append(&idx, b + 0, b + 1, b + 3)
		append(&idx, b + 0, b + 3, b + 2)
	}

	nm, baked := engine.navmesh_bake_triangles(pos[:], idx[:])
	testing.expect(t, baked, "straight corridor navmesh should bake")
	testing.expect(t, nm.grid_w > 0 && nm.grid_h > 0 && len(nm.grid_offsets) == int(nm.grid_w * nm.grid_h) + 1, "CSR spatial grid should be built")

	pi_in, cp_in, ok_in := engine.navmesh_find_nearest_point(&nm, {3.0, 0, 0.2})
	testing.expect(t, ok_in && pi_in >= 0 && linalg.distance(cp_in, [3]f32{3.0, 0, 0.2}) < 1e-3, "in-cell nearest point lookup failed")

	pi_far, cp_far, ok_far := engine.navmesh_find_nearest_point(&nm, {12.0, 0, 3.0})
	testing.expect(t, ok_far && pi_far >= 0 && linalg.distance(cp_far, [3]f32{8.0, 0, 1.0}) < 1e-3, "ring-fallback nearest point should snap to corridor end")

	straight, straight_ok := engine.navmesh_find_path(&nm, {0.5, 0, 0}, {7.5, 0, 0}, context.temp_allocator, agent_radius = 0.0)
	testing.expect(t, straight_ok && len(straight) == 2, "SSFA funnel should collapse straight 8-triangle corridor to 2 waypoints")
	engine.navmesh_destroy(&nm)

	// 2. L-shaped corridor turning at inner corner (2, 0, 2) to verify agent_radius corner inset
	l_pos := [?] [3]f32{
		{0, 0, 0}, {0, 0, 2}, {2, 0, 0}, {2, 0, 2}, {4, 0, 0}, {4, 0, 2}, // horizontal leg
		{2, 0, 4}, {4, 0, 4}, {2, 0, 6}, {4, 0, 6},                       // vertical leg
	}
	l_idx := [?]u32{
		0, 1, 3,   0, 3, 2,
		2, 3, 5,   2, 5, 4,
		3, 6, 7,   3, 7, 5,
		6, 8, 9,   6, 9, 7,
	}
	nm_l, baked_l := engine.navmesh_bake_triangles(l_pos[:], l_idx[:])
	testing.expect(t, baked_l, "L-corridor navmesh should bake")

	path_r0, ok_r0 := engine.navmesh_find_path(&nm_l, {0.5, 0, 1.5}, {2.5, 0, 5.5}, context.temp_allocator, agent_radius = 0.0)
	path_r4, ok_r4 := engine.navmesh_find_path(&nm_l, {0.5, 0, 1.5}, {2.5, 0, 5.5}, context.temp_allocator, agent_radius = 0.4)
	testing.expect(t, ok_r0 && len(path_r0) >= 3 && ok_r4 && len(path_r4) >= 3, "L-corridor path should bend around corner")
	if len(path_r0) >= 3 && len(path_r4) >= 3 {
		inner_corner := [3]f32{2, 0, 2}
		d0 := linalg.distance(path_r0[1], inner_corner)
		d4 := linalg.distance(path_r4[1], inner_corner)
		testing.expectf(t, d0 < 0.05 && d4 > d0 + 0.25, "agent_radius=0.4 should inset corner portal outward from inner corner (d0=%.3f, d4=%.3f)", d0, d4)
	}
	engine.navmesh_destroy(&nm_l)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)

	// 3. NavMesh dirty AABB accumulation & consume reset
	_, _, _ = engine.navmesh_consume_dirty()
	engine.navmesh_notify_geometry_changed({-2, 0, -1}, {1, 2, 3})
	engine.navmesh_notify_geometry_changed({0, -1, 2}, {5, 4, 6})
	dirty, bmin, bmax := engine.navmesh_consume_dirty()
	testing.expect(t, dirty, "navmesh_consume_dirty should report pending geometry change")
	testing.expect(t, linalg.distance(bmin, [3]f32{-2, -1, -1}) < 1e-4 && linalg.distance(bmax, [3]f32{5, 4, 6}) < 1e-4, "dirty bounds must union all queued volumes")
	dirty2, _, _ := engine.navmesh_consume_dirty()
	testing.expect(t, !dirty2, "second navmesh_consume_dirty should be clear")
}

@(test)
test_file_explorer_component_scaffold_deterministic :: proc(t: ^testing.T) {
	a := file_exp.format_new_component_scaffold("game", "Hero", context.temp_allocator)
	b := file_exp.format_new_component_scaffold("game", "Hero", context.temp_allocator)
	testing.expect(t, a == b && len(a) > 0, "format_new_component_scaffold must be deterministic")
	testing.expect(t, strings.contains(a, "package game") && strings.contains(a, `@(component={menu="Custom/Hero"})`) && strings.contains(a, "reset_Hero :: proc(c: ^Hero)"), "scaffold missing expected declarations")
}
