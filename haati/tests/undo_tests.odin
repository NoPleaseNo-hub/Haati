package tests

import "../engine"
import "base:runtime"
import "../editor"
import "../editor/inspector"
import "../editor/menu"
import "../editor/simulate"
import "../editor/undo"

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_undo_value_transform_position :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	testing.expect(t, tr != nil, "transform exists")
	if tr == nil do return

	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {10, 20, 30}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
	testing.expect(t, undo.can_undo(s), "should be able to undo")

	ok := undo.apply_undo(s)
	testing.expect(t, ok, "undo succeeded")
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect(t, undo.can_redo(s), "should be able to redo")

	ok = undo.apply_redo(s)
	testing.expect(t, ok, "redo succeeded")
	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
}

@(test)
test_undo_value_component_field :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, lt := engine.transform_get_or_add_comp(tH, engine.Light)
	testing.expect(t, lt != nil, "light exists")
	if lt == nil do return

	target := undo.make_component_target(owned.handle, offset_of(engine.Light, color), typeid_of([4]f32))
	old_json := undo.capture_json(&lt.color, typeid_of([4]f32))
	lt.color = {1, 0.5, 0.25, 1}
	new_json := undo.capture_json(&lt.color, typeid_of([4]f32))
	undo.push_value(s, target, old_json, new_json)

	ok := undo.apply_undo(s)
	testing.expect(t, ok, "undo succeeded")
	testing.expect_value(t, lt.color, [4]f32{1, 1, 1, 1})

	ok = undo.apply_redo(s)
	testing.expect(t, ok, "redo succeeded")
	testing.expect_value(t, lt.color, [4]f32{1, 0.5, 0.25, 1})
}

@(test)
test_undo_value_string_name :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("Before")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo.make_transform_target(tH, offset_of(engine.Transform, name), typeid_of(string))
	old_json := undo.capture_json(&tr.name, typeid_of(string))
	delete(tr.name)
	tr.name = strings.clone("After")
	new_json := undo.capture_json(&tr.name, typeid_of(string))
	undo.push_value(s, target, old_json, new_json)

	undo.apply_undo(s)
	testing.expect_value(t, tr.name, "Before")
	undo.apply_redo(s)
	testing.expect_value(t, tr.name, "After")
}

@(test)
test_undo_reparent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	aH := engine.transform_new("A")
	bH := engine.transform_new("B")
	cH := engine.transform_new("C", aH)

	old_parent := aH
	old_index := engine.transform_get_sibling_index(cH)
	engine.transform_set_parent(cH, bH)
	new_index := engine.transform_get_sibling_index(cH)
	undo.record_reparent(cH, old_parent, bH, old_index, new_index)

	ct := engine.pool_get(&tc_mem.world.transforms, engine.Handle(cH))
	testing.expect(t, ct != nil, "C exists after reparent")
	if ct == nil do return
	testing.expect_value(t, ct.parent.handle, engine.Handle(bH))

	undo.apply_undo(s)
	testing.expect_value(t, ct.parent.handle, engine.Handle(aH))

	undo.apply_redo(s)
	testing.expect_value(t, ct.parent.handle, engine.Handle(bH))
}

@(test)
test_undo_create_subtree :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	parentH := engine.Transform_Handle(tc_mem.scene.root.handle)

	newH := engine.transform_new("New", parentH)
	undo.record_create(newH, parentH)

	p := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
	if p == nil do return
	testing.expect_value(t, len(p.children), 1)

	undo.apply_undo(s)
	testing.expect_value(t, len(p.children), 0)
	testing.expect(t, !engine.pool_valid(&tc_mem.world.transforms, engine.Handle(newH)), "new should be destroyed on undo")

	undo.apply_redo(s)
	testing.expect_value(t, len(p.children), 1)
}

@(test)
test_undo_delete_subtree :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	parentH := engine.Transform_Handle(tc_mem.scene.root.handle)
	childH := engine.transform_new("Child", parentH)
	ch := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
	if ch == nil do return
	child_lid := ch.local_id
	ch.position = {7, 8, 9}

	pre, ok := undo.record_delete_pre(childH)
	testing.expect(t, ok, "delete_pre captured")
	defer if ok do undo.record_cleanup(&pre)
	engine.transform_destroy(childH)
	undo.record_commit(&pre)

	p := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
	if p == nil do return
	testing.expect_value(t, len(p.children), 0)

	undo.apply_undo(s)
	testing.expect_value(t, len(p.children), 1)

	restored_h, rok := undo.scene_find_transform_by_local_id(tc_mem.scene, child_lid)
	testing.expect(t, rok, "restored child found by local_id")
	restored := engine.pool_get(&tc_mem.world.transforms, restored_h)
	testing.expect(t, restored != nil, "restored transform exists")
	if restored == nil do return
	testing.expect_value(t, restored.name, "Child")
	testing.expect_value(t, restored.position, [3]f32{7, 8, 9})

	undo.apply_redo(s)
	testing.expect_value(t, len(p.children), 0)
}

@(test)
test_undo_add_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, lt := engine.transform_add_comp(tH, .Light)
	testing.expect(t, lt != nil, "light added")
	if lt == nil do return
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	undo.record_add_component(tH, owned.handle, len(tr.components) - 1)

	testing.expect_value(t, len(tr.components), 1)

	undo.apply_undo(s)
	testing.expect_value(t, len(tr.components), 0)

	undo.apply_redo(s)
	testing.expect_value(t, len(tr.components), 1)
	testing.expect(t, tr.components[0].handle.type_key == .Light, "component is the light")
}

