package cad_csg_editor

// Modal Scene3D CAD Blockout, 2D Polyline/Spline Extruder & Red Faction Destructible CSG Editor.
//
// Upgraded Workflow (Unreal Modeling Mode PolyEd / Spline + Blender Curve Extrude + AutoCAD PLINE):
// 1. `[1] Spline / Poly Sketch`:
//    - Click point-by-point on the WorkPlane to place 2D vertices, or hold `Shift + Drag` for freehand squiggly spline drawing.
//    - Press `C` (or Right-Click any placed vertex) to toggle between a **Sharp CAD Corner** (cyan square) and a
//      **Smooth Catmull-Rom Spline Curve** (gold circle).
//    - Type exact lengths (`3.5` + Enter) or relative coordinates (`3.5, 2.0` + Enter) at any time, or place by hand.
//    - Click the start point `P0` (or press `Enter` / `Space`) to close the 2D loop, then pull the 3D Extrude handle
//      by hand or type an exact extrusion height (`2.5` or `-1.5` + Enter)!
// 2. `[2] Box / Primitive`:
//    - Click-drag (or click corner A -> corner B) on the WorkPlane, then pull height H (or type dimensions).
//    - When `- Cut Hole (Subtract)` is active, automatically penetrates INTO the target wall/floor so boolean cuts
//      carve through immediately with a bright red X-Ray boolean cut preview.
// 3. `[3] Extrude / Push-Pull Face`:
//    - Hover any brush face and drag by hand OR type an exact offset (`1.25` or `-0.5` + Enter) to push/pull it.
// 4. `[4] Geo-Mod Blast (B)`:
//    - Click any surface (or press `B` anytime) to carve a Red Faction boolean crater.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import "haati:engine/gizmos"
import input "haati:engine/input"
import "haati:editor/handles"
import "haati:editor/icons"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import cad_csg "haati:packages/cad_csg"
import control_rig_ed "haati:packages/control_rig/editor"

CAD_Sub_Tool :: enum u8 {
	Spline_Poly_Sketch = 0, // 2D Polyline / Catmull-Rom Spline Sketcher -> 3D Extrude (Unreal / Blender / CAD style)
	Box_Primitive      = 1, // 2-Stage Box / Wedge / Hex / Cylinder Pull-Push Builder
	Face_Push_Pull     = 2, // Direct Face Extrude / Push-Pull Resizer (by hand or typed offset)
	Geo_Mod_Blast      = 3, // Live Red Faction Boolean Crater Blaster
	Clip_Brush_Plane   = 4, // SabreCSG / RealtimeCSG 2-Point CSG Clip Plane Slicer
	Soft_Deform_Brush  = 5, // Soft Deformer Body Brush (Mesh Coord Offset Dent/Bulge/Ripple/Twist while Jolt CSG Collision stays untouched!)
	Draw_Glass_Poly    = 6, // Interactive 3D Polygon Glass Drawing Tool (Click 3D Points -> Complete Loop -> Fill with Glass!)
}

Draft_Stage :: enum u8 {
	Idle            = 0,
	Drawing_Footprint = 1, // Dragging 2D box footprint or sketching 2D spline profile
	Extruding_Height  = 2, // Pulling 3D height H perpendicular to WorkPlane
}

// Blender-style Extrude / Intrude Axis Selection (`Normal`, `World X`, `World Y`, `World Z`, `Free Cursor`)
Extrude_Axis_Mode :: enum u8 {
	Face_Normal = 0, // Extrude/Intrude along the selected face's outward normal (Default)
	World_X     = 1, // Lock extrusion to World X axis (1, 0, 0)
	World_Y     = 2, // Lock extrusion to World Y axis (0, 1, 0)
	World_Z     = 3, // Lock extrusion to World Z axis (0, 0, 1)
	Free_Cursor = 4, // Free 3D extrusion parallel to view plane
}

// CSG Extrude Mode: True Blender-style Extrude/Intrude new segment/pocket vs Move existing face plane
Extrude_CSG_Behavior :: enum u8 {
	Extrude_Intrude_Segment = 0, // Outward = Extrude new boss/segment; Inward = Intrude boolean recess/pocket!
	Move_Face_Plane         = 1, // Push/Pull existing brush face plane
}

CAD_WorkPlane :: struct {
	origin:    [3]f32,
	normal:    [3]f32,
	u_axis:    [3]f32,
	v_axis:    [3]f32,
	is_custom: bool,
}

OSNAP_Kind :: enum u8 {
	None        = 0,
	Vertex      = 1,
	Midpoint    = 2,
	Face_Center = 3,
}

CAD_Polar_Snap_Params :: struct {
	raw_uv:           [2]f32,
	anchor_uv:        [2]f32,
	has_anchor:       bool,
	has_prev_dir:     bool,
	prev_dir_uv:      [2]f32,
	snap_step:        f32,
	polar_enabled:    bool,
	polar_step_deg:   f32,
	is_box_footprint: bool,
	shift_held:       bool,
	alt_held:         bool,
}

CAD_Polar_Snap_Result :: struct {
	uv:            [2]f32,
	polar_snapped: bool,
	snapped_deg:   f32,
	radial_len:    f32,
	is_perp_prev:  bool,
	is_para_prev:  bool,
}

@(private = "package")
_ed: struct {
	initialized:        bool,
	tool_active:        bool, // True when a CAD tool (Spline, Box, Extrude Face, Blast) is active instead of Picker/Move/Rotate/Scale
	prev_viewport_mode: control_rig_ed.Scene_Viewport_Mode,
	sub_tool:           CAD_Sub_Tool,
	brush_op:           cad_csg.Brush_Op,
	primitive:          cad_csg.Brush_Primitive,
	snap_step:          f32,
	axis_snap_enabled:  bool, // Polar angle snapping enabled relative to placed anchor point
	polar_step_deg:     f32,  // Configurable polar angle step: 15, 30, 45, or 90 degrees
	polar_origin_first_pt: bool, // False = Last Vertex (P_{n-1}), True = First Point (P0)
	osnap_enabled:      bool, // Magnetic Object Snap (Vertex, Edge Midpoint, Face Center)
	plane_locked:       bool, // Manual WorkPlane lock (`F`); when false & Idle, auto-aligns to hovered surface
	spline_wall_strip:  bool, // Thickens an open polyline (>= 2 pts) into a closed corridor wall polygon
	spline_wall_thickness: f32,
	show_brush_face_grips: bool, // Direct 6-face push/pull parametric resize grips on selected CSG brush
	grid_half_ext:      f32,
	brush_color:        [4]f32,
	brush_destructible: bool,
	brush_anchored:     bool,
	blast_radius:       f32,
	blast_impulse:      f32,

	// Active 2D Sketch WorkPlane in 3D World Space (always aligned to World X/Y/Z axes)
	plane:              CAD_WorkPlane,

	// Hover & raycast state
	hover_valid:        bool,
	hover_snapped:      [3]f32,
	hover_raw_pos:      [3]f32,
	hover_raw_normal:   [3]f32,
	hover_uv:           [2]f32,
	hover_vol:          ^cad_csg.CSGVolume,
	hover_brush_idx:    int,

	// Active Polar Protractor & OSNAP visual guide state
	snap_guide_active:  bool,
	snap_guide_from:    [3]f32,
	snap_guide_dir:     [3]f32,
	snap_guide_col:     [4]f32,
	snap_guide_label:   string,
	polar_arc_active:   bool,
	polar_snapped_deg:  f32,
	polar_radial_len:   f32,
	osnap_active:       bool,
	osnap_kind:         OSNAP_Kind,
	osnap_world_pt:     [3]f32,

	// 2D Polyline / Catmull-Rom Spline Sketch state (`Spline_Poly_Sketch`)
	sketch_points:      [dynamic]cad_csg.CSG_Profile_Point,
	sketch_next_smooth: bool, // false = Sharp CAD Corner, true = Smooth Catmull-Rom Spline Curve
	sketch_freehand:    bool, // Freehand squiggly stroke mode (or hold Shift + Drag)
	sketch_tension:     f32,
	sketch_drag_pt_idx: int,  // >= 0 when dragging an existing control vertex

	// 2-Stage Box / Primitive & Extrude state (3D Ray-Axis projected)
	draft_stage:         Draft_Stage,
	footprint_dragged:   bool,
	start_uv:            [2]f32,
	curr_uv:             [2]f32,
	extrude_height:      f32,
	extrude_axis_origin: [3]f32,
	extrude_start_s:     f32,

	// Blender-Style Face Extrude / Intrude + Axis Selection state (works on BOTH Polygon Meshes & CSG Volumes!)
	extrude_axis_mode:      Extrude_Axis_Mode,
	extrude_csg_behavior:   Extrude_CSG_Behavior,
	extrude_inset_margin:   f32,  // Inset margin (0.0 .. 0.80) when extruding/intruding a face
	push_active:            bool,
	push_is_poly_mesh:      bool, // True when extruding/intruding a polygon face on an Editable_Poly_Mesh / MeshFilter
	push_poly_face_idx:     int,
	push_poly_ring_verts:   [dynamic]u32,
	push_poly_base_pos:     [dynamic][3]f32,
	push_vol:               ^cad_csg.CSGVolume,
	push_brush_idx:         int,
	push_spawned_brush_idx: int,  // >= 0 when extruding/intruding a new CSG segment/pocket brush
	push_face_axis:         int,  // 0=X, 1=Y, 2=Z, 3=Profile_2D top/bottom cap, 4=Profile_2D side wall
	push_face_sign:         f32,  // +1 or -1
	push_world_origin:      [3]f32,
	push_world_normal:      [3]f32,
	push_drag_axis_world:   [3]f32,
	push_local_normal:      [3]f32,
	push_wall_dir_2d:       [2]f32,
	push_start_s:           f32,
	push_current_delta:     f32,
	push_orig_center:       [3]f32,
	push_orig_size:         [3]f32,
	push_orig_height:       f32,
	push_orig_profile:      [dynamic]cad_csg.CSG_Profile_Point,
	push_face_profile:      [dynamic]cad_csg.CSG_Profile_Point, // Exact 2D polygon of the clicked CSG face
	push_face_u:            [3]f32,
	push_face_v:            [3]f32,
	push_face_center_local: [3]f32,
	push_face_color:        [4]u8,
	push_hull_idx:          int,
	push_plane_idx:         int,
	push_orig_plane_dist:   f32,

	// Selected brush index in active CSGVolume + per-brush 3D gizmo state
	selected_brush_idx:            int,
	selected_blast_idx:            int,
	show_cut_and_blast_wireframes: bool,
	show_chunk_grid:               bool, // Visualizes 8m^3 Voxel-like CSG_Chunk grid cells & telemetry in Scene3D
	gizmo_edits_brush:      bool, // True = W/E/R gizmo moves/rotates/scales the selected CSG_Brush; False = moves whole CSGVolume
	brush_gizmo_dragging:   bool,
	brush_gizmo_start_pos:  [3]f32,
	brush_gizmo_start_cent: [3]f32,
	brush_gizmo_start_size: [3]f32,
	brush_gizmo_start_yaw:  f32,
	brush_gizmo_rot:        quaternion128,
	brush_gizmo_rot_start:  quaternion128,
	brush_gizmo_scale:      [3]f32,

	// SabreCSG / RealtimeCSG 2-Point Clip Plane Slicer state (`Clip_Brush_Plane`)
	clip_mode:          cad_csg.CSG_Clip_Mode,
	clip_split_gap:     f32,
	clip_has_pt_a:      bool,
	clip_pt_a:          [3]f32,
	clip_pt_b:          [3]f32,
	clip_surface_norm:  [3]f32,
	clip_vol:           ^cad_csg.CSGVolume,

	// Pillar 2 (Parametric Prefabs & Architectural Details) & Pillar 3 (See-Through Shatterable Glass) Editor state
	detail_preset:         cad_csg.CSG_Detail_Preset,
	detail_scale:          [3]f32,
	detail_yaw_deg:        f32,
	detail_array_count:    i32,
	detail_array_spacing:  f32,
	detail_pop_debris:     bool,
	selected_detail_idx:   int,
	glass_size_2d:         [2]f32,
	glass_cells_x:         i32,
	glass_cells_y:         i32,
	glass_material:        cad_csg.CSG_Material_Preset,
	selected_glass_idx:    int,

	// Parametric Architectural Prefab Builder state (Live-updates last spawned prefab when sliders change!)
	prefab_kind:           int, // 0 = Wall + Window + See-Through Glass, 1 = Wall + Doorway, 2 = Bunker Room, 3 = Staircase
	prefab_wall_size:      [3]f32,
	prefab_opening_size:   [2]f32,
	prefab_sill_height:    f32,
	prefab_material:       cad_csg.CSG_Material_Preset,
	last_prefab_vol:       engine.Transform_Handle,
	last_prefab_wall_id:   u32,
	last_prefab_cut_id:    u32,
	last_prefab_glass_id:  u32,

	// Soft Deformer Brush & Renderer Math Debug state (`Soft_Deform_Brush`)
	deform_mode:           cad_csg.CSG_Soft_Deform_Mode,
	deform_radius:         f32,
	deform_amplitude:      f32,
	show_deform_vectors:   bool,

	// Interactive 3D Polygon Glass Drawing Tool (`Draw_Glass_Poly`) & Faker CSG Toolbox state
	glass_poly_pts_3d:               [dynamic][3]f32,
	glass_poly_surf_norms:           [dynamic][3]f32,
	glass_poly_target_vol:           ^cad_csg.CSGVolume,
	glass_draw_carve_wall:           bool,
	faker_shape_kind:                cad_csg.CSG_Faker_Shape,
	faker_margin:                    f32,
	faker_material:                  cad_csg.CSG_Material_Preset,
	faker_make_projectile:           bool,
	faker_edit_inner_instance_gizmo: bool,
	faker_gizmo_dragging:            bool,
	faker_gizmo_start_pos:           [3]f32,
	faker_gizmo_start_off:           [3]f32,
	faker_gizmo_start_rot_deg:       [3]f32,
	faker_gizmo_rot_q:               quaternion128,
	faker_gizmo_rot_start_q:         quaternion128,
	faker_gizmo_scale:               [3]f32,
	faker_gizmo_start_scale:         [3]f32,
	mesh_wrap_mode:                  cad_csg.CSG_Mesh_Wrap_Mode,
	line_trace_grid_res:             i32,
	mesh_wrap_multipass:             bool,
	mesh_wrap_passes:                i32,
	mesh_wrap_tightness:             f32,
	tool_cut_material_guid:          engine.Asset_GUID, // Optional weapon/tool cut material override (e.g. Magic Sword slash; empty = Blunt Impact / Mesh Fallback)
	tool_cut_tex_guid:               engine.Asset_GUID, // Texture GUID bound to the Cut / Crater Fill Material
	tool_cut_albedo:                 [4]f32,            // Albedo color tint for the Cut / Crater Fill Material
	tool_cut_albedo_enabled:         bool,              // True when custom Cut / Crater Fill Albedo color override is active

	// Godot-Style Procedural Texture & Material Studio state
	proc_tex_pattern:      cad_csg.CSG_Procedural_Tex_Pattern,
	proc_tex_size:         i32,
	proc_tex_scale:        f32,
	proc_tex_contrast:     f32,
	proc_tex_color_a:      [4]f32,
	proc_tex_color_b:      [4]f32,
	proc_tex_preview_guid: engine.Asset_GUID,
	proc_tex_dirty:        bool,
	proc_tex_export_status:string,
	deform_tex_preview_guid:engine.Asset_GUID,

	// Live keyboard numeric override buffer + `Tab` Length / Angle CAD HUD state
	num_buf:                [32]u8,
	num_len:                int,
	hud_angle_field_active: bool,
	hud_locked_len_valid:   bool,
	hud_locked_len:         f32,

	// Direct 6-Face Live Parametric Resize Grips state
	face_grip_dragging:   bool,
	face_grip_axis:       int,
	face_grip_sign:       f32,
	face_grip_accum:      f32,
	face_grip_start_cent: [3]f32,
	face_grip_start_size: [3]f32,
	face_grip_start_h:    f32,
}

// Helper for 3D Ruler (`view_scene.odin`) to query the exact world AABB of a `CSGVolume` object.
get_object_world_aabb_for_ruler :: proc(tH: engine.Transform_Handle) -> (lo, hi: [3]f32, ok: bool) {
	w := engine.ctx_world()
	if w == nil || tH == {} || !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return {}, {}, false
	_, vol := engine.transform_get_comp(tH, cad_csg.CSGVolume)
	if vol != nil {
		if vlo, vhi, vok := cad_csg.csg_volume_local_aabb(vol); vok {
			tw := engine.transform_world(tH)
			return tw.position + vlo * tw.scale, tw.position + vhi * tw.scale, true
		}
	}
	return {}, {}, false
}

@(private = "package")
_ensure_init :: proc() {
	if _ed.initialized do return
	_ed.initialized            = true
	_ed.tool_active            = false
	_ed.prev_viewport_mode     = control_rig_ed.scene_viewport_mode
	_ed.sub_tool               = .Spline_Poly_Sketch
	_ed.brush_op               = .Add
	_ed.primitive              = .Box
	_ed.snap_step              = 0.25
	_ed.axis_snap_enabled      = true
	_ed.polar_step_deg         = 15.0
	_ed.polar_origin_first_pt  = false
	_ed.osnap_enabled          = true
	_ed.plane_locked           = false
	_ed.spline_wall_strip      = false
	_ed.spline_wall_thickness  = 0.35
	_ed.show_brush_face_grips  = true
	_ed.grid_half_ext          = 10.0
	_ed.brush_color            = {0.78, 0.81, 0.86, 1.0}
	_ed.brush_destructible     = true
	_ed.brush_anchored         = false
	_ed.blast_radius           = 0.12
	_ed.blast_impulse          = 14.0
	_ed.extrude_height         = 2.0
	_ed.extrude_axis_mode      = .Face_Normal
	_ed.extrude_csg_behavior   = .Extrude_Intrude_Segment
	_ed.extrude_inset_margin   = 0.20
	_ed.selected_brush_idx            = -1
	_ed.selected_blast_idx            = -1
	_ed.show_cut_and_blast_wireframes = true
	_ed.show_chunk_grid               = false
	_ed.gizmo_edits_brush      = true
	_ed.push_brush_idx         = -1
	_ed.push_spawned_brush_idx = -1
	_ed.push_poly_face_idx     = -1
	_ed.sketch_drag_pt_idx     = -1
	_ed.sketch_tension         = 0.25
	_ed.clip_mode              = .Split_Both
	_ed.clip_split_gap         = 0.0
	_ed.detail_preset          = .Gothic_Pillar
	_ed.detail_scale           = {1.0, 1.0, 1.0}
	_ed.detail_yaw_deg         = 0.0
	_ed.detail_array_count     = 4
	_ed.detail_array_spacing   = 2.2
	_ed.detail_pop_debris      = true
	_ed.selected_detail_idx    = -1
	_ed.glass_size_2d          = {2.4, 1.5}
	_ed.glass_cells_x          = 6
	_ed.glass_cells_y          = 4
	_ed.glass_material         = .Tempered_Glass
	_ed.selected_glass_idx     = -1
	_ed.prefab_kind            = 0
	_ed.prefab_wall_size       = {6.0, 3.4, 0.45}
	_ed.prefab_opening_size    = {2.4, 1.5}
	_ed.prefab_sill_height     = 1.0
	_ed.prefab_material        = .Concrete
	_ed.deform_mode            = .Dent_Inward
	_ed.deform_radius          = 1.85
	_ed.deform_amplitude       = 0.55
	_ed.show_deform_vectors    = true
	_ed.glass_draw_carve_wall  = true
	_ed.faker_shape_kind       = .Auto_Convex_Hull
	_ed.faker_margin           = 0.035
	_ed.faker_material         = .Steel_Plate
	_ed.faker_make_projectile  = false
	_ed.mesh_wrap_mode         = .Exact_Face_Decompose
	_ed.line_trace_grid_res    = 7
	_ed.mesh_wrap_multipass    = true
	_ed.mesh_wrap_passes       = 2
	_ed.mesh_wrap_tightness    = 0.75
	_ed.tool_cut_albedo        = {1.0, 1.0, 1.0, 1.0}
	_ed.proc_tex_pattern       = .Glass_Frosted_Streaks
	_ed.proc_tex_size          = 128
	_ed.proc_tex_scale         = 4.0
	_ed.proc_tex_contrast      = 1.0
	_ed.proc_tex_color_a       = {0.58, 0.88, 0.98, 0.34}
	_ed.proc_tex_color_b       = {0.92, 0.98, 1.00, 0.86}
	_ed.proc_tex_dirty         = true
	_reset_workplane_to_ground()
	handles.pick_register({
		click = _pick_csg_volume_click,
		band  = _pick_csg_volume_band,
	})
}

// True when standard W/E/R transform mode is active on a multi-brush CSGVolume (or Faker CSG inner mesh instance)
// and the user is transforming an individual brush or the inner GPU Mesh Instance.
is_editing_csg_brush :: proc() -> bool {
	_sync_viewport_mode()
	if _ed.tool_active do return false
	w := engine.ctx_world()
	if w == nil do return false
	sel := engine.inspector_active_selection()
	if sel == {} || !engine.pool_valid(&w.transforms, engine.Handle(sel)) do return false
	_, vol := engine.transform_get_comp(sel, cad_csg.CSGVolume)
	if vol == nil || !vol.enabled do return false
	if vol.is_faker_mesh && _ed.faker_edit_inner_instance_gizmo do return true
	if !_ed.gizmo_edits_brush || len(vol.brushes) <= 1 do return false
	return _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(vol.brushes)
}

@(private = "package")
_reset_transient_tool_state :: proc() {
	_ed.draft_stage            = .Idle
	_ed.footprint_dragged      = false
	_ed.push_active            = false
	_ed.brush_gizmo_dragging   = false
	_ed.face_grip_dragging     = false
	_ed.sketch_drag_pt_idx     = -1
	_ed.clip_has_pt_a          = false
	clear(&_ed.glass_poly_pts_3d)
	clear(&_ed.glass_poly_surf_norms)
	_ed.glass_poly_target_vol  = nil
	_ed.num_len                = 0
	_ed.hud_angle_field_active = false
	_ed.hud_locked_len_valid   = false
	_ed.snap_guide_active      = false
	_ed.polar_arc_active       = false
	_ed.osnap_active           = false
	handles.claim_mouse(false)
}

// Synchronizes `_ed.tool_active` and the CAD Mode Session Memory Cache when the user switches the `Modes:` dropdown in Scene3D.
@(private = "package")
_sync_viewport_mode :: proc() {
	_ensure_init()
	cur_mode := control_rig_ed.scene_viewport_mode
	if cur_mode != _ed.prev_viewport_mode {
		if cur_mode == .CAD_Blockout {
			enter_cad_mode_memory_cache()
			_ed.tool_active = true
		} else {
			_ed.tool_active = false
			_reset_transient_tool_state()
			release_cad_mode_memory_cache()
		}
		_ed.prev_viewport_mode = cur_mode
	}
}

// True when a CAD drawing/extrude/blast tool is currently the active tool in Scene3D
// (mutually exclusive with Picker / Move / Rotate / Scale / Handles on the Tools bar).
is_cad_tool_active :: proc() -> bool {
	_sync_viewport_mode()
	return _ed.tool_active
}

// True while the user is actively mid-sketch, mid-box-draft, or mid-face-extrude.
is_cad_tool_busy :: proc() -> bool {
	_sync_viewport_mode()
	return _ed.tool_active && (_ed.draft_stage != .Idle || _ed.push_active || len(_ed.sketch_points) > 0 || _ed.num_len > 0)
}

active_cad_sub_tool :: proc() -> CAD_Sub_Tool {
	_ensure_init()
	return _ed.sub_tool
}

// Activates a specific CAD sub-tool (deselecting Move/Rotate/Scale on the Scene3D Tools bar).
activate_cad_tool :: proc(tool: CAD_Sub_Tool) {
	_ensure_init()
	_ensure_mesh_ed_init()
	_reset_transient_tool_state()
	if _ed.sub_tool != tool {
		clear(&_ed.sketch_points)
	}
	if tool != .Soft_Deform_Brush && tool != .Clip_Brush_Plane {
		_mesh_ed.workspace_tab = .CSG_Editor
	}
	_ed.tool_active        = true
	_ed.sub_tool           = tool
	control_rig_ed.scene_viewport_mode = .CAD_Blockout
	_ed.prev_viewport_mode = .CAD_Blockout
}

// Deactivates any active CAD drawing sub-tool so standard Picker (Q), Move (W), Rotate (E),
// Scale (R), and Handles (T) gizmos operate normally in Scene3D while staying in CAD Mode!
deactivate_cad_tool :: proc() {
	_ensure_init()
	_ed.tool_active = false
	_reset_transient_tool_state()
	clear(&_ed.sketch_points)
}


// Toggles a CAD tool from the Scene3D Tools overlay bar: clicking an already-active
// CAD tool toggles it off back to standard Move/Rotate/Scale mode.
toggle_cad_tool :: proc(tool: CAD_Sub_Tool) {
	_sync_viewport_mode()
	if _ed.tool_active && _ed.sub_tool == tool {
		deactivate_cad_tool()
	} else {
		activate_cad_tool(tool)
	}
}

@(private = "package")
_reset_workplane_to_ground :: proc() {
	_ed.plane = CAD_WorkPlane{
		origin    = {0, 0, 0},
		normal    = {0, 1, 0},
		u_axis    = {1, 0, 0}, // World +X
		v_axis    = {0, 0, 1}, // World +Z
		is_custom = false,
	}
}

// Aligns the WorkPlane to `pos` and `normal` while strictly locking `u_axis` and `v_axis`
// to canonical World X, Y, Z axes (never camera rotation!).
@(private = "package")
_align_workplane_to_surface :: proc(pos, normal: [3]f32) {
	n := linalg.normalize0(normal)
	u, v: [3]f32
	if abs(n.y) > 0.72 {
		// Floor or Ceiling plane -> U = World +X, V = World +Z
		u = {1, 0, 0}
		v = {0, 0, 1}
	} else if abs(n.z) > 0.72 {
		// North/South Wall -> U = World +X, V = World +Y (Up)
		u = {1, 0, 0}
		v = {0, 1, 0}
	} else if abs(n.x) > 0.72 {
		// East/West Wall -> U = World +Z, V = World +Y (Up)
		u = {0, 0, 1}
		v = {0, 1, 0}
	} else {
		// Sloped surface: keep V aligned with World +Y (Up) projected onto plane, and U horizontal
		world_up := [3]f32{0, 1, 0}
		u = linalg.normalize0(linalg.cross(world_up, n))
		if linalg.length2(u) < 1e-4 do u = {1, 0, 0}
		v = linalg.normalize0(linalg.cross(n, u))
		if v.y < 0 do v = -v
	}
	// Snap origin to metric grid along U and V so coordinates stay clean
	_ed.plane = CAD_WorkPlane{
		origin    = pos,
		normal    = n,
		u_axis    = u,
		v_axis    = v,
		is_custom = true,
	}
}

// Find or create the active `CSGVolume` in the scene.
// Never grabs an arbitrary unselected `CSGVolume` from the scene!
@(private = "package")
_resolve_active_volume :: proc(create_if_missing := false) -> (vol: ^cad_csg.CSGVolume, owner: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return nil, {}

	sel := engine.inspector_active_selection()
	if sel != {} && engine.pool_valid(&w.transforms, engine.Handle(sel)) {
		if _, v := engine.transform_get_comp(sel, cad_csg.CSGVolume); v != nil && v.enabled {
			return v, sel
		}
	}

	if _ed.hover_vol != nil && _ed.hover_vol.enabled && _ed.hover_vol.owner != {} &&
	   engine.pool_valid(&w.transforms, engine.Handle(_ed.hover_vol.owner)) {
		return _ed.hover_vol, engine.Transform_Handle(_ed.hover_vol.owner)
	}

	if _mesh_ed.target_owner != {} && engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) {
		if _, v := engine.transform_get_comp(_mesh_ed.target_owner, cad_csg.CSGVolume); v != nil && v.enabled {
			return v, _mesh_ed.target_owner
		}
	}

	if !create_if_missing do return nil, {}
	scene := engine.sm_scene_get_active()
	if scene == nil do return nil, {}

	root_h := engine.Transform_Handle(scene.root.handle)
	new_h := engine.transform_new("CSG_Blockout_Volume", root_h)
	engine.transform_ensure_unique_name(new_h)
	_, ptr := engine.transform_add_comp(new_h, .CSGVolume)
	vol = cast(^cad_csg.CSGVolume)ptr
	if vol != nil {
		cad_csg.reset_CSGVolume(vol)
	}
	scene.dirty = true
	engine.inspector_request_select(new_h)
	return vol, new_h
}

@(private = "package")
_snap_scalar :: #force_inline proc(val, step: f32) -> f32 {
	if step <= 0.0001 do return val
	return math.round(val / step) * step
}

// Closest signed distance along a 3D axis `(axis_origin, axis_dir)` to the 3D mouse `ray`.
// Used for camera-independent 3D extrusion and face push/pull!
@(private = "package")
_ray_closest_dist_along_axis :: proc(ray: engine.Ray, axis_origin, axis_dir: [3]f32) -> f32 {
	w0 := ray.origin - axis_origin
	b  := linalg.dot(ray.direction, axis_dir)
	d  := linalg.dot(ray.direction, w0)
	e  := linalg.dot(axis_dir, w0)
	denom := 1.0 - b * b
	if abs(denom) < 1e-4 {
		return -e
	}
	return clamp((b * d - e) / denom, -200.0, 200.0)
}

// Helper returning the World Axis name ("X", "Y", "Z") and color for a WorkPlane tangent vector.
@(private = "package")
_world_axis_info :: proc(ax: [3]f32) -> (name: string, col: [4]f32) {
	if abs(ax.x) >= 0.7 {
		return "X", {1.0, 0.28, 0.28, 0.95} // World X = Red
	}
	if abs(ax.y) >= 0.7 {
		return "Y", {0.25, 0.95, 0.35, 0.95} // World Y = Green
	}
	return "Z", {0.30, 0.62, 1.0, 0.95}      // World Z = Blue
}

@(private = "package")
_wrap_deg_180 :: #force_inline proc(deg: f32) -> f32 {
	d := deg
	for d <= -180.0 do d += 360.0
	for d > 180.0 do d -= 360.0
	return d
}

// Pure, unit-testable True Anchor-Origin Polar & Grid Math:
// - NEVER angle-snaps to `{0, 0}` when `has_anchor == false` (before Point 1 is placed)!
// - NEVER collapses 2-corner `Box_Primitive` footprints onto `0°/90°` rays (`shift_held` locks `1:1` Square aspect)!
// - Projects radially from `anchor_uv` along exact polar angle increments (`15°/30°/45°/90°` + `⊥/∥` prev-segment inference),
//   quantizing Euclidean segment length `r` cleanly to `snap_step` (`alt_held` bypasses all snapping).
compute_cad_polar_snap :: proc(p: CAD_Polar_Snap_Params) -> (res: CAD_Polar_Snap_Result) {
	if p.alt_held {
		res.uv = p.raw_uv
		if p.has_anchor {
			res.radial_len = linalg.length(p.raw_uv - p.anchor_uv)
		}
		return res
	}

	// 1. Before Point 1 is placed (`!p.has_anchor`): ONLY snap Cartesian `(u, v)` to metric grid!
	//    Never snap angles relative to `{0, 0}`!
	if !p.has_anchor {
		res.uv = {
			_snap_scalar(p.raw_uv.x, p.snap_step),
			_snap_scalar(p.raw_uv.y, p.snap_step),
		}
		return res
	}

	// 2. 2-Corner Box / Primitive Footprint: never collapse width or depth onto 0°/90° polar rays!
	//    Quantizes `(du, dv)` relative to `anchor_uv` so OSNAP-anchored boxes have exact metric Width x Depth,
	//    and holding `Shift` locks a 1:1 Square footprint relative to `anchor_uv`.
	if p.is_box_footprint {
		du := p.raw_uv.x - p.anchor_uv.x
		dv := p.raw_uv.y - p.anchor_uv.y
		u := p.anchor_uv.x + _snap_scalar(du, p.snap_step)
		v := p.anchor_uv.y + _snap_scalar(dv, p.snap_step)
		if p.shift_held {
			min_side := max(p.snap_step, 0.10)
			side := max(_snap_scalar(max(abs(du), abs(dv)), p.snap_step), min_side)
			su: f32 = 1.0 if du >= 0 else -1.0
			sv: f32 = 1.0 if dv >= 0 else -1.0
			u = p.anchor_uv.x + su * side
			v = p.anchor_uv.y + sv * side
			res.polar_snapped = true
			res.snapped_deg   = math.atan2(sv, su) * (180.0 / math.PI)
		}
		res.uv = {u, v}
		res.radial_len = linalg.length(res.uv - p.anchor_uv)
		return res
	}

	// 3. True Radial Polar Projection strictly from `p.anchor_uv`!
	delta := p.raw_uv - p.anchor_uv
	raw_r := linalg.length(delta)
	eff_polar := p.polar_enabled || p.shift_held
	eff_step  := f32(15.0) if p.shift_held else (p.polar_step_deg if p.polar_step_deg > 0.5 else 15.0)
	min_r     := max(p.snap_step * 0.25, 0.08)

	if eff_polar && raw_r >= min_r {
		raw_deg := math.atan2(delta.y, delta.x) * (180.0 / math.PI)
		matched := false
		chosen_deg: f32 = 0.0

		// 3a. Previous-segment Parallel (`0°/180°`) and Perpendicular (`±90°`) inference
		if p.has_prev_dir && linalg.length2(p.prev_dir_uv) > 1e-4 {
			prev_deg := math.atan2(p.prev_dir_uv.y, p.prev_dir_uv.x) * (180.0 / math.PI)
			infer_tol := min(eff_step * 0.35, 6.0)
			cands := [4]struct {
				ang:  f32,
				perp: bool,
			}{
				{_wrap_deg_180(prev_deg), false},
				{_wrap_deg_180(prev_deg + 180.0), false},
				{_wrap_deg_180(prev_deg + 90.0), true},
				{_wrap_deg_180(prev_deg - 90.0), true},
			}
			best_diff := infer_tol
			for c in cands {
				diff := abs(_wrap_deg_180(raw_deg - c.ang))
				if diff <= best_diff {
					best_diff  = diff
					chosen_deg = c.ang
					matched    = true
					res.is_perp_prev = c.perp
					res.is_para_prev = !c.perp
				}
			}
		}

		// 3b. Configurable Protractor Step (`15°`, `30°`, `45°`, `90°`)
		if !matched {
			nearest := _wrap_deg_180(math.round(raw_deg / eff_step) * eff_step)
			tol     := min(eff_step * 0.5, 15.0)
			if abs(_wrap_deg_180(raw_deg - nearest)) <= tol {
				chosen_deg = nearest
				matched    = true
			}
		}

		if matched {
			r := raw_r
			if p.snap_step > 0.0001 {
				r = max(_snap_scalar(raw_r, p.snap_step), max(p.snap_step, 0.05))
			}
			dir_2d: [2]f32
			if abs(chosen_deg) < 1e-3 {
				dir_2d = {1, 0}
			} else if abs(abs(chosen_deg) - 180.0) < 1e-3 {
				dir_2d = {-1, 0}
			} else if abs(chosen_deg - 90.0) < 1e-3 {
				dir_2d = {0, 1}
			} else if abs(chosen_deg + 90.0) < 1e-3 {
				dir_2d = {0, -1}
			} else {
				rad := chosen_deg * (math.PI / 180.0)
				dir_2d = {math.cos(rad), math.sin(rad)}
			}
			res.uv            = p.anchor_uv + dir_2d * r
			res.polar_snapped = true
			res.snapped_deg   = chosen_deg
			res.radial_len    = r
			return res
		}
	}

	res.uv = {
		_snap_scalar(p.raw_uv.x, p.snap_step),
		_snap_scalar(p.raw_uv.y, p.snap_step),
	}
	res.radial_len = linalg.length(res.uv - p.anchor_uv)
	return res
}

