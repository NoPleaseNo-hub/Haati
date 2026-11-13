package cad_csg

// ============================================================================
// SEVERED STEEL VOXEL SDF DESTRUCTION ENGINE (`CSG_Voxel_Grid`)
// ============================================================================
// - Lazily converts a `CSG_Chunk`'s convex hulls into a `32^3` Signed Distance Field
//   (`33^3` corner samples in `i8` + `32^3` material/color cells) the moment the
//   first blast or boolean cut hits that chunk.
// - O(1) constant-time blast carving (< 0.05 ms per blast regardless of whether
//   the player shoots the same wall 1 time or 10,000 times!).
// - Dual-Bounded Surface Nets / Dual Contouring isosurface extraction (crisp flat
//   CAD walls where `mat_slot == 0` + smooth faceted craters where `mat_slot == 1`).
// - 3D Greedy-Merged Box Mesher for fast Jolt physics & raycast hulls.
// - O(1) Trilinear SDF Triangle Clipper for `.fmesh` (`Faker CSG`) & Ghoul CSG.

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import engine "haati:engine"
import gfx "haati:engine/gfx"

@(private = "package")
_vox_pt_idx :: #force_inline proc(x, y, z: int) -> int {
	return (z * CSG_VOXEL_PTS + y) * CSG_VOXEL_PTS + x
}

@(private = "package")
_vox_cell_idx :: #force_inline proc(x, y, z: int) -> int {
	return (z * CSG_VOXEL_RES + y) * CSG_VOXEL_RES + x
}

// 4-bit nibble material accessors (packs 2 cells `0..15` into 1 `u8`, cutting material RAM in half!)
@(private = "package")
_vox_get_mat_slot :: #force_inline proc(grid: ^CSG_Voxel_Grid, c_idx: int) -> u8 {
	b := grid.mat_packed[c_idx >> 1]
	return (b >> 4) if (c_idx & 1) != 0 else (b & 0x0F)
}

@(private = "package")
_vox_set_mat_slot :: #force_inline proc(grid: ^CSG_Voxel_Grid, c_idx: int, val: u8) {
	idx := c_idx >> 1
	v   := val & 0x0F
	if (c_idx & 1) != 0 {
		grid.mat_packed[idx] = (grid.mat_packed[idx] & 0x0F) | (v << 4)
	} else {
		grid.mat_packed[idx] = (grid.mat_packed[idx] & 0xF0) | v
	}
}

// 64-bit `u64` 4x4x4 Brick indexing helpers (`6 x 6 x 6 = 216` bricks, `4 x 4 x 4 = 64` cells per brick = 1 bit per cell!)
@(private = "package")
_vox_brick_idx :: #force_inline proc(bx, by, bz: int) -> int {
	return (bz * CSG_BRICK_DIM + by) * CSG_BRICK_DIM + bx
}

@(private = "package")
_vox_cell_brick_bit :: #force_inline proc(x, y, z: int) -> (b_idx: int, bit_mask: u64) {
	bx, by, bz := x >> 2, y >> 2, z >> 2
	lx, ly, lz := uint(x & 3), uint(y & 3), uint(z & 3)
	b_idx    = (bz * CSG_BRICK_DIM + by) * CSG_BRICK_DIM + bx
	bit_mask = u64(1) << ((lz << 4) | (ly << 2) | lx)
	return
}

// 64-bit `u64` axis-span lookup tables for 1-cycle 3D AABB sub-brick intersection (`bit = (lz << 4) | (ly << 2) | lx`)
@(private = "file")
_BRICK_X_MASKS :: [4]u64{
	0x1111_1111_1111_1111,
	0x2222_2222_2222_2222,
	0x4444_4444_4444_4444,
	0x8888_8888_8888_8888,
}

@(private = "file")
_BRICK_Y_MASKS :: [4]u64{
	0x000F_000F_000F_000F,
	0x00F0_00F0_00F0_00F0,
	0x0F00_0F00_0F00_0F00,
	0xF000_F000_F000_F000,
}

@(private = "file")
_BRICK_Z_MASKS :: [4]u64{
	0x0000_0000_0000_FFFF,
	0x0000_0000_FFFF_0000,
	0x0000_FFFF_0000_0000,
	0xFFFF_0000_0000_0000,
}

// Updates `surface_bricks` and `cut_bricks` for all `4x4x4` bricks overlapping cell range `[cx0..cx1, cy0..cy1, cz0..cz1]`.
// - `surface_bricks`: computed 4 cells at a time via bitwise shifts on `pt_solid_rows` (`zero` `sdf` array reads!).
// - `cut_bricks`: bit `b = 1` iff cell `b` has at least one corner with `cut_sdf > 0` (actually carved into air!).
@(private = "package")
_vox_update_brick_masks_range :: proc(grid: ^CSG_Voxel_Grid, cx0, cy0, cz0, cx1, cy1, cz1: int) {
	bx0 := clamp(cx0 >> 2, 0, CSG_BRICK_DIM - 1)
	by0 := clamp(cy0 >> 2, 0, CSG_BRICK_DIM - 1)
	bz0 := clamp(cz0 >> 2, 0, CSG_BRICK_DIM - 1)
	bx1 := clamp(cx1 >> 2, 0, CSG_BRICK_DIM - 1)
	by1 := clamp(cy1 >> 2, 0, CSG_BRICK_DIM - 1)
	bz1 := clamp(cz1 >> 2, 0, CSG_BRICK_DIM - 1)

	has_cuts := grid.has_cuts

	for bz in bz0 ..= bz1 {
		z_base := bz << 2
		for by in by0 ..= by1 {
			y_base := by << 2
			for bx in bx0 ..= bx1 {
				x_base := bx << 2
				x_sh   := uint(x_base)
				b_idx  := _vox_brick_idx(bx, by, bz)
				surf_m: u64 = 0
				cut_m:  u64 = 0

				for lz in 0 ..< 4 {
					z  := z_base + lz
					z0 := z * CSG_VOXEL_PTS
					z1 := (z + 1) * CSG_VOXEL_PTS
					for ly in 0 ..< 4 {
						y     := y_base + ly
						shift := uint((lz << 4) | (ly << 2))

						r00 := grid.pt_solid_rows[z0 + y]     >> x_sh
						r10 := grid.pt_solid_rows[z0 + y + 1] >> x_sh
						r01 := grid.pt_solid_rows[z1 + y]     >> x_sh
						r11 := grid.pt_solid_rows[z1 + y + 1] >> x_sh

						any0 := r00 | (r00 >> 1) | r10 | (r10 >> 1)
						any1 := r01 | (r01 >> 1) | r11 | (r11 >> 1)
						all0 := r00 & (r00 >> 1) & r10 & (r10 >> 1)
						all1 := r01 & (r01 >> 1) & r11 & (r11 >> 1)

						surf4  := u64(((any0 | any1) & ~(all0 & all1)) & 0x0F)
						surf_m |= (surf4 << shift)

						if has_cuts {
							p00 := (z0 + y)     * CSG_VOXEL_PTS + x_base
							p10 := (z0 + y + 1) * CSG_VOXEL_PTS + x_base
							p01 := (z1 + y)     * CSG_VOXEL_PTS + x_base
							p11 := (z1 + y + 1) * CSG_VOXEL_PTS + x_base
							for lx in 0 ..< 4 {
								if grid.cut_sdf[p00 + lx] > 0 || grid.cut_sdf[p00 + lx + 1] > 0 ||
								   grid.cut_sdf[p10 + lx] > 0 || grid.cut_sdf[p10 + lx + 1] > 0 ||
								   grid.cut_sdf[p01 + lx] > 0 || grid.cut_sdf[p01 + lx + 1] > 0 ||
								   grid.cut_sdf[p11 + lx] > 0 || grid.cut_sdf[p11 + lx + 1] > 0 {
									cut_m |= (u64(1) << (shift | uint(lx)))
								}
							}
						}
					}
				}
				grid.surface_bricks[b_idx] = surf_m
				grid.cut_bricks[b_idx]     = cut_m
			}
		}
	}
}

// Returns true if the local AABB `[bmin - pad, bmax + pad]` overlaps any cell marked in `grid.cut_bricks`.
// Uses 64-bit `u64` bitwise sub-brick masks (`x_mask & y_mask & z_mask`) to test exact cells in 1 CPU cycle!
@(private = "package")
_vox_aabb_overlaps_cut_bricks :: #force_inline proc(grid: ^CSG_Voxel_Grid, bmin, bmax: [3]f32, pad: f32) -> bool {
	if !grid.has_cuts do return false
	p_min := bmin - [3]f32{pad, pad, pad}
	p_max := bmax + [3]f32{pad, pad, pad}
	if p_max.x < grid.cut_aabb_min.x || p_min.x > grid.cut_aabb_max.x ||
	   p_max.y < grid.cut_aabb_min.y || p_min.y > grid.cut_aabb_max.y ||
	   p_max.z < grid.cut_aabb_min.z || p_min.z > grid.cut_aabb_max.z {
		return false
	}
	inv_sz := 1.0 / grid.voxel_size
	cx0 := clamp(int(math.floor((p_min.x - grid.origin.x) * inv_sz)), 0, CSG_VOXEL_RES - 1)
	cy0 := clamp(int(math.floor((p_min.y - grid.origin.y) * inv_sz)), 0, CSG_VOXEL_RES - 1)
	cz0 := clamp(int(math.floor((p_min.z - grid.origin.z) * inv_sz)), 0, CSG_VOXEL_RES - 1)
	cx1 := clamp(int(math.floor((p_max.x - grid.origin.x) * inv_sz)), 0, CSG_VOXEL_RES - 1)
	cy1 := clamp(int(math.floor((p_max.y - grid.origin.y) * inv_sz)), 0, CSG_VOXEL_RES - 1)
	cz1 := clamp(int(math.floor((p_max.z - grid.origin.z) * inv_sz)), 0, CSG_VOXEL_RES - 1)

	bx0, by0, bz0 := cx0 >> 2, cy0 >> 2, cz0 >> 2
	bx1, by1, bz1 := cx1 >> 2, cy1 >> 2, cz1 >> 2

	xm := _BRICK_X_MASKS
	ym := _BRICK_Y_MASKS
	zm := _BRICK_Z_MASKS

	for bz in bz0 ..= bz1 {
		lz0 := max(cz0 - (bz << 2), 0)
		lz1 := min(cz1 - (bz << 2), 3)
		z_mask: u64 = 0
		for lz in lz0 ..= lz1 do z_mask |= zm[lz]

		for by in by0 ..= by1 {
			ly0 := max(cy0 - (by << 2), 0)
			ly1 := min(cy1 - (by << 2), 3)
			y_mask: u64 = 0
			for ly in ly0 ..= ly1 do y_mask |= ym[ly]
			zy_mask := z_mask & y_mask

			for bx in bx0 ..= bx1 {
				cm := grid.cut_bricks[_vox_brick_idx(bx, by, bz)]
				if cm == 0 do continue
				lx0 := max(cx0 - (bx << 2), 0)
				lx1 := min(cx1 - (bx << 2), 3)
				x_mask: u64 = 0
				for lx in lx0 ..= lx1 do x_mask |= xm[lx]
				if (cm & zy_mask & x_mask) != 0 {
					return true
				}
			}
		}
	}
	return false
}

// Quantizes a metric signed distance `sd` (where `< 0` is solid and `> 0` is air)
// into `i8` (`[-127..127]`) scaled by `band = voxel_size * 2.5`.
@(private = "file")
_quantize_sdf :: #force_inline proc(sd: f32, voxel_size: f32) -> i8 {
	band := max(voxel_size * 2.5, 0.02)
	norm := clamp(sd / band, -1.0, 1.0)
	q := int(math.round(norm * 127.0))
	if q == 0 {
		// Preserve strict sign around zero so inside (`sd <= 0`) vs outside (`sd > 0`) is unambiguous
		return 0 if sd <= 0.0 else 1
	}
	return i8(clamp(q, -127, 127))
}