@(test)
test_undo_remove_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, lt := engine.transform_get_or_add_comp(tH, engine.Light)
	if lt == nil do return
	lt.color = {0.1, 0.2, 0.3, 1}
	lt.enabled = true

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	list_idx := 0

	pre, ok := undo.record_remove_component_pre(tH, owned.handle, list_idx)
	testing.expect(t, ok, "pre captured")
	defer if ok do undo.record_cleanup(&pre)
	engine.transform_remove_comp(tH, owned.handle)
	undo.record_commit(&pre)

	testing.expect_value(t, len(tr.components), 0)

	undo.apply_undo(s)
	testing.expect_value(t, len(tr.components), 1)

	_, restored := engine.transform_get_comp(tH, engine.Light)
	testing.expect(t, restored != nil, "component restored")
	if restored == nil do return
	testing.expect_value(t, restored.color, [4]f32{0.1, 0.2, 0.3, 1})

	undo.apply_redo(s)
	testing.expect_value(t, len(tr.components), 0)
}

@(test)
test_undo_reorder_components :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	engine.transform_add_comp(tH, .Light)
	engine.transform_add_comp(tH, .Camera)

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.Light)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.Camera)

	entry := tr.components[0]
	ordered_remove(&tr.components, 0)
	inject_at(&tr.components, 1, entry)
	undo.record_reorder_components(tH, 0, 1)

	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.Camera)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.Light)

	undo.apply_undo(s)
	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.Light)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.Camera)

	undo.apply_redo(s)
	testing.expect_value(t, tr.components[0].handle.type_key, engine.TypeKey.Camera)
	testing.expect_value(t, tr.components[1].handle.type_key, engine.TypeKey.Light)
}

@(test)
test_undo_group_command :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	undo.begin_group_command(s, "Edit Pos+Scale")
	{
		target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
		old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
		tr.position = {1, 1, 1}
		new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
		undo.push_value(s, target, old_json, new_json)

		target2 := undo.make_transform_target(tH, offset_of(engine.Transform, scale), typeid_of([3]f32))
		old_json2 := undo.capture_json(&tr.scale, typeid_of([3]f32))
		tr.scale = {2, 2, 2}
		new_json2 := undo.capture_json(&tr.scale, typeid_of([3]f32))
		undo.push_value(s, target2, old_json2, new_json2)
	}
	undo.end_group_command(s, "Edit Pos+Scale")

	testing.expect(t, undo.can_undo(s), "one undo entry available")

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tr.scale, [3]f32{1, 1, 1})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})
}

@(test)
test_undo_stack_clear :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {5, 5, 5}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	testing.expect(t, undo.can_undo(s), "can undo")

	undo.clear(s)
	testing.expect(t, !undo.can_undo(s), "cannot undo after clear")
	testing.expect(t, !undo.can_redo(s), "cannot redo after clear")

	undo.clear(s)
	testing.expect(t, !undo.can_undo(s), "double clear is safe")

	target2 := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json2 := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {9, 9, 9}
	new_json2 := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target2, old_json2, new_json2)
	testing.expect(t, undo.can_undo(s), "stack is reusable after clear")
	testing.expect_value(t, undo.top_index(s), 1)
}

@(test)
test_undo_inspector_flow_f32_field :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, p := engine.transform_get_or_add_comp(tH, engine.Light)
	if p == nil do return
	p.intensity = 55

	undo.push_component_owner(owned.handle)
	defer undo.pop_owner()

	e := undo.edit_begin(owned.handle, &p.intensity, typeid_of(f32))
	p.intensity = 123
	undo.edit_end(&e)

	testing.expect(t, undo.can_undo(s), "should have recorded f32 change")
	testing.expect_value(t, p.intensity, f32(123))

	ok := undo.apply_undo(s)
	testing.expect(t, ok, "undo succeeded")
	testing.expect_value(t, p.intensity, f32(55))

	ok = undo.apply_redo(s)
	testing.expect(t, ok, "redo succeeded")
	testing.expect_value(t, p.intensity, f32(123))
}

@(test)
test_undo_jump_to :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	push :: proc(s: ^undo.Undo_Stack, tr: ^engine.Transform, target: undo.Property_Target, v: [3]f32) {
		old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
		tr.position = v
		new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
		undo.push_value(s, target, old_json, new_json)
	}

	push(s, tr, target, {1, 0, 0})
	push(s, tr, target, {2, 0, 0})
	push(s, tr, target, {3, 0, 0})
	testing.expect_value(t, undo.top_index(s), 3)
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})

	ok := undo.jump_to(s, 1)
	testing.expect(t, ok, "jump to step 1")
	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect_value(t, tr.position, [3]f32{1, 0, 0})

	ok = undo.jump_to(s, 3)
	testing.expect(t, ok, "jump to step 3")
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})

	ok = undo.jump_to(s, 0)
	testing.expect(t, ok, "jump to initial state")
	testing.expect_value(t, undo.top_index(s), 0)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
}

@(test)
test_undo_default_label :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {9, 9, 9}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	items := undo.entries(s)
	testing.expect_value(t, len(items), 1)
	testing.expect_value(t, items[0].label, "Edit Transform")
}

@(test)
test_undo_create_empty_parent_repro :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	child := engine.transform_new("Child", rootH)
	testing.expect(t, child != {}, "child created")

	create_empty_parent :: proc(s: ^undo.Undo_Stack, tH: engine.Transform_Handle, w: ^engine.World) -> engine.Transform_Handle {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return {}
		sibling_idx := engine.transform_get_sibling_index(tH)
		old_parent := engine.Transform_Handle(t.parent.handle)

		undo.begin_group_command(s, "Create Empty Parent")
		committed := false
		defer if !committed do undo.abort_group_command(s)

		new_parent := engine.transform_new("Transform", old_parent)
		if new_parent == {} do return {}
		undo.record_create(new_parent, old_parent)

		old_np_parent := old_parent
		old_np_index := engine.transform_get_sibling_index(new_parent)
		engine.transform_set_parent(new_parent, old_parent, sibling_idx)
		new_np_index := engine.transform_get_sibling_index(new_parent)
		undo.record_reparent(new_parent, old_np_parent, old_parent, old_np_index, new_np_index)

		old_ch_parent := engine.Transform_Handle(t.parent.handle)
		old_ch_index := engine.transform_get_sibling_index(tH)
		engine.transform_set_parent(tH, new_parent)
		new_ch_index := engine.transform_get_sibling_index(tH)
		undo.record_reparent(tH, old_ch_parent, new_parent, old_ch_index, new_ch_index)

		undo.end_group_command(s, "Create Empty Parent")
		committed = true
		return new_parent
	}

	_ = create_empty_parent(s, child, &tc_mem.world)
	testing.expect(t, undo.apply_undo(s), "first undo ok")

	_ = create_empty_parent(s, child, &tc_mem.world)
	testing.expect(t, undo.apply_undo(s), "second undo ok")
}

