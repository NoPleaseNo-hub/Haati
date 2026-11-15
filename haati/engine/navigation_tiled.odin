package engine

// =============================================================================
// Two-Stage Async Tiled Jigsaw/CSG NavMesh + Active Destruction Quarantine
// =============================================================================
// - Partitions the world into 16m x 16m XZ tiles with a 2-cell neighbor apron.
// - Stage 1 (Coarse, 16x16) restores routing quickly on dirty tiles.
// - Stage 2 (Fine, 64x64, ~0.25m cells) rasterizes static MeshRenderers plus
//   registered plugin geometry providers (Physics3D static colliders, CSG chunks)
//   into a multi-span 2.5D heightfield, erodes by agent radius, and runs greedy
//   2D rectangle merging so flat jigsaw floors stay low-poly while props/doorways
//   carve cleanly.
// - Destruction Quarantine immediately marks blast craters non-walkable on the
//   active NavMesh and suppresses Fine rebakes inside actively fracturing tiles
//   until debris settles, preventing wasted mid-destruction churn.

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import core "haati:engine/core"

NAV_TILE_SIZE  :: f32(16.0)
NAV_COARSE_RES :: i32(16)
NAV_FINE_RES   :: i32(64)
NAV_APRON      :: i32(2)

Nav_Geometry_Emit_Proc     :: #type proc(user_data: rawptr, v0, v1, v2: [3]f32)
Nav_Geometry_Provider_Proc :: #type proc(w: ^World, aabb_min, aabb_max: [3]f32, emit: Nav_Geometry_Emit_Proc, emit_user: rawptr)

@(private = "file")
_MAX_NAV_PROVIDERS :: 32

@(private = "file")
_nav_providers: struct {
	procs: [32]Nav_Geometry_Provider_Proc,
	count: int,
}

// Registers a geometry provider (e.g. physics3d static colliders, cad_csg chunks)
// without coupling `haati/engine` back to any plugin package.
nav_register_geometry_provider :: proc(provider: Nav_Geometry_Provider_Proc) {
	if provider == nil do return
	for i in 0 ..< _nav_providers.count {
		if _nav_providers.procs[i] == provider do return
	}
	if _nav_providers.count < _MAX_NAV_PROVIDERS {
		_nav_providers.procs[_nav_providers.count] = provider
		_nav_providers.count += 1
	}
}

@(private = "file")
_Nav_Bake_Stage :: enum u8 {
	None   = 0,
	Coarse = 1,
	Fine   = 2,
}

@(private = "file")
_Nav_Tile :: struct {
	coord:          [2]i32,
	polys:          [dynamic]Nav_Poly,
	has_coarse:     bool,
	has_fine:       bool,
	pending_coarse: bool,
	pending_fine:   bool,
	in_flight:      _Nav_Bake_Stage,
}

@(private = "file")
_Nav_Tile_Job :: struct {
	coord:        [2]i32,
	stage:        _Nav_Bake_Stage,
	res:          i32,
	agent_radius: f32,
	agent_height: f32,
	step_height:  f32,
	min_dot_y:    f32,
	tris:         [][3][3]f32,
	out_polys:    [dynamic]Nav_Poly,
	counter:      core.Job_Counter,
	done:         bool,
}

@(private = "file")
_nav_tiled: struct {
	tiles:            map[[2]i32]_Nav_Tile,
	quarantine_until: map[[2]i32]f32,
	active_jobs:      [dynamic]^_Nav_Tile_Job,
	elapsed:          f32,
	need_rebuild:     bool,
	next_version:     u64,
	agent_radius:     f32,
	agent_height:     f32,
	step_height:      f32,
	max_slope_deg:    f32,
}

@(private = "file")
_nav_tiled_ensure_defaults :: proc() {
	if _nav_tiled.agent_radius <= 0 do _nav_tiled.agent_radius = 0.35
	if _nav_tiled.agent_height <= 0 do _nav_tiled.agent_height = 1.8
	if _nav_tiled.step_height  <= 0 do _nav_tiled.step_height  = 0.45
	if _nav_tiled.max_slope_deg <= 0 do _nav_tiled.max_slope_deg = 45.0
	if _nav_tiled.next_version == 0 do _nav_tiled.next_version = 1
}

@(private = "file")
_world_to_tile_coord :: #force_inline proc(x, z: f32) -> [2]i32 {
	inv := f32(1.0) / NAV_TILE_SIZE
	return {i32(math.floor(x * inv)), i32(math.floor(z * inv))}
}

