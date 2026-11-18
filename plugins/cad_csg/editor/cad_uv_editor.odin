package cad_csg_editor

// ============================================================================
// UV TOOL SUITE & 2D UV EDITOR WINDOW
// ============================================================================
// Complete UV Mapping, Unwrapping, Island Packing, Seams & 2D Visual UV Editor
// for Haati CAD Polygon Meshes & Unreal Modeling Mode workflows.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import gfx "haati:engine/gfx"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import cad_csg "haati:packages/cad_csg"

UV_Select_Mode :: enum u8 {
	Face   = 0,
	Vertex = 1,
	Island = 2,
}

UV_Drag_Mode :: enum u8 {
	None        = 0,
	Pan_Canvas  = 1,
	Move_Vertex = 2,
	Move_Face   = 3,
	Move_Island = 4,
	Box_Select  = 5,
}

@(private = "package")
_uv_ed: struct {
	initialized:         bool,
	pan:                 [2]f32,
	zoom:                f32,
	select_mode:         UV_Select_Mode,
	selected_face:       int,
	selected_corner:     int, // Corner index in `_mesh_ed.faces[selected_face].verts`
	selected_island:     [dynamic]int,
	hovered_face:        int,
	hovered_corner:      int,
	drag_mode:           UV_Drag_Mode,
	drag_start_screen:   [2]f32,
	drag_orig_uvs:       [dynamic][2]f32,
	has_drag_orig_uvs:   bool,

	// Canvas display toggles
	show_texture:        bool,
	show_checker:        bool,
	show_wireframe:      bool,
	show_vertex_dots:    bool,
	show_labels:         bool,
	grid_snap:           bool,
	grid_step:           f32, // 0.125 = 1/8 grid, 0.0625 = 1/16 grid

	// Live Unwrapper & Transformation sliders
	unwrap_scale:            f32,
	unwrap_padding:          f32,
	transform_selected_only: bool, // When true (default) and a face is selected, Rot/Flip/Scale/Fit only affect the selected face(s)!
	live_scale:              [2]f32,
	live_offset:             [2]f32,
	live_rot_deg:            f32,
	slider_snap_uvs:         [dynamic][2]f32,
	has_slider_snap:         bool,
	active_tex_guid:         engine.Asset_GUID,
}

@(private = "package")
_ensure_uv_ed_init :: proc() {
	if _uv_ed.initialized do return
	_uv_ed.initialized             = true
	_uv_ed.pan                     = {0, 0}
	_uv_ed.zoom                    = 320.0 // 320 pixels per 1.0 UV unit
	_uv_ed.select_mode             = .Face
	_uv_ed.selected_face           = -1
	_uv_ed.selected_corner         = -1
	_uv_ed.hovered_face            = -1
	_uv_ed.hovered_corner          = -1
	_uv_ed.drag_mode               = .None
	_uv_ed.show_texture            = true
	_uv_ed.show_checker            = true
	_uv_ed.show_wireframe          = true
	_uv_ed.show_vertex_dots        = true
	_uv_ed.show_labels             = true
	_uv_ed.grid_snap               = false
	_uv_ed.grid_step               = 0.125
	_uv_ed.unwrap_scale            = 1.0
	_uv_ed.unwrap_padding          = 0.02
	_uv_ed.transform_selected_only = true
	_uv_ed.live_scale              = {1.0, 1.0}
	_uv_ed.live_offset             = {0.0, 0.0}
	_uv_ed.live_rot_deg            = 0.0

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	_uv_ed.selected_island  = make([dynamic]int, 0, 16)
	_uv_ed.drag_orig_uvs    = make([dynamic][2]f32, 0, 16)
	_uv_ed.slider_snap_uvs  = make([dynamic][2]f32, 0, 64)
}

@(private = "package")
_uv_ed_release_cache :: proc() {
	if !_uv_ed.initialized do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev

	delete(_uv_ed.selected_island)
	delete(_uv_ed.drag_orig_uvs)
	delete(_uv_ed.slider_snap_uvs)
	_uv_ed.selected_island  = nil
	_uv_ed.drag_orig_uvs    = nil
	_uv_ed.slider_snap_uvs  = nil
	_uv_ed.has_drag_orig_uvs = false
	_uv_ed.has_slider_snap   = false
	_uv_ed.initialized       = false
}

// Opens the 2D UV Editor Window
open_uv_editor_window :: proc() {
	_ensure_uv_ed_init()
	wnd.open("uv_editor")
}

// ============================================================================
// UV UNWRAPPING & PROJECTION ALGORITHMS
// ============================================================================

// Cubic / Box Projection: Projects each face onto its closest cardinal axis (±X, ±Y, ±Z).
// Preserves metric proportions and eliminates stretching across all sides of a box, building, or room.
mesh_uv_unwrap_box :: proc(scale: f32 = 1.0, fit_01 := false) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 || len(_mesh_ed.verts) == 0 do return

	s := max(scale, 0.01)
	min_uv := [2]f32{ max(f32),  max(f32)}
	max_uv := [2]f32{-max(f32), -max(f32)}

	for &f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		_ensure_face_uvs(&f)
		fn, _ := _face_normal_and_center(f)
		ax := fn
		for vi, i in f.verts {
			if int(vi) >= len(_mesh_ed.verts) do continue
			p := _mesh_ed.verts[vi]
			uv := [2]f32{0, 0}
			if abs(ax.x) >= abs(ax.y) && abs(ax.x) >= abs(ax.z) {
				// Dominant ±X face: project onto YZ
				uv = [2]f32{p.z * (-1.0 if ax.x >= 0 else 1.0) * s, p.y * s}
			} else if abs(ax.y) >= abs(ax.x) && abs(ax.y) >= abs(ax.z) {
				// Dominant ±Y face: project onto XZ
				uv = [2]f32{p.x * s, p.z * (1.0 if ax.y >= 0 else -1.0) * s}
			} else {
				// Dominant ±Z face: project onto XY
				uv = [2]f32{p.x * (1.0 if ax.z >= 0 else -1.0) * s, p.y * s}
			}
			f.uvs[i] = uv
			min_uv = linalg.min(min_uv, uv)
			max_uv = linalg.max(max_uv, uv)
		}
	}

	if fit_01 {
		span := max_uv - min_uv
		span.x = max(span.x, 1e-4)
		span.y = max(span.y, 1e-4)
		for &f in _mesh_ed.faces {
			for &uv in f.uvs {
				uv = 0.02 + ((uv - min_uv) / span) * 0.96
			}
		}
	}

	_rebuild_editable_mesh_gpu(commit = true)
}

// Planar Projection: Projects the mesh (or selected faces) along axis (0=X, 1=Y, 2=Z, 3=Normal).
mesh_uv_unwrap_planar :: proc(axis: int, scale: f32 = 1.0, fit_01 := true, selected_only := false) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 || len(_mesh_ed.verts) == 0 do return

	s := max(scale, 0.01)
	min_uv := [2]f32{ max(f32),  max(f32)}
	max_uv := [2]f32{-max(f32), -max(f32)}

	for &f, fi in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		if selected_only && fi != _mesh_ed.selected_face do continue
		_ensure_face_uvs(&f)
		fn, _ := _face_normal_and_center(f)
		u_ax, v_ax := cad_csg.plane_tangent_basis(fn)

		for vi, i in f.verts {
			if int(vi) >= len(_mesh_ed.verts) do continue
			p := _mesh_ed.verts[vi]
			uv := [2]f32{0, 0}
			switch axis {
			case 0: uv = [2]f32{p.z * s, p.y * s} // X plane
			case 1: uv = [2]f32{p.x * s, p.z * s} // Y plane
			case 2: uv = [2]f32{p.x * s, p.y * s} // Z plane
			case:   uv = [2]f32{linalg.dot(p, u_ax) * s, linalg.dot(p, v_ax) * s} // Normal basis
			}
			f.uvs[i] = uv
			min_uv = linalg.min(min_uv, uv)
			max_uv = linalg.max(max_uv, uv)
		}
	}

	if fit_01 {
		span := max_uv - min_uv
		span.x = max(span.x, 1e-4)
		span.y = max(span.y, 1e-4)
		for &f, fi in _mesh_ed.faces {
			if selected_only && fi != _mesh_ed.selected_face do continue
			for &uv in f.uvs {
				uv = 0.02 + ((uv - min_uv) / span) * 0.96
			}
		}
	}

	_rebuild_editable_mesh_gpu(commit = true)
}

