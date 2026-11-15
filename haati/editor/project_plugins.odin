package editor

// Project Settings > Plugins. Lists every folder in plugins/ (repository root,
// one level above the working directory) with a toggle: on means a symlink to
// it exists in packages/, which is what enables a plugin (docs/Plugins.md,
// Folder structure). The filesystem IS the state, so nothing persists here.
//
// Code changes apply on the next build: the tab offers Relaunch once a toggle
// changed. Assets mount right away through the refresh.

import "core:fmt"
import "core:os"
import "core:strings"
import im "haati:external/odin-imgui"
import "haati:engine_editor/asset_pipeline"
import "haati:editor/icons"
import "haati:editor/widgets"
import "../engine"

Plugin_Link_State :: enum {
	Off,       // nothing in packages/ for this plugin
	Linked,    // packages/<name> is a symlink: enabled
	Directory, // packages/<name> is a real directory: a copy, not toggled here
}

Plugin_Entry :: struct {
	name:  string, // temp
	state: Plugin_Link_State,
}

// Required built-in engine modules hard-imported by editor/engine whose
// haati:packages/<name> mount stays active for game projects (void_odin, app).
is_core_engine_module :: proc(name: string) -> bool {
	switch name {
	case "cad_csg",
		"control_rig",
		"physics3d",
		"physics2d",
		"input_manager",
		"mhgui",
		"text",
		"sprites",
		"essentials",
		"node_graph",
		"audio",
		"animation",
		"sequencer",
		"particles",
		"tween":
		return true
	}
	return false
}

project_plugins_register :: proc() {
	settings_add_custom_tab("Plugins", project_plugins_draw)
}

// Temp-allocated, sorted by the dir cache.
plugins_list :: proc() -> []Plugin_Entry {
	plugins_dir := engine.engine_plugins_dir(context.temp_allocator)
	pkgs_dir := project_packages_path()
	entries, ok := project_dir_listing(plugins_dir)
	if !ok do return nil
	out := make([dynamic]Plugin_Entry, context.temp_allocator)
	for entry in entries {
		if !entry.is_dir || strings.has_prefix(entry.name, ".") do continue
		link := fmt.tprintf("%s/%s", pkgs_dir, entry.name)
		state := Plugin_Link_State.Off
		if info, lerr := os.lstat(link, context.temp_allocator); lerr == nil {
			state = info.type == .Symlink ? .Linked : .Directory
		}
		append(&out, Plugin_Entry{name = strings.clone(entry.name, context.temp_allocator), state = state})
	}
	return out[:]
}

@(private = "file")
_plugin_after_change :: proc(verb, name: string) {
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
	fmt.printfln("[Editor] %s plugin %s - code changes apply after Relaunch", verb, name)
}

@(private = "file")
_plugin_enable :: proc(name: string) {
	link := fmt.tprintf("%s/%s", project_packages_path(), name)
	target := fmt.tprintf("%s/%s", engine.engine_plugins_dir(context.temp_allocator), name)
	if !engine.os_create_dir_link(link, target) {
		fmt.printfln("[Editor] Enable plugin: link %s -> %s failed", link, target)
		return
	}
	_plugin_after_change("Enabled", name)
}

// Only ever removes a symlink/junction. A real directory in packages/ is
// someone's copy and stays.
@(private = "file")
_plugin_disable :: proc(name: string) {
	if is_core_engine_module(name) do return
	link := fmt.tprintf("%s/%s", project_packages_path(), name)
	info, lerr := os.lstat(link, context.temp_allocator)
	if lerr != nil || info.type != .Symlink do return
	if !engine.os_remove_dir_link(link) {
		fmt.printfln("[Editor] Disable plugin: unlink %s failed", link)
		return
	}
	_plugin_after_change("Disabled", name)
}

project_plugins_draw :: proc() {
	plugins := plugins_list()

	// Fixed top part: what the toggles do, and the way to apply them.
	im.TextDisabled("Adds/Removes plugin symlinks in `packages` folder")
	im.AlignTextToFramePadding()
	im.BeginDisabled(relaunch_pending())
	if im.Button(icons.ICON_MD_REFRESH + " Relaunch") do relaunch_request()
	im.EndDisabled()
	im.SameLine()
	im.TextDisabled("to rebuild and apply changes")
	im.Spacing()

	if len(plugins) == 0 {
		im.TextDisabled("No folders in plugins/")
		return
	}

	// The list scrolls on its own below the fixed part. RowBg gives the
	// zebra stripes from the theme's TableRowBgAlt.
	flags := im.TableFlags_RowBg | im.TableFlags_ScrollY
	if im.BeginTable("##plugins", 1, flags, {0, 0}) {
		for p in plugins {
			im.PushID(strings.clone_to_cstring(p.name, context.temp_allocator))
			defer im.PopID()
			im.TableNextRow()
			im.TableNextColumn()

			core_mod := is_core_engine_module(p.name)
			on := p.state != .Off
			im.BeginDisabled(p.state == .Directory || core_mod)
			if im.Checkbox(strings.clone_to_cstring(p.name, context.temp_allocator), &on) {
				if on do _plugin_enable(p.name)
				else if !core_mod do _plugin_disable(p.name)
			}
			im.EndDisabled()
			if core_mod {
				im.SameLine()
				im.TextDisabled("[Core Module]")
			}
			tip: cstring
			if core_mod {
				tip = fmt.ctprintf("Required built-in engine module: haati:packages/%s stays active for game projects (void_odin, app).", p.name)
			} else {
				switch p.state {
				case .Linked:    tip = fmt.ctprintf("Enabled: packages/%s -> ../../plugins/%s", p.name, p.name)
				case .Off:       // nothing to say: no link exists
				case .Directory: tip = fmt.ctprintf("packages/%s is a real directory (a copy), not a link", p.name)
				}
			}
			widgets.tooltip(tip, im.HoveredFlags_AllowWhenDisabled)
		}
		im.EndTable()
	}
}
