package editor

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:encoding/uuid"
import engine "../engine"
import "haati:engine_editor/asset_pipeline"
import "inspector"
import "undo"
import file_explorer_editor "haati:editor/file_explorer/editor"

ProjectViewData :: struct {
	currentPath:  string,
	selectedFile: string,
	rootPath:     string,
}

projectViewData: ProjectViewData

_project_scroll_to_list_sel: bool
_project_rename_active: bool
_project_rename_just_finished: bool

@(private = "file") _last_fe_selected: string
@(private = "file") _last_fe_epoch: u64
@(private = "file") _was_asset_locked: bool

init_project_view :: proc() {
	context.allocator = runtime.default_allocator()
	projectViewData.rootPath = strings.clone("assets")
	projectViewData.currentPath = strings.clone("assets")
}

shutdown_project_view :: proc() {
	project_file_ops_shutdown()
	project_package_samples_shutdown()
	project_dir_cache_shutdown()
	delete(projectViewData.rootPath, runtime.default_allocator())
	delete(projectViewData.currentPath, runtime.default_allocator())
	if projectViewData.selectedFile != "" {
		delete(projectViewData.selectedFile, runtime.default_allocator())
	}
	if _last_fe_selected != "" {
		delete(_last_fe_selected, runtime.default_allocator())
	}
	projectViewData = {}
	_last_fe_selected = ""
}

_project_set_current :: proc(path: string) {
	context.allocator = runtime.default_allocator()
	new_path := strings.clone(path)
	delete(projectViewData.currentPath)
	projectViewData.currentPath = new_path
}

_project_set_active :: proc(path: string) {
	context.allocator = runtime.default_allocator()
	new_path := strings.clone(path)
	delete(projectViewData.selectedFile)
	projectViewData.selectedFile = new_path
}

_project_set_selected :: proc(path: string) {
	_project_set_active(path)
	sel_proj_only(path)
}

_is_inspector_asset :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".asset") || strings.has_suffix(path, ".mat")
}

_project_inspect_path :: proc(full_path: string) {
	if inspector.is_locked() do return
	if project_path_is_package_root(full_path) {
		inspector.load_package(project_package_root_name(full_path), full_path, _project_package_asset_count(full_path))
		return
	}
	if _is_inspector_asset(full_path) {
		inspector.load_from_file(full_path)
		return
	}
	if strings.has_suffix(full_path, ".scene") {
		inspector.load_file_only(full_path)
		return
	}
	if asset_pipeline.is_importable_extension(filepath.ext(full_path)) {
		inspector.load_import_settings(full_path)
	}
}

_project_activate_file :: proc(full_path: string) {
	_project_inspect_path(full_path)
	if strings.has_suffix(full_path, ".scene") do editor_open_scene(full_path)
}

_project_begin_rename :: proc(full_path: string, in_tree: bool) {
	_ = in_tree
	if full_path == "" || project_path_is_protected(full_path) do return
	file_explorer_editor.fe_reveal_asset_path(full_path, true)
}

_project_begin_rename_selected :: proc() {
	sel := projectViewData.selectedFile
	if sel == "" do return
	_project_begin_rename(sel, false)
}

create_scene_variant :: proc(base_path: string) {
	dir := filepath.dir(base_path)
	stem := filepath.stem(base_path)
	variant_name := strings.concatenate({stem, "_Variant.scene"}, context.temp_allocator)
	variant_path, _ := filepath.join({dir, variant_name}, context.temp_allocator)

	if !engine.scene_create_variant_file(base_path, variant_path) {
		fmt.printf("[Editor] Failed to create scene variant from %s\n", base_path)
		return
	}
	asset_pipeline.asset_db_refresh()

	undo.purge_scenes(undo.get())
	hierarchy_edit_stack_clear()
	scene := engine.scene_load_single_path(variant_path)
	engine.sm_scene_set_active(scene)
}

_project_reveal_keep_selection :: proc(path: string) {
	parent := filepath.dir(path)
	if parent == "" do parent = projectViewData.rootPath
	_project_set_current(parent)
	_project_scroll_to_list_sel = true
	file_explorer_editor.fe_reveal_asset_path(path, false)
}

_project_reveal_path :: proc(path: string, select: bool) {
	parent := filepath.dir(path)
	if parent == "" do parent = projectViewData.rootPath
	if project_path_is_package_root(path) do parent = project_packages_path()
	_project_set_current(parent)
	if select {
		_project_set_selected(path)
		_project_inspect_path(path)
		_project_scroll_to_list_sel = true
	}
	file_explorer_editor.fe_reveal_asset_path(path, select)
}

// Keeps projectViewData synced with Void File Explorer and drains inspector
// asset ping/select/open requests every frame.
project_selection_frame_sync :: proc() {
	if fe_dir := file_explorer_editor.fe_active_asset_dir(); fe_dir != "" && fe_dir != projectViewData.currentPath {
		_project_set_current(fe_dir)
	}
	fe_sel := file_explorer_editor.fe_selected_asset_path()
	fe_epoch := file_explorer_editor.fe_selection_epoch()
	if fe_sel != _last_fe_selected || fe_epoch != _last_fe_epoch {
		context.allocator = runtime.default_allocator()
		delete(_last_fe_selected)
		_last_fe_selected = strings.clone(fe_sel)
		_last_fe_epoch = fe_epoch
		if fe_sel != "" {
			_project_set_selected(fe_sel)
			_project_inspect_path(fe_sel)
		}
	}

	asset_locked := inspector.is_locked()
	if _was_asset_locked && !asset_locked && sel_in_project() && fe_sel != "" {
		_project_inspect_path(fe_sel)
	}
	_was_asset_locked = asset_locked

	if !asset_locked && !sel_in_project() && len(_sel_scene) > 0 && inspector.has_selected_asset() {
		inspector.unload()
	}

	if ping_guid, ok := engine.inspector_take_pending_ping_asset(); ok {
		if path, pok := engine.asset_db_get_path(uuid.Identifier(ping_guid)); pok {
			_project_reveal_path(path, select = false)
		}
	}
	if sel_guid, ok := engine.inspector_take_pending_select_asset(); ok {
		if path, pok := engine.asset_db_get_path(uuid.Identifier(sel_guid)); pok {
			_project_reveal_path(path, select = true)
		}
	}
	if open_guid, ok := engine.inspector_take_pending_open_asset(); ok {
		if path, pok := engine.asset_db_get_path(uuid.Identifier(open_guid)); pok {
			_project_reveal_path(path, select = true)
			_project_activate_file(path)
		}
	}
}
