package cad_csg

// Component definitions for the CAD Blockout & Red Faction Destructible CSG System.
//
// `CSGVolume` stores an authored hierarchy of non-destructive CAD brushes (`CSG_Brush`),
// partitioned at compile/runtime into 8m x 8m x 8m Spatial CSG Chunks (`CSG_Chunk`)
// with an SOA AABB broadphase array (`brush_aabbs`) for cache-friendly culling.

import jolt "moonhug:external/jolt"
import engine "moonhug:engine"
import gfx "moonhug:engine/gfx"

CSG_DEFAULT_CHUNK_SIZE :: f32(8.0)

Debris_Collider_Mode :: enum u8 {
	Drunken_Sphere = 0, // SphereShape + OffsetCenterOfMassShape + high AngularDamping (wobbles & settles like a rock at 1/10th GJK cost)
	Convex_Hull    = 1, // 8-to-12 vertex ConvexHullShape with 0.03m convexRadius
	Box_Primitive  = 2, // Fast OBB BoxShape
}

// Physical & Destructible Material Presets for the Material Properties DataTable:
// Governs yield force required to break/shatter, crater radius scaling, fracture pattern,
// glass/ice translucency & cascade shatter threshold, and Soft Deformer Body parameters.
CSG_Material_Preset :: enum u8 {
	Concrete            = 0, // Standard structural concrete (medium yield force, Voronoi chunks)
	Reinforced_Concrete = 1, // Rebar-reinforced bunker concrete (high yield force, shallow spalling craters)
	Brick_Masonry       = 2, // Clay brick wall (low-medium yield force, stepped block fracture)
	Tempered_Glass      = 3, // See-through architectural glass (low yield force, concentric spiderweb shatter)
	Reinforced_Glass    = 4, // Laminated / wire-mesh security glass (high yield force, local punch hole only)
	Sheet_Ice           = 5, // Translucent brittle ice (very low yield force, wide crystalline shard shatter, low friction)
	Wood_Plank          = 6, // Timber / structural wood (splintering slabs)
	Steel_Plate         = 7, // Heavy armor steel (very high yield force, plastic denting via Soft Deformer)
	Soft_Metal_Panel    = 8, // Deformable sheet metal / vehicle hull / blast panel (plastic + elastic coordinate-offset denting)
	Soft_Rubber_Gel     = 9, // Elastic soft-body cushion / bumper (deep elastic coordinate-offset bounce-back)
}

// Fracture cleavage & damage response behavior in the Material Properties DataTable.
CSG_Fracture_Pattern :: enum u8 {
	Voronoi_Chunks       = 0, // Standard Red Faction faceted polyhedral crater
	Concentric_Spiderweb = 1, // Tempered glass radial/concentric shatter
	Crystalline_Shards   = 2, // Brittle ice / crystal wide-angle cleavage
	Rebar_Held_Cracks    = 3, // Reinforced concrete shallow spall crater
	Wired_Local_Hole     = 4, // Reinforced glass local punch-through without full pane collapse
	Block_Masonry        = 5, // Stepped brick/block fracture
	Splinter_Slabs       = 6, // Elongated wood splintering
	Plastic_Dent_Only    = 7, // Resists boolean cutting below yield force; deforms via Soft Deformer Coordinate Offset!
}

// Soft Deformer Brush / Impact Mode for vertex & UV-texture coordinate-offset deformation (`p' = p + Δp(x, t)`).
CSG_Soft_Deform_Mode :: enum u8 {
	Dent_Inward      = 0, // Pushes surface inward along -Normal with subtle radial rim bulge
	Bulge_Outward    = 1, // Pulls/bulges surface outward along +Normal
	Shockwave_Ripple = 2, // Damped sinusoidal concentric wave ring
	Twist_Shear      = 3, // Tangential swirl / shear displacement in the surface plane
}

