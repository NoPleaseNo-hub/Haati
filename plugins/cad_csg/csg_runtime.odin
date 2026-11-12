package cad_csg

// Runtime Compiler, Async Worker Thread, Batched JoltC Collider Swapper,
// Debris Spawner ("Drunken Sphere" & 8-Vert Convex Hull), and Red Faction
// Visual Latency Masking for `CSGVolume`.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:thread"
import "core:time"
import jolt "moonhug:external/jolt"
import engine "moonhug:engine"
import gfx "moonhug:engine/gfx"
import "moonhug:engine/gizmos"
import physics3d "moonhug:packages/physics3d"

// ============================================================================
// PROJECT SETTINGS (`Edit -> Project Settings -> CAD & Destructible CSG`)
// ============================================================================

CAD_CSG_Settings :: struct {
	async_destruction_worker:      bool, // Offloads boolean crater carving + JoltC shape cooking to background worker thread
	default_chunk_size:            f32,
	max_chunk_swaps_per_tick:      i32,
	blast_jaggedness:              f32,
	debris_count_per_blast:        i32  `inspect:"-"`,
	debris_lifetime_sec:           f32  `inspect:"-"`,
	drunken_sphere_com_offset:     f32  `inspect:"-"`,
	drunken_sphere_ang_damp:       f32  `inspect:"-"`,
	blast_fx_duration_sec:         f32,

	// Configurable & Disableable CAD Mode Keybindings (never active outside CAD mode or while holding RMB!)
	enable_all_keybindings:        bool, // Master toggle to enable/disable all CAD keyboard shortcuts
	enable_transform_tool_hotkeys: bool, // Q/W/E/R/T tool switching (only in CAD mode, never in Play mode or RMB fly)
	enable_subtool_number_hotkeys: bool, // 1/2/3/4 sub-tool & vertex/edge/face mode hotkeys
	enable_axis_lock_hotkeys:      bool, // X/Y/Z/N/G axis constraint & boolean flip hotkeys
	enable_modeling_op_hotkeys:    bool, // Shift+E Extrude, I Inset, B Bevel/Blast, O Pivot, A Select All, [ ] Radius
}

@(project_settings={name="CAD & Destructible CSG"})
csg_settings := CAD_CSG_Settings{
	async_destruction_worker      = true,
	default_chunk_size            = 8.0,
	max_chunk_swaps_per_tick      = 4,
	blast_jaggedness              = 0.14,
	debris_count_per_blast        = 0,
	debris_lifetime_sec           = 6.0,
	drunken_sphere_com_offset     = 0.38,
	drunken_sphere_ang_damp       = 6.5,
	blast_fx_duration_sec         = 0.45,
	enable_all_keybindings        = true,
	enable_transform_tool_hotkeys = true,
	enable_subtool_number_hotkeys = true,
	enable_axis_lock_hotkeys      = true,
	enable_modeling_op_hotkeys    = true,
}

// ============================================================================
// ASYNC WORKER & VISUAL LATENCY MASKING STATE
// ============================================================================

CSG_Async_Chunk_Input :: struct {
	coord:                [3]i32,
	aabb_min:             [3]f32,
	aabb_max:             [3]f32,
	destructible_hulls:   [dynamic]CSG_Convex,
	indestructible_hulls: [dynamic]CSG_Convex,
	voxel_grid:           ^CSG_Voxel_Grid,
}

CSG_Async_Blast_Job :: struct {
	volume_owner:      engine.Transform_Handle,
	world_id:          u64,
	local_blast_pos:   [3]f32,
	world_blast_pos:   [3]f32,
	blast_radius:      f32,
	blast_impulse:     f32,
	blast_jaggedness:  f32,
	scorch_color:      [4]u8,
	blast_mat_slot:    u8,
	ground_y:          f32,
	collapse_islands:  bool,
	spawn_debris:      bool,
	debris_mode:       Debris_Collider_Mode,
	cook_jolt_shapes:  bool,
	use_voxel_sdf:     bool,
	seed:              u32,
	touched_chunks:    [dynamic]CSG_Async_Chunk_Input,
}

CSG_Async_Chunk_Output :: struct {
	coord:                [3]i32,
	destructible_hulls:   [dynamic]CSG_Convex,
	indestructible_hulls: [dynamic]CSG_Convex,
	voxel_grid:           ^CSG_Voxel_Grid,
	detached_islands:     [dynamic]CSG_Convex,
	verts:                [dynamic]gfx.Vertex,
	indices:              [dynamic]u32,
	submeshes:            [dynamic]engine.Mesh_Submesh,
	cooked_shape:         ^jolt.Shape,
}

CSG_Async_Blast_Result :: struct {
	volume_owner:    engine.Transform_Handle,
	world_id:        u64,
	world_blast_pos: [3]f32,
	blast_radius:    f32,
	blast_impulse:   f32,
	spawn_debris:    bool,
	debris_mode:     Debris_Collider_Mode,
	seed:            u32,
	chunk_outputs:   [dynamic]CSG_Async_Chunk_Output,
}

// Red Faction style immediate visual explosion/dust effect (masks 1-2 frame async CSG swap)
CSG_Blast_FX :: struct {
	world_pos: [3]f32,
	radius:    f32,
	age:       f32,
	duration:  f32,
	seed:      u32,
}

// Live dynamic debris entity tracked for automatic cleanup after `debris_lifetime_sec`
CSG_Active_Debris :: struct {
	tH:        engine.Transform_Handle,
	mesh_guid: engine.Asset_GUID,
	body_id:   jolt.BodyID,
	shape:     ^jolt.Shape,
	ttl:       f32,
}

@(private = "file")
_worker_state: struct {
	mutex:        sync.Mutex,
	running:      bool,
	busy:         bool,
	stop_flag:    bool,
	worker:       ^thread.Thread,
	pending_jobs: [dynamic]CSG_Async_Blast_Job,
	results:      [dynamic]CSG_Async_Blast_Result,
	blast_fx:     [dynamic]CSG_Blast_FX,
	debris_list:  [dynamic]CSG_Active_Debris,
	blast_Links:  u32,
}

// Deterministic procedural mesh GUID from a Transform_Handle and salt
make_procedural_guid :: proc(tH: engine.Transform_Handle, salt: u32 = 0) -> engine.Asset_GUID {
	raw: [16]u8
	h_bits := transmute(u64)tH
	// Prefix "CSG!"
	raw[0] = 0x43
	raw[1] = 0x53
	raw[2] = 0x47
	raw[3] = 0x21
	for i in 0 ..< 8 {
		raw[4 + i] = u8((h_bits >> (uint(i) * 8)) & 0xFF)
	}
	for i in 0 ..< 4 {
		raw[12 + i] = u8((salt >> (uint(i) * 8)) & 0xFF)
	}
	return engine.Asset_GUID(raw)
}

// Deterministic per-chunk procedural GPU mesh GUID from the owner Transform_Handle and 3D chunk coordinate
@(private = "file")
_make_chunk_procedural_guid :: proc(tH: engine.Transform_Handle, coord: [3]i32) -> engine.Asset_GUID {
	h: u32 = 2166136261
	h = (h ~ u32(coord.x)) * 16777619
	h = (h ~ u32(coord.y)) * 16777619
	h = (h ~ u32(coord.z)) * 16777619
	if h < 10 do h += 10
	return make_procedural_guid(tH, h)
}

// ============================================================================
// CHUNK & VOLUME MEMORY MANAGEMENT
// ============================================================================

@(private = "file")
_chunk_free :: proc(chunk: ^CSG_Chunk, destroy_jolt_body := true) {
	if chunk == nil do return
	context.allocator = runtime.default_allocator()
	for &h in chunk.destructible_hulls do convex_destroy(&h)
	delete(chunk.destructible_hulls)
	for &h in chunk.indestructible_hulls do convex_destroy(&h)
	delete(chunk.indestructible_hulls)
	if chunk.voxel_grid != nil {
		csg_voxel_grid_free(chunk.voxel_grid)
		chunk.voxel_grid = nil
	}
	delete(chunk.verts)
	delete(chunk.indices)
	delete(chunk.submeshes)
	if !engine.asset_guid_is_empty(chunk.chunk_mesh_guid) {
		engine.mesh_remove_procedural(chunk.chunk_mesh_guid)
		chunk.chunk_mesh_guid = {}
	}

	if destroy_jolt_body && physics3d.is_body_valid(chunk.static_body) {
		if physics3d._state.world_ready && physics3d._state.body_interface != nil {
			bi := physics3d._state.body_interface
			if jolt.BodyInterface_IsAdded(bi, chunk.static_body) {
				jolt.BodyInterface_RemoveBody(bi, chunk.static_body)
			}
			jolt.BodyInterface_DestroyBody(bi, chunk.static_body)
		}
		chunk.static_body = 0
	}
	if chunk.jolt_shape != nil {
		if physics3d._state.world_ready {
			delete_key(&physics3d._state.shape_owner, uintptr(chunk.jolt_shape))
		}
		jolt.Shape_Destroy(chunk.jolt_shape)
		chunk.jolt_shape = nil
	}
	free(chunk)
}

csg_volume_free_runtime :: proc(vol: ^CSGVolume, clear_recorded_blasts := false) {
	if vol == nil do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if vol.chunks != nil {
		for _, ch in vol.chunks {
			_chunk_free(ch, true)
		}
		delete(vol.chunks)
		vol.chunks = nil
	}
	if vol.brush_aabbs != nil {
		delete(vol.brush_aabbs)
		vol.brush_aabbs = nil
	}
	if clear_recorded_blasts && vol.recorded_blasts != nil {
		delete(vol.recorded_blasts)
		vol.recorded_blasts = nil
	}
	if clear_recorded_blasts && vol.soft_deform_stamps != nil {
		delete(vol.soft_deform_stamps)
		vol.soft_deform_stamps = nil
	}
	for &gp in vol.glass_panes {
		_free_glass_pane_runtime(&gp)
	}
	if vol.owner != {} {
		dg_guid := make_detail_and_glass_guid(vol.owner)
		if !engine.asset_guid_is_empty(dg_guid) {
			engine.mesh_remove_procedural(dg_guid)
		}
		gp_guid := make_glass_pane_guid(vol.owner)
		if !engine.asset_guid_is_empty(gp_guid) {
			engine.mesh_remove_procedural(gp_guid)
		}
	}
	if physics3d.is_body_valid(vol.dynamic_body) {
		if physics3d._state.world_ready && physics3d._state.body_interface != nil {
			bi := physics3d._state.body_interface
			if jolt.BodyInterface_IsAdded(bi, vol.dynamic_body) {
				jolt.BodyInterface_RemoveBody(bi, vol.dynamic_body)
			}
			jolt.BodyInterface_DestroyBody(bi, vol.dynamic_body)
		}
		vol.dynamic_body = 0
	}
	if vol.dynamic_shape != nil {
		if physics3d._state.world_ready {
			delete_key(&physics3d._state.shape_owner, uintptr(vol.dynamic_shape))
		}
		jolt.Shape_Destroy(vol.dynamic_shape)
		vol.dynamic_shape = nil
	}
	if !engine.asset_guid_is_empty(vol.mesh_guid) {
		engine.mesh_remove_procedural(vol.mesh_guid)
		vol.mesh_guid = {}
	}
	if !engine.asset_guid_is_empty(vol.shadow_mesh_guid) {
		engine.mesh_remove_procedural(vol.shadow_mesh_guid)
		vol.shadow_mesh_guid = {}
	}
	vol.compiled = false
	vol.gpu_dirty = false
	if w := engine.ctx_world(); w != nil && physics3d._state.world_ready {
		vol.physics_world_id = w.id
	} else {
		vol.physics_world_id = 0
	}
}

// ============================================================================
// LOCK-FREE OFF-THREAD JOLTC SHAPE COOKING
// ============================================================================

// Verifies that `pts` form a non-degenerate 3D volume (bounding box >= 3cm and non-coplanar)
// before passing them to JoltC's `ConvexHullShapeSettings_Create`.
@(private = "file")
_points_form_3d_simplex :: proc(pts: [][3]f32) -> bool {
	if len(pts) < 4 do return false
	lo := pts[0]
	hi := pts[0]
	for p in pts[1:] {
		lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); lo.z = min(lo.z, p.z)
		hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y); hi.z = max(hi.z, p.z)
	}
	ext := hi - lo
	if ext.x < 0.025 || ext.y < 0.025 || ext.z < 0.025 do return false

	p0 := pts[0]
	// Find furthest point p1
	p1 := p0
	best_d2: f32 = 0
	for p in pts[1:] {
		d2 := linalg.length2(p - p0)
		if d2 > best_d2 {
			best_d2 = d2
			p1 = p
		}
	}
	if best_d2 < 1e-4 do return false
	dir1 := linalg.normalize0(p1 - p0)

	// Find point p2 furthest from line (p0, dir1)
	p2 := p0
	best_line_d2: f32 = 0
	for p in pts[1:] {
		v := p - p0
		perp := v - dir1 * linalg.dot(v, dir1)
		d2 := linalg.length2(perp)
		if d2 > best_line_d2 {
			best_line_d2 = d2
			p2 = p
		}
	}
	if best_line_d2 < 1e-4 do return false
	plane_n := linalg.normalize0(linalg.cross(p1 - p0, p2 - p0))

	// Ensure at least one point lies >= 1.5cm off the plane (p0, p1, p2)
	for p in pts[1:] {
		if abs(linalg.dot(p - p0, plane_n)) >= 0.015 {
			return true
		}
	}
	return false
}

// Cooks a `^jolt.Shape` from a chunk's convex hulls (or triangle mesh).
// 100% thread-safe: `ShapeSettings_CreateShape` allocates a standalone ref-counted
// `^jolt.Shape` without touching `jolt.PhysicsSystem` or `jolt.BodyInterface`!
@(private = "file")
_cook_chunk_jolt_shape :: proc(
	destructible:      []CSG_Convex,
	indestructible:    []CSG_Convex,
	verts:             []gfx.Vertex,
	indices:           []u32,
	scale:             [3]f32 = {1, 1, 1},
	prefer_exact_mesh: bool = false,
) -> ^jolt.Shape {
	total_hulls := len(destructible) + len(indestructible)
	if (total_hulls == 0 && !prefer_exact_mesh) || len(indices) < 3 do return nil

	// Fast Path A & B: Up to 24 Convex Polyhedra -> Direct `ConvexHullShape` (if 1) or `StaticCompoundShape` (if >= 2)!
	// (Skipped when `prefer_exact_mesh` is true on Voxel SDF chunks so static craters use exact 0.0mm Surface Nets triangle collision!)
	if !prefer_exact_mesh && total_hulls <= 24 {
		sub_shapes := make([dynamic]^jolt.Shape, 0, total_hulls, context.temp_allocator)
		pts := make([dynamic][3]f32, 0, 32, context.temp_allocator)

		for pass in 0 ..< 2 {
			slice_h := destructible if pass == 0 else indestructible
			for h in slice_h {
				convex_extract_vertices(h, &pts)
				for &p in pts do p *= scale
				if !_points_form_3d_simplex(pts[:]) do continue
				cs := jolt.ConvexHullShapeSettings_Create(&pts[0], u32(len(pts)), 0.01)
				if cs != nil {
					sub_shape := cast(^jolt.Shape)jolt.ConvexHullShapeSettings_CreateShape(cs)
					jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)cs)
					if sub_shape != nil {
						append(&sub_shapes, sub_shape)
					}
				}
			}
		}

		if len(sub_shapes) == 1 {
			return sub_shapes[0]
		} else if len(sub_shapes) >= 2 {
			comp_settings := jolt.StaticCompoundShapeSettings_Create()
			if comp_settings != nil {
				defer jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)comp_settings)
				zero_pos := [3]f32{0, 0, 0}
				ident_rot := transmute(jolt.Quat)[4]f32{0, 0, 0, 1}
				for s in sub_shapes {
					jolt.CompoundShapeSettings_AddShape2(
						cast(^jolt.CompoundShapeSettings)comp_settings,
						&zero_pos,
						&ident_rot,
						s,
						0,
					)
				}
				if cooked := jolt.StaticCompoundShape_Create(comp_settings); cooked != nil {
					return cast(^jolt.Shape)cooked
				}
			}
			for s in sub_shapes do jolt.Shape_Destroy(s)
		}
	}

	// Path C: High-complexity chunk -> `MeshShape` with `FavorBuildSpeed` and non-degenerate triangle filtering!
	tri_count := len(indices) / 3
	if tri_count == 0 || len(verts) < 3 do return nil
	v_buf := make([][3]f32, len(verts), context.temp_allocator)
	for v, i in verts {
		v_buf[i] = v.position * scale
	}
	idx_tris := make([dynamic]jolt.IndexedTriangle, 0, min(tri_count, 4096), context.temp_allocator)
	for t in 0 ..< tri_count {
		if len(idx_tris) >= 4096 do break
		i0 := indices[t * 3 + 0]
		i1 := indices[t * 3 + 1]
		i2 := indices[t * 3 + 2]
		if int(i0) >= len(v_buf) || int(i1) >= len(v_buf) || int(i2) >= len(v_buf) do continue
		p0 := v_buf[i0]
		p1 := v_buf[i1]
		p2 := v_buf[i2]
		if linalg.length2(linalg.cross(p1 - p0, p2 - p0)) < 1e-6 do continue
		append(&idx_tris, jolt.IndexedTriangle{
			i1            = i0,
			i2            = i1,
			i3            = i2,
			materialIndex = 0,
			userData      = 0,
		})
	}
	if len(idx_tris) == 0 do return nil
	ms := jolt.MeshShapeSettings_Create2(&v_buf[0], u32(len(v_buf)), &idx_tris[0], u32(len(idx_tris)))
	if ms == nil do return nil
	defer jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)ms)
	jolt.MeshShapeSettings_SetBuildQuality(ms, .FavorBuildSpeed)
	return cast(^jolt.Shape)jolt.MeshShapeSettings_CreateShape(ms)
}

// ============================================================================
// VOLUME COMPILATION, PROJECTED PLANAR SHADOWS & RENDER COLLECTOR
// ============================================================================

@(private = "file")
_ensure_volume_guids :: proc(vol: ^CSGVolume) {
	if vol == nil || vol.owner == {} do return
	if engine.asset_guid_is_empty(vol.mesh_guid) {
		vol.mesh_guid = make_procedural_guid(vol.owner, 0)
	}
	if engine.asset_guid_is_empty(vol.shadow_mesh_guid) {
		vol.shadow_mesh_guid = make_procedural_guid(vol.owner, 1)
	}
	// If a legacy scene attached a MeshFilter with a transient "CSG!" GUID, clear it
	// so `_collect_mesh_renderers` never attempts a failed disk lookup on `library/`.
	w := engine.ctx_world()
	if w != nil && engine.pool_valid(&w.transforms, engine.Handle(vol.owner)) {
		if _, mf := engine.transform_get_comp(vol.owner, engine.MeshFilter); mf != nil {
			raw := transmute([16]u8)mf.mesh.guid
			if raw[0] == 0x43 && raw[1] == 0x53 && raw[2] == 0x47 && raw[3] == 0x21 {
				mf.mesh.guid = {}
			}
		}
	}
}

CSG_Shadow_Light :: struct {
	valid:      bool,
	kind:       engine.Light_Type,
	world_pos:  [3]f32,
	to_light:   [3]f32, // unit vector pointing TOWARD the light (for directional/spot)
	forward:    [3]f32, // unit vector pointing ALONG the light's shine direction (-Z)
	outer_cos:  f32,    // cosine of half spot_angle (for spot light cone check)
	range:      f32,
	intensity:  f32,
	ambient:    f32,
	strength:   f32,
	ground_y:   f32,
	signature:  u64,
}

@(private = "file")
_last_shadow_light_sig: u64
@(private = "file")
_scene_props_shadow_guid: engine.Asset_GUID

// Collects ALL active `engine.Light` objects in the scene with `cast_shadows == true`.
// Supports simultaneous `.Directional`, `.Spot`, and `.Point` lights (each respecting its `range` and cone!).
@(private = "file")
_resolve_scene_shadow_lights :: proc(alloc := context.temp_allocator) -> (lights: [dynamic]CSG_Shadow_Light, combined_sig: u64) {
	lights = make([dynamic]CSG_Shadow_Light, 0, 8, alloc)
	w := engine.ctx_world()
	if w == nil do return

	hash_f32 :: #force_inline proc(h: u64, v: f32) -> u64 {
		q := i32(math.round(v * 200.0))
		return (h ~ u64(u32(q))) * 1099511628211
	}
	combined_sig = 14695981039346656037

	it := engine.pool_iterator(engine.lights(w))
	for l, _ in engine.pool_next(&it) {
		if !l.enabled || !l.cast_shadows || l.intensity <= 0.01 do continue
		if !engine.transform_active_in_hierarchy(l.owner) do continue

		tw := engine.transform_world(engine.Transform_Handle(l.owner))
		rot := engine.quat_to_matrix3(tw.rotation)
		fwd := linalg.normalize0([3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]})
		to_l := -fwd
		if to_l.y < -0.08 {
			to_l = -to_l
		} else if abs(to_l.y) <= 0.08 {
			to_l = linalg.normalize0([3]f32{to_l.x, 0.65, to_l.z})
		}

		sl := CSG_Shadow_Light{
			valid     = true,
			kind      = l.type,
			world_pos = tw.position,
			to_light  = to_l,
			forward   = fwd,
			outer_cos = math.cos(math.to_radians(max(l.spot_angle, l.inner_spot_angle)) * 0.5),
			range     = max(l.range, 1.0),
			intensity = max(l.intensity, 0.05),
			ambient   = clamp(l.ambient, 0.05, 0.85),
			strength  = clamp(l.shadow_strength if l.shadow_strength > 0.01 else 0.72, 0.05, 1.0),
			ground_y  = l.shadow_ground_y,
		}

		h: u64 = 14695981039346656037
		h = (h ~ u64(l.type)) * 1099511628211
		h = hash_f32(h, sl.world_pos.x)
		h = hash_f32(h, sl.world_pos.y)
		h = hash_f32(h, sl.world_pos.z)
		h = hash_f32(h, sl.to_light.x)
		h = hash_f32(h, sl.to_light.y)
		h = hash_f32(h, sl.to_light.z)
		h = hash_f32(h, sl.range)
		h = hash_f32(h, sl.intensity)
		h = hash_f32(h, sl.strength)
		h = hash_f32(h, sl.ground_y)
		sl.signature = h
		combined_sig = (combined_sig ~ h) * 1099511628211

		append(&lights, sl)
	}
	return
}

// Primary directional/dominant light helper for vertex self-shadowing
@(private = "file")
_resolve_scene_shadow_light :: proc() -> (res: CSG_Shadow_Light) {
	lights, sig := _resolve_scene_shadow_lights(context.temp_allocator)
	if len(lights) == 0 do return
	best_idx := 0
	for l, i in lights {
		if l.kind == .Directional {
			best_idx = i
			break
		}
	}
	res = lights[best_idx]
	res.signature = sig
	return
}

// Returns true if a world-space point `world_pt` is within `light.range` (and spot cone for Spot lights).
@(private = "file")
_light_reaches_world_point :: #force_inline proc(light: CSG_Shadow_Light, world_pt: [3]f32) -> bool {
	if !light.valid do return false
	if light.kind == .Directional do return true
	diff := world_pt - light.world_pos
	dist2 := linalg.length2(diff)
	if dist2 > light.range * light.range do return false
	if light.kind == .Spot && dist2 > 1e-4 {
		dir := diff / math.sqrt(dist2)
		if linalg.dot(dir, light.forward) < light.outer_cos - 0.15 do return false
	}
	return true
}

