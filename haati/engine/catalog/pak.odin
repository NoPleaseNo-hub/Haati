package catalog

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

PAK_MAGIC   :: "MHPAK001"
PAK_VERSION :: u32(1)
_PAK_HEADER_SIZE :: 24

Pak_Entry :: struct {
	path:    string,
	offset:  u64,
	size:    u64,
	fnv1a64: u64,
}

Pak_Archive :: struct {
	data:    []u8,
	entries: map[string]Pak_Entry,
	alloc:   runtime.Allocator,
}

pak_fnv1a64 :: proc(bytes: []u8) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in bytes {
		h ~= u64(b)
		h *= u64(0x100000001b3)
	}
	return h
}

@(private = "file")
_put_u16le :: #force_inline proc(dst: []u8, v: u16) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
}

@(private = "file")
_put_u32le :: #force_inline proc(dst: []u8, v: u32) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
	dst[2] = u8(v >> 16)
	dst[3] = u8(v >> 24)
}

@(private = "file")
_put_u64le :: #force_inline proc(dst: []u8, v: u64) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
	dst[2] = u8(v >> 16)
	dst[3] = u8(v >> 24)
	dst[4] = u8(v >> 32)
	dst[5] = u8(v >> 40)
	dst[6] = u8(v >> 48)
	dst[7] = u8(v >> 56)
}

@(private = "file")
_get_u16le :: #force_inline proc(src: []u8) -> u16 {
	return u16(src[0]) | (u16(src[1]) << 8)
}

@(private = "file")
_get_u32le :: #force_inline proc(src: []u8) -> u32 {
	return u32(src[0]) | (u32(src[1]) << 8) | (u32(src[2]) << 16) | (u32(src[3]) << 24)
}

@(private = "file")
_get_u64le :: #force_inline proc(src: []u8) -> u64 {
	return u64(src[0]) |
		(u64(src[1]) << 8) |
		(u64(src[2]) << 16) |
		(u64(src[3]) << 24) |
		(u64(src[4]) << 32) |
		(u64(src[5]) << 40) |
		(u64(src[6]) << 48) |
		(u64(src[7]) << 56)
}

@(private = "file")
_normalize_rel_path :: proc(p: string, allocator := context.temp_allocator) -> string {
	replaced, _ := strings.replace_all(p, "\\", "/", allocator)
	res := replaced
	for strings.has_prefix(res, "./") {
		res = res[2:]
	}
	res = strings.trim_left(res, "/")
	return res
}

@(private = "file")
_is_safe_rel_path :: proc(p: string) -> bool {
	if len(p) == 0 do return false
	if p[0] == '/' || p[0] == '\\' do return false
	if strings.contains_rune(p, ':') do return false
	for seg in strings.split(p, "/", context.temp_allocator) {
		if seg == ".." do return false
	}
	return true
}

@(private = "file")
_collect_files :: proc(root_dir: string, rel_prefix: string, out: ^[dynamic]string, alloc: runtime.Allocator) -> bool {
	cur_dir := rel_prefix == "" ? root_dir : fmt.tprintf("%s/%s", root_dir, rel_prefix)
	handle, err := os.open(cur_dir)
	if err != nil do return false
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return false

	for e in entries {
		rel := rel_prefix == "" ? e.name : strings.concatenate({rel_prefix, "/", e.name}, context.temp_allocator)
		full := strings.concatenate({root_dir, "/", rel}, context.temp_allocator)
		if e.type == .Directory {
			if !_collect_files(root_dir, rel, out, alloc) do return false
		} else if os.is_file(full) {
			norm := _normalize_rel_path(rel, context.temp_allocator)
			append(out, strings.clone(norm, alloc))
		}
	}
	return true
}

// Packs all regular files under `src_dir` into a deterministic `MHPAK001` archive at `out_pak_path`.
pak_pack_directory :: proc(src_dir: string, out_pak_path: string) -> (count: int, ok: bool) {
	if src_dir == "" || out_pak_path == "" || !os.is_dir(src_dir) {
		return 0, false
	}

	alloc := runtime.default_allocator()
	paths := make([dynamic]string, 0, 64, alloc)
	defer {
		for p in paths do delete(p, alloc)
		delete(paths)
	}

	if !_collect_files(src_dir, "", &paths, alloc) {
		return 0, false
	}
	slice.sort(paths[:])

	_Packed_Meta :: struct {
		path:    string,
		offset:  u64,
		size:    u64,
		fnv1a64: u64,
	}
	metas := make([dynamic]_Packed_Meta, 0, len(paths), alloc)
	defer delete(metas)

	buf := make([dynamic]u8, _PAK_HEADER_SIZE, 4096, alloc)
	defer delete(buf)

	for p in paths {
		if len(p) > int(max(u16)) do return 0, false
		full := strings.concatenate({src_dir, "/", p}, context.temp_allocator)
		fbytes, ferr := os.read_entire_file(full, alloc)
		if ferr != nil do return 0, false
		defer delete(fbytes, alloc)

		off := u64(len(buf))
		sz := u64(len(fbytes))
		hash := pak_fnv1a64(fbytes)
		append(&metas, _Packed_Meta{
			path    = p,
			offset  = off,
			size    = sz,
			fnv1a64 = hash,
		})
		if len(fbytes) > 0 {
			append(&buf, ..fbytes)
		}
	}

	toc_offset := u64(len(buf))

	// Write header.
	copy(buf[0:8], PAK_MAGIC)
	_put_u32le(buf[8:12], PAK_VERSION)
	_put_u32le(buf[12:16], u32(len(metas)))
	_put_u64le(buf[16:24], toc_offset)

	// Append TOC entries.
	for m in metas {
		plen := u16(len(m.path))
		start := len(buf)
		resize(&buf, start + 2 + int(plen) + 24)
		_put_u16le(buf[start : start+2], plen)
		copy(buf[start+2 : start+2+int(plen)], m.path)
		meta_off := start + 2 + int(plen)
		_put_u64le(buf[meta_off : meta_off+8], m.offset)
		_put_u64le(buf[meta_off+8 : meta_off+16], m.size)
		_put_u64le(buf[meta_off+16 : meta_off+24], m.fnv1a64)
	}

	norm_out, _ := strings.replace_all(out_pak_path, "\\", "/", context.temp_allocator)
	ensure_parent_dirs(norm_out)
	if os.write_entire_file(out_pak_path, buf[:]) != nil {
		return 0, false
	}
	return len(metas), true
}

