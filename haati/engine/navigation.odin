package engine

import "core:math"
import "core:math/linalg"

// =============================================================================
// Multi-Core NavMesh Baker, Triangle Adjacency Graph & A* Pathfinder
// =============================================================================

Nav_Poly :: struct {
	verts:     [3][3]f32,
	center:    [3]f32,
	normal:    [3]f32,
	neighbors: [3]i32,
	walkable:  bool,
}

NavMesh :: struct {
	polys:         [dynamic]Nav_Poly,
	bounds_min:    [3]f32,
	bounds_max:    [3]f32,
	max_slope_deg: f32,
}

@(private = "file")
_active_navmesh: struct {
	ready: bool,
	nm:    NavMesh,
}

navmesh_destroy :: proc(nm: ^NavMesh) {
	if nm == nil do return
	if nm.polys != nil {
		delete(nm.polys)
		nm.polys = nil
	}
	nm.bounds_min = {}
	nm.bounds_max = {}
}

navmesh_set_active :: proc(nm: NavMesh) {
	navmesh_clear_active()
	_active_navmesh.nm    = nm
	_active_navmesh.ready = true
}

navmesh_get_active :: proc() -> ^NavMesh {
	if !_active_navmesh.ready do return nil
	return &_active_navmesh.nm
}

navmesh_clear_active :: proc() {
	if _active_navmesh.ready {
		navmesh_destroy(&_active_navmesh.nm)
		_active_navmesh.ready = false
	}
}

@(private = "file")
_Tri_Bake_Ctx :: struct {
	positions:   [][3]f32,
	indices:     []u32,
	min_dot_y:   f32,
	out_polys:   []Nav_Poly,
}

@(private = "file")
_tri_bake_worker :: proc(start, end: int, userdata: rawptr) {
	ctx := cast(^_Tri_Bake_Ctx)userdata
	for tri := start; tri < end; tri += 1 {
		i0 := int(ctx.indices[tri * 3 + 0])
		i1 := int(ctx.indices[tri * 3 + 1])
		i2 := int(ctx.indices[tri * 3 + 2])
		if i0 < 0 || i1 < 0 || i2 < 0 || i0 >= len(ctx.positions) || i1 >= len(ctx.positions) || i2 >= len(ctx.positions) {
			continue
		}
		a := ctx.positions[i0]
		b := ctx.positions[i1]
		c := ctx.positions[i2]
		e1 := b - a
		e2 := c - a
		cross_n := linalg.cross(e1, e2)
		area2 := linalg.length(cross_n)
		if area2 <= 1e-6 do continue
		n := cross_n / area2
		// Ensure upward normal if winding flipped; keep authored orientation vs world up check.
		walk := n.y >= ctx.min_dot_y
		ctx.out_polys[tri] = Nav_Poly{
			verts     = {a, b, c},
			center    = (a + b + c) / 3.0,
			normal    = n,
			neighbors = {-1, -1, -1},
			walkable  = walk,
		}
	}
}

@(private = "file")
_quant_pt :: #force_inline proc(p: [3]f32) -> [3]i32 {
	return {
		i32(math.round(p.x * 1000.0)),
		i32(math.round(p.y * 1000.0)),
		i32(math.round(p.z * 1000.0)),
	}
}

@(private = "file")
_Edge_Key :: struct {
	a: [3]i32,
	b: [3]i32,
}

@(private = "file")
_edge_key_less :: proc(p, q: [3]i32) -> bool {
	if p.x != q.x do return p.x < q.x
	if p.y != q.y do return p.y < q.y
	return p.z < q.z
}

@(private = "file")
_make_undirected_edge :: proc(p, q: [3]f32) -> _Edge_Key {
	qp := _quant_pt(p)
	qq := _quant_pt(q)
	if _edge_key_less(qp, qq) do return _Edge_Key{qp, qq}
	return _Edge_Key{qq, qp}
}

