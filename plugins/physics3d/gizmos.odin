package physics3d

// Collider wireframes, shared by two callers: the editor's selected-object
// gizmos (packages/physics3d/editor delegates here) and the in-app debug
// view — the DebugDraw phase subscriber draws EVERY enabled collider when
// engine.debug_draw_enabled is on. Full 3D: shapes go through the owner's
// world position and rotation (scale ignored, matching the sync: the sizes
// are scaled already). Drawn through engine/gizmos.

import "core:math/linalg"
import "haati:engine"
import "haati:engine/gizmos"

// Unity's collider gizmo green.
COLLIDER_GIZMO_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}
SPRING_ARM_GIZMO_COLOR :: [4]f32{0.25, 0.85, 1.0, 1}
TIME_DILATION_GIZMO_COLOR :: [4]f32{0.45, 0.82, 1.0, 1}

draw_time_dilation_volume_wires :: proc(vol: ^TimeDilationVolume, color: [4]f32) {
	if vol == nil || vol.owner == {} do return
	gizmos.with_color(color)
	gizmos.in_local_space(vol.owner, use_scale = false)
	s := collider_scale(vol.owner)
	o := vol.center_offset * s
	if vol.shape_mode == .Sphere_Radius {
		r := max(vol.sphere_radius * max(s.x, max(s.y, s.z)), 0.01)
		gizmos.wire_sphere(o, r)
	} else {
		sz := [3]f32{
			max(vol.box_size.x, 0.01) * s.x,
			max(vol.box_size.y, 0.01) * s.y,
			max(vol.box_size.z, 0.01) * s.z,
		}
		gizmos.wire_box(o, sz)
	}
}

draw_spring_arm_wires :: proc(arm: ^SpringArm3D, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(arm.owner, use_scale = false)
	dir := linalg.normalize0(arm.arm_direction_local)
	if linalg.length2(dir) < 1e-6 do dir = {0, 0, -1}
	start := arm.shoulder_offset
	tip := start + dir * max(arm.spring_length, 0.0)
	gizmos.line(start, tip)
	if arm.probe_radius > 0.001 {
		gizmos.wire_sphere(tip, arm.probe_radius)
	}
}

draw_box_collider_wires :: proc(c: ^BoxCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	size, o := box_scaled(c, collider_scale(c.owner))
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(o, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		gizmos.wire_box({0, 0, 0}, size)
	} else {
		gizmos.wire_box(o, size)
	}
}

draw_sphere_collider_wires :: proc(c: ^SphereCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius, o := sphere_scaled(c, collider_scale(c.owner))
	gizmos.wire_sphere(o, radius)
}

draw_capsule_collider_wires :: proc(c: ^CapsuleCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	axis: [3]f32
	switch c.direction {
	case .X_Axis: axis = {1, 0, 0}
	case .Y_Axis: axis = {0, 1, 0}
	case .Z_Axis: axis = {0, 0, 1}
	}
	radius, height, o := capsule_scaled(c, collider_scale(c.owner))
	half := max(height * 0.5 - radius, 0)
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(o, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		gizmos.wire_capsule(-axis * half, axis * half, radius)
	} else {
		gizmos.wire_capsule(o - axis * half, o + axis * half, radius)
	}
}

draw_box_collider_solid :: proc(c: ^BoxCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	size, o := box_scaled(c, collider_scale(c.owner))
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(o, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		gizmos.solid_box({0, 0, 0}, size)
	} else {
		gizmos.solid_box(o, size)
	}
}

draw_sphere_collider_solid :: proc(c: ^SphereCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius, o := sphere_scaled(c, collider_scale(c.owner))
	gizmos.solid_sphere(o, radius)
}

draw_capsule_collider_solid :: proc(c: ^CapsuleCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	axis: [3]f32
	switch c.direction {
	case .X_Axis: axis = {1, 0, 0}
	case .Y_Axis: axis = {0, 1, 0}
	case .Z_Axis: axis = {0, 0, 1}
	}
	radius, height, o := capsule_scaled(c, collider_scale(c.owner))
	half := max(height * 0.5 - radius, 0)
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(o, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		gizmos.solid_capsule(-axis * half, axis * half, radius)
	} else {
		gizmos.solid_capsule(o - axis * half, o + axis * half, radius)
	}
}

draw_mesh_collider_wires :: proc(c: ^MeshCollider, color: [4]f32) {
	w := engine.ctx_world()
	pptr, ok := resolve_mesh_collider_pptr(w, c)
	if !ok do return
	tmp_mf := engine.MeshFilter{mesh = pptr}
	verts, inds, g_ok := engine.mesh_read_cpu_geometry(&tmp_mf, context.temp_allocator)
	if !g_ok || len(verts) < 3 do return

	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	s := collider_scale(c.owner)
	o := c.center * s
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(o, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		o = {0, 0, 0}
	}

	tri_count := len(inds) / 3
	if tri_count > 0 && tri_count <= 256 {
		for t in 0 ..< tri_count {
			v0 := o + verts[inds[t * 3 + 0]].position * s
			v1 := o + verts[inds[t * 3 + 1]].position * s
			v2 := o + verts[inds[t * 3 + 2]].position * s
			gizmos.line(v0, v1)
			gizmos.line(v1, v2)
			gizmos.line(v2, v0)
		}
	} else {
		bmin := [3]f32{max(f32), max(f32), max(f32)}
		bmax := [3]f32{-max(f32), -max(f32), -max(f32)}
		for v in verts {
			p := v.position * s
			bmin = linalg.min(bmin, p)
			bmax = linalg.max(bmax, p)
		}
		gizmos.wire_box(o + (bmin + bmax) * 0.5, bmax - bmin)
	}
}

// Every enabled collider as a wireframe (Unity's Physics Debug view, there is
// no selection in the app).
@(phase={key=DebugDraw, mode=App})
debug_draw :: proc() {
	w := engine.ctx_world()
	it := engine.pool_iterator(box_colliders(w))
	for c, _ in engine.pool_next(&it) {
		if c.enabled do draw_box_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it2 := engine.pool_iterator(sphere_colliders(w))
	for c, _ in engine.pool_next(&it2) {
		if c.enabled do draw_sphere_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it3 := engine.pool_iterator(capsule_colliders(w))
	for c, _ in engine.pool_next(&it3) {
		if c.enabled do draw_capsule_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it4 := engine.pool_iterator(mesh_colliders(w))
	for c, _ in engine.pool_next(&it4) {
		if c.enabled do draw_mesh_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	if vol_pool := time_dilation_volumes(w); vol_pool != nil {
		it5 := engine.pool_iterator(vol_pool)
		for vol, _ in engine.pool_next(&it5) {
			if vol.enabled do draw_time_dilation_volume_wires(vol, TIME_DILATION_GIZMO_COLOR)
		}
	}
}