// Projects a single vertex `pos` onto `y = ground_y` for Directional, Point, or Spot lights.
@(private = "file")
_project_vertex_to_shadow_plane :: #force_inline proc(pos: [3]f32, ground_y, y_eps: f32, light: CSG_Shadow_Light) -> [3]f32 {
	h := max(pos.y - ground_y, 0.0)
	if light.kind == .Directional {
		inv_ly := 1.0 / max(light.to_light.y, 0.18)
		return {
			pos.x - light.to_light.x * h * inv_ly,
			y_eps,
			pos.z - light.to_light.z * h * inv_ly,
		}
	}
	// Point or Spot light: radial perspective projection from `light.world_pos` through `pos` onto `y = ground_y`
	dy := max(light.world_pos.y - pos.y, 0.20)
	t_proj := clamp(h / dy, 0.0, 4.5)
	proj_x := pos.x + (pos.x - light.world_pos.x) * t_proj
	proj_z := pos.z + (pos.z - light.world_pos.z) * t_proj
	// Clamp projected shadow extent to `light.range` from the light's XZ position
	dx := proj_x - light.world_pos.x
	dz := proj_z - light.world_pos.z
	d_xz := math.sqrt(dx * dx + dz * dz)
	max_r := max(light.range * 1.15, 1.5)
	if d_xz > max_r && d_xz > 1e-4 {
		scale := max_r / d_xz
		proj_x = light.world_pos.x + dx * scale
		proj_z = light.world_pos.z + dz * scale
	}
	return {proj_x, y_eps, proj_z}
}

// Evaluates the floor illumination contribution of `light` at world-space floor point `world_pt`,
// matching the exact attenuation curve of `lit.frag` (`a = clamp(1 - (d/R)^2, 0, 1); a *= a`).
@(private = "file")
_eval_light_floor_illum :: #force_inline proc(light: CSG_Shadow_Light, world_pt: [3]f32) -> f32 {
	if !light.valid do return 0.0
	if light.kind == .Directional {
		ndotl := max(light.to_light.y, 0.15)
		return light.intensity * ndotl
	}
	diff := world_pt - light.world_pos
	dist2 := linalg.length2(diff)
	r := max(light.range, 0.001)
	if dist2 >= r * r do return 0.0
	dist := math.sqrt(dist2)
	ratio := dist / r
	a := clamp(1.0 - ratio * ratio, 0.0, 1.0)
	atten := a * a
	if light.kind == .Spot && dist > 1e-4 {
		dir := diff / dist
		cos_a := linalg.dot(dir, light.forward)
		atten *= clamp((cos_a - light.outer_cos) / 0.15, 0.0, 1.0)
	}
	ndotl := clamp(-diff.y / max(dist, 0.001), 0.15, 1.0)
	return light.intensity * ndotl * atten
}

// Cheap analytical multi-light shadow washout & additive light ratio at floor point `world_pt`:
// Because `lit.frag` multiplies vertex color by `I_total(p) = ambient + (1 - ambient) * sum(I_i(p))`,
// when Light `caster_idx` is blocked while other lights `j != caster_idx` directly illuminate `world_pt`,
// an opposing light washes out / kills the shadow (`drop -> 0`) instead of leaving a dark shadow under the opposing light!
@(private = "file")
_eval_shadow_vertex_color :: proc(
	lights:     []CSG_Shadow_Light,
	caster_idx: int,
	world_pt:   [3]f32,
) -> (col: [4]u8, drop_strength: f32) {
	if caster_idx < 0 || caster_idx >= len(lights) {
		return {38, 40, 48, 255}, 0.5
	}
	caster := lights[caster_idx]
	caster_illum := _eval_light_floor_illum(caster, world_pt)
	if caster_illum <= 0.005 {
		return {145, 152, 164, 255}, 0.0
	}

	other_illum: f32 = 0.0
	for ol, idx in lights {
		if idx == caster_idx || !ol.valid do continue
		other_illum += _eval_light_floor_illum(ol, world_pt)
	}

	ambient := caster.ambient
	total_illum := max(ambient + (1.0 - ambient) * (caster_illum + other_illum), 0.05)

	// Fraction of total floor light lost when `caster` is occluded, weighted by opposing-light washout
	blocked_frac := ((1.0 - ambient) * caster_illum * caster.strength) / total_illum
	washout      := caster_illum / max(caster_illum + 1.35 * other_illum, 0.001)
	drop_strength = clamp(blocked_frac * washout, 0.0, 0.85)

	// Base lit floor neutral albedo is ~{145, 152, 164}; scale down by `(1.0 - drop_strength)`
	// so `lit.frag` (`out = color * I_total`) reproduces `floor_albedo * (I_total - I_caster)`!
	keep := clamp(1.0 - drop_strength, 0.16, 1.0)
	r_u8 := u8(clamp(145.0 * keep, 16.0, 148.0))
	g_u8 := u8(clamp(152.0 * keep, 18.0, 155.0))
	b_u8 := u8(clamp(164.0 * keep, 22.0, 168.0))
	return {r_u8, g_u8, b_u8, 255}, drop_strength
}

// ============================================================================
// GROUND RECEIVER DETECTION & PLANAR SHADOW CLIPPING
// ============================================================================

// Represents an actual floor/ground surface in the scene at `y ≈ ground_y` that can receive
// projected planar drop shadows. If no ground receivers exist at `ground_y`, planar shadows
// are suppressed so shadows never float in empty air; if a shadow extends past the edge of
// a floor receiver (or over a blasted hole through the floor), it is clipped to the receiver!
CSG_Ground_Receiver :: struct {
	min_xz:      [2]f32, // World-space [min_x, min_z]
	max_xz:      [2]f32, // World-space [max_x, max_z]
	top_y:       f32,    // World-space top floor surface Y
	plane_count: int,    // >0 when the floor hull has non-cardinal horizontal edges (spline floor or blasted crater rim)
	planes:      [16]CSG_Plane,
}

// Collects all valid floor/ground receiver surfaces near `ground_y` across static `CSGVolume`s,
// floor `MeshRenderer`s, and static `BoxCollider`s, merging adjacent axis-aligned floor chunks.
csg_collect_ground_receivers :: proc(ground_y: f32, alloc := context.temp_allocator) -> (receivers: [dynamic]CSG_Ground_Receiver, sig: u64) {
	receivers = make([dynamic]CSG_Ground_Receiver, 0, 16, alloc)
	w := engine.ctx_world()
	if w == nil do return

	hash_f :: #force_inline proc(h: u64, v: f32) -> u64 {
		q := i32(math.round(v * 100.0))
		return (h ~ u64(u32(q))) * 1099511628211
	}
	sig = 14695981039346656037

	// 1. Static CSGVolume floor hulls (`!vol.is_dynamic_rigidbody`)
	v_it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&v_it) {
		if !vol.enabled || vol.is_dynamic_rigidbody do continue
		if !engine.transform_active_in_hierarchy(vol.owner) do continue
		tw := engine.transform_world(vol.owner)
		vol_pos := tw.position

		for _, ch in vol.chunks {
			if ch == nil do continue
			for pass in 0 ..< 2 {
				h_slice := ch.destructible_hulls[:] if pass == 0 else ch.indestructible_hulls[:]
				for h in h_slice {
					w_min := h.aabb_min + vol_pos
					w_max := h.aabb_max + vol_pos
					// Must span or touch `ground_y` and have its top surface near `ground_y` (not a tall wall or sphere!)
					if w_min.y > ground_y + 0.25 || w_max.y < ground_y - 0.35 || w_max.y > ground_y + 0.45 {
						continue
					}
					if (w_max.x - w_min.x) < 0.45 || (w_max.z - w_min.z) < 0.45 {
						continue
					}

					has_flat_top := false
					is_axis_box  := true
					rec := CSG_Ground_Receiver{
						min_xz = {w_min.x, w_min.z},
						max_xz = {w_max.x, w_max.z},
						top_y  = w_max.y,
					}

					for p in h.planes {
						if p.normal.y > 0.85 {
							wp_d := p.dist + linalg.dot(p.normal, vol_pos)
							if abs(wp_d - w_max.y * p.normal.y) <= 0.18 {
								has_flat_top = true
							}
							continue
						}
						if p.normal.y < -0.80 do continue

						// Side boundary plane (`abs(p.normal.y) <= 0.85`)
						is_card_xz := (abs(p.normal.x) > 0.999 && abs(p.normal.y) < 0.01) ||
						              (abs(p.normal.z) > 0.999 && abs(p.normal.y) < 0.01)
						if !is_card_xz {
							is_axis_box = false
						}
						if rec.plane_count < len(rec.planes) {
							wp := p
							wp.dist = p.dist + linalg.dot(p.normal, vol_pos)
							rec.planes[rec.plane_count] = wp
							rec.plane_count += 1
						}
					}
					if !has_flat_top do continue
					if is_axis_box {
						rec.plane_count = 0
					}
					append(&receivers, rec)
				}
			}
		}
	}

	// 2. Standard MeshRenderer floor slabs (excluding CSGVolumes and non-floor props/spheres)
	mr_it := engine.pool_iterator(engine.mesh_renderers(w))
	for mr, _ in engine.pool_next(&mr_it) {
		if !mr.enabled do continue
		owner_h := engine.Transform_Handle(mr.owner)
		if !engine.transform_active_in_hierarchy(owner_h) do continue
		if _, has_csg := engine.transform_get_comp(owner_h, CSGVolume); has_csg != nil do continue
		_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
		if mf == nil || engine.asset_guid_is_empty(mf.mesh.guid) do continue
		mesh, ok := engine.mesh_load_filter(mf)
		if !ok do continue

		tw := engine.transform_world(owner_h)
		model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		lo := mesh.aabb_min
		hi := mesh.aabb_max
		corners := [8][3]f32{
			{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z}, {lo.x, hi.y, lo.z},
			{lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z}, {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z},
		}
		w_min := [3]f32{max(f32), max(f32), max(f32)}
		w_max := [3]f32{-max(f32), -max(f32), -max(f32)}
		for c in corners {
			wp := (model * [4]f32{c.x, c.y, c.z, 1.0}).xyz
			w_min = linalg.min(w_min, wp)
			w_max = linalg.max(w_max, wp)
		}
		if w_min.y <= ground_y + 0.25 && w_max.y >= ground_y - 0.35 && w_max.y <= ground_y + 0.45 &&
		   (w_max.y - w_min.y) <= 1.25 && (w_max.x - w_min.x) >= 1.5 && (w_max.z - w_min.z) >= 1.5 {
			append(&receivers, CSG_Ground_Receiver{
				min_xz = {w_min.x, w_min.z},
				max_xz = {w_max.x, w_max.z},
				top_y  = w_max.y,
			})
		}
	}

	// 3. Static BoxCollider floor slabs (in case a floor has a BoxCollider without a MeshRenderer or CSGVolume)
	bc_it := engine.pool_iterator(physics3d.box_colliders(w))
	for bc, _ in engine.pool_next(&bc_it) {
		if !bc.enabled || bc.is_trigger do continue
		owner_h := engine.Transform_Handle(bc.owner)
		if !engine.transform_active_in_hierarchy(owner_h) do continue
		if _, has_csg := engine.transform_get_comp(owner_h, CSGVolume); has_csg != nil do continue
		if _, rb := engine.transform_get_comp(owner_h, physics3d.Rigidbody); rb != nil && !rb.is_kinematic do continue

		tw := engine.transform_world(owner_h)
		half := bc.size * tw.scale * 0.5
		c_w  := tw.position + bc.center * tw.scale
		w_min := c_w - half
		w_max := c_w + half
		if w_min.y <= ground_y + 0.25 && w_max.y >= ground_y - 0.35 && w_max.y <= ground_y + 0.45 &&
		   (w_max.y - w_min.y) <= 1.25 && (w_max.x - w_min.x) >= 1.5 && (w_max.z - w_min.z) >= 1.5 {
			append(&receivers, CSG_Ground_Receiver{
				min_xz = {w_min.x, w_min.z},
				max_xz = {w_max.x, w_max.z},
				top_y  = w_max.y,
			})
		}
	}

	// 4. Merge adjacent/overlapping axis-aligned rectangular floor chunks (`plane_count == 0`)
	//    so un-blasted multi-chunk floors collapse into single large rectangles!
	merged_any := true
	for merged_any && len(receivers) > 1 {
		merged_any = false
		outer_m: for i := 0; i < len(receivers); i += 1 {
			ra := receivers[i]
			if ra.plane_count > 0 do continue
			for j := i + 1; j < len(receivers); j += 1 {
				rb := receivers[j]
				if rb.plane_count > 0 || abs(ra.top_y - rb.top_y) > 0.03 do continue

				// Check if one rectangle completely contains the other
				if ra.min_xz.x <= rb.min_xz.x + 0.02 && ra.max_xz.x >= rb.max_xz.x - 0.02 &&
				   ra.min_xz.y <= rb.min_xz.y + 0.02 && ra.max_xz.y >= rb.max_xz.y - 0.02 {
					ordered_remove(&receivers, j)
					merged_any = true
					break outer_m
				}
				if rb.min_xz.x <= ra.min_xz.x + 0.02 && rb.max_xz.x >= ra.max_xz.x - 0.02 &&
				   rb.min_xz.y <= ra.min_xz.y + 0.02 && rb.max_xz.y >= ra.max_xz.y - 0.02 {
					receivers[i] = rb
					ordered_remove(&receivers, j)
					merged_any = true
					break outer_m
				}

				// Same Z span and touching/overlapping X span
				if abs(ra.min_xz.y - rb.min_xz.y) <= 0.03 && abs(ra.max_xz.y - rb.max_xz.y) <= 0.03 &&
				   ra.max_xz.x >= rb.min_xz.x - 0.05 && rb.max_xz.x >= ra.min_xz.x - 0.05 {
					receivers[i].min_xz.x = min(ra.min_xz.x, rb.min_xz.x)
					receivers[i].max_xz.x = max(ra.max_xz.x, rb.max_xz.x)
					ordered_remove(&receivers, j)
					merged_any = true
					break outer_m
				}

				// Same X span and touching/overlapping Z span
				if abs(ra.min_xz.x - rb.min_xz.x) <= 0.03 && abs(ra.max_xz.x - rb.max_xz.x) <= 0.03 &&
				   ra.max_xz.y >= rb.min_xz.y - 0.05 && rb.max_xz.y >= ra.min_xz.y - 0.05 {
					receivers[i].min_xz.y = min(ra.min_xz.y, rb.min_xz.y)
					receivers[i].max_xz.y = max(ra.max_xz.y, rb.max_xz.y)
					ordered_remove(&receivers, j)
					merged_any = true
					break outer_m
				}
			}
		}
	}

	for r in receivers {
		sig = hash_f(sig, r.min_xz.x)
		sig = hash_f(sig, r.min_xz.y)
		sig = hash_f(sig, r.max_xz.x)
		sig = hash_f(sig, r.max_xz.y)
		sig = hash_f(sig, r.top_y)
		sig = (sig ~ u64(r.plane_count)) * 1099511628211
	}
	return
}

// Clips a world-space projected shadow triangle `(p0_w, p1_w, p2_w)` against a single `CSG_Ground_Receiver` `r`,
// writing the resulting world-space convex polygon vertices into `poly_out`.
csg_clip_shadow_tri_to_receiver :: proc(
	p0_w, p1_w, p2_w: [3]f32,
	r:                CSG_Ground_Receiver,
	y_layer_step:     f32,
	poly_out:         ^[dynamic][3]f32,
	poly_scratch:     ^[dynamic][3]f32,
) {
	clear(poly_out)
	y_use := max(p0_w.y, r.top_y + y_layer_step)
	append(poly_out,
		[3]f32{p0_w.x, y_use, p0_w.z},
		[3]f32{p1_w.x, y_use, p1_w.z},
		[3]f32{p2_w.x, y_use, p2_w.z},
	)

	box_planes := [4]CSG_Plane{
		{normal = {+1, 0,  0}, dist =  r.max_xz.x},
		{normal = {-1, 0,  0}, dist = -r.min_xz.x},
		{normal = { 0, 0, +1}, dist =  r.max_xz.y},
		{normal = { 0, 0, -1}, dist = -r.min_xz.y},
	}
	for bp in box_planes {
		clip_polygon_by_plane(poly_out[:], bp, poly_scratch)
		poly_out^, poly_scratch^ = poly_scratch^, poly_out^
		if len(poly_out) < 3 do return
	}

	for pi in 0 ..< r.plane_count {
		clip_polygon_by_plane(poly_out[:], r.planes[pi], poly_scratch)
		poly_out^, poly_scratch^ = poly_scratch^, poly_out^
		if len(poly_out) < 3 do return
	}
}

// Clips a world-space projected shadow triangle `(p0_w, p1_w, p2_w)` against `receivers` and appends
// the surviving floor-clamped shadow triangles to `sh_verts` and `sh_inds`.
// If no ground receiver exists underneath, emits nothing (preventing floating mid-air shadows!).
@(private = "file")
_clip_and_emit_shadow_triangle :: proc(
	p0_w, p1_w, p2_w: [3]f32,
	out_offset:       [3]f32,
	y_layer_step:     f32,
	receivers:        []CSG_Ground_Receiver,
	lights:           []CSG_Shadow_Light,
	l_idx:            int,
	sh_verts:         ^[dynamic]gfx.Vertex,
	sh_inds:          ^[dynamic]u32,
	poly_a:           ^[dynamic][3]f32,
	poly_b:           ^[dynamic][3]f32,
) {
	if len(receivers) == 0 do return

	t_min_x := min(p0_w.x, min(p1_w.x, p2_w.x))
	t_max_x := max(p0_w.x, max(p1_w.x, p2_w.x))
	t_min_z := min(p0_w.z, min(p1_w.z, p2_w.z))
	t_max_z := max(p0_w.z, max(p1_w.z, p2_w.z))

	for r in receivers {
		if t_max_x <= r.min_xz.x + 1e-3 || t_min_x >= r.max_xz.x - 1e-3 ||
		   t_max_z <= r.min_xz.y + 1e-3 || t_min_z >= r.max_xz.y - 1e-3 {
			continue
		}

		// Fast Path: triangle is 100% inside a rectangular floor receiver
		if r.plane_count == 0 &&
		   t_min_x >= r.min_xz.x && t_max_x <= r.max_xz.x &&
		   t_min_z >= r.min_xz.y && t_max_z <= r.max_xz.y {
			y_use := max(p0_w.y, r.top_y + y_layer_step)
			q0 := [3]f32{p0_w.x, y_use, p0_w.z}
			q1 := [3]f32{p1_w.x, y_use, p1_w.z}
			q2 := [3]f32{p2_w.x, y_use, p2_w.z}
			c0, d0 := _eval_shadow_vertex_color(lights, l_idx, q0)
			c1, d1 := _eval_shadow_vertex_color(lights, l_idx, q1)
			c2, d2 := _eval_shadow_vertex_color(lights, l_idx, q2)
			if max(d0, max(d1, d2)) >= 0.10 {
				bv := u32(len(sh_verts))
				append(sh_verts,
					gfx.Vertex{position = q0 + out_offset, normal = {0, 1, 0}, uv = {0, 0}, color = c0},
					gfx.Vertex{position = q1 + out_offset, normal = {0, 1, 0}, uv = {0, 0}, color = c1},
					gfx.Vertex{position = q2 + out_offset, normal = {0, 1, 0}, uv = {0, 0}, color = c2},
				)
				append(sh_inds, bv, bv + 1, bv + 2)
			}
			return
		}

		// Clip Path: slice shadow triangle against the exact boundary planes of `r`
		csg_clip_shadow_tri_to_receiver(p0_w, p1_w, p2_w, r, y_layer_step, poly_a, poly_b)
		if len(poly_a) < 3 || polygon_area(poly_a[:]) <= 1e-4 do continue

		max_d: f32 = 0
		bv := u32(len(sh_verts))
		for pt in poly_a^ {
			col, d := _eval_shadow_vertex_color(lights, l_idx, pt)
			max_d = max(max_d, d)
			append(sh_verts, gfx.Vertex{
				position = pt + out_offset,
				normal   = {0, 1, 0},
				uv       = {0, 0},
				color    = col,
			})
		}
		if max_d < 0.10 {
			resize(sh_verts, int(bv))
			continue
		}
		tri_n := u32(len(poly_a) - 2)
		for k in 0 ..< tri_n {
			append(sh_inds, bv, bv + k + 1, bv + k + 2)
		}
	}
}

