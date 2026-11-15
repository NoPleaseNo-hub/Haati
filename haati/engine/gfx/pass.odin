// Render passes and the CPU draw batch. pass_begin_* only records the
// target; pass_end encodes one copy pass (vertex upload) followed by one
// render pass replaying the recorded draws — copy passes can't nest inside
// render passes, and this keeps mid-pass texture_create legal.
package gfx

import "base:runtime"
import "core:math"
import "core:slice"
import sdl "vendor:sdl3"

Render_Target :: struct {
	color, depth:  ^sdl.GPUTexture,
	hdr_color:     ^sdl.GPUTexture,
	bloom_mips:    [BLOOM_MIP_COUNT]^sdl.GPUTexture,
	bloom_mip_w:   [BLOOM_MIP_COUNT]u32,
	bloom_mip_h:   [BLOOM_MIP_COUNT]u32,
	width, height: i32,
}

MAX_RT_DIM :: i32(8192)

_Draw :: struct {
	kind:         _Pipeline_Kind,
	is_mesh:      bool,
	texture:      ^Texture, // nil = white
	vp_index:     i32,
	first_vertex: u32, // batch draws
	vertex_count: u32,
	mesh:         Mesh, // mesh draws
	mesh_first:   u32, // index range within the mesh (submeshes)
	mesh_count:   u32,
	model:        matrix[4, 4]f32,
	color:        [4]f32,
	shader:       string, // "" = DEFAULT_SHADER (meshes and batched quads)
	material:     []u8,   // fragment UBO slot 1 bytes (shader property block); nil = none
	extra_tex:     []^Texture, // fragment sampler bindings 1..N (multi-texture shaders); nil entries = white
	no_shadow:     bool,   // when true, skip drawing this mesh into shadow maps
	bounds_center: [3]f32, // conservative world-space bounding sphere center (for shadow culling)
	bounds_radius: f32,    // >0 enables shadow frustum/range culling
}

// Fragment sampler slots a single draw can bind (mirrors the importer's
// SHADER_MAX_SAMPLERS — pipelines are created with at most this many).
MAX_FRAGMENT_SAMPLERS :: 8
SHADOW_SAMPLER_SLOT :: 7

// Must match the GLSL UBO (std140: mat4, mat4, vec4). Batch draws push
// model = identity (vertices are pre-transformed to world space).
_Uniform :: struct {
	view_proj: matrix[4, 4]f32,
	model:     matrix[4, 4]f32,
	tint:      [4]f32,
}

// Up to MAX_LIGHTS lights reach the shader in one UBO. Matches the Light
// component's pool max, so every enabled light in a scene fits.
MAX_LIGHTS :: 64

Light_Kind :: enum u32 {
	Directional,
	Point,
	Spot,
}

// One light as the renderer takes it (set_lights). Angles arrive as cosines of
// the HALF angle, so the shader compares dot products directly.
Light :: struct {
	kind:            Light_Kind,
	position:        [3]f32, // point/spot
	direction:       [3]f32, // the way the light travels
	color:           [3]f32,
	intensity:       f32,
	range:           f32,    // point/spot falloff end
	inner_cos:       f32,    // spot: full brightness inside
	outer_cos:       f32,    // spot: zero outside
	cast_shadows:    bool,
	shadow_strength: f32,
	shadow_bias:     f32,
}

// Must match the lit shader's GpuLight (fragment set=3 binding=0), std140:
// four vec4 per light.
_Gpu_Light :: struct {
	pos_type:    [4]f32, // xyz = position, w = kind (0 dir, 1 point, 2 spot)
	dir_range:   [4]f32, // xyz = normalized travel direction, w = range
	color_outer: [4]f32, // rgb premultiplied by intensity, w = cos outer half-angle
	params:      [4]f32, // x = cos inner half-angle, yzw reserved
}

// Must match the lit shader's LightUBO. cam_pos comes from the draw's view
// (set_view_proj), not set_lights — it's filled in at push time per view
// switch.
_Light_Uniform :: struct {
	ambient_count:     [4]f32, // x = ambient floor, y = light count
	cam_pos:           [4]f32, // xyz = camera world position (specular shaders), w unused
	lights:            [MAX_LIGHTS]_Gpu_Light,
	shadow_mats:       [16]matrix[4, 4]f32, // 0..2 dir CSM, 3 spot, 4..9 point0, 10..15 point1
	cascade_splits:    [4]f32,              // xyz = cascade max distances, w = spot caster light index (<0 if none)
	shadow_atlas_info: [4]f32,              // x = 1.0/atlas_dim, y = dir strength, z = spot strength, w = enabled (>0.5)
	point_shadow_info: [4]f32,              // x = point0 light idx (<0 none), y = point1 light idx (<0 none), z = p0 en, w = p1 en
}

// Matches the previously baked-in lit shader constants, so scenes without a
// Light component keep looking the same: one white directional, 0.35 ambient.
_LIGHT_DEFAULT :: _Light_Uniform{
	ambient_count = {0.35, 1, 0, 0},
	lights = {
		0 = {
			pos_type    = {0, 0, 0, 0},
			dir_range   = {-0.42107597, -0.84215194, -0.33686078, 0}, // normalize({-0.5,-1,-0.4})
			color_outer = {1, 1, 1, 0},
			params      = {0, 0, 0, 0},
		},
	},
}

