package serialization

import "base:runtime"
import "core:reflect"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:io"
import "core:mem"
import engine ".."

// Every guid in a scene goes through here, so it runs thousands of times per
// save. The string is built on the STACK rather than in the temp allocator: a
// scene marshal is a long call chain that temp-allocates freely underneath this
// one, and a guid string handed out of a temp arena that gets reset mid-marshal
// writes garbage into the middle of the file — a corrupt scene that only fails
// on the next load.
asset_guid_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	guid := (cast(^engine.Asset_GUID)v.data)^
	buf: [uuid.EXPECTED_LENGTH]byte
	s := uuid.to_string(uuid.Identifier(guid), buf[:])
	if err := json.marshal_to_writer(w, s, opt); err != nil do return err
	return nil
}

asset_guid_from_value :: proc(val: json.Value, v: any, allocator: runtime.Allocator) -> json.Unmarshal_Error {
	_ = allocator
	#partial switch tv in val {
	case json.Null:
		(cast(^engine.Asset_GUID)v.data)^ = {}
		return nil
	case json.String:
		if len(tv) == 0 {
			(cast(^engine.Asset_GUID)v.data)^ = {}
			return nil
		}
		if id, read_err := uuid.read(tv); read_err == nil {
			(cast(^engine.Asset_GUID)v.data)^ = engine.Asset_GUID(id)
			return nil
		}
		// Fallback for legacy "[140, 80, ...]" string representations of [16]u8
		if len(tv) >= 2 && tv[0] == '[' && tv[len(tv) - 1] == ']' {
			raw: [16]u8
			idx := 0
			cur := 0
			has_digit := false
			for i := 1; i < len(tv) - 1; i += 1 {
				ch := tv[i]
				if ch >= '0' && ch <= '9' {
					cur = cur * 10 + int(ch - '0')
					has_digit = true
				} else if has_digit {
					if idx < 16 do raw[idx] = u8(clamp(cur, 0, 255))
					idx += 1
					cur = 0
					has_digit = false
				}
			}
			if has_digit && idx < 16 {
				raw[idx] = u8(clamp(cur, 0, 255))
				idx += 1
			}
			if idx == 16 {
				(cast(^engine.Asset_GUID)v.data)^ = engine.Asset_GUID(raw)
				return nil
			}
		}
		return json.Unmarshal_Data_Error.Invalid_Data
	case json.Array:
		if len(tv) == 0 {
			(cast(^engine.Asset_GUID)v.data)^ = {}
			return nil
		}
		if len(tv) == 16 {
			raw: [16]u8
			for elem, i in tv {
				#partial switch ev in elem {
				case json.Integer:
					raw[i] = u8(clamp(ev, 0, 255))
				case json.Float:
					raw[i] = u8(clamp(int(ev), 0, 255))
				case:
					return json.Unmarshal_Data_Error.Invalid_Data
				}
			}
			(cast(^engine.Asset_GUID)v.data)^ = engine.Asset_GUID(raw)
			return nil
		}
		return json.Unmarshal_Data_Error.Invalid_Data
	}
	return json.Unmarshal_Data_Error.Invalid_Data
}

asset_guid_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, parse_err := json.parse_value(p)
	if parse_err != nil do return parse_err
	defer json.destroy_value(val, p.allocator)
	return asset_guid_from_value(val, v, p.allocator)
}

mat4_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	m := (cast(^matrix[4, 4]f32)v.data)^
	flat := transmute([16]f32)m
	if err := json.marshal_to_writer(w, flat, opt); err != nil do return err
	return nil
}

mat4_from_value :: proc(val: json.Value, v: any, allocator: runtime.Allocator) -> json.Unmarshal_Error {
	_ = allocator
	#partial switch tv in val {
	case json.Null:
		(cast(^matrix[4, 4]f32)v.data)^ = {}
		return nil
	case json.Array:
		if len(tv) == 16 {
			flat: [16]f32
			for elem, i in tv {
				#partial switch ev in elem {
				case json.Integer:
					flat[i] = f32(ev)
				case json.Float:
					flat[i] = f32(ev)
				case:
					return json.Unmarshal_Data_Error.Invalid_Data
				}
			}
			(cast(^matrix[4, 4]f32)v.data)^ = transmute(matrix[4, 4]f32)flat
			return nil
		}
		if len(tv) == 4 {
			m: matrix[4, 4]f32
			for col_elem, col in tv {
				col_arr, ok := col_elem.(json.Array)
				if !ok || len(col_arr) != 4 do return json.Unmarshal_Data_Error.Invalid_Data
				for row_elem, row in col_arr {
					#partial switch ev in row_elem {
					case json.Integer:
						m[col, row] = f32(ev)
					case json.Float:
						m[col, row] = f32(ev)
					case:
						return json.Unmarshal_Data_Error.Invalid_Data
					}
				}
			}
			(cast(^matrix[4, 4]f32)v.data)^ = m
			return nil
		}
		if len(tv) == 0 {
			(cast(^matrix[4, 4]f32)v.data)^ = {}
			return nil
		}
	}
	return json.Unmarshal_Data_Error.Invalid_Data
}

