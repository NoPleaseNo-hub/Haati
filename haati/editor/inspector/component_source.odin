package inspector

import engine "haati:engine"

// Function pointers wired by editor core at startup so any inspector
// (builtin hierarchy inspector, or void_inspector plugin) can open scripts and query paths.
open_component_source_fn: proc(key: engine.TypeKey) -> bool
get_component_source_location_fn: proc(key: engine.TypeKey) -> (path: string, line: int, ok: bool)

open_component_source :: proc(key: engine.TypeKey) -> bool {
	if open_component_source_fn != nil do return open_component_source_fn(key)
	return false
}

component_source_location :: proc(key: engine.TypeKey) -> (path: string, line: int, ok: bool) {
	if get_component_source_location_fn != nil do return get_component_source_location_fn(key)
	return "", 0, false
}