@(test)
test_undo_new_edit_truncates_redo :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	push_edit :: proc(s: ^undo.Undo_Stack, tr: ^engine.Transform, target: undo.Property_Target, v: [3]f32) {
		old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
		tr.position = v
		new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
		undo.push_value(s, target, old_json, new_json)
	}

	push_edit(s, tr, target, {1, 0, 0})
	push_edit(s, tr, target, {2, 0, 0})
	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{1, 0, 0})
	testing.expect(t, undo.can_redo(s), "can redo")

	push_edit(s, tr, target, {9, 9, 9})
	testing.expect(t, !undo.can_redo(s), "redo truncated by new edit")
}

// Undoing a cleared Ref must restore it RESOLVED. The undo payload carries
// only PPtr data (Handle fields are json:"-" and unmarshal to zero), so the
// apply path re-binds handles against the live scene — without that, the
// inspector shows "unresolved local_id = N" until the scene reloads
// (repro: open tank.scene, clear tank.turret, undo).
@(test)
test_undo_ref_clear_restores_resolved_handle :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	// Loaded scene, so transforms register in local_ids — the repro state.
	path := "haati/tests/_test_undo_ref.scene"
	defer os.remove(path)
	scene_json := `{
  "root": 1,
  "transforms": [
    {"local_id": 1, "name": "Root", "is_active": true,
     "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [{"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}],
     "components": []},
    {"local_id": 2, "name": "Turret", "is_active": true,
     "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [], "components": []}
  ],
  "nested_scenes": [], "breadcrumbs": [], "components": []
}`
	testing.expect(t, os.write_entire_file(path, transmute([]byte)scene_json) == nil)

	loaded := engine.scene_load_single_path(path)
	testing.expect(t, loaded != nil, "scene loads")
	if loaded == nil do return
	tc_mem.scene = loaded

	root_h, root_ok := engine.bimap_get(&loaded.local_ids, engine.Local_ID(1))
	turret_h, turret_ok := engine.bimap_get(&loaded.local_ids, engine.Local_ID(2))
	testing.expect(t, root_ok && turret_ok, "lids registered at load")
	if !root_ok || !turret_ok do return

	w := engine.ctx_world()
	turret := engine.pool_get(&w.transforms, turret_h)
	testing.expect(t, turret != nil)
	if turret == nil do return
	testing.expect(t, turret.parent.handle == root_h, "loaded ref starts resolved")

	// Inspector flow: capture old, clear to none, capture new, push.
	target := undo.make_transform_target(engine.Transform_Handle(turret_h), offset_of(engine.Transform, parent), typeid_of(engine.Ref))
	old_json := undo.capture_json(&turret.parent, typeid_of(engine.Ref))
	turret.parent = engine.Ref{}
	new_json := undo.capture_json(&turret.parent, typeid_of(engine.Ref))
	undo.push_value(s, target, old_json, new_json)

	testing.expect(t, undo.apply_undo(s), "undo succeeded")
	testing.expect_value(t, turret.parent.pptr.local_id, engine.Local_ID(1))
	testing.expect(t, turret.parent.handle == root_h,
		"undone ref must be RESOLVED, not just carry the local_id")

	// Redo re-clears: the handle must clear too — unmarshal alone leaves the
	// pre-apply (resolved) handle under the zeroed pptr and the field would
	// still look assigned.
	testing.expect(t, undo.apply_redo(s), "redo succeeded")
	testing.expect_value(t, turret.parent.pptr.local_id, engine.Local_ID(0))
	testing.expect(t, turret.parent.handle == engine.Handle{},
		"redone clear must clear the handle as well")

	testing.expect(t, undo.apply_undo(s), "second undo succeeded")
	testing.expect(t, turret.parent.handle == root_h, "resolved again after redo cycle")
}

// The same clear→undo cycle for objects created THIS session and never saved:
// creation registers lids in the scene's live index (local_ids), so undo
// resolution binds without a save/reload round-trip.
@(test)
test_undo_ref_clear_resolves_for_fresh_objects :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	pH := engine.transform_new("Turret")
	cH := engine.transform_new("Body")
	engine.transform_set_parent(cH, pH)

	w := engine.ctx_world()
	ct := engine.pool_get(&w.transforms, engine.Handle(cH))
	pt := engine.pool_get(&w.transforms, engine.Handle(pH))
	testing.expect(t, ct != nil && pt != nil)
	if ct == nil || pt == nil do return
	testing.expect(t, ct.parent.pptr.local_id == pt.local_id, "ref carries the fresh lid")

	// Fresh lids must be registered in the live index at creation.
	reg_h, reg_ok := engine.bimap_get(&tc_mem.scene.local_ids, pt.local_id)
	testing.expect(t, reg_ok && reg_h == engine.Handle(pH), "created transform registered in local_ids")

	target := undo.make_transform_target(cH, offset_of(engine.Transform, parent), typeid_of(engine.Ref))
	old_json := undo.capture_json(&ct.parent, typeid_of(engine.Ref))
	ct.parent = engine.Ref{}
	new_json := undo.capture_json(&ct.parent, typeid_of(engine.Ref))
	undo.push_value(s, target, old_json, new_json)

	testing.expect(t, undo.apply_undo(s), "undo succeeded")
	testing.expect_value(t, ct.parent.pptr.local_id, pt.local_id)
	testing.expect(t, ct.parent.handle == engine.Handle(pH),
		"ref to a never-saved transform must resolve after undo")
}

