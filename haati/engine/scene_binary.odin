package engine

// =============================================================================
// TAGGED BINARY SCENE FORMAT (`HTSCN001`) + EMBEDDED UTF-8 SUMMARY
// =============================================================================
// Replaces raw multi-hundred-KB pretty JSON `.scene` files on disk/in RAM with
// a deterministic, forward-compatible TLV binary container while keeping:
//   - Embedded human/AI-readable UTF-8 Summary block at `[32..32+summary_len)`
//     containing hierarchy preview + `deps:` unique cross-asset GUIDs so both
//     humans, agents (`tools/haati -- scene-info`), and `catalog.odin` work cleanly.
//   - Component `__type` UUIDs emitted once per component record so GUID count
//     invariants and unknown-component preservation stay 100% intact.
//   - Payload CRC32 verification + strict slice bounds checking against corruption.

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"

SCENE_BINARY_MAGIC          :: "HTSCN001"
SCENE_BINARY_HEADER_SIZE    :: 32
SCENE_BINARY_FORMAT_VERSION :: u32(1)
_SCENE_BIN_MAX_ITEMS        :: 4_000_000

@(private = "file")
_Bin_JSON_Tag :: enum u8 {
	Null    = 0,
	Boolean = 1,
	Integer = 2,
	Float   = 3,
	String  = 4,
	Array   = 5,
	Object  = 6,
}

@(private = "file")
_Bin_Writer :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
_bw_u8 :: proc(w: ^_Bin_Writer, v: u8) {
	append(&w.buf, v)
}

