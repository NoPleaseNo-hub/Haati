package mhgui_editor

// Editor half of mhgui: the GameObject > UI menu, scene-view picking of UI
// rects, and the rect tool drawn on the selected RectTransform (built on
// editor/handles, docs/Handles.md). Each menu action and each drag is one
// undo step.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import im "haati:external/odin-imgui"
import "haati:engine"
import "haati:editor/handles"
import "haati:engine/gizmos"
import "haati:editor/inspector"
import "haati:editor/undo"
import mhgui "haati:packages/mhgui"

@(private = "file") _NONE :: engine.Transform_Handle{}

// The canvas plane in the scene view.
@(private = "file") _PLANE_NORMAL :: [3]f32{0, 0, 1}

// Rect tool colors: the rect and its handles, the anchors, the pivot ring.
@(private = "file") _COLOR_RECT :: [4]f32{1, 1, 1, 0.9}
@(private = "file") _COLOR_RECT_DRIVEN :: [4]f32{1, 1, 1, 0.45}
@(private = "file") _COLOR_GUIDE :: [4]f32{1, 1, 1, 0.6}
@(private = "file") _COLOR_CORNER :: [4]f32{1, 1, 1, 0.9}
@(private = "file") _COLOR_ANCHOR :: [4]f32{1, 1, 1, 0.9}
@(private = "file") _COLOR_PIVOT :: [4]f32{0.3, 0.6, 1, 1}
@(private = "file") _COLOR_CANVAS :: [4]f32{1, 1, 1, 0.5}

// --- Menu ---------------------------------------------------------------------------

// Adds `key` to `tH` as a recorded step; no-op when the node has one already.
// `init` fills the new component before the step is recorded, so redo
// rebuilds it with those values, not the reset defaults.
@(private = "file")
_add_comp :: proc(tH: engine.Transform_Handle, key: engine.TypeKey, init: proc(ptr: rawptr) = nil) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	if _, idx := engine.transform_find_comp(t, key); idx >= 0 do return
	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return
	if init != nil do init(ptr)
	undo.record_add_component(tH, owned.handle, len(t.components) - 1)
}

// The canvas node `tH` sits in (itself included), or _NONE.
@(private = "file")
_canvas_of :: proc(start: engine.Transform_Handle) -> engine.Transform_Handle {
	w := engine.ctx_world()
	tH := start
	for tH != _NONE {
		if _, c := engine.transform_get_comp(tH, engine.Canvas); c != nil do return tH
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return _NONE
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return _NONE
}

// A new Canvas node at the scene root.
@(private = "file")
_create_canvas :: proc() -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	if scene == nil do return _NONE
	tH := undo.record_create_child("Canvas", engine.Transform_Handle(scene.root.handle))
	if tH != _NONE {
		_add_comp(tH, .Canvas)
		_add_comp(tH, .GraphicRaycaster)
	}
	return tH
}