@(private = "file")
_tile_world_bounds :: #force_inline proc(coord: [2]i32) -> (min_xz, max_xz: [2]f32) {
	x0 := f32(coord.x) * NAV_TILE_SIZE
	z0 := f32(coord.y) * NAV_TILE_SIZE
	return {x0, z0}, {x0 + NAV_TILE_SIZE, z0 + NAV_TILE_SIZE}
}

@(private = "file")
_ensure_tile :: proc(coord: [2]i32) -> ^_Nav_Tile {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _nav_tiled.tiles == nil {
		_nav_tiled.tiles = make(map[[2]i32]_Nav_Tile, 32)
	}
	if coord not_in _nav_tiled.tiles {
		_nav_tiled.tiles[coord] = _Nav_Tile{coord = coord}
	}
	return &_nav_tiled.tiles[coord]
}

// Marks all 16m tiles overlapping `bounds_min..bounds_max` dirty (`Coarse` if not yet
// baked, plus queued `Fine` refinement).
nav_tiled_mark_bounds_dirty :: proc(bounds_min, bounds_max: [3]f32) {
	_nav_tiled_ensure_defaults()
	pad := _nav_tiled.agent_radius + 0.5
	c0 := _world_to_tile_coord(bounds_min.x - pad, bounds_min.z - pad)
	c1 := _world_to_tile_coord(bounds_max.x + pad, bounds_max.z + pad)
	for tz in c0.y ..= c1.y {
		for tx in c0.x ..= c1.x {
			tile := _ensure_tile({tx, tz})
			if !tile.has_coarse && !tile.has_fine {
				tile.pending_coarse = true
			}
			tile.pending_fine = true
		}
	}
}

