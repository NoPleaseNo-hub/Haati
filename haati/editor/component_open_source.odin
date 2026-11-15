package editor

// Component Source Code Quick-Navigation.
// Provides 1-click and double-click opening of component Odin source code directly in
// Rider, VS Code, or the user's configured editor, navigating to the exact definition line.
// Unified with Void File Explorer IDE settings — zero duplication.

import "core:fmt"
import "core:os"
import engine "../engine"
import cs "haati:editor/code_studio"
import file_explorer "haati:editor/file_explorer"
import "inspector"
import "widgets"
import wnd "haati:editor/window"

@(init)
_init_component_source_hooks :: proc "contextless" () {
	inspector.open_component_source_fn = component_open_source
	inspector.get_component_source_location_fn = component_source_location
	widgets.open_source_in_ide_fn = open_in_code_editor
	file_explorer.open_script_smart_fn = open_in_code_editor
}

// Resolves and opens the source file declaring this component: `.bodin` scripts
// route to Blueprint Studio and `.odin` files route to Odin Micro-Studio or the
// configured external IDE at the exact definition line.
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

	return open_in_code_editor(abs_path, line)
}

// Smart Jump-to-Code router: `.bodin` / `.mhgraph` / companion generated files open in
// Blueprint Studio; `.odin` files open in Odin Micro-Studio by default or external IDE if set.
open_in_code_editor :: proc(path: string, line: int = 1) -> bool {
	resolved, found := file_explorer.resolve_source_file_path(path)
	target_in := found ? resolved : path
	kind, target := file_explorer.classify_script_jump_target(target_in)
	if kind == .Blueprint_Graph {
		open_in_blueprint_studio(target)
		return true
	}
	if file_explorer.prefer_external_ide_enabled() {
		return file_explorer.open_script_in_external_ide(target, line)
	}
	if !found && !os.exists(target) {
		return file_explorer.open_script_in_external_ide(path, line)
	}
	if cs.open_file_in_studio(target, line) {
		wnd.open("odin_micro_studio")
		return true
	}
	return file_explorer.open_script_in_external_ide(target, line)
}
