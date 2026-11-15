package physics3d_editor

// Collider wireframes in the scene view via the @(on_draw_gizmos) hook — drawn
// only for objects in the selection (a parent selected counts). The wire geometry
// lives in the runtime package (packages/physics3d/gizmos.odin), shared with
// the in-app @(debug_draw) view — here only the selected-only policy and the
// color choice remain.
//
// In the Handles tool (T), bounds handles on the selected colliders resize
// them (@(on_scene_handles)), one undo step per drag.

import "core:fmt"
import "core:math/linalg"
import im "haati:external/odin-imgui"
import "haati:engine"
import "haati:engine/gizmos"
import "haati:editor/handles"
import "haati:editor/inspector"
import "haati:editor/undo"
import "haati:editor/widgets"
import physics3d "haati:packages/physics3d"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
physics3d_editor_install :: proc() {
	inspector.mapPropertyDrawer[typeid_of(physics3d.Collision_Mask)] = draw_collision_mask_property
}

draw_collision_mask_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	mask_ptr := cast(^physics3d.Collision_Mask)ptr
	if mask_ptr == nil do return
	val := mask_ptr^

	inspector.field_row(label)
	im.PushIDPtr(ptr)
	defer im.PopID()

	avail_w := im.GetContentRegionAvail().x
	drop_w := f32(22.0)
	spacing := f32(2.0)
	btn_w := max((avail_w - drop_w - spacing * 8.0) / 8.0, 16.0)

	for i in 0 ..< int(physics3d.NUM_LAYERS) {
		if i > 0 do im.SameLine(0, spacing)
		bit := physics3d.Collision_Mask(1 << u32(i))
		is_on := (val & bit) != 0
		if is_on {
			im.PushStyleColorImVec4(.Button, {0.16, 0.52, 0.28, 1.0})
			im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.64, 0.36, 1.0})
			im.PushStyleColorImVec4(.ButtonActive, {0.12, 0.42, 0.22, 1.0})
			im.PushStyleColorImVec4(.Text, {0.95, 1.0, 0.95, 1.0})
		} else {
			im.PushStyleColorImVec4(.Button, {0.15, 0.16, 0.19, 1.0})
			im.PushStyleColorImVec4(.ButtonHovered, {0.24, 0.26, 0.30, 1.0})
			im.PushStyleColorImVec4(.ButtonActive, {0.20, 0.22, 0.26, 1.0})
			im.PushStyleColorImVec4(.Text, {0.48, 0.50, 0.55, 1.0})
		}
		btn_lbl := fmt.ctprintf("%d##ch_%d", i + 1, i)
		if im.Button(btn_lbl, {btn_w, 0}) {
			if is_on {
				val &= ~bit
			} else {
				val |= bit
			}
			mask_ptr^ = val
			inspector.field_edit_row_hold()
			inspector.mark_inspector_changed()
		}
		im.PopStyleColor(4)
		ch_name := physics3d.collision_channel_label(i)
		widgets.tooltip(fmt.ctprintf("%d: %s — %s (Click to toggle)", i + 1, ch_name, is_on ? "ACTIVE (Blocks / Collides)" : "IGNORED"))
	}

	im.SameLine(0, spacing)
	if im.Button("v##ch_popup_btn", {drop_w, 0}) {
		im.OpenPopup("##ch_mask_popup")
	}
	widgets.tooltip("Open named channel list (configure channel names in Project Settings -> Physics 3D)")

	if im.BeginPopup("##ch_mask_popup") {
		inspector.field_edit_row_hold()
		if im.Button("All Channels", {105, 0}) {
			val = physics3d.Collision_Mask(0xFF)
			mask_ptr^ = val
			inspector.mark_inspector_changed()
		}
		im.SameLine()
		if im.Button("Ignore All", {105, 0}) {
			val = 0
			mask_ptr^ = val
			inspector.mark_inspector_changed()
		}
		im.Separator()
		for i in 0 ..< int(physics3d.NUM_LAYERS) {
			bit := physics3d.Collision_Mask(1 << u32(i))
			checked := (val & bit) != 0
			ch_name := physics3d.collision_channel_label(i)
			row_lbl := fmt.ctprintf("%d: %s##chk_%d", i + 1, ch_name, i)
			if im.Checkbox(row_lbl, &checked) {
				if checked {
					val |= bit
				} else {
					val &= ~bit
				}
				mask_ptr^ = val
				inspector.mark_inspector_changed()
			}
		}
		im.EndPopup()
	}
}

@(on_draw_gizmos={component=BoxCollider})
box_collider_gizmos :: proc(c: ^physics3d.BoxCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_box_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=SphereCollider})
sphere_collider_gizmos :: proc(c: ^physics3d.SphereCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_sphere_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=CapsuleCollider})
capsule_collider_gizmos :: proc(c: ^physics3d.CapsuleCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_capsule_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=MeshCollider})
mesh_collider_gizmos :: proc(c: ^physics3d.MeshCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_mesh_collider_wires(c, physics3d.COLLIDER_GIZMO_COLOR)
}

