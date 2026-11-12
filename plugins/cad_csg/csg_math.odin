package cad_csg

// Mathematical Core for CAD Blockout & Red Faction (Geo-Mod) Destructible CSG.
//
// DESIGN PRINCIPLES (Data-Oriented & Numerically Robust in IEEE-754 f32):
// 1. Half-Space Convex Representation:
//    Every solid volume is represented as a union of convex polyhedra (`CSG_Convex`),
//    where each convex polyhedron is the intersection of half-space planes:
//        P = { x in R^3 | dot(n_i, x) <= d_i  for all i }
// 2. Zero Non-Manifold Degeneracy:
//    Boolean subtraction (`convex_subtract`) uses sequential half-space plane splitting
//    (Sutherland-Hodgman polygon clipping) with plane quantization and redundant-plane
//    pruning. Every surviving piece is guaranteed by convexity to be a closed,
//    watertight convex polyhedron — never producing open holes or T-junctions.
// 3. Direct JoltC Compatibility:
//    Each surviving `CSG_Convex` directly yields its extreme vertices for lock-free
//    off-thread `jolt.ConvexHullShapeSettings_Create` cooking or chunked `MeshShape`
//    with `FavorBuildSpeed`.

import "core:math"
import "core:math/linalg"
import gfx "moonhug:engine/gfx"
import engine "moonhug:engine"

// Quantization epsilon for plane distances (~0.5 mm) and polygon clipping
CSG_PLANE_EPS           :: f32(1e-4)
CSG_AREA_EPS            :: f32(1e-6)
CSG_WELD_EPS_SQ         :: f32(1e-6)
CSG_BASE_EXTENT         :: f32(2048.0)
CSG_MAX_PLANES_PER_HULL :: 256

Brush_Op :: enum u8 {
	Add      = 0,
	Subtract = 1,
}

Brush_Primitive :: enum u8 {
	Box        = 0, // 6-plane rectangular prism
	Wedge      = 1, // 5-plane angled ramp / stairs slope
	Prism_6    = 2, // 8-plane hexagonal column / corridor
	Prism_8    = 3, // 10-plane octagonal pillar / tunnel
	Cylinder   = 4, // 14-plane 12-sided cylinder
	Bevel_Box  = 5, // 10-plane UT2003 sci-fi beveled block
	Profile_2D = 6, // Extruded 2D CAD Polyline / Catmull-Rom Spline profile (sharp + smooth vertices)
}

// One 2D control point on a WorkPlane for `Brush_Primitive.Profile_2D`.
CSG_Profile_Point :: struct {
	uv:      [2]f32, // 2D coordinates (U, V) in meters on the brush's sketch plane
	smooth:  bool,   // false = Sharp CAD Corner, true = Smooth Catmull-Rom Spline Curve
	tension: f32,    // Curve tension (0.0 = standard Catmull-Rom, 0.5 = tighter spline)
}

// Half-space plane: dot(normal, x) <= dist
CSG_Plane :: struct {
	normal:        [3]f32,
	dist:          f32,
	mat_slot:      u8,     // 0 = Exterior brush material, 1 = Blasted crater / interior material
	uv_scale:      f32,    // Metric UV tiling factor (default 0.5 -> 1 tile per 2 meters)
	uv_offset:     [2]f32, // Tangent-space UV offset (U, V) (RealtimeCSG TexGen)
	uv_rot_deg:    f32,    // Tangent-space UV rotation in degrees (RealtimeCSG TexGen)
	uv_lock_brush: bool,   // false = World-Locked seamless tiling; true = Brush/Hull-centroid locked
	color:         [4]u8,  // Per-face vertex tint (crater faces darken/scorch automatically)
}

// A single watertight convex polyhedron defined by the intersection of `planes`.
CSG_Convex :: struct {
	planes:   [dynamic]CSG_Plane,
	aabb_min: [3]f32,
	aabb_max: [3]f32,
	centroid: [3]f32,
	volume:   f32,
	anchored: bool, // True if this hull is anchored to the world/floor (cannot collapse as floating island)
	brush_id: u32,
}

// Extracted planar N-gon face of a `CSG_Convex`.
CSG_Face_Poly :: struct {
	plane_idx:     int,
	hull_idx:      int,
	normal:        [3]f32,
	mat_slot:      u8,
	uv_scale:      f32,
	uv_offset:     [2]f32,
	uv_rot_deg:    f32,
	uv_lock_brush: bool,
	color:         [4]u8,
	verts:         [dynamic][3]f32,
}

convex_destroy :: proc(c: ^CSG_Convex) {
	if c.planes != nil {
		delete(c.planes)
		c.planes = nil
	}
}

convex_clone :: proc(src: CSG_Convex, alloc := context.allocator) -> CSG_Convex {
	dst := src
	dst.planes = make([dynamic]CSG_Plane, len(src.planes), alloc)
	copy(dst.planes[:], src.planes[:])
	return dst
}

aabb_overlaps :: #force_inline proc(min_a, max_a, min_b, max_b: [3]f32, eps: f32 = 1e-4) -> bool {
	return (min_a.x <= max_b.x + eps && max_a.x >= min_b.x - eps) &&
	       (min_a.y <= max_b.y + eps && max_a.y >= min_b.y - eps) &&
	       (min_a.z <= max_b.z + eps && max_a.z >= min_b.z - eps)
}

// Quantizes a plane's normal and distance slightly so coplanar CAD brush faces match cleanly.
quantize_plane :: proc(p: CSG_Plane) -> CSG_Plane {
	out := p
	n := linalg.normalize0(out.normal)
	is_cardinal := false
	// Snap near-cardinal normals to exact cardinal axes
	if abs(n.x) > 0.99999 { n = {math.sign(n.x), 0, 0}; is_cardinal = true }
	if abs(n.y) > 0.99999 { n = {0, math.sign(n.y), 0}; is_cardinal = true }
	if abs(n.z) > 0.99999 { n = {0, 0, math.sign(n.z)}; is_cardinal = true }
	out.normal = n
	// Only snap distance to 1/2048 meter (~0.48mm) on axis-aligned cardinal planes!
	// On curved / spherical / angled polyhedra where 4..16 planes meet at a single vertex,
	// independent rounding of `dist` by +-0.24mm (> CSG_PLANE_EPS) breaks vertex incidence
	// and chamfers/busts sphere, cone, and cylinder edges.
	if is_cardinal {
		out.dist = math.round(out.dist * 2048.0) / 2048.0
	}
	return out
}

// Builds an orthonormal tangent basis (u_axis, v_axis) on a plane with normal `n`
// such that `cross(u_axis, v_axis) == n` (counter-clockwise winding when viewed from +n).
plane_tangent_basis :: proc(n: [3]f32) -> (u_axis, v_axis: [3]f32) {
	// Pick a world reference up vector that isn't parallel to `n`
	up := [3]f32{0, 1, 0}
	if abs(n.y) > 0.92 {
		up = {0, 0, 1}
	}
	u_axis = linalg.normalize0(linalg.cross(up, n))
	v_axis = linalg.normalize0(linalg.cross(n, u_axis))
	return
}

// Clips a convex polygon `poly_in` against half-space `dot(plane.normal, x) <= plane.dist`.
clip_polygon_by_plane :: proc(poly_in: [][3]f32, plane: CSG_Plane, poly_out: ^[dynamic][3]f32) {
	clear(poly_out)
	n := len(poly_in)
	if n < 3 do return

	// Signed distance: positive = outside half-space, <= 0 = inside half-space
	prev := poly_in[n - 1]
	prev_d := linalg.dot(plane.normal, prev) - plane.dist
	prev_in := prev_d <= CSG_PLANE_EPS

	for i in 0 ..< n {
		curr := poly_in[i]
		curr_d := linalg.dot(plane.normal, curr) - plane.dist
		curr_in := curr_d <= CSG_PLANE_EPS

		if curr_in {
			if !prev_in {
				denom := prev_d - curr_d
				t := clamp(prev_d / denom, 0.0, 1.0) if abs(denom) > 1e-8 else 0.5
				ipt := linalg.lerp(prev, curr, t)
				ipt -= plane.normal * (linalg.dot(plane.normal, ipt) - plane.dist)
				append(poly_out, ipt)
			}
			append(poly_out, curr)
		} else if prev_in {
			denom := prev_d - curr_d
			t := clamp(prev_d / denom, 0.0, 1.0) if abs(denom) > 1e-8 else 0.5
			ipt := linalg.lerp(prev, curr, t)
			ipt -= plane.normal * (linalg.dot(plane.normal, ipt) - plane.dist)
			append(poly_out, ipt)
		}

		prev = curr
		prev_d = curr_d
		prev_in = curr_in
	}
}

// Computes the area of a 3D planar convex polygon.
polygon_area :: proc(verts: [][3]f32) -> f32 {
	if len(verts) < 3 do return 0
	p0 := verts[0]
	sum := [3]f32{0, 0, 0}
	for i in 1 ..< len(verts) - 1 {
		sum += linalg.cross(verts[i] - p0, verts[i + 1] - p0)
	}
	return 0.5 * linalg.length(sum)
}

// Collapses microscopic sliver edges (< 1.5mm) created when 4..16 planes meet at a single vertex
// (such as UV sphere quad corners and polar caps) so extracted polygon faces never have busted micro-chamfers.
@(private = "file")
_weld_clipped_poly_micro_edges :: proc(poly: ^[dynamic][3]f32) {
	if len(poly) < 3 do return
	MICRO_EDGE_EPS_SQ :: f32(2.25e-6) // (1.5mm)^2
	i := 0
	for i < len(poly) && len(poly) >= 3 {
		next := (i + 1) % len(poly)
		if linalg.length2(poly[next] - poly[i]) <= MICRO_EDGE_EPS_SQ {
			poly[i] = (poly[i] + poly[next]) * 0.5
			ordered_remove(poly, next)
		} else {
			i += 1
		}
	}
}

// Extracts all non-degenerate polygon faces of `hull`, updates `hull.aabb_min`,
// `hull.aabb_max`, `hull.centroid`, and `hull.volume`, and optionally prunes
// redundant half-space planes that contribute no face.
convex_rebuild_bounds_and_prune :: proc(hull: ^CSG_Convex, prune_redundant := true, min_extent: f32 = 0.015) -> bool {
	if len(hull.planes) < 4 do return false

	// Deduplicate nearly-identical planes first (keep tightest dist)
	for i := 0; i < len(hull.planes); i += 1 {
		pi := hull.planes[i]
		for j := i + 1; j < len(hull.planes); {
			pj := hull.planes[j]
			if linalg.dot(pi.normal, pj.normal) > 0.9998 {
				if pj.dist < pi.dist {
					hull.planes[i] = pj
					pi = pj
				}
				ordered_remove(&hull.planes, j)
			} else {
				j += 1
			}
		}
	}
	if len(hull.planes) < 4 do return false

	buf_a := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	buf_b := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	plane_active := make([]bool, len(hull.planes), context.temp_allocator)

	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{-max(f32), -max(f32), -max(f32)}
	vert_sum := [3]f32{0, 0, 0}
	vert_count := 0
	valid_faces := 0

	for p_idx in 0 ..< len(hull.planes) {
		p := hull.planes[p_idx]
		u_ax, v_ax := plane_tangent_basis(p.normal)
		origin := p.normal * p.dist

		// Start with a giant quad on plane `p_idx`
		clear(&buf_a)
		append(&buf_a, origin - u_ax * CSG_BASE_EXTENT - v_ax * CSG_BASE_EXTENT)
		append(&buf_a, origin + u_ax * CSG_BASE_EXTENT - v_ax * CSG_BASE_EXTENT)
		append(&buf_a, origin + u_ax * CSG_BASE_EXTENT + v_ax * CSG_BASE_EXTENT)
		append(&buf_a, origin - u_ax * CSG_BASE_EXTENT + v_ax * CSG_BASE_EXTENT)

		for other_idx in 0 ..< len(hull.planes) {
			if other_idx == p_idx do continue
			clip_polygon_by_plane(buf_a[:], hull.planes[other_idx], &buf_b)
			buf_a, buf_b = buf_b, buf_a
			if len(buf_a) < 3 do break
		}

		_weld_clipped_poly_micro_edges(&buf_a)

		if len(buf_a) >= 3 && polygon_area(buf_a[:]) > CSG_AREA_EPS {
			plane_active[p_idx] = true
			valid_faces += 1
			for v in buf_a {
				lo.x = min(lo.x, v.x)
				lo.y = min(lo.y, v.y)
				lo.z = min(lo.z, v.z)
				hi.x = max(hi.x, v.x)
				hi.y = max(hi.y, v.y)
				hi.z = max(hi.z, v.z)
				vert_sum += v
				vert_count += 1
			}
		}
	}

	if valid_faces < 4 || vert_count < 4 do return false
	ext := hi - lo
	if ext.x < min_extent || ext.y < min_extent || ext.z < min_extent do return false

	if prune_redundant || len(hull.planes) > CSG_MAX_PLANES_PER_HULL {
		w_idx := 0
		for r_idx in 0 ..< len(hull.planes) {
			if plane_active[r_idx] && w_idx < CSG_MAX_PLANES_PER_HULL {
				hull.planes[w_idx] = hull.planes[r_idx]
				w_idx += 1
			}
		}
		resize(&hull.planes, w_idx)
		if len(hull.planes) < 4 do return false
	}

	hull.aabb_min = lo
	hull.aabb_max = hi
	hull.centroid = vert_sum / f32(vert_count)
	hull.volume = ext.x * ext.y * ext.z * 0.5
	return true
}

