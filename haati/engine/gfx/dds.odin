package gfx

import "base:runtime"
import "core:encoding/endian"
import sdl "vendor:sdl3"

DDS_Mip :: struct {
	width:  u32,
	height: u32,
	offset: int,
	size:   int,
}

DDS_Info :: struct {
	format:      sdl.GPUTextureFormat,
	width:       u32,
	height:      u32,
	block_bytes: u32,
	mips:        [16]DDS_Mip,
	mip_count:   u32,
}

_DDS_MAGIC        :: u32(0x20534444) // "DDS "
_DDS_FOURCC_DXT1  :: u32(0x31545844) // "DXT1"
_DDS_FOURCC_DXT5  :: u32(0x35545844) // "DXT5"
_DDS_FOURCC_ATI2  :: u32(0x32495441) // "ATI2"
_DDS_FOURCC_BC5U  :: u32(0x55354342) // "BC5U"
_DDS_FOURCC_DX10  :: u32(0x30315844) // "DX10"
_DDPF_FOURCC      :: u32(0x4)
_DDSCAPS2_CUBEMAP :: u32(0x200)
_DDSD_MIPMAPCOUNT :: u32(0x20000)
_DX10_MISC_CUBE   :: u32(0x4)

@(private = "file")
_dds_dxgi_to_gpu :: proc(dxgi: u32) -> (fmt: sdl.GPUTextureFormat, block_bytes: u32, ok: bool) {
	switch dxgi {
	case 71: return .BC1_RGBA_UNORM, 8, true
	case 72: return .BC1_RGBA_UNORM_SRGB, 8, true
	case 77: return .BC3_RGBA_UNORM, 16, true
	case 78: return .BC3_RGBA_UNORM_SRGB, 16, true
	case 83: return .BC5_RG_UNORM, 16, true
	case 98: return .BC7_RGBA_UNORM, 16, true
	case 99: return .BC7_RGBA_UNORM_SRGB, 16, true
	}
	return .INVALID, 0, false
}

// Parses a DDS container header and validates all mip slice offsets for BC1/BC3/BC5/BC7 2D textures.
dds_parse :: proc(data: []u8) -> (info: DDS_Info, ok: bool) {
	if len(data) < 128 do return {}, false
	if endian.unchecked_get_u32le(data[0:]) != _DDS_MAGIC do return {}, false
	if endian.unchecked_get_u32le(data[4:]) != 124 do return {}, false  // dwSize
	if endian.unchecked_get_u32le(data[76:]) != 32 do return {}, false  // ddspf.dwSize

	flags := endian.unchecked_get_u32le(data[8:])
	height := endian.unchecked_get_u32le(data[12:])
	width := endian.unchecked_get_u32le(data[16:])
	depth := endian.unchecked_get_u32le(data[24:])
	mip_raw := endian.unchecked_get_u32le(data[28:])
	ddspf_flags := endian.unchecked_get_u32le(data[80:])
	fourcc := endian.unchecked_get_u32le(data[84:])
	caps2 := endian.unchecked_get_u32le(data[112:])

	if width == 0 || height == 0 || depth > 1 || (caps2 & _DDSCAPS2_CUBEMAP) != 0 do return {}, false
	if (ddspf_flags & _DDPF_FOURCC) == 0 do return {}, false

	payload_offset := 128
	switch fourcc {
	case _DDS_FOURCC_DXT1:
		info.format = .BC1_RGBA_UNORM
		info.block_bytes = 8
	case _DDS_FOURCC_DXT5:
		info.format = .BC3_RGBA_UNORM
		info.block_bytes = 16
	case _DDS_FOURCC_ATI2, _DDS_FOURCC_BC5U:
		info.format = .BC5_RG_UNORM
		info.block_bytes = 16
	case _DDS_FOURCC_DX10:
		if len(data) < 148 do return {}, false
		dxgi := endian.unchecked_get_u32le(data[128:])
		dim := endian.unchecked_get_u32le(data[132:])
		misc := endian.unchecked_get_u32le(data[136:])
		arr := endian.unchecked_get_u32le(data[140:])
		if (misc & _DX10_MISC_CUBE) != 0 || arr > 1 || (dim != 0 && dim != 3) do return {}, false
		fmt_ok: bool
		info.format, info.block_bytes, fmt_ok = _dds_dxgi_to_gpu(dxgi)
		if !fmt_ok do return {}, false
		payload_offset = 148
	case:
		return {}, false
	}

	declared_mips := u32(1)
	if (flags & _DDSD_MIPMAPCOUNT) != 0 || mip_raw > 1 {
		if mip_raw == 0 do return {}, false
		declared_mips = min(mip_raw, u32(len(info.mips)))
	}

	info.width = width
	info.height = height
	off := payload_offset
	mw := width
	mh := height
	for i in u32(0) ..< declared_mips {
		bw := max((mw + 3) / 4, 1)
		bh := max((mh + 3) / 4, 1)
		sz := int(u64(bw) * u64(bh) * u64(info.block_bytes))
		if sz <= 0 || off + sz > len(data) do return {}, false
		info.mips[i] = DDS_Mip{width = mw, height = mh, offset = off, size = sz}
		off += sz
		info.mip_count = i + 1
		mw = max(mw >> 1, 1)
		mh = max(mh >> 1, 1)
	}
	if info.mip_count == 0 do return {}, false
	return info, true
}

// Uploads a pre-compressed BC1/BC3/BC5/BC7 DDS texture with its mip chain directly to GPU memory.
texture_create_dds :: proc(data: []u8) -> ^Texture {
	if _gfx.device == nil do return nil
	info, ok := dds_parse(data)
	if !ok do return nil
	if !sdl.GPUTextureSupportsFormat(_gfx.device, info.format, .D2, {.SAMPLER}) do return nil

	last := info.mips[info.mip_count - 1]
	payload_start := info.mips[0].offset
	payload_end := last.offset + last.size
	payload_len := payload_end - payload_start
	if payload_len <= 0 do return nil

	gpu_tex := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = info.format,
		usage                = {.SAMPLER},
		width                = info.width,
		height               = info.height,
		layer_count_or_depth = 1,
		num_levels           = info.mip_count,
	})
	if gpu_tex == nil do return nil

	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(payload_len),
	})
	if transfer == nil {
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	if mapped == nil {
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	runtime.mem_copy_non_overlapping(mapped, raw_data(data[payload_start:payload_end]), payload_len)
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil {
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	if copy_pass == nil {
		_ = sdl.SubmitGPUCommandBuffer(cmd)
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	for m in u32(0) ..< info.mip_count {
		mip := info.mips[m]
		ppr := ((mip.width + 3) / 4) * 4
		rpl := ((mip.height + 3) / 4) * 4
		sdl.UploadToGPUTexture(copy_pass,
			{transfer_buffer = transfer, offset = u32(mip.offset - payload_start), pixels_per_row = ppr, rows_per_layer = rpl},
			{texture = gpu_tex, mip_level = m, w = mip.width, h = mip.height, d = 1},
			false)
	}
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	tex := new(Texture, runtime.default_allocator())
	tex.gpu = gpu_tex
	tex.width = i32(info.width)
	tex.height = i32(info.height)
	tex.format = info.format
	return tex
}
