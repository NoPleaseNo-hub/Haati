package control_rig_editor

// Scene-view picking & raycasting for ArmatureDeformedMesh (skeletal & hybrid meshes).
// Enables direct viewport click-selection and box-selection of characters, bone joints, and colliders.

import "core:math"
import "core:math/linalg"
import engine "moonhug:engine"
import "moonhug:engine/gizmos"
import handles "moonhug:editor/handles"
import physics3d "moonhug:packages/physics3d"
import crig "moonhug:packages/control_rig"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
armature_deformed_mesh_picker_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	handles.pick_register(handles.Pick_Provider{
		click = _adm_pick_click,
		band  = _adm_pick_band,
	})
}

@(private = "file")
_ray_hit_sphere :: proc(ray: engine.Ray, center: [3]f32, radius: f32) -> (hit_t: f32, hit: bool) {
	v := center - ray.origin
	proj := linalg.dot(v, ray.direction)
	d2 := linalg.length2(v) - proj * proj
	r2 := radius * radius
	if d2 > r2 do return 0, false
	th := math.sqrt(max(f32(0), r2 - d2))
	t0 := proj - th
	t1 := proj + th
	if t0 > 0.001 do return t0, true
	if t1 > 0.001 do return t1, true
	return 0, false
}

@(private = "file")
_ray_hit_capsule_segment :: proc(ray: engine.Ray, p0, p1: [3]f32, radius: f32) -> (hit_t: f32, hit: bool) {
	d_seg := p1 - p0
	len_sq := linalg.length2(d_seg)
	if len_sq < 0.00001 {
		return _ray_hit_sphere(ray, p0, radius)
	}

	d_ray := ray.direction
	r := ray.origin - p0
	a := linalg.dot(d_ray, d_ray)
	b := linalg.dot(d_ray, d_seg)
	c := len_sq
	d := linalg.dot(d_ray, r)
	e := linalg.dot(d_seg, r)

	denom := a * c - b * b
	t_val: f32 = 0
	u_val: f32 = 0

	if denom > 0.000001 {
		t_val = (b * e - c * d) / denom
		u_val = (a * e - b * d) / denom
	} else {
		t_val = 0
		u_val = e / c if c > 0 else 0
	}

	u_clamped := clamp(u_val, f32(0.0), f32(1.0))
	seg_pt := p0 + d_seg * u_clamped
	t_final := max(f32(0.0), linalg.dot(seg_pt - ray.origin, d_ray))
	ray_pt := ray.origin + d_ray * t_final

	dist_sq := linalg.length2(seg_pt - ray_pt)
	if dist_sq <= radius * radius {
		surf_dist := math.sqrt(max(f32(0), radius * radius - dist_sq))
		hit_dist := max(f32(0.0), t_final - surf_dist)
		return hit_dist, true
	}
	return 0, false
}

@(private = "file")
_ray_hit_capsule_collider :: proc(ray: engine.Ray, bone_h: engine.Transform_Handle, cap: ^physics3d.CapsuleCollider) -> (hit_t: f32, hit: bool) {
	tw := engine.transform_world(bone_h)
	s := [3]f32{abs(tw.scale.x), abs(tw.scale.y), abs(tw.scale.z)}
	if s.x < 1e-4 do s.x = 1
	if s.y < 1e-4 do s.y = 1
	if s.z < 1e-4 do s.z = 1

	rad, height, center := physics3d.capsule_scaled(cap, s)
	if rad <= 0.001 || height <= 0.001 do return 0, false
	inner_len := max(f32(0.0), height - rad * 2.0)

	axis_dir: [3]f32
	switch cap.direction {
	case .X_Axis: axis_dir = {1, 0, 0}
	case .Y_Axis: axis_dir = {0, 1, 0}
	case .Z_Axis: axis_dir = {0, 0, 1}
	}

	rot := cap.rotation
	if rot == {} || (rot.x*rot.x + rot.y*rot.y + rot.z*rot.z + rot.w*rot.w) < 1e-4 do rot = {0, 0, 0, 1}
	rot_native := linalg.normalize(engine.quat_to_native(rot))
	axis_rot := linalg.quaternion128_mul_vector3(rot_native, axis_dir)

	half_len := inner_len * 0.5
	// `center` is in scaled bone-local space; `cap.rotation` rotates the capsule axis around `center`
	p0_local := center - axis_rot * half_len
	p1_local := center + axis_rot * half_len

	m := engine.trs_matrix(tw.position, tw.rotation, [3]f32{1, 1, 1})
	p0_w := (m * [4]f32{p0_local.x, p0_local.y, p0_local.z, 1}).xyz
	p1_w := (m * [4]f32{p1_local.x, p1_local.y, p1_local.z, 1}).xyz

	return _ray_hit_capsule_segment(ray, p0_w, p1_w, rad)
}