// Extracts the clipped polygon faces of `hull` into `out_faces` (allocated on `alloc`).
convex_extract_faces :: proc(hull: CSG_Convex, out_faces: ^[dynamic]CSG_Face_Poly, alloc := context.temp_allocator, hull_idx: int = 0) {
	buf_a := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	buf_b := make([dynamic][3]f32, 0, 32, context.temp_allocator)

	for p_idx in 0 ..< len(hull.planes) {
		p := hull.planes[p_idx]
		u_ax, v_ax := plane_tangent_basis(p.normal)
		origin := p.normal * p.dist

		clear(&buf_a)
		append(&buf_a, origin - u_ax * CSG_BASE_EXTENT - v_ax * CSG_BASE_EXTENT)
		append(&buf_a, origin + u_ax * CSG_BASE_EXTENT - v_ax * CSG_BASE_EXTENT)
		append(&buf_a, origin + u_ax * CSG_BASE_EXTENT + v_ax * CSG_BASE_EXTENT)
		append(&buf_a, origin - u_ax * CSG_BASE_EXTENT + v_ax * CSG_BASE_EXTENT)

		for other_idx in 0 ..< len(hull.planes) {
			if other_idx == p_idx do continue
			clip_polygon_by_plane(buf_a[:], hull.planes[other_idx], &buf_b)
			buf_a, buf_b = buf_b, buf_a
			if len(buf_a) < 3 do break
		}

		_weld_clipped_poly_micro_edges(&buf_a)

		if len(buf_a) >= 3 && polygon_area(buf_a[:]) > CSG_AREA_EPS {
			verts := make([dynamic][3]f32, len(buf_a), alloc)
			copy(verts[:], buf_a[:])
			append(out_faces, CSG_Face_Poly{
				plane_idx     = p_idx,
				hull_idx      = hull_idx,
				normal        = p.normal,
				mat_slot      = p.mat_slot,
				uv_scale      = p.uv_scale,
				uv_offset     = p.uv_offset,
				uv_rot_deg    = p.uv_rot_deg,
				uv_lock_brush = p.uv_lock_brush,
				color         = p.color,
				verts         = verts,
			})
		}
	}
}

// Extracts deduplicated extreme vertices of `hull` (for JoltC `ConvexHullShapeSettings_Create`
// and Separating Axis Theorem tests).
convex_extract_vertices :: proc(hull: CSG_Convex, out_verts: ^[dynamic][3]f32) {
	clear(out_verts)
	faces := make([dynamic]CSG_Face_Poly, 0, len(hull.planes), context.temp_allocator)
	convex_extract_faces(hull, &faces, context.temp_allocator)
	for f in faces {
		for v in f.verts {
			found := false
			for existing in out_verts {
				if linalg.length2(v - existing) < CSG_WELD_EPS_SQ {
					found = true
					break
				}
			}
			if !found {
				append(out_verts, v)
			}
		}
	}
}

// Tests whether two convex polyhedra actually overlap in 3D space using Half-Space / SAT check.
convex_intersects :: proc(a, b: CSG_Convex) -> bool {
	if !aabb_overlaps(a.aabb_min, a.aabb_max, b.aabb_min, b.aabb_max, -1e-4) {
		return false
	}
	verts_a := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	convex_extract_vertices(a, &verts_a)
	if len(verts_a) == 0 do return false

	// If all vertices of `a` lie on or outside a single plane of `b`, they do not intersect!
	for pb in b.planes {
		all_outside := true
		for v in verts_a {
			if linalg.dot(pb.normal, v) - pb.dist < -CSG_PLANE_EPS * 4.0 {
				all_outside = false
				break
			}
		}
		if all_outside do return false
	}

	verts_b := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	convex_extract_vertices(b, &verts_b)
	if len(verts_b) == 0 do return false

	for pa in a.planes {
		all_outside := true
		for v in verts_b {
			if linalg.dot(pa.normal, v) - pa.dist < -CSG_PLANE_EPS * 4.0 {
				all_outside = false
				break
			}
		}
		if all_outside do return false
	}
	return true
}

// Watertight Boolean Subtraction: `subject \ cutter`.
// Appends surviving convex polyhedra to `out_pieces` (allocated with `alloc`).
// Consumes `subject` (frees its planes if split or eaten; transfers ownership if untouched).
//
// Uses two key C# RealtimeCSG / Chisel & SabreCSG runtime CSG techniques:
// 1. Exact Half-Space Intersection Pre-Filter (`inter = subject ∩ cutter`):
//    Tests if the combined half-space polyhedron has >= 3mm 3D thickness before splitting.
//    Eliminates false-positive SAT splits and prevents grazing blasts from slicing untouched hulls into planks.
// 2. Best-Plane-First Splitting Order (Largest Outside Clearance First):
//    Orders cutter planes by descending `max_d` on `subject` so the largest intact surrounding blocks
//    are detached first as single clean hulls instead of slicing long fence-plank strips across the chunk.
convex_subtract :: proc(subject: CSG_Convex, cutter: CSG_Convex, out_pieces: ^[dynamic]CSG_Convex, alloc := context.allocator, min_piece_extent: f32 = 0.003) {
	if !aabb_overlaps(subject.aabb_min, subject.aabb_max, cutter.aabb_min, cutter.aabb_max, -0.002) {
		append(out_pieces, subject)
		return
	}

	// 1. Exact 3D Half-Space Intersection Pre-Check (`inter = subject ∩ cutter`)
	inter := CSG_Convex{
		planes = make([dynamic]CSG_Plane, 0, len(subject.planes) + len(cutter.planes), context.temp_allocator),
	}
	append(&inter.planes, ..subject.planes[:])
	append(&inter.planes, ..cutter.planes[:])
	if !convex_rebuild_bounds_and_prune(&inter, prune_redundant = true, min_extent = 0.003) {
		append(out_pieces, subject)
		return
	}

	subj_verts := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	convex_extract_vertices(subject, &subj_verts)
	if len(subj_verts) < 4 {
		append(out_pieces, subject)
		return
	}

	// Check if `subject` is completely contained inside `cutter`
	all_inside_cutter := true
	for v in subj_verts {
		for cp in cutter.planes {
			if linalg.dot(cp.normal, v) - cp.dist > 0.003 {
				all_inside_cutter = false
				break
			}
		}
		if !all_inside_cutter do break
	}
	if all_inside_cutter {
		subj_mut := subject
		convex_destroy(&subj_mut)
		return
	}

	// 2. Order cutter planes by descending `max_d` on `subject` (Largest Outside Volume First!)
	Plane_Order :: struct {
		idx:   int,
		max_d: f32,
	}
	order := make([dynamic]Plane_Order, 0, len(cutter.planes), context.temp_allocator)
	for cp, idx in cutter.planes {
		max_d := -max(f32)
		for v in subj_verts {
			d := linalg.dot(cp.normal, v) - cp.dist
			if d > max_d do max_d = d
		}
		// Only planes where `subject` actually protrudes outside (`max_d > 2mm`) can emit an outside piece
		if max_d > 0.002 {
			append(&order, Plane_Order{idx = idx, max_d = max_d})
		}
	}
	// Insertion sort descending by `max_d`
	for i in 1 ..< len(order) {
		key := order[i]
		j := i - 1
		for j >= 0 && order[j].max_d < key.max_d {
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key
	}

	initial_out_len := len(out_pieces)
	work := convex_clone(subject, alloc)
	work_alive := true
	work_verts := make([dynamic][3]f32, 0, 32, context.temp_allocator)

	for po in order {
		if !work_alive do break
		cp := cutter.planes[po.idx]

		convex_extract_vertices(work, &work_verts)
		if len(work_verts) < 4 {
			convex_destroy(&work)
			work_alive = false
			break
		}

		min_d := max(f32)
		max_d := -max(f32)
		for v in work_verts {
			d := linalg.dot(cp.normal, v) - cp.dist
			min_d = min(min_d, d)
			max_d = max(max_d, d)
		}

		// If `work` is already completely inside `cp` (no protrusion > 2mm), this plane doesn't slice `work`
		if max_d <= 0.002 {
			continue
		}

		// If `work` lies completely outside `cp`, then the remaining `work` is outside `cutter` -> keep it!
		if min_d >= -CSG_PLANE_EPS * 2.0 {
			append(out_pieces, work)
			work_alive = false
			break
		}

		// `work` straddles `cp` -> emit the outside fragment (`dot(cp.normal, x) >= cp.dist`)
		// using a 3mm minimum extent so thin surface caps next to small 0.25m craters are preserved!
		outside_hull := convex_clone(work, alloc)
		cut_plane := quantize_plane(CSG_Plane{
			normal   = -cp.normal,
			dist     = -cp.dist,
			mat_slot = cp.mat_slot,
			uv_scale = cp.uv_scale,
			color    = cp.color,
		})
		append(&outside_hull.planes, cut_plane)
		if convex_rebuild_bounds_and_prune(&outside_hull, prune_redundant = true, min_extent = min_piece_extent) {
			append(out_pieces, outside_hull)
		} else {
			convex_destroy(&outside_hull)
		}

		// Clip `work` to the inside of `cp` using a tiny 0.2mm intermediate extent threshold
		// so `work` NEVER dies prematurely mid-loop before all remaining planes emit their outside pieces!
		// Mark `inside_plane.mat_slot = 0` because `inside_plane` is the internal partition seam between `work`
		// and `outside_hull` (whereas `cut_plane` on `outside_hull` is the true exposed crater wall with `mat_slot = 1`).
		inside_plane := quantize_plane(cp)
		inside_plane.mat_slot = 0
		append(&work.planes, inside_plane)
		if !convex_rebuild_bounds_and_prune(&work, prune_redundant = true, min_extent = 0.0002) {
			convex_destroy(&work)
			work_alive = false
		}
	}

	// Anything remaining in `work` after all cutter planes is strictly inside `cutter` (carved away!)
	if work_alive {
		convex_destroy(&work)
	}

	// Safety net: only preserve `subject` if a grazing micro-blast hit a large hull whose centroid is strictly
	// outside `cutter`. If `subject`'s centroid is inside `cutter` (or `subject` is already a small interior shard
	// whose thin outside slivers fell below `min_piece_extent`), vaporize `subject` so blasts never "resurrect"
	// interior fragments when tunneling through a mesh!
	if len(out_pieces) == initial_out_len {
		ext_s := subject.aabb_max - subject.aabb_min
		max_s := max(ext_s.x, max(ext_s.y, ext_s.z))
		if max_s > 0.45 && !_point_inside_convex(subject.centroid, cutter, 0.02) {
			append(out_pieces, subject)
		} else {
			subj_mut := subject
			convex_destroy(&subj_mut)
		}
	} else {
		subj_mut := subject
		convex_destroy(&subj_mut)
	}
}

CSG_MAX_HULLS_PER_CHUNK :: 192

@(private = "file")
_point_inside_convex :: #force_inline proc(pt: [3]f32, c: CSG_Convex, eps: f32 = 0.01) -> bool {
	for p in c.planes {
		if linalg.dot(p.normal, pt) - p.dist > eps do return false
	}
	return true
}

