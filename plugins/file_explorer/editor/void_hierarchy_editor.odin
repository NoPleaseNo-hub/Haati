package file_explorer_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:mem"
import "core:slice"
import "core:path/filepath"
import "core:encoding/uuid"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import wnd "haati:editor/window"
import icons "haati:editor/icons"
import thm "haati:editor/theme"
import undo "haati:editor/undo"
import clip "haati:editor/clipboard"
import editor_visuals "haati:packages/editor_visuals"
import widgets "haati:editor/widgets"
import inspector "haati:editor/inspector"
import file_exp "haati:packages/file_explorer"
import cad_csg "haati:packages/cad_csg"
import cad_csg_editor "haati:packages/cad_csg/editor"
import control_rig "haati:packages/control_rig"
import physics3d "haati:packages/physics3d"

// ─────────────────────────────────────────────────────────────
// VOID HIERARCHY — GODOT & UNREAL STYLE SCENE TREE DOCK
// ─────────────────────────────────────────────────────────────
// High-performance, zero-garbage, cache-friendly scene hierarchy.
// Features:
// 1. One-click Godot Visibility Eye Toggle on each row
// 2. Component/Type Badges (Camera, Light, Mesh, Script, Physics, Audio, Rig)
// 3. Full keyboard shortcuts: Delete, F2, Ctrl+C, Ctrl+V, Ctrl+D, Type-Ahead (A-Z)
// 4. Unreal-style folder & node color coding
// 5. Drag & Drop reparenting + dropping assets from Void File Explorer
// ─────────────────────────────────────────────────────────────

@(private = "file") _vh_filter_buf:          [128]u8
@(private = "file") _vh_selected_tH:         engine.Transform_Handle = {}
@(private = "file") _vh_scroll_to_selected:  bool = false
@(private = "file") _vh_force_close_all:     bool = false

// Navigation and multi-selection lists (Zero heap allocations)
@(private = "file") _vh_nav_list:            [1024]engine.Transform_Handle
@(private = "file") _vh_nav_count:           int = 0
@(private = "file") _vh_anchor_tH:           engine.Transform_Handle = {}
@(private = "file") _vh_range_pending:        engine.Transform_Handle = {}
@(private = "file") _vh_visible_list:        [1024]engine.Transform_Handle
@(private = "file") _vh_visible_count:       int = 0
// Custom node tag colors (Unreal style) keyed by Transform local_id
@(private = "file") _vh_node_colors:         map[engine.Local_ID][4]f32

// Scene tree state & selection persistence across editor sessions
Void_Hierarchy_Scene_State :: struct {
	scene_path:          string,
	active_local_id:     i64,
	active_name:         string,
	expanded_local_ids:  [dynamic]i64,
	collapsed_local_ids: [dynamic]i64,
}

Void_Hierarchy_Prefs :: struct {
	last_scene_path: string,
	scenes:          [dynamic]Void_Hierarchy_Scene_State,
}

@(user_settings={name="Void Hierarchy"})
void_hierarchy_prefs: Void_Hierarchy_Prefs

@(private = "file") _vh_open_nodes:            map[engine.Local_ID]bool
@(private = "file") _vh_pending_open_nodes:    map[engine.Transform_Handle]bool
@(private = "file") _vh_pending_close_nodes: map[engine.Transform_Handle]bool
// Recursively marks `tH` and all of its descendants to collapse:
@(private = "file")
_vh_collapse_node_recursive :: proc(tH: engine.Transform_Handle, sc: ^engine.Scene) {
	w := engine.ctx_world()
	if w == nil || tH == {} || !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	if _vh_open_nodes == nil {
		_vh_open_nodes = make(map[engine.Local_ID]bool)
	}
	if _vh_pending_close_nodes == nil {
		_vh_pending_close_nodes = make(map[engine.Transform_Handle]bool)
	}
	// Mark this node closed in saved prefs AND in ImGui's pending queue
	_vh_open_nodes[t.local_id] = false
	_vh_pending_close_nodes[tH] = true
	delete_key(&_vh_pending_open_nodes, tH)
	// Recurse into every child transform in the scene
	curr_sc := t.scene if t.scene != nil else sc
	for child in t.children {
		if ch, ok := engine.scene_ref_resolve_transform(curr_sc, child, tH); ok {
			_vh_collapse_node_recursive(ch, curr_sc)
		} else if engine.pool_valid(&w.transforms, child.handle) {
			_vh_collapse_node_recursive(engine.Transform_Handle(child.handle), curr_sc)
		}
	}
}
@(private = "file") _vh_restored_scene_path:   string = ""
@(private = "file") _vh_restored_scene_ptr:    ^engine.Scene = nil
@(private = "file") _vh_dirty_prefs:           bool = false
@(private = "file") _vh_save_cooldown:         f32 = 0.0

// Deferred click handling for already-selected items (preserves multi-selection drag & drop)
@(private = "file") _vh_deferred_toggle_tH: engine.Transform_Handle = {}
@(private = "file") _vh_deferred_select_tH: engine.Transform_Handle = {}
@(private = "file") _vh_is_dragging:        bool = false
@(private = "file") _vh_show_instantiate_modal: bool = false
@(private = "file") _vh_instantiate_modal_open_pending: bool = false
@(private = "file") _vh_instantiate_force_root: bool = false
@(private = "file") _vh_instantiate_search_buf: [128]u8
@(private = "file") _vh_selected_scene_guid: engine.Asset_GUID
@(private = "file") _vh_node_right_clicked_or_hovered: bool = false

// Separate / Move Selected Objects to New Scene modal state
@(private = "file") _vh_show_separate_scene_modal:      bool = false
@(private = "file") _vh_separate_modal_open_pending:    bool = false
@(private = "file") _vh_separate_into_existing_mode:    bool = false
@(private = "file") _vh_separate_existing_target_buf:   [256]u8
@(private = "file") _vh_separate_existing_target_len:   int = 0
@(private = "file") _vh_separate_scene_filter_buf:      [128]u8
@(private = "file") _vh_separate_new_subfolder_buf:     [128]u8
@(private = "file") _vh_separate_show_new_subfolder:    bool = false
@(private = "file") _vh_separate_scene_name_buf:        [128]u8
@(private = "file") _vh_separate_scene_dir_buf:         [256]u8
@(private = "file") _vh_separate_remove_originals:      bool = true
@(private = "file") _vh_separate_replace_with_instance: bool = false
@(private = "file") _vh_separate_center_at_origin:      bool = false
@(private = "file") _vh_separate_save_current_scene:    bool = true

// Quick Scene Switcher & Session Scene Navigation History
@(private = "file") _vh_scene_nav_search_buf:           [128]u8
@(private = "file") _vh_scene_nav_new_name_buf:         [128]u8
@(private = "file") _vh_scene_nav_show_new_input:       bool = false
@(private = "file") _vh_scene_nav_rename_buf:           [128]u8
@(private = "file") _vh_scene_nav_show_rename_input:    bool = false
@(private = "file") _vh_auto_save_on_scene_switch:      bool = true
@(private = "file") _vh_prev_scene_path_buf:            [512]u8
@(private = "file") _vh_prev_scene_path_len:            int = 0
@(private = "file") _vh_recent_scenes_buf:              [12][512]u8
@(private = "file") _vh_recent_scenes_len:              [12]int
@(private = "file") _vh_recent_scenes_count:            int = 0

// Searchable Add Node / Add Component & New Odin Component Script Modal state
@(private = "file") _vh_add_node_search_buf:            [128]u8
@(private = "file") _vh_attach_comp_search_buf:         [128]u8
@(private = "file") _vh_show_new_comp_modal:            bool = false
@(private = "file") _vh_new_comp_modal_open_pending:    bool = false
@(private = "file") _vh_new_comp_name_buf:              [128]u8
@(private = "file") _vh_new_comp_folder_buf:            [256]u8

// Multi-selection drag & drop payload
VH_Drag_Payload :: struct {
	count:   int,
	handles: [64]engine.Transform_Handle,
}

@(private = "file")
_vh_is_ancestor :: proc(potential_ancestor: engine.Transform_Handle, node: engine.Transform_Handle) -> bool {
	if potential_ancestor == {} || node == {} do return false
	w := engine.ctx_world()
	cur := node
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		if !engine.pool_valid(&w.transforms, t.parent.handle) do break
		parent := engine.Transform_Handle(t.parent.handle)
		if parent == potential_ancestor do return true
		cur = parent
	}
	return false
}

// Node Badge representation (Godot style)
Node_Badge :: struct {
	icon:      cstring,
	color:     [4]f32,
	type_name: string,
}

@(private = "file")
_vh_node_find_code_key :: proc(t: ^engine.Transform) -> (key: engine.TypeKey, type_name: string, ok: bool) {
	if t == nil do return {}, "", false
	for c in t.components {
		if c.handle.type_key == engine.INVALID_TYPE_KEY do continue
		path, _, has_loc := inspector.component_source_location(c.handle.type_key)
		if has_loc && len(path) > 0 {
			tid := engine.get_typeid_by_type_key(c.handle.type_key)
			name := tid != nil ? fmt.tprintf("%v", tid) : "Script"
			return c.handle.type_key, name, true
		}
	}
	return {}, "", false
}

@(private = "file")
_vh_node_find_ancestor_armature_code_key :: proc(tH: engine.Transform_Handle) -> (key: engine.TypeKey, type_name: string, ok: bool) {
	w := engine.ctx_world()
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		for c in t.components {
			if c.handle.type_key == engine.INVALID_TYPE_KEY do continue
			if c.handle.type_key == .ControlRig || c.handle.type_key == .ArmatureDeformedMesh {
				path, _, has_loc := inspector.component_source_location(c.handle.type_key)
				if has_loc && len(path) > 0 {
					tid := engine.get_typeid_by_type_key(c.handle.type_key)
					name := tid != nil ? fmt.tprintf("%v", tid) : "Armature Code"
					return c.handle.type_key, name, true
				}
			}
		}
		if !engine.pool_valid(&w.transforms, t.parent.handle) do break
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return {}, "", false
}

@(private = "file")
_vh_get_badge :: proc(t: ^engine.Transform, tH: engine.Transform_Handle = {}, sc: ^engine.Scene = nil) -> Node_Badge {
	if sc != nil && tH != {} && engine.scene_hierarchy_transform_is_nested_scene_host(sc, tH) {
		return {icons.ICON_MD_PLAY_CIRCLE, {0.30, 0.75, 1.0, 1.0}, "Scene"}
	}
	if t.nested_owned {
		return {icons.ICON_MD_STACKS, {0.35, 0.70, 1.0, 1.0}, "Prefab"}
	}
	if len(t.components) == 0 {
		return {icons.ICON_MD_ACCOUNT_TREE, {0.75, 0.78, 0.85, 1.0}, "GameObject"}
	}

	// First pass: high-priority specialized components (CSGVolume / Faker CSG / ControlRig / Armature)
	// When a Mesh entity is converted to CSG or Faker CSG in-place, `.CSGVolume` is appended after
	// `.MeshFilter` in `t.components`; scanning for `.CSGVolume` first ensures converted meshes
	// immediately display "CSG" / "Faker CSG" instead of staying stuck on "Mesh"!
	for c in t.components {
		if c.handle.type_key == engine.INVALID_TYPE_KEY do continue
		if c.handle.type_key == .CSGVolume {
			if w := engine.ctx_world(); w != nil {
				if vol := engine.pool_get(cad_csg.csg_volumes(w), c.handle); vol != nil && vol.is_faker_mesh {
					return {icons.ICON_MD_LAYERS, {0.18, 0.92, 0.85, 1.0}, "Faker CSG"}
				}
			}
			return {icons.ICON_MD_WIDGETS, {1.0, 0.65, 0.18, 1.0}, "CSG"}
		}
		if c.handle.type_key == .ControlRig || c.handle.type_key == .ArmatureDeformedMesh {
			return {icons.ICON_MD_ANIMATION, {0.75, 0.45, 0.95, 1.0}, "Rig"}
		}
	}

	for c in t.components {
		if c.handle.type_key == engine.INVALID_TYPE_KEY do continue
		tid := engine.get_typeid_by_type_key(c.handle.type_key)
		if tid == nil do continue
		name := fmt.tprintf("%v", tid)
		name_lower := strings.to_lower(name, context.temp_allocator)

		if strings.contains(name_lower, "springarm") {
			return {icons.ICON_MD_OPEN_WITH, {1.0, 0.72, 0.18, 1.0}, "SpringArm3D"}
		}
		if strings.contains(name_lower, "camera") {
			return {icons.ICON_MD_VISIBILITY, {0.20, 0.85, 0.95, 1.0}, "Camera"}
		}
		if strings.contains(name_lower, "light") {
			return {icons.ICON_MD_RECORD, {1.0, 0.82, 0.20, 1.0}, "Light"}
		}
		if strings.contains(name_lower, "mesh") || strings.contains(name_lower, "renderer") {
			return {icons.ICON_MD_DEPLOYED_CODE, {0.30, 0.65, 0.95, 1.0}, "Mesh"}
		}
		if strings.contains(name_lower, "audio") {
			return {icons.ICON_MD_VOLUME_UP, {0.95, 0.40, 0.70, 1.0}, "Audio"}
		}
		if strings.contains(name_lower, "collider") || strings.contains(name_lower, "rigid") || strings.contains(name_lower, "physics") {
			return {icons.ICON_MD_WIDGETS, {0.95, 0.55, 0.15, 1.0}, "Physics"}
		}
		if strings.contains(name_lower, "sprite") {
			return {icons.ICON_MD_IMAGE, {0.25, 0.85, 0.55, 1.0}, "Sprite"}
		}
		if strings.contains(name_lower, "anim") || strings.contains(name_lower, "tween") || strings.contains(name_lower, "sequencer") {
			return {icons.ICON_MD_ANIMATION, {0.75, 0.45, 0.95, 1.0}, "Animation"}
		}
		if strings.contains(name_lower, "text") {
			return {icons.ICON_MD_DESCRIPTION, {0.85, 0.85, 0.90, 1.0}, "Text"}
		}
		if strings.contains(name_lower, "player") || strings.contains(name_lower, "script") || strings.contains(name_lower, "void") {
			return {icons.ICON_MD_CODE, {0.20, 0.95, 0.50, 1.0}, "Script"}
		}
	}

	return {icons.ICON_MD_CODE, {0.45, 0.85, 0.55, 1.0}, "Component"}
}

// ─────────────────────────────────────────────────────────────
// STATE PERSISTENCE & RESTORATION
// ─────────────────────────────────────────────────────────────

@(private = "file")
_vh_mark_prefs_dirty :: proc() {
	_vh_dirty_prefs = true
	_vh_save_cooldown = 0.0
}

@(private = "file")
_vh_scene_key :: proc(scene: ^engine.Scene) -> string {
	if scene == nil do return "default"
	if len(scene.path) > 0 do return scene.path
	if scene.asset_guid != (engine.Asset_GUID{}) {
		if p, ok := engine.asset_db_get_path(uuid.Identifier(scene.asset_guid)); ok {
			return p
		}
	}
	return "default"
}

@(private = "file")
_vh_find_transform_by_name :: proc(scene: ^engine.Scene, name: string) -> engine.Transform_Handle {
	if scene == nil || len(name) == 0 do return {}
	w := engine.ctx_world()
	if w == nil do return {}

	find_recursive :: proc(tH: engine.Transform_Handle, sc: ^engine.Scene, name: string, w: ^engine.World) -> engine.Transform_Handle {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return {}
		if t.name == name do return tH
		for child in t.children {
			ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
			if !ok && engine.pool_valid(&w.transforms, child.handle) {
				ch = engine.Transform_Handle(child.handle)
				ok = true
			}
			if ok {
				if found := find_recursive(ch, sc, name, w); found != {} do return found
			}
		}
		return {}
	}

	return find_recursive(engine.Transform_Handle(scene.root.handle), scene, name, w)
}

@(private = "file")
_vh_reveal_ancestors :: proc(target_h: engine.Transform_Handle) {
	if target_h == {} do return
	w := engine.ctx_world()
	if w == nil do return

	if _vh_open_nodes == nil {
		_vh_open_nodes = make(map[engine.Local_ID]bool)
	}
	if _vh_pending_open_nodes == nil {
		_vh_pending_open_nodes = make(map[engine.Transform_Handle]bool)
	}

	cur := target_h
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		if !engine.pool_valid(&w.transforms, t.parent.handle) do break
		parent_h := engine.Transform_Handle(t.parent.handle)
		parent_t := engine.pool_get(&w.transforms, engine.Handle(parent_h))
		if parent_t != nil {
			_vh_open_nodes[parent_t.local_id] = true
			_vh_pending_open_nodes[parent_h] = true
		}
		cur = parent_h
	}
}

@(private = "file")
_vh_restore_scene_state :: proc(scene: ^engine.Scene) {
	if scene == nil do return
	if len(scene.path) > 0 {
		sc_disk := _vh_normalize_scene_disk_path(scene.path, context.temp_allocator)
		if len(sc_disk) > 0 && !os.exists(sc_disk) {
			sc_dir := filepath.dir(sc_disk) // slice into sc_disk — do NOT delete!
			if os.is_dir(sc_dir) {
				if dh, derr := os.open(sc_dir); derr == nil {
					defer os.close(dh)
					if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
						scene_cand := ""
						scene_count := 0
						for fi in entries {
							if fi.type != .Directory && strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), ".scene") {
								joined, _ := filepath.join({sc_dir, fi.name}, context.temp_allocator)
								norm_j, _ := strings.replace_all(joined, "\\", "/", context.temp_allocator)
								scene_cand = norm_j
								scene_count += 1
							}
						}
						if scene_count == 1 && len(scene_cand) > 0 {
							delete(scene.path)
							scene.path = strings.clone(scene_cand)
						}
					}
				}
			}
		}
	}
	path_key := _vh_scene_key(scene)

	if _vh_restored_scene_ptr == scene && _vh_restored_scene_path == path_key {
		return
	}
	if len(_vh_restored_scene_path) > 0 do delete(_vh_restored_scene_path)
	_vh_restored_scene_path = strings.clone(path_key)
	_vh_restored_scene_ptr = scene

	if _vh_open_nodes == nil {
		_vh_open_nodes = make(map[engine.Local_ID]bool)
	}
	if _vh_pending_open_nodes == nil {
		_vh_pending_open_nodes = make(map[engine.Transform_Handle]bool)
	}

	// Always ensure scene root is open
	w := engine.ctx_world()
	if w != nil && engine.pool_valid(&w.transforms, scene.root.handle) {
		root_h := engine.Transform_Handle(scene.root.handle)
		if root_t := engine.pool_get(&w.transforms, scene.root.handle); root_t != nil {
			_vh_open_nodes[root_t.local_id] = true
			_vh_pending_open_nodes[root_h] = true
		}
	}

	// Find saved state entry
	entry_idx := -1
	for s, i in void_hierarchy_prefs.scenes {
		if s.scene_path == path_key || (len(void_hierarchy_prefs.scenes) == 1 && (s.scene_path == "" || path_key == "default")) {
			entry_idx = i
			break
		}
	}
	if entry_idx == -1 do return

	st := &void_hierarchy_prefs.scenes[entry_idx]

	// Restore expansion states
	for lid in st.expanded_local_ids {
		_vh_open_nodes[engine.Local_ID(lid)] = true
	}
	for lid in st.collapsed_local_ids {
		_vh_open_nodes[engine.Local_ID(lid)] = false
	}

	// Find target active handle
	target_h: engine.Transform_Handle = {}
	if st.active_local_id != 0 {
		if h, ok := engine.bimap_get(&scene.local_ids, engine.Local_ID(st.active_local_id)); ok {
			if h.type_key == .Transform && engine.pool_valid(&w.transforms, h) {
				target_h = engine.Transform_Handle(h)
			}
		}
	}

	if target_h == {} && len(st.active_name) > 0 {
		target_h = _vh_find_transform_by_name(scene, st.active_name)
	}

	if target_h != {} {
		_vh_reveal_ancestors(target_h)
		_vh_select_node(target_h)
		_vh_scroll_to_selected = true
		fmt.printfln("[Void Hierarchy] Restored scene state for '%s': selected '%s' (local_id: %d)", path_key, st.active_name, st.active_local_id)
	}
}

@(private = "file")
_vh_sync_scene_state :: proc(scene: ^engine.Scene) {
	if scene == nil do return
	path_key := _vh_scene_key(scene)

	entry_idx := -1
	for s, i in void_hierarchy_prefs.scenes {
		if s.scene_path == path_key {
			entry_idx = i
			break
		}
	}
	if entry_idx == -1 {
		new_state := Void_Hierarchy_Scene_State{
			scene_path = strings.clone(path_key),
		}
		append(&void_hierarchy_prefs.scenes, new_state)
		entry_idx = len(void_hierarchy_prefs.scenes) - 1
	}

	st := &void_hierarchy_prefs.scenes[entry_idx]
	if void_hierarchy_prefs.last_scene_path != path_key {
		if len(void_hierarchy_prefs.last_scene_path) > 0 do delete(void_hierarchy_prefs.last_scene_path)
		void_hierarchy_prefs.last_scene_path = strings.clone(path_key)
	}

	// Update active selection
	w := engine.ctx_world()
	active_h := _vh_selected_tH
	if active_h == {} do active_h = engine.inspector_active_selection()
	if active_h != {} && w != nil && engine.pool_valid(&w.transforms, engine.Handle(active_h)) {
		t := engine.pool_get(&w.transforms, engine.Handle(active_h))
		if t != nil {
			st.active_local_id = i64(t.local_id)
			if len(st.active_name) > 0 do delete(st.active_name)
			st.active_name = strings.clone(t.name)
		}
	}

	// Update expanded / collapsed lists
	clear(&st.expanded_local_ids)
	clear(&st.collapsed_local_ids)
	for lid, is_open in _vh_open_nodes {
		if is_open {
			append(&st.expanded_local_ids, i64(lid))
		} else {
			append(&st.collapsed_local_ids, i64(lid))
		}
	}
}

@(private = "file")
_vh_save_prefs :: proc(scene: ^engine.Scene) {
	if scene != nil {
		_vh_sync_scene_state(scene)
	}
	engine.user_settings_save("Void Hierarchy", &void_hierarchy_prefs, typeid_of(Void_Hierarchy_Prefs))
}

@(private = "file")
_vh_tick_save :: proc(scene: ^engine.Scene, dt: f32) {
	if !_vh_dirty_prefs do return
	_vh_save_cooldown += dt
	if _vh_save_cooldown >= 0.5 {
		_vh_save_prefs(scene)
		_vh_dirty_prefs = false
		_vh_save_cooldown = 0.0
	}
}