// Repacks all chunks' cached vertex and index arrays into `vol.mesh_guid` and builds
// the real-time projected planar shadow mesh (`vol.shadow_mesh_guid`) driven by ALL active shadow-casting `Light`s.
// Safe to call during `csg_render_collector` (before draw calls are encoded for the frame)
// or in headless unit tests.
csg_volume_upload_gpu_now :: proc(vol: ^CSGVolume) {
	if vol == nil || vol.owner == {} do return
	_ensure_volume_guids(vol)
	vol.gpu_dirty = false

	total_v := 0
	total_i := 0
	has_deform := (vol.soft_deform_enabled && len(vol.soft_deform_stamps) > 0) || vol.deform_debug_heatmap
	for coord, ch in vol.chunks {
		if engine.asset_guid_is_empty(ch.chunk_mesh_guid) {
			ch.chunk_mesh_guid = _make_chunk_procedural_guid(vol.owner, coord)
		}
		if ch.dirty_gpu || !engine.mesh_is_cached(ch.chunk_mesh_guid) {
			if len(ch.verts) > 0 && len(ch.indices) > 0 {
				upload_verts: []gfx.Vertex            = ch.verts[:]
				upload_inds:  []u32                   = ch.indices[:]
				upload_subs:  []engine.Mesh_Submesh   = ch.submeshes[:]
				if has_deform {
					upload_verts, upload_inds, upload_subs = csg_tessellate_and_deform_mesh(vol, ch.verts[:], ch.indices[:], ch.submeshes[:], context.temp_allocator)
				}
				engine.mesh_upsert_procedural(ch.chunk_mesh_guid, upload_verts, upload_inds, upload_subs, keep_cpu_buffers = false)
			} else {
				engine.mesh_remove_procedural(ch.chunk_mesh_guid)
			}
			ch.dirty_gpu = false
		}
		total_v += len(ch.verts)
		total_i += len(ch.indices)
	}

	// 1. Build batched GPU mesh for surviving procedural `CSG_Detail_Instance` items (opaque):
	dg_guid := make_detail_and_glass_guid(vol.owner)
	dg_verts := make([dynamic]gfx.Vertex, 0, 256, context.temp_allocator)
	dg_indices := make([dynamic]u32, 0, 512, context.temp_allocator)
	sun_light := _resolve_scene_shadow_light()
	sun_vec := sun_light.to_light if (sun_light.valid && sun_light.kind == .Directional) else [3]f32{0, 0, 0}
	if len(vol.detail_instances) > 0 {
		_append_detail_instances_and_glass_to_gpu_mesh(vol, &dg_verts, &dg_indices, sun_vec, include_glass = false)
	}
	if len(dg_verts) > 0 && len(dg_indices) > 0 {
		upload_dg: []gfx.Vertex = dg_verts[:]
		if has_deform {
			upload_dg, _, _ = csg_build_deformed_vertex_buffer(vol, dg_verts[:], context.temp_allocator)
		}
		engine.mesh_upsert_procedural(dg_guid, upload_dg, dg_indices[:], nil, keep_cpu_buffers = true)
	} else {
		engine.mesh_remove_procedural(dg_guid)
	}

	// 2. Build dedicated translucent see-through `CSG_Glass_Pane` mesh (`glass_guid`), sorted after opaque geometry!
	glass_guid := make_glass_pane_guid(vol.owner)
	glass_verts := make([dynamic]gfx.Vertex, 0, 256, context.temp_allocator)
	glass_indices := make([dynamic]u32, 0, 512, context.temp_allocator)
	if len(vol.glass_panes) > 0 {
		_append_glass_panes_to_gpu_mesh(vol, &glass_verts, &glass_indices, sun_vec)
	}
	if len(glass_verts) > 0 && len(glass_indices) > 0 {
		engine.mesh_upsert_procedural(glass_guid, glass_verts[:], glass_indices[:], nil, keep_cpu_buffers = true)
	} else {
		engine.mesh_remove_procedural(glass_guid)
	}

	// 3. Build clipped Faker CSG inner mesh (`A` inside `B`) and interior cut cap (`B` inside `A`)!
	_upload_faker_clipped_meshes_now(vol)

	if (total_v == 0 || total_i == 0) && len(dg_verts) == 0 {
		engine.mesh_remove_procedural(vol.mesh_guid)
		engine.mesh_remove_procedural(vol.shadow_mesh_guid)
		return
	}

	all_verts := make([dynamic]gfx.Vertex, 0, total_v + len(dg_verts), context.temp_allocator)
	all_indices := make([dynamic]u32, 0, total_i + len(dg_indices), context.temp_allocator)
	all_submeshes := make([dynamic]engine.Mesh_Submesh, 0, 2, context.temp_allocator)

	Chunk_Base :: struct {
		ch:     ^CSG_Chunk,
		base_v: u32,
	}
	chunk_bases := make([dynamic]Chunk_Base, 0, len(vol.chunks), context.temp_allocator)
	for _, ch in vol.chunks {
		if len(ch.verts) == 0 || len(ch.indices) == 0 do continue
		bv := u32(len(all_verts))
		if has_deform {
			def_v, _, _ := csg_build_deformed_vertex_buffer(vol, ch.verts[:], context.temp_allocator)
			append(&all_verts, ..def_v[:])
		} else {
			append(&all_verts, ..ch.verts[:])
		}
		append(&chunk_bases, Chunk_Base{ch = ch, base_v = bv})
	}

	max_slots := 2
	for cb in chunk_bases {
		if len(cb.ch.submeshes) > max_slots {
			max_slots = min(len(cb.ch.submeshes), 8)
		}
	}

	for slot in 0 ..< max_slots {
		first_idx := u32(len(all_indices))
		for cb in chunk_bases {
			if slot >= len(cb.ch.submeshes) do continue
			sub := cb.ch.submeshes[slot]
			for k in 0 ..< sub.index_count {
				orig_idx := cb.ch.indices[sub.first_index + k]
				append(&all_indices, cb.base_v + orig_idx)
			}
		}
		if slot == 0 && len(dg_verts) > 0 && len(dg_indices) > 0 {
			dg_base := u32(len(all_verts))
			append(&all_verts, ..dg_verts[:])
			for di in dg_indices {
				append(&all_indices, dg_base + di)
			}
		}
		count := u32(len(all_indices)) - first_idx
		append(&all_submeshes, engine.Mesh_Submesh{
			first_index = first_idx,
			index_count = count,
		})
	}
	for len(all_submeshes) > 0 && all_submeshes[len(all_submeshes) - 1].index_count == 0 {
		pop(&all_submeshes)
	}

	engine.mesh_upsert_procedural(vol.mesh_guid, all_verts[:], all_indices[:], all_submeshes[:], keep_cpu_buffers = false)

	// Build Projected Planar Drop Shadow Mesh from ALL active `Light` components (`cast_shadows == true`) in range,
	// clipped strictly against actual ground/floor receiver surfaces (`csg_collect_ground_receivers`) so shadows
	// never float in empty air when there is no floor underneath!
	// Optimization: Only project `slot == 0` outer shell triangles (never `slot == 1` interior crater micro-triangles!)
	// and cap per-light projected triangles at 384 so rapid-fire voxel blasts stay 100% stutter-free!
	lights, _ := _resolve_scene_shadow_lights(context.temp_allocator)
	if vol.cast_planar_shadows && !vol.is_dynamic_rigidbody && len(lights) > 0 {
		tw_vol := engine.transform_world(vol.owner)
		vol_offset := tw_vol.position
		outer_idx_cnt := int(all_submeshes[0].index_count) if len(all_submeshes) > 0 else len(all_indices)
		tri_count := min(outer_idx_cnt / 3, len(all_indices) / 3)
		tri_step  := max(tri_count / 384, 1)

		sh_verts := make([dynamic]gfx.Vertex, 0, min(tri_count, 384) * 3, context.temp_allocator)
		sh_inds  := make([dynamic]u32, 0, min(tri_count, 384) * 3, context.temp_allocator)
		poly_a   := make([dynamic][3]f32, 0, 16, context.temp_allocator)
		poly_b   := make([dynamic][3]f32, 0, 16, context.temp_allocator)

		for light, l_idx in lights {
			ground_y := vol.ground_y if abs(light.ground_y) < 1e-4 else light.ground_y
			receivers, _ := csg_collect_ground_receivers(ground_y, context.temp_allocator)
			if len(receivers) == 0 do continue // No ground surface at `ground_y` -> do not project shadows into empty air!

			// Slight per-light height step (1.2mm) prevents Z-fighting when multiple lights' shadows overlap!
			y_step   := 0.015 + f32(l_idx) * 0.0012
			shadow_y := ground_y + y_step

			// Transform light position into volume-local space for range & projection checks
			local_light := light
			local_light.world_pos = light.world_pos - vol_offset

			for ti := 0; ti < tri_count; ti += tri_step {
				v0 := all_verts[all_indices[ti * 3 + 0]]
				v1 := all_verts[all_indices[ti * 3 + 1]]
				v2 := all_verts[all_indices[ti * 3 + 2]]

				max_y := max(v0.position.y, max(v1.position.y, v2.position.y))
				if max_y <= ground_y + 0.12 do continue
				if v0.normal.y < -0.15 do continue

				tri_mid := (v0.position + v1.position + v2.position) * (1.0 / 3.0)
				if !_light_reaches_world_point(local_light, tri_mid) do continue

				to_l := local_light.to_light if local_light.kind == .Directional else linalg.normalize0(local_light.world_pos - tri_mid)
				if linalg.dot(v0.normal, to_l) < 0.02 do continue

				p0 := _project_vertex_to_shadow_plane(v0.position, ground_y, shadow_y, local_light)
				p1 := _project_vertex_to_shadow_plane(v1.position, ground_y, shadow_y, local_light)
				p2 := _project_vertex_to_shadow_plane(v2.position, ground_y, shadow_y, local_light)

				cr := linalg.cross(p1 - p0, p2 - p0)
				if abs(cr.y) < 1e-4 do continue
				if cr.y < 0 {
					p1, p2 = p2, p1
				}

				_clip_and_emit_shadow_triangle(
					p0 + vol_offset,
					p1 + vol_offset,
					p2 + vol_offset,
					-vol_offset,
					y_step,
					receivers[:],
					lights[:],
					l_idx,
					&sh_verts,
					&sh_inds,
					&poly_a,
					&poly_b,
				)
			}
		}

		if len(sh_verts) >= 3 && len(sh_inds) >= 3 {
			engine.mesh_upsert_procedural(vol.shadow_mesh_guid, sh_verts[:], sh_inds[:], nil, keep_cpu_buffers = false)
		} else {
			engine.mesh_remove_procedural(vol.shadow_mesh_guid)
		}
	} else {
		engine.mesh_remove_procedural(vol.shadow_mesh_guid)
	}
}

// Projects real-time planar shadows for `MeshRenderer` and `SkinnedMeshRenderer` objects in the scene
// across ALL active `engine.Light`s with `cast_shadows == true` that are within `light.range`,
// clipped strictly against actual ground/floor receiver surfaces (`csg_collect_ground_receivers`)!
@(private = "file")
_collect_standard_mesh_shadows :: proc(w: ^engine.World, view: engine.Render_View, lights: []CSG_Shadow_Light, out: ^[dynamic]engine.Render_Command) {
	if len(lights) == 0 do return
	if engine.asset_guid_is_empty(_scene_props_shadow_guid) {
		raw: [16]u8 = {0x43, 0x53, 0x47, 0x21, 0x53, 0x48, 0x44, 0x57, 1, 2, 3, 4, 5, 6, 7, 8}
		_scene_props_shadow_guid = transmute(engine.Asset_GUID)raw
	}

	sh_verts := make([dynamic]gfx.Vertex, 0, 512, context.temp_allocator)
	sh_inds  := make([dynamic]u32, 0, 512, context.temp_allocator)
	poly_a   := make([dynamic][3]f32, 0, 16, context.temp_allocator)
	poly_b   := make([dynamic][3]f32, 0, 16, context.temp_allocator)
	first_owner: engine.Transform_Handle

	for light, l_idx in lights {
		if !light.valid do continue
		ground_y := light.ground_y
		receivers, _ := csg_collect_ground_receivers(ground_y, context.temp_allocator)
		if len(receivers) == 0 do continue // No floor receiver in scene -> do not emit shadows into empty air!

		y_step   := 0.015 + f32(l_idx) * 0.0012
		shadow_y := ground_y + y_step

		// 1. Standard MeshRenderer + MeshFilter objects (`mr.cast_shadows == true`)
		mr_it := engine.pool_iterator(engine.mesh_renderers(w))
		for mr, _ in engine.pool_next(&mr_it) {
			if !mr.enabled || !mr.cast_shadows do continue
			owner_h := engine.Transform_Handle(mr.owner)
			t := engine.pool_get(&w.transforms, engine.Handle(owner_h))
			if t == nil || !engine.transform_active_in_hierarchy(owner_h) do continue
			if t.render_layer & view.layer_mask == 0 do continue
			if _, has_csg := engine.transform_get_comp(owner_h, CSGVolume); has_csg != nil do continue
			_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
			if mf == nil || engine.asset_guid_is_empty(mf.mesh.guid) do continue
			mesh, ok := engine.mesh_load_filter(mf)
			if !ok do continue

			tw := engine.transform_world(owner_h)
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			lo := mesh.aabb_min
			hi := mesh.aabb_max
			c_local := (lo + hi) * 0.5
			c_world := (model * [4]f32{c_local.x, c_local.y, c_local.z, 1.0}).xyz
			if !_light_reaches_world_point(light, c_world) do continue

			// If CPU triangles are available (e.g. Editable CAD Meshes, Torus, Car, etc.), project exact triangles!
			if len(mesh.bind_vertices) >= 3 && len(mesh.bind_indices) >= 3 && len(mesh.bind_indices) <= 3600 {
				if first_owner == {} do first_owner = owner_h
				tri_n := len(mesh.bind_indices) / 3
				for ti in 0 ..< tri_n {
					v0 := mesh.bind_vertices[mesh.bind_indices[ti * 3 + 0]].position
					v1 := mesh.bind_vertices[mesh.bind_indices[ti * 3 + 1]].position
					v2 := mesh.bind_vertices[mesh.bind_indices[ti * 3 + 2]].position
					w0 := (model * [4]f32{v0.x, v0.y, v0.z, 1.0}).xyz
					w1 := (model * [4]f32{v1.x, v1.y, v1.z, 1.0}).xyz
					w2 := (model * [4]f32{v2.x, v2.y, v2.z, 1.0}).xyz
					if max(w0.y, max(w1.y, w2.y)) <= ground_y + 0.08 do continue
					n_tri := linalg.normalize0(linalg.cross(w1 - w0, w2 - w0))
					to_l := light.to_light if light.kind == .Directional else linalg.normalize0(light.world_pos - w0)
					if linalg.dot(n_tri, to_l) < 0.01 do continue

					p0 := _project_vertex_to_shadow_plane(w0, ground_y, shadow_y, light)
					p1 := _project_vertex_to_shadow_plane(w1, ground_y, shadow_y, light)
					p2 := _project_vertex_to_shadow_plane(w2, ground_y, shadow_y, light)
					cr := linalg.cross(p1 - p0, p2 - p0)
					if abs(cr.y) < 1e-4 do continue
					if cr.y < 0 do p1, p2 = p2, p1

					_clip_and_emit_shadow_triangle(
						p0, p1, p2,
						{0, 0, 0},
						y_step,
						receivers[:],
						lights[:],
						l_idx,
						&sh_verts,
						&sh_inds,
						&poly_a,
						&poly_b,
					)
				}
				continue
			}

			corners_local := [8][3]f32{
				{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z}, {lo.x, hi.y, lo.z},
				{lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z}, {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z},
			}
			cw: [8][3]f32
			max_y: f32 = -1e9
			for c, k in corners_local {
				w4 := model * [4]f32{c.x, c.y, c.z, 1.0}
				cw[k] = w4.xyz
				max_y = max(max_y, w4.y)
			}
			if max_y <= ground_y + 0.12 do continue
			if first_owner == {} do first_owner = owner_h

			box_tris := [10][3]int{
				{3, 2, 6}, {3, 6, 7}, // Top (+Y)
				{0, 1, 2}, {0, 2, 3}, // Back (-Z)
				{4, 6, 5}, {4, 7, 6}, // Front (+Z)
				{0, 3, 7}, {0, 7, 4}, // Left (-X)
				{1, 5, 6}, {1, 6, 2}, // Right (+X)
			}
			for tri in box_tris {
				w0 := cw[tri[0]]
				w1 := cw[tri[1]]
				w2 := cw[tri[2]]
				n_tri := linalg.normalize0(linalg.cross(w1 - w0, w2 - w0))
				to_l := light.to_light if light.kind == .Directional else linalg.normalize0(light.world_pos - w0)
				if linalg.dot(n_tri, to_l) < 0.02 do continue

				p0 := _project_vertex_to_shadow_plane(w0, ground_y, shadow_y, light)
				p1 := _project_vertex_to_shadow_plane(w1, ground_y, shadow_y, light)
				p2 := _project_vertex_to_shadow_plane(w2, ground_y, shadow_y, light)
				cr := linalg.cross(p1 - p0, p2 - p0)
				if abs(cr.y) < 1e-4 do continue
				if cr.y < 0 do p1, p2 = p2, p1

				_clip_and_emit_shadow_triangle(
					p0, p1, p2,
					{0, 0, 0},
					y_step,
					receivers[:],
					lights[:],
					l_idx,
					&sh_verts,
					&sh_inds,
					&poly_a,
					&poly_b,
				)
			}
		}

		// 2. SkinnedMeshRenderer objects (`smr.cast_shadows == true`)
		smr_it := engine.pool_iterator(engine.skinned_mesh_renderers(w))
		for smr, _ in engine.pool_next(&smr_it) {
			if !smr.enabled || !smr.cast_shadows || !smr.posed_ok do continue
			owner_h := engine.Transform_Handle(smr.owner)
			t := engine.pool_get(&w.transforms, engine.Handle(owner_h))
			if t == nil || !engine.transform_active_in_hierarchy(owner_h) do continue
			if t.render_layer & view.layer_mask == 0 do continue

			lo := smr.posed_min
			hi := smr.posed_max
			if hi.y <= ground_y + 0.12 do continue
			c_world := (lo + hi) * 0.5
			if !_light_reaches_world_point(light, c_world) do continue
			if first_owner == {} do first_owner = owner_h

			cw := [8][3]f32{
				{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z}, {lo.x, hi.y, lo.z},
				{lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z}, {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z},
			}
			box_tris := [10][3]int{
				{3, 2, 6}, {3, 6, 7},
				{0, 1, 2}, {0, 2, 3},
				{4, 6, 5}, {4, 7, 6},
				{0, 3, 7}, {0, 7, 4},
				{1, 5, 6}, {1, 6, 2},
			}
			for tri in box_tris {
				w0, w1, w2 := cw[tri[0]], cw[tri[1]], cw[tri[2]]
				p0 := _project_vertex_to_shadow_plane(w0, ground_y, shadow_y, light)
				p1 := _project_vertex_to_shadow_plane(w1, ground_y, shadow_y, light)
				p2 := _project_vertex_to_shadow_plane(w2, ground_y, shadow_y, light)
				cr := linalg.cross(p1 - p0, p2 - p0)
				if abs(cr.y) < 1e-4 do continue
				if cr.y < 0 do p1, p2 = p2, p1

				_clip_and_emit_shadow_triangle(
					p0, p1, p2,
					{0, 0, 0},
					y_step,
					receivers[:],
					lights[:],
					l_idx,
					&sh_verts,
					&sh_inds,
					&poly_a,
					&poly_b,
				)
			}
		}
	}

	if len(sh_verts) >= 3 && first_owner != {} {
		engine.mesh_upsert_procedural(_scene_props_shadow_guid, sh_verts[:], sh_inds[:], nil, keep_cpu_buffers = false)
		append(out, engine.Render_Command{
			owner   = first_owner,
			variant = engine.Draw_Mesh{
				mesh  = _scene_props_shadow_guid,
				part  = 0,
				model = linalg.MATRIX4F32_IDENTITY,
			},
		})
	} else {
		engine.mesh_remove_procedural(_scene_props_shadow_guid)
	}
}

// Marks the volume's GPU mesh dirty so `csg_render_collector` uploads it safely before the next render pass
// (or uploads immediately in headless tests where `gfx.device() == nil`).
csg_volume_repack_gpu_mesh :: proc(vol: ^CSGVolume) {
	if vol == nil || vol.owner == {} do return
	_ensure_volume_guids(vol)
	vol.gpu_dirty = true
	if gfx.device() == nil {
		csg_volume_upload_gpu_now(vol)
	}
}

// Self-contained `Render_Collector` for `CSGVolume` (registered at `ImportersInit`).
// Ensures every `CSGVolume` is compiled, uploaded, and rendered in Edit Mode, Play Mode,
// after Undo/Redo, and after Scene Reloads without fragile fake `MeshFilter` disk GUIDs!
@(phase={key=engine.Phase.ImportersInit, order=4})
csg_render_collector_init :: proc() {
	@(static) registered := false
	if registered do return
	registered = true
	engine.render_register_collector(_collect_csg_volumes)
}

@(private = "file")
_collect_csg_volumes :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	w := engine.ctx_world()
	if w == nil do return

	// Drain any completed async Editor-mode blasts BEFORE collecting draw commands
	if !physics3d._state.world_ready {
		csg_drain_completed_results()
	}

	lights, light_sig := _resolve_scene_shadow_lights(context.temp_allocator)
	light := _resolve_scene_shadow_light()
	_, rec_sig := csg_collect_ground_receivers(light.ground_y if light.valid else 0.0, context.temp_allocator)
	combined_env_sig := (light_sig ~ rec_sig) * 1099511628211
	light_changed := combined_env_sig != _last_shadow_light_sig
	_last_shadow_light_sig = combined_env_sig

	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled do continue
		owner_h := engine.Transform_Handle(vol.owner)
		t := engine.pool_get(&w.transforms, engine.Handle(owner_h))
		if t == nil || !engine.transform_active_in_hierarchy(vol.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		if !vol.compiled {
			csg_volume_rebuild(vol)
		} else if light_changed && vol.cast_planar_shadows {
			// Re-bake chunk vertex self-shadowing and planar shadow mesh when any scene Light moves/rotates!
			sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
			combined_hulls := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)
			for _, ch in vol.chunks {
				if ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
					csg_voxel_triangulate_chunk(ch.voxel_grid, ch.indestructible_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
				} else {
					clear(&combined_hulls)
					append(&combined_hulls, ..ch.destructible_hulls[:])
					append(&combined_hulls, ..ch.indestructible_hulls[:])
					csg_triangulate_hulls(combined_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
				}
				ch.dirty_gpu = true
			}
			vol.gpu_dirty = true
		}
		if vol.gpu_dirty || !engine.mesh_is_cached(vol.mesh_guid) {
			csg_volume_upload_gpu_now(vol)
		}
		if !engine.mesh_is_cached(vol.mesh_guid) do continue

		tw := engine.transform_world(owner_h)
		model_mat := engine.trs_matrix(tw.position, tw.rotation, tw.scale)

		var_mats: []engine.Asset_GUID = nil
		outer_mat := vol.custom_material_guid
		if engine.asset_guid_is_empty(outer_mat) {
			if _, mr := engine.transform_get_comp(owner_h, engine.MeshRenderer); mr != nil && len(mr.materials) > 0 {
				outer_mat = mr.materials[0]
			}
		}
		cut_mat := vol.faker_cut_material_guid if !engine.asset_guid_is_empty(vol.faker_cut_material_guid) else outer_mat
		pal_len := len(vol.cut_material_palette)
		if !engine.asset_guid_is_empty(outer_mat) || !engine.asset_guid_is_empty(cut_mat) || pal_len > 0 {
			slot_cnt := max(2, min(pal_len + 1, 8))
			mat_slice := make([]engine.Asset_GUID, slot_cnt, context.temp_allocator)
			mat_slice[0] = outer_mat
			mat_slice[1] = cut_mat
			for pk in 0 ..< min(pal_len, 7) {
				pg := vol.cut_material_palette[pk]
				mat_slice[pk + 1] = pg if !engine.asset_guid_is_empty(pg) else cut_mat
			}
			var_mats = mat_slice
		}

		// "Faker Mesh" Hybrid Rendering Rule:
		// If `vol.is_faker_mesh` is enabled:
		//   - Inner Mesh `A` (`vol.faker_mesh_guid`) is ALWAYS rendered as an instance inside `B`
		//     (clipped to `B` if `B` was boolean-carved/sliced, and soft-deformed if `vol.faker_transfer_dents` is on).
		//   - Outer CSG Collider `B` (`vol`) is hidden on the outside (`vol.faker_hide_outer_shell`),
		//     and only renders `B`'s interior cut surfaces where `B` cuts INSIDE `A`!
		skip_outer_csg_chunks := false
		if vol.is_faker_mesh && !engine.asset_guid_is_empty(vol.faker_mesh_guid) {
			skip_outer_csg_chunks = _collect_faker_mesh_commands(vol, owner_h, model_mat, var_mats, out)
		} else if (vol.is_faker_mesh || vol.is_ghoul_bone_csg) && vol.faker_hide_outer_shell {
			// Bone-attached Ghoul CSG collider (outer shell hidden while ArmatureDeformedMesh renders the character skin!)
			skip_outer_csg_chunks = true
		}

		// Render per-chunk GPU meshes (voxel-style CSG chunks) when available, falling back to vol.mesh_guid
		rendered_chunks := false
		if !skip_outer_csg_chunks {
			for _, ch in vol.chunks {
				if len(ch.indices) == 0 || engine.asset_guid_is_empty(ch.chunk_mesh_guid) do continue
				if !engine.mesh_is_cached(ch.chunk_mesh_guid) do continue
				append(out, engine.Render_Command{
					owner   = owner_h,
					variant = engine.Draw_Mesh{
						mesh          = ch.chunk_mesh_guid,
						part          = 0,
						model         = model_mat,
						materials     = var_mats,
						unlit_heatmap = vol.deform_debug_heatmap,
					},
				})
				rendered_chunks = true
			}
			if !rendered_chunks && engine.mesh_is_cached(vol.mesh_guid) {
				append(out, engine.Render_Command{
					owner   = owner_h,
					variant = engine.Draw_Mesh{
						mesh          = vol.mesh_guid,
						part          = 0,
						model         = model_mat,
						materials     = var_mats,
						unlit_heatmap = vol.deform_debug_heatmap,
					},
				})
			}
		}

		// 1. Opaque Detail Instances mesh
		dg_guid := make_detail_and_glass_guid(vol.owner)
		if !engine.asset_guid_is_empty(dg_guid) && engine.mesh_is_cached(dg_guid) {
			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh          = dg_guid,
					part          = 0,
					model         = model_mat,
					unlit_heatmap = vol.deform_debug_heatmap,
				},
			})
		}
		// 2. Translucent See-Through Glass Panes mesh (bound to `csg_glass_material_guid()` which sorts LAST after opaque meshes!)
		glass_guid := make_glass_pane_guid(vol.owner)
		if !engine.asset_guid_is_empty(glass_guid) && engine.mesh_is_cached(glass_guid) {
			glass_mat_guid := csg_ensure_glass_material_ready()
			glass_mats := make([]engine.Asset_GUID, 1, context.temp_allocator)
			glass_mats[0] = glass_mat_guid
			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh      = glass_guid,
					part      = 0,
					model     = model_mat,
					materials = glass_mats,
				},
			})
		}

		// Render any surviving `Custom_Mesh_Asset` CSG-bound detail instances (`!inst.destroyed_in_ram`)
		for inst in vol.detail_instances {
			if inst.destroyed_in_ram || inst.preset != .Custom_Mesh_Asset || engine.asset_guid_is_empty(inst.custom_mesh) do continue
			q_yaw := linalg.quaternion_angle_axis_f32(inst.yaw_deg * (math.PI / 180.0), [3]f32{0, 1, 0})
			inst_local_mat := engine.trs_matrix(inst.local_pos, {q_yaw.x, q_yaw.y, q_yaw.z, q_yaw.w}, inst.scale)
			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh  = inst.custom_mesh,
					part  = 0,
					model = model_mat * inst_local_mat,
				},
			})
		}

		if vol.cast_planar_shadows && !vol.is_dynamic_rigidbody && len(lights) > 0 && engine.mesh_is_cached(vol.shadow_mesh_guid) {
			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh  = vol.shadow_mesh_guid,
					part  = 0,
					model = model_mat,
				},
			})
		}
	}

	// Also project planar floor shadows for standard MeshRenderer and SkinnedMeshRenderer objects across all shadow-casting Lights!
	if view.kind != .Preview {
		_collect_standard_mesh_shadows(w, view, lights[:], out)
	}
}

