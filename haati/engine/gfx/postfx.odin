// Dual-filter HDR bloom (Jimenez 13-tap downsample w/ soft-knee + Karis average
// on mip 0, 9-tap additive tent upsample) and single-pass exposure + ACES fitted
// composite into sRGB display targets.
package gfx

import sdl "vendor:sdl3"

BLOOM_MIP_COUNT :: 5

Post_FX_Config :: struct {
	bloom_enabled:   bool,
	bloom_threshold: f32,
	bloom_intensity: f32,
	bloom_scatter:   f32,
	exposure:        f32,
	tonemap_enabled: bool,
}

POST_FX_DEFAULT :: Post_FX_Config{
	bloom_enabled   = true,
	bloom_threshold = 1.0,
	bloom_intensity = 0.08,
	bloom_scatter   = 0.72,
	exposure        = 1.0,
	tonemap_enabled = true,
}

POST_FX_2D_DEFAULT :: Post_FX_Config{
	bloom_enabled   = false,
	bloom_threshold = 1.0,
	bloom_intensity = 0.0,
	bloom_scatter   = 0.72,
	exposure        = 1.0,
	tonemap_enabled = false,
}

// Sets Post-FX parameters for the active (or upcoming) HDR render pass.
// Resets to POST_FX_DEFAULT at the end of pass_end.
set_post_fx :: proc(cfg: Post_FX_Config) {
	_pass.post_fx = cfg
}

@(private = "file")
_Bloom_Down_UBO :: struct {
	params:    [4]f32, // xy = src_texel_size, z = is_first_pass (>0.5), w = unused
	threshold: [4]f32, // x = thresh, y = thresh - knee, z = 2 * knee, w = 0.25 / max(knee, 1e-4)
}

@(private = "file")
_Bloom_Up_UBO :: struct {
	params: [4]f32, // xy = filter_radius * src_texel_size, z = scatter, w = unused
}

@(private = "file")
_Composite_UBO :: struct {
	params: [4]f32, // x = exposure, y = bloom_intensity, z = tonemap_enabled (>0.5), w = bloom_enabled (>0.5)
}

@(private = "file")
_post_fx: struct {
	down_pipe: ^sdl.GPUGraphicsPipeline,
	up_pipe:   ^sdl.GPUGraphicsPipeline,
	comp_pipe: ^sdl.GPUGraphicsPipeline,
}

@(private = "file")
_create_fullscreen_pipeline :: proc(
	vert: ^sdl.GPUShader,
	frag_samplers: u32,
	frag_ubos: u32,
	frag_spv, frag_msl: []u8,
	target_format: sdl.GPUTextureFormat,
	additive: bool,
) -> ^sdl.GPUGraphicsPipeline {
	frag := _create_shader(.FRAGMENT, frag_samplers, frag_ubos, frag_spv, frag_msl)
	if frag == nil do return nil
	defer sdl.ReleaseGPUShader(_gfx.device, frag)

	color_target := sdl.GPUColorTargetDescription{
		format = target_format,
	}
	if additive {
		color_target.blend_state = sdl.GPUColorTargetBlendState{
			src_color_blendfactor = .ONE,
			dst_color_blendfactor = .ONE,
			color_blend_op        = .ADD,
			src_alpha_blendfactor = .ONE,
			dst_alpha_blendfactor = .ONE,
			alpha_blend_op        = .ADD,
			enable_blend          = true,
		}
	}

	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = vert,
		fragment_shader = frag,
		primitive_type  = .TRIANGLELIST,
		rasterizer_state = {
			cull_mode         = .NONE,
			enable_depth_clip = true,
		},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets         = 1,
			has_depth_stencil_target  = false,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(_gfx.device, info)
}

_post_fx_init :: proc() -> bool {
	if _gfx.device == nil do return false
	vert := _create_shader(.VERTEX, 0, 0, _POSTFX_VERT_SPV, _POSTFX_VERT_MSL)
	if vert == nil do return false
	defer sdl.ReleaseGPUShader(_gfx.device, vert)

	_post_fx.down_pipe = _create_fullscreen_pipeline(vert, 1, 1, _BLOOM_DOWN_SPV, _BLOOM_DOWN_MSL, _gfx.hdr_format, false)
	_post_fx.up_pipe   = _create_fullscreen_pipeline(vert, 1, 1, _BLOOM_UP_SPV, _BLOOM_UP_MSL, _gfx.hdr_format, true)
	_post_fx.comp_pipe = _create_fullscreen_pipeline(vert, 2, 1, _COMP_TONEMAP_SPV, _COMP_TONEMAP_MSL, _gfx.swapchain_format, false)
	if _post_fx.down_pipe == nil || _post_fx.up_pipe == nil || _post_fx.comp_pipe == nil {
		_post_fx_shutdown()
		return false
	}
	return true
}

_post_fx_shutdown :: proc() {
	if _gfx.device != nil {
		if _post_fx.down_pipe != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, _post_fx.down_pipe)
		if _post_fx.up_pipe != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, _post_fx.up_pipe)
		if _post_fx.comp_pipe != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, _post_fx.comp_pipe)
	}
	_post_fx = {}
}