// ─────────────────────────────────────────────────────────────
// OPERATIONS & KEYBOARD SHORTCUTS
// ─────────────────────────────────────────────────────────────

@(private = "file")
_vh_select_node :: proc(tH: engine.Transform_Handle, ping: bool = false) {
	_vh_selected_tH = tH
	_vh_anchor_tH = tH
	_vh_deferred_toggle_tH = {}
	_vh_deferred_select_tH = {}
	engine.inspector_request_selection_op(tH, .Set)
	engine.inspector_set_active_selection(tH)
	engine.inspector_set_inspected_selection(tH)
	one := [1]engine.Transform_Handle{tH}
	engine.inspector_set_selection_all(one[:])
	if ping {
		engine.inspector_request_ping(tH)
	}
	_vh_mark_prefs_dirty()
}

@(private = "file")
_vh_toggle_select_node :: proc(tH: engine.Transform_Handle) {
	// Sync local and engine selection immediately for zero-latency UI response
	all := engine.inspector_selection_all()
	new_all := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	found := false
	for h in all {
		if h == tH {
			found = true
		} else {
			append(&new_all, h)
		}
	}
	if !found {
		append(&new_all, tH)
	}

	engine.inspector_request_selection_batch(new_all[:])
	engine.inspector_set_selection_all(new_all[:])

	if !found {
		engine.inspector_set_active_selection(tH)
		engine.inspector_set_inspected_selection(tH)
		_vh_selected_tH = tH
		_vh_anchor_tH = tH
	} else if len(new_all) > 0 {
		last := new_all[len(new_all) - 1]
		engine.inspector_set_active_selection(last)
		engine.inspector_set_inspected_selection(last)
		_vh_selected_tH = last
		_vh_anchor_tH = last
	} else {
		engine.inspector_set_active_selection({})
		engine.inspector_set_inspected_selection({})
		_vh_selected_tH = {}
		_vh_anchor_tH = {}
	}
	_vh_mark_prefs_dirty()
}

@(private = "file")
_vh_range_select_node :: proc(target: engine.Transform_Handle) {
	anchor := _vh_anchor_tH
	if anchor == {} {
		anchor = _vh_selected_tH
	}
	if anchor == {} {
		anchor = engine.inspector_active_selection()
	}
	if anchor == {} {
		_vh_select_node(target)
		return
	}

	a_idx := -1
	t_idx := -1
	for i in 0 ..< _vh_nav_count {
		h := _vh_nav_list[i]
		if h == anchor do a_idx = i
		if h == target do t_idx = i
	}

	if a_idx == -1 || t_idx == -1 {
		_vh_select_node(target)
		return
	}

	range_handles := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	step := 1 if a_idx <= t_idx else -1
	for i := a_idx; ; i += step {
		append(&range_handles, _vh_nav_list[i])
		if i == t_idx do break
	}

	engine.inspector_request_selection_batch(range_handles[:])
	engine.inspector_set_selection_all(range_handles[:])
	engine.inspector_set_active_selection(target)
	engine.inspector_set_inspected_selection(target)
	_vh_selected_tH = target
	_vh_mark_prefs_dirty()
	// Anchor stays unchanged to allow extending the range with subsequent Shift+clicks
}

@(private = "file")
_vh_delete_selected :: proc() {
	all_sel := engine.inspector_selection_all()
	w := engine.ctx_world()
	if w == nil do return

	targets := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	if len(all_sel) > 0 {
		for h in all_sel {
			if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil || t.parent.handle == {} do continue
			append(&targets, h)
		}
	} else if _vh_selected_tH != {} && engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) {
		t := engine.pool_get(&w.transforms, engine.Handle(_vh_selected_tH))
		if t != nil && t.parent.handle != {} {
			append(&targets, _vh_selected_tH)
		}
	}

	if len(targets) == 0 do return

	g := undo.group_begin("Delete Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		undo.record_delete(h)
	}
	undo.group_commit(&g)

	_vh_selected_tH = {}
	_vh_anchor_tH = {}
	engine.inspector_request_selection_op({}, .Clear)
	engine.inspector_set_active_selection({})
	engine.inspector_set_inspected_selection({})
	_vh_mark_prefs_dirty()
}

@(private = "file")
_vh_begin_rename :: proc(tH: engine.Transform_Handle) {
	if tH == {} do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	wnd.show_rename_dialog("Rename Entity", t.name, proc(new_name: string) {
		trimmed := strings.trim_space(new_name)
		if len(trimmed) == 0 do return
		w := engine.ctx_world()
		active := engine.inspector_active_selection()
		if active != {} && engine.pool_valid(&w.transforms, engine.Handle(active)) {
			t := engine.pool_get(&w.transforms, engine.Handle(active))
			if t != nil {
				delete(t.name)
				t.name = strings.clone(trimmed)
				engine.transform_ensure_unique_name(active)
				if t.scene != nil do t.scene.dirty = true
			}
		}
	})
}

@(private = "file")
_vh_copy_selected :: proc() {
	if _vh_selected_tH == {} do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) do return

	data := engine.scene_copy_subtree(_vh_selected_tH)
	clip.copy_hierarchy(data)
	fmt.printfln("[Void Hierarchy] Copied entity to clipboard")
}

@(private = "file")
_vh_paste_under_selected :: proc() {
	if !clip.has_hierarchy() do return
	target := _vh_selected_tH
	w := engine.ctx_world()

	// If no selection or invalid, paste under active scene root
	if target == {} || !engine.pool_valid(&w.transforms, engine.Handle(target)) {
		scene := engine.sm_scene_get_active()
		if scene == nil do return
		target = engine.Transform_Handle(scene.root.handle)
	}

	result := engine.scene_paste_subtree(clip.paste_hierarchy(), target)
	if result != {} {
		undo.record_create(result, target)
		engine.transform_ensure_unique_name(result)
		_vh_select_node(result, ping = true)
		_vh_scroll_to_selected = true
		fmt.printfln("[Void Hierarchy] Pasted entity")
	}
}

@(private = "file")
_vh_duplicate_selected :: proc() {
	all_sel := engine.inspector_selection_all()
	w := engine.ctx_world()
	if w == nil do return

	if len(all_sel) > 1 {
		new_handles := make([dynamic]engine.Transform_Handle, context.temp_allocator)
		g := undo.group_begin("Duplicate Entities")
		defer undo.group_end(&g)
		undo.record_selection_snapshot()

		for h in all_sel {
			if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil do continue
			parentH := engine.Transform_Handle(t.parent.handle)
			result := engine.scene_duplicate_subtree(h)
			if result != {} {
				undo.record_create(result, parentH)
				engine.transform_ensure_unique_name(result)
				append(&new_handles, result)
			}
		}
		if len(new_handles) > 0 {
			undo.group_commit(&g)
			engine.inspector_request_selection_batch(new_handles[:])
			_vh_selected_tH = new_handles[len(new_handles) - 1]
			_vh_scroll_to_selected = true
			fmt.printfln("[Void Hierarchy] Duplicated %d entities", len(new_handles))
		}
		return
	}

	if _vh_selected_tH == {} do return
	if !engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) do return

	t := engine.pool_get(&w.transforms, engine.Handle(_vh_selected_tH))
	if t == nil do return
	parentH := engine.Transform_Handle(t.parent.handle)

	g := undo.group_begin("Duplicate Entity")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	result := engine.scene_duplicate_subtree(_vh_selected_tH)
	if result != {} {
		undo.record_create(result, parentH)
		engine.transform_ensure_unique_name(result)
		undo.group_commit(&g)
		_vh_select_node(result, ping = true)
		_vh_scroll_to_selected = true
		fmt.printfln("[Void Hierarchy] Duplicated entity")
	}
}

@(private = "file")
_vh_create_node_with_components :: proc(name: string, comp_keys: []engine.TypeKey = nil, force_root: bool = false) {
	parentH := _vh_selected_tH
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if scene == nil do return

	if force_root || parentH == {} || !engine.pool_valid(&w.transforms, engine.Handle(parentH)) {
		parentH = engine.Transform_Handle(scene.root.handle)
	}

	g := undo.group_begin(fmt.tprintf("Create %s", name))
	defer undo.group_end(&g)
	undo.record_selection_snapshot()

	newH := engine.transform_new(name, parentH)
	undo.record_create(newH, parentH)
	engine.transform_ensure_unique_name(newH)

	// If parenting under a scaled parent, normalize local scale so world scale is [1, 1, 1]
	t := engine.pool_get(&w.transforms, engine.Handle(newH))
	if t != nil && parentH != engine.Transform_Handle(scene.root.handle) {
		pw := engine.transform_world(parentH)
		safe_scale := [3]f32{
			pw.scale.x != 0 ? pw.scale.x : 1,
			pw.scale.y != 0 ? pw.scale.y : 1,
			pw.scale.z != 0 ? pw.scale.z : 1,
		}
		t.scale = [3]f32{1, 1, 1} / safe_scale
		// If parenting directly under a SpringArm3D, place the new child right at the tip of the SpringArm!
		if _, arm := physics3d.get_comp(parentH, physics3d.SpringArm3D); arm != nil {
			t.position = physics3d.spring_arm_tip_local(arm, arm.spring_length)
		}
	}

	for key in comp_keys {
		owned, ptr := engine.transform_add_comp(newH, key)
		if ptr != nil {
			if key == .MeshFilter {
				if mf := cast(^engine.MeshFilter)ptr; mf != nil {
					if guid, err := uuid.read("9b978885-12f8-4d30-be4d-d9c2c2074477"); err == nil {
						mf.mesh = engine.PPtr{guid = engine.Asset_GUID(guid)}
					}
				}
			} else if key == .MeshRenderer {
				if mr := cast(^engine.MeshRenderer)ptr; mr != nil {
					if guid, err := uuid.read("86518465-b823-4eb9-b3f5-c0deef450fc6"); err == nil {
						append(&mr.materials, engine.Asset_GUID(guid))
					}
				}
			} else if key == .Light {
				if l := cast(^engine.Light)ptr; l != nil {
					engine.reset_Light(l)
					if strings.contains(name, "Point") {
						l.type = .Point
						l.intensity = 1.6
						l.range = 14.0
					} else if strings.contains(name, "Spot") {
						l.type = .Spot
						l.intensity = 2.0
						l.range = 16.0
						l.spot_angle = 42.0
						l.inner_spot_angle = 28.0
					}
				}
				if t_light := engine.pool_get(&w.transforms, engine.Handle(newH)); t_light != nil {
					if t_light.position == {} {
						t_light.position = {0, 6.0, 0}
					}
					if t_light.rotation == engine.QUAT_IDENTITY {
						// Default downward sun/spot angle (-50 deg pitch, +35 deg yaw) so shadows work immediately
						t_light.rotation = {-0.402641, 0.272532, 0.127084, 0.864361}
					}
				}
			} else if key == .Camera {
				if c := cast(^engine.Camera)ptr; c != nil {
					c.fov = 60.0
					c.near_clip = 0.3
					c.far_clip = 1000.0
				}
			}
			t_curr := engine.pool_get(&w.transforms, engine.Handle(newH))
			if t_curr != nil {
				undo.record_add_component(newH, owned.handle, len(t_curr.components) - 1)
			}
		}
	}

	scene.dirty = true
	undo.group_commit(&g)
	_vh_select_node(newH, ping = true)
	_vh_scroll_to_selected = true
}

@(private = "file")
_vh_create_empty_child :: proc(name: string = "Node") {
	_vh_create_node_with_components(name, nil, force_root = false)
}

@(private = "package")
_vh_attach_component_to_node :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> bool {
	w := engine.ctx_world()
	if w == nil || tH == {} || !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return false
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return false
	_, existing_idx := engine.transform_find_comp(t, key)
	if existing_idx >= 0 do return false

	g := undo.group_begin(fmt.tprintf("Add %v", key))
	defer undo.group_end(&g)

	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return false
	t_curr := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t_curr != nil {
		undo.record_add_component(tH, owned.handle, len(t_curr.components) - 1)
		if t_curr.scene != nil do t_curr.scene.dirty = true
	}
	if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
	undo.group_commit(&g)
	_vh_select_node(tH, ping = false)
	return true
}

@(private = "package")
_vh_classify_component_key :: proc(key: engine.TypeKey, src_path: string) -> (category: string, icon: cstring, col: im.Vec4) {
	p_lower := strings.to_lower(src_path, context.temp_allocator)
	if strings.contains(p_lower, "void_odin") {
		return "Void / Custom Scripts", icons.ICON_MD_CODE, {0.20, 0.95, 0.55, 1.0}
	}
	if key == .SpringArm3D {
		return "Physics 3D", icons.ICON_MD_OPEN_WITH, {1.0, 0.72, 0.18, 1.0}
	}
	if strings.contains(p_lower, "physics3d") || key == .SpringBone {
		return "Physics 3D", icons.ICON_MD_WIDGETS, {0.95, 0.58, 0.18, 1.0}
	}
	if (strings.contains(p_lower, "control_rig") || strings.contains(p_lower, "animation")) && !strings.contains(p_lower, "sequencer/track") && !strings.contains(p_lower, "animation_sample") {
		return "Animation & Control Rig", icons.ICON_MD_ANIMATION, {0.78, 0.48, 0.98, 1.0}
	}
	if key == .Camera {
		return "3D & Rendering", icons.ICON_MD_VISIBILITY, {0.20, 0.85, 0.95, 1.0}
	}
	if key == .Light {
		return "3D & Rendering", icons.ICON_MD_RECORD, {1.0, 0.82, 0.20, 1.0}
	}
	if key == .MeshFilter || key == .MeshRenderer || key == .SkinnedMeshRenderer || key == .ParticleSystem || key == .CSGVolume {
		return "3D & Rendering", icons.ICON_MD_DEPLOYED_CODE, {0.30, 0.72, 0.98, 1.0}
	}
	if strings.contains(p_lower, "audio") && !strings.contains(p_lower, "sequencer") {
		return "Audio", icons.ICON_MD_VOLUME_UP, {0.95, 0.42, 0.70, 1.0}
	}
	if strings.contains(p_lower, "physics2d") || strings.contains(p_lower, "sprites") {
		return "2D Nodes", icons.ICON_MD_IMAGE, {0.25, 0.85, 0.55, 1.0}
	}
	if strings.contains(p_lower, "ui_canvas") || strings.contains(p_lower, "mhgui") || strings.contains(p_lower, "text") {
		return "UI Controls", icons.ICON_MD_LAYERS, {0.85, 0.85, 0.92, 1.0}
	}
	if strings.contains(p_lower, "sequencer") || strings.contains(p_lower, "tween") {
		return "Timeline & Tween", icons.ICON_MD_PLAY_CIRCLE, {0.55, 0.75, 0.95, 1.0}
	}
	return "Gameplay & Misc", icons.ICON_MD_CODE, {0.55, 0.85, 0.65, 1.0}
}

@(private = "package")
_vh_sanitize_odin_identifier :: proc(raw: string) -> string {
	trimmed := strings.trim_space(raw)
	if strings.has_suffix(strings.to_lower(trimmed, context.temp_allocator), ".odin") {
		trimmed = trimmed[:len(trimmed) - 5]
	}
	clean_b := strings.builder_make(context.temp_allocator)
	for r, idx in trimmed {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_' || (idx > 0 && r >= '0' && r <= '9') {
			strings.write_rune(&clean_b, r)
		}
	}
	return strings.to_string(clean_b)
}

@(private = "package")
_vh_sanitize_odin_subfolder :: proc(raw_folder: string) -> string {
	norm, _ := strings.replace_all(strings.trim_space(raw_folder), "\\", "/", context.temp_allocator)
	norm = strings.trim(norm, "/")
	for prefix in ([?]string{"../plugins/void_odin/", "plugins/void_odin/", "haati/packages/void_odin/", "packages/void_odin/", "void_odin/"}) {
		if strings.has_prefix(norm, prefix) {
			norm = strings.trim(norm[len(prefix):], "/")
			break
		}
	}
	if norm == "plugins/void_odin" || norm == "void_odin" || norm == "." {
		return ""
	}
	if len(norm) == 0 do return ""

	parts := strings.split(norm, "/", context.temp_allocator)
	clean_b := strings.builder_make(context.temp_allocator)
	first := true
	for part in parts {
		p := strings.trim_space(part)
		if len(p) == 0 || p == "." || p == ".." do continue
		seg := _vh_sanitize_odin_identifier(p)
		if len(seg) == 0 do continue
		if !first do strings.write_byte(&clean_b, '/')
		strings.write_string(&clean_b, seg)
		first = false
	}
	return strings.to_string(clean_b)
}

@(private = "package")
_vh_default_odin_component_folder :: proc() -> string {
	if scene := engine.sm_scene_get_active(); scene != nil && len(scene.path) > 0 {
		norm_path, _ := strings.replace_all(scene.path, "\\", "/", context.temp_allocator)
		dir_norm, _ := strings.replace_all(filepath.dir(norm_path), "\\", "/", context.temp_allocator)
		for marker in ([?]string{"plugins/void_odin", "packages/void_odin"}) {
			if idx := strings.index(dir_norm, marker); idx >= 0 {
				sub := strings.trim(dir_norm[idx + len(marker):], "/")
				return _vh_sanitize_odin_subfolder(sub)
			}
		}
	}
	return ""
}

@(private = "package")
_vh_compute_odin_package_name :: proc(rel_sub_folder: string) -> string {
	clean_sub := _vh_sanitize_odin_subfolder(rel_sub_folder)
	if len(clean_sub) == 0 do return "void_odin"
	flat_sub, _ := strings.replace_all(clean_sub, "/", "_", context.temp_allocator)
	return fmt.tprintf("void_odin_%s", flat_sub)
}

@(private = "file")
_vh_make_directories_recursive :: proc(dir_path: string) {
	norm, _ := strings.replace_all(dir_path, "\\", "/", context.temp_allocator)
	parts := strings.split(norm, "/", context.temp_allocator)
	accum := strings.builder_make(context.temp_allocator)
	for part, idx in parts {
		if len(part) == 0 {
			if idx == 0 do strings.write_byte(&accum, '/')
			continue
		}
		if strings.builder_len(accum) > 0 && strings.to_string(accum) != "/" {
			strings.write_byte(&accum, '/')
		}
		strings.write_string(&accum, part)
		cur := strings.to_string(accum)
		if strings.ends_with(part, ":") do continue
		if !os.exists(cur) {
			_ = os.make_directory(cur)
		}
	}
}

@(private = "package")
_vh_default_odin_component_name :: proc(node_name: string = "") -> string {
	candidate := _vh_sanitize_odin_identifier(node_name)
	if len(candidate) > 0 && candidate != "Root" && candidate != "GameObject" && candidate != "Node" {
		return candidate
	}
	if scene := engine.sm_scene_get_active(); scene != nil {
		if len(scene.path) > 0 {
			stem := _vh_sanitize_odin_identifier(filepath.stem(scene.path))
			if len(stem) > 0 && stem != "New_Level" && stem != "Root" {
				return stem
			}
		}
	}
	return "NewComponent"
}

@(private = "package")
_vh_create_and_open_odin_component :: proc(struct_name: string, rel_sub_folder: string = "") -> (norm_file: string, ok: bool) {
	if len(struct_name) == 0 do return "", false
	ws_root := file_exp.get_workspace_root()
	clean_sub := _vh_sanitize_odin_subfolder(rel_sub_folder)
	pkg_name := _vh_compute_odin_package_name(clean_sub)

	base_dir, _ := filepath.join({ws_root, "plugins", "void_odin"}, context.temp_allocator)
	target_dir := base_dir
	if len(clean_sub) > 0 {
		target_dir, _ = filepath.join({base_dir, clean_sub}, context.temp_allocator)
	}
	_vh_make_directories_recursive(target_dir)

	full_file, _ := filepath.join({target_dir, fmt.tprintf("component_%s.odin", struct_name)}, context.temp_allocator)
	norm_path, _ := strings.replace_all(full_file, "\\", "/", context.temp_allocator)

	if !os.exists(norm_path) {
		h1: u64 = 14695981039346656037
		h2: u64 = 1099511628211
		seed := fmt.tprintf("%s.%s", pkg_name, struct_name)
		for b_ch in transmute([]u8)seed {
			h1 = (h1 ~ u64(b_ch)) * 1099511628211
			h2 = (h2 ~ u64(b_ch)) * 14695981039346656037
		}
		guid_str := fmt.tprintf(
			"%08x-%04x-4%03x-8%03x-%012x",
			u32(h1 & 0xffffffff),
			u16((h1 >> 32) & 0xffff),
			u16((h1 >> 48) & 0x0fff),
			u16(h2 & 0x0fff),
			u64((h2 >> 16) & 0xffffffffffff),
		)
		code_txt := fmt.tprintf(
			"package %s\n\nimport \"haati:engine\"\n\n@" + "(component={{menu=\"Void/%s\"}})\n@" + "(typ_guid={{guid = \"%s\"}})\n%s :: struct {{\n\tusing base: engine.CompData,\n\t// Tip: Use engine.Ref_Local to reference a Scene Node,\n\t// or f32, int, bool, [3]f32 for tunable Inspector variables.\n}}\n\nreset_%s :: proc(c: ^%s) {{\n}}\n",
			pkg_name,
			struct_name,
			guid_str,
			struct_name,
			struct_name,
			struct_name,
		)
		_ = os.write_entire_file(norm_path, code_txt)
	}
	_needs_refresh = true
	engine.asset_db_request_refresh()
	file_exp.open_script_in_ide(norm_path, 6)
	return norm_path, true
}

@(private = "package")
_vh_open_new_odin_component_modal :: proc(preferred_node_name: string = "") {
	mem.zero(&_vh_new_comp_name_buf, len(_vh_new_comp_name_buf))
	mem.zero(&_vh_new_comp_folder_buf, len(_vh_new_comp_folder_buf))
	node_name := preferred_node_name
	if len(node_name) == 0 && _vh_selected_tH != {} {
		if w := engine.ctx_world(); w != nil && engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) {
			if sel_t := engine.pool_get(&w.transforms, engine.Handle(_vh_selected_tH)); sel_t != nil {
				node_name = sel_t.name
			}
		}
	}
	def_name := _vh_default_odin_component_name(node_name)
	copy(_vh_new_comp_name_buf[:len(_vh_new_comp_name_buf) - 1], def_name)
	def_folder := _vh_default_odin_component_folder()
	if len(def_folder) > 0 {
		copy(_vh_new_comp_folder_buf[:len(_vh_new_comp_folder_buf) - 1], def_folder)
	}
	_vh_show_new_comp_modal = true
	_vh_new_comp_modal_open_pending = true
}

