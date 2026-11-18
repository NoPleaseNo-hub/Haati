package editor

import "core:strings"
import im "haati:external/odin-imgui"
import engine "../engine"
import "undo"

HIERARCHY_DRAG_TYPE :: "HIERARCHY_TRANSFORM"
_HANDLE_NONE :: engine.Transform_Handle{}

@(private)
_hierarchy_force_open: engine.Transform_Handle
@(private)
_hierarchy_rename_target: engine.Transform_Handle
@(private)
_hierarchy_rename_just_finished: bool
@(private)
_hierarchy_scroll_to_sel: bool

Scene_Edit_Frame :: struct {
	path: string,
	guid: engine.Asset_GUID,
}

@(private)
_edit_stack: [dynamic]Scene_Edit_Frame

hierarchy_edit_stack_clear :: proc() {
	for &f in _edit_stack do delete(f.path)
	clear(&_edit_stack)
}

@(private)
_paste_subtree_with_undo :: proc(data: []byte, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	tH := engine.scene_paste_subtree(data, parent)
	if tH != {} {
		undo.record_create(tH, parent)
	}
	return tH
}

@(private)
_duplicate_with_undo :: proc(tH: engine.Transform_Handle) -> engine.Transform_Handle {
	result := engine.scene_duplicate_subtree(tH)
	if result != {} {
		w := engine.ctx_world()
		t := engine.pool_get(&w.transforms, engine.Handle(result))
		if t != nil {
			undo.record_create(result, engine.Transform_Handle(t.parent.handle))
		}
	}
	return result
}

@(private)
_edit_stack_guid_present :: proc(guid: engine.Asset_GUID) -> bool {
	if guid == (engine.Asset_GUID{}) do return false
	cur := engine.sm_scene_get_active()
	if cur != nil && cur.asset_guid == guid do return true
	for f in _edit_stack {
		if f.guid == guid do return true
	}
	return false
}

@(private)
_hierarchy_enter_scene :: proc(source_path: string, source_guid: engine.Asset_GUID) {
	push := !_edit_stack_guid_present(source_guid)
	if push {
		cur := engine.sm_scene_get_active()
		if cur != nil && len(cur.path) > 0 {
			frame := Scene_Edit_Frame{path = strings.clone(cur.path), guid = cur.asset_guid}
			append(&_edit_stack, frame)
		}
	}
	undo.purge_scenes(undo.get())
	sel_scene_clear()
	scene := engine.scene_load_single_path(source_path)
	engine.sm_scene_set_active(scene)
}

@(private)
_hierarchy_exit_scene :: proc() {
	if len(_edit_stack) == 0 do return
	frame := pop(&_edit_stack)
	defer delete(frame.path)
	undo.purge_scenes(undo.get())
	sel_scene_clear()
	scene := engine.scene_load_single_path(frame.path)
	engine.sm_scene_set_active(scene)
}

@(private)
_hierarchy_discard_scene :: proc(scene: ^engine.Scene) {
	if scene == nil || len(scene.path) == 0 do return
	path := strings.clone(scene.path, context.temp_allocator)
	undo.purge_scene(undo.get(), scene)
	sel_scene_clear()
	_ = engine.scene_reload_in_place_path(scene, path)
}

@(private)
_hierarchy_open_ancestors :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	if engine.pool_valid(&w.transforms, t.parent.handle) {
		_hierarchy_force_open = engine.Transform_Handle(t.parent.handle)
	}
}

@(private)
_begin_rename :: proc(tH: engine.Transform_Handle) {
	_hierarchy_rename_target = tH
	engine.hierarchy_request_rename(tH)
}

hierarchy_apply_pending_select :: proc() {
	if op, ok := engine.inspector_take_pending_selection_op(); ok {
		#partial switch op.op {
		case .Set:
			sel_scene_only(op.target)
			_hierarchy_scroll_to_sel = true
			_hierarchy_open_ancestors(op.target)
		case .Add:
			sel_scene_add(op.target)
			_hierarchy_scroll_to_sel = true
			_hierarchy_open_ancestors(op.target)
		case .Remove:
			sel_scene_remove(op.target)
		case .Toggle:
			sel_scene_toggle(op.target)
			_hierarchy_scroll_to_sel = true
			_hierarchy_open_ancestors(op.target)
		case .Clear:
			sel_scene_clear()
		case .Replace_Set:
			sel_scene_set(op.targets[:])
			if len(op.targets) > 0 {
				last := op.targets[len(op.targets) - 1]
				_hierarchy_scroll_to_sel = true
				_hierarchy_open_ancestors(last)
			}
		}
	} else if pending, ok := engine.inspector_take_pending_select(); ok {
		sel_scene_only(pending)
		_hierarchy_scroll_to_sel = true
		_hierarchy_open_ancestors(pending)
	}
}