@(private = "file")
_bw_u32 :: proc(w: ^_Bin_Writer, v: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

@(private = "file")
_bw_i64 :: proc(w: ^_Bin_Writer, v: i64) {
	b: [8]u8
	endian.put_i64(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

@(private = "file")
_bw_f32 :: proc(w: ^_Bin_Writer, v: f32) {
	b: [4]u8
	endian.put_f32(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

@(private = "file")
_bw_f64 :: proc(w: ^_Bin_Writer, v: f64) {
	b: [8]u8
	endian.put_f64(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

@(private = "file")
_bw_guid :: proc(w: ^_Bin_Writer, g: Asset_GUID) {
	raw := ([16]u8)(g)
	append(&w.buf, ..raw[:])
}

@(private = "file")
_bw_str :: proc(w: ^_Bin_Writer, s: string) {
	_bw_u32(w, u32(len(s)))
	if len(s) > 0 {
		append(&w.buf, ..transmute([]u8)s)
	}
}

@(private = "file")
_bw_pptr :: proc(w: ^_Bin_Writer, p: PPtr) {
	_bw_i64(w, i64(p.local_id))
	_bw_guid(w, p.guid)
}

@(private = "file")
_bw_tlv_begin :: proc(w: ^_Bin_Writer, tag: u8) -> int {
	_bw_u8(w, tag)
	pos := len(w.buf)
	_bw_u32(w, 0)
	return pos
}

@(private = "file")
_bw_tlv_end :: proc(w: ^_Bin_Writer, len_pos: int) {
	plen := u32(len(w.buf) - (len_pos + 4))
	endian.put_u32(w.buf[len_pos:len_pos + 4], .Little, plen)
}

@(private = "file")
_bw_json_value :: proc(w: ^_Bin_Writer, v: json.Value) {
	if v == nil {
		_bw_u8(w, u8(_Bin_JSON_Tag.Null))
		return
	}
	switch val in v {
	case json.Null:
		_bw_u8(w, u8(_Bin_JSON_Tag.Null))
	case json.Boolean:
		_bw_u8(w, u8(_Bin_JSON_Tag.Boolean))
		_bw_u8(w, val ? 1 : 0)
	case json.Integer:
		_bw_u8(w, u8(_Bin_JSON_Tag.Integer))
		_bw_i64(w, i64(val))
	case json.Float:
		_bw_u8(w, u8(_Bin_JSON_Tag.Float))
		_bw_f64(w, f64(val))
	case json.String:
		_bw_u8(w, u8(_Bin_JSON_Tag.String))
		_bw_str(w, string(val))
	case json.Array:
		_bw_u8(w, u8(_Bin_JSON_Tag.Array))
		_bw_u32(w, u32(len(val)))
		for item in val {
			_bw_json_value(w, item)
		}
	case json.Object:
		_bw_u8(w, u8(_Bin_JSON_Tag.Object))
		_bw_u32(w, u32(len(val)))
		if len(val) > 0 {
			keys := make([dynamic]string, 0, len(val), context.temp_allocator)
			for k in val {
				append(&keys, k)
			}
			slice.sort(keys[:])
			for k in keys {
				_bw_str(w, k)
				_bw_json_value(w, val[k])
			}
		}
	}
}

@(private = "file")
_Bin_Reader :: struct {
	buf: []byte,
	pos: int,
}

@(private = "file")
_br_rem :: proc(r: ^_Bin_Reader) -> int {
	if r.pos < 0 || r.pos > len(r.buf) do return 0
	return len(r.buf) - r.pos
}

@(private = "file")
_br_u8 :: proc(r: ^_Bin_Reader) -> (u8, bool) {
	if _br_rem(r) < 1 do return 0, false
	v := r.buf[r.pos]
	r.pos += 1
	return v, true
}

@(private = "file")
_br_u32 :: proc(r: ^_Bin_Reader) -> (u32, bool) {
	if _br_rem(r) < 4 do return 0, false
	v, ok := endian.get_u32(r.buf[r.pos:r.pos + 4], .Little)
	if !ok do return 0, false
	r.pos += 4
	return v, true
}

@(private = "file")
_br_i64 :: proc(r: ^_Bin_Reader) -> (i64, bool) {
	if _br_rem(r) < 8 do return 0, false
	v, ok := endian.get_i64(r.buf[r.pos:r.pos + 8], .Little)
	if !ok do return 0, false
	r.pos += 8
	return v, true
}

@(private = "file")
_br_f32 :: proc(r: ^_Bin_Reader) -> (f32, bool) {
	if _br_rem(r) < 4 do return 0, false
	v, ok := endian.get_f32(r.buf[r.pos:r.pos + 4], .Little)
	if !ok do return 0, false
	r.pos += 4
	return v, true
}

@(private = "file")
_br_f64 :: proc(r: ^_Bin_Reader) -> (f64, bool) {
	if _br_rem(r) < 8 do return 0, false
	v, ok := endian.get_f64(r.buf[r.pos:r.pos + 8], .Little)
	if !ok do return 0, false
	r.pos += 8
	return v, true
}

@(private = "file")
_br_guid :: proc(r: ^_Bin_Reader) -> (Asset_GUID, bool) {
	if _br_rem(r) < 16 do return {}, false
	raw: [16]u8
	copy(raw[:], r.buf[r.pos:r.pos + 16])
	r.pos += 16
	return Asset_GUID(raw), true
}

@(private = "file")
_br_str :: proc(r: ^_Bin_Reader, allocator := context.allocator) -> (string, bool) {
	n, ok := _br_u32(r)
	if !ok do return "", false
	ni := int(n)
	if ni < 0 || ni > _br_rem(r) do return "", false
	if ni == 0 do return strings.clone("", allocator), true
	s := strings.clone(string(r.buf[r.pos:r.pos + ni]), allocator)
	r.pos += ni
	return s, true
}

@(private = "file")
_br_pptr :: proc(r: ^_Bin_Reader) -> (PPtr, bool) {
	lid, ok1 := _br_i64(r)
	if !ok1 do return {}, false
	g, ok2 := _br_guid(r)
	if !ok2 do return {}, false
	return PPtr{local_id = Local_ID(lid), guid = g}, true
}

@(private = "file")
_br_json_value :: proc(r: ^_Bin_Reader, allocator := context.allocator) -> (json.Value, bool) {
	tb, tok := _br_u8(r)
	if !tok do return nil, false
	switch _Bin_JSON_Tag(tb) {
	case .Null:
		return json.Null{}, true
	case .Boolean:
		b, bok := _br_u8(r)
		if !bok do return nil, false
		return json.Boolean(b != 0), true
	case .Integer:
		iv, iok := _br_i64(r)
		if !iok do return nil, false
		return json.Integer(iv), true
	case .Float:
		fv, fok := _br_f64(r)
		if !fok do return nil, false
		return json.Float(fv), true
	case .String:
		s, sok := _br_str(r, allocator)
		if !sok do return nil, false
		return json.String(s), true
	case .Array:
		cnt, cok := _br_u32(r)
		if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) > _br_rem(r) do return nil, false
		arr := make(json.Array, 0, int(cnt), allocator)
		for _ in 0 ..< cnt {
			elem, eok := _br_json_value(r, allocator)
			if !eok {
				for it in arr {
					json.destroy_value(it, allocator)
				}
				delete(arr)
				return nil, false
			}
			append(&arr, elem)
		}
		return arr, true
	case .Object:
		cnt, cok := _br_u32(r)
		if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) * 5 > _br_rem(r) do return nil, false
		obj := make(json.Object, int(cnt), allocator)
		for _ in 0 ..< cnt {
			k, kok := _br_str(r, allocator)
			if !kok {
				for ok_k, ok_v in obj {
					delete(ok_k, allocator)
					json.destroy_value(ok_v, allocator)
				}
				delete(obj)
				return nil, false
			}
			val, vok := _br_json_value(r, allocator)
			if !vok {
				delete(k, allocator)
				for ok_k, ok_v in obj {
					delete(ok_k, allocator)
					json.destroy_value(ok_v, allocator)
				}
				delete(obj)
				return nil, false
			}
			obj[k] = val
		}
		return obj, true
	}
	return nil, false
}

// Fast prefix check for HTSCN001 binary `.scene` buffers.
scene_bytes_is_binary :: proc(data: []byte) -> bool {
	return len(data) >= len(SCENE_BINARY_MAGIC) && string(data[:len(SCENE_BINARY_MAGIC)]) == SCENE_BINARY_MAGIC
}

@(private = "file")
_component_short_name_no_log :: proc(v: json.Value) -> string {
	obj, is_obj := v.(json.Object)
	if !is_obj do return "Component"
	tv, has_type := obj[EXT_TYPE_KEY]
	if !has_type do return "Component"
	gs, is_str := tv.(json.String)
	if !is_str do return "Component"
	guid, gerr := uuid.read(string(gs))
	if gerr != nil do return "UnknownComponent"
	tid, tok := get_typeid_by_guid_ok(guid)
	if !tok do return "UnknownComponent"
	full := fmt.tprintf("%v", tid)
	if dot := strings.last_index_byte(full, '.'); dot >= 0 && dot + 1 < len(full) {
		return full[dot + 1:]
	}
	return full
}

@(private = "file")
_build_scene_summary_text :: proc(sf: ^SceneFile, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(0, 1024, allocator)
	fmt.sbprintln(&sb, "# HTSCN001 Scene Summary")
	fmt.sbprintfln(&sb, "schema_version: %d  root_local_id: %d", sf.schema_version, sf.root)
	fmt.sbprintfln(
		&sb,
		"counts: transforms=%d components=%d nested_scenes=%d breadcrumbs=%d",
		len(sf.transforms),
		len(sf.components),
		len(sf.nested_scenes),
		len(sf.breadcrumbs),
	)

	// Map component local_id -> short struct name (without echoing component GUIDs)
	comp_names := make(map[Local_ID]string, len(sf.components), context.temp_allocator)
	for cv in sf.components {
		if obj, is_o := cv.(json.Object); is_o {
			if lid, lok := _json_local_id_of(obj); lok && lid != 0 {
				comp_names[lid] = _component_short_name_no_log(cv)
			}
		}
	}

	tr_by_lid := make(map[Local_ID]^Transform, len(sf.transforms), context.temp_allocator)
	for &tr in sf.transforms {
		tr_by_lid[tr.local_id] = &tr
	}

	if len(sf.transforms) > 0 {
		strings.write_string(&sb, "hierarchy:\n")
		visited := make(map[Local_ID]bool, len(sf.transforms), context.temp_allocator)
		emitted := 0
		MAX_PREVIEW :: 64

		write_node :: proc(
			sb: ^strings.Builder,
			tr_by_lid: ^map[Local_ID]^Transform,
			comp_names: ^map[Local_ID]string,
			visited: ^map[Local_ID]bool,
			emitted: ^int,
			lid: Local_ID,
			depth: int,
		) {
			if emitted^ >= MAX_PREVIEW || lid == 0 || visited^[lid] do return
			tr, ok := tr_by_lid^[lid]
			if !ok || tr == nil do return
			visited^[lid] = true
			emitted^ += 1

			for _ in 0 ..< min(depth, 10) {
				strings.write_string(sb, "  ")
			}
			nm := tr.name != "" ? tr.name : "(unnamed)"
			fmt.sbprintf(sb, "  - %q (lid=%d)", nm, tr.local_id)
			if len(tr.components) > 0 {
				strings.write_string(sb, " [")
				for c, ci in tr.components {
					if ci > 0 do strings.write_string(sb, ", ")
					cname, cok := comp_names^[c.local_id]
					strings.write_string(sb, cok ? cname : "Component")
				}
				strings.write_string(sb, "]")
			}
			strings.write_byte(sb, '\n')
			for ch in tr.children {
				write_node(sb, tr_by_lid, comp_names, visited, emitted, ch.pptr.local_id, depth + 1)
			}
		}

		if sf.root != 0 {
			write_node(&sb, &tr_by_lid, &comp_names, &visited, &emitted, sf.root, 0)
		}
		for &tr in sf.transforms {
			if emitted >= MAX_PREVIEW do break
			if !visited[tr.local_id] {
				write_node(&sb, &tr_by_lid, &comp_names, &visited, &emitted, tr.local_id, 0)
			}
		}
		if len(sf.transforms) > emitted {
			fmt.sbprintfln(&sb, "  ... (%d more transform(s))", len(sf.transforms) - emitted)
		}
	}

	// Emit unique non-empty cross-asset GUIDs under `deps:` so catalog.odin GUID harvesting stays complete.
	deps_set := make(map[Asset_GUID]bool, 8, context.temp_allocator)
	add_dep := #force_inline proc(set: ^map[Asset_GUID]bool, g: Asset_GUID) {
		if !asset_guid_is_empty(g) do set^[g] = true
	}
	for &tr in sf.transforms {
		add_dep(&deps_set, tr.parent.pptr.guid)
		for ch in tr.children {
			add_dep(&deps_set, ch.pptr.guid)
		}
	}
	for &bc in sf.breadcrumbs {
		add_dep(&deps_set, bc.scene_source.guid)
	}
	for &ns in sf.nested_scenes {
		add_dep(&deps_set, ns.source_prefab)
		for &ov in ns.overrides do add_dep(&deps_set, ov.target.guid)
		for &rc in ns.removed_components do add_dep(&deps_set, rc.target.guid)
		for &ac in ns.added_components do add_dep(&deps_set, ac.owner.guid)
		for &ro in ns.removed_objects do add_dep(&deps_set, ro.target.guid)
		for &ao in ns.added_objects do add_dep(&deps_set, ao.parent.guid)
	}
	if len(deps_set) > 0 {
		dep_strs := make([dynamic]string, 0, len(deps_set), context.temp_allocator)
		for g in deps_set {
			append(&dep_strs, uuid.to_string(uuid.Identifier(g), context.temp_allocator))
		}
		slice.sort(dep_strs[:])
		strings.write_string(&sb, "deps:")
		for ds in dep_strs {
			strings.write_byte(&sb, ' ')
			strings.write_string(&sb, ds)
		}
		strings.write_byte(&sb, '\n')
	}

	return strings.to_string(sb)
}

// Encodes a SceneFile into deterministic HTSCN001 tagged binary with embedded UTF-8 summary and payload CRC32.
scene_binary_encode :: proc(sf: ^SceneFile, allocator := context.allocator) -> ([]byte, bool) {
	if sf == nil do return nil, false

	summary := _build_scene_summary_text(sf, context.temp_allocator)

	pw := _Bin_Writer{
		buf = make([dynamic]u8, 0, 1024, context.temp_allocator),
	}

	_bw_i64(&pw, i64(sf.root))

	// Section 1: Transforms
	_bw_u32(&pw, u32(len(sf.transforms)))
	for &tr in sf.transforms {
		p1 := _bw_tlv_begin(&pw, 1); _bw_i64(&pw, i64(tr.local_id)); _bw_tlv_end(&pw, p1)
		p2 := _bw_tlv_begin(&pw, 2); _bw_str(&pw, tr.name); _bw_tlv_end(&pw, p2)
		p3 := _bw_tlv_begin(&pw, 3); _bw_u8(&pw, tr.is_active ? 1 : 0); _bw_tlv_end(&pw, p3)
		p4 := _bw_tlv_begin(&pw, 4)
		_bw_f32(&pw, tr.position.x); _bw_f32(&pw, tr.position.y); _bw_f32(&pw, tr.position.z)
		_bw_tlv_end(&pw, p4)
		p5 := _bw_tlv_begin(&pw, 5)
		_bw_f32(&pw, tr.rotation.x); _bw_f32(&pw, tr.rotation.y); _bw_f32(&pw, tr.rotation.z); _bw_f32(&pw, tr.rotation.w)
		_bw_tlv_end(&pw, p5)
		p6 := _bw_tlv_begin(&pw, 6)
		_bw_f32(&pw, tr.scale.x); _bw_f32(&pw, tr.scale.y); _bw_f32(&pw, tr.scale.z)
		_bw_tlv_end(&pw, p6)
		p7 := _bw_tlv_begin(&pw, 7); _bw_u32(&pw, tr.render_layer); _bw_tlv_end(&pw, p7)
		p8 := _bw_tlv_begin(&pw, 8); _bw_pptr(&pw, tr.parent.pptr); _bw_tlv_end(&pw, p8)
		p9 := _bw_tlv_begin(&pw, 9)
		_bw_u32(&pw, u32(len(tr.children)))
		for ch in tr.children {
			_bw_pptr(&pw, ch.pptr)
		}
		_bw_tlv_end(&pw, p9)
		p10 := _bw_tlv_begin(&pw, 10)
		_bw_u32(&pw, u32(len(tr.components)))
		for comp in tr.components {
			_bw_i64(&pw, i64(comp.local_id))
		}
		_bw_tlv_end(&pw, p10)
		_bw_u8(&pw, 0)
	}

	// Section 2: NestedScenes
	_bw_u32(&pw, u32(len(sf.nested_scenes)))
	for &ns in sf.nested_scenes {
		p1 := _bw_tlv_begin(&pw, 1); _bw_i64(&pw, i64(ns.local_id)); _bw_tlv_end(&pw, p1)
		p2 := _bw_tlv_begin(&pw, 2); _bw_i64(&pw, i64(ns.local_id_in_parent)); _bw_tlv_end(&pw, p2)
		p3 := _bw_tlv_begin(&pw, 3); _bw_guid(&pw, ns.source_prefab); _bw_tlv_end(&pw, p3)
		p4 := _bw_tlv_begin(&pw, 4); _bw_i64(&pw, i64(ns.transform_parent)); _bw_tlv_end(&pw, p4)
		p5 := _bw_tlv_begin(&pw, 5); _bw_i64(&pw, i64(ns.host_breadcrumb_id)); _bw_tlv_end(&pw, p5)
		p6 := _bw_tlv_begin(&pw, 6); _bw_i64(&pw, i64(ns.sibling_index)); _bw_tlv_end(&pw, p6)
		p7 := _bw_tlv_begin(&pw, 7)
		_bw_u32(&pw, u32(len(ns.overrides)))
		for &ov in ns.overrides {
			_bw_pptr(&pw, ov.target)
			_bw_str(&pw, ov.property_path)
			_bw_json_value(&pw, ov.value)
		}
		_bw_tlv_end(&pw, p7)
		p8 := _bw_tlv_begin(&pw, 8)
		_bw_u32(&pw, u32(len(ns.removed_components)))
		for rc in ns.removed_components {
			_bw_pptr(&pw, rc.target)
		}
		_bw_tlv_end(&pw, p8)
		p9 := _bw_tlv_begin(&pw, 9)
		_bw_u32(&pw, u32(len(ns.added_components)))
		for &ac in ns.added_components {
			_bw_pptr(&pw, ac.owner)
			_bw_i64(&pw, i64(ac.local_id))
			_bw_str(&pw, ac.type_guid)
			_bw_str(&pw, ac.json)
		}
		_bw_tlv_end(&pw, p9)
		p10 := _bw_tlv_begin(&pw, 10)
		_bw_u32(&pw, u32(len(ns.removed_objects)))
		for ro in ns.removed_objects {
			_bw_pptr(&pw, ro.target)
		}
		_bw_tlv_end(&pw, p10)
		p11 := _bw_tlv_begin(&pw, 11)
		_bw_u32(&pw, u32(len(ns.added_objects)))
		for &ao in ns.added_objects {
			_bw_pptr(&pw, ao.parent)
			_bw_i64(&pw, i64(ao.local_id))
			_bw_str(&pw, ao.json)
		}
		_bw_tlv_end(&pw, p11)
		_bw_u8(&pw, 0)
	}

	// Section 3: Breadcrumbs
	_bw_u32(&pw, u32(len(sf.breadcrumbs)))
	for &bc in sf.breadcrumbs {
		p1 := _bw_tlv_begin(&pw, 1); _bw_i64(&pw, i64(bc.local_id)); _bw_tlv_end(&pw, p1)
		p2 := _bw_tlv_begin(&pw, 2); _bw_pptr(&pw, bc.scene_source); _bw_tlv_end(&pw, p2)
		p3 := _bw_tlv_begin(&pw, 3); _bw_i64(&pw, i64(bc.scene_instance)); _bw_tlv_end(&pw, p3)
		_bw_u8(&pw, 0)
	}

	// Section 4: Components (json.Value records with sorted object keys)
	_bw_u32(&pw, u32(len(sf.components)))
	for comp_val in sf.components {
		_bw_json_value(&pw, comp_val)
	}

	sum_off := u32(SCENE_BINARY_HEADER_SIZE)
	sum_len := u32(len(summary))
	payload := pw.buf[:]
	crc := hash.crc32(payload)

	total := int(sum_off) + int(sum_len) + len(payload)
	out := make([]byte, total, allocator)
	copy(out[:8], SCENE_BINARY_MAGIC)
	endian.put_u32(out[8:12], .Little, SCENE_BINARY_FORMAT_VERSION)
	endian.put_u32(out[12:16], .Little, u32(max(sf.schema_version, 0)))
	endian.put_u32(out[16:20], .Little, u32(0))
	endian.put_u32(out[20:24], .Little, sum_off)
	endian.put_u32(out[24:28], .Little, sum_len)
	endian.put_u32(out[28:32], .Little, crc)
	if sum_len > 0 {
		copy(out[int(sum_off):int(sum_off) + int(sum_len)], summary)
	}
	if len(payload) > 0 {
		copy(out[int(sum_off) + int(sum_len):], payload)
	}
	return out, true
}

@(private = "file")
_scene_bin_parse_header :: proc(data: []byte) -> (schema_ver: int, sum_off: int, sum_len: int, payload_off: int, payload_crc: u32, ok: bool) {
	if !scene_bytes_is_binary(data) || len(data) < SCENE_BINARY_HEADER_SIZE do return
	fmt_ver, ok0 := endian.get_u32(data[8:12], .Little)
	sch_ver, ok1 := endian.get_u32(data[12:16], .Little)
	soff, ok2    := endian.get_u32(data[20:24], .Little)
	slen, ok3    := endian.get_u32(data[24:28], .Little)
	crc, ok4     := endian.get_u32(data[28:32], .Little)
	if !ok0 || !ok1 || !ok2 || !ok3 || !ok4 do return
	if fmt_ver != SCENE_BINARY_FORMAT_VERSION do return
	if int(soff) < SCENE_BINARY_HEADER_SIZE do return
	end_sum := u64(soff) + u64(slen)
	if end_sum > u64(len(data)) do return
	poff := int(end_sum)
	if hash.crc32(data[poff:]) != crc do return
	return int(sch_ver), int(soff), int(slen), poff, crc, true
}

// Decodes HTSCN001 bytes into `sf` on `allocator`. Validates magic, bounds, and payload CRC32.
// On failure, destroys any partial allocations and zeroes `sf`.
scene_binary_decode :: proc(data: []byte, sf: ^SceneFile, allocator := context.allocator) -> bool {
	if sf == nil do return false
	sf^ = {}

	schema_ver, _, _, payload_off, _, hok := _scene_bin_parse_header(data)
	if !hok do return false

	prev := context.allocator
	context.allocator = allocator
	defer context.allocator = prev

	fail_cleanup :: proc(sf: ^SceneFile) -> bool {
		scene_file_destroy(sf)
		sf^ = {}
		return false
	}

	sf.schema_version = schema_ver
	r := _Bin_Reader{buf = data[payload_off:], pos = 0}

	root_lid, rok := _br_i64(&r)
	if !rok do return fail_cleanup(sf)
	sf.root = Local_ID(root_lid)

	// Section 1: Transforms
	tr_cnt, tcok := _br_u32(&r)
	if !tcok || tr_cnt > _SCENE_BIN_MAX_ITEMS || int(tr_cnt) > _br_rem(&r) do return fail_cleanup(sf)
	sf.transforms = make([dynamic]Transform, 0, int(tr_cnt), allocator)
	for _ in 0 ..< tr_cnt {
		tr: Transform
		for {
			tag, tok := _br_u8(&r)
			if !tok do return fail_cleanup(sf)
			if tag == 0 do break
			flen, lok := _br_u32(&r)
			if !lok || int(flen) > _br_rem(&r) do return fail_cleanup(sf)
			sub := _Bin_Reader{buf = r.buf[r.pos:r.pos + int(flen)], pos = 0}
			r.pos += int(flen)

			switch tag {
			case 1:
				v, ok := _br_i64(&sub)
				if !ok do return fail_cleanup(sf)
				tr.local_id = Local_ID(v)
			case 2:
				if tr.name != "" do delete(tr.name, allocator)
				s, ok := _br_str(&sub, allocator)
				if !ok do return fail_cleanup(sf)
				tr.name = s
			case 3:
				b, ok := _br_u8(&sub)
				if !ok do return fail_cleanup(sf)
				tr.is_active = b != 0
			case 4:
				x, ok1 := _br_f32(&sub)
				y, ok2 := _br_f32(&sub)
				z, ok3 := _br_f32(&sub)
				if !ok1 || !ok2 || !ok3 do return fail_cleanup(sf)
				tr.position = {x, y, z}
			case 5:
				x, ok1 := _br_f32(&sub)
				y, ok2 := _br_f32(&sub)
				z, ok3 := _br_f32(&sub)
				w, ok4 := _br_f32(&sub)
				if !ok1 || !ok2 || !ok3 || !ok4 do return fail_cleanup(sf)
				tr.rotation = {x, y, z, w}
			case 6:
				x, ok1 := _br_f32(&sub)
				y, ok2 := _br_f32(&sub)
				z, ok3 := _br_f32(&sub)
				if !ok1 || !ok2 || !ok3 do return fail_cleanup(sf)
				tr.scale = {x, y, z}
			case 7:
				rl, ok := _br_u32(&sub)
				if !ok do return fail_cleanup(sf)
				tr.render_layer = rl
			case 8:
				p, ok := _br_pptr(&sub)
				if !ok do return fail_cleanup(sf)
				tr.parent = Ref{pptr = p}
			case 9:
				cn, cok := _br_u32(&sub)
				if !cok || cn > _SCENE_BIN_MAX_ITEMS || int(cn) * 24 > _br_rem(&sub) do return fail_cleanup(sf)
				tr.children = make([dynamic]Ref, 0, int(cn), allocator)
				for _ in 0 ..< cn {
					p, ok := _br_pptr(&sub)
					if !ok {
						delete(tr.children)
						tr.children = nil
						return fail_cleanup(sf)
					}
					append(&tr.children, Ref{pptr = p})
				}
			case 10:
				cn, cok := _br_u32(&sub)
				if !cok || cn > _SCENE_BIN_MAX_ITEMS || int(cn) * 8 > _br_rem(&sub) do return fail_cleanup(sf)
				tr.components = make([dynamic]Owned, 0, int(cn), allocator)
				for _ in 0 ..< cn {
					cid, ok := _br_i64(&sub)
					if !ok {
						delete(tr.components)
						tr.components = nil
						return fail_cleanup(sf)
					}
					append(&tr.components, Owned{local_id = Local_ID(cid)})
				}
			}
		}
		append(&sf.transforms, tr)
	}

	// Section 2: NestedScenes
	ns_cnt, ncok := _br_u32(&r)
	if !ncok || ns_cnt > _SCENE_BIN_MAX_ITEMS || int(ns_cnt) > _br_rem(&r) do return fail_cleanup(sf)
	sf.nested_scenes = make([dynamic]NestedScene, 0, int(ns_cnt), allocator)
	for _ in 0 ..< ns_cnt {
		ns: NestedScene
		for {
			tag, tok := _br_u8(&r)
			if !tok {
				nested_scene_free_owned(&ns)
				return fail_cleanup(sf)
			}
			if tag == 0 do break
			flen, lok := _br_u32(&r)
			if !lok || int(flen) > _br_rem(&r) {
				nested_scene_free_owned(&ns)
				return fail_cleanup(sf)
			}
			sub := _Bin_Reader{buf = r.buf[r.pos:r.pos + int(flen)], pos = 0}
			r.pos += int(flen)

			switch tag {
			case 1:
				v, ok := _br_i64(&sub)
				if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
				ns.local_id = Local_ID(v)
			case 2:
				v, ok := _br_i64(&sub)
				if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
				ns.local_id_in_parent = Local_ID(v)
			case 3:
				g, ok := _br_guid(&sub)
				if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
				ns.source_prefab = g
			case 4:
				v, ok := _br_i64(&sub)
				if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
				ns.transform_parent = Local_ID(v)
			case 5:
				v, ok := _br_i64(&sub)
				if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
				ns.host_breadcrumb_id = Local_ID(v)
			case 6:
				v, ok := _br_i64(&sub)
				if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
				ns.sibling_index = int(v)
			case 7:
				cnt, cok := _br_u32(&sub)
				if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) * 29 > _br_rem(&sub) {
					nested_scene_free_owned(&ns); return fail_cleanup(sf)
				}
				ns.overrides = make([dynamic]Override, 0, int(cnt), allocator)
				for _ in 0 ..< cnt {
					tgt, ok1 := _br_pptr(&sub)
					if !ok1 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					pp, ok2 := _br_str(&sub, allocator)
					if !ok2 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					val, ok3 := _br_json_value(&sub, allocator)
					if !ok3 {
						delete(pp, allocator)
						nested_scene_free_owned(&ns)
						return fail_cleanup(sf)
					}
					append(&ns.overrides, Override{target = tgt, property_path = pp, value = val})
				}
			case 8:
				cnt, cok := _br_u32(&sub)
				if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) * 24 > _br_rem(&sub) {
					nested_scene_free_owned(&ns); return fail_cleanup(sf)
				}
				ns.removed_components = make([dynamic]Removed_Component, 0, int(cnt), allocator)
				for _ in 0 ..< cnt {
					tgt, ok := _br_pptr(&sub)
					if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					append(&ns.removed_components, Removed_Component{target = tgt})
				}
			case 9:
				cnt, cok := _br_u32(&sub)
				if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) * 40 > _br_rem(&sub) {
					nested_scene_free_owned(&ns); return fail_cleanup(sf)
				}
				ns.added_components = make([dynamic]Added_Component, 0, int(cnt), allocator)
				for _ in 0 ..< cnt {
					own, ok1 := _br_pptr(&sub)
					if !ok1 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					lid, ok2 := _br_i64(&sub)
					if !ok2 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					tg, ok3 := _br_str(&sub, allocator)
					if !ok3 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					js, ok4 := _br_str(&sub, allocator)
					if !ok4 {
						delete(tg, allocator)
						nested_scene_free_owned(&ns)
						return fail_cleanup(sf)
					}
					append(&ns.added_components, Added_Component{
						owner     = own,
						local_id  = Local_ID(lid),
						type_guid = tg,
						json      = js,
					})
				}
			case 10:
				cnt, cok := _br_u32(&sub)
				if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) * 24 > _br_rem(&sub) {
					nested_scene_free_owned(&ns); return fail_cleanup(sf)
				}
				ns.removed_objects = make([dynamic]Removed_Object, 0, int(cnt), allocator)
				for _ in 0 ..< cnt {
					tgt, ok := _br_pptr(&sub)
					if !ok { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					append(&ns.removed_objects, Removed_Object{target = tgt})
				}
			case 11:
				cnt, cok := _br_u32(&sub)
				if !cok || cnt > _SCENE_BIN_MAX_ITEMS || int(cnt) * 36 > _br_rem(&sub) {
					nested_scene_free_owned(&ns); return fail_cleanup(sf)
				}
				ns.added_objects = make([dynamic]Added_Object, 0, int(cnt), allocator)
				for _ in 0 ..< cnt {
					par, ok1 := _br_pptr(&sub)
					if !ok1 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					lid, ok2 := _br_i64(&sub)
					if !ok2 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					js, ok3 := _br_str(&sub, allocator)
					if !ok3 { nested_scene_free_owned(&ns); return fail_cleanup(sf) }
					append(&ns.added_objects, Added_Object{
						parent   = par,
						local_id = Local_ID(lid),
						json     = js,
					})
				}
			}
		}
		append(&sf.nested_scenes, ns)
	}

	// Section 3: Breadcrumbs
	bc_cnt, bcok := _br_u32(&r)
	if !bcok || bc_cnt > _SCENE_BIN_MAX_ITEMS || int(bc_cnt) > _br_rem(&r) do return fail_cleanup(sf)
	sf.breadcrumbs = make([dynamic]Breadcrumb, 0, int(bc_cnt), allocator)
	for _ in 0 ..< bc_cnt {
		bc: Breadcrumb
		for {
			tag, tok := _br_u8(&r)
			if !tok do return fail_cleanup(sf)
			if tag == 0 do break
			flen, lok := _br_u32(&r)
			if !lok || int(flen) > _br_rem(&r) do return fail_cleanup(sf)
			sub := _Bin_Reader{buf = r.buf[r.pos:r.pos + int(flen)], pos = 0}
			r.pos += int(flen)
			switch tag {
			case 1:
				v, ok := _br_i64(&sub)
				if !ok do return fail_cleanup(sf)
				bc.local_id = Local_ID(v)
			case 2:
				p, ok := _br_pptr(&sub)
				if !ok do return fail_cleanup(sf)
				bc.scene_source = p
			case 3:
				v, ok := _br_i64(&sub)
				if !ok do return fail_cleanup(sf)
				bc.scene_instance = Local_ID(v)
			}
		}
		append(&sf.breadcrumbs, bc)
	}

	// Section 4: Components
	comp_cnt, ccok := _br_u32(&r)
	if !ccok || comp_cnt > _SCENE_BIN_MAX_ITEMS || int(comp_cnt) > _br_rem(&r) do return fail_cleanup(sf)
	sf.components = make([dynamic]json.Value, 0, int(comp_cnt), allocator)
	for _ in 0 ..< comp_cnt {
		cv, vok := _br_json_value(&r, allocator)
		if !vok do return fail_cleanup(sf)
		append(&sf.components, cv)
	}

	return true
}

// Reads the embedded UTF-8 summary directly in O(1) for valid HTSCN001 binaries,
// or synthesizes an identical summary for legacy JSON `.scene` inputs.
scene_extract_summary :: proc(data: []byte, allocator := context.allocator) -> (string, bool) {
	if scene_bytes_is_binary(data) {
		_, soff, slen, _, _, hok := _scene_bin_parse_header(data)
		if !hok do return "", false
		return strings.clone(string(data[soff:soff + slen]), allocator), true
	}

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	sf: SceneFile
	err := scene_file_unmarshal(data, &sf)
	context.allocator = prev
	if err != nil do return "", false
	defer {
		prev2 := context.allocator
		context.allocator = runtime.default_allocator()
		scene_file_destroy(&sf)
		context.allocator = prev2
	}
	return _build_scene_summary_text(&sf, allocator), true
}

// Converts HTSCN001 binary scene bytes back into canonical JSON bytes on demand for
// tools/diffs that inspect raw JSON object trees; clones JSON inputs untouched.
scene_bytes_to_json_if_binary :: proc(data: []byte, allocator := context.allocator) -> ([]byte, bool) {
	if !scene_bytes_is_binary(data) {
		out := make([]byte, len(data), allocator)
		copy(out, data)
		return out, true
	}

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	sf: SceneFile
	dec_ok := scene_binary_decode(data, &sf, runtime.default_allocator())
	if !dec_ok {
		context.allocator = prev
		return nil, false
	}
	opts := json.Marshal_Options{
		spec             = .JSON,
		pretty           = true,
		use_spaces       = true,
		spaces           = 2,
		sort_maps_by_key = true,
	}
	raw, merr := json.marshal(sf, opts, context.temp_allocator)
	scene_file_destroy(&sf)
	context.allocator = prev
	if merr != nil do return nil, false
	return json_canonicalize_floats(raw, allocator), true
}