// Immediately removes walkability in `blast_center..blast_radius` on the active NavMesh
// and quarantines overlapping tiles from Fine rebakes for `settle_sec`.
nav_quarantine_begin :: proc(
	bounds_min:   [3]f32,
	bounds_max:   [3]f32,
	settle_sec:   f32 = 0.45,
	blast_center: [3]f32 = {},
	blast_radius: f32 = 0.0,
) {
	_nav_tiled_ensure_defaults()
	if nm := navmesh_get_active(); nm != nil && blast_radius > 0 {
		_ = navmesh_set_sphere_walkable(nm, blast_center, blast_radius, false)
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if _nav_tiled.quarantine_until == nil {
		_nav_tiled.quarantine_until = make(map[[2]i32]f32, 16)
	}
	until := _nav_tiled.elapsed + max(settle_sec, f32(0.05))
	pad := _nav_tiled.agent_radius + 0.5
	c0 := _world_to_tile_coord(bounds_min.x - pad, bounds_min.z - pad)
	c1 := _world_to_tile_coord(bounds_max.x + pad, bounds_max.z + pad)
	for tz in c0.y ..= c1.y {
		for tx in c0.x ..= c1.x {
			coord := [2]i32{tx, tz}
			if prev_until, has := _nav_tiled.quarantine_until[coord]; !has || until > prev_until {
				_nav_tiled.quarantine_until[coord] = until
			}
			tile := _ensure_tile(coord)
			tile.pending_fine = true
		}
	}
}

nav_is_tile_quarantined :: proc(coord: [2]i32) -> bool {
	if _nav_tiled.quarantine_until == nil do return false
	if until, ok := _nav_tiled.quarantine_until[coord]; ok {
		return _nav_tiled.elapsed < until
	}
	return false
}

@(private = "file")
_Tri_Gather_Ctx :: struct {
	min_xz: [2]f32,
	max_xz: [2]f32,
	tris:   [dynamic][3][3]f32,
}

@(private = "file")
_nav_emit_tri :: proc(user_data: rawptr, v0, v1, v2: [3]f32) {
	ctx := cast(^_Tri_Gather_Ctx)user_data
	if max(v0.x, max(v1.x, v2.x)) < ctx.min_xz.x || min(v0.x, min(v1.x, v2.x)) > ctx.max_xz.x do return
	if max(v0.z, max(v1.z, v2.z)) < ctx.min_xz.y || min(v0.z, min(v1.z, v2.z)) > ctx.max_xz.y do return
	append(&ctx.tris, [3][3]f32{v0, v1, v2})
}

@(private = "file")
_gather_static_mesh_renderers :: proc(w: ^World, aabb_min, aabb_max: [3]f32, emit: Nav_Geometry_Emit_Proc, emit_user: rawptr) {
	if w == nil || emit == nil do return
	mr_pool := mesh_renderers(w)
	if mr_pool == nil do return
	it := pool_iterator(mr_pool)
	for mr, _ in pool_next(&it) {
		if !mr.enabled do continue
		t := pool_get(&w.transforms, Handle(mr.owner))
		if t == nil || !transform_active_in_hierarchy(mr.owner) do continue
		if _, rb_idx := transform_find_comp(t, .Rigidbody); rb_idx >= 0 do continue

		_, mf := transform_get_comp(mr.owner, MeshFilter)
		if mf == nil || asset_guid_is_empty(mf.mesh.guid) do continue
		part, pok := mesh_filter_part(mf)
		if !pok do continue

		tw := transform_world(mr.owner)
		model := trs_matrix(tw.position, tw.rotation, tw.scale)

		if len(mesh_cache) > 0 {
			if m, mok := &mesh_cache[Mesh_Key{mf.mesh.guid, part}]; mok {
				lo := m.aabb_min
				hi := m.aabb_max
				if lo != hi {
					w_min := [3]f32{1e30, 1e30, 1e30}
					w_max := [3]f32{-1e30, -1e30, -1e30}
					for cz in 0 ..< 2 {
						for cy in 0 ..< 2 {
							for cx in 0 ..< 2 {
								corner := [4]f32{
									cx == 0 ? lo.x : hi.x,
									cy == 0 ? lo.y : hi.y,
									cz == 0 ? lo.z : hi.z,
									1.0,
								}
								wp := (model * corner).xyz
								w_min.x = min(w_min.x, wp.x); w_min.y = min(w_min.y, wp.y); w_min.z = min(w_min.z, wp.z)
								w_max.x = max(w_max.x, wp.x); w_max.y = max(w_max.y, wp.y); w_max.z = max(w_max.z, wp.z)
							}
						}
					}
					if w_max.x < aabb_min.x || w_min.x > aabb_max.x ||
					   w_max.z < aabb_min.z || w_min.z > aabb_max.z {
						continue
					}
				}
			}
		}

		verts, inds, ok := mesh_read_cpu_geometry(mf, context.temp_allocator)
		if !ok || len(verts) < 3 || len(inds) < 3 do continue
		tri_count := len(inds) / 3
		for ti in 0 ..< tri_count {
			i0 := int(inds[ti * 3 + 0])
			i1 := int(inds[ti * 3 + 1])
			i2 := int(inds[ti * 3 + 2])
			if i0 >= len(verts) || i1 >= len(verts) || i2 >= len(verts) do continue
			p0 := (model * [4]f32{verts[i0].position.x, verts[i0].position.y, verts[i0].position.z, 1.0}).xyz
			p1 := (model * [4]f32{verts[i1].position.x, verts[i1].position.y, verts[i1].position.z, 1.0}).xyz
			p2 := (model * [4]f32{verts[i2].position.x, verts[i2].position.y, verts[i2].position.z, 1.0}).xyz
			emit(emit_user, p0, p1, p2)
		}
	}
}

@(private = "file")
_snapshot_tile_geometry :: proc(w: ^World, coord: [2]i32, res: i32) -> [][3][3]f32 {
	cs := NAV_TILE_SIZE / f32(res)
	apron_m := f32(NAV_APRON) * cs + 0.1
	min_xz, max_xz := _tile_world_bounds(coord)
	q_min := [3]f32{min_xz.x - apron_m, -1e6, min_xz.y - apron_m}
	q_max := [3]f32{max_xz.x + apron_m,  1e6, max_xz.y + apron_m}

	ctx := _Tri_Gather_Ctx{
		min_xz = {q_min.x, q_min.z},
		max_xz = {q_max.x, q_max.z},
		tris   = make([dynamic][3][3]f32, 0, 256, runtime.default_allocator()),
	}
	_gather_static_mesh_renderers(w, q_min, q_max, _nav_emit_tri, &ctx)
	for pi in 0 ..< _nav_providers.count {
		if _nav_providers.procs[pi] != nil {
			_nav_providers.procs[pi](w, q_min, q_max, _nav_emit_tri, &ctx)
		}
	}
	return ctx.tris[:]
}

@(private = "file")
_HF_MAX_SPANS :: 4

@(private = "file")
_HF_Cell :: struct {
	ys:    [_HF_MAX_SPANS]f32,
	count: u8,
}

@(private = "file")
_hf_insert_floor :: proc(cell: ^_HF_Cell, y: f32) {
	n := int(cell.count)
	for i in 0 ..< n {
		if abs(cell.ys[i] - y) <= 0.05 {
			if y > cell.ys[i] do cell.ys[i] = y
			return
		}
	}
	if n < _HF_MAX_SPANS {
		cell.ys[n] = y
		cell.count += 1
		// Keep ascending so index 0 is lowest floor (interior room floors precede roofs).
		for i := n; i > 0 && cell.ys[i] < cell.ys[i - 1]; i -= 1 {
			cell.ys[i], cell.ys[i - 1] = cell.ys[i - 1], cell.ys[i]
		}
	} else if y < cell.ys[_HF_MAX_SPANS - 1] {
		cell.ys[_HF_MAX_SPANS - 1] = y
		for i := _HF_MAX_SPANS - 1; i > 0 && cell.ys[i] < cell.ys[i - 1]; i -= 1 {
			cell.ys[i], cell.ys[i - 1] = cell.ys[i - 1], cell.ys[i]
		}
	}
}

@(private = "file")
_tri_cell_bounds :: proc(a, b, c: [3]f32, orig_x, orig_z, inv_cs: f32, g: int) -> (gx0, gx1, gz0, gz1: int, ok: bool) {
	tx0 := min(a.x, min(b.x, c.x))
	tx1 := max(a.x, max(b.x, c.x))
	tz0 := min(a.z, min(b.z, c.z))
	tz1 := max(a.z, max(b.z, c.z))
	gx0 = int(math.floor((tx0 - orig_x) * inv_cs))
	gx1 = int(math.floor((tx1 - orig_x) * inv_cs))
	gz0 = int(math.floor((tz0 - orig_z) * inv_cs))
	gz1 = int(math.floor((tz1 - orig_z) * inv_cs))
	if gx1 < 0 || gx0 >= g || gz1 < 0 || gz0 >= g do return 0, -1, 0, -1, false
	gx0 = clamp(gx0, 0, g - 1)
	gx1 = clamp(gx1, 0, g - 1)
	gz0 = clamp(gz0, 0, g - 1)
	gz1 = clamp(gz1, 0, g - 1)
	return gx0, gx1, gz0, gz1, true
}

@(private = "file")
_nav_tile_job_worker :: proc(user_data: rawptr) {
	job := cast(^_Nav_Tile_Job)user_data
	if job == nil do return

	defer intrinsics.atomic_store_explicit(&job.done, true, .Release)
	if len(job.tris) == 0 do return

	res := int(job.res)
	apron := int(NAV_APRON)
	g := res + 2 * apron
	cs := NAV_TILE_SIZE / f32(res)
	inv_cs := 1.0 / cs
	min_xz, _ := _tile_world_bounds(job.coord)
	orig_x := min_xz.x - f32(apron) * cs
	orig_z := min_xz.y - f32(apron) * cs

	cells := make([]_HF_Cell, g * g, context.temp_allocator)
	// Pass 1: rasterize upward walkable floor triangles at cell centers.
	for tri in job.tris {
		a, b, c := tri[0], tri[1], tri[2]
		cross_n := linalg.cross(b - a, c - a)
		area2 := linalg.length(cross_n)
		if area2 <= 1e-6 do continue
		ny := cross_n.y / area2
		if ny < job.min_dot_y do continue

		gx0, gx1, gz0, gz1, ok := _tri_cell_bounds(a, b, c, orig_x, orig_z, inv_cs, g)
		if !ok do continue

		v0x := c.x - a.x; v0z := c.z - a.z
		v1x := b.x - a.x; v1z := b.z - a.z
		denom := v0x * v1z - v1x * v0z
		if abs(denom) < 1e-8 do continue
		inv_d := 1.0 / denom

		for gz in gz0 ..= gz1 {
			pz := orig_z + (f32(gz) + 0.5) * cs
			v2z := pz - a.z
			row := gz * g
			for gx in gx0 ..= gx1 {
				px := orig_x + (f32(gx) + 0.5) * cs
				v2x := px - a.x
				u := (v2x * v1z - v1x * v2z) * inv_d
				v := (v0x * v2z - v2x * v0z) * inv_d
				if u >= -0.02 && v >= -0.02 && (u + v) <= 1.04 {
					uc := clamp(u, f32(0.0), f32(1.0))
					vc := clamp(v, f32(0.0), f32(1.0))
					if uc + vc > 1.0 {
						s := 1.0 / (uc + vc)
						uc *= s
						vc *= s
					}
					y := a.y + uc * (c.y - a.y) + vc * (b.y - a.y)
					_hf_insert_floor(&cells[row + gx], y)
				}
			}
		}
	}

	// Pass 2: check headroom/obstacles over every candidate floor span using AABB-expanded
	// overlap so even thin walls/pillars never slip between cell centers.
	blocked_mask := make([]u8, g * g, context.temp_allocator)
	for tri in job.tris {
		a, b, c := tri[0], tri[1], tri[2]
		tri_ymin := min(a.y, min(b.y, c.y))
		tri_ymax := max(a.y, max(b.y, c.y))
		// Expand AABB by half a cell to catch narrow steep walls overlapping cell bounds.
		tx0 := min(a.x, min(b.x, c.x)) - cs * 0.48
		tx1 := max(a.x, max(b.x, c.x)) + cs * 0.48
		tz0 := min(a.z, min(b.z, c.z)) - cs * 0.48
		tz1 := max(a.z, max(b.z, c.z)) + cs * 0.48
		gx0 := int(math.floor((tx0 - orig_x) * inv_cs))
		gx1 := int(math.floor((tx1 - orig_x) * inv_cs))
		gz0 := int(math.floor((tz0 - orig_z) * inv_cs))
		gz1 := int(math.floor((tz1 - orig_z) * inv_cs))
		if gx1 < 0 || gx0 >= g || gz1 < 0 || gz0 >= g do continue
		gx0 = clamp(gx0, 0, g - 1)
		gx1 = clamp(gx1, 0, g - 1)
		gz0 = clamp(gz0, 0, g - 1)
		gz1 = clamp(gz1, 0, g - 1)

		for gz in gz0 ..= gz1 {
			row := gz * g
			for gx in gx0 ..= gx1 {
				cell := &cells[row + gx]
				if cell.count == 0 do continue
				for si in 0 ..< int(cell.count) {
					bit := u8(1) << u32(si)
					if (blocked_mask[row + gx] & bit) != 0 do continue
					fy := cell.ys[si]
					if tri_ymax > fy + job.step_height && tri_ymin < fy + job.agent_height {
						blocked_mask[row + gx] |= bit
					}
				}
			}
		}
	}

	walk_init := make([]bool, g * g, context.temp_allocator)
	floor_y := make([]f32, g * g, context.temp_allocator)
	for idx in 0 ..< g * g {
		c := cells[idx]
		if c.count == 0 do continue
		bm := blocked_mask[idx]
		for si in 0 ..< int(c.count) {
			if (bm & (u8(1) << u32(si))) == 0 {
				walk_init[idx] = true
				floor_y[idx] = c.ys[si]
				break
			}
		}
	}

	// Pass 3: erode walkable cells by agent radius (clamped by apron), checking both
	// obstacle neighbors and vertical drop cliffs (> step_height).
	erode_r := int(math.ceil(job.agent_radius / cs))
	if job.stage == .Coarse {
		erode_r = min(erode_r, 1)
	} else {
		erode_r = clamp(erode_r, 0, apron)
	}

	walk_final := make([]bool, g * g, context.temp_allocator)
	if erode_r <= 0 {
		copy(walk_final, walk_init)
	} else {
		erode_max_step := job.step_height * f32(erode_r) + 0.05
		for gz in 0 ..< g {
			row := gz * g
			for gx in 0 ..< g {
				cidx := row + gx
				if !walk_init[cidx] do continue
				cy := floor_y[cidx]
				ok := true
				outer: for dz in -erode_r ..= erode_r {
					nz := gz + dz
					if nz < 0 || nz >= g {
						ok = false
						break outer
					}
					nrow := nz * g
					for dx in -erode_r ..= erode_r {
						if dx * dx + dz * dz > erode_r * erode_r + 1 do continue
						nx := gx + dx
						if nx < 0 || nx >= g || !walk_init[nrow + nx] || abs(floor_y[nrow + nx] - cy) > erode_max_step {
							ok = false
							break outer
						}
					}
				}
				walk_final[cidx] = ok
			}
		}
	}

	// Pass 4: greedy 2D rectangle merge over interior [0..<res, 0..<res] walkable cells.
	used := make([]bool, res * res, context.temp_allocator)
	job.out_polys = make([dynamic]Nav_Poly, 0, res * 2, runtime.default_allocator())
	COPLANAR_TOL :: f32(0.12)

	for iz in 0 ..< res {
		for ix in 0 ..< res {
			uidx := iz * res + ix
			if used[uidx] do continue
			gidx0 := (iz + apron) * g + (ix + apron)
			if !walk_final[gidx0] {
				used[uidx] = true
				continue
			}

			base_h := floor_y[gidx0]
			w_cells := 1
			for ix + w_cells < res {
				nu := iz * res + (ix + w_cells)
				ng := (iz + apron) * g + (ix + w_cells + apron)
				if used[nu] || !walk_final[ng] || abs(floor_y[ng] - base_h) > COPLANAR_TOL {
					break
				}
				w_cells += 1
			}

			h_cells := 1
			row_loop: for iz + h_cells < res {
				rz := iz + h_cells
				for kx in 0 ..< w_cells {
					nu := rz * res + (ix + kx)
					ng := (rz + apron) * g + (ix + kx + apron)
					if used[nu] || !walk_final[ng] || abs(floor_y[ng] - base_h) > COPLANAR_TOL {
						break row_loop
					}
				}
				h_cells += 1
			}

			y_sum := f32(0.0)
			for kz in 0 ..< h_cells {
				for kx in 0 ..< w_cells {
					used[(iz + kz) * res + (ix + kx)] = true
					y_sum += floor_y[(iz + kz + apron) * g + (ix + kx + apron)]
				}
			}
			avg_y := y_sum / f32(w_cells * h_cells)

			x0 := min_xz.x + f32(ix) * cs
			x1 := min_xz.x + f32(ix + w_cells) * cs
			z0 := min_xz.y + f32(iz) * cs
			z1 := min_xz.y + f32(iz + h_cells) * cs
			v00 := [3]f32{x0, avg_y, z0}
			v01 := [3]f32{x0, avg_y, z1}
			v11 := [3]f32{x1, avg_y, z1}
			v10 := [3]f32{x1, avg_y, z0}

			// CCW upward (+Y) triangles: cross(v01-v00, v11-v00) = (0, +dx*dz, 0).
			append(&job.out_polys, Nav_Poly{
				verts     = {v00, v01, v11},
				center    = (v00 + v01 + v11) / 3.0,
				normal    = {0, 1, 0},
				neighbors = {-1, -1, -1},
				walkable  = true,
			})
			append(&job.out_polys, Nav_Poly{
				verts     = {v00, v11, v10},
				center    = (v00 + v11 + v10) / 3.0,
				normal    = {0, 1, 0},
				neighbors = {-1, -1, -1},
				walkable  = true,
			})
		}
	}

	// Pre-stitch intra-tile shared edges on worker thread.
	if len(job.out_polys) > 0 {
		_Edge_Ref :: struct {
			poly_idx: i32,
			edge_idx: i32,
		}
		edge_map := make(map[_Edge_Key]_Edge_Ref, len(job.out_polys) * 3, context.temp_allocator)
		for &p, pi in job.out_polys {
			for ei in 0 ..< 3 {
				ek := _make_undirected_edge(p.verts[ei], p.verts[(ei + 1) % 3])
				if other, has := edge_map[ek]; has {
					if other.poly_idx != i32(pi) {
						p.neighbors[ei] = other.poly_idx
						job.out_polys[other.poly_idx].neighbors[other.edge_idx] = i32(pi)
					}
				} else {
					edge_map[ek] = _Edge_Ref{i32(pi), i32(ei)}
				}
			}
		}
	}
}

@(private = "file")
_dispatch_tile_job :: proc(w: ^World, tile: ^_Nav_Tile, stage: _Nav_Bake_Stage) {
	if tile == nil || stage == .None do return
	res := stage == .Coarse ? NAV_COARSE_RES : NAV_FINE_RES
	tris := _snapshot_tile_geometry(w, tile.coord, res)

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if _nav_tiled.active_jobs == nil {
		_nav_tiled.active_jobs = make([dynamic]^_Nav_Tile_Job, 0, 8)
	}
	slope_c := clamp(_nav_tiled.max_slope_deg, 1.0, 89.0)
	job := new(_Nav_Tile_Job)
	job.coord        = tile.coord
	job.stage        = stage
	job.res          = res
	job.agent_radius = _nav_tiled.agent_radius
	job.agent_height = _nav_tiled.agent_height
	job.step_height  = _nav_tiled.step_height
	job.min_dot_y    = math.cos(math.to_radians(slope_c))
	job.tris         = tris

	tile.in_flight = stage
	if stage == .Coarse {
		tile.pending_coarse = false
	} else {
		tile.pending_fine = false
	}
	append(&_nav_tiled.active_jobs, job)
	core.job_dispatch(_nav_tile_job_worker, job, &job.counter)
}

@(private = "file")
_nav_tiled_harvest_finished :: proc() {
	for i := len(_nav_tiled.active_jobs) - 1; i >= 0; i -= 1 {
		job := _nav_tiled.active_jobs[i]
		if !intrinsics.atomic_load_explicit(&job.done, .Acquire) do continue
		core.job_wait(&job.counter)
		ordered_remove(&_nav_tiled.active_jobs, i)

		if _nav_tiled.tiles != nil {
			if tile, ok := &_nav_tiled.tiles[job.coord]; ok {
				if tile.in_flight == job.stage {
					tile.in_flight = .None
				}
				if job.stage == .Coarse {
					tile.has_coarse = true
					if !tile.has_fine {
						if tile.polys != nil do delete(tile.polys)
						tile.polys = job.out_polys
						job.out_polys = nil
						_nav_tiled.need_rebuild = true
					}
				} else {
					tile.has_fine = true
					if tile.polys != nil do delete(tile.polys)
					tile.polys = job.out_polys
					job.out_polys = nil
					_nav_tiled.need_rebuild = true
				}
			}
		}

		if job.out_polys != nil do delete(job.out_polys)
		if job.tris != nil do delete(job.tris, runtime.default_allocator())
		free(job, runtime.default_allocator())
	}
}

@(private = "file")
_nav_tiled_assemble_navmesh :: proc() {
	_nav_tiled_ensure_defaults()
	if _nav_tiled.tiles == nil do return

	total_polys := 0
	for _, &tile in _nav_tiled.tiles {
		total_polys += len(tile.polys)
	}
	if total_polys == 0 {
		_nav_tiled.next_version += 1
		navmesh_clear_active()
		_nav_tiled.need_rebuild = false
		return
	}

	nm := NavMesh{
		max_slope_deg = _nav_tiled.max_slope_deg,
		polys         = make([dynamic]Nav_Poly, 0, total_polys, runtime.default_allocator()),
	}
	for _, &tile in _nav_tiled.tiles {
		if len(tile.polys) == 0 do continue
		base := i32(len(nm.polys))
		for p in tile.polys {
			np := p
			for ni in 0 ..< 3 {
				if np.neighbors[ni] >= 0 {
					np.neighbors[ni] += base
				}
			}
			append(&nm.polys, np)
		}
	}

	_ = navmesh_stitch_seams(&nm, 0.08, max(_nav_tiled.step_height, f32(0.35)))
	navmesh_rebuild_spatial_grid(&nm, runtime.default_allocator())
	_nav_tiled.next_version += 1
	nm.version = _nav_tiled.next_version
	navmesh_set_active(nm)
	_nav_tiled.need_rebuild = false
}

// Per-frame tiled NavMesh driver (`order=45`, strictly before `nav_agents_update` at `50`).
@(update={order=45})
nav_tiled_update :: proc(dt: f32) {
	_nav_tiled_ensure_defaults()
	if dt > 0 {
		_nav_tiled.elapsed += dt
	}

	// Expire settled destruction quarantines -> allow queued Fine rebakes.
	if _nav_tiled.quarantine_until != nil && len(_nav_tiled.quarantine_until) > 0 {
		expired := make([dynamic][2]i32, 0, len(_nav_tiled.quarantine_until), context.temp_allocator)
		for coord, until in _nav_tiled.quarantine_until {
			if _nav_tiled.elapsed >= until {
				append(&expired, coord)
			}
		}
		for coord in expired {
			delete_key(&_nav_tiled.quarantine_until, coord)
			tile := _ensure_tile(coord)
			tile.pending_fine = true
		}
	}

	// Harvest dirty geometry events emitted by CSG blast drains / dynamic edits.
	if dirty, bmin, bmax := navmesh_consume_dirty(); dirty {
		nav_tiled_mark_bounds_dirty(bmin, bmax)
	}

	_nav_tiled_harvest_finished()

	w := ctx_world()
	if w != nil && _nav_tiled.tiles != nil {
		MAX_DISPATCH_PER_FRAME :: 4
		dispatched := 0
		// Priority 1: Coarse passes restore connectivity fastest on newly dirty tiles.
		for _, &tile in _nav_tiled.tiles {
			if dispatched >= MAX_DISPATCH_PER_FRAME do break
			if tile.in_flight != .None || !tile.pending_coarse do continue
			_dispatch_tile_job(w, &tile, .Coarse)
			dispatched += 1
		}
		// Priority 2: Fine passes (suppressed while tile is inside active destruction quarantine).
		for coord, &tile in _nav_tiled.tiles {
			if dispatched >= MAX_DISPATCH_PER_FRAME do break
			if tile.in_flight != .None || !tile.pending_fine do continue
			if nav_is_tile_quarantined(coord) do continue
			_dispatch_tile_job(w, &tile, .Fine)
			dispatched += 1
		}
	}

	if _nav_tiled.need_rebuild {
		_nav_tiled_assemble_navmesh()
	}
}

// Synchronously dispatches and waits on all pending unquarantined tiles and rebuilds
// the active `NavMesh` (for baking tools & unit tests).
nav_tiled_flush_all :: proc() {
	_nav_tiled_ensure_defaults()
	w := ctx_world()
	for {
		for i := len(_nav_tiled.active_jobs) - 1; i >= 0; i -= 1 {
			core.job_wait(&_nav_tiled.active_jobs[i].counter)
		}
		_nav_tiled_harvest_finished()

		did_dispatch := false
		if w != nil && _nav_tiled.tiles != nil {
			for coord, &tile in _nav_tiled.tiles {
				if tile.in_flight != .None do continue
				if tile.pending_coarse {
					_dispatch_tile_job(w, &tile, .Coarse)
					did_dispatch = true
				} else if tile.pending_fine && !nav_is_tile_quarantined(coord) {
					_dispatch_tile_job(w, &tile, .Fine)
					did_dispatch = true
				}
			}
		}
		if !did_dispatch && len(_nav_tiled.active_jobs) == 0 do break
	}
	if _nav_tiled.need_rebuild {
		_nav_tiled_assemble_navmesh()
	}
}

// Synchronous helper to bake all tiles intersecting `bounds_min..bounds_max`.
nav_tiled_rebake_bounds_sync :: proc(
	w:             ^World,
	bounds_min:    [3]f32,
	bounds_max:    [3]f32,
	agent_radius:  f32 = 0.35,
	max_slope_deg: f32 = 45.0,
) -> bool {
	if w == nil do return false
	_nav_tiled.agent_radius = max(agent_radius, f32(0.05))
	_nav_tiled.max_slope_deg = clamp(max_slope_deg, 1.0, 89.0)
	_nav_tiled_ensure_defaults()
	nav_tiled_mark_bounds_dirty(bounds_min, bounds_max)
	if _nav_tiled.tiles != nil {
		c0 := _world_to_tile_coord(bounds_min.x - _nav_tiled.agent_radius, bounds_min.z - _nav_tiled.agent_radius)
		c1 := _world_to_tile_coord(bounds_max.x + _nav_tiled.agent_radius, bounds_max.z + _nav_tiled.agent_radius)
		for tz in c0.y ..= c1.y {
			for tx in c0.x ..= c1.x {
				tile := _ensure_tile({tx, tz})
				// Jump straight to Fine for sync rebake calls.
				tile.pending_coarse = false
				tile.pending_fine = true
			}
		}
	}
	prev_w := _ctx_world_swap(w)
	defer _ = _ctx_world_swap(prev_w)
	nav_tiled_flush_all()
	return navmesh_get_active() != nil
}

@(private = "file")
_ctx_world_swap :: proc(w: ^World) -> ^World {
	uc := ctx_get()
	if uc == nil do return nil
	old := uc.world
	uc.world = w
	return old
}

// Waits for any in-flight tile bake jobs and releases all tiled navmesh allocations.
nav_tiled_reset :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if _nav_tiled.active_jobs != nil {
		for job in _nav_tiled.active_jobs {
			core.job_wait(&job.counter)
			if job.out_polys != nil do delete(job.out_polys)
			if job.tris != nil do delete(job.tris, runtime.default_allocator())
			free(job, runtime.default_allocator())
		}
		delete(_nav_tiled.active_jobs)
		_nav_tiled.active_jobs = nil
	}
	if _nav_tiled.tiles != nil {
		for _, &tile in _nav_tiled.tiles {
			if tile.polys != nil do delete(tile.polys)
		}
		delete(_nav_tiled.tiles)
		_nav_tiled.tiles = nil
	}
	if _nav_tiled.quarantine_until != nil {
		delete(_nav_tiled.quarantine_until)
		_nav_tiled.quarantine_until = nil
	}
	_nav_tiled.elapsed = 0
	_nav_tiled.need_rebuild = false
	_nav_tiled.next_version = 1
	_, _, _ = navmesh_consume_dirty()
	navmesh_clear_active()
}

@(phase={key=ExitingPlayMode})
_nav_tiled_on_exit_play :: proc() {
	nav_tiled_reset()
}

@(phase={key=Shutdown})
_nav_tiled_on_shutdown :: proc() {
	nav_tiled_reset()
}
