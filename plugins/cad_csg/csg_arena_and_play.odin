package cad_csg

// Raycasting, Play-Mode Geo-Mod Blaster, Automatic Deserialization Rebuild,
// and Scene Composition Brush Detach / Split Utilities.

import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:fmt"
import engine "haati:engine"
import input "haati:engine/input"

// Computes the combined local-space AABB of all chunks in `vol`.
csg_volume_local_aabb :: proc(vol: ^CSGVolume) -> (lo, hi: [3]f32, ok: bool) {
	if vol == nil do return {}, {}, false
	if !vol.compiled {
		csg_volume_rebuild(vol)
	}
	first := true
	for _, ch in vol.chunks {
		if len(ch.verts) == 0 do continue
		if first {
			lo = ch.aabb_min
			hi = ch.aabb_max
			first = false
		} else {
			lo.x = min(lo.x, ch.aabb_min.x)
			lo.y = min(lo.y, ch.aabb_min.y)
			lo.z = min(lo.z, ch.aabb_min.z)
			hi.x = max(hi.x, ch.aabb_max.x)
			hi.y = max(hi.y, ch.aabb_max.y)
			hi.z = max(hi.z, ch.aabb_max.z)
		}
	}
	return lo, hi, !first
}

// Exact raycast against all compiled `CSGVolume` spatial chunks in the active world.
// Uses each 8m^3 chunk's CPU vertex/index buffers directly (with per-chunk AABB culling),
// so it never depends on GPU buffer state or `mesh_load`.
csg_raycast_world :: proc(ray: engine.Ray) -> (hit_pos: [3]f32, hit_normal: [3]f32, hit_t: f32, hit_vol: ^CSGVolume, hit_brush_idx: int, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return {}, {0, 1, 0}, 0, nil, -1, false

	best_t := max(f32)
	hit_brush_idx = -1

	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || !engine.transform_active_in_hierarchy(vol.owner) do continue
		if !vol.compiled {
			csg_volume_rebuild(vol)
		}
		if len(vol.chunks) == 0 do continue

		tw := engine.transform_world(vol.owner)
		model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		inv_m := linalg.inverse(model)
		lo4 := inv_m * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1.0}
		ld4 := inv_m * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0.0}
		local_ray := engine.Ray{origin = lo4.xyz, direction = ld4.xyz}

		for _, ch in vol.chunks {
			if len(ch.indices) < 3 do continue
			if _, aabb_hit := engine.ray_hit_aabb(local_ray, ch.aabb_min, ch.aabb_max); !aabb_hit {
				continue
			}

			tri_count := len(ch.indices) / 3
			for ti in 0 ..< tri_count {
				i0 := ch.indices[ti * 3 + 0]
				i1 := ch.indices[ti * 3 + 1]
				i2 := ch.indices[ti * 3 + 2]
				v0 := ch.verts[i0].position
				v1 := ch.verts[i1].position
				v2 := ch.verts[i2].position
				ln := linalg.normalize0(linalg.cross(v1 - v0, v2 - v0))
				if linalg.length2(ln) < 0.25 {
					ln = ch.verts[i0].normal
				}
				// Skip back-facing triangles so clicking an exterior face never picks an interior/opposite face
				if linalg.dot(ln, local_ray.direction) > 0.15 do continue

				if tt, th := engine.ray_hit_triangle(local_ray, v0, v1, v2); th && tt > 0.001 && tt < best_t {
					best_t = tt
					local_hit := local_ray.origin + local_ray.direction * tt
					wh4 := model * [4]f32{local_hit.x, local_hit.y, local_hit.z, 1.0}
					hit_pos = wh4.xyz
					wn4 := model * [4]f32{ln.x, ln.y, ln.z, 0.0}
					hit_normal = linalg.normalize0(wn4.xyz)
					hit_t = tt
					hit_vol = vol
					ok = true

					// Identify which authored brush in `brush_aabbs` owns this surface face
					hit_brush_idx = -1
					best_face_err := f32(1e9)
					for b_idx := len(vol.brush_aabbs) - 1; b_idx >= 0; b_idx -= 1 {
						b_aabb := vol.brush_aabbs[b_idx]
						if local_hit.x < b_aabb[0].x - 0.12 || local_hit.x > b_aabb[1].x + 0.12 ||
						   local_hit.y < b_aabb[0].y - 0.12 || local_hit.y > b_aabb[1].y + 0.12 ||
						   local_hit.z < b_aabb[0].z - 0.12 || local_hit.z > b_aabb[1].z + 0.12 {
							continue
						}
						// Prefer the additive brush whose boundary plane in direction `ln` is closest to `local_hit`
						face_err: f32 = 0.25
						if abs(ln.x) > 0.6 {
							target_x := b_aabb[1].x if ln.x > 0 else b_aabb[0].x
							face_err = abs(local_hit.x - target_x)
						} else if abs(ln.y) > 0.6 {
							target_y := b_aabb[1].y if ln.y > 0 else b_aabb[0].y
							face_err = abs(local_hit.y - target_y)
						} else if abs(ln.z) > 0.6 {
							target_z := b_aabb[1].z if ln.z > 0 else b_aabb[0].z
							face_err = abs(local_hit.z - target_z)
						}
						if vol.brushes[b_idx].op != .Add {
							face_err += 0.5 // Prefer additive brushes for Push/Pull unless only a subtractive brush matches
						}
						if face_err < best_face_err {
							best_face_err = face_err
							hit_brush_idx = b_idx
						}
					}
				}
			}
		}
	}
	return
}

