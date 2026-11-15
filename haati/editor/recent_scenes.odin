package editor

// Opening a scene from the editor goes through editor_open_scene, so the
// three places that used to spell the same four lines agree, and so the
// Recent Scenes list sees every open. The list is guids, not paths, so a
// moved scene stays reachable. It lives in editor_settings and persists with
// it.
//
// Recent Scenes is a DYNAMIC menu (menu.MenuEntryKind.Dynamic): its items
// exist only at draw time, so it is drawn by a proc rather than registered.

import "base:runtime"
import "core:encoding/uuid"
import "core:path/filepath"
import "core:strings"
import im "haati:external/odin-imgui"
import "haati:engine"
import "haati:editor/icons"
import "haati:editor/undo"
import "haati:editor/widgets"
import wnd "haati:editor/window"

RECENT_SCENES_MAX :: 10

@(private = "file")
_pending_open_scene_path: string

@(init)
_recent_scenes_init :: proc "contextless" () {
	wnd.open_scene_handler = _request_open_scene_impl
}

@(private = "file")
_set_pending_open_scene :: proc(path: string) {
	context.allocator = runtime.default_allocator()
	if len(_pending_open_scene_path) > 0 {
		delete(_pending_open_scene_path)
		_pending_open_scene_path = ""
	}
	if len(path) > 0 {
		_pending_open_scene_path = strings.clone(path)
	}
}

@(private = "file")
_request_open_scene_impl :: proc(path: string, prompt_save: bool) -> bool {
	if len(path) == 0 do return false
	clean_p, _ := filepath.clean(path, context.temp_allocator)
	norm_p, _ := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)
	engine.asset_db_request_refresh()

	if prompt_save {
		if cur := engine.sm_scene_get_active(); cur != nil && cur.dirty && !strings.equal_fold(cur.path, norm_p) {
			_set_pending_open_scene(norm_p)
			btns := [3]widgets.Dialog_Button{
				{
					label = "Save",
					is_default = true,
					action = proc() {
						if cur_sc := engine.sm_scene_get_active(); cur_sc != nil && len(cur_sc.path) > 0 {
							engine.scene_save(cur_sc, cur_sc.path)
						}
						target := strings.clone(_pending_open_scene_path, context.temp_allocator)
						_set_pending_open_scene("")
						if len(target) > 0 do editor_open_scene(target)
					},
				},
				{
					label = "Don't Save",
					is_danger = true,
					action = proc() {
						target := strings.clone(_pending_open_scene_path, context.temp_allocator)
						_set_pending_open_scene("")
						if len(target) > 0 do editor_open_scene(target)
					},
				},
				{
					label = "Cancel",
					is_cancel = true,
					action = proc() {
						_set_pending_open_scene("")
					},
				},
			}
			widgets.dialog_open(widgets.Dialog{
				title       = "Unsaved Scene Changes",
				description = "The active scene has unsaved changes. Save before switching scenes?",
				icon        = icons.ICON_MD_WARNING,
				buttons     = btns[:],
			})
			return true
		}
	}

	editor_open_scene(norm_p)
	return true
}

// Fresh navigation to `path`: the nested-scene edit stack resets, undo for
// the scenes being replaced is purged, and the scene becomes active.
editor_open_scene :: proc(path: string) {
	undo.purge_scenes(undo.get())
	hierarchy_edit_stack_clear()
	scene := engine.scene_load_single_path(path)
	engine.sm_scene_set_active(scene)
	if scene != nil do _recent_scenes_push(path)
}

@(private = "file")
_recent_scenes_push :: proc(path: string) {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return
	// The list is loaded by json.unmarshal under the default allocator and
	// saved from here, so every string in it is owned by that one allocator.
	context.allocator = runtime.default_allocator()
	guid_str := uuid.to_string(guid)
	list := &editor_settings.recent_scene_guids
	for g, i in list {
		if g == guid_str {
			ordered_remove(list, i)
			delete(g)
			break
		}
	}
	inject_at(list, 0, guid_str)
	for len(list) > RECENT_SCENES_MAX {
		delete(pop(list))
	}
}

@(menu_dynamic={path="File/Recent Scenes", order=2})
_recent_scenes_menu :: proc() {
	list := editor_settings.recent_scene_guids
	shown := 0
	for guid_str in list {
		guid, perr := uuid.read(guid_str)
		if perr != nil do continue
		path, ok := engine.asset_db_get_path(guid)
		if !ok do continue // deleted since: skipped, dropped on the next push
		label := strings.clone_to_cstring(strings.trim_suffix(filepath.base(path), ".scene"), context.temp_allocator)
		im.PushIDInt(i32(shown))
		if im.MenuItem(label) do editor_open_scene(path)
		widgets.tooltip(strings.clone_to_cstring(path, context.temp_allocator), im.HoveredFlags_ForTooltip)
		im.PopID()
		shown += 1
	}
	if shown == 0 {
		im.BeginDisabled()
		im.MenuItem("No recent scenes")
		im.EndDisabled()
	}
}