// Propagates a `CSG_Brush`'s RealtimeCSG `TexGen` surface parameters (`uv_offset`, `uv_rot_deg`, `uv_lock_brush`)
// onto every half-space plane of `hull`.
@(private = "file")
_apply_brush_texgen_to_hull :: #force_inline proc(hull: ^CSG_Convex, b: CSG_Brush) {
	if hull == nil do return
	for &p in hull.planes {
		p.uv_offset     = b.uv_offset
		p.uv_rot_deg    = b.uv_rot_deg
		p.uv_lock_brush = b.uv_lock_brush
	}
}

// When a Mesh GameObject (e.g. `PhysCube`) is converted into a `CSGVolume` or `Faker CSG`,
// any legacy primitive `BoxCollider`, `SphereCollider`, `CapsuleCollider`, or `Rigidbody`
// on the same entity must be retired so Jolt ONLY collides with the exact CSG convex hulls
// (and does not draw or collide with an uncut phantom BoxCollider!).
csg_retire_legacy_primitive_colliders :: proc(owner: engine.Transform_Handle, vol: ^CSGVolume) {
	if owner == {} || vol == nil || !vol.enabled || vol.is_ghoul_bone_csg do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(owner)) do return

	if _, rb := engine.transform_get_comp(owner, physics3d.Rigidbody); rb != nil {
		if rb.enabled && !rb.is_kinematic {
			vol.is_dynamic_rigidbody = true
		}
		engine.transform_destroy_comp(owner, physics3d.Rigidbody)
	}
	if _, bc := engine.transform_get_comp(owner, physics3d.BoxCollider); bc != nil {
		engine.transform_destroy_comp(owner, physics3d.BoxCollider)
	}
	if _, sc := engine.transform_get_comp(owner, physics3d.SphereCollider); sc != nil {
		engine.transform_destroy_comp(owner, physics3d.SphereCollider)
	}
	if _, cc := engine.transform_get_comp(owner, physics3d.CapsuleCollider); cc != nil {
		engine.transform_destroy_comp(owner, physics3d.CapsuleCollider)
	}
}

// Rebuilds the `CSGVolume` from its authored `brushes` array (and any detached `runtime_hulls`)
// into 8m^3 spatial chunks, subdividing oversized brushes along chunk boundaries so even huge
// single-volume CSG worlds stay fast and crash-free, updates SOA `brush_aabbs`, re-applies
// recorded blast craters per-chunk if `preserve_craters_on_rebuild` is enabled, triangulates all
// chunks, and marks the GPU mesh ready.
csg_volume_rebuild :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	csg_retire_legacy_primitive_colliders(vol.owner, vol)
	_ensure_volume_guids(vol)

	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	csg_volume_free_runtime(vol, clear_recorded_blasts = false)
	if vol.chunk_size < 2.0 {
		vol.chunk_size = CSG_DEFAULT_CHUNK_SIZE
	}

	vol.chunks = make(map[[3]i32]^CSG_Chunk, alloc)
	vol.brush_aabbs = make([dynamic][2][3]f32, len(vol.brushes), alloc)

	// 1. Build convex hulls for all additive brushes and subtract all subsequent subtractive brushes
	Add_Entry :: struct {
		brush_idx:    int,
		destructible: bool,
		hulls:        [dynamic]CSG_Convex,
	}
	entries := make([dynamic]Add_Entry, 0, len(vol.brushes) + 1, context.temp_allocator)
	defer {
		for &e in entries {
			for &h in e.hulls do convex_destroy(&h)
			delete(e.hulls)
		}
	}

	// Include any pre-carved / baked `runtime_hulls` (from Mesh->CSG, Bake CSG, or detached/split pieces!)
	if len(vol.runtime_hulls) > 0 {
		rt_list := make([dynamic]CSG_Convex, 0, len(vol.runtime_hulls), alloc)
		for rh in vol.runtime_hulls {
			if len(rh.planes) >= 4 {
				cloned := convex_clone(rh, alloc)
				if convex_rebuild_bounds_and_prune(&cloned, false) {
					append(&rt_list, cloned)
				} else {
					convex_destroy(&cloned)
				}
			}
		}
		if len(rt_list) > 0 {
			csg_subdivide_hulls_by_grid(&rt_list, vol.chunk_size, alloc)
			append(&entries, Add_Entry{
				brush_idx    = -1,
				destructible = true,
				hulls        = rt_list,
			})
		} else {
			delete(rt_list)
		}
	}

	for &b, idx in vol.brushes {
		if b.id == 0 {
			if vol.next_brush_id == 0 do vol.next_brush_id = 1
			b.id = vol.next_brush_id
			vol.next_brush_id += 1
		}
		if b.uv_scale <= 0.001 do b.uv_scale = 0.5
		if b.color.a == 0 do b.color = {210, 216, 224, 255}

		mat_slot: u8 = 0 if b.op == .Add else 1

		// 2D Polyline / Catmull-Rom Spline Extrusion Brush (`Brush_Primitive.Profile_2D`)
		if b.primitive == .Profile_2D && len(b.profile_points) >= 3 {
			prof_hulls := make([dynamic]CSG_Convex, 0, 8, alloc)
			p_min, p_max, p_ok := csg_extrude_profile_2d_hulls(
				b.profile_points[:],
				b.center,
				b.plane_u,
				b.plane_v,
				b.plane_normal,
				b.extrude_height,
				b.color,
				b.uv_scale,
				mat_slot,
				b.anchored,
				b.id,
				&prof_hulls,
				alloc,
			)
			if !p_ok || len(prof_hulls) == 0 {
				delete(prof_hulls)
				vol.brush_aabbs[idx] = {b.center - {0.5, 0.5, 0.5}, b.center + {0.5, 0.5, 0.5}}
				continue
			}
			for &ph in prof_hulls do _apply_brush_texgen_to_hull(&ph, b)
			vol.brush_aabbs[idx] = {p_min, p_max}
			if b.op == .Add {
				csg_subdivide_hulls_by_grid(&prof_hulls, vol.chunk_size, alloc)
				append(&entries, Add_Entry{
					brush_idx    = idx,
					destructible = b.destructible,
					hulls        = prof_hulls,
				})
			} else {
				for &ch_hull in prof_hulls {
					for &e in entries {
						convex_list_subtract(&e.hulls, ch_hull, alloc)
					}
					convex_destroy(&ch_hull)
				}
				delete(prof_hulls)
			}
			continue
		}

		hull, ok := csg_make_primitive_convex(
			b.primitive,
			b.center,
			b.size,
			b.yaw_deg,
			b.color,
			b.uv_scale,
			mat_slot,
			b.anchored,
			b.id,
			alloc,
		)
		if !ok {
			vol.brush_aabbs[idx] = {b.center - b.size * 0.5, b.center + b.size * 0.5}
			continue
		}
		_apply_brush_texgen_to_hull(&hull, b)
		// Record exact world/local AABB in contiguous SOA array
		vol.brush_aabbs[idx] = {hull.aabb_min, hull.aabb_max}

		if b.op == .Add {
			h_list := make([dynamic]CSG_Convex, 1, alloc)
			h_list[0] = hull
			// Partition oversized brushes along 8m spatial chunk grid boundaries!
			csg_subdivide_hulls_by_grid(&h_list, vol.chunk_size, alloc)
			append(&entries, Add_Entry{
				brush_idx    = idx,
				destructible = b.destructible,
				hulls        = h_list,
			})
		} else {
			// Subtract from all preceding additive brushes whose AABB overlaps (mark cut faces with `mat_slot = 1`)
			for &p in hull.planes do p.mat_slot = 1
			for &e in entries {
				convex_list_subtract(&e.hulls, hull, alloc)
			}
			convex_destroy(&hull)
		}
	}

	// 2. Assign each surviving convex polyhedron to its 8m x 8m x 8m spatial chunk based on its centroid
	inv_chunk := 1.0 / vol.chunk_size
	for &e in entries {
		for &h in e.hulls {
			coord := [3]i32{
				i32(math.floor(h.centroid.x * inv_chunk)),
				i32(math.floor(h.centroid.y * inv_chunk)),
				i32(math.floor(h.centroid.z * inv_chunk)),
			}
			ch, exists := vol.chunks[coord]
			if !exists {
				ch = new(CSG_Chunk, alloc)
				ch.coord = coord
				ch.aabb_min = h.aabb_min
				ch.aabb_max = h.aabb_max
				ch.destructible_hulls = make([dynamic]CSG_Convex, 0, 8, alloc)
				ch.indestructible_hulls = make([dynamic]CSG_Convex, 0, 4, alloc)
				ch.verts = make([dynamic]gfx.Vertex, 0, 64, alloc)
				ch.indices = make([dynamic]u32, 0, 128, alloc)
				ch.submeshes = make([dynamic]engine.Mesh_Submesh, 0, 2, alloc)
				ch.chunk_mesh_guid = _make_chunk_procedural_guid(vol.owner, coord)
				ch.dirty_physics = true
				ch.dirty_gpu = true
				vol.chunks[coord] = ch
			} else {
				ch.aabb_min.x = min(ch.aabb_min.x, h.aabb_min.x)
				ch.aabb_min.y = min(ch.aabb_min.y, h.aabb_min.y)
				ch.aabb_min.z = min(ch.aabb_min.z, h.aabb_min.z)
				ch.aabb_max.x = max(ch.aabb_max.x, h.aabb_max.x)
				ch.aabb_max.y = max(ch.aabb_max.y, h.aabb_max.y)
				ch.aabb_max.z = max(ch.aabb_max.z, h.aabb_max.z)
			}

			// Transfer ownership of `h` into chunk
			if e.destructible {
				append(&ch.destructible_hulls, h)
			} else {
				append(&ch.indestructible_hulls, h)
			}
			h.planes = nil
		}
		clear(&e.hulls)
	}

	// 2b. If `preserve_craters_on_rebuild` is enabled, re-apply recorded Red Faction blast craters
	// only to the specific spatial chunks whose AABB overlaps each blast; otherwise clear transient test blasts
	// and restore all CSG-bound detail instances & glass panes to their pristine `.scene` recipe state in RAM!
	if vol.preserve_craters_on_rebuild && len(vol.recorded_blasts) > 0 {
		scorch := [4]u8{255, 255, 255, 255} if !engine.asset_guid_is_empty(vol.faker_cut_material_guid) else [4]u8{88, 80, 74, 255}
		use_vox := (vol.destruction_backend == .Lazy_Voxel_SDF && !vol.is_ghoul_bone_csg)
		for rb in vol.recorded_blasts {
			b_min := rb.local_pos - [3]f32{rb.radius, rb.radius, rb.radius}
			b_max := rb.local_pos + [3]f32{rb.radius, rb.radius, rb.radius}
			rb_col  := rb.color if rb.color.a > 0 else scorch
			rb_slot := rb.mat_slot if rb.mat_slot > 0 else 1
			if use_vox {
				for _, ch in vol.chunks {
					if len(ch.destructible_hulls) == 0 && ch.voxel_grid == nil do continue
					if !aabb_overlaps(ch.aabb_min, ch.aabb_max, b_min, b_max, 0.25) do continue
					if ch.voxel_grid == nil {
						ch.voxel_grid = csg_voxel_grid_init_from_hulls(ch.destructible_hulls[:], ch.aabb_min, ch.aabb_max, alloc)
					}
					csg_voxel_carve_blast(ch.voxel_grid, rb.local_pos, rb.radius, rb.seed, csg_settings.blast_jaggedness, rb_col, rb_slot)
				}
			} else {
				cutter, c_ok := csg_make_blast_convex(rb.local_pos, rb.radius, rb.seed, csg_settings.blast_jaggedness, rb_col, context.temp_allocator, rb_slot)
				if c_ok {
					for _, ch in vol.chunks {
						if len(ch.destructible_hulls) == 0 do continue
						if !aabb_overlaps(ch.aabb_min, ch.aabb_max, b_min, b_max, 0.25) do continue
						convex_list_subtract(&ch.destructible_hulls, cutter, alloc)
					}
				}
			}
		}
		if use_vox {
			for _, ch in vol.chunks {
				if ch != nil && ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
					csg_voxel_build_greedy_hulls(ch.voxel_grid, &ch.destructible_hulls, alloc)
				}
			}
		}
		for rb in vol.recorded_blasts {
			_csg_apply_blast_to_instances_and_glass(vol, rb.local_pos, rb.local_pos, rb.radius, 0.0, rb.seed, false)
		}
	} else {
		if !vol.preserve_craters_on_rebuild && vol.recorded_blasts != nil {
			clear(&vol.recorded_blasts)
		}
		csg_volume_restore_ram_state(vol)
	}

	// 3. Smart-clean & triangulate each spatial chunk using the active scene Light direction (if any),
	//    passing touching hulls from neighboring chunks as `extra_sibling_hulls` so inter-chunk seam faces are 100% clipped!
	light := _resolve_scene_shadow_light()
	sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
	for _, ch in vol.chunks {
		if ch.voxel_grid == nil && len(ch.destructible_hulls) > 0 {
			_ = csg_clean_and_simplify_hulls(&ch.destructible_hulls, alloc)
		}
		if len(ch.indestructible_hulls) > 0 {
			_ = csg_clean_and_simplify_hulls(&ch.indestructible_hulls, alloc)
		}
	}

	combined_hulls := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)
	neighbor_hulls := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)
	for c_key, ch in vol.chunks {
		if ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
			csg_voxel_triangulate_chunk(ch.voxel_grid, ch.indestructible_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
			ch.dirty_physics = true
			ch.dirty_gpu = true
			continue
		}
		clear(&combined_hulls)
		clear(&neighbor_hulls)
		append(&combined_hulls, ..ch.destructible_hulls[:])
		append(&combined_hulls, ..ch.indestructible_hulls[:])
		if len(vol.chunks) > 1 {
			for n_key, n_ch in vol.chunks {
				if n_key == c_key || n_ch == nil do continue
				if !aabb_overlaps(ch.aabb_min, ch.aabb_max, n_ch.aabb_min, n_ch.aabb_max, 0.05) do continue
				for nh in n_ch.destructible_hulls {
					if aabb_overlaps(ch.aabb_min, ch.aabb_max, nh.aabb_min, nh.aabb_max, 0.05) {
						append(&neighbor_hulls, nh)
					}
				}
				for nh in n_ch.indestructible_hulls {
					if aabb_overlaps(ch.aabb_min, ch.aabb_max, nh.aabb_min, nh.aabb_max, 0.05) {
						append(&neighbor_hulls, nh)
					}
				}
			}
		}
		csg_triangulate_hulls(combined_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec, neighbor_hulls[:])
		ch.dirty_physics = true
		ch.dirty_gpu = true
	}

	// 4. Repack all chunks into the volume's GPU mesh
	csg_volume_repack_gpu_mesh(vol)
	vol.compiled = true
}

// Re-cooks and synchronizes JoltC physics colliders from the CURRENT chunk geometry
// (including any blasted craters!) WITHOUT rebuilding or resetting destroyed meshes!
csg_volume_sync_colliders_only :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	csg_retire_legacy_primitive_colliders(vol.owner, vol)
	if !vol.compiled {
		csg_volume_rebuild(vol)
	}
	if w := engine.ctx_world(); w != nil && physics3d._state.world_ready {
		vol.physics_world_id = w.id
	}
	for _, ch in vol.chunks {
		ch.dirty_physics = true
		if physics3d._state.world_ready && !vol.is_dynamic_rigidbody {
			_sync_chunk_physics_body(vol, ch)
		}
	}
	for &gp in vol.glass_panes {
		gp.dirty_physics = true
		if physics3d._state.world_ready {
			csg_sync_glass_pane_physics(vol, &gp)
		}
	}
	if physics3d._state.world_ready && vol.is_dynamic_rigidbody {
		_sync_volume_dynamic_body(vol, true)
	}
	if w := engine.ctx_world(); w != nil && vol.owner != {} && engine.pool_valid(&w.transforms, engine.Handle(vol.owner)) {
		tw := engine.transform_world(vol.owner)
		vol.last_physics_pos = tw.position
		vol.last_physics_rot = tw.rotation
		vol.has_physics_sync = true
	}
}

// Explicitly clears all recorded Red Faction blast craters, popped detail instances, and shattered glass cells
// in RAM and restores the volume to its pristine `.scene` CAD recipe!
csg_volume_reset_craters :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	if vol.recorded_blasts != nil {
		clear(&vol.recorded_blasts)
	}
	csg_volume_reset_soft_deform(vol)
	csg_volume_restore_ram_state(vol)
	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Removes a single recorded Red Faction blast crater by index (`blast_idx`) and rebuilds the volume.