// Runtime Update Hook:
// 1. Automatically compiles any uncompiled `CSGVolume` loaded from a `.scene` file.
// 2. Allows pressing `G` (or Middle-Click) in Play mode to fire a Geo-Mod blast along the active Game Camera!
@(update={order=100})
csg_runtime_update :: proc(dt: f32) {
	_ = dt
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || !engine.transform_active_in_hierarchy(vol.owner) do continue
		if !vol.compiled {
			csg_volume_rebuild(vol)
		}
	}

	// In Play Mode: pressing G or Middle-Mouse fires a Red Faction Geo-Mod Rocket from the active camera!
	if input.key_pressed(.G) || input.mouse_pressed(.Middle) {
		if cam := engine.camera_active(); cam != nil {
			vp := engine.canvas_game_viewport()
			mp := input.mouse_position()
			ray := engine.camera_screen_ray(cam, mp, vp)
			if hp, _, _, _, _, hit := csg_raycast_world(ray); hit {
				csg_trigger_blast(hp, 1.65, 14.0)
			}
		}
	}
}

// Helper to append a primitive brush to a `CSGVolume`
csg_volume_add_brush :: proc(
	vol:          ^CSGVolume,
	name:         string,
	op:           Brush_Op,
	primitive:    Brush_Primitive,
	center:       [3]f32,
	size:         [3]f32,
	yaw_deg:      f32 = 0,
	color:        [4]u8 = {210, 216, 224, 255},
	destructible: bool = true,
	anchored:     bool = false,
	uv_scale:     f32 = 0.5,
) -> int {
	if vol == nil do return -1
	if vol.next_brush_id == 0 do vol.next_brush_id = 1
	id := vol.next_brush_id
	vol.next_brush_id += 1

	b := CSG_Brush{
		id           = id,
		name         = strings.clone(name),
		op           = op,
		primitive    = primitive,
		center       = center,
		size         = size,
		yaw_deg      = yaw_deg,
		uv_scale     = uv_scale,
		color        = color,
		destructible = destructible,
		anchored     = anchored,
	}
	append(&vol.brushes, b)
	return len(vol.brushes) - 1
}

