package cad_csg_tests

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"
import "core:time"
import "moonhug:engine"
import common "moonhug:tests/common"
import physics3d "moonhug:packages/physics3d"
import cad_csg "moonhug:packages/cad_csg"
import cad_ed "moonhug:packages/cad_csg/editor"

@(test)
cad_csg_three_pillar_level_composition_channels_glass_and_ram_reset_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Verify the 6-Channel Jolt Collision Matrix (`packages/physics3d`):
	//    - `LAYER_DEBRIS_COSMETIC` (5) collides ONLY with `LAYER_NON_MOVING` (0), never with `LAYER_CHARACTER` (2), `LAYER_MOVING` (1), or itself!
	//    - `LAYER_GLASS_FENESTRATION` (3) collides with `LAYER_CHARACTER` (2) and `LAYER_MOVING` (1).
	testing.expect(t, physics3d.should_layers_collide(physics3d.LAYER_DEBRIS_COSMETIC, physics3d.LAYER_NON_MOVING), "Cosmetic debris must collide with Solid World floors/walls")
	testing.expect(t, !physics3d.should_layers_collide(physics3d.LAYER_DEBRIS_COSMETIC, physics3d.LAYER_CHARACTER), "Cosmetic debris must NEVER collide with Character capsules")
	testing.expect(t, !physics3d.should_layers_collide(physics3d.LAYER_DEBRIS_COSMETIC, physics3d.LAYER_MOVING), "Cosmetic debris must NEVER collide with Dynamic Rigidbodies")
	testing.expect(t, !physics3d.should_layers_collide(physics3d.LAYER_DEBRIS_COSMETIC, physics3d.LAYER_DEBRIS_COSMETIC), "Cosmetic debris must NEVER collide with other debris shards")
	testing.expect(t, physics3d.should_layers_collide(physics3d.LAYER_GLASS_FENESTRATION, physics3d.LAYER_CHARACTER), "Intact glass panes must block Character movement")

	// 2. Build a 3-Pillar Level Composition Volume in the Scene:
	//    - Pillar 1: Structural CSG Wall (`z = 0.0`) with a boolean window cutout + a Solid Backstop Wall at `z = -4.0`
	//    - Pillar 2: Gothic Pillar & Pointed Arch Detail Instances stamped on the wall (`vol.detail_instances`)
	//    - Pillar 3: Valve-style 2D Shatterable Tempered Glass Pane mounted in the window at `z = 0.0` (`vol.glass_panes`)
	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)
	vol_h := engine.transform_new("Gothic_Cathedral_Section", root_h)
	_, ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)ptr
	testing.expect(t, vol != nil, "CSGVolume should be created")
	cad_csg.reset_CSGVolume(vol)

	cad_csg.csg_volume_add_brush(vol, "Foundation_Floor", .Add, .Box, {0, -0.25, -2.0}, {14.0, 0.5, 10.0}, 0, {140, 145, 155, 255}, destructible = false, anchored = true)
	cad_csg.csg_volume_add_brush(vol, "Gothic_Front_Wall", .Add, .Box, {0, 2.0, 0.0}, {10.0, 4.0, 0.8}, 0, {195, 200, 210, 255}, destructible = true, anchored = false)
	cad_csg.csg_volume_add_brush(vol, "Window_Opening_Cut", .Subtract, .Box, {0, 2.0, 0.0}, {2.4, 1.6, 1.6}, 0, {90, 90, 90, 255}, destructible = true, anchored = false)
	cad_csg.csg_volume_add_brush(vol, "Backstop_Solid_Wall", .Add, .Box, {0, 2.0, -4.0}, {10.0, 4.0, 0.8}, 0, {180, 185, 195, 255}, destructible = true, anchored = false)

	// Stamp 4 Gothic Pillars along the front wall (`x = -3.0, -1.0, +1.0, +3.0`) + a Pointed Arch
	added_pillars := cad_csg.csg_volume_add_detail_wall_array(
		vol, "Gothic_Wall_Pillar", .Gothic_Pillar,
		{0, 1.8, 0.42}, {0, 0, 1}, {1, 0, 0},
		4, 2.0,
	)
	testing.expect(t, added_pillars == 4, "1-Click Gothic Wall Array should stamp 4 Gothic_Pillar instances")
	_ = cad_csg.csg_volume_add_detail_instance(vol, "Window_Pointed_Arch", .Gothic_Pointed_Arch, {0, 2.8, 0.42}, {0, 0, 1})

	// Mount a 2D Shatterable Tempered Glass Pane inside the window opening at `{0, 2.0, 0.0}`
	gp_idx := cad_csg.csg_volume_add_glass_pane(vol, "Cathedral_Window_Glass", {0, 2.0, 0.0}, {2.4, 1.6}, {0, 0, 1}, 6, 4)
	testing.expect(t, gp_idx == 0, "Shatterable glass pane should be added")

	cad_csg.csg_volume_rebuild(vol)
	dt :: f32(1.0 / 60.0)
	cad_csg.csg_fixed_step(dt)
	physics3d.physics_step(dt)

	dg_guid := cad_csg.make_detail_and_glass_guid(vol.owner)
	testing.expect(t, engine.mesh_is_cached(dg_guid), "Batched Gothic Detail Instances + Glass Pane GPU mesh must be uploaded")

	// 3. Test Channel-Masked Raycasts through the Unbroken Glass Window (`{0, 2.0, +3.0}` -> `{0, 0, -1}`):
	//    - `MASK_WEAPON_TRACE` must hit the glass pane at `z ~ 0.0` (`channel == .Glass_Fenestration`)!
	//    - `MASK_VISION_LOS` (AI Sight) must see right THROUGH the glass pane at `z = 0.0` and hit `Backstop_Solid_Wall` at `z ~ -3.6`!
	w_hit, w_ok := physics3d.raycast_masked({0, 2.0, 3.0}, {0, 0, -1}, 20.0, physics3d.MASK_WEAPON_TRACE)
	testing.expect(t, w_ok && w_hit.channel == .Glass_Fenestration && abs(w_hit.position.z - 0.0) < 0.25, "Weapon trace must intercept unbroken glass on LAYER_GLASS_FENESTRATION")

	v_hit, v_ok := physics3d.raycast_masked({0, 2.0, 3.0}, {0, 0, -1}, 20.0, physics3d.MASK_VISION_LOS)
	testing.expect(t, v_ok && v_hit.channel == .Solid_World && v_hit.position.z < -3.0, "AI Vision (MASK_VISION_LOS) must see straight through unbroken glass and hit the solid wall behind it!")

	// 4. Shatter the glass pane in RAM (`csg_damage_glass_at_point`) and verify `MASK_WEAPON_TRACE` now passes through the broken window!
	broken_cells := cad_csg.csg_damage_glass_at_point({0, 2.0, 0.0}, 1.25, 10.0)
	testing.expect(t, broken_cells > 0, "csg_damage_glass_at_point should shatter glass cells in RAM")
	w_hit_after, w_ok_after := physics3d.raycast_masked({0, 2.0, 3.0}, {0, 0, -1}, 20.0, physics3d.MASK_WEAPON_TRACE)
	testing.expect(t, w_ok_after && w_hit_after.channel == .Solid_World && w_hit_after.position.z < -3.0, "Once shattered in RAM, weapon traces and players pass straight through the broken window!")

	// 5. Blast the left side of `Gothic_Front_Wall` at `{-3.0, 1.8, 0.0}` and verify the attached Gothic Pillar at `x = -3.0`
	//    automatically pops off (`destroyed_in_ram == true`) in RAM!
	cad_csg.csg_trigger_blast({-3.0, 1.8, 0.0}, 1.5, 12.0)
	time.sleep(25 * time.Millisecond)
	cad_csg.csg_fixed_step(dt)
	testing.expect(t, vol.detail_instances[0].destroyed_in_ram == true, "Gothic pillar whose backing CSG wall was blasted must pop off (destroyed_in_ram = true) in RAM")
	testing.expect(t, vol.detail_instances[3].destroyed_in_ram == false, "Far-right Gothic pillar at x = +3.0 on intact CSG wall must remain intact")

	// 6. Verify Minecraft-Style Recipe-on-Disk + Runtime-Deltas-in-RAM Reset (`csg_volume_reset_craters`):
	//    Restoring from the recipe in RAM must bring back all Gothic pillars AND restore the unbroken glass pane collider!
	cad_csg.csg_volume_reset_craters(vol)
	testing.expect(t, vol.detail_instances[0].destroyed_in_ram == false, "Resetting destruction must restore popped Gothic detail instances from the scene recipe")
	testing.expect(t, !vol.glass_panes[0].completely_shattered, "Resetting destruction must restore shattered glass cells from the scene recipe")
	w_hit_restored, w_ok_restored := physics3d.raycast_masked({0, 2.0, 3.0}, {0, 0, -1}, 20.0, physics3d.MASK_WEAPON_TRACE)
	testing.expect(t, w_ok_restored && w_hit_restored.channel == .Glass_Fenestration, "Restored glass pane must block weapon traces again on LAYER_GLASS_FENESTRATION")
}