// Magnetic Object Snap (`OSNAP`): Vertex (`□`), Edge Midpoint (`△`), and Face Center (`◎`)
// across nearby CSG brushes and compiled hulls in world space!
@(private = "package")
_find_osnap_world_point :: proc(world_hint: [3]f32) -> (best_pt: [3]f32, best_kind: OSNAP_Kind, ok: bool) {
	if !_ed.osnap_enabled do return {}, .None, false
	w := engine.ctx_world()
	if w == nil do return {}, .None, false

	tol := max(_ed.snap_step * 0.55, 0.22)
	best_score := tol

	check_cand :: #force_inline proc(cand, hint: [3]f32, kind: OSNAP_Kind, best_s: ^f32, out_p: ^[3]f32, out_k: ^OSNAP_Kind, out_ok: ^bool) {
		d := linalg.length(cand - hint)
		// Slight priority bias toward exact corners (`Vertex`), then `Midpoint`, then `Face_Center`
		bias: f32 = 0.0 if kind == .Vertex else (0.02 if kind == .Midpoint else 0.035)
		if d <= best_s^ && d + bias < best_s^ + 0.01 {
			best_s^ = d
			out_p^  = cand
			out_k^  = kind
			out_ok^ = true
		}
	}

	v_it := engine.pool_iterator(cad_csg.csg_volumes(w))
	for vol, _ in engine.pool_next(&v_it) {
		if vol == nil || !vol.enabled || vol.is_ghoul_bone_csg || !engine.transform_active_in_hierarchy(vol.owner) do continue
		tw := engine.transform_world(engine.Transform_Handle(vol.owner))
		rot_q := engine.quat_to_native(tw.rotation)

		if vlo, vhi, vok := cad_csg.csg_volume_local_aabb(vol); vok {
			w_lo := tw.position + vlo * tw.scale - {tol + 0.5, tol + 0.5, tol + 0.5}
			w_hi := tw.position + vhi * tw.scale + {tol + 0.5, tol + 0.5, tol + 0.5}
			if world_hint.x < w_lo.x || world_hint.x > w_hi.x ||
			   world_hint.y < w_lo.y || world_hint.y > w_hi.y ||
			   world_hint.z < w_lo.z || world_hint.z > w_hi.z {
				continue
			}
		}

		for b in vol.brushes {
			if b.primitive == .Profile_2D && len(b.profile_points) >= 2 {
				orig := tw.position + linalg.quaternion128_mul_vector3(rot_q, b.center * tw.scale)
				pu := linalg.quaternion128_mul_vector3(rot_q, b.plane_u)
				pv := linalg.quaternion128_mul_vector3(rot_q, b.plane_v)
				pn := linalg.quaternion128_mul_vector3(rot_q, b.plane_normal)
				n_pts := len(b.profile_points)
				for i in 0 ..< n_pts {
					pa := b.profile_points[i].uv
					pb := b.profile_points[(i + 1) % n_pts].uv
					wa0 := orig + pu * pa.x + pv * pa.y
					wa1 := wa0 + pn * b.extrude_height
					wb0 := orig + pu * pb.x + pv * pb.y
					wb1 := wb0 + pn * b.extrude_height
					check_cand(wa0, world_hint, .Vertex, &best_score, &best_pt, &best_kind, &ok)
					check_cand(wa1, world_hint, .Vertex, &best_score, &best_pt, &best_kind, &ok)
					check_cand((wa0 + wb0) * 0.5, world_hint, .Midpoint, &best_score, &best_pt, &best_kind, &ok)
					check_cand((wa1 + wb1) * 0.5, world_hint, .Midpoint, &best_score, &best_pt, &best_kind, &ok)
					check_cand((wa0 + wa1) * 0.5, world_hint, .Midpoint, &best_score, &best_pt, &best_kind, &ok)
				}
			} else {
				yaw_q := rot_q * linalg.quaternion_angle_axis_f32(math.to_radians(b.yaw_deg), [3]f32{0, 1, 0})
				bc := tw.position + linalg.quaternion128_mul_vector3(rot_q, b.center * tw.scale)
				he := b.size * tw.scale * 0.5
				ax_x := linalg.quaternion128_mul_vector3(yaw_q, [3]f32{1, 0, 0}) * he.x
				ax_y := linalg.quaternion128_mul_vector3(yaw_q, [3]f32{0, 1, 0}) * he.y
				ax_z := linalg.quaternion128_mul_vector3(yaw_q, [3]f32{0, 0, 1}) * he.z

				corners: [8][3]f32
				for k in 0 ..< 8 {
					sx: f32 = -1.0 if (k & 1) == 0 else 1.0
					sy: f32 = -1.0 if (k & 2) == 0 else 1.0
					sz: f32 = -1.0 if (k & 4) == 0 else 1.0
					corners[k] = bc + ax_x * sx + ax_y * sy + ax_z * sz
					check_cand(corners[k], world_hint, .Vertex, &best_score, &best_pt, &best_kind, &ok)
				}
				box_edges := [12][2]int{
					{0, 1}, {2, 3}, {4, 5}, {6, 7},
					{0, 2}, {1, 3}, {4, 6}, {5, 7},
					{0, 4}, {1, 5}, {2, 6}, {3, 7},
				}
				for e in box_edges {
					check_cand((corners[e[0]] + corners[e[1]]) * 0.5, world_hint, .Midpoint, &best_score, &best_pt, &best_kind, &ok)
				}
				face_offsets := [6][3]f32{ax_x, -ax_x, ax_y, -ax_y, ax_z, -ax_z}
				for fo in face_offsets {
					check_cand(bc + fo, world_hint, .Face_Center, &best_score, &best_pt, &best_kind, &ok)
				}
			}
		}

		// Fallback for converted / plane-clipped CSG volumes without authored brushes
		if len(vol.brushes) == 0 {
			model_m := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			for _, ch in vol.chunks {
				if ch == nil do continue
				for v_s in ch.verts {
					vw := (model_m * [4]f32{v_s.position.x, v_s.position.y, v_s.position.z, 1.0}).xyz
					check_cand(vw, world_hint, .Vertex, &best_score, &best_pt, &best_kind, &ok)
				}
			}
		}
	}
	return
}

// Resolves the current Polar Snap Anchor (`has_anchor`, `anchor_uv`, `has_prev_dir`, `prev_dir_uv`)
// strictly from placed points (NEVER `{0, 0}` when Idle!).
@(private = "package")
_resolve_active_polar_anchor :: proc() -> (has_anchor: bool, anchor_uv: [2]f32, has_prev_dir: bool, prev_dir_uv: [2]f32, is_box_footprint: bool) {
	if _ed.sub_tool == .Spline_Poly_Sketch {
		if _ed.sketch_drag_pt_idx >= 0 && _ed.sketch_drag_pt_idx < len(_ed.sketch_points) {
			if _ed.sketch_drag_pt_idx > 0 {
				return true, _ed.sketch_points[_ed.sketch_drag_pt_idx - 1].uv, false, {}, false
			} else if len(_ed.sketch_points) > 1 {
				return true, _ed.sketch_points[1].uv, false, {}, false
			}
			return false, {}, false, {}, false
		}
		if len(_ed.sketch_points) > 0 {
			if _ed.polar_origin_first_pt {
				return true, _ed.sketch_points[0].uv, false, {}, false
			}
			last_idx := len(_ed.sketch_points) - 1
			anchor_uv = _ed.sketch_points[last_idx].uv
			if last_idx >= 1 {
				has_prev_dir = true
				prev_dir_uv  = anchor_uv - _ed.sketch_points[last_idx - 1].uv
			}
			return true, anchor_uv, has_prev_dir, prev_dir_uv, false
		}
	} else if _ed.sub_tool == .Box_Primitive && _ed.draft_stage == .Drawing_Footprint {
		return true, _ed.start_uv, false, {}, true
	}
	return false, {}, false, {}, false
}

// Intersects `ray` with the active `CAD_WorkPlane`, applying Magnetic OSNAP,
// explicit 1-push Axis Locks (`X/Y/Z`), True Anchor-Origin Polar Protractor snapping, and metric grid snapping.
@(private = "package")
_raycast_workplane :: proc(ray: engine.Ray) -> (world_pt: [3]f32, uv: [2]f32, ok: bool) {
	_ed.snap_guide_active = false
	_ed.polar_arc_active  = false
	_ed.osnap_active      = false

	denom := linalg.dot(_ed.plane.normal, ray.direction)
	if abs(denom) < 1e-5 do return {}, {}, false
	t := linalg.dot(_ed.plane.origin - ray.origin, _ed.plane.normal) / denom
	if t < 0.01 || t > 500.0 do return {}, {}, false

	hit := ray.origin + ray.direction * t
	rel := hit - _ed.plane.origin
	raw_uv := [2]f32{
		linalg.dot(rel, _ed.plane.u_axis),
		linalg.dot(rel, _ed.plane.v_axis),
	}

	shift_held := im.GetIO().KeyShift || input.key_down(.LSHIFT) || input.key_down(.RSHIFT)
	alt_held   := im.GetIO().KeyAlt   || input.key_down(.LALT)   || input.key_down(.RALT)
	// When Freehand mode is active in Spline Sketch, don't treat Shift as 15° polar lock during drag
	is_freehand_stroke := _ed.sub_tool == .Spline_Poly_Sketch && _ed.sketch_freehand && (im.IsMouseDown(.Left) || input.mouse_down(.Left))
	polar_shift := shift_held && !is_freehand_stroke

	has_anchor, anchor_uv, has_prev_dir, prev_dir_uv, is_box_fp := _resolve_active_polar_anchor()

	// 1. Magnetic OSNAP (Vertex / Midpoint / Face Center) projected cleanly onto WorkPlane!
	if _ed.osnap_enabled && !alt_held && !is_freehand_stroke {
		if os_pt, os_kind, os_ok := _find_osnap_world_point(hit); os_ok {
			os_rel := os_pt - _ed.plane.origin
			if abs(linalg.dot(os_rel, _ed.plane.normal)) <= max(_ed.snap_step * 2.0, 0.65) {
				uv = {
					linalg.dot(os_rel, _ed.plane.u_axis),
					linalg.dot(os_rel, _ed.plane.v_axis),
				}
				world_pt = _ed.plane.origin + _ed.plane.u_axis * uv.x + _ed.plane.v_axis * uv.y
				_ed.osnap_active   = true
				_ed.osnap_kind     = os_kind
				_ed.osnap_world_pt = world_pt
				return world_pt, uv, true
			}
		}
	}

	// 2. Explicit 1-push World Axis Lock (`[X]`, `[Y]`, `[Z]`) when an anchor exists
	ax_lock := active_axis_constraint()
	if ax_lock != .Free && has_anchor && !alt_held {
		ref_3d := _ed.plane.origin + _ed.plane.u_axis * anchor_uv.x + _ed.plane.v_axis * anchor_uv.y
		u_name, u_col := _world_axis_info(_ed.plane.u_axis)
		v_name, v_col := _world_axis_info(_ed.plane.v_axis)
		target_name := "X" if ax_lock == .X else ("Y" if ax_lock == .Y else "Z")
		if u_name == target_name {
			u_s := _snap_scalar(raw_uv.x, _ed.snap_step)
			uv = {u_s, anchor_uv.y}
			world_pt = _ed.plane.origin + _ed.plane.u_axis * uv.x + _ed.plane.v_axis * uv.y
			_ed.snap_guide_active = true
			_ed.snap_guide_from   = ref_3d
			_ed.snap_guide_dir    = _ed.plane.u_axis if u_s >= anchor_uv.x else -_ed.plane.u_axis
			_ed.snap_guide_col    = u_col
			_ed.snap_guide_label  = fmt.tprintf("LOCK %s", u_name)
			return world_pt, uv, true
		} else if v_name == target_name {
			v_s := _snap_scalar(raw_uv.y, _ed.snap_step)
			uv = {anchor_uv.x, v_s}
			world_pt = _ed.plane.origin + _ed.plane.u_axis * uv.x + _ed.plane.v_axis * uv.y
			_ed.snap_guide_active = true
			_ed.snap_guide_from   = ref_3d
			_ed.snap_guide_dir    = _ed.plane.v_axis if v_s >= anchor_uv.y else -_ed.plane.v_axis
			_ed.snap_guide_col    = v_col
			_ed.snap_guide_label  = fmt.tprintf("LOCK %s", v_name)
			return world_pt, uv, true
		}
	}

	// 3. True Anchor-Origin Polar & Grid Snap
	snap_res := compute_cad_polar_snap(CAD_Polar_Snap_Params{
		raw_uv           = raw_uv,
		anchor_uv        = anchor_uv,
		has_anchor       = has_anchor,
		has_prev_dir     = has_prev_dir,
		prev_dir_uv      = prev_dir_uv,
		snap_step        = _ed.snap_step,
		polar_enabled    = _ed.axis_snap_enabled,
		polar_step_deg   = _ed.polar_step_deg,
		is_box_footprint = is_box_fp,
		shift_held       = polar_shift,
		alt_held         = alt_held,
	})
	uv = snap_res.uv

	// 4. Honor `Tab`-locked Length during Angle entry in Spline Sketch!
	if _ed.sub_tool == .Spline_Poly_Sketch && has_anchor && _ed.hud_locked_len_valid && abs(_ed.hud_locked_len) >= 0.02 {
		dir_uv := uv - anchor_uv
		if linalg.length2(dir_uv) < 1e-5 {
			dir_uv = {1, 0}
		} else {
			dir_uv = linalg.normalize0(dir_uv)
		}
		uv = anchor_uv + dir_uv * _ed.hud_locked_len
		snap_res.radial_len = abs(_ed.hud_locked_len)
	}

	if snap_res.polar_snapped && has_anchor {
		ref_3d := _ed.plane.origin + _ed.plane.u_axis * anchor_uv.x + _ed.plane.v_axis * anchor_uv.y
		rad    := snap_res.snapped_deg * (math.PI / 180.0)
		ray_3d := linalg.normalize0(_ed.plane.u_axis * math.cos(rad) + _ed.plane.v_axis * math.sin(rad))
		_, u_col := _world_axis_info(_ed.plane.u_axis)
		_, v_col := _world_axis_info(_ed.plane.v_axis)

		col := [4]f32{1.0, 0.86, 0.24, 0.95}
		if abs(snap_res.snapped_deg) < 0.5 || abs(abs(snap_res.snapped_deg) - 180.0) < 0.5 {
			col = u_col
		} else if abs(abs(snap_res.snapped_deg) - 90.0) < 0.5 {
			col = v_col
		} else if snap_res.is_perp_prev {
			col = {0.35, 0.98, 0.72, 0.96}
		}

		_ed.snap_guide_active = true
		_ed.snap_guide_from   = ref_3d
		_ed.snap_guide_dir    = ray_3d
		_ed.snap_guide_col    = col
		if is_box_fp {
			_ed.snap_guide_label = "1:1 SQUARE"
		} else if snap_res.is_perp_prev {
			_ed.snap_guide_label = fmt.tprintf("PERP %.0f°", snap_res.snapped_deg)
		} else if snap_res.is_para_prev {
			_ed.snap_guide_label = fmt.tprintf("PARA %.0f°", snap_res.snapped_deg)
		} else {
			_ed.snap_guide_label = fmt.tprintf("Ang %.0f°", snap_res.snapped_deg)
		}
		_ed.polar_arc_active  = !is_box_fp
		_ed.polar_snapped_deg = snap_res.snapped_deg
		_ed.polar_radial_len  = snap_res.radial_len
	}

	world_pt = _ed.plane.origin + _ed.plane.u_axis * uv.x + _ed.plane.v_axis * uv.y
	return world_pt, uv, true
}

// Default extrusion height: when `- Cut Hole (Subtract)` is active, defaults to NEGATIVE (`-normal`)
// so drawing on a wall or floor immediately cuts INTO the solid volume instead of extruding into empty air!
@(private = "package")
_default_extrude_height :: proc() -> f32 {
	mag := max(abs(_ed.extrude_height), max(_ed.snap_step * 2.0, 1.0))
	return -mag if _ed.brush_op == .Subtract else mag
}

@(private = "package")
_key_just_pressed :: #force_inline proc(k: input.Key, im_k: im.Key) -> bool {
	return input.key_pressed(k) || im.IsKeyPressed(im_k, false)
}

// Appends digits / '.', ',', 'x', '-' to the live numeric override buffer during drafting,
// plus `Tab` switching between Length (`m`) and Angle (`deg`) (or `Width` and `Depth` in Box tool!).
@(private = "package")
_poll_numeric_keyboard_input :: proc() -> (committed: bool) {
	num_keys := [10]struct {
		k:     input.Key,
		kp:    input.Key,
		im_k:  im.Key,
		im_kp: im.Key,
		ch:    u8,
	}{
		{._0, .KP_0, ._0, .Keypad0, '0'},
		{._1, .KP_1, ._1, .Keypad1, '1'},
		{._2, .KP_2, ._2, .Keypad2, '2'},
		{._3, .KP_3, ._3, .Keypad3, '3'},
		{._4, .KP_4, ._4, .Keypad4, '4'},
		{._5, .KP_5, ._5, .Keypad5, '5'},
		{._6, .KP_6, ._6, .Keypad6, '6'},
		{._7, .KP_7, ._7, .Keypad7, '7'},
		{._8, .KP_8, ._8, .Keypad8, '8'},
		{._9, .KP_9, ._9, .Keypad9, '9'},
	}

	for nk in num_keys {
		if _key_just_pressed(nk.k, nk.im_k) || _key_just_pressed(nk.kp, nk.im_kp) {
			if _ed.num_len < len(_ed.num_buf) - 1 {
				_ed.num_buf[_ed.num_len] = nk.ch
				_ed.num_len += 1
			}
		}
	}
	if _key_just_pressed(.PERIOD, .Period) || _key_just_pressed(.KP_DECIMAL, .KeypadDecimal) {
		if _ed.num_len < len(_ed.num_buf) - 1 {
			_ed.num_buf[_ed.num_len] = '.'
			_ed.num_len += 1
		}
	}
	if _key_just_pressed(.MINUS, .Minus) || _key_just_pressed(.KP_MINUS, .KeypadSubtract) {
		if _ed.num_len == 0 {
			_ed.num_buf[_ed.num_len] = '-'
			_ed.num_len += 1
		}
	}
	if _key_just_pressed(.COMMA, .Comma) {
		if _ed.num_len > 0 && _ed.num_len < len(_ed.num_buf) - 1 {
			_ed.num_buf[_ed.num_len] = ','
			_ed.num_len += 1
		}
	}
	if _key_just_pressed(.X, .X) && _ed.num_len > 0 {
		if _ed.num_len < len(_ed.num_buf) - 1 {
			_ed.num_buf[_ed.num_len] = 'x'
			_ed.num_len += 1
		}
	}
	if _key_just_pressed(.BACKSPACE, .Backspace) && _ed.num_len > 0 {
		_ed.num_len -= 1
	}

	// `Tab` switches Length (`m`) <-> Angle (`deg`) in Spline Sketch, or inserts `x` for `Width x Depth` in Box Footprint!
	if _key_just_pressed(.TAB, .Tab) {
		if _ed.sub_tool == .Spline_Poly_Sketch && _ed.draft_stage != .Extruding_Height && len(_ed.sketch_points) > 0 {
			if !_ed.hud_angle_field_active {
				if _ed.num_len > 0 {
					if l_val, l_ok := strconv.parse_f32(strings.trim_space(string(_ed.num_buf[:_ed.num_len]))); l_ok && abs(l_val) >= 0.02 {
						_ed.hud_locked_len       = l_val
						_ed.hud_locked_len_valid = true
					}
					_ed.num_len = 0
				}
				_ed.hud_angle_field_active = true
			} else {
				_ed.hud_angle_field_active = false
				_ed.num_len = 0
			}
		} else if _ed.sub_tool == .Box_Primitive && _ed.draft_stage == .Drawing_Footprint && _ed.num_len > 0 {
			cur_s := string(_ed.num_buf[:_ed.num_len])
			if strings.index_byte(cur_s, 'x') < 0 && strings.index_byte(cur_s, ',') < 0 && _ed.num_len < len(_ed.num_buf) - 1 {
				_ed.num_buf[_ed.num_len] = 'x'
				_ed.num_len += 1
			}
		}
	}

	if (_key_just_pressed(.RETURN, .Enter) || _key_just_pressed(.KP_ENTER, .KeypadEnter)) && (_ed.num_len > 0 || _ed.hud_locked_len_valid) {
		str := string(_ed.num_buf[:_ed.num_len])
		_ed.num_len = 0

		// Support `WxD` or `U,V` (e.g. `4x3` or `4,3`)
		sep_idx := strings.index_byte(str, 'x')
		if sep_idx < 0 do sep_idx = strings.index_byte(str, ',')

		if sep_idx > 0 {
			w_str := strings.trim_space(str[:sep_idx])
			d_str := strings.trim_space(str[sep_idx + 1:])
			w_val, w_ok := strconv.parse_f32(w_str)
			d_val, d_ok := strconv.parse_f32(d_str)
			if w_ok && d_ok {
				if _ed.sub_tool == .Spline_Poly_Sketch && _ed.draft_stage != .Extruding_Height {
					base_uv := _ed.sketch_points[len(_ed.sketch_points) - 1].uv if len(_ed.sketch_points) > 0 else [2]f32{0, 0}
					append(&_ed.sketch_points, cad_csg.CSG_Profile_Point{
						uv      = base_uv + {w_val, d_val},
						smooth  = _ed.sketch_next_smooth,
						tension = _ed.sketch_tension,
					})
					_ed.hud_angle_field_active = false
					_ed.hud_locked_len_valid   = false
					_ed.draft_stage = .Drawing_Footprint
					return false
				} else if _ed.draft_stage == .Drawing_Footprint && abs(w_val) >= 0.05 && abs(d_val) >= 0.05 {
					su := f32(1.0) if _ed.curr_uv.x >= _ed.start_uv.x else f32(-1.0)
					sv := f32(1.0) if _ed.curr_uv.y >= _ed.start_uv.y else f32(-1.0)
					_ed.curr_uv.x = _ed.start_uv.x + su * abs(w_val)
					_ed.curr_uv.y = _ed.start_uv.y + sv * abs(d_val)
					_ed.extrude_height = _default_extrude_height()
					_ed.draft_stage = .Extruding_Height
					return false
				}
			}
		} else {
			val, ok := strconv.parse_f32(strings.trim_space(str))
			// Handle Spline Angle / Locked-Length Polar Segment Commit (`L` + `Tab` + `Angle` + `Enter`)!
			if _ed.sub_tool == .Spline_Poly_Sketch && _ed.draft_stage != .Extruding_Height && len(_ed.sketch_points) > 0 && (_ed.hud_angle_field_active || _ed.hud_locked_len_valid) {
				last_uv := _ed.sketch_points[len(_ed.sketch_points) - 1].uv
				cur_delta := _ed.hover_uv - last_uv
				seg_r := _ed.hud_locked_len if _ed.hud_locked_len_valid else linalg.length(cur_delta)
				if abs(seg_r) < 0.05 do seg_r = max(_ed.snap_step, 0.5)
				ang_deg: f32
				if _ed.hud_angle_field_active && ok {
					ang_deg = val
				} else if !_ed.hud_angle_field_active && ok {
					seg_r = val
					ang_deg = math.atan2(cur_delta.y, cur_delta.x) * (180.0 / math.PI)
				} else {
					ang_deg = math.atan2(cur_delta.y, cur_delta.x) * (180.0 / math.PI)
				}
				rad := ang_deg * (math.PI / 180.0)
				append(&_ed.sketch_points, cad_csg.CSG_Profile_Point{
					uv      = last_uv + {math.cos(rad) * seg_r, math.sin(rad) * seg_r},
					smooth  = _ed.sketch_next_smooth,
					tension = _ed.sketch_tension,
				})
				_ed.hud_angle_field_active = false
				_ed.hud_locked_len_valid   = false
				_ed.draft_stage = .Drawing_Footprint
				return false
			}

			if ok && abs(val) >= 0.02 {
				if _ed.push_active {
					_apply_face_push_pull_delta(val)
					_ed.push_active = false
					if _ed.push_is_poly_mesh {
						_finish_poly_face_interactive_extrude(val)
					}
					return true
				}
				if _ed.draft_stage == .Extruding_Height {
					_ed.extrude_height = val
					return true
				}
				if _ed.sub_tool == .Spline_Poly_Sketch {
					// Place next vertex at exact distance `val` along current cursor direction!
					if len(_ed.sketch_points) == 0 {
						append(&_ed.sketch_points, cad_csg.CSG_Profile_Point{
							uv      = _ed.hover_uv,
							smooth  = _ed.sketch_next_smooth,
							tension = _ed.sketch_tension,
						})
					} else {
						last_uv := _ed.sketch_points[len(_ed.sketch_points) - 1].uv
						dir_uv := _ed.hover_uv - last_uv
						if linalg.length2(dir_uv) < 1e-4 {
							dir_uv = {1, 0}
						} else {
							dir_uv = linalg.normalize0(dir_uv)
						}
						append(&_ed.sketch_points, cad_csg.CSG_Profile_Point{
							uv      = last_uv + dir_uv * val,
							smooth  = _ed.sketch_next_smooth,
							tension = _ed.sketch_tension,
						})
					}
					_ed.draft_stage = .Drawing_Footprint
					return false
				} else if _ed.draft_stage == .Drawing_Footprint {
					su := f32(1.0) if _ed.curr_uv.x >= _ed.start_uv.x else f32(-1.0)
					sv := f32(1.0) if _ed.curr_uv.y >= _ed.start_uv.y else f32(-1.0)
					_ed.curr_uv.x = _ed.start_uv.x + su * abs(val)
					_ed.curr_uv.y = _ed.start_uv.y + sv * abs(val)
					_ed.extrude_height = _default_extrude_height()
					_ed.draft_stage = .Extruding_Height
					return false
				}
			}
		}
	}
	return false
}

// Expands an open 2D polyline (`>= 2` points) into a mitered closed corridor wall-strip polygon of width `thickness`!
@(private = "package")
_build_wall_strip_polygon_2d :: proc(
	pts:       []cad_csg.CSG_Profile_Point,
	thickness: f32,
	allocator := context.temp_allocator,
) -> []cad_csg.CSG_Profile_Point {
	spine := cad_csg.csg_eval_profile_2d(pts, false, 6, context.temp_allocator)
	n := len(spine)
	if n < 2 do return nil

	half_t := max(thickness * 0.5, 0.04)
	out := make([dynamic]cad_csg.CSG_Profile_Point, 0, n * 2, allocator)
	right_rail := make([][2]f32, n, context.temp_allocator)

	for i in 0 ..< n {
		miter_n: [2]f32
		if i == 0 {
			d := linalg.normalize0(spine[1] - spine[0])
			if linalg.length2(d) < 1e-5 do d = {1, 0}
			miter_n = {-d.y, d.x} * half_t
		} else if i == n - 1 {
			d := linalg.normalize0(spine[n - 1] - spine[n - 2])
			if linalg.length2(d) < 1e-5 do d = {1, 0}
			miter_n = {-d.y, d.x} * half_t
		} else {
			d0 := linalg.normalize0(spine[i] - spine[i - 1])
			d1 := linalg.normalize0(spine[i + 1] - spine[i])
			n0 := [2]f32{-d0.y, d0.x}
			n1 := [2]f32{-d1.y, d1.x}
			avg_n := linalg.normalize0(n0 + n1)
			if linalg.length2(avg_n) < 1e-4 {
				miter_n = n1 * half_t
			} else {
				denom := max(linalg.dot(avg_n, n1), 0.42)
				miter_n = avg_n * min(half_t / denom, half_t * 2.2)
			}
		}
		append(&out, cad_csg.CSG_Profile_Point{uv = spine[i] + miter_n, smooth = false, tension = 0.0})
		right_rail[i] = spine[i] - miter_n
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(&out, cad_csg.CSG_Profile_Point{uv = right_rail[i], smooth = false, tension = 0.0})
	}
	return out[:]
}

// Computes the world center and world size of the currently drafted Box / Primitive brush.
// When `_ed.brush_op == .Subtract`, adds a small surface penetration offset so coplanar wall cuts
// slice cleanly through the outer face!
@(private = "package")
_draft_brush_box :: proc() -> (center: [3]f32, size: [3]f32) {
	u_min := min(_ed.start_uv.x, _ed.curr_uv.x)
	u_max := max(_ed.start_uv.x, _ed.curr_uv.x)
	v_min := min(_ed.start_uv.y, _ed.curr_uv.y)
	v_max := max(_ed.start_uv.y, _ed.curr_uv.y)

	step := max(_ed.snap_step, 0.1)
	if u_max - u_min < step * 0.5 do u_max = u_min + step
	if v_max - v_min < step * 0.5 do v_max = v_min + step

	u_mid := (u_min + u_max) * 0.5
	v_mid := (v_min + v_max) * 0.5
	w_u := u_max - u_min
	d_v := v_max - v_min
	h_n := _ed.extrude_height
	if abs(h_n) < 0.05 {
		h_n = -step if _ed.brush_op == .Subtract else step
	}

	// For boolean subtraction, expand slightly along the plane normal so coplanar wall cuts never leave a skin
	cut_pad: f32 = 0.08 if _ed.brush_op == .Subtract else 0.0
	base_center := _ed.plane.origin + _ed.plane.u_axis * u_mid + _ed.plane.v_axis * v_mid
	center = base_center + _ed.plane.normal * (h_n * 0.5)

	u_abs := [3]f32{abs(_ed.plane.u_axis.x), abs(_ed.plane.u_axis.y), abs(_ed.plane.u_axis.z)}
	v_abs := [3]f32{abs(_ed.plane.v_axis.x), abs(_ed.plane.v_axis.y), abs(_ed.plane.v_axis.z)}
	n_abs := [3]f32{abs(_ed.plane.normal.x), abs(_ed.plane.normal.y), abs(_ed.plane.normal.z)}
	ext_world := u_abs * w_u + v_abs * d_v + n_abs * (abs(h_n) + cut_pad)
	size = {max(ext_world.x, 0.1), max(ext_world.y, 0.1), max(ext_world.z, 0.1)}
	return
}

// Spawns a brand-new standalone top-level `CSGVolume` GameObject centered at `world_pos`.
@(private = "file")
_spawn_standalone_csg_volume_at :: proc(name_prefix: string, world_pos: [3]f32) -> (vol: ^cad_csg.CSGVolume, owner: engine.Transform_Handle) {
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return nil, {}

	root_h := engine.Transform_Handle(scene.root.handle)
	new_h := engine.transform_new(name_prefix, root_h)
	engine.transform_ensure_unique_name(new_h)
	if t := engine.pool_get(&w.transforms, engine.Handle(new_h)); t != nil {
		t.position = world_pos
	}
	_, ptr := engine.transform_add_comp(new_h, .CSGVolume)
	vol = cast(^cad_csg.CSGVolume)ptr
	if vol != nil {
		cad_csg.reset_CSGVolume(vol)
	}
	scene.dirty = true
	engine.inspector_request_select(new_h)
	return vol, new_h
}