// One view entry per set_view_proj call: the matrix plus the camera world
// position fragment shaders see as cam_pos.
_View :: struct {
	vp:      matrix[4, 4]f32,
	cam_pos: [3]f32,
}

_pass: struct {
	active:       bool,
	target_rt:    ^Render_Target,
	target_color: ^sdl.GPUTexture,
	target_depth: ^sdl.GPUTexture, // nil = depth-less pass (imgui-only)
	resolve_dst:  ^sdl.GPUTexture,
	resolve_w:    u32,
	resolve_h:    u32,
	clear:        Maybe([4]f32),
	light:        Maybe(_Light_Uniform), // nil = _LIGHT_DEFAULT; reset each pass_end
	post_fx:      Post_FX_Config,
	vps:          [dynamic]_View,
	vtx:          [dynamic]Vertex,
	draws:        [dynamic]_Draw,
	// GPU-side batch storage, grown on demand, reused across passes/frames
	vbuf:          ^sdl.GPUBuffer,
	transfer:      ^sdl.GPUTransferBuffer,
	vbuf_capacity: u32, // in vertices
} = {
	post_fx = POST_FX_DEFAULT,
}

_pass_shutdown :: proc() {
	if _pass.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, _pass.vbuf)
	if _pass.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, _pass.transfer)
	delete(_pass.vps)
	delete(_pass.vtx)
	delete(_pass.draws)
	_pass = {post_fx = POST_FX_DEFAULT}
}

@(private = "file")
_rt_release_textures :: proc(rt: ^Render_Target) {
	if rt == nil || _gfx.device == nil do return
	if rt.color != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.color)
	if rt.hdr_color != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.hdr_color)
	if rt.depth != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.depth)
	for i in 0 ..< BLOOM_MIP_COUNT {
		if rt.bloom_mips[i] != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.bloom_mips[i])
	}
	rt.color = nil
	rt.hdr_color = nil
	rt.depth = nil
	rt.bloom_mips = {}
	rt.bloom_mip_w = {}
	rt.bloom_mip_h = {}
}

@(private = "file")
_rt_populate :: proc(rt: ^Render_Target, width, height: i32, with_color: bool) -> bool {
	if _gfx.device == nil || rt == nil do return false
	w := clamp(width, 1, MAX_RT_DIM)
	h := clamp(height, 1, MAX_RT_DIM)

	color: ^sdl.GPUTexture
	if with_color {
		color = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
			type                 = .D2,
			format               = _gfx.swapchain_format,
			usage                = {.COLOR_TARGET, .SAMPLER},
			width                = u32(w),
			height               = u32(h),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})
	}
	hdr_color := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _gfx.hdr_format,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(w),
		height               = u32(h),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	depth := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _depth_format(),
		usage                = {.DEPTH_STENCIL_TARGET},
		width                = u32(w),
		height               = u32(h),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if hdr_color == nil || depth == nil || (with_color && color == nil) {
		if color != nil do sdl.ReleaseGPUTexture(_gfx.device, color)
		if hdr_color != nil do sdl.ReleaseGPUTexture(_gfx.device, hdr_color)
		if depth != nil do sdl.ReleaseGPUTexture(_gfx.device, depth)
		return false
	}

	rt.width = w
	rt.height = h
	rt.color = color
	rt.hdr_color = hdr_color
	rt.depth = depth

	mw := u32(w)
	mh := u32(h)
	for i in 0 ..< BLOOM_MIP_COUNT {
		mw = max(mw / 2, 1)
		mh = max(mh / 2, 1)
		mip := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
			type                 = .D2,
			format               = _gfx.hdr_format,
			usage                = {.COLOR_TARGET, .SAMPLER},
			width                = mw,
			height               = mh,
			layer_count_or_depth = 1,
			num_levels           = 1,
		})
		if mip == nil {
			_rt_release_textures(rt)
			return false
		}
		rt.bloom_mips[i] = mip
		rt.bloom_mip_w[i] = mw
		rt.bloom_mip_h[i] = mh
	}
	return true
}

rt_create :: proc(width, height: i32) -> ^Render_Target {
	if _gfx.device == nil do return nil
	rt := new(Render_Target, runtime.default_allocator())
	if !_rt_populate(rt, width, height, true) {
		free(rt, runtime.default_allocator())
		return nil
	}
	return rt
}

// No-op when the size is unchanged. Callers must re-fetch rt_imgui_id after
// a resize (the color texture is recreated) — fetching it every frame is the
// normal pattern.
rt_resize :: proc(rt: ^Render_Target, width, height: i32) {
	if rt == nil do return
	w := clamp(width, 1, MAX_RT_DIM)
	h := clamp(height, 1, MAX_RT_DIM)
	need_color := rt.color != nil || rt.hdr_color == nil
	if rt.width == w && rt.height == h && (!need_color || rt.color != nil) && rt.hdr_color != nil && rt.depth != nil do return
	tmp: Render_Target
	if !_rt_populate(&tmp, w, h, need_color) do return
	_rt_release_textures(rt)
	rt^ = tmp
}

rt_destroy :: proc(rt: ^Render_Target) {
	if rt == nil do return
	_rt_release_textures(rt)
	rt^ = {}
	free(rt, runtime.default_allocator())
}