// A scene is dirty from the first recorded edit until scene_save, and an
// undo or redo edits it again. Selection commands touch no scene.
@(test)
test_undo_marks_scene_dirty :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	scene := engine.sm_scene_get_active()
	testing.expect(t, scene != nil, "setup provides an active scene")
	if scene == nil do return
	scene.dirty = false

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	testing.expect(t, tr.scene == scene, "a new transform belongs to the active scene")

	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {1, 2, 3}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)
	testing.expect(t, scene.dirty, "recording an edit marks the scene dirty")

	scene.dirty = false
	undo.apply_undo(s)
	testing.expect(t, scene.dirty, "undo marks the scene dirty")

	scene.dirty = false
	undo.apply_redo(s)
	testing.expect(t, scene.dirty, "redo marks the scene dirty")

	// A grouped edit lands through end_group_command, not push, and must mark too.
	scene.dirty = false
	undo.begin_group_command(s, "Group")
	old_json2 := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {4, 5, 6}
	new_json2 := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json2, new_json2)
	testing.expect(t, !scene.dirty, "a command inside an open group is not landed yet")
	undo.end_group_command(s, "Group")
	testing.expect(t, scene.dirty, "closing the group marks the scene dirty")
}

// --- Merged from undo_session_tests.odin ---

@(test)
test_session_multi_target_is_one_undo_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	c := engine.transform_new("C")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	tc := engine.pool_get(&w.transforms, engine.Handle(c))

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
		undo.edit_target_transform(b, &tb.position, typeid_of([3]f32)),
		undo.edit_target_transform(c, &tc.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	ta.position = {1, 1, 1}
	tb.position = {2, 2, 2}
	tc.position = {3, 3, 3}
	undo.edit_session_end(&sess)

	// ONE undo takes all three back — the property comp_snapshot could not hold,
	// because a second target discarded the first's pending record.
	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tb.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tc.position, [3]f32{0, 0, 0})

	// And redo restores all three.
	undo.apply_redo(s)
	testing.expect_value(t, ta.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tb.position, [3]f32{2, 2, 2})
	testing.expect_value(t, tc.position, [3]f32{3, 3, 3})
}

// A dynamic-array element lives in its own allocation, so `field_ptr - base` is
// the distance between two unrelated allocations — measured at ~526KB for a
// 64-byte component. Recording that as an offset and applying it later writes
// far outside the component (the material-assignment crash). The session must
// fall back to recording the whole component.
@(test)
test_session_array_element_records_whole_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	h := _comp_handle_of(a, .MeshRenderer)
	w := engine.ctx_world()
	_, ptr := engine.transform_add_comp(a, .MeshRenderer)
	h = _comp_handle_of(a, .MeshRenderer)
	mr := cast(^engine.MeshRenderer)ptr
	mr.materials = make([dynamic]engine.Asset_GUID)
	append(&mr.materials, engine.Asset_GUID{})

	// Point at the ELEMENT, which is outside the component.
	targets := []undo.Edit_Target{
		undo.edit_target_pooled(h, &mr.materials[0], typeid_of(engine.Asset_GUID)),
	}
	sess := undo.edit_session_begin(targets, "Material")
	mat := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	mr.materials[0] = mat
	undo.edit_session_end(&sess)

	// Every recorded offset must land inside the component. A nonsense offset
	// is checked rather than "did it crash": the bad write lands wherever the
	// heap happens to be, so it faults in the editor and usually not in a test.
	comp_size := u32(size_of(engine.MeshRenderer))
	for entry in s.items[:s.top] {
		_expect_offsets_in_bounds(t, entry.cmd, comp_size)
	}

	testing.expect_value(t, mr.materials[0], mat)
	undo.apply_undo(s)
	testing.expect_value(t, len(mr.materials), 1)
	testing.expect_value(t, mr.materials[0], engine.Asset_GUID{})
	_ = w
}

@(test)
test_session_no_change_records_nothing :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	ta.position = {5, 5, 5}

	before := s.top
	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	// Nothing written: clicking into a field and tabbing out must not record.
	undo.edit_session_end(&sess)

	testing.expect_value(t, s.top, before)
}

// Only the targets that actually moved are recorded, so a selection where one
// object already held the new value does not gain a no-op entry.
@(test)
test_session_records_only_changed_targets :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	tb.position = {7, 7, 7} // already at the destination

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
		undo.edit_target_transform(b, &tb.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	ta.position = {7, 7, 7}
	tb.position = {7, 7, 7} // unchanged
	undo.edit_session_end(&sess)

	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tb.position, [3]f32{7, 7, 7}) // untouched by the undo
}

@(test)
test_session_abort_records_nothing :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))

	before := s.top
	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	ta.position = {4, 4, 4}
	undo.edit_session_abort(&sess)

	// The value the caller wrote stays; only the record is dropped.
	testing.expect_value(t, ta.position, [3]f32{4, 4, 4})
	testing.expect_value(t, s.top, before)
}

// A session survives the frames between begin and end, which is the whole point
// — the before-state is captured once and cannot be clobbered by anything that
// happens in between.
@(test)
test_session_spans_intervening_edits :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")

	// Several frames of dragging, plus an unrelated recorded edit in between.
	ta.position = {1, 0, 0}
	e := undo.edit_begin(b, &tb.position, typeid_of([3]f32), "Other")
	tb.position = {9, 9, 9}
	undo.edit_end(&e)
	ta.position = {2, 0, 0}
	ta.position = {3, 0, 0}

	undo.edit_session_end(&sess)

	// The session records 0 -> 3, not 2 -> 3: the pre-image was taken at begin.
	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
}

@(private)
_comp_handle_of :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> engine.Handle {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}
	for comp in t.components {
		if comp.handle.type_key == key do return comp.handle
	}
	return {}
}

