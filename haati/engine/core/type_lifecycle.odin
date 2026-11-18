package core

// Per-type lifecycle procs (docs/Components.md, "Lifecycle procs"): a
// @(typ_guid) type declares them by name in its own file, and the generated
// registration (type_guid_gen) puts them in these tables by TypeKey.
//
// - reset_T:       cleanup_T first when the type has one, then the defaults,
//                  so a reset on a live value frees what it owned. A new
//                  instance gets it, a value loaded from data gets it under
//                  the data (unmarshal_over_reset), and the inspector's Reset
//                  runs it on a live value.
// - cleanup_T:     frees what a value owns and leaves it zeroed. Runs when a
//                  component is destroyed, when a union variant goes, when a
//                  tween node is destroyed.
// - on_validate_T: after an inspector edit and after a value is loaded from
//                  data, to keep the value consistent (a zero that means
//                  "default" becomes the default here).
//
// on_destroy_T stays a component's (engine/components.odin): it is about
// leaving a world, not about the value.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

Value_Unmarshaler :: #type proc(v: json.Value, dst: any, allocator: runtime.Allocator) -> json.Unmarshal_Error

@(private = "file")
_value_unmarshalers: map[typeid]Value_Unmarshaler

register_value_unmarshaler :: proc(tid: typeid, fn: Value_Unmarshaler) {
	if tid == nil || fn == nil do return
	if _value_unmarshalers == nil {
		_value_unmarshalers = make(map[typeid]Value_Unmarshaler, runtime.default_allocator())
	}
	_value_unmarshalers[tid] = fn
}

type_reset_procs:       [TypeKey]proc(rawptr)
type_cleanup_procs:     [TypeKey]proc(rawptr)
type_on_validate_procs: [TypeKey]proc(rawptr)

type_register_reset :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_reset_procs[key] = fn
}

type_register_cleanup :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_cleanup_procs[key] = fn
}

type_register_on_validate :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_on_validate_procs[key] = fn
}

type_has_reset :: proc(key: TypeKey) -> bool {
	return type_reset_procs[key] != nil
}

type_has_cleanup :: proc(key: TypeKey) -> bool {
	return type_cleanup_procs[key] != nil
}

type_reset :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_reset_procs[key]; fn != nil do fn(ptr)
}

type_cleanup :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_cleanup_procs[key]; fn != nil do fn(ptr)
}

type_cleanup_by_typeid :: proc(tid: typeid, ptr: rawptr) {
	if key, ok := get_type_key_by_typeid(tid); ok do type_cleanup(key, ptr)
}

type_on_validate :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_on_validate_procs[key]; fn != nil do fn(ptr)
}

type_on_validate_by_typeid :: proc(tid: typeid, ptr: rawptr) {
	if key, ok := get_type_key_by_typeid(tid); ok do type_on_validate(key, ptr)
}

// The Serialization project setting (docs/Components.md, "Missing fields and
// reset defaults"). It lives in core because every typed load reads it, and
// core cannot import the engine.
Serialization_Settings :: struct {
	// On: a top-level field a scene, prefab, asset, import settings or union
	// variant file does not name loads as the type's reset_T default. The cost
	// is a reset and a cleanup on a scratch copy for every loaded value whose
	// type has a reset_T. Off: a field missing from a file loads as zero, so a
	// field added to a type after a file was saved must tolerate zero or be
	// migrated by hand.
	load_defaults_for_missing_fields: bool `decor:help(text="On: a field a file does not name loads as the type's reset default, not zero. Costs a reset and a cleanup on a scratch copy per loaded component or asset. Off: a missing field loads as zero.")`,
}

@(project_settings={name="Serialization"})
serialization_settings := Serialization_Settings{load_defaults_for_missing_fields = true}