@(private = "file")
_ray_hit_box_collider :: proc(ray: engine.Ray, bone_h: engine.Transform_Handle, box: ^physics3d.BoxCollider) -> (hit_t: f32, hit: bool) {
	tw := engine.transform_world(bone_h)
	s := [3]f32{abs(tw.scale.x), abs(tw.scale.y), abs(tw.scale.z)}
	if s.x < 1e-4 do s.x = 1
	if s.y < 1e-4 do s.y = 1
	if s.z < 1e-4 do s.z = 1

	size_scaled, center_scaled := physics3d.box_scaled(box, s)
	bone_mat := engine.trs_matrix(tw.position, tw.rotation, [3]f32{1, 1, 1})
	center_w := (bone_mat * [4]f32{center_scaled.x, center_scaled.y, center_scaled.z, 1}).xyz

	rot := box.rotation
	if rot == {} || (rot.x*rot.x + rot.y*rot.y + rot.z*rot.z + rot.w*rot.w) < 1e-4 do rot = {0, 0, 0, 1}
	world_rot := engine.quat_to_native(tw.rotation) * engine.quat_to_native(rot)
	if (world_rot.x*world_rot.x + world_rot.y*world_rot.y + world_rot.z*world_rot.z + world_rot.w*world_rot.w) < 1e-4 do world_rot = quaternion128(1)
	world_rot = linalg.normalize(world_rot)

	box_mat := engine.trs_matrix(center_w, engine.quat_from_native(world_rot), [3]f32{1, 1, 1})
	det := linalg.determinant(box_mat)
	if abs(det) < 1e-6 do return 0, false
	inv_mat := linalg.inverse(box_mat)

	local_o := (inv_mat * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}).xyz
	local_d := (inv_mat * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}).xyz

	local_ray := engine.Ray{origin = local_o, direction = local_d}
	half_sz := size_scaled * 0.5
	lo := -half_sz
	hi :=  half_sz

	box_hit_t, ok := engine.ray_hit_aabb(local_ray, lo, hi)
	if !ok do return 0, false

	hit_local := local_o + local_d * box_hit_t
	hit_world := (box_mat * [4]f32{hit_local.x, hit_local.y, hit_local.z, 1}).xyz
	world_dist := linalg.length(hit_world - ray.origin)
	return world_dist, true
}

@(private = "file")
_ray_hit_sphere_collider :: proc(ray: engine.Ray, bone_h: engine.Transform_Handle, sph: ^physics3d.SphereCollider) -> (hit_t: f32, hit: bool) {
	tw := engine.transform_world(bone_h)
	rad, center := physics3d.sphere_scaled(sph, tw.scale)
	m := engine.trs_matrix(tw.position, tw.rotation, [3]f32{1, 1, 1})
	center_w := (m * [4]f32{center.x, center.y, center.z, 1}).xyz
	return _ray_hit_sphere(ray, center_w, rad)
}