@(private = "file")
_vh_draw_add_node_menu_items :: proc(force_root: bool = false) {
	if im.IsWindowAppearing() {
		mem.zero(&_vh_add_node_search_buf, len(_vh_add_node_search_buf))
		im.SetKeyboardFocusHere()
	}

	q_str := strings.trim_space(string(cstring(raw_data(_vh_add_node_search_buf[:]))))
	im.SetNextItemWidth(len(q_str) > 0 ? 386.0 : 290.0)
	enter_pressed := im.InputTextWithHint(
		"##VHAddNodeSearch",
		fmt.ctprintf("%s  Search nodes or components...", icons.ICON_MD_SEARCH),
		cstring(raw_data(_vh_add_node_search_buf[:])),
		len(_vh_add_node_search_buf),
		{.EnterReturnsTrue},
	)
	if len(q_str) > 0 {
		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s##VHClearAddNodeSearch", icons.ICON_MD_CLOSE), {26, 0}) {
			mem.zero(&_vh_add_node_search_buf, len(_vh_add_node_search_buf))
			q_str = ""
		}
	}
	im.Separator()

	// ── SEARCH FILTER MODE: Unified color-coded list (no duplicate single-component presets) ──
	if len(q_str) > 0 {
		VH_Node_Preset :: struct {
			label:     string,
			node_name: string,
			keys:      []engine.TypeKey,
			icon:      cstring,
			col:       im.Vec4,
		}
		// Only multi-component bundles / configured presets here; single-component nodes
		// (Camera, SpringArm3D, SphereCollider, BoxCollider, CapsuleCollider, AudioSource, etc.)
		// are listed once by the component loop below so nothing ever duplicates!
		presets := []VH_Node_Preset{
			{"Node (Empty Transform)", "Node", nil, icons.ICON_MD_ACCOUNT_TREE, {0.75, 0.82, 0.92, 1.0}},
			{"RigidBody3D (Rigidbody + BoxCollider)", "RigidBody3D", {.Rigidbody, .BoxCollider}, icons.ICON_MD_WIDGETS, {0.95, 0.58, 0.18, 1.0}},
			{"Mesh (MeshFilter + MeshRenderer)", "Mesh", {.MeshFilter, .MeshRenderer}, icons.ICON_MD_DEPLOYED_CODE, {0.30, 0.72, 0.98, 1.0}},
			{"SkinnedMesh (MeshFilter + SkinnedMeshRenderer)", "SkinnedMesh", {.MeshFilter, .SkinnedMeshRenderer}, icons.ICON_MD_ANIMATION, {0.78, 0.48, 0.98, 1.0}},
			{"ArmatureDeformedMesh (ControlRig + ArmatureDeformedMesh)", "ArmatureDeformedMesh", {.ControlRig, .ArmatureDeformedMesh}, icons.ICON_MD_ANIMATION, {0.78, 0.48, 0.98, 1.0}},
			{"Directional Light (Sun + Shadows)", "DirectionalLight3D", {.Light}, icons.ICON_MD_RECORD, {1.0, 0.82, 0.20, 1.0}},
			{"Point Light (Omni + Shadows)", "PointLight3D", {.Light}, icons.ICON_MD_RECORD, {1.0, 0.82, 0.20, 1.0}},
			{"Spot Light (Cone + Shadows)", "SpotLight3D", {.Light}, icons.ICON_MD_RECORD, {1.0, 0.82, 0.20, 1.0}},
			{"RigidBody2D (Rigidbody2D + BoxCollider2D)", "RigidBody2D", {.Rigidbody2D, .BoxCollider2D}, icons.ICON_MD_WIDGETS, {0.25, 0.85, 0.55, 1.0}},
			{"Canvas (Root UI)", "Canvas", {.Canvas, .CanvasScaler, .GraphicRaycaster}, icons.ICON_MD_LAYERS, {0.85, 0.85, 0.92, 1.0}},
		}

		w := engine.ctx_world()
		has_sel := _vh_selected_tH != {} && w != nil && engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH))

		if im.BeginChild("##VHAddNodeSearchList", {420, 260}, {.Borders}) {
			match_count := 0

			// 1. Multi-Component Node Bundles
			for p, idx in presets {
				if !_vh_matches_filter(p.label, q_str) && !_vh_matches_filter(p.node_name, q_str) do continue
				match_count += 1
				im.PushIDInt(i32(idx))
				im.PushStyleColorImVec4(.Text, p.col)
				clicked := im.Selectable(fmt.ctprintf("%s  %s  [Preset]", p.icon, p.label), match_count == 1)
				im.PopStyleColor(1)
				if clicked || (enter_pressed && match_count == 1) {
					_vh_create_node_with_components(p.node_name, p.keys, force_root)
					im.CloseCurrentPopup()
				}
				im.PopID()
			}

			// 2. All Registered Engine & Plugin Components (color-coded)
			for key in engine.TypeKey {
				if key == engine.INVALID_TYPE_KEY do continue
				src_path, _, is_comp := inspector.component_source_location(key)
				if !is_comp do continue
				comp_name := fmt.tprintf("%v", key)
				cat, icon, col := _vh_classify_component_key(key, src_path)
				if !_vh_matches_filter(comp_name, q_str) && !_vh_matches_filter(cat, q_str) do continue

				match_count += 1
				im.PushIDInt(1000 + i32(key))
				row_w: f32 = has_sel ? 328.0 : 400.0
				im.PushStyleColorImVec4(.Text, col)
				clicked := im.Selectable(fmt.ctprintf("%s  %s  (%s)", icon, comp_name, cat), match_count == 1, {}, {row_w, 20})
				im.PopStyleColor(1)
				if clicked || (enter_pressed && match_count == 1) {
					keys := [1]engine.TypeKey{key}
					_vh_create_node_with_components(comp_name, keys[:], force_root)
					im.CloseCurrentPopup()
				}
				widgets.tooltip(fmt.ctprintf("Create a new child Node named '%s' with %s attached", comp_name, comp_name))

				if has_sel {
					im.SameLine(336.0)
					if im.SmallButton("+Attach##Att") {
						_vh_attach_component_to_node(_vh_selected_tH, key)
						im.CloseCurrentPopup()
					}
					widgets.tooltip(fmt.ctprintf("Attach %s directly onto the currently selected node", comp_name))
				}
				im.PopID()
			}

			if match_count == 0 {
				im.TextDisabled("No matching nodes or components found.")
			}
		}
		im.EndChild()
		return
	}

	if im.MenuItem(fmt.ctprintf("%s  Node (Empty)", icons.ICON_MD_ACCOUNT_TREE)) {
		_vh_create_node_with_components("Node", nil, force_root)
	}
	if im.MenuItem(fmt.ctprintf("%s  Instantiate Child Scene... (Nested Scene)", icons.ICON_MD_PLAY_CIRCLE)) {
		_vh_open_instantiate_modal(force_root)
	}
	im.Separator()

	// 3D & Rendering Nodes
	if im.BeginMenu(fmt.ctprintf("%s  3D & Rendering", icons.ICON_MD_DEPLOYED_CODE)) {
		im.PushStyleColorImVec4(.Text, {0.20, 0.85, 0.95, 1.0})
		if im.MenuItem(fmt.ctprintf("%s  Camera", icons.ICON_MD_VISIBILITY)) {
			_vh_create_node_with_components("Camera", {.Camera}, force_root)
		}
		im.PopStyleColor(1)
		im.Separator()
		im.PushStyleColorImVec4(.Text, {0.30, 0.72, 0.98, 1.0})
		if im.MenuItem(fmt.ctprintf("%s  Mesh (MeshFilter + MeshRenderer)", icons.ICON_MD_DEPLOYED_CODE)) {
			_vh_create_node_with_components("Mesh", {.MeshFilter, .MeshRenderer}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  SkinnedMesh (MeshFilter + SkinnedMeshRenderer)", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("SkinnedMesh", {.MeshFilter, .SkinnedMeshRenderer}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  ArmatureDeformedMesh (ControlRig + ArmatureDeformedMesh)", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("ArmatureDeformedMesh", {.ControlRig, .ArmatureDeformedMesh}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  ParticleSystem", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("ParticleSystem", {.ParticleSystem}, force_root)
		}
		im.PopStyleColor(1)
		im.Separator()
		im.PushStyleColorImVec4(.Text, {1.0, 0.82, 0.20, 1.0})
		if im.MenuItem(fmt.ctprintf("%s  Directional Light (Sun + Shadows)", icons.ICON_MD_RECORD)) {
			_vh_create_node_with_components("DirectionalLight3D", {.Light}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  Point Light (Omni + Shadows)", icons.ICON_MD_RECORD)) {
			_vh_create_node_with_components("PointLight3D", {.Light}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  Spot Light (Cone + Shadows)", icons.ICON_MD_RECORD)) {
			_vh_create_node_with_components("SpotLight3D", {.Light}, force_root)
		}
		im.PopStyleColor(1)
		im.EndMenu()
	}

	// Physics & Colliders 3D
	if im.BeginMenu(fmt.ctprintf("%s  Physics & Colliders 3D", icons.ICON_MD_WIDGETS)) {
		im.PushStyleColorImVec4(.Text, {1.0, 0.72, 0.18, 1.0})
		if im.MenuItem(fmt.ctprintf("%s  SpringArm3D (Camera Boom)", icons.ICON_MD_OPEN_WITH)) {
			_vh_create_node_with_components("SpringArm3D", {.SpringArm3D}, force_root)
		}
		im.PopStyleColor(1)
		im.Separator()
		im.PushStyleColorImVec4(.Text, {0.95, 0.58, 0.18, 1.0})
		if im.MenuItem(fmt.ctprintf("%s  SphereCollider", icons.ICON_MD_WIDGETS)) {
			_vh_create_node_with_components("SphereCollider", {.SphereCollider}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  BoxCollider", icons.ICON_MD_WIDGETS)) {
			_vh_create_node_with_components("BoxCollider", {.BoxCollider}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  CapsuleCollider", icons.ICON_MD_WIDGETS)) {
			_vh_create_node_with_components("CapsuleCollider", {.CapsuleCollider}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  RigidBody3D (Rigidbody + BoxCollider)", icons.ICON_MD_WIDGETS)) {
			_vh_create_node_with_components("RigidBody3D", {.Rigidbody, .BoxCollider}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  SpringBone", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("SpringBone", {.SpringBone}, force_root)
		}
		im.PopStyleColor(1)
		im.EndMenu()
	}

	// Void / Gameplay Scripts (all components in plugins/void_odin/)
	if im.BeginMenu(fmt.ctprintf("%s  Void / Custom Scripts", icons.ICON_MD_CODE)) {
		im.PushStyleColorImVec4(.Text, {0.20, 0.95, 0.55, 1.0})
		for key in engine.TypeKey {
			if key == engine.INVALID_TYPE_KEY do continue
			src_path, _, is_comp := inspector.component_source_location(key)
			if !is_comp || !strings.contains(strings.to_lower(src_path, context.temp_allocator), "void_odin") do continue
			cname := fmt.tprintf("%v", key)
			if im.MenuItem(fmt.ctprintf("%s  %s", icons.ICON_MD_CODE, cname)) {
				keys := [1]engine.TypeKey{key}
				_vh_create_node_with_components(cname, keys[:], force_root)
			}
		}
		im.PopStyleColor(1)
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Create New Odin Component (.odin)...", icons.ICON_MD_ADD)) {
			_vh_open_new_odin_component_modal()
		}
		im.EndMenu()
	}

	// Control Rig & Animation
	if im.BeginMenu(fmt.ctprintf("%s  Control Rig & Animation", icons.ICON_MD_ANIMATION)) {
		im.PushStyleColorImVec4(.Text, {0.78, 0.48, 0.98, 1.0})
		if im.MenuItem(fmt.ctprintf("%s  ControlRig", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("ControlRig", {.ControlRig}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  HumanoidIkSolver", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("HumanoidIkSolver", {.HumanoidIkSolver}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  ProceduralLocomotion", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("ProceduralLocomotion", {.ProceduralLocomotion}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  HandPoseDriver", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("HandPoseDriver", {.HandPoseDriver}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  Animation (Clip Player)", icons.ICON_MD_ANIMATION)) {
			_vh_create_node_with_components("Animation", {.Animation}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  TimelineAnimator", icons.ICON_MD_PLAY_CIRCLE)) {
			_vh_create_node_with_components("TimelineAnimator", {.TimelineAnimator}, force_root)
		}
		im.PopStyleColor(1)
		im.EndMenu()
	}

	// 2D Nodes (Godot Node2D style)
	if im.BeginMenu(fmt.ctprintf("%s  2D Nodes (Node2D)", icons.ICON_MD_IMAGE)) {
		if im.MenuItem(fmt.ctprintf("%s  Sprite2D (SpriteRenderer)", icons.ICON_MD_IMAGE)) {
			_vh_create_node_with_components("Sprite2D", {.SpriteRenderer}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  RigidBody2D (Rigidbody2D + BoxCollider2D)", icons.ICON_MD_WIDGETS)) {
			_vh_create_node_with_components("RigidBody2D", {.Rigidbody2D, .BoxCollider2D}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  SpriteSortingGroup", icons.ICON_MD_LAYERS)) {
			_vh_create_node_with_components("SpriteSortingGroup", {.SpriteSortingGroup}, force_root)
		}
		im.EndMenu()
	}

	// UI Elements (Godot Control style)
	if im.BeginMenu(fmt.ctprintf("%s  UI Elements (Control)", icons.ICON_MD_DESCRIPTION)) {
		if im.MenuItem(fmt.ctprintf("%s  Canvas (Root UI)", icons.ICON_MD_LAYERS)) {
			_vh_create_node_with_components("Canvas", {.Canvas, .CanvasScaler, .GraphicRaycaster}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  Text (Label)", icons.ICON_MD_DESCRIPTION)) {
			_vh_create_node_with_components("Text", {.RectTransform, .Text}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  Button", icons.ICON_MD_WIDGETS)) {
			_vh_create_node_with_components("Button", {.RectTransform, .Image, .Button}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  Image (TextureRect)", icons.ICON_MD_IMAGE)) {
			_vh_create_node_with_components("Image", {.RectTransform, .Image}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  LayoutGroup (Container)", icons.ICON_MD_ACCOUNT_TREE)) {
			_vh_create_node_with_components("LayoutGroup", {.RectTransform, .LayoutGroup}, force_root)
		}
		im.EndMenu()
	}

	// Audio
	if im.BeginMenu(fmt.ctprintf("%s  Audio", icons.ICON_MD_VOLUME_UP)) {
		if im.MenuItem(fmt.ctprintf("%s  AudioSource", icons.ICON_MD_VOLUME_UP)) {
			_vh_create_node_with_components("AudioSource", {.AudioSource}, force_root)
		}
		if im.MenuItem(fmt.ctprintf("%s  AudioListener", icons.ICON_MD_VOLUME_UP)) {
			_vh_create_node_with_components("AudioListener", {.AudioListener}, force_root)
		}
		im.EndMenu()
	}
}

@(private = "file")
_vh_draw_attach_component_menu :: proc(tH: engine.Transform_Handle, t: ^engine.Transform) {
	if im.IsWindowAppearing() {
		mem.zero(&_vh_attach_comp_search_buf, len(_vh_attach_comp_search_buf))
		im.SetKeyboardFocusHere()
	}

	q_str := strings.trim_space(string(cstring(raw_data(_vh_attach_comp_search_buf[:]))))
	im.SetNextItemWidth(len(q_str) > 0 ? 245.0 : 280.0)
	enter_pressed := im.InputTextWithHint(
		"##VHAttachCompSearch",
		fmt.ctprintf("%s  Search components to attach...", icons.ICON_MD_SEARCH),
		cstring(raw_data(_vh_attach_comp_search_buf[:])),
		len(_vh_attach_comp_search_buf),
		{.EnterReturnsTrue},
	)
	if len(q_str) > 0 {
		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s##VHClearAttachSearch", icons.ICON_MD_CLOSE), {26, 0}) {
			mem.zero(&_vh_attach_comp_search_buf, len(_vh_attach_comp_search_buf))
			q_str = ""
		}
	}
	im.Separator()

	categories := []string{
		"Void / Custom Scripts",
		"Physics 3D",
		"3D & Rendering",
		"Animation & Control Rig",
		"Audio",
		"2D Nodes",
		"UI Controls",
		"Timeline & Tween",
		"Gameplay & Misc",
	}

	if len(q_str) > 0 {
		if im.BeginChild("##VHAttachCompList", {310, 240}, {.Borders}) {
			match_count := 0
			for key in engine.TypeKey {
				if key == engine.INVALID_TYPE_KEY do continue
				src_path, _, is_comp := inspector.component_source_location(key)
				if !is_comp do continue
				comp_name := fmt.tprintf("%v", key)
				cat, icon, col := _vh_classify_component_key(key, src_path)
				if !_vh_matches_filter(comp_name, q_str) && !_vh_matches_filter(cat, q_str) do continue

				_, existing_idx := engine.transform_find_comp(t, key)
				already_has := existing_idx >= 0
				match_count += 1

				im.PushIDInt(i32(key))
				if already_has do im.BeginDisabled()
				im.PushStyleColorImVec4(.Text, col)
				clicked := im.Selectable(
					fmt.ctprintf("%s  %s%s  (%s)", icon, comp_name, already_has ? " [Attached]" : "", cat),
					match_count == 1 && !already_has,
				)
				im.PopStyleColor(1)
				if (clicked || (enter_pressed && match_count == 1)) && !already_has {
					_vh_attach_component_to_node(tH, key)
					im.CloseCurrentPopup()
				}
				if already_has do im.EndDisabled()
				im.PopID()
			}
			if match_count == 0 {
				im.TextDisabled("No matching components.")
			}
		}
		im.EndChild()
		return
	}

	for cat in categories {
		if im.BeginMenu(fmt.ctprintf("%s  %s", icons.ICON_MD_WIDGETS, cat)) {
			for key in engine.TypeKey {
				if key == engine.INVALID_TYPE_KEY do continue
				src_path, _, is_comp := inspector.component_source_location(key)
				if !is_comp do continue
				k_cat, icon, col := _vh_classify_component_key(key, src_path)
				if k_cat != cat do continue

				comp_name := fmt.tprintf("%v", key)
				_, existing_idx := engine.transform_find_comp(t, key)
				already_has := existing_idx >= 0

				im.PushStyleColorImVec4(.Text, col)
				if im.MenuItem(fmt.ctprintf("%s  %s%s", icon, comp_name, already_has ? " (Attached)" : ""), nil, false, !already_has) {
					_vh_attach_component_to_node(tH, key)
				}
				im.PopStyleColor(1)
			}
			im.EndMenu()
		}
	}

	im.Separator()
	if im.MenuItem(fmt.ctprintf("%s  Create New Odin Component (.odin)...", icons.ICON_MD_ADD)) {
		_vh_open_new_odin_component_modal()
	}
}

@(private = "file")
_vh_jump_to_by_char :: proc(ch: rune) {
	if _vh_nav_count == 0 do return
	prefix := fmt.tprintf("%c", ch)
	prefix_lower := strings.to_lower(prefix, context.temp_allocator)

	w := engine.ctx_world()
	curr_idx := -1
	for i in 0 ..< _vh_nav_count {
		if _vh_nav_list[i] == _vh_selected_tH {
			curr_idx = i
			break
		}
	}

	start := (curr_idx + 1) % _vh_nav_count
	for count := 0; count < _vh_nav_count; count += 1 {
		idx := (start + count) % _vh_nav_count
		tH := _vh_nav_list[idx]
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do continue

		name_lower := strings.to_lower(t.name, context.temp_allocator)
		if strings.has_prefix(name_lower, prefix_lower) {
			_vh_select_node(tH, ping = true)
			_vh_scroll_to_selected = true
			return
		}
	}
}

@(private = "file")
_vh_handle_keyboard_shortcuts :: proc() {
	io := im.GetIO()
	if io.WantTextInput do return

	ctrl_down := io.KeyCtrl

	// 1. Delete
	if im.IsKeyPressed(.Delete, false) {
		_vh_delete_selected()
		return
	}

	// 2. F2 Rename
	if im.IsKeyPressed(.F2, false) {
		if _vh_selected_tH != {} {
			_vh_begin_rename(_vh_selected_tH)
			return
		}
	}

	// 3. Ctrl+C Copy
	if ctrl_down && im.IsKeyPressed(.C, false) {
		_vh_copy_selected()
		return
	}

	// 3b. Ctrl+Shift+D Separate / Move Selected to New Scene
	if ctrl_down && io.KeyShift && im.IsKeyPressed(.D, false) {
		_vh_open_separate_to_new_scene_modal()
		return
	}

	// 4. Ctrl+A Select All (all visible tree nodes)
	if ctrl_down && im.IsKeyPressed(.A, false) {
		if _vh_nav_count > 0 {
			engine.inspector_request_selection_batch(_vh_nav_list[:_vh_nav_count])
			engine.inspector_set_selection_all(_vh_nav_list[:_vh_nav_count])
		}
		return
	}

	// 7. F -> Frame in scene
	if !ctrl_down && im.IsKeyPressed(.F, false) {
		if _vh_selected_tH != {} {
			engine.inspector_request_ping(_vh_selected_tH)
			return
		}
	}

	// 8. Type-Ahead Navigation (A-Z, 0-9)
	if !ctrl_down && !io.KeyAlt {
		for k in im.Key.A ..= im.Key.Z {
			if im.IsKeyPressed(k, false) {
				ch := rune('a' + (int(k) - int(im.Key.A)))
				_vh_jump_to_by_char(ch)
				return
			}
		}
		for k in im.Key._0 ..= im.Key._9 {
			if im.IsKeyPressed(k, false) {
				ch := rune('0' + (int(k) - int(im.Key._0)))
				_vh_jump_to_by_char(ch)
				return
			}
		}
	}

	// 9. Up/Down Arrow Navigation
	if !ctrl_down && !io.KeyAlt && _vh_nav_count > 0 {
		curr_idx := -1
		for i in 0 ..< _vh_nav_count {
			if _vh_nav_list[i] == _vh_selected_tH {
				curr_idx = i
				break
			}
		}

		if im.IsKeyPressed(.DownArrow, false) {
			next_idx := (curr_idx + 1) % _vh_nav_count if curr_idx != -1 else 0
			_vh_select_node(_vh_nav_list[next_idx], ping = true)
			_vh_scroll_to_selected = true
			return
		}
		if im.IsKeyPressed(.UpArrow, false) {
			prev_idx := (curr_idx - 1 + _vh_nav_count) % _vh_nav_count if curr_idx != -1 else 0
			_vh_select_node(_vh_nav_list[prev_idx], ping = true)
			_vh_scroll_to_selected = true
			return
		}
	}
}

// ─────────────────────────────────────────────────────────────
// CONTEXT MENU
// ─────────────────────────────────────────────────────────────

@(private = "file")
_vh_draw_context_menu :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, sc: ^engine.Scene = nil) {
	curr_sc := t.scene if t.scene != nil else sc
	badge := _vh_get_badge(t, tH, curr_sc)
	im.TextColored(badge.color, fmt.ctprintf("%s  %s  (%s)", badge.icon, t.name, badge.type_name))
	im.Separator()

	// 0. Jump to Code (if node or ancestor armature has code)
	if code_key, code_type, has_code := _vh_node_find_code_key(t); has_code {
		if im.MenuItem(fmt.ctprintf("%s  Jump to Script Code (%s)...", icons.ICON_MD_CODE, code_type)) {
			inspector.open_component_source(code_key)
		}
		im.Separator()
	} else if arm_key, arm_type, has_arm := _vh_node_find_ancestor_armature_code_key(tH); has_arm {
		if im.MenuItem(fmt.ctprintf("%s  Jump to Armature Code (%s)...", icons.ICON_MD_CODE, arm_type)) {
			inspector.open_component_source(arm_key)
		}
		im.Separator()
	}

	// Nested Scene action (Open Subscene Asset)
	if curr_sc != nil {
		if ns := engine.scene_find_nested_scene_for_host(curr_sc, tH); ns != nil && ns.source_prefab != (engine.Asset_GUID{}) {
			if src_path, ok := engine.asset_db_get_path(uuid.Identifier(ns.source_prefab)); ok {
				if im.MenuItem(fmt.ctprintf("%s  Open Scene Asset (%s)...", icons.ICON_MD_OPEN_IN_NEW, filepath.base(src_path))) {
					_vh_switch_to_scene_path(src_path)
				}
				im.Separator()
			}
		}
	}

	// 1. Godot Visibility Toggle with Undo
	vis_label := "Hide in Scene" if t.is_active else "Show in Scene"
	vis_icon := icons.ICON_MD_VISIBILITY_OFF if t.is_active else icons.ICON_MD_VISIBILITY
	if im.MenuItem(fmt.ctprintf("%s  %s", vis_icon, vis_label)) {
		e := undo.edit_begin(tH, &t.is_active, typeid_of(bool), t.is_active ? "Hide Object" : "Show Object")
		t.is_active = !t.is_active
		undo.edit_end(&e)
		if t.scene != nil do t.scene.dirty = true
	}

	// 2. Lock Toggle
	is_locked := engine.node_is_locked(tH)
	lock_label := "Unlock Object" if is_locked else "Lock Object (Freeze)"
	lock_icon := icons.ICON_MD_LOCK_OPEN if is_locked else icons.ICON_MD_LOCK
	if im.MenuItem(fmt.ctprintf("%s  %s", lock_icon, lock_label)) {
		engine.node_set_locked(tH, !is_locked)
	}

	im.Separator()

	// 3. Add Child Node & Attach Component
	if im.BeginMenu(fmt.ctprintf("%s  Add Child Node", icons.ICON_MD_ADD)) {
		_vh_draw_add_node_menu_items()
		im.EndMenu()
	}
	if im.BeginMenu(fmt.ctprintf("%s  Add Component to '%s'", icons.ICON_MD_WIDGETS, t.name)) {
		_vh_draw_attach_component_menu(tH, t)
		im.EndMenu()
	}
	if im.MenuItem(fmt.ctprintf("%s  Instantiate Child Scene...", icons.ICON_MD_PLAY_CIRCLE)) {
		_vh_open_instantiate_modal(force_root = false)
	}

	im.Separator()

	// 4. Duplicate & Separate to New Scene
	if im.MenuItem(fmt.ctprintf("%s  Duplicate (Ctrl+D)", icons.ICON_MD_CONTENT_COPY)) {
		_vh_duplicate_selected()
	}
	if t.parent.handle != {} {
		if im.MenuItem(fmt.ctprintf("%s  Separate / Move Selected to New Scene... (Ctrl+Shift+D)", icons.ICON_MD_OPEN_IN_NEW)) {
			_vh_open_separate_to_new_scene_modal()
		}
	}

	// 5. Copy & Paste
	if im.MenuItem(fmt.ctprintf("%s  Copy (Ctrl+C)", icons.ICON_MD_CONTENT_COPY)) {
		_vh_copy_selected()
	}
	if im.MenuItem(fmt.ctprintf("%s  Paste as Child (Ctrl+V)", icons.ICON_MD_CONTENT_PASTE), nil, false, clip.has_hierarchy()) {
		_vh_paste_under_selected()
	}

	im.Separator()

	// 6. Unreal / Godot Tag Colors
	if im.BeginMenu(fmt.ctprintf("%s  Set Color Tag", icons.ICON_MD_PALETTE)) {
		presets := []struct { name: string, col: [4]f32 }{
			{"Red",          {0.92, 0.25, 0.25, 1.0}},
			{"Orange",       {0.95, 0.55, 0.15, 1.0}},
			{"Amber / Gold", {0.95, 0.78, 0.12, 1.0}},
			{"Green",        {0.18, 0.80, 0.44, 1.0}},
			{"Teal",         {0.12, 0.75, 0.82, 1.0}},
			{"Cyan",         {0.20, 0.85, 0.95, 1.0}},
			{"Blue",         {0.25, 0.55, 0.95, 1.0}},
			{"Purple",       {0.72, 0.40, 0.95, 1.0}},
			{"Pink",         {0.95, 0.35, 0.65, 1.0}},
			{"Slate",        {0.55, 0.65, 0.75, 1.0}},
		}
		for p in presets {
			im.PushStyleColorImVec4(.Text, p.col)
			if im.MenuItem(fmt.ctprintf("%s  %s", icons.ICON_MD_RECORD, p.name)) {
				_vh_node_colors[t.local_id] = p.col
			}
			im.PopStyleColor()
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Reset Color Tag", icons.ICON_MD_REFRESH)) {
			delete_key(&_vh_node_colors, t.local_id)
		}
		im.EndMenu()
	}

	im.Separator()

	// 7. Focus
	if im.MenuItem(fmt.ctprintf("%s  Focus in Scene View (F)", icons.ICON_MD_CENTER_FOCUS)) {
		engine.inspector_request_ping(tH)
	}

	// 8. Rename
	if im.MenuItem(fmt.ctprintf("%s  Rename... (F2)", icons.ICON_MD_EDIT)) {
		_vh_begin_rename(tH)
	}

	// 9. Delete
	if im.MenuItem(fmt.ctprintf("%s  Delete... (Del)", icons.ICON_MD_DELETE)) {
		_vh_delete_selected()
	}
}

// ─────────────────────────────────────────────────────────────
// FILTER MATCHING (DEEP SUBTREE & FUZZY DELIMITER SUPPORT)
// ─────────────────────────────────────────────────────────────

@(private = "package")
_vh_matches_filter :: proc(name: string, query: string) -> bool {
	q := strings.trim_space(query)
	if len(q) == 0 do return true

	name_lower := strings.to_lower(name, context.temp_allocator)
	q_lower := strings.to_lower(q, context.temp_allocator)

	// 1. Direct substring match (e.g. "node" matches "node_3")
	if strings.contains(name_lower, q_lower) do return true

	// 2. Normalized match ignoring underscores, hyphens, and spaces
	// e.g. user typed "node3" -> matches "node_3" or "node-3" or "node 3"
	strip_delims :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for r in s {
			if r != '_' && r != '-' && r != ' ' && r != '.' {
				strings.write_rune(&b, r)
			}
		}
		return strings.to_string(b)
	}

	norm_name := strip_delims(name_lower)
	norm_q := strip_delims(q_lower)
	if len(norm_q) > 0 && strings.contains(norm_name, norm_q) {
		return true
	}

	// 3. Multi-word search terms: e.g. "box anim" matches "BoxAnimated"
	terms := strings.fields(q_lower, context.temp_allocator)
	if len(terms) > 1 {
		all_match := true
		for term in terms {
			if !strings.contains(name_lower, term) && !strings.contains(norm_name, strip_delims(term)) {
				all_match = false
				break
			}
		}
		if all_match do return true
	}

	return false
}

@(private = "file")
_vh_has_matching_descendant :: proc(tH: engine.Transform_Handle, sc: ^engine.Scene, query: string) -> bool {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return false

	curr_sc := t.scene if t.scene != nil else sc

	for child in t.children {
		ch, ok := engine.scene_ref_resolve_transform(curr_sc, child, tH)
		if !ok && engine.pool_valid(&w.transforms, child.handle) {
			ch = engine.Transform_Handle(child.handle)
			ok = true
		}
		if !ok do continue
		ct := engine.pool_get(&w.transforms, engine.Handle(ch))
		if ct == nil do continue

		if _vh_matches_filter(ct.name, query) do return true
		if _vh_has_matching_descendant(ch, curr_sc, query) do return true
	}
	return false
}

// ─────────────────────────────────────────────────────────────
// TREE NODE RECURSIVE DRAW
// ─────────────────────────────────────────────────────────────

@(private = "file")
_vh_to_asset_db_path :: proc(path: string, alloc := context.temp_allocator) -> string {
	clean_p, _ := filepath.clean(path, alloc)
	norm_p, _  := strings.replace_all(clean_p, "\\", "/", alloc)
	rel_p      := strings.trim_prefix(norm_p, "../")
	rel_p       = strings.trim_prefix(rel_p, "./")
	if strings.has_prefix(rel_p, "plugins/") {
		return fmt.tprintf("packages/%s", strings.trim_prefix(rel_p, "plugins/"))
	} else if strings.has_prefix(rel_p, "haati/") {
		return strings.trim_prefix(rel_p, "haati/")
	}
	return rel_p
}

@(private = "file")
_vh_handle_asset_drop_on_node :: proc(tH: engine.Transform_Handle, sc: ^engine.Scene, asset_path: string) {
	lower_path := strings.to_lower(asset_path, context.temp_allocator)
	db_path    := _vh_to_asset_db_path(asset_path, context.temp_allocator)
	if strings.has_suffix(lower_path, ".scene") {
		guid_id, ok := engine.asset_db_get_guid(db_path)
		if !ok do guid_id, ok = engine.asset_db_get_guid(asset_path)
		if ok {
			inst_h := engine.scene_instantiate_guid_nested(engine.Asset_GUID(guid_id), tH)
			if inst_h != {} {
				engine.transform_ensure_unique_name(inst_h)
				if sc != nil do sc.dirty = true
				_vh_select_node(inst_h, ping = true)
			}
		}
	} else if strings.has_suffix(lower_path, ".mat") ||
	          strings.has_suffix(lower_path, ".png") ||
	          strings.has_suffix(lower_path, ".jpg") ||
	          strings.has_suffix(lower_path, ".jpeg") ||
	          strings.has_suffix(lower_path, ".tga") ||
	          strings.has_suffix(lower_path, ".bmp") {
		if cad_csg_editor.apply_dropped_material_or_texture(asset_path, tH, {}, false) {
			_vh_select_node(tH, ping = false)
		}
	} else if strings.has_suffix(lower_path, ".fmesh") {
		new_tH := cad_csg.csg_spawn_faker_mesh_from_binary({0, 0, 0}, asset_path)
		if new_tH != {} {
			if tH != {} {
				engine.transform_set_parent(new_tH, tH, -1, keep_world = false)
			}
			if sc != nil do sc.dirty = true
			_vh_select_node(new_tH, ping = true)
		}
	} else if strings.has_suffix(lower_path, ".glb") || strings.has_suffix(lower_path, ".gltf") {
		w := engine.ctx_world()
		if w != nil && engine.pool_valid(&w.transforms, engine.Handle(tH)) {
			guid_id, ok := engine.asset_db_get_guid(db_path)
			if !ok do guid_id, ok = engine.asset_db_get_guid(asset_path)
			if ok {
				mesh_guid := engine.Asset_GUID(guid_id)
				applied := false
				if _, vol := engine.transform_get_comp(tH, cad_csg.CSGVolume); vol != nil && vol.is_faker_mesh {
					vol.faker_mesh_guid = mesh_guid
					vol.gpu_dirty = true
					applied = true
				}
				if !applied {
					if _, mf := engine.transform_get_comp(tH, engine.MeshFilter); mf != nil {
						mf.mesh = engine.PPtr{guid = mesh_guid}
						applied = true
					}
				}
				if applied {
					if sc != nil do sc.dirty = true
					_vh_select_node(tH, ping = false)
				} else {
					stem := filepath.stem(filepath.base(asset_path))
					new_tH, _ := control_rig.instantiate_gltf_model_auto(mesh_guid, stem, tH, {}, false)
					if new_tH != {} {
						if sc != nil do sc.dirty = true
						_vh_select_node(new_tH, ping = true)
					}
				}
			}
		}
	}
}

@(private = "file")
_vh_draw_root_empty_space_menu :: proc(root_tH: engine.Transform_Handle, root_t: ^engine.Transform, scene: ^engine.Scene) {
	if root_tH != {} && _vh_selected_tH != root_tH {
		_vh_select_node(root_tH)
	}
	root_name := root_t != nil ? root_t.name : "Scene Root"
	im.TextColored({0.35, 0.85, 1.0, 1.0}, fmt.ctprintf("%s  Add Node to Root (%s)", icons.ICON_MD_ACCOUNT_TREE, root_name))
	im.Separator()

	_vh_draw_add_node_menu_items(force_root = true)

	im.Separator()
	if im.MenuItem(fmt.ctprintf("%s  Paste into Root (Ctrl+V)", icons.ICON_MD_CONTENT_PASTE), nil, false, clip.has_hierarchy()) {
		_vh_select_node(root_tH)
		_vh_paste_under_selected()
	}
	if im.MenuItem(fmt.ctprintf("%s  Collapse All Nodes", icons.ICON_MD_EXPAND_LESS)) {
		_vh_collapse_node_recursive(root_tH, scene)
		_vh_mark_prefs_dirty()
	}
}

@(private = "file")
_vh_draw_node :: proc(tH: engine.Transform_Handle, sc: ^engine.Scene, filter: string, depth: int = 0) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	curr_sc := t.scene if t.scene != nil else sc

	has_filter := len(filter) > 0
	matches_self := !has_filter || _vh_matches_filter(t.name, filter)
	has_matching_child := has_filter && _vh_has_matching_descendant(tH, curr_sc, filter)

	// Pruning: if filter is active and neither this node nor any descendant matches, hide it!
	if has_filter && !matches_self && !has_matching_child {
		return
	}

	has_children := len(t.children) > 0

	// Register in navigation list
	if _vh_nav_count < len(_vh_nav_list) {
		_vh_nav_list[_vh_nav_count] = tH
		_vh_nav_count += 1
	}

	p := thm.palette()
	is_sel := engine.inspector_selection_contains(tH) || (tH == _vh_selected_tH) || (engine.inspector_active_selection() == tH)
	badge := _vh_get_badge(t, tH, curr_sc)

	// Custom tag color or adapted semantic badge color (plain GameObjects use clean primary text)
	raw_tag_col, has_tag_col := _vh_node_colors[t.local_id]
	tag_col: im.Vec4
	if has_tag_col {
		tag_col = thm.adapt_badge_color(raw_tag_col)
	} else if fcol, has_fcol := editor_visuals.get_folder_color(t.name); has_fcol {
		tag_col = thm.adapt_badge_color(fcol)
	} else if len(t.components) == 0 && !t.nested_owned && !(curr_sc != nil && tH != {} && engine.scene_hierarchy_transform_is_nested_scene_host(curr_sc, tH)) {
		tag_col = is_sel ? p.text_primary : p.text_secondary
	} else {
		tag_col = thm.adapt_badge_color(badge.color)
	}

	ui_s := max(im.GetFontSize() / 14.0, 0.6)
	row_h := max(im.GetFrameHeight(), math.ceil(23.0 * ui_s))

	im.PushIDInt(i32(engine.Handle(tH).index))
	im.TableNextRow({}, row_h)

	// ── COL 0: TREE NODE, BADGE, AND NAME (LEFT STRETCH COLUMN) ───
	im.TableNextColumn()

	row_cursor := im.GetCursorScreenPos()
	col0_max_x := row_cursor.x + im.GetContentRegionAvail().x
	dl := im.GetWindowDrawList()

	// Draw subtle vertical tree hierarchy guide lines for child levels
	if depth > 0 {
		indent_step := im.GetStyle().IndentSpacing
		base_x := row_cursor.x - f32(depth) * indent_step + 8.0 * ui_s
		guide_col := im.GetColorU32ImVec4(thm.with_alpha(p.border_strong, p.is_light ? 0.55 : 0.42))
		mid_y := row_cursor.y + row_h * 0.48
		for d in 0 ..< depth {
			gx := base_x + f32(d) * indent_step
			im.DrawList_AddLine(dl, {gx, row_cursor.y - 2.0}, {gx, row_cursor.y + row_h - 1.0}, guide_col, 1.0)
		}
		elbow_x := base_x + f32(depth - 1) * indent_step
		im.DrawList_AddLine(dl, {elbow_x, mid_y}, {elbow_x + 7.0 * ui_s, mid_y}, guide_col, 1.0)
	}

	// Highlighted row accent bar on the left when selected
	if is_sel {
		im.DrawList_AddRectFilled(
			dl,
			{row_cursor.x - 2.0, row_cursor.y + 1.5},
			{row_cursor.x + 1.5, row_cursor.y + row_h - 2.5},
			im.GetColorU32ImVec4(p.accent),
			1.5,
		)
	}

	flags := im.TreeNodeFlags{.OpenOnArrow, .SpanAllColumns, .AllowOverlap, .FramePadding}
	if !has_children do flags += {.Leaf, .NoTreePushOnOpen}
	if is_sel do flags += {.Selected}
	if has_filter && has_matching_child {
		im.SetNextItemOpen(true)
	} else if (_vh_force_close_all || (tH in _vh_pending_close_nodes)) && !has_filter {
		im.SetNextItemOpen(false)
		delete_key(&_vh_pending_close_nodes, tH)
	} else if tH in _vh_pending_open_nodes {
		im.SetNextItemOpen(true)
		delete_key(&_vh_pending_open_nodes, tH)
	} else if open_state, has_saved := _vh_open_nodes[t.local_id]; has_saved {
		im.SetNextItemOpen(open_state, .Once)
	} else if t.parent.handle == {} {
		im.SetNextItemOpen(true, .Once)
	}

	// Dimmed appearance if inactive, warning hue if search match, or adapted tag color
	if !t.is_active {
		im.PushStyleColorImVec4(.Text, p.text_muted)
	} else if has_filter && matches_self {
		im.PushStyleColorImVec4(.Text, p.status_warning)
	} else {
		im.PushStyleColorImVec4(.Text, tag_col)
	}

	im.PushStyleVarImVec2(.FramePadding, {3.0 * ui_s, 2.0 * ui_s})
	node_label := fmt.ctprintf("%s  %s###TN_%d", badge.icon, t.name, engine.Handle(tH).index)
	node_open := im.TreeNodeEx(node_label, flags)
	im.PopStyleVar()
	im.PopStyleColor()

	if im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) {
		_vh_node_right_clicked_or_hovered = true
	}

	if has_children {
		if _vh_open_nodes == nil {
			_vh_open_nodes = make(map[engine.Local_ID]bool)
		}
		 if _vh_force_close_all && !has_filter {
			_vh_open_nodes[t.local_id] = false
			_vh_mark_prefs_dirty()
		} else if im.IsItemToggledOpen() {
			_vh_open_nodes[t.local_id] = node_open
			_vh_mark_prefs_dirty()
		} else if _, exists := _vh_open_nodes[t.local_id]; !exists {
			_vh_open_nodes[t.local_id] = node_open
		}
	}

	if _vh_scroll_to_selected && is_sel {
		im.SetScrollHereY()
		_vh_scroll_to_selected = false
	}

	// Click to select (Single, Ctrl+Toggle, Shift+Range, Drag-safe)
	node_toggled := has_children && im.IsItemToggledOpen()
	io := im.GetIO()

	if !node_toggled {
		if im.IsItemClicked(.Left) {
			if io.KeyShift {
				_vh_range_pending = tH
				_vh_deferred_toggle_tH = {}
				_vh_deferred_select_tH = {}
			} else if io.KeyCtrl || io.KeySuper {
				if !is_sel {
					_vh_toggle_select_node(tH)
					_vh_deferred_toggle_tH = {}
					_vh_deferred_select_tH = {}
				} else {
					// Already selected: defer toggle-off to mouse release so dragging works
					_vh_deferred_toggle_tH = tH
					_vh_deferred_select_tH = {}
				}
			} else {
				if !is_sel {
					_vh_select_node(tH)
					_vh_deferred_toggle_tH = {}
					_vh_deferred_select_tH = {}
				} else {
					// Already selected: defer single-select collapse to mouse release so dragging works
					_vh_deferred_select_tH = tH
					_vh_deferred_toggle_tH = {}
				}
			}
		}

		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			_vh_select_node(tH, ping = true)
		}
	}

	// Right-click context menu (preserve multi-selection if right-clicking already selected item)
	if im.BeginPopupContextItem(fmt.ctprintf("##Ctx_%d", engine.Handle(tH).index)) {
		_vh_node_right_clicked_or_hovered = true
		if !engine.inspector_selection_contains(tH) {
			_vh_select_node(tH)
		}
		_vh_draw_context_menu(tH, t, curr_sc)
		im.EndPopup()
	}

	// Drag & Drop Source: Reparent node or multiple selected nodes
	if im.BeginDragDropSource({}) {
		_vh_is_dragging = true
		_vh_deferred_toggle_tH = {}
		_vh_deferred_select_tH = {}
		all_sel := engine.inspector_selection_all()
		is_multi := len(all_sel) > 1 && engine.inspector_selection_contains(tH)

		drag_payload: VH_Drag_Payload
		if is_multi {
			drag_payload.count = min(len(all_sel), 64)
			for i in 0 ..< drag_payload.count {
				drag_payload.handles[i] = all_sel[i]
			}
			im.SetDragDropPayload("VOID_HIERARCHY_NODES", &drag_payload, size_of(VH_Drag_Payload))
			im.TextColored(tag_col, fmt.ctprintf("%s  %s (+%d selected)", badge.icon, t.name, drag_payload.count - 1))
			im.TextDisabled("-> Drop on another node to reparent all selected")
		} else {
			drag_payload.count = 1
			drag_payload.handles[0] = tH
			im.SetDragDropPayload("VOID_HIERARCHY_NODES", &drag_payload, size_of(VH_Drag_Payload))
			single_handle := tH
			im.SetDragDropPayload("VOID_HIERARCHY_NODE", &single_handle, size_of(engine.Transform_Handle))
			im.TextColored(tag_col, fmt.ctprintf("%s  %s", badge.icon, t.name))
			im.TextDisabled("-> Drop on another node to reparent")
		}
		im.EndDragDropSource()
	}

	// Drag & Drop Target: Accept other nodes or assets from Void File Explorer
	if im.BeginDragDropTarget() {
		// 1. Reparenting (multi-node or single node, keeping world position)
		if p_nodes := im.AcceptDragDropPayload("VOID_HIERARCHY_NODES", {}); p_nodes != nil && p_nodes.Data != nil {
			payload := (cast(^VH_Drag_Payload)p_nodes.Data)^
			g := undo.group_begin("Reparent Objects")
			defer undo.group_end(&g)
			undo.record_selection_snapshot()

			reparented := 0
			reparented_handles := make([dynamic]engine.Transform_Handle, context.temp_allocator)
			for i in 0 ..< payload.count {
				dragged_tH := payload.handles[i]
				if dragged_tH != tH && dragged_tH != {} && !_vh_is_ancestor(dragged_tH, tH) {
					undo.record_reparent_to(dragged_tH, tH)
					engine.transform_set_parent(dragged_tH, tH, -1, keep_world = true)
					append(&reparented_handles, dragged_tH)
					reparented += 1
				}
			}
			if reparented > 0 {
				if sc != nil do sc.dirty = true
				undo.group_commit(&g)
				engine.inspector_request_selection_batch(reparented_handles[:])
				_vh_selected_tH = reparented_handles[len(reparented_handles) - 1]
			}
		} else if p_node := im.AcceptDragDropPayload("VOID_HIERARCHY_NODE", {}); p_node != nil && p_node.Data != nil {
			dragged_tH := (cast(^engine.Transform_Handle)p_node.Data)^
			if dragged_tH != tH && dragged_tH != {} && !_vh_is_ancestor(dragged_tH, tH) {
				g := undo.group_begin("Reparent Object")
				defer undo.group_end(&g)
				undo.record_selection_snapshot()
				undo.record_reparent_to(dragged_tH, tH)
				engine.transform_set_parent(dragged_tH, tH, -1, keep_world = true)
				if sc != nil do sc.dirty = true
				undo.group_commit(&g)
				_vh_select_node(dragged_tH, ping = true)
			}
		}

		// 2. Drop asset from Void File Explorer (.scene, .mat, .png/.jpg, .fmesh, .glb/.gltf)
		if p_asset := im.AcceptDragDropPayload("ASSET_PATH", {}); p_asset != nil && p_asset.Data != nil {
			asset_path := string(([^]byte)(p_asset.Data)[:p_asset.DataSize])
			_vh_handle_asset_drop_on_node(tH, sc, asset_path)
		}
		im.EndDragDropTarget()
	}

	// Styled colored pill badge on the right of the node label (only drawn when it fits inside Col 0)
	if badge.type_name != "GameObject" || depth == 0 {
		pill_label_str := depth == 0 && badge.type_name == "GameObject" ? "ROOT" : badge.type_name
		pill_cstr := fmt.ctprintf("%s", pill_label_str)
		t_sz := im.CalcTextSize(pill_cstr)
		pill_w := t_sz.x + 10.0 * ui_s
		if im.GetItemRectMax().x + 8.0 * ui_s + pill_w <= col0_max_x - 2.0 {
			im.SameLine(0, 8.0 * ui_s)
			p_pos := im.GetCursorScreenPos()
			pill_min := im.Vec2{p_pos.x, p_pos.y + 1.0}
			pill_max := im.Vec2{p_pos.x + pill_w, p_pos.y + t_sz.y + 3.0 * ui_s}
			p_col := depth == 0 && badge.type_name == "GameObject" ? [4]f32{0.35, 0.78, 1.0, 1.0} : badge.color
			im.DrawList_AddRectFilled(dl, pill_min, pill_max, im.GetColorU32ImVec4({p_col.r, p_col.g, p_col.b, 0.16}), 4.0)
			im.DrawList_AddRect(dl, pill_min, pill_max, im.GetColorU32ImVec4({p_col.r, p_col.g, p_col.b, 0.45}), 4.0, 1.0)
			im.SetCursorScreenPos({p_pos.x + 5.0 * ui_s, p_pos.y + 1.0})
			im.TextColored({p_col.r, p_col.g, p_col.b, 0.92}, pill_cstr)
		}
	}

	// ── COL 1: GODOT SCRIPT CODE BUTTON (</>) ─────────────────────
	im.TableNextColumn()
	if code_key, code_type, has_code := _vh_node_find_code_key(t); has_code {
		im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
		im.PushStyleColorImVec4(.ButtonHovered, {0.20, 0.50, 0.85, 0.45})
		im.PushStyleColorImVec4(.ButtonActive, {0.30, 0.60, 0.95, 0.65})
		im.PushStyleColorImVec4(.Text, {0.35, 0.85, 0.95, 1.0})

		if im.SmallButton(fmt.ctprintf("%s##Code_%d", icons.ICON_MD_CODE, engine.Handle(tH).index)) {
			inspector.open_component_source(code_key)
		}
		if im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) do _vh_node_right_clicked_or_hovered = true
		im.PopStyleColor(4)

		path, line, _ := inspector.component_source_location(code_key)
		res_p, _ := file_exp.resolve_source_file_path(path)
		disp_p := res_p if res_p != "" else path
		widgets.tooltip(fmt.ctprintf("Jump to Code: %s\n%s:%d", code_type, disp_p, line))
	} else if arm_key, arm_type, has_arm := _vh_node_find_ancestor_armature_code_key(tH); has_arm {
		im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
		im.PushStyleColorImVec4(.ButtonHovered, {0.20, 0.50, 0.85, 0.35})
		im.PushStyleColorImVec4(.ButtonActive, {0.30, 0.60, 0.95, 0.55})
		im.PushStyleColorImVec4(.Text, {0.45, 0.65, 0.85, 0.60})

		if im.SmallButton(fmt.ctprintf("%s##CodeArm_%d", icons.ICON_MD_CODE, engine.Handle(tH).index)) {
			inspector.open_component_source(arm_key)
		}
		if im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) do _vh_node_right_clicked_or_hovered = true
		im.PopStyleColor(4)

		path, line, _ := inspector.component_source_location(arm_key)
		res_p, _ := file_exp.resolve_source_file_path(path)
		disp_p := res_p if res_p != "" else path
		widgets.tooltip(fmt.ctprintf("Jump to Armature Code: %s\n%s:%d", arm_type, disp_p, line))
	}

	// ── COL 2: GODOT LOCK TOGGLE (RIGHT-ALIGNED, NEVER INDENTS) ────
	im.TableNextColumn()
	is_locked := engine.node_is_locked(tH)
	is_parent_locked := !is_locked && engine.node_is_locked_in_hierarchy(tH)
	lock_icon := icons.ICON_MD_LOCK if (is_locked || is_parent_locked) else icons.ICON_MD_LOCK_OPEN
	lock_col := im.Vec4{1.0, 0.80, 0.20, 1.0} if is_locked else (im.Vec4{0.90, 0.65, 0.25, 0.70} if is_parent_locked else im.Vec4{0.60, 0.65, 0.75, 0.50})

	im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
	im.PushStyleColorImVec4(.ButtonHovered, {0.30, 0.35, 0.45, 0.45})
	im.PushStyleColorImVec4(.ButtonActive, {0.40, 0.50, 0.70, 0.65})
	im.PushStyleColorImVec4(.Text, lock_col)

	if im.SmallButton(fmt.ctprintf("%s##Lock_%d", lock_icon, engine.Handle(tH).index)) {
		engine.node_set_locked(tH, !is_locked)
	}
	if im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) do _vh_node_right_clicked_or_hovered = true
	im.PopStyleColor(4)

	if is_locked {
		widgets.tooltip("Locked: Frozen and protected against changes (Click to Unlock)")
	} else if is_parent_locked {
		widgets.tooltip("Inherited Lock: Parent node is locked (Click to Lock this node explicitly)")
	} else {
		widgets.tooltip("Unlocked (Click to Lock and Freeze)")
	}

	// ── COL 3: GODOT VISIBILITY EYE TOGGLE (RIGHT-ALIGNED, NEVER INDENTS) ──
	im.TableNextColumn()
	eye_icon := icons.ICON_MD_VISIBILITY if t.is_active else icons.ICON_MD_VISIBILITY_OFF
	eye_col := im.Vec4{0.90, 0.93, 1.0, 0.95} if t.is_active else im.Vec4{0.88, 0.35, 0.35, 0.85}

	im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
	im.PushStyleColorImVec4(.ButtonHovered, {0.30, 0.35, 0.45, 0.45})
	im.PushStyleColorImVec4(.ButtonActive, {0.40, 0.50, 0.70, 0.65})
	im.PushStyleColorImVec4(.Text, eye_col)

	if im.SmallButton(fmt.ctprintf("%s##Eye_%d", eye_icon, engine.Handle(tH).index)) {
		e := undo.edit_begin(tH, &t.is_active, typeid_of(bool), t.is_active ? "Hide Object" : "Show Object")
		t.is_active = !t.is_active
		undo.edit_end(&e)
		if t.scene != nil do t.scene.dirty = true
	}
	if im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) do _vh_node_right_clicked_or_hovered = true
	im.PopStyleColor(4)

	widgets.tooltip(t.is_active ? "Visible in Scene (Click to Hide)" : "Hidden in Scene (Click to Show)")

	// Recursively draw children
	if node_open && has_children {
		children_copy := make([]engine.Ref, len(t.children), context.temp_allocator)
		copy(children_copy, t.children[:])
		for child in children_copy {
			ch, ok := engine.scene_ref_resolve_transform(curr_sc, child, tH)
			if !ok && engine.pool_valid(&w.transforms, child.handle) {
				ch = engine.Transform_Handle(child.handle)
				ok = true
			}
			if !ok do continue
			_vh_draw_node(ch, curr_sc, filter, depth + 1)
		}
		im.TreePop()
	}

	im.PopID()
}

// ─────────────────────────────────────────────────────────────
// MAIN WINDOW ENTRY POINT
// ─────────────────────────────────────────────────────────────

@(editor_window={id="void_hierarchy", title="Void Hierarchy", icon="LAYERS", width=380, height=620})
void_hierarchy_window_draw :: proc() {
	scene := engine.sm_scene_get_active()
	if scene != nil {
		if !engine.application_is_playing() {
			if sm := engine.ctx_scene_manager(); sm != nil && sm.count > 1 {
				for i := sm.count - 1; i >= 0; i -= 1 {
					other := sm.loaded[i]
					if other == nil || other == scene do continue
					same_guid := scene.asset_guid != {} && other.asset_guid == scene.asset_guid
					same_path := len(scene.path) > 0 && len(other.path) > 0 &&
					             strings.equal_fold(_vh_to_asset_db_path(scene.path), _vh_to_asset_db_path(other.path))
					if same_guid || same_path {
						engine.sm_scene_unload(other)
					}
				}
			}
		}
		_vh_restore_scene_state(scene)
	}

	// Sync external selection from editor
	ext_sel := engine.inspector_active_selection()
	if ext_sel != {} {
		if ext_sel != _vh_selected_tH {
			_vh_selected_tH = ext_sel
			_vh_mark_prefs_dirty()
		}
		if _vh_anchor_tH == {} {
			_vh_anchor_tH = ext_sel
		}
	} else {
		all_sel := engine.inspector_selection_all()
		if len(all_sel) == 0 && _vh_restored_scene_ptr != nil {
			if _vh_selected_tH != {} {
				_vh_selected_tH = {}
				_vh_anchor_tH = {}
				_vh_mark_prefs_dirty()
			}
		}
	}

	// Keyboard shortcuts (Del, F2, Ctrl+C, Ctrl+V, Ctrl+D, A-Z letter jump)
	// Only active when the cursor is hovering Void Hierarchy so WASD in Scene3D never jumps between objects.
	if im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows) && !im.IsMouseDown(.Right) {
		_vh_handle_keyboard_shortcuts()
	}

	// ── SCENE HEADER BANNER CARD & TOP TOOLBAR ──────────────────
	w := engine.ctx_world()
	root_tH: engine.Transform_Handle = {}
	root_t: ^engine.Transform = nil
	if scene != nil && w != nil && engine.pool_valid(&w.transforms, scene.root.handle) {
		root_tH = engine.Transform_Handle(scene.root.handle)
		root_t  = engine.pool_get(&w.transforms, engine.Handle(root_tH))
	}

	ui_s := max(im.GetFontSize() / 14.0, 0.6)
	fh := im.GetFrameHeight()
	st := im.GetStyle()
	p := thm.palette()
	if scene != nil && root_t != nil {
		dl := im.GetWindowDrawList()
		card_pos := im.GetCursorScreenPos()
		card_w := im.GetContentRegionAvail().x
		pad_x := 6.0 * ui_s
		pad_y := 5.0 * ui_s

		scene_title := len(scene.path) > 0 ? filepath.stem(scene.path) : root_t.name
		switch_vis := fmt.ctprintf("%s  %s  %s", icons.ICON_MD_LAYERS, scene_title, icons.ICON_MD_EXPAND_MORE)
		switch_w := im.CalcTextSize(switch_vis).x + 16.0 * ui_s
		status_txt := scene.dirty ? "* UNSAVED" : "SAVED"
		status_cstr := fmt.ctprintf("[%s]", status_txt)
		status_w := im.CalcTextSize(status_cstr).x + 8.0 * ui_s
		save_w: f32 = (scene.dirty && len(scene.path) > 0) ? (im.CalcTextSize(fmt.ctprintf("%s Save", icons.ICON_MD_SAVE)).x + st.FramePadding.x * 2.0 + 8.0 * ui_s) : 0.0

		root_vis := fmt.ctprintf("%s Root Node", icons.ICON_MD_ADD)
		btn_w := math.ceil(im.CalcTextSize(root_vis).x + st.FramePadding.x * 2.0 + 8.0 * ui_s)
		btn_h := fh

		has_back := false
		prev_path := ""
		back_label: cstring = ""
		back_w: f32 = 0.0
		if _vh_prev_scene_path_len > 0 {
			prev_path = string(_vh_prev_scene_path_buf[:_vh_prev_scene_path_len])
			if !strings.equal_fold(filepath.stem(scene.path), filepath.stem(prev_path)) {
				has_back = true
				prev_stem := filepath.stem(prev_path)
				back_vis := fmt.ctprintf("%s %s", icons.ICON_MD_HISTORY, prev_stem)
				back_label = fmt.ctprintf("%s##VHBackSceneBtn", back_vis)
				back_w = clamp(math.ceil(im.CalcTextSize(back_vis).x + st.FramePadding.x * 2.0 + 8.0 * ui_s), 56.0 * ui_s, 160.0 * ui_s)
			}
		}

		left_total := pad_x + switch_w + status_w + save_w + 10.0 * ui_s
		right_total := btn_w + (has_back ? (back_w + 6.0 * ui_s) : 0.0) + pad_x
		wrap_banner := (left_total + right_total) > card_w
		card_h := wrap_banner ? (btn_h * 2.0 + pad_y * 3.0) : max(btn_h + pad_y * 2.0, 34.0 * ui_s)
		card_max := im.Vec2{card_pos.x + card_w, card_pos.y + card_h}

		im.DrawList_AddRectFilled(dl, card_pos, card_max, im.GetColorU32ImVec4(p.bg_elevated), 6.0)
		im.DrawList_AddRect(dl, card_pos, card_max, im.GetColorU32ImVec4(p.border_subtle), 6.0, 1.0)

		im.SetCursorScreenPos({card_pos.x + pad_x, card_pos.y + pad_y})

		// Interactive 1-click Scene Switcher button on the banner
		im.PushStyleColorImVec4(.Button, p.bg_panel)
		im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
		im.PushStyleColorImVec4(.ButtonActive, p.bg_active)
		im.PushStyleColorImVec4(.Text, p.accent)
		im.PushStyleVar(.FrameRounding, 4.0)
		im.PushStyleVarImVec2(.FramePadding, {8.0 * ui_s, st.FramePadding.y})
		if im.Button(fmt.ctprintf("%s##VHSceneSwitchBtn", switch_vis), {0, btn_h}) {
			if len(scene.path) > 0 {
				_vh_record_recent_scene(scene.path)
			}
			_vh_scene_nav_show_new_input = false
			im.OpenPopup("##VHSceneNavigatorPopup")
		}
		im.PopStyleVar(2)
		im.PopStyleColor(4)
		widgets.tooltip(fmt.ctprintf("Active Scene: %s\nClick to switch scenes, browse all project .scene files, or create a new scene", len(scene.path) > 0 ? scene.path : scene_title))

		_vh_draw_scene_navigator_popup(scene)

		im.SameLine(0, 6.0 * ui_s)
		status_col := scene.dirty ? p.status_warning : p.status_success
		im.AlignTextToFramePadding()
		im.TextColored(status_col, status_cstr)

		// 1-click Save button right on the banner when dirty
		if scene.dirty && len(scene.path) > 0 {
			im.SameLine(0, 4.0 * ui_s)
			im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_success, 0.20))
			im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.status_success, 0.32))
			im.PushStyleColorImVec4(.ButtonActive, thm.with_alpha(p.status_success, 0.40))
			im.PushStyleVar(.FrameRounding, 3.0)
			if im.SmallButton(fmt.ctprintf("%s Save##VHBannerSave", icons.ICON_MD_SAVE)) {
				engine.scene_save(scene, scene.path)
			}
			im.PopStyleVar()
			im.PopStyleColor(3)
			widgets.tooltip(fmt.ctprintf("Save '%s' (Ctrl+S)", scene.path))
		}

		right_row_y := wrap_banner ? (card_pos.y + pad_y * 2.0 + btn_h) : (card_pos.y + pad_y)
		right_start_x := max(card_pos.x + pad_x, card_max.x - right_total)

		// 1-click [< Back] button to return to the previous scene
		if has_back {
			im.SetCursorScreenPos({right_start_x, right_row_y})
			im.PushStyleColorImVec4(.Button, p.bg_panel)
			im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
			im.PushStyleColorImVec4(.ButtonActive, p.bg_active)
			im.PushStyleVar(.FrameRounding, 4.0)
			if im.Button(back_label, {back_w, btn_h}) {
				_vh_switch_to_scene_path(prev_path)
			}
			im.PopStyleVar()
			im.PopStyleColor(3)
			widgets.tooltip(fmt.ctprintf("Switch back to previous scene:\n%s", prev_path))
		}

		root_btn_x := has_back ? (right_start_x + back_w + 6.0 * ui_s) : max(card_pos.x + pad_x, card_max.x - btn_w - pad_x)
		im.SetCursorScreenPos({root_btn_x, right_row_y})
		im.PushStyleColorImVec4(.Button, p.accent_soft)
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.accent, 0.26))
		im.PushStyleColorImVec4(.ButtonActive, thm.with_alpha(p.accent, 0.34))
		im.PushStyleVar(.FrameRounding, 4.0)
		if im.Button(fmt.ctprintf("%s##VHQuickRootAdd", root_vis), {min(btn_w, max(48.0, card_max.x - root_btn_x - pad_x)), btn_h}) {
			_vh_select_node(root_tH)
			im.OpenPopup("##VHRootEmptySpacePopup")
		}
		im.PopStyleVar()
		im.PopStyleColor(3)
		widgets.tooltip("Add a new child node directly under the Scene Root")

		im.SetCursorScreenPos({card_pos.x, card_max.y + 5.0 * ui_s})
	}

	im.PushStyleVarImVec2(.ItemSpacing, {5.0 * ui_s, 6.0 * ui_s})
	im.PushStyleVar(.FrameRounding, 5.0)

	// [+ Add Node] Primary Button with dropdown
	im.PushStyleColorImVec4(.Button, p.accent_soft)
	im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.accent, 0.26))
	im.PushStyleColorImVec4(.ButtonActive, thm.with_alpha(p.accent, 0.34))
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.accent, 0.55))
	im.PushStyleVar(.FrameBorderSize, 1.0)
	if im.Button(fmt.ctprintf("%s  Add Node", icons.ICON_MD_ADD)) {
		im.OpenPopup("##VHAddNodePopup")
	}
	im.PopStyleVar()
	im.PopStyleColor(4)
	if im.BeginPopup("##VHAddNodePopup") {
		if _vh_selected_tH != {} && w != nil && engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) {
			sel_t := engine.pool_get(&w.transforms, engine.Handle(_vh_selected_tH))
			sel_name := sel_t != nil ? sel_t.name : "Selected"
			if im.BeginMenu(fmt.ctprintf("%s  Add as Child of '%s'", icons.ICON_MD_ADD, sel_name)) {
				_vh_draw_add_node_menu_items(force_root = false)
				im.EndMenu()
			}
			if im.BeginMenu(fmt.ctprintf("%s  Add at Scene Root", icons.ICON_MD_ACCOUNT_TREE)) {
				_vh_draw_add_node_menu_items(force_root = true)
				im.EndMenu()
			}
		} else {
			_vh_draw_add_node_menu_items(force_root = true)
		}
		im.EndPopup()
	}
	im.SameLine()
	can_sep_toolbar := _vh_selected_tH != {} && _vh_selected_tH != root_tH
	if !can_sep_toolbar do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s->Scene##VHSepToScene", icons.ICON_MD_OPEN_IN_NEW)) {
		_vh_open_separate_to_new_scene_modal()
	}
	if !can_sep_toolbar do im.EndDisabled()
	widgets.tooltip("Separate / Move Selected Object(s) into a brand-new .scene file (Ctrl+Shift+D)")

	im.SameLine()
	if im.Button(fmt.ctprintf("%s##CollapseAll", icons.ICON_MD_EXPAND_LESS)) {
		if sc := engine.sm_scene_get_active(); sc != nil {
			_vh_collapse_node_recursive(engine.Transform_Handle(sc.root.handle), sc)
			_vh_mark_prefs_dirty()
		}
	}
	widgets.tooltip("Collapse All Nodes Recursively")

	im.SameLine()
	is_docked := im.IsWindowDocked()
	dock_icon := is_docked ? icons.ICON_MD_OPEN_IN_NEW : icons.ICON_MD_DOCK
	if im.Button(fmt.ctprintf("%s##VHDockToggle", dock_icon)) {
		wnd.toggle_window_dock("void_hierarchy")
	}
	widgets.tooltip(is_docked ? "Dock Out as Floating Window" : "Dock Window Back into Workspace")

	// Filter Input with Clear button (wraps cleanly onto its own row if zoomed/narrow!)
	filter_str := strings.trim_space(string(cstring(raw_data(_vh_filter_buf[:]))))
	clear_btn_w := fh
	im.SameLine()
	avail_w := im.GetContentRegionAvail().x
	if avail_w < 120.0 * ui_s {
		im.NewLine()
		avail_w = im.GetContentRegionAvail().x
	}
	input_w := filter_str != "" ? (avail_w - clear_btn_w - 4.0 * ui_s) : avail_w
	im.SetNextItemWidth(max(60.0, input_w))
	im.PushStyleColorImVec4(.FrameBg, p.bg_recessed)
	im.InputTextWithHint("##VHFilter", "Search hierarchy...", cstring(raw_data(_vh_filter_buf[:])), len(_vh_filter_buf), {})
	im.PopStyleColor()

	if filter_str != "" {
		im.SameLine(0, 4.0 * ui_s)
		if im.Button(fmt.ctprintf("%s##ClearFilter", icons.ICON_MD_CLOSE), {clear_btn_w, 0}) {
			mem.zero(&_vh_filter_buf, len(_vh_filter_buf))
		}
	}

	im.PopStyleVar(2)
	im.Separator()

	// ── SCENE TREE VIEW (TABLE) ────────────────────────────────
	_vh_nav_count = 0
	_vh_node_right_clicked_or_hovered = false
	scene = engine.sm_scene_get_active()
	if scene == nil {
		im.TextDisabled("No active scene loaded.")
		return
	}

	if w == nil || !engine.pool_valid(&w.transforms, scene.root.handle) {
		im.TextDisabled("Active scene root not found.")
		return
	}

	root_tH = engine.Transform_Handle(scene.root.handle)
	root_t = engine.pool_get(&w.transforms, engine.Handle(root_tH))
	if root_t == nil {
		im.TextDisabled("Root transform invalid.")
		return
	}

	flags := im.TableFlags_BordersInnerV | im.TableFlags_BordersOuter | im.TableFlags_RowBg | im.TableFlags_Resizable | im.TableFlags_ScrollY
	avail_size := im.GetContentRegionAvail()
	bottom_bar_h := fh + 8.0 * ui_s
	table_h := max(100.0, avail_size.y - bottom_bar_h)

	hdr_icon_w := max(
		im.CalcTextSize(fmt.ctprintf(" %s ", icons.ICON_MD_CODE)).x,
		im.CalcTextSize(fmt.ctprintf(" %s ", icons.ICON_MD_VISIBILITY_OFF)).x,
	)
	btn_icon_w := im.CalcTextSize(icons.ICON_MD_VISIBILITY_OFF).x + st.FramePadding.x * 2.0
	icon_col_w := math.ceil(max(hdr_icon_w, btn_icon_w) + st.CellPadding.x * 2.0 + 6.0 * ui_s)

	im.PushStyleColorImVec4(.TableRowBg, {0, 0, 0, 0})
	im.PushStyleColorImVec4(.TableRowBgAlt, thm.with_alpha(p.bg_elevated, p.is_light ? 0.45 : 0.32))
	im.PushStyleColorImVec4(.Header, p.accent_soft)
	im.PushStyleColorImVec4(.HeaderHovered, thm.with_alpha(p.accent, p.is_light ? 0.20 : 0.26))
	im.PushStyleColorImVec4(.HeaderActive, thm.with_alpha(p.accent, p.is_light ? 0.28 : 0.34))

	if im.BeginTable("##VoidHierarchyTreeTable", 4, flags, {0, table_h}) {
		im.TableSetupColumn("Scene Hierarchy", {.WidthStretch}, 1.0)
		im.TableSetupColumn(fmt.ctprintf(" %s ##ColCode", icons.ICON_MD_CODE), {.WidthFixed}, icon_col_w)
		im.TableSetupColumn(fmt.ctprintf(" %s ##ColLock", icons.ICON_MD_LOCK), {.WidthFixed}, icon_col_w)
		im.TableSetupColumn(fmt.ctprintf(" %s ##ColVis", icons.ICON_MD_VISIBILITY), {.WidthFixed}, icon_col_w)
		im.TableHeadersRow()

		filter_trimmed := strings.trim_space(filter_str)

		// Draw root and recursive tree
		_vh_draw_node(root_tH, scene, filter_trimmed, 0)

		// Empty-space right-click inside the scrollable table child window
		if im.BeginPopupContextWindow("##VHTableEmptyCtx", im.PopupFlags_NoOpenOverItems) {
			_vh_node_right_clicked_or_hovered = true
			_vh_draw_root_empty_space_menu(root_tH, root_t, scene)
			im.EndPopup()
		}

		im.EndTable()
	}
	im.PopStyleColor(5)

	// Process deferred mouse release on already-selected items (preserves multi-selection drag & drop)
	if im.IsMouseDragging(.Left, 4.0) {
		_vh_is_dragging = true
		_vh_deferred_toggle_tH = {}
		_vh_deferred_select_tH = {}
	}

	if im.IsMouseReleased(.Left) {
		if !_vh_is_dragging && !im.IsMouseDragging(.Left, 4.0) {
			if _vh_deferred_toggle_tH != {} {
				_vh_toggle_select_node(_vh_deferred_toggle_tH)
			} else if _vh_deferred_select_tH != {} {
				_vh_select_node(_vh_deferred_select_tH)
			}
		}
		_vh_deferred_toggle_tH = {}
		_vh_deferred_select_tH = {}
		_vh_is_dragging = false
	}

	// Process deferred Shift-click range selection over complete visual tree
	if _vh_range_pending != {} {
		target := _vh_range_pending
		_vh_range_pending = {}
		_vh_range_select_node(target)
	}
	_vh_force_close_all = false

	// Guaranteed empty-space right-click anywhere in Void Hierarchy (inside table empty space or window background)
	// when not right-clicking on a node: selects Root and opens the Root Add Node popup!
	if im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows) &&
	   im.IsMouseReleased(.Right) &&
	   !_vh_node_right_clicked_or_hovered &&
	   !im.IsPopupOpen("", im.PopupFlags_AnyPopupId) {
		_vh_select_node(root_tH)
		im.OpenPopup("##VHRootEmptySpacePopup")
	}

	if im.BeginPopup("##VHRootEmptySpacePopup") {
		_vh_draw_root_empty_space_menu(root_tH, root_t, scene)
		im.EndPopup()
	}

	if im.BeginPopupContextWindow("##VHBackgroundCtx", im.PopupFlags_NoOpenOverItems) {
		_vh_draw_root_empty_space_menu(root_tH, root_t, scene)
		im.EndPopup()
	}

	// Empty space drop target: reparent to scene root (keep_world = true)
	if im.BeginDragDropTarget() {
		if p_nodes := im.AcceptDragDropPayload("VOID_HIERARCHY_NODES", {}); p_nodes != nil && p_nodes.Data != nil {
			payload := (cast(^VH_Drag_Payload)p_nodes.Data)^
			g := undo.group_begin("Reparent to Root")
			defer undo.group_end(&g)
			undo.record_selection_snapshot()

			reparented := 0
			reparented_handles := make([dynamic]engine.Transform_Handle, context.temp_allocator)
			for i in 0 ..< payload.count {
				dragged_tH := payload.handles[i]
				if dragged_tH != {} && dragged_tH != root_tH && !_vh_is_ancestor(dragged_tH, root_tH) {
					undo.record_reparent_to(dragged_tH, root_tH)
					engine.transform_set_parent(dragged_tH, root_tH, -1, keep_world = true)
					append(&reparented_handles, dragged_tH)
					reparented += 1
				}
			}
			if reparented > 0 {
				scene.dirty = true
				undo.group_commit(&g)
				engine.inspector_request_selection_batch(reparented_handles[:])
				_vh_selected_tH = reparented_handles[len(reparented_handles) - 1]
			}
		} else if p_node := im.AcceptDragDropPayload("VOID_HIERARCHY_NODE", {}); p_node != nil && p_node.Data != nil {
			dragged_tH := (cast(^engine.Transform_Handle)p_node.Data)^
			if dragged_tH != {} && dragged_tH != root_tH {
				g := undo.group_begin("Reparent to Root")
				defer undo.group_end(&g)
				undo.record_selection_snapshot()
				undo.record_reparent_to(dragged_tH, root_tH)
				engine.transform_set_parent(dragged_tH, root_tH, -1, keep_world = true)
				scene.dirty = true
				undo.group_commit(&g)
			}
		} else if p_asset := im.AcceptDragDropPayload("ASSET_PATH", {}); p_asset != nil && p_asset.Data != nil {
			asset_path := string(([^]byte)(p_asset.Data)[:p_asset.DataSize])
			_vh_handle_asset_drop_on_node(root_tH, scene, asset_path)
		}
		im.EndDragDropTarget()
	}

	// Bottom Status Bar
	im.Separator()
	im.TextDisabled(fmt.ctprintf("%s %d nodes", icons.ICON_MD_ACCOUNT_TREE, _vh_nav_count))
	all_sel := engine.inspector_selection_all()
	if len(all_sel) > 1 {
		im.SameLine(0, 14)
		im.TextColored(p.accent, fmt.ctprintf("Selected: %d objects", len(all_sel)))
	} else if _vh_selected_tH != {} && engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) {
		sel_t := engine.pool_get(&w.transforms, engine.Handle(_vh_selected_tH))
		if sel_t != nil {
			badge := _vh_get_badge(sel_t, _vh_selected_tH, scene)
			im.SameLine(0, 14)
			im.TextColored(thm.adapt_badge_color(badge.color), fmt.ctprintf("%s %s [%s]", badge.icon, sel_t.name, badge.type_name))
		}
	} else {
		im.SameLine(0, 14)
		im.TextDisabled("Right-click empty space to add to Root")
	}

	// Snapshot visible nodes for range selection across frames
	if _vh_nav_count > 0 {
		copy(_vh_visible_list[:_vh_nav_count], _vh_nav_list[:_vh_nav_count])
		_vh_visible_count = _vh_nav_count
	}

	if scene != nil {
		_vh_tick_save(scene, im.GetIO().DeltaTime)
	}

	_draw_instantiate_scene_modal()
	_draw_separate_to_new_scene_modal()
	_draw_new_odin_component_modal()
}

