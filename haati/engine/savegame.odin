package engine

// Zero-JSON binary Save-Game container (`HSVG0001`).
// Uses deterministic key-sorted binary records, 64-bit FNV-1a payload integrity
// verification (via `catalog.pak_fnv1a64`), and temp-file + sync + replace-rename
// atomic commits so abrupt power/process loss never corrupts existing save slots.

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "catalog"

SAVEGAME_MAGIC       :: "HSVG"
SAVEGAME_VERSION     :: u32(1)
SAVEGAME_HEADER_SIZE :: 32

Save_Tag :: enum u8 {
	Int    = 1,
	F32    = 2,
	F64    = 3,
	Bool   = 4,
	String = 5,
	Vec3   = 6,
	Quat   = 7,
	Bytes  = 8,
}

Save_Value :: union {
	i64,
	f32,
	f64,
	bool,
	string,
	[3]f32,
	[4]f32,
	[]u8,
}

Save_Game :: struct {
	version: u32,
	entries: map[string]Save_Value,
	alloc:   runtime.Allocator,
}

@(private = "file")
_sg_append_u16le :: proc(buf: ^[dynamic]u8, v: u16) {
	n := len(buf)
	resize(buf, n + 2)
	endian.unchecked_put_u16le(buf[n : n+2], v)
}

@(private = "file")
_sg_append_u32le :: proc(buf: ^[dynamic]u8, v: u32) {
	n := len(buf)
	resize(buf, n + 4)
	endian.unchecked_put_u32le(buf[n : n+4], v)
}

@(private = "file")
_sg_append_u64le :: proc(buf: ^[dynamic]u8, v: u64) {
	n := len(buf)
	resize(buf, n + 8)
	endian.unchecked_put_u64le(buf[n : n+8], v)
}

@(private = "file")
_sg_free_value :: proc(v: Save_Value, alloc: runtime.Allocator) {
	switch val in v {
	case i64, f32, f64, bool, [3]f32, [4]f32:
	case string:
		delete(val, alloc)
	case []u8:
		delete(val, alloc)
	}
}

@(private = "file")
_sg_ensure_alloc :: proc(sg: ^Save_Game) -> runtime.Allocator {
	if sg.alloc.procedure == nil {
		sg.alloc = context.allocator
	}
	if sg.version == 0 {
		sg.version = SAVEGAME_VERSION
	}
	return sg.alloc
}

@(private = "file")
_sg_put_entry :: proc(sg: ^Save_Game, key: string, val: Save_Value) -> bool {
	if sg == nil || key == "" || len(key) > int(max(u16)) do return false
	alloc := _sg_ensure_alloc(sg)
	if sg.entries == nil {
		sg.entries = make(map[string]Save_Value, 16, alloc)
	}
	if ptr, has := &sg.entries[key]; has {
		_sg_free_value(ptr^, alloc)
		ptr^ = val
		return true
	}
	k_clone := strings.clone(key, alloc)
	sg.entries[k_clone] = val
	return true
}

savegame_init :: proc(allocator := context.allocator) -> Save_Game {
	return Save_Game{
		version = SAVEGAME_VERSION,
		entries = make(map[string]Save_Value, 16, allocator),
		alloc   = allocator,
	}
}

savegame_destroy :: proc(sg: ^Save_Game) {
	if sg == nil do return
	alloc := sg.alloc if sg.alloc.procedure != nil else context.allocator
	for k, v in sg.entries {
		_sg_free_value(v, alloc)
		delete(k, alloc)
	}
	delete(sg.entries)
	sg^ = {}
}

savegame_set_i64 :: proc(sg: ^Save_Game, key: string, v: i64) -> bool {
	return _sg_put_entry(sg, key, v)
}

savegame_set_f32 :: proc(sg: ^Save_Game, key: string, v: f32) -> bool {
	return _sg_put_entry(sg, key, v)
}

savegame_set_f64 :: proc(sg: ^Save_Game, key: string, v: f64) -> bool {
	return _sg_put_entry(sg, key, v)
}

savegame_set_bool :: proc(sg: ^Save_Game, key: string, v: bool) -> bool {
	return _sg_put_entry(sg, key, v)
}