mat4_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, parse_err := json.parse_value(p)
	if parse_err != nil do return parse_err
	defer json.destroy_value(val, p.allocator)
	return mat4_from_value(val, v, p.allocator)
}

union_marshal :: proc(w: io.Stream, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    tid := reflect.union_variant_typeid(v)
    if tid == nil {
        _, e := io.write_string(w, "null")
        if e != .None do return .Unsupported_Type
        return nil
    }

    guid := engine.get_guid_by_typeid(tid)
    guid_str := uuid.to_string(guid, context.temp_allocator)

    _, e := io.write_string(w, "{\"__type_guid\":")
    if e != .None do return .Unsupported_Type

    if err := json.marshal_to_writer(w, guid_str, opt); err != nil do return err

    variant_any := any{v.data, tid}
    variant_bytes, marshal_err := json.marshal(variant_any, opt^, context.temp_allocator)
    if marshal_err != nil do return marshal_err

    if len(variant_bytes) > 1 && variant_bytes[0] == '{' {
        stripped := variant_bytes[1:]
        if len(stripped) > 0 && stripped[0] != '}' {
            _, e = io.write_string(w, ",")
            if e != .None do return .Unsupported_Type
        }
        _, e = io.write(w, stripped)
        if e != .None do return .Unsupported_Type
    } else {
        _, e = io.write_string(w, "}")
        if e != .None do return .Unsupported_Type
    }

    return nil
}

union_from_value :: proc(obj_val: json.Value, v: any, allocator: runtime.Allocator) -> json.Unmarshal_Error {
    if obj_val == nil {
        reflect.set_union_variant_typeid(v, nil)
        return nil
    }
    if _, is_null := obj_val.(json.Null); is_null {
        reflect.set_union_variant_typeid(v, nil)
        return nil
    }

    root, ok := obj_val.(json.Object)
    if !ok do return json.Unmarshal_Data_Error.Invalid_Data

    type_val, has_type := root["__type_guid"]
    if !has_type do return json.Unmarshal_Data_Error.Invalid_Data

    guid_str, guid_ok := type_val.(json.String)
    if !guid_ok do return json.Unmarshal_Data_Error.Invalid_Data

    guid, guid_err := uuid.read(guid_str)
    if guid_err != nil do return json.Unmarshal_Data_Error.Invalid_Data

    // A variant no installed plugin declares is dangling data, not a bug.
    tid, known := engine.get_typeid_by_guid_ok(guid)
    if !known do return json.Unmarshal_Data_Error.Invalid_Data

    ti := type_info_of(tid)
    variant_ptr, alloc_err := mem.alloc(ti.size, ti.align, allocator)
    if alloc_err != nil do return json.Unmarshal_Data_Error.Invalid_Data
    mem.zero(variant_ptr, ti.size)

    _, ptr_tid_ok := engine.get_pointer_typeid_by_typeid(tid)
    if !ptr_tid_ok {
        mem.free(variant_ptr, allocator)
        return json.Unmarshal_Data_Error.Invalid_Data
    }

    if uerr := engine.unmarshal_value_over_reset(root, variant_ptr, tid, allocator = allocator); uerr != nil {
        mem.free(variant_ptr, allocator)
        return uerr
    }

    // Zero → reset → JSON → on_validate, the same as every other load.
    engine.type_on_validate_by_typeid(tid, variant_ptr)
    mem.copy(v.data, variant_ptr, ti.size)
    reflect.set_union_variant_typeid(v, tid)
    mem.free(variant_ptr, allocator)

    return nil
}

union_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
    obj_val, parse_err := json.parse_value(p)
    if parse_err != nil do return parse_err
    defer json.destroy_value(obj_val, p.allocator)
    return union_from_value(obj_val, v, p.allocator)
}
