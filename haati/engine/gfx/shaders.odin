// Compiled shader blobs embedded at build time; the runtime picks the format
// the device accepts. MSL entry point is main0 (spirv-cross convention),
// SPIR-V is main. See `mh shaders`.
//
// Built-in shaders (one vertex shader, per-shader fragment): "unlit" and
// "lit", registered in init. shader_register is the seam a future custom
// shader importer plugs into — pipelines are name-keyed (see gfx.odin).
package gfx

import sdl "vendor:sdl3"

@(private) _WORLD_VERT_SPV := #load("shaders/compiled/world.vert.spv")
@(private) _WORLD_FRAG_SPV := #load("shaders/compiled/world.frag.spv")
@(private) _WORLD_VERT_MSL := #load("shaders/compiled/world.vert.msl")
@(private) _WORLD_FRAG_MSL := #load("shaders/compiled/world.frag.msl")
@(private) _LIT_FRAG_SPV   := #load("shaders/compiled/lit.frag.spv")
@(private) _LIT_FRAG_MSL   := #load("shaders/compiled/lit.frag.msl")
@(private) _DEPTH_FRAG_SPV    := #load("shaders/compiled/depth.frag.spv")
@(private) _DEPTH_FRAG_MSL    := #load("shaders/compiled/depth.frag.msl")
@(private) _POSTFX_VERT_SPV   := #load("shaders/compiled/postfx.vert.spv")
@(private) _POSTFX_VERT_MSL   := #load("shaders/compiled/postfx.vert.msl")
@(private) _BLOOM_DOWN_SPV    := #load("shaders/compiled/bloom_downsample.frag.spv")
@(private) _BLOOM_DOWN_MSL    := #load("shaders/compiled/bloom_downsample.frag.msl")
@(private) _BLOOM_UP_SPV      := #load("shaders/compiled/bloom_upsample.frag.spv")
@(private) _BLOOM_UP_MSL      := #load("shaders/compiled/bloom_upsample.frag.msl")
@(private) _COMP_TONEMAP_SPV  := #load("shaders/compiled/composite_tonemap.frag.spv")
@(private) _COMP_TONEMAP_MSL  := #load("shaders/compiled/composite_tonemap.frag.msl")

// num_* counts must match the shader's declared resources per SDL_GPU
// convention (vertex UBO set=1, fragment sampler2D set=2 in the GLSL source).
_create_shader :: proc(stage: sdl.GPUShaderStage, num_samplers, num_uniform_buffers: u32, spv, msl: []u8) -> ^sdl.GPUShader {
	formats := sdl.GetGPUShaderFormats(_gfx.device)
	info := sdl.GPUShaderCreateInfo{
		stage                = stage,
		num_samplers         = num_samplers,
		num_uniform_buffers  = num_uniform_buffers,
	}
	if .MSL in formats {
		info.format = {.MSL}
		info.entrypoint = "main0"
		info.code = raw_data(msl)
		info.code_size = len(msl)
	} else if .SPIRV in formats {
		info.format = {.SPIRV}
		info.entrypoint = "main"
		info.code = raw_data(spv)
		info.code_size = len(spv)
	} else {
		return nil
	}
	return sdl.CreateGPUShader(_gfx.device, info)
}