@(private = "file")
_window_hdr_rt_ensure :: proc(width, height: i32) -> ^Render_Target {
	if _gfx.device == nil do return nil
	w := clamp(width, 1, MAX_RT_DIM)
	h := clamp(height, 1, MAX_RT_DIM)
	if _gfx.window_hdr_rt == nil {
		rt := new(Render_Target, runtime.default_allocator())
		if !_rt_populate(rt, w, h, false) {
			free(rt, runtime.default_allocator())
			return nil
		}
		_gfx.window_hdr_rt = rt
		return rt
	}
	rt := _gfx.window_hdr_rt
	if rt.width == w && rt.height == h && rt.hdr_color != nil && rt.depth != nil {
		return rt
	}
	tmp: Render_Target
	if !_rt_populate(&tmp, w, h, false) do return nil
	_rt_release_textures(rt)
	rt^ = tmp
	return rt
}

// imgui 1.92.2+ SDLGPU3 convention: ImTextureID = raw ^sdl.GPUTexture.
rt_imgui_id :: proc(rt: ^Render_Target) -> rawptr {
	if rt == nil do return nil
	return rt.color
}

// Copies the RT's color into a new standalone sampled texture the caller owns
// (texture_destroy frees it). The blit records on the FRAME command buffer, so
// call it between passes, after the pass that filled the RT — ordering within
// the frame makes the copy valid for any later sampling, imgui included.
rt_snapshot :: proc(rt: ^Render_Target) -> ^Texture {
	assert(!_pass.active, "rt_snapshot must run between passes")
	if _gfx.cmd == nil || _gfx.device == nil || rt == nil || rt.color == nil || rt.width < 1 || rt.height < 1 do return nil
	gpu_tex := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _gfx.swapchain_format,
		usage                = {.SAMPLER, .COLOR_TARGET},
		width                = u32(rt.width),
		height               = u32(rt.height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if gpu_tex == nil do return nil
	sdl.BlitGPUTexture(_gfx.cmd, sdl.GPUBlitInfo{
		source      = {texture = rt.color, w = u32(rt.width), h = u32(rt.height)},
		destination = {texture = gpu_tex, w = u32(rt.width), h = u32(rt.height)},
		load_op     = .DONT_CARE,
		filter      = .LINEAR,
	})
	tex := new(Texture, runtime.default_allocator())
	tex.gpu = gpu_tex
	tex.width = rt.width
	tex.height = rt.height
	tex.format = _gfx.swapchain_format
	return tex
}

// Async readback of the RT's color contents (texture_download_* protocol).
// The contents must come from an already SUBMITTED frame — calling this at
// the top of a frame reads what the previous frame drew.
rt_download_begin :: proc(rt: ^Render_Target) -> ^Texture_Download {
	if rt == nil || rt.color == nil || rt.width < 1 || rt.height < 1 do return nil
	tex := Texture{gpu = rt.color, width = rt.width, height = rt.height, format = _gfx.swapchain_format}
	return texture_download_begin(&tex)
}

// The swapchain image this frame is drawing into, and its size. Valid between
// pass_begin_swapchain and frame_end. nil outside that window, or on a frame the
// acquire failed (minimized window).
//
// This is what makes an on-demand full-window capture possible: the swapchain
// holds EVERYTHING, imgui panels included, so a copy taken after the UI pass is
// a picture of the whole editor. See swapchain_capture.
@(private = "file")
_swapchain_this_frame: struct {
	tex:  ^sdl.GPUTexture,
	w, h: u32,
}

// Starts a readback of the current swapchain image — the finished frame,
// including every imgui panel.
//
// ONLY runs when someone asks for a screenshot: the cost is one full-screen copy
// plus a download on that single frame, and nothing at all otherwise. That is
// why the frame still renders straight to the swapchain, rather than through an
// offscreen target that would need blitting every frame forever just to keep a
// capture possible.
//
// Both the copy AND the download are encoded into the FRAME's command buffer,
// which is what makes this correct. texture_download_begin would otherwise
// acquire its own buffer and submit it immediately — running the download ahead
// of a copy that is still sitting unsubmitted in the frame buffer, and reading
// an untouched texture. (That produced a solid magenta image: uninitialized
// texture memory, not a broken capture path.)
//
// Call while the frame's command buffer is open and after the UI pass has ended.
// Returns nil when there is no swapchain image this frame.
swapchain_capture_begin :: proc() -> ^Texture_Download {
	if _gfx.device == nil || _swapchain_this_frame.tex == nil do return nil
	if _gfx.cmd == nil do return nil
	w := _swapchain_this_frame.w
	h := _swapchain_this_frame.h
	if w < 2 || h < 2 do return nil

	// A swapchain image cannot be downloaded from directly — it belongs to the
	// presentation engine. Copy into a texture that can be, then read that.
	dst := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _gfx.swapchain_format,
		usage                = {.SAMPLER},
		width                = w,
		height               = h,
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if dst == nil do return nil

	byte_count := w * h * 4
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .DOWNLOAD, size = byte_count})
	if transfer == nil {
		sdl.ReleaseGPUTexture(_gfx.device, dst)
		return nil
	}

	// One copy pass on the frame buffer: swapchain -> dst -> transfer buffer.
	copy_pass := sdl.BeginGPUCopyPass(_gfx.cmd)
	if copy_pass == nil {
		sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		sdl.ReleaseGPUTexture(_gfx.device, dst)
		return nil
	}
	sdl.CopyGPUTextureToTexture(copy_pass,
		sdl.GPUTextureLocation{texture = _swapchain_this_frame.tex},
		sdl.GPUTextureLocation{texture = dst}, w, h, 1, false)
	sdl.DownloadFromGPUTexture(copy_pass,
		{texture = dst, w = w, h = h, d = 1},
		{transfer_buffer = transfer, pixels_per_row = w, rows_per_layer = h})
	sdl.EndGPUCopyPass(copy_pass)

	// The frame's own submit carries this, so the fence comes from frame_end.
	d := new(Texture_Download, runtime.default_allocator())
	d.transfer = transfer
	d.fence = nil // set by frame_end
	d.width = i32(w)
	d.height = i32(h)
	d.bgra = _gfx.swapchain_format == .B8G8R8A8_UNORM || _gfx.swapchain_format == .B8G8R8A8_UNORM_SRGB
	d.scratch_texture = dst
	_swapchain_pending_download = d
	return d
}