csg_volume_remove_recorded_blast :: proc(vol: ^CSGVolume, blast_idx: int) {
	if vol == nil || blast_idx < 0 || blast_idx >= len(vol.recorded_blasts) do return
	ordered_remove(&vol.recorded_blasts, blast_idx)
	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// Bakes all authored brushes, boolean subtractions, extrusions/intrusions, and recorded blast craters
// of `vol` into clean, self-contained `vol.runtime_hulls` (persisted in `.scene` for Scene Composition!).
// The baked `CSGVolume` remains 100% destructible at runtime and loads without re-running boolean history!
csg_volume_bake_changes :: proc(vol: ^CSGVolume) -> int {
	if vol == nil do return 0
	if !vol.compiled {
		csg_volume_rebuild(vol)
	}

	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	baked := make([dynamic]CSG_Convex, 0, 32, alloc)
	for _, ch in vol.chunks {
		if ch == nil do continue
		for h in ch.destructible_hulls {
			if len(h.planes) >= 4 {
				append(&baked, convex_clone(h, alloc))
			}
		}
		for h in ch.indestructible_hulls {
			if len(h.planes) >= 4 {
				append(&baked, convex_clone(h, alloc))
			}
		}
	}
	if len(baked) == 0 {
		delete(baked)
		return 0
	}
	if len(baked) > 1 {
		_ = csg_clean_and_simplify_hulls(&baked, alloc)
	}

	// Replace `runtime_hulls` with the baked convex polyhedra and clear the construction history
	if vol.runtime_hulls != nil {
		for &rh in vol.runtime_hulls do convex_destroy(&rh)
		delete(vol.runtime_hulls)
	}
	vol.runtime_hulls = baked

	if vol.brushes != nil {
		context.allocator = prev_alloc
		for &b in vol.brushes {
			if len(b.name) > 0 do delete(b.name)
			if b.profile_points != nil do delete(b.profile_points)
		}
		clear(&vol.brushes)
		context.allocator = alloc
	}
	if vol.recorded_blasts != nil {
		clear(&vol.recorded_blasts)
	}

	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return len(vol.runtime_hulls)
}

// Registers `mat_guid` in `vol.cut_material_palette` (slots `1..7`) and returns the `mat_slot` (`1..7`)
// so each cut or blast crater retains its own independent Fill Texture without overwriting earlier cuts!
csg_volume_register_cut_material :: proc(vol: ^CSGVolume, mat_guid: engine.Asset_GUID) -> u8 {
	if vol == nil do return 1
	eff_guid := mat_guid
	if engine.asset_guid_is_empty(eff_guid) {
		outer_mat := vol.custom_material_guid
		if engine.asset_guid_is_empty(outer_mat) {
			w := engine.ctx_world()
			if w != nil && vol.owner != {} && engine.pool_valid(&w.transforms, engine.Handle(vol.owner)) {
				if _, mr := engine.transform_get_comp(vol.owner, engine.MeshRenderer); mr != nil && len(mr.materials) > 0 {
					outer_mat = mr.materials[0]
				}
			}
		}
		eff_guid = outer_mat
		if engine.asset_guid_is_empty(eff_guid) do return 1
	}
	for existing, idx in vol.cut_material_palette {
		if existing == eff_guid {
			return u8(clamp(idx + 1, 1, 7))
		}
	}
	prev_a := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_a
	if vol.cut_material_palette == nil {
		vol.cut_material_palette = make([dynamic]engine.Asset_GUID, 0, 8)
	}
	if len(vol.cut_material_palette) < 7 {
		append(&vol.cut_material_palette, eff_guid)
		return u8(len(vol.cut_material_palette))
	}
	vol.cut_material_palette[6] = eff_guid
	return 7
}

// SabreCSG / RealtimeCSG 2-Point Clip Plane Slicer for a `CSGVolume`:
// Consolidates authored brushes into `vol.runtime_hulls` (if not already baked) and slices all
// straddling hulls along `(local_normal, local_dist)` using `mode` (`Split_Both`, `Keep_Back`, or `Keep_Front`).
// When `mode == .Split_Both` in an active scene and both halves are non-empty, detaches the `+N` front half
// into a second standalone `CSGVolume` GameObject (`<Name>_SplitHalf`) with its own centered Transform & Jolt collider!
csg_volume_clip_by_plane :: proc(
	vol:                   ^CSGVolume,
	local_normal:          [3]f32,
	local_dist:            f32,
	mode:                  CSG_Clip_Mode,
	split_gap:             f32 = 0.0,
	cut_material_override: engine.Asset_GUID = {},
	cut_albedo_override:   [4]u8 = {0, 0, 0, 0},
) -> (sliced_count: int) {
	if vol == nil do return 0
	if !engine.asset_guid_is_empty(cut_material_override) && engine.asset_guid_is_empty(vol.faker_cut_material_guid) {
		vol.faker_cut_material_guid = cut_material_override
	}
	cap_slot := csg_volume_register_cut_material(vol, cut_material_override)
	cap_col  := cut_albedo_override
	if cap_col.a == 0 && !engine.asset_guid_is_empty(cut_material_override) {
		cap_col = {255, 255, 255, 255}
	}
	_flush_in_flight_worker_blasts()
	if !vol.compiled {
		csg_volume_rebuild(vol)
	}

	// O(1) Fast Plane-vs-AABB Reject: if the cutting plane does not actually clip or straddle `vol`,
	// exit immediately in O(1) without baking, cloning, or rebuilding anything!
	if lo, hi, aok := csg_volume_local_aabb(vol); aok {
		min_s: f32 =  1e30
		max_s: f32 = -1e30
		for cx in 0 ..< 2 {
			for cy in 0 ..< 2 {
				for cz in 0 ..< 2 {
					c_pt := [3]f32{
						lo.x if cx == 0 else hi.x,
						lo.y if cy == 0 else hi.y,
						lo.z if cz == 0 else hi.z,
					}
					s := linalg.dot(local_normal, c_pt) - local_dist
					min_s = min(min_s, s)
					max_s = max(max_s, s)
				}
			}
		}
		if mode == .Split_Both && (min_s >= -1e-3 || max_s <= 1e-3) {
			return 0
		}
		if mode == .Keep_Back && max_s <= 1e-3 {
			return 0
		}
		if mode == .Keep_Front && min_s >= -1e-3 {
			return 0
		}
	}

	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	saved_vox_blasts := make([dynamic]CSG_Recorded_Blast, 0, len(vol.recorded_blasts), context.temp_allocator)
	if vol.destruction_backend == .Lazy_Voxel_SDF && len(vol.recorded_blasts) > 0 && !vol.is_ghoul_bone_csg {
		append(&saved_vox_blasts, ..vol.recorded_blasts[:])
		clear(&vol.recorded_blasts)
	}

	// Consolidate active chunk hulls directly into `vol.runtime_hulls` in a single O(N) pass
	// (WITHOUT running a redundant pre-slice `csg_volume_rebuild` or `csg_clean_and_simplify_hulls`!).
	// Crucial for `.fmesh`-hybrid Voxel SDF chunks: extract `ch.voxel_grid.base_shell_hulls` (the razor-sharp
	// original CSG outer polyhedra) instead of `ch.destructible_hulls` (which are the greedy voxel collision boxes!),
	// then re-carve `saved_vox_blasts` after slicing so sliced voxel objects stay 100% razor-sharp!
	if len(vol.brushes) > 0 || len(vol.chunks) > 0 {
		extracted := make([dynamic]CSG_Convex, 0, max(len(vol.runtime_hulls), 8), alloc)
		for _, ch in vol.chunks {
			if ch == nil do continue
			if ch.voxel_grid != nil && len(ch.voxel_grid.base_shell_hulls) > 0 {
				for h in ch.voxel_grid.base_shell_hulls {
					if len(h.planes) >= 4 {
						append(&extracted, convex_clone(h, alloc))
					}
				}
			} else {
				for h in ch.destructible_hulls {
					if len(h.planes) >= 4 {
						append(&extracted, convex_clone(h, alloc))
					}
				}
			}
			for h in ch.indestructible_hulls {
				if len(h.planes) >= 4 {
					ic := convex_clone(h, alloc)
					ic.anchored = true
					append(&extracted, ic)
				}
			}
		}
		if len(extracted) > 0 {
			for &rh in vol.runtime_hulls do convex_destroy(&rh)
			delete(vol.runtime_hulls)
			vol.runtime_hulls = extracted
			for &b in vol.brushes {
				if b.profile_points != nil do delete(b.profile_points)
			}
			clear(&vol.brushes)
			if len(saved_vox_blasts) == 0 {
				clear(&vol.recorded_blasts)
			}
		} else {
			delete(extracted)
		}
	}
	if len(vol.runtime_hulls) == 0 do return 0

	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	has_scene_owner := w != nil && scene != nil && vol.owner != {} &&
	                   engine.pool_get(&w.transforms, engine.Handle(vol.owner)) != nil

	// For bone-attached Ghoul CSG volumes, never split a skeleton bone into two Transform entities or move the bone joint:
	// - For core trunk bones (`Hips`, `Pelvis`, `Spine`, `Chest`, `Torso`, `Root`), `Split_Both` slices `runtime_hulls`
	//   into BOTH `back_hulls` and `front_hulls` in-place with a wound gash gap so the upper body never disappears!
	// - For appendicular limb bones (`Arm`, `ForeArm`, `UpLeg`, `Leg`), `Split_Both` keeps the proximal `{0,0,0}` half.
	eff_mode := mode
	ghoul_in_place_split := false
	if vol.is_ghoul_bone_csg && eff_mode == .Split_Both {
		is_trunk := false
		if w != nil && vol.owner != {} {
			if bt := engine.pool_get(&w.transforms, engine.Handle(vol.owner)); bt != nil {
				// Check if parent transform also has a Ghoul CSGVolume; if not (or name is Hips/Pelvis/Spine/Chest/Root), it's a trunk bone!
				if bt.parent.handle == {} {
					is_trunk = true
				} else {
					_, p_vol := engine.transform_get_comp(engine.Transform_Handle(bt.parent.handle), CSGVolume)
					if p_vol == nil || !p_vol.is_ghoul_bone_csg {
						is_trunk = true
					}
				}
				// Also check bone name for Spine / Chest / Pelvis / Hips / Torso
				if !is_trunk && len(bt.name) >= 4 {
					low_buf: [64]u8
					n_len := min(len(bt.name), 64)
					for ci in 0 ..< n_len {
						ch_c := bt.name[ci]
						if ch_c >= 'A' && ch_c <= 'Z' do ch_c += 32
						low_buf[ci] = ch_c
					}
					low_s := string(low_buf[:n_len])
					has_sub :: proc(s, sub: string) -> bool {
						if len(sub) > len(s) do return false
						for i in 0 ..= len(s) - len(sub) {
							if s[i:i + len(sub)] == sub do return true
						}
						return false
					}
					if (has_sub(low_s, "hip") || has_sub(low_s, "pelvis") || has_sub(low_s, "spine") ||
					    has_sub(low_s, "chest") || has_sub(low_s, "torso") || has_sub(low_s, "waist")) &&
					   !has_sub(low_s, "leg") && !has_sub(low_s, "arm") {
						is_trunk = true
					}
				}
			}
		}
		if is_trunk {
			ghoul_in_place_split = true
		} else {
			eff_mode = .Keep_Back if local_dist >= 0.0 else .Keep_Front
		}
	}

	if ghoul_in_place_split {
		g_gap    := max(split_gap, 0.016)
		combined := make([dynamic]CSG_Convex, 0, len(vol.runtime_hulls) * 2, alloc)
		for &h in vol.runtime_hulls {
			sb := csg_clip_convex_by_plane(h, local_normal, local_dist, .Keep_Back,  &combined, g_gap, alloc, cap_slot, cap_col)
			sf := csg_clip_convex_by_plane(h, local_normal, local_dist, .Keep_Front, &combined, g_gap, alloc, cap_slot, cap_col)
			if sb || sf {
				sliced_count += 1
			}
			convex_destroy(&h)
		}
		delete(vol.runtime_hulls)
		vol.runtime_hulls = combined
	} else if eff_mode == .Split_Both && has_scene_owner {
		back_hulls  := make([dynamic]CSG_Convex, 0, len(vol.runtime_hulls), alloc)
		front_hulls := make([dynamic]CSG_Convex, 0, len(vol.runtime_hulls), alloc)

		for &h in vol.runtime_hulls {
			sb := csg_clip_convex_by_plane(h, local_normal, local_dist, .Keep_Back,  &back_hulls,  split_gap, alloc, cap_slot, cap_col)
			sf := csg_clip_convex_by_plane(h, local_normal, local_dist, .Keep_Front, &front_hulls, split_gap, alloc, cap_slot, cap_col)
			if sb || sf {
				sliced_count += 1
			}
			convex_destroy(&h)
		}
		delete(vol.runtime_hulls)

		if len(back_hulls) > 0 && len(front_hulls) > 0 {
			// Helper to compute AABB center of a hull list and shift all planes by `-pivot`
			recenter_hull_list :: proc(list: ^[dynamic]CSG_Convex) -> [3]f32 {
				bmin := [3]f32{ 1e30,  1e30,  1e30}
				bmax := [3]f32{-1e30, -1e30, -1e30}
				for &ch in list^ {
					bmin = linalg.min(bmin, ch.aabb_min)
					bmax = linalg.max(bmax, ch.aabb_max)
				}
				pivot := (bmin + bmax) * 0.5
				if linalg.length2(pivot) > 1e-6 {
					for &ch in list^ {
						for &p in ch.planes {
							p.dist -= linalg.dot(p.normal, pivot)
						}
						convex_rebuild_bounds_and_prune(&ch, prune_redundant = false)
					}
				}
				return pivot
			}

			vol_owner := engine.Transform_Handle(vol.owner)
			tw := engine.transform_world(vol_owner)
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)

			// Free all existing Jolt static/dynamic bodies on `vol` BEFORE shifting `tr_orig.position`
			// so zero pre-slice ghost colliders remain at the old origin!
			csg_volume_free_runtime(vol, clear_recorded_blasts = false)

			back_pivot  := recenter_hull_list(&back_hulls)
			front_pivot := recenter_hull_list(&front_hulls)

			vol.runtime_hulls = back_hulls
			orig_faker_offset := vol.faker_mesh_offset
			if vol.is_faker_mesh {
				vol.faker_mesh_offset = orig_faker_offset - back_pivot
			}
			if tr_orig := engine.pool_get(&w.transforms, engine.Handle(vol_owner)); tr_orig != nil {
				tr_orig.position = (model * [4]f32{back_pivot.x, back_pivot.y, back_pivot.z, 1.0}).xyz
			}

			// Spawn a second standalone CSGVolume entity for `front_hulls` using the caller's world allocator (`prev_alloc`)
			// so `t.name` and `t.children` match the allocator used by `transform_destroy`!
			parent_h := engine.Transform_Handle(scene.root.handle)
			orig_name := "CSG_Sliced"
			if tr_orig := engine.pool_get(&w.transforms, engine.Handle(vol_owner)); tr_orig != nil && len(tr_orig.name) > 0 {
				orig_name = tr_orig.name
				if tr_orig.parent.handle != {} {
					parent_h = engine.Transform_Handle(tr_orig.parent.handle)
				}
			}
			context.allocator = prev_alloc
			new_h := engine.transform_new(orig_name, parent_h)
			engine.transform_ensure_unique_name(new_h)
			if nt := engine.pool_get(&w.transforms, engine.Handle(new_h)); nt != nil {
				nt.position = (model * [4]f32{front_pivot.x, front_pivot.y, front_pivot.z, 1.0}).xyz
				nt.rotation = tw.rotation
				nt.scale    = tw.scale
			}

			_, new_ptr := engine.transform_add_comp(new_h, .CSGVolume)
			context.allocator = alloc
			new_vol := cast(^CSGVolume)new_ptr
			if new_vol != nil {
				reset_CSGVolume(new_vol)
				// Re-fetch `vol` in case `transform_add_comp` reallocated the `CSGVolume` component pool!
				_, vol_re := engine.transform_get_comp(vol_owner, CSGVolume)
				if vol_re != nil {
					new_vol.chunk_size                 = vol_re.chunk_size
					new_vol.ground_y                   = vol_re.ground_y - front_pivot.y
					new_vol.is_dynamic_rigidbody       = vol_re.is_dynamic_rigidbody
					new_vol.enable_structural_collapse = vol_re.enable_structural_collapse
					new_vol.spawn_debris               = vol_re.spawn_debris
					new_vol.cast_planar_shadows        = vol_re.cast_planar_shadows
					new_vol.debris_collider_mode       = vol_re.debris_collider_mode
					new_vol.material_preset            = vol_re.material_preset
					new_vol.custom_material_guid       = vol_re.custom_material_guid
					new_vol.soft_deform_enabled        = vol_re.soft_deform_enabled
					new_vol.is_faker_mesh              = vol_re.is_faker_mesh
					new_vol.faker_mesh_guid            = vol_re.faker_mesh_guid
					new_vol.faker_material_guid        = vol_re.faker_material_guid
					new_vol.faker_cut_material_guid    = vol_re.faker_cut_material_guid
					new_vol.faker_shape_kind           = vol_re.faker_shape_kind
					new_vol.faker_margin               = vol_re.faker_margin
					new_vol.faker_mesh_scale           = vol_re.faker_mesh_scale
					new_vol.faker_mesh_rot_deg         = vol_re.faker_mesh_rot_deg
					new_vol.faker_mesh_offset          = orig_faker_offset - front_pivot
					new_vol.faker_hide_outer_shell     = vol_re.faker_hide_outer_shell
					new_vol.faker_render_cut_interior  = vol_re.faker_render_cut_interior
					new_vol.faker_transfer_dents       = vol_re.faker_transfer_dents
					new_vol.faker_split_on_slice       = vol_re.faker_split_on_slice
					new_vol.destruction_backend        = vol_re.destruction_backend
					new_vol.preserve_craters_on_rebuild = true
					vol_re.preserve_craters_on_rebuild  = true
					if len(vol_re.cut_material_palette) > 0 {
						clear(&new_vol.cut_material_palette)
						append(&new_vol.cut_material_palette, ..vol_re.cut_material_palette[:])
					}
					if len(saved_vox_blasts) > 0 {
						for sb in saved_vox_blasts {
							sb_back  := sb
							sb_front := sb
							sb_back.local_pos  -= back_pivot
							sb_front.local_pos -= front_pivot
							append(&vol_re.recorded_blasts, sb_back)
							append(&new_vol.recorded_blasts, sb_front)
						}
					}
					if new_vol.runtime_hulls != nil {
						delete(new_vol.runtime_hulls)
					}
					new_vol.runtime_hulls = front_hulls

					csg_volume_rebuild(vol_re)
					csg_volume_sync_colliders_only(vol_re)
				}
				csg_volume_rebuild(new_vol)
				csg_volume_sync_colliders_only(new_vol)
				// Wake any Jolt bodies overlapping the sliced region so dynamic halves/props settle immediately
				if physics3d._state.world_ready && physics3d._state.system != nil {
					wake_box := jolt.AABox{
						min = tw.position - [3]f32{6.0, 6.0, 6.0},
						max = tw.position + [3]f32{6.0, 6.0, 6.0},
					}
					jolt.PhysicsSystem_ActivateBodiesInAABox(
						physics3d._state.system,
						&wake_box,
						physics3d.LAYER_MOVING,
					)
				}
			} else {
				for &fh in front_hulls do convex_destroy(&fh)
				delete(front_hulls)
			}
			scene.dirty = true
			return sliced_count
		} else if len(back_hulls) > 0 {
			delete(front_hulls)
			vol.runtime_hulls = back_hulls
		} else {
			delete(back_hulls)
			vol.runtime_hulls = front_hulls
		}
	} else {
		sliced_count = csg_clip_hull_list_by_plane(&vol.runtime_hulls, local_normal, local_dist, eff_mode, split_gap, alloc, cap_slot, cap_col)
	}

	if len(saved_vox_blasts) > 0 {
		vol.preserve_craters_on_rebuild = true
		for sb in saved_vox_blasts {
			append(&vol.recorded_blasts, sb)
		}
	}
	csg_volume_rebuild(vol)
	// Pop/hide any CSG-bound detail instances whose backing CSG hull was sliced away by `Keep_Back` / `Keep_Front`!
	if eff_mode != .Split_Both && len(vol.detail_instances) > 0 {
		_csg_apply_blast_to_instances_and_glass(vol, {}, {}, 0.0, 5.0, 777)
		csg_volume_repack_gpu_mesh(vol)
	}
	csg_volume_sync_colliders_only(vol)
	if scene != nil do scene.dirty = true
	return sliced_count
}

// Chisel / RealtimeCSG Dirty-Brush-AABB Partial Chunk Rebuilder:
// When dragging a brush gizmo (Move / Rotate / Scale) inside a large multi-chunk `CSGVolume`,
// only rebuilds the spatial chunks overlapping `[dirty_min, dirty_max]` (`old_aabb ∪ new_aabb`),
// leaving all non-overlapping chunks untouched! Returns the number of chunks rebuilt.
csg_volume_rebuild_dirty_aabb :: proc(vol: ^CSGVolume, dirty_min, dirty_max: [3]f32) -> (rebuilt_chunks: int) {
	if vol == nil do return 0
	if !vol.compiled || vol.chunks == nil || len(vol.chunks) <= 1 {
		csg_volume_rebuild(vol)
		return len(vol.chunks)
	}

	_ensure_volume_guids(vol)
	if vol.chunk_size < 2.0 {
		vol.chunk_size = CSG_DEFAULT_CHUNK_SIZE
	}

	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	cs := vol.chunk_size
	inv_chunk := 1.0 / cs
	margin :: f32(0.25)
	lo_m := linalg.min(dirty_min, dirty_max) - [3]f32{margin, margin, margin}
	hi_m := linalg.max(dirty_min, dirty_max) + [3]f32{margin, margin, margin}

	c_min := [3]i32{
		i32(math.floor(lo_m.x * inv_chunk)),
		i32(math.floor(lo_m.y * inv_chunk)),
		i32(math.floor(lo_m.z * inv_chunk)),
	}
	c_max := [3]i32{
		i32(math.floor(hi_m.x * inv_chunk)),
		i32(math.floor(hi_m.y * inv_chunk)),
		i32(math.floor(hi_m.z * inv_chunk)),
	}
	region_min := [3]f32{f32(c_min.x) * cs, f32(c_min.y) * cs, f32(c_min.z) * cs}
	region_max := [3]f32{f32(c_max.x + 1) * cs, f32(c_max.y + 1) * cs, f32(c_max.z + 1) * cs}

	if len(vol.brush_aabbs) != len(vol.brushes) {
		delete(vol.brush_aabbs)
		vol.brush_aabbs = make([dynamic][2][3]f32, len(vol.brushes), alloc)
	}

	Add_Entry :: struct {
		brush_idx:    int,
		destructible: bool,
		hulls:        [dynamic]CSG_Convex,
	}
	entries := make([dynamic]Add_Entry, 0, len(vol.brushes) + 1, context.temp_allocator)
	defer {
		for &e in entries {
			for &h in e.hulls do convex_destroy(&h)
			delete(e.hulls)
		}
	}

	// 1. Include any `runtime_hulls` overlapping the dirty chunk region
	if len(vol.runtime_hulls) > 0 {
		rt_list := make([dynamic]CSG_Convex, 0, len(vol.runtime_hulls), alloc)
		for rh in vol.runtime_hulls {
			if len(rh.planes) >= 4 && aabb_overlaps(rh.aabb_min, rh.aabb_max, region_min, region_max, 0.05) {
				cloned := convex_clone(rh, alloc)
				if convex_rebuild_bounds_and_prune(&cloned, false) {
					append(&rt_list, cloned)
				} else {
					convex_destroy(&cloned)
				}
			}
		}
		if len(rt_list) > 0 {
			csg_subdivide_hulls_by_grid(&rt_list, cs, alloc)
			append(&entries, Add_Entry{
				brush_idx    = -1,
				destructible = true,
				hulls        = rt_list,
			})
		} else {
			delete(rt_list)
		}
	}

	// 2. Evaluate brushes overlapping `[region_min, region_max]` (and update SOA `brush_aabbs`)
	for &b, idx in vol.brushes {
		if b.id == 0 {
			if vol.next_brush_id == 0 do vol.next_brush_id = 1
			b.id = vol.next_brush_id
			vol.next_brush_id += 1
		}
		if b.uv_scale <= 0.001 do b.uv_scale = 0.5
		if b.color.a == 0 do b.color = {210, 216, 224, 255}
		mat_slot: u8 = 0 if b.op == .Add else 1

		if b.primitive == .Profile_2D && len(b.profile_points) >= 3 {
			prof_hulls := make([dynamic]CSG_Convex, 0, 8, alloc)
			p_min, p_max, p_ok := csg_extrude_profile_2d_hulls(
				b.profile_points[:], b.center, b.plane_u, b.plane_v, b.plane_normal,
				b.extrude_height, b.color, b.uv_scale, mat_slot, b.anchored, b.id, &prof_hulls, alloc,
			)
			if !p_ok || len(prof_hulls) == 0 {
				delete(prof_hulls)
				vol.brush_aabbs[idx] = {b.center - {0.5, 0.5, 0.5}, b.center + {0.5, 0.5, 0.5}}
				continue
			}
			for &ph in prof_hulls do _apply_brush_texgen_to_hull(&ph, b)
			vol.brush_aabbs[idx] = {p_min, p_max}
			if !aabb_overlaps(p_min, p_max, region_min, region_max, 0.05) {
				for &ph in prof_hulls do convex_destroy(&ph)
				delete(prof_hulls)
				continue
			}
			if b.op == .Add {
				csg_subdivide_hulls_by_grid(&prof_hulls, cs, alloc)
				append(&entries, Add_Entry{brush_idx = idx, destructible = b.destructible, hulls = prof_hulls})
			} else {
				for &ch_hull in prof_hulls {
					for &e in entries do convex_list_subtract(&e.hulls, ch_hull, alloc)
					convex_destroy(&ch_hull)
				}
				delete(prof_hulls)
			}
			continue
		}

		// Fast AABB pre-check for standard primitives before building full convex hull if clearly far away
		max_half := max(b.size.x, max(b.size.y, b.size.z)) * 0.75
		est_min := b.center - [3]f32{max_half, max_half, max_half}
		est_max := b.center + [3]f32{max_half, max_half, max_half}
		if !aabb_overlaps(est_min, est_max, region_min, region_max, 0.1) {
			continue
		}

		hull, ok := csg_make_primitive_convex(
			b.primitive, b.center, b.size, b.yaw_deg, b.color, b.uv_scale, mat_slot, b.anchored, b.id, alloc,
		)
		if !ok {
			vol.brush_aabbs[idx] = {b.center - b.size * 0.5, b.center + b.size * 0.5}
			continue
		}
		_apply_brush_texgen_to_hull(&hull, b)
		vol.brush_aabbs[idx] = {hull.aabb_min, hull.aabb_max}

		if !aabb_overlaps(hull.aabb_min, hull.aabb_max, region_min, region_max, 0.05) {
			convex_destroy(&hull)
			continue
		}

		if b.op == .Add {
			h_list := make([dynamic]CSG_Convex, 1, alloc)
			h_list[0] = hull
			csg_subdivide_hulls_by_grid(&h_list, cs, alloc)
			append(&entries, Add_Entry{brush_idx = idx, destructible = b.destructible, hulls = h_list})
		} else {
			for &e in entries {
				convex_list_subtract(&e.hulls, hull, alloc)
			}
			convex_destroy(&hull)
		}
	}

	// 3. Free & remove ONLY the existing chunks whose `coord` falls inside `[c_min .. c_max]`
	dirty_coords := make([dynamic][3]i32, 0, 16, context.temp_allocator)
	for coord, ch in vol.chunks {
		if coord.x >= c_min.x && coord.x <= c_max.x &&
		   coord.y >= c_min.y && coord.y <= c_max.y &&
		   coord.z >= c_min.z && coord.z <= c_max.z {
			append(&dirty_coords, coord)
			_chunk_free(ch, true)
		}
	}
	for dc in dirty_coords {
		delete_key(&vol.chunks, dc)
	}

	// 4. Repopulate ONLY the chunks in `[c_min .. c_max]`
	touched_chunks := make(map[[3]i32]^CSG_Chunk, 16, context.temp_allocator)
	for &e in entries {
		for &h in e.hulls {
			coord := [3]i32{
				i32(math.floor(h.centroid.x * inv_chunk)),
				i32(math.floor(h.centroid.y * inv_chunk)),
				i32(math.floor(h.centroid.z * inv_chunk)),
			}
			if coord.x < c_min.x || coord.x > c_max.x ||
			   coord.y < c_min.y || coord.y > c_max.y ||
			   coord.z < c_min.z || coord.z > c_max.z {
				convex_destroy(&h)
				h.planes = nil
				continue
			}

			ch, exists := vol.chunks[coord]
			if !exists {
				ch = new(CSG_Chunk, alloc)
				ch.coord = coord
				ch.aabb_min = h.aabb_min
				ch.aabb_max = h.aabb_max
				ch.destructible_hulls = make([dynamic]CSG_Convex, 0, 8, alloc)
				ch.indestructible_hulls = make([dynamic]CSG_Convex, 0, 4, alloc)
				ch.verts = make([dynamic]gfx.Vertex, 0, 64, alloc)
				ch.indices = make([dynamic]u32, 0, 128, alloc)
				ch.submeshes = make([dynamic]engine.Mesh_Submesh, 0, 2, alloc)
				ch.chunk_mesh_guid = _make_chunk_procedural_guid(vol.owner, coord)
				ch.dirty_physics = true
				ch.dirty_gpu = true
				vol.chunks[coord] = ch
			} else {
				ch.aabb_min.x = min(ch.aabb_min.x, h.aabb_min.x)
				ch.aabb_min.y = min(ch.aabb_min.y, h.aabb_min.y)
				ch.aabb_min.z = min(ch.aabb_min.z, h.aabb_min.z)
				ch.aabb_max.x = max(ch.aabb_max.x, h.aabb_max.x)
				ch.aabb_max.y = max(ch.aabb_max.y, h.aabb_max.y)
				ch.aabb_max.z = max(ch.aabb_max.z, h.aabb_max.z)
			}
			touched_chunks[coord] = ch

			if e.destructible {
				append(&ch.destructible_hulls, h)
			} else {
				append(&ch.indestructible_hulls, h)
			}
			h.planes = nil
		}
		clear(&e.hulls)
	}

	// 5. Re-apply recorded craters ONLY to the dirty chunks
	if vol.preserve_craters_on_rebuild && len(vol.recorded_blasts) > 0 && len(touched_chunks) > 0 {
		scorch := [4]u8{255, 255, 255, 255} if !engine.asset_guid_is_empty(vol.faker_cut_material_guid) else [4]u8{88, 80, 74, 255}
		use_vox := (vol.destruction_backend == .Lazy_Voxel_SDF && !vol.is_ghoul_bone_csg)
		for rb in vol.recorded_blasts {
			b_min := rb.local_pos - [3]f32{rb.radius, rb.radius, rb.radius}
			b_max := rb.local_pos + [3]f32{rb.radius, rb.radius, rb.radius}
			if !aabb_overlaps(region_min, region_max, b_min, b_max, 0.25) do continue
			rb_col  := rb.color if rb.color.a > 0 else scorch
			rb_slot := rb.mat_slot if rb.mat_slot > 0 else 1
			if use_vox {
				for _, ch in touched_chunks {
					if len(ch.destructible_hulls) == 0 && ch.voxel_grid == nil do continue
					if !aabb_overlaps(ch.aabb_min, ch.aabb_max, b_min, b_max, 0.25) do continue
					if ch.voxel_grid == nil {
						ch.voxel_grid = csg_voxel_grid_init_from_hulls(ch.destructible_hulls[:], ch.aabb_min, ch.aabb_max, alloc)
					}
					csg_voxel_carve_blast(ch.voxel_grid, rb.local_pos, rb.radius, rb.seed, csg_settings.blast_jaggedness, rb_col, rb_slot)
				}
			} else {
				cutter, c_ok := csg_make_blast_convex(rb.local_pos, rb.radius, rb.seed, csg_settings.blast_jaggedness, rb_col, context.temp_allocator, rb_slot)
				if c_ok {
					for _, ch in touched_chunks {
						if len(ch.destructible_hulls) == 0 do continue
						if !aabb_overlaps(ch.aabb_min, ch.aabb_max, b_min, b_max, 0.25) do continue
						convex_list_subtract(&ch.destructible_hulls, cutter, alloc)
					}
				}
			}
		}
		if use_vox {
			for _, ch in touched_chunks {
				if ch != nil && ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
					csg_voxel_build_greedy_hulls(ch.voxel_grid, &ch.destructible_hulls, alloc)
				}
			}
		}
	}

	// 6. Smart-clean & re-triangulate ONLY the touched dirty chunks!
	light := _resolve_scene_shadow_light()
	sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
	combined_hulls := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)
	for _, ch in touched_chunks {
		if ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
			if len(ch.indestructible_hulls) > 0 {
				_ = csg_clean_and_simplify_hulls(&ch.indestructible_hulls, alloc)
			}
			csg_voxel_triangulate_chunk(ch.voxel_grid, ch.indestructible_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
		} else {
			if len(ch.destructible_hulls) > 0 {
				_ = csg_clean_and_simplify_hulls(&ch.destructible_hulls, alloc)
			}
			if len(ch.indestructible_hulls) > 0 {
				_ = csg_clean_and_simplify_hulls(&ch.indestructible_hulls, alloc)
			}
			clear(&combined_hulls)
			append(&combined_hulls, ..ch.destructible_hulls[:])
			append(&combined_hulls, ..ch.indestructible_hulls[:])
			csg_triangulate_hulls(combined_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
		}
		ch.dirty_physics = true
		ch.dirty_gpu = true
		rebuilt_chunks += 1
	}

	csg_volume_repack_gpu_mesh(vol)
	vol.compiled = true
	return max(rebuilt_chunks, len(dirty_coords))
}

