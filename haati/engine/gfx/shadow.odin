// 16-tile 4096x4096 (4x4 grid of 1024x1024 tiles) shadow atlas:
//   Tiles 0..2  : Directional CSM (3 cascades)
//   Tile  3     : Primary Spot light
//   Tiles 4..9  : Point light 0 cubemap (+X, -X, +Y, -Y, +Z, -Z)
//   Tiles 10..15: Point light 1 cubemap (+X, -X, +Y, -Y, +Z, -Z)
package gfx

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

SHADOW_ATLAS_SIZE :: 4096
SHADOW_TILE_SIZE :: 1024
SHADOW_CASCADE_SPLITS :: [3]f32{16.0, 48.0, 128.0}

@(private)
_shadow: struct {
	atlas:    ^sdl.GPUTexture,
	sampler:  ^sdl.GPUSampler,
	pipeline: ^sdl.GPUGraphicsPipeline,
}

@(private)
_shadow_probe_depth_format :: proc() -> sdl.GPUTextureFormat {
	for candidate in ([?]sdl.GPUTextureFormat{.D32_FLOAT, .D24_UNORM, .D16_UNORM}) {
		if sdl.GPUTextureSupportsFormat(_gfx.device, candidate, .D2, {.DEPTH_STENCIL_TARGET, .SAMPLER}) {
			return candidate
		}
	}
	return _depth_format()
}

@(private)
_shadow_init :: proc() -> bool {
	if _gfx.device == nil do return false
	fmt := _shadow_probe_depth_format()
	_shadow.atlas = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = fmt,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = SHADOW_ATLAS_SIZE,
		height               = SHADOW_ATLAS_SIZE,
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if _shadow.atlas == nil do return false

	_shadow.sampler = sdl.CreateGPUSampler(_gfx.device, sdl.GPUSamplerCreateInfo{
		min_filter     = .NEAREST,
		mag_filter     = .NEAREST,
		mipmap_mode    = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	})
	if _shadow.sampler == nil {
		_shadow_shutdown()
		return false
	}

	vert := _create_shader(.VERTEX, 0, 1, _WORLD_VERT_SPV, _WORLD_VERT_MSL)
	frag := _create_shader(.FRAGMENT, 0, 0, _DEPTH_FRAG_SPV, _DEPTH_FRAG_MSL)
	if vert == nil || frag == nil {
		if vert != nil do sdl.ReleaseGPUShader(_gfx.device, vert)
		if frag != nil do sdl.ReleaseGPUShader(_gfx.device, frag)
		_shadow_shutdown()
		return false
	}
	defer sdl.ReleaseGPUShader(_gfx.device, vert)
	defer sdl.ReleaseGPUShader(_gfx.device, frag)

	buffer_desc := sdl.GPUVertexBufferDescription{
		slot       = 0,
		pitch      = size_of(Vertex),
		input_rate = .VERTEX,
	}
	attributes := [4]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, position))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, uv))},
		{location = 3, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Vertex, color))},
	}

	_shadow.pipeline = sdl.CreateGPUGraphicsPipeline(_gfx.device, sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffer_desc,
			num_vertex_buffers         = 1,
			vertex_attributes          = raw_data(attributes[:]),
			num_vertex_attributes      = len(attributes),
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {
			depth_bias_constant_factor = 1.5,
			depth_bias_slope_factor    = 2.0,
			enable_depth_bias          = true,
			enable_depth_clip          = true,
		},
		depth_stencil_state = {
			compare_op         = .LESS_OR_EQUAL,
			enable_depth_test  = true,
			enable_depth_write = true,
		},
		target_info = {
			num_color_targets        = 0,
			depth_stencil_format     = fmt,
			has_depth_stencil_target = true,
		},
	})
	if _shadow.pipeline == nil {
		_shadow_shutdown()
		return false
	}
	return true
}