// Subtract `cutter` from an entire list of convex polyhedra `hulls`.
// Never skips overlapping hulls when spamming blasts in the same chunk: instead, when a chunk is already
// heavily fractured, small pre-fractured shards whose centroid lies inside the blast are vaporized cleanly
// and micro-sliver emission threshold scales up slightly so repeated blasts can chew all the way through any chunk!
convex_list_subtract :: proc(hulls: ^[dynamic]CSG_Convex, cutter: CSG_Convex, alloc := context.allocator, max_hulls: int = CSG_MAX_HULLS_PER_CHUNK) {
	if len(hulls) == 0 do return
	next_hulls := make([dynamic]CSG_Convex, 0, min(len(hulls) + 16, max_hulls + 32), alloc)

	crowded := len(hulls^) >= 48
	for &h in hulls^ {
		// Fast path: hulls that do not overlap `cutter` pass straight through untouched
		if !aabb_overlaps(h.aabb_min, h.aabb_max, cutter.aabb_min, cutter.aabb_max, -0.001) {
			append(&next_hulls, h)
			continue
		}

		// Vaporize small pre-fractured shards whose centroid is inside the blast polyhedron instead of splitting them into 14 micro-slivers!
		ext := h.aabb_max - h.aabb_min
		max_dim := max(ext.x, max(ext.y, ext.z))
		if max_dim < 0.35 && _point_inside_convex(h.centroid, cutter, 0.04) {
			convex_destroy(&h)
			continue
		}
		if (crowded || len(next_hulls) >= max_hulls / 2) && max_dim < 0.65 && _point_inside_convex(h.centroid, cutter, 0.04) {
			convex_destroy(&h)
			continue
		}
		if len(next_hulls) >= max_hulls && max_dim < 1.25 {
			// Extreme saturation fallback: shatter/vaporize small overlapping fragment so blasts ALWAYS keep carving!
			convex_destroy(&h)
			continue
		}

		min_ext: f32 = 0.022 if (crowded || len(next_hulls) >= 96) else 0.004
		convex_subtract(h, cutter, &next_hulls, alloc, min_ext)
	}
	delete(hulls^)
	hulls^ = next_hulls
}

// Slices a single convex polyhedron across an axis-aligned plane `x[axis] = split_val`.
@(private = "file")
_split_convex_along_axis :: proc(
	h:         CSG_Convex,
	axis:      int,
	split_val: f32,
	out_list:  ^[dynamic]CSG_Convex,
	alloc := context.allocator,
) {
	if h.aabb_max[axis] <= split_val + 0.05 || h.aabb_min[axis] >= split_val - 0.05 {
		append(out_list, h)
		return
	}
	n_pos := [3]f32{0, 0, 0}
	n_neg := [3]f32{0, 0, 0}
	n_pos[axis] = +1.0
	n_neg[axis] = -1.0

	ref_col := [4]u8{200, 206, 214, 255}
	ref_uv: f32 = 0.5
	ref_slot: u8 = 0
	if len(h.planes) > 0 {
		ref_col  = h.planes[0].color
		ref_uv   = h.planes[0].uv_scale
		ref_slot = h.planes[0].mat_slot
	}

	// Lower half: x[axis] <= split_val -> normal = +axis, dist = split_val
	lo_hull := convex_clone(h, alloc)
	append(&lo_hull.planes, CSG_Plane{normal = n_pos, dist = split_val, mat_slot = ref_slot, uv_scale = ref_uv, color = ref_col})
	if convex_rebuild_bounds_and_prune(&lo_hull, prune_redundant = true) {
		append(out_list, lo_hull)
	} else {
		convex_destroy(&lo_hull)
	}

	// Upper half: x[axis] >= split_val -> normal = -axis, dist = -split_val
	hi_hull := h
	append(&hi_hull.planes, CSG_Plane{normal = n_neg, dist = -split_val, mat_slot = ref_slot, uv_scale = ref_uv, color = ref_col})
	if convex_rebuild_bounds_and_prune(&hi_hull, prune_redundant = true) {
		append(out_list, hi_hull)
	} else {
		convex_destroy(&hi_hull)
	}
}

// Subdivides any large convex polyhedron along `chunk_size` spatial grid boundaries (X, Y, Z)
// so a massive brush (e.g. 40m x 40m floor or wall) is partitioned cleanly into 8m^3 chunks.
csg_subdivide_hulls_by_grid :: proc(hulls: ^[dynamic]CSG_Convex, chunk_size: f32, alloc := context.allocator) {
	if len(hulls) == 0 || chunk_size < 2.0 do return
	inv_c := 1.0 / chunk_size

	for axis in 0 ..< 3 {
		next_list := make([dynamic]CSG_Convex, 0, len(hulls^) * 2, alloc)
		for h in hulls^ {
			span := h.aabb_max[axis] - h.aabb_min[axis]
			if span <= chunk_size * 1.25 || len(next_list) >= 128 {
				append(&next_list, h)
				continue
			}
			first_grid := int(math.floor(h.aabb_min[axis] * inv_c)) + 1
			last_grid  := int(math.floor(h.aabb_max[axis] * inv_c))
			// Cap grid splits per axis to 8 so even a 1000m brush stays fast and bounded
			if last_grid - first_grid > 8 {
				step := max((last_grid - first_grid) / 8, 1)
				work_list := make([dynamic]CSG_Convex, 1, alloc)
				work_list[0] = h
				for g := first_grid; g <= last_grid; g += step {
					split_val := f32(g) * chunk_size
					tmp := make([dynamic]CSG_Convex, 0, len(work_list) + 2, alloc)
					for wh in work_list {
						_split_convex_along_axis(wh, axis, split_val, &tmp, alloc)
					}
					delete(work_list)
					work_list = tmp
				}
				for wh in work_list do append(&next_list, wh)
				delete(work_list)
			} else {
				work_list := make([dynamic]CSG_Convex, 1, alloc)
				work_list[0] = h
				for g in first_grid ..= last_grid {
					split_val := f32(g) * chunk_size
					tmp := make([dynamic]CSG_Convex, 0, len(work_list) + 2, alloc)
					for wh in work_list {
						_split_convex_along_axis(wh, axis, split_val, &tmp, alloc)
					}
					delete(work_list)
					work_list = tmp
				}
				for wh in work_list do append(&next_list, wh)
				delete(work_list)
			}
		}
		delete(hulls^)
		hulls^ = next_list
	}
}

// ============================================================================
// PRIMITIVE CONVEX POLYHEDRON BUILDERS (UT2003 / AutoCAD Blockout Primitives)
// ============================================================================

@(private = "file")
_rotate_y :: #force_inline proc(v: [3]f32, cos_y, sin_y: f32) -> [3]f32 {
	return {
		v.x * cos_y + v.z * sin_y,
		v.y,
		-v.x * sin_y + v.z * cos_y,
	}
}

@(private = "file")
_add_local_plane :: proc(hull: ^CSG_Convex, center: [3]f32, cos_y, sin_y: f32, local_n: [3]f32, local_d: f32, mat_slot: u8, uv_scale: f32, color: [4]u8) {
	wn := linalg.normalize0(_rotate_y(local_n, cos_y, sin_y))
	wd := local_d + linalg.dot(wn, center)
	append(&hull.planes, quantize_plane(CSG_Plane{
		normal   = wn,
		dist     = wd,
		mat_slot = mat_slot,
		uv_scale = uv_scale,
		color    = color,
	}))
}

csg_make_primitive_convex :: proc(
	prim:      Brush_Primitive,
	center:    [3]f32,
	size:      [3]f32,
	yaw_deg:   f32 = 0,
	color:     [4]u8 = {215, 220, 228, 255},
	uv_scale:  f32 = 0.5,
	mat_slot:  u8 = 0,
	anchored:  bool = false,
	brush_id:  u32 = 0,
	alloc := context.allocator,
) -> (hull: CSG_Convex, ok: bool) {
	hx := max(size.x * 0.5, 0.025)
	hy := max(size.y * 0.5, 0.025)
	hz := max(size.z * 0.5, 0.025)
	rad := math.to_radians(yaw_deg)
	cos_y := math.cos(rad)
	sin_y := math.sin(rad)

	hull.planes = make([dynamic]CSG_Plane, 0, 16, alloc)
	hull.anchored = anchored
	hull.brush_id = brush_id

	#partial switch prim {
	case .Box:
		_add_local_plane(&hull, center, cos_y, sin_y, {+1,  0,  0}, hx, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {-1,  0,  0}, hx, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0, +1,  0}, hy, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0, -1,  0}, hy, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0,  0, +1}, hz, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0,  0, -1}, hz, mat_slot, uv_scale, color)

	case .Wedge:
		// 5-plane right-angled ramp: rises from (-hz, -hy) up to (+hz, +hy)
		_add_local_plane(&hull, center, cos_y, sin_y, {+1,  0,  0}, hx, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {-1,  0,  0}, hx, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0, -1,  0}, hy, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0,  0, +1}, hz, mat_slot, uv_scale, color)
		// Slope plane passing through (0, -hy, -hz) and (0, +hy, +hz) with outward normal (0, +hz, -hy)
		slope_n := linalg.normalize0([3]f32{0, hz, -hy})
		_add_local_plane(&hull, center, cos_y, sin_y, slope_n, 0.0, mat_slot, uv_scale, color)

	case .Prism_6, .Prism_8, .Cylinder:
		sides := 6
		if prim == .Prism_8 do sides = 8
		if prim == .Cylinder do sides = 12
		_add_local_plane(&hull, center, cos_y, sin_y, {0, +1, 0}, hy, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {0, -1, 0}, hy, mat_slot, uv_scale, color)
		for i in 0 ..< sides {
			ang := (f32(i) + 0.5) * (2.0 * math.PI / f32(sides))
			ca := math.cos(ang)
			sa := math.sin(ang)
			// Elliptical support distance for radii (hx, hz)
			n_local := linalg.normalize0([3]f32{ca / hx, 0, sa / hz})
			pt_local := [3]f32{ca * hx, 0, sa * hz}
			d_local := linalg.dot(n_local, pt_local)
			_add_local_plane(&hull, center, cos_y, sin_y, n_local, d_local, mat_slot, uv_scale, color)
		}

	case .Bevel_Box:
		// 6 box planes + 4 vertical 45-degree corner bevels (classic UT2003 sci-fi trim pillar/wall)
		_add_local_plane(&hull, center, cos_y, sin_y, {+1,  0,  0}, hx, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {-1,  0,  0}, hx, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0, +1,  0}, hy, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0, -1,  0}, hy, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0,  0, +1}, hz, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, { 0,  0, -1}, hz, mat_slot, uv_scale, color)
		inv_sqrt2 :: f32(0.70710678)
		bevel_d := (hx + hz) * inv_sqrt2 * 0.86
		_add_local_plane(&hull, center, cos_y, sin_y, {+inv_sqrt2, 0, +inv_sqrt2}, bevel_d, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {-inv_sqrt2, 0, +inv_sqrt2}, bevel_d, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {+inv_sqrt2, 0, -inv_sqrt2}, bevel_d, mat_slot, uv_scale, color)
		_add_local_plane(&hull, center, cos_y, sin_y, {-inv_sqrt2, 0, -inv_sqrt2}, bevel_d, mat_slot, uv_scale, color)
	}

	if !convex_rebuild_bounds_and_prune(&hull, prune_redundant = false) {
		convex_destroy(&hull)
		return {}, false
	}
	return hull, true
}

// Builds a 14-plane faceted "Red Faction Geo-Mod Blast Polyhedron" (truncated octahedron
// with deterministic seed-based plane jitter) so runtime explosions carve chunky, jagged
// rock craters with `mat_slot = 1` and scorched vertex coloring.
csg_make_blast_convex :: proc(
	center:     [3]f32,
	radius:     f32,
	seed:       u32 = 1,
	jaggedness: f32 = 0.14,
	scorch_col: [4]u8 = {92, 84, 78, 255},
	alloc      := context.allocator,
	mat_slot:   u8 = 1,
) -> (hull: CSG_Convex, ok: bool) {
	r := max(radius, 0.06)
	hull.planes = make([dynamic]CSG_Plane, 0, 14, alloc)

	// 6 axial directions + 8 octahedral diagonal directions = 14 facets
	s3 :: f32(0.57735027)
	base_dirs := [14][3]f32{
		{+1,  0,  0}, {-1,  0,  0},
		{ 0, +1,  0}, { 0, -1,  0},
		{ 0,  0, +1}, { 0,  0, -1},
		{+s3, +s3, +s3}, {-s3, +s3, +s3},
		{+s3, -s3, +s3}, {-s3, -s3, +s3},
		{+s3, +s3, -s3}, {-s3, +s3, -s3},
		{+s3, -s3, -s3}, {-s3, -s3, -s3},
	}

	// Clamp normal & radial distance perturbation so small-radius blasts (e.g. 0.25m)
	// with max jaggedness slider stay well-formed centered convex polyhedra and never collapse!
	eff_jag := clamp(jaggedness, 0.0, 0.35) * 0.60
	rad_jag := eff_jag * 0.40

	state := seed * 747796405 + 2891336453
	for d, idx in base_dirs {
		state = state * 747796405 + 2891336453
		rx := (f32(state & 0xFFFF) / 32768.0 - 1.0) * eff_jag
		state = state * 747796405 + 2891336453
		ry := (f32(state & 0xFFFF) / 32768.0 - 1.0) * eff_jag
		state = state * 747796405 + 2891336453
		rz := (f32(state & 0xFFFF) / 32768.0 - 1.0) * eff_jag
		state = state * 747796405 + 2891336453
		rd := 1.0 + (f32(state & 0xFFFF) / 32768.0 - 1.0) * rad_jag

		n := linalg.normalize0(d + [3]f32{rx, ry, rz})
		// Octahedral diagonal planes sit slightly closer (~0.92 * r) so all 14 facets actively bevel the crater
		base_scale: f32 = 1.0 if idx < 6 else 0.92
		dist := linalg.dot(n, center) + r * base_scale * rd
		// Slight per-facet shade variation so crater facets read crisply even with 1 light
		shade := u8(clamp(i32(scorch_col.r) + i32((idx % 5) - 2) * 5, 0, 255))
		facet_col := [4]u8{
			shade,
			u8(clamp(i32(scorch_col.g) + i32((idx % 5) - 2) * 4, 0, 255)),
			u8(clamp(i32(scorch_col.b) + i32((idx % 5) - 2) * 4, 0, 255)),
			255,
		}
		append(&hull.planes, quantize_plane(CSG_Plane{
			normal   = n,
			dist     = dist,
			mat_slot = mat_slot if mat_slot > 0 else 1,
			uv_scale = 0.5,
			color    = facet_col,
		}))
	}

	if !convex_rebuild_bounds_and_prune(&hull, prune_redundant = true, min_extent = 0.005) {
		convex_destroy(&hull)
		return {}, false
	}
	return hull, true
}