@(private)
_push_transparent_button_bg :: proc() {
	transparent := im.Vec4{0, 0, 0, 0}
	hover := im.GetStyleColorVec4(im.Col.ButtonHovered)^
	active := im.GetStyleColorVec4(im.Col.ButtonActive)^
	im.PushStyleColorImVec4(im.Col.Button, transparent)
	im.PushStyleColorImVec4(im.Col.ButtonHovered, hover)
	im.PushStyleColorImVec4(im.Col.ButtonActive, active)
}

@(private)
_hierarchy_handle_is_root :: proc(tH: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return false
	return !engine.pool_valid(&w.transforms, t.parent.handle)
}

@(private)
_hierarchy_handle_is_nested :: proc(tH: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		if t.nested_owned do return true
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return false
}

@(private)
_nested_removal_target :: proc(tH: engine.Transform_Handle) -> (host: engine.Transform_Handle, obj_lid: engine.Local_ID, scene: ^engine.Scene, ok: bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, 0, nil, false
	parent_nested := false
	if pt := engine.pool_get(&w.transforms, t.parent.handle); pt != nil {
		parent_nested = pt.nested_owned || engine.scene_find_nested_scene_for_host(pt.scene, engine.Transform_Handle(t.parent.handle)) != nil
	}
	if !t.nested_owned && !parent_nested do return {}, 0, nil, false
	h := engine.transform_immediate_nested_host(tH)
	if h == {} do return {}, 0, nil, false
	return h, t.local_id, t.scene, true
}

@(private)
_delete_selected :: proc() {
	targets := sel_scene_top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Delete Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	deleted := 0
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) do continue
		nested_host, obj_lid, scene, is_prefab_content := _nested_removal_target(h)
		undo.record_delete(h)
		if is_prefab_content {
			if _, ok := engine.nested_scene_record_object_removed(scene, nested_host, obj_lid); ok {
				undo.record_object_removed_on_instance(scene, nested_host, obj_lid)
			}
		}
		deleted += 1
	}
	if deleted > 0 do undo.group_commit(&g)
	sel_scene_clear()
}

@(private)
_duplicate_selected :: proc() {
	targets := sel_scene_top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Duplicate Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	results := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		result := _duplicate_with_undo(h)
		if result == {} do continue
		engine._transform_append_name_suffix(result, "_copy")
		append(&results, result)
	}
	if len(results) > 0 do undo.group_commit(&g)
	sel_scene_clear()
	for r in results do sel_scene_add(r)
}

@(private)
_create_empty_parent :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	sibling_idx := engine.transform_get_sibling_index(tH)
	old_parent := engine.Transform_Handle(t.parent.handle)

	g := undo.group_begin("Create Empty Parent")
	defer undo.group_end(&g)

	new_parent := undo.record_create_child("Transform", old_parent)
	if new_parent == {} do return
	undo.record_reparent_to(new_parent, old_parent, sibling_idx)
	undo.record_reparent_to(tH, new_parent)
	undo.group_commit(&g)

	sel_scene_only(new_parent)
	_hierarchy_force_open = new_parent
}

@(private)
_is_ancestor :: proc(potential_ancestor: engine.Transform_Handle, node: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	n := engine.pool_get(&w.transforms, engine.Handle(node))
	if n == nil do return false
	current := n.parent
	for engine.pool_valid(&w.transforms, current.handle) {
		if current.handle == engine.Handle(potential_ancestor) do return true
		ct := engine.pool_get(&w.transforms, current.handle)
		current = ct.parent
	}
	return false
}

hierarchy_get_selected :: proc() -> engine.Transform_Handle {
	return sel_scene_active()
}

@(menu_item={path="Edit/Toggle Transform Active", order=0, shortcut="Alt+Shift+A"})
hierarchy_toggle_active_menu :: proc() {
	w := engine.ctx_world()
	if w == nil do return
	sel_scene_prune()
	targets := sel_scene_items()
	if len(targets) == 0 do return
	g := undo.group_begin("Toggle Active")
	defer undo.group_end(&g)
	toggled := 0
	for tH in targets {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do continue
		e := undo.edit_begin(tH, &t.is_active, typeid_of(bool), "Toggle Active")
		defer undo.edit_end(&e)
		t.is_active = !t.is_active
		toggled += 1
	}
	if toggled > 0 do undo.group_commit(&g)
}

shutdown_hierarchy_views :: proc() {
	hierarchy_edit_stack_clear()
	delete(_edit_stack)
	_edit_stack = nil
	selection_shutdown()
}