@(private = "package")
_commit_drafted_box_brush :: proc() {
	world_center, size := _draft_brush_box()

	vol: ^cad_csg.CSGVolume
	owner: engine.Transform_Handle
	if _ed.brush_op == .Add {
		// Additive drafting ALWAYS creates its own standalone top-level `CSGVolume` GameObject
		// centered at `world_center` (never stuffed into an existing CSGVolume!).
		vol, owner = _spawn_standalone_csg_volume_at(fmt.tprintf("CSG_%v_Volume", _ed.primitive), world_center)
	} else {
		vol, owner = _resolve_active_volume(create_if_missing = false)
	}
	// If subtracting (`- Cut Hole`), also carve any overlapping bone-attached Ghoul CSG volumes in world space!
	if _ed.brush_op == .Subtract {
		if w := engine.ctx_world(); w != nil {
			b_wmin := world_center - size * 0.55
			b_wmax := world_center + size * 0.55
			v_it := engine.pool_iterator(cad_csg.csg_volumes(w))
			for g_vol, _ in engine.pool_next(&v_it) {
				if g_vol == nil || !g_vol.enabled || !g_vol.is_ghoul_bone_csg || g_vol == vol do continue
				gh := engine.Transform_Handle(g_vol.owner)
				gtw := engine.transform_world(gh)
				if !cad_csg.aabb_overlaps(gtw.position - {0.5, 0.5, 0.5}, gtw.position + {0.5, 0.5, 0.5}, b_wmin, b_wmax, 0.35) do continue
				inv_g := linalg.inverse(engine.trs_matrix(gtw.position, gtw.rotation, gtw.scale))
				g_loc_c := (inv_g * [4]f32{world_center.x, world_center.y, world_center.z, 1.0}).xyz
				_ = cad_csg.csg_volume_add_brush(g_vol, "Ghoul_Cut", .Subtract, _ed.primitive, g_loc_c, size, 0, {155, 28, 28, 255}, true, false)
				cad_csg.csg_volume_rebuild(g_vol)
			}
		}
	}

	if vol == nil || owner == {} do return
	csg_history_ensure_baseline(vol)

	tw := engine.transform_world(owner)
	local_center := world_center - tw.position

	col_u8 := [4]u8{
		u8(clamp(_ed.brush_color.r * 255.0, 0, 255)),
		u8(clamp(_ed.brush_color.g * 255.0, 0, 255)),
		u8(clamp(_ed.brush_color.b * 255.0, 0, 255)),
		255,
	}

	op_str := "Add" if _ed.brush_op == .Add else "Cut"
	b_name := fmt.tprintf("%s_%v_%d", op_str, _ed.primitive, max(vol.next_brush_id, 1))
	idx := cad_csg.csg_volume_add_brush(
		vol,
		b_name,
		_ed.brush_op,
		_ed.primitive,
		local_center,
		size,
		0,
		col_u8,
		_ed.brush_destructible,
		_ed.brush_anchored,
	)
	_ed.selected_brush_idx = idx
	cad_csg.csg_volume_rebuild(vol)
	csg_history_commit(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(private = "package")
_commit_drafted_spline_profile_brush :: proc() {
	min_pts := 2 if _ed.spline_wall_strip else 3
	if len(_ed.sketch_points) < min_pts do return

	final_pts: []cad_csg.CSG_Profile_Point
	if _ed.spline_wall_strip {
		final_pts = _build_wall_strip_polygon_2d(_ed.sketch_points[:], _ed.spline_wall_thickness, context.temp_allocator)
		if len(final_pts) < 4 do return
	} else {
		buf := make([]cad_csg.CSG_Profile_Point, len(_ed.sketch_points), context.temp_allocator)
		copy(buf, _ed.sketch_points[:])
		final_pts = buf
	}

	h_n := _ed.extrude_height
	if abs(h_n) < 0.05 {
		h_n = _default_extrude_height()
	}

	// Center the 2D spline profile around its own 2D bounding-box midpoint (`uv_mid`)
	// so the resulting CSGVolume's Transform gizmo and Center of Mass sit dead-center on the spline island
	// rather than back at the workplane/world origin `(0, 0, 0)`!
	uv_min := final_pts[0].uv
	uv_max := final_pts[0].uv
	for pt in final_pts {
		uv_min.x = min(uv_min.x, pt.uv.x)
		uv_min.y = min(uv_min.y, pt.uv.y)
		uv_max.x = max(uv_max.x, pt.uv.x)
		uv_max.y = max(uv_max.y, pt.uv.y)
	}
	uv_mid := (uv_min + uv_max) * 0.5
	for &pt in final_pts {
		pt.uv -= uv_mid
	}
	world_profile_origin := _ed.plane.origin + _ed.plane.u_axis * uv_mid.x + _ed.plane.v_axis * uv_mid.y
	world_center         := world_profile_origin + _ed.plane.normal * (h_n * 0.5)

	vol: ^cad_csg.CSGVolume
	owner: engine.Transform_Handle
	if _ed.brush_op == .Add {
		// Additive spline drafting ALWAYS creates its own standalone top-level `CSGVolume` GameObject
		// centered at the 3D centroid (`world_center`) of the extruded spline island!
		vol_name := "CSG_WallStrip_Volume" if _ed.spline_wall_strip else "CSG_Spline_Volume"
		vol, owner = _spawn_standalone_csg_volume_at(vol_name, world_center)
	} else {
		vol, owner = _resolve_active_volume(create_if_missing = false)
	}
	if vol == nil || owner == {} do return
	csg_history_ensure_baseline(vol)

	tw := engine.transform_world(owner)
	local_origin := world_profile_origin - tw.position

	// For boolean subtraction, shift origin slightly outward along +normal and extend height
	// so coplanar cuts slice cleanly through the wall's front face!
	if _ed.brush_op == .Subtract {
		pad := f32(0.05) if h_n < 0 else f32(-0.05)
		local_origin += _ed.plane.normal * pad
		h_n += (-0.10 if h_n < 0 else 0.10)
	}

	col_u8 := [4]u8{
		u8(clamp(_ed.brush_color.r * 255.0, 0, 255)),
		u8(clamp(_ed.brush_color.g * 255.0, 0, 255)),
		u8(clamp(_ed.brush_color.b * 255.0, 0, 255)),
		255,
	}

	op_str := "Add" if _ed.brush_op == .Add else "Cut"
	b_name := fmt.tprintf("%s_SplineProfile_%d", op_str, max(vol.next_brush_id, 1))
	idx := cad_csg.csg_volume_add_profile_brush(
		vol,
		b_name,
		_ed.brush_op,
		local_origin,
		_ed.plane.u_axis,
		_ed.plane.v_axis,
		_ed.plane.normal,
		final_pts,
		h_n,
		col_u8,
		_ed.brush_destructible,
		_ed.brush_anchored,
	)
	_ed.selected_brush_idx     = idx
	clear(&_ed.sketch_points)
	_ed.draft_stage            = .Idle
	_ed.hud_angle_field_active = false
	_ed.hud_locked_len_valid   = false
	cad_csg.csg_volume_rebuild(vol)
	csg_history_commit(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Resolve the active world-space extrusion direction for `Extrude_Axis_Mode`.
@(private = "package")
_resolve_extrude_axis_dir :: proc(face_normal: [3]f32) -> (dir: [3]f32, label: string, col: [4]f32) {
	switch _ed.extrude_axis_mode {
	case .Face_Normal:
		return linalg.normalize0(face_normal), "Face Normal (N)", {1.0, 0.85, 0.22, 1.0}
	case .World_X:
		sgn: f32 = 1.0 if face_normal.x >= -0.01 else -1.0
		return {sgn, 0, 0}, "World X Axis (X)", {1.0, 0.28, 0.28, 1.0}
	case .World_Y:
		sgn: f32 = 1.0 if face_normal.y >= -0.01 else -1.0
		return {0, sgn, 0}, "World Y Axis (Y)", {0.25, 0.95, 0.38, 1.0}
	case .World_Z:
		sgn: f32 = 1.0 if face_normal.z >= -0.01 else -1.0
		return {0, 0, sgn}, "World Z Axis (Z)", {0.32, 0.62, 1.0, 1.0}
	case .Free_Cursor:
		return linalg.normalize0(face_normal), "Free Cursor (G)", {0.88, 0.55, 1.0, 1.0}
	}
	return linalg.normalize0(face_normal), "Face Normal (N)", {1.0, 0.85, 0.22, 1.0}
}

// Extracts the exact 3D polygon (`CSG_Face_Poly`) of the hovered/clicked face on `vol` at `(local_p, local_n)`,
// whether `vol` was built from `brushes` (Box, Cylinder, Hex Pillar, Wedge, Profile_2D) OR `runtime_hulls` (converted Torus/Mesh)!
@(private = "package")
_extract_hovered_csg_face_poly :: proc(
	vol:     ^cad_csg.CSGVolume,
	b_idx:   int,
	local_p: [3]f32,
	local_n: [3]f32,
) -> (
	verts_out:    [dynamic][3]f32,
	face_n_out:   [3]f32,
	face_c_out:   [3]f32,
	col_out:      [4]u8,
	rt_hull_idx:  int,
	rt_plane_idx: int,
	ok:           bool,
) {
	rt_hull_idx  = -1
	rt_plane_idx = -1
	col_out      = {200, 210, 224, 255}
	if vol == nil do return

	match_hull_face :: proc(
		hull:    cad_csg.CSG_Convex,
		local_p: [3]f32,
		local_n: [3]f32,
		best_score: ^f32,
		best_verts: ^[dynamic][3]f32,
		best_n:     ^[3]f32,
		best_c:     ^[3]f32,
		best_col:   ^[4]u8,
		best_pi:    ^int,
	) -> bool {
		faces := make([dynamic]cad_csg.CSG_Face_Poly, 0, len(hull.planes), context.temp_allocator)
		cad_csg.convex_extract_faces(hull, &faces, context.temp_allocator)
		matched := false
		for fp in faces {
			if len(fp.verts) < 3 do continue
			nd := linalg.dot(fp.normal, local_n)
			if nd < 0.65 do continue
			// Distance of `local_p` from this face plane and from face centroid
			fc: [3]f32
			for v in fp.verts do fc += v
			fc /= f32(len(fp.verts))
			plane_err := abs(linalg.dot(fp.normal, local_p - fc))
			if plane_err > 0.35 do continue
			cent_dist := linalg.length(local_p - fc)
			score := nd * 4.0 - plane_err * 8.0 - cent_dist * 0.25
			if score > best_score^ {
				best_score^ = score
				clear(best_verts)
				append(best_verts, ..fp.verts[:])
				best_n^   = fp.normal
				best_c^   = fc
				best_col^ = fp.color
				// Find matching plane index in `hull.planes`
				best_p_dot: f32 = -1.0
				for p, pi in hull.planes {
					d := linalg.dot(p.normal, fp.normal)
					if d > best_p_dot {
						best_p_dot = d
						best_pi^ = pi
					}
				}
				matched = true
			}
		}
		return matched
	}

	verts_out  = make([dynamic][3]f32, 0, 8, context.temp_allocator)
	best_score := f32(-1e9)
	best_pi    := -1

	// 1. If we hit a non-Profile_2D authored brush, test its unsplit convex hull first so chunk grid lines don't split the face!
	if b_idx >= 0 && b_idx < len(vol.brushes) {
		b := vol.brushes[b_idx]
		col_out = b.color
		if b.primitive != .Profile_2D {
			if bh, bh_ok := cad_csg.csg_make_primitive_convex(
				b.primitive, b.center, b.size, b.yaw_deg, b.color, max(b.uv_scale, 0.5), 0, b.anchored, b.id, context.temp_allocator,
			); bh_ok {
				if match_hull_face(bh, local_p, local_n, &best_score, &verts_out, &face_n_out, &face_c_out, &col_out, &best_pi) {
					return verts_out, face_n_out, face_c_out, col_out, -1, -1, true
				}
			}
		}
	}

	// 2. Test `vol.runtime_hulls` (e.g. converted Torus / Mesh or Baked CSG hulls)
	for rh, hi in vol.runtime_hulls {
		if !cad_csg.aabb_overlaps(rh.aabb_min, rh.aabb_max, local_p, local_p, 0.25) do continue
		pi := -1
		if match_hull_face(rh, local_p, local_n, &best_score, &verts_out, &face_n_out, &face_c_out, &col_out, &pi) {
			rt_hull_idx  = hi
			rt_plane_idx = pi
			ok           = true
		}
	}
	if ok do return

	// 3. Fallback: test compiled hulls inside `vol.chunks`
	for _, ch in vol.chunks {
		if ch == nil || !cad_csg.aabb_overlaps(ch.aabb_min, ch.aabb_max, local_p, local_p, 0.25) do continue
		for dh in ch.destructible_hulls {
			pi := -1
			if match_hull_face(dh, local_p, local_n, &best_score, &verts_out, &face_n_out, &face_c_out, &col_out, &pi) {
				ok = true
			}
		}
		for ih in ch.indestructible_hulls {
			pi := -1
			if match_hull_face(ih, local_p, local_n, &best_score, &verts_out, &face_n_out, &face_c_out, &col_out, &pi) {
				ok = true
			}
		}
	}
	return
}

// Applies a Blender-style Extrude (outward `delta > 0`) or Intrude (inward `delta < 0`) offset
// along the selected axis (`Normal`, `World X`, `World Y`, `World Z`, or `Free Cursor`) to:
// - An `Editable_Poly_Mesh` / `MeshFilter` polygon face (extruding/intruding a new topological face ring!)
// - Or ANY `CSGVolume` face (brushes OR converted `runtime_hulls`! Extruding outward extrudes the exact
//   polygon face; intruding inward insets/bevels the face and carves a boolean pocket for building interiors!).
@(private = "package")
_apply_face_push_pull_delta :: proc(delta: f32, free_offset: [3]f32 = {0, 0, 0}) {
	_ed.push_current_delta = delta
	move_vec := _ed.push_drag_axis_world * delta
	if _ed.extrude_axis_mode == .Free_Cursor && linalg.length2(free_offset) > 1e-6 {
		move_vec = free_offset
	}

	// Case 1: Extruding / Intruding a Polygon Mesh face (`Editable_Poly_Mesh`)!
	if _ed.push_is_poly_mesh {
		if len(_ed.push_poly_ring_verts) > 0 && len(_ed.push_poly_ring_verts) == len(_ed.push_poly_base_pos) {
			_, inv := _mesh_model()
			local_move := _xf_vec(inv, move_vec)
			for vi, k in _ed.push_poly_ring_verts {
				if int(vi) < len(_mesh_ed.verts) {
					_mesh_ed.verts[vi] = _ed.push_poly_base_pos[k] + local_move
				}
			}
			_rebuild_editable_mesh_gpu(commit = false)
		}
		return
	}

	// Case 2: Extruding / Intruding a CSGVolume Face (works on both `brushes` AND `runtime_hulls`!)
	vol := _ed.push_vol
	if vol == nil {
		vol, _ = _resolve_active_volume(false)
	}
	if vol == nil do return

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	// True Blender-Style Extrude/Intrude Segment on ANY CSG face using its exact 2D face polygon (`_ed.push_face_profile`):
	// - Outward (`delta >= 0`): extrudes ONLY that exact face polygon (`inset = 0.0` so non-square shapes like Cylinders,
	//   Hex Pillars, Wedges, and Torus segments extrude the clicked face instead of cloning the whole mesh!).
	// - Inward (`delta < 0`): insets/bevels the face polygon (`inset = max(_ed.extrude_inset_margin, 0.16)`) and carves
	//   an interior boolean subtract pocket so you can hollow out buildings!
	if _ed.extrude_csg_behavior == .Extrude_Intrude_Segment && len(_ed.push_face_profile) >= 3 {
		abs_d := max(abs(delta), 0.08)
		is_intrude := (delta < -0.02)

		tw_vol := engine.transform_world(engine.Transform_Handle(vol.owner))
		inv_rot := linalg.quaternion_inverse(engine.quat_to_native(tw_vol.rotation))
		local_drag_dir := linalg.normalize0(linalg.quaternion128_mul_vector3(inv_rot, _ed.push_drag_axis_world))
		if linalg.dot(local_drag_dir, _ed.push_local_normal) < 0 {
			local_drag_dir = -local_drag_dir
		}

		// Outward extrude uses the exact 1:1 face polygon (`scale = 1.0`);
		// Inward intrude insets the polygon so walls remain around the pocket!
		inset: f32 = 0.0
		if is_intrude {
			inset = clamp(max(_ed.extrude_inset_margin, 0.16), 0.08, 0.75)
		}
		scale_2d := 1.0 - inset

		if _ed.push_spawned_brush_idx < 0 || _ed.push_spawned_brush_idx >= len(vol.brushes) {
			if vol.brushes == nil {
				vol.brushes = make([dynamic]cad_csg.CSG_Brush, 0, 4)
			}
			pts := make([dynamic]cad_csg.CSG_Profile_Point, len(_ed.push_face_profile))
			for p, pi in _ed.push_face_profile {
				pts[pi] = cad_csg.CSG_Profile_Point{
					uv      = p.uv * scale_2d,
					smooth  = false,
					tension = 0.25,
				}
			}
			new_id := max(vol.next_brush_id, 1)
			vol.next_brush_id = new_id + 1
			new_b := cad_csg.CSG_Brush{
				id             = new_id,
				name           = fmt.aprintf("Intrude_Pocket_%d" if is_intrude else "Extrude_Face_%d", new_id),
				op             = .Subtract if is_intrude else .Add,
				primitive      = .Profile_2D,
				center         = _ed.push_face_center_local,
				size           = {1, 1, 1},
				color          = _ed.push_face_color,
				uv_scale       = 0.5,
				destructible   = true,
				anchored       = false,
				plane_u        = _ed.push_face_u,
				plane_v        = _ed.push_face_v,
				plane_normal   = _ed.push_local_normal,
				extrude_height = abs_d,
				profile_points = pts,
			}
			append(&vol.brushes, new_b)
			_ed.push_spawned_brush_idx = len(vol.brushes) - 1
		}

		sb := &vol.brushes[_ed.push_spawned_brush_idx]
		sb.op = .Subtract if is_intrude else .Add
		if len(sb.profile_points) == len(_ed.push_face_profile) {
			for p, pi in _ed.push_face_profile {
				sb.profile_points[pi].uv = p.uv * scale_2d
			}
		}
		if is_intrude {
			// Start slightly outside the face (+0.04) and extrude inward (-local_drag_dir) so the pocket cuts cleanly through the surface
			sb.center         = _ed.push_face_center_local + _ed.push_local_normal * 0.04
			sb.plane_normal   = local_drag_dir
			sb.extrude_height = -(abs_d + 0.06)
		} else {
			// Start slightly inside the face (-0.02) and extrude outward (+local_drag_dir) so it welds seamlessly
			sb.center         = _ed.push_face_center_local - _ed.push_local_normal * 0.02
			sb.plane_normal   = local_drag_dir
			sb.extrude_height = abs_d + 0.02
		}

		cad_csg.csg_volume_rebuild(vol)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		return
	}

	// Move Face Plane mode (`Extrude_CSG_Behavior.Move_Face_Plane`) on `runtime_hulls` when no brush is hit
	if (_ed.push_brush_idx < 0 || _ed.push_brush_idx >= len(vol.brushes)) &&
	   _ed.push_hull_idx >= 0 && _ed.push_hull_idx < len(vol.runtime_hulls) {
		rh := &vol.runtime_hulls[_ed.push_hull_idx]
		if _ed.push_plane_idx >= 0 && _ed.push_plane_idx < len(rh.planes) {
			rh.planes[_ed.push_plane_idx].dist = max(_ed.push_orig_plane_dist + delta, -500.0)
			cad_csg.convex_rebuild_bounds_and_prune(rh, false)
			cad_csg.csg_volume_rebuild(vol)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		return
	}

	if _ed.push_brush_idx < 0 || _ed.push_brush_idx >= len(vol.brushes) do return

	b := &vol.brushes[_ed.push_brush_idx]
	if b.primitive == .Profile_2D {
		if _ed.push_face_axis == 3 {
			// Top or bottom cap of Profile_2D extrusion
			orig_h := _ed.push_orig_height
			h_sign: f32 = 1.0 if orig_h >= 0 else -1.0
			if _ed.push_face_sign > 0 {
				new_h := orig_h + delta
				if abs(new_h) < 0.1 do new_h = 0.1 * h_sign
				b.extrude_height = new_h
				b.center = _ed.push_orig_center
			} else {
				new_h := orig_h + delta * h_sign
				if abs(new_h) < 0.1 do new_h = 0.1 * h_sign
				actual_d := (new_h - orig_h) * h_sign
				b.extrude_height = new_h
				b.center = _ed.push_orig_center - b.plane_normal * (actual_d * h_sign)
			}
		} else if _ed.push_face_axis == 4 && len(_ed.push_orig_profile) == len(b.profile_points) {
			c2d: [2]f32
			for p in _ed.push_orig_profile do c2d += p.uv
			c2d /= f32(max(len(_ed.push_orig_profile), 1))
			w_dir := _ed.push_wall_dir_2d
			for p, i in _ed.push_orig_profile {
				rel := p.uv - c2d
				if linalg.dot(rel, w_dir) >= -0.05 {
					b.profile_points[i].uv = p.uv + w_dir * delta
				} else {
					b.profile_points[i].uv = p.uv
				}
			}
		}
	} else {
		ax := clamp(_ed.push_face_axis, 0, 2)
		new_sz := max(_ed.push_orig_size[ax] + delta, 0.1)
		actual_d := new_sz - _ed.push_orig_size[ax]
		b.size[ax] = new_sz
		b.center = _ed.push_orig_center + _ed.push_local_normal * (actual_d * 0.5)
	}
	cad_csg.csg_volume_rebuild(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// ============================================================================
// SCENE3D COMPACT TOP TOOLBAR OVERLAY (`@(scene_overlay)`)
// ============================================================================

@(scene_overlay={id="cad_csg_mode", order=-90})
cad_csg_scene_overlay :: proc(vertical: bool) {
	_ = vertical
	_sync_viewport_mode()

	// Always tick and draw Red Faction blast shockwaves & dust clouds in Scene3D!
	cad_csg.csg_tick_and_draw_blast_fx(1.0 / 60.0)

	// Check if a CSGVolume is currently selected in standard Scene3D mode
	sel_vol: ^cad_csg.CSGVolume = nil
	sel_h: engine.Transform_Handle = {}
	if w := engine.ctx_world(); w != nil {
		sel := engine.inspector_active_selection()
		if sel != {} && engine.pool_valid(&w.transforms, engine.Handle(sel)) {
			sel_h = sel
			_, sel_vol = engine.transform_get_comp(sel, cad_csg.CSGVolume)
		}
	}

	if !_ed.tool_active && control_rig_ed.scene_viewport_mode != .CAD_Blockout {
		// Compact contextual bar when a CSGVolume is selected in standard W/E/R Transform mode!
		if sel_vol == nil do return

		// Direct 6-Face Live Parametric Resize Grips toggle
		fg_pushed := _ed.show_brush_face_grips
		if fg_pushed {
			im.PushStyleColorImVec4(.Button, {0.16, 0.58, 0.52, 0.95})
		}
		if im.SmallButton("6-Face Grips") {
			_ed.show_brush_face_grips = !_ed.show_brush_face_grips
		}
		if fg_pushed do im.PopStyleColor(1)
		widgets.ui_tool_script_loc(#location(_draw_and_handle_selected_brush_6face_grips), "Direct 6-Face Parametric CSG Resize Grips")
		widgets.tooltip("Show interactive push/pull dots on all 6 faces of the selected CSG brush (dragging one face keeps the opposite face anchored!).")
		im.SameLine(0, 4)

		if len(sel_vol.brushes) > 1 && _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(sel_vol.brushes) {
			sb := sel_vol.brushes[_ed.selected_brush_idx]
			gz_pushed := _ed.gizmo_edits_brush
			if gz_pushed {
				im.PushStyleColorImVec4(.Button, {0.20, 0.56, 0.78, 0.95})
				im.PushStyleColorImVec4(.ButtonHovered, {0.28, 0.66, 0.88, 1.00})
			}
			gz_lbl := fmt.ctprintf("Gizmo: Brush [%s]" if _ed.gizmo_edits_brush else "Gizmo: Whole Volume", sb.name)
			if im.SmallButton(gz_lbl) {
				_ed.gizmo_edits_brush = !_ed.gizmo_edits_brush
				_ed.brush_gizmo_dragging = false
			}
			if gz_pushed do im.PopStyleColor(2)
			widgets.ui_tool_script_loc(#location(_draw_and_handle_selected_brush_gizmo), "CSG Per-Brush 3D Transform Gizmo")
			widgets.tooltip("Toggle whether W / E / R moves/rotates/scales ONLY the clicked CSG Brush vs. the entire CSGVolume!")
			im.SameLine(0, 4)

			im.PushStyleColorImVec4(.Button, {0.82, 0.44, 0.14, 0.95})
			im.PushStyleColorImVec4(.ButtonHovered, {0.92, 0.54, 0.22, 1.00})
			if im.SmallButton("Detach -> RB") {
				if new_h := cad_csg.csg_detach_brush_to_volume(sel_vol, _ed.selected_brush_idx, true); new_h != {} {
					_ed.selected_brush_idx = 0
					engine.inspector_request_select(new_h)
				}
			}
			im.PopStyleColor(2)
			widgets.ui_tool_script_loc(#location(cad_csg.csg_detach_brush_to_volume), "Detach CSG Brush to Dynamic Physics Volume")
			widgets.tooltip("Pops this selected CSG Brush out into its own standalone Dynamic Rigidbody CSGVolume GameObject with Jolt physics!")
			im.SameLine(0, 4)
		}

		// Quick Dynamic Physics toggle on single-brush or detached CSG objects
		dyn_pushed := sel_vol.is_dynamic_rigidbody
		if dyn_pushed {
			im.PushStyleColorImVec4(.Button, {0.18, 0.64, 0.36, 0.95})
		}
		if im.SmallButton("Dynamic RB" if sel_vol.is_dynamic_rigidbody else "Static Env") {
			sel_vol.is_dynamic_rigidbody = !sel_vol.is_dynamic_rigidbody
			sel_vol.gpu_dirty = true
			cad_csg.csg_volume_sync_colliders_only(sel_vol)
		}
		if dyn_pushed do im.PopStyleColor(1)
		widgets.ui_tool_script_loc(#location(cad_csg.csg_volume_sync_colliders_only), "CSG Volume Jolt Collider / Rigidbody Sync")
		widgets.tooltip("Toggle Jolt Dynamic Rigidbody physics on this CSGVolume.")
		im.SameLine(0, 4)

		// Voxel-like CSG Chunk Grid visualizer toggle
		ch_pushed := _ed.show_chunk_grid
		if ch_pushed {
			im.PushStyleColorImVec4(.Button, {0.24, 0.58, 0.68, 0.95})
		}
		if im.SmallButton(fmt.ctprintf("Chunks (%d)", len(sel_vol.chunks))) {
			_ed.show_chunk_grid = !_ed.show_chunk_grid
		}
		if ch_pushed do im.PopStyleColor(1)
		widgets.ui_tool_script_loc(#location(_draw_csg_chunk_grid), "CSG Spatial Chunk Grid Visualizer")
		widgets.tooltip("Show/Hide the 8m x 8m x 8m Voxel-like CSG Spatial Chunks and per-chunk hull/triangle telemetry in Scene3D.")
		im.SameLine(0, 4)

		if can_revert_or_rewrap_csg_mesh(sel_h) {
			wrap_short := [4]cstring{"0:Exact", "1:SingleHull", "2:MultiRay", "3:Statue"}
			wm_i := clamp(int(_ed.mesh_wrap_mode), 0, 3)
			im.SetNextItemWidth(94)
			if im.BeginCombo("##top_wrap_mode", wrap_short[wm_i]) {
				wrap_full := [4]cstring{
					"0: Exact Face Decompose",
					"1: Single Smooth Ray Hull",
					"2: Multi-Section Spherical Rays",
					"3: Anatomy Sliced Statue",
				}
				for i in 0 ..< 4 {
					if im.Selectable(wrap_full[i], wm_i == i) {
						_ed.mesh_wrap_mode = cad_csg.CSG_Mesh_Wrap_Mode(i)
						_ = convert_editable_mesh_to_csg(make_dynamic_physics = sel_vol.is_dynamic_rigidbody, append_to_active_volume = false)
					}
				}
				im.EndCombo()
			}
			widgets.tooltip("Switch CSG Wrap Method (0..3) and immediately re-wrap the source mesh in-place!")
			im.SameLine(0, 4)

			if widgets.small_button_colored("Undo -> Mesh", {0.82, 0.36, 0.16, 0.95}) {
				_ = revert_csg_to_original_mesh(sel_h)
				return
			}
			widgets.tooltip("Undoes the Mesh -> CSG conversion and restores the original MeshFilter + MeshRenderer!")
			im.SameLine(0, 4)
		}

		if im.SmallButton("CSG Panel") {
			wnd.open("cad_csg_panel")
		}
		widgets.ui_tool_script_loc(#location(_draw_cad_csg_panel_contents), "CAD & CSG Blockout Panel")
		widgets.tooltip("Open the CAD & CSG Blockout Panel")
		return
	}

	// ========================================================================
	// VIEWPORT-FIRST MINIMALIST CAD CONTEXT BAR (Consolidated Single Strip!)
	// ========================================================================
	is_mesh_tab := (active_workspace_tab() == .Mesh_Editor)
	if is_mesh_tab {
		im.PushStyleColorImVec4(.Button, {0.80, 0.46, 0.16, 0.95})
	} else {
		im.PushStyleColorImVec4(.Button, {0.16, 0.50, 0.76, 0.95})
	}
	mode_lbl := fmt.ctprintf("%s Mesh" if is_mesh_tab else "%s CSG", icons.ICON_MD_HEXAGON if is_mesh_tab else icons.ICON_MD_VIEW_IN_AR)
	if im.SmallButton(mode_lbl) {
		set_workspace_tab(.CSG_Editor if is_mesh_tab else .Mesh_Editor)
	}
	im.PopStyleColor(1)
	widgets.ui_tool_script_loc(#location(set_workspace_tab), "Switch CSG Editor vs Mesh Editor Mode")
	widgets.tooltip("Toggle between CSG Blockout Mode and Polygon Mesh Modeling Mode.")
	im.SameLine(0, 4)

	im.TextColored({0.5, 0.5, 0.5, 0.55}, "|")
	im.SameLine(0, 4)

	// Consolidated CAD Sub-Tool Strip (`1..7`) — ONE authoritative location, zero duplicate bars!
	sub_btns := [7]struct {
		tool: CAD_Sub_Tool,
		lbl:  cstring,
		tip:  cstring,
	}{
		{.Spline_Poly_Sketch, icons.ICON_MD_POLYLINE + " 1##cad_st1", "1: 2D Polyline / Catmull-Rom Spline Sketch -> Extrude (Right-click for settings)"},
		{.Box_Primitive,      icons.ICON_MD_VIEW_IN_AR + " 2##cad_st2", "2: 3D Box / Primitive Builder (Right-click for shape & boolean settings)"},
		{.Face_Push_Pull,     icons.ICON_MD_ARCHITECTURE + " 3##cad_st3", "3: Face Extrude / Intrude (Works on both CSG Brushes & Polygon Meshes! Right-click for settings)"},
		{.Geo_Mod_Blast,      icons.ICON_MD_ADS_CLICK + " 4##cad_st4", "4: Red Faction Geo-Mod Crater Blast (Right-click for radius/impulse & fill material)"},
		{.Clip_Brush_Plane,   icons.ICON_MD_DIFFERENCE + " 5##cad_st5", "5: 2-Point CSG Clip Plane Slicer (Tab cycles Split Both / Keep Back / Keep Front)"},
		{.Soft_Deform_Brush,  icons.ICON_MD_TUNE + " 6##cad_st6", "6: Soft Deformer Body Brush (Tab cycles Dent / Bulge / Ripple / Twist)"},
		{.Draw_Glass_Poly,    icons.ICON_MD_GRID_4X4 + " 7##cad_st7", "7: 3D Shatterable Polygon Glass Loop Tool"},
	}
	for sb_item in sub_btns {
		is_act := _ed.tool_active && _ed.sub_tool == sb_item.tool && (!is_mesh_tab || sb_item.tool == .Clip_Brush_Plane || sb_item.tool == .Soft_Deform_Brush)
		if is_act {
			im.PushStyleColorImVec4(.Button, {0.20, 0.62, 0.88, 0.98})
			im.PushStyleColorImVec4(.ButtonHovered, {0.28, 0.70, 0.95, 1.00})
		}
		switch sb_item.tool {
		case .Spline_Poly_Sketch: widgets.ui_tool_script_loc(tool_impl_location(.Spline_Poly_Sketch), "CAD 2D Spline Sketcher", draw_spline_tool_right_click_settings)
		case .Box_Primitive:      widgets.ui_tool_script_loc(tool_impl_location(.Box_Primitive), "CAD 3D Box / Primitive Builder", draw_box_tool_right_click_settings)
		case .Face_Push_Pull:     widgets.ui_tool_script_loc(tool_impl_location(.Face_Push_Pull), "CAD Face Extrude / Intrude", draw_extrude_tool_right_click_settings)
		case .Geo_Mod_Blast:      widgets.ui_tool_script_loc(tool_impl_location(.Geo_Mod_Blast), "Geo-Mod Crater Blast", draw_blast_tool_right_click_settings)
		case .Clip_Brush_Plane:   widgets.ui_tool_script_loc(tool_impl_location(.Clip_Brush_Plane), "2-Point Clip Plane Slicer", draw_clip_plane_tool_right_click_settings)
		case .Soft_Deform_Brush:  widgets.ui_tool_script_loc(tool_impl_location(.Soft_Deform_Brush), "Soft Deformer Body Brush")
		case .Draw_Glass_Poly:    widgets.ui_tool_script_loc(tool_impl_location(.Draw_Glass_Poly), "3D Glass Loop Tool")
		}
		if im.SmallButton(sb_item.lbl) {
			toggle_cad_tool(sb_item.tool)
		}
		if is_act do im.PopStyleColor(2)
		widgets.tooltip(sb_item.tip)
		im.SameLine(0, 2)
	}

	im.SameLine(0, 4)
	im.TextColored({0.5, 0.5, 0.5, 0.55}, "|")
	im.SameLine(0, 4)

	// Boolean Operation Toggle (+Add Solid vs -Cut Hole)
	is_add := (_ed.brush_op == .Add)
	if is_add {
		im.PushStyleColorImVec4(.Button, {0.16, 0.62, 0.34, 0.92})
		im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.74, 0.42, 1.00})
	} else {
		im.PushStyleColorImVec4(.Button, {0.82, 0.22, 0.20, 0.95})
		im.PushStyleColorImVec4(.ButtonHovered, {0.92, 0.30, 0.28, 1.00})
	}
	op_lbl: cstring = "+Add (X)" if is_add else "-Cut (X)"
	if im.SmallButton(op_lbl) {
		_ed.brush_op = .Subtract if is_add else .Add
		if _ed.draft_stage == .Extruding_Height {
			_ed.extrude_height = -abs(_ed.extrude_height) if _ed.brush_op == .Subtract else abs(_ed.extrude_height)
		}
	}
	im.PopStyleColor(2)
	widgets.ui_tool_script_loc(#location(cad_csg.convex_list_subtract), "CSG Half-Space Boolean Union / Subtract", draw_box_tool_right_click_settings)
	widgets.tooltip("Toggle CSG Boolean Operation (Shortcut: X): +Add Solid vs -Cut Hole.")
	im.SameLine(0, 4)

	// Context-specific compact controls for active sub-tool
	if _ed.tool_active && _ed.sub_tool == .Spline_Poly_Sketch {
		if _ed.sketch_next_smooth {
			im.PushStyleColorImVec4(.Button, {0.82, 0.58, 0.14, 0.95})
		} else {
			im.PushStyleColorImVec4(.Button, {0.24, 0.46, 0.68, 0.92})
		}
		if im.SmallButton("Smooth (C)" if _ed.sketch_next_smooth else "Corner (C)") {
			_ed.sketch_next_smooth = !_ed.sketch_next_smooth
		}
		im.PopStyleColor(1)
		widgets.ui_tool_script_loc(#location(cad_csg.csg_eval_profile_2d), "Catmull-Rom Spline vs Sharp CAD Corner", draw_spline_tool_right_click_settings)
		widgets.tooltip("Toggle Sharp CAD Corner vs Smooth Catmull-Rom Curve (C, or Right-click a vertex).")
		im.SameLine(0, 3)

		ws_pushed := _ed.spline_wall_strip
		if ws_pushed {
			im.PushStyleColorImVec4(.Button, {0.18, 0.64, 0.52, 0.96})
		}
		if im.SmallButton("Wall Strip") {
			_ed.spline_wall_strip = !_ed.spline_wall_strip
		}
		if ws_pushed do im.PopStyleColor(1)
		widgets.tooltip("Wall-Strip Mode: Draw an open polyline (2+ points) and press Enter to thicken & extrude it into a corridor wall!")
		im.SameLine(0, 3)

		if _ed.spline_wall_strip {
			im.SetNextItemWidth(66)
			im.DragFloat("##wall_t_top", &_ed.spline_wall_thickness, 0.02, 0.08, 4.0, "T:%.2fm")
			widgets.tooltip("Corridor wall thickness in meters when Wall-Strip Mode is active.")
			im.SameLine(0, 3)
		}

		fh_pushed := _ed.sketch_freehand
		if fh_pushed do im.PushStyleColorImVec4(.Button, {0.65, 0.32, 0.78, 0.95})
		if im.SmallButton("Freehand") {
			_ed.sketch_freehand = !_ed.sketch_freehand
		}
		if fh_pushed do im.PopStyleColor(1)
		widgets.tooltip("Freehand continuous curve stroke.")
		im.SameLine(0, 3)

		min_extrude_pts := 2 if _ed.spline_wall_strip else 3
		if len(_ed.sketch_points) >= min_extrude_pts && _ed.draft_stage != .Extruding_Height {
			im.PushStyleColorImVec4(.Button, {0.20, 0.68, 0.38, 0.95})
			if im.SmallButton("Extrude (Enter)") {
				_begin_spline_extrude_stage(handles.frame().ray)
			}
			im.PopStyleColor(1)
			widgets.tooltip("Transition to 3D height extrusion (Enter / Space).")
			im.SameLine(0, 3)
		}
		if len(_ed.sketch_points) > 0 {
			if im.SmallButton("Clear") {
				clear(&_ed.sketch_points)
				_ed.draft_stage = .Idle
				_ed.hud_angle_field_active = false
				_ed.hud_locked_len_valid   = false
			}
			widgets.tooltip("Discard current sketch points (Backspace removes only the last vertex!).")
			im.SameLine(0, 3)
		}
	} else if _ed.tool_active && _ed.sub_tool == .Box_Primitive {
		prim_names := [6]cstring{"Box", "Wedge", "Hex (6)", "Oct (8)", "Cyl (12)", "Bevel Box"}
		p_idx := clamp(int(_ed.primitive), 0, 5)
		im.SetNextItemWidth(90)
		if im.BeginCombo("##cad_prim", prim_names[p_idx]) {
			for i in 0 ..< 6 {
				if im.Selectable(prim_names[i], p_idx == i) {
					_ed.primitive = cad_csg.Brush_Primitive(i)
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Primitive shape drawn by Tool 2 (Hold Shift while dragging footprint for 1:1 Square!).")
		im.SameLine(0, 4)
	} else if _ed.tool_active && _ed.sub_tool == .Geo_Mod_Blast {
		im.SetNextItemWidth(92)
		im.SliderFloat("##blast_rad_top", &_ed.blast_radius, 0.12, 8.0, "R:%.2fm")
		widgets.tooltip("Geo-Mod Crater Radius ('[' and ']')")
		im.SameLine(0, 3)
		im.SetNextItemWidth(82)
		im.SliderFloat("##blast_imp_top", &_ed.blast_impulse, 1.0, 40.0, "Imp:%.0f")
		widgets.tooltip("Debris Impulse")
		im.SameLine(0, 3)
		if im.ColorEdit4("Fill##blast_cut_alb_top", &_ed.tool_cut_albedo, {.NoInputs}) {
			_ed.tool_cut_albedo_enabled = true
			sync_cut_fill_material_and_active_volume(&_ed.tool_cut_material_guid)
		}
		widgets.tooltip("Crater Fill Albedo")
		im.SameLine(0, 3)
		im.PushStyleColorImVec4(.Button, {0.72, 0.28, 0.20, 0.95})
		if im.SmallButton("Reset") {
			if vol_r, _ := _resolve_active_volume(false); vol_r != nil {
				cad_csg.csg_volume_reset_craters(vol_r)
			}
			if sel_h != {} do reset_ghoul_wounds_if_any(sel_h)
		}
		im.PopStyleColor(1)
		widgets.tooltip("Reset blasted craters to pristine geometry.")
		im.SameLine(0, 4)
	} else if _ed.tool_active && _ed.sub_tool == .Clip_Brush_Plane {
		clip_names := [3]cstring{"Split Both", "Keep Back", "Keep Front"}
		cm_idx := clamp(int(_ed.clip_mode), 0, 2)
		im.SetNextItemWidth(96)
		if im.BeginCombo("##clip_mode_top", clip_names[cm_idx]) {
			for i in 0 ..< 3 {
				if im.Selectable(clip_names[i], cm_idx == i) {
					_ed.clip_mode = cad_csg.CSG_Clip_Mode(i)
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Clip Plane Mode (Tab cycles)")
		im.SameLine(0, 3)
		im.SetNextItemWidth(76)
		im.SliderFloat("##clip_gap_top", &_ed.clip_split_gap, 0.0, 0.50, "Gap:%.2f")
		widgets.tooltip("Split seam gap in meters")
		im.SameLine(0, 4)
	}

	// True Anchor-Origin Polar Protractor Selector (`Off`, `15°`, `30°`, `45°`, `90°`) + Origin Toggle (`Last` vs `P0`)
	polar_lbl := fmt.ctprintf("Polar: %.0f°", _ed.polar_step_deg) if _ed.axis_snap_enabled else cstring("Polar: Off")
	im.SetNextItemWidth(86)
	if im.BeginCombo("##cad_polar_step", polar_lbl) {
		if im.Selectable("Off (Shift = 15°)", !_ed.axis_snap_enabled) {
			_ed.axis_snap_enabled = false
		}
		polar_steps := [4]f32{15.0, 30.0, 45.0, 90.0}
		for ps in polar_steps {
			is_p := _ed.axis_snap_enabled && abs(_ed.polar_step_deg - ps) < 0.1
			if im.Selectable(fmt.ctprintf("%.0f° Protractor", ps), is_p) {
				_ed.axis_snap_enabled = true
				_ed.polar_step_deg    = ps
			}
		}
		im.EndCombo()
	}
	widgets.ui_tool_script_loc(#location(compute_cad_polar_snap), "True Anchor-Origin Polar Protractor Math")
	widgets.tooltip("True Anchor-Origin Polar Angle Snapping: snaps strictly from your placed vertex (NEVER world {0,0}!).\n• Shift: Momentary 15° snap (or 1:1 Square in Box tool)\n• Alt: Momentary Free bypass")
	im.SameLine(0, 3)

	if _ed.axis_snap_enabled && _ed.sub_tool == .Spline_Poly_Sketch {
		orig_pushed := _ed.polar_origin_first_pt
		if orig_pushed do im.PushStyleColorImVec4(.Button, {0.24, 0.52, 0.72, 0.92})
		if im.SmallButton("Orig:P0" if _ed.polar_origin_first_pt else "Orig:Last") {
			_ed.polar_origin_first_pt = !_ed.polar_origin_first_pt
		}
		if orig_pushed do im.PopStyleColor(1)
		widgets.tooltip("Polar Protractor Origin: snap angles relative to the Last Placed Vertex (default) vs. First Sketch Point P0!")
		im.SameLine(0, 3)
	}

	// Magnetic OSNAP Toggle (`□ Vertex`, `△ Midpoint`, `◎ Face Center`)
	os_pushed := _ed.osnap_enabled
	if os_pushed do im.PushStyleColorImVec4(.Button, {0.18, 0.58, 0.44, 0.92})
	if im.SmallButton("OSNAP") {
		_ed.osnap_enabled = !_ed.osnap_enabled
	}
	if os_pushed do im.PopStyleColor(1)
	widgets.ui_tool_script_loc(#location(_find_osnap_world_point), "Magnetic Object Snap (Vertex / Midpoint / Face Center)")
	widgets.tooltip("Magnetic OSNAP onto existing CSG corners ([Vertex]), edge midpoints ([Midpoint]), and face centers ([Center]). Hold Alt to bypass.")
	im.SameLine(0, 3)

	// Metric Grid Snap Step
	snap_presets := [5]f32{0.1, 0.25, 0.5, 1.0, 2.0}
	im.SetNextItemWidth(78)
	if im.BeginCombo("##cad_snap", fmt.ctprintf("%.2gm", _ed.snap_step)) {
		for sp in snap_presets {
			if im.Selectable(fmt.ctprintf("%.2g m", sp), abs(_ed.snap_step - sp) < 0.001) {
				_ed.snap_step = sp
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Metric grid & radial length snap step (in meters).")
	im.SameLine(0, 3)

	// Auto-Surface WorkPlane vs Locked Plane (`F` toggles Lock, `Shift+F` or Right-Click resets to Ground `Y=0`)
	pl_pushed := _ed.plane_locked
	if pl_pushed do im.PushStyleColorImVec4(.Button, {0.78, 0.54, 0.14, 0.95})
	pl_lbl := fmt.ctprintf("%s Plane (F)", icons.ICON_MD_LOCK if _ed.plane_locked else icons.ICON_MD_LOCK_OPEN)
	if im.SmallButton(pl_lbl) {
		_ed.plane_locked = !_ed.plane_locked
	}
	if pl_pushed do im.PopStyleColor(1)
	if im.IsItemClicked(.Right) {
		_ed.plane_locked = false
		_reset_workplane_to_ground()
	}
	widgets.tooltip("WorkPlane Alignment:\n• Unlocked (Auto): Automatically aligns to any hovered CSG wall/ramp/floor before Point 1 is clicked, then locks during the sketch!\n• Locked (F): Keeps current WorkPlane fixed.\n• Right-Click or Shift+F: Reset to Ground Y=0.")
	im.SameLine(0, 3)

	// 6-Face Grips quick toggle when in Q/W/E/R/T mode inside CAD Blockout
	if !_ed.tool_active {
		fg2 := _ed.show_brush_face_grips
		if fg2 do im.PushStyleColorImVec4(.Button, {0.16, 0.58, 0.52, 0.95})
		if im.SmallButton("6-Face") {
			_ed.show_brush_face_grips = !_ed.show_brush_face_grips
		}
		if fg2 do im.PopStyleColor(1)
		widgets.tooltip("Toggle Direct 6-Face Live Parametric Resize Grips on the selected CSG brush.")
		im.SameLine(0, 3)
	}

	if can_revert_or_rewrap_csg_mesh(sel_h) {
		if widgets.small_button_colored("Undo->Mesh", {0.82, 0.36, 0.16, 0.95}) {
			_ = revert_csg_to_original_mesh(sel_h)
			return
		}
		widgets.tooltip("Restore original MeshFilter + MeshRenderer.")
		im.SameLine(0, 3)
	}

	if im.SmallButton(icons.ICON_MD_TUNE + "##open_csg_panel") {
		wnd.open("cad_csg_panel")
	}
	widgets.ui_tool_script_loc(#location(_draw_cad_csg_panel_contents), "CAD & CSG Blockout Panel")
	widgets.tooltip("Open Full CAD & CSG Inspector Window")
}

// Crisp 28px Bottom-Center CAD Command & Telemetry Pill (Click-through HUD rendered on Scene3D DrawList).
draw_cad_bottom_telemetry_hud :: proc(img_min, img_max: im.Vec2) {
	_ensure_init()
	vp_w := img_max.x - img_min.x
	vp_h := img_max.y - img_min.y
	if vp_w < 340.0 || vp_h < 180.0 do return

	is_mesh := (active_workspace_tab() == .Mesh_Editor)
	tool_str: string
	if is_mesh && !(_ed.tool_active && (_ed.sub_tool == .Clip_Brush_Plane || _ed.sub_tool == .Soft_Deform_Brush)) {
		tool_str = "MESH EDITOR"
	} else if !_ed.tool_active {
		tool_str = "CSG SELECT · 6-FACE GRIPS"
	} else {
		op_s := "+ADD" if _ed.brush_op == .Add else "-CUT"
		switch _ed.sub_tool {
		case .Spline_Poly_Sketch: tool_str = fmt.tprintf("1:SPLINE (%s)%s", op_s, " [WALL]" if _ed.spline_wall_strip else "")
		case .Box_Primitive:      tool_str = fmt.tprintf("2:BOX/%v (%s)", _ed.primitive, op_s)
		case .Face_Push_Pull:     tool_str = "3:FACE EXTRUDE/INTRUDE"
		case .Geo_Mod_Blast:      tool_str = fmt.tprintf("4:BLAST R=%.2fm", _ed.blast_radius)
		case .Clip_Brush_Plane:   tool_str = "5:2-PT CLIP PLANE"
		case .Soft_Deform_Brush:  tool_str = "6:SOFT DEFORM"
		case .Draw_Glass_Poly:    tool_str = "7:3D GLASS LOOP"
		}
	}

	readout: string
	is_typing := (_ed.num_len > 0 || _ed.hud_locked_len_valid)
	if is_typing {
		typed := string(_ed.num_buf[:_ed.num_len])
		if _ed.sub_tool == .Spline_Poly_Sketch && _ed.draft_stage != .Extruding_Height && len(_ed.sketch_points) > 0 {
			if _ed.hud_angle_field_active {
				l_disp := _ed.hud_locked_len if _ed.hud_locked_len_valid else linalg.length(_ed.hover_uv - _ed.sketch_points[len(_ed.sketch_points) - 1].uv)
				readout = fmt.tprintf("L: %.2fm  |  [Angle]: %s_ deg  (Tab=Len, Enter=Place)", l_disp, typed)
			} else {
				readout = fmt.tprintf("[Length]: %s_ m  (Tab=Angle, Enter=Place)", typed)
			}
		} else if _ed.draft_stage == .Extruding_Height {
			readout = fmt.tprintf("[Height]: %s_ m  (Enter=Commit)", typed)
		} else {
			readout = fmt.tprintf("[Input]: %s_  (Tab=WxD, Enter=Commit)", typed)
		}
	} else if _ed.tool_active && _ed.sub_tool == .Spline_Poly_Sketch && len(_ed.sketch_points) > 0 {
		if _ed.draft_stage == .Extruding_Height {
			readout = fmt.tprintf("Pts: %d  |  H: %+.2f m", len(_ed.sketch_points), _ed.extrude_height)
		} else if _ed.hover_valid {
			last_uv := _ed.sketch_points[len(_ed.sketch_points) - 1].uv
			d := _ed.hover_uv - last_uv
			seg_l := linalg.length(d)
			seg_a := math.atan2(d.y, d.x) * (180.0 / math.PI)
			readout = fmt.tprintf("Pts: %d  |  L: %.2f m   Ang: %+.1f°", len(_ed.sketch_points), seg_l, seg_a)
		} else {
			readout = fmt.tprintf("Pts: %d", len(_ed.sketch_points))
		}
	} else if _ed.tool_active && _ed.sub_tool == .Box_Primitive && _ed.draft_stage != .Idle {
		w_u := max(abs(_ed.curr_uv.x - _ed.start_uv.x), _ed.snap_step)
		d_v := max(abs(_ed.curr_uv.y - _ed.start_uv.y), _ed.snap_step)
		h_n := _ed.extrude_height if _ed.draft_stage == .Extruding_Height else 0.0
		readout = fmt.tprintf("W: %.2f × D: %.2f × H: %+.2f m", w_u, d_v, h_n)
	} else if _ed.hover_valid && _ed.tool_active {
		readout = fmt.tprintf("U: %+.2f  V: %+.2f m", _ed.hover_uv.x, _ed.hover_uv.y)
	} else {
		readout = fmt.tprintf("Grid %.2gm", _ed.snap_step)
	}

	osnap_tag := ""
	if _ed.osnap_active {
		switch _ed.osnap_kind {
		case .None:        osnap_tag = ""
		case .Vertex:      osnap_tag = " | OSNAP:Vertex"
		case .Midpoint:    osnap_tag = " | OSNAP:Midpoint"
		case .Face_Center: osnap_tag = " | OSNAP:Center"
		}
	}
	polar_tag := fmt.tprintf("Polar %.0f°", _ed.polar_step_deg) if _ed.axis_snap_enabled else "Polar Off"
	plane_tag := "Locked" if _ed.plane_locked else ("Surface" if _ed.plane.is_custom else "Ground")
	full_txt  := fmt.ctprintf("%s   ·   %s   ·   %s | Plane:%s%s   ·   Shift:15°/Sq  Alt:Free  Tab:L/Ang  Bksp:Undo", tool_str, readout, polar_tag, plane_tag, osnap_tag)

	ts := im.CalcTextSize(full_txt)
	pad_x :: f32(14.0)
	pad_y :: f32(5.0)
	pill_w := min(ts.x + pad_x * 2.0, vp_w - 24.0)
	pill_h := ts.y + pad_y * 2.0
	px := img_min.x + (vp_w - pill_w) * 0.5
	py := img_max.y - pill_h - 8.0

	dl := im.GetWindowDrawList()
	bg_col     := im.ColorConvertFloat4ToU32({0.07, 0.09, 0.12, 0.88})
	border_col := im.ColorConvertFloat4ToU32({0.88, 0.54, 0.96, 0.90} if is_typing else {0.26, 0.52, 0.76, 0.72})
	txt_col    := im.ColorConvertFloat4ToU32({1.0, 0.86, 1.0, 1.0} if is_typing else {0.88, 0.94, 1.0, 0.98})
	im.DrawList_AddRectFilled(dl, {px, py}, {px + pill_w, py + pill_h}, bg_col, 6.0)
	im.DrawList_AddRect(dl, {px, py}, {px + pill_w, py + pill_h}, border_col, 6.0, 1.0)
	im.DrawList_AddText(dl, {px + pad_x, py + pad_y}, txt_col, full_txt)
}

// ============================================================================
// SCENE3D PICKING, COMPONENT GIZMOS & MODAL CAD BLOCKOUT TOOLS
// ============================================================================

@(private = "package")
_pick_csg_volume_click :: proc(view: engine.Render_View, ray: engine.Ray) -> (tH: engine.Transform_Handle, t: f32, ok: bool) {
	_ = view
	_, _, hit_t, hit_vol, hit_b_idx, hit_ok := cad_csg.csg_raycast_world(ray)
	if !hit_ok || hit_vol == nil do return {}, 0, false
	if hit_b_idx >= 0 && hit_b_idx != _ed.selected_brush_idx {
		_ed.selected_brush_idx = hit_b_idx
		_ed.brush_gizmo_dragging = false
	}
	return engine.Transform_Handle(hit_vol.owner), hit_t, true
}

@(private = "package")
_pick_csg_volume_band :: proc(view: engine.Render_View, rmin, rmax: [2]f32, out: ^[dynamic]engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return
	it := engine.pool_iterator(cad_csg.csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || !engine.transform_active_in_hierarchy(vol.owner) do continue
		lo, hi, aabb_ok := cad_csg.csg_volume_local_aabb(vol)
		if !aabb_ok do continue
		tw := engine.transform_world(engine.Transform_Handle(vol.owner))
		model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)

		first := true
		pmin, pmax: [2]f32
		for k in 0 ..< 8 {
			local := [4]f32{
				k & 1 == 0 ? lo.x : hi.x,
				k & 2 == 0 ? lo.y : hi.y,
				k & 4 == 0 ? lo.z : hi.z,
				1.0,
			}
			wp := (model * local).xyz
			if px, pok := gizmos.helper_project_in(view, wp); pok {
				if first {
					pmin, pmax = px, px
					first = false
				} else {
					pmin = {min(pmin.x, px.x), min(pmin.y, px.y)}
					pmax = {max(pmax.x, px.x), max(pmax.y, px.y)}
				}
			}
		}
		if !first && pmin.x <= rmax.x && pmax.x >= rmin.x && pmin.y <= rmax.y && pmax.y >= rmin.y {
			append(out, engine.Transform_Handle(vol.owner))
		}
	}
}

// Draws the 8m x 8m x 8m Voxel-like `CSG_Chunk` spatial cells + per-chunk telemetry in Scene3D!
@(private = "package")
_draw_csg_chunk_grid :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil || !_ed.show_chunk_grid || len(vol.chunks) == 0 do return
	tw := engine.transform_world(engine.Transform_Handle(vol.owner))
	cs := max(vol.chunk_size, 2.0)

	gizmos.in_world_space()
	for coord, ch in vol.chunks {
		if ch == nil || len(ch.indices) == 0 do continue
		cell_min := [3]f32{f32(coord.x) * cs, f32(coord.y) * cs, f32(coord.z) * cs}
		cell_center := tw.position + cell_min + [3]f32{cs * 0.5, cs * 0.5, cs * 0.5}

		// 1. Subtle 8m^3 Voxel-like spatial grid cell boundary
		gizmos.with_depth_test(true)
		gizmos.with_color({0.20, 0.85, 0.95, 0.26})
		gizmos.wire_box(cell_center, {cs, cs, cs} * tw.scale)

		// 2. Tight active chunk geometry AABB + telemetry pill
		geom_center := tw.position + (ch.aabb_min + ch.aabb_max) * 0.5
		geom_size   := (ch.aabb_max - ch.aabb_min) * tw.scale
		gizmos.with_depth_test(false)
		gizmos.with_color({0.30, 0.95, 0.65, 0.65})
		gizmos.wire_box(geom_center, geom_size)

		hulls_n := len(ch.destructible_hulls) + len(ch.indestructible_hulls)
		tris_n  := len(ch.indices) / 3
		lbl := fmt.tprintf("Chunk (%d,%d,%d) | %d hulls | %d tris", coord.x, coord.y, coord.z, hulls_n, tris_n)
		_draw_3d_tracked_pill(tw.position + {geom_center.x - tw.position.x, ch.aabb_max.y + 0.25, geom_center.z - tw.position.z}, lbl, {0.40, 0.95, 1.0, 0.95})
	}
}

// Draws and handles the 3D W / E / R Transform Gizmo directly on the selected `CSG_Brush`
// inside a multi-brush `CSGVolume` so individual CSG brushes can be moved, rotated, or scaled!
@(private = "package")
_draw_and_handle_selected_brush_gizmo :: proc(vol: ^cad_csg.CSGVolume, tool: handles.Tool) {
	if vol == nil || _ed.selected_brush_idx < 0 || _ed.selected_brush_idx >= len(vol.brushes) do return
	f := handles.frame()
	if !f.valid do return

	// Allow clicking a different brush inside the volume when not dragging the gizmo handle
	if f.input.clicked && f.input.hovered && !handles.consumes_mouse() {
		if _, _, _, hit_vol, hit_b_idx, hit_ok := cad_csg.csg_raycast_world(f.ray); hit_ok && hit_vol == vol && hit_b_idx >= 0 {
			if hit_b_idx != _ed.selected_brush_idx {
				_ed.selected_brush_idx = hit_b_idx
				_ed.brush_gizmo_dragging = false
			}
		}
	}

	b := &vol.brushes[_ed.selected_brush_idx]
	tw := engine.transform_world(engine.Transform_Handle(vol.owner))
	origin := tw.position + b.center

	v := f.view
	cam_fwd := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
	cam_depth := linalg.dot(origin - v.cam_pos, cam_fwd)
	if cam_depth <= 0.01 && !_ed.brush_gizmo_dragging do return

	dist := max(cam_depth, 0.25) * (2.41421356 / max(abs(v.proj[1, 1]), 0.1))
	if abs(v.proj[3, 3]) > 0.5 && abs(v.proj[1, 1]) > 1e-6 {
		dist = (1.0 / abs(v.proj[1, 1])) * 2.41421356
	}
	size := dist * 0.15
	if size <= 0 do return

	gizmos.in_world_space()
	_BRUSH_GIZMO_ID :: u64(0x4353_475f_4252_5348)
	d: handles.Drag

	#partial switch tool {
	case .Translate:
		pos := origin
		d = handles.position_handle(_BRUSH_GIZMO_ID, &pos, quaternion128(1), size, handles.PRIO_TOOL)
		if d.started {
			_ed.brush_gizmo_dragging   = true
			_ed.brush_gizmo_start_pos  = origin
			_ed.brush_gizmo_start_cent = b.center
		}
		if _ed.brush_gizmo_dragging && (d.dragging || d.released) {
			old_c := b.center
			delta := pos - _ed.brush_gizmo_start_pos
			b.center = _ed.brush_gizmo_start_cent + delta
			half_r := max(b.size.x, max(b.size.y, b.size.z)) * 0.75 + 0.5
			dirty_min := linalg.min(old_c, b.center) - [3]f32{half_r, half_r, half_r}
			dirty_max := linalg.max(old_c, b.center) + [3]f32{half_r, half_r, half_r}
			if d.released {
				cad_csg.csg_volume_rebuild(vol)
			} else {
				_ = cad_csg.csg_volume_rebuild_dirty_aabb(vol, dirty_min, dirty_max)
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

	case .Rotate:
		if !_ed.brush_gizmo_dragging {
			_ed.brush_gizmo_rot = linalg.quaternion_angle_axis_f32(math.to_radians(b.yaw_deg), [3]f32{0, 1, 0})
		}
		d = handles.rotation_handle(_BRUSH_GIZMO_ID, &_ed.brush_gizmo_rot, origin, size, false, handles.PRIO_TOOL)
		if d.started {
			_ed.brush_gizmo_dragging  = true
			_ed.brush_gizmo_rot_start = _ed.brush_gizmo_rot
			_ed.brush_gizmo_start_yaw = b.yaw_deg
		}
		if _ed.brush_gizmo_dragging && (d.dragging || d.released) {
			turn := _ed.brush_gizmo_rot * conj(_ed.brush_gizmo_rot_start)
			fwd := linalg.quaternion128_mul_vector3(turn, [3]f32{0, 0, 1})
			yaw_delta := math.to_degrees(math.atan2(fwd.x, fwd.z))
			b.yaw_deg = _ed.brush_gizmo_start_yaw + yaw_delta
			half_r := max(b.size.x, max(b.size.y, b.size.z)) * 0.75 + 0.5
			if d.released {
				cad_csg.csg_volume_rebuild(vol)
			} else {
				_ = cad_csg.csg_volume_rebuild_dirty_aabb(vol, b.center - [3]f32{half_r, half_r, half_r}, b.center + [3]f32{half_r, half_r, half_r})
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

	case .Scale:
		if !_ed.brush_gizmo_dragging {
			_ed.brush_gizmo_scale = {1, 1, 1}
		}
		rot := linalg.quaternion_angle_axis_f32(math.to_radians(b.yaw_deg), [3]f32{0, 1, 0})
		d = handles.scale_handle(_BRUSH_GIZMO_ID, &_ed.brush_gizmo_scale, origin, rot, size, handles.PRIO_TOOL)
		if d.started {
			_ed.brush_gizmo_dragging   = true
			_ed.brush_gizmo_start_size = b.size
		}
		if _ed.brush_gizmo_dragging && (d.dragging || d.released) {
			old_sz := b.size
			b.size = {
				max(_ed.brush_gizmo_start_size.x * _ed.brush_gizmo_scale.x, 0.1),
				max(_ed.brush_gizmo_start_size.y * _ed.brush_gizmo_scale.y, 0.1),
				max(_ed.brush_gizmo_start_size.z * _ed.brush_gizmo_scale.z, 0.1),
			}
			max_sz := linalg.max(old_sz, b.size)
			half_r := max(max_sz.x, max(max_sz.y, max_sz.z)) * 0.75 + 0.5
			if d.released {
				cad_csg.csg_volume_rebuild(vol)
			} else {
				_ = cad_csg.csg_volume_rebuild_dirty_aabb(vol, b.center - [3]f32{half_r, half_r, half_r}, b.center + [3]f32{half_r, half_r, half_r})
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}

	if d.started {
		csg_history_ensure_baseline(vol)
	}
	if d.released || (_ed.brush_gizmo_dragging && !d.dragging) {
		_ed.brush_gizmo_dragging = false
		cad_csg.csg_volume_sync_colliders_only(vol)
		csg_history_commit(vol)
	}
}

// Direct 6-Face Live Parametric Resize Grips (`handles.box_bounds`) on the selected CSG brush (`+Add` or `-Cut` hole!):
// Dragging any of the 6 face dots (`±X, ±Y, ±Z`) pushes/pulls ONLY that face while keeping the opposite face anchored!
// Hold `Alt` for symmetric center resize, `Shift` for proportional resize.
@(private = "package")
_draw_and_handle_selected_brush_6face_grips :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil || !vol.enabled || vol.is_faker_mesh || vol.is_ghoul_bone_csg || !_ed.show_brush_face_grips do return
	if len(vol.brushes) == 0 do return
	f := handles.frame()
	if !f.valid do return

	if (_ed.selected_brush_idx < 0 || _ed.selected_brush_idx >= len(vol.brushes)) && len(vol.brushes) == 1 {
		_ed.selected_brush_idx = 0
	}
	if _ed.selected_brush_idx < 0 || _ed.selected_brush_idx >= len(vol.brushes) do return

	// Allow clicking another brush inside a multi-brush CSGVolume to switch which brush the 6-face grips edit
	if len(vol.brushes) > 1 && f.input.clicked && f.input.hovered && !handles.consumes_mouse() {
		if _, _, _, hit_v, hit_bi, hit_ok := cad_csg.csg_raycast_world(f.ray); hit_ok && hit_v == vol && hit_bi >= 0 && hit_bi < len(vol.brushes) {
			_ed.selected_brush_idx = hit_bi
			_ed.face_grip_dragging = false
		}
	}

	b := &vol.brushes[_ed.selected_brush_idx]
	owner_h := engine.Transform_Handle(vol.owner)
	tw := engine.transform_world(owner_h)
	grip_col := [4]f32{0.22, 0.96, 0.58, 0.96} if b.op == .Add else [4]f32{1.0, 0.36, 0.28, 0.96}
	_BRUSH_6FACE_ID :: u64(0x4353_475f_3646_4345)

	if b.primitive == .Profile_2D {
		// Top / Bottom cap height grip along `b.plane_normal` when aligned to a principal local axis
		ax_n := -1
		if abs(b.plane_normal.x) > 0.92 do ax_n = 0
		if abs(b.plane_normal.y) > 0.92 do ax_n = 1
		if abs(b.plane_normal.z) > 0.92 do ax_n = 2
		if ax_n < 0 do return

		h_abs := max(abs(b.extrude_height), 0.10)
		h_sgn: f32 = 1.0 if b.extrude_height >= 0 else -1.0
		c_cap := b.center + b.plane_normal * (b.extrude_height * 0.5)
		sz_cap := [3]f32{0.5, 0.5, 0.5}
		sz_cap[ax_n] = h_abs
		axes_set: handles.Axes = {.X} if ax_n == 0 else ({.Y} if ax_n == 1 else {.Z})

		gizmos.in_local_space(owner_h)
		gizmos.with_depth_test(false)
		d := handles.box_bounds(_BRUSH_6FACE_ID, &c_cap, &sz_cap, axes_set, grip_col, fixed_center = false)
		if d.started {
			csg_history_ensure_baseline(vol)
			_ed.face_grip_dragging   = true
			_ed.face_grip_start_cent = b.center
			_ed.face_grip_start_h    = b.extrude_height
		}
		if _ed.face_grip_dragging && (d.dragging || d.released) {
			raw_dh := sz_cap[ax_n] - abs(_ed.face_grip_start_h)
			snap_dh := raw_dh if im.GetIO().KeyAlt else _snap_scalar(raw_dh, _ed.snap_step)
			new_abs := max(abs(_ed.face_grip_start_h) + snap_dh, 0.10)
			b.extrude_height = new_abs * h_sgn
			if d.released {
				cad_csg.csg_volume_rebuild(vol)
				cad_csg.csg_volume_sync_colliders_only(vol)
				csg_history_commit(vol)
				_ed.face_grip_dragging = false
			} else {
				cad_csg.csg_volume_rebuild(vol)
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		gizmos.in_world_space()
		return
	}

	if abs(b.yaw_deg) > 0.05 do return

	c_edit  := b.center
	sz_edit := b.size

	gizmos.in_local_space(owner_h)
	gizmos.with_depth_test(false)
	gizmos.with_color({grip_col.r, grip_col.g, grip_col.b, 0.55})
	gizmos.wire_box(b.center, b.size)

	d := handles.box_bounds(_BRUSH_6FACE_ID, &c_edit, &sz_edit, handles.ALL_AXES, grip_col, fixed_center = false)
	if d.started {
		csg_history_ensure_baseline(vol)
		_ed.face_grip_dragging   = true
		_ed.face_grip_start_cent = b.center
		_ed.face_grip_start_size = b.size
	}
	if _ed.face_grip_dragging && (d.dragging || d.released) {
		old_c  := b.center
		old_sz := b.size
		new_c  := _ed.face_grip_start_cent
		new_sz := _ed.face_grip_start_size
		orig_mid := _ed.face_grip_start_cent + [3]f32{0, 0, 0}

		for ax in 0 ..< 3 {
			raw_ds := sz_edit[ax] - _ed.face_grip_start_size[ax]
			if abs(raw_ds) > 1e-4 {
				snap_ds := raw_ds if im.GetIO().KeyAlt else _snap_scalar(raw_ds, _ed.snap_step)
				clamped_s := max(_ed.face_grip_start_size[ax] + snap_ds, 0.10)
				actual_ds := clamped_s - _ed.face_grip_start_size[ax]
				new_sz[ax] = clamped_s
				dc := c_edit[ax] - orig_mid[ax]
				if abs(dc) > 1e-4 {
					side: f32 = 1.0 if dc >= 0 else -1.0
					new_c[ax] = orig_mid[ax] + side * (actual_ds * 0.5)
				}
			}
		}
		b.center = new_c
		b.size   = new_sz

		max_sz := linalg.max(old_sz, b.size)
		half_r := max(max_sz.x, max(max_sz.y, max_sz.z)) * 0.75 + 0.6
		dirty_lo := linalg.min(old_c, b.center) - [3]f32{half_r, half_r, half_r}
		dirty_hi := linalg.max(old_c, b.center) + [3]f32{half_r, half_r, half_r}
		if d.released {
			_ed.face_grip_dragging = false
			cad_csg.csg_volume_rebuild(vol)
			cad_csg.csg_volume_sync_colliders_only(vol)
			csg_history_commit(vol)
		} else {
			_ = cad_csg.csg_volume_rebuild_dirty_aabb(vol, dirty_lo, dirty_hi)
		}
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	} else if _ed.face_grip_dragging && !d.dragging {
		_ed.face_grip_dragging = false
		cad_csg.csg_volume_rebuild(vol)
		cad_csg.csg_volume_sync_colliders_only(vol)
		csg_history_commit(vol)
	}

	gizmos.in_world_space()
	if _ed.face_grip_dragging || control_rig_ed.scene_viewport_mode == .CAD_Blockout {
		rot_q := engine.quat_to_native(tw.rotation)
		bc_w := tw.position + linalg.quaternion128_mul_vector3(rot_q, b.center * tw.scale)
		top_off := linalg.quaternion128_mul_vector3(rot_q, [3]f32{0, b.size.y * tw.scale.y * 0.5 + 0.22, 0})
		dim_lbl := fmt.tprintf("%.2f × %.2f × %.2f m", b.size.x * tw.scale.x, b.size.y * tw.scale.y, b.size.z * tw.scale.z)
		_draw_3d_tracked_pill(bc_w + top_off, dim_lbl, grip_col)
	}
}

// Draws and handles the 3D W / E / R Transform Gizmo directly on the inner GPU Mesh Instance
// (`faker_mesh_offset`, `faker_mesh_rot_deg`, `faker_mesh_scale`) inside a stationary `Faker CSG` volume!
@(private = "package")
_draw_and_handle_faker_inner_mesh_gizmo :: proc(vol: ^cad_csg.CSGVolume, tool: handles.Tool) {
	if vol == nil || !vol.is_faker_mesh || !_ed.faker_edit_inner_instance_gizmo do return
	f := handles.frame()
	if !f.valid do return

	tw := engine.transform_world(engine.Transform_Handle(vol.owner))
	origin := tw.position + vol.faker_mesh_offset * tw.scale

	v := f.view
	cam_fwd := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
	cam_depth := linalg.dot(origin - v.cam_pos, cam_fwd)
	if cam_depth <= 0.01 && !_ed.faker_gizmo_dragging do return

	dist := max(cam_depth, 0.25) * (2.41421356 / max(abs(v.proj[1, 1]), 0.1))
	if abs(v.proj[3, 3]) > 0.5 && abs(v.proj[1, 1]) > 1e-6 {
		dist = (1.0 / abs(v.proj[1, 1])) * 2.41421356
	}
	size := dist * 0.15
	if size <= 0 do return

	gizmos.in_world_space()
	_FAKER_GIZMO_ID :: u64(0x464B_525f_4d45_5348)
	d: handles.Drag

	rx := math.to_radians(vol.faker_mesh_rot_deg.x)
	ry := math.to_radians(vol.faker_mesh_rot_deg.y)
	rz := math.to_radians(vol.faker_mesh_rot_deg.z)
	cur_rot_q := linalg.quaternion_from_euler_angles_f32(ry, rx, rz, .YXZ)

	#partial switch tool {
	case .Translate:
		pos := origin
		d = handles.position_handle(_FAKER_GIZMO_ID, &pos, quaternion128(1), size, handles.PRIO_TOOL)
		if d.started {
			_ed.faker_gizmo_dragging  = true
			_ed.faker_gizmo_start_pos = origin
			_ed.faker_gizmo_start_off = vol.faker_mesh_offset
		}
		if _ed.faker_gizmo_dragging && (d.dragging || d.released) {
			delta := pos - _ed.faker_gizmo_start_pos
			inv_s := [3]f32{
				1.0 / max(abs(tw.scale.x), 1e-4),
				1.0 / max(abs(tw.scale.y), 1e-4),
				1.0 / max(abs(tw.scale.z), 1e-4),
			}
			vol.faker_mesh_offset = _ed.faker_gizmo_start_off + delta * inv_s
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

	case .Rotate:
		if !_ed.faker_gizmo_dragging {
			_ed.faker_gizmo_rot_q = cur_rot_q
		}
		d = handles.rotation_handle(_FAKER_GIZMO_ID, &_ed.faker_gizmo_rot_q, origin, size, false, handles.PRIO_TOOL)
		if d.started {
			_ed.faker_gizmo_dragging      = true
			_ed.faker_gizmo_rot_start_q   = _ed.faker_gizmo_rot_q
			_ed.faker_gizmo_start_rot_deg = vol.faker_mesh_rot_deg
		}
		if _ed.faker_gizmo_dragging && (d.dragging || d.released) {
			turn := _ed.faker_gizmo_rot_q * conj(_ed.faker_gizmo_rot_start_q)
			fwd := linalg.quaternion128_mul_vector3(turn, [3]f32{0, 0, 1})
			up_v := linalg.quaternion128_mul_vector3(turn, [3]f32{0, 1, 0})
			yaw_d   := math.to_degrees(math.atan2(fwd.x, fwd.z))
			pitch_d := math.to_degrees(math.asin(clamp(-fwd.y, -1.0, 1.0)))
			roll_d  := math.to_degrees(math.atan2(up_v.x, up_v.y))
			vol.faker_mesh_rot_deg = _ed.faker_gizmo_start_rot_deg + [3]f32{pitch_d, yaw_d, roll_d}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

	case .Scale:
		if !_ed.faker_gizmo_dragging {
			_ed.faker_gizmo_scale = {1, 1, 1}
		}
		d = handles.scale_handle(_FAKER_GIZMO_ID, &_ed.faker_gizmo_scale, origin, cur_rot_q, size, handles.PRIO_TOOL)
		if d.started {
			_ed.faker_gizmo_dragging    = true
			_ed.faker_gizmo_start_scale = vol.faker_mesh_scale
		}
		if _ed.faker_gizmo_dragging && (d.dragging || d.released) {
			vol.faker_mesh_scale = {
				max(_ed.faker_gizmo_start_scale.x * _ed.faker_gizmo_scale.x, 0.02),
				max(_ed.faker_gizmo_start_scale.y * _ed.faker_gizmo_scale.y, 0.02),
				max(_ed.faker_gizmo_start_scale.z * _ed.faker_gizmo_scale.z, 0.02),
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}

	if d.released || (_ed.faker_gizmo_dragging && !d.dragging) {
		_ed.faker_gizmo_dragging = false
	}

	_draw_3d_tracked_pill(
		origin + {0, 0.35, 0},
		fmt.tprintf("INNER MESH INSTANCE GIZMO | Pos:(%.2f,%.2f,%.2f) Rot:(%.0f,%.0f,%.0f) Scale:(%.2f,%.2f,%.2f)",
			vol.faker_mesh_offset.x, vol.faker_mesh_offset.y, vol.faker_mesh_offset.z,
			vol.faker_mesh_rot_deg.x, vol.faker_mesh_rot_deg.y, vol.faker_mesh_rot_deg.z,
			vol.faker_mesh_scale.x, vol.faker_mesh_scale.y, vol.faker_mesh_scale.z),
		{1.0, 0.85, 0.22, 1.0},
	)
}

@(private = "package")
_draw_hull_wireframe_edges :: proc(h: cad_csg.CSG_Convex, offset: [3]f32) {
	if len(h.planes) < 4 do return
	buf_a := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	buf_b := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	EXT :: f32(256.0)
	for fp, fi in h.planes {
		u_ax, v_ax := cad_csg.plane_tangent_basis(fp.normal)
		origin := fp.normal * fp.dist
		clear(&buf_a)
		append(&buf_a, origin - u_ax * EXT - v_ax * EXT)
		append(&buf_a, origin + u_ax * EXT - v_ax * EXT)
		append(&buf_a, origin + u_ax * EXT + v_ax * EXT)
		append(&buf_a, origin - u_ax * EXT + v_ax * EXT)
		for cp, ci in h.planes {
			if ci == fi do continue
			cad_csg.clip_polygon_by_plane(buf_a[:], cp, &buf_b)
			buf_a, buf_b = buf_b, buf_a
			if len(buf_a) < 3 do break
		}
		if len(buf_a) >= 3 && cad_csg.polygon_area(buf_a[:]) > 1e-4 {
			m := len(buf_a)
			for i in 0 ..< m {
				gizmos.line(offset + buf_a[i], offset + buf_a[(i + 1) % m])
			}
		}
	}
}

// Draws the unmistakable 3D Object Type Badge (`[FAKER CSG]` vs `[CSG VOLUME]`) + Faker CSG wireframe cages in Scene3D!
@(private = "package")
_draw_csg_object_type_3d_badge_and_cages :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil || !vol.enabled do return
	w := engine.ctx_world()
	owner_h := engine.Transform_Handle(vol.owner)
	if w == nil || owner_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner_h)) do return

	tw := engine.transform_world(owner_h)
	obj_name := "CSG"
	if t := engine.pool_get(&w.transforms, engine.Handle(owner_h)); t != nil && len(t.name) > 0 {
		obj_name = t.name
	}

	lo, hi, aabb_ok := cad_csg.csg_volume_local_aabb(vol)
	if !aabb_ok {
		lo = {-0.5, -0.5, -0.5}
		hi = {0.5, 0.5, 0.5}
	}
	c_local := (lo + hi) * 0.5
	sz_local := hi - lo
	c_world := tw.position + c_local * tw.scale
	top_pt := [3]f32{c_world.x, tw.position.y + hi.y * tw.scale.y + 0.32, c_world.z}

	// Count active chunk hulls (or fallback to runtime_hulls)
	chunk_hulls_n := 0
	for _, ch in vol.chunks {
		if ch != nil {
			chunk_hulls_n += len(ch.destructible_hulls) + len(ch.indestructible_hulls)
		}
	}

	if vol.is_faker_mesh {
		// 1. Emerald-Green Outer CSG Collider Wireframe Cage in `owner_h`'s Local Space (rotates & scales with Transform!)
		gizmos.in_local_space(owner_h)
		gizmos.with_depth_test(false)
		gizmos.with_color({0.18, 0.96, 0.56, 0.72})
		if chunk_hulls_n > 0 {
			for _, ch in vol.chunks {
				if ch == nil do continue
				for h in ch.destructible_hulls   do _draw_hull_wireframe_edges(h, {0, 0, 0})
				for h in ch.indestructible_hulls do _draw_hull_wireframe_edges(h, {0, 0, 0})
			}
		} else if len(vol.runtime_hulls) > 0 {
			for h in vol.runtime_hulls {
				_draw_hull_wireframe_edges(h, {0, 0, 0})
			}
		} else {
			gizmos.wire_box(c_local, sz_local)
		}

		// 2. Gold Inner GPU Mesh Instance Bounding Cage (shown only when uncut so user can see how the mesh fits inside `B`)
		if !engine.asset_guid_is_empty(vol.faker_mesh_guid) && len(vol.runtime_hulls) == 0 && len(vol.recorded_blasts) == 0 && chunk_hulls_n <= 1 {
			mf := engine.MeshFilter{mesh = engine.PPtr{guid = vol.faker_mesh_guid}}
			if mesh, m_ok := engine.mesh_load_filter(&mf); m_ok {
				m_ext := (mesh.aabb_max - mesh.aabb_min) * vol.faker_mesh_scale
				m_mid := (mesh.aabb_min + mesh.aabb_max) * 0.5 * vol.faker_mesh_scale + vol.faker_mesh_offset
				gizmos.with_color({1.0, 0.84, 0.22, 0.88})
				gizmos.wire_box(m_mid, m_ext)
			}
		}

		gizmos.in_world_space()
		hulls_n := max(chunk_hulls_n, max(len(vol.runtime_hulls), len(vol.brushes)))
		_draw_3d_tracked_pill(
			top_pt,
			fmt.tprintf("[FAKER CSG] %s (CSG Hulls: %d + GPU Mesh Instance)", obj_name, hulls_n),
			{0.20, 0.98, 0.60, 1.0},
		)
	} else {
		gizmos.in_local_space(owner_h)
		gizmos.with_depth_test(!vol.is_ghoul_bone_csg)
		gizmos.with_color({1.0, 0.42, 0.24, 0.75} if vol.is_ghoul_bone_csg else {0.25, 0.84, 1.0, 0.45})
		if chunk_hulls_n > 0 {
			for _, ch in vol.chunks {
				if ch == nil do continue
				for h in ch.destructible_hulls   do _draw_hull_wireframe_edges(h, {0, 0, 0})
				for h in ch.indestructible_hulls do _draw_hull_wireframe_edges(h, {0, 0, 0})
			}
		} else if len(vol.runtime_hulls) > 0 {
			for h in vol.runtime_hulls {
				_draw_hull_wireframe_edges(h, {0, 0, 0})
			}
		} else if !vol.is_ghoul_bone_csg {
			gizmos.wire_box(c_local, sz_local)
		}

		if !vol.is_ghoul_bone_csg {
			gizmos.in_world_space()
			hulls_n := max(chunk_hulls_n, len(vol.runtime_hulls))
			_draw_3d_tracked_pill(
				top_pt,
				fmt.tprintf("[CSG VOLUME] %s (%d Brushes, %d Hulls)", obj_name, len(vol.brushes), hulls_n),
				{0.28, 0.88, 1.0, 1.0},
			)
		}
	}
}

// Draws selection outline and clicked brush wireframe when a `CSGVolume` is selected in standard Scene3D mode
@(on_draw_gizmos={component=CSGVolume})
on_draw_gizmos_csg_volume :: proc(vol: ^cad_csg.CSGVolume, ctx: handles.Gizmo_Context) {
	if vol == nil || !vol.enabled do return
	if .Selected not_in ctx.state do return
	if is_cad_tool_active() do return

	_draw_csg_chunk_grid(vol)
	_draw_csg_object_type_3d_badge_and_cages(vol)

	tw := engine.transform_world(engine.Transform_Handle(vol.owner))
	gizmos.in_world_space()

	// Highlight the last clicked brush inside this CSGVolume
	if _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(vol.brushes) {
		b := vol.brushes[_ed.selected_brush_idx]
		gizmos.with_depth_test(false)
		gizmos.with_color({1.0, 0.78, 0.22, 0.85} if b.op == .Add else {1.0, 0.30, 0.25, 0.85})
		if b.primitive != .Profile_2D {
			gizmos.wire_box(tw.position + b.center, b.size)
		}
		if len(vol.brushes) > 1 {
			tag := fmt.tprintf("CSG Brush: %s (%v)", b.name, b.primitive)
			_draw_3d_tracked_pill(tw.position + b.center + {0, b.size.y * 0.5 + 0.28, 0}, tag, {1.0, 0.84, 0.28, 0.95})
		}
	}
}

Pending_Slice_Op :: struct {
	owner:        engine.Transform_Handle,
	world_pt:     [3]f32,
	world_normal: [3]f32,
	mode:         cad_csg.CSG_Clip_Mode,
	split_gap:    f32,
	cut_mat_guid: engine.Asset_GUID,
	cut_albedo:   [4]u8,
}

@(private = "package")
tool_cut_albedo_u8 :: proc() -> [4]u8 {
	if _ed.tool_cut_albedo_enabled || !engine.asset_guid_is_empty(_ed.tool_cut_material_guid) || !engine.asset_guid_is_empty(_ed.tool_cut_tex_guid) {
		return {
			u8(clamp(_ed.tool_cut_albedo.r * 255.0 + 0.5, 0.0, 255.0)),
			u8(clamp(_ed.tool_cut_albedo.g * 255.0 + 0.5, 0.0, 255.0)),
			u8(clamp(_ed.tool_cut_albedo.b * 255.0 + 0.5, 0.0, 255.0)),
			255,
		}
	}
	return {0, 0, 0, 0}
}

@(private = "file")
_pending_slice_queue: [dynamic]Pending_Slice_Op

@(private = "file")
_drain_pending_slice_queue :: proc() {
	if len(_pending_slice_queue) == 0 do return
	w := engine.ctx_world()
	if w == nil {
		clear(&_pending_slice_queue)
		return
	}
	budget := 3
	for len(_pending_slice_queue) > 0 && budget > 0 {
		op := _pending_slice_queue[0]
		ordered_remove(&_pending_slice_queue, 0)
		if op.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(op.owner)) do continue
		_, cur_v := engine.transform_get_comp(op.owner, cad_csg.CSGVolume)
		if cur_v == nil || !cur_v.enabled do continue
		tw := engine.transform_world(op.owner)
		m_t := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		inv_m := linalg.inverse(m_t)
		local_pt := (inv_m * [4]f32{op.world_pt.x, op.world_pt.y, op.world_pt.z, 1.0}).xyz
		local_n  := linalg.normalize0((linalg.transpose(m_t) * [4]f32{op.world_normal.x, op.world_normal.y, op.world_normal.z, 0.0}).xyz)
		local_d  := linalg.dot(local_n, local_pt)
		if cad_csg.csg_volume_clip_by_plane(cur_v, local_n, local_d, op.mode, op.split_gap, op.cut_mat_guid, op.cut_albedo) > 0 {
			budget -= 1
		}
	}
}

// Called directly from `editor/gizmo_pass.odin` while `handles.frame()` and `.Tools` channel are active
cad_csg_draw_gizmos :: proc(tool: handles.Tool = .Translate) {
	_drain_pending_slice_queue()
	if control_rig_ed.scene_viewport_mode == .CAD_Blockout && active_workspace_tab() == .Mesh_Editor {
		// If Soft Deform Brush (Key 6) or 2-Point Clip Plane Slicer (Key 5) is active while in Mesh Editor tab,
		// run the interactive tool right over the Editable_Poly_Mesh / CSGVolume!
		if !(_ed.tool_active && (_ed.sub_tool == .Soft_Deform_Brush || _ed.sub_tool == .Clip_Brush_Plane)) {
			draw_and_handle_mesh_editor_gizmos(tool)
			return
		}
	}
	if !is_cad_tool_active() {
		if vol_sel, _ := _resolve_active_volume(false); vol_sel != nil {
			_draw_csg_object_type_3d_badge_and_cages(vol_sel)
			if vol_sel.is_faker_mesh && _ed.faker_edit_inner_instance_gizmo {
				_draw_and_handle_faker_inner_mesh_gizmo(vol_sel, tool)
				return
			}
			_draw_and_handle_selected_brush_6face_grips(vol_sel)
		}
		if is_editing_csg_brush() {
			if vol, _ := _resolve_active_volume(false); vol != nil {
				_draw_and_handle_selected_brush_gizmo(vol, tool)
			}
		}
		return
	}


	f := handles.frame()
	if !f.valid do return

	if vol_g, _ := _resolve_active_volume(false); vol_g != nil {
		_draw_csg_chunk_grid(vol_g)
		_draw_csg_object_type_3d_badge_and_cages(vol_g)
	}
	// Also draw bone-attached Ghoul CSG cages when in CAD Mode so you can see the exact contoured limb hulls!
	if w_g := engine.ctx_world(); w_g != nil {
		g_it := engine.pool_iterator(cad_csg.csg_volumes(w_g))
		for gv, _ in engine.pool_next(&g_it) {
			if gv != nil && gv.enabled && gv.is_ghoul_bone_csg {
				_draw_csg_object_type_3d_badge_and_cages(gv)
			}
		}
	}

	mp := f.input.mouse
	mouse_in_vp := f.input.hovered
	lmb_clicked := f.input.clicked
	lmb_down    := f.input.down
	rmb_clicked := im.IsMouseClicked(.Right) && mouse_in_vp
	rmb_down    := im.IsMouseDown(.Right) || input.mouse_down(.Right)
	ray := f.ray

	// 1. Raycast against compiled CSG volumes & Auto-Surface WorkPlane (when Idle & unlocked!)
	hit_pos, hit_norm, _, hit_vol, hit_b_idx, hit_mesh := cad_csg.csg_raycast_world(ray)
	_ed.hover_vol = hit_vol
	_ed.hover_brush_idx = hit_b_idx
	if hit_mesh {
		_ed.hover_raw_pos = hit_pos
		_ed.hover_raw_normal = hit_norm
	}

	// Auto-Surface WorkPlane: dynamically align to hovered CSG face BEFORE Point 1 is clicked,
	// then stay 100% locked onto that surface throughout the sketch/extrusion!
	if mouse_in_vp && !_ed.plane_locked && _ed.draft_stage == .Idle && len(_ed.sketch_points) == 0 && len(_ed.glass_poly_pts_3d) == 0 && !_ed.push_active &&
	   (_ed.sub_tool == .Spline_Poly_Sketch || _ed.sub_tool == .Box_Primitive) {
		if hit_mesh && linalg.length2(hit_norm) > 0.25 {
			_align_workplane_to_surface(hit_pos, hit_norm)
			// Phase-lock tangent origin to metric grid while preserving exact surface normal offset!
			n_dist := linalg.dot(hit_pos, _ed.plane.normal)
			u_snap := _snap_scalar(linalg.dot(hit_pos, _ed.plane.u_axis), _ed.snap_step)
			v_snap := _snap_scalar(linalg.dot(hit_pos, _ed.plane.v_axis), _ed.snap_step)
			_ed.plane.origin = _ed.plane.normal * n_dist + _ed.plane.u_axis * u_snap + _ed.plane.v_axis * v_snap
		} else if _ed.plane.is_custom {
			_reset_workplane_to_ground()
		}
	}

	wp_pt, wp_uv, wp_ok := _raycast_workplane(ray)
	_ed.hover_valid = wp_ok
	if wp_ok {
		_ed.hover_snapped = wp_pt
		_ed.hover_uv = wp_uv
	}

	// 2. Global CAD Mode Hotkeys (when not flying camera with RMB and keybindings are enabled in settings)
	if mouse_in_vp && !rmb_down && !im.GetIO().WantTextInput && are_cad_hotkeys_enabled() {
		if are_subtool_number_hotkeys_enabled() {
			if _key_just_pressed(._1, ._1) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Spline_Poly_Sketch)
			}
			if _key_just_pressed(._2, ._2) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Box_Primitive)
			}
			if _key_just_pressed(._3, ._3) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Face_Push_Pull)
			}
			if _key_just_pressed(._4, ._4) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Geo_Mod_Blast)
			}
			if _key_just_pressed(._5, ._5) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Clip_Brush_Plane)
			}
			if _key_just_pressed(._6, ._6) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Soft_Deform_Brush)
			}
			if _key_just_pressed(._7, ._7) && _ed.num_len == 0 && _ed.draft_stage == .Idle && !_ed.push_active {
				activate_cad_tool(.Draw_Glass_Poly)
			}
		}
		if _ed.sub_tool == .Soft_Deform_Brush && _ed.num_len == 0 && _key_just_pressed(.TAB, .Tab) {
			_ed.deform_mode = cad_csg.CSG_Soft_Deform_Mode((int(_ed.deform_mode) + 1) % 4)
		}
		if _ed.sub_tool == .Clip_Brush_Plane && _ed.num_len == 0 && _key_just_pressed(.TAB, .Tab) {
			_ed.clip_mode = cad_csg.CSG_Clip_Mode((int(_ed.clip_mode) + 1) % 3)
		}
		if _ed.sub_tool == .Face_Push_Pull && _ed.num_len == 0 && are_axis_lock_hotkeys_enabled() {
			// Blender-Style Extrude/Intrude Axis Selection Hotkeys (`N` = Normal, `X` = World X, `Y` = World Y, `Z` = World Z, `G` = Free Cursor, `Tab` = Mode)
			if _key_just_pressed(.N, .N) do _ed.extrude_axis_mode = .Face_Normal
			if _key_just_pressed(.X, .X) do _ed.extrude_axis_mode = (.World_X if _ed.extrude_axis_mode != .World_X else .Face_Normal)
			if _key_just_pressed(.Y, .Y) do _ed.extrude_axis_mode = (.World_Y if _ed.extrude_axis_mode != .World_Y else .Face_Normal)
			if _key_just_pressed(.Z, .Z) do _ed.extrude_axis_mode = (.World_Z if _ed.extrude_axis_mode != .World_Z else .Face_Normal)
			if _key_just_pressed(.G, .G) do _ed.extrude_axis_mode = (.Free_Cursor if _ed.extrude_axis_mode != .Free_Cursor else .Face_Normal)
			if _key_just_pressed(.TAB, .Tab) {
				_ed.extrude_csg_behavior = (.Move_Face_Plane if _ed.extrude_csg_behavior == .Extrude_Intrude_Segment else .Extrude_Intrude_Segment)
			}
		} else if _key_just_pressed(.X, .X) && _ed.num_len == 0 && _ed.draft_stage != .Drawing_Footprint && are_axis_lock_hotkeys_enabled() {
			_ed.brush_op = .Subtract if _ed.brush_op == .Add else .Add
			if _ed.draft_stage == .Extruding_Height {
				_ed.extrude_height = -abs(_ed.extrude_height) if _ed.brush_op == .Subtract else abs(_ed.extrude_height)
			}
		}
		if are_modeling_op_hotkeys_enabled() {
			// `[` and `]` keys: adjust Geo-Mod Blast Radius live in Scene3D!
			if _key_just_pressed(.LEFTBRACKET, .LeftBracket) {
				_ed.blast_radius = clamp(_ed.blast_radius - 0.10, 0.12, 8.0)
			}
			if _key_just_pressed(.RIGHTBRACKET, .RightBracket) {
				_ed.blast_radius = clamp(_ed.blast_radius + 0.10, 0.12, 8.0)
			}
			// `C` key: toggle Smooth Spline vs Sharp Corner (or flip hovered sketch vertex!)
			if _key_just_pressed(.C, .C) && _ed.sub_tool == .Spline_Poly_Sketch {
				hovered_pt := _find_hovered_sketch_point(wp_uv)
				if hovered_pt >= 0 {
					_ed.sketch_points[hovered_pt].smooth = !_ed.sketch_points[hovered_pt].smooth
				} else {
					_ed.sketch_next_smooth = !_ed.sketch_next_smooth
				}
			}
			// `F` key: toggle manual WorkPlane lock on hovered surface (`Shift+F` unlocks & resets to Ground Y=0)
			if _key_just_pressed(.F, .F) {
				if input.key_down(.LSHIFT) || input.key_down(.RSHIFT) || f.input.shift {
					_ed.plane_locked = false
					_reset_workplane_to_ground()
				} else {
					if !_ed.plane_locked && hit_mesh {
						_align_workplane_to_surface(hit_pos, hit_norm)
					}
					_ed.plane_locked = !_ed.plane_locked
				}
			}
			// `B` key: instant Red Faction Geo-Mod blast at hovered surface point!
			if _key_just_pressed(.B, .B) {
				target := hit_pos if hit_mesh else wp_pt
				if hit_mesh || wp_ok {
					cad_csg.csg_trigger_blast(target, _ed.blast_radius, _ed.blast_impulse, _ed.tool_cut_material_guid, tool_cut_albedo_u8())
				}
			}
		}
		// `Escape`: cancel active draft or spline sketch (or exit CAD tool if already idle)
		if _key_just_pressed(.ESCAPE, .Escape) {
			if _ed.draft_stage != .Idle || _ed.push_active || len(_ed.sketch_points) > 0 || len(_ed.glass_poly_pts_3d) > 0 || _ed.num_len > 0 || _ed.clip_has_pt_a {
				_reset_transient_tool_state()
				clear(&_ed.sketch_points)
			} else {
				deactivate_cad_tool()
				return
			}
		}
	}

	// 3. Draw the Dynamic 2D WorkPlane Grid + Polar Protractor Arc / OSNAP Marker in WorldSpace
	_draw_workplane_grid()
	_draw_axis_snap_guide()

	// 4. Execute Active CAD Sub-Tool State Machine
	if mouse_in_vp {
		switch _ed.sub_tool {
		case .Spline_Poly_Sketch:
			_update_and_draw_spline_sketch_tool(ray, wp_ok, wp_pt, wp_uv, f.input.shift, lmb_clicked, lmb_down, rmb_clicked)
		case .Box_Primitive:
			_update_and_draw_box_primitive_tool(ray, wp_ok, wp_pt, wp_uv, lmb_clicked, lmb_down)
		case .Face_Push_Pull:
			_update_and_draw_face_push_pull(ray, hit_mesh, hit_pos, hit_norm, hit_vol, hit_b_idx, lmb_clicked, lmb_down)
		case .Geo_Mod_Blast:
			_update_and_draw_blast_tool(mp, hit_mesh, hit_pos, hit_norm, wp_ok, wp_pt, lmb_clicked)
		case .Clip_Brush_Plane:
			_update_and_draw_clip_plane_tool(hit_mesh, hit_pos, hit_norm, hit_vol, wp_ok, wp_pt, lmb_clicked, rmb_clicked)
		case .Soft_Deform_Brush:
			_update_and_draw_soft_deform_brush_tool(hit_mesh, hit_pos, hit_norm, hit_vol, wp_ok, wp_pt, lmb_clicked, rmb_clicked)
		case .Draw_Glass_Poly:
			_update_and_draw_glass_poly_tool(ray, hit_mesh, hit_pos, hit_norm, hit_vol, wp_ok, wp_pt, lmb_clicked, rmb_clicked)
		}
	} else {
		// Still draw active sketch / extrusion preview when mouse is over toolbar
		if _ed.sub_tool == .Spline_Poly_Sketch && len(_ed.sketch_points) > 0 {
			_draw_spline_sketch_preview(wp_ok, wp_uv)
		} else if _ed.sub_tool == .Box_Primitive && _ed.draft_stage != .Idle {
			_draw_box_draft_preview()
		} else if _ed.sub_tool == .Draw_Glass_Poly && len(_ed.glass_poly_pts_3d) > 0 {
			_update_and_draw_glass_poly_tool(ray, false, {}, {}, nil, false, {}, false, false)
		}
	}

	// 5. Highlight selected brush wireframe AND show subtractive/blast crater wireframes in CAD Mode so they are never invisible!
	if vol, owner := _resolve_active_volume(false); vol != nil {
		tw := engine.transform_world(owner)
		gizmos.in_world_space()
		gizmos.with_depth_test(false)

		if _ed.show_cut_and_blast_wireframes {
			for b, b_i in vol.brushes {
				if b.op != .Subtract || b_i == _ed.selected_brush_idx do continue
				gizmos.with_color({1.0, 0.32, 0.25, 0.42})
				if b.primitive == .Profile_2D && len(b.profile_points) >= 3 {
					poly := cad_csg.csg_eval_profile_2d(b.profile_points[:], true, 6, context.temp_allocator)
					orig := tw.position + b.center
					for i in 0 ..< len(poly) {
						pa := poly[i]
						pb := poly[(i + 1) % len(poly)]
						p0 := orig + b.plane_u * pa.x + b.plane_v * pa.y
						p1 := orig + b.plane_u * pb.x + b.plane_v * pb.y
						gizmos.line(p0, p1)
						gizmos.line(p0 + b.plane_normal * b.extrude_height, p1 + b.plane_normal * b.extrude_height)
					}
				} else {
					gizmos.wire_box(tw.position + b.center, b.size)
				}
			}
			if _ed.selected_blast_idx >= 0 && _ed.selected_blast_idx < len(vol.recorded_blasts) {
				rb := vol.recorded_blasts[_ed.selected_blast_idx]
				gizmos.with_color({1.0, 0.78, 0.18, 0.95})
				gizmos.wire_sphere(tw.position + rb.local_pos, rb.radius)
			}
		}

		if _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(vol.brushes) {
			b := vol.brushes[_ed.selected_brush_idx]
			sel_col := [4]f32{0.25, 0.90, 0.45, 0.85} if b.op == .Add else [4]f32{1.0, 0.30, 0.25, 0.92}
			gizmos.with_color(sel_col)
			if b.primitive == .Profile_2D && len(b.profile_points) >= 3 {
				poly := cad_csg.csg_eval_profile_2d(b.profile_points[:], true, 6, context.temp_allocator)
				orig := tw.position + b.center
				for i in 0 ..< len(poly) {
					pa := poly[i]
					pb := poly[(i + 1) % len(poly)]
					p0 := orig + b.plane_u * pa.x + b.plane_v * pa.y
					p1 := orig + b.plane_u * pb.x + b.plane_v * pb.y
					gizmos.line(p0, p1)
					gizmos.line(p0 + b.plane_normal * b.extrude_height, p1 + b.plane_normal * b.extrude_height)
					gizmos.line(p0, p0 + b.plane_normal * b.extrude_height)
				}
			} else {
				gizmos.wire_box(tw.position + b.center, b.size)
			}
		}

		if (_ed.show_deform_vectors || _ed.sub_tool == .Soft_Deform_Brush) && len(vol.soft_deform_stamps) > 0 {
			_draw_soft_deform_renderer_math_debug(vol)
		}
	}
}

@(private = "package")
_draw_workplane_grid :: proc() {
	gizmos.in_world_space()
	gizmos.with_depth_test(true)

	o := _ed.plane.origin
	u := _ed.plane.u_axis
	v := _ed.plane.v_axis
	ext := _ed.grid_half_ext
	step := max(_ed.snap_step, 0.25)
	steps := int(math.round(ext / step))

	_, u_col := _world_axis_info(u)
	_, v_col := _world_axis_info(v)

	for i := -steps; i <= steps; i += 1 {
		dist := f32(i) * step
		is_major := (i == 0) || (abs(i) % 4 == 0)
		if i == 0 {
			gizmos.with_color(u_col)
			gizmos.line(o - u * ext, o + u * ext)
			gizmos.with_color(v_col)
			gizmos.line(o - v * ext, o + v * ext)
		} else {
			alpha: f32 = 0.34 if is_major else 0.14
			col := [4]f32{0.35, 0.78, 0.95, alpha} if _ed.plane.is_custom else [4]f32{0.58, 0.64, 0.72, alpha}
			gizmos.with_color(col)
			gizmos.line(o + v * dist - u * ext, o + v * dist + u * ext)
			gizmos.line(o + u * dist - v * ext, o + u * dist + v * ext)
		}
	}

	gizmos.with_color({1.0, 0.72, 0.18, 0.95} if _ed.plane_locked else {1.0, 0.85, 0.20, 0.72})
	gizmos.line(o, o + _ed.plane.normal * 0.8)
}

// Draws the 3D Polar Protractor Arc & Ray strictly from the placed anchor point + Magnetic OSNAP marker!
@(private = "package")
_draw_axis_snap_guide :: proc() {
	if _ed.draft_stage == .Extruding_Height || _ed.push_active do return
	if _ed.sub_tool != .Spline_Poly_Sketch && _ed.sub_tool != .Box_Primitive do return

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// 1. Magnetic OSNAP Marker (`□ Vertex`, `△ Midpoint`, `◎ Center`)
	if _ed.osnap_active {
		p := _ed.osnap_world_pt
		n := _ed.plane.normal
		u := _ed.plane.u_axis
		v := _ed.plane.v_axis
		switch _ed.osnap_kind {
		case .None:
		case .Vertex:
			gizmos.with_color({0.20, 1.0, 0.48, 1.0})
			gizmos.wire_box(p, {0.20, 0.20, 0.20})
			_draw_3d_tracked_pill(p + n * 0.26, "Vertex", {0.25, 1.0, 0.55, 1.0})
		case .Midpoint:
			gizmos.with_color({0.25, 0.94, 1.0, 1.0})
			s: f32 = 0.13
			t0 := p + v * s
			t1 := p - v * (s * 0.7) - u * s
			t2 := p - v * (s * 0.7) + u * s
			gizmos.line(t0, t1)
			gizmos.line(t1, t2)
			gizmos.line(t2, t0)
			_draw_3d_tracked_pill(p + n * 0.26, "Midpoint", {0.32, 0.95, 1.0, 1.0})
		case .Face_Center:
			gizmos.with_color({1.0, 0.84, 0.22, 1.0})
			gizmos.wire_circle(p, n, 0.14, 18)
			_draw_3d_tracked_pill(p + n * 0.26, "Center", {1.0, 0.86, 0.28, 1.0})
		}
	}

	if !_ed.snap_guide_active do return

	from := _ed.snap_guide_from
	dir  := _ed.snap_guide_dir
	u    := _ed.plane.u_axis
	v    := _ed.plane.v_axis

	// 2. Outward Polar Ray starting AT `from` (plus subtle faint back-extension)
	faint_col := _ed.snap_guide_col
	faint_col.a *= 0.26
	gizmos.with_color(faint_col)
	gizmos.line(from - dir * 2.0, from)
	gizmos.with_color(_ed.snap_guide_col)
	gizmos.line(from, from + dir * max(_ed.polar_radial_len + 2.5, 5.0))

	// 3. 3D Polar Protractor Reference Arc & 15° Ticks centered at `from`!
	if _ed.polar_arc_active {
		arc_r := clamp(_ed.polar_radial_len * 0.38, 0.32, 1.35)
		// Subtle 360° 15-degree protractor tick ring
		gizmos.with_color({0.75, 0.84, 0.95, 0.30})
		gizmos.wire_circle(from, _ed.plane.normal, arc_r, 36)
		for tk := 0; tk < 24; tk += 1 {
			ang_t := f32(tk) * 15.0 * (math.PI / 180.0)
			td := u * math.cos(ang_t) + v * math.sin(ang_t)
			in_r := arc_r * (0.86 if (tk % 3 == 0) else 0.92)
			gizmos.line(from + td * in_r, from + td * arc_r)
		}
		// 0° reference baseline tick
		gizmos.with_color({1.0, 0.42, 0.42, 0.65})
		gizmos.line(from, from + u * (arc_r * 1.15))

		// Swept angle arc from `0°` to `_ed.polar_snapped_deg`
		gizmos.with_color(_ed.snap_guide_col)
		segs :: 16
		end_rad := _ed.polar_snapped_deg * (math.PI / 180.0)
		for s_i in 0 ..< segs {
			a0 := (f32(s_i) / f32(segs)) * end_rad
			a1 := (f32(s_i + 1) / f32(segs)) * end_rad
			p0 := from + (u * math.cos(a0) + v * math.sin(a0)) * (arc_r * 0.72)
			p1 := from + (u * math.cos(a1) + v * math.sin(a1)) * (arc_r * 0.72)
			gizmos.line(p0, p1)
		}
	}

	if len(_ed.snap_guide_label) > 0 && _ed.hover_valid {
		_draw_3d_tracked_pill(_ed.hover_snapped + _ed.plane.normal * 0.28, _ed.snap_guide_label, _ed.snap_guide_col)
	}
}

@(private = "package")
_find_hovered_sketch_point :: proc(hover_uv: [2]f32) -> int {
	thresh := max(_ed.snap_step * 0.45, 0.22)
	thresh_sq := thresh * thresh
	for p, i in _ed.sketch_points {
		if linalg.length2(p.uv - hover_uv) <= thresh_sq {
			return i
		}
	}
	return -1
}

// Initializes 3D Ray-to-Axis extrusion from the 2D sketch's centroid along `_ed.plane.normal`.
@(private = "package")
_begin_spline_extrude_stage :: proc(ray: engine.Ray) {
	c2d: [2]f32
	for p in _ed.sketch_points do c2d += p.uv
	if len(_ed.sketch_points) > 0 do c2d /= f32(len(_ed.sketch_points))
	_ed.extrude_axis_origin    = _ed.plane.origin + _ed.plane.u_axis * c2d.x + _ed.plane.v_axis * c2d.y
	_ed.extrude_start_s        = _ray_closest_dist_along_axis(ray, _ed.extrude_axis_origin, _ed.plane.normal)
	_ed.extrude_height         = _default_extrude_height()
	_ed.hud_angle_field_active = false
	_ed.hud_locked_len_valid   = false
	_ed.draft_stage            = .Extruding_Height
}

// ============================================================================
// TOOL 1: 2D POLYLINE / CATMULL-ROM SPLINE SKETCHER & EXTRUDER
// ============================================================================

@(private = "package")
_update_and_draw_spline_sketch_tool :: proc(
	ray:         engine.Ray,
	wp_ok:       bool,
	wp_pt:       [3]f32,
	wp_uv:       [2]f32,
	shift_held:  bool,
	lmb_clicked: bool,
	lmb_down:    bool,
	rmb_clicked: bool,
) {
	_ = wp_pt
	_ = shift_held

	// `Backspace` (when not editing a typed number) undoes ONLY the last placed vertex!
	if _ed.num_len == 0 && !_ed.hud_locked_len_valid && _ed.draft_stage != .Extruding_Height && len(_ed.sketch_points) > 0 &&
	   _key_just_pressed(.BACKSPACE, .Backspace) {
		pop(&_ed.sketch_points)
		if len(_ed.sketch_points) == 0 {
			_ed.draft_stage = .Idle
		}
		return
	}

	// Poll keyboard numeric overrides (`3.5` + Enter, `3.5` + Tab + `30` + Enter, or `3.5,2.0` + Enter)
	if _poll_numeric_keyboard_input() {
		if _ed.draft_stage == .Extruding_Height {
			_commit_drafted_spline_profile_brush()
			return
		}
	}

	min_extrude_pts := 2 if _ed.spline_wall_strip else 3

	if _ed.draft_stage != .Extruding_Height {
		// Enter or Space transitions to 3D Extrude (`>= 2` pts in Wall-Strip mode, `>= 3` pts in closed loop)!
		if (_key_just_pressed(.RETURN, .Enter) || _key_just_pressed(.KP_ENTER, .KeypadEnter) || _key_just_pressed(.SPACE, .Space)) &&
		   len(_ed.sketch_points) >= min_extrude_pts {
			_begin_spline_extrude_stage(ray)
			return
		}

		if wp_ok {
			hovered_idx := _find_hovered_sketch_point(wp_uv)

			// Right-Click on an existing point toggles Sharp Corner vs Smooth Spline Curve!
			if hovered_idx >= 0 && rmb_clicked {
				_ed.sketch_points[hovered_idx].smooth = !_ed.sketch_points[hovered_idx].smooth
			}

			// Dragging an existing control point
			if _ed.sketch_drag_pt_idx >= 0 {
				handles.claim_mouse(true)
				if lmb_down && _ed.sketch_drag_pt_idx < len(_ed.sketch_points) {
					_ed.sketch_points[_ed.sketch_drag_pt_idx].uv = wp_uv
				} else {
					_ed.sketch_drag_pt_idx = -1
				}
			} else if lmb_clicked {
				handles.claim_mouse(true)
				// Clicking P0 when >= 3 points (and not in open Wall-Strip mode) closes the loop and starts Extrude!
				if !_ed.spline_wall_strip && hovered_idx == 0 && len(_ed.sketch_points) >= 3 {
					_begin_spline_extrude_stage(ray)
				} else if hovered_idx > 0 {
					_ed.sketch_drag_pt_idx = hovered_idx
				} else {
					append(&_ed.sketch_points, cad_csg.CSG_Profile_Point{
						uv      = wp_uv,
						smooth  = true if _ed.sketch_freehand else _ed.sketch_next_smooth,
						tension = _ed.sketch_tension,
					})
					_ed.hud_angle_field_active = false
					_ed.hud_locked_len_valid   = false
					_ed.draft_stage = .Drawing_Footprint
				}
			} else if lmb_down && _ed.sketch_freehand {
				// Freehand continuous spline stroke: sample smooth control points every `min_dist` meters!
				handles.claim_mouse(true)
				min_dist := max(_ed.snap_step * 0.75, 0.30)
				if len(_ed.sketch_points) == 0 || linalg.length(wp_uv - _ed.sketch_points[len(_ed.sketch_points) - 1].uv) >= min_dist {
					append(&_ed.sketch_points, cad_csg.CSG_Profile_Point{
						uv      = wp_uv,
						smooth  = true,
						tension = _ed.sketch_tension,
					})
					_ed.draft_stage = .Drawing_Footprint
				}
			}
		}
	} else {
		// Phase 2: Extruding 3D Height along WorkPlane Normal using 3D Ray-to-Axis projection!
		handles.claim_mouse(false)
		cur_s := _ray_closest_dist_along_axis(ray, _ed.extrude_axis_origin, _ed.plane.normal)
		raw_h := cur_s - _ed.extrude_start_s
		if abs(raw_h) < 0.05 {
			raw_h = _default_extrude_height()
		}
		snapped_h := raw_h if im.GetIO().KeyAlt else _snap_scalar(raw_h, _ed.snap_step)
		if abs(snapped_h) < _ed.snap_step && !im.GetIO().KeyAlt {
			snapped_h = -_ed.snap_step if (_ed.brush_op == .Subtract || raw_h < 0) else _ed.snap_step
		}
		_ed.extrude_height = snapped_h

		if lmb_clicked || _key_just_pressed(.RETURN, .Enter) || _key_just_pressed(.KP_ENTER, .KeypadEnter) {
			_commit_drafted_spline_profile_brush()
			return
		}
	}

	_draw_spline_sketch_preview(wp_ok, wp_uv)
}

@(private = "package")
_draw_spline_sketch_preview :: proc(wp_ok: bool, wp_uv: [2]f32) {
	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	o := _ed.plane.origin
	u := _ed.plane.u_axis
	v := _ed.plane.v_axis
	n := _ed.plane.normal

	// Draw cursor snap marker
	if wp_ok && _ed.draft_stage != .Extruding_Height {
		pt3 := o + u * wp_uv.x + v * wp_uv.y
		marker_col := [4]f32{1.0, 0.78, 0.22, 0.95} if _ed.sketch_next_smooth else [4]f32{0.25, 0.92, 1.0, 0.95}
		gizmos.with_color(marker_col)
		if _ed.sketch_next_smooth {
			gizmos.solid_sphere(pt3, 0.08)
		} else {
			gizmos.wire_box(pt3, {0.14, 0.14, 0.14})
		}
	}

	if len(_ed.sketch_points) == 0 do return

	preview_pts := make([dynamic]cad_csg.CSG_Profile_Point, 0, len(_ed.sketch_points) + 1, context.temp_allocator)
	append(&preview_pts, .._ed.sketch_points[:])
	is_closed := (_ed.draft_stage == .Extruding_Height) && !_ed.spline_wall_strip
	if _ed.draft_stage != .Extruding_Height && wp_ok && _ed.sketch_drag_pt_idx < 0 {
		if !_ed.spline_wall_strip && len(preview_pts) >= 3 && linalg.length(wp_uv - preview_pts[0].uv) <= max(_ed.snap_step * 0.45, 0.22) {
			is_closed = true
		} else {
			append(&preview_pts, cad_csg.CSG_Profile_Point{
				uv      = wp_uv,
				smooth  = _ed.sketch_next_smooth,
				tension = _ed.sketch_tension,
			})
		}
	}

	curve_col := [4]f32{0.22, 0.95, 0.55, 0.95} if _ed.brush_op == .Add else [4]f32{1.0, 0.32, 0.28, 0.98}
	gizmos.with_color(curve_col)

	if _ed.spline_wall_strip && len(preview_pts) >= 2 {
		wall_pts := _build_wall_strip_polygon_2d(preview_pts[:], _ed.spline_wall_thickness, context.temp_allocator)
		wn := len(wall_pts)
		for i in 0 ..< wn {
			pa := wall_pts[i].uv
			pb := wall_pts[(i + 1) % wn].uv
			p0 := o + u * pa.x + v * pa.y
			p1 := o + u * pb.x + v * pb.y
			gizmos.line(p0, p1)
			if _ed.draft_stage == .Extruding_Height {
				h := _ed.extrude_height
				gizmos.line(p0 + n * h, p1 + n * h)
				gizmos.line(p0, p0 + n * h)
			}
		}
	} else {
		poly2d := cad_csg.csg_eval_profile_2d(preview_pts[:], is_closed, 6, context.temp_allocator)
		seg_limit := len(poly2d) if is_closed else max(len(poly2d) - 1, 0)
		for i in 0 ..< seg_limit {
			pa := poly2d[i]
			pb := poly2d[(i + 1) % len(poly2d)]
			p0 := o + u * pa.x + v * pa.y
			p1 := o + u * pb.x + v * pb.y
			gizmos.line(p0, p1)

			if _ed.draft_stage == .Extruding_Height {
				h := _ed.extrude_height
				gizmos.line(p0 + n * h, p1 + n * h)
				if i % 2 == 0 {
					gizmos.line(p0, p0 + n * h)
				}
			}
		}
	}

	for cp, idx in _ed.sketch_points {
		cp3 := o + u * cp.uv.x + v * cp.uv.y
		if idx == 0 {
			gizmos.with_color({0.20, 1.0, 0.45, 1.0})
			gizmos.solid_sphere(cp3, 0.11)
		} else if cp.smooth {
			gizmos.with_color({1.0, 0.78, 0.20, 0.95})
			gizmos.solid_sphere(cp3, 0.085)
		} else {
			gizmos.with_color({0.25, 0.90, 1.0, 0.95})
			gizmos.wire_box(cp3, {0.14, 0.14, 0.14})
		}
	}

	// Crisp, non-verbose numeric 3D callouts (full shortcut help lives in the Bottom-Center CAD Telemetry HUD!)
	if _ed.draft_stage == .Extruding_Height {
		base_c := _ed.extrude_axis_origin
		top_c  := base_c + n * _ed.extrude_height
		gizmos.with_color({1.0, 0.88, 0.22, 1.0})
		gizmos.line(base_c, top_c)
		gizmos.solid_sphere(top_c, 0.11)
		h_lbl := fmt.tprintf("H: %+.2f m", _ed.extrude_height)
		_draw_3d_tracked_pill((base_c + top_c) * 0.5, h_lbl, {0.35, 1.0, 0.55, 1.0} if _ed.brush_op == .Add else {1.0, 0.42, 0.38, 1.0})
	} else if wp_ok && len(_ed.sketch_points) > 0 {
		last_uv := _ed.sketch_points[len(_ed.sketch_points) - 1].uv
		du := wp_uv.x - last_uv.x
		dv := wp_uv.y - last_uv.y
		seg_len := math.sqrt(du * du + dv * dv)
		ang_deg := math.atan2(dv, du) * (180.0 / math.PI)
		mid_uv := (last_uv + wp_uv) * 0.5
		mid_3d := o + u * mid_uv.x + v * mid_uv.y
		seg_lbl := fmt.tprintf("%.2f m  (%+.1f°)", seg_len, ang_deg)
		_draw_3d_tracked_pill(mid_3d, seg_lbl, {0.55, 0.92, 1.0, 1.0})

		if !_ed.spline_wall_strip && len(_ed.sketch_points) >= 3 && linalg.length(wp_uv - _ed.sketch_points[0].uv) <= max(_ed.snap_step * 0.45, 0.22) {
			p0_3d := o + u * _ed.sketch_points[0].uv.x + v * _ed.sketch_points[0].uv.y
			_draw_3d_tracked_pill(p0_3d + n * 0.24, "Close & Extrude", {0.35, 1.0, 0.58, 1.0})
		}
	}

	if _ed.num_len > 0 || _ed.hud_locked_len_valid {
		num_str := string(_ed.num_buf[:_ed.num_len])
		tag := fmt.tprintf("Ang: %s_°", num_str) if _ed.hud_angle_field_active else fmt.tprintf("L: %s_ m", num_str)
		_draw_3d_tracked_pill(o + u * wp_uv.x + v * wp_uv.y + n * 0.42, tag, {1.0, 0.65, 1.0, 1.0})
	}
}

// ============================================================================
// TOOL 2: BOX / PRIMITIVE BUILDER (With 3D Ray-Axis Extrusion & Boolean Cut Penetration)
// ============================================================================

@(private = "package")
_update_and_draw_box_primitive_tool :: proc(
	ray:         engine.Ray,
	wp_ok:       bool,
	wp_pt:       [3]f32,
	wp_uv:       [2]f32,
	lmb_clicked: bool,
	lmb_down:    bool,
) {
	if _ed.draft_stage != .Idle {
		if _poll_numeric_keyboard_input() {
			_commit_drafted_box_brush()
			_ed.draft_stage = .Idle
			_ed.footprint_dragged = false
			return
		}
	}

	switch _ed.draft_stage {
	case .Idle:
		if wp_ok {
			gizmos.in_world_space()
			gizmos.with_depth_test(false)
			gizmos.with_color({0.25, 0.92, 1.0, 0.95})
			gizmos.solid_sphere(wp_pt, 0.08)
			if lmb_clicked {
				handles.claim_mouse(true)
				_ed.start_uv = wp_uv
				_ed.curr_uv = wp_uv + {_ed.snap_step, _ed.snap_step}
				_ed.extrude_height = _default_extrude_height()
				_ed.num_len = 0
				_ed.footprint_dragged = false
				_ed.draft_stage = .Drawing_Footprint
			}
		}

	case .Drawing_Footprint:
		handles.claim_mouse(lmb_down)
		if wp_ok {
			_ed.curr_uv = wp_uv
			if lmb_down && linalg.length(wp_uv - _ed.start_uv) >= max(_ed.snap_step * 0.45, 0.15) {
				_ed.footprint_dragged = true
			}
		}
		// Supports BOTH Click+Drag+Release footprint AND Click-Corner-A -> Click-Corner-B!
		if (_ed.footprint_dragged && !lmb_down) || (!_ed.footprint_dragged && lmb_clicked) {
			mid_uv := (_ed.start_uv + _ed.curr_uv) * 0.5
			_ed.extrude_axis_origin = _ed.plane.origin + _ed.plane.u_axis * mid_uv.x + _ed.plane.v_axis * mid_uv.y
			_ed.extrude_start_s     = _ray_closest_dist_along_axis(ray, _ed.extrude_axis_origin, _ed.plane.normal)
			_ed.extrude_height      = _default_extrude_height()
			_ed.draft_stage         = .Extruding_Height
		}

	case .Extruding_Height:
		handles.claim_mouse(false)
		cur_s := _ray_closest_dist_along_axis(ray, _ed.extrude_axis_origin, _ed.plane.normal)
		raw_h := cur_s - _ed.extrude_start_s
		if abs(raw_h) < 0.05 {
			raw_h = _default_extrude_height()
		}
		snapped_h := _snap_scalar(raw_h, _ed.snap_step)
		if abs(snapped_h) < _ed.snap_step {
			snapped_h = -_ed.snap_step if (_ed.brush_op == .Subtract || raw_h < 0) else _ed.snap_step
		}
		_ed.extrude_height = snapped_h

		if lmb_clicked || _key_just_pressed(.RETURN, .Enter) || _key_just_pressed(.KP_ENTER, .KeypadEnter) {
			_commit_drafted_box_brush()
			_ed.draft_stage = .Idle
			_ed.footprint_dragged = false
		}
	}

	if _ed.draft_stage != .Idle {
		_draw_box_draft_preview()
	}
}

@(private = "package")
_draw_box_draft_preview :: proc() {
	u_min := min(_ed.start_uv.x, _ed.curr_uv.x)
	u_max := max(_ed.start_uv.x, _ed.curr_uv.x)
	v_min := min(_ed.start_uv.y, _ed.curr_uv.y)
	v_max := max(_ed.start_uv.y, _ed.curr_uv.y)
	step := max(_ed.snap_step, 0.1)
	if u_max - u_min < step * 0.5 do u_max = u_min + step
	if v_max - v_min < step * 0.5 do v_max = v_min + step

	w_u := u_max - u_min
	d_v := v_max - v_min
	diag := math.sqrt(w_u * w_u + d_v * d_v)

	o := _ed.plane.origin
	u := _ed.plane.u_axis
	v := _ed.plane.v_axis
	n := _ed.plane.normal

	c00 := o + u * u_min + v * v_min
	c10 := o + u * u_max + v * v_min
	c11 := o + u * u_max + v * v_max
	c01 := o + u * u_min + v * v_max

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	wire_col := [4]f32{0.22, 0.92, 0.48, 0.95} if _ed.brush_op == .Add else [4]f32{1.0, 0.28, 0.24, 0.98}
	gizmos.with_color(wire_col)

	gizmos.line(c00, c10)
	gizmos.line(c10, c11)
	gizmos.line(c11, c01)
	gizmos.line(c01, c00)

	gizmos.with_color({1.0, 0.84, 0.22, 0.70})
	gizmos.line(c00, c11)

	h_n := _ed.extrude_height if _ed.draft_stage == .Extruding_Height else f32(0.0)
	if _ed.draft_stage == .Extruding_Height {
		t00 := c00 + n * h_n
		t10 := c10 + n * h_n
		t11 := c11 + n * h_n
		t01 := c01 + n * h_n
		gizmos.with_color(wire_col)
		gizmos.line(t00, t10)
		gizmos.line(t10, t11)
		gizmos.line(t11, t01)
		gizmos.line(t01, t00)
		gizmos.line(c00, t00)
		gizmos.line(c10, t10)
		gizmos.line(c11, t11)
		gizmos.line(c01, t01)

		// Draw X-Ray diagonal cross on cut faces when Boolean Subtracting so the cutout is unmistakable!
		if _ed.brush_op == .Subtract {
			gizmos.with_color({1.0, 0.20, 0.18, 0.85})
			gizmos.line(t00, t11)
			gizmos.line(t10, t01)
			gizmos.line(c00, t11)
		}
	}

	u_name, _ := _world_axis_info(u)
	v_name, _ := _world_axis_info(v)
	_draw_3d_tracked_pill((c00 + c10) * 0.5, fmt.tprintf("%s: %.2f m", u_name, w_u), {1.0, 0.48, 0.48, 1.0})
	_draw_3d_tracked_pill((c10 + c11) * 0.5, fmt.tprintf("%s: %.2f m", v_name, d_v), {0.48, 0.78, 1.0, 1.0})
	_draw_3d_tracked_pill((c00 + c11) * 0.5, fmt.tprintf("Diag: %.2f m", diag), {1.0, 0.86, 0.35, 1.0})

	if _ed.draft_stage == .Extruding_Height {
		op_tag := "+ADD" if _ed.brush_op == .Add else "-CUT HOLE"
		mid_h := c11 + n * (h_n * 0.5)
		_draw_3d_tracked_pill(mid_h, fmt.tprintf("%s  H: %.2f m (Click/Enter)", op_tag, h_n), {0.35, 1.0, 0.55, 1.0} if _ed.brush_op == .Add else {1.0, 0.42, 0.38, 1.0})
	}

	if _ed.num_len > 0 {
		num_str := string(_ed.num_buf[:_ed.num_len])
		_draw_3d_tracked_pill(c00 + n * (h_n + 0.4), fmt.tprintf("Typed: %s_ (Enter)", num_str), {1.0, 0.65, 1.0, 1.0})
	}
}

// ============================================================================
// TOOL 3: BLENDER-STYLE FACE EXTRUDE / INTRUDE + AXIS SELECTION (`Normal`, `X`, `Y`, `Z`, `Free`)
// Works on BOTH Polygon Meshes (`Editable_Poly_Mesh` / `MeshFilter`) AND `CSGVolume` Brushes!
// ============================================================================

@(private = "package")
_update_and_draw_face_push_pull :: proc(
	ray:         engine.Ray,
	hit_mesh:    bool,
	hit_pos:     [3]f32,
	hit_norm:    [3]f32,
	hit_vol:     ^cad_csg.CSGVolume,
	hit_b_idx:   int,
	lmb_clicked: bool,
	lmb_down:    bool,
) {
	// Allow typing an exact extrude/intrude distance while dragging or after selecting a face!
	if _ed.push_active {
		if _poll_numeric_keyboard_input() {
			return
		}
	}

	if !_ed.push_active {
		// 1. First check if the cursor ray hits a Polygon Mesh (`MeshFilter` / `Editable_Poly_Mesh`) face!
		if poly_tH, poly_fi, poly_t, poly_hit_p, poly_norm, poly_ok := _raycast_scene_poly_mesh_for_extrude(ray); poly_ok && (!hit_mesh || poly_t <= linalg.length(hit_pos - ray.origin) + 0.02) {
			tw_poly := engine.transform_world(poly_tH)
			origin := tw_poly.position
			ax_dir, ax_lbl, ax_col := _resolve_extrude_axis_dir(poly_norm)

			gizmos.in_world_space()
			gizmos.with_depth_test(false)

			// Draw highlighted polygon face ring + extrusion axis guide line
			if poly_fi >= 0 && poly_fi < len(_mesh_ed.faces) {
				pf := _mesh_ed.faces[poly_fi]
				m := len(pf.verts)
				gizmos.with_color({1.0, 0.85, 0.18, 0.98})
				for i in 0 ..< m {
					va := origin + _mesh_ed.verts[pf.verts[i]]
					vb := origin + _mesh_ed.verts[pf.verts[(i + 1) % m]]
					gizmos.line(va, vb)
				}
			}
			gizmos.with_color(ax_col)
			gizmos.line(poly_hit_p - ax_dir * 4.0, poly_hit_p + ax_dir * 4.0)
			gizmos.wire_circle(poly_hit_p, poly_norm, 0.28, 20)
			gizmos.solid_sphere(poly_hit_p + ax_dir * 0.65, 0.08)

			_draw_3d_tracked_pill(
				poly_hit_p + poly_norm * 0.85,
				fmt.tprintf("Mesh Face #%d: Extrude (+Out) / Intrude (-In) | Axis: %s [Keys: N/X/Y/Z/G] | Inset: %.0f%%", poly_fi, ax_lbl, _ed.extrude_inset_margin * 100.0),
				ax_col,
			)

			if lmb_clicked {
				handles.claim_mouse(true)
				_begin_poly_face_interactive_extrude(poly_tH, poly_fi, poly_hit_p, poly_norm, ax_dir, ray)
			}
			return
		}

		// 2. Otherwise check if the cursor ray hits ANY `CSGVolume` Face (authored `brushes`, converted `runtime_hulls`, or compiled `chunks`)!
		if hit_mesh && hit_vol != nil {
			b_idx := hit_b_idx
			tw_hit := engine.transform_world(engine.Transform_Handle(hit_vol.owner))
			rot_q := engine.quat_to_native(tw_hit.rotation)
			inv_rot := linalg.quaternion_inverse(rot_q)
			local_p := linalg.quaternion128_mul_vector3(inv_rot, hit_pos - tw_hit.position)
			local_n := linalg.normalize0(linalg.quaternion128_mul_vector3(inv_rot, hit_norm))

			if (b_idx < 0 || b_idx >= len(hit_vol.brushes)) && len(hit_vol.brushes) > 0 {
				best_d := max(f32)
				for candidate, ci in hit_vol.brushes {
					d := linalg.length2(local_p - candidate.center)
					if d < best_d {
						best_d = d
						b_idx = ci
					}
				}
			}

			// Extract the exact 3D polygon (`CSG_Face_Poly`) of the hovered face on this CSGVolume!
			face_verts, face_n_loc, face_c_loc, face_col, rt_hi, rt_pi, face_ok := _extract_hovered_csg_face_poly(hit_vol, b_idx, local_p, local_n)
			ax_dir, ax_lbl, ax_col := _resolve_extrude_axis_dir(hit_norm)

			gizmos.in_world_space()
			gizmos.with_depth_test(false)
			gizmos.with_color({1.0, 0.85, 0.18, 0.98})

			// Draw the exact polygon outline of the hovered face (or a fallback quad if not extracted)
			if face_ok && len(face_verts) >= 3 {
				m := len(face_verts)
				for i in 0 ..< m {
					va := tw_hit.position + linalg.quaternion128_mul_vector3(rot_q, face_verts[i])
					vb := tw_hit.position + linalg.quaternion128_mul_vector3(rot_q, face_verts[(i + 1) % m])
					gizmos.line(va, vb)
				}
			} else {
				ft_u, ft_v := cad_csg.plane_tangent_basis(hit_norm)
				q_half: f32 = 0.45
				gizmos.line(hit_pos - ft_u * q_half - ft_v * q_half, hit_pos + ft_u * q_half - ft_v * q_half)
				gizmos.line(hit_pos + ft_u * q_half - ft_v * q_half, hit_pos + ft_u * q_half + ft_v * q_half)
				gizmos.line(hit_pos + ft_u * q_half + ft_v * q_half, hit_pos - ft_u * q_half + ft_v * q_half)
				gizmos.line(hit_pos - ft_u * q_half + ft_v * q_half, hit_pos - ft_u * q_half - ft_v * q_half)
			}
			gizmos.wire_circle(hit_pos, hit_norm, 0.30, 20)

			gizmos.with_color(ax_col)
			gizmos.line(hit_pos - ax_dir * 4.0, hit_pos + ax_dir * 4.0)
			gizmos.solid_sphere(hit_pos + ax_dir * 0.70, 0.08)

			has_brush := (b_idx >= 0 && b_idx < len(hit_vol.brushes))
			yaw_deg: f32 = hit_vol.brushes[b_idx].yaw_deg if has_brush else 0.0
			rad := math.to_radians(yaw_deg)
			cos_y := math.cos(rad)
			sin_y := math.sin(rad)
			bn := [3]f32{
				local_n.x * cos_y - local_n.z * sin_y,
				local_n.y,
				local_n.x * sin_y + local_n.z * cos_y,
			}
			ax := 0
			an := [3]f32{abs(bn.x), abs(bn.y), abs(bn.z)}
			if an.y >= an.x && an.y >= an.z {
				ax = 1
			} else if an.z >= an.x && an.z >= an.y {
				ax = 2
			}
			sgn: f32 = 1.0 if bn[ax] >= 0 else -1.0

			axis_local_vec := [3]f32{0, 0, 0}
			axis_local_vec[ax] = sgn
			rot_local_n := [3]f32{
				axis_local_vec.x * cos_y + axis_local_vec.z * sin_y,
				axis_local_vec.y,
				-axis_local_vec.x * sin_y + axis_local_vec.z * cos_y,
			}

			plane_names := [3][2]string{{"-X", "+X"}, {"-Y", "+Y"}, {"-Z", "+Z"}}
			face_tag := plane_names[ax][1 if sgn > 0 else 0]
			target_name := "CSG Hull"
			if has_brush {
				b := hit_vol.brushes[b_idx]
				target_name = b.name
				if b.primitive == .Profile_2D {
					face_tag = "Cap" if abs(linalg.dot(local_n, b.plane_normal)) > 0.65 else "Side Wall"
				}
			}
			mode_tag := "Extrude Face (+Out) / Intrude Pocket (-In)" if _ed.extrude_csg_behavior == .Extrude_Intrude_Segment else "Move Face Plane"
			_draw_3d_tracked_pill(
				hit_pos + hit_norm * 0.85,
				fmt.tprintf("%s: %s [%s] | Axis: %s [N/X/Y/Z/G, Tab=Mode]", mode_tag, target_name, face_tag, ax_lbl),
				ax_col,
			)

			if lmb_clicked {
				handles.claim_mouse(true)
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				defer context.allocator = prev_alloc

				csg_history_ensure_baseline(hit_vol)
				_ed.push_active            = true
				_ed.push_is_poly_mesh      = false
				_ed.push_vol               = hit_vol
				_ed.push_brush_idx         = b_idx if has_brush else -1
				_ed.push_spawned_brush_idx = -1
				_ed.push_hull_idx          = rt_hi
				_ed.push_plane_idx         = rt_pi
				_ed.push_world_origin      = hit_pos
				_ed.push_world_normal      = linalg.normalize0(hit_norm)
				_ed.push_drag_axis_world   = ax_dir
				_ed.push_start_s           = _ray_closest_dist_along_axis(ray, _ed.push_world_origin, _ed.push_drag_axis_world)
				_ed.push_current_delta     = 0
				_ed.push_face_color        = face_col

				if rt_hi >= 0 && rt_hi < len(hit_vol.runtime_hulls) && rt_pi >= 0 && rt_pi < len(hit_vol.runtime_hulls[rt_hi].planes) {
					_ed.push_orig_plane_dist = hit_vol.runtime_hulls[rt_hi].planes[rt_pi].dist
				}

				// Store the exact 2D polygon profile of the clicked face for true face-only Extrude / Intrude!
				clear(&_ed.push_face_profile)
				if face_ok && len(face_verts) >= 3 {
					fn_use := linalg.normalize0(face_n_loc)
					fu, fv := cad_csg.plane_tangent_basis(fn_use)
					_ed.push_local_normal      = fn_use
					_ed.push_face_u            = fu
					_ed.push_face_v            = fv
					_ed.push_face_center_local = face_c_loc
					for v in face_verts {
						rel := v - face_c_loc
						append(&_ed.push_face_profile, cad_csg.CSG_Profile_Point{
							uv      = {linalg.dot(rel, fu), linalg.dot(rel, fv)},
							smooth  = false,
							tension = 0.25,
						})
					}
				} else {
					fn_use := linalg.normalize0(local_n)
					fu, fv := cad_csg.plane_tangent_basis(fn_use)
					_ed.push_local_normal      = fn_use
					_ed.push_face_u            = fu
					_ed.push_face_v            = fv
					_ed.push_face_center_local = local_p
					for corner in ([4][2]f32{{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}}) {
						append(&_ed.push_face_profile, cad_csg.CSG_Profile_Point{uv = corner})
					}
				}

				if has_brush {
					b := hit_vol.brushes[b_idx]
					_ed.push_orig_center = b.center
					_ed.push_orig_size   = b.size
					_ed.push_orig_height = b.extrude_height
					if b.primitive == .Profile_2D {
						cap_dot := linalg.dot(local_n, b.plane_normal)
						if abs(cap_dot) > 0.65 {
							_ed.push_face_axis = 3
							_ed.push_face_sign = 1.0 if cap_dot >= 0 else -1.0
						} else {
							_ed.push_face_axis = 4
							_ed.push_face_sign = 1.0
							_ed.push_wall_dir_2d = linalg.normalize0([2]f32{
								linalg.dot(local_n, b.plane_u),
								linalg.dot(local_n, b.plane_v),
							})
							clear(&_ed.push_orig_profile)
							append(&_ed.push_orig_profile, ..b.profile_points[:])
						}
					} else {
						_ed.push_face_axis = ax
						_ed.push_face_sign = sgn
						if !face_ok {
							_ed.push_local_normal = linalg.normalize0(rot_local_n)
						}
					}
				}

				_ed.selected_brush_idx = b_idx
				_ed.num_len            = 0
				engine.inspector_request_select(engine.Transform_Handle(hit_vol.owner))
			}
		}
	} else {
		handles.claim_mouse(true)
		// Allow live switching of Extrusion Axis (`N`/`X`/`Y`/`Z`/`G`) even mid-drag!
		ax_dir, ax_lbl, ax_col := _resolve_extrude_axis_dir(_ed.push_world_normal)
		if ax_dir != _ed.push_drag_axis_world {
			_ed.push_drag_axis_world = ax_dir
			_ed.push_start_s = _ray_closest_dist_along_axis(ray, _ed.push_world_origin, _ed.push_drag_axis_world) - _ed.push_current_delta
		}

		cur_s := _ray_closest_dist_along_axis(ray, _ed.push_world_origin, _ed.push_drag_axis_world)
		raw_d := cur_s - _ed.push_start_s
		delta := _snap_scalar(raw_d, _ed.snap_step)

		// Compute free-cursor 3D offset if in `.Free_Cursor` mode
		free_off := [3]f32{0, 0, 0}
		if _ed.extrude_axis_mode == .Free_Cursor {
			f := handles.frame()
			cam_fwd := [3]f32{-f.view.view[2, 0], -f.view.view[2, 1], -f.view.view[2, 2]}
			denom := linalg.dot(ray.direction, cam_fwd)
			if abs(denom) > 1e-4 {
				t_p := linalg.dot(_ed.push_world_origin - ray.origin, cam_fwd) / denom
				free_off = (ray.origin + ray.direction * t_p) - _ed.push_world_origin
			}
		}

		_apply_face_push_pull_delta(delta, free_off)

		cur_face_pt := _ed.push_world_origin + (_ed.push_drag_axis_world * delta if _ed.extrude_axis_mode != .Free_Cursor else free_off)
		gizmos.in_world_space()
		gizmos.with_depth_test(false)
		gizmos.with_color(ax_col)
		gizmos.line(_ed.push_world_origin - _ed.push_drag_axis_world * 5.0, _ed.push_world_origin + _ed.push_drag_axis_world * 5.0)
		gizmos.line(_ed.push_world_origin, cur_face_pt)
		gizmos.solid_sphere(cur_face_pt, 0.11)

		action_str := "EXTRUDE (+Out)" if delta >= 0 else "INTRUDE (-In)"
		lbl := fmt.tprintf("%s: %+.2f m | Axis: %s [N/X/Y/Z/G] (Type value + Enter or Release)", action_str, delta, ax_lbl)
		_draw_3d_tracked_pill(cur_face_pt + _ed.push_world_normal * 0.35, lbl, ax_col)

		if !lmb_down {
			_ed.push_active = false
			if _ed.push_is_poly_mesh {
				_finish_poly_face_interactive_extrude(_ed.push_current_delta)
			} else if _ed.push_vol != nil {
				csg_history_commit(_ed.push_vol)
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
}

// ============================================================================
// TOOL 4: RED FACTION GEO-MOD BLAST TESTER
// ============================================================================

@(private = "package")
_update_and_draw_blast_tool :: proc(
	mp:          [2]f32,
	hit_mesh:    bool,
	hit_pos:     [3]f32,
	hit_norm:    [3]f32,
	wp_ok:       bool,
	wp_pt:       [3]f32,
	lmb_clicked: bool,
) {
	_ = mp
	if !hit_mesh && !wp_ok do return
	target := hit_pos if hit_mesh else wp_pt
	norm   := hit_norm if hit_mesh else _ed.plane.normal

	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	gizmos.with_color({1.0, 0.32, 0.14, 0.90})
	gizmos.wire_sphere(target, _ed.blast_radius)
	gizmos.wire_circle(target, norm, _ed.blast_radius * 0.65, 24)

	_draw_3d_tracked_pill(target + norm * (_ed.blast_radius + 0.2), fmt.tprintf("Geo-Mod Blast R: %.2f m (Click / B | [ ] Adjust Radius)", _ed.blast_radius), {1.0, 0.45, 0.30, 1.0})

	if lmb_clicked {
		handles.claim_mouse(true)
		cad_csg.csg_trigger_blast(target, _ed.blast_radius, _ed.blast_impulse, _ed.tool_cut_material_guid, tool_cut_albedo_u8())
	}
}

// ============================================================================
// TOOL 5: SABRECSG / REALTIMECSG 2-POINT CSG CLIP PLANE SLICER
// (Perspective-Exact Camera-Ray Knife Plane + Live 3D Cross-Section Contour!)
// ============================================================================

// Computes and draws the exact 3D polygon cross-section loops where the cutting plane `(world_pt, world_n)`
// intersects every convex hull of `vol`, so the user sees the exact laser cut wrapping around the 3D mesh!
@(private = "package")
_draw_clip_plane_mesh_contour :: proc(vol: ^cad_csg.CSGVolume, world_pt, world_n: [3]f32) -> (hit_hull_count: int) {
	if vol == nil || linalg.length2(world_n) < 0.25 do return 0
	if !vol.compiled {
		cad_csg.csg_volume_rebuild(vol)
	}

	tw := engine.transform_world(engine.Transform_Handle(vol.owner))
	rot_q := engine.quat_to_native(tw.rotation)
	inv_rot := linalg.quaternion_inverse(rot_q)
	local_pt := linalg.quaternion128_mul_vector3(inv_rot, world_pt - tw.position)
	local_n  := linalg.normalize0(linalg.quaternion128_mul_vector3(inv_rot, world_n))
	local_d  := linalg.dot(local_n, local_pt)

	u_ax, v_ax := cad_csg.plane_tangent_basis(local_n)
	origin := local_n * local_d
	EXT :: f32(256.0)

	buf_a := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	buf_b := make([dynamic][3]f32, 0, 32, context.temp_allocator)

	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	gizmos.with_color({0.10, 1.0, 0.92, 1.0}) // Bright Laser Cyan cross-section contour

	for _, ch in vol.chunks {
		if ch == nil do continue
		for pass in 0 ..< 2 {
			hulls := ch.destructible_hulls[:] if pass == 0 else ch.indestructible_hulls[:]
			for h in hulls {
				// Quick AABB vs plane check
				c_box := (h.aabb_min + h.aabb_max) * 0.5
				e_box := (h.aabb_max - h.aabb_min) * 0.5
				r_eff := abs(local_n.x) * e_box.x + abs(local_n.y) * e_box.y + abs(local_n.z) * e_box.z
				if abs(linalg.dot(local_n, c_box) - local_d) > r_eff + 0.01 do continue

				clear(&buf_a)
				append(&buf_a, origin - u_ax * EXT - v_ax * EXT)
				append(&buf_a, origin + u_ax * EXT - v_ax * EXT)
				append(&buf_a, origin + u_ax * EXT + v_ax * EXT)
				append(&buf_a, origin - u_ax * EXT + v_ax * EXT)

				for p in h.planes {
					cad_csg.clip_polygon_by_plane(buf_a[:], p, &buf_b)
					buf_a, buf_b = buf_b, buf_a
					if len(buf_a) < 3 do break
				}

				if len(buf_a) >= 3 && cad_csg.polygon_area(buf_a[:]) > 1e-4 {
					hit_hull_count += 1
					m := len(buf_a)
					for i in 0 ..< m {
						va := tw.position + linalg.quaternion128_mul_vector3(rot_q, buf_a[i]) * tw.scale
						vb := tw.position + linalg.quaternion128_mul_vector3(rot_q, buf_a[(i + 1) % m]) * tw.scale
						gizmos.line(va, vb)
					}
				}
			}
		}
	}
	return hit_hull_count
}

@(private = "package")
_update_and_draw_clip_plane_tool :: proc(
	hit_mesh:    bool,
	hit_pos:     [3]f32,
	hit_norm:    [3]f32,
	hit_vol:     ^cad_csg.CSGVolume,
	wp_ok:       bool,
	wp_pt:       [3]f32,
	lmb_clicked: bool,
	rmb_clicked: bool,
) {
	if rmb_clicked && _ed.clip_has_pt_a {
		_ed.clip_has_pt_a = false
		return
	}
	if !hit_mesh && !wp_ok && !_ed.clip_has_pt_a do return

	f := handles.frame()
	v := f.view
	cam_right := [3]f32{v.view[0, 0], v.view[0, 1], v.view[0, 2]}
	cam_up    := [3]f32{v.view[1, 0], v.view[1, 1], v.view[1, 2]}
	cam_fwd   := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
	is_ortho  := abs(v.proj[3, 3]) > 0.5

	raw_pt := hit_pos if hit_mesh else wp_pt
	// Use exact surface hit point by default so perspective never jumps off the cursor;
	// hold Ctrl to snap Point A / Point B to the metric grid step!
	ctrl_snap := im.GetIO().KeyCtrl
	snapped_pt := raw_pt
	if ctrl_snap || (!hit_mesh && wp_ok) {
		step := _ed.snap_step if ctrl_snap else max(_ed.snap_step * 0.25, 0.05)
		snapped_pt = {
			_snap_scalar(raw_pt.x, step),
			_snap_scalar(raw_pt.y, step),
			_snap_scalar(raw_pt.z, step),
		}
	}

	surf_n := hit_norm if (hit_mesh && linalg.length2(hit_norm) > 0.25) else _ed.plane.normal

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	mode_names := [3]string{"Split Both Halves", "Keep Back (-N)", "Keep Front (+N)"}
	m_str := mode_names[clamp(int(_ed.clip_mode), 0, 2)]
	ax_c := active_axis_constraint()

	if !_ed.clip_has_pt_a {
		gizmos.with_color({0.20, 1.0, 0.92, 0.98})
		gizmos.solid_sphere(snapped_pt, 0.07)
		gizmos.wire_circle(snapped_pt, surf_n, 0.24, 20)

		// If the user locked X, Y, or Z axis, preview the exact axis-locked slice contour even before clicking!
		if ax_c != .Free {
			ax_n := [3]f32{1, 0, 0} if ax_c == .X else ([3]f32{0, 1, 0} if ax_c == .Y else [3]f32{0, 0, 1})
			vol_prev := hit_vol if hit_vol != nil else _ed.clip_vol
			if vol_prev == nil do vol_prev, _ = _resolve_active_volume(false)
			_draw_clip_plane_mesh_contour(vol_prev, snapped_pt, ax_n)
		}

		ax_hint := "View Knife (Perspective-Exact)" if ax_c == .Free else ("Locked X Plane" if ax_c == .X else ("Locked Y Plane" if ax_c == .Y else "Locked Z Plane"))
		_draw_3d_tracked_pill(
			snapped_pt + surf_n * 0.38,
			fmt.tprintf("CSG Clip [%s | %s]: Click Point A (X/Y/Z=Axis Plane, Tab=Mode)", m_str, ax_hint),
			{0.35, 0.95, 1.0, 1.0},
		)
		if lmb_clicked && (hit_mesh || wp_ok) {
			handles.claim_mouse(true)
			vol_target := hit_vol
			if vol_target == nil {
				vol_target, _ = _resolve_active_volume(false)
			}
			_ed.clip_vol          = vol_target
			_ed.clip_pt_a         = snapped_pt
			_ed.clip_pt_b         = snapped_pt
			_ed.clip_surface_norm = surf_n
			_ed.clip_has_pt_a     = true
		}
		return
	}

	// Point A is placed: project the current mouse ray (`f.ray`) onto the camera-aligned plane at `pt_a`
	// so the cut line is 100% free of depth/perspective distortion!
	pt_a := _ed.clip_pt_a
	denom_v := linalg.dot(f.ray.direction, cam_fwd)
	pt_b_view := snapped_pt
	if abs(denom_v) > 1e-4 {
		t_v := linalg.dot(pt_a - f.ray.origin, cam_fwd) / denom_v
		if t_v > 0.01 {
			pt_b_view = f.ray.origin + f.ray.direction * t_v
		}
	}

	// Compute 2D screen-plane offset `(dx, dy)` from Point A to the cursor
	rel_v := pt_b_view - pt_a
	dx := linalg.dot(rel_v, cam_right)
	dy := linalg.dot(rel_v, cam_up)
	dist_2d := math.sqrt(dx * dx + dy * dy)
	ang_deg := math.to_degrees(math.atan2(dy, dx))

	// Snap screen angle when Shift is held (15° increments) OR magnetically snap to 0°/45°/90° within 6° when Axis Snap is enabled!
	shift_held := f.input.shift || input.key_down(.LSHIFT) || input.key_down(.RSHIFT)
	snapped_angle := false
	if dist_2d > 0.02 {
		if shift_held {
			ang_deg = math.round(ang_deg / 15.0) * 15.0
			snapped_angle = true
		} else if _ed.axis_snap_enabled {
			nearest_45 := math.round(ang_deg / 45.0) * 45.0
			if abs(ang_deg - nearest_45) <= 6.0 {
				ang_deg = nearest_45
				snapped_angle = true
			}
		}
		if snapped_angle {
			rad := math.to_radians(ang_deg)
			dx = math.cos(rad) * dist_2d
			dy = math.sin(rad) * dist_2d
			pt_b_view = pt_a + cam_right * dx + cam_up * dy
		}
	}
	_ed.clip_pt_b = pt_b_view

	// Determine the exact 3D cutting plane normal `plane_n`:
	// - If World X/Y/Z Axis Lock is active, lock the plane normal to that exact world axis!
	// - Otherwise, construct the exact Camera-Ray Knife Plane passing through the Camera Eye, `pt_a`, and `pt_b_view`
	//   so the cutting plane projects to a razor-straight line between Point A and Point B on screen!
	sight_dir := cam_fwd if is_ortho else linalg.normalize0(pt_a - v.cam_pos)
	cut_tan   := linalg.normalize0(pt_b_view - pt_a)
	plane_n: [3]f32
	if ax_c == .X {
		plane_n = {1, 0, 0}
		cut_tan = {0, 0, 1} if abs(cam_fwd.y) > 0.7 else {0, 1, 0}
	} else if ax_c == .Y {
		plane_n = {0, 1, 0}
		cut_tan = {1, 0, 0}
	} else if ax_c == .Z {
		plane_n = {0, 0, 1}
		cut_tan = {1, 0, 0} if abs(cam_fwd.y) > 0.7 else {0, 1, 0}
	} else if linalg.length2(cut_tan) > 1e-4 {
		plane_n = linalg.normalize0(linalg.cross(cut_tan, sight_dir))
	} else {
		plane_n = cam_right
		cut_tan = cam_up
	}

	// Draw the live 3D cross-section contour ring directly on the CSGVolume's surfaces!
	vol := _ed.clip_vol
	if vol == nil {
		vol, _ = _resolve_active_volume(false)
	}
	sliced_preview_n := _draw_clip_plane_mesh_contour(vol, pt_a, plane_n)

	// Draw the screen-aligned Knife Line from Point A to Point B + extended guide line
	gizmos.with_color({0.20, 1.0, 0.48, 1.0})
	gizmos.solid_sphere(pt_a, 0.08)
	gizmos.with_color({1.0, 0.88, 0.20, 1.0})
	gizmos.solid_sphere(pt_b_view, 0.08)
	gizmos.line(pt_a, pt_b_view)

	gizmos.with_color({0.25, 0.95, 1.0, 0.55})
	gizmos.line(pt_a - cut_tan * 8.0, pt_b_view + cut_tan * 8.0)

	// Draw +Normal arrow at the midpoint so Keep Front (+N) vs Keep Back (-N) is unmistakable
	mid := (pt_a + pt_b_view) * 0.5
	gizmos.with_color({1.0, 0.40, 0.26, 0.98})
	gizmos.line(mid, mid + plane_n * 0.85)
	gizmos.solid_sphere(mid + plane_n * 0.85, 0.06)

	snap_tag := fmt.tprintf("Angle: %.0f° (Snapped)", ang_deg) if snapped_angle else fmt.tprintf("Angle: %.1f° (Shift=15° Snap)", ang_deg)
	if ax_c != .Free {
		snap_tag = "Locked World X Plane" if ax_c == .X else ("Locked World Y Plane" if ax_c == .Y else "Locked World Z Plane")
	}
	_draw_3d_tracked_pill(
		mid + cam_up * 0.42,
		fmt.tprintf("Knife Cut [%s] | %s | Hits %d hull(s) | Click or Enter to Slice! (Tab=Mode, RMB=Cancel)", m_str, snap_tag, sliced_preview_n),
		{0.25, 1.0, 0.92, 1.0} if sliced_preview_n > 0 else {1.0, 0.78, 0.28, 1.0},
	)

	commit := (lmb_clicked && (dist_2d >= 0.03 || ax_c != .Free)) ||
	          _key_just_pressed(.RETURN, .Enter) ||
	          _key_just_pressed(.KP_ENTER, .KeypadEnter)
	if commit {
		handles.claim_mouse(true)
		if vol == nil {
			sel_h := engine.inspector_active_selection()
			if sel_h != {} {
				_, mf_sel := engine.transform_get_comp(sel_h, engine.MeshFilter)
				if mf_sel != nil {
					_sync_mesh_editor_with_selection()
					conv_h := convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
					if conv_h != {} {
						_, vol = engine.transform_get_comp(conv_h, cad_csg.CSGVolume)
					}
				}
			}
		}
		w := engine.ctx_world()
		target_owners := make([dynamic]engine.Transform_Handle, 0, 8, context.temp_allocator)
		if vol != nil && vol.owner != {} {
			append(&target_owners, engine.Transform_Handle(vol.owner))
		}

		// Also include any sibling CSGVolume pieces or bone-attached Ghoul CSG volumes straddled by the knife stroke `pt_a .. pt_b_view`
		// so multi-angle slashing across already-split halves or across a skeletal rig slices all straddled pieces cleanly!
		if w != nil {
			k_min   := linalg.min(pt_a, pt_b_view) - [3]f32{0.6, 0.6, 0.6}
			k_max   := linalg.max(pt_a, pt_b_view) + [3]f32{0.6, 0.6, 0.6}
			world_d := linalg.dot(plane_n, pt_a)
			v_it := engine.pool_iterator(cad_csg.csg_volumes(w))
			for cand_v, _ in engine.pool_next(&v_it) {
				if !cand_v.enabled do continue
				cand_h := engine.Transform_Handle(cand_v.owner)
				already := false
				for th in target_owners do if th == cand_h { already = true; break }
				if already do continue
				lo, hi, aok := cad_csg.csg_volume_local_aabb(cand_v)
				if !aok do continue
				ctw := engine.transform_world(cand_h)
				c_mat := engine.trs_matrix(ctw.position, ctw.rotation, ctw.scale)
				w_min := [3]f32{ 1e30,  1e30,  1e30}
				w_max := [3]f32{-1e30, -1e30, -1e30}
				min_p: f32 =  1e30
				max_p: f32 = -1e30
				for cx in 0 ..< 2 {
					for cy in 0 ..< 2 {
						for cz in 0 ..< 2 {
							lc := [3]f32{
								lo.x if cx == 0 else hi.x,
								lo.y if cy == 0 else hi.y,
								lo.z if cz == 0 else hi.z,
							}
							wc := (c_mat * [4]f32{lc.x, lc.y, lc.z, 1.0}).xyz
							w_min = linalg.min(w_min, wc)
							w_max = linalg.max(w_max, wc)
							sd := linalg.dot(plane_n, wc) - world_d
							min_p = min(min_p, sd)
							max_p = max(max_p, sd)
						}
					}
				}
				if !cad_csg.aabb_overlaps(w_min, w_max, k_min, k_max, 0.25) do continue
				// Fast O(1) Plane-Straddle Filter: skip sibling volumes that do not actually cross the cutting plane!
				if _ed.clip_mode == .Split_Both && (min_p >= -0.002 || max_p <= 0.002) do continue
				if _ed.clip_mode == .Keep_Back  && max_p <= 0.002 do continue
				if _ed.clip_mode == .Keep_Front && min_p >= -0.002 do continue
				append(&target_owners, cand_h)
			}
		}

		if len(target_owners) > 0 {
			immediate_budget := 3
			for t_owner, idx in target_owners {
				if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(t_owner)) do continue
				_, cur_v := engine.transform_get_comp(t_owner, cad_csg.CSGVolume)
				if cur_v == nil || !cur_v.enabled do continue

				// Bone-attached Ghoul CSG volumes and the first 3 pieces slice immediately;
				// any additional rubble pieces in a large pile queue into `_pending_slice_queue` (3 per frame) so slicing never freezes!
				cut_alb := tool_cut_albedo_u8()
				if !cur_v.is_ghoul_bone_csg && immediate_budget <= 0 {
					append(&_pending_slice_queue, Pending_Slice_Op{
						owner        = t_owner,
						world_pt     = pt_a,
						world_normal = plane_n,
						mode         = _ed.clip_mode,
						split_gap    = _ed.clip_split_gap,
						cut_mat_guid = _ed.tool_cut_material_guid,
						cut_albedo   = cut_alb,
					})
					continue
				}

				if idx == 0 {
					csg_history_ensure_baseline(cur_v)
				}
				tw := engine.transform_world(t_owner)
				m_t := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
				inv_m := linalg.inverse(m_t)
				local_pt := (inv_m * [4]f32{pt_a.x, pt_a.y, pt_a.z, 1.0}).xyz
				local_n  := linalg.normalize0((linalg.transpose(m_t) * [4]f32{plane_n.x, plane_n.y, plane_n.z, 0.0}).xyz)
				local_d  := linalg.dot(local_n, local_pt)
				if cad_csg.csg_volume_clip_by_plane(cur_v, local_n, local_d, _ed.clip_mode, _ed.clip_split_gap, _ed.tool_cut_material_guid, cut_alb) > 0 {
					if !cur_v.is_ghoul_bone_csg {
						immediate_budget -= 1
					}
				}
				if idx == 0 {
					_, vol_after := engine.transform_get_comp(t_owner, cad_csg.CSGVolume)
					if vol_after != nil {
						csg_history_commit(vol_after)
					}
				}
			}
			_ed.selected_brush_idx = -1
		}
		_ed.clip_has_pt_a = false
	}
}

// ============================================================================
// TOOL 6: SOFT DEFORMER BODY BRUSH (WORKS ON MESH, CSG VOLUME & FAKER CSG + COLLISION!)
// (Deforms visual vertices AND updates Jolt CSG/Mesh collision! RMB rotates camera normally and NEVER resets!)
// ============================================================================

@(private = "package")
_update_and_draw_soft_deform_brush_tool :: proc(
	hit_mesh:    bool,
	hit_pos:     [3]f32,
	hit_norm:    [3]f32,
	hit_vol:     ^cad_csg.CSGVolume,
	wp_ok:       bool,
	wp_pt:       [3]f32,
	lmb_clicked: bool,
	rmb_clicked: bool,
) {
	_ = rmb_clicked // Right-click is reserved for camera rotation — NEVER reset deformations on RMB!

	// Also raycast against the active `Editable_Poly_Mesh` so Soft Deform works seamlessly on `[POLY MESH]` objects too!
	f := handles.frame()
	poly_hit := false
	poly_pos:  [3]f32
	poly_norm: [3]f32
	poly_t:    f32 = max(f32)
	if f.valid {
		poly_pos, poly_norm, poly_t, poly_hit = raycast_editable_poly_mesh_world(f.ray)
	}

	use_poly := false
	if poly_hit {
		if !hit_mesh {
			use_poly = true
		} else if f.valid {
			csg_t := linalg.length(hit_pos - f.ray.origin)
			if poly_t <= csg_t + 0.02 {
				use_poly = true
			}
		}
	}

	if !hit_mesh && !poly_hit && !wp_ok do return
	target := poly_pos if use_poly else (hit_pos if hit_mesh else wp_pt)
	norm   := poly_norm if use_poly else (hit_norm if (hit_mesh && linalg.length2(hit_norm) > 0.25) else _ed.plane.normal)

	vol := hit_vol if !use_poly else nil
	if vol == nil && !use_poly {
		vol, _ = _resolve_active_volume(false)
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	mode_names := [4]string{"Dent Inward (-N)", "Bulge Outward (+N)", "Shockwave Ripple (Wave)", "Twist Shear (Vortex)"}
	m_str := mode_names[clamp(int(_ed.deform_mode), 0, 3)]

	// Draw Soft Deformer field radius sphere + directional displacement preview arrow
	gizmos.with_color({0.95, 0.35, 1.0, 0.92})
	gizmos.wire_sphere(target, _ed.deform_radius)
	gizmos.wire_circle(target, norm, _ed.deform_radius * 0.55, 24)

	disp_dir := -norm if _ed.deform_mode == .Dent_Inward else norm
	gizmos.with_color({0.25, 1.0, 0.85, 1.0})
	gizmos.line(target, target + disp_dir * _ed.deform_amplitude)
	gizmos.solid_sphere(target + disp_dir * _ed.deform_amplitude, 0.08)

	target_kind_info := " | Target: [POLY MESH]"
	if vol != nil {
		mat_row := cad_csg.csg_get_material_properties(vol.material_preset)
		kind_tag := "[FAKER CSG]" if vol.is_faker_mesh else "[CSG VOLUME]"
		target_kind_info = fmt.tprintf(" | %s Mat: %s", kind_tag, mat_row.name)
	}
	_draw_3d_tracked_pill(
		target + norm * (_ed.deform_radius + 0.25),
		fmt.tprintf("Soft Deformer [%s] R:%.2fm Amp:%.2fm%s (LMB=Deform+Collider, Tab=Mode, Ctrl+Z=Undo)", m_str, _ed.deform_radius, _ed.deform_amplitude, target_kind_info),
		{0.95, 0.55, 1.0, 1.0},
	)

	if lmb_clicked {
		if use_poly || (vol == nil && len(_mesh_ed.verts) > 0 && _mesh_ed.target_owner != {}) {
			handles.claim_mouse(true)
			_ = apply_soft_deform_to_editable_poly_mesh(
				target,
				norm,
				_ed.deform_radius,
				_ed.deform_amplitude,
				_ed.deform_mode,
			)
		} else if vol != nil {
			handles.claim_mouse(true)
			vol_owner := engine.Transform_Handle(vol.owner)
			csg_history_ensure_baseline(vol)
			vol.soft_deform_enabled = true
			_ = cad_csg.csg_apply_soft_deform_impulse(
				target,
				norm,
				_ed.deform_radius,
				_ed.deform_amplitude,
				_ed.deform_mode,
				vol,
			)
			if w := engine.ctx_world(); w != nil && vol_owner != {} && engine.pool_valid(&w.transforms, engine.Handle(vol_owner)) {
				if _, vol_after := engine.transform_get_comp(vol_owner, cad_csg.CSGVolume); vol_after != nil {
					csg_history_commit(vol_after)
				}
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
}

// Visualizes the Soft Deformer Coordinate-Offset Renderer Math in 3D:
// 1. Draws the Undeformed Jolt CSG Collision Cage in green (`p_0`)
// 2. Draws 3D Displacement Vector Arrows `p_0 -> p'` (`delta_p(x, t)`) and strain-colored deformed vertices (`p'`)!
@(private = "package")
_draw_soft_deform_renderer_math_debug :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil || len(vol.soft_deform_stamps) == 0 do return
	tw := engine.transform_world(engine.Transform_Handle(vol.owner))
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// 1. Draw each active Soft Deformer stamp center & radius
	for st, si in vol.soft_deform_stamps {
		wp := (model * [4]f32{st.local_pos.x, st.local_pos.y, st.local_pos.z, 1.0}).xyz
		gizmos.with_color({0.85, 0.35, 1.0, 0.45})
		gizmos.wire_sphere(wp, st.radius)
		if si == len(vol.soft_deform_stamps) - 1 {
			tot_amp := st.plastic_depth + st.elastic_depth
			_draw_3d_tracked_pill(wp + {0, st.radius + 0.18, 0}, fmt.tprintf("Deform Stamp #%d (%v | Amp:%.2fm)", si + 1, st.mode, tot_amp), {0.92, 0.55, 1.0, 0.95})
		}
	}

	// 2. Sample chunk vertices to draw 3D displacement vector arrows `p_0 (Collision) -> p' (Deformed Visual)`!
	arrow_budget := 180
	for _, ch in vol.chunks {
		if ch == nil || len(ch.verts) == 0 do continue
		step := max(len(ch.verts) / 48, 1)
		for vi := 0; vi < len(ch.verts) && arrow_budget > 0; vi += step {
			p0_loc := ch.verts[vi].position
			disp_loc, strain := cad_csg.csg_eval_soft_deform_offset(vol.soft_deform_stamps[:], p0_loc)
			if linalg.length2(disp_loc) < 1e-4 do continue
			p1_loc := p0_loc + disp_loc
			p0_w := (model * [4]f32{p0_loc.x, p0_loc.y, p0_loc.z, 1.0}).xyz
			p1_w := (model * [4]f32{p1_loc.x, p1_loc.y, p1_loc.z, 1.0}).xyz

			// Undeformed collision point p0 (Green dot)
			gizmos.with_color({0.20, 0.95, 0.40, 0.85})
			gizmos.solid_sphere(p0_w, 0.025)

			// Displacement vector arrow p0 -> p1 (Heat-colored by strain)
			hc := cad_csg.csg_strain_to_heatmap_color(strain)
			gizmos.with_color({f32(hc[0]) / 255.0, f32(hc[1]) / 255.0, f32(hc[2]) / 255.0, 0.95})
			gizmos.line(p0_w, p1_w)
			gizmos.solid_sphere(p1_w, 0.035)
			arrow_budget -= 1
		}
	}
}

// ============================================================================
// TOOL 7: INTERACTIVE 3D POLYGON GLASS BUILDER (`Draw_Glass_Poly`)
// (Click 3D Points with CAD Ruler Live Segment Lengths -> Complete Loop -> Fill with Glass!)
// ============================================================================

@(private = "package")
_update_and_draw_glass_poly_tool :: proc(
	ray:         engine.Ray,
	hit_mesh:    bool,
	hit_pos:     [3]f32,
	hit_norm:    [3]f32,
	hit_vol:     ^cad_csg.CSGVolume,
	wp_ok:       bool,
	wp_pt:       [3]f32,
	lmb_clicked: bool,
	rmb_clicked: bool,
) {
	f := handles.frame()
	if !f.valid do return

	// Backspace (when numeric HUD buffer is empty) undoes the last placed 3D glass vertex without cancelling the loop!
	if _ed.num_len == 0 && len(_ed.glass_poly_pts_3d) > 0 && _key_just_pressed(.BACKSPACE, .Backspace) {
		pop(&_ed.glass_poly_pts_3d)
		if len(_ed.glass_poly_surf_norms) > 0 do pop(&_ed.glass_poly_surf_norms)
		if len(_ed.glass_poly_pts_3d) == 0 do _ed.glass_poly_target_vol = nil
		return
	}

	// Right-click: if >= 3 points placed, complete & fill the glass loop; otherwise undo the last placed point!
	if rmb_clicked && len(_ed.glass_poly_pts_3d) > 0 {
		if len(_ed.glass_poly_pts_3d) >= 3 {
			_commit_drawn_glass_poly_loop()
		} else {
			pop(&_ed.glass_poly_pts_3d)
			if len(_ed.glass_poly_surf_norms) > 0 do pop(&_ed.glass_poly_surf_norms)
			if len(_ed.glass_poly_pts_3d) == 0 do _ed.glass_poly_target_vol = nil
		}
		return
	}

	// Determine the current 3D cursor point (`cur_pt`) and snap badge
	has_cur := hit_mesh || wp_ok
	raw_pt := hit_pos if hit_mesh else wp_pt
	surf_n := hit_norm if (hit_mesh && linalg.length2(hit_norm) > 0.25) else _ed.plane.normal

	// If neither surface nor workplane was hit, project onto the active polygon plane (if points exist)
	if !has_cur && len(_ed.glass_poly_pts_3d) > 0 {
		ref_p := _ed.glass_poly_pts_3d[len(_ed.glass_poly_pts_3d) - 1]
		ref_n := _ed.glass_poly_surf_norms[0] if len(_ed.glass_poly_surf_norms) > 0 else [3]f32{0, 0, 1}
		denom := linalg.dot(ray.direction, ref_n)
		if abs(denom) > 1e-4 {
			t_p := linalg.dot(ref_p - ray.origin, ref_n) / denom
			if t_p > 0.05 {
				raw_pt  = ray.origin + ray.direction * t_p
				surf_n  = ref_n
				has_cur = true
			}
		}
	}

	cur_pt := raw_pt
	snap_badge := ""
	ctrl_snap := im.GetIO().KeyCtrl
	alt_free  := im.GetIO().KeyAlt
	if has_cur {
		// 1. Magnetic OSNAP (Vertex □, Midpoint △, Face Center ◎) across CSG brushes & compiled chunks
		if _ed.osnap_enabled && !alt_free {
			if os_pt, os_kind, os_ok := _find_osnap_world_point(raw_pt); os_ok && os_kind != .None {
				cur_pt = os_pt
				_ed.osnap_active   = true
				_ed.osnap_kind     = os_kind
				_ed.osnap_world_pt = os_pt
				switch os_kind {
				case .None:
				case .Vertex:      snap_badge = " [OSNAP: Vertex]"
				case .Midpoint:    snap_badge = " [OSNAP: Midpoint]"
				case .Face_Center: snap_badge = " [OSNAP: Center]"
				}
			}
		}

		// 2. If not corner-snapped, apply Ctrl metric grid snap OR World Axis snap relative to last point
		if len(snap_badge) == 0 {
			if ctrl_snap || !hit_mesh {
				step := _ed.snap_step if ctrl_snap else max(_ed.snap_step * 0.5, 0.05)
				cur_pt = {
					_snap_scalar(raw_pt.x, step),
					_snap_scalar(raw_pt.y, step),
					_snap_scalar(raw_pt.z, step),
				}
				snap_badge = " [Grid Snap]"
			} else if _ed.axis_snap_enabled && len(_ed.glass_poly_pts_3d) > 0 {
				prev_p := _ed.glass_poly_pts_3d[len(_ed.glass_poly_pts_3d) - 1]
				delta := cur_pt - prev_p
				seg_len := linalg.length(delta)
				if seg_len > 0.08 {
					dir := delta / seg_len
					axes := [3][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
					axis_names := [3]string{" [Snap X]", " [Snap Y]", " [Snap Z]"}
					for ax, ai in axes {
						d_ax := linalg.dot(dir, ax)
						if abs(d_ax) > 0.985 { // within ~10 deg of world axis
							sgn: f32 = 1.0 if d_ax >= 0 else -1.0
							snapped_len := _snap_scalar(seg_len, max(_ed.snap_step * 0.5, 0.05)) if ctrl_snap else seg_len
							cur_pt = prev_p + ax * (sgn * snapped_len)
							snap_badge = axis_names[ai]
							break
						}
					}
				}
			}
		}
	}

	// Check if hovering near the start point `P0` when `>= 3` points are placed (to close the loop!)
	n_placed := len(_ed.glass_poly_pts_3d)
	closing_loop := false
	if n_placed >= 3 && has_cur {
		p0 := _ed.glass_poly_pts_3d[0]
		if linalg.length(cur_pt - p0) <= 0.28 {
			cur_pt = p0
			closing_loop = true
			snap_badge = " [CLOSE LOOP -> FILL GLASS!]"
		}
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// Draw live translucent glass polygon preview fan + CAD Ruler edge length measurements!
	if n_placed > 0 {
		p0 := _ed.glass_poly_pts_3d[0]

		// 1) Translucent cyan-teal glass interior preview lines & diagonal reflection streaks
		if n_placed >= 2 {
			gizmos.with_color({0.32, 0.92, 1.0, 0.42})
			for i in 1 ..< n_placed - 1 {
				pa := _ed.glass_poly_pts_3d[i]
				pb := _ed.glass_poly_pts_3d[i + 1]
				gizmos.line(p0, pa)
				gizmos.line(p0, pb)
				// Mid-cross hatch so the filled glass surface is unmistakable
				gizmos.line((p0 + pa) * 0.5, (pa + pb) * 0.5)
			}
			if has_cur && !closing_loop {
				plast := _ed.glass_poly_pts_3d[n_placed - 1]
				gizmos.with_color({0.32, 0.92, 1.0, 0.35})
				gizmos.line(p0, cur_pt)
				gizmos.line((p0 + plast) * 0.5, (plast + cur_pt) * 0.5)
			}
		}

		// 2) Placed 3D edges + CAD Ruler segment length pills
		for i in 0 ..< n_placed - 1 {
			pa := _ed.glass_poly_pts_3d[i]
			pb := _ed.glass_poly_pts_3d[i + 1]
			seg_len := linalg.length(pb - pa)
			gizmos.with_color({0.25, 0.96, 1.0, 0.98})
			gizmos.line(pa, pb)
			mid := (pa + pb) * 0.5
			_draw_3d_tracked_pill(mid + surf_n * 0.08, fmt.tprintf("%.2f m", seg_len), {0.55, 0.96, 1.0, 0.95})
		}

		// 3) Live rubber-band edge from `P_last` -> `cur_pt` (and closing preview edge back to `P0`)
		if has_cur {
			plast := _ed.glass_poly_pts_3d[n_placed - 1]
			live_len := linalg.length(cur_pt - plast)
			gizmos.with_color({0.25, 1.0, 0.55, 1.0} if closing_loop else {1.0, 0.88, 0.25, 0.98})
			gizmos.line(plast, cur_pt)
			if live_len > 0.02 {
				_draw_3d_tracked_pill(
					(plast + cur_pt) * 0.5 + surf_n * 0.10,
					fmt.tprintf("%.2f m%s", live_len, snap_badge),
					{0.35, 1.0, 0.62, 1.0} if closing_loop else {1.0, 0.90, 0.32, 1.0},
				)
			}
			if n_placed >= 2 && !closing_loop {
				gizmos.with_color({0.25, 0.95, 0.65, 0.55})
				gizmos.line(cur_pt, p0)
			}
		}

		// 4) Placed 3D vertex handles (P0 highlighted in bright green when `>= 3` points are ready to close!)
		for pt, idx in _ed.glass_poly_pts_3d {
			if idx == 0 {
				gizmos.with_color({0.20, 1.0, 0.48, 1.0})
				gizmos.solid_sphere(pt, 0.075 if closing_loop else 0.06)
				if n_placed >= 3 {
					gizmos.wire_circle(pt, surf_n, 0.18, 20)
				}
			} else {
				gizmos.with_color({0.28, 0.92, 1.0, 1.0})
				gizmos.solid_sphere(pt, 0.05)
			}
		}
	}

	// Draw cursor handle & contextual HUD instruction pill
	if has_cur {
		gizmos.with_color({0.20, 1.0, 0.52, 1.0} if closing_loop else {0.35, 0.95, 1.0, 0.98})
		gizmos.solid_sphere(cur_pt, 0.055)
		gizmos.wire_circle(cur_pt, surf_n, 0.14, 18)

		hud_msg: string
		if n_placed == 0 {
			hud_msg = fmt.tprintf("3D Glass Tool: Click Point 1 in 3D Space%s (Ctrl=Grid Snap)", snap_badge)
		} else if closing_loop {
			hud_msg = fmt.tprintf("Click P0 (or Press Enter) to Fill %d-Point Loop with Glass!", n_placed)
		} else if n_placed < 3 {
			hud_msg = fmt.tprintf("3D Glass Loop (%d pts): Click next 3D point%s (RMB=Undo)", n_placed, snap_badge)
		} else {
			hud_msg = fmt.tprintf("3D Glass Loop (%d pts): Click P0 / Enter / RMB to Fill with Glass!%s", n_placed, snap_badge)
		}
		_draw_3d_tracked_pill(
			cur_pt + surf_n * 0.28,
			hud_msg,
			{0.28, 1.0, 0.58, 1.0} if closing_loop else {0.42, 0.96, 1.0, 1.0},
		)
	}

	// Keyboard Enter / Space when `>= 3` points are placed -> complete loop & fill with glass!
	if n_placed >= 3 && (_key_just_pressed(.RETURN, .Enter) || _key_just_pressed(.KP_ENTER, .KeypadEnter) || _key_just_pressed(.SPACE, .Space)) {
		_commit_drawn_glass_poly_loop()
		return
	}

	// Left-click: either close the loop on P0 or append a new 3D vertex!
	if lmb_clicked && has_cur {
		handles.claim_mouse(true)
		if closing_loop {
			_commit_drawn_glass_poly_loop()
			return
		}
		if n_placed == 0 && hit_vol != nil {
			_ed.glass_poly_target_vol = hit_vol
		}
		// Prevent duplicate zero-length clicks on the exact same last vertex
		if n_placed > 0 && linalg.length(cur_pt - _ed.glass_poly_pts_3d[n_placed - 1]) < 0.03 {
			return
		}
		append(&_ed.glass_poly_pts_3d, cur_pt)
		append(&_ed.glass_poly_surf_norms, surf_n)
	}
}

@(private = "package")
_commit_drawn_glass_poly_loop :: proc() {
	if len(_ed.glass_poly_pts_3d) < 3 do return

	vol := _ed.glass_poly_target_vol
	if vol == nil {
		vol = _ed.hover_vol
	}
	if vol == nil {
		vol, _ = _resolve_active_volume(true)
	}
	if vol != nil {
		csg_history_ensure_baseline(vol)
		tw := engine.transform_world(engine.Transform_Handle(vol.owner))
		inv_m := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		local_pts := make([][3]f32, len(_ed.glass_poly_pts_3d), context.temp_allocator)
		for wp_i, idx in _ed.glass_poly_pts_3d {
			local_pts[idx] = (inv_m * [4]f32{wp_i.x, wp_i.y, wp_i.z, 1.0}).xyz
		}
		hint_n := _ed.glass_poly_surf_norms[0] if len(_ed.glass_poly_surf_norms) > 0 else _ed.plane.normal
		_, gp_idx := cad_csg.csg_volume_add_poly_glass_pane(
			vol,
			"Poly_Glass",
			local_pts,
			hint_n,
			_ed.glass_draw_carve_wall,
			0.65,
			_ed.glass_material,
		)
		_ed.selected_glass_idx = gp_idx if gp_idx >= 0 else len(vol.glass_panes) - 1
		csg_history_commit(vol)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}

	clear(&_ed.glass_poly_pts_3d)
	clear(&_ed.glass_poly_surf_norms)
	_ed.glass_poly_target_vol = nil
}

@(private = "package")
_draw_3d_tracked_pill :: proc(
	world_pos: [3]f32,
	text:      string,
	col:       [4]f32,
) {
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	gizmos.with_color(col)
	gizmos.label(world_pos, text, align = {0.5, 0.5}, scale = 1.05)
}

// ============================================================================
// DEDICATED DOCKABLE WINDOW: `CAD & CSG` (`Window -> CAD & CSG Blockout`)
// ============================================================================

@(editor_window={id="cad_csg_panel", title="CAD & CSG Blockout", icon="EXTENSION", width=460, height=700})
draw_cad_csg_window :: proc() {
	_sync_viewport_mode()
	_draw_cad_csg_panel_contents()
}

@(private = "package")
_draw_cad_csg_panel_contents :: proc() {
	// 1. Mode & Sub-Tool Selection (Mutually exclusive with Picker / Move / Rotate / Scale)
	im.SeparatorText("1. Active Scene3D Tool (Transform vs CAD/CSG)")
	if im.RadioButton("Select / Move / Rotate / Scale Object (Q / W / E / R)", !_ed.tool_active) {
		deactivate_cad_tool()
	}
	widgets.tooltip("Leave the CAD drawing tools and use the normal Picker / Move / Rotate / Scale gizmo (Q / W / E / R)")
	if im.RadioButton("1: 2D Polyline / Spline Sketch -> Extrude", _ed.tool_active && _ed.sub_tool == .Spline_Poly_Sketch) {
		activate_cad_tool(.Spline_Poly_Sketch)
	}
	widgets.tooltip("Click points on the WorkPlane (C = sharp/smooth, Shift+drag = freehand), Enter closes the loop, then pull it up into a 3D solid")
	if im.RadioButton("2: Box / Primitive Pull-Push Builder", _ed.tool_active && _ed.sub_tool == .Box_Primitive) {
		activate_cad_tool(.Box_Primitive)
	}
	widgets.tooltip("Drag a footprint on the WorkPlane, then pull the height. The shape (Box, Wedge, Pillar, Cylinder...) is picked in the CAD top bar")
	if im.RadioButton("3: Extrude / Push-Pull Brush Face", _ed.tool_active && _ed.sub_tool == .Face_Push_Pull) {
		activate_cad_tool(.Face_Push_Pull)
	}
	widgets.tooltip("Click & drag any CSG or mesh face to extrude it outward or intrude it inward (type a number + Enter for an exact distance)")
	if im.RadioButton("4: Red Faction Geo-Mod Crater Blaster (B)", _ed.tool_active && _ed.sub_tool == .Geo_Mod_Blast) {
		activate_cad_tool(.Geo_Mod_Blast)
	}
	widgets.tooltip("Click any destructible CSG surface to blast a boolean crater ([ and ] change the radius)")
	if im.RadioButton("5: SabreCSG / RealtimeCSG 2-Point Clip Plane Slicer", _ed.tool_active && _ed.sub_tool == .Clip_Brush_Plane) {
		activate_cad_tool(.Clip_Brush_Plane)
	}
	widgets.tooltip("Click Point A and Point B across a CSG volume to slice or bevel it along an arbitrary plane (Tab cycles Split Both / Keep Back / Keep Front)")
	if im.RadioButton("6: Soft Deformer Body Brush (Mesh Coord Offset + Math Debug)", _ed.tool_active && _ed.sub_tool == .Soft_Deform_Brush) {
		activate_cad_tool(.Soft_Deform_Brush)
	}
	widgets.tooltip("Deforms visual mesh vertices (Dent, Bulge, Shockwave Ripple, Twist) via coordinate offset while keeping Jolt CSG collision bodies 100% untouched!")

	op_idx := i32(_ed.brush_op)
	if im.RadioButton("+ Add Solid (Union)", op_idx == 0) do _ed.brush_op = .Add
	widgets.tooltip("New brushes add solid geometry (boolean union)")
	im.SameLine()
	if im.RadioButton("- Cut Hole (Boolean Subtract)", op_idx == 1) do _ed.brush_op = .Subtract
	widgets.tooltip("New brushes carve holes into existing CSG (boolean subtract) - doors, windows, tunnels")

	if _ed.sub_tool == .Spline_Poly_Sketch {
		im.Checkbox("Smooth Catmull-Rom Spline Vertex (C)", &_ed.sketch_next_smooth)
		widgets.tooltip("The next placed point is a smooth curve point instead of a sharp corner (C toggles)")
		im.Checkbox("Freehand Squiggly Stroke (or hold Shift+Drag)", &_ed.sketch_freehand)
		widgets.tooltip("Drag to draw a continuous freehand curve instead of clicking point by point")
		im.SliderFloat("Spline Curve Tension", &_ed.sketch_tension, 0.0, 0.80, "%.2f")
		widgets.tooltip("How tightly smooth points curve: 0 = round and loose, higher = tighter, closer to straight lines")
	}

	im.Checkbox("Snap to World X/Y/Z Axes & 45° Half-Axes", &_ed.axis_snap_enabled)
	widgets.tooltip("Snap the drawing direction to world X / Y / Z and 45-degree half-axes relative to the last point")
	im.SliderFloat("Metric Grid Snap (m)", &_ed.snap_step, 0.05, 2.0, "%.2f m")
	widgets.tooltip("Grid step in meters for drawing, box sizes and extrusion")
	im.SliderFloat("Crater Blast Radius (m) [ / ]", &_ed.blast_radius, 0.12, 8.0, "%.2f m")
	widgets.tooltip("Radius of the Geo-Mod crater in meters (also [ and ] in Scene3D)")
	im.SliderFloat("Crater Blast Impulse", &_ed.blast_impulse, 1.0, 40.0, "%.1f")
	widgets.tooltip("How hard debris and detached pieces are thrown by a blast")
	im.ColorEdit4("New Brush Color", &_ed.brush_color)
	widgets.tooltip("Color of newly drawn CSG brushes")
	im.Checkbox("Destructible by Geo-Mod Blasts", &_ed.brush_destructible)
	widgets.tooltip("New brushes can be blasted by the Geo-Mod tool (uncheck for indestructible walls / floors)")
	im.SameLine()
	im.Checkbox("Anchored Foundation", &_ed.brush_anchored)
	widgets.tooltip("New brushes count as grounded foundation: pieces still connected to them never collapse")

	im.Spacing()
	im.SeparatorText("2. Colliders, Craters & Rigidbody Physics")

	vol, _ := _resolve_active_volume(false)
	if vol == nil {
		im.TextDisabled("No CSGVolume in scene yet. Draw in Scene3D to create one.")
	} else {
		// Separate Collider vs CSG vs Crater Rebuild Buttons!
		im.PushStyleColorImVec4(.Button, {0.18, 0.52, 0.76, 0.95})
		if im.Button("Sync Jolt Colliders Only (Keep Craters)", {-1, 26}) {
			cad_csg.csg_volume_sync_colliders_only(vol)
		}
		im.PopStyleColor(1)
		widgets.tooltip("Re-cooks JoltC physics colliders from the current geometry WITHOUT resetting or erasing any blasted craters!")

		if im.Button("Rebuild CSG Meshes", {165, 24}) {
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("Recompile all brushes into meshes and colliders (craters are re-applied if 'Keep Blast Craters' is on)")
		im.SameLine()
		im.Checkbox("Keep Blast Craters", &vol.preserve_craters_on_rebuild)
		widgets.tooltip("When checked, rebuilding CSG or editing brushes automatically re-applies your existing blast craters so destroyed holes are NOT lost!")

		if len(vol.recorded_blasts) > 0 {
			im.PushStyleColorImVec4(.Button, {0.72, 0.28, 0.20, 0.92})
			if im.Button(fmt.ctprintf("Reset %d Blast Crater(s) (Restore Pristine)", len(vol.recorded_blasts)), {-1, 24}) {
				cad_csg.csg_volume_reset_craters(vol)
			}
			widgets.tooltip("Remove all recorded blast craters and restore the untouched geometry")
			im.PopStyleColor(1)
		}

		im.Spacing()
		// Physics Mode: Static Environment w/ Structural Island Collapse vs Full Dynamic Rigidbody
		if im.Checkbox("Dynamic Rigidbody Volume (Falls & Tumbles in Jolt)", &vol.is_dynamic_rigidbody) {
			vol.gpu_dirty = true
			cad_csg.csg_volume_sync_colliders_only(vol)
		}
		widgets.tooltip("• Unchecked (Default): Grounded walls/floors are static Jolt colliders, while any upper pillar/bridge severed from the ground by a blast collapses as a dynamic falling Rigidbody!\n• Checked: The entire CSGVolume is simulated as a movable, falling Jolt Rigidbody prop!")

		if im.Checkbox("Cast Real-Time Planar Floor Shadows", &vol.cast_planar_shadows) {
			vol.gpu_dirty = true
		}
		widgets.tooltip("Projects real-time 3D directional sun shadows from elevated walls, doorways, windows, catwalks, pillars, and blasted holes onto the floor plane.")

		im.Checkbox("Detach & Collapse Severed Pillars/Bridges", &vol.enable_structural_collapse)
		widgets.tooltip("When a blast cuts a piece off from the ground it breaks away as a falling dynamic object")

		im.Spacing()
		im.SeparatorText(fmt.ctprintf("2b. Severed Steel Voxel SDF & CSG Chunks (%d Active Chunks)", len(vol.chunks)))
		backend_idx := i32(vol.destruction_backend)
		im.Text("Blast Destruction Backend:")
		if im.RadioButton("Severed Steel Voxel SDF (O(1) No-Lag Tunneling)", backend_idx == 0) {
			vol.destruction_backend = .Lazy_Voxel_SDF
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("Recommended (Default): Untouched chunks stay crisp CAD polygons; the moment a blast hits a chunk, it lazily allocates a 32x32x32 Voxel SDF grid and carves craters in O(1) constant time (< 0.05 ms) with Surface Nets smoothing and 16^3 greedy Jolt physics boxes. Zero hull fragmentation or lag even after 500 rapid-fire blasts!")
		im.SameLine()
		if im.RadioButton("Classic Convex CSG", backend_idx == 1) {
			vol.destruction_backend = .Pure_Convex_CSG
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("Legacy planar half-space boolean subtraction (splits convex hulls on every blast)")
		im.Checkbox("Show 3D CSG Chunk Grid & Telemetry in Scene3D", &_ed.show_chunk_grid)
		widgets.ui_tool_script_loc(#location(_draw_csg_chunk_grid), "CSG Spatial Chunk Grid Visualizer")
		widgets.tooltip("Draws each Voxel-like CSG_Chunk cell boundary and its hull/triangle count in Scene3D.")
		if im.SliderFloat("Spatial Chunk Size (m)", &vol.chunk_size, 4.0, 24.0, "%.1f m") {
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("Size of CSG chunks: 8m = dense indoor CQB (4x player height), 16m = UT2004/UT3/Helldivers outdoor structures, 24m = mega terrain")
		im.TextDisabled("Presets (2m Player Scale):")
		im.SameLine()
		if im.SmallButton("8m (Indoor CQB)") {
			vol.chunk_size = 8.0
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("8m x 8m x 8m chunks (4x player height): ultra-fast per-blast rebuilds for multi-story indoor rooms & bunkers")
		im.SameLine()
		if im.SmallButton("16m (Outdoor / UT3 / Helldivers)") {
			vol.chunk_size = 16.0
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("16m x 16m x 16m chunks (8x player height): 8x fewer chunks & Jolt static bodies for large Helldivers / UT2004 / UT3 maps!")
		im.SameLine()
		if im.SmallButton("24m (Mega)") {
			vol.chunk_size = 24.0
			cad_csg.csg_volume_rebuild(vol)
		}
		widgets.tooltip("24m x 24m x 24m chunks: minimum draw-call & broadphase overhead for massive open terrain")

		im.Spacing()
		im.SeparatorText(fmt.ctprintf("2c. Bake & Save CSG (%d Baked Hulls)", len(vol.runtime_hulls)))
		im.PushStyleColorImVec4(.Button, {0.18, 0.58, 0.36, 0.95})
		if im.Button("Bake & Save CSG Changes in .scene (Scene Composition)", {-1, 26}) {
			_ = cad_csg.csg_volume_bake_changes(vol)
			_ed.selected_brush_idx = -1
			if sc := engine.sm_scene_get_active(); sc != nil && len(sc.path) > 0 {
				_ = engine.scene_save(sc, sc.path)
			}
		}
		im.PopStyleColor(1)
		widgets.ui_tool_script_loc(#location(cad_csg.csg_volume_bake_changes), "Bake CSG Changes into .scene")
		widgets.tooltip("Bakes all CSG brushes, booleans, extrusions/intrusions, and blast craters into persistent convex hulls (runtime_hulls) and saves the active .scene file!\nIdeal for Scene Composition & procedural map generation while keeping the volume 100% destructible in Play Mode!")

		if im.Button("Bake CSG -> Static Mesh Object (MeshFilter + MeshRenderer)", {-1, 24}) {
			if mh := cad_csg.csg_volume_bake_to_static_mesh(vol); mh != {} {
				engine.inspector_request_select(mh)
			}
		}
		widgets.ui_tool_script_loc(#location(cad_csg.csg_volume_bake_to_static_mesh), "Bake CSG Volume to Static Mesh Object")
		widgets.tooltip("Converts the current compiled CSG geometry into a standalone Static Mesh GameObject (unifies across chunks, removes internal seam faces, merges coplanar polygons, and dissolves pointless vertices!)")

		if im.Button("Smart Clean & Simplify CSG Hulls & Triangles", {-1, 24}) {
			_ = cad_csg.csg_volume_smart_clean_and_simplify(vol)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.ui_tool_script_loc(#location(cad_csg.csg_volume_smart_clean_and_simplify), "Smart Clean & Simplify CSG Hulls & Triangles")
		widgets.tooltip("Smart CSG Cleaner: Purges sliver/micro convex fragments, merges sibling convex hulls whose union is convex, clips partial internal seam faces, merges coplanar polygons, and dissolves pointless collinear/T-junction vertices!")

		if im.Button("Center Pivot to Geometry", {215, 22}) {
			csg_history_ensure_baseline(vol)
			if cad_csg.csg_volume_recenter_pivot(vol) {
				csg_history_commit(vol)
			}
		}
		widgets.tooltip("Moves the entity gizmo pivot to the exact center of the CSG geometry without shifting the geometry in 3D world space!")
		im.SameLine()
		if im.Button("Drop Bottom to Y=0", {-1, 22}) {
			_ = cad_csg.csg_volume_drop_to_ground(vol, 0.0)
		}
		widgets.tooltip("Drops the CSG Volume vertically so its lowest face rests flush on the ground plane (Y = 0.0).")

		im.Spacing()
		im.SeparatorText(fmt.ctprintf("3. Authored CSG Brushes (%d) & Blast Craters (%d)", len(vol.brushes), len(vol.recorded_blasts)))
		im.Checkbox("Show Cut Hole & Blast Crater 3D Wireframes", &_ed.show_cut_and_blast_wireframes)
		widgets.tooltip("Draws 3D wireframe outlines for all boolean '- Cut Hole' brushes and Geo-Mod blast craters so subtractive volumes are never invisible in CAD Mode!")
		if len(vol.brushes) > 1 {
			im.SameLine()
			if im.SmallButton("Move '-' Cuts Last") {
				csg_history_ensure_baseline(vol)
				if cad_csg.csg_volume_move_subtracts_to_end(vol) > 0 {
					csg_history_commit(vol)
				}
			}
			widgets.tooltip("Moves all '- Cut Hole' brushes to the bottom of the Brush Stack so existing doorways/windows also carve newly added walls!")
		}
		if len(vol.brushes) > 1 {
			im.TextDisabled("3D W/E/R Gizmo Target:")
			im.SameLine()
			if im.RadioButton("Selected Brush", _ed.gizmo_edits_brush) do _ed.gizmo_edits_brush = true
			widgets.tooltip("The W / E / R gizmo moves only the brush selected in the list below")
			im.SameLine()
			if im.RadioButton("Whole Volume", !_ed.gizmo_edits_brush) do _ed.gizmo_edits_brush = false
			widgets.tooltip("The W / E / R gizmo moves the whole CSGVolume object")

			if _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(vol.brushes) {
				sb_name := vol.brushes[_ed.selected_brush_idx].name
				im.PushStyleColorImVec4(.Button, {0.82, 0.44, 0.14, 0.95})
				im.PushStyleColorImVec4(.ButtonHovered, {0.92, 0.54, 0.22, 1.00})
				if im.Button(fmt.ctprintf("Detach '%s' -> Dynamic Physics CSG Object", sb_name), {-1, 25}) {
					if new_h := cad_csg.csg_detach_brush_to_volume(vol, _ed.selected_brush_idx, true); new_h != {} {
						_ed.selected_brush_idx = 0
						engine.inspector_request_select(new_h)
					}
				}
				im.PopStyleColor(2)
				widgets.ui_tool_script_loc(#location(cad_csg.csg_detach_brush_to_volume), "Detach CSG Brush to Dynamic Physics Volume")
				widgets.tooltip("Extracts the selected CSG Brush (plus any overlapping doorway/window cutouts) into its own standalone GameObject with Dynamic Jolt Physics enabled!")

				if im.Button("Detach Selected Brush (Static CSG)", {215, 22}) {
					if new_h := cad_csg.csg_detach_brush_to_volume(vol, _ed.selected_brush_idx, false); new_h != {} {
						_ed.selected_brush_idx = 0
						engine.inspector_request_select(new_h)
					}
				}
				widgets.tooltip("Extract the selected brush into its own static (non-physics) CSGVolume object")
				im.SameLine()
				if im.Button("Split All to Separate CSG", {-1, 22}) {
					_ = cad_csg.csg_split_all_brushes_to_volumes(vol, false)
					_ed.selected_brush_idx = 0
				}
				widgets.ui_tool_script_loc(#location(cad_csg.csg_split_all_brushes_to_volumes), "Split All Brushes to Separate CSG Volumes")
				widgets.tooltip("Splits every additive brush in this volume into its own separate selectable CSGVolume GameObject in the Hierarchy!")
			}
		}

		remove_idx := -1
		detach_phys_idx := -1
		dup_idx := -1
		move_idx := -1
		move_dir := 0
		for &b, idx in vol.brushes {
			im.PushIDInt(i32(idx))
			is_sel := (_ed.selected_brush_idx == idx)
			op_tag := "[+]" if b.op == .Add else "[-]"
			lbl := fmt.ctprintf("%s %s (%v)", op_tag, b.name, b.primitive)
			if im.Selectable(lbl, is_sel, {}, {142, 0}) {
				_ed.selected_brush_idx = idx
			}
			widgets.tooltip("Select this brush (highlighted in Scene3D and targeted by the brush gizmo)")
			im.SameLine(0, 3)
			if im.SmallButton(icons.ICON_MD_ARROW_DROP_UP + "##bu") && idx > 0 {
				move_idx = idx
				move_dir = -1
			}
			widgets.tooltip("Move brush earlier in stack")
			im.SameLine(0, 2)
			if im.SmallButton(icons.ICON_MD_ARROW_DROP_DOWN + "##bd") && idx + 1 < len(vol.brushes) {
				move_idx = idx
				move_dir = 1
			}
			widgets.tooltip("Move brush later in stack ('.Subtract' holes only cut brushes above them!)")
			im.SameLine(0, 3)
			if im.SmallButton("Dup") {
				dup_idx = idx
			}
			widgets.tooltip("Duplicate this brush inside the volume")
			im.SameLine(0, 3)
			if im.SmallButton("Phys") {
				detach_phys_idx = idx
			}
			widgets.tooltip("Detach this brush into its own Dynamic Physics CSGVolume GameObject!")
			im.SameLine(0, 3)
			if im.SmallButton("+/-") {
				b.op = .Subtract if b.op == .Add else .Add
				cad_csg.csg_volume_rebuild(vol)
			}
			widgets.tooltip("Flip this brush between Add (solid) and Cut (hole)")
			im.SameLine(0, 3)
			if im.SmallButton("X") {
				remove_idx = idx
			}
			widgets.tooltip("Delete this brush from the volume")
			im.PopID()
		}
		if move_idx >= 0 && move_dir != 0 {
			csg_history_ensure_baseline(vol)
			_ed.selected_brush_idx = cad_csg.csg_volume_move_brush_order(vol, move_idx, move_dir)
			csg_history_commit(vol)
		} else if dup_idx >= 0 {
			csg_history_ensure_baseline(vol)
			_ed.selected_brush_idx = cad_csg.csg_volume_duplicate_brush(vol, dup_idx)
			csg_history_commit(vol)
		} else if detach_phys_idx >= 0 {
			if new_h := cad_csg.csg_detach_brush_to_volume(vol, detach_phys_idx, true); new_h != {} {
				_ed.selected_brush_idx = 0
				engine.inspector_request_select(new_h)
			}
		} else if remove_idx >= 0 {
			if len(vol.brushes[remove_idx].name) > 0 {
				delete(vol.brushes[remove_idx].name)
			}
			if vol.brushes[remove_idx].profile_points != nil {
				delete(vol.brushes[remove_idx].profile_points)
			}
			ordered_remove(&vol.brushes, remove_idx)
			if _ed.selected_brush_idx >= len(vol.brushes) {
				_ed.selected_brush_idx = len(vol.brushes) - 1
			}
			cad_csg.csg_volume_rebuild(vol)
		}

		// RealtimeCSG `TexGen` Surface & UV Inspector for the currently selected `CSG_Brush`!
		if _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(vol.brushes) {
			sb := &vol.brushes[_ed.selected_brush_idx]
			im.Spacing()
			im.SeparatorText(fmt.ctprintf("3b. Selected Brush Surface & TexGen UV (%s)", sb.name))
			tex_dirty := false
			if im.Checkbox("Brush-Locked UVs (No Texture Swimming on Move)", &sb.uv_lock_brush) {
				tex_dirty = true
			}
			widgets.tooltip("• Unchecked (World-Locked): Seamless metric UV tiling across adjacent walls/floors.\n• Checked (Brush-Locked, RealtimeCSG TexGen): Locks UVs to this brush's centroid so moving/resizing the brush never swims the texture!")
			if sb.uv_scale <= 0.001 do sb.uv_scale = 0.5
			if im.SliderFloat("UV Tiling Scale (tiles/m)", &sb.uv_scale, 0.05, 4.0, "%.2f") {
				tex_dirty = true
			}
			widgets.tooltip("Metric UV tiling density on this brush's faces (default 0.50 = 1 tile per 2 meters)")
			if im.DragFloat2("UV Offset (U, V)", &sb.uv_offset, 0.02, -10.0, 10.0, "%.2f") {
				tex_dirty = true
			}
			widgets.tooltip("Tangent-space UV offset (U, V) for aligning brick/panel seams on this brush")
			if im.SliderFloat("UV Rotation (deg)", &sb.uv_rot_deg, -180.0, 180.0, "%.1f deg") {
				tex_dirty = true
			}
			widgets.tooltip("Tangent-space UV rotation angle in degrees on this brush's faces")
			im.SameLine()
			if im.SmallButton("0°") { sb.uv_rot_deg = 0; tex_dirty = true }
			widgets.tooltip("Reset UV rotation to 0 degrees")
			im.SameLine()
			if im.SmallButton("45°") { sb.uv_rot_deg = 45; tex_dirty = true }
			widgets.tooltip("Snap UV rotation to 45 degrees")
			im.SameLine()
			if im.SmallButton("90°") { sb.uv_rot_deg = 90; tex_dirty = true }
			widgets.tooltip("Snap UV rotation to 90 degrees")

			col_f := [4]f32{
				f32(sb.color.r) / 255.0,
				f32(sb.color.g) / 255.0,
				f32(sb.color.b) / 255.0,
				f32(sb.color.a) / 255.0,
			}
			if im.ColorEdit4("Brush Surface Tint", &col_f) {
				sb.color = {
					u8(clamp(col_f.r * 255.0, 0, 255)),
					u8(clamp(col_f.g * 255.0, 0, 255)),
					u8(clamp(col_f.b * 255.0, 0, 255)),
					u8(clamp(col_f.a * 255.0, 0, 255)),
				}
				tex_dirty = true
			}
			widgets.tooltip("Per-brush vertex color tint")

			if tex_dirty {
				half_r := max(sb.size.x, max(sb.size.y, sb.size.z)) * 0.75 + 0.5
				_ = cad_csg.csg_volume_rebuild_dirty_aabb(vol, sb.center - [3]f32{half_r, half_r, half_r}, sb.center + [3]f32{half_r, half_r, half_r})
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
		}

		// List every recorded Geo-Mod Blast Crater with its own selectable row, radius slider, and `[X]` delete button!
		if len(vol.recorded_blasts) > 0 {
			im.Spacing()
			im.TextColoredUnformatted({1.0, 0.58, 0.28, 1.0}, fmt.ctprintf("Recorded Geo-Mod Blast Craters (%d):", len(vol.recorded_blasts)))
			remove_blast_idx := -1
			for &rb, b_idx in vol.recorded_blasts {
				im.PushIDInt(i32(10000 + b_idx))
				is_sel_b := (_ed.selected_blast_idx == b_idx)
				bl_lbl := fmt.ctprintf("[-] Geo-Mod Blast #%d (Pos: %.1f, %.1f, %.1f)", b_idx + 1, rb.local_pos.x, rb.local_pos.y, rb.local_pos.z)
				if im.Selectable(bl_lbl, is_sel_b, {}, {205, 0}) {
					_ed.selected_blast_idx = b_idx
					_ed.selected_brush_idx = -1
				}
				widgets.tooltip("Click to highlight this Geo-Mod Blast Crater sphere in Scene3D")
				im.SameLine()
				im.SetNextItemWidth(78)
				if im.SliderFloat("##rb_rad", &rb.radius, 0.25, 8.0, "R:%.2fm") {
					cad_csg.csg_volume_rebuild(vol)
				}
				widgets.tooltip("Adjust this blast crater's radius in meters")
				im.SameLine()
				if im.SmallButton("X") {
					remove_blast_idx = b_idx
				}
				widgets.tooltip("Delete this individual Geo-Mod blast crater and restore the geometry it carved!")
				im.PopID()
			}
			if remove_blast_idx >= 0 {
				cad_csg.csg_volume_remove_recorded_blast(vol, remove_blast_idx)
				if _ed.selected_blast_idx >= len(vol.recorded_blasts) {
					_ed.selected_blast_idx = len(vol.recorded_blasts) - 1
				}
			}
		}
	}

	im.Spacing()
	im.SeparatorText("4. CAD & Modeling Keybindings (Configurable / Disableable)")
	im.Checkbox("Enable CAD & Modeling Keyboard Shortcuts", &cad_csg.csg_settings.enable_all_keybindings)
	widgets.tooltip("Master toggle for all CAD & Modeling keyboard shortcuts (also in Edit -> Project Settings -> CAD & Destructible CSG). Note: W/E/R/Q/T only switch tools when in CAD Mode and never during Play Mode or RMB camera fly!")
	if cad_csg.csg_settings.enable_all_keybindings {
		im.Checkbox("Q / W / E / R / T Transform Tool Shortcuts (CAD Mode Only)", &cad_csg.csg_settings.enable_transform_tool_hotkeys)
		widgets.tooltip("Allow Q/W/E/R/T to switch Picker/Move/Rotate/Scale/Handles when in CAD Mode (never active in Play Mode or outside CAD Mode)")
		im.Checkbox("1 / 2 / 3 / 4 Sub-Tool & Vertex/Edge/Face Mode Keys", &cad_csg.csg_settings.enable_subtool_number_hotkeys)
		widgets.tooltip("Allow number keys 1/2/3/4 to switch CAD sub-tools or Mesh Editor Vertex/Edge/Face modes")
		im.Checkbox("X / Y / Z / N / G Axis Lock & Boolean Flip Keys", &cad_csg.csg_settings.enable_axis_lock_hotkeys)
		widgets.tooltip("Allow X/Y/Z/N/G to lock axes or toggle Add/Cut in CAD Mode")
		im.Checkbox("Shift+E / I / B / O / A / C / [ ] Modeling & Blast Keys", &cad_csg.csg_settings.enable_modeling_op_hotkeys)
		widgets.tooltip("Allow modeling operation shortcuts (Extrude, Inset, Bevel, Pivot, Select All, Spline Smooth, Crater Radius)")
	}
}
