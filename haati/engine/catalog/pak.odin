package catalog

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

PAK_MAGIC   :: "MHPAK001"
PAK_VERSION :: u32(1)
_PAK_HEADER_SIZE :: 24
PAK_STREAM_CHUNK_BYTES :: 256 * 1024

Pak_Entry :: struct {
	path:    string,
	offset:  u64,
	size:    u64,
	fnv1a64: u64,
}

Pak_Archive :: struct {
	file:      ^os.File,
	file_size: u64,
	entries:   map[string]Pak_Entry,
	alloc:     runtime.Allocator,
}

pak_fnv1a64 :: proc(bytes: []u8) -> u64 {
	return hash.fnv64a(bytes)
}

@(private = "file")
_pak_write_all :: proc(f: ^os.File, data: []u8) -> bool {
	written := 0
	for written < len(data) {
		n, err := os.write(f, data[written:])
		if err != nil || n <= 0 do return false
		written += n
	}
	return true
}

@(private = "file")
_pak_write_at_all :: proc(f: ^os.File, data: []u8, offset: i64) -> bool {
	written := 0
	for written < len(data) {
		n, err := os.write_at(f, data[written:], offset + i64(written))
		if err != nil || n <= 0 do return false
		written += n
	}
	return true
}

@(private = "file")
_pak_read_at_all :: proc(f: ^os.File, dst: []u8, offset: i64) -> bool {
	got := 0
	for got < len(dst) {
		n, err := os.read_at(f, dst[got:], offset + i64(got))
		if n > 0 {
			got += n
		}
		if err != nil {
			if got == len(dst) && err == io.Error.EOF {
				return true
			}
			return false
		}
		if n <= 0 do return false
	}
	return true
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

// Packs all regular files under `src_dir` into a deterministic `MHPAK001` archive via fixed-buffer streaming.
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

	norm_out, _ := strings.replace_all(out_pak_path, "\\", "/", context.temp_allocator)
	ensure_parent_dirs(norm_out)

	out_f, oerr := os.create(out_pak_path)
	if oerr != nil {
		return 0, false
	}
	pack_ok := false
	defer {
		if out_f != nil {
			os.close(out_f)
		}
		if !pack_ok {
			_ = os.remove(out_pak_path)
		}
	}

	zero_hdr: [_PAK_HEADER_SIZE]u8
	if !_pak_write_all(out_f, zero_hdr[:]) {
		return 0, false
	}

	chunk := make([]u8, PAK_STREAM_CHUNK_BYTES, alloc)
	defer delete(chunk, alloc)

	cursor := u64(_PAK_HEADER_SIZE)
	for p in paths {
		if len(p) > int(max(u16)) do return 0, false
		full := strings.concatenate({src_dir, "/", p}, context.temp_allocator)
		sf, serr := os.open(full)
		if serr != nil do return 0, false

		fsz_i64, sz_err := os.file_size(sf)
		if sz_err != nil || fsz_i64 < 0 {
			os.close(sf)
			return 0, false
		}

		h := u64(0xcbf29ce484222325)
		written_sz := u64(0)
		stream_ok := true
		for {
			r, rerr := os.read(sf, chunk)
			if r > 0 {
				h = hash.fnv64a(chunk[:r], h)
				if !_pak_write_all(out_f, chunk[:r]) {
					stream_ok = false
					break
				}
				written_sz += u64(r)
			}
			if rerr != nil {
				if rerr != io.Error.EOF {
					stream_ok = false
				}
				break
			}
			if r == 0 do break
		}
		os.close(sf)

		if !stream_ok || written_sz != u64(fsz_i64) {
			return 0, false
		}

		append(&metas, _Packed_Meta{
			path    = p,
			offset  = cursor,
			size    = written_sz,
			fnv1a64 = h,
		})
		cursor += written_sz
	}

	toc_offset := cursor

	// Serialize and stream TOC entries.
	toc_buf := make([dynamic]u8, 0, len(metas) * 64 + 64, alloc)
	defer delete(toc_buf)
	for m in metas {
		plen := u16(len(m.path))
		start := len(toc_buf)
		resize(&toc_buf, start + 2 + int(plen) + 24)
		endian.unchecked_put_u16le(toc_buf[start : start+2], plen)
		copy(toc_buf[start+2 : start+2+int(plen)], m.path)
		meta_off := start + 2 + int(plen)
		endian.unchecked_put_u64le(toc_buf[meta_off : meta_off+8], m.offset)
		endian.unchecked_put_u64le(toc_buf[meta_off+8 : meta_off+16], m.size)
		endian.unchecked_put_u64le(toc_buf[meta_off+16 : meta_off+24], m.fnv1a64)
	}
	if len(toc_buf) > 0 && !_pak_write_all(out_f, toc_buf[:]) {
		return 0, false
	}

	// Patch final header at offset 0.
	hdr: [_PAK_HEADER_SIZE]u8
	copy(hdr[0:8], PAK_MAGIC)
	endian.unchecked_put_u32le(hdr[8:12], PAK_VERSION)
	endian.unchecked_put_u32le(hdr[12:16], u32(len(metas)))
	endian.unchecked_put_u64le(hdr[16:24], toc_offset)
	if !_pak_write_at_all(out_f, hdr[:], 0) {
		return 0, false
	}

	cerr := os.close(out_f)
	out_f = nil
	if cerr != nil {
		return 0, false
	}
	pack_ok = true
	return len(metas), true
}

