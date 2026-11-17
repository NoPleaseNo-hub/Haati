package editor

import "base:runtime"
import gfx "../engine/gfx"
import input "../engine/input"
import im "haati:external/odin-imgui"
import "menu"
import "core:math"
import "core:math/linalg"
import "../engine"
import "inspector"
import "haati:engine/gizmos"
import "core:strings"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import "core:fmt"
import "core:encoding/uuid"
import "haati:editor/undo"
import wnd "haati:editor/window"
import editor_visuals "haati:editor/editor_visuals"
import "haati:editor/handles"
import cad_csg_editor "haati:packages/cad_csg/editor"

scene_rt: ^gfx.Render_Target

// Editor camera: first-person data (position + yaw/pitch about the EYE), NOT
// a Camera component — the scene view renders through the same engine
// collect/execute path as game cameras. scene_cam_target is derived: the
// look-at anchor scene_cam_dist along the forward ray. Orbit/zoom/frame pull
// toward it; fly and pan carry it along (Unity's pivot model).
scene_cam_pos: [3]f32
scene_cam_yaw: f32   // radians, atan2(fwd.z, fwd.x)
scene_cam_pitch: f32 // radians, asin(fwd.y), clamped just short of the poles
scene_cam_dist: f32
scene_cam_target: [3]f32

// Flythrough speed: wheel while flying rescales the base (kept for the whole
// session), holding movement keys ramps the current speed toward base*mult.
scene_fly_speed: f32
_fly_speed_cur: f32

// Flythrough smoothing: mouse look drives TARGET angles and the camera
// exponentially chases them; movement velocity chases the keyed direction the
// same way. Both use 1-exp(-dt/tau), so the lag feel is frame-rate independent.
_fly_yaw_target: f32
_fly_pitch_target: f32
_fly_vel: [3]f32

_orbit_active: bool
_orbit_pivot: [3]f32

scene_view_hovered: bool
scene_flythrough_active: bool

// Projection and the 2D Planar view. Orthographic is an optional toggle inside
// Camera Settings (for 2D scene capture / compass setup). By default, both 3D
// and 2D Planar views use real 3D Perspective projection so moving forward and
// backward along the depth axis has authentic 3D depth perception.
// 2D Planar mode locks camera rotation to a cardinal axis (Front, Back, Left,
// Right, Top, Bottom) with no orbit: right and middle drag both pan on the
// workplane, plain Mouse Wheel moves physically forward/backward through depth,
// and Ctrl + Mouse Wheel zooms magnification. Leaving 2D restores the 3D view.
scene_cam_ortho: bool
scene_2d_mode: bool
_pre_2d_yaw: f32
_pre_2d_pitch: f32
_pre_2d_ortho: bool
_pre_2d_pos: [3]f32
_pre_2d_dist: f32
_pre_2d_has_saved_3d: bool
_scene_2d_pending: bool // settings asked for 2D before the camera existed

Scene_2D_Angle :: enum {
	Front,  // -Z (XY plane)
	Back,   // +Z (XY plane)
	Right,  // -X (YZ plane)
	Left,   // +X (YZ plane)
	Top,    // -Y (XZ plane, top-down)
	Bottom, // +Y (XZ plane, bottom-up)
}

scene_2d_angle: Scene_2D_Angle = .Front

// 2D Planar / CAD navigation & measurement state:
// - Plain Mouse Wheel moves scene_cam_pos physically forward/backward along the 3D view axis
//   by scene_2d_wheel_step so the camera travels through the origin or mesh in real 3D depth
//   (and scales scene_cam_dist so orthographic projection scales cleanly too).
SCENE_2D_BASE_DIST     :: f32(10.0)
SCENE_2D_INITIAL_DEPTH :: f32(3.5)
scene_2d_wheel_step: f32 = 0.25
_speed_hud_timer: f32
scene_2d_ruler_active: bool
_ruler_dragging: bool
_ruler_has_measurement: bool
_ruler_start_world: [3]f32
_ruler_end_world: [3]f32

Ruler_Mode :: enum {
	Surface_Clearance,  // 3D Surface + Wall/Obstacle Safe Spawn Clearance + Object Height
	Vertical_Height,    // Camera-tilt-independent Axis-Locked (World Y Height / X / Z)
	Along_Mesh_Surface, // Point-to-Point 3D Tape along mesh surfaces
	Angle_Protractor,   // Protractor / Angle & Slope measurement
}

Ruler_Angle_Unit :: enum {
	Degrees,    // Degrees (deg)
	Radians,    // Radians (rad / pi)
	Quaternion, // 3D Orientation Quaternion (qx, qy, qz, qw)
}

Ruler_Axis_Lock :: enum {
	None,    // Free 3D surface / workplane
	World_X, // Lock to World X axis (Red)
	World_Y, // Lock to World Y axis / Vertical Height (Green)
	World_Z, // Lock to World Z axis (Blue)
}

_ruler_mode:       Ruler_Mode       = .Surface_Clearance
_ruler_angle_unit: Ruler_Angle_Unit = .Degrees
_ruler_axis_lock:  Ruler_Axis_Lock  = .None

// Live 3D surface hover & wall-clearance state for the Ruler
_ruler_hover_valid:    bool
_ruler_hover_world:    [3]f32
_ruler_hover_tH:       engine.Transform_Handle
_ruler_hover_aabb_min: [3]f32
_ruler_hover_aabb_max: [3]f32
_ruler_wall_hit_valid: bool
_ruler_wall_hit_pos:   [3]f32
_ruler_wall_dist:      f32
_ruler_wall_tH:        engine.Transform_Handle
_ruler_safe_spawn_rad: f32

Ruler_Measurement :: struct {
	start_world: [3]f32,
	end_world:   [3]f32,
	axis_r:      [3]f32,
	axis_u:      [3]f32,
	label_h:     cstring,
	label_v:     cstring,
	wall_valid:  bool,
	wall_pos:    [3]f32,
	wall_dist:   f32,
	safe_rad:    f32,
}

_ruler_pinned: [dynamic]Ruler_Measurement

scene_set_2d_angle :: proc(angle: Scene_2D_Angle, preserve_pos := false) {
	scene_2d_angle = angle
	if !scene_2d_mode {
		_pre_2d_yaw, _pre_2d_pitch, _pre_2d_ortho = scene_cam_yaw, scene_cam_pitch, scene_cam_ortho
		_pre_2d_pos, _pre_2d_dist = scene_cam_pos, scene_cam_dist
		_pre_2d_has_saved_3d = true
	}
	scene_2d_mode = true
	switch angle {
	case .Front:
		scene_cam_yaw = -math.PI / 2
		scene_cam_pitch = 0
	case .Back:
		scene_cam_yaw = math.PI / 2
		scene_cam_pitch = 0
	case .Right:
		scene_cam_yaw = math.PI
		scene_cam_pitch = 0
	case .Left:
		scene_cam_yaw = 0
		scene_cam_pitch = 0
	case .Top:
		scene_cam_yaw = -math.PI / 2
		scene_cam_pitch = -PITCH_LIMIT
	case .Bottom:
		scene_cam_yaw = -math.PI / 2
		scene_cam_pitch = PITCH_LIMIT
	}
	_frame_tween_active = false
	origin_pos := [3]f32{0, 0, 0}
	w := engine.ctx_world()
	if w != nil {
		for h in sel_scene_items() {
			if engine.pool_valid(&w.transforms, engine.Handle(h)) {
				origin_pos = engine.transform_world(h).position
				break
			}
		}
	}
	fwd, r, u := _scene_cam_basis()
	rel := scene_cam_pos - origin_pos
	pan_h := linalg.dot(rel, r)
	pan_v := linalg.dot(rel, u)
	depth := linalg.dot(rel, -fwd)
	if abs(pan_h) > 50.0 || abs(pan_v) > 50.0 {
		pan_h, pan_v = 0, 0
	}
	if !preserve_pos || abs(depth) > 500.0 {
		depth = SCENE_2D_INITIAL_DEPTH
	}
	scene_cam_pos = origin_pos + r * pan_h + u * pan_v - fwd * depth
	if !preserve_pos || scene_cam_dist < CAM_MIN_DIST {
		scene_cam_dist = SCENE_2D_INITIAL_DEPTH
	}
	update_scene_camera()
}

scene_set_2d :: proc(on: bool, preserve_pos := false) {
	if on {
		if !scene_2d_mode {
			_pre_2d_yaw, _pre_2d_pitch, _pre_2d_ortho = scene_cam_yaw, scene_cam_pitch, scene_cam_ortho
			_pre_2d_pos, _pre_2d_dist = scene_cam_pos, scene_cam_dist
			_pre_2d_has_saved_3d = true
		}
		scene_2d_mode = true
		scene_set_2d_angle(scene_2d_angle, preserve_pos = preserve_pos)
	} else {
		if !scene_2d_mode do return
		scene_2d_mode = false
		scene_cam_yaw, scene_cam_pitch = _pre_2d_yaw, _pre_2d_pitch
		_frame_tween_active = false
		if _pre_2d_has_saved_3d {
			scene_cam_ortho = _pre_2d_ortho
			scene_cam_pos = _pre_2d_pos
			scene_cam_dist = max(_pre_2d_dist, CAM_MIN_DIST)
		} else {
			fwd, _, _ := _scene_cam_basis()
			scene_cam_pos = scene_cam_target - fwd * scene_cam_dist
		}
		update_scene_camera()
	}
}

// Click-to-pick state: a click is press+release under a small drag threshold
// (so orbit/pan drags never select). Set in draw_scene_view / handle_scene_input.
_scene_img_min: im.Vec2
// The view the scene image was last rendered with: labels project through it.
_scene_view_last: engine.Render_View
_scene_click_pos: im.Vec2
_scene_click_pending: bool

// Rubber-band box select (Unity): an armed LMB click that travels beyond the
// click threshold becomes a live box select. The selection updates every
// frame while the band is open; the selection-undo tracker pauses
// (scene_band_selecting) so the whole gesture records as ONE "Select" step.
_band_active: bool
_band_anchor: im.Vec2 // screen coords
_band_additive: bool  // cmd/ctrl held at band start: adds to the base set
_band_base: [dynamic]engine.Transform_Handle // selection at band start

scene_band_selecting :: proc() -> bool {
	return _band_active
}

_band_shutdown :: proc() {
	delete(_band_base)
	_band_base = nil
}

CAM_MIN_DIST          :: f32(0.01)
FLYTHROUGH_BASE_SPEED :: f32(8.0)
FLYTHROUGH_MIN_SPEED  :: f32(0.25)
FLYTHROUGH_MAX_SPEED  :: f32(250.0)
FLYTHROUGH_SHIFT_MULT :: f32(3.0)
FLYTHROUGH_RAMP_MULT :: f32(3.0) // held movement accelerates up to base*this
FLYTHROUGH_RAMP_TIME :: f32(2.0) // seconds to reach the ramp cap
FLY_SPEED_WHEEL_BASE :: f32(1.2) // wheel during fly: speed *= base^notches
FLY_LOOK_SMOOTH_TAU :: f32(0.025) // seconds for look to catch its target (~63%)
scene_fly_move_smooth_tau: f32 = 0.08 // seconds for velocity to catch its target; lower = snappier stop (0 = instant)
scene_look_sensitivity: f32 = 0.005   // radians per pixel (fly + orbit)
ZOOM_WHEEL_BASE :: f32(1.2) // wheel dolly: dist *= base^-notches
ZOOM_MIN_STEP :: f32(0.25) // keeps close-range dolly responsive
ZOOM_DRAG_FACTOR :: 0.01

SCENE_CAM_FOV_DEG :: f32(45)
scene_cam_fov_deg: f32 = SCENE_CAM_FOV_DEG
SCENE_CAM_NEAR :: f32(0.001) // Very small non-zero near clip plane so moving close to meshes simulates zooming in cleanly
SCENE_CAM_FAR :: f32(20000)  // far enough to frame a whole 4K canvas (one unit per canvas pixel)

init_scene_view :: proc() {
	scene_rt = gfx.rt_create(1, 1)
	scene_fly_speed = editor_settings.scene_fly_speed >= FLYTHROUGH_MIN_SPEED ? editor_settings.scene_fly_speed : FLYTHROUGH_BASE_SPEED
	_fly_speed_cur = scene_fly_speed
	if editor_settings.scene_cam_has_pos {
		scene_cam_pos = editor_settings.scene_cam_pos
		scene_cam_yaw = editor_settings.scene_cam_yaw
		scene_cam_pitch = editor_settings.scene_cam_pitch
		scene_cam_dist = max(editor_settings.scene_cam_dist, CAM_MIN_DIST)
		update_scene_camera()
	} else {
		scene_cam_look_at({7, 7, 7}, {0, 0, 0})
	}

	// Unity-style dockable overlays (dock.odin): register every
	// @(scene_overlay) item (generated), then restore persisted placement.
	_register_scene_overlays()
	overlay_set_default_anchor("Tools", .Bar_Left)        // Unity's left toolbar strip
	overlay_set_default_anchor("Orientation", .Top_Right) // Unity's scene gizmo corner; settings override
	overlay_set_transparent("Orientation")                // Unity's: no panel, only the grip
	overlays_apply_settings()
}

shutdown_scene_view :: proc() {
	gizmo_shutdown()
	_band_shutdown()
	delete(_pick_menu)
	_pick_menu = nil
	overlays_shutdown()
	gfx.rt_destroy(scene_rt)
	scene_rt = nil
}

// Orthonormal frame from yaw/pitch using exact spherical derivatives:
// right = {-sin(yaw), 0, cos(yaw)}, up = right x fwd.
// This is analytically continuous all the way to the poles (looking straight
// down or straight up), eliminating any cross-product singularity or axis flip
// during MMB screen dragging. In 2D mode, returns the exact axis-aligned
// orthonormal basis for each 2D orthographic angle.
_scene_cam_basis :: proc() -> (fwd, right, up: [3]f32) {
	if scene_2d_mode {
		switch scene_2d_angle {
		case .Front:  return {0, 0, -1}, {1, 0, 0},  {0, 1, 0}
		case .Back:   return {0, 0, 1},  {-1, 0, 0}, {0, 1, 0}
		case .Right:  return {-1, 0, 0}, {0, 0, -1}, {0, 1, 0}
		case .Left:   return {1, 0, 0},  {0, 0, 1},  {0, 1, 0}
		case .Top:    return {0, -1, 0}, {1, 0, 0},  {0, 0, -1}
		case .Bottom: return {0, 1, 0},  {1, 0, 0},  {0, 0, 1}
		}
	}
	cy := math.cos(scene_cam_yaw)
	sy := math.sin(scene_cam_yaw)
	cp := math.cos(scene_cam_pitch)
	sp := math.sin(scene_cam_pitch)
	fwd = {cy * cp, sp, sy * cp}
	right = {-sy, 0, cy}
	up = {-cy * sp, cp, -sy * sp}
	return
}

scene_cam_forward :: proc() -> [3]f32 {
	fwd, _, _ := _scene_cam_basis()
	return fwd
}

scene_cam_right :: proc() -> [3]f32 {
	_, right, _ := _scene_cam_basis()
	return right
}

scene_cam_up :: proc() -> [3]f32 {
	_, _, up := _scene_cam_basis()
	return up
}

// Place the camera and derive yaw/pitch/dist so it looks at target.
scene_cam_look_at :: proc(pos, target: [3]f32) {
	scene_cam_pos = pos
	d := target - pos
	scene_cam_dist = linalg.length(d)
	if scene_cam_dist > 0.0001 {
		dir := d / scene_cam_dist
		scene_cam_pitch = math.asin(clamp(dir.y, -1, 1))
		scene_cam_yaw = math.atan2(dir.z, dir.x)
	}
	update_scene_camera()
}

PITCH_LIMIT :: f32(math.PI / 2 - 0.02)