// Smart CSG Simplifier & Lazy Cleaner for an entire `CSGVolume`:
// Prunes degenerate/lingering sliver hulls, merges sibling split hulls, clips internal seam polygons,
// dissolves collinear vertices, and re-triangulates all chunks.
csg_volume_smart_clean_and_simplify :: proc(vol: ^CSGVolume) -> (cleaned_ops: int) {
	if vol == nil do return 0
	if !vol.compiled {
		csg_volume_rebuild(vol)
		return 1
	}
	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	light := _resolve_scene_shadow_light()
	sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
	combined_hulls := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)

	for _, ch in vol.chunks {
		if ch == nil do continue
		before_tris := len(ch.indices) / 3
		if ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
			csg_voxel_prune_floating_crumbs(ch.voxel_grid)
			csg_voxel_build_greedy_hulls(ch.voxel_grid, &ch.destructible_hulls, alloc)
			cleaned_ops += csg_clean_and_simplify_hulls(&ch.indestructible_hulls, alloc)
			csg_voxel_triangulate_chunk(ch.voxel_grid, ch.indestructible_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
		} else {
			cleaned_ops += csg_clean_and_simplify_hulls(&ch.destructible_hulls, alloc)
			cleaned_ops += csg_clean_and_simplify_hulls(&ch.indestructible_hulls, alloc)
			clear(&combined_hulls)
			append(&combined_hulls, ..ch.destructible_hulls[:])
			append(&combined_hulls, ..ch.indestructible_hulls[:])
			csg_triangulate_hulls(combined_hulls[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
		}
		after_tris := len(ch.indices) / 3
		if before_tris != after_tris {
			cleaned_ops += abs(before_tris - after_tris)
		}
		ch.dirty_gpu = true
		ch.dirty_physics = true
	}
	csg_volume_repack_gpu_mesh(vol)
	csg_volume_sync_colliders_only(vol)
	return cleaned_ops
}

// Bakes the compiled `CSGVolume` into a standalone static `MeshFilter + MeshRenderer` GameObject
// in the active scene, unifying hulls across all chunks first so inter-chunk seam faces are 100% culled,
// coplanar polygons are merged, and pointless collinear vertices are dissolved!
csg_volume_bake_to_static_mesh :: proc(vol: ^CSGVolume) -> engine.Transform_Handle {
	if vol == nil do return {}
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return {}
	if !vol.compiled {
		csg_volume_rebuild(vol)
	}

	// Gather all hulls across all chunks into one unified list and merge sibling chunk-split hulls
	// so baking `CSG -> Static Mesh` has ZERO internal seam polygons across chunk or boolean boundaries!
	unified_hulls := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)
	for _, ch in vol.chunks {
		if ch == nil do continue
		for h in ch.destructible_hulls {
			if len(h.planes) >= 4 {
				append(&unified_hulls, convex_clone(h, context.temp_allocator))
			}
		}
		for h in ch.indestructible_hulls {
			if len(h.planes) >= 4 {
				append(&unified_hulls, convex_clone(h, context.temp_allocator))
			}
		}
	}
	if len(unified_hulls) == 0 do return {}

	_ = csg_clean_and_simplify_hulls(&unified_hulls, context.temp_allocator)

	light := _resolve_scene_shadow_light()
	sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
	all_verts := make([dynamic]gfx.Vertex, 0, 128, context.temp_allocator)
	all_inds  := make([dynamic]u32, 0, 256, context.temp_allocator)
	all_subs  := make([dynamic]engine.Mesh_Submesh, 0, 2, context.temp_allocator)
	csg_triangulate_hulls(unified_hulls[:], &all_verts, &all_inds, &all_subs, sun_vec)
	if len(all_verts) < 3 || len(all_inds) < 3 do return {}

	tw := engine.transform_world(vol.owner)
	root_h := engine.Transform_Handle(scene.root.handle)
	new_h := engine.transform_new("Baked_CSG_Mesh", root_h)
	engine.transform_ensure_unique_name(new_h)
	if nt := engine.pool_get(&w.transforms, engine.Handle(new_h)); nt != nil {
		nt.position = tw.position
		nt.rotation = tw.rotation
		nt.scale    = tw.scale
	}

	_, mf_ptr := engine.transform_add_comp(new_h, .MeshFilter)
	mf := cast(^engine.MeshFilter)mf_ptr
	_, mr_ptr := engine.transform_add_comp(new_h, .MeshRenderer)
	mr := cast(^engine.MeshRenderer)mr_ptr
	if mr != nil do mr.cast_shadows = true

	m_guid := make_procedural_guid(new_h, 0x4241_4B45)
	engine.mesh_upsert_procedural(m_guid, all_verts[:], all_inds[:], nil, keep_cpu_buffers = true)
	if mf != nil {
		mf.mesh = engine.PPtr{guid = m_guid, local_id = 0}
	}
	scene.dirty = true
	return new_h
}

// ============================================================================
// JOLTC PHYSICS SYNC FOR STATIC CHUNKS & DYNAMIC DEBRIS
// ============================================================================

@(private = "file")
_sync_chunk_physics_body :: proc(vol: ^CSGVolume, ch: ^CSG_Chunk, pre_cooked_shape: ^jolt.Shape = nil) {
	if !physics3d._state.world_ready || physics3d._state.body_interface == nil do return
	bi := physics3d._state.body_interface
	tw := engine.transform_world(vol.owner)

	// Remove existing static body if chunk became empty
	if len(ch.indices) < 3 {
		if physics3d.is_body_valid(ch.static_body) {
			if jolt.BodyInterface_IsAdded(bi, ch.static_body) {
				jolt.BodyInterface_RemoveBody(bi, ch.static_body)
			}
			jolt.BodyInterface_DestroyBody(bi, ch.static_body)
			ch.static_body = 0
		}
		if ch.jolt_shape != nil {
			delete_key(&physics3d._state.shape_owner, uintptr(ch.jolt_shape))
			jolt.Shape_Destroy(ch.jolt_shape)
			ch.jolt_shape = nil
		}
		ch.dirty_physics = false
		return
	}

	new_shape := pre_cooked_shape
	if new_shape == nil {
		if vol.soft_deform_enabled && len(vol.soft_deform_stamps) > 0 && len(ch.verts) >= 3 && len(ch.indices) >= 3 {
			def_verts, _, _ := csg_build_deformed_vertex_buffer(vol, ch.verts[:], context.temp_allocator)
			new_shape = _cook_chunk_jolt_shape(
				nil,
				nil,
				def_verts,
				ch.indices[:],
				tw.scale,
			)
		}
		if new_shape == nil {
			use_exact_mesh := (ch.voxel_grid != nil && ch.voxel_grid.has_cuts)
			new_shape = _cook_chunk_jolt_shape(
				ch.destructible_hulls[:],
				ch.indestructible_hulls[:],
				ch.verts[:],
				ch.indices[:],
				tw.scale,
				use_exact_mesh,
			)
		}
	}
	if new_shape == nil {
		if physics3d.is_body_valid(ch.static_body) {
			if jolt.BodyInterface_IsAdded(bi, ch.static_body) {
				jolt.BodyInterface_RemoveBody(bi, ch.static_body)
			}
			jolt.BodyInterface_DestroyBody(bi, ch.static_body)
			ch.static_body = 0
		}
		if ch.jolt_shape != nil {
			delete_key(&physics3d._state.shape_owner, uintptr(ch.jolt_shape))
			jolt.Shape_Destroy(ch.jolt_shape)
			ch.jolt_shape = nil
		}
		ch.dirty_physics = false
		return
	}

	physics3d._state.shape_owner[uintptr(new_shape)] = vol.owner

	// Always remove and destroy the old static Jolt body before adding the updated shape
	// so Jolt's ContactManager purges 100% of cached sub-shape contact manifolds from the pre-blast geometry!
	if physics3d.is_body_valid(ch.static_body) {
		if jolt.BodyInterface_IsAdded(bi, ch.static_body) {
			jolt.BodyInterface_RemoveBody(bi, ch.static_body)
		}
		jolt.BodyInterface_DestroyBody(bi, ch.static_body)
		ch.static_body = 0
	}
	if ch.jolt_shape != nil && ch.jolt_shape != new_shape {
		delete_key(&physics3d._state.shape_owner, uintptr(ch.jolt_shape))
		jolt.Shape_Destroy(ch.jolt_shape)
	}
	ch.jolt_shape = new_shape

	pos := tw.position
	rot := transmute(jolt.Quat)tw.rotation
	bcs := jolt.BodyCreationSettings_Create3(
		ch.jolt_shape,
		&pos,
		&rot,
		.Static,
		physics3d.LAYER_NON_MOVING,
	)
	if bcs != nil {
		jolt.BodyCreationSettings_SetFriction(bcs, 0.75)
		jolt.BodyCreationSettings_SetRestitution(bcs, 0.10)
		jolt.BodyCreationSettings_SetUserData(bcs, transmute(u64)engine.Handle(vol.owner))
		ch.static_body = jolt.BodyInterface_CreateAndAddBody(bi, bcs, .DontActivate)
		jolt.BodyCreationSettings_Destroy(bcs)
	}
	ch.dirty_physics = false
}

// Synchronizes the entire `CSGVolume` as a single Dynamic JoltC Rigidbody when `vol.is_dynamic_rigidbody == true`.
@(private = "file")
_sync_volume_dynamic_body :: proc(vol: ^CSGVolume, force_rebuild_shape := false) {
	if !physics3d._state.world_ready || physics3d._state.body_interface == nil do return
	bi := physics3d._state.body_interface
	tw := engine.transform_world(vol.owner)

	// Remove any per-chunk static bodies if switching from Static to Dynamic, and check if any chunk needs physics sync
	any_chunk_dirty := false
	for _, ch in vol.chunks {
		if ch.dirty_physics do any_chunk_dirty = true
		if physics3d.is_body_valid(ch.static_body) {
			if jolt.BodyInterface_IsAdded(bi, ch.static_body) {
				jolt.BodyInterface_RemoveBody(bi, ch.static_body)
			}
			jolt.BodyInterface_DestroyBody(bi, ch.static_body)
			ch.static_body = 0
		}
		ch.dirty_physics = false
	}

	if !force_rebuild_shape && !any_chunk_dirty && physics3d.is_body_valid(vol.dynamic_body) && jolt.BodyInterface_IsAdded(bi, vol.dynamic_body) {
		return
	}

	// Collect up to 32 valid 3D convex hulls across all chunks (with O(1) BoxShape fast-path for greedy voxel boxes!)
	Dyn_Sub_Shape :: struct {
		shape: ^jolt.Shape,
		pos:   [3]f32,
	}
	sub_shapes := make([dynamic]Dyn_Sub_Shape, 0, 16, context.temp_allocator)
	pts := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	has_soft_deform := vol.soft_deform_enabled && len(vol.soft_deform_stamps) > 0

	outer_chunks: for _, ch in vol.chunks {
		if ch == nil do continue
		is_vox_chunk := (ch.voxel_grid != nil && ch.voxel_grid.has_cuts && !has_soft_deform)
		for pass in 0 ..< 2 {
			slice_h := ch.destructible_hulls[:] if pass == 0 else ch.indestructible_hulls[:]
			// If a voxel-blasted dynamic rubble piece has > 24 greedy boxes, step through them so Jolt compound cooking stays < 0.2 ms
			step := max(len(slice_h) / 24, 1) if (is_vox_chunk && pass == 0 && len(slice_h) > 24) else 1
			for hi := 0; hi < len(slice_h); hi += step {
				h := slice_h[hi]
				if is_vox_chunk && pass == 0 && len(h.planes) == 6 {
					half_ext := (h.aabb_max - h.aabb_min) * 0.5 * tw.scale
					if half_ext.x >= 0.015 && half_ext.y >= 0.015 && half_ext.z >= 0.015 {
						box_s := cast(^jolt.Shape)jolt.BoxShape_Create(&half_ext, min(min(half_ext.x, min(half_ext.y, half_ext.z)) * 0.2, 0.01))
						if box_s != nil {
							center_p := (h.aabb_min + h.aabb_max) * 0.5 * tw.scale
							append(&sub_shapes, Dyn_Sub_Shape{shape = box_s, pos = center_p})
							if len(sub_shapes) >= 32 do break outer_chunks
							continue
						}
					}
				}
				convex_extract_vertices(h, &pts)
				if has_soft_deform {
					for &p in pts {
						dp, _ := csg_eval_soft_deform_offset(vol.soft_deform_stamps[:], p)
						p = (p + dp) * tw.scale
					}
				} else {
					for &p in pts do p *= tw.scale
				}
				if !_points_form_3d_simplex(pts[:]) do continue
				cs := jolt.ConvexHullShapeSettings_Create(&pts[0], u32(len(pts)), 0.01)
				if cs != nil {
					sub_s := cast(^jolt.Shape)jolt.ConvexHullShapeSettings_CreateShape(cs)
					jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)cs)
					if sub_s != nil {
						append(&sub_shapes, Dyn_Sub_Shape{shape = sub_s, pos = {0, 0, 0}})
						if len(sub_shapes) >= 32 do break outer_chunks
					}
				}
			}
		}
	}

	if len(sub_shapes) == 0 {
		if physics3d.is_body_valid(vol.dynamic_body) {
			if jolt.BodyInterface_IsAdded(bi, vol.dynamic_body) {
				jolt.BodyInterface_RemoveBody(bi, vol.dynamic_body)
			}
			jolt.BodyInterface_DestroyBody(bi, vol.dynamic_body)
			vol.dynamic_body = 0
		}
		if vol.dynamic_shape != nil {
			delete_key(&physics3d._state.shape_owner, uintptr(vol.dynamic_shape))
			jolt.Shape_Destroy(vol.dynamic_shape)
			vol.dynamic_shape = nil
		}
		return
	}

	cooked: ^jolt.Shape = nil
	if len(sub_shapes) == 1 && linalg.length2(sub_shapes[0].pos) < 1e-6 {
		cooked = sub_shapes[0].shape
	} else {
		comp_settings := jolt.StaticCompoundShapeSettings_Create()
		if comp_settings != nil {
			defer jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)comp_settings)
			ident_r := transmute(jolt.Quat)[4]f32{0, 0, 0, 1}
			for &entry in sub_shapes {
				jolt.CompoundShapeSettings_AddShape2(
					cast(^jolt.CompoundShapeSettings)comp_settings,
					&entry.pos,
					&ident_r,
					entry.shape,
					0,
				)
			}
			cooked = cast(^jolt.Shape)jolt.StaticCompoundShape_Create(comp_settings)
		}
		if cooked == nil {
			for entry in sub_shapes do jolt.Shape_Destroy(entry.shape)
		}
	}
	if cooked == nil do return

	physics3d._state.shape_owner[uintptr(cooked)] = vol.owner

	// Preserve existing dynamic body velocity if recreating its Jolt body so old contact manifolds are 100% purged!
	had_vel := false
	prev_lin_vel, prev_ang_vel: [3]f32
	if physics3d.is_body_valid(vol.dynamic_body) {
		if jolt.BodyInterface_IsAdded(bi, vol.dynamic_body) {
			jolt.BodyInterface_GetLinearAndAngularVelocity(bi, vol.dynamic_body, &prev_lin_vel, &prev_ang_vel)
			had_vel = true
			jolt.BodyInterface_RemoveBody(bi, vol.dynamic_body)
		}
		jolt.BodyInterface_DestroyBody(bi, vol.dynamic_body)
		vol.dynamic_body = 0
	}
	if vol.dynamic_shape != nil && vol.dynamic_shape != cooked {
		delete_key(&physics3d._state.shape_owner, uintptr(vol.dynamic_shape))
		jolt.Shape_Destroy(vol.dynamic_shape)
	}
	vol.dynamic_shape = cooked

	pos := tw.position
	rot := transmute(jolt.Quat)tw.rotation
	bcs := jolt.BodyCreationSettings_Create3(
		vol.dynamic_shape,
		&pos,
		&rot,
		.Dynamic,
		physics3d.LAYER_MOVING,
	)
	if bcs != nil {
		jolt.BodyCreationSettings_SetFriction(bcs, 0.75)
		jolt.BodyCreationSettings_SetRestitution(bcs, 0.12)
		jolt.BodyCreationSettings_SetLinearDamping(bcs, 0.15)
		jolt.BodyCreationSettings_SetAngularDamping(bcs, 0.35)
		if had_vel {
			jolt.BodyCreationSettings_SetLinearVelocity(bcs, &prev_lin_vel)
			jolt.BodyCreationSettings_SetAngularVelocity(bcs, &prev_ang_vel)
		}
		jolt.BodyCreationSettings_SetUserData(bcs, transmute(u64)engine.Handle(vol.owner))
		vol.dynamic_body = jolt.BodyInterface_CreateAndAddBody(bi, bcs, .Activate)
		jolt.BodyCreationSettings_Destroy(bcs)
	}
}

// Creates a "Drunken Sphere" or 8-Vertex Convex Hull dynamic debris shard in JoltC + Scene!
@(private = "package")
_spawn_debris_shard :: proc(
	world_pos:    [3]f32,
	shard_size:   [3]f32,
	blast_center: [3]f32,
	impulse:      f32,
	mode:         Debris_Collider_Mode,
	seed:         u32,
	custom_hull:  Maybe(CSG_Convex) = nil,
) {
	// Geo-Mod rubble balls (`CSG_Debris_Rock`) are disabled so blasts carve clean craters without spawning rubble spheres.
	_ = world_pos
	_ = shard_size
	_ = blast_center
	_ = impulse
	_ = mode
	_ = seed
	_ = custom_hull
}

