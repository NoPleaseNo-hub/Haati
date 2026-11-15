package cad_csg_editor

// Left-Side Slide-Out Tool Drawer, Blender/FreeCAD Polygon Mesh Editor Mode
// (Vertex / Edge / Face selection + 1-push World X / Y / Z Axis Constraints +
// Extrude, Inset, Bevel, Subdivide, Close Holes, Normals, Convex Hull), and
// Live `Mesh -> CSG` Compliance Checker & Converter.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import gfx "haati:engine/gfx"
import "haati:engine/gizmos"
import input "haati:engine/input"
import "haati:editor/handles"
import "haati:editor/icons"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import cad_csg "haati:packages/cad_csg"
import control_rig "haati:packages/control_rig"
import control_rig_ed "haati:packages/control_rig/editor"

// Which sub-editor tab is active inside CAD / Modeling Mode
CAD_Workspace_Tab :: enum u8 {
	CSG_Editor  = 0, // Half-Space Boolean CSG Blockout & Red Faction Geo-Mod Destruction
	Mesh_Editor = 1, // Blender / FreeCAD Polygon Mesh Editor + Mesh -> CSG Compliance & Converter
}

// Blender / Unreal sub-object & whole-mesh selection mode (`1` = Vertex, `2` = Edge, `3` = Face, `4` = Object)
Mesh_Select_Mode :: enum u8 {
	Vertex = 0,
	Edge   = 1,
	Face   = 2,
	Object = 3, // Whole-Mesh Transform (Q/E/R moves/rotates/scales the whole mesh entity) & 2-Mesh Booleans
}

// Blender-style live operator adjustment ("Adjust Last Operation" panel)
Mesh_Active_Op :: enum u8 {
	None       = 0,
	Extrude    = 1,
	Inset      = 2,
	Bevel_Face = 3,
	Bevel_Edge = 4,
	Loop_Cut   = 5,
}

// Blender-style 1-push World Axis Constraint (`Free`, `X`, `Y`, `Z`)
Axis_Constraint :: enum u8 {
	Free = 0,
	X    = 1,
	Y    = 2,
	Z    = 3,
}

// One polygon face (3+ vertex indices in CCW outward order) in an `Editable_Poly_Mesh`
Editable_Poly_Face :: struct {
	verts: [dynamic]u32,
	uvs:   [dynamic][2]f32,
	color: [4]u8,
}

// Diagnostic report from the `Mesh -> CSG` Compliance Checker
Mesh_CSG_Compliance_Report :: struct {
	compliant:             bool,
	vert_count:            int,
	face_count:            int,
	unique_plane_count:    int,
	open_boundary_edges:   int,
	non_manifold_edges:    int,
	inverted_normal_faces: int,
	concave_face_count:    int,
	concave_vert_count:    int,
	degenerate_faces:      int,
	has_valid_volume:      bool,
	aabb_size:             [3]f32,
	// Indices of offending elements for 3D viewport highlighting
	open_edge_pairs:       [dynamic][2]u32,
	concave_verts:         [dynamic]u32,
	inverted_faces:        [dynamic]int,
}

// Dedicated Toggleable Drawers in Mesh Mode (Unreal Modeling Mode / Blender Category Rail)
CAD_Mesh_Drawer :: enum u8 {
	Shapes     = 0, // Spawn Primitives, Parametric Size/Segs, 3D Wireframe Cage
	Poly_Edit  = 1, // [1] Vert, [2] Edge, [3] Face, [4] Object + Mode-Specific Tools & Live Sliders
	Booleans   = 2, // Unreal Multi-Mesh Booleans (A+B, A-B, A&B), Plane Cut, 3D Cutter Box
	UV_Suite   = 3, // Quick UV Unwrap, Pack, Seams, Transform + Open 2D UV Editor Window
	Convert    = 4, // Save .glb/.obj to Disk, Simplify/Clean, Multi-Pass Repair, Convert Mesh <-> CSG
	Mat_Deform = 5, // Procedural Texture Studio, Physical Material DataTable & Soft Deformer Math
}

// Dedicated Toggleable Drawers in CSG Mode
CAD_CSG_Drawer :: enum u8 {
	Draw_Brushes  = 0, // Spline (1), Box (2), Extrude (3), Blast (4/B), Clip Plane (5), Soft Deform (6)
	Booleans      = 1, // Unreal Multi-CSG Booleans (A+B, A-B, A&B) + Spawn Separate CSG Volumes
	Kitbash_Glass = 2, // Parametric Architectural Prefabs, Details & See-Through Shatterable Glass
	Bake_Convert  = 3, // Convert CSG -> Editable Mesh, Bake & Save, Smart Clean, Physics/Colliders
	Mat_Deform    = 4, // Procedural Texture Studio, Physical Material DataTable & Soft Deformer Math
}

// Full copy of a CSGVolume's authored brushes, runtime hulls & blasts for CAD Session Undo / Redo
CSG_Volume_Snapshot :: struct {
	owner:           engine.Transform_Handle,
	brushes:         [dynamic]cad_csg.CSG_Brush,
	runtime_hulls:   [dynamic]cad_csg.CSG_Convex,
	recorded_blasts: [dynamic]cad_csg.CSG_Recorded_Blast,
	obj_pos:         [3]f32,
}

@(private = "package")
_mesh_ed: struct {
	initialized:        bool,
	workspace_tab:      CAD_Workspace_Tab,

	// Left-Side Slim 42px Icon Dock + Optional Pin-able Popover Drawer in Scene3D
	drawer_open:        bool,
	drawer_pinned:      bool,
	drawer_anim_t:      f32, // 0.0 = collapsed 42px icon dock only, 1.0 = active popover drawer slid out
	drawer_hovered:     bool,
	active_mesh_drawer: CAD_Mesh_Drawer,
	active_csg_drawer:  CAD_CSG_Drawer,

	// CAD Session Memory Cache state (Allocated on Enter CAD Mode, Released on Exit CAD Mode)
	cad_cache_active:   bool,

	// Shared Blender-style 1-push Axis Lock (`Free`, `X`, `Y`, `Z`)
	axis_lock:          Axis_Constraint,

	// Editable Polygon Mesh & AutoCAD 3D Wireframe Cage state (synced live to `target_owner`'s `MeshFilter`)
	target_owner:       engine.Transform_Handle,
	mesh_guid:          engine.Asset_GUID,
	verts:              [dynamic][3]f32,
	faces:              [dynamic]Editable_Poly_Face,
	wire_edges:         [dynamic][2]u32, // Explicit 3D AutoCAD Wireframe Cage edges
	wire_draw_mode:     bool,            // True when clicking in 3D places AutoCAD wireframe vertices/edges
	wire_mirror_x:      bool,            // Mirrors 3D wireframe across X=0 (for symmetric cars/vehicles!)
	wire_last_vert:     int,
	wire_tube_radius:   f32,
	lathe_segments:     int,
	mesh_color:         [4]f32,

	// Parametric Shape Creation settings (Unreal Modeling Mode `Shapes`)
	shape_dims:         [3]f32,
	shape_subdivs:      int,
	last_spawned_preset: int,

	// Sub-object selection state (`Vertex`, `Edge`, `Face`)
	select_mode:        Mesh_Select_Mode,
	selected_verts:     [dynamic]u32,
	selected_edge:      [2]u32,
	has_selected_edge:  bool,
	selected_face:      int,
	hovered_vert:       int,
	hovered_edge:       [2]u32,
	has_hovered_edge:   bool,
	hovered_face:       int,
	xray_mode:          bool, // False (default) = depth-tested wireframe & occlusion-aware front-face picking!
	local_gizmo_space:  bool, // True (default) = align sub-object gizmo with selected Face Normal / Edge tangent!

	// Interactive 3D Sub-Object Gizmo / Extrude / Intrude state
	gizmo_dragging:     bool,
	gizmo_start_pos:    [3]f32,
	drag_orig_verts:    [dynamic][3]f32,
	extrude_amount:     f32,
	inset_amount:       f32,
	bevel_amount:       f32,
	bevel_height:       f32,
	weld_distance:      f32,

	// Blender-Style Live Operator Adjustment ("Adjust Last Operation" panel)
	active_op:          Mesh_Active_Op,
	op_snap:            Mesh_Snapshot,
	has_op_snap:        bool,
	op_face_idx:        int,
	op_edge:            [2]u32,
	op_loop_axis:       int,

	// Unreal-Style 2-Mesh & 2-CSG Booleans (`A + B`, `A - B`, `A & B`) + Save to Disk
	bool_target_b:      engine.Transform_Handle,
	csg_bool_target_b:  engine.Transform_Handle,
	bool_consume_tools: bool, // Default true in UI so Tool B doesn't linger inside carved holes
	save_status:        string,
	uv_seams:           [dynamic][2]u32, // Marked UV Seam edges for unwrapping & 3D display

	// Interactive 3D Face Extrude/Tunnel & Inset Handles directly in `Mesh_Editor` mode
	pre_extrude_snap:       Mesh_Snapshot,
	has_pre_extrude_snap:   bool,
	extrude_orig_ring_loc:  [dynamic][3]f32,
	extrude_orig_norm_loc:  [3]f32,
	face_extrude_dragging:  bool,
	face_extrude_handle_pos:[3]f32,
	face_extrude_origin_w:  [3]f32,
	face_extrude_axis_w:    [3]f32,
	face_extrude_start_s:   f32,
	face_extrude_delta:     f32,
	face_inset_dragging:    bool,
	face_inset_handle_pos:  [3]f32,
	face_inset_start_dist:  f32,

	// Unreal `TriModel` / Mesh Booleans (`MshBool`) & Plane Cut (`PlnCut`) state + 3D Cutter Gizmo
	cut_plane_axis:         int, // 0=X, 1=Y, 2=Z
	cut_plane_offset:       f32,
	cut_plane_keep_neg:     bool,
	show_cut_plane_preview: bool,
	bool_box_size:          [3]f32,
	bool_box_offset:        [3]f32,
	show_cutter_box_gizmo:  bool,
	cutter_gizmo_dragging:  bool,
	cutter_gizmo_start_pos: [3]f32,
	cutter_gizmo_start_off: [3]f32,
	cutter_gizmo_start_sz:  [3]f32,
	cutter_gizmo_scale:     [3]f32,

	// Cached `Mesh -> CSG` Compliance Report
	report:             Mesh_CSG_Compliance_Report,
	report_dirty:       bool,

	// Sub-object transform mode (Move / Rotate / Scale) — follows the Scene3D W/E/R toolbar
	xform_mode:         Mesh_Xform_Mode,
	last_tool:          handles.Tool,
	gizmo_rot:          quaternion128,
	gizmo_scale:        [3]f32,
	gizmo_pivot_world:  [3]f32,

	// Multi-face selection (Shift+Click). `selected_face` stays the primary face for single-face ops.
	sel_faces:          [dynamic]int,

	// Per-frame hover state so Scene3D does not click-through-pick other objects while editing
	hover_any:          bool,

	// Pivot / Origin editing (`O`): moves the object's origin while geometry stays fixed in world
	pivot_edit:         bool,
	pivot_drag_start:   [3]f32,
	pivot_children:     [dynamic]Mesh_Child_Pos,

	// Local Undo / Redo history for Mesh & CSG edits (allocated in CAD Mode, released on exit)
	undo_stack:         [dynamic]Mesh_Snapshot,
	redo_stack:         [dynamic]Mesh_Snapshot,
	committed:          Mesh_Snapshot,
	has_committed:      bool,
	history_owner:      engine.Transform_Handle,

	csg_undo_stack:     [dynamic]CSG_Volume_Snapshot,
	csg_redo_stack:     [dynamic]CSG_Volume_Snapshot,
	csg_committed:      CSG_Volume_Snapshot,
	has_csg_committed:  bool,
	csg_history_owner:  engine.Transform_Handle,

	// Why the mesh could not be loaded into the editor (shown in the drawer & viewport)
	load_error:         string,
}

Mesh_Xform_Mode :: enum u8 {
	Move   = 0,
	Rotate = 1,
	Scale  = 2,
}

Mesh_Child_Pos :: struct {
	tH:  engine.Transform_Handle,
	pos: [3]f32,
}

// Full copy of the editable mesh for Undo / Redo
Mesh_Snapshot :: struct {
	verts:      [dynamic][3]f32,
	face_sizes: [dynamic]u32,
	face_inds:  [dynamic]u32,
	face_uvs:   [dynamic][2]f32,
	face_cols:  [dynamic][4]u8,
	wire_edges: [dynamic][2]u32,
	obj_pos:    [3]f32, // owner's local position (changes when the pivot / origin is edited)
}

MESH_EDITOR_MAX_TRIS  :: 60000
MESH_EDITOR_UNDO_MAX  :: 48

@(private = "package")
_ensure_mesh_ed_init :: proc() {
	if _mesh_ed.initialized {
		if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
		return
	}
	_mesh_ed.initialized        = true
	_mesh_ed.workspace_tab      = .CSG_Editor
	_mesh_ed.drawer_open        = false
	_mesh_ed.drawer_pinned      = false
	_mesh_ed.drawer_anim_t      = 0.0
	_mesh_ed.active_mesh_drawer = .Poly_Edit
	_mesh_ed.active_csg_drawer  = .Draw_Brushes
	_mesh_ed.axis_lock          = .Free
	_mesh_ed.select_mode        = .Face
	_mesh_ed.selected_face      = -1
	_mesh_ed.hovered_vert       = -1
	_mesh_ed.hovered_face       = -1
	_mesh_ed.xray_mode          = false
	_mesh_ed.local_gizmo_space  = true
	_mesh_ed.wire_last_vert     = -1
	_mesh_ed.wire_mirror_x      = true
	_mesh_ed.wire_tube_radius   = 0.08
	_mesh_ed.lathe_segments     = 12
	_mesh_ed.shape_dims         = {2.0, 2.0, 2.0}
	_mesh_ed.shape_subdivs      = 12
	_mesh_ed.last_spawned_preset = -1
	_mesh_ed.mesh_color         = {0.76, 0.82, 0.90, 1.0}
	_mesh_ed.extrude_amount     = 0.75
	_mesh_ed.inset_amount       = 0.25
	_mesh_ed.bevel_amount       = 0.20
	_mesh_ed.bevel_height       = 0.00
	_mesh_ed.weld_distance      = 0.05
	_mesh_ed.op_face_idx        = -1
	_mesh_ed.cut_plane_axis     = 1 // Y plane
	_mesh_ed.cut_plane_offset   = 0.0
	_mesh_ed.cut_plane_keep_neg = true
	// Default Boolean Cutter Box centered at {0, 0, 0} with size {0.9, 0.9, 2.6} so it punches a clean Z-tunnel through a 2m Box!
	_mesh_ed.bool_box_size      = {0.90, 0.90, 2.60}
	_mesh_ed.bool_box_offset    = {0.0, 0.0, 0.0}
	_mesh_ed.bool_consume_tools = true
	_mesh_ed.cutter_gizmo_scale = {1, 1, 1}
	_mesh_ed.report_dirty       = true
	_mesh_ed.gizmo_rot          = quaternion128(1)
	_mesh_ed.gizmo_scale        = {1, 1, 1}
	_mesh_ed.last_tool          = .Translate

	enter_cad_mode_memory_cache()
}

// ============================================================================
// CAD MODE SESSION MEMORY CACHE (ALLOCATE ON ENTER CAD MODE, RELEASE ON EXIT)
// ============================================================================

// Allocates the dedicated CAD Session Memory Cache when entering `CAD_Blockout` mode.
enter_cad_mode_memory_cache :: proc() {
	if !_mesh_ed.initialized {
		_ensure_mesh_ed_init()
		return
	}
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	if _mesh_ed.cad_cache_active {
		// Clear any stale undo/redo history from a previous session so entering CAD mode starts fresh
		for &s in _mesh_ed.undo_stack do _snapshot_free(&s)
		clear(&_mesh_ed.undo_stack)
		for &s in _mesh_ed.redo_stack do _snapshot_free(&s)
		clear(&_mesh_ed.redo_stack)
		for &cs in _mesh_ed.csg_undo_stack do _csg_snapshot_free(&cs)
		clear(&_mesh_ed.csg_undo_stack)
		for &cs in _mesh_ed.csg_redo_stack do _csg_snapshot_free(&cs)
		clear(&_mesh_ed.csg_redo_stack)
		return
	}

	if _mesh_ed.verts == nil                 do _mesh_ed.verts                 = make([dynamic][3]f32, 0, 64)
	if _mesh_ed.faces == nil                 do _mesh_ed.faces                 = make([dynamic]Editable_Poly_Face, 0, 64)
	if _mesh_ed.wire_edges == nil            do _mesh_ed.wire_edges            = make([dynamic][2]u32, 0, 64)
	if _mesh_ed.uv_seams == nil              do _mesh_ed.uv_seams              = make([dynamic][2]u32, 0, 32)
	if _mesh_ed.selected_verts == nil        do _mesh_ed.selected_verts        = make([dynamic]u32, 0, 32)
	if _mesh_ed.drag_orig_verts == nil       do _mesh_ed.drag_orig_verts       = make([dynamic][3]f32, 0, 64)
	if _mesh_ed.extrude_orig_ring_loc == nil do _mesh_ed.extrude_orig_ring_loc = make([dynamic][3]f32, 0, 16)
	if _mesh_ed.report.open_edge_pairs == nil do _mesh_ed.report.open_edge_pairs = make([dynamic][2]u32, 0, 32)
	if _mesh_ed.report.concave_verts == nil   do _mesh_ed.report.concave_verts   = make([dynamic]u32, 0, 32)
	if _mesh_ed.report.inverted_faces == nil  do _mesh_ed.report.inverted_faces  = make([dynamic]int, 0, 32)
	if _mesh_ed.sel_faces == nil             do _mesh_ed.sel_faces             = make([dynamic]int, 0, 16)
	if _mesh_ed.pivot_children == nil        do _mesh_ed.pivot_children        = make([dynamic]Mesh_Child_Pos, 0, 8)
	if _mesh_ed.undo_stack == nil            do _mesh_ed.undo_stack            = make([dynamic]Mesh_Snapshot, 0, MESH_EDITOR_UNDO_MAX + 1)
	if _mesh_ed.redo_stack == nil            do _mesh_ed.redo_stack            = make([dynamic]Mesh_Snapshot, 0, MESH_EDITOR_UNDO_MAX + 1)
	if _mesh_ed.csg_undo_stack == nil        do _mesh_ed.csg_undo_stack        = make([dynamic]CSG_Volume_Snapshot, 0, 32)
	if _mesh_ed.csg_redo_stack == nil        do _mesh_ed.csg_redo_stack        = make([dynamic]CSG_Volume_Snapshot, 0, 32)

	_mesh_ed.cad_cache_active = true
}

// Releases 100% of the CAD Session Memory Cache (Mesh & CSG Undo/Redo snapshots and working buffers)
// when exiting `CAD_Blockout` mode so 0 bytes are held when not editing meshes/CSG!
release_cad_mode_memory_cache :: proc() {
	if !_mesh_ed.initialized do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	_clear_active_op()
	if _mesh_ed.has_pre_extrude_snap {
		_snapshot_free(&_mesh_ed.pre_extrude_snap)
		_mesh_ed.has_pre_extrude_snap = false
	}

	// Free all Mesh Undo/Redo snapshots
	for &s in _mesh_ed.undo_stack do _snapshot_free(&s)
	delete(_mesh_ed.undo_stack)
	_mesh_ed.undo_stack = nil

	for &s in _mesh_ed.redo_stack do _snapshot_free(&s)
	delete(_mesh_ed.redo_stack)
	_mesh_ed.redo_stack = nil

	if _mesh_ed.has_committed {
		_snapshot_free(&_mesh_ed.committed)
		_mesh_ed.has_committed = false
	}
	_mesh_ed.history_owner = {}

	// Free all CSG Undo/Redo snapshots
	for &cs in _mesh_ed.csg_undo_stack do _csg_snapshot_free(&cs)
	delete(_mesh_ed.csg_undo_stack)
	_mesh_ed.csg_undo_stack = nil

	for &cs in _mesh_ed.csg_redo_stack do _csg_snapshot_free(&cs)
	delete(_mesh_ed.csg_redo_stack)
	_mesh_ed.csg_redo_stack = nil

	if _mesh_ed.has_csg_committed {
		_csg_snapshot_free(&_mesh_ed.csg_committed)
		_mesh_ed.has_csg_committed = false
	}
	_mesh_ed.csg_history_owner = {}

	// Free editable mesh working buffers
	_clear_editable_mesh()
	delete(_mesh_ed.verts);                 _mesh_ed.verts = nil
	delete(_mesh_ed.faces);                 _mesh_ed.faces = nil
	delete(_mesh_ed.wire_edges);            _mesh_ed.wire_edges = nil
	delete(_mesh_ed.uv_seams);              _mesh_ed.uv_seams = nil
	delete(_mesh_ed.selected_verts);        _mesh_ed.selected_verts = nil
	delete(_mesh_ed.drag_orig_verts);       _mesh_ed.drag_orig_verts = nil
	delete(_mesh_ed.extrude_orig_ring_loc); _mesh_ed.extrude_orig_ring_loc = nil
	delete(_mesh_ed.report.open_edge_pairs); _mesh_ed.report.open_edge_pairs = nil
	delete(_mesh_ed.report.concave_verts);   _mesh_ed.report.concave_verts = nil
	delete(_mesh_ed.report.inverted_faces);  _mesh_ed.report.inverted_faces = nil
	delete(_mesh_ed.sel_faces);             _mesh_ed.sel_faces = nil
	delete(_mesh_ed.pivot_children);        _mesh_ed.pivot_children = nil

	_uv_ed_release_cache()

	_mesh_ed.target_owner     = {}
	_mesh_ed.cad_cache_active = false
}

// Queries the active state, undo/redo counts, and memory footprint (in bytes) of the CAD Session Memory Cache.
cad_mode_memory_cache_stats :: proc() -> (active: bool, mesh_undo_count, mesh_redo_count, csg_undo_count, csg_redo_count, bytes_used: int) {
	if !_mesh_ed.initialized || !_mesh_ed.cad_cache_active {
		return false, 0, 0, 0, 0, 0
	}
	active          = true
	mesh_undo_count = len(_mesh_ed.undo_stack)
	mesh_redo_count = len(_mesh_ed.redo_stack)
	csg_undo_count  = len(_mesh_ed.csg_undo_stack)
	csg_redo_count  = len(_mesh_ed.csg_redo_stack)

	snap_bytes :: proc(s: Mesh_Snapshot) -> int {
		return cap(s.verts) * size_of([3]f32) +
		       cap(s.face_sizes) * size_of(u32) +
		       cap(s.face_inds) * size_of(u32) +
		       cap(s.face_uvs) * size_of([2]f32) +
		       cap(s.face_cols) * size_of([4]u8) +
		       cap(s.wire_edges) * size_of([2]u32) +
		       size_of(Mesh_Snapshot)
	}
	csg_snap_bytes :: proc(s: CSG_Volume_Snapshot) -> int {
		b := cap(s.brushes) * size_of(cad_csg.CSG_Brush) +
		     cap(s.runtime_hulls) * size_of(cad_csg.CSG_Convex) +
		     cap(s.recorded_blasts) * size_of(cad_csg.CSG_Recorded_Blast) +
		     size_of(CSG_Volume_Snapshot)
		for h in s.runtime_hulls {
			b += cap(h.planes) * size_of(cad_csg.CSG_Plane)
		}
		return b
	}

	bytes_used += cap(_mesh_ed.verts) * size_of([3]f32)
	bytes_used += cap(_mesh_ed.faces) * size_of(Editable_Poly_Face)
	for f in _mesh_ed.faces {
		bytes_used += cap(f.verts) * size_of(u32) + cap(f.uvs) * size_of([2]f32)
	}
	for s in _mesh_ed.undo_stack do bytes_used += snap_bytes(s)
	for s in _mesh_ed.redo_stack do bytes_used += snap_bytes(s)
	if _mesh_ed.has_committed    do bytes_used += snap_bytes(_mesh_ed.committed)
	if _mesh_ed.has_op_snap      do bytes_used += snap_bytes(_mesh_ed.op_snap)

	for cs in _mesh_ed.csg_undo_stack do bytes_used += csg_snap_bytes(cs)
	for cs in _mesh_ed.csg_redo_stack do bytes_used += csg_snap_bytes(cs)
	if _mesh_ed.has_csg_committed     do bytes_used += csg_snap_bytes(_mesh_ed.csg_committed)
	return
}

// ============================================================================
// WORLD <-> MESH-LOCAL SPACE (verts are stored in the owner's local mesh space;
// the GPU mesh is drawn with the owner's full TRS, so picking & gizmos must be too)
// ============================================================================

@(private = "package")
_mesh_model :: proc() -> (m: matrix[4, 4]f32, inv: matrix[4, 4]f32) {
	tw := engine.transform_world(_mesh_ed.target_owner)
	sc := tw.scale
	// Guard against zero scale so the inverse never explodes
	for i in 0 ..< 3 do if abs(sc[i]) < 1e-5 do sc[i] = 1e-5
	m = engine.trs_matrix(tw.position, tw.rotation, sc)
	inv = linalg.inverse(m)
	return
}

@(private = "package")
_xf_point :: #force_inline proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
	v := m * [4]f32{p.x, p.y, p.z, 1}
	return v.xyz
}

@(private = "package")
_xf_vec :: #force_inline proc(m: matrix[4, 4]f32, d: [3]f32) -> [3]f32 {
	v := m * [4]f32{d.x, d.y, d.z, 0}
	return v.xyz
}

// ============================================================================
// UNDO / REDO HISTORY (MESH & CSG IN CAD SESSION MEMORY CACHE)
// ============================================================================

@(private = "file")
_snapshot_take :: proc() -> Mesh_Snapshot {
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	alloc := runtime.default_allocator()
	s: Mesh_Snapshot
	s.verts      = make([dynamic][3]f32, len(_mesh_ed.verts), alloc)
	copy(s.verts[:], _mesh_ed.verts[:])
	s.face_sizes = make([dynamic]u32, 0, len(_mesh_ed.faces), alloc)
	s.face_inds  = make([dynamic]u32, 0, len(_mesh_ed.faces) * 4, alloc)
	s.face_uvs   = make([dynamic][2]f32, 0, len(_mesh_ed.faces) * 4, alloc)
	s.face_cols  = make([dynamic][4]u8, 0, len(_mesh_ed.faces), alloc)
	for &f in _mesh_ed.faces {
		_ensure_face_uvs(&f)
		append(&s.face_sizes, u32(len(f.verts)))
		append(&s.face_inds, ..f.verts[:])
		append(&s.face_uvs, ..f.uvs[:])
		append(&s.face_cols, f.color)
	}
	s.wire_edges = make([dynamic][2]u32, len(_mesh_ed.wire_edges), alloc)
	copy(s.wire_edges[:], _mesh_ed.wire_edges[:])
	if w := engine.ctx_world(); w != nil && _mesh_ed.target_owner != {} {
		if t := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner)); t != nil {
			s.obj_pos = t.position
		}
	}
	return s
}

@(private = "file")
_snapshot_free :: proc(s: ^Mesh_Snapshot) {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	delete(s.verts)
	delete(s.face_sizes)
	delete(s.face_inds)
	delete(s.face_uvs)
	delete(s.face_cols)
	delete(s.wire_edges)
	s^ = {}
}

@(private = "file")
_snapshot_restore :: proc(s: Mesh_Snapshot, restore_obj_pos: bool) {
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	for &f in _mesh_ed.faces {
		delete(f.verts)
		if f.uvs != nil do delete(f.uvs)
	}
	clear(&_mesh_ed.faces)
	clear(&_mesh_ed.verts)
	clear(&_mesh_ed.wire_edges)
	append(&_mesh_ed.verts, ..s.verts[:])
	off := 0
	for sz, i in s.face_sizes {
		n := int(sz)
		face_uvs: [][2]f32 = nil
		if len(s.face_uvs) >= off + n {
			face_uvs = s.face_uvs[off:off + n]
		}
		_add_poly_face(s.face_inds[off:off + n], s.face_cols[i], uvs = face_uvs)
		off += n
	}
	append(&_mesh_ed.wire_edges, ..s.wire_edges[:])
	_mesh_clear_sub_selection()

	if restore_obj_pos {
		if w := engine.ctx_world(); w != nil && _mesh_ed.target_owner != {} {
			if t := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner)); t != nil {
				t.position = s.obj_pos
			}
		}
	}
}

@(private = "package")
_csg_snapshot_take :: proc(vol: ^cad_csg.CSGVolume) -> CSG_Volume_Snapshot {
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	alloc := runtime.default_allocator()
	s: CSG_Volume_Snapshot
	if vol == nil do return s
	s.owner = engine.Transform_Handle(vol.owner)

	if len(vol.brushes) > 0 {
		s.brushes = make([dynamic]cad_csg.CSG_Brush, len(vol.brushes), alloc)
		for b, i in vol.brushes {
			cb := b
			if len(b.name) > 0 {
				cb.name = strings.clone(b.name, alloc)
			}
			if len(b.profile_points) > 0 {
				cb.profile_points = make([dynamic]cad_csg.CSG_Profile_Point, len(b.profile_points), alloc)
				copy(cb.profile_points[:], b.profile_points[:])
			} else {
				cb.profile_points = nil
			}
			s.brushes[i] = cb
		}
	}
	if len(vol.runtime_hulls) > 0 {
		s.runtime_hulls = make([dynamic]cad_csg.CSG_Convex, 0, len(vol.runtime_hulls), alloc)
		for h in vol.runtime_hulls {
			append(&s.runtime_hulls, cad_csg.convex_clone(h, alloc))
		}
	}
	if len(vol.recorded_blasts) > 0 {
		s.recorded_blasts = make([dynamic]cad_csg.CSG_Recorded_Blast, len(vol.recorded_blasts), alloc)
		copy(s.recorded_blasts[:], vol.recorded_blasts[:])
	}
	if w := engine.ctx_world(); w != nil && s.owner != {} {
		if t := engine.pool_get(&w.transforms, engine.Handle(s.owner)); t != nil {
			s.obj_pos = t.position
		}
	}
	return s
}

@(private = "package")
_csg_snapshot_free :: proc(s: ^CSG_Volume_Snapshot) {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	for &b in s.brushes {
		if len(b.name) > 0 do delete(b.name)
		if b.profile_points != nil do delete(b.profile_points)
	}
	delete(s.brushes)
	for &h in s.runtime_hulls do cad_csg.convex_destroy(&h)
	delete(s.runtime_hulls)
	delete(s.recorded_blasts)
	s^ = {}
}

@(private = "package")
_csg_snapshot_restore :: proc(s: CSG_Volume_Snapshot) {
	w := engine.ctx_world()
	if w == nil || s.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(s.owner)) do return
	_, vol := engine.transform_get_comp(s.owner, cad_csg.CSGVolume)
	if vol == nil do return

	vol_alloc := context.allocator
	for &b in vol.brushes {
		if len(b.name) > 0 do delete(b.name, vol_alloc)
		if b.profile_points != nil do delete(b.profile_points)
	}
	clear(&vol.brushes)
	for b in s.brushes {
		cb := b
		if len(b.name) > 0 do cb.name = strings.clone(b.name, vol_alloc)
		if len(b.profile_points) > 0 {
			cb.profile_points = make([dynamic]cad_csg.CSG_Profile_Point, len(b.profile_points), vol_alloc)
			copy(cb.profile_points[:], b.profile_points[:])
		} else {
			cb.profile_points = nil
		}
		append(&vol.brushes, cb)
	}

	if vol.runtime_hulls != nil {
		for &h in vol.runtime_hulls do cad_csg.convex_destroy(&h)
		clear(&vol.runtime_hulls)
	} else if len(s.runtime_hulls) > 0 {
		vol.runtime_hulls = make([dynamic]cad_csg.CSG_Convex, 0, len(s.runtime_hulls), vol_alloc)
	}
	for h in s.runtime_hulls {
		append(&vol.runtime_hulls, cad_csg.convex_clone(h, vol_alloc))
	}

	clear(&vol.recorded_blasts)
	for rb in s.recorded_blasts {
		append(&vol.recorded_blasts, rb)
	}

	cad_csg.csg_volume_rebuild(vol)
	cad_csg.csg_volume_sync_colliders_only(vol)
	if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
}

@(private = "package")
csg_history_reset :: proc(vol: ^cad_csg.CSGVolume) {
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	for &cs in _mesh_ed.csg_undo_stack do _csg_snapshot_free(&cs)
	clear(&_mesh_ed.csg_undo_stack)
	for &cs in _mesh_ed.csg_redo_stack do _csg_snapshot_free(&cs)
	clear(&_mesh_ed.csg_redo_stack)
	if _mesh_ed.has_csg_committed do _csg_snapshot_free(&_mesh_ed.csg_committed)
	if vol != nil {
		_mesh_ed.csg_committed     = _csg_snapshot_take(vol)
		_mesh_ed.has_csg_committed = true
		_mesh_ed.csg_history_owner = engine.Transform_Handle(vol.owner)
	} else {
		_mesh_ed.has_csg_committed = false
		_mesh_ed.csg_history_owner = {}
	}
}

@(private = "package")
csg_history_ensure_baseline :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil do return
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	owner := engine.Transform_Handle(vol.owner)
	if !_mesh_ed.has_csg_committed || _mesh_ed.csg_history_owner != owner {
		csg_history_reset(vol)
	}
}

@(private = "package")
csg_history_commit :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil do return
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	owner := engine.Transform_Handle(vol.owner)
	if !_mesh_ed.has_csg_committed || _mesh_ed.csg_history_owner != owner {
		csg_history_reset(vol)
		return
	}
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	append(&_mesh_ed.csg_undo_stack, _mesh_ed.csg_committed)
	if len(_mesh_ed.csg_undo_stack) > MESH_EDITOR_UNDO_MAX {
		_csg_snapshot_free(&_mesh_ed.csg_undo_stack[0])
		ordered_remove(&_mesh_ed.csg_undo_stack, 0)
	}
	for &cs in _mesh_ed.csg_redo_stack do _csg_snapshot_free(&cs)
	clear(&_mesh_ed.csg_redo_stack)
	_mesh_ed.csg_committed = _csg_snapshot_take(vol)
}

@(private = "file")
_clear_active_op :: proc() {
	if _mesh_ed.has_op_snap {
		_snapshot_free(&_mesh_ed.op_snap)
		_mesh_ed.has_op_snap = false
	}
	_mesh_ed.active_op   = .None
	_mesh_ed.op_face_idx = -1
}

@(private = "file")
_begin_active_op :: proc(op: Mesh_Active_Op) {
	if _mesh_ed.has_op_snap {
		_snapshot_free(&_mesh_ed.op_snap)
		_mesh_ed.has_op_snap = false
	}
	_mesh_ed.op_snap     = _snapshot_take()
	_mesh_ed.has_op_snap = true
	_mesh_ed.active_op   = op
	_mesh_ed.op_face_idx = _mesh_ed.selected_face
	_mesh_ed.op_edge     = _mesh_ed.selected_edge
}

@(private = "file")
_history_reset :: proc() {
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	_clear_active_op()
	for &s in _mesh_ed.undo_stack do _snapshot_free(&s)
	clear(&_mesh_ed.undo_stack)
	for &s in _mesh_ed.redo_stack do _snapshot_free(&s)
	clear(&_mesh_ed.redo_stack)
	if _mesh_ed.has_committed do _snapshot_free(&_mesh_ed.committed)
	_mesh_ed.committed     = _snapshot_take()
	_mesh_ed.has_committed = true
	_mesh_ed.history_owner = _mesh_ed.target_owner
}

// Called after every finished edit: pushes the previous committed state onto the undo stack.
@(private = "file")
_history_commit :: proc() {
	if !_mesh_ed.cad_cache_active do enter_cad_mode_memory_cache()
	if !_mesh_ed.has_committed || _mesh_ed.history_owner != _mesh_ed.target_owner {
		_history_reset()
		return
	}
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	append(&_mesh_ed.undo_stack, _mesh_ed.committed)
	if len(_mesh_ed.undo_stack) > MESH_EDITOR_UNDO_MAX {
		_snapshot_free(&_mesh_ed.undo_stack[0])
		ordered_remove(&_mesh_ed.undo_stack, 0)
	}
	for &s in _mesh_ed.redo_stack do _snapshot_free(&s)
	clear(&_mesh_ed.redo_stack)
	_mesh_ed.committed = _snapshot_take()
}

mesh_editor_can_undo :: proc() -> bool {
	_ensure_mesh_ed_init()
	if !_mesh_ed.cad_cache_active do return false
	if _mesh_ed.workspace_tab == .CSG_Editor && len(_mesh_ed.csg_undo_stack) > 0 {
		return true
	}
	if _mesh_ed.history_owner == _mesh_ed.target_owner && len(_mesh_ed.undo_stack) > 0 {
		return true
	}
	return len(_mesh_ed.csg_undo_stack) > 0
}

mesh_editor_can_redo :: proc() -> bool {
	_ensure_mesh_ed_init()
	if !_mesh_ed.cad_cache_active do return false
	if _mesh_ed.workspace_tab == .CSG_Editor && len(_mesh_ed.csg_redo_stack) > 0 {
		return true
	}
	if _mesh_ed.history_owner == _mesh_ed.target_owner && len(_mesh_ed.redo_stack) > 0 {
		return true
	}
	return len(_mesh_ed.csg_redo_stack) > 0
}

mesh_editor_undo :: proc() {
	if !mesh_editor_can_undo() do return

	if (_mesh_ed.workspace_tab == .CSG_Editor && len(_mesh_ed.csg_undo_stack) > 0) ||
	   (_mesh_ed.history_owner != _mesh_ed.target_owner || len(_mesh_ed.undo_stack) == 0) {
		if len(_mesh_ed.csg_undo_stack) == 0 do return
		cur := _mesh_ed.csg_committed
		target := pop(&_mesh_ed.csg_undo_stack)
		append(&_mesh_ed.csg_redo_stack, cur)
		_mesh_ed.csg_committed = target
		_csg_snapshot_restore(target)
		return
	}

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	_clear_active_op()
	cur := _mesh_ed.committed
	target := pop(&_mesh_ed.undo_stack)
	append(&_mesh_ed.redo_stack, cur)
	_mesh_ed.committed = target
	_snapshot_restore(target, target.obj_pos != cur.obj_pos)
	_rebuild_editable_mesh_gpu(commit = false)
	_evaluate_mesh_csg_compliance()
}

mesh_editor_redo :: proc() {
	if !mesh_editor_can_redo() do return

	if (_mesh_ed.workspace_tab == .CSG_Editor && len(_mesh_ed.csg_redo_stack) > 0) ||
	   (_mesh_ed.history_owner != _mesh_ed.target_owner || len(_mesh_ed.redo_stack) == 0) {
		if len(_mesh_ed.csg_redo_stack) == 0 do return
		cur := _mesh_ed.csg_committed
		target := pop(&_mesh_ed.csg_redo_stack)
		append(&_mesh_ed.csg_undo_stack, cur)
		_mesh_ed.csg_committed = target
		_csg_snapshot_restore(target)
		return
	}

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	_clear_active_op()
	cur := _mesh_ed.committed
	target := pop(&_mesh_ed.redo_stack)
	append(&_mesh_ed.undo_stack, cur)
	_mesh_ed.committed = target
	_snapshot_restore(target, target.obj_pos != cur.obj_pos)
	_rebuild_editable_mesh_gpu(commit = false)
	_evaluate_mesh_csg_compliance()
}

// Real source location of each CAD sub-tool's implementation, for Right-Click -> "Jump to Tool Script"
// (used by the Scene3D Tools bar so its jump targets never go stale).
tool_impl_location :: proc(tool: CAD_Sub_Tool) -> runtime.Source_Code_Location {
	switch tool {
	case .Spline_Poly_Sketch: return #location(_update_and_draw_spline_sketch_tool)
	case .Box_Primitive:      return #location(_update_and_draw_box_primitive_tool)
	case .Face_Push_Pull:     return #location(_update_and_draw_face_push_pull)
	case .Geo_Mod_Blast:      return #location(_update_and_draw_blast_tool)
	case .Clip_Brush_Plane:   return #location(_update_and_draw_clip_plane_tool)
	case .Soft_Deform_Brush:  return #location(_update_and_draw_soft_deform_brush_tool)
	case .Draw_Glass_Poly:    return #location(_update_and_draw_glass_poly_tool)
	}
	return #location(_update_and_draw_spline_sketch_tool)
}

// ============================================================================
// PUBLIC QUERIES USED BY THE SCENE VIEW (picking, hotkeys, Edit menu routing)
// ============================================================================

// True when Scene3D is in CAD Mode -> Mesh Editor in a sub-object mode (Vertex / Edge / Face):
// the scene view then routes Delete / Undo / 1-2-3 to the mesh editor and hides the whole-object transform gizmo.
// When `_mesh_ed.select_mode == .Object`, returns `false` so Scene3D's standard Q/E/R object gizmo transforms the whole mesh!
mesh_editor_owns_viewport :: proc() -> bool {
	_ensure_mesh_ed_init()
	if control_rig_ed.scene_viewport_mode != .CAD_Blockout || _mesh_ed.workspace_tab != .Mesh_Editor do return false
	if _mesh_ed.select_mode == .Object && !_mesh_ed.wire_draw_mode && !_mesh_ed.pivot_edit && !_mesh_ed.show_cutter_box_gizmo {
		return false
	}
	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) do return false
	return len(_mesh_ed.verts) > 0 || _mesh_ed.wire_draw_mode
}

// True while the pointer is over a vertex / edge / face of the edited mesh (or a sub-object drag is active)
// so the scene view does not click-through-select other objects.
mesh_editor_wants_mouse :: proc() -> bool {
	if !mesh_editor_owns_viewport() do return false
	return _mesh_ed.hover_any || _mesh_ed.gizmo_dragging || _mesh_ed.face_extrude_dragging || _mesh_ed.face_inset_dragging || _mesh_ed.cutter_gizmo_dragging || _mesh_ed.wire_draw_mode
}

mesh_editor_has_sub_selection :: proc() -> bool {
	_ensure_mesh_ed_init()
	switch _mesh_ed.select_mode {
	case .Vertex: return len(_mesh_ed.selected_verts) > 0
	case .Edge:   return _mesh_ed.has_selected_edge
	case .Face:   return _mesh_ed.selected_face >= 0 || len(_mesh_ed.sel_faces) > 0
	case .Object: return false
	}
	return false
}

@(private = "package")
_mesh_clear_sub_selection :: proc() {
	clear(&_mesh_ed.selected_verts)
	clear(&_mesh_ed.sel_faces)
	_mesh_ed.selected_face     = -1
	_mesh_ed.has_selected_edge = false
}

@(private = "file")
_face_is_selected :: proc(fi: int) -> bool {
	if fi == _mesh_ed.selected_face do return true
	for sf in _mesh_ed.sel_faces do if sf == fi do return true
	return false
}

// Deletes the selected vertices' faces / the selected edge's faces / the selected faces, then
// compacts unused vertices. Routed from `Edit -> Delete` (Delete key) while the mesh editor owns Scene3D.
mesh_editor_delete_selection :: proc() {
	_ensure_mesh_ed_init()
	if !mesh_editor_has_sub_selection() do return
	_clear_active_op()
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	kill := make([]bool, len(_mesh_ed.faces), context.temp_allocator)
	for f, fi in _mesh_ed.faces {
		switch _mesh_ed.select_mode {
		case .Vertex:
			outer: for vi in f.verts {
				for sv in _mesh_ed.selected_verts do if sv == vi { kill[fi] = true; break outer }
			}
		case .Edge:
			m := len(f.verts)
			for i in 0 ..< m {
				u, v := f.verts[i], f.verts[(i + 1) % m]
				e := _mesh_ed.selected_edge
				if (u == e[0] && v == e[1]) || (u == e[1] && v == e[0]) { kill[fi] = true; break }
			}
		case .Face:
			kill[fi] = _face_is_selected(fi)
		case .Object:
		}
	}
	// Also drop wireframe edges touching deleted vertices in Vertex mode
	if _mesh_ed.select_mode == .Vertex {
		for i := len(_mesh_ed.wire_edges) - 1; i >= 0; i -= 1 {
			e := _mesh_ed.wire_edges[i]
			for sv in _mesh_ed.selected_verts {
				if sv == e[0] || sv == e[1] { ordered_remove(&_mesh_ed.wire_edges, i); break }
			}
		}
	}
	for fi := len(_mesh_ed.faces) - 1; fi >= 0; fi -= 1 {
		if kill[fi] {
			delete(_mesh_ed.faces[fi].verts)
			ordered_remove(&_mesh_ed.faces, fi)
		}
	}
	_compact_unused_verts()
	_mesh_clear_sub_selection()
	_rebuild_editable_mesh_gpu()
}

// Removes vertices referenced by no face and no wireframe edge, remapping all indices.
@(private = "package")
_compact_unused_verts :: proc() {
	used := make([]bool, len(_mesh_ed.verts), context.temp_allocator)
	for f in _mesh_ed.faces do for vi in f.verts do if int(vi) < len(used) do used[vi] = true
	for e in _mesh_ed.wire_edges {
		if int(e[0]) < len(used) do used[e[0]] = true
		if int(e[1]) < len(used) do used[e[1]] = true
	}
	remap := make([]u32, len(_mesh_ed.verts), context.temp_allocator)
	n := 0
	for i in 0 ..< len(_mesh_ed.verts) {
		if used[i] {
			_mesh_ed.verts[n] = _mesh_ed.verts[i]
			remap[i] = u32(n)
			n += 1
		}
	}
	resize(&_mesh_ed.verts, n)
	for &f in _mesh_ed.faces do for &vi in f.verts do vi = remap[vi]
	for &e in _mesh_ed.wire_edges {
		e[0] = remap[e[0]]
		e[1] = remap[e[1]]
	}
}

// Moves the owner's origin (pivot) to `new_world` while keeping the geometry (and child objects)
// exactly where they are in the world.
@(private = "package")
_mesh_set_origin_world :: proc(new_world: [3]f32, commit := true) {
	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} do return
	t := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner))
	if t == nil do return

	_, inv := _mesh_model()
	cur_world := engine.transform_world(_mesh_ed.target_owner).position
	local_off := _xf_vec(inv, new_world - cur_world)

	kids := make([dynamic]Mesh_Child_Pos, 0, len(t.children), context.temp_allocator)
	for c in t.children {
		ch := engine.Transform_Handle(c.handle)
		if engine.pool_valid(&w.transforms, c.handle) {
			append(&kids, Mesh_Child_Pos{ch, engine.transform_world(ch).position})
		}
	}
	for &v in _mesh_ed.verts do v -= local_off
	engine.transform_set_world_position(_mesh_ed.target_owner, new_world)
	for k in kids do engine.transform_set_world_position(k.tH, k.pos)
	_rebuild_editable_mesh_gpu(commit = commit)
}

@(private = "package")
_mesh_geometry_world_bounds :: proc() -> (lo, hi, center: [3]f32, ok: bool) {
	if len(_mesh_ed.verts) == 0 do return
	m, _ := _mesh_model()
	for v, i in _mesh_ed.verts {
		p := _xf_point(m, v)
		if i == 0 { lo = p; hi = p } else { lo = linalg.min(lo, p); hi = linalg.max(hi, p) }
	}
	return lo, hi, (lo + hi) * 0.5, true
}

@(private = "package")
_mesh_selection_world_center :: proc() -> (c: [3]f32, ok: bool) {
	m, _ := _mesh_model()
	ids := make([dynamic]u32, 0, 16, context.temp_allocator)
	_collect_active_verts(&ids)
	if len(ids) == 0 do return
	for vi in ids do c += _xf_point(m, _mesh_ed.verts[vi])
	return c / f32(len(ids)), true
}

// Unique vertex indices affected by the current sub-object selection
@(private = "package")
_collect_active_verts :: proc(out: ^[dynamic]u32) {
	seen := make(map[u32]bool, 16, context.temp_allocator)
	add :: proc(out: ^[dynamic]u32, seen: ^map[u32]bool, vi: u32) {
		if int(vi) >= len(_mesh_ed.verts) || vi in seen do return
		seen[vi] = true
		append(out, vi)
	}
	switch _mesh_ed.select_mode {
	case .Vertex:
		for vi in _mesh_ed.selected_verts do add(out, &seen, vi)
	case .Edge:
		if _mesh_ed.has_selected_edge {
			add(out, &seen, _mesh_ed.selected_edge[0])
			add(out, &seen, _mesh_ed.selected_edge[1])
		}
	case .Face:
		if _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) {
			for vi in _mesh_ed.faces[_mesh_ed.selected_face].verts do add(out, &seen, vi)
		}
		for fi in _mesh_ed.sel_faces {
			if fi >= 0 && fi < len(_mesh_ed.faces) {
				for vi in _mesh_ed.faces[fi].verts do add(out, &seen, vi)
			}
		}
	case .Object:
	}
}

// Returns true when the mouse is over the Left-Side Slide-Out Drawer in Scene3D
// so viewport click-to-pick does not click through the drawer UI.
left_drawer_wants_mouse :: proc() -> bool {
	return _mesh_ed.drawer_hovered
}

// Returns true when Scene3D is currently in `CAD_Blockout` viewport mode.
is_in_cad_mode :: proc() -> bool {
	_sync_viewport_mode()
	return control_rig_ed.scene_viewport_mode == .CAD_Blockout
}

// Keybinding query helpers backed by `cad_csg.csg_settings` (configurable in Project Settings & CAD Panel)
are_cad_hotkeys_enabled :: proc() -> bool {
	return cad_csg.csg_settings.enable_all_keybindings
}

are_transform_tool_hotkeys_enabled :: proc() -> bool {
	return cad_csg.csg_settings.enable_all_keybindings && cad_csg.csg_settings.enable_transform_tool_hotkeys
}

are_subtool_number_hotkeys_enabled :: proc() -> bool {
	return cad_csg.csg_settings.enable_all_keybindings && cad_csg.csg_settings.enable_subtool_number_hotkeys
}

are_axis_lock_hotkeys_enabled :: proc() -> bool {
	return cad_csg.csg_settings.enable_all_keybindings && cad_csg.csg_settings.enable_axis_lock_hotkeys
}

are_modeling_op_hotkeys_enabled :: proc() -> bool {
	return cad_csg.csg_settings.enable_all_keybindings && cad_csg.csg_settings.enable_modeling_op_hotkeys
}


active_workspace_tab :: proc() -> CAD_Workspace_Tab {
	_ensure_mesh_ed_init()
	return _mesh_ed.workspace_tab
}

set_workspace_tab :: proc(tab: CAD_Workspace_Tab) {
	_ensure_mesh_ed_init()
	_mesh_ed.workspace_tab = tab
	control_rig_ed.scene_viewport_mode = .CAD_Blockout
	_ed.prev_viewport_mode = .CAD_Blockout
	if tab == .Mesh_Editor {
		// In Mesh Editor mode, disable CSG drawing sub-tool so sub-object mesh gizmos own the viewport
		_ed.tool_active = false
		_sync_mesh_editor_with_selection()
	}
}

active_axis_constraint :: proc() -> Axis_Constraint {
	_ensure_mesh_ed_init()
	return _mesh_ed.axis_lock
}

set_axis_constraint :: proc(axis: Axis_Constraint) {
	_ensure_mesh_ed_init()
	if _mesh_ed.axis_lock == axis {
		_mesh_ed.axis_lock = .Free
	} else {
		_mesh_ed.axis_lock = axis
	}
}

// ============================================================================
// EDITABLE POLYGON MESH MANAGEMENT & PROCEDURAL GPU SYNC
// ============================================================================

@(private = "package")
_clear_editable_mesh :: proc() {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	for &f in _mesh_ed.faces {
		delete(f.verts)
		if f.uvs != nil do delete(f.uvs)
	}
	clear(&_mesh_ed.faces)
	clear(&_mesh_ed.verts)
	clear(&_mesh_ed.wire_edges)
	clear(&_mesh_ed.selected_verts)
	clear(&_mesh_ed.sel_faces)
	_mesh_ed.wire_last_vert = -1
	_mesh_ed.has_selected_edge = false
	_mesh_ed.selected_face = -1
	_mesh_ed.report_dirty = true
}

@(private = "package")
_add_wire_edge :: proc(u, v: u32) {
	if u == v do return
	a := min(u, v)
	b := max(u, v)
	for e in _mesh_ed.wire_edges {
		if min(e[0], e[1]) == a && max(e[0], e[1]) == b do return
	}
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	append(&_mesh_ed.wire_edges, [2]u32{u, v})
}

@(private = "package")
_face_normal_and_center_of_indices :: proc(indices: []u32) -> (normal: [3]f32, center: [3]f32) {
	n := len(indices)
	if n < 3 do return {0, 1, 0}, {0, 0, 0}
	for idx in indices {
		if int(idx) < len(_mesh_ed.verts) {
			center += _mesh_ed.verts[idx]
		}
	}
	center /= f32(n)

	nx, ny, nz: f32
	for i in 0 ..< n {
		ia := indices[i]
		ib := indices[(i + 1) % n]
		if int(ia) >= len(_mesh_ed.verts) || int(ib) >= len(_mesh_ed.verts) do continue
		va := _mesh_ed.verts[ia]
		vb := _mesh_ed.verts[ib]
		nx += (va.y - vb.y) * (va.z + vb.z)
		ny += (va.z - vb.z) * (va.x + vb.x)
		nz += (va.x - vb.x) * (va.y + vb.y)
	}
	normal = linalg.normalize0([3]f32{nx, ny, nz})
	if linalg.length2(normal) < 1e-6 {
		normal = {0, 1, 0}
	}
	return
}

@(private = "package")
_ensure_face_uvs :: proc(f: ^Editable_Poly_Face) {
	if f == nil do return
	n := len(f.verts)
	if len(f.uvs) == n do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	fn, _ := _face_normal_and_center(f^)
	u_ax, v_ax := cad_csg.plane_tangent_basis(fn)
	resize(&f.uvs, n)
	for vi, idx in f.verts {
		if int(vi) < len(_mesh_ed.verts) {
			p := _mesh_ed.verts[vi]
			f.uvs[idx] = [2]f32{linalg.dot(p, u_ax) * 0.5, linalg.dot(p, v_ax) * 0.5}
		}
	}
}

@(private = "package")
_add_poly_face :: proc(indices: []u32, col: [4]u8 = {196, 210, 230, 255}, uvs: [][2]f32 = nil) {
	if len(indices) < 3 do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	v_list := make([dynamic]u32, len(indices))
	copy(v_list[:], indices)
	uv_list := make([dynamic][2]f32, len(indices))
	if uvs != nil && len(uvs) == len(indices) {
		copy(uv_list[:], uvs)
	} else {
		fn, _ := _face_normal_and_center_of_indices(indices)
		u_ax, v_ax := cad_csg.plane_tangent_basis(fn)
		for vi, idx in indices {
			if int(vi) < len(_mesh_ed.verts) {
				p := _mesh_ed.verts[vi]
				uv_list[idx] = [2]f32{linalg.dot(p, u_ax) * 0.5, linalg.dot(p, v_ax) * 0.5}
			}
		}
	}
	append(&_mesh_ed.faces, Editable_Poly_Face{
		verts = v_list,
		uvs   = uv_list,
		color = col,
	})
}

@(private = "package")
_face_normal_and_center :: proc(f: Editable_Poly_Face) -> (normal: [3]f32, center: [3]f32) {
	n := len(f.verts)
	if n < 3 do return {0, 1, 0}, {0, 0, 0}
	for idx in f.verts {
		if int(idx) < len(_mesh_ed.verts) {
			center += _mesh_ed.verts[idx]
		}
	}
	center /= f32(n)

	// Newell's method for robust polygon normal on triangles, quads, and N-gons
	nx, ny, nz: f32
	for i in 0 ..< n {
		ia := f.verts[i]
		ib := f.verts[(i + 1) % n]
		if int(ia) >= len(_mesh_ed.verts) || int(ib) >= len(_mesh_ed.verts) do continue
		va := _mesh_ed.verts[ia]
		vb := _mesh_ed.verts[ib]
		nx += (va.y - vb.y) * (va.z + vb.z)
		ny += (va.z - vb.z) * (va.x + vb.x)
		nz += (va.x - vb.x) * (va.y + vb.y)
	}
	normal = linalg.normalize0([3]f32{nx, ny, nz})
	if linalg.length2(normal) < 1e-6 {
		normal = {0, 1, 0}
	}
	return
}

@(private = "package")
_mesh_centroid :: proc() -> [3]f32 {
	if len(_mesh_ed.verts) == 0 do return {0, 0, 0}
	sum: [3]f32
	for v in _mesh_ed.verts do sum += v
	return sum / f32(len(_mesh_ed.verts))
}

// Uploads the current `Editable_Poly_Mesh` to `target_owner`'s `MeshFilter` via `engine.mesh_upsert_procedural`.
// `commit = true` (finished edit): records an Undo step and refreshes the `Mesh -> CSG` compliance report.
// `commit = false` (live gizmo drag frame): GPU upload only, so dragging stays fast on big meshes.
@(private = "package")
_rebuild_editable_mesh_gpu :: proc(commit := true) {
	_mesh_ed.report_dirty = true
	if commit {
		_evaluate_mesh_csg_compliance()
		_history_commit()
	}

	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) {
		return
	}

	_, mf := engine.transform_get_comp(_mesh_ed.target_owner, engine.MeshFilter)
	if mf == nil {
		_, ptr := engine.transform_add_comp(_mesh_ed.target_owner, .MeshFilter)
		mf = cast(^engine.MeshFilter)ptr
	}
	_, mr := engine.transform_get_comp(_mesh_ed.target_owner, engine.MeshRenderer)
	if mr == nil {
		_, ptr := engine.transform_add_comp(_mesh_ed.target_owner, .MeshRenderer)
		mr = cast(^engine.MeshRenderer)ptr
	}
	if mr != nil {
		mr.enabled = true
	}
	// If this entity also has a CSGVolume component from a previous Mesh->CSG conversion,
	// keep CSGVolume disabled while editing its MeshRenderer so chunks don't double-render!
	if _, csg_vol := engine.transform_get_comp(_mesh_ed.target_owner, cad_csg.CSGVolume); csg_vol != nil && csg_vol.enabled {
		cad_csg.csg_volume_free_runtime(csg_vol)
		csg_vol.enabled = false
	}

	if engine.asset_guid_is_empty(_mesh_ed.mesh_guid) {
		_mesh_ed.mesh_guid = cad_csg.make_procedural_guid(_mesh_ed.target_owner, 0x4D45_5348)
	}

	gpu_verts := make([dynamic]gfx.Vertex, 0, len(_mesh_ed.faces) * 4, context.temp_allocator)
	gpu_inds  := make([dynamic]u32, 0, len(_mesh_ed.faces) * 6, context.temp_allocator)

	col_u8 := [4]u8{
		u8(clamp(_mesh_ed.mesh_color.r * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.g * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.b * 255.0, 0, 255)),
		255,
	}

	for &f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		_ensure_face_uvs(&f)
		fn, _ := _face_normal_and_center(f)
		base_v := u32(len(gpu_verts))
		for vi, corner_i in f.verts {
			if int(vi) >= len(_mesh_ed.verts) do continue
			pos := _mesh_ed.verts[vi]
			uv := f.uvs[corner_i] if corner_i < len(f.uvs) else [2]f32{0, 0}
			append(&gpu_verts, gfx.Vertex{
				position = pos,
				normal   = fn,
				uv       = uv,
				color    = col_u8,
			})
		}
		tri_n := u32(len(f.verts) - 2)
		for t in 0 ..< tri_n {
			append(&gpu_inds, base_v, base_v + t + 1, base_v + t + 2)
		}
	}

	if len(gpu_verts) >= 3 && len(gpu_inds) >= 3 {
		engine.mesh_upsert_procedural(_mesh_ed.mesh_guid, gpu_verts[:], gpu_inds[:], nil, keep_cpu_buffers = true)
		if mf != nil {
			mf.mesh = engine.PPtr{guid = _mesh_ed.mesh_guid, local_id = 0}
		}
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Creates or selects an Editable CAD Mesh GameObject with the chosen Unreal Modeling Mode / AutoCAD primitive:
// `0` = Box, `1` = Cylinder, `2` = Wedge Ramp, `3` = Pyramid/Cone, `4` = Non-Compliant Test Mesh,
// `5` = UV Sphere, `6` = Torus, `7` = Linear Stairs, `8` = AutoCAD 3D Car Wireframe & Chassis Blockout!
spawn_editable_cad_mesh :: proc(preset: int) {
	_ensure_mesh_ed_init()
	scene := engine.sm_scene_get_active()
	w := engine.ctx_world()
	if scene == nil || w == nil do return

	root_h := engine.Transform_Handle(scene.root.handle)
	preset_names := [9]string{
		"CAD_Mesh_Box",
		"CAD_Mesh_Cylinder",
		"CAD_Mesh_Wedge",
		"CAD_Mesh_Cone",
		"CAD_Mesh_NonCompliant_Test",
		"CAD_Mesh_Sphere",
		"CAD_Mesh_Torus",
		"CAD_Mesh_Stairs",
		"CAD_Car_Wireframe_Chassis",
	}
	name := preset_names[clamp(preset, 0, 8)]

	new_h := engine.transform_new(name, root_h)
	engine.transform_ensure_unique_name(new_h)
	if t := engine.pool_get(&w.transforms, engine.Handle(new_h)); t != nil {
		t.position = {0, 1.0, 0}
	}
	_, _ = engine.transform_add_comp(new_h, .MeshFilter)
	_, _ = engine.transform_add_comp(new_h, .MeshRenderer)

	_mesh_ed.target_owner = new_h
	_mesh_ed.mesh_guid = cad_csg.make_procedural_guid(new_h, 0x4D45_5348)
	_clear_editable_mesh()

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	hx := max(_mesh_ed.shape_dims.x * 0.5, 0.25)
	hy := max(_mesh_ed.shape_dims.y * 0.5, 0.25)
	hz := max(_mesh_ed.shape_dims.z * 0.5, 0.25)
	sub_n := clamp(_mesh_ed.shape_subdivs, 6, 24)

	switch preset {
	case 0: // Box
		append(&_mesh_ed.verts,
			[3]f32{-hx, -hy, -hz}, // 0
			[3]f32{ hx, -hy, -hz}, // 1
			[3]f32{ hx,  hy, -hz}, // 2
			[3]f32{-hx,  hy, -hz}, // 3
			[3]f32{-hx, -hy,  hz}, // 4
			[3]f32{ hx, -hy,  hz}, // 5
			[3]f32{ hx,  hy,  hz}, // 6
			[3]f32{-hx,  hy,  hz}, // 7
		)
		_add_poly_face({3, 7, 6, 2}) // Top (+Y)
		_add_poly_face({0, 1, 5, 4}) // Bottom (-Y)
		_add_poly_face({4, 5, 6, 7}) // Front (+Z)
		_add_poly_face({0, 3, 2, 1}) // Back (-Z)
		_add_poly_face({1, 2, 6, 5}) // Right (+X)
		_add_poly_face({0, 4, 7, 3}) // Left (-X)
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 2 // Select Front (+Z) face by default for immediate Extrude / Tunnel

	case 1: // Parametric Cylinder
		n := sub_n
		r := max(hx, hz)
		for i in 0 ..< n {
			ang := f32(i) * (2.0 * math.PI / f32(n))
			append(&_mesh_ed.verts, [3]f32{math.cos(ang) * r, -hy, math.sin(ang) * r})
		}
		for i in 0 ..< n {
			ang := f32(i) * (2.0 * math.PI / f32(n))
			append(&_mesh_ed.verts, [3]f32{math.cos(ang) * r, hy, math.sin(ang) * r})
		}
		top_cap := make([dynamic]u32, n, context.temp_allocator)
		bot_cap := make([dynamic]u32, n, context.temp_allocator)
		for i in 0 ..< n {
			top_cap[i] = u32(n + (n - 1 - i))
			bot_cap[i] = u32(i)
			next := (i + 1) % n
			_add_poly_face({u32(i), u32(n + i), u32(n + next), u32(next)})
		}
		_add_poly_face(top_cap[:])
		_add_poly_face(bot_cap[:])
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = n

	case 2: // Wedge / Ramp
		append(&_mesh_ed.verts,
			[3]f32{-hx, -hy, -hz}, // 0
			[3]f32{ hx, -hy, -hz}, // 1
			[3]f32{ hx, -hy,  hz}, // 2
			[3]f32{-hx, -hy,  hz}, // 3
			[3]f32{-hx,  hy, -hz}, // 4
			[3]f32{ hx,  hy, -hz}, // 5
		)
		_add_poly_face({0, 3, 2, 1}) // Bottom (-Y)
		_add_poly_face({0, 1, 5, 4}) // Back (-Z)
		_add_poly_face({3, 4, 5, 2}) // Sloped Ramp
		_add_poly_face({0, 4, 3})    // Left Triangle (-X)
		_add_poly_face({1, 2, 5})    // Right Triangle (+X)
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 2

	case 3: // Pyramid / Cone
		n := clamp(sub_n, 4, 16)
		r := max(hx, hz)
		base_ring := make([dynamic]u32, n, context.temp_allocator)
		for i in 0 ..< n {
			ang := f32(i) * (2.0 * math.PI / f32(n))
			base_ring[i] = u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, [3]f32{math.cos(ang) * r, -hy, math.sin(ang) * r})
		}
		apex := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, [3]f32{0, hy, 0})
		_add_poly_face(base_ring[:])
		for i in 0 ..< n {
			next := (i + 1) % n
			_add_poly_face({base_ring[next], base_ring[i], apex})
		}
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 1

	case 4: // Non-Compliant Mesh (Missing Top Face = Open Hole + Pushed-In Concave Vertex!)
		append(&_mesh_ed.verts,
			[3]f32{-hx, -hy, -hz}, // 0
			[3]f32{ hx, -hy, -hz}, // 1
			[3]f32{ hx,  hy, -hz}, // 2
			[3]f32{-hx,  hy, -hz}, // 3
			[3]f32{-hx, -hy,  hz}, // 4
			[3]f32{ hx, -hy,  hz}, // 5
			[3]f32{ hx,  hy,  hz}, // 6
			[3]f32{-hx,  hy,  hz}, // 7
			[3]f32{ 0.0, 0.0, 0.25}, // 8: Interior concave spike vertex!
		)
		_add_poly_face({0, 4, 5, 1}) // Bottom (-Y)
		_add_poly_face({0, 1, 2, 3}) // Back (-Z)
		_add_poly_face({1, 5, 6, 2}) // Right (+X)
		_add_poly_face({0, 3, 7, 4}) // Left (-X)
		_add_poly_face({4, 7, 8})
		_add_poly_face({7, 6, 8})
		_add_poly_face({6, 5, 8})
		_add_poly_face({5, 4, 8})
		_mesh_ed.selected_face = 0

	case 5: // UV Sphere
		rings := 6
		segs  := clamp(sub_n, 8, 16)
		r     := max(hx, hy)
		bot_v := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, [3]f32{0, -r, 0})
		for ri in 1 ..< rings {
			phi := -math.PI * 0.5 + f32(ri) * (math.PI / f32(rings))
			y   := math.sin(phi) * r
			rc  := math.cos(phi) * r
			for si in 0 ..< segs {
				theta := f32(si) * (2.0 * math.PI / f32(segs))
				append(&_mesh_ed.verts, [3]f32{math.cos(theta) * rc, y, math.sin(theta) * rc})
			}
		}
		top_v := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, [3]f32{0, r, 0})
		for si in 0 ..< segs {
			next := (si + 1) % segs
			_add_poly_face({bot_v, u32(1 + next), u32(1 + si)})
		}
		for ri in 0 ..< rings - 2 {
			r0 := u32(1 + ri * segs)
			r1 := u32(1 + (ri + 1) * segs)
			for si in 0 ..< segs {
				next := u32((si + 1) % segs)
				s0 := u32(si)
				_add_poly_face({r0 + s0, r0 + next, r1 + next, r1 + s0})
			}
		}
		last_r := u32(1 + (rings - 2) * segs)
		for si in 0 ..< segs {
			next := u32((si + 1) % segs)
			_add_poly_face({last_r + u32(si), last_r + next, top_v})
		}
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 0

	case 6: // Torus Ring (Analytical outward normals pointing away from minor tube centerline)
		maj_n := clamp(sub_n, 8, 16)
		min_n := 6
		R     := max(hx, 1.1)
		r_tub := max(hy * 0.35, 0.32)
		for i in 0 ..< maj_n {
			u_ang := f32(i) * (2.0 * math.PI / f32(maj_n))
			cu, su := math.cos(u_ang), math.sin(u_ang)
			for j in 0 ..< min_n {
				v_ang := f32(j) * (2.0 * math.PI / f32(min_n))
				cv, sv := math.cos(v_ang), math.sin(v_ang)
				rad := R + r_tub * cv
				append(&_mesh_ed.verts, [3]f32{cu * rad, r_tub * sv, su * rad})
			}
		}
		for i in 0 ..< maj_n {
			ni := (i + 1) % maj_n
			for j in 0 ..< min_n {
				nj := (j + 1) % min_n
				v00 := u32(i * min_n + j)
				v10 := u32(ni * min_n + j)
				v11 := u32(ni * min_n + nj)
				v01 := u32(i * min_n + nj)
				// Outward CCW winding around tube surface `(v01 -> v11 -> v10 -> v00)`
				_add_poly_face({v01, v11, v10, v00})
			}
		}
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 0

	case 7: // Linear Stairs (Unreal Modeling Mode `LinStair`)
		steps := 5
		w_x   := hx
		tot_y := hy * 2.0
		tot_z := hz * 2.0
		step_h := tot_y / f32(steps)
		step_d := tot_z / f32(steps)
		for s_i in 0 ..< steps {
			z0 := -hz + f32(s_i) * step_d
			z1 := z0 + step_d
			y_top := -hy + f32(s_i + 1) * step_h
			y_bot := -hy
			b := u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts,
				[3]f32{-w_x, y_bot, z0}, [3]f32{ w_x, y_bot, z0},
				[3]f32{ w_x, y_top, z0}, [3]f32{-w_x, y_top, z0},
				[3]f32{-w_x, y_bot, z1}, [3]f32{ w_x, y_bot, z1},
				[3]f32{ w_x, y_top, z1}, [3]f32{-w_x, y_top, z1},
			)
			_add_poly_face({b + 3, b + 2, b + 6, b + 7}) // Tread (+Y)
			_add_poly_face({b + 0, b + 1, b + 2, b + 3}) // Riser (-Z)
			_add_poly_face({b + 4, b + 7, b + 6, b + 5}) // Back (+Z)
			_add_poly_face({b + 0, b + 4, b + 5, b + 1}) // Base (-Y)
			_add_poly_face({b + 1, b + 5, b + 6, b + 2}) // Right (+X)
			_add_poly_face({b + 0, b + 3, b + 7, b + 4}) // Left (-X)
		}
		mesh_op_weld_vertices(0.01)
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 0

	case 8: // AutoCAD 3D Car / Coupe Wireframe Cage & Polygon Chassis!
		// Side profile loop (8 vertices in YZ plane, extruded symmetrically to -X and +X with greenhouse cabin taper):
		// 0: Front lower chin, 1: Front bumper nose, 2: Hood/Windshield base, 3: Roof front header,
		// 4: Roof rear header, 5: Rear deck/trunk base, 6: Rear tail panel, 7: Rear lower diffuser
		profile_yz := [8][2]f32{
			{-0.45, -2.15}, // 0: Front chin
			{ 0.12, -2.20}, // 1: Front nose
			{ 0.28, -0.85}, // 2: Windshield base
			{ 0.88, -0.25}, // 3: Front roof
			{ 0.86,  0.85}, // 4: Rear roof
			{ 0.34,  1.45}, // 5: Trunk base
			{ 0.25,  2.15}, // 6: Rear tail
			{-0.45,  2.05}, // 7: Rear underbody
		}
		for side in 0 ..< 2 {
			sgn_x: f32 = -1.0 if side == 0 else 1.0
			for p, pi in profile_yz {
				// Cabin roof (indices 3, 4) tapers slightly inward like a real car greenhouse!
				half_w: f32 = 0.96 if (pi != 3 && pi != 4) else 0.78
				append(&_mesh_ed.verts, [3]f32{sgn_x * half_w, p[0], p[1]})
			}
		}
		// Record explicit AutoCAD 3D Wireframe Cage edges AND polygon body faces!
		for i in 0 ..< 8 {
			next := (i + 1) % 8
			l0, l1 := u32(i), u32(next)
			r0, r1 := u32(8 + i), u32(8 + next)
			_add_wire_edge(l0, l1)
			_add_wire_edge(r0, r1)
			_add_wire_edge(l0, r0)
			// Centerline quad strip (bumper, hood, windshield, roof, rear window, trunk, rear valence, floor)
			_add_poly_face({l0, r0, r1, l1})
		}
		// Left (-X) and Right (+X) body side panels (split into Front Fender, Cabin Door/Window, Rear Quarter)
		_add_poly_face({0, 1, 2, 7})
		_add_poly_face({7, 2, 5, 6})
		_add_poly_face({2, 3, 4, 5})
		_add_poly_face({8 + 0, 8 + 7, 8 + 2, 8 + 1})
		_add_poly_face({8 + 7, 8 + 6, 8 + 5, 8 + 2})
		_add_poly_face({8 + 2, 8 + 5, 8 + 4, 8 + 3})
		mesh_op_recalculate_outward_normals()
		_mesh_ed.selected_face = 2 // Select Windshield / Cabin face by default
	}

	_rebuild_editable_mesh_gpu(commit = false)
	_history_reset()
	engine.inspector_request_select(new_h)
}

// Raycast all scene `MeshFilter` entities (and the active `_mesh_ed` Editable Poly Mesh) so the
// Extrude (`3`) tool can directly hover, extrude (+Out), and intrude (-In) any polygon mesh face!
@(private = "package")
_raycast_scene_poly_mesh_for_extrude :: proc(ray: engine.Ray) -> (hit_tH: engine.Transform_Handle, hit_face_idx: int, hit_t: f32, hit_pos: [3]f32, hit_norm: [3]f32, ok: bool) {
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	if w == nil do return {}, -1, 0, {}, {}, false

	// Ensure active selection (if it has a MeshFilter and not a CSGVolume) is synced into `_mesh_ed`
	sel := engine.inspector_active_selection()
	if sel != {} && engine.pool_valid(&w.transforms, engine.Handle(sel)) {
		if _, has_csg := engine.transform_get_comp(sel, cad_csg.CSGVolume); has_csg == nil {
			if _, mf := engine.transform_get_comp(sel, engine.MeshFilter); mf != nil {
				_sync_mesh_editor_with_selection()
			}
		}
	}

	// If `_mesh_ed.target_owner` is valid AND does NOT have an active `CSGVolume` (and has an enabled `MeshRenderer`),
	// test its exact `Editable_Poly_Face` polygons first!
	if _mesh_ed.target_owner != {} && engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) && len(_mesh_ed.faces) > 0 {
		if _, csg_v := engine.transform_get_comp(_mesh_ed.target_owner, cad_csg.CSGVolume); csg_v != nil && csg_v.enabled {
			return {}, -1, 0, {}, {}, false
		}
		if _, mr := engine.transform_get_comp(_mesh_ed.target_owner, engine.MeshRenderer); mr == nil || !mr.enabled {
			return {}, -1, 0, {}, {}, false
		}
		tw := engine.transform_world(_mesh_ed.target_owner)
		origin := tw.position
		best_t := max(f32)
		best_fi := -1
		for poly_f, fi in _mesh_ed.faces {
			m := len(poly_f.verts)
			if m < 3 do continue
			v0 := origin + _mesh_ed.verts[poly_f.verts[0]]
			for ti in 1 ..< m - 1 {
				v1 := origin + _mesh_ed.verts[poly_f.verts[ti]]
				v2 := origin + _mesh_ed.verts[poly_f.verts[ti + 1]]
				if tt, th := _ray_triangle_intersect(ray, v0, v1, v2); th && tt < best_t {
					best_t = tt
					best_fi = fi
				}
			}
		}
		if best_fi >= 0 {
			fn, _ := _face_normal_and_center(_mesh_ed.faces[best_fi])
			return _mesh_ed.target_owner, best_fi, best_t, ray.origin + ray.direction * best_t, fn, true
		}
	}
	return {}, -1, 0, {}, {}, false
}

// Returns true if `ring` covers >= 88% of the mesh's 2D cross-section perpendicular to `axis_n`
// (meaning `ring` is a full outer wall face rather than an already-inset inner face).
@(private = "package")
_face_ring_covers_full_cross_section :: proc(ring: [][3]f32, axis_n: [3]f32) -> bool {
	if len(ring) < 3 || len(_mesh_ed.verts) < 4 do return false
	u_ax, v_ax := cad_csg.plane_tangent_basis(linalg.normalize0(axis_n))
	m_umin, m_umax := f32(1e9), f32(-1e9)
	m_vmin, m_vmax := f32(1e9), f32(-1e9)
	for v in _mesh_ed.verts {
		u := linalg.dot(v, u_ax)
		vv := linalg.dot(v, v_ax)
		m_umin = min(m_umin, u); m_umax = max(m_umax, u)
		m_vmin = min(m_vmin, vv); m_vmax = max(m_vmax, vv)
	}
	r_umin, r_umax := f32(1e9), f32(-1e9)
	r_vmin, r_vmax := f32(1e9), f32(-1e9)
	for v in ring {
		u := linalg.dot(v, u_ax)
		vv := linalg.dot(v, v_ax)
		r_umin = min(r_umin, u); r_umax = max(r_umax, u)
		r_vmin = min(r_vmin, vv); r_vmax = max(r_vmax, vv)
	}
	m_uspan := max(m_umax - m_umin, 1e-4)
	m_vspan := max(m_vmax - m_vmin, 1e-4)
	return (r_umax - r_umin) >= m_uspan * 0.88 && (r_vmax - r_vmin) >= m_vspan * 0.88
}

// Starts a live interactive 3D mouse-drag Extrude/Intrude on polygon face `face_idx` of `poly_tH`:
// - Captures `_mesh_ed.pre_extrude_snap` once BEFORE adding vertices/faces so live drag frames never spam Undo
//   and inward pocket/tunnel drags can cleanly restore the pre-drag mesh before boolean subtraction!
// - Creates a new topological face ring (inset by `inset_override` or `_ed.extrude_inset_margin` if > 0.01)
// - Stitches quad side walls around the ring
// - Records `_ed.push_poly_ring_verts` & `_ed.push_poly_base_pos` so dragging the mouse pulls the face
//   outward (Extrude) or pushes it inward (Intrude / Carve Tunnel) along `ax_dir`!
@(private = "package")
_begin_poly_face_interactive_extrude :: proc(
	poly_tH:        engine.Transform_Handle,
	face_idx:       int,
	hit_p:          [3]f32,
	face_n:         [3]f32,
	ax_dir:         [3]f32,
	ray:            engine.Ray,
	inset_override: f32 = -1.0,
) {
	if face_idx < 0 || face_idx >= len(_mesh_ed.faces) do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	orig_f := _mesh_ed.faces[face_idx]
	m := len(orig_f.verts)
	if m < 3 do return

	// Save pristine pre-extrude snapshot BEFORE modifying `_mesh_ed.verts` or `_mesh_ed.faces`!
	if _mesh_ed.has_pre_extrude_snap {
		_snapshot_free(&_mesh_ed.pre_extrude_snap)
	}
	_mesh_ed.pre_extrude_snap     = _snapshot_take()
	_mesh_ed.has_pre_extrude_snap = true

	fn_local, center := _face_normal_and_center(orig_f)
	_mesh_ed.extrude_orig_norm_loc = fn_local
	clear(&_mesh_ed.extrude_orig_ring_loc)
	for vi in orig_f.verts {
		append(&_mesh_ed.extrude_orig_ring_loc, _mesh_ed.verts[vi])
	}

	raw_inset := inset_override if inset_override >= 0.0 else _ed.extrude_inset_margin
	inset_t := clamp(raw_inset, 0.0, 0.75)

	old_ring := make([]u32, m, context.temp_allocator)
	copy(old_ring, orig_f.verts[:])
	start_ring := make([]u32, m, context.temp_allocator)
	new_ring   := make([]u32, m, context.temp_allocator)

	clear(&_ed.push_poly_ring_verts)
	clear(&_ed.push_poly_base_pos)

	// If `inset_t > 0.01`, first create a flat inset border ring on the original face plane
	// so the surrounding wall stays flat and the extruded/intruded walls go straight at 90 degrees!
	if inset_t > 0.01 {
		for i in 0 ..< m {
			old_v := _mesh_ed.verts[old_ring[i]]
			base_v := linalg.lerp(old_v, center, inset_t)
			ins_idx := u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, base_v)
			start_ring[i] = ins_idx
		}
		for i in 0 ..< m {
			next := (i + 1) % m
			_add_poly_face({old_ring[i], old_ring[next], start_ring[next], start_ring[i]}, orig_f.color)
		}
	} else {
		copy(start_ring, old_ring)
	}

	for i in 0 ..< m {
		base_v := _mesh_ed.verts[start_ring[i]]
		new_idx := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, base_v)
		new_ring[i] = new_idx
		append(&_ed.push_poly_ring_verts, new_idx)
		append(&_ed.push_poly_base_pos, base_v)
	}

	// Update cap face to `new_ring` and stitch quad side walls connecting `start_ring` -> `new_ring`
	for i in 0 ..< m {
		_mesh_ed.faces[face_idx].verts[i] = new_ring[i]
	}
	for i in 0 ..< m {
		next := (i + 1) % m
		_add_poly_face({start_ring[i], start_ring[next], new_ring[next], new_ring[i]}, orig_f.color)
	}
	// Upload preview to GPU without committing an intermediate Undo step!
	_rebuild_editable_mesh_gpu(commit = false)

	_mesh_ed.selected_face   = face_idx
	_ed.push_active          = true
	_ed.push_is_poly_mesh    = true
	_ed.push_poly_face_idx   = face_idx
	_ed.push_world_origin    = hit_p
	_ed.push_world_normal    = linalg.normalize0(face_n)
	_ed.push_drag_axis_world = ax_dir
	_ed.push_start_s         = _ray_closest_dist_along_axis(ray, _ed.push_world_origin, _ed.push_drag_axis_world)
	_ed.push_current_delta   = 0
	_ed.num_len              = 0
	engine.inspector_request_select(poly_tH)
}

// Cancels an in-progress interactive Face Extrude/Intrude drag and restores `_mesh_ed.pre_extrude_snap`.
@(private = "package")
_cancel_poly_face_interactive_extrude :: proc() {
	if _mesh_ed.has_pre_extrude_snap {
		_snapshot_restore(_mesh_ed.pre_extrude_snap, false)
		_snapshot_free(&_mesh_ed.pre_extrude_snap)
		_mesh_ed.has_pre_extrude_snap = false
		_rebuild_editable_mesh_gpu(commit = false)
		_evaluate_mesh_csg_compliance()
	}
	_ed.push_active = false
	_mesh_ed.face_extrude_dragging = false
}

// Called when an interactive polygon-mesh Face Extrude/Intrude finishes (`!lmb_down` or Enter):
// - If `abs(delta) < 0.015`: restores `_mesh_ed.pre_extrude_snap` so clicking a face without dragging never leaves duplicate vertices!
// - If `delta < -0.015` (pushed inward): restores `_mesh_ed.pre_extrude_snap` and performs an exact 3D Boolean Prism Subtraction
//   (auto-insetting if the face covered the full outer wall cross-section, and punching a clean open through-tunnel if it reaches the opposite side!).
// - If `delta >= 0.015` (pulled outward): commits a single Undo step!
@(private = "package")
_finish_poly_face_interactive_extrude :: proc(delta: f32) {
	defer {
		if _mesh_ed.has_pre_extrude_snap {
			_snapshot_free(&_mesh_ed.pre_extrude_snap)
			_mesh_ed.has_pre_extrude_snap = false
		}
	}

	if abs(delta) < 0.015 || len(_ed.push_poly_base_pos) < 3 {
		if _mesh_ed.has_pre_extrude_snap {
			sel_fi := _ed.push_poly_face_idx
			_snapshot_restore(_mesh_ed.pre_extrude_snap, false)
			if sel_fi >= 0 && sel_fi < len(_mesh_ed.faces) {
				_mesh_ed.selected_face = sel_fi
			}
			_rebuild_editable_mesh_gpu(commit = false)
		}
		return
	}

	if delta < -0.015 && _mesh_ed.has_pre_extrude_snap {
		// Copy base ring before restoring snapshot
		ring_pts := make([][3]f32, len(_ed.push_poly_base_pos), context.temp_allocator)
		copy(ring_pts, _ed.push_poly_base_pos[:])

		_, inv := _mesh_model()
		n_dir := linalg.normalize0(_mesh_ed.extrude_orig_norm_loc)
		if linalg.length2(n_dir) < 0.5 do n_dir = linalg.normalize0(_xf_vec(inv, _ed.push_world_normal))
		drag_axis_loc := linalg.normalize0(_xf_vec(inv, _ed.push_drag_axis_world))
		if linalg.length2(drag_axis_loc) < 0.5 do drag_axis_loc = n_dir

		// Restore the pristine pre-extrude mesh before boolean carving!
		_snapshot_restore(_mesh_ed.pre_extrude_snap, false)

		// If `ring_pts` covers the full outer cross-section of the mesh (because `extrude_inset_margin` was 0 on a full wall face),
		// automatically inset `ring_pts` by `clamp(_mesh_ed.inset_amount, 0.20, 0.45)` so it carves a hollow tunnel or pocket with walls!
		if _face_ring_covers_full_cross_section(ring_pts, n_dir) {
			rc: [3]f32
			for p in ring_pts do rc += p
			rc /= f32(len(ring_pts))
			auto_ins := clamp(_mesh_ed.inset_amount, 0.20, 0.45)
			for &p in ring_pts {
				p = linalg.lerp(p, rc, auto_ins)
			}
		}

		base_c: [3]f32
		for p in ring_pts do base_c += p
		base_c /= f32(len(ring_pts))
		pushed_d := linalg.dot(n_dir, base_c + drag_axis_loc * delta)

		min_mesh_d := max(f32)
		max_mesh_d := -max(f32)
		for v in _mesh_ed.verts {
			d := linalg.dot(n_dir, v)
			min_mesh_d = min(min_mesh_d, d)
			max_mesh_d = max(max_mesh_d, d)
		}

		is_through_tunnel := (pushed_d <= min_mesh_d + 0.18)
		carve_delta := delta
		if is_through_tunnel {
			// Ensure tunnel cutter extends all the way through the mesh thickness!
			mesh_thick := max(max_mesh_d - min_mesh_d, abs(delta))
			carve_delta = -max(abs(delta), mesh_thick + 0.25)
		}
		_carve_poly_prism_tunnel(ring_pts, n_dir, drag_axis_loc, carve_delta, extend_exit = is_through_tunnel)
		return
	}

	// Outward extrusion (`delta >= 0.015`): commit a single Undo step!
	_rebuild_editable_mesh_gpu(commit = true)
}

// Converts the currently active `CSGVolume` in place into an `Editable_Poly_Mesh` and switches to `Mesh_Editor` mode!
convert_active_csg_to_editable_mesh :: proc() -> engine.Transform_Handle {
	_ensure_mesh_ed_init()
	vol, owner := _resolve_active_volume(create_if_missing = false)
	if vol == nil || owner == {} do return {}
	if !vol.compiled {
		cad_csg.csg_volume_rebuild(vol)
	}
	unified_hulls := make([dynamic]cad_csg.CSG_Convex, 0, 32, context.temp_allocator)
	for _, ch in vol.chunks {
		if ch == nil do continue
		if ch.voxel_grid != nil && len(ch.voxel_grid.base_shell_hulls) > 0 {
			for h in ch.voxel_grid.base_shell_hulls {
				if len(h.planes) >= 4 do append(&unified_hulls, cad_csg.convex_clone(h, context.temp_allocator))
			}
			for h in ch.indestructible_hulls {
				if len(h.planes) >= 4 do append(&unified_hulls, cad_csg.convex_clone(h, context.temp_allocator))
			}
		} else {
			for h in ch.destructible_hulls {
				if len(h.planes) >= 4 do append(&unified_hulls, cad_csg.convex_clone(h, context.temp_allocator))
			}
			for h in ch.indestructible_hulls {
				if len(h.planes) >= 4 do append(&unified_hulls, cad_csg.convex_clone(h, context.temp_allocator))
			}
		}
	}
	if len(unified_hulls) == 0 && len(vol.runtime_hulls) > 0 {
		for h in vol.runtime_hulls {
			if len(h.planes) >= 4 do append(&unified_hulls, cad_csg.convex_clone(h, context.temp_allocator))
		}
	}
	if len(unified_hulls) == 0 do return {}

	_ = cad_csg.csg_clean_and_simplify_hulls(&unified_hulls, context.temp_allocator)
	_mesh_ed.load_error = ""
	_mesh_ed.target_owner = owner
	_mesh_ed.mesh_guid = cad_csg.make_procedural_guid(owner, 0x4D45_5348)
	_rebuild_editable_mesh_from_csg_hulls(unified_hulls[:])
	_history_reset()
	_mesh_ed.workspace_tab = .Mesh_Editor
	_ed.tool_active = false
	engine.inspector_set_active_selection(owner)
	engine.inspector_request_select(owner)
	return owner
}

// Loads any selected `MeshFilter` or `CSGVolume` entity into the Editable Poly Mesh buffers (welding shared vertices)
@(private = "package")
_sync_mesh_editor_with_selection :: proc() {
	w := engine.ctx_world()
	if w == nil do return
	sel := engine.inspector_active_selection()
	if sel == {} || !engine.pool_valid(&w.transforms, engine.Handle(sel)) do return
	@(static) last_failed: engine.Transform_Handle

	// If multiple objects are selected via Ctrl+Click in Scene3D / Hierarchy and our current `target_owner`
	// is still part of the multi-selection, keep `target_owner` as Target Mesh A (so its Undo history and
	// active edit state are preserved!) and record the newly clicked object as Tool Mesh B (`bool_target_b`).
	all_sel := engine.inspector_selection_all()
	if len(all_sel) > 1 && _mesh_ed.target_owner != {} &&
	   engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) && len(_mesh_ed.verts) > 0 {
		target_still_selected := false
		for sh in all_sel {
			if sh == _mesh_ed.target_owner {
				target_still_selected = true
			} else if sh != {} && engine.pool_valid(&w.transforms, engine.Handle(sh)) {
				_mesh_ed.bool_target_b = sh
			}
		}
		if target_still_selected {
			return
		}
	}

	// 1. If `sel` has an enabled `CSGVolume` (or `Faker CSG`), NEVER auto-convert or disable `csg_vol`!
	//    (`CSGVolume` -> `Editable_Poly_Mesh` conversion happens ONLY when explicitly clicking `convert_active_csg_to_editable_mesh`).
	if _, csg_vol := engine.transform_get_comp(sel, cad_csg.CSGVolume); csg_vol != nil && csg_vol.enabled {
		if _mesh_ed.target_owner == sel {
			_clear_editable_mesh()
			_mesh_ed.target_owner = {}
		}
		return
	}

	if sel == _mesh_ed.target_owner && len(_mesh_ed.verts) > 0 do return
	if sel == last_failed do return // don't re-read a mesh that failed to load every frame

	_, mf := engine.transform_get_comp(sel, engine.MeshFilter)
	if mf == nil {
		_mesh_ed.load_error = "Selected object has no MeshFilter or CSGVolume - select a mesh/CSG, or spawn a shape from the drawer."
		last_failed = sel
		return
	}

	cpu_verts, cpu_inds, ok := engine.mesh_read_cpu_geometry(mf, context.temp_allocator)
	if !ok || len(cpu_verts) < 3 || len(cpu_inds) < 3 {
		_mesh_ed.load_error = "Could not read this mesh's CPU geometry (mesh asset missing or not imported yet)."
		last_failed = sel
		return
	}
	if len(cpu_inds) / 3 > MESH_EDITOR_MAX_TRIS {
		@(static) err_buf: [192]u8
		_mesh_ed.load_error = fmt.bprintf(err_buf[:], "Mesh too dense for the poly editor (%d tris > %d). Decimate it first.", len(cpu_inds) / 3, MESH_EDITOR_MAX_TRIS)
		last_failed = sel
		return
	}
	last_failed = {}
	_mesh_ed.load_error = ""

	_mesh_ed.target_owner = sel
	_mesh_ed.mesh_guid = cad_csg.make_procedural_guid(sel, 0x4D45_5348)
	_clear_editable_mesh()

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	// Weld coincident vertices (UV / normal seams) from triangle soup into an indexed topological mesh.
	// Hashed on a 1mm grid so loading stays O(n) even for dense imported meshes.
	Weld_Key :: [3]i32
	weld := make(map[Weld_Key]u32, len(cpu_verts), context.temp_allocator)
	remap := make([]u32, len(cpu_verts), context.temp_allocator)
	for v, i in cpu_verts {
		k := Weld_Key{i32(math.round(v.position.x * 1000)), i32(math.round(v.position.y * 1000)), i32(math.round(v.position.z * 1000))}
		if existing, found := weld[k]; found {
			remap[i] = existing
		} else {
			idx := u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, v.position)
			weld[k] = idx
			remap[i] = idx
		}
	}

	tri_count := len(cpu_inds) / 3
	for t in 0 ..< tri_count {
		raw0 := cpu_inds[t * 3 + 0]
		raw1 := cpu_inds[t * 3 + 1]
		raw2 := cpu_inds[t * 3 + 2]
		i0 := remap[raw0]
		i1 := remap[raw1]
		i2 := remap[raw2]
		if i0 == i1 || i1 == i2 || i2 == i0 do continue
		uvs_tri := [3][2]f32{cpu_verts[raw0].uv, cpu_verts[raw1].uv, cpu_verts[raw2].uv}
		_add_poly_face({i0, i1, i2}, uvs = uvs_tri[:])
	}

	// Merge coplanar adjacent triangles into clean convex N-gon / Quad faces and dissolve pointless collinear vertices!
	if len(_mesh_ed.faces) <= 3000 {
		_merge_coplanar_triangles()
		_compact_unused_vertices()
	}
	_evaluate_mesh_csg_compliance()
	_history_reset()
}

// Checks whether an indexed face loop `loop` with normal `normal` is strictly convex and free of duplicate indices.
@(private = "package")
_is_face_loop_convex :: proc(loop: []u32, normal: [3]f32) -> bool {
	n := len(loop)
	if n < 3 do return false
	for i in 0 ..< n {
		if int(loop[i]) >= len(_mesh_ed.verts) do return false
		for j in i + 1 ..< n {
			if loop[i] == loop[j] || linalg.length2(_mesh_ed.verts[loop[i]] - _mesh_ed.verts[loop[j]]) < 1e-5 {
				return false
			}
		}
	}
	for i in 0 ..< n {
		va := _mesh_ed.verts[loop[(i - 1 + n) % n]]
		vb := _mesh_ed.verts[loop[i]]
		vc := _mesh_ed.verts[loop[(i + 1) % n]]
		e1 := linalg.normalize0(vb - va)
		e2 := linalg.normalize0(vc - vb)
		if linalg.dot(linalg.cross(e1, e2), normal) < -1e-4 {
			return false
		}
	}
	return true
}

// Dissolves consecutive duplicate indices and collinear degree-2 vertices inside a single face loop `loop`.
@(private = "package")
_dissolve_collinear_verts_in_loop :: proc(loop: ^[dynamic]u32) {
	if loop == nil || len(loop) < 3 do return
	changed := true
	guard := 16
	for changed && len(loop) >= 3 && guard > 0 {
		changed = false
		guard -= 1
		for i := 0; i < len(loop) && len(loop) >= 3; {
			next := (i + 1) % len(loop)
			if loop[i] == loop[next] || linalg.length2(_mesh_ed.verts[loop[i]] - _mesh_ed.verts[loop[next]]) <= 1e-5 {
				ordered_remove(loop, next)
				changed = true
			} else {
				i += 1
			}
		}
		if len(loop) < 3 do break
		for i := 0; i < len(loop) && len(loop) >= 3; {
			n := len(loop)
			prev := _mesh_ed.verts[loop[(i - 1 + n) % n]]
			curr := _mesh_ed.verts[loop[i]]
			next := _mesh_ed.verts[loop[(i + 1) % n]]
			e1 := curr - prev
			e2 := next - curr
			l1 := linalg.length(e1)
			l2 := linalg.length(e2)
			if l1 <= 1e-4 || l2 <= 1e-4 || linalg.dot(e1 / l1, e2 / l2) > 0.9992 {
				ordered_remove(loop, i)
				changed = true
			} else {
				i += 1
			}
		}
	}
}

// Removes all unused/orphan vertices from `_mesh_ed.verts` that are not referenced by any face or wireframe edge,
// remapping all face and wireframe vertex indices cleanly.
@(private = "package")
_compact_unused_vertices :: proc() -> (removed_verts: int) {
	vn := len(_mesh_ed.verts)
	if vn == 0 do return 0

	used := make([]bool, vn, context.temp_allocator)
	for f in _mesh_ed.faces {
		for vi in f.verts {
			if int(vi) < vn do used[vi] = true
		}
	}
	for we in _mesh_ed.wire_edges {
		if int(we[0]) < vn do used[we[0]] = true
		if int(we[1]) < vn do used[we[1]] = true
	}

	kept_count := 0
	for u in used {
		if u do kept_count += 1
	}
	if kept_count == vn do return 0

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	remap := make([]u32, vn, context.temp_allocator)
	new_verts := make([dynamic][3]f32, 0, kept_count)
	for v, i in _mesh_ed.verts {
		if used[i] {
			remap[i] = u32(len(new_verts))
			append(&new_verts, v)
		}
	}
	delete(_mesh_ed.verts)
	_mesh_ed.verts = new_verts

	for &f in _mesh_ed.faces {
		for &vi in f.verts {
			if int(vi) < vn do vi = remap[vi]
		}
	}
	for &we in _mesh_ed.wire_edges {
		if int(we[0]) < vn do we[0] = remap[we[0]]
		if int(we[1]) < vn do we[1] = remap[we[1]]
	}
	clear(&_mesh_ed.selected_verts)
	return vn - kept_count
}

// Stitches T-junctions between coplanar faces and dissolves pointless miter-seam vertices on straight outer edges.
@(private = "package")
_stitch_and_miter_clean_coplanar_faces :: proc() {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	// 1. Stitch T-junctions on coplanar faces
	for i in 0 ..< len(_mesh_ed.faces) {
		fa := &_mesh_ed.faces[i]
		if len(fa.verts) < 3 do continue
		na, ca := _face_normal_and_center(fa^)
		for j in 0 ..< len(_mesh_ed.faces) {
			if i == j do continue
			fb := _mesh_ed.faces[j]
			if len(fb.verts) < 3 do continue
			nb, cb := _face_normal_and_center(fb)
			if linalg.dot(na, nb) < 0.9995 || abs(linalg.dot(na, cb - ca)) > 0.003 do continue

			for vk_idx in fb.verts {
				already := false
				for va_idx in fa.verts {
					if va_idx == vk_idx { already = true; break }
				}
				if already do continue
				vk := _mesh_ed.verts[vk_idx]
				for e := 0; e < len(fa.verts); e += 1 {
					va := _mesh_ed.verts[fa.verts[e]]
					vb := _mesh_ed.verts[fa.verts[(e + 1) % len(fa.verts)]]
					ab := vb - va
					ab_len2 := linalg.length2(ab)
					if ab_len2 < 1e-4 do continue
					t := linalg.dot(vk - va, ab) / ab_len2
					if t <= 0.01 || t >= 0.99 do continue
					if linalg.length2(vk - (va + ab * t)) <= 2.5e-5 {
						inject_at(&fa.verts, e + 1, vk_idx)
						break
					}
				}
			}
		}
	}

	// 2. Dissolve 2-face coplanar miter seam vertices (pivots vertical T-seams into corner-to-corner miters!)
	changed := true
	guard := 64
	for changed && guard > 0 {
		changed = false
		guard -= 1
		outer_m: for f1_idx in 0 ..< len(_mesh_ed.faces) {
			f1 := &_mesh_ed.faces[f1_idx]
			n1 := len(f1.verts)
			if n1 < 4 do continue
			norm1, c1 := _face_normal_and_center(f1^)

			for k1 in 0 ..< n1 {
				vi := f1.verts[k1]
				ref_count := 0
				f2_idx := -1
				k2_found := -1
				for fj_idx in 0 ..< len(_mesh_ed.faces) {
					fj := _mesh_ed.faces[fj_idx]
					for vj, kj in fj.verts {
						if vj == vi {
							ref_count += 1
							if fj_idx != f1_idx {
								f2_idx = fj_idx
								k2_found = kj
							}
							break
						}
					}
					if ref_count > 2 do break
				}
				if ref_count != 2 || f2_idx < 0 do continue

				f2 := &_mesh_ed.faces[f2_idx]
				n2 := len(f2.verts)
				if n2 < 3 do continue
				norm2, c2 := _face_normal_and_center(f2^)
				if linalg.dot(norm1, norm2) < 0.9995 || abs(linalg.dot(norm1, c2 - c1)) > 0.003 do continue

				prev1 := f1.verts[(k1 - 1 + n1) % n1]
				next1 := f1.verts[(k1 + 1) % n1]
				prev2 := f2.verts[(k2_found - 1 + n2) % n2]
				next2 := f2.verts[(k2_found + 1) % n2]

				if prev1 == next2 && next1 != prev2 {
					prev_prev1 := f1.verts[(k1 - 2 + n1) % n1]
					dir_in  := linalg.normalize0(_mesh_ed.verts[prev1] - _mesh_ed.verts[prev_prev1])
					dir_out := linalg.normalize0(_mesh_ed.verts[vi] - _mesh_ed.verts[prev1])
					if linalg.dot(dir_in, dir_out) > 0.995 {
						vc := next1
						cand1 := make([dynamic]u32, 0, n1 - 1)
						for m in 0 ..< n1 {
							if m != k1 do append(&cand1, f1.verts[m])
						}
						cand2 := make([dynamic]u32, n2)
						copy(cand2[:], f2.verts[:])
						cand2[k2_found] = vc
						if _is_face_loop_convex(cand1[:], norm1) && _is_face_loop_convex(cand2[:], norm2) {
							delete(f1.verts)
							delete(f2.verts)
							f1.verts = cand1
							f2.verts = cand2
							changed = true
							break outer_m
						}
						delete(cand1)
						delete(cand2)
					}
				} else if next1 == prev2 && prev1 != next2 {
					next_next1 := f1.verts[(k1 + 2) % n1]
					dir_in  := linalg.normalize0(_mesh_ed.verts[next1] - _mesh_ed.verts[vi])
					dir_out := linalg.normalize0(_mesh_ed.verts[next_next1] - _mesh_ed.verts[next1])
					if linalg.dot(dir_in, dir_out) > 0.995 {
						vc := prev1
						cand1 := make([dynamic]u32, 0, n1 - 1)
						for m in 0 ..< n1 {
							if m != k1 do append(&cand1, f1.verts[m])
						}
						cand2 := make([dynamic]u32, n2)
						copy(cand2[:], f2.verts[:])
						cand2[k2_found] = vc
						if _is_face_loop_convex(cand1[:], norm1) && _is_face_loop_convex(cand2[:], norm2) {
							delete(f1.verts)
							delete(f2.verts)
							f1.verts = cand1
							f2.verts = cand2
							changed = true
							break outer_m
						}
						delete(cand1)
						delete(cand2)
					}
				}
			}
		}
	}

	// 3. Stitch any remaining T-junctions across ALL faces (including perpendicular pillar/slab junctions!)
	for i in 0 ..< len(_mesh_ed.faces) {
		fa := &_mesh_ed.faces[i]
		if len(fa.verts) < 3 do continue
		for j in 0 ..< len(_mesh_ed.faces) {
			if i == j do continue
			fb := _mesh_ed.faces[j]
			if len(fb.verts) < 3 do continue
			for vk_idx in fb.verts {
				already := false
				for va_idx in fa.verts {
					if va_idx == vk_idx { already = true; break }
				}
				if already do continue
				vk := _mesh_ed.verts[vk_idx]
				for e := 0; e < len(fa.verts); e += 1 {
					va := _mesh_ed.verts[fa.verts[e]]
					vb := _mesh_ed.verts[fa.verts[(e + 1) % len(fa.verts)]]
					ab := vb - va
					ab_len2 := linalg.length2(ab)
					if ab_len2 < 1e-4 do continue
					t := linalg.dot(vk - va, ab) / ab_len2
					if t <= 0.01 || t >= 0.99 do continue
					if linalg.length2(vk - (va + ab * t)) <= 2.5e-5 {
						inject_at(&fa.verts, e + 1, vk_idx)
						break
					}
				}
			}
		}
	}

	// 4. Chord-split any face that still contains a 180-degree collinear stitched T-junction vertex
	//    into strictly convex quads/triangles with 0 collinear vertices and 0 open boundary edges!
	is_loop_collinear_at :: proc(loop: []u32, idx: int) -> (bool, [3]f32) {
		n := len(loop)
		if n < 4 do return false, {}
		prev := _mesh_ed.verts[loop[(idx - 1 + n) % n]]
		curr := _mesh_ed.verts[loop[idx]]
		next := _mesh_ed.verts[loop[(idx + 1) % n]]
		e1 := linalg.normalize0(curr - prev)
		e2 := linalg.normalize0(next - curr)
		if linalg.dot(e1, e2) > 0.999 {
			return true, linalg.normalize0(next - prev)
		}
		return false, {}
	}

	split_any := true
	split_guard := 128
	for split_any && split_guard > 0 {
		split_any = false
		split_guard -= 1
		for fi := 0; fi < len(_mesh_ed.faces); fi += 1 {
			f := _mesh_ed.faces[fi]
			n := len(f.verts)
			if n < 4 do continue

			col_k := -1
			edge_dir: [3]f32
			for k in 0 ..< n {
				if ok, ed := is_loop_collinear_at(f.verts[:], k); ok {
					col_k = k
					edge_dir = ed
					break
				}
			}
			if col_k < 0 do continue

			vk := _mesh_ed.verts[f.verts[col_k]]
			best_m := -1
			best_score := f32(-1e9)
			for m in 0 ..< n {
				if m == col_k || m == (col_k + 1) % n || m == (col_k - 1 + n) % n do continue
				vm := _mesh_ed.verts[f.verts[m]]
				chord := vm - vk
				clen := linalg.length(chord)
				if clen <= 1e-3 do continue
				cdir := chord / clen
				align := abs(linalg.dot(cdir, edge_dir))
				if align > 0.96 do continue

				score := (1.0 - align) * 10.0
				if ok_m, _ := is_loop_collinear_at(f.verts[:], m); ok_m {
					score += 5.0
				}
				if score > best_score {
					best_score = score
					best_m = m
				}
			}
			if best_m < 0 do continue

			poly_a := make([dynamic]u32, 0, n)
			for idx := col_k; ; idx = (idx + 1) % n {
				append(&poly_a, f.verts[idx])
				if idx == best_m do break
			}
			poly_b := make([dynamic]u32, 0, n)
			for idx := best_m; ; idx = (idx + 1) % n {
				append(&poly_b, f.verts[idx])
				if idx == col_k do break
			}

			if len(poly_a) >= 3 && len(poly_b) >= 3 {
				delete(_mesh_ed.faces[fi].verts)
				_mesh_ed.faces[fi].verts = poly_a
				append(&_mesh_ed.faces, Editable_Poly_Face{verts = poly_b, color = f.color})
				split_any = true
				break
			} else {
				delete(poly_a)
				delete(poly_b)
			}
		}
	}
}

@(private = "package")
_merge_coplanar_triangles :: proc() {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	// 1. Remove any internal opposite-facing or duplicate buried faces (two faces with identical vertex sets)
	for i := 0; i < len(_mesh_ed.faces); i += 1 {
		fa := _mesh_ed.faces[i]
		na := len(fa.verts)
		if na < 3 do continue
		removed_pair := false
		for j := i + 1; j < len(_mesh_ed.faces); j += 1 {
			fb := _mesh_ed.faces[j]
			if len(fb.verts) != na do continue
			matches := 0
			for va in fa.verts {
				for vb in fb.verts {
					if va == vb { matches += 1; break }
				}
			}
			if matches == na {
				n_a, _ := _face_normal_and_center(fa)
				n_b, _ := _face_normal_and_center(fb)
				delete(_mesh_ed.faces[j].verts)
				ordered_remove(&_mesh_ed.faces, j)
				if linalg.dot(n_a, n_b) < -0.5 {
					// Opposite-facing internal seam pair -> remove BOTH faces!
					delete(_mesh_ed.faces[i].verts)
					ordered_remove(&_mesh_ed.faces, i)
					i -= 1
					removed_pair = true
				}
				break
			}
		}
		if removed_pair do continue
	}

	// 2. Greedily merge coplanar adjacent faces whenever their combined polygon (after dissolving collinear edge vertices) is strictly convex!
	merged := true
	guard := 128
	for merged && guard > 0 {
		merged = false
		guard -= 1
		outer: for i := 0; i < len(_mesh_ed.faces); i += 1 {
			fa := _mesh_ed.faces[i]
			na := len(fa.verts)
			if na < 3 do continue
			n_a, c_a := _face_normal_and_center(fa)

			for j := i + 1; j < len(_mesh_ed.faces); j += 1 {
				fb := _mesh_ed.faces[j]
				nb := len(fb.verts)
				if nb < 3 do continue
				n_b, c_b := _face_normal_and_center(fb)
				if linalg.dot(n_a, n_b) < 0.9995 do continue
				if abs(linalg.dot(n_a, c_b - c_a)) > 0.003 do continue

				// Check if fa and fb share a directed edge (u->v in fa, v->u in fb)
				for ea in 0 ..< na {
					u := fa.verts[ea]
					v := fa.verts[(ea + 1) % na]
					for eb in 0 ..< nb {
						if fb.verts[eb] == v && fb.verts[(eb + 1) % nb] == u {
							// Build combined face loop and immediately dissolve collinear midpoint vertices!
							comb := make([dynamic]u32, 0, na + nb - 2)
							for k in 0 ..< na - 1 {
								append(&comb, fa.verts[(ea + 1 + k) % na])
							}
							for k in 0 ..< nb - 1 {
								append(&comb, fb.verts[(eb + 1 + k) % nb])
							}
							_dissolve_collinear_verts_in_loop(&comb)
							if len(comb) >= 3 && _is_face_loop_convex(comb[:], n_a) {
								delete(_mesh_ed.faces[i].verts)
								delete(_mesh_ed.faces[j].verts)
								_mesh_ed.faces[i].verts = comb
								ordered_remove(&_mesh_ed.faces, j)
								merged = true
								break outer
							}
							delete(comb)
						}
					}
				}
			}
		}
	}

	// 3. Stitch coplanar T-junctions and dissolve miter seam vertices on outer edges
	_stitch_and_miter_clean_coplanar_faces()
}

// Smart Mesh Simplifier & Pointless Vertex / Coplanar Polygon Cleaner (`Simplify / Clean Mesh`):
// 1. Welds close vertices within tolerance,
// 2. Culls buried opposite-facing internal seam faces,
// 3. Merges coplanar adjacent faces into clean convex quads/N-gons,
// 4. Dissolves pointless collinear vertices & T-junction seam points along straight edges,
// 5. Purges all unused/orphan vertices!
mesh_op_simplify_and_clean_mesh :: proc() {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.verts) < 3 || len(_mesh_ed.faces) == 0 do return
	mesh_op_weld_vertices(max(_mesh_ed.weld_distance, 0.004), commit = false)
	for &f in _mesh_ed.faces {
		_dissolve_collinear_verts_in_loop(&f.verts)
	}
	_merge_coplanar_triangles()
	_compact_unused_vertices()
	_rebuild_editable_mesh_gpu()
}

// ============================================================================
// BLENDER / FREECAD MESH EDITING OPERATIONS
// ============================================================================

// Extrudes the selected Face (or Edge) by `distance` meters along the face normal
// (or along the active Blender-style `X`, `Y`, `Z` Axis Lock!).
// If `distance < -0.02` on a Face, routes through `mesh_op_intrude_selected_face` so inward extrusions
// always carve clean boolean pockets or through-tunnels without self-intersecting walls!
mesh_op_extrude_selected :: proc(distance: f32, commit := true) {
	_ensure_mesh_ed_init()
	if _mesh_ed.select_mode == .Face && distance < -0.02 {
		mesh_op_intrude_selected_face(abs(distance), _mesh_ed.inset_amount)
		return
	}

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	dir := [3]f32{0, 1, 0}
	if _mesh_ed.axis_lock == .X do dir = {1, 0, 0}
	if _mesh_ed.axis_lock == .Y do dir = {0, 1, 0}
	if _mesh_ed.axis_lock == .Z do dir = {0, 0, 1}

	if _mesh_ed.select_mode == .Face && _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) {
		f_idx := _mesh_ed.selected_face
		orig_f := _mesh_ed.faces[f_idx]
		m := len(orig_f.verts)
		if m < 3 do return

		if _mesh_ed.axis_lock == .Free {
			dir, _ = _face_normal_and_center(orig_f)
		}

		old_ring := make([]u32, m, context.temp_allocator)
		copy(old_ring, orig_f.verts[:])
		new_ring := make([]u32, m, context.temp_allocator)

		for i in 0 ..< m {
			old_v := _mesh_ed.verts[old_ring[i]]
			new_ring[i] = u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, old_v + dir * distance)
		}

		// Update the extruded cap face to use `new_ring`
		for i in 0 ..< m {
			_mesh_ed.faces[f_idx].verts[i] = new_ring[i]
		}
		// Stitch quad side walls around the extruded ring
		for i in 0 ..< m {
			next := (i + 1) % m
			_add_poly_face({old_ring[i], old_ring[next], new_ring[next], new_ring[i]}, orig_f.color)
		}
		_rebuild_editable_mesh_gpu(commit = commit)
	} else if _mesh_ed.select_mode == .Edge && _mesh_ed.has_selected_edge {
		u := _mesh_ed.selected_edge[0]
		v := _mesh_ed.selected_edge[1]
		if int(u) >= len(_mesh_ed.verts) || int(v) >= len(_mesh_ed.verts) do return
		u2 := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, _mesh_ed.verts[u] + dir * distance)
		v2 := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, _mesh_ed.verts[v] + dir * distance)
		_add_poly_face({u, v, v2, u2})
		_mesh_ed.selected_edge = {u2, v2}
		_rebuild_editable_mesh_gpu(commit = commit)
	}
}

// Insets the selected Face inward by `inset_ratio` (0.05..0.85), creating a quad frame around it
mesh_op_inset_selected_face :: proc(inset_amount: f32, commit := true) {
	_ensure_mesh_ed_init()
	if _mesh_ed.selected_face < 0 || _mesh_ed.selected_face >= len(_mesh_ed.faces) do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	f_idx := _mesh_ed.selected_face
	orig_f := _mesh_ed.faces[f_idx]
	m := len(orig_f.verts)
	if m < 3 do return

	_, center := _face_normal_and_center(orig_f)
	t := clamp(inset_amount, 0.05, 0.85)

	old_ring := make([]u32, m, context.temp_allocator)
	copy(old_ring, orig_f.verts[:])
	new_ring := make([]u32, m, context.temp_allocator)

	for i in 0 ..< m {
		old_v := _mesh_ed.verts[old_ring[i]]
		new_ring[i] = u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, linalg.lerp(old_v, center, t))
	}

	for i in 0 ..< m {
		_mesh_ed.faces[f_idx].verts[i] = new_ring[i]
	}
	for i in 0 ..< m {
		next := (i + 1) % m
		_add_poly_face({old_ring[i], old_ring[next], new_ring[next], new_ring[i]}, orig_f.color)
	}
	_rebuild_editable_mesh_gpu(commit = commit)
}

// Bevels / Chamfers the selected Face (insets by `bevel_amt` and pushes along face normal by `bevel_height`)
mesh_op_bevel_selected_face :: proc(bevel_amt: f32, bevel_height: f32 = 0.0, commit := true) {
	_ensure_mesh_ed_init()
	if _mesh_ed.selected_face < 0 || _mesh_ed.selected_face >= len(_mesh_ed.faces) do return
	f_idx := _mesh_ed.selected_face
	fn, _ := _face_normal_and_center(_mesh_ed.faces[f_idx])
	mesh_op_inset_selected_face(clamp(bevel_amt, 0.04, 0.78), commit = false)
	push_h := bevel_height if abs(bevel_height) > 1e-4 else bevel_amt
	for vi in _mesh_ed.faces[f_idx].verts {
		if int(vi) < len(_mesh_ed.verts) {
			_mesh_ed.verts[vi] += fn * push_h
		}
	}
	_rebuild_editable_mesh_gpu(commit = commit)
}

// Bevels / Chamfers the selected Edge `(u, v)` in `[2] Edge` mode by `width`!
// Splits the shared edge between its two adjacent faces into a chamfer quad `{u_a, v_a, v_b, u_b}`.
mesh_op_bevel_selected_edge :: proc(width: f32, commit := true) {
	_ensure_mesh_ed_init()
	if !_mesh_ed.has_selected_edge do return
	u := _mesh_ed.selected_edge[0]
	v := _mesh_ed.selected_edge[1]
	if int(u) >= len(_mesh_ed.verts) || int(v) >= len(_mesh_ed.verts) || u == v do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	// Find the two faces sharing edge `(u, v)`
	fa_idx := -1
	fb_idx := -1
	fa_oriented_uv := true
	for f, fi in _mesh_ed.faces {
		m := len(f.verts)
		for i in 0 ..< m {
			a := f.verts[i]
			b := f.verts[(i + 1) % m]
			if a == u && b == v {
				if fa_idx < 0 { fa_idx = fi; fa_oriented_uv = true } else if fb_idx < 0 { fb_idx = fi }
			} else if a == v && b == u {
				if fa_idx < 0 { fa_idx = fi; fa_oriented_uv = false } else if fb_idx < 0 { fb_idx = fi }
			}
		}
	}
	if fa_idx < 0 || fb_idx < 0 do return
	if !fa_oriented_uv {
		u, v = v, u
	}

	_, ca := _face_normal_and_center(_mesh_ed.faces[fa_idx])
	_, cb := _face_normal_and_center(_mesh_ed.faces[fb_idx])
	t := clamp(width, 0.04, 0.65)

	vu := _mesh_ed.verts[u]
	vv := _mesh_ed.verts[v]
	ua_pt := linalg.lerp(vu, ca, t)
	va_pt := linalg.lerp(vv, ca, t)
	ub_pt := linalg.lerp(vu, cb, t)
	vb_pt := linalg.lerp(vv, cb, t)

	// Move `u` and `v` to `ua_pt` and `va_pt` (used by `fa_idx`), and create `ub` and `vb` for `fb_idx`
	_mesh_ed.verts[u] = ua_pt
	_mesh_ed.verts[v] = va_pt
	ub := u32(len(_mesh_ed.verts))
	append(&_mesh_ed.verts, ub_pt)
	vb := u32(len(_mesh_ed.verts))
	append(&_mesh_ed.verts, vb_pt)

	// Replace `u -> ub` and `v -> vb` inside `fb_idx`
	for &vi in _mesh_ed.faces[fb_idx].verts {
		if vi == u do vi = ub
		else if vi == v do vi = vb
	}

	// For any side face that touches `u` (or `v`) and shares an edge with `fb_idx`, inject `ub` (or `vb`) so the corner stays manifold!
	for &f, fi in _mesh_ed.faces {
		if fi == fa_idx || fi == fb_idx do continue
		m := len(f.verts)
		for i := 0; i < len(f.verts); i += 1 {
			curr := f.verts[i]
			next := f.verts[(i + 1) % len(f.verts)]
			prev_v := f.verts[(i - 1 + len(f.verts)) % len(f.verts)]
			if curr == u {
				// Check if `next` belongs to `fb_idx`
				next_in_fb := false
				for fbv in _mesh_ed.faces[fb_idx].verts do if fbv == next { next_in_fb = true; break }
				if next_in_fb {
					inject_at(&f.verts, i + 1, ub)
					break
				}
				prev_in_fb := false
				for fbv in _mesh_ed.faces[fb_idx].verts do if fbv == prev_v { prev_in_fb = true; break }
				if prev_in_fb {
					inject_at(&f.verts, i, ub)
					break
				}
			}
		}
		for i := 0; i < len(f.verts); i += 1 {
			curr := f.verts[i]
			next := f.verts[(i + 1) % len(f.verts)]
			prev_v := f.verts[(i - 1 + len(f.verts)) % len(f.verts)]
			if curr == v {
				next_in_fb := false
				for fbv in _mesh_ed.faces[fb_idx].verts do if fbv == next { next_in_fb = true; break }
				if next_in_fb {
					inject_at(&f.verts, i + 1, vb)
					break
				}
				prev_in_fb := false
				for fbv in _mesh_ed.faces[fb_idx].verts do if fbv == prev_v { prev_in_fb = true; break }
				if prev_in_fb {
					inject_at(&f.verts, i, vb)
					break
				}
			}
		}
		_ = m
	}

	// Add the new chamfer quad face `{u, ub, vb, v}`
	_add_poly_face({u, ub, vb, v}, _mesh_ed.faces[fa_idx].color)
	mesh_op_recalculate_outward_normals()
	_rebuild_editable_mesh_gpu(commit = commit)
}

// Blender-Style `Make Face / Fill (F)` in `[1] Vertex` or `[2] Edge` Mode:
// - If in Edge mode: closes the open hole loop containing the selected edge (or all open holes).
// - If 2 vertices are selected in Vertex mode: connects them (splits any shared face along the chord `(v0, v1)` or adds a wireframe edge).
// - If >= 3 vertices are selected in Vertex mode: orders the selected vertices into a planar CCW polygon loop around their centroid,
//   orients its normal outward away from the mesh centroid, and creates a new polygon face!
mesh_op_make_face_from_selected_verts :: proc() -> bool {
	_ensure_mesh_ed_init()
	_clear_active_op()

	if _mesh_ed.select_mode == .Edge {
		mesh_op_close_open_holes()
		return true
	}
	if len(_mesh_ed.selected_verts) == 2 {
		return mesh_op_connect_selected_verts()
	}
	if len(_mesh_ed.selected_verts) < 3 do return false

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	// Deduplicate selected vertices
	unique := make([dynamic]u32, 0, len(_mesh_ed.selected_verts), context.temp_allocator)
	for vi in _mesh_ed.selected_verts {
		if int(vi) >= len(_mesh_ed.verts) do continue
		dup := false
		for uv in unique do if uv == vi { dup = true; break }
		if !dup do append(&unique, vi)
	}
	n := len(unique)
	if n < 3 do return false

	// Compute centroid of selected vertices
	fc: [3]f32
	for vi in unique do fc += _mesh_ed.verts[vi]
	fc /= f32(n)

	// Compute best-fit plane normal of the selected vertices
	p0 := _mesh_ed.verts[unique[0]]
	best_n := [3]f32{0, 1, 0}
	best_len2: f32 = 0
	for i in 1 ..< n {
		for j in i + 1 ..< n {
			cr := linalg.cross(_mesh_ed.verts[unique[i]] - p0, _mesh_ed.verts[unique[j]] - p0)
			l2 := linalg.length2(cr)
			if l2 > best_len2 {
				best_len2 = l2
				best_n = cr
			}
		}
	}
	fn := linalg.normalize0(best_n)
	if linalg.length2(fn) < 0.5 do fn = {0, 1, 0}

	// Orient `fn` outward away from mesh centroid
	mc := _mesh_centroid()
	if linalg.length2(fc - mc) > 1e-4 && linalg.dot(fn, fc - mc) < 0 {
		fn = -fn
	}

	// Sort `unique` vertices counter-clockwise in the 2D tangent plane `(u_ax, v_ax)` of `fn`
	u_ax, v_ax := cad_csg.plane_tangent_basis(fn)
	Vert_Angle :: struct {
		vi:  u32,
		ang: f32,
	}
	va_list := make([]Vert_Angle, n, context.temp_allocator)
	for vi, idx in unique {
		rel := _mesh_ed.verts[vi] - fc
		va_list[idx] = Vert_Angle{
			vi  = vi,
			ang = math.atan2(linalg.dot(rel, v_ax), linalg.dot(rel, u_ax)),
		}
	}
	slice.sort_by(va_list, proc(a, b: Vert_Angle) -> bool {
		return a.ang < b.ang
	})

	sorted_loop := make([]u32, n, context.temp_allocator)
	for item, idx in va_list do sorted_loop[idx] = item.vi

	// Check if a face with the exact same vertex set already exists
	for &ef, efi in _mesh_ed.faces {
		if len(ef.verts) != n do continue
		matches := 0
		for sv in sorted_loop {
			for fv in ef.verts {
				if sv == fv { matches += 1; break }
			}
		}
		if matches == n {
			_mesh_ed.selected_face = efi
			return false
		}
	}

	col_u8 := [4]u8{
		u8(clamp(_mesh_ed.mesh_color.r * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.g * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.b * 255.0, 0, 255)),
		255,
	}
	_add_poly_face(sorted_loop, col_u8)
	new_fi := len(_mesh_ed.faces) - 1
	mesh_op_recalculate_outward_normals()
	_mesh_ed.selected_face = new_fi
	_rebuild_editable_mesh_gpu(commit = true)
	return true
}

// Blender-Style `Connect Vertex Pair / Split Face (J)` in `[1] Vertex` Mode:
// If 2 selected vertices belong to the same face (and aren't already adjacent along an edge),
// splits that face across the chord `(u, v)` into two faces; otherwise connects them with a 3D wireframe edge!
mesh_op_connect_selected_verts :: proc() -> bool {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.selected_verts) < 2 do return false
	u := _mesh_ed.selected_verts[0]
	v := _mesh_ed.selected_verts[1]
	if u == v || int(u) >= len(_mesh_ed.verts) || int(v) >= len(_mesh_ed.verts) do return false

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	split_any := false
	for fi := 0; fi < len(_mesh_ed.faces); fi += 1 {
		f := _mesh_ed.faces[fi]
		n := len(f.verts)
		if n < 4 do continue
		ku := -1
		kv := -1
		for vi, k in f.verts {
			if vi == u do ku = k
			if vi == v do kv = k
		}
		if ku < 0 || kv < 0 do continue
		if (ku + 1) % n == kv || (kv + 1) % n == ku do continue

		poly_a := make([dynamic]u32, 0, n)
		for idx := ku; ; idx = (idx + 1) % n {
			append(&poly_a, f.verts[idx])
			if idx == kv do break
		}
		poly_b := make([dynamic]u32, 0, n)
		for idx := kv; ; idx = (idx + 1) % n {
			append(&poly_b, f.verts[idx])
			if idx == ku do break
		}
		if len(poly_a) >= 3 && len(poly_b) >= 3 {
			delete(_mesh_ed.faces[fi].verts)
			_mesh_ed.faces[fi].verts = poly_a
			append(&_mesh_ed.faces, Editable_Poly_Face{verts = poly_b, color = f.color})
			split_any = true
			break
		} else {
			delete(poly_a)
			delete(poly_b)
		}
	}
	if !split_any {
		_add_wire_edge(u, v)
	}
	_rebuild_editable_mesh_gpu(commit = true)
	return true
}

// Dissolves the selected vertices from any face loops that contain them (keeping faces with >= 3 remaining vertices)
mesh_op_dissolve_selected_verts :: proc() {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.selected_verts) == 0 do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	for fi := len(_mesh_ed.faces) - 1; fi >= 0; fi -= 1 {
		f := &_mesh_ed.faces[fi]
		for sv in _mesh_ed.selected_verts {
			for k := len(f.verts) - 1; k >= 0; k -= 1 {
				if f.verts[k] == sv {
					ordered_remove(&f.verts, k)
				}
			}
		}
		if len(f.verts) < 3 {
			delete(f.verts)
			ordered_remove(&_mesh_ed.faces, fi)
		}
	}
	_compact_unused_vertices()
	_rebuild_editable_mesh_gpu(commit = true)
}

// Flips the winding order / normal of the currently selected face(s) in `[3] Face` mode
mesh_op_flip_selected_face_normal :: proc() {
	_ensure_mesh_ed_init()
	if _mesh_ed.selected_face < 0 || _mesh_ed.selected_face >= len(_mesh_ed.faces) do return
	f := &_mesh_ed.faces[_mesh_ed.selected_face]
	n := len(f.verts)
	for i in 0 ..< n / 2 {
		f.verts[i], f.verts[n - 1 - i] = f.verts[n - 1 - i], f.verts[i]
	}
	_rebuild_editable_mesh_gpu(commit = true)
}

// Re-applies the active operator (`Extrude`, `Inset`, `Bevel_Face`, `Bevel_Edge`, `Loop_Cut`) from `_mesh_ed.op_snap`
// whenever the user drags an operator parameter slider in the drawer!
@(private = "file")
_reapply_active_op :: proc(commit := false) {
	if !_mesh_ed.has_op_snap || _mesh_ed.active_op == .None do return
	_snapshot_restore(_mesh_ed.op_snap, false)
	_mesh_ed.selected_face = _mesh_ed.op_face_idx
	_mesh_ed.selected_edge = _mesh_ed.op_edge
	_mesh_ed.has_selected_edge = (_mesh_ed.op_edge[0] != _mesh_ed.op_edge[1])

	switch _mesh_ed.active_op {
	case .None:
	case .Extrude:
		mesh_op_extrude_selected(_mesh_ed.extrude_amount, commit = commit)
	case .Inset:
		mesh_op_inset_selected_face(_mesh_ed.inset_amount, commit = commit)
	case .Bevel_Face:
		mesh_op_bevel_selected_face(_mesh_ed.bevel_amount, _mesh_ed.bevel_height, commit = commit)
	case .Bevel_Edge:
		mesh_op_bevel_selected_edge(_mesh_ed.bevel_amount, commit = commit)
	case .Loop_Cut:
		mesh_op_loop_cut(_mesh_ed.op_loop_axis, _mesh_ed.cut_plane_offset)
	}
}

// Subdivides the selected Face (or splits the selected Edge at its midpoint)
mesh_op_subdivide_selected :: proc() {
	_ensure_mesh_ed_init()
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	if _mesh_ed.select_mode == .Face && _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) {
		f_idx := _mesh_ed.selected_face
		orig_f := _mesh_ed.faces[f_idx]
		m := len(orig_f.verts)
		if m < 3 do return

		_, center := _face_normal_and_center(orig_f)
		c_idx := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, center)

		ring := make([]u32, m, context.temp_allocator)
		copy(ring, orig_f.verts[:])

		// Replace original face with first triangle, append remaining triangles
		resize(&_mesh_ed.faces[f_idx].verts, 3)
		_mesh_ed.faces[f_idx].verts[0] = ring[0]
		_mesh_ed.faces[f_idx].verts[1] = ring[1]
		_mesh_ed.faces[f_idx].verts[2] = c_idx
		for i in 1 ..< m {
			next := (i + 1) % m
			_add_poly_face({ring[i], ring[next], c_idx})
		}
		_rebuild_editable_mesh_gpu()
	} else if _mesh_ed.select_mode == .Edge && _mesh_ed.has_selected_edge {
		u := _mesh_ed.selected_edge[0]
		v := _mesh_ed.selected_edge[1]
		if int(u) >= len(_mesh_ed.verts) || int(v) >= len(_mesh_ed.verts) do return
		mid := (_mesh_ed.verts[u] + _mesh_ed.verts[v]) * 0.5
		m_idx := u32(len(_mesh_ed.verts))
		append(&_mesh_ed.verts, mid)

		// Insert midpoint into any face containing edge (u, v) or (v, u)
		for &f in _mesh_ed.faces {
			nf := len(f.verts)
			for i in 0 ..< nf {
				a := f.verts[i]
				b := f.verts[(i + 1) % nf]
				if (a == u && b == v) || (a == v && b == u) {
					inject_at(&f.verts, i + 1, m_idx)
					break
				}
			}
		}
		_mesh_ed.select_mode = .Vertex
		clear(&_mesh_ed.selected_verts)
		append(&_mesh_ed.selected_verts, m_idx)
		_rebuild_editable_mesh_gpu()
	}
}

// Deletes the currently selected Face (useful for opening a surface or testing open-hole repair!)
mesh_op_delete_selected_face :: proc() {
	_ensure_mesh_ed_init()
	if _mesh_ed.selected_face < 0 || _mesh_ed.selected_face >= len(_mesh_ed.faces) do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	delete(_mesh_ed.faces[_mesh_ed.selected_face].verts)
	ordered_remove(&_mesh_ed.faces, _mesh_ed.selected_face)
	if _mesh_ed.selected_face >= len(_mesh_ed.faces) {
		_mesh_ed.selected_face = len(_mesh_ed.faces) - 1
	}
	_rebuild_editable_mesh_gpu()
}

// Welds vertices within `max_dist` meters of each other and cleans degenerate faces
mesh_op_weld_vertices :: proc(max_dist: f32, commit := true) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.verts) < 2 do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	eps_sq := max(max_dist * max_dist, 1e-6)
	new_verts := make([dynamic][3]f32, 0, len(_mesh_ed.verts))
	remap := make([]u32, len(_mesh_ed.verts), context.temp_allocator)

	// If >= 2 vertices are selected in Vertex mode, weld selected vertices to their centroid first!
	if _mesh_ed.select_mode == .Vertex && len(_mesh_ed.selected_verts) >= 2 {
		c: [3]f32
		valid_n := 0
		for vi in _mesh_ed.selected_verts {
			if int(vi) < len(_mesh_ed.verts) {
				c += _mesh_ed.verts[vi]
				valid_n += 1
			}
		}
		if valid_n >= 2 {
			c /= f32(valid_n)
			for vi in _mesh_ed.selected_verts {
				if int(vi) < len(_mesh_ed.verts) {
					_mesh_ed.verts[vi] = c
				}
			}
		}
	}

	for v, i in _mesh_ed.verts {
		found := -1
		for nv, ni in new_verts {
			if linalg.length2(v - nv) <= eps_sq {
				found = ni
				break
			}
		}
		if found >= 0 {
			remap[i] = u32(found)
		} else {
			remap[i] = u32(len(new_verts))
			append(&new_verts, v)
		}
	}

	delete(_mesh_ed.verts)
	_mesh_ed.verts = new_verts

	for fi := 0; fi < len(_mesh_ed.faces); {
		f := &_mesh_ed.faces[fi]
		for k in 0 ..< len(f.verts) {
			f.verts[k] = remap[f.verts[k]]
		}
		// Remove consecutive duplicate vertex indices in the face loop
		for k := 0; k < len(f.verts); {
			next := (k + 1) % max(len(f.verts), 1)
			if len(f.verts) > 1 && f.verts[k] == f.verts[next] {
				ordered_remove(&f.verts, k)
			} else {
				k += 1
			}
		}
		if len(f.verts) < 3 {
			delete(f.verts)
			ordered_remove(&_mesh_ed.faces, fi)
		} else {
			fi += 1
		}
	}
	clear(&_mesh_ed.selected_verts)
	_rebuild_editable_mesh_gpu(commit = commit)
}

// Repairs open boundary holes by tracing unpaired boundary half-edges and capping each hole loop!
mesh_op_close_open_holes :: proc() {
	_ensure_mesh_ed_init()
	_evaluate_mesh_csg_compliance()
	if len(_mesh_ed.report.open_edge_pairs) == 0 do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	// Each open directed edge `(a -> b)` in an existing face needs an opposing `(b -> a)` edge in the cap face!
	Half_Edge :: struct {
		u, v: u32,
		used: bool,
	}
	boundary := make([dynamic]Half_Edge, 0, len(_mesh_ed.report.open_edge_pairs), context.temp_allocator)
	for pair in _mesh_ed.report.open_edge_pairs {
		// `pair` was recorded as `(u, v)` from the existing face; the cap needs `(v -> u)`
		append(&boundary, Half_Edge{u = pair[1], v = pair[0], used = false})
	}

	for i in 0 ..< len(boundary) {
		if boundary[i].used do continue
		boundary[i].used = true
		loop := make([dynamic]u32, 0, 8, context.temp_allocator)
		append(&loop, boundary[i].u)
		curr := boundary[i].v
		start := boundary[i].u

		guard := len(boundary) + 2
		for curr != start && guard > 0 {
			guard -= 1
			append(&loop, curr)
			found_next := false
			for j in 0 ..< len(boundary) {
				if !boundary[j].used && boundary[j].u == curr {
					boundary[j].used = true
					curr = boundary[j].v
					found_next = true
					break
				}
			}
			if !found_next do break
		}

		if len(loop) >= 3 {
			_add_poly_face(loop[:])
		}
	}

	mesh_op_recalculate_outward_normals()
}

// Tests whether face `fi`'s normal `fn` at `fc` points outward into empty space.
// - Fast & Exact Convex Support Check: if `fn` (or `-fn`) is an outer support plane of the vertex cloud
//   (no mesh vertices lie in front of it), `dot(fn, fc - c) >= 0` is 100% exact and immune to grazing
//   ray-edge double hits at UV sphere poles!
// - Jordan-Brouwer Ray-Parity Fallback: used only for non-support concave/interior faces (like the inner
//   tube of a Torus ring) where vertices of the opposite side lie in front of the face plane.
@(private = "file")
_is_face_normal_pointing_outward :: proc(fi: int, fn, fc, c: [3]f32) -> bool {
	out_cand := fn if linalg.dot(fn, fc - c) >= 0 else -fn
	d_cand   := linalg.dot(out_cand, fc)
	is_outer_support := true
	for v in _mesh_ed.verts {
		if linalg.dot(out_cand, v) - d_cand > 0.015 {
			is_outer_support = false
			break
		}
	}
	if is_outer_support {
		return linalg.dot(fn, fc - c) >= -1e-4
	}

	if len(_mesh_ed.faces) >= 4 {
		// Perturb ray direction slightly to avoid grazing edges
		dir_pos := linalg.normalize0(fn + [3]f32{0.0013, 0.0017, 0.0011})
		dir_neg := -dir_pos
		ray_pos := engine.Ray{origin = fc + fn * 0.002, direction = dir_pos}
		ray_neg := engine.Ray{origin = fc - fn * 0.002, direction = dir_neg}
		hits_pos := 0
		hits_neg := 0
		for poly_f, fj in _mesh_ed.faces {
			if fj == fi do continue
			m := len(poly_f.verts)
			if m < 3 do continue
			v0 := _mesh_ed.verts[poly_f.verts[0]]
			for ti in 1 ..< m - 1 {
				v1 := _mesh_ed.verts[poly_f.verts[ti]]
				v2 := _mesh_ed.verts[poly_f.verts[ti + 1]]
				if t_p, ok_p := _ray_triangle_intersect(ray_pos, v0, v1, v2); ok_p && t_p > 0.002 {
					hits_pos += 1
				}
				if t_n, ok_n := _ray_triangle_intersect(ray_neg, v0, v1, v2); ok_n && t_n > 0.002 {
					hits_neg += 1
				}
			}
		}
		if (hits_pos % 2 == 0) && (hits_neg % 2 == 1) do return true
		if (hits_pos % 2 == 1) && (hits_neg % 2 == 0) do return false
	}
	return linalg.dot(fn, fc - c) >= -1e-4
}

// Ensures every face normal points outward away from the solid interior (supports Torus & concave meshes!)
mesh_op_recalculate_outward_normals :: proc() {
	_ensure_mesh_ed_init()
	c := _mesh_centroid()
	for &f, fi in _mesh_ed.faces {
		fn, fc := _face_normal_and_center(f)
		if !_is_face_normal_pointing_outward(fi, fn, fc, c) {
			n := len(f.verts)
			for i in 0 ..< n / 2 {
				f.verts[i], f.verts[n - 1 - i] = f.verts[n - 1 - i], f.verts[i]
			}
		}
	}
	_rebuild_editable_mesh_gpu()
}

// Wraps the mesh into a guaranteed-watertight, 100% compliant 3D Convex Hull polyhedron!
// Uses half-space plane support of outward bounding directions + face planes, then extracts
// the exact convex polyhedron faces via `cad_csg.convex_extract_faces`.
mesh_op_make_convex_hull :: proc() {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.verts) < 4 do return

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	c := _mesh_centroid()
	hull := cad_csg.CSG_Convex{
		planes = make([dynamic]cad_csg.CSG_Plane, 0, 32, context.temp_allocator),
	}

	col_u8 := [4]u8{
		u8(clamp(_mesh_ed.mesh_color.r * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.g * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.b * 255.0, 0, 255)),
		255,
	}

	add_support_plane :: proc(hull: ^cad_csg.CSG_Convex, dir: [3]f32, verts: [][3]f32, col: [4]u8) {
		n := linalg.normalize0(dir)
		if linalg.length2(n) < 0.5 do return
		max_d: f32 = -max(f32)
		for v in verts {
			d := linalg.dot(n, v)
			if d > max_d do max_d = d
		}
		// Skip if a nearly identical plane normal already exists
		for &ep in hull.planes {
			if linalg.dot(ep.normal, n) > 0.995 {
				ep.dist = min(ep.dist, max_d)
				return
			}
		}
		append(&hull.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
			normal   = n,
			dist     = max_d,
			mat_slot = 0,
			uv_scale = 0.5,
			color    = col,
		}))
	}

	// 1. Add support planes for all current non-concave outward face normals
	for f in _mesh_ed.faces {
		fn, fc := _face_normal_and_center(f)
		if linalg.dot(fn, fc - c) < 0 do fn = -fn
		// Check if this face plane is an extreme support plane of the vertex cloud (within small tolerance)
		face_d := linalg.dot(fn, fc)
		max_d: f32 = -max(f32)
		for v in _mesh_ed.verts {
			max_d = max(max_d, linalg.dot(fn, v))
		}
		if max_d - face_d <= 0.02 {
			add_support_plane(&hull, fn, _mesh_ed.verts[:], col_u8)
		}
	}

	// 2. Only include the 6 cardinal AABB planes and vertex-triplet hull facets when the mesh has
	//    open holes, concave dents, or fewer than 4 valid support planes (never on an already-closed
	//    convex UV Sphere / Cylinder / Cone, where cardinal or diagonal triplet planes would shave edges!).
	_evaluate_mesh_csg_compliance()
	needs_hull_completion := len(hull.planes) < 4 || _mesh_ed.report.open_boundary_edges > 0 || _mesh_ed.report.concave_face_count > 0

	if needs_hull_completion {
		cardinals := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, -1, 0}}
		cardinals[5] = {0, 0, -1}
		for cd in cardinals {
			add_support_plane(&hull, cd, _mesh_ed.verts[:], col_u8)
		}

		// 3. Test triplets of extreme vertices that form true outer convex hull facets (tight 1e-4 coplanarity tolerance)
		vn := min(len(_mesh_ed.verts), 32)
		for i in 0 ..< vn {
			for j in i + 1 ..< vn {
				for k in j + 1 ..< vn {
					va := _mesh_ed.verts[i]
					vb := _mesh_ed.verts[j]
					vc := _mesh_ed.verts[k]
					n := linalg.normalize0(linalg.cross(vb - va, vc - va))
					if linalg.length2(n) < 0.5 do continue
					if linalg.dot(n, va - c) < 0 do n = -n
					d0 := linalg.dot(n, va)
					is_support := true
					for v in _mesh_ed.verts {
						if linalg.dot(n, v) - d0 > 1e-4 {
							is_support = false
							break
						}
					}
					if is_support {
						add_support_plane(&hull, n, _mesh_ed.verts[:], col_u8)
					}
				}
			}
		}
	}

	if !cad_csg.convex_rebuild_bounds_and_prune(&hull, prune_redundant = true) do return

	faces_out := make([dynamic]cad_csg.CSG_Face_Poly, 0, len(hull.planes), context.temp_allocator)
	cad_csg.convex_extract_faces(hull, &faces_out, context.temp_allocator)
	if len(faces_out) < 4 do return

	_clear_editable_mesh()
	weld_eps_sq :: f32(1e-5)
	for fp in faces_out {
		if len(fp.verts) < 3 do continue
		f_inds := make([dynamic]u32, 0, len(fp.verts), context.temp_allocator)
		for pt in fp.verts {
			found := -1
			for ev, ei in _mesh_ed.verts {
				if linalg.length2(pt - ev) <= weld_eps_sq {
					found = ei
					break
				}
			}
			if found >= 0 {
				append(&f_inds, u32(found))
			} else {
				append(&f_inds, u32(len(_mesh_ed.verts)))
				append(&_mesh_ed.verts, pt)
			}
		}
		if len(f_inds) >= 3 {
			_add_poly_face(f_inds[:])
		}
	}
	_rebuild_editable_mesh_gpu()
}

// ============================================================================
// LIVE `MESH -> CSG` COMPLIANCE CHECKER & CONVERTER
// ============================================================================

@(private = "package")
_evaluate_mesh_csg_compliance :: proc() {
	r := &_mesh_ed.report
	clear(&r.open_edge_pairs)
	clear(&r.concave_verts)
	clear(&r.inverted_faces)

	r.vert_count            = len(_mesh_ed.verts)
	r.face_count            = len(_mesh_ed.faces)
	r.unique_plane_count    = 0
	r.open_boundary_edges   = 0
	r.non_manifold_edges    = 0
	r.inverted_normal_faces = 0
	r.concave_face_count    = 0
	r.concave_vert_count    = 0
	r.degenerate_faces      = 0
	r.has_valid_volume      = false
	r.compliant             = false
	_mesh_ed.report_dirty   = false

	if r.vert_count < 4 || r.face_count < 4 do return

	// 1. Check 3D AABB volume
	lo := _mesh_ed.verts[0]
	hi := _mesh_ed.verts[0]
	for v in _mesh_ed.verts[1:] {
		lo.x = min(lo.x, v.x); lo.y = min(lo.y, v.y); lo.z = min(lo.z, v.z)
		hi.x = max(hi.x, v.x); hi.y = max(hi.y, v.y); hi.z = max(hi.z, v.z)
	}
	r.aabb_size = hi - lo
	r.has_valid_volume = (r.aabb_size.x >= 0.05 && r.aabb_size.y >= 0.05 && r.aabb_size.z >= 0.05)

	// 2. Check Watertightness / Half-Edge Pairing (every undirected edge must have 1 forward + 1 reverse half-edge)
	Edge_Entry :: struct {
		u, v:     u32, // canonical u < v
		fwd_cnt:  int,
		rev_cnt:  int,
		raw_u, raw_v: u32,
	}
	edges := make([dynamic]Edge_Entry, 0, r.face_count * 4, context.temp_allocator)
	for f in _mesh_ed.faces {
		m := len(f.verts)
		if m < 3 {
			r.degenerate_faces += 1
			continue
		}
		for i in 0 ..< m {
			a := f.verts[i]
			b := f.verts[(i + 1) % m]
			if a == b do continue
			u := min(a, b)
			v := max(a, b)
			is_fwd := (a == u)
			found := false
			for &e in edges {
				if e.u == u && e.v == v {
					if is_fwd do e.fwd_cnt += 1
					else      do e.rev_cnt += 1
					found = true
					break
				}
			}
			if !found {
				append(&edges, Edge_Entry{
					u       = u,
					v       = v,
					fwd_cnt = 1 if is_fwd else 0,
					rev_cnt = 0 if is_fwd else 1,
					raw_u   = a,
					raw_v   = b,
				})
			}
		}
	}

	for e in edges {
		total := e.fwd_cnt + e.rev_cnt
		if total == 1 {
			r.open_boundary_edges += 1
			append(&r.open_edge_pairs, [2]u32{e.raw_u, e.raw_v})
		} else if total > 2 || e.fwd_cnt != 1 || e.rev_cnt != 1 {
			r.non_manifold_edges += 1
		}
	}

	// 3. Check Outward Normals & 3D Convexity (all vertices behind every face plane)
	c := _mesh_centroid()
	unique_normals := make([dynamic][4]f32, 0, r.face_count, context.temp_allocator)
	vert_marked_concave := make([]bool, r.vert_count, context.temp_allocator)

	for f, fi in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		fn, fc := _face_normal_and_center(f)
		is_outward := _is_face_normal_pointing_outward(fi, fn, fc, c) if r.open_boundary_edges == 0 else (linalg.dot(fn, fc - c) >= -1e-4)
		if !is_outward {
			r.inverted_normal_faces += 1
			append(&r.inverted_faces, fi)
		}

		// Use outward-oriented plane for convexity test
		out_n := fn if is_outward else -fn
		plane_d := linalg.dot(out_n, fc)

		// Deduplicate unique planes
		is_dup_plane := false
		for up in unique_normals {
			if linalg.dot(up.xyz, out_n) > 0.999 && abs(up.w - plane_d) < 0.005 {
				is_dup_plane = true
				break
			}
		}
		if !is_dup_plane {
			append(&unique_normals, [4]f32{out_n.x, out_n.y, out_n.z, plane_d})
		}

		// Test if any vertex protrudes significantly in front of this face plane (`dot(out_n, v) - plane_d > 0.015`)
		face_violated := false
		for v, vi in _mesh_ed.verts {
			if linalg.dot(out_n, v) - plane_d > 0.015 {
				face_violated = true
				if !vert_marked_concave[vi] {
					vert_marked_concave[vi] = true
					append(&r.concave_verts, u32(vi))
				}
			}
		}
		if face_violated {
			r.concave_face_count += 1
		}
	}

	r.concave_vert_count = len(r.concave_verts)
	r.unique_plane_count = len(unique_normals)

	r.compliant = r.has_valid_volume &&
	              r.open_boundary_edges == 0 &&
	              r.non_manifold_edges == 0 &&
	              r.inverted_normal_faces == 0 &&
	              r.concave_face_count == 0 &&
	              r.degenerate_faces == 0 &&
	              r.unique_plane_count >= 4 &&
	              r.unique_plane_count <= cad_csg.CSG_MAX_PLANES_PER_HULL
}

// Exact 5-Ray Jordan-Brouwer Odd/Even Parity Point-in-Mesh Test:
// Determines whether a 3D point `pt` lies strictly inside the solid volume enclosed by `_mesh_ed.faces`.
// Uses 5 Golden-Ratio perturbed ray directions and deduplicates grazing edge/vertex hits within `t` eps `0.002`
// so points inside a carved tunnel, window cutout, or concave pocket reliably test as `false` (outside solid)!
@(private = "package")
_is_point_inside_editable_mesh :: proc(pt: [3]f32) -> bool {
	if len(_mesh_ed.faces) < 4 || len(_mesh_ed.verts) < 4 do return false

	ray_dirs := [5][3]f32{
		linalg.normalize0([3]f32{ 0.9701,  0.1348,  0.1992}),
		linalg.normalize0([3]f32{-0.1825,  0.9621, -0.2013}),
		linalg.normalize0([3]f32{ 0.2114, -0.1742,  0.9617}),
		linalg.normalize0([3]f32{-0.6812, -0.5193,  0.5159}),
		linalg.normalize0([3]f32{ 0.5341,  0.6689, -0.5172}),
	}

	inside_votes := 0
	for dir in ray_dirs {
		ray := engine.Ray{origin = pt, direction = dir}
		hit_ts := make([dynamic]f32, 0, 16, context.temp_allocator)
		for poly_f in _mesh_ed.faces {
			m := len(poly_f.verts)
			if m < 3 do continue
			v0 := _mesh_ed.verts[poly_f.verts[0]]
			for ti in 1 ..< m - 1 {
				v1 := _mesh_ed.verts[poly_f.verts[ti]]
				v2 := _mesh_ed.verts[poly_f.verts[ti + 1]]
				if t_hit, ok := _ray_triangle_intersect(ray, v0, v1, v2); ok && t_hit > 1e-4 {
					// Deduplicate grazing hits along a shared triangle edge or vertex at the same distance `t`
					dup_t := false
					for et in hit_ts {
						if abs(et - t_hit) < 0.002 {
							dup_t = true
							break
						}
					}
					if !dup_t {
						append(&hit_ts, t_hit)
					}
				}
			}
		}
		if (len(hit_ts) % 2) == 1 {
			inside_votes += 1
		}
	}
	return inside_votes >= 3
}

// Exact Concave-Plane Volumetric Decomposition (`Mesh -> Multi-Hull CSG_Convex`):
// - If the mesh is a single compliant convex hull (e.g. Box, Cylinder, Wedge, UV Sphere), builds 1 exact `CSG_Convex`.
// - If the mesh has carved tunnels, boolean holes, recessed pockets, L-corners, or staircases:
//   1. Builds the outer bounding convex hull from the mesh's outer support planes.
//   2. Collects all unique interior splitting planes from faces that have mesh vertices on both sides.
//   3. Partitions the outer hull across those interior splitting planes into convex cells.
//   4. Filters out empty tunnel/cutout cells using the 5-ray Jordan-Brouwer parity test (`_is_point_inside_editable_mesh`).
//   5. Greedily merges adjacent solid cells via `cad_csg.csg_clean_and_simplify_hulls` into minimal watertight convex hulls!
@(private = "package")
_decompose_editable_mesh_to_csg_hulls :: proc(
	make_dynamic_physics := false,
	alloc := context.allocator,
) -> [dynamic]cad_csg.CSG_Convex {
	hulls := make([dynamic]cad_csg.CSG_Convex, 0, 8, alloc)
	if len(_mesh_ed.verts) < 4 || len(_mesh_ed.faces) < 4 do return hulls

	_evaluate_mesh_csg_compliance()

	// SAFETY GUARD FOR COMPLEX / NON-WATERTIGHT / AI-GENERATED MESHES:
	// Exact Concave-Plane Partitioning (`Method 0`) is designed for low-poly architectural CAD blocks (<= 84 faces).
	// If the mesh is dense (> 84 faces) or has open non-watertight boundaries (> 6 open edges), brute-force
	// plane stitching & cell partitioning would be O(F^2) and freeze the editor — automatically route to
	// our Spherical Multi-Ray Line-Trace Hull Builder instead!
	if len(_mesh_ed.faces) > 84 || _mesh_ed.report.open_boundary_edges > 6 {
		tris := make([dynamic][3]u32, 0, len(_mesh_ed.faces) * 2, context.temp_allocator)
		for f in _mesh_ed.faces {
			if len(f.verts) < 3 do continue
			for ti in 1 ..< len(f.verts) - 1 {
				append(&tris, [3]u32{f.verts[0], f.verts[ti], f.verts[ti + 1]})
			}
		}
		return _build_csg_hulls_via_line_traces(
			_mesh_ed.verts[:],
			tris[:],
			.Multi_Ray_Line_Trace,
			int(_ed.line_trace_grid_res),
			make_dynamic_physics,
			{220, 224, 230, 255},
			alloc,
		)
	}

	if !_mesh_ed.report.compliant {
		if _mesh_ed.report.open_boundary_edges > 0 {
			_stitch_and_miter_clean_coplanar_faces()
			_evaluate_mesh_csg_compliance()
		}
		if _mesh_ed.report.open_boundary_edges > 0 && _mesh_ed.report.concave_face_count == 0 {
			mesh_op_close_open_holes()
		}
		if _mesh_ed.report.inverted_normal_faces > 0 do mesh_op_recalculate_outward_normals()
		_evaluate_mesh_csg_compliance()
	}

	col_u8 := [4]u8{220, 224, 230, 255}

	c := _mesh_centroid()

	// Case A: Single compliant convex hull (Box, Cylinder, Cone, Wedge, UV Sphere up to 256 planes)
	if _mesh_ed.report.compliant {
		hull := cad_csg.CSG_Convex{
			planes   = make([dynamic]cad_csg.CSG_Plane, 0, len(_mesh_ed.faces), alloc),
			anchored = !make_dynamic_physics,
			brush_id = 1,
		}
		for f in _mesh_ed.faces {
			if len(f.verts) < 3 do continue
			fn, fc := _face_normal_and_center(f)
			if linalg.dot(fn, fc - c) < 0 do fn = -fn
			plane_d := linalg.dot(fn, fc)
			sum_d: f32 = 0
			cnt_d := 0
			for vi in f.verts {
				if int(vi) < len(_mesh_ed.verts) {
					sum_d += linalg.dot(fn, _mesh_ed.verts[vi])
					cnt_d += 1
				}
			}
			if cnt_d > 0 do plane_d = sum_d / f32(cnt_d)
			append(&hull.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
				normal   = fn,
				dist     = plane_d,
				mat_slot = 0,
				uv_scale = 0.5,
				color    = col_u8,
			}))
		}
		if cad_csg.convex_rebuild_bounds_and_prune(&hull, prune_redundant = false) {
			append(&hulls, hull)
			return hulls
		}
		cad_csg.convex_destroy(&hull)
	}

	// Collect outer support planes AND interior splitting planes from `_mesh_ed.faces`
	outer_hull := cad_csg.CSG_Convex{
		planes   = make([dynamic]cad_csg.CSG_Plane, 0, 24, alloc),
		anchored = !make_dynamic_physics,
		brush_id = 1,
	}
	interior_planes := make([dynamic][4]f32, 0, 24, context.temp_allocator)

	for f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		fn, fc := _face_normal_and_center(f)
		if linalg.dot(fn, _mesh_ed.verts[f.verts[0]] - fc) > 1.0 {} // no-op
		face_d := linalg.dot(fn, fc)

		min_d := max(f32)
		max_d := -max(f32)
		for v in _mesh_ed.verts {
			d := linalg.dot(fn, v) - face_d
			min_d = min(min_d, d)
			max_d = max(max_d, d)
		}

		if max_d <= 0.015 || min_d >= -0.015 {
			// Outer support plane of the mesh! Orient outward so all vertices have `dot(out_n, v) <= out_d`
			out_n := fn if max_d <= 0.015 else -fn
			out_d: f32 = -max(f32)
			for v in _mesh_ed.verts {
				out_d = max(out_d, linalg.dot(out_n, v))
			}
			dup_outer := false
			for &ep in outer_hull.planes {
				if linalg.dot(ep.normal, out_n) > 0.998 && abs(ep.dist - out_d) < 0.008 {
					dup_outer = true
					break
				}
			}
			if !dup_outer {
				append(&outer_hull.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
					normal   = out_n,
					dist     = out_d,
					mat_slot = 0,
					uv_scale = 0.5,
					color    = col_u8,
				}))
			}
		} else {
			// Interior splitting plane (vertices lie significantly on BOTH sides of this face plane, e.g. tunnel wall!)
			qn := cad_csg.quantize_plane(cad_csg.CSG_Plane{normal = fn, dist = face_d})
			// Canonicalize sign of normal so opposite tunnel walls or duplicate faces with flipped normals aren't duplicated
			cn := qn.normal
			cd := qn.dist
			if cn.x < -1e-4 || (abs(cn.x) <= 1e-4 && (cn.y < -1e-4 || (abs(cn.y) <= 1e-4 && cn.z < 0))) {
				cn = -cn
				cd = -cd
			}
			dup_int := false
			for ip in interior_planes {
				if linalg.dot(ip.xyz, cn) > 0.998 && abs(ip.w - cd) < 0.008 {
					dup_int = true
					break
				}
			}
			if !dup_int {
				append(&interior_planes, [4]f32{cn.x, cn.y, cn.z, cd})
			}
		}
	}

	// Always include the 6 AABB cardinal support planes on `outer_hull` to guarantee boundedness
	lo := _mesh_ed.verts[0]
	hi := _mesh_ed.verts[0]
	for v in _mesh_ed.verts[1:] {
		lo = linalg.min(lo, v)
		hi = linalg.max(hi, v)
	}
	cardinals := [6][4]f32{
		{ 1,  0,  0,  hi.x},
		{-1,  0,  0, -lo.x},
		{ 0,  1,  0,  hi.y},
		{ 0, -1,  0, -lo.y},
		{ 0,  0,  1,  hi.z},
		{ 0,  0, -1, -lo.z},
	}
	for cp in cardinals {
		cn := [3]f32{cp.x, cp.y, cp.z}
		cd := cp.w
		dup_c := false
		for ep in outer_hull.planes {
			if linalg.dot(ep.normal, cn) > 0.998 && abs(ep.dist - cd) < 0.01 {
				dup_c = true
				break
			}
		}
		if !dup_c {
			append(&outer_hull.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
				normal   = cn,
				dist     = cd,
				mat_slot = 0,
				uv_scale = 0.5,
				color    = col_u8,
			}))
		}
	}

	// Check if this is a high-face curved Torus ring (all vertices outside an XZ inner hole radius and > 16 interior planes)
	mid_box := (lo + hi) * 0.5
	min_r_xz := max(f32)
	max_r_xz: f32 = 0
	for v in _mesh_ed.verts {
		dx := v.x - mid_box.x
		dz := v.z - mid_box.z
		r_xz := math.sqrt(dx * dx + dz * dz)
		min_r_xz = min(min_r_xz, r_xz)
		max_r_xz = max(max_r_xz, r_xz)
	}

	if max_r_xz > 0.25 && min_r_xz > max_r_xz * 0.16 && len(interior_planes) > 16 {
		cad_csg.convex_destroy(&outer_hull)
		sectors := clamp(len(_mesh_ed.faces) / 6, 8, 16)
		d_ang := (2.0 * math.PI) / f32(sectors)
		for s in 0 ..< sectors {
			ang0 := -math.PI + f32(s) * d_ang
			ang1 := ang0 + d_ang
			sector_faces := make([dynamic]int, 0, 8, context.temp_allocator)
			sector_verts := make([dynamic][3]f32, 0, 24, context.temp_allocator)
			for f, fi in _mesh_ed.faces {
				_, fc := _face_normal_and_center(f)
				ang := math.atan2(fc.z - mid_box.z, fc.x - mid_box.x)
				in_sector := (ang >= ang0 - 0.04 && ang <= ang1 + 0.04)
				if s == 0 && ang > math.PI - 0.04 do in_sector = true
				if s == sectors - 1 && ang < -math.PI + 0.04 do in_sector = true
				if in_sector {
					append(&sector_faces, fi)
					for vi in f.verts {
						if int(vi) < len(_mesh_ed.verts) {
							append(&sector_verts, _mesh_ed.verts[vi])
						}
					}
				}
			}
			if len(sector_verts) < 4 || len(sector_faces) == 0 do continue
			sub_lo := sector_verts[0]
			sub_hi := sector_verts[0]
			sub_c: [3]f32
			for sv in sector_verts {
				sub_lo = linalg.min(sub_lo, sv)
				sub_hi = linalg.max(sub_hi, sv)
				sub_c += sv
			}
			sub_c /= f32(len(sector_verts))
			sh, sh_ok := cad_csg.csg_make_primitive_convex(
				.Box,
				(sub_lo + sub_hi) * 0.5,
				{max(sub_hi.x - sub_lo.x, 0.15), max(sub_hi.y - sub_lo.y, 0.15), max(sub_hi.z - sub_lo.z, 0.15)},
				0, col_u8, 0.5, 0, !make_dynamic_physics, u32(s + 1), alloc,
			)
			if !sh_ok do continue
			for fi in sector_faces {
				f := _mesh_ed.faces[fi]
				fn, _ := _face_normal_and_center(f)
				if linalg.dot(fn, _mesh_ed.verts[f.verts[0]] - sub_c) < 0 do fn = -fn
				max_d: f32 = -1e9
				for sv in sector_verts do max_d = max(max_d, linalg.dot(fn, sv))
				append(&sh.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
					normal = fn, dist = max_d, uv_scale = 0.5, color = col_u8,
				}))
			}
			n_start := [3]f32{math.sin(ang0), 0, -math.cos(ang0)}
			if linalg.dot(n_start, sub_c - mid_box) > 0 do n_start = -n_start
			max_d0: f32 = -1e9
			for sv in sector_verts do max_d0 = max(max_d0, linalg.dot(n_start, sv))
			append(&sh.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
				normal = n_start, dist = max_d0, uv_scale = 0.5, color = col_u8,
			}))
			n_end := [3]f32{-math.sin(ang1), 0, math.cos(ang1)}
			if linalg.dot(n_end, sub_c - mid_box) > 0 do n_end = -n_end
			max_d1: f32 = -1e9
			for sv in sector_verts do max_d1 = max(max_d1, linalg.dot(n_end, sv))
			append(&sh.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
				normal = n_end, dist = max_d1, uv_scale = 0.5, color = col_u8,
			}))
			if cad_csg.convex_rebuild_bounds_and_prune(&sh, prune_redundant = true) {
				sh.anchored = !make_dynamic_physics
				append(&hulls, sh)
			} else {
				cad_csg.convex_destroy(&sh)
			}
		}
		return hulls
	}

	// Exact Concave-Plane Cell Partitioning + Jordan-Brouwer Interior Parity Filtering
	// (Preserves 100% of carved tunnels, archways, recessed pockets, doorways, stairs, and L-shapes!)
	if !cad_csg.convex_rebuild_bounds_and_prune(&outer_hull, prune_redundant = true) {
		cad_csg.convex_destroy(&outer_hull)
		return hulls
	}

	cells := make([dynamic]cad_csg.CSG_Convex, 0, 32, alloc)
	append(&cells, outer_hull)

	max_split_planes := min(len(interior_planes), 16)
	for pi in 0 ..< max_split_planes {
		if len(cells) > 64 do break
		sp := interior_planes[pi]
		sn := sp.xyz
		sd := sp.w
		_ = cad_csg.csg_clip_hull_list_by_plane(&cells, sn, sd, .Split_Both, 0.0, alloc)
	}

	// Filter cells: keep ONLY cells whose interior centroid lies inside the solid mesh (`_is_point_inside_editable_mesh`)
	faces_tmp := make([dynamic]cad_csg.CSG_Face_Poly, 0, 16, context.temp_allocator)
	for &cell in cells {
		clear(&faces_tmp)
		cad_csg.convex_extract_faces(cell, &faces_tmp, context.temp_allocator)
		test_pt := cell.centroid
		if len(faces_tmp) >= 4 {
			sum_pt: [3]f32
			cnt_pt := 0
			for fp in faces_tmp {
				for v in fp.verts {
					sum_pt += v
					cnt_pt += 1
				}
			}
			if cnt_pt > 0 {
				test_pt = sum_pt / f32(cnt_pt)
			}
		}
		if _is_point_inside_editable_mesh(test_pt) {
			cell.anchored = !make_dynamic_physics
			append(&hulls, cell)
		} else {
			cad_csg.convex_destroy(&cell)
		}
	}
	delete(cells)

	// Greedily merge adjacent convex cells whose union is convex (e.g. 8 cells around a tunnel -> 4 clean hulls!)
	if len(hulls) > 1 {
		cad_csg.csg_clean_and_simplify_hulls(&hulls, alloc)
		for &h, hi_idx in hulls {
			h.anchored = !make_dynamic_physics
			h.brush_id = u32(hi_idx + 1)
		}
	}
	return hulls
}

// Rebuilds `_mesh_ed.verts` and `_mesh_ed.faces` from a slice of `CSG_Convex` hulls using
// `cad_csg.csg_extract_clean_polygons_from_hulls` (which clips partial internal seams, merges coplanar faces,
// and dissolves pointless T-junction/miter vertices) followed by `mesh_op_simplify_and_clean_mesh()`.
@(private = "package")
_rebuild_editable_mesh_from_csg_hulls :: proc(hulls: []cad_csg.CSG_Convex) {
	if len(hulls) == 0 do return
	clean_polys := make([dynamic]cad_csg.CSG_Face_Poly, 0, len(hulls) * 6, context.temp_allocator)
	cad_csg.csg_extract_clean_polygons_from_hulls(hulls, &clean_polys, context.temp_allocator)
	if len(clean_polys) == 0 do return

	_clear_editable_mesh()
	weld_eps_sq :: f32(1e-5)
	for fp in clean_polys {
		if len(fp.verts) < 3 do continue
		f_inds := make([dynamic]u32, 0, len(fp.verts), context.temp_allocator)
		for pt in fp.verts {
			found := -1
			for ev, ei in _mesh_ed.verts {
				if linalg.length2(pt - ev) <= weld_eps_sq {
					found = ei
					break
				}
			}
			if found >= 0 {
				append(&f_inds, u32(found))
			} else {
				append(&f_inds, u32(len(_mesh_ed.verts)))
				append(&_mesh_ed.verts, pt)
			}
		}
		if len(f_inds) >= 3 {
			_add_poly_face(f_inds[:], fp.color)
		}
	}
	mesh_op_simplify_and_clean_mesh()
}

// Carves a boolean tunnel or recessed pocket prism from `base_ring` extruded along `drag_axis` by `delta` (`delta < 0`)
// into or right through the active `Editable_Poly_Mesh`, producing a clean, manifold, coplanar-merged pocket or open through-tunnel!
@(private = "package")
_carve_poly_prism_tunnel :: proc(base_ring: [][3]f32, face_n, drag_axis: [3]f32, delta: f32, extend_exit := true) {
	m := len(base_ring)
	if m < 3 || abs(delta) < 0.04 do return

	prev := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev

	col_u8 := [4]u8{
		u8(clamp(_mesh_ed.mesh_color.r * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.g * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.b * 255.0, 0, 255)),
		255,
	}

	// Build a convex cutter prism from `base_ring` expanded slightly at the entry (+0.08m)
	// and, when `extend_exit == true`, also expanded at the exit (+0.08m) so it punches cleanly through both faces!
	axis_n := linalg.normalize0(drag_axis)
	if linalg.length2(axis_n) < 0.5 do axis_n = linalg.normalize0(face_n)
	inward_dir := axis_n * (-1.0 if delta < 0 else 1.0)
	depth := abs(delta)
	exit_pad: f32 = 0.08 if extend_exit else 0.0

	p_start := make([][3]f32, m, context.temp_allocator)
	p_end   := make([][3]f32, m, context.temp_allocator)
	prism_c: [3]f32
	for i in 0 ..< m {
		p_start[i] = base_ring[i] - inward_dir * 0.08
		p_end[i]   = base_ring[i] + inward_dir * (depth + exit_pad)
		prism_c += p_start[i] + p_end[i]
	}
	prism_c /= f32(m * 2)

	cutter := cad_csg.CSG_Convex{
		planes = make([dynamic]cad_csg.CSG_Plane, 0, m + 2, alloc),
	}
	defer cad_csg.convex_destroy(&cutter)

	// Start & end cap planes of the prism
	d_start := linalg.dot(-inward_dir, p_start[0])
	d_end   := linalg.dot(inward_dir, p_end[0])
	append(&cutter.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{normal = -inward_dir, dist = d_start, uv_scale = 0.5, color = col_u8}))
	append(&cutter.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{normal =  inward_dir, dist = d_end,   uv_scale = 0.5, color = col_u8}))

	// Side wall planes around `base_ring`
	for i in 0 ..< m {
		va := base_ring[i]
		vb := base_ring[(i + 1) % m]
		edge_dir := vb - va
		wn := linalg.normalize0(linalg.cross(edge_dir, inward_dir))
		if linalg.length2(wn) < 0.25 do continue
		if linalg.dot(wn, va - prism_c) < 0 do wn = -wn
		wd := linalg.dot(wn, va)
		append(&cutter.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{normal = wn, dist = wd, uv_scale = 0.5, color = col_u8}))
	}

	if !cad_csg.convex_rebuild_bounds_and_prune(&cutter, prune_redundant = true) do return

	base_hulls := _decompose_editable_mesh_to_csg_hulls(false, alloc)
	defer {
		for &bh in base_hulls do cad_csg.convex_destroy(&bh)
		delete(base_hulls)
	}
	if len(base_hulls) == 0 do return

	cad_csg.convex_list_subtract(&base_hulls, cutter, alloc)
	if len(base_hulls) == 0 do return

	cad_csg.csg_clean_and_simplify_hulls(&base_hulls, alloc)
	_rebuild_editable_mesh_from_csg_hulls(base_hulls[:])
}

// Builds 1 or more smooth, rounded, non-cubey `CSG_Convex` hulls around an arbitrary triangle mesh
// (including non-watertight AI meshes, helmets, props, or posed skeletal statues) using Fibonacci-Sphere
// Multi-Angle 3D Line Traces (`_ray_triangle_intersect`) and k-DOP support planes:
// - `.Single_Bounding_Hull`: Fires 42 spherical line traces from all angles around the mesh to sculpt 1 smooth polyhedral hull.
// - `.Multi_Ray_Line_Trace`: Slices the mesh along its longest principal axis into `2..6` smooth sections and wraps each
//   section with 36 spherical multi-angle line-traced planes (producing rounded, form-fitting multi-hull CSG with ZERO cube voxels!).
// - `.Anatomy_Sliced_Statue`: Slices a posed humanoid rig or statue into vertical bands, separates disconnected limb/torso
//   islands (e.g. left/right legs, torso, arms, head), and wraps each island with 32 spherical radial line traces!
@(private = "package")
_build_csg_hulls_via_line_traces :: proc(
	verts:                [][3]f32,
	tris:                 [][3]u32,
	mode:                 cad_csg.CSG_Mesh_Wrap_Mode,
	grid_res:             int,
	make_dynamic_physics: bool,
	col_u8:               [4]u8,
	alloc := context.allocator,
) -> [dynamic]cad_csg.CSG_Convex {
	hulls := make([dynamic]cad_csg.CSG_Convex, 0, 16, alloc)
	if len(verts) < 3 || len(tris) < 1 do return hulls

	lo := verts[0]
	hi := verts[0]
	for v in verts[1:] {
		lo = linalg.min(lo, v)
		hi = linalg.max(hi, v)
	}
	ext := hi - lo
	if ext.x < 0.04 do hi.x += 0.04
	if ext.y < 0.04 do hi.y += 0.04
	if ext.z < 0.04 do hi.z += 0.04
	ext = hi - lo

	// Generate a Fibonacci-Sphere + Cardinal set of 3D ray directions so every hull is sculpted smoothly from all angles (zero cubiness!)
	build_spherical_ray_dirs :: proc(num_fibonacci: int, alloc := context.temp_allocator) -> [][3]f32 {
		n_fib := clamp(num_fibonacci, 18, 56)
		dirs := make([dynamic][3]f32, 0, n_fib + 6, alloc)
		cardinals := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
		for c in cardinals do append(&dirs, c)

		golden_angle :: f32(2.399963229728653) // pi * (3 - sqrt(5))
		for i in 0 ..< n_fib {
			y := 1.0 - (f32(i) / f32(max(n_fib - 1, 1))) * 2.0
			r := math.sqrt(max(1.0 - y * y, 0.0))
			theta := golden_angle * f32(i)
			d := linalg.normalize0([3]f32{math.cos(theta) * r, y, math.sin(theta) * r})
			if linalg.length2(d) < 0.5 do continue
			dup := false
			for ed in dirs {
				if linalg.dot(ed, d) > 0.965 {
					dup = true
					break
				}
			}
			if !dup do append(&dirs, d)
		}
		return dirs[:]
	}

	// Sculpts a single smooth, multi-angle `CSG_Convex` hull around `pts` by firing inward 3D line traces
	// along `ray_dirs` against `tris` and combining ray-hit surface normals with tight support planes!
	build_spherical_ray_hull_for_subset :: proc(
		pts:                  [][3]f32,
		all_verts:            [][3]f32,
		tris:                 [][3]u32,
		ray_dirs:             [][3]f32,
		anchored:             bool,
		brush_id:             u32,
		col:                  [4]u8,
		alloc:                runtime.Allocator,
	) -> (cad_csg.CSG_Convex, bool) {
		if len(pts) < 3 do return {}, false
		s_lo := pts[0]
		s_hi := pts[0]
		for p in pts[1:] {
			s_lo = linalg.min(s_lo, p)
			s_hi = linalg.max(s_hi, p)
		}
		center := (s_lo + s_hi) * 0.5
		radius := linalg.length(s_hi - s_lo) + 0.75

		h := cad_csg.CSG_Convex{
			planes   = make([dynamic]cad_csg.CSG_Plane, 0, len(ray_dirs) + 12, alloc),
			anchored = anchored,
			brush_id = brush_id,
		}

		add_hull_support_plane :: proc(h: ^cad_csg.CSG_Convex, raw_n: [3]f32, pts: [][3]f32, col: [4]u8, margin: f32 = 0.005) {
			n := linalg.normalize0(raw_n)
			if linalg.length2(n) < 0.25 do return
			for ep in h.planes {
				if linalg.dot(ep.normal, n) > 0.968 do return
			}
			max_d: f32 = -1e9
			for p in pts {
				d := linalg.dot(n, p)
				if d > max_d do max_d = d
			}
			append(&h.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
				normal   = n,
				dist     = max_d + margin,
				mat_slot = 0,
				uv_scale = 0.5,
				color    = col,
			}))
		}

		// 1. Add spherical ray-direction support planes
		for d in ray_dirs {
			add_hull_support_plane(&h, d, pts, col)
		}

		// 2. Fire inward line traces along `ray_dirs` toward `center` to capture exact surface normals on curved domes/visors!
		max_tri_scan := min(len(tris), 1200)
		tri_step := max(len(tris) / max_tri_scan, 1)
		for d in ray_dirs {
			ray := engine.Ray{
				origin    = center + d * radius,
				direction = -d,
			}
			best_t: f32 = 1e9
			best_n := d
			for ti := 0; ti < len(tris); ti += tri_step {
				tri := tris[ti]
				v0, v1, v2 := all_verts[tri[0]], all_verts[tri[1]], all_verts[tri[2]]
				if t_hit, ok := _ray_triangle_intersect(ray, v0, v1, v2); ok && t_hit < best_t {
					hit_p := ray.origin + ray.direction * t_hit
					if hit_p.x < s_lo.x - 0.08 || hit_p.x > s_hi.x + 0.08 ||
					   hit_p.y < s_lo.y - 0.08 || hit_p.y > s_hi.y + 0.08 ||
					   hit_p.z < s_lo.z - 0.08 || hit_p.z > s_hi.z + 0.08 {
						continue
					}
					best_t = t_hit
					tn := linalg.normalize0(linalg.cross(v1 - v0, v2 - v0))
					if linalg.dot(tn, d) < 0 do tn = -tn
					if linalg.length2(tn) > 0.25 do best_n = tn
				}
			}
			if best_t < 1e8 {
				add_hull_support_plane(&h, best_n, pts, col)
			}
		}

		if cad_csg.convex_rebuild_bounds_and_prune(&h, prune_redundant = true) {
			return h, true
		}
		cad_csg.convex_destroy(&h)
		return {}, false
	}

	// ------------------------------------------------------------------------
	// MULTIPASS REFINEMENT HELPER:
	// Pass 1 builds the base wrap hulls above; Passes `2..N` iteratively:
	//   1. Carve/split any hull whose internal mesh vertices have a pronounced concave waist/overhang,
	//   2. Fire a denser local spherical + grazing-bevel ray pass centered on each hull's local mesh vertices,
	//   3. Tighten every hull plane against the actual mesh vertices inside that hull (`margin = lerp(0.006, 0.0015, tightness)`),
	//   4. Slice off / prune any sub-hull with too few mesh vertices so zero empty lips remain!
	// ------------------------------------------------------------------------
	refine_hulls_multipass :: proc(
		hulls:                ^[dynamic]cad_csg.CSG_Convex,
		verts:                [][3]f32,
		tris:                 [][3]u32,
		make_dynamic_physics: bool,
		col_u8:               [4]u8,
		alloc:                runtime.Allocator,
	) {
		if !_ed.mesh_wrap_multipass || len(hulls) == 0 do return
		total_passes := clamp(int(_ed.mesh_wrap_passes), 2, 4)
		tightness    := clamp(_ed.mesh_wrap_tightness, 0.10, 1.00)
		tight_margin := linalg.lerp(f32(0.006), f32(0.0015), tightness)

		for pass_i in 2 ..= total_passes {
			pass_rays := build_spherical_ray_dirs(clamp(28 + pass_i * 10, 32, 60), context.temp_allocator)
			next_hulls := make([dynamic]cad_csg.CSG_Convex, 0, len(hulls) * 2, alloc)
			next_brush_id: u32 = 1

			for &h in hulls^ {
				// Gather mesh vertices and triangle centroids inside `h`
				sub_pts := make([dynamic][3]f32, 0, 128, context.temp_allocator)
				for v in verts {
					if !cad_csg.aabb_overlaps(v, v, h.aabb_min, h.aabb_max, 0.006) do continue
					in_h := true
					for p in h.planes {
						if linalg.dot(p.normal, v) - p.dist > 0.006 {
							in_h = false
							break
						}
					}
					if in_h do append(&sub_pts, v)
				}
				for tri in tris {
					tc := (verts[tri[0]] + verts[tri[1]] + verts[tri[2]]) * (1.0 / 3.0)
					if !cad_csg.aabb_overlaps(tc, tc, h.aabb_min, h.aabb_max, 0.004) do continue
					in_h := true
					for p in h.planes {
						if linalg.dot(p.normal, tc) - p.dist > 0.004 {
							in_h = false
							break
						}
					}
					if in_h do append(&sub_pts, tc)
				}

				// Prune empty lip hulls that contain almost no mesh points
				if len(sub_pts) < 3 {
					cad_csg.convex_destroy(&h)
					continue
				}

				// Check if `sub_pts` inside `h` has a concave taper/step along `h`'s longest axis
				// where splitting `h` in two allows a much tighter fit (e.g. helmet rim vs dome, visor recess)
				s_lo := sub_pts[0]
				s_hi := sub_pts[0]
				for sp in sub_pts[1:] {
					s_lo = linalg.min(s_lo, sp)
					s_hi = linalg.max(s_hi, sp)
				}
				s_ext := s_hi - s_lo
				split_axis := 1
				if s_ext.x >= s_ext.y && s_ext.x >= s_ext.z do split_axis = 0
				else if s_ext.z >= s_ext.x && s_ext.z >= s_ext.y do split_axis = 2

				did_split := false
				if tightness >= 0.45 && len(hulls) + len(next_hulls) < 18 && s_ext[split_axis] > 0.14 && len(sub_pts) >= 12 {
					mid_c := (s_lo[split_axis] + s_hi[split_axis]) * 0.5
					lo_pts := make([dynamic][3]f32, 0, len(sub_pts), context.temp_allocator)
					hi_pts := make([dynamic][3]f32, 0, len(sub_pts), context.temp_allocator)
					lo_min := [3]f32{ 1e9,  1e9,  1e9}
					lo_max := [3]f32{-1e9, -1e9, -1e9}
					hi_min := [3]f32{ 1e9,  1e9,  1e9}
					hi_max := [3]f32{-1e9, -1e9, -1e9}

					for sp in sub_pts {
						if sp[split_axis] <= mid_c + 0.005 {
							cp := sp
							cp[split_axis] = min(cp[split_axis], mid_c)
							append(&lo_pts, cp)
							lo_min = linalg.min(lo_min, cp)
							lo_max = linalg.max(lo_max, cp)
						}
						if sp[split_axis] >= mid_c - 0.005 {
							cp := sp
							cp[split_axis] = max(cp[split_axis], mid_c)
							append(&hi_pts, cp)
							hi_min = linalg.min(hi_min, cp)
							hi_max = linalg.max(hi_max, cp)
						}
					}

					if len(lo_pts) >= 4 && len(hi_pts) >= 4 {
						lo_w := linalg.length(lo_max - lo_min)
						hi_w := linalg.length(hi_max - hi_min)
						diff_ratio := abs(lo_w - hi_w) / max(max(lo_w, hi_w), 1e-4)
						if diff_ratio > (1.12 - tightness * 0.65) * 0.25 {
							h_lo, ok_lo := build_spherical_ray_hull_for_subset(lo_pts[:], verts, tris, pass_rays, !make_dynamic_physics, next_brush_id, col_u8, alloc)
							h_hi, ok_hi := build_spherical_ray_hull_for_subset(hi_pts[:], verts, tris, pass_rays, !make_dynamic_physics, next_brush_id + 1, col_u8, alloc)
							if ok_lo && ok_hi {
								next_brush_id += 2
								append(&next_hulls, h_lo, h_hi)
								cad_csg.convex_destroy(&h)
								did_split = true
							} else {
								if ok_lo do cad_csg.convex_destroy(&h_lo)
								if ok_hi do cad_csg.convex_destroy(&h_hi)
							}
						}
					}
				}

				if !did_split {
					// Tighten all existing planes of `h` to `sub_pts` + `tight_margin` and add finer pass_rays bevel planes
					for &p in h.planes {
						max_d: f32 = -1e9
						for sp in sub_pts {
							pr := linalg.dot(p.normal, sp)
							if pr > max_d do max_d = pr
						}
						if max_d > -1e8 {
							p.dist = min(p.dist, max_d + tight_margin)
						}
					}
					for d in pass_rays {
						dup := false
						for ep in h.planes {
							if linalg.dot(ep.normal, d) > (0.985 - tightness * 0.025) {
								dup = true
								break
							}
						}
						if !dup && len(h.planes) < 42 {
							max_d: f32 = -1e9
							for sp in sub_pts {
								pr := linalg.dot(d, sp)
								if pr > max_d do max_d = pr
							}
							if max_d > -1e8 {
								append(&h.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
									normal   = d,
									dist     = max_d + tight_margin,
									mat_slot = 0,
									uv_scale = 0.5,
									color    = col_u8,
								}))
							}
						}
					}
					if cad_csg.convex_rebuild_bounds_and_prune(&h, prune_redundant = true) {
						h.brush_id = next_brush_id
						next_brush_id += 1
						append(&next_hulls, h)
					} else {
						cad_csg.convex_destroy(&h)
					}
				}
			}

			delete(hulls^)
			hulls^ = next_hulls
		}
	}

	// ------------------------------------------------------------------------
	// MODE 1: Single Bounding Hull (Spherical Multi-Angle Ray Envelope — 0 Cubes!)
	// ------------------------------------------------------------------------
	if mode == .Single_Bounding_Hull {
		ray_dirs := build_spherical_ray_dirs(clamp(grid_res * 5, 28, 52), context.temp_allocator)
		if h, ok := build_spherical_ray_hull_for_subset(verts, verts, tris, ray_dirs, !make_dynamic_physics, 1, col_u8, alloc); ok {
			append(&hulls, h)
		}
		refine_hulls_multipass(&hulls, verts, tris, make_dynamic_physics, col_u8, alloc)
		return hulls
	}

	// ------------------------------------------------------------------------
	// MODE 2: Multi-Ray Line-Trace Sculptor (Smooth Multi-Section Spherical Ray Hulls — 0 Cubes!)
	// Slices the mesh along its longest principal axis into `2..6` sections (or radial sectors for rings)
	// and sculpts a smooth, rounded 36-direction spherical ray hull around each section!
	// ------------------------------------------------------------------------
	if mode == .Multi_Ray_Line_Trace {
		num_slices := clamp(grid_res / 2, 2, 6)
		ray_dirs := build_spherical_ray_dirs(clamp(grid_res * 4, 24, 44), context.temp_allocator)

		// Choose principal slicing axis (0=X, 1=Y, 2=Z) with largest extent (prefer Y for helmets/props if comparable)
		axis := 1
		if ext.x > ext.y * 1.25 && ext.x >= ext.z do axis = 0
		else if ext.z > ext.y * 1.25 && ext.z > ext.x do axis = 2

		step := ext[axis] / f32(num_slices)
		brush_seq: u32 = 1

		for s in 0 ..< num_slices {
			c0 := lo[axis] + f32(s) * step
			c1 := c0 + step
			slice_pts := make([dynamic][3]f32, 0, 128, context.temp_allocator)

			for v in verts {
				if v[axis] >= c0 - 0.008 && v[axis] <= c1 + 0.008 {
					clamped_v := v
					clamped_v[axis] = clamp(v[axis], c0, c1)
					append(&slice_pts, clamped_v)
				}
			}
			// Include exact triangle-edge intersections with slice boundary planes `c0` and `c1`
			for tri in tris {
				tv := [3][3]f32{verts[tri[0]], verts[tri[1]], verts[tri[2]]}
				for e in 0 ..< 3 {
					pa := tv[e]
					pb := tv[(e + 1) % 3]
					for cut_v in ([2]f32{c0, c1}) {
						if (pa[axis] < cut_v && pb[axis] > cut_v) || (pa[axis] > cut_v && pb[axis] < cut_v) {
							t := (cut_v - pa[axis]) / (pb[axis] - pa[axis])
							ipt := linalg.lerp(pa, pb, clamp(t, 0.0, 1.0))
							ipt[axis] = cut_v
							append(&slice_pts, ipt)
						}
					}
				}
			}
			if len(slice_pts) < 4 do continue

			if h, ok := build_spherical_ray_hull_for_subset(slice_pts[:], verts, tris, ray_dirs, !make_dynamic_physics, brush_seq, col_u8, alloc); ok {
				brush_seq += 1
				append(&hulls, h)
			}
		}

		refine_hulls_multipass(&hulls, verts, tris, make_dynamic_physics, col_u8, alloc)
		if len(hulls) > 1 {
			cad_csg.csg_clean_and_simplify_hulls(&hulls, alloc)
		}
		return hulls
	}

	// ------------------------------------------------------------------------
	// MODE 3: Anatomy Sliced Statue (Vertical Bands + Limb/Torso Island Separation + Spherical Ray Traces)
	// ------------------------------------------------------------------------
	bands := clamp(grid_res, 3, 10)
	dy := ext.y / f32(bands)
	brush_id_seq: u32 = 1
	statue_ray_dirs := build_spherical_ray_dirs(28, context.temp_allocator)

	for b in 0 ..< bands {
		y0 := lo.y + f32(b) * dy
		y1 := y0 + dy
		band_pts := make([dynamic][3]f32, 0, 128, context.temp_allocator)

		// 1. Collect vertices inside `[y0, y1]` and triangle-edge crossings with `y0` and `y1`
		for v in verts {
			if v.y >= y0 - 0.01 && v.y <= y1 + 0.01 {
				append(&band_pts, [3]f32{v.x, clamp(v.y, y0, y1), v.z})
			}
		}
		for tri in tris {
			tv := [3][3]f32{verts[tri[0]], verts[tri[1]], verts[tri[2]]}
			for e in 0 ..< 3 {
				pa := tv[e]
				pb := tv[(e + 1) % 3]
				for cut_y in ([2]f32{y0, y1}) {
					if (pa.y < cut_y && pb.y > cut_y) || (pa.y > cut_y && pb.y < cut_y) {
						t := (cut_y - pa.y) / (pb.y - pa.y)
						ipt := linalg.lerp(pa, pb, clamp(t, 0.0, 1.0))
						ipt.y = cut_y
						append(&band_pts, ipt)
					}
				}
			}
		}
		if len(band_pts) < 4 do continue

		// 2. Sort `band_pts` along X to detect separated anatomical islands (e.g. left leg vs right leg, arms vs torso!)
		slice.sort_by(band_pts[:], proc(a, b: [3]f32) -> bool {
			return a.x < b.x
		})
		gap_thresh := max(ext.x * 0.085, 0.06)
		island_starts := make([dynamic]int, 0, 4, context.temp_allocator)
		append(&island_starts, 0)
		for i in 1 ..< len(band_pts) {
			if band_pts[i].x - band_pts[i - 1].x > gap_thresh && len(island_starts) < 4 {
				append(&island_starts, i)
			}
		}
		append(&island_starts, len(band_pts))

		for isl in 0 ..< len(island_starts) - 1 {
			i_start := island_starts[isl]
			i_end   := island_starts[isl + 1]
			sub_pts := band_pts[i_start:i_end]
			if len(sub_pts) < 3 do continue

			// Ensure top and bottom of the band are represented so the slice hull has thickness
			isl_pts := make([dynamic][3]f32, 0, len(sub_pts) + 8, context.temp_allocator)
			s_lo := sub_pts[0]
			s_hi := sub_pts[0]
			for sp in sub_pts {
				s_lo = linalg.min(s_lo, sp)
				s_hi = linalg.max(s_hi, sp)
				append(&isl_pts, sp)
			}
			if s_hi.y - s_lo.y < dy * 0.35 {
				mid_xz := [2]f32{(s_lo.x + s_hi.x) * 0.5, (s_lo.z + s_hi.z) * 0.5}
				append(&isl_pts, [3]f32{mid_xz.x, y0, mid_xz.y})
				append(&isl_pts, [3]f32{mid_xz.x, y1, mid_xz.y})
			}

			if h, ok := build_spherical_ray_hull_for_subset(isl_pts[:], verts, tris, statue_ray_dirs, !make_dynamic_physics, brush_id_seq, col_u8, alloc); ok {
				brush_id_seq += 1
				append(&hulls, h)
			}
		}
	}

	refine_hulls_multipass(&hulls, verts, tris, make_dynamic_physics, col_u8, alloc)
	if len(hulls) > 1 {
		cad_csg.csg_clean_and_simplify_hulls(&hulls, alloc)
	}
	return hulls
}

// Draws the `CSG_Mesh_Wrap_Mode` enum selector + `Ray Detail / Slices` slider + `Multipass Tight Fit` controls
// so users can choose between `Exact_Face_Decompose`, `Single_Bounding_Hull`, `Multi_Ray_Line_Trace`, and `Anatomy_Sliced_Statue`.
@(private = "package")
_draw_csg_wrap_mode_selector :: proc(avail_w: f32) {
	_ensure_init()
	wrap_names := [4]cstring{
		"0: Exact Face Decompose (Low-Poly CAD / Tunnels)",
		"1: Single Smooth Ray Hull (Helmets / Props)",
		"2: Multi-Section Spherical Rays (Non-Watertight / AI)",
		"3: Anatomy Sliced Statue (Posed Rig / Humanoid)",
	}
	w_idx := clamp(i32(_ed.mesh_wrap_mode), 0, 3)
	im.SetNextItemWidth(avail_w - 78)
	if im.ComboChar("CSG Wrap", &w_idx, raw_data(wrap_names[:]), 4) {
		_ed.mesh_wrap_mode = cad_csg.CSG_Mesh_Wrap_Mode(w_idx)
	}
	widgets.tooltip(
		"Selects how Mesh -> CSG builds convex hulls:\n" +
		"• 0: Exact Face Decompose — exact concave-plane decomposition for low-poly CAD meshes (auto-switches to Spherical Rays if > 84 faces or non-watertight so it never freezes!).\n" +
		"• 1: Single Smooth Ray Hull — fires 42 spherical line traces from all angles to sculpt 1 smooth, rounded polyhedral hull (ideal for helmets/props!).\n" +
		"• 2: Multi-Section Spherical Rays — slices a complex or non-watertight AI mesh into 2..6 sections and wraps each with 36 spherical line traces (zero blocky cubes!).\n" +
		"• 3: Anatomy Sliced Statue — slices a posed skeletal rig or humanoid mesh into anatomical bands & limbs!",
	)
	if _ed.mesh_wrap_mode != .Exact_Face_Decompose {
		im.SetNextItemWidth(avail_w - 78)
		lbl: cstring = "Ray Detail" if _ed.mesh_wrap_mode == .Single_Bounding_Hull else ("Ray Sections" if _ed.mesh_wrap_mode == .Multi_Ray_Line_Trace else "Statue Slices")
		im.SliderInt(lbl, &_ed.line_trace_grid_res, 3, 12, "%d")
		widgets.tooltip("Controls spherical ray density and number of sculpted hull sections (3..12)")
	}
	im.Checkbox("Multipass Tight Fit & Lip Prune", &_ed.mesh_wrap_multipass)
	widgets.tooltip(
		"When enabled, runs 2..4 iterative refinement passes after the base wrap:\n" +
		"• Splits hulls with concave tapers/steps (e.g. helmet rim vs dome),\n" +
		"• Fires secondary local grazing rays to bevel and tighten every plane flush to the mesh,\n" +
		"• Slices off empty CSG lips that have no mesh inside them!",
	)
	if _ed.mesh_wrap_multipass {
		im.SetNextItemWidth((avail_w - 90) * 0.45)
		im.SliderInt("Passes", &_ed.mesh_wrap_passes, 2, 4, "%d")
		im.SameLine(0, 8)
		im.SetNextItemWidth((avail_w - 90) * 0.55)
		im.SliderFloat("Tightness", &_ed.mesh_wrap_tightness, 0.10, 1.00, "%.2f")
	}
}

// Converts the selected `Editable_Poly_Mesh`, high-poly `MeshFilter`, OR posed `ArmatureDeformedMesh` skeletal rig into CSG:
// - When `_ed.mesh_wrap_mode == .Exact_Face_Decompose`: uses exact concave-plane decomposition for low-poly CAD meshes
//   (and automatically delegates > 84-face or non-watertight meshes to Spherical Line Traces so it never freezes!).
// - When `_ed.mesh_wrap_mode` is `.Single_Bounding_Hull`, `.Multi_Ray_Line_Trace`, or `.Anatomy_Sliced_Statue` (or when wrapping
//   a posed `ArmatureDeformedMesh` skeletal character into a static/dynamic CSG statue!): fires spherical line traces at the triangles
//   to build smooth, rounded CSG hulls and preserves the mesh's material & Faker CSG reference!
convert_editable_mesh_to_csg :: proc(make_dynamic_physics := false, append_to_active_volume := false) -> engine.Transform_Handle {
	_ensure_init()
	_ensure_mesh_ed_init()

	prev := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev

	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return {}

	sel_h := engine.inspector_active_selection()
	target_h := _mesh_ed.target_owner
	if sel_h != {} && engine.pool_valid(&w.transforms, engine.Handle(sel_h)) {
		target_h = sel_h
	}

	// Inherit any existing material from the target entity's MeshRenderer and use neutral white/silver vertex color
	// instead of `_mesh_ed.mesh_color`'s green wireframe highlight!
	inherited_mat_guid: engine.Asset_GUID = {}
	existing_csg_vol: ^cad_csg.CSGVolume = nil
	if target_h != {} && engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
		_, existing_csg_vol = engine.transform_get_comp(target_h, cad_csg.CSGVolume)
		if _, mr_existing := engine.transform_get_comp(target_h, engine.MeshRenderer); mr_existing != nil && len(mr_existing.materials) > 0 {
			inherited_mat_guid = mr_existing.materials[0]
		} else if existing_csg_vol != nil {
			if !engine.asset_guid_is_empty(existing_csg_vol.orig_source_mat_guid) {
				inherited_mat_guid = existing_csg_vol.orig_source_mat_guid
			} else if !engine.asset_guid_is_empty(existing_csg_vol.custom_material_guid) {
				inherited_mat_guid = existing_csg_vol.custom_material_guid
			}
		}
	}
	col_u8 := [4]u8{255, 255, 255, 255} if !engine.asset_guid_is_empty(inherited_mat_guid) else [4]u8{220, 224, 230, 255}

	// Check if the selected object (or a child of the selected ControlRig root) has a posed `ArmatureDeformedMesh`
	// (including when `arm_c.enabled` was disabled by a previous Mesh->CSG conversion on the same object so the user can re-wrap it!).
	posed_arm: ^control_rig.ArmatureDeformedMesh = nil
	posed_arm_owner: engine.Transform_Handle = {}
	if target_h != {} && engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
		if _, arm_c := engine.transform_get_comp(target_h, control_rig.ArmatureDeformedMesh); arm_c != nil && (arm_c.enabled || existing_csg_vol != nil) {
			posed_arm = arm_c
			posed_arm_owner = target_h
		} else if t_node := engine.pool_get(&w.transforms, engine.Handle(target_h)); t_node != nil {
			for ch_ref in t_node.children {
				ch_h := engine.Transform_Handle(ch_ref.handle)
				if _, arm_ch := engine.transform_get_comp(ch_h, control_rig.ArmatureDeformedMesh); arm_ch != nil && (arm_ch.enabled || existing_csg_vol != nil) {
					posed_arm = arm_ch
					posed_arm_owner = ch_h
					target_h = ch_h
					break
				}
			}
		}
	}

	// If re-wrapping an already-converted Editable Poly Mesh in `.Exact_Face_Decompose` mode, make sure `_mesh_ed` is populated from `MeshFilter`
	if posed_arm == nil && _ed.mesh_wrap_mode == .Exact_Face_Decompose && (len(_mesh_ed.verts) < 4 || _mesh_ed.target_owner != target_h) {
		if existing_csg_vol != nil {
			prev_csg_en := existing_csg_vol.enabled
			existing_csg_vol.enabled = false
			_sync_mesh_editor_with_selection()
			existing_csg_vol.enabled = prev_csg_en
		} else {
			_sync_mesh_editor_with_selection()
		}
	}

	frozen_statue_guid: engine.Asset_GUID = {}
	hulls: [dynamic]cad_csg.CSG_Convex

	if posed_arm != nil {
		prev_arm_en := posed_arm.enabled
		posed_arm.enabled = true
		// Extract current posed skeletal mesh geometry and freeze it into a static procedural mesh for Faker CSG statue rendering!
		if p_verts, p_inds, _, p_ok := control_rig.armature_extract_posed_local_geometry(posed_arm_owner, context.temp_allocator); p_ok && len(p_verts) >= 3 && len(p_inds) >= 3 {
			frozen_statue_guid = cad_csg.make_procedural_guid(posed_arm_owner, 0x5354_4154) // 'STAT'
			engine.mesh_upsert_procedural(frozen_statue_guid, p_verts, p_inds)

			pts := make([][3]f32, len(p_verts), context.temp_allocator)
			for pv, i in p_verts do pts[i] = pv.position
			tri_cnt := len(p_inds) / 3
			tris := make([][3]u32, tri_cnt, context.temp_allocator)
			for ti in 0 ..< tri_cnt {
				tris[ti] = {p_inds[ti * 3 + 0], p_inds[ti * 3 + 1], p_inds[ti * 3 + 2]}
			}
			use_mode := _ed.mesh_wrap_mode
			if use_mode == .Exact_Face_Decompose {
				// Default posed skeletal statues to Anatomy_Sliced_Statue if Exact_Face_Decompose was selected
				use_mode = .Anatomy_Sliced_Statue
			}
			hulls = _build_csg_hulls_via_line_traces(pts, tris, use_mode, int(_ed.line_trace_grid_res), make_dynamic_physics, col_u8, alloc)
			// Disable live skeletal deformation on the converted statue entity so it stays frozen as a CSG statue!
			posed_arm.enabled = false
		} else {
			posed_arm.enabled = prev_arm_en
		}
	} else if _ed.mesh_wrap_mode == .Exact_Face_Decompose && len(_mesh_ed.verts) >= 4 && len(_mesh_ed.faces) >= 4 {
		hulls = _decompose_editable_mesh_to_csg_hulls(make_dynamic_physics, alloc)
		if target_h != {} && engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
			if _, mf := engine.transform_get_comp(target_h, engine.MeshFilter); mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
				frozen_statue_guid = mf.mesh.guid
			}
		}
	} else {
		// Build triangle list from either `MeshFilter`, `existing_csg_vol.orig_source_mesh_guid`, or `_mesh_ed`
		pts := make([dynamic][3]f32, 0, 256, context.temp_allocator)
		tris := make([dynamic][3]u32, 0, 256, context.temp_allocator)
		if target_h != {} && engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
			if _, mf := engine.transform_get_comp(target_h, engine.MeshFilter); mf != nil {
				if engine.asset_guid_is_empty(mf.mesh.guid) && existing_csg_vol != nil {
					src_guid := existing_csg_vol.orig_source_mesh_guid
					if engine.asset_guid_is_empty(src_guid) do src_guid = existing_csg_vol.faker_mesh_guid
					if !engine.asset_guid_is_empty(src_guid) {
						mf.mesh = engine.PPtr{guid = src_guid, local_id = 0}
					}
				}
				if cpu_v, cpu_i, ok := engine.mesh_read_cpu_geometry(mf, context.temp_allocator); ok && len(cpu_v) >= 3 && len(cpu_i) >= 3 {
					for cv in cpu_v do append(&pts, cv.position)
					tc := len(cpu_i) / 3
					for ti in 0 ..< tc {
						append(&tris, [3]u32{cpu_i[ti * 3 + 0], cpu_i[ti * 3 + 1], cpu_i[ti * 3 + 2]})
					}
					if !engine.asset_guid_is_empty(mf.mesh.guid) {
						frozen_statue_guid = mf.mesh.guid
					}
				}
			}
		}
		if len(pts) == 0 && len(_mesh_ed.verts) >= 4 && len(_mesh_ed.faces) >= 4 {
			for v in _mesh_ed.verts do append(&pts, v)
			for f in _mesh_ed.faces {
				if len(f.verts) < 3 do continue
				for ti in 1 ..< len(f.verts) - 1 {
					append(&tris, [3]u32{f.verts[0], f.verts[ti], f.verts[ti + 1]})
				}
			}
		}
		if len(pts) >= 3 && len(tris) >= 1 {
			use_mode := _ed.mesh_wrap_mode
			if use_mode == .Exact_Face_Decompose {
				use_mode = .Multi_Ray_Line_Trace
			}
			hulls = _build_csg_hulls_via_line_traces(pts[:], tris[:], use_mode, int(_ed.line_trace_grid_res), make_dynamic_physics, col_u8, alloc)
		}
	}

	if len(hulls) == 0 {
		delete(hulls)
		return {}
	}
	defer delete(hulls)

	if append_to_active_volume {
		vol, owner := _resolve_active_volume(create_if_missing = true)
		if vol != nil {
			if vol.runtime_hulls == nil {
				vol.runtime_hulls = make([dynamic]cad_csg.CSG_Convex, 0, len(hulls) + 4, alloc)
			}
			// Offset hull planes by target_h relative to volume owner if needed
			delta := [3]f32{0, 0, 0}
			if target_h != {} && engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
				tw_mesh := engine.transform_world(target_h)
				tw_vol  := engine.transform_world(owner)
				delta   = tw_mesh.position - tw_vol.position
				if target_h != owner {
					if _, mr := engine.transform_get_comp(target_h, engine.MeshRenderer); mr != nil {
						mr.enabled = false
					}
				}
			}
			for &h in hulls {
				if linalg.length2(delta) > 1e-6 {
					for &p in h.planes {
						p.dist += linalg.dot(p.normal, delta)
					}
					cad_csg.convex_rebuild_bounds_and_prune(&h, prune_redundant = false)
				}
				append(&vol.runtime_hulls, h)
			}
			cad_csg.csg_volume_rebuild(vol)
			scene.dirty = true
			_mesh_ed.target_owner = owner
			_mesh_ed.workspace_tab = .CSG_Editor
			engine.inspector_set_active_selection(owner)
			engine.inspector_request_select(owner)
			return owner
		}
	}

	// Create or upgrade `target_h` into a standalone `CSGVolume`!
	if target_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
		root_h := engine.Transform_Handle(scene.root.handle)
		target_h = engine.transform_new("Converted_CSG_Mesh", root_h)
		engine.transform_ensure_unique_name(target_h)
	} else {
		// Disable temporary MeshRenderer on the editable mesh / posed statue entity so CSGVolume's chunk renderer takes over cleanly
		if _, mr := engine.transform_get_comp(target_h, engine.MeshRenderer); mr != nil {
			mr.enabled = false
		}
	}

	_, vol := engine.transform_get_comp(target_h, cad_csg.CSGVolume)
	if vol == nil {
		_, ptr := engine.transform_add_comp(target_h, .CSGVolume)
		vol = cast(^cad_csg.CSGVolume)ptr
		if vol != nil do cad_csg.reset_CSGVolume(vol)
	}
	if vol != nil {
		vol.enabled = true
		vol.converted_from_mesh = true
		if vol.brushes != nil {
			for &b in vol.brushes {
				if len(b.name) > 0 do delete(b.name)
				if b.profile_points != nil do delete(b.profile_points)
			}
			clear(&vol.brushes)
		}
		if vol.recorded_blasts != nil {
			clear(&vol.recorded_blasts)
		}
		if vol.runtime_hulls != nil {
			for &old_h in vol.runtime_hulls do cad_csg.convex_destroy(&old_h)
			clear(&vol.runtime_hulls)
		} else {
			vol.runtime_hulls = make([dynamic]cad_csg.CSG_Convex, 0, len(hulls), alloc)
		}
		for h in hulls do append(&vol.runtime_hulls, h)
		vol.is_dynamic_rigidbody = make_dynamic_physics
		if !engine.asset_guid_is_empty(inherited_mat_guid) {
			if engine.asset_guid_is_empty(vol.orig_source_mat_guid) {
				vol.orig_source_mat_guid = inherited_mat_guid
			}
			vol.custom_material_guid = inherited_mat_guid
			vol.faker_material_guid  = inherited_mat_guid
		}
		if !engine.asset_guid_is_empty(frozen_statue_guid) {
			if engine.asset_guid_is_empty(vol.orig_source_mesh_guid) {
				vol.orig_source_mesh_guid = frozen_statue_guid
			}
			vol.faker_mesh_guid = frozen_statue_guid
		} else if engine.asset_guid_is_empty(vol.faker_mesh_guid) && !engine.asset_guid_is_empty(_mesh_ed.mesh_guid) {
			if engine.asset_guid_is_empty(vol.orig_source_mesh_guid) {
				vol.orig_source_mesh_guid = _mesh_ed.mesh_guid
			}
			vol.faker_mesh_guid = _mesh_ed.mesh_guid
		}
		cad_csg.csg_volume_rebuild(vol)
		cad_csg.csg_volume_sync_colliders_only(vol)
	}
	scene.dirty = true
	_mesh_ed.target_owner = target_h
	_mesh_ed.workspace_tab = .CSG_Editor
	engine.inspector_set_active_selection(target_h)
	engine.inspector_request_select(target_h)
	return target_h
}

// Returns true if `target_h` (or the active selection) is a `CSGVolume` that was converted from a Mesh or Posed Skeletal Rig
// and can be reverted back to the original Mesh (`revert_csg_to_original_mesh`) or re-wrapped in-place with another `CSG_Mesh_Wrap_Mode`.
can_revert_or_rewrap_csg_mesh :: proc(target_h_in: engine.Transform_Handle = {}) -> bool {
	w := engine.ctx_world()
	if w == nil do return false
	th := target_h_in
	if th == {} do th = engine.inspector_active_selection()
	if th == {} || !engine.pool_valid(&w.transforms, engine.Handle(th)) do return false

	_, vol := engine.transform_get_comp(th, cad_csg.CSGVolume)
	if vol == nil || !vol.enabled do return false
	if vol.converted_from_mesh || !engine.asset_guid_is_empty(vol.orig_source_mesh_guid) do return true
	if _, mf := engine.transform_get_comp(th, engine.MeshFilter); mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) do return true
	if _, arm := engine.transform_get_comp(th, control_rig.ArmatureDeformedMesh); arm != nil do return true
	return false
}

// Resets all Ghoul CSG wounds & severed limbs on the selected character rig or bone if present.
reset_ghoul_wounds_if_any :: proc(target_h_in: engine.Transform_Handle = {}) {
	th := target_h_in
	if th == {} do th = engine.inspector_active_selection()
	if th == {} do return
	_ = control_rig.smart_collider_reset_ghoul_wounds(th)
}

// Reverts a converted `CSGVolume` back to its original `MeshFilter + MeshRenderer` (or `ArmatureDeformedMesh` skeletal rig),
// freeing all CSG chunks and Jolt colliders so the user can undo a Mesh->CSG conversion in 1 click!
revert_csg_to_original_mesh :: proc(target_h_in: engine.Transform_Handle = {}) -> bool {
	_ensure_init()
	_ensure_mesh_ed_init()

	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return false

	target_h := target_h_in
	if target_h == {} do target_h = engine.inspector_active_selection()
	if target_h == {} do target_h = _mesh_ed.target_owner
	if target_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(target_h)) do return false

	_, vol := engine.transform_get_comp(target_h, cad_csg.CSGVolume)
	if vol == nil do return false

	orig_mesh_guid := vol.orig_source_mesh_guid
	if engine.asset_guid_is_empty(orig_mesh_guid) do orig_mesh_guid = vol.faker_mesh_guid
	orig_mat_guid := vol.orig_source_mat_guid
	if engine.asset_guid_is_empty(orig_mat_guid) do orig_mat_guid = vol.custom_material_guid

	// Free all CSG runtime chunks, GPU procedural chunk meshes, and Jolt static/dynamic physics bodies!
	cad_csg.csg_volume_free_runtime(vol)
	if vol.runtime_hulls != nil {
		for &h in vol.runtime_hulls do cad_csg.convex_destroy(&h)
		clear(&vol.runtime_hulls)
	}
	if vol.recorded_blasts != nil {
		clear(&vol.recorded_blasts)
	}
	vol.is_faker_mesh = false
	vol.enabled       = false

	// Restore either the Posed Skeletal `ArmatureDeformedMesh` OR the static/editable `MeshFilter + MeshRenderer`
	restored_arm := false
	if _, arm_c := engine.transform_get_comp(target_h, control_rig.ArmatureDeformedMesh); arm_c != nil {
		arm_c.enabled = true
		restored_arm  = true
	}
	if !restored_arm {
		_, mf := engine.transform_get_comp(target_h, engine.MeshFilter)
		if mf == nil && !engine.asset_guid_is_empty(orig_mesh_guid) {
			_, ptr := engine.transform_add_comp(target_h, .MeshFilter)
			mf = cast(^engine.MeshFilter)ptr
		}
		if mf != nil {
			mf.enabled = true
			if engine.asset_guid_is_empty(mf.mesh.guid) && !engine.asset_guid_is_empty(orig_mesh_guid) {
				mf.mesh = engine.PPtr{guid = orig_mesh_guid, local_id = 0}
			}
		}

		_, mr := engine.transform_get_comp(target_h, engine.MeshRenderer)
		if mr == nil {
			_, ptr := engine.transform_add_comp(target_h, .MeshRenderer)
			mr = cast(^engine.MeshRenderer)ptr
		}
		if mr != nil {
			mr.enabled = true
			if len(mr.materials) == 0 && !engine.asset_guid_is_empty(orig_mat_guid) {
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				append(&mr.materials, orig_mat_guid)
				context.allocator = prev_alloc
			}
		}
	}

	_mesh_ed.workspace_tab = .Mesh_Editor
	_ed.tool_active        = false
	_sync_mesh_editor_with_selection()
	scene.dirty = true
	engine.inspector_request_select(target_h)
	return true
}

// ============================================================================
// UNREAL MODELING MODE + AUTOCAD 3D WIREFRAME + BLENDER POLYMODEL OPERATIONS
// ============================================================================

// Intrudes the selected Face inward into the mesh (insets by `inset_ratio` if on a full outer wall face
// and pushes inward by `-abs(depth)` along the face normal or active World Axis Lock `X`/`Y`/`Z`) — creates
// recessed windows, vents, grilles, or automatically punches an open through-tunnel if `depth` reaches the opposite face!
mesh_op_intrude_selected_face :: proc(depth: f32, inset_ratio: f32) {
	_ensure_mesh_ed_init()
	if _mesh_ed.selected_face < 0 || _mesh_ed.selected_face >= len(_mesh_ed.faces) do return

	f_idx := _mesh_ed.selected_face
	orig_f := _mesh_ed.faces[f_idx]
	if len(orig_f.verts) < 3 do return
	fn, fc := _face_normal_and_center(orig_f)
	drag_dir := fn
	if _mesh_ed.axis_lock == .X do drag_dir = {1, 0, 0} if fn.x >= 0 else {-1, 0, 0}
	if _mesh_ed.axis_lock == .Y do drag_dir = {0, 1, 0} if fn.y >= 0 else {0, -1, 0}
	if _mesh_ed.axis_lock == .Z do drag_dir = {0, 0, 1} if fn.z >= 0 else {0, 0, -1}

	ring_pts := make([][3]f32, len(orig_f.verts), context.temp_allocator)
	for vi, i in orig_f.verts {
		ring_pts[i] = _mesh_ed.verts[vi]
	}
	// Only inset if the face covers the full outer cross-section (avoid double-insetting if user already ran Inset!)
	if _face_ring_covers_full_cross_section(ring_pts, fn) {
		t_ins := clamp(inset_ratio, 0.08, 0.75)
		for &p in ring_pts {
			p = linalg.lerp(p, fc, t_ins)
		}
	}

	min_mesh_d := max(f32)
	max_mesh_d := -max(f32)
	for v in _mesh_ed.verts {
		d := linalg.dot(fn, v)
		min_mesh_d = min(min_mesh_d, d)
		max_mesh_d = max(max_mesh_d, d)
	}
	pushed_d := linalg.dot(fn, fc - drag_dir * abs(depth))
	is_through := (pushed_d <= min_mesh_d + 0.15)
	use_depth := abs(depth)
	if is_through {
		use_depth = max(use_depth, (max_mesh_d - min_mesh_d) + 0.25)
	}
	_carve_poly_prism_tunnel(ring_pts, fn, drag_dir, -use_depth, extend_exit = is_through)
}

// 1-Click Through-Tunnel Carver: Punches a clean, watertight open boolean tunnel straight through the mesh
// from the selected face to the opposite side (automatically insetting by `inset_ratio` if the selected face is a full outer wall!).
mesh_op_carve_tunnel_selected_face :: proc(inset_ratio: f32) {
	_ensure_mesh_ed_init()
	if _mesh_ed.selected_face < 0 || _mesh_ed.selected_face >= len(_mesh_ed.faces) {
		if len(_mesh_ed.faces) > 0 {
			_mesh_ed.selected_face = 0
		} else {
			return
		}
	}
	f_idx := _mesh_ed.selected_face
	orig_f := _mesh_ed.faces[f_idx]
	if len(orig_f.verts) < 3 do return
	fn, fc := _face_normal_and_center(orig_f)
	drag_dir := fn
	if _mesh_ed.axis_lock == .X do drag_dir = {1, 0, 0} if fn.x >= 0 else {-1, 0, 0}
	if _mesh_ed.axis_lock == .Y do drag_dir = {0, 1, 0} if fn.y >= 0 else {0, -1, 0}
	if _mesh_ed.axis_lock == .Z do drag_dir = {0, 0, 1} if fn.z >= 0 else {0, 0, -1}

	ring_pts := make([][3]f32, len(orig_f.verts), context.temp_allocator)
	for vi, i in orig_f.verts {
		ring_pts[i] = _mesh_ed.verts[vi]
	}
	if _face_ring_covers_full_cross_section(ring_pts, fn) {
		t_ins := clamp(inset_ratio, 0.12, 0.70)
		for &p in ring_pts {
			p = linalg.lerp(p, fc, t_ins)
		}
	}

	min_d := max(f32)
	max_d := -max(f32)
	for v in _mesh_ed.verts {
		d := linalg.dot(fn, v)
		min_d = min(min_d, d)
		max_d = max(max_d, d)
	}
	thick := max(max_d - min_d, 1.0)
	_carve_poly_prism_tunnel(ring_pts, fn, drag_dir, -(thick + 0.30), extend_exit = true)
}

// Blender-Style Edge Loop Cut (`Ctrl+R`): Splits all polygon faces straddling the plane `v[axis] = offset`
// into two clean faces WITHOUT deleting either side or adding internal caps, and selects the new ring vertices!
mesh_op_loop_cut :: proc(axis: int, offset: f32) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	ax := clamp(axis, 0, 2)
	n := [3]f32{0, 0, 0}
	n[ax] = 1.0

	new_faces := make([dynamic]Editable_Poly_Face, 0, len(_mesh_ed.faces) * 2)
	for &f in _mesh_ed.faces {
		m := len(f.verts)
		if m < 3 {
			delete(f.verts)
			continue
		}
		neg_loop := make([dynamic]u32, 0, m + 2)
		pos_loop := make([dynamic]u32, 0, m + 2)
		for i in 0 ..< m {
			ia := f.verts[i]
			ib := f.verts[(i + 1) % m]
			va := _mesh_ed.verts[ia]
			vb := _mesh_ed.verts[ib]
			da := linalg.dot(n, va) - offset
			db := linalg.dot(n, vb) - offset
			if da <= 1e-4 {
				append(&neg_loop, ia)
			}
			if da >= -1e-4 {
				append(&pos_loop, ia)
			}
			if (da < -1e-4 && db > 1e-4) || (da > 1e-4 && db < -1e-4) {
				t := da / (da - db)
				ipt := linalg.lerp(va, vb, clamp(t, 0.0, 1.0))
				new_vi := u32(len(_mesh_ed.verts))
				append(&_mesh_ed.verts, ipt)
				append(&neg_loop, new_vi)
				append(&pos_loop, new_vi)
			}
		}
		delete(f.verts)
		if len(neg_loop) >= 3 {
			append(&new_faces, Editable_Poly_Face{verts = neg_loop, color = f.color})
		} else {
			delete(neg_loop)
		}
		if len(pos_loop) >= 3 {
			append(&new_faces, Editable_Poly_Face{verts = pos_loop, color = f.color})
		} else {
			delete(pos_loop)
		}
	}
	delete(_mesh_ed.faces)
	_mesh_ed.faces = new_faces
	mesh_op_weld_vertices(0.005)

	// Automatically select the newly cut edge-ring vertices so the user can immediately scale/move the loop!
	_mesh_ed.select_mode = .Vertex
	clear(&_mesh_ed.selected_verts)
	for v, vi in _mesh_ed.verts {
		if abs(v[ax] - offset) <= 0.015 {
			append(&_mesh_ed.selected_verts, u32(vi))
		}
	}
	_rebuild_editable_mesh_gpu(commit = true)
}

// Mirrors all +X faces across X=0 to -X and welds centerline vertices (Blender Mirror Modifier for cars/props!)
mesh_op_mirror_x :: proc() {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	orig_f_cnt := len(_mesh_ed.faces)
	for fi in 0 ..< orig_f_cnt {
		f := _mesh_ed.faces[fi]
		_, fc := _face_normal_and_center(f)
		if fc.x <= 0.02 do continue // Only mirror +X faces across X=0
		m := len(f.verts)
		mir_ring := make([dynamic]u32, m, context.temp_allocator)
		for i in 0 ..< m {
			// Reverse winding order because reflection across X=0 flips handedness!
			src_v := _mesh_ed.verts[f.verts[m - 1 - i]]
			mv := [3]f32{-src_v.x, src_v.y, src_v.z}
			if abs(src_v.x) < 0.04 {
				mv.x = 0
				_mesh_ed.verts[f.verts[m - 1 - i]].x = 0
			}
			idx := u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, mv)
			mir_ring[i] = idx
		}
		_add_poly_face(mir_ring[:], f.color)
	}
	mesh_op_weld_vertices(0.04)
	mesh_op_recalculate_outward_normals()
}

// AutoCAD 3D Wireframe Skinner: Automatically finds closed 3-edge and 4-edge wireframe loops
// in `_mesh_ed.wire_edges` and skins them into polygon faces!
mesh_op_skin_wireframe_to_faces :: proc() {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.wire_edges) < 3 do return

	has_edge :: proc(u, v: u32) -> bool {
		a, b := min(u, v), max(u, v)
		for e in _mesh_ed.wire_edges {
			if min(e[0], e[1]) == a && max(e[0], e[1]) == b do return true
		}
		return false
	}

	face_exists :: proc(loop: []u32) -> bool {
		for f in _mesh_ed.faces {
			if len(f.verts) != len(loop) do continue
			matches := 0
			for lv in loop {
				for fv in f.verts {
					if lv == fv { matches += 1; break }
				}
			}
			if matches == len(loop) do return true
		}
		return false
	}

	vn := u32(len(_mesh_ed.verts))
	// 1. Skin 3-edge triangles
	for a in 0 ..< vn {
		for b in a + 1 ..< vn {
			if !has_edge(a, b) do continue
			for c in b + 1 ..< vn {
				if has_edge(b, c) && has_edge(c, a) {
					tri := [3]u32{a, b, c}
					if !face_exists(tri[:]) {
						_add_poly_face(tri[:])
					}
				}
			}
		}
	}
	// 2. Skin 4-edge quads (a - b - c - d - a without diagonal chords)
	for e1, i1 in _mesh_ed.wire_edges {
		a, b := e1[0], e1[1]
		for e2, i2 in _mesh_ed.wire_edges {
			if i1 == i2 do continue
			if e2[0] == a || e2[1] == a || e2[0] == b || e2[1] == b do continue
			c, d := e2[0], e2[1]
			if has_edge(b, c) && has_edge(d, a) && !has_edge(a, c) && !has_edge(b, d) {
				quad := [4]u32{a, b, c, d}
				if !face_exists(quad[:]) {
					_add_poly_face(quad[:])
				}
			} else if has_edge(b, d) && has_edge(c, a) && !has_edge(a, d) && !has_edge(b, c) {
				quad := [4]u32{a, b, d, c}
				if !face_exists(quad[:]) {
					_add_poly_face(quad[:])
				}
			}
		}
	}
	mesh_op_recalculate_outward_normals()
}

// Converts the 3D Wireframe Cage (or current polygon edges) into a 3D Tubular Strut / Rollcage Mesh!
mesh_op_wireframe_to_tubes :: proc(tube_r: f32) {
	_ensure_mesh_ed_init()
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	r := clamp(tube_r, 0.02, 0.50)
	edges := make([dynamic][2][3]f32, 0, 64, context.temp_allocator)
	if len(_mesh_ed.wire_edges) > 0 {
		for e in _mesh_ed.wire_edges {
			if int(e[0]) < len(_mesh_ed.verts) && int(e[1]) < len(_mesh_ed.verts) {
				append(&edges, [2][3]f32{_mesh_ed.verts[e[0]], _mesh_ed.verts[e[1]]})
			}
		}
	} else {
		for f in _mesh_ed.faces {
			m := len(f.verts)
			for i in 0 ..< m {
				u := f.verts[i]
				v := f.verts[(i + 1) % m]
				if u < v && int(u) < len(_mesh_ed.verts) && int(v) < len(_mesh_ed.verts) {
					append(&edges, [2][3]f32{_mesh_ed.verts[u], _mesh_ed.verts[v]})
				}
			}
		}
	}
	if len(edges) == 0 do return

	_clear_editable_mesh()
	for seg in edges {
		p0, p1 := seg[0], seg[1]
		dir := p1 - p0
		if linalg.length(dir) < 0.02 do continue
		n_dir := linalg.normalize(dir)
		u_ax, v_ax := cad_csg.plane_tangent_basis(n_dir)
		b := u32(len(_mesh_ed.verts))
		corners := [4][3]f32{
			(-u_ax - v_ax) * r, (u_ax - v_ax) * r, (u_ax + v_ax) * r, (-u_ax + v_ax) * r,
		}
		for c in corners do append(&_mesh_ed.verts, p0 + c)
		for c in corners do append(&_mesh_ed.verts, p1 + c)
		for k in 0 ..< 4 {
			nk := u32((k + 1) % 4)
			k0 := u32(k)
			_add_poly_face({b + k0, b + nk, b + 4 + nk, b + 4 + k0})
		}
		_add_poly_face({b + 0, b + 3, b + 2, b + 1})
		_add_poly_face({b + 4, b + 5, b + 6, b + 7})
	}
	_rebuild_editable_mesh_gpu()
}

// Unreal `PathRev`: Revolves / Lathes the current vertex profile 360 degrees around the Y axis (for wheels, tires, pillars, domes)!
mesh_op_lathe_revolve :: proc(segments: int) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.verts) < 2 do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	segs := clamp(segments, 6, 24)
	// Extract profile points `(radius_xz, y)` from unique heights/radii
	prof := make([dynamic][2]f32, 0, 16, context.temp_allocator)
	for v in _mesh_ed.verts {
		r_xz := max(math.sqrt(v.x * v.x + v.z * v.z), 0.15)
		dup := false
		for p in prof {
			if abs(p.x - r_xz) < 0.05 && abs(p.y - v.y) < 0.05 { dup = true; break }
		}
		if !dup && len(prof) < 12 {
			append(&prof, [2]f32{r_xz, v.y})
		}
	}
	if len(prof) < 2 do return

	_clear_editable_mesh()
	pn := len(prof)
	for s in 0 ..< segs {
		ang := f32(s) * (2.0 * math.PI / f32(segs))
		ca, sa := math.cos(ang), math.sin(ang)
		for p in prof {
			append(&_mesh_ed.verts, [3]f32{ca * p.x, p.y, sa * p.x})
		}
	}
	for s in 0 ..< segs {
		ns := (s + 1) % segs
		for i in 0 ..< pn {
			ni := (i + 1) % pn
			v00 := u32(s * pn + i)
			v10 := u32(ns * pn + i)
			v11 := u32(ns * pn + ni)
			v01 := u32(s * pn + ni)
			_add_poly_face({v00, v10, v11, v01})
		}
	}
	mesh_op_recalculate_outward_normals()
}

// Unreal `PlnCut`: Slices the editable mesh cleanly across a 3D plane (`axis`: 0=X, 1=Y, 2=Z at `offset`)
// and automatically caps the sliced cross-section!
mesh_op_plane_cut :: proc(axis: int, offset: f32, keep_neg: bool) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	ax := clamp(axis, 0, 2)
	n := [3]f32{0, 0, 0}
	n[ax] = 1.0 if keep_neg else -1.0
	d_plane := offset if keep_neg else -offset

	new_faces := make([dynamic]Editable_Poly_Face, 0, len(_mesh_ed.faces) + 2)
	for &f in _mesh_ed.faces {
		m := len(f.verts)
		if m < 3 {
			delete(f.verts)
			continue
		}
		clipped := make([dynamic]u32, 0, m + 2)
		for i in 0 ..< m {
			ia := f.verts[i]
			ib := f.verts[(i + 1) % m]
			va := _mesh_ed.verts[ia]
			vb := _mesh_ed.verts[ib]
			da := linalg.dot(n, va) - d_plane
			db := linalg.dot(n, vb) - d_plane
			if da <= 1e-4 {
				append(&clipped, ia)
			}
			if (da <= 1e-4 && db > 1e-4) || (da > 1e-4 && db <= 1e-4) {
				t := da / (da - db)
				ipt := linalg.lerp(va, vb, clamp(t, 0.0, 1.0))
				new_vi := u32(len(_mesh_ed.verts))
				append(&_mesh_ed.verts, ipt)
				append(&clipped, new_vi)
			}
		}
		delete(f.verts)
		if len(clipped) >= 3 {
			append(&new_faces, Editable_Poly_Face{verts = clipped, color = f.color})
		} else {
			delete(clipped)
		}
	}
	delete(_mesh_ed.faces)
	_mesh_ed.faces = new_faces
	mesh_op_weld_vertices(0.01)
	mesh_op_close_open_holes()
}

mesh_editor_set_boolean_box :: proc(offset, size: [3]f32) {
	_ensure_mesh_ed_init()
	_mesh_ed.bool_box_offset = offset
	_mesh_ed.bool_box_size   = size
}

mesh_editor_get_counts :: proc() -> (vert_count, face_count: int) {
	_ensure_mesh_ed_init()
	return len(_mesh_ed.verts), len(_mesh_ed.faces)
}

mesh_editor_get_compliance_counts :: proc() -> (open_edges, inverted_faces, concave_faces: int, has_valid_volume: bool) {
	_ensure_mesh_ed_init()
	_evaluate_mesh_csg_compliance()
	return _mesh_ed.report.open_boundary_edges, _mesh_ed.report.inverted_normal_faces, _mesh_ed.report.concave_face_count, _mesh_ed.report.has_valid_volume
}

mesh_editor_get_target_owner :: proc() -> engine.Transform_Handle {
	_ensure_mesh_ed_init()
	return _mesh_ed.target_owner
}

mesh_editor_select_verts :: proc(verts: []u32) {
	_ensure_mesh_ed_init()
	_mesh_ed.select_mode = .Vertex
	clear(&_mesh_ed.selected_verts)
	for vi in verts {
		append(&_mesh_ed.selected_verts, vi)
	}
}

mesh_editor_select_edge :: proc(u, v: u32) {
	_ensure_mesh_ed_init()
	_mesh_ed.select_mode = .Edge
	_mesh_ed.selected_edge = {u, v}
	_mesh_ed.has_selected_edge = (u != v)
}

mesh_editor_select_face :: proc(face_idx: int) {
	_ensure_mesh_ed_init()
	_mesh_ed.select_mode = .Face
	_mesh_ed.selected_face = face_idx
}

// Unreal `MshBool`: Performs exact 3D Boolean Union (`+Add`) or Boolean Subtract (`-Cut`) of the
// adjustable 3D Cutter Box (`_mesh_ed.bool_box_offset`, `_mesh_ed.bool_box_size`) against the editable mesh!
// Decomposes the existing mesh into exact multi-hull CSG cells first so carving multiple tunnels or
// cutting into an already-concave mesh preserves all existing holes, then reconstructs a clean,
// zero-internal-poly, zero-pointless-vertex Editable Poly Mesh!
mesh_op_boolean_box :: proc(op: cad_csg.Brush_Op) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	prev := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev

	col_u8 := [4]u8{
		u8(clamp(_mesh_ed.mesh_color.r * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.g * 255.0, 0, 255)),
		u8(clamp(_mesh_ed.mesh_color.b * 255.0, 0, 255)),
		255,
	}

	result_hulls := _decompose_editable_mesh_to_csg_hulls(false, alloc)
	defer {
		for &rh in result_hulls do cad_csg.convex_destroy(&rh)
		delete(result_hulls)
	}
	if len(result_hulls) == 0 do return

	cutter, c_ok := cad_csg.csg_make_primitive_convex(
		.Box,
		_mesh_ed.bool_box_offset,
		_mesh_ed.bool_box_size,
		0,
		col_u8,
		0.5,
		0,
		false,
		1,
		alloc,
	)
	if !c_ok do return

	if op == .Subtract {
		cad_csg.convex_list_subtract(&result_hulls, cutter, alloc)
		cad_csg.convex_destroy(&cutter)
	} else {
		// Union: subtract cutter from base so they don't overlap, then append cutter!
		cad_csg.convex_list_subtract(&result_hulls, cutter, alloc)
		append(&result_hulls, cutter)
	}

	if len(result_hulls) == 0 do return
	cad_csg.csg_clean_and_simplify_hulls(&result_hulls, alloc)
	_rebuild_editable_mesh_from_csg_hulls(result_hulls[:])
}

// Unreal Modeling Mode 2-Mesh Booleans (`Mesh A` & `Mesh B` in World Space):
// - `mode == 0`: `A + B` (Union — combines Mesh A and Mesh B into one clean manifold mesh)
// - `mode == 1`: `A - B` (Subtract / Difference — carves Mesh B out of Mesh A)
// - `mode == 2`: `A ∩ B` (Intersection — keeps only the overlapping volume of Mesh A and Mesh B)
// - `mode == 3`: `B - A` (Subtract Inverse — carves Mesh A out of Mesh B)
// Note: Tool Mesh B is NEVER hidden or deleted; it remains active and untouched in the scene.
mesh_op_boolean_with_other_mesh :: proc(other_h: engine.Transform_Handle, mode: int) -> bool {
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} || other_h == {} || other_h == _mesh_ed.target_owner do return false
	if !engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) ||
	   !engine.pool_valid(&w.transforms, engine.Handle(other_h)) {
		return false
	}
	if len(_mesh_ed.faces) == 0 || len(_mesh_ed.verts) < 4 do return false

	prev := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev

	// 1. Decompose Mesh A into CSG hulls in Mesh A's local space
	hulls_a := _decompose_editable_mesh_to_csg_hulls(false, alloc)
	defer {
		for &ha in hulls_a do cad_csg.convex_destroy(&ha)
		delete(hulls_a)
	}
	if len(hulls_a) == 0 do return false

	// Compute transform from `other_h` local space -> World -> `_mesh_ed.target_owner` local space (`mat_b_to_a`)
	_, inv_a := _mesh_model()
	tw_b := engine.transform_world(other_h)
	sc_b := tw_b.scale
	for i in 0 ..< 3 do if abs(sc_b[i]) < 1e-5 do sc_b[i] = 1e-5
	model_b := engine.trs_matrix(tw_b.position, tw_b.rotation, sc_b)
	mat_b_to_a := inv_a * model_b

	// 2. Temporarily load `other_h` (transformed by `mat_b_to_a`) into `_mesh_ed` and decompose it into `hulls_b`
	snap_a := _snapshot_take()
	_clear_editable_mesh()

	loaded_b := false
	if _, csg_b := engine.transform_get_comp(other_h, cad_csg.CSGVolume); csg_b != nil && len(csg_b.chunks) > 0 {
		b_hulls_local := make([dynamic]cad_csg.CSG_Convex, 0, 16, context.temp_allocator)
		for _, ch in csg_b.chunks {
			if ch == nil do continue
			for h in ch.destructible_hulls {
				if len(h.planes) >= 4 do append(&b_hulls_local, cad_csg.convex_clone(h, context.temp_allocator))
			}
			for h in ch.indestructible_hulls {
				if len(h.planes) >= 4 do append(&b_hulls_local, cad_csg.convex_clone(h, context.temp_allocator))
			}
		}
		if len(b_hulls_local) > 0 {
			polys_b := make([dynamic]cad_csg.CSG_Face_Poly, 0, len(b_hulls_local) * 6, context.temp_allocator)
			cad_csg.csg_extract_clean_polygons_from_hulls(b_hulls_local[:], &polys_b, context.temp_allocator)
			for fp in polys_b {
				if len(fp.verts) < 3 do continue
				f_inds := make([dynamic]u32, 0, len(fp.verts), context.temp_allocator)
				for pt in fp.verts {
					pt_a := _xf_point(mat_b_to_a, pt)
					found := -1
					for ev, ei in _mesh_ed.verts {
						if linalg.length2(pt_a - ev) <= 1e-5 { found = ei; break }
					}
					if found >= 0 {
						append(&f_inds, u32(found))
					} else {
						append(&f_inds, u32(len(_mesh_ed.verts)))
						append(&_mesh_ed.verts, pt_a)
					}
				}
				if len(f_inds) >= 3 do _add_poly_face(f_inds[:], fp.color)
			}
			loaded_b = len(_mesh_ed.faces) >= 4
		}
	}

	if !loaded_b {
		if _, mf_b := engine.transform_get_comp(other_h, engine.MeshFilter); mf_b != nil {
			if cpu_v, cpu_i, ok_b := engine.mesh_read_cpu_geometry(mf_b, context.temp_allocator); ok_b && len(cpu_v) >= 3 && len(cpu_i) >= 3 {
				Weld_Key :: [3]i32
				weld := make(map[Weld_Key]u32, len(cpu_v), context.temp_allocator)
				remap := make([]u32, len(cpu_v), context.temp_allocator)
				for v, i in cpu_v {
					pt_a := _xf_point(mat_b_to_a, v.position)
					k := Weld_Key{i32(math.round(pt_a.x * 1000)), i32(math.round(pt_a.y * 1000)), i32(math.round(pt_a.z * 1000))}
					if ex, found := weld[k]; found {
						remap[i] = ex
					} else {
						idx := u32(len(_mesh_ed.verts))
						append(&_mesh_ed.verts, pt_a)
						weld[k] = idx
						remap[i] = idx
					}
				}
				tri_cnt := len(cpu_i) / 3
				for t in 0 ..< tri_cnt {
					i0, i1, i2 := remap[cpu_i[t * 3 + 0]], remap[cpu_i[t * 3 + 1]], remap[cpu_i[t * 3 + 2]]
					if i0 == i1 || i1 == i2 || i2 == i0 do continue
					_add_poly_face({i0, i1, i2})
				}
				if len(_mesh_ed.faces) <= 3000 {
					_merge_coplanar_triangles()
					_compact_unused_vertices()
				}
				loaded_b = len(_mesh_ed.faces) >= 4
			}
		}
	}

	if !loaded_b {
		_snapshot_restore(snap_a, false)
		_snapshot_free(&snap_a)
		return false
	}

	hulls_b := _decompose_editable_mesh_to_csg_hulls(false, alloc)
	defer {
		for &hb in hulls_b do cad_csg.convex_destroy(&hb)
		delete(hulls_b)
	}

	// Restore Mesh A before applying boolean result
	_snapshot_restore(snap_a, false)
	_snapshot_free(&snap_a)

	if len(hulls_b) == 0 do return false

	// 3. Execute exact 3D Boolean operation between `hulls_a` and `hulls_b`
	switch mode {
	case 0: // A + B (Union)
		for hb in hulls_b {
			cad_csg.convex_list_subtract(&hulls_a, hb, alloc)
		}
		for hb in hulls_b {
			append(&hulls_a, cad_csg.convex_clone(hb, alloc))
		}
	case 1: // A - B (Subtract B from A)
		for hb in hulls_b {
			cad_csg.convex_list_subtract(&hulls_a, hb, alloc)
		}
	case 2: // A ∩ B (Intersection: A - (A - B))
		diff_b := make([dynamic]cad_csg.CSG_Convex, 0, len(hulls_a), alloc)
		for ha in hulls_a {
			append(&diff_b, cad_csg.convex_clone(ha, alloc))
		}
		for hb in hulls_b {
			cad_csg.convex_list_subtract(&diff_b, hb, alloc)
		}
		for hd in diff_b {
			cad_csg.convex_list_subtract(&hulls_a, hd, alloc)
		}
		for &hd in diff_b do cad_csg.convex_destroy(&hd)
		delete(diff_b)
	case 3: // B - A (Subtract A from B)
		for ha in hulls_a {
			cad_csg.convex_list_subtract(&hulls_b, ha, alloc)
		}
		for &ha in hulls_a do cad_csg.convex_destroy(&ha)
		clear(&hulls_a)
		for hb in hulls_b {
			append(&hulls_a, cad_csg.convex_clone(hb, alloc))
		}
	}

	if len(hulls_a) == 0 do return false
	cad_csg.csg_clean_and_simplify_hulls(&hulls_a, alloc)
	_rebuild_editable_mesh_from_csg_hulls(hulls_a[:])
	return true
}

// Unreal-Style Multi-Mesh Booleans:
// Operates on Target Mesh A with one or more Tool Meshes (B, C, D...) selected via Ctrl+Click in Scene3D!
// When `consume_tools` is true, Tool meshes are removed after a successful boolean so they don't plug carved holes.
mesh_op_boolean_multi :: proc(target_h: engine.Transform_Handle, tool_handles: []engine.Transform_Handle, mode: int, consume_tools: bool = false) -> bool {
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	if w == nil || target_h == {} || len(tool_handles) == 0 do return false
	if !engine.pool_valid(&w.transforms, engine.Handle(target_h)) do return false

	// If `target_h` is a character rig (`ArmatureDeformedMesh` or has bone Ghoul `CSGVolume` children),
	// delegate directly to `csg_op_boolean_multi` so Mesh Bool carves the character's Ghoul CSG bones!
	if _, adm_t := engine.transform_get_comp(target_h, control_rig.ArmatureDeformedMesh); adm_t != nil {
		return csg_op_boolean_multi(target_h, tool_handles, mode, consume_tools)
	}

	if _mesh_ed.target_owner != target_h {
		engine.inspector_request_select(target_h)
		_sync_mesh_editor_with_selection()
	}
	if len(_mesh_ed.faces) == 0 || len(_mesh_ed.verts) < 4 do return false

	any_ok := false
	for tool_h in tool_handles {
		if tool_h == {} || tool_h == target_h do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(tool_h)) do continue
		if mesh_op_boolean_with_other_mesh(tool_h, mode) {
			any_ok = true
		}
	}
	if any_ok && consume_tools {
		for tool_h in tool_handles {
			if tool_h == {} || tool_h == target_h do continue
			if engine.pool_valid(&w.transforms, engine.Handle(tool_h)) {
				engine.transform_destroy(tool_h)
			}
		}
		_mesh_ed.bool_target_b = {}
		_mesh_ed.csg_bool_target_b = {}
		engine.inspector_request_select(target_h)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	return any_ok
}

// Spawns a standalone `CSGVolume` GameObject with a single primitive brush (`Box`, `Cylinder`, `Wedge`, etc.)
// so the user can move independent CSG objects with `Q / E / R` and run `Ctrl + Click` Multi-CSG Booleans!
spawn_separate_csg_primitive_volume :: proc(prim: cad_csg.Brush_Primitive = .Box, size: [3]f32 = {2, 2, 2}, world_pos: [3]f32 = {0, 1.0, 0}) -> engine.Transform_Handle {
	_ensure_init()
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return {}

	root_h := engine.Transform_Handle(scene.root.handle)
	new_h := engine.transform_new(fmt.tprintf("CSG_%v_Volume", prim), root_h)
	engine.transform_ensure_unique_name(new_h)
	if t := engine.pool_get(&w.transforms, engine.Handle(new_h)); t != nil {
		t.position = world_pos
	}
	_, ptr := engine.transform_add_comp(new_h, .CSGVolume)
	vol := cast(^cad_csg.CSGVolume)ptr
	if vol != nil {
		cad_csg.reset_CSGVolume(vol)
		col_u8 := [4]u8{
			u8(clamp(_ed.brush_color.r * 255.0, 0, 255)),
			u8(clamp(_ed.brush_color.g * 255.0, 0, 255)),
			u8(clamp(_ed.brush_color.b * 255.0, 0, 255)),
			255,
		}
		_ = cad_csg.csg_volume_add_brush(vol, fmt.tprintf("Add_%v_1", prim), .Add, prim, {0, 0, 0}, size, 0, col_u8, true, true)
		cad_csg.csg_volume_rebuild(vol)
		csg_history_reset(vol)
	}
	deactivate_cad_tool()
	scene.dirty = true
	engine.inspector_request_select(new_h)
	return new_h
}

// Extracts unified convex hulls from a `CSGVolume` in its local space.
@(private = "file")
_extract_csg_volume_hulls_local :: proc(vol: ^cad_csg.CSGVolume, alloc: runtime.Allocator) -> [dynamic]cad_csg.CSG_Convex {
	hulls := make([dynamic]cad_csg.CSG_Convex, 0, 16, alloc)
	if vol == nil do return hulls
	if !vol.compiled {
		cad_csg.csg_volume_rebuild(vol)
	}
	for _, ch in vol.chunks {
		if ch == nil do continue
		for h in ch.destructible_hulls {
			if len(h.planes) >= 4 do append(&hulls, cad_csg.convex_clone(h, alloc))
		}
		for h in ch.indestructible_hulls {
			if len(h.planes) >= 4 do append(&hulls, cad_csg.convex_clone(h, alloc))
		}
	}
	if len(hulls) == 0 && len(vol.runtime_hulls) > 0 {
		for h in vol.runtime_hulls {
			if len(h.planes) >= 4 do append(&hulls, cad_csg.convex_clone(h, alloc))
		}
	}
	if len(hulls) > 1 {
		cad_csg.csg_clean_and_simplify_hulls(&hulls, alloc)
	}
	return hulls
}

// Unreal-Style 2-Volume CSG Booleans (`CSG Volume A` & `CSG Volume / Mesh B` in World Space):
// - `mode == 0`: `A + B` (Union — combines CSG A and Tool B in world space into CSG A)
// - `mode == 1`: `A - B` (Subtract / Difference — carves Tool B out of CSG A in world space)
// - `mode == 2`: `A & B` (Intersection — keeps only the overlapping volume of CSG A and Tool B)
// - `mode == 3`: `B - A` (Subtract Inverse — carves CSG A out of Tool B and stores in CSG A)
// Note: Tool B (`other_h`) is NEVER hidden or deleted; it remains active and untouched in the scene!
csg_op_boolean_with_other :: proc(target_h, other_h: engine.Transform_Handle, mode: int, commit_undo := true) -> bool {
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	if w == nil || target_h == {} || other_h == {} || target_h == other_h do return false
	if !engine.pool_valid(&w.transforms, engine.Handle(target_h)) ||
	   !engine.pool_valid(&w.transforms, engine.Handle(other_h)) {
		return false
	}

	_, vol_a := engine.transform_get_comp(target_h, cad_csg.CSGVolume)
	if vol_a == nil || !vol_a.enabled do return false

	if commit_undo {
		csg_history_ensure_baseline(vol_a)
	}

	vol_alloc := context.allocator
	prev := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev

	// 1. Extract Target CSG A's convex hulls in A's local space
	context.allocator = vol_alloc
	if !vol_a.compiled {
		cad_csg.csg_volume_rebuild(vol_a)
	}
	context.allocator = alloc
	hulls_a := _extract_csg_volume_hulls_local(vol_a, alloc)
	defer {
		for &ha in hulls_a do cad_csg.convex_destroy(&ha)
		delete(hulls_a)
	}
	if len(hulls_a) == 0 do return false

	// 2. Compute transform from Tool B's local space into Target A's local space
	tw_a := engine.transform_world(target_h)
	mat_a := engine.trs_matrix(tw_a.position, tw_a.rotation, tw_a.scale)
	inv_a := linalg.matrix4_inverse(mat_a)

	tw_b := engine.transform_world(other_h)
	mat_b := engine.trs_matrix(tw_b.position, tw_b.rotation, tw_b.scale)
	mat_b_to_a := inv_a * mat_b
	inv_trans_b_to_a := linalg.transpose(linalg.matrix4_inverse(mat_b_to_a))

	// 3. Extract Tool B's convex hulls transformed into Target A's local space
	hulls_b := make([dynamic]cad_csg.CSG_Convex, 0, 16, alloc)
	defer {
		for &hb in hulls_b do cad_csg.convex_destroy(&hb)
		delete(hulls_b)
	}

	if _, vol_b := engine.transform_get_comp(other_h, cad_csg.CSGVolume); vol_b != nil && vol_b.enabled {
		context.allocator = vol_alloc
		if !vol_b.compiled {
			cad_csg.csg_volume_rebuild(vol_b)
		}
		context.allocator = alloc
		raw_b := _extract_csg_volume_hulls_local(vol_b, alloc)
		defer delete(raw_b)
		for &hb in raw_b {
			for &p in hb.planes {
				pt_b := p.normal * p.dist
				pt_a := _xf_point(mat_b_to_a, pt_b)
				n_a  := linalg.normalize0((inv_trans_b_to_a * [4]f32{p.normal.x, p.normal.y, p.normal.z, 0.0}).xyz)
				if linalg.length2(n_a) < 0.25 do n_a = p.normal
				p.normal = n_a
				p.dist   = linalg.dot(n_a, pt_a)
				p = cad_csg.quantize_plane(p)
			}
			if cad_csg.convex_rebuild_bounds_and_prune(&hb, prune_redundant = false) {
				append(&hulls_b, hb)
			} else {
				cad_csg.convex_destroy(&hb)
			}
		}
	} else if _, mf_b := engine.transform_get_comp(other_h, engine.MeshFilter); mf_b != nil {
		if cpu_v, cpu_i, ok := engine.mesh_read_cpu_geometry(mf_b, context.temp_allocator); ok && len(cpu_v) >= 3 && len(cpu_i) >= 3 {
			snap_ed := _snapshot_take()
			_clear_editable_mesh()
			Weld_Key :: struct { x, y, z: i32 }
			weld := make(map[Weld_Key]u32, len(cpu_v), context.temp_allocator)
			remap := make([]u32, len(cpu_v), context.temp_allocator)
			for v, i in cpu_v {
				pt_a := _xf_point(mat_b_to_a, v.position)
				k := Weld_Key{i32(math.round(pt_a.x * 1000)), i32(math.round(pt_a.y * 1000)), i32(math.round(pt_a.z * 1000))}
				if ex, found := weld[k]; found {
					remap[i] = ex
				} else {
					idx := u32(len(_mesh_ed.verts))
					append(&_mesh_ed.verts, pt_a)
					weld[k] = idx
					remap[i] = idx
				}
			}
			tri_cnt := len(cpu_i) / 3
			for t in 0 ..< tri_cnt {
				i0, i1, i2 := remap[cpu_i[t * 3 + 0]], remap[cpu_i[t * 3 + 1]], remap[cpu_i[t * 3 + 2]]
				if i0 == i1 || i1 == i2 || i2 == i0 do continue
				_add_poly_face({i0, i1, i2})
			}
			if len(_mesh_ed.faces) <= 3000 {
				_merge_coplanar_triangles()
				_compact_unused_vertices()
			}
			if len(_mesh_ed.faces) >= 4 {
				decomp_b := _decompose_editable_mesh_to_csg_hulls(false, alloc)
				for hb in decomp_b do append(&hulls_b, hb)
				delete(decomp_b)
			}
			_snapshot_restore(snap_ed, false)
			_snapshot_free(&snap_ed)
		}
	}

	if len(hulls_b) == 0 do return false
	if vol_a.is_ghoul_bone_csg && mode == 1 {
		for &hb in hulls_b {
			for &p in hb.planes {
				p.mat_slot      = 1
				p.uv_lock_brush = false
				p.color         = {155, 28, 28, 255}
			}
		}
	}

	// 4. Execute exact 3D Boolean operation between `hulls_a` and `hulls_b`
	switch mode {
	case 0: // A + B (Union)
		for hb in hulls_b {
			cad_csg.convex_list_subtract(&hulls_a, hb, alloc)
		}
		for hb in hulls_b {
			append(&hulls_a, cad_csg.convex_clone(hb, alloc))
		}
	case 1: // A - B (Subtract B from A)
		for hb in hulls_b {
			cad_csg.convex_list_subtract(&hulls_a, hb, alloc)
		}
	case 2: // A & B (Intersection: A - (A - B))
		diff_b := make([dynamic]cad_csg.CSG_Convex, 0, len(hulls_a), alloc)
		for ha in hulls_a {
			append(&diff_b, cad_csg.convex_clone(ha, alloc))
		}
		for hb in hulls_b {
			cad_csg.convex_list_subtract(&diff_b, hb, alloc)
		}
		for hd in diff_b {
			cad_csg.convex_list_subtract(&hulls_a, hd, alloc)
		}
		for &hd in diff_b do cad_csg.convex_destroy(&hd)
		delete(diff_b)
	case 3: // B - A (Subtract A from B)
		for ha in hulls_a {
			cad_csg.convex_list_subtract(&hulls_b, ha, alloc)
		}
		for &ha in hulls_a do cad_csg.convex_destroy(&ha)
		clear(&hulls_a)
		for hb in hulls_b {
			append(&hulls_a, cad_csg.convex_clone(hb, alloc))
		}
	}

	if len(hulls_a) == 0 && !(vol_a.is_ghoul_bone_csg && mode == 1) do return false
	if len(hulls_a) > 1 {
		cad_csg.csg_clean_and_simplify_hulls(&hulls_a, alloc)
	}

	// 5. Store booleaned convex hulls into `vol_a.runtime_hulls`, rebuild `vol_a`, and commit CSG Undo!
	context.allocator = vol_alloc
	if vol_a.brushes != nil {
		for &b in vol_a.brushes {
			if len(b.name) > 0 do delete(b.name, vol_alloc)
			if b.profile_points != nil do delete(b.profile_points)
		}
		clear(&vol_a.brushes)
	}
	if vol_a.runtime_hulls != nil {
		for &old_h in vol_a.runtime_hulls do cad_csg.convex_destroy(&old_h)
		clear(&vol_a.runtime_hulls)
	} else {
		vol_a.runtime_hulls = make([dynamic]cad_csg.CSG_Convex, 0, len(hulls_a), vol_alloc)
	}
	for ha, hi_idx in hulls_a {
		cloned := cad_csg.convex_clone(ha, vol_alloc)
		cloned.brush_id = u32(hi_idx + 1)
		cloned.anchored = !vol_a.is_dynamic_rigidbody
		append(&vol_a.runtime_hulls, cloned)
	}
	_ed.selected_brush_idx = -1
	cad_csg.csg_volume_rebuild(vol_a)
	cad_csg.csg_volume_sync_colliders_only(vol_a)
	if commit_undo {
		csg_history_commit(vol_a)
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Unreal-Style Multi-CSG Booleans:
// Operates on Target CSG Volume A (`target_h`) with one or more Tool Volumes/Meshes (`tool_handles`) selected via Ctrl+Click in Scene3D!
// When `consume_tools` is true, Tool volumes/meshes are removed after a successful boolean so carved holes are immediately visible.
csg_op_boolean_multi :: proc(target_h: engine.Transform_Handle, tool_handles: []engine.Transform_Handle, mode: int, consume_tools: bool = false) -> bool {
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	if w == nil || target_h == {} || len(tool_handles) == 0 do return false
	if !engine.pool_valid(&w.transforms, engine.Handle(target_h)) do return false

	// If `target_h` is a character root (`ArmatureDeformedMesh`) or a Ghoul bone, collect all Ghoul bone `CSGVolume`s in the character hierarchy!
	_, vol_a := engine.transform_get_comp(target_h, cad_csg.CSGVolume)
	if (vol_a == nil || !vol_a.enabled) || vol_a.is_ghoul_bone_csg {
		char_root := target_h
		// Walk up to character root if a single bone was selected
		for _ in 0 ..< 16 {
			if _, adm_c := engine.transform_get_comp(char_root, control_rig.ArmatureDeformedMesh); adm_c != nil do break
			t_cur := engine.pool_get(&w.transforms, engine.Handle(char_root))
			if t_cur == nil || t_cur.parent.handle == {} do break
			p_h := engine.Transform_Handle(t_cur.parent.handle)
			if p_h == engine.Transform_Handle(engine.sm_scene_get_active().root.handle) do break
			char_root = p_h
		}
		bone_vols := make([dynamic]engine.Transform_Handle, 0, 24, context.temp_allocator)
		collect_ghoul_bones :: proc(w: ^engine.World, tH: engine.Transform_Handle, out: ^[dynamic]engine.Transform_Handle) {
			t := engine.pool_get(&w.transforms, engine.Handle(tH))
			if t == nil do return
			if _, v := engine.transform_get_comp(tH, cad_csg.CSGVolume); v != nil && v.enabled {
				append(out, tH)
			}
			for ch in t.children {
				if ch.handle != {} && engine.pool_valid(&w.transforms, ch.handle) {
					collect_ghoul_bones(w, engine.Transform_Handle(ch.handle), out)
				}
			}
		}
		collect_ghoul_bones(w, char_root, &bone_vols)
		if len(bone_vols) > 0 {
			any_bone_ok := false
			for bh in bone_vols {
				for tool_h in tool_handles {
					if tool_h == {} || tool_h == bh || tool_h == char_root do continue
					if csg_op_boolean_with_other(bh, tool_h, mode, commit_undo = false) {
						any_bone_ok = true
					}
				}
			}
			if any_bone_ok && consume_tools {
				for tool_h in tool_handles {
					if tool_h == {} || tool_h == char_root do continue
					if engine.pool_valid(&w.transforms, engine.Handle(tool_h)) {
						engine.transform_destroy(tool_h)
					}
				}
				_mesh_ed.bool_target_b = {}
				_mesh_ed.csg_bool_target_b = {}
				engine.inspector_request_select(char_root)
			}
			return any_bone_ok
		}
	}

	if vol_a == nil || !vol_a.enabled do return false

	csg_history_ensure_baseline(vol_a)
	any_ok := false
	for tool_h in tool_handles {
		if tool_h == {} || tool_h == target_h do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(tool_h)) do continue
		if csg_op_boolean_with_other(target_h, tool_h, mode, commit_undo = false) {
			any_ok = true
		}
	}
	if any_ok {
		csg_history_commit(vol_a)
		if consume_tools {
			for tool_h in tool_handles {
				if tool_h == {} || tool_h == target_h do continue
				if engine.pool_valid(&w.transforms, engine.Handle(tool_h)) {
					engine.transform_destroy(tool_h)
				}
			}
			_mesh_ed.bool_target_b = {}
			_mesh_ed.csg_bool_target_b = {}
			engine.inspector_request_select(target_h)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
	return any_ok
}

// Saves the current `Editable_Poly_Mesh` to disk as both a binary glTF 2.0 `.glb` (`assets/meshes/<name>.glb`)
// and Wavefront `.obj` (`assets/meshes/<name>.obj`), refreshes `AssetDB`, and binds `mf.mesh` to the saved disk asset!
mesh_op_save_to_disk :: proc(custom_name: string = "") -> (saved_glb_path: string, ok: bool) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.verts) < 3 || len(_mesh_ed.faces) < 1 do return "", false

	w := engine.ctx_world()
	raw_name := custom_name
	if len(raw_name) == 0 && w != nil && _mesh_ed.target_owner != {} {
		if t := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner)); t != nil && len(t.name) > 0 {
			raw_name = t.name
		}
	}
	if len(raw_name) == 0 do raw_name = "CAD_Custom_Mesh"

	// Sanitize filename
	name_buf := make([dynamic]u8, 0, len(raw_name), context.temp_allocator)
	for i in 0 ..< len(raw_name) {
		ch := raw_name[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' {
			append(&name_buf, ch)
		} else if ch == ' ' {
			append(&name_buf, '_')
		}
	}
	safe_name := string(name_buf[:]) if len(name_buf) > 0 else "CAD_Custom_Mesh"

	os.make_directory("assets")
	os.make_directory("assets/meshes")
	glb_path := fmt.tprintf("assets/meshes/%s.glb", safe_name)
	obj_path := fmt.tprintf("assets/meshes/%s.obj", safe_name)

	// Build flat unindexed/indexed GPU vertices & triangles
	pos_arr  := make([dynamic][3]f32, 0, len(_mesh_ed.faces) * 4, context.temp_allocator)
	norm_arr := make([dynamic][3]f32, 0, len(_mesh_ed.faces) * 4, context.temp_allocator)
	uv_arr   := make([dynamic][2]f32, 0, len(_mesh_ed.faces) * 4, context.temp_allocator)
	ind_arr  := make([dynamic]u32, 0, len(_mesh_ed.faces) * 6, context.temp_allocator)

	min_p := [3]f32{ max(f32),  max(f32),  max(f32)}
	max_p := [3]f32{-max(f32), -max(f32), -max(f32)}

	for &f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		_ensure_face_uvs(&f)
		fn, _ := _face_normal_and_center(f)
		base_v := u32(len(pos_arr))
		for vi, corner_i in f.verts {
			if int(vi) >= len(_mesh_ed.verts) do continue
			p := _mesh_ed.verts[vi]
			min_p = linalg.min(min_p, p)
			max_p = linalg.max(max_p, p)
			append(&pos_arr, p)
			append(&norm_arr, fn)
			uv := f.uvs[corner_i] if corner_i < len(f.uvs) else [2]f32{0, 0}
			append(&uv_arr, uv)
		}
		tri_n := u32(len(f.verts) - 2)
		for t in 0 ..< tri_n {
			append(&ind_arr, base_v, base_v + t + 1, base_v + t + 2)
		}
	}
	v_cnt := len(pos_arr)
	i_cnt := len(ind_arr)
	if v_cnt < 3 || i_cnt < 3 do return "", false

	// 1. Write Wavefront `.obj` file (preserves N-gon/Quad topology and UVs cleanly for Blender/Maya!)
	obj_sb := strings.builder_make(0, 4096, context.temp_allocator)
	fmt.sbprintf(&obj_sb, "# MoonHug CAD Mesh Export: %s\no %s\n", safe_name, safe_name)
	for v in _mesh_ed.verts {
		fmt.sbprintf(&obj_sb, "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
	}
	for f in _mesh_ed.faces {
		for uv in f.uvs {
			fmt.sbprintf(&obj_sb, "vt %.6f %.6f\n", uv.x, uv.y)
		}
	}
	for f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		fn, _ := _face_normal_and_center(f)
		fmt.sbprintf(&obj_sb, "vn %.6f %.6f %.6f\n", fn.x, fn.y, fn.z)
	}
	vt_counter := 1
	for f, fi in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		fmt.sbprintf(&obj_sb, "f")
		for vi in f.verts {
			fmt.sbprintf(&obj_sb, " %d/%d/%d", int(vi) + 1, vt_counter, fi + 1)
			vt_counter += 1
		}
		fmt.sbprintf(&obj_sb, "\n")
	}
	_ = os.write_entire_file(obj_path, obj_sb.buf[:])

	// 2. Write standard binary glTF 2.0 `.glb` file for MoonHug AssetDB & Unreal/Godot/Blender
	pos_bytes  := v_cnt * size_of([3]f32)
	norm_bytes := v_cnt * size_of([3]f32)
	uv_bytes   := v_cnt * size_of([2]f32)
	ind_bytes  := i_cnt * size_of(u32)

	off_pos  := 0
	off_norm := off_pos + pos_bytes
	off_uv   := off_norm + norm_bytes
	off_ind  := off_uv + uv_bytes
	bin_raw_len := off_ind + ind_bytes
	bin_pad_len := (bin_raw_len + 3) & ~int(3)

	json_str := fmt.tprintf(
		`{{"asset":{{"version":"2.0","generator":"MoonHug CAD"}},"scene":0,"scenes":[{{"nodes":[0]}}],"nodes":[{{"mesh":0,"name":"%s"}}],"meshes":[{{"name":"%s","primitives":[{{"attributes":{{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2}},"indices":3,"mode":4}}]}}],"buffers":[{{"byteLength":%d}}],"bufferViews":[{{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34962}},{{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34962}},{{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34962}},{{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":34963}}],"accessors":[{{"bufferView":0,"componentType":5126,"count":%d,"type":"VEC3","min":[%.6f,%.6f,%.6f],"max":[%.6f,%.6f,%.6f]}},{{"bufferView":1,"componentType":5126,"count":%d,"type":"VEC3"}},{{"bufferView":2,"componentType":5126,"count":%d,"type":"VEC2"}},{{"bufferView":3,"componentType":5125,"count":%d,"type":"SCALAR"}}]}}`,
		safe_name, safe_name,
		bin_pad_len,
		off_pos, pos_bytes,
		off_norm, norm_bytes,
		off_uv, uv_bytes,
		off_ind, ind_bytes,
		v_cnt, min_p.x, min_p.y, min_p.z, max_p.x, max_p.y, max_p.z,
		v_cnt,
		v_cnt,
		i_cnt,
	)
	json_raw_len := len(json_str)
	json_pad_len := (json_raw_len + 3) & ~int(3)
	total_glb_len := 12 + 8 + json_pad_len + 8 + bin_pad_len

	glb_buf := make([]u8, total_glb_len, context.temp_allocator)
	write_u32_le :: proc(dst: []u8, offset: int, val: u32) {
		dst[offset + 0] = u8(val & 0xFF)
		dst[offset + 1] = u8((val >> 8) & 0xFF)
		dst[offset + 2] = u8((val >> 16) & 0xFF)
		dst[offset + 3] = u8((val >> 24) & 0xFF)
	}

	// GLB 12-byte Header
	write_u32_le(glb_buf, 0, 0x46546C67) // "glTF"
	write_u32_le(glb_buf, 4, 2)          // version 2
	write_u32_le(glb_buf, 8, u32(total_glb_len))

	// JSON Chunk Header + Padded Payload
	write_u32_le(glb_buf, 12, u32(json_pad_len))
	write_u32_le(glb_buf, 16, 0x4E4F534A) // "JSON"
	copy(glb_buf[20:20 + json_raw_len], transmute([]u8)json_str)
	for i in json_raw_len ..< json_pad_len {
		glb_buf[20 + i] = 0x20 // space padding per glTF 2.0 spec
	}

	// BIN Chunk Header + Binary Buffers
	bin_chunk_off := 20 + json_pad_len
	write_u32_le(glb_buf, bin_chunk_off + 0, u32(bin_pad_len))
	write_u32_le(glb_buf, bin_chunk_off + 4, 0x004E4942) // "BIN\0"
	bin_data := glb_buf[bin_chunk_off + 8 : bin_chunk_off + 8 + bin_pad_len]
	copy(bin_data[off_pos  : off_pos  + pos_bytes],  slice.to_bytes(pos_arr[:]))
	copy(bin_data[off_norm : off_norm + norm_bytes], slice.to_bytes(norm_arr[:]))
	copy(bin_data[off_uv   : off_uv   + uv_bytes],   slice.to_bytes(uv_arr[:]))
	copy(bin_data[off_ind  : off_ind  + ind_bytes],  slice.to_bytes(ind_arr[:]))

	if os.write_entire_file(glb_path, glb_buf) != nil {
		_mesh_ed.save_status = "Failed to write .glb to assets/meshes/"
		return "", false
	}

	// Refresh AssetDB so the newly written `.glb` is imported and assigned to `target_owner`'s `MeshFilter`!
	if len(engine.asset_db.root_path) > 0 {
		engine.asset_db_request_refresh()
		if disk_id, g_ok := engine.asset_db_get_guid(glb_path); g_ok {
			disk_guid := engine.Asset_GUID(disk_id)
			if w != nil && _mesh_ed.target_owner != {} {
				if _, mf := engine.transform_get_comp(_mesh_ed.target_owner, engine.MeshFilter); mf != nil {
					mf.mesh = engine.PPtr{guid = disk_guid, local_id = 0}
				}
			}
		}
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	@(static) status_buf: [192]u8
	_mesh_ed.save_status = fmt.bprintf(status_buf[:], "Saved: %s (+ .obj)", glb_path)
	return glb_path, true
}

// Multi-Hull Convex Decomposition (`Mesh -> Multi-Hull Destructible CSGVolume`):
// - If the mesh is already convex (`_mesh_ed.report.compliant`), converts it as a single exact `CSG_Convex`.
// - If the mesh has carved tunnels, holes, recessed pockets, L-corners, staircases, or a Torus ring hole,
//   decomposes it via `_decompose_editable_mesh_to_csg_hulls` (Exact Concave-Plane Partitioning + 5-Ray
//   Jordan-Brouwer Parity Filtering + `csg_clean_and_simplify_hulls`) so every tunnel/hole stays 100% open!
convert_complex_mesh_to_multihull_csg :: proc(make_dynamic_physics := false) -> engine.Transform_Handle {
	return convert_editable_mesh_to_csg(make_dynamic_physics, append_to_active_volume = false)
}

// Raycasts against the active `Editable_Poly_Mesh` (`_mesh_ed.target_owner`) in World Space,
// returning the closest hit position, outward world normal, and ray distance `t`.
@(private = "package")
raycast_editable_poly_mesh_world :: proc(ray: engine.Ray) -> (hit_pos, hit_norm: [3]f32, hit_t: f32, ok: bool) {
	_ensure_mesh_ed_init()
	w := engine.ctx_world()
	if w == nil do return {}, {}, max(f32), false
	if sel := engine.inspector_active_selection(); sel != {} && engine.pool_valid(&w.transforms, engine.Handle(sel)) {
		if _, csg_v := engine.transform_get_comp(sel, cad_csg.CSGVolume); csg_v != nil && csg_v.enabled {
			return {}, {}, max(f32), false
		}
	}
	_sync_mesh_editor_with_selection()
	if _mesh_ed.target_owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) ||
	   len(_mesh_ed.verts) == 0 || len(_mesh_ed.faces) == 0 {
		return {}, {}, max(f32), false
	}
	// If the entity has an active CSGVolume, let CSG raycasting handle it instead
	if _, csg_v := engine.transform_get_comp(_mesh_ed.target_owner, cad_csg.CSGVolume); csg_v != nil && csg_v.enabled {
		return {}, {}, max(f32), false
	}

	model, _ := _mesh_model()
	best_t := max(f32)
	best_n := [3]f32{0, 1, 0}

	for poly_f in _mesh_ed.faces {
		m := len(poly_f.verts)
		if m < 3 do continue
		v0_w := _xf_point(model, _mesh_ed.verts[poly_f.verts[0]])
		fn_l, _ := _face_normal_and_center(poly_f)
		fn_w := linalg.normalize0(_xf_vec(model, fn_l))
		for ti in 1 ..< m - 1 {
			v1_w := _xf_point(model, _mesh_ed.verts[poly_f.verts[ti]])
			v2_w := _xf_point(model, _mesh_ed.verts[poly_f.verts[ti + 1]])
			if t_hit, hit_ok := _ray_triangle_intersect(ray, v0_w, v1_w, v2_w); hit_ok && t_hit < best_t {
				best_t = t_hit
				best_n = fn_w
			}
		}
	}
	if best_t < max(f32) {
		return ray.origin + ray.direction * best_t, best_n, best_t, true
	}
	return {}, {}, max(f32), false
}

// Applies a Soft Deformer impulse (`Dent_Inward`, `Bulge_Outward`, `Shockwave_Ripple`, `Twist_Shear`)
// directly to the vertices of the active `Editable_Poly_Mesh`, automatically subdividing any large
// low-poly face under the brush so even a simple 8-vert box mesh dents smoothly, and commits to Undo!
@(private = "package")
apply_soft_deform_to_editable_poly_mesh :: proc(
	world_pos:  [3]f32,
	world_norm: [3]f32,
	radius:     f32,
	amplitude:  f32,
	mode:       cad_csg.CSG_Soft_Deform_Mode,
) -> int {
	_ensure_mesh_ed_init()
	_sync_mesh_editor_with_selection()
	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) ||
	   len(_mesh_ed.verts) == 0 {
		return 0
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	_, inv := _mesh_model()
	local_pos  := _xf_point(inv, world_pos)
	local_norm := linalg.normalize0(_xf_vec(inv, world_norm))
	if linalg.length2(local_norm) < 0.25 do local_norm = {0, 1, 0}
	r_loc := max(radius, 0.20)

	// If any face near `local_pos` has long coarse edges (`> r_loc * 0.45`), perform up to 2 passes
	// of 1-to-4 edge+centroid subdivision so both the interior AND the boundary edges near the brush can deform smoothly!
	for _ in 0 ..< 2 {
		if len(_mesh_ed.faces) >= 1200 do break
		orig_face_n := len(_mesh_ed.faces)
		split_any := false
		for fi := orig_face_n - 1; fi >= 0; fi -= 1 {
			f := _mesh_ed.faces[fi]
			m := len(f.verts)
			if m < 3 do continue
			_, fc := _face_normal_and_center(f)
			if linalg.length(fc - local_pos) > r_loc * 1.25 do continue
			max_edge: f32 = 0.0
			for i in 0 ..< m {
				va := _mesh_ed.verts[f.verts[i]]
				vb := _mesh_ed.verts[f.verts[(i + 1) % m]]
				max_edge = max(max_edge, linalg.length(vb - va))
			}
			if max_edge > max(r_loc * 0.42, 0.28) {
				ring := make([]u32, m, context.temp_allocator)
				copy(ring, f.verts[:])
				f_col := f.color
				delete(_mesh_ed.faces[fi].verts)
				if _mesh_ed.faces[fi].uvs != nil do delete(_mesh_ed.faces[fi].uvs)
				ordered_remove(&_mesh_ed.faces, fi)

				if m == 3 {
					// 1-to-4 triangle midpoint subdivision
					v0, v1, v2 := ring[0], ring[1], ring[2]
					m01 := u32(len(_mesh_ed.verts)); append(&_mesh_ed.verts, (_mesh_ed.verts[v0] + _mesh_ed.verts[v1]) * 0.5)
					m12 := u32(len(_mesh_ed.verts)); append(&_mesh_ed.verts, (_mesh_ed.verts[v1] + _mesh_ed.verts[v2]) * 0.5)
					m20 := u32(len(_mesh_ed.verts)); append(&_mesh_ed.verts, (_mesh_ed.verts[v2] + _mesh_ed.verts[v0]) * 0.5)
					_add_poly_face({v0,  m01, m20}, f_col)
					_add_poly_face({m01, v1,  m12}, f_col)
					_add_poly_face({m20, m12, v2},  f_col)
					_add_poly_face({m01, m12, m20}, f_col)
				} else {
					// 1-to-m quad/polygon subdivision using edge midpoints + centroid
					c_vi := u32(len(_mesh_ed.verts))
					append(&_mesh_ed.verts, fc)
					mids := make([]u32, m, context.temp_allocator)
					for i in 0 ..< m {
						u := ring[i]
						v := ring[(i + 1) % m]
						mids[i] = u32(len(_mesh_ed.verts))
						append(&_mesh_ed.verts, (_mesh_ed.verts[u] + _mesh_ed.verts[v]) * 0.5)
					}
					for i in 0 ..< m {
						prev_m := mids[(i - 1 + m) % m]
						curr_v := ring[i]
						curr_m := mids[i]
						_add_poly_face({prev_m, curr_v, curr_m, c_vi}, f_col)
					}
				}
				split_any = true
			}
		}
		if !split_any do break
	}

	stamp := [1]cad_csg.CSG_Soft_Deform_Stamp{{
		local_pos     = local_pos,
		local_normal  = local_norm,
		radius        = r_loc,
		plastic_depth = amplitude,
		elastic_depth = 0.0,
		elastic_vel   = 0.0,
		mode          = mode,
	}}

	moved_verts := 0
	for vi in 0 ..< len(_mesh_ed.verts) {
		disp, _ := cad_csg.csg_eval_soft_deform_offset(stamp[:], _mesh_ed.verts[vi])
		if linalg.length2(disp) > 1e-6 {
			_mesh_ed.verts[vi] += disp
			moved_verts += 1
		}
	}

	if moved_verts > 0 {
		// Use `commit = false` during brush strokes so we never block on synchronous 3D CSG compliance dry-runs!
		_rebuild_editable_mesh_gpu(commit = false)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	return moved_verts
}

// ============================================================================
// 3D VIEWPORT GIZMOS, PICKING & AXIS LOCK RENDERING FOR MESH EDITOR MODE
// ============================================================================

@(private = "file")
_ray_triangle_intersect :: proc(ray: engine.Ray, v0, v1, v2: [3]f32) -> (t: f32, hit: bool) {
	e1 := v1 - v0
	e2 := v2 - v0
	h := linalg.cross(ray.direction, e2)
	a := linalg.dot(e1, h)
	if abs(a) < 1e-6 do return 0, false
	f := 1.0 / a
	s := ray.origin - v0
	u := f * linalg.dot(s, h)
	if u < 0.0 || u > 1.0 do return 0, false
	q := linalg.cross(s, e1)
	v := f * linalg.dot(ray.direction, q)
	if v < 0.0 || u + v > 1.0 do return 0, false
	t = f * linalg.dot(e2, q)
	return t, t > 0.01
}

// Draws and handles 3D Vertex (`1`), Edge (`2`), and Face (`3`) selection, AutoCAD 3D Wireframe
// point/edge placement, 1-push `X`/`Y`/`Z` Axis Constraints, sub-object Move / Rotate / Scale gizmos
// (following the Scene3D W / E / R toolbar), and Pivot / Origin editing (`O`) in `Scene3D`.
// Everything runs in WORLD space through the owner's full TRS matrix: verts are stored mesh-local,
// so rotated / scaled / parented objects pick and drag correctly.
draw_and_handle_mesh_editor_gizmos :: proc(tool: handles.Tool = .Translate) {
	_ensure_mesh_ed_init()
	_mesh_ed.hover_any = false
	if control_rig_ed.scene_viewport_mode != .CAD_Blockout || _mesh_ed.workspace_tab != .Mesh_Editor do return

	_sync_mesh_editor_with_selection()
	f := handles.frame()
	if !f.valid do return

	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) ||
	   (len(_mesh_ed.verts) == 0 && !_mesh_ed.wire_draw_mode) {
		_draw_mesh_editor_hint()
		return
	}

	// Follow the Scene3D Tools bar (W / E / R buttons & keys) whenever it changes
	if tool != _mesh_ed.last_tool {
		_mesh_ed.last_tool = tool
		#partial switch tool {
		case .Rotate: _mesh_ed.xform_mode = .Rotate
		case .Scale:  _mesh_ed.xform_mode = .Scale
		case:         _mesh_ed.xform_mode = .Move
		}
	}

	model, inv := _mesh_model()
	tw := engine.transform_world(_mesh_ed.target_owner)
	io := im.GetIO()

	// ---------------------------------------------------------------- Hotkeys
	rmb_down := im.IsMouseDown(.Right) || input.mouse_down(.Right)
	busy_drag := _mesh_ed.gizmo_dragging || _mesh_ed.face_extrude_dragging || _mesh_ed.face_inset_dragging || _mesh_ed.cutter_gizmo_dragging
	if f.input.hovered && !rmb_down && !io.WantTextInput && !busy_drag && !(io.KeyCtrl || io.KeySuper) && are_cad_hotkeys_enabled() {
		if are_subtool_number_hotkeys_enabled() {
			if _key_just_pressed(._1, ._1) { _mesh_ed.select_mode = .Vertex; _mesh_ed.wire_draw_mode = false }
			if _key_just_pressed(._2, ._2) { _mesh_ed.select_mode = .Edge;   _mesh_ed.wire_draw_mode = false }
			if _key_just_pressed(._3, ._3) { _mesh_ed.select_mode = .Face;   _mesh_ed.wire_draw_mode = false }
			if _key_just_pressed(._4, ._4) { _mesh_ed.select_mode = .Object; _mesh_ed.wire_draw_mode = false }
		}

		// Alt+Z toggles X-Ray Backfaces vs Occluded Front-Face Picking; X, Y, Z lock World Axes
		if io.KeyAlt && _key_just_pressed(.Z, .Z) {
			_mesh_ed.xray_mode = !_mesh_ed.xray_mode
		} else if are_axis_lock_hotkeys_enabled() {
			if _key_just_pressed(.X, .X) do set_axis_constraint(.X)
			if _key_just_pressed(.Y, .Y) do set_axis_constraint(.Y)
			if _key_just_pressed(.Z, .Z) do set_axis_constraint(.Z)
		}

		if are_modeling_op_hotkeys_enabled() {
			// Q / G = grab/move, E / R come from the Scene3D Tools bar
			if _key_just_pressed(.G, .G) || _key_just_pressed(.Q, .Q) do _mesh_ed.xform_mode = .Move
			// F = Make Face / Fill in Vertex/Edge mode; J = Connect Verts / Split Face in Vertex mode
			if (_mesh_ed.select_mode == .Vertex || _mesh_ed.select_mode == .Edge) && _key_just_pressed(.F, .F) {
				mesh_op_make_face_from_selected_verts()
			}
			if _mesh_ed.select_mode == .Vertex && _key_just_pressed(.J, .J) {
				mesh_op_connect_selected_verts()
			}
			// Shift+E = Extrude, I = Inset, B = Bevel (with live operator adjustment!)
			if io.KeyShift && _key_just_pressed(.E, .E) {
				_begin_active_op(.Extrude)
				mesh_op_extrude_selected(_mesh_ed.extrude_amount)
			}
			if _mesh_ed.select_mode == .Face && _key_just_pressed(.I, .I) {
				_begin_active_op(.Inset)
				mesh_op_inset_selected_face(_mesh_ed.inset_amount)
			}
			if _key_just_pressed(.B, .B) {
				if _mesh_ed.select_mode == .Edge {
					_begin_active_op(.Bevel_Edge)
					mesh_op_bevel_selected_edge(_mesh_ed.bevel_amount)
				} else if _mesh_ed.select_mode == .Face {
					_begin_active_op(.Bevel_Face)
					mesh_op_bevel_selected_face(_mesh_ed.bevel_amount, _mesh_ed.bevel_height)
				}
			}
			// O = toggle Pivot / Origin edit
			if _key_just_pressed(.O, .O) do _mesh_ed.pivot_edit = !_mesh_ed.pivot_edit
			// Enter when 3D Cutter Box Gizmo is open immediately carves the Cutter Box!
			if _mesh_ed.show_cutter_box_gizmo && (_key_just_pressed(.RETURN, .Enter) || _key_just_pressed(.KP_ENTER, .KeypadEnter)) {
				mesh_op_boolean_box(.Subtract)
			}
			// A = select all, Alt+A = deselect all
			if _key_just_pressed(.A, .A) {
				if io.KeyAlt {
					_mesh_clear_sub_selection()
				} else {
					_mesh_select_all()
				}
			}
		}
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// World-space vertex cache & front-face visibility cache for this frame
	wverts := make([][3]f32, len(_mesh_ed.verts), context.temp_allocator)
	for v, i in _mesh_ed.verts do wverts[i] = _xf_point(model, v)

	face_front := make([]bool, len(_mesh_ed.faces), context.temp_allocator)
	vert_front := make([]bool, len(_mesh_ed.verts), context.temp_allocator)
	if len(_mesh_ed.faces) == 0 {
		for i in 0 ..< len(vert_front) do vert_front[i] = true
	} else {
		is_ortho_view := abs(f.view.proj[3, 3]) > 0.5
		cam_fwd_view  := [3]f32{-f.view.view[2, 0], -f.view.view[2, 1], -f.view.view[2, 2]}
		for poly_f, fi in _mesh_ed.faces {
			if len(poly_f.verts) < 3 do continue
			fn_l, fc_l := _face_normal_and_center(poly_f)
			fn_w := linalg.normalize0(_xf_vec(model, fn_l))
			fc_w := _xf_point(model, fc_l)
			view_dir := cam_fwd_view if is_ortho_view else linalg.normalize0(fc_w - f.view.cam_pos)
			if linalg.dot(fn_w, view_dir) < 0.12 {
				face_front[fi] = true
				for vi in poly_f.verts {
					if int(vi) < len(vert_front) do vert_front[vi] = true
				}
			}
		}
	}

	// Draw explicit AutoCAD 3D Wireframe Cage edges in bright cyan-green
	if len(_mesh_ed.wire_edges) > 0 {
		gizmos.with_color({0.20, 0.96, 0.72, 0.92})
		for we in _mesh_ed.wire_edges {
			if int(we[0]) < len(wverts) && int(we[1]) < len(wverts) {
				gizmos.line(wverts[we[0]], wverts[we[1]])
			}
		}
	}

	// ------------------------------------------- AutoCAD 3D Wireframe sketching
	if _mesh_ed.wire_draw_mode {
		_handle_wire_draw_mode(f, model, inv, wverts)
		return
	}

	// ------------------------------------------- Hover detection (occlusion-aware unless X-Ray is on!)
	mouse := f.input.mouse
	hov_vert := -1
	hov_face := -1
	hov_edge: [2]u32
	hov_edge_ok := false
	best_t := max(f32)
	if !busy_drag && f.input.hovered {
		// Face under cursor (nearest front-facing ray hit, or any face if X-Ray is enabled)
		for poly_f, fi in _mesh_ed.faces {
			m := len(poly_f.verts)
			if m < 3 do continue
			if !_mesh_ed.xray_mode && !face_front[fi] do continue
			v0 := wverts[poly_f.verts[0]]
			for t_i in 1 ..< m - 1 {
				if hit_t, hit_ok := _ray_triangle_intersect(f.ray, v0, wverts[poly_f.verts[t_i]], wverts[poly_f.verts[t_i + 1]]); hit_ok && hit_t < best_t {
					best_t = hit_t
					hov_face = fi
				}
			}
		}
		switch _mesh_ed.select_mode {
		case .Vertex:
			best_px := f32(14.0 * 14.0)
			for wp, vi in wverts {
				if !_mesh_ed.xray_mode {
					if !vert_front[vi] do continue
					if best_t < max(f32) && linalg.length(wp - f.ray.origin) > best_t + 0.25 do continue
				}
				if px, ok := gizmos.helper_project_in(f.view, wp); ok {
					if d2 := linalg.length2(px - mouse); d2 < best_px {
						best_px = d2
						hov_vert = vi
					}
				}
			}
		case .Edge:
			best_px := f32(10.0)
			for poly_f, fi in _mesh_ed.faces {
				if !_mesh_ed.xray_mode && !face_front[fi] do continue
				m := len(poly_f.verts)
				for i in 0 ..< m {
					u := poly_f.verts[i]
					v := poly_f.verts[(i + 1) % m]
					if int(u) >= len(wverts) || int(v) >= len(wverts) do continue
					if !_mesh_ed.xray_mode && best_t < max(f32) {
						mid_d := linalg.length((wverts[u] + wverts[v]) * 0.5 - f.ray.origin)
						if mid_d > best_t + 0.30 do continue
					}
					if d := _screen_seg_dist(f.view, mouse, wverts[u], wverts[v]); d < best_px {
						best_px = d
						hov_edge = {u, v}
						hov_edge_ok = true
					}
				}
			}
			for we in _mesh_ed.wire_edges {
				u, v := we[0], we[1]
				if int(u) < len(wverts) && int(v) < len(wverts) {
					if d := _screen_seg_dist(f.view, mouse, wverts[u], wverts[v]); d < best_px {
						best_px = d
						hov_edge = {u, v}
						hov_edge_ok = true
					}
				}
			}
		case .Face:
		case .Object:
			hov_face = -1
		}
		_mesh_ed.hover_any = (_mesh_ed.select_mode != .Object) && (hov_vert >= 0 || hov_edge_ok || hov_face >= 0)
	}

	// ------------------------------------------- Draw cage, selection & hover
	dense := len(_mesh_ed.faces) > 8000
	for poly_f, fi in _mesh_ed.faces {
		m := len(poly_f.verts)
		if m < 3 do continue
		is_sel := _mesh_ed.select_mode == .Face && _face_is_selected(fi)
		is_hov := _mesh_ed.select_mode == .Face && fi == hov_face
		if dense && !is_sel && !is_hov do continue

		if is_sel || is_hov {
			gizmos.with_depth_test(false)
			col := [4]f32{1.0, 0.78, 0.18, 0.98} if is_sel else [4]f32{1.0, 1.0, 1.0, 0.88}
			gizmos.with_color(col)
			for i in 0 ..< m {
				gizmos.line(wverts[poly_f.verts[i]], wverts[poly_f.verts[(i + 1) % m]])
			}
			gizmos.with_color({col.r, col.g, col.b, 0.24 if is_sel else 0.14})
			v0 := wverts[poly_f.verts[0]]
			for t_i in 1 ..< m - 1 {
				gizmos.solid_triangle(v0, wverts[poly_f.verts[t_i]], wverts[poly_f.verts[t_i + 1]])
			}
		} else if _mesh_ed.xray_mode || face_front[fi] {
			gizmos.with_depth_test(!_mesh_ed.xray_mode)
			gizmos.with_color({0.28, 0.82, 0.98, 0.45 if _mesh_ed.xray_mode else 0.82})
			for i in 0 ..< m {
				gizmos.line(wverts[poly_f.verts[i]], wverts[poly_f.verts[(i + 1) % m]])
			}
		}
	}
	gizmos.with_depth_test(false)

	// Draw unmistakable 3D Object Type Badge Pill (`[POLY MESH]`) above the editable mesh!
	if len(wverts) > 0 {
		w_lo := wverts[0]
		w_hi := wverts[0]
		for wp in wverts[1:] {
			w_lo = linalg.min(w_lo, wp)
			w_hi = linalg.max(w_hi, wp)
		}
		m_name := "Mesh"
		if tm := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner)); tm != nil && len(tm.name) > 0 {
			m_name = tm.name
		}
		top_pt := [3]f32{(w_lo.x + w_hi.x) * 0.5, w_hi.y + 0.32, (w_lo.z + w_hi.z) * 0.5}
		_draw_3d_tracked_pill(
			top_pt,
			fmt.tprintf("[POLY MESH] %s (%dV, %dF)", m_name, len(_mesh_ed.verts), len(_mesh_ed.faces)),
			{1.0, 0.58, 0.16, 1.0},
		)
	}

	// Highlight Boolean Target `Mesh B` (`_mesh_ed.bool_target_b`) in Scene3D if valid!
	if _mesh_ed.bool_target_b != {} && _mesh_ed.bool_target_b != _mesh_ed.target_owner &&
	   engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.bool_target_b)) {
		tw_b := engine.transform_world(_mesh_ed.bool_target_b)
		gizmos.with_color({1.0, 0.35, 0.92, 0.95})
		gizmos.wire_box(tw_b.position, linalg.max(tw_b.scale * 2.0, [3]f32{0.5, 0.5, 0.5}))
		b_name := "Mesh B"
		if tb := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.bool_target_b)); tb != nil && len(tb.name) > 0 {
			b_name = tb.name
		}
		_draw_3d_tracked_pill(tw_b.position + {0, 1.25, 0}, fmt.tprintf("Boolean Mesh B: %s", b_name), {1.0, 0.45, 0.95, 1.0})
	}

	// Non-compliant Open Boundary Edges (orange-red) and Concave Vertices (magenta)
	if len(_mesh_ed.report.open_edge_pairs) > 0 && !dense {
		gizmos.with_color({1.0, 0.28, 0.12, 1.0})
		for pair in _mesh_ed.report.open_edge_pairs {
			if int(pair[0]) < len(wverts) && int(pair[1]) < len(wverts) {
				gizmos.line(wverts[pair[0]], wverts[pair[1]])
			}
		}
	}
	if len(_mesh_ed.report.concave_verts) > 0 && !dense {
		gizmos.with_color({1.0, 0.18, 0.78, 1.0})
		for vi in _mesh_ed.report.concave_verts {
			if int(vi) < len(wverts) {
				gizmos.solid_sphere(wverts[vi], handles.world_per_pixels(wverts[vi], 4.5))
			}
		}
	}

	// Marked UV Seams (bright neon orange lines in 3D viewport)
	if len(_mesh_ed.uv_seams) > 0 {
		gizmos.with_color({1.0, 0.50, 0.08, 1.0})
		for seam in _mesh_ed.uv_seams {
			if int(seam[0]) < len(wverts) && int(seam[1]) < len(wverts) {
				gizmos.line(wverts[seam[0]], wverts[seam[1]])
			}
		}
	}

	switch _mesh_ed.select_mode {
	case .Vertex:
		for wp, vi in wverts {
			is_sel := false
			for sv in _mesh_ed.selected_verts do if int(sv) == vi { is_sel = true; break }
			if dense && !is_sel && vi != hov_vert do continue
			if !_mesh_ed.xray_mode && !is_sel && vi != hov_vert && !vert_front[vi] do continue
			col := [4]f32{0.30, 0.90, 1.0, 0.85}
			if vi == hov_vert do col = {1.0, 1.0, 1.0, 1.0}
			if is_sel do col = {1.0, 0.82, 0.18, 1.0}
			gizmos.with_color(col)
			gizmos.solid_sphere(wp, handles.world_per_pixels(wp, 5.5 if (is_sel || vi == hov_vert) else 3.5))
		}
	case .Edge:
		if hov_edge_ok {
			gizmos.with_color({1.0, 1.0, 1.0, 1.0})
			gizmos.line(wverts[hov_edge[0]], wverts[hov_edge[1]])
		}
		if _mesh_ed.has_selected_edge {
			u, v := _mesh_ed.selected_edge[0], _mesh_ed.selected_edge[1]
			if int(u) < len(wverts) && int(v) < len(wverts) {
				gizmos.with_color({1.0, 0.85, 0.18, 1.0})
				gizmos.line(wverts[u], wverts[v])
				mid := (wverts[u] + wverts[v]) * 0.5
				gizmos.solid_sphere(mid, handles.world_per_pixels(mid, 5))
			}
		}
	case .Face:
	case .Object:
	}

	gizmo_size :: proc(v: engine.Render_View, p: [3]f32) -> f32 {
		cam_fwd := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
		if abs(v.proj[3, 3]) > 0.5 && abs(v.proj[1, 1]) > 1e-6 {
			return (1.0 / abs(v.proj[1, 1])) * 2.41421356 * 0.14
		}
		depth := max(linalg.dot(p - v.cam_pos, cam_fwd), 0.25)
		return depth * (2.41421356 / max(abs(v.proj[1, 1]), 0.1)) * 0.14
	}

	// ------------------------------------------- 3D Plane Cut Preview (`_mesh_ed.show_cut_plane_preview`)
	if _mesh_ed.show_cut_plane_preview && len(_mesh_ed.verts) > 0 {
		m_lo := _mesh_ed.verts[0]
		m_hi := _mesh_ed.verts[0]
		for v in _mesh_ed.verts[1:] {
			m_lo = linalg.min(m_lo, v)
			m_hi = linalg.max(m_hi, v)
		}
		m_mid := (m_lo + m_hi) * 0.5
		m_ext := linalg.max((m_hi - m_lo) * 0.65, [3]f32{0.8, 0.8, 0.8})
		ax := clamp(_mesh_ed.cut_plane_axis, 0, 2)
		off := _mesh_ed.cut_plane_offset
		q_pts: [4][3]f32
		n_loc: [3]f32
		n_loc[ax] = -1.0 if _mesh_ed.cut_plane_keep_neg else 1.0
		if ax == 0 {
			q_pts = {{off, m_mid.y - m_ext.y, m_mid.z - m_ext.z}, {off, m_mid.y + m_ext.y, m_mid.z - m_ext.z}, {off, m_mid.y + m_ext.y, m_mid.z + m_ext.z}, {off, m_mid.y - m_ext.y, m_mid.z + m_ext.z}}
		} else if ax == 1 {
			q_pts = {{m_mid.x - m_ext.x, off, m_mid.z - m_ext.z}, {m_mid.x + m_ext.x, off, m_mid.z - m_ext.z}, {m_mid.x + m_ext.x, off, m_mid.z + m_ext.z}, {m_mid.x - m_ext.x, off, m_mid.z + m_ext.z}}
		} else {
			q_pts = {{m_mid.x - m_ext.x, m_mid.y - m_ext.y, off}, {m_mid.x + m_ext.x, m_mid.y - m_ext.y, off}, {m_mid.x + m_ext.x, m_mid.y + m_ext.y, off}, {m_mid.x - m_ext.x, m_mid.y + m_ext.y, off}}
		}
		wq: [4][3]f32
		for p, i in q_pts do wq[i] = _xf_point(model, p)
		gizmos.with_color({0.15, 0.96, 0.88, 0.92})
		for i in 0 ..< 4 do gizmos.line(wq[i], wq[(i + 1) % 4])
		gizmos.with_color({0.15, 0.96, 0.88, 0.16})
		gizmos.solid_triangle(wq[0], wq[1], wq[2])
		gizmos.solid_triangle(wq[0], wq[2], wq[3])
		pc_w := (wq[0] + wq[2]) * 0.5
		nw_w := linalg.normalize0(_xf_vec(model, n_loc))
		gizmos.with_color({0.25, 1.0, 0.50, 0.98})
		gizmos.line(pc_w, pc_w + nw_w * 0.65)
		gizmos.solid_sphere(pc_w + nw_w * 0.65, handles.world_per_pixels(pc_w, 5.0))
		ax_names := [3]string{"X", "Y", "Z"}
		_draw_3d_tracked_pill(pc_w + nw_w * 0.80, fmt.tprintf("Plane Cut %s = %+.2fm (Green Arrow = Kept Half)", ax_names[ax], off), {0.20, 0.98, 0.88, 1.0})
	}

	// ------------------------------------------- 3D Boolean Cutter Box Gizmo (`_mesh_ed.show_cutter_box_gizmo`)
	_MESH_CUTTER_GIZMO_ID :: u64(0x4D45_5348_4355_5442)
	if _mesh_ed.show_cutter_box_gizmo {
		c_world := _xf_point(model, _mesh_ed.bool_box_offset)
		sz_world := _mesh_ed.bool_box_size * tw.scale
		gizmos.with_depth_test(false)
		gizmos.with_color({1.0, 0.24, 0.20, 0.96})
		gizmos.wire_box(c_world, sz_world)
		// Draw X-Ray diagonal cross on the cutter box so it reads unmistakably as a boolean cutter
		hs := sz_world * 0.5
		gizmos.with_color({1.0, 0.35, 0.25, 0.55})
		gizmos.line(c_world - hs, c_world + hs)
		gizmos.line(c_world + {-hs.x, -hs.y, hs.z}, c_world + {hs.x, hs.y, -hs.z})

		c_size := gizmo_size(f.view, c_world)
		cd: handles.Drag
		if _mesh_ed.xform_mode == .Scale {
			if !_mesh_ed.cutter_gizmo_dragging do _mesh_ed.cutter_gizmo_scale = {1, 1, 1}
			cd = handles.scale_handle(_MESH_CUTTER_GIZMO_ID, &_mesh_ed.cutter_gizmo_scale, c_world, quaternion128(1), c_size, handles.PRIO_TOOL)
			if cd.started {
				_mesh_ed.cutter_gizmo_dragging = true
				_mesh_ed.cutter_gizmo_start_sz = _mesh_ed.bool_box_size
				_mesh_ed.cutter_gizmo_scale    = {1, 1, 1}
			}
			if _mesh_ed.cutter_gizmo_dragging && (cd.dragging || cd.released) {
				_mesh_ed.bool_box_size = {
					max(_mesh_ed.cutter_gizmo_start_sz.x * _mesh_ed.cutter_gizmo_scale.x, 0.10),
					max(_mesh_ed.cutter_gizmo_start_sz.y * _mesh_ed.cutter_gizmo_scale.y, 0.10),
					max(_mesh_ed.cutter_gizmo_start_sz.z * _mesh_ed.cutter_gizmo_scale.z, 0.10),
				}
			}
		} else {
			pos_c := _mesh_ed.cutter_gizmo_start_pos if _mesh_ed.cutter_gizmo_dragging else c_world
			cd = handles.position_handle(_MESH_CUTTER_GIZMO_ID, &pos_c, quaternion128(1), c_size, handles.PRIO_TOOL)
			if cd.started {
				_mesh_ed.cutter_gizmo_dragging  = true
				_mesh_ed.cutter_gizmo_start_pos = c_world
				_mesh_ed.cutter_gizmo_start_off = _mesh_ed.bool_box_offset
			}
			if _mesh_ed.cutter_gizmo_dragging && (cd.dragging || cd.released) {
				delta_w := _apply_axis_lock(pos_c - _mesh_ed.cutter_gizmo_start_pos)
				_mesh_ed.bool_box_offset = _mesh_ed.cutter_gizmo_start_off + _xf_vec(inv, delta_w)
			}
		}
		if cd.released || (_mesh_ed.cutter_gizmo_dragging && !cd.dragging) {
			_mesh_ed.cutter_gizmo_dragging = false
		}
		_draw_3d_tracked_pill(
			c_world + {0, hs.y + handles.world_per_pixels(c_world, 22), 0},
			fmt.tprintf("3D Cutter Box (%.2fx%.2fx%.2fm) [W=Move, R=Scale | Enter = -Cut Box]", _mesh_ed.bool_box_size.x, _mesh_ed.bool_box_size.y, _mesh_ed.bool_box_size.z),
			{1.0, 0.40, 0.32, 1.0},
		)
	}

	// ------------------------------------------- Direct 3D Interactive Face Extrude/Tunnel & Inset Handles
	if _mesh_ed.select_mode == .Face && _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) &&
	   !_mesh_ed.pivot_edit && !_mesh_ed.show_cutter_box_gizmo && !_mesh_ed.gizmo_dragging {
		sel_fi := _mesh_ed.selected_face
		sel_f  := _mesh_ed.faces[sel_fi]
		if len(sel_f.verts) >= 3 {
			fn_l, fc_l := _face_normal_and_center(sel_f)
			fc_w := _xf_point(model, fc_l)
			fn_w := linalg.normalize0(_xf_vec(model, fn_l))
			ext_ax_w := fn_w
			if _mesh_ed.axis_lock == .X do ext_ax_w = {1, 0, 0} if fn_w.x >= -0.01 else {-1, 0, 0}
			if _mesh_ed.axis_lock == .Y do ext_ax_w = {0, 1, 0} if fn_w.y >= -0.01 else {0, -1, 0}
			if _mesh_ed.axis_lock == .Z do ext_ax_w = {0, 0, 1} if fn_w.z >= -0.01 else {0, 0, -1}

			f_giz_size := gizmo_size(f.view, fc_w)
			ext_knob_w := fc_w + ext_ax_w * (f_giz_size * 1.38)
			if _mesh_ed.face_extrude_dragging {
				ext_knob_w = _mesh_ed.face_extrude_origin_w + _mesh_ed.face_extrude_axis_w * _mesh_ed.face_extrude_delta
			}

			// 1. Gold 3D Face Extrude (+Out) / Carve Tunnel (-In) Knob
			ext_hot := _mesh_ed.face_extrude_dragging
			if !ext_hot && !_mesh_ed.face_inset_dragging && f.input.hovered {
				if px, ok := gizmos.helper_project_in(f.view, ext_knob_w); ok {
					if linalg.length2(px - mouse) <= 15.0 * 15.0 {
						ext_hot = true
						_mesh_ed.hover_any = true
					}
				}
			}

			ext_col := [4]f32{1.0, 0.96, 0.32, 1.0} if ext_hot else [4]f32{1.0, 0.72, 0.14, 0.98}
			gizmos.with_color(ext_col)
			gizmos.line(fc_w, ext_knob_w)
			gizmos.solid_sphere(ext_knob_w, handles.world_per_pixels(ext_knob_w, 8.0 if ext_hot else 6.5))
			gizmos.wire_circle(ext_knob_w, ext_ax_w, handles.world_per_pixels(ext_knob_w, 12.0), 20)

			if ext_hot && !_mesh_ed.face_extrude_dragging {
				_draw_3d_tracked_pill(
					ext_knob_w + ext_ax_w * handles.world_per_pixels(ext_knob_w, 22),
					"Drag Gold Handle: Extrude (+Out) / Carve Pocket or Tunnel (-In) [Hold Shift = Inset]",
					{1.0, 0.92, 0.28, 1.0},
				)
			}

			if !_mesh_ed.face_extrude_dragging && ext_hot && f.input.clicked {
				handles.claim_mouse(true)
				ins_ovr: f32 = _mesh_ed.inset_amount if (io.KeyShift || f.input.shift) else 0.0
				_begin_poly_face_interactive_extrude(_mesh_ed.target_owner, sel_fi, fc_w, fn_w, ext_ax_w, f.ray, ins_ovr)
				_mesh_ed.face_extrude_dragging = true
				_mesh_ed.face_extrude_origin_w = fc_w
				_mesh_ed.face_extrude_axis_w   = ext_ax_w
				_mesh_ed.face_extrude_start_s  = _ray_closest_dist_along_axis(f.ray, fc_w, ext_ax_w)
				_mesh_ed.face_extrude_delta    = 0
			}

			if _mesh_ed.face_extrude_dragging {
				handles.claim_mouse(true)
				if im.IsMouseClicked(.Right) || _key_just_pressed(.ESCAPE, .Escape) {
					_cancel_poly_face_interactive_extrude()
				} else {
					cur_s := _ray_closest_dist_along_axis(f.ray, _mesh_ed.face_extrude_origin_w, _mesh_ed.face_extrude_axis_w)
					raw_d := cur_s - _mesh_ed.face_extrude_start_s
					step_s: f32 = _ed.snap_step if io.KeyCtrl else 0.05
					delta_e := _snap_scalar(raw_d, step_s)
					_mesh_ed.face_extrude_delta = delta_e
					_apply_face_push_pull_delta(delta_e)

					act_tag := "EXTRUDE (+Out)" if delta_e >= 0 else "CARVE POCKET / TUNNEL (-In)"
					act_col := [4]f32{0.30, 1.0, 0.55, 1.0} if delta_e >= 0 else [4]f32{1.0, 0.45, 0.28, 1.0}
					_draw_3d_tracked_pill(
						ext_knob_w + _mesh_ed.face_extrude_axis_w * handles.world_per_pixels(ext_knob_w, 24),
						fmt.tprintf("%s: %+.2f m (Release to Commit, RMB = Cancel)", act_tag, delta_e),
						act_col,
					)

					if !f.input.down {
						_mesh_ed.face_extrude_dragging = false
						_ed.push_active = false
						_finish_poly_face_interactive_extrude(delta_e)
					}
				}
			}

			// 2. Cyan 3D Interactive Face Inset Knob (between face center and first corner vertex)
			if !_mesh_ed.face_extrude_dragging && int(sel_f.verts[0]) < len(wverts) {
				v0_w := wverts[sel_f.verts[0]]
				ins_knob_w := linalg.lerp(fc_w, v0_w, 0.66)
				ins_hot := _mesh_ed.face_inset_dragging
				if !ins_hot && f.input.hovered {
					if px, ok := gizmos.helper_project_in(f.view, ins_knob_w); ok {
						if linalg.length2(px - mouse) <= 13.0 * 13.0 {
							ins_hot = true
							_mesh_ed.hover_any = true
						}
					}
				}
				ins_col := [4]f32{0.40, 1.0, 1.0, 1.0} if ins_hot else [4]f32{0.18, 0.88, 0.96, 0.92}
				gizmos.with_color(ins_col)
				gizmos.line(fc_w, ins_knob_w)
				gizmos.solid_sphere(ins_knob_w, handles.world_per_pixels(ins_knob_w, 6.5 if ins_hot else 5.0))
				if ins_hot && !_mesh_ed.face_inset_dragging {
					_draw_3d_tracked_pill(
						ins_knob_w + fn_w * handles.world_per_pixels(ins_knob_w, 20),
						"Drag Cyan Handle: Interactive Inset Face (I)",
						{0.25, 0.98, 1.0, 1.0},
					)
				}
				if !_mesh_ed.face_inset_dragging && ins_hot && f.input.clicked {
					handles.claim_mouse(true)
					if _mesh_ed.has_pre_extrude_snap do _snapshot_free(&_mesh_ed.pre_extrude_snap)
					_mesh_ed.pre_extrude_snap      = _snapshot_take()
					_mesh_ed.has_pre_extrude_snap  = true
					_mesh_ed.face_inset_dragging   = true
					_mesh_ed.face_inset_handle_pos = fc_w
					_mesh_ed.face_inset_start_dist = max(linalg.length(v0_w - fc_w), 0.10)
				}
				if _mesh_ed.face_inset_dragging {
					handles.claim_mouse(true)
					if im.IsMouseClicked(.Right) || _key_just_pressed(.ESCAPE, .Escape) {
						if _mesh_ed.has_pre_extrude_snap {
							_snapshot_restore(_mesh_ed.pre_extrude_snap, false)
							_snapshot_free(&_mesh_ed.pre_extrude_snap)
							_mesh_ed.has_pre_extrude_snap = false
							_mesh_ed.selected_face = sel_fi
							_rebuild_editable_mesh_gpu(commit = false)
						}
						_mesh_ed.face_inset_dragging = false
					} else {
						// Intersect mouse ray with face plane `(fc_w, fn_w)` to measure live inset ratio
						denom := linalg.dot(fn_w, f.ray.direction)
						cur_r := _mesh_ed.inset_amount
						if abs(denom) > 1e-4 {
							t_pl := linalg.dot(_mesh_ed.face_inset_handle_pos - f.ray.origin, fn_w) / denom
							hit_pl := f.ray.origin + f.ray.direction * t_pl
							dist_c := linalg.length(hit_pl - _mesh_ed.face_inset_handle_pos)
							cur_r = clamp(1.0 - (dist_c / _mesh_ed.face_inset_start_dist), 0.05, 0.85)
						}
						_mesh_ed.inset_amount = cur_r
						if _mesh_ed.has_pre_extrude_snap {
							_snapshot_restore(_mesh_ed.pre_extrude_snap, false)
							_mesh_ed.selected_face = sel_fi
							mesh_op_inset_selected_face(cur_r, commit = !f.input.down)
						}
						_draw_3d_tracked_pill(
							_mesh_ed.face_inset_handle_pos + fn_w * handles.world_per_pixels(_mesh_ed.face_inset_handle_pos, 26),
							fmt.tprintf("INSET FACE: %.0f%% (Release to Commit, RMB = Cancel)", cur_r * 100.0),
							{0.25, 0.98, 1.0, 1.0},
						)
						if !f.input.down {
							if _mesh_ed.has_pre_extrude_snap {
								_snapshot_free(&_mesh_ed.pre_extrude_snap)
								_mesh_ed.has_pre_extrude_snap = false
							}
							_mesh_ed.face_inset_dragging = false
						}
					}
				}
			}
		}
	}

	// ------------------------------------------- Gizmo (sub-object or pivot)
	active := make([dynamic]u32, 0, 32, context.temp_allocator)
	_collect_active_verts(&active)

	_MESH_SUB_GIZMO_ID   :: u64(0x4D45_5348_5355_4247)
	_MESH_PIVOT_GIZMO_ID :: u64(0x4D45_5348_5049_5654)

	if _mesh_ed.pivot_edit {
		// Pivot / Origin edit: move the object's origin, geometry & children stay put in the world
		start := _mesh_ed.pivot_drag_start if _mesh_ed.gizmo_dragging else tw.position
		pos := start
		d := handles.position_handle(_MESH_PIVOT_GIZMO_ID, &pos, quaternion128(1), gizmo_size(f.view, start), handles.PRIO_TOOL)
		if d.started {
			_mesh_ed.gizmo_dragging   = true
			_mesh_ed.pivot_drag_start = tw.position
			resize(&_mesh_ed.drag_orig_verts, len(_mesh_ed.verts))
			copy(_mesh_ed.drag_orig_verts[:], _mesh_ed.verts[:])
			clear(&_mesh_ed.pivot_children)
			if t := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner)); t != nil {
				for c in t.children {
					if engine.pool_valid(&w.transforms, c.handle) {
						ch := engine.Transform_Handle(c.handle)
						append(&_mesh_ed.pivot_children, Mesh_Child_Pos{ch, engine.transform_world(ch).position})
					}
				}
			}
		}
		if _mesh_ed.gizmo_dragging && (d.dragging || d.released) {
			delta := _apply_axis_lock(pos - _mesh_ed.pivot_drag_start)
			new_world := _mesh_ed.pivot_drag_start + delta
			local_off := _xf_vec(inv, delta)
			for i in 0 ..< min(len(_mesh_ed.verts), len(_mesh_ed.drag_orig_verts)) {
				_mesh_ed.verts[i] = _mesh_ed.drag_orig_verts[i] - local_off
			}
			engine.transform_set_world_position(_mesh_ed.target_owner, new_world)
			for k in _mesh_ed.pivot_children do engine.transform_set_world_position(k.tH, k.pos)
			_rebuild_editable_mesh_gpu(commit = d.released)
		}
		if _mesh_ed.gizmo_dragging && !d.dragging && !d.released {
			_mesh_ed.gizmo_dragging = false
			_rebuild_editable_mesh_gpu(commit = true)
		}
		if d.released do _mesh_ed.gizmo_dragging = false

		cur := engine.transform_world(_mesh_ed.target_owner).position
		gizmos.with_color({1.0, 0.45, 0.95, 1.0})
		gizmos.solid_sphere(cur, handles.world_per_pixels(cur, 7))
		_draw_3d_tracked_pill(cur + {0, handles.world_per_pixels(cur, 26), 0}, "PIVOT / ORIGIN EDIT (O to exit)", {1.0, 0.55, 0.95, 1.0})
	} else if len(active) > 0 && !_mesh_ed.show_cutter_box_gizmo && !_mesh_ed.face_extrude_dragging && !_mesh_ed.face_inset_dragging {
		pivot: [3]f32
		for vi in active do pivot += wverts[vi]
		pivot /= f32(len(active))
		if _mesh_ed.gizmo_dragging do pivot = _mesh_ed.gizmo_pivot_world

		// Compute Local / Face-Normal gizmo orientation quaternion when `_mesh_ed.local_gizmo_space` is active
		orient_q := quaternion128(1)
		if _mesh_ed.local_gizmo_space && _mesh_ed.axis_lock == .Free {
			if _mesh_ed.select_mode == .Face && _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) {
				fn_l, _ := _face_normal_and_center(_mesh_ed.faces[_mesh_ed.selected_face])
				fn_w := linalg.normalize0(_xf_vec(model, fn_l))
				if linalg.length2(fn_w) > 0.5 {
					u_w, v_w := cad_csg.plane_tangent_basis(fn_w)
					orient_q = linalg.quaternion_from_matrix3_f32(matrix[3, 3]f32{
						u_w.x, v_w.x, fn_w.x,
						u_w.y, v_w.y, fn_w.y,
						u_w.z, v_w.z, fn_w.z,
					})
				}
			} else {
				orient_q = engine.quat_to_native(tw.rotation)
			}
		}

		// Infinite Blender-style axis constraint line through the pivot
		if _mesh_ed.axis_lock != .Free {
			ax_dir, ax_col, ax_name := _axis_lock_info()
			gizmos.with_color(ax_col)
			gizmos.line(pivot - ax_dir * 25.0, pivot + ax_dir * 25.0)
			_draw_3d_tracked_pill(pivot + {0, handles.world_per_pixels(pivot, 30), 0}, fmt.tprintf("LOCKED TO WORLD %s", ax_name), ax_col)
		}

		size := gizmo_size(f.view, pivot)
		d: handles.Drag
		switch _mesh_ed.xform_mode {
		case .Move:
			pos := pivot
			d = handles.position_handle(_MESH_SUB_GIZMO_ID, &pos, orient_q, size, handles.PRIO_TOOL)
			if d.started do _begin_sub_drag(pivot)
			if _mesh_ed.gizmo_dragging && (d.dragging || d.released) {
				delta := _apply_axis_lock(pos - _mesh_ed.gizmo_pivot_world)
				local_delta := _xf_vec(inv, delta)
				for vi in active {
					if int(vi) < len(_mesh_ed.drag_orig_verts) {
						_mesh_ed.verts[vi] = _mesh_ed.drag_orig_verts[vi] + local_delta
					}
				}
				_rebuild_editable_mesh_gpu(commit = d.released)
			}
		case .Rotate:
			if !_mesh_ed.gizmo_dragging do _mesh_ed.gizmo_rot = quaternion128(1)
			d = handles.rotation_handle(_MESH_SUB_GIZMO_ID, &_mesh_ed.gizmo_rot, pivot, size, false, handles.PRIO_TOOL)
			if d.started {
				_begin_sub_drag(pivot)
				_mesh_ed.gizmo_rot = quaternion128(1)
			}
			if _mesh_ed.gizmo_dragging && (d.dragging || d.released) {
				turn := _mesh_ed.gizmo_rot
				for vi in active {
					if int(vi) < len(_mesh_ed.drag_orig_verts) {
						wp := _xf_point(model, _mesh_ed.drag_orig_verts[vi])
						wp2 := pivot + linalg.quaternion128_mul_vector3(turn, wp - pivot)
						_mesh_ed.verts[vi] = _xf_point(inv, wp2)
					}
				}
				_rebuild_editable_mesh_gpu(commit = d.released)
			}
		case .Scale:
			if !_mesh_ed.gizmo_dragging do _mesh_ed.gizmo_scale = {1, 1, 1}
			d = handles.scale_handle(_MESH_SUB_GIZMO_ID, &_mesh_ed.gizmo_scale, pivot, orient_q, size, handles.PRIO_TOOL)
			if d.started {
				_begin_sub_drag(pivot)
				_mesh_ed.gizmo_scale = {1, 1, 1}
			}
			if _mesh_ed.gizmo_dragging && (d.dragging || d.released) {
				s := _mesh_ed.gizmo_scale
				switch _mesh_ed.axis_lock {
				case .Free:
				case .X: s = {s.x if s.x != 1 else (s.y if s.y != 1 else s.z), 1, 1}
				case .Y: s = {1, s.y if s.y != 1 else (s.x if s.x != 1 else s.z), 1}
				case .Z: s = {1, 1, s.z if s.z != 1 else (s.x if s.x != 1 else s.y)}
				}
				inv_orient := linalg.quaternion_inverse(orient_q)
				for vi in active {
					if int(vi) < len(_mesh_ed.drag_orig_verts) {
						wp := _xf_point(model, _mesh_ed.drag_orig_verts[vi])
						rel_local := linalg.quaternion128_mul_vector3(inv_orient, wp - pivot)
						wp_scaled := pivot + linalg.quaternion128_mul_vector3(orient_q, rel_local * s)
						_mesh_ed.verts[vi] = _xf_point(inv, wp_scaled)
					}
				}
				_rebuild_editable_mesh_gpu(commit = d.released)
			}
		}
		if _mesh_ed.gizmo_dragging && !d.dragging && !d.released {
			// Drag lost without a release frame (selection changed mid-drag): still record it
			_mesh_ed.gizmo_dragging = false
			_rebuild_editable_mesh_gpu(commit = true)
		}
		if d.released do _mesh_ed.gizmo_dragging = false
	}

	// ------------------------------------------- Click picking (when not on the gizmo)
	if f.input.clicked && f.input.hovered && !handles.consumes_mouse() && !busy_drag && !_mesh_ed.face_extrude_dragging && !_mesh_ed.face_inset_dragging && _mesh_ed.select_mode != .Object {
		_clear_active_op()
		multi_sel := f.input.shift || io.KeyCtrl || io.KeySuper || input.key_down(.LCTRL) || input.key_down(.RCTRL)
		switch _mesh_ed.select_mode {
		case .Vertex:
			if hov_vert >= 0 {
				if multi_sel {
					removed := false
					for sv, i in _mesh_ed.selected_verts {
						if int(sv) == hov_vert { ordered_remove(&_mesh_ed.selected_verts, i); removed = true; break }
					}
					if !removed do append(&_mesh_ed.selected_verts, u32(hov_vert))
				} else {
					clear(&_mesh_ed.selected_verts)
					append(&_mesh_ed.selected_verts, u32(hov_vert))
				}
			} else if !multi_sel {
				clear(&_mesh_ed.selected_verts)
			}
		case .Edge:
			if hov_edge_ok {
				_mesh_ed.selected_edge = hov_edge
				_mesh_ed.has_selected_edge = true
			} else if !multi_sel {
				_mesh_ed.has_selected_edge = false
			}
		case .Face:
			if hov_face >= 0 {
				if multi_sel {
					if _face_is_selected(hov_face) {
						if hov_face == _mesh_ed.selected_face {
							_mesh_ed.selected_face = pop(&_mesh_ed.sel_faces) if len(_mesh_ed.sel_faces) > 0 else -1
						} else {
							for sf, i in _mesh_ed.sel_faces do if sf == hov_face { ordered_remove(&_mesh_ed.sel_faces, i); break }
						}
					} else {
						if _mesh_ed.selected_face >= 0 do append(&_mesh_ed.sel_faces, _mesh_ed.selected_face)
						_mesh_ed.selected_face = hov_face
					}
				} else {
					clear(&_mesh_ed.sel_faces)
					_mesh_ed.selected_face = hov_face
				}
			} else if !multi_sel {
				clear(&_mesh_ed.sel_faces)
				_mesh_ed.selected_face = -1
			}
		case .Object:
		}
	}
}

@(private = "file")
_begin_sub_drag :: proc(pivot: [3]f32) {
	_mesh_ed.gizmo_dragging    = true
	_mesh_ed.gizmo_start_pos   = pivot
	_mesh_ed.gizmo_pivot_world = pivot
	resize(&_mesh_ed.drag_orig_verts, len(_mesh_ed.verts))
	copy(_mesh_ed.drag_orig_verts[:], _mesh_ed.verts[:])
}

@(private = "file")
_apply_axis_lock :: proc(delta: [3]f32) -> [3]f32 {
	switch _mesh_ed.axis_lock {
	case .Free: return delta
	case .X:    return {delta.x, 0, 0}
	case .Y:    return {0, delta.y, 0}
	case .Z:    return {0, 0, delta.z}
	}
	return delta
}

@(private = "file")
_axis_lock_info :: proc() -> (dir: [3]f32, col: [4]f32, name: string) {
	switch _mesh_ed.axis_lock {
	case .Free, .X: return {1, 0, 0}, {1.0, 0.25, 0.25, 0.95}, "X"
	case .Y:        return {0, 1, 0}, {0.25, 0.95, 0.35, 0.95}, "Y"
	case .Z:        return {0, 0, 1}, {0.30, 0.62, 1.0, 0.95}, "Z"
	}
	return {1, 0, 0}, {1, 1, 1, 1}, "X"
}

@(private = "file")
_screen_seg_dist :: proc(view: engine.Render_View, mouse: [2]f32, a, b: [3]f32) -> f32 {
	sa, oka := gizmos.helper_project_in(view, a)
	sb, okb := gizmos.helper_project_in(view, b)
	if !oka || !okb do return max(f32)
	ab := sb - sa
	t: f32 = 0
	if l2 := linalg.dot(ab, ab); l2 > 0 do t = clamp(linalg.dot(mouse - sa, ab) / l2, 0, 1)
	return linalg.length(mouse - (sa + ab * t))
}

@(private = "package")
_mesh_select_all :: proc() {
	switch _mesh_ed.select_mode {
	case .Vertex:
		clear(&_mesh_ed.selected_verts)
		for i in 0 ..< len(_mesh_ed.verts) do append(&_mesh_ed.selected_verts, u32(i))
	case .Edge:
		// Edges are single-select: switch to Vertex mode with everything selected
		_mesh_ed.select_mode = .Vertex
		_mesh_select_all()
	case .Face:
		clear(&_mesh_ed.sel_faces)
		_mesh_ed.selected_face = 0 if len(_mesh_ed.faces) > 0 else -1
		for i in 1 ..< len(_mesh_ed.faces) do append(&_mesh_ed.sel_faces, i)
	case .Object:
	}
}

// Viewport hint when CAD Mesh Editor is open but nothing editable is loaded
@(private = "file")
_draw_mesh_editor_hint :: proc() {
	w := engine.ctx_world()
	if w == nil do return
	sel := engine.inspector_active_selection()
	if sel == {} || !engine.pool_valid(&w.transforms, engine.Handle(sel)) do return
	msg := _mesh_ed.load_error if len(_mesh_ed.load_error) > 0 else "Mesh Editor: select a mesh object to edit its vertices / edges / faces"
	p := engine.transform_world(sel).position
	_draw_3d_tracked_pill(p + {0, handles.world_per_pixels(p, 40), 0}, msg, {1.0, 0.62, 0.30, 1.0})
}

// AutoCAD 3D Wireframe Cage interactive sketching (`_mesh_ed.wire_draw_mode`), in world space
@(private = "file")
_handle_wire_draw_mode :: proc(f: handles.Frame, model, inv: matrix[4, 4]f32, wverts: [][3]f32) {
	_mesh_ed.hover_any = true // wireframe drawing owns every viewport click
	wp_pt, _, wp_ok := _raycast_workplane(f.ray)
	local_pt := _xf_point(inv, wp_pt) if wp_ok else [3]f32{0, 0, 0}
	if _mesh_ed.wire_last_vert >= 0 && _mesh_ed.wire_last_vert < len(_mesh_ed.verts) && _mesh_ed.axis_lock != .Free {
		last_v := _mesh_ed.verts[_mesh_ed.wire_last_vert]
		switch _mesh_ed.axis_lock {
		case .Free:
		case .X: local_pt = {local_pt.x, last_v.y, last_v.z}
		case .Y: local_pt = {last_v.x, local_pt.y, last_v.z}
		case .Z: local_pt = {last_v.x, last_v.y, local_pt.z}
		}
	}
	// Snap onto an existing vertex to close a wireframe loop
	snap_vi := -1
	for wp, vi in wverts {
		if px, ok := gizmos.helper_project_in(f.view, wp); ok {
			if linalg.length2(px - f.input.mouse) < 18.0 * 18.0 {
				snap_vi = vi
				local_pt = _mesh_ed.verts[vi]
				break
			}
		}
	}
	cursor_w := _xf_point(model, local_pt)
	gizmos.with_color({1.0, 0.90, 0.25, 1.0})
	gizmos.solid_sphere(cursor_w, handles.world_per_pixels(cursor_w, 6))
	if _mesh_ed.wire_last_vert >= 0 && _mesh_ed.wire_last_vert < len(wverts) {
		gizmos.line(wverts[_mesh_ed.wire_last_vert], cursor_w)
	}
	_draw_3d_tracked_pill(cursor_w + {0, handles.world_per_pixels(cursor_w, 24), 0}, "3D Wireframe: Click = Add Point (RMB = End Chain, X/Y/Z = Lock Axis)", {0.25, 0.98, 0.78, 1.0})

	if im.IsMouseClicked(.Right) && f.input.hovered {
		_mesh_ed.wire_last_vert = -1
	}
	if f.input.clicked && f.input.hovered {
		handles.claim_mouse(true)
		prev := context.allocator
		context.allocator = runtime.default_allocator()
		defer context.allocator = prev

		new_vi: u32
		if snap_vi >= 0 {
			new_vi = u32(snap_vi)
		} else {
			new_vi = u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, local_pt)
		}
		if _mesh_ed.wire_last_vert >= 0 && _mesh_ed.wire_last_vert < len(_mesh_ed.verts) {
			_add_wire_edge(u32(_mesh_ed.wire_last_vert), new_vi)
		}
		if _mesh_ed.wire_mirror_x && abs(local_pt.x) > 0.05 && snap_vi < 0 {
			mir_vi := u32(len(_mesh_ed.verts))
			append(&_mesh_ed.verts, [3]f32{-local_pt.x, local_pt.y, local_pt.z})
			_add_wire_edge(new_vi, mir_vi)
		}
		_mesh_ed.wire_last_vert = int(new_vi)
		_history_commit()
	}
}

// ============================================================================
// SLIM 42PX ICON DOCK + FLOATING PIN-ABLE POPOVER DRAWER IN `Scene3D`
// (CAD REDUX: Reclaims ~370 px of Viewport Real Estate by Default!)
// ============================================================================

draw_cad_left_drawer :: proc(img_min, img_max: im.Vec2) {
	_ensure_mesh_ed_init()
	_sync_viewport_mode()
	_mesh_ed.drawer_hovered = false

	in_cad_mode := (control_rig_ed.scene_viewport_mode == .CAD_Blockout)
	if !in_cad_mode {
		_mesh_ed.drawer_anim_t = 0.0
		return
	}

	// Always draw the docked Bottom CAD Command-Line & Live Telemetry Pill while in CAD Mode!
	draw_cad_bottom_telemetry_hud(img_min, img_max)

	// Smoothly animate slide-out width of the active category popover panel
	target_t: f32 = 1.0 if _mesh_ed.drawer_open else 0.0
	dt := clamp(im.GetIO().DeltaTime, 0.001, 0.1)
	_mesh_ed.drawer_anim_t = linalg.lerp(_mesh_ed.drawer_anim_t, target_t, clamp(dt * 16.0, 0.0, 1.0))
	if abs(_mesh_ed.drawer_anim_t - target_t) < 0.01 {
		_mesh_ed.drawer_anim_t = target_t
	}

	rail_w        :: f32(42.0)
	drawer_full_w :: f32(288.0)
	cur_w         := drawer_full_w * _mesh_ed.drawer_anim_t
	top_y         := img_min.y + 42.0
	max_h         := max(img_max.y - top_y - 36.0, 220.0)

	is_csg := (_mesh_ed.workspace_tab == .CSG_Editor)

	// ------------------------------------------------------------------------
	// 1. SLIM 42PX LEFT ICON DOCK (Always visible in CAD Mode; collapsed by default)
	//    Clicking an icon pops out its focused card; clicking again collapses it!
	// ------------------------------------------------------------------------
	rail_h := f32(304.0) if !is_csg else f32(268.0)
	im.SetCursorScreenPos({img_min.x + 4.0, top_y})
	im.PushStyleColorImVec4(.ChildBg, {0.08, 0.10, 0.13, 0.94})
	im.PushStyleColorImVec4(.Border, {0.26, 0.46, 0.68, 0.72})
	im.PushStyleVar(.ChildRounding, 7.0)
	im.PushStyleVar(.ChildBorderSize, 1.0)
	im.PushStyleVarImVec2(.WindowPadding, {4, 5})

	if im.BeginChild("##cad_multi_drawer_rail", {rail_w, min(rail_h, max_h)}, {.Borders}, {.NoScrollbar, .NoScrollWithMouse}) {
		if im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem | im.HoveredFlags_ChildWindows) {
			_mesh_ed.drawer_hovered = true
		}

		btn_w := rail_w - 8.0

		// Workspace Mode Switcher Icon at top of 42px dock: toggles CSG <-> Mesh!
		im.PushStyleColorImVec4(.Button, {0.18, 0.54, 0.78, 0.98} if is_csg else {0.82, 0.48, 0.16, 0.98})
		ws_icon := fmt.ctprintf("%s##cad_dock_ws", icons.ICON_MD_VIEW_IN_AR if is_csg else icons.ICON_MD_HEXAGON)
		if im.Button(ws_icon, {btn_w, 28}) {
			set_workspace_tab(.Mesh_Editor if is_csg else .CSG_Editor)
		}
		im.PopStyleColor(1)
		widgets.tooltip(
			"Active Workspace: CSG Blockout Mode (click to switch to Polygon Mesh Mode)" if is_csg else
			"Active Workspace: Polygon Mesh Mode (click to switch to CSG Blockout Mode)",
		)

		im.Separator()

		if is_csg {
			csg_drawers := [5]struct {
				id:   CAD_CSG_Drawer,
				lbl:  cstring,
				tip:  cstring,
				col:  im.Vec4,
			}{
				{.Draw_Brushes,  icons.ICON_MD_DRAW + "##csg_d1",      "1. CSG Draw & Brushes Popover: Spline (1), Box/Shape (2), Extrude (3), Geo-Mod Blast (4), Clip Plane (5), Soft Deform (6). Click icon to open/close!", {0.18, 0.54, 0.80, 0.98}},
				{.Booleans,      icons.ICON_MD_JOIN_FULL + "##csg_d2", "2. CSG Booleans Popover: Ctrl+Click 2+ CSG Volumes in Scene3D for A + B (Union), A - B (Subtract), A & B (Intersect)!",                                  {0.82, 0.36, 0.22, 0.98}},
				{.Kitbash_Glass, icons.ICON_MD_PENTAGON + "##csg_d3",  "3. Faker CSG & 3D Glass Popover: Drag-and-Drop 3D Meshes into CSGVolume colliders or draw 3D Shatterable Glass Loops (7)!",                              {0.16, 0.68, 0.52, 0.98}},
				{.Bake_Convert,  icons.ICON_MD_SAVE + "##csg_d4",      "4. CSG Bake & Convert Popover: Bake & Save CSG, Convert CSG -> Editable Mesh, Static Mesh Copy, Smart Clean.",                                           {0.20, 0.62, 0.40, 0.98}},
				{.Mat_Deform,    icons.ICON_MD_PALETTE + "##csg_d5",   "5. Material DataTable, Procedural Texture Studio & Soft Deformer Body Brush Popover!",                                                                   {0.78, 0.28, 0.72, 0.98}},
			}
			for item in csg_drawers {
				is_sel := (_mesh_ed.active_csg_drawer == item.id)
				if is_sel {
					col := item.col
					if !_mesh_ed.drawer_open do col.w = 0.58
					im.PushStyleColorImVec4(.Button, col)
				}
				if im.Button(item.lbl, {btn_w, 32}) {
					if _mesh_ed.active_csg_drawer == item.id {
						_mesh_ed.drawer_open = !_mesh_ed.drawer_open
					} else {
						_mesh_ed.active_csg_drawer = item.id
						_mesh_ed.drawer_open = true
						if item.id == .Booleans {
							deactivate_cad_tool()
						}
					}
				}
				if is_sel do im.PopStyleColor(1)
				widgets.tooltip(item.tip)
			}
		} else {
			mesh_drawers := [6]struct {
				id:   CAD_Mesh_Drawer,
				lbl:  cstring,
				tip:  cstring,
				col:  im.Vec4,
			}{
				{.Shapes,     icons.ICON_MD_CATEGORY + "##msh_d1",  "1. Shapes & Wireframe Popover: Spawn Box, Cyl, Sphere, Cone, Torus, Wedge, Stairs, Car Wireframe & 3D Sketch.",              {0.18, 0.58, 0.46, 0.98}},
				{.Poly_Edit,  icons.ICON_MD_POLYLINE + "##msh_d2",  "2. Poly Edit Popover: [1] Vert, [2] Edge, [3] Face, [4] Object modes + Extrude/Tunnel, Inset, Bevel, Loop Cut, Weld.",        {0.20, 0.56, 0.82, 0.98}},
				{.Booleans,   icons.ICON_MD_JOIN_FULL + "##msh_d3", "3. Mesh Booleans Popover: Ctrl+Click 2+ Meshes in Scene3D for A + B (Union), A - B (Subtract), A & B (Intersect) + Plane Cut!", {0.82, 0.36, 0.22, 0.98}},
				{.UV_Suite,   icons.ICON_MD_GRID_4X4 + "##msh_d4",  "4. UV Suite Popover: Open 2D UV Editor Window + Box/Planar/Cylinder/Sphere/Auto-Islands Unwrap & Pack!",                      {0.22, 0.64, 0.78, 0.98}},
				{.Convert,    icons.ICON_MD_SAVE + "##msh_d5",      "5. Save & Convert Popover: Save Mesh to Disk (.glb + .obj), Multi-Pass Auto-Fix & Convert Mesh <-> Multi-Hull CSG!",          {0.78, 0.52, 0.18, 0.98}},
				{.Mat_Deform, icons.ICON_MD_PALETTE + "##msh_d6",   "6. Material DataTable, Procedural Texture Studio & Soft Deformer Renderer Math Debug Popover!",                               {0.78, 0.28, 0.72, 0.98}},
			}
			for item in mesh_drawers {
				is_sel := (_mesh_ed.active_mesh_drawer == item.id)
				if is_sel {
					col := item.col
					if !_mesh_ed.drawer_open do col.w = 0.58
					im.PushStyleColorImVec4(.Button, col)
				}
				if im.Button(item.lbl, {btn_w, 32}) {
					if _mesh_ed.active_mesh_drawer == item.id {
						_mesh_ed.drawer_open = !_mesh_ed.drawer_open
					} else {
						_mesh_ed.active_mesh_drawer = item.id
						_mesh_ed.drawer_open = true
						if item.id == .Booleans {
							_mesh_ed.select_mode = .Object
							_mesh_ed.wire_draw_mode = false
							_clear_active_op()
						}
					}
				}
				if is_sel do im.PopStyleColor(1)
				widgets.tooltip(item.tip)
			}
		}

		im.Separator()
		tog_lbl := fmt.ctprintf("%s##cad_dock_tog", icons.ICON_MD_CHEVRON_LEFT if _mesh_ed.drawer_open else icons.ICON_MD_CHEVRON_RIGHT)
		if im.Button(tog_lbl, {btn_w, 24}) {
			_mesh_ed.drawer_open = !_mesh_ed.drawer_open
		}
		widgets.tooltip("Open or collapse the floating tool popover card (your selected tool remains active when collapsed!)")
	}
	im.EndChild()
	im.PopStyleVar(3)
	im.PopStyleColor(2)

	if cur_w < 8.0 do return

	// ------------------------------------------------------------------------
	// 2. FLOATING PIN-ABLE POPOVER CARD (Auto-collapses on 3D click unless pinned!)
	// ------------------------------------------------------------------------
	im.SetCursorScreenPos({img_min.x + rail_w + 8.0, top_y})
	im.PushStyleColorImVec4(.ChildBg, {0.10, 0.12, 0.16, 0.96})
	im.PushStyleColorImVec4(.Border, {0.28, 0.48, 0.68, 0.74})
	im.PushStyleVar(.ChildRounding, 7.0)
	im.PushStyleVar(.ChildBorderSize, 1.0)
	im.PushStyleVarImVec2(.WindowPadding, {8, 8})

	drawer_h := min(max_h, 560.0)
	if im.BeginChild("##cad_scene3d_left_drawer", {max(cur_w, 1.0), max(drawer_h, 1.0)}, {.Borders}, {}) {
		if im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem | im.HoveredFlags_ChildWindows) {
			_mesh_ed.drawer_hovered = true
		}

		avail_w  := max(im.GetContentRegionAvail().x, 120.0)
		half_w   := (avail_w - 4.0) * 0.5
		third_w  := (avail_w - 8.0) / 3.0
		fourth_w := (avail_w - 12.0) * 0.25

		// Compact Popover Header with Pin toggle (`Lock` vs `Unlock`) and `[x]` Close button
		card_title: cstring = "CAD Popover"
		if is_csg {
			switch _mesh_ed.active_csg_drawer {
			case .Draw_Brushes:  card_title = "1. CSG Draw & Brushes"
			case .Booleans:      card_title = "2. CSG Booleans"
			case .Kitbash_Glass: card_title = "3. Faker CSG & Glass"
			case .Bake_Convert:  card_title = "4. Bake & Convert"
			case .Mat_Deform:    card_title = "5. Materials & Deform"
			}
		} else {
			switch _mesh_ed.active_mesh_drawer {
			case .Shapes:     card_title = "1. Shapes & Wireframe"
			case .Poly_Edit:  card_title = "2. Polygon Mesh Edit"
			case .Booleans:   card_title = "3. Mesh Booleans"
			case .UV_Suite:   card_title = "4. UV Suite"
			case .Convert:    card_title = "5. Save & Convert"
			case .Mat_Deform: card_title = "6. Materials & Deform"
			}
		}
		im.TextColoredUnformatted({0.58, 0.88, 1.0, 1.0}, card_title)
		im.SameLine(max(avail_w - 52.0, 80.0))
		was_pinned := _mesh_ed.drawer_pinned
		if was_pinned do im.PushStyleColorImVec4(.Button, {0.22, 0.58, 0.84, 0.98})
		pin_lbl := fmt.ctprintf("%s##cad_pin_drawer", icons.ICON_MD_LOCK if was_pinned else icons.ICON_MD_LOCK_OPEN)
		if im.Button(pin_lbl, {24, 20}) {
			_mesh_ed.drawer_pinned = !was_pinned
		}
		if was_pinned do im.PopStyleColor(1)
		widgets.tooltip(
			"Pinned Open: card stays open while clicking in the 3D viewport (click to unpin)" if _mesh_ed.drawer_pinned else
			"Unpinned Popover: card auto-collapses out of your way as soon as you click in Scene3D (click to pin open)",
		)
		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s##cad_close_drawer", icons.ICON_MD_CLOSE), {24, 20}) {
			_mesh_ed.drawer_open = false
		}
		widgets.tooltip("Collapse popover card back into the 42px icon dock")

		// Shared Header: CAD Session Memory Cache + Undo/Redo + Axis Lock
		_draw_cad_session_cache_and_axis_header(avail_w, half_w, third_w, fourth_w, is_csg)
		im.Separator()

		if is_csg {
			switch _mesh_ed.active_csg_drawer {
			case .Draw_Brushes:  _draw_csg_drawer_draw(avail_w, half_w)
			case .Booleans:      _draw_csg_drawer_booleans(avail_w, half_w, third_w)
			case .Kitbash_Glass: _draw_csg_drawer_kitbash(avail_w, half_w)
			case .Bake_Convert:  _draw_csg_drawer_bake(avail_w, half_w)
			case .Mat_Deform:    _draw_csg_drawer_materials_and_deform(avail_w, half_w, third_w)
			}
		} else {
			switch _mesh_ed.active_mesh_drawer {
			case .Shapes:     _draw_mesh_drawer_shapes(avail_w, half_w, third_w)
			case .Poly_Edit:  _draw_mesh_drawer_poly_edit(avail_w, half_w, third_w, fourth_w)
			case .Booleans:   _draw_mesh_drawer_booleans(avail_w, half_w, third_w)
			case .UV_Suite:   _draw_mesh_drawer_uv_suite(avail_w, half_w, third_w)
			case .Convert:    _draw_mesh_drawer_convert(avail_w, half_w)
			case .Mat_Deform: _draw_csg_drawer_materials_and_deform(avail_w, half_w, third_w)
			}
		}
	}
	im.EndChild()

	im.PopStyleVar(3)
	im.PopStyleColor(2)

	// Auto-collapse unpinned popover card when clicking directly into the 3D viewport!
	if _mesh_ed.drawer_open && !_mesh_ed.drawer_pinned && !_mesh_ed.drawer_hovered && !im.IsAnyItemHovered() && !im.IsPopupOpen(nil, im.PopupFlags_AnyPopupId) && im.IsMouseClicked(.Left) {
		mp := im.GetIO().MousePos
		if mp.x >= img_min.x + rail_w + cur_w + 10.0 && mp.x <= img_max.x && mp.y >= top_y && mp.y <= img_max.y {
			_mesh_ed.drawer_open = false
		}
	}
}

// ============================================================================
// SHARED HEADER: CAD SESSION MEMORY CACHE + UNDO/REDO + AXIS LOCK
// ============================================================================

@(private = "file")
_draw_cad_session_cache_and_axis_header :: proc(avail_w, half_w, third_w, fourth_w: f32, is_csg: bool) {
	// 0. Unmistakable Active Object Type Badge (`[POLY MESH]` vs `[CSG VOLUME]` vs `[FAKER CSG]`)
	w_hdr := engine.ctx_world()
	sel_hdr := engine.inspector_active_selection()
	badge_lbl: cstring = "[NO MESH / CSG SELECTED]"
	badge_col := im.Vec4{0.24, 0.27, 0.32, 0.95}
	badge_tip: cstring = "Click any Mesh or CSG Volume in Scene3D (or spawn a shape) to see whether it is a [POLY MESH], [CSG VOLUME], or [FAKER CSG]!"

	if w_hdr != nil && sel_hdr != {} && engine.pool_valid(&w_hdr.transforms, engine.Handle(sel_hdr)) {
		obj_name := "Object"
		if t_hdr := engine.pool_get(&w_hdr.transforms, engine.Handle(sel_hdr)); t_hdr != nil && len(t_hdr.name) > 0 {
			obj_name = t_hdr.name
		}
		_, csg_hdr := engine.transform_get_comp(sel_hdr, cad_csg.CSGVolume)
		_, mf_hdr  := engine.transform_get_comp(sel_hdr, engine.MeshFilter)

		if csg_hdr != nil && csg_hdr.enabled {
			hulls_n := len(csg_hdr.runtime_hulls) + len(csg_hdr.brushes)
			if csg_hdr.is_faker_mesh {
				badge_lbl = fmt.ctprintf("[FAKER CSG] %s (%d Hulls + Instance)", obj_name, hulls_n)
				badge_col = {0.12, 0.68, 0.44, 0.98}
				badge_tip = "This object is a [FAKER CSG]: an outer destructible CSGVolume physics collider wrapping an inner GPU-Instanced 3D Mesh!"
			} else {
				badge_lbl = fmt.ctprintf("[CSG VOLUME] %s (%d Brushes, %d Hulls)", obj_name, len(csg_hdr.brushes), len(csg_hdr.runtime_hulls))
				badge_col = {0.14, 0.56, 0.84, 0.98}
				badge_tip = "This object is a [CSG VOLUME]: a half-space boolean & multi-hull destructible CSG solid collider (ready for Booleans, 2-Pt Slicing, Soft Deform, or Faker CSG!)."
			}
		} else if mf_hdr != nil || (_mesh_ed.target_owner == sel_hdr && len(_mesh_ed.verts) > 0) {
			badge_lbl = fmt.ctprintf("[POLY MESH] %s (%dV, %dF)", obj_name, len(_mesh_ed.verts), len(_mesh_ed.faces))
			badge_col = {0.84, 0.46, 0.12, 0.98}
			badge_tip = "This object is a [POLY MESH]: an editable polygon mesh (Vertices / Edges / Faces / UVs). Convert it to a [CSG VOLUME] in Drawer 5 (or Drawer 3) to use CSG & Faker CSG tools!"
		}
	}
	im.PushStyleColorImVec4(.Button, badge_col)
	im.PushStyleColorImVec4(.ButtonHovered, badge_col)
	im.PushStyleColorImVec4(.ButtonActive, badge_col)
	_ = im.Button(badge_lbl, {avail_w, 23})
	im.PopStyleColor(3)
	widgets.tooltip(badge_tip)

	// 1. CAD Session Memory Cache status + Undo / Redo buttons
	cache_on, m_undo_n, _, c_undo_n, _, bytes_used := cad_mode_memory_cache_stats()
	kb_used := f32(bytes_used) / 1024.0
	im.TextColoredUnformatted({0.40, 0.96, 0.68, 1.0}, fmt.ctprintf("CAD Cache: %s (%.1f KB)", "Active" if cache_on else "Idle", kb_used))
	widgets.tooltip("Dedicated CAD Mode Session Memory Cache: allocated automatically when entering CAD Mode to store Mesh & CSG Undo/Redo snapshots, and freed 100%% when exiting CAD Mode!")

	if is_csg {
		vol_u, owner_u := _resolve_active_volume(false)
		if vol_u != nil && owner_u != {} {
			csg_history_ensure_baseline(vol_u)
		}
		can_u := len(_mesh_ed.csg_undo_stack) > 0 && owner_u != {} && _mesh_ed.csg_history_owner == owner_u
		can_r := len(_mesh_ed.csg_redo_stack) > 0 && owner_u != {} && _mesh_ed.csg_history_owner == owner_u
		if !can_u do im.BeginDisabled()
		if im.Button(fmt.ctprintf("Undo CSG (%d)", c_undo_n), {half_w, 22}) do mesh_editor_undo()
		widgets.tooltip("Undo the last CSG brush, boolean, extrude, clip, or blast operation (Ctrl+Z)")
		if !can_u do im.EndDisabled()
		im.SameLine(0, 4)
		if !can_r do im.BeginDisabled()
		if im.Button(fmt.ctprintf("Redo CSG (%d)", len(_mesh_ed.csg_redo_stack)), {half_w, 22}) do mesh_editor_redo()
		widgets.tooltip("Redo the last undone CSG operation (Ctrl+Shift+Z)")
		if !can_r do im.EndDisabled()
	} else {
		w := engine.ctx_world()
		has_target := w != nil && _mesh_ed.target_owner != {} && engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.target_owner)) && len(_mesh_ed.verts) > 0
		if has_target {
			name := "Mesh"
			if t := engine.pool_get(&w.transforms, engine.Handle(_mesh_ed.target_owner)); t != nil && len(t.name) > 0 do name = t.name
			im.TextColoredUnformatted({0.75, 0.95, 1.0, 1.0}, fmt.ctprintf("Target: %s (%dV, %dF)", name, len(_mesh_ed.verts), len(_mesh_ed.faces)))
		} else {
			im.TextColored({1.0, 0.72, 0.35, 1.0}, "Target: (Click a Mesh/CSG or Spawn Shape)")
		}
		can_u := len(_mesh_ed.undo_stack) > 0 && _mesh_ed.history_owner == _mesh_ed.target_owner
		can_r := len(_mesh_ed.redo_stack) > 0 && _mesh_ed.history_owner == _mesh_ed.target_owner
		if !can_u do im.BeginDisabled()
		if im.Button(fmt.ctprintf("Undo (%d)", m_undo_n), {half_w, 22}) do mesh_editor_undo()
		widgets.tooltip("Undo the last mesh edit or boolean in CAD Session Cache (Ctrl+Z)")
		if !can_u do im.EndDisabled()
		im.SameLine(0, 4)
		if !can_r do im.BeginDisabled()
		if im.Button(fmt.ctprintf("Redo (%d)", len(_mesh_ed.redo_stack)), {half_w, 22}) do mesh_editor_redo()
		widgets.tooltip("Redo the last undone mesh edit in CAD Session Cache (Ctrl+Shift+Z)")
		if !can_r do im.EndDisabled()
	}

	// 2. Compact 1-Push World Axis Lock Bar (`[Free]`, `[X]`, `[Y]`, `[Z]`)
	ax_items := [4]struct {
		mode: Axis_Constraint,
		lbl:  cstring,
		col:  im.Vec4,
	}{
		{.Free, "Free",   {0.32, 0.36, 0.42, 0.95}},
		{.X,    "X Axis", {0.82, 0.22, 0.22, 0.95}},
		{.Y,    "Y Axis", {0.20, 0.68, 0.30, 0.95}},
		{.Z,    "Z Axis", {0.22, 0.48, 0.88, 0.95}},
	}
	for item, idx in ax_items {
		if idx > 0 do im.SameLine(0, 4)
		active_ax := (_mesh_ed.axis_lock == item.mode)
		if active_ax do im.PushStyleColorImVec4(.Button, item.col)
		if im.Button(item.lbl, {fourth_w, 21}) {
			set_axis_constraint(item.mode)
			switch item.mode {
			case .Free: _ed.extrude_axis_mode = .Face_Normal
			case .X:    _ed.extrude_axis_mode = .World_X
			case .Y:    _ed.extrude_axis_mode = .World_Y
			case .Z:    _ed.extrude_axis_mode = .World_Z
			}
		}
		if active_ax do im.PopStyleColor(1)
		widgets.tooltip("Free: no axis lock" if item.mode == .Free else fmt.ctprintf("Lock to World %s (hotkey %s, press again to unlock)", item.lbl, "X" if item.mode == .X else ("Y" if item.mode == .Y else "Z")))
	}
}

// ============================================================================
// CSG DRAWER 1: `1.Draw` — AUTOCAD / CSG BLOCKOUT BRUSH TOOLS
// ============================================================================

@(private = "file")
_draw_csg_drawer_draw :: proc(avail_w, half_w: f32) {
	im.TextColored({0.45, 0.88, 1.0, 1.0}, "Drawer 1: CSG Blockout & Brushes")

	// Quick toggle back to Q/E/R Transform / Picker in Scene3D
	qer_act := !_ed.tool_active
	if qer_act do im.PushStyleColorImVec4(.Button, {0.22, 0.62, 0.44, 0.98})
	if im.Button("Select / Move / Rotate / Scale (Q/E/R)", {avail_w, 24}) {
		deactivate_cad_tool()
	}
	if qer_act do im.PopStyleColor(1)
	widgets.tooltip("Use standard Scene3D Q (Move), E (Rotate), R (Scale) and Ctrl+Click selection")

	// 2x2 Grid of CSG Sub-Tools with Right-Click Settings Popups
	s1_act := _ed.tool_active && _ed.sub_tool == .Spline_Poly_Sketch
	if s1_act do im.PushStyleColorImVec4(.Button, {0.20, 0.56, 0.80, 0.98})
	widgets.ui_tool_script_loc(tool_impl_location(.Spline_Poly_Sketch), "CAD 2D Spline Sketcher", draw_spline_tool_right_click_settings)
	if im.Button(fmt.ctprintf("%s Spline (1)", icons.ICON_MD_POLYLINE), {half_w, 26}) {
		toggle_cad_tool(.Spline_Poly_Sketch)
	}
	widgets.tooltip("Spline Sketch (1): click points on the WorkPlane, Enter closes the loop and pulls it into a 3D solid. Right-Click for settings")
	if s1_act do im.PopStyleColor(1)
	im.SameLine(0, 4)

	s2_act := _ed.tool_active && _ed.sub_tool == .Box_Primitive
	if s2_act do im.PushStyleColorImVec4(.Button, {0.20, 0.56, 0.80, 0.98})
	widgets.ui_tool_script_loc(tool_impl_location(.Box_Primitive), "CAD 3D Box / Primitive Builder", draw_box_tool_right_click_settings)
	if im.Button(fmt.ctprintf("%s Box/Shape (2)", icons.ICON_MD_VIEW_IN_AR), {half_w, 26}) {
		toggle_cad_tool(.Box_Primitive)
	}
	widgets.tooltip("Box / Shape (2): drag a footprint, then pull the height. Right-Click for shape and boolean settings")
	if s2_act do im.PopStyleColor(1)

	s3_act := _ed.tool_active && _ed.sub_tool == .Face_Push_Pull
	if s3_act do im.PushStyleColorImVec4(.Button, {0.20, 0.56, 0.80, 0.98})
	widgets.ui_tool_script_loc(tool_impl_location(.Face_Push_Pull), "Blender-Style Face Extrude / Intrude Tool", draw_extrude_tool_right_click_settings)
	if im.Button(fmt.ctprintf("%s Extrude (3)", icons.ICON_MD_ARCHITECTURE), {half_w, 26}) {
		toggle_cad_tool(.Face_Push_Pull)
	}
	widgets.tooltip("Extrude / Intrude (3): drag any CSG or mesh face outward or inward. Right-Click for axis and mode")
	if s3_act do im.PopStyleColor(1)
	im.SameLine(0, 4)

	s4_act := _ed.tool_active && _ed.sub_tool == .Geo_Mod_Blast
	if s4_act do im.PushStyleColorImVec4(.Button, {0.86, 0.28, 0.16, 0.98})
	widgets.ui_tool_script_loc(tool_impl_location(.Geo_Mod_Blast), "Red Faction Geo-Mod Blast Tool", draw_blast_tool_right_click_settings)
	if im.Button(fmt.ctprintf("%s Blast (4/B)", icons.ICON_MD_ADS_CLICK), {half_w, 26}) {
		toggle_cad_tool(.Geo_Mod_Blast)
	}
	widgets.tooltip("Geo-Mod Blast (4 / B): click a destructible CSG surface to blast a crater. Right-Click for radius / impulse")
	if s4_act do im.PopStyleColor(1)

	s5_act := _ed.tool_active && _ed.sub_tool == .Clip_Brush_Plane
	if s5_act do im.PushStyleColorImVec4(.Button, {0.20, 0.64, 0.76, 0.98})
	widgets.ui_tool_script_loc(tool_impl_location(.Clip_Brush_Plane), "SabreCSG / RealtimeCSG 2-Point Clip Plane Slicer", draw_clip_plane_tool_right_click_settings)
	if im.Button(fmt.ctprintf("%s Clip Plane (5)", icons.ICON_MD_CROP_FREE), {half_w, 25}) {
		toggle_cad_tool(.Clip_Brush_Plane)
	}
	widgets.tooltip("Clip Plane Slicer (5): click Point A and Point B in Scene3D to slice or bevel any CSG volume along an arbitrary plane (Tab cycles Split Both / Keep Back / Keep Front)")
	if s5_act do im.PopStyleColor(1)
	im.SameLine(0, 4)

	s6_act := _ed.tool_active && _ed.sub_tool == .Soft_Deform_Brush
	if s6_act do im.PushStyleColorImVec4(.Button, {0.78, 0.28, 0.86, 0.98})
	widgets.ui_tool_script_loc(tool_impl_location(.Soft_Deform_Brush), "Soft Deformer Coordinate-Offset Brush", draw_soft_deform_tool_right_click_settings)
	if im.Button(fmt.ctprintf("%s Soft Deform (6)", icons.ICON_MD_TUNE), {half_w, 25}) {
		toggle_cad_tool(.Soft_Deform_Brush)
	}
	widgets.tooltip("Soft Deformer Brush (6): click any CSG surface to dent, bulge, ripple, or twist visual mesh coordinates while Jolt CSG collision stays 100% untouched!")
	if s6_act do im.PopStyleColor(1)

	is_add := (_ed.brush_op == .Add)
	im.PushStyleColorImVec4(.Button, {0.16, 0.62, 0.34, 0.95} if is_add else {0.82, 0.22, 0.20, 0.95})
	if im.Button("+ Add Solid (X)" if is_add else "- Cut Boolean Hole (X)", {avail_w, 24}) {
		_ed.brush_op = .Subtract if is_add else .Add
	}
	widgets.tooltip("Toggle whether new CSG brushes add solid geometry or cut holes (X)")
	im.PopStyleColor(1)

	im.Separator()
	switch _ed.sub_tool {
	case .Spline_Poly_Sketch: draw_spline_tool_right_click_settings()
	case .Box_Primitive:      draw_box_tool_right_click_settings()
	case .Face_Push_Pull:     draw_extrude_tool_right_click_settings()
	case .Geo_Mod_Blast:      draw_blast_tool_right_click_settings()
	case .Clip_Brush_Plane:   draw_clip_plane_tool_right_click_settings()
	case .Soft_Deform_Brush:  draw_soft_deform_tool_right_click_settings()
	case .Draw_Glass_Poly:
	}

	// Quick RealtimeCSG TexGen UV Inspector when a CSG brush is selected
	if vol_tex, _ := _resolve_active_volume(false); vol_tex != nil && _ed.selected_brush_idx >= 0 && _ed.selected_brush_idx < len(vol_tex.brushes) {
		sb := &vol_tex.brushes[_ed.selected_brush_idx]
		im.Separator()
		im.TextColoredUnformatted({0.95, 0.85, 0.35, 1.0}, fmt.ctprintf("Brush TexGen UV (%s):", sb.name))
		tex_dirty := false
		if im.Checkbox("Brush-Locked UVs (No Swim)", &sb.uv_lock_brush) do tex_dirty = true
		if sb.uv_scale <= 0.001 do sb.uv_scale = 0.5
		im.SetNextItemWidth(avail_w - 75)
		if im.SliderFloat("UV Scale", &sb.uv_scale, 0.05, 4.0, "%.2f") do tex_dirty = true
		im.SetNextItemWidth(avail_w - 75)
		if im.DragFloat2("UV Offset", &sb.uv_offset, 0.02, -10.0, 10.0, "%.2f") do tex_dirty = true
		im.SetNextItemWidth(avail_w - 75)
		if im.SliderFloat("UV Rot", &sb.uv_rot_deg, -180.0, 180.0, "%.0f deg") do tex_dirty = true
		if tex_dirty {
			csg_history_ensure_baseline(vol_tex)
			half_r := max(sb.size.x, max(sb.size.y, sb.size.z)) * 0.75 + 0.5
			_ = cad_csg.csg_volume_rebuild_dirty_aabb(vol_tex, sb.center - [3]f32{half_r, half_r, half_r}, sb.center + [3]f32{half_r, half_r, half_r})
			csg_history_commit(vol_tex)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
}

// ============================================================================
// CSG DRAWER 2: `2.Booleans` — UNREAL-STYLE MULTI-CSG BOOLEANS (`Ctrl + Click`)
// ============================================================================

@(private = "file")
_draw_csg_drawer_booleans :: proc(avail_w, half_w, third_w: f32) {
	im.TextColored({1.0, 0.85, 0.30, 1.0}, "Drawer 2: Multi-CSG Booleans (A & B)")
	im.TextColored({0.55, 0.95, 0.75, 1.0}, "Scene3D Q/E/R moves CSG objects; Ctrl+Click selects 2+!")

	if _ed.tool_active {
		if im.Button("Switch to Q/E/R Select & Move Mode", {avail_w, 23}) {
			deactivate_cad_tool()
		}
	}

	// Quick Spawners for Separate Independent CSGVolume Objects so user can position & boolean them
	im.SeparatorText("Spawn Independent CSG Volume Objects")
	if im.Button("+ CSG Box", {third_w, 22}) {
		spawn_separate_csg_primitive_volume(.Box, _mesh_ed.shape_dims, {0, 1.0, 0})
	}
	widgets.tooltip("Spawns a separate movable CSGVolume Box object so you can move it with Q/E/R and Ctrl+Click boolean it with another CSGVolume!")
	im.SameLine(0, 4)
	if im.Button("+ CSG Cyl", {third_w, 22}) {
		spawn_separate_csg_primitive_volume(.Cylinder, _mesh_ed.shape_dims, {0.8, 1.0, 0})
	}
	widgets.tooltip("Spawns a separate movable CSGVolume Cylinder object")
	im.SameLine(0, 4)
	if im.Button("+ CSG Wedge", {third_w, 22}) {
		spawn_separate_csg_primitive_volume(.Wedge, _mesh_ed.shape_dims, {-0.8, 1.0, 0})
	}
	widgets.tooltip("Spawns a separate movable CSGVolume Wedge/Ramp object")

	if vol_sp, _ := _resolve_active_volume(false); vol_sp != nil && len(vol_sp.brushes) > 1 {
		if im.Button(fmt.ctprintf("Split %d Brushes -> Separate CSG Volumes", len(vol_sp.brushes)), {avail_w, 22}) {
			csg_history_ensure_baseline(vol_sp)
			_ = cad_csg.csg_split_all_brushes_to_volumes(vol_sp, false)
			_ed.selected_brush_idx = 0
			deactivate_cad_tool()
		}
		widgets.tooltip("Splits every brush inside this CSGVolume into its own separate selectable CSGVolume GameObject so you can Ctrl+Click and boolean them!")
	}

	im.SeparatorText("Unreal Multi-CSG Booleans (Ctrl+Click)")
	w_b := engine.ctx_world()
	all_sel := engine.inspector_selection_all()
	sel_vols := make([dynamic]engine.Transform_Handle, 0, len(all_sel), context.temp_allocator)
	if w_b != nil {
		for sh in all_sel {
			if sh == {} || !engine.pool_valid(&w_b.transforms, engine.Handle(sh)) do continue
			_, csg_p := engine.transform_get_comp(sh, cad_csg.CSGVolume)
			_, mf_p  := engine.transform_get_comp(sh, engine.MeshFilter)
			_, adm_p := engine.transform_get_comp(sh, control_rig.ArmatureDeformedMesh)
			if csg_p != nil || mf_p != nil || adm_p != nil {
				append(&sel_vols, sh)
			}
		}
	}

	target_h: engine.Transform_Handle = {}
	tool_h:   engine.Transform_Handle = {}
	extra_tools := make([dynamic]engine.Transform_Handle, 0, 4, context.temp_allocator)

	// Prefer the first selected object that has a CSGVolume as Target CSG A
	if len(sel_vols) >= 1 {
		for sv in sel_vols {
			if _, csg_v := engine.transform_get_comp(sv, cad_csg.CSGVolume); csg_v != nil && csg_v.enabled {
				target_h = sv
				break
			}
		}
		if target_h == {} do target_h = sel_vols[0]
		for sv in sel_vols {
			if sv == target_h do continue
			if tool_h == {} {
				tool_h = sv
			} else {
				append(&extra_tools, sv)
			}
		}
	} else if _, owner_a := _resolve_active_volume(false); owner_a != {} {
		target_h = owner_a
	}
	if tool_h == {} && _mesh_ed.bool_target_b != {} && _mesh_ed.bool_target_b != target_h &&
	   w_b != nil && engine.pool_valid(&w_b.transforms, engine.Handle(_mesh_ed.bool_target_b)) {
		tool_h = _mesh_ed.bool_target_b
	}

	target_name := "(Select a CSG Volume)"
	if w_b != nil && target_h != {} {
		if t := engine.pool_get(&w_b.transforms, engine.Handle(target_h)); t != nil && len(t.name) > 0 {
			target_name = t.name
		}
	}
	tool_name := "(None - Ctrl+Click in Scene3D)"
	if w_b != nil && tool_h != {} {
		if t := engine.pool_get(&w_b.transforms, engine.Handle(tool_h)); t != nil && len(t.name) > 0 {
			tool_name = t.name
		}
	}

	im.TextColoredUnformatted({0.25, 0.95, 0.45, 1.0}, fmt.ctprintf("Target (CSG A): %s", target_name))
	if tool_h != {} {
		extra_lbl := ""
		if len(extra_tools) > 0 do extra_lbl = fmt.tprintf(" (+ %d more)", len(extra_tools))
		im.TextColoredUnformatted({0.35, 0.85, 1.0, 1.0}, fmt.ctprintf("Tool(s) (CSG/Mesh B): %s%s", tool_name, extra_lbl))
		if im.Button("Swap (A <-> B)##csg_swap", {-1, 22}) {
			// Reorder selection so `tool_h` becomes Target A and `target_h` becomes Tool B
			engine.inspector_request_select(tool_h)
			_mesh_ed.bool_target_b = target_h
		}
		widgets.tooltip("Swaps Target CSG A and Tool CSG B")
	} else {
		im.TextColored({0.95, 0.85, 0.35, 1.0}, "Hold Ctrl + Click a 2nd CSG/Mesh in Scene3D!")
	}

	im.Checkbox("Delete Tool B After Boolean##csg_consume", &_mesh_ed.bool_consume_tools)
	widgets.tooltip("When checked (default), Tool B is deleted after joining/subtracting so it never lingers inside carved holes. Uncheck when stamping one cutter into multiple walls!")

	has_both := target_h != {} && tool_h != {}
	if !has_both do im.BeginDisabled()
	im.PushStyleColorImVec4(.Button, {0.14, 0.52, 0.48, 0.98})
	if im.Button("Join Brushes into CSG A (Keep Editable Stack)##csg", {avail_w, 25}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		if _, vol_a := engine.transform_get_comp(target_h, cad_csg.CSGVolume); vol_a != nil {
			csg_history_ensure_baseline(vol_a)
			if cad_csg.csg_merge_volumes_non_destructive(target_h, all_tools[:], false, _mesh_ed.bool_consume_tools) {
				csg_history_commit(vol_a)
				if _mesh_ed.bool_consume_tools {
					_mesh_ed.bool_target_b = {}
					_mesh_ed.csg_bool_target_b = {}
				}
			}
		}
	}
	im.PopStyleColor(1)
	widgets.tooltip("Non-destructively transfers all parametric brushes from Tool CSG B into Target CSG A's Brush Stack in world space!")

	im.PushStyleColorImVec4(.Button, {0.18, 0.62, 0.38, 0.98})
	if im.Button("A + B (Union)##csg", {third_w, 26}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		csg_op_boolean_multi(target_h, all_tools[:], 0, _mesh_ed.bool_consume_tools)
	}
	im.PopStyleColor(1)
	widgets.tooltip("CSG Boolean Union (A + B): Combines Target CSG A and Tool B in world space!")

	im.SameLine(0, 4)
	im.PushStyleColorImVec4(.Button, {0.84, 0.32, 0.22, 0.98})
	if im.Button("A - B (Subtract)##csg", {third_w, 26}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		csg_op_boolean_multi(target_h, all_tools[:], 1, _mesh_ed.bool_consume_tools)
	}
	im.PopStyleColor(1)
	widgets.tooltip("CSG Boolean Subtract (A - B): Carves Tool B out of Target CSG A in world space!")

	im.SameLine(0, 4)
	im.PushStyleColorImVec4(.Button, {0.35, 0.52, 0.88, 0.98})
	if im.Button("A & B (Intersect)##csg", {third_w, 26}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		csg_op_boolean_multi(target_h, all_tools[:], 2, _mesh_ed.bool_consume_tools)
	}
	im.PopStyleColor(1)
	widgets.tooltip("CSG Boolean Intersection (A & B): Keeps only the overlapping volume shared by Target CSG A and Tool B!")
	if !has_both do im.EndDisabled()

	im.TextDisabled("Tip: Right-click in Scene3D with 2+ CSG/Mesh objects selected for quick Booleans!")
}

// ============================================================================
// CSG DRAWER 3: `3.Prefabs` — PARAMETRIC PREFABS, ARCHITECTURAL DETAILS & SEE-THROUGH GLASS
// (Replaces confusing "Kitbash" with clear Parametric Architectural Prefabs & Live Controls!)
// ============================================================================

// Spawns a Parametric Architectural Prefab into the active (or newly created) `CSGVolume`,
// recording its brush & glass IDs so dragging sliders in Drawer 3 live-updates the spawned prefab!
spawn_parametric_csg_prefab :: proc(kind: int) {
	_ensure_init()
	vol, owner := _resolve_active_volume(create_if_missing = true)
	if vol == nil || owner == {} do return
	csg_history_ensure_baseline(vol)

	vol.material_preset = _ed.prefab_material
	mat_row := cad_csg.csg_get_material_properties(_ed.prefab_material)
	col_u8  := mat_row.base_color

	w_sz := [3]f32{
		max(_ed.prefab_wall_size.x, 1.5),
		max(_ed.prefab_wall_size.y, 1.5),
		max(_ed.prefab_wall_size.z, 0.20),
	}
	op_sz := [2]f32{
		clamp(_ed.prefab_opening_size.x, 0.5, w_sz.x - 0.4),
		clamp(_ed.prefab_opening_size.y, 0.5, w_sz.y - 0.3),
	}
	sill_h := clamp(_ed.prefab_sill_height, 0.0, max(w_sz.y - op_sz.y - 0.1, 0.0))

	_ed.last_prefab_vol      = owner
	_ed.last_prefab_wall_id  = 0
	_ed.last_prefab_cut_id   = 0
	_ed.last_prefab_glass_id = 0

	switch kind {
	case 0: // Wall + Window Cutout + See-Through Glass Pane
		wall_center := [3]f32{0, w_sz.y * 0.5, 0}
		w_idx := cad_csg.csg_volume_add_brush(vol, "Prefab_Wall", .Add, .Box, wall_center, w_sz, 0, col_u8, true, true)
		if w_idx >= 0 && w_idx < len(vol.brushes) {
			_ed.last_prefab_wall_id = vol.brushes[w_idx].id
			_ed.selected_brush_idx  = w_idx
		}
		win_center := [3]f32{0, sill_h + op_sz.y * 0.5, 0}
		cut_idx, gp_idx := cad_csg.csg_volume_add_window_cutout_with_glass(
			vol, "Window", win_center, op_sz, {0, 0, 1}, w_sz.z,
			_ed.glass_cells_x, _ed.glass_cells_y, _ed.glass_material,
		)
		if cut_idx >= 0 && cut_idx < len(vol.brushes) {
			_ed.last_prefab_cut_id = vol.brushes[cut_idx].id
		}
		if gp_idx >= 0 && gp_idx < len(vol.glass_panes) {
			_ed.last_prefab_glass_id = vol.glass_panes[gp_idx].id
			_ed.selected_glass_idx   = gp_idx
		}

	case 1: // Wall + Doorway Cutout
		wall_center := [3]f32{0, w_sz.y * 0.5, 0}
		w_idx := cad_csg.csg_volume_add_brush(vol, "Prefab_Door_Wall", .Add, .Box, wall_center, w_sz, 0, col_u8, true, true)
		if w_idx >= 0 && w_idx < len(vol.brushes) {
			_ed.last_prefab_wall_id = vol.brushes[w_idx].id
			_ed.selected_brush_idx  = w_idx
		}
		door_h := min(max(op_sz.y, 2.1), w_sz.y - 0.25)
		door_w := min(max(op_sz.x, 1.2), w_sz.x - 0.4)
		cut_idx := cad_csg.csg_volume_add_brush(
			vol, "Prefab_Door_Cutout", .Subtract, .Box,
			{0, door_h * 0.5 - 0.02, 0}, {door_w, door_h + 0.04, w_sz.z + 0.28}, 0,
			mat_row.scorch_color, true, false,
		)
		if cut_idx >= 0 && cut_idx < len(vol.brushes) {
			_ed.last_prefab_cut_id = vol.brushes[cut_idx].id
		}
		cad_csg.csg_volume_rebuild(vol)

	case 2: // Bunker Room (Floor + Roof + 4 Walls + Front Doorway + Window with See-Through Glass!)
		rx := max(w_sz.x, 5.0)
		ry := max(w_sz.y, 3.2)
		rz := max(w_sz.x * 0.85, 4.5)
		t  := max(w_sz.z, 0.40)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_Floor", .Add, .Box, {0, -t * 0.5, 0}, {rx + 0.5, t, rz + 0.5}, 0, col_u8, false, true)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_Roof",  .Add, .Box, {0, ry + t * 0.5, 0}, {rx, t, rz}, 0, col_u8, true, false)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_North", .Add, .Box, {0, ry * 0.5, -rz * 0.5 + t * 0.5}, {rx, ry, t}, 0, col_u8, true, true)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_South", .Add, .Box, {0, ry * 0.5,  rz * 0.5 - t * 0.5}, {rx, ry, t}, 0, col_u8, true, true)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_East",  .Add, .Box, { rx * 0.5 - t * 0.5, ry * 0.5, 0}, {t, ry, rz - t * 2.0}, 0, col_u8, true, true)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_West",  .Add, .Box, {-rx * 0.5 + t * 0.5, ry * 0.5, 0}, {t, ry, rz - t * 2.0}, 0, col_u8, true, true)
		// Front doorway on South wall (-X side) + Window with See-Through Glass on South wall (+X side)
		_ = cad_csg.csg_volume_add_brush(vol, "Bunker_Door_Cut", .Subtract, .Box, {-rx * 0.22, 1.05, rz * 0.5 - t * 0.5}, {1.35, 2.15, t + 0.30}, 0, mat_row.scorch_color, true, false)
		_, gp_idx := cad_csg.csg_volume_add_window_cutout_with_glass(
			vol, "Bunker_Window", {rx * 0.20, sill_h + op_sz.y * 0.5, rz * 0.5 - t * 0.5},
			op_sz, {0, 0, 1}, t, _ed.glass_cells_x, _ed.glass_cells_y, _ed.glass_material,
		)
		_ed.selected_glass_idx = gp_idx

	case 3: // Stepped CSG Staircase (6 steps)
		steps := 6
		step_w := max(w_sz.x * 0.45, 2.0)
		tot_h  := max(w_sz.y, 2.4)
		tot_d  := max(w_sz.x * 0.65, 3.6)
		sh     := tot_h / f32(steps)
		sd     := tot_d / f32(steps)
		for i in 0 ..< steps {
			cur_h := sh * f32(i + 1)
			cz    := -tot_d * 0.5 + sd * (f32(i) + 0.5)
			_ = cad_csg.csg_volume_add_brush(
				vol, fmt.tprintf("Stair_Step_%d", i + 1), .Add, .Box,
				{0, cur_h * 0.5, cz}, {step_w, cur_h, sd}, 0, col_u8, true, i == 0,
			)
		}
		cad_csg.csg_volume_rebuild(vol)
	}

	csg_history_commit(vol)
	engine.inspector_request_select(owner)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Live-updates the last-spawned Wall + Window/Door Prefab when the user drags the Prefab sliders!
@(private = "file")
_sync_last_spawned_prefab :: proc(vol: ^cad_csg.CSGVolume) {
	if vol == nil || _ed.last_prefab_vol != engine.Transform_Handle(vol.owner) do return
	changed := false
	w_sz := [3]f32{
		max(_ed.prefab_wall_size.x, 1.5),
		max(_ed.prefab_wall_size.y, 1.5),
		max(_ed.prefab_wall_size.z, 0.20),
	}
	op_sz := [2]f32{
		clamp(_ed.prefab_opening_size.x, 0.5, w_sz.x - 0.4),
		clamp(_ed.prefab_opening_size.y, 0.5, w_sz.y - 0.3),
	}
	sill_h := clamp(_ed.prefab_sill_height, 0.0, max(w_sz.y - op_sz.y - 0.1, 0.0))

	if _ed.last_prefab_wall_id != 0 {
		for &b in vol.brushes {
			if b.id == _ed.last_prefab_wall_id {
				b.size   = w_sz
				b.center.y = w_sz.y * 0.5
				changed = true
				break
			}
		}
	}
	if _ed.last_prefab_glass_id != 0 {
		for &gp in vol.glass_panes {
			if gp.id == _ed.last_prefab_glass_id {
				gp.size_2d  = op_sz
				gp.center.y = sill_h + op_sz.y * 0.5
				gp.material_preset = _ed.glass_material
				_ = cad_csg.csg_sync_glass_pane_paired_cutout(vol, &gp)
				changed = true
				break
			}
		}
	} else if _ed.last_prefab_cut_id != 0 {
		for &b in vol.brushes {
			if b.id == _ed.last_prefab_cut_id {
				b.size   = {op_sz.x, op_sz.y + 0.04, w_sz.z + 0.28}
				b.center.y = op_sz.y * 0.5 - 0.02
				changed = true
				break
			}
		}
	}
	if changed {
		cad_csg.csg_volume_rebuild(vol)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
}

@(private = "file")
_draw_csg_drawer_kitbash :: proc(avail_w, half_w: f32) {
	im.TextColored({0.25, 0.96, 0.65, 1.0}, "Drawer 3: Faker CSG (CSG Collider + Mesh Instance)")
	im.TextDisabled("Workflow: 1. Turn Mesh -> CSG  2. Attach Mesh Instance  3. Fit Scale/Rot/Pos")

	w := engine.ctx_world()
	sel_h := engine.inspector_active_selection()
	vol: ^cad_csg.CSGVolume = nil
	owner_h: engine.Transform_Handle = {}
	if w != nil && sel_h != {} && engine.pool_valid(&w.transforms, engine.Handle(sel_h)) {
		_, csg_sel := engine.transform_get_comp(sel_h, cad_csg.CSGVolume)
		if csg_sel != nil && csg_sel.enabled {
			vol     = csg_sel
			owner_h = sel_h
		}
	}
	if vol == nil {
		vol, owner_h = _resolve_active_volume(false)
	}

	// Check if the user currently has a Polygon Mesh or Posed Skeletal Rig selected instead of a CSGVolume
	is_poly_mesh_selected := false
	is_rig_selected       := false
	if w != nil && sel_h != {} && engine.pool_valid(&w.transforms, engine.Handle(sel_h)) {
		_, csg_c := engine.transform_get_comp(sel_h, cad_csg.CSGVolume)
		_, mf_c  := engine.transform_get_comp(sel_h, engine.MeshFilter)
		_, arm_c := engine.transform_get_comp(sel_h, control_rig.ArmatureDeformedMesh)
		if arm_c != nil && arm_c.enabled {
			is_rig_selected = true
		} else if t_node := engine.pool_get(&w.transforms, engine.Handle(sel_h)); t_node != nil {
			for ch_ref in t_node.children {
				ch_h := engine.Transform_Handle(ch_ref.handle)
				if _, arm_ch := engine.transform_get_comp(ch_h, control_rig.ArmatureDeformedMesh); arm_ch != nil && arm_ch.enabled {
					is_rig_selected = true
					break
				}
			}
		}
		if (csg_c == nil || !csg_c.enabled) && (mf_c != nil || is_rig_selected || (_mesh_ed.target_owner == sel_h && len(_mesh_ed.verts) > 0)) {
			is_poly_mesh_selected = true
		}
	}

	if is_poly_mesh_selected {
		im.Spacing()
		im.PushStyleColorImVec4(.Text, {1.0, 0.68, 0.25, 1.0})
		if is_rig_selected {
			im.TextWrapped("Selected object is a [SKELETAL RIG]. Freeze its current pose into a static/dynamic CSG Statue using Line Traces!")
		} else {
			im.TextWrapped("Selected object is a [POLY MESH]. Faker CSG only operates on a [CSG VOLUME]!")
		}
		im.PopStyleColor(1)
		_draw_csg_wrap_mode_selector(avail_w)
		im.PushStyleColorImVec4(.Button, {0.84, 0.48, 0.14, 0.98})
		btn_lbl: cstring = "Step 1: Freeze Posed Rig -> CSG Statue Volume" if is_rig_selected else "Step 1: Convert Selected Mesh -> Multi-Hull CSG Volume"
		if im.Button(btn_lbl, {avail_w, 28}) {
			if !is_rig_selected {
				_sync_mesh_editor_with_selection()
			}
			conv_h := convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
			if conv_h != {} {
				_mesh_ed.active_csg_drawer = .Kitbash_Glass
				engine.inspector_request_select(conv_h)
			}
		}
		im.PopStyleColor(1)
		widgets.tooltip("Uses the selected CSG Wrap Mode (Exact Face Decompose or Multi-Angle Line Traces) to turn your Mesh or Posed Skeletal Rig into a destructible CSGVolume + Faker CSG!")
		im.Separator()
	}

	if vol == nil {
		im.TextColored({1.0, 0.75, 0.35, 1.0}, "Select or create a [CSG VOLUME] in Scene3D to convert it into a Faker CSG.")
		return
	}

	// If this CSGVolume was converted from a Mesh or Posed Skeletal Rig, let the user test all 4 Wrap Modes back-to-back or Undo in 1 click!
	if can_revert_or_rewrap_csg_mesh(owner_h) {
		im.SeparatorText("Compare CSG Wrap Methods / Undo to Mesh")
		_draw_csg_wrap_mode_selector(avail_w)
		if widgets.button_colored("Re-Wrap CSG with Selected Method", {0.18, 0.56, 0.82, 0.98}, {half_w, 25}) {
			_ = convert_editable_mesh_to_csg(make_dynamic_physics = vol.is_dynamic_rigidbody, append_to_active_volume = false)
		}
		widgets.tooltip("Re-runs Mesh -> CSG conversion in-place on the original source mesh using the newly selected CSG Wrap Mode so you can compare all 4 methods!")
		im.SameLine(0, 4)
		if widgets.button_colored("Undo: Revert to Mesh", {0.82, 0.36, 0.16, 0.98}, {half_w, 25}) {
			if revert_csg_to_original_mesh(owner_h) {
				return
			}
		}
		widgets.tooltip("Undoes the Mesh -> CSG conversion and restores the original MeshFilter + MeshRenderer (or Posed Skeletal Rig)!")
	}

	// ------------------------------------------------------------------------
	// STEP A: ATTACH / SELECT OR DRAG-AND-DROP MESH INSTANCE INTO THIS CSG VOLUME
	// ------------------------------------------------------------------------
	im.SeparatorText("1. Attach Mesh Instance into CSG Volume")

	// Drag-and-Drop Target Slot (accepts `.glb`, `.gltf`, `.obj`, `.fmesh` from Void File Explorer!)
	drop_lbl: cstring = "[ Drop Mesh (.glb / .obj / .fmesh) from Void Explorer Here ]"
	if vol.is_faker_mesh && !engine.asset_guid_is_empty(vol.faker_mesh_guid) {
		if m_path, pok := engine.asset_db_get_path(auto_cast vol.faker_mesh_guid); pok && len(m_path) > 0 {
			drop_lbl = fmt.ctprintf("Instance: %s (Drop to Replace)", m_path)
		} else {
			drop_lbl = fmt.ctprintf("Instance: Mesh GUID 0x%X (Drop to Replace)", vol.faker_mesh_guid)
		}
	}
	im.PushStyleColorImVec4(.Button, {0.14, 0.48, 0.38, 0.95} if vol.is_faker_mesh else {0.18, 0.30, 0.42, 0.95})
	im.PushStyleColorImVec4(.ButtonHovered, {0.20, 0.62, 0.48, 1.00})
	_ = im.Button(drop_lbl, {avail_w, 30})
	im.PopStyleColor(2)
	widgets.tooltip("Drag any .glb, .gltf, .obj, or .fmesh asset card from the Void File Explorer and drop it here to attach it as the GPU Mesh Instance inside this CSGVolume!")

	if im.BeginDragDropTarget() {
		if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
			raw_bytes := ([^]u8)(payload.Data)[:payload.DataSize]
			dropped_str := strings.trim_right_null(string(raw_bytes))
			ext_lo := strings.to_lower(dropped_str, context.temp_allocator)
			if strings.has_suffix(ext_lo, ".fmesh") {
				bh := cad_csg.csg_spawn_faker_mesh_from_binary(engine.transform_world(owner_h).position, dropped_str)
				if bh != {} do engine.inspector_request_select(bh)
			} else if strings.has_suffix(ext_lo, ".glb") || strings.has_suffix(ext_lo, ".gltf") || strings.has_suffix(ext_lo, ".obj") {
				rel_p := dropped_str
				if len(engine.asset_db.root_path) > 0 {
					root_norm, _ := strings.replace_all(engine.asset_db.root_path, "\\", "/", context.temp_allocator)
					drop_norm, _ := strings.replace_all(dropped_str, "\\", "/", context.temp_allocator)
					if strings.has_prefix(drop_norm, root_norm) {
						rel_p = strings.trim_left(drop_norm[len(root_norm):], "/")
					}
				}
				engine.asset_db_request_refresh()
				if disk_id, g_ok := engine.asset_db_get_guid(rel_p); g_ok {
					csg_history_ensure_baseline(vol)
					_ = cad_csg.csg_attach_mesh_instance_to_csg(vol, engine.Asset_GUID(disk_id), {}, auto_fit = true)
					csg_history_commit(vol)
				}
			}
		}
		im.EndDragDropTarget()
	}

	// Dropdown Picker to select any Mesh from `assets/meshes/` or any Scene `MeshFilter`
	picker_preview: cstring = "Select Mesh Asset or Scene Mesh..."
	if !engine.asset_guid_is_empty(vol.faker_mesh_guid) {
		if p_str, pok := engine.asset_db_get_path(auto_cast vol.faker_mesh_guid); pok && len(p_str) > 0 {
			picker_preview = strings.clone_to_cstring(p_str, context.temp_allocator)
		} else {
			picker_preview = fmt.ctprintf("Attached Mesh (0x%X)", vol.faker_mesh_guid)
		}
	}
	im.SetNextItemWidth(avail_w)
	if im.BeginCombo("##faker_mesh_picker", picker_preview) {
		// 1. Source mesh on this entity (if converted from Mesh -> CSG)
		if owner_h != {} {
			if _, mf_self := engine.transform_get_comp(owner_h, engine.MeshFilter); mf_self != nil && !engine.asset_guid_is_empty(mf_self.mesh.guid) {
				is_cur := (vol.faker_mesh_guid == mf_self.mesh.guid && vol.is_faker_mesh)
				if im.Selectable("[This Object's Original Source Mesh]", is_cur) {
					csg_history_ensure_baseline(vol)
					_ = cad_csg.csg_attach_mesh_instance_to_csg(vol, mf_self.mesh.guid, {}, auto_fit = false)
					csg_history_commit(vol)
				}
			}
		}
		// 2. Any other MeshFilter object in the active scene
		if w != nil {
			mf_it := engine.pool_iterator(engine.mesh_filters(w))
			for mf_other, _ in engine.pool_next(&mf_it) {
				if engine.asset_guid_is_empty(mf_other.mesh.guid) do continue
				mh_owner := engine.Transform_Handle(mf_other.owner)
				m_name := "Scene Mesh"
				if tm := engine.pool_get(&w.transforms, engine.Handle(mh_owner)); tm != nil && len(tm.name) > 0 {
					m_name = tm.name
				}
				lbl_c := fmt.ctprintf("Scene Mesh: %s", m_name)
				if im.Selectable(lbl_c, vol.faker_mesh_guid == mf_other.mesh.guid && vol.is_faker_mesh) {
					mat_g: engine.Asset_GUID = {}
					if _, mr_o := engine.transform_get_comp(mh_owner, engine.MeshRenderer); mr_o != nil && len(mr_o.materials) > 0 {
						mat_g = mr_o.materials[0]
					}
					csg_history_ensure_baseline(vol)
					_ = cad_csg.csg_attach_mesh_instance_to_csg(vol, mf_other.mesh.guid, mat_g, auto_fit = true)
					csg_history_commit(vol)
				}
			}
		}
		// 3. Disk mesh files in `assets/meshes/`
		if dir_fd, d_err := os.open("assets/meshes"); d_err == nil {
			defer os.close(dir_fd)
			if fis, r_err := os.read_dir(dir_fd, -1, context.temp_allocator); r_err == nil {
				for fi in fis {
					if fi.type == .Directory do continue
					lo_n := strings.to_lower(fi.name, context.temp_allocator)
					if !strings.has_suffix(lo_n, ".glb") && !strings.has_suffix(lo_n, ".gltf") && !strings.has_suffix(lo_n, ".obj") {
						continue
					}
					rel_m := fmt.tprintf("assets/meshes/%s", fi.name)
					if disk_id, g_ok := engine.asset_db_get_guid(rel_m); g_ok {
						m_guid := engine.Asset_GUID(disk_id)
						if im.Selectable(fmt.ctprintf("Asset: %s", fi.name), vol.faker_mesh_guid == m_guid && vol.is_faker_mesh) {
							csg_history_ensure_baseline(vol)
							_ = cad_csg.csg_attach_mesh_instance_to_csg(vol, m_guid, {}, auto_fit = true)
							csg_history_commit(vol)
						}
					}
				}
			}
		}
		im.EndCombo()
	}

	// Quick 1-click button if this CSGVolume already has a stored `faker_mesh_guid` or `MeshFilter` on the same entity
	source_guid := vol.faker_mesh_guid
	if engine.asset_guid_is_empty(source_guid) && owner_h != {} {
		if _, mf_s := engine.transform_get_comp(owner_h, engine.MeshFilter); mf_s != nil {
			source_guid = mf_s.mesh.guid
		}
	}
	if !vol.is_faker_mesh && !engine.asset_guid_is_empty(source_guid) {
		im.PushStyleColorImVec4(.Button, {0.14, 0.68, 0.44, 0.98})
		if im.Button("Convert This CSG -> Faker CSG (Attach Source Mesh Instance)", {avail_w, 26}) {
			csg_history_ensure_baseline(vol)
			_ = cad_csg.csg_attach_mesh_instance_to_csg(vol, source_guid, {}, auto_fit = false)
			csg_history_commit(vol)
		}
		im.PopStyleColor(1)
		widgets.tooltip("Attaches the source 3D Mesh as a GPU Instance inside this CSGVolume and converts the volume into a [FAKER CSG]!")
	}

	// ------------------------------------------------------------------------
	// STEP B: FIT & TRANSFORM INNER MESH INSTANCE INSIDE CSG COLLIDER
	// ------------------------------------------------------------------------
	if vol.is_faker_mesh {
		im.SeparatorText("2. Fit Inner Mesh Instance Inside CSG")

		// 3D Viewport Gizmo toggle for moving/rotating/scaling the inner Mesh Instance inside the stationary CSG collider!
		giz_act := _ed.faker_edit_inner_instance_gizmo
		if giz_act do im.PushStyleColorImVec4(.Button, {0.88, 0.64, 0.12, 0.98})
		if im.Button(
			"3D Gizmo: Editing INNER MESH INSTANCE (W/E/R) [ON]" if giz_act else "Edit Inner Mesh Instance with 3D Gizmo (W/E/R)",
			{avail_w, 25},
		) {
			_ed.faker_edit_inner_instance_gizmo = !_ed.faker_edit_inner_instance_gizmo
			if _ed.faker_edit_inner_instance_gizmo {
				deactivate_cad_tool()
			}
		}
		if giz_act do im.PopStyleColor(1)
		widgets.tooltip("When enabled, Scene3D W (Move), E (Rotate), and R (Scale) gizmos transform ONLY the inner GPU Mesh Instance inside the stationary CSGVolume collider cage so you can fit it visually!")

		if im.Button("Auto-Fit Instance to CSG Bounds", {half_w, 23}) {
			csg_history_ensure_baseline(vol)
			cad_csg.csg_autofit_faker_mesh_to_volume(vol)
			csg_history_commit(vol)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Automatically centers and scales the inner Mesh Instance so its bounding box fits snugly inside the CSGVolume collider (minus CSG Margin)!")
		im.SameLine(0, 4)
		if im.Button("Reset Pos / Rot / Scale", {half_w, 23}) {
			vol.faker_mesh_offset  = {0, 0, 0}
			vol.faker_mesh_rot_deg = {0, 0, 0}
			vol.faker_mesh_scale   = {1, 1, 1}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Resets the inner Mesh Instance offset to (0,0,0), rotation to (0,0,0), and scale to (1,1,1)")

		fm_changed := false
		im.SetNextItemWidth(avail_w - 88)
		if im.DragFloat3("Instance Pos", &vol.faker_mesh_offset, 0.01, -25.0, 25.0, "%.3f m") do fm_changed = true
		widgets.tooltip("Local X / Y / Z position offset of the inner GPU Mesh Instance relative to the CSGVolume collider")

		im.SetNextItemWidth(avail_w - 88)
		if im.DragFloat3("Instance Rot", &vol.faker_mesh_rot_deg, 0.5, -180.0, 180.0, "%.1f deg") do fm_changed = true
		widgets.tooltip("Local Pitch / Yaw / Roll rotation (degrees) of the inner GPU Mesh Instance inside the CSGVolume collider")

		im.SetNextItemWidth(avail_w - 88)
		if im.DragFloat3("Instance Scale", &vol.faker_mesh_scale, 0.01, 0.01, 50.0, "%.3f") do fm_changed = true
		widgets.tooltip("Local X / Y / Z scale of the inner GPU Mesh Instance inside the CSGVolume collider")

		uni_s := (vol.faker_mesh_scale.x + vol.faker_mesh_scale.y + vol.faker_mesh_scale.z) / 3.0
		im.SetNextItemWidth(avail_w - 88)
		if im.SliderFloat("Uniform Scale", &uni_s, 0.05, 5.0, "%.3fx") {
			vol.faker_mesh_scale = {uni_s, uni_s, uni_s}
			fm_changed = true
		}
		widgets.tooltip("Uniformly scales X, Y, and Z of the inner Mesh Instance together")

		im.SetNextItemWidth(avail_w - 88)
		if im.SliderFloat("Fit Margin (m)", &vol.faker_margin, 0.0, 0.25, "%.3f m") {
			fm_changed = true
		}
		widgets.tooltip("Clearance margin in meters between the outer CSG collider and the inner Mesh Instance when clicking Auto-Fit")

		if fm_changed {
			vol.gpu_dirty = true
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

		// Visibility & Deformation Rules
		im.SeparatorText("3. Faker CSG Shell & Deformation Rules")
		if im.Checkbox("Hide Outer CSG Shell (Show Inner Mesh Instance)", &vol.faker_hide_outer_shell) {
			vol.gpu_dirty = true
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("When checked, only the inner GPU Mesh Instance renders while the outer CSGVolume acts as an invisible physics/destruction collider. Uncheck to see the outer CSG shell in 3D!")

		if im.Checkbox("Render Cut CSG Interior When Sliced/Blasted", &vol.faker_render_cut_interior) {
			vol.gpu_dirty = true
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		if vol.faker_render_cut_interior {
			if _draw_cut_material_override_picker("faker_vol", &vol.faker_cut_material_guid, avail_w, "[Default Fallback: Same Texture as Mesh]") {
				vol.gpu_dirty = true
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
		}
		if im.Checkbox("Transfer Soft-Deform Dents to Inner Mesh", &vol.faker_transfer_dents) {
			vol.gpu_dirty = true
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		im.Checkbox("Split Faker CSG on 2-Point Clip Plane Slice", &vol.faker_split_on_slice)

		// Save / Spawn Binary `.fmesh` & Revert button
		obj_slug := "faker_object"
		if w != nil && owner_h != {} {
			if t_o := engine.pool_get(&w.transforms, engine.Handle(owner_h)); t_o != nil && len(t_o.name) > 0 {
				obj_slug = t_o.name
			}
		}
		fmesh_path := fmt.tprintf("assets/meshes/%s.fmesh", obj_slug)
		if im.Button(fmt.ctprintf("%s Save Binary .fmesh", icons.ICON_MD_SAVE), {half_w, 23}) {
			_ = cad_csg.csg_save_faker_mesh_binary(vol, fmesh_path)
		}
		widgets.tooltip(fmt.ctprintf("Saves this Faker CSG (inner Mesh Instance + outer CSG convex hulls) as '%s' (zero JSON!)", fmesh_path))
		im.SameLine(0, 4)
		if im.Button("+ Spawn .fmesh Copy", {half_w, 23}) {
			bh := cad_csg.csg_spawn_faker_mesh_from_binary(engine.transform_world(owner_h).position + {1.2, 0, 0}, fmesh_path)
			if bh != {} do engine.inspector_request_select(bh)
		}

		im.PushStyleColorImVec4(.Button, {0.68, 0.24, 0.20, 0.95})
		if im.Button("Detach Inner Mesh (Revert to Pure CSG Volume)", {avail_w, 22}) {
			vol.is_faker_mesh               = false
			vol.faker_hide_outer_shell      = false
			_ed.faker_edit_inner_instance_gizmo = false
			cad_csg.csg_volume_rebuild(vol)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		im.PopStyleColor(1)
	}

	// ------------------------------------------------------------------------
	// 3D POLYGON GLASS BUILDER (`Draw_Glass_Poly`, Key 7)
	// ------------------------------------------------------------------------
	im.Spacing()
	im.SeparatorText("3D Polygon Glass Loop Tool (Key: 7)")
	s7_act := _ed.tool_active && _ed.sub_tool == .Draw_Glass_Poly
	if s7_act do im.PushStyleColorImVec4(.Button, {0.16, 0.68, 0.78, 0.98})
	if im.Button("Draw 3D Glass Loop (Click Points -> Fill)", {avail_w, 25}) {
		toggle_cad_tool(.Draw_Glass_Poly)
	}
	if s7_act do im.PopStyleColor(1)
	widgets.tooltip("Click 3+ points in 3D space (with live CAD Ruler segment lengths), then click P0 or press Enter to fill the closed loop with see-through shatterable glass!")
	im.Checkbox("Auto-Carve Boolean Opening in Wall Behind Glass", &_ed.glass_draw_carve_wall)
}

// ============================================================================
// CSG DRAWER 4: `4.Bake/IO` — BAKE, SAVE & CONVERT CSG <-> MESH
// ============================================================================

@(private = "file")
_draw_csg_drawer_bake :: proc(avail_w, half_w: f32) {
	im.TextColored({0.45, 0.95, 0.65, 1.0}, "Drawer 4: Bake, Save & Convert CSG")
	if vol_act, act_h := _resolve_active_volume(false); vol_act != nil {
		if can_revert_or_rewrap_csg_mesh(act_h) {
			im.SeparatorText("Mesh -> CSG Wrap Switcher & Undo")
			_draw_csg_wrap_mode_selector(avail_w)
			if widgets.button_colored("Re-Wrap with Selected Method", {0.18, 0.56, 0.82, 0.98}, {half_w, 25}) {
				_ = convert_editable_mesh_to_csg(make_dynamic_physics = vol_act.is_dynamic_rigidbody, append_to_active_volume = false)
			}
			widgets.tooltip("Re-wraps the original source mesh using the selected CSG Wrap Mode so you can compare all 4 methods back-to-back!")
			im.SameLine(0, 4)
			if widgets.button_colored("Undo: Revert CSG -> Mesh", {0.82, 0.36, 0.16, 0.98}, {half_w, 25}) {
				if revert_csg_to_original_mesh(act_h) {
					return
				}
			}
			widgets.tooltip("Undoes the Mesh -> CSG conversion and restores the original MeshFilter + MeshRenderer (or Posed Skeletal Rig)!")
			im.Separator()
		}

		im.PushStyleColorImVec4(.Button, {0.18, 0.58, 0.36, 0.95})
		if im.Button("Bake & Save CSG Changes", {avail_w, 25}) {
			csg_history_ensure_baseline(vol_act)
			_ = cad_csg.csg_volume_bake_changes(vol_act)
			_ed.selected_brush_idx = -1
			csg_history_commit(vol_act)
			if sc := engine.sm_scene_get_active(); sc != nil && len(sc.path) > 0 {
				_ = engine.scene_save(sc, sc.path)
			}
		}
		im.PopStyleColor(1)
		widgets.tooltip("Bakes all CSG brushes, booleans, extrusions, and blasted craters into persistent convex hulls and saves the .scene file")

		im.PushStyleColorImVec4(.Button, {0.78, 0.46, 0.16, 0.98})
		if im.Button("Convert CSG -> Editable Mesh (Edit in Place)", {avail_w, 25}) {
			convert_active_csg_to_editable_mesh()
		}
		im.PopStyleColor(1)
		widgets.tooltip("Converts this CSGVolume in place into an Editable Polygon Mesh (preserving all tunnels/holes and dissolving chunk seams) and switches to Modeling / Mesh mode!")

		if im.Button("Bake CSG -> Static Mesh Copy", {half_w, 23}) {
			if mh := cad_csg.csg_volume_bake_to_static_mesh(vol_act); mh != {} {
				engine.inspector_request_select(mh)
			}
		}
		widgets.tooltip("Bakes a separate static MeshFilter + MeshRenderer copy of this CSGVolume")
		im.SameLine(0, 4)
		if im.Button("Smart Clean CSG", {half_w, 23}) {
			csg_history_ensure_baseline(vol_act)
			_ = cad_csg.csg_volume_smart_clean_and_simplify(vol_act)
			csg_history_commit(vol_act)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Removes sliver fragments, merges convex sibling hulls, and dissolves collinear seam vertices")
	} else {
		im.TextDisabled("Select a CSGVolume in Scene3D.")
	}

	im.Separator()
	if im.Button("Reset WorkPlane (Y=0)", {half_w, 22}) {
		_reset_workplane_to_ground()
	}
	im.SameLine(0, 4)
	if im.Button("Full CSG Panel", {half_w, 22}) {
		wnd.open("cad_csg_panel")
	}
}

// ============================================================================
// MESH DRAWER 1: `1.Shapes` — SPAWN EDITABLE SHAPES & 3D WIREFRAME SKETCH
// ============================================================================

@(private = "file")
_draw_mesh_drawer_shapes :: proc(avail_w, half_w, third_w: f32) {
	im.TextColored({0.45, 0.95, 0.72, 1.0}, "Drawer 1: Spawn Editable Shapes & Wireframe")

	if im.Button("+ Box", {third_w, 24})    do spawn_editable_cad_mesh(0)
	widgets.tooltip("Spawn an editable box mesh and select it for editing")
	im.SameLine(0, 4)
	if im.Button("+ Cyl", {third_w, 24})    do spawn_editable_cad_mesh(1)
	widgets.tooltip("Spawn an editable cylinder mesh and select it for editing")
	im.SameLine(0, 4)
	if im.Button("+ Sphere", {third_w, 24}) do spawn_editable_cad_mesh(5)
	widgets.tooltip("Spawn an editable UV sphere mesh and select it for editing")

	if im.Button("+ Cone", {third_w, 24})   do spawn_editable_cad_mesh(3)
	widgets.tooltip("Spawn an editable cone / pyramid mesh and select it for editing")
	im.SameLine(0, 4)
	if im.Button("+ Torus", {third_w, 24})  do spawn_editable_cad_mesh(6)
	widgets.tooltip("Spawn an editable torus (ring) mesh and select it for editing")
	im.SameLine(0, 4)
	if im.Button("+ Wedge", {third_w, 24})  do spawn_editable_cad_mesh(2)
	widgets.tooltip("Spawn an editable wedge / ramp mesh and select it for editing")

	if im.Button("+ Stairs", {third_w, 24}) do spawn_editable_cad_mesh(7)
	widgets.tooltip("Spawn an editable linear staircase mesh and select it for editing")
	im.SameLine(0, 4)
	im.PushStyleColorImVec4(.Button, {0.16, 0.58, 0.44, 0.95})
	if im.Button("+ Car Wireframe", {avail_w - third_w - 4.0, 24}) do spawn_editable_cad_mesh(8)
	im.PopStyleColor(1)
	widgets.tooltip("Spawns a 3D AutoCAD-style Car Wireframe Cage + Polygon Coupe Chassis")

	im.Spacing()
	im.SetNextItemWidth(avail_w - 80.0)
	im.DragFloat3("Shape Size", &_mesh_ed.shape_dims, 0.05, 0.1, 20.0, "%.2f m")
	widgets.tooltip("Width / Height / Depth (m) for newly spawned shapes")

	im.SetNextItemWidth(avail_w - 80.0)
	segs_i32 := i32(_mesh_ed.shape_subdivs)
	if im.SliderInt("Segments", &segs_i32, 3, 24) {
		_mesh_ed.shape_subdivs = int(segs_i32)
	}
	widgets.tooltip("Circumference segments for Cylinder / Sphere / Cone / Torus")

	im.SeparatorText("AutoCAD 3D Wireframe Sketch")
	wf_act := _mesh_ed.wire_draw_mode
	if wf_act do im.PushStyleColorImVec4(.Button, {0.16, 0.68, 0.50, 0.98})
	if im.Button("3D Wireframe Draw: ON" if wf_act else "3D Wireframe Sketch Mode", {half_w, 24}) {
		_mesh_ed.wire_draw_mode = !_mesh_ed.wire_draw_mode
		_mesh_ed.wire_last_vert = -1
		if _mesh_ed.wire_draw_mode && _mesh_ed.target_owner == {} {
			spawn_editable_cad_mesh(8)
		}
	}
	if wf_act do im.PopStyleColor(1)
	widgets.tooltip("Click points in 3D to sketch wireframe edges (RMB ends chain, X/Y/Z locks axis)")
	im.SameLine(0, 4)
	if im.Button("Skin Wire -> Faces", {half_w, 24}) {
		mesh_op_skin_wireframe_to_faces()
	}
	widgets.tooltip("Detects closed 3-edge and 4-edge wireframe loops and skins them into polygon faces")
}

// ============================================================================
// MESH DRAWER 2: `2.PolyEdit` — CONTEXT-SENSITIVE VERT / EDGE / FACE / OBJECT
// ============================================================================

@(private = "file")
_draw_mesh_drawer_poly_edit :: proc(avail_w, half_w, third_w, fourth_w: f32) {
	im.TextColored({0.45, 0.88, 1.0, 1.0}, "Drawer 2: Poly Edit ([1]Vert [2]Edge [3]Face)")

	sel_modes := [4]struct {
		mode: Mesh_Select_Mode,
		lbl:  cstring,
	}{
		{.Vertex, "[1] Vert"},
		{.Edge,   "[2] Edge"},
		{.Face,   "[3] Face"},
		{.Object, "[4] Object"},
	}
	for sm, i in sel_modes {
		if i > 0 do im.SameLine(0, 4)
		act := (_mesh_ed.select_mode == sm.mode)
		if act do im.PushStyleColorImVec4(.Button, {0.20, 0.58, 0.82, 0.98})
		if im.Button(sm.lbl, {fourth_w, 25}) {
			_mesh_ed.select_mode = sm.mode
			_mesh_ed.wire_draw_mode = false
			_clear_active_op()
		}
		if act do im.PopStyleColor(1)
	}

	if _mesh_ed.select_mode != .Object {
		modes := [3]struct {
			m:   Mesh_Xform_Mode,
			lbl: cstring,
		}{{.Move, "Move (Q/W)"}, {.Rotate, "Rotate (E)"}, {.Scale, "Scale (R)"}}
		for md, i in modes {
			if i > 0 do im.SameLine(0, 4)
			act := _mesh_ed.xform_mode == md.m && !_mesh_ed.pivot_edit
			if act do im.PushStyleColorImVec4(.Button, {0.20, 0.58, 0.82, 0.98})
			if im.Button(md.lbl, {third_w, 22}) {
				_mesh_ed.xform_mode = md.m
				_mesh_ed.pivot_edit = false
			}
			if act do im.PopStyleColor(1)
		}
		im.Checkbox("Local/Normal Gizmo", &_mesh_ed.local_gizmo_space)
		im.SameLine(0, 8)
		im.Checkbox("X-Ray (Alt+Z)", &_mesh_ed.xray_mode)
	}

	im.Separator()

	switch _mesh_ed.select_mode {
	case .Vertex:
		im.TextColoredUnformatted({1.0, 0.85, 0.30, 1.0}, fmt.ctprintf("Vertex Tools (%d selected):", len(_mesh_ed.selected_verts)))
		im.TextDisabled("Shift/Ctrl+Click 3+ verts -> Make Face (F)")

		can_make_face := len(_mesh_ed.selected_verts) >= 2
		if !can_make_face do im.BeginDisabled()
		im.PushStyleColorImVec4(.Button, {0.18, 0.62, 0.38, 0.98})
		if im.Button("Make Face / Fill (F)", {half_w, 25}) {
			mesh_op_make_face_from_selected_verts()
		}
		im.PopStyleColor(1)
		if !can_make_face do im.EndDisabled()
		widgets.tooltip("Select 3 or more vertices and click (or press F) to build a new polygon face!")

		im.SameLine(0, 4)
		if !can_make_face do im.BeginDisabled()
		if im.Button("Connect / Split (J)", {half_w, 25}) {
			mesh_op_connect_selected_verts()
		}
		if !can_make_face do im.EndDisabled()
		widgets.tooltip("Splits any face containing 2 selected vertices along the chord connecting them (Shortcut: J)")

		if im.Button("Weld Selected Verts", {half_w, 23}) {
			mesh_op_weld_vertices(_mesh_ed.weld_distance)
		}
		im.SameLine(0, 4)
		if im.Button("Dissolve Verts", {half_w, 23}) {
			mesh_op_dissolve_selected_verts()
		}
		im.SetNextItemWidth(avail_w - 85.0)
		im.SliderFloat("Weld Dist", &_mesh_ed.weld_distance, 0.001, 0.50, "%.3f m")
		if im.Button("Delete Selected Verts (Del)", {avail_w, 22}) {
			mesh_editor_delete_selection()
		}

	case .Edge:
		im.TextColored({1.0, 0.85, 0.30, 1.0}, "Edge Tools:")
		has_e := _mesh_ed.has_selected_edge
		if !has_e do im.BeginDisabled()
		im.PushStyleColorImVec4(.Button, {0.20, 0.56, 0.82, 0.98})
		if im.Button("Bevel Edge (B)", {half_w, 25}) {
			_begin_active_op(.Bevel_Edge)
			mesh_op_bevel_selected_edge(_mesh_ed.bevel_amount)
		}
		im.PopStyleColor(1)
		im.SameLine(0, 4)
		if im.Button("Extrude Edge (E)", {half_w, 25}) {
			_begin_active_op(.Extrude)
			mesh_op_extrude_selected(_mesh_ed.extrude_amount)
		}
		if im.Button("Split Edge Midpoint", {half_w, 23}) {
			_clear_active_op()
			mesh_op_subdivide_selected()
		}
		im.SameLine(0, 4)
		if im.Button("Close Edge Hole (F)", {half_w, 23}) {
			_clear_active_op()
			mesh_op_close_open_holes()
		}
		if !has_e do im.EndDisabled()

		im.SetNextItemWidth(avail_w - 90.0)
		if im.SliderFloat("Bevel Width", &_mesh_ed.bevel_amount, 0.04, 0.65, "%.2f") {
			if _mesh_ed.active_op == .Bevel_Edge do _reapply_active_op(commit = false)
		}
		if im.IsItemDeactivatedAfterEdit() && _mesh_ed.active_op == .Bevel_Edge {
			_reapply_active_op(commit = true)
		}

		im.SetNextItemWidth(avail_w - 90.0)
		if im.SliderFloat("Extrude Dist", &_mesh_ed.extrude_amount, -3.0, 3.0, "%.2f m") {
			if _mesh_ed.active_op == .Extrude do _reapply_active_op(commit = false)
		}
		if im.IsItemDeactivatedAfterEdit() && _mesh_ed.active_op == .Extrude {
			_reapply_active_op(commit = true)
		}

		im.TextColored({0.75, 0.90, 1.0, 1.0}, "Edge Loop Cut:")
		if im.Button("Loop Cut X", {third_w, 22}) { _begin_active_op(.Loop_Cut); _mesh_ed.op_loop_axis = 0; mesh_op_loop_cut(0, _mesh_ed.cut_plane_offset) }
		im.SameLine(0, 4)
		if im.Button("Loop Cut Y", {third_w, 22}) { _begin_active_op(.Loop_Cut); _mesh_ed.op_loop_axis = 1; mesh_op_loop_cut(1, _mesh_ed.cut_plane_offset) }
		im.SameLine(0, 4)
		if im.Button("Loop Cut Z", {third_w, 22}) { _begin_active_op(.Loop_Cut); _mesh_ed.op_loop_axis = 2; mesh_op_loop_cut(2, _mesh_ed.cut_plane_offset) }
		im.SetNextItemWidth(avail_w * 0.52)
		if im.SliderFloat("Loop Offset", &_mesh_ed.cut_plane_offset, -3.0, 3.0, "%.2f m") {
			if _mesh_ed.active_op == .Loop_Cut do _reapply_active_op(commit = false)
		}
		im.SameLine(0, 6)
		im.Checkbox("3D Plane", &_mesh_ed.show_cut_plane_preview)

		if has_e {
			if im.Button("Mark / Clear UV Seam (Orange)", {avail_w, 22}) do mesh_uv_toggle_selected_edge_seam()
			if im.Button("Delete Selected Edge (Del)", {avail_w, 22})   do mesh_editor_delete_selection()
		}

	case .Face:
		im.TextColored({1.0, 0.85, 0.30, 1.0}, "Face Tools (Gold Handle = +Extrude / -Tunnel):")
		has_f := _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces)

		if !has_f do im.BeginDisabled()
		im.PushStyleColorImVec4(.Button, {0.82, 0.56, 0.14, 0.98})
		if im.Button("Extrude (E)", {third_w, 25}) {
			_begin_active_op(.Extrude)
			mesh_op_extrude_selected(_mesh_ed.extrude_amount)
		}
		im.PopStyleColor(1)
		im.SameLine(0, 4)
		im.PushStyleColorImVec4(.Button, {0.16, 0.62, 0.74, 0.98})
		if im.Button("Inset (I)", {third_w, 25}) {
			_begin_active_op(.Inset)
			mesh_op_inset_selected_face(_mesh_ed.inset_amount)
		}
		im.PopStyleColor(1)
		im.SameLine(0, 4)
		im.PushStyleColorImVec4(.Button, {0.24, 0.54, 0.84, 0.98})
		if im.Button("Bevel (B)", {third_w, 25}) {
			_begin_active_op(.Bevel_Face)
			mesh_op_bevel_selected_face(_mesh_ed.bevel_amount, _mesh_ed.bevel_height)
		}
		im.PopStyleColor(1)

		if im.Button("Subdivide", {third_w, 22})   { _clear_active_op(); mesh_op_subdivide_selected() }
		im.SameLine(0, 4)
		if im.Button("Flip Normal", {third_w, 22}) { _clear_active_op(); mesh_op_flip_selected_face_normal() }
		im.SameLine(0, 4)
		if im.Button("Delete Face", {third_w, 22}) { mesh_editor_delete_selection() }
		if !has_f do im.EndDisabled()

		im.SetNextItemWidth(avail_w - 92.0)
		if im.SliderFloat("Extrude Dist", &_mesh_ed.extrude_amount, -3.0, 3.0, "%+.2f m") {
			if _mesh_ed.active_op == .Extrude do _reapply_active_op(commit = false)
		}
		if im.IsItemDeactivatedAfterEdit() && _mesh_ed.active_op == .Extrude do _reapply_active_op(commit = true)

		im.SetNextItemWidth(avail_w - 92.0)
		if im.SliderFloat("Inset Width", &_mesh_ed.inset_amount, 0.05, 0.80, "%.2f") {
			if _mesh_ed.active_op == .Inset do _reapply_active_op(commit = false)
		}
		if im.IsItemDeactivatedAfterEdit() && _mesh_ed.active_op == .Inset do _reapply_active_op(commit = true)

		im.SetNextItemWidth(avail_w - 92.0)
		if im.SliderFloat("Bevel Width", &_mesh_ed.bevel_amount, 0.04, 0.75, "%.2f") {
			if _mesh_ed.active_op == .Bevel_Face do _reapply_active_op(commit = false)
		}
		if im.IsItemDeactivatedAfterEdit() && _mesh_ed.active_op == .Bevel_Face do _reapply_active_op(commit = true)

		im.SetNextItemWidth(avail_w - 92.0)
		if im.SliderFloat("Bevel Height", &_mesh_ed.bevel_height, -1.0, 1.0, "%+.2f m") {
			if _mesh_ed.active_op == .Bevel_Face do _reapply_active_op(commit = false)
		}
		if im.IsItemDeactivatedAfterEdit() && _mesh_ed.active_op == .Bevel_Face do _reapply_active_op(commit = true)

	case .Object:
		im.TextColored({0.55, 0.95, 0.75, 1.0}, "Whole-Mesh Q/E/R Transform & Pivot:")
		piv := _mesh_ed.pivot_edit
		if piv do im.PushStyleColorImVec4(.Button, {0.78, 0.30, 0.74, 0.98})
		if im.Button("Edit Pivot / Origin: ON (O)" if piv else "Edit Pivot / Origin (O)", {avail_w, 23}) {
			_mesh_ed.pivot_edit = !_mesh_ed.pivot_edit
		}
		if piv do im.PopStyleColor(1)
		if im.Button("Origin->Center", {third_w, 22}) {
			if _, _, c, ok := _mesh_geometry_world_bounds(); ok do _mesh_set_origin_world(c)
		}
		im.SameLine(0, 4)
		if im.Button("Origin->Bottom", {third_w, 22}) {
			if lo, _, c, ok := _mesh_geometry_world_bounds(); ok do _mesh_set_origin_world({c.x, lo.y, c.z})
		}
		im.SameLine(0, 4)
		if im.Button("Mirror +X->-X", {third_w, 22}) {
			mesh_op_mirror_x()
		}
	}

	im.Spacing()
	im.PushStyleColorImVec4(.Button, {0.18, 0.56, 0.52, 0.96})
	if im.Button("Simplify / Clean Mesh (Reduce Pointless Verts)", {avail_w, 23}) {
		_clear_active_op()
		mesh_op_simplify_and_clean_mesh()
	}
	im.PopStyleColor(1)
}

// ============================================================================
// MESH DRAWER 3: `3.Booleans` — UNREAL-STYLE MULTI-MESH BOOLEANS (`Ctrl+Click`)
// ============================================================================

@(private = "file")
_draw_mesh_drawer_booleans :: proc(avail_w, half_w, third_w: f32) {
	im.TextColored({1.0, 0.85, 0.30, 1.0}, "Drawer 3: Multi-Mesh Booleans (A & B)")
	im.TextColored({0.55, 0.95, 0.75, 1.0}, "Scene3D Q/E/R moves meshes; Ctrl+Click selects 2+!")

	if _mesh_ed.select_mode != .Object {
		if im.Button("Switch to [4] Whole-Mesh Object Mode (Q/E/R)", {avail_w, 23}) {
			_mesh_ed.select_mode = .Object
			_mesh_ed.wire_draw_mode = false
		}
	}

	w_b := engine.ctx_world()
	all_sel := engine.inspector_selection_all()
	sel_meshes := make([dynamic]engine.Transform_Handle, 0, len(all_sel), context.temp_allocator)
	if w_b != nil {
		for sh in all_sel {
			if sh == {} || !engine.pool_valid(&w_b.transforms, engine.Handle(sh)) do continue
			_, mf_p  := engine.transform_get_comp(sh, engine.MeshFilter)
			_, csg_p := engine.transform_get_comp(sh, cad_csg.CSGVolume)
			_, adm_p := engine.transform_get_comp(sh, control_rig.ArmatureDeformedMesh)
			if mf_p != nil || csg_p != nil || adm_p != nil {
				append(&sel_meshes, sh)
			}
		}
	}

	target_h := _mesh_ed.target_owner
	tool_h: engine.Transform_Handle = {}
	extra_tools := make([dynamic]engine.Transform_Handle, 0, 4, context.temp_allocator)

	if len(sel_meshes) >= 2 {
		is_target_in_sel := false
		for sm in sel_meshes do if sm == target_h { is_target_in_sel = true; break }
		if !is_target_in_sel {
			target_h = sel_meshes[0]
		}
		for sm in sel_meshes {
			if sm == target_h do continue
			if tool_h == {} {
				tool_h = sm
			} else {
				append(&extra_tools, sm)
			}
		}
	} else if _mesh_ed.bool_target_b != {} && _mesh_ed.bool_target_b != target_h &&
	          w_b != nil && engine.pool_valid(&w_b.transforms, engine.Handle(_mesh_ed.bool_target_b)) {
		tool_h = _mesh_ed.bool_target_b
	}

	target_name := "Mesh A"
	if w_b != nil && target_h != {} {
		if t := engine.pool_get(&w_b.transforms, engine.Handle(target_h)); t != nil && len(t.name) > 0 {
			target_name = t.name
		}
	}
	tool_name := "(None - Ctrl+Click in Scene3D)"
	if w_b != nil && tool_h != {} {
		if t := engine.pool_get(&w_b.transforms, engine.Handle(tool_h)); t != nil && len(t.name) > 0 {
			tool_name = t.name
		}
	}

	im.TextColoredUnformatted({0.25, 0.95, 0.45, 1.0}, fmt.ctprintf("Target (Mesh A): %s", target_name))
	if tool_h != {} {
		extra_lbl := ""
		if len(extra_tools) > 0 do extra_lbl = fmt.tprintf(" (+ %d more)", len(extra_tools))
		im.TextColoredUnformatted({0.35, 0.85, 1.0, 1.0}, fmt.ctprintf("Tool(s) (Mesh B): %s%s", tool_name, extra_lbl))
		if im.Button("Swap (A <-> B)", {-1, 22}) {
			_mesh_ed.target_owner = {}
			engine.inspector_request_select(tool_h)
			_sync_mesh_editor_with_selection()
			_mesh_ed.bool_target_b = target_h
		}
		widgets.tooltip("Swaps Target Mesh A and Tool Mesh B")
	} else {
		im.TextColored({0.95, 0.85, 0.35, 1.0}, "Hold Ctrl + Click a 2nd mesh in Scene3D!")
	}

	im.Checkbox("Delete Tool B After Boolean##mesh_consume", &_mesh_ed.bool_consume_tools)
	widgets.tooltip("When checked (default), Tool Mesh B is deleted after joining/subtracting so it never blocks carved holes.")

	has_tools := (tool_h != {})
	if !has_tools do im.BeginDisabled()
	im.PushStyleColorImVec4(.Button, {0.18, 0.62, 0.38, 0.98})
	if im.Button("A + B (Union)", {third_w, 26}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		mesh_op_boolean_multi(target_h, all_tools[:], 0, _mesh_ed.bool_consume_tools)
	}
	im.PopStyleColor(1)
	widgets.tooltip("Boolean Union (A + B): Welds Target A and Tool B together in world space, removing internal intersecting faces!")

	im.SameLine(0, 4)
	im.PushStyleColorImVec4(.Button, {0.84, 0.32, 0.22, 0.98})
	if im.Button("A - B (Subtract)", {third_w, 26}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		mesh_op_boolean_multi(target_h, all_tools[:], 1, _mesh_ed.bool_consume_tools)
	}
	im.PopStyleColor(1)
	widgets.tooltip("Boolean Subtract / Difference (A - B): Carves Tool Mesh B out of Target Mesh A in world space!")

	im.SameLine(0, 4)
	im.PushStyleColorImVec4(.Button, {0.35, 0.52, 0.88, 0.98})
	if im.Button("A & B (Intersect)", {third_w, 26}) {
		all_tools := make([dynamic]engine.Transform_Handle, 0, len(extra_tools) + 1, context.temp_allocator)
		append(&all_tools, tool_h)
		append(&all_tools, ..extra_tools[:])
		mesh_op_boolean_multi(target_h, all_tools[:], 2, _mesh_ed.bool_consume_tools)
	}
	im.PopStyleColor(1)
	widgets.tooltip("Boolean Intersection (A & B): Keeps only the overlapping volume shared by Target A and Tool B!")
	if !has_tools do im.EndDisabled()

	im.TextDisabled("Tip: Right-click in Scene3D with 2+ Meshes/CSGs selected for quick Booleans!")

	im.SeparatorText("Plane Cut (PlnCut) & 3D Cutter Box")
	im.SetNextItemWidth(avail_w * 0.52)
	im.SliderFloat("Cut Offset", &_mesh_ed.cut_plane_offset, -3.0, 3.0, "%.2f m")
	im.SameLine(0, 6)
	im.Checkbox("3D Plane", &_mesh_ed.show_cut_plane_preview)
	if im.Button("PlnCut Y", {third_w, 22}) { _mesh_ed.cut_plane_axis = 1; mesh_op_plane_cut(1, _mesh_ed.cut_plane_offset, true) }
	im.SameLine(0, 4)
	if im.Button("PlnCut X", {third_w, 22}) { _mesh_ed.cut_plane_axis = 0; mesh_op_plane_cut(0, _mesh_ed.cut_plane_offset, true) }
	im.SameLine(0, 4)
	if im.Button("PlnCut Z", {third_w, 22}) { _mesh_ed.cut_plane_axis = 2; mesh_op_plane_cut(2, _mesh_ed.cut_plane_offset, true) }

	im.Checkbox("3D Cutter Box Gizmo (Enter = Cut)", &_mesh_ed.show_cutter_box_gizmo)
	if _mesh_ed.show_cutter_box_gizmo {
		if im.Button("-Cut Box", {half_w, 22}) do mesh_op_boolean_box(.Subtract)
		im.SameLine(0, 4)
		if im.Button("+Union Box", {half_w, 22}) do mesh_op_boolean_box(.Add)
	}
}

// ============================================================================
// MESH DRAWER 4: `4.UV Suite` — UV UNWRAPPER & 2D UV EDITOR WINDOW
// ============================================================================

@(private = "file")
_draw_mesh_drawer_uv_suite :: proc(avail_w, half_w, third_w: f32) {
	im.TextColored({0.35, 0.90, 1.0, 1.0}, "Drawer 4: UV Unwrapper & 2D UV Editor")

	im.PushStyleColorImVec4(.Button, {0.18, 0.55, 0.78, 0.98})
	if im.Button(fmt.ctprintf("%s Open 2D UV Editor Window", icons.ICON_MD_IMAGE), {avail_w, 28}) {
		open_uv_editor_window()
	}
	im.PopStyleColor(1)
	widgets.tooltip("Opens the interactive 2D UV Editor Window with texture backdrop, UV island selection, and vertex/face dragging!")

	im.SeparatorText("1-Click UV Projection & Unwrapping")
	if im.Button("Box Unwrap", {third_w, 24})   do mesh_uv_unwrap_box(1.0, fit_01 = true)
	widgets.tooltip("Cubic 6-axis box unwrap: projects every face onto its closest cardinal axis")
	im.SameLine(0, 4)
	if im.Button("Planar View", {third_w, 24})  do mesh_uv_unwrap_planar(3, 1.0, fit_01 = true)
	widgets.tooltip("Projects faces onto the normal/view plane")
	im.SameLine(0, 4)
	if im.Button("Auto-Islands", {third_w, 24}) do mesh_uv_auto_unwrap_islands(0.02)
	widgets.tooltip("Automatically segments faces by angle & seams into UV islands, flattens them, and packs into [0, 1]!")

	if im.Button("Cylinder", {third_w, 23})     do mesh_uv_unwrap_cylinder(1, fit_01 = true)
	im.SameLine(0, 4)
	if im.Button("Sphere", {third_w, 23})       do mesh_uv_unwrap_sphere(fit_01 = true)
	im.SameLine(0, 4)
	if im.Button("Pack Islands", {third_w, 23}) do mesh_uv_pack_islands(0.02)

	im.SeparatorText("UV Transform & Seams")
	if im.Button("Fit 0-1", {third_w, 22})      do mesh_uv_fit_01()
	im.SameLine(0, 4)
	if im.Button("Rot 90 deg", {third_w, 22})   do mesh_uv_rotate_90(true)
	im.SameLine(0, 4)
	if im.Button("Flip U", {third_w, 22})       do mesh_uv_flip(true, false)

	if im.Button("Flip V", {half_w, 22})        do mesh_uv_flip(false, true)
	im.SameLine(0, 4)
	if im.Button(fmt.ctprintf("Clear Seams (%d)", len(_mesh_ed.uv_seams)), {half_w, 22}) {
		mesh_uv_clear_all_seams()
	}
}

// ============================================================================
// MESH DRAWER 5: `5.Save/CSG` — SAVE TO DISK & MULTI-PASS MESH <-> CSG
// ============================================================================

@(private = "file")
_draw_mesh_drawer_convert :: proc(avail_w, half_w: f32) {
	im.TextColored({0.95, 0.85, 0.35, 1.0}, "Drawer 5: Save to Disk & Convert <-> CSG")
	if len(_mesh_ed.verts) == 0 {
		im.TextDisabled("Select any Mesh/CSG in Scene3D or spawn a shape in Drawer 1.")
		return
	}

	im.PushStyleColorImVec4(.Button, {0.20, 0.52, 0.78, 0.98})
	if im.Button(fmt.ctprintf("%s Save Mesh to Disk (.glb + .obj)", icons.ICON_MD_SAVE), {avail_w, 26}) {
		_, _ = mesh_op_save_to_disk()
	}
	im.PopStyleColor(1)
	widgets.tooltip("Writes this mesh to disk as 'assets/meshes/<Name>.glb' (glTF 2.0 binary) and '.obj', imports into AssetDB, and binds to MeshFilter!")
	if len(_mesh_ed.save_status) > 0 {
		im.TextColoredUnformatted({0.35, 0.98, 0.55, 1.0}, strings.clone_to_cstring(_mesh_ed.save_status, context.temp_allocator))
	}

	im.SeparatorText("Watertight Check & Multi-Pass Repair")
	if _mesh_ed.report_dirty {
		_evaluate_mesh_csg_compliance()
	}
	r := &_mesh_ed.report
	is_watertight_ready := r.has_valid_volume && r.open_boundary_edges == 0 && r.inverted_normal_faces == 0
	if is_watertight_ready {
		im.PushStyleColorImVec4(.Text, {0.28, 0.96, 0.48, 1.0})
		if r.concave_face_count == 0 {
			im.TextWrappedUnformatted(fmt.ctprintf("%s Watertight Convex Mesh (%dV, %dF)", icons.ICON_MD_CHECK, r.vert_count, r.face_count))
		} else {
			im.TextWrappedUnformatted(fmt.ctprintf("%s Watertight Concave / Tunnel Mesh (%dV, %dF) — Ready for Multi-Hull CSG!", icons.ICON_MD_CHECK, r.vert_count, r.face_count))
		}
		im.PopStyleColor(1)
	} else {
		im.PushStyleColorImVec4(.Text, {1.0, 0.52, 0.28, 1.0})
		im.TextWrappedUnformatted(fmt.ctprintf("%s Repair Needed (%d open edges, %d flipped):", icons.ICON_MD_WARNING, r.open_boundary_edges, r.inverted_normal_faces))
		im.PopStyleColor(1)
		if r.open_boundary_edges > 0 {
			if im.Button("Auto-Fix: Multi-Pass Stitch & Close Holes", {avail_w, 22}) {
				_stitch_and_miter_clean_coplanar_faces()
				_evaluate_mesh_csg_compliance()
				if _mesh_ed.report.open_boundary_edges > 0 {
					mesh_op_close_open_holes()
				}
				_rebuild_editable_mesh_gpu(commit = true)
			}
		}
		if r.inverted_normal_faces > 0 {
			if im.Button("Auto-Fix: Flip Normals Outward", {avail_w, 22}) do mesh_op_recalculate_outward_normals()
		}
	}

	im.Spacing()
	_draw_csg_wrap_mode_selector(avail_w)
	if can_revert_or_rewrap_csg_mesh() {
		im.PushStyleColorImVec4(.Button, {0.18, 0.56, 0.82, 0.98})
		if im.Button("Re-Wrap CSG with Selected Method", {half_w, 26}) {
			_ = convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = false)
		}
		im.PopStyleColor(1)
		widgets.tooltip("Re-runs Mesh -> CSG conversion using the newly selected CSG Wrap Mode so you can compare all 4 methods!")
		im.SameLine(0, 4)
		im.PushStyleColorImVec4(.Button, {0.82, 0.36, 0.16, 0.98})
		if im.Button("Undo: Revert CSG -> Mesh", {half_w, 26}) {
			_ = revert_csg_to_original_mesh()
		}
		im.PopStyleColor(1)
		widgets.tooltip("Undoes the Mesh -> CSG conversion and restores the original MeshFilter + MeshRenderer!")
	}
	im.PushStyleColorImVec4(.Button, {0.16, 0.64, 0.36, 0.98})
	if im.Button("Convert -> Multi-Hull Destructible CSG", {avail_w, 26}) {
		convert_complex_mesh_to_multihull_csg(make_dynamic_physics = false)
	}
	im.PopStyleColor(1)
	widgets.tooltip("Converts this mesh or posed rig into a destructible CSGVolume using the selected CSG Wrap Mode (Exact Face Decompose, Single Hull, Line-Trace Grid, or Anatomy Sliced Statue)!")

	if im.Button("-> Dynamic Physics CSG", {half_w, 23}) {
		convert_complex_mesh_to_multihull_csg(make_dynamic_physics = true)
	}
	im.SameLine(0, 4)
	if im.Button("-> Add to Active CSG", {half_w, 23}) {
		convert_editable_mesh_to_csg(make_dynamic_physics = false, append_to_active_volume = true)
	}
}

// ============================================================================
// PER-TOOL RIGHT-CLICK DROPDOWN SETTINGS CALLBACKS
// ============================================================================

draw_spline_tool_right_click_settings :: proc() {
	_ensure_init()
	im.Text("2D Spline / Polyline Sketch Settings:")
	im.Checkbox("Smooth Catmull-Rom Spline (C)", &_ed.sketch_next_smooth)
	widgets.tooltip("The next placed point is a smooth curve point instead of a sharp corner (C toggles)")
	im.Checkbox("Wall-Strip Corridor Mode (Open Line -> Thick Wall)", &_ed.spline_wall_strip)
	widgets.tooltip("Press Enter on 2+ open points to thicken the polyline into an architectural wall strip of exact thickness!")
	if _ed.spline_wall_strip {
		im.SetNextItemWidth(180)
		im.SliderFloat("Wall Thickness (m)", &_ed.spline_wall_thickness, 0.08, 3.0, "%.2f m")
		widgets.tooltip("Thickness in meters when extruding an open polyline wall strip")
	}
	im.Checkbox("Freehand Squiggly Stroke (Shift+Drag)", &_ed.sketch_freehand)
	widgets.tooltip("Drag to draw a continuous freehand curve instead of clicking point by point")
	im.SetNextItemWidth(180)
	im.SliderFloat("Curve Tension", &_ed.sketch_tension, 0.0, 0.85, "%.2f")
	widgets.tooltip("How tightly smooth points curve: 0 = round and loose, higher = tighter")
	im.SetNextItemWidth(180)
	im.SliderFloat("Default Extrude H", &_ed.extrude_height, -10.0, 10.0, "%.2f m")
	widgets.tooltip("Default height a sketch is extruded to (negative = downward)")
	im.Separator()
	im.Checkbox("True Anchor Polar Angle Snap", &_ed.axis_snap_enabled)
	widgets.tooltip("Projects angle rays strictly from your clicked anchor point (never snaps to world {0,0} before Point 1!). Hold Alt for momentary Free angle")
	if _ed.axis_snap_enabled {
		im.SetNextItemWidth(180)
		if im.BeginCombo("Polar Step (°)", fmt.ctprintf("%.0f deg", _ed.polar_step_deg)) {
			steps := [4]f32{15.0, 30.0, 45.0, 90.0}
			for st in steps {
				if im.Selectable(fmt.ctprintf("%.0f deg", st), abs(_ed.polar_step_deg - st) < 0.1) {
					_ed.polar_step_deg = st
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Angular protractor increment around your anchor point (15, 30, 45, or 90 degrees)")
		im.Checkbox("Polar Origin: First Point (P0) vs Last Vertex", &_ed.polar_origin_first_pt)
		widgets.tooltip("Unchecked = measure angle from the last placed segment vertex; Checked = measure radial angle from the very first clicked point (P0)")
	}
	im.Checkbox("Magnetic OSNAP (Vertex / Midpoint / Center)", &_ed.osnap_enabled)
	widgets.tooltip("Magnetically snaps to existing CSG vertices, edge midpoints, and face centers (hold Alt to bypass)")
	im.SetNextItemWidth(180)
	im.SliderFloat("Grid Snap Step", &_ed.snap_step, 0.05, 2.0, "%.2f m")
	widgets.tooltip("Radial / metric grid step in meters for drawing and extrusion")
}

draw_box_tool_right_click_settings :: proc() {
	_ensure_init()
	im.Text("3D Box / Primitive Builder Settings:")
	prim_names := [6]cstring{"Box", "Wedge (Ramp)", "Hex Pillar (6)", "Oct Column (8)", "Cylinder (12)", "Bevel Box"}
	p_idx := clamp(int(_ed.primitive), 0, 5)
	im.SetNextItemWidth(180)
	if im.BeginCombo("Primitive Shape", prim_names[p_idx]) {
		for i in 0 ..< 6 {
			if im.Selectable(prim_names[i], p_idx == i) {
				_ed.primitive = cad_csg.Brush_Primitive(i)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Shape the Box tool draws: Box, Wedge ramp, Hex pillar, Octagonal column, Cylinder or Bevelled box")
	is_sub := (_ed.brush_op == .Subtract)
	if im.Checkbox("Boolean Cut Hole (-Subtract)", &is_sub) {
		_ed.brush_op = .Subtract if is_sub else .Add
	}
	widgets.tooltip("The drawn shape carves a hole into existing CSG instead of adding solid geometry")
	im.Checkbox("6-Face Brush Resize Grips on Select", &_ed.show_brush_face_grips)
	widgets.tooltip("Shows 6 Hammer/TrenchBroom-style face handles on the selected brush to push/pull individual faces while keeping the opposite face anchored!")
	im.Checkbox("Destructible Brush", &_ed.brush_destructible)
	widgets.tooltip("The new brush can be blasted by the Geo-Mod tool")
	im.Checkbox("Magnetic OSNAP (Vertex / Midpoint / Center)", &_ed.osnap_enabled)
	widgets.tooltip("Magnetically snaps footprint corners to existing CSG vertices, edge midpoints, and face centers (Shift = 1:1 Square lock, Alt = Free)")
	im.SetNextItemWidth(180)
	im.SliderFloat("Grid Snap Step", &_ed.snap_step, 0.05, 2.0, "%.2f m")
	widgets.tooltip("Grid step in meters for footprint dimensions and height (type WxD + Enter for exact size!)")
	im.ColorEdit4("Brush Tint", &_ed.brush_color)
	widgets.tooltip("Color of newly drawn CSG brushes")
}


draw_extrude_tool_right_click_settings :: proc() {
	_ensure_init()
	im.TextColored({1.0, 0.85, 0.25, 1.0}, "Blender-Style Face Extrude / Intrude Settings:")

	axis_names := [5]cstring{
		"Face Normal (Key: N)",
		"World X Axis (Key: X)",
		"World Y Axis (Key: Y)",
		"World Z Axis (Key: Z)",
		"Free Cursor 3D (Key: G)",
	}
	ax_idx := clamp(int(_ed.extrude_axis_mode), 0, 4)
	im.SetNextItemWidth(190)
	if im.BeginCombo("Extrude Axis", axis_names[ax_idx]) {
		for i in 0 ..< 5 {
			if im.Selectable(axis_names[i], ax_idx == i) {
				_ed.extrude_axis_mode = Extrude_Axis_Mode(i)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Direction faces are extruded: face normal, world X / Y / Z or free cursor (hotkeys N / X / Y / Z / G)")

	beh_names := [2]cstring{
		"Extrude (+Out) / Intrude Pocket (-In)",
		"Move / Resize Existing Face Plane",
	}
	b_idx := clamp(int(_ed.extrude_csg_behavior), 0, 1)
	im.SetNextItemWidth(190)
	if im.BeginCombo("CSG Mode (Tab)", beh_names[b_idx]) {
		for i in 0 ..< 2 {
			if im.Selectable(beh_names[i], b_idx == i) {
				_ed.extrude_csg_behavior = Extrude_CSG_Behavior(i)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("On CSG volumes: extrude a new segment / carve a pocket, or move the existing face plane (Tab switches)")

	im.SetNextItemWidth(180)
	im.SliderFloat("Face Inset Margin", &_ed.extrude_inset_margin, 0.0, 0.75, "%.2f")
	widgets.tooltip("Inset of the new face ring when extruding a mesh face (0 = the whole face)")
	im.SetNextItemWidth(180)
	im.SliderFloat("Extrude Snap Step", &_ed.snap_step, 0.05, 2.0, "%.2f m")
	widgets.tooltip("Snap step for the extrude distance in meters")
	im.Checkbox("Edit Single Brush in Gizmo Mode", &_ed.gizmo_edits_brush)
	widgets.tooltip("W / E / R moves only the clicked CSG brush instead of the whole volume")
	im.TextDisabled("Drag outward = Extrude, Drag inward = Intrude!")
}

// Deterministic runtime Material GUID for Cut / Crater Fill Albedo & Texture overrides when no `.mat` file is selected.
@(private = "file")
_make_tool_cut_fill_mat_guid :: proc() -> engine.Asset_GUID {
	return engine.Asset_GUID([16]u8{
		0x43, 0x55, 0x54, 0x5F, 0x46, 0x49, 0x4C, 0x4C, // "CUT_FILL"
		0x5F, 0x4D, 0x41, 0x54, 0x5F, 0x30, 0x30, 0x31,
	})
}

// Updates the active Cut / Crater Fill Material (`guid_ptr^`) with `_ed.tool_cut_tex_guid`.
// Per-blast / per-slice Albedo color (`_ed.tool_cut_albedo`) is baked directly into vertex color `[4]u8`
// on each individual blast or clip plane so changing the tool's Fill Texture or Fill Albedo Color
// applies ONLY to future cuts/blasts and never overwrites previously carved craters or cuts!
@(private = "package")
sync_cut_fill_material_and_active_volume :: proc(guid_ptr: ^engine.Asset_GUID) {
	if guid_ptr == nil do return

	if _ed.tool_cut_albedo_enabled || !engine.asset_guid_is_empty(_ed.tool_cut_tex_guid) {
		if engine.asset_guid_is_empty(guid_ptr^) {
			guid_ptr^ = _make_tool_cut_fill_mat_guid()
		}
		tex_to_use := _ed.tool_cut_tex_guid
		shd_to_use := engine.Material_Shader.Lit
		if m_existing, mok := engine.material_load(guid_ptr^); mok {
			shd_to_use = m_existing.shader
			if engine.asset_guid_is_empty(tex_to_use) && guid_ptr^ != _make_tool_cut_fill_mat_guid() {
				tex_to_use = m_existing.texture
				_ed.tool_cut_tex_guid = tex_to_use
			}
		}
		// Keep the material's base color at `{1, 1, 1, 1}` so each blast/cut's per-vertex `[4]u8` albedo color
		// tints the texture independently per blast/slice!
		mat_data := engine.Material{
			shader  = shd_to_use,
			texture = tex_to_use,
			color   = {1.0, 1.0, 1.0, 1.0},
		}
		m_path, pok := engine.asset_db_get_path(auto_cast guid_ptr^)
		if guid_ptr^ == _make_tool_cut_fill_mat_guid() || (pok && strings.has_prefix(m_path, "assets/materials/Cut_")) {
			engine.material_preview(guid_ptr^, mat_data)
			if pok && strings.has_prefix(m_path, "assets/materials/Cut_") {
				_ = engine.material_save_to_file(m_path, mat_data)
			}
		}
	}

	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Resolves a `.mat` asset path directly to its `Asset_GUID`, or if given a `.png` / `.jpg` / `.jpeg` texture path,
// automatically creates/updates a wrapper `.mat` in `assets/materials/Cut_<stem>.mat` and returns its `Asset_GUID`!
@(private = "file")
_resolve_or_create_material_from_asset_path :: proc(raw_path: string) -> (engine.Asset_GUID, bool) {
	rel_p, _ := strings.replace_all(raw_path, "\\", "/", context.temp_allocator)
	if len(engine.asset_db.root_path) > 0 {
		root_norm, _ := strings.replace_all(engine.asset_db.root_path, "\\", "/", context.temp_allocator)
		if strings.has_prefix(rel_p, root_norm) {
			rel_p = strings.trim_left(rel_p[len(root_norm):], "/")
		}
	}
	ext_lo := strings.to_lower(rel_p, context.temp_allocator)
	if strings.has_suffix(ext_lo, ".mat") {
		engine.asset_db_request_refresh()
		if disk_id, ok := engine.asset_db_get_guid(rel_p); ok {
			mat_guid := engine.Asset_GUID(disk_id)
			if m_loaded, mok := engine.material_load(mat_guid); mok {
				_ed.tool_cut_tex_guid = m_loaded.texture
				_ed.tool_cut_albedo   = m_loaded.color
			}
			return mat_guid, true
		}
		return {}, false
	}
	if strings.has_suffix(ext_lo, ".png") || strings.has_suffix(ext_lo, ".jpg") || strings.has_suffix(ext_lo, ".jpeg") {
		engine.asset_db_request_refresh()
		tex_id, tok := engine.asset_db_get_guid(rel_p)
		if !tok do return {}, false
		tex_guid := engine.Asset_GUID(tex_id)
		_ed.tool_cut_tex_guid = tex_guid

		// Extract filename stem
		base_name := rel_p
		if slash_i := strings.last_index_byte(base_name, '/'); slash_i >= 0 {
			base_name = base_name[slash_i + 1:]
		}
		if dot_i := strings.last_index_byte(base_name, '.'); dot_i > 0 {
			base_name = base_name[:dot_i]
		}
		_ = os.make_directory("assets")
		_ = os.make_directory("assets/materials")
		mat_rel := fmt.tprintf("assets/materials/Cut_%s.mat", base_name)
		mat_data := engine.Material{
			shader  = .Lit,
			texture = tex_guid,
			color   = {1.0, 1.0, 1.0, 1.0},
		}
		_ = engine.material_save_to_file(mat_rel, mat_data)
		engine.asset_db_request_refresh()
		if mat_id, mok := engine.asset_db_get_guid(mat_rel); mok {
			mat_guid := engine.Asset_GUID(mat_id)
			engine.material_preview(mat_guid, mat_data)
			return mat_guid, true
		}
		// Deterministic in-memory fallback GUID per texture if AssetDB hasn't indexed the new file yet
		fallback_guid := tex_guid
		fallback_guid[0] ~= 0x43
		fallback_guid[1] ~= 0x55
		engine.material_preview(fallback_guid, mat_data)
		return fallback_guid, true
	}
	return {}, false
}

// Reusable UI widget for selecting or drag-and-dropping an optional Cut / Crater Interior Material or Texture
// + Cut / Crater Fill Albedo Color (with a 1-click default fallback to the object's own texture!).
@(private = "file")
_draw_cut_material_override_picker :: proc(
	id_suffix:      string,
	guid_ptr:       ^engine.Asset_GUID,
	avail_w:        f32,
	fallback_label: cstring,
) -> (changed: bool) {
	if guid_ptr == nil do return false
	has_override := !engine.asset_guid_is_empty(guid_ptr^)

	cur_lbl: cstring = fallback_label
	if has_override {
		if m_path, pok := engine.asset_db_get_path(auto_cast guid_ptr^); pok && len(m_path) > 0 {
			cur_lbl = fmt.ctprintf("Override: %s", m_path)
		} else if !engine.asset_guid_is_empty(_ed.tool_cut_tex_guid) {
			if t_path, tok := engine.asset_db_get_path(auto_cast _ed.tool_cut_tex_guid); tok && len(t_path) > 0 {
				cur_lbl = fmt.ctprintf("Fill Tex: %s", t_path)
			} else {
				cur_lbl = "Fill: Procedural Studio Texture + Albedo"
			}
		} else {
			cur_lbl = fmt.ctprintf("Fill: Solid Albedo (%.2f, %.2f, %.2f)", _ed.tool_cut_albedo.r, _ed.tool_cut_albedo.g, _ed.tool_cut_albedo.b)
		}
	}

	im.TextColored({0.95, 0.82, 0.35, 1.0} if has_override else {0.45, 0.95, 0.65, 1.0}, "Cut / Crater Fill Texture & Albedo:")
	btn_w := (avail_w - 64.0) if has_override else avail_w
	im.SetNextItemWidth(btn_w)
	if im.BeginCombo(fmt.ctprintf("##cut_mat_combo_%s", id_suffix), cur_lbl) {
		if im.Selectable(fallback_label, !has_override) {
			guid_ptr^ = {}
			_ed.tool_cut_tex_guid       = {}
			_ed.tool_cut_albedo_enabled = false
			_ed.tool_cut_albedo         = {1, 1, 1, 1}
			sync_cut_fill_material_and_active_volume(guid_ptr)
			changed = true
		}
		if im.Selectable("[Solid Albedo Fill Only (No Texture)]", has_override && engine.asset_guid_is_empty(_ed.tool_cut_tex_guid)) {
			_ed.tool_cut_tex_guid       = {}
			_ed.tool_cut_albedo_enabled = true
			guid_ptr^                   = _make_tool_cut_fill_mat_guid()
			sync_cut_fill_material_and_active_volume(guid_ptr)
			changed = true
		}
		if im.Selectable("[Procedural Texture Studio Pattern]", false) {
			_ensure_proc_tex_preview()
			_ed.tool_cut_tex_guid       = _ed.proc_tex_preview_guid
			_ed.tool_cut_albedo_enabled = true
			guid_ptr^                   = _make_tool_cut_fill_mat_guid()
			sync_cut_fill_material_and_active_volume(guid_ptr)
			changed = true
		}
		for p, g in engine.asset_db.path_to_guid {
			p_lo := strings.to_lower(p, context.temp_allocator)
			if strings.has_suffix(p_lo, ".mat") {
				eg := engine.Asset_GUID(g)
				if im.Selectable(fmt.ctprintf("Mat: %s", p), guid_ptr^ == eg) {
					guid_ptr^ = eg
					if m_loaded, mok := engine.material_load(eg); mok {
						_ed.tool_cut_tex_guid = m_loaded.texture
						_ed.tool_cut_albedo   = m_loaded.color
					}
					sync_cut_fill_material_and_active_volume(guid_ptr)
					changed = true
				}
			}
		}
		for p, _ in engine.asset_db.path_to_guid {
			p_lo := strings.to_lower(p, context.temp_allocator)
			if strings.has_suffix(p_lo, ".png") || strings.has_suffix(p_lo, ".jpg") || strings.has_suffix(p_lo, ".jpeg") {
				if im.Selectable(fmt.ctprintf("Tex: %s", p), false) {
					if mg, mok := _resolve_or_create_material_from_asset_path(p); mok {
						guid_ptr^ = mg
						sync_cut_fill_material_and_active_volume(guid_ptr)
						changed = true
					}
				}
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("• Default Fallback (Empty): Filled slice cross-sections and Geo-Mod craters automatically use the mesh's own outer texture.\n• Solid Albedo or Texture Override: Pick any .mat, .png/.jpg texture, Procedural Studio pattern, or Solid Albedo color to fill the cut/crater interior!")

	// Also allow dragging and dropping any `.mat` or `.png`/`.jpg` directly onto the combo box!
	if im.BeginDragDropTarget() {
		if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
			raw_bytes := ([^]u8)(payload.Data)[:payload.DataSize]
			dropped_str := strings.trim_right_null(string(raw_bytes))
			if mg, mok := _resolve_or_create_material_from_asset_path(dropped_str); mok {
				guid_ptr^ = mg
				sync_cut_fill_material_and_active_volume(guid_ptr)
				changed = true
			}
		}
		im.EndDragDropTarget()
	}

	if has_override {
		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("Fallback##rst_%s", id_suffix), {60, 0}) {
			guid_ptr^ = {}
			_ed.tool_cut_tex_guid       = {}
			_ed.tool_cut_albedo_enabled = false
			_ed.tool_cut_albedo         = {1, 1, 1, 1}
			sync_cut_fill_material_and_active_volume(guid_ptr)
			changed = true
		}
		widgets.tooltip("Clear override and revert to Default Fallback (uses the mesh's own texture)")
	}

	// Cut / Crater Fill Albedo Color Picker (works both as a solid fill color OR as an albedo tint over the chosen Fill Texture!)
	im.SetNextItemWidth(avail_w - 95.0)
	if im.ColorEdit4(fmt.ctprintf("Fill Albedo##cut_alb_%s", id_suffix), &_ed.tool_cut_albedo) {
		_ed.tool_cut_albedo_enabled = true
		sync_cut_fill_material_and_active_volume(guid_ptr)
		changed = true
	}
	widgets.tooltip("Albedo RGBA color for Cut / Crater interior faces! Pick any color to tint the selected Cut Fill Texture (or to fill cuts/craters with a solid Albedo color even without a texture).")
	return changed
}

draw_blast_tool_right_click_settings :: proc() {
	_ensure_init()
	im.Text("Red Faction Geo-Mod Crater Settings:")
	im.SetNextItemWidth(190)
	im.SliderFloat("Crater Radius ([ / ])", &_ed.blast_radius, 0.12, 8.0, "%.2f m")
	widgets.tooltip("Radius of the Geo-Mod crater in meters (also [ and ] in Scene3D)")
	im.SetNextItemWidth(190)
	im.SliderFloat("Explosion Impulse", &_ed.blast_impulse, 1.0, 40.0, "%.1f")
	widgets.tooltip("How hard debris and detached pieces are thrown by a blast")
	im.SetNextItemWidth(190)
	if im.SliderFloat("Crater Jaggedness", &cad_csg.csg_settings.blast_jaggedness, 0.0, 0.35, "%.2f") {
		if vol, _ := _resolve_active_volume(false); vol != nil && len(vol.recorded_blasts) > 0 {
			cad_csg.csg_volume_rebuild(vol)
		}
	}
	widgets.tooltip("Perturbs the 14 facet angles and depths of the blast polyhedron so craters look like jagged fractured rock instead of a smooth geometric crystal (0.00 = uniform crystal, 0.14 = natural rock, 0.35 = rough jagged shatter)")
	_ = _draw_cut_material_override_picker("blast_tool", &_ed.tool_cut_material_guid, 250, "[Blunt Impact: Keep Mesh's Own Texture]")
	im.PushStyleColorImVec4(.Button, {0.72, 0.28, 0.20, 0.95})
	if im.Button("Reset Destruction Test (Restore CSG)", {-1, 24}) {
		if vol_r, _ := _resolve_active_volume(false); vol_r != nil {
			cad_csg.csg_volume_reset_craters(vol_r)
		}
	}
	im.PopStyleColor(1)
	widgets.tooltip("Restores the CSGVolume to its clean, un-blasted CAD geometry after testing destruction")
}

draw_clip_plane_tool_right_click_settings :: proc() {
	_ensure_init()
	im.TextColored({0.35, 0.95, 1.0, 1.0}, "2-Point CSG Clip Plane Slicer (SabreCSG / RealtimeCSG):")
	clip_names := [3]cstring{
		"Split Both Halves (Two Hulls)",
		"Keep Back (-Normal Half)",
		"Keep Front (+Normal Half)",
	}
	cm_idx := clamp(int(_ed.clip_mode), 0, 2)
	im.SetNextItemWidth(190)
	if im.BeginCombo("Clip Mode (Tab)", clip_names[cm_idx]) {
		for i in 0 ..< 3 {
			if im.Selectable(clip_names[i], cm_idx == i) {
				_ed.clip_mode = cad_csg.CSG_Clip_Mode(i)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("• Split Both Halves: Slices the CSG volume into two separate watertight convex pieces across the plane.\n• Keep Back / Keep Front: Shaves off one side of the cutting plane to bevel or trim the volume (Shortcut: Tab).")
	im.SetNextItemWidth(180)
	im.SliderFloat("Split Seam Gap", &_ed.clip_split_gap, 0.0, 0.50, "%.2f m")
	widgets.tooltip("Optional gap width in meters between the two sliced halves")
	im.SetNextItemWidth(180)
	im.SliderFloat("Grid Snap Step", &_ed.snap_step, 0.05, 2.0, "%.2f m")
	widgets.tooltip("Grid step in meters for snapping Clip Point A and Point B")
	_ = _draw_cut_material_override_picker("clip_tool", &_ed.tool_cut_material_guid, 250, "[Default Cut: Keep Mesh's Own Texture]")
	if _ed.clip_has_pt_a {
		if im.SmallButton("Cancel Point A (RMB)") {
			_ed.clip_has_pt_a = false
		}
		widgets.tooltip("Cancel the currently placed Point A")
	}
	im.TextDisabled("Click Point A -> Click Point B in Scene3D to slice!")
}

draw_mesh_extrude_right_click_settings :: proc() {
	_ensure_mesh_ed_init()
	im.SetNextItemWidth(180)
	im.SliderFloat("Extrude Distance", &_mesh_ed.extrude_amount, -5.0, 5.0, "%.2f m")
	widgets.tooltip("Distance used by Extrude (Shift+E) and Intrude; negative pushes inward")
}

draw_mesh_inset_right_click_settings :: proc() {
	_ensure_mesh_ed_init()
	im.SetNextItemWidth(180)
	im.SliderFloat("Inset Ratio", &_mesh_ed.inset_amount, 0.05, 0.80, "%.2f")
	widgets.tooltip("How far Inset (I) shrinks the new inner face (fraction of the face size)")
}

draw_mesh_bevel_right_click_settings :: proc() {
	_ensure_mesh_ed_init()
	im.SetNextItemWidth(180)
	im.SliderFloat("Bevel Amount", &_mesh_ed.bevel_amount, 0.05, 0.60, "%.2f m")
	widgets.tooltip("Size of the chamfer created by Bevel (B)")
}

draw_soft_deform_tool_right_click_settings :: proc() {
	_ensure_init()
	im.TextColored({0.95, 0.55, 1.0, 1.0}, "Soft Deformer Body Brush (Mesh Coord Offset):")
	mode_names := [4]cstring{
		"Dent Inward (-Normal)",
		"Bulge Outward (+Normal)",
		"Shockwave Ripple (Wave)",
		"Twist Shear (Vortex)",
	}
	dm_idx := clamp(int(_ed.deform_mode), 0, 3)
	im.SetNextItemWidth(185)
	if im.BeginCombo("Deform Mode (Tab)", mode_names[dm_idx]) {
		for i in 0 ..< 4 {
			if im.Selectable(mode_names[i], dm_idx == i) {
				_ed.deform_mode = cad_csg.CSG_Soft_Deform_Mode(i)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Deformation field mode: Dent Inward, Bulge Outward, Shockwave Ripple, or Twist Shear (Tab cycles)")
	im.SetNextItemWidth(180)
	im.SliderFloat("Deform Radius (m)", &_ed.deform_radius, 0.30, 8.0, "%.2f m")
	im.SetNextItemWidth(180)
	im.SliderFloat("Deform Amplitude (m)", &_ed.deform_amplitude, 0.05, 2.50, "%.2f m")
	im.Checkbox("Show 3D Offset Vectors (p0 -> p')", &_ed.show_deform_vectors)
	widgets.tooltip("Draws 3D displacement vector arrows from undeformed collision vertices (p0) to deformed visual vertices (p')!")

	if vol, _ := _resolve_active_volume(false); vol != nil {
		if im.Checkbox("Render Strain Heatmap on Mesh", &vol.deform_debug_heatmap) {
			cad_csg.csg_volume_repack_gpu_mesh(vol)
		}
		widgets.tooltip("Colors deformed vertices with an unlit strain heatmap (Blue = 0 -> Cyan -> Green -> Yellow -> Red = Max Strain)!")
		if len(vol.soft_deform_stamps) > 0 {
			im.PushStyleColorImVec4(.Button, {0.72, 0.28, 0.20, 0.95})
			if im.Button(fmt.ctprintf("Clear %d Soft Deform Stamp(s)", len(vol.soft_deform_stamps)), {-1, 23}) {
				cad_csg.csg_volume_reset_soft_deform(vol)
			}
			im.PopStyleColor(1)
		}
	}
}

// ============================================================================
// DRAWER 5 (CSG) / DRAWER 6 (MESH):
// PHYSICAL MATERIAL DATATABLE, GODOT-STYLE PROCEDURAL TEXTURE STUDIO & SOFT DEFORMER MATH
// ============================================================================

@(private = "file")
_build_current_proc_tex_params :: proc(sz_override: i32 = 0) -> cad_csg.CSG_Proc_Texture_Params {
	sz := sz_override if sz_override > 0 else clamp(_ed.proc_tex_size, 32, 512)
	params := cad_csg.csg_default_proc_texture_params(_ed.proc_tex_pattern)
	params.width           = sz
	params.height          = sz
	params.primary_color   = _ed.proc_tex_color_a
	params.secondary_color = _ed.proc_tex_color_b
	params.scale           = max(_ed.proc_tex_scale, 0.5)
	params.roughness_frost = clamp(_ed.proc_tex_contrast * 0.35, 0.0, 1.0)
	return params
}

@(private = "file")
_ensure_proc_tex_preview :: proc() {
	if engine.asset_guid_is_empty(_ed.proc_tex_preview_guid) {
		_ed.proc_tex_preview_guid = engine.Asset_GUID([16]u8{
			0x50, 0x52, 0x4F, 0x43, 0x5F, 0x54, 0x45, 0x58,
			0x5F, 0x50, 0x52, 0x56, 0x00, 0x00, 0x00, 0x01,
		})
		_ed.proc_tex_dirty = true
	}
	_, cached := engine.texture_load(_ed.proc_tex_preview_guid)
	if _ed.proc_tex_dirty || !cached {
		_ed.proc_tex_dirty = false
		params := _build_current_proc_tex_params()
		pixels := cad_csg.csg_generate_procedural_texture_rgba(params, context.temp_allocator)
		engine.texture_upsert_procedural(_ed.proc_tex_preview_guid, pixels, params.width, params.height)
	}
}

@(private = "file")
_apply_procedural_texture_to_selection :: proc() {
	_ensure_proc_tex_preview()
	params := _build_current_proc_tex_params()
	pixels := cad_csg.csg_generate_procedural_texture_rgba(params, context.temp_allocator)

	// Dedicated procedural Texture & Material GUIDs for applied studio material
	tex_guid := engine.Asset_GUID([16]u8{
		0x50, 0x52, 0x4F, 0x43, 0x5F, 0x54, 0x45, 0x58,
		0x5F, 0x41, 0x50, 0x50, 0x00, 0x00, u8(_ed.proc_tex_pattern), 0x02,
	})
	mat_guid := engine.Asset_GUID([16]u8{
		0x50, 0x52, 0x4F, 0x43, 0x5F, 0x4D, 0x41, 0x54,
		0x5F, 0x41, 0x50, 0x50, 0x00, 0x00, u8(_ed.proc_tex_pattern), 0x02,
	})
	// If it's a translucent glass/ice pattern, give `mat_guid` a high byte prefix `{0xFE, 0xFE, ...}` so it sorts after opaque!
	is_translucent := _ed.proc_tex_pattern == .Glass_Frosted_Streaks || _ed.proc_tex_pattern == .Glass_Wired_Reinforced || _ed.proc_tex_pattern == .Sheet_Ice_Crystalline || _ed.proc_tex_color_a.a < 0.92
	if is_translucent {
		mat_guid = engine.Asset_GUID([16]u8{
			0xFE, 0xFE, 0x47, 0x4C, 0x41, 0x53, 0x53, 0x21,
			0x53, 0x54, 0x55, 0x44, 0x49, 0x4F, u8(_ed.proc_tex_pattern), 0xFE,
		})
	}
	engine.texture_upsert_procedural(tex_guid, pixels, params.width, params.height)
	engine.material_preview(mat_guid, engine.Material{
		shader  = .Unlit if is_translucent else .Lit,
		texture = tex_guid,
		color   = {1.0, 1.0, 1.0, 1.0},
	})

	// 1. Apply to active CSGVolume if one exists
	if vol, _ := _resolve_active_volume(false); vol != nil {
		vol.custom_material_guid = mat_guid
		vol.gpu_dirty = true
	}
	// 2. Also apply to selected MeshRenderer if one is selected
	w := engine.ctx_world()
	sel := engine.inspector_active_selection()
	if w != nil && sel != {} && engine.pool_valid(&w.transforms, engine.Handle(sel)) {
		if _, mr := engine.transform_get_comp(sel, engine.MeshRenderer); mr != nil {
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			if len(mr.materials) == 0 {
				append(&mr.materials, mat_guid)
			} else {
				mr.materials[0] = mat_guid
			}
			context.allocator = prev_a
		}
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(private = "file")
_draw_csg_drawer_materials_and_deform :: proc(avail_w, half_w, third_w: f32) {
	im.TextColored({0.95, 0.58, 1.0, 1.0}, "Material DataTable, Texture Studio & Soft Deformer")

	im.PushStyleColorImVec4(.Button, {0.58, 0.24, 0.72, 0.98})
	if im.Button(fmt.ctprintf("%s Open Unified Void Material Editor & Node Graph", icons.ICON_MD_PALETTE), {avail_w, 26}) {
		wnd.open("void_material_editor")
	}
	im.PopStyleColor(1)
	widgets.tooltip("Opens the Unified Void Material Editor (Material Inspector, Unreal/Blender Visual Node Graph & Physical CSG Material Studio)!")

	vol, _ := _resolve_active_volume(false)

	// ------------------------------------------------------------------------
	// 1. PHYSICAL & DESTRUCTIBLE MATERIAL PROPERTIES DATATABLE
	// ------------------------------------------------------------------------
	im.SeparatorText("1. Physical Material Properties DataTable")
	preset_names := [10]cstring{
		"Concrete (Yield: 6.0 N*s)",
		"Reinforced Concrete (Yield: 22.0 N*s)",
		"Brick Masonry (Yield: 4.5 N*s)",
		"Tempered Glass (Yield: 1.5 N*s, Shatters)",
		"Reinforced Wired Glass (Yield: 9.5 N*s)",
		"Sheet Ice (Yield: 1.0 N*s, Crystalline)",
		"Wood Plank (Yield: 3.5 N*s)",
		"Steel Plate (Yield: 48.0 N*s, Dents Only!)",
		"Soft Metal Panel (Yield: 35.0 N*s, Deep Dents!)",
		"Soft Rubber / Gel (Yield: 60.0 N*s, Elastic Wave!)",
	}
	cur_preset: cad_csg.CSG_Material_Preset = vol.material_preset if vol != nil else _ed.prefab_material
	p_idx := clamp(i32(cur_preset), 0, 9)
	im.SetNextItemWidth(avail_w - 75)
	if im.ComboChar("Material", &p_idx, raw_data(preset_names[:]), 10) {
		cur_preset = cad_csg.CSG_Material_Preset(p_idx)
		_ed.prefab_material = cur_preset
		if vol != nil {
			vol.material_preset = cur_preset
			// Enable soft deformer automatically on deformable presets
			row_sel := cad_csg.csg_get_material_properties(cur_preset)
			if row_sel.deform_enabled {
				vol.soft_deform_enabled = true
			}
			// Tint brush colors to match material preset
			col_f := [4]f32{
				f32(row_sel.base_color[0]) / 255.0,
				f32(row_sel.base_color[1]) / 255.0,
				f32(row_sel.base_color[2]) / 255.0,
				1.0,
			}
			_ed.brush_color = col_f
			for &b in vol.brushes {
				if b.op == .Add do b.color = row_sel.base_color
			}
			cad_csg.csg_volume_rebuild(vol)
		}
	}
	widgets.tooltip("Selects the Physical & Destructible Material Preset for this CSGVolume (governs blast yield force, crater scale, glass shatter resistance, and soft deformation!)")

	cad_csg.csg_init_material_datatable()
	row := &cad_csg.csg_material_datatable[cur_preset]
	im.SetNextItemWidth(avail_w - 110)
	im.SliderFloat("Yield Force (N*s)", &row.yield_blast_force, 0.5, 65.0, "%.1f N*s")
	widgets.tooltip("Minimum blast impulse required to fracture/carve this material! Blasts below this threshold do NOT carve boolean holes (they only dent Soft Metal / Steel!)")
	im.SetNextItemWidth(avail_w - 110)
	im.SliderFloat("Crater Scale", &row.crater_radius_scale, 0.0, 2.0, "%.2fx")
	im.SetNextItemWidth(avail_w - 110)
	im.SliderFloat("Deform Stiffness", &row.deform_stiffness, 1.0, 100.0, "%.1f")
	widgets.tooltip("Lower stiffness = deeper elastic/plastic dents on impact (Soft Rubber = 12, Soft Metal = 18, Steel = 28)")

	// ------------------------------------------------------------------------
	// 2. SOFT DEFORMER BRUSH (WORKS ON MESH, CSG VOLUME & FAKER CSG + COLLISION!)
	// ------------------------------------------------------------------------
	im.SeparatorText("2. Soft Deformer Brush (Mesh + CSG + Faker CSG)")
	sd_act := _ed.tool_active && _ed.sub_tool == .Soft_Deform_Brush
	if sd_act do im.PushStyleColorImVec4(.Button, {0.78, 0.28, 0.86, 0.98})
	if im.Button("Soft Deformer Brush (Key: 6)", {avail_w, 25}) {
		toggle_cad_tool(.Soft_Deform_Brush)
	}
	if sd_act do im.PopStyleColor(1)
	widgets.tooltip("Click any [POLY MESH], [CSG VOLUME], or [FAKER CSG] surface in Scene3D to dent, bulge, ripple, or twist geometry AND update Jolt physics colliders! (Right-click rotates camera normally)")

	mode_names_sd := [4]cstring{
		"Dent Inward (-Normal)",
		"Bulge Outward (+Normal)",
		"Shockwave Ripple (Wave)",
		"Twist Shear (Vortex)",
	}
	dm_idx_sd := clamp(i32(_ed.deform_mode), 0, 3)
	im.SetNextItemWidth(avail_w - 80)
	if im.ComboChar("Deform Mode", &dm_idx_sd, raw_data(mode_names_sd[:]), 4) {
		_ed.deform_mode = cad_csg.CSG_Soft_Deform_Mode(dm_idx_sd)
	}
	im.SetNextItemWidth(avail_w - 80)
	im.SliderFloat("Brush Radius", &_ed.deform_radius, 0.25, 8.0, "%.2f m")
	im.SetNextItemWidth(avail_w - 80)
	im.SliderFloat("Brush Depth", &_ed.deform_amplitude, 0.05, 2.50, "%.2f m")

	if vol != nil {
		tw_vol := engine.transform_world(vol.owner)
		if im.Button("+ Test Dent Stamp", {half_w, 23}) {
			csg_history_ensure_baseline(vol)
			vol.soft_deform_enabled = true
			lo, hi, _ := cad_csg.csg_volume_local_aabb(vol)
			mid := (lo + hi) * 0.5
			wp := tw_vol.position + [3]f32{mid.x, mid.y, hi.z}
			_ = cad_csg.csg_apply_soft_deform_impulse(wp, {0, 0, 1}, _ed.deform_radius, _ed.deform_amplitude, .Dent_Inward, vol)
			csg_history_commit(vol)
		}
		widgets.tooltip("Stamps an inward dent on the front of the volume and updates its Jolt physics collider!")
		im.SameLine(0, 4)
		if im.Button("+ Test Wave Ripple", {half_w, 23}) {
			csg_history_ensure_baseline(vol)
			vol.soft_deform_enabled = true
			lo, hi, _ := cad_csg.csg_volume_local_aabb(vol)
			mid := (lo + hi) * 0.5
			wp := tw_vol.position + [3]f32{mid.x, mid.y, hi.z}
			_ = cad_csg.csg_apply_soft_deform_impulse(wp, {0, 0, 1}, _ed.deform_radius * 1.4, _ed.deform_amplitude, .Shockwave_Ripple, vol)
			csg_history_commit(vol)
		}
		widgets.tooltip("Stamps an oscillating damped sinusoidal shockwave ripple across the mesh coordinates!")

		im.Checkbox("3D Vectors (p0 -> p') & Cage", &_ed.show_deform_vectors)
		if im.Checkbox("Strain Heatmap Shader Mode", &vol.deform_debug_heatmap) {
			cad_csg.csg_volume_repack_gpu_mesh(vol)
		}
		if len(vol.soft_deform_stamps) > 0 {
			if im.Button(fmt.ctprintf("Clear Soft Deform Stamps (%d)", len(vol.soft_deform_stamps)), {avail_w, 22}) {
				cad_csg.csg_volume_reset_soft_deform(vol)
			}
		}
	} else if len(_mesh_ed.verts) > 0 && _mesh_ed.target_owner != {} {
		if im.Button("+ Test Dent on Selected Poly Mesh", {avail_w, 23}) {
			if _, hi_w, c_w, ok_b := _mesh_geometry_world_bounds(); ok_b {
				_ = apply_soft_deform_to_editable_poly_mesh({c_w.x, hi_w.y, c_w.z}, {0, 1, 0}, _ed.deform_radius, _ed.deform_amplitude, _ed.deform_mode)
			}
		}
		widgets.tooltip("Applies a Soft Deformer dent directly to the selected [POLY MESH] (use Ctrl+Z to undo!)")
	}
}

// ============================================================================
// EMBEDDED PANEL FOR UNIFIED `VOID MATERIAL EDITOR` (TAB 3: PHYSICAL CSG & DEFORMER STUDIO)
// ============================================================================

draw_procedural_texture_and_material_studio_contents :: proc() {
	_ensure_init()
	_ensure_mesh_ed_init()

	avail_w := max(im.GetContentRegionAvail().x, 200.0)
	half_w  := (avail_w - 6.0) * 0.5
	third_w := (avail_w - 12.0) / 3.0

	_draw_csg_drawer_materials_and_deform(avail_w, half_w, third_w)

	im.Spacing()
	im.SeparatorText("4. 2D Deformation Coordinate-Offset Texture Map (R=dX, G=dY, B=dZ, A=Strain)")
	vol, _ := _resolve_active_volume(false)
	if vol == nil {
		im.TextDisabled("Select a CSGVolume to inspect its 2D Deformation Offset Texture & Renderer Math.")
	} else {
		if engine.asset_guid_is_empty(_ed.deform_tex_preview_guid) {
			_ed.deform_tex_preview_guid = engine.Asset_GUID([16]u8{
				0x44, 0x45, 0x46, 0x4F, 0x52, 0x4D, 0x5F, 0x54,
				0x45, 0x58, 0x5F, 0x4D, 0x41, 0x50, 0x00, 0x01,
			})
		}
		def_pixels := cad_csg.csg_build_soft_deform_offset_texture_rgba8(vol, 64, 64, vol.deform_debug_heatmap, context.temp_allocator)
		engine.texture_upsert_procedural(_ed.deform_tex_preview_guid, def_pixels, 64, 64)
		if def_tex, dok := engine.texture_load(_ed.deform_tex_preview_guid); dok && def_tex != nil && def_tex.gfx != nil && def_tex.gfx.gpu != nil {
			def_tid := im.TextureID(uintptr(gfx.texture_imgui_id(def_tex.gfx)))
			im.Image(im.TextureRef{_TexID = def_tid}, {128, 128})
			im.SameLine()
		}
		im.BeginGroup()
		im.TextColoredUnformatted({0.45, 0.92, 1.0, 1.0}, fmt.ctprintf("Active Stamps: %d / %d", len(vol.soft_deform_stamps), cad_csg.MAX_SOFT_DEFORM_STAMPS))
		im.TextWrapped("Encoding: Neutral (0,0,0) = RGB(128,128,128). Displacements map [-1m..+1m] -> [0..255].")
		im.TextWrapped("Jolt Physics Colliders (LAYER_STATIC_WORLD) remain 100%% untouched while visual vertices deform via p' = p0 + delta_p(x, t)!")
		if im.Button("Save Material DataTable JSON", {210, 23}) {
			_ = cad_csg.csg_save_material_datatable_json()
		}
		im.SameLine()
		if im.Button("Reload JSON", {110, 23}) {
			_ = cad_csg.csg_load_material_datatable_json()
		}
		im.EndGroup()
	}
}

// ============================================================================
// SCENE3D RIGHT-CLICK CONTEXT MENU INTEGRATION (CSG & MESH BOOLEANS + PIVOT)
// ============================================================================

// Renders context-sensitive CSG & Mesh Boolean actions at the top of Scene3D's
// right-click popup (`##scene_context_menu`) whenever 2+ CSG/Mesh objects are
// selected (even if the user right-clicks empty space beside them), plus quick
// single-CSG actions when 1 CSG volume is right-clicked or selected.
draw_scene_context_menu_cad_items :: proc(clicked_target: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return

	all_sel := engine.inspector_selection_all()
	sel_candidates := make([dynamic]engine.Transform_Handle, 0, len(all_sel) + 2, context.temp_allocator)
	for sh in all_sel {
		if sh == {} || !engine.pool_valid(&w.transforms, engine.Handle(sh)) do continue
		_, csg_p := engine.transform_get_comp(sh, cad_csg.CSGVolume)
		_, mf_p  := engine.transform_get_comp(sh, engine.MeshFilter)
		_, adm_p := engine.transform_get_comp(sh, control_rig.ArmatureDeformedMesh)
		if csg_p != nil || mf_p != nil || adm_p != nil {
			append(&sel_candidates, sh)
		}
	}
	if len(sel_candidates) == 1 && _mesh_ed.bool_target_b != {} &&
	   _mesh_ed.bool_target_b != sel_candidates[0] &&
	   engine.pool_valid(&w.transforms, engine.Handle(_mesh_ed.bool_target_b)) {
		append(&sel_candidates, _mesh_ed.bool_target_b)
	}

	// Case 1: 2+ CSG/Mesh entities selected -> Direct Right-Click Booleans & Non-Destructive Join!
	if len(sel_candidates) >= 2 {
		target_h: engine.Transform_Handle = {}
		target_is_csg := false
		for sv in sel_candidates {
			if _, csg_v := engine.transform_get_comp(sv, cad_csg.CSGVolume); csg_v != nil && csg_v.enabled {
				target_h = sv
				target_is_csg = true
				break
			}
		}
		if target_h == {} do target_h = sel_candidates[0]

		tools := make([dynamic]engine.Transform_Handle, 0, len(sel_candidates) - 1, context.temp_allocator)
		all_tools_have_csg_brushes := target_is_csg
		for sv in sel_candidates {
			if sv == target_h do continue
			append(&tools, sv)
			if _, tv := engine.transform_get_comp(sv, cad_csg.CSGVolume); tv == nil || !tv.enabled || len(tv.brushes) == 0 {
				all_tools_have_csg_brushes = false
			}
		}

		name_a := "Target A"
		if t_a := engine.pool_get(&w.transforms, engine.Handle(target_h)); t_a != nil && len(t_a.name) > 0 {
			name_a = t_a.name
		}
		name_b := "Tool B"
		if len(tools) > 0 {
			if t_b := engine.pool_get(&w.transforms, engine.Handle(tools[0])); t_b != nil && len(t_b.name) > 0 {
				name_b = t_b.name
			}
		}
		extra_sfx := len(tools) > 1 ? fmt.tprintf(" +%d", len(tools) - 1) : ""

		im.TextColored({0.35, 0.95, 0.65, 1.0}, "%s", fmt.ctprintf("CSG / Mesh Booleans: %s  <-  %s%s", name_a, name_b, extra_sfx))

		if all_tools_have_csg_brushes {
			if im.MenuItem("Join Brushes into CSG A (Keep Editable Stack)") {
				_ensure_init()
				_ensure_mesh_ed_init()
				if _, vol_a := engine.transform_get_comp(target_h, cad_csg.CSGVolume); vol_a != nil {
					csg_history_ensure_baseline(vol_a)
					if cad_csg.csg_merge_volumes_non_destructive(target_h, tools[:], false, true) {
						csg_history_commit(vol_a)
						_mesh_ed.bool_target_b = {}
						_mesh_ed.csg_bool_target_b = {}
					}
				}
			}
		}

		if im.MenuItem("Boolean Union (A + B) — Join & Delete B") {
			if target_is_csg {
				csg_op_boolean_multi(target_h, tools[:], 0, true)
			} else {
				mesh_op_boolean_multi(target_h, tools[:], 0, true)
			}
		}
		if im.MenuItem("Boolean Subtract (A - B) — Carve & Delete B") {
			if target_is_csg {
				csg_op_boolean_multi(target_h, tools[:], 1, true)
			} else {
				mesh_op_boolean_multi(target_h, tools[:], 1, true)
			}
		}
		if im.MenuItem("Boolean Intersect (A & B) — Overlap & Delete B") {
			if target_is_csg {
				csg_op_boolean_multi(target_h, tools[:], 2, true)
			} else {
				mesh_op_boolean_multi(target_h, tools[:], 2, true)
			}
		}

		if im.BeginMenu("Boolean & Keep Tool B Untouched") {
			if all_tools_have_csg_brushes {
				if im.MenuItem("Copy Brushes into CSG A (Keep B)") {
					_ensure_init()
					_ensure_mesh_ed_init()
					if _, vol_a := engine.transform_get_comp(target_h, cad_csg.CSGVolume); vol_a != nil {
						csg_history_ensure_baseline(vol_a)
						if cad_csg.csg_merge_volumes_non_destructive(target_h, tools[:], false, false) {
							csg_history_commit(vol_a)
						}
					}
				}
			}
			if im.MenuItem("Union (A + B) — Keep B") {
				if target_is_csg do csg_op_boolean_multi(target_h, tools[:], 0, false)
				else             do mesh_op_boolean_multi(target_h, tools[:], 0, false)
			}
			if im.MenuItem("Subtract (A - B) — Keep B") {
				if target_is_csg do csg_op_boolean_multi(target_h, tools[:], 1, false)
				else             do mesh_op_boolean_multi(target_h, tools[:], 1, false)
			}
			if im.MenuItem("Intersect (A & B) — Keep B") {
				if target_is_csg do csg_op_boolean_multi(target_h, tools[:], 2, false)
				else             do mesh_op_boolean_multi(target_h, tools[:], 2, false)
			}
			im.EndMenu()
		}

		if len(tools) > 0 {
			if im.MenuItem("Swap Target A <-> Tool B") {
				_ensure_mesh_ed_init()
				engine.inspector_request_select(tools[0])
				_mesh_ed.bool_target_b = target_h
			}
		}
		im.Separator()
		return
	}

	// Case 2: Single CSGVolume right-clicked or selected -> Quick CSG Volume Actions submenu!
	single_h := clicked_target
	if single_h == {} && len(sel_candidates) == 1 do single_h = sel_candidates[0]
	if single_h != {} && engine.pool_valid(&w.transforms, engine.Handle(single_h)) {
		if _, vol := engine.transform_get_comp(single_h, cad_csg.CSGVolume); vol != nil && vol.enabled {
			if im.BeginMenu("CSG Volume Quick Actions") {
				if im.MenuItem("Center Pivot to Geometry") {
					_ensure_init()
					_ensure_mesh_ed_init()
					csg_history_ensure_baseline(vol)
					if cad_csg.csg_volume_recenter_pivot(vol) {
						csg_history_commit(vol)
					}
				}
				if im.MenuItem("Drop Bottom to Ground (Y = 0)") {
					_ensure_init()
					_ensure_mesh_ed_init()
					_ = cad_csg.csg_volume_drop_to_ground(vol, 0.0)
				}
				if len(vol.brushes) > 1 {
					if im.MenuItem("Move '-' Subtract Cuts to End of Stack") {
						_ensure_init()
						_ensure_mesh_ed_init()
						csg_history_ensure_baseline(vol)
						if cad_csg.csg_volume_move_subtracts_to_end(vol) > 0 {
							csg_history_commit(vol)
						}
					}
					if im.MenuItem(fmt.ctprintf("Split %d Brushes -> Separate CSG Volumes", len(vol.brushes))) {
						_ensure_init()
						_ensure_mesh_ed_init()
						csg_history_ensure_baseline(vol)
						_ = cad_csg.csg_split_all_brushes_to_volumes(vol, false)
						_ed.selected_brush_idx = 0
						deactivate_cad_tool()
					}
				}
				if im.MenuItem("Smart Clean & Simplify Coplanar Hulls") {
					_ensure_init()
					_ensure_mesh_ed_init()
					csg_history_ensure_baseline(vol)
					_ = cad_csg.csg_volume_smart_clean_and_simplify(vol)
					csg_history_commit(vol)
				}
				im.Separator()
				if im.MenuItem("Bake CSG -> Static Mesh Object") {
					_ = cad_csg.csg_volume_bake_to_static_mesh(vol)
				}
				im.EndMenu()
			}
			im.Separator()
		}
	}
}