// ============================================================================
// TRIANGULATION & METRIC WORLD-ALIGNED UV PROJECTION
// ============================================================================

// Cyrus-Beck exact ray vs. convex half-space polyhedron test for 3D self-shadowing
@(private = "file")
_ray_hits_convex :: proc(origin, dir: [3]f32, h: CSG_Convex, min_t: f32 = 0.04, max_t: f32 = 30.0) -> bool {
	t_enter := min_t
	t_exit  := max_t
	for p in h.planes {
		numer := p.dist - linalg.dot(p.normal, origin)
		denom := linalg.dot(p.normal, dir)
		if abs(denom) < 1e-6 {
			if numer < -1e-4 do return false
		} else {
			t := numer / denom
			if denom > 0 {
				if t < t_exit do t_exit = t
			} else {
				if t > t_enter do t_enter = t
			}
			if t_enter > t_exit do return false
		}
	}
	return t_exit >= t_enter && t_enter < max_t
}

// ============================================================================
// SMART CSG SIMPLIFIER, COLLINEAR VERTEX CLEANER & EXACT SEAM CLIPPING
// ============================================================================

// Cleans a 3D convex/planar polygon loop in-place:
// 1. Combines/welds consecutive vertices that are closer than `min_dist` (removes micro-clusters).
// 2. Dissolves pointless collinear vertices (`prev -> curr -> next` on a straight line).
csg_clean_and_simplify_face_poly :: proc(verts: ^[dynamic][3]f32, min_dist: f32 = 0.006) {
	if verts == nil || len(verts) < 3 do return
	min_d2 := min_dist * min_dist

	changed := true
	guard := 16
	for changed && len(verts) >= 3 && guard > 0 {
		changed = false
		guard -= 1

		// Pass 1: Weld close consecutive vertices
		for i := 0; i < len(verts) && len(verts) >= 3; {
			next := (i + 1) % len(verts)
			if linalg.length2(verts[i] - verts[next]) <= min_d2 {
				ordered_remove(verts, next)
				changed = true
			} else {
				i += 1
			}
		}
		if len(verts) < 3 do break

		// Pass 2: Dissolve collinear degree-2 boundary vertices (`dot(d1, d2) > 0.9992`)
		for i := 0; i < len(verts) && len(verts) >= 3; {
			n := len(verts)
			prev := verts[(i - 1 + n) % n]
			curr := verts[i]
			next := verts[(i + 1) % n]
			e1 := curr - prev
			e2 := next - curr
			l1 := linalg.length(e1)
			l2 := linalg.length(e2)
			if l1 <= min_dist || l2 <= min_dist || linalg.dot(e1 / l1, e2 / l2) > 0.9992 {
				ordered_remove(verts, i)
				changed = true
			} else {
				i += 1
			}
		}
	}
}

// Tests whether a 3D planar polygon loop `verts` with outward normal `normal` is strictly convex
// and free of self-pinching duplicate vertices.
csg_is_face_poly_convex :: proc(verts: [][3]f32, normal: [3]f32) -> bool {
	n := len(verts)
	if n < 3 do return false
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			if linalg.length2(verts[i] - verts[j]) < 1e-5 {
				return false
			}
		}
	}
	for i in 0 ..< n {
		a := verts[(i - 1 + n) % n]
		b := verts[i]
		c := verts[(i + 1) % n]
		e1 := linalg.normalize0(b - a)
		e2 := linalg.normalize0(c - b)
		cr := linalg.cross(e1, e2)
		if linalg.dot(cr, normal) < -1e-4 {
			return false
		}
	}
	return true
}

// Subtracts the 2D/3D contact footprint of a touching sibling hull `hj` from a coplanar face polygon `f`.
// - If `f` does not overlap `hj`, appends `f` untouched to `out_pieces`.
// - If `f` is 100% covered by `hj`, discards `f` (buried internal seam!).
// - If `f` is partially covered by `hj` (e.g. a wall slab touching a top lintel or bottom sill around a carved tunnel),
//   splits `f` along `hj`'s side planes and keeps ONLY the exposed exterior portions of `f`!
@(private = "file")
_subtract_hull_from_face_poly :: proc(
	f:          CSG_Face_Poly,
	hj:         CSG_Convex,
	out_pieces: ^[dynamic]CSG_Face_Poly,
	alloc := context.temp_allocator,
) {
	if len(f.verts) < 3 do return

	f_min := f.verts[0]
	f_max := f.verts[0]
	for v in f.verts[1:] {
		f_min = linalg.min(f_min, v)
		f_max = linalg.max(f_max, v)
	}
	if !aabb_overlaps(f_min, f_max, hj.aabb_min, hj.aabb_max, 0.01) {
		append(out_pieces, f)
		return
	}

	// Fast check: if all vertices of `f` lie outside any single non-parallel side plane of `hj`, `f` is completely outside `hj`!
	all_inside_hj := true
	for pb in hj.planes {
		if abs(linalg.dot(pb.normal, f.normal)) >= 0.995 do continue
		min_d := max(f32)
		max_d := -max(f32)
		for v in f.verts {
			d := linalg.dot(pb.normal, v) - pb.dist
			min_d = min(min_d, d)
			max_d = max(max_d, d)
		}
		if min_d >= -0.0015 && max_d > 0.002 {
			append(out_pieces, f)
			return
		}
		if max_d > 0.002 {
			all_inside_hj = false
		}
	}
	if all_inside_hj {
		// 100% buried inside `hj`!
		return
	}

	// Partial overlap on the shared seam plane: slice `work` against each non-parallel side plane of `hj`.
	work := make([dynamic][3]f32, len(f.verts), alloc)
	copy(work[:], f.verts[:])
	clip_out := make([dynamic][3]f32, 0, 12, alloc)
	clip_in  := make([dynamic][3]f32, 0, 12, alloc)

	for pb in hj.planes {
		if len(work) < 3 do break
		// Skip planes parallel/anti-parallel to the face itself
		if abs(linalg.dot(pb.normal, f.normal)) >= 0.995 do continue

		min_d := max(f32)
		max_d := -max(f32)
		for v in work {
			d := linalg.dot(pb.normal, v) - pb.dist
			min_d = min(min_d, d)
			max_d = max(max_d, d)
		}

		if max_d <= 0.002 {
			// `work` is already inside `pb`, move to next side plane
			continue
		}
		if min_d >= -0.0015 && max_d > 0.002 {
			// `work` is completely outside `pb` -> all of `work` survives outside `hj`!
			csg_clean_and_simplify_face_poly(&work)
			if len(work) >= 3 && polygon_area(work[:]) > 1e-4 {
				piece := f
				piece.verts = work
				append(out_pieces, piece)
			}
			return
		}

		// `work` straddles `pb`:
		// 1. Emit the outside part (`dot(pb.normal, x) >= pb.dist`, i.e., clipped by `-pb`)
		out_plane := CSG_Plane{normal = -pb.normal, dist = -pb.dist}
		clip_polygon_by_plane(work[:], out_plane, &clip_out)
		csg_clean_and_simplify_face_poly(&clip_out)
		if len(clip_out) >= 3 && polygon_area(clip_out[:]) > 1e-4 {
			saved := make([dynamic][3]f32, len(clip_out), alloc)
			copy(saved[:], clip_out[:])
			piece := f
			piece.verts = saved
			append(out_pieces, piece)
		}

		// 2. Keep the inside part (`dot(pb.normal, x) <= pb.dist`) as `work` for remaining planes of `hj`
		clip_polygon_by_plane(work[:], pb, &clip_in)
		work, clip_in = clip_in, work
		csg_clean_and_simplify_face_poly(&work)
	}
	// Anything still remaining in `work` after all side planes of `hj` lies strictly inside `hj` and is culled!
}

// Clips face `f` of `hulls[f.hull_idx]` against all sibling hulls `hulls[j]` (`j != f.hull_idx`)
// (plus any `extra_sibling_hulls` from neighboring chunks) that share an opposing seam plane with `f`,
// appending only the exposed exterior polygon pieces to `out_faces`.
@(private = "file")
_clip_face_poly_against_sibling_hulls :: proc(
	f:                   CSG_Face_Poly,
	hulls:               []CSG_Convex,
	out_faces:           ^[dynamic]CSG_Face_Poly,
	alloc                := context.temp_allocator,
	extra_sibling_hulls: []CSG_Convex = nil,
) {
	if len(f.verts) < 3 do return
	if len(hulls) <= 1 && len(extra_sibling_hulls) == 0 {
		f_clean := f
		csg_clean_and_simplify_face_poly(&f_clean.verts)
		if len(f_clean.verts) >= 3 && polygon_area(f_clean.verts[:]) > 1e-4 {
			append(out_faces, f_clean)
		}
		return
	}

	curr_list := make([dynamic]CSG_Face_Poly, 0, 4, alloc)
	next_list := make([dynamic]CSG_Face_Poly, 0, 4, alloc)
	f_init := f
	csg_clean_and_simplify_face_poly(&f_init.verts)
	if len(f_init.verts) < 3 || polygon_area(f_init.verts[:]) <= 1e-4 do return
	append(&curr_list, f_init)

	v0 := f_init.verts[0]
	for hj, j in hulls {
		if j == f.hull_idx || len(curr_list) == 0 do continue

		has_opposing_seam := false
		for pb in hj.planes {
			if linalg.dot(pb.normal, f.normal) < -0.9985 && abs(linalg.dot(pb.normal, v0) - pb.dist) <= 0.004 {
				has_opposing_seam = true
				break
			}
		}
		if !has_opposing_seam do continue

		clear(&next_list)
		for piece in curr_list {
			_subtract_hull_from_face_poly(piece, hj, &next_list, alloc)
		}
		curr_list, next_list = next_list, curr_list
	}

	for hj in extra_sibling_hulls {
		if len(curr_list) == 0 do break
		has_opposing_seam := false
		for pb in hj.planes {
			if linalg.dot(pb.normal, f.normal) < -0.9985 && abs(linalg.dot(pb.normal, v0) - pb.dist) <= 0.004 {
				has_opposing_seam = true
				break
			}
		}
		if !has_opposing_seam do continue

		clear(&next_list)
		for piece in curr_list {
			_subtract_hull_from_face_poly(piece, hj, &next_list, alloc)
		}
		curr_list, next_list = next_list, curr_list
	}

	for piece in curr_list {
		if len(piece.verts) >= 3 && polygon_area(piece.verts[:]) > 1e-4 {
			append(out_faces, piece)
		}
	}
}

