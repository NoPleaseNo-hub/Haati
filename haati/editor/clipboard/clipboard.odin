package clipboard

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:fmt"
import "core:reflect"
import engine "../../engine"
import ser "../../engine/serialization"
import "../../engine/log"

// The editor's one clipboard. It holds what the last copy took, of one kind:
// a value (a field or a component, as JSON), hierarchy objects, or project
// files. Each copy clears the rest, so a paste never brings back something
// copied before the last copy.
Clipboard :: struct {
	json_data:       [dynamic]byte,
	json_tid:        typeid,
	hierarchy_data:  []byte,
	hierarchy_alloc: runtime.Allocator,
	files:           [dynamic]string, // owned clones
	files_cut:       bool,            // the files move on paste instead of copying
}

@(private)
_clipboard: Clipboard

init :: proc() {
	prev := context.allocator
	context.allocator = runtime.default_allocator() // lives across frames
	defer context.allocator = prev
	_clipboard.json_data = make([dynamic]byte)
	_clipboard.files = make([dynamic]string)
}

shutdown :: proc() {
	clear_all()
	delete(_clipboard.json_data)
	delete(_clipboard.files)
	_clipboard = {}
}

// Empties the clipboard of every kind.
clear_all :: proc() {
	clear(&_clipboard.json_data)
	_clipboard.json_tid = nil
	if _clipboard.hierarchy_data != nil {
		alloc := _clipboard.hierarchy_alloc.procedure != nil ? _clipboard.hierarchy_alloc : context.allocator
		delete(_clipboard.hierarchy_data, alloc)
	}
	_clipboard.hierarchy_data = nil
	_clipboard.hierarchy_alloc = {}
	clear_files()
}

copy :: proc(v: any) -> bool {
	x, ok := _resolve_any(v)
	if !ok {
		log.error("clipboard.copy: could not resolve value")
		return false
	}
	ptr := x.data
	tid := x.id
	if ptr == nil || tid == nil {
		return false
	}

	ser.Run_Before_Serialize(ptr, tid, false)
	defer ser.Run_Before_Serialize(ptr, tid, true)
	opts := json.Marshal_Options {
		spec       = .JSON,
		pretty     = false,
		use_spaces = false,
		spaces     = 0,
	}
	bytes, err := json.marshal(x, opts, allocator = context.allocator)
	if err != nil {
		log.error(fmt.tprintf("clipboard.copy: marshal failed: %v", err))
		return false
	}
	defer delete(bytes)

	clear_all()
	append(&_clipboard.json_data, ..bytes)
	_clipboard.json_tid = tid
	return true
}

has :: proc() -> bool {
	return len(_clipboard.json_data) > 0 && _clipboard.json_tid != nil
}

target_typeid :: proc() -> typeid {
	return _clipboard.json_tid
}

can_paste :: proc(tid: typeid) -> bool {
	return len(_clipboard.json_data) > 0 && _clipboard.json_tid == tid && tid != nil
}

paste :: proc(dst: any) -> bool {
	if len(_clipboard.json_data) == 0 || _clipboard.json_tid == nil {
		return false
	}
	x, ok := _resolve_any(dst)
	if !ok {
		return false
	}
	if x.id != _clipboard.json_tid {
		return false
	}
	ptr := x.data
	tid := x.id
	ptr_tid, ptr_tid_ok := engine.get_pointer_typeid_by_typeid(tid)
	if !ptr_tid_ok {
		log.error(fmt.tprintf("clipboard.paste: no pointer typeid registered for %v — call engine.register_pointer_type($T) during init", tid))
		return false
	}
	target := any{data = &ptr, id = ptr_tid}
	um_err := json.unmarshal_any(_clipboard.json_data[:], target, json.DEFAULT_SPECIFICATION, context.allocator)
	if um_err != nil {
		log.error(fmt.tprintf("clipboard.paste: unmarshal failed: %v", um_err))
		return false
	}
	ser.Run_After_Deserialize(ptr, tid)
	return true
}

// Pastes component JSON values onto `comp_ptr` while preserving instance identity
// (`CompData`: `owner`, `local_id`, `enabled`), then runs `engine.type_on_validate`.
paste_component_values :: proc(comp_ptr: rawptr, comp_tid: typeid, type_key: engine.TypeKey) -> bool {
	if comp_ptr == nil || comp_tid == nil || !can_paste(comp_tid) do return false
	base := (cast(^engine.CompData)comp_ptr)^
	if !paste(any{data = comp_ptr, id = comp_tid}) do return false
	(cast(^engine.CompData)comp_ptr)^ = base
	engine.type_on_validate(type_key, comp_ptr)
	return true
}

// Takes ownership of `data`.
copy_hierarchy :: proc(data: []byte) {
	clear_all()
	_clipboard.hierarchy_data = data
	_clipboard.hierarchy_alloc = context.allocator
}

paste_hierarchy :: proc() -> []byte {
	return _clipboard.hierarchy_data
}

has_hierarchy :: proc() -> bool {
	return len(_clipboard.hierarchy_data) > 0
}

// Project files to paste, by path: `cut` moves them on paste, else they copy.
copy_files :: proc(paths: []string, cut: bool) {
	clear_all()
	for p in paths do append(&_clipboard.files, strings.clone(p, runtime.default_allocator()))
	_clipboard.files_cut = cut
}

files :: proc() -> []string {
	return _clipboard.files[:]
}

files_cut :: proc() -> bool {
	return _clipboard.files_cut
}

// Empties the files alone: a cut is pasted once.
clear_files :: proc() {
	for p in _clipboard.files do delete(p, runtime.default_allocator())
	clear(&_clipboard.files)
	_clipboard.files_cut = false
}

@(private)
_resolve_any :: proc(v: any) -> (any, bool) {
	x := v
	for _ in 0 ..< 32 {
		if x.data == nil {
			return {}, false
		}
		ti := type_info_of(x.id)
		if ti == nil {
			return {}, false
		}
		if !reflect.is_pointer(ti) {
			return x, true
		}
		x = reflect.deref(x)
	}
	return {}, false
}