savegame_set_string :: proc(sg: ^Save_Game, key: string, v: string) -> bool {
	if sg == nil || key == "" || len(key) > int(max(u16)) do return false
	alloc := _sg_ensure_alloc(sg)
	return _sg_put_entry(sg, key, strings.clone(v, alloc))
}

savegame_set_vec3 :: proc(sg: ^Save_Game, key: string, v: [3]f32) -> bool {
	return _sg_put_entry(sg, key, v)
}

savegame_set_quat :: proc(sg: ^Save_Game, key: string, v: [4]f32) -> bool {
	return _sg_put_entry(sg, key, v)
}

savegame_set_bytes :: proc(sg: ^Save_Game, key: string, v: []u8) -> bool {
	if sg == nil || key == "" || len(key) > int(max(u16)) do return false
	alloc := _sg_ensure_alloc(sg)
	return _sg_put_entry(sg, key, slice.clone(v, alloc))
}

savegame_get_i64 :: proc(sg: ^Save_Game, key: string) -> (i64, bool) {
	if sg == nil do return 0, false
	raw, has := sg.entries[key]
	if !has do return 0, false
	v, ok := raw.(i64)
	return v, ok
}

savegame_get_f32 :: proc(sg: ^Save_Game, key: string) -> (f32, bool) {
	if sg == nil do return 0, false
	raw, has := sg.entries[key]
	if !has do return 0, false
	v, ok := raw.(f32)
	return v, ok
}

savegame_get_f64 :: proc(sg: ^Save_Game, key: string) -> (f64, bool) {
	if sg == nil do return 0, false
	raw, has := sg.entries[key]
	if !has do return 0, false
	v, ok := raw.(f64)
	return v, ok
}

savegame_get_bool :: proc(sg: ^Save_Game, key: string) -> (bool, bool) {
	if sg == nil do return false, false
	raw, has := sg.entries[key]
	if !has do return false, false
	v, ok := raw.(bool)
	return v, ok
}

savegame_get_string :: proc(sg: ^Save_Game, key: string) -> (string, bool) {
	if sg == nil do return "", false
	raw, has := sg.entries[key]
	if !has do return "", false
	v, ok := raw.(string)
	return v, ok
}

savegame_get_vec3 :: proc(sg: ^Save_Game, key: string) -> ([3]f32, bool) {
	if sg == nil do return {}, false
	raw, has := sg.entries[key]
	if !has do return {}, false
	v, ok := raw.([3]f32)
	return v, ok
}

savegame_get_quat :: proc(sg: ^Save_Game, key: string) -> ([4]f32, bool) {
	if sg == nil do return {}, false
	raw, has := sg.entries[key]
	if !has do return {}, false
	v, ok := raw.([4]f32)
	return v, ok
}

savegame_get_bytes :: proc(sg: ^Save_Game, key: string) -> ([]u8, bool) {
	if sg == nil do return nil, false
	raw, has := sg.entries[key]
	if !has do return nil, false
	v, ok := raw.([]u8)
	return v, ok
}