// Clamp the angles and re-derive the look-at anchor from the eye. A NaN/inf
// guard resets the camera instead of leaving the view unrecoverably black
// (bad mesh bounds or a zero-length basis would poison every later frame).
update_scene_camera :: proc() {
	scene_cam_pitch = clamp(scene_cam_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	scene_cam_dist = clamp(scene_cam_dist, CAM_MIN_DIST, 10000)

	fwd, _, _ := _scene_cam_basis()
	scene_cam_target = scene_cam_pos + fwd * scene_cam_dist

	ok :: proc(v: [3]f32) -> bool {
		for c in v {
			if c != c || abs(c) > 1e20 do return false
		}
		return true
	}
	if !ok(scene_cam_pos) || !ok(scene_cam_target) || scene_cam_yaw != scene_cam_yaw {
		scene_cam_look_at({7, 7, 7}, {0, 0, 0})
	}
}

// Frame the current selection (Unity's F): center the orbit camera on the
// object's bounds and pull back far enough to fit them in the FOV. The move
// tweens with ease-in/out over SCENE_FRAME_TWEEN_SEC (any manual camera input
// cancels it).
SCENE_FRAME_TWEEN_SEC :: f32(0.2)

_frame_tween_active: bool
_frame_tween_t: f32
_frame_tween_from_target, _frame_tween_to_target: [3]f32
_frame_tween_from_dist, _frame_tween_to_dist: f32

// Unity's Edit > Frame Selected (F in the scene view).
@(menu_item={path="Edit/Frame Selected", order=-44, shortcut=""})
edit_frame_selected_menu :: proc() {
	scene_frame_selected()
}

scene_frame_selected :: proc() {
	// Union over ALL selected objects (Unity frames the whole selection).
	w := engine.ctx_world()
	first := true
	cmin, cmax: [3]f32
	quads := drawn_quads(scene_render_view(max(_scene_view_size.x, 1), max(_scene_view_size.y, 1)))
	for h in sel_scene_items() {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		c, r := _selection_bounds(h, quads)
		lo := c - r
		hi := c + r
		if first {
			cmin, cmax = lo, hi
			first = false
		} else {
			cmin = {min(cmin.x, lo.x), min(cmin.y, lo.y), min(cmin.z, lo.z)}
			cmax = {max(cmax.x, hi.x), max(cmax.y, hi.y), max(cmax.z, hi.z)}
		}
	}
	if first do return
	center := (cmin + cmax) * 0.5
	radius := max(linalg.length(cmax - cmin) * 0.5, 0.1)
	_frame_tween_from_target = scene_cam_target
	_frame_tween_from_dist = scene_cam_dist
	_frame_tween_to_target = center
	_frame_tween_to_dist = max(radius / math.tan(math.to_radians(SCENE_CAM_FOV_DEG) * 0.5) * 1.2, 1)
	_frame_tween_t = 0
	_frame_tween_active = true
}

_update_frame_tween :: proc(dt: f32) {
	if !_frame_tween_active do return
	_frame_tween_t = min(_frame_tween_t + dt / SCENE_FRAME_TWEEN_SEC, 1)
	t := _frame_tween_t
	k := t * t * (3 - 2 * t) // smoothstep: ease in/out
	// Framing keeps the view direction (Unity's F): the eye rides behind the
	// tweened anchor along the current forward ray.
	tgt := linalg.lerp(_frame_tween_from_target, _frame_tween_to_target, k)
	scene_cam_dist = _frame_tween_from_dist + (_frame_tween_to_dist - _frame_tween_from_dist) * k
	fwd, _, _ := _scene_cam_basis()
	scene_cam_pos = tgt - fwd * scene_cam_dist
	update_scene_camera()
	if _frame_tween_t >= 1 do _frame_tween_active = false
}

// A gizmo label at `p` (screen), shadowed, for the scene and game views. A
// rotated label is drawn glyph by glyph from the font atlas, turned 90
// degrees clockwise so it reads top to bottom with the glyph tops facing
// right: imgui has no rotated text of its own.
@(private)
_draw_handle_label :: proc(dl: ^im.DrawList, p: im.Vec2, l: engine.Gizmo_Label) {
	c := strings.clone_to_cstring(l.text, context.temp_allocator)
	font := im.GetFont()
	scale := l.scale if l.scale > 0.001 else 1.0
	font_size := im.GetFontSize() * scale
	size := im.Font_CalcTextSizeA(font, font_size, 1e10, -1.0, c)
	if !l.rotated {
		at := im.Vec2{p.x - size.x * l.align.x, p.y - size.y * l.align.y}
		im.DrawList_AddTextImFontPtr(dl, font, font_size, {at.x + 1, at.y + 1}, 0xB0000000, c)
		im.DrawList_AddTextImFontPtr(dl, font, font_size, at, im.ColorConvertFloat4ToU32(l.color), c)
		return
	}
	baked := im.Font_GetFontBaked(font, font_size)
	if baked == nil do return
	// The turned box is size.y wide and size.x tall; text x runs down it,
	// text y (down from the glyph tops) runs to the left.
	box := im.Vec2{size.y, size.x}
	origin := im.Vec2{p.x - box.x * l.align.x, p.y - box.y * l.align.y}
	draw :: proc(dl: ^im.DrawList, font: ^im.Font, baked: ^im.FontBaked, origin: im.Vec2, text_h: f32, text: string, col: u32) {
		pen := f32(0)
		for r in text {
			g := im.FontBaked_FindGlyph(baked, im.Wchar(r))
			if g == nil do continue
			if g.Visible != 0 {
				map_pt :: proc(origin: im.Vec2, text_h, gx, gy: f32) -> im.Vec2 { return {origin.x + text_h - gy, origin.y + gx} }
				im.DrawList_AddImageQuad(dl, font.OwnerAtlas.TexRef,
					map_pt(origin, text_h, pen + g.X0, g.Y0), map_pt(origin, text_h, pen + g.X1, g.Y0),
					map_pt(origin, text_h, pen + g.X1, g.Y1), map_pt(origin, text_h, pen + g.X0, g.Y1),
					{g.U0, g.V0}, {g.U1, g.V0}, {g.U1, g.V1}, {g.U0, g.V1}, col)
			}
			pen += g.AdvanceX
		}
	}
	draw(dl, font, baked, {origin.x + 1, origin.y + 1}, size.y, l.text, 0xB0000000)
	draw(dl, font, baked, origin, size.y, l.text, im.ColorConvertFloat4ToU32(l.color))
}

// UI bounds: a Canvas frames its whole rect, a RectTransform its resolved
// corners in canvas (world) space — the Transform position of a UI node means
// nothing, so framing it would go to the origin.
_ui_bounds :: proc(tH: engine.Transform_Handle) -> (center: [3]f32, radius: f32, ok: bool) {
	corners: [4][3]f32
	if _, cv := engine.transform_get_comp(tH, engine.Canvas); cv != nil {
		root, xform, _ := engine.canvas_placement(tH, engine.canvas_game_viewport())
		corners = engine.rect_corners(root, xform)
	} else if _, rt := engine.transform_get_comp(tH, engine.RectTransform); rt != nil {
		canvas := engine.canvas_of(tH)
		if canvas == {} do return {}, 0, false
		nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
		engine.canvas_resolve_placed(canvas, &nodes)
		found := false
		for n in nodes {
			if n.tH == tH {
				corners = engine.rect_corners(n.rect, n.xform)
				found = true
				break
			}
		}
		if !found do return {}, 0, false
	} else {
		return {}, 0, false
	}
	lo, hi := corners[0], corners[0]
	for c in corners[1:] {
		lo = {min(lo.x, c.x), min(lo.y, c.y), min(lo.z, c.z)}
		hi = {max(hi.x, c.x), max(hi.y, c.y), max(hi.z, c.z)}
	}
	return (lo + hi) * 0.5, max(linalg.length(hi - lo) * 0.5, 0.1), true
}

// World bounds of a skinned mesh, for the selection shapes below.
//
// A skinned mesh is posed straight into WORLD space
// (component_SkinnedMeshRenderer.odin), so its box is axis-aligned and takes
// no model matrix. The MeshFilter path below is wrong for one twice over: the
// mesh aabb is the BIND pose in the rig's own space, and pushing it through
// the owner's transform makes a box that swings with the animated root while
// the character deforms independently inside it — which reads as a shaky box
// at a strange angle.
//
// nil when the renderer has never been skinned: there is no pose to bound yet,
// and the callers fall through to the shapes they already drew.
@(private = "file")
_skinned_world_aabb :: proc(tH: engine.Transform_Handle) -> (lo, hi: [3]f32, ok: bool) {
	_, smr := engine.transform_get_comp(tH, engine.SkinnedMeshRenderer)
	if smr == nil do return {}, {}, false
	return engine.skinned_mesh_world_bounds(smr)
}

// Bounding sphere of the selection: skinned mesh from its posed world bounds,
// mesh AABB through the world transform, the quads a package renderer draws
// (`quads` is drawn_quads), or a default radius around the position
// (mirrors the shapes draw_selection_outline draws).
_selection_bounds :: proc(tH: engine.Transform_Handle, quads: Drawn_Quads) -> (center: [3]f32, radius: f32) {
	if c, r, ok := _ui_bounds(tH); ok do return c, r
	tw := engine.transform_world(tH)
	center = tw.position
	radius = 1.5

	vmin :: proc(a, b: [3]f32) -> [3]f32 {return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}}
	vmax :: proc(a, b: [3]f32) -> [3]f32 {return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}}

	// Before the MeshFilter branch: a skinned character carries both, and only
	// this one describes where it currently is.
	if lo, hi, ok := _skinned_world_aabb(tH); ok {
		center = (lo + hi) * 0.5
		radius = max(linalg.length(hi - lo) * 0.5, 0.1)
		return
	}

	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	if mf != nil && mf.mesh != {} {
		if mesh, ok := engine.mesh_load_filter(mf); ok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			lo, hi := mesh.aabb_min, mesh.aabb_max
			cmin, cmax: [3]f32
			for i in 0 ..< 8 {
				local := [4]f32{
					i & 1 == 0 ? lo.x : hi.x,
					i & 2 == 0 ? lo.y : hi.y,
					i & 4 == 0 ? lo.z : hi.z,
					1,
				}
				p := (model * local).xyz
				cmin = i == 0 ? p : vmin(cmin, p)
				cmax = i == 0 ? p : vmax(cmax, p)
			}
			center = (cmin + cmax) * 0.5
			radius = max(linalg.length(cmax - cmin) * 0.5, 0.1)
			return
		}
	}

	if n, _, lo, hi := _owner_quads(tH, quads); n > 0 {
		center = (lo + hi) * 0.5
		radius = max(linalg.length(hi - lo) * 0.5, 0.1)
	}
	return
}

// The quads `tH`'s own renderers draw, from drawn_quads: how many, the
// first, and the world box around all of them.
_owner_quads :: proc(tH: engine.Transform_Handle, quads: Drawn_Quads) -> (count: int, first: [4][3]f32, lo, hi: [3]f32) {
	for i in quads.by_owner[tH] or_else nil {
		q := quads.all[i].variant.(engine.Draw_Quad)
		if count == 0 {
			first = q.corners
			lo, hi = q.corners[0], q.corners[0]
		}
		for p in q.corners {
			lo = linalg.min(lo, p)
			hi = linalg.max(hi, p)
		}
		count += 1
	}
	return
}

// Effective vertical FOV in degrees (never scaled by Ctrl+Wheel so mouse look stays consistent).
scene_cam_effective_fov_deg :: proc() -> f32 {
	return clamp(scene_cam_fov_deg, 10.0, 120.0)
}

// Half the visible height at the anchor: what the perspective view shows at
// scene_cam_dist, and the orthographic view's half height.
scene_cam_half_height :: proc() -> f32 {
	return max(scene_cam_dist, CAM_MIN_DIST) * math.tan(math.to_radians(scene_cam_effective_fov_deg()) * 0.5)
}

// The scene view's Render_View — also the basis for picking rays later.
// When `unclipped_ortho` is true in 2D mode, near_clip is extended to -SCENE_CAM_FAR
// so 3D transform gizmos, handles, and picking rays are never clipped when slicing deep into a mesh.
scene_render_view :: proc(w, h: f32, unclipped_ortho := false) -> engine.Render_View {
	_, _, cam_up := _scene_cam_basis()
	view := linalg.matrix4_look_at_f32(scene_cam_pos, scene_cam_target, cam_up)
	aspect := w / max(h, 1)
	proj: matrix[4, 4]f32
	if scene_cam_ortho {
		half_h := scene_cam_half_height()
		half_w := half_h * aspect
		near_clip: f32 = unclipped_ortho ? -SCENE_CAM_FAR : SCENE_CAM_NEAR
		proj = gfx.matrix4_ortho_z01(-half_w, half_w, -half_h, half_h, near_clip, SCENE_CAM_FAR)
	} else {
		// Adaptive near clip plane in 3D perspective mode:
		// Using 0.001m everywhere consumed 99.995% of the 24-bit depth buffer inside the first 20cm,
		// leaving ~4.8cm depth quantization steps at 20m that caused planar floor shadows to Z-fight.
		// Scaling near_persp between 0.04m (close-up) and 0.22m (normal room view) increases depth
		// precision by 100x-220x while still letting the camera fly right up to any mesh.
		near_persp := clamp(scene_cam_dist * 0.01, 0.04, 0.22)
		far_persp  := max(scene_cam_dist * 80.0, 3000.0)
		proj = gfx.matrix4_perspective_z01(math.to_radians(scene_cam_effective_fov_deg()), aspect, near_persp, far_persp)
	}
	return engine.render_view_make(view, proj, w, h, ~u32(0), .SceneView) // editor sees all layers
}

render_scene_rt :: proc(w, h: i32) {
	if w < 1 || h < 1 do return
	gfx.rt_resize(scene_rt, w, h)

	gfx.pass_begin_target(scene_rt, [4]f32{0.15, 0.15, 0.15, 1})
	gfx.set_post_fx(gfx.POST_FX_DEFAULT)
	view := scene_render_view(f32(w), f32(h), unclipped_ortho = false)
	gfx.set_view_proj(view.view_proj, view.cam_pos)

	commands := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	prev_suppress := engine.canvas_suppress_overlay_in_scene_3d()
	if !scene_2d_mode {
		engine.canvas_set_suppress_overlay_in_scene_3d(true)
	}
	engine.render_collect_commands(view, &commands)
	engine.canvas_set_suppress_overlay_in_scene_3d(prev_suppress)
	engine.render_execute(view, commands[:])

	// Draw the grid and axis lines AFTER scene meshes so in 2D mode the active
	// depth-slice workplane grid depth-tests against 3D meshes and visibly slices through them.
	draw_grid()
	draw_axis_lines()

	// The gizmo pass (gizmo_pass.odin) recorded the outline, the handles, the
	// transform gizmo and the gizmo hooks before this render. The next pass reads the view's size
	// and the frame it rendered in. Keep near_clip at SCENE_CAM_NEAR so passing through a mesh
	// clips wireframes and gizmos behind the camera cleanly.
	_scene_rendered_frame = gfx.frame_index
	_scene_view_size = {f32(w), f32(h)}
	gizmo_view := scene_render_view(f32(w), f32(h), unclipped_ortho = false)
	if scene_2d_mode {
		gfx.set_view_proj(gizmo_view.view_proj, gizmo_view.cam_pos)
	}
	gizmos.set_view(gizmo_view)
	_scene_view_last = gizmo_view
	// Gameplay shapes, gizmos, then tools: depth-tested first, then the rest over them.
	gizmos.draw(scene_gizmo_channels())
	gfx.pass_end()
}

// Orange wireframe on the selected object: mesh → its local AABB edges
// through the world transform; a package renderer → the quad it draws (a
// sprite), or the box around its quads when it draws several (particles);
// neither → a small axis cross at the position. `quads` is drawn_quads.
// A UI node gets the cross: its rect is its selection shape, and the rect
// tool draws that.
//
// A SKINNED mesh deliberately gets no box. Its mesh aabb is the bind pose in
// the rig's own space, so the box below swings with the animated root while
// the character deforms independently inside it. The box is a stand-in for a
// silhouette outline, which is what an editor draws here when it can, and a
// box at the wrong angle is further from that than nothing — the transform
// gizmo and the axis cross still mark the selection. `_selection_bounds` does
// use the posed world bounds, so framing the selection still frames the
// character where it actually is.
draw_selection_outline :: proc(tH: engine.Transform_Handle, quads: Drawn_Quads) {
	out_col := editor_visuals.get_outline_color()
	out_scale := editor_visuals.get_outline_scale()
	out_thick := editor_visuals.get_outline_thickness()
	out_cross := editor_visuals.get_outline_cross_size()

	gizmos.with_color(out_col)
	tw := engine.transform_world(tH)

	_, skinned := engine.transform_get_comp(tH, engine.SkinnedMeshRenderer)

	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	_, mr := engine.transform_get_comp(tH, engine.MeshRenderer)
	if skinned == nil && mf != nil && mf.mesh != {} && (mr == nil || mr.enabled) {
		if mesh, ok := engine.mesh_load_filter(mf); ok {
			gizmos.in_local_space(tH)
			lo, hi := mesh.aabb_min, mesh.aabb_max
			center := (lo + hi) * 0.5
			size := (hi - lo) * out_scale
			gizmos.wire_box(center, size)
			if out_thick > 1.3 {
				gizmos.wire_box(center, size * 1.01)
			}
			return
		}
	}

	if _, rt := engine.transform_get_comp(tH, engine.RectTransform); rt == nil {
		n, first, lo, hi := _owner_quads(tH, quads)
		if n == 1 {
			gizmos.wire_quad(first)
			return
		}
		if n > 1 {
			center := (lo + hi) * 0.5
			size := (hi - lo) * out_scale
			gizmos.wire_box(center, size)
			if out_thick > 1.3 {
				gizmos.wire_box(center, size * 1.01)
			}
			return
		}
	}

	gizmos.line_cross(tw.position, out_cross)
}

// Scene grid: per-plane toggles + cell layout, edited via the Grid overlay
// overlay popup (draw_grid_overlay) and persisted in editor_settings.
// A cell is cell_size units, drawn with emphasized lines; subdivide splits
// each cell into N fine-line divisions; cells_count is cells from center to side.
Grid_Settings :: struct {
	show_xz:     bool,
	show_xy:     bool,
	show_yz:     bool,
	show_axes:   bool,
	cell_size:   f32, // one cell in world units (emphasized lines)
	subdivide:   i32, // fine-line divisions per cell (1 = none)
	cells_count: i32, // cells from center to side (radius)
}

GRID_DEFAULTS :: Grid_Settings{show_xz = true, show_axes = false, cell_size = 10, subdivide = 10, cells_count = 2}

// Gizmo drag snapping (Snap overlay popup; Ctrl inverts enabled while held).
// Translate step comes from `mode`: a full grid cell, one grid subdivision,
// or a free `units` value (> 0).
Snap_Mode :: enum u8 {
	Grid,
	SubGrid,
	Units,
}

Snap_Settings :: struct {
	enabled: bool,
	angle:   f32, // rotate snap, degrees
	mode:    Snap_Mode,
	units:   f32, // translate step when mode == .Units
}

SNAP_DEFAULTS :: Snap_Settings{enabled = false, angle = 15, mode = .SubGrid, units = 1}

snap_settings := SNAP_DEFAULTS

// Translate-snap step in world units per the active snap mode.
snap_translate_step :: proc() -> f32 {
	gs := grid_settings
	switch snap_settings.mode {
	case .Grid:    return max(gs.cell_size, 0.0001)
	case .SubGrid: return max(gs.cell_size / f32(max(gs.subdivide, 1)), 0.0001)
	case .Units:   return max(snap_settings.units, 0.0001)
	}
	return 1
}

grid_settings := GRID_DEFAULTS

_GRID_CELL_COL :: [4]f32{0.46, 0.46, 0.46, 1} // cell-boundary lines
_GRID_SUB_COL :: [4]f32{0.3, 0.3, 0.3, 1}     // subdivision lines
_2d_depth_pulse_timer: f32

draw_grid :: proc() {
	gs := grid_settings
	if gs.cells_count <= 0 || gs.cell_size <= 0 do return
	if scene_2d_mode {
		fwd, _, _ := _scene_cam_basis()
		origin_pos := [3]f32{0, 0, 0}
		if w := engine.ctx_world(); w != nil {
			for h in sel_scene_items() {
				if engine.pool_valid(&w.transforms, engine.Handle(h)) {
					origin_pos = engine.transform_world(h).position
					break
				}
			}
		}
		// Place the 2D workplane grid at the active origin's depth plane so moving
		// the 3D camera forward/backward with the mouse wheel visibly travels toward
		// and through the workplane and mesh in 3D perspective.
		slice_off := fwd * linalg.dot(origin_pos, fwd)
		switch scene_2d_angle {
		case .Front, .Back:
			_draw_grid_plane({1, 0, 0}, {0, 1, 0}, slice_off) // XY plane at origin depth
		case .Left, .Right:
			_draw_grid_plane({0, 0, 1}, {0, 1, 0}, slice_off) // YZ plane at origin depth
		case .Top, .Bottom:
			_draw_grid_plane({1, 0, 0}, {0, 0, 1}, slice_off) // XZ plane at origin depth
		}
		return
	}
	if gs.show_xz do _draw_grid_plane({1, 0, 0}, {0, 0, 1})
	if gs.show_xy do _draw_grid_plane({1, 0, 0}, {0, 1, 0})
	if gs.show_yz do _draw_grid_plane({0, 1, 0}, {0, 0, 1})
}

// One grid plane spanned by axes u,v: fine lines every cell_size/subdivide;
// every subdivide-th line is a cell boundary and draws emphasized.
_draw_grid_plane :: proc(u, v: [3]f32, plane_offset: [3]f32 = {0, 0, 0}) {
	gs := grid_settings
	sub := max(gs.subdivide, 1)
	step := gs.cell_size / f32(sub)
	n := gs.cells_count * sub // fine steps from center to side
	half := f32(gs.cells_count) * gs.cell_size
	pulse := clamp(_2d_depth_pulse_timer / 0.6, 0.0, 1.0)
	cell_col := linalg.lerp(_GRID_CELL_COL, [4]f32{0.35, 0.78, 1.0, 1.0}, pulse * 0.55)
	sub_col  := linalg.lerp(_GRID_SUB_COL,  [4]f32{0.22, 0.52, 0.72, 1.0}, pulse * 0.40)
	for i in -n ..= n {
		off := f32(i) * step
		col := i % sub == 0 ? cell_col : sub_col
		gfx.draw_line(plane_offset + u * off - v * half, plane_offset + u * off + v * half, col, depth_write = true)
		gfx.draw_line(plane_offset + v * off - u * half, plane_offset + v * off + u * half, col, depth_write = true)
	}
}