@(menu_item={path="GameObject/UI/Canvas", order=50})
ui_menu_canvas :: proc() {
	g := undo.group_begin("Create Canvas")
	defer undo.group_end(&g)
	tH := _create_canvas()
	if tH == _NONE do return
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

@(menu_item={path="GameObject/UI/Canvas (3D Tracked)", order=53})
ui_menu_canvas_tracked :: proc() {
	g := undo.group_begin("Create 3D Tracked Canvas")
	defer undo.group_end(&g)
	tH := _create_canvas()
	if tH == _NONE do return
	if _, c := engine.transform_get_comp(tH, engine.Canvas); c != nil {
		c.render_mode = .ScreenSpace3DTracked
	}
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

@(menu_item={path="GameObject/UI/Canvas (World Space)", order=54})
ui_menu_canvas_world :: proc() {
	g := undo.group_begin("Create World Space Canvas")
	defer undo.group_end(&g)
	tH := _create_canvas()
	if tH == _NONE do return
	if _, c := engine.transform_get_comp(tH, engine.Canvas); c != nil {
		c.render_mode = .WorldSpace
	}
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

// An Image node (RectTransform + CanvasRenderer + Image): under the selection
// when that sits in a canvas, else under a new canvas.
@(menu_item={path="GameObject/UI/Image", order=51})
ui_menu_image :: proc() {
	g := undo.group_begin("Create Image")
	defer undo.group_end(&g)
	parent := engine.inspector_active_selection()
	if _canvas_of(parent) == _NONE {
		parent = _create_canvas()
		if parent == _NONE do return
	}
	tH := undo.record_create_child("Image", parent)
	if tH == _NONE do return
	_add_comp(tH, .RectTransform)
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .Image)
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
mhgui_editor_install :: proc() {
	inspector.add_component_wrapper(typeid_of(mhgui.Image), _image_inspector)
	inspector.add_component_wrapper(typeid_of(engine.Canvas), _canvas_inspector)
	inspector.add_component_wrapper(typeid_of(engine.Camera), _camera_inspector)
}

@(private = "file")
_camera_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	cam := cast(^engine.Camera)ctx.ptr
	if cam == nil do return

	im.Spacing()
	preview := engine.render_layer_name(cam.render_layer_mask)
	if cam.render_layer_mask == (engine.RENDER_LAYER_ALL & ~engine.RENDER_LAYER_UI) {
		preview = "Everything Except UI"
	}
	im.SetNextItemWidth(-1)
	if im.BeginCombo("Culling Layers", strings.clone_to_cstring(preview, context.temp_allocator)) {
		if im.MenuItem("Everything (All Layers)", nil, cam.render_layer_mask == engine.RENDER_LAYER_ALL) {
			cam.render_layer_mask = engine.RENDER_LAYER_ALL
			inspector.mark_inspector_changed()
		}
		if im.MenuItem("Everything Except UI (World Camera)", nil, cam.render_layer_mask == (engine.RENDER_LAYER_ALL & ~engine.RENDER_LAYER_UI)) {
			cam.render_layer_mask = engine.RENDER_LAYER_ALL & ~engine.RENDER_LAYER_UI
			inspector.mark_inspector_changed()
		}
		if im.MenuItem("UI Layer Only (UI Camera)", nil, cam.render_layer_mask == engine.RENDER_LAYER_UI) {
			cam.render_layer_mask = engine.RENDER_LAYER_UI
			inspector.mark_inspector_changed()
		}
		im.Separator()
		for def in engine.RENDER_LAYER_DEFS {
			has_bit := (cam.render_layer_mask & def.mask) != 0
			if im.Checkbox(strings.clone_to_cstring(def.name, context.temp_allocator), &has_bit) {
				if has_bit {
					cam.render_layer_mask |= def.mask
				} else {
					cam.render_layer_mask &= ~def.mask
				}
				inspector.mark_inspector_changed()
			}
		}
		im.EndCombo()
	}
}

@(private = "file")
_setup_ui_layer_and_two_cameras :: proc(canvas_tH: engine.Transform_Handle, c: ^engine.Canvas) {
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return

	// 1. Place Canvas and all its UI children onto the UI Render Layer
	engine.transform_set_render_layer_recursive(canvas_tH, engine.RENDER_LAYER_UI)

	// 2. Find existing World Camera and UI Camera
	world_cam_h: engine.Transform_Handle
	ui_cam_h:    engine.Transform_Handle
	cam_it := engine.pool_iterator(engine.cameras(w))
	for cam, _ in engine.pool_next(&cam_it) {
		if !engine.transform_active_in_hierarchy(cam.owner) do continue
		if cam.render_layer_mask == engine.RENDER_LAYER_UI {
			ui_cam_h = cam.owner
		} else {
			if world_cam_h == {} do world_cam_h = cam.owner
			// Exclude UI layer from world camera so World Camera renders everything else
			cam.render_layer_mask &= ~engine.RENDER_LAYER_UI
		}
	}

	// 3. Create UI Camera if none exists yet
	root_h := engine.Transform_Handle(scene.root.handle)
	if ui_cam_h == {} {
		ui_cam_h = engine.transform_new("UI_Camera", root_h)
		engine.transform_ensure_unique_name(ui_cam_h)
		if ut := engine.pool_get(&w.transforms, engine.Handle(ui_cam_h)); ut != nil {
			ut.position = {0, 0, -10}
			ut.render_layer = engine.RENDER_LAYER_UI
		}
		if _, cam_ptr := engine.transform_add_comp(ui_cam_h, .Camera); cam_ptr != nil {
			uc := cast(^engine.Camera)cam_ptr
			engine.reset_Camera(uc)
			uc.order = 10
			uc.render_layer_mask = engine.RENDER_LAYER_UI
		}
	}

	// 4. If Canvas is in ScreenSpaceCamera mode, bind it to UI_Camera automatically
	if c.render_mode == .ScreenSpaceCamera && ui_cam_h != {} {
		c.render_camera = engine.Ref_Local{handle = engine.Handle(ui_cam_h)}
	}
	scene.dirty = true
	inspector.mark_inspector_changed()
}

// Canvas inspector: draws the standard fields (render_mode: ViewportHUD /
// ScreenSpaceCamera / ScreenSpace3DTracked / WorldSpace, sorting_order, tracked_target,
// scene_2d_asset) and provides one-click buttons for UI Render Layer + 2-Camera setup
// and Scene2D asset instantiation.
@(private = "file")
_canvas_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	c := cast(^engine.Canvas)ctx.ptr
	if c == nil do return
	#partial switch c.render_mode {
	case .ScreenSpaceOverlay:
		im.TextDisabled("Mode: Overlay (Draws in Scene 2D & Game View; hidden in 3D Scene3D viewport)")
	case .ScreenSpaceCamera:
		im.TextDisabled("Mode: Camera (Placed on camera plane; assign Render Camera below)")
	case .ScreenSpace3DTracked:
		im.TextDisabled("Mode: ScreenSpace3DTracked (2D screen overlay anchored to 3D world transform)")
	case .WorldSpace:
		im.TextDisabled("Mode: WorldSpace (3D planar surface inside Scene3D hierarchy)")
	}

	w := engine.ctx_world()
	if t := engine.pool_get(&w.transforms, engine.Handle(c.owner)); t != nil {
		im.Spacing()
		is_ui_layer := t.render_layer == engine.RENDER_LAYER_UI
		if !is_ui_layer {
			if im.Button("Move Canvas Hierarchy to 'UI' Layer", {-1, 0}) {
				engine.transform_set_render_layer_recursive(c.owner, engine.RENDER_LAYER_UI)
				inspector.mark_inspector_changed()
			}
		} else {
			im.TextColored({0.45, 0.92, 0.55, 1.0}, "Layer: UI (1 << 5)")
		}
		if im.Button("Setup UI Layer + 2 Cameras (World + UI)", {-1, 0}) {
			_setup_ui_layer_and_two_cameras(c.owner, c)
		}
	}

	has_scene2d := c.scene_2d_asset != (engine.Asset_GUID{})
	im.BeginDisabled(!has_scene2d)
	if im.Button("Import Scene2D Instance") {
		imported, ok_imp := engine.canvas_import_scene_2d(c.owner)
		if ok_imp && imported != _NONE {
			inspector.mark_inspector_changed()
			engine.inspector_request_select(imported)
		}
	}
	im.EndDisabled()
}