// Cylindrical Projection: Wraps UVs around an axis (default Y) with seamless wrap correction.
mesh_uv_unwrap_cylinder :: proc(axis: int = 1, fit_01 := true) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 || len(_mesh_ed.verts) == 0 do return

	c := _mesh_centroid()
	min_y := max(f32)
	max_y := -max(f32)
	for v in _mesh_ed.verts {
		min_y = min(min_y, v.y)
		max_y = max(max_y, v.y)
	}
	y_span := max(max_y - min_y, 0.01)

	for &f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		_ensure_face_uvs(&f)
		fn, _ := _face_normal_and_center(f)
		is_cap := abs(fn.y) > 0.88 // Top or bottom cap face

		if is_cap {
			// Project cap planar on XZ
			for vi, i in f.verts {
				if int(vi) >= len(_mesh_ed.verts) do continue
				p := _mesh_ed.verts[vi]
				f.uvs[i] = [2]f32{0.5 + (p.x - c.x) * 0.45, 0.5 + (p.z - c.z) * 0.45}
			}
		} else {
			// Cylinder tube: theta -> U, Y -> V
			for vi, i in f.verts {
				if int(vi) >= len(_mesh_ed.verts) do continue
				p := _mesh_ed.verts[vi]
				theta := math.atan2(p.z - c.z, p.x - c.x) // -pi .. pi
				u := (theta / (2.0 * math.PI)) + 0.5     // 0 .. 1
				v := (p.y - min_y) / y_span              // 0 .. 1
				f.uvs[i] = [2]f32{u, v}
			}

			// Seam wrap fix: if face crosses the -pi / +pi seam (delta U > 0.5), shift wrapped vertices
			has_left := false
			has_right := false
			for uv in f.uvs {
				if uv.x < 0.25 do has_left = true
				if uv.x > 0.75 do has_right = true
			}
			if has_left && has_right {
				for &uv in f.uvs {
					if uv.x < 0.25 do uv.x += 1.0
				}
			}
		}
	}

	if fit_01 {
		mesh_uv_pack_islands(0.02)
	} else {
		_rebuild_editable_mesh_gpu(commit = true)
	}
}

// Spherical Projection: Maps longitude theta and latitude phi into UV [0, 1].
mesh_uv_unwrap_sphere :: proc(fit_01 := true) {
	_ensure_mesh_ed_init()
	if len(_mesh_ed.faces) == 0 || len(_mesh_ed.verts) == 0 do return

	c := _mesh_centroid()
	for &f in _mesh_ed.faces {
		if len(f.verts) < 3 do continue
		_ensure_face_uvs(&f)
		for vi, i in f.verts {
			if int(vi) >= len(_mesh_ed.verts) do continue
			p := _mesh_ed.verts[vi] - c
			r := linalg.length(p)
			if r < 1e-4 { f.uvs[i] = {0.5, 0.5}; continue }
			theta := math.atan2(p.z, p.x)
			phi   := math.asin(clamp(p.y / r, -1.0, 1.0))
			u := (theta / (2.0 * math.PI)) + 0.5
			v := (phi / math.PI) + 0.5
			f.uvs[i] = [2]f32{u, v}
		}

		// Seam wrap fix across -pi / +pi
		has_left := false
		has_right := false
		for uv in f.uvs {
			if uv.x < 0.25 do has_left = true
			if uv.x > 0.75 do has_right = true
		}
		if has_left && has_right {
			for &uv in f.uvs {
				if uv.x < 0.25 do uv.x += 1.0
			}
		}
	}

	if fit_01 {
		mesh_uv_fit_01()
	} else {
		_rebuild_editable_mesh_gpu(commit = true)
	}
}

// Clusters connected faces into UV Islands (splitting at sharp edges > 48° or marked UV seams),
// unfolds each island into 2D, and packs all islands into [0, 1] texture space!
mesh_uv_auto_unwrap_islands :: proc(margin: f32 = 0.02) {
	_ensure_mesh_ed_init()
	fn_count := len(_mesh_ed.faces)
	if fn_count == 0 do return

	// 1. Partition faces into disjoint UV Islands
	visited := make([]bool, fn_count, context.temp_allocator)
	islands := make([dynamic][dynamic]int, 0, 8, context.temp_allocator)

	is_seam_edge :: proc(u, v: u32) -> bool {
		a := min(u, v); b := max(u, v)
		for s in _mesh_ed.uv_seams {
			if min(s[0], s[1]) == a && max(s[0], s[1]) == b do return true
		}
		return false
	}

	queue := make([dynamic]int, 0, 16, context.temp_allocator)
	for start_f := 0; start_f < fn_count; start_f += 1 {
		if visited[start_f] do continue
		visited[start_f] = true
		island := make([dynamic]int, 0, 16, context.temp_allocator)
		append(&island, start_f)
		clear(&queue)
		append(&queue, start_f)

		for len(queue) > 0 {
			curr_f := pop(&queue)
			n_curr, _ := _face_normal_and_center(_mesh_ed.faces[curr_f])

			// Check all neighbor faces sharing an edge
			for e_i := 0; e_i < len(_mesh_ed.faces[curr_f].verts); e_i += 1 {
				u := _mesh_ed.faces[curr_f].verts[e_i]
				v := _mesh_ed.faces[curr_f].verts[(e_i + 1) % len(_mesh_ed.faces[curr_f].verts)]
				if is_seam_edge(u, v) do continue // Stop at marked seam!

				for other_f := 0; other_f < fn_count; other_f += 1 {
					if visited[other_f] do continue
					// Does other_f share edge (u, v)?
					shares := false
					for o_i := 0; o_i < len(_mesh_ed.faces[other_f].verts); o_i += 1 {
						ou := _mesh_ed.faces[other_f].verts[o_i]
						ov := _mesh_ed.faces[other_f].verts[(o_i + 1) % len(_mesh_ed.faces[other_f].verts)]
						if (ou == v && ov == u) || (ou == u && ov == v) {
							shares = true
							break
						}
					}
					if shares {
						n_other, _ := _face_normal_and_center(_mesh_ed.faces[other_f])
						// Check angle threshold (dihedral angle < 50 degrees)
						if linalg.dot(n_curr, n_other) > 0.65 {
							visited[other_f] = true
							append(&island, other_f)
							append(&queue, other_f)
						}
					}
				}
			}
		}
		append(&islands, island)
	}

	// 2. Unfold each island into 2D via best-fit tangent basis projection
	for island in islands {
		if len(island) == 0 do continue
		avg_n: [3]f32
		avg_c: [3]f32
		for fi in island {
			n_f, c_f := _face_normal_and_center(_mesh_ed.faces[fi])
			avg_n += n_f
			avg_c += c_f
		}
		avg_n = linalg.normalize0(avg_n)
		avg_c /= f32(len(island))
		u_ax, v_ax := cad_csg.plane_tangent_basis(avg_n)

		for fi in island {
			f := &_mesh_ed.faces[fi]
			_ensure_face_uvs(f)
			for vi, idx in f.verts {
				if int(vi) < len(_mesh_ed.verts) {
					p := _mesh_ed.verts[vi] - avg_c
					f.uvs[idx] = [2]f32{linalg.dot(p, u_ax), linalg.dot(p, v_ax)}
				}
			}
		}
	}

	// 3. Pack all islands into [0, 1] texture space!
	mesh_uv_pack_islands(margin)
}