pak_open :: proc(pak_path: string, allocator := context.allocator) -> (ar: Pak_Archive, ok: bool) {
	f, err := os.open(pak_path)
	if err != nil do return {}, false

	fsz_i64, serr := os.file_size(f)
	if serr != nil || fsz_i64 < _PAK_HEADER_SIZE {
		os.close(f)
		return {}, false
	}
	fsz := u64(fsz_i64)

	hdr: [_PAK_HEADER_SIZE]u8
	if !_pak_read_at_all(f, hdr[:], 0) {
		os.close(f)
		return {}, false
	}
	if string(hdr[0:8]) != PAK_MAGIC {
		os.close(f)
		return {}, false
	}
	ver := endian.unchecked_get_u32le(hdr[8:12])
	if ver != PAK_VERSION {
		os.close(f)
		return {}, false
	}
	entry_count := endian.unchecked_get_u32le(hdr[12:16])
	toc_offset := endian.unchecked_get_u64le(hdr[16:24])
	if toc_offset < _PAK_HEADER_SIZE || toc_offset > fsz {
		os.close(f)
		return {}, false
	}
	if u64(entry_count) > (fsz - toc_offset) / 26 {
		os.close(f)
		return {}, false
	}

	toc_size := fsz - toc_offset
	if toc_size > u64(max(int)) {
		os.close(f)
		return {}, false
	}
	toc_bytes := make([]u8, int(toc_size), allocator)
	defer delete(toc_bytes, allocator)
	if len(toc_bytes) > 0 && !_pak_read_at_all(f, toc_bytes, i64(toc_offset)) {
		os.close(f)
		return {}, false
	}

	cleanup_fail := proc(f: ^os.File, entries: ^map[string]Pak_Entry, alloc: runtime.Allocator) {
		for k in entries^ do delete(k, alloc)
		delete(entries^)
		os.close(f)
	}

	entries := make(map[string]Pak_Entry, int(entry_count), allocator)
	cursor := 0
	for _ in 0 ..< entry_count {
		if len(toc_bytes) - cursor < 2 {
			cleanup_fail(f, &entries, allocator)
			return {}, false
		}
		plen := int(endian.unchecked_get_u16le(toc_bytes[cursor : cursor+2]))
		cursor += 2
		if len(toc_bytes) - cursor < plen + 24 {
			cleanup_fail(f, &entries, allocator)
			return {}, false
		}
		raw_path := string(toc_bytes[cursor : cursor+plen])
		cursor += plen
		off := endian.unchecked_get_u64le(toc_bytes[cursor : cursor+8])
		sz  := endian.unchecked_get_u64le(toc_bytes[cursor+8 : cursor+16])
		h   := endian.unchecked_get_u64le(toc_bytes[cursor+16 : cursor+24])
		cursor += 24

		if !_is_safe_rel_path(raw_path) || raw_path in entries {
			cleanup_fail(f, &entries, allocator)
			return {}, false
		}
		if off < _PAK_HEADER_SIZE || sz > toc_offset || off > toc_offset - sz {
			cleanup_fail(f, &entries, allocator)
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
		file      = f,
		file_size = fsz,
		entries   = entries,
		alloc     = allocator,
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
	if ar.file != nil {
		os.close(ar.file)
	}
	ar^ = {}
}

pak_read_entry :: proc(ar: ^Pak_Archive, rel_path: string, allocator := context.temp_allocator) -> (bytes: []u8, ok: bool) {
	if ar == nil || ar.file == nil do return nil, false
	norm := _normalize_rel_path(rel_path, context.temp_allocator)
	entry, has := ar.entries[norm]
	if !has do return nil, false

	if entry.offset > ar.file_size || entry.size > ar.file_size - entry.offset do return nil, false
	if entry.size > u64(max(int)) do return nil, false

	if entry.size == 0 {
		if pak_fnv1a64(nil) != entry.fnv1a64 do return nil, false
		out := make([]u8, 0, allocator)
		return out, true
	}

	out := make([]u8, int(entry.size), allocator)
	if !_pak_read_at_all(ar.file, out, i64(entry.offset)) {
		delete(out, allocator)
		return nil, false
	}
	if pak_fnv1a64(out) != entry.fnv1a64 {
		delete(out, allocator)
		return nil, false
	}
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

		payload, rok := pak_read_entry(&ar, norm, allocator)
		if !rok do return false

		out_file := strings.concatenate({dst_dir, "/", norm}, context.temp_allocator)
		parent := filepath.dir(out_file)
		if parent != "" && parent != "." {
			_ = os.make_directory_all(parent)
		}
		werr := os.write_entire_file(out_file, payload)
		delete(payload, allocator)
		if werr != nil {
			return false
		}
	}
	return true
}