// A Button node: an Image as the target graphic plus the Button. Like the
// Image menu, under the selection when that sits in a canvas.
@(menu_item={path="GameObject/UI/Button", order=52})
ui_menu_button :: proc() {
	g := undo.group_begin("Create Button")
	defer undo.group_end(&g)
	parent := engine.inspector_active_selection()
	if _canvas_of(parent) == _NONE {
		parent = _create_canvas()
		if parent == _NONE do return
	}
	tH := undo.record_create_child("Button", parent)
	if tH == _NONE do return
	_add_comp(tH, .RectTransform, proc(ptr: rawptr) {
		(cast(^engine.RectTransform)ptr).size_delta = {160, 30}
	})
	_add_comp(tH, .CanvasRenderer)
	_add_comp(tH, .Image)
	_add_comp(tH, .Button)
	undo.group_commit(&g)
	engine.inspector_request_select(tH)
}

// --- Image inspector -------------------------------------------------------------------

// Default fields, then the Sprite row (the shared sprite picker; the field
// itself is inspect:"-") and Set Native Size, which sizes the node's
// RectTransform to the sprite's pixels as one undo step.
@(private = "file")
_image_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	img := cast(^mhgui.Image)ctx.ptr
	if inspector.sprite_ref_row("Sprite", &img.sprite) {
		inspector.mark_inspector_changed()
		inspector.record_nested_override(&img.sprite, typeid_of(engine.PPtr), "sprite", true)
	}
	owned, rt := engine.transform_get_comp(img.owner, engine.RectTransform)
	if rt == nil do return
	_, px, _, _, ok := mhgui.image_source(img)
	im.BeginDisabled(!ok)
	if im.Button("Set Native Size") {
		targets := [?]undo.Edit_Target{undo.edit_target_pooled(owned.handle, &rt.size_delta, typeid_of([2]f32))}
		sess := undo.edit_session_begin(targets[:], "Set Native Size")
		rt.size_delta = {px.z, px.w}
		undo.edit_session_end(&sess)
		inspector.mark_inspector_changed()
	}
	im.EndDisabled()
}