// Greedily merges coplanar adjacent `CSG_Face_Poly` polygons that share an edge whenever their
// combined loop is strictly convex, immediately dissolving collinear midpoint vertices along straight edges!
@(private = "file")
_merge_coplanar_csg_face_polys :: proc(faces: ^[dynamic]CSG_Face_Poly, alloc := context.temp_allocator) {
	if faces == nil || len(faces) <= 1 do return

	merged := true
	guard := 96
	for merged && len(faces) > 1 && guard > 0 {
		merged = false
		guard -= 1
		outer_merge: for i := 0; i < len(faces); i += 1 {
			fa := faces[i]
			na := len(fa.verts)
			if na < 3 do continue

			for j := i + 1; j < len(faces); j += 1 {
				fb := faces[j]
				nb := len(fb.verts)
				if nb < 3 do continue
				if fa.mat_slot != fb.mat_slot || fa.color != fb.color || fa.uv_lock_brush != fb.uv_lock_brush do continue
				if abs(fa.uv_scale - fb.uv_scale) > 1e-3 || abs(fa.uv_rot_deg - fb.uv_rot_deg) > 1e-2 do continue
				if linalg.length2(fa.uv_offset - fb.uv_offset) > 1e-4 do continue
				if linalg.dot(fa.normal, fb.normal) < 0.9995 do continue
				if abs(linalg.dot(fa.normal, fb.verts[0] - fa.verts[0])) > 0.003 do continue

				// Check if `fa` and `fb` share an opposing directed edge (`va0 -> va1` in `fa`, `vb0 -> vb1` in `fb` with `va0 == vb1` and `va1 == vb0`)
				for ea in 0 ..< na {
					va0 := fa.verts[ea]
					va1 := fa.verts[(ea + 1) % na]
					for eb in 0 ..< nb {
						vb0 := fb.verts[eb]
						vb1 := fb.verts[(eb + 1) % nb]
						if linalg.length2(va0 - vb1) <= 2.5e-5 && linalg.length2(va1 - vb0) <= 2.5e-5 {
							comb := make([dynamic][3]f32, 0, na + nb - 2, alloc)
							for k in 0 ..< na - 1 {
								append(&comb, fa.verts[(ea + 1 + k) % na])
							}
							for k in 0 ..< nb - 1 {
								append(&comb, fb.verts[(eb + 1 + k) % nb])
							}
							csg_clean_and_simplify_face_poly(&comb)
							if len(comb) >= 3 && csg_is_face_poly_convex(comb[:], fa.normal) && polygon_area(comb[:]) > 1e-4 {
								faces[i].verts = comb
								ordered_remove(faces, j)
								merged = true
								break outer_merge
							}
						}
					}
				}
			}
		}
	}
}

// Stitches T-junction vertices between coplanar adjacent `CSG_Face_Poly` polygons so that if a corner
// vertex `vk` of one face (e.g. a tunnel lintel corner) lies strictly inside the boundary edge `va -> vb`
// of an adjacent coplanar face (e.g. the side wall frame), `vk` is inserted into `va -> vb`.
@(private = "file")
_stitch_coplanar_t_junctions :: proc(faces: ^[dynamic]CSG_Face_Poly) {
	if faces == nil || len(faces) <= 1 do return

	for i in 0 ..< len(faces) {
		fa := &faces[i]
		if len(fa.verts) < 3 do continue
		for j in 0 ..< len(faces) {
			if i == j do continue
			fb := faces[j]
			if len(fb.verts) < 3 do continue
			if linalg.dot(fa.normal, fb.normal) < 0.9995 do continue
			if abs(linalg.dot(fa.normal, fb.verts[0] - fa.verts[0])) > 0.003 do continue

			for vk in fb.verts {
				// Skip if `vk` is already a vertex of `fa`
				already := false
				for va in fa.verts {
					if linalg.length2(vk - va) <= 2.5e-5 {
						already = true
						break
					}
				}
				if already do continue

				// Check if `vk` lies strictly inside any edge `va -> vb` of `fa`
				for e := 0; e < len(fa.verts); e += 1 {
					va := fa.verts[e]
					vb := fa.verts[(e + 1) % len(fa.verts)]
					ab := vb - va
					ab_len2 := linalg.length2(ab)
					if ab_len2 < 1e-4 do continue
					t := linalg.dot(vk - va, ab) / ab_len2
					if t <= 0.01 || t >= 0.99 do continue
					proj := va + ab * t
					if linalg.length2(vk - proj) <= 2.5e-5 {
						inject_at(&fa.verts, e + 1, vk)
						break
					}
				}
			}
		}
	}
}

