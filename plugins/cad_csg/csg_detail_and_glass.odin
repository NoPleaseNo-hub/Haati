package cad_csg

// ============================================================================
// PILLAR 2 & PILLAR 3 LEVEL COMPOSITION RUNTIME & MANAGER
// ============================================================================
// 1. Pillar 2 — CSG-Bound Mesh Instance Decorator (`CSG_Detail_Instance`):
//    - Ultra-cheap visual architectural kitbash instances ("Gothic Wall" pillars, pointed arches,
//      buttresses, ribbed trim beams, brackets, grates, and custom mesh assets).
//    - Zero Jolt collider overhead ("just for show"), batched into a single GPU mesh buffer.
//    - Coupled to CSG destruction in RAM: when the backing CSG hull is blasted or clipped away,
//      unsupported instances set `destroyed_in_ram = true` and pop off as cosmetic debris on
//      `physics3d.LAYER_DEBRIS_COSMETIC` (`5`).
// 2. Pillar 3 — Valve-Style 2D Shatterable Tempered Glass (`CSG_Glass_Pane`):
//    - 2D Voronoi-perturbed cell grid mounted in CSG window cutouts.
//    - Uses `physics3d.LAYER_GLASS_FENESTRATION` (`3`): blocks physical movement, transparent to
//      AI Vision (`MASK_VISION_LOS`), and shatters on Weapon Traces (`MASK_WEAPON_TRACE`) or blasts!
// 3. Minecraft-Style Recipe-on-Disk + Runtime-Deltas-in-RAM:
//    - Authored instances and glass panes serialize to `.scene` on disk; all destruction state
//      (`destroyed_in_ram`, `shattered_cells`, `completely_shattered`) lives strictly in RAM and
//      resets cleanly on Scene Reload or `Reset Destruction`.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import jolt "haati:external/jolt"
import engine "haati:engine"
import gfx "haati:engine/gfx"
import physics3d "haati:packages/physics3d"

// Deterministic procedural GPU mesh GUID for a volume's batched Detail Instances + Shatterable Glass Panes
make_detail_and_glass_guid :: #force_inline proc(tH: engine.Transform_Handle) -> engine.Asset_GUID {
	return make_procedural_guid(tH, 7)
}

// Dedicated procedural GPU mesh GUID for see-through `CSG_Glass_Pane` geometry (`salt = 8`),
// rendered with `csg_glass_material_guid()` so transparent glass sorts AFTER all opaque CSG chunks!
make_glass_pane_guid :: #force_inline proc(tH: engine.Transform_Handle) -> engine.Asset_GUID {
	return make_procedural_guid(tH, 8)
}

// Procedural GPU mesh GUID for clipped inner mesh `A` of a Faker CSG (`salt = 9`)
make_faker_clipped_guid :: #force_inline proc(tH: engine.Transform_Handle) -> engine.Asset_GUID {
	return make_procedural_guid(tH, 9)
}

// Procedural GPU mesh GUID for clipped interior cut cap `B` inside `A` of a Faker CSG (`salt = 10`)
make_faker_cut_cap_guid :: #force_inline proc(tH: engine.Transform_Handle) -> engine.Asset_GUID {
	return make_procedural_guid(tH, 10)
}

// ============================================================================
// PILLAR 2: CSG-BOUND DETAIL INSTANCE AUTHORING & WALL ARRAY STAMPER
// ============================================================================

// Adds a single CSG-bound visual detail instance (`CSG_Detail_Instance`) to `vol`.
csg_volume_add_detail_instance :: proc(
	vol:                 ^CSGVolume,
	name:                string,
	preset:              CSG_Detail_Preset,
	local_pos:           [3]f32,
	local_normal:        [3]f32 = {0, 0, 1},
	yaw_deg:             f32 = 0.0,
	scale:               [3]f32 = {1, 1, 1},
	color:               [4]u8 = {202, 198, 190, 255},
	pop_debris_on_blast: bool = true,
	custom_mesh:         engine.Asset_GUID = {},
) -> int {
	if vol == nil do return -1
	if vol.next_brush_id == 0 do vol.next_brush_id = 1
	id := vol.next_brush_id
	vol.next_brush_id += 1

	n_clean := linalg.normalize0(local_normal)
	if linalg.length2(n_clean) < 1e-4 do n_clean = {0, 0, 1}

	s_clean := [3]f32{
		max(abs(scale.x), 0.05),
		max(abs(scale.y), 0.05),
		max(abs(scale.z), 0.05),
	}

	inst := CSG_Detail_Instance{
		id                  = id,
		name                = strings.clone(name),
		preset              = preset,
		custom_mesh         = custom_mesh,
		local_pos           = local_pos,
		local_normal        = n_clean,
		yaw_deg             = yaw_deg,
		scale               = s_clean,
		color               = color,
		pop_debris_on_blast = pop_debris_on_blast,
		destroyed_in_ram    = false,
	}
	append(&vol.detail_instances, inst)
	csg_volume_repack_gpu_mesh(vol)
	return len(vol.detail_instances) - 1
}

// 1-Click Linear Wall Array Stamper:
// Stamps `count` evenly-spaced architectural kitbash instances (e.g. Gothic Pillars, Pointed Arches,
// Wall Buttresses, or Trim Beams) along `tangent_dir` centered around `start_local_pos` on a CSG surface!
csg_volume_add_detail_wall_array :: proc(
	vol:                 ^CSGVolume,
	base_name:           string,
	preset:              CSG_Detail_Preset,
	center_local_pos:    [3]f32,
	local_normal:        [3]f32,
	tangent_dir:         [3]f32,
	count:               int,
	spacing:             f32 = 2.0,
	yaw_deg:             f32 = 0.0,
	scale:               [3]f32 = {1, 1, 1},
	color:               [4]u8 = {202, 198, 190, 255},
	pop_debris_on_blast: bool = true,
	custom_mesh:         engine.Asset_GUID = {},
) -> int {
	if vol == nil || count <= 0 do return 0
	t_dir := linalg.normalize0(tangent_dir)
	if linalg.length2(t_dir) < 1e-4 do t_dir = {1, 0, 0}
	step := max(spacing, 0.25)
	half_span := f32(count - 1) * step * 0.5
	added := 0
	for i in 0 ..< count {
		offset := (f32(i) * step) - half_span
		p := center_local_pos + t_dir * offset
		nm := fmt.tprintf("%s_%d", base_name, i + 1)
		if csg_volume_add_detail_instance(vol, nm, preset, p, local_normal, yaw_deg, scale, color, pop_debris_on_blast, custom_mesh) >= 0 {
			added += 1
		}
	}
	return added
}