@(private = "file")
_adm_pick_click :: proc(view: engine.Render_View, ray: engine.Ray) -> (tH: engine.Transform_Handle, t: f32, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return {}, 0, false

	best_t: f32 = 1e20
	best_h: engine.Transform_Handle = {}

	it := engine.pool_iterator(crig.armature_deformed_meshes(w))
	for adm, _ in engine.pool_next(&it) {
		if !adm.enabled do continue
		owner_h := engine.Transform_Handle(adm.owner)
		if !engine.transform_active_in_hierarchy(adm.owner) do continue

		// ====================================================================
		// BONE / COLLIDER WORKSPACE MODE: Exclusively pick bones and their colliders
		// on the active character. Mesh AABB is NEVER tested in this mode!
		// ====================================================================
		is_bone_picking := (scene_viewport_mode == .Control_Rig && (character_edit_mode == .Bone_Mode || character_edit_mode == .Colliders))
		if is_bone_picking {
			active_char := get_active_character_owner()
			if active_char != {} && active_char != owner_h do continue
			for j in adm.joints {
				if j == {} || !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue
				t := engine.pool_get(&w.transforms, engine.Handle(j))
				if t == nil do continue

				j_pos := engine.transform_world_position(j)

				// A. Test attached CapsuleCollider
				_, cap := engine.transform_get_comp(j, physics3d.CapsuleCollider)
				if cap != nil {
					if hit_t, hit := _ray_hit_capsule_collider(ray, j, cap); hit {
						if hit_t < best_t {
							best_t = hit_t
							best_h = j
						}
					}
				}

				// B. Test attached BoxCollider
				_, box := engine.transform_get_comp(j, physics3d.BoxCollider)
				if box != nil {
					if hit_t, hit := _ray_hit_box_collider(ray, j, box); hit {
						if hit_t < best_t {
							best_t = hit_t
							best_h = j
						}
					}
				}

				// C. Test attached SphereCollider
				_, sph := engine.transform_get_comp(j, physics3d.SphereCollider)
				if sph != nil {
					if hit_t, hit := _ray_hit_sphere_collider(ray, j, sph); hit {
						if hit_t < best_t {
							best_t = hit_t
							best_h = j
						}
					}
				}

				// D. Test bone joint sphere (ONLY in Bone_Mode — in Colliders mode, clicks strictly pick 3D colliders!)
				if character_edit_mode == .Bone_Mode {
					joint_pick_rad := max(crig.skeleton_settings.bone_pick_radius, 0.05)
					if hit_t, hit := _ray_hit_sphere(ray, j_pos, joint_pick_rad); hit {
						if hit_t < best_t {
							best_t = hit_t
							best_h = j
						}
					}

					// E. Test bone line segment connecting parent bone to child
					if t.parent.handle != {} && engine.pool_valid(&w.transforms, t.parent.handle) {
						parent_pos := engine.transform_world_position(engine.Transform_Handle(t.parent.handle))
						bone_segment_rad := max(0.04 * crig.skeleton_settings.bone_thickness, 0.02)
						if hit_t, hit := _ray_hit_capsule_segment(ray, parent_pos, j_pos, bone_segment_rad); hit {
							if hit_t < best_t {
								best_t = hit_t
								best_h = j
							}
						}
					}
				}
			}
			// In Bone Mode, never fall through to mesh AABB!
			continue
		}

		// ====================================================================
		// RIG CONTROLS MODE: Keep focus locked to the active character so stray
		// clicks near contours never select background actors or fight handles.
		// ====================================================================
		if scene_viewport_mode == .Control_Rig && character_edit_mode == .Rig_Controls && show_rig_controls {
			active_char := get_active_character_owner()
			if active_char != {} {
				continue
			}
		}

		// ====================================================================
		// MESH MODE: Clicks pick the character actor in the level
		// ====================================================================
		if adm.posed_min != adm.posed_max {
			margin := [3]f32{0.05, 0.05, 0.05}
			lo := adm.posed_min - margin
			hi := adm.posed_max + margin
			if hit_t, hit := engine.ray_hit_aabb(ray, lo, hi); hit {
				if hit_t < best_t {
					best_t = hit_t
					best_h = owner_h
				}
			}
			continue
		}

		// Fallback: test bind mesh AABB in local space
		mesh_guid := adm.mesh
		if engine.asset_guid_is_empty(mesh_guid) {
			_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
			if mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
				mesh_guid = mf.mesh.guid
			}
		}
		if engine.asset_guid_is_empty(mesh_guid) do continue

		mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
		if !mok || mesh == nil do continue

		tw := engine.transform_world(owner_h)
		inv := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		local_o := inv * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
		local_d := inv * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}
		local_ray := engine.Ray{origin = local_o.xyz, direction = local_d.xyz}

		if hit_t, hit := engine.ray_hit_aabb(local_ray, mesh.aabb_min, mesh.aabb_max); hit {
			if hit_t < best_t {
				best_t = hit_t
				best_h = owner_h
			}
		}
	}

	if best_h != {} {
		return best_h, best_t, true
	}
	return {}, 0, false
}

@(private = "file")
_adm_pick_band :: proc(view: engine.Render_View, rmin, rmax: [2]f32, out: ^[dynamic]engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(crig.armature_deformed_meshes(w))
	for adm, _ in engine.pool_next(&it) {
		if !adm.enabled do continue
		owner_h := engine.Transform_Handle(adm.owner)
		if !engine.transform_active_in_hierarchy(adm.owner) do continue

		is_bone_picking := (scene_viewport_mode == .Control_Rig && (character_edit_mode == .Bone_Mode || character_edit_mode == .Colliders))

		// In Default Scene / Rig Controls Mode, test character mesh bounds
		if !is_bone_picking {
			lo := adm.posed_min
			hi := adm.posed_max
			if lo != hi {
				corners := [8][3]f32{
					{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {lo.x, hi.y, lo.z}, {hi.x, hi.y, lo.z},
					{lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z}, {lo.x, hi.y, hi.z}, {hi.x, hi.y, hi.z},
				}
				hit_mesh := false
				for c in corners {
					sp, ok := gizmos.helper_project_in(view, c)
					if ok && sp.x >= rmin.x && sp.x <= rmax.x && sp.y >= rmin.y && sp.y <= rmax.y {
						hit_mesh = true
						break
					}
				}
				if hit_mesh do append(out, owner_h)
			}
		}

		// In Bone / Collider Workspace Mode, collect contained bones of active character
		if is_bone_picking && len(adm.joints) > 0 {
			active_char := get_active_character_owner()
			if active_char != {} && active_char != owner_h do continue
			for j in adm.joints {
				if j == {} || !engine.pool_valid(&w.transforms, engine.Handle(j)) || !engine.transform_active_in_hierarchy(j) do continue
				pos := engine.transform_world_position(j)
				sp, ok := gizmos.helper_project_in(view, pos)
				if ok && sp.x >= rmin.x && sp.x <= rmax.x && sp.y >= rmin.y && sp.y <= rmax.y {
					append(out, j)
				}
			}
		}
	}
}