// Fails on any pooled record whose offset points outside the component it
// names. resolve_target_ptr computes base+offset with no bounds check, so such
// a record is a wild write waiting to happen.
@(private)
_expect_offsets_in_bounds :: proc(t: ^testing.T, command: undo.Command, comp_size: u32) {
	#partial switch cmd in command {
	case undo.Value_Command:
		if cmd.target.kind != .Pooled do return
		if cmd.target.handle.type_key == .Transform do return
		testing.expectf(
			t, cmd.target.offset < comp_size,
			"undo record points %v bytes into a %v-byte component",
			cmd.target.offset, comp_size,
		)
	case undo.Group_Command:
		for sub in cmd.subs {
			_expect_offsets_in_bounds(t, sub, comp_size)
		}
	}
}

// Undoing a multi-edit of an array ELEMENT must restore each object's own
// value, not the active object's.
//
// An element is recorded as the WHOLE component (its storage is a separate
// allocation no offset can name). A "before" payload captured at FIELD
// granularity and written into such an entry is the wrong shape: undo then
// applies the active object's whole component to its peer. That is what emptied
// DamagedHelmet's materials when undoing a material set across a selection.
@(test)
test_session_array_element_undo_restores_each_own_value :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshRenderer)
	_, b_ptr := engine.transform_add_comp(b, .MeshRenderer)
	mr_a := cast(^engine.MeshRenderer)a_ptr
	mr_b := cast(^engine.MeshRenderer)b_ptr

	mat_a := engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	mat_b := engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}
	mr_a.materials = make([dynamic]engine.Asset_GUID)
	mr_b.materials = make([dynamic]engine.Asset_GUID)
	append(&mr_a.materials, mat_a)
	append(&mr_b.materials, mat_b)

	// A material assigned across both, as the inspector's element row does.
	picked := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	targets := []undo.Edit_Target{
		undo.edit_target_pooled(_comp_handle_of(a, .MeshRenderer), &mr_a.materials[0], typeid_of(engine.Asset_GUID)),
		undo.edit_target_pooled(_comp_handle_of(b, .MeshRenderer), &mr_b.materials[0], typeid_of(engine.Asset_GUID)),
	}
	sess := undo.edit_session_begin(targets, "Material")
	mr_a.materials[0] = picked
	mr_b.materials[0] = picked
	undo.edit_session_end(&sess)

	testing.expect_value(t, mr_a.materials[0], picked)
	testing.expect_value(t, mr_b.materials[0], picked)

	// Each object goes back to ITS OWN material, and neither array is emptied.
	undo.apply_undo(s)
	testing.expect_value(t, len(mr_a.materials), 1)
	testing.expect_value(t, len(mr_b.materials), 1)
	testing.expect_value(t, mr_a.materials[0], mat_a)
	testing.expect_value(t, mr_b.materials[0], mat_b)
}

// A SINGLE selected object's picker change must record an undo step.
//
// Pickers are bracketed retroactively: the row snapshots the value, draws, and
// opens the transaction only if it moved. Taking that snapshot only when there
// are multi-edit peers left a lone object's mesh assignment with nothing to
// record against, so changing a mesh produced no undo step at all.
@(test)
test_session_single_target_records_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	_, ptr := engine.transform_add_comp(a, .MeshFilter)
	mf := cast(^engine.MeshFilter)ptr
	original := engine.PPtr{guid = engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}}
	mf.mesh = original

	before := s.top
	targets := []undo.Edit_Target{
		undo.edit_target_pooled(_comp_handle_of(a, .MeshFilter), &mf.mesh, typeid_of(engine.PPtr)),
	}
	sess := undo.edit_session_begin(targets, "mesh")
	picked := engine.PPtr{guid = engine.Asset_GUID{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7}}
	mf.mesh = picked
	undo.edit_session_end(&sess)

	// One entry, and it reverts.
	testing.expect(t, s.top > before, "a single-object edit is recorded")
	undo.apply_undo(s)
	testing.expect_value(t, mf.mesh, original)
}

// A structural op (inspector button, union variant switch, decorator) applies to
// the whole selection as ONE undo step.
//
// These were the last callers of the single global pending edit, which held one
// record at a time: a second object's snapshot discarded the first's, so undo
// reverted the active object and left every peer where the click had put it.
@(test)
test_structural_edit_covers_selection_in_one_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .Light)
	_, b_ptr := engine.transform_add_comp(b, .Light)
	light_a := cast(^engine.Light)a_ptr
	light_b := cast(^engine.Light)b_ptr
	light_a.intensity = 1
	light_b.intensity = 1

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle_of(b, .Light), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	before := s.top
	undo.push_component_owner(_comp_handle_of(a, .Light))
	sess := inspector.structural_edit_begin("Invoke")
	// What a button's `invoke` does: mutate every selected object's component.
	light_a.intensity = 4
	light_b.intensity = 4
	inspector.structural_edit_end(&sess)
	undo.pop_owner()

	testing.expect_value(t, s.top, before + 1)

	// One undo takes BOTH back, not just the active object.
	undo.apply_undo(s)
	testing.expect_value(t, light_a.intensity, f32(1))
	testing.expect_value(t, light_b.intensity, f32(1))
}

// An inspector button runs on EVERY selected object, in one undo step.
//
// The click path is only reachable by a real mouse press, so the mutation is
// extracted into `inspector_button_invoke` and driven here. Running `invoke` on
// the active object alone left the session recording peers that never changed,
// so the button silently did nothing to the rest of the selection.
@(test)
test_inspector_button_invokes_across_selection :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .Light)
	_, b_ptr := engine.transform_add_comp(b, .Light)
	light_a := cast(^engine.Light)a_ptr
	light_b := cast(^engine.Light)b_ptr
	light_a.intensity = 1
	light_b.intensity = 1

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle_of(b, .Light), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	btn := inspector.Inspector_Button{label = "Double Intensity", invoke = _btn_double_intensity}

	before := s.top
	undo.push_component_owner(_comp_handle_of(a, .Light))
	inspector.inspector_button_invoke(btn, a_ptr)
	undo.pop_owner()

	// Both ran, and it is ONE step.
	testing.expect_value(t, light_a.intensity, f32(2))
	testing.expect_value(t, light_b.intensity, f32(2))
	testing.expect_value(t, s.top, before + 1)

	undo.apply_undo(s)
	testing.expect_value(t, light_a.intensity, f32(1))
	testing.expect_value(t, light_b.intensity, f32(1))
}

