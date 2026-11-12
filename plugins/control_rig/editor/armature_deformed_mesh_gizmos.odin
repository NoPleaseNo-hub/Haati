package control_rig_editor

// Unreal Engine-inspired Skeleton & Bone Gizmos for ArmatureDeformedMesh.
//
// Features:
// 1. Slender wire diamond/pyramid bones with clamped screen-space taper, matching Unreal Engine's bone aesthetics.
// 2. Direct joint pivot selection: bone joints register as pickable handles so clicking in the 3D viewport selects the bone.
// 3. Dual-mode rendering:
//    - Live Skeleton: draws the deformed bones when transforms are bound in the scene hierarchy.
//    - Mesh Rest Skeleton Preview: automatically derives and renders the bone skeleton directly from the mesh asset's
//      bind-pose geometry even before bones are extracted, so the user instantly sees the skeleton upon selecting any mesh.

import "core:math/linalg"
import "moonhug:engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"
import crig "moonhug:packages/control_rig"
import physics3d "moonhug:packages/physics3d"

@(private = "file")
_draw_unreal_bone :: proc(a, b: [3]f32, selected: bool, ambient: bool, dimmed := false, dim_alpha: f32 = 0.15) {
	d := b - a
	length := linalg.length(d)
	if length < 0.001 do return
	dir := d / length

	color := crig.skeleton_settings.bone_color_selected if selected else (crig.skeleton_settings.bone_color_ambient if ambient else crig.skeleton_settings.bone_color_default)
	thick := max(1.0, crig.skeleton_settings.bone_line_thickness)
	alpha := clamp(crig.skeleton_settings.solid_bone_alpha, 0.05, 1.0)

	if dimmed {
		color.a = clamp(dim_alpha, 0.0, 0.5)
		thick = 1.0
		alpha = clamp(dim_alpha * 0.3, 0.0, 0.15)
	}

	face_col := [4]f32{color.r, color.g, color.b, color.a * alpha}
	is_solid := crig.skeleton_settings.draw_solid_bones && !dimmed

	// If 3D bone volume is completely disabled or dimmed, fall back to simple wire strokes
	if !crig.skeleton_settings.draw_diamond_bones || dimmed {
		gizmos.with_color(color)
		gizmos.line(a, b)
		if thick > 1.1 && !dimmed {
			offset := 0.002 * (thick - 1.0)
			up := [3]f32{0, 1, 0}
			if abs(linalg.dot(dir, up)) > 0.95 do up = [3]f32{1, 0, 0}
			side := linalg.normalize0(linalg.cross(dir, up)) * offset
			ortho_up := linalg.normalize0(linalg.cross(side, dir)) * offset
			gizmos.line(a + side, b + side)
			gizmos.line(a - side, b - side)
			gizmos.line(a + ortho_up, b + ortho_up)
			gizmos.line(a - ortho_up, b - ortho_up)
		}
		return
	}

	// Basis for bone cross-section
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(dir, up)) > 0.95 do up = [3]f32{1, 0, 0}
	side := linalg.normalize0(linalg.cross(dir, up))
	ortho_up := linalg.normalize0(linalg.cross(side, dir))

	switch crig.skeleton_settings.bone_solid_shape {
	case .Cylinder:
		// Uniform round cylinder: Constant width, never balloons with bone length or distance!
		rad := 0.014 * max(0.1, crig.skeleton_settings.bone_thickness)
		rad = min(rad, length * 0.35)
		if is_solid {
			gizmos.with_color(face_col)
			gizmos.solid_cylinder(a, b, rad, segments = 16)
		}
		gizmos.with_color(color)
		gizmos.wire_cylinder(a, b, rad, segments = 16)
		core_col := [4]f32{color.r, color.g, color.b, color.a * 0.40}
		gizmos.with_color(core_col)
		gizmos.line(a, b)

	case .Capsule:
		// Smooth rounded capsule: Constant width, capped ends
		rad := 0.014 * max(0.1, crig.skeleton_settings.bone_thickness)
		rad = min(rad, length * 0.35)
		if is_solid {
			gizmos.with_color(face_col)
			gizmos.solid_capsule(a, b, rad, segments = 12)
		}
		gizmos.with_color(color)
		gizmos.wire_capsule(a, b, rad, segments = 12)
		core_col := [4]f32{color.r, color.g, color.b, color.a * 0.40}
		gizmos.with_color(core_col)
		gizmos.line(a, b)

	case .Box:
		// Uniform rectangular bar/prism: Constant cross-section
		hw := 0.012 * max(0.1, crig.skeleton_settings.bone_thickness)
		hw = min(hw, length * 0.35)
		c0 := a + side * hw + ortho_up * hw
		c1 := a - side * hw + ortho_up * hw
		c2 := a - side * hw - ortho_up * hw
		c3 := a + side * hw - ortho_up * hw
		c4 := b + side * hw + ortho_up * hw
		c5 := b - side * hw + ortho_up * hw
		c6 := b - side * hw - ortho_up * hw
		c7 := b + side * hw - ortho_up * hw

		if is_solid {
			gizmos.with_color(face_col)
			// Base quad
			gizmos.solid_triangle(c0, c1, c2)
			gizmos.solid_triangle(c0, c2, c3)
			// Tip quad
			gizmos.solid_triangle(c4, c7, c6)
			gizmos.solid_triangle(c4, c6, c5)
			// Side +ortho_up
			gizmos.solid_triangle(c0, c4, c5)
			gizmos.solid_triangle(c0, c5, c1)
			// Side -ortho_up
			gizmos.solid_triangle(c3, c2, c6)
			gizmos.solid_triangle(c3, c6, c7)
			// Side +side
			gizmos.solid_triangle(c0, c3, c7)
			gizmos.solid_triangle(c0, c7, c4)
			// Side -side
			gizmos.solid_triangle(c1, c5, c6)
			gizmos.solid_triangle(c1, c6, c2)
		}
		gizmos.with_color(color)
		gizmos.line(c0, c1); gizmos.line(c1, c2); gizmos.line(c2, c3); gizmos.line(c3, c0)
		gizmos.line(c4, c5); gizmos.line(c5, c6); gizmos.line(c6, c7); gizmos.line(c7, c4)
		gizmos.line(c0, c4); gizmos.line(c1, c5); gizmos.line(c2, c6); gizmos.line(c3, c7)
		core_col := [4]f32{color.r, color.g, color.b, color.a * 0.40}
		gizmos.with_color(core_col)
		gizmos.line(a, b)

	case .Stick:
		// Slender solid rod (Blender stick mode)
		rad := 0.005 * max(0.1, crig.skeleton_settings.bone_thickness)
		if is_solid {
			gizmos.with_color(face_col)
			gizmos.solid_cylinder(a, b, rad, segments = 8)
		}
		gizmos.with_color(color)
		gizmos.line(a, b)

	case .Diamond:
		// Classic octahedral diamond, with clamped maximum width to prevent distance ballooning
		mid_t: f32 = 0.20
		mid := a + dir * (length * mid_t)
		width := min(length * 0.07, 0.08) * max(0.05, crig.skeleton_settings.bone_thickness)

		p0 := mid + side * width
		p1 := mid + ortho_up * width
		p2 := mid - side * width
		p3 := mid - ortho_up * width

		if is_solid {
			gizmos.with_color(face_col)
			// Base pyramid
			gizmos.solid_triangle(a, p0, p1)
			gizmos.solid_triangle(a, p1, p2)
			gizmos.solid_triangle(a, p2, p3)
			gizmos.solid_triangle(a, p3, p0)
			// Tip pyramid
			gizmos.solid_triangle(b, p1, p0)
			gizmos.solid_triangle(b, p2, p1)
			gizmos.solid_triangle(b, p3, p2)
			gizmos.solid_triangle(b, p0, p3)
		}

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

		if thick > 1.1 {
			off := 0.0015 * (thick - 1.0)
			s_off := side * off
			o_off := ortho_up * off
			gizmos.line(a + s_off, p0 + s_off)
			gizmos.line(a - s_off, p2 - s_off)
			gizmos.line(a + o_off, p1 + o_off)
			gizmos.line(a - o_off, p3 - o_off)
			gizmos.line(p0 + s_off, b + s_off)
			gizmos.line(p2 - s_off, b - s_off)
			gizmos.line(p1 + o_off, b + o_off)
			gizmos.line(p3 - o_off, b - o_off)
		}

		// Faint centerline
		core_col := [4]f32{color.r, color.g, color.b, color.a * 0.45}
		gizmos.with_color(core_col)
		gizmos.line(a, b)
	}
}