@(private)
_shadow_shutdown :: proc() {
	if _gfx.device != nil {
		if _shadow.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, _shadow.pipeline)
		if _shadow.sampler != nil do sdl.ReleaseGPUSampler(_gfx.device, _shadow.sampler)
		if _shadow.atlas != nil do sdl.ReleaseGPUTexture(_gfx.device, _shadow.atlas)
	}
	_shadow = {}
}

// Computes 3 world-texel-snapped orthographic shadow view-projection matrices
// (SDL_GPU Z in [0, 1]) centered around `cam_pos` for a directional light.
shadow_compute_directional_csm :: proc(light_dir, cam_pos: [3]f32, splits := SHADOW_CASCADE_SPLITS) -> (mats: [3]matrix[4, 4]f32) {
	dir := linalg.normalize0(light_dir)
	if linalg.length2(dir) < 1e-8 {
		dir = {0, -1, 0}
	}
	up_ref := [3]f32{0, 1, 0}
	if abs(linalg.dot(dir, up_ref)) > 0.99 {
		up_ref = {0, 0, 1}
	}
	// Right-handed basis: viewer looks along `dir` (so view +Z points along `-dir`).
	fwd := -dir
	right := linalg.normalize0(linalg.cross(up_ref, fwd))
	cam_up := linalg.cross(fwd, right)

	cam_lx := linalg.dot(cam_pos, right)
	cam_ly := linalg.dot(cam_pos, cam_up)
	cam_lz := linalg.dot(cam_pos, fwd)

	for i in 0 ..< 3 {
		radius := max(splits[i], 1.0)
		texel_world := (2.0 * radius) / f32(SHADOW_TILE_SIZE)
		snapped_x := math.floor(cam_lx / texel_world) * texel_world
		snapped_y := math.floor(cam_ly / texel_world) * texel_world
		center := right * snapped_x + cam_up * snapped_y + fwd * cam_lz

		depth_range := max(radius * 3.0, 120.0)
		eye := center + fwd * depth_range
		view := linalg.matrix4_look_at_f32(eye, center, cam_up)
		proj := matrix4_ortho_z01(-radius, radius, -radius, radius, 0.1, depth_range * 2.0)
		mats[i] = proj * view
	}
	return mats
}

// Computes a perspective shadow view-projection matrix (SDL_GPU Z in [0, 1])
// covering a spot light's outer cone up to `range`.
shadow_compute_spot_matrix :: proc(pos, dir: [3]f32, outer_cos, range: f32) -> matrix[4, 4]f32 {
	d := linalg.normalize0(dir)
	if linalg.length2(d) < 1e-8 {
		d = {0, -1, 0}
	}
	half_angle := math.acos(clamp(outer_cos, 0.01, 0.9999))
	fov := clamp(half_angle * 2.0, 0.1, math.PI * 0.95)
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(d, up)) > 0.99 {
		up = {0, 0, 1}
	}
	view := linalg.matrix4_look_at_f32(pos, pos + d, up)
	proj := matrix4_perspective_z01(fov, 1.0, 0.1, max(range, 1.0))
	return proj * view
}

// Selects cubemap face index 0..5 (+X, -X, +Y, -Y, +Z, -Z) for `offset = world_pos - light_pos`.
shadow_select_point_face :: proc(offset: [3]f32) -> int {
	ax := abs(offset.x)
	ay := abs(offset.y)
	az := abs(offset.z)
	if ax >= ay && ax >= az {
		return offset.x >= 0 ? 0 : 1
	}
	if ay >= az {
		return offset.y >= 0 ? 2 : 3
	}
	return offset.z >= 0 ? 4 : 5
}

