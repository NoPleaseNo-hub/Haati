// GPU device, pipelines, textures, meshes, and the frame lifecycle on
// SDL_GPU. One shader pair serves every pipeline; draws are batched CPU-side
// per pass (see pass.odin).
package gfx

import "base:runtime"
import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// One vertex format for the CPU batch AND meshes. Normals are unused by the
// unlit shader; reserved for lighting.
Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
	color:    [4]u8,
}

Texture_Filter :: enum u8 {
	Linear  = 0,
	Nearest = 1,
}

Texture_Wrap :: enum u8 {
	Default = 0, // Meshes -> Repeat, Quads/Sprites -> Clamp
	Repeat  = 1,
	Clamp   = 2,
	Mirror  = 3,
}

Texture :: struct {
	gpu:           ^sdl.GPUTexture,
	width, height: i32,
	format:        sdl.GPUTextureFormat, // readback needs the channel order
	filter:        Texture_Filter,
	wrap:          Texture_Wrap,
}

Mesh :: struct {
	vbuf, ibuf:  ^sdl.GPUBuffer,
	index_count: u32,
}

_Pipeline_Kind :: enum u8 {
	Tris,          // alpha-blended, depth test, NO depth write (sprites)
	Tris_Depth,    // opaque, depth test + write (meshes)
	Tris_Overlay,  // alpha-blended, no depth test (gizmo solids, e.g. arrow cones)
	Lines,         // depth-tested lines (selection outline)
	Lines_Depth,   // depth test + WRITE (editor grid — occludes and is occluded
	               // by meshes regardless of draw order; sprites still cover it)
	Lines_Overlay, // no depth test (gizmos)
}

// One pipeline per kind, per registered shader. All shaders share the Vertex
// format and the UBO layout (pass.odin _Uniform) — that contract is what lets
// pass_end switch shaders per draw without re-plumbing uniforms.
_Shader_Set :: [_Pipeline_Kind]^sdl.GPUGraphicsPipeline

DEFAULT_SHADER :: "unlit"

_DEPTH_FORMAT :: sdl.GPUTextureFormat.D32_FLOAT

_depth_format :: #force_inline proc() -> sdl.GPUTextureFormat {
	return _gfx.depth_format != .INVALID ? _gfx.depth_format : _DEPTH_FORMAT
}

_gfx: struct {
	device:           ^sdl.GPUDevice,
	swapchain_format: sdl.GPUTextureFormat,
	depth_format:     sdl.GPUTextureFormat,
	cmd:              ^sdl.GPUCommandBuffer, // valid between frame_begin/frame_end
	shader_sets:      map[string]_Shader_Set, // built-ins registered in init
	shader_samplers:  map[string]u32,         // fragment sampler counts keyed by shader name
	pipelines:        _Shader_Set, // = shader_sets[DEFAULT_SHADER] (batch fast path)
	skin_pipeline:    ^sdl.GPUComputePipeline,
	sampler_linear:   ^sdl.GPUSampler,
	sampler_nearest:  ^sdl.GPUSampler,
	sampler_repeat:   ^sdl.GPUSampler, // linear + REPEAT — mesh draws (glTF's default wrap)
	// 2x3 sampler table: [Linear/Nearest][0=Clamp, 1=Repeat, 2=Mirror] (`REV-08`)
	samplers:         [Texture_Filter][3]^sdl.GPUSampler,
	white_tex:        ^Texture,
	window_depth:     ^sdl.GPUTexture, // lazily sized to the swapchain
	window_depth_w:   u32,
	window_depth_h:   u32,
	// SDL 3.4.14's Metal backend answers QueryGPUFence with the fence's BUSY
	// state (3.4.16 answers signaled). Probed once at init, see _fence_probe.
	fence_query_inverted: bool,
}