// Unmarshals `data`, one JSON object, over the zeroed T at `ptr` (`tid` is T).
// A top-level field the object names comes from the data. Every other field
// keeps T's reset default, so a field added to T after the data was saved
// loads as its reset value, not zero. Every load of a typed value from data
// goes through here or through the two variants below: scene and prefab
// components, assets, import settings, union variants. A T with no reset_T,
// or serialization_settings.load_defaults_for_missing_fields off, gets a plain
// unmarshal.
//
// This variant starts from bytes only, so it parses `data` once to learn which
// keys it names. A caller that already holds the parsed object passes it to
// unmarshal_over_reset_object, and a caller that holds a json.Value passes it
// to unmarshal_value_over_reset.
unmarshal_over_reset :: proc(
	data: []byte,
	ptr: rawptr,
	tid: typeid,
	spec := json.DEFAULT_SPECIFICATION,
	allocator := context.allocator,
) -> json.Unmarshal_Error {
	if !_needs_reset_defaults(tid) do return _unmarshal_plain(data, ptr, tid, spec, allocator)
	root, perr := json.parse(data, spec, true, context.temp_allocator)
	obj, is_obj := root.(json.Object)
	if perr != nil || !is_obj {
		// Not an object: the unmarshal reports what is wrong with it.
		return _unmarshal_plain(data, ptr, tid, spec, allocator)
	}
	return unmarshal_over_reset_object(data, obj, ptr, tid, spec, allocator)
}

// unmarshal_over_reset for a caller that holds `obj`, the parsed form of
// `data`: the key set comes from `obj`, so `data` is not parsed a second time.
//
// reset_T runs on a scratch T, never on `ptr`: a reset may allocate, and the
// unmarshal would allocate over it. The fields the data lacks then move from
// the scratch into `ptr`, and cleanup_T frees what the scratch still holds
// (the defaults of the fields the data supplied). The scratch and the moved
// defaults are on `allocator`, the same as the unmarshaled fields.
unmarshal_over_reset_object :: proc(
	data: []byte,
	obj: json.Object,
	ptr: rawptr,
	tid: typeid,
	spec := json.DEFAULT_SPECIFICATION,
	allocator := context.allocator,
) -> json.Unmarshal_Error {
	if !_needs_reset_defaults(tid) do return _unmarshal_plain(data, ptr, tid, spec, allocator)
	key, _ := get_type_key_by_typeid(tid)
	info := runtime.type_info_base(type_info_of(tid)).variant.(runtime.Type_Info_Struct)

	context.allocator = allocator
	ti := type_info_of(tid)
	scratch, aerr := mem.alloc(ti.size, ti.align)
	fmt.assertf(aerr == nil, "out of memory for a %v scratch", tid)
	defer mem.free(scratch)
	type_reset(key, scratch)
	defer type_cleanup(key, scratch)

	if err := _unmarshal_plain(data, ptr, tid, spec, allocator); err != nil do return err
	_take_absent_fields(ptr, scratch, info, obj)
	return nil
}

// unmarshal_over_reset for a caller that holds a json.Value: decodes directly
// from the in-memory json.Value tree when supported, avoiding JSON text
// re-marshaling and re-tokenization while preserving exact reset defaults.
unmarshal_value_over_reset :: proc(
	v: json.Value,
	ptr: rawptr,
	tid: typeid,
	spec := json.DEFAULT_SPECIFICATION,
	allocator := context.allocator,
) -> json.Unmarshal_Error {
	if _value_unmarshalers != nil {
		if fn, ok := _value_unmarshalers[tid]; ok && fn != nil {
			return fn(v, any{ptr, tid}, allocator)
		}
	}

	if _can_unmarshal_value_direct(tid) {
		if !_needs_reset_defaults(tid) {
			if handled, derr := _unmarshal_value_direct(v, ptr, tid, allocator); handled {
				return derr
			}
		} else if obj, is_obj := v.(json.Object); is_obj {
			key, _ := get_type_key_by_typeid(tid)
			if len(obj) == 0 {
				type_reset(key, ptr)
				return nil
			}
			info := runtime.type_info_base(type_info_of(tid)).variant.(runtime.Type_Info_Struct)
			prev_alloc := context.allocator
			context.allocator = allocator
			defer context.allocator = prev_alloc
			ti := type_info_of(tid)
			scratch, aerr := mem.alloc(ti.size, ti.align)
			fmt.assertf(aerr == nil, "out of memory for a %v scratch", tid)
			defer mem.free(scratch)
			type_reset(key, scratch)
			defer type_cleanup(key, scratch)

			if handled, derr := _unmarshal_value_direct(v, ptr, tid, allocator); handled {
				if derr != nil do return derr
				_take_absent_fields(ptr, scratch, info, obj)
				return nil
			}
			if key != INVALID_TYPE_KEY {
				type_cleanup(key, ptr)
			}
		}
	}

	data, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return json.Unmarshal_Data_Error.Invalid_Data
	obj, is_obj := v.(json.Object)
	if !is_obj {
		// Not an object: the unmarshal reports what is wrong with it.
		return _unmarshal_plain(data, ptr, tid, spec, allocator)
	}
	return unmarshal_over_reset_object(data, obj, ptr, tid, spec, allocator)
}