// One active Soft Deformer coordinate-offset impulse stamp in volume-local space (`RAM-only` runtime state).
// Deforms rendered visual vertices & the 2D Deformation Offset Texture (`p' = p + Δp`) with spring-damper
// elastic recovery + permanent plastic denting while the underlying Jolt CSG collision stays 100% unchanged!
CSG_Soft_Deform_Stamp :: struct {
	local_pos:      [3]f32,
	local_normal:   [3]f32,
	radius:         f32,
	plastic_depth:  f32, // Permanent plastic dent depth in meters
	elastic_depth:  f32, // Transient elastic displacement in meters (oscillates & decays via spring-damper)
	elastic_vel:    f32, // Current elastic velocity (m/s)
	stiffness:      f32, // Hooke spring constant k
	damping:        f32, // Damping / recovery rate c
	mode:           CSG_Soft_Deform_Mode,
	age:            f32,
}

// Recorded runtime blast so rebuilding CSG (when `preserve_craters_on_rebuild` is true)
// keeps all carved craters intact unless the user explicitly clicks "Reset Craters".
CSG_Recorded_Blast :: struct {
	local_pos: [3]f32,
	radius:    f32,
	seed:      u32,
	mat_slot:  u8,
	color:     [4]u8,
}

// One authored CAD / CSG brush in a `CSGVolume`'s local space.
CSG_Brush :: struct {
	id:              u32,
	name:            string,
	op:              Brush_Op,
	primitive:       Brush_Primitive,
	material_preset: CSG_Material_Preset, // Physical & destructible material row from DataTable
	center:          [3]f32,
	size:            [3]f32, // Full width (X), height (Y), depth (Z) in meters
	yaw_deg:         f32,    // Rotation around Y in degrees
	uv_scale:        f32,    // Metric UV tiling scale
	uv_offset:       [2]f32, // Tangent-space UV offset (U, V) (RealtimeCSG TexGen)
	uv_rot_deg:      f32,    // Tangent-space UV rotation in degrees (RealtimeCSG TexGen)
	uv_lock_brush:   bool,   // false (default) = World-Locked seamless tiling; true = Brush/Hull-centroid locked
	color:           [4]u8,  // RGBA vertex color tint
	destructible:    bool,   // Can runtime Red Faction blasts carve this brush?
	anchored:        bool,   // Foundation anchor (prevents structural island collapse)

	// 2D Polyline / Catmull-Rom Spline Extrusion fields (used when `primitive == .Profile_2D`)
	profile_points:  [dynamic]CSG_Profile_Point,
	plane_normal:    [3]f32,
	plane_u:         [3]f32,
	plane_v:         [3]f32,
	extrude_height:  f32,
}

CSG_VOXEL_RES   :: 24
CSG_VOXEL_PTS   :: CSG_VOXEL_RES + 1
CSG_BRICK_DIM   :: CSG_VOXEL_RES / 4 // 6 bricks per axis (each brick is 4x4x4 = 64 cells = 1 u64!)
CSG_BRICK_COUNT :: CSG_BRICK_DIM * CSG_BRICK_DIM * CSG_BRICK_DIM // 216 u64 bricks per chunk

CSG_Destruction_Backend :: enum u8 {
	Lazy_Voxel_SDF  = 0, // Severed Steel Mode (Default): Pristine chunks stay exact polygons; blasted chunks convert on demand to O(1) 24^3 Voxel SDF + Surface Nets & Greedy Box Jolt colliders!
	Pure_Convex_CSG = 1, // Classic Half-Space Convex Polyhedron boolean splitting
}