// Window + GPU device + pipelines. show=false lets the caller apply saved
// window geometry before show_window().
init :: proc(title: cstring, width, height: i32, show := true) -> bool {
	if !_platform_init(title, width, height, show) do return false

	// On Windows, prefer the Vulkan backend explicitly so SPIR-V shaders are
	// guaranteed native ingestion rather than risking a D3D12 driver selection (`REV-01`).
	when ODIN_OS == .Windows {
		_gfx.device = sdl.CreateGPUDevice({.SPIRV, .MSL}, ODIN_DEBUG, "vulkan")
	}
	if _gfx.device == nil {
		_gfx.device = sdl.CreateGPUDevice({.SPIRV, .MSL}, ODIN_DEBUG, nil)
	}
	if _gfx.device == nil do return false
	if !sdl.ClaimWindowForGPUDevice(_gfx.device, _platform.window) do return false
	_gfx.swapchain_format = sdl.GetGPUSwapchainTextureFormat(_gfx.device, _platform.window)
	_ = sdl.SetGPUSwapchainParameters(_gfx.device, _platform.window, .SDR, .VSYNC)
	// Probe hardware depth format support (`REV-02`): D32_FLOAT -> D24_UNORM -> D16_UNORM
	_gfx.depth_format = _DEPTH_FORMAT
	for candidate in ([?]sdl.GPUTextureFormat{.D32_FLOAT, .D24_UNORM, .D16_UNORM}) {
		if sdl.GPUTextureSupportsFormat(_gfx.device, candidate, .D2, {.DEPTH_STENCIL_TARGET}) {
			_gfx.depth_format = candidate
			break
		}
	}
	// Three frames in flight (with fallback to 2): lets CPU work and secondary multi-viewport window
	// command buffers overlap smoothly without stalling on swapchain fences.
	if !sdl.SetGPUAllowedFramesInFlight(_gfx.device, 3) {
		if !sdl.SetGPUAllowedFramesInFlight(_gfx.device, 2) do return false
	}
	_fence_probe()

	addr_modes := [3]sdl.GPUSamplerAddressMode{.CLAMP_TO_EDGE, .REPEAT, .MIRRORED_REPEAT}
	for f in Texture_Filter {
		sdl_f: sdl.GPUFilter = f == .Nearest ? .NEAREST : .LINEAR
		sdl_m: sdl.GPUSamplerMipmapMode = f == .Nearest ? .NEAREST : .LINEAR
		for addr, a_idx in addr_modes {
			_gfx.samplers[f][a_idx] = sdl.CreateGPUSampler(_gfx.device, sdl.GPUSamplerCreateInfo{
				min_filter     = sdl_f,
				mag_filter     = sdl_f,
				mipmap_mode    = sdl_m,
				address_mode_u = addr,
				address_mode_v = addr,
				address_mode_w = addr,
				max_lod        = 1000.0,
			})
		}
	}
	_gfx.sampler_linear  = _gfx.samplers[.Linear][0]
	_gfx.sampler_repeat  = _gfx.samplers[.Linear][1]
	_gfx.sampler_nearest = _gfx.samplers[.Nearest][0]

	if !_create_pipelines() do return false
	if !_skinning_init() do return false
	if !_shadow_init() do return false

	white := [4]u8{255, 255, 255, 255}
	_gfx.white_tex = texture_create(white[:], 1, 1, mipmaps = false)
	return _gfx.white_tex != nil
}

shutdown :: proc() {
	if _gfx.device != nil {
		_ = sdl.WaitForGPUIdle(_gfx.device)
		_pass_shutdown()
		_debug_text_shutdown()
		_shadow_shutdown()
		_skinning_shutdown()
		if _gfx.white_tex != nil do texture_destroy(_gfx.white_tex)
		if _gfx.window_depth != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.window_depth)
		for name, set in _gfx.shader_sets {
			for p in set {
				if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
			}
			delete(name)
		}
		delete(_gfx.shader_sets)
		for name, _ in _gfx.shader_samplers {
			delete(name)
		}
		delete(_gfx.shader_samplers)
		for f in Texture_Filter {
			for s in _gfx.samplers[f] {
				if s != nil do sdl.ReleaseGPUSampler(_gfx.device, s)
			}
		}
		sdl.ReleaseWindowFromGPUDevice(_gfx.device, _platform.window)
		sdl.DestroyGPUDevice(_gfx.device)
	}
	_gfx = {}
	_platform_shutdown()
}

device :: proc() -> ^sdl.GPUDevice {
	return _gfx.device
}

swapchain_format :: proc() -> sdl.GPUTextureFormat {
	return _gfx.swapchain_format
}

// Frames begun since startup, bumped before anything else in a frame, so the
// first frame is 1 and a zero stamp never matches a real one. Per-frame work
// that several views would otherwise repeat — CPU skinning, collected once per
// view — stamps itself with this and skips when the stamp already matches.
frame_index: u64

frame_begin :: proc() -> bool {
	frame_index += 1
	_platform_frame_tick()
	_gfx.cmd = sdl.AcquireGPUCommandBuffer(_gfx.device)
	return _gfx.cmd != nil
}