// 2D Bin Packing: Arranges and scales all disjoint UV islands neatly within [0, 1] x [0, 1] texture space.
mesh_uv_pack_islands :: proc(padding: f32 = 0.02) {
	_ensure_mesh_ed_init()
	fn_count := len(_mesh_ed.faces)
	if fn_count == 0 do return

	// Group faces into islands sharing UV coordinates
	visited := make([]bool, fn_count, context.temp_allocator)
	islands := make([dynamic][dynamic]int, 0, 8, context.temp_allocator)

	for start := 0; start < fn_count; start += 1 {
		if visited[start] do continue
		visited[start] = true
		island := make([dynamic]int, 0, 8, context.temp_allocator)
		append(&island, start)
		queue := make([dynamic]int, 0, 8, context.temp_allocator)
		append(&queue, start)

		for len(queue) > 0 {
			curr := pop(&queue)
			f_curr := &_mesh_ed.faces[curr]
			_ensure_face_uvs(f_curr)

			for other := 0; other < fn_count; other += 1 {
				if visited[other] do continue
				f_other := &_mesh_ed.faces[other]
				_ensure_face_uvs(f_other)

				// Check if curr and other share any UV point
				shares_uv := false
				for uva in f_curr.uvs {
					for uvb in f_other.uvs {
						if linalg.length2(uva - uvb) <= 1e-4 {
							shares_uv = true
							break
						}
					}
					if shares_uv do break
				}
				if shares_uv {
					visited[other] = true
					append(&island, other)
					append(&queue, other)
				}
			}
		}
		append(&islands, island)
	}

	if len(islands) == 0 do return

	// Island bounds info for bin packing
	Island_Box :: struct {
		indices: []int,
		min_uv:  [2]f32,
		max_uv:  [2]f32,
		size:    [2]f32,
		place:   [2]f32,
	}
	boxes := make([]Island_Box, len(islands), context.temp_allocator)
	for island, i in islands {
		b_min := [2]f32{ max(f32),  max(f32)}
		b_max := [2]f32{-max(f32), -max(f32)}
		for fi in island {
			for uv in _mesh_ed.faces[fi].uvs {
				b_min = linalg.min(b_min, uv)
				b_max = linalg.max(b_max, uv)
			}
		}
		sz := b_max - b_min
		sz.x = max(sz.x, 0.001)
		sz.y = max(sz.y, 0.001)
		boxes[i] = Island_Box{
			indices = island[:],
			min_uv  = b_min,
			max_uv  = b_max,
			size    = sz,
		}
	}

	// Sort islands by height descending for tight row packing
	slice.sort_by(boxes, proc(a, b: Island_Box) -> bool {
		return a.size.y > b.size.y
	})

	// Row-based shelf packer
	pad := clamp(padding, 0.005, 0.10)
	cur_x: f32 = pad
	cur_y: f32 = pad
	row_h: f32 = 0
	max_w: f32 = pad
	max_h: f32 = pad

	cols := int(math.ceil(math.sqrt(f32(len(boxes)))))
	target_row_w: f32 = 0
	for b in boxes do target_row_w += b.size.x
	target_row_w = max(target_row_w / f32(max(cols, 1)), 0.1)

	for &b in boxes {
		if cur_x + b.size.x > target_row_w && cur_x > pad {
			cur_x = pad
			cur_y += row_h + pad
			row_h = 0
		}
		b.place = {cur_x, cur_y}
		cur_x += b.size.x + pad
		row_h = max(row_h, b.size.y)
		max_w = max(max_w, cur_x)
		max_h = max(max_h, cur_y + row_h + pad)
	}

	// Scale and normalize all placed islands uniformly into [pad, 1 - pad]
	scale_factor := min((1.0 - pad * 2.0) / max(max_w, 0.01), (1.0 - pad * 2.0) / max(max_h, 0.01))
	for b in boxes {
		for fi in b.indices {
			for &uv in _mesh_ed.faces[fi].uvs {
				rel := uv - b.min_uv
				uv = pad + (b.place + rel) * scale_factor
			}
		}
	}

	_rebuild_editable_mesh_gpu(commit = true)
}

// Mark / Unmark selected edge as a UV Seam (visible in 3D in bright neon orange!)
mesh_uv_toggle_selected_edge_seam :: proc() {
	_ensure_mesh_ed_init()
	if _mesh_ed.select_mode != .Edge || !_mesh_ed.has_selected_edge do return
	u := min(_mesh_ed.selected_edge[0], _mesh_ed.selected_edge[1])
	v := max(_mesh_ed.selected_edge[0], _mesh_ed.selected_edge[1])

	found_idx := -1
	for s, i in _mesh_ed.uv_seams {
		if s[0] == u && s[1] == v {
			found_idx = i
			break
		}
	}

	if found_idx >= 0 {
		ordered_remove(&_mesh_ed.uv_seams, found_idx)
	} else {
		append(&_mesh_ed.uv_seams, [2]u32{u, v})
	}
}

mesh_uv_clear_all_seams :: proc() {
	_ensure_mesh_ed_init()
	clear(&_mesh_ed.uv_seams)
}

// Returns true if any face is currently selected in the UV / Mesh editor.
@(private = "package")
_uv_has_face_selection :: proc() -> bool {
	if _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) do return true
	if len(_mesh_ed.sel_faces) > 0 do return true
	if len(_uv_ed.selected_island) > 0 do return true
	return false
}

// Checks whether face `fi` should be affected by a UV operation.
@(private = "package")
_uv_is_face_targeted :: proc(fi: int, selected_only: bool) -> bool {
	if !selected_only || !_uv_has_face_selection() do return true
	if _uv_ed.select_mode == .Island && len(_uv_ed.selected_island) > 0 {
		for idx in _uv_ed.selected_island {
			if idx == fi do return true
		}
	}
	if len(_mesh_ed.sel_faces) > 0 {
		for idx in _mesh_ed.sel_faces {
			if idx == fi do return true
		}
	}
	return fi == _mesh_ed.selected_face
}

// Computes the UV bounding box `(min_uv, max_uv)` and center `c` of the targeted face(s).
// Crucial: rotating or mirroring a single face must pivot around THAT face's own UV center, not `{0.5, 0.5}`!
@(private = "package")
_uv_compute_target_bounds :: proc(selected_only: bool) -> (center, min_uv, max_uv: [2]f32) {
	min_uv = { max(f32),  max(f32)}
	max_uv = {-max(f32), -max(f32)}
	count := 0
	for &f, fi in _mesh_ed.faces {
		if !_uv_is_face_targeted(fi, selected_only) do continue
		_ensure_face_uvs(&f)
		for uv in f.uvs {
			min_uv = linalg.min(min_uv, uv)
			max_uv = linalg.max(max_uv, uv)
			count += 1
		}
	}
	if count == 0 {
		return {0.5, 0.5}, {0.0, 0.0}, {1.0, 1.0}
	}
	return (min_uv + max_uv) * 0.5, min_uv, max_uv
}

// Collects all faces belonging to the same UV island (connected in UV space) as `seed_face`.
@(private = "package")
_uv_collect_connected_island :: proc(seed_face: int, out_island: ^[dynamic]int) {
	clear(out_island)
	fn_count := len(_mesh_ed.faces)
	if seed_face < 0 || seed_face >= fn_count do return

	visited := make([]bool, fn_count, context.temp_allocator)
	queue   := make([dynamic]int, 0, 16, context.temp_allocator)
	visited[seed_face] = true
	append(out_island, seed_face)
	append(&queue, seed_face)

	for len(queue) > 0 {
		curr := pop(&queue)
		f_curr := &_mesh_ed.faces[curr]
		_ensure_face_uvs(f_curr)
		for other := 0; other < fn_count; other += 1 {
			if visited[other] do continue
			f_other := &_mesh_ed.faces[other]
			_ensure_face_uvs(f_other)
			shares_uv := false
			for uva in f_curr.uvs {
				for uvb in f_other.uvs {
					if linalg.length2(uva - uvb) <= 1e-4 {
						shares_uv = true
						break
					}
				}
				if shares_uv do break
			}
			if shares_uv {
				visited[other] = true
				append(out_island, other)
				append(&queue, other)
			}
		}
	}
}

// Quick UV Transform tools (automatically target the selected face(s) when `_uv_ed.transform_selected_only` is true!)
mesh_uv_fit_01 :: proc(selected_only_override := false) {
	_ensure_mesh_ed_init()
	_ensure_uv_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	sel_only := selected_only_override || (_uv_ed.transform_selected_only && _uv_has_face_selection())
	_, min_uv, max_uv := _uv_compute_target_bounds(sel_only)
	span := max_uv - min_uv
	span.x = max(span.x, 1e-4)
	span.y = max(span.y, 1e-4)
	for &f, fi in _mesh_ed.faces {
		if !_uv_is_face_targeted(fi, sel_only) do continue
		for &uv in f.uvs {
			uv = 0.02 + ((uv - min_uv) / span) * 0.96
		}
	}
	_rebuild_editable_mesh_gpu(commit = true)
}

mesh_uv_rotate_90 :: proc(clockwise := true, selected_only_override := false) {
	_ensure_mesh_ed_init()
	_ensure_uv_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	sel_only := selected_only_override || (_uv_ed.transform_selected_only && _uv_has_face_selection())
	c, _, _ := _uv_compute_target_bounds(sel_only)
	for &f, fi in _mesh_ed.faces {
		if !_uv_is_face_targeted(fi, sel_only) do continue
		for &uv in f.uvs {
			rel := uv - c
			if clockwise {
				uv = c + [2]f32{rel.y, -rel.x}
			} else {
				uv = c + [2]f32{-rel.y, rel.x}
			}
		}
	}
	_rebuild_editable_mesh_gpu(commit = true)
}