@(on_draw_gizmos={component=SpringArm3D})
spring_arm_gizmos :: proc(arm: ^physics3d.SpringArm3D, ctx: handles.Gizmo_Context) {
	if !arm.in_play_mode {
		physics3d.spring_arm_sync_children(arm, engine.ctx_world(), arm.spring_length)
	}
	if .In_Selection not_in ctx.state do return
	physics3d.draw_spring_arm_wires(arm, physics3d.SPRING_ARM_GIZMO_COLOR)
}

@(on_draw_gizmos={component=TimeDilationVolume})
time_dilation_volume_gizmos :: proc(vol: ^physics3d.TimeDilationVolume, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics3d.draw_time_dilation_volume_wires(vol, physics3d.TIME_DILATION_GIZMO_COLOR)
}

// --- Bounds handles --------------------------------------------------------------
// The handles work in the collider's space with scaled sizes, as the wires do.
// A field changes only on the axes the drag changed, so a click without a
// move, or the scale round trip, never touches the others.

@(private = "file")
_edit: undo.Edit_Session

@(private = "file")
_axis :: proc(d: physics3d.Capsule_Direction) -> handles.Axis {
	switch d {
	case .X_Axis: return .X
	case .Y_Axis: return .Y
	case .Z_Axis: return .Z
	}
	return .Y
}

@(on_scene_handles={component=BoxCollider})
box_collider_handles :: proc(c: ^physics3d.BoxCollider, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics3d.collider_scale(c.owner)
	gizmos.in_local_space(c.owner, use_scale = false)
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	size0, center0 := physics3d.box_scaled(c, s)
	size := size0
	center: [3]f32
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(center0, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		center = {0, 0, 0}
	} else {
		center = center0
	}
	d := handles.box_bounds(handles.id_of(h), &center, &size, color = physics3d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.size, typeid_of([3]f32)),
			undo.edit_target_pooled(h, &c.center, typeid_of([3]f32)),
		}
		handles.begin_drag_edit(&_edit, targets[:], "Edit Box Collider")
	}
	if d.dragging || d.released {
		handles.unscale_vec3(&c.size, size, size0, s)
		if rot != {0, 0, 0, 1} {
			rot_native := engine.quat_to_native(rot)
			actual_center := center0 + linalg.quaternion128_mul_vector3(rot_native, center)
			handles.unscale_vec3(&c.center, actual_center, center0, s)
		} else {
			handles.unscale_vec3(&c.center, center, center0, s)
		}
	}
	if d.released do undo.edit_session_end(&_edit)
}

@(on_scene_handles={component=SphereCollider})
sphere_collider_handles :: proc(c: ^physics3d.SphereCollider, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics3d.collider_scale(c.owner)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius0, center0 := physics3d.sphere_scaled(c, s)
	radius, center := radius0, center0
	d := handles.sphere_bounds(handles.id_of(h), &center, &radius, color = physics3d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.radius, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.center, typeid_of([3]f32)),
		}
		handles.begin_drag_edit(&_edit, targets[:], "Edit Sphere Collider")
	}
	if d.dragging || d.released {
		handles.unscale_scalar(&c.radius, radius, radius0, max(s.x, s.y, s.z))
		handles.unscale_vec3(&c.center, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}

@(on_scene_handles={component=CapsuleCollider})
capsule_collider_handles :: proc(c: ^physics3d.CapsuleCollider, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics3d.collider_scale(c.owner)
	gizmos.in_local_space(c.owner, use_scale = false)
	rot := c.rotation
	if rot == {} do rot = {0, 0, 0, 1}
	radius0, height0, center0 := physics3d.capsule_scaled(c, s)
	radius, height := radius0, height0
	center: [3]f32
	if rot != {0, 0, 0, 1} {
		m := engine.trs_matrix(center0, rot, {1, 1, 1})
		gizmos.with_matrix(m)
		center = {0, 0, 0}
	} else {
		center = center0
	}
	axis := _axis(c.direction)
	d := handles.capsule_bounds(handles.id_of(h), &center, &radius, &height, axis, color = physics3d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.radius, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.height, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.center, typeid_of([3]f32)),
		}
		handles.begin_drag_edit(&_edit, targets[:], "Edit Capsule Collider")
	}
	if d.dragging || d.released {
		// The scale capsule_scaled applies: the long axis for the height,
		// the larger of the other two for the radius.
		i := int(axis)
		handles.unscale_scalar(&c.radius, radius, radius0, max(s[(i + 1) % 3], s[(i + 2) % 3]))
		handles.unscale_scalar(&c.height, height, height0, s[i])
		if rot != {0, 0, 0, 1} {
			rot_native := engine.quat_to_native(rot)
			actual_center := center0 + linalg.quaternion128_mul_vector3(rot_native, center)
			handles.unscale_vec3(&c.center, actual_center, center0, s)
		} else {
			handles.unscale_vec3(&c.center, center, center0, s)
		}
	}
	if d.released do undo.edit_session_end(&_edit)
}