// A capture whose copy rides this frame's command buffer, waiting for the
// submit in frame_end to give it a fence.
@(private = "file")
_swapchain_pending_download: ^Texture_Download

pass_begin_target :: proc(rt: ^Render_Target, clear: Maybe([4]f32)) {
	assert(!_pass.active, "gfx pass already active")
	_pass.active = true
	if rt != nil {
		_pass.target_rt = rt
		_pass.target_color = rt.hdr_color != nil ? rt.hdr_color : rt.color
		_pass.target_depth = rt.depth
		_pass.resolve_dst = rt.hdr_color != nil ? rt.color : nil
		_pass.resolve_w = u32(max(rt.width, 0))
		_pass.resolve_h = u32(max(rt.height, 0))
	} else {
		_pass.target_rt = nil
		_pass.target_color = nil
		_pass.target_depth = nil
		_pass.resolve_dst = nil
		_pass.resolve_w = 0
		_pass.resolve_h = 0
	}
	_pass.clear = clear
}

// When `true` (set during active multi-viewport window drags), `pass_begin_swapchain`
// never block-stalls on `WaitAndAcquireGPUSwapchainTexture` if the main swapchain image
// is busy; this keeps dragged secondary OS windows moving at full 120-240 Hz without VSYNC serialization spikes!
skip_swapchain_wait_on_drag := false

// When `true` (any secondary OS viewport window exists), `pass_begin_swapchain`
// yields cleanly if the main swapchain has no free image instead of blocking on
// `WaitAndAcquireGPUSwapchainTexture`, preventing a maximized or covering secondary
// window from freezing the event loop on an occluded FIFO swapchain.
skip_swapchain_wait_secondary := false

// When `true` (a secondary OS viewport completely covers the main window),
// skip acquiring the main swapchain altogether this frame.
skip_main_swapchain := false

// True on frames where `WaitAndAcquireGPUSwapchainTexture` already waited on VSYNC.
swapchain_waited_this_frame := false

// Acquires the swapchain image; false when the window is minimized (skip
// drawing this frame). The window depth buffer is lazily (re)sized.
// depth=false makes a depth-less pass — REQUIRED when only external
// pipelines without a depth attachment draw in it (the editor's imgui pass);
// our own gfx pipelines must NOT draw in such a pass (they declare D32).
pass_begin_swapchain :: proc(clear: Maybe([4]f32), depth := true) -> bool {
	assert(!_pass.active, "gfx pass already active")
	swapchain_waited_this_frame = false
	if _gfx.cmd == nil || _gfx.device == nil || _platform.window == nil do return false
	swap_tex: ^sdl.GPUTexture
	w, h: u32

	flags := sdl.GetWindowFlags(_platform.window)
	if skip_main_swapchain || .MINIMIZED in flags || .HIDDEN in flags || .OCCLUDED in flags {
		return false
	}

	// Try acquiring swapchain texture without blocking indefinitely.
	// If unacquired (e.g. display standby, lock screen, or background occlusion),
	// only block-wait if the app currently has user focus and no secondary
	// OS windows/drags are active; otherwise yield so secondary viewports
	// and the frame pacer keep pumping smoothly.
	if !sdl.AcquireGPUSwapchainTexture(_gfx.cmd, _platform.window, &swap_tex, &w, &h) {
		return false
	}
	if swap_tex == nil {
		app_unfocused := sdl.GetKeyboardFocus() == nil && sdl.GetMouseFocus() == nil
		if skip_swapchain_wait_on_drag || skip_swapchain_wait_secondary || app_unfocused {
			return false
		}
		swapchain_waited_this_frame = true
		if !sdl.WaitAndAcquireGPUSwapchainTexture(_gfx.cmd, _platform.window, &swap_tex, &w, &h) {
			return false
		}
	}
	if swap_tex == nil || w == 0 || h == 0 do return false

	// Remembered for an on-demand capture later this frame (swapchain_capture).
	_swapchain_this_frame = {tex = swap_tex, w = w, h = h}

	if !depth {
		_pass.active = true
		_pass.target_rt = nil
		_pass.target_color = swap_tex
		_pass.target_depth = nil
		_pass.resolve_dst = nil
		_pass.resolve_w = 0
		_pass.resolve_h = 0
		_pass.clear = clear
		return true
	}

	hdr_rt := _window_hdr_rt_ensure(i32(w), i32(h))
	if hdr_rt == nil do return false

	_pass.active = true
	_pass.target_rt = hdr_rt
	_pass.target_color = hdr_rt.hdr_color
	_pass.target_depth = hdr_rt.depth
	_pass.resolve_dst = swap_tex
	_pass.resolve_w = w
	_pass.resolve_h = h
	_pass.clear = clear
	return true
}