// Per-chunk 24^3 Signed Distance Field (SDF) Voxel Grid for O(1) Severed Steel crater carving (~39 KB total, fits in L1/L2 cache!).
// Accelerated by 64-bit `u64` 4x4x4 Brick Bitmasks (`surface_bricks`, `solid_bricks`, `cut_bricks`) + 4-bit nibble-packed materials.
// Automatically turns any blasted CSG chunk into a self-hosted `.fmesh`:
// - `base_shell_verts` / `base_shell_indices` retain the razor-sharp original CSG outer shell (clipped against `cut_sdf <= 0`),
// - `sdf` + Surface Nets (`mat_slot == 1`, clipped inside `base_shell_hulls`) provide the 3D rocky crater/tunnel interior and Jolt collision!
CSG_Voxel_Grid :: struct {
	// 8-byte aligned dynamic arrays & 64-bit `u64` 4x4x4 Brick Bitmasks (1 bit per voxel cell = 64 cells per u64!)
	base_shell_verts:         [dynamic]gfx.Vertex,
	base_shell_indices:       [dynamic]u32,
	base_shell_hulls:         [dynamic]CSG_Convex,
	surface_bricks:           [CSG_BRICK_COUNT]u64, // Bit `b` = 1 iff cell crosses `sdf == 0` isosurface (`0 < neg_corners < 8`)
	cut_bricks:               [CSG_BRICK_COUNT]u64, // Bit `b` = 1 iff cell is within the active cut narrow-band (`cut_sdf > -48`)

	// 4-byte aligned f32 & u32 fields + 32-bit row bitmasks for 1-cycle bitwise flood-fill BFS & brick mask generation
	origin:                   [3]f32, // Local chunk minimum corner
	voxel_size:               f32,    // Size of 1 voxel cell in meters (chunk_span / 24.0)
	uv_scale:                 f32,
	cut_aabb_min:             [3]f32, // Tight local AABB of all carved blasts/slices for fast O(1) outer-shell triangle culling
	cut_aabb_max:             [3]f32,
	base_shell_slot0_count:   u32,
	base_shell_submeshes:     [8]engine.Mesh_Submesh,
	pt_solid_rows:            [CSG_VOXEL_PTS * CSG_VOXEL_PTS]u32, // Bit `x` = 1 iff `sdf[x,y,z] <= 0`

	// 1-byte aligned SDF & 4-bit packed material arrays (zero internal padding!)
	// Corner-sampled Signed Distance Field (`25 x 25 x 25`), quantized to `i8` where:
	// `< 0` = inside solid, `> 0` = outside air, `0` = exact isosurface (`1 unit = voxel_size / 24.0`)
	sdf:                      [CSG_VOXEL_PTS * CSG_VOXEL_PTS * CSG_VOXEL_PTS]i8,
	// Pure Carving / Hole SDF (`25 x 25 x 25`), quantized to `i8` where:
	// `< 0` = untouched by any blast/slice, `> 0` = carved away by a blast/slice, `0` = exact crater rim!
	cut_sdf:                  [CSG_VOXEL_PTS * CSG_VOXEL_PTS * CSG_VOXEL_PTS]i8,
	// 4-bit nibble-packed per-cell (`24 x 24 x 24 / 2 = 6,912` bytes) palette entry ID (`0..15`, 2 cells per byte!)
	mat_packed:               [(CSG_VOXEL_RES * CSG_VOXEL_RES * CSG_VOXEL_RES) / 2]u8,
	palette_colors:           [16][4]u8,
	palette_mat_slots:        [16]u8,
	base_color:               [4]u8, // Default outer chunk RGBA tint
	cut_color:                [4]u8, // Carved crater / scorch RGBA tint
	palette_count:            u8,
	base_shell_submesh_count: u8,
	has_cuts:                 bool,
}

// One 8m x 8m x 8m spatial cell inside a `CSGVolume` (like a Voxel Chunk, but for exact CSG polyhedra).
// Owns its local convex polyhedra (or lazy-allocated Severed Steel `voxel_grid`), cached triangulated vertices/indices,
// its own per-chunk GPU mesh GUID, and its own Jolt static BodyID.
CSG_Chunk :: struct {
	coord:                [3]i32,
	aabb_min:             [3]f32,
	aabb_max:             [3]f32,
	destructible_hulls:   [dynamic]CSG_Convex,
	indestructible_hulls: [dynamic]CSG_Convex,
	voxel_grid:           ^CSG_Voxel_Grid,
	verts:                [dynamic]gfx.Vertex,
	indices:              [dynamic]u32,
	submeshes:            [dynamic]engine.Mesh_Submesh,
	chunk_mesh_guid:      engine.Asset_GUID,
	jolt_shape:           ^jolt.Shape,
	static_body:          jolt.BodyID,
	dirty_physics:        bool,
	dirty_gpu:            bool,
}

