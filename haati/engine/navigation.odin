package engine

import "base:runtime"
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
	version:       u64,
	polys:         [dynamic]Nav_Poly,
	bounds_min:    [3]f32,
	bounds_max:    [3]f32,
	max_slope_deg: f32,

	// Flat CSR 2D XZ spatial grid for sub-linear nearest-polygon lookup
	grid_min:      [2]f32,
	grid_inv_cell: f32,
	grid_w:        i32,
	grid_h:        i32,
	grid_offsets:  []i32,
	grid_tris:     []i32,
	grid_alloc:    runtime.Allocator,
}

NavMesh_Dirty_Proc :: #type proc(bounds_min, bounds_max: [3]f32)

@(private = "file")
_nav_dirty: struct {
	callback:   NavMesh_Dirty_Proc,
	pending:    bool,
	bounds_min: [3]f32,
	bounds_max: [3]f32,
}

navmesh_set_dirty_callback :: proc(cb: NavMesh_Dirty_Proc) {
	_nav_dirty.callback = cb
}

navmesh_notify_geometry_changed :: proc(bounds_min, bounds_max: [3]f32) {
	if !_nav_dirty.pending {
		_nav_dirty.bounds_min = bounds_min
		_nav_dirty.bounds_max = bounds_max
		_nav_dirty.pending = true
	} else {
		_nav_dirty.bounds_min.x = min(_nav_dirty.bounds_min.x, bounds_min.x)
		_nav_dirty.bounds_min.y = min(_nav_dirty.bounds_min.y, bounds_min.y)
		_nav_dirty.bounds_min.z = min(_nav_dirty.bounds_min.z, bounds_min.z)
		_nav_dirty.bounds_max.x = max(_nav_dirty.bounds_max.x, bounds_max.x)
		_nav_dirty.bounds_max.y = max(_nav_dirty.bounds_max.y, bounds_max.y)
		_nav_dirty.bounds_max.z = max(_nav_dirty.bounds_max.z, bounds_max.z)
	}
	if _nav_dirty.callback != nil {
		_nav_dirty.callback(bounds_min, bounds_max)
	}
}

navmesh_consume_dirty :: proc() -> (dirty: bool, min_b, max_b: [3]f32) {
	if !_nav_dirty.pending do return false, {}, {}
	min_b = _nav_dirty.bounds_min
	max_b = _nav_dirty.bounds_max
	_nav_dirty.pending = false
	_nav_dirty.bounds_min = {}
	_nav_dirty.bounds_max = {}
	return true, min_b, max_b
}

@(private = "file")
_active_navmesh: struct {
	ready: bool,
	nm:    NavMesh,
}

navmesh_destroy :: proc(nm: ^NavMesh) {
	if nm == nil do return
	if nm.grid_offsets != nil {
		delete(nm.grid_offsets, nm.grid_alloc)
		nm.grid_offsets = nil
	}
	if nm.grid_tris != nil {
		delete(nm.grid_tris, nm.grid_alloc)
		nm.grid_tris = nil
	}
	if nm.polys != nil {
		delete(nm.polys)
		nm.polys = nil
	}
	nm.grid_w = 0
	nm.grid_h = 0
	nm.grid_inv_cell = 0
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

_Edge_Key :: struct {
	a: [3]i32,
	b: [3]i32,
}

_edge_key_less :: proc(p, q: [3]i32) -> bool {
	if p.x != q.x do return p.x < q.x
	if p.y != q.y do return p.y < q.y
	return p.z < q.z
}

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

	nm.version = 1
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

	_navmesh_build_grid(&nm, allocator)
	return nm, true
}