@(on_draw_gizmos={component=ArmatureDeformedMesh})
armature_deformed_mesh_gizmos :: proc(adm: ^crig.ArmatureDeformedMesh, ctx: handles.Gizmo_Context) {
	w := engine.ctx_world()
	if w == nil do return

	mesh_guid := adm.mesh
	part: i32 = adm.bound_part
	if engine.asset_guid_is_empty(mesh_guid) {
		owner_h := engine.Transform_Handle(adm.owner)
		_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
		if mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
			mesh_guid = mf.mesh.guid
			if p, ok := engine.mesh_filter_part(mf); ok do part = p
		}
	}
	if engine.asset_guid_is_empty(mesh_guid) do return

	mesh, ok := engine.mesh_load(mesh_guid, part)
	if !ok || mesh == nil do return
	if !engine.mesh_is_skinned(mesh) || len(mesh.inverse_binds) == 0 do return

	owner_h := engine.Transform_Handle(adm.owner)
	if !engine.transform_active_in_hierarchy(owner_h) do return

	actor_tw := engine.transform_world(owner_h)
	actor_m := engine.trs_matrix(actor_tw.position, actor_tw.rotation, actor_tw.scale)

	is_selected := .In_Selection in ctx.state || .Selected in ctx.state
	if !is_selected {
		active_sel := engine.inspector_active_selection()
		for j in adm.joints {
			if j != {} && (j == active_sel || engine.inspector_selection_contains(j)) {
				is_selected = true
				break
			}
		}
	}
	active_char := get_active_character_owner()
	if scene_viewport_mode != .Control_Rig {
		return
	}
	if active_char != {} && active_char != owner_h && !is_selected {
		return
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// Mode A: Live Bone Transforms in Hierarchy
	has_bound_joints := false
	if len(adm.joints) > 0 {
		for j in adm.joints {
			if j != {} && engine.pool_valid(&w.transforms, engine.Handle(j)) {
				has_bound_joints = true
				break
			}
		}
	}

	is_paint_active := (scene_viewport_mode == .Control_Rig && character_edit_mode == .Bone_Mode && (weight_painter.enabled || crig.show_bone_weights_heatmap))
	is_hand_poses_mode := (scene_viewport_mode == .Control_Rig && character_edit_mode == .Hand_Poses)
	is_colliders_mode := (scene_viewport_mode == .Control_Rig && character_edit_mode == .Colliders)
	dim_inactive := (is_paint_active && crig.skeleton_settings.dim_inactive_bones_in_paint_mode) || is_hand_poses_mode || is_colliders_mode
	paint_dim_alpha := is_hand_poses_mode ? f32(0.12) : (is_colliders_mode ? f32(0.18) : crig.skeleton_settings.inactive_bones_paint_alpha)
	in_bone_workspace := (scene_viewport_mode == .Control_Rig && (character_edit_mode == .Bone_Mode || character_edit_mode == .Colliders))

	if has_bound_joints {
		for j in adm.joints {
			if j == {} || !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue
			if !engine.transform_active_in_hierarchy(j) do continue
			t := engine.pool_get(&w.transforms, engine.Handle(j))
			if t == nil do continue

			pos := engine.transform_world_position(j)
			bone_sel := engine.inspector_selection_contains(j) || engine.inspector_active_selection() == j || (is_paint_active && j == crig.active_heatmap_bone_h)
			is_dimmed := dim_inactive && !bone_sel

			// Only register clickable 2D bone joint icons in Bone_Mode — NEVER in Colliders mode,
			// so clicking in Colliders mode strictly picks 3D colliders instead of bone joints!
			if scene_viewport_mode == .Control_Rig && character_edit_mode == .Bone_Mode {
				gizmos.icon(pos, 16.0, j, nil, {0, 0, 0, 0})
			}

			joint_col: [4]f32
			if bone_sel {
				joint_col = crig.skeleton_settings.bone_color_selected
			} else if is_dimmed {
				joint_col = crig.skeleton_settings.bone_joint_color
				joint_col.a = clamp(paint_dim_alpha, 0.0, 0.5)
			} else {
				joint_col = crig.skeleton_settings.bone_joint_color if is_selected else crig.skeleton_settings.bone_color_ambient
			}
			gizmos.with_color(joint_col)
			gizmos.wire_sphere(pos, is_dimmed ? max(0.003, crig.skeleton_settings.joint_radius * 0.6) : max(0.005, crig.skeleton_settings.joint_radius), segments = 8)

			show_this_label := (bone_sel && in_bone_workspace) || (crig.skeleton_settings.show_bone_labels && !is_dimmed && scene_viewport_mode == .Control_Rig && character_edit_mode == .Bone_Mode && is_selected)
			if show_this_label {
				lbl_col := crig.skeleton_settings.bone_label_color_selected if bone_sel else crig.skeleton_settings.bone_label_color
				gizmos.with_color(lbl_col)
				gizmos.label(pos, t.name, align = {-0.5, 1.0}, offset_px = {0, -12}, scale = crig.skeleton_settings.bone_label_scale)
			}

			if t.parent.handle != {} {
				parent_h := engine.Transform_Handle(t.parent.handle)
				if engine.transform_active_in_hierarchy(parent_h) {
					parent_pos := engine.transform_world_position(parent_h)
					_draw_unreal_bone(parent_pos, pos, bone_sel, !is_selected, dimmed = is_dimmed, dim_alpha = paint_dim_alpha)
				}
			}

			// Draw bone colliders when in Control Rig mode and show_bone_colliders is active
			if scene_viewport_mode == .Control_Rig && show_bone_colliders && (!is_dimmed || bone_sel) {
				base_color := [4]f32{1.0, 0.85, 0.20, 0.95} if bone_sel else [4]f32{0.25, 0.85, 0.35, 0.85}
				solid_color := base_color
				solid_color.a = clamp(collider_solid_alpha, 0.05, 0.90)
				wire_color := base_color
				wire_color.a = 0.95

				_, cap := engine.transform_get_comp(j, physics3d.CapsuleCollider)
				if cap != nil {
					if collider_shading_mode == .Semi_Transparent || collider_shading_mode == .Solid_Only {
						physics3d.draw_capsule_collider_solid(cap, solid_color)
					}
					if collider_shading_mode == .Semi_Transparent || collider_shading_mode == .Wireframe {
						physics3d.draw_capsule_collider_wires(cap, wire_color)
					}
				}
				_, box := engine.transform_get_comp(j, physics3d.BoxCollider)
				if box != nil {
					if collider_shading_mode == .Semi_Transparent || collider_shading_mode == .Solid_Only {
						physics3d.draw_box_collider_solid(box, solid_color)
					}
					if collider_shading_mode == .Semi_Transparent || collider_shading_mode == .Wireframe {
						physics3d.draw_box_collider_wires(box, wire_color)
					}
				}
				_, sph := engine.transform_get_comp(j, physics3d.SphereCollider)
				if sph != nil {
					if collider_shading_mode == .Semi_Transparent || collider_shading_mode == .Solid_Only {
						physics3d.draw_sphere_collider_solid(sph, solid_color)
					}
					if collider_shading_mode == .Semi_Transparent || collider_shading_mode == .Wireframe {
						physics3d.draw_sphere_collider_wires(sph, wire_color)
					}
				}
			}


			// Draw SpringBone secondary dynamic tip & spring connector if present
			if scene_viewport_mode == .Control_Rig && (!is_dimmed || bone_sel) {
				_, sb := engine.transform_get_comp(j, crig.SpringBone)
				if sb != nil && sb.current_tip_pos != {} {
					gizmos.with_color({0.20, 0.85, 0.95, 0.95})
					gizmos.line(pos, sb.current_tip_pos)
					gizmos.wire_sphere(sb.current_tip_pos, 0.014, segments = 12)
				}
			}
		}
		if is_hand_poses_mode {
			draw_hand_poses_viewport_gizmos(owner_h)
		}
		weight_painter_draw_gizmo()
		return
	}

	// Mode B: Mesh Rest Skeleton Preview (when bone GameObjects are not yet spawned into the scene)
	// Derives world positions for all bones from mesh.inverse_binds transformed by actor_m
	rest_positions := make([][3]f32, len(mesh.inverse_binds), context.temp_allocator)
	for i in 0 ..< len(mesh.inverse_binds) {
		inv := mesh.inverse_binds[i]
		bind_m := linalg.inverse(inv)
		local_pos := [3]f32{bind_m[3, 0], bind_m[3, 1], bind_m[3, 2]}
		p4 := actor_m * [4]f32{local_pos.x, local_pos.y, local_pos.z, 1}
		rest_positions[i] = p4.xyz
	}

	for i in 0 ..< len(rest_positions) {
		pos := rest_positions[i]
		name := mesh.joint_names[i] if i < len(mesh.joint_names) else ""
		bone_sel := is_selected
		is_dimmed := dim_inactive && !bone_sel

		joint_col := crig.skeleton_settings.bone_color_selected if is_selected else crig.skeleton_settings.bone_joint_color
		if is_dimmed do joint_col.a = clamp(paint_dim_alpha, 0.0, 0.5)
		gizmos.with_color(joint_col)
		gizmos.wire_sphere(pos, is_dimmed ? max(0.003, crig.skeleton_settings.joint_radius * 0.6) : max(0.005, crig.skeleton_settings.joint_radius), segments = 8)

		if crig.skeleton_settings.show_bone_labels && is_selected && !is_dimmed {
			gizmos.with_color(crig.skeleton_settings.bone_label_color)
			if len(name) > 0 {
				gizmos.label(pos, name, align = {-0.5, 1.0}, offset_px = {0, -10}, scale = crig.skeleton_settings.bone_label_scale)
			}
		}

		// Connect nearby skeleton chain bones: find closest joint in skin order
		min_dist: f32 = 0.85
		parent_idx := -1
		for p in 0 ..< i {
			d := linalg.length(pos - rest_positions[p])
			if d > 0.02 && d < min_dist {
				min_dist = d
				parent_idx = p
			}
		}
		if parent_idx != -1 {
			_draw_unreal_bone(rest_positions[parent_idx], pos, is_selected, !is_selected, dimmed = is_dimmed, dim_alpha = paint_dim_alpha)
		}
	}
	weight_painter_draw_gizmo()
}