// --- Canvas outline --------------------------------------------------------------------

// Only 3D in-world canvases (WorldSpace / ScreenSpaceCamera) draw a 3D wireframe
// outline in Scene3D; 2D Overlay canvases draw their frame inside Scene 2D instead.
@(on_draw_gizmos={component=Canvas})
canvas_gizmos :: proc(c: ^engine.Canvas, ctx: handles.Gizmo_Context) {
	if !engine.transform_active_in_hierarchy(c.owner) do return
	root, xform, in_world := engine.canvas_placement(c.owner, engine.canvas_game_viewport())
	if !in_world do return
	gizmos.with_depth_test(false)
	gizmos.with_color(_COLOR_CANVAS)
	gizmos.wire_quad(engine.rect_corners(root, xform))
}

// --- Rect tool -----------------------------------------------------------------------

// The drag in flight: the RectTransform as it was at grab, restored and
// re-edited from the total drag offset every frame so a drag is a pure
// function of where the pointer is now, and the undo session around it.
@(private = "file") _drag_start: engine.RectTransform
@(private = "file") _drag_edit: undo.Edit_Session

// Handle ids: the node's pool index scoped by a handle slot, never 0.
@(private = "file")
_handle_id :: proc(tH: engine.Transform_Handle, slot: u64) -> u64 {
	return (u64(tH.index) + 1) << 4 | slot
}

// One rect-tool handle: which edges it moves (-1 low, +1 high, 0 none per
// axis) and where it sits on the rect (0..1 per axis).
@(private = "file")
_Rect_Handle :: struct {
	sides: [2]i8,
	at:    [2]f32,
}

@(private = "file")
_RECT_HANDLES := [8]_Rect_Handle{
	{{-1, -1}, {0, 0}}, {{1, -1}, {1, 0}}, {{1, 1}, {1, 1}}, {{-1, 1}, {0, 1}}, // corners
	{{-1, 0}, {0, 0.5}}, {{1, 0}, {1, 0.5}}, {{0, -1}, {0.5, 0}}, {{0, 1}, {0.5, 1}}, // edges
}

@(private = "file")
_rect_point :: proc(r: engine.Rect, m: matrix[4, 4]f32, at: [2]f32) -> [3]f32 {
	return engine.rect_apply(m, {r.pos.x + r.size.x * at.x, r.pos.y + r.size.y * at.y})
}

// Pointer priorities among the rect tool's handles (the body is 0).
@(private = "file") _PRIO_EDGE :: 1
@(private = "file") _PRIO_CORNER :: 2 // corners and anchors
@(private = "file") _PRIO_PIVOT :: 3