// Removes an authored `CSG_Detail_Instance` by index from `vol`.
csg_volume_remove_detail_instance :: proc(vol: ^CSGVolume, idx: int) {
	if vol == nil || idx < 0 || idx >= len(vol.detail_instances) do return
	if len(vol.detail_instances[idx].name) > 0 {
		delete(vol.detail_instances[idx].name)
	}
	ordered_remove(&vol.detail_instances, idx)
	csg_volume_repack_gpu_mesh(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// ============================================================================
// PILLAR 3: VALVE-STYLE 2D SHATTERABLE TEMPERED GLASS (`CSG_Glass_Pane`)
// ============================================================================

// Adds a 2D shatterable glass pane (`CSG_Glass_Pane`) to `vol`.
// Automatically computes orthonormal `(u_axis, v_axis)` on the pane plane and registers its
// static Jolt collider on `physics3d.LAYER_GLASS_FENESTRATION` (`3`).
csg_volume_add_glass_pane :: proc(
	vol:             ^CSGVolume,
	name:            string,
	center:          [3]f32,
	size_2d:         [2]f32 = {2.4, 1.6},
	normal:          [3]f32 = {0, 0, 1},
	cells_x:         i32 = 6,
	cells_y:         i32 = 4,
	color:           [4]u8 = {165, 232, 250, 70},
	thickness:       f32 = 0.04,
	material_preset: CSG_Material_Preset = .Tempered_Glass,
	cutout_brush_id: u32 = 0,
) -> int {
	if vol == nil do return -1
	if vol.next_brush_id == 0 do vol.next_brush_id = 1
	id := vol.next_brush_id
	vol.next_brush_id += 1

	n := linalg.normalize0(normal)
	if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
	up_ref := [3]f32{0, 1, 0} if abs(n.y) < 0.92 else [3]f32{0, 0, 1}
	u_ax := linalg.normalize0(linalg.cross(up_ref, n))
	v_ax := linalg.normalize0(linalg.cross(n, u_ax))

	cx := clamp(cells_x, 2, 16)
	cy := clamp(cells_y, 2, 16)
	total_cells := int(cx * cy)
	shattered := make([dynamic]bool, total_cells, runtime.default_allocator())

	use_col := color
	if use_col.a > 140 {
		// Ensure default glass tint is genuinely see-through (~27%..38% opacity)
		row := csg_get_material_row(material_preset)
		if row.opacity < 0.90 {
			use_col = row.base_color
		} else {
			use_col.a = 72
		}
	}

	gp := CSG_Glass_Pane{
		id                   = id,
		name                 = strings.clone(name),
		material_preset      = material_preset,
		center               = center,
		size_2d              = {max(size_2d.x, 0.25), max(size_2d.y, 0.25)},
		thickness            = clamp(thickness, 0.02, 0.25),
		normal               = n,
		u_axis               = u_ax,
		v_axis               = v_ax,
		cells_x              = cx,
		cells_y              = cy,
		color                = use_col,
		cutout_brush_id      = cutout_brush_id,
		shattered_cells      = shattered,
		completely_shattered = false,
		dirty_physics        = true,
	}
	append(&vol.glass_panes, gp)
	if physics3d._state.world_ready {
		csg_sync_glass_pane_physics(vol, &vol.glass_panes[len(vol.glass_panes) - 1])
	}
	csg_volume_repack_gpu_mesh(vol)
	return len(vol.glass_panes) - 1
}

// Adds a custom 3D Polygonal `CSG_Glass_Pane` from a loop of 3D volume-local points (`local_poly_pts`, >= 3 points).
// Optionally carves a matching `.Subtract` `Profile_2D` window hole through `vol` if `carve_wall_hole == true`!
csg_volume_add_poly_glass_pane :: proc(
	vol:             ^CSGVolume,
	name:            string,
	local_poly_pts:  [][3]f32,
	hint_normal:     [3]f32 = {0, 0, 1},
	carve_wall_hole: bool = false,
	wall_thickness:  f32 = 0.65,
	material_preset: CSG_Material_Preset = .Tempered_Glass,
) -> (cut_brush_idx: int, glass_idx: int) {
	cut_brush_idx = -1
	glass_idx     = -1
	if vol == nil || len(local_poly_pts) < 3 do return

	// 1. Compute centroid & best-fit Newell plane normal from `local_poly_pts`
	center: [3]f32
	for p in local_poly_pts do center += p
	center /= f32(len(local_poly_pts))

	newell_n: [3]f32
	m := len(local_poly_pts)
	for i in 0 ..< m {
		a := local_poly_pts[i] - center
		b := local_poly_pts[(i + 1) % m] - center
		newell_n += linalg.cross(a, b)
	}
	n := linalg.normalize0(newell_n)
	if linalg.length2(n) < 1e-4 {
		n = linalg.normalize0(hint_normal)
		if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
	} else if linalg.dot(n, hint_normal) < 0 {
		n = -n
	}

	up_ref := [3]f32{0, 1, 0} if abs(n.y) < 0.92 else [3]f32{0, 0, 1}
	u_ax := linalg.normalize0(linalg.cross(up_ref, n))
	v_ax := linalg.normalize0(linalg.cross(n, u_ax))

	// 2. Project 3D loop into 2D `(u, v)` meters relative to `center`
	poly_2d := make([dynamic][2]f32, 0, m)
	min_uv := [2]f32{ max(f32),  max(f32)}
	max_uv := [2]f32{-max(f32), -max(f32)}
	for p in local_poly_pts {
		rel := p - center
		uv := [2]f32{linalg.dot(rel, u_ax), linalg.dot(rel, v_ax)}
		append(&poly_2d, uv)
		min_uv = linalg.min(min_uv, uv)
		max_uv = linalg.max(max_uv, uv)
	}
	span_2d := linalg.max(max_uv - min_uv, [2]f32{0.25, 0.25})
	mid_uv  := (min_uv + max_uv) * 0.5
	// Recenter `center` to the 2D bounding-box center so `[-half_u..+half_u, -half_v..+half_v]` is symmetric
	center += u_ax * mid_uv.x + v_ax * mid_uv.y
	for &uv in poly_2d {
		uv -= mid_uv
	}

	// 3. Optionally carve a matching `.Subtract` `Profile_2D` brush through the wall!
	cut_id: u32 = 0
	if carve_wall_hole {
		prof_pts := make([]CSG_Profile_Point, len(poly_2d), context.temp_allocator)
		for uv, i in poly_2d {
			prof_pts[i] = CSG_Profile_Point{uv = uv, smooth = false, tension = 0.5}
		}
		depth_n := max(wall_thickness + 0.35, 0.75)
		cut_center := center - n * (depth_n * 0.5)
		cut_brush_idx = csg_volume_add_profile_brush(
			vol,
			fmt.tprintf("%s_PolyCut", name),
			.Subtract,
			cut_center,
			u_ax,
			v_ax,
			n,
			prof_pts,
			depth_n,
			{180, 190, 200, 255},
			true,
			false,
		)
		if cut_brush_idx >= 0 && cut_brush_idx < len(vol.brushes) {
			cut_id = vol.brushes[cut_brush_idx].id
		}
	}

	row := csg_get_material_row(material_preset)
	glass_idx = csg_volume_add_glass_pane(
		vol,
		name,
		center,
		span_2d,
		n,
		6,
		4,
		row.base_color,
		0.04,
		material_preset,
		cut_id,
	)
	if glass_idx >= 0 && glass_idx < len(vol.glass_panes) {
		vol.glass_panes[glass_idx].u_axis         = u_ax
		vol.glass_panes[glass_idx].v_axis         = v_ax
		vol.glass_panes[glass_idx].poly_points_2d = poly_2d
	} else {
		delete(poly_2d)
	}

	if carve_wall_hole {
		csg_volume_rebuild(vol)
	} else {
		csg_volume_repack_gpu_mesh(vol)
	}
	return cut_brush_idx, glass_idx
}

// Carves a boolean `.Subtract` window opening through `vol` at `center` and mounts a paired
// see-through `CSG_Glass_Pane` inside the opening so you can see right through the wall!
// Links `gp.cutout_brush_id` to the cutout brush so moving or resizing the glass pane in the
// editor automatically moves/resizes the boolean window hole too!
csg_volume_add_window_cutout_with_glass :: proc(
	vol:             ^CSGVolume,
	name:            string,
	center:          [3]f32,
	size_2d:         [2]f32 = {2.4, 1.6},
	wall_normal:     [3]f32 = {0, 0, 1},
	wall_thickness:  f32 = 0.60,
	cells_x:         i32 = 6,
	cells_y:         i32 = 4,
	material_preset: CSG_Material_Preset = .Tempered_Glass,
) -> (cut_brush_idx: int, glass_idx: int) {
	if vol == nil do return -1, -1
	n := linalg.normalize0(wall_normal)
	if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
	up_ref := [3]f32{0, 1, 0} if abs(n.y) < 0.92 else [3]f32{0, 0, 1}
	u_ax := linalg.normalize0(linalg.cross(up_ref, n))
	v_ax := linalg.normalize0(linalg.cross(n, u_ax))

	w_u := max(size_2d.x, 0.35)
	h_v := max(size_2d.y, 0.35)
	depth_n := max(wall_thickness + 0.30, 0.70)

	u_abs := [3]f32{abs(u_ax.x), abs(u_ax.y), abs(u_ax.z)}
	v_abs := [3]f32{abs(v_ax.x), abs(v_ax.y), abs(v_ax.z)}
	n_abs := [3]f32{abs(n.x), abs(n.y), abs(n.z)}
	cut_size := u_abs * w_u + v_abs * h_v + n_abs * depth_n

	cut_name := fmt.tprintf("%s_Cutout", name)
	cut_brush_idx = csg_volume_add_brush(
		vol,
		cut_name,
		.Subtract,
		.Box,
		center,
		{max(cut_size.x, 0.2), max(cut_size.y, 0.2), max(cut_size.z, 0.2)},
		0.0,
		{180, 190, 200, 255},
		true,
		false,
	)
	cut_id: u32 = 0
	if cut_brush_idx >= 0 && cut_brush_idx < len(vol.brushes) {
		cut_id = vol.brushes[cut_brush_idx].id
	}

	row := csg_get_material_row(material_preset)
	glass_idx = csg_volume_add_glass_pane(
		vol,
		name,
		center,
		{w_u, h_v},
		n,
		cells_x,
		cells_y,
		row.base_color,
		0.04,
		material_preset,
		cut_id,
	)
	csg_volume_rebuild(vol)
	return cut_brush_idx, glass_idx
}

// Synchronizes a glass pane's paired `.Subtract` window cutout brush (if `gp.cutout_brush_id != 0`)
// when the user edits the glass pane's `center` or `size_2d` in the inspector/drawer.
csg_sync_glass_pane_paired_cutout :: proc(vol: ^CSGVolume, gp: ^CSG_Glass_Pane) -> bool {
	if vol == nil || gp == nil || gp.cutout_brush_id == 0 do return false
	for &b in vol.brushes {
		if b.id == gp.cutout_brush_id && b.op == .Subtract {
			n := linalg.normalize0(gp.normal)
			if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
			u_abs := [3]f32{abs(gp.u_axis.x), abs(gp.u_axis.y), abs(gp.u_axis.z)}
			v_abs := [3]f32{abs(gp.v_axis.x), abs(gp.v_axis.y), abs(gp.v_axis.z)}
			n_abs := [3]f32{abs(n.x), abs(n.y), abs(n.z)}
			depth_n := max(linalg.dot(b.size, n_abs), 0.70)
			ext := u_abs * max(gp.size_2d.x, 0.25) + v_abs * max(gp.size_2d.y, 0.25) + n_abs * depth_n
			b.center = gp.center
			b.size   = {max(ext.x, 0.2), max(ext.y, 0.2), max(ext.z, 0.2)}
			return true
		}
	}
	return false
}

// Removes an authored `CSG_Glass_Pane` by index and destroys its Jolt `LAYER_GLASS_FENESTRATION` body.
csg_volume_remove_glass_pane :: proc(vol: ^CSGVolume, idx: int) {
	if vol == nil || idx < 0 || idx >= len(vol.glass_panes) do return
	_free_glass_pane_runtime(&vol.glass_panes[idx])
	if len(vol.glass_panes[idx].name) > 0 {
		delete(vol.glass_panes[idx].name)
	}
	if vol.glass_panes[idx].poly_points_2d != nil {
		delete(vol.glass_panes[idx].poly_points_2d)
	}
	if vol.glass_panes[idx].shattered_cells != nil {
		delete(vol.glass_panes[idx].shattered_cells)
	}
	if vol.glass_panes[idx].shatter_impacts != nil {
		delete(vol.glass_panes[idx].shatter_impacts)
	}
	ordered_remove(&vol.glass_panes, idx)
	csg_volume_repack_gpu_mesh(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(private = "package")
_free_glass_pane_runtime :: proc(gp: ^CSG_Glass_Pane) {
	if gp == nil do return
	if physics3d.is_body_valid(gp.glass_body) {
		if physics3d._state.world_ready && physics3d._state.body_interface != nil {
			bi := physics3d._state.body_interface
			if jolt.BodyInterface_IsAdded(bi, gp.glass_body) {
				jolt.BodyInterface_RemoveBody(bi, gp.glass_body)
			}
			jolt.BodyInterface_DestroyBody(bi, gp.glass_body)
		}
		gp.glass_body = 0
	}
	if gp.glass_shape != nil {
		if physics3d._state.world_ready {
			delete_key(&physics3d._state.shape_owner, uintptr(gp.glass_shape))
		}
		jolt.Shape_Destroy(gp.glass_shape)
		gp.glass_shape = nil
	}
}

// Synchronizes a `CSG_Glass_Pane`'s static Jolt collider on `physics3d.LAYER_GLASS_FENESTRATION` (`3`).
// - While intact (`< 35%` cells broken), creates a thin oriented static BoxShape body on `LAYER_GLASS_FENESTRATION`
//   so players and dynamic props cannot walk through the unbroken window, while AI Vision (`MASK_VISION_LOS`)
//   sees right through it and Weapon Traces (`MASK_WEAPON_TRACE`) intercept it!
// - Once `>= 35%` of the pane is shattered in RAM, destroys the Jolt body so players can jump through the broken window!
csg_sync_glass_pane_physics :: proc(vol: ^CSGVolume, gp: ^CSG_Glass_Pane) {
	if vol == nil || gp == nil do return
	gp.dirty_physics = false

	_ = physics3d.physics_system()
	if !physics3d._state.world_ready || physics3d._state.body_interface == nil do return

	total_c := max(int(gp.cells_x * gp.cells_y), 1)
	broken_c := 0
	for b in gp.shattered_cells {
		if b do broken_c += 1
	}
	if gp.completely_shattered || len(gp.shatter_impacts) > 0 || f32(broken_c) >= f32(total_c) * 0.35 {
		_free_glass_pane_runtime(gp)
		return
	}

	if physics3d.is_body_valid(gp.glass_body) do return
	if w := engine.ctx_world(); w != nil && vol.physics_world_id == 0 {
		vol.physics_world_id = w.id
	}

	// Build oriented BoxShape in volume-local space
	half_u := max(gp.size_2d.x * 0.5, 0.05)
	half_v := max(gp.size_2d.y * 0.5, 0.05)
	half_n := max(gp.thickness * 0.5, 0.015)

	n := linalg.normalize0(gp.normal)
	if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
	u := linalg.normalize0(gp.u_axis)
	v := linalg.normalize0(gp.v_axis)
	if linalg.length2(u) < 1e-4 || linalg.length2(v) < 1e-4 {
		up_ref := [3]f32{0, 1, 0} if abs(n.y) < 0.92 else [3]f32{0, 0, 1}
		u = linalg.normalize0(linalg.cross(up_ref, n))
		v = linalg.normalize0(linalg.cross(n, u))
	}

	half_ext := [3]f32{half_u, half_v, half_n}
	convex_r := min(f32(0.01), half_n * 0.45)
	box_shape := cast(^jolt.Shape)jolt.BoxShape_Create(&half_ext, convex_r)
	if box_shape == nil do return

	// Orientation matrix with columns (u, v, n)
	rot_m := matrix[3, 3]f32{
		u.x, v.x, n.x,
		u.y, v.y, n.y,
		u.z, v.z, n.z,
	}
	local_q := linalg.quaternion_from_matrix3_f32(rot_m)
	tw := engine.transform_world(vol.owner)
	vol_q := physics3d._world_quat(tw.rotation)
	world_q := linalg.normalize(vol_q * engine.quat_to_native([4]f32{local_q.x, local_q.y, local_q.z, local_q.w}))
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	world_pos := (model * [4]f32{gp.center.x, gp.center.y, gp.center.z, 1.0}).xyz

	bcs := jolt.BodyCreationSettings_Create3(
		box_shape,
		&world_pos,
		&world_q,
		.Static,
		physics3d.LAYER_GLASS_FENESTRATION,
	)
	if bcs == nil {
		jolt.Shape_Destroy(box_shape)
		return
	}
	jolt.BodyCreationSettings_SetFriction(bcs, 0.25)
	jolt.BodyCreationSettings_SetRestitution(bcs, 0.10)
	jolt.BodyCreationSettings_SetUserData(bcs, transmute(u64)engine.Handle(vol.owner))

	gp.glass_shape = box_shape
	gp.glass_body  = jolt.BodyInterface_CreateAndAddBody(physics3d._state.body_interface, bcs, .DontActivate)
	jolt.BodyCreationSettings_Destroy(bcs)
	physics3d._state.shape_owner[uintptr(box_shape)] = engine.Transform_Handle(vol.owner)
}

// Shatters 2D glass cells within `impact_radius` of `world_pos` across all `CSGVolume`s in the active world.
// - Marks hit cells as shattered in RAM (never modifies `.scene` on disk).
// - Spawns falling translucent glass shards on `physics3d.LAYER_DEBRIS_COSMETIC` (`5`).
// - Removes the pane's `LAYER_GLASS_FENESTRATION` Jolt body once `>= 35%` of cells are broken!
csg_damage_glass_at_point :: proc(
	world_pos:     [3]f32,
	impact_radius: f32 = 0.55,
	impulse:       f32 = 8.0,
) -> (shattered_cells_count: int) {
	w := engine.ctx_world()
	if w == nil do return 0

	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || len(vol.glass_panes) == 0 do continue
		tw := engine.transform_world(vol.owner)
		model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		inv_m := linalg.inverse(model)
		lp := (inv_m * [4]f32{world_pos.x, world_pos.y, world_pos.z, 1.0}).xyz

		vol_hit := _damage_volume_glass_panes_local(vol, lp, world_pos, impact_radius, impulse, 9001)
		if vol_hit > 0 {
			shattered_cells_count += vol_hit
			csg_volume_repack_gpu_mesh(vol)
		}
	}
	return shattered_cells_count
}

@(private = "package")
_damage_volume_glass_panes_local :: proc(
	vol:           ^CSGVolume,
	local_pos:     [3]f32,
	world_pos:     [3]f32,
	impact_radius: f32,
	impulse:       f32,
	seed:          u32,
) -> (newly_broken: int) {
	if vol == nil || len(vol.glass_panes) == 0 do return 0
	tw := engine.transform_world(vol.owner)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	rad := max(impact_radius, 0.20)

	for &gp, gp_idx in vol.glass_panes {
		row := csg_get_material_row(gp.material_preset)
		// Consult Material Properties DataTable: if impulse is below `row.yield_blast_force`,
		// the glass/ice pane resists shattering (e.g. Reinforced_Glass requires >= 6.5 impulse!)
		if impulse < row.yield_blast_force {
			continue
		}
		eff_rad := max(rad * row.crater_radius_scale, 0.18)

		cx := max(int(gp.cells_x), 2)
		cy := max(int(gp.cells_y), 2)
		total_c := cx * cy
		if len(gp.shattered_cells) != total_c {
			if gp.shattered_cells != nil do delete(gp.shattered_cells)
			gp.shattered_cells = make([dynamic]bool, total_c, runtime.default_allocator())
		}

		// Check perpendicular distance from `local_pos` to the glass pane plane
		rel := local_pos - gp.center
		plane_d := abs(linalg.dot(rel, gp.normal))
		if plane_d > eff_rad + 0.35 do continue

		u_coord := linalg.dot(rel, gp.u_axis)
		v_coord := linalg.dot(rel, gp.v_axis)
		half_u := gp.size_2d.x * 0.5
		half_v := gp.size_2d.y * 0.5
		if abs(u_coord) > half_u + eff_rad || abs(v_coord) > half_v + eff_rad do continue

		cell_w := gp.size_2d.x / f32(cx)
		cell_h := gp.size_2d.y / f32(cy)
		pane_broken_now := 0

		// Record a localized radial spiderweb fracture hole in `gp.shatter_impacts`
		// so shattering glass punches a realistic jagged spiderweb hole with perimeter shards
		// instead of deleting the entire glass pane from existence!
		hit_u := clamp(u_coord, -half_u * 0.78, half_u * 0.78)
		hit_v := clamp(v_coord, -half_v * 0.78, half_v * 0.78)
		hole_r := clamp(eff_rad * 0.58, 0.16, min(half_u, half_v) * 0.68)
		if gp.shatter_impacts == nil {
			gp.shatter_impacts = make([dynamic][4]f32, 0, 8, runtime.default_allocator())
		}
		merged_existing := false
		for &imp in gp.shatter_impacts {
			du := imp.x - hit_u
			dv := imp.y - hit_v
			if math.sqrt(du * du + dv * dv) < 0.18 {
				imp.z = min(imp.z + hole_r * 0.35, min(half_u, half_v) * 0.76)
				merged_existing = true
				break
			}
		}
		if !merged_existing && len(gp.shatter_impacts) < 10 {
			append(&gp.shatter_impacts, [4]f32{hit_u, hit_v, hole_r, f32((seed + u32(len(gp.shatter_impacts) * 73)) % 1024)})
		}

		for iy in 0 ..< cy {
			for ix in 0 ..< cx {
				c_idx := iy * cx + ix
				if gp.shattered_cells[c_idx] do continue
				cu := -half_u + (f32(ix) + 0.5) * cell_w
				cv := -half_v + (f32(iy) + 0.5) * cell_h
				dist_2d := math.sqrt((cu - u_coord) * (cu - u_coord) + (cv - v_coord) * (cv - v_coord))
				if dist_2d <= eff_rad + max(cell_w, cell_h) * 0.45 {
					gp.shattered_cells[c_idx] = true
					newly_broken += 1
					pane_broken_now += 1

					// Spawn up to 6 falling cosmetic glass shards per impact on `LAYER_DEBRIS_COSMETIC`!
					if vol.spawn_debris && physics3d._state.world_ready && pane_broken_now <= 6 {
						cell_local := gp.center + gp.u_axis * cu + gp.v_axis * cv
						cell_world := (model * [4]f32{cell_local.x, cell_local.y, cell_local.z, 1.0}).xyz
						_spawn_debris_shard(
							cell_world,
							{max(cell_w * 0.32, 0.06), max(cell_h * 0.32, 0.06), 0.025},
							world_pos,
							impulse * 0.65,
							.Box_Primitive,
							seed + u32(gp_idx * 31 + c_idx * 17),
							nil,
						)
					}
				}
			}
		}

		if pane_broken_now == 0 {
			// Ensure at least 1 broken cell count is returned when a spiderweb impact is added
			newly_broken += 1
			pane_broken_now = 1
		}

		if pane_broken_now > 0 {
			// Keep `gp.completely_shattered = false` so the jagged perimeter shards & spiderweb cracks
			// remain visibly mounted in the window frame instead of deleting the glass from existence!
			gp.completely_shattered = false
			csg_sync_glass_pane_physics(vol, &gp)
		}
	}
	return newly_broken
}

// ============================================================================
// RAM-ONLY DESTRUCTION COUPLING & SCENE RECIPE RESET
// ============================================================================

// Checks whether `local_pt` is supported by (within `margin` meters of) any surviving
// `CSG_Convex` hull across all spatial chunks of `vol`.
@(private = "package")
_is_local_point_supported_by_csg :: proc(vol: ^CSGVolume, local_pt: [3]f32, margin: f32 = 0.35) -> bool {
	if vol == nil || len(vol.chunks) == 0 do return false
	for _, ch in vol.chunks {
		if ch == nil do continue
		if local_pt.x < ch.aabb_min.x - margin || local_pt.x > ch.aabb_max.x + margin ||
		   local_pt.y < ch.aabb_min.y - margin || local_pt.y > ch.aabb_max.y + margin ||
		   local_pt.z < ch.aabb_min.z - margin || local_pt.z > ch.aabb_max.z + margin {
			continue
		}
		for h in ch.destructible_hulls {
			if _point_near_convex_hull(h, local_pt, margin) do return true
		}
		for h in ch.indestructible_hulls {
			if _point_near_convex_hull(h, local_pt, margin) do return true
		}
	}
	return false
}

@(private = "file")
_point_near_convex_hull :: #force_inline proc(h: CSG_Convex, pt: [3]f32, margin: f32) -> bool {
	if pt.x < h.aabb_min.x - margin || pt.x > h.aabb_max.x + margin ||
	   pt.y < h.aabb_min.y - margin || pt.y > h.aabb_max.y + margin ||
	   pt.z < h.aabb_min.z - margin || pt.z > h.aabb_max.z + margin {
		return false
	}
	for p in h.planes {
		if linalg.dot(p.normal, pt) - p.dist > margin {
			return false
		}
	}
	return true
}

// Automatically invoked whenever a Geo-Mod blast or 2-Point Clip Plane carves `vol` in RAM:
// 1. Any `CSG_Detail_Instance` inside the blast sphere (`blast_radius + 0.35m`) OR whose anchor point
//    is no longer supported by any surviving CSG hull in `vol.chunks` sets `destroyed_in_ram = true`
//    and pops off as cosmetic debris on `physics3d.LAYER_DEBRIS_COSMETIC` (`5`).
// 2. Any `CSG_Glass_Pane` overlapped by the blast shatters its affected 2D cells in RAM!
@(private = "package")
_csg_apply_blast_to_instances_and_glass :: proc(
	vol:             ^CSGVolume,
	local_blast_pos: [3]f32,
	world_blast_pos: [3]f32,
	blast_radius:    f32,
	blast_impulse:   f32,
	seed:            u32,
	allow_debris:    bool = true,
) {
	if vol == nil do return
	tw := engine.transform_world(vol.owner)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)

	// 1. Pop / hide unsupported or directly blasted `CSG_Detail_Instance` items in RAM
	popped_debris := 0
	for &inst, idx in vol.detail_instances {
		if inst.destroyed_in_ram do continue
		dist := linalg.length(inst.local_pos - local_blast_pos)
		in_blast := (blast_radius > 0.01) && (dist <= blast_radius + 0.35)
		has_support := _is_local_point_supported_by_csg(vol, inst.local_pos, 0.38)
		if in_blast || !has_support {
			inst.destroyed_in_ram = true
			if allow_debris && inst.pop_debris_on_blast && vol.spawn_debris && physics3d._state.world_ready && popped_debris < 6 {
				popped_debris += 1
				inst_world := (model * [4]f32{inst.local_pos.x, inst.local_pos.y, inst.local_pos.z, 1.0}).xyz
				deb_ext := [3]f32{
					clamp(inst.scale.x * 0.35, 0.14, 0.45),
					clamp(inst.scale.y * 0.35, 0.14, 0.45),
					clamp(inst.scale.z * 0.35, 0.14, 0.45),
				}
				_spawn_debris_shard(
					inst_world,
					deb_ext,
					world_blast_pos,
					max(blast_impulse * 0.65, 4.0),
					.Box_Primitive,
					seed + u32(idx * 97 + 13),
					nil,
				)
			}
		}
	}

	// 2. Shatter any `CSG_Glass_Pane` cells within the blast radius in RAM
	if blast_radius > 0.01 && len(vol.glass_panes) > 0 {
		_ = _damage_volume_glass_panes_local(vol, local_blast_pos, world_blast_pos, blast_radius + 0.25, blast_impulse, seed)
	}
}

// Restores all `CSG_Detail_Instance` (`destroyed_in_ram = false`) and all `CSG_Glass_Pane`
// (`shattered_cells = false`, `completely_shattered = false`, re-adds Jolt `LAYER_GLASS_FENESTRATION` collider)
// back to their pristine `.scene` recipe state in RAM!
csg_volume_restore_ram_state :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	for &inst in vol.detail_instances {
		inst.destroyed_in_ram = false
	}
	for &gp in vol.glass_panes {
		gp.completely_shattered = false
		if gp.shatter_impacts != nil {
			clear(&gp.shatter_impacts)
		}
		cx := max(int(gp.cells_x), 2)
		cy := max(int(gp.cells_y), 2)
		total_c := cx * cy
		if len(gp.shattered_cells) != total_c {
			if gp.shattered_cells != nil do delete(gp.shattered_cells)
			gp.shattered_cells = make([dynamic]bool, total_c, runtime.default_allocator())
		} else {
			for i in 0 ..< total_c do gp.shattered_cells[i] = false
		}
		gp.dirty_physics = true
		if physics3d._state.world_ready {
			csg_sync_glass_pane_physics(vol, &gp)
		}
	}
}