// Bakes triangle soup into a walkable NavMesh in parallel via `job_parallel_for`
// and builds edge-shared polygon adjacency.
navmesh_bake_triangles :: proc(
	positions:          [][3]f32,
	indices:            []u32,
	walkable_slope_deg: f32 = 45.0,
	allocator           := context.allocator,
) -> (nm: NavMesh, ok: bool) {
	tri_count := len(indices) / 3
	if tri_count <= 0 || len(positions) < 3 do return {}, false

	slope_c := clamp(walkable_slope_deg, 1.0, 89.0)
	min_dot_y := math.cos(math.to_radians(slope_c))

	scratch := make([]Nav_Poly, tri_count, context.temp_allocator)
	ctx := _Tri_Bake_Ctx{
		positions = positions,
		indices   = indices,
		min_dot_y = min_dot_y,
		out_polys = scratch,
	}
	job_parallel_for(tri_count, 64, _tri_bake_worker, &ctx)

	nm.max_slope_deg = slope_c
	nm.polys = make([dynamic]Nav_Poly, 0, tri_count, allocator)
	first := true
	for tri in 0 ..< tri_count {
		p := scratch[tri]
		if !p.walkable do continue
		for v in p.verts {
			if first {
				nm.bounds_min = v
				nm.bounds_max = v
				first = false
			} else {
				nm.bounds_min.x = min(nm.bounds_min.x, v.x)
				nm.bounds_min.y = min(nm.bounds_min.y, v.y)
				nm.bounds_min.z = min(nm.bounds_min.z, v.z)
				nm.bounds_max.x = max(nm.bounds_max.x, v.x)
				nm.bounds_max.y = max(nm.bounds_max.y, v.y)
				nm.bounds_max.z = max(nm.bounds_max.z, v.z)
			}
		}
		append(&nm.polys, p)
	}

	if len(nm.polys) == 0 {
		navmesh_destroy(&nm)
		return {}, false
	}

	_Edge_Ref :: struct {
		poly_idx: i32,
		edge_idx: i32,
	}
	edge_map := make(map[_Edge_Key]_Edge_Ref, len(nm.polys) * 3, context.temp_allocator)
	for pi in 0 ..< len(nm.polys) {
		p := &nm.polys[pi]
		for ei in 0 ..< 3 {
			v0 := p.verts[ei]
			v1 := p.verts[(ei + 1) % 3]
			ek := _make_undirected_edge(v0, v1)
			if other, has := edge_map[ek]; has {
				if other.poly_idx != i32(pi) {
					p.neighbors[ei] = other.poly_idx
					nm.polys[other.poly_idx].neighbors[other.edge_idx] = i32(pi)
				}
			} else {
				edge_map[ek] = _Edge_Ref{i32(pi), i32(ei)}
			}
		}
	}

	return nm, true
}

@(private = "file")
_closest_point_on_triangle :: proc(p, a, b, c: [3]f32) -> [3]f32 {
	ab := b - a
	ac := c - a
	ap := p - a
	d1 := linalg.dot(ab, ap)
	d2 := linalg.dot(ac, ap)
	if d1 <= 0.0 && d2 <= 0.0 do return a

	bp := p - b
	d3 := linalg.dot(ab, bp)
	d4 := linalg.dot(ac, bp)
	if d3 >= 0.0 && d4 <= d3 do return b

	vc := d1 * d4 - d3 * d2
	if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
		v := d1 / (d1 - d3)
		return a + ab * v
	}

	cp := p - c
	d5 := linalg.dot(ab, cp)
	d6 := linalg.dot(ac, cp)
	if d6 >= 0.0 && d5 <= d6 do return c

	vb := d5 * d2 - d1 * d6
	if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
		w := d2 / (d2 - d6)
		return a + ac * w
	}

	va := d3 * d6 - d5 * d4
	if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0 {
		w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	}

	denom := 1.0 / max(va + vb + vc, 1e-8)
	v := vb * denom
	w := vc * denom
	return a + ab * v + ac * w
}

navmesh_find_nearest_point :: proc(nm: ^NavMesh, pt: [3]f32) -> (poly_idx: i32, closest: [3]f32, ok: bool) {
	if nm == nil || len(nm.polys) == 0 do return -1, {}, false
	best_dist2: f32 = 1e30
	best_idx: i32 = -1
	best_pt: [3]f32
	for pi in 0 ..< len(nm.polys) {
		poly := &nm.polys[pi]
		if !poly.walkable do continue
		cp := _closest_point_on_triangle(pt, poly.verts[0], poly.verts[1], poly.verts[2])
		d2 := linalg.length2(cp - pt)
		if d2 < best_dist2 {
			best_dist2 = d2
			best_idx = i32(pi)
			best_pt = cp
		}
	}
	if best_idx < 0 do return -1, {}, false
	return best_idx, best_pt, true
}