// ============================================================================
// PILLAR 2: CSG-BOUND MESH INSTANCE DECORATOR ("GOTHIC WALL / KITBASH LAYER")
// ============================================================================
// Purely visual architectural detail instances (`CSG_Detail_Instance`) attached to CSG surfaces.
// - Zero Jolt physics collider overhead (`just for show`), batched into the volume's GPU render pass.
// - Automatically coupled to CSG destruction in RAM: when a Geo-Mod blast or 2-Point Clip Plane
//   removes the backing CSG hull, unsupported detail instances set `destroyed_in_ram = true` and
//   pop off as short-lived cosmetic debris on `physics3d.LAYER_DEBRIS_COSMETIC`!

CSG_Detail_Preset :: enum u8 {
	Gothic_Pillar         = 0, // Fluted octagonal Gothic stone column with base plinth & capital
	Gothic_Pointed_Arch   = 1, // Pointed Gothic vault arch with keystone
	Wall_Buttress         = 2, // Stepped flying/wall buttress pilaster
	Ribbed_Trim_Beam      = 3, // Carved stone cornice / frieze molding beam
	Stone_Cornice_Bracket = 4, // Corbel / gargoyle support bracket
	Iron_Window_Grate     = 5, // Decorative iron bar lattice for windows & vents
	Custom_Mesh_Asset     = 6, // Any external project Mesh Asset GUID (`.obj` / `.gltf`)
}

CSG_Detail_Instance :: struct {
	id:                  u32,
	name:                string,
	preset:              CSG_Detail_Preset,
	custom_mesh:         engine.Asset_GUID,
	local_pos:           [3]f32,
	local_normal:        [3]f32,
	yaw_deg:             f32,
	scale:               [3]f32,
	color:               [4]u8,
	pop_debris_on_blast: bool,

	// Runtime-only state in RAM (never written to `.scene` on disk; reset on scene reload / Reset Destruction!)
	destroyed_in_ram:    bool `json:"-" inspect:"-"`,
}

// ============================================================================
// PILLAR 3: VALVE-STYLE 2D SHATTERABLE TEMPERED GLASS (`CSG_Glass_Pane`)
// ============================================================================
// 2D grid/Voronoi shatterable glass pane mounted in CSG window cutouts.
// - Registers a thin static Jolt box collider on `physics3d.LAYER_GLASS_FENESTRATION` (`3`):
//   • Blocks player & dynamic prop movement while intact
//   • Transparent to AI Vision / Line-of-Sight (`physics3d.MASK_VISION_LOS`)
//   • Intercepted & shattered by Weapon / Ballistic traces (`physics3d.MASK_WEAPON_TRACE`) and Geo-Mod blasts!

CSG_Glass_Pane :: struct {
	id:                   u32,
	name:                 string,
	material_preset:      CSG_Material_Preset, // Tempered_Glass (default), Reinforced_Glass, or Sheet_Ice
	center:               [3]f32,
	size_2d:              [2]f32, // Bounding Width (U) and Height (V) in meters
	thickness:            f32,    // Default 0.04m
	normal:               [3]f32,
	u_axis:               [3]f32,
	v_axis:               [3]f32,
	cells_x:              i32,    // Grid columns (default 6)
	cells_y:              i32,    // Grid rows (default 4)
	color:                [4]u8,  // RGBA tint (default `{150, 225, 245, 72}`)
	cutout_brush_id:      u32,    // Optional paired `.Subtract` window cutout brush ID for live resizing
	poly_points_2d:       [dynamic][2]f32, // Optional custom 2D polygon loop in (u_axis, v_axis) meters relative to `center`

	// Runtime-only state in RAM (never written to `.scene` on disk; restored on scene reload / Reset Destruction!)
	shattered_cells:      [dynamic]bool   `json:"-" inspect:"-"`,
	shatter_impacts:      [dynamic][4]f32 `json:"-" inspect:"-"`, // (u_m, v_m, hole_radius_m, seed) for radial spiderweb fracture!
	completely_shattered: bool            `json:"-" inspect:"-"`,
	glass_body:           jolt.BodyID     `json:"-" inspect:"-"`,
	glass_shape:          ^jolt.Shape     `json:"-" inspect:"-"`,
	dirty_physics:        bool            `json:"-" inspect:"-"`,
}