// Dissolves pointless T-junction / split-seam vertices sitting on straight outer edges of coplanar frame quads!
// When a vertex `vi` is ONLY referenced by 2 coplanar faces `F1` and `F2` (because any perpendicular face like
// the roof/floor already dissolved `vi` along its straight outer edge), and `F1` has `(vt -> vi -> vc)` while
// `F2` has `(vi -> vt)` (or vice-versa), removing `vi` from `F1` (`vt -> vc`) and replacing `vi` with `vc` in `F2`
// (`vc -> vt`) pivots the vertical split seam into a clean corner-to-corner miter seam and eliminates `vi`!
@(private = "file")
_dissolve_coplanar_seam_miter_vertices :: proc(faces: ^[dynamic]CSG_Face_Poly, alloc := context.temp_allocator) {
	if faces == nil || len(faces) <= 1 do return

	same_pt :: #force_inline proc(a, b: [3]f32) -> bool {
		return linalg.length2(a - b) <= 2.5e-5
	}

	changed := true
	guard := 64
	for changed && guard > 0 {
		changed = false
		guard -= 1

		outer_miter: for f1_idx in 0 ..< len(faces) {
			f1 := &faces[f1_idx]
			n1 := len(f1.verts)
			if n1 < 4 do continue

			for k1 in 0 ..< n1 {
				vi := f1.verts[k1]
				// Count how many faces in `faces` contain `vi`
				ref_count := 0
				f2_idx := -1
				k2_found := -1
				for fj_idx in 0 ..< len(faces) {
					fj := faces[fj_idx]
					for v, kj in fj.verts {
						if same_pt(v, vi) {
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
				f2 := &faces[f2_idx]
				n2 := len(f2.verts)
				if n2 < 3 do continue
				if linalg.dot(f1.normal, f2.normal) < 0.9995 do continue
				if abs(linalg.dot(f1.normal, f2.verts[0] - f1.verts[0])) > 0.003 do continue

				prev1 := f1.verts[(k1 - 1 + n1) % n1]
				next1 := f1.verts[(k1 + 1) % n1]
				prev2 := f2.verts[(k2_found - 1 + n2) % n2]
				next2 := f2.verts[(k2_found + 1) % n2]

				// Case 1: `prev1 == next2` (shared interior corner `vt = prev1`, outer corner `vc = next1`).
				// Only remove `vi` from `f1` if `vt = prev1` is a collinear T-junction in `f1` (so `f1` is the 5/6-vert T-bar face,
				// never turning a 4-vert sill/lintel quad into a 3-vert triangle!).
				if same_pt(prev1, next2) && !same_pt(next1, prev2) {
					prev_prev1 := f1.verts[(k1 - 2 + n1) % n1]
					dir_in  := linalg.normalize0(prev1 - prev_prev1)
					dir_out := linalg.normalize0(vi - prev1)
					if linalg.dot(dir_in, dir_out) > 0.995 {
						vc := next1
						cand1 := make([dynamic][3]f32, 0, n1 - 1, alloc)
						for m in 0 ..< n1 {
							if m != k1 do append(&cand1, f1.verts[m])
						}
						cand2 := make([dynamic][3]f32, n2, alloc)
						copy(cand2[:], f2.verts[:])
						cand2[k2_found] = vc

						if csg_is_face_poly_convex(cand1[:], f1.normal) && csg_is_face_poly_convex(cand2[:], f2.normal) {
							f1.verts = cand1
							f2.verts = cand2
							changed = true
							break outer_miter
						}
					}
				}

				// Case 2: `next1 == prev2` (shared interior corner `vt = next1`, outer corner `vc = prev1`).
				// Only remove `vi` from `f1` if `vt = next1` is a collinear T-junction in `f1`.
				if same_pt(next1, prev2) && !same_pt(prev1, next2) {
					next_next1 := f1.verts[(k1 + 2) % n1]
					dir_in  := linalg.normalize0(next1 - vi)
					dir_out := linalg.normalize0(next_next1 - next1)
					if linalg.dot(dir_in, dir_out) > 0.995 {
						vc := prev1
						cand1 := make([dynamic][3]f32, 0, n1 - 1, alloc)
						for m in 0 ..< n1 {
							if m != k1 do append(&cand1, f1.verts[m])
						}
						cand2 := make([dynamic][3]f32, n2, alloc)
						copy(cand2[:], f2.verts[:])
						cand2[k2_found] = vc

						if csg_is_face_poly_convex(cand1[:], f1.normal) && csg_is_face_poly_convex(cand2[:], f2.normal) {
							f1.verts = cand1
							f2.verts = cand2
							changed = true
							break outer_miter
						}
					}
				}
			}
		}
	}
}

// Stitches any remaining T-junction vertices across ALL faces (including perpendicular pillar/slab junctions)
// after 2-face coplanar miter seams have already been dissolved.
@(private = "file")
_stitch_all_face_t_junctions :: proc(faces: ^[dynamic]CSG_Face_Poly) {
	if faces == nil || len(faces) <= 1 do return

	for i in 0 ..< len(faces) {
		fa := &faces[i]
		if len(fa.verts) < 3 do continue
		for j in 0 ..< len(faces) {
			if i == j do continue
			fb := faces[j]
			if len(fb.verts) < 3 do continue

			for vk in fb.verts {
				already := false
				for va in fa.verts {
					if linalg.length2(vk - va) <= 2.5e-5 {
						already = true
						break
					}
				}
				if already do continue

				for e := 0; e < len(fa.verts); e += 1 {
					va := fa.verts[e]
					vb := fa.verts[(e + 1) % len(fa.verts)]
					ab := vb - va
					ab_len2 := linalg.length2(ab)
					if ab_len2 < 1e-4 do continue
					t := linalg.dot(vk - va, ab) / ab_len2
					if t <= 0.01 || t >= 0.99 do continue
					proj := va + ab * t
					if linalg.length2(vk - proj) <= 2.5e-5 {
						inject_at(&fa.verts, e + 1, vk)
						break
					}
				}
			}
		}
	}
}

// Splits any convex face polygon that still contains a 180-degree collinear stitched T-junction vertex `v_k`
// along a chord `(v_k, v_m)` to an opposite non-collinear vertex `v_m` of the face (preferring an opposite T-junction
// vertex perpendicular to the edge so cross-shaped tunnel ceilings split into pure 4-vertex rectangles!).
// Guarantees 0 collinear vertices, 0 zero-area fan triangles, and 100% manifold paired edges (`open_boundary_edges == 0`).
@(private = "file")
_split_faces_at_collinear_t_junctions :: proc(faces: ^[dynamic]CSG_Face_Poly, alloc := context.temp_allocator) {
	if faces == nil || len(faces) == 0 do return

	is_collinear_at :: proc(verts: [][3]f32, idx: int) -> (bool, [3]f32) {
		n := len(verts)
		if n < 4 do return false, {}
		prev := verts[(idx - 1 + n) % n]
		curr := verts[idx]
		next := verts[(idx + 1) % n]
		e1 := linalg.normalize0(curr - prev)
		e2 := linalg.normalize0(next - curr)
		if linalg.dot(e1, e2) > 0.999 {
			return true, linalg.normalize0(next - prev)
		}
		return false, {}
	}

	split_any := true
	guard := 128
	for split_any && guard > 0 {
		split_any = false
		guard -= 1
		for fi := 0; fi < len(faces); fi += 1 {
			f := faces[fi]
			n := len(f.verts)
			if n < 4 do continue

			col_k := -1
			edge_dir: [3]f32
			for k in 0 ..< n {
				if ok, ed := is_collinear_at(f.verts[:], k); ok {
					col_k = k
					edge_dir = ed
					break
				}
			}
			if col_k < 0 do continue

			vk := f.verts[col_k]
			best_m := -1
			best_score := f32(-1e9)
			for m in 0 ..< n {
				if m == col_k || m == (col_k + 1) % n || m == (col_k - 1 + n) % n do continue
				vm := f.verts[m]
				chord := vm - vk
				clen := linalg.length(chord)
				if clen <= 1e-3 do continue
				cdir := chord / clen
				align := abs(linalg.dot(cdir, edge_dir))
				if align > 0.96 do continue // Must not be on the same straight edge!

				// Prefer perpendicular chords (`1.0 - align`), with a bonus if `vm` is ALSO a collinear T-junction!
				score := (1.0 - align) * 10.0
				if ok_m, _ := is_collinear_at(f.verts[:], m); ok_m {
					score += 5.0
				}
				if score > best_score {
					best_score = score
					best_m = m
				}
			}
			if best_m < 0 do continue

			// Split `f` along chord `col_k <-> best_m` into `poly_a` and `poly_b`
			poly_a := make([dynamic][3]f32, 0, n, alloc)
			for idx := col_k; ; idx = (idx + 1) % n {
				append(&poly_a, f.verts[idx])
				if idx == best_m do break
			}
			poly_b := make([dynamic][3]f32, 0, n, alloc)
			for idx := best_m; ; idx = (idx + 1) % n {
				append(&poly_b, f.verts[idx])
				if idx == col_k do break
			}

			if len(poly_a) >= 3 && len(poly_b) >= 3 && polygon_area(poly_a[:]) > 1e-4 && polygon_area(poly_b[:]) > 1e-4 {
				faces[fi].verts = poly_a
				fb_new := f
				fb_new.verts = poly_b
				append(faces, fb_new)
				split_any = true
				break
			}
		}
	}
}

// Extracts all visible, seam-clipped, coplanar-merged, collinear-cleaned, and miter-simplified `CSG_Face_Poly` polygons
// from a slice of `CSG_Convex` hulls.
csg_extract_clean_polygons_from_hulls :: proc(
	hulls:               []CSG_Convex,
	out_faces:           ^[dynamic]CSG_Face_Poly,
	alloc                := context.temp_allocator,
	extra_sibling_hulls: []CSG_Convex = nil,
) {
	clear(out_faces)
	if len(hulls) == 0 do return

	raw_faces := make([dynamic]CSG_Face_Poly, 0, len(hulls) * 8, alloc)
	for h, hi in hulls {
		convex_extract_faces(h, &raw_faces, alloc, hi)
	}
	if len(raw_faces) == 0 do return

	for rf in raw_faces {
		_clip_face_poly_against_sibling_hulls(rf, hulls, out_faces, alloc, extra_sibling_hulls)
	}
	_merge_coplanar_csg_face_polys(out_faces, alloc)
	if len(out_faces) <= 72 {
		_stitch_coplanar_t_junctions(out_faces)
		_merge_coplanar_csg_face_polys(out_faces, alloc)
		_dissolve_coplanar_seam_miter_vertices(out_faces, alloc)
		_stitch_all_face_t_junctions(out_faces)
		_split_faces_at_collinear_t_junctions(out_faces, alloc)
	}
}

// Smart CSG Hull Simplifier & Lazy Cleaner:
// 1. Prunes degenerate/sliver hulls and redundant planes.
// 2. Merges adjacent sibling `CSG_Convex` hulls that share an opposing split plane and have identical non-seam side planes
//    (collapsing unnecessary splits back into single clean convex blocks without ever filling holes or tunnels!).
csg_clean_and_simplify_hulls :: proc(hulls: ^[dynamic]CSG_Convex, alloc := context.allocator) -> (cleaned_count: int) {
	if hulls == nil || len(hulls) == 0 do return 0

	// 1. Prune degenerate hulls and redundant planes
	for i := len(hulls) - 1; i >= 0; i -= 1 {
		if !convex_rebuild_bounds_and_prune(&hulls[i], prune_redundant = true, min_extent = 0.004) {
			convex_destroy(&hulls[i])
			ordered_remove(hulls, i)
			cleaned_count += 1
		}
	}
	if len(hulls) <= 1 do return cleaned_count

	// 2. Exact Sibling Convex Hull Merging:
	// If Hull A and Hull B share an opposing seam plane `(pa in A, pb in B)` with `dot(pa.normal, pb.normal) < -0.999`
	// and `abs(pa.dist + pb.dist) <= 0.006`, AND all their non-seam planes (`abs(dot(p.normal, pa.normal)) < 0.998`) match,
	// then `A` and `B` are the two exact halves of a single convex block split by `pa`!
	// Prioritizing X-seams -> Z-seams -> Y-seams -> diagonal seams prevents pinwheel deadlocks on 3x3 slab grids
	// (so a 2-tunnel 4-pillar box always simplifies to 1 Top Slab + 1 Bottom Slab + 4 Pillars = 6 hulls!).
	merged := true
	guard := 96
	for merged && len(hulls) > 1 && guard > 0 {
		merged = false
		guard -= 1
		outer_h: for axis_pass in 0 ..< 4 {
			for i := 0; i < len(hulls); i += 1 {
				ha := hulls[i]
				for j := i + 1; j < len(hulls); j += 1 {
					hb := hulls[j]
					if ha.anchored != hb.anchored do continue
					if !aabb_overlaps(ha.aabb_min, ha.aabb_max, hb.aabb_min, hb.aabb_max, 0.01) do continue

					seam_ia := -1
					seam_ib := -1
					for pa, ia in ha.planes {
						for pb, ib in hb.planes {
							if linalg.dot(pa.normal, pb.normal) < -0.999 && abs(pa.dist + pb.dist) <= 0.006 {
								seam_ia = ia
								seam_ib = ib
								break
							}
						}
						if seam_ia >= 0 do break
					}
					if seam_ia < 0 || seam_ib < 0 do continue

					seam_n := ha.planes[seam_ia].normal
					if axis_pass == 0 && abs(seam_n.x) < 0.9 do continue
					if axis_pass == 1 && abs(seam_n.z) < 0.9 do continue
					if axis_pass == 2 && abs(seam_n.y) < 0.9 do continue

					sides_match := true
					for pa, ia in ha.planes {
						if ia == seam_ia || abs(linalg.dot(pa.normal, seam_n)) >= 0.998 do continue
						found := false
						for pb, ib in hb.planes {
							if ib == seam_ib do continue
							if linalg.dot(pa.normal, pb.normal) > 0.998 && abs(pa.dist - pb.dist) <= 0.006 {
								found = true
								break
							}
						}
						if !found {
							sides_match = false
							break
						}
					}
					if !sides_match do continue

					for pb, ib in hb.planes {
						if ib == seam_ib || abs(linalg.dot(pb.normal, seam_n)) >= 0.998 do continue
						found := false
						for pa, ia in ha.planes {
							if ia == seam_ia do continue
							if linalg.dot(pa.normal, pb.normal) > 0.998 && abs(pa.dist - pb.dist) <= 0.006 {
								found = true
								break
							}
						}
						if !found {
							sides_match = false
							break
						}
					}
					if !sides_match do continue

					// Build merged convex hull by dropping `seam_ia` from `ha` and `seam_ib` from `hb`
					cand := CSG_Convex{
						planes   = make([dynamic]CSG_Plane, 0, len(ha.planes) + 2, alloc),
						anchored = ha.anchored,
						brush_id = ha.brush_id,
					}
					for pa, ia in ha.planes {
						if ia == seam_ia do continue
						append(&cand.planes, pa)
					}
					for pb, ib in hb.planes {
						if ib == seam_ib do continue
						dup := false
						for &cp in cand.planes {
							if linalg.dot(cp.normal, pb.normal) > 0.998 {
								cp.dist = max(cp.dist, pb.dist)
								dup = true
								break
							}
						}
						if !dup {
							append(&cand.planes, pb)
						}
					}
					if convex_rebuild_bounds_and_prune(&cand, prune_redundant = true, min_extent = 0.004) {
						convex_destroy(&hulls[i])
						convex_destroy(&hulls[j])
						hulls[i] = cand
						ordered_remove(hulls, j)
						cleaned_count += 1
						merged = true
						break outer_h
					} else {
						convex_destroy(&cand)
					}
				}
			}
		}
	}
	return cleaned_count
}

// Triangulates a slice of `CSG_Convex` polyhedra into GPU-ready `gfx.Vertex`, `u32` indices,
// and up to 2 `Mesh_Submesh` ranges (Submesh 0 = Exterior architecture, Submesh 1 = Crater interior),
// clipping buried & partially-buried internal seam faces, merging coplanar polygons, dissolving
// pointless collinear vertices, culling sliver triangles, and baking directional sun self-shadowing + cavity AO.
csg_triangulate_hulls :: proc(
	hulls:               []CSG_Convex,
	out_verts:           ^[dynamic]gfx.Vertex,
	out_indices:         ^[dynamic]u32,
	out_submeshes:       ^[dynamic]engine.Mesh_Submesh,
	sun_dir:             [3]f32 = {0, 0, 0},
	extra_sibling_hulls: []CSG_Convex = nil,
) {
	clear(out_verts)
	clear(out_indices)
	clear(out_submeshes)
	if len(hulls) == 0 do return

	faces := make([dynamic]CSG_Face_Poly, 0, len(hulls) * 8, context.temp_allocator)
	csg_extract_clean_polygons_from_hulls(hulls, &faces, context.temp_allocator, extra_sibling_hulls)
	if len(faces) == 0 do return

	has_sun := linalg.length2(sun_dir) > 0.01
	max_slot: u8 = 0
	for f in faces {
		if len(f.verts) >= 3 && f.mat_slot > max_slot {
			max_slot = min(f.mat_slot, 7)
		}
	}

	// Emit pass 0 (mat_slot == 0) through `max_slot` (`1..7`) so each per-cut/blast material slot has a contiguous submesh
	for slot in u8(0) ..= max_slot {
		first_idx := u32(len(out_indices))
		for f in faces {
			if min(f.mat_slot, 7) != slot || len(f.verts) < 3 do continue
			u_ax, v_ax := plane_tangent_basis(f.normal)
			uv_s := f.uv_scale if f.uv_scale > 0.001 else 0.5
			base_v := u32(len(out_verts))

			// Compute face center for soft self-shadowing supplement
			face_center: [3]f32
			for pos in f.verts do face_center += pos
			face_center /= f32(len(f.verts))

			for pos in f.verts {
				// RealtimeCSG `TexGen` UV Projection:
				// - World-Locked (default): seamless tiling across adjacent brushes/chunks (`uv_lock_brush == false`)
				// - Brush-Locked (`uv_lock_brush == true`): anchors UVs to the hull centroid so moving/resizing does not swim textures!
				uv_pos := pos
				if f.uv_lock_brush && f.hull_idx >= 0 && f.hull_idx < len(hulls) {
					uv_pos = pos - hulls[f.hull_idx].centroid
				}
				u_raw := linalg.dot(uv_pos, u_ax) * uv_s
				v_raw := linalg.dot(uv_pos, v_ax) * uv_s
				if abs(f.uv_rot_deg) > 1e-3 {
					rad := math.to_radians(f.uv_rot_deg)
					cr  := math.cos(rad)
					sr  := math.sin(rad)
					u_rot := u_raw * cr - v_raw * sr
					v_rot := u_raw * sr + v_raw * cr
					u_raw = u_rot
					v_raw = v_rot
				}
				uv := [2]f32{u_raw + f.uv_offset.x, v_raw + f.uv_offset.y}

				// 1. Directional Sun Raycast Self-Shadowing against sibling hulls in chunk (only when an active shadow-casting Light is in the scene)
				in_sun_shadow := false
				if has_sun && linalg.dot(f.normal, sun_dir) > -0.05 {
					sample_pt := linalg.lerp(pos, face_center, 0.22) + f.normal * 0.045
					for h in hulls {
						if _ray_hits_convex(sample_pt, sun_dir, h, 0.05, 28.0) {
							in_sun_shadow = true
							break
						}
					}
				}

				// 2. Ground & Overhang Contact Cavity AO
				ao_factor: f32 = 1.0
				if f.normal.y < -0.5 {
					// Underside of catwalks/archways/doorways
					ao_factor *= 0.78
				} else if abs(f.normal.y) < 0.35 && pos.y >= -0.05 && pos.y <= 0.35 {
					// Base of vertical walls/pillars meeting the floor
					ao_factor *= 0.88 + 0.12 * clamp(pos.y / 0.35, 0.0, 1.0)
				}

				shade_r := f32(f.color.r) * ao_factor
				shade_g := f32(f.color.g) * ao_factor
				shade_b := f32(f.color.b) * ao_factor
				if in_sun_shadow {
					// Cool sky-tinted shadow multiplier so self-shadowed floors/walls read with crisp 3D depth
					shade_r *= 0.56
					shade_g *= 0.59
					shade_b *= 0.66
				}

				v_col := [4]u8{
					u8(clamp(shade_r, 0.0, 255.0)),
					u8(clamp(shade_g, 0.0, 255.0)),
					u8(clamp(shade_b, 0.0, 255.0)),
					f.color.a,
				}

				append(out_verts, gfx.Vertex{
					position = pos,
					normal   = f.normal,
					uv       = uv,
					color    = v_col,
				})
			}

			// Fan triangulation (guaranteed valid because every face is a convex polygon), skipping degenerate slivers!
			tri_count := u32(len(f.verts) - 2)
			p0 := f.verts[0]
			for t in 0 ..< tri_count {
				p1 := f.verts[t + 1]
				p2 := f.verts[t + 2]
				if linalg.length(linalg.cross(p1 - p0, p2 - p0)) * 0.5 <= 1e-5 do continue
				append(out_indices, base_v)
				append(out_indices, base_v + t + 1)
				append(out_indices, base_v + t + 2)
			}
		}
		idx_count := u32(len(out_indices)) - first_idx
		append(out_submeshes, engine.Mesh_Submesh{
			first_index = first_idx,
			index_count = idx_count,
		})
	}
	for len(out_submeshes) > 0 && out_submeshes[len(out_submeshes) - 1].index_count == 0 {
		pop(out_submeshes)
	}
}

// ============================================================================
// STRUCTURAL ADJACENCY & FLOATING ISLAND FLOOD-FILL (Red Faction Collapse)
// ============================================================================

// Returns true if two convex hulls touch or share a boundary within `touch_eps` (100% symmetric!).
convex_touches :: proc(a, b: CSG_Convex, touch_eps: f32 = 0.04) -> bool {
	if !aabb_overlaps(a.aabb_min, a.aabb_max, b.aabb_min, b.aabb_max, touch_eps) {
		return false
	}
	for pa in a.planes {
		for pb in b.planes {
			// Opposing normals at almost the same plane offset
			if linalg.dot(pa.normal, pb.normal) < -0.95 && abs(pa.dist + pb.dist) <= touch_eps {
				return true
			}
		}
	}
	// Symmetric check 1: any vertex of `a` within `touch_eps` of all planes of `b`
	verts_a := make([dynamic][3]f32, 0, 24, context.temp_allocator)
	convex_extract_vertices(a, &verts_a)
	for v in verts_a {
		inside_b := true
		for pb in b.planes {
			if linalg.dot(pb.normal, v) - pb.dist > touch_eps {
				inside_b = false
				break
			}
		}
		if inside_b do return true
	}
	// Symmetric check 2: any vertex of `b` within `touch_eps` of all planes of `a`
	verts_b := make([dynamic][3]f32, 0, 24, context.temp_allocator)
	convex_extract_vertices(b, &verts_b)
	for v in verts_b {
		inside_a := true
		for pa in a.planes {
			if linalg.dot(pa.normal, v) - pa.dist > touch_eps {
				inside_a = false
				break
			}
		}
		if inside_a do return true
	}
	return false
}

// Breadth-first search (BFS) on convex hull adjacency to separate any hulls
// disconnected from the ground foundation (`aabb_min.y <= ground_y + 0.12`) — OR, for
// elevated/dynamic CSG objects that do not touch the ground, any smaller piece split
// off from the largest connected component — into `detached_hulls` so severed CSG
// pieces become independent dynamic physics objects!
csg_extract_detached_islands :: proc(
	hulls:          ^[dynamic]CSG_Convex,
	ground_y:       f32,
	detached_hulls: ^[dynamic]CSG_Convex,
) {
	n := len(hulls)
	if n <= 1 do return

	visited := make([]bool, n, context.temp_allocator)
	queue := make([dynamic]int, 0, n, context.temp_allocator)

	// 1. Seed BFS with hulls resting on the ground plane (`aabb_min.y <= ground_y + 0.12`),
	//    or foundation-anchored hulls near ground level.
	//    (Elevated hulls at the top of a pillar/wall are only kept if connected through intact lower hulls!)
	for i in 0 ..< n {
		if hulls[i].aabb_min.y <= ground_y + 0.12 || (hulls[i].anchored && hulls[i].aabb_min.y <= ground_y + 0.35) {
			visited[i] = true
			append(&queue, i)
		}
	}

	if len(queue) > 0 {
		head := 0
		for head < len(queue) {
			curr := queue[head]
			head += 1
			for j in 0 ..< n {
				if visited[j] do continue
				if convex_touches(hulls[curr], hulls[j]) {
					visited[j] = true
					append(&queue, j)
				}
			}
		}
	} else {
		// 2. No hull touches `ground_y` (e.g. an elevated/floating CSG brush or a dynamic CSG object).
		//    Partition all hulls into connected components via `convex_touches`: if the object was
		//    split into 2+ disconnected pieces, keep the largest connected component in `hulls`
		//    and extract all other disconnected pieces into `detached_hulls`!
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
				ext := hulls[curr].aabb_max - hulls[curr].aabb_min
				c_vol += max(ext.x, 0.05) * max(ext.y, 0.05) * max(ext.z, 0.05)
				for j in 0 ..< n {
					if comp_id[j] >= 0 do continue
					if convex_touches(hulls[curr], hulls[j]) {
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

		// If the object is still a single connected piece, nothing detached
		if num_comps <= 1 do return

		for i in 0 ..< n {
			visited[i] = (comp_id[i] == best_comp)
		}
	}

	write_idx := 0
	for i in 0 ..< n {
		if visited[i] {
			hulls[write_idx] = hulls[i]
			write_idx += 1
		} else {
			append(detached_hulls, hulls[i])
		}
	}
	resize(hulls, write_idx)
}

// Groups a flat list of detached `CSG_Convex` hulls into connected structural islands
// using `convex_touches`, transferring ownership of the hulls into each island slice.
csg_group_hulls_into_islands :: proc(
	detached: ^[dynamic]CSG_Convex,
	alloc    := context.allocator,
) -> [dynamic][dynamic]CSG_Convex {
	islands := make([dynamic][dynamic]CSG_Convex, 0, 4, alloc)
	n := len(detached)
	if n == 0 do return islands

	used := make([]bool, n, context.temp_allocator)
	queue := make([dynamic]int, 0, n, context.temp_allocator)

	for start in 0 ..< n {
		if used[start] do continue
		used[start] = true
		clear(&queue)
		append(&queue, start)

		island := make([dynamic]CSG_Convex, 0, 4, alloc)
		head := 0
		for head < len(queue) {
			curr := queue[head]
			head += 1
			append(&island, detached[curr])
			detached[curr].planes = nil
			for j in 0 ..< n {
				if used[j] do continue
				if convex_touches(island[len(island) - 1], detached[j]) {
					used[j] = true
					append(&queue, j)
				}
			}
		}
		append(&islands, island)
	}
	clear(detached)
	return islands
}

// ============================================================================
// 2D CAD POLYLINE & CATMULL-ROM SPLINE EVALUATION + CONVEX EXTRUSION
// (Unreal Modeling Mode PolyEd / Spline + Blender Curve Extrude Parity)
// ============================================================================

// Evaluates a sequence of 2D control points (`CSG_Profile_Point`) where each vertex
// can be either a Sharp CAD Corner (`smooth = false`) or a Smooth Catmull-Rom Spline
// control point (`smooth = true`).
csg_eval_profile_2d :: proc(
	points:       []CSG_Profile_Point,
	closed:       bool = true,
	subdivisions: int  = 6,
	alloc              := context.temp_allocator,
) -> [dynamic][2]f32 {
	n := len(points)
	out := make([dynamic][2]f32, 0, max(n * subdivisions, 4), alloc)
	if n == 0 do return out
	if n == 1 {
		append(&out, points[0].uv)
		return out
	}
	if n == 2 {
		append(&out, points[0].uv)
		append(&out, points[1].uv)
		return out
	}

	seg_count := n if closed else (n - 1)
	sub_n := max(subdivisions, 2)

	for i in 0 ..< seg_count {
		p1 := points[i]
		p2 := points[(i + 1) % n]

		// Straight line segment when both endpoints are Sharp Corners
		if !p1.smooth && !p2.smooth {
			append(&out, p1.uv)
			continue
		}

		p0 := points[(i - 1 + n) % n] if (closed || i > 0) else p1
		p3 := points[(i + 2) % n]     if (closed || i + 2 < n) else p2

		tension := clamp((p1.tension + p2.tension) * 0.5, 0.0, 0.85)
		scale := (1.0 - tension) * 0.5

		// Compute Hermite tangents; if one endpoint is sharp, clamp its tangent toward the chord
		// so sharp-to-curve transitions don't overshoot!
		m1 := (p2.uv - p0.uv) * scale if p1.smooth else (p2.uv - p1.uv) * 0.5
		m2 := (p3.uv - p1.uv) * scale if p2.smooth else (p2.uv - p1.uv) * 0.5

		for s in 0 ..< sub_n {
			t := f32(s) / f32(sub_n)
			t2 := t * t
			t3 := t2 * t
			h00 :=  2.0 * t3 - 3.0 * t2 + 1.0
			h10 :=        t3 - 2.0 * t2 + t
			h01 := -2.0 * t3 + 3.0 * t2
			h11 :=        t3 -       t2
			pt := h00 * p1.uv + h10 * m1 + h01 * p2.uv + h11 * m2
			append(&out, pt)
		}
	}

	if !closed {
		append(&out, points[n - 1].uv)
	}
	return out
}

@(private = "file")
_cross2d :: #force_inline proc(a, b, c: [2]f32) -> f32 {
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

@(private = "file")
_point_in_tri2d :: #force_inline proc(p, a, b, c: [2]f32) -> bool {
	c1 := _cross2d(a, b, p)
	c2 := _cross2d(b, c, p)
	c3 := _cross2d(c, a, p)
	return c1 >= -1e-5 && c2 >= -1e-5 && c3 >= -1e-5
}

@(private = "file")
_is_poly2d_convex :: proc(poly: [][2]f32) -> bool {
	n := len(poly)
	if n < 3 do return false
	for i in 0 ..< n {
		a := poly[i]
		b := poly[(i + 1) % n]
		c := poly[(i + 2) % n]
		if _cross2d(a, b, c) < -1e-4 {
			return false
		}
	}
	return true
}

// Triangulates a simple 2D Counter-Clockwise polygon (including concave / squiggly shapes)
// into convex pieces using Ear-Clipping + Hertel-Mehlhorn convex polygon merging.
@(private = "file")
_decompose_poly2d_to_convex_pieces :: proc(ccw_poly: [][2]f32, alloc := context.temp_allocator) -> [dynamic][dynamic][2]f32 {
	pieces := make([dynamic][dynamic][2]f32, 0, 8, alloc)
	n := len(ccw_poly)
	if n < 3 do return pieces

	// Fast path: already convex and <= 16 vertices!
	if n <= 16 && _is_poly2d_convex(ccw_poly) {
		single := make([dynamic][2]f32, n, alloc)
		copy(single[:], ccw_poly)
		append(&pieces, single)
		return pieces
	}

	// Ear-clipping triangulation on index list
	avail := make([dynamic]int, n, context.temp_allocator)
	for i in 0 ..< n do avail[i] = i

	guard := n * 4
	for len(avail) > 3 && guard > 0 {
		guard -= 1
		m := len(avail)
		ear_found := false

		// Pick the sharpest valid convex ear
		best_ear := -1
		best_score := -max(f32)
		for i in 0 ..< m {
			ia := avail[(i - 1 + m) % m]
			ib := avail[i]
			ic := avail[(i + 1) % m]
			a := ccw_poly[ia]
			b := ccw_poly[ib]
			c := ccw_poly[ic]

			cross := _cross2d(a, b, c)
			if cross <= 1e-5 do continue // Reflex or collinear vertex

			// Ensure no other vertex lies inside triangle (a, b, c)
			any_inside := false
			for j in 0 ..< m {
				ij := avail[j]
				if ij == ia || ij == ib || ij == ic do continue
				if _point_in_tri2d(ccw_poly[ij], a, b, c) {
					any_inside = true
					break
				}
			}
			if !any_inside {
				if cross > best_score {
					best_score = cross
					best_ear = i
				}
			}
		}

		if best_ear < 0 {
			// Fallback if self-intersecting squiggly stroke: clip middle vertex
			best_ear = 0
		}
		m = len(avail)
		ia := avail[(best_ear - 1 + m) % m]
		ib := avail[best_ear]
		ic := avail[(best_ear + 1) % m]
		tri := make([dynamic][2]f32, 3, alloc)
		tri[0] = ccw_poly[ia]
		tri[1] = ccw_poly[ib]
		tri[2] = ccw_poly[ic]
		if abs(_cross2d(tri[0], tri[1], tri[2])) > 1e-5 {
			append(&pieces, tri)
		}
		ordered_remove(&avail, best_ear)
		ear_found = true
		_ = ear_found
	}

	if len(avail) == 3 {
		tri := make([dynamic][2]f32, 3, alloc)
		tri[0] = ccw_poly[avail[0]]
		tri[1] = ccw_poly[avail[1]]
		tri[2] = ccw_poly[avail[2]]
		if abs(_cross2d(tri[0], tri[1], tri[2])) > 1e-5 {
			append(&pieces, tri)
		}
	}

	// Hertel-Mehlhorn greedy merge: merge any two pieces that share a directed edge (u->v in A, v->u in B)
	// if their combined polygon remains strictly convex and <= 12 vertices!
	merged_any := true
	for merged_any && len(pieces) > 1 {
		merged_any = false
		outer: for i := 0; i < len(pieces); i += 1 {
			pa := pieces[i]
			na := len(pa)
			for j := i + 1; j < len(pieces); j += 1 {
				pb := pieces[j]
				nb := len(pb)
				if na + nb - 2 > 12 do continue

				for ea in 0 ..< na {
					va0 := pa[ea]
					va1 := pa[(ea + 1) % na]
					for eb in 0 ..< nb {
						vb0 := pb[eb]
						vb1 := pb[(eb + 1) % nb]
						if linalg.length2(va0 - vb1) < 1e-6 && linalg.length2(va1 - vb0) < 1e-6 {
							// Candidate merged polygon
							cand := make([dynamic][2]f32, 0, na + nb - 2, alloc)
							for k in 0 ..< na {
								idx := (ea + 1 + k) % na
								if idx == ea do break
								append(&cand, pa[idx])
							}
							for k in 0 ..< nb {
								idx := (eb + 1 + k) % nb
								if idx == eb do break
								append(&cand, pb[idx])
							}
							if _is_poly2d_convex(cand[:]) {
								pieces[i] = cand
								ordered_remove(&pieces, j)
								merged_any = true
								break outer
							}
						}
					}
				}
			}
		}
	}

	return pieces
}

// Extrudes a 2D Polyline / Catmull-Rom Spline profile (`points`) on the plane
// `(plane_origin, plane_u, plane_v, plane_n)` by `extrude_height` into one or more
// watertight 3D `CSG_Convex` half-space polyhedra!
csg_extrude_profile_2d_hulls :: proc(
	points:         []CSG_Profile_Point,
	plane_origin:   [3]f32,
	plane_u:        [3]f32,
	plane_v:        [3]f32,
	plane_n:        [3]f32,
	extrude_height: f32,
	color:          [4]u8,
	uv_scale:       f32,
	mat_slot:       u8,
	anchored:       bool,
	brush_id:       u32,
	out_hulls:      ^[dynamic]CSG_Convex,
	alloc           := context.allocator,
) -> (aabb_min, aabb_max: [3]f32, ok: bool) {
	aabb_min = {max(f32), max(f32), max(f32)}
	aabb_max = {-max(f32), -max(f32), -max(f32)}
	if len(points) < 3 do return aabb_min, aabb_max, false

	raw_poly := csg_eval_profile_2d(points, true, 6, context.temp_allocator)
	if len(raw_poly) < 3 do return aabb_min, aabb_max, false

	// 1. Clean near-duplicate vertices
	clean_poly := make([dynamic][2]f32, 0, len(raw_poly), context.temp_allocator)
	for p in raw_poly {
		if len(clean_poly) == 0 || linalg.length2(p - clean_poly[len(clean_poly) - 1]) > 1e-4 {
			append(&clean_poly, p)
		}
	}
	if len(clean_poly) > 1 && linalg.length2(clean_poly[0] - clean_poly[len(clean_poly) - 1]) <= 1e-4 {
		pop(&clean_poly)
	}
	if len(clean_poly) < 3 do return aabb_min, aabb_max, false

	// 2. Remove nearly collinear interior vertices so plane counts stay compact
	simplified := make([dynamic][2]f32, 0, len(clean_poly), context.temp_allocator)
	cn := len(clean_poly)
	for i in 0 ..< cn {
		prev := clean_poly[(i - 1 + cn) % cn]
		curr := clean_poly[i]
		next := clean_poly[(i + 1) % cn]
		d1 := linalg.normalize0(curr - prev)
		d2 := linalg.normalize0(next - curr)
		if linalg.dot(d1, d2) < 0.9992 {
			append(&simplified, curr)
		}
	}
	if len(simplified) < 3 do return aabb_min, aabb_max, false

	// 3. Enforce Counter-Clockwise (CCW) 2D winding via signed shoelace area
	area2: f32 = 0
	sn := len(simplified)
	for i in 0 ..< sn {
		a := simplified[i]
		b := simplified[(i + 1) % sn]
		area2 += (a.x * b.y - b.x * a.y)
	}
	if abs(area2) < 1e-4 do return aabb_min, aabb_max, false
	if area2 < 0 {
		for i in 0 ..< sn / 2 {
			simplified[i], simplified[sn - 1 - i] = simplified[sn - 1 - i], simplified[i]
		}
	}

	// 4. Decompose into convex 2D polygons
	convex_pieces := _decompose_poly2d_to_convex_pieces(simplified[:], context.temp_allocator)
	if len(convex_pieces) == 0 do return aabb_min, aabb_max, false

	u_dir := linalg.normalize0(plane_u)
	v_dir := linalg.normalize0(plane_v)
	n_dir := linalg.normalize0(plane_n)
	if linalg.length2(n_dir) < 0.5 do n_dir = {0, 1, 0}
	if linalg.length2(u_dir) < 0.5 || linalg.length2(v_dir) < 0.5 {
		u_dir, v_dir = plane_tangent_basis(n_dir)
	}

	z_min := min(f32(0.0), extrude_height)
	z_max := max(f32(0.0), extrude_height)
	if z_max - z_min < 0.05 {
		if extrude_height >= 0 {
			z_max = z_min + 0.1
		} else {
			z_min = z_max - 0.1
		}
	}

	built_any := false
	for piece in convex_pieces {
		m := len(piece)
		if m < 3 do continue

		// Compute 2D piece centroid to guarantee outward side normals
		c2d: [2]f32
		for p in piece do c2d += p
		c2d /= f32(m)

		hull := CSG_Convex{
			planes   = make([dynamic]CSG_Plane, 0, m + 2, alloc),
			anchored = anchored,
			brush_id = brush_id,
		}

		// Top and bottom extrusion cap planes
		top_pt := plane_origin + n_dir * z_max
		bot_pt := plane_origin + n_dir * z_min
		append(&hull.planes, quantize_plane(CSG_Plane{
			normal   = n_dir,
			dist     = linalg.dot(n_dir, top_pt),
			mat_slot = mat_slot,
			uv_scale = uv_scale,
			color    = color,
		}))
		append(&hull.planes, quantize_plane(CSG_Plane{
			normal   = -n_dir,
			dist     = linalg.dot(-n_dir, bot_pt),
			mat_slot = mat_slot,
			uv_scale = uv_scale,
			color    = color,
		}))

		// Outward side planes for each 2D edge
		for i in 0 ..< m {
			pa := piece[i]
			pb := piece[(i + 1) % m]
			edge := pb - pa
			if linalg.length2(edge) < 1e-6 do continue

			n2d := linalg.normalize0([2]f32{edge.y, -edge.x})
			if linalg.dot(n2d, pa - c2d) < 0 {
				n2d = -n2d
			}
			side_n := linalg.normalize0(u_dir * n2d.x + v_dir * n2d.y)
			edge_pt3 := plane_origin + u_dir * pa.x + v_dir * pa.y
			append(&hull.planes, quantize_plane(CSG_Plane{
				normal   = side_n,
				dist     = linalg.dot(side_n, edge_pt3),
				mat_slot = mat_slot,
				uv_scale = uv_scale,
				color    = color,
			}))
		}

		if convex_rebuild_bounds_and_prune(&hull, prune_redundant = true) {
			aabb_min.x = min(aabb_min.x, hull.aabb_min.x)
			aabb_min.y = min(aabb_min.y, hull.aabb_min.y)
			aabb_min.z = min(aabb_min.z, hull.aabb_min.z)
			aabb_max.x = max(aabb_max.x, hull.aabb_max.x)
			aabb_max.y = max(aabb_max.y, hull.aabb_max.y)
			aabb_max.z = max(aabb_max.z, hull.aabb_max.z)
			append(out_hulls, hull)
			built_any = true
		} else {
			convex_destroy(&hull)
		}
	}

	return aabb_min, aabb_max, built_any
}

// ============================================================================
// SABRECSG / REALTIMECSG 2-POINT CSG CLIP PLANE SLICER
// ============================================================================

CSG_Clip_Mode :: enum u8 {
	Split_Both = 0, // Slices straddling hulls into TWO separate watertight convex hulls (Front & Back halves)
	Keep_Back  = 1, // Shaves/clips off the +Normal side, keeping only `dot(n, x) <= dist`
	Keep_Front = 2, // Shaves/clips off the -Normal side, keeping only `dot(-n, x) <= -dist`
}

// Clips a single convex polyhedron `h` against an arbitrary cutting plane `(plane_normal, plane_dist)`.
// - If `h` does not straddle the plane, keeps `h` if it lies on the retained side (or discards it if on the clipped side).
// - If `h` straddles the plane, slices `h` cleanly along `(plane_normal, plane_dist)` with optional `split_gap`
//   and caps the freshly sliced face with `cap_color` / `cap_uv_scale`!
csg_clip_convex_by_plane :: proc(
	h:            CSG_Convex,
	plane_normal: [3]f32,
	plane_dist:   f32,
	mode:         CSG_Clip_Mode,
	out_list:     ^[dynamic]CSG_Convex,
	split_gap:    f32 = 0.0,
	alloc         := context.allocator,
	cap_mat_slot: u8 = 1,
	cap_color:    [4]u8 = {0, 0, 0, 0},
) -> (sliced: bool) {
	n := linalg.normalize0(plane_normal)
	if linalg.length2(n) < 0.5 {
		append(out_list, convex_clone(h, alloc))
		return false
	}

	verts := make([dynamic][3]f32, 0, 32, context.temp_allocator)
	convex_extract_vertices(h, &verts)
	if len(verts) < 4 {
		return false
	}

	min_s: f32 =  1e30
	max_s: f32 = -1e30
	for v in verts {
		s := linalg.dot(n, v) - plane_dist
		min_s = min(min_s, s)
		max_s = max(max_s, s)
	}

	// Non-straddling hull: either completely in Back (`max_s <= 1e-3`) or completely in Front (`min_s >= -1e-3`)
	if max_s <= 1e-3 {
		if mode == .Split_Both || mode == .Keep_Back {
			append(out_list, convex_clone(h, alloc))
		}
		return false
	}
	if min_s >= -1e-3 {
		if mode == .Split_Both || mode == .Keep_Front {
			append(out_list, convex_clone(h, alloc))
		}
		return false
	}

	// Hull straddles the cutting plane! Inherit surface properties from the first plane of `h`.
	ref_p := h.planes[0] if len(h.planes) > 0 else CSG_Plane{uv_scale = 0.5, color = {210, 216, 224, 255}}
	half_gap := clamp(split_gap * 0.5, 0.0, 0.5)
	eff_slot := cap_mat_slot if cap_mat_slot > 0 else 1
	eff_col  := cap_color if cap_color.a > 0 else (ref_p.color if (ref_p.color.r > 120 && ref_p.color.g < 60 && ref_p.color.b < 60) else [4]u8{255, 255, 255, 255})

	if mode == .Split_Both || mode == .Keep_Back {
		back_h := convex_clone(h, alloc)
		cap_back := quantize_plane(CSG_Plane{
			normal        = n,
			dist          = plane_dist - half_gap,
			mat_slot      = eff_slot,
			uv_scale      = ref_p.uv_scale,
			uv_offset     = ref_p.uv_offset,
			uv_rot_deg    = ref_p.uv_rot_deg,
			uv_lock_brush = false,
			color         = eff_col,
		})
		append(&back_h.planes, cap_back)
		if convex_rebuild_bounds_and_prune(&back_h, prune_redundant = true, min_extent = 0.015) {
			append(out_list, back_h)
			sliced = true
		} else {
			convex_destroy(&back_h)
		}
	}

	if mode == .Split_Both || mode == .Keep_Front {
		front_h := convex_clone(h, alloc)
		cap_front := quantize_plane(CSG_Plane{
			normal        = -n,
			dist          = -plane_dist - half_gap,
			mat_slot      = eff_slot,
			uv_scale      = ref_p.uv_scale,
			uv_offset     = ref_p.uv_offset,
			uv_rot_deg    = ref_p.uv_rot_deg,
			uv_lock_brush = false,
			color         = eff_col,
		})
		append(&front_h.planes, cap_front)
		if convex_rebuild_bounds_and_prune(&front_h, prune_redundant = true, min_extent = 0.015) {
			append(out_list, front_h)
			sliced = true
		} else {
			convex_destroy(&front_h)
		}
	}

	return sliced
}

// Clips a list of convex hulls in-place against `(plane_normal, plane_dist)` using `mode`.
// Returns the number of hulls that were actively sliced by the plane.
csg_clip_hull_list_by_plane :: proc(
	hulls:        ^[dynamic]CSG_Convex,
	plane_normal: [3]f32,
	plane_dist:   f32,
	mode:         CSG_Clip_Mode,
	split_gap:    f32 = 0.0,
	alloc         := context.allocator,
	cap_mat_slot: u8 = 1,
	cap_color:    [4]u8 = {0, 0, 0, 0},
) -> (sliced_count: int) {
	if hulls == nil || len(hulls^) == 0 do return 0
	next_list := make([dynamic]CSG_Convex, 0, len(hulls^) * 2, alloc)
	for &h in hulls^ {
		if csg_clip_convex_by_plane(h, plane_normal, plane_dist, mode, &next_list, split_gap, alloc, cap_mat_slot, cap_color) {
			sliced_count += 1
		}
		convex_destroy(&h)
	}
	delete(hulls^)
	hulls^ = next_list
	return sliced_count
}