@(private = "file")
_navmesh_build_grid :: proc(nm: ^NavMesh, allocator := context.allocator) {
	if nm == nil || len(nm.polys) == 0 do return
	extent_x := max(nm.bounds_max.x - nm.bounds_min.x, 1.0)
	extent_z := max(nm.bounds_max.z - nm.bounds_min.z, 1.0)
	max_ext := max(extent_x, extent_z)
	target_dim := clamp(int(math.ceil(math.sqrt(f32(len(nm.polys)) * 2.0))), 4, 64)
	cell_size := max(max_ext / f32(target_dim), 0.25)
	inv_cell := 1.0 / cell_size
	gw := clamp(i32(math.ceil(extent_x * inv_cell)), 1, 64)
	gh := clamp(i32(math.ceil(extent_z * inv_cell)), 1, 64)
	cell_count := int(gw * gh)

	counts := make([]i32, cell_count, context.temp_allocator)
	for &p in nm.polys {
		if !p.walkable do continue
		min_x := min(p.verts[0].x, min(p.verts[1].x, p.verts[2].x))
		max_x := max(p.verts[0].x, max(p.verts[1].x, p.verts[2].x))
		min_z := min(p.verts[0].z, min(p.verts[1].z, p.verts[2].z))
		max_z := max(p.verts[0].z, max(p.verts[1].z, p.verts[2].z))
		cx0 := clamp(i32(math.floor((min_x - nm.bounds_min.x) * inv_cell)), 0, gw - 1)
		cx1 := clamp(i32(math.floor((max_x - nm.bounds_min.x) * inv_cell)), 0, gw - 1)
		cz0 := clamp(i32(math.floor((min_z - nm.bounds_min.z) * inv_cell)), 0, gh - 1)
		cz1 := clamp(i32(math.floor((max_z - nm.bounds_min.z) * inv_cell)), 0, gh - 1)
		for cz in cz0 ..= cz1 {
			row := cz * gw
			for cx in cx0 ..= cx1 {
				counts[row + cx] += 1
			}
		}
	}

	nm.grid_alloc = allocator
	nm.grid_min = {nm.bounds_min.x, nm.bounds_min.z}
	nm.grid_inv_cell = inv_cell
	nm.grid_w = gw
	nm.grid_h = gh
	nm.grid_offsets = make([]i32, cell_count + 1, allocator)
	running := i32(0)
	for ci in 0 ..< cell_count {
		nm.grid_offsets[ci] = running
		running += counts[ci]
	}
	nm.grid_offsets[cell_count] = running

	nm.grid_tris = make([]i32, int(running), allocator)
	cursors := make([]i32, cell_count, context.temp_allocator)
	copy(cursors, nm.grid_offsets[:cell_count])
	for &p, pi in nm.polys {
		if !p.walkable do continue
		min_x := min(p.verts[0].x, min(p.verts[1].x, p.verts[2].x))
		max_x := max(p.verts[0].x, max(p.verts[1].x, p.verts[2].x))
		min_z := min(p.verts[0].z, min(p.verts[1].z, p.verts[2].z))
		max_z := max(p.verts[0].z, max(p.verts[1].z, p.verts[2].z))
		cx0 := clamp(i32(math.floor((min_x - nm.bounds_min.x) * inv_cell)), 0, gw - 1)
		cx1 := clamp(i32(math.floor((max_x - nm.bounds_min.x) * inv_cell)), 0, gw - 1)
		cz0 := clamp(i32(math.floor((min_z - nm.bounds_min.z) * inv_cell)), 0, gh - 1)
		cz1 := clamp(i32(math.floor((max_z - nm.bounds_min.z) * inv_cell)), 0, gh - 1)
		for cz in cz0 ..= cz1 {
			row := cz * gw
			for cx in cx0 ..= cx1 {
				cidx := row + cx
				nm.grid_tris[cursors[cidx]] = i32(pi)
				cursors[cidx] += 1
			}
		}
	}
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

@(private = "file")
_nav_cell_search :: #force_inline proc(
	nm:         ^NavMesh,
	pt:         [3]f32,
	cx, cz:     i32,
	cell_size:  f32,
	best_dist2: ^f32,
	best_idx:   ^i32,
	best_pt:    ^[3]f32,
) -> f32 {
	min_x := nm.grid_min.x + f32(cx) * cell_size
	max_x := min_x + cell_size
	min_z := nm.grid_min.y + f32(cz) * cell_size
	max_z := min_z + cell_size
	dx := max(0.0, max(min_x - pt.x, pt.x - max_x))
	dz := max(0.0, max(min_z - pt.z, pt.z - max_z))
	cell_lb2 := dx * dx + dz * dz
	if cell_lb2 >= best_dist2^ do return cell_lb2

	cidx := cz * nm.grid_w + cx
	start := nm.grid_offsets[cidx]
	end := nm.grid_offsets[cidx + 1]
	for ti in start ..< end {
		pi := nm.grid_tris[ti]
		poly := &nm.polys[pi]
		if !poly.walkable do continue
		cp := _closest_point_on_triangle(pt, poly.verts[0], poly.verts[1], poly.verts[2])
		d2 := linalg.length2(cp - pt)
		if d2 < best_dist2^ {
			best_dist2^ = d2
			best_idx^ = pi
			best_pt^ = cp
		}
	}
	return cell_lb2
}