// Computes perspective shadow view-projection matrix (SDL_GPU Z in [0, 1])
// for cubemap face 0..5 of a point light with a 92-degree FOV guard band.
shadow_point_face_vp :: proc(light_pos: [3]f32, face: int, range: f32) -> matrix[4, 4]f32 {
	dir, up: [3]f32
	switch face {
	case 0:
		dir = {1, 0, 0}
		up = {0, 1, 0}
	case 1:
		dir = {-1, 0, 0}
		up = {0, 1, 0}
	case 2:
		dir = {0, 1, 0}
		up = {0, 0, -1}
	case 3:
		dir = {0, -1, 0}
		up = {0, 0, 1}
	case 4:
		dir = {0, 0, 1}
		up = {0, 1, 0}
	case 5:
		dir = {0, 0, -1}
		up = {0, 1, 0}
	case:
		dir = {1, 0, 0}
		up = {0, 1, 0}
	}
	fov := f32(92.0 * math.RAD_PER_DEG)
	view := linalg.matrix4_look_at_f32(light_pos, light_pos + dir, up)
	proj := matrix4_perspective_z01(fov, 1.0, 0.08, max(range, 1.0))
	return proj * view
}

@(private = "file")
_render_shadow_tile :: proc(rp: ^sdl.GPURenderPass, tile_col, tile_row: i32, vp: matrix[4, 4]f32) {
	sdl.SetGPUViewport(rp, sdl.GPUViewport{
		x         = f32(tile_col * SHADOW_TILE_SIZE),
		y         = f32(tile_row * SHADOW_TILE_SIZE),
		w         = f32(SHADOW_TILE_SIZE),
		h         = f32(SHADOW_TILE_SIZE),
		min_depth = 0.0,
		max_depth = 1.0,
	})
	bound_vb: ^sdl.GPUBuffer
	bound_ib: ^sdl.GPUBuffer
	for &d in _pass.draws {
		if !d.is_mesh || d.no_shadow || d.mesh.vbuf == nil || d.mesh.ibuf == nil || d.mesh_count == 0 do continue
		if d.kind != .Tris && d.kind != .Tris_Depth do continue
		if d.mesh.vbuf != bound_vb {
			vb := sdl.GPUBufferBinding{buffer = d.mesh.vbuf}
			sdl.BindGPUVertexBuffers(rp, 0, &vb, 1)
			bound_vb = d.mesh.vbuf
		}
		if d.mesh.ibuf != bound_ib {
			ib := sdl.GPUBufferBinding{buffer = d.mesh.ibuf}
			sdl.BindGPUIndexBuffer(rp, ib, ._32BIT)
			bound_ib = d.mesh.ibuf
		}
		u := _Uniform{view_proj = vp, model = d.model, tint = {1, 1, 1, 1}}
		sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
		sdl.DrawGPUIndexedPrimitives(rp, d.mesh_count, 1, d.mesh_first, 0, 0)
	}
}