frame_end :: proc() {
	if _gfx.cmd != nil {
		// A pending swapchain capture rides THIS buffer, so it needs the fence
		// this submit produces — the ordinary path takes the cheaper submit.
		if d := _swapchain_take_pending(); d != nil {
			d.fence = sdl.SubmitGPUCommandBufferAndAcquireFence(_gfx.cmd)
		} else {
			_ = sdl.SubmitGPUCommandBuffer(_gfx.cmd)
		}
		_gfx.cmd = nil
	}
	// The swapchain image belongs to this frame only — a capture must not reach
	// for it after submit.
	_swapchain_frame_clear()
}

command_buffer :: proc() -> ^sdl.GPUCommandBuffer {
	return _gfx.cmd
}

_create_pipelines :: proc() -> bool {
	_gfx.shader_sets = make(map[string]_Shader_Set)
	_gfx.shader_samplers = make(map[string]u32)
	if !shader_register(DEFAULT_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _WORLD_FRAG_SPV, _WORLD_FRAG_MSL) do return false
	if !shader_register("lit", _WORLD_VERT_SPV, _WORLD_VERT_MSL, _LIT_FRAG_SPV, _LIT_FRAG_MSL, frag_samplers = 8, frag_uniform_buffers = 1) do return false
	_gfx.pipelines = _gfx.shader_sets[DEFAULT_SHADER]
	return true
}

shader_exists :: proc(name: string) -> bool {
	return name in _gfx.shader_sets
}

// User shaders are fragment-only: the vertex stage is always the built-in
// world vertex shader (fixed Vertex format + _Uniform contract). Resource
// counts come from import-time reflection, not convention.
shader_register_fragment :: proc(name: string, frag_spv, frag_msl: []u8, num_samplers, num_uniform_buffers: u32) -> bool {
	return shader_register(name, _WORLD_VERT_SPV, _WORLD_VERT_MSL, frag_spv, frag_msl,
		frag_samplers = num_samplers, frag_uniform_buffers = num_uniform_buffers)
}

// Releases the shader's pipelines (SDL_GPU defers actual destruction past
// in-flight frames). Used by shader hot-reload; unknown names are a no-op.
shader_unregister :: proc(name: string) {
	set, ok := _gfx.shader_sets[name]
	if !ok do return
	for p in set {
		if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
	}
	key, _ := delete_key(&_gfx.shader_sets, name)
	delete(key)
	skey, _ := delete_key(&_gfx.shader_samplers, name)
	delete(skey)
}

// Builds the full pipeline set for a vertex+fragment shader pair and registers
// it under `name` (draw_mesh's shader parameter). The vertex stage must
// declare 1 UBO (_Uniform layout); fragment resource counts must match the
// shader's declarations (sampler2D at set=2, optional Light UBO at set=3).
// Re-registering a name is an error (false).
shader_register :: proc(name: string, vert_spv, vert_msl, frag_spv, frag_msl: []u8, frag_samplers: u32 = 1, frag_uniform_buffers: u32 = 0) -> bool {
	if name in _gfx.shader_sets do return false
	vert := _create_shader(.VERTEX, 0, 1, vert_spv, vert_msl)
	frag := _create_shader(.FRAGMENT, frag_samplers, frag_uniform_buffers, frag_spv, frag_msl)
	if vert == nil || frag == nil do return false
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
	alpha_blend := sdl.GPUColorTargetBlendState{
		src_color_blendfactor = .SRC_ALPHA,
		dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
		color_blend_op        = .ADD,
		src_alpha_blendfactor = .ONE,
		dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
		alpha_blend_op        = .ADD,
		enable_blend          = true,
	}
	color_target := sdl.GPUColorTargetDescription{
		format      = _gfx.swapchain_format,
		blend_state = alpha_blend,
	}

	info := sdl.GPUGraphicsPipelineCreateInfo{
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
			enable_depth_clip = true,
		},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets         = 1,
			depth_stencil_format      = _depth_format(),
			has_depth_stencil_target  = true,
		},
	}

	make_pipeline :: proc(info: ^sdl.GPUGraphicsPipelineCreateInfo, primitive: sdl.GPUPrimitiveType, depth_test, depth_write: bool) -> ^sdl.GPUGraphicsPipeline {
		info.primitive_type = primitive
		info.depth_stencil_state = {
			compare_op         = .LESS_OR_EQUAL,
			enable_depth_test  = depth_test,
			enable_depth_write = depth_write,
		}
		return sdl.CreateGPUGraphicsPipeline(_gfx.device, info^)
	}

	set: _Shader_Set
	set[.Tris]          = make_pipeline(&info, .TRIANGLELIST, true, false)
	set[.Tris_Depth]    = make_pipeline(&info, .TRIANGLELIST, true, true)
	set[.Tris_Overlay]  = make_pipeline(&info, .TRIANGLELIST, false, false)
	set[.Lines]         = make_pipeline(&info, .LINELIST, true, false)
	set[.Lines_Depth]   = make_pipeline(&info, .LINELIST, true, true)
	set[.Lines_Overlay] = make_pipeline(&info, .LINELIST, false, false)
	for p in set {
		if p == nil {
			for q in set {
				if q != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, q)
			}
			return false
		}
	}
	_gfx.shader_sets[strings.clone(name)] = set
	_gfx.shader_samplers[strings.clone(name)] = frag_samplers
	return true
}

