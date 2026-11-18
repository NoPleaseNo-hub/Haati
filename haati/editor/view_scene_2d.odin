package editor

// Dedicated "Scene 2D" Editor Window — Dual Godot-Style 2D Game Engine & UMG Menu Engine.
// Operates as a standalone dockable editor window (`icons.TITLE_SCENE_2D`,
// `Window -> General -> Scene 2D`, shortcut `Ctrl+Shift+2`) with:
//   1. Dual-Pass 2D Offscreen Rendering:
//      - Pass 1 (2D World Space, 1m = 100px centered at {0,0}): renders `SpriteRenderer`,
//        2D meshes, and particles at exact 100 PPU scale.
//      - Pass 2 (2D UI Canvas Space, [0..ref.x] x [0..ref.y] px): renders `Canvas` panels,
//        9-slice `Image`s, `Button`s, and SDF `Text` on top.
//   2. Godot-Style 2D Game Engine Authoring & Simulation:
//      - One-click creation of `+Sprite2D`, `+RigidBody2D (Box)`, `+RigidBody2D (Circle)`,
//        `+StaticBody2D (Platform)`, `+Character2D (Capsule)`, and `+2D Physics Arena`.
//      - Live green 2D collider wireframes (`BoxCollider2D`, `CircleCollider2D`, `CapsuleCollider2D`),
//        direct 2D click-picking, drag-move, and corner-scaling of 2D world nodes.
//      - In-viewport `[Simulate 2D Physics]` toggle with automatic transform snapshot & restore.
//   3. Full Menu & UI Engine:
//      - One-click `+Panel`, `+Image`, `+Button`, `+Text`, `+Layout`, plus Menu Templates
//        (`+Build QuickMenu Canvas`, `+Sci-Fi Button`, `+Slider Row`, `+Toggle Row`, `+HUD Overlay`).
//      - Interactive `[Test Menu / Live Overlay]` mode to test `QuickMenu`, `Console`, and
//        `mhgui.Button` hover/click transitions directly inside Scene 2D.
//      - Inline Quick-Styling bar (Color tint swatch + Text string & font size editor),
//        drag-and-drop texture import from Void File Explorer, right-click context menu,
//        and keyboard shortcuts (Arrow nudge, Ctrl+D duplicate, Delete).

import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "../engine"
import gfx "../engine/gfx"
import "../engine/input"
import "menu"
import "undo"
import "haati:editor/icons"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import mhgui "haati:packages/mhgui"
import physics2d "haati:packages/physics2d"
import sprites "haati:packages/sprites"
import text_pkg "haati:packages/text"

scene_2d_rt: ^gfx.Render_Target

Scene_2D_Resolution :: struct {
	label: cstring,
	w, h:  f32,
}

SCENE_2D_RESOLUTIONS :: []Scene_2D_Resolution{
	{"1920x1080 (Full HD 16:9)", 1920, 1080},
	{"1280x720 (HD 16:9)", 1280, 720},
	{"2560x1440 (QHD 16:9)", 2560, 1440},
	{"3840x2160 (4K UHD 16:9)", 3840, 2160},
	{"1080x1920 (Portrait Mobile)", 1080, 1920},
	{"Custom Resolution...", 0, 0},
}

// Built-in 2D sprite asset GUIDs (fallback to mhgui.white_texture_guid() if absent)
@(private = "file") _S2D_SQUARE_SPRITE_GUID_STR :: "a42ddfb5-859d-43cc-81ca-c51438ab63e9"
@(private = "file") _S2D_CIRCLE_SPRITE_GUID_STR :: "f763e80e-c7e4-4d58-9a39-50b64585018f"

// What layer / source `Scene 2D` renders into its offscreen viewport
@(private = "file")
_S2D_Render_Mode :: enum u8 {
	World_2D_And_Canvas = 0, // 2D Sprites/Physics2D + UI Canvas (3D Meshes excluded by default so they never occlude UI)
	UI_Canvas_Only      = 1, // Isolates ONLY the selected UI/Menu Canvas (zero 2D sprites or 3D background)
	World_2D_Only       = 2, // Isolates ONLY the 2D Game World (Sprites & Physics2D, hides UI Canvas overlays)
	Scene_Capture_Cam   = 3, // Renders through the selected Scene Capture Camera (`engine.Camera` / `Canvas.render_camera`)
}

// Which menu system `[Test Menu]` activates inside `Scene 2D`
@(private = "file")
_S2D_Test_Menu_Source :: enum u8 {
	Both_Canvas_And_QuickMenu = 0, // Interactive Scene Canvas UI + Void QuickMenu / Console Overlay
	Scene_Canvas_Only         = 1, // Interactive Scene Canvas UI Only (Buttons with Raked-Leaf Physics)
	Void_QuickMenu_Only       = 2, // Void QuickMenu (Main / Settings / Dev Console ~) Overlay Only
}

// 2D Canvas viewport state (independent of 3D Scene camera)
@(private = "file") _s2d_res_index: int = 0
@(private = "file") _s2d_custom_res: [2]i32 = {1920, 1080}
@(private = "file") _s2d_pan: [2]f32 = {960, 540} // Canvas center in canvas pixel space (0..1920, 0..1080)
@(private = "file") _s2d_zoom: f32 = 0.55         // Screen pixels per canvas pixel
@(private = "file") _s2d_initialized: bool = false
@(private = "file") _s2d_show_grid: bool = true
@(private = "file") _s2d_show_colliders: bool = true
@(private = "file") _s2d_live_menu_preview: bool = false
@(private = "file") _s2d_render_mode: _S2D_Render_Mode = .World_2D_And_Canvas
@(private = "file") _s2d_include_3d_meshes: bool = false
@(private = "file") _s2d_isolate_selected_canvas: bool = true
@(private = "file") _s2d_pinned_canvas: engine.Transform_Handle
@(private = "file") _s2d_capture_cam_h: engine.Transform_Handle
@(private = "file") _s2d_show_capture_cam_gizmo: bool = true
@(private = "file") _s2d_test_menu_source: _S2D_Test_Menu_Source = .Both_Canvas_And_QuickMenu

// Raked-Leaf Hover Physics state for Scene `Canvas` `mhgui.Button` nodes during `[Test Menu]`
@(private = "file")
_S2D_Canvas_Btn_Physics :: struct {
	tH:            engine.Transform_Handle,
	orig_rot:      [4]f32,
	orig_pos:      [3]f32,
	target_rot:    f32,
	target_off:    [2]f32,
	cur_rot:       f32,
	cur_off:       [2]f32,
	settle_timer:  f32,
	idle_timer:    f32,
	was_hovered:   bool,
}

@(private = "file") _s2d_canvas_btn_phys: [dynamic]_S2D_Canvas_Btn_Physics

// In-viewport 2D Physics Simulation state inside Scene 2D
@(private = "file")
_S2D_Sim_Snapshot :: struct {
	tH:       engine.Transform_Handle,
	position: [3]f32,
	rotation: [4]f32,
	scale:    [3]f32,
}

@(private = "file") _s2d_sim_running: bool = false
@(private = "file") _s2d_sim_accum: f32 = 0.0
@(private = "file") _s2d_sim_snapshots: [dynamic]_S2D_Sim_Snapshot

// 2D Interactive RectTransform, 2D World Node & Scene Capture Camera drag state inside Scene 2D
@(private = "file")
_S2D_Drag_Kind :: enum u8 {
	None,
	Move_Body,
	Resize_Edge,
	Move_Anchor,
	Move_Anchor_All,
	Move_Pivot,
	Move_World_2D,
	Scale_World_2D,
	Move_Capture_Cam,
	Resize_Capture_Cam,
}

@(private = "file") _s2d_drag_kind: _S2D_Drag_Kind = .None
@(private = "file") _s2d_drag_tH: engine.Transform_Handle
@(private = "file") _s2d_drag_start_rt: engine.RectTransform
@(private = "file") _s2d_drag_start_pos: [3]f32
@(private = "file") _s2d_drag_start_scale: [3]f32
@(private = "file") _s2d_drag_start_ortho: f32
@(private = "file") _s2d_drag_start_mouse: im.Vec2
@(private = "file") _s2d_drag_sides: [2]i8
@(private = "file") _s2d_drag_anchor_idx: int
@(private = "file") _s2d_drag_parent_rect: engine.Rect
@(private = "file") _s2d_drag_sess: undo.Edit_Session

// Context menu spawn position in canvas pixels
@(private = "file") _s2d_ctx_canvas_pt: [2]f32 = {960, 540}
@(private = "file") _s2d_rmb_press_pos: im.Vec2

// Inline text edit buffer for quick label editing in toolbar
@(private = "file") _s2d_inline_text_buf: [256]u8
@(private = "file") _s2d_inline_text_last_tH: engine.Transform_Handle

// 2D AutoCAD Ruler state in Scene 2D (in canvas pixel coordinates)
@(private = "file")
_S2D_Ruler_Meas :: struct {
	p0, p1: [2]f32, // Canvas pixel coordinates
}

@(private = "file") _s2d_ruler_active: bool = false
@(private = "file") _s2d_ruler_dragging: bool = false
@(private = "file") _s2d_ruler_has_cur: bool = false
@(private = "file") _s2d_ruler_cur: _S2D_Ruler_Meas
@(private = "file") _s2d_ruler_pinned: [dynamic]_S2D_Ruler_Meas

init_scene_2d_view :: proc() {
	scene_2d_rt = gfx.rt_create(1, 1)
}

shutdown_scene_2d_view :: proc() {
	if _s2d_sim_running {
		_s2d_stop_physics_sim()
	}
	_s2d_restore_canvas_btn_physics()
	gfx.rt_destroy(scene_2d_rt)
	scene_2d_rt = nil
	delete(_s2d_ruler_pinned)
	delete(_s2d_sim_snapshots)
	delete(_s2d_canvas_btn_phys)
}

@(private = "file")
_s2d_restore_canvas_btn_physics :: proc() {
	w := engine.ctx_world()
	if w != nil {
		for entry in _s2d_canvas_btn_phys {
			if t := engine.pool_get(&w.transforms, engine.Handle(entry.tH)); t != nil {
				t.rotation = entry.orig_rot
			}
			if _, rt := engine.transform_get_comp(entry.tH, engine.RectTransform); rt != nil {
				rt.anchored_position = entry.orig_pos
			}
			if _, cr := engine.transform_get_comp(entry.tH, engine.CanvasRenderer); cr != nil {
				cr.tinted = false
			}
		}
	}
	clear(&_s2d_canvas_btn_phys)
}

// Reference canvas size in pixels (default 1920x1080, or user-specified custom W x H)
@(private = "file")
_s2d_ref_size :: proc() -> [2]f32 {
	res := SCENE_2D_RESOLUTIONS
	idx := clamp(_s2d_res_index, 0, len(res) - 1)
	if res[idx].w <= 0 || res[idx].h <= 0 {
		return {f32(max(_s2d_custom_res.x, 64)), f32(max(_s2d_custom_res.y, 64))}
	}
	return {res[idx].w, res[idx].h}
}

// Keep the canvas layout engine's reference size synced with Scene 2D when
// Scene 2D is open in the editor so Inspector Anchor Presets and rect_frame
// match Scene 2D's exact canvas dimensions without overriding 3D SceneView placement.
scene_2d_sync_viewport :: proc() {
	engine.canvas_set_scene_2d_viewport(_s2d_ref_size(), false)
}

// Convert 2D canvas coordinate (where {0,0} is bottom-left of reference canvas, Y-up)
// to screen-space ImGui coordinate inside `view_min..view_max`.
@(private = "file")
_s2d_canvas_to_screen :: proc(canvas_pt: [2]f32, view_min, view_size: im.Vec2) -> im.Vec2 {
	center := view_min + view_size * 0.5
	return {
		center.x + (canvas_pt.x - _s2d_pan.x) * _s2d_zoom,
		center.y - (canvas_pt.y - _s2d_pan.y) * _s2d_zoom,
	}
}

// Convert screen-space ImGui coordinate to 2D canvas coordinate (Y-up).
@(private = "file")
_s2d_screen_to_canvas :: proc(screen_pt: im.Vec2, view_min, view_size: im.Vec2) -> [2]f32 {
	center := view_min + view_size * 0.5
	z := max(_s2d_zoom, 0.01)
	return {
		_s2d_pan.x + (screen_pt.x - center.x) / z,
		_s2d_pan.y - (screen_pt.y - center.y) / z,
	}
}

// Convert 2D World Space (meters, {0,0} at center of reference canvas, 1m = 100px) <-> 2D Canvas Pixels
@(private = "file")
_s2d_world_to_canvas :: proc(world_xy: [2]f32) -> [2]f32 {
	ref := _s2d_ref_size()
	return ref * 0.5 + world_xy * engine.PIXELS_PER_UNIT
}

@(private = "file")
_s2d_canvas_to_world :: proc(canvas_pt: [2]f32) -> [2]f32 {
	ref := _s2d_ref_size()
	return (canvas_pt - ref * 0.5) / engine.PIXELS_PER_UNIT
}

// Fit the reference 2D canvas comfortably inside `view_size`.
@(private = "file")
_s2d_fit_canvas :: proc(view_size: im.Vec2) {
	ref := _s2d_ref_size()
	_s2d_pan = ref * 0.5
	if view_size.x > 64 && view_size.y > 64 {
		zx := (view_size.x - 80) / max(ref.x, 1)
		zy := (view_size.y - 80) / max(ref.y, 1)
		_s2d_zoom = clamp(min(zx, zy), 0.10, 4.0)
	} else {
		_s2d_zoom = 0.55
	}
}

// Find the active Canvas in the current scene (pinned Canvas, selected node's Canvas, or first enabled Canvas).
@(private = "file")
_s2d_active_canvas :: proc() -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil do return {}
	if _s2d_pinned_canvas != {} && engine.pool_valid(&w.transforms, engine.Handle(_s2d_pinned_canvas)) {
		if _, c := engine.transform_get_comp(_s2d_pinned_canvas, engine.Canvas); c != nil && c.enabled {
			return _s2d_pinned_canvas
		}
	}
	active_h := engine.inspector_active_selection()
	if active_h != {} && engine.pool_valid(&w.transforms, engine.Handle(active_h)) {
		if ch := engine.canvas_of(active_h); ch != {} do return ch
	}
	it := engine.pool_iterator(engine.canvases(w))
	for c, _ in engine.pool_next(&it) {
		ch := engine.Transform_Handle(c.owner)
		if c.enabled && engine.transform_active_in_hierarchy(ch) {
			return ch
		}
	}
	return {}
}

// Resolve the Scene Capture Camera (`_s2d_capture_cam_h`, active `Canvas.render_camera`, selected `Camera`, or `camera_active`).
@(private = "file")
_s2d_resolve_capture_camera :: proc() -> (cam_h: engine.Transform_Handle, cam: ^engine.Camera) {
	w := engine.ctx_world()
	if w == nil do return {}, nil

	if _s2d_capture_cam_h != {} && engine.pool_valid(&w.transforms, engine.Handle(_s2d_capture_cam_h)) {
		if _, c := engine.transform_get_comp(_s2d_capture_cam_h, engine.Camera); c != nil {
			return _s2d_capture_cam_h, c
		}
	}

	canvas_h := _s2d_active_canvas()
	if canvas_h != {} {
		if _, cv := engine.transform_get_comp(canvas_h, engine.Canvas); cv != nil {
			rc_h := engine.Transform_Handle(cv.render_camera.handle)
			if rc_h != {} && engine.pool_valid(&w.transforms, engine.Handle(rc_h)) {
				if _, c := engine.transform_get_comp(rc_h, engine.Camera); c != nil {
					return rc_h, c
				}
			}
		}
	}

	active_h := engine.inspector_active_selection()
	if active_h != {} && engine.pool_valid(&w.transforms, engine.Handle(active_h)) {
		if _, c := engine.transform_get_comp(active_h, engine.Camera); c != nil {
			return active_h, c
		}
	}

	if ac := engine.camera_active(); ac != nil {
		return engine.Transform_Handle(ac.owner), ac
	}
	return {}, nil
}

// One-click generator: creates an Orthographic 2D Scene Capture Camera (`Camera2D_Capture`)
// sized to match the reference 2D canvas at 100 PPU and hooks it to `Scene 2D` and `Canvas.render_camera`.
@(private = "file")
_s2d_create_capture_camera_2d :: proc() -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	w := engine.ctx_world()
	if scene == nil || w == nil do return {}

	root_h := engine.Transform_Handle(scene.root.handle)
	g := undo.group_begin("Create Scene Capture Camera 2D")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	cam_h := engine.transform_new("Camera2D_Capture", root_h)
	undo.record_create(cam_h, root_h)
	engine.transform_ensure_unique_name(cam_h)

	spawn_w := _s2d_canvas_to_world(_s2d_pan)
	if t := engine.pool_get(&w.transforms, engine.Handle(cam_h)); t != nil {
		t.position = {spawn_w.x, spawn_w.y, 10.0}
		t.rotation = engine.QUAT_IDENTITY
		t.scale    = {1, 1, 1}
	}

	owned, ptr := engine.transform_add_comp(cam_h, .Camera)
	if cam := cast(^engine.Camera)ptr; cam != nil {
		ref := _s2d_ref_size()
		cam.projection        = .Orthographic
		cam.orthographic_size = max(ref.y / (2.0 * engine.PIXELS_PER_UNIT), 1.0)
		cam.near_clip         = -100.0
		cam.far_clip          = 1000.0
		cam.clear_color       = {0.10, 0.12, 0.16, 1.0}
	}
	if t_curr := engine.pool_get(&w.transforms, engine.Handle(cam_h)); t_curr != nil {
		undo.record_add_component(cam_h, owned.handle, len(t_curr.components) - 1)
	}

	_s2d_capture_cam_h = cam_h
	_s2d_show_capture_cam_gizmo = true

	// Also hook to active Canvas if present
	if canvas_h := _s2d_active_canvas(); canvas_h != {} {
		if _, cv := engine.transform_get_comp(canvas_h, engine.Canvas); cv != nil {
			cv.render_camera = engine.Ref_Local{handle = engine.Handle(cam_h)}
		}
	}

	scene.dirty = true
	undo.group_commit(&g)
	engine.inspector_request_select(cam_h)
	return cam_h
}