@(private = "file")
_vh_collect_top_level_selected_for_separate :: proc(alloc := context.temp_allocator) -> [dynamic]engine.Transform_Handle {
	out := make([dynamic]engine.Transform_Handle, 0, 8, alloc)
	w := engine.ctx_world()
	if w == nil do return out

	raw := make([dynamic]engine.Transform_Handle, 0, 8, context.temp_allocator)
	all_sel := engine.inspector_selection_all()
	if len(all_sel) > 0 {
		for h in all_sel {
			if h == {} || !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil || t.parent.handle == {} do continue // Skip scene root
			append(&raw, h)
		}
	} else if _vh_selected_tH != {} && engine.pool_valid(&w.transforms, engine.Handle(_vh_selected_tH)) {
		t := engine.pool_get(&w.transforms, engine.Handle(_vh_selected_tH))
		if t != nil && t.parent.handle != {} {
			append(&raw, _vh_selected_tH)
		}
	}

	// Filter out any selected node whose ancestor is also in `raw` so subtrees are never duplicated
	for h in raw {
		has_sel_ancestor := false
		for other in raw {
			if other != h && _vh_is_ancestor(other, h) {
				has_sel_ancestor = true
				break
			}
		}
		if !has_sel_ancestor {
			append(&out, h)
		}
	}
	return out
}

