package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../engine"
import "menu"
import "undo"
import cad_csg "moonhug:packages/cad_csg"
import cad_csg_editor "moonhug:packages/cad_csg/editor"
import control_rig "moonhug:packages/control_rig"

// Extracts component struct names from an .odin source file if present:
// Looks for '@(component' followed by '<Ident> :: struct'
extract_all_component_struct_names :: proc(content: string, allocator := context.temp_allocator) -> [dynamic]string {
	names := make([dynamic]string, allocator)
	search_start := 0
	for {
		rel_idx := strings.index(content[search_start:], "@(component")
		if rel_idx < 0 do break
		comp_idx := search_start + rel_idx

		remaining := content[comp_idx:]
		struct_idx := strings.index(remaining, "::")
		if struct_idx < 0 {
			search_start = comp_idx + len("@(component")
			continue
		}

		prefix := strings.trim_space(remaining[:struct_idx])
		tokens := strings.fields(prefix, allocator)
		if len(tokens) > 0 {
			last_token := tokens[len(tokens) - 1]
			clean_id := strings.trim(last_token, " \t\r\n():;,")
			if len(clean_id) > 0 {
				append(&names, clean_id)
			}
		}
		search_start = comp_idx + struct_idx + 2
	}
	return names
}

// Finds the corresponding MenuNode in "Component" menu for any asset file path
find_component_node_for_asset :: proc(path: string) -> ^menu.MenuNode {
	root := menu.node_at("Component")
	if root == nil do return nil

	base_name := filepath.base(path)
	stem_name := filepath.stem(base_name)

	clean_path, _ := filepath.clean(path, context.temp_allocator)
	norm_path, _ := strings.replace_all(clean_path, "\\", "/", context.temp_allocator)

	extracted_names: [dynamic]string
	if strings.has_suffix(strings.to_lower(base_name, context.temp_allocator), ".odin") {
		if content_bytes, err := os.read_entire_file(norm_path, context.temp_allocator); err == nil {
			extracted_names = extract_all_component_struct_names(string(content_bytes))
		}
	}

	// 1. Try each extracted name first
	for name in extracted_names {
		if found := _search_component_tree(root, base_name, stem_name, name); found != nil {
			return found
		}
	}

	// 2. Try stem name / base name
	return _search_component_tree(root, base_name, stem_name, "")
}

@(private = "file")
_search_component_tree :: proc(node: ^menu.MenuNode, base_name, stem_name, target_type_name: string) -> ^menu.MenuNode {
	if node == nil do return nil

	if node.kind == .Action {
		// 1. Exact match on extracted struct name
		if target_type_name != "" && strings.equal_fold(node.name, target_type_name) {
			return node
		}
		// 2. Exact match on stem name
		if stem_name != "" && strings.equal_fold(node.name, stem_name) {
			return node
		}
		// 3. Match on origin containing base filename
		if base_name != "" && strings.contains(node.origin, base_name) {
			return node
		}
	}

	for child in node.children {
		if found := _search_component_tree(child, base_name, stem_name, target_type_name); found != nil {
			return found
		}
	}
	return nil
}

_get_transform_name :: proc(tH: engine.Transform_Handle) -> string {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t != nil do return t.name
	return ""
}