CSG_Faker_Shape :: enum u8 {
	Auto_Convex_Hull = 0, // Tight 3D convex hull fitted around the mesh vertices + margin
	Oriented_Box     = 1, // Box CSG brush fitted around the mesh AABB + margin
	Tapered_Blade    = 2, // Wedge / Dagger blade CSG brush + margin
	Cylinder_Hull    = 3, // Cylinder CSG brush + margin
}

// How a 3D Mesh (or posed Skeletal Character / Statue) is decomposed & wrapped into a `CSGVolume`!
CSG_Mesh_Wrap_Mode :: enum u8 {
	Exact_Face_Decompose  = 0, // Current Make CSG: Exact Concave-Plane Partitioning + 5-Ray Interior Classifier
	Single_Bounding_Hull  = 1, // Fast 1-Hull Beveled k-DOP Envelope wrapping the whole mesh
	Multi_Ray_Line_Trace  = 2, // Async Multi-Angle Line-Trace Sculptor: Fires a 3D grid of line traces across X/Y/Z + grazing rays to sculpt tight CSG spans
	Anatomy_Sliced_Statue = 3, // Humanoid / Statue Sliced Line-Trace: Slices mesh into vertical/anatomical bands and fits ray-traced CSG hulls per section
}

@(component={menu="CSG/CSGVolume"})
@(typ_guid={guid = "a48c7e21-9b34-4d12-8f65-3c91a7b4e210"})
CSGVolume :: struct {
	using base:                  engine.CompData `inspect:"-"`,
	chunk_size:                  f32,
	ground_y:                    f32,
	material_preset:             CSG_Material_Preset,
	blast_resistance:            f32, // Custom resistance multiplier (default 1.0; >1.0 = harder to break, <1.0 = easier to break)
	custom_material_guid:        engine.Asset_GUID `inspect:"-"`,
	soft_deform_enabled:         bool,
	deform_debug_heatmap:        bool `json:"-" inspect:"-"`,
	enable_structural_collapse:  bool,
	spawn_debris:                bool `inspect:"-"`,
	preserve_craters_on_rebuild: bool,
	is_dynamic_rigidbody:        bool,
	cast_planar_shadows:         bool,
	debris_collider_mode:        Debris_Collider_Mode `inspect:"-"`,
	next_brush_id:               u32 `inspect:"-"`,
	brushes:                     [dynamic]CSG_Brush,

	// "Faker Mesh" Hybrid Pairing:
	// Inner Mesh `A` (ALWAYS an instance via `faker_mesh_guid`) wrapped inside slightly larger CSG Collider `B` (`+faker_margin`).
	// Rule: If A is inside B, render A; if any part of B cuts inside A (boolean cut/blast/slice), render that interior cut part as B!
	is_faker_mesh:               bool,
	destruction_backend:         CSG_Destruction_Backend,
	faker_mesh_guid:             engine.Asset_GUID `inspect:"-"`,
	faker_material_guid:         engine.Asset_GUID `inspect:"-"`,
	faker_cut_material_guid:     engine.Asset_GUID `inspect:"-"`, // Optional override material/texture for sliced/blasted interior (empty = fallback to mesh's own material!)
	cut_material_palette:        [dynamic]engine.Asset_GUID `inspect:"-"`, // Per-destruction material slots `1..7` so each cut/blast keeps its own texture!
	faker_shape_kind:            CSG_Faker_Shape,
	faker_margin:                f32, // How much larger CSG collider B is than inner mesh A (default +0.04m)
	faker_mesh_scale:            [3]f32,
	faker_mesh_offset:           [3]f32,
	faker_mesh_rot_deg:          [3]f32, // Local Euler rotation (Pitch, Yaw, Roll in degrees) of the inner Mesh Instance inside the CSGVolume
	faker_hide_outer_shell:      bool, // Hide B's outer shell where it encloses A; only render B where B cuts inside A
	faker_render_cut_interior:   bool, // Render B's interior cut faces where B enters inside A's bounds
	faker_transfer_dents:        bool, // Transfer CSG soft-deformer dents/warps onto the Faker Mesh
	faker_split_on_slice:        bool, // Split Faker Mesh when CSG B is sliced or severed
	faker_prune_empty_lips:      bool, // Automatically slice off hanging CSG lips/hulls that have no or almost no mesh inside them
	is_ghoul_bone_csg:           bool, // True when attached to a skeletal rig bone for Ghoul CSG dismemberment/slicing/blasting

	// Saved source Mesh / Material metadata when converted from a Mesh via `Turn Mesh -> CSG`,
	// enabling 1-click "Undo / Revert CSG -> Original Mesh" and live switching between CSG Wrap Modes!
	converted_from_mesh:         bool              `json:"-" inspect:"-"`,
	orig_source_mesh_guid:       engine.Asset_GUID `json:"-" inspect:"-"`,
	orig_source_mat_guid:        engine.Asset_GUID `json:"-" inspect:"-"`,

	// Pillar 2 & 3 Level Composition Recipe (persisted in `.scene` on disk; runtime mutations stay in RAM!)
	detail_instances:            [dynamic]CSG_Detail_Instance `inspect:"-"`,
	glass_panes:                 [dynamic]CSG_Glass_Pane      `inspect:"-"`,

	// Baked / converted convex hulls & recorded blast craters (persisted in .scene for Scene Composition!)
	runtime_hulls:               [dynamic]CSG_Convex         `inspect:"-"`, // Pre-carved / baked hulls (from Mesh->CSG, Bake CSG, or detached islands)
	recorded_blasts:             [dynamic]CSG_Recorded_Blast `inspect:"-"`,

	// Runtime Soft Deformer Coordinate-Offset Stamps (`p' = p + Δp(x, t)` in RAM while CSG collision stays unchanged!)
	soft_deform_stamps:          [dynamic]CSG_Soft_Deform_Stamp `json:"-" inspect:"-"`,

	// Runtime / SOA broadphase state (never serialized to JSON)
	brush_aabbs:                 [dynamic][2][3]f32          `json:"-" inspect:"-"`,
	chunks:                      map[[3]i32]^CSG_Chunk       `json:"-" inspect:"-"`,
	mesh_guid:                   engine.Asset_GUID           `json:"-" inspect:"-"`,
	shadow_mesh_guid:            engine.Asset_GUID           `json:"-" inspect:"-"`,
	compiled:                    bool                        `json:"-" inspect:"-"`,
	gpu_dirty:                   bool                        `json:"-" inspect:"-"`,
	physics_world_id:            u64                         `json:"-" inspect:"-"`,
	dynamic_body:                jolt.BodyID                 `json:"-" inspect:"-"`,
	dynamic_shape:               ^jolt.Shape                 `json:"-" inspect:"-"`,
	last_physics_pos:            [3]f32                      `json:"-" inspect:"-"`,
	last_physics_rot:            [4]f32                      `json:"-" inspect:"-"`,
	has_physics_sync:            bool                        `json:"-" inspect:"-"`,
}