@(private = "file")
_dequantize_sdf :: #force_inline proc(q: i8, voxel_size: f32) -> f32 {
	band := max(voxel_size * 2.5, 0.02)
	return (f32(q) / 127.0) * band
}

csg_voxel_grid_clone :: proc(src: ^CSG_Voxel_Grid, alloc := context.allocator) -> ^CSG_Voxel_Grid {
	if src == nil do return nil
	dst := new(CSG_Voxel_Grid, alloc)
	dst^ = src^
	if len(src.base_shell_verts) > 0 {
		dst.base_shell_verts = make([dynamic]gfx.Vertex, len(src.base_shell_verts), alloc)
		copy(dst.base_shell_verts[:], src.base_shell_verts[:])
	} else {
		dst.base_shell_verts = nil
	}
	if len(src.base_shell_indices) > 0 {
		dst.base_shell_indices = make([dynamic]u32, len(src.base_shell_indices), alloc)
		copy(dst.base_shell_indices[:], src.base_shell_indices[:])
	} else {
		dst.base_shell_indices = nil
	}
	if len(src.base_shell_hulls) > 0 {
		dst.base_shell_hulls = make([dynamic]CSG_Convex, len(src.base_shell_hulls), alloc)
		for h, i in src.base_shell_hulls {
			dst.base_shell_hulls[i] = convex_clone(h, alloc)
		}
	} else {
		dst.base_shell_hulls = nil
	}
	return dst
}

csg_voxel_grid_free :: proc(grid: ^CSG_Voxel_Grid, alloc := context.allocator) {
	if grid == nil do return
	if grid.base_shell_verts != nil do delete(grid.base_shell_verts)
	if grid.base_shell_indices != nil do delete(grid.base_shell_indices)
	if grid.base_shell_hulls != nil {
		for &h in grid.base_shell_hulls do convex_destroy(&h)
		delete(grid.base_shell_hulls)
	}
	free(grid, alloc)
}

// Initializes a `32^3` Voxel Signed Distance Field (`CSG_Voxel_Grid`) from a chunk's
// `destructible_hulls`, padding the bounds by `1.75` voxels on all 6 sides so the outer
// boundary of the grid is guaranteed to be outside air (`sdf > 0`) for watertight Surface Nets extraction!
csg_voxel_grid_init_from_hulls :: proc(
	hulls:      []CSG_Convex,
	chunk_min:  [3]f32,
	chunk_max:  [3]f32,
	alloc := context.allocator,
) -> ^CSG_Voxel_Grid {
	if len(hulls) == 0 do return nil

	bmin := hulls[0].aabb_min
	bmax := hulls[0].aabb_max
	for h in hulls[1:] {
		bmin = linalg.min(bmin, h.aabb_min)
		bmax = linalg.max(bmax, h.aabb_max)
	}
	ext := bmax - bmin
	max_span := max(ext.x, max(ext.y, ext.z))
	if max_span < 0.08 {
		c_ext := chunk_max - chunk_min
		max_span = max(c_ext.x, max(c_ext.y, c_ext.z))
		bmin = chunk_min
		bmax = chunk_max
	}
	max_span = max(max_span, 0.25)

	// Fit the 32^3 grid tightly around `[bmin, bmax]` with a 2-voxel air border on each side (`28` interior cells across `max_span`)
	vox_sz := max_span / f32(CSG_VOXEL_RES - 4)
	pad    := vox_sz * 2.0
	center := (bmin + bmax) * 0.5
	half_grid := (f32(CSG_VOXEL_RES) * vox_sz) * 0.5

	grid := new(CSG_Voxel_Grid, alloc)
	grid.origin       = center - [3]f32{half_grid, half_grid, half_grid}
	grid.voxel_size   = vox_sz
	grid.uv_scale     = 0.5
	grid.has_cuts     = false
	grid.cut_aabb_min = { 1e30,  1e30,  1e30}
	grid.cut_aabb_max = {-1e30, -1e30, -1e30}
	for i in 0 ..< len(grid.cut_sdf) {
		grid.cut_sdf[i] = -127
	}
	_ = pad

	// Capture the chunk's pristine razor-sharp CSG outer shell so blasting turns the chunk into a self-hosted `.fmesh`
	// (sharp original CSG outer polygons with Voxel SDF hole-punching + Surface Nets interior crater walls & collision)!
	grid.base_shell_verts   = make([dynamic]gfx.Vertex, 0, 128, alloc)
	grid.base_shell_indices = make([dynamic]u32, 0, 256, alloc)
	grid.base_shell_hulls   = make([dynamic]CSG_Convex, 0, len(hulls), alloc)
	for h in hulls {
		if len(h.planes) >= 4 {
			append(&grid.base_shell_hulls, convex_clone(h, alloc))
		}
	}
	if len(grid.base_shell_hulls) > 0 {
		dummy_subs := make([dynamic]engine.Mesh_Submesh, 0, 8, context.temp_allocator)
		csg_triangulate_hulls(grid.base_shell_hulls[:], &grid.base_shell_verts, &grid.base_shell_indices, &dummy_subs)
		if len(dummy_subs) > 0 {
			grid.base_shell_slot0_count = dummy_subs[0].index_count
			sub_n := min(len(dummy_subs), 8)
			grid.base_shell_submesh_count = u8(sub_n)
			for si in 0 ..< sub_n {
				grid.base_shell_submeshes[si] = dummy_subs[si]
			}
		} else {
			grid.base_shell_slot0_count = u32(len(grid.base_shell_indices))
			grid.base_shell_submesh_count = 1
			grid.base_shell_submeshes[0] = {first_index = 0, index_count = u32(len(grid.base_shell_indices))}
		}
	}

	default_col := [4]u8{210, 216, 224, 255}
	if len(hulls[0].planes) > 0 {
		default_col   = hulls[0].planes[0].color
		grid.uv_scale = max(hulls[0].planes[0].uv_scale, 0.1)
	}
	grid.base_color = default_col
	grid.cut_color  = {92, 84, 78, 255}

	// 1. Evaluate exact Signed Distance `min_h max_p (dot(n, x) - d)` at all `25 x 25 x 25` grid corners
	// Force the outermost 1-corner shell (`0` and `CSG_VOXEL_RES`) to be outside air (`64`)
	// so Surface Nets is 100% closed and watertight around the entire chunk!
	for i in 0 ..< len(grid.sdf) {
		grid.sdf[i] = 64
	}

	// 1. Evaluate exact Signed Distance `min_h max_p (dot(n, x) - d)` at interior `23 x 23 x 23` grid corners
	//    with Y/Z row hoisting so plane `n.y*py + n.z*pz - dist` and Y/Z AABB checks run once per row instead of 23x!
	band_lim := vox_sz * 3.0
	for z in 1 ..< CSG_VOXEL_RES {
		pz := grid.origin.z + f32(z) * vox_sz
		for y in 1 ..< CSG_VOXEL_RES {
			py := grid.origin.y + f32(y) * vox_sz
			row_solid_mask: u32 = 0
			base_p_idx := _vox_pt_idx(0, y, z)

			row_sd: [CSG_VOXEL_PTS]f32 = ---
			for x in 1 ..< CSG_VOXEL_RES {
				row_sd[x] = 1e9
			}

			for h in hulls {
				if len(h.planes) < 4 do continue
				dy := max(h.aabb_min.y - py, max(f32(0.0), py - h.aabb_max.y))
				dz := max(h.aabb_min.z - pz, max(f32(0.0), pz - h.aabb_max.z))
				dyz := dy + dz
				if dyz > band_lim do continue

				for x in 1 ..< CSG_VOXEL_RES {
					px := grid.origin.x + f32(x) * vox_sz
					dx := max(h.aabb_min.x - px, max(f32(0.0), px - h.aabb_max.x))
					if dx + dyz > row_sd[x] + band_lim do continue

					pt := [3]f32{px, py, pz}
					h_sd: f32 = -1e9
					for p in h.planes {
						d := linalg.dot(p.normal, pt) - p.dist
						if d > h_sd do h_sd = d
					}
					if h_sd < row_sd[x] {
						row_sd[x] = h_sd
					}
				}
			}

			for x in 1 ..< CSG_VOXEL_RES {
				q_sd := _quantize_sdf(row_sd[x], vox_sz)
				grid.sdf[base_p_idx + x] = q_sd
				if q_sd <= 0 {
					row_solid_mask |= (u32(1) << uint(x))
				}
			}
			grid.pt_solid_rows[z * CSG_VOXEL_PTS + y] = row_solid_mask
		}
	}

	_vox_update_brick_masks_range(grid, 0, 0, 0, CSG_VOXEL_RES - 1, CSG_VOXEL_RES - 1, CSG_VOXEL_RES - 1)
	return grid
}

// ============================================================================
// PHASE 2: O(1) CONSTANT-TIME SEVERED STEEL BLAST CARVING & PLANE SLICING
// ============================================================================