@(private = "file")
_s2d_default_square_sprite_guid :: proc() -> engine.Asset_GUID {
	if g, err := uuid.read(_S2D_SQUARE_SPRITE_GUID_STR); err == nil {
		if _, ok := engine.texture_load(engine.Asset_GUID(g)); ok {
			return engine.Asset_GUID(g)
		}
	}
	return mhgui.white_texture_guid()
}

@(private = "file")
_s2d_default_circle_sprite_guid :: proc() -> engine.Asset_GUID {
	if g, err := uuid.read(_S2D_CIRCLE_SPRITE_GUID_STR); err == nil {
		if _, ok := engine.texture_load(engine.Asset_GUID(g)); ok {
			return engine.Asset_GUID(g)
		}
	}
	return _s2d_default_square_sprite_guid()
}

// Create a UI widget under `parent_h` (or active scene root) as an undoable step.
@(private = "file")
_s2d_create_widget :: proc(name: string, parent_h: engine.Transform_Handle, comp_keys: []engine.TypeKey, size_delta: [2]f32, default_text: string = "", anchored_pos: [2]f32 = {0, 0}) -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	if scene == nil do return {}
	w := engine.ctx_world()
	if w == nil do return {}

	actual_parent := parent_h
	if actual_parent == {} || !engine.pool_valid(&w.transforms, engine.Handle(actual_parent)) {
		actual_parent = engine.Transform_Handle(scene.root.handle)
	}

	g := undo.group_begin(fmt.tprintf("Create 2D UI %s", name))
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	newH := engine.transform_new(name, actual_parent)
	undo.record_create(newH, actual_parent)
	engine.transform_ensure_unique_name(newH)

	for key in comp_keys {
		owned, ptr := engine.transform_add_comp(newH, key)
		if ptr != nil {
			if key == .RectTransform {
				if rt := cast(^engine.RectTransform)ptr; rt != nil {
					rt.anchor_min = {0.5, 0.5}
					rt.anchor_max = {0.5, 0.5}
					rt.pivot = {0.5, 0.5}
					rt.anchored_position = {anchored_pos.x, anchored_pos.y, 0}
					rt.size_delta = size_delta
					rt.z_index = 0
				}
			} else if key == .Text {
				if txt := cast(^text_pkg.Text)ptr; txt != nil {
					if len(txt.text) > 0 do delete(txt.text)
					txt.text = strings.clone(len(default_text) > 0 ? default_text : "Text")
					txt.font = text_pkg.default_font_guid()
					txt.material = text_pkg.default_material_guid()
				}
			}
		}
		t_curr := engine.pool_get(&w.transforms, engine.Handle(newH))
		if t_curr != nil {
			undo.record_add_component(newH, owned.handle, len(t_curr.components) - 1)
		}
	}

	scene.dirty = true
	undo.group_commit(&g)
	engine.inspector_request_select(newH)
	return newH
}

// Create a Godot-style 2D Game World node (`Sprite2D`, `RigidBody2D`, `StaticBody2D`, `Character2D`).
@(private = "file")
_S2D_Node2D_Preset :: enum u8 {
	Sprite2D,
	RigidBody2D_Box,
	RigidBody2D_Circle,
	StaticBody2D_Platform,
	Character2D_Capsule,
}

@(private = "file")
_s2d_create_game_node_2d :: proc(preset: _S2D_Node2D_Preset, world_pos: [2]f32 = {0, 0}) -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	if scene == nil do return {}
	w := engine.ctx_world()
	if w == nil do return {}

	root_h := engine.Transform_Handle(scene.root.handle)
	name := "Sprite2D"
	scale := [3]f32{1, 1, 1}
	color := [4]f32{0.25, 0.78, 0.96, 1.0}
	use_circle_tex := false

	switch preset {
	case .Sprite2D:
		name = "Sprite2D"
		color = {0.28, 0.82, 0.96, 1.0}
	case .RigidBody2D_Box:
		name = "RigidBody2D_Box"
		color = {0.92, 0.56, 0.22, 1.0}
	case .RigidBody2D_Circle:
		name = "RigidBody2D_Ball"
		color = {0.96, 0.84, 0.26, 1.0}
		use_circle_tex = true
	case .StaticBody2D_Platform:
		name = "StaticBody2D_Platform"
		scale = {8.0, 0.6, 1.0}
		color = {0.34, 0.42, 0.52, 1.0}
	case .Character2D_Capsule:
		name = "Character2D"
		scale = {0.8, 1.6, 1.0}
		color = {0.28, 0.88, 0.58, 1.0}
	}

	g := undo.group_begin(fmt.tprintf("Create 2D Node %s", name))
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	newH := engine.transform_new(name, root_h)
	undo.record_create(newH, root_h)
	engine.transform_ensure_unique_name(newH)

	if t := engine.pool_get(&w.transforms, engine.Handle(newH)); t != nil {
		t.position = {world_pos.x, world_pos.y, 0}
		t.scale = scale
	}

	add_comp :: proc(w: ^engine.World, tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
		owned, ptr := engine.transform_add_comp(tH, key)
		if t_curr := engine.pool_get(&w.transforms, engine.Handle(tH)); t_curr != nil {
			undo.record_add_component(tH, owned.handle, len(t_curr.components) - 1)
		}
		return ptr
	}

	if sr := cast(^sprites.SpriteRenderer)add_comp(w, newH, .SpriteRenderer); sr != nil {
		sr.sprite.guid = use_circle_tex ? _s2d_default_circle_sprite_guid() : _s2d_default_square_sprite_guid()
		sr.sprite.local_id = 0
		sr.color = color
		// If fallback texture is 1x1 white.png (100 PPU), scale up so 1m = 100px
		if sr.sprite.guid == mhgui.white_texture_guid() {
			if t := engine.pool_get(&w.transforms, engine.Handle(newH)); t != nil {
				t.scale.x *= 100.0
				t.scale.y *= 100.0
			}
		}
	}

	switch preset {
	case .Sprite2D:
	case .RigidBody2D_Box:
		if rb := cast(^physics2d.Rigidbody2D)add_comp(w, newH, .Rigidbody2D); rb != nil {
			rb.body_type = .Dynamic
			rb.gravity_scale = 1.0
		}
		if bc := cast(^physics2d.BoxCollider2D)add_comp(w, newH, .BoxCollider2D); bc != nil {
			bc.size = {1, 1}
			bc.density = 1.0
			bc.friction = 0.6
		}
	case .RigidBody2D_Circle:
		if rb := cast(^physics2d.Rigidbody2D)add_comp(w, newH, .Rigidbody2D); rb != nil {
			rb.body_type = .Dynamic
			rb.gravity_scale = 1.0
		}
		if cc := cast(^physics2d.CircleCollider2D)add_comp(w, newH, .CircleCollider2D); cc != nil {
			cc.radius = 0.5
			cc.density = 1.0
			cc.friction = 0.5
			cc.bounciness = 0.45
		}
	case .StaticBody2D_Platform:
		if bc := cast(^physics2d.BoxCollider2D)add_comp(w, newH, .BoxCollider2D); bc != nil {
			bc.size = {1, 1}
			bc.density = 1.0
			bc.friction = 0.7
		}
	case .Character2D_Capsule:
		if rb := cast(^physics2d.Rigidbody2D)add_comp(w, newH, .Rigidbody2D); rb != nil {
			rb.body_type = .Dynamic
			rb.gravity_scale = 1.0
			rb.fixed_rotation = true
		}
		if cap := cast(^physics2d.CapsuleCollider2D)add_comp(w, newH, .CapsuleCollider2D); cap != nil {
			cap.size = {1, 1}
			cap.direction = .Vertical
			cap.density = 1.0
			cap.friction = 0.2
		}
	}

	scene.dirty = true
	undo.group_commit(&g)
	engine.inspector_request_select(newH)
	return newH
}

// One-click generator: build a playable 2D Physics Arena (Ground, Ramp, Boxes, Balls)
@(private = "file")
_s2d_build_physics_arena_template :: proc() {
	_s2d_create_game_node_2d(.StaticBody2D_Platform, {0, -3.6})
	ramp_h := _s2d_create_game_node_2d(.StaticBody2D_Platform, {-2.2, -0.8})
	if w := engine.ctx_world(); w != nil && ramp_h != {} {
		if t := engine.pool_get(&w.transforms, engine.Handle(ramp_h)); t != nil {
			t.scale = {4.5, 0.35, 1.0}
			t.rotation = engine.quat_from_euler_xyz(0, 0, -16.0)
		}
	}
	_s2d_create_game_node_2d(.RigidBody2D_Box, {-2.8, 2.4})
	_s2d_create_game_node_2d(.RigidBody2D_Box, {-2.1, 3.8})
	_s2d_create_game_node_2d(.RigidBody2D_Circle, {-3.2, 4.5})
	_s2d_create_game_node_2d(.Character2D_Capsule, {2.4, -1.5})
}

// Helper to create a styled UI Button with label inside a Menu Canvas
@(private = "file")
_s2d_create_styled_button :: proc(name, label: string, parent_h: engine.Transform_Handle, pos, size: [2]f32, bg_col: [4]f32, z_idx: i32 = 2) -> engine.Transform_Handle {
	btn_h := _s2d_create_widget(name, parent_h, {.RectTransform, .CanvasRenderer, .Image, .Button}, size, "", pos)
	if btn_h == {} do return {}
	if _, rt := engine.transform_get_comp(btn_h, engine.RectTransform); rt != nil {
		rt.z_index = z_idx
	}
	if _, img := engine.transform_get_comp(btn_h, mhgui.Image); img != nil {
		img.color = bg_col
	}
	if _, btn := engine.transform_get_comp(btn_h, mhgui.Button); btn != nil {
		btn.colors.normal = {1, 1, 1, 1}
		btn.colors.highlighted = {1.18, 1.22, 1.28, 1}
		btn.colors.pressed = {0.72, 0.82, 0.95, 1}
	}
	lbl_h := _s2d_create_widget("Label", btn_h, {.RectTransform, .CanvasRenderer, .Text}, {0, 0}, label)
	if lbl_h != {} {
		if _, lrt := engine.transform_get_comp(lbl_h, engine.RectTransform); lrt != nil {
			lrt.anchor_min = {0, 0}
			lrt.anchor_max = {1, 1}
			lrt.size_delta = {0, 0}
			lrt.z_index = z_idx + 1
		}
		if _, ltxt := engine.transform_get_comp(lbl_h, text_pkg.Text); ltxt != nil {
			ltxt.font_size = 20
			ltxt.horizontal_alignment = .Center
			ltxt.vertical_alignment = .Middle
			ltxt.color = {0.92, 0.96, 1.0, 1.0}
		}
	}
	return btn_h
}

// One-click generator: build an inspectable Godot-style QuickMenu & Settings Canvas hierarchy
// directly inside the active scene so the user can edit or customize it as a Scene 2D Menu!
@(private = "file")
_s2d_build_quickmenu_canvas_template :: proc(view_size: im.Vec2) {
	canvas_h := _s2d_active_canvas()
	if canvas_h == {} {
		canvas_h = _s2d_create_widget("QuickMenu_Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, _s2d_ref_size())
		_s2d_fit_canvas(view_size)
	}
	if canvas_h == {} do return

	// 1. Left Sidebar Panel
	sidebar_h := _s2d_create_widget("Sidebar_Panel", canvas_h, {.RectTransform, .CanvasRenderer, .Image}, {340, 680}, "", {-580, 0})
	if sidebar_h != {} {
		if _, rt := engine.transform_get_comp(sidebar_h, engine.RectTransform); rt != nil do rt.z_index = 1
		if _, img := engine.transform_get_comp(sidebar_h, mhgui.Image); img != nil {
			img.color = {0.06, 0.08, 0.12, 0.94}
		}
		hdr_h := _s2d_create_widget("Menu_Title", sidebar_h, {.RectTransform, .CanvasRenderer, .Text}, {300, 44}, "HAATI // QUICK MENU", {0, 290})
		if _, txt := engine.transform_get_comp(hdr_h, text_pkg.Text); txt != nil {
			txt.font_size = 24
			txt.horizontal_alignment = .Center
			txt.color = {0.22, 0.86, 1.0, 1.0}
		}
		_s2d_create_styled_button("Btn_Resume", "RESUME GAME", sidebar_h, {0, 210}, {290, 46}, {0.12, 0.20, 0.30, 0.96}, 2)
		_s2d_create_styled_button("Btn_Settings", "SETTINGS", sidebar_h, {0, 150}, {290, 46}, {0.15, 0.32, 0.46, 0.96}, 2)
		_s2d_create_styled_button("Btn_DebugCam", "DEBUG FREE CAM", sidebar_h, {0, 90}, {290, 46}, {0.12, 0.24, 0.34, 0.96}, 2)
		_s2d_create_styled_button("Btn_Console", "DEV CONSOLE (~)", sidebar_h, {0, 30}, {290, 46}, {0.12, 0.20, 0.30, 0.96}, 2)
		_s2d_create_styled_button("Btn_SpawnDummy", "SPAWN RAGDOLL BUTTON", sidebar_h, {0, -30}, {290, 46}, {0.16, 0.22, 0.32, 0.96}, 2)
		_s2d_create_styled_button("Btn_Quit", "QUIT TO DESKTOP", sidebar_h, {0, -260}, {290, 46}, {0.38, 0.12, 0.14, 0.96}, 2)
	}

	// 2. Right Settings Content Panel
	content_h := _s2d_create_widget("Settings_Panel", canvas_h, {.RectTransform, .CanvasRenderer, .Image}, {780, 680}, "", {180, 0})
	if content_h != {} {
		if _, rt := engine.transform_get_comp(content_h, engine.RectTransform); rt != nil do rt.z_index = 1
		if _, img := engine.transform_get_comp(content_h, mhgui.Image); img != nil {
			img.color = {0.07, 0.09, 0.14, 0.94}
		}
		sub_h := _s2d_create_widget("Settings_Header", content_h, {.RectTransform, .CanvasRenderer, .Text}, {720, 40}, "CAMERA, DISPLAY & CONSOLE SETTINGS", {0, 290})
		if _, txt := engine.transform_get_comp(sub_h, text_pkg.Text); txt != nil {
			txt.font_size = 22
			txt.horizontal_alignment = .Center
			txt.color = {0.22, 0.86, 1.0, 1.0}
		}
		_s2d_create_slider_row_widget(content_h, "Row_CameraFOV", "Camera Field of View (deg)", "103.0", {0, 215}, 0.65)
		_s2d_create_slider_row_widget(content_h, "Row_MouseSens", "Master Mouse Multiplier", "1.00x", {0, 155}, 0.50)
		_s2d_create_slider_row_widget(content_h, "Row_MouseYawMult", "Mouse Yaw Mult (Horizontal)", "1.00x", {0, 95}, 0.50)
		_s2d_create_slider_row_widget(content_h, "Row_MousePitchMult", "Mouse Pitch Mult (Vertical)", "0.85x", {0, 35}, 0.42)
		_s2d_create_slider_row_widget(content_h, "Row_FlySpeed", "Debug Free-Cam Speed (m/s)", "12.0", {0, -25}, 0.35)
		_s2d_create_toggle_row_widget(content_h, "Row_EnableConsole", "Enable Developer Console (~ / Backtick)", {0, -85}, true)
		_s2d_create_toggle_row_widget(content_h, "Row_DebugCamActive", "Activate 6DOF Debug Free-Cam", {0, -145}, false)
		_s2d_create_styled_button("Btn_ApplyGraphics", "APPLY GRAPHICS", content_h, {220, -270}, {240, 44}, {0.14, 0.48, 0.36, 0.98}, 3)
	}
	engine.inspector_request_select(canvas_h)
}

@(private = "file")
_s2d_create_slider_row_widget :: proc(parent_h: engine.Transform_Handle, name, label, val_str: string, pos: [2]f32, fill_frac: f32) -> engine.Transform_Handle {
	row_h := _s2d_create_widget(name, parent_h, {.RectTransform, .CanvasRenderer, .Image}, {700, 52}, "", pos)
	if row_h == {} do return {}
	if _, rt := engine.transform_get_comp(row_h, engine.RectTransform); rt != nil do rt.z_index = 2
	if _, img := engine.transform_get_comp(row_h, mhgui.Image); img != nil do img.color = {0.10, 0.13, 0.19, 0.92}

	lbl_h := _s2d_create_widget("Label", row_h, {.RectTransform, .CanvasRenderer, .Text}, {340, 40}, label, {-160, 0})
	if _, rt := engine.transform_get_comp(lbl_h, engine.RectTransform); rt != nil do rt.z_index = 3
	if _, txt := engine.transform_get_comp(lbl_h, text_pkg.Text); txt != nil {
		txt.font_size = 18
		txt.vertical_alignment = .Middle
	}

	track_w :: f32(220.0)
	track_h := _s2d_create_widget("SliderTrack", row_h, {.RectTransform, .CanvasRenderer, .Image}, {track_w, 14}, "", {140, 0})
	if _, rt := engine.transform_get_comp(track_h, engine.RectTransform); rt != nil do rt.z_index = 3
	if _, img := engine.transform_get_comp(track_h, mhgui.Image); img != nil do img.color = {0.04, 0.06, 0.09, 1.0}

	fw := clamp(fill_frac, 0.05, 1.0) * track_w
	fill_h := _s2d_create_widget("SliderFill", track_h, {.RectTransform, .CanvasRenderer, .Image}, {fw, 14}, "", {(fw - track_w) * 0.5, 0})
	if _, rt := engine.transform_get_comp(fill_h, engine.RectTransform); rt != nil do rt.z_index = 4
	if _, img := engine.transform_get_comp(fill_h, mhgui.Image); img != nil do img.color = {0.20, 0.78, 0.98, 1.0}

	val_h := _s2d_create_widget("ValueText", row_h, {.RectTransform, .CanvasRenderer, .Text}, {70, 40}, val_str, {295, 0})
	if _, rt := engine.transform_get_comp(val_h, engine.RectTransform); rt != nil do rt.z_index = 3
	if _, txt := engine.transform_get_comp(val_h, text_pkg.Text); txt != nil {
		txt.font_size = 18
		txt.horizontal_alignment = .Right
		txt.vertical_alignment = .Middle
		txt.color = {0.22, 0.88, 1.0, 1.0}
	}
	return row_h
}

@(private = "file")
_s2d_create_toggle_row_widget :: proc(parent_h: engine.Transform_Handle, name, label: string, pos: [2]f32, checked: bool) -> engine.Transform_Handle {
	row_h := _s2d_create_widget(name, parent_h, {.RectTransform, .CanvasRenderer, .Image, .Button}, {700, 52}, "", pos)
	if row_h == {} do return {}
	if _, rt := engine.transform_get_comp(row_h, engine.RectTransform); rt != nil do rt.z_index = 2
	if _, img := engine.transform_get_comp(row_h, mhgui.Image); img != nil do img.color = {0.10, 0.13, 0.19, 0.92}

	lbl_h := _s2d_create_widget("Label", row_h, {.RectTransform, .CanvasRenderer, .Text}, {460, 40}, label, {-100, 0})
	if _, rt := engine.transform_get_comp(lbl_h, engine.RectTransform); rt != nil do rt.z_index = 3
	if _, txt := engine.transform_get_comp(lbl_h, text_pkg.Text); txt != nil {
		txt.font_size = 18
		txt.vertical_alignment = .Middle
	}

	box_h := _s2d_create_widget("CheckBox", row_h, {.RectTransform, .CanvasRenderer, .Image}, {28, 28}, "", {290, 0})
	if _, rt := engine.transform_get_comp(box_h, engine.RectTransform); rt != nil do rt.z_index = 3
	if _, img := engine.transform_get_comp(box_h, mhgui.Image); img != nil {
		img.color = checked ? {0.18, 0.78, 0.52, 1.0} : {0.18, 0.22, 0.28, 1.0}
	}
	return row_h
}

// Start / Stop in-viewport 2D Physics Simulation inside Scene 2D
@(private = "file")
_s2d_start_physics_sim :: proc() {
	if _s2d_sim_running do return
	w := engine.ctx_world()
	if w == nil do return
	clear(&_s2d_sim_snapshots)
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		h_typed := h
		h_typed.type_key = .Transform
		tH := engine.Transform_Handle(h_typed)
		append(&_s2d_sim_snapshots, _S2D_Sim_Snapshot{
			tH       = tH,
			position = t.position,
			rotation = t.rotation,
			scale    = t.scale,
		})
	}
	_s2d_sim_accum = 0.0
	_s2d_sim_running = true
}

