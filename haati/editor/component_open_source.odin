package editor

// Component Source Code Quick-Navigation.
// Provides 1-click and double-click opening of component Odin source code directly in
// Rider, VS Code, or the user's configured editor, navigating to the exact definition line.
// Unified with Void File Explorer IDE settings — zero duplication.

import "core:fmt"
import engine "../engine"
import file_explorer "../packages/file_explorer"
import "inspector"
import "widgets"

@(init)
_init_component_source_hooks :: proc "contextless" () {
	inspector.open_component_source_fn = component_open_source
	inspector.get_component_source_location_fn = component_source_location
	widgets.open_source_in_ide_fn = open_in_code_editor
}

// Resolves and opens the Odin source file declaring this component in the user's code editor,
// jumping directly to the struct definition line.
component_open_source :: proc(key: engine.TypeKey) -> bool {
	raw_path, line, ok := component_source_location(key)
	if !ok || raw_path == "" {
		fmt.printfln("[Editor] No source location found for component %v", key)
		return false
	}

	abs_path, found := file_explorer.resolve_source_file_path(raw_path)
	if !found {
		fmt.printfln("[Editor] Source file not found for component %v (%s)", key, raw_path)
		return false
	}

	return file_explorer.open_script_in_ide(abs_path, line)
}

// Opens any source file at line using the unified IDE launcher.
open_in_code_editor :: proc(path: string, line: int = 1) -> bool {
	if abs_path, found := file_explorer.resolve_source_file_path(path); found {
		return file_explorer.open_script_in_ide(abs_path, line)
	}
	return file_explorer.open_script_in_ide(path, line)
}