// Directional light for the CURRENT pass's lit-shader draws (one light —
// per-draw light lists are a later problem). Each direction is the way the
// light travels (sun → scene); zero-length falls back to straight down. Not
// calling this keeps the default (one white directional, 0.35 ambient).
set_lights :: proc(ls: []Light, ambient: f32) {
	u := _Light_Uniform{}
	n := min(len(ls), MAX_LIGHTS)
	u.ambient_count = {clamp(ambient, 0, 1), f32(n), 0, 0}
	for i in 0 ..< n {
		l := ls[i]
		d := l.direction
		len_sq := d.x * d.x + d.y * d.y + d.z * d.z
		if len_sq < 1e-12 {
			d = {0, -1, 0}
		} else {
			d /= math.sqrt(len_sq)
		}
		shadow_flag := f32(l.cast_shadows ? -2.0 : -1.0)
		strength := l.cast_shadows ? clamp(l.shadow_strength, 0.0, 1.0) : 0.0
		bias := l.shadow_bias > 0 ? l.shadow_bias : 0.0015
		u.lights[i] = _Gpu_Light{
			pos_type    = {l.position.x, l.position.y, l.position.z, f32(l.kind)},
			dir_range   = {d.x, d.y, d.z, max(l.range, 0)},
			color_outer = {l.color.r * l.intensity, l.color.g * l.intensity, l.color.b * l.intensity, l.outer_cos},
			params      = {l.inner_cos, shadow_flag, strength, bias},
		}
	}
	_pass.light = u
}

// Back to the built-in default (one white directional, 0.35 ambient) — for
// callers that set temporary lights (the inspector's preview headlight) and
// must not leak them into later passes of lightless scenes.
set_lights_default :: proc() {
	_pass.light = _LIGHT_DEFAULT
}

// May change mid-pass (multi-camera stacking, screen-space overlays).
// cam_pos is the camera's world position, exposed to fragment shaders for
// specular terms — screen-space/ortho callers can leave the zero default.
set_view_proj :: proc(vp: matrix[4, 4]f32, cam_pos := [3]f32{0, 0, 0}) {
	v := _View{vp = vp, cam_pos = cam_pos}
	if len(_pass.vps) > 0 && _pass.vps[len(_pass.vps)-1] == v do return
	append(&_pass.vps, v)
}

_MAT4_IDENTITY :: matrix[4, 4]f32{
	1, 0, 0, 0,
	0, 1, 0, 0,
	0, 0, 1, 0,
	0, 0, 0, 1,
}

_current_vp :: proc() -> i32 {
	if len(_pass.vps) == 0 {
		append(&_pass.vps, _View{vp = _MAT4_IDENTITY})
	}
	return i32(len(_pass.vps) - 1)
}

// corners in draw order: bottom-left, bottom-right, top-right, top-left
// (two CCW triangles). tex=nil draws untextured white. shader/material work
// like draw_mesh's (sprite materials); normal is the quad's facing, consumed
// by lighting shaders. Same-state consecutive quads merge into one draw —
// distinct material slices don't merge (compared by pointer). depth_test=false
// draws over everything (gizmo icons).
draw_quad :: proc(corners: [4][3]f32, uvs: [4][2]f32, color: [4]f32, tex: ^Texture, shader := "", material: []u8 = nil, normal := [3]f32{0, 0, 1}, extra_tex: []^Texture = nil, depth_test := true) {
	c := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := normal
	append(&_pass.vtx,
		Vertex{corners[0], n, uvs[0], c},
		Vertex{corners[1], n, uvs[1], c},
		Vertex{corners[2], n, uvs[2], c},
		Vertex{corners[0], n, uvs[0], c},
		Vertex{corners[2], n, uvs[2], c},
		Vertex{corners[3], n, uvs[3], c},
	)
	_batch_append(.Tris if depth_test else .Tris_Overlay, tex, first, 6, shader, material, extra_tex)
}

// Untextured filled triangle (white 1x1 texture bound at draw). Winding is
// irrelevant — the pipelines don't cull.
draw_triangle :: proc(a, b, c: [3]f32, color: [4]f32, depth_test := true) {
	col := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	append(&_pass.vtx, Vertex{a, n, {}, col}, Vertex{b, n, {}, col}, Vertex{c, n, {}, col})
	_batch_append(depth_test ? .Tris : .Tris_Overlay, nil, first, 3)
}

// depth_write=true makes the line participate in occlusion both ways (editor
// grid): later depth-tested draws can't paint over closer line pixels.
draw_line :: proc(a, b: [3]f32, color: [4]f32, depth_test := true, depth_write := false) {
	c := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	kind: _Pipeline_Kind = depth_test ? (depth_write ? .Lines_Depth : .Lines) : .Lines_Overlay
	append(&_pass.vtx, Vertex{a, n, {}, c}, Vertex{b, n, {}, c})
	_batch_append(kind, nil, first, 2)
}

