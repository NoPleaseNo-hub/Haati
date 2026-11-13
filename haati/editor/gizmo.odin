package editor

// The scene view's transform tool (W E R): a caller of the move, rotate and
// scale handles (editor/handles/transform_handles.odin). The handles own the
// pointer, the drawing and the drag math. The tool owns what a drag does:
//
// - Drags apply to EVERY selected top-level object: move offsets them all,
//   rotate orbits positions around the gizmo and turns orientations, scale
//   scales offsets and local scales. Start states are captured at grab, and
//   every frame applies start + the drag since the grab.
// - One undo step per drag: an edit session opened at grab and closed at
//   release, or when the drag's handle goes away (a mode switch, the
//   selection emptied).
// - The gizmo sits on the active object's pivot or the centroid of the
//   selection (gizmo_pivot). Move and rotate follow gizmo_space, scale is
//   always on the object's own axes.
// - Its parts use handles.PRIO_TOOL: a component's own handle under the
//   pointer takes the click.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import im "haati:external/odin-imgui"
import "haati:editor/handles"
import "haati:engine/gizmos"
import "../engine"
import "undo"
import control_rig_editor "haati:packages/control_rig/editor"
import cad_csg_editor "haati:packages/cad_csg/editor"

// The scene view's tool (handles.Tool): Q selection only, W E R the
// transform gizmo, T the selection's own handles in place of the gizmo.
Gizmo_Mode :: handles.Tool

gizmo_mode: Gizmo_Mode = .Translate

// Gizmo axis orientation: Global = world axes, Local = the object's rotated
// axes. Scale ignores this: it always composes in local space.
Gizmo_Space :: enum {
	Global,
	Local,
}

gizmo_space: Gizmo_Space = .Global

// Gizmo position: the active object's pivot, or the centroid of the selected
// top-level objects (the pivot average stands in for the combined bounds
// center).
Gizmo_Pivot :: enum {
	Pivot,
	Center,
}

gizmo_pivot: Gizmo_Pivot = .Pivot

gizmo_origin :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	if gizmo_pivot == .Center {
		sum: [3]f32
		n := 0
		for h in sel_scene_top_level() {
			sum += engine.transform_world_position(h)
			n += 1
		}
		if n > 0 do return sum / f32(n)
	}
	return engine.transform_world_position(tH)
}

// Snap is the Snap popup's Enabled XOR the snap modifier: it temporarily
// snaps when the toggle is off and frees the drag when it's on. io.KeyCtrl is
// Ctrl on Windows and Linux, Cmd on macOS (imgui's ConfigMacOSXBehaviors
// remaps it there). The gizmo pass turns this into the handles' snap steps.
_gizmo_snap_active :: proc() -> bool {
	return snap_settings.enabled != im.GetIO().KeyCtrl
}

_gizmo_snap_angle :: proc() -> f32 {
	return math.to_radians(max(snap_settings.angle, 1))
}

// Gizmo screen presence: fraction of the camera distance, so it stays a
// constant apparent size while zooming.
_GIZMO_SIZE_FACTOR :: f32(0.15)

// The tool's handle id: the composites salt their parts from it.
@(private = "file")
_TOOL_ID :: u64(0x7472_616e_7366_6f72)

_gizmo_dragging: bool
_gizmo_start_world: [3]f32 // gizmo origin (pivot point) at grab

// What the rotate and scale handles edit during a drag: the turn since the
// grab (from _gizmo_rot_start) and the per-axis scale factor.
@(private = "file")
_gizmo_rot: quaternion128 = 1
@(private = "file")
_gizmo_rot_start: quaternion128 = 1
@(private = "file")
_gizmo_factor: [3]f32 = {1, 1, 1}

// One drag applies to every selected top-level object. Start states are
// captured at grab, the per-frame apply is absolute (start + delta).
_Gizmo_Target :: struct {
	tH:          engine.Transform_Handle,
	start_pos:   [3]f32, // world
	start_rot:   [4]f32, // world
	start_scale: [3]f32, // local
}
_gizmo_targets: [dynamic]_Gizmo_Target