// ============================================================================
// BATCHED GPU MESH GENERATOR FOR GOTHIC DETAIL INSTANCES & SHATTERABLE GLASS
// ============================================================================

@(private = "file")
_append_oriented_box :: proc(
	verts:   ^[dynamic]gfx.Vertex,
	indices: ^[dynamic]u32,
	center:  [3]f32,
	u_ax:    [3]f32,
	v_ax:    [3]f32,
	n_ax:    [3]f32,
	half:    [3]f32,
	color:   [4]u8,
	sun_dir: [3]f32,
) {
	faces := [6]struct {
		normal: [3]f32,
		t_u:    [3]f32,
		t_v:    [3]f32,
		ext_n:  f32,
		ext_u:  f32,
		ext_v:  f32,
	}{
		{ n_ax,  u_ax,  v_ax, half.z, half.x, half.y}, // Front (+N)
		{-n_ax, -u_ax,  v_ax, half.z, half.x, half.y}, // Back (-N)
		{ u_ax, -n_ax,  v_ax, half.x, half.z, half.y}, // Right (+U)
		{-u_ax,  n_ax,  v_ax, half.x, half.z, half.y}, // Left (-U)
		{ v_ax,  u_ax, -n_ax, half.y, half.x, half.z}, // Top (+V)
		{-v_ax,  u_ax,  n_ax, half.y, half.x, half.z}, // Bottom (-V)
	}

	has_sun := linalg.length2(sun_dir) > 1e-4
	for f in faces {
		shade: f32 = 1.0
		if has_sun {
			ndotl := linalg.dot(f.normal, sun_dir)
			shade = clamp(0.62 + 0.38 * max(ndotl, -0.35), 0.45, 1.12)
		} else {
			shade = 0.88 + 0.12 * f.normal.y
		}
		fc := [4]u8{
			u8(clamp(f32(color.r) * shade, 0, 255)),
			u8(clamp(f32(color.g) * shade, 0, 255)),
			u8(clamp(f32(color.b) * shade, 0, 255)),
			color.a,
		}
		fc_center := center + f.normal * f.ext_n
		p0 := fc_center - f.t_u * f.ext_u - f.t_v * f.ext_v
		p1 := fc_center + f.t_u * f.ext_u - f.t_v * f.ext_v
		p2 := fc_center + f.t_u * f.ext_u + f.t_v * f.ext_v
		p3 := fc_center - f.t_u * f.ext_u + f.t_v * f.ext_v

		bv := u32(len(verts))
		append(verts,
			gfx.Vertex{position = p0, normal = f.normal, uv = {0, 0}, color = fc},
			gfx.Vertex{position = p1, normal = f.normal, uv = {f.ext_u, 0}, color = fc},
			gfx.Vertex{position = p2, normal = f.normal, uv = {f.ext_u, f.ext_v}, color = fc},
			gfx.Vertex{position = p3, normal = f.normal, uv = {0, f.ext_v}, color = fc},
		)
		append(indices, bv + 0, bv + 1, bv + 2, bv + 0, bv + 2, bv + 3)
	}
}

// Appends all surviving (`!inst.destroyed_in_ram`) procedural architectural kitbash instances
// and all intact 2D `CSG_Glass_Pane` cells of `vol` into `(verts, indices)`.
@(private = "package")
_append_detail_instances_and_glass_to_gpu_mesh :: proc(
	vol:           ^CSGVolume,
	verts:         ^[dynamic]gfx.Vertex,
	indices:       ^[dynamic]u32,
	sun_dir:       [3]f32,
	include_glass: bool = true,
) {
	if vol == nil do return

	// 1. Emit surviving procedural `CSG_Detail_Instance` kitbash geometry
	for inst in vol.detail_instances {
		if inst.destroyed_in_ram || inst.preset == .Custom_Mesh_Asset do continue

		n := linalg.normalize0(inst.local_normal)
		if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
		up_ref := [3]f32{0, 1, 0} if abs(n.y) < 0.92 else [3]f32{0, 0, 1}
		u0 := linalg.normalize0(linalg.cross(up_ref, n))
		v0 := linalg.normalize0(linalg.cross(n, u0))

		rad := inst.yaw_deg * (math.PI / 180.0)
		cs := math.cos(rad)
		sn := math.sin(rad)
		u := u0 * cs + v0 * sn
		v := -u0 * sn + v0 * cs

		s := inst.scale
		p := inst.local_pos
		col := inst.color
		dark_col := [4]u8{
			u8(max(int(col.r) - 28, 20)),
			u8(max(int(col.g) - 28, 20)),
			u8(max(int(col.b) - 26, 20)),
			col.a,
		}

		switch inst.preset {
		case .Gothic_Pillar:
			// Base plinth + tall fluted shaft + corbelled capital
			h := max(s.y * 3.0, 0.6)
			w := max(s.x * 0.42, 0.12)
			d := max(s.z * 0.36, 0.12)
			// Base plinth
			_append_oriented_box(verts, indices, p - v * (h * 0.44) + n * (d * 0.45), u, v, n, {w * 0.68, h * 0.08, d * 0.65}, dark_col, sun_dir)
			// Main shaft + fluted rib
			_append_oriented_box(verts, indices, p + n * (d * 0.40), u, v, n, {w * 0.48, h * 0.42, d * 0.48}, col, sun_dir)
			_append_oriented_box(verts, indices, p + n * (d * 0.65), u, v, n, {w * 0.24, h * 0.40, d * 0.30}, dark_col, sun_dir)
			// Capital
			_append_oriented_box(verts, indices, p + v * (h * 0.44) + n * (d * 0.48), u, v, n, {w * 0.72, h * 0.08, d * 0.68}, dark_col, sun_dir)

		case .Gothic_Pointed_Arch:
			// Left & Right pointed arch ribs meeting at an elevated Gothic keystone
			span := max(s.x * 2.2, 0.8)
			rise := max(s.y * 1.4, 0.5)
			depth := max(s.z * 0.35, 0.12)
			segs :: 4
			for side in -1 ..= 1 {
				if side == 0 do continue
				sgn := f32(side)
				for si in 0 ..< segs {
					t0 := f32(si) / f32(segs)
					t1 := f32(si + 1) / f32(segs)
					tm := (t0 + t1) * 0.5
					ang := tm * (math.PI * 0.42)
					u_off := sgn * span * 0.5 * (1.0 - tm * 0.88)
					v_off := math.sin(ang) * rise
					u_seg := linalg.normalize0(u * (-sgn * math.sin(ang)) + v * math.cos(ang))
					v_seg := linalg.normalize0(linalg.cross(n, u_seg))
					seg_c := p + u * u_off + v * v_off + n * (depth * 0.5)
					_append_oriented_box(verts, indices, seg_c, u_seg, v_seg, n, {0.11 * s.x, (rise / f32(segs)) * 0.62, depth * 0.5}, col, sun_dir)
				}
			}
			// Pointed Keystone at apex
			_append_oriented_box(verts, indices, p + v * (rise * 1.02) + n * (depth * 0.58), u, v, n, {0.18 * s.x, 0.22 * s.y, depth * 0.65}, dark_col, sun_dir)

		case .Wall_Buttress:
			// 3-tier stepped Gothic cathedral flying/wall buttress
			h := max(s.y * 3.2, 0.8)
			w := max(s.x * 0.55, 0.18)
			d := max(s.z * 0.85, 0.25)
			_append_oriented_box(verts, indices, p - v * (h * 0.28) + n * (d * 0.55), u, v, n, {w * 0.55, h * 0.24, d * 0.55}, col, sun_dir)
			_append_oriented_box(verts, indices, p + v * (h * 0.08) + n * (d * 0.38), u, v, n, {w * 0.46, h * 0.22, d * 0.38}, col, sun_dir)
			_append_oriented_box(verts, indices, p + v * (h * 0.36) + n * (d * 0.24), u, v, n, {w * 0.38, h * 0.14, d * 0.24}, dark_col, sun_dir)

		case .Ribbed_Trim_Beam:
			// Horizontal carved stone cornice / frieze beam with lower dentil lip
			w := max(s.x * 2.0, 0.4)
			h := max(s.y * 0.32, 0.10)
			d := max(s.z * 0.28, 0.08)
			_append_oriented_box(verts, indices, p + n * (d * 0.5), u, v, n, {w * 0.5, h * 0.5, d * 0.5}, col, sun_dir)
			_append_oriented_box(verts, indices, p - v * (h * 0.55) + n * (d * 0.32), u, v, n, {w * 0.5, h * 0.22, d * 0.32}, dark_col, sun_dir)

		case .Stone_Cornice_Bracket:
			// Stepped corbel support bracket
			w := max(s.x * 0.36, 0.12)
			h := max(s.y * 0.65, 0.18)
			d := max(s.z * 0.55, 0.16)
			_append_oriented_box(verts, indices, p + v * (h * 0.22) + n * (d * 0.50), u, v, n, {w * 0.5, h * 0.25, d * 0.50}, col, sun_dir)
			_append_oriented_box(verts, indices, p - v * (h * 0.18) + n * (d * 0.28), u, v, n, {w * 0.42, h * 0.22, d * 0.28}, dark_col, sun_dir)

		case .Iron_Window_Grate:
			// Vertical + horizontal wrought-iron window bars
			w := max(s.x * 1.8, 0.4)
			h := max(s.y * 1.4, 0.4)
			bar_r :: f32(0.03)
			iron_col := [4]u8{62, 66, 72, 255}
			for bx in -1 ..= 1 {
				u_pos := f32(bx) * (w * 0.32)
				_append_oriented_box(verts, indices, p + u * u_pos + n * 0.03, u, v, n, {bar_r, h * 0.48, bar_r}, iron_col, sun_dir)
			}
			for by in -1 ..= 1 {
				if by == 0 do continue
				v_pos := f32(by) * (h * 0.28)
				_append_oriented_box(verts, indices, p + v * v_pos + n * 0.03, u, v, n, {w * 0.48, bar_r, bar_r}, iron_col, sun_dir)
			}

		case .Custom_Mesh_Asset:
			// Handled via instanced `Draw_Mesh` commands in `_collect_csg_volumes`
		}
	}

	// 2. If `include_glass` is true, also emit glass panes into `(verts, indices)`
	if include_glass {
		_append_glass_panes_to_gpu_mesh(vol, verts, indices, sun_dir)
	}
}