@(private = "file")
_can_unmarshal_value_direct :: proc(tid: typeid, depth := 0) -> bool {
	if tid == nil || depth > 24 do return false
	if _value_unmarshalers != nil {
		if fn, ok := _value_unmarshalers[tid]; ok && fn != nil {
			return true
		}
	}
	if json._user_unmarshalers != nil {
		if fn, ok := json._user_unmarshalers[tid]; ok && fn != nil {
			return false
		}
	}
	if tid == typeid_of(json.Value) do return false

	ti := type_info_of(tid)
	if ti == nil do return false
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean, runtime.Type_Info_Float:
		return true
	case runtime.Type_Info_Integer:
		return v.endianness == .Platform && ti.size <= 8
	case runtime.Type_Info_String:
		return !v.is_cstring
	case runtime.Type_Info_Enum:
		return v.base != nil && runtime.type_info_base(v.base).size <= 8
	case runtime.Type_Info_Array:
		return _can_unmarshal_value_direct(v.elem.id, depth + 1)
	case runtime.Type_Info_Slice:
		return _can_unmarshal_value_direct(v.elem.id, depth + 1)
	case runtime.Type_Info_Dynamic_Array:
		return _can_unmarshal_value_direct(v.elem.id, depth + 1)
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags do return false
		for i in 0 ..< int(v.field_count) {
			if !_can_unmarshal_value_direct(v.types[i].id, depth + 1) do return false
		}
		return true
	}
	return false
}

@(private = "file")
_write_int_to_ptr :: proc(ptr: rawptr, size: int, signed: bool, val: i64) -> bool {
	switch size {
	case 1:
		if signed { (cast(^i8)ptr)^ = i8(val) } else { (cast(^u8)ptr)^ = u8(val) }
	case 2:
		if signed { (cast(^i16)ptr)^ = i16(val) } else { (cast(^u16)ptr)^ = u16(val) }
	case 4:
		if signed { (cast(^i32)ptr)^ = i32(val) } else { (cast(^u32)ptr)^ = u32(val) }
	case 8:
		if signed { (cast(^i64)ptr)^ = val } else { (cast(^u64)ptr)^ = u64(val) }
	case:
		return false
	}
	return true
}

@(private = "file")
_write_float_to_ptr :: proc(ptr: rawptr, size: int, val: f64) -> bool {
	switch size {
	case 2:
		(cast(^f16)ptr)^ = f16(val)
	case 4:
		(cast(^f32)ptr)^ = f32(val)
	case 8:
		(cast(^f64)ptr)^ = val
	case:
		return false
	}
	return true
}

@(private = "file")
_write_bool_to_ptr :: proc(ptr: rawptr, size: int, b: bool) -> bool {
	switch size {
	case 1:
		(cast(^u8)ptr)^ = b ? 1 : 0
	case 2:
		(cast(^u16)ptr)^ = b ? 1 : 0
	case 4:
		(cast(^u32)ptr)^ = b ? 1 : 0
	case 8:
		(cast(^u64)ptr)^ = b ? 1 : 0
	case:
		return false
	}
	return true
}