// Uploads RGBA8 pixels into a new sampled texture. Uses its OWN short-lived
// command buffer so lazy loads mid-frame (between passes) stay legal.
texture_create :: proc(pixels: []u8, width, height: i32, mipmaps := true) -> ^Texture {
	assert(len(pixels) == int(width * height * 4))
	levels := u32(1)
	usage := sdl.GPUTextureUsageFlags{.SAMPLER}
	if mipmaps && width > 1 && height > 1 {
		levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1
		usage = {.SAMPLER, .COLOR_TARGET}
	}
	gpu_tex := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = .R8G8B8A8_UNORM,
		usage                = usage,
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = levels,
	})
	if gpu_tex == nil do return nil

	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(len(pixels)),
	})
	if transfer == nil {
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(pixels), len(pixels))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(copy_pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = gpu_tex, w = u32(width), h = u32(height), d = 1},
		false)
	sdl.EndGPUCopyPass(copy_pass)
	if levels > 1 {
		sdl.GenerateMipmapsForGPUTexture(cmd, gpu_tex)
	}
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	tex := new(Texture, runtime.default_allocator())
	tex.gpu = gpu_tex
	tex.width = width
	tex.height = height
	tex.format = .R8G8B8A8_UNORM
	return tex
}

// Overwrites a region of a sampled RGBA8 texture (a dynamic font atlas adding
// a glyph). Own command buffer, like texture_create.
texture_upload_region :: proc(tex: ^Texture, x, y, width, height: i32, pixels: []u8) -> bool {
	if tex == nil || tex.gpu == nil do return false
	assert(len(pixels) == int(width * height * 4))
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(len(pixels))})
	if transfer == nil do return false
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(pixels), len(pixels))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil do return false
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(copy_pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = tex.gpu, x = u32(x), y = u32(y), w = u32(width), h = u32(height), d = 1},
		false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	return true
}

// An in-flight GPU→CPU pixel readback. The copy runs on its own command
// buffer, queued after everything already submitted — poll readiness each
// frame instead of blocking on the fence.
Texture_Download :: struct {
	transfer:      ^sdl.GPUTransferBuffer,
	fence:         ^sdl.GPUFence,
	width, height: i32,
	bgra:          bool,
	// Intermediate texture a swapchain capture copies through, freed with the
	// download. nil for the ordinary render-target path, which reads the RT
	// texture directly.
	scratch_texture: ^sdl.GPUTexture,
}

// Starts an async readback of the texture's pixels. The pass that produced the
// contents must already be SUBMITTED (frame_end) — queue order then guarantees
// the copy sees the finished pixels. Follow with texture_download_ready polls,
// then texture_download_take (or _cancel). nil on failure.
texture_download_begin :: proc(tex: ^Texture) -> ^Texture_Download {
	byte_count := u32(tex.width * tex.height * 4)
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .DOWNLOAD, size = byte_count})
	if transfer == nil do return nil
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil {
		sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return nil
	}
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(copy_pass,
		{texture = tex.gpu, w = u32(tex.width), h = u32(tex.height), d = 1},
		{transfer_buffer = transfer, pixels_per_row = u32(tex.width), rows_per_layer = u32(tex.height)})
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return nil
	}
	d := new(Texture_Download, runtime.default_allocator())
	d.transfer = transfer
	d.fence = fence
	d.width = tex.width
	d.height = tex.height
	d.bgra = tex.format == .B8G8R8A8_UNORM || tex.format == .B8G8R8A8_UNORM_SRGB
	return d
}