@(private)
_btn_double_intensity :: proc(comp: rawptr) {
	light := cast(^engine.Light)comp
	light.intensity *= 2
}

// Switching a union variant zeroes the payload and records one undo step.
//
// The old variant's bytes mean something different under the new tag, so
// carrying them over reads garbage as the new type. No component in the tree
// carries a union field yet, so the shape is declared here.
_Test_Union :: union {
	i64,
	[2]f32,
}

@(test)
test_union_variant_switch_zeroes_payload :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	// Undo writes a value back through its registered pointer type; a type the
	// engine has never seen cannot be restored.
	engine.register_pointer_type(_Test_Union)

	ti := runtime.type_info_base(type_info_of(_Test_Union))
	info, ok := ti.variant.(runtime.Type_Info_Union)
	if !testing.expect(t, ok, "test type is a union") do return

	val: _Test_Union = i64(0x7fff_ffff)
	ptr := rawptr(&val)
	tag_ptr := rawptr(uintptr(ptr) + uintptr(info.tag_offset))

	// A raw target, which is what a union field inside editor-owned state is.
	undo.push_raw_owner(ptr, typeid_of(_Test_Union))
	defer undo.pop_owner()

	before := s.top
	// Variant INDEX 1 is [2]f32. For this nilable union that is stored as tag 2,
	// since tag 0 means nil — the conversion the inspector previously got wrong,
	// selecting the neighbouring variant.
	inspector.union_set_variant(ptr, tag_ptr, info, 1)

	// The i64 payload must not survive into the [2]f32 variant.
	v, is_vec := val.([2]f32)
	testing.expect(t, is_vec, "variant switched to [2]f32")
	testing.expect_value(t, v, [2]f32{0, 0})
	testing.expect_value(t, s.top, before + 1)

	// And it reverts.
	undo.apply_undo(s)
	old, is_int := val.(i64)
	testing.expect(t, is_int, "undo restored the i64 variant")
	testing.expect_value(t, old, i64(0x7fff_ffff))
}

// --- Merged from undo_ergonomic_tests.odin ---

@(test)
test_undo_edit_transform_begin_commit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		e := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {10, 20, 30}
		undo.edit_end(&e)
	}

	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
	testing.expect(t, undo.can_undo(s), "undo recorded")

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{10, 20, 30})
}

@(test)
test_undo_edit_transform_string_field :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("Before")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		e := undo.edit_begin(tH, &tr.name, typeid_of(string))
		delete(tr.name)
		tr.name = strings.clone("After")
		undo.edit_end(&e)
	}

	testing.expect_value(t, tr.name, "After")

	undo.apply_undo(s)
	testing.expect_value(t, tr.name, "Before")

	undo.apply_redo(s)
	testing.expect_value(t, tr.name, "After")
}

@(test)
test_undo_edit_component_begin_commit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, lt := engine.transform_get_or_add_comp(tH, engine.Light)
	if lt == nil do return

	{
		e := undo.edit_begin(owned.handle, &lt.color, typeid_of([4]f32))
		lt.color = {1, 0.5, 0.25, 1}
		undo.edit_end(&e)
	}

	testing.expect_value(t, lt.color, [4]f32{1, 0.5, 0.25, 1})

	undo.apply_undo(s)
	testing.expect_value(t, lt.color, [4]f32{1, 1, 1, 1})

	undo.apply_redo(s)
	testing.expect_value(t, lt.color, [4]f32{1, 0.5, 0.25, 1})
}

@(test)
test_undo_edit_cancel_no_record :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		e := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {5, 5, 5}
		undo.edit_cancel(&e)
	}

	testing.expect_value(t, tr.position, [3]f32{5, 5, 5})
	testing.expect(t, !undo.can_undo(s), "cancel did not record")
}

@(test)
test_undo_group_scope_commit :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		g := undo.group_begin("Edit Pos+Scale")
		defer undo.group_end(&g)

		e1 := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {1, 1, 1}
		undo.edit_end(&e1)

		e2 := undo.edit_begin(tH, &tr.scale, typeid_of([3]f32))
		tr.scale = {2, 2, 2}
		undo.edit_end(&e2)

		undo.group_commit(&g)
	}

	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect_value(t, tr.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tr.scale, [3]f32{1, 1, 1})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})
}

@(test)
test_undo_group_scope_auto_abort :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	{
		g := undo.group_begin("Aborted")
		defer undo.group_end(&g)

		e := undo.edit_begin(tH, &tr.position, typeid_of([3]f32))
		tr.position = {7, 7, 7}
		undo.edit_end(&e)
	}

	testing.expect(t, !undo.can_undo(s), "missing group_commit aborts group")
}

@(test)
test_undo_record_delete_fused :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	parentH := engine.Transform_Handle(tc_mem.scene.root.handle)
	childH := engine.transform_new("Child", parentH)
	ch := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
	if ch == nil do return
	child_lid := ch.local_id
	ch.position = {7, 8, 9}

	undo.record_delete(childH)

	p := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
	if p == nil do return
	testing.expect_value(t, len(p.children), 0)

	undo.apply_undo(s)
	testing.expect_value(t, len(p.children), 1)

	restored_h, rok := undo.scene_find_transform_by_local_id(tc_mem.scene, child_lid)
	testing.expect(t, rok, "restored child found")
	restored := engine.pool_get(&tc_mem.world.transforms, restored_h)
	if restored == nil do return
	testing.expect_value(t, restored.position, [3]f32{7, 8, 9})

	undo.apply_redo(s)
	testing.expect_value(t, len(p.children), 0)
}