// Helper to append a 2D Polyline / Catmull-Rom Spline extrusion brush (`Brush_Primitive.Profile_2D`) to a `CSGVolume`
csg_volume_add_profile_brush :: proc(
	vol:            ^CSGVolume,
	name:           string,
	op:             Brush_Op,
	plane_origin:   [3]f32,
	plane_u:        [3]f32,
	plane_v:        [3]f32,
	plane_normal:   [3]f32,
	points:         []CSG_Profile_Point,
	extrude_height: f32,
	color:          [4]u8 = {210, 216, 224, 255},
	destructible:   bool = true,
	anchored:       bool = false,
	uv_scale:       f32 = 0.5,
) -> int {
	if vol == nil || len(points) < 3 do return -1
	if vol.next_brush_id == 0 do vol.next_brush_id = 1
	id := vol.next_brush_id
	vol.next_brush_id += 1

	pts_copy := make([dynamic]CSG_Profile_Point, len(points))
	copy(pts_copy[:], points)

	// Compute approximate size AABB for inspector display
	min_uv := points[0].uv
	max_uv := points[0].uv
	for p in points[1:] {
		min_uv.x = min(min_uv.x, p.uv.x)
		min_uv.y = min(min_uv.y, p.uv.y)
		max_uv.x = max(max_uv.x, p.uv.x)
		max_uv.y = max(max_uv.y, p.uv.y)
	}
	span_u := max(max_uv.x - min_uv.x, 0.2)
	span_v := max(max_uv.y - min_uv.y, 0.2)

	b := CSG_Brush{
		id             = id,
		name           = strings.clone(name),
		op             = op,
		primitive      = .Profile_2D,
		center         = plane_origin,
		size           = {span_u, abs(extrude_height), span_v},
		uv_scale       = uv_scale,
		color          = color,
		destructible   = destructible,
		anchored       = anchored,
		profile_points = pts_copy,
		plane_normal   = plane_normal,
		plane_u        = plane_u,
		plane_v        = plane_v,
		extrude_height = extrude_height,
	}
	append(&vol.brushes, b)
	return len(vol.brushes) - 1
}

// Clones a `CSG_Brush` shifted by `offset` in local space
@(private = "file")
_clone_brush_shifted :: proc(src: CSG_Brush, offset: [3]f32) -> CSG_Brush {
	dst := src
	dst.name = strings.clone(src.name)
	dst.center = src.center + offset
	if len(src.profile_points) > 0 {
		dst.profile_points = make([dynamic]CSG_Profile_Point, len(src.profile_points))
		copy(dst.profile_points[:], src.profile_points[:])
	} else {
		dst.profile_points = nil
	}
	return dst
}

