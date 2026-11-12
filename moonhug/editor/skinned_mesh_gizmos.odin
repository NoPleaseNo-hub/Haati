package editor

// Unreal Engine-inspired Skeleton & Bone Gizmos for SkinnedMeshRenderer.
//
// Draws clean, slender wire diamond/pyramid bones with clamped screen-space thickness
// so bones remain clearly visible without expanding into bulky octahedra that obscure the mesh.
// Bone joints are registered as pickable targets, allowing direct click-selection in the 3D scene view.

import "core:math/linalg"
import "moonhug:engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"

BONE_COLOR_DEFAULT  :: [4]f32{0.2, 0.75, 1.0, 0.75} // Unreal ice-blue wire
BONE_COLOR_SELECTED :: [4]f32{1.0, 0.85, 0.2, 1.0}  // Radiant gold for selected bone
BONE_COLOR_AMBIENT  :: [4]f32{0.2, 0.65, 0.85, 0.35} // Soft ghost overlay when unselected
BONE_JOINT_COLOR    :: [4]f32{0.3, 0.85, 1.0, 0.9}
BONE_JOINT_SELECTED :: [4]f32{1.0, 0.95, 0.5, 1.0}

_draw_unreal_bone :: proc(a, b: [3]f32, selected: bool, ambient: bool) {
	d := b - a
	length := linalg.length(d)
	if length < 0.001 do return
	dir := d / length

	// Up vector for orthonormal basis
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(dir, up)) > 0.95 do up = [3]f32{1, 0, 0}
	side := linalg.normalize0(linalg.cross(dir, up))
	ortho_up := linalg.normalize0(linalg.cross(side, dir))

	// Clamped taper width (avoids giant bulky Blender octahedra)
	mid_t: f32 = 0.20
	mid := a + dir * (length * mid_t)
	width := clamp(length * 0.07, 0.005, 0.035)

	p0 := mid + side * width
	p1 := mid + ortho_up * width
	p2 := mid - side * width
	p3 := mid - ortho_up * width

	color := BONE_COLOR_SELECTED if selected else (BONE_COLOR_AMBIENT if ambient else BONE_COLOR_DEFAULT)

	gizmos.with_color(color)
	// Base to diamond waist
	gizmos.line(a, p0)
	gizmos.line(a, p1)
	gizmos.line(a, p2)
	gizmos.line(a, p3)

	// Diamond waist ring
	gizmos.line(p0, p1)
	gizmos.line(p1, p2)
	gizmos.line(p2, p3)
	gizmos.line(p3, p0)

	// Diamond waist to tip
	gizmos.line(p0, b)
	gizmos.line(p1, b)
	gizmos.line(p2, b)
	gizmos.line(p3, b)

	// Faint centerline
	core_col := [4]f32{color.r, color.g, color.b, color.a * 0.4}
	gizmos.with_color(core_col)
	gizmos.line(a, b)
}

@(on_draw_gizmos={component=SkinnedMeshRenderer})
skinned_mesh_gizmos :: proc(smr: ^engine.SkinnedMeshRenderer, ctx: handles.Gizmo_Context) {
	w := engine.ctx_world()
	if w == nil do return

	joints := smr.joints
	if len(joints) == 0 do return

	// Determine if the character or any of its bones are selected
	is_skeleton_selected := .In_Selection in ctx.state || .Selected in ctx.state
	if !is_skeleton_selected {
		for j in joints {
			if j == {} do continue
			b_ctx := gizmo_context(j)
			if .In_Selection in b_ctx.state || .Selected in b_ctx.state {
				is_skeleton_selected = true
				break
			}
		}
	}

	if !is_skeleton_selected do return

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	for j in joints {
		if j == {} do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue

		t := engine.pool_get(&w.transforms, engine.Handle(j))
		if t == nil do continue

		pos := engine.transform_world_position(j)
		b_ctx := gizmo_context(j)
		is_selected := .Selected in b_ctx.state

		// Register joint for scene view mouse picking
		gizmos.icon(pos, 16.0, j, nil, {0, 0, 0, 0})

		// Draw joint pivot
		joint_color := BONE_JOINT_SELECTED if is_selected else BONE_JOINT_COLOR
		gizmos.with_color(joint_color)
		gizmos.wire_sphere(pos, 0.012, segments = 8)

		if is_selected {
			gizmos.with_color(BONE_COLOR_SELECTED)
			gizmos.label(pos, t.name, align = {-0.5, 1.0}, offset_px = {0, -12})
		}

		// Find parent bone in skeleton
		if t.parent.handle != {} {
			parent_h := engine.Transform_Handle(t.parent.handle)
			parent_pos := engine.transform_world_position(parent_h)
			_draw_unreal_bone(parent_pos, pos, is_selected, !is_skeleton_selected)
		}
	}
}