// The two corners an edge runs between, from the rect's bl, br, tr, tl.
@(private = "file")
_edge_ends :: proc(c: [4][3]f32, sides: [2]i8) -> (a, b: [3]f32) {
	switch {
	case sides.x < 0: return c[0], c[3] // left
	case sides.x > 0: return c[1], c[2] // right
	case sides.y < 0: return c[0], c[1] // bottom
	case:             return c[3], c[2] // top
	}
}

// The resize arrow for a corner or edge handle: diagonal for corners (the
// bottom-left/top-right pair leans one way, the other pair the other),
// vertical for the top and bottom edges, horizontal for the sides.
@(private = "file")
_resize_cursor :: proc(sides: [2]i8) -> im.MouseCursor {
	switch {
	case sides.x != 0 && sides.y != 0: return .ResizeNESW if sides.x == sides.y else .ResizeNWSE
	case sides.x != 0:                 return .ResizeEW
	case:                              return .ResizeNS
	}
}

// Apply a handle's drag: start from the grab-time values, then move or
// resize by the total offset. The world offset is a canvas offset (one unit
// per canvas unit), brought into the parent's space so a child of a rotated
// or scaled parent drags along its own axes.
@(private = "file")
_apply_drag :: proc(rt: ^engine.RectTransform, h: ^_Rect_Handle, d: handles.Drag, parent_xform: matrix[4, 4]f32) {
	rt.anchored_position = _drag_start.anchored_position
	rt.size_delta = _drag_start.size_delta
	delta := engine.rect_apply_dir(linalg.inverse(parent_xform), d.delta.xy)
	if h == nil {
		mhgui.rect_drag_move(rt, delta)
	} else {
		mhgui.rect_drag_edges(rt, h.sides, delta)
	}
}

@(private = "file")
_drag_begin :: proc(tH: engine.Transform_Handle, rt: ^engine.RectTransform, label := "Rect Tool") {
	_drag_start = rt^
	owned, _ := engine.transform_get_comp(tH, engine.RectTransform)
	targets := [?]undo.Edit_Target{
		undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)),
		undo.edit_target_pooled(owned.handle, &rt.size_delta, typeid_of([2]f32)),
		undo.edit_target_pooled(owned.handle, &rt.anchor_min, typeid_of([2]f32)),
		undo.edit_target_pooled(owned.handle, &rt.anchor_max, typeid_of([2]f32)),
		undo.edit_target_pooled(owned.handle, &rt.pivot, typeid_of([2]f32)),
	}
	_drag_edit = undo.edit_session_begin(targets[:], label)
}

// A point on the drag plane as a fraction of a rect (its own space), clamped.
@(private = "file")
_rect_fraction :: proc(r: engine.Rect, m: matrix[4, 4]f32, world: [3]f32) -> [2]f32 {
	local := linalg.inverse(m) * [4]f32{world.x, world.y, world.z, 1}
	f := (local.xy - r.pos) / r.size
	return {clamp(f.x, 0, 1), clamp(f.y, 0, 1)}
}

// Snaps a fraction to the corners, edges and center (Ctrl held), Unity's
// pivot snapping.
@(private = "file")
_snap_fraction :: proc(f: [2]f32) -> [2]f32 {
	snap :: proc(v: f32) -> f32 { return math.round(v * 2) * 0.5 }
	return {snap(f.x), snap(f.y)}
}

