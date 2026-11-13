package editor

// =============================================================================
// ODIN MICRO-STUDIO & NIAGARA VISUAL SCRIPT STUDIO REGISTRATION (`studio_windows.odin`)
// =============================================================================

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import cs "haati:editor/code_studio"
import vs "haati:editor/visual_script"
import wnd "haati:editor/window"
import file_explorer_editor "haati:packages/file_explorer/editor"
import "../engine"

@(private = "file")
_open_ide_bridge :: proc(abs_path: string, line: int) -> bool {
	return open_in_code_editor(abs_path, line)
}

@(private = "file")
_switch_to_blueprint_bridge :: proc(path_hint: string) {
	resolved_graph := ""
	lo := strings.to_lower(path_hint, context.temp_allocator)
	if strings.has_suffix(lo, ".bodin") || strings.has_suffix(lo, ".mhgraph") {
		resolved_graph = path_hint
	} else if strings.has_suffix(lo, "_mhgraph_generated.odin") {
		base := filepath.base(path_hint)
		stem := strings.trim_suffix(base, "_mhgraph_generated.odin")
		repo_root := engine.resolve_repo_root(context.temp_allocator)
		bodin_cand, _ := filepath.join({repo_root, "assets", "scripts", fmt.tprintf("%s.bodin", stem)}, context.temp_allocator)
		if os.exists(bodin_cand) {
			resolved_graph = bodin_cand
		} else {
			mhg_cand, _ := filepath.join({repo_root, "assets", "scripts", fmt.tprintf("%s.mhgraph", stem)}, context.temp_allocator)
			if os.exists(mhg_cand) do resolved_graph = mhg_cand
		}
	}
	if resolved_graph != "" {
		vs.open_blueprint_in_studio(resolved_graph)
	}
	vs.set_studio_view_mode_graph()
	wnd.open("mh_visual_script")
}

studio_windows_init :: proc() {
	cs.install_editor_hooks(relaunch_request, _open_ide_bridge)
	cs.install_blueprint_switch_hook(_switch_to_blueprint_bridge)
	vs.register_material_studio_drawer(
		file_explorer_editor.draw_material_graph_studio_embedded,
		file_explorer_editor.connect_material_editor_to_path,
	)
	// Auto-load the latest pre-built `hot_cartridge_latest.dll` if present in `../builds/`
	dll_ext :: ".dll" when ODIN_OS == .Windows else (".dylib" when ODIN_OS == .Darwin else ".so")
	latest_rel, _ := filepath.join({"..", "builds", "hot_cartridge_latest" + dll_ext}, context.temp_allocator)
	_, _ = engine.hot_cartridge_load_dll(latest_rel)
}

studio_windows_frame_tick :: proc() {
	engine.hot_cartridge_poll()
}

studio_windows_draw_popups :: proc() {
	cs.draw_scoped_node_popup()
}

studio_windows_shutdown :: proc() {
	vs.shutdown_visual_script_studio()
	cs.shutdown_studio()
	engine.hot_cartridge_unload_all()
}

@(editor_window={id="odin_micro_studio", title="Odin Micro-Studio", icon="CODE", width=1060, height=700})
odin_micro_studio_window :: proc() {
	cs.draw_micro_studio_window()
}

@(editor_window={id="mh_visual_script", title="Unified Graph Studio", icon="ACCOUNT_TREE", width=1280, height=800})
unified_graph_studio_window :: proc() {
	vs.draw_visual_script_studio_window()
}

@(menu_item={path="Window/Odin Micro-Studio", order=-12, shortcut=""})
menu_open_odin_micro_studio :: proc() {
	wnd.open("odin_micro_studio")
}

@(menu_item={path="Window/Unified Graph Studio", order=-11, shortcut=""})
menu_open_unified_graph_studio :: proc() {
	wnd.open("mh_visual_script")
}

@(menu_item={path="Tools/Hot-Swap Gameplay Cartridge", order=1, shortcut="F7"})
menu_trigger_hot_cartridge_build :: proc() {
	engine.hot_cartridge_trigger_async_build(true)
}