// ─────────────────────────────────────────────────────────────
// SCENE DISCOVERY, QUICK SCENE SWITCHER & NAVIGATION HELPERS
// ─────────────────────────────────────────────────────────────

VH_Project_Scene_Entry :: struct {
	guid:        engine.Asset_GUID,
	disk_path:   string,
	display_dir: string,
	name:        string,
}

@(private = "file")
_vh_fast_display_scene_path :: proc(path: string, alloc := context.temp_allocator) -> string {
	trimmed := strings.trim_space(path)
	if len(trimmed) == 0 do return ""
	norm, _ := strings.replace_all(trimmed, "\\", "/", alloc)
	if strings.has_prefix(norm, "packages/") {
		after_pkg := strings.trim_prefix(norm, "packages/")
		return fmt.tprintf("../plugins/%s", after_pkg)
	}
	return norm
}

@(private = "package")
_vh_normalize_scene_disk_path :: proc(path: string, alloc := context.temp_allocator) -> string {
	trimmed := strings.trim_space(path)
	if len(trimmed) == 0 do return ""
	resolved := _resolve_disk_path_from_db_path(trimmed, alloc)
	norm, _ := strings.replace_all(resolved, "\\", "/", alloc)
	return norm
}

@(private = "file")
_vh_record_recent_scene :: proc(path: string) {
	norm := _vh_fast_display_scene_path(path, context.temp_allocator)
	if len(norm) == 0 do return

	// Remove existing duplicate entry if already in recent list
	existing_idx := -1
	for i in 0 ..< _vh_recent_scenes_count {
		cur := string(_vh_recent_scenes_buf[i][:_vh_recent_scenes_len[i]])
		if strings.equal_fold(cur, norm) || strings.equal_fold(filepath.stem(cur), filepath.stem(norm)) {
			existing_idx = i
			break
		}
	}

	if existing_idx == 0 {
		return
	}

	limit := existing_idx if existing_idx > 0 else min(_vh_recent_scenes_count, len(_vh_recent_scenes_buf) - 1)
	for i := limit; i > 0; i -= 1 {
		_vh_recent_scenes_buf[i] = _vh_recent_scenes_buf[i - 1]
		_vh_recent_scenes_len[i] = _vh_recent_scenes_len[i - 1]
	}

	n := min(len(norm), len(_vh_recent_scenes_buf[0]) - 1)
	mem.zero(&_vh_recent_scenes_buf[0], len(_vh_recent_scenes_buf[0]))
	copy(_vh_recent_scenes_buf[0][:n], norm[:n])
	_vh_recent_scenes_len[0] = n
	if existing_idx < 0 && _vh_recent_scenes_count < len(_vh_recent_scenes_buf) {
		_vh_recent_scenes_count += 1
	}
}