// An anchor drag: anchor k (bl, br, tr, tl) alone follows the mouse on the
// parent rect, pushing its counterpart along rather than crossing it. Shift
// also moves the pivot with it, Alt also moves the rect onto the anchors;
// otherwise the rect keeps its place unless raw edit mode is on.
@(private = "file")
_apply_anchor_drag :: proc(rt: ^engine.RectTransform, k: int, d: handles.Drag, parent: engine.Rect, parent_xform: matrix[4, 4]f32) {
	rt^ = _drag_start
	// The anchor moves BY the drag, not TO the mouse: the press point can be
	// anywhere on the triangle, and the anchor must not jump under it.
	df := engine.rect_apply_dir(linalg.inverse(parent_xform), d.delta.xy) / parent.size
	start := [2]f32{
		_drag_start.anchor_min.x if k == 0 || k == 3 else _drag_start.anchor_max.x,
		_drag_start.anchor_min.y if k == 0 || k == 1 else _drag_start.anchor_max.y,
	}
	f := [2]f32{clamp(start.x + df.x, 0, 1), clamp(start.y + df.y, 0, 1)}
	io := im.GetIO()
	rect := engine.rect_resolve(parent, rt)
	amin, amax := rt.anchor_min, rt.anchor_max
	// Per axis: which side of the pair this anchor is.
	set_min :: proc(amin, amax: ^f32, v: f32) { amin^ = v; amax^ = max(amax^, v) }
	set_max :: proc(amin, amax: ^f32, v: f32) { amax^ = v; amin^ = min(amin^, v) }
	if k == 0 || k == 3 {
		set_min(&amin.x, &amax.x, f.x)
	} else {
		set_max(&amin.x, &amax.x, f.x)
	}
	if k == 0 || k == 1 {
		set_min(&amin.y, &amax.y, f.y)
	} else {
		set_max(&amin.y, &amax.y, f.y)
	}
	rt.anchor_min = amin
	rt.anchor_max = amax
	if io.KeyShift do rt.pivot = {0.5 if amin.x != amax.x else amin.x, 0.5 if amin.y != amax.y else amin.y}
	if io.KeyAlt {
		rt.anchored_position.xy = 0
		if amin.x != amax.x do rt.size_delta.x = 0
		if amin.y != amax.y do rt.size_delta.y = 0
	} else if !handles.rect_raw_edit {
		engine.rect_transform_keep_rect(rt, parent, rect)
	}
}

// While an anchor drags: dashed lines through the anchors across the parent
// rect, with the percentage of the parent each of the three sections takes
// (before, between and after the anchors) written on the lowest horizontal
// line and the leftmost vertical line.
@(private = "file")
_draw_anchor_guides :: proc(rt: ^engine.RectTransform, parent: engine.Rect, m: matrix[4, 4]f32) {
	at :: proc(m: matrix[4, 4]f32, parent: engine.Rect, f: [2]f32) -> [3]f32 {
		return engine.rect_apply(m, parent.pos + parent.size * f)
	}
	lo, hi := rt.anchor_min, rt.anchor_max
	{
		gizmos.with_depth_test(false)
		gizmos.with_color(_COLOR_GUIDE)
		dashed :: proc(a, b: [3]f32) {
			gizmos.line_dashed(a, b, gizmos.helper_pixel((a + b) * 0.5, 6)) // 6 px dashes
		}
		for x in ([2]f32{lo.x, hi.x}) do dashed(at(m, parent, {x, 0}), at(m, parent, {x, 1}))
		for y in ([2]f32{lo.y, hi.y}) do dashed(at(m, parent, {0, y}), at(m, parent, {1, y}))
	}

	// Labels hang below the horizontal line, centered on their section, and
	// stand turned left of the vertical one, a few pixels off the dashes.
	xs := [4]f32{0, lo.x, hi.x, 1}
	ys := [4]f32{0, lo.y, hi.y, 1}
	for i in 0 ..< 3 {
		if xs[i + 1] - xs[i] > 0.0005 {
			gizmos.label(at(m, parent, {(xs[i] + xs[i + 1]) * 0.5, lo.y}), fmt.tprintf("%.0f%%", (xs[i + 1] - xs[i]) * 100), align = {0.5, 0}, offset_px = {0, 4})
		}
		if ys[i + 1] - ys[i] > 0.0005 {
			gizmos.label(at(m, parent, {lo.x, (ys[i] + ys[i + 1]) * 0.5}), fmt.tprintf("%.0f%%", (ys[i + 1] - ys[i]) * 100), align = {1, 0.5}, rotated = true, offset_px = {-4, 0})
		}
	}
}