savegame_encode :: proc(sg: ^Save_Game, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	if sg == nil do return nil, false

	keys := make([dynamic]string, 0, len(sg.entries), allocator)
	defer delete(keys)
	for k in sg.entries {
		if len(k) == 0 || len(k) > int(max(u16)) do return nil, false
		append(&keys, k)
	}
	slice.sort(keys[:])

	buf := make([dynamic]u8, SAVEGAME_HEADER_SIZE, SAVEGAME_HEADER_SIZE + len(keys)*32, allocator)
	defer delete(buf)

	for k in keys {
		_sg_append_u16le(&buf, u16(len(k)))
		append(&buf, ..transmute([]u8)k)

		raw := sg.entries[k]
		switch val in raw {
		case i64:
			append(&buf, u8(Save_Tag.Int))
			_sg_append_u64le(&buf, u64(val))
		case f32:
			append(&buf, u8(Save_Tag.F32))
			_sg_append_u32le(&buf, transmute(u32)val)
		case f64:
			append(&buf, u8(Save_Tag.F64))
			_sg_append_u64le(&buf, transmute(u64)val)
		case bool:
			append(&buf, u8(Save_Tag.Bool))
			append(&buf, u8(1) if val else u8(0))
		case string:
			if len(val) > int(max(u32)) do return nil, false
			append(&buf, u8(Save_Tag.String))
			_sg_append_u32le(&buf, u32(len(val)))
			if len(val) > 0 {
				append(&buf, ..transmute([]u8)val)
			}
		case [3]f32:
			append(&buf, u8(Save_Tag.Vec3))
			for i in 0 ..< 3 {
				_sg_append_u32le(&buf, transmute(u32)val[i])
			}
		case [4]f32:
			append(&buf, u8(Save_Tag.Quat))
			for i in 0 ..< 4 {
				_sg_append_u32le(&buf, transmute(u32)val[i])
			}
		case []u8:
			if len(val) > int(max(u32)) do return nil, false
			append(&buf, u8(Save_Tag.Bytes))
			_sg_append_u32le(&buf, u32(len(val)))
			if len(val) > 0 {
				append(&buf, ..val)
			}
		}
	}

	payload := buf[SAVEGAME_HEADER_SIZE:]
	ver := sg.version != 0 ? sg.version : SAVEGAME_VERSION
	copy(buf[0:4], SAVEGAME_MAGIC)
	endian.unchecked_put_u32le(buf[4:8], ver)
	endian.unchecked_put_u32le(buf[8:12], 0)
	endian.unchecked_put_u32le(buf[12:16], u32(len(keys)))
	endian.unchecked_put_u64le(buf[16:24], catalog.pak_fnv1a64(payload))
	endian.unchecked_put_u64le(buf[24:32], u64(len(payload)))

	out := make([]u8, len(buf), allocator)
	copy(out, buf[:])
	return out, true
}