@(private = "file")
_vh_switch_to_scene_path :: proc(raw_path: string) -> bool {
	disk_path := _vh_normalize_scene_disk_path(raw_path, context.temp_allocator)
	if len(disk_path) == 0 || !os.exists(disk_path) {
		fmt.printfln("[Void Hierarchy] Cannot switch to scene (file not found): '%s'", raw_path)
		return false
	}

	cur_sc := engine.sm_scene_get_active()
	if cur_sc != nil && len(cur_sc.path) > 0 {
		cur_norm := _vh_normalize_scene_disk_path(cur_sc.path, context.temp_allocator)
		if !strings.equal_fold(cur_norm, disk_path) {
			mem.zero(&_vh_prev_scene_path_buf, len(_vh_prev_scene_path_buf))
			pn := min(len(cur_norm), len(_vh_prev_scene_path_buf) - 1)
			copy(_vh_prev_scene_path_buf[:pn], cur_norm[:pn])
			_vh_prev_scene_path_len = pn
		}
		_vh_record_recent_scene(cur_norm)
		if cur_sc.dirty && _vh_auto_save_on_scene_switch {
			engine.scene_save(cur_sc, cur_sc.path)
		}
	}

	_vh_record_recent_scene(disk_path)

	undo.purge_scenes(undo.get())
	load_path := disk_path
	if db_p := _vh_to_asset_db_path(disk_path, context.temp_allocator); len(db_p) > 0 && os.exists(db_p) {
		load_path = db_p
	}
	loaded_sc := engine.scene_load_single_path(load_path)
	if loaded_sc == nil {
		fmt.printfln("[Void Hierarchy] Failed to load scene: '%s'", disk_path)
		return false
	}
	engine.sm_scene_set_active(loaded_sc)

	_vh_selected_tH = {}
	_vh_anchor_tH = {}

	// Sync Void File Explorer to the switched scene's folder so the user can see it immediately
	// NOTE: filepath.dir returns a slice into disk_path — never delete it!
	sc_dir := filepath.dir(disk_path)
	norm_dir, _ := strings.replace_all(sc_dir, "\\", "/", context.temp_allocator)
	if len(norm_dir) > 0 && os.is_dir(norm_dir) {
		_navigate_to(norm_dir)
		_set_selection_by_path(disk_path)
	}

	return true
}

@(private = "file")
_vh_collect_all_project_scenes :: proc(alloc := context.temp_allocator) -> [dynamic]VH_Project_Scene_Entry {
	out := make([dynamic]VH_Project_Scene_Entry, 0, 32, alloc)
	seen := make(map[string]bool, 64, alloc)

	// 1. Pure in-memory collection from engine.asset_db (zero disk I/O per frame!)
	for id, path in engine.asset_db.guid_to_path {
		if !strings.has_suffix(strings.to_lower(path, alloc), ".scene") do continue
		disk_p := _vh_fast_display_scene_path(path, alloc)
		if len(disk_p) == 0 do continue
		stem := filepath.stem(disk_p)
		key := strings.to_lower(stem, alloc)
		if key in seen do continue
		seen[key] = true

		dir_raw := filepath.dir(disk_p) // slice into disk_p — do NOT delete!
		norm_dir, _ := strings.replace_all(dir_raw, "\\", "/", alloc)

		append(&out, VH_Project_Scene_Entry{
			guid        = engine.Asset_GUID(id),
			disk_path   = disk_p,
			display_dir = norm_dir,
			name        = stem,
		})
	}

	// 2. Also include any scenes in session recent history (e.g. newly separated scenes before asset_db refresh)
	for i in 0 ..< _vh_recent_scenes_count {
		r_path := string(_vh_recent_scenes_buf[i][:_vh_recent_scenes_len[i]])
		if len(r_path) == 0 do continue
		stem := filepath.stem(r_path)
		key := strings.to_lower(stem, alloc)
		if key in seen do continue
		seen[key] = true

		dir_raw := filepath.dir(r_path) // slice into r_path — do NOT delete!
		norm_dir, _ := strings.replace_all(dir_raw, "\\", "/", alloc)
		resolved_guid, _ := engine.asset_db_get_guid(_vh_to_asset_db_path(r_path, alloc))

		append(&out, VH_Project_Scene_Entry{
			guid        = engine.Asset_GUID(resolved_guid),
			disk_path   = r_path,
			display_dir = norm_dir,
			name        = stem,
		})
	}

	slice.sort_by(out[:], proc(a, b: VH_Project_Scene_Entry) -> bool {
		if a.name != b.name do return a.name < b.name
		return a.disk_path < b.disk_path
	})
	return out
}

@(private = "file")
_vh_collect_all_project_folders :: proc(alloc := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 16, alloc)
	seen := make(map[string]bool, 32, alloc)

	add_folder :: proc(raw: string, seen: ^map[string]bool, out: ^[dynamic]string, alloc: mem.Allocator) {
		trimmed := strings.trim_space(raw)
		if len(trimmed) == 0 || trimmed == "." || trimmed == ".." do return
		norm, _ := strings.replace_all(trimmed, "\\", "/", alloc)
		norm = strings.trim_right(norm, "/")
		if len(norm) == 0 || norm == "." || norm == ".." do return
		key := strings.to_lower(norm, alloc)
		if key in seen^ do return
		seen^[key] = true
		append(out, norm)
	}

	// Priority 1: Active scene directory (filepath.dir is a slice — do NOT delete!)
	if sc := engine.sm_scene_get_active(); sc != nil && len(sc.path) > 0 {
		d := filepath.dir(sc.path)
		add_folder(d, &seen, &out, alloc)
	}

	// Priority 2: Current Void File Explorer directory (if inside a specific subfolder)
	if exp_dir := _get_current_dir(); len(exp_dir) > 0 && exp_dir != "." && exp_dir != ".." {
		add_folder(exp_dir, &seen, &out, alloc)
	}

	// Priority 3: Any directory containing a .scene file in asset_db
	all_scenes := _vh_collect_all_project_scenes(alloc)
	for s in all_scenes {
		add_folder(s.display_dir, &seen, &out, alloc)
	}

	// Priority 4: Standard project scene/level directories (pure in-memory strings)
	add_folder("../plugins/void_odin/Levels", &seen, &out, alloc)
	add_folder("../plugins/void_odin/assets", &seen, &out, alloc)
	add_folder("assets/scenes", &seen, &out, alloc)

	return out
}

@(private = "file")
_vh_set_dir_buf :: proc(dir_str: string) {
	mem.zero(&_vh_separate_scene_dir_buf, len(_vh_separate_scene_dir_buf))
	norm, _ := strings.replace_all(dir_str, "\\", "/", context.temp_allocator)
	norm = strings.trim_right(norm, "/")
	n := min(len(norm), len(_vh_separate_scene_dir_buf) - 1)
	copy(_vh_separate_scene_dir_buf[:n], norm[:n])
}

@(private = "file")
_vh_set_name_buf :: proc(name_str: string) {
	mem.zero(&_vh_separate_scene_name_buf, len(_vh_separate_scene_name_buf))
	n := min(len(name_str), len(_vh_separate_scene_name_buf) - 1)
	copy(_vh_separate_scene_name_buf[:n], name_str[:n])
}