@(private = "file")
_s2d_stop_physics_sim :: proc() {
	if !_s2d_sim_running do return
	_s2d_sim_running = false
	w := engine.ctx_world()
	if w == nil do return

	// Clean up live Box2D bodies/shapes so next run starts cleanly from authored state
	if rb_pool := physics2d.rigidbody2_ds(w); rb_pool != nil {
		it := engine.pool_iterator(rb_pool)
		for rb, _ in engine.pool_next(&it) {
			physics2d.on_destroy_Rigidbody2D(rb)
		}
	}
	if bc_pool := physics2d.box_collider2_ds(w); bc_pool != nil {
		it := engine.pool_iterator(bc_pool)
		for bc, _ in engine.pool_next(&it) {
			physics2d.on_destroy_BoxCollider2D(bc)
		}
	}
	if cc_pool := physics2d.circle_collider2_ds(w); cc_pool != nil {
		it := engine.pool_iterator(cc_pool)
		for cc, _ in engine.pool_next(&it) {
			physics2d.on_destroy_CircleCollider2D(cc)
		}
	}
	if cap_pool := physics2d.capsule_collider2_ds(w); cap_pool != nil {
		it := engine.pool_iterator(cap_pool)
		for cap, _ in engine.pool_next(&it) {
			physics2d.on_destroy_CapsuleCollider2D(cap)
		}
	}

	// Restore snapshotted transforms
	for snap in _s2d_sim_snapshots {
		if t := engine.pool_get(&w.transforms, engine.Handle(snap.tH)); t != nil {
			t.position = snap.position
			t.rotation = snap.rotation
			t.scale = snap.scale
		}
	}
	clear(&_s2d_sim_snapshots)
}

// Resolve the parent rect of `tH` directly inside the Scene 2D reference canvas
// so anchor presets and offsets always match Scene 2D's exact canvas dimensions.
@(private = "file")
_s2d_parent_rect :: proc(tH: engine.Transform_Handle) -> (parent_rect: engine.Rect, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return {}, false
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, false
	canvas_h := engine.canvas_of(tH)
	if canvas_h == {} || canvas_h == tH do return {}, false
	parent_tH := engine.Transform_Handle(t.parent.handle)
	root_rect := engine.Rect{pos = {0, 0}, size = _s2d_ref_size()}
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas_h, root_rect, &nodes)
	for n in nodes {
		if n.tH == parent_tH {
			return n.rect, true
		}
	}
	return root_rect, true
}

@(private = "file")
_s2d_on_pick_preset :: proc(
	user_data: rawptr,
	_: int,
	_: int,
	preset: engine.UI_Anchor_Preset,
	_: [2]f32,
	_: [2]f32,
	_: bool,
	set_position: bool,
) {
	if user_data == nil do return
	th := (^engine.Transform_Handle)(user_data)^
	_s2d_apply_preset(th, preset, set_position)
}