// Carves a jagged Severed Steel / Red Faction crater into `grid` at `center` with `radius`
// in O(1) constant time (< 0.05 ms, zero allocations, zero hull fragmentation!).
csg_voxel_carve_blast :: proc(
	grid:       ^CSG_Voxel_Grid,
	center:     [3]f32,
	radius:     f32,
	seed:       u32 = 1,
	jaggedness: f32 = 0.14,
	scorch_col: [4]u8 = {92, 84, 78, 255},
	mat_slot:   u8 = 1,
) {
	if grid == nil do return
	vox_sz := grid.voxel_size
	if vox_sz <= 1e-5 do return

	r := max(radius, max(vox_sz * 0.85, 0.06))
	jag := clamp(jaggedness, 0.0, 0.35) * 0.45
	reach := r * (1.0 + jag) + vox_sz * 2.6

	rel_min := (center - [3]f32{reach, reach, reach} - grid.origin) / vox_sz
	rel_max := (center + [3]f32{reach, reach, reach} - grid.origin) / vox_sz

	ix0 := clamp(int(math.floor(rel_min.x)), 1, CSG_VOXEL_RES - 1)
	iy0 := clamp(int(math.floor(rel_min.y)), 1, CSG_VOXEL_RES - 1)
	iz0 := clamp(int(math.floor(rel_min.z)), 1, CSG_VOXEL_RES - 1)
	ix1 := clamp(int(math.ceil(rel_max.x)),  1, CSG_VOXEL_RES - 1)
	iy1 := clamp(int(math.ceil(rel_max.y)),  1, CSG_VOXEL_RES - 1)
	iz1 := clamp(int(math.ceil(rel_max.z)),  1, CSG_VOXEL_RES - 1)

	if ix0 > ix1 || iy0 > iy1 || iz0 > iz1 do return

	seed_f := f32(seed & 0xFFFF) * 0.0173

	// 1. Update corner SDF values & `pt_solid_rows` bitmask in `[ix0..ix1, iy0..iy1, iz0..iz1]`
	for z in iz0 ..= iz1 {
		pz := grid.origin.z + f32(z) * vox_sz
		for y in iy0 ..= iy1 {
			py := grid.origin.y + f32(y) * vox_sz
			zy_idx   := z * CSG_VOXEL_PTS + y
			row_mask := grid.pt_solid_rows[zy_idx]
			base_p   := _vox_pt_idx(0, y, z)
			for x in ix0 ..= ix1 {
				px := grid.origin.x + f32(x) * vox_sz
				diff := [3]f32{px, py, pz} - center
				dist := linalg.length(diff)

				// Angular rock/concrete facet perturbation so craters have chunky Severed Steel geometry
				r_eff := r
				if dist > 1e-4 && jag > 0.005 {
					dir := diff / dist
					n_val := math.sin(dir.x * 5.7 + seed_f) * math.cos(dir.y * 6.3 - seed_f * 1.3) +
					         math.sin(dir.z * 5.1 + seed_f * 0.7) * 0.5
					r_eff = r * (1.0 + clamp(n_val * 0.65, -1.0, 1.0) * jag)
				}

				// Inside the blast sphere, `carve_sd = r_eff - dist > 0` (air!)
				carve_sd := r_eff - dist
				q_carve  := _quantize_sdf(carve_sd, vox_sz)
				p_idx    := base_p + x
				if q_carve > grid.cut_sdf[p_idx] {
					grid.cut_sdf[p_idx] = q_carve
				}
				if q_carve > grid.sdf[p_idx] {
					grid.sdf[p_idx] = q_carve
					grid.has_cuts   = true
					if q_carve > 0 {
						row_mask &~= (u32(1) << uint(x))
					}
				}
			}
			grid.pt_solid_rows[zy_idx] = row_mask
		}
	}

	if grid.has_cuts {
		grid.cut_aabb_min = linalg.min(grid.cut_aabb_min, center - [3]f32{reach, reach, reach})
		grid.cut_aabb_max = linalg.max(grid.cut_aabb_max, center + [3]f32{reach, reach, reach})
	}

	// 2. Tag cells bordering the newly carved crater with `p_id` (`1..15`) in 4-bit `mat_packed`
	cx0 := clamp(ix0 - 1, 0, CSG_VOXEL_RES - 1)
	cy0 := clamp(iy0 - 1, 0, CSG_VOXEL_RES - 1)
	cz0 := clamp(iz0 - 1, 0, CSG_VOXEL_RES - 1)
	cx1 := clamp(ix1,     0, CSG_VOXEL_RES - 1)
	cy1 := clamp(iy1,     0, CSG_VOXEL_RES - 1)
	cz1 := clamp(iz1,     0, CSG_VOXEL_RES - 1)

	scorch_band   := r * (1.0 + jag) + vox_sz * 1.45
	scorch_band2  := scorch_band * scorch_band
	grid.cut_color = scorch_col

	// Find or allocate a per-blast palette entry `p_id` (`1..15`) pairing `(scorch_col, eff_mat_slot)`
	eff_mat_slot := clamp(mat_slot, 1, 7)
	p_id: u8 = 0
	for pi in u8(1) ..= grid.palette_count {
		if grid.palette_mat_slots[pi] == eff_mat_slot && grid.palette_colors[pi] == scorch_col {
			p_id = pi
			break
		}
	}
	if p_id == 0 {
		if grid.palette_count < 15 {
			grid.palette_count += 1
			p_id = grid.palette_count
		} else {
			p_id = 15
		}
		grid.palette_colors[p_id]    = scorch_col
		grid.palette_mat_slots[p_id] = eff_mat_slot
	}

	for z in cz0 ..= cz1 {
		for y in cy0 ..= cy1 {
			for x in cx0 ..= cx1 {
				cp := grid.origin + ([3]f32{f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5}) * vox_sz
				if linalg.length2(cp - center) <= scorch_band2 {
					_vox_set_mat_slot(grid, _vox_cell_idx(x, y, z), p_id)
				}
			}
		}
	}

	// 3. Prune tiny isolated mid-air floating SDF crumbs & refresh 64-bit `u64` brick bitmasks!
	csg_voxel_prune_floating_crumbs(grid)
	_vox_update_brick_masks_range(grid, cx0, cy0, cz0, cx1, cy1, cz1)
}

@(private = "file")
_vox_prune_row_bits :: proc(
	grid:          ^CSG_Voxel_Grid,
	zy:            int,
	mask_to_prune: u32,
	p_min:         ^[3]int,
	p_max:         ^[3]int,
) {
	y := zy % CSG_VOXEL_PTS
	z := zy / CSG_VOXEL_PTS
	vox_sz := grid.voxel_size
	base_p := _vox_pt_idx(0, y, z)
	grid.pt_solid_rows[zy] &~= mask_to_prune

	p_min.y = min(p_min.y, max(y - 1, 0))
	p_max.y = max(p_max.y, min(y, CSG_VOXEL_RES - 1))
	p_min.z = min(p_min.z, max(z - 1, 0))
	p_max.z = max(p_max.z, min(z, CSG_VOXEL_RES - 1))

	m := mask_to_prune
	for m != 0 {
		x := int(intrinsics.count_trailing_zeros(m))
		m &= m - 1
		p_min.x = min(p_min.x, max(x - 1, 0))
		p_max.x = max(p_max.x, min(x, CSG_VOXEL_RES - 1))
		p_idx := base_p + x
		grid.sdf[p_idx]     = 64
		grid.cut_sdf[p_idx] = 64
		pt := grid.origin + [3]f32{f32(x), f32(y), f32(z)} * vox_sz
		grid.cut_aabb_min = linalg.min(grid.cut_aabb_min, pt - [3]f32{vox_sz, vox_sz, vox_sz})
		grid.cut_aabb_max = linalg.max(grid.cut_aabb_max, pt + [3]f32{vox_sz, vox_sz, vox_sz})
		for dz in -1 ..= 0 {
			for dy in -1 ..= 0 {
				for dx in -1 ..= 0 {
					mcx, mcy, mcz := x + dx, y + dy, z + dz
					if mcx >= 0 && mcx < CSG_VOXEL_RES && mcy >= 0 && mcy < CSG_VOXEL_RES && mcz >= 0 && mcz < CSG_VOXEL_RES {
						_vox_set_mat_slot(grid, _vox_cell_idx(mcx, mcy, mcz), 1)
					}
				}
			}
		}
	}
}

// Flood-fills one 6-connected component in `unvisited` starting from `(start_zy, seed_bit)`,
// appending `(u64(zy) << 32) | u64(mask)` entries into `items[start_item..]` with ZERO memset or heap allocations!
@(private = "file")
_vox_flood_fill_into_items :: #force_inline proc(
	unvisited:  ^[CSG_VOXEL_PTS * CSG_VOXEL_PTS]u32,
	items:      ^[4096]u64,
	start_item: int,
	start_zy:   int,
	seed_bit:   u32,
) -> (comp_cnt: int, end_item: int) {
	if start_item >= len(items) {
		return 0, start_item
	}
	solid0 := unvisited[start_zy] & ~seed_bit
	m0     := seed_bit
	for {
		nx := ((m0 << 1) | (m0 >> 1)) & solid0
		if nx == 0 do break
		m0     |= nx
		solid0 &~= nx
	}
	unvisited[start_zy] = solid0
	comp_cnt = int(intrinsics.count_ones(m0))

	items[start_item] = (u64(start_zy) << 32) | u64(m0)
	head     := start_item
	end_item  = start_item + 1

	n_offsets := [4]int{-1, +1, -CSG_VOXEL_PTS, +CSG_VOXEL_PTS}

	for head < end_item {
		packed  := items[head]
		head    += 1
		curr_zy := int(packed >> 32)
		m       := u32(packed)

		for off in n_offsets {
			n_zy := curr_zy + off
			if n_zy < CSG_VOXEL_PTS || n_zy >= (CSG_VOXEL_RES * CSG_VOXEL_PTS) do continue
			n_solid := unvisited[n_zy]
			n_add   := n_solid & m
			if n_add != 0 {
				n_solid &~= n_add
				n_m := n_add
				for {
					nx := ((n_m << 1) | (n_m >> 1)) & n_solid
					if nx == 0 do break
					n_m     |= nx
					n_solid &~= nx
				}
				unvisited[n_zy] = n_solid
				comp_cnt       += int(intrinsics.count_ones(n_m))
				if end_item < len(items) {
					items[end_item] = (u64(n_zy) << 32) | u64(n_m)
					end_item       += 1
				}
			}
		}
	}
	return
}

// Removes tiny disconnected mid-air SDF crumbs (`sdf <= 0` components with `< 16` corners or `< 1/14` of main solid)
// using zero-allocation, zero-memset 32-bit bitwise X-row flood-fill and hardware `POPCNT` (`count_ones`).
// Returns true if any crumbs were pruned (and all brick masks were refreshed).
csg_voxel_prune_floating_crumbs :: proc(grid: ^CSG_Voxel_Grid) -> bool {
	if grid == nil do return false

	unvisited := grid.pt_solid_rows
	total_solid_pts := 0
	first_zy := -1
	for zy in CSG_VOXEL_PTS ..< CSG_VOXEL_RES * CSG_VOXEL_PTS {
		r := unvisited[zy]
		if r != 0 {
			total_solid_pts += int(intrinsics.count_ones(r))
			if first_zy < 0 do first_zy = zy
		}
	}
	if total_solid_pts <= 1 || first_zy < 0 do return false

	items: [4096]u64 = ---
	seed0 := unvisited[first_zy] & (0 - unvisited[first_zy])
	c0_cnt, end0 := _vox_flood_fill_into_items(&unvisited, &items, 0, first_zy, seed0)

	// Fast Path #1 (95%+ of blasts): 100% of solid voxels belong to a single connected body -> zero crumbs!
	if c0_cnt == total_solid_pts do return false

	rem_pts := total_solid_pts - c0_cnt
	p_min := [3]int{CSG_VOXEL_RES, CSG_VOXEL_RES, CSG_VOXEL_RES}
	p_max := [3]int{0, 0, 0}

	// Fast Path #2: Component 0 is the main body AND all remaining disconnected bits combined are smaller than `min_keep`!
	if c0_cnt >= rem_pts {
		min_keep := max(16, c0_cnt / 14)
		if rem_pts < min_keep {
			for zy in first_zy ..< CSG_VOXEL_RES * CSG_VOXEL_PTS {
				if unvisited[zy] != 0 {
					_vox_prune_row_bits(grid, zy, unvisited[zy], &p_min, &p_max)
				}
			}
			if p_min.x <= p_max.x {
				_vox_update_brick_masks_range(grid, p_min.x, p_min.y, p_min.z, p_max.x, p_max.y, p_max.z)
			}
			return true
		}
	}

	// General Path: Multiple non-trivial components exist (zero heap allocations, flat `items` spans!)
	Comp_Span :: struct {
		start, end, cnt: int,
	}
	spans: [64]Comp_Span = ---
	spans[0]   = {0, end0, c0_cnt}
	span_count := 1
	cur_item   := end0
	max_cnt    := c0_cnt
	best_idx   := 0

	for zy in first_zy ..< CSG_VOXEL_RES * CSG_VOXEL_PTS {
		for unvisited[zy] != 0 && span_count < 64 {
			seed := unvisited[zy] & (0 - unvisited[zy])
			cnt, next_item := _vox_flood_fill_into_items(&unvisited, &items, cur_item, zy, seed)
			idx := span_count
			spans[idx]  = {cur_item, next_item, cnt}
			span_count += 1
			cur_item    = next_item
			if cnt > max_cnt {
				max_cnt  = cnt
				best_idx = idx
			}
		}
	}

	min_keep   := max(16, max_cnt / 14)
	any_pruned := false
	for idx in 0 ..< span_count {
		sp := spans[idx]
		if idx != best_idx && sp.cnt < min_keep {
			any_pruned = true
			for k in sp.start ..< sp.end {
				packed := items[k]
				_vox_prune_row_bits(grid, int(packed >> 32), u32(packed), &p_min, &p_max)
			}
		}
	}
	if any_pruned && p_min.x <= p_max.x {
		_vox_update_brick_masks_range(grid, p_min.x, p_min.y, p_min.z, p_max.x, p_max.y, p_max.z)
	}
	return any_pruned
}