draw_axis_lines :: proc() {
	if !grid_settings.show_axes do return
	gfx.draw_line({0, 0, 0}, {5, 0, 0}, {0.9, 0.16, 0.22, 1}, depth_write = true) // X red
	gfx.draw_line({0, 0, 0}, {0, 5, 0}, {0, 0.89, 0.19, 1}, depth_write = true)   // Y green
	gfx.draw_line({0, 0, 0}, {0, 0, 5}, {0, 0.47, 0.95, 1}, depth_write = true)   // Z blue
}

@(private = "file") _last_active_scene_path: string

_check_scene_view_switch :: proc() {
	active := engine.sm_scene_get_active()
	cur_path := active != nil ? active.path : ""
	if cur_path != _last_active_scene_path {
		if len(_last_active_scene_path) > 0 {
			if editor_settings.scene_views == nil {
				editor_settings.scene_views = make(map[string]SceneCameraView)
			}
			key_to_use := _last_active_scene_path
			if !(_last_active_scene_path in editor_settings.scene_views) {
				key_to_use = strings.clone(_last_active_scene_path)
			}
			editor_settings.scene_views[key_to_use] = SceneCameraView{
				has_pos  = true,
				pos      = scene_cam_pos,
				yaw      = _pre_2d_yaw if scene_2d_mode else scene_cam_yaw,
				pitch    = _pre_2d_pitch if scene_2d_mode else scene_cam_pitch,
				dist     = scene_cam_dist,
				ortho    = _pre_2d_ortho if scene_2d_mode else scene_cam_ortho,
				is_2d    = scene_2d_mode,
				angle_2d = scene_2d_angle,
			}
		}
		delete(_last_active_scene_path)
		_last_active_scene_path = strings.clone(cur_path)
		if len(cur_path) > 0 && editor_settings.scene_views != nil {
			if v, ok := editor_settings.scene_views[cur_path]; ok && v.has_pos {
				_scene_2d_pending = false
				if v.is_2d {
					_pre_2d_yaw = v.yaw
					_pre_2d_pitch = v.pitch
					_pre_2d_ortho = v.ortho
					scene_cam_pos = v.pos
					scene_cam_dist = max(v.dist, 0.1)
					scene_2d_angle = v.angle_2d
					scene_set_2d(true, preserve_pos = true)
				} else {
					if scene_2d_mode {
						scene_set_2d(false)
					}
					scene_cam_pos = v.pos
					scene_cam_yaw = v.yaw
					scene_cam_pitch = v.pitch
					scene_cam_dist = max(v.dist, 0.1)
					scene_cam_ortho = v.ortho
					update_scene_camera()
				}
			}
		}
	}
}

@(private = "file") _scene_was_docked: bool = true

draw_scene_view :: proc() {
	_check_scene_view_switch()

	dt := im.GetIO().DeltaTime
	if _speed_hud_timer > 0 do _speed_hud_timer = max(_speed_hud_timer - dt, 0)
	if _2d_depth_pulse_timer > 0 do _2d_depth_pulse_timer = max(_2d_depth_pulse_timer - dt, 0)

	// Zero padding so the render target fills the window edge to edge. Popped
	// as soon as Begin has read it (the content region is computed there):
	// held any longer, every tooltip and popup the overlays raise is a window
	// too and would draw its text flush against its own border.
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})

	// NoScrollbar: overlays draw ON the image with last-frame sizes, so a
	// freshly appearing or resizing overlay can momentarily extend past the
	// window edge — a scrollbar would shrink the content region, resize the
	// RT and shift the image, oscillating for frames.
	// A star on the tab while the active scene has unsaved edits. Only the
	// text after ### is the window id, so the label can change freely.
	// Note: Originally called "Scene"; renamed to "Scene3D" (keeping ###Scene ID).
	scene_title: cstring = icons.TITLE_SCENE
	if active := engine.sm_scene_get_active(); active != nil && active.dirty {
		scene_title = icons.ICON_MD_LANDSCAPE + " Scene3D *###Scene"
	}
	scene_flags: im.WindowFlags = {.NoCollapse, .NoScrollbar, .NoScrollWithMouse}
	if _scene_was_docked {
		scene_flags += {.NoMove}
	}
	open := wnd.begin(scene_title, &menu.show_scene, scene_flags)
	im.PopStyleVar()
	if open {
		_scene_was_docked = im.IsWindowDocked()
		wnd.decorate_floating_window(scene_title, &menu.show_scene)
		if _scene_2d_pending {
			_scene_2d_pending = false
			scene_set_2d(true, preserve_pos = editor_settings.scene_cam_has_pos)
		}

		// Docked toolbar strips take their space first; the image gets what
		// is left, so a strip sits beside the render instead of over it.
		overlays_measure_bars()
		bar_l, bar_r, bar_t, bar_b := overlay_bar_insets()
		content_min := im.GetCursorScreenPos()
		avail := im.GetContentRegionAvail()
		content_max := content_min + avail
		avail.x = max(avail.x - bar_l - bar_r, 0)
		avail.y = max(avail.y - bar_t - bar_b, 0)
		w := i32(avail.x)
		h := i32(avail.y)

		if w > 0 && h > 0 {
			render_scene_rt(w, h)
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(scene_rt)))
			im.SetCursorScreenPos({content_min.x + bar_l, content_min.y + bar_t})
			if tex_id != 0 {
				im.Image(im.TextureRef{_TexID = tex_id}, avail)
			} else {
				im.Dummy(avail)
			}
			_scene_img_min = im.GetItemRectMin()
			if im.BeginDragDropTarget() {
				if payload := im.AcceptDragDropPayload("ASSET_PATH", {}); payload != nil && payload.Data != nil && payload.DataSize > 0 {
					path := strings.trim_right_null(string(([^]byte)(payload.Data)[:payload.DataSize]))
					editor_drop_asset_in_scene(path, im.GetMousePos())
				} else if payload_pptr := im.AcceptDragDropPayload("ASSET_PPTR", {}); payload_pptr != nil && payload_pptr.Data != nil && int(payload_pptr.DataSize) == size_of(engine.PPtr) {
					pptr := (cast(^engine.PPtr)payload_pptr.Data)^
					if p_str, p_ok := engine.asset_db_get_path(uuid.Identifier(pptr.guid)); p_ok && len(p_str) > 0 {
						editor_drop_asset_in_scene(p_str, im.GetMousePos())
					}
				}
				im.EndDragDropTarget()
			}
			// Gizmo labels (anchor percentages and such) over the image,
			// shadowed so they read on any background.
			dl := im.GetWindowDrawList()
			for l in gizmos.labels(scene_gizmo_channels()) {
				px, ok := gizmos.helper_project_in(_scene_view_last, l.pos)
				if !ok do continue
				_draw_handle_label(dl, _scene_img_min + px + l.offset_px, l)
			}
			overlays_draw(_scene_img_min, _scene_img_min + avail, content_min, content_max)
			cad_csg_editor.draw_cad_left_drawer(_scene_img_min, _scene_img_min + avail)
			_draw_cad_ruler_overlay(dl, _scene_img_min, _scene_img_min + avail)
			if scene_2d_mode {
				_draw_2d_cad_hud(dl, _scene_img_min, _scene_img_min + avail)
			} else if _speed_hud_timer > 0 {
				_draw_3d_speed_hud(dl, _scene_img_min, _scene_img_min + avail)
			}
		}

		scene_view_hovered = im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem)
		if scene_view_hovered && (im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)) && !overlay_wants_mouse() {
			im.SetWindowFocus()
		}
		if (!scene_view_hovered && im.IsMouseClicked(.Left)) || (overlay_wants_mouse() && !handles.dragging()) {
			gizmo_end_drag_if_any()
		}
		// Flythrough is hover-independent once latched: the captured cursor
		// is pinned, so hover can't be trusted mid-flight.
		if scene_view_hovered || scene_flythrough_active {
			handle_scene_input()
		}
		// Band tracking is hover-independent: the drag keeps working when the
		// cursor leaves the image, like orbit/gizmo drags.
		if _band_active {
			_update_rubber_band()
		}
		_draw_pick_menu()
		_draw_scene_context_menu()
	}
	im.End()
}

// --- Context menu ----------------------------------------------------------------------
// A right-click opens the object's menu, the hierarchy row's own (the Edit
// selection band and the GameObject bands, every registered item), and
// selects the object first unless it is already in the selection. On empty
// space it opens the hierarchy background's menu: create and view items.

// Pointer travel, in pixels, and hold duration, in seconds, under which a
// right-click counts as a human single-click (context menu) rather than
// holding/dragging RMB for Screen Rotate / Fly mode.
CONTEXT_CLICK_SLOP_PX      :: f32(6.0)
CONTEXT_CLICK_MAX_HOLD_SEC :: f32(0.24)

@(private = "file") _ctx_click_pending:   bool
@(private = "file") _ctx_click_pos:       [2]f32 // scene-image pixels at the press
@(private = "file") _ctx_click_travel:    f32
@(private = "file") _ctx_click_hold_time: f32
@(private = "file") _ctx_menu_target: engine.Transform_Handle // {} = empty space
@(private = "file") _scene_spawn_pos: [3]f32 // 3D world coordinates where clicked

@(private = "file")
_scene_context_menu_open :: proc(view: engine.Render_View, px, py: f32) {
	prev_suppress := engine.canvas_suppress_overlay_in_scene_3d()
	if !scene_2d_mode do engine.canvas_set_suppress_overlay_in_scene_3d(true)
	hits := scene_view_pick_all(view, px, py)
	engine.canvas_set_suppress_overlay_in_scene_3d(prev_suppress)
	ray := engine.render_view_screen_ray(view, px, py)

	if len(hits) > 0 {
		_ctx_menu_target = hits[0].tH
		_scene_spawn_pos = ray.origin + ray.direction * hits[0].t
		if !sel_scene_is(hits[0].tH) {
			sel_scene_only(hits[0].tH)
			engine.inspector_set_active_selection(hits[0].tH)
			engine.inspector_set_selection_all({hits[0].tH})
		}
	} else {
		_ctx_menu_target = {}
		// Intersect with ground plane Y = 0 if ray is pointing towards it
		if abs(ray.direction.y) > 0.001 {
			t_ground := -ray.origin.y / ray.direction.y
			if t_ground > 0.1 && t_ground < 100.0 {
				_scene_spawn_pos = ray.origin + ray.direction * t_ground
			} else {
				_scene_spawn_pos = ray.origin + ray.direction * 5.0
			}
		} else {
			_scene_spawn_pos = ray.origin + ray.direction * 5.0
		}
	}
	im.OpenPopup("##scene_context_menu")
}

@(private = "file")
_scene_create_node :: proc(name: string, comp_keys: []engine.TypeKey, pos: [3]f32, parent: engine.Transform_Handle = {}) {
	scene := engine.sm_scene_get_active()
	if scene == nil do return
	w := engine.ctx_world()

	actual_parent := parent
	if actual_parent == {} || !engine.pool_valid(&w.transforms, engine.Handle(actual_parent)) {
		actual_parent = engine.Transform_Handle(scene.root.handle)
	}

	g := undo.group_begin(fmt.tprintf("Create %s", name))
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	newH := engine.transform_new(name, actual_parent)
	undo.record_create(newH, actual_parent)
	engine.transform_ensure_unique_name(newH)

	t := engine.pool_get(&w.transforms, engine.Handle(newH))
	if t != nil {
		if actual_parent == engine.Transform_Handle(scene.root.handle) {
			t.position = pos
		} else {
			pw := engine.transform_world(actual_parent)
			safe_scale := [3]f32{
				pw.scale.x != 0 ? pw.scale.x : 1,
				pw.scale.y != 0 ? pw.scale.y : 1,
				pw.scale.z != 0 ? pw.scale.z : 1,
			}
			inv_rot := linalg.quaternion_inverse(engine.quat_to_native(pw.rotation))
			t.position = linalg.quaternion128_mul_vector3(inv_rot, pos - pw.position) / safe_scale
			t.scale = [3]f32{1, 1, 1} / safe_scale
		}
	}

	for key in comp_keys {
		owned, ptr := engine.transform_add_comp(newH, key)
		if ptr != nil {
			if key == .MeshFilter {
				if mf := cast(^engine.MeshFilter)ptr; mf != nil {
					if guid, err := uuid.read("9b978885-12f8-4d30-be4d-d9c2c2074477"); err == nil {
						mf.mesh = engine.PPtr{guid = engine.Asset_GUID(guid)}
					}
				}
			} else if key == .MeshRenderer {
				if mr := cast(^engine.MeshRenderer)ptr; mr != nil {
					if guid, err := uuid.read("86518465-b823-4eb9-b3f5-c0deef450fc6"); err == nil {
						append(&mr.materials, engine.Asset_GUID(guid))
					}
				}
			} else if key == .Light {
				if l := cast(^engine.Light)ptr; l != nil {
					engine.reset_Light(l)
					if strings.contains(name, "Point") {
						l.type = .Point
						l.intensity = 1.6
						l.range = 14.0
					} else if strings.contains(name, "Spot") {
						l.type = .Spot
						l.intensity = 2.0
						l.range = 16.0
						l.spot_angle = 42.0
						l.inner_spot_angle = 28.0
					}
				}
				if t_light := engine.pool_get(&w.transforms, engine.Handle(newH)); t_light != nil {
					if t_light.position.y < 0.5 {
						t_light.position.y += 4.5
					}
					if t_light.rotation == engine.QUAT_IDENTITY {
						t_light.rotation = {-0.402641, 0.272532, 0.127084, 0.864361}
					}
				}
			} else if key == .Camera {
				if c := cast(^engine.Camera)ptr; c != nil {
					c.fov = 60.0
					c.near_clip = 0.3
					c.far_clip = 1000.0
				}
			}
			t_curr := engine.pool_get(&w.transforms, engine.Handle(newH))
			if t_curr != nil {
				undo.record_add_component(newH, owned.handle, len(t_curr.components) - 1)
			}
		}
	}

	scene.dirty = true
	undo.group_commit(&g)
	engine.inspector_request_select(newH)
}