reset_CSGVolume :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	csg_volume_free_runtime(vol, true)
	if vol.runtime_hulls != nil {
		for &h in vol.runtime_hulls do convex_destroy(&h)
		delete(vol.runtime_hulls)
		vol.runtime_hulls = nil
	}
	if vol.brushes != nil {
		for &b in vol.brushes {
			if len(b.name) > 0 do delete(b.name)
			if b.profile_points != nil do delete(b.profile_points)
		}
		delete(vol.brushes)
		vol.brushes = nil
	}
	if vol.detail_instances != nil {
		for &inst in vol.detail_instances {
			if len(inst.name) > 0 do delete(inst.name)
		}
		delete(vol.detail_instances)
		vol.detail_instances = nil
	}
	if vol.glass_panes != nil {
		for &gp in vol.glass_panes {
			if len(gp.name) > 0 do delete(gp.name)
			if gp.poly_points_2d != nil do delete(gp.poly_points_2d)
			if gp.shattered_cells != nil do delete(gp.shattered_cells)
			if gp.shatter_impacts != nil do delete(gp.shatter_impacts)
		}
		delete(vol.glass_panes)
		vol.glass_panes = nil
	}
	if vol.soft_deform_stamps != nil {
		delete(vol.soft_deform_stamps)
		vol.soft_deform_stamps = nil
	}
	if vol.cut_material_palette != nil {
		delete(vol.cut_material_palette)
		vol.cut_material_palette = nil
	}
	if vol.recorded_blasts != nil {
		delete(vol.recorded_blasts)
		vol.recorded_blasts = nil
	}
	vol.chunk_size = CSG_DEFAULT_CHUNK_SIZE
	vol.ground_y = 0.0
	vol.material_preset = .Concrete
	vol.blast_resistance = 1.0
	vol.custom_material_guid = {}
	vol.soft_deform_enabled = false
	vol.deform_debug_heatmap = false
	vol.is_faker_mesh = false
	vol.destruction_backend = .Lazy_Voxel_SDF
	vol.is_ghoul_bone_csg = false
	vol.faker_mesh_guid = {}
	vol.faker_material_guid = {}
	vol.faker_cut_material_guid = {}
	vol.faker_shape_kind = .Auto_Convex_Hull
	vol.faker_margin = 0.04
	vol.faker_mesh_scale = {1, 1, 1}
	vol.faker_mesh_offset = {0, 0, 0}
	vol.faker_mesh_rot_deg = {0, 0, 0}
	vol.faker_hide_outer_shell = true
	vol.faker_render_cut_interior = true
	vol.faker_transfer_dents = true
	vol.faker_split_on_slice = true
	vol.faker_prune_empty_lips = true
	vol.enable_structural_collapse = true
	vol.spawn_debris = false
	vol.preserve_craters_on_rebuild = false
	vol.is_dynamic_rigidbody = false
	vol.cast_planar_shadows = true
	vol.debris_collider_mode = .Drunken_Sphere
	vol.next_brush_id = 1
	vol.compiled = false
	vol.gpu_dirty = false
}

