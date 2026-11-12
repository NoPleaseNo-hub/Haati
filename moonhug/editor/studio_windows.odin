package editor

// =============================================================================
// ODIN MICRO-STUDIO & NIAGARA VISUAL SCRIPT STUDIO REGISTRATION (`studio_windows.odin`)
// =============================================================================

import "core:path/filepath"
import cs "moonhug:editor/code_studio"
import vs "moonhug:editor/visual_script"
import wnd "moonhug:editor/window"
import "../engine"

@(private = "file")
_open_ide_bridge :: proc(abs_path: string, line: int) -> bool {
	return open_in_code_editor(abs_path, line)
}

studio_windows_init :: proc() {
	cs.install_editor_hooks(relaunch_request, _open_ide_bridge)
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

@(editor_window={id="mh_visual_script", title="Niagara Visual Script Studio", icon="ACCOUNT_TREE", width=1240, height=780})
niagara_visual_script_window :: proc() {
	vs.draw_visual_script_studio_window()
}

@(menu_item={path="Window/Odin Micro-Studio", order=-12, shortcut=""})
menu_open_odin_micro_studio :: proc() {
	wnd.open("odin_micro_studio")
}

@(menu_item={path="Window/Niagara Visual Script Studio", order=-11, shortcut=""})
menu_open_niagara_visual_script :: proc() {
	wnd.open("mh_visual_script")
}

@(menu_item={path="Tools/Hot-Swap Gameplay Cartridge", order=1, shortcut="F7"})
menu_trigger_hot_cartridge_build :: proc() {
	engine.hot_cartridge_trigger_async_build(true)
}