texture_download_ready :: proc(d: ^Texture_Download) -> bool {
	// A swapchain capture has no fence until the frame it rides is submitted.
	if d.fence == nil do return false
	return _fence_signaled(d.fence)
}

// A fence that has been waited on is signaled by definition, so a false
// answer from QueryGPUFence means this SDL build reports the inverse.
@(private = "file")
_fence_probe :: proc() {
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil do return
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil do return
	defer sdl.ReleaseGPUFence(_gfx.device, fence)
	fences := [1]^sdl.GPUFence{fence}
	_ = sdl.WaitForGPUFences(_gfx.device, true, raw_data(fences[:]), 1)
	_gfx.fence_query_inverted = !sdl.QueryGPUFence(_gfx.device, fence)
}

@(private = "file")
_fence_signaled :: proc(fence: ^sdl.GPUFence) -> bool {
	return sdl.QueryGPUFence(_gfx.device, fence) != _gfx.fence_query_inverted
}

// The pixels as RGBA8 rows top-down, allocated with `allocator`. Frees the
// download — call once, after texture_download_ready. nil slice on map failure.
texture_download_take :: proc(d: ^Texture_Download, allocator := context.allocator) -> []u8 {
	defer texture_download_cancel(d)
	// QueryGPUFence only reports that the fence signalled; block until the
	// buffer's contents are actually visible to the host before mapping.
	// Without this the map raced the GPU's writes and the tail of the image
	// came back as untouched memory (alpha 0), a different row count each time.
	if d.fence != nil {
		fences := [1]^sdl.GPUFence{d.fence}
		_ = sdl.WaitForGPUFences(_gfx.device, true, raw_data(fences[:]), 1)
	}
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, d.transfer, false)
	if mapped == nil do return nil
	pixels := make([]u8, int(d.width * d.height * 4), allocator)
	runtime.mem_copy_non_overlapping(raw_data(pixels), mapped, len(pixels))
	sdl.UnmapGPUTransferBuffer(_gfx.device, d.transfer)
	if d.bgra {
		for i := 0; i < len(pixels); i += 4 {
			pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
		}
	}
	return pixels
}

// Frees an in-flight download without taking the pixels (SDL defers the
// actual GPU-side destruction past any pending work).
texture_download_cancel :: proc(d: ^Texture_Download) {
	if d.fence != nil do sdl.ReleaseGPUFence(_gfx.device, d.fence)
	sdl.ReleaseGPUTransferBuffer(_gfx.device, d.transfer)
	if d.scratch_texture != nil do sdl.ReleaseGPUTexture(_gfx.device, d.scratch_texture)
	free(d, runtime.default_allocator())
}

texture_destroy :: proc(tex: ^Texture) {
	if tex == nil do return
	if tex.gpu != nil do sdl.ReleaseGPUTexture(_gfx.device, tex.gpu)
	free(tex, runtime.default_allocator())
}

// For imgui: since imgui 1.92.2 the SDLGPU3 backend's ImTextureID is the raw
// SDL_GPUTexture pointer (NOT a sampler-binding struct — passing one crashes,
// see the backend's 2025-08-08 breaking change).
texture_imgui_id :: proc(tex: ^Texture) -> rawptr {
	return tex.gpu
}

mesh_create :: proc(vertices: []Vertex, indices: []u32) -> Mesh {
	vsize := u32(len(vertices) * size_of(Vertex))
	isize := u32(len(indices) * size_of(u32))
	vbuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX}, size = vsize})
	ibuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.INDEX}, size = isize})
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = vsize + isize})
	if vbuf == nil || ibuf == nil || transfer == nil {
		if vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, vbuf)
		if ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, ibuf)
		if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return {}
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(vertices), int(vsize))
	runtime.mem_copy_non_overlapping(rawptr(uintptr(mapped) + uintptr(vsize)), raw_data(indices), int(isize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer}, {buffer = vbuf, size = vsize}, false)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer, offset = vsize}, {buffer = ibuf, size = isize}, false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	return Mesh{vbuf = vbuf, ibuf = ibuf, index_count = u32(len(indices))}
}

// A mesh whose VERTICES are rewritten every frame and whose indices never
// change — what CPU skinning needs: the index buffer is the bind mesh's, the
// vertex buffer is the posed result.
//
// The transfer buffer is kept rather than recreated per update, and both it and
// the vertex buffer cycle on write so the GPU is never asked to read a buffer
// that is being overwritten.
Dynamic_Mesh :: struct {
	using mesh:    Mesh,
	transfer:      ^sdl.GPUTransferBuffer,
	vertex_capacity: u32,
}