on_validate_CSGVolume :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	vol.spawn_debris = false
	vol.compiled = false
}

on_destroy_CSGVolume :: proc(vol: ^CSGVolume) {
	cleanup_CSGVolume(vol)
}

cleanup_CSGVolume :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	csg_volume_free_runtime(vol, true)
	if vol.runtime_hulls != nil {
		for &h in vol.runtime_hulls do convex_destroy(&h)
		delete(vol.runtime_hulls)
		vol.runtime_hulls = nil
	}
	if vol.brushes != nil {
		for &b in vol.brushes {
			if len(b.name) > 0 do delete(b.name)
			if b.profile_points != nil do delete(b.profile_points)
		}
		delete(vol.brushes)
		vol.brushes = nil
	}
	if vol.detail_instances != nil {
		for &inst in vol.detail_instances {
			if len(inst.name) > 0 do delete(inst.name)
		}
		delete(vol.detail_instances)
		vol.detail_instances = nil
	}
	if vol.glass_panes != nil {
		for &gp in vol.glass_panes {
			if len(gp.name) > 0 do delete(gp.name)
			if gp.poly_points_2d != nil do delete(gp.poly_points_2d)
			if gp.shattered_cells != nil do delete(gp.shattered_cells)
			if gp.shatter_impacts != nil do delete(gp.shatter_impacts)
		}
		delete(vol.glass_panes)
		vol.glass_panes = nil
	}
	if vol.soft_deform_stamps != nil {
		delete(vol.soft_deform_stamps)
		vol.soft_deform_stamps = nil
	}
	if vol.cut_material_palette != nil {
		delete(vol.cut_material_palette)
		vol.cut_material_palette = nil
	}
	if vol.recorded_blasts != nil {
		delete(vol.recorded_blasts)
		vol.recorded_blasts = nil
	}
	engine.comp_zero(vol)
}

csg_volumes :: c_s_g_volumes