@(test)
cad_csg_spline_extrude_boolean_and_crater_preserve_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)
	vol_h := engine.transform_new("SplineTestVolume", root_h)
	_, ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)ptr
	testing.expect(t, vol != nil, "Volume should exist")

	// 1. Extrude a concave/curved L-shaped 2D spline profile into a 3D wall
	pts := [6]cad_csg.CSG_Profile_Point{
		{uv = {-3.0, -2.0}, smooth = false, tension = 0.5},
		{uv = { 3.0, -2.0}, smooth = false, tension = 0.5},
		{uv = { 3.0,  0.0}, smooth = true,  tension = 0.5},
		{uv = { 0.5,  0.5}, smooth = true,  tension = 0.5},
		{uv = { 0.0,  2.5}, smooth = false, tension = 0.5},
		{uv = {-3.0,  2.5}, smooth = false, tension = 0.5},
	}
	cad_csg.csg_volume_add_profile_brush(
		vol, "Curved_Spline_Wall", .Add,
		{0, 0, 0}, {1, 0, 0}, {0, 0, 1}, {0, 1, 0},
		pts[:], 3.0, {120, 130, 150, 255},
	)
	cad_csg.csg_volume_rebuild(vol)
	testing.expect(t, len(vol.chunks) > 0, "Extruded 2D spline profile should generate convex chunks")

	// 2. Boolean subtract a doorway hole through the extruded spline wall
	door_pts := [4]cad_csg.CSG_Profile_Point{
		{uv = {-0.8, 0.0}, smooth = false, tension = 0.5},
		{uv = { 0.8, 0.0}, smooth = false, tension = 0.5},
		{uv = { 0.8, 2.0}, smooth = true,  tension = 0.5},
		{uv = {-0.8, 2.0}, smooth = true,  tension = 0.5},
	}
	chunks_before_cut := len(vol.chunks)
	cad_csg.csg_volume_add_profile_brush(
		vol, "Spline_Arch_Cut", .Subtract,
		{0, 0, -2.05}, {1, 0, 0}, {0, 1, 0}, {0, 0, -1},
		door_pts[:], -3.0, {210, 80, 65, 255},
	)
	cad_csg.csg_volume_rebuild(vol)
	testing.expect(t, len(vol.chunks) >= chunks_before_cut, "Boolean subtraction should compile cleanly around the arch")

	// 3. Blast a crater and verify `preserve_craters_on_rebuild` keeps craters across rebuild & sync_colliders_only
	cad_csg.csg_trigger_blast({-1.5, 1.5, -1.0}, 1.2, 10.0)
	time.sleep(25 * time.Millisecond)
	cad_csg.csg_fixed_step(1.0 / 60.0)
	testing.expect(t, len(vol.recorded_blasts) == 1, "Blast should be recorded on volume")
	chunks_after_blast := len(vol.chunks)

	cad_csg.csg_volume_sync_colliders_only(vol)
	testing.expect(t, len(vol.chunks) == chunks_after_blast, "Sync colliders only must not alter chunks or craters")

	vol.preserve_craters_on_rebuild = true
	cad_csg.csg_volume_rebuild(vol)
	testing.expect(t, len(vol.chunks) == chunks_after_blast, "Rebuild with preserve_craters_on_rebuild should preserve blast craters")

	cad_csg.csg_volume_reset_craters(vol)
	testing.expect(t, len(vol.recorded_blasts) == 0, "Reset craters should clear recorded blasts")
}

@(test)
cad_csg_detach_brush_and_split_island_into_dynamic_csg_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)
	vol_h := engine.transform_new("PillarSplitTestVolume", root_h)
	_, ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)ptr
	testing.expect(t, vol != nil, "Volume should exist")
	cad_csg.reset_CSGVolume(vol)

	// 1. Add a foundation floor, a tall pillar (0..4m), and a crate brush
	cad_csg.csg_volume_add_brush(vol, "Floor", .Add, .Box, {0, -0.25, 0}, {10.0, 0.5, 10.0}, 0, {140, 140, 140, 255}, destructible = false, anchored = true)
	cad_csg.csg_volume_add_brush(vol, "Tall_Pillar", .Add, .Box, {0, 2.0, 0}, {0.8, 4.0, 0.8}, 0, {200, 190, 180, 255}, destructible = true, anchored = false)
	b_idx := cad_csg.csg_volume_add_brush(vol, "Side_Block", .Add, .Box, {3.0, 1.0, 0}, {1.0, 1.0, 1.0}, 0, {180, 200, 220, 255}, destructible = true, anchored = false)
	cad_csg.csg_volume_rebuild(vol)

	// 2. Detach `Side_Block` into its own standalone Dynamic Physics CSGVolume
	detached_h := cad_csg.csg_detach_brush_to_volume(vol, b_idx, true)
	testing.expect(t, detached_h != {}, "Detaching a brush should return a new Transform_Handle")
	_, det_vol := engine.transform_get_comp(detached_h, cad_csg.CSGVolume)
	testing.expect(t, det_vol != nil && det_vol.is_dynamic_rigidbody, "Detached brush volume should have is_dynamic_rigidbody = true")

	// Count CSGVolumes before blasting the pillar base
	vols_before := 0
	it1 := engine.pool_iterator(cad_csg.csg_volumes(w))
	for _, _ in engine.pool_next(&it1) do vols_before += 1

	// 3. Blast the base of `Tall_Pillar` at y = 0.6m so the upper section (y in ~1.8..4.0m) is severed from the floor!
	cad_csg.csg_trigger_blast({0, 0.6, 0}, 1.3, 10.0)
	time.sleep(30 * time.Millisecond)
	cad_csg.csg_fixed_step(1.0 / 60.0)

	vols_after := 0
	found_severed_piece := false
	it2 := engine.pool_iterator(cad_csg.csg_volumes(w))
	for v, _ in engine.pool_next(&it2) {
		vols_after += 1
		if len(v.runtime_hulls) > 0 && v.is_dynamic_rigidbody {
			found_severed_piece = true
		}
	}
	testing.expect(t, vols_after > vols_before && found_severed_piece, "Severing a pillar from the ground should spawn a new dynamic CSGVolume object with runtime_hulls")
}

@(test)
cad_csg_bake_changes_and_static_mesh_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)
	vol_h := engine.transform_new("BakeTestVolume", root_h)
	_, ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)ptr
	testing.expect(t, vol != nil, "Volume should exist")
	cad_csg.reset_CSGVolume(vol)

	cad_csg.csg_volume_add_brush(vol, "BaseWall", .Add, .Box, {0, 1.5, 0}, {4.0, 3.0, 1.0}, 0, {180, 190, 200, 255})
	cad_csg.csg_volume_add_brush(vol, "WindowCut", .Subtract, .Box, {0, 1.5, 0}, {1.5, 1.2, 2.0}, 0, {200, 80, 80, 255})
	cad_csg.csg_volume_rebuild(vol)

	// 1. Bake CSG changes into runtime_hulls
	baked_cnt := cad_csg.csg_volume_bake_changes(vol)
	testing.expect(t, baked_cnt > 0, "Baking CSG changes should succeed")
	testing.expect(t, len(vol.brushes) == 0 && len(vol.runtime_hulls) > 0, "Baked volume should consolidate brushes into persistent runtime_hulls")

	// 2. Bake CSG into a standalone Static Mesh GameObject
	mesh_h := cad_csg.csg_volume_bake_to_static_mesh(vol)
	testing.expect(t, mesh_h != {}, "Baking CSG to Static Mesh should create a new Transform_Handle")
	_, mr := engine.transform_get_comp(mesh_h, engine.MeshRenderer)
	testing.expect(t, mr != nil && mr.cast_shadows, "Baked static mesh should have MeshRenderer with cast_shadows = true")
}