@(private = "file")
_vh_draw_scene_navigator_popup :: proc(cur_sc: ^engine.Scene) {
	im.SetNextWindowSize({520, 470}, .Always)
	if !im.BeginPopup("##VHSceneNavigatorPopup") do return
	defer im.EndPopup()

	cur_norm := cur_sc != nil ? _vh_fast_display_scene_path(cur_sc.path, context.temp_allocator) : ""

	im.TextColored({0.38, 0.86, 1.0, 1.0}, fmt.ctprintf("%s  Quick Scene Navigator", icons.ICON_MD_LAYERS))
	im.SameLine(300.0)
	im.Checkbox("Auto-Save on Switch", &_vh_auto_save_on_scene_switch)
	widgets.tooltip("Automatically saves the current scene if it has unsaved changes before switching to another scene")

	im.Separator()
	im.Spacing()

	// Top quick action row: [+ New Empty Scene], [Rename Scene], [Reveal in Explorer], [Separate Selected...]
	im.PushStyleColorImVec4(.Button, {0.16, 0.44, 0.30, 0.92})
	im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.58, 0.40, 1.0})
	if im.Button(fmt.ctprintf("%s New Empty Scene", icons.ICON_MD_ADD)) {
		_vh_scene_nav_show_new_input = !_vh_scene_nav_show_new_input
		_vh_scene_nav_show_rename_input = false
		if _vh_scene_nav_show_new_input {
			default_new := "New_Scene"
			mem.zero(&_vh_scene_nav_new_name_buf, len(_vh_scene_nav_new_name_buf))
			copy(_vh_scene_nav_new_name_buf[:len(default_new)], default_new)
		}
	}
	im.PopStyleColor(2)
	widgets.tooltip("Create a brand-new empty .scene in the current scene's folder and switch to it immediately")

	if len(cur_norm) > 0 {
		im.SameLine(0, 6)
		if im.Button(fmt.ctprintf("%s Rename Scene", icons.ICON_MD_EDIT)) {
			_vh_scene_nav_show_rename_input = !_vh_scene_nav_show_rename_input
			_vh_scene_nav_show_new_input = false
			if _vh_scene_nav_show_rename_input {
				cur_stem := filepath.stem(cur_norm)
				mem.zero(&_vh_scene_nav_rename_buf, len(_vh_scene_nav_rename_buf))
				n := min(len(cur_stem), len(_vh_scene_nav_rename_buf) - 1)
				copy(_vh_scene_nav_rename_buf[:n], cur_stem[:n])
			}
		}
		widgets.tooltip(fmt.ctprintf("Rename the current scene file ('%s') on disk", filepath.base(cur_norm)))

		im.SameLine(0, 6)
		if im.Button(fmt.ctprintf("%s Reveal in Explorer", icons.ICON_MD_FOLDER)) {
			disk_cur := _vh_normalize_scene_disk_path(cur_norm, context.temp_allocator)
			d := filepath.dir(disk_cur) // slice into disk_cur — do NOT delete!
			norm_d, _ := strings.replace_all(d, "\\", "/", context.temp_allocator)
			if os.is_dir(norm_d) {
				_navigate_to(norm_d)
				_set_selection_by_path(disk_cur)
			}
			im.CloseCurrentPopup()
		}
		widgets.tooltip(fmt.ctprintf("Highlight '%s' in Void File Explorer", cur_norm))
	}

	sep_targets := _vh_collect_top_level_selected_for_separate(context.temp_allocator)
	if len(sep_targets) > 0 {
		im.SameLine(0, 6)
		im.PushStyleColorImVec4(.Button, {0.18, 0.38, 0.68, 0.92})
		if im.Button(fmt.ctprintf("%s Move (%d)...", icons.ICON_MD_OPEN_IN_NEW, len(sep_targets))) {
			im.CloseCurrentPopup()
			_vh_open_separate_to_new_scene_modal()
		}
		im.PopStyleColor(1)
		widgets.tooltip("Separate or move the currently selected hierarchy objects into another scene")
	}

	// Inline [Rename Scene] bar
	if _vh_scene_nav_show_rename_input && cur_sc != nil && len(cur_norm) > 0 {
		im.Spacing()
		im.PushStyleColorImVec4(.ChildBg, {0.18, 0.16, 0.24, 0.95})
		if im.BeginChild("##VHRenameSceneBox", {500, 38}, {.Borders}) {
			im.SetNextItemWidth(260)
			ren_enter := im.InputTextWithHint("##VHRenameSceneInput", "New scene name...", cstring(raw_data(_vh_scene_nav_rename_buf[:])), len(_vh_scene_nav_rename_buf), {.EnterReturnsTrue})
			im.SameLine(0, 6)
			if im.Button(fmt.ctprintf("%s Apply Rename", icons.ICON_MD_CHECK)) || ren_enter {
				raw_ren := strings.trim_space(string(cstring(raw_data(_vh_scene_nav_rename_buf[:]))))
				if len(raw_ren) > 0 {
					if !strings.has_suffix(strings.to_lower(raw_ren, context.temp_allocator), ".scene") {
						raw_ren = fmt.tprintf("%s.scene", raw_ren)
					}
					disk_cur := _vh_normalize_scene_disk_path(cur_sc.path, context.temp_allocator)
					if os.exists(disk_cur) {
						if new_p, ok := file_exp.rename_entry(disk_cur, raw_ren); ok {
							defer delete(new_p)
							delete(cur_sc.path)
							cur_sc.path = strings.clone(new_p)
							_vh_record_recent_scene(new_p)
							engine.asset_db_request_refresh()
							_needs_refresh = true
							_vh_scene_nav_show_rename_input = false
						}
					} else {
						// File was already renamed on disk in same folder; point cur_sc.path to it
						d := filepath.dir(disk_cur) // slice — do NOT delete!
						cand, _ := filepath.join({d, raw_ren}, context.temp_allocator)
						norm_cand, _ := strings.replace_all(cand, "\\", "/", context.temp_allocator)
						if os.exists(norm_cand) {
							delete(cur_sc.path)
							cur_sc.path = strings.clone(norm_cand)
							_vh_scene_nav_show_rename_input = false
						}
					}
				}
			}
			im.SameLine(0, 4)
			if im.Button("Cancel##VHRenameSceneCancel") {
				_vh_scene_nav_show_rename_input = false
			}
		}
		im.EndChild()
		im.PopStyleColor(1)
	}

	// Inline [+ New Empty Scene] creator bar
	if _vh_scene_nav_show_new_input {
		im.Spacing()
		im.PushStyleColorImVec4(.ChildBg, {0.12, 0.17, 0.24, 0.95})
		if im.BeginChild("##VHNewEmptySceneBox", {500, 38}, {.Borders}) {
			im.SetNextItemWidth(250)
			enter_pressed := im.InputTextWithHint("##VHNewSceneInput", "Scene name...", cstring(raw_data(_vh_scene_nav_new_name_buf[:])), len(_vh_scene_nav_new_name_buf), {.EnterReturnsTrue})
			im.SameLine(0, 6)
			if im.Button(fmt.ctprintf("%s Create & Open", icons.ICON_MD_CHECK)) || enter_pressed {
				raw_new := strings.trim_space(string(cstring(raw_data(_vh_scene_nav_new_name_buf[:]))))
				if len(raw_new) == 0 do raw_new = "New_Scene"
				if strings.has_suffix(strings.to_lower(raw_new, context.temp_allocator), ".scene") {
					raw_new = raw_new[:len(raw_new) - 6]
				}
				target_dir := "assets/scenes"
				if len(cur_norm) > 0 {
					d := filepath.dir(cur_norm) // slice into cur_norm — do NOT delete!
					nd, _ := strings.replace_all(d, "\\", "/", context.temp_allocator)
					if len(nd) > 0 && nd != "." do target_dir = nd
				} else if exp_d := _get_current_dir(); len(exp_d) > 0 && exp_d != "." && exp_d != ".." {
					nd, _ := strings.replace_all(exp_d, "\\", "/", context.temp_allocator)
					target_dir = nd
				}
				_ = os.make_directory(target_dir)
				new_scene_path := fmt.tprintf("%s/%s.scene", strings.trim_right(target_dir, "/"), raw_new)
				if engine.scene_save_empty_to_file(raw_new, new_scene_path) {
					engine.asset_db_request_refresh()
					_needs_refresh = true
					_vh_scene_nav_show_new_input = false
					_vh_switch_to_scene_path(new_scene_path)
					im.CloseCurrentPopup()
				}
			}
			im.SameLine(0, 4)
			if im.Button("Cancel##VHNewSceneCancel") {
				_vh_scene_nav_show_new_input = false
			}
		}
		im.EndChild()
		im.PopStyleColor(1)
	}

	im.Spacing()

	// Search filter input
	filter_str := strings.trim_space(string(cstring(raw_data(_vh_scene_nav_search_buf[:]))))
	filter_lower := strings.to_lower(filter_str, context.temp_allocator)

	im.SetNextItemWidth(len(filter_str) > 0 ? 464.0 : 500.0)
	im.InputTextWithHint("##VHSceneNavSearch", fmt.ctprintf("%s  Filter scenes by name or folder...", icons.ICON_MD_SEARCH), cstring(raw_data(_vh_scene_nav_search_buf[:])), len(_vh_scene_nav_search_buf), {})
	if len(filter_str) > 0 {
		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s##VHClearSceneSearch", icons.ICON_MD_CLOSE), {28, 0}) {
			mem.zero(&_vh_scene_nav_search_buf, len(_vh_scene_nav_search_buf))
			filter_str = ""
			filter_lower = ""
		}
	}

	// Recent / Session Scenes Quick Chips (when not filtering — pure in-memory check!)
	if len(filter_lower) == 0 && _vh_recent_scenes_count > 1 {
		im.Spacing()
		im.TextColored({0.95, 0.80, 0.35, 0.95}, fmt.ctprintf("%s  Recent in Session:", icons.ICON_MD_HISTORY))
		shown_recent := 0
		for i in 0 ..< _vh_recent_scenes_count {
			r_path := string(_vh_recent_scenes_buf[i][:_vh_recent_scenes_len[i]])
			if len(r_path) == 0 || strings.equal_fold(filepath.stem(r_path), filepath.stem(cur_norm)) do continue
			r_stem := filepath.stem(r_path)
			if shown_recent > 0 do im.SameLine(0, 5)
			im.PushStyleColorImVec4(.Button, {0.16, 0.25, 0.38, 0.92})
			im.PushStyleColorImVec4(.ButtonHovered, {0.24, 0.38, 0.58, 1.0})
			if im.SmallButton(fmt.ctprintf("%s %s##VHRecent_%d", icons.ICON_MD_OPEN_IN_NEW, r_stem, i)) {
				if _vh_switch_to_scene_path(r_path) {
					im.CloseCurrentPopup()
				}
			}
			im.PopStyleColor(2)
			widgets.tooltip(fmt.ctprintf("Switch to '%s'", r_path))
			shown_recent += 1
			if shown_recent >= 4 do break
		}
	}

	im.Spacing()
	all_scenes := _vh_collect_all_project_scenes(context.temp_allocator)
	im.TextColored({0.65, 0.78, 0.95, 1.0}, fmt.ctprintf("All Project Scenes (%d):", len(all_scenes)))

	list_h: f32 = (_vh_scene_nav_show_new_input || _vh_scene_nav_show_rename_input) ? 195.0 : 240.0
	if im.BeginChild("##VHSceneNavList", {500, list_h}, {.Borders}) {
		shown_count := 0
		for sc_entry, idx in all_scenes {
			if len(filter_lower) > 0 {
				if !strings.contains(strings.to_lower(sc_entry.name, context.temp_allocator), filter_lower) &&
				   !strings.contains(strings.to_lower(sc_entry.display_dir, context.temp_allocator), filter_lower) {
					continue
				}
			}
			shown_count += 1
			is_active := strings.equal_fold(sc_entry.disk_path, cur_norm)

			im.PushIDInt(i32(idx))
			avail_w: f32 = 478.0
			action_reserve: f32 = 86.0

			if is_active {
				im.PushStyleColorImVec4(.Text, {0.30, 0.95, 0.58, 1.0})
			}
			row_label := fmt.ctprintf(
				"%s  %s%s   [%s]##SceneRow",
				is_active ? icons.ICON_MD_CHECK : icons.ICON_MD_LAYERS,
				sc_entry.name,
				is_active ? " (ACTIVE)" : "",
				sc_entry.display_dir,
			)
			if im.Selectable(row_label, is_active, {}, {avail_w - action_reserve, 22}) {
				if !is_active {
					if _vh_switch_to_scene_path(sc_entry.disk_path) {
						im.CloseCurrentPopup()
					}
				}
			}
			if is_active {
				im.PopStyleColor(1)
			}
			widgets.tooltip(fmt.ctprintf("Click to open '%s'", sc_entry.disk_path))

			// Right-side quick buttons: [Folder] and [+ Child]
			im.SameLine(avail_w - action_reserve + 8.0)
			if im.SmallButton(fmt.ctprintf("%s##Rev", icons.ICON_MD_FOLDER)) {
				if os.is_dir(sc_entry.display_dir) {
					_navigate_to(sc_entry.display_dir)
					_set_selection_by_path(sc_entry.disk_path)
				}
			}
			widgets.tooltip(fmt.ctprintf("Reveal '%s' in Void File Explorer", sc_entry.disk_path))

			im.SameLine(0, 4)
			can_nest := !is_active && sc_entry.guid != {} && cur_sc != nil
			if !can_nest do im.BeginDisabled()
			if im.SmallButton("+Child##Nest") {
				parent_tH := engine.Transform_Handle(cur_sc.root.handle)
				if _vh_selected_tH != {} do parent_tH = _vh_selected_tH
				inst_h := engine.scene_instantiate_guid_nested(sc_entry.guid, parent_tH)
				if inst_h != {} {
					engine.transform_ensure_unique_name(inst_h)
					cur_sc.dirty = true
					_vh_select_node(inst_h, ping = true)
					im.CloseCurrentPopup()
				}
			}
			if !can_nest do im.EndDisabled()
			widgets.tooltip("Instantiate this scene as a Nested Child Node in the current scene")

			im.PopID()
		}

		if shown_count == 0 {
			im.TextDisabled("No matching .scene files found.")
		}
	}
	im.EndChild()
}

// ─────────────────────────────────────────────────────────────
// SEPARATE / MOVE SELECTED OBJECTS TO NEW OR EXISTING SCENE
// ─────────────────────────────────────────────────────────────

@(private = "file")
_vh_open_separate_to_new_scene_modal :: proc() {
	targets := _vh_collect_top_level_selected_for_separate(context.temp_allocator)
	if len(targets) == 0 do return

	w := engine.ctx_world()
	default_name := "Separated_Scene"
	if w != nil && engine.pool_valid(&w.transforms, engine.Handle(targets[0])) {
		if t0 := engine.pool_get(&w.transforms, engine.Handle(targets[0])); t0 != nil && len(t0.name) > 0 {
			default_name = fmt.tprintf("%s_Scene", t0.name)
		}
	}
	_vh_set_name_buf(default_name)

	default_dir := "assets/scenes"
	if sc := engine.sm_scene_get_active(); sc != nil && len(sc.path) > 0 {
		dir_p := filepath.dir(sc.path) // slice into sc.path — do NOT delete!
		norm_dir, _ := strings.replace_all(dir_p, "\\", "/", context.temp_allocator)
		if len(norm_dir) > 0 && norm_dir != "." {
			default_dir = norm_dir
		}
	} else if exp_dir := _get_current_dir(); len(exp_dir) > 0 && exp_dir != "." && exp_dir != ".." {
		norm_dir, _ := strings.replace_all(exp_dir, "\\", "/", context.temp_allocator)
		if len(norm_dir) > 0 && norm_dir != "." {
			default_dir = norm_dir
		}
	}
	_vh_set_dir_buf(default_dir)

	_vh_separate_show_new_subfolder = false
	mem.zero(&_vh_separate_new_subfolder_buf, len(_vh_separate_new_subfolder_buf))
	mem.zero(&_vh_separate_scene_filter_buf, len(_vh_separate_scene_filter_buf))

	_vh_show_separate_scene_modal = true
	_vh_separate_modal_open_pending = true
}

@(private = "file")
_vh_execute_separate_to_new_scene :: proc(open_new_scene_after: bool) -> bool {
	w := engine.ctx_world()
	cur_sc := engine.sm_scene_get_active()
	if w == nil || cur_sc == nil do return false

	targets := _vh_collect_top_level_selected_for_separate(context.temp_allocator)
	if len(targets) == 0 do return false

	out_path: string
	raw_name: string
	append_mode := _vh_separate_into_existing_mode

	if append_mode {
		if _vh_separate_existing_target_len <= 0 do return false
		target_existing := string(_vh_separate_existing_target_buf[:_vh_separate_existing_target_len])
		out_path = _vh_normalize_scene_disk_path(target_existing, context.temp_allocator)
		if len(out_path) == 0 do return false
		raw_name = filepath.stem(out_path)
	} else {
		raw_name = strings.trim_space(string(cstring(raw_data(_vh_separate_scene_name_buf[:]))))
		if len(raw_name) == 0 do raw_name = "Separated_Scene"
		if strings.has_suffix(strings.to_lower(raw_name, context.temp_allocator), ".scene") {
			raw_name = raw_name[:len(raw_name) - 6]
		}

		raw_dir := strings.trim_space(string(cstring(raw_data(_vh_separate_scene_dir_buf[:]))))
		if len(raw_dir) == 0 do raw_dir = "assets/scenes"
		norm_dir, _ := strings.replace_all(raw_dir, "\\", "/", context.temp_allocator)
		norm_dir = strings.trim_right(norm_dir, "/")

		// Ensure output directory exists
		_ = os.make_directory("assets")
		if norm_dir != "assets" {
			_ = os.make_directory(norm_dir)
		}
		out_path = fmt.tprintf("%s/%s.scene", norm_dir, raw_name)
	}

	valid_targets := make([dynamic]engine.Transform_Handle, 0, len(targets), context.temp_allocator)
	parent_handles := make([dynamic]engine.Transform_Handle, 0, len(targets), context.temp_allocator)
	world_positions := make([dynamic][3]f32, 0, len(targets), context.temp_allocator)
	world_rotations := make([dynamic][4]f32, 0, len(targets), context.temp_allocator)
	world_scales    := make([dynamic][3]f32, 0, len(targets), context.temp_allocator)

	avg_pos := [3]f32{0, 0, 0}
	for h in targets {
		if h == {} || !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		tw := engine.transform_world(h)
		append(&valid_targets, h)
		append(&parent_handles, engine.Transform_Handle(t.parent.handle))
		append(&world_positions, tw.position)
		append(&world_rotations, tw.rotation)
		append(&world_scales, tw.scale)
		avg_pos += tw.position
	}
	if len(valid_targets) == 0 do return false
	avg_pos /= f32(len(valid_targets))

	if _vh_separate_center_at_origin {
		for &wp in world_positions {
			wp -= avg_pos
		}
	}

	// Save separated subtrees directly into the target `.scene` file (creating or appending)
	saved_ok := engine.scene_save_subtrees_to_file(
		cur_sc,
		valid_targets[:],
		world_positions[:],
		world_rotations[:],
		world_scales[:],
		raw_name,
		out_path,
		append_mode,
	)
	if !saved_ok {
		fmt.printfln("[Void Hierarchy] Failed to save separated scene to '%s'", out_path)
		return false
	}
	engine.asset_db_request_refresh()
	_needs_refresh = true
	_vh_record_recent_scene(out_path)

	// Optionally remove original selected objects from current scene (with Undo support!)
	if _vh_separate_remove_originals {
		g := undo.group_begin("Separate Objects to Scene")
		defer undo.group_end(&g)
		undo.record_selection_snapshot()

		first_parent := parent_handles[0]
		for orig_h in valid_targets {
			if engine.pool_valid(&w.transforms, engine.Handle(orig_h)) {
				undo.record_delete(orig_h)
			}
		}

		// Optionally instantiate the newly created scene in place of the removed objects
		var_inst_h: engine.Transform_Handle = {}
		if !append_mode && _vh_separate_replace_with_instance {
			db_p := _vh_to_asset_db_path(out_path, context.temp_allocator)
			guid_id, gok := engine.asset_db_get_guid(db_p)
			if !gok do guid_id, gok = engine.asset_db_get_guid(out_path)
			if gok {
				inst_parent := first_parent
				if inst_parent == {} || !engine.pool_valid(&w.transforms, engine.Handle(inst_parent)) {
					inst_parent = engine.Transform_Handle(cur_sc.root.handle)
				}
				var_inst_h = engine.scene_instantiate_guid_nested(engine.Asset_GUID(guid_id), inst_parent)
				if var_inst_h != {} {
					if _vh_separate_center_at_origin {
						if it_tr := engine.pool_get(&w.transforms, engine.Handle(var_inst_h)); it_tr != nil {
							it_tr.position = avg_pos
						}
					}
					undo.record_create(var_inst_h, inst_parent)
					engine.transform_ensure_unique_name(var_inst_h)
				}
			}
		}

		cur_sc.dirty = true
		undo.group_commit(&g)

		if var_inst_h != {} {
			_vh_select_node(var_inst_h, ping = true)
		} else {
			_vh_selected_tH = {}
			_vh_anchor_tH = {}
			engine.inspector_request_selection_op({}, .Clear)
			engine.inspector_set_active_selection({})
			engine.inspector_set_inspected_selection({})
		}

		if _vh_separate_save_current_scene && len(cur_sc.path) > 0 {
			engine.scene_save(cur_sc, cur_sc.path)
		}
	}

	if open_new_scene_after {
		_vh_switch_to_scene_path(out_path)
	} else {
		// Even when staying in current scene, reveal the target folder in Void Explorer so it's 1 click away
		out_dir := filepath.dir(out_path) // slice into out_path — do NOT delete!
		norm_out_dir, _ := strings.replace_all(out_dir, "\\", "/", context.temp_allocator)
		if os.is_dir(norm_out_dir) {
			_navigate_to(norm_out_dir)
			_set_selection_by_path(out_path)
		}
	}

	fmt.printfln("[Void Hierarchy] Separated %d object(s) into scene '%s' (append=%v)", len(valid_targets), out_path, append_mode)
	return true
}