savegame_decode :: proc(data: []u8, allocator := context.allocator) -> (sg: Save_Game, ok: bool) {
	if len(data) < SAVEGAME_HEADER_SIZE do return {}, false
	if string(data[0:4]) != SAVEGAME_MAGIC do return {}, false

	ver := endian.unchecked_get_u32le(data[4:8])
	flags := endian.unchecked_get_u32le(data[8:12])
	if ver != SAVEGAME_VERSION || flags != 0 do return {}, false

	entry_count := endian.unchecked_get_u32le(data[12:16])
	stored_hash := endian.unchecked_get_u64le(data[16:24])
	payload_size := endian.unchecked_get_u64le(data[24:32])

	actual_payload := data[SAVEGAME_HEADER_SIZE:]
	if payload_size != u64(len(actual_payload)) do return {}, false
	if catalog.pak_fnv1a64(actual_payload) != stored_hash do return {}, false
	// Each record requires at least 2 bytes key length + 1 byte key + 1 byte tag = 4 bytes.
	if u64(entry_count) > payload_size / 4 do return {}, false

	out := Save_Game{
		version = ver,
		entries = make(map[string]Save_Value, int(entry_count), allocator),
		alloc   = allocator,
	}

	cursor := SAVEGAME_HEADER_SIZE
	for _ in 0 ..< entry_count {
		if len(data) - cursor < 2 {
			savegame_destroy(&out)
			return {}, false
		}
		klen := int(endian.unchecked_get_u16le(data[cursor : cursor+2]))
		cursor += 2
		if klen == 0 || len(data) - cursor < klen + 1 {
			savegame_destroy(&out)
			return {}, false
		}
		raw_key := string(data[cursor : cursor+klen])
		cursor += klen
		if raw_key in out.entries {
			savegame_destroy(&out)
			return {}, false
		}

		tag := Save_Tag(data[cursor])
		cursor += 1
		val: Save_Value

		switch tag {
		case .Int:
			if len(data) - cursor < 8 {
				savegame_destroy(&out)
				return {}, false
			}
			val = i64(endian.unchecked_get_u64le(data[cursor : cursor+8]))
			cursor += 8
		case .F32:
			if len(data) - cursor < 4 {
				savegame_destroy(&out)
				return {}, false
			}
			bits := endian.unchecked_get_u32le(data[cursor : cursor+4])
			val = transmute(f32)bits
			cursor += 4
		case .F64:
			if len(data) - cursor < 8 {
				savegame_destroy(&out)
				return {}, false
			}
			bits := endian.unchecked_get_u64le(data[cursor : cursor+8])
			val = transmute(f64)bits
			cursor += 8
		case .Bool:
			if len(data) - cursor < 1 {
				savegame_destroy(&out)
				return {}, false
			}
			b := data[cursor]
			if b != 0 && b != 1 {
				savegame_destroy(&out)
				return {}, false
			}
			val = (b == 1)
			cursor += 1
		case .String:
			if len(data) - cursor < 4 {
				savegame_destroy(&out)
				return {}, false
			}
			slen := int(endian.unchecked_get_u32le(data[cursor : cursor+4]))
			cursor += 4
			if slen < 0 || len(data) - cursor < slen {
				savegame_destroy(&out)
				return {}, false
			}
			val = strings.clone(string(data[cursor : cursor+slen]), allocator)
			cursor += slen
		case .Vec3:
			if len(data) - cursor < 12 {
				savegame_destroy(&out)
				return {}, false
			}
			v3: [3]f32
			for i in 0 ..< 3 {
				bits := endian.unchecked_get_u32le(data[cursor + i*4 : cursor + i*4 + 4])
				v3[i] = transmute(f32)bits
			}
			val = v3
			cursor += 12
		case .Quat:
			if len(data) - cursor < 16 {
				savegame_destroy(&out)
				return {}, false
			}
			v4: [4]f32
			for i in 0 ..< 4 {
				bits := endian.unchecked_get_u32le(data[cursor + i*4 : cursor + i*4 + 4])
				v4[i] = transmute(f32)bits
			}
			val = v4
			cursor += 16
		case .Bytes:
			if len(data) - cursor < 4 {
				savegame_destroy(&out)
				return {}, false
			}
			blen := int(endian.unchecked_get_u32le(data[cursor : cursor+4]))
			cursor += 4
			if blen < 0 || len(data) - cursor < blen {
				savegame_destroy(&out)
				return {}, false
			}
			val = slice.clone(data[cursor : cursor+blen], allocator)
			cursor += blen
		case:
			savegame_destroy(&out)
			return {}, false
		}

		k_clone := strings.clone(raw_key, allocator)
		out.entries[k_clone] = val
	}

	if cursor != len(data) {
		savegame_destroy(&out)
		return {}, false
	}
	return out, true
}

savegame_write_atomic :: proc(path: string, sg: ^Save_Game, allocator := context.allocator) -> bool {
	if path == "" || sg == nil do return false

	norm, was_alloc := strings.replace_all(path, "\\", "/", allocator)
	defer if was_alloc do delete(norm, allocator)
	catalog.ensure_parent_dirs(norm)

	blob, eok := savegame_encode(sg, allocator)
	if !eok do return false
	defer delete(blob, allocator)

	tmp_path := fmt.aprintf("%s.%d.tmp", path, os.get_pid(), allocator = allocator)
	defer delete(tmp_path, allocator)

	f, cerr := os.create(tmp_path)
	if cerr != nil do return false

	written := 0
	write_ok := true
	for written < len(blob) {
		n, werr := os.write(f, blob[written:])
		if werr != nil || n <= 0 {
			write_ok = false
			break
		}
		written += n
	}
	if write_ok {
		_ = os.sync(f)
	}
	if cl_err := os.close(f); cl_err != nil {
		write_ok = false
	}
	if !write_ok {
		_ = os.remove(tmp_path)
		return false
	}
	if rerr := os.rename(tmp_path, path); rerr != nil {
		_ = os.remove(tmp_path)
		return false
	}
	return true
}

savegame_read_file :: proc(path: string, allocator := context.allocator) -> (sg: Save_Game, ok: bool) {
	if path == "" do return {}, false
	blob, err := os.read_entire_file(path, allocator)
	if err != nil do return {}, false
	defer delete(blob, allocator)
	return savegame_decode(blob, allocator)
}