_post_fx_resolve :: proc(
	cmd: ^sdl.GPUCommandBuffer,
	rt: ^Render_Target,
	dst_color: ^sdl.GPUTexture,
	dst_w, dst_h: u32,
	cfg: Post_FX_Config,
) {
	if cmd == nil || _gfx.device == nil || rt == nil || rt.hdr_color == nil || dst_color == nil || dst_w == 0 || dst_h == 0 {
		return
	}
	if _post_fx.comp_pipe == nil do return

	mip_count := 0
	for i in 0 ..< BLOOM_MIP_COUNT {
		if rt.bloom_mips[i] == nil || rt.bloom_mip_w[i] == 0 || rt.bloom_mip_h[i] == 0 {
			break
		}
		mip_count += 1
	}

	bloom_active := cfg.bloom_enabled && cfg.bloom_intensity > 1e-4 && mip_count > 0 && _post_fx.down_pipe != nil && _post_fx.up_pipe != nil
	if bloom_active {
		thresh := max(cfg.bloom_threshold, f32(0.0))
		knee := thresh * 0.5
		thresh_vec := [4]f32{thresh, thresh - knee, 2.0 * knee, 0.25 / max(knee, 1e-4)}

		// 1. Progressive 13-tap downsample pyramid from hdr_color -> mips[0..mip_count-1].
		for i in 0 ..< mip_count {
			src_tex := i == 0 ? rt.hdr_color : rt.bloom_mips[i - 1]
			src_w := i == 0 ? u32(max(rt.width, 1)) : rt.bloom_mip_w[i - 1]
			src_h := i == 0 ? u32(max(rt.height, 1)) : rt.bloom_mip_h[i - 1]

			ct := sdl.GPUColorTargetInfo{
				texture  = rt.bloom_mips[i],
				load_op  = .DONT_CARE,
				store_op = .STORE,
			}
			rp := sdl.BeginGPURenderPass(cmd, &ct, 1, nil)
			if rp == nil do continue
			sdl.BindGPUGraphicsPipeline(rp, _post_fx.down_pipe)
			smp := sdl.GPUTextureSamplerBinding{texture = src_tex, sampler = _gfx.sampler_linear}
			sdl.BindGPUFragmentSamplers(rp, 0, &smp, 1)
			ubo := _Bloom_Down_UBO{
				params    = {1.0 / f32(max(src_w, 1)), 1.0 / f32(max(src_h, 1)), i == 0 ? 1.0 : 0.0, 0.0},
				threshold = thresh_vec,
			}
			sdl.PushGPUFragmentUniformData(cmd, 0, &ubo, size_of(_Bloom_Down_UBO))
			sdl.DrawGPUPrimitives(rp, 3, 1, 0, 0)
			sdl.EndGPURenderPass(rp)
		}

		// 2. Additive 9-tap tent upsample from coarsest mip back into bloom_mips[0].
		scatter := clamp(cfg.bloom_scatter, f32(0.0), f32(1.0))
		for i := mip_count - 1; i >= 1; i -= 1 {
			src_tex := rt.bloom_mips[i]
			src_w := rt.bloom_mip_w[i]
			src_h := rt.bloom_mip_h[i]

			ct := sdl.GPUColorTargetInfo{
				texture  = rt.bloom_mips[i - 1],
				load_op  = .LOAD,
				store_op = .STORE,
			}
			rp := sdl.BeginGPURenderPass(cmd, &ct, 1, nil)
			if rp == nil do continue
			sdl.BindGPUGraphicsPipeline(rp, _post_fx.up_pipe)
			smp := sdl.GPUTextureSamplerBinding{texture = src_tex, sampler = _gfx.sampler_linear}
			sdl.BindGPUFragmentSamplers(rp, 0, &smp, 1)
			ubo := _Bloom_Up_UBO{
				params = {1.0 / f32(max(src_w, 1)), 1.0 / f32(max(src_h, 1)), scatter, 0.0},
			}
			sdl.PushGPUFragmentUniformData(cmd, 0, &ubo, size_of(_Bloom_Up_UBO))
			sdl.DrawGPUPrimitives(rp, 3, 1, 0, 0)
			sdl.EndGPURenderPass(rp)
		}
	}

	// 3. Final composite + ACES fitted tonemap + linear -> sRGB into dst_color.
	ct := sdl.GPUColorTargetInfo{
		texture  = dst_color,
		load_op  = .DONT_CARE,
		store_op = .STORE,
	}
	rp := sdl.BeginGPURenderPass(cmd, &ct, 1, nil)
	if rp == nil do return
	sdl.BindGPUGraphicsPipeline(rp, _post_fx.comp_pipe)
	bloom_tex := bloom_active ? rt.bloom_mips[0] : (_gfx.white_tex != nil ? _gfx.white_tex.gpu : rt.hdr_color)
	bindings := [2]sdl.GPUTextureSamplerBinding{
		{texture = rt.hdr_color, sampler = _gfx.sampler_linear},
		{texture = bloom_tex, sampler = _gfx.sampler_linear},
	}
	sdl.BindGPUFragmentSamplers(rp, 0, &bindings[0], 2)
	comp_ubo := _Composite_UBO{
		params = {
			cfg.exposure > 0 ? cfg.exposure : 1.0,
			max(cfg.bloom_intensity, f32(0.0)),
			cfg.tonemap_enabled ? 1.0 : 0.0,
			bloom_active ? 1.0 : 0.0,
		},
	}
	sdl.PushGPUFragmentUniformData(cmd, 0, &comp_ubo, size_of(_Composite_UBO))
	sdl.DrawGPUPrimitives(rp, 3, 1, 0, 0)
	sdl.EndGPURenderPass(rp)
}