navmesh_find_nearest_point :: proc(nm: ^NavMesh, pt: [3]f32) -> (poly_idx: i32, closest: [3]f32, ok: bool) {
	if nm == nil || len(nm.polys) == 0 do return -1, {}, false
	best_dist2: f32 = 1e30
	best_idx: i32 = -1
	best_pt: [3]f32

	if nm.grid_w > 0 && nm.grid_h > 0 && nm.grid_inv_cell > 0 && len(nm.grid_offsets) == int(nm.grid_w * nm.grid_h) + 1 {
		gw := nm.grid_w
		gh := nm.grid_h
		cell_size := 1.0 / nm.grid_inv_cell
		qcx := clamp(i32(math.floor((pt.x - nm.grid_min.x) * nm.grid_inv_cell)), 0, gw - 1)
		qcz := clamp(i32(math.floor((pt.z - nm.grid_min.y) * nm.grid_inv_cell)), 0, gh - 1)
		max_ring := max(max(qcx, gw - 1 - qcx), max(qcz, gh - 1 - qcz))

		for r in i32(0) ..= max_ring {
			min_ring_lb2: f32 = 1e30
			if r == 0 {
				min_ring_lb2 = _nav_cell_search(nm, pt, qcx, qcz, cell_size, &best_dist2, &best_idx, &best_pt)
			} else {
				x0 := qcx - r
				x1 := qcx + r
				z0 := qcz - r
				z1 := qcz + r
				for cx := max(x0, 0); cx <= min(x1, gw - 1); cx += 1 {
					if z0 >= 0 do min_ring_lb2 = min(min_ring_lb2, _nav_cell_search(nm, pt, cx, z0, cell_size, &best_dist2, &best_idx, &best_pt))
					if z1 < gh do min_ring_lb2 = min(min_ring_lb2, _nav_cell_search(nm, pt, cx, z1, cell_size, &best_dist2, &best_idx, &best_pt))
				}
				for cz := max(z0 + 1, 0); cz <= min(z1 - 1, gh - 1); cz += 1 {
					if x0 >= 0 do min_ring_lb2 = min(min_ring_lb2, _nav_cell_search(nm, pt, x0, cz, cell_size, &best_dist2, &best_idx, &best_pt))
					if x1 < gw do min_ring_lb2 = min(min_ring_lb2, _nav_cell_search(nm, pt, x1, cz, cell_size, &best_dist2, &best_idx, &best_pt))
				}
			}
			if r >= 1 && best_idx >= 0 && min_ring_lb2 >= best_dist2 do break
		}
		if best_idx >= 0 do return best_idx, best_pt, true
	}

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

@(private = "file")
_nav_heap_sift_up :: proc(heap: []i32, heap_pos: []i32, f_score: []f32, idx: int) {
	i := idx
	node := heap[i]
	nf := f_score[node]
	for i > 0 {
		parent := (i - 1) >> 1
		pn := heap[parent]
		if nf >= f_score[pn] do break
		heap[i] = pn
		heap_pos[pn] = i32(i)
		i = parent
	}
	heap[i] = node
	heap_pos[node] = i32(i)
}

@(private = "file")
_nav_heap_sift_down :: proc(heap: []i32, heap_pos: []i32, f_score: []f32, count: int, idx: int) {
	i := idx
	node := heap[i]
	nf := f_score[node]
	for {
		left := (i << 1) + 1
		if left >= count do break
		best := left
		right := left + 1
		if right < count && f_score[heap[right]] < f_score[heap[left]] {
			best = right
		}
		bn := heap[best]
		if nf <= f_score[bn] do break
		heap[i] = bn
		heap_pos[bn] = i32(i)
		i = best
	}
	heap[i] = node
	heap_pos[node] = i32(i)
}

@(private = "file")
_nav_triarea2_xz :: #force_inline proc(a, b, c: [3]f32) -> f32 {
	return (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
}

@(private = "file")
_nav_xz_equal :: #force_inline proc(a, b: [3]f32) -> bool {
	dx := a.x - b.x
	dz := a.z - b.z
	return dx * dx + dz * dz < 1e-8
}