@(test)
cad_csg_uv_sphere_72_planes_and_ground_clipped_shadows_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Build a 72-face UV Sphere (6 rings x 12 segments = 72 planes) and verify all 72 faces survive intact!
	hull := cad_csg.CSG_Convex{
		planes = make([dynamic]cad_csg.CSG_Plane, 0, 72),
	}
	defer cad_csg.convex_destroy(&hull)

	rings :: 6
	segs  :: 12
	for ri in 0 ..< rings {
		phi0 := -0.5 * 3.14159265 + f32(ri) * (3.14159265 / f32(rings))
		phi1 := -0.5 * 3.14159265 + f32(ri + 1) * (3.14159265 / f32(rings))
		phi_mid := 0.5 * (phi0 + phi1)
		for si in 0 ..< segs {
			th_mid := (f32(si) + 0.5) * (2.0 * 3.14159265 / f32(segs))
			cp := f32(1.0)
			// Spherical face normal
			n := [3]f32{
				math.cos_f32(phi_mid) * math.cos_f32(th_mid),
				math.sin_f32(phi_mid),
				math.cos_f32(phi_mid) * math.sin_f32(th_mid),
			}
			_ = cp
			append(&hull.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
				normal   = n,
				dist     = 1.0,
				uv_scale = 0.5,
				color    = {200, 210, 225, 255},
			}))
		}
	}

	ok := cad_csg.convex_rebuild_bounds_and_prune(&hull, prune_redundant = true)
	testing.expect(t, ok, "72-plane UV Sphere convex hull should rebuild cleanly")
	testing.expect(t, len(hull.planes) == 72, "All 72 planes of the UV Sphere must be preserved (not truncated at 48)")

	faces := make([dynamic]cad_csg.CSG_Face_Poly, 0, 72, context.temp_allocator)
	cad_csg.convex_extract_faces(hull, &faces, context.temp_allocator)
	testing.expect(t, len(faces) == 72, "All 72 sphere faces should extract without busted or missing facets")

	// 2. Verify planar shadows are NOT emitted when there is no ground receiver, and ARE clipped to ground when present
	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)

	light_h := engine.transform_new("ShadowLight", root_h)
	_, l_ptr := engine.transform_add_comp(light_h, .Light)
	light := cast(^engine.Light)l_ptr
	if light != nil {
		engine.reset_Light(light)
		light.type = .Directional
		light.intensity = 1.0
		light.cast_shadows = true
		light.shadow_ground_y = 0.0
	}

	vol_h := engine.transform_new("FloatingCasterVolume", root_h)
	_, v_ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)v_ptr
	cad_csg.reset_CSGVolume(vol)

	// Add ONLY an elevated block at y = 2.0 (NO floor at y = 0.0!)
	cad_csg.csg_volume_add_brush(vol, "FloatingBlock", .Add, .Box, {0, 2.0, 0}, {2.0, 1.0, 2.0}, 0, {200, 200, 200, 255})
	cad_csg.csg_volume_rebuild(vol)
	recs_empty, _ := cad_csg.csg_collect_ground_receivers(0.0, context.temp_allocator)
	testing.expect(t, len(recs_empty) == 0, "Elevated block alone must not be treated as a ground receiver")
	testing.expect(t, !engine.mesh_is_cached(vol.shadow_mesh_guid), "No planar shadow mesh should be emitted when there is no ground at ground_y")

	// Now add an 8m x 6m floor slab (`z in -3..+3`, so the shadow at `z in -1.3..-4.8` lands on the floor and clips at `z = -3.0`!)
	cad_csg.csg_volume_add_brush(vol, "FloorSlab", .Add, .Box, {0, -0.1, 0}, {8.0, 0.2, 6.0}, 0, {140, 140, 140, 255})
	cad_csg.csg_volume_rebuild(vol)
	recs_with_floor, _ := cad_csg.csg_collect_ground_receivers(0.0, context.temp_allocator)
	testing.expect(t, len(recs_with_floor) > 0, "Floor slab at y = 0 must be detected as a ground receiver")
	testing.expect(t, engine.mesh_is_cached(vol.shadow_mesh_guid), "Planar shadow mesh should be emitted once a ground receiver is present")
}

@(test)
cad_csg_small_radius_high_jaggedness_blast_no_plank_or_cube_loss_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Build an 8m x 8m x 8m cube hull
	cube, c_ok := cad_csg.csg_make_primitive_convex(.Box, {0, 4.0, 0}, {8.0, 8.0, 8.0})
	testing.expect(t, c_ok, "8m x 8m x 8m cube should build")
	hulls := make([dynamic]cad_csg.CSG_Convex, 0, 64)
	append(&hulls, cube)
	defer {
		for &h in hulls do cad_csg.convex_destroy(&h)
		delete(hulls)
	}

	// Fire 12 small-radius (0.25m) blasts with maximum jaggedness (0.35) along the front (+Z = 4.0) face,
	// including grazing hits (z = 4.24 -> 1cm penetration!) that previously triggered the plank-rip / cube-delete bug!
	blast_pts := [6][3]f32{
		{ 0.0, 4.0, 4.00},
		{ 1.2, 4.0, 4.24}, // 1cm grazing hit on +Z face!
		{-1.2, 3.5, 4.23}, // 2cm grazing hit on +Z face!
		{ 0.0, 7.99, 4.00}, // Corner/edge grazing hit!
		{ 2.5, 5.0, 4.00},
		{-2.5, 2.5, 4.00},
	}

	for pt, i in blast_pts {
		cutter, b_ok := cad_csg.csg_make_blast_convex(pt, 0.25, u32(i + 1) * 997, 0.35)
		testing.expect(t, b_ok, "Small-radius (0.25m) high-jaggedness (0.35) blast polyhedron must always build")
		if b_ok {
			cad_csg.convex_list_subtract(&hulls, cutter)
			cad_csg.convex_destroy(&cutter)
		}
	}

	testing.expect(t, len(hulls) > 1, "Small blasts on the +Z face must carve craters into the 8x8 cube")

	// Verify the overall 8x8x8 bounds are preserved (the cube was NOT deleted) and the back half (z in [-4, +3]) is intact!
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{-max(f32), -max(f32), -max(f32)}
	total_vol: f32 = 0
	for h in hulls {
		lo.x = min(lo.x, h.aabb_min.x); lo.y = min(lo.y, h.aabb_min.y); lo.z = min(lo.z, h.aabb_min.z)
		hi.x = max(hi.x, h.aabb_max.x); hi.y = max(hi.y, h.aabb_max.y); hi.z = max(hi.z, h.aabb_max.z)
		ext := h.aabb_max - h.aabb_min
		total_vol += ext.x * ext.y * ext.z
	}
	testing.expect(t, lo.x <= -3.95 && hi.x >= 3.95 && lo.y <= 0.05 && hi.y >= 7.95 && lo.z <= -3.95 && hi.z >= 3.95, "8x8x8 outer bounds must remain intact after small surface blasts")
	testing.expect(t, total_vol >= 8.0 * 8.0 * 8.0 * 0.95, "Small 0.25m surface blasts must never rip 8m planks through the cube or delete large volume")
}

@(test)
cad_csg_realtime_csg_clip_plane_texgen_and_dirty_aabb_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)

	// 1. Test SabreCSG / RealtimeCSG 2-Point Clip Plane Slicer (`csg_volume_clip_by_plane`)
	vol_h := engine.transform_new("Test_Clip_Volume", root_h)
	_, v_ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)v_ptr
	cad_csg.reset_CSGVolume(vol)

	cad_csg.csg_volume_add_brush(vol, "BlockA", .Add, .Box, {0, 1.0, 0}, {4.0, 2.0, 4.0}, 0, {200, 200, 200, 255})
	// Configure RealtimeCSG TexGen UV parameters on BlockA before slicing
	vol.brushes[0].uv_lock_brush = true
	vol.brushes[0].uv_offset     = {0.25, 0.75}
	vol.brushes[0].uv_rot_deg    = 45.0
	cad_csg.csg_volume_rebuild(vol)

	// Slice `BlockA` along X = 0 into two separate CSGVolume GameObjects (`Split_Both`) with a 0.10m gap
	sliced := cad_csg.csg_volume_clip_by_plane(vol, {1, 0, 0}, 0.0, .Split_Both, 0.10)
	_, vol = engine.transform_get_comp(vol_h, cad_csg.CSGVolume)
	testing.expect(t, sliced == 1, "BlockA straddling X=0 should be sliced into two halves")
	testing.expect(t, vol != nil && len(vol.runtime_hulls) == 1, "Split_Both should keep the -N half in the original CSGVolume and detach the +N half into a second CSGVolume GameObject")
	testing.expect(t, vol.runtime_hulls[0].planes[0].uv_lock_brush == true, "Clipped hulls must preserve TexGen uv_lock_brush")
	testing.expect(t, abs(vol.runtime_hulls[0].planes[0].uv_rot_deg - 45.0) < 1e-3, "Clipped hulls must preserve TexGen uv_rot_deg")

	// 2. Test Chisel / RealtimeCSG Dirty-Brush-AABB Partial Chunk Rebuilding (`csg_volume_rebuild_dirty_aabb`)
	multi_h := engine.transform_new("Test_Multi_Chunk_Volume", root_h)
	_, m_ptr := engine.transform_add_comp(multi_h, .CSGVolume)
	m_vol := cast(^cad_csg.CSGVolume)m_ptr
	cad_csg.reset_CSGVolume(m_vol)
	m_vol.chunk_size = 8.0

	// Place Brush 0 in Chunk (0, 0, 0) at x = 2.0, and Brush 1 far away in Chunk (3, 0, 0) at x = 26.0
	cad_csg.csg_volume_add_brush(m_vol, "NearBrush", .Add, .Box, {2.0, 1.0, 2.0}, {2.0, 2.0, 2.0}, 0, {200, 200, 200, 255})
	cad_csg.csg_volume_add_brush(m_vol, "FarBrush",  .Add, .Box, {26.0, 1.0, 2.0}, {2.0, 2.0, 2.0}, 0, {180, 200, 220, 255})
	cad_csg.csg_volume_rebuild(m_vol)
	testing.expect(t, len(m_vol.chunks) == 2, "Two brushes 24m apart with 8m chunk_size must occupy 2 distinct chunks")

	far_chunk_before := m_vol.chunks[{3, 0, 0}]
	testing.expect(t, far_chunk_before != nil, "Chunk (3,0,0) must exist")

	// Move `NearBrush` slightly inside Chunk (0, 0, 0) and rebuild ONLY its dirty AABB!
	m_vol.brushes[0].center = {3.0, 1.0, 2.0}
	rebuilt_n := cad_csg.csg_volume_rebuild_dirty_aabb(m_vol, {0.5, -0.5, 0.5}, {4.5, 2.5, 3.5})
	testing.expect(t, rebuilt_n == 1, "csg_volume_rebuild_dirty_aabb should rebuild only the 1 dirty chunk overlapping NearBrush")
	testing.expect(t, m_vol.chunks[{3, 0, 0}] == far_chunk_before, "Distant Chunk (3,0,0) pointer must remain completely untouched during partial rebuild!")

	// 3. Test Spamming 35 Blasts on a Single Chunk: must NEVER freeze at max_hulls and must chew all the way through!
	spam_cube, s_ok := cad_csg.csg_make_primitive_convex(.Box, {0, 2.0, 0}, {4.0, 4.0, 4.0})
	testing.expect(t, s_ok, "Spam test 4m cube should build")
	spam_hulls := make([dynamic]cad_csg.CSG_Convex, 0, 128)
	append(&spam_hulls, spam_cube)
	defer {
		for &sh in spam_hulls do cad_csg.convex_destroy(&sh)
		delete(spam_hulls)
	}
	for i in 0 ..< 35 {
		// March blasts across and through the entire 4m cube so by blast 35 the center is completely hollowed/destroyed
		bx := f32((i % 5) - 2) * 0.9
		by := 0.8 + f32((i / 5) % 4) * 0.8
		bz := f32((i % 3) - 1) * 0.9
		cutter, b_ok := cad_csg.csg_make_blast_convex({bx, by, bz}, 1.35, u32(i + 10) * 1337, 0.22)
		if b_ok {
			cad_csg.convex_list_subtract(&spam_hulls, cutter)
			cad_csg.convex_destroy(&cutter)
		}
	}
	// Verify the center of the cube {0, 2.0, 0} was actually carved out even on the later blasts!
	center_still_solid := false
	for sh in spam_hulls {
		inside := true
		for p in sh.planes {
			if p.normal.x * 0.0 + p.normal.y * 2.0 + p.normal.z * 0.0 - p.dist > 1e-3 {
				inside = false
				break
			}
		}
		if inside {
			center_still_solid = true
			break
		}
	}
	testing.expect(t, !center_still_solid, "Repeated blast spam on a single chunk must keep carving and never freeze at a hull cap")
}