// Emits Double-Glazed Physical Glass with 3D Parallax Refraction, Sea-Green Cut-Glass Edge Thickness,
// Custom 3D Polygon Boundary Support (`gp.poly_points_2d`), and Radial Spiderweb Fracture (`gp.shatter_impacts`):
// - Eliminates z-fighting by separating the Back Refracted Sheet (`-n * half_t`) and Front Specular Sheet (`+n * half_t`)
//   by physical glass thickness `2 * half_t` (`~3.6 cm`), with Snell-law shifted UVs on the back layer for 3D parallax refraction!
// - Eliminates checkerboard cell squares by rendering intact glass as a continuous smooth double-glazed sheet with
//   perimeter Fresnel glow and a Sea-Green cut-glass internal bevel along every boundary edge.
// - When shattered (`len(gp.shatter_impacts) > 0` or broken cells), punches a localized 12-sector jagged spiderweb hole
//   with radial/concentric crack lines, 3D cut-glass hole rims, and surviving perimeter glass shards instead of deleting the pane!
@(private = "package")
_append_glass_panes_to_gpu_mesh :: proc(
	vol:     ^CSGVolume,
	verts:   ^[dynamic]gfx.Vertex,
	indices: ^[dynamic]u32,
	sun_dir: [3]f32,
) {
	if vol == nil do return
	_ = sun_dir

	for gp in vol.glass_panes {
		if gp.completely_shattered do continue
		half_u := max(gp.size_2d.x * 0.5, 0.12)
		half_v := max(gp.size_2d.y * 0.5, 0.12)
		half_t := clamp(gp.thickness * 0.5, 0.018, 0.045)

		row := csg_get_material_row(gp.material_preset)
		base_col := gp.color
		if base_col.a > 125 {
			base_col.a = u8(clamp(row.opacity * 255.0, 52.0, 96.0))
		}
		// Front Specular Fresnel sheet color (crisp sky-cyan specular tint, ~28% alpha -> 100% see-through)
		front_center_col := [4]u8{base_col.r, base_col.g, base_col.b, clamp(base_col.a, 48, 86)}
		front_edge_col   := [4]u8{
			u8(min(int(base_col.r) + 45, 245)),
			u8(min(int(base_col.g) + 32, 252)),
			255,
			clamp(base_col.a + 26, 74, 118),
		}
		// Back Refracted Sheet color (deep sea-green internal refraction tint, shifted UVs for parallax depth!)
		back_refract_col := [4]u8{
			u8(clamp(int(base_col.r) - 70, 24, 140)),
			u8(clamp(int(base_col.g) - 10, 145, 225)),
			u8(clamp(int(base_col.b) - 15, 155, 235)),
			clamp(base_col.a - 10, 38, 72),
		}
		// Dense Sea-Green Cut-Glass Edge Bevel (visible inside the 3D thickness of the glass sheet & broken rims)
		cut_glass_edge_col := [4]u8{44, 214, 198, 178}
		// Bright crystalline fracture border & spiderweb crack line color
		crack_col := [4]u8{215, 250, 255, 215}
		// Specular diagonal reflection ribbon color
		glint_col := [4]u8{238, 252, 255, 112}
		// Outer structural window frame / mullion border color
		frame_col := [4]u8{46, 58, 70, 235}

		n := linalg.normalize0(gp.normal)
		if linalg.length2(n) < 1e-4 do n = {0, 0, 1}
		u := linalg.normalize0(gp.u_axis)
		v := linalg.normalize0(gp.v_axis)

		// Build the 2D boundary polygon (either custom 3D-drawn polygon `gp.poly_points_2d` or 4-corner rectangle)
		rect_pts := [4][2]f32{
			{-half_u, -half_v},
			{ half_u, -half_v},
			{ half_u,  half_v},
			{-half_u,  half_v},
		}
		poly_pts: [][2]f32 = gp.poly_points_2d[:] if len(gp.poly_points_2d) >= 3 else rect_pts[:]
		num_pts := len(poly_pts)

		// 1. Emit Outer Window Frame Mullions + Internal Sea-Green Cut-Glass Thickness Rim along every polygon edge
		frame_t :: f32(0.032)
		for i in 0 ..< num_pts {
			pA_2d := poly_pts[i]
			pB_2d := poly_pts[(i + 1) % num_pts]
			edge_2d := pB_2d - pA_2d
			edge_len := linalg.length(edge_2d)
			if edge_len < 1e-3 do continue
			dir_2d := edge_2d / edge_len
			inward_2d := [2]f32{-dir_2d.y, dir_2d.x}
			mid_2d := (pA_2d + pB_2d) * 0.5
			if linalg.dot(mid_2d, inward_2d) > 0 {
				inward_2d = -inward_2d
			}

			edge_u := linalg.normalize0(u * dir_2d.x + v * dir_2d.y)
			edge_v := linalg.normalize0(u * inward_2d.x + v * inward_2d.y)
			mid_3d := gp.center + u * mid_2d.x + v * mid_2d.y

			// Outer structural dark frame bar
			_append_oriented_box(
				verts, indices,
				mid_3d - edge_v * (frame_t * 0.35),
				edge_u, edge_v, n,
				{edge_len * 0.5 + frame_t * 0.35, frame_t * 0.45, half_t * 1.25},
				frame_col, sun_dir,
			)

			// Internal Sea-Green Cut-Glass Refractive Bevel (inset just inside the frame, spanning -n*half_t .. +n*half_t)
			in_A_2d := pA_2d + inward_2d * (frame_t * 0.65)
			in_B_2d := pB_2d + inward_2d * (frame_t * 0.65)
			pA_front := gp.center + u * in_A_2d.x + v * in_A_2d.y + n * half_t
			pB_front := gp.center + u * in_B_2d.x + v * in_B_2d.y + n * half_t
			pB_back  := gp.center + u * in_B_2d.x + v * in_B_2d.y - n * half_t
			pA_back  := gp.center + u * in_A_2d.x + v * in_A_2d.y - n * half_t
			bv_rim := u32(len(verts))
			append(verts,
				gfx.Vertex{position = pA_front, normal = edge_v, uv = {0, 0}, color = cut_glass_edge_col},
				gfx.Vertex{position = pB_front, normal = edge_v, uv = {1, 0}, color = cut_glass_edge_col},
				gfx.Vertex{position = pB_back,  normal = edge_v, uv = {1, 1}, color = cut_glass_edge_col},
				gfx.Vertex{position = pA_back,  normal = edge_v, uv = {0, 1}, color = cut_glass_edge_col},
			)
			append(indices, bv_rim + 0, bv_rim + 1, bv_rim + 2, bv_rim + 0, bv_rim + 2, bv_rim + 3)
		}

		// Check if the pane has any shatter damage (`gp.shatter_impacts` or legacy `gp.shattered_cells`)
		has_damage := len(gp.shatter_impacts) > 0
		if !has_damage {
			for b in gp.shattered_cells {
				if b {
					has_damage = true
					break
				}
			}
		}

		// 2A. INTACT GLASS: Continuous Double-Glazed Parallax Sheet (Zero Z-Fighting, Zero Grid Squares!)
		if !has_damage {
			// Helper to map 2D local point -> normalized [0..1] UV
			uv_from_2d :: #force_inline proc(pt: [2]f32, hu, hv: f32) -> [2]f32 {
				return {
					clamp((pt.x + hu) / max(hu * 2.0, 0.01), 0.0, 1.0),
					clamp(1.0 - (pt.y + hv) / max(hv * 2.0, 0.01), 0.0, 1.0),
				}
			}

			// Layer 1: Back Refracted Surface at `-n * half_t` with Snell-law shifted UVs (`+0.065, -0.048`)
			// Because `cull_mode = .NONE` in the renderer, emitting ONE triangle fan at `-n * half_t` and ONE
			// triangle fan at `+n * half_t` (separated by `2 * half_t = 3.6 cm`) guarantees ZERO z-fighting
			// from both viewing sides while creating true 3D double-walled glass depth & parallax refraction!
			refract_uv_shift :: [2]f32{0.065, -0.048}
			bv_back := u32(len(verts))
			append(verts, gfx.Vertex{
				position = gp.center - n * half_t,
				normal   = -n,
				uv       = [2]f32{0.5, 0.5} + refract_uv_shift,
				color    = back_refract_col,
			})
			for i in 0 ..< num_pts {
				pt := poly_pts[i] * 0.985
				uv_p := uv_from_2d(pt, half_u, half_v) * 0.94 + refract_uv_shift
				append(verts, gfx.Vertex{
					position = gp.center + u * pt.x + v * pt.y - n * half_t,
					normal   = -n,
					uv       = uv_p,
					color    = cut_glass_edge_col,
				})
			}
			for i in 0 ..< num_pts {
				next_i := (i + 1) % num_pts
				append(indices, bv_back, bv_back + 1 + u32(next_i), bv_back + 1 + u32(i))
			}

			// Layer 2: Front Specular Fresnel Surface at `+n * half_t`
			bv_front := u32(len(verts))
			append(verts, gfx.Vertex{
				position = gp.center + n * half_t,
				normal   = n,
				uv       = {0.5, 0.5},
				color    = front_center_col,
			})
			for i in 0 ..< num_pts {
				pt := poly_pts[i] * 0.985
				uv_p := uv_from_2d(pt, half_u, half_v)
				append(verts, gfx.Vertex{
					position = gp.center + u * pt.x + v * pt.y + n * half_t,
					normal   = n,
					uv       = uv_p,
					color    = front_edge_col,
				})
			}
			for i in 0 ..< num_pts {
				next_i := (i + 1) % num_pts
				append(indices, bv_front, bv_front + 1 + u32(i), bv_front + 1 + u32(next_i))
			}

			// Layer 3: Two crisp diagonal specular reflection ribbons across the front glass face
			// (offset by +0.0025m outside `+n * half_t` so they never z-fight with the front sheet)
			glint_z := half_t + 0.0025
			for ribbon_i in 0 ..< 2 {
				ru_off := (-0.22 if ribbon_i == 0 else 0.24) * half_u
				rw     := (0.11  if ribbon_i == 0 else 0.055) * half_u
				r_bot_u := clamp(ru_off - half_u * 0.32, -half_u * 0.88, half_u * 0.88)
				r_top_u := clamp(ru_off + half_u * 0.32, -half_u * 0.88, half_u * 0.88)
				r_bot_v := -half_v * 0.86
				r_top_v :=  half_v * 0.86

				g0 := gp.center + u * (r_bot_u - rw) + v * r_bot_v + n * glint_z
				g1 := gp.center + u * (r_bot_u + rw) + v * r_bot_v + n * glint_z
				g2 := gp.center + u * (r_top_u + rw) + v * r_top_v + n * glint_z
				g3 := gp.center + u * (r_top_u - rw) + v * r_top_v + n * glint_z
				bvg := u32(len(verts))
				append(verts,
					gfx.Vertex{position = g0, normal = n, uv = {0.35, 0.9}, color = glint_col},
					gfx.Vertex{position = g1, normal = n, uv = {0.38, 0.9}, color = glint_col},
					gfx.Vertex{position = g2, normal = n, uv = {0.65, 0.1}, color = glint_col},
					gfx.Vertex{position = g3, normal = n, uv = {0.62, 0.1}, color = glint_col},
				)
				append(indices, bvg + 0, bvg + 1, bvg + 2, bvg + 0, bvg + 2, bvg + 3)
			}
			continue
		}

		// 2B. SHATTERED GLASS: Radial Spiderweb Fracture & Jagged Perimeter Shards
		// Instead of deleting the glass pane from existence, each impact punches a 12-sector jagged hole
		// surrounded by a 3D crystalline cut-glass rim, concentric collar shards, and radial spiderweb cracks!
		imp_center := [2]f32{0, 0}
		imp_rad    := min(half_u, half_v) * 0.42
		imp_seed   := f32(137.0)
		if len(gp.shatter_impacts) > 0 {
			last_imp := gp.shatter_impacts[len(gp.shatter_impacts) - 1]
			imp_center = {last_imp.x, last_imp.y}
			imp_rad    = clamp(last_imp.z, 0.15, min(half_u, half_v) * 0.72)
			imp_seed   = last_imp.w
		}

		SECTORS :: 12
		for s_i in 0 ..< SECTORS {
			a0 := (f32(s_i) / f32(SECTORS)) * math.TAU
			a1 := (f32(s_i + 1) / f32(SECTORS)) * math.TAU
			dir0 := [2]f32{math.cos(a0), math.sin(a0)}
			dir1 := [2]f32{math.cos(a1), math.sin(a1)}

			// Deterministic per-sector jaggedness so the hole looks like fractured plate glass
			jitter0 := 0.78 + 0.42 * abs(math.sin(f32(s_i) * 2.73 + imp_seed))
			jitter1 := 0.78 + 0.42 * abs(math.sin(f32((s_i + 1) % SECTORS) * 2.73 + imp_seed))

			// Ray-cast from `imp_center` along `dir` to the pane boundary polygon
			ray_to_poly :: proc(orig, d: [2]f32, pts: [][2]f32, hu, hv: f32) -> [2]f32 {
				best_t := f32(1e6)
				n_pts := len(pts)
				for k in 0 ..< n_pts {
					a := pts[k]
					b := pts[(k + 1) % n_pts]
					e := b - a
					denom := d.x * e.y - d.y * e.x
					if abs(denom) < 1e-6 do continue
					diff := a - orig
					t := (diff.x * e.y - diff.y * e.x) / denom
					u_seg := (diff.x * d.y - diff.y * d.x) / denom
					if t > 0.01 && u_seg >= -0.01 && u_seg <= 1.01 && t < best_t {
						best_t = t
					}
				}
				if best_t > 1e5 {
					return {clamp(orig.x + d.x * hu, -hu, hu), clamp(orig.y + d.y * hv, -hv, hv)}
				}
				return orig + d * (best_t * 0.985)
			}

			outer0 := ray_to_poly(imp_center, dir0, poly_pts, half_u, half_v)
			outer1 := ray_to_poly(imp_center, dir1, poly_pts, half_u, half_v)
			dist_out0 := linalg.length(outer0 - imp_center)
			dist_out1 := linalg.length(outer1 - imp_center)

			r_hole0 := min(imp_rad * jitter0, dist_out0 * 0.72)
			r_hole1 := min(imp_rad * jitter1, dist_out1 * 0.72)
			hole0   := imp_center + dir0 * r_hole0
			hole1   := imp_center + dir1 * r_hole1

			r_mid0  := math.lerp(r_hole0, dist_out0, f32(0.46))
			r_mid1  := math.lerp(r_hole1, dist_out1, f32(0.46))
			mid0    := imp_center + dir0 * r_mid0
			mid1    := imp_center + dir1 * r_mid1

			// 1) Outer Perimeter Ring (`mid0..mid1` -> `outer1..outer0`): always survives anchored to the frame!
			//    Emit both Back Refracted layer (`-n * half_t`) and Front Specular layer (`+n * half_t`)
			p_m0_f := gp.center + u * mid0.x   + v * mid0.y   + n * half_t
			p_m1_f := gp.center + u * mid1.x   + v * mid1.y   + n * half_t
			p_o1_f := gp.center + u * outer1.x + v * outer1.y + n * half_t
			p_o0_f := gp.center + u * outer0.x + v * outer0.y + n * half_t

			p_m0_b := gp.center + u * mid0.x   + v * mid0.y   - n * half_t
			p_m1_b := gp.center + u * mid1.x   + v * mid1.y   - n * half_t
			p_o1_b := gp.center + u * outer1.x + v * outer1.y - n * half_t
			p_o0_b := gp.center + u * outer0.x + v * outer0.y - n * half_t

			bv_out := u32(len(verts))
			append(verts,
				// Back refracted shard quad
				gfx.Vertex{position = p_m0_b, normal = -n, uv = {0.35, 0.35}, color = back_refract_col},
				gfx.Vertex{position = p_m1_b, normal = -n, uv = {0.65, 0.35}, color = back_refract_col},
				gfx.Vertex{position = p_o1_b, normal = -n, uv = {0.85, 0.10}, color = cut_glass_edge_col},
				gfx.Vertex{position = p_o0_b, normal = -n, uv = {0.15, 0.10}, color = cut_glass_edge_col},
				// Front specular shard quad
				gfx.Vertex{position = p_m0_f, normal =  n, uv = {0.30, 0.40}, color = crack_col},
				gfx.Vertex{position = p_m1_f, normal =  n, uv = {0.60, 0.40}, color = crack_col},
				gfx.Vertex{position = p_o1_f, normal =  n, uv = {0.90, 0.05}, color = front_edge_col},
				gfx.Vertex{position = p_o0_f, normal =  n, uv = {0.10, 0.05}, color = front_edge_col},
			)
			append(indices,
				bv_out + 0, bv_out + 2, bv_out + 1, bv_out + 0, bv_out + 3, bv_out + 2,
				bv_out + 4, bv_out + 5, bv_out + 6, bv_out + 4, bv_out + 6, bv_out + 7,
			)

			// 2) Inner Jagged Collar Ring (`hole0..hole1` -> `mid1..mid0`):
			//    Every 3rd sector breaks completely out to make a dramatic jagged tooth silhouette;
			//    surviving teeth tilt slightly (`tilt_n`) to catch specular glints!
			collar_survives := ((s_i + int(imp_seed)) % 3) != 0
			if collar_survives {
				tilt_n := n * (0.008 * math.sin(f32(s_i) * 1.9 + imp_seed))
				p_h0_f := gp.center + u * hole0.x + v * hole0.y + n * half_t + tilt_n
				p_h1_f := gp.center + u * hole1.x + v * hole1.y + n * half_t + tilt_n
				bv_col := u32(len(verts))
				append(verts,
					gfx.Vertex{position = p_h0_f, normal = n, uv = {0.45, 0.55}, color = crack_col},
					gfx.Vertex{position = p_h1_f, normal = n, uv = {0.55, 0.55}, color = crack_col},
					gfx.Vertex{position = p_m1_f, normal = n, uv = {0.65, 0.35}, color = front_center_col},
					gfx.Vertex{position = p_m0_f, normal = n, uv = {0.35, 0.35}, color = front_center_col},
				)
				append(indices, bv_col + 0, bv_col + 1, bv_col + 2, bv_col + 0, bv_col + 2, bv_col + 3)
			}

			// 3) 3D Crystalline Cut-Glass Hole Rim along the broken inner edge (`hole0 -> hole1` or `mid0 -> mid1`)
			rim_a := hole0 if collar_survives else mid0
			rim_b := hole1 if collar_survives else mid1
			ra_f := gp.center + u * rim_a.x + v * rim_a.y + n * half_t
			rb_f := gp.center + u * rim_b.x + v * rim_b.y + n * half_t
			rb_b := gp.center + u * rim_b.x + v * rim_b.y - n * half_t
			ra_b := gp.center + u * rim_a.x + v * rim_a.y - n * half_t
			bv_hr := u32(len(verts))
			append(verts,
				gfx.Vertex{position = ra_f, normal = -u * dir0.x - v * dir0.y, uv = {0, 0}, color = crack_col},
				gfx.Vertex{position = rb_f, normal = -u * dir1.x - v * dir1.y, uv = {1, 0}, color = crack_col},
				gfx.Vertex{position = rb_b, normal = -u * dir1.x - v * dir1.y, uv = {1, 1}, color = cut_glass_edge_col},
				gfx.Vertex{position = ra_b, normal = -u * dir0.x - v * dir0.y, uv = {0, 1}, color = cut_glass_edge_col},
			)
			append(indices, bv_hr + 0, bv_hr + 1, bv_hr + 2, bv_hr + 0, bv_hr + 2, bv_hr + 3)

			// 4) Radial Spiderweb Crack Spoke from the broken rim (`rim_a`) out to the frame (`outer0`)
			spoke_2d := outer0 - rim_a
			spoke_len := linalg.length(spoke_2d)
			if spoke_len > 0.04 {
				spoke_u := linalg.normalize0(u * spoke_2d.x + v * spoke_2d.y)
				spoke_v := linalg.normalize0(linalg.cross(n, spoke_u))
				spoke_mid := gp.center + u * ((rim_a.x + outer0.x) * 0.5) + v * ((rim_a.y + outer0.y) * 0.5)
				_append_oriented_box(
					verts, indices,
					spoke_mid,
					spoke_u, spoke_v, n,
					{spoke_len * 0.5, 0.006, half_t * 1.08},
					crack_col, sun_dir,
				)
			}

			// 5) Concentric Spiderweb Crack Arc connecting `mid0 -> mid1`
			arc_2d := mid1 - mid0
			arc_len := linalg.length(arc_2d)
			if arc_len > 0.03 {
				arc_u := linalg.normalize0(u * arc_2d.x + v * arc_2d.y)
				arc_v := linalg.normalize0(linalg.cross(n, arc_u))
				arc_mid := gp.center + u * ((mid0.x + mid1.x) * 0.5) + v * ((mid0.y + mid1.y) * 0.5)
				_append_oriented_box(
					verts, indices,
					arc_mid,
					arc_u, arc_v, n,
					{arc_len * 0.5, 0.0055, half_t * 1.06},
					crack_col, sun_dir,
				)
			}
		}
	}
}

// ============================================================================
// FAKER CSG RUNTIME (CSG COLLIDER VOLUME `B` + INNER GPU MESH INSTANCE `A`)
// ============================================================================
// Workflow:
// 1. Start with any `CSGVolume` `B` (for example, created via "Turn Mesh into CSG" or CAD brushes).
// 2. Use the Faker CSG Tool (only operates on CSG) to attach any project Mesh asset (`vol.faker_mesh_guid`)
//    as a hardware-instanced visual mesh `A` inside `B` (`vol.is_faker_mesh = true`).
// 3. Adjust `vol.faker_mesh_offset`, `vol.faker_mesh_rot_deg`, and `vol.faker_mesh_scale` (or click Auto-Fit)
//    so the Mesh Instance `A` fits inside the CSGVolume `B`.
// 4. Visibility & Deformation Rule:
//    - While `A` is inside `B`, `A` is rendered as a fast GPU Mesh Instance.
//    - When `B` is sliced, blasted, or dented, `B`'s Jolt collider updates and interior cut surfaces / dents transfer!

// Computes the local-space AABB `[bmin, bmax]` of a `CSGVolume` across all its `runtime_hulls`, `chunks`, or `brushes`.
csg_get_volume_local_aabb :: proc(vol: ^CSGVolume) -> (bmin, bmax: [3]f32, ok: bool) {
	if vol == nil do return {-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}, false
	bmin = { 1e30,  1e30,  1e30}
	bmax = {-1e30, -1e30, -1e30}
	found := false

	for h in vol.runtime_hulls {
		bmin = linalg.min(bmin, h.aabb_min)
		bmax = linalg.max(bmax, ch_or_h_max(h))
		found = true
	}
	if !found && vol.chunks != nil {
		for _, ch in vol.chunks {
			if ch == nil do continue
			for h in ch.destructible_hulls {
				bmin = linalg.min(bmin, h.aabb_min)
				bmax = linalg.max(bmax, h.aabb_max)
				found = true
			}
			for h in ch.indestructible_hulls {
				bmin = linalg.min(bmin, h.aabb_min)
				bmax = linalg.max(bmax, h.aabb_max)
				found = true
			}
		}
	}
	if !found {
		for b in vol.brushes {
			if b.op != .Add do continue
			half := b.size * 0.5
			bmin = linalg.min(bmin, b.center - half)
			bmax = linalg.max(bmax, b.center + half)
			found = true
		}
	}
	if !found {
		return {-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}, false
	}
	return bmin, bmax, true

	ch_or_h_max :: #force_inline proc(h: CSG_Convex) -> [3]f32 {
		return h.aabb_max
	}
}

// Auto-fits the inner Mesh Instance (`vol.faker_mesh_guid`) so its AABB is centered and scaled
// to fit cleanly inside the `CSGVolume`'s local bounds (leaving `vol.faker_margin` clearance).
csg_autofit_faker_mesh_to_volume :: proc(vol: ^CSGVolume) {
	if vol == nil || engine.asset_guid_is_empty(vol.faker_mesh_guid) do return
	if !vol.compiled {
		csg_volume_rebuild(vol)
	}
	csg_min, csg_max, csg_ok := csg_get_volume_local_aabb(vol)
	if !csg_ok do return

	mf := engine.MeshFilter{mesh = engine.PPtr{guid = vol.faker_mesh_guid}}
	mesh, m_ok := engine.mesh_load_filter(&mf)
	if !m_ok do return

	mesh_ext := mesh.aabb_max - mesh.aabb_min
	if mesh_ext.x < 1e-4 && mesh_ext.y < 1e-4 && mesh_ext.z < 1e-4 do return

	csg_center := (csg_min + csg_max) * 0.5
	csg_ext    := csg_max - csg_min
	margin     := clamp(vol.faker_margin, 0.0, 0.25)
	target_ext := [3]f32{
		max(csg_ext.x - margin * 2.0, csg_ext.x * 0.85),
		max(csg_ext.y - margin * 2.0, csg_ext.y * 0.85),
		max(csg_ext.z - margin * 2.0, csg_ext.z * 0.85),
	}

	sx := target_ext.x / max(mesh_ext.x, 1e-3)
	sy := target_ext.y / max(mesh_ext.y, 1e-3)
	sz := target_ext.z / max(mesh_ext.z, 1e-3)
	vol.faker_mesh_scale = {sx, sy, sz}

	mesh_center := (mesh.aabb_min + mesh.aabb_max) * 0.5
	vol.faker_mesh_offset = csg_center - mesh_center * vol.faker_mesh_scale
}