pak_open :: proc(pak_path: string, allocator := context.allocator) -> (ar: Pak_Archive, ok: bool) {
	data, err := os.read_entire_file(pak_path, allocator)
	if err != nil do return {}, false

	cleanup_fail := proc(data: []u8, entries: ^map[string]Pak_Entry, alloc: runtime.Allocator) {
		for k in entries^ do delete(k, alloc)
		delete(entries^)
		delete(data, alloc)
	}

	if len(data) < _PAK_HEADER_SIZE {
		delete(data, allocator)
		return {}, false
	}
	if string(data[0:8]) != PAK_MAGIC {
		delete(data, allocator)
		return {}, false
	}
	ver := _get_u32le(data[8:12])
	if ver != PAK_VERSION {
		delete(data, allocator)
		return {}, false
	}
	entry_count := _get_u32le(data[12:16])
	toc_offset := _get_u64le(data[16:24])
	if toc_offset < _PAK_HEADER_SIZE || toc_offset > u64(len(data)) {
		delete(data, allocator)
		return {}, false
	}

	entries := make(map[string]Pak_Entry, int(entry_count), allocator)
	cursor := int(toc_offset)
	for _ in 0 ..< entry_count {
		if cursor + 2 > len(data) {
			cleanup_fail(data, &entries, allocator)
			return {}, false
		}
		plen := int(_get_u16le(data[cursor : cursor+2]))
		cursor += 2
		if cursor + plen + 24 > len(data) {
			cleanup_fail(data, &entries, allocator)
			return {}, false
		}
		raw_path := string(data[cursor : cursor+plen])
		cursor += plen
		off := _get_u64le(data[cursor : cursor+8])
		sz  := _get_u64le(data[cursor+8 : cursor+16])
		h   := _get_u64le(data[cursor+16 : cursor+24])
		cursor += 24

		if off < _PAK_HEADER_SIZE || sz > toc_offset || off + sz > toc_offset {
			cleanup_fail(data, &entries, allocator)
			return {}, false
		}
		p_clone := strings.clone(raw_path, allocator)
		entries[p_clone] = Pak_Entry{
			path    = p_clone,
			offset  = off,
			size    = sz,
			fnv1a64 = h,
		}
	}

	ar = Pak_Archive{
		data    = data,
		entries = entries,
		alloc   = allocator,
	}
	return ar, true
}

pak_close :: proc(ar: ^Pak_Archive) {
	if ar == nil do return
	alloc := ar.alloc if ar.alloc.procedure != nil else context.allocator
	for k in ar.entries {
		delete(k, alloc)
	}
	delete(ar.entries)
	if ar.data != nil {
		delete(ar.data, alloc)
	}
	ar^ = {}
}

pak_read_entry :: proc(ar: ^Pak_Archive, rel_path: string, allocator := context.temp_allocator) -> (bytes: []u8, ok: bool) {
	if ar == nil || len(ar.data) == 0 do return nil, false
	norm := _normalize_rel_path(rel_path, context.temp_allocator)
	entry, has := ar.entries[norm]
	if !has do return nil, false

	end := entry.offset + entry.size
	if end > u64(len(ar.data)) || entry.offset > end do return nil, false

	payload := ar.data[entry.offset:end]
	if pak_fnv1a64(payload) != entry.fnv1a64 do return nil, false

	if entry.size == 0 {
		out := make([]u8, 0, allocator)
		return out, true
	}
	out := make([]u8, int(entry.size), allocator)
	copy(out, payload)
	return out, true
}

pak_extract_directory :: proc(pak_path: string, dst_dir: string, allocator := context.allocator) -> bool {
	if dst_dir == "" do return false
	ar, ok := pak_open(pak_path, allocator)
	if !ok do return false
	defer pak_close(&ar)

	for _, entry in ar.entries {
		norm := _normalize_rel_path(entry.path, context.temp_allocator)
		if !_is_safe_rel_path(norm) do return false

		end := entry.offset + entry.size
		if end > u64(len(ar.data)) || entry.offset > end do return false

		payload := ar.data[entry.offset:end]
		if pak_fnv1a64(payload) != entry.fnv1a64 do return false

		out_file := strings.concatenate({dst_dir, "/", norm}, context.temp_allocator)
		parent := filepath.dir(out_file)
		if parent != "" && parent != "." {
			_ = os.make_directory_all(parent)
		}
		if os.write_entire_file(out_file, payload) != nil {
			return false
		}
	}
	return true
}