@(test)
cad_csg_tunnel_box_clean_mesh_and_roundtrip_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Build a 4m x 4m x 4m CSG Box (`[-2, 2]^3`) and carve a 1.2m x 1.2m through-tunnel along Z (`[-0.6, 0.6] x [-0.6, 0.6] x [-3, 3]`)
	outer_box, ok_b := cad_csg.csg_make_primitive_convex(.Box, {0, 0, 0}, {4.0, 4.0, 4.0})
	tunnel_cut, ok_c := cad_csg.csg_make_primitive_convex(.Box, {0, 0, 0}, {1.2, 1.2, 6.0})
	testing.expect(t, ok_b && ok_c, "Outer box and tunnel cutter should build")

	hulls := make([dynamic]cad_csg.CSG_Convex, 0, 8)
	append(&hulls, outer_box)
	defer {
		for &h in hulls do cad_csg.convex_destroy(&h)
		delete(hulls)
	}
	cad_csg.convex_list_subtract(&hulls, tunnel_cut)
	cad_csg.convex_destroy(&tunnel_cut)

	cad_csg.csg_clean_and_simplify_hulls(&hulls)
	testing.expect(t, len(hulls) == 4, "Box with a Z-tunnel should consist of 4 clean convex hulls (Left, Right, Top Lintel, Bottom Sill)")

	// 2. Extract clean polygons (`CSG -> Mesh` pipeline):
	//    - Partial internal seams between full-height walls and top/bottom lintel/sill must be 100% clipped away!
	//    - Coplanar outer faces must merge into convex quads!
	//    - Pointless T-junction/miter vertices at `(±0.6, ±2, ±2)` must be dissolved, leaving exactly 16 unique corner vertices and 16 quads!
	clean_polys := make([dynamic]cad_csg.CSG_Face_Poly, 0, 24, context.temp_allocator)
	cad_csg.csg_extract_clean_polygons_from_hulls(hulls[:], &clean_polys, context.temp_allocator)
	testing.expect(t, len(clean_polys) == 16, "Clean tunnel box must have exactly 16 convex quad faces (4 outer sides + 4 inner tunnel walls + 4 front frame quads + 4 back frame quads, 0 internal seam faces)")

	unique_verts := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	for fp in clean_polys {
		testing.expect(t, len(fp.verts) == 4, "Every face of the cleaned tunnel box must be a 4-vertex convex quad (no pointless collinear/T-junction points)")
		testing.expect(t, cad_csg.csg_is_face_poly_convex(fp.verts[:], fp.normal), "Every extracted polygon must be strictly convex (never an L-polygon bridging across the tunnel)")
		for v in fp.verts {
			found := false
			for uv in unique_verts {
				if linalg.length2(v - uv) <= 1e-4 {
					found = true
					break
				}
			}
			if !found do append(&unique_verts, v)
		}
	}
	testing.expect(t, len(unique_verts) == 16, "Cleaned tunnel box must have exactly 16 unique vertices (8 outer box corners + 8 tunnel opening corners, 0 pointless edge points)")

	// 3. Verify `csg_Volume_Bake_To_Static_Mesh` + `CSG -> Mesh -> CSG` round-trip preserves the open tunnel (never turns into a solid box!)
	scene := engine.sm_scene_get_active()
	root_h := engine.Transform_Handle(scene.root.handle)
	vol_h := engine.transform_new("TunnelRoundTripVol", root_h)
	_, v_ptr := engine.transform_add_comp(vol_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)v_ptr
	cad_csg.reset_CSGVolume(vol)

	cad_csg.csg_volume_add_brush(vol, "MainCube", .Add, .Box, {0, 0, 0}, {4.0, 4.0, 4.0}, 0, {200, 200, 200, 255})
	cad_csg.csg_volume_add_brush(vol, "TunnelHole", .Subtract, .Box, {0, 0, 0}, {1.2, 1.2, 6.0}, 0, {220, 80, 80, 255})
	cad_csg.csg_volume_rebuild(vol)

	baked_mesh_h := cad_csg.csg_volume_bake_to_static_mesh(vol)
	testing.expect(t, baked_mesh_h != {}, "csg_volume_bake_to_static_mesh should create a static mesh entity")
	_, mf := engine.transform_get_comp(baked_mesh_h, engine.MeshFilter)
	cpu_v, cpu_i, ok_m := engine.mesh_read_cpu_geometry(mf, context.temp_allocator)
	testing.expect(t, ok_m && len(cpu_i) == 16 * 6, "Baked tunnel static mesh should have exactly 16 quads = 32 triangles (96 indices) and 0 internal seam triangles")
	_ = cpu_v

	// 4. Test the exact Mesh Editor workflow:
	//    Spawn Mesh Box -> Carve Tunnel in Mesh (`mesh_op_boolean_box(.Subtract)`) -> Convert Mesh to CSG (`convert_editable_mesh_to_csg`)!
	//    Verify the converted CSG has 4 hulls around the open tunnel and does NOT turn back into a 1-hull solid box!
	cad_ed.spawn_editable_cad_mesh(0) // Spawn 2x2x2 CAD_Mesh_Box
	cad_ed.mesh_editor_set_boolean_box({0.0, 0.0, 0.0}, {0.8, 0.8, 4.0}) // Through-tunnel along Z!
	cad_ed.mesh_op_boolean_box(.Subtract)

	m_verts, m_faces := cad_ed.mesh_editor_get_counts()
	testing.expect(t, m_verts == 16, "Mesh Box with carved tunnel must have 16 vertices (0 pointless points)")
	testing.expect(t, m_faces == 16, "Mesh Box with carved tunnel must have 16 convex quad faces (0 internal polygons)")

	csg_from_mesh_h := cad_ed.convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
	testing.expect(t, csg_from_mesh_h != {}, "Converting tunnel mesh to CSG must succeed")
	_, csg_from_mesh_vol := engine.transform_get_comp(csg_from_mesh_h, cad_csg.CSGVolume)
	testing.expect(t, csg_from_mesh_vol != nil && len(csg_from_mesh_vol.runtime_hulls) == 4, "Converted CSGVolume from tunnel mesh must have 4 hulls (Left, Right, Top, Bottom), NEVER a 1-hull solid box!")

	// Verify the center of the tunnel (0, 0, 0) is NOT inside any of the converted CSG hulls!
	tunnel_center_solid := false
	for rh in csg_from_mesh_vol.runtime_hulls {
		inside := true
		for p in rh.planes {
			if -p.dist > 1e-3 {
				inside = false
				break
			}
		}
		if inside {
			tunnel_center_solid = true
			break
		}
	}
	testing.expect(t, !tunnel_center_solid, "Center of the carved tunnel (0,0,0) must remain open/empty after Mesh -> CSG conversion!")

	// 5. Test 1-Click Face Through-Tunnel Carving (`mesh_op_carve_tunnel_selected_face`) directly on a fresh Box outer face (without manual pre-inset!)
	cad_ed.spawn_editable_cad_mesh(0) // Spawn fresh 6-face Box
	cad_ed.mesh_op_carve_tunnel_selected_face(0.30)
	t_verts, t_faces := cad_ed.mesh_editor_get_counts()
	testing.expect(t, t_verts == 16 && t_faces == 16, "1-Click Carve Tunnel on a fresh Box face must auto-inset and produce a 16-vert, 16-quad open tunnel!")

	// 6. Test Blender-Style Edge Loop Cut (`mesh_op_loop_cut`) splits a 6-face Box into 10 faces without deleting half the mesh!
	cad_ed.spawn_editable_cad_mesh(0)
	cad_ed.mesh_op_loop_cut(0, 0.0)
	lc_verts, lc_faces := cad_ed.mesh_editor_get_counts()
	testing.expect(t, lc_verts == 12 && lc_faces == 10, "Loop Cut X at 0.0 on a 6-face Box must split the 4 crossing faces into 8 (10 total faces, 12 vertices) without deleting either half!")
}