// Ensures a `CSGVolume` configured as a Faker CSG has valid CSG geometry:
// - If `vol` ALREADY has `runtime_hulls` (e.g. from "Turn Mesh into CSG") or `brushes`, preserves them!
// - Only generates a fallback bounding brush if `vol` has zero hulls and zero brushes.
csg_update_faker_mesh_envelope :: proc(vol: ^CSGVolume) {
	if vol == nil || !vol.is_faker_mesh do return

	margin := clamp(vol.faker_margin, 0.005, 0.50)
	vol.faker_margin = margin
	if linalg.length2(vol.faker_mesh_scale) < 1e-4 {
		vol.faker_mesh_scale = {1, 1, 1}
	}

	// If the CSGVolume already has converted mesh hulls (`runtime_hulls`) or authored `brushes`,
	// keep its exact CSG collision geometry intact!
	if len(vol.runtime_hulls) > 0 || len(vol.brushes) > 0 {
		csg_volume_rebuild(vol)
		csg_volume_sync_colliders_only(vol)
		return
	}

	// Fallback only when `vol` has no CSG geometry yet: fit a bounding CSG brush around `faker_mesh_guid`
	half_ext := [3]f32{0.5, 0.5, 0.5}
	center_off := [3]f32{0, 0, 0}
	if !engine.asset_guid_is_empty(vol.faker_mesh_guid) {
		mf := engine.MeshFilter{mesh = engine.PPtr{guid = vol.faker_mesh_guid}}
		if mesh, ok := engine.mesh_load_filter(&mf); ok {
			ext := (mesh.aabb_max - mesh.aabb_min) * 0.5
			if linalg.length2(ext) > 1e-4 {
				half_ext = ext
				center_off = (mesh.aabb_min + mesh.aabb_max) * 0.5
			}
		}
	}

	scale := vol.faker_mesh_scale
	padded_size := [3]f32{
		max(half_ext.x * abs(scale.x) + margin, 0.03) * 2.0,
		max(half_ext.y * abs(scale.y) + margin, 0.03) * 2.0,
		max(half_ext.z * abs(scale.z) + margin, 0.03) * 2.0,
	}
	b_center := center_off * scale + vol.faker_mesh_offset
	row := csg_get_material_row(vol.material_preset)
	_ = csg_volume_add_brush(
		vol,
		"FakerCSG_Hull",
		.Add,
		.Bevel_Box,
		b_center,
		padded_size,
		0.0,
		row.base_color,
		true,
		false,
	)
	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
}

// Attaches a GPU Mesh Instance (`mesh_guid`) inside an existing `CSGVolume` (`vol`),
// converting the `CSGVolume` into a **Faker CSG** without destroying its existing CSG hulls!
csg_attach_mesh_instance_to_csg :: proc(
	vol:       ^CSGVolume,
	mesh_guid: engine.Asset_GUID,
	mat_guid:  engine.Asset_GUID = {},
	auto_fit:  bool              = false,
) -> bool {
	if vol == nil || engine.asset_guid_is_empty(mesh_guid) do return false

	vol.enabled                   = true
	vol.is_faker_mesh             = true
	vol.faker_mesh_guid           = mesh_guid
	if !engine.asset_guid_is_empty(mat_guid) {
		vol.faker_material_guid = mat_guid
	}
	if linalg.length2(vol.faker_mesh_scale) < 1e-4 {
		vol.faker_mesh_scale = {1, 1, 1}
	}
	vol.faker_hide_outer_shell    = true
	vol.faker_render_cut_interior = true
	vol.faker_transfer_dents      = true
	vol.faker_split_on_slice      = true

	// If the same entity still had an enabled standalone MeshRenderer, disable it so the mesh isn't drawn twice
	if vol.owner != {} {
		if _, mr := engine.transform_get_comp(vol.owner, engine.MeshRenderer); mr != nil && mr.enabled {
			if engine.asset_guid_is_empty(vol.faker_material_guid) && len(mr.materials) > 0 {
				vol.faker_material_guid = mr.materials[0]
			}
			mr.enabled = false
		}
	}

	csg_update_faker_mesh_envelope(vol)
	if auto_fit {
		csg_autofit_faker_mesh_to_volume(vol)
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Wraps an entity (`target_h`) that already has a `CSGVolume` (or `MeshFilter`) as a **Faker CSG**.
csg_wrap_mesh_as_faker_csg :: proc(
	target_h:   engine.Transform_Handle,
	shape_kind: CSG_Faker_Shape     = .Auto_Convex_Hull,
	margin:     f32                 = 0.035,
	mat_preset: CSG_Material_Preset = .Steel_Plate,
) -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil || target_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
		return {}
	}

	mesh_guid: engine.Asset_GUID = {}
	mat_guid:  engine.Asset_GUID = {}
	if _, mf := engine.transform_get_comp(target_h, engine.MeshFilter); mf != nil {
		mesh_guid = mf.mesh.guid
		if _, mr := engine.transform_get_comp(target_h, engine.MeshRenderer); mr != nil {
			if len(mr.materials) > 0 {
				mat_guid = mr.materials[0]
			}
			mr.enabled = false
		}
	}

	_, vol := engine.transform_get_comp(target_h, CSGVolume)
	if vol == nil {
		_, ptr := engine.transform_add_comp(target_h, .CSGVolume)
		vol = cast(^CSGVolume)ptr
		if vol != nil {
			reset_CSGVolume(vol)
		}
	}
	if vol == nil do return {}

	if engine.asset_guid_is_empty(mesh_guid) {
		mesh_guid = vol.faker_mesh_guid
	}

	vol.faker_shape_kind = shape_kind
	vol.faker_margin     = clamp(margin, 0.005, 0.50)
	vol.material_preset  = mat_preset
	vol.spawn_debris     = true
	if !engine.asset_guid_is_empty(mesh_guid) {
		_ = csg_attach_mesh_instance_to_csg(vol, mesh_guid, mat_guid, false)
	} else {
		vol.is_faker_mesh = true
		csg_update_faker_mesh_envelope(vol)
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return target_h
}

// ============================================================================
// ZERO-JSON BINARY `.fmesh` ARCHETYPE FORMAT (NO JSON PARSING FOR PROJECTILES!)
// ============================================================================
// Binary `.fmesh` header + serialized CSG convex hulls so any Faker CSG (CSG Collider + Mesh Instance)
// can be saved to disk and spawned at runtime with zero JSON parsing!
CSG_FAKER_BINARY_MAGIC   :: u32(0x484D_4B46) // "FKMH"
CSG_FAKER_BINARY_VERSION :: u32(3)

CSG_Faker_Binary_Archetype_V2 :: struct #packed {
	magic:               u32,
	version:             u32,
	mesh_guid:           engine.Asset_GUID,
	material_guid:       engine.Asset_GUID,
	mesh_scale:          [3]f32,
	mesh_offset:         [3]f32,
	mesh_rot_deg:        [3]f32,
	margin:              f32,
	shape_kind:          CSG_Faker_Shape,
	material_preset:     CSG_Material_Preset,
	hide_outer_shell:    bool,
	render_cut_interior: bool,
	transfer_dents:      bool,
	split_on_slice:      bool,
	is_dynamic_rb:       bool,
	_pad:                u8,
	hull_count:          u32,
}

CSG_Faker_Binary_Archetype :: struct #packed {
	using v2:            CSG_Faker_Binary_Archetype_V2,
	blast_resistance:    f32,
}

@(private = "file")
_cached_faker_archetype: CSG_Faker_Binary_Archetype

// Reads the binary `.fmesh` header (supporting both v2 and v3 `.fmesh` files) for Void File Explorer preview & inspector.
csg_read_faker_binary_header :: proc(path: string) -> (arch: CSG_Faker_Binary_Archetype, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < size_of(CSG_Faker_Binary_Archetype_V2) {
		return {}, false
	}
	v2 := (cast(^CSG_Faker_Binary_Archetype_V2)raw_data(data))^
	if v2.magic != CSG_FAKER_BINARY_MAGIC {
		return {}, false
	}
	if v2.version >= 3 && len(data) >= size_of(CSG_Faker_Binary_Archetype) {
		arch = (cast(^CSG_Faker_Binary_Archetype)raw_data(data))^
		if arch.blast_resistance <= 0.01 do arch.blast_resistance = 1.0
	} else {
		arch.v2 = v2
		arch.blast_resistance = 1.0
	}
	return arch, true
}

// Updates the material preset, blast resistance, slice splitting, and dynamic rigidbody flags directly in a `.fmesh` file on disk.
csg_update_faker_binary_settings :: proc(
	path:             string,
	material_preset:  CSG_Material_Preset,
	blast_resistance: f32,
	split_on_slice:   bool,
	is_dynamic_rb:    bool,
) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < size_of(CSG_Faker_Binary_Archetype_V2) do return false
	v2 := (cast(^CSG_Faker_Binary_Archetype_V2)raw_data(data))^
	if v2.magic != CSG_FAKER_BINARY_MAGIC do return false

	old_hdr_size := size_of(CSG_Faker_Binary_Archetype_V2)
	arch: CSG_Faker_Binary_Archetype
	if v2.version >= 3 && len(data) >= size_of(CSG_Faker_Binary_Archetype) {
		arch = (cast(^CSG_Faker_Binary_Archetype)raw_data(data))^
		old_hdr_size = size_of(CSG_Faker_Binary_Archetype)
	} else {
		arch.v2 = v2
	}
	arch.version          = CSG_FAKER_BINARY_VERSION
	arch.material_preset  = material_preset
	arch.blast_resistance = clamp(blast_resistance, 0.1, 25.0)
	arch.split_on_slice   = split_on_slice
	arch.is_dynamic_rb    = is_dynamic_rb

	tail := data[old_hdr_size:]
	out_buf := make([dynamic]u8, 0, size_of(CSG_Faker_Binary_Archetype) + len(tail), context.temp_allocator)
	hdr_bytes := ([^]u8)(&arch)[:size_of(CSG_Faker_Binary_Archetype)]
	append(&out_buf, ..hdr_bytes)
	append(&out_buf, ..tail)
	return os.write_entire_file(path, out_buf[:]) == nil
}

// Saves a `CSGVolume` Faker CSG (including its inner Mesh Instance transform and its CSG convex hulls)
// as a compact raw binary `.fmesh` file (zero JSON!).
csg_save_faker_mesh_binary :: proc(vol: ^CSGVolume, path: string = "assets/meshes/faker_object.fmesh") -> bool {
	if vol == nil || !vol.is_faker_mesh do return false
	_ = os.make_directory("assets")
	_ = os.make_directory("assets/meshes")

	if !vol.compiled {
		csg_volume_rebuild(vol)
	}
	if len(vol.runtime_hulls) == 0 && len(vol.brushes) > 0 {
		_ = csg_volume_bake_changes(vol)
	}

	arch := CSG_Faker_Binary_Archetype{
		v2 = CSG_Faker_Binary_Archetype_V2{
			magic               = CSG_FAKER_BINARY_MAGIC,
			version             = CSG_FAKER_BINARY_VERSION,
			mesh_guid           = vol.faker_mesh_guid,
			material_guid       = vol.faker_material_guid,
			mesh_scale          = vol.faker_mesh_scale,
			mesh_offset         = vol.faker_mesh_offset,
			mesh_rot_deg        = vol.faker_mesh_rot_deg,
			margin              = vol.faker_margin,
			shape_kind          = vol.faker_shape_kind,
			material_preset     = vol.material_preset,
			hide_outer_shell    = vol.faker_hide_outer_shell,
			render_cut_interior = vol.faker_render_cut_interior,
			transfer_dents      = vol.faker_transfer_dents,
			split_on_slice      = vol.faker_split_on_slice,
			is_dynamic_rb       = vol.is_dynamic_rigidbody,
			hull_count          = u32(len(vol.runtime_hulls)),
		},
		blast_resistance = vol.blast_resistance if vol.blast_resistance > 0.05 else 1.0,
	}
	_cached_faker_archetype = arch

	buf := make([dynamic]u8, 0, size_of(CSG_Faker_Binary_Archetype) + len(vol.runtime_hulls) * 128, context.temp_allocator)
	hdr_bytes := ([^]u8)(&arch)[:size_of(CSG_Faker_Binary_Archetype)]
	append(&buf, ..hdr_bytes)

	for h in vol.runtime_hulls {
		p_count := u32(len(h.planes))
		pc_bytes := ([^]u8)(&p_count)[:size_of(u32)]
		append(&buf, ..pc_bytes)
		for p in h.planes {
			p_copy := p
			pb := ([^]u8)(&p_copy)[:size_of(CSG_Plane)]
			append(&buf, ..pb)
		}
	}

	return os.write_entire_file(path, buf[:]) == nil
}

// Spawns a Faker CSG directly from a binary `.fmesh` file with ZERO JSON parsing!
csg_spawn_faker_mesh_from_binary :: proc(
	world_pos: [3]f32 = {0, 1.6, 0},
	path:      string = "assets/meshes/faker_object.fmesh",
) -> engine.Transform_Handle {
	data, err := os.read_entire_file(path, context.temp_allocator)
	arch := _cached_faker_archetype
	has_file := err == nil && len(data) >= size_of(CSG_Faker_Binary_Archetype_V2)
	hdr_offset := size_of(CSG_Faker_Binary_Archetype_V2)
	if has_file {
		v2 := (cast(^CSG_Faker_Binary_Archetype_V2)raw_data(data))^
		if v2.magic == CSG_FAKER_BINARY_MAGIC {
			if v2.version >= 3 && len(data) >= size_of(CSG_Faker_Binary_Archetype) {
				arch = (cast(^CSG_Faker_Binary_Archetype)raw_data(data))^
				hdr_offset = size_of(CSG_Faker_Binary_Archetype)
			} else {
				arch.v2 = v2
				arch.blast_resistance = 1.0
				hdr_offset = size_of(CSG_Faker_Binary_Archetype_V2)
			}
			_cached_faker_archetype = arch
		}
	}
	if arch.magic != CSG_FAKER_BINARY_MAGIC {
		return {}
	}

	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return {}

	root_h := engine.Transform_Handle(scene.root.handle)
	h := engine.transform_new("FakerCSG_Instance", root_h)
	engine.transform_ensure_unique_name(h)
	if t := engine.pool_get(&w.transforms, engine.Handle(h)); t != nil {
		t.position = world_pos
	}

	_, ptr := engine.transform_add_comp(h, .CSGVolume)
	vol := cast(^CSGVolume)ptr
	if vol == nil do return {}
	reset_CSGVolume(vol)

	vol.enabled                   = true
	vol.is_faker_mesh             = true
	vol.faker_mesh_guid           = arch.mesh_guid
	vol.faker_material_guid       = arch.material_guid
	vol.faker_mesh_scale          = arch.mesh_scale
	vol.faker_mesh_offset         = arch.mesh_offset
	vol.faker_mesh_rot_deg        = arch.mesh_rot_deg
	vol.faker_margin              = clamp(arch.margin, 0.005, 0.25)
	vol.faker_shape_kind          = arch.shape_kind
	vol.material_preset           = arch.material_preset
	vol.blast_resistance          = arch.blast_resistance if arch.blast_resistance > 0.05 else 1.0
	vol.faker_hide_outer_shell    = arch.hide_outer_shell
	vol.faker_render_cut_interior = arch.render_cut_interior
	vol.faker_transfer_dents      = arch.transfer_dents
	vol.faker_split_on_slice      = arch.split_on_slice
	vol.is_dynamic_rigidbody      = arch.is_dynamic_rb
	vol.spawn_debris              = true

	// Restore binary CSG convex hulls if present in the `.fmesh` file
	if has_file && arch.version >= 2 && arch.hull_count > 0 {
		offset := hdr_offset
		alloc := runtime.default_allocator()
		vol.runtime_hulls = make([dynamic]CSG_Convex, 0, int(arch.hull_count), alloc)
		for _ in 0 ..< arch.hull_count {
			if offset + size_of(u32) > len(data) do break
			p_count := (cast(^u32)&data[offset])^
			offset += size_of(u32)
			if p_count == 0 || p_count > 256 || offset + int(p_count) * size_of(CSG_Plane) > len(data) do break
			ch := CSG_Convex{
				planes = make([dynamic]CSG_Plane, int(p_count), alloc),
			}
			for pi in 0 ..< int(p_count) {
				ch.planes[pi] = (cast(^CSG_Plane)&data[offset])^
				offset += size_of(CSG_Plane)
			}
			if convex_rebuild_bounds_and_prune(&ch, prune_redundant = false) {
				append(&vol.runtime_hulls, ch)
			} else {
				convex_destroy(&ch)
			}
		}
	}

	csg_update_faker_mesh_envelope(vol)
	scene.dirty = true
	return h
}