// Populates shadow matrices on the current pass's light uniform and renders the
// 4096x4096 16-tile depth atlas (tiles 0..2 dir CSM, 3 spot, 4..9 point0, 10..15 point1).
shadow_render_pass :: proc(cam_pos: [3]f32) {
	if !_pass.active || _gfx.cmd == nil || _shadow.atlas == nil || _shadow.pipeline == nil do return

	light := _pass.light.? or_else _LIGHT_DEFAULT
	count := min(int(light.ambient_count.y), MAX_LIGHTS)

	dir_idx := -1
	spot_idx := -1
	point0_idx := -1
	point1_idx := -1
	point0_d2 := f32(1e30)
	point1_d2 := f32(1e30)
	for i in 0 ..< count {
		gl := light.lights[i]
		if gl.params.y >= -1.5 do continue
		if gl.pos_type.w < 0.5 {
			if dir_idx < 0 do dir_idx = i
		} else if gl.pos_type.w > 1.5 {
			if spot_idx < 0 do spot_idx = i
		} else {
			delta := gl.pos_type.xyz - cam_pos
			d2 := linalg.dot(delta, delta)
			if d2 < point0_d2 {
				point1_idx = point0_idx
				point1_d2 = point0_d2
				point0_idx = i
				point0_d2 = d2
			} else if d2 < point1_d2 {
				point1_idx = i
				point1_d2 = d2
			}
		}
	}

	if dir_idx < 0 && spot_idx < 0 && point0_idx < 0 {
		light.shadow_atlas_info = {}
		light.cascade_splits.w = -1.0
		light.point_shadow_info = {-1.0, -1.0, 0.0, 0.0}
		_pass.light = light
		return
	}

	_flush_pending_skinning(_gfx.cmd)

	if dir_idx >= 0 {
		gl := light.lights[dir_idx]
		csm_mats := shadow_compute_directional_csm(gl.dir_range.xyz, cam_pos)
		light.shadow_mats[0] = csm_mats[0]
		light.shadow_mats[1] = csm_mats[1]
		light.shadow_mats[2] = csm_mats[2]
	}

	if spot_idx >= 0 {
		gl := light.lights[spot_idx]
		light.shadow_mats[3] = shadow_compute_spot_matrix(gl.pos_type.xyz, gl.dir_range.xyz, gl.color_outer.w, gl.dir_range.w)
	}

	if point0_idx >= 0 {
		gl := light.lights[point0_idx]
		for f in 0 ..< 6 {
			light.shadow_mats[4 + f] = shadow_point_face_vp(gl.pos_type.xyz, f, gl.dir_range.w)
		}
	}

	if point1_idx >= 0 {
		gl := light.lights[point1_idx]
		for f in 0 ..< 6 {
			light.shadow_mats[10 + f] = shadow_point_face_vp(gl.pos_type.xyz, f, gl.dir_range.w)
		}
	}

	light.cascade_splits = {SHADOW_CASCADE_SPLITS[0], SHADOW_CASCADE_SPLITS[1], SHADOW_CASCADE_SPLITS[2], f32(spot_idx)}
	light.shadow_atlas_info = {
		1.0 / f32(SHADOW_ATLAS_SIZE),
		dir_idx >= 0 ? 1.0 : 0.0,
		spot_idx >= 0 ? 1.0 : 0.0,
		1.0,
	}
	light.point_shadow_info = {
		f32(point0_idx),
		f32(point1_idx),
		point0_idx >= 0 ? 1.0 : 0.0,
		point1_idx >= 0 ? 1.0 : 0.0,
	}
	_pass.light = light

	has_meshes := false
	for &d in _pass.draws {
		if d.is_mesh && !d.no_shadow && d.mesh.vbuf != nil && d.mesh.ibuf != nil && d.mesh_count > 0 && (d.kind == .Tris || d.kind == .Tris_Depth) {
			has_meshes = true
			break
		}
	}
	if !has_meshes do return

	depth_info := sdl.GPUDepthStencilTargetInfo{
		texture          = _shadow.atlas,
		clear_depth      = 1.0,
		load_op          = .CLEAR,
		store_op         = .STORE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}
	rp := sdl.BeginGPURenderPass(_gfx.cmd, nil, 0, &depth_info)
	if rp == nil do return
	sdl.BindGPUGraphicsPipeline(rp, _shadow.pipeline)
	if dir_idx >= 0 {
		for tile in 0 ..< 3 {
			_render_shadow_tile(rp, i32(tile % 4), i32(tile / 4), light.shadow_mats[tile])
		}
	}
	if spot_idx >= 0 {
		_render_shadow_tile(rp, i32(3 % 4), i32(3 / 4), light.shadow_mats[3])
	}
	if point0_idx >= 0 {
		for f in 0 ..< 6 {
			tile := 4 + f
			_render_shadow_tile(rp, i32(tile % 4), i32(tile / 4), light.shadow_mats[tile])
		}
	}
	if point1_idx >= 0 {
		for f in 0 ..< 6 {
			tile := 10 + f
			_render_shadow_tile(rp, i32(tile % 4), i32(tile / 4), light.shadow_mats[tile])
		}
	}
	sdl.EndGPURenderPass(rp)
}