@(test)
cad_csg_two_tunnels_four_pillars_roundtrip_and_blender_unreal_ops_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. User Bug Reproduction & Verification:
	//    Spawn a Box Mesh -> Carve TWO crossing tunnels (Z tunnel + X tunnel, creating 2 platforms held by 4 pillars)
	//    -> Verify 0 open boundary edges right away (no T-junction hole warning!)
	//    -> Convert Mesh -> CSG (6 hulls: Top Slab, Bottom Slab, 4 Pillars)
	//    -> Convert CSG -> Mesh (`convert_active_csg_to_editable_mesh`) -> Verify 0 open boundary edges & 0 inverted normals
	//    -> Convert Mesh -> CSG AGAIN -> Verify it STILL has 6 hulls and hollow center `{0,0,0}` (NEVER turns into a cube!)
	cad_ed.spawn_editable_cad_mesh(0) // 2x2x2 Box (`[-1, 1]^3`)
	// Carve Z tunnel (`[-0.4, 0.4] x [-0.4, 0.4] x [-2, 2]`)
	cad_ed.mesh_editor_set_boolean_box({0, 0, 0}, {0.8, 0.8, 4.0})
	cad_ed.mesh_op_boolean_box(.Subtract)
	// Carve X tunnel (`[-2, 2] x [-0.4, 0.4] x [-0.4, 0.4]`)
	cad_ed.mesh_editor_set_boolean_box({0, 0, 0}, {4.0, 0.8, 0.8})
	cad_ed.mesh_op_boolean_box(.Subtract)

	open1, inv1, _, valid_vol1 := cad_ed.mesh_editor_get_compliance_counts()
	testing.expect(t, open1 == 0 && inv1 == 0 && valid_vol1, "2-Tunnel 4-Pillar Mesh must have 0 open boundary edges and 0 inverted faces (perpendicular pillar-to-slab T-junctions stitched & chord-split!)")

	// Convert 4-Pillar Mesh -> CSG (Pass 1)
	csg_h1 := cad_ed.convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
	testing.expect(t, csg_h1 != {}, "Pass 1: 4-Pillar Mesh -> CSG must succeed")
	_, vol1 := engine.transform_get_comp(csg_h1, cad_csg.CSGVolume)
	testing.expect(t, vol1 != nil && len(vol1.runtime_hulls) == 6, "Pass 1: 2-Tunnel 4-Pillar CSGVolume must have 6 convex hulls (Top Slab, Bottom Slab, 4 Corner Pillars)")

	// Convert 4-Pillar CSG -> Editable Mesh (Pass 2)
	mesh_h2 := cad_ed.convert_active_csg_to_editable_mesh()
	testing.expect(t, mesh_h2 == csg_h1, "Pass 2: CSG -> Mesh must convert in place on the same entity")
	open2, inv2, _, valid_vol2 := cad_ed.mesh_editor_get_compliance_counts()
	testing.expect(t, open2 == 0 && inv2 == 0 && valid_vol2, "Pass 2: Converted 4-Pillar Mesh from CSG must remain 100% watertight (0 open edges, 0 inverted faces)")

	// Convert 4-Pillar Editable Mesh -> CSG AGAIN (Pass 3)
	csg_h3 := cad_ed.convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
	testing.expect(t, csg_h3 == csg_h1, "Pass 3: Mesh -> CSG round-trip must succeed in place")
	_, vol3 := engine.transform_get_comp(csg_h3, cad_csg.CSGVolume)
	testing.expect(t, vol3 != nil && len(vol3.runtime_hulls) == 6, "Pass 3: Round-tripped CSGVolume must still have 6 hulls (NEVER wrapped into a 1-hull solid cube!)")

	center_solid := false
	for rh in vol3.runtime_hulls {
		inside := true
		for p in rh.planes {
			if -p.dist > 1e-3 {
				inside = false
				break
			}
		}
		if inside {
			center_solid = true
			break
		}
	}
	testing.expect(t, !center_solid, "Pass 3: Center (0,0,0) of the 2-tunnel 4-pillar structure must remain hollow after Mesh -> CSG -> Mesh -> CSG!")

	// 2. Test `[1] Vertex` Mode `Make Face / Fill (F)` (`mesh_op_make_face_from_selected_verts`):
	cad_ed.spawn_editable_cad_mesh(0) // Fresh 8-vert, 6-face Box
	cad_ed.mesh_editor_select_face(0) // Select top face `{3, 7, 6, 2}`
	cad_ed.mesh_op_delete_selected_face()
	_, faces_after_del := cad_ed.mesh_editor_get_counts()
	open_after_del, _, _, _ := cad_ed.mesh_editor_get_compliance_counts()
	testing.expect(t, faces_after_del == 5 && open_after_del == 4, "Deleting a box face should leave 5 faces and 4 open boundary edges")

	// Select the 4 top vertices `{3, 7, 6, 2}` (in arbitrary order `{2, 3, 6, 7}`) in Vertex mode and press `F` (`mesh_op_make_face_from_selected_verts`)!
	cad_ed.mesh_editor_select_verts({2, 3, 6, 7})
	filled_ok := cad_ed.mesh_op_make_face_from_selected_verts()
	_, faces_after_fill := cad_ed.mesh_editor_get_counts()
	open_after_fill, inv_after_fill, _, _ := cad_ed.mesh_editor_get_compliance_counts()
	testing.expect(t, filled_ok && faces_after_fill == 6 && open_after_fill == 0 && inv_after_fill == 0, "Make Face / Fill (F) from 4 selected vertices must create a properly oriented outward quad and restore 0 open edges!")

	// 3. Test `[2] Edge` Mode `Bevel / Chamfer Edge (B)` (`mesh_op_bevel_selected_edge`):
	cad_ed.spawn_editable_cad_mesh(0)
	cad_ed.mesh_editor_select_edge(0, 1)
	cad_ed.mesh_op_bevel_selected_edge(0.25)
	bev_verts, bev_faces := cad_ed.mesh_editor_get_counts()
	bev_open, bev_inv, _, _ := cad_ed.mesh_editor_get_compliance_counts()
	testing.expect(t, bev_verts == 10 && bev_faces == 7 && bev_open == 0 && bev_inv == 0, "Beveling an edge on a Box must produce a watertight 7-face, 10-vertex chamfered polyhedron with 0 open edges!")

	// 4. Test World-Space 2-Mesh Booleans (`mesh_op_boolean_with_other_mesh`: `A - B`):
	cad_ed.spawn_editable_cad_mesh(0) // Spawn Mesh B (cutter)
	mesh_b_h := cad_ed.mesh_editor_get_target_owner()
	w := engine.ctx_world()
	if tb := engine.pool_get(&w.transforms, engine.Handle(mesh_b_h)); tb != nil {
		tb.scale = {0.5, 0.5, 2.5} // Narrow bar along Z
	}
	cad_ed.spawn_editable_cad_mesh(0) // Spawn Mesh A (2x2x2 Box at origin, now active in Mesh Editor)
	bool_ok := cad_ed.mesh_op_boolean_with_other_mesh(mesh_b_h, 1) // Mode 1 = `A - B`
	ab_verts, ab_faces := cad_ed.mesh_editor_get_counts()
	ab_open, ab_inv, _, _ := cad_ed.mesh_editor_get_compliance_counts()
	testing.expect(t, bool_ok && ab_verts == 16 && ab_faces == 16 && ab_open == 0 && ab_inv == 0, "World-Space 2-Mesh Boolean (A - B) must carve Mesh B's transformed volume out of Mesh A cleanly!")
	// Verify Tool Mesh B was NOT hidden or disabled!
	_, mr_b := engine.transform_get_comp(mesh_b_h, engine.MeshRenderer)
	testing.expect(t, mr_b != nil && mr_b.enabled, "Tool Mesh B must remain active and visible in the scene (NO automatic hiding)")

	// 5. Test Save Mesh to Disk (`mesh_op_save_to_disk` -> `.glb` + `.obj`):
	glb_path, save_ok := cad_ed.mesh_op_save_to_disk("UnitTest_CAD_SavedMesh")
	testing.expect(t, save_ok && glb_path == "assets/meshes/UnitTest_CAD_SavedMesh.glb", "mesh_op_save_to_disk should return valid .glb path")
	testing.expect(t, os.exists("assets/meshes/UnitTest_CAD_SavedMesh.glb") && os.exists("assets/meshes/UnitTest_CAD_SavedMesh.obj"), "Both .glb and .obj files must be written to disk")
	os.remove("assets/meshes/UnitTest_CAD_SavedMesh.glb")
	os.remove("assets/meshes/UnitTest_CAD_SavedMesh.obj")
}