// A pivot drag: the pivot follows the mouse inside the rect (Ctrl snaps to
// the corners, edges and center); the rect keeps its place unless raw edit
// mode is on.
@(private = "file")
_apply_pivot_drag :: proc(rt: ^engine.RectTransform, d: handles.Drag, rect: engine.Rect, xform: matrix[4, 4]f32, parent: engine.Rect) {
	rt^ = _drag_start
	f := _rect_fraction(rect, xform, d.point)
	io := im.GetIO()
	if io.KeyCtrl || io.KeySuper do f = _snap_fraction(f)
	before := engine.rect_resolve(parent, rt)
	rt.pivot = f
	if !handles.rect_raw_edit do engine.rect_transform_keep_rect(rt, parent, before)
}

// The selected RectTransform's rect and its parent's, as placed on the canvas.
// `driven`: a LayoutGroup lays it out.
@(private = "file")
_Placed :: struct {
	rect, parent:        engine.Rect,
	xform, parent_xform: matrix[4, 4]f32,
	driven:              bool,
}

@(private = "file")
_placed :: proc(tH: engine.Transform_Handle) -> (p: _Placed, ok: bool) {
	canvas := _canvas_of(tH)
	if canvas == _NONE || canvas == tH do return
	_, _, in_world := engine.canvas_placement(canvas, engine.canvas_game_viewport())
	if !in_world && engine.canvas_suppress_overlay_in_scene_3d() do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	parent_tH := engine.Transform_Handle(t.parent.handle)

	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_placed(canvas, &nodes)
	have_rect, have_parent: bool
	for n in nodes {
		if n.tH == tH { p.rect = n.rect; p.xform = n.xform; have_rect = true; p.driven = n.driven }
		if n.tH == parent_tH { p.parent = n.rect; p.parent_xform = n.xform; have_parent = true }
	}
	return p, have_rect && have_parent
}

// A selected RectTransform's outline (a parent selected counts), in every
// tool. A rect a LayoutGroup lays out gets its own color: moving or resizing it
// would be undone by the layout on the next frame, so the rect tool offers no
// handles for it.
@(on_draw_gizmos={component=RectTransform})
rect_transform_gizmos :: proc(rt: ^engine.RectTransform, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	p, ok := _placed(rt.owner)
	if !ok do return
	corners := engine.rect_corners(p.rect, p.xform)
	if p.driven {
		gizmos.with_depth_test(false)
		gizmos.with_color(_COLOR_RECT_DRIVEN)
		gizmos.wire_quad(corners)
		return
	}
	handles.rect_outlined(corners, _COLOR_RECT)
}