// shader picks a registered shader set (shader_register); ""/unknown names
// fall back to DEFAULT_SHADER. The caller keeps `shader` alive through
// pass_end (material cache / string literals — never temp per-frame builds);
// `material` (property-block UBO bytes for fragment slot 1) may be
// temp-allocated — it's read at pass_end within the same frame.
// index_count=0 draws the whole mesh; a submesh passes its index range.
draw_mesh :: proc(mesh: Mesh, tex: ^Texture, model: matrix[4, 4]f32, color: [4]f32, shader := "", first_index: u32 = 0, index_count: u32 = 0, material: []u8 = nil, extra_tex: []^Texture = nil, no_shadow: bool = false, bounds_center: [3]f32 = {}, bounds_radius: f32 = 0, double_sided: bool = false) {
	if mesh.index_count == 0 do return
	count := index_count == 0 ? mesh.index_count : index_count
	if first_index >= mesh.index_count do return
	count = min(count, mesh.index_count - first_index)
	kind: _Pipeline_Kind = .Tris_Depth
	if double_sided {
		kind = .Tris_Depth_TwoSided
	} else if model_has_negative_scale(model) {
		kind = .Tris_Depth_Front
	}
	append(&_pass.draws, _Draw{
		kind          = kind,
		is_mesh       = true,
		texture       = tex,
		vp_index      = _current_vp(),
		mesh          = mesh,
		mesh_first    = first_index,
		mesh_count    = count,
		model         = model,
		color         = color,
		shader        = shader,
		material      = material,
		extra_tex     = extra_tex,
		no_shadow     = no_shadow,
		bounds_center = bounds_center,
		bounds_radius = bounds_radius,
	})
}

// Draws indexed lines using a mesh's line index buffer and vertex buffer.
// Used for hardware-accelerated 3D wireframe overlays on skinned or static meshes.
draw_mesh_lines :: proc(mesh: Mesh, model: matrix[4, 4]f32, color: [4]f32, depth_test := true) {
	if mesh.index_count == 0 || mesh.vbuf == nil || mesh.ibuf == nil do return
	append(&_pass.draws, _Draw{
		kind       = depth_test ? .Lines : .Lines_Overlay,
		is_mesh    = true,
		texture    = nil,
		vp_index   = _current_vp(),
		mesh       = mesh,
		mesh_first = 0,
		mesh_count = mesh.index_count,
		model      = model,
		color      = color,
		shader     = "",
	})
}

_color_u8 :: proc(c: [4]f32) -> [4]u8 {
	return {
		u8(clamp(c.r, 0, 1) * 255),
		u8(clamp(c.g, 0, 1) * 255),
		u8(clamp(c.b, 0, 1) * 255),
		u8(clamp(c.a, 0, 1) * 255),
	}
}

// Extends the previous draw when pipeline/texture/view/shader/material
// match — the common case for sprite runs and grid lines. Material slices
// compare by pointer: callers reuse one packed slice per material to merge.
_batch_append :: proc(kind: _Pipeline_Kind, tex: ^Texture, first: u32, count: u32, shader := "", material: []u8 = nil, extra_tex: []^Texture = nil) {
	vp := _current_vp()
	if len(_pass.draws) > 0 {
		last := &_pass.draws[len(_pass.draws)-1]
		if !last.is_mesh && last.kind == kind && last.texture == tex && last.vp_index == vp &&
		   last.shader == shader &&
		   raw_data(last.material) == raw_data(material) && len(last.material) == len(material) &&
		   raw_data(last.extra_tex) == raw_data(extra_tex) && len(last.extra_tex) == len(extra_tex) &&
		   last.first_vertex + last.vertex_count == first {
			last.vertex_count += count
			return
		}
	}
	append(&_pass.draws, _Draw{
		kind         = kind,
		texture      = tex,
		vp_index     = vp,
		first_vertex = first,
		vertex_count = count,
		shader       = shader,
		material     = material,
		extra_tex    = extra_tex,
	})
}

@(private = "file")
_pass_finish_reset :: proc() {
	clear(&_pass.vtx)
	clear(&_pass.draws)
	clear(&_pass.vps)
	_pass.active = false
	_pass.target_rt = nil
	_pass.target_color = nil
	_pass.target_depth = nil
	_pass.resolve_dst = nil
	_pass.resolve_w = 0
	_pass.resolve_h = 0
	_pass.light = nil
	_pass.post_fx = POST_FX_DEFAULT
}