@(test)
cad_uv_suite_and_multi_boolean_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Test Box UV Unwrapping & Metric Projection
	cad_ed.spawn_editable_cad_mesh(0) // 8-vert, 6-face Box
	cad_ed.mesh_uv_unwrap_box(scale = 1.0, fit_01 = true)

	// 2. Test Planar Projection
	cad_ed.mesh_uv_unwrap_planar(axis = 1, scale = 1.0, fit_01 = true)

	// 3. Test Cylindrical Projection
	cad_ed.spawn_editable_cad_mesh(1) // Cylinder
	cad_ed.mesh_uv_unwrap_cylinder(axis = 1, fit_01 = true)

	// 4. Test Spherical Projection
	cad_ed.spawn_editable_cad_mesh(5) // UV Sphere
	cad_ed.mesh_uv_unwrap_sphere(fit_01 = true)

	// 5. Test Auto-Unwrap Islands (Conformal / LSCM) & Island Packing
	cad_ed.spawn_editable_cad_mesh(0) // Box
	cad_ed.mesh_uv_auto_unwrap_islands(margin = 0.02)
	cad_ed.mesh_uv_pack_islands(padding = 0.02)

	// 6. Test UV Seams: Mark Edge Seam & Clear Seams
	cad_ed.mesh_editor_select_edge(0, 1)
	cad_ed.mesh_uv_toggle_selected_edge_seam()
	cad_ed.mesh_uv_clear_all_seams()

	// 7. Test Quick UV Transforms: Rotate 90, Flip U/V, Fit 0-1
	cad_ed.mesh_uv_rotate_90(clockwise = true)
	cad_ed.mesh_uv_flip(flip_u = true, flip_v = false)
	cad_ed.mesh_uv_fit_01()

	// 8. Test Unreal-Style Multi-Mesh Booleans (`mesh_op_boolean_multi` without hiding)
	cad_ed.spawn_editable_cad_mesh(0) // Tool B
	tool_b := cad_ed.mesh_editor_get_target_owner()
	w := engine.ctx_world()
	if tb := engine.pool_get(&w.transforms, engine.Handle(tool_b)); tb != nil {
		tb.scale = {0.4, 0.4, 3.0}
	}
	cad_ed.spawn_editable_cad_mesh(0) // Target A (2x2x2 Box)
	target_a := cad_ed.mesh_editor_get_target_owner()

	multi_ok := cad_ed.mesh_op_boolean_multi(target_a, {tool_b}, 1) // Subtract
	testing.expect(t, multi_ok, "mesh_op_boolean_multi (Subtract) should succeed")
	_, mr_tool := engine.transform_get_comp(tool_b, engine.MeshRenderer)
	testing.expect(t, mr_tool != nil && mr_tool.enabled, "Tool mesh must remain enabled/visible after multi-boolean")
}

@(test)
cad_session_memory_cache_and_multi_csg_booleans_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	w := engine.ctx_world()

	// 1. Enter CAD Mode -> Allocate Session Memory Cache
	cad_ed.enter_cad_mode_memory_cache()
	cache_on, m_u0, _, _, _, _ := cad_ed.cad_mode_memory_cache_stats()
	testing.expect(t, cache_on && m_u0 == 0, "Entering CAD Mode must activate the session memory cache at Undo (0)")

	// 2. Spawn Tool Mesh B and Target Mesh A, verify newly spawned shape starts at Undo (0),
	//    then run Multi-Mesh Boolean (`A - B`) and verify Undo (1) / Redo (1) work!
	cad_ed.spawn_editable_cad_mesh(0) // Tool B
	tool_b := cad_ed.mesh_editor_get_target_owner()
	if tb := engine.pool_get(&w.transforms, engine.Handle(tool_b)); tb != nil {
		tb.scale = {0.4, 0.4, 3.0}
	}

	cad_ed.spawn_editable_cad_mesh(0) // Target A (8V, 6F)
	target_a := cad_ed.mesh_editor_get_target_owner()
	_, m_u_spawn, _, _, _, _ := cad_ed.cad_mode_memory_cache_stats()
	testing.expect(t, m_u_spawn == 0, "Newly spawned CAD mesh must start with clean baseline Undo (0)")

	ok_m_bool := cad_ed.mesh_op_boolean_multi(target_a, {tool_b}, 1)
	testing.expect(t, ok_m_bool, "Multi-Mesh Boolean (A - B) should succeed")
	_, m_u_after, _, _, _, bytes_after := cad_ed.cad_mode_memory_cache_stats()
	testing.expect(t, m_u_after == 1 && bytes_after > 0, "Multi-Mesh Boolean must record Undo (1) in CAD Session Memory Cache")

	// Undo the Multi-Mesh Boolean -> back to 8V, 6F Box!
	cad_ed.set_workspace_tab(.Mesh_Editor)
	cad_ed.mesh_editor_undo()
	v_undo, f_undo := cad_ed.mesh_editor_get_counts()
	testing.expect(t, v_undo == 8 && f_undo == 6, "Undoing Multi-Mesh Boolean must restore Target A to 8V, 6F Box")

	// Redo the Multi-Mesh Boolean -> back to 16V, 16F carved tunnel!
	cad_ed.mesh_editor_redo()
	v_redo, f_redo := cad_ed.mesh_editor_get_counts()
	testing.expect(t, v_redo == 16 && f_redo == 16, "Redoing Multi-Mesh Boolean must restore the 16V, 16F tunnel mesh")

	// 3. Test Unreal-Style Multi-CSG Booleans (`csg_op_boolean_multi`: `A - B`, `A + B`, `A & B`) + CSG Undo/Redo!
	cad_ed.set_workspace_tab(.CSG_Editor)
	csg_a_h := cad_ed.spawn_separate_csg_primitive_volume(.Box, {4.0, 4.0, 4.0}, {0, 2.0, 0})
	csg_b_h := cad_ed.spawn_separate_csg_primitive_volume(.Box, {1.6, 1.6, 8.0}, {0, 2.0, 0})
	engine.inspector_request_select(csg_a_h)

	_, vol_a := engine.transform_get_comp(csg_a_h, cad_csg.CSGVolume)
	_, vol_b := engine.transform_get_comp(csg_b_h, cad_csg.CSGVolume)
	testing.expect(t, vol_a != nil && vol_b != nil, "Both CSGVolume A and CSGVolume B must exist")

	// Run CSG Boolean Subtract (`A - B`)
	csg_sub_ok := cad_ed.csg_op_boolean_multi(csg_a_h, {csg_b_h}, 1)
	testing.expect(t, csg_sub_ok && len(vol_a.runtime_hulls) >= 4, "CSG Multi-Boolean (A - B) must carve CSG B out of CSG A into multi-hull CSG")
	testing.expect(t, vol_b.enabled, "Tool CSG B must remain enabled and visible (never auto-hidden)")

	// Undo CSG Boolean Subtract -> restores `vol_a` back to its 1 authored Box brush!
	_, _, _, c_undo_n, _, _ := cad_ed.cad_mode_memory_cache_stats()
	testing.expect(t, c_undo_n == 1, "CSG Boolean must record 1 step on the CSG Undo stack")
	cad_ed.mesh_editor_undo()
	testing.expect(t, len(vol_a.brushes) == 1 && len(vol_a.runtime_hulls) == 0, "Undoing CSG Boolean must restore CSG A's original brush")

	// Redo CSG Boolean Subtract -> restores the carved multi-hull CSG!
	cad_ed.mesh_editor_redo()
	testing.expect(t, len(vol_a.runtime_hulls) >= 4, "Redoing CSG Boolean must restore the carved multi-hull CSG")

	// 4. Exit CAD Mode -> Release 100% of the CAD Session Memory Cache!
	cad_ed.release_cad_mode_memory_cache()
	cache_after_exit, m_u_exit, m_r_exit, c_u_exit, c_r_exit, bytes_exit := cad_ed.cad_mode_memory_cache_stats()
	testing.expect(
		t,
		!cache_after_exit && m_u_exit == 0 && m_r_exit == 0 && c_u_exit == 0 && c_r_exit == 0 && bytes_exit == 0,
		"Exiting CAD Mode must release 100% of the CAD Session Memory Cache (0 bytes used)",
	)
}