// The rect tool on a selected RectTransform. The parent's anchor markers work
// in every tool. With the Handles tool (T) the rest joins them: corner and edge
// handles that resize, the body that moves, and the pivot ring. The outline
// comes from rect_transform_gizmos.
@(on_scene_handles={component=RectTransform})
rect_transform_handles :: proc(rt: ^engine.RectTransform, ctx: handles.Gizmo_Context) {
	tH := rt.owner
	p, ok := _placed(tH)
	if !ok do return
	if p.driven do return
	rect, parent := p.rect, p.parent
	xform, parent_xform := p.xform, p.parent_xform
	corners := engine.rect_corners(rect, xform)

	// The four anchors on the parent rect (in the parent's space), bl, br,
	// tr, tl, each a handle: dragging one moves that anchor along the parent
	// rect. Coinciding anchors overlap: dragging one pulls it out. Anchors are
	// fractions of the parent rect, so grid snapping stays off for them.
	a_lo := parent.pos + parent.size * rt.anchor_min
	a_hi := parent.pos + parent.size * rt.anchor_max
	anchor_size := handles.world_per_pixels(_rect_point(rect, parent_xform, {0.5, 0.5}), 10)
	anchor_at :: proc(m: matrix[4, 4]f32, p: [2]f32) -> [3]f32 {
		return engine.rect_apply(m, p)
	}
	anchor_pts := [4][2]f32{a_lo, {a_hi.x, a_lo.y}, a_hi, {a_lo.x, a_hi.y}}
	anchor_dirs := [4][3]f32{{1, 1, 0}, {-1, 1, 0}, {-1, -1, 0}, {1, -1, 0}}
	anchor_dragging := false
	for k in 0 ..< 4 {
		handles.with_snap(false)
		p := anchor_at(parent_xform, anchor_pts[k])
		// The hit area is the triangle's own screen box, so coinciding
		// anchors are told apart by which triangle is under the mouse.
		tri, _ := handles.triangle_points(p, anchor_dirs[k], anchor_size)
		d := handles.area(_handle_id(tH, 20 + u64(k)), p, _PLANE_NORMAL, tri[:], prio = _PRIO_CORNER)
		handles.triangle_outline(p, anchor_dirs[k], anchor_size, handles.COLOR_HOT if d.hot else _COLOR_ANCHOR)
		if d.started do _drag_begin(tH, rt, "Anchors")
		if d.dragging {
			_apply_anchor_drag(rt, k, d, parent, parent_xform)
			anchor_dragging = true
		}
		if d.released do undo.edit_session_end(&_drag_edit)
	}
	if anchor_dragging do _draw_anchor_guides(rt, parent, parent_xform)
	if ctx.tool != .Handles do return

	// The rect with its own rotation and scale applied. Its corners and whole
	// edges resize; the cursor says what a spot does (a resize arrow on
	// corners and edges, the move cursor over the body). Pointer priority:
	// pivot over corners and anchors over edges over the body.
	body := handles.quad(_handle_id(tH, 9), corners, _PLANE_NORMAL)
	if body.started do _drag_begin(tH, rt)
	if body.dragging do _apply_drag(rt, nil, body, parent_xform)
	if body.released do undo.edit_session_end(&_drag_edit)
	if body.hot do im.SetMouseCursor(.ResizeAll)

	for &h, i in _RECT_HANDLES {
		corner := h.sides.x != 0 && h.sides.y != 0
		d: handles.Drag
		if corner {
			p := _rect_point(rect, xform, h.at)
			d = handles.point(_handle_id(tH, u64(i) + 1), p, _PLANE_NORMAL, prio = _PRIO_CORNER)
			handles.dot_outlined(p, _PLANE_NORMAL, handles.world_per_pixels(p, 3), handles.COLOR_HOT if d.hot else _COLOR_CORNER)
		} else {
			a, b := _edge_ends(corners, h.sides)
			d = handles.segment(_handle_id(tH, u64(i) + 1), a, b, _PLANE_NORMAL, prio = _PRIO_EDGE)
		}
		if d.started do _drag_begin(tH, rt)
		if d.dragging do _apply_drag(rt, &h, d, parent_xform)
		if d.released do undo.edit_session_end(&_drag_edit)
		if d.hot do im.SetMouseCursor(_resize_cursor(h.sides))
	}

	// Pivot ring, drawn last so it reads over the handles, and a handle too.
	// It wins over a resize spot it sits on (a pivot on an edge or corner).
	// The pivot is a fraction of the rect with its own Ctrl snap to 0, 0.5
	// and 1 (_apply_pivot_drag), so grid snapping stays off for it.
	handles.with_snap(false)
	pivot := _rect_point(rect, xform, rt.pivot)
	pd := handles.point(_handle_id(tH, 10), pivot, _PLANE_NORMAL, prio = _PRIO_PIVOT)
	handles.circle_outlined(pivot, _PLANE_NORMAL, handles.world_per_pixels(pivot, 5), handles.COLOR_HOT if pd.hot else _COLOR_PIVOT)
	if pd.started do _drag_begin(tH, rt, "Pivot")
	if pd.dragging do _apply_pivot_drag(rt, pd, rect, xform, parent)
	if pd.released do undo.edit_session_end(&_drag_edit)
}