// Spawns a severed structural island (`island_hulls`) as a brand-new standalone `CSGVolume`
// GameObject (`CSG_Detached_Piece`) with `is_dynamic_rigidbody = true` and its own JoltC
// compound physics body so split/destroyed CSG pieces become independent physics objects!
@(private = "file")
_spawn_detached_csg_island_volume :: proc(
	parent_vol:   ^CSGVolume,
	island_hulls: []CSG_Convex,
	blast_center: [3]f32,
	impulse:      f32,
	seed:         u32,
) -> engine.Transform_Handle {
	if parent_vol == nil || len(island_hulls) == 0 do return {}
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil do return {}

	alloc := runtime.default_allocator()

	// Compute local AABB and centroid of the severed island
	isl_min := island_hulls[0].aabb_min
	isl_max := island_hulls[0].aabb_max
	for h in island_hulls[1:] {
		isl_min.x = min(isl_min.x, h.aabb_min.x)
		isl_min.y = min(isl_min.y, h.aabb_min.y)
		isl_min.z = min(isl_min.z, h.aabb_min.z)
		isl_max.x = max(isl_max.x, h.aabb_max.x)
		isl_max.y = max(isl_max.y, h.aabb_max.y)
		isl_max.z = max(isl_max.z, h.aabb_max.z)
	}
	local_center := (isl_min + isl_max) * 0.5

	// Cache `parent_vol` fields before `transform_add_comp` in case the `CSGVolume` pool reallocates!
	parent_owner       := parent_vol.owner
	parent_chunk_size  := parent_vol.chunk_size
	parent_ground_y    := parent_vol.ground_y
	parent_debris      := parent_vol.spawn_debris
	parent_debris_mode := parent_vol.debris_collider_mode
	parent_mat_preset  := parent_vol.material_preset
	parent_cust_mat    := parent_vol.custom_material_guid
	parent_is_faker    := parent_vol.is_faker_mesh && parent_vol.faker_split_on_slice
	parent_f_mesh      := parent_vol.faker_mesh_guid
	parent_f_mat       := parent_vol.faker_material_guid
	parent_f_cut_mat   := parent_vol.faker_cut_material_guid
	parent_f_scale     := parent_vol.faker_mesh_scale
	parent_f_offset    := parent_vol.faker_mesh_offset
	parent_f_hide      := parent_vol.faker_hide_outer_shell
	parent_f_cut_int   := parent_vol.faker_render_cut_interior
	parent_f_dents     := parent_vol.faker_transfer_dents
	parent_cut_pal     := make([dynamic]engine.Asset_GUID, len(parent_vol.cut_material_palette), context.temp_allocator)
	for pg, pi in parent_vol.cut_material_palette {
		parent_cut_pal[pi] = pg
	}

	tw := engine.transform_world(parent_owner)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	world_center := (model * [4]f32{local_center.x, local_center.y, local_center.z, 1.0}).xyz

	root_h := engine.Transform_Handle(scene.root.handle)
	piece_h := engine.transform_new("CSG_Detached_Piece", root_h)
	engine.transform_ensure_unique_name(piece_h)
	if pt := engine.pool_get(&w.transforms, engine.Handle(piece_h)); pt != nil {
		pt.position = world_center
		pt.rotation = tw.rotation
		pt.scale    = tw.scale
	}

	_, vol_ptr := engine.transform_add_comp(piece_h, .CSGVolume)
	new_vol := cast(^CSGVolume)vol_ptr
	if new_vol == nil do return {}
	reset_CSGVolume(new_vol)

	new_vol.chunk_size                  = parent_chunk_size
	new_vol.ground_y                    = parent_ground_y - world_center.y
	new_vol.material_preset             = parent_mat_preset
	new_vol.custom_material_guid        = parent_cust_mat
	new_vol.is_dynamic_rigidbody        = true
	new_vol.enable_structural_collapse  = true
	new_vol.spawn_debris                = parent_debris
	new_vol.preserve_craters_on_rebuild = false
	new_vol.cast_planar_shadows         = false
	new_vol.debris_collider_mode        = parent_debris_mode
	new_vol.is_faker_mesh               = parent_is_faker
	new_vol.faker_mesh_guid             = parent_f_mesh
	new_vol.faker_material_guid         = parent_f_mat
	new_vol.faker_cut_material_guid     = parent_f_cut_mat
	new_vol.faker_mesh_scale            = parent_f_scale
	new_vol.faker_mesh_offset           = parent_f_offset - local_center
	new_vol.faker_hide_outer_shell      = parent_f_hide
	new_vol.faker_render_cut_interior   = parent_f_cut_int
	new_vol.faker_transfer_dents        = parent_f_dents
	if len(parent_cut_pal) > 0 {
		new_vol.cut_material_palette = make([dynamic]engine.Asset_GUID, len(parent_cut_pal), alloc)
		for pg, pi in parent_cut_pal {
			new_vol.cut_material_palette[pi] = pg
		}
	}
	new_vol.runtime_hulls               = make([dynamic]CSG_Convex, 0, len(island_hulls), alloc)

	for h in island_hulls {
		cloned := convex_clone(h, alloc)
		cloned.anchored = false
		for &p in cloned.planes {
			p.dist -= linalg.dot(p.normal, local_center)
		}
		if convex_rebuild_bounds_and_prune(&cloned, false) {
			append(&new_vol.runtime_hulls, cloned)
		} else {
			convex_destroy(&cloned)
		}
	}

	if len(new_vol.runtime_hulls) == 0 {
		engine.transform_destroy(piece_h)
		return {}
	}

	csg_volume_rebuild(new_vol)

	// Immediately create and activate the Jolt dynamic body if Physics is running
	if physics3d._state.world_ready && physics3d._state.body_interface != nil {
		_sync_volume_dynamic_body(new_vol, true)
		bi := physics3d._state.body_interface
		if physics3d.is_body_valid(new_vol.dynamic_body) && jolt.BodyInterface_IsAdded(bi, new_vol.dynamic_body) {
			dir := linalg.normalize0((world_center - blast_center) + [3]f32{0, 0.35, 0})
			vel := dir * clamp(impulse, 1.0, 12.0)
			ang_vel := [3]f32{
				f32(int(seed % 7) - 3) * 0.85,
				f32(int((seed >> 3) % 7) - 3) * 0.85,
				f32(int((seed >> 6) % 7) - 3) * 0.85,
			}
			jolt.BodyInterface_SetLinearAndAngularVelocity(bi, new_vol.dynamic_body, &vel, &ang_vel)
		}
	}
	return piece_h
}

// Performs a volume-wide structural connectivity check across ALL `CSG_Chunk`s of `vol`.
// - For grounded/static volumes (`!vol.is_dynamic_rigidbody`): seeds BFS from hulls touching `vol.ground_y`
//   or touching any `indestructible_hull` (e.g. `Foundation_Floor`), and extracts any upper pillar/wall/bridge
//   hulls that are no longer connected to the foundation.
// - For dynamic/floating volumes (`vol.is_dynamic_rigidbody` or no ground seeds): partitions hulls into
//   connected components, keeps the largest connected component in `vol`, and extracts all split-off pieces!
@(private = "file")
_extract_volume_detached_islands :: proc(vol: ^CSGVolume, out_detached: ^[dynamic]CSG_Convex) {
	if vol == nil || len(vol.chunks) == 0 do return

	Hull_Ref :: struct {
		ch:   ^CSG_Chunk,
		idx:  int,
		hull: CSG_Convex,
	}
	refs := make([dynamic]Hull_Ref, 0, 64, context.temp_allocator)
	ind_hulls := make([dynamic]CSG_Convex, 0, 16, context.temp_allocator)

	for _, ch in vol.chunks {
		if ch == nil do continue
		// Voxel SDF chunks prune disconnected crumbs directly inside `csg_voxel_prune_floating_crumbs`;
		// never detach individual greedy collider boxes from a Voxel SDF chunk as square blocky islands!
		if ch.voxel_grid != nil && ch.voxel_grid.has_cuts do continue
		for h, idx in ch.destructible_hulls {
			append(&refs, Hull_Ref{ch = ch, idx = idx, hull = h})
		}
		for ih in ch.indestructible_hulls {
			append(&ind_hulls, ih)
		}
	}

	n := len(refs)
	if n == 0 do return

	keep := make([]bool, n, context.temp_allocator)
	queue := make([dynamic]int, 0, n, context.temp_allocator)

	if !vol.is_dynamic_rigidbody {
		for r, i in refs {
			grounded := r.hull.aabb_min.y <= vol.ground_y + 0.12 || (r.hull.anchored && r.hull.aabb_min.y <= vol.ground_y + 0.35)
			if !grounded {
				for ih in ind_hulls {
					if convex_touches(r.hull, ih) {
						grounded = true
						break
					}
				}
			}
			if grounded {
				keep[i] = true
				append(&queue, i)
			}
		}
	}

	if len(queue) > 0 {
		head := 0
		for head < len(queue) {
			curr := queue[head]
			head += 1
			for j in 0 ..< n {
				if keep[j] do continue
				if convex_touches(refs[curr].hull, refs[j].hull) {
					keep[j] = true
					append(&queue, j)
				}
			}
		}
	} else if vol.is_dynamic_rigidbody || len(ind_hulls) == 0 {
		if n <= 1 do return
		// Floating or dynamic CSGVolume: keep the largest connected component and detach any split-off pieces!
		comp_id := make([]int, n, context.temp_allocator)
		for i in 0 ..< n do comp_id[i] = -1
		best_comp := 0
		best_vol: f32 = -1.0
		num_comps := 0

		for start in 0 ..< n {
			if comp_id[start] >= 0 do continue
			cid := num_comps
			num_comps += 1
			clear(&queue)
			comp_id[start] = cid
			append(&queue, start)
			c_vol: f32 = 0.0
			head := 0
			for head < len(queue) {
				curr := queue[head]
				head += 1
				ext := refs[curr].hull.aabb_max - refs[curr].hull.aabb_min
				c_vol += max(ext.x, 0.05) * max(ext.y, 0.05) * max(ext.z, 0.05)
				for j in 0 ..< n {
					if comp_id[j] >= 0 do continue
					if convex_touches(refs[curr].hull, refs[j].hull) {
						comp_id[j] = cid
						append(&queue, j)
					}
				}
			}
			if c_vol > best_vol {
				best_vol = c_vol
				best_comp = cid
			}
		}

		if num_comps <= 1 do return
		for i in 0 ..< n {
			keep[i] = (comp_id[i] == best_comp)
		}
	}

	// Count how many hulls detached
	detached_count := 0
	for k in keep {
		if !k do detached_count += 1
	}
	if detached_count == 0 do return

	// Remove detached hulls from their chunks, re-triangulate affected chunks, and update their Jolt shapes
	affected_chunks := make(map[^CSG_Chunk]bool, context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		if keep[i] do continue
		r := refs[i]
		det_h := r.ch.destructible_hulls[r.idx]
		if r.ch.voxel_grid != nil && r.ch.voxel_grid.has_cuts {
			// Clear the detached island's box region from the chunk's Voxel SDF grid so it isn't drawn twice!
			g := r.ch.voxel_grid
			if g.voxel_size > 1e-5 {
				rmin := (det_h.aabb_min - g.origin) / g.voxel_size
				rmax := (det_h.aabb_max - g.origin) / g.voxel_size
				ix0 := clamp(int(math.floor(rmin.x)), 1, CSG_VOXEL_RES - 1)
				iy0 := clamp(int(math.floor(rmin.y)), 1, CSG_VOXEL_RES - 1)
				iz0 := clamp(int(math.floor(rmin.z)), 1, CSG_VOXEL_RES - 1)
				ix1 := clamp(int(math.ceil(rmax.x)),  1, CSG_VOXEL_RES - 1)
				iy1 := clamp(int(math.ceil(rmax.y)),  1, CSG_VOXEL_RES - 1)
				iz1 := clamp(int(math.ceil(rmax.z)),  1, CSG_VOXEL_RES - 1)
				for z in iz0 ..= iz1 {
					for y in iy0 ..= iy1 {
						for x in ix0 ..= ix1 {
							g.sdf[z * CSG_VOXEL_PTS * CSG_VOXEL_PTS + y * CSG_VOXEL_PTS + x] = 127
						}
					}
				}
			}
		}
		append(out_detached, det_h)
		ordered_remove(&r.ch.destructible_hulls, r.idx)
		affected_chunks[r.ch] = true
	}

	light := _resolve_scene_shadow_light()
	sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
	combined := make([dynamic]CSG_Convex, 0, 32, context.temp_allocator)

	for ch, _ in affected_chunks {
		if ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
			csg_voxel_triangulate_chunk(
				ch.voxel_grid,
				ch.indestructible_hulls[:],
				&ch.verts,
				&ch.indices,
				&ch.submeshes,
				sun_vec,
			)
		} else {
			clear(&combined)
			append(&combined, ..ch.destructible_hulls[:])
			append(&combined, ..ch.indestructible_hulls[:])
			csg_triangulate_hulls(combined[:], &ch.verts, &ch.indices, &ch.submeshes, sun_vec)
		}
		if len(ch.verts) > 0 {
			lo := ch.verts[0].position
			hi := ch.verts[0].position
			for v in ch.verts[1:] {
				lo.x = min(lo.x, v.position.x); lo.y = min(lo.y, v.position.y); lo.z = min(lo.z, v.position.z)
				hi.x = max(hi.x, v.position.x); hi.y = max(hi.y, v.position.y); hi.z = max(hi.z, v.position.z)
			}
			ch.aabb_min = lo
			ch.aabb_max = hi
		}
		ch.dirty_gpu = true
		ch.dirty_physics = true
		if physics3d._state.world_ready && !vol.is_dynamic_rigidbody {
			_sync_chunk_physics_body(vol, ch, nil)
		}
	}
}

// ============================================================================
// BACKGROUND WORKER THREAD & ASYNC BLAST PIPELINE
// ============================================================================

@(private = "file")
_execute_blast_job :: proc(job: ^CSG_Async_Blast_Job) -> CSG_Async_Blast_Result {
	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	res := CSG_Async_Blast_Result{
		volume_owner    = job.volume_owner,
		world_id        = job.world_id,
		world_blast_pos = job.world_blast_pos,
		blast_radius    = job.blast_radius,
		blast_impulse   = job.blast_impulse,
		spawn_debris    = job.spawn_debris,
		debris_mode     = job.debris_mode,
		seed            = job.seed,
		chunk_outputs   = make([dynamic]CSG_Async_Chunk_Output, 0, len(job.touched_chunks), alloc),
	}

	jaggedness := job.blast_jaggedness if job.blast_jaggedness > 0.001 else csg_settings.blast_jaggedness
	scorch_col := job.scorch_color if job.scorch_color[3] > 0 else [4]u8{88, 80, 74, 255}
	b_slot     := job.blast_mat_slot if job.blast_mat_slot > 0 else 1
	cutter: CSG_Convex
	ok := false
	if !job.use_voxel_sdf {
		cutter, ok = csg_make_blast_convex(
			job.local_blast_pos,
			job.blast_radius,
			job.seed,
			jaggedness,
			scorch_col,
			alloc,
			b_slot,
		)
	}
	defer if ok do convex_destroy(&cutter)

	for &in_ch in job.touched_chunks {
		out_ch := CSG_Async_Chunk_Output{
			coord                = in_ch.coord,
			destructible_hulls   = in_ch.destructible_hulls,
			indestructible_hulls = in_ch.indestructible_hulls,
			voxel_grid           = in_ch.voxel_grid,
			detached_islands     = make([dynamic]CSG_Convex, 0, 4, alloc),
			verts                = make([dynamic]gfx.Vertex, 0, 128, alloc),
			indices              = make([dynamic]u32, 0, 256, alloc),
			submeshes            = make([dynamic]engine.Mesh_Submesh, 0, 2, alloc),
		}

		if job.use_voxel_sdf {
			// SEVERED STEEL O(1) VOXEL SDF DESTRUCTION PATH:
			if out_ch.voxel_grid == nil {
				out_ch.voxel_grid = csg_voxel_grid_init_from_hulls(
					out_ch.destructible_hulls[:],
					in_ch.aabb_min,
					in_ch.aabb_max,
					alloc,
				)
			}
			if out_ch.voxel_grid != nil {
				csg_voxel_carve_blast(
					out_ch.voxel_grid,
					job.local_blast_pos,
					job.blast_radius,
					job.seed,
					jaggedness,
					scorch_col,
					b_slot,
				)
				csg_voxel_build_greedy_hulls(out_ch.voxel_grid, &out_ch.destructible_hulls, alloc)
				csg_voxel_triangulate_chunk(
					out_ch.voxel_grid,
					out_ch.indestructible_hulls[:],
					&out_ch.verts,
					&out_ch.indices,
					&out_ch.submeshes,
				)
			}
		} else {
			if ok {
				convex_list_subtract(&out_ch.destructible_hulls, cutter, alloc)
				if len(out_ch.destructible_hulls) <= 36 {
					_ = csg_clean_and_simplify_hulls(&out_ch.destructible_hulls, alloc)
				} else {
					for hi := len(out_ch.destructible_hulls) - 1; hi >= 0; hi -= 1 {
						if !convex_rebuild_bounds_and_prune(&out_ch.destructible_hulls[hi], prune_redundant = false, min_extent = 0.006) {
							convex_destroy(&out_ch.destructible_hulls[hi])
							ordered_remove(&out_ch.destructible_hulls, hi)
						}
					}
				}
			}

			combined := make([dynamic]CSG_Convex, 0, len(out_ch.destructible_hulls) + len(out_ch.indestructible_hulls), context.temp_allocator)
			append(&combined, ..out_ch.destructible_hulls[:])
			append(&combined, ..out_ch.indestructible_hulls[:])
			csg_triangulate_hulls(combined[:], &out_ch.verts, &out_ch.indices, &out_ch.submeshes)
		}

		if job.cook_jolt_shapes && len(out_ch.indices) >= 3 {
			use_exact_mesh := (out_ch.voxel_grid != nil && out_ch.voxel_grid.has_cuts)
			out_ch.cooked_shape = _cook_chunk_jolt_shape(
				out_ch.destructible_hulls[:],
				out_ch.indestructible_hulls[:],
				out_ch.verts[:],
				out_ch.indices[:],
				{1, 1, 1},
				use_exact_mesh,
			)
		}

		append(&res.chunk_outputs, out_ch)
		in_ch.destructible_hulls = nil
		in_ch.indestructible_hulls = nil
		in_ch.voxel_grid = nil
	}
	delete(job.touched_chunks)
	return res
}

@(private = "file")
_csg_worker_proc :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	for {
		has_job := false
		job: CSG_Async_Blast_Job

		sync.lock(&_worker_state.mutex)
		if _worker_state.stop_flag {
			sync.unlock(&_worker_state.mutex)
			break
		}
		if len(_worker_state.pending_jobs) > 0 {
			job = _worker_state.pending_jobs[0]
			ordered_remove(&_worker_state.pending_jobs, 0)
			_worker_state.busy = true
			has_job = true
		}
		sync.unlock(&_worker_state.mutex)

		if has_job {
			res := _execute_blast_job(&job)
			free_all(context.temp_allocator)
			sync.lock(&_worker_state.mutex)
			append(&_worker_state.results, res)
			_worker_state.busy = false
			sync.unlock(&_worker_state.mutex)
		} else {
			time.sleep(2 * time.Millisecond)
		}
	}
}

@(private = "file")
_ensure_worker_started :: proc() {
	sync.lock(&_worker_state.mutex)
	defer sync.unlock(&_worker_state.mutex)
	if _worker_state.running do return
	alloc := runtime.default_allocator()
	context.allocator = alloc
	_worker_state.pending_jobs = make([dynamic]CSG_Async_Blast_Job, alloc)
	_worker_state.results = make([dynamic]CSG_Async_Blast_Result, alloc)
	_worker_state.blast_fx = make([dynamic]CSG_Blast_FX, alloc)
	_worker_state.debris_list = make([dynamic]CSG_Active_Debris, alloc)
	_worker_state.stop_flag = false
	_worker_state.worker = thread.create(_csg_worker_proc)
	if _worker_state.worker != nil {
		thread.start(_worker_state.worker)
		_worker_state.running = true
	}
}

// Ensures any queued or in-flight async blast jobs finish and commit to `vol.chunks`
// before a new blast snapshots `ch.destructible_hulls`, so rapid-fire blast spam never drops a crater
// or overwrites newer craters with an older in-flight snapshot ("turning back time")!
@(private = "file")
_flush_in_flight_worker_blasts :: proc() {
	if !_worker_state.running do return
	for guard := 0; guard < 500; guard += 1 {
		sync.lock(&_worker_state.mutex)
		pending   := len(_worker_state.pending_jobs)
		busy      := _worker_state.busy
		results_n := len(_worker_state.results)
		sync.unlock(&_worker_state.mutex)
		if results_n > 0 {
			csg_drain_completed_results()
		}
		if pending == 0 && !busy && results_n == 0 do break
		time.sleep(1 * time.Millisecond)
	}
	csg_drain_completed_results()
}