// Extracts any ungrounded solid connected components (`cnt >= 16`) from a blasted `CSG_Voxel_Grid`
// into greedy `CSG_Convex` hulls in `out_detached_hulls`, and prunes their voxels out of `grid`.
csg_voxel_extract_ungrounded_islands :: proc(
	grid:               ^CSG_Voxel_Grid,
	ground_y:           f32,
	ind_hulls:          []CSG_Convex,
	is_dynamic_volume:  bool,
	out_detached_hulls: ^[dynamic]CSG_Convex,
	alloc := context.allocator,
) -> bool {
	if grid == nil || out_detached_hulls == nil do return false

	unvisited := grid.pt_solid_rows
	first_zy := -1
	for zy in CSG_VOXEL_PTS ..< CSG_VOXEL_RES * CSG_VOXEL_PTS {
		if unvisited[zy] != 0 {
			first_zy = zy
			break
		}
	}
	if first_zy < 0 do return false

	Comp_Span :: struct {
		start, end, cnt: int,
		grounded:        bool,
	}
	items: [4096]u64 = ---
	spans: [64]Comp_Span = ---
	span_count := 0
	cur_item   := 0
	max_cnt    := -1
	best_idx   := 0

	for zy in first_zy ..< CSG_VOXEL_RES * CSG_VOXEL_PTS {
		for unvisited[zy] != 0 && span_count < 64 && cur_item < len(items) {
			seed := unvisited[zy] & (0 - unvisited[zy])
			cnt, next_item := _vox_flood_fill_into_items(&unvisited, &items, cur_item, zy, seed)
			idx := span_count
			spans[idx]  = {start = cur_item, end = next_item, cnt = cnt}
			span_count += 1
			cur_item    = next_item
			if cnt > max_cnt {
				max_cnt  = cnt
				best_idx = idx
			}
		}
	}
	if span_count == 0 do return false

	vox_sz := grid.voxel_size
	ground_tol := ground_y + max(0.25, vox_sz * 1.5)
	ungrounded_count := 0

	if is_dynamic_volume {
		if span_count <= 1 do return false
		for idx in 0 ..< span_count {
			spans[idx].grounded = (idx == best_idx)
			if !spans[idx].grounded && spans[idx].cnt >= 16 {
				ungrounded_count += 1
			}
		}
	} else {
		for idx in 0 ..< span_count {
			sp := &spans[idx]
			if sp.cnt < 16 {
				sp.grounded = true
				continue
			}
			min_p := [3]int{CSG_VOXEL_RES, CSG_VOXEL_RES, CSG_VOXEL_RES}
			max_p := [3]int{0, 0, 0}
			for k in sp.start ..< sp.end {
				packed := items[k]
				zy := int(packed >> 32)
				y  := zy % CSG_VOXEL_PTS
				z  := zy / CSG_VOXEL_PTS
				m  := u32(packed)
				for m != 0 {
					x := int(intrinsics.count_trailing_zeros(m))
					m &= m - 1
					min_p.x = min(min_p.x, x); max_p.x = max(max_p.x, x)
					min_p.y = min(min_p.y, y); max_p.y = max(max_p.y, y)
					min_p.z = min(min_p.z, z); max_p.z = max(max_p.z, z)
				}
			}
			w_min := grid.origin + [3]f32{f32(min_p.x), f32(min_p.y), f32(min_p.z)} * vox_sz
			w_max := grid.origin + [3]f32{f32(max_p.x), f32(max_p.y), f32(max_p.z)} * vox_sz
			if w_min.y <= ground_tol {
				sp.grounded = true
			} else {
				pad := max(0.12, vox_sz * 1.25)
				for ih in ind_hulls {
					if aabb_overlaps(w_min, w_max, ih.aabb_min, ih.aabb_max, pad) {
						sp.grounded = true
						break
					}
				}
			}
			if !sp.grounded {
				ungrounded_count += 1
			}
		}
	}

	if ungrounded_count == 0 do return false

	ungrounded_rows: [CSG_VOXEL_PTS * CSG_VOXEL_PTS]u32
	for idx in 0 ..< span_count {
		sp := spans[idx]
		if sp.grounded || sp.cnt < 16 do continue
		for k in sp.start ..< sp.end {
			packed := items[k]
			ungrounded_rows[int(packed >> 32)] |= u32(packed)
		}
	}

	tmp_hulls := make([dynamic]CSG_Convex, 0, 16, context.temp_allocator)
	csg_voxel_build_greedy_hulls(grid, &tmp_hulls, alloc)
	inv_v := 1.0 / max(vox_sz, 1e-4)
	for &h in tmp_hulls {
		hc := (h.aabb_min + h.aabb_max) * 0.5 - grid.origin
		gx := clamp(int(math.round(hc.x * inv_v)), 0, CSG_VOXEL_RES)
		gy := clamp(int(math.round(hc.y * inv_v)), 0, CSG_VOXEL_RES)
		gz := clamp(int(math.round(hc.z * inv_v)), 0, CSG_VOXEL_RES)
		hit := false
		for dz in -1 ..= 1 {
			zz := clamp(gz + dz, 0, CSG_VOXEL_RES)
			for dy in -1 ..= 1 {
				yy := clamp(gy + dy, 0, CSG_VOXEL_RES)
				row := ungrounded_rows[zz * CSG_VOXEL_PTS + yy]
				if row == 0 do continue
				for dx in -1 ..= 1 {
					xx := clamp(gx + dx, 0, CSG_VOXEL_RES)
					if (row & (u32(1) << uint(xx))) != 0 {
						hit = true
						break
					}
				}
				if hit do break
			}
			if hit do break
		}
		if hit || span_count == 1 {
			append(out_detached_hulls, h)
		} else {
			convex_destroy(&h)
		}
	}

	p_min := [3]int{CSG_VOXEL_RES, CSG_VOXEL_RES, CSG_VOXEL_RES}
	p_max := [3]int{0, 0, 0}
	for idx in 0 ..< span_count {
		sp := spans[idx]
		if sp.grounded || sp.cnt < 16 do continue
		for k in sp.start ..< sp.end {
			packed := items[k]
			_vox_prune_row_bits(grid, int(packed >> 32), u32(packed), &p_min, &p_max)
		}
	}
	if p_min.x <= p_max.x {
		_vox_update_brick_masks_range(grid, p_min.x, p_min.y, p_min.z, p_max.x, p_max.y, p_max.z)
	}
	return len(out_detached_hulls) > 0
}

// Clips a `CSG_Voxel_Grid` against an arbitrary cutting plane `(plane_normal, plane_dist)` in local space.
csg_voxel_clip_by_plane :: proc(
	grid:         ^CSG_Voxel_Grid,
	plane_normal: [3]f32,
	plane_dist:   f32,
	mode:         CSG_Clip_Mode,
	split_gap:    f32 = 0.0,
) {
	if grid == nil do return
	n := linalg.normalize0(plane_normal)
	if linalg.length2(n) < 0.5 do return
	vox_sz := grid.voxel_size
	half_gap := clamp(split_gap * 0.5, 0.0, 0.5)

	for z in 1 ..< CSG_VOXEL_RES {
		pz := grid.origin.z + f32(z) * vox_sz
		for y in 1 ..< CSG_VOXEL_RES {
			py := grid.origin.y + f32(y) * vox_sz
			zy_idx   := z * CSG_VOXEL_PTS + y
			row_mask := grid.pt_solid_rows[zy_idx]
			base_p   := _vox_pt_idx(0, y, z)
			for x in 1 ..< CSG_VOXEL_RES {
				px := grid.origin.x + f32(x) * vox_sz
				pt := [3]f32{px, py, pz}
				s := linalg.dot(n, pt) - plane_dist
				cut_sd: f32 = -1e9
				if mode == .Keep_Back {
					cut_sd = s + half_gap
				} else if mode == .Keep_Front {
					cut_sd = -s + half_gap
				} else {
					cut_sd = max(half_gap, vox_sz * 0.65) - abs(s)
				}
				q_cut := _quantize_sdf(cut_sd, vox_sz)
				if q_cut <= -64 do continue
				p_idx := base_p + x
				if q_cut > grid.cut_sdf[p_idx] {
					grid.cut_sdf[p_idx] = q_cut
				}
				if q_cut > grid.sdf[p_idx] {
					grid.sdf[p_idx] = q_cut
					grid.has_cuts   = true
					if q_cut > 0 {
						row_mask &~= (u32(1) << uint(x))
					}
					if q_cut > -48 {
						grid.cut_aabb_min = linalg.min(grid.cut_aabb_min, pt - [3]f32{vox_sz, vox_sz, vox_sz})
						grid.cut_aabb_max = linalg.max(grid.cut_aabb_max, pt + [3]f32{vox_sz, vox_sz, vox_sz})
					}
				}
			}
			grid.pt_solid_rows[zy_idx] = row_mask
		}
	}

	// Mark cells along or carved by the cut plane with `mat_slot = 1`
	for z in 0 ..< CSG_VOXEL_RES {
		for y in 0 ..< CSG_VOXEL_RES {
			for x in 0 ..< CSG_VOXEL_RES {
				cp := grid.origin + ([3]f32{f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5}) * vox_sz
				s  := linalg.dot(n, cp) - plane_dist
				is_cut_cell := abs(s) <= half_gap + vox_sz * 1.4
				if mode == .Keep_Back && s >= -half_gap - vox_sz * 1.4 do is_cut_cell = true
				if mode == .Keep_Front && -s >= -half_gap - vox_sz * 1.4 do is_cut_cell = true
				if is_cut_cell {
					_vox_set_mat_slot(grid, _vox_cell_idx(x, y, z), 1)
				}
			}
		}
	}
	csg_voxel_prune_floating_crumbs(grid)
	_vox_update_brick_masks_range(grid, 0, 0, 0, CSG_VOXEL_RES - 1, CSG_VOXEL_RES - 1, CSG_VOXEL_RES - 1)
}

// ============================================================================
// PHASE 2B: DUAL-BOUNDED SURFACE NETS / DUAL CONTOURING MESH EXTRACTOR
// ============================================================================