// Drops an asset onto a specific transform (or creates a new entity if target_tH is empty)
editor_drop_asset_on_transform :: proc(path: string, target_tH: engine.Transform_Handle, spawn_pos: [3]f32 = {}) -> bool {
	clean_path, _ := filepath.clean(path, context.temp_allocator)
	norm_path, _ := strings.replace_all(clean_path, "\\", "/", context.temp_allocator)
	ext := strings.to_lower(filepath.ext(norm_path), context.temp_allocator)

	scene := engine.sm_scene_get_active()
	if scene == nil do return false
	root_tH := engine.Transform_Handle(scene.root.handle)

	// 1. Scene files (.scene) -> Instantiate as child or in root
	if ext == ".scene" {
		parent_tH := target_tH if target_tH != {} else root_tH
		guid, ok := engine.asset_db_get_guid(norm_path)
		if !ok {
			trimmed := strings.trim_prefix(norm_path, "../")
			trimmed = strings.trim_prefix(trimmed, "./")
			if strings.has_prefix(trimmed, "plugins/") {
				trimmed = fmt.tprintf("packages/%s", strings.trim_prefix(trimmed, "plugins/"))
			} else if strings.has_prefix(trimmed, "moonhug/") {
				trimmed = strings.trim_prefix(trimmed, "moonhug/")
			}
			guid, ok = engine.asset_db_get_guid(trimmed)
		}

		if ok {
			new_tH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(guid), parent_tH)
			if new_tH != {} {
				if spawn_pos != {} {
					engine.transform_set_world_position(new_tH, spawn_pos)
				}
				undo.record_create(new_tH, parent_tH)
				sel_scene_only(new_tH)
				fmt.printfln("[Void] Instantiated scene '%s' under '%s'", filepath.base(norm_path), _get_transform_name(parent_tH))
				return true
			}
		} else {
			// Additive load by path
			if loaded := engine.scene_load_additive_path(norm_path); loaded != nil {
				fmt.printfln("[Void] Loaded scene '%s' additively", filepath.base(norm_path))
				return true
			}
		}
		return false
	}

	// 2. 3D Model files (.glb, .gltf) -> Auto-detect Skeletal Mesh (Control Rig) vs. Static Mesh!
	if ext == ".glb" || ext == ".gltf" {
		parent_tH := target_tH if target_tH != {} else root_tH
		guid, ok := engine.asset_db_get_guid(norm_path)
		if !ok {
			trimmed := strings.trim_prefix(norm_path, "../")
			trimmed = strings.trim_prefix(trimmed, "./")
			if strings.has_prefix(trimmed, "plugins/") {
				trimmed = fmt.tprintf("packages/%s", strings.trim_prefix(trimmed, "plugins/"))
			} else if strings.has_prefix(trimmed, "moonhug/") {
				trimmed = strings.trim_prefix(trimmed, "moonhug/")
			}
			guid, ok = engine.asset_db_get_guid(trimmed)
		}
		if ok {
			stem := filepath.stem(filepath.base(norm_path))
			new_tH, is_skel := control_rig.instantiate_gltf_model_auto(
				engine.Asset_GUID(guid),
				stem,
				parent_tH,
				spawn_pos,
				spawn_pos != {},
			)
			if new_tH != {} {
				undo.record_create(new_tH, parent_tH)
				sel_scene_only(new_tH)
				kind_str := "Control Rig Skeletal Mesh" if is_skel else "Static 3D Mesh"
				fmt.printfln("[Void] Spawned %s '%s' under '%s'", kind_str, filepath.base(norm_path), _get_transform_name(parent_tH))
				return true
			}
		}
		return false
	}

	// 2b. Binary Faker CSG (.fmesh)
	if ext == ".fmesh" {
		parent_tH := target_tH if target_tH != {} else root_tH
		pos := spawn_pos if spawn_pos != {} else scene_cam_target
		new_tH := cad_csg.csg_spawn_faker_mesh_from_binary(pos, norm_path)
		if new_tH != {} {
			if target_tH != {} {
				engine.transform_set_parent(new_tH, target_tH, -1, keep_world = spawn_pos != {})
			}
			undo.record_create(new_tH, parent_tH)
			scene.dirty = true
			sel_scene_only(new_tH)
			fmt.printfln("[Void] Spawned Faker CSG '%s'", filepath.base(norm_path))
			return true
		}
		return false
	}

	// 2c. Material (.mat) & Texture (.png, .jpg, .jpeg, .bmp, .tga) -> Apply to object & under-cursor UV face!
	if ext == ".mat" || ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tga" {
		dest_tH := target_tH if target_tH != {} else hierarchy_get_selected()
		if cad_csg_editor.apply_dropped_material_or_texture(norm_path, dest_tH, {}, false) {
			fmt.printfln("[Void] Applied material/texture '%s' to '%s'", filepath.base(norm_path), _get_transform_name(dest_tH))
			return true
		}
		return false
	}

	// 3. Script / Component files (.odin)
	node := find_component_node_for_asset(norm_path)
	if node != nil {
		dest_tH := target_tH
		if dest_tH == {} {
			// Godot-style: if dropped in empty space, create a new GameObject named after the component!
			dest_tH = undo.record_create_child(node.name, root_tH)
			if spawn_pos != {} {
				engine.transform_set_world_position(dest_tH, spawn_pos)
			}
			fmt.printfln("[Void] Created new entity '%s' for component '%s'", node.name, node.name)
		}

		sel_scene_only(dest_tH)
		if node.action != nil {
			node.action()
			fmt.printfln("[Void] Added component '%s' to '%s'", node.name, _get_transform_name(dest_tH))
			return true
		}
	} else if ext == ".odin" {
		// Detect if it declared a component that hasn't been built yet
		base_name := filepath.base(norm_path)
		if content_bytes, err := os.read_entire_file(norm_path, context.temp_allocator); err == nil {
			names := extract_all_component_struct_names(string(content_bytes))
			if len(names) > 0 {
				fmt.printfln("[Void] Script '%s' declares component '%s'. Run 'mh build' to compile it into the binary first.", base_name, names[0])
				return false
			}
		}
		fmt.printfln("[Void] Script '%s' does not appear to contain a registered @(component).", base_name)
	}

	return false
}

// Drops an asset into the 3D Scene Viewport:
// Picks the 3D entity under the mouse cursor, or selected entity, or creates a new entity.
editor_drop_asset_in_scene :: proc(path: string, mouse_screen_pos: im.Vec2) -> bool {
	px := mouse_screen_pos.x - _scene_img_min.x
	py := mouse_screen_pos.y - _scene_img_min.y
	tH, hit := scene_view_pick(_scene_view_last, px, py)

	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext == ".mat" || ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tga" {
		ray := engine.render_view_screen_ray(_scene_view_last, px, py)
		picked_tH := tH if hit else {}
		if cad_csg_editor.apply_dropped_material_or_texture(path, picked_tH, ray, true) {
			fmt.printfln("[Void] Applied material/texture '%s' to object & under-cursor UV face", filepath.base(path))
			return true
		}
	}

	if ext == ".glb" || ext == ".gltf" || ext == ".fmesh" || ext == ".scene" {
		ray := engine.render_view_screen_ray(_scene_view_last, px, py)
		drop_pos := scene_cam_target
		if hp, _, _, _, _, c_ok := cad_csg.csg_raycast_world(ray); c_ok {
			drop_pos = hp
		} else if abs(ray.direction.y) > 1e-4 {
			t_ground := -ray.origin.y / ray.direction.y
			if t_ground > 0.1 && t_ground < 200.0 {
				drop_pos = ray.origin + ray.direction * t_ground
			}
		}
		return editor_drop_asset_on_transform(path, {}, drop_pos)
	}

	if hit {
		return editor_drop_asset_on_transform(path, tH)
	}

	// If no direct 3D object was under cursor, check if an entity is currently selected
	selected_tH := hierarchy_get_selected()
	if selected_tH != _HANDLE_NONE {
		return editor_drop_asset_on_transform(path, selected_tH)
	}

	// Otherwise Godot style: create a new object in scene at camera focus point
	return editor_drop_asset_on_transform(path, {}, scene_cam_target)
}