@(test)
test_undo_record_remove_component_fused :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	owned, lt := engine.transform_get_or_add_comp(tH, engine.Light)
	if lt == nil do return
	lt.color = {0.1, 0.2, 0.3, 1}

	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	undo.record_remove_component(tH, owned.handle)
	testing.expect_value(t, len(tr.components), 0)

	undo.apply_undo(s)
	testing.expect_value(t, len(tr.components), 1)
	_, restored := engine.transform_get_comp(tH, engine.Light)
	testing.expect(t, restored != nil, "component restored")
	if restored == nil do return
	testing.expect_value(t, restored.color, [4]f32{0.1, 0.2, 0.3, 1})

	undo.apply_redo(s)
	testing.expect_value(t, len(tr.components), 0)
}

@(test)
test_undo_record_create_child_and_reparent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	aH := undo.record_create_child("A", rootH)
	bH := undo.record_create_child("B", rootH)
	testing.expect(t, aH != {}, "A created")
	testing.expect(t, bH != {}, "B created")

	undo.record_reparent_to(aH, bH)
	ta := engine.pool_get(&tc_mem.world.transforms, engine.Handle(aH))
	if ta == nil do return
	testing.expect_value(t, ta.parent.handle, engine.Handle(bH))

	undo.apply_undo(s)
	testing.expect_value(t, ta.parent.handle, engine.Handle(rootH))
}

@(test)
test_undo_field_drag_external :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return

	d := undo.edit_begin(tH, &tr.position, typeid_of([3]f32), "Viewport Move")
	tr.position = {1, 0, 0}
	tr.position = {2, 0, 0}
	tr.position = {3, 0, 0}
	undo.edit_end(&d)

	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})

	undo.apply_undo(s)
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})

	undo.apply_redo(s)
	testing.expect_value(t, tr.position, [3]f32{3, 0, 0})
}

// --- Merged from undo_rework_tests.odin ---

@(private="file")
_sel_state_proj :: proc(ids: ..engine.Local_ID) -> undo.Selection_State {
	proj := make([]engine.PPtr, len(ids))
	for id, i in ids {
		proj[i] = engine.PPtr{local_id = id}
	}
	return undo.Selection_State{proj = proj}
}

@(private="file")
_applied_sel: [dynamic]engine.PPtr

@(private="file")
_test_capture_hook :: proc() -> undo.Selection_State {
	return {}
}

@(private="file")
_test_apply_hook :: proc(state: undo.Selection_State) {
	clear(&_applied_sel)
	append(&_applied_sel, ..state.proj)
}

@(test)
test_undo_selection_command :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	undo.set_selection_hooks(_test_capture_hook, _test_apply_hook)
	defer undo.set_selection_hooks(nil, nil)
	defer {
		delete(_applied_sel)
		_applied_sel = nil
	}

	undo.push_selection(s, _sel_state_proj(1), _sel_state_proj(2), "Select b.mat")
	testing.expect(t, undo.can_undo(s), "selection step recorded")

	undo.apply_undo(s)
	testing.expect_value(t, len(_applied_sel), 1)
	if len(_applied_sel) == 1 do testing.expect_value(t, _applied_sel[0].local_id, engine.Local_ID(1))

	undo.apply_redo(s)
	testing.expect_value(t, len(_applied_sel), 1)
	if len(_applied_sel) == 1 do testing.expect_value(t, _applied_sel[0].local_id, engine.Local_ID(2))
}

@(test)
test_undo_push_selection_skips_equal :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	undo.push_selection(s, _sel_state_proj(7), _sel_state_proj(7))
	testing.expect(t, !undo.can_undo(s), "equal states must not record")
}

@(test)
test_undo_purge_scenes_keeps_non_scene_entries :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	// Entry 1: scene-bound transform edit.
	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {1, 2, 3}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	// Entry 2: project-only selection step (no scene references).
	undo.push_selection(s, _sel_state_proj(1), _sel_state_proj(2))

	testing.expect_value(t, len(undo.entries(s)), 2)
	testing.expect_value(t, undo.top_index(s), 2)

	undo.purge_scenes(s)

	testing.expect_value(t, len(undo.entries(s)), 1)
	testing.expect_value(t, undo.top_index(s), 1)
	testing.expect(t, undo.can_undo(s), "surviving entry still undoable")

	// Purge counts as stack activity (the selection tracker re-baselines).
	testing.expect(t, undo.activity_consume(s), "purge marks activity")
	testing.expect(t, !undo.activity_consume(s), "activity consumed once")
}

@(test)
test_undo_purge_scene_specific :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	tH := engine.transform_new("N")
	tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	if tr == nil do return
	target := undo.make_transform_target(tH, offset_of(engine.Transform, position), typeid_of([3]f32))
	old_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	tr.position = {1, 2, 3}
	new_json := undo.capture_json(&tr.position, typeid_of([3]f32))
	undo.push_value(s, target, old_json, new_json)

	// Purging an unrelated scene keeps the entry.
	other: engine.Scene
	undo.purge_scene(s, &other)
	testing.expect_value(t, len(undo.entries(s)), 1)

	// Purging the owning scene drops it.
	undo.purge_scene(s, tr.scene)
	testing.expect_value(t, len(undo.entries(s)), 0)
	testing.expect(t, !undo.can_undo(s), "nothing left to undo")
}

@(private="file")
_asset_apply_calls: int

@(private="file")
_asset_apply_last_json: string

@(private="file")
_test_asset_apply :: proc(guid: engine.Asset_GUID, _: undo.Doc_Kind, json_bytes: []byte) -> bool {
	_asset_apply_calls += 1
	delete(_asset_apply_last_json)
	_asset_apply_last_json = strings.clone(string(json_bytes))
	return true
}