mesh_uv_flip :: proc(flip_u, flip_v: bool, selected_only_override := false) {
	_ensure_mesh_ed_init()
	_ensure_uv_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	sel_only := selected_only_override || (_uv_ed.transform_selected_only && _uv_has_face_selection())
	c, _, _ := _uv_compute_target_bounds(sel_only)
	for &f, fi in _mesh_ed.faces {
		if !_uv_is_face_targeted(fi, sel_only) do continue
		for &uv in f.uvs {
			if flip_u do uv.x = c.x - (uv.x - c.x)
			if flip_v do uv.y = c.y - (uv.y - c.y)
		}
	}
	_rebuild_editable_mesh_gpu(commit = true)
}

mesh_uv_transform :: proc(scale, offset: [2]f32, rot_deg: f32, selected_only := false, commit := true) {
	_ensure_mesh_ed_init()
	_ensure_uv_ed_init()
	if len(_mesh_ed.faces) == 0 do return
	rad := rot_deg * (math.PI / 180.0)
	cos_a := math.cos(rad)
	sin_a := math.sin(rad)
	c, _, _ := _uv_compute_target_bounds(selected_only)

	for &f, fi in _mesh_ed.faces {
		if !_uv_is_face_targeted(fi, selected_only) do continue
		for &uv in f.uvs {
			rel := (uv - c) * scale
			rot := [2]f32{rel.x * cos_a - rel.y * sin_a, rel.x * sin_a + rel.y * cos_a}
			uv = c + rot + offset
		}
	}
	_rebuild_editable_mesh_gpu(commit = commit)
}

@(private = "package")
_uv_snapshot_slider_base :: proc() {
	_ensure_uv_ed_init()
	clear(&_uv_ed.slider_snap_uvs)
	for &f in _mesh_ed.faces {
		_ensure_face_uvs(&f)
		append(&_uv_ed.slider_snap_uvs, ..f.uvs[:])
	}
	_uv_ed.has_slider_snap = true
}

@(private = "package")
_uv_restore_and_apply_slider :: proc(commit: bool) {
	if !_uv_ed.has_slider_snap do _uv_snapshot_slider_base()
	off := 0
	for &f in _mesh_ed.faces {
		_ensure_face_uvs(&f)
		n := len(f.uvs)
		if off + n <= len(_uv_ed.slider_snap_uvs) {
			copy(f.uvs[:], _uv_ed.slider_snap_uvs[off:off + n])
		}
		off += n
	}
	sel_only := _uv_ed.transform_selected_only && _uv_has_face_selection()
	mesh_uv_transform(_uv_ed.live_scale, _uv_ed.live_offset, _uv_ed.live_rot_deg, selected_only = sel_only, commit = commit)
	if commit {
		_uv_ed.has_slider_snap = false
		_uv_ed.live_scale   = {1.0, 1.0}
		_uv_ed.live_offset  = {0.0, 0.0}
		_uv_ed.live_rot_deg = 0.0
	}
}

// ============================================================================
// 2D UV EDITOR WINDOW & INTERACTIVE CANVAS
// ============================================================================

@(editor_window={id="uv_editor", title="UV Editor", icon="IMAGE", width=880, height=640})
draw_uv_editor_window :: proc() {
	_ensure_uv_ed_init()
	_ensure_mesh_ed_init()
	_sync_mesh_editor_with_selection()

	w := engine.ctx_world()
	if w == nil || _mesh_ed.target_owner == {} || len(_mesh_ed.faces) == 0 {
		im.TextColored({1.0, 0.75, 0.25, 1.0}, "No editable mesh selected in Scene3D.")
		im.TextDisabled("Select any object with a MeshFilter / CSGVolume in Scene3D or spawn a primitive from CAD Mode.")
		return
	}

	// 1. Top Toolbar: Unwrapping shortcuts & display toggles
	_draw_uv_toolbar()
	im.Separator()

	// 2. Main split view: Interactive 2D UV Canvas (left) + UV Inspector panel (right)
	avail := im.GetContentRegionAvail()
	panel_w: f32 = 256.0
	canvas_w := max(avail.x - panel_w - 8.0, 64.0)
	canvas_h := max(avail.y - 4.0, 64.0)

	_draw_uv_canvas({canvas_w, canvas_h})
	im.SameLine(0, 8)
	_draw_uv_inspector(panel_w)
}