// Finds an indexed binary-heap A* polygon corridor smoothed by 2D XZ SSFA funnel string-pulling.
navmesh_find_path :: proc(
	nm:           ^NavMesh,
	start:        [3]f32,
	goal:         [3]f32,
	allocator     := context.temp_allocator,
	agent_radius: f32 = 0.0,
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
	heap_pos  := make([]i32, n, context.temp_allocator)

	for i in 0 ..< n {
		g_score[i]   = 1e30
		f_score[i]   = 1e30
		came_from[i] = -1
		heap_pos[i]  = -1
	}

	open := make([dynamic]i32, 0, min(n, 64), context.temp_allocator)
	g_score[sp] = 0
	f_score[sp] = linalg.distance(nm.polys[sp].center, goal_pt)
	heap_pos[sp] = 0
	append(&open, sp)

	found := false
	for len(open) > 0 {
		best_node := open[0]
		heap_pos[best_node] = -1
		last_node := pop(&open)
		if len(open) > 0 {
			open[0] = last_node
			heap_pos[last_node] = 0
			_nav_heap_sift_down(open[:], heap_pos, f_score, len(open), 0)
		}
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
				pos := int(heap_pos[nb])
				if pos < 0 {
					pos = len(open)
					heap_pos[nb] = i32(pos)
					append(&open, nb)
				}
				_nav_heap_sift_up(open[:], heap_pos, f_score, pos)
			}
		}
	}

	if !found do return nil, false

	rev_chain := make([dynamic]i32, 0, 16, context.temp_allocator)
	cur := gp
	for cur >= 0 {
		append(&rev_chain, cur)
		if cur == sp do break
		cur = came_from[cur]
	}

	_Nav_Portal :: struct {
		right: [3]f32,
		left:  [3]f32,
	}
	portals := make([dynamic]_Nav_Portal, 0, len(rev_chain), context.temp_allocator)
	for i := len(rev_chain) - 1; i > 0; i -= 1 {
		p_a := rev_chain[i]
		p_b := rev_chain[i - 1]
		poly_a := &nm.polys[p_a]
		poly_b := &nm.polys[p_b]
		e0 := poly_b.center
		e1 := e0
		found_a := false
		for ei in 0 ..< 3 {
			if poly_a.neighbors[ei] == p_b {
				e0 = poly_a.verts[ei]
				e1 = poly_a.verts[(ei + 1) % 3]
				found_a = true
				break
			}
		}
		// If the destination triangle exposes a strictly narrower portal edge (e.g.
		// entering a doorway from a large merged room quad), tighten the portal to it.
		for ei in 0 ..< 3 {
			if poly_b.neighbors[ei] == p_a {
				b0 := poly_b.verts[ei]
				b1 := poly_b.verts[(ei + 1) % 3]
				if !found_a || linalg.length2(b1 - b0) < linalg.length2(e1 - e0) {
					e0 = b1
					e1 = b0
				}
				break
			}
		}
		right, left := e0, e1
		if _nav_triarea2_xz(poly_a.center, e0, e1) < 0 {
			right, left = e1, e0
		}
		if agent_radius > 0 {
			edge := left - right
			elen := math.sqrt(edge.x * edge.x + edge.z * edge.z)
			if elen > 1e-4 {
				inset := min(agent_radius, elen * 0.45)
				dir := edge / elen
				right += dir * inset
				left -= dir * inset
			}
		}
		append(&portals, _Nav_Portal{right = right, left = left})
	}
	append(&portals, _Nav_Portal{right = goal_pt, left = goal_pt})

	pts := make([dynamic][3]f32, 0, len(portals) + 2, allocator)
	append(&pts, start_pt)

	apex := start_pt
	portal_right := start_pt
	portal_left := start_pt
	apex_idx := -1
	right_idx := -1
	left_idx := -1

	pi := 0
	for pi < len(portals) {
		right := portals[pi].right
		left := portals[pi].left

		if _nav_triarea2_xz(apex, portal_right, right) >= 0 {
			if _nav_xz_equal(apex, portal_right) || _nav_xz_equal(apex, portal_left) || _nav_triarea2_xz(apex, portal_left, right) < 0 {
				portal_right = right
				right_idx = pi
			} else {
				if linalg.distance(pts[len(pts) - 1], portal_left) > 0.01 {
					append(&pts, portal_left)
				}
				apex = portal_left
				apex_idx = left_idx
				portal_left = apex
				portal_right = apex
				left_idx = apex_idx
				right_idx = apex_idx
				pi = apex_idx + 1
				continue
			}
		}

		if _nav_triarea2_xz(apex, portal_left, left) <= 0 {
			if _nav_xz_equal(apex, portal_left) || _nav_xz_equal(apex, portal_right) || _nav_triarea2_xz(apex, portal_right, left) > 0 {
				portal_left = left
				left_idx = pi
			} else {
				if linalg.distance(pts[len(pts) - 1], portal_right) > 0.01 {
					append(&pts, portal_right)
				}
				apex = portal_right
				apex_idx = right_idx
				portal_left = apex
				portal_right = apex
				left_idx = apex_idx
				right_idx = apex_idx
				pi = apex_idx + 1
				continue
			}
		}

		pi += 1
	}

	if linalg.distance(pts[len(pts) - 1], goal_pt) > 0.01 {
		append(&pts, goal_pt)
	}
	return pts[:], true
}