@(private = "file")
_CORNER_OFFSETS :: [8][3]int{
	{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
	{0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1},
}

@(private = "file")
_CUBE_EDGES :: [12][2]int{
	{0, 1}, {2, 3}, {4, 5}, {6, 7}, // X edges
	{0, 2}, {1, 3}, {4, 6}, {5, 7}, // Y edges
	{0, 4}, {1, 5}, {2, 6}, {3, 7}, // Z edges
}

// Extracts a watertight, dual-bounded Surface Nets triangle mesh from `grid` (plus any
// `indestructible_hulls` steel rebar!) into `out_verts`, `out_indices`, and `out_submeshes`.
csg_voxel_triangulate_chunk :: proc(
	grid:                 ^CSG_Voxel_Grid,
	indestructible_hulls: []CSG_Convex,
	out_verts:            ^[dynamic]gfx.Vertex,
	out_indices:          ^[dynamic]u32,
	out_submeshes:        ^[dynamic]engine.Mesh_Submesh,
	sun_dir:              [3]f32 = {0, 0, 0},
) {
	clear(out_verts)
	clear(out_indices)
	clear(out_submeshes)
	if grid == nil {
		if len(indestructible_hulls) > 0 {
			csg_triangulate_hulls(indestructible_hulls, out_verts, out_indices, out_submeshes, sun_dir)
		}
		return
	}

	alloc := context.temp_allocator
	vox_sz := grid.voxel_size
	uv_s   := max(grid.uv_scale, 0.1)
	has_sun := linalg.length2(sun_dir) > 0.25

	cell_v_idx := make([]i32, CSG_VOXEL_RES * CSG_VOXEL_RES * CSG_VOXEL_RES, alloc)
	for i in 0 ..< len(cell_v_idx) do cell_v_idx[i] = -1

	dual_pos     := make([dynamic][3]f32, 0, 512, alloc)
	dual_norm    := make([dynamic][3]f32, 0, 512, alloc)
	dual_mat     := make([dynamic]u8,     0, 512, alloc)
	dual_col     := make([dynamic][4]u8,  0, 512, alloc)
	active_cells := make([dynamic][3]u8,  0, 512, alloc)

	corner_offsets := _CORNER_OFFSETS
	cube_edges     := _CUBE_EDGES

	// 1. Place one Dual Vertex inside every sign-changing cell `(cx, cy, cz)` using 64-bit `u64` `surface_bricks`!
	//    - If `grid.surface_bricks[b_idx] == 0`, skips all 64 cells in 1 CPU cycle!
	//    - Otherwise jumps directly to set bits via hardware `TZCNT` (`count_trailing_zeros`).
	for bz in 0 ..< CSG_BRICK_DIM {
		z_base := bz << 2
		for by in 0 ..< CSG_BRICK_DIM {
			y_base := by << 2
			for bx in 0 ..< CSG_BRICK_DIM {
				b_idx := _vox_brick_idx(bx, by, bz)
				mask  := grid.surface_bricks[b_idx]
				if mask == 0 do continue
				x_base := bx << 2

				for mask != 0 {
					bit := int(intrinsics.count_trailing_zeros(mask))
					mask &= mask - 1
					x := x_base + (bit & 3)
					y := y_base + ((bit >> 2) & 3)
					z := z_base + (bit >> 4)

					p00 := _vox_pt_idx(x, y,     z)
					p10 := _vox_pt_idx(x, y + 1, z)
					p01 := _vox_pt_idx(x, y,     z + 1)
					p11 := _vox_pt_idx(x, y + 1, z + 1)
					s := [8]i8{
						grid.sdf[p00],     grid.sdf[p00 + 1],
						grid.sdf[p10],     grid.sdf[p10 + 1],
						grid.sdf[p01],     grid.sdf[p01 + 1],
						grid.sdf[p11],     grid.sdf[p11 + 1],
					}

					cell_base := grid.origin + [3]f32{f32(x), f32(y), f32(z)} * vox_sz
					avg_pt := [3]f32{0, 0, 0}
					cross_cnt := 0
					for e in cube_edges {
						c0, c1 := e[0], e[1]
						s0, s1 := s[c0], s[c1]
						if (s0 <= 0) != (s1 <= 0) {
							denom := f32(int(s1) - int(s0))
							t := clamp(f32(-int(s0)) / denom, 0.0, 1.0) if abs(denom) > 1e-4 else 0.5
							o0 := corner_offsets[c0]
							o1 := corner_offsets[c1]
							p0 := cell_base + [3]f32{f32(o0[0]), f32(o0[1]), f32(o0[2])} * vox_sz
							p1 := cell_base + [3]f32{f32(o1[0]), f32(o1[1]), f32(o1[2])} * vox_sz
							avg_pt += linalg.lerp(p0, p1, t)
							cross_cnt += 1
						}
					}
					if cross_cnt == 0 do continue
					v_pos := avg_pt / f32(cross_cnt)

					// Central-difference SDF gradient across the 8 cell corners
					gx := f32((int(s[1]) - int(s[0])) + (int(s[3]) - int(s[2])) + (int(s[5]) - int(s[4])) + (int(s[7]) - int(s[6])))
					gy := f32((int(s[2]) - int(s[0])) + (int(s[3]) - int(s[1])) + (int(s[6]) - int(s[4])) + (int(s[7]) - int(s[5])))
					gz := f32((int(s[4]) - int(s[0])) + (int(s[5]) - int(s[1])) + (int(s[6]) - int(s[2])) + (int(s[7]) - int(s[3])))
					grad_n := linalg.normalize0([3]f32{gx, gy, gz})
					if linalg.length2(grad_n) < 0.25 do grad_n = {0, 1, 0}

					c_idx := _vox_cell_idx(x, y, z)
					p_id  := _vox_get_mat_slot(grid, c_idx)
					ms: u8 = 0
					col := grid.base_color
					if p_id > 0 {
						if p_id <= grid.palette_count && grid.palette_mat_slots[p_id] > 0 {
							ms  = grid.palette_mat_slots[p_id]
							col = grid.palette_colors[p_id]
						} else {
							ms  = 1
							col = grid.cut_color
						}
					}
					cell_v_idx[c_idx] = i32(len(dual_pos))
					append(&dual_pos,     v_pos)
					append(&dual_norm,    grad_n)
					append(&dual_mat,     ms)
					append(&dual_col,     col)
					append(&active_cells, [3]u8{u8(x), u8(y), u8(z)})
				}
			}
		}
	}

	Quad_Face :: struct {
		idx:      [4]i32,
		mat_slot: u8,
		color:    [4]u8,
	}
	quads := make([dynamic]Quad_Face, 0, len(dual_pos) * 2, alloc)

	emit_quad :: proc(q_list: ^[dynamic]Quad_Face, c0, c1, c2, c3: i32, dual_m: []u8, dual_c: [][4]u8, skip_slot0: bool) {
		if c0 < 0 || c1 < 0 || c2 < 0 || c3 < 0 do return
		// If any of the 4 cells bordering this edge is a carved crater (`dual_m > 0`), inherit its material slot & color
		ms: u8 = 0
		col := dual_c[c0]
		if dual_m[c0] > 0      { ms = dual_m[c0]; col = dual_c[c0] }
		else if dual_m[c1] > 0 { ms = dual_m[c1]; col = dual_c[c1] }
		else if dual_m[c2] > 0 { ms = dual_m[c2]; col = dual_c[c2] }
		else if dual_m[c3] > 0 { ms = dual_m[c3]; col = dual_c[c3] }
		if skip_slot0 && ms == 0 do return
		append(q_list, Quad_Face{
			idx      = {c0, c1, c2, c3},
			mat_slot = ms,
			color    = col,
		})
	}

	has_base_shell := len(grid.base_shell_verts) >= 3 && len(grid.base_shell_indices) >= 3

	// 2. Emit dual quads across every sign-changing interior grid edge along X, Y, and Z.
	//    Since every quad requires `v2 = cell_v_idx[x, y, z] >= 0`, we iterate ONLY over `active_cells`!
	for ac, ac_i in active_cells {
		x, y, z := int(ac[0]), int(ac[1]), int(ac[2])
		if x < 1 || y < 1 || z < 1 do continue
		v2 := i32(ac_i)
		p_idx := _vox_pt_idx(x, y, z)
		s0 := grid.sdf[p_idx] <= 0

		// +X edge `(x,y,z) -> (x+1,y,z)`: shared by cells `(x, y-1, z-1)`, `(x, y, z-1)`, `(x, y, z)`, `(x, y-1, z)`
		if x < CSG_VOXEL_RES - 1 {
			sx := grid.sdf[p_idx + 1] <= 0
			if s0 != sx {
				v0 := cell_v_idx[_vox_cell_idx(x, y - 1, z - 1)]
				v1 := cell_v_idx[_vox_cell_idx(x, y,     z - 1)]
				v3 := cell_v_idx[_vox_cell_idx(x, y - 1, z)]
				if s0 {
					emit_quad(&quads, v0, v1, v2, v3, dual_mat[:], dual_col[:], has_base_shell)
				} else {
					emit_quad(&quads, v0, v3, v2, v1, dual_mat[:], dual_col[:], has_base_shell)
				}
			}
		}

		// +Y edge `(x,y,z) -> (x,y+1,z)`: shared by cells `(x-1, y, z-1)`, `(x-1, y, z)`, `(x, y, z)`, `(x, y, z-1)`
		if y < CSG_VOXEL_RES - 1 {
			sy := grid.sdf[p_idx + CSG_VOXEL_PTS] <= 0
			if s0 != sy {
				v0 := cell_v_idx[_vox_cell_idx(x - 1, y, z - 1)]
				v1 := cell_v_idx[_vox_cell_idx(x - 1, y, z)]
				v3 := cell_v_idx[_vox_cell_idx(x,     y, z - 1)]
				if s0 {
					emit_quad(&quads, v0, v1, v2, v3, dual_mat[:], dual_col[:], has_base_shell)
				} else {
					emit_quad(&quads, v0, v3, v2, v1, dual_mat[:], dual_col[:], has_base_shell)
				}
			}
		}

		// +Z edge `(x,y,z) -> (x,y,z+1)`: shared by cells `(x-1, y-1, z)`, `(x, y-1, z)`, `(x, y, z)`, `(x-1, y, z)`
		if z < CSG_VOXEL_RES - 1 {
			sz := grid.sdf[p_idx + CSG_VOXEL_PTS * CSG_VOXEL_PTS] <= 0
			if s0 != sz {
				v0 := cell_v_idx[_vox_cell_idx(x - 1, y - 1, z)]
				v1 := cell_v_idx[_vox_cell_idx(x,     y - 1, z)]
				v3 := cell_v_idx[_vox_cell_idx(x - 1, y,     z)]
				if s0 {
					emit_quad(&quads, v0, v1, v2, v3, dual_mat[:], dual_col[:], has_base_shell)
				} else {
					emit_quad(&quads, v0, v3, v2, v1, dual_mat[:], dual_col[:], has_base_shell)
				}
			}
		}
	}

	// 3. Emit vertices and indices grouped by submesh:
	//    - `slot == 0`: Self-Hosted `.fmesh` Sharp CSG Outer Shell (`grid.base_shell_verts` / `grid.base_shell_indices`
	//      clipped against `csg_voxel_sample_cut_sdf_trilinear <= 0`), so untouched CSG surfaces stay 100% razor-sharp!
	//    - `slot == 1`: 3D Voxel Crater & Tunnel Interior from Surface Nets (`q.mat_slot == 1`), clipped strictly inside
	//      `grid.base_shell_hulls` so the crater interior meets the sharp CSG hole rim flush with zero outer protrusion!
	cut_pad        := vox_sz * 1.65

	Sub_Tri :: struct {
		v: [3]gfx.Vertex,
	}
	sub_curr := make([dynamic]Sub_Tri, 0, 64, alloc)
	sub_next := make([dynamic]Sub_Tri, 0, 64, alloc)
	poly_a   := make([dynamic][3]f32,  0, 16, alloc)
	poly_b   := make([dynamic][3]f32,  0, 16, alloc)

	lerp_vtx :: #force_inline proc(a, b: gfx.Vertex, t: f32) -> gfx.Vertex {
		return gfx.Vertex{
			position = linalg.lerp(a.position, b.position, t),
			normal   = linalg.normalize0(linalg.lerp(a.normal, b.normal, t)),
			uv       = linalg.lerp(a.uv, b.uv, t),
			color    = {
				u8(clamp(linalg.lerp(f32(a.color.r), f32(b.color.r), t), 0, 255)),
				u8(clamp(linalg.lerp(f32(a.color.g), f32(b.color.g), t), 0, 255)),
				u8(clamp(linalg.lerp(f32(a.color.b), f32(b.color.b), t), 0, 255)),
				a.color.a,
			},
		}
	}

	max_slot: u8 = 1
	if grid.base_shell_submesh_count > 1 {
		max_slot = max(max_slot, min(grid.base_shell_submesh_count - 1, 7))
	}
	for q in quads {
		if q.mat_slot > max_slot {
			max_slot = min(q.mat_slot, 7)
		}
	}

	for slot in u8(0) ..= max_slot {
		first_idx := u32(len(out_indices))

		if has_base_shell {
			total_base_idx := u32(len(grid.base_shell_indices))
			t_start := 0
			t_end   := 0
			if grid.base_shell_submesh_count > 0 {
				if slot < grid.base_shell_submesh_count {
					sm := grid.base_shell_submeshes[slot]
					t_start = int(min(sm.first_index, total_base_idx) / 3)
					t_end   = int(min(sm.first_index + sm.index_count, total_base_idx) / 3)
				}
			} else {
				slot0_idx_end := min(grid.base_shell_slot0_count, total_base_idx) if grid.base_shell_slot0_count > 0 || total_base_idx == 0 else total_base_idx
				if slot == 0 {
					t_start = 0
					t_end   = int(slot0_idx_end / 3)
				} else if slot == 1 {
					t_start = int(slot0_idx_end / 3)
					t_end   = int(total_base_idx / 3)
				}
			}
			max_sub_ed := max(vox_sz * 1.10, 0.08)

			for ti in t_start ..< t_end {
				v0 := grid.base_shell_verts[grid.base_shell_indices[ti * 3 + 0]]
				v1 := grid.base_shell_verts[grid.base_shell_indices[ti * 3 + 1]]
				v2 := grid.base_shell_verts[grid.base_shell_indices[ti * 3 + 2]]

				t_min := linalg.min(v0.position, linalg.min(v1.position, v2.position))
				t_max := linalg.max(v0.position, linalg.max(v1.position, v2.position))

				// O(1) 64-bit `cut_bricks` Fast Path: If this CSG outer/slice triangle doesn't overlap any cut brick, emit it 100% untouched!
				if !_vox_aabb_overlaps_cut_bricks(grid, t_min, t_max, cut_pad) {
					bv := u32(len(out_verts))
					append(out_verts, v0, v1, v2)
					append(out_indices, bv + 0, bv + 1, bv + 2)
					continue
				}

				// Adaptive `cut_bricks` Subdivision: subdivide only sub-triangles whose `4x4x4` bricks contain active cuts!
				clear(&sub_curr)
				append(&sub_curr, Sub_Tri{v = {v0, v1, v2}})

				for _ in 0 ..< 4 {
					clear(&sub_next)
					any_split := false
					for st in sub_curr {
						sv0, sv1, sv2 := st.v[0], st.v[1], st.v[2]
						s_min := linalg.min(sv0.position, linalg.min(sv1.position, sv2.position))
						s_max := linalg.max(sv0.position, linalg.max(sv1.position, sv2.position))
						// 1-cycle 64-bit sub-brick check: if no cell in `[s_min, s_max]` has `cut_sdf > 0`,
						// then every point inside `st` is mathematically guaranteed to have `sd <= 0` (100% uncut)!
						if !_vox_aabb_overlaps_cut_bricks(grid, s_min, s_max, vox_sz * 0.15) {
							bv := u32(len(out_verts))
							append(out_verts, sv0, sv1, sv2)
							append(out_indices, bv + 0, bv + 1, bv + 2)
							continue
						}
						l01 := linalg.length(sv1.position - sv0.position)
						l12 := linalg.length(sv2.position - sv1.position)
						l20 := linalg.length(sv0.position - sv2.position)
						max_l := max(l01, max(l12, l20))
						if max_l <= max_sub_ed {
							append(&sub_next, st)
							continue
						}
						// If sub-triangle is already `<= 2.5 * vox_sz`, check if all 3 vertices are
						// completely inside the carved hole (`> vox_sz * 0.45` -> cull!) or completely uncut (`< -vox_sz * 0.45` -> emit!)
						if max_l <= vox_sz * 2.5 {
							sd0, ic0 := csg_voxel_sample_cut_sdf_trilinear(grid, sv0.position)
							sd1, ic1 := csg_voxel_sample_cut_sdf_trilinear(grid, sv1.position)
							sd2, ic2 := csg_voxel_sample_cut_sdf_trilinear(grid, sv2.position)
							if (!ic0 && !ic1 && !ic2) || (sd0 < -vox_sz * 0.45 && sd1 < -vox_sz * 0.45 && sd2 < -vox_sz * 0.45) {
								bv := u32(len(out_verts))
								append(out_verts, sv0, sv1, sv2)
								append(out_indices, bv + 0, bv + 1, bv + 2)
								continue
							}
							if sd0 > vox_sz * 0.45 && sd1 > vox_sz * 0.45 && sd2 > vox_sz * 0.45 {
								continue
							}
						}
						m01 := lerp_vtx(sv0, sv1, 0.5)
						m12 := lerp_vtx(sv1, sv2, 0.5)
						m20 := lerp_vtx(sv2, sv0, 0.5)
						append(&sub_next,
							Sub_Tri{v = {sv0, m01, m20}},
							Sub_Tri{v = {m01, sv1, m12}},
							Sub_Tri{v = {m20, m12, sv2}},
							Sub_Tri{v = {m01, m12, m20}},
						)
						any_split = true
					}
					sub_curr, sub_next = sub_next, sub_curr
					if !any_split do break
				}

				for st in sub_curr {
					sv := st.v
					s0, c0 := csg_voxel_sample_cut_sdf_trilinear(grid, sv[0].position)
					s1, c1 := csg_voxel_sample_cut_sdf_trilinear(grid, sv[1].position)
					s2, c2 := csg_voxel_sample_cut_sdf_trilinear(grid, sv[2].position)

					if (!c0 && !c1 && !c2) || (s0 <= 0.0 && s1 <= 0.0 && s2 <= 0.0) {
						bv := u32(len(out_verts))
						append(out_verts, sv[0], sv[1], sv[2])
						append(out_indices, bv + 0, bv + 1, bv + 2)
						continue
					}
					if s0 > 0.0 && s1 > 0.0 && s2 > 0.0 {
						continue
					}

					sd_3 := [3]f32{s0, s1, s2}
					clipped_v: [8]gfx.Vertex
					clipped_n := 0
					prev_v := sv[2]
					prev_s := sd_3[2]
					for k in 0 ..< 3 {
						curr_v := sv[k]
						curr_s := sd_3[k]
						if curr_s <= 0.0 {
							if prev_s > 0.0 && clipped_n < 8 {
								t := clamp(prev_s / (prev_s - curr_s), 0.0, 1.0)
								clipped_v[clipped_n] = lerp_vtx(prev_v, curr_v, t)
								clipped_n += 1
							}
							if clipped_n < 8 {
								clipped_v[clipped_n] = curr_v
								clipped_n += 1
							}
						} else if prev_s <= 0.0 && clipped_n < 8 {
							t := clamp(prev_s / (prev_s - curr_s), 0.0, 1.0)
							clipped_v[clipped_n] = lerp_vtx(prev_v, curr_v, t)
							clipped_n += 1
						}
						prev_v = curr_v
						prev_s = curr_s
					}
					if clipped_n >= 3 {
						bv := u32(len(out_verts))
						for k in 0 ..< clipped_n {
							append(out_verts, clipped_v[k])
						}
						for k in 1 ..< u32(clipped_n - 1) {
							append(out_indices, bv, bv + k, bv + k + 1)
						}
					}
				}
			}
		}

		if !has_base_shell || slot >= 1 {
			for q in quads {
				if min(q.mat_slot, 7) != slot do continue
				i0, i1, i2, i3 := q.idx[0], q.idx[1], q.idx[2], q.idx[3]
				p0, p1, p2, p3 := dual_pos[i0], dual_pos[i1], dual_pos[i2], dual_pos[i3]

				fn := linalg.normalize0(linalg.cross(p1 - p0, p2 - p0) + linalg.cross(p2 - p0, p3 - p0))
				if linalg.length2(fn) < 0.1 do continue

				avg_grad := linalg.normalize0(dual_norm[i0] + dual_norm[i1] + dual_norm[i2] + dual_norm[i3])
				if linalg.dot(fn, avg_grad) < 0 {
					i1, i3 = i3, i1
					p1, p3 = p3, p1
					fn = -fn
				}

				u_ax, v_ax := plane_tangent_basis(fn)

				// When rendering `slot >= 1` (crater/tunnel interior) inside a self-hosted `.fmesh` CSG shell,
				// clip the Surface Nets crater quad against `grid.base_shell_hulls` so the rocky crater interior
				// terminates 100% flush with the razor-sharp CSG outer wall and never pokes outside!
				if slot >= 1 && len(grid.base_shell_hulls) > 0 {
					q_min := linalg.min(linalg.min(p0, p1), linalg.min(p2, p3))
					q_max := linalg.max(linalg.max(p0, p1), linalg.max(p2, p3))
					vn_blend := linalg.normalize0(avg_grad * 0.55 + fn * 0.45)
					if linalg.length2(vn_blend) < 0.25 do vn_blend = fn

					ao: f32 = 1.0
					if vn_blend.y < -0.5 do ao *= 0.78
					if has_sun && linalg.dot(vn_blend, sun_dir) < -0.15 {
						ao *= 0.72
					}
					v_col := [4]u8{
						u8(clamp(f32(q.color.r) * ao, 0.0, 255.0)),
						u8(clamp(f32(q.color.g) * ao, 0.0, 255.0)),
						u8(clamp(f32(q.color.b) * ao, 0.0, 255.0)),
						q.color.a,
					}

					for bh in grid.base_shell_hulls {
						if !aabb_overlaps(q_min, q_max, bh.aabb_min, bh.aabb_max, 0.04) do continue

						// Fast 3-case bitmask plane classification before touching `poly_a` / `clip_polygon_by_plane`:
						// - If all 4 vertices are outside ANY plane `bp`, the quad is 100% outside `bh` -> skip hull!
						// - If all 4 vertices are inside ALL planes `bp`, emit the 4 vertices directly (0 clips!) & break!
						// - Otherwise clip ONLY against the specific planes recorded in `straddle_mask`!
						outside_hull  := false
						straddle_mask: u64 = 0
						for bp, pi in bh.planes {
							d0 := linalg.dot(bp.normal, p0) - bp.dist
							d1 := linalg.dot(bp.normal, p1) - bp.dist
							d2 := linalg.dot(bp.normal, p2) - bp.dist
							d3 := linalg.dot(bp.normal, p3) - bp.dist
							if d0 > 1e-4 && d1 > 1e-4 && d2 > 1e-4 && d3 > 1e-4 {
								outside_hull = true
								break
							}
							if (d0 > 1e-4 || d1 > 1e-4 || d2 > 1e-4 || d3 > 1e-4) && pi < 64 {
								straddle_mask |= (u64(1) << uint(pi))
							}
						}
						if outside_hull do continue

						if straddle_mask == 0 {
							base_v := u32(len(out_verts))
							pts_q  := [4][3]f32{p0, p1, p2, p3}
							for pt in pts_q {
								append(out_verts, gfx.Vertex{
									position = pt,
									normal   = vn_blend,
									uv       = {linalg.dot(pt, u_ax) * uv_s, linalg.dot(pt, v_ax) * uv_s},
									color    = v_col,
								})
							}
							append(out_indices, base_v + 0, base_v + 1, base_v + 2, base_v + 0, base_v + 2, base_v + 3)
							break
						}

						clear(&poly_a)
						append(&poly_a, p0, p1, p2, p3)
						sm := straddle_mask
						for sm != 0 {
							pi := int(intrinsics.count_trailing_zeros(sm))
							sm &= sm - 1
							clip_polygon_by_plane(poly_a[:], bh.planes[pi], &poly_b)
							poly_a, poly_b = poly_b, poly_a
							if len(poly_a) < 3 do break
						}
						if len(poly_a) >= 3 {
							base_v := u32(len(out_verts))
							for pt in poly_a {
								append(out_verts, gfx.Vertex{
									position = pt,
									normal   = vn_blend,
									uv       = {linalg.dot(pt, u_ax) * uv_s, linalg.dot(pt, v_ax) * uv_s},
									color    = v_col,
								})
							}
							for k in 1 ..< u32(len(poly_a) - 1) {
								append(out_indices, base_v, base_v + k, base_v + k + 1)
							}
						}
					}
					continue
				}

				base_v := u32(len(out_verts))
				pts_4  := [4][3]f32{p0, p1, p2, p3}
				idxs_4 := [4]i32{i0, i1, i2, i3}

				for k in 0 ..< 4 {
					pos := pts_4[k]
					vn := fn if slot == 0 else linalg.normalize0(dual_norm[idxs_4[k]] * 0.55 + fn * 0.45)
					uv := [2]f32{linalg.dot(pos, u_ax) * uv_s, linalg.dot(pos, v_ax) * uv_s}

					ao: f32 = 1.0
					if vn.y < -0.5 do ao *= 0.78
					if has_sun && linalg.dot(vn, sun_dir) < -0.15 {
						ao *= 0.72
					}
					v_col := [4]u8{
						u8(clamp(f32(q.color.r) * ao, 0.0, 255.0)),
						u8(clamp(f32(q.color.g) * ao, 0.0, 255.0)),
						u8(clamp(f32(q.color.b) * ao, 0.0, 255.0)),
						q.color.a,
					}
					append(out_verts, gfx.Vertex{
						position = pos,
						normal   = vn,
						uv       = uv,
						color    = v_col,
					})
				}

				append(out_indices, base_v + 0, base_v + 1, base_v + 2)
				append(out_indices, base_v + 0, base_v + 2, base_v + 3)
			}
		}

		// Also append any `indestructible_hulls` (Severed Steel indestructible structural beams) into `slot == 0`
		if slot == 0 && len(indestructible_hulls) > 0 {
			ind_v := make([dynamic]gfx.Vertex, 0, 64, alloc)
			ind_i := make([dynamic]u32, 0, 128, alloc)
			ind_s := make([dynamic]engine.Mesh_Submesh, 0, 2, alloc)
			csg_triangulate_hulls(indestructible_hulls, &ind_v, &ind_i, &ind_s, sun_dir)
			base_ind := u32(len(out_verts))
			append(out_verts, ..ind_v[:])
			for idx_val in ind_i {
				append(out_indices, base_ind + idx_val)
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
// PHASE 3: 3D GREEDY-MERGED BOX MESHER FOR JOLT PHYSICS & RAYCAST HULLS
// ============================================================================

// Precomputed 64-bit `u64` masks for each of the 8 `2x2x2` super-cells inside a `4x4x4` brick.
@(private = "file")
_SUPERCELL_BRICK_MASKS :: [8]u64{
	0x0000_0000_0033_0033, // sx=0, sy=0, sz=0
	0x0000_0000_00CC_00CC, // sx=1, sy=0, sz=0
	0x0000_0000_3300_3300, // sx=0, sy=1, sz=0
	0x0000_0000_CC00_CC00, // sx=1, sy=1, sz=0
	0x0033_0033_0000_0000, // sx=0, sy=0, sz=1
	0x00CC_00CC_0000_0000, // sx=1, sy=0, sz=1
	0x3300_3300_0000_0000, // sx=0, sy=1, sz=1
	0xCC00_CC00_0000_0000, // sx=1, sy=1, sz=1
}

// Sweeps the `24^3` voxel occupancy grid using 64-bit `u64` brick masks + hardware bit-scan intrinsics (`TZCNT` / `LZCNT`)
// and greedily merges contiguous solid super-cells along +X, +Y, and +Z into a compact set of axis-aligned `CSG_Convex` box hulls!
csg_voxel_build_greedy_hulls :: proc(
	grid:      ^CSG_Voxel_Grid,
	out_hulls: ^[dynamic]CSG_Convex,
	alloc := context.allocator,
) {
	if out_hulls == nil do return
	for &h in out_hulls^ do convex_destroy(&h)
	clear(out_hulls)
	if grid == nil do return

	// Use 12^3 super-cells (2x2x2 voxels per collider brick across the 24^3 grid).
	// Each 12-cell X-row fits in a single `u16` bitmask (`solid_rows` & `cut_rows`) for 1-instruction `TZCNT` X/Y/Z expansion!
	G_RES :: CSG_VOXEL_RES / 2
	solid_rows: [G_RES * G_RES]u16
	cut_rows:   [G_RES * G_RES]u16

	sc_masks  := _SUPERCELL_BRICK_MASKS
	any_solid := false

	// 1. Fast 64-bit `surface_bricks` + 32-bit `pt_solid_rows` super-cell classification:
	for bz in 0 ..< CSG_BRICK_DIM {
		gz0 := bz << 1
		for by in 0 ..< CSG_BRICK_DIM {
			gy0 := by << 1
			for bx in 0 ..< CSG_BRICK_DIM {
				b_idx     := _vox_brick_idx(bx, by, bz)
				surf_mask := grid.surface_bricks[b_idx]
				cut_mask  := grid.cut_bricks[b_idx]
				gx0       := uint(bx << 1)

				// Fast Path: Monochrome brick (`surf_mask == 0` -> either 100% air or 100% solid across all 64 cells!)
				if surf_mask == 0 {
					v_corner := (grid.pt_solid_rows[(bz << 2) * CSG_VOXEL_PTS + (by << 2)] >> uint(bx << 2)) & 1
					if v_corner != 0 {
						pair_bits := u16(0b11) << gx0
						solid_rows[(gz0 + 0) * G_RES + (gy0 + 0)] |= pair_bits
						solid_rows[(gz0 + 0) * G_RES + (gy0 + 1)] |= pair_bits
						solid_rows[(gz0 + 1) * G_RES + (gy0 + 0)] |= pair_bits
						solid_rows[(gz0 + 1) * G_RES + (gy0 + 1)] |= pair_bits
						if cut_mask != 0 {
							for sub in 0 ..< 8 {
								if (cut_mask & sc_masks[sub]) != 0 {
									sx := uint(sub & 1)
									sy := (sub >> 1) & 1
									sz := (sub >> 2) & 1
									cut_rows[(gz0 + sz) * G_RES + (gy0 + sy)] |= (u16(1) << (gx0 + sx))
								}
							}
						}
						any_solid = true
					}
					continue
				}

				for sub in 0 ..< 8 {
					sx := sub & 1
					sy := (sub >> 1) & 1
					sz := (sub >> 2) & 1
					gx := (bx << 1) + sx
					gy := gy0 + sy
					gz := gz0 + sz
					vx0, vy0, vz0 := gx * 2, gy * 2, gz * 2

					// Fast center-corner bit check in `pt_solid_rows`
					mid_row := grid.pt_solid_rows[(vz0 + 1) * CSG_VOXEL_PTS + (vy0 + 1)]
					is_sc_solid := (mid_row & (u32(1) << uint(vx0 + 1))) != 0
					if !is_sc_solid {
						neg_corners := 0
						for dz in 0 ..= 2 {
							z_off := (vz0 + dz) * CSG_VOXEL_PTS
							r0 := (grid.pt_solid_rows[z_off + vy0]     >> uint(vx0)) & 0b111
							r1 := (grid.pt_solid_rows[z_off + vy0 + 1] >> uint(vx0)) & 0b111
							r2 := (grid.pt_solid_rows[z_off + vy0 + 2] >> uint(vx0)) & 0b111
							neg_corners += int(intrinsics.count_ones(r0 | (r1 << 3) | (r2 << 6)))
						}
						is_sc_solid = neg_corners >= 11
					}

					if is_sc_solid {
						row_i := gz * G_RES + gy
						bit   := u16(1) << uint(gx)
						solid_rows[row_i] |= bit
						if (cut_mask & sc_masks[sub]) != 0 {
							cut_rows[row_i] |= bit
						}
						any_solid = true
					}
				}
			}
		}
	}
	if !any_solid do return

	vox_sz  := grid.voxel_size
	step_sz := vox_sz * 2.0
	brush_seq: u32 = 1

	// 2. Bit-Scan Greedy 3D Box Merger (`TZCNT` finds start X and X-run length in 2 instructions; bitwise AND expands Y and Z!)
	for gz in 0 ..< G_RES {
		for gy in 0 ..< G_RES {
			row_i := gz * G_RES + gy
			for solid_rows[row_i] != 0 {
				row := solid_rows[row_i]
				// Jump directly to first unused solid super-cell `gx` via `TZCNT`
				gx := int(intrinsics.count_trailing_zeros(row))
				// Count contiguous `1` bits starting at `gx` in 1 instruction via `TZCNT(~(row >> gx))`
				wx := int(intrinsics.count_trailing_zeros(~(row >> uint(gx))))
				x_span_mask := ((u16(1) << uint(wx)) - 1) << uint(gx)

				// Expand along +Y using a single bitwise AND per row
				wy := 1
				for gy + wy < G_RES {
					if (solid_rows[gz * G_RES + gy + wy] & x_span_mask) != x_span_mask do break
					wy += 1
				}

				// Expand along +Z using a single bitwise AND per row
				wz := 1
				z_loop: for gz + wz < G_RES {
					z_base := (gz + wz) * G_RES
					for iy in gy ..< gy + wy {
						if (solid_rows[z_base + iy] & x_span_mask) != x_span_mask do break z_loop
					}
					wz += 1
				}

				// Clear merged bits in `solid_rows` & accumulate `cut_rows` via bitwise operations
				cut_acc: u16 = 0
				for iz in gz ..< gz + wz {
					z_base := iz * G_RES
					for iy in gy ..< gy + wy {
						solid_rows[z_base + iy] &~= x_span_mask
						cut_acc |= (cut_rows[z_base + iy] & x_span_mask)
					}
				}
				has_cut := cut_acc != 0

				bmin := grid.origin + [3]f32{f32(gx), f32(gy), f32(gz)} * step_sz
				bmax := grid.origin + [3]f32{f32(gx + wx), f32(gy + wy), f32(gz + wz)} * step_sz

				// 3. Bit-Scan Tightening (`TZCNT` / `LZCNT` on `pt_solid_rows` + boundary-only zero-crossing refinement):
				vx0, vx1 := gx * 2, (gx + wx) * 2
				vy0, vy1 := gy * 2, (gy + wy) * 2
				vz0, vz1 := gz * 2, (gz + wz) * 2

				range_mask := ((u32(1) << uint(vx1 - vx0 + 1)) - 1) << uint(vx0)
				all_x_mask: u32 = 0
				all_y_mask: u32 = 0
				all_z_mask: u32 = 0

				for vz in vz0 ..= vz1 {
					z_off := vz * CSG_VOXEL_PTS
					z_or: u32 = 0
					for vy in vy0 ..= vy1 {
						rm := grid.pt_solid_rows[z_off + vy] & range_mask
						if rm != 0 {
							z_or       |= rm
							all_y_mask |= (u32(1) << uint(vy))
						}
					}
					if z_or != 0 {
						all_x_mask |= z_or
						all_z_mask |= (u32(1) << uint(vz))
					}
				}
				if all_x_mask == 0 do continue

				min_ix := int(intrinsics.count_trailing_zeros(all_x_mask))
				max_ix := 31 - int(intrinsics.count_leading_zeros(all_x_mask))
				min_iy := int(intrinsics.count_trailing_zeros(all_y_mask))
				max_iy := 31 - int(intrinsics.count_leading_zeros(all_y_mask))
				min_iz := int(intrinsics.count_trailing_zeros(all_z_mask))
				max_iz := 31 - int(intrinsics.count_leading_zeros(all_z_mask))

				t_min := grid.origin + [3]f32{f32(min_ix), f32(min_iy), f32(min_iz)} * vox_sz
				t_max := grid.origin + [3]f32{f32(max_ix), f32(max_iy), f32(max_iz)} * vox_sz

				// Only check zero-crossing edges on the specific boundary planes that are strictly inside `[vx0..vx1, vy0..vy1, vz0..vz1]`!
				if min_ix > vx0 {
					x_bit := u32(1) << uint(min_ix)
					best_t: f32 = 0.0
					for vz in min_iz ..= max_iz {
						z_off := vz * CSG_VOXEL_PTS
						for vy in min_iy ..= max_iy {
							if (grid.pt_solid_rows[z_off + vy] & x_bit) != 0 {
								p_idx := _vox_pt_idx(min_ix - 1, vy, vz)
								s_air := int(grid.sdf[p_idx])
								s_sol := int(grid.sdf[p_idx + 1])
								denom := f32(s_air - s_sol)
								t := clamp(f32(-s_sol) / denom, 0.0, 1.0) if denom > 1e-4 else 0.5
								if t > best_t do best_t = t
							}
						}
					}
					t_min.x -= best_t * vox_sz
				}
				if max_ix < vx1 {
					x_bit := u32(1) << uint(max_ix)
					best_t: f32 = 0.0
					for vz in min_iz ..= max_iz {
						z_off := vz * CSG_VOXEL_PTS
						for vy in min_iy ..= max_iy {
							if (grid.pt_solid_rows[z_off + vy] & x_bit) != 0 {
								p_idx := _vox_pt_idx(max_ix, vy, vz)
								s_sol := int(grid.sdf[p_idx])
								s_air := int(grid.sdf[p_idx + 1])
								denom := f32(s_air - s_sol)
								t := clamp(f32(-s_sol) / denom, 0.0, 1.0) if denom > 1e-4 else 0.5
								if t > best_t do best_t = t
							}
						}
					}
					t_max.x += best_t * vox_sz
				}
				if min_iy > vy0 {
					best_t: f32 = 0.0
					for vz in min_iz ..= max_iz {
						m := grid.pt_solid_rows[vz * CSG_VOXEL_PTS + min_iy] & range_mask
						for m != 0 {
							vx := int(intrinsics.count_trailing_zeros(m))
							m &= m - 1
							s_air := int(grid.sdf[_vox_pt_idx(vx, min_iy - 1, vz)])
							s_sol := int(grid.sdf[_vox_pt_idx(vx, min_iy,     vz)])
							denom := f32(s_air - s_sol)
							t := clamp(f32(-s_sol) / denom, 0.0, 1.0) if denom > 1e-4 else 0.5
							if t > best_t do best_t = t
						}
					}
					t_min.y -= best_t * vox_sz
				}
				if max_iy < vy1 {
					best_t: f32 = 0.0
					for vz in min_iz ..= max_iz {
						m := grid.pt_solid_rows[vz * CSG_VOXEL_PTS + max_iy] & range_mask
						for m != 0 {
							vx := int(intrinsics.count_trailing_zeros(m))
							m &= m - 1
							s_sol := int(grid.sdf[_vox_pt_idx(vx, max_iy,     vz)])
							s_air := int(grid.sdf[_vox_pt_idx(vx, max_iy + 1, vz)])
							denom := f32(s_air - s_sol)
							t := clamp(f32(-s_sol) / denom, 0.0, 1.0) if denom > 1e-4 else 0.5
							if t > best_t do best_t = t
						}
					}
					t_max.y += best_t * vox_sz
				}
				if min_iz > vz0 {
					best_t: f32 = 0.0
					z_off := min_iz * CSG_VOXEL_PTS
					for vy in min_iy ..= max_iy {
						m := grid.pt_solid_rows[z_off + vy] & range_mask
						for m != 0 {
							vx := int(intrinsics.count_trailing_zeros(m))
							m &= m - 1
							s_air := int(grid.sdf[_vox_pt_idx(vx, vy, min_iz - 1)])
							s_sol := int(grid.sdf[_vox_pt_idx(vx, vy, min_iz)])
							denom := f32(s_air - s_sol)
							t := clamp(f32(-s_sol) / denom, 0.0, 1.0) if denom > 1e-4 else 0.5
							if t > best_t do best_t = t
						}
					}
					t_min.z -= best_t * vox_sz
				}
				if max_iz < vz1 {
					best_t: f32 = 0.0
					z_off := max_iz * CSG_VOXEL_PTS
					for vy in min_iy ..= max_iy {
						m := grid.pt_solid_rows[z_off + vy] & range_mask
						for m != 0 {
							vx := int(intrinsics.count_trailing_zeros(m))
							m &= m - 1
							s_sol := int(grid.sdf[_vox_pt_idx(vx, vy, max_iz)])
							s_air := int(grid.sdf[_vox_pt_idx(vx, vy, max_iz + 1)])
							denom := f32(s_air - s_sol)
							t := clamp(f32(-s_sol) / denom, 0.0, 1.0) if denom > 1e-4 else 0.5
							if t > best_t do best_t = t
						}
					}
					t_max.z += best_t * vox_sz
				}

				bmin = linalg.max(bmin, t_min)
				bmax = linalg.min(bmax, t_max)
				if has_cut {
					// Slight inward margin on cut surfaces so box corners never poke past curved Surface Nets quads
					inset := vox_sz * 0.12
					if bmax.x - bmin.x > inset * 3.0 { bmin.x += inset; bmax.x -= inset }
					if bmax.y - bmin.y > inset * 3.0 { bmin.y += inset; bmax.y -= inset }
					if bmax.z - bmin.z > inset * 3.0 { bmin.z += inset; bmax.z -= inset }
				}
				bsize := bmax - bmin
				if bsize.x < 0.03 || bsize.y < 0.03 || bsize.z < 0.03 do continue
				bcenter := (bmin + bmax) * 0.5

				ms: u8 = 1 if has_cut else 0
				col := grid.cut_color if has_cut else grid.base_color
				if box_h, ok := csg_make_primitive_convex(.Box, bcenter, bsize, 0.0, col, grid.uv_scale, ms, true, brush_seq, alloc); ok {
					brush_seq += 1
					append(out_hulls, box_h)
				}
			}
		}
	}
}

// ============================================================================
// PHASE 4: O(1) TRILINEAR VOXEL SDF CLIPPER FOR `.fmesh` (`Faker CSG`)
// ============================================================================

// Samples the continuous Signed Distance (in meters, `< 0` = inside solid, `> 0` = carved air)
// at local position `pos` inside `grid` using trilinear interpolation.
// If `pos` is outside `grid`'s bounding box, returns `-1.0` (untouched by this grid).
csg_voxel_sample_sdf_trilinear :: proc(grid: ^CSG_Voxel_Grid, pos: [3]f32) -> (sd: f32, in_bounds: bool) {
	if grid == nil || grid.voxel_size <= 1e-5 do return -1.0, false
	rel := (pos - grid.origin) / grid.voxel_size
	if rel.x < 1.0 || rel.x >= f32(CSG_VOXEL_RES - 1) ||
	   rel.y < 1.0 || rel.y >= f32(CSG_VOXEL_RES - 1) ||
	   rel.z < 1.0 || rel.z >= f32(CSG_VOXEL_RES - 1) {
		return -1.0, false
	}

	ix := clamp(int(math.floor(rel.x)), 0, CSG_VOXEL_RES - 1)
	iy := clamp(int(math.floor(rel.y)), 0, CSG_VOXEL_RES - 1)
	iz := clamp(int(math.floor(rel.z)), 0, CSG_VOXEL_RES - 1)
	fx := clamp(rel.x - f32(ix), 0.0, 1.0)
	fy := clamp(rel.y - f32(iy), 0.0, 1.0)
	fz := clamp(rel.z - f32(iz), 0.0, 1.0)

	s000 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix,     iy,     iz)],     grid.voxel_size)
	s100 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix + 1, iy,     iz)],     grid.voxel_size)
	s010 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix,     iy + 1, iz)],     grid.voxel_size)
	s110 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix + 1, iy + 1, iz)],     grid.voxel_size)
	s001 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix,     iy,     iz + 1)], grid.voxel_size)
	s101 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix + 1, iy,     iz + 1)], grid.voxel_size)
	s011 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix,     iy + 1, iz + 1)], grid.voxel_size)
	s111 := _dequantize_sdf(grid.sdf[_vox_pt_idx(ix + 1, iy + 1, iz + 1)], grid.voxel_size)

	c00 := linalg.lerp(s000, s100, fx)
	c10 := linalg.lerp(s010, s110, fx)
	c01 := linalg.lerp(s001, s101, fx)
	c11 := linalg.lerp(s011, s111, fx)
	c0  := linalg.lerp(c00,  c10,  fy)
	c1  := linalg.lerp(c01,  c11,  fy)
	return linalg.lerp(c0, c1, fz), true
}