@(private = "file")
_draw_uv_toolbar :: proc() {
	// Mode selector: Face / Vertex / Island
	mode_names := [3]cstring{"Face", "Vertex", "Island"}
	cur_m := int(_uv_ed.select_mode)
	im.SetNextItemWidth(92)
	if im.BeginCombo("Select##uv_sel", mode_names[cur_m]) {
		for m_name, idx in mode_names {
			if im.Selectable(m_name, cur_m == idx) {
				_uv_ed.select_mode = UV_Select_Mode(idx)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("UV Selection Mode: select individual UV faces, corner vertices, or connected UV islands (Shift+Click multi-selects faces!)")

	im.SameLine(0, 6)
	if im.Button("Unwrap##btn") do im.OpenPopup("uv_unwrap_popup")
	if im.BeginPopup("uv_unwrap_popup") {
		im.TextColored({0.35, 0.90, 1.0, 1.0}, "UV Unwrapping Methods:")
		if im.MenuItem("Box (Cubic) Unwrap") do mesh_uv_unwrap_box(_uv_ed.unwrap_scale, fit_01 = true)
		if im.MenuItem("Planar Unwrap (View / Normal)") do mesh_uv_unwrap_planar(3, _uv_ed.unwrap_scale, fit_01 = true)
		if im.MenuItem("Planar X Plane") do mesh_uv_unwrap_planar(0, _uv_ed.unwrap_scale, fit_01 = true)
		if im.MenuItem("Planar Y Plane (Top / Ground)") do mesh_uv_unwrap_planar(1, _uv_ed.unwrap_scale, fit_01 = true)
		if im.MenuItem("Planar Z Plane (Front)") do mesh_uv_unwrap_planar(2, _uv_ed.unwrap_scale, fit_01 = true)
		if im.MenuItem("Cylindrical Unwrap (Pillar / Tube)") do mesh_uv_unwrap_cylinder(1, fit_01 = true)
		if im.MenuItem("Spherical Unwrap") do mesh_uv_unwrap_sphere(fit_01 = true)
		im.Separator()
		if im.MenuItem("Auto-Unwrap Islands (Conformal / LSCM)") do mesh_uv_auto_unwrap_islands(_uv_ed.unwrap_padding)
		if im.MenuItem("Pack UV Islands into [0, 1]") do mesh_uv_pack_islands(_uv_ed.unwrap_padding)
		im.EndPopup()
	}
	widgets.tooltip("Choose an automatic UV projection or conformal island unwrap method")

	im.SameLine(0, 4)
	if im.Button("Pack") do mesh_uv_pack_islands(_uv_ed.unwrap_padding)
	widgets.tooltip("Pack all UV islands into [0, 1] texture space without overlapping")

	im.SameLine(0, 4)
	if im.Button("Fit 0-1") do mesh_uv_fit_01()
	widgets.tooltip("Normalize selected face(s) (or all UVs if none selected) to fit the [0, 1] texture bounds")

	im.SameLine(0, 4)
	if im.Button("Rot -90°") do mesh_uv_rotate_90(false)
	widgets.tooltip("Rotate selected face(s) (or all UVs) 90 degrees counter-clockwise around their UV center (Shortcut: Shift+R)")

	im.SameLine(0, 4)
	if im.Button("Rot +90°") do mesh_uv_rotate_90(true)
	widgets.tooltip("Rotate selected face(s) (or all UVs) 90 degrees clockwise around their UV center (Shortcut: R)")

	im.SameLine(0, 4)
	if im.Button("Mirror U") do mesh_uv_flip(true, false)
	widgets.tooltip("Mirror / flip selected face(s) (or all UVs) horizontally in-place around their UV center (Shortcut: H)")

	im.SameLine(0, 4)
	if im.Button("Mirror V") do mesh_uv_flip(false, true)
	widgets.tooltip("Mirror / flip selected face(s) (or all UVs) vertically in-place around their UV center (Shortcut: V)")

	im.SameLine(0, 8)
	im.Checkbox("Selected Only", &_uv_ed.transform_selected_only)
	widgets.tooltip("When checked, Rotate / Mirror / Scale / Fit operate ONLY on the currently selected face(s) around that face's UV center! Uncheck to transform the entire mesh at once.")

	im.SameLine(0, 8)
	im.Checkbox("Snap", &_uv_ed.grid_snap)
	widgets.tooltip("Snap UV vertices to the texture grid while dragging")

	im.SameLine(0, 8)
	im.Checkbox("Tex", &_uv_ed.show_texture)
	widgets.tooltip("Display active material's texture in the UV canvas background")

	im.SameLine(0, 8)
	im.Checkbox("Chk", &_uv_ed.show_checker)
	widgets.tooltip("Display 8x8 checkerboard in [0, 1] texture bounds")

	im.SameLine(0, 8)
	if im.Button("Frame (F)") {
		_uv_ed.pan  = {0, 0}
		_uv_ed.zoom = 320.0
	}
	widgets.tooltip("Reset UV canvas zoom and center [0, 1] in view")
}

@(private = "file")
_draw_uv_canvas :: proc(size: im.Vec2) {
	if !im.BeginChild("##uv_canvas_child", size, {.Borders}, {.NoScrollbar, .NoScrollWithMouse}) {
		im.EndChild()
		return
	}
	defer im.EndChild()

	origin := im.GetCursorScreenPos()
	region := im.GetContentRegionAvail()
	if region.x < 16.0 || region.y < 16.0 {
		return
	}
	dl := im.GetWindowDrawList()

	// Background fill
	im.DrawList_AddRectFilled(dl, origin, {origin.x + region.x, origin.y + region.y}, 0xFF141414)

	// Coordinate transform helpers
	// UV (0,0) is bottom-left, (1,1) is top-right in standard texture space
	center_origin := im.Vec2{
		origin.x + region.x * 0.5 + _uv_ed.pan.x - _uv_ed.zoom * 0.5,
		origin.y + region.y * 0.5 + _uv_ed.pan.y - _uv_ed.zoom * 0.5,
	}

	uv_to_screen :: proc(uv: [2]f32, o: im.Vec2, zoom: f32) -> im.Vec2 {
		return {o.x + uv.x * zoom, o.y + (1.0 - uv.y) * zoom}
	}

	screen_to_uv :: proc(screen: im.Vec2, o: im.Vec2, zoom: f32) -> [2]f32 {
		return {
			(screen.x - o.x) / max(zoom, 1.0),
			1.0 - (screen.y - o.y) / max(zoom, 1.0),
		}
	}

	p0 := uv_to_screen({0, 0}, center_origin, _uv_ed.zoom)
	p1 := uv_to_screen({1, 1}, center_origin, _uv_ed.zoom)
	box_min := im.Vec2{min(p0.x, p1.x), min(p0.y, p1.y)}
	box_max := im.Vec2{max(p0.x, p1.x), max(p0.y, p1.y)}

	// 1. Draw Checkerboard in [0, 1] x [0, 1] texture space
	if _uv_ed.show_checker {
		chk_n := 8
		step := _uv_ed.zoom / f32(chk_n)
		for r in 0 ..< chk_n {
			for c in 0 ..< chk_n {
				col: u32 = 0xFF222222 if ((r + c) % 2 == 0) else 0xFF2C2C2C
				c0 := im.Vec2{box_min.x + f32(c) * step, box_min.y + f32(r) * step}
				c1 := im.Vec2{c0.x + step, c0.y + step}
				im.DrawList_AddRectFilled(dl, c0, c1, col)
			}
		}
	}

	// 2. Draw Material Texture if assigned to the target entity
	if _uv_ed.show_texture {
		if _, mr := engine.transform_get_comp(_mesh_ed.target_owner, engine.MeshRenderer); mr != nil && len(mr.materials) > 0 {
			if mat, mat_ok := engine.material_load(mr.materials[0]); mat_ok && mat != nil && !engine.asset_guid_is_empty(mat.texture) {
				if tex, ok := engine.texture_load(mat.texture); ok && tex != nil && tex.gfx.gpu != nil {
					tex_id := im.TextureID(uintptr(gfx.texture_imgui_id(tex.gfx)))
					im.DrawList_AddImage(dl, im.TextureRef{_TexID = tex_id}, box_min, box_max, {0, 0}, {1, 1}, 0xCCFFFFFF)
				}
			}
		}
	}

	// 3. Draw Grid Lines inside [0, 1] (at 0.25, 0.5, 0.75)
	grid_col: u32 = 0x44607080
	for g in 1 ..< 4 {
		t := f32(g) * 0.25
		im.DrawList_AddLine(dl, uv_to_screen({t, 0}, center_origin, _uv_ed.zoom), uv_to_screen({t, 1}, center_origin, _uv_ed.zoom), grid_col, 1.0)
		im.DrawList_AddLine(dl, uv_to_screen({0, t}, center_origin, _uv_ed.zoom), uv_to_screen({1, t}, center_origin, _uv_ed.zoom), grid_col, 1.0)
	}

	// 4. Draw [0, 1] Texture Boundary Border
	im.DrawList_AddRect(dl, box_min, box_max, 0xFF00D4FF, 0, 2.0)
	if _uv_ed.show_labels {
		im.DrawList_AddText(dl, {box_min.x + 4, box_max.y - 18}, 0xAA00D4FF, "(0, 0)")
		im.DrawList_AddText(dl, {box_max.x - 42, box_max.y - 18}, 0xAA00D4FF, "(1, 0)")
		im.DrawList_AddText(dl, {box_min.x + 4, box_min.y + 4}, 0xAA00D4FF, "(0, 1)")
		im.DrawList_AddText(dl, {box_max.x - 42, box_min.y + 4}, 0xAA00D4FF, "(1, 1)")
	}

	// 5. Draw Mesh UV Polygons
	mouse := im.GetMousePos()
	hov_face := -1
	hov_corner := -1
	best_dist2: f32 = 49.0 // 7px hit radius for vertex dots

	for fi := 0; fi < len(_mesh_ed.faces); fi += 1 {
		f := &_mesh_ed.faces[fi]
		m := len(f.verts)
		if m < 3 do continue
		_ensure_face_uvs(f)

		is_sel := _uv_has_face_selection() && _uv_is_face_targeted(fi, true)
		poly_pts := make([]im.Vec2, m, context.temp_allocator)
		for i := 0; i < m; i += 1 {
			uv_pt := f.uvs[i] if i < len(f.uvs) else [2]f32{0, 0}
			poly_pts[i] = uv_to_screen(uv_pt, center_origin, _uv_ed.zoom)
			d2 := linalg.length2(poly_pts[i] - mouse)
			if d2 < best_dist2 {
				best_dist2 = d2
				hov_face = fi
				hov_corner = i
			}
		}

		// Face hit test via 2D point-in-polygon
		if hov_face < 0 && _is_point_in_2d_poly(mouse, poly_pts) {
			hov_face = fi
		}

		// Colors
		fill_col: u32 = 0x223580AA
		border_col: u32 = 0x8845B0DD
		thick: f32 = 1.0

		if is_sel {
			fill_col   = 0x5500D0FF // Bright Gold
			border_col = 0xFF00E5FF
			thick      = 2.2
		} else if fi == _uv_ed.hovered_face {
			fill_col   = 0x4420D080
			border_col = 0xFF30F0A0
			thick      = 1.5
		}

		// Convex/fan fill
		for t := 1; t < m - 1; t += 1 {
			im.DrawList_AddTriangleFilled(dl, poly_pts[0], poly_pts[t], poly_pts[t + 1], fill_col)
		}
		// Border polyline
		for i := 0; i < m; i += 1 {
			next := (i + 1) % m
			im.DrawList_AddLine(dl, poly_pts[i], poly_pts[next], border_col, thick)
		}

		// Vertex dots
		if _uv_ed.show_vertex_dots {
			for i := 0; i < m; i += 1 {
				pt := poly_pts[i]
				dot_col: u32 = 0xBB80D0FF
				rad: f32 = 3.0
				if is_sel {
					dot_col = 0xFF00E5FF
					rad     = 4.5
				}
				if fi == _uv_ed.hovered_face && i == _uv_ed.hovered_corner {
					dot_col = 0xFFFFFFFF
					rad     = 6.0
				}
				im.DrawList_AddCircleFilled(dl, pt, rad, dot_col)
			}
		}
	}
	_uv_ed.hovered_face = hov_face
	_uv_ed.hovered_corner = hov_corner

	// Draw Pivot Marker on the selected face(s) so the user sees the exact rotation/mirror center!
	if _uv_has_face_selection() {
		piv_uv, _, _ := _uv_compute_target_bounds(true)
		piv_scr := uv_to_screen(piv_uv, center_origin, _uv_ed.zoom)
		im.DrawList_AddCircle(dl, piv_scr, 6.0, 0xFF00FFAA, 16, 1.8)
		im.DrawList_AddLine(dl, {piv_scr.x - 8, piv_scr.y}, {piv_scr.x + 8, piv_scr.y}, 0xFF00FFAA, 1.5)
		im.DrawList_AddLine(dl, {piv_scr.x, piv_scr.y - 8}, {piv_scr.x, piv_scr.y + 8}, 0xFF00FFAA, 1.5)
	}

	// 6. Interactive Canvas Controls (Pan, Zoom, Drag UVs, Keyboard Shortcuts)
	im.SetCursorScreenPos(origin)
	im.InvisibleButton("##uv_canvas_btn", region)
	canvas_hovered := im.IsItemHovered()

	if canvas_hovered {
		// Zoom with Mouse Wheel centered on cursor
		wheel := im.GetIO().MouseWheel
		if wheel != 0 && !im.GetIO().KeyCtrl {
			zoom_factor: f32 = 1.15 if wheel > 0 else (1.0 / 1.15)
			mouse_uv := screen_to_uv(mouse, center_origin, _uv_ed.zoom)
			_uv_ed.zoom = clamp(_uv_ed.zoom * zoom_factor, 40.0, 3000.0)
			// Adjust pan so mouse_uv stays in the same screen spot
			new_screen := uv_to_screen(mouse_uv, center_origin, _uv_ed.zoom)
			_uv_ed.pan += mouse - new_screen
		}

		// Pan with MMB or RMB drag
		if im.IsMouseDragging(.Middle, 0) || im.IsMouseDragging(.Right, 1) {
			_uv_ed.pan += im.GetIO().MouseDelta
		}

		// Per-Face Keyboard Shortcuts when hovering the UV Canvas:
		// R = Rotate 90° (Shift+R = -90°), H = Mirror U (Horizontal), V = Mirror V (Vertical)
		if !im.GetIO().WantTextInput {
			if im.IsKeyPressed(.R, false) {
				mesh_uv_rotate_90(clockwise = !im.GetIO().KeyShift, selected_only_override = true)
			}
			if im.IsKeyPressed(.H, false) {
				mesh_uv_flip(true, false, selected_only_override = true)
			}
			if im.IsKeyPressed(.V, false) {
				mesh_uv_flip(false, true, selected_only_override = true)
			}
		}
	}

	// Click to Select & Start Drag
	if im.IsItemActivated() {
		if hov_face >= 0 {
			if im.GetIO().KeyShift {
				found_sf := false
				for sf, sfi in _mesh_ed.sel_faces {
					if sf == hov_face {
						ordered_remove(&_mesh_ed.sel_faces, sfi)
						found_sf = true
						break
					}
				}
				if !found_sf {
					append(&_mesh_ed.sel_faces, hov_face)
				}
				_mesh_ed.selected_face = hov_face
				_uv_ed.selected_face   = hov_face
			} else {
				in_sel := false
				for sf in _mesh_ed.sel_faces {
					if sf == hov_face {
						in_sel = true
						break
					}
				}
				if !in_sel {
					clear(&_mesh_ed.sel_faces)
					append(&_mesh_ed.sel_faces, hov_face)
				}
				_mesh_ed.selected_face = hov_face
				_uv_ed.selected_face   = hov_face
			}
			_uv_ed.selected_corner = hov_corner
			_uv_ed.drag_start_screen = mouse
			_uv_ed.has_drag_orig_uvs = true

			if _uv_ed.select_mode == .Island {
				_uv_collect_connected_island(hov_face, &_uv_ed.selected_island)
			} else {
				clear(&_uv_ed.selected_island)
			}

			// Snapshot ALL faces' original UVs so multi-face and island dragging work cleanly!
			clear(&_uv_ed.drag_orig_uvs)
			for &f_it in _mesh_ed.faces {
				_ensure_face_uvs(&f_it)
				append(&_uv_ed.drag_orig_uvs, ..f_it.uvs[:])
			}

			if hov_corner >= 0 && _uv_ed.select_mode == .Vertex {
				_uv_ed.drag_mode = .Move_Vertex
			} else if _uv_ed.select_mode == .Island {
				_uv_ed.drag_mode = .Move_Island
			} else {
				_uv_ed.drag_mode = .Move_Face
			}
		} else {
			clear(&_mesh_ed.sel_faces)
			clear(&_uv_ed.selected_island)
			_mesh_ed.selected_face = -1
			_uv_ed.selected_face = -1
			_uv_ed.selected_corner = -1
			_uv_ed.drag_mode = .None
		}
	}

	// Live Dragging UV Vertices / Faces / Islands
	if im.IsItemActive() && im.IsMouseDragging(.Left, 2) && _uv_ed.drag_mode != .None && _uv_ed.selected_face >= 0 && _uv_ed.selected_face < len(_mesh_ed.faces) {
		delta_screen := mouse - _uv_ed.drag_start_screen
		delta_uv := [2]f32{delta_screen.x / max(_uv_ed.zoom, 1.0), -delta_screen.y / max(_uv_ed.zoom, 1.0)}

		switch _uv_ed.drag_mode {
		case .Move_Vertex:
			// Find offset of `_uv_ed.selected_face` in `_uv_ed.drag_orig_uvs`
			off := 0
			for fi := 0; fi < _uv_ed.selected_face; fi += 1 {
				off += len(_mesh_ed.faces[fi].uvs)
			}
			f := &_mesh_ed.faces[_uv_ed.selected_face]
			if _uv_ed.selected_corner >= 0 && _uv_ed.selected_corner < len(f.uvs) && off + _uv_ed.selected_corner < len(_uv_ed.drag_orig_uvs) {
				new_uv := _uv_ed.drag_orig_uvs[off + _uv_ed.selected_corner] + delta_uv
				if _uv_ed.grid_snap && _uv_ed.grid_step > 0 {
					new_uv.x = math.round(new_uv.x / _uv_ed.grid_step) * _uv_ed.grid_step
					new_uv.y = math.round(new_uv.y / _uv_ed.grid_step) * _uv_ed.grid_step
				}
				f.uvs[_uv_ed.selected_corner] = new_uv
			}
		case .Move_Face, .Move_Island:
			off := 0
			for &f_it, fi in _mesh_ed.faces {
				n := len(f_it.uvs)
				if _uv_is_face_targeted(fi, true) && off + n <= len(_uv_ed.drag_orig_uvs) {
					for i := 0; i < n; i += 1 {
						new_uv := _uv_ed.drag_orig_uvs[off + i] + delta_uv
						if _uv_ed.grid_snap && _uv_ed.grid_step > 0 {
							new_uv.x = math.round(new_uv.x / _uv_ed.grid_step) * _uv_ed.grid_step
							new_uv.y = math.round(new_uv.y / _uv_ed.grid_step) * _uv_ed.grid_step
						}
						f_it.uvs[i] = new_uv
					}
				}
				off += n
			}
		case .None, .Pan_Canvas, .Box_Select:
		}
		_rebuild_editable_mesh_gpu(commit = false)
	}

	// Release drag -> commit undo step
	if im.IsItemDeactivated() {
		if _uv_ed.drag_mode != .None {
			_rebuild_editable_mesh_gpu(commit = true)
		}
		_uv_ed.drag_mode = .None
		_uv_ed.has_drag_orig_uvs = false
	}
}

@(private = "file")
_draw_uv_inspector :: proc(width: f32) {
	if !im.BeginChild("##uv_inspector_child", {width, 0}, {.Borders}, {}) {
		im.EndChild()
		return
	}
	defer im.EndChild()

	avail_w := max(im.GetContentRegionAvail().x, width - 16.0)
	im.SeparatorText("UV Tool Suite")

	// 1. Quick Unwrap Buttons
	im.TextColored({0.35, 0.90, 1.0, 1.0}, "1. Unwrap Methods:")
	half_w := (avail_w - 4.0) * 0.5
	if im.Button("Box (Cubic)", {half_w, 24}) do mesh_uv_unwrap_box(_uv_ed.unwrap_scale, fit_01 = true)
	widgets.tooltip("Cubic 6-axis unwrap: projects every face along its closest cardinal axis (±X, ±Y, ±Z)")
	im.SameLine(0, 4)
	if im.Button("Planar View", {half_w, 24}) do mesh_uv_unwrap_planar(3, _uv_ed.unwrap_scale, fit_01 = true)
	widgets.tooltip("Projects all faces onto the view/normal plane")

	if im.Button("Cylinder", {half_w, 24}) do mesh_uv_unwrap_cylinder(1, fit_01 = true)
	widgets.tooltip("Cylindrical unwrap for columns, tubes, and curved walls")
	im.SameLine(0, 4)
	if im.Button("Sphere", {half_w, 24}) do mesh_uv_unwrap_sphere(fit_01 = true)
	widgets.tooltip("Spherical unwrap (latitude / longitude mapping)")

	im.PushStyleColorImVec4(.Button, {0.18, 0.62, 0.44, 0.98})
	if im.Button("Auto-Unwrap Islands (LSCM)", {-1, 25}) do mesh_uv_auto_unwrap_islands(_uv_ed.unwrap_padding)
	im.PopStyleColor(1)
	widgets.tooltip("Automatically segments faces into smooth UV islands, flattens them, and packs them into [0, 1] texture space!")

	// 2. UV Packing & Seams
	im.SeparatorText("2. Pack & Seams")
	if im.Button("Pack UV Islands", {half_w, 24}) do mesh_uv_pack_islands(_uv_ed.unwrap_padding)
	widgets.tooltip("Packs all UV islands into [0, 1] without overlapping")
	im.SameLine(0, 4)
	if im.Button("Fit 0-1", {half_w, 24}) do mesh_uv_fit_01()

	im.SetNextItemWidth(avail_w - 70.0)
	im.SliderFloat("Pack Pad", &_uv_ed.unwrap_padding, 0.005, 0.08, "%.3f")
	widgets.tooltip("Spacing between islands when packing into [0, 1]")

	// UV Seams
	if im.Button("Mark / Clear Seam (Edge Mode)", {-1, 22}) do mesh_uv_toggle_selected_edge_seam()
	widgets.tooltip("Marks or unmarks the selected edge as a UV Seam (displayed in bright neon orange in 3D Scene view)")
	if len(_mesh_ed.uv_seams) > 0 {
		im.TextColoredUnformatted({1.0, 0.60, 0.15, 1.0}, fmt.ctprintf("Marked Seams: %d edges", len(_mesh_ed.uv_seams)))
		if im.SmallButton("Clear All Seams") do mesh_uv_clear_all_seams()
	}

	// 3. Transform & Align (Per-Face or All Faces!)
	im.SeparatorText("3. Transform & Mirror")
	im.Checkbox("Affect Selected Face(s) Only", &_uv_ed.transform_selected_only)
	widgets.tooltip("When checked and a face is selected, Rotate / Mirror / Scale / Offset pivot around THAT face's UV center!")

	if _uv_has_face_selection() && _uv_ed.transform_selected_only {
		im.TextColoredUnformatted({0.25, 1.0, 0.55, 1.0}, fmt.ctprintf("Target: Selected Face #%d (Pivot = Face Center)", _mesh_ed.selected_face))
	} else {
		im.TextColored({0.75, 0.82, 0.92, 1.0}, "Target: All Mesh Faces (Pivot = 0.5, 0.5)")
	}

	if im.Button("Rot -90° (CCW)", {half_w, 23}) do mesh_uv_rotate_90(false)
	widgets.tooltip("Rotate targeted face(s) 90° counter-clockwise in-place (Shortcut: Shift+R)")
	im.SameLine(0, 4)
	if im.Button("Rot +90° (CW)", {half_w, 23}) do mesh_uv_rotate_90(true)
	widgets.tooltip("Rotate targeted face(s) 90° clockwise in-place (Shortcut: R)")

	if im.Button("Mirror U (Flip H)", {half_w, 23}) do mesh_uv_flip(true, false)
	widgets.tooltip("Mirror / flip targeted face(s) horizontally in-place around their UV center (Shortcut: H)")
	im.SameLine(0, 4)
	if im.Button("Mirror V (Flip V)", {half_w, 23}) do mesh_uv_flip(false, true)
	widgets.tooltip("Mirror / flip targeted face(s) vertically in-place around their UV center (Shortcut: V)")

	im.SetNextItemWidth(avail_w - 70.0)
	if im.SliderFloat2("UV Scale", &_uv_ed.live_scale, 0.1, 10.0, "%.2f") {
		_uv_restore_and_apply_slider(commit = false)
	}
	if im.IsItemActivated() do _uv_snapshot_slider_base()
	if im.IsItemDeactivatedAfterEdit() do _uv_restore_and_apply_slider(commit = true)

	im.SetNextItemWidth(avail_w - 70.0)
	if im.SliderFloat2("UV Offset", &_uv_ed.live_offset, -2.0, 2.0, "%.2f") {
		_uv_restore_and_apply_slider(commit = false)
	}
	if im.IsItemActivated() do _uv_snapshot_slider_base()
	if im.IsItemDeactivatedAfterEdit() do _uv_restore_and_apply_slider(commit = true)

	im.SetNextItemWidth(avail_w - 70.0)
	if im.SliderFloat("UV Rotate", &_uv_ed.live_rot_deg, -180.0, 180.0, "%.1f°") {
		_uv_restore_and_apply_slider(commit = false)
	}
	if im.IsItemActivated() do _uv_snapshot_slider_base()
	if im.IsItemDeactivatedAfterEdit() do _uv_restore_and_apply_slider(commit = true)

	// 4. Active Selection Info + Direct Single-Face Controls
	im.SeparatorText("4. Selected Face UV Controls")
	if _mesh_ed.selected_face >= 0 && _mesh_ed.selected_face < len(_mesh_ed.faces) {
		f := &_mesh_ed.faces[_mesh_ed.selected_face]
		im.TextColoredUnformatted({0.2, 0.9, 0.4, 1.0}, fmt.ctprintf("Selected Face #%d (%d verts):", _mesh_ed.selected_face, len(f.verts)))
		if im.Button("Rot Face +90°##sf", {half_w, 22}) do mesh_uv_rotate_90(true, selected_only_override = true)
		im.SameLine(0, 4)
		if im.Button("Rot Face -90°##sf", {half_w, 22}) do mesh_uv_rotate_90(false, selected_only_override = true)
		if im.Button("Mirror Face U##sf", {half_w, 22}) do mesh_uv_flip(true, false, selected_only_override = true)
		im.SameLine(0, 4)
		if im.Button("Mirror Face V##sf", {half_w, 22}) do mesh_uv_flip(false, true, selected_only_override = true)
		if im.Button("Fit This Face [0-1]", {half_w, 22}) do mesh_uv_fit_01(selected_only_override = true)
		im.SameLine(0, 4)
		if im.Button("Unwrap Planar", {half_w, 22}) do mesh_uv_unwrap_planar(3, fit_01 = true, selected_only = true)
		if im.Button("Deselect Face (Edit All)", {-1, 20}) {
			clear(&_mesh_ed.sel_faces)
			clear(&_uv_ed.selected_island)
			_mesh_ed.selected_face = -1
			_uv_ed.selected_face   = -1
		}
		for uv, i in f.uvs {
			vi := f.verts[i] if i < len(f.verts) else 0
			im.TextDisabledUnformatted(fmt.ctprintf("  v%d: (U: %.3f, V: %.3f)", vi, uv.x, uv.y))
		}
	} else {
		im.TextDisabled("Click any face in the UV canvas (Shift+Click for multiple) to rotate, mirror, or drag just that face!")
	}
}

// 2D point in polygon test
@(private = "file")
_is_point_in_2d_poly :: proc(pt: im.Vec2, poly: []im.Vec2) -> bool {
	n := len(poly)
	if n < 3 do return false
	inside := false
	j := n - 1
	for i := 0; i < n; i += 1 {
		pi := poly[i]
		pj := poly[j]
		if ((pi.y > pt.y) != (pj.y > pt.y)) && (pt.x < (pj.x - pi.x) * (pt.y - pi.y) / max(pj.y - pi.y, 1e-4) + pi.x) {
			inside = !inside
		}
		j = i
	}
	return inside
}

// ============================================================================
// DRAG-AND-DROP MATERIAL (.mat) & TEXTURE (.png/.jpg) ONTO 3D OBJECTS & FACE UVS
// ============================================================================

// Applies a dropped `.mat` or texture (`.png`, `.jpg`, `.jpeg`, `.bmp`, `.tga`) asset onto a 3D object
// (`MeshRenderer`, `CSGVolume`, `Faker CSG`, `SkinnedMeshRenderer`, or `SpriteRenderer`) AND uses `drop_ray`
// to auto-pick and sync the exact under-cursor polygon Face UV map (or CSG Brush)!
apply_dropped_material_or_texture :: proc(
	raw_path:  string,
	target_tH: engine.Transform_Handle,
	drop_ray:  engine.Ray = {},
	has_ray:   bool = false,
) -> bool {
	_ensure_init()
	_ensure_mesh_ed_init()
	_ensure_uv_ed_init()

	clean_p, _ := filepath.clean(raw_path, context.temp_allocator)
	norm_p, _  := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)
	rel_p      := norm_p
	if len(engine.asset_db.root_path) > 0 {
		root_norm, _ := strings.replace_all(engine.asset_db.root_path, "\\", "/", context.temp_allocator)
		if strings.has_prefix(norm_p, root_norm) {
			rel_p = strings.trim_left(norm_p[len(root_norm):], "/")
		}
	}
	rel_p = strings.trim_prefix(rel_p, "../")
	rel_p = strings.trim_prefix(rel_p, "./")
	if strings.has_prefix(rel_p, "plugins/") {
		rel_p = fmt.tprintf("packages/%s", strings.trim_prefix(rel_p, "plugins/"))
	} else if strings.has_prefix(rel_p, "haati/") {
		rel_p = strings.trim_prefix(rel_p, "haati/")
	}

	ext := strings.to_lower(filepath.ext(rel_p), context.temp_allocator)
	is_mat := (ext == ".mat")
	is_tex := (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tga")
	if !is_mat && !is_tex do return false

	engine.asset_db_request_refresh()
	disk_id, found := engine.asset_db_get_guid(rel_p)
	if !found {
		disk_id, found = engine.asset_db_get_guid(norm_p)
	}
	if !found do return false

	mat_guid: engine.Asset_GUID = {}
	tex_guid: engine.Asset_GUID = {}

	if is_mat {
		mat_guid = engine.Asset_GUID(disk_id)
		if mat_obj, mok := engine.material_load(mat_guid); mok && mat_obj != nil {
			tex_guid = mat_obj.texture
		}
	} else {
		tex_guid = engine.Asset_GUID(disk_id)
		_ = os.make_directory("assets")
		_ = os.make_directory("assets/materials")
		stem := filepath.stem(filepath.base(rel_p))
		mat_rel := fmt.tprintf("assets/materials/%s.mat", stem)
		if existing_id, m_ok := engine.asset_db_get_guid(mat_rel); m_ok {
			mat_guid = engine.Asset_GUID(existing_id)
			engine.material_preview(mat_guid, engine.Material{
				shader  = .Lit,
				texture = tex_guid,
				color   = {1, 1, 1, 1},
			})
		} else {
			new_mat := engine.Material{
				shader  = .Lit,
				texture = tex_guid,
				color   = {1, 1, 1, 1},
			}
			_ = engine.material_save_to_file(mat_rel, new_mat)
			engine.asset_db_request_refresh()
			if mid, mfound := engine.asset_db_get_guid(mat_rel); mfound {
				mat_guid = engine.Asset_GUID(mid)
				engine.material_preview(mat_guid, new_mat)
			}
		}
	}
	if engine.asset_guid_is_empty(mat_guid) do return false

	w := engine.ctx_world()
	if w == nil do return false

	dest_tH := target_tH
	picked_face_idx := -1

	// If dropped in 3D Scene Viewport with a cursor ray, raycast against both Editable Poly Meshes and CSGVolumes
	// so we pick the exact object AND the exact under-cursor Face UV map / CSG Brush!
	if has_ray && linalg.length2(drop_ray.direction) > 1e-4 {
		hit_mh, hit_fi, hit_mt, _, _, m_ok := _raycast_scene_poly_mesh_for_extrude(drop_ray)
		_, _, c_dist, hit_vol, hit_b_idx, hit_cad := cad_csg.csg_raycast_world(drop_ray)

		if m_ok && (!hit_cad || hit_mt <= c_dist) {
			dest_tH         = hit_mh
			picked_face_idx = hit_fi
		} else if hit_cad && hit_vol != nil {
			vol_h := engine.Transform_Handle(hit_vol.owner)
			dest_tH = vol_h
			if hit_b_idx >= 0 {
				_ed.selected_brush_idx = hit_b_idx
			}
		}
	}

	if dest_tH == {} {
		dest_tH = engine.inspector_active_selection()
	}
	if dest_tH == {} || !engine.pool_valid(&w.transforms, engine.Handle(dest_tH)) {
		return false
	}

	applied := false

	// 1. Apply to CSGVolume & Faker CSG (inner mesh instance + outer CSG cut surfaces)
	if _, vol := engine.transform_get_comp(dest_tH, cad_csg.CSGVolume); vol != nil && vol.enabled {
		csg_history_ensure_baseline(vol)
		vol.custom_material_guid = mat_guid
		if vol.is_faker_mesh {
			vol.faker_material_guid = mat_guid
		}
		// Ensure brush and runtime-hull vertex colors are pure white so dark default brush colors
		// don't darken/tint the applied texture or material!
		for &b in vol.brushes {
			b.color = {255, 255, 255, 255}
		}
		for &rh in vol.runtime_hulls {
			for &pl in rh.planes {
				pl.color = {255, 255, 255, 255}
			}
		}
		cad_csg.csg_volume_rebuild(vol)
		cad_csg.csg_volume_upload_gpu_now(vol)
		csg_history_commit(vol)
		engine.inspector_request_select(dest_tH)
		applied = true
	}

	// 2. Apply to MeshRenderer (+ auto-sync under-cursor Face UV map!)
	_, mr := engine.transform_get_comp(dest_tH, engine.MeshRenderer)
	_, mf := engine.transform_get_comp(dest_tH, engine.MeshFilter)
	if mr == nil && mf != nil {
		_, ptr := engine.transform_add_comp(dest_tH, .MeshRenderer)
		mr = cast(^engine.MeshRenderer)ptr
	}
	if mr != nil {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		if len(mr.materials) == 0 {
			append(&mr.materials, mat_guid)
		} else {
			mr.materials[0] = mat_guid
		}
		context.allocator = prev_a
		applied = true

		// Ensure `_mesh_ed` is synced to `dest_tH` so we can select and inspect the under-cursor Face UV map!
		if _, has_csg := engine.transform_get_comp(dest_tH, cad_csg.CSGVolume); has_csg == nil || !has_csg.enabled {
			engine.inspector_request_select(dest_tH)
			_sync_mesh_editor_with_selection()
			if picked_face_idx < 0 && has_ray && linalg.length2(drop_ray.direction) > 1e-4 {
				if _, fi2, _, _, _, mok2 := _raycast_scene_poly_mesh_for_extrude(drop_ray); mok2 {
					picked_face_idx = fi2
				}
			}
			if picked_face_idx >= 0 && picked_face_idx < len(_mesh_ed.faces) {
				_mesh_ed.selected_face = picked_face_idx
				_uv_ed.selected_face   = picked_face_idx
				f := &_mesh_ed.faces[picked_face_idx]
				_ensure_face_uvs(f)
				// Check if the face's UVs are degenerate (all {0,0}); if so, planar-unwrap that face into [0..1]!
				uv_min := [2]f32{ 1e30,  1e30}
				uv_max := [2]f32{-1e30, -1e30}
				for uv in f.uvs {
					uv_min = linalg.min(uv_min, uv)
					uv_max = linalg.max(uv_max, uv)
				}
				if (uv_max.x - uv_min.x) < 1e-3 && (uv_max.y - uv_min.y) < 1e-3 {
					mesh_uv_unwrap_planar(3, 1.0, fit_01 = true, selected_only = true)
				} else {
					_rebuild_editable_mesh_gpu(commit = false)
				}
			}
		}
	}

	// 3. Apply to SkinnedMeshRenderer
	if _, smr := engine.transform_get_comp(dest_tH, engine.SkinnedMeshRenderer); smr != nil {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		if len(smr.materials) == 0 {
			append(&smr.materials, mat_guid)
		} else {
			smr.materials[0] = mat_guid
		}
		context.allocator = prev_a
		applied = true
	}

	if applied {
		if !engine.asset_guid_is_empty(tex_guid) {
			_uv_ed.active_tex_guid = tex_guid
		}
		engine.inspector_request_select(dest_tH)
		if sc := engine.sm_scene_get_active(); sc != nil {
			sc.dirty = true
		}
	}
	return applied
}