// Enqueues a Red Faction style runtime boolean blast at `world_pos` with `radius`.
// - Spawns immediate visual shockwave/dust particles on frame T0 to hide the 1-frame async latency.
// - Dispatches the touched 8m^3 chunks to the background worker thread (or executes immediately if worker unavailable).
csg_trigger_blast :: proc(
	world_pos:             [3]f32,
	radius:                f32 = 1.6,
	impulse:               f32 = 12.0,
	cut_material_override: engine.Asset_GUID = {},
	cut_albedo_override:   [4]u8 = {0, 0, 0, 0},
) -> int {
	w := engine.ctx_world()
	if w == nil do return 0
	_ensure_worker_started()

	// Drain any completed or in-flight async blasts before snapshotting chunk hulls so rapid-fire blast spam
	// always carves cumulatively into the latest geometry!
	_flush_in_flight_worker_blasts()

	prev_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_alloc

	_worker_state.blast_Links += 1
	seed := _worker_state.blast_Links * 2654435761 + u32(transmute(u32)world_pos.x)

	// 1. Immediate Frame T0 Visual Latency Masking (Shockwave + Dust Cloud + Sparks)
	append(&_worker_state.blast_fx, CSG_Blast_FX{
		world_pos = world_pos,
		radius    = radius,
		age       = 0.0,
		duration  = max(csg_settings.blast_fx_duration_sec, 0.25),
		seed      = seed,
	})

	// 2. Find all CSGVolumes and their 8m^3 spatial chunks overlapping the blast AABB
	touched_count := 0
	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || !engine.transform_active_in_hierarchy(vol.owner) do continue
		if !vol.compiled {
			csg_volume_rebuild(vol)
		}

		tw := engine.transform_world(vol.owner)
		inv_m := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		lp4 := inv_m * [4]f32{world_pos.x, world_pos.y, world_pos.z, 1.0}
		local_pos := lp4.xyz

		// Evaluate Material Properties DataTable (`vol.material_preset`) & `vol.blast_resistance` against `impulse` & `radius`:
		res_mult := vol.blast_resistance if vol.blast_resistance > 0.05 else 1.0
		adj_impulse := impulse / res_mult
		adj_radius  := radius / math.sqrt(res_mult)
		should_fracture, eff_radius, jaggedness, scorch_col, _ := csg_eval_blast_against_material(vol.material_preset, adj_radius, adj_impulse)
		if !engine.asset_guid_is_empty(cut_material_override) && engine.asset_guid_is_empty(vol.faker_cut_material_guid) {
			vol.faker_cut_material_guid = cut_material_override
		}
		blast_slot := csg_volume_register_cut_material(vol, cut_material_override)
		if cut_albedo_override.a > 0 {
			scorch_col = cut_albedo_override
		} else if !engine.asset_guid_is_empty(cut_material_override) {
			scorch_col = {255, 255, 255, 255}
		}

		// Even if the main structural volume doesn't fracture (e.g. Steel_Plate / Soft_Metal_Panel / Reinforced_Concrete),
		// still test attached detail instances and fragile glass panes against the blast!
		if !should_fracture {
			_csg_apply_blast_to_instances_and_glass(vol, local_pos, world_pos, radius, impulse, seed)
			continue
		}

		b_min := local_pos - [3]f32{eff_radius, eff_radius, eff_radius}
		b_max := local_pos + [3]f32{eff_radius, eff_radius, eff_radius}

		use_vox_sdf := (vol.destruction_backend == .Lazy_Voxel_SDF && !vol.is_ghoul_bone_csg)

		// =========================================================================
		// FAST IN-PLACE VOXEL SDF BLAST PATH (< 0.15 ms, ZERO 300KB DEEP CLONES,
		// ZERO 15.6ms WINDOWS THREAD SLEEP STALLS ON RAPID CLICK SPAM!):
		// =========================================================================
		if use_vox_sdf {
			light := _resolve_scene_shadow_light()
			sun_vec := light.to_light if (light.valid && light.kind == .Directional) else [3]f32{0, 0, 0}
			vol_touched := 0

			for _, ch in vol.chunks {
				if len(ch.destructible_hulls) == 0 && ch.voxel_grid == nil do continue
				if !aabb_overlaps(ch.aabb_min, ch.aabb_max, b_min, b_max, 0.25) do continue

				if ch.voxel_grid == nil {
					ch.voxel_grid = csg_voxel_grid_init_from_hulls(
						ch.destructible_hulls[:],
						ch.aabb_min,
						ch.aabb_max,
						alloc,
					)
				}
				if ch.voxel_grid == nil do continue

				csg_voxel_carve_blast(
					ch.voxel_grid,
					local_pos,
					eff_radius,
					seed,
					jaggedness,
					scorch_col,
					blast_slot,
				)
				if vol.is_dynamic_rigidbody {
					csg_voxel_build_greedy_hulls(ch.voxel_grid, &ch.destructible_hulls, alloc)
				}
				csg_voxel_triangulate_chunk(
					ch.voxel_grid,
					ch.indestructible_hulls[:],
					&ch.verts,
					&ch.indices,
					&ch.submeshes,
					sun_vec,
				)
				if len(ch.verts) > 0 {
					lo := ch.verts[0].position
					hi := ch.verts[0].position
					for v in ch.verts[1:] {
						lo = linalg.min(lo, v.position)
						hi = linalg.max(hi, v.position)
					}
					ch.aabb_min = lo
					ch.aabb_max = hi
				}
				ch.dirty_gpu     = true
				ch.dirty_physics = true
				if physics3d._state.world_ready && !vol.is_dynamic_rigidbody {
					_sync_chunk_physics_body(vol, ch)
				}
				vol_touched   += 1
				touched_count += 1
			}

			if vol_touched == 0 {
				_csg_apply_blast_to_instances_and_glass(vol, local_pos, world_pos, radius, impulse, seed)
				continue
			}

			if !engine.asset_guid_is_empty(cut_material_override) && engine.asset_guid_is_empty(vol.faker_cut_material_guid) {
				vol.faker_cut_material_guid = cut_material_override
			}
			if vol.recorded_blasts == nil {
				vol.recorded_blasts = make([dynamic]CSG_Recorded_Blast, 0, 16, alloc)
			}
			append(&vol.recorded_blasts, CSG_Recorded_Blast{
				local_pos = local_pos,
				radius    = eff_radius,
				seed      = seed,
				mat_slot  = blast_slot,
				color     = scorch_col,
			})

			if len(vol.detail_instances) > 0 || len(vol.glass_panes) > 0 {
				context.allocator = prev_alloc
				_csg_apply_blast_to_instances_and_glass(vol, local_pos, world_pos, eff_radius, impulse, seed, true)
				context.allocator = alloc
			}
			if physics3d._state.world_ready && vol.is_dynamic_rigidbody {
				_sync_volume_dynamic_body(vol, true)
			}
			if vol.spawn_debris {
				shard_count := clamp(int(eff_radius * 2.5), 1, 4)
				context.allocator = prev_alloc
				for s_i in 0 ..< shard_count {
					s_seed := seed + u32(s_i + 1) * 193
					ang    := f32(s_seed & 0xFF) * (2.0 * math.PI / 255.0)
					r_off  := eff_radius * 0.35
					sp_pos := world_pos + [3]f32{math.cos(ang) * r_off, 0.15, math.sin(ang) * r_off}
					sz     := clamp(eff_radius * 0.24, 0.10, 0.35)
					_spawn_debris_shard(sp_pos, {sz, sz * 0.8, sz * 0.9}, world_pos, impulse, vol.debris_collider_mode, s_seed)
				}
				context.allocator = alloc
			}
			if physics3d._state.world_ready && physics3d._state.system != nil {
				pad := eff_radius * 1.75
				blast_box := jolt.AABox{
					min = world_pos - [3]f32{pad, pad, pad},
					max = world_pos + [3]f32{pad, pad, pad},
				}
				jolt.PhysicsSystem_ActivateBodiesInAABox(
					physics3d._state.system,
					&blast_box,
					physics3d.LAYER_MOVING,
				)
			}
			csg_volume_repack_gpu_mesh(vol)
			continue
		}

		touched := make([dynamic]CSG_Async_Chunk_Input, 0, 8, alloc)
		for coord, ch in vol.chunks {
			if len(ch.destructible_hulls) == 0 && ch.voxel_grid == nil do continue
			// Check if chunk AABB overlaps blast AABB
			if !aabb_overlaps(ch.aabb_min, ch.aabb_max, b_min, b_max, 0.25) do continue

			// Deep-clone only the touched chunk's hulls & voxel_grid for the background worker
			d_clone := make([dynamic]CSG_Convex, len(ch.destructible_hulls), alloc)
			for h, i in ch.destructible_hulls {
				d_clone[i] = convex_clone(h, alloc)
			}
			i_clone := make([dynamic]CSG_Convex, len(ch.indestructible_hulls), alloc)
			for h, i in ch.indestructible_hulls {
				i_clone[i] = convex_clone(h, alloc)
			}
			v_clone := csg_voxel_grid_clone(ch.voxel_grid, alloc) if use_vox_sdf else nil
			append(&touched, CSG_Async_Chunk_Input{
				coord                = coord,
				aabb_min             = ch.aabb_min,
				aabb_max             = ch.aabb_max,
				destructible_hulls   = d_clone,
				indestructible_hulls = i_clone,
				voxel_grid           = v_clone,
			})
			touched_count += 1
		}

		if len(touched) == 0 {
			delete(touched)
			_csg_apply_blast_to_instances_and_glass(vol, local_pos, world_pos, radius, impulse, seed)
			continue
		}

		if !engine.asset_guid_is_empty(cut_material_override) && engine.asset_guid_is_empty(vol.faker_cut_material_guid) {
			vol.faker_cut_material_guid = cut_material_override
		}

		// Record blast on the volume so individual craters can be inspected/reset, or re-applied on rebuild
		// when `preserve_craters_on_rebuild` is enabled.
		if vol.recorded_blasts == nil {
			vol.recorded_blasts = make([dynamic]CSG_Recorded_Blast, 0, 16, alloc)
		}
		append(&vol.recorded_blasts, CSG_Recorded_Blast{
			local_pos = local_pos,
			radius    = eff_radius,
			seed      = seed,
			mat_slot  = blast_slot,
			color     = scorch_col,
		})

		job := CSG_Async_Blast_Job{
			volume_owner     = vol.owner,
			world_id         = w.id,
			local_blast_pos  = local_pos,
			world_blast_pos  = world_pos,
			blast_radius     = eff_radius,
			blast_impulse    = impulse,
			blast_jaggedness = jaggedness,
			scorch_color     = scorch_col,
			blast_mat_slot   = blast_slot,
			ground_y         = vol.ground_y,
			collapse_islands = vol.enable_structural_collapse,
			spawn_debris     = vol.spawn_debris,
			debris_mode      = vol.debris_collider_mode,
			cook_jolt_shapes = physics3d._state.world_ready && !vol.is_dynamic_rigidbody,
			use_voxel_sdf    = use_vox_sdf,
			seed             = seed,
			touched_chunks   = touched,
		}

		if csg_settings.async_destruction_worker {
			sync.lock(&_worker_state.mutex)
			append(&_worker_state.pending_jobs, job)
			sync.unlock(&_worker_state.mutex)
		} else {
			res := _execute_blast_job(&job)
			sync.lock(&_worker_state.mutex)
			append(&_worker_state.results, res)
			sync.unlock(&_worker_state.mutex)
			context.allocator = prev_alloc
			csg_drain_completed_results()
			context.allocator = alloc
		}
	}

	return touched_count
}

// ============================================================================
// PRE-PHYSICS BATCH COMMIT & VISUAL LATENCY MASKING
// ============================================================================

// Drains completed async CSG results, swaps GPU meshes, performs batched JoltC
// collider shape updates, wakes sleeping bodies in the blast AABB, and spawns debris.
csg_drain_completed_results :: proc() {
	if !_worker_state.running do return
	w := engine.ctx_world()
	if w == nil do return

	world_alloc := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = world_alloc

	max_swaps := int(max(csg_settings.max_chunk_swaps_per_tick, 1))
	swaps_done := 0

	for swaps_done < max_swaps {
		has_res := false
		res: CSG_Async_Blast_Result

		sync.lock(&_worker_state.mutex)
		if len(_worker_state.results) > 0 {
			res = _worker_state.results[0]
			ordered_remove(&_worker_state.results, 0)
			has_res = true
		}
		sync.unlock(&_worker_state.mutex)

		if !has_res do break
		swaps_done += 1

		// Validate target volume still exists in active world
		vol: ^CSGVolume = nil
		if res.world_id == w.id && res.volume_owner != {} && engine.pool_valid(&w.transforms, engine.Handle(res.volume_owner)) {
			_, vol = engine.transform_get_comp(res.volume_owner, CSGVolume)
		}

		if vol == nil || !vol.compiled {
			// Clean up discarded result
			for &co in res.chunk_outputs {
				for &h in co.destructible_hulls do convex_destroy(&h)
				delete(co.destructible_hulls)
				for &h in co.indestructible_hulls do convex_destroy(&h)
				delete(co.indestructible_hulls)
				if co.voxel_grid != nil do csg_voxel_grid_free(co.voxel_grid, alloc)
				for &h in co.detached_islands do convex_destroy(&h)
				delete(co.detached_islands)
				delete(co.verts)
				delete(co.indices)
				delete(co.submeshes)
				if co.cooked_shape != nil do jolt.Shape_Destroy(co.cooked_shape)
			}
			delete(res.chunk_outputs)
			continue
		}

		// Apply each modified chunk in a single batch
		for &co in res.chunk_outputs {
			ch, exists := vol.chunks[co.coord]
			if exists && ch != nil {
				for &h in ch.destructible_hulls do convex_destroy(&h)
				delete(ch.destructible_hulls)
				for &h in ch.indestructible_hulls do convex_destroy(&h)
				delete(ch.indestructible_hulls)
				if ch.voxel_grid != nil do csg_voxel_grid_free(ch.voxel_grid, alloc)
				delete(ch.verts)
				delete(ch.indices)
				delete(ch.submeshes)

				ch.destructible_hulls = co.destructible_hulls
				ch.indestructible_hulls = co.indestructible_hulls
				ch.voxel_grid = co.voxel_grid
				ch.verts = co.verts
				ch.indices = co.indices
				ch.submeshes = co.submeshes
				ch.dirty_gpu = true
				ch.dirty_physics = true

				// Recompute chunk AABB
				if len(ch.verts) > 0 {
					lo := ch.verts[0].position
					hi := ch.verts[0].position
					for v in ch.verts[1:] {
						lo.x = min(lo.x, v.position.x)
						lo.y = min(lo.y, v.position.y)
						lo.z = min(lo.z, v.position.z)
						hi.x = max(hi.x, v.position.x)
						hi.y = max(hi.y, v.position.y)
						hi.z = max(hi.z, v.position.z)
					}
					ch.aabb_min = lo
					ch.aabb_max = hi
				}

				if physics3d._state.world_ready && !vol.is_dynamic_rigidbody {
					_sync_chunk_physics_body(vol, ch, co.cooked_shape)
					co.cooked_shape = nil
				} else if co.cooked_shape != nil {
					jolt.Shape_Destroy(co.cooked_shape)
					co.cooked_shape = nil
				}
			} else {
				for &h in co.destructible_hulls do convex_destroy(&h)
				delete(co.destructible_hulls)
				for &h in co.indestructible_hulls do convex_destroy(&h)
				delete(co.indestructible_hulls)
				if co.voxel_grid != nil do csg_voxel_grid_free(co.voxel_grid, alloc)
				delete(co.verts)
				delete(co.indices)
				delete(co.submeshes)
				if co.cooked_shape != nil do jolt.Shape_Destroy(co.cooked_shape)
			}

			for &island in co.detached_islands do convex_destroy(&island)
			delete(co.detached_islands)
		}
		delete(res.chunk_outputs)

		// Perform volume-wide structural island extraction and spawn severed islands as
		// standalone Dynamic `CSGVolume` physics objects (`CSG_Detached_Piece`) when Physics is active!
		if vol.enable_structural_collapse && physics3d._state.world_ready {
			detached_hulls := make([dynamic]CSG_Convex, 0, 8, alloc)
			_extract_volume_detached_islands(vol, &detached_hulls)
			if len(detached_hulls) > 0 {
				islands := csg_group_hulls_into_islands(&detached_hulls, alloc)
				for &isl, isl_idx in islands {
					if len(isl) > 0 {
						lo := isl[0].aabb_min
						hi := isl[0].aabb_max
						for h in isl[1:] {
							lo.x = min(lo.x, h.aabb_min.x); lo.y = min(lo.y, h.aabb_min.y); lo.z = min(lo.z, h.aabb_min.z)
							hi.x = max(hi.x, h.aabb_max.x); hi.y = max(hi.y, h.aabb_max.y); hi.z = max(hi.z, h.aabb_max.z)
						}
						ext := hi - lo
						max_ext := max(ext.x, max(ext.y, ext.z))
						context.allocator = world_alloc
						if max_ext >= 0.25 {
							_ = _spawn_detached_csg_island_volume(
								vol,
								isl[:],
								res.world_blast_pos,
								res.blast_impulse * 0.40,
								res.seed + u32(isl_idx + 1) * 97,
							)
							_, vol = engine.transform_get_comp(res.volume_owner, CSGVolume)
						}
						context.allocator = alloc
					}
					for &h in isl do convex_destroy(&h)
					delete(isl)
				}
				delete(islands)
			}
			delete(detached_hulls)
		}

		if vol != nil {
			// Pop/hide any CSG-bound detail instances whose backing CSG hull was blasted away,
			// and shatter any 2D glass panes overlapped by the blast in RAM!
			if len(vol.detail_instances) > 0 || len(vol.glass_panes) > 0 {
				tw_v := engine.transform_world(vol.owner)
				model_v := engine.trs_matrix(tw_v.position, tw_v.rotation, tw_v.scale)
				inv_m := linalg.inverse(model_v)
				local_b := (inv_m * [4]f32{res.world_blast_pos.x, res.world_blast_pos.y, res.world_blast_pos.z, 1.0}).xyz
				context.allocator = world_alloc
				_csg_apply_blast_to_instances_and_glass(
					vol,
					local_b,
					res.world_blast_pos,
					res.blast_radius,
					res.blast_impulse,
					res.seed,
					true,
				)
				context.allocator = alloc
			}

			if physics3d._state.world_ready && vol.is_dynamic_rigidbody {
				_sync_volume_dynamic_body(vol, true)
			}

			// Repack combined GPU mesh for the volume
			csg_volume_repack_gpu_mesh(vol)
		}

		// Wake up any sleeping Jolt rigidbodies inside the blast AABB so crates/ragdolls fall into the new crater!
		if physics3d._state.world_ready && physics3d._state.system != nil {
			pad := res.blast_radius * 1.75
			blast_box := jolt.AABox{
				min = res.world_blast_pos - [3]f32{pad, pad, pad},
				max = res.world_blast_pos + [3]f32{pad, pad, pad},
			}
			jolt.PhysicsSystem_ActivateBodiesInAABox(
				physics3d._state.system,
				&blast_box,
				physics3d.LAYER_MOVING,
			)
		}
	}
}

BROAD_LAYER_MOVING_JOLT :: jolt.BroadPhaseLayer(1)

// Pre-Physics Fixed Step (`order=950`, right before `physics3d`'s `order=1000` step!)
// Ensures all compiled CSG chunks have static Jolt bodies and commits batched async swaps.
@(fixed_update={order=950})
csg_fixed_step :: proc(fixed_dt: f32) {
	w := engine.ctx_world()
	if w == nil do return

	// Ensure Jolt world is initialized
	_ = physics3d.physics_system()
	if !physics3d._state.world_ready do return
	bi := physics3d._state.body_interface

	// 1. Sync any newly compiled or dirty CSGVolume chunks to Jolt
	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || !engine.transform_active_in_hierarchy(vol.owner) do continue
		if !vol.compiled {
			csg_volume_rebuild(vol)
		}
		if vol.physics_world_id != w.id {
			// Only zero BodyIDs if switching between TWO DIFFERENT worlds (e.g. Editor <-> Play Mode).
			// If `vol.physics_world_id == 0`, any valid bodies already created on `vol` belong to `w` —
			// never zero them out without destroying them or they become permanent mid-air ghost colliders!
			if vol.physics_world_id != 0 {
				for _, ch in vol.chunks {
					ch.static_body = 0
					ch.dirty_physics = true
				}
				for &gp in vol.glass_panes {
					gp.glass_body = 0
					gp.glass_shape = nil
					gp.dirty_physics = true
				}
				vol.dynamic_body = 0
				vol.has_physics_sync = false
			}
			vol.physics_world_id = w.id
		}
		for &gp in vol.glass_panes {
			if gp.dirty_physics || (!physics3d.is_body_valid(gp.glass_body) && !gp.completely_shattered) {
				csg_sync_glass_pane_physics(vol, &gp)
			}
		}
		tw_cur := engine.transform_world(vol.owner)
		if vol.is_dynamic_rigidbody {
			_sync_volume_dynamic_body(vol, false)
			// Sync Jolt dynamic body <-> CSGVolume owner (supports runtime Scene Gizmo dragging & teleport!)
			if physics3d.is_body_valid(vol.dynamic_body) && bi != nil && jolt.BodyInterface_IsAdded(bi, vol.dynamic_body) {
				if vol.has_physics_sync &&
				   (linalg.length2(tw_cur.position - vol.last_physics_pos) > 1e-6 ||
				    linalg.length2(tw_cur.rotation - vol.last_physics_rot) > 1e-5) {
					// User dragged the object with the Transform Gizmo or gameplay code teleported it:
					// Teleport the Jolt dynamic body to the new transform instead of snapping it back!
					t_pos := tw_cur.position
					t_rot := engine.quat_to_native(tw_cur.rotation)
					jolt.BodyInterface_SetPositionAndRotation(bi, vol.dynamic_body, &t_pos, &t_rot, .Activate)
					zero_v := [3]f32{0, 0, 0}
					jolt.BodyInterface_SetLinearAndAngularVelocity(bi, vol.dynamic_body, &zero_v, &zero_v)
					vol.last_physics_pos = tw_cur.position
					vol.last_physics_rot = tw_cur.rotation
				} else {
					pos: [3]f32
					rot: jolt.Quat
					jolt.BodyInterface_GetPositionAndRotation(bi, vol.dynamic_body, &pos, &rot)
					rot_v := engine.quat_from_native(rot)
					engine.transform_set_world_position(vol.owner, pos)
					engine.transform_set_world_rotation(vol.owner, rot_v)
					vol.last_physics_pos = pos
					vol.last_physics_rot = rot_v
					vol.has_physics_sync = true
				}
			}
		} else {
			if physics3d.is_body_valid(vol.dynamic_body) && bi != nil {
				if jolt.BodyInterface_IsAdded(bi, vol.dynamic_body) {
					jolt.BodyInterface_RemoveBody(bi, vol.dynamic_body)
				}
				jolt.BodyInterface_DestroyBody(bi, vol.dynamic_body)
				vol.dynamic_body = 0
			}
			moved_static := vol.has_physics_sync &&
			                (linalg.length2(tw_cur.position - vol.last_physics_pos) > 1e-6 ||
			                 linalg.length2(tw_cur.rotation - vol.last_physics_rot) > 1e-5)
			for _, ch in vol.chunks {
				if ch.dirty_physics {
					_sync_chunk_physics_body(vol, ch)
				} else if moved_static && physics3d.is_body_valid(ch.static_body) && bi != nil && jolt.BodyInterface_IsAdded(bi, ch.static_body) {
					t_pos := tw_cur.position
					t_rot := engine.quat_to_native(tw_cur.rotation)
					jolt.BodyInterface_SetPositionAndRotation(bi, ch.static_body, &t_pos, &t_rot, .Activate)
				}
			}
			vol.last_physics_pos = tw_cur.position
			vol.last_physics_rot = tw_cur.rotation
			vol.has_physics_sync = true
		}
	}

	// 2. Drain completed async CSG blast results right before Jolt's PhysicsSystem_Update!
	csg_drain_completed_results()

	// 3. Tick and sync dynamic debris transforms from Jolt
	for i := len(_worker_state.debris_list) - 1; i >= 0; i -= 1 {
		deb := &_worker_state.debris_list[i]
		deb.ttl -= fixed_dt
		valid_t := deb.tH != {} && engine.pool_valid(&w.transforms, engine.Handle(deb.tH))
		if deb.ttl <= 0 || !valid_t {
			if physics3d.is_body_valid(deb.body_id) && bi != nil {
				if jolt.BodyInterface_IsAdded(bi, deb.body_id) {
					jolt.BodyInterface_RemoveBody(bi, deb.body_id)
				}
				jolt.BodyInterface_DestroyBody(bi, deb.body_id)
			}
			if deb.shape != nil {
				jolt.Shape_Destroy(deb.shape)
			}
			if !engine.asset_guid_is_empty(deb.mesh_guid) {
				engine.mesh_remove_procedural(deb.mesh_guid)
			}
			if valid_t {
				engine.transform_destroy(deb.tH)
			}
			ordered_remove(&_worker_state.debris_list, i)
			continue
		}

		// Copy Jolt dynamic body position & rotation back to debris Transform
		if physics3d.is_body_valid(deb.body_id) && bi != nil && jolt.BodyInterface_IsAdded(bi, deb.body_id) {
			pos: [3]f32
			rot: jolt.Quat
			jolt.BodyInterface_GetPositionAndRotation(bi, deb.body_id, &pos, &rot)
			if t := engine.pool_get(&w.transforms, engine.Handle(deb.tH)); t != nil {
				t.position = pos
				t.rotation = transmute([4]f32)rot
			}
		}
	}
}

// Tick and render Red Faction Blast Visual FX (shockwave rings, dust cloud billboards, flying sparks)
// in both Editor Scene3D and Game views!
csg_tick_and_draw_blast_fx :: proc(dt: f32) {
	// Also drain any completed async blasts when testing in Editor mode (outside Play mode)
	if !physics3d._state.world_ready {
		csg_drain_completed_results()
	}
	// Advance soft-deformer ripple oscillations & elastic springback recovery
	csg_tick_soft_deform_stamps(dt)

	if len(_worker_state.blast_fx) == 0 do return
	gizmos.in_world_space()
	gizmos.with_depth_test(true)

	for i := len(_worker_state.blast_fx) - 1; i >= 0; i -= 1 {
		fx := &_worker_state.blast_fx[i]
		fx.age += max(dt, 0.001)
		if fx.age >= fx.duration {
			ordered_remove(&_worker_state.blast_fx, i)
			continue
		}

		t := clamp(fx.age / fx.duration, 0.0, 1.0)
		inv_t := 1.0 - t

		// Expanding UT2003 Shockwave Rings & Flying Spark Streaks (no solid_sphere balls!)
		ring_r := fx.radius * (0.35 + math.sqrt(t) * 1.35)
		gizmos.with_color({1.0, 0.55, 0.15, inv_t * 0.90})
		gizmos.wire_circle(fx.world_pos, {0, 1, 0}, ring_r, 28)
		gizmos.wire_circle(fx.world_pos, {1, 0, 0}, ring_r * 0.85, 24)
		gizmos.wire_circle(fx.world_pos, {0, 0, 1}, ring_r * 0.85, 24)

		puff_count :: 10
		for p in 0 ..< puff_count {
			ang := f32(p) * (2.0 * math.PI / f32(puff_count)) + f32(fx.seed & 0xFF) * 0.02
			elev := (f32(p % 3) - 0.5) * 0.55
			dir := linalg.normalize0([3]f32{math.cos(ang), elev, math.sin(ang)})

			// Flying orange spark streak
			spark_start := fx.world_pos + dir * (fx.radius * t * 1.1)
			spark_end   := fx.world_pos + dir * (fx.radius * (t * 1.5 + 0.25))
			gizmos.with_color({1.0, 0.82, 0.30, inv_t * 0.95})
			gizmos.line(spark_start, spark_end)
		}
	}
}

@(phase={key=ExitingPlayMode})
csg_exiting_play_mode :: proc() {
	w := engine.ctx_world()
	if w != nil {
		it := engine.pool_iterator(csg_volumes(w))
		for vol, _ in engine.pool_next(&it) {
			vol.physics_world_id = 0
			vol.dynamic_body = 0
			vol.dynamic_shape = nil
			for _, ch in vol.chunks {
				ch.static_body = 0
				ch.jolt_shape = nil
				ch.dirty_physics = true
			}
			for &gp in vol.glass_panes {
				gp.glass_body = 0
				gp.glass_shape = nil
				gp.dirty_physics = true
			}
			csg_volume_restore_ram_state(vol)
		}
	}
	for &deb in _worker_state.debris_list {
		if !engine.asset_guid_is_empty(deb.mesh_guid) {
			engine.mesh_remove_procedural(deb.mesh_guid)
		}
	}
	clear(&_worker_state.debris_list)
	clear(&_worker_state.blast_fx)
}

@(phase={key=Shutdown})
csg_shutdown :: proc() {
	if _worker_state.running {
		sync.lock(&_worker_state.mutex)
		_worker_state.stop_flag = true
		sync.unlock(&_worker_state.mutex)
		if _worker_state.worker != nil {
			thread.join(_worker_state.worker)
			thread.destroy(_worker_state.worker)
			_worker_state.worker = nil
		}
		_worker_state.running = false
	}
}