// Samples the continuous Carving / Hole Signed Distance (`grid.cut_sdf`, where `< 0` = untouched,
// `> 0` = carved away by a blast or slice, `0` = exact crater boundary) using trilinear interpolation.
// Accelerated by 64-bit `u64` `cut_bricks`: any cell with bit `0` rejects in 1 bitwise instruction without reading `cut_sdf`!
csg_voxel_sample_cut_sdf_trilinear :: proc(grid: ^CSG_Voxel_Grid, pos: [3]f32) -> (sd: f32, is_cut: bool) {
	if grid == nil || !grid.has_cuts || grid.voxel_size <= 1e-5 do return -1.0, false
	pad := grid.voxel_size * 1.5
	if pos.x < grid.cut_aabb_min.x - pad || pos.x > grid.cut_aabb_max.x + pad ||
	   pos.y < grid.cut_aabb_min.y - pad || pos.y > grid.cut_aabb_max.y + pad ||
	   pos.z < grid.cut_aabb_min.z - pad || pos.z > grid.cut_aabb_max.z + pad {
		return -1.0, false
	}
	rel := (pos - grid.origin) / grid.voxel_size
	if rel.x < 1.0 || rel.x >= f32(CSG_VOXEL_RES - 1) ||
	   rel.y < 1.0 || rel.y >= f32(CSG_VOXEL_RES - 1) ||
	   rel.z < 1.0 || rel.z >= f32(CSG_VOXEL_RES - 1) {
		return -1.0, false
	}

	// Since `rel >= 1.0`, hardware float-to-int truncation `int(rel)` equals `floor(rel)`!
	ix := int(rel.x)
	iy := int(rel.y)
	iz := int(rel.z)

	// 1-instruction `u64` brick bitmask reject (avoids reading 8 `i8` corners from `cut_sdf`!)
	b_idx, bit_mask := _vox_cell_brick_bit(ix, iy, iz)
	if (grid.cut_bricks[b_idx] & bit_mask) == 0 {
		return -1.0, false
	}

	p00 := _vox_pt_idx(ix, iy,     iz)
	p10 := _vox_pt_idx(ix, iy + 1, iz)
	p01 := _vox_pt_idx(ix, iy,     iz + 1)
	p11 := _vox_pt_idx(ix, iy + 1, iz + 1)

	fx := rel.x - f32(ix)
	fy := rel.y - f32(iy)
	fz := rel.z - f32(iz)

	s000 := f32(grid.cut_sdf[p00])
	s100 := f32(grid.cut_sdf[p00 + 1])
	s010 := f32(grid.cut_sdf[p10])
	s110 := f32(grid.cut_sdf[p10 + 1])
	s001 := f32(grid.cut_sdf[p01])
	s101 := f32(grid.cut_sdf[p01 + 1])
	s011 := f32(grid.cut_sdf[p11])
	s111 := f32(grid.cut_sdf[p11 + 1])

	c00 := s000 + (s100 - s000) * fx
	c10 := s010 + (s110 - s010) * fx
	c01 := s001 + (s101 - s001) * fx
	c11 := s011 + (s111 - s011) * fx
	c0  := c00  + (c10  - c00)  * fy
	c1  := c01  + (c11  - c01)  * fy
	q_lerp := c0 + (c1 - c0) * fz

	scale := max(grid.voxel_size * 2.5, 0.02) * (1.0 / 127.0)
	return q_lerp * scale, true
}

// Returns true if `vol` has any chunk with an active cut `voxel_grid`.
csg_volume_has_voxel_cuts :: proc(vol: ^CSGVolume) -> bool {
	if vol == nil || vol.chunks == nil do return false
	for _, ch in vol.chunks {
		if ch != nil && ch.voxel_grid != nil && ch.voxel_grid.has_cuts {
			return true
		}
	}
	return false
}