// Detaches a single authored `CSG_Brush` (`brush_idx`) out of `vol` into its own standalone
// `CSGVolume` GameObject in the scene hierarchy, optionally enabling Jolt Dynamic Physics
// (`is_dynamic_rigidbody = enable_dynamic_physics`) on the new CSG object!
// Also copies any subsequent overlapping `.Subtract` boolean cutouts so doorway/window holes stay intact.
csg_detach_brush_to_volume :: proc(
	vol:                    ^CSGVolume,
	brush_idx:              int,
	enable_dynamic_physics: bool = true,
) -> engine.Transform_Handle {
	if vol == nil || brush_idx < 0 || brush_idx >= len(vol.brushes) do return {}
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return {}

	// If `vol` only has 1 brush total, just toggle `is_dynamic_rigidbody` directly on `vol`!
	if len(vol.brushes) == 1 {
		vol.is_dynamic_rigidbody = enable_dynamic_physics
		vol.brushes[0].anchored = !enable_dynamic_physics
		csg_volume_rebuild(vol)
		csg_volume_sync_colliders_only(vol)
		scene.dirty = true
		return engine.Transform_Handle(vol.owner)
	}

	if !vol.compiled {
		csg_volume_rebuild(vol)
	}

	vol_owner := vol.owner
	target_b := vol.brushes[brush_idx]
	b_aabb := vol.brush_aabbs[brush_idx] if brush_idx < len(vol.brush_aabbs) else [2][3]f32{target_b.center - target_b.size * 0.5, target_b.center + target_b.size * 0.5}
	local_pivot := target_b.center

	tw := engine.transform_world(vol_owner)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	world_pos := (model * [4]f32{local_pivot.x, local_pivot.y, local_pivot.z, 1.0}).xyz

	root_h := engine.Transform_Handle(scene.root.handle)
	new_name := fmt.tprintf("CSG_%s", target_b.name if len(target_b.name) > 0 else "Object")
	new_h := engine.transform_new(new_name, root_h)
	engine.transform_ensure_unique_name(new_h)
	if nt := engine.pool_get(&w.transforms, engine.Handle(new_h)); nt != nil {
		nt.position = world_pos
		nt.rotation = tw.rotation
		nt.scale    = tw.scale
	}

	_, new_ptr := engine.transform_add_comp(new_h, .CSGVolume)
	new_vol := cast(^CSGVolume)new_ptr
	if new_vol == nil do return {}
	reset_CSGVolume(new_vol)

	// Re-fetch `vol` in case `transform_add_comp` reallocated the `CSGVolume` component pool!
	_, vol_re := engine.transform_get_comp(vol_owner, CSGVolume)
	if vol_re == nil do return {}
	vol := vol_re

	new_vol.chunk_size                 = vol.chunk_size
	new_vol.ground_y                   = vol.ground_y - local_pivot.y
	new_vol.is_dynamic_rigidbody       = enable_dynamic_physics
	new_vol.enable_structural_collapse = vol.enable_structural_collapse
	new_vol.spawn_debris               = vol.spawn_debris
	new_vol.cast_planar_shadows        = !enable_dynamic_physics && vol.cast_planar_shadows
	new_vol.debris_collider_mode       = vol.debris_collider_mode

	// Add the detached brush centered at `{0, 0, 0}` in `new_vol`
	main_clone := _clone_brush_shifted(target_b, -local_pivot)
	main_clone.op = .Add
	if enable_dynamic_physics {
		main_clone.anchored = false
	}
	append(&new_vol.brushes, main_clone)

	// Copy any subsequent `.Subtract` brushes in `vol` whose AABB overlaps `b_aabb`
	if target_b.op == .Add {
		for k := brush_idx + 1; k < len(vol.brushes); k += 1 {
			sub_b := vol.brushes[k]
			if sub_b.op != .Subtract do continue
			sub_aabb := vol.brush_aabbs[k] if k < len(vol.brush_aabbs) else [2][3]f32{sub_b.center - sub_b.size * 0.5, sub_b.center + sub_b.size * 0.5}
			if aabb_overlaps(b_aabb[0], b_aabb[1], sub_aabb[0], sub_aabb[1], 0.05) {
				append(&new_vol.brushes, _clone_brush_shifted(sub_b, -local_pivot))
			}
		}
	}

	// Remove `brush_idx` from the original `vol`
	if len(vol.brushes[brush_idx].name) > 0 {
		delete(vol.brushes[brush_idx].name)
	}
	if vol.brushes[brush_idx].profile_points != nil {
		delete(vol.brushes[brush_idx].profile_points)
	}
	ordered_remove(&vol.brushes, brush_idx)

	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	csg_volume_rebuild(new_vol)
	csg_volume_sync_colliders_only(new_vol)
	scene.dirty = true
	return new_h
}

// Splits all additive brushes in `vol` (beyond the first brush) into individual standalone
// `CSGVolume` GameObjects in the scene hierarchy so each CSG object can be selected, moved,
// or given physics independently!
csg_split_all_brushes_to_volumes :: proc(vol: ^CSGVolume, enable_physics_on_unanchored: bool = false) -> int {
	if vol == nil || len(vol.brushes) <= 1 do return 0
	vol_owner := vol.owner
	spawned := 0
	for i := len(vol.brushes) - 1; i >= 1; i -= 1 {
		_, cur_vol := engine.transform_get_comp(vol_owner, CSGVolume)
		if cur_vol == nil || i >= len(cur_vol.brushes) do break
		if cur_vol.brushes[i].op != .Add do continue
		dyn := enable_physics_on_unanchored && !cur_vol.brushes[i].anchored
		if h := csg_detach_brush_to_volume(cur_vol, i, dyn); h != {} {
			spawned += 1
		}
	}
	return spawned
}