@(test)
test_undo_asset_target_routes_through_hook :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	undo.set_asset_apply(_test_asset_apply)
	defer undo.set_asset_apply(nil)
	_asset_apply_calls = 0
	defer {
		delete(_asset_apply_last_json)
		_asset_apply_last_json = ""
	}

	guid: engine.Asset_GUID
	guid[0] = 42
	target := undo.make_asset_target(guid, typeid_of(int))
	old_json := make([]byte, 1); old_json[0] = '1'
	new_json := make([]byte, 1); new_json[0] = '2'
	undo.push_value(s, target, old_json, new_json)

	undo.apply_undo(s)
	testing.expect_value(t, _asset_apply_calls, 1)
	testing.expect_value(t, _asset_apply_last_json, "1")

	undo.apply_redo(s)
	testing.expect_value(t, _asset_apply_calls, 2)
	testing.expect_value(t, _asset_apply_last_json, "2")
}

// --- Merged from play_undo_tests.odin ---

@(private = "file")
_hosts := [1]simulate.Host{{name = "play_undo_test", update = proc(dt: f32) {}, fixed_update = proc(dt: f32) {}}}

// Stands in for data Stop does not roll back (an asset, a project setting).
@(private = "file")
_setting: int

@(private = "file")
_set_intensity :: proc(owned: engine.Owned, p: ^engine.Light, v: f32) {
	undo.push_component_owner(owned.handle)
	defer undo.pop_owner()
	e := undo.edit_begin(owned.handle, &p.intensity, typeid_of(f32))
	p.intensity = v
	undo.edit_end(&e)
}

@(private = "file")
_light_in :: proc(sc: ^engine.Scene, lid: engine.Local_ID) -> ^engine.Light {
	tH, ok := engine.scene_find_selectable_transform_local_id(sc, lid)
	if !ok do return nil
	_, p := engine.transform_get_comp(tH, engine.Light)
	return p
}

@(private = "file")
_new_lamp :: proc(parent: engine.Transform_Handle, intensity: f32) -> (engine.Owned, ^engine.Light, engine.Local_ID) {
	tH := engine.transform_new("Lamp", parent)
	lid := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).local_id
	owned, p := engine.transform_get_or_add_comp(tH, engine.Light)
	if p != nil do p.intensity = intensity
	return owned, p, lid
}

@(test)
test_stop_drops_play_steps_and_keeps_steps_from_before_play :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	simulate.install({}, _hosts[:])
	defer simulate.install({}, nil)
	defer simulate.stop() // a failed expect must not leave the run going

	owned, p, lid := _new_lamp(engine.Transform_Handle(tc.scene.root.handle), 55)
	if p == nil do return
	_set_intensity(owned, p, 123) // before Play

	testing.expect(t, simulate.start(), "Play starts")
	_set_intensity(owned, p, 200) // during Play, a scene step
	_setting = 0
	se := undo.edit_raw_begin(&_setting, typeid_of(int), &_setting, typeid_of(int), "Setting")
	_setting = 7
	undo.edit_end(&se) // during Play, not a scene step
	testing.expect_value(t, len(s.items), 3)

	testing.expect(t, !undo.jump_to(s, 0), "a jump past the run's steps does nothing")
	testing.expect_value(t, undo.top_index(s), 3)

	// Through the Edit menu, the path Cmd+Z takes: its enabled predicate must
	// allow the run's steps while playing.
	editor._register_menu_items()
	defer menu.shutdown_menu()
	undone1, _ := menu.invoke_path("Edit/Undo")
	undone2, _ := menu.invoke_path("Edit/Undo")
	testing.expect(t, undone1 && undone2, "Edit/Undo undoes the run's two steps")
	testing.expect_value(t, p.intensity, f32(123))
	locked, _ := menu.invoke_path("Edit/Undo")
	testing.expect(t, !locked, "the step from before Play is locked while playing")
	redone1, _ := menu.invoke_path("Edit/Redo")
	redone2, _ := menu.invoke_path("Edit/Redo")
	testing.expect(t, redone1 && redone2, "Edit/Redo redoes them")
	testing.expect_value(t, _setting, 7)

	simulate.stop()
	testing.expect_value(t, len(s.items), 2)
	sc := engine.sm_scene_get_active()
	restored := _light_in(sc, lid)
	testing.expect(t, restored != nil && restored.intensity == 123, "Stop restores the value from before Play")

	testing.expect(t, undo.apply_undo(s), "the setting step from Play undoes")
	testing.expect_value(t, _setting, 0)
	testing.expect(t, undo.apply_undo(s), "the step from before Play undoes")
	restored = _light_in(sc, lid)
	testing.expect(t, restored != nil && restored.intensity == 55, "it reverts on the restored scene")
}

// One scene file loaded twice: both copies carry the same guid, so only the
// session id tells them apart after Stop reloads the played copy.
@(test)
test_undo_after_stop_finds_the_played_copy_of_a_twice_loaded_scene :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	simulate.install({}, _hosts[:])
	defer simulate.install({}, nil)
	defer simulate.stop()

	guid := engine.Asset_GUID{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	first := tc.scene
	first.asset_guid = guid
	_, first_lamp, first_lid := _new_lamp(engine.Transform_Handle(first.root.handle), 999)
	if first_lamp == nil do return

	second := engine.scene_new()
	second.asset_guid = guid
	engine.sm_scene_set_active(second)
	engine.scene_ensure_root(second)
	owned, p, lid := _new_lamp(engine.Transform_Handle(second.root.handle), 55)
	if p == nil do return
	_set_intensity(owned, p, 123) // before Play, in the second copy

	testing.expect(t, simulate.start(), "Play starts on the second copy")
	simulate.stop()

	played := engine.sm_scene_get_active()
	testing.expect(t, undo.apply_undo(s), "the step from before Play undoes")
	lamp := _light_in(played, lid)
	testing.expect(t, lamp != nil && lamp.intensity == 55, "it reverts in the copy that played")
	other := _light_in(first, first_lid)
	testing.expect(t, other != nil && other.intensity == 999, "the other copy is untouched")
}