@(private = "file")
_scene_draw_create_node_menu_items :: proc(parent: engine.Transform_Handle, pos: [3]f32) {
	if im.MenuItem(fmt.ctprintf("%s  Node (Empty)", icons.ICON_MD_ACCOUNT_TREE)) {
		_scene_create_node("Node", nil, pos, parent)
	}
	im.Separator()

	// 3D Nodes (Godot Node3D style)
	if im.BeginMenu(fmt.ctprintf("%s  3D Nodes (Node3D)", icons.ICON_MD_DEPLOYED_CODE)) {
		if im.MenuItem(fmt.ctprintf("%s  Mesh (MeshFilter + MeshRenderer)", icons.ICON_MD_DEPLOYED_CODE)) {
			_scene_create_node("Mesh", {.MeshFilter, .MeshRenderer}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  SkinnedMesh (MeshFilter + SkinnedMeshRenderer)", icons.ICON_MD_ANIMATION)) {
			_scene_create_node("SkinnedMesh", {.MeshFilter, .SkinnedMeshRenderer}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Camera3D", icons.ICON_MD_VISIBILITY)) {
			_scene_create_node("Camera3D", {.Camera}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Directional Light (Sun + Shadows)", icons.ICON_MD_RECORD)) {
			_scene_create_node("DirectionalLight3D", {.Light}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Point Light (Omni + Shadows)", icons.ICON_MD_RECORD)) {
			_scene_create_node("PointLight3D", {.Light}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Spot Light (Cone + Shadows)", icons.ICON_MD_RECORD)) {
			_scene_create_node("SpotLight3D", {.Light}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  RigidBody3D (Rigidbody + BoxCollider)", icons.ICON_MD_WIDGETS)) {
			_scene_create_node("RigidBody3D", {.Rigidbody, .BoxCollider}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  ParticleSystem", icons.ICON_MD_ANIMATION)) {
			_scene_create_node("ParticleSystem", {.ParticleSystem}, pos, parent)
		}
		im.EndMenu()
	}

	// 2D Nodes (Godot Node2D style)
	if im.BeginMenu(fmt.ctprintf("%s  2D Nodes (Node2D)", icons.ICON_MD_IMAGE)) {
		if im.MenuItem(fmt.ctprintf("%s  Sprite2D (SpriteRenderer)", icons.ICON_MD_IMAGE)) {
			_scene_create_node("Sprite2D", {.SpriteRenderer}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  RigidBody2D (Rigidbody2D + BoxCollider2D)", icons.ICON_MD_WIDGETS)) {
			_scene_create_node("RigidBody2D", {.Rigidbody2D, .BoxCollider2D}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  SpriteSortingGroup", icons.ICON_MD_LAYERS)) {
			_scene_create_node("SpriteSortingGroup", {.SpriteSortingGroup}, pos, parent)
		}
		im.EndMenu()
	}

	// UI Elements (Godot Control style)
	if im.BeginMenu(fmt.ctprintf("%s  UI Elements (Control)", icons.ICON_MD_DESCRIPTION)) {
		if im.MenuItem(fmt.ctprintf("%s  Canvas (Root UI)", icons.ICON_MD_LAYERS)) {
			_scene_create_node("Canvas", {.Canvas, .CanvasScaler, .GraphicRaycaster}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Text (Label)", icons.ICON_MD_DESCRIPTION)) {
			_scene_create_node("Text", {.RectTransform, .Text}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Button", icons.ICON_MD_WIDGETS)) {
			_scene_create_node("Button", {.RectTransform, .Image, .Button}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  Image (TextureRect)", icons.ICON_MD_IMAGE)) {
			_scene_create_node("Image", {.RectTransform, .Image}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  LayoutGroup (Container)", icons.ICON_MD_ACCOUNT_TREE)) {
			_scene_create_node("LayoutGroup", {.RectTransform, .LayoutGroup}, pos, parent)
		}
		im.EndMenu()
	}

	// Audio
	if im.BeginMenu(fmt.ctprintf("%s  Audio", icons.ICON_MD_VOLUME_UP)) {
		if im.MenuItem(fmt.ctprintf("%s  AudioSource", icons.ICON_MD_VOLUME_UP)) {
			_scene_create_node("AudioSource", {.AudioSource}, pos, parent)
		}
		if im.MenuItem(fmt.ctprintf("%s  AudioListener", icons.ICON_MD_VOLUME_UP)) {
			_scene_create_node("AudioListener", {.AudioListener}, pos, parent)
		}
		im.EndMenu()
	}
}

@(private = "file")
_draw_scene_context_menu :: proc() {
	if !im.BeginPopup("##scene_context_menu") do return
	defer im.EndPopup()
	w := engine.ctx_world()

	cad_csg_editor.draw_scene_context_menu_cad_items(_ctx_menu_target)

	if _ctx_menu_target != {} && engine.pool_valid(&w.transforms, engine.Handle(_ctx_menu_target)) {
		t := engine.pool_get(&w.transforms, engine.Handle(_ctx_menu_target))
		if t != nil {
			widgets.text_coloredf(thm.palette().accent, "%s  %s", icons.ICON_MD_DEPLOYED_CODE, t.name)
			im.Separator()
		}

		if im.BeginMenu(fmt.ctprintf("%s  Add Child Node", icons.ICON_MD_ADD)) {
			_scene_draw_create_node_menu_items(_ctx_menu_target, _scene_spawn_pos)
			im.EndMenu()
		}

		if im.BeginMenu(fmt.ctprintf("%s  Add Sibling at Surface (%.1f, %.1f, %.1f)", icons.ICON_MD_TRIP_ORIGIN, _scene_spawn_pos.x, _scene_spawn_pos.y, _scene_spawn_pos.z)) {
			parentH := engine.Transform_Handle(t.parent.handle)
			_scene_draw_create_node_menu_items(parentH, _scene_spawn_pos)
			im.EndMenu()
		}

		im.Separator()

		if im.MenuItem(fmt.ctprintf("%s  Frame Selected (F)", icons.ICON_MD_CENTER_FOCUS)) {
			scene_frame_selected()
		}

		menu.draw_menu_sections({
			menu.section("Edit", min_order = menu.EDIT_SECTION_SELECTION_MIN, max_order = menu.EDIT_SECTION_SELECTION_MAX),
		})
	} else {
		widgets.text_disabledf("Spawn Position: [%.1f, %.1f, %.1f]", _scene_spawn_pos.x, _scene_spawn_pos.y, _scene_spawn_pos.z)
		im.Separator()

		_scene_draw_create_node_menu_items({}, _scene_spawn_pos)

		im.Separator()
		menu.draw_menu_sections({
			menu.section("GameObject", max_order = menu.GO_SECTION_PARENTING - 1),
			menu.section("GameObject", min_order = menu.GO_SECTION_VIEW),
		})
	}
}

// --- Pick menu -----------------------------------------------------------------------
// Cmd (Ctrl) + right-click lists every object under the pointer, nearest
// first, and a row selects it: the way to reach an object a nearer one
// covers. The list is taken at the click, so it stays put while the menu is
// open.

@(private = "file")
_pick_menu: [dynamic]engine.Transform_Handle // cross-frame: default allocator

@(private = "file")
_pick_menu_open :: proc(view: engine.Render_View, px, py: f32) {
	if _pick_menu == nil do _pick_menu = make([dynamic]engine.Transform_Handle, runtime.default_allocator())
	clear(&_pick_menu)
	prev_suppress := engine.canvas_suppress_overlay_in_scene_3d()
	if !scene_2d_mode do engine.canvas_set_suppress_overlay_in_scene_3d(true)
	for h in scene_view_pick_all(view, px, py) do append(&_pick_menu, h.tH)
	engine.canvas_set_suppress_overlay_in_scene_3d(prev_suppress)
	if len(_pick_menu) > 0 do im.OpenPopup("##scene_pick_menu")
}

@(private = "file")
_draw_pick_menu :: proc() {
	if !im.BeginPopup("##scene_pick_menu") do return
	w := engine.ctx_world()
	for h in _pick_menu {
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue // gone since the click
		im.PushIDInt(i32(h.index))
		if im.MenuItem(strings.clone_to_cstring(t.name, context.temp_allocator)) {
			engine.inspector_request_select(h)
		}
		im.PopID()
	}
	im.EndPopup()
}

_update_rubber_band :: proc() {
	if !im.IsMouseDown(.Left) {
		_band_active = false // released: the tracker records the final set
		return
	}
	mp := im.GetMousePos()
	rmin := im.Vec2{min(mp.x, _band_anchor.x), min(mp.y, _band_anchor.y)}
	rmax := im.Vec2{max(mp.x, _band_anchor.x), max(mp.y, _band_anchor.y)}

	if scene_rt != nil {
		view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
		vmin := [2]f32{rmin.x - _scene_img_min.x, rmin.y - _scene_img_min.y}
		vmax := [2]f32{rmax.x - _scene_img_min.x, rmax.y - _scene_img_min.y}
		hits := scene_view_band_query(view, vmin, vmax)
		sel_scene_clear()
		if _band_additive {
			for h in _band_base do sel_scene_add(h)
		}
		for h in hits do sel_scene_add(h)
	}

	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(im.Vec4{0.35, 0.55, 1, 0.12}))
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(im.Vec4{0.5, 0.7, 1, 0.9}))
}

@(private = "file")
_ruler_mode_label :: proc(m: Ruler_Mode) -> cstring {
	switch m {
	case .Surface_Clearance:  return "Surface + Wall Clearance"
	case .Vertical_Height:    return "Vertical Height / Axis-Locked"
	case .Along_Mesh_Surface: return "Along Mesh Surface (3D Tape)"
	case .Angle_Protractor:   return "Protractor / Angle & Slope"
	}
	return "Surface + Wall Clearance"
}

@(private = "file")
_ruler_angle_unit_label :: proc(u: Ruler_Angle_Unit) -> cstring {
	switch u {
	case .Degrees:    return "Degrees (deg)"
	case .Radians:    return "Radians (rad)"
	case .Quaternion: return "Quaternion (x,y,z,w)"
	}
	return "Degrees (deg)"
}

@(private = "file")
_ruler_axis_lock_label :: proc(a: Ruler_Axis_Lock) -> cstring {
	switch a {
	case .None:    return "Free 3D"
	case .World_X: return "Lock X"
	case .World_Y: return "Lock Y (Height)"
	case .World_Z: return "Lock Z"
	}
	return "Free 3D"
}

@(private = "file")
_draw_ruler_right_click_settings :: proc() {
	im.TextColored({1.0, 0.85, 0.25, 1.0}, "3D & 2D Ruler Settings (Shortcut: M)")
	im.SetNextItemWidth(200)
	if im.BeginCombo("Ruler Mode##rc_rmode", _ruler_mode_label(_ruler_mode)) {
		for m in Ruler_Mode {
			if im.Selectable(_ruler_mode_label(m), _ruler_mode == m) {
				_ruler_mode = m
				if m == .Vertical_Height && _ruler_axis_lock == .None {
					_ruler_axis_lock = .World_Y
				}
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("What the ruler measures: surface distance + wall clearance, vertical height, distance along a mesh surface, or angles / slope")
	im.SetNextItemWidth(200)
	if im.BeginCombo("Axis Lock##rc_raxis", _ruler_axis_lock_label(_ruler_axis_lock)) {
		for a in Ruler_Axis_Lock {
			if im.Selectable(_ruler_axis_lock_label(a), _ruler_axis_lock == a) {
				_ruler_axis_lock = a
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Lock the measurement to world X, Y (height) or Z so camera tilt never skews it (hotkeys X / Y / Z, N = free)")
	im.SetNextItemWidth(200)
	if im.BeginCombo("Angle Format##rc_rang", _ruler_angle_unit_label(_ruler_angle_unit)) {
		for u in Ruler_Angle_Unit {
			if im.Selectable(_ruler_angle_unit_label(u), _ruler_angle_unit == u) {
				_ruler_angle_unit = u
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Show angles in degrees, radians or as a quaternion (x, y, z, w)")
	im.SetNextItemWidth(180)
	im.SliderFloat("2D Depth Step", &scene_2d_wheel_step, 0.05, 5.0, "%.2f m")
	widgets.tooltip("How far one mouse-wheel notch moves the 2D view's depth plane")
	if im.Button("Clear All Pinned Rulers", {-1, 22}) {
		_ruler_dragging = false
		_ruler_has_measurement = false
		clear(&_ruler_pinned)
	}
	widgets.tooltip("Remove the active measurement and every pinned ruler")
}


// Unity-style Tools overlay item (dockable, dock.odin): gizmo mode
// toggles + universal 3D/2D Ruler (mutually exclusive with Move/Rotate/Scale and CAD tools).
@(scene_overlay={id="Tools", order=0})
draw_tools_overlay :: proc(vertical: bool) {
	cad_active := cad_csg_editor.is_cad_tool_active()

	mode_button :: proc(icon: cstring, tooltip: cstring, mode: Gizmo_Mode, vertical: bool, cad_active: bool, impl: runtime.Source_Code_Location, impl_label: string, first := false, loc := #caller_location) {
		if !vertical && !first do im.SameLine()
		widgets.ui_tool_script_loc(impl, impl_label)
		if overlay_tool_button(icon, tooltip, !cad_active && !scene_2d_ruler_active && gizmo_mode == mode, loc = loc) {
			gizmo_mode = mode
			scene_2d_ruler_active = false
			_ruler_dragging = false
			cad_csg_editor.deactivate_cad_tool()
		}
	}
	mode_button(icons.ICON_MD_ARROW_SELECTOR, "Picker (Q / 1): Select objects in Scene3D (click = select, Ctrl+Click = toggle, drag = box select)", .Picker, vertical, cad_active, #location(scene_view_pick), "Scene Viewport Picking (scene_view_pick)", first = true)
	mode_button(icons.ICON_MD_OPEN_WITH, "Move (W): Translate the selected object.\nIn CAD Mesh Editor: moves the selected vertices / edge / faces (also G).", .Translate, vertical, cad_active, #location(gizmo_tool_frame), "3D Move/Rotate/Scale Gizmo (gizmo_tool_frame)")
	mode_button(icons.ICON_MD_ROTATE_RIGHT, "Rotate (E): Rotate the selected object.\nIn CAD Mesh Editor: rotates the selected vertices / edge / faces around their center.", .Rotate, vertical, cad_active, #location(gizmo_tool_frame), "3D Move/Rotate/Scale Gizmo (gizmo_tool_frame)")
	mode_button(icons.ICON_MD_OPEN_IN_FULL, "Scale (R): Scale the selected object.\nIn CAD Mesh Editor: scales the selected vertices / edge / faces around their center.", .Scale, vertical, cad_active, #location(gizmo_tool_frame), "3D Move/Rotate/Scale Gizmo (gizmo_tool_frame)")
	mode_button(icons.ICON_MD_CROP_FREE + "##handles_tool", "Handles (T): show the selection's own component handles (collider sizes, rect tool, light range...) instead of the transform gizmo", .Handles, vertical, cad_active, #location(gizmo_pass), "Component Scene Handles Pass (gizmo_pass)")

	// Universal 3D & 2D Ruler Tool (M) — lives directly in the Move/Rotate/Scale group in ALL modes!
	// Selecting Ruler unselects Move/Rotate/Scale and CAD tools so clicks measure cleanly without gizmo conflicts.
	if !vertical do im.SameLine()
	widgets.ui_tool_script_loc(#location(_draw_cad_ruler_overlay), "3D Surface, Height & Wall-Clearance Ruler (_draw_cad_ruler_overlay)", _draw_ruler_right_click_settings)
	if overlay_tool_button(icons.ICON_MD_STRAIGHTEN, "3D & 2D Ruler (M) (Right-Click for Mode/Angle Dropdowns & Code): Measure object heights, wall spawn clearance, World X/Y/Z axis-locked distances, and angles (deg/rad/quat)", scene_2d_ruler_active) {
		scene_2d_ruler_active = !scene_2d_ruler_active
		if scene_2d_ruler_active {
			cad_csg_editor.deactivate_cad_tool()
		} else {
			_ruler_dragging = false
			_ruler_has_measurement = false
		}
	}
	if _ruler_has_measurement || len(_ruler_pinned) > 0 {
		if !vertical do im.SameLine(0, 2)
		widgets.ui_tool_script_loc(#location(_draw_cad_ruler_overlay), "3D Ruler Overlay (_draw_cad_ruler_overlay)", _draw_ruler_right_click_settings)
		if overlay_tool_button(icons.ICON_MD_DELETE, "Clear Ruler Measurements (active and pinned)", false, width = OVERLAY_BUTTON_SIZE) {
			_ruler_dragging = false
			_ruler_has_measurement = false
			clear(&_ruler_pinned)
		}
	}

	// Perspective / Orthographic Projection Toggle — moved onto the Tools bar
	if !vertical do im.SameLine(0, 4)
	proj_label: cstring = scene_cam_ortho ? "Ortho" : "Persp"
	if vertical {
		proj_label = scene_cam_ortho ? "Ort" : "Prs"
	}
	widgets.ui_tool_script_loc(#location(scene_render_view), "Scene Camera & Projection (scene_render_view)")
	if overlay_tool_button(proj_label, "Toggle Perspective vs Orthographic Projection", scene_cam_ortho, width = vertical ? OVERLAY_BUTTON_SIZE : 44.0) {
		scene_cam_ortho = !scene_cam_ortho
		update_scene_camera()
	}
}


// View overlay: 2D / 3D toggle buttons + Viewport Controls dropdown (adjustment values).
// The redundant Front/Back/Left/Right/Top/Bottom dropdown was removed because the
// top-right 3D Orientation Gizmo snaps directly to any view side.
@(scene_overlay={id="View", order=50})
draw_view_overlay :: proc(vertical: bool) {
	@(static) cam_popup_pos: im.Vec2

	if overlay_tool_button("2D", "2D planar view (use the top-right 3D Orientation gizmo to snap to Front/Back/Left/Right/Top/Bottom; Wheel moves depth, WASD/MMB/RMB pans)", scene_2d_mode, width = vertical ? OVERLAY_BUTTON_SIZE : 28.0) {
		scene_set_2d(!scene_2d_mode)
	}

	if !vertical do im.SameLine(0, 2)
	if overlay_tool_button("3D", "3D free camera view (RMB + WASDQE fly, Alt+LMB orbit, MMB pan)", !scene_2d_mode, width = vertical ? OVERLAY_BUTTON_SIZE : 28.0) {
		scene_set_2d(false)
	}

	light_mode := engine.render_effective_scene_lighting_mode()
	if !vertical do im.SameLine(0, 4)
	if overlay_tool_button("Lit", "Real-time Lit view (0 lights = true pitch black, 16-tile GPU shadow atlas)", light_mode == .Lit, width = vertical ? OVERLAY_BUTTON_SIZE : 28.0) {
		engine.render_set_scene_lighting_mode(.Lit)
	}

	if !vertical do im.SameLine(0, 2)
	if overlay_tool_button("Unlit", "Scene-view Unlit inspection mode (flat full-bright lighting, Game View stays true Lit)", light_mode == .Unlit, width = vertical ? OVERLAY_BUTTON_SIZE : 38.0) {
		engine.render_set_scene_lighting_mode(.Unlit)
	}

	if !vertical do im.SameLine(0, 2)
	if overlay_tool_button("FakeLight", "Scene-view Studio FakeLight (angled directional light with real 3-cascade CSM shadows even with 0 scene Lights; Game View stays true Lit)", light_mode == .FakeLight, width = vertical ? OVERLAY_BUTTON_SIZE : 62.0) {
		engine.render_set_scene_lighting_mode(.FakeLight)
	}

	// Viewport Controls Dropdown (adjustment values: FOV, Fly Speed, Snappiness, Sensitivity, 2D Depth Step)
	if !vertical do im.SameLine(0, 4)
	if overlay_tool_button(icons.ICON_MD_TUNE, "Viewport Controls (FOV, Fly Speed, Snappiness, Rotation Sensitivity, Depth Step)", false) {
		cam_popup_pos = {im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
		im.OpenPopup("##cam_nav_settings")
	}
	im.SetNextWindowPos(cam_popup_pos, .Appearing)
	if im.BeginPopup("##cam_nav_settings") {
		@(static) editing_speed: bool
		@(static) focus_speed_input: bool
		@(static) was_dragging_speed: bool
		@(static) pre_drag_speed: f32
		@(static) speed_edit_val: f32

		if im.IsWindowAppearing() {
			editing_speed = false
			focus_speed_input = false
			was_dragging_speed = false
		}

		im.SeparatorText("Camera & Viewport Controls")

		im.Text("Field of View (FOV):")
		im.SetNextItemWidth(160)
		if im.SliderFloat("##CamFOV", &scene_cam_fov_deg, 10.0, 110.0, "%.0f deg") {
			scene_cam_fov_deg = clamp(scene_cam_fov_deg, 10.0, 110.0)
			update_scene_camera()
		}
		widgets.tooltip("Viewport camera vertical Field of View in degrees (default: 45 deg)")

		if im.Checkbox("Orthographic Projection", &scene_cam_ortho) {
			update_scene_camera()
		}
		widgets.tooltip("Toggle flat parallel Orthographic Projection (also available as the Persp/Ortho button on the Tools bar)")

		if scene_cam_ortho {
			im.Text("Ortho View Size:")
			im.SetNextItemWidth(160)
			if im.DragFloat("##OrthoSize", &scene_cam_dist, 0.05, CAM_MIN_DIST, 1000.0, "%.2f m", {.Logarithmic}) {
				scene_cam_dist = clamp(scene_cam_dist, CAM_MIN_DIST, 1000.0)
				update_scene_camera()
			}
			widgets.tooltip("Orthographic frustum scale (Ctrl + Mouse Wheel in Ortho mode also scales this without affecting depth slicing)")
		}

		im.Separator()

		im.Text("Move / Fly Speed:")
		im.SetNextItemWidth(160)
		if !editing_speed {
			v_drag := scene_fly_speed
			drag_step := max(scene_fly_speed * 0.015, 0.001)
			changed := im.DragFloat("##CamSpeed", &v_drag, drag_step, FLYTHROUGH_MIN_SPEED, FLYTHROUGH_MAX_SPEED, "%.3f", {.Logarithmic})
			widgets.tooltip("Scene camera fly speed in m/s (RMB + WASD). Drag or double-click to type; mouse wheel while flying also changes it")
			if im.IsItemActivated() {
				was_dragging_speed = false
				pre_drag_speed = scene_fly_speed
			}
			if im.IsItemActive() && im.IsMouseDragging(.Left, 2.0) {
				was_dragging_speed = true
			}
			if changed && was_dragging_speed {
				scene_fly_speed = clamp(v_drag, FLYTHROUGH_MIN_SPEED, FLYTHROUGH_MAX_SPEED)
				_fly_speed_cur = scene_fly_speed
			}
			if im.IsItemDeactivated() && !was_dragging_speed {
				scene_fly_speed = pre_drag_speed
				_fly_speed_cur = pre_drag_speed
				speed_edit_val = pre_drag_speed
				editing_speed = true
				focus_speed_input = true
			}
			widgets.tooltip("Click to type an exact speed, or drag left/right to scrub smoothly (min: 0.005)")
		} else {
			just_focused := focus_speed_input
			if focus_speed_input {
				im.SetKeyboardFocusHere(0)
				focus_speed_input = false
			}
			submitted := im.InputFloat("##CamSpeedEdit", &speed_edit_val, 0, 0, "%.3f", {.EnterReturnsTrue, .AutoSelectAll})
			if im.IsKeyPressed(.Escape) {
				editing_speed = false
			} else if submitted || (!just_focused && !im.IsItemActive()) {
				scene_fly_speed = clamp(speed_edit_val, FLYTHROUGH_MIN_SPEED, FLYTHROUGH_MAX_SPEED)
				_fly_speed_cur = scene_fly_speed
				editing_speed = false
			}
		}

		im.Spacing()
		im.Text("Fly Stop Snappiness:")
		snappiness: f32 = clamp(1.0 - (scene_fly_move_smooth_tau / 0.15), 0.0, 1.0)
		im.SetNextItemWidth(160)
		if im.SliderFloat("##StopSnappiness", &snappiness, 0.0, 1.0, snappiness >= 0.95 ? "Instant Stop" : "%.2f") {
			scene_fly_move_smooth_tau = (1.0 - snappiness) * 0.15
		}
		widgets.tooltip("Controls how quickly the camera stops when releasing RMB/keys (1.0 = instant stop, no drift)")

		im.Spacing()
		im.Text("Rotation Sensitivity:")
		sens_display := scene_look_sensitivity * 1000.0
		im.SetNextItemWidth(160)
		if im.SliderFloat("##RotSensitivity", &sens_display, 1.0, 15.0, "%.1f") {
			scene_look_sensitivity = sens_display / 1000.0
		}
		widgets.tooltip("Adjust mouse look & orbit rotation sensitivity (lower = gentle/fine, higher = fast)")

		im.Spacing()
		im.Text("2D Wheel Depth Step:")
		im.SetNextItemWidth(160)
		if im.DragFloat("##2dWheelStep", &scene_2d_wheel_step, 0.05, 0.01, 100.0, "%.2f m", {.Logarithmic}) {
			scene_2d_wheel_step = clamp(scene_2d_wheel_step, 0.01, 100.0)
		}
		widgets.tooltip("Distance moved forward/backward along the 2D view axis per Mouse Wheel notch")

		im.Spacing()
		if im.Button("Reset Defaults", {-1, 22}) {
			scene_cam_fov_deg = SCENE_CAM_FOV_DEG
			scene_cam_ortho = false
			scene_fly_speed = FLYTHROUGH_BASE_SPEED
			_fly_speed_cur = FLYTHROUGH_BASE_SPEED
			scene_fly_move_smooth_tau = 0.08
			scene_look_sensitivity = 0.005
			scene_2d_wheel_step = 0.25
			editing_speed = false
			update_scene_camera()
		}
		widgets.tooltip("Reset camera FOV, projection, fly speed, smoothing, look sensitivity and 2D wheel step to their defaults")
		im.EndPopup()
	}
}

// Determine the active ruler axis basis & labels:
// - In 2D planar views: exact 2D planar axes ("dX"/"dY", "dZ"/"dY", "dX"/"dZ").
// - In 3D views: true World Horizontal ("dXZ (Horiz)") and World Vertical ("dY (Height)")
//   so camera pitch/tilt NEVER distorts vertical height or horizontal distance!
@(private = "file")
_ruler_basis_for_segment :: proc(start_pt, end_pt: [3]f32) -> (axis_r, axis_u: [3]f32, label_h, label_v: cstring) {
	if scene_2d_mode {
		_, r, u := _scene_cam_basis()
		switch scene_2d_angle {
		case .Front, .Back:   return r, u, "dX", "dY"
		case .Right, .Left:   return r, u, "dZ", "dY"
		case .Top, .Bottom:   return r, u, "dX", "dZ"
		}
	}
	diff := end_pt - start_pt
	horiz := [3]f32{diff.x, 0, diff.z}
	hlen := linalg.length(horiz)
	if hlen > 0.0005 {
		axis_r = horiz / hlen
	} else {
		_, r, _ := _scene_cam_basis()
		rh := [3]f32{r.x, 0, r.z}
		axis_r = linalg.length(rh) > 0.001 ? linalg.normalize(rh) : [3]f32{1, 0, 0}
	}
	axis_u  = {0, 1, 0}
	label_h = "dXZ (Horiz)"
	label_v = "dY (Height)"
	return
}

// Compute the world-space AABB (min, max) of a scene object (MeshFilter, SkinnedMeshRenderer, or CSGVolume).
@(private = "file")
_ruler_object_world_aabb :: proc(tH: engine.Transform_Handle) -> (lo, hi: [3]f32, ok: bool) {
	w := engine.ctx_world()
	if w == nil || tH == {} || !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return {}, {}, false
	tw := engine.transform_world(tH)
	if slo, shi, sok := _skinned_world_aabb(tH); sok {
		return slo, shi, true
	}
	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	if mf != nil && mf.mesh != {} {
		if mesh, mok := engine.mesh_load_filter(mf); mok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			mlo, mhi := mesh.aabb_min, mesh.aabb_max
			for i in 0 ..< 8 {
				local := [4]f32{
					i & 1 == 0 ? mlo.x : mhi.x,
					i & 2 == 0 ? mlo.y : mhi.y,
					i & 4 == 0 ? mlo.z : mhi.z,
					1,
				}
				p := (model * local).xyz
				lo = i == 0 ? p : linalg.min(lo, p)
				hi = i == 0 ? p : linalg.max(hi, p)
			}
			return lo, hi, true
		}
	}
	// Fallback: check CSGVolume or general object bounds
	if blo, bhi, bok := cad_csg_editor.get_object_world_aabb_for_ruler(tH); bok {
		return blo, bhi, true
	}
	return tw.position - {0.5, 0.5, 0.5}, tw.position + {0.5, 0.5, 0.5}, false
}

// Raycast any 3D ray against all scene meshes, CSG volumes (via pick providers), and optionally the Y=0 ground plane.
@(private = "file")
_ruler_raycast_ray :: proc(view: engine.Render_View, ray: engine.Ray, include_ground := true, ignore_floor_slab := false) -> (hit_pos: [3]f32, hit_t: f32, hit_tH: engine.Transform_Handle, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return {}, 0, {}, false
	best_t: f32 = 1e30

	// 1. Test all MeshRenderers (exact triangle intersection when CPU bind vertices exist, else local AABB)
	mr_it := engine.pool_iterator(engine.mesh_renderers(w))
	for mr, _ in engine.pool_next(&mr_it) {
		if !mr.enabled || !engine.transform_active_in_hierarchy(mr.owner) do continue
		owner_h := engine.Transform_Handle(mr.owner)
		_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
		if mf == nil || mf.mesh == {} do continue
		mesh, mok := engine.mesh_load_filter(mf)
		if !mok do continue

		tw := engine.transform_world(owner_h)
		inv := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		local_o := inv * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
		local_d := inv * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}
		local_ray := engine.Ray{origin = local_o.xyz, direction = local_d.xyz}

		if t_aabb, hit := engine.ray_hit_aabb(local_ray, mesh.aabb_min, mesh.aabb_max); hit && t_aabb >= 0 {
			if len(mesh.bind_indices) >= 3 && len(mesh.joint_names) == 0 {
				tri_count := len(mesh.bind_indices) / 3
				for ti in 0 ..< tri_count {
					i0 := mesh.bind_indices[ti * 3 + 0]
					i1 := mesh.bind_indices[ti * 3 + 1]
					i2 := mesh.bind_indices[ti * 3 + 2]
					if int(i0) < len(mesh.bind_vertices) && int(i1) < len(mesh.bind_vertices) && int(i2) < len(mesh.bind_vertices) {
						v0 := mesh.bind_vertices[i0].position
						v1 := mesh.bind_vertices[i1].position
						v2 := mesh.bind_vertices[i2].position
						if tt, th := engine.ray_hit_triangle(local_ray, v0, v1, v2); th && tt > 0.001 && tt < best_t {
							best_t = tt
							hit_tH = owner_h
							ok = true
						}
					}
				}
			} else if t_aabb > 0.001 && t_aabb < best_t {
				best_t = t_aabb
				hit_tH = owner_h
				ok = true
			}
		}
	}

	// 2. Test SkinnedMeshRenderers
	smr_it := engine.pool_iterator(engine.skinned_mesh_renderers(w))
	for smr, _ in engine.pool_next(&smr_it) {
		if !smr.enabled || !engine.transform_active_in_hierarchy(smr.owner) do continue
		lo, hi, sok := engine.skinned_mesh_world_bounds(smr)
		if !sok do continue
		if t_skin, hit := engine.ray_hit_aabb(ray, lo, hi); hit && t_skin > 0.001 && t_skin < best_t {
			best_t = t_skin
			hit_tH = engine.Transform_Handle(smr.owner)
			ok = true
		}
	}

	// 3. Test package pick providers (CSGVolume brushes & chunks!)
	for provider in handles.pick_providers() {
		if tH, t_prov, pok := provider.click(view, ray); pok && t_prov > 0.001 && t_prov < best_t {
			p_cand := ray.origin + ray.direction * t_prov
			if ignore_floor_slab && abs(p_cand.y) < 0.08 do continue
			best_t = t_prov
			hit_tH = tH
			ok = true
		}
	}

	// 4. Test Ground Plane (Y = 0)
	if include_ground && abs(ray.direction.y) > 0.0005 {
		t_ground := -ray.origin.y / ray.direction.y
		if t_ground > 0.01 && t_ground < best_t && t_ground < 500.0 {
			best_t = t_ground
			hit_tH = {}
			ok = true
		}
	}

	if ok {
		hit_pos = ray.origin + ray.direction * best_t
		hit_t   = best_t
	}
	return
}

// Project a camera screen ray onto a 3D line passing through `origin` along `axis_dir` (unit vector).
// This makes vertical height (World Y) and horizontal axis (World X / Z) measurements 100% immune to camera tilt!
@(private = "file")
_ruler_project_ray_to_axis :: proc(ray: engine.Ray, origin: [3]f32, axis_dir: [3]f32) -> [3]f32 {
	w0 := origin - ray.origin
	b  := linalg.dot(axis_dir, ray.direction)
	c  := linalg.dot(axis_dir, w0)
	f  := linalg.dot(ray.direction, w0)
	denom := 1.0 - b * b
	if abs(denom) < 1e-4 do return origin
	s := (b * f - c) / denom
	return origin + axis_dir * s
}

// Compute wall/obstacle clearance along the measurement direction and safe spawn radius around `start_pt`.
@(private = "file")
_ruler_update_wall_clearance :: proc(view: engine.Render_View, start_pt, end_pt: [3]f32) {
	_ruler_wall_hit_valid = false
	_ruler_wall_dist      = 0
	_ruler_wall_tH        = {}
	_ruler_safe_spawn_rad = 0

	probe_y := max(start_pt.y + 0.35, 0.35)
	probe_origin := [3]f32{start_pt.x, probe_y, start_pt.z}

	// 1. Raycast along horizontal measurement direction (or camera forward horizontal if start == end)
	diff_xz := [3]f32{end_pt.x - start_pt.x, 0, end_pt.z - start_pt.z}
	dir_xz: [3]f32
	if linalg.length(diff_xz) > 0.02 {
		dir_xz = linalg.normalize(diff_xz)
	} else {
		fwd, _, _ := _scene_cam_basis()
		fh := [3]f32{fwd.x, 0, fwd.z}
		dir_xz = linalg.length(fh) > 0.001 ? linalg.normalize(fh) : [3]f32{0, 0, -1}
	}

	if wpos, wt, wtH, wok := _ruler_raycast_ray(view, engine.Ray{origin = probe_origin, direction = dir_xz}, include_ground = false, ignore_floor_slab = true); wok && wt < 200.0 {
		_ruler_wall_hit_valid = true
		_ruler_wall_hit_pos   = {wpos.x, start_pt.y, wpos.z}
		_ruler_wall_dist      = wt
		_ruler_wall_tH        = wtH
	}

	// 2. Safe spawn radius: minimum obstacle distance across 8 horizontal compass directions
	min_clear: f32 = _ruler_wall_hit_valid ? _ruler_wall_dist : 999.0
	compass_dirs := [8][3]f32{
		{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
		{0.7071, 0, 0.7071}, {-0.7071, 0, 0.7071}, {0.7071, 0, -0.7071}, {-0.7071, 0, -0.7071},
	}
	for cd in compass_dirs {
		if _, ct, _, cok := _ruler_raycast_ray(view, engine.Ray{origin = probe_origin, direction = cd}, include_ground = false, ignore_floor_slab = true); cok {
			if ct < min_clear do min_clear = ct
		}
	}
	if min_clear < 500.0 {
		_ruler_safe_spawn_rad = min_clear
	}
}

// Convert a screen-space pixel position (inside the scene image) to 3D world space for the Ruler:
// - In 2D mode: projects onto the active 2D workplane.
// - In 3D mode: raycasts against scene meshes, CSG surfaces, and the ground plane (or projects onto
//   the locked World X / Y / Z axis when dragging with an axis lock or in Vertical Height mode!).
@(private = "file")
_2d_screen_to_world_plane :: proc(screen_pos: im.Vec2, snap: bool, is_end_point := false) -> [3]f32 {
	if scene_rt == nil do return {}
	view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
	ray := engine.render_view_screen_ray(view, screen_pos.x - _scene_img_min.x, screen_pos.y - _scene_img_min.y)

	if !scene_2d_mode {
		// If dragging the end point with an active World Axis Lock (or in Vertical_Height mode),
		// project the cursor ray directly onto that World Axis through `_ruler_start_world`!
		eff_lock := _ruler_axis_lock
		if eff_lock == .None && _ruler_mode == .Vertical_Height {
			eff_lock = .World_Y
		}
		if is_end_point && eff_lock != .None {
			axis_vec: [3]f32
			switch eff_lock {
			case .None:    axis_vec = {0, 1, 0}
			case .World_X: axis_vec = {1, 0, 0}
			case .World_Y: axis_vec = {0, 1, 0}
			case .World_Z: axis_vec = {0, 0, 1}
			}
			pt := _ruler_project_ray_to_axis(ray, _ruler_start_world, axis_vec)
			if snap {
				step := max(snap_translate_step(), 0.01)
				d := math.round(linalg.dot(pt - _ruler_start_world, axis_vec) / step) * step
				pt = _ruler_start_world + axis_vec * d
			}
			return pt
		}

		// Raycast 3D scene surfaces (Meshes, CSG Volumes, and Ground Plane Y=0)
		if hit_p, _, _, ok := _ruler_raycast_ray(view, ray, include_ground = true); ok {
			pt := hit_p
			if snap {
				step := max(snap_translate_step(), 0.01)
				pt.x = math.round(pt.x / step) * step
				pt.y = math.round(pt.y / step) * step
				pt.z = math.round(pt.z / step) * step
			}
			return pt
		}
	}

	fwd, r, u := _scene_cam_basis()
	origin := [3]f32{0, 0, 0}
	w := engine.ctx_world()
	for h in sel_scene_items() {
		if engine.pool_valid(&w.transforms, engine.Handle(h)) {
			origin = engine.transform_world(h).position
			break
		}
	}

	denom := linalg.dot(ray.direction, fwd)
	pt := ray.origin
	if abs(denom) > 0.0001 {
		t := linalg.dot(origin - ray.origin, fwd) / denom
		pt = ray.origin + ray.direction * t
	}
	if snap {
		step := snap_translate_step()
		rel := pt - origin
		rx := math.round(linalg.dot(rel, r) / step) * step
		ry := math.round(linalg.dot(rel, u) / step) * step
		rz := linalg.dot(rel, fwd)
		pt = origin + r * rx + u * ry + fwd * rz
	}
	return pt
}

// Helper to draw a framed CAD measurement pill badge at screen position `center`.
_draw_ruler_badge :: proc(dl: ^im.DrawList, center: im.Vec2, txt: cstring, border_col, text_col: u32, alpha: f32 = 1.0) {
	ts := im.CalcTextSize(txt)
	bmin := center - ts * 0.5 - {6, 3}
	bmax := center + ts * 0.5 + {6, 3}
	im.DrawList_AddRectFilled(dl, bmin, bmax, im.GetColorU32ImVec4({0.07, 0.08, 0.11, 0.92 * alpha}), 4.0)
	im.DrawList_AddRect(dl, bmin, bmax, border_col, 4.0)
	im.DrawList_AddText(dl, center - ts * 0.5, text_col, txt)
}

// Format angle according to `_ruler_angle_unit` (`Degrees`, `Radians`, or `Quaternion`).
@(private = "file")
_ruler_format_hypotenuse_badge :: proc(dist: f32, dh, dv: f32, diff: [3]f32) -> cstring {
	angle_rad := math.atan2(dv, dh)
	angle_deg := math.to_degrees(angle_rad)
	comp_deg  := 90.0 - abs(angle_deg)
	switch _ruler_angle_unit {
	case .Degrees:
		return fmt.ctprintf("%.3f m  (%.1f deg / %.1f deg)", dist, abs(angle_deg), comp_deg)
	case .Radians:
		comp_rad := (math.PI * 0.5) - abs(angle_rad)
		return fmt.ctprintf("%.3f m  (%.3f rad / %.3f rad | %.2f pi)", dist, abs(angle_rad), comp_rad, abs(angle_rad) / math.PI)
	case .Quaternion:
		// Compute rotation quaternion from reference horizontal axis +Z (or +X) to `normalize0(diff)`
		d_norm := linalg.normalize0(diff)
		ref_v  := abs(d_norm.z) < 0.99 ? [3]f32{0, 0, 1} : [3]f32{1, 0, 0}
		cr     := linalg.cross(ref_v, d_norm)
		dt_v   := linalg.dot(ref_v, d_norm)
		qw     := 1.0 + dt_v
		q_len  := math.sqrt(cr.x * cr.x + cr.y * cr.y + cr.z * cr.z + qw * qw)
		if q_len > 1e-5 {
			return fmt.ctprintf("%.3f m  Quat(%.2f, %.2f, %.2f, %.2f)", dist, cr.x / q_len, cr.y / q_len, cr.z / q_len, qw / q_len)
		}
		return fmt.ctprintf("%.3f m  Quat(0.00, 0.00, 0.00, 1.00)", dist)
	}
	return fmt.ctprintf("%.3f m", dist)
}

// Draws one complete 3-sided AutoCAD right-triangle dimension measurement:
// - Side 1 (Hypotenuse P0 -> P1, Gold): distance + angle badge (deg/rad/quat), end ticks, angle arc at P0
// - Side 2 (Horizontal Leg P0 -> Pc, Red/Coral): dedicated horizontal measurement badge + ticks
// - Side 3 (Vertical Leg Pc -> P1, Green/Emerald): dedicated vertical height measurement badge + ticks
// - Optional Wall/Obstacle Clearance laser ray + Safe Spawn Radius readout
@(private = "file")
_draw_single_ruler_triangle :: proc(dl: ^im.DrawList, img_min: im.Vec2, m: Ruler_Measurement, is_pinned: bool) {
	p0_rel, ok0 := gizmos.helper_project_in(_scene_view_last, m.start_world)
	p1_rel, ok1 := gizmos.helper_project_in(_scene_view_last, m.end_world)
	if !ok0 || !ok1 do return

	p0 := img_min + p0_rel
	p1 := img_min + p1_rel
	diff := m.end_world - m.start_world
	dh := linalg.dot(diff, m.axis_r)
	dv := linalg.dot(diff, m.axis_u)
	dist := linalg.length(diff)

	corner_world := m.start_world + m.axis_r * dh
	pc_rel, okc := gizmos.helper_project_in(_scene_view_last, corner_world)
	pc := img_min + pc_rel

	alpha: f32 = is_pinned ? 0.85 : 1.0
	col_shadow := im.GetColorU32ImVec4({0.0, 0.0, 0.0, 0.85 * alpha})
	col_main   := im.GetColorU32ImVec4({1.0, 0.85, 0.20, alpha})
	col_h      := im.GetColorU32ImVec4({0.98, 0.42, 0.38, alpha})
	col_v      := im.GetColorU32ImVec4({0.35, 0.92, 0.50, alpha})
	col_arc    := im.GetColorU32ImVec4({0.55, 0.82, 1.0, 0.85 * alpha})
	col_coord  := im.GetColorU32ImVec4({0.78, 0.84, 0.92, 0.85 * alpha})
	col_wall   := im.GetColorU32ImVec4({0.25, 0.95, 0.92, 0.90 * alpha})

	// Draw Wall / Obstacle Clearance Line if valid in Surface_Clearance mode
	if m.wall_valid && _ruler_mode == .Surface_Clearance {
		pw_rel, okw := gizmos.helper_project_in(_scene_view_last, m.wall_pos)
		if okw {
			pw := img_min + pw_rel
			im.DrawList_AddLine(dl, p0, pw, col_shadow, 3.0)
			im.DrawList_AddLine(dl, p0, pw, col_wall, 1.8)
			im.DrawList_AddCircleFilled(dl, pw, 4.5, col_wall)
			mid_w := (p0 + pw) * 0.5 + {0, -18}
			w_txt := fmt.ctprintf("To Wall: %.2f m  |  Safe Spawn R: %.2f m", m.wall_dist, m.safe_rad)
			_draw_ruler_badge(dl, mid_w, w_txt, col_wall, im.GetColorU32ImVec4({0.75, 1.0, 0.98, alpha}), alpha)
		}
	}

	has_legs := okc && abs(dh) > 0.0005 && abs(dv) > 0.0005
	tri_centroid := (p0 + p1 + pc) / 3.0

	if has_legs {
		// 1. Draw Horizontal Leg (Side 2: P0 -> Pc) and Vertical Leg (Side 3: Pc -> P1)
		im.DrawList_AddLine(dl, p0, pc, col_shadow, 3.5)
		im.DrawList_AddLine(dl, pc, p1, col_shadow, 3.5)
		im.DrawList_AddLine(dl, p0, pc, col_h, 2.0)
		im.DrawList_AddLine(dl, pc, p1, col_v, 2.0)

		// Right-angle square symbol (∟) at the 90-degree corner Pc
		vec_h := p0 - pc
		vec_v := p1 - pc
		len_h := linalg.length(vec_h)
		len_v := linalg.length(vec_v)
		if len_h > 18.0 && len_v > 18.0 {
			uh := vec_h / len_h
			uv := vec_v / len_v
			sq_sz: f32 = min(10.0, min(len_h, len_v) * 0.25)
			c_h := pc + uh * sq_sz
			c_v := pc + uv * sq_sz
			c_hv := pc + uh * sq_sz + uv * sq_sz
			im.DrawList_AddLine(dl, c_h, c_hv, im.GetColorU32ImVec4({0.9, 0.95, 1.0, 0.8 * alpha}), 1.5)
			im.DrawList_AddLine(dl, c_v, c_hv, im.GetColorU32ImVec4({0.9, 0.95, 1.0, 0.8 * alpha}), 1.5)
		}

		// Angle arc at P0 between Horizontal Leg (P0 -> Pc) and Hypotenuse (P0 -> P1)
		dir_h := pc - p0
		dir_hyp := p1 - p0
		lh := linalg.length(dir_h)
		lhyp := linalg.length(dir_hyp)
		if lh > 36.0 && lhyp > 36.0 {
			ang0 := math.atan2(dir_h.y, dir_h.x)
			ang1 := math.atan2(dir_hyp.y, dir_hyp.x)
			diff_ang := ang1 - ang0
			for diff_ang > math.PI do diff_ang -= 2 * math.PI
			for diff_ang < -math.PI do diff_ang += 2 * math.PI
			arc_r: f32 = min(28.0, min(lh, lhyp) * 0.35)
			SEGMENTS :: 12
			prev_pt := p0 + im.Vec2{math.cos(ang0), math.sin(ang0)} * arc_r
			for s in 1 ..= SEGMENTS {
				t := f32(s) / f32(SEGMENTS)
				a := ang0 + diff_ang * t
				cur_pt := p0 + im.Vec2{math.cos(a), math.sin(a)} * arc_r
				im.DrawList_AddLine(dl, prev_pt, cur_pt, col_arc, 1.5)
				prev_pt = cur_pt
			}
		}

		// Side 2 Badge: Horizontal Leg Measurement (centered on P0 -> Pc, pushed outward from triangle centroid)
		mid_h := (p0 + pc) * 0.5
		out_h := mid_h - tri_centroid
		out_h_len := linalg.length(out_h)
		off_h := out_h_len > 0.001 ? (out_h / out_h_len) * 16.0 : im.Vec2{0, 16}
		txt_h := fmt.ctprintf("%s: %.3f m", m.label_h, abs(dh))
		_draw_ruler_badge(dl, mid_h + off_h, txt_h, col_h, im.GetColorU32ImVec4({1.0, 0.82, 0.80, alpha}), alpha)

		// Side 3 Badge: Vertical Leg Measurement (centered on Pc -> P1, pushed outward from triangle centroid)
		mid_v := (pc + p1) * 0.5
		out_v := mid_v - tri_centroid
		out_v_len := linalg.length(out_v)
		off_v := out_v_len > 0.001 ? (out_v / out_v_len) * 22.0 : im.Vec2{22, 0}
		txt_v := fmt.ctprintf("%s: %.3f m", m.label_v, abs(dv))
		_draw_ruler_badge(dl, mid_v + off_v, txt_v, col_v, im.GetColorU32ImVec4({0.80, 1.0, 0.85, alpha}), alpha)

		im.DrawList_AddCircleFilled(dl, pc, 3.5, im.GetColorU32ImVec4({0.95, 0.95, 1.0, alpha}))
	}

	// 2. Main Hypotenuse Dimension Line (Side 1: P0 -> P1) with perpendicular CAD end ticks
	im.DrawList_AddLine(dl, p0, p1, col_shadow, 4.0)
	im.DrawList_AddLine(dl, p0, p1, col_main, 2.2)
	screen_dir := p1 - p0
	slen := linalg.length(screen_dir)
	perp := im.Vec2{0, -1}
	if slen > 1.0 {
		perp = im.Vec2{-screen_dir.y / slen, screen_dir.x / slen}
		tick := perp * 7.5
		im.DrawList_AddLine(dl, p0 - tick, p0 + tick, col_shadow, 3.5)
		im.DrawList_AddLine(dl, p1 - tick, p1 + tick, col_shadow, 3.5)
		im.DrawList_AddLine(dl, p0 - tick, p0 + tick, col_main, 2.0)
		im.DrawList_AddLine(dl, p1 - tick, p1 + tick, col_main, 2.0)
	}
	im.DrawList_AddCircleFilled(dl, p0, 4.5, col_main)
	im.DrawList_AddCircleFilled(dl, p1, 4.5, col_main)

	// Side 1 Badge: Hypotenuse Total Distance + Angles (deg / rad / quat)
	mid_hyp := (p0 + p1) * 0.5
	out_hyp := perp
	if has_legs && linalg.dot(mid_hyp + perp * 10.0 - pc, mid_hyp - pc) < linalg.dot(mid_hyp - perp * 10.0 - pc, mid_hyp - pc) {
		out_hyp = -perp
	}
	txt_hyp := _ruler_format_hypotenuse_badge(dist, dh, dv, diff)
	_draw_ruler_badge(dl, mid_hyp + out_hyp * 20.0, txt_hyp, col_main, im.GetColorU32ImVec4({1.0, 0.95, 0.75, alpha}), alpha)

	// Start/End world coordinate tags when sufficiently separated on screen
	if slen > 55.0 && !is_pinned {
		c0_txt := fmt.ctprintf("(%.2f, %.2f, %.2f)", m.start_world.x, m.start_world.y, m.start_world.z)
		c1_txt := fmt.ctprintf("(%.2f, %.2f, %.2f)", m.end_world.x, m.end_world.y, m.end_world.z)
		im.DrawList_AddText(dl, p0 + {8, 6}, col_coord, c0_txt)
		im.DrawList_AddText(dl, p1 + {8, 6}, col_coord, c1_txt)
	}
}

// Draws all pinned AutoCAD Ruler measurements, the live 3D surface crosshair & object height bracket,
// the active measurement, and the Ruler Mode / Angle / Axis control bar.
@(private = "file")
_draw_cad_ruler_overlay :: proc(dl: ^im.DrawList, img_min, img_max: im.Vec2) {
	// 1. Draw pinned measurements
	for pm in _ruler_pinned {
		_draw_single_ruler_triangle(dl, img_min, pm, true)
	}

	// 2. When Ruler is active in 3D, draw live 3D surface crosshair, plumb line to floor, and hovered object WxHxD height bracket!
	if scene_2d_ruler_active && _ruler_hover_valid && !scene_2d_mode {
		ph_rel, ok_h := gizmos.helper_project_in(_scene_view_last, _ruler_hover_world)
		if ok_h {
			ph := img_min + ph_rel
			col_cross := im.GetColorU32ImVec4({0.30, 0.95, 1.0, 0.92})
			im.DrawList_AddCircle(dl, ph, 7.0, col_cross, 16, 1.8)
			im.DrawList_AddLine(dl, ph - {11, 0}, ph + {11, 0}, col_cross, 1.5)
			im.DrawList_AddLine(dl, ph - {0, 11}, ph + {0, 11}, col_cross, 1.5)

			// Plumb line down to Y=0 floor if hovering above floor
			if abs(_ruler_hover_world.y) > 0.05 {
				floor_pt := [3]f32{_ruler_hover_world.x, 0, _ruler_hover_world.z}
				if pf_rel, ok_f := gizmos.helper_project_in(_scene_view_last, floor_pt); ok_f {
					pf := img_min + pf_rel
					im.DrawList_AddLine(dl, ph, pf, im.GetColorU32ImVec4({0.35, 0.92, 0.50, 0.70}), 1.5)
					im.DrawList_AddCircleFilled(dl, pf, 3.5, im.GetColorU32ImVec4({0.35, 0.92, 0.50, 0.90}))
				}
			}

			// If hovering a scene mesh/CSG object, draw its vertical height bracket + WxHxD badge!
			w := engine.ctx_world()
			obj_name: string = "Ground Plane (Y=0)"
			has_box := false
			box_sz: [3]f32
			if _ruler_hover_tH != {} && w != nil && engine.pool_valid(&w.transforms, engine.Handle(_ruler_hover_tH)) {
				if t := engine.pool_get(&w.transforms, engine.Handle(_ruler_hover_tH)); t != nil && len(t.name) > 0 {
					obj_name = t.name
				}
				if lo, hi, bok := _ruler_object_world_aabb(_ruler_hover_tH); bok {
					has_box = true
					box_sz = hi - lo
					// Draw vertical height ruler bracket along the side of the hovered object!
					bot_corner := [3]f32{hi.x + 0.15, lo.y, (lo.z + hi.z) * 0.5}
					top_corner := [3]f32{hi.x + 0.15, hi.y, (lo.z + hi.z) * 0.5}
					pb_rel, ok_b := gizmos.helper_project_in(_scene_view_last, bot_corner)
					pt_rel, ok_t := gizmos.helper_project_in(_scene_view_last, top_corner)
					if ok_b && ok_t {
						pb := img_min + pb_rel
						pt := img_min + pt_rel
						col_hb := im.GetColorU32ImVec4({0.35, 0.98, 0.55, 0.95})
						im.DrawList_AddLine(dl, pb, pt, col_hb, 2.2)
						im.DrawList_AddLine(dl, pb - {6, 0}, pb + {6, 0}, col_hb, 2.0)
						im.DrawList_AddLine(dl, pt - {6, 0}, pt + {6, 0}, col_hb, 2.0)
						hb_txt := fmt.ctprintf("%s Height: %.2f m (W:%.2f x H:%.2f x D:%.2f)", obj_name, box_sz.y, box_sz.x, box_sz.y, box_sz.z)
						_draw_ruler_badge(dl, (pb + pt) * 0.5 + {0, -14}, hb_txt, col_hb, im.GetColorU32ImVec4({0.85, 1.0, 0.88, 1.0}))
					}
				}
			}

			if !_ruler_dragging {
				cursor_txt: cstring
				if has_box {
					cursor_txt = fmt.ctprintf("[%s] Pos:(%.2f, %.2f, %.2f) | H:%.2fm | Safe Spawn R:%.2fm", obj_name, _ruler_hover_world.x, _ruler_hover_world.y, _ruler_hover_world.z, box_sz.y, _ruler_safe_spawn_rad)
				} else if _ruler_wall_hit_valid {
					cursor_txt = fmt.ctprintf("Pos:(%.2f, %.2f, %.2f) | Wall Clearance: %.2f m (Safe R: %.2f m)", _ruler_hover_world.x, _ruler_hover_world.y, _ruler_hover_world.z, _ruler_wall_dist, _ruler_safe_spawn_rad)
				} else {
					cursor_txt = fmt.ctprintf("Pos:(%.2f, %.2f, %.2f) | Elev Y: %.2f m", _ruler_hover_world.x, _ruler_hover_world.y, _ruler_hover_world.z, _ruler_hover_world.y)
				}
				_draw_ruler_badge(dl, ph + {0, 22}, cursor_txt, col_cross, im.GetColorU32ImVec4({0.88, 0.98, 1.0, 1.0}))
			}
		}
	}

	// 3. Draw current active measurement
	r, u, lh, lv := _ruler_basis_for_segment(_ruler_start_world, _ruler_end_world)
	if _ruler_has_measurement || _ruler_dragging {
		cur := Ruler_Measurement{
			start_world = _ruler_start_world,
			end_world   = _ruler_end_world,
			axis_r      = r,
			axis_u      = u,
			label_h     = lh,
			label_v     = lv,
			wall_valid  = _ruler_wall_hit_valid,
			wall_pos    = _ruler_wall_hit_pos,
			wall_dist   = _ruler_wall_dist,
			safe_rad    = _ruler_safe_spawn_rad,
		}
		_draw_single_ruler_triangle(dl, img_min, cur, false)
	}

	// 4. When Ruler mode is active (or active/pinned measurements exist), show the Ruler Mode / Axis / Angle control bar
	if !scene_2d_ruler_active && !_ruler_has_measurement && len(_ruler_pinned) == 0 do return

	bar_pos := im.Vec2{img_min.x + 12, img_max.y - (scene_2d_mode ? 64.0 : 34.0)}
	im.SetCursorScreenPos(bar_pos)
	im.PushStyleColorImVec4(.Button, {0.13, 0.14, 0.18, 0.92})
	im.PushStyleColorImVec4(.ButtonHovered, {0.24, 0.28, 0.36, 0.98})
	im.PushStyleColorImVec4(.ButtonActive, {0.30, 0.36, 0.48, 1.0})
	im.PushStyleVarImVec2(.FramePadding, {6, 3})
	im.PushStyleVar(.FrameRounding, 4.0)

	// Ruler Mode Dropdown
	im.SetNextItemWidth(175)
	if im.BeginCombo("##ruler_mode_combo", _ruler_mode_label(_ruler_mode)) {
		for m in Ruler_Mode {
			if im.Selectable(_ruler_mode_label(m), _ruler_mode == m) {
				_ruler_mode = m
				if m == .Vertical_Height && _ruler_axis_lock == .None {
					_ruler_axis_lock = .World_Y
				} else if m != .Vertical_Height && _ruler_axis_lock == .World_Y {
					_ruler_axis_lock = .None
				}
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Ruler Mode: Surface + Wall Clearance (safe spawn distance), Vertical Height / Axis-Locked (camera-tilt independent), Along Mesh Surface, or Protractor")
	im.SameLine(0, 4)

	// World Axis Lock Quick Toggles (Free / X / Y Height / Z)
	for a in Ruler_Axis_Lock {
		active_a := _ruler_axis_lock == a || (_ruler_mode == .Vertical_Height && a == .World_Y && _ruler_axis_lock == .None)
		if active_a {
			im.PushStyleColorImVec4(.Button, {0.22, 0.52, 0.32, 0.98})
		}
		if im.Button(fmt.ctprintf("%s##raxis_%d", _ruler_axis_lock_label(a), int(a))) {
			_ruler_axis_lock = a
			if a == .World_Y {
				_ruler_mode = .Vertical_Height
			} else if a == .None && _ruler_mode == .Vertical_Height {
				_ruler_mode = .Surface_Clearance
			}
		}
		widgets.tooltip("Lock the ruler to this world axis so camera tilt never skews the measurement (hotkeys X / Y / Z, N = free)")
		if active_a {
			im.PopStyleColor()
		}
		widgets.tooltip("Lock ruler measurement to World Axis (Hotkeys while Ruler active: X, Y for Vertical Height, Z, or N for Free)")
		im.SameLine(0, 2)
	}

	// Angle Format Dropdown (Degrees / Radians / Quaternion)
	im.SameLine(0, 4)
	im.SetNextItemWidth(135)
	if im.BeginCombo("##ruler_ang_combo", _ruler_angle_unit_label(_ruler_angle_unit)) {
		for u_ang in Ruler_Angle_Unit {
			if im.Selectable(_ruler_angle_unit_label(u_ang), _ruler_angle_unit == u_ang) {
				_ruler_angle_unit = u_ang
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Angle Display Format: Degrees (deg), Radians (rad / pi), or 3D Orientation Quaternion (qx, qy, qz, qw)")
	im.SameLine(0, 6)

	if _ruler_has_measurement {
		if im.Button("+ Pin (P)##ruler_pin") {
			append(&_ruler_pinned, Ruler_Measurement{
				start_world = _ruler_start_world,
				end_world   = _ruler_end_world,
				axis_r      = r,
				axis_u      = u,
				label_h     = lh,
				label_v     = lv,
				wall_valid  = _ruler_wall_hit_valid,
				wall_pos    = _ruler_wall_hit_pos,
				wall_dist   = _ruler_wall_dist,
				safe_rad    = _ruler_safe_spawn_rad,
			})
		}
		widgets.tooltip("Pin the current 3-sided measurement on screen so you can measure additional segments (Shortcut: P or hold Shift on release)")
		im.SameLine(0, 4)
	}

	if _ruler_has_measurement || len(_ruler_pinned) > 0 {
		if im.Button(fmt.ctprintf("%s Clear##ruler_clr_all", icons.ICON_MD_DELETE)) {
			_ruler_dragging = false
			_ruler_has_measurement = false
			clear(&_ruler_pinned)
		}
		widgets.tooltip("Clear the active ruler measurement and any pinned measurements from the viewport")
		im.SameLine(0, 4)
	}

	if _ruler_has_measurement {
		diff := _ruler_end_world - _ruler_start_world
		dh := abs(linalg.dot(diff, r))
		dv := abs(linalg.dot(diff, u))
		area := dh * dv
		slope_str: cstring = dh > 0.0005 ? fmt.ctprintf("%.2f", dv / dh) : "inf"
		info_txt := fmt.ctprintf("Area: %.2f m^2 | Slope: %s | Safe Spawn R: %.2f m##ruler_info", area, slope_str, _ruler_safe_spawn_rad)
		im.Button(info_txt)
		widgets.tooltip("Bounding area, rise/run slope, and safe obstacle-free spawn radius around start point")
	}

	im.PopStyleVar(2)
	im.PopStyleColor(3)
}

// 2D CAD HUD: live Depth Slice readout (Plain Wheel forward/backward through origin/mesh)
// and dynamic metric scale bar.
@(private = "file")
_draw_2d_cad_hud :: proc(dl: ^im.DrawList, img_min, img_max: im.Vec2) {
	fwd, r, u := _scene_cam_basis()

	// Bottom-left Depth Slice Readout + CAD Metric Scale Bar
	view_h := max(img_max.y - img_min.y, 1.0)
	if view_h < 80 do return

	// Determine active origin (selected node or World {0,0,0}) and camera depth slice
	origin_pos := [3]f32{0, 0, 0}
	origin_name: string = "Origin"
	w := engine.ctx_world()
	for h in sel_scene_items() {
		if engine.pool_valid(&w.transforms, engine.Handle(h)) {
			origin_pos = engine.transform_world(h).position
			if t := engine.pool_get(&w.transforms, engine.Handle(h)); t != nil && len(t.name) > 0 {
				origin_name = t.name
			}
			break
		}
	}
	// Signed distance from origin_pos to scene_cam_pos along -fwd (positive = in front of origin, negative = sliced past origin)
	depth_from_origin := linalg.dot(scene_cam_pos - origin_pos, -fwd)
	axis_char: cstring = "Z"
	switch scene_2d_angle {
	case .Front, .Back:   axis_char = "Z"
	case .Right, .Left:   axis_char = "X"
	case .Top, .Bottom:   axis_char = "Y"
	}

	half_h: f32
	if scene_cam_ortho {
		half_h = scene_cam_half_height()
	} else {
		fov_rad := math.to_radians(scene_cam_effective_fov_deg())
		plane_dist := max(abs(depth_from_origin), 0.25)
		half_h = plane_dist * math.tan(fov_rad * 0.5)
	}
	units_per_px := (2.0 * half_h) / view_h

	// Pick a clean 1-2-5 metric scale bar length that spans roughly 65..150 pixels
	nice_steps := [15]f32{0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 250.0}
	bar_world: f32 = 1.0
	for s in nice_steps {
		px_w := s / max(units_per_px, 1e-6)
		bar_world = s
		if px_w >= 65.0 do break
	}
	bar_px := clamp(bar_world / max(units_per_px, 1e-6), 40.0, 180.0)

	hud_pos := im.Vec2{img_min.x + 12, img_max.y - 34}
	im.SetCursorScreenPos(hud_pos)
	im.PushStyleColorImVec4(.Button, {0.11, 0.12, 0.15, 0.88})
	im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.26, 0.33, 0.95})
	im.PushStyleColorImVec4(.ButtonActive, {0.28, 0.34, 0.44, 1.0})
	im.PushStyleVarImVec2(.FramePadding, {6, 3})
	im.PushStyleVar(.FrameRounding, 4.0)

	// Interactive Depth Slice DragFloat + Reset Button (Plain Mouse Wheel or drag left/right moves along depth axis through origin/mesh)
	depth_drag := depth_from_origin
	im.SetNextItemWidth(165)
	depth_fmt := fmt.ctprintf("Depth (%s): %%+.2f m [%s]", axis_char, origin_name)
	if im.DragFloat("##2d_depth_drag", &depth_drag, 0.02, -500.0, 500.0, depth_fmt) {
		rel := scene_cam_pos - origin_pos
		pan_h := linalg.dot(rel, r)
		pan_v := linalg.dot(rel, u)
		scene_cam_pos = origin_pos + r * pan_h + u * pan_v - fwd * depth_drag
		_2d_depth_pulse_timer = 0.6
		update_scene_camera()
	}
	widgets.tooltip("2D Planar Depth along view axis (Plain Mouse Wheel or drag left/right to move forward/backward in 3D depth)")
	im.SameLine(0, 2)
	if im.Button(icons.ICON_MD_REFRESH + "##2d_depth_rst") {
		rel := scene_cam_pos - origin_pos
		pan_h := linalg.dot(rel, r)
		pan_v := linalg.dot(rel, u)
		scene_cam_pos = origin_pos + r * pan_h + u * pan_v - fwd * SCENE_2D_INITIAL_DEPTH
		_2d_depth_pulse_timer = 0.6
		update_scene_camera()
	}
	widgets.tooltip("Reset 2D Depth position in front of active origin")

	im.PopStyleVar(2)
	im.PopStyleColor(3)

	// Draw CAD Metric Scale Bar right next to the Depth Slice button
	im.SameLine(0, 12)
	scale_min := im.GetCursorScreenPos()
	im.Dummy({bar_px + 12, 22})
	bar_y := scale_min.y + 16
	bar_x0 := scale_min.x + 4
	bar_x1 := bar_x0 + bar_px
	col_bar_bg := im.GetColorU32ImVec4({0.08, 0.09, 0.12, 0.82})
	col_bar_fg := im.GetColorU32ImVec4({0.85, 0.90, 0.98, 0.95})
	im.DrawList_AddRectFilled(dl, {bar_x0 - 4, scale_min.y}, {bar_x1 + 4, scale_min.y + 22}, col_bar_bg, 4.0)
	im.DrawList_AddLine(dl, {bar_x0, bar_y}, {bar_x1, bar_y}, col_bar_fg, 2.0)
	im.DrawList_AddLine(dl, {bar_x0, bar_y - 5}, {bar_x0, bar_y + 2}, col_bar_fg, 2.0)
	im.DrawList_AddLine(dl, {bar_x1, bar_y - 5}, {bar_x1, bar_y + 2}, col_bar_fg, 2.0)
	im.DrawList_AddLine(dl, {(bar_x0 + bar_x1) * 0.5, bar_y - 3}, {(bar_x0 + bar_x1) * 0.5, bar_y + 1}, col_bar_fg, 1.5)
	scale_txt := bar_world >= 1.0 ? fmt.ctprintf("%.0f m", bar_world) : fmt.ctprintf("%.2g m", bar_world)
	sts := im.CalcTextSize(scale_txt)
	im.DrawList_AddText(dl, {(bar_x0 + bar_x1 - sts.x) * 0.5, scale_min.y + 1}, col_bar_fg, scale_txt)
}

@(private = "file")
_draw_3d_speed_hud :: proc(dl: ^im.DrawList, img_min, img_max: im.Vec2) {
	alpha := clamp(_speed_hud_timer / 0.4, 0.0, 1.0)
	txt := fmt.ctprintf("WASD Fly Speed: %.3f m/s", scene_fly_speed)
	ts := im.CalcTextSize(txt)
	bmin := im.Vec2{img_min.x + 12, img_max.y - 34}
	bmax := bmin + ts + {16, 10}
	im.DrawList_AddRectFilled(dl, bmin, bmax, im.GetColorU32ImVec4({0.09, 0.11, 0.15, 0.88 * alpha}), 4.0)
	im.DrawList_AddRect(dl, bmin, bmax, im.GetColorU32ImVec4({0.35, 0.65, 0.95, 0.85 * alpha}), 4.0)
	im.DrawList_AddText(dl, bmin + {8, 5}, im.GetColorU32ImVec4({0.92, 0.96, 1.0, alpha}), txt)
}


// Pivot mini-overlay: Unity's Global/Local gizmo orientation switch — a single
// icon+word button that flips the space on click. Scale always stays local
// (see Gizmo_Space).
@(scene_overlay={id="Pivot", order=100})
draw_pivot_overlay :: proc(vertical: bool) {
	// Unity's Pivot/Center toggle: gizmo at the active object's pivot vs the
	// center of the selection.
	// Vertical dock: icon-only square buttons (the words won't fit the column).
	pivot_label: cstring
	if vertical {
		pivot_label = gizmo_pivot == .Pivot ? icons.ICON_MD_TRIP_ORIGIN : icons.ICON_MD_CENTER_FOCUS
	} else {
		pivot_label = gizmo_pivot == .Pivot ? icons.ICON_MD_TRIP_ORIGIN + " Pivot" : icons.ICON_MD_CENTER_FOCUS + "Center"
	}
	if overlay_tool_button(pivot_label, "Gizmo position: active object's pivot vs the selection center", false, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		gizmo_pivot = gizmo_pivot == .Pivot ? .Center : .Pivot
	}

	if !vertical do im.SameLine()
	label: cstring
	if vertical {
		label = gizmo_space == .Global ? icons.ICON_MD_PUBLIC : icons.ICON_MD_DEPLOYED_CODE
	} else {
		label = gizmo_space == .Global ? icons.ICON_MD_PUBLIC + " World" : icons.ICON_MD_DEPLOYED_CODE + " Local"
	}
	if overlay_tool_button(label, "Gizmo orientation: world axes vs the object's axes (scale is always local)", false, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		gizmo_space = gizmo_space == .Global ? .Local : .Global
	}
}

// Planes restored when the grid toggle is switched back on after hiding all
// planes. XZ is the sensible fallback if nothing was shown when it was hidden.
_grid_last_planes := Grid_Settings{show_xz = true}

// Grid overlay: a split button. The icon toggles all grid planes on/off; the
// dropdown arrow opens the popup with the plane and spacing settings (see
// Grid_Settings). Button lights up while any plane shows.
@(scene_overlay={id="Grid", order=200})
draw_grid_overlay :: proc(vertical: bool) {
	gs := &grid_settings
	any_plane := gs.show_xz || gs.show_xy || gs.show_yz
	toggled, arrow := overlay_split_button("grid", icons.ICON_MD_GRID_ON, "Toggle grid", any_plane)
	if toggled {
		if any_plane {
			_grid_last_planes = gs^ // remember which planes were showing
			gs.show_xz, gs.show_xy, gs.show_yz = false, false, false
		} else {
			gs.show_xz = _grid_last_planes.show_xz
			gs.show_xy = _grid_last_planes.show_xy
			gs.show_yz = _grid_last_planes.show_yz
			if !(gs.show_xz || gs.show_xy || gs.show_yz) do gs.show_xz = true
		}
	}
	if arrow do im.OpenPopup("##grid_settings")
	im.SetNextWindowPos({im.GetItemRectMin().x - OVERLAY_BUTTON_SIZE - OVERLAY_SPLIT_GAP, im.GetItemRectMax().y + 2}, .Appearing)
	if im.BeginPopup("##grid_settings") {
		im.SeparatorText("Planes")
		im.Checkbox("XZ", &gs.show_xz)
		widgets.tooltip("Show the ground grid (XZ plane)")
		im.SameLine()
		im.Checkbox("XY", &gs.show_xy)
		widgets.tooltip("Show the front grid (XY plane)")
		im.SameLine()
		im.Checkbox("YZ", &gs.show_yz)
		widgets.tooltip("Show the side grid (YZ plane)")
		im.SameLine()
		im.Checkbox("Axes", &gs.show_axes)
		widgets.tooltip("Show the colored world X / Y / Z axis lines")

		im.SeparatorText("Cells")
		im.SetNextItemWidth(110)
		inspector.drag_float("Cell size", &gs.cell_size, 0.5, 0.01, 10000, "%.2f")
		widgets.tooltip("One cell in world units (emphasized lines)")
		im.SetNextItemWidth(110)
		inspector.drag_int("Subdivide", &gs.subdivide, 1, 1, 100)
		widgets.tooltip("Fine-line divisions inside each cell (1 = none)")
		im.SetNextItemWidth(110)
		inspector.drag_int("Cells count", &gs.cells_count, 1, 1, 1000)
		widgets.tooltip("Cells from the center to the grid's edge")
		im.EndPopup()
	}
}

// Snap split button next to the grid button. The icon toggles snapping on/off;
// the dropdown arrow opens the snap settings popup. Button lights up while
// snapping is enabled; Ctrl inverts enabled during a drag.
@(scene_overlay={id="Grid", order=210})
draw_snap_overlay :: proc(vertical: bool) {
	if !vertical do im.SameLine()
	toggled, arrow := overlay_split_button("snap", icons.ICON_MD_SNAP, "Toggle snap (hold Ctrl / Cmd on mac to invert while dragging)", snap_settings.enabled)
	if toggled do snap_settings.enabled = !snap_settings.enabled
	if arrow do im.OpenPopup("##snap_settings")
	im.SetNextWindowPos({im.GetItemRectMin().x - OVERLAY_BUTTON_SIZE - OVERLAY_SPLIT_GAP, im.GetItemRectMax().y + 2}, .Appearing)
	if im.BeginPopup("##snap_settings") {
		ss := &snap_settings
		im.SetNextItemWidth(110)
		inspector.drag_float("Angle", &ss.angle, 1, 1, 180, "%.0f deg")
		widgets.tooltip("Rotate gizmo snap increment")

		mode_names := [Snap_Mode]cstring{.Grid = "Grid", .SubGrid = "SubGrid", .Units = "Units"}
		im.SetNextItemWidth(110)
		if im.BeginCombo("Move step", mode_names[ss.mode], {}) {
			for m in Snap_Mode {
				if im.Selectable(mode_names[m], ss.mode == m) do ss.mode = m
			}
			im.EndCombo()
		}
		widgets.tooltip("Grid = one cell, SubGrid = one subdivision, Units = custom step")
		if ss.mode == .Units {
			im.SetNextItemWidth(110)
			inspector.drag_float("Value", &ss.units, 0.1, 0.01, 10000, "%.2f")
			if ss.units <= 0 do ss.units = 0.01
		}
		im.EndPopup()
	}
}

handle_scene_input :: proc() {
	io := im.GetIO()
	dt := io.DeltaTime
	alt_down := io.KeyAlt

	rmb_down := im.IsMouseDown(.Right)
	rmb_dragging := im.IsMouseDragging(.Right, 1)
	mmb_dragging := im.IsMouseDragging(.Middle, 1)
	lmb_dragging := im.IsMouseDragging(.Left, 1)
	cmd := io.KeyCtrl || io.KeySuper

	// Cmd (Ctrl) + right-click: the pick menu, every object under the
	// pointer. It takes the click from the flythrough.
	if cmd && im.IsMouseClicked(.Right) && !alt_down && !overlay_wants_mouse() && scene_rt != nil {
		mp := im.GetMousePos()
		view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height), unclipped_ortho = true)
		_pick_menu_open(view, mp.x - _scene_img_min.x, mp.y - _scene_img_min.y)
	}

	// Single Right-Click (fast human-speed click) vs. Hold/Drag RMB (Rotate/Move Screen Mode):
	// - Pressing and releasing RMB within `CONTEXT_CLICK_MAX_HOLD_SEC` (0.24s) without dragging
	//   past `CONTEXT_CLICK_SLOP_PX` (6px) and without pressing WASD opens the Context Menu (`##scene_context_menu`).
	// - Holding RMB longer than 0.24s, dragging the mouse > 6px, or pressing WASD while holding RMB
	//   immediately enters Screen Rotate / Move Mode (3D fly in 3D mode, 2D planar pan in 2D mode).
	if im.IsMouseClicked(.Right) && !cmd && !alt_down && !overlay_wants_mouse() && scene_rt != nil {
		mp := im.GetMousePos()
		_ctx_click_pos = {mp.x - _scene_img_min.x, mp.y - _scene_img_min.y}
		_ctx_click_travel = 0
		_ctx_click_hold_time = 0
		_ctx_click_pending = _ctx_click_pos.x >= 0 && _ctx_click_pos.y >= 0 && _ctx_click_pos.x < f32(scene_rt.width) && _ctx_click_pos.y < f32(scene_rt.height)
	}
	wasd_held := input.key_down(.W) || im.IsKeyDown(.W) || im.IsKeyDown(.UpArrow) ||
	             input.key_down(.S) || im.IsKeyDown(.S) || im.IsKeyDown(.DownArrow) ||
	             input.key_down(.A) || im.IsKeyDown(.A) || im.IsKeyDown(.LeftArrow) ||
	             input.key_down(.D) || im.IsKeyDown(.D) || im.IsKeyDown(.RightArrow) ||
	             input.key_down(.E) || im.IsKeyDown(.E) ||
	             input.key_down(.Q) || im.IsKeyDown(.Q)

	if _ctx_click_pending && rmb_down {
		_ctx_click_hold_time += dt
		raw_d := input.mouse_delta()
		im_d  := io.MouseDelta
		_ctx_click_travel += max(abs(raw_d.x) + abs(raw_d.y), abs(im_d.x) + abs(im_d.y))
		if _ctx_click_travel > CONTEXT_CLICK_SLOP_PX ||
		   _ctx_click_hold_time > CONTEXT_CLICK_MAX_HOLD_SEC ||
		   wasd_held || alt_down || cmd || input.wheel() != 0 {
			_ctx_click_pending = false
		}
	}
	if _ctx_click_pending && im.IsMouseReleased(.Right) {
		_ctx_click_pending = false
		if scene_flythrough_active {
			scene_flythrough_active = false
			input.set_mouse_relative(false)
		}
		if scene_rt != nil {
			view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height), unclipped_ortho = true)
			_scene_context_menu_open(view, _ctx_click_pos.x, _ctx_click_pos.y)
		}
		return
	}

	// Flythrough latches once RMB is held/dragged past the single-click threshold (`!_ctx_click_pending`)
	// and holds until RMB releases. Relative mouse mode hides and pins the cursor only when flythrough
	// actually starts, so a single right-click never teleports the cursor away from the menu!
	if scene_flythrough_active && (!rmb_down || alt_down) {
		scene_flythrough_active = false
		input.set_mouse_relative(false)
	}
	if !scene_flythrough_active && rmb_down && !_ctx_click_pending && !alt_down && !cmd && scene_view_hovered && !scene_2d_mode && !overlay_wants_mouse() {
		scene_flythrough_active = true
		input.set_mouse_relative(true, {_scene_img_min.x, _scene_img_min.y}, _scene_view_size)
		// Smoothing state starts at rest so entry doesn't inherit stale lag.
		_fly_yaw_target = scene_cam_yaw
		_fly_pitch_target = scene_cam_pitch
		_fly_vel = {0, 0, 0}
	}

	// Any manual camera input takes over from an in-flight frame tween.
	if rmb_down || mmb_dragging || (alt_down && lmb_dragging) || (io.MouseWheel != 0 && (scene_2d_mode || cmd)) {
		_frame_tween_active = false
	}

	// In 2D Mode, holding RMB enters 2D Screen Movement Mode:
	// - Mouse drag pans the 2D screen
	// - WASD / Arrow keys strictly pan the 2D screen (up/down/left/right) regardless of any other WASD bindings!
	if scene_2d_mode && rmb_down && !_ctx_click_pending && !alt_down && !cmd {
		_, r, u := _scene_cam_basis()
		delta := io.MouseDelta
		if (delta.x != 0 || delta.y != 0) && scene_rt != nil {
			fov_rad := math.to_radians(scene_cam_effective_fov_deg())
			units_per_px := (2 * max(scene_cam_dist, 0.5) * math.tan(fov_rad * 0.5)) / max(f32(scene_rt.height), 1)
			if scene_cam_ortho do units_per_px = 2 * scene_cam_half_height() / max(f32(scene_rt.height), 1)
			scene_cam_pos += r * (-delta.x * units_per_px) + u * (delta.y * units_per_px)
		}
		move_2d := [3]f32{0, 0, 0}
		if input.key_down(.W) || im.IsKeyDown(.W) || im.IsKeyDown(.UpArrow)    do move_2d += u
		if input.key_down(.S) || im.IsKeyDown(.S) || im.IsKeyDown(.DownArrow)  do move_2d -= u
		if input.key_down(.D) || im.IsKeyDown(.D) || im.IsKeyDown(.RightArrow) do move_2d += r
		if input.key_down(.A) || im.IsKeyDown(.A) || im.IsKeyDown(.LeftArrow)  do move_2d -= r
		if move_2d != {} {
			zoom_scale := clamp(scene_cam_dist / FLYTHROUGH_BASE_SPEED, 0.05, 10.0)
			spd := scene_fly_speed * zoom_scale
			if input.key_down(.LSHIFT) || input.key_down(.RSHIFT) || io.KeyShift do spd *= FLYTHROUGH_SHIFT_MULT
			scene_cam_pos += linalg.normalize0(move_2d) * spd * dt
		}
		update_scene_camera()
		return
	}

	// In 3D Mode, holding RMB (`scene_flythrough_active`) enters 3D Screen Rotate & Fly Mode:
	// - Mouse rotates the camera
	// - WASD / Q / E / Arrows strictly move the 3D camera regardless of any other WASD bindings!
	if scene_flythrough_active {
		_orbit_active = false
		// Keep ImGui's logical cursor pinned to the center of the Scene Viewport
		// so no external window or widget can ever be hovered mid-flythrough.
		io.MousePos = {_scene_img_min.x + _scene_view_size.x * 0.5, _scene_img_min.y + _scene_view_size.y * 0.5}

		// First-person look — all reads below go through the input package
		// (raw SDL snapshot): imgui derives its mouse delta from the cursor
		// position, which relative mode pins.
		// Mouse moves the TARGET; the camera exponentially chases it, which
		// smooths sensor jitter into a short, frame-rate-independent glide.
		delta := input.mouse_delta()
		// The pointer moved or the camera flew: the right-click is a look,
		// not a click for the context menu.
		_ctx_click_travel += abs(delta.x) + abs(delta.y)
		if _ctx_click_travel > CONTEXT_CLICK_SLOP_PX || input.wheel() != 0 do _ctx_click_pending = false
		_fly_yaw_target += delta.x * scene_look_sensitivity
		_fly_pitch_target = clamp(_fly_pitch_target - delta.y * scene_look_sensitivity, -PITCH_LIMIT, PITCH_LIMIT)
		look_k := 1 - math.exp(-dt / FLY_LOOK_SMOOTH_TAU)
		scene_cam_yaw += (_fly_yaw_target - scene_cam_yaw) * look_k
		scene_cam_pitch = clamp(scene_cam_pitch + (_fly_pitch_target - scene_cam_pitch) * look_k, -PITCH_LIMIT, PITCH_LIMIT)

		// Wheel during fly rescales the base speed for the session (Unity).
		if wheel := input.wheel(); wheel != 0 {
			scene_fly_speed = clamp(scene_fly_speed * math.pow(FLY_SPEED_WHEEL_BASE, wheel), FLYTHROUGH_MIN_SPEED, FLYTHROUGH_MAX_SPEED)
			_fly_speed_cur = min(_fly_speed_cur, scene_fly_speed * FLYTHROUGH_RAMP_MULT)
			_speed_hud_timer = 1.5
		}

		fwd, right, _ := _scene_cam_basis()
		move := [3]f32{0, 0, 0}
		if input.key_down(.W) || im.IsKeyDown(.W) || im.IsKeyDown(.UpArrow)    do move += fwd
		if input.key_down(.S) || im.IsKeyDown(.S) || im.IsKeyDown(.DownArrow)  do move -= fwd
		if input.key_down(.D) || im.IsKeyDown(.D) || im.IsKeyDown(.RightArrow) do move += right
		if input.key_down(.A) || im.IsKeyDown(.A) || im.IsKeyDown(.LeftArrow)  do move -= right
		if input.key_down(.E) || im.IsKeyDown(.E) do move += [3]f32{0, 1, 0}
		if input.key_down(.Q) || im.IsKeyDown(.Q) do move -= [3]f32{0, 1, 0}
		if move != {} do _ctx_click_pending = false

		// Target velocity from the keys; the smoothed velocity chases it so
		// starts, stops, and direction changes ease instead of stepping.
		target_vel: [3]f32
		len := linalg.length(move)
		if len > 0 {
			// Held movement ramps toward the cap, so short taps stay precise
			// and long hauls get fast. Release resets to base.
			_fly_speed_cur = min(
				_fly_speed_cur + scene_fly_speed * (FLYTHROUGH_RAMP_MULT - 1) / FLYTHROUGH_RAMP_TIME * dt,
				scene_fly_speed * FLYTHROUGH_RAMP_MULT,
			)
			speed := _fly_speed_cur
			if input.key_down(.LSHIFT) || input.key_down(.RSHIFT) || io.KeyShift do speed *= FLYTHROUGH_SHIFT_MULT
			target_vel = move / len * speed
		} else {
			_fly_speed_cur = scene_fly_speed
		}
		if scene_fly_move_smooth_tau <= 0.005 {
			_fly_vel = target_vel
		} else {
			move_k := 1 - math.exp(-dt / scene_fly_move_smooth_tau)
			_fly_vel += (target_vel - _fly_vel) * move_k
		}
		scene_cam_pos += _fly_vel * dt

		update_scene_camera()
		return
	}
	_fly_speed_cur = scene_fly_speed

	// Transform tool shortcuts (when RMB is not held):
	// Q = Picker, W = Move (.Translate), E = Rotate (.Rotate), R = Scale (.Scale), T = Handles (.Handles)
	// Camera WASD flythrough requires holding Right Mouse Button (handled above).
	if scene_view_hovered && !rmb_down && !io.WantTextInput && !cmd && !alt_down && !sim_is_active() && im.GetTopMostPopupModal() == nil {
		in_cad := cad_csg_editor.is_in_cad_mode()
		allow_xform_keys := !in_cad || (cad_csg_editor.are_transform_tool_hotkeys_enabled() && !cad_csg_editor.is_cad_tool_busy() && !(io.KeyShift && cad_csg_editor.mesh_editor_owns_viewport()))
		if allow_xform_keys {
			if im.IsKeyPressed(.Q) {
				gizmo_mode = .Picker
				scene_2d_ruler_active = false
				if in_cad do cad_csg_editor.deactivate_cad_tool()
			}
			if im.IsKeyPressed(.W) {
				gizmo_mode = .Translate
				scene_2d_ruler_active = false
				if in_cad do cad_csg_editor.deactivate_cad_tool()
			}
			if im.IsKeyPressed(.E) {
				gizmo_mode = .Rotate
				scene_2d_ruler_active = false
				if in_cad do cad_csg_editor.deactivate_cad_tool()
			}
			if im.IsKeyPressed(.R) {
				gizmo_mode = .Scale
				scene_2d_ruler_active = false
				if in_cad do cad_csg_editor.deactivate_cad_tool()
			}
			if im.IsKeyPressed(.T) {
				gizmo_mode = .Handles
				scene_2d_ruler_active = false
				if in_cad do cad_csg_editor.deactivate_cad_tool()
			}
		}
	}

	// Gizmo mode shortcuts (1/2/3/4/5, F, Delete, M) — only when Scene3D is hovered and no modal popup is active!
	if scene_view_hovered && !rmb_down && !io.WantTextInput && !sim_is_active() && !scene_tools_consume_mouse() && im.GetTopMostPopupModal() == nil {
		// In CAD Mesh Editor, 1 / 2 / 3 pick Vertex / Edge / Face and Delete removes sub-objects
		// (routed through Edit -> Delete), so don't also switch tools / delete the whole object here.
		mesh_owns := cad_csg_editor.mesh_editor_owns_viewport()
		if !mesh_owns && (!cad_csg_editor.is_in_cad_mode() || cad_csg_editor.are_subtool_number_hotkeys_enabled()) {
			if im.IsKeyPressed(._1) { gizmo_mode = .Picker;    scene_2d_ruler_active = false }
			if im.IsKeyPressed(._2) { gizmo_mode = .Translate; scene_2d_ruler_active = false }
			if im.IsKeyPressed(._3) { gizmo_mode = .Rotate;    scene_2d_ruler_active = false }
			if im.IsKeyPressed(._4) { gizmo_mode = .Scale;     scene_2d_ruler_active = false }
			if im.IsKeyPressed(._5) { gizmo_mode = .Handles;   scene_2d_ruler_active = false }
		}
		if im.IsKeyPressed(.F) && !mesh_owns do scene_frame_selected()
		if im.IsKeyPressed(.Delete) && !mesh_owns do hierarchy_delete_menu()
		if im.IsKeyPressed(.M) {
			scene_2d_ruler_active = !scene_2d_ruler_active
			if scene_2d_ruler_active {
				cad_csg_editor.deactivate_cad_tool()
			} else {
				_ruler_dragging = false
				_ruler_has_measurement = false
			}
		}
		if (scene_2d_ruler_active || _ruler_has_measurement) && im.IsKeyPressed(.P) && _ruler_has_measurement {
			r, u, lh, lv := _ruler_basis_for_segment(_ruler_start_world, _ruler_end_world)
			append(&_ruler_pinned, Ruler_Measurement{
				start_world = _ruler_start_world,
				end_world   = _ruler_end_world,
				axis_r      = r,
				axis_u      = u,
				label_h     = lh,
				label_v     = lv,
				wall_valid  = _ruler_wall_hit_valid,
				wall_pos    = _ruler_wall_hit_pos,
				wall_dist   = _ruler_wall_dist,
				safe_rad    = _ruler_safe_spawn_rad,
			})
		}
	}

	// 3D & 2D Ruler interaction (works in all modes):
	// - Updates live 3D surface hover & object height bracket + wall clearance
	// - Supports X / Y (Vertical Height) / Z / N axis lock hotkeys
	// - LMB drag measures between two points (with optional World Axis Lock)
	if scene_2d_ruler_active {
		if !rmb_down && !io.WantTextInput && !cmd {
			if im.IsKeyPressed(.X) {
				_ruler_axis_lock = (_ruler_axis_lock == .World_X) ? .None : .World_X
			}
			if im.IsKeyPressed(.Y) {
				_ruler_axis_lock = (_ruler_axis_lock == .World_Y) ? .None : .World_Y
				if _ruler_axis_lock == .World_Y do _ruler_mode = .Vertical_Height
			}
			if im.IsKeyPressed(.Z) {
				_ruler_axis_lock = (_ruler_axis_lock == .World_Z) ? .None : .World_Z
			}
			if im.IsKeyPressed(.N) {
				_ruler_axis_lock = .None
			}
		}

		snap_now := snap_settings.enabled != cmd
		mp := im.GetMousePos()
		if scene_rt != nil {
			view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
			ray := engine.render_view_screen_ray(view, mp.x - _scene_img_min.x, mp.y - _scene_img_min.y)
			if hp, _, htH, hok := _ruler_raycast_ray(view, ray, include_ground = true); hok {
				_ruler_hover_valid = true
				_ruler_hover_world = hp
				_ruler_hover_tH    = htH
				if !_ruler_dragging && !_ruler_has_measurement {
					_ruler_update_wall_clearance(view, hp, hp)
				}
			} else {
				_ruler_hover_valid = false
			}
		}

		if im.IsMouseClicked(.Left) && !alt_down && !overlay_wants_mouse() {
			_ruler_dragging = true
			_ruler_has_measurement = true
			_ruler_start_world = _2d_screen_to_world_plane(mp, snap_now, is_end_point = false)
			_ruler_end_world = _ruler_start_world
			if scene_rt != nil {
				view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
				_ruler_update_wall_clearance(view, _ruler_start_world, _ruler_end_world)
			}
			_scene_click_pending = false
		}
		if _ruler_dragging {
			if im.IsMouseDown(.Left) {
				_ruler_end_world = _2d_screen_to_world_plane(mp, snap_now, is_end_point = true)
				if scene_rt != nil {
					view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
					_ruler_update_wall_clearance(view, _ruler_start_world, _ruler_end_world)
				}
				return
			} else {
				_ruler_dragging = false
				if input.key_down(.LSHIFT) || input.key_down(.RSHIFT) {
					r, u, lh, lv := _ruler_basis_for_segment(_ruler_start_world, _ruler_end_world)
					append(&_ruler_pinned, Ruler_Measurement{
						start_world = _ruler_start_world,
						end_world   = _ruler_end_world,
						axis_r      = r,
						axis_u      = u,
						label_h     = lh,
						label_v     = lv,
						wall_valid  = _ruler_wall_hit_valid,
						wall_pos    = _ruler_wall_hit_pos,
						wall_dist   = _ruler_wall_dist,
						safe_rad    = _ruler_safe_spawn_rad,
					})
				}
			}
		}
	} else {
		_ruler_dragging    = false
		_ruler_hover_valid = false
	}

	// Escape drops the selection (not mid-drag: the drag teardown in
	// gizmo_tool_frame would leave its undo step open). During a
	// band it cancels the band and restores the pre-band selection instead.
	if im.IsKeyPressed(.Escape) && !scene_tools_dragging() {
		if _ruler_has_measurement || scene_2d_ruler_active || len(_ruler_pinned) > 0 {
			_ruler_dragging = false
			_ruler_has_measurement = false
			scene_2d_ruler_active = false
			clear(&_ruler_pinned)
		} else if _band_active {
			_band_active = false
			sel_scene_clear()
			for h in _band_base do sel_scene_add(h)
		} else if scene_rig_controls_mode_active() && scene_rig_controls_clear_if_any() {
			// Cleared selected rig control(s) while keeping the active character selected
		} else {
			sel_scene_clear()
		}
		_scene_click_pending = false
	}

	// Click-to-pick: LMB press + release within a few pixels (and no Alt —
	// Alt+LMB orbits; not on the gizmo — grabs must not select-through; and
	// not on an overlay — button clicks must not pick behind them).
	if !scene_2d_ruler_active && im.IsMouseClicked(.Left) && !alt_down && !scene_tools_consume_mouse() && !overlay_wants_mouse() {
		_scene_click_pos = im.GetMousePos()
		_scene_click_pending = true
	}
	if _scene_click_pending && scene_tools_consume_mouse() {
		_scene_click_pending = false
	}
	// An armed click that travels beyond the click threshold becomes a rubber
	// band (works in every tool mode, Unity-style).
	if _scene_click_pending && !_band_active && !scene_rig_controls_mode_active() {
		mp := im.GetMousePos()
		dx := mp.x - _scene_click_pos.x
		dy := mp.y - _scene_click_pos.y
		if dx * dx + dy * dy >= 16 {
			_scene_click_pending = false
			_band_active = true
			_band_anchor = _scene_click_pos
			_band_additive = io.KeyCtrl || io.KeySuper
			clear(&_band_base)
			for h in sel_scene_items() do append(&_band_base, h)
		}
	}
	if _scene_click_pending && im.IsMouseReleased(.Left) {
		_scene_click_pending = false
		mp := im.GetMousePos()
		dx := mp.x - _scene_click_pos.x
		dy := mp.y - _scene_click_pos.y
		if !alt_down && dx * dx + dy * dy < 16 && scene_rt != nil {
			if scene_rig_controls_mode_active() {
				// Clicking empty viewport space in Rig Controls mode deselects rig controls cleanly
				// instead of picking background/floor geometry behind the character.
				if !cmd {
					_ = scene_rig_controls_clear_if_any()
				}
			} else {
				view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height), unclipped_ortho = true)
				px := mp.x - _scene_img_min.x
				py := mp.y - _scene_img_min.y
				// cmd/ctrl-click toggles the picked object in/out of the
				// selection (no hierarchy reveal); plain click selects only it.
				// Clicking empty space clears — unless toggling, where a miss
				// shouldn't nuke the set being built.
				prev_suppress := engine.canvas_suppress_overlay_in_scene_3d()
				if !scene_2d_mode do engine.canvas_set_suppress_overlay_in_scene_3d(true)
				tH, hit := scene_view_pick(view, px, py)
				engine.canvas_set_suppress_overlay_in_scene_3d(prev_suppress)
				if hit {
					if cmd {
						sel_scene_toggle(tH)
					} else {
						engine.inspector_request_select(tH)
					}
				} else if !cmd {
					sel_scene_clear()
				}
			}
		}
	}

	if alt_down && lmb_dragging && !scene_2d_mode {
		// Orbit around the anchor captured when the drag started (Unity's
		// pivot model: F/pan/zoom place it, orbit revolves around it).
		if !_orbit_active {
			_orbit_active = true
			_orbit_pivot = scene_cam_target
			scene_cam_dist = max(linalg.length(scene_cam_pos - _orbit_pivot), CAM_MIN_DIST)
		}
		delta := io.MouseDelta
		scene_cam_yaw += delta.x * scene_look_sensitivity
		scene_cam_pitch = clamp(scene_cam_pitch - delta.y * scene_look_sensitivity, -PITCH_LIMIT, PITCH_LIMIT)
		fwd, _, _ := _scene_cam_basis()
		scene_cam_pos = _orbit_pivot - fwd * scene_cam_dist
		update_scene_camera()
		return
	}
	_orbit_active = false

	// Pan: middle drag, and in 2D also right drag and alt-drag (no orbit there).
	if mmb_dragging || (scene_2d_mode && scene_view_hovered && (rmb_dragging || (alt_down && lmb_dragging))) {
		delta := io.MouseDelta
		_, r, u := _scene_cam_basis()

		// Distance/viewport scaling keeps the grabbed point under the cursor
		// at any zoom level and window size.
		fov_rad := math.to_radians(scene_cam_effective_fov_deg())
		units_per_px := (2 * max(scene_cam_dist, 0.5) * math.tan(fov_rad * 0.5)) / max(f32(scene_rt.height), 1)
		if scene_cam_ortho do units_per_px = 2 * scene_cam_half_height() / max(f32(scene_rt.height), 1)
		pan := r * (-delta.x * units_per_px) + u * (delta.y * units_per_px)
		scene_cam_pos += pan
		update_scene_camera()
		return
	}

	wheel := io.MouseWheel
	if wheel != 0 {
		if scene_cam_ortho && cmd {
			// In Orthographic mode, Ctrl + Mouse Wheel scales the orthographic frustum size
			// monotonically without changing camera depth position.
			scene_cam_dist = clamp(scene_cam_dist * math.pow(ZOOM_WHEEL_BASE, -wheel), CAM_MIN_DIST, 10000)
			update_scene_camera()
		} else if !scene_2d_mode {
			// In 3D Scene mode, zoom is removed completely; Mouse Wheel exclusively
			// adjusts WASD camera movement/fly speed (scene_fly_speed), while the
			// small near clip plane (SCENE_CAM_NEAR = 0.001) lets you fly right up to any surface.
			if !cmd && !alt_down {
				scene_fly_speed = clamp(scene_fly_speed * math.pow(FLY_SPEED_WHEEL_BASE, wheel), FLYTHROUGH_MIN_SPEED, FLYTHROUGH_MAX_SPEED)
				_fly_speed_cur = scene_fly_speed
				_speed_hud_timer = 1.5
			}
		} else {
			// In 2D planar mode: Mouse Wheel physically moves the camera forward/backward
			// along the locked view axis (Z depth) straight through {0,0,0} and through meshes
			// without bouncing scene_cam_dist at the origin.
			step := scene_2d_wheel_step
			if input.key_down(.LSHIFT) || input.key_down(.RSHIFT) || io.KeyShift do step *= FLYTHROUGH_SHIFT_MULT
			if alt_down do step *= 0.1
			fwd, _, _ := _scene_cam_basis()
			scene_cam_pos += fwd * (wheel * step)
			_2d_depth_pulse_timer = 0.6
			update_scene_camera()
		}
	}
}