// Sutherland-Hodgman polygon clipper for `[]gfx.Vertex` against half-space `dot(plane.normal, v.position) - plane.dist <= 1e-4`.
@(private = "package")
_clip_vertex_poly_by_plane :: proc(poly_in: []gfx.Vertex, plane: CSG_Plane, poly_out: ^[dynamic]gfx.Vertex) {
	clear(poly_out)
	n := len(poly_in)
	if n < 3 do return

	EPS :: f32(1e-4)
	prev := poly_in[n - 1]
	prev_d := linalg.dot(plane.normal, prev.position) - plane.dist
	prev_in := prev_d <= EPS

	for i in 0 ..< n {
		curr := poly_in[i]
		curr_d := linalg.dot(plane.normal, curr.position) - plane.dist
		curr_in := curr_d <= EPS

		if curr_in {
			if !prev_in {
				denom := prev_d - curr_d
				t := clamp(prev_d / denom, 0.0, 1.0) if abs(denom) > 1e-8 else 0.5
				append(poly_out, _lerp_gfx_vertex(prev, curr, t))
			}
			append(poly_out, curr)
		} else if prev_in {
			denom := prev_d - curr_d
			t := clamp(prev_d / denom, 0.0, 1.0) if abs(denom) > 1e-8 else 0.5
			append(poly_out, _lerp_gfx_vertex(prev, curr, t))
		}

		prev    = curr
		prev_d  = curr_d
		prev_in = curr_in
	}
}

@(private = "package")
_build_unit_cube_fallback_geometry :: proc(alloc := context.temp_allocator) -> (verts: []gfx.Vertex, inds: []u32) {
	v := make([]gfx.Vertex, 24, alloc)
	idx := make([]u32, 36, alloc)
	col := [4]u8{225, 232, 245, 255}
	faces := [6]struct {
		n:   [3]f32,
		pts: [4][3]f32,
	}{
		{{ 0,  1,  0}, {{-0.5,  0.5, -0.5}, {-0.5,  0.5,  0.5}, { 0.5,  0.5,  0.5}, { 0.5,  0.5, -0.5}}},
		{{ 0, -1,  0}, {{-0.5, -0.5, -0.5}, { 0.5, -0.5, -0.5}, { 0.5, -0.5,  0.5}, {-0.5, -0.5,  0.5}}},
		{{ 0,  0,  1}, {{-0.5, -0.5,  0.5}, { 0.5, -0.5,  0.5}, { 0.5,  0.5,  0.5}, {-0.5,  0.5,  0.5}}},
		{{ 0,  0, -1}, {{-0.5, -0.5, -0.5}, {-0.5,  0.5, -0.5}, { 0.5,  0.5, -0.5}, { 0.5, -0.5, -0.5}}},
		{{ 1,  0,  0}, {{ 0.5, -0.5, -0.5}, { 0.5,  0.5, -0.5}, { 0.5,  0.5,  0.5}, { 0.5, -0.5,  0.5}}},
		{{-1,  0,  0}, {{-0.5, -0.5, -0.5}, {-0.5, -0.5,  0.5}, {-0.5,  0.5,  0.5}, {-0.5,  0.5, -0.5}}},
	}
	uvs := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	for f, fi in faces {
		b := u32(fi * 4)
		for k in 0 ..< 4 {
			v[int(b) + k] = gfx.Vertex{position = f.pts[k], normal = f.n, uv = uvs[k], color = col}
		}
		bi := fi * 6
		idx[bi + 0], idx[bi + 1], idx[bi + 2] = b + 0, b + 1, b + 2
		idx[bi + 3], idx[bi + 4], idx[bi + 5] = b + 0, b + 2, b + 3
	}
	return v, idx
}