// Encodes the pass: batch upload (copy pass), then the render pass replaying
// draws. before_end runs inside the render pass (the editor renders imgui
// draw data there).
pass_end :: proc(before_end: proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) = nil) {
	assert(_pass.active, "gfx pass not active")
	if _gfx.cmd == nil || _gfx.device == nil || _pass.target_color == nil {
		_pass_finish_reset()
		return
	}
	_flush_pending_skinning(_gfx.cmd)
	_upload_batch()

	color_info := sdl.GPUColorTargetInfo{
		texture  = _pass.target_color,
		load_op  = .LOAD,
		store_op = .STORE,
	}
	if clear, ok := _pass.clear.?; ok {
		color_info.load_op = .CLEAR
		if _pass.target_rt != nil && _gfx.hdr_format != _gfx.swapchain_format {
			color_info.clear_color = {
				math.pow(max(clear.r, f32(0)), f32(2.2)),
				math.pow(max(clear.g, f32(0)), f32(2.2)),
				math.pow(max(clear.b, f32(0)), f32(2.2)),
				clear.a,
			}
		} else {
			color_info.clear_color = {clear.r, clear.g, clear.b, clear.a}
		}
	}
	// If draws were recorded in a pass started with depth = false (STUB-11),
	// bind the shared scratch depth buffer so standard pipelines remain valid.
	if _pass.target_depth == nil && len(_pass.draws) > 0 {
		ps := pixel_size()
		w, h := u32(max(ps.x, 1)), u32(max(ps.y, 1))
		if _gfx.window_depth == nil || _gfx.window_depth_w != w || _gfx.window_depth_h != h {
			if _gfx.window_depth != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.window_depth)
			_gfx.window_depth = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
				type                 = .D2,
				format               = _depth_format(),
				usage                = {.DEPTH_STENCIL_TARGET},
				width                = w,
				height               = h,
				layer_count_or_depth = 1,
				num_levels           = 1,
			})
			_gfx.window_depth_w = w
			_gfx.window_depth_h = h
		}
		_pass.target_depth = _gfx.window_depth
	}
	rp: ^sdl.GPURenderPass
	if _pass.target_depth != nil {
		depth_info := sdl.GPUDepthStencilTargetInfo{
			texture          = _pass.target_depth,
			clear_depth      = 1,
			load_op          = .CLEAR, // depth is always per-pass scratch
			store_op         = .DONT_CARE,
			stencil_load_op  = .DONT_CARE,
			stencil_store_op = .DONT_CARE,
		}
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, &depth_info)
	} else {
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, nil)
	}
	if rp == nil {
		_pass_finish_reset()
		return
	}

	// Light + camera uniforms (fragment slot 0) are re-pushed on view switch —
	// cam_pos is per-view (multi-camera passes). Only pipelines that declare
	// the fragment UBO (lit, user shaders) consume them.
	light := _pass.light.? or_else _LIGHT_DEFAULT

	bound: ^sdl.GPUGraphicsPipeline
	batch_bound := false
	bound_vbuf: ^sdl.GPUBuffer
	bound_ibuf: ^sdl.GPUBuffer
	bound_samplers: [MAX_FRAGMENT_SAMPLERS]sdl.GPUTextureSamplerBinding
	bound_num_samplers: u32
	pushed_vp := i32(-1)
	pushed_light_vp := i32(-1)
	pushed_mesh := false
	pushed_mat: []u8
	pushed_mat_is_zero := false
	for &d in _pass.draws {
		if pushed_light_vp != d.vp_index {
			light.cam_pos.xyz = _pass.vps[d.vp_index].cam_pos
			sdl.PushGPUFragmentUniformData(_gfx.cmd, 0, &light, size_of(_Light_Uniform))
			pushed_light_vp = d.vp_index
		}
		pipeline := _gfx.pipelines[d.kind]
		if d.shader != "" {
			if set, ok := _gfx.shader_sets[d.shader]; ok do pipeline = set[d.kind]
		}
		if pipeline != bound {
			sdl.BindGPUGraphicsPipeline(rp, pipeline)
			bound = pipeline
			batch_bound = false // vertex buffer binding survives, but re-bind cheaply per pipeline switch
			bound_num_samplers = 0
			pushed_mat = nil
			pushed_mat_is_zero = false
		}
		tex := d.texture != nil ? d.texture : _gfx.white_tex
		// Select sampler from the texture's configured filter/wrap modes (`REV-08`),
		// defaulting wrap to REPEAT for meshes and CLAMP for batch quads when Default.
		_sampler_for_texture :: #force_inline proc(t: ^Texture, is_mesh: bool) -> ^sdl.GPUSampler {
			if t == nil do return is_mesh ? _gfx.sampler_repeat : _gfx.sampler_linear
			wrap_idx: int
			switch t.wrap {
			case .Default: wrap_idx = is_mesh ? 1 : 0
			case .Repeat:  wrap_idx = 1
			case .Clamp:   wrap_idx = 0
			case .Mirror:  wrap_idx = 2
			}
			if s := _gfx.samplers[t.filter][wrap_idx]; s != nil do return s
			return is_mesh ? _gfx.sampler_repeat : _gfx.sampler_linear
		}
		// Slot 0 = main texture; extra_tex fills 1..N; slot 7 = shared shadow atlas
		// whenever the pipeline declares > SHADOW_SAMPLER_SLOT fragment samplers.
		shader_name := d.shader != "" ? d.shader : DEFAULT_SHADER
		req_samplers := _gfx.shader_samplers[shader_name]
		if req_samplers == 0 do req_samplers = 1
		req_samplers = min(req_samplers, MAX_FRAGMENT_SAMPLERS)

		bindings: [MAX_FRAGMENT_SAMPLERS]sdl.GPUTextureSamplerBinding
		default_smp := _sampler_for_texture(_gfx.white_tex, d.is_mesh)
		bindings[0] = {texture = tex.gpu, sampler = _sampler_for_texture(tex, d.is_mesh)}
		for i in u32(1) ..< MAX_FRAGMENT_SAMPLERS {
			bindings[i] = {texture = _gfx.white_tex.gpu, sampler = default_smp}
		}
		for et, idx in d.extra_tex {
			slot := u32(idx + 1)
			if slot >= MAX_FRAGMENT_SAMPLERS do break
			if slot == SHADOW_SAMPLER_SLOT && req_samplers > SHADOW_SAMPLER_SLOT do continue
			t := et != nil ? et : _gfx.white_tex
			bindings[slot] = {texture = t.gpu, sampler = _sampler_for_texture(t, d.is_mesh)}
		}
		if req_samplers > SHADOW_SAMPLER_SLOT {
			shadow_tex := _shadow.atlas != nil ? _shadow.atlas : _gfx.white_tex.gpu
			shadow_smp := _shadow.sampler != nil ? _shadow.sampler : _gfx.sampler_nearest
			bindings[SHADOW_SAMPLER_SLOT] = {texture = shadow_tex, sampler = shadow_smp}
		}
		num_bindings := max(req_samplers, min(u32(1 + len(d.extra_tex)), MAX_FRAGMENT_SAMPLERS))
		samplers_changed := num_bindings != bound_num_samplers
		if !samplers_changed {
			for si in u32(0) ..< num_bindings {
				if bindings[si] != bound_samplers[si] {
					samplers_changed = true
					break
				}
			}
		}
		if samplers_changed {
			sdl.BindGPUFragmentSamplers(rp, 0, &bindings[0], num_bindings)
			for si in u32(0) ..< num_bindings {
				bound_samplers[si] = bindings[si]
			}
			bound_num_samplers = num_bindings
		}

		req_ubos := _gfx.shader_ubos[shader_name]
		if len(d.material) > 0 {
			if pushed_mat_is_zero || !slice.equal(pushed_mat, d.material) {
				// Shader property block (custom shaders' MaterialUBO / LitMaterialUBO, slot 1).
				sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, raw_data(d.material), u32(len(d.material)))
				pushed_mat = d.material
				pushed_mat_is_zero = false
			}
		} else if req_ubos > 1 {
			if !pushed_mat_is_zero {
				zero_ubo: [4]f32
				sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, &zero_ubo, size_of([4]f32))
				pushed_mat = nil
				pushed_mat_is_zero = true
			}
		}

		if d.is_mesh {
			u := _Uniform{view_proj = _pass.vps[d.vp_index].vp, model = d.model, tint = d.color}
			sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
			pushed_vp = -1
			pushed_mesh = true

			if d.mesh.vbuf != bound_vbuf {
				vb := sdl.GPUBufferBinding{buffer = d.mesh.vbuf}
				sdl.BindGPUVertexBuffers(rp, 0, &vb, 1)
				bound_vbuf = d.mesh.vbuf
			}
			if d.mesh.ibuf != bound_ibuf {
				sdl.BindGPUIndexBuffer(rp, {buffer = d.mesh.ibuf}, ._32BIT)
				bound_ibuf = d.mesh.ibuf
			}
			sdl.DrawGPUIndexedPrimitives(rp, d.mesh_count, 1, d.mesh_first, 0, 0)
			batch_bound = false
		} else {
			if pushed_vp != d.vp_index || pushed_mesh {
				u := _Uniform{view_proj = _pass.vps[d.vp_index].vp, model = _MAT4_IDENTITY, tint = {1, 1, 1, 1}}
				sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
				pushed_vp = d.vp_index
				pushed_mesh = false
			}
			if !batch_bound {
				if bound_vbuf != _pass.vbuf {
					vb := sdl.GPUBufferBinding{buffer = _pass.vbuf}
					sdl.BindGPUVertexBuffers(rp, 0, &vb, 1)
					bound_vbuf = _pass.vbuf
				}
				batch_bound = true
			}
			sdl.DrawGPUPrimitives(rp, d.vertex_count, 1, d.first_vertex, 0)
		}
	}

	if before_end != nil do before_end(_gfx.cmd, rp)
	sdl.EndGPURenderPass(rp)

	if _pass.target_rt != nil && _pass.resolve_dst != nil {
		_post_fx_resolve(_gfx.cmd, _pass.target_rt, _pass.resolve_dst, _pass.resolve_w, _pass.resolve_h, _pass.post_fx)
	}
	_pass_finish_reset()
}