// Finds a polygon-corridor A* path smoothed through shared portal midpoints.
navmesh_find_path :: proc(
	nm:        ^NavMesh,
	start:     [3]f32,
	goal:      [3]f32,
	allocator := context.temp_allocator,
) -> (waypoints: [][3]f32, ok: bool) {
	if nm == nil || len(nm.polys) == 0 do return nil, false
	sp, start_pt, sok := navmesh_find_nearest_point(nm, start)
	gp, goal_pt, gok  := navmesh_find_nearest_point(nm, goal)
	if !sok || !gok do return nil, false

	if sp == gp {
		out := make([][3]f32, 2, allocator)
		out[0] = start_pt
		out[1] = goal_pt
		return out, true
	}

	n := len(nm.polys)
	g_score   := make([]f32, n, context.temp_allocator)
	f_score   := make([]f32, n, context.temp_allocator)
	came_from := make([]i32, n, context.temp_allocator)
	closed    := make([]bool, n, context.temp_allocator)
	in_open   := make([]bool, n, context.temp_allocator)

	for i in 0 ..< n {
		g_score[i]   = 1e30
		f_score[i]   = 1e30
		came_from[i] = -1
	}

	open := make([dynamic]i32, 0, min(n, 64), context.temp_allocator)
	g_score[sp] = 0
	f_score[sp] = linalg.distance(nm.polys[sp].center, goal_pt)
	in_open[sp] = true
	append(&open, sp)

	found := false
	for len(open) > 0 {
		best_open_i := 0
		best_node := open[0]
		best_f := f_score[best_node]
		for oi in 1 ..< len(open) {
			cand := open[oi]
			if f_score[cand] < best_f {
				best_f = f_score[cand]
				best_node = cand
				best_open_i = oi
			}
		}
		unordered_remove(&open, best_open_i)
		in_open[best_node] = false
		closed[best_node] = true

		if best_node == gp {
			found = true
			break
		}

		cur_poly := &nm.polys[best_node]
		for nb in cur_poly.neighbors {
			if nb < 0 || int(nb) >= n || closed[nb] do continue
			if !nm.polys[nb].walkable do continue
			step_cost := linalg.distance(cur_poly.center, nm.polys[nb].center)
			tentative_g := g_score[best_node] + step_cost
			if tentative_g < g_score[nb] {
				came_from[nb] = best_node
				g_score[nb]   = tentative_g
				f_score[nb]   = tentative_g + linalg.distance(nm.polys[nb].center, goal_pt)
				if !in_open[nb] {
					in_open[nb] = true
					append(&open, nb)
				}
			}
		}
	}

	if !found do return nil, false

	// Reconstruct polygon chain sp .. gp.
	rev_chain := make([dynamic]i32, 0, 16, context.temp_allocator)
	cur := gp
	for cur >= 0 {
		append(&rev_chain, cur)
		if cur == sp do break
		cur = came_from[cur]
	}

	pts := make([dynamic][3]f32, 0, len(rev_chain) + 2, allocator)
	append(&pts, start_pt)
	for i := len(rev_chain) - 1; i > 0; i -= 1 {
		p_a := rev_chain[i]
		p_b := rev_chain[i - 1]
		poly_a := &nm.polys[p_a]
		// Use midpoint of shared portal edge between adjacent triangles for smoother steering.
		portal_mid := nm.polys[p_b].center
		for ei in 0 ..< 3 {
			if poly_a.neighbors[ei] == p_b {
				portal_mid = (poly_a.verts[ei] + poly_a.verts[(ei + 1) % 3]) * 0.5
				break
			}
		}
		if linalg.distance(pts[len(pts) - 1], portal_mid) > 0.05 {
			append(&pts, portal_mid)
		}
	}
	if linalg.distance(pts[len(pts) - 1], goal_pt) > 0.01 {
		append(&pts, goal_pt)
	}
	return pts[:], true
}