@(private = "file")
_unmarshal_value_direct :: proc(
	v: json.Value,
	ptr: rawptr,
	tid: typeid,
	allocator: runtime.Allocator,
) -> (handled: bool, err: json.Unmarshal_Error) {
	if tid == nil || ptr == nil do return false, nil
	if _value_unmarshalers != nil {
		if fn, ok := _value_unmarshalers[tid]; ok && fn != nil {
			return true, fn(v, any{ptr, tid}, allocator)
		}
	}
	if json._user_unmarshalers != nil {
		if fn, ok := json._user_unmarshalers[tid]; ok && fn != nil {
			return false, nil
		}
	}

	ti := type_info_of(tid)
	base := runtime.type_info_base(ti)

	if v == nil {
		mem.zero(ptr, ti.size)
		return true, nil
	}
	if _, is_null := v.(json.Null); is_null {
		mem.zero(ptr, ti.size)
		return true, nil
	}

	#partial switch info in base.variant {
	case runtime.Type_Info_Boolean:
		b, ok := v.(json.Boolean)
		if !ok do return true, json.Unmarshal_Data_Error.Invalid_Data
		if !_write_bool_to_ptr(ptr, ti.size, b) do return false, nil
		return true, nil

	case runtime.Type_Info_Integer:
		if info.endianness != .Platform || ti.size > 8 do return false, nil
		#partial switch iv in v {
		case json.Integer:
			_ = _write_int_to_ptr(ptr, ti.size, info.signed, i64(iv))
			return true, nil
		case json.Float:
			_ = _write_int_to_ptr(ptr, ti.size, info.signed, i64(iv))
			return true, nil
		}
		return true, json.Unmarshal_Data_Error.Invalid_Data

	case runtime.Type_Info_Float:
		#partial switch fv in v {
		case json.Float:
			if !_write_float_to_ptr(ptr, ti.size, f64(fv)) do return false, nil
			return true, nil
		case json.Integer:
			if !_write_float_to_ptr(ptr, ti.size, f64(fv)) do return false, nil
			return true, nil
		}
		return true, json.Unmarshal_Data_Error.Invalid_Data

	case runtime.Type_Info_String:
		if info.is_cstring do return false, nil
		s, ok := v.(json.String)
		if !ok do return true, json.Unmarshal_Data_Error.Invalid_Data
		dst := cast(^string)ptr
		dst^ = strings.clone(s, allocator)
		return true, nil

	case runtime.Type_Info_Enum:
		ebase := runtime.type_info_base(info.base)
		eint, is_int := ebase.variant.(runtime.Type_Info_Integer)
		if !is_int || ebase.size > 8 do return false, nil
		#partial switch ev in v {
		case json.String:
			for name, idx in info.names {
				if name == ev {
					_ = _write_int_to_ptr(ptr, ebase.size, eint.signed, i64(info.values[idx]))
					return true, nil
				}
			}
			return true, nil
		case json.Integer:
			_ = _write_int_to_ptr(ptr, ebase.size, eint.signed, i64(ev))
			return true, nil
		case json.Float:
			_ = _write_int_to_ptr(ptr, ebase.size, eint.signed, i64(ev))
			return true, nil
		}
		return true, json.Unmarshal_Data_Error.Invalid_Data

	case runtime.Type_Info_Array:
		arr, ok := v.(json.Array)
		if !ok do return true, json.Unmarshal_Data_Error.Invalid_Data
		if len(arr) > info.count do return true, json.Unmarshal_Data_Error.Invalid_Data
		for elem_v, i in arr {
			elem_ptr := rawptr(uintptr(ptr) + uintptr(i * info.elem_size))
			eh, eerr := _unmarshal_value_direct(elem_v, elem_ptr, info.elem.id, allocator)
			if !eh do return false, nil
			if eerr != nil do return true, eerr
		}
		return true, nil

	case runtime.Type_Info_Slice:
		arr, ok := v.(json.Array)
		if !ok do return true, json.Unmarshal_Data_Error.Invalid_Data
		raw := cast(^mem.Raw_Slice)ptr
		if len(arr) == 0 {
			raw.data = nil
			raw.len = 0
			return true, nil
		}
		buf, berr := mem.alloc_bytes(len(arr) * info.elem_size, info.elem.align, allocator)
		if berr != nil do return true, json.Unmarshal_Data_Error.Invalid_Data
		mem.zero_slice(buf)
		raw.data = raw_data(buf)
		raw.len = len(arr)
		for elem_v, i in arr {
			elem_ptr := rawptr(uintptr(raw.data) + uintptr(i * info.elem_size))
			eh, eerr := _unmarshal_value_direct(elem_v, elem_ptr, info.elem.id, allocator)
			if !eh {
				mem.free_bytes(buf, allocator)
				raw^ = {}
				return false, nil
			}
			if eerr != nil do return true, eerr
		}
		return true, nil

	case runtime.Type_Info_Dynamic_Array:
		arr, ok := v.(json.Array)
		if !ok do return true, json.Unmarshal_Data_Error.Invalid_Data
		raw := cast(^mem.Raw_Dynamic_Array)ptr
		raw.allocator = allocator
		if len(arr) == 0 {
			raw.data = nil
			raw.len = 0
			raw.cap = 0
			return true, nil
		}
		buf, berr := mem.alloc_bytes(len(arr) * info.elem_size, info.elem.align, allocator)
		if berr != nil do return true, json.Unmarshal_Data_Error.Invalid_Data
		mem.zero_slice(buf)
		raw.data = raw_data(buf)
		raw.len = len(arr)
		raw.cap = len(arr)
		for elem_v, i in arr {
			elem_ptr := rawptr(uintptr(raw.data) + uintptr(i * info.elem_size))
			eh, eerr := _unmarshal_value_direct(elem_v, elem_ptr, info.elem.id, allocator)
			if !eh {
				mem.free_bytes(buf, allocator)
				raw^ = {allocator = allocator}
				return false, nil
			}
			if eerr != nil do return true, eerr
		}
		return true, nil

	case runtime.Type_Info_Struct:
		if .raw_union in info.flags do return false, nil
		obj, ok := v.(json.Object)
		if !ok do return true, json.Unmarshal_Data_Error.Invalid_Data
		for i in 0 ..< int(info.field_count) {
			off := info.offsets[i]
			ftype := info.types[i]
			name := info.names[i]
			if info.usings[i] && name == "_" {
				if _, is_sub := runtime.type_info_base(ftype).variant.(runtime.Type_Info_Struct); is_sub {
					eh, eerr := _unmarshal_value_direct(v, rawptr(uintptr(ptr) + off), ftype.id, allocator)
					if !eh do return false, nil
					if eerr != nil do return true, eerr
					continue
				}
			}
			json_name := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
			if comma := strings.index_byte(json_name, ','); comma >= 0 do json_name = json_name[:comma]
			if json_name == "-" do continue
			if json_name == "" do json_name = name
			if fv, has := obj[json_name]; has {
				eh, eerr := _unmarshal_value_direct(fv, rawptr(uintptr(ptr) + off), ftype.id, allocator)
				if !eh do return false, nil
				if eerr != nil do return true, eerr
			}
		}
		return true, nil
	}

	return false, nil
}