// One copy pass uploading this pass's vertices. cycle=true keeps earlier
// encoded passes (and in-flight frames) reading their own allocation.
_upload_batch :: proc() {
	count := u32(len(_pass.vtx))
	if count == 0 do return

	if count > _pass.vbuf_capacity {
		new_cap := max(u32(4096), _pass.vbuf_capacity)
		for new_cap < count do new_cap *= 2
		if _pass.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, _pass.vbuf)
		if _pass.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, _pass.transfer)
		_pass.vbuf = nil
		_pass.transfer = nil
		_pass.vbuf_capacity = 0
		size := new_cap * size_of(Vertex)
		vbuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX}, size = size})
		transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = size})
		if vbuf == nil || transfer == nil {
			if vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, vbuf)
			if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
			return
		}
		_pass.vbuf = vbuf
		_pass.transfer = transfer
		_pass.vbuf_capacity = new_cap
	}
	if _pass.vbuf == nil || _pass.transfer == nil do return

	byte_count := int(count) * size_of(Vertex)
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, _pass.transfer, true)
	if mapped == nil do return
	runtime.mem_copy_non_overlapping(mapped, raw_data(_pass.vtx), byte_count)
	sdl.UnmapGPUTransferBuffer(_gfx.device, _pass.transfer)

	copy_pass := sdl.BeginGPUCopyPass(_gfx.cmd)
	if copy_pass == nil do return
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = _pass.transfer},
		{buffer = _pass.vbuf, size = u32(byte_count)}, true)
	sdl.EndGPUCopyPass(copy_pass)
}

// Frame teardown: the swapchain image is only valid until submit.
_swapchain_frame_clear :: proc() {
	_swapchain_this_frame = {}
}

// Hands the frame's pending capture to frame_end, which submits with a fence.
_swapchain_take_pending :: proc() -> ^Texture_Download {
	d := _swapchain_pending_download
	_swapchain_pending_download = nil
	return d
}