// Builds & uploads the clipped geometry for a **Faker CSG** (`vol.is_faker_mesh == true`):
//   1. **Rule 1 (`A` inside `B` -> render `A`)**:
//      Clips the triangles of inner visual mesh `A` (`vol.faker_mesh_guid`, transformed by `faker_mesh_offset`,
//      `faker_mesh_rot_deg`, `faker_mesh_scale`) against the active convex hulls of outer CSG collider `B` (`vol`).
//      Uploaded to `make_faker_clipped_guid(vol.owner)`.
//   2. **Rule 2 (`B` inside `A` -> render that part as `B`)**:
//      When `vol.faker_render_cut_interior` is enabled, takes any boundary triangle of `B` whose plane cuts
//      strictly through the interior of `A` (where `A` has vertices on BOTH the front `+` and back `-` sides of the plane,
//      such as a 2-Point Slice plane or a Geo-Mod blast crater), clips it against the 26-DOP convex support planes of `A`,
//      and uploads the resulting interior cross-section cap to `make_faker_cut_cap_guid(vol.owner)`!
@(private = "package")
_upload_faker_clipped_meshes_now :: proc(vol: ^CSGVolume) {
	if vol == nil || vol.owner == {} do return
	a_guid     := make_faker_clipped_guid(vol.owner)
	b_cap_guid := make_faker_cut_cap_guid(vol.owner)

	if !vol.is_faker_mesh {
		engine.mesh_remove_procedural(a_guid)
		engine.mesh_remove_procedural(b_cap_guid)
		return
	}

	scale := vol.faker_mesh_scale
	if linalg.length2(scale) < 1e-4 do scale = {1, 1, 1}
	off := vol.faker_mesh_offset
	rot_deg := vol.faker_mesh_rot_deg

	rx := math.to_radians(rot_deg.x)
	ry := math.to_radians(rot_deg.y)
	rz := math.to_radians(rot_deg.z)
	rot_q := linalg.quaternion_from_euler_angles_f32(ry, rx, rz, .YXZ)
	rot_m := linalg.matrix4_from_quaternion_f32(rot_q)
	local_m := linalg.matrix4_translate_f32(off) * rot_m * linalg.matrix4_scale_f32(scale)

	if gfx.device() != nil {
		_, _ = engine.mesh_load(vol.faker_mesh_guid, 0)
	}
	tmp_mf := engine.MeshFilter{mesh = engine.PPtr{guid = vol.faker_mesh_guid, local_id = 0}}
	src_verts, src_inds, ok := engine.mesh_read_cpu_geometry(&tmp_mf, context.temp_allocator)
	if !ok || len(src_verts) == 0 || len(src_inds) < 3 {
		src_verts, src_inds = _build_unit_cube_fallback_geometry(context.temp_allocator)
	}

	inv_scale := [3]f32{
		1.0 / (scale.x if abs(scale.x) > 1e-4 else 1.0),
		1.0 / (scale.y if abs(scale.y) > 1e-4 else 1.0),
		1.0 / (scale.z if abs(scale.z) > 1e-4 else 1.0),
	}
	a_verts := make([]gfx.Vertex, len(src_verts), context.temp_allocator)
	a_min := [3]f32{ 1e30,  1e30,  1e30}
	a_max := [3]f32{-1e30, -1e30, -1e30}
	for v, i in src_verts {
		p4 := local_m * [4]f32{v.position.x, v.position.y, v.position.z, 1.0}
		ns := v.normal * inv_scale
		n4 := rot_m * [4]f32{ns.x, ns.y, ns.z, 0.0}
		nl := linalg.normalize0(n4.xyz)
		if linalg.length2(nl) < 1e-4 do nl = {0, 1, 0}
		a_verts[i]          = v
		a_verts[i].position = p4.xyz
		a_verts[i].normal   = nl
		a_min = linalg.min(a_min, p4.xyz)
		a_max = linalg.max(a_max, p4.xyz)
	}

	hulls := make([dynamic]CSG_Convex, 0, 16, context.temp_allocator)
	for _, ch in vol.chunks {
		if ch == nil do continue
		append(&hulls, ..ch.destructible_hulls[:])
		append(&hulls, ..ch.indestructible_hulls[:])
	}
	if len(hulls) == 0 && len(vol.runtime_hulls) > 0 {
		append(&hulls, ..vol.runtime_hulls[:])
	}
	if len(hulls) == 0 {
		engine.mesh_remove_procedural(a_guid)
		engine.mesh_remove_procedural(b_cap_guid)
		return
	}

	has_deform := (vol.soft_deform_enabled && len(vol.soft_deform_stamps) > 0) || vol.deform_debug_heatmap
	has_voxel_cuts := csg_volume_has_voxel_cuts(vol)
	all_inside_hulls := !has_deform && len(vol.recorded_blasts) == 0 && !has_voxel_cuts
	if all_inside_hulls {
		for v in a_verts {
			inside_any := false
			for h in hulls {
				if !aabb_overlaps(v.position, v.position, h.aabb_min, h.aabb_max, 8e-3) do continue
				in_h := true
				for p in h.planes {
					if linalg.dot(p.normal, v.position) - p.dist > 8e-3 {
						in_h = false
						break
					}
				}
				if in_h {
					inside_any = true
					break
				}
			}
			if !inside_any {
				all_inside_hulls = false
				break
			}
		}
	}
	if all_inside_hulls {
		// Fast Path: `A` is 100% inside undamaged `B` (single-hull OR multi-hull!) -> draw hardware-instanced `vol.faker_mesh_guid`!
		engine.mesh_remove_procedural(a_guid)
		engine.mesh_remove_procedural(b_cap_guid)
		return
	}

	// =========================================================================
	// SEVERED STEEL O(1) VOXEL SDF FAKER CLIPPER (`has_voxel_cuts == true`)
	// Clips `A` against the continuous trilinear Voxel SDF in O(1) per triangle
	// and caps interior craters using the chunk's `mat_slot == 1` Surface Nets mesh!
	// =========================================================================
	if has_voxel_cuts {
		active_grids := make([dynamic]^CSG_Voxel_Grid, 0, len(vol.chunks), context.temp_allocator)
		min_vox_sz: f32 = 0.08
		for _, ch in vol.chunks {
			if ch != nil && ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
				append(&active_grids, ch.voxel_grid)
				if ch.voxel_grid.voxel_size > 1e-4 && ch.voxel_grid.voxel_size < min_vox_sz {
					min_vox_sz = ch.voxel_grid.voxel_size
				}
			}
		}

		vox_eval_cut_sdf :: proc(pos: [3]f32, grids: []^CSG_Voxel_Grid) -> (sd: f32, is_cut: bool) {
			best_sd: f32 = -1.0
			any_cut := false
			for g in grids {
				if s, cut := csg_voxel_sample_cut_sdf_trilinear(g, pos); cut {
					if !any_cut || s > best_sd {
						best_sd = s
						any_cut = true
					}
				}
			}
			return best_sd, any_cut
		}

		vox_lerp_vert :: #force_inline proc(a, b: gfx.Vertex, t: f32) -> gfx.Vertex {
			tc := clamp(t, 0.0, 1.0)
			return gfx.Vertex{
				position = linalg.lerp(a.position, b.position, tc),
				normal   = linalg.normalize0(linalg.lerp(a.normal, b.normal, tc)),
				uv       = linalg.lerp(a.uv, b.uv, tc),
				color    = {
					u8(clamp(f32(a.color.r) + (f32(b.color.r) - f32(a.color.r)) * tc, 0.0, 255.0)),
					u8(clamp(f32(a.color.g) + (f32(b.color.g) - f32(a.color.g)) * tc, 0.0, 255.0)),
					u8(clamp(f32(a.color.b) + (f32(b.color.b) - f32(a.color.b)) * tc, 0.0, 255.0)),
					u8(clamp(f32(a.color.a) + (f32(b.color.a) - f32(a.color.a)) * tc, 0.0, 255.0)),
				},
			}
		}

		vox_clip_or_subdiv_tri :: proc(
			v0, v1, v2: gfx.Vertex,
			depth:      int,
			min_vox_sz: f32,
			grids:      []^CSG_Voxel_Grid,
			blasts:     []CSG_Recorded_Blast,
			out_v:      ^[dynamic]gfx.Vertex,
			out_i:      ^[dynamic]u32,
		) {
			s0, c0 := vox_eval_cut_sdf(v0.position, grids)
			s1, c1 := vox_eval_cut_sdf(v1.position, grids)
			s2, c2 := vox_eval_cut_sdf(v2.position, grids)
			cm_pos := (v0.position + v1.position + v2.position) * (1.0 / 3.0)
			sm, cm_c := vox_eval_cut_sdf(cm_pos, grids)
			_ = sm

			near_cut := c0 || c1 || c2 || cm_c
			if !near_cut && len(blasts) > 0 {
				t_min := linalg.min(v0.position, linalg.min(v1.position, v2.position))
				t_max := linalg.max(v0.position, linalg.max(v1.position, v2.position))
				for b in blasts {
					r_pad := b.radius * 1.35 + min_vox_sz * 1.5
					b_min := b.local_pos - [3]f32{r_pad, r_pad, r_pad}
					b_max := b.local_pos + [3]f32{r_pad, r_pad, r_pad}
					if aabb_overlaps(t_min, t_max, b_min, b_max, 0.0) {
						near_cut = true
						break
					}
				}
			}

			if !near_cut {
				bv := u32(len(out_v))
				append(out_v, v0, v1, v2)
				append(out_i, bv, bv + 1, bv + 2)
				return
			}

			if depth < 2 {
				e01 := linalg.length(v1.position - v0.position)
				e12 := linalg.length(v2.position - v1.position)
				e20 := linalg.length(v0.position - v2.position)
				max_e := max(e01, max(e12, e20))
				if max_e > min_vox_sz * 1.45 {
					m01 := vox_lerp_vert(v0, v1, 0.5)
					m12 := vox_lerp_vert(v1, v2, 0.5)
					m20 := vox_lerp_vert(v2, v0, 0.5)
					vox_clip_or_subdiv_tri(v0,  m01, m20, depth + 1, min_vox_sz, grids, blasts, out_v, out_i)
					vox_clip_or_subdiv_tri(m01, v1,  m12, depth + 1, min_vox_sz, grids, blasts, out_v, out_i)
					vox_clip_or_subdiv_tri(m20, m12, v2,  depth + 1, min_vox_sz, grids, blasts, out_v, out_i)
					vox_clip_or_subdiv_tri(m01, m12, m20, depth + 1, min_vox_sz, grids, blasts, out_v, out_i)
					return
				}
			}

			// Leaf triangle SDF clipping against `sd <= 0` (solid interior of `B`)
			if s0 > 0.0 && s1 > 0.0 && s2 > 0.0 {
				return
			}
			if s0 <= 0.0 && s1 <= 0.0 && s2 <= 0.0 {
				bv := u32(len(out_v))
				append(out_v, v0, v1, v2)
				append(out_i, bv, bv + 1, bv + 2)
				return
			}

			in_verts := [3]gfx.Vertex{v0, v1, v2}
			in_sds   := [3]f32{s0, s1, s2}
			clipped_poly: [6]gfx.Vertex
			poly_len := 0
			for ei in 0 ..< 3 {
				ej := (ei + 1) % 3
				va, sa := in_verts[ei], in_sds[ei]
				vb, sb := in_verts[ej], in_sds[ej]
				a_in := sa <= 0.0
				b_in := sb <= 0.0
				if a_in && b_in {
					clipped_poly[poly_len] = vb
					poly_len += 1
				} else if a_in && !b_in {
					denom := sa - sb
					t := sa / denom if abs(denom) > 1e-6 else 0.5
					clipped_poly[poly_len] = vox_lerp_vert(va, vb, t)
					poly_len += 1
				} else if !a_in && b_in {
					denom := sa - sb
					t := sa / denom if abs(denom) > 1e-6 else 0.5
					clipped_poly[poly_len] = vox_lerp_vert(va, vb, t)
					poly_len += 1
					clipped_poly[poly_len] = vb
					poly_len += 1
				}
			}
			if poly_len >= 3 {
				bv := u32(len(out_v))
				for k in 0 ..< poly_len {
					append(out_v, clipped_poly[k])
				}
				for k in 0 ..< u32(poly_len - 2) {
					append(out_i, bv, bv + k + 1, bv + k + 2)
				}
			}
		}

		clipped_a_verts := make([dynamic]gfx.Vertex, 0, len(a_verts) * 2, context.temp_allocator)
		clipped_a_inds  := make([dynamic]u32,        0, len(src_inds) * 2, context.temp_allocator)
		tri_n := len(src_inds) / 3
		for ti in 0 ..< tri_n {
			i0, i1, i2 := src_inds[ti * 3 + 0], src_inds[ti * 3 + 1], src_inds[ti * 3 + 2]
			if int(i0) >= len(a_verts) || int(i1) >= len(a_verts) || int(i2) >= len(a_verts) do continue
			vox_clip_or_subdiv_tri(
				a_verts[i0],
				a_verts[i1],
				a_verts[i2],
				0,
				min_vox_sz,
				active_grids[:],
				vol.recorded_blasts[:],
				&clipped_a_verts,
				&clipped_a_inds,
			)
		}

		// Rule 2: Emit interior crater surface (`sm.mat_slot != 0`) from voxel chunks clipped to `A`'s envelope!
		cap_b_verts := make([dynamic]gfx.Vertex, 0, 256, context.temp_allocator)
		cap_b_inds  := make([dynamic]u32,        0, 512, context.temp_allocator)
		if vol.faker_render_cut_interior {
			surviving_a := clipped_a_verts[:] if len(clipped_a_verts) >= 3 else a_verts
			s2 :: f32(0.70710678)
			s3 :: f32(0.57735027)
			dop_dirs := [26][3]f32{
				{+1,  0,  0}, {-1,  0,  0},
				{ 0, +1,  0}, { 0, -1,  0},
				{ 0,  0, +1}, { 0,  0, -1},
				{+s2, +s2,  0}, {-s2, +s2,  0}, {+s2, -s2,  0}, {-s2, -s2,  0},
				{+s2,  0, +s2}, {-s2,  0, +s2}, {+s2,  0, -s2}, {-s2,  0, -s2},
				{ 0, +s2, +s2}, { 0, -s2, +s2}, { 0, +s2, -s2}, { 0, -s2, -s2},
				{+s3, +s3, +s3}, {-s3, +s3, +s3}, {+s3, -s3, +s3}, {-s3, -s3, +s3},
				{+s3, +s3, -s3}, {-s3, -s3, -s3}, {+s3, -s3, -s3}, {-s3, -s3, -s3},
			}
			dop_planes: [26]CSG_Plane
			for d, di in dop_dirs {
				max_d: f32 = -1e30
				for va in surviving_a {
					proj := linalg.dot(d, va.position)
					if proj > max_d do max_d = proj
				}
				dop_planes[di] = CSG_Plane{normal = d, dist = max_d - 0.002}
			}

			// Precompute 64-direction Fibonacci sphere radial support planes around `a_center` in O(N) once!
			FIB_N :: 64
			a_center := (a_min + a_max) * 0.5
			fib_dirs:   [FIB_N][3]f32
			fib_planes: [FIB_N]CSG_Plane
			fib_valid:  [FIB_N]bool
			golden_ratio :: f32(1.61803398875)
			for fi in 0 ..< FIB_N {
				y := 1.0 - (f32(fi) / f32(FIB_N - 1)) * 2.0
				r := math.sqrt(max(0.0, 1.0 - y * y))
				theta := math.TAU * f32(fi) / golden_ratio
				fib_dirs[fi] = {math.cos(theta) * r, y, math.sin(theta) * r}
				fib_planes[fi] = CSG_Plane{normal = fib_dirs[fi], dist = -1e30}
			}
			for va in surviving_a {
				u_va := linalg.normalize0(va.position - a_center)
				if linalg.length2(u_va) < 0.5 do continue
				for fi in 0 ..< FIB_N {
					if linalg.dot(u_va, fib_dirs[fi]) >= 0.90 {
						pr := linalg.dot(fib_dirs[fi], va.position) - 0.002
						if pr > fib_planes[fi].dist {
							fib_planes[fi].dist = pr
							fib_valid[fi]       = true
						}
					}
				}
			}

			c_poly_a := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)
			c_poly_b := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)
			for _, ch in vol.chunks {
				if ch == nil || ch.voxel_grid == nil || !ch.voxel_grid.has_cuts || len(ch.submeshes) < 2 do continue
				// In `csg_voxel_triangulate_chunk`, `ch.submeshes[1]` is the `slot == 1` crater submesh
				sm := ch.submeshes[1]
				end_idx := int(sm.first_index + sm.index_count)
				if end_idx > len(ch.indices) do end_idx = len(ch.indices)
				for idx := int(sm.first_index); idx + 2 < end_idx; idx += 3 {
						ci0, ci1, ci2 := ch.indices[idx + 0], ch.indices[idx + 1], ch.indices[idx + 2]
						if int(ci0) >= len(ch.verts) || int(ci1) >= len(ch.verts) || int(ci2) >= len(ch.verts) do continue
						cv0, cv1, cv2 := ch.verts[ci0], ch.verts[ci1], ch.verts[ci2]
						cv0.color = {255, 255, 255, 255}
						cv1.color = {255, 255, 255, 255}
						cv2.color = {255, 255, 255, 255}

						clear(&c_poly_a)
						append(&c_poly_a, cv0, cv1, cv2)
						for dp in dop_planes {
							_clip_vertex_poly_by_plane(c_poly_a[:], dp, &c_poly_b)
							c_poly_a, c_poly_b = c_poly_b, c_poly_a
							if len(c_poly_a) < 3 do break
						}
						if len(c_poly_a) < 3 do continue

						// Clip against closest Fibonacci radial support plane to trim outer `+faker_margin` lip on curved meshes
						c_mid := (cv0.position + cv1.position + cv2.position) * (1.0 / 3.0)
						u_mid := linalg.normalize0(c_mid - a_center)
						if linalg.length2(u_mid) > 0.5 {
							best_fi  := -1
							best_dot := f32(-1.0)
							for fi in 0 ..< FIB_N {
								if !fib_valid[fi] do continue
								d_fi := linalg.dot(u_mid, fib_dirs[fi])
								if d_fi > best_dot {
									best_dot = d_fi
									best_fi  = fi
								}
							}
							if best_fi >= 0 {
								_clip_vertex_poly_by_plane(c_poly_a[:], fib_planes[best_fi], &c_poly_b)
								c_poly_a, c_poly_b = c_poly_b, c_poly_a
							}
						}

						if len(c_poly_a) >= 3 {
							bv := u32(len(cap_b_verts))
							for pv in c_poly_a do append(&cap_b_verts, pv)
							for k in 0 ..< u32(len(c_poly_a) - 2) {
								append(&cap_b_inds, bv, bv + k + 1, bv + k + 2)
							}
						}
				}
			}
		}

		if len(clipped_a_verts) >= 3 && len(clipped_a_inds) >= 3 {
			up_v: []gfx.Vertex = clipped_a_verts[:]
			up_i: []u32        = clipped_a_inds[:]
			if has_deform && vol.faker_transfer_dents {
				up_v, up_i, _ = csg_tessellate_and_deform_mesh(vol, up_v, up_i, nil, context.temp_allocator)
			}
			engine.mesh_upsert_procedural(a_guid, up_v, up_i, nil, keep_cpu_buffers = true)
		} else {
			engine.mesh_remove_procedural(a_guid)
		}

		if len(cap_b_verts) >= 3 && len(cap_b_inds) >= 3 {
			up_v: []gfx.Vertex = cap_b_verts[:]
			up_i: []u32        = cap_b_inds[:]
			if has_deform {
				up_v, up_i, _ = csg_tessellate_and_deform_mesh(vol, up_v, up_i, nil, context.temp_allocator)
			}
			engine.mesh_upsert_procedural(b_cap_guid, up_v, up_i, nil, keep_cpu_buffers = true)
		} else {
			engine.mesh_remove_procedural(b_cap_guid)
		}
		return
	}

	// =========================================================================
	// EMPTY LIP PRUNER & HULL TIGHTENER ("Hey, you got this complex lip,
	// but there is barely or no mesh in it, well time to slice it off!")
	// =========================================================================
	if vol.faker_prune_empty_lips {
		s2_lip :: f32(0.70710678)
		s3_lip :: f32(0.57735027)
		lip_dirs := [14][3]f32{
			{+1, 0, 0}, {-1, 0, 0},
			{0, +1, 0}, {0, -1, 0},
			{0, 0, +1}, {0, 0, -1},
			{+s3_lip, +s3_lip, +s3_lip}, {-s3_lip, +s3_lip, +s3_lip},
			{+s3_lip, -s3_lip, +s3_lip}, {-s3_lip, -s3_lip, +s3_lip},
			{+s3_lip, +s3_lip, -s3_lip}, {-s3_lip, +s3_lip, -s3_lip},
			{+s3_lip, -s3_lip, -s3_lip}, {-s3_lip, -s3_lip, -s3_lip},
		}
		_ = s2_lip

		prune_poly_a := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)
		prune_poly_b := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)
		tri_total := len(src_inds) / 3

		eval_and_tighten_hull :: proc(
			h:         ^CSG_Convex,
			a_verts:   []gfx.Vertex,
			src_inds:  []u32,
			tri_total: int,
			lip_dirs:  [14][3]f32,
			poly_a:    ^[dynamic]gfx.Vertex,
			poly_b:    ^[dynamic]gfx.Vertex,
		) -> (keep_hull: bool, modified_hull: bool) {
			m_min := [3]f32{ 1e30,  1e30,  1e30}
			m_max := [3]f32{-1e30, -1e30, -1e30}
			dop_max: [14]f32
			for di in 0 ..< 14 do dop_max[di] = -1e30

			tri_cnt := 0
			mesh_area: f32 = 0.0

			for ti in 0 ..< tri_total {
				i0, i1, i2 := src_inds[ti * 3 + 0], src_inds[ti * 3 + 1], src_inds[ti * 3 + 2]
				if int(i0) >= len(a_verts) || int(i1) >= len(a_verts) || int(i2) >= len(a_verts) do continue
				v0, v1, v2 := a_verts[i0], a_verts[i1], a_verts[i2]
				t_min := linalg.min(v0.position, linalg.min(v1.position, v2.position))
				t_max := linalg.max(v0.position, linalg.max(v1.position, v2.position))
				if !aabb_overlaps(t_min, t_max, h.aabb_min, h.aabb_max, 1e-3) do continue

				rejected := false
				all_in   := true
				for p in h.planes {
					d0 := linalg.dot(p.normal, v0.position) - p.dist
					d1 := linalg.dot(p.normal, v1.position) - p.dist
					d2 := linalg.dot(p.normal, v2.position) - p.dist
					if d0 > 1e-4 && d1 > 1e-4 && d2 > 1e-4 {
						rejected = true
						break
					}
					if d0 > 1e-4 || d1 > 1e-4 || d2 > 1e-4 {
						all_in = false
					}
				}
				if rejected do continue

				if all_in {
					e1 := v1.position - v0.position
					e2 := v2.position - v0.position
					a := 0.5 * linalg.length(linalg.cross(e1, e2))
					if a > 1e-7 {
						tri_cnt += 1
						mesh_area += a
						for vp in ([3][3]f32{v0.position, v1.position, v2.position}) {
							m_min = linalg.min(m_min, vp)
							m_max = linalg.max(m_max, vp)
							for d, di in lip_dirs {
								pr := linalg.dot(d, vp)
								if pr > dop_max[di] do dop_max[di] = pr
							}
						}
					}
				} else {
					clear(poly_a)
					append(poly_a, v0, v1, v2)
					for p in h.planes {
						_clip_vertex_poly_by_plane(poly_a[:], p, poly_b)
						poly_a^, poly_b^ = poly_b^, poly_a^
						if len(poly_a) < 3 do break
					}
					if len(poly_a) >= 3 {
						p0 := poly_a[0].position
						poly_a_area: f32 = 0.0
						for k in 1 ..< len(poly_a) - 1 {
							e1 := poly_a[k].position - p0
							e2 := poly_a[k + 1].position - p0
							poly_a_area += 0.5 * linalg.length(linalg.cross(e1, e2))
						}
						if poly_a_area > 1e-7 {
							tri_cnt += 1
							mesh_area += poly_a_area
							for pv in poly_a^ {
								vp := pv.position
								m_min = linalg.min(m_min, vp)
								m_max = linalg.max(m_max, vp)
								for d, di in lip_dirs {
									pr := linalg.dot(d, vp)
									if pr > dop_max[di] do dop_max[di] = pr
								}
							}
						}
					}
				}
			}

			// 1. If there is no mesh (or barely a microscopic sliver `< 2e-5 m^2`) inside this hull, slice the hull off completely!
			if tri_cnt == 0 || mesh_area < 2e-5 {
				return false, true
			}

			// 2. If this hull has an empty lip hanging off past the actual mesh inside `h` by > 1.4cm, slice off that lip!
			hull_span := [6]f32{
				 h.aabb_max.x, -h.aabb_min.x,
				 h.aabb_max.y, -h.aabb_min.y,
				 h.aabb_max.z, -h.aabb_min.z,
			}
			for di in 0 ..< 6 {
				if hull_span[di] - dop_max[di] > 0.014 {
					d := lip_dirs[di]
					tight_dist := dop_max[di] + 0.004
					found_aligned := false
					for &p in h.planes {
						if linalg.dot(p.normal, d) > 0.985 && p.mat_slot == 0 {
							if tight_dist < p.dist - 0.004 {
								p.dist = tight_dist
								modified_hull = true
							}
							found_aligned = true
							break
						}
					}
					if !found_aligned && len(h.planes) < 40 {
						append(&h.planes, CSG_Plane{normal = d, dist = tight_dist, mat_slot = 0, uv_scale = 0.5})
						modified_hull = true
					}
				}
			}
			if modified_hull {
				if !convex_rebuild_bounds_and_prune(h, prune_redundant = false) {
					return false, true
				}
			}
			return true, modified_hull
		}

		any_chunk_pruned := false
		for _, ch in vol.chunks {
			if ch == nil do continue
			ch_mod := false
			for hi := len(ch.destructible_hulls) - 1; hi >= 0; hi -= 1 {
				keep, mod := eval_and_tighten_hull(
					&ch.destructible_hulls[hi],
					a_verts,
					src_inds,
					tri_total,
					lip_dirs,
					&prune_poly_a,
					&prune_poly_b,
				)
				if !keep {
					convex_destroy(&ch.destructible_hulls[hi])
					ordered_remove(&ch.destructible_hulls, hi)
					ch_mod = true
				} else if mod {
					ch_mod = true
				}
			}
			if ch_mod {
				ch.dirty_physics = true
				any_chunk_pruned = true
			}
		}

		if any_chunk_pruned {
			clear(&hulls)
			for _, ch in vol.chunks {
				if ch == nil do continue
				append(&hulls, ..ch.destructible_hulls[:])
				append(&hulls, ..ch.indestructible_hulls[:])
			}
			if len(hulls) == 0 {
				engine.mesh_remove_procedural(a_guid)
				engine.mesh_remove_procedural(b_cap_guid)
				return
			}
		}
	}

	// =========================================================================
	// Pre-classify each hull plane:
	// - Bit 1 (`1`): Internal hull-to-hull partition seam shared between two touching hulls of `B`.
	// - Bit 2 (`2`): True interior cut plane of `B` that slices strictly through `A` (with vertices of `A` on both sides).
	// =========================================================================
	PLANE_FLAG_INTERNAL_SEAM :: u8(1)
	PLANE_FLAG_INTERIOR_CUT  :: u8(2)

	Faker_Cut_Segment :: struct {
		p0, p1: [3]f32,
	}

	hull_plane_flags := make([][]u8, len(hulls), context.temp_allocator)
	cut_plane_segs   := make([][][dynamic]Faker_Cut_Segment, len(hulls), context.temp_allocator)

	for hi in 0 ..< len(hulls) {
		h := hulls[hi]
		hull_plane_flags[hi] = make([]u8, len(h.planes), context.temp_allocator)
		cut_plane_segs[hi]   = make([][dynamic]Faker_Cut_Segment, len(h.planes), context.temp_allocator)
		for pi in 0 ..< len(h.planes) {
			p := h.planes[pi]
			is_seam := false
			// Only uncut partition planes (`p.mat_slot == 0`) can be purely internal seams;
			// cut/slice/blast planes (`p.mat_slot != 0`) must NEVER be ignored as internal seams!
			if p.mat_slot == 0 {
				for hj in 0 ..< len(hulls) {
					if hj == hi do continue
					oh := hulls[hj]
					if !aabb_overlaps(h.aabb_min, h.aabb_max, oh.aabb_min, oh.aabb_max, 0.03) do continue
					for op in oh.planes {
						if linalg.dot(p.normal, op.normal) < -0.985 && abs(p.dist + op.dist) < 0.03 {
							is_seam = true
							break
						}
					}
					if is_seam do break
				}
			}
			if is_seam {
				hull_plane_flags[hi][pi] |= PLANE_FLAG_INTERNAL_SEAM
			} else if vol.faker_render_cut_interior {
				is_cut_plane := (p.mat_slot != 0)
				if !is_cut_plane {
					has_front := false
					has_back  := false
					for va in a_verts {
						sd := linalg.dot(p.normal, va.position) - p.dist
						if sd >  0.008 do has_front = true
						if sd < -0.008 do has_back  = true
						if has_front && has_back do break
					}
					is_cut_plane = has_front && has_back
				}
				if is_cut_plane {
					hull_plane_flags[hi][pi] |= PLANE_FLAG_INTERIOR_CUT
					cut_plane_segs[hi][pi] = make([dynamic]Faker_Cut_Segment, 0, 32, context.temp_allocator)
				}
			}
		}
	}

	// =========================================================================
	// RULE 1: "If A is inside of B, render A"
	// Clip every triangle of `A` against the active convex hulls of `B`.
	// Triangles that bridge across an internal hull-to-hull seam without crossing any exterior/cut plane
	// are emitted unclipped once so zero 1-pixel cracks ever appear along internal hull boundaries!
	// =========================================================================
	clipped_a_verts := make([dynamic]gfx.Vertex, 0, len(a_verts) * 2, context.temp_allocator)
	clipped_a_inds  := make([dynamic]u32,        0, len(src_inds) * 2, context.temp_allocator)
	poly_curr := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)
	poly_next := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)

	tri_n := len(src_inds) / 3
	for ti in 0 ..< tri_n {
		i0, i1, i2 := src_inds[ti * 3 + 0], src_inds[ti * 3 + 1], src_inds[ti * 3 + 2]
		if int(i0) >= len(a_verts) || int(i1) >= len(a_verts) || int(i2) >= len(a_verts) do continue
		v0, v1, v2 := a_verts[i0], a_verts[i1], a_verts[i2]
		t_min := linalg.min(v0.position, linalg.min(v1.position, v2.position))
		t_max := linalg.max(v0.position, linalg.max(v1.position, v2.position))

		// Seam-free bridge check for multi-hull volumes:
		// If all 3 vertices lie inside the union of `hulls` and never cross any non-seam plane of an overlapping hull,
		// emit the original triangle unsplit so internal hull partitions never create a 1-pixel seam!
		if len(hulls) > 1 {
			tv_pos := [3][3]f32{v0.position, v1.position, v2.position}
			verts_in_union := true
			for vp in tv_pos {
				in_any := false
				for h in hulls {
					if !aabb_overlaps(vp, vp, h.aabb_min, h.aabb_max, 4e-3) do continue
					ok_h := true
					for p in h.planes {
						if linalg.dot(p.normal, vp) - p.dist > 4e-3 {
							ok_h = false
							break
						}
					}
					if ok_h {
						in_any = true
						break
					}
				}
				if !in_any {
					verts_in_union = false
					break
				}
			}
			if verts_in_union {
				crosses_cut := false
				outer_cut_chk: for h, hi in hulls {
					if !aabb_overlaps(t_min, t_max, h.aabb_min, h.aabb_max, 1e-3) do continue
					for p, pi in h.planes {
						if (hull_plane_flags[hi][pi] & PLANE_FLAG_INTERNAL_SEAM) != 0 do continue
						if linalg.dot(p.normal, v0.position) - p.dist > 1e-3 ||
						   linalg.dot(p.normal, v1.position) - p.dist > 1e-3 ||
						   linalg.dot(p.normal, v2.position) - p.dist > 1e-3 {
							crosses_cut = true
							break outer_cut_chk
						}
					}
				}
				if !crosses_cut {
					bv := u32(len(clipped_a_verts))
					append(&clipped_a_verts, v0, v1, v2)
					append(&clipped_a_inds, bv, bv + 1, bv + 2)
					continue
				}
			}
		}

		for h, hi in hulls {
			if !aabb_overlaps(t_min, t_max, h.aabb_min, h.aabb_max, 1e-3) do continue

			rejected := false
			all_in   := true
			for p in h.planes {
				d0 := linalg.dot(p.normal, v0.position) - p.dist
				d1 := linalg.dot(p.normal, v1.position) - p.dist
				d2 := linalg.dot(p.normal, v2.position) - p.dist
				if d0 > 1e-4 && d1 > 1e-4 && d2 > 1e-4 {
					rejected = true
					break
				}
				if d0 > 1e-4 || d1 > 1e-4 || d2 > 1e-4 {
					all_in = false
				}
			}
			if rejected do continue

			if all_in {
				bv := u32(len(clipped_a_verts))
				append(&clipped_a_verts, v0, v1, v2)
				append(&clipped_a_inds, bv, bv + 1, bv + 2)
			} else {
				clear(&poly_curr)
				append(&poly_curr, v0, v1, v2)
				for p in h.planes {
					_clip_vertex_poly_by_plane(poly_curr[:], p, &poly_next)
					poly_curr, poly_next = poly_next, poly_curr
					if len(poly_curr) < 3 do break
				}
				if len(poly_curr) >= 3 {
					bv := u32(len(clipped_a_verts))
					for pv in poly_curr do append(&clipped_a_verts, pv)
					fan_n := u32(len(poly_curr) - 2)
					for k in 0 ..< fan_n {
						append(&clipped_a_inds, bv, bv + k + 1, bv + k + 2)
					}

					// Record exact clipped boundary segments lying on any active interior cut plane of `h`
					if vol.faker_render_cut_interior {
						pn := len(poly_curr)
						for m in 0 ..< pn {
							pa := poly_curr[m].position
							pb := poly_curr[(m + 1) % pn].position
							if linalg.length2(pb - pa) < 1e-10 do continue
							for p, pi in h.planes {
								if (hull_plane_flags[hi][pi] & PLANE_FLAG_INTERIOR_CUT) == 0 do continue
								if abs(linalg.dot(p.normal, pa) - p.dist) <= 6e-4 &&
								   abs(linalg.dot(p.normal, pb) - p.dist) <= 6e-4 {
									append(&cut_plane_segs[hi][pi], Faker_Cut_Segment{p0 = pa, p1 = pb})
								}
							}
						}
					}
				}
			}
		}
	}

	// =========================================================================
	// RULE 2: "If any part of B cuts inside A, render that part as B"
	// Extracts the solid 3D cut & Geo-Mod blast crater faces of `B` (after exact sibling-hull seam subtraction)
	// and clips their outer perimeter tightly to `A`'s surface envelope so:
	//   1. Both 2-Point Slices AND 3D concave Geo-Mod Blast Craters are 100% SOLIDLY FILLED IN with texture
	//      (even when `A` is a hollow thin-shell mesh like `DamagedHelmet.glb`!), and
	//   2. Zero outer fin ever protrudes past `A`'s outer surface!
	// =========================================================================
	cap_b_verts := make([dynamic]gfx.Vertex, 0, 128, context.temp_allocator)
	cap_b_inds  := make([dynamic]u32,        0, 256, context.temp_allocator)

	if vol.faker_render_cut_interior {
		planar_uv_for_plane :: proc(pos: [3]f32, n: [3]f32, uv_scale: f32) -> [2]f32 {
			s := uv_scale if uv_scale > 1e-4 else 0.5
			an := [3]f32{abs(n.x), abs(n.y), abs(n.z)}
			if an.y >= an.x && an.y >= an.z {
				return {pos.x * s, pos.z * s}
			} else if an.x >= an.y && an.x >= an.z {
				return {pos.z * s, pos.y * s}
			}
			return {pos.x * s, pos.y * s}
		}

		// 1. Precompute Global 26-DOP support planes of surviving `A` (`clipped_a_verts` if non-empty, else `a_verts`, inset by `-0.002m`)
		surviving_a := clipped_a_verts[:] if len(clipped_a_verts) >= 3 else a_verts
		s2 :: f32(0.70710678)
		s3 :: f32(0.57735027)
		dop_dirs := [26][3]f32{
			{+1,  0,  0}, {-1,  0,  0},
			{ 0, +1,  0}, { 0, -1,  0},
			{ 0,  0, +1}, { 0,  0, -1},
			{+s2, +s2,  0}, {-s2, +s2,  0}, {+s2, -s2,  0}, {-s2, -s2,  0},
			{+s2,  0, +s2}, {-s2,  0, +s2}, {+s2,  0, -s2}, {-s2,  0, -s2},
			{ 0, +s2, +s2}, { 0, -s2, +s2}, { 0, +s2, -s2}, { 0, -s2, -s2},
			{+s3, +s3, +s3}, {-s3, +s3, +s3}, {+s3, -s3, +s3}, {-s3, -s3, +s3},
			{+s3, +s3, -s3}, {-s3, +s3, -s3}, {+s3, -s3, -s3}, {-s3, -s3, -s3},
		}
		dop_planes: [26]CSG_Plane
		for d, di in dop_dirs {
			max_d: f32 = -1e30
			for va in surviving_a {
				proj := linalg.dot(d, va.position)
				if proj > max_d do max_d = proj
			}
			dop_planes[di] = CSG_Plane{normal = d, dist = max_d - 0.002}
		}

		a_center := (a_min + a_max) * 0.5
		a_unit_dirs := make([][3]f32, len(surviving_a), context.temp_allocator)
		for va, vi in surviving_a {
			a_unit_dirs[vi] = linalg.normalize0(va.position - a_center)
		}

		// 2. Extract all visible, seam-subtracted polygons of `B` across `hulls`
		clean_b_faces := make([dynamic]CSG_Face_Poly, 0, len(hulls) * 6, context.temp_allocator)
		csg_extract_clean_polygons_from_hulls(hulls[:], &clean_b_faces, context.temp_allocator)

		poly_buf_a := make([dynamic][3]f32, 0, 32, context.temp_allocator)
		poly_buf_b := make([dynamic][3]f32, 0, 32, context.temp_allocator)
		slice_pts  := make([dynamic][3]f32, 0, 64, context.temp_allocator)

		for fp in clean_b_faces {
			if len(fp.verts) < 3 do continue
			fp_dist := linalg.dot(fp.normal, fp.verts[0])

			// Gather any exact clipped boundary points of `A` lying on `(fp.normal, fp_dist)`
			clear(&slice_pts)
			for hi in 0 ..< len(hulls) {
				h := hulls[hi]
				for p, pi in h.planes {
					if len(cut_plane_segs[hi][pi]) == 0 do continue
					if linalg.dot(p.normal, fp.normal) > 0.995 && abs(p.dist - fp_dist) < 0.01 {
						for seg in cut_plane_segs[hi][pi] {
							append(&slice_pts, seg.p0, seg.p1)
						}
					}
				}
			}

			// Include this face if it is an explicit cut/slice/blast face (`fp.mat_slot != 0`)
			// OR if it actively sliced `A`'s triangles (`len(slice_pts) >= 4`).
			if fp.mat_slot == 0 && len(slice_pts) < 4 do continue

			clear(&poly_buf_a)
			append(&poly_buf_a, ..fp.verts[:])

			// Filter A: Clip against Global 26-DOP of `A`
			for dp in dop_planes {
				clip_polygon_by_plane(poly_buf_a[:], dp, &poly_buf_b)
				poly_buf_a, poly_buf_b = poly_buf_b, poly_buf_a
				if len(poly_buf_a) < 3 do break
			}
			if len(poly_buf_a) < 3 do continue

			// Filter B: If `(fp.normal, fp_dist)` is an outer slice plane of `B` (no hull of `B` lies in front of it)
			// and we have exact clipped perimeter points `slice_pts` of `A` on that slice plane, clip `poly_buf_a`
			// against the tight 24-direction 2D cross-section support envelope of `slice_pts`!
			is_outer_slice_plane := true
			outer_plane_chk: for h in hulls {
				if linalg.dot(fp.normal, h.centroid) - fp_dist > 0.02 {
					is_outer_slice_plane = false
					break outer_plane_chk
				}
			}
			if is_outer_slice_plane && len(slice_pts) >= 4 {
				u_ax, v_ax := plane_tangent_basis(fp.normal)
				for dir_i in 0 ..< 24 {
					ang := f32(dir_i) * (math.TAU / 24.0)
					d_2d := linalg.normalize0(u_ax * math.cos(ang) + v_ax * math.sin(ang))
					max_2d: f32 = -1e30
					for sp in slice_pts {
						proj := linalg.dot(d_2d, sp)
						if proj > max_2d do max_2d = proj
					}
					clip_polygon_by_plane(poly_buf_a[:], CSG_Plane{normal = d_2d, dist = max_2d - 0.0005}, &poly_buf_b)
					poly_buf_a, poly_buf_b = poly_buf_b, poly_buf_a
					if len(poly_buf_a) < 3 do break
				}
			}
			if len(poly_buf_a) < 3 do continue

			// Filter C: Local Radial Cone Support from `a_center`
			// Trims any outer `+faker_margin` overhang on curved or concave surfaces (like the helmet dome/cheek/visor)
			// while keeping 100% of the concave 3D Geo-Mod crater interior inside `A`!
			sample_dirs := make([dynamic][3]f32, 0, len(poly_buf_a) * 2, context.temp_allocator)
			pn_cur := len(poly_buf_a)
			for k in 0 ..< pn_cur {
				va_p := poly_buf_a[k]
				vb_p := poly_buf_a[(k + 1) % pn_cur]
				u1 := linalg.normalize0(va_p - a_center)
				u2 := linalg.normalize0((va_p + vb_p) * 0.5 - a_center)
				if linalg.length2(u1) > 0.5 do append(&sample_dirs, u1)
				if linalg.length2(u2) > 0.5 do append(&sample_dirs, u2)
			}
			for u_dir in sample_dirs {
				cone_max_d: f32 = -1e30
				found_in_cone := false
				for va, vi in surviving_a {
					if linalg.dot(a_unit_dirs[vi], u_dir) >= 0.93 {
						proj := linalg.dot(u_dir, va.position)
						if proj > cone_max_d {
							cone_max_d = proj
							found_in_cone = true
						}
					}
				}
				if found_in_cone {
					clip_polygon_by_plane(poly_buf_a[:], CSG_Plane{normal = u_dir, dist = cone_max_d - 0.002}, &poly_buf_b)
					poly_buf_a, poly_buf_b = poly_buf_b, poly_buf_a
					if len(poly_buf_a) < 3 do break
				}
			}

			if len(poly_buf_a) >= 3 && polygon_area(poly_buf_a[:]) > 1e-5 {
				// Emit solid triangulated cut/crater polygon with pure neutral white vertex color `{255, 255, 255, 255}`
				// so the assigned Cut Texture (or fallback Mesh Texture) renders cleanly without muddy vertex darkening!
				bv := u32(len(cap_b_verts))
				for pt in poly_buf_a {
					append(&cap_b_verts, gfx.Vertex{
						position = pt,
						normal   = fp.normal,
						uv       = planar_uv_for_plane(pt, fp.normal, fp.uv_scale),
						color    = {255, 255, 255, 255},
					})
				}
				fan_n := u32(len(poly_buf_a) - 2)
				for k in 0 ..< fan_n {
					append(&cap_b_inds, bv, bv + k + 1, bv + k + 2)
				}
			}
		}
	}

	if len(clipped_a_verts) >= 3 && len(clipped_a_inds) >= 3 {
		up_v: []gfx.Vertex = clipped_a_verts[:]
		up_i: []u32        = clipped_a_inds[:]
		if has_deform && vol.faker_transfer_dents {
			up_v, up_i, _ = csg_tessellate_and_deform_mesh(vol, up_v, up_i, nil, context.temp_allocator)
		}
		engine.mesh_upsert_procedural(a_guid, up_v, up_i, nil, keep_cpu_buffers = true)
	} else {
		engine.mesh_remove_procedural(a_guid)
	}

	if len(cap_b_verts) >= 3 && len(cap_b_inds) >= 3 {
		up_v: []gfx.Vertex = cap_b_verts[:]
		up_i: []u32        = cap_b_inds[:]
		if has_deform {
			up_v, up_i, _ = csg_tessellate_and_deform_mesh(vol, up_v, up_i, nil, context.temp_allocator)
		}
		engine.mesh_upsert_procedural(b_cap_guid, up_v, up_i, nil, keep_cpu_buffers = true)
	} else {
		engine.mesh_remove_procedural(b_cap_guid)
	}
}