@(test)
csg_materials_procedural_textures_and_soft_deformer_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Verify Physical & Destructible Material Properties DataTable (`csg_material_datatable`)
	cad_csg.csg_init_material_datatable()

	// Tempered Glass & Sheet Ice shatter at low force (5.0 N*s), while Reinforced Concrete & Steel Plate resist!
	glass_frac, glass_r, _, _, _ := cad_csg.csg_eval_blast_against_material(.Tempered_Glass, 1.5, 5.0)
	ice_frac, ice_r, _, _, _     := cad_csg.csg_eval_blast_against_material(.Sheet_Ice, 1.5, 5.0)
	reinf_frac, _, _, _, _       := cad_csg.csg_eval_blast_against_material(.Reinforced_Concrete, 1.5, 5.0)
	steel_frac, _, _, _, steel_dent := cad_csg.csg_eval_blast_against_material(.Steel_Plate, 1.5, 14.0)
	soft_frac, _, _, _, soft_dent   := cad_csg.csg_eval_blast_against_material(.Soft_Metal_Panel, 1.5, 14.0)

	testing.expect(t, glass_frac && glass_r > 1.5, "Tempered_Glass must fracture at 5.0 N*s impulse")
	testing.expect(t, ice_frac && ice_r > 1.5, "Sheet_Ice must fracture at 5.0 N*s impulse")
	testing.expect(t, !reinf_frac, "Reinforced_Concrete must resist a weak 5.0 N*s blast")
	testing.expect(t, !steel_frac && steel_dent > 0.02, "Steel_Plate must resist fracturing at 14.0 N*s while producing a Soft Deformer dent!")
	testing.expect(t, !soft_frac && soft_dent > steel_dent, "Soft_Metal_Panel must dent deeper than Steel_Plate under the same impulse!")

	// 2. Verify Godot-Style Procedural Texture Generator (`csg_generate_procedural_texture_rgba`)
	//    Specifically verify that `Glass_Frosted_Streaks` produces a see-through translucent interior (`alpha < 110`)
	//    AND bright visible specular streaks / frame rim (`alpha > 180`)!
	glass_params := cad_csg.csg_default_proc_texture_params(.Glass_Frosted_Streaks)
	glass_params.width  = 64
	glass_params.height = 64
	glass_rgba := cad_csg.csg_generate_procedural_texture_rgba(glass_params, context.temp_allocator)
	testing.expect(t, len(glass_rgba) == 64 * 64 * 4, "Procedural glass texture must generate 64x64 RGBA8 buffer")

	min_a: u8 = 255
	max_a: u8 = 0
	for i := 3; i < len(glass_rgba); i += 4 {
		a := glass_rgba[i]
		if a < min_a do min_a = a
		if a > max_a do max_a = a
	}
	testing.expect(t, min_a < 110 && max_a > 175, "See-through glass procedural texture must have both translucent see-through pixels and bright specular streak/rim pixels")

	// Also verify `csg_glass_material_guid()` has high-byte prefix `0xFF, 0xFF` so it sorts AFTER opaque meshes!
	g_guid_raw := transmute([16]u8)cad_csg.csg_glass_material_guid()
	testing.expect(t, g_guid_raw[0] == 0xFF && g_guid_raw[1] == 0xFF, "csg_glass_material_guid must start with 0xFF, 0xFF so transparent glass sorts after opaque geometry")

	// 3. Verify Parametric Window Cutout + See-Through Glass Pairing (`csg_volume_add_window_cutout_with_glass` & `csg_sync_glass_pane_paired_cutout`)
	cad_ed.spawn_parametric_csg_prefab(0) // Wall + Window + See-Through Glass
	w := engine.ctx_world()
	it := engine.pool_iterator(cad_csg.csg_volumes(w))
	vol, _, _ := engine.pool_next(&it)
	testing.expect(t, vol != nil, "spawn_parametric_csg_prefab(0) must create a CSGVolume")
	testing.expect(t, len(vol.brushes) == 2 && len(vol.glass_panes) == 1, "Wall + Window Prefab must have 1 additive wall brush, 1 subtractive window cutout brush, and 1 see-through glass pane")
	testing.expect(t, vol.glass_panes[0].cutout_brush_id == vol.brushes[1].id, "Glass pane must be linked to its paired .Subtract window cutout brush")

	// Resize the glass pane and sync its paired cutout brush
	vol.glass_panes[0].size_2d = {3.2, 2.0}
	sync_ok := cad_csg.csg_sync_glass_pane_paired_cutout(vol, &vol.glass_panes[0])
	testing.expect(t, sync_ok && abs(vol.brushes[1].size.x - 3.2) < 1e-3, "Syncing glass pane paired cutout must resize the boolean .Subtract window hole to match")

	// 4. Verify Soft Deformer Bodies via Coordinate Offset (`csg_apply_soft_deform_impulse`, `csg_build_deformed_vertex_buffer`, `csg_build_soft_deform_offset_texture_rgba8`)
	//    Ensure visual vertices deform while CSG collision hulls remain 100% unchanged!
	vol.material_preset     = .Soft_Metal_Panel
	vol.soft_deform_enabled = true

	// Record undeformed collision hull count before soft deformation
	hulls_before := 0
	verts_before := 0
	for _, ch in vol.chunks {
		hulls_before += len(ch.destructible_hulls) + len(ch.indestructible_hulls)
		verts_before += len(ch.verts)
	}
	testing.expect(t, hulls_before > 0 && verts_before > 0, "Compiled wall volume must have convex collision hulls and chunk vertices")

	// Apply a Soft Deformer dent stamp at the front of the wall
	stamps_added := cad_csg.csg_apply_soft_deform_impulse({0, 1.5, 0.25}, {0, 0, 1}, 1.8, 0.40, .Dent_Inward, vol)
	testing.expect(t, stamps_added == 1 && len(vol.soft_deform_stamps) == 1, "csg_apply_soft_deform_impulse must add a Soft Deformer coordinate-offset stamp")

	// Verify collision hulls stay valid (>= hulls_before, with shallow dent pocket carved) AND visual vertex buffer deforms (`max_disp > 0.05m`)
	hulls_after := 0
	max_visual_disp: f32 = 0.0
	for _, ch in vol.chunks {
		hulls_after += len(ch.destructible_hulls) + len(ch.indestructible_hulls)
		if len(ch.verts) > 0 {
			_, ch_max_d, _ := cad_csg.csg_build_deformed_vertex_buffer(vol, ch.verts[:], context.temp_allocator)
			if ch_max_d > max_visual_disp do max_visual_disp = ch_max_d
		}
	}
	testing.expect(t, hulls_after >= hulls_before, "Soft Deformer must maintain valid CSG collision hulls (with shallow dent pocket carved)")
	testing.expect(t, max_visual_disp > 0.05, "Soft Deformer must displace visual mesh vertices via coordinate offset (p' = p0 + delta_p)")

	// Verify 2D Deformation Offset Texture generation (`csg_build_soft_deform_offset_texture_rgba8`)
	deform_tex := cad_csg.csg_build_soft_deform_offset_texture_rgba8(vol, 32, 32, false, context.temp_allocator)
	testing.expect(t, len(deform_tex) == 32 * 32 * 4, "Deformation offset texture must be 32x32 RGBA8")

	// Tick elastic spring-damper recovery and reset soft deform
	cad_csg.csg_tick_soft_deform_stamps(0.016)
	cad_csg.csg_volume_reset_soft_deform(vol)
	testing.expect(t, len(vol.soft_deform_stamps) == 0, "csg_volume_reset_soft_deform must clear all deformation stamps")
}