// =============================================================================
// Practical CSG Level-Building Ergonomics:
// Brush Reorder, Duplicate, Pivot Recenter, Floor Drop & Non-Destructive Merge!
// =============================================================================

// Duplicates `brush_idx` inside `vol` with an optional local-space offset (`{0.25, 0, 0.25}`),
// returning the newly appended brush index.
csg_volume_duplicate_brush :: proc(vol: ^CSGVolume, brush_idx: int, local_offset: [3]f32 = {0.25, 0, 0.25}) -> int {
	if vol == nil || brush_idx < 0 || brush_idx >= len(vol.brushes) do return -1
	if vol.next_brush_id == 0 do vol.next_brush_id = u32(len(vol.brushes) + 1)
	new_id := vol.next_brush_id
	vol.next_brush_id += 1

	src := vol.brushes[brush_idx]
	dup := _clone_brush_shifted(src, local_offset)
	dup.id = new_id
	delete(dup.name)
	dup.name = fmt.aprintf("%s_Copy", src.name if len(src.name) > 0 else "Brush")
	append(&vol.brushes, dup)

	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return len(vol.brushes) - 1
}

// Moves `brush_idx` up (`delta = -1`) or down (`delta = +1`) in the CSG Brush Stack,
// returning the new index of the moved brush.
csg_volume_move_brush_order :: proc(vol: ^CSGVolume, brush_idx: int, delta: int) -> int {
	if vol == nil || brush_idx < 0 || brush_idx >= len(vol.brushes) || delta == 0 do return brush_idx
	dst := clamp(brush_idx + delta, 0, len(vol.brushes) - 1)
	if dst == brush_idx do return brush_idx

	tmp := vol.brushes[brush_idx]
	if dst < brush_idx {
		for i := brush_idx; i > dst; i -= 1 {
			vol.brushes[i] = vol.brushes[i - 1]
		}
	} else {
		for i := brush_idx; i < dst; i += 1 {
			vol.brushes[i] = vol.brushes[i + 1]
		}
	}
	vol.brushes[dst] = tmp

	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return dst
}

// Reorders `vol.brushes` stably so all `.Add` solid brushes evaluate BEFORE `.Subtract`
// hole/doorway/window brushes — fixing the classic CSG paper-cut where adding a new wall
// after an existing doorway fails to get cut by the doorway!
csg_volume_move_subtracts_to_end :: proc(vol: ^CSGVolume) -> int {
	if vol == nil || len(vol.brushes) <= 1 do return 0
	adds := make([dynamic]CSG_Brush, 0, len(vol.brushes), context.temp_allocator)
	subs := make([dynamic]CSG_Brush, 0, len(vol.brushes), context.temp_allocator)
	moved := 0
	seen_sub := false
	for b in vol.brushes {
		if b.op == .Subtract {
			seen_sub = true
			append(&subs, b)
		} else {
			if seen_sub do moved += 1
			append(&adds, b)
		}
	}
	if moved == 0 do return 0
	idx := 0
	for b in adds { vol.brushes[idx] = b; idx += 1 }
	for b in subs { vol.brushes[idx] = b; idx += 1 }
	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return moved
}