// True when a load of `tid` keeps reset defaults for absent fields: the
// setting is on, and T is a struct with a reset_T.
@(private = "file")
_needs_reset_defaults :: proc(tid: typeid) -> bool {
	if !serialization_settings.load_defaults_for_missing_fields do return false
	key, keyed := get_type_key_by_typeid(tid)
	if !keyed || !type_has_reset(key) do return false
	_, is_struct := runtime.type_info_base(type_info_of(tid)).variant.(runtime.Type_Info_Struct)
	return is_struct
}

@(private = "file")
_unmarshal_plain :: proc(
	data: []byte,
	ptr: rawptr,
	tid: typeid,
	spec: json.Specification,
	allocator: runtime.Allocator,
) -> json.Unmarshal_Error {
	if !json.is_valid(data, spec, true) {
		return json.Unmarshal_Data_Error.Invalid_Data
	}
	ptr_tid, ptr_ok := get_pointer_typeid_by_typeid(tid)
	fmt.assertf(ptr_ok, "%v has no pointer type (register_pointer_type)", tid)
	pp := ptr
	return json.unmarshal_any(data, any{&pp, ptr_tid}, spec, allocator)
}

// Swaps every field of `dst` the JSON object does not name with the same field
// of `src`. The names follow json.unmarshal: the `json` tag's name, else the
// field name, and the fields of a `using _:` field sit in the parent object.
// A `json:"-"` field is never in the data, so it always takes `src`'s value.
@(private = "file")
_take_absent_fields :: proc(dst, src: rawptr, info: runtime.Type_Info_Struct, obj: json.Object) {
	for i in 0 ..< int(info.field_count) {
		off := info.offsets[i]
		ftype := info.types[i]
		name := info.names[i]
		if info.usings[i] && name == "_" {
			if sub, ok := runtime.type_info_base(ftype).variant.(runtime.Type_Info_Struct); ok {
				_take_absent_fields(rawptr(uintptr(dst) + off), rawptr(uintptr(src) + off), sub, obj)
				continue
			}
		}
		json_name := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
		if comma := strings.index_byte(json_name, ','); comma >= 0 do json_name = json_name[:comma]
		if json_name != "-" {
			if json_name == "" do json_name = name
			if json_name in obj do continue
		}
		a := rawptr(uintptr(dst) + off)
		b := rawptr(uintptr(src) + off)
		rem := ftype.size
		cur: uintptr = 0
		swap_buf: [256]byte
		for rem > 0 {
			chunk := min(rem, len(swap_buf))
			pa := rawptr(uintptr(a) + cur)
			pb := rawptr(uintptr(b) + cur)
			mem.copy_non_overlapping(&swap_buf[0], pa, chunk)
			mem.copy_non_overlapping(pa, pb, chunk)
			mem.copy_non_overlapping(pb, &swap_buf[0], chunk)
			rem -= chunk
			cur += uintptr(chunk)
		}
	}
}