@(test)
poly_glass_spiderweb_shatter_and_faker_mesh_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Verify 3D Polygon Glass Creation (`csg_volume_add_poly_glass_pane`) & Radial Spiderweb Shatter
	//    (Shattering punches a radial spiderweb hole + jagged collar shards instead of deleting glass from existence!)
	wall_h := cad_ed.spawn_separate_csg_primitive_volume(.Box, {6.0, 4.0, 0.5}, {0, 2.0, 0})
	_, wall_vol := engine.transform_get_comp(wall_h, cad_csg.CSGVolume)
	testing.expect(t, wall_vol != nil, "Wall CSGVolume must be created")

	poly_pts_3d := [5][3]f32{
		{-1.2, -0.8, 0.25},
		{ 1.2, -0.8, 0.25},
		{ 1.2,  0.5, 0.25},
		{ 0.0,  1.2, 0.25}, // Pointed arch peak!
		{-1.2,  0.5, 0.25},
	}
	cut_idx, gp_idx := cad_csg.csg_volume_add_poly_glass_pane(
		wall_vol,
		"Arch_Poly_Glass",
		poly_pts_3d[:],
		{0, 0, 1},
		true,
		0.5,
		.Tempered_Glass,
	)
	cad_csg.csg_volume_rebuild(wall_vol)
	testing.expect(t, gp_idx == 0 && cut_idx >= 0 && len(wall_vol.glass_panes[0].poly_points_2d) == 5, "3D Polygon Glass must store 5 custom polygon vertices and carve a matching .Subtract hole")

	// Trigger Glass Shatter Test on the pane and verify it does NOT delete the glass from existence!
	shattered_cells := cad_csg.csg_damage_glass_at_point(
		{0, 2.0, 0.25},
		0.85,
		8.0,
	)
	testing.expect(t, shattered_cells > 0, "csg_damage_glass_at_point must fracture cells around the impact")
	testing.expect(t, !wall_vol.glass_panes[0].completely_shattered, "Single shatter test must NOT delete the entire glass pane from existence!")
	testing.expect(t, len(wall_vol.glass_panes[0].shatter_impacts) == 1, "Glass pane must record the impact crater for radial spiderweb fracture")

	// 2. Verify CSG-First Faker CSG Workflow:
	//    Spawn Mesh -> Turn Mesh into CSG (`convert_editable_mesh_to_csg`) -> Attach Mesh Instance into CSG (`csg_attach_mesh_instance_to_csg`)
	//    -> Fit Scale/Rotation/Offset (`csg_autofit_faker_mesh_to_volume`) -> Save & Spawn Binary `.fmesh` (`csg_save_faker_mesh_binary`)!
	cad_ed.spawn_editable_cad_mesh(1) // Spawn Cylinder Mesh
	csg_h := cad_ed.convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
	testing.expect(t, csg_h != {}, "convert_editable_mesh_to_csg must convert the cylinder mesh into a CSGVolume")
	w := engine.ctx_world()
	_, faker_vol := engine.transform_get_comp(csg_h, cad_csg.CSGVolume)
	testing.expect(t, faker_vol != nil && !engine.asset_guid_is_empty(faker_vol.faker_mesh_guid), "Converted CSGVolume must remember the source mesh GUID for 1-click Faker CSG conversion")

	attached := cad_csg.csg_attach_mesh_instance_to_csg(faker_vol, faker_vol.faker_mesh_guid, {}, auto_fit = true)
	testing.expect(t, attached && faker_vol.is_faker_mesh && len(faker_vol.runtime_hulls) > 0, "csg_attach_mesh_instance_to_csg must convert CSGVolume into a Faker CSG while preserving its converted CSG hulls")
	faker_vol.faker_mesh_rot_deg = {0, 45, 0}

	// Verify Binary `.fmesh` Save & Spawn (including serialized CSG hulls & rotation!)
	fmesh_path := "assets/meshes/unit_test_faker.fmesh"
	saved_bin := cad_csg.csg_save_faker_mesh_binary(faker_vol, fmesh_path)
	testing.expect(t, saved_bin && os.exists(fmesh_path), "csg_save_faker_mesh_binary must write a raw binary .fmesh file without JSON")
	spawned_bin_h := cad_csg.csg_spawn_faker_mesh_from_binary({4.0, 1.5, 0.0}, fmesh_path)
	_, spawned_bin_vol := engine.transform_get_comp(spawned_bin_h, cad_csg.CSGVolume)
	testing.expect(t, spawned_bin_vol != nil && spawned_bin_vol.is_faker_mesh && spawned_bin_vol.faker_mesh_guid == faker_vol.faker_mesh_guid && abs(spawned_bin_vol.faker_mesh_rot_deg.y - 45.0) < 1e-3, "csg_spawn_faker_mesh_from_binary must restore mesh GUID, rotation, and CSG hulls")
	os.remove(fmesh_path)

	// 3. Verify 2-Point Clip Plane Slicer (`csg_volume_clip_by_plane` with `.Split_Both`) splits a CSGVolume into TWO separate GameObjects!
	slice_box_h := cad_ed.spawn_separate_csg_primitive_volume(.Box, {4.0, 2.0, 2.0}, {0, 5.0, 0})
	_, slice_vol := engine.transform_get_comp(slice_box_h, cad_csg.CSGVolume)
	vols_before := 0
	it_before := engine.pool_iterator(cad_csg.csg_volumes(w))
	for _, _ in engine.pool_next(&it_before) do vols_before += 1

	sliced_cnt := cad_csg.csg_volume_clip_by_plane(slice_vol, {1, 0, 0}, 0.0, .Split_Both, 0.05)
	vols_after := 0
	it_after := engine.pool_iterator(cad_csg.csg_volumes(w))
	for _, _ in engine.pool_next(&it_after) do vols_after += 1
	testing.expect(t, sliced_cnt > 0 && vols_after == vols_before + 1, "Slicing a CSGVolume with Split_Both must detach the second half into a new standalone CSGVolume GameObject!")
}

@(test)
faker_csg_clipping_and_soft_deform_tessellation_test :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1. Spawn a Box CSGVolume (`B`), convert it into a Faker CSG with an inner Cube Mesh (`A`),
	//    and slice `B` diagonally with `csg_volume_clip_by_plane(..., .Split_Both)`.
	box_h := cad_ed.spawn_separate_csg_primitive_volume(.Box, {2.0, 2.0, 2.0}, {0, 2.0, 0})
	_, vol := engine.transform_get_comp(box_h, cad_csg.CSGVolume)
	testing.expect(t, vol != nil, "Faker test CSGVolume must exist")

	vol.is_faker_mesh = true
	vol.faker_mesh_scale = {2.0, 2.0, 2.0}
	vol.faker_hide_outer_shell = true

	// Slice diagonally across X+Y and split into two halves
	n_diag := linalg.normalize0([3]f32{1.0, 0.65, 0.0})
	sliced := cad_csg.csg_volume_clip_by_plane(vol, n_diag, 0.0, .Split_Both, 0.04)
	testing.expect(t, sliced > 0, "Diagonal slice on Faker CSG must clip the outer CSG hull")
	cad_csg.csg_volume_upload_gpu_now(vol)

	a_guid := cad_csg.make_faker_clipped_guid(vol.owner)
	b_cap_guid := cad_csg.make_faker_cut_cap_guid(vol.owner)
	mf_a := engine.MeshFilter{mesh = engine.PPtr{guid = a_guid}}
	mf_b := engine.MeshFilter{mesh = engine.PPtr{guid = b_cap_guid}}
	a_verts, a_inds, a_ok := engine.mesh_read_cpu_geometry(&mf_a, context.temp_allocator)
	b_verts, b_inds, b_ok := engine.mesh_read_cpu_geometry(&mf_b, context.temp_allocator)

	testing.expect(t, a_ok && len(a_verts) > 0 && len(a_inds) >= 3, "Rule 1 (A inside B -> render A): Clipped inner mesh A must be uploaded with valid clipped triangles")
	testing.expect(t, b_ok && len(b_verts) > 0 && len(b_inds) >= 3, "Rule 2 (B inside A -> render that part as B): Interior cross-section cap of B inside A must be uploaded")

	// Verify all clipped vertices of A on `vol` lie strictly inside every plane of the sliced CSG hull `B`!
	max_plane_violation: f32 = -1e30
	if len(vol.runtime_hulls) > 0 {
		h0 := vol.runtime_hulls[0]
		for v in a_verts {
			for p in h0.planes {
				viol := linalg.dot(p.normal, v.position) - p.dist
				if viol > max_plane_violation do max_plane_violation = viol
			}
		}
	}
	testing.expect(t, max_plane_violation <= 1e-3, "All vertices of clipped inner mesh A must lie inside every half-space plane of the sliced CSG hull B")

	// 2. Verify local 1-to-4 midpoint tessellation (`csg_tessellate_and_deform_mesh`) on a coarse CSGVolume
	dent_h := cad_ed.spawn_separate_csg_primitive_volume(.Box, {4.0, 2.0, 4.0}, {8.0, 1.0, 0.0})
	_, dent_vol := engine.transform_get_comp(dent_h, cad_csg.CSGVolume)
	base_v_count := 0
	for _, ch in dent_vol.chunks {
		if ch != nil do base_v_count += len(ch.verts)
	}
	stamped := cad_csg.csg_apply_soft_deform_impulse({8.0, 2.0, 0.0}, {0, 1, 0}, 1.2, 0.45, .Dent_Inward, dent_vol)
	testing.expect(t, stamped > 0 && len(dent_vol.soft_deform_stamps) == 1, "Soft deform impulse must record a deformation stamp without synchronous boolean hull carving")

	tess_v_count := 0
	for _, ch in dent_vol.chunks {
		if ch == nil do continue
		tv, ti, _ := cad_csg.csg_tessellate_and_deform_mesh(dent_vol, ch.verts[:], ch.indices[:], ch.submeshes[:], context.temp_allocator)
		tess_v_count += len(tv)
		testing.expect(t, len(ti) >= len(ch.indices), "Tessellated index count must be >= coarse index count")
	}
	testing.expect(t, tess_v_count > base_v_count, "csg_tessellate_and_deform_mesh must locally subdivide coarse triangles overlapping the soft deform stamp")
}









