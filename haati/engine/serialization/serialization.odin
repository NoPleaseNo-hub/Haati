package serialization

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:encoding/uuid"
import strings "core:strings"
import engine ".."
import "../log"

TYPE_GUID_KEY :: "__type_guid"

BeforeSerializeProc :: proc(ptr: rawptr, tid: typeid, is_cleanup: bool)
AfterDeserializeProc :: proc(ptr: rawptr, tid: typeid)
File_Reader_Proc :: #type proc(path: string, allocator: runtime.Allocator) -> ([]u8, os.Error)

file_reader_hook:   File_Reader_Proc
read_only_vfs_hook: proc() -> bool

mapBeforeSerialize: map[typeid]BeforeSerializeProc
mapAfterDeserialize: map[typeid]AfterDeserializeProc

@(phase={key=SerializationInit, order=-200})
init :: proc() {
	@(static) done := false
	if done do return
	done = true
	mapBeforeSerialize = make(map[typeid]BeforeSerializeProc)
	mapAfterDeserialize = make(map[typeid]AfterDeserializeProc)
	init_serialization_callbacks()
}

Run_Before_Serialize :: proc(ptr: rawptr, tid: typeid, is_cleanup: bool) {
	if cb, ok := mapBeforeSerialize[tid]; ok {
		cb(ptr, tid, is_cleanup)
	}
}

Run_After_Deserialize :: proc(ptr: rawptr, tid: typeid) {
	if cb, ok := mapAfterDeserialize[tid]; ok {
		cb(ptr, tid)
	}
}

load_from_file :: proc(filepath: string) -> (file_data: any, ok: bool) {
    // Validate filepath
    if filepath == "" || len(filepath) < 5 {
        log.error(fmt.tprintf("Invalid filepath: %s", filepath))
        return any{}, false
    }

    // Read file (mounted VFS first via hook or direct engine VFS, disk fallback)
    raw_data: []u8
    read_ok: os.Error
    if file_reader_hook != nil {
        raw_data, read_ok = file_reader_hook(filepath, context.allocator)
    } else {
        raw_data, read_ok = engine.vfs_read_entire_file(filepath, context.allocator)
    }
    if read_ok != nil {
        log.error(fmt.tprintf("Failed to read file: %s", filepath))
        return any{}, false
    }
    defer delete(raw_data)

    read_only := engine.vfs_is_mounted()
    if read_only_vfs_hook != nil {
        read_only = read_only_vfs_hook()
    }
    data := raw_data
    sanitized_data, was_sanitized := engine.material_sanitize_legacy_json(raw_data, context.temp_allocator)
    if was_sanitized {
        data = sanitized_data
        if !read_only {
            _ = os.write_entire_file(filepath, sanitized_data)
        }
    }

    // Parse JSON
    json_data, err := json.parse(data)
    if err != nil {
        log.error(fmt.tprintf("Failed to parse JSON: %v", err))
        return any{}, false
    }
    defer json.destroy_value(json_data)

    // Extract root object
    root, ok_root := json_data.(json.Object)
    if !ok_root {
        log.error("JSON root is not an object")
        return any{}, false
    }

    // Get __typ_guid from root (inside object, no "data" wrapper)
    guid_value, ok_guid := root[TYPE_GUID_KEY]
    if !ok_guid {
        log.error("Missing __typ_guid field")
        return any{}, false
    }

    guid_str, ok_guid_str := guid_value.(json.String)
    if !ok_guid_str {
        log.error("__typ_guid is not a string")
        return any{}, false
    }

    guid, guid_parse_err := uuid.read(guid_str)
    if guid_parse_err != nil {
        log.error(fmt.tprintf("Invalid UUID in __type_guid: %s", guid_str))
        return any{}, false
    }

    // A type no installed plugin declares: the asset's plugin is missing.
    if _, known := engine.get_typeid_by_guid_ok(guid); !known {
        log.error(fmt.tprintf("Unknown __typ_guid %s: no installed plugin declares this asset type", guid_str))
        return any{}, false
    }
    // Zeroed, then the file over the type's reset defaults: a field the file
    // lacks keeps its default.
    instance := engine.create_zero_instance_by_guid(guid)
    if instance.data == nil {
        log.error(fmt.tprintf("Failed to allocate instance for __type_guid: %s", guid_str))
        return any{}, false
    }
    unmarshal_err := engine.unmarshal_over_reset_object(data, root, instance.data, instance.id, json.DEFAULT_SPECIFICATION, context.allocator)
    if unmarshal_err != nil {
        free(instance.data)
        log.error(fmt.tprintf("Failed to unmarshal JSON: %v", unmarshal_err))
        return any{}, false
    }

    engine.type_on_validate_by_typeid(instance.id, instance.data)
    result := instance
    if cb, ok := mapAfterDeserialize[result.id]; ok {
        cb(result.data, result.id)
    }
    log.info(fmt.tprintf("Loaded from %s", filepath))
    return result, true
}

// write_asset_to_path writes a default asset (guid + marshaled data) to file_path.
write_asset_to_path :: proc(file_path: string, guid: uuid.Identifier, data: any, log_tag := "Created asset") -> bool {
    if file_path == "" || len(file_path) < 5 {
        log.error("write_asset_to_path: invalid file path")
        return false
    }
    if cb, ok := mapBeforeSerialize[data.id]; ok {
        cb(data.data, data.id, false)
    }
    opts := json.Marshal_Options{
        spec    = .JSON,
        pretty  = true,
        use_spaces = true,
        spaces  = 2,
    }
    raw_bytes, marshal_err := json.marshal(data, opts)
    if marshal_err != nil {
        log.error(fmt.tprintf("write_asset_to_path: JSON marshal failed: %v", marshal_err))
        return false
    }
    data_bytes := engine.json_canonicalize_floats(raw_bytes)
    delete(raw_bytes)
    defer delete(data_bytes)
    if cb, ok_cb := mapBeforeSerialize[data.id]; ok_cb {
        cb(data.data, data.id, true)
    }
    guid_str := uuid.to_string(guid)
    defer delete(guid_str)
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(&builder, "{\n  \"")
    strings.write_string(&builder, TYPE_GUID_KEY)
    strings.write_string(&builder, "\": \"")
    strings.write_string(&builder, guid_str)
    brace_idx := -1
    for bi := 0; bi < len(data_bytes); bi += 1 {
        if data_bytes[bi] == '{' {
            brace_idx = bi
            break
        }
    }
    tail := ""
    if brace_idx >= 0 {
        after_brace := strings.trim_left_space(string(data_bytes[brace_idx + 1:]))
        if len(after_brace) > 0 && after_brace != "}" {
            tail = after_brace
        }
    }
    if tail != "" {
        strings.write_string(&builder, "\",\n  ")
        strings.write_string(&builder, tail)
    } else {
        strings.write_string(&builder, "\"\n}")
    }
    full_json := strings.to_string(builder)
    if write_err := os.write_entire_file(file_path, transmute([]byte)full_json); write_err != nil {
        log.error(fmt.tprintf("write_asset_to_path: failed to write %s", file_path))
        return false
    }
    log.info(fmt.tprintf("%s: %s", log_tag, file_path))
    return true
}

save_to_file :: proc(filepath: string, file_data: any) -> bool {
    guid := engine.get_guid_by_typeid(file_data.id)
    return write_asset_to_path(filepath, guid, file_data, "Saved successfully to")
}