// Apply a `UI_Anchor_Preset` to `tH` with undo recording.
@(private = "file")
_s2d_apply_preset :: proc(tH: engine.Transform_Handle, preset: engine.UI_Anchor_Preset, snap_to_anchors: bool) {
	owned, rt := engine.transform_get_comp(tH, engine.RectTransform)
	if rt == nil do return
	parent_rect, ok := _s2d_parent_rect(tH)
	if !ok do return

	sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Set 2D Anchor Preset")
	engine.rect_transform_apply_preset(rt, parent_rect, preset, keep_rect = !snap_to_anchors)
	undo.edit_session_end(&sess)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Dual-Pass Offscreen Renderer with Layer Filtering & Scene Capture Camera Hook:
// - Pass 1 renders 2D World Space (`SpriteRenderer`, particles, or Scene Capture Camera view).
//   By default `meshes = false` so 3D scene meshes never bleed into Scene 2D unless enabled!
// - Pass 2 renders 2D UI Canvas Space (`[0..rw] x [0..rh]` px) at near-plane depth (`z = 9.98`)
//   so UI Panels, Buttons, and SDF Text are never occluded by depth!
@(private = "file")
_s2d_render_offscreen :: proc(ref_w, ref_h: i32) {
	if scene_2d_rt == nil || ref_w < 1 || ref_h < 1 do return
	gfx.rt_resize(scene_2d_rt, ref_w, ref_h)

	rw := f32(ref_w)
	rh := f32(ref_h)
	half_w := rw * 0.5
	half_h := rh * 0.5

	// Pass 1: 2D World Camera or hooked Scene Capture Camera
	world_half_w := half_w / engine.PIXELS_PER_UNIT
	world_half_h := half_h / engine.PIXELS_PER_UNIT
	cam_pos_world := [3]f32{0, 0, 10.0}
	view_mat_world := linalg.matrix4_look_at_f32(cam_pos_world, {0, 0, 0}, {0, 1, 0})
	proj_mat_world := gfx.matrix4_ortho_z01(-world_half_w, world_half_w, -world_half_h, world_half_h, -1000.0, 1000.0)
	rv_world := engine.render_view_make(view_mat_world, proj_mat_world, rw, rh, ~u32(0), .SceneView)

	clear_col := [4]f32{0.11, 0.12, 0.15, 1.0}
	include_meshes := _s2d_include_3d_meshes
	if _s2d_render_mode == .Scene_Capture_Cam {
		if _, cap_cam := _s2d_resolve_capture_camera(); cap_cam != nil {
			rv_world = engine.camera_render_view(cap_cam, rw, rh)
			rv_world.kind = .SceneView
			clear_col = cap_cam.clear_color
			if cap_cam.projection == .Perspective {
				include_meshes = true
			}
		}
	}

	// Pass 2: 2D UI Canvas Camera (spanning [0..rw] x [0..rh] pixels, near=0.01..far=2000)
	cam_pos_ui := [3]f32{half_w, half_h, 10.0}
	view_mat_ui := linalg.matrix4_look_at_f32(cam_pos_ui, {half_w, half_h, 0.0}, {0, 1, 0})
	proj_mat_ui := gfx.matrix4_ortho_z01(-half_w, half_w, -half_h, half_h, 0.01, 2000.0)
	rv_ui := engine.render_view_make(view_mat_ui, proj_mat_ui, rw, rh, ~u32(0), .SceneView)

	gfx.pass_begin_target(scene_2d_rt, clear_col)
	gfx.set_post_fx(gfx.POST_FX_2D_DEFAULT)

	// Execute Pass 1 (2D World Sprites / Scene Capture Camera; skipped in UI_Canvas_Only mode)
	if _s2d_render_mode != .UI_Canvas_Only {
		engine.canvas_set_scene_2d_viewport({rw, rh}, false)
		gfx.set_view_proj(rv_world.view_proj, rv_world.cam_pos)
		world_cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
		engine.render_collect_commands(rv_world, &world_cmds, meshes = include_meshes, canvases = false)
		engine.render_execute(rv_world, world_cmds[:])
	}

	// Execute Pass 2 (2D UI Canvases in [0..rw] x [0..rh]; skipped in World_2D_Only or Void_QuickMenu_Only preview)
	draw_canvas_pass := _s2d_render_mode != .World_2D_Only &&
	                    (!_s2d_live_menu_preview || _s2d_test_menu_source != .Void_QuickMenu_Only)
	if draw_canvas_pass {
		target_canvas := _s2d_isolate_selected_canvas ? _s2d_active_canvas() : {}
		engine.canvas_set_scene_2d_viewport({rw, rh}, true, target_canvas)
		gfx.set_view_proj(rv_ui.view_proj, rv_ui.cam_pos)
		ui_cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
		engine.canvas_collect_graphics(rv_ui, &ui_cmds)
		// Place all UI Canvas quads right at the near plane (`z = 9.98` in front of `cam_pos_ui.z = 10.0`)
		// so they have NDC depth ~0.000005 and are NEVER depth-occluded by Pass 1!
		for &cmd in ui_cmds {
			if dq, ok := &cmd.variant.(engine.Draw_Quad); ok {
				for &c in dq.corners {
					c.z = 9.98
				}
			}
		}
		engine.render_execute(rv_ui, ui_cmds[:])
		engine.canvas_set_scene_2d_viewport({rw, rh}, false)
	}

	gfx.pass_end()
}

// Draw the top toolbar inside the `Scene 2D` window.
@(private = "file")
_draw_scene_2d_toolbar :: proc(view_size: im.Vec2) {
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	active_h := engine.inspector_active_selection()
	canvas_h := _s2d_active_canvas()

	im.PushStyleVarImVec2(.FramePadding, {6, 4})
	defer im.PopStyleVar()

	// 1. Scene Kind Badge / Toggle (Scene2D vs Scene3D)
	if scene != nil {
		is_2d_scene := scene.scene_kind == .Scene2D
		if is_2d_scene {
			im.PushStyleColorImVec4(.Button, {0.16, 0.58, 0.44, 0.92})
		} else {
			im.PushStyleColorImVec4(.Button, {0.22, 0.30, 0.44, 0.88})
		}
		kind_label: cstring = is_2d_scene ? "Scene2D" : "Scene3D"
		if im.Button(fmt.ctprintf("%s %s##s2d_kind", icons.ICON_MD_LAYERS, kind_label)) {
			scene.scene_kind = is_2d_scene ? .Scene3D : .Scene2D
			scene.dirty = true
		}
		im.PopStyleColor()
		widgets.tooltip("Scene Type Declaration (Scene2D vs Scene3D): A Scene3D can import Scene2D assets via a Canvas component")
		im.SameLine(0, 4)
	}

	// 1b. Render Layer / View Mode & Scene Capture Camera Selector!
	render_mode_lbl: cstring = "View: 2D + Menu"
	switch _s2d_render_mode {
	case .World_2D_And_Canvas: render_mode_lbl = "View: 2D + Menu"
	case .UI_Canvas_Only:      render_mode_lbl = "View: Menu Only"
	case .World_2D_Only:       render_mode_lbl = "View: 2D World Only"
	case .Scene_Capture_Cam:   render_mode_lbl = "View: Capture Cam"
	}
	im.SetNextItemWidth(142)
	if im.BeginCombo("##s2d_render_mode_combo", render_mode_lbl, {}) {
		im.SeparatorText("What Part / Layer of Scene 2D to Render")
		if im.Selectable("2D World (Sprites & Physics2D) + UI Menu Canvas", _s2d_render_mode == .World_2D_And_Canvas) {
			_s2d_render_mode = .World_2D_And_Canvas
		}
		if im.Selectable("Menu / UI Canvas Only (Clean Menu Isolation)", _s2d_render_mode == .UI_Canvas_Only) {
			_s2d_render_mode = .UI_Canvas_Only
		}
		if im.Selectable("2D Game World Only (Hide UI Menu Overlays)", _s2d_render_mode == .World_2D_Only) {
			_s2d_render_mode = .World_2D_Only
		}
		if im.Selectable("Scene Capture Camera (Render Camera Hook)", _s2d_render_mode == .Scene_Capture_Cam) {
			_s2d_render_mode = .Scene_Capture_Cam
		}

		im.SeparatorText("Layer Isolation & Background Options")
		im.Checkbox("Isolate Active Canvas Only (Hide Other Canvases)", &_s2d_isolate_selected_canvas)
		im.Checkbox("Show Capture Camera Region Frame in 2D", &_s2d_show_capture_cam_gizmo)
		im.Checkbox("Include 3D Scene Meshes in Background", &_s2d_include_3d_meshes)

		im.SeparatorText("Scene Capture Camera Hook (Camera2D)")
		cap_h, cap_cam := _s2d_resolve_capture_camera()
		cap_name := "None (Auto)"
		if cap_h != {} && w != nil {
			if ct := engine.pool_get(&w.transforms, engine.Handle(cap_h)); ct != nil {
				cap_name = ct.name
			}
		}
		im.TextColored({0.25, 0.88, 1.0, 1.0}, "Active Capture Cam: %s", strings.clone_to_cstring(cap_name, context.temp_allocator))
		if w != nil {
			it_cam := engine.pool_iterator(engine.cameras(w))
			for cm, _ in engine.pool_next(&it_cam) {
				ch := engine.Transform_Handle(cm.owner)
				cname := "Camera"
				if ct := engine.pool_get(&w.transforms, engine.Handle(ch)); ct != nil do cname = ct.name
				proj_tag := cm.projection == .Orthographic ? "Ortho 2D" : "Persp 3D"
				if im.Selectable(fmt.ctprintf("Hook Camera: %s [%s]##cap_%d", cname, proj_tag, ch.index), ch == cap_h) {
					_s2d_capture_cam_h = ch
					if canvas_h != {} {
						if _, cv := engine.transform_get_comp(canvas_h, engine.Canvas); cv != nil {
							cv.render_camera = engine.Ref_Local{handle = engine.Handle(ch)}
						}
					}
				}
			}
		}
		if cap_cam != nil && cap_h != {} {
			if im.Button("Select Capture Camera in Inspector", {-1, 0}) {
				engine.inspector_request_select(cap_h)
			}
			if im.Button("Center 2D View on Capture Camera", {-1, 0}) {
				tw := engine.transform_world(cap_h)
				_s2d_pan = _s2d_world_to_canvas(tw.position.xy)
			}
		}
		if im.Button("+Create & Hook Orthographic Capture Camera 2D", {-1, 0}) {
			_s2d_create_capture_camera_2d()
		}
		im.EndCombo()
	}
	widgets.tooltip("Choose which part/layer of Scene 2D to render (2D+Menu, Menu Only, 2D World Only, or Scene Capture Camera) and configure the Capture Camera hook")
	im.SameLine(0, 6)

	// 2. Active Canvas Selector & Projection Mode Selector (ViewportHUD, CameraSpace, 3D Tracked, WorldSpace)
	if canvas_h == {} {
		im.PushStyleColorImVec4(.Button, {0.18, 0.65, 0.42, 0.95})
		im.PushStyleColorImVec4(.ButtonHovered, {0.24, 0.76, 0.50, 1.00})
		if im.Button(fmt.ctprintf("%s +Canvas", icons.ICON_MD_ADD)) {
			c_h := _s2d_create_widget("Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, _s2d_ref_size())
			if c_h != {} {
				_s2d_pinned_canvas = c_h
				_s2d_fit_canvas(view_size)
			}
		}
		im.PopStyleColor(2)
		widgets.tooltip("Create a new 2D Canvas root node in the active scene")
	} else if w != nil {
		_, c_comp := engine.transform_get_comp(canvas_h, engine.Canvas)
		c_name := "Canvas"
		if ct := engine.pool_get(&w.transforms, engine.Handle(canvas_h)); ct != nil {
			c_name = ct.name
		}
		im.SetNextItemWidth(135)
		if im.BeginCombo("##s2d_sel_canvas_combo", fmt.ctprintf("%s %s", icons.ICON_MD_LAYERS, c_name), {}) {
			im.SeparatorText("Select Active Scene Canvas / Menu")
			it_cv := engine.pool_iterator(engine.canvases(w))
			for cv, _ in engine.pool_next(&it_cv) {
				ch := engine.Transform_Handle(cv.owner)
				if !engine.pool_valid(&w.transforms, engine.Handle(ch)) do continue
				nm := "Canvas"
				if ct := engine.pool_get(&w.transforms, engine.Handle(ch)); ct != nil do nm = ct.name
				if im.Selectable(fmt.ctprintf("%s##cv_sel_%d", nm, ch.index), ch == canvas_h) {
					_s2d_pinned_canvas = ch
					engine.inspector_request_select(ch)
				}
			}
			im.Separator()
			if im.Selectable("+ Create New Canvas...", false) {
				new_c := _s2d_create_widget("Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, _s2d_ref_size())
				if new_c != {} {
					_s2d_pinned_canvas = new_c
					_s2d_fit_canvas(view_size)
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Select which Canvas in the scene to view and edit in Scene 2D")

		if c_comp != nil {
			im.SameLine(0, 4)
			mode_str: cstring = "ViewportHUD"
			#partial switch c_comp.render_mode {
			case .ScreenSpaceOverlay:   mode_str = "ViewportHUD"
			case .ScreenSpaceCamera:    mode_str = "CameraSpace"
			case .ScreenSpace3DTracked: mode_str = "3D Tracked"
			case .WorldSpace:           mode_str = "WorldSpace"
			}
			im.SetNextItemWidth(112)
			if im.BeginCombo("##s2d_canvas_mode", mode_str, {}) {
				if im.Selectable("ViewportHUD (Screen Overlay)", c_comp.render_mode == .ScreenSpaceOverlay) {
					c_comp.render_mode = .ScreenSpaceOverlay
					if scene != nil do scene.dirty = true
				}
				if im.Selectable("CameraSpace (Scene Capture Cam)", c_comp.render_mode == .ScreenSpaceCamera) {
					c_comp.render_mode = .ScreenSpaceCamera
					if c_comp.render_camera.handle == {} {
						if cap_h, _ := _s2d_resolve_capture_camera(); cap_h != {} {
							c_comp.render_camera = engine.Ref_Local{handle = engine.Handle(cap_h)}
						}
					}
					if scene != nil do scene.dirty = true
				}
				if im.Selectable("ScreenSpace3DTracked", c_comp.render_mode == .ScreenSpace3DTracked) {
					c_comp.render_mode = .ScreenSpace3DTracked
					if scene != nil do scene.dirty = true
				}
				if im.Selectable("WorldSpace (3D Plane)", c_comp.render_mode == .WorldSpace) {
					c_comp.render_mode = .WorldSpace
					if scene != nil do scene.dirty = true
				}
				im.EndCombo()
			}
			widgets.tooltip("Canvas Projection Mode: ViewportHUD, CameraSpace (hooked to Render Camera), ScreenSpace3DTracked, or WorldSpace")
		}
	}

	im.SameLine(0, 6)
	im.TextDisabled("|")
	im.SameLine(0, 6)

	// 3. One-Click 2D UI & Menu Creation Buttons + Menu Templates Popup
	target_parent := canvas_h
	if active_h != {} && canvas_h != {} && engine.canvas_of(active_h) == canvas_h {
		target_parent = active_h
	}

	ensure_parent :: proc(target_parent, canvas_h: engine.Transform_Handle, view_size: im.Vec2) -> engine.Transform_Handle {
		if target_parent != {} do return target_parent
		if canvas_h != {} do return canvas_h
		c_h := _s2d_create_widget("Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, _s2d_ref_size())
		_s2d_fit_canvas(view_size)
		return c_h
	}

	if im.Button(fmt.ctprintf("%s +Panel", icons.ICON_MD_CROP_FREE)) {
		p := ensure_parent(target_parent, canvas_h, view_size)
		panel_h := _s2d_create_widget("Panel", p, {.RectTransform, .CanvasRenderer, .Image}, {420, 280})
		if _, img := engine.transform_get_comp(panel_h, mhgui.Image); img != nil {
			img.color = {0.10, 0.13, 0.19, 0.92}
		}
	}
	widgets.tooltip("Add a 2D UI Panel container (RectTransform + CanvasRenderer + Image)")

	im.SameLine(0, 3)
	if im.Button(fmt.ctprintf("%s +Button", icons.ICON_MD_WIDGETS)) {
		p := ensure_parent(target_parent, canvas_h, view_size)
		_s2d_create_styled_button("Button", "Button", p, {0, 0}, {180, 48}, {0.18, 0.28, 0.40, 1.0}, 1)
	}
	widgets.tooltip("Add an interactive 2D UI Button with hover/press color transitions and a centered Text label")

	im.SameLine(0, 3)
	if im.Button(fmt.ctprintf("%s +Text", icons.ICON_MD_DESCRIPTION)) {
		p := ensure_parent(target_parent, canvas_h, view_size)
		_s2d_create_widget("Text", p, {.RectTransform, .CanvasRenderer, .Text}, {240, 48}, "New Text")
	}
	widgets.tooltip("Add a 2D UI Text label (RectTransform + CanvasRenderer + Text)")

	im.SameLine(0, 3)
	@(static) menu_tpl_popup_pos: im.Vec2
	im.PushStyleColorImVec4(.Button, {0.16, 0.36, 0.54, 0.94})
	if im.Button(fmt.ctprintf("%s +Menu Builder %s##s2d_menu_tpl", icons.ICON_MD_WIDGETS, icons.ICON_MD_ARROW_DROP_DOWN)) {
		menu_tpl_popup_pos = {im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
		im.OpenPopup("##s2d_menu_builder_popup")
	}
	im.PopStyleColor()
	widgets.tooltip("Menu Engine Builder: Generate complete QuickMenu Canvas, Sci-Fi Buttons, Sliders, Toggles, Image, or LayoutGroup")

	im.SetNextWindowPos(menu_tpl_popup_pos, .Appearing)
	if im.BeginPopup("##s2d_menu_builder_popup") {
		im.SeparatorText("Menu Engine Templates & Widgets")
		if im.MenuItem(fmt.ctprintf("%s  Build Full Godot QuickMenu & Settings Canvas", icons.ICON_MD_SETTINGS)) {
			_s2d_build_quickmenu_canvas_template(view_size)
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  +Sci-Fi Menu Button (Hover/Press Styled)", icons.ICON_MD_WIDGETS)) {
			p := ensure_parent(target_parent, canvas_h, view_size)
			_s2d_create_styled_button("SciFi_Button", "SCI-FI ACTION", p, {0, 0}, {260, 46}, {0.12, 0.22, 0.34, 0.96}, 2)
		}
		if im.MenuItem(fmt.ctprintf("%s  +Settings Slider Row (Label + Track + Fill + Value)", icons.ICON_MD_TUNE)) {
			p := ensure_parent(target_parent, canvas_h, view_size)
			_s2d_create_slider_row_widget(p, "Slider_Row", "Setting Parameter", "75%", {0, 0}, 0.75)
		}
		if im.MenuItem(fmt.ctprintf("%s  +Settings Toggle Checkbox Row", icons.ICON_MD_CHECK)) {
			p := ensure_parent(target_parent, canvas_h, view_size)
			_s2d_create_toggle_row_widget(p, "Toggle_Row", "Enable Feature Option", {0, 0}, true)
		}
		if im.MenuItem(fmt.ctprintf("%s  +UI Image / Icon Widget", icons.ICON_MD_IMAGE)) {
			p := ensure_parent(target_parent, canvas_h, view_size)
			_s2d_create_widget("Image", p, {.RectTransform, .CanvasRenderer, .Image}, {140, 140})
		}
		if im.MenuItem(fmt.ctprintf("%s  +UI LayoutGroup (Horizontal / Vertical / Grid)", icons.ICON_MD_ACCOUNT_TREE)) {
			p := ensure_parent(target_parent, canvas_h, view_size)
			_s2d_create_widget("LayoutGroup", p, {.RectTransform, .LayoutGroup}, {360, 240})
		}
		im.EndPopup()
	}

	// 4. Godot-Style 2D Game Engine Creation Dropdown & Physics Simulation Toggle
	im.SameLine(0, 4)
	@(static) game2d_popup_pos: im.Vec2
	im.PushStyleColorImVec4(.Button, {0.20, 0.46, 0.30, 0.94})
	if im.Button(fmt.ctprintf("%s +2D Game Node %s##s2d_game_nodes", icons.ICON_MD_SPORTS_ESPORTS, icons.ICON_MD_ARROW_DROP_DOWN)) {
		game2d_popup_pos = {im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
		im.OpenPopup("##s2d_game2d_popup")
	}
	im.PopStyleColor()
	widgets.tooltip("Godot-Style 2D Game Engine Nodes: Create Sprite2D, RigidBody2D (Box/Circle), StaticBody2D Platform, Character2D, or a full 2D Physics Arena")

	im.SetNextWindowPos(game2d_popup_pos, .Appearing)
	if im.BeginPopup("##s2d_game2d_popup") {
		spawn_w := _s2d_canvas_to_world(_s2d_pan)
		im.SeparatorText("Godot-Style 2D Game Nodes (1m = 100px)")
		if im.MenuItem(fmt.ctprintf("%s  +Sprite2D (Transform + SpriteRenderer)", icons.ICON_MD_IMAGE)) {
			_s2d_create_game_node_2d(.Sprite2D, spawn_w)
		}
		if im.MenuItem(fmt.ctprintf("%s  +RigidBody2D Box (Dynamic BoxCollider2D)", icons.ICON_MD_HEXAGON)) {
			_s2d_create_game_node_2d(.RigidBody2D_Box, spawn_w)
		}
		if im.MenuItem(fmt.ctprintf("%s  +RigidBody2D Ball (Dynamic CircleCollider2D)", icons.ICON_MD_PENTAGON)) {
			_s2d_create_game_node_2d(.RigidBody2D_Circle, spawn_w)
		}
		if im.MenuItem(fmt.ctprintf("%s  +StaticBody2D Platform / Ground (Static BoxCollider2D)", icons.ICON_MD_DRAG_HANDLE)) {
			_s2d_create_game_node_2d(.StaticBody2D_Platform, spawn_w)
		}
		if im.MenuItem(fmt.ctprintf("%s  +CharacterBody2D (CapsuleCollider2D, Fixed Rotation)", icons.ICON_MD_CATEGORY)) {
			_s2d_create_game_node_2d(.Character2D_Capsule, spawn_w)
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Build 2D Physics Arena Sample (Ground + Ramp + Bodies)", icons.ICON_MD_PLAY_CIRCLE)) {
			_s2d_build_physics_arena_template()
		}
		im.EndPopup()
	}

	// 4b. In-Viewport 2D Physics Simulation Toggle (`[Sim 2D]`)
	im.SameLine(0, 4)
	if _s2d_sim_running {
		im.PushStyleColorImVec4(.Button, {0.86, 0.36, 0.14, 0.98})
	} else {
		im.PushStyleColorImVec4(.Button, {0.18, 0.24, 0.32, 0.92})
	}
	sim_lbl: cstring = _s2d_sim_running ? fmt.ctprintf("%s Stop 2D Sim##s2d_sim", icons.ICON_MD_STOP) : fmt.ctprintf("%s Sim 2D##s2d_sim", icons.ICON_MD_PLAY_ARROW)
	if im.Button(sim_lbl) {
		if _s2d_sim_running {
			_s2d_stop_physics_sim()
		} else {
			_s2d_start_physics_sim()
		}
	}
	im.PopStyleColor()
	widgets.tooltip("Simulate 2D Physics (Box2D) live inside Scene 2D and restore transforms on stop")

	// 4c. Live Menu / QuickMenu Overlay Preview Toggle (`[Test Menu]`) + Menu Target Selector
	im.SameLine(0, 4)
	if _s2d_live_menu_preview {
		im.PushStyleColorImVec4(.Button, {0.14, 0.62, 0.78, 0.98})
	} else {
		im.PushStyleColorImVec4(.Button, {0.18, 0.24, 0.32, 0.92})
	}
	if im.Button(fmt.ctprintf("%s Test Menu##s2d_test_menu", icons.ICON_MD_ADS_CLICK)) {
		_s2d_live_menu_preview = !_s2d_live_menu_preview
		if !_s2d_live_menu_preview {
			_s2d_restore_canvas_btn_physics()
		}
	}
	im.PopStyleColor()
	widgets.tooltip("Interactive Menu Preview Mode: Test Scene Canvas Buttons (with Raked-Leaf button+text physics) and/or the Void QuickMenu & Developer Console (~) inside Scene 2D")

	im.SameLine(0, 2)
	@(static) test_menu_src_popup_pos: im.Vec2
	if im.Button(fmt.ctprintf("%s##s2d_test_menu_src_btn", icons.ICON_MD_ARROW_DROP_DOWN)) {
		test_menu_src_popup_pos = {im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
		im.OpenPopup("##s2d_test_menu_src_popup")
	}
	widgets.tooltip("Select WHICH Menu to test when 'Test Menu' is active (Scene Canvas UI, Void QuickMenu Overlay, or Both)")

	im.SetNextWindowPos(test_menu_src_popup_pos, .Appearing)
	if im.BeginPopup("##s2d_test_menu_src_popup") {
		im.SeparatorText("Select Active Menu for [Test Menu]")
		if im.Selectable("Both: Scene Canvas UI + Void QuickMenu Overlay", _s2d_test_menu_source == .Both_Canvas_And_QuickMenu) {
			_s2d_test_menu_source = .Both_Canvas_And_QuickMenu
			_s2d_live_menu_preview = true
		}
		if im.Selectable("Scene Canvas Menu Only (In-Scene UI Hierarchy)", _s2d_test_menu_source == .Scene_Canvas_Only) {
			_s2d_test_menu_source = .Scene_Canvas_Only
			_s2d_live_menu_preview = true
		}
		if im.Selectable("Void QuickMenu & Dev Console (~) Overlay Only", _s2d_test_menu_source == .Void_QuickMenu_Only) {
			_s2d_test_menu_source = .Void_QuickMenu_Only
			_s2d_live_menu_preview = true
		}
		im.EndPopup()
	}

	// 5. UMG Anchor Presets, Z-Index, and Inline Quick-Styling (Color + Text) for Selected Node
	if active_h != {} && w != nil && engine.pool_valid(&w.transforms, engine.Handle(active_h)) {
		owned_rt, rt := engine.transform_get_comp(active_h, engine.RectTransform)
		if rt != nil && active_h != canvas_h {
			im.SameLine(0, 6)
			im.TextDisabled("|")
			im.SameLine(0, 6)

			@(static) anchor_popup_pos: im.Vec2
			if im.Button(fmt.ctprintf("%s Anchors %s##s2d_anchors", icons.ICON_MD_GRID_ON, icons.ICON_MD_ARROW_DROP_DOWN)) {
				anchor_popup_pos = {im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
				im.OpenPopup("##s2d_anchor_presets_popup")
			}
			widgets.tooltip("UMG / Godot Anchor Presets (Default keeps widget position & size; hold Alt while clicking to snap widget onto anchor)")

			im.SetNextWindowPos(anchor_popup_pos, .Appearing)
			if im.BeginPopup("##s2d_anchor_presets_popup") {
				im.SeparatorText("UI Anchor Presets")
				pick_th := active_h
				draw_anchor_presets_grid(
					rt,
					"Default keeps position & size   Alt: snap onto anchors",
					_s2d_on_pick_preset,
					&pick_th,
				)
				im.EndPopup()
			}

			im.SameLine(0, 4)
			im.TextUnformatted("Z:")
			im.SameLine(0, 2)
			im.SetNextItemWidth(52)
			z_val := rt.z_index
			if im.DragInt("##s2d_z_index", &z_val, 1.0, -32768, 32767) {
				targets := [?]undo.Edit_Target{undo.edit_target_pooled(owned_rt.handle, &rt.z_index, typeid_of(i32))}
				sess := undo.edit_session_begin(targets[:], "Set UI Z Index")
				rt.z_index = z_val
				undo.edit_session_end(&sess)
				if scene != nil do scene.dirty = true
			}
			widgets.tooltip("Explicit integer Z-Index for 2D draw and hit-test sorting (higher renders on top)")
		}

		// Inline Color Swatch for `mhgui.Image` or `sprites.SpriteRenderer`
		if owned_img, img := engine.transform_get_comp(active_h, mhgui.Image); img != nil {
			im.SameLine(0, 4)
			col := img.color
			if im.ColorEdit4("##s2d_img_col", &col, {.NoInputs, .AlphaBar}) {
				targets := [?]undo.Edit_Target{undo.edit_target_pooled(owned_img.handle, &img.color, typeid_of([4]f32))}
				sess := undo.edit_session_begin(targets[:], "Set UI Image Color")
				img.color = col
				undo.edit_session_end(&sess)
				if scene != nil do scene.dirty = true
			}
			widgets.tooltip("Quick-Edit UI Image Color / Tint")
		} else if owned_sr, sr := engine.transform_get_comp(active_h, sprites.SpriteRenderer); sr != nil {
			im.SameLine(0, 4)
			col := sr.color
			if im.ColorEdit4("##s2d_sr_col", &col, {.NoInputs, .AlphaBar}) {
				targets := [?]undo.Edit_Target{undo.edit_target_pooled(owned_sr.handle, &sr.color, typeid_of([4]f32))}
				sess := undo.edit_session_begin(targets[:], "Set Sprite2D Color")
				sr.color = col
				undo.edit_session_end(&sess)
				if scene != nil do scene.dirty = true
			}
			widgets.tooltip("Quick-Edit Sprite2D Color / Tint")
		}

		// Inline Text String & Font Size editor for `text_pkg.Text` (or a Button's child Label)
		txt_tH := active_h
		_, txt_comp := engine.transform_get_comp(txt_tH, text_pkg.Text)
		if txt_comp == nil {
			if t := engine.pool_get(&w.transforms, engine.Handle(active_h)); t != nil {
				for child_ref in t.children {
					ch := engine.Transform_Handle(child_ref.handle)
					if _, ctxt := engine.transform_get_comp(ch, text_pkg.Text); ctxt != nil {
						txt_tH = ch
						txt_comp = ctxt
						break
					}
				}
			}
		}
		if txt_comp != nil {
			if _s2d_inline_text_last_tH != txt_tH {
				_s2d_inline_text_last_tH = txt_tH
				mem.zero(&_s2d_inline_text_buf, size_of(_s2d_inline_text_buf))
				n := min(len(txt_comp.text), len(_s2d_inline_text_buf) - 1)
				if n > 0 do mem.copy(&_s2d_inline_text_buf[0], raw_data(txt_comp.text), n)
			}
			im.SameLine(0, 4)
			im.SetNextItemWidth(120)
			if im.InputTextWithHint("##s2d_inline_txt", "Label text...", cstring(&_s2d_inline_text_buf[0]), len(_s2d_inline_text_buf), {}) {
				new_str := string(cstring(&_s2d_inline_text_buf[0]))
				if new_str != txt_comp.text {
					delete(txt_comp.text)
					txt_comp.text = strings.clone(new_str)
					if scene != nil do scene.dirty = true
				}
			}
			widgets.tooltip("Quick-Edit Text / Button Label string")
		}
	}

	im.SameLine(0, 6)
	im.TextDisabled("|")
	im.SameLine(0, 6)

	// 6. 2D AutoCAD Ruler, Collider Gizmo Toggle, Grid Toggle, and Reference Resolution
	ruler_on := _s2d_ruler_active
	if ruler_on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button(fmt.ctprintf("%s##s2d_ruler", icons.ICON_MD_STRAIGHTEN)) {
		_s2d_ruler_active = !_s2d_ruler_active
		if !_s2d_ruler_active {
			_s2d_ruler_dragging = false
			_s2d_ruler_has_cur = false
		}
	}
	if ruler_on do im.PopStyleColor()
	widgets.tooltip("2D Canvas AutoCAD Ruler (M): Measure all 3 triangle sides in pixels, angles, and area (P to pin)")

	im.SameLine(0, 3)
	col_on := _s2d_show_colliders
	if col_on do im.PushStyleColorImVec4(.Button, {0.20, 0.56, 0.32, 0.92})
	if im.Button(icons.ICON_MD_HEXAGON + "##s2d_colliders_btn") {
		_s2d_show_colliders = !_s2d_show_colliders
	}
	if col_on do im.PopStyleColor()
	widgets.tooltip("Toggle 2D Physics Collider Wireframes (BoxCollider2D, CircleCollider2D, CapsuleCollider2D)")

	im.SameLine(0, 3)
	grid_on := _s2d_show_grid
	if grid_on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button(icons.ICON_MD_GRID_ON + "##s2d_grid_btn") {
		_s2d_show_grid = !_s2d_show_grid
	}
	if grid_on do im.PopStyleColor()
	widgets.tooltip("Toggle 2D Canvas Blueprint Grid & Rule-of-Thirds Guides")

	im.SameLine(0, 4)
	res_list := SCENE_2D_RESOLUTIONS
	_s2d_res_index = clamp(_s2d_res_index, 0, len(res_list) - 1)
	is_custom_res := res_list[_s2d_res_index].w <= 0 || res_list[_s2d_res_index].h <= 0
	combo_label: cstring = is_custom_res ? fmt.ctprintf("Custom (%dx%d)", _s2d_custom_res.x, _s2d_custom_res.y) : res_list[_s2d_res_index].label
	im.SetNextItemWidth(145)
	if im.BeginCombo("##s2d_res_combo", combo_label, {}) {
		for r, idx in res_list {
			if im.Selectable(r.label, idx == _s2d_res_index) {
				if (r.w <= 0 || r.h <= 0) && !is_custom_res {
					prev_ref := _s2d_ref_size()
					_s2d_custom_res = {i32(prev_ref.x), i32(prev_ref.y)}
				}
				_s2d_res_index = idx
				_s2d_fit_canvas(view_size)
			}
		}
		im.Separator()
		im.TextDisabled("Custom Resolution (px):")
		cw := _s2d_custom_res.x
		ch := _s2d_custom_res.y
		im.SetNextItemWidth(72)
		w_ed := im.DragInt("##s2d_pop_cw", &cw, 1.0, 64, 8192, "%d W")
		im.SameLine(0, 4)
		im.TextDisabled("x")
		im.SameLine(0, 4)
		im.SetNextItemWidth(72)
		h_ed := im.DragInt("##s2d_pop_ch", &ch, 1.0, 64, 8192, "%d H")
		if w_ed || h_ed {
			_s2d_custom_res = {clamp(cw, 64, 8192), clamp(ch, 64, 8192)}
			_s2d_res_index = len(res_list) - 1
		}
		im.EndCombo()
	}
	widgets.tooltip("Reference 2D Canvas Resolution (Select a preset or choose Custom Resolution)")
}

// Draw top and left pixel rulers + 2D blueprint grid inside the `Scene 2D` viewport.
@(private = "file")
_draw_scene_2d_backdrop_and_rulers :: proc(dl: ^im.DrawList, view_min, view_max: im.Vec2) {
	view_size := view_max - view_min
	ref := _s2d_ref_size()

	// Backdrop fill
	im.DrawList_AddRectFilled(dl, view_min, view_max, im.GetColorU32ImVec4({0.08, 0.09, 0.11, 1.0}))

	// Choose grid step in canvas pixels based on zoom
	step_px: f32 = 100.0
	if _s2d_zoom > 2.0 {
		step_px = 20.0
	} else if _s2d_zoom > 0.8 {
		step_px = 50.0
	} else if _s2d_zoom < 0.25 {
		step_px = 200.0
	}

	c_min := _s2d_screen_to_canvas({view_min.x, view_max.y}, view_min, view_size)
	c_max := _s2d_screen_to_canvas({view_max.x, view_min.y}, view_min, view_size)

	if _s2d_show_grid {
		col_minor := im.GetColorU32ImVec4({0.18, 0.20, 0.25, 0.55})
		col_major := im.GetColorU32ImVec4({0.26, 0.30, 0.38, 0.75})

		x_start := math.floor(c_min.x / step_px) * step_px
		for x := x_start; x <= c_max.x; x += step_px {
			sx := _s2d_canvas_to_screen({x, 0}, view_min, view_size).x
			is_major := math.abs(math.mod(x, step_px * 2)) < 0.1
			im.DrawList_AddLine(dl, {sx, view_min.y}, {sx, view_max.y}, is_major ? col_major : col_minor, 1.0)
		}
		y_start := math.floor(c_min.y / step_px) * step_px
		for y := y_start; y <= c_max.y; y += step_px {
			sy := _s2d_canvas_to_screen({0, y}, view_min, view_size).y
			is_major := math.abs(math.mod(y, step_px * 2)) < 0.1
			im.DrawList_AddLine(dl, {view_min.x, sy}, {view_max.x, sy}, is_major ? col_major : col_minor, 1.0)
		}

		// Draw 2D World Origin Crosshair ({0,0} meters = center of reference canvas)
		orig_screen := _s2d_canvas_to_screen(ref * 0.5, view_min, view_size)
		im.DrawList_AddLine(dl, {orig_screen.x - 10, orig_screen.y}, {orig_screen.x + 10, orig_screen.y}, im.GetColorU32ImVec4({0.95, 0.35, 0.38, 0.75}), 1.5)
		im.DrawList_AddLine(dl, {orig_screen.x, orig_screen.y - 10}, {orig_screen.x, orig_screen.y + 10}, im.GetColorU32ImVec4({0.35, 0.92, 0.48, 0.75}), 1.5)
	}

	// Reference Canvas Screen Frame (0..ref.x, 0..ref.y)
	f_tl := _s2d_canvas_to_screen({0, ref.y}, view_min, view_size)
	f_br := _s2d_canvas_to_screen({ref.x, 0}, view_min, view_size)

	// Draw live rendered 2D offscreen texture inside the reference frame
	if scene_2d_rt != nil {
		if tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(scene_2d_rt))); tex_id != 0 {
			im.DrawList_AddImage(dl, im.TextureRef{_TexID = tex_id}, f_tl, f_br)
		}
	}

	// Rule-of-thirds and center guides inside the reference canvas
	if _s2d_show_grid {
		col_guide := im.GetColorU32ImVec4({0.25, 0.75, 0.95, 0.22})
		for frac in ([2]f32{1.0 / 3.0, 2.0 / 3.0}) {
			gx := f_tl.x + (f_br.x - f_tl.x) * frac
			gy := f_tl.y + (f_br.y - f_tl.y) * frac
			im.DrawList_AddLine(dl, {gx, f_tl.y}, {gx, f_br.y}, col_guide, 1.0)
			im.DrawList_AddLine(dl, {f_tl.x, gy}, {f_br.x, gy}, col_guide, 1.0)
		}
	}

	// Reference screen border & header badge showing active Render Mode & Canvas / Capture Camera
	col_frame := im.GetColorU32ImVec4({0.22, 0.82, 0.98, 0.92})
	im.DrawList_AddRect(dl, f_tl, f_br, col_frame)
	mode_tag := "2D World + Menu Canvas"
	switch _s2d_render_mode {
	case .World_2D_And_Canvas: mode_tag = "2D World + Menu Canvas"
	case .UI_Canvas_Only:      mode_tag = "Menu / UI Canvas Only"
	case .World_2D_Only:       mode_tag = "2D Game World Only"
	case .Scene_Capture_Cam:   mode_tag = "Scene Capture Camera"
	}
	hdr_txt := fmt.ctprintf(
		"Scene 2D [%.0fx%.0f px | %.1fx%.1f m @ 100 PPU | Mode: %s]",
		ref.x,
		ref.y,
		ref.x / engine.PIXELS_PER_UNIT,
		ref.y / engine.PIXELS_PER_UNIT,
		mode_tag,
	)
	im.DrawList_AddText(dl, {f_tl.x + 4, f_tl.y - 18}, col_frame, hdr_txt)

	// Top & Left Pixel Rulers (Godot 2D / UMG style)
	ruler_thick :: f32(20.0)
	col_ruler_bg := im.GetColorU32ImVec4({0.09, 0.10, 0.13, 0.94})
	col_ruler_tick := im.GetColorU32ImVec4({0.65, 0.72, 0.82, 0.85})
	im.DrawList_AddRectFilled(dl, view_min, {view_max.x, view_min.y + ruler_thick}, col_ruler_bg)
	im.DrawList_AddRectFilled(dl, view_min, {view_min.x + ruler_thick, view_max.y}, col_ruler_bg)

	x_tick_start := math.floor(c_min.x / step_px) * step_px
	for x := x_tick_start; x <= c_max.x; x += step_px {
		sx := _s2d_canvas_to_screen({x, 0}, view_min, view_size).x
		if sx < view_min.x + ruler_thick || sx > view_max.x - 10 do continue
		im.DrawList_AddLine(dl, {sx, view_min.y + ruler_thick - 6}, {sx, view_min.y + ruler_thick}, col_ruler_tick, 1.0)
		im.DrawList_AddText(dl, {sx + 3, view_min.y + 2}, col_ruler_tick, fmt.ctprintf("%.0f", x))
	}
	y_tick_start := math.floor(c_min.y / step_px) * step_px
	for y := y_tick_start; y <= c_max.y; y += step_px {
		sy := _s2d_canvas_to_screen({0, y}, view_min, view_size).y
		if sy < view_min.y + ruler_thick || sy > view_max.y - 14 do continue
		im.DrawList_AddLine(dl, {view_min.x + ruler_thick - 6, sy}, {view_min.x + ruler_thick, sy}, col_ruler_tick, 1.0)
		im.DrawList_AddText(dl, {view_min.x + 2, sy + 2}, col_ruler_tick, fmt.ctprintf("%.0f", y))
	}
}

// Draw 2D Physics Colliders (`BoxCollider2D`, `CircleCollider2D`, `CapsuleCollider2D`),
// the interactive Scene Capture Camera Frame (`Move_Capture_Cam` / `Resize_Capture_Cam`),
// and handle selection, drag-moving, and corner-scaling of 2D World nodes (`SpriteRenderer` / 2D bodies).
@(private = "file")
_draw_and_interact_scene_2d_world_nodes :: proc(dl: ^im.DrawList, view_min, view_max: im.Vec2, view_hovered: bool) -> (consumed_click: bool) {
	w := engine.ctx_world()
	if w == nil do return false
	view_size := view_max - view_min
	active_h := engine.inspector_active_selection()
	io := im.GetIO()
	mp := io.MousePos
	ref := _s2d_ref_size()

	// 0. Interactive Scene Capture Camera Frame (defines what region of Scene 2D the Capture Camera renders!)
	if _s2d_show_capture_cam_gizmo && _s2d_render_mode != .UI_Canvas_Only {
		cap_h, cap_cam := _s2d_resolve_capture_camera()
		if cap_h != {} && cap_cam != nil && engine.pool_valid(&w.transforms, engine.Handle(cap_h)) {
			cap_t := engine.pool_get(&w.transforms, engine.Handle(cap_h))
			tw := engine.transform_world(cap_h)
			aspect := ref.x / max(ref.y, 1.0)
			half_h_m: f32 = cap_cam.orthographic_size > 0 ? cap_cam.orthographic_size : 5.0
			if cap_cam.projection == .Perspective {
				dist_z := max(abs(tw.position.z), 1.0)
				half_h_m = math.tan(math.to_radians(cap_cam.fov) * 0.5) * dist_z
			}
			half_w_m := half_h_m * aspect

			cam_c_min := _s2d_world_to_canvas({tw.position.x - half_w_m, tw.position.y - half_h_m})
			cam_c_max := _s2d_world_to_canvas({tw.position.x + half_w_m, tw.position.y + half_h_m})
			c_tl := _s2d_canvas_to_screen({cam_c_min.x, cam_c_max.y}, view_min, view_size)
			c_br := _s2d_canvas_to_screen({cam_c_max.x, cam_c_min.y}, view_min, view_size)

			is_cap_sel := active_h == cap_h || _s2d_render_mode == .Scene_Capture_Cam
			col_cam := is_cap_sel ? im.GetColorU32ImVec4({1.0, 0.42, 0.88, 0.96}) : im.GetColorU32ImVec4({0.88, 0.38, 0.82, 0.72})
			im.DrawList_AddRect(dl, c_tl, c_br, col_cam)

			// Capture Camera Header Pill (Drag to move Capture Camera region in 2D!)
			cam_name := cap_t != nil ? cap_t.name : "CaptureCamera"
			pill_txt := fmt.ctprintf(
				"%s Capture Cam: %s [(%.2fm, %.2fm) | Size: %.2fm] (Drag to Move Region)",
				icons.ICON_MD_VIDEOCAM,
				cam_name,
				tw.position.x,
				tw.position.y,
				half_h_m,
			)
			ts := im.CalcTextSize(pill_txt)
			pill_min := im.Vec2{c_tl.x, c_tl.y - ts.y - 8}
			pill_max := im.Vec2{c_tl.x + ts.x + 12, c_tl.y}
			pill_hot := view_hovered && mp.x >= pill_min.x && mp.x <= pill_max.x && mp.y >= pill_min.y && mp.y <= pill_max.y
			im.DrawList_AddRectFilled(
				dl,
				pill_min,
				pill_max,
				pill_hot ? im.GetColorU32ImVec4({0.42, 0.14, 0.38, 0.98}) : im.GetColorU32ImVec4({0.22, 0.08, 0.24, 0.92}),
				4.0,
			)
			im.DrawList_AddRect(dl, pill_min, pill_max, col_cam, 4.0)
			im.DrawList_AddText(dl, {pill_min.x + 6, pill_min.y + 4}, im.GetColorU32ImVec4({1.0, 0.88, 0.98, 1.0}), pill_txt)

			if pill_hot && !_s2d_ruler_active && !_s2d_live_menu_preview && im.IsMouseClicked(.Left) && !consumed_click && cap_t != nil {
				engine.inspector_request_select(cap_h)
				_s2d_capture_cam_h = cap_h
				_s2d_drag_kind = .Move_Capture_Cam
				_s2d_drag_tH = cap_h
				_s2d_drag_start_pos = cap_t.position
				_s2d_drag_start_mouse = mp
				targets := [?]undo.Edit_Target{undo.edit_target_pooled(engine.Handle(cap_h), &cap_t.position, typeid_of([3]f32))}
				_s2d_drag_sess = undo.edit_session_begin(targets[:], "Move Scene Capture Camera")
				consumed_click = true
			}

			// 4 Corner Handles on Capture Camera Frame to resize `orthographic_size`
			cam_corners := [4]im.Vec2{c_tl, {c_br.x, c_tl.y}, c_br, {c_tl.x, c_br.y}}
			cam_signs := [4][2]i8{{-1, 1}, {1, 1}, {1, -1}, {-1, -1}}
			for cp, k in cam_corners {
				hot := view_hovered && math.abs(mp.x - cp.x) <= 7.5 && math.abs(mp.y - cp.y) <= 7.5
				im.DrawList_AddRectFilled(
					dl,
					cp - {5.0, 5.0},
					cp + {5.0, 5.0},
					hot ? im.GetColorU32ImVec4({1.0, 0.95, 0.25, 1.0}) : col_cam,
				)
				if hot && !_s2d_ruler_active && !_s2d_live_menu_preview && im.IsMouseClicked(.Left) && !consumed_click {
					engine.inspector_request_select(cap_h)
					_s2d_capture_cam_h = cap_h
					_s2d_drag_kind = .Resize_Capture_Cam
					_s2d_drag_tH = cap_h
					_s2d_drag_start_ortho = half_h_m
					_s2d_drag_start_mouse = mp
					_s2d_drag_sides = cam_signs[k]
					owned_cam, _ := engine.transform_get_comp(cap_h, engine.Camera)
					targets := [?]undo.Edit_Target{undo.edit_target_pooled(owned_cam.handle, &cap_cam.orthographic_size, typeid_of(f32))}
					_s2d_drag_sess = undo.edit_session_begin(targets[:], "Resize Capture Camera Ortho Size")
					consumed_click = true
				}
			}
		}
	}

	// Update active Capture Camera drag
	if _s2d_drag_kind == .Move_Capture_Cam || _s2d_drag_kind == .Resize_Capture_Cam {
		if im.IsMouseDown(.Left) {
			delta_screen := mp - _s2d_drag_start_mouse
			delta_canvas := [2]f32{delta_screen.x / max(_s2d_zoom, 0.01), -delta_screen.y / max(_s2d_zoom, 0.01)}
			delta_world := delta_canvas / engine.PIXELS_PER_UNIT
			if _s2d_drag_kind == .Move_Capture_Cam {
				if t := engine.pool_get(&w.transforms, engine.Handle(_s2d_drag_tH)); t != nil {
					t.position = {
						_s2d_drag_start_pos.x + delta_world.x,
						_s2d_drag_start_pos.y + delta_world.y,
						_s2d_drag_start_pos.z,
					}
				}
			} else if _, cap_cam := engine.transform_get_comp(_s2d_drag_tH, engine.Camera); cap_cam != nil {
				dy := f32(_s2d_drag_sides.y) * delta_world.y
				cap_cam.projection = .Orthographic
				cap_cam.orthographic_size = clamp(_s2d_drag_start_ortho + dy, 0.25, 250.0)
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			consumed_click = true
		} else {
			undo.edit_session_end(&_s2d_drag_sess)
			_s2d_drag_kind = .None
		}
	}

	// In Menu / UI Canvas Only mode, skip 2D world sprite/collider gizmos so the menu is 100% uncluttered
	if _s2d_render_mode == .UI_Canvas_Only do return consumed_click

	col_wire := im.GetColorU32ImVec4({0.42, 0.96, 0.52, 0.92})
	col_trig := im.GetColorU32ImVec4({0.32, 0.88, 0.98, 0.88})

	rotate2d :: proc(p: [2]f32, rad: f32) -> [2]f32 {
		c := math.cos(rad)
		s := math.sin(rad)
		return {p.x * c - p.y * s, p.x * s + p.y * c}
	}

	// 1. Draw green 2D collider wireframes
	if _s2d_show_colliders {
		if bc_pool := physics2d.box_collider2_ds(w); bc_pool != nil {
			it := engine.pool_iterator(bc_pool)
			for c, _ in engine.pool_next(&it) {
				if !c.enabled || !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
				tw := engine.transform_world(c.owner)
				ang := math.to_radians(engine.quat_to_euler_xyz(tw.rotation).z)
				sz, off := physics2d.box_scaled(c, physics2d.collider_scale(c.owner))
				center_w := tw.position.xy + rotate2d(off, ang)
				hx, hy := sz.x * 0.5, sz.y * 0.5
				local_pts := [4][2]f32{{-hx, -hy}, {hx, -hy}, {hx, hy}, {-hx, hy}}
				scr_pts: [4]im.Vec2
				for lp, k in local_pts {
					wp := center_w + rotate2d(lp, ang)
					scr_pts[k] = _s2d_canvas_to_screen(_s2d_world_to_canvas(wp), view_min, view_size)
				}
				clr := c.is_trigger ? col_trig : col_wire
				for k in 0 ..< 4 {
					im.DrawList_AddLine(dl, scr_pts[k], scr_pts[(k + 1) % 4], clr, 2.0)
				}
			}
		}
		if cc_pool := physics2d.circle_collider2_ds(w); cc_pool != nil {
			it := engine.pool_iterator(cc_pool)
			for c, _ in engine.pool_next(&it) {
				if !c.enabled || !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
				tw := engine.transform_world(c.owner)
				ang := math.to_radians(engine.quat_to_euler_xyz(tw.rotation).z)
				rad, off := physics2d.circle_scaled(c, physics2d.collider_scale(c.owner))
				center_w := tw.position.xy + rotate2d(off, ang)
				scr_c := _s2d_canvas_to_screen(_s2d_world_to_canvas(center_w), view_min, view_size)
				scr_r := rad * engine.PIXELS_PER_UNIT * _s2d_zoom
				clr := c.is_trigger ? col_trig : col_wire
				im.DrawList_AddCircle(dl, scr_c, max(scr_r, 2.0), clr, 28, 2.0)
			}
		}
		if cap_pool := physics2d.capsule_collider2_ds(w); cap_pool != nil {
			it := engine.pool_iterator(cap_pool)
			for c, _ in engine.pool_next(&it) {
				if !c.enabled || !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
				tw := engine.transform_world(c.owner)
				ang := math.to_radians(engine.quat_to_euler_xyz(tw.rotation).z)
				sz, off := physics2d.capsule_scaled(c, physics2d.collider_scale(c.owner))
				center_w := tw.position.xy + rotate2d(off, ang)
				scr_c := _s2d_canvas_to_screen(_s2d_world_to_canvas(center_w), view_min, view_size)
				half_px := sz * 0.5 * engine.PIXELS_PER_UNIT * _s2d_zoom
				clr := c.is_trigger ? col_trig : col_wire
				r_min_pt := scr_c - {half_px.x, half_px.y}
				r_max_pt := scr_c + {half_px.x, half_px.y}
				im.DrawList_AddRect(dl, r_min_pt, r_max_pt, clr, min(half_px.x, half_px.y), 2.0)
			}
		}
	}

	// 2. Collect 2D World nodes (nodes with SpriteRenderer, Rigidbody2D, BoxCollider2D, CircleCollider2D, CapsuleCollider2D)
	World_Node_2D :: struct {
		tH:       engine.Transform_Handle,
		rect_px:  engine.Rect, // Bounding box in canvas pixels
		world_xy: [2]f32,
	}
	w_nodes := make([dynamic]World_Node_2D, context.temp_allocator)
	it_t := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it_t) {
		if !t.is_active do continue
		h_typed := h
		h_typed.type_key = .Transform
		tH := engine.Transform_Handle(h_typed)
		if engine.canvas_of(tH) != {} do continue // Handled by Canvas widget pass

		_, sr := engine.transform_get_comp(tH, sprites.SpriteRenderer)
		_, rb := engine.transform_get_comp(tH, physics2d.Rigidbody2D)
		_, bc := engine.transform_get_comp(tH, physics2d.BoxCollider2D)
		_, cc := engine.transform_get_comp(tH, physics2d.CircleCollider2D)
		_, cap := engine.transform_get_comp(tH, physics2d.CapsuleCollider2D)
		if sr == nil && rb == nil && bc == nil && cc == nil && cap == nil do continue

		tw := engine.transform_world(tH)
		size_m := [2]f32{abs(tw.scale.x), abs(tw.scale.y)}
		if sr != nil && sr.sprite.guid == mhgui.white_texture_guid() {
			size_m /= 100.0
		} else if cc != nil && sr == nil {
			d := cc.radius * 2.0 * max(abs(tw.scale.x), abs(tw.scale.y))
			size_m = {d, d}
		}
		size_px := [2]f32{max(size_m.x * engine.PIXELS_PER_UNIT, 16), max(size_m.y * engine.PIXELS_PER_UNIT, 16)}
		center_px := _s2d_world_to_canvas(tw.position.xy)
		append(&w_nodes, World_Node_2D{
			tH       = tH,
			rect_px  = engine.Rect{pos = center_px - size_px * 0.5, size = size_px},
			world_xy = tw.position.xy,
		})
	}

	// 3. Draw selection outline, 4 scale handles, and body drag for selected 2D World node
	for wn in w_nodes {
		is_sel := wn.tH == active_h
		r_tl := _s2d_canvas_to_screen({wn.rect_px.pos.x, wn.rect_px.pos.y + wn.rect_px.size.y}, view_min, view_size)
		r_br := _s2d_canvas_to_screen({wn.rect_px.pos.x + wn.rect_px.size.x, wn.rect_px.pos.y}, view_min, view_size)

		if is_sel {
			im.DrawList_AddRect(dl, r_tl, r_br, im.GetColorU32ImVec4({1.0, 0.84, 0.22, 0.98}), 0, 2.0)
			if t := engine.pool_get(&w.transforms, engine.Handle(wn.tH)); t != nil {
				badge := fmt.ctprintf("%s [2D World: (%.2fm, %.2fm)]", t.name, wn.world_xy.x, wn.world_xy.y)
				im.DrawList_AddText(dl, {r_tl.x + 2, r_tl.y - 18}, im.GetColorU32ImVec4({1.0, 0.90, 0.35, 1.0}), badge)

				// 4 Corner Scale Handles for 2D World node
				corners := [4]im.Vec2{r_tl, {r_br.x, r_tl.y}, r_br, {r_tl.x, r_br.y}}
				signs := [4][2]i8{{-1, 1}, {1, 1}, {1, -1}, {-1, -1}}
				for cp, k in corners {
					hot := view_hovered && math.abs(mp.x - cp.x) <= 7.0 && math.abs(mp.y - cp.y) <= 7.0
					im.DrawList_AddRectFilled(dl, cp - {4.5, 4.5}, cp + {4.5, 4.5}, hot ? im.GetColorU32ImVec4({1.0, 0.9, 0.2, 1.0}) : im.GetColorU32ImVec4({0.25, 0.92, 0.65, 0.98}))
					if hot && !_s2d_ruler_active && !_s2d_live_menu_preview && im.IsMouseClicked(.Left) && !consumed_click {
						_s2d_drag_kind = .Scale_World_2D
						_s2d_drag_tH = wn.tH
						_s2d_drag_start_scale = t.scale
						_s2d_drag_start_mouse = mp
						_s2d_drag_sides = signs[k]
						targets := [?]undo.Edit_Target{undo.edit_target_pooled(engine.Handle(wn.tH), &t.scale, typeid_of([3]f32))}
						_s2d_drag_sess = undo.edit_session_begin(targets[:], "Scale 2D Node")
						consumed_click = true
					}
				}

				// Body Move Drag for 2D World node
				in_body := view_hovered && mp.x >= r_tl.x && mp.x <= r_br.x && mp.y >= r_tl.y && mp.y <= r_br.y
				if in_body && !_s2d_ruler_active && !_s2d_live_menu_preview && im.IsMouseClicked(.Left) && !consumed_click {
					_s2d_drag_kind = .Move_World_2D
					_s2d_drag_tH = wn.tH
					_s2d_drag_start_pos = t.position
					_s2d_drag_start_mouse = mp
					targets := [?]undo.Edit_Target{undo.edit_target_pooled(engine.Handle(wn.tH), &t.position, typeid_of([3]f32))}
					_s2d_drag_sess = undo.edit_session_begin(targets[:], "Move 2D Node")
					consumed_click = true
				}
			}
		} else {
			im.DrawList_AddRect(dl, r_tl, r_br, im.GetColorU32ImVec4({0.35, 0.78, 0.95, 0.35}))
		}
	}

	// 4. Active 2D World Node drag update
	if _s2d_drag_kind == .Move_World_2D || _s2d_drag_kind == .Scale_World_2D {
		if t := engine.pool_get(&w.transforms, engine.Handle(_s2d_drag_tH)); t != nil && im.IsMouseDown(.Left) {
			delta_screen := mp - _s2d_drag_start_mouse
			delta_canvas := [2]f32{delta_screen.x / max(_s2d_zoom, 0.01), -delta_screen.y / max(_s2d_zoom, 0.01)}
			delta_world := delta_canvas / engine.PIXELS_PER_UNIT
			if _s2d_drag_kind == .Move_World_2D {
				t.position = {
					_s2d_drag_start_pos.x + delta_world.x,
					_s2d_drag_start_pos.y + delta_world.y,
					_s2d_drag_start_pos.z,
				}
			} else {
				sx := max(_s2d_drag_start_scale.x + f32(_s2d_drag_sides.x) * delta_world.x * 2.0, 0.05)
				sy := max(_s2d_drag_start_scale.y + f32(_s2d_drag_sides.y) * delta_world.y * 2.0, 0.05)
				t.scale = {sx, sy, _s2d_drag_start_scale.z}
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			consumed_click = true
		} else {
			undo.edit_session_end(&_s2d_drag_sess)
			_s2d_drag_kind = .None
		}
	}

	// 5. Click-to-Pick a 2D World node if not already consumed
	if view_hovered && !_s2d_ruler_active && !_s2d_live_menu_preview && !consumed_click && im.IsMouseClicked(.Left) && !io.KeyAlt {
		c_pt := _s2d_screen_to_canvas(mp, view_min, view_size)
		for i := len(w_nodes) - 1; i >= 0; i -= 1 {
			wn := w_nodes[i]
			if c_pt.x >= wn.rect_px.pos.x && c_pt.x <= wn.rect_px.pos.x + wn.rect_px.size.x &&
			   c_pt.y >= wn.rect_px.pos.y && c_pt.y <= wn.rect_px.pos.y + wn.rect_px.size.y {
				engine.inspector_request_select(wn.tH)
				consumed_click = true
				break
			}
		}
	}
	return consumed_click
}

// Draw all UI widgets in the active Canvas and handle 2D picking + interactive
// RectTransform move, resize, anchor, and pivot manipulation.
@(private = "file")
_draw_and_interact_scene_2d_widgets :: proc(dl: ^im.DrawList, view_min, view_max: im.Vec2, view_hovered: bool) {
	if _s2d_drag_kind != .None && !im.IsMouseDown(.Left) {
		undo.edit_session_end(&_s2d_drag_sess)
		_s2d_drag_kind = .None
	}

	// First draw & interact with 2D World nodes (Sprites, 2D Physics bodies/colliders & Scene Capture Camera Frame)
	world_consumed := _draw_and_interact_scene_2d_world_nodes(dl, view_min, view_max, view_hovered)

	// In `World_2D_Only` mode, do not draw UI widget outlines or pick UI widgets
	if _s2d_render_mode == .World_2D_Only {
		return
	}

	w := engine.ctx_world()
	if w == nil do return
	canvas_h := _s2d_active_canvas()
	if canvas_h == {} do return

	view_size := view_max - view_min
	ref := _s2d_ref_size()
	root_rect := engine.Rect{pos = {0, 0}, size = ref}

	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas_h, root_rect, &nodes)
	if len(nodes) == 0 do return

	active_h := engine.inspector_active_selection()
	io := im.GetIO()
	mp := io.MousePos
	dt := clamp(io.DeltaTime, 0.0, 0.05)

	// Interactive Menu Preview Mode: highlight, press & apply Raked-Leaf Hover Physics
	// to `mhgui.Button` nodes (rotating BOTH the button quad AND its child Text label together!).
	if _s2d_live_menu_preview {
		if _s2d_test_menu_source == .Void_QuickMenu_Only {
			return
		}
		c_pt := _s2d_screen_to_canvas(mp, view_min, view_size)
		hovered_btn: engine.Transform_Handle
		best_z: i32 = min(i32)
		if view_hovered {
			for i := len(nodes) - 1; i >= 1; i -= 1 {
				n := nodes[i]
				if _, btn := engine.transform_get_comp(n.tH, mhgui.Button); btn != nil && btn.enabled && btn.interactable {
					if c_pt.x >= n.rect.pos.x && c_pt.x <= n.rect.pos.x + n.rect.size.x &&
					   c_pt.y >= n.rect.pos.y && c_pt.y <= n.rect.pos.y + n.rect.size.y {
						if hovered_btn == {} || n.z_index >= best_z {
							hovered_btn = n.tH
							best_z = n.z_index
						}
					}
				}
			}
		}

		m_vel_len := math.sqrt(io.MouseDelta.x * io.MouseDelta.x + io.MouseDelta.y * io.MouseDelta.y)

		for n in nodes {
			if _, btn := engine.transform_get_comp(n.tH, mhgui.Button); btn != nil && btn.enabled {
				target_tH := engine.Transform_Handle(btn.target_graphic.handle)
				if target_tH == {} do target_tH = n.tH
				is_hov := (n.tH == hovered_btn)
				if _, cr := engine.transform_get_comp(target_tH, engine.CanvasRenderer); cr != nil {
					cr.tinted = true
					if is_hov {
						cr.tint = (im.IsMouseDown(.Left) ? btn.colors.pressed : btn.colors.highlighted) * btn.colors.color_multiplier
					} else {
						cr.tint = btn.colors.normal * btn.colors.color_multiplier
					}
				}

				// Find or register Raked-Leaf physics state for this Canvas Button
				t := engine.pool_get(&w.transforms, engine.Handle(n.tH))
				_, rt := engine.transform_get_comp(n.tH, engine.RectTransform)
				if t != nil && rt != nil {
					p_idx := -1
					for entry, idx in _s2d_canvas_btn_phys {
						if entry.tH == n.tH {
							p_idx = idx
							break
						}
					}
					if p_idx < 0 {
						p_idx = len(_s2d_canvas_btn_phys)
						append(&_s2d_canvas_btn_phys, _S2D_Canvas_Btn_Physics{
							tH       = n.tH,
							orig_rot = t.rotation,
							orig_pos = rt.anchored_position,
						})
					}
					bp := &_s2d_canvas_btn_phys[p_idx]

					if is_hov && (!bp.was_hovered || m_vel_len > 6.0) {
						center_x := n.rect.pos.x + n.rect.size.x * 0.5
						half_w := max(n.rect.size.x * 0.5, 1.0)
						rel_x := clamp((c_pt.x - center_x) / half_w, -1.0, 1.0)
						impulse := clamp(m_vel_len * 0.08, 0.35, 1.8)
						// Flip Y velocity from screen space (Y-down) to canvas space (Y-up)
						bp.target_off.x = clamp(bp.cur_off.x + io.MouseDelta.x * 0.65, -24.0, 24.0)
						bp.target_off.y = clamp(bp.cur_off.y - io.MouseDelta.y * 0.65, -16.0, 16.0)
						bp.target_rot   = clamp(bp.cur_rot - rel_x * 0.14 * impulse - io.MouseDelta.x * 0.005, -0.28, 0.28)
						bp.settle_timer = 0.0
					}
					if is_hov && im.IsMouseClicked(.Left) {
						bp.target_off.y -= 6.0
						bp.target_rot *= -0.75
						bp.settle_timer = 0.0
					}
					bp.was_hovered = is_hov

					// Settle with cubic ease-out over 2.0s + idle hover wiggle after 3.0s
					bp.settle_timer = min(bp.settle_timer + dt, 2.0)
					u := 1.0 - (bp.settle_timer / 2.0)
					ease := 1.0 - u * u * u
					bp.cur_off.x = bp.target_off.x * (1.0 - ease)
					bp.cur_off.y = bp.target_off.y * (1.0 - ease)
					bp.cur_rot   = bp.target_rot * (1.0 - ease)

					if is_hov {
						bp.idle_timer += dt
						if bp.idle_timer > 3.0 {
							wt := bp.idle_timer - 3.0
							bp.cur_rot   += math.sin(wt * 4.5) * 0.045
							bp.cur_off.y += math.cos(wt * 3.2) * 3.0
						}
					} else {
						bp.idle_timer = 0.0
					}

					half_a := bp.cur_rot * 0.5
					t.rotation = {0, 0, math.sin(half_a), math.cos(half_a)}
					rt.anchored_position = bp.orig_pos + {bp.cur_off.x, bp.cur_off.y, 0}
				}
			}
		}
		return
	}

	// Draw outlines & labels for all widgets in canvas hierarchy
	selected_idx := -1
	parent_of_selected_rect := root_rect
	for n, idx in nodes {
		if n.tH == active_h do selected_idx = idx
		if idx == 0 do continue // Skip root canvas rect (already drawn as cyan frame)
		r_tl := _s2d_canvas_to_screen({n.rect.pos.x, n.rect.pos.y + n.rect.size.y}, view_min, view_size)
		r_br := _s2d_canvas_to_screen({n.rect.pos.x + n.rect.size.x, n.rect.pos.y}, view_min, view_size)

		is_sel := n.tH == active_h
		col_outline := is_sel ? im.GetColorU32ImVec4({1.0, 0.82, 0.22, 0.98}) : im.GetColorU32ImVec4({0.75, 0.82, 0.95, 0.45})
		im.DrawList_AddRect(dl, r_tl, r_br, col_outline)

		// Show widget name + z_index badge on top-left corner when selected
		if is_sel {
			if t := engine.pool_get(&w.transforms, engine.Handle(n.tH)); t != nil {
				badge := fmt.ctprintf("%s [z:%d] (%.0fx%.0f)", t.name, n.z_index, n.rect.size.x, n.rect.size.y)
				im.DrawList_AddText(dl, {r_tl.x + 2, r_tl.y - 16}, im.GetColorU32ImVec4({1.0, 0.88, 0.35, 1.0}), badge)
			}
		}
	}

	// Interactive Handles for the Selected RectTransform (Anchors, 8 Resize Handles, Pivot, Body Move)
	handle_consumed_click := world_consumed
	if selected_idx > 0 {
		sel_node := nodes[selected_idx]
		_, rt := engine.transform_get_comp(sel_node.tH, engine.RectTransform)
		if t := engine.pool_get(&w.transforms, engine.Handle(sel_node.tH)); t != nil {
			parent_tH := engine.Transform_Handle(t.parent.handle)
			for n in nodes {
				if n.tH == parent_tH {
					parent_of_selected_rect = n.rect
					break
				}
			}
		}

		if rt != nil && !sel_node.driven {
			r := sel_node.rect
			pr := parent_of_selected_rect

			// 1. UMG Anchor Gizmo on the parent rect (1.15x larger blue/cyan center square + 4 corner triangles)
			a_lo := pr.pos + pr.size * rt.anchor_min
			a_hi := pr.pos + pr.size * rt.anchor_max
			anchor_pts := [4][2]f32{a_lo, {a_hi.x, a_lo.y}, a_hi, {a_lo.x, a_hi.y}}
			anchor_dirs := [4][2]f32{{-1, 1}, {1, 1}, {1, -1}, {-1, -1}}

			if rt.anchor_min != rt.anchor_max {
				s_box_tl := _s2d_canvas_to_screen({a_lo.x, a_hi.y}, view_min, view_size)
				s_box_br := _s2d_canvas_to_screen({a_hi.x, a_lo.y}, view_min, view_size)
				im.DrawList_AddRect(dl, s_box_tl, s_box_br, im.GetColorU32ImVec4({0.20, 0.78, 1.0, 0.55}))
			}

			anchor_center_canvas := (a_lo + a_hi) * 0.5
			ac_screen := _s2d_canvas_to_screen(anchor_center_canvas, view_min, view_size)
			ac_half :: f32(5.0 * 1.15)
			ac_hot := view_hovered && math.abs(mp.x - ac_screen.x) <= ac_half + 2.5 && math.abs(mp.y - ac_screen.y) <= ac_half + 2.5

			tri_leg :: f32(10.0 * 1.15)
			tri_hit :: f32(10.0 * 1.15)
			for k in 0 ..< 4 {
				ap := _s2d_canvas_to_screen(anchor_pts[k], view_min, view_size)
				d := anchor_dirs[k]
				p1 := ap + {d.x * tri_leg, 0}
				p2 := ap + {0, d.y * tri_leg}
				centroid := (ap + p1 + p2) / 3.0
				dist := linalg.length(mp - centroid)
				hot := view_hovered && !ac_hot && dist <= tri_hit
				col_a := hot ? im.GetColorU32ImVec4({1.0, 0.92, 0.25, 1.0}) : im.GetColorU32ImVec4({0.25, 0.90, 1.0, 0.95})
				im.DrawList_AddTriangleFilled(dl, ap, p1, p2, col_a)
				im.DrawList_AddTriangle(dl, ap, p1, p2, im.GetColorU32ImVec4({0.05, 0.06, 0.08, 0.95}), 1.5)

				if hot && !_s2d_ruler_active && im.IsMouseClicked(.Left) && !handle_consumed_click {
					_s2d_begin_rt_drag(.Move_Anchor, sel_node.tH, rt, mp, pr)
					_s2d_drag_anchor_idx = k
					handle_consumed_click = true
				}
			}

			col_ac := ac_hot ? im.GetColorU32ImVec4({1.0, 0.92, 0.25, 1.0}) : im.GetColorU32ImVec4({0.18, 0.68, 1.0, 0.98})
			im.DrawList_AddRectFilled(dl, ac_screen - {ac_half, ac_half}, ac_screen + {ac_half, ac_half}, col_ac)
			im.DrawList_AddRect(dl, ac_screen - {ac_half, ac_half}, ac_screen + {ac_half, ac_half}, im.GetColorU32ImVec4({0.05, 0.06, 0.08, 0.98}))
			if ac_hot && !_s2d_ruler_active && im.IsMouseClicked(.Left) && !handle_consumed_click {
				_s2d_begin_rt_drag(.Move_Anchor_All, sel_node.tH, rt, mp, pr)
				handle_consumed_click = true
			}

			if (_s2d_drag_kind == .Move_Anchor || _s2d_drag_kind == .Move_Anchor_All) && _s2d_drag_tH == sel_node.tH {
				col_g := im.GetColorU32ImVec4({0.25, 0.90, 1.0, 0.70})
				s_lo := _s2d_canvas_to_screen(a_lo, view_min, view_size)
				s_hi := _s2d_canvas_to_screen(a_hi, view_min, view_size)
				p_tl := _s2d_canvas_to_screen({pr.pos.x, pr.pos.y + pr.size.y}, view_min, view_size)
				p_br := _s2d_canvas_to_screen({pr.pos.x + pr.size.x, pr.pos.y}, view_min, view_size)
				im.DrawList_AddLine(dl, {s_lo.x, p_tl.y}, {s_lo.x, p_br.y}, col_g, 1.5)
				im.DrawList_AddLine(dl, {s_hi.x, p_tl.y}, {s_hi.x, p_br.y}, col_g, 1.5)
				im.DrawList_AddLine(dl, {p_tl.x, s_lo.y}, {p_br.x, s_lo.y}, col_g, 1.5)
				im.DrawList_AddLine(dl, {p_tl.x, s_hi.y}, {p_br.x, s_hi.y}, col_g, 1.5)
			}

			// 2. Pivot Ring (1.15x scaled)
			piv_canvas := r.pos + r.size * rt.pivot
			piv_screen := _s2d_canvas_to_screen(piv_canvas, view_min, view_size)
			piv_hot := view_hovered && linalg.length(mp - piv_screen) <= (8.0 * 1.15)
			im.DrawList_AddCircle(dl, piv_screen, 6.0 * 1.15, piv_hot ? im.GetColorU32ImVec4({1.0, 0.9, 0.2, 1.0}) : im.GetColorU32ImVec4({0.3, 0.65, 1.0, 1.0}), 16, 2.0)
			if piv_hot && !_s2d_ruler_active && im.IsMouseClicked(.Left) && !handle_consumed_click {
				_s2d_begin_rt_drag(.Move_Pivot, sel_node.tH, rt, mp, pr)
				handle_consumed_click = true
			}

			// 3. Eight Resize Handles (4 corners + 4 edge midpoints, 1.15x scaled)
			Handle_Def :: struct {
				sides: [2]i8,
				at:    [2]f32,
			}
			HANDLE_DEFS := [8]Handle_Def{
				{{-1, -1}, {0, 0}}, {{1, -1}, {1, 0}}, {{1, 1}, {1, 1}}, {{-1, 1}, {0, 1}},
				{{-1, 0}, {0, 0.5}}, {{1, 0}, {1, 0.5}}, {{0, -1}, {0.5, 0}}, {{0, 1}, {0.5, 1}},
			}
			h_half :: f32(4.0 * 1.15)
			h_hit  :: f32(6.0 * 1.15)
			for hd in HANDLE_DEFS {
				hp := _s2d_canvas_to_screen(r.pos + r.size * hd.at, view_min, view_size)
				hot := view_hovered && math.abs(mp.x - hp.x) <= h_hit && math.abs(mp.y - hp.y) <= h_hit
				im.DrawList_AddRectFilled(dl, hp - {h_half, h_half}, hp + {h_half, h_half}, hot ? im.GetColorU32ImVec4({1.0, 0.9, 0.2, 1.0}) : im.GetColorU32ImVec4({1.0, 1.0, 1.0, 0.95}))
				im.DrawList_AddRect(dl, hp - {h_half, h_half}, hp + {h_half, h_half}, im.GetColorU32ImVec4({0.08, 0.09, 0.12, 1.0}))
				if hot && !_s2d_ruler_active && im.IsMouseClicked(.Left) && !handle_consumed_click {
					_s2d_begin_rt_drag(.Resize_Edge, sel_node.tH, rt, mp, pr)
					_s2d_drag_sides = hd.sides
					handle_consumed_click = true
				}
			}

			// 4. Body Drag (clicking inside the selected widget moves it)
			r_tl := _s2d_canvas_to_screen({r.pos.x, r.pos.y + r.size.y}, view_min, view_size)
			r_br := _s2d_canvas_to_screen({r.pos.x + r.size.x, r.pos.y}, view_min, view_size)
			in_body := view_hovered && mp.x >= r_tl.x && mp.x <= r_br.x && mp.y >= r_tl.y && mp.y <= r_br.y
			if in_body && !_s2d_ruler_active && im.IsMouseClicked(.Left) && !handle_consumed_click {
				_s2d_begin_rt_drag(.Move_Body, sel_node.tH, rt, mp, pr)
				handle_consumed_click = true
			}
		}
	}

	// Active RectTransform drag update / release
	if _s2d_drag_kind != .None && _s2d_drag_kind != .Move_World_2D && _s2d_drag_kind != .Scale_World_2D &&
	   _s2d_drag_kind != .Move_Capture_Cam && _s2d_drag_kind != .Resize_Capture_Cam {
		if _, rt := engine.transform_get_comp(_s2d_drag_tH, engine.RectTransform); rt != nil && im.IsMouseDown(.Left) {
			delta_screen := mp - _s2d_drag_start_mouse
			delta_canvas := [2]f32{delta_screen.x / max(_s2d_zoom, 0.01), -delta_screen.y / max(_s2d_zoom, 0.01)}
			rt^ = _s2d_drag_start_rt

			#partial switch _s2d_drag_kind {
			case .Move_Body:
				mhgui.rect_drag_move(rt, delta_canvas)
			case .Resize_Edge:
				mhgui.rect_drag_edges(rt, _s2d_drag_sides, delta_canvas)
			case .Move_Anchor_All:
				pr := _s2d_drag_parent_rect
				before := engine.rect_resolve(pr, rt)
				df := delta_canvas / [2]f32{max(pr.size.x, 1), max(pr.size.y, 1)}
				span := _s2d_drag_start_rt.anchor_max - _s2d_drag_start_rt.anchor_min
				if io.KeyCtrl {
					df = {math.round(df.x * 20.0) * 0.05, math.round(df.y * 20.0) * 0.05}
				}
				amin := [2]f32{
					clamp(_s2d_drag_start_rt.anchor_min.x + df.x, 0.0, max(1.0 - span.x, 0.0)),
					clamp(_s2d_drag_start_rt.anchor_min.y + df.y, 0.0, max(1.0 - span.y, 0.0)),
				}
				amax := amin + span
				rt.anchor_min = amin
				rt.anchor_max = amax
				if !io.KeyAlt {
					engine.rect_transform_keep_rect(rt, pr, before)
				}
			case .Move_Anchor:
				pr := _s2d_drag_parent_rect
				df := delta_canvas / [2]f32{max(pr.size.x, 1), max(pr.size.y, 1)}
				k := _s2d_drag_anchor_idx
				start := [2]f32{
					_s2d_drag_start_rt.anchor_min.x if k == 0 || k == 3 else _s2d_drag_start_rt.anchor_max.x,
					_s2d_drag_start_rt.anchor_min.y if k == 0 || k == 1 else _s2d_drag_start_rt.anchor_max.y,
				}
				f := [2]f32{clamp(start.x + df.x, 0, 1), clamp(start.y + df.y, 0, 1)}
				before := engine.rect_resolve(pr, rt)
				amin, amax := rt.anchor_min, rt.anchor_max
				if k == 0 || k == 3 {
					amin.x = f.x
					amax.x = max(amax.x, f.x)
				} else {
					amax.x = f.x
					amin.x = min(amin.x, f.x)
				}
				if k == 0 || k == 1 {
					amin.y = f.y
					amax.y = max(amax.y, f.y)
				} else {
					amax.y = f.y
					amin.y = min(amin.y, f.y)
				}
				rt.anchor_min = amin
				rt.anchor_max = amax
				if !io.KeyAlt {
					engine.rect_transform_keep_rect(rt, pr, before)
				}
			case .Move_Pivot:
				pr := _s2d_drag_parent_rect
				before := engine.rect_resolve(pr, rt)
				cur_canvas := _s2d_screen_to_canvas(mp, view_min, view_size)
				f := (cur_canvas - before.pos) / [2]f32{max(before.size.x, 1), max(before.size.y, 1)}
				f = {clamp(f.x, 0, 1), clamp(f.y, 0, 1)}
				if io.KeyCtrl do f = {math.round(f.x * 2) * 0.5, math.round(f.y * 2) * 0.5}
				rt.pivot = f
				engine.rect_transform_keep_rect(rt, pr, before)
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		} else {
			undo.edit_session_end(&_s2d_drag_sess)
			_s2d_drag_kind = .None
		}
		return
	}

	// Direct 2D Click-to-Pick (sorted by highest z_index first, then deepest tree index).
	if view_hovered && !_s2d_ruler_active && !handle_consumed_click && im.IsMouseClicked(.Left) && !io.KeyAlt {
		c_pt := _s2d_screen_to_canvas(mp, view_min, view_size)
		best_tH: engine.Transform_Handle = {}
		best_z: i32 = -2147483648
		for i := len(nodes) - 1; i >= 1; i -= 1 {
			n := nodes[i]
			if c_pt.x >= n.rect.pos.x && c_pt.x <= n.rect.pos.x + n.rect.size.x &&
			   c_pt.y >= n.rect.pos.y && c_pt.y <= n.rect.pos.y + n.rect.size.y {
				if best_tH == {} || n.z_index > best_z {
					best_tH = n.tH
					best_z = n.z_index
				}
			}
		}
		if best_tH != {} {
			if ht := engine.pool_get(&w.transforms, engine.Handle(best_tH)); ht != nil {
				parent_tH := engine.Transform_Handle(ht.parent.handle)
				if parent_tH != {} && parent_tH != canvas_h {
					if _, btn := engine.transform_get_comp(parent_tH, mhgui.Button); btn != nil {
						if active_h != parent_tH && active_h != best_tH {
							best_tH = parent_tH
						}
					}
				}
			}
			engine.inspector_request_select(best_tH)
		} else if canvas_h != {} {
			engine.inspector_request_select(canvas_h)
		}
	}
}

@(private = "file")
_s2d_begin_rt_drag :: proc(kind: _S2D_Drag_Kind, tH: engine.Transform_Handle, rt: ^engine.RectTransform, mp: im.Vec2, parent_rect: engine.Rect) {
	_s2d_drag_kind = kind
	_s2d_drag_tH = tH
	_s2d_drag_start_rt = rt^
	_s2d_drag_start_mouse = mp
	_s2d_drag_parent_rect = parent_rect
	owned, _ := engine.transform_get_comp(tH, engine.RectTransform)
	targets := [?]undo.Edit_Target{
		undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)),
		undo.edit_target_pooled(owned.handle, &rt.size_delta, typeid_of([2]f32)),
		undo.edit_target_pooled(owned.handle, &rt.anchor_min, typeid_of([2]f32)),
		undo.edit_target_pooled(owned.handle, &rt.anchor_max, typeid_of([2]f32)),
		undo.edit_target_pooled(owned.handle, &rt.pivot, typeid_of([2]f32)),
	}
	_s2d_drag_sess = undo.edit_session_begin(targets[:], "Edit 2D RectTransform")
}

// Draw 3-sided AutoCAD ruler triangles in the `Scene 2D` window.
@(private = "file")
_draw_scene_2d_ruler :: proc(dl: ^im.DrawList, view_min, view_max: im.Vec2) {
	view_size := view_max - view_min
	draw_one :: proc(dl: ^im.DrawList, m: _S2D_Ruler_Meas, view_min, view_size: im.Vec2, pinned: bool) {
		s0 := _s2d_canvas_to_screen(m.p0, view_min, view_size)
		s1 := _s2d_canvas_to_screen(m.p1, view_min, view_size)
		sc := im.Vec2{s1.x, s0.y}

		dx := abs(m.p1.x - m.p0.x)
		dy := abs(m.p1.y - m.p0.y)
		dist := math.sqrt(dx * dx + dy * dy)
		angle := math.to_degrees(math.atan2(dy, dx))

		alpha: f32 = pinned ? 0.85 : 1.0
		col_hyp := im.GetColorU32ImVec4({1.0, 0.82, 0.18, alpha})
		col_h   := im.GetColorU32ImVec4({0.98, 0.38, 0.34, alpha})
		col_v   := im.GetColorU32ImVec4({0.30, 0.92, 0.48, alpha})

		im.DrawList_AddLine(dl, s0, sc, col_h, 2.0)
		im.DrawList_AddLine(dl, sc, s1, col_v, 2.0)
		im.DrawList_AddLine(dl, s0, s1, col_hyp, 2.5)

		if dx > 1.0 {
			_draw_ruler_badge(dl, (s0 + sc) * 0.5 + {0, 14}, fmt.ctprintf("dX: %.1f px", dx), col_h, col_h, alpha)
		}
		if dy > 1.0 {
			_draw_ruler_badge(dl, (sc + s1) * 0.5 + {44, 0}, fmt.ctprintf("dY: %.1f px", dy), col_v, col_v, alpha)
		}
		_draw_ruler_badge(dl, (s0 + s1) * 0.5 - {0, 16}, fmt.ctprintf("%.1f px (%.1f deg)", dist, angle), col_hyp, col_hyp, alpha)
	}

	for pm in _s2d_ruler_pinned {
		draw_one(dl, pm, view_min, view_size, true)
	}
	if _s2d_ruler_has_cur {
		draw_one(dl, _s2d_ruler_cur, view_min, view_size, false)
	}
}

// Right-Click Context Menu inside Scene 2D
@(private = "file")
_draw_scene_2d_context_menu :: proc(view_size: im.Vec2) {
	if im.BeginPopup("##s2d_canvas_context_menu") {
		w := engine.ctx_world()
		active_h := engine.inspector_active_selection()
		canvas_h := _s2d_active_canvas()
		ref := _s2d_ref_size()
		rel_pos := _s2d_ctx_canvas_pt - ref * 0.5
		world_pt := _s2d_canvas_to_world(_s2d_ctx_canvas_pt)

		im.SeparatorText("Scene 2D — Create Menu / UI Widget Here")
		if im.MenuItem(fmt.ctprintf("%s  Create UI Panel Here", icons.ICON_MD_CROP_FREE)) {
			if canvas_h == {} do canvas_h = _s2d_create_widget("Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, ref)
			panel_h := _s2d_create_widget("Panel", canvas_h, {.RectTransform, .CanvasRenderer, .Image}, {420, 280}, "", rel_pos)
			if _, img := engine.transform_get_comp(panel_h, mhgui.Image); img != nil do img.color = {0.10, 0.13, 0.19, 0.92}
		}
		if im.MenuItem(fmt.ctprintf("%s  Create UI Button Here", icons.ICON_MD_WIDGETS)) {
			if canvas_h == {} do canvas_h = _s2d_create_widget("Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, ref)
			_s2d_create_styled_button("Button", "Button", canvas_h, rel_pos, {190, 48}, {0.18, 0.28, 0.40, 1.0}, 2)
		}
		if im.MenuItem(fmt.ctprintf("%s  Create Text Label Here", icons.ICON_MD_DESCRIPTION)) {
			if canvas_h == {} do canvas_h = _s2d_create_widget("Canvas", {}, {.Canvas, .CanvasScaler, .GraphicRaycaster}, ref)
			_s2d_create_widget("Text", canvas_h, {.RectTransform, .CanvasRenderer, .Text}, {240, 48}, "New Text", rel_pos)
		}
		if im.MenuItem(fmt.ctprintf("%s  Build Full QuickMenu & Settings Canvas", icons.ICON_MD_SETTINGS)) {
			_s2d_build_quickmenu_canvas_template(view_size)
		}

		im.SeparatorText("Scene 2D — Create 2D Game Node / Capture Camera Here")
		if im.MenuItem(fmt.ctprintf("%s  Create & Hook Scene Capture Camera 2D Here", icons.ICON_MD_VIDEOCAM)) {
			cam_h := _s2d_create_capture_camera_2d()
			if cam_h != {} && w != nil {
				if ct := engine.pool_get(&w.transforms, engine.Handle(cam_h)); ct != nil {
					ct.position = {world_pt.x, world_pt.y, 10.0}
				}
			}
		}
		if im.MenuItem(fmt.ctprintf("%s  Create Sprite2D Here", icons.ICON_MD_IMAGE)) {
			_s2d_create_game_node_2d(.Sprite2D, world_pt)
		}
		if im.MenuItem(fmt.ctprintf("%s  Create RigidBody2D (Dynamic Box) Here", icons.ICON_MD_HEXAGON)) {
			_s2d_create_game_node_2d(.RigidBody2D_Box, world_pt)
		}
		if im.MenuItem(fmt.ctprintf("%s  Create RigidBody2D (Dynamic Ball) Here", icons.ICON_MD_PENTAGON)) {
			_s2d_create_game_node_2d(.RigidBody2D_Circle, world_pt)
		}
		if im.MenuItem(fmt.ctprintf("%s  Create StaticBody2D Platform Here", icons.ICON_MD_DRAG_HANDLE)) {
			_s2d_create_game_node_2d(.StaticBody2D_Platform, world_pt)
		}

		if active_h != {} && w != nil && engine.pool_valid(&w.transforms, engine.Handle(active_h)) {
			im.SeparatorText("Selected Node Actions")
			if _, rt := engine.transform_get_comp(active_h, engine.RectTransform); rt != nil {
				if im.MenuItem(fmt.ctprintf("%s  Bring to Front (+Z)", icons.ICON_MD_EXPAND_LESS)) {
					rt.z_index += 1
				}
				if im.MenuItem(fmt.ctprintf("%s  Send to Back (-Z)", icons.ICON_MD_EXPAND_MORE)) {
					rt.z_index -= 1
				}
				if im.MenuItem(fmt.ctprintf("%s  Center in Parent", icons.ICON_MD_CENTER_FOCUS)) {
					_s2d_apply_preset(active_h, .Center, true)
				}
			}
			if im.MenuItem(fmt.ctprintf("%s  Duplicate (Ctrl+D)", icons.ICON_MD_CONTENT_COPY)) {
				_duplicate_selected()
			}
			if im.MenuItem(fmt.ctprintf("%s  Delete (Del)", icons.ICON_MD_DELETE)) {
				_delete_selected()
			}
		}
		im.EndPopup()
	}
}

draw_scene_2d_view :: proc() {
	if wnd.main_central_dock_id != 0 {
		im.SetNextWindowDockID(wnd.main_central_dock_id, .FirstUseEver)
	}
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	open := wnd.begin(icons.TITLE_SCENE_2D, &menu.show_scene_2d, {.NoCollapse, .NoScrollbar, .NoScrollWithMouse})
	im.PopStyleVar()

	if open {
		wnd.decorate_floating_window(icons.TITLE_SCENE_2D, &menu.show_scene_2d)
		content_min := im.GetCursorScreenPos()
		full := im.GetContentRegionAvail()

		bar_h := im.GetFrameHeight() + 10
		view_min := im.Vec2{content_min.x, content_min.y + bar_h}
		view_size := im.Vec2{max(full.x, 1), max(full.y - bar_h, 1)}
		view_max := view_min + view_size

		if !_s2d_initialized && view_size.x > 64 && view_size.y > 64 {
			_s2d_initialized = true
			_s2d_fit_canvas(view_size)
		}

		// Step in-viewport 2D Physics Simulation if running
		if _s2d_sim_running {
			dt := clamp(im.GetIO().DeltaTime, 0.0, 0.05)
			_s2d_sim_accum += dt
			fixed_dt :: f32(1.0 / 60.0)
			for _s2d_sim_accum >= fixed_dt {
				physics2d.physics_step(fixed_dt)
				_s2d_sim_accum -= fixed_dt
			}
		}

		// Top Toolbar
		im.SetCursorScreenPos(content_min + {6, 4})
		im.BeginGroup()
		_draw_scene_2d_toolbar(view_size)
		im.EndGroup()

		// Render offscreen 2D Canvas + 2D World preview
		ref := _s2d_ref_size()
		_s2d_render_offscreen(i32(ref.x), i32(ref.y))

		// Reserve interactive canvas area
		im.SetCursorScreenPos(view_min)
		im.InvisibleButton("##scene_2d_canvas_surface", view_size, {.MouseButtonLeft, .MouseButtonRight, .MouseButtonMiddle})
		view_hovered := im.IsItemHovered()

		// Accept Drag-and-Drop Assets from Void File Explorer onto Scene 2D
		if im.BeginDragDropTarget() {
			if payload := im.AcceptDragDropPayload("ASSET_PATH", {}); payload != nil && payload.Data != nil {
				path := string(([^]byte)(payload.Data)[:payload.DataSize])
				ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
				drop_c := _s2d_screen_to_canvas(im.GetIO().MousePos, view_min, view_size)
				if ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" {
					if guid, ok := engine.asset_db_get_guid(path); ok {
						canvas_h := _s2d_active_canvas()
						active_h := engine.inspector_active_selection()
						if canvas_h != {} && (active_h == canvas_h || engine.canvas_of(active_h) == canvas_h) {
							rel := drop_c - ref * 0.5
							img_h := _s2d_create_widget(filepath.stem(path), canvas_h, {.RectTransform, .CanvasRenderer, .Image}, {180, 180}, "", rel)
							if _, img := engine.transform_get_comp(img_h, mhgui.Image); img != nil {
								img.sprite.guid = engine.Asset_GUID(guid)
							}
						} else {
							w_pt := _s2d_canvas_to_world(drop_c)
							sp_h := _s2d_create_game_node_2d(.Sprite2D, w_pt)
							if _, sr := engine.transform_get_comp(sp_h, sprites.SpriteRenderer); sr != nil {
								sr.sprite.guid = engine.Asset_GUID(guid)
								sr.color = {1, 1, 1, 1}
							}
						}
					}
				} else if scene := engine.sm_scene_get_active(); scene != nil {
					editor_drop_asset_on_transform(path, engine.Transform_Handle(scene.root.handle))
				}
			}
			im.EndDragDropTarget()
		}

		dl := im.GetWindowDrawList()
		im.DrawList_PushClipRect(dl, view_min, view_max, true)
		_draw_scene_2d_backdrop_and_rulers(dl, view_min, view_max)
		_draw_and_interact_scene_2d_widgets(dl, view_min, view_max, view_hovered)
		_draw_scene_2d_ruler(dl, view_min, view_max)

		// Live Menu / QuickMenu & Console Overlay Preview inside Scene 2D
		if _s2d_live_menu_preview && _s2d_test_menu_source != .Scene_Canvas_Only {
			f_tl := _s2d_canvas_to_screen({0, ref.y}, view_min, view_size)
			f_br := _s2d_canvas_to_screen({ref.x, 0}, view_min, view_size)
			engine.game_view_overlay_draw({f_tl.x, f_tl.y}, {f_br.x, f_br.y}, view_hovered, true)
		}
		im.DrawList_PopClipRect(dl)

		// Floating Active Menu Switcher Bar when `[Test Menu]` is enabled
		if _s2d_live_menu_preview {
			im.SetCursorScreenPos({view_min.x + 28, view_min.y + 26})
			im.PushStyleColorImVec4(.ChildBg, {0.06, 0.08, 0.12, 0.92})
			im.PushStyleColorImVec4(.Border, {0.18, 0.85, 0.55, 0.85})
			im.PushStyleVarImVec2(.WindowPadding, {8, 4})
			if im.BeginChild("##s2d_active_menu_banner", {565, 30}, {.Borders}, {.NoScrollbar, .NoScrollWithMouse}) {
				im.TextColored({0.25, 0.95, 0.60, 1.0}, "ACTIVE MENU:")
				im.SameLine(0, 6)
				is_both := _s2d_test_menu_source == .Both_Canvas_And_QuickMenu
				is_cnv  := _s2d_test_menu_source == .Scene_Canvas_Only
				is_void := _s2d_test_menu_source == .Void_QuickMenu_Only
				if is_both do im.PushStyleColorImVec4(.Button, {0.14, 0.45, 0.30, 0.98})
				if im.SmallButton("Both (Canvas + QuickMenu)##s2d_mb_both") {
					_s2d_test_menu_source = .Both_Canvas_And_QuickMenu
				}
				if is_both do im.PopStyleColor()
				im.SameLine(0, 4)
				if is_cnv do im.PushStyleColorImVec4(.Button, {0.14, 0.40, 0.65, 0.98})
				if im.SmallButton("Scene Canvas Only##s2d_mb_cnv") {
					_s2d_test_menu_source = .Scene_Canvas_Only
					_s2d_render_mode = .UI_Canvas_Only
				}
				if is_cnv do im.PopStyleColor()
				im.SameLine(0, 4)
				if is_void do im.PushStyleColorImVec4(.Button, {0.55, 0.32, 0.12, 0.98})
				if im.SmallButton("Void QuickMenu Only##s2d_mb_void") {
					_s2d_restore_canvas_btn_physics()
					_s2d_test_menu_source = .Void_QuickMenu_Only
				}
				if is_void do im.PopStyleColor()
			}
			im.EndChild()
			im.PopStyleVar()
			im.PopStyleColor(2)
		}

		// Open Right-Click Context Menu if RMB clicked without dragging
		if view_hovered && im.IsMouseClicked(.Right) {
			_s2d_rmb_press_pos = im.GetIO().MousePos
		}
		if view_hovered && im.IsMouseReleased(.Right) && linalg.length(im.GetIO().MousePos - _s2d_rmb_press_pos) < 5.0 {
			_s2d_ctx_canvas_pt = _s2d_screen_to_canvas(im.GetIO().MousePos, view_min, view_size)
			im.OpenPopup("##s2d_canvas_context_menu")
		}
		_draw_scene_2d_context_menu(view_size)

		// Bottom-left Godot-style 2D Zoom & Fit Bar
		im.SetCursorScreenPos({view_min.x + 28, view_max.y - 32})
		im.PushStyleColorImVec4(.Button, {0.11, 0.12, 0.15, 0.90})
		if im.Button("-##s2d_z_out") do _s2d_zoom = clamp(_s2d_zoom / 1.15, 0.08, 8.0)
		widgets.tooltip("Zoom Out 2D Canvas")
		im.SameLine(0, 2)
		if im.Button(fmt.ctprintf("%.0f%%%%##s2d_z_rst", _s2d_zoom * 100.0)) do _s2d_zoom = 1.0
		widgets.tooltip("Reset 2D Canvas Zoom to 100% (1:1 pixels)")
		im.SameLine(0, 2)
		if im.Button("+##s2d_z_in") do _s2d_zoom = clamp(_s2d_zoom * 1.15, 0.08, 8.0)
		widgets.tooltip("Zoom In 2D Canvas")
		im.SameLine(0, 4)
		if im.Button("Fit Canvas##s2d_fit") do _s2d_fit_canvas(view_size)
		widgets.tooltip("Center and fit the reference 2D Canvas inside the viewport (F)")
		if _s2d_ruler_has_cur {
			im.SameLine(0, 4)
			if im.Button("+ Pin (P)##s2d_bot_pin") {
				append(&_s2d_ruler_pinned, _s2d_ruler_cur)
			}
		}
		if _s2d_ruler_has_cur || len(_s2d_ruler_pinned) > 0 {
			im.SameLine(0, 4)
			if im.Button(fmt.ctprintf("%s Clear Ruler##s2d_bot_clr", icons.ICON_MD_DELETE)) {
				_s2d_ruler_has_cur = false
				_s2d_ruler_dragging = false
				clear(&_s2d_ruler_pinned)
			}
		}
		im.PopStyleColor()

		// Handle 2D Navigation & Editing Shortcuts
		io := im.GetIO()
		if view_hovered {
			if !io.WantTextInput && !_s2d_live_menu_preview {
				if im.IsKeyPressed(.M, false) {
					_s2d_ruler_active = !_s2d_ruler_active
				}
				if im.IsKeyPressed(.F, false) {
					_s2d_fit_canvas(view_size)
				}
				if _s2d_ruler_has_cur && im.IsKeyPressed(.P, false) {
					append(&_s2d_ruler_pinned, _s2d_ruler_cur)
				}
				if im.IsKeyPressed(.Escape, false) {
					_s2d_ruler_active = false
					_s2d_ruler_has_cur = false
					clear(&_s2d_ruler_pinned)
				}
				// Delete & Ctrl+D Duplicate inside Scene 2D
				if im.IsKeyPressed(.Delete, false) {
					_delete_selected()
				}
				if io.KeyCtrl && im.IsKeyPressed(.D, false) {
					_duplicate_selected()
				}

				// Arrow Key Nudging for selected RectTransform (1px / 10px) or 2D World node (0.05m / 0.5m)
				active_h := engine.inspector_active_selection()
				if active_h != {} {
					nudge_dir := [2]f32{0, 0}
					if im.IsKeyPressed(.LeftArrow, true)  do nudge_dir.x -= 1
					if im.IsKeyPressed(.RightArrow, true) do nudge_dir.x += 1
					if im.IsKeyPressed(.DownArrow, true)  do nudge_dir.y -= 1
					if im.IsKeyPressed(.UpArrow, true)    do nudge_dir.y += 1
					if nudge_dir != {0, 0} {
						mult: f32 = io.KeyShift ? 10.0 : 1.0
						if _, rt := engine.transform_get_comp(active_h, engine.RectTransform); rt != nil {
							rt.anchored_position.x += nudge_dir.x * mult
							rt.anchored_position.y += nudge_dir.y * mult
							if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
						} else if w := engine.ctx_world(); w != nil {
							if t := engine.pool_get(&w.transforms, engine.Handle(active_h)); t != nil {
								t.position.x += nudge_dir.x * 0.05 * mult
								t.position.y += nudge_dir.y * 0.05 * mult
								if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
							}
						}
					}
				}
			}

			// 2D Ruler drag
			if _s2d_ruler_active {
				if im.IsMouseClicked(.Left) {
					_s2d_ruler_dragging = true
					_s2d_ruler_has_cur = true
					pt := _s2d_screen_to_canvas(io.MousePos, view_min, view_size)
					_s2d_ruler_cur = {pt, pt}
				}
				if _s2d_ruler_dragging && im.IsMouseDown(.Left) {
					_s2d_ruler_cur.p1 = _s2d_screen_to_canvas(io.MousePos, view_min, view_size)
				}
				if _s2d_ruler_dragging && im.IsMouseReleased(.Left) {
					_s2d_ruler_dragging = false
					if io.KeyShift {
						append(&_s2d_ruler_pinned, _s2d_ruler_cur)
					}
				}
			}

			// Pan with MMB or RMB drag
			if im.IsMouseDragging(.Middle, 1.0) || im.IsMouseDragging(.Right, 1.0) {
				_s2d_pan.x -= io.MouseDelta.x / max(_s2d_zoom, 0.01)
				_s2d_pan.y += io.MouseDelta.y / max(_s2d_zoom, 0.01)
			}

			// Pan with WASD when not typing and Ctrl is not held
			if !io.WantTextInput && !io.KeyCtrl && !_s2d_live_menu_preview && !im.IsMouseDown(.Right) {
				pan_speed := (600.0 / max(_s2d_zoom, 0.05)) * io.DeltaTime
				if input.key_down(.W) do _s2d_pan.y += pan_speed
				if input.key_down(.S) do _s2d_pan.y -= pan_speed
				if input.key_down(.D) do _s2d_pan.x += pan_speed
				if input.key_down(.A) do _s2d_pan.x -= pan_speed
			}

			// Zoom around cursor with Mouse Wheel
			if io.MouseWheel != 0 && !_s2d_live_menu_preview {
				before := _s2d_screen_to_canvas(io.MousePos, view_min, view_size)
				_s2d_zoom = clamp(_s2d_zoom * math.pow(1.12, io.MouseWheel), 0.08, 8.0)
				after := _s2d_screen_to_canvas(io.MousePos, view_min, view_size)
				_s2d_pan += before - after
			}
		}
	}
	im.End()
}