// Recenters `vol`'s Transform pivot to the exact geometric center of its compiled CSG AABB
// WITHOUT moving a single vertex by even 0.001mm in 3D World Space!
csg_volume_recenter_pivot :: proc(vol: ^CSGVolume) -> bool {
	if vol == nil do return false
	w := engine.ctx_world()
	owner := engine.Transform_Handle(vol.owner)
	if w == nil || owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner)) do return false

	lo, hi, ok := csg_volume_local_aabb(vol)
	if !ok do return false
	local_c := (lo + hi) * 0.5
	if linalg.length2(local_c) < 1e-6 do return false

	tw := engine.transform_world(owner)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	world_c := (model * [4]f32{local_c.x, local_c.y, local_c.z, 1.0}).xyz
	world_delta := world_c - tw.position

	nt := engine.pool_get(&w.transforms, engine.Handle(owner))
	if nt == nil do return false

	// Convert `world_delta` into parent-local space if parented
	if nt.parent.handle != {} && engine.pool_valid(&w.transforms, nt.parent.handle) {
		ptw := engine.transform_world(engine.Transform_Handle(nt.parent.handle))
		inv_p := linalg.inverse(engine.trs_matrix(ptw.position, ptw.rotation, ptw.scale))
		nt.position = (inv_p * [4]f32{world_c.x, world_c.y, world_c.z, 1.0}).xyz
	} else {
		nt.position += world_delta
	}

	off := -local_c
	for &b in vol.brushes         { b.center += off }
	for &rb in vol.recorded_blasts { rb.local_pos += off }
	for &di in vol.detail_instances { di.local_pos += off }
	for &gp in vol.glass_panes     { gp.center += off }
	for &sd in vol.soft_deform_stamps { sd.local_pos += off }
	for &h in vol.runtime_hulls {
		for &p in h.planes {
			p.dist += linalg.dot(p.normal, off)
		}
		h.aabb_min += off
		h.aabb_max += off
		h.centroid += off
	}
	vol.ground_y += off.y

	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Shifts `vol`'s entity vertically so the lowest point of its compiled CSG geometry rests flush on `ground_y` (default `0.0`).