// One transaction for the whole drag, however many objects it moves. Opened
// at grab, closed at release (docs/Undo.md): the session captures every
// target's before-state at one instant and emits a single grouped action.
@(private)
_gizmo_edit: undo.Edit_Session

// True while the gizmo or a handle owns the mouse (hot or dragging): the
// scene view then neither picks nor starts a box select, so grabs never
// select through.
scene_tools_consume_mouse :: proc() -> bool {
	if cad_csg_editor.is_cad_tool_active() {
		return true
	}
	// CAD Mesh Editor: pointer over a vertex / edge / face of the edited mesh (or mid sub-object drag)
	if cad_csg_editor.mesh_editor_wants_mouse() {
		return true
	}
	if control_rig_editor.is_brush_painting() || control_rig_editor.hand_pose_slider_dragging() {
		return true
	}
	return handles.consumes_mouse()
}

// True while a transform gizmo or handle drag is in progress.
scene_tools_dragging :: proc() -> bool {
	if control_rig_editor.is_brush_painting() || control_rig_editor.hand_pose_slider_dragging() {
		return true
	}
	return handles.dragging()
}

// True while Control Rig -> Rig Controls mode is active in Scene 3D.
// Clicking empty viewport space (or pressing Escape) in this mode clears rig-control
// selection first instead of raycasting floor/background meshes behind the character.
scene_rig_controls_mode_active :: proc() -> bool {
	return control_rig_editor.scene_viewport_mode == .Control_Rig &&
	       control_rig_editor.character_edit_mode == .Rig_Controls &&
	       control_rig_editor.show_rig_controls
}

scene_rig_controls_clear_if_any :: proc() -> bool {
	if card(control_rig_editor.selected_rig_controls) > 0 {
		control_rig_editor.clear_rig_selection()
		return true
	}
	return false
}

// The transform tool's frame, from the gizmo pass after the handle hooks: the
// gizmo on the active object in W E R, and the end of a drag whose gizmo went
// away (Q or T pressed mid-drag, the selection emptied).
gizmo_tool_frame :: proc() {
	if req_tool, has_req := control_rig_editor.consume_requested_gizmo_tool(); has_req {
		gizmo_mode = req_tool
	}
	control_rig_editor.current_gizmo_tool = gizmo_mode

	if scene_2d_ruler_active || cad_csg_editor.is_cad_tool_active() || cad_csg_editor.is_editing_csg_brush() || cad_csg_editor.mesh_editor_owns_viewport() {
		gizmo_end_drag_if_any()
		return
	}
	sel := sel_scene_active()
	if control_rig_editor.scene_viewport_mode == .Control_Rig {
		// In Collider Mode (`character_edit_mode == .Colliders`), the 3D Move/Rotate/Scale gizmo
		// exclusively edits the selected bone's Collider (`center`, `rotation`, `size`/`radius`/`height`)
		// and NEVER moves, rotates, or scales the bone Transform itself!
		if control_rig_editor.character_edit_mode == .Colliders {
			gizmo_end_drag_if_any()
			if gizmo_mode != .Handles && sel != _HANDLE_NONE && !engine.node_is_locked_in_hierarchy(sel) {
				control_rig_editor.draw_collider_mode_transform_gizmo(sel, gizmo_mode)
			} else {
				control_rig_editor.end_collider_mode_gizmo_drag()
			}
			return
		} else {
			control_rig_editor.end_collider_mode_gizmo_drag()
		}
		// In Rig_Controls mode, suppress the active character's root actor TRS gizmo (which sits
		// right between L_Foot and R_Foot and steals clicks / drags the whole actor off the ground).
		// Rig controls draw their own dedicated 3D manipulator in control_rig_gizmos.
		active_char := control_rig_editor.get_active_character_owner()
		if control_rig_editor.character_edit_mode == .Rig_Controls &&
		   control_rig_editor.show_rig_controls &&
		   (sel == _HANDLE_NONE || sel == active_char || sel == control_rig_editor.selected_rig_owner) {
			gizmo_end_drag_if_any()
			return
		}
	} else {
		control_rig_editor.end_collider_mode_gizmo_drag()
	}
	if gizmo_mode != .Handles && sel != _HANDLE_NONE && !engine.node_is_locked_in_hierarchy(sel) {
		gizmo_draw_and_handle(sel)
	} else {
		gizmo_end_drag_if_any()
	}
}