// Emits render commands for a `CSGVolume` configured as a **Faker CSG** (`vol.is_faker_mesh == true`):
// - Rule 1 ("If A is inside of B, render A"):
//   - When `B` is undamaged and `A` lies 100% inside `B`, emits `vol.faker_mesh_guid` as a fast hardware instance.
//   - When `B` is sliced, boolean-blasted, or soft-deformed, emits `make_faker_clipped_guid(vol.owner)` (`A` clipped to `B`).
// - Rule 2 ("If any part of B cuts inside A, render that part as B"):
//   - Emits `make_faker_cut_cap_guid(vol.owner)` (`B`'s interior cut faces clipped strictly to `A`),
//     while keeping the outer CSG shell of `B` hidden whenever `vol.faker_hide_outer_shell == true`!
@(private = "package")
_collect_faker_mesh_commands :: proc(
	vol:       ^CSGVolume,
	owner_h:   engine.Transform_Handle,
	model_mat: matrix[4, 4]f32,
	var_mats:  []engine.Asset_GUID,
	out:       ^[dynamic]engine.Render_Command,
) -> (skip_outer_csg_chunks: bool) {
	if vol == nil || !vol.is_faker_mesh || engine.asset_guid_is_empty(vol.faker_mesh_guid) {
		return false
	}

	// Resolve materials slice for inner mesh `A`
	mats_a := var_mats
	if !engine.asset_guid_is_empty(vol.faker_material_guid) {
		custom_slice := make([]engine.Asset_GUID, 1, context.temp_allocator)
		custom_slice[0] = vol.faker_material_guid
		mats_a = custom_slice
	}

	a_guid     := make_faker_clipped_guid(vol.owner)
	b_cap_guid := make_faker_cut_cap_guid(vol.owner)
	has_clipped_a := !engine.asset_guid_is_empty(a_guid) && engine.mesh_is_cached(a_guid)
	has_cut_cap_b := !engine.asset_guid_is_empty(b_cap_guid) && engine.mesh_is_cached(b_cap_guid)

	if has_clipped_a || has_cut_cap_b {
		if has_clipped_a {
			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh          = a_guid,
					part          = 0,
					model         = model_mat,
					materials     = mats_a,
					unlit_heatmap = vol.deform_debug_heatmap,
					no_shadow     = !vol.cast_planar_shadows,
				},
			})
		}
		if has_cut_cap_b {
			// Cut / Crater Interior Material Resolution:
			// 1. If an explicit override cut material/texture is set (`vol.faker_cut_material_guid`, e.g. Magic Sword slash or burn), use it!
			// 2. Otherwise (Default Fallback), use `mats_a` (the Faker Mesh's own material/texture, e.g. white marble wall or helmet texture)!
			mats_b := mats_a
			if !engine.asset_guid_is_empty(vol.faker_cut_material_guid) {
				cut_slice := make([]engine.Asset_GUID, 1, context.temp_allocator)
				cut_slice[0] = vol.faker_cut_material_guid
				mats_b = cut_slice
			}
			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh          = b_cap_guid,
					part          = 0,
					model         = model_mat,
					materials     = mats_b,
					unlit_heatmap = vol.deform_debug_heatmap,
					no_shadow     = !vol.cast_planar_shadows,
				},
			})
		}
		return vol.faker_hide_outer_shell
	}

	// Compute local instance transform for undamaged visual mesh `A` inside CSG envelope `B`
	scale := vol.faker_mesh_scale
	if linalg.length2(scale) < 1e-4 do scale = {1, 1, 1}
	off := vol.faker_mesh_offset
	rot_deg := vol.faker_mesh_rot_deg

	rx := math.to_radians(rot_deg.x)
	ry := math.to_radians(rot_deg.y)
	rz := math.to_radians(rot_deg.z)
	rot_q := linalg.quaternion_from_euler_angles_f32(ry, rx, rz, .YXZ)
	local_m := linalg.matrix4_translate_f32(off) * linalg.matrix4_from_quaternion_f32(rot_q) * linalg.matrix4_scale_f32(scale)
	inst_world_m := model_mat * local_m

	// Emit Hardware-Instanced `Draw_Mesh` command for undamaged visual mesh `A`!
	append(out, engine.Render_Command{
		owner   = owner_h,
		variant = engine.Draw_Mesh{
			mesh          = vol.faker_mesh_guid,
			part          = 0,
			model         = inst_world_m,
			materials     = mats_a,
			unlit_heatmap = vol.deform_debug_heatmap,
			no_shadow     = !vol.cast_planar_shadows,
		},
	})

	return vol.faker_hide_outer_shell
}