// Rebuilds `nm.bounds_min`, `nm.bounds_max`, and the 2D XZ CSR lookup grid after
// polys are assembled or modified outside `navmesh_bake_triangles`.
navmesh_rebuild_spatial_grid :: proc(nm: ^NavMesh, allocator := context.allocator) {
	if nm == nil do return
	if nm.grid_offsets != nil {
		delete(nm.grid_offsets, nm.grid_alloc)
		nm.grid_offsets = nil
	}
	if nm.grid_tris != nil {
		delete(nm.grid_tris, nm.grid_alloc)
		nm.grid_tris = nil
	}
	nm.grid_w = 0
	nm.grid_h = 0
	nm.grid_inv_cell = 0

	first := true
	for &p in nm.polys {
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
	}
	if first do return
	_navmesh_build_grid(nm, allocator)
}

@(private = "file")
_Boundary_Edge :: struct {
	poly_idx: i32,
	edge_idx: i32,
	a:        [3]f32,
	b:        [3]f32,
	mid_x:    f32,
	mid_z:    f32,
}

@(private = "file")
_xz_pts_close :: #force_inline proc(a, b: [3]f32, xy_eps2, y_eps: f32) -> bool {
	dx := a.x - b.x
	dz := a.z - b.z
	return (dx * dx + dz * dz) <= xy_eps2 && abs(a.y - b.y) <= y_eps
}