// The gizmo for tH in the handles frame (handles.frame: view, pointer,
// buttons, snap steps), and what its drag does to the selection.
gizmo_draw_and_handle :: proc(tH: engine.Transform_Handle) {
	gizmos.in_world_space()
	origin := gizmo_origin(tH)
	v := handles.frame().view
	cam_fwd := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
	cam_depth := linalg.dot(origin - v.cam_pos, cam_fwd)
	if cam_depth <= SCENE_CAM_NEAR && !_gizmo_dragging {
		gizmo_end_drag_if_any()
		return
	}
	dist: f32
	if abs(v.proj[3, 3]) > 0.5 && abs(v.proj[1, 1]) > 1e-6 {
		half_h := 1.0 / abs(v.proj[1, 1])
		dist = half_h / math.tan(math.to_radians(SCENE_CAM_FOV_DEG) * 0.5)
	} else {
		if cam_depth <= SCENE_CAM_NEAR {
			gizmo_end_drag_if_any()
			return
		}
		dist = linalg.length(origin - v.cam_pos)
	}
	size := dist * _GIZMO_SIZE_FACTOR
	if size <= 0 do return

	d: handles.Drag
	switch gizmo_mode {
	case .Picker, .Handles:
		gizmo_end_drag_if_any()
		return
	case .Translate:
		rot := _gizmo_rotation(tH) if gizmo_space == .Local else quaternion128(1)
		pos := origin
		d = handles.position_handle(_TOOL_ID, &pos, rot, size, handles.PRIO_TOOL)
		if d.started do _gizmo_begin(origin)
		if _gizmo_dragging && (d.dragging || d.released) {
			delta := pos - _gizmo_start_world
			for &tgt in _gizmo_targets {
				engine.transform_set_world_position(tgt.tH, tgt.start_pos + delta)
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	case .Rotate:
		local := gizmo_space == .Local
		if !_gizmo_dragging do _gizmo_rot = _gizmo_rotation(tH) if local else quaternion128(1)
		d = handles.rotation_handle(_TOOL_ID, &_gizmo_rot, origin, size, local, handles.PRIO_TOOL)
		if d.started {
			_gizmo_begin(origin)
			_gizmo_rot_start = _gizmo_rot
		}
		if _gizmo_dragging && (d.dragging || d.released) {
			turn := _gizmo_rot * conj(_gizmo_rot_start)
			for &tgt in _gizmo_targets {
				world := turn * engine.quat_to_native(tgt.start_rot)
				engine.transform_set_world_rotation(tgt.tH, engine.quat_from_native(world))
				// Orbit the position around the pivot (no-op for the object
				// AT the pivot: single-object Pivot mode keeps its place).
				off := tgt.start_pos - _gizmo_start_world
				if linalg.length(off) > 1e-6 {
					engine.transform_set_world_position(tgt.tH, _gizmo_start_world + linalg.quaternion128_mul_vector3(turn, off))
				}
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	case .Scale:
		if !_gizmo_dragging do _gizmo_factor = {1, 1, 1}
		rot := _gizmo_rotation(tH)
		d = handles.scale_handle(_TOOL_ID, &_gizmo_factor, origin, rot, size, handles.PRIO_TOOL)
		if d.started do _gizmo_begin(origin)
		if _gizmo_dragging && (d.dragging || d.released) {
			w := engine.ctx_world()
			f := _gizmo_factor
			for &tgt in _gizmo_targets {
				t := engine.pool_get(&w.transforms, engine.Handle(tgt.tH))
				if t == nil do continue
				t.scale = tgt.start_scale * f
				// Each object's offset from the pivot scales along the
				// handle's axes by the same factors.
				off := tgt.start_pos - _gizmo_start_world
				if linalg.length(off) > 1e-6 {
					moved := _gizmo_start_world
					for i in 0 ..< 3 {
						e: [3]f32
						e[i] = 1
						axis := linalg.quaternion128_mul_vector3(rot, e)
						moved += axis * linalg.dot(off, axis) * f[i]
					}
					engine.transform_set_world_position(tgt.tH, moved)
				}
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
	// A released drag is one step, and so is a drag whose handle went away
	// (another mode's handle holds no drag).
	if d.released || (_gizmo_dragging && !d.dragging) do gizmo_end_drag_if_any()
}

@(private = "file")
_gizmo_rotation :: proc(tH: engine.Transform_Handle) -> quaternion128 {
	return engine.quat_to_native(engine.transform_world_rotation(tH))
}

@(private = "file")
_gizmo_begin :: proc(origin: [3]f32) {
	gizmo_end_drag_if_any()
	if !_gizmo_collect_targets() do return
	_gizmo_dragging = true
	_gizmo_start_world = origin
}

@(private)
_gizmo_collect_targets :: proc() -> bool {
	// Cross-frame state: never borrows the caller's allocator.
	if _gizmo_targets == nil do _gizmo_targets = make([dynamic]_Gizmo_Target, runtime.default_allocator())
	clear(&_gizmo_targets)
	w := engine.ctx_world()

	// One target list for the session, built alongside the gizmo's own. Rotate
	// and scale each touch TWO fields per object (the field itself plus position,
	// which moves as things orbit or scale about the pivot), so those objects
	// contribute two entries.
	edits := make([dynamic]undo.Edit_Target, 0, len(_gizmo_targets) * 2, context.temp_allocator)

	for h in sel_scene_top_level() {
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		append(&_gizmo_targets, _Gizmo_Target{
			tH          = h,
			start_pos   = engine.transform_world_position(h),
			start_rot   = engine.transform_world_rotation(h),
			start_scale = t.scale,
		})
		switch gizmo_mode {
		case .Picker, .Handles:
		case .Translate:
			append(&edits, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
			// A UI node moves through its RectTransform (transform_set_world_position
			// converts), so that is the field the drag must record.
			if owned, rt := engine.transform_get_comp(h, engine.RectTransform); rt != nil {
				append(&edits, undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)))
			}
		case .Rotate:
			append(&edits, undo.edit_target_transform(h, &t.rotation, typeid_of([4]f32)))
			append(&edits, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
			if owned, rt := engine.transform_get_comp(h, engine.RectTransform); rt != nil {
				append(&edits, undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)))
			}
		case .Scale:
			append(&edits, undo.edit_target_transform(h, &t.scale, typeid_of([3]f32)))
			append(&edits, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
			if owned, rt := engine.transform_get_comp(h, engine.RectTransform); rt != nil {
				append(&edits, undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)))
			}
		}
	}

	if len(_gizmo_targets) == 0 do return false
	if len(edits) > 0 {
		_gizmo_edit = undo.edit_session_begin(edits[:], _gizmo_label())
	}
	return true
}

@(private)
_gizmo_label :: proc() -> string {
	switch gizmo_mode {
	case .Picker, .Handles: return "Gizmo"
	case .Translate: return "Gizmo Move"
	case .Rotate:    return "Gizmo Rotate"
	case .Scale:     return "Gizmo Scale"
	}
	return "Gizmo"
}

@(private)
_gizmo_end_drag :: proc() {
	// The session is the group: it records one action for every target that
	// moved, and nothing at all when the drag ended where it started.
	undo.edit_session_end(&_gizmo_edit)
	clear(&_gizmo_targets)
}

// Finalize an in-flight drag (mode switch, selection loss) — commits what
// happened so far as the drag's undo group.
gizmo_end_drag_if_any :: proc() {
	if _gizmo_dragging {
		_gizmo_dragging = false
		_gizmo_end_drag()
		// The drag's handle is the tool's own (one drag at a time): it holds the
		// pointer no longer.
		handles.end_drag()
	}
}

gizmo_shutdown :: proc() {
	delete(_gizmo_targets)
	_gizmo_targets = nil
}