@(private = "file")
_draw_separate_to_new_scene_modal :: proc() {
	if !_vh_show_separate_scene_modal do return
	if _vh_separate_modal_open_pending {
		im.OpenPopup("Separate / Move Selected to New Scene", {})
		_vh_separate_modal_open_pending = false
	}

	vp := im.GetMainViewport()
	center := vp.WorkPos + vp.WorkSize * 0.5
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize({600, 560}, .Appearing)

	if im.BeginPopupModal("Separate / Move Selected to New Scene", &_vh_show_separate_scene_modal, {}) {
		im.TextColored({0.35, 0.88, 1.0, 1.0}, fmt.ctprintf("%s  Separate / Move Selected Objects to Scene", icons.ICON_MD_OPEN_IN_NEW))
		im.TextDisabled("Create a new .scene or move/append directly into any existing .scene with 1 click:")
		im.Separator()
		im.Spacing()

		targets := _vh_collect_top_level_selected_for_separate(context.temp_allocator)
		w := engine.ctx_world()
		cur_sc := engine.sm_scene_get_active()
		cur_norm := cur_sc != nil ? _vh_fast_display_scene_path(cur_sc.path, context.temp_allocator) : ""

		first_obj_name := "Object"
		if len(targets) > 0 && w != nil && engine.pool_valid(&w.transforms, engine.Handle(targets[0])) {
			if t0 := engine.pool_get(&w.transforms, engine.Handle(targets[0])); t0 != nil && len(t0.name) > 0 {
				first_obj_name = t0.name
			}
		}

		im.TextColored({0.95, 0.82, 0.35, 1.0}, fmt.ctprintf("Selected Top-Level Objects (%d):", len(targets)))
		if im.BeginChild("##SepTargetList", {-1, 56}, {.Borders}) {
			for h in targets {
				if w != nil && engine.pool_valid(&w.transforms, engine.Handle(h)) {
					if t := engine.pool_get(&w.transforms, engine.Handle(h)); t != nil {
						badge := _vh_get_badge(t, h)
						im.TextColored(badge.color, fmt.ctprintf(" • %s  %s  [%s]", badge.icon, t.name, badge.type_name))
					}
				}
			}
		}
		im.EndChild()

		im.Spacing()

		// ── MODE TOGGLE TABS: [Create New .scene] vs [Move / Append into Existing .scene] ──
		tab_w := (im.GetContentRegionAvail().x - 8.0) * 0.5
		new_mode_active := !_vh_separate_into_existing_mode
		if new_mode_active {
			im.PushStyleColorImVec4(.Button, {0.16, 0.46, 0.76, 0.96})
			im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.54, 0.86, 1.0})
		} else {
			im.PushStyleColorImVec4(.Button, {0.16, 0.20, 0.28, 0.85})
			im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.28, 0.38, 0.95})
		}
		if im.Button(fmt.ctprintf("%s  Create New .scene File", icons.ICON_MD_ADD), {tab_w, 28}) {
			_vh_separate_into_existing_mode = false
		}
		im.PopStyleColor(2)

		im.SameLine(0, 8)
		if _vh_separate_into_existing_mode {
			im.PushStyleColorImVec4(.Button, {0.16, 0.54, 0.38, 0.96})
			im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.64, 0.46, 1.0})
		} else {
			im.PushStyleColorImVec4(.Button, {0.16, 0.20, 0.28, 0.85})
			im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.28, 0.38, 0.95})
		}
		if im.Button(fmt.ctprintf("%s  Move / Append into Existing .scene", icons.ICON_MD_LAYERS), {tab_w, 28}) {
			_vh_separate_into_existing_mode = true
		}
		im.PopStyleColor(2)

		im.Spacing()

		all_scenes := _vh_collect_all_project_scenes(context.temp_allocator)
		all_folders := _vh_collect_all_project_folders(context.temp_allocator)

		if !_vh_separate_into_existing_mode {
			// ── MODE A: CREATE NEW .SCENE FILE ──
			im.Text("New Scene Name:")
			im.SetNextItemWidth(-1)
			im.InputTextWithHint("##SepSceneName", "Enter scene name...", cstring(raw_data(_vh_separate_scene_name_buf[:])), len(_vh_separate_scene_name_buf), {})

			im.Spacing()
			im.Text("Target Folder (Click a preset or browse — no typing needed):")

			// Quick 1-click folder buttons
			cur_dir_str := strings.trim_space(string(cstring(raw_data(_vh_separate_scene_dir_buf[:]))))
			for folder_p, f_idx in all_folders {
				if f_idx >= 4 do break
				if f_idx > 0 do im.SameLine(0, 5)
				is_cur_f := strings.equal_fold(cur_dir_str, folder_p)
				if is_cur_f {
					im.PushStyleColorImVec4(.Button, {0.18, 0.48, 0.78, 0.95})
				} else {
					im.PushStyleColorImVec4(.Button, {0.18, 0.24, 0.34, 0.88})
				}
				short_lbl := filepath.base(folder_p)
				if short_lbl == "." || len(short_lbl) == 0 do short_lbl = folder_p
				if im.SmallButton(fmt.ctprintf("%s %s##QF_%d", icons.ICON_MD_FOLDER, short_lbl, f_idx)) {
					_vh_set_dir_buf(folder_p)
					cur_dir_str = folder_p
				}
				im.PopStyleColor(1)
				widgets.tooltip(fmt.ctprintf("Use folder: %s", folder_p))
			}

			// Dropdown Folder Picker + [+ Subfolder] button
			im.SetNextItemWidth(-125)
			if im.BeginCombo("##SepFolderCombo", fmt.ctprintf("%s  %s", icons.ICON_MD_FOLDER_OPEN, len(cur_dir_str) > 0 ? cur_dir_str : "Select folder...")) {
				for folder_p in all_folders {
					is_sel := strings.equal_fold(cur_dir_str, folder_p)
					if im.Selectable(fmt.ctprintf("%s  %s", icons.ICON_MD_FOLDER, folder_p), is_sel) {
						_vh_set_dir_buf(folder_p)
						cur_dir_str = folder_p
					}
				}
				im.EndCombo()
			}
			im.SameLine(0, 6)
			if im.Button(fmt.ctprintf("%s Subfolder", icons.ICON_MD_ADD), {118, 0}) {
				_vh_separate_show_new_subfolder = !_vh_separate_show_new_subfolder
			}

			if _vh_separate_show_new_subfolder {
				im.SetNextItemWidth(-150)
				sub_enter := im.InputTextWithHint("##SepNewSubfolder", "New subfolder name...", cstring(raw_data(_vh_separate_new_subfolder_buf[:])), len(_vh_separate_new_subfolder_buf), {.EnterReturnsTrue})
				im.SameLine(0, 6)
				if im.Button("Use Subfolder", {142, 0}) || sub_enter {
					sub_str := strings.trim_space(string(cstring(raw_data(_vh_separate_new_subfolder_buf[:]))))
					if len(sub_str) > 0 {
						base_d := len(cur_dir_str) > 0 ? strings.trim_right(cur_dir_str, "/") : "assets/scenes"
						combined := fmt.tprintf("%s/%s", base_d, sub_str)
						_ = os.make_directory(combined)
						_vh_set_dir_buf(combined)
						_vh_separate_show_new_subfolder = false
						mem.zero(&_vh_separate_new_subfolder_buf, len(_vh_separate_new_subfolder_buf))
					}
				}
			}

			// Show existing .scene files in the selected folder so user can see what's inside or click one
			im.Spacing()
			im.TextDisabled("Existing .scene files in selected folder (click to reuse name, double-click to append):")
			if im.BeginChild("##SepFolderScenesPreview", {-1, 78}, {.Borders}) {
				in_folder_count := 0
				for sc_e in all_scenes {
					if strings.equal_fold(sc_e.display_dir, cur_dir_str) {
						in_folder_count += 1
						is_cur_active := strings.equal_fold(sc_e.disk_path, cur_norm)
						lbl := fmt.ctprintf("%s  %s.scene%s", icons.ICON_MD_LAYERS, sc_e.name, is_cur_active ? "  [Current Active Scene]" : "")
						if im.Selectable(lbl, false, {.AllowDoubleClick}) {
							_vh_set_name_buf(sc_e.name)
							if im.IsMouseDoubleClicked(.Left) && !is_cur_active {
								_vh_separate_into_existing_mode = true
								mem.zero(&_vh_separate_existing_target_buf, len(_vh_separate_existing_target_buf))
								tn := min(len(sc_e.disk_path), len(_vh_separate_existing_target_buf) - 1)
								copy(_vh_separate_existing_target_buf[:tn], sc_e.disk_path[:tn])
								_vh_separate_existing_target_len = tn
							}
						}
					}
				}
				if in_folder_count == 0 {
					im.TextDisabled(" (No existing .scene files in this folder yet)")
				}
			}
			im.EndChild()
		} else {
			// ── MODE B: MOVE / APPEND INTO EXISTING .SCENE ──
			im.TextColored({0.40, 0.92, 0.65, 1.0}, "Click a target .scene below to append the selected object(s) into it:")

			filter_str := strings.trim_space(string(cstring(raw_data(_vh_separate_scene_filter_buf[:]))))
			filter_lower := strings.to_lower(filter_str, context.temp_allocator)
			im.SetNextItemWidth(-1)
			im.InputTextWithHint("##SepExistingFilter", fmt.ctprintf("%s  Search existing project scenes...", icons.ICON_MD_SEARCH), cstring(raw_data(_vh_separate_scene_filter_buf[:])), len(_vh_separate_scene_filter_buf), {})

			sel_existing := _vh_separate_existing_target_len > 0 ? string(_vh_separate_existing_target_buf[:_vh_separate_existing_target_len]) : ""

			if im.BeginChild("##SepExistingSceneList", {-1, 155}, {.Borders}) {
				shown := 0
				for sc_e in all_scenes {
					// Skip current active scene (moving into the same scene is a no-op)
					if strings.equal_fold(sc_e.disk_path, cur_norm) do continue
					if len(filter_lower) > 0 {
						if !strings.contains(strings.to_lower(sc_e.name, context.temp_allocator), filter_lower) &&
						   !strings.contains(strings.to_lower(sc_e.display_dir, context.temp_allocator), filter_lower) {
							continue
						}
					}
					shown += 1
					is_sel := strings.equal_fold(sel_existing, sc_e.disk_path)
					row_lbl := fmt.ctprintf("%s  %s   ( %s )", icons.ICON_MD_LAYERS, sc_e.name, sc_e.display_dir)
					if im.Selectable(row_lbl, is_sel, {.AllowDoubleClick}) {
						mem.zero(&_vh_separate_existing_target_buf, len(_vh_separate_existing_target_buf))
						tn := min(len(sc_e.disk_path), len(_vh_separate_existing_target_buf) - 1)
						copy(_vh_separate_existing_target_buf[:tn], sc_e.disk_path[:tn])
						_vh_separate_existing_target_len = tn
						sel_existing = sc_e.disk_path
					}
				}
				if shown == 0 {
					im.TextDisabled("No other .scene files found in project. Switch to 'Create New .scene File' above!")
				}
			}
			im.EndChild()
		}

		im.Spacing()
		im.Checkbox("Remove Selected Objects from Current Scene (Move instead of Copy)", &_vh_separate_remove_originals)
		widgets.tooltip("Deletes the selected objects from the current scene after saving them to the target scene (Undoable with Ctrl+Z!)")

		if _vh_separate_remove_originals {
			im.Indent(18.0)
			if !_vh_separate_into_existing_mode {
				im.Checkbox("Replace Removed Objects with Nested Instance of New Scene", &_vh_separate_replace_with_instance)
				widgets.tooltip("Spawns the new .scene as a Nested Child Scene right where the separated objects were!")
			}
			im.Checkbox("Auto-Save Current Scene After Moving", &_vh_separate_save_current_scene)
			im.Unindent(18.0)
		}

		im.Checkbox("Center Separated Objects at World Origin (0, 0, 0) in Target Scene", &_vh_separate_center_at_origin)
		widgets.tooltip("When enabled, shifts the separated objects so their average position is at (0, 0, 0) in the target scene. When unchecked, preserves their exact World coordinates.")

		im.Spacing()
		im.Separator()
		im.Spacing()

		can_exec := len(targets) > 0 && (!_vh_separate_into_existing_mode || _vh_separate_existing_target_len > 0)
		if !can_exec do im.BeginDisabled()
		im.PushStyleColorImVec4(.Button, {0.16, 0.56, 0.38, 0.95})
		stay_lbl := _vh_separate_into_existing_mode ? fmt.ctprintf("%s  Move into Selected Scene (Stay Here)", icons.ICON_MD_CHECK) : fmt.ctprintf("%s  Separate (Stay in Current Scene)", icons.ICON_MD_CHECK)
		if im.Button(stay_lbl, {245, 30}) {
			if _vh_execute_separate_to_new_scene(open_new_scene_after = false) {
				_vh_show_separate_scene_modal = false
				im.CloseCurrentPopup()
			}
		}
		im.PopStyleColor(1)

		im.SameLine(0, 8)
		im.PushStyleColorImVec4(.Button, {0.18, 0.45, 0.78, 0.95})
		open_lbl := _vh_separate_into_existing_mode ? fmt.ctprintf("%s  Move & Open Target Scene", icons.ICON_MD_OPEN_IN_NEW) : fmt.ctprintf("%s  Separate & Open New Scene", icons.ICON_MD_OPEN_IN_NEW)
		if im.Button(open_lbl, {220, 30}) {
			if _vh_execute_separate_to_new_scene(open_new_scene_after = true) {
				_vh_show_separate_scene_modal = false
				im.CloseCurrentPopup()
			}
		}
		im.PopStyleColor(1)
		if !can_exec do im.EndDisabled()

		im.SameLine(0, 8)
		if im.Button("Cancel", {72, 30}) {
			_vh_show_separate_scene_modal = false
			im.CloseCurrentPopup()
		}

		im.EndPopup()
	}
}

@(private = "file")
_vh_open_instantiate_modal :: proc(force_root: bool = false) {
	_vh_show_instantiate_modal = true
	_vh_instantiate_modal_open_pending = true
	_vh_instantiate_force_root = force_root
	_vh_instantiate_search_buf = {}
	_vh_selected_scene_guid = {}
}

@(private = "file")
_vh_instantiate_selected_scene :: proc() {
	if _vh_selected_scene_guid == {} do return
	s := engine.sm_scene_get_active()
	if s == nil do return

	parent_tH := engine.Transform_Handle(s.root.handle)
	if !_vh_instantiate_force_root && _vh_selected_tH != {} {
		parent_tH = _vh_selected_tH
	}

	inst_h := engine.scene_instantiate_guid_nested(_vh_selected_scene_guid, parent_tH)
	if inst_h != {} {
		engine.transform_ensure_unique_name(inst_h)
		s.dirty = true
		_vh_select_node(inst_h, ping = true)
	}
}

@(private = "file")
_draw_instantiate_scene_modal :: proc() {
	if !_vh_show_instantiate_modal do return
	if _vh_instantiate_modal_open_pending {
		im.OpenPopup("Instantiate Child Scene", {})
		_vh_instantiate_modal_open_pending = false
	}

	vp := im.GetMainViewport()
	center := vp.WorkPos + vp.WorkSize * 0.5
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize({520, 420}, .Appearing)

	if im.BeginPopupModal("Instantiate Child Scene", &_vh_show_instantiate_modal, {}) {
		im.TextColored({0.82, 0.45, 1.0, 1.0}, fmt.ctprintf("%s  Instantiate Scene as Nested Child Node", icons.ICON_MD_PLAY_CIRCLE))
		im.TextDisabled("Select an authored .scene from your project to instance into the hierarchy:")
		im.Separator()
		im.Spacing()

		filter_str := strings.trim_space(string(cstring(raw_data(_vh_instantiate_search_buf[:]))))
		filter_lower := strings.to_lower(filter_str, context.temp_allocator)

		im.SetNextItemWidth(-1)
		im.InputTextWithHint("##SceneFilter", "Search scenes...", cstring(raw_data(_vh_instantiate_search_buf[:])), len(_vh_instantiate_search_buf), {})

		im.Spacing()

		all_scenes := _vh_collect_all_project_scenes(context.temp_allocator)

		if im.BeginChild("##SceneList", {-1, -45}, {.Borders}) {
			shown := 0
			for sc_entry in all_scenes {
				if sc_entry.guid == {} do continue
				if len(filter_lower) > 0 &&
				   !strings.contains(strings.to_lower(sc_entry.name, context.temp_allocator), filter_lower) &&
				   !strings.contains(strings.to_lower(sc_entry.display_dir, context.temp_allocator), filter_lower) {
					continue
				}
				shown += 1
				is_sel := _vh_selected_scene_guid == sc_entry.guid
				line_lbl := fmt.ctprintf("%s  %s  ( %s )", icons.ICON_MD_PLAY_CIRCLE, sc_entry.name, sc_entry.display_dir)
				if im.Selectable(line_lbl, is_sel, {.AllowDoubleClick}) {
					_vh_selected_scene_guid = sc_entry.guid
					if im.IsMouseDoubleClicked(.Left) {
						_vh_instantiate_selected_scene()
						_vh_show_instantiate_modal = false
						im.CloseCurrentPopup()
					}
				}
			}

			if shown == 0 {
				im.TextDisabled("No matching .scene files found in the project.")
			}
		}
		im.EndChild()

		im.Spacing()
		can_instantiate := _vh_selected_scene_guid != {}
		if !can_instantiate do im.BeginDisabled()
		if im.Button(fmt.ctprintf("%s  Instantiate", icons.ICON_MD_CHECK), {130, 30}) {
			_vh_instantiate_selected_scene()
			_vh_show_instantiate_modal = false
			im.CloseCurrentPopup()
		}
		if !can_instantiate do im.EndDisabled()

		im.SameLine(0, 15)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {100, 30}) {
			_vh_show_instantiate_modal = false
			im.CloseCurrentPopup()
		}

		im.EndPopup()
	}
}

@(private = "package")
_vh_draw_odin_folder_selector_and_preview :: proc(
	id_suffix: string,
	folder_buf: ^[256]u8,
	struct_name: string,
	input_width: f32 = -1,
) -> (clean_sub: string) {
	scene_folder := _vh_default_odin_component_folder()
	raw_folder := strings.trim_space(string(cstring(raw_data(folder_buf[:]))))
	clean_sub = _vh_sanitize_odin_subfolder(raw_folder)

	im.TextDisabled("Target Folder inside plugins/void_odin/ (leave empty for root):")
	if len(scene_folder) > 0 {
		is_scene_sel := clean_sub == scene_folder
		if is_scene_sel {
			im.PushStyleColorImVec4(.Button, {0.16, 0.44, 0.30, 0.95})
		}
		if im.SmallButton(fmt.ctprintf("%s Scene Folder (%s)##SceneDir_%s", icons.ICON_MD_FOLDER, scene_folder, id_suffix)) {
			mem.zero(folder_buf, len(folder_buf^))
			copy(folder_buf[:len(folder_buf^) - 1], scene_folder)
			clean_sub = scene_folder
		}
		if is_scene_sel do im.PopStyleColor(1)
		widgets.tooltip("Place this script alongside the active scene in its folder")
		im.SameLine(0, 6)
	}

	is_root_sel := len(clean_sub) == 0
	if is_root_sel {
		im.PushStyleColorImVec4(.Button, {0.20, 0.36, 0.56, 0.95})
	}
	if im.SmallButton(fmt.ctprintf("%s Root (plugins/void_odin)##RootDir_%s", icons.ICON_MD_FOLDER, id_suffix)) {
		mem.zero(folder_buf, len(folder_buf^))
		clean_sub = ""
	}
	if is_root_sel do im.PopStyleColor(1)
	widgets.tooltip("Place this script in the root plugins/void_odin/ folder")

	im.SetNextItemWidth(input_width)
	_ = im.InputTextWithHint(
		fmt.ctprintf("##VHCompFolder_%s", id_suffix),
		"Subfolder inside plugins/void_odin (empty = root)...",
		cstring(raw_data(folder_buf[:])),
		len(folder_buf^),
		{},
	)

	raw_folder = strings.trim_space(string(cstring(raw_data(folder_buf[:]))))
	clean_sub = _vh_sanitize_odin_subfolder(raw_folder)
	pkg_name := _vh_compute_odin_package_name(clean_sub)

	if len(struct_name) > 0 {
		file_rel := len(clean_sub) > 0 \
			? fmt.tprintf("plugins/void_odin/%s/component_%s.odin", clean_sub, struct_name) \
			: fmt.tprintf("plugins/void_odin/component_%s.odin", struct_name)
		im.TextColored({0.65, 0.82, 1.0, 1.0}, fmt.ctprintf("Target File:  %s", file_rel))
		im.TextColored({0.55, 0.90, 0.70, 1.0}, fmt.ctprintf("Odin Package: package %s   |   Menu: Void/%s", pkg_name, struct_name))
	} else {
		im.TextDisabled("Enter a valid Odin struct identifier.")
	}
	return clean_sub
}

@(private = "package")
_draw_new_odin_component_modal :: proc() {
	if !_vh_show_new_comp_modal do return
	if _vh_new_comp_modal_open_pending || !im.IsPopupOpen("Create New Odin Component (.odin)", {}) {
		im.OpenPopup("Create New Odin Component (.odin)", {})
		_vh_new_comp_modal_open_pending = false
	}

	vp := im.GetMainViewport()
	center := vp.WorkPos + vp.WorkSize * 0.5
	im.SetNextWindowPos(center, .Always, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize({500, 340}, .Always)

	if im.BeginPopupModal("Create New Odin Component (.odin)", &_vh_show_new_comp_modal, {}) {
		im.TextColored({0.25, 0.95, 0.58, 1.0}, fmt.ctprintf("%s  Create New Odin Gameplay Component", icons.ICON_MD_CODE))
		im.TextDisabled("Creates a new @(component) struct in plugins/void_odin/ and opens it in your IDE.")
		im.Separator()
		im.Spacing()

		im.Text("Component Struct Name (PascalCase):")
		if im.IsWindowAppearing() {
			im.SetKeyboardFocusHere()
		}
		im.SetNextItemWidth(460)
		enter_pressed := im.InputTextWithHint(
			"##VHNewCompNameInput",
			"Enter component struct name...",
			cstring(raw_data(_vh_new_comp_name_buf[:])),
			len(_vh_new_comp_name_buf),
			{.EnterReturnsTrue},
		)

		raw_name := strings.trim_space(string(cstring(raw_data(_vh_new_comp_name_buf[:]))))
		struct_name := _vh_sanitize_odin_identifier(raw_name)

		im.Spacing()
		clean_sub := _vh_draw_odin_folder_selector_and_preview("VHModal", &_vh_new_comp_folder_buf, struct_name, 460)

		im.Spacing()
		im.Separator()
		im.Spacing()

		can_create := len(struct_name) > 0
		if !can_create do im.BeginDisabled()
		im.PushStyleColorImVec4(.Button, {0.16, 0.46, 0.32, 0.95})
		im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.58, 0.40, 1.0})
		if im.Button(fmt.ctprintf("%s  Create & Open in IDE", icons.ICON_MD_CHECK), {190, 32}) || (enter_pressed && can_create) {
			_, _ = _vh_create_and_open_odin_component(struct_name, clean_sub)
			_vh_show_new_comp_modal = false
			im.CloseCurrentPopup()
		}
		im.PopStyleColor(2)
		if !can_create do im.EndDisabled()

		im.SameLine(0, 12)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {110, 32}) || im.IsKeyPressed(.Escape, false) {
			_vh_show_new_comp_modal = false
			im.CloseCurrentPopup()
		}

		im.EndPopup()
	}
}

@(menu_item={path="Window/Void Hierarchy", shortcut=""})
void_hierarchy_window_open :: proc() {
	wnd.open("void_hierarchy")
}