// Connects unstitched boundary polygon edges (`neighbors[ei] < 0`) across jigsaw
// tile borders or small height steps within `(xy_eps, y_eps)`.
navmesh_stitch_seams :: proc(nm: ^NavMesh, xy_eps: f32 = 0.06, y_eps: f32 = 0.35) -> int {
	if nm == nil || len(nm.polys) == 0 do return 0
	xeps := max(xy_eps, f32(0.005))
	xeps2 := xeps * xeps
	yeps := max(y_eps, f32(0.01))

	edges := make([dynamic]_Boundary_Edge, 0, len(nm.polys), context.temp_allocator)
	for &p, pi in nm.polys {
		if !p.walkable do continue
		for ei in 0 ..< 3 {
			if p.neighbors[ei] >= 0 do continue
			a := p.verts[ei]
			b := p.verts[(ei + 1) % 3]
			append(&edges, _Boundary_Edge{
				poly_idx = i32(pi),
				edge_idx = i32(ei),
				a        = a,
				b        = b,
				mid_x    = (a.x + b.x) * 0.5,
				mid_z    = (a.z + b.z) * 0.5,
			})
		}
	}
	if len(edges) < 2 do return 0

	// Pass 1: spatial-hashed endpoint-to-endpoint boundary matching (exact / near-coincident seams).
	cell_sz := max(xeps * 4.0, f32(0.5))
	inv_cell := 1.0 / cell_sz
	buckets := make(map[[2]i32][dynamic]i32, len(edges), context.temp_allocator)
	for e, idx in edges {
		key := [2]i32{i32(math.floor(e.mid_x * inv_cell)), i32(math.floor(e.mid_z * inv_cell))}
		lst := buckets[key]
		if lst == nil {
			lst = make([dynamic]i32, 0, 4, context.temp_allocator)
		}
		append(&lst, i32(idx))
		buckets[key] = lst
	}

	stitched := 0
	for e0, i0 in edges {
		p0 := &nm.polys[e0.poly_idx]
		if p0.neighbors[e0.edge_idx] >= 0 do continue
		cx := i32(math.floor(e0.mid_x * inv_cell))
		cz := i32(math.floor(e0.mid_z * inv_cell))
		best_i := i32(-1)
		best_err2 := f32(1e30)
		for dz in i32(-1) ..= i32(1) {
			for dx in i32(-1) ..= i32(1) {
				cand_list, ok := buckets[[2]i32{cx + dx, cz + dz}]
				if !ok do continue
				for i1 in cand_list {
					if int(i1) == i0 do continue
					e1 := edges[i1]
					if e1.poly_idx == e0.poly_idx do continue
					if nm.polys[e1.poly_idx].neighbors[e1.edge_idx] >= 0 do continue
					match_fwd := _xz_pts_close(e0.a, e1.a, xeps2, yeps) && _xz_pts_close(e0.b, e1.b, xeps2, yeps)
					match_rev := _xz_pts_close(e0.a, e1.b, xeps2, yeps) && _xz_pts_close(e0.b, e1.a, xeps2, yeps)
					if !match_fwd && !match_rev do continue
					err2 := (e0.mid_x - e1.mid_x) * (e0.mid_x - e1.mid_x) + (e0.mid_z - e1.mid_z) * (e0.mid_z - e1.mid_z)
					if err2 < best_err2 {
						best_err2 = err2
						best_i = i1
					}
				}
			}
		}
		if best_i >= 0 {
			e1 := edges[best_i]
			p0.neighbors[e0.edge_idx] = e1.poly_idx
			nm.polys[e1.poly_idx].neighbors[e1.edge_idx] = e0.poly_idx
			stitched += 1
		}
	}

	// Pass 2: collinear overlapping seam fallback (connects unequal-length doorway edges across tiles).
	rem := make([dynamic]i32, 0, len(edges), context.temp_allocator)
	for e, idx in edges {
		if nm.polys[e.poly_idx].neighbors[e.edge_idx] < 0 {
			append(&rem, i32(idx))
		}
	}
	if len(rem) >= 2 {
		seg_cell :: f32(2.0)
		inv_seg := f32(1.0) / seg_cell
		seg_buckets := make(map[[2]i32][dynamic]i32, len(rem) * 2, context.temp_allocator)
		for ri in rem {
			e := edges[ri]
			x0 := i32(math.floor((min(e.a.x, e.b.x) - xeps) * inv_seg))
			x1 := i32(math.floor((max(e.a.x, e.b.x) + xeps) * inv_seg))
			z0 := i32(math.floor((min(e.a.z, e.b.z) - xeps) * inv_seg))
			z1 := i32(math.floor((max(e.a.z, e.b.z) + xeps) * inv_seg))
			for gz in z0 ..= z1 {
				for gx in x0 ..= x1 {
					key := [2]i32{gx, gz}
					lst := seg_buckets[key]
					if lst == nil {
						lst = make([dynamic]i32, 0, 4, context.temp_allocator)
					}
					append(&lst, ri)
					seg_buckets[key] = lst
				}
			}
		}
		for r0 in rem {
			e0 := edges[r0]
			p0 := &nm.polys[e0.poly_idx]
			if p0.neighbors[e0.edge_idx] >= 0 do continue
			d0x := e0.b.x - e0.a.x
			d0z := e0.b.z - e0.a.z
			len0 := math.sqrt(d0x * d0x + d0z * d0z)
			if len0 <= 0.05 do continue
			nx0 := d0x / len0
			nz0 := d0z / len0

			best_r1 := i32(-1)
			best_overlap := f32(0.05)
			x0 := i32(math.floor((min(e0.a.x, e0.b.x) - xeps) * inv_seg))
			x1 := i32(math.floor((max(e0.a.x, e0.b.x) + xeps) * inv_seg))
			z0 := i32(math.floor((min(e0.a.z, e0.b.z) - xeps) * inv_seg))
			z1 := i32(math.floor((max(e0.a.z, e0.b.z) + xeps) * inv_seg))
			for gz in z0 ..= z1 {
				for gx in x0 ..= x1 {
					lst, ok := seg_buckets[[2]i32{gx, gz}]
					if !ok do continue
					for r1 in lst {
						if r1 <= r0 do continue
						e1 := edges[r1]
						if e1.poly_idx == e0.poly_idx do continue
						if nm.polys[e1.poly_idx].neighbors[e1.edge_idx] >= 0 do continue

						d1x := e1.b.x - e1.a.x
						d1z := e1.b.z - e1.a.z
						len1 := math.sqrt(d1x * d1x + d1z * d1z)
						if len1 <= 0.05 do continue
						nx1 := d1x / len1
						nz1 := d1z / len1
						// Collinear check in XZ (dot near +-1 -> cross near 0)
						if abs(nx0 * nz1 - nz0 * nx1) > 0.05 do continue
						// Perpendicular distance from e1 endpoints to e0 line
						perp_a := abs((e1.a.x - e0.a.x) * (-nz0) + (e1.a.z - e0.a.z) * nx0)
						perp_b := abs((e1.b.x - e0.a.x) * (-nz0) + (e1.b.z - e0.a.z) * nx0)
						if perp_a > xeps || perp_b > xeps do continue

						t0a := f32(0.0)
						t0b := len0
						t1a := (e1.a.x - e0.a.x) * nx0 + (e1.a.z - e0.a.z) * nz0
						t1b := (e1.b.x - e0.a.x) * nx0 + (e1.b.z - e0.a.z) * nz0
						lo := max(min(t0a, t0b), min(t1a, t1b))
						hi := min(max(t0a, t0b), max(t1a, t1b))
						ov := hi - lo
						if ov <= best_overlap do continue

						mid_t := (lo + hi) * 0.5
						u0 := clamp(mid_t / len0, f32(0.0), f32(1.0))
						y0 := math.lerp(e0.a.y, e0.b.y, u0)
						denom1 := t1b - t1a
						u1 := abs(denom1) > 1e-4 ? clamp((mid_t - t1a) / denom1, f32(0.0), f32(1.0)) : f32(0.5)
						y1 := math.lerp(e1.a.y, e1.b.y, u1)
						if abs(y0 - y1) > yeps do continue

						best_overlap = ov
						best_r1 = r1
					}
				}
			}
			if best_r1 >= 0 {
				e1 := edges[best_r1]
				p0.neighbors[e0.edge_idx] = e1.poly_idx
				nm.polys[e1.poly_idx].neighbors[e1.edge_idx] = e0.poly_idx
				stitched += 1
			}
		}
	}

	if stitched > 0 {
		nm.version += 1
	}
	return stitched
}

// Immediately enables or disables walkability for every polygon intersecting a world
// sphere (e.g. a freshly detonated crater/quarantine zone at frame T0). Bumps `nm.version`.
navmesh_set_sphere_walkable :: proc(nm: ^NavMesh, center: [3]f32, radius: f32, walkable: bool) -> int {
	if nm == nil || len(nm.polys) == 0 || radius <= 0 do return 0
	r2 := radius * radius
	changed := 0
	for &p in nm.polys {
		if p.walkable == walkable do continue
		cp := _closest_point_on_triangle(center, p.verts[0], p.verts[1], p.verts[2])
		if linalg.length2(cp - center) <= r2 {
			p.walkable = walkable
			changed += 1
		}
	}
	if changed > 0 {
		nm.version += 1
	}
	return changed
}