dynamic_mesh_create :: proc(vertex_capacity: int, indices: []u32) -> Dynamic_Mesh {
	vsize := u32(vertex_capacity * size_of(Vertex))
	isize := u32(len(indices) * size_of(u32))
	if vsize == 0 || isize == 0 do return {}

	vbuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX}, size = vsize})
	ibuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.INDEX}, size = isize})
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = max(vsize, isize)})
	if vbuf == nil || ibuf == nil || transfer == nil {
		if vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, vbuf)
		if ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, ibuf)
		if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return {}
	}

	// Indices go up once.
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(indices), int(isize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer}, {buffer = ibuf, size = isize}, false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	return Dynamic_Mesh{
		mesh = Mesh{vbuf = vbuf, ibuf = ibuf, index_count = u32(len(indices))},
		transfer = transfer,
		vertex_capacity = u32(vertex_capacity),
	}
}

// Replace the vertex data. Silently does nothing past the capacity the mesh was
// created with, which is the bind mesh's vertex count and never changes.
dynamic_mesh_update :: proc(m: ^Dynamic_Mesh, vertices: []Vertex) {
	if m.vbuf == nil || m.transfer == nil do return
	n := min(u32(len(vertices)), m.vertex_capacity)
	if n == 0 do return
	vsize := n * size_of(Vertex)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, m.transfer, true) // cycle
	runtime.mem_copy_non_overlapping(mapped, raw_data(vertices), int(vsize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, m.transfer)

	cmd := _gfx.cmd
	own_cmd := false
	if cmd == nil {
		cmd = sdl.AcquireGPUCommandBuffer(_gfx.device)
		own_cmd = true
	}
	if cmd == nil do return

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	if copy_pass != nil {
		sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = m.transfer}, {buffer = m.vbuf, size = vsize}, true)
		sdl.EndGPUCopyPass(copy_pass)
	}
	if own_cmd {
		_ = sdl.SubmitGPUCommandBuffer(cmd)
	}
}

dynamic_mesh_destroy :: proc(m: ^Dynamic_Mesh) {
	if m.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, m.transfer)
	mesh_destroy(&m.mesh)
	m^ = {}
}

mesh_destroy :: proc(mesh: ^Mesh) {
	if mesh.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, mesh.vbuf)
	if mesh.ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, mesh.ibuf)
	mesh^ = {}
}

// Builds a GPU line index buffer for wireframe rendering of triangle indices.
// Deduplicates shared triangle edges so every edge is rendered exactly once with uniform alpha.
dynamic_mesh_create_wire_indices :: proc(triangle_indices: []u32, vbuf: ^sdl.GPUBuffer) -> Mesh {
	if len(triangle_indices) < 3 || vbuf == nil do return {}

	seen_edges := make(map[u64]bool, len(triangle_indices), context.temp_allocator)
	lines := make([dynamic]u32, 0, len(triangle_indices) * 2, context.temp_allocator)

	add_edge :: proc(seen: ^map[u64]bool, lines: ^[dynamic]u32, a, b: u32) {
		mi := min(a, b)
		ma := max(a, b)
		key := (u64(mi) << 32) | u64(ma)
		if key in seen do return
		seen[key] = true
		append(lines, a, b)
	}

	for i := 0; i + 2 < len(triangle_indices); i += 3 {
		i0, i1, i2 := triangle_indices[i], triangle_indices[i + 1], triangle_indices[i + 2]
		add_edge(&seen_edges, &lines, i0, i1)
		add_edge(&seen_edges, &lines, i1, i2)
		add_edge(&seen_edges, &lines, i2, i0)
	}

	if len(lines) == 0 do return {}
	isize := u32(len(lines) * size_of(u32))

	ibuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.INDEX}, size = isize})
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = isize})
	if ibuf == nil || transfer == nil {
		if ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, ibuf)
		if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return {}
	}

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(lines), int(isize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer}, {buffer = ibuf, size = isize}, false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	return Mesh{
		vbuf        = vbuf,
		ibuf        = ibuf,
		index_count = u32(len(lines)),
	}
}

dynamic_mesh_destroy_wire_indices :: proc(wire_mesh: ^Mesh) {
	if wire_mesh == nil do return
	if wire_mesh.ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, wire_mesh.ibuf)
	wire_mesh.ibuf = nil
	wire_mesh.vbuf = nil
	wire_mesh.index_count = 0
}