csg_volume_drop_to_ground :: proc(vol: ^CSGVolume, ground_y: f32 = 0.0) -> bool {
	if vol == nil do return false
	w := engine.ctx_world()
	owner := engine.Transform_Handle(vol.owner)
	if w == nil || owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner)) do return false

	lo, hi, ok := csg_volume_local_aabb(vol)
	if !ok do return false
	tw := engine.transform_world(owner)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)

	corners := [8][3]f32{
		{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z},
		{lo.x, hi.y, lo.z}, {hi.x, hi.y, lo.z},
		{lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z},
		{lo.x, hi.y, hi.z}, {hi.x, hi.y, hi.z},
	}
	min_wy := (model * [4]f32{corners[0].x, corners[0].y, corners[0].z, 1.0}).y
	for c in corners[1:] {
		wy := (model * [4]f32{c.x, c.y, c.z, 1.0}).y
		if wy < min_wy do min_wy = wy
	}

	dy := ground_y - min_wy
	if abs(dy) < 1e-5 do return true
	if nt := engine.pool_get(&w.transforms, engine.Handle(owner)); nt != nil {
		nt.position.y += dy
	}
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Non-Destructive Multi-CSG Brush Join:
// Transforms all authored `CSG_Brush` entries (and recorded blasts) of `tool_handles` from World Space
// into `target_h`'s local space, keeping every single brush 100% parametric & editable in `target_h`'s Brush Stack!
csg_merge_volumes_non_destructive :: proc(
	target_h:         engine.Transform_Handle,
	tool_handles:     []engine.Transform_Handle,
	flip_to_subtract: bool = false,
	consume_tools:    bool = true,
) -> bool {
	w := engine.ctx_world()
	if w == nil || target_h == {} || len(tool_handles) == 0 do return false
	if !engine.pool_valid(&w.transforms, engine.Handle(target_h)) do return false
	_, vol_a := engine.transform_get_comp(target_h, CSGVolume)
	if vol_a == nil || !vol_a.enabled do return false

	tw_a   := engine.transform_world(target_h)
	mat_a  := engine.trs_matrix(tw_a.position, tw_a.rotation, tw_a.scale)
	inv_a  := linalg.inverse(mat_a)
	qa     := quaternion(x = tw_a.rotation.x, y = tw_a.rotation.y, z = tw_a.rotation.z, w = tw_a.rotation.w)
	inv_qa := linalg.quaternion_inverse(qa)
	safe_sa := [3]f32{
		abs(tw_a.scale.x) > 1e-4 ? tw_a.scale.x : 1.0,
		abs(tw_a.scale.y) > 1e-4 ? tw_a.scale.y : 1.0,
		abs(tw_a.scale.z) > 1e-4 ? tw_a.scale.z : 1.0,
	}

	if vol_a.next_brush_id == 0 do vol_a.next_brush_id = u32(len(vol_a.brushes) + 1)
	merged_any := false
	to_destroy := make([dynamic]engine.Transform_Handle, 0, len(tool_handles), context.temp_allocator)

	for th in tool_handles {
		if th == {} || th == target_h || !engine.pool_valid(&w.transforms, engine.Handle(th)) do continue
		_, vol_b := engine.transform_get_comp(th, CSGVolume)
		if vol_b == nil || len(vol_b.brushes) == 0 do continue

		tw_b  := engine.transform_world(th)
		mat_b := engine.trs_matrix(tw_b.position, tw_b.rotation, tw_b.scale)
		qb    := quaternion(x = tw_b.rotation.x, y = tw_b.rotation.y, z = tw_b.rotation.z, w = tw_b.rotation.w)
		rel_q := inv_qa * qb
		fwd_x := linalg.quaternion128_mul_vector3(rel_q, [3]f32{1, 0, 0})
		delta_yaw_deg := math.atan2(-fwd_x.z, fwd_x.x) * (180.0 / math.PI)
		scale_ratio := [3]f32{
			abs(tw_b.scale.x / safe_sa.x),
			abs(tw_b.scale.y / safe_sa.y),
			abs(tw_b.scale.z / safe_sa.z),
		}

		for src_b in vol_b.brushes {
			nb := _clone_brush_shifted(src_b, {0, 0, 0})
			nb.id = vol_a.next_brush_id
			vol_a.next_brush_id += 1
			if flip_to_subtract {
				nb.op = (src_b.op == .Add) ? .Subtract : .Add
			}

			w_cent := (mat_b * [4]f32{src_b.center.x, src_b.center.y, src_b.center.z, 1.0}).xyz
			nb.center  = (inv_a * [4]f32{w_cent.x, w_cent.y, w_cent.z, 1.0}).xyz
			nb.size    = src_b.size * scale_ratio
			nb.yaw_deg = src_b.yaw_deg + delta_yaw_deg

			if src_b.primitive == .Profile_2D {
				wu := linalg.quaternion128_mul_vector3(rel_q, src_b.plane_u)
				wv := linalg.quaternion128_mul_vector3(rel_q, src_b.plane_v)
				wn := linalg.quaternion128_mul_vector3(rel_q, src_b.plane_normal)
				nb.plane_u        = linalg.normalize0(wu)
				nb.plane_v        = linalg.normalize0(wv)
				nb.plane_normal   = linalg.normalize0(wn)
				nb.extrude_height = src_b.extrude_height * scale_ratio.y
				for &pt in nb.profile_points {
					pt.uv.x *= scale_ratio.x
					pt.uv.y *= scale_ratio.z
				}
			}
			append(&vol_a.brushes, nb)
			merged_any = true
		}

		for rb in vol_b.recorded_blasts {
			w_bp := (mat_b * [4]f32{rb.local_pos.x, rb.local_pos.y, rb.local_pos.z, 1.0}).xyz
			nrb := rb
			nrb.local_pos = (inv_a * [4]f32{w_bp.x, w_bp.y, w_bp.z, 1.0}).xyz
			nrb.radius   *= (scale_ratio.x + scale_ratio.y + scale_ratio.z) / 3.0
			append(&vol_a.recorded_blasts, nrb)
		}

		if consume_tools {
			append(&to_destroy, th)
		}
	}

	if !merged_any do return false
	for dh in to_destroy {
		if engine.pool_valid(&w.transforms, engine.Handle(dh)) {
			engine.transform_destroy(dh)
		}
	}
	// Re-fetch `vol_a` in case destroying `dh` compacted anything
	if _, vol_re := engine.transform_get_comp(target_h, CSGVolume); vol_re != nil {
		csg_volume_rebuild(vol_re)
		csg_volume_sync_colliders_only(vol_re)
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}
