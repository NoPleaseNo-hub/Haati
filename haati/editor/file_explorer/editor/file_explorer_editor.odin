package file_explorer_editor

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import stbi "vendor:stb/image"
import im "haati:external/odin-imgui"
import gfx "haati:engine/gfx"
import wnd "haati:editor/window"
import icons "haati:editor/icons"
import thm "haati:editor/theme"
import undo "haati:editor/undo"
import engine "haati:engine"
import file_exp "haati:editor/file_explorer"
import editor_visuals "haati:editor/editor_visuals"
import cad_csg "haati:packages/cad_csg"
import audio "haati:packages/audio"
import widgets "haati:editor/widgets"
import vs "haati:editor/visual_script"

// ─────────────────────────────────────────────────────────────
// STATE & STATIC BUFFERS (100% HEAP-CORRUPTION PROOF)
// ─────────────────────────────────────────────────────────────

@(private = "file") _initialized:             bool = false

// Fixed-buffer Path tracking (Zero dynamic heap allocations, no dangling pointers)
@(private = "file") _current_dir_buf:         [512]u8
@(private = "file") _current_dir_len:         int = 0

_get_current_dir :: proc() -> string {
	if _current_dir_len == 0 do return file_exp.get_workspace_root()
	return string(_current_dir_buf[:_current_dir_len])
}

@(private = "file") _tree_reveal_frames:      int = 0
@(private = "file") _tree_scroll_frames:      int = 0

_trigger_tree_reveal :: proc(scroll: bool = true) {
	_tree_reveal_frames = 2
	if scroll {
		_tree_scroll_frames = 2
	} else {
		_tree_scroll_frames = 0
	}
}

_set_current_dir :: proc(new_dir: string, trigger_reveal: bool = true) {
	clean, _ := filepath.clean(new_dir, context.temp_allocator)
	norm, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
	_current_dir_len = copy(_current_dir_buf[:], norm)
	if trigger_reveal {
		_trigger_tree_reveal(scroll = true)
	}
}

// History stack (Zero dynamic heap allocations)
History_Entry :: struct {
	buf: [512]u8,
	len: int,
}
@(private = "file") _history:                 [64]History_Entry
@(private = "file") _history_count:           int = 0
@(private = "file") _history_idx:             int = -1

// Directory items and dedicated reusable memory arena
@(private = "file") _items_backing:           [1024 * 1024]u8
@(private = "file") _items_arena:             mem.Arena
@(private = "file") _arena_init_done:         bool = false
@(private = "file") _items:                   [dynamic]file_exp.File_Item
_needs_refresh:                               bool = true

Tree_Subdir :: struct {
	name:      string,
	norm_path: string,
}
@(private = "file") _tree_subdirs_cache:      map[string][dynamic]Tree_Subdir

@(private = "file")
_clear_tree_subdirs_cache :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for k, list in _tree_subdirs_cache {
		for item in list {
			delete(item.name)
			delete(item.norm_path)
		}
		delete(list)
		delete(k)
	}
	clear(&_tree_subdirs_cache)
}

@(private = "file")
_get_tree_subdirs :: proc(norm_dir: string) -> []Tree_Subdir {
	if cached, found := _tree_subdirs_cache[norm_dir]; found {
		return cached[:]
	}
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	list := make([dynamic]Tree_Subdir)
	handle, err := os.open(norm_dir)
	if err == nil {
		defer os.close(handle)
		sub_entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
		if read_err == nil {
			defer os.file_info_slice_delete(sub_entries, context.temp_allocator)
			for entry in sub_entries {
				is_dir := entry.type == .Directory
				if is_dir && !strings.has_prefix(entry.name, ".") && entry.name != "builds" && entry.name != "bin" && entry.name != ".gemini" {
					sub_path, _ := filepath.join({norm_dir, entry.name}, context.temp_allocator)
					sub_clean, _ := filepath.clean(sub_path, context.temp_allocator)
					sub_norm, _ := strings.replace_all(sub_clean, "\\", "/", context.temp_allocator)
					append(&list, Tree_Subdir{
						name      = strings.clone(entry.name),
						norm_path = strings.clone(sub_norm),
					})
				}
			}
		}
	}
	_tree_subdirs_cache[strings.clone(norm_dir)] = list
	return _tree_subdirs_cache[norm_dir][:]
}

// Selection Tracking (Multi-Selection & Active Item)
@(private = "file") _selected_path_buf:       [512]u8
@(private = "file") _selected_path_len:       int = 0
@(private = "file") _selected_name_buf:       [256]u8
@(private = "file") _selected_name_len:       int = 0
@(private = "file") _selected_type_buf:       [64]u8
@(private = "file") _selected_type_len:       int = 0
@(private = "file") _has_selection:           bool = false
@(private = "file") _selected_paths:          [dynamic]string
@(private = "file") _fe_selection_epoch:      u64 = 0

fe_selection_epoch :: proc() -> u64 {
	return _fe_selection_epoch
}

_get_selected_path :: proc() -> string {
	if !_has_selection do return ""
	return string(_selected_path_buf[:_selected_path_len])
}

_get_selected_name :: proc() -> string {
	if !_has_selection do return ""
	return string(_selected_name_buf[:_selected_name_len])
}

_get_selected_type :: proc() -> string {
	if !_has_selection do return ""
	return string(_selected_type_buf[:_selected_type_len])
}

_get_selected_paths :: proc() -> []string {
	if !_has_selection do return nil
	return _selected_paths[:]
}

_is_item_selected :: proc(path: string) -> bool {
	if !_has_selection do return false
	for p in _selected_paths {
		if p == path do return true
	}
	return false
}

@(private) _active_mat_path_buf: [512]u8
@(private) _active_mat_path_len: int = 0

@(private)
_to_asset_db_path :: proc(path: string, alloc := context.temp_allocator) -> string {
	clean_p, _ := filepath.clean(path, alloc)
	norm_p, _  := strings.replace_all(clean_p, "\\", "/", alloc)
	rel_p      := strings.trim_prefix(norm_p, "../")
	rel_p       = strings.trim_prefix(rel_p, "./")
	if strings.has_prefix(rel_p, "plugins/") {
		rel_p = fmt.tprintf("packages/%s", strings.trim_prefix(rel_p, "plugins/"))
	} else if strings.has_prefix(rel_p, "haati/") {
		rel_p = strings.trim_prefix(rel_p, "haati/")
	}
	// Sample packages inside `plugins/<pkg>/samples/<sample_pkg>/...` are mounted at `packages/<sample_pkg>/...`
	if strings.has_prefix(rel_p, "packages/") {
		if samples_idx := strings.index(rel_p, "/samples/"); samples_idx > 0 {
			after_samples := rel_p[samples_idx + len("/samples/"):]
			rel_p = fmt.tprintf("packages/%s", after_samples)
		}
	}
	return rel_p
}

@(private)
_lookup_asset_guid_any_path :: proc(path: string) -> (uuid.Identifier, bool) {
	if id, ok := engine.asset_db_lookup_guid_any(path); ok {
		return uuid.Identifier(id), true
	}
	db_p := _to_asset_db_path(path, context.temp_allocator)
	if id, ok := engine.asset_db_lookup_guid_any(db_p); ok {
		return uuid.Identifier(id), true
	}
	return {}, false
}

@(private = "file")
_selected_paths_clear :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for p in _selected_paths do delete(p)
	clear(&_selected_paths)
}

@(private = "file")
_selected_paths_append :: proc(path: string) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	append(&_selected_paths, strings.clone(path))
}

@(private = "file")
_selected_paths_remove_at :: proc(idx: int) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	delete(_selected_paths[idx])
	ordered_remove(&_selected_paths, idx)
}

_set_selection :: proc(item: file_exp.File_Item) {
	_selected_paths_clear()
	_selected_paths_append(item.path)
	_selected_path_len = copy(_selected_path_buf[:], item.path)
	_selected_name_len = copy(_selected_name_buf[:], item.name)
	_selected_type_len = copy(_selected_type_buf[:], item.type_name)
	_has_selection = true
	_fe_selection_epoch += 1

	if !item.is_dir && item.extension == ".mat" {
		_connect_material_editor_to_mat(item.path)
	}
}

_toggle_selection :: proc(item: file_exp.File_Item) {
	found_idx := -1
	for p, i in _selected_paths {
		if p == item.path {
			found_idx = i
			break
		}
	}
	if found_idx != -1 {
		_selected_paths_remove_at(found_idx)
		if len(_selected_paths) == 0 {
			_clear_selection()
		} else {
			last := _selected_paths[len(_selected_paths) - 1]
			_selected_path_len = copy(_selected_path_buf[:], last)
			_fe_selection_epoch += 1
		}
	} else {
		_selected_paths_append(item.path)
		_selected_path_len = copy(_selected_path_buf[:], item.path)
		_selected_name_len = copy(_selected_name_buf[:], item.name)
		_selected_type_len = copy(_selected_type_buf[:], item.type_name)
		_has_selection = true
		_fe_selection_epoch += 1
	}
}

_range_selection :: proc(item: file_exp.File_Item, items: []file_exp.File_Item) {
	anchor_path := _get_selected_path()
	anchor_idx := -1
	target_idx := -1
	for it, i in items {
		if it.path == anchor_path do anchor_idx = i
		if it.path == item.path do target_idx = i
	}
	if anchor_idx != -1 && target_idx != -1 {
		start := min(anchor_idx, target_idx)
		end := max(anchor_idx, target_idx)
		_selected_paths_clear()
		for i in start..=end {
			_selected_paths_append(items[i].path)
		}
		_selected_path_len = copy(_selected_path_buf[:], item.path)
		_selected_name_len = copy(_selected_name_buf[:], item.name)
		_selected_type_len = copy(_selected_type_buf[:], item.type_name)
		_has_selection = true
		_fe_selection_epoch += 1
	} else {
		_set_selection(item)
	}
}

_select_all :: proc(items: []file_exp.File_Item) {
	if len(items) == 0 do return
	_selected_paths_clear()
	for it in items {
		_selected_paths_append(it.path)
	}
	last := items[len(items) - 1]
	_selected_path_len = copy(_selected_path_buf[:], last.path)
	_selected_name_len = copy(_selected_name_buf[:], last.name)
	_selected_type_len = copy(_selected_type_buf[:], last.type_name)
	_has_selection = true
	_fe_selection_epoch += 1
}

_clear_selection :: proc() {
	_selected_paths_clear()
	_selected_path_len = 0
	_selected_name_len = 0
	_selected_type_len = 0
	_has_selection = false
	_fe_selection_epoch += 1
}

// UI state, Search Index & Resizable Splitter
@(private = "file") _search_buf:              [128]u8
// Default to Active Folder (Recursive) so typing searches the active folder first without crawling the whole repo!
@(private = "file") _search_scope:            file_exp.Search_Scope = .Active_Folder_Recursive
@(private = "file") _sort_mode:               file_exp.Sort_Mode = .Name_Asc

// Dedicated 4 MB Arena for the In-Memory Scope Index (rebuilt ONLY on folder/scope change or refresh, never on keystrokes)
@(private = "file") _index_backing:           [4 * 1024 * 1024]u8
@(private = "file") _index_arena:             mem.Arena
@(private = "file") _index_arena_init_done:   bool = false
@(private = "file") _scope_index:             [dynamic]file_exp.File_Item
@(private = "file") _scope_index_dirty:       bool = true
@(private = "file") _indexed_dir_buf:         [512]u8
@(private = "file") _indexed_dir_len:         int = -1
@(private = "file") _indexed_scope:           file_exp.Search_Scope = .Active_Folder_Recursive

@(private = "file") _search_backing:          [1024 * 1024]u8
@(private = "file") _search_arena:            mem.Arena
@(private = "file") _search_arena_init_done:  bool = false
@(private = "file") _search_results:          [dynamic]file_exp.File_Item
@(private = "file") _last_search_query_buf:   [128]u8
@(private = "file") _last_search_query_len:   int = -1
@(private = "file") _last_search_dir_buf:     [512]u8
@(private = "file") _last_search_dir_len:     int = -1
@(private = "file") _last_search_scope:       file_exp.Search_Scope = .Active_Folder_Recursive
@(private = "file") _last_search_sort:        file_exp.Sort_Mode = .Name_Asc
@(private = "file") _matched_ancestor_dirs:   map[string]bool

// Backspace / Widening Search Debounce (prevents micro-stutters when holding Backspace!)
SEARCH_WIDEN_DEBOUNCE_SEC :: 0.12
@(private = "file") _search_widen_deadline:   f64 = 0.0
@(private = "file") _pending_widen_query_buf: [128]u8
@(private = "file") _pending_widen_query_len: int = -1

// Frame-budgeted preview loading & Rubber-band Marquee multi-select state
MAX_PREVIEW_LOADS_PER_FRAME :: 2
@(private = "file") _previews_loaded_this_frame: int = 0
@(private = "file") _marquee_active:             bool = false
@(private = "file") _marquee_start:              im.Vec2
@(private = "file") _marquee_additive:           bool = false

@(private = "file") _left_pane_width:         f32 = 230.0 // Draggable divider width
@(private = "file") _show_inspector_pane:     bool = true
@(private = "file") _inspector_pane_width:    f32 = 248.0
@(private = "file") _inspector_orbit_yaw:     f32 = 0.65
@(private = "file") _inspector_orbit_pitch:   f32 = 0.38

@(private = "file")
_is_grid_mode :: proc() -> bool {
	return file_exp.settings.is_grid_view
}

@(private = "file")
_set_grid_mode :: proc(grid: bool) {
	file_exp.settings.is_grid_view = grid
}

@(private = "file")
_current_card_size :: proc() -> f32 {
	sz := file_exp.clamp_card_size(file_exp.settings.grid_card_size)
	file_exp.settings.grid_card_size = sz
	return sz
}

@(private = "file")
_set_card_size :: proc(px: f32) {
	file_exp.settings.grid_card_size = file_exp.clamp_card_size(px)
}

@(private = "file")
_current_list_scale :: proc() -> f32 {
	sc := file_exp.clamp_list_scale(file_exp.settings.list_row_scale)
	file_exp.settings.list_row_scale = sc
	return sc
}

@(private = "file")
_set_list_scale :: proc(scale: f32) {
	file_exp.settings.list_row_scale = file_exp.clamp_list_scale(scale)
}

@(private = "file")
_explorer_step_zoom :: proc(notches: f32) {
	if notches == 0 do return
	if _is_grid_mode() {
		_set_card_size(file_exp.step_card_size(_current_card_size(), notches))
	} else {
		_set_list_scale(file_exp.step_list_scale(_current_list_scale(), notches))
	}
}

@(private = "file")
_explorer_reset_zoom :: proc() {
	if _is_grid_mode() {
		_set_card_size(file_exp.CARD_SIZE_DEFAULT)
	} else {
		_set_list_scale(file_exp.LIST_SCALE_DEFAULT)
	}
}

@(private = "file")
_any_explorer_modal_open :: proc() -> bool {
	return _show_delete_modal || _show_rename_modal || _show_new_folder ||
	       _show_new_scene    || _show_new_script   || _show_color_picker
}

// Category Filter Chips (Unreal Engine Content Browser Style)
Explorer_Category_Filter :: enum {
	All = 0,
	Folders,
	Meshes,
	Textures,
	Materials,
	Audio,
	Scenes,
	Scripts,
}
@(private = "file") _category_filter: Explorer_Category_Filter = .All

// ─────────────────────────────────────────────────────────────
// LIVE ASSET PREVIEW CACHE (TEXTURES, 3D MESHES, MATERIALS, AUDIO, SCENES, SCRIPTS)
// ─────────────────────────────────────────────────────────────

Preview_Tri :: struct {
	v0, v1, v2: [3]f32,
	normal:     [3]f32,
}

Asset_Preview_Kind :: enum {
	None = 0,
	Folder,
	Texture,
	Mesh_3D,
	Material,
	Audio,
	Scene,
	Code,
}

Asset_Preview_Entry :: struct {
	loaded:             bool,
	kind:               Asset_Preview_Kind,
	// Folder preview
	folder_child_count: int,
	// Texture preview
	tex_valid:          bool,
	tex_imgui_id:       im.TextureID,
	owned_gfx_tex:      gfx.Texture,
	owns_gfx_tex:       bool,
	img_w:              int,
	img_h:              int,
	// 3D Mesh preview (normalized in [-1, 1]^3)
	mesh_tris:          [dynamic]Preview_Tri,
	vert_count:         int,
	tri_count:          int,
	mesh_bounds_ext:    [3]f32,
	// Material (.mat) preview
	mat_color:          [4]f32,
	mat_shader:         string,
	mat_tex_name:       string,
	mat_has_tex:        bool,
	mat_tex_id:         im.TextureID,
	// Audio (.wav / .ogg / .mp3) waveform preview
	audio_waveform:     [32]f32,
	audio_duration_sec: f32,
	audio_sample_rate:  int,
	audio_channels:     int,
	// Scene (.scene) preview
	scene_obj_count:    int,
	// Code / Script (.odin / .json / .glsl) preview
	code_lines:         [dynamic]string,
}

@(private = "file") _preview_cache: map[string]Asset_Preview_Entry

@(private)
_clear_preview_cache :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for k, &entry in _preview_cache {
		if entry.owns_gfx_tex {
			gfx.texture_destroy(&entry.owned_gfx_tex)
		}
		if entry.mesh_tris != nil {
			delete(entry.mesh_tris)
		}
		if len(entry.mat_shader) > 0 {
			delete(entry.mat_shader)
		}
		if len(entry.mat_tex_name) > 0 {
			delete(entry.mat_tex_name)
		}
		for line in entry.code_lines {
			delete(line)
		}
		if entry.code_lines != nil {
			delete(entry.code_lines)
		}
		delete(k)
	}
	clear(&_preview_cache)
}

@(private = "file")
_item_matches_category_filter :: proc(item: file_exp.File_Item, filter: Explorer_Category_Filter) -> bool {
	if filter == .All do return true
	ext := item.extension
	#partial switch filter {
	case .Folders:
		return item.is_dir
	case .Meshes:
		return !item.is_dir && (ext == ".glb" || ext == ".gltf" || ext == ".obj" || ext == ".fbx" || ext == ".fmesh")
	case .Textures:
		return !item.is_dir && (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tga" || ext == ".hdr")
	case .Materials:
		return !item.is_dir && (ext == ".mat" || ext == ".glsl" || ext == ".vert" || ext == ".frag")
	case .Audio:
		return !item.is_dir && (ext == ".wav" || ext == ".ogg" || ext == ".mp3" || ext == ".flac")
	case .Scenes:
		return !item.is_dir && (ext == ".scene" || ext == ".prefab")
	case .Scripts:
		return !item.is_dir && (ext == ".odin" || ext == ".json" || ext == ".md" || ext == ".txt")
	}
	return true
}

// Modal states (Fixed Buffers)
@(private = "file") _show_new_folder:         bool = false
@(private = "file") _new_folder_buf:          [128]u8

@(private = "file") _show_new_scene:          bool = false
@(private = "file") _new_scene_buf:           [128]u8
@(private = "file") _new_scene_template:      int = 0

@(private = "file") _show_new_script:         bool = false
@(private = "file") _new_script_buf:          [128]u8
@(private = "file") _new_script_template:     int = 0

@(private = "file") _show_delete_modal:       bool = false
@(private = "file") _delete_target_path_buf:  [512]u8
@(private = "file") _delete_target_path_len:  int = 0
@(private = "file") _delete_target_name_buf:  [256]u8
@(private = "file") _delete_target_name_len:  int = 0
@(private = "file") _delete_target_is_dir:    bool = false
@(private = "file") _explorer_window_hovered: bool = false
@(private = "file") _explorer_window_focused: bool = false
@(private) _mat_ed_window_hovered:   bool = false
@(private) _mat_ed_window_focused:   bool = false

// Returns true whenever Void File Explorer or Void Material Editor owns keyboard shortcuts
// (hovered, focused, or displaying a modal dialog), preventing Scene3D / Hierarchy from
// hijacking Delete, F2, Ctrl+C, Ctrl+V, or Ctrl+D and deleting scene entities!
owns_keyboard_shortcuts :: proc() -> bool {
	return _explorer_window_hovered || _explorer_window_focused ||
	       _mat_ed_window_hovered   || _mat_ed_window_focused   ||
	       _show_delete_modal || _show_rename_modal || _show_new_folder ||
	       _show_new_scene    || _show_new_script   || _show_color_picker
}

@(private = "file") _show_rename_modal:       bool = false
@(private = "file") _rename_target_path_buf:  [512]u8
@(private = "file") _rename_target_path_len:  int = 0
@(private = "file") _rename_buf:              [128]u8

// Unreal Engine style Folder Color Picker Modal state
@(private = "file") _show_color_picker:          bool = false
@(private = "file") _color_picker_folder_buf:    [128]u8
@(private = "file") _color_picker_folder_len:    int = 0
@(private = "file") _color_picker_current_col:   [4]f32 = {0.25, 0.65, 1.0, 1.0}

// Clipboard state (Fixed Buffers)
@(private = "file") _clipboard_path_buf:      [512]u8
@(private = "file") _clipboard_path_len:      int = 0
@(private = "file") _clipboard_has_item:      bool = false
@(private = "file") _scroll_to_selected:      bool = false

_set_selection_by_path :: proc(path: string) {
	for item in _items {
		if item.path == path {
			_set_selection(item)
			_scroll_to_selected = true
			return
		}
	}
}

_open_delete_modal_for_selected :: proc() {
	if !_has_selection do return
	target_path := _get_selected_path()
	target_name := _get_selected_name()
	_delete_target_path_len = copy(_delete_target_path_buf[:], target_path)
	_delete_target_name_len = copy(_delete_target_name_buf[:], target_name)
	_delete_target_is_dir   = os.is_dir(target_path)
	_show_delete_modal      = true
}

_open_delete_modal_for_path :: proc(path: string, label: string) {
	if len(path) == 0 do return
	_selected_path_len = copy(_selected_path_buf[:], path)
	_selected_name_len = copy(_selected_name_buf[:], label)
	_selected_type_len = copy(_selected_type_buf[:], "Folder" if os.is_dir(path) else "File")
	_selected_paths_clear()
	_selected_paths_append(path)
	_has_selection = true
	_fe_selection_epoch += 1
	_open_delete_modal_for_selected()
}

_open_rename_modal_for_selected :: proc() {
	if !_has_selection do return
	target_path := _get_selected_path()
	target_name := _get_selected_name()
	_rename_target_path_len = copy(_rename_target_path_buf[:], target_path)
	mem.zero(&_rename_buf, len(_rename_buf))
	copy(_rename_buf[:], target_name)
	_show_rename_modal = true
}

_copy_selected_to_clipboard :: proc() {
	if !_has_selection do return
	if len(_selected_paths) > 1 {
		b := strings.builder_make(context.temp_allocator)
		for p, i in _selected_paths {
			if i > 0 do strings.write_string(&b, "\n")
			strings.write_string(&b, p)
		}
		combined := strings.to_string(b)
		im.SetClipboardText(strings.clone_to_cstring(combined, context.temp_allocator))
		fmt.printfln("[Void Explorer] Copied %d items to clipboard", len(_selected_paths))
	} else {
		target_path := _get_selected_path()
		_clipboard_path_len = copy(_clipboard_path_buf[:], target_path)
		_clipboard_has_item = true
		im.SetClipboardText(strings.clone_to_cstring(target_path, context.temp_allocator))
		fmt.printfln("[Void Explorer] Copied: %s", target_path)
	}
}

_paste_from_clipboard :: proc() {
	src_path := ""
	if _clipboard_has_item && _clipboard_path_len > 0 {
		src_path = string(_clipboard_path_buf[:_clipboard_path_len])
	} else {
		clip := im.GetClipboardText()
		if clip != nil {
			clip_str := string(clip)
			if os.exists(clip_str) {
				src_path = clip_str
			}
		}
	}
	if src_path != "" && os.exists(src_path) {
		dest_dir := _get_current_dir()
		new_path, ok := file_exp.copy_entry(src_path, dest_dir)
		if ok {
			_refresh_items()
			_set_selection_by_path(new_path)
			fmt.printfln("[Void Explorer] Pasted: %s", new_path)
		}
	}
}

_jump_to_item_by_char :: proc(ch: rune) {
	q := _get_search_query()
	items := _search_results[:] if len(q) > 0 else _items[:]
	if len(items) == 0 do return

	prefix := fmt.tprintf("%c", ch)
	prefix_lower := strings.to_lower(prefix, context.temp_allocator)

	curr_idx := -1
	if _has_selection {
		sel_path := _get_selected_path()
		for item, i in items {
			if item.path == sel_path {
				curr_idx = i
				break
			}
		}
	}

	start := (curr_idx + 1) % len(items)
	for count := 0; count < len(items); count += 1 {
		idx := (start + count) % len(items)
		item_name_lower := strings.to_lower(items[idx].name, context.temp_allocator)
		if strings.has_prefix(item_name_lower, prefix_lower) {
			_set_selection(items[idx])
			_scroll_to_selected = true
			return
		}
	}
}

_handle_keyboard_shortcuts :: proc() {
	io := im.GetIO()
	if io.WantTextInput do return
	if _any_explorer_modal_open() {
		return
	}

	ctrl_down := io.KeyCtrl

	// Content Zoom shortcuts (Ctrl + = / - / 0)
	if ctrl_down {
		if im.IsKeyPressed(.Equal, false) || im.IsKeyPressed(.KeypadAdd, false) {
			_explorer_step_zoom(1.0)
			return
		}
		if im.IsKeyPressed(.Minus, false) || im.IsKeyPressed(.KeypadSubtract, false) {
			_explorer_step_zoom(-1.0)
			return
		}
		if im.IsKeyPressed(._0, false) || im.IsKeyPressed(.Keypad0, false) {
			_explorer_reset_zoom()
			return
		}
	}

	// 1. Delete key -> Delete selected item
	if im.IsKeyPressed(.Delete, false) {
		if _has_selection {
			_open_delete_modal_for_selected()
			return
		}
	}

	// 2. F2 key -> Rename selected item
	if im.IsKeyPressed(.F2, false) {
		if _has_selection {
			_open_rename_modal_for_selected()
			return
		}
	}

	// 3. Ctrl+C -> Copy selected item
	if ctrl_down && im.IsKeyPressed(.C, false) {
		if _has_selection {
			_copy_selected_to_clipboard()
			return
		}
	}

	// 4. Ctrl+V -> Paste item into current directory
	if ctrl_down && im.IsKeyPressed(.V, false) {
		_paste_from_clipboard()
		return
	}

	// 5. Ctrl+D -> Duplicate selected item
	if ctrl_down && im.IsKeyPressed(.D, false) {
		if _has_selection {
			_copy_selected_to_clipboard()
			_paste_from_clipboard()
			return
		}
	}

	// 6. Ctrl+A -> Select all items
	if ctrl_down && im.IsKeyPressed(.A, false) {
		q := _get_search_query()
		items := _search_results[:] if len(q) > 0 else _items[:]
		_select_all(items)
		return
	}

	// 6. Letter jump (A-Z and 0-9) - only without Ctrl/Alt
	if !ctrl_down && !io.KeyAlt {
		for k in im.Key.A ..= im.Key.Z {
			if im.IsKeyPressed(k, false) {
				ch := rune('a' + (int(k) - int(im.Key.A)))
				_jump_to_item_by_char(ch)
				return
			}
		}
		for k in im.Key._0 ..= im.Key._9 {
			if im.IsKeyPressed(k, false) {
				ch := rune('0' + (int(k) - int(im.Key._0)))
				_jump_to_item_by_char(ch)
				return
			}
		}
	}
}

// ─────────────────────────────────────────────────────────────
// LIFECYCLE & NAVIGATION (NO DELETES, ZERO CRASH RISK)
// ─────────────────────────────────────────────────────────────

@(private)
_ensure_init :: proc() {
	if _initialized do return
	_initialized = true

	if !_arena_init_done {
		mem.arena_init(&_items_arena, _items_backing[:])
		_arena_init_done = true
	}

	start_dir := "."
	if !engine.has_active_project() {
		start_dir = file_exp.resolve_workspace_path("plugins/void_odin", context.temp_allocator)
		if !os.exists(start_dir) {
			start_dir = file_exp.get_workspace_root()
		}
	}
	_set_current_dir(start_dir)

	_history_count = 1
	_history_idx = 0
	_history[0].len = copy(_history[0].buf[:], _get_current_dir())

	_needs_refresh = true
}

_navigate_to :: proc(target_path: string, push_history: bool = true, scroll_tree: bool = true, reveal_tree: bool = true) {
	clean, _ := filepath.clean(target_path, context.temp_allocator)
	norm, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)

	if !os.exists(norm) || !os.is_dir(norm) do return

	if push_history {
		if _history_idx >= 0 && _history_idx < _history_count - 1 {
			_history_count = _history_idx + 1
		}
		if _history_count < len(_history) {
			_history[_history_count].len = copy(_history[_history_count].buf[:], norm)
			_history_idx = _history_count
			_history_count += 1
		}
	}

	_set_current_dir(norm, trigger_reveal = false)
	_clear_selection()
	_needs_refresh = true
	if reveal_tree {
		_trigger_tree_reveal(scroll = scroll_tree)
	}
	if engine.overwatch_hooks_extended() {
		engine.overwatch_record_event(.User_Action, "VoidExplorer", fmt.tprintf("Navigated to folder '%s'", filepath.base(norm)))
	}
}

@(private = "file")
_nav_back :: proc() {
	if _history_idx > 0 {
		_history_idx -= 1
		entry := &_history[_history_idx]
		_set_current_dir(string(entry.buf[:entry.len]), trigger_reveal = true)
		_clear_selection()
		_needs_refresh = true
	}
}

@(private = "file")
_nav_forward :: proc() {
	if _history_idx >= 0 && _history_idx < _history_count - 1 {
		_history_idx += 1
		entry := &_history[_history_idx]
		_set_current_dir(string(entry.buf[:entry.len]), trigger_reveal = true)
		_clear_selection()
		_needs_refresh = true
	}
}

@(private = "file")
_nav_up :: proc() {
	curr := _get_current_dir()
	if curr == file_exp.get_workspace_root() do return
	parent := filepath.dir(curr)
	if parent != "" && parent != curr {
		_navigate_to(parent, push_history = true)
	}
}

@(private = "file")
_refresh_items :: proc() {
	if !_arena_init_done {
		mem.arena_init(&_items_arena, _items_backing[:])
		_arena_init_done = true
	}
	// Reset the arena offset: frees all memory without heap fragmentation or syscalls!
	_items_arena.offset = 0
	alloc := mem.arena_allocator(&_items_arena)

	_items = file_exp.read_dir_items(_get_current_dir(), file_exp.settings.show_hidden, alloc, _sort_mode)
	_clear_tree_subdirs_cache()
	_scope_index_dirty = true
	_last_search_query_len = -1
	_needs_refresh = false
}

// ─────────────────────────────────────────────────────────────
// MULTI-CORE ARRAY-SLICED SEARCH, INCREMENTAL NARROWING & CACHING
// ─────────────────────────────────────────────────────────────

@(private = "file")
_get_search_query :: proc() -> string {
	raw := strings.string_from_null_terminated_ptr(raw_data(_search_buf[:]), len(_search_buf))
	return strings.trim_space(raw)
}

@(private = "file")
_fe_matches_filter :: proc(name: string, query: string) -> bool {
	pq := file_exp.prepare_search_query(query, context.temp_allocator)
	if len(pq.raw_lower) == 0 do return true
	name_lower, name_norm := file_exp.normalize_search_key(name, context.temp_allocator)
	dummy := file_exp.File_Item{
		name       = name,
		path       = name,
		name_lower = name_lower,
		name_norm  = name_norm,
		path_lower = name_lower,
	}
	return file_exp.item_matches_prepared_query(dummy, &pq)
}

@(private = "file")
_ensure_scope_index :: proc() {
	curr_dir := _get_current_dir()
	indexed_dir := string(_indexed_dir_buf[:max(0, _indexed_dir_len)])
	if !_scope_index_dirty && _indexed_dir_len >= 0 && indexed_dir == curr_dir && _indexed_scope == _search_scope {
		return
	}

	if !_index_arena_init_done {
		mem.arena_init(&_index_arena, _index_backing[:])
		_index_arena_init_done = true
	}
	_index_arena.offset = 0
	idx_alloc := mem.arena_allocator(&_index_arena)

	_scope_index = file_exp.build_scope_index(curr_dir, _search_scope, file_exp.settings.show_hidden, idx_alloc)
	_indexed_dir_len = copy(_indexed_dir_buf[:], curr_dir)
	_indexed_scope = _search_scope
	_scope_index_dirty = false
}

@(private = "file")
_clear_matched_ancestor_dirs :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for k in _matched_ancestor_dirs {
		delete(k)
	}
	clear(&_matched_ancestor_dirs)
}

@(private = "file")
_rebuild_matched_ancestor_dirs :: proc() {
	_clear_matched_ancestor_dirs()
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	// Fast slice-based parent path walk: `item.path` is already normalized with `'/'`
	// at index-build time, so we simply slice at each `'/'` without calling `filepath.clean`
	// or `strings.replace_all` on every ancestor!
	for item in _search_results {
		p := item.path
		last_slash := strings.last_index_byte(p, '/')
		safety := 0
		for last_slash > 0 && safety < 16 {
			safety += 1
			curr := p[:last_slash]
			if curr == "." || curr == ".." || curr == "/" do break
			if !(curr in _matched_ancestor_dirs) {
				_matched_ancestor_dirs[strings.clone(curr)] = true
			}
			last_slash = strings.last_index_byte(curr, '/')
		}
	}
}

@(private = "file")
_update_search_results :: proc() {
	if _needs_refresh {
		_refresh_items()
	}

	query := _get_search_query()
	if len(query) == 0 {
		_search_widen_deadline   = 0.0
		_pending_widen_query_len = -1
		if _last_search_query_len != 0 {
			_clear_matched_ancestor_dirs()
			_last_search_query_len = 0
		}
		return
	}

	curr_dir := _get_current_dir()
	last_query := string(_last_search_query_buf[:max(0, _last_search_query_len)])
	last_dir := string(_last_search_dir_buf[:max(0, _last_search_dir_len)])

	query_changed := _last_search_query_len < 0 || last_query != query
	dir_changed := _search_scope != .All_Project && (_last_search_dir_len < 0 || last_dir != curr_dir)
	scope_changed := _last_search_scope != _search_scope
	sort_changed := _last_search_sort != _sort_mode

	if !query_changed && !dir_changed && !scope_changed && !sort_changed && !_needs_refresh && !_scope_index_dirty {
		return
	}

	// Ensure our in-memory scope index is up to date (zero disk I/O on keystrokes!)
	_ensure_scope_index()

	// Fast path: if only sort order changed, sort existing results in-place
	if !query_changed && !dir_changed && !scope_changed && !_scope_index_dirty && sort_changed {
		file_exp.sort_file_items(_search_results[:], _sort_mode)
		_last_search_sort = _sort_mode
		return
	}

	// Incremental Narrowing vs Widening (Backspace):
	// - Added letters (`can_narrow_search_query` == true) and previous result set wasn't capped:
	//   narrow down immediately from surviving `_search_results[:]` (zero delay!)
	// - Removed letters (Backspace / widening): debounce for 120ms (`SEARCH_WIDEN_DEBOUNCE_SEC`)
	//   when the scope index is large (`len(_scope_index) >= 128`) so rapid Backspace keystrokes
	//   never stutter the main thread or overwhelm worker threads!
	can_narrow := !dir_changed && !scope_changed && _last_search_query_len > 0 && len(_search_results) < 2000 && file_exp.can_narrow_search_query(last_query, query)
	if query_changed && !can_narrow && !dir_changed && !scope_changed && _last_search_query_len > len(query) && len(_scope_index) >= 128 {
		now_sec := im.GetTime()
		pending_q := string(_pending_widen_query_buf[:max(0, _pending_widen_query_len)])
		if _pending_widen_query_len < 0 || pending_q != query {
			_pending_widen_query_len = copy(_pending_widen_query_buf[:], query)
			_search_widen_deadline   = now_sec + SEARCH_WIDEN_DEBOUNCE_SEC
			return
		}
		if now_sec < _search_widen_deadline {
			return
		}
	}
	_search_widen_deadline   = 0.0
	_pending_widen_query_len = -1

	var_candidates: []file_exp.File_Item
	if can_narrow {
		// Snapshot surviving items in temp_allocator before resetting _search_arena
		snap := make([]file_exp.File_Item, len(_search_results), context.temp_allocator)
		copy(snap, _search_results[:])
		var_candidates = snap
	} else {
		var_candidates = _scope_index[:]
	}

	if !_search_arena_init_done {
		mem.arena_init(&_search_arena, _search_backing[:])
		_search_arena_init_done = true
	}
	_search_arena.offset = 0
	alloc := mem.arena_allocator(&_search_arena)

	_search_results = make([dynamic]file_exp.File_Item, 0, min(len(var_candidates), 2000), alloc)

	// Slice `var_candidates` across worker cores via `engine.job_parallel_for` (or tight single-core loop when < 256)!
	file_exp.filter_items_parallel(var_candidates, query, &_search_results, _sort_mode)

	_rebuild_matched_ancestor_dirs()

	_last_search_query_len = copy(_last_search_query_buf[:], query)
	_last_search_dir_len = copy(_last_search_dir_buf[:], curr_dir)
	_last_search_scope = _search_scope
	_last_search_sort = _sort_mode
}

@(private = "file")
_folder_has_search_match :: proc(folder_path: string) -> (matches_self: bool, has_matching_child: bool) {
	q := _get_search_query()
	if len(q) == 0 do return false, false

	clean_folder, _ := filepath.clean(folder_path, context.temp_allocator)
	norm_folder, _ := strings.replace_all(clean_folder, "\\", "/", context.temp_allocator)

	base_name := filepath.base(norm_folder)
	if base_name == "." || base_name == ".." || base_name == "" do base_name = "Root"
	matches_self = _fe_matches_filter(base_name, q)

	if norm_folder == "." || norm_folder == ".." || norm_folder == file_exp.get_workspace_root() {
		has_matching_child = len(_search_results) > 0
		return
	}

	has_matching_child = norm_folder in _matched_ancestor_dirs
	return
}

// Drag-and-Drop Folder Target: allows dropping ASSET_PATH payloads onto any folder
// (Grid cards, List rows, Breadcrumbs, Bookmarks, and Folder Tree nodes) to move files/folders!
@(private = "file")
_accept_folder_drop_target :: proc(target_dir: string) {
	if len(target_dir) == 0 do return
	if im.BeginDragDropTarget() {
		if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
			dropped_p := strings.trim_right_null(string(([^]u8)(payload.Data)[:payload.DataSize]))
			if len(dropped_p) > 0 {
				moved_any := false
				last_moved := ""
				// If the dropped item is part of a multi-selection, move all selected items together
				if _is_item_selected(dropped_p) && len(_selected_paths) > 1 {
					paths_to_move := make([dynamic]string, 0, len(_selected_paths), context.temp_allocator)
					for sp in _selected_paths {
						append(&paths_to_move, strings.clone(sp, context.temp_allocator))
					}
					for sp in paths_to_move {
						if new_p, ok := file_exp.move_entry(sp, target_dir); ok {
							moved_any = true
							last_moved = new_p
						}
					}
				} else {
					if new_p, ok := file_exp.move_entry(dropped_p, target_dir); ok {
						moved_any = true
						last_moved = new_p
					}
				}
				if moved_any {
					engine.asset_db_request_refresh()
					_clear_preview_cache()
					_clear_selection()
					_scope_index_dirty = true
					_needs_refresh = true
					if len(last_moved) > 0 {
						fmt.printfln("[Void Explorer] Moved -> %s", last_moved)
						if engine.overwatch_hooks_extended() {
							engine.overwatch_record_event(.User_Action, "VoidExplorer", fmt.tprintf("Moved item into '%s' (-> %s)", filepath.base(target_dir), filepath.base(last_moved)))
						}
					}
				}
			}
		}
		im.EndDragDropTarget()
	}
}

@(private = "file")
_open_color_picker_for_folder :: proc(folder_key: string) {
	_color_picker_folder_len = copy(_color_picker_folder_buf[:], folder_key)
	existing_col, has_col := editor_visuals.get_folder_color(folder_key)
	if has_col {
		_color_picker_current_col = existing_col
	} else {
		_color_picker_current_col = {0.25, 0.65, 1.0, 1.0}
	}
	_show_color_picker = true
}

// ─────────────────────────────────────────────────────────────
// UNREAL ENGINE STYLE FOLDER COLOR PALETTE SUBMENU
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_color_palette_menu :: proc(dir_path: string) {
	folder_key := filepath.base(dir_path)
	if folder_key == "." || folder_key == ".." || folder_key == "" do folder_key = "Root"

	Palette_Color :: struct {
		name: string,
		col:  [4]f32,
	}
	presets := []Palette_Color{
		{"Red",          {0.92, 0.25, 0.25, 1.0}},
		{"Orange",       {0.95, 0.55, 0.15, 1.0}},
		{"Amber / Gold", {0.95, 0.78, 0.12, 1.0}},
		{"Green",        {0.18, 0.80, 0.44, 1.0}},
		{"Emerald",      {0.10, 0.65, 0.45, 1.0}},
		{"Teal",         {0.12, 0.75, 0.82, 1.0}},
		{"Cyan",         {0.20, 0.85, 0.95, 1.0}},
		{"Blue",         {0.25, 0.55, 0.95, 1.0}},
		{"Indigo",       {0.45, 0.45, 0.95, 1.0}},
		{"Purple",       {0.72, 0.40, 0.95, 1.0}},
		{"Pink / Rose",  {0.95, 0.35, 0.65, 1.0}},
		{"Slate / Gray", {0.55, 0.65, 0.75, 1.0}},
	}

	for p in presets {
		im.PushStyleColorImVec4(.Text, p.col)
		// Use ICON_MD_RECORD (solid circle glyph) to eliminate any unicode missing character diamond!
		label := fmt.ctprintf("%s  %s", icons.ICON_MD_RECORD, p.name)
		if im.MenuItem(label) {
			editor_visuals.set_folder_color(folder_key, p.col)
		}
		im.PopStyleColor()
	}

	im.Separator()

	if im.MenuItem(fmt.ctprintf("%s  Custom Color...", icons.ICON_MD_PALETTE)) {
		_open_color_picker_for_folder(folder_key)
	}

	if im.MenuItem(fmt.ctprintf("%s  Reset to Default Color", icons.ICON_MD_REFRESH)) {
		editor_visuals.clear_folder_color(folder_key)
	}
}

@(private = "file")
_draw_folder_dropdown_menu :: proc(dir_path: string, label: string) {
	im.TextColoredUnformatted({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("%s  %s", icons.ICON_MD_FOLDER, label))
	im.Separator()

	if im.MenuItem(fmt.ctprintf("%s  Open Folder", icons.ICON_MD_FOLDER_OPEN)) {
		_navigate_to(dir_path)
	}
	if im.MenuItem(fmt.ctprintf("%s  Show in %s", icons.ICON_MD_FOLDER_OPEN, file_exp.get_os_explorer_name())) {
		file_exp.reveal_in_os(dir_path)
	}

	im.Separator()

	// Unreal style Set Color submenu
	if im.BeginMenu(fmt.ctprintf("%s  Set Color", icons.ICON_MD_PALETTE)) {
		_draw_color_palette_menu(dir_path)
		im.EndMenu()
	}

	// Pin or Unpin from Quick Access
	is_pinned := file_exp.is_bookmark(dir_path)
	if is_pinned {
		if im.MenuItem(fmt.ctprintf("%s  Unpin from Quick Access", icons.ICON_MD_CLOSE)) {
			file_exp.remove_bookmark(dir_path)
		}
	} else {
		if im.MenuItem(fmt.ctprintf("%s  Pin to Quick Access", icons.ICON_MD_ADD)) {
			file_exp.add_bookmark(label, dir_path)
		}
	}

	im.Separator()

	if im.MenuItem(fmt.ctprintf("%s  New Folder...", icons.ICON_MD_FOLDER)) {
		_navigate_to(dir_path)
		mem.zero(&_new_folder_buf, len(_new_folder_buf))
		copy_str := "New_Folder"
		mem.copy(&_new_folder_buf[0], raw_data(copy_str), len(copy_str))
		_show_new_folder = true
	}
	if im.MenuItem(fmt.ctprintf("%s  New Level / Scene (.scene)...", icons.ICON_MD_PLAY_CIRCLE)) {
		_navigate_to(dir_path)
		mem.zero(&_new_scene_buf, len(_new_scene_buf))
		copy_str := "New_Level.scene"
		mem.copy(&_new_scene_buf[0], raw_data(copy_str), len(copy_str))
		_new_scene_template = 0
		_show_new_scene = true
	}
	if im.MenuItem(fmt.ctprintf("%s  New Odin Script (.odin)...", icons.ICON_MD_CODE)) {
		_navigate_to(dir_path)
		mem.zero(&_new_script_buf, len(_new_script_buf))
		copy_str := "new_script.odin"
		mem.copy(&_new_script_buf[0], raw_data(copy_str), len(copy_str))
		_new_script_template = 0
		_show_new_script = true
	}
	if im.MenuItem(fmt.ctprintf("%s  New Material (.mat)", icons.ICON_MD_PALETTE)) {
		_navigate_to(dir_path)
		_create_new_material_in_dir(dir_path)
	}

	ws_root := file_exp.get_workspace_root()
	if dir_path != ws_root && dir_path != "." && dir_path != ".." {
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Delete Folder... (Del)", icons.ICON_MD_DELETE)) {
			_open_delete_modal_for_path(dir_path, label)
		}
	}
}

@(private = "file")
_create_new_material_in_dir :: proc(dir_path: string) {
	clean_d, _ := filepath.clean(dir_path, context.temp_allocator)
	norm_d, _ := strings.replace_all(clean_d, "\\", "/", context.temp_allocator)
	if len(norm_d) == 0 || norm_d == "." {
		_ = os.make_directory("assets")
		_ = os.make_directory("assets/materials")
		norm_d = "assets/materials"
	}
	mat_path := fmt.tprintf("%s/New_Material.mat", norm_d)
	suffix := 1
	for os.exists(mat_path) && suffix < 100 {
		mat_path = fmt.tprintf("%s/New_Material_%d.mat", norm_d, suffix)
		suffix += 1
	}
	if engine.material_save_to_file(mat_path, engine.Material{
		shader = .Lit,
		color  = {0.85, 0.85, 0.90, 1.0},
	}) {
		engine.asset_db_request_refresh()
		_refresh_items()
		_show_inspector_pane = true
		_set_selection_by_path(mat_path)
		_connect_material_editor_to_mat(mat_path)
	}
}

// ─────────────────────────────────────────────────────────────
// DIALOGS & MODALS
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_modals :: proc() {
	center := widgets.active_monitor_center()

	// 1. New Folder Modal
	if _show_new_folder {
		im.OpenPopup("Create New Folder", {})
	}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Create New Folder", &_show_new_folder, {.AlwaysAutoResize}) {
		im.TextColoredUnformatted({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("%s  Create New Folder", icons.ICON_MD_FOLDER))
		im.Separator()
		im.Spacing()

		im.Text("Folder Name:")
		im.SetNextItemWidth(-1)
		enter_pressed := im.InputText("##NewFolderName", cstring(raw_data(_new_folder_buf[:])), len(_new_folder_buf), {.EnterReturnsTrue})

		im.Spacing()
		im.Separator()
		im.Spacing()

		if im.Button(fmt.ctprintf("%s  Create", icons.ICON_MD_CHECK), {110, 30}) || enter_pressed {
			name := strings.string_from_null_terminated_ptr(raw_data(_new_folder_buf[:]), len(_new_folder_buf))
			if len(strings.trim_space(name)) > 0 {
				_, ok := file_exp.create_folder(_get_current_dir(), name)
				if ok {
					_needs_refresh = true
				}
			}
			_show_new_folder = false
			im.CloseCurrentPopup()
		}
		im.SameLine(0, 15)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {110, 30}) {
			_show_new_folder = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// 2. New Scene / Level Modal
	if _show_new_scene {
		im.OpenPopup("Create New Level / Scene", {})
	}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Create New Level / Scene", &_show_new_scene, {.AlwaysAutoResize}) {
		im.TextColoredUnformatted({0.8, 0.45, 1.0, 1.0}, fmt.ctprintf("%s  Create New Scene (.scene)", icons.ICON_MD_PLAY_CIRCLE))
		im.Separator()
		im.Spacing()

		im.Text("Scene Name:")
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(320)
		enter_pressed := im.InputText("##NewSceneName", cstring(raw_data(_new_scene_buf[:])), len(_new_scene_buf), {.EnterReturnsTrue})

		im.Spacing()
		im.Separator()
		im.Spacing()

		if im.Button(fmt.ctprintf("%s  Create Scene", icons.ICON_MD_CHECK), {140, 30}) || enter_pressed {
			name := strings.string_from_null_terminated_ptr(raw_data(_new_scene_buf[:]), len(_new_scene_buf))
			if len(strings.trim_space(name)) > 0 {
				new_path, ok := file_exp.create_level_scene(_get_current_dir(), name)
				if ok {
					_needs_refresh = true
					engine.asset_db_request_refresh()
					_open_scene_in_editor(new_path)
				}
			}
			_show_new_scene = false
			im.CloseCurrentPopup()
		}
		im.SameLine(0, 15)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {110, 30}) {
			_show_new_scene = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// 3. New Odin Script Modal
	if _show_new_script {
		im.OpenPopup("Create New Odin Script", {})
	}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Create New Odin Script", &_show_new_script, {.AlwaysAutoResize}) {
		im.TextColoredUnformatted({0.35, 0.7, 1.0, 1.0}, fmt.ctprintf("%s  Create New Odin Component (.odin)", icons.ICON_MD_CODE))
		im.Separator()
		im.Spacing()

		im.Text("Component / Script Name:")
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(320)
		enter_pressed := im.InputText("##NewScriptName", cstring(raw_data(_new_script_buf[:])), len(_new_script_buf), {.EnterReturnsTrue})

		im.Spacing()
		im.Separator()
		im.Spacing()

		if im.Button(fmt.ctprintf("%s  Create Script", icons.ICON_MD_CHECK), {140, 30}) || enter_pressed {
			name := strings.string_from_null_terminated_ptr(raw_data(_new_script_buf[:]), len(_new_script_buf))
			if len(strings.trim_space(name)) > 0 {
				new_path, ok := file_exp.create_odin_script(_get_current_dir(), name)
				if ok {
					_needs_refresh = true
					engine.asset_db_request_refresh()
					file_exp.open_script_in_ide(new_path)
				}
			}
			_show_new_script = false
			im.CloseCurrentPopup()
		}
		im.SameLine(0, 15)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {110, 30}) {
			_show_new_script = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// 4. Rename Modal
	if _show_rename_modal {
		im.OpenPopup("Rename Item", {})
	}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Rename Item", &_show_rename_modal, {.AlwaysAutoResize}) {
		im.TextColoredUnformatted({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("%s  Rename", icons.ICON_MD_EDIT))
		im.Separator()
		im.Spacing()

		im.Text("New Name:")
		im.SetNextItemWidth(-1)
		if im.IsWindowAppearing() {
			im.SetKeyboardFocusHere()
		}
		enter_pressed := im.InputText("##RenameInput", cstring(raw_data(_rename_buf[:])), len(_rename_buf), {.EnterReturnsTrue})

		im.Spacing()
		im.Separator()
		im.Spacing()

		if im.Button(fmt.ctprintf("%s  Rename", icons.ICON_MD_CHECK), {110, 30}) || enter_pressed {
			new_name := strings.string_from_null_terminated_ptr(raw_data(_rename_buf[:]), len(_rename_buf))
			if len(strings.trim_space(new_name)) > 0 {
				target_path := string(_rename_target_path_buf[:_rename_target_path_len])
				new_path, ok := file_exp.rename_entry(target_path, new_name)
				if ok {
					defer delete(new_path)
					if sc := engine.sm_scene_get_active(); sc != nil && len(sc.path) > 0 {
						sc_disk := _vh_normalize_scene_disk_path(sc.path, context.temp_allocator)
						t_norm, _ := strings.replace_all(target_path, "\\", "/", context.temp_allocator)
						if strings.equal_fold(sc_disk, t_norm) || strings.equal_fold(filepath.base(sc_disk), filepath.base(t_norm)) {
							delete(sc.path)
							sc.path = strings.clone(new_path)
						}
					}
					engine.asset_db_request_refresh()
					_clear_selection()
					_needs_refresh = true
				}
			}
			_show_rename_modal = false
			im.CloseCurrentPopup()
		}
		im.SameLine(0, 15)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {110, 30}) || im.IsKeyPressed(.Escape, false) {
			_show_rename_modal = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// 5. Custom Folder Color Modal (Unreal Engine Style)
	if _show_color_picker {
		im.OpenPopup("Set Folder Color", {})
	}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Set Folder Color", &_show_color_picker, {.AlwaysAutoResize}) {
		folder_name := string(_color_picker_folder_buf[:_color_picker_folder_len])
		im.TextColoredUnformatted({0.35, 0.75, 1.0, 1.0}, fmt.ctprintf("%s  Set Folder Color: \"%s\"", icons.ICON_MD_PALETTE, folder_name))
		im.Separator()
		im.Spacing()

		im.ColorPicker4("##FolderColorPicker", &_color_picker_current_col, {.NoAlpha, .NoSidePreview})

		im.Spacing()
		im.Separator()
		im.Spacing()

		if im.Button(fmt.ctprintf("%s  Apply Color", icons.ICON_MD_CHECK), {120, 30}) {
			editor_visuals.set_folder_color(folder_name, _color_picker_current_col)
			_show_color_picker = false
			im.CloseCurrentPopup()
		}
		im.SameLine(0, 12)
		if im.Button(fmt.ctprintf("%s  Reset Default", icons.ICON_MD_REFRESH), {120, 30}) {
			editor_visuals.clear_folder_color(folder_name)
			_show_color_picker = false
			im.CloseCurrentPopup()
		}
		im.SameLine(0, 12)
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {90, 30}) {
			_show_color_picker = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// 6. Confirm Delete Modal (In-window popup modal — guaranteed to open from both context menu & Delete key!)
	if _show_delete_modal {
		im.OpenPopup("Confirm Delete", {})
	}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Confirm Delete", &_show_delete_modal, {.AlwaysAutoResize}) {
		im.TextColoredUnformatted({1.0, 0.35, 0.35, 1.0}, fmt.ctprintf("%s  Confirm Permanent Delete", icons.ICON_MD_DELETE))
		im.Separator()
		im.Spacing()

		sel_count := len(_selected_paths)
		if sel_count > 1 {
			im.TextUnformatted(fmt.ctprintf("Are you sure you want to permanently delete these %d items from disk?", sel_count))
		} else {
			target_name := string(_delete_target_name_buf[:_delete_target_name_len])
			kind_str := "folder" if _delete_target_is_dir else "file"
			im.TextUnformatted(fmt.ctprintf("Are you sure you want to permanently delete this %s?", kind_str))
			im.Spacing()
			im.TextColoredUnformatted({0.95, 0.85, 0.35, 1.0}, fmt.ctprintf("    \"%s\"", target_name))
		}
		im.Spacing()
		im.TextDisabled("ATTENTION: This removes the item directly from disk and cannot be undone.")
		im.Spacing()
		im.Separator()
		im.Spacing()

		im.PushStyleColorImVec4(.Button,        {0.78, 0.18, 0.18, 0.92})
		im.PushStyleColorImVec4(.ButtonHovered, {0.92, 0.24, 0.24, 1.00})
		im.PushStyleColorImVec4(.ButtonActive,  {1.00, 0.15, 0.15, 1.00})
		confirm_hit := im.Button(fmt.ctprintf("%s  Delete Permanently (Enter)", icons.ICON_MD_DELETE), {210, 30}) || im.IsKeyPressed(.Enter, false)
		im.PopStyleColor(3)

		im.SameLine(0, 15)
		cancel_hit := im.Button(fmt.ctprintf("%s  Cancel (Esc)", icons.ICON_MD_CLOSE), {120, 30}) || im.IsKeyPressed(.Escape, false)

		if confirm_hit {
			if sel_count > 1 {
				for p in _selected_paths {
					if len(p) > 0 {
						file_exp.delete_entry(p)
					}
				}
			} else {
				target_path := string(_delete_target_path_buf[:_delete_target_path_len])
				if len(target_path) > 0 {
					file_exp.delete_entry(target_path)
				}
			}
			_clear_preview_cache()
			_clear_selection()
			_needs_refresh     = true
			_show_delete_modal = false
			im.CloseCurrentPopup()
		} else if cancel_hit {
			_show_delete_modal = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

// ─────────────────────────────────────────────────────────────
// TOP TOOLBAR & BREADCRUMBS
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_view_and_zoom_controls :: proc(btn_sz: f32) {
	p := thm.palette()
	io := im.GetIO()
	grid_active := _is_grid_mode()

	// 1. Segmented [Grid | List] Toggle
	if widgets.icon_button(icons.ICON_MD_GRID_VIEW, "##ViewModeGrid", "Grid / Tile View", active = grid_active, size = btn_sz) {
		_set_grid_mode(true)
	}
	im.SameLine(0, 2)
	if widgets.icon_button(icons.ICON_MD_LIST_ALT, "##ViewModeList", "Details / List View", active = !grid_active, size = btn_sz) {
		_set_grid_mode(false)
	}

	// Subtle vertical hairline divider
	im.SameLine(0, 7)
	div_pos := im.GetCursorScreenPos()
	im.DrawList_AddLine(
		im.GetWindowDrawList(),
		{div_pos.x, div_pos.y + 3.0},
		{div_pos.x, div_pos.y + btn_sz - 3.0},
		im.GetColorU32ImVec4(p.border_subtle),
		1.0,
	)
	im.Dummy({1.0, btn_sz})

	// 2. Zoom Out [-]
	im.SameLine(0, 7)
	out_tip: cstring = "Reduce Tile Size (Ctrl + MouseWheel Down / Ctrl + -)" if grid_active else "Reduce Row Density (Ctrl + MouseWheel Down / Ctrl + -)"
	if widgets.ghost_icon_button(icons.ICON_MD_REMOVE, "##ZoomStepOut", out_tip, size = btn_sz) {
		_explorer_step_zoom(-1.0)
	}

	// 3. Clean Wide Smooth Slider (empty track format -> zero grab/text overlap)
	im.SameLine(0, 4)
	slider_w: f32 = 132.0
	im.SetNextItemWidth(slider_w)
	im.PushStyleColorImVec4(.FrameBg, p.bg_recessed)
	im.PushStyleColorImVec4(.FrameBgHovered, p.bg_hover)
	im.PushStyleColorImVec4(.FrameBgActive, p.bg_active)
	im.PushStyleColorImVec4(.SliderGrab, p.accent)
	im.PushStyleColorImVec4(.SliderGrabActive, p.accent_hover)
	im.PushStyleVar(.FrameRounding, 4.0)
	im.PushStyleVar(.GrabRounding, 4.0)
	im.PushStyleVar(.GrabMinSize, 10.0)

	def_t: f32
	if grid_active {
		sz := _current_card_size()
		if im.SliderFloat("##ExplorerCardSizeSlider", &sz, file_exp.CARD_SIZE_MIN, file_exp.CARD_SIZE_MAX, "") {
			_set_card_size(sz)
		}
		def_t = (file_exp.CARD_SIZE_DEFAULT - file_exp.CARD_SIZE_MIN) / (file_exp.CARD_SIZE_MAX - file_exp.CARD_SIZE_MIN)
	} else {
		pct := _current_list_scale() * 100.0
		if im.SliderFloat("##ExplorerListZoomSlider", &pct, file_exp.LIST_SCALE_MIN * 100.0, file_exp.LIST_SCALE_MAX * 100.0, "") {
			_set_list_scale(pct / 100.0)
		}
		def_t = (file_exp.LIST_SCALE_DEFAULT - file_exp.LIST_SCALE_MIN) / (file_exp.LIST_SCALE_MAX - file_exp.LIST_SCALE_MIN)
	}

	s_min := im.GetItemRectMin()
	s_max := im.GetItemRectMax()
	if im.IsItemHovered() && io.MouseWheel != 0 && !io.KeyCtrl {
		_explorer_step_zoom(io.MouseWheel)
		io.MouseWheel = 0
	}
	if grid_active {
		widgets.tooltip(fmt.ctprintf("Tile Size: %.0f px  (Range: %.0fpx - %.0fpx)\nCtrl + MouseWheel anywhere in Explorer to zoom\nCtrl + = / - / 0 shortcuts", _current_card_size(), file_exp.CARD_SIZE_MIN, file_exp.CARD_SIZE_MAX))
	} else {
		widgets.tooltip(fmt.ctprintf("List Density: %.0f%%  (Range: %.0f%% - %.0f%%)\nCtrl + MouseWheel anywhere in Explorer to zoom\nCtrl + = / - / 0 shortcuts", math.round(_current_list_scale() * 100.0), file_exp.LIST_SCALE_MIN * 100.0, file_exp.LIST_SCALE_MAX * 100.0))
	}

	im.PopStyleVar(3)
	im.PopStyleColor(5)

	// Subtle default-snap tick mark above/below track center
	tick_x := s_min.x + 5.0 + def_t * max(1.0, (s_max.x - s_min.x) - 10.0)
	im.DrawList_AddLine(
		im.GetWindowDrawList(),
		{tick_x, s_max.y - 3.0},
		{tick_x, s_max.y},
		im.GetColorU32ImVec4(p.text_muted),
		1.0,
	)

	// 4. Zoom In [+]
	im.SameLine(0, 4)
	in_tip: cstring = "Enlarge Tile Size (Ctrl + MouseWheel Up / Ctrl + +)" if grid_active else "Increase Row Density (Ctrl + MouseWheel Up / Ctrl + +)"
	if widgets.ghost_icon_button(icons.ICON_MD_ADD, "##ZoomStepIn", in_tip, size = btn_sz) {
		_explorer_step_zoom(1.0)
	}

	// 5. Fixed-Width Clickable Readout & View/Size Presets Pill (Left-click: Presets, Right/Middle-click: Reset)
	im.SameLine(0, 4)
	readout_lbl: cstring
	if grid_active {
		readout_lbl = fmt.ctprintf("%.0fpx##ZoomReadoutBtn", _current_card_size())
	} else {
		readout_lbl = fmt.ctprintf("%.0f%%##ZoomReadoutBtn", math.round(_current_list_scale() * 100.0))
	}
	im.PushStyleColorImVec4(.Button, p.bg_elevated)
	im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
	im.PushStyleColorImVec4(.Border, p.border_subtle)
	im.PushStyleVar(.FrameBorderSize, 1.0)
	if im.Button(readout_lbl, {58.0, btn_sz}) {
		im.OpenPopup("##ExplorerZoomPresetsPopup", {})
	}
	if im.IsItemHovered() && (im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)) {
		_explorer_reset_zoom()
	}
	widgets.tooltip("Click: Size & View Presets\nRight-Click: Reset to Default (Ctrl+0)\nCtrl + MouseWheel: Smooth Zoom")
	im.PopStyleVar()
	im.PopStyleColor(3)

	if im.BeginPopup("##ExplorerZoomPresetsPopup") {
		widgets.popup_header(icons.ICON_MD_ZOOM_IN, "View & Size Presets", p.accent)
		curr_px := _current_card_size()
		Grid_Preset :: struct {
			label: cstring,
			px:    f32,
		}
		grid_presets := [6]Grid_Preset{
			{"Compact Icons (48px)",           48.0},
			{"Small Tiles (68px)",             68.0},
			{"Medium Cards - Default (104px)", file_exp.CARD_SIZE_DEFAULT},
			{"Large Cards (152px)",            152.0},
			{"Extra Large Previews (208px)",   208.0},
			{"Jumbo Showcase (256px)",         256.0},
		}
		for gp in grid_presets {
			is_curr := grid_active && abs(curr_px - gp.px) < 1.0
			if im.MenuItem(gp.label, nil, is_curr) {
				_set_grid_mode(true)
				_set_card_size(gp.px)
			}
		}

		im.Separator()
		curr_sc := _current_list_scale()
		List_Preset :: struct {
			label: cstring,
			scale: f32,
		}
		list_presets := [4]List_Preset{
			{"Details List - Compact (85%)",      0.85},
			{"Details List - Standard (100%)",    file_exp.LIST_SCALE_DEFAULT},
			{"Details List - Comfortable (125%)", 1.25},
			{"Details List - Large (150%)",       1.50},
		}
		for lp in list_presets {
			is_curr := !grid_active && abs(curr_sc - lp.scale) < 0.03
			if im.MenuItem(lp.label, nil, is_curr) {
				_set_grid_mode(false)
				_set_list_scale(lp.scale)
			}
		}

		im.Separator()
		if im.MenuItem("Reset Current View Zoom", "Ctrl+0") {
			_explorer_reset_zoom()
		}
		im.EndPopup()
	}
}

@(private = "file")
_draw_toolbar :: proc() {
	// 1. Navigation Buttons (Back, Forward, Up, Refresh)
	back_disabled := _history_idx <= 0
	if back_disabled {
		im.BeginDisabled()
	}
	if im.Button(icons.ICON_MD_CHEVRON_LEFT) {
		_nav_back()
	}
	if back_disabled {
		im.EndDisabled()
	}
	widgets.tooltip("Back")

	im.SameLine(0, 4)
	fwd_disabled := _history_idx < 0 || _history_idx >= _history_count - 1
	if fwd_disabled {
		im.BeginDisabled()
	}
	if im.Button(icons.ICON_MD_CHEVRON_RIGHT) {
		_nav_forward()
	}
	if fwd_disabled {
		im.EndDisabled()
	}
	widgets.tooltip("Forward")

	im.SameLine(0, 4)
	if im.Button(icons.ICON_MD_EXPAND_LESS) {
		_nav_up()
	}
	widgets.tooltip("Up to Parent Folder")

	im.SameLine(0, 4)
	if im.Button(icons.ICON_MD_REFRESH) {
		_needs_refresh = true
	}
	widgets.tooltip("Refresh Folder")

	// 2. Clickable Breadcrumbs Bar
	im.SameLine(0, 12)
	im.PushStyleColorImVec4(.Button, {0.12, 0.14, 0.18, 0.7})
	im.PushStyleColorImVec4(.ButtonHovered, {0.20, 0.25, 0.35, 1.0})

	norm_curr := _get_current_dir()
	parts := strings.split(norm_curr, "/", context.temp_allocator)
	accum_path := ""

	for part, idx in parts {
		if idx > 0 {
			im.SameLine(0, 2)
			im.TextDisabled("/")
			im.SameLine(0, 2)
			accum_path = strings.concatenate({accum_path, "/", part}, context.temp_allocator)
		} else {
			accum_path = part
		}

		disp_label := part
		if part == "." {
			disp_label = "Engine Core"
		} else if part == ".." {
			disp_label = "Workspace Root"
		}

		btn_id := fmt.ctprintf("%s##Crumb_%d", disp_label, idx)
		if im.Button(btn_id) {
			_navigate_to(accum_path)
		}
		if im.BeginPopupContextItem(fmt.ctprintf("##CrumbCtx_%d", idx)) {
			if im.MenuItem(fmt.ctprintf("%s  Open Folder", icons.ICON_MD_FOLDER_OPEN)) {
				_navigate_to(accum_path)
			}
			if im.MenuItem(fmt.ctprintf("%s  Show in %s", icons.ICON_MD_FOLDER_OPEN, file_exp.get_os_explorer_name())) {
				file_exp.reveal_in_os(accum_path)
			}
			if im.MenuItem(fmt.ctprintf("%s  Copy Path", icons.ICON_MD_LINK)) {
				im.SetClipboardText(strings.clone_to_cstring(accum_path, context.temp_allocator))
			}
			im.EndPopup()
		}
		_accept_folder_drop_target(accum_path)
	}
	im.PopStyleColor(2)

	// 3. Right-Aligned Workspace Actions: [+ Add / Create], [Preview], [Open in OS], [Dock]
	p := thm.palette()
	st := im.GetStyle()
	btn_sz := im.GetFrameHeight()
	add_btn_lbl := fmt.ctprintf("%s  Add / Create  %s", icons.ICON_MD_ADD, icons.ICON_MD_EXPAND_MORE)
	prev_btn_lbl := fmt.ctprintf("%s Preview", icons.ICON_MD_VISIBILITY)
	add_btn_w := im.CalcTextSize(add_btn_lbl).x + st.FramePadding.x * 2.0
	prev_btn_w := im.CalcTextSize(prev_btn_lbl).x + st.FramePadding.x * 2.0
	right_row1_w := add_btn_w + 6.0 + prev_btn_w + 6.0 + btn_sz + 6.0 + btn_sz

	im.SameLine(0, 12)
	avail_x := im.GetContentRegionAvail().x
	if avail_x > right_row1_w + 4.0 {
		im.SetCursorPosX(im.GetCursorPosX() + avail_x - right_row1_w)
	}

	// [+ Add / Create] Menu Button (clean Antigravity primary tonal pill)
	im.PushStyleColorImVec4(.Button, p.accent_soft)
	im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.accent, 0.26))
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.accent, 0.55))
	im.PushStyleVar(.FrameBorderSize, 1.0)
	if im.Button(add_btn_lbl) {
		im.OpenPopup("##ToolbarAddMenu", {})
	}
	im.PopStyleVar()
	im.PopStyleColor(3)

	if im.BeginPopup("##ToolbarAddMenu") {
		if im.MenuItem(fmt.ctprintf("%s  New Folder...", icons.ICON_MD_FOLDER)) {
			mem.zero(&_new_folder_buf, len(_new_folder_buf))
			copy_str := "New_Folder"
			mem.copy(&_new_folder_buf[0], raw_data(copy_str), len(copy_str))
			_show_new_folder = true
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  New Level / Scene (.scene)...", icons.ICON_MD_PLAY_CIRCLE)) {
			mem.zero(&_new_scene_buf, len(_new_scene_buf))
			copy_str := "New_Level.scene"
			mem.copy(&_new_scene_buf[0], raw_data(copy_str), len(copy_str))
			_new_scene_template = 0
			_show_new_scene = true
		}
		if im.MenuItem(fmt.ctprintf("%s  New Odin Script (.odin)...", icons.ICON_MD_CODE)) {
			mem.zero(&_new_script_buf, len(_new_script_buf))
			copy_str := "new_script.odin"
			mem.copy(&_new_script_buf[0], raw_data(copy_str), len(copy_str))
			_new_script_template = 0
			_show_new_script = true
		}
		if im.MenuItem(fmt.ctprintf("%s  New Material (.mat)", icons.ICON_MD_PALETTE)) {
			_create_new_material_in_dir(_get_current_dir())
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Open in Windows Explorer", icons.ICON_MD_FOLDER_OPEN)) {
			file_exp.reveal_in_os(_get_current_dir())
		}
		im.EndPopup()
	}

	// Toggle Right-Side Live Asset Preview Inspector Pane
	im.SameLine(0, 6)
	if _show_inspector_pane {
		im.PushStyleColorImVec4(.Button, p.accent_soft)
		im.PushStyleColorImVec4(.Text, p.is_light ? p.accent : p.text_primary)
	} else {
		im.PushStyleColorImVec4(.Button, p.bg_elevated)
		im.PushStyleColorImVec4(.Text, p.text_secondary)
	}
	if im.Button(prev_btn_lbl) {
		_show_inspector_pane = !_show_inspector_pane
	}
	im.PopStyleColor(2)
	widgets.tooltip("Toggle Live Asset Preview & Metadata Inspector Pane")

	// Reveal in OS button
	im.SameLine(0, 6)
	if widgets.icon_button(icons.ICON_MD_FOLDER_OPEN, "##ExplorerOpenOS", "Show Current Folder in Windows Explorer", size = btn_sz) {
		file_exp.reveal_in_os(_get_current_dir())
	}

	// Dock Toggle button (Float out / Dock back in)
	im.SameLine(0, 6)
	is_docked := im.IsWindowDocked()
	dock_icon: cstring = is_docked ? icons.ICON_MD_OPEN_IN_NEW : icons.ICON_MD_DOCK
	if widgets.icon_button(dock_icon, "##ExplorerDockToggle", is_docked ? "Dock Out as Floating Window" : "Dock Window Back into Workspace", size = btn_sz) {
		wnd.toggle_window_dock("void_file_explorer")
	}

	// Row 2: Search + Scope + Sort (Left)  |  View Mode + Zoom Bar (Right)
	im.Spacing()
	zoom_strip_w := btn_sz * 4.0 + 132.0 + 58.0 + 31.0
	avail_row2 := im.GetContentRegionAvail().x
	search_w := clamp(avail_row2 - zoom_strip_w - 190.0, 140.0, 260.0)
	_ = widgets.search_bar(_search_buf[:], widgets.Search_Bar_Opts{
		id            = "##ExplorerSearch",
		hint          = "Search files & folders...",
		mode          = .Toolbar,
		width         = search_w,
		clear_tooltip = "Clear Search",
	})

	// Search Scope Toggle (Active Folder + Subfolders [Default] | Active Folder Flat | Entire Project)
	im.SameLine(0, 6)
	switch _search_scope {
	case .Active_Folder_Recursive:
		im.PushStyleColorImVec4(.Text, p.status_warning)
		if im.SmallButton(fmt.ctprintf("%s Folder+", icons.ICON_MD_FOLDER)) {
			_search_scope = .Active_Folder_Flat
		}
		im.PopStyleColor()
		widgets.tooltip("Search Scope: Active Folder + Subfolders (Fast, Multi-Core)\nLeft-Click to cycle: Folder+ -> Here -> Project\nRight-Click to select scope")
	case .Active_Folder_Flat:
		im.PushStyleColorImVec4(.Text, p.status_success)
		if im.SmallButton(fmt.ctprintf("%s Here", icons.ICON_MD_FOLDER_OPEN)) {
			_search_scope = .All_Project
		}
		im.PopStyleColor()
		widgets.tooltip("Search Scope: Active Folder Only (No Subfolders)\nLeft-Click to cycle: Folder+ -> Here -> Project\nRight-Click to select scope")
	case .All_Project:
		im.PushStyleColorImVec4(.Text, p.accent)
		if im.SmallButton(fmt.ctprintf("%s Project", icons.ICON_MD_SEARCH)) {
			_search_scope = .Active_Folder_Recursive
		}
		im.PopStyleColor()
		widgets.tooltip("Search Scope: Entire Project (Excludes library/builds)\nLeft-Click to cycle: Folder+ -> Here -> Project\nRight-Click to select scope")
	}
	if im.BeginPopupContextItem("##SearchScopePopup") {
		if im.MenuItem("Active Folder + Subfolders (Default)", nil, _search_scope == .Active_Folder_Recursive) {
			_search_scope = .Active_Folder_Recursive
		}
		if im.MenuItem("Active Folder Only (Flat)", nil, _search_scope == .Active_Folder_Flat) {
			_search_scope = .Active_Folder_Flat
		}
		if im.MenuItem("Entire Project", nil, _search_scope == .All_Project) {
			_search_scope = .All_Project
		}
		im.EndPopup()
	}

	// Sort Mode Selector Button & Popup
	im.SameLine(0, 6)
	sort_label: cstring = "A-Z"
	switch _sort_mode {
	case .Name_Asc:      sort_label = "Name A-Z"
	case .Name_Desc:     sort_label = "Name Z-A"
	case .Date_Newest:   sort_label = "Newest"
	case .Date_Oldest:   sort_label = "Oldest"
	case .Size_Largest:  sort_label = "Largest"
	case .Size_Smallest: sort_label = "Smallest"
	case .Type_Asc:      sort_label = "Type"
	}
	if im.SmallButton(fmt.ctprintf("Sort: %s %s##SortBtn", sort_label, icons.ICON_MD_EXPAND_MORE)) {
		im.OpenPopup("##ExplorerSortMenu", {})
	}
	widgets.tooltip("Sort Files & Folders (Folders always stay grouped at top)")
	if im.BeginPopup("##ExplorerSortMenu") {
		Sort_Option :: struct {
			mode:  file_exp.Sort_Mode,
			label: cstring,
		}
		sort_opts := [7]Sort_Option{
			{.Name_Asc,      "Name (A -> Z)"},
			{.Name_Desc,     "Name (Z -> A)"},
			{.Date_Newest,   "Date Modified (Newest First)"},
			{.Date_Oldest,   "Date Modified (Oldest First)"},
			{.Size_Largest,  "File Size (Largest First)"},
			{.Size_Smallest, "File Size (Smallest First)"},
			{.Type_Asc,      "Asset Type / Extension"},
		}
		for opt in sort_opts {
			if im.MenuItem(opt.label, nil, _sort_mode == opt.mode) {
				_sort_mode = opt.mode
				file_exp.sort_file_items(_items[:], _sort_mode)
			}
		}
		im.EndPopup()
	}

	// Studio View Mode & Zoom Control Bar (right-aligned when space permits; wraps cleanly otherwise)
	if im.GetContentRegionAvail().x >= zoom_strip_w + 16.0 {
		im.SameLine(0, 12)
		im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - zoom_strip_w)
	} else {
		im.Spacing()
	}
	_draw_view_and_zoom_controls(btn_sz)

	// Category Filter Chips Bar (Clean Antigravity Tonal Pills)
	im.Spacing()
	Category_Chip :: struct {
		filter: Explorer_Category_Filter,
		label:  cstring,
		col:    [4]f32,
	}
	chips := [8]Category_Chip{
		{.All,       "All",       {0.48, 0.66, 0.97, 1.0}},
		{.Folders,   "Folders",   {0.94, 0.74, 0.28, 1.0}},
		{.Meshes,    "3D Meshes", {0.30, 0.78, 0.56, 1.0}},
		{.Textures,  "Textures",  {0.92, 0.48, 0.66, 1.0}},
		{.Materials, "Materials", {0.94, 0.60, 0.26, 1.0}},
		{.Audio,     "Audio",     {0.28, 0.80, 0.74, 1.0}},
		{.Scenes,    "Levels",    {0.72, 0.52, 0.98, 1.0}},
		{.Scripts,   "Scripts",   {0.42, 0.70, 0.98, 1.0}},
	}
	for chip, ci in chips {
		if ci > 0 do im.SameLine(0, 5)
		is_active := _category_filter == chip.filter
		chip_fg := thm.adapt_badge_color(chip.col)
		if is_active {
			im.PushStyleColorImVec4(.Button, thm.with_alpha(chip_fg, p.is_light ? 0.14 : 0.20))
			im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(chip_fg, p.is_light ? 0.22 : 0.28))
			im.PushStyleColorImVec4(.Border, thm.with_alpha(chip_fg, 0.65))
			im.PushStyleColorImVec4(.Text, chip_fg)
			im.PushStyleVar(.FrameBorderSize, 1.0)
		} else {
			im.PushStyleColorImVec4(.Button, p.bg_elevated)
			im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
			im.PushStyleColorImVec4(.Border, p.border_subtle)
			im.PushStyleColorImVec4(.Text, p.text_secondary)
			im.PushStyleVar(.FrameBorderSize, 1.0)
		}
		if im.SmallButton(chip.label) {
			if _category_filter == chip.filter && chip.filter != .All {
				_category_filter = .All
			} else {
				_category_filter = chip.filter
			}
		}
		im.PopStyleVar()
		im.PopStyleColor(4)
	}

	im.Separator()
}

// ─────────────────────────────────────────────────────────────
// LEFT PANE: QUICK ACCESS BOOKMARKS & DIRECTORY TREE
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_left_pane :: proc() {
	p := thm.palette()
	// ── 1. QUICK ACCESS HEADER & ITEMS ──
	im.TextColored(p.text_muted, "Quick Access")
	im.Separator()

	current_dir := _get_current_dir()
	bookmarks := file_exp.get_bookmarks()
	avail_w := im.GetContentRegionAvail().x
	btn_w: f32 = 22.0

	for bm, idx in bookmarks {
		im.PushIDInt(i32(idx))
		bm_clean, _ := filepath.clean(bm.path, context.temp_allocator)
		bm_norm, _ := strings.replace_all(bm_clean, "\\", "/", context.temp_allocator)
		is_active := current_dir == bm_norm || (current_dir == "." && (bm_norm == "." || bm_norm == file_exp.get_workspace_root()))

		folder_key := filepath.base(bm_norm)
		if folder_key == "." || folder_key == ".." || folder_key == "" do folder_key = "Root"
		fcol, has_fcol := editor_visuals.get_folder_color(folder_key)
		row_col := has_fcol ? thm.adapt_badge_color(fcol) : (is_active ? p.text_primary : p.text_secondary)

		// Selectable row with label
		label_w := max(40.0, avail_w - btn_w - 6.0)
		im.PushStyleColorImVec4(.Text, row_col)
		selected := im.Selectable(fmt.ctprintf("%s  %s##BmSelect", bm.icon, bm.label), is_active, {}, im.Vec2{label_w, 0})
		im.PopStyleColor()

		// Accept drag-and-drop onto Quick Access bookmarks to move files/folders
		_accept_folder_drop_target(bm_norm)

		// DIRECT LEFT-CLICK on the bookmark navigates immediately!
		if selected || im.IsItemClicked(.Left) {
			_navigate_to(bm.path)
		}

		// Right-click on the row opens context menu
		if im.BeginPopupContextItem("##BmFolderCtx") {
			_draw_folder_dropdown_menu(bm.path, bm.label)
			im.EndPopup()
		}

		// Quiet Ghost Menu Button ("...") — invisible background at rest, clean tonal hover
		im.SameLine(0, 4)
		im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
		im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
		im.PushStyleColorImVec4(.Text, p.text_muted)
		if im.SmallButton(fmt.ctprintf("%s##BmMenuBtn", icons.ICON_MD_MORE_HORIZ)) {
			im.OpenPopup("##BmFolderMenu")
		}
		im.PopStyleColor(3)
		widgets.tooltip("Folder Options & Colors (Left-Click)")

		if im.BeginPopup("##BmFolderMenu") {
			_draw_folder_dropdown_menu(bm.path, bm.label)
			im.EndPopup()
		}

		im.PopID()
	}

	im.Spacing()
	im.Spacing()

	// ── 2. FOLDER DIRECTORY TREE ──
	im.TextColored(p.text_muted, "Project Directory")
	im.Separator()

	_draw_folder_tree_node(file_exp.get_workspace_root(), "Workspace Root", depth = 0)
	if _tree_reveal_frames > 0 do _tree_reveal_frames -= 1
	if _tree_scroll_frames > 0 do _tree_scroll_frames -= 1
}

@(private = "file")
_is_path_ancestor :: proc(ancestor: string, descendant: string) -> bool {
	if ancestor == descendant || len(ancestor) == 0 || len(descendant) == 0 do return false

	ws := file_exp.get_workspace_root()
	clean_ws, _ := filepath.clean(ws, context.temp_allocator)
	norm_ws, _ := strings.replace_all(clean_ws, "\\", "/", context.temp_allocator)

	if ancestor == norm_ws || ancestor == "." {
		return descendant != norm_ws && descendant != "."
	}

	prefix := fmt.tprintf("%s/", ancestor)
	return strings.has_prefix(descendant, prefix)
}

@(private = "file")
_draw_folder_tree_node :: proc(dir_path: string, label: string, depth: int) {
	if depth > 12 do return // Safety recursion limit

	clean_dir, _ := filepath.clean(dir_path, context.temp_allocator)
	norm_dir, _ := strings.replace_all(clean_dir, "\\", "/", context.temp_allocator)
	curr_dir := _get_current_dir()
	is_selected := curr_dir == norm_dir
	is_ancestor := _is_path_ancestor(norm_dir, curr_dir)

	q := _get_search_query()
	has_query := len(q) > 0

	matches_self := false
	has_child_match := false
	if has_query {
		matches_self, has_child_match = _folder_has_search_match(norm_dir)
		// Only prune/auto-open the full workspace tree when searching Entire Project;
		// when searching the Active Folder, keep the tree stable and only auto-open within the active folder!
		if _search_scope == .All_Project {
			if depth > 0 && !matches_self && !has_child_match {
				return
			}
			if has_child_match {
				im.SetNextItemOpen(true, .Always)
			}
		} else if (is_selected || _is_path_ancestor(curr_dir, norm_dir)) && has_child_match {
			im.SetNextItemOpen(true, .Always)
		}
	} else if _tree_reveal_frames > 0 {
		if is_ancestor {
			im.SetNextItemOpen(true)
		}
	}

	flags := im.TreeNodeFlags{.OpenOnArrow, .OpenOnDoubleClick, .SpanAvailWidth}
	if depth == 0 {
		flags += {.DefaultOpen}
	}
	if is_selected {
		flags += {.Selected}
	}

	// Folder color styling: custom folder colors stay distinct; untagged folders use clean theme typography
	p := thm.palette()
	folder_key := filepath.base(norm_dir)
	if folder_key == "." || folder_key == ".." || folder_key == "" do folder_key = "Root"
	fcol, has_fcol := editor_visuals.get_folder_color(folder_key)
	tree_col := has_fcol ? thm.adapt_badge_color(fcol) : (is_selected ? p.text_primary : p.text_secondary)

	im.PushID(strings.clone_to_cstring(norm_dir, context.temp_allocator))

	node_label := fmt.ctprintf("%s  %s##Node", icons.ICON_MD_FOLDER, label)
	if has_query && matches_self {
		im.PushStyleColorImVec4(.Text, p.status_warning)
	} else {
		im.PushStyleColorImVec4(.Text, tree_col)
	}
	node_open := im.TreeNodeEx(node_label, flags)
	im.PopStyleColor()

	// Accept drag-and-drop onto any Folder Tree node to move files/folders
	_accept_folder_drop_target(norm_dir)

	if is_selected && _tree_scroll_frames > 0 {
		im.SetScrollHereY(0.5)
	}

	if im.IsItemClicked(.Left) && !im.IsItemToggledOpen() {
		_navigate_to(norm_dir, push_history = true, scroll_tree = false, reveal_tree = false)
	}

	// Right-click context menu on tree item
	if im.BeginPopupContextItem("##TreeNodeCtx") {
		_draw_folder_dropdown_menu(norm_dir, label)
		im.EndPopup()
	}

	// Quiet Ghost Menu Button ("...")
	im.SameLine(0, 0)
	avail_tree_x := im.GetContentRegionAvail().x
	if avail_tree_x > 26.0 {
		im.SetCursorPosX(im.GetCursorPosX() + avail_tree_x - 22.0)
	}
	im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
	im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
	im.PushStyleColorImVec4(.Text, p.text_muted)
	if im.SmallButton(fmt.ctprintf("%s##TreeMenuBtn", icons.ICON_MD_MORE_HORIZ)) {
		im.OpenPopup("##TreeFolderMenu")
	}
	im.PopStyleColor(3)
	widgets.tooltip("Folder Options & Colors (Left-Click)")

	if im.BeginPopup("##TreeFolderMenu") {
		_draw_folder_dropdown_menu(norm_dir, label)
		im.EndPopup()
	}

	if node_open {
		for sub in _get_tree_subdirs(norm_dir) {
			_draw_folder_tree_node(sub.norm_path, sub.name, depth + 1)
		}
		im.TreePop()
	}

	im.PopID()
}

// ─────────────────────────────────────────────────────────────
// RIGHT PANE: CONTENT BROWSER (GRID & LIST MODES)
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_right_pane :: proc() {
	if _needs_refresh {
		_refresh_items()
	}

	query := _get_search_query()
	has_query := len(query) > 0

	raw_items: []file_exp.File_Item
	if has_query {
		raw_items = _search_results[:]
	} else {
		raw_items = _items[:]
	}

	// Apply Category Filter Chip
	visible_items: []file_exp.File_Item
	if _category_filter == .All {
		visible_items = raw_items
	} else {
		filtered := make([dynamic]file_exp.File_Item, 0, len(raw_items), context.temp_allocator)
		for it in raw_items {
			if _item_matches_category_filter(it, _category_filter) {
				append(&filtered, it)
			}
		}
		visible_items = filtered[:]
	}

	if len(visible_items) == 0 {
		im.Spacing()
		if has_query {
			scope_str := "Active Folder (+Subfolders)"
			if _search_scope == .Active_Folder_Flat {
				scope_str = "Active Folder (Flat)"
			} else if _search_scope == .All_Project {
				scope_str = "Entire Project"
			}
			im.TextDisabledUnformatted(fmt.ctprintf("No items match your search filter \"%s\" in %s.", query, scope_str))
			im.TextDisabled("Try searching without special characters, or click the scope button above to switch to Project.")
		} else if _category_filter != .All {
			im.TextDisabled("No items in this folder match the active Category Filter.")
			if im.SmallButton("Reset Filter to [All]") {
				_category_filter = .All
			}
		} else {
			im.TextDisabled("This folder is empty.")
			im.TextDisabled("Right-click here or click [+ Add / Create] above to add a new level, script, or folder.")
		}
	} else if _is_grid_mode() {
		_draw_grid_view(visible_items)
	} else {
		_draw_list_view(visible_items)
	}

	// Context menu for empty space in content view
	if im.BeginPopupContextWindow("##ExplorerEmptyCtx", im.PopupFlags_NoOpenOverItems) {
		os_exp_name := file_exp.get_os_explorer_name()
		if _has_selection {
			if im.MenuItem(fmt.ctprintf("%s  Show Selected \"%s\" in %s", icons.ICON_MD_FOLDER_OPEN, _get_selected_name(), os_exp_name)) {
				file_exp.reveal_in_os(_get_selected_path())
			}
		}
		if im.MenuItem(fmt.ctprintf("%s  Show Current Folder in %s", icons.ICON_MD_FOLDER_OPEN, os_exp_name)) {
			file_exp.reveal_in_os(_get_current_dir())
		}
		im.Separator()
		has_clip := _clipboard_has_item || (im.GetClipboardText() != nil && os.exists(string(im.GetClipboardText())))
		if im.MenuItem(fmt.ctprintf("%s  Paste", icons.ICON_MD_CONTENT_PASTE), "Ctrl+V", false, has_clip) {
			_paste_from_clipboard()
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  New Folder...", icons.ICON_MD_FOLDER)) {
			mem.zero(&_new_folder_buf, len(_new_folder_buf))
			copy_str := "New_Folder"
			mem.copy(&_new_folder_buf[0], raw_data(copy_str), len(copy_str))
			_show_new_folder = true
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  New Level / Scene (.scene)...", icons.ICON_MD_PLAY_CIRCLE)) {
			mem.zero(&_new_scene_buf, len(_new_scene_buf))
			copy_str := "New_Level.scene"
			mem.copy(&_new_scene_buf[0], raw_data(copy_str), len(copy_str))
			_new_scene_template = 0
			_show_new_scene = true
		}
		if im.MenuItem(fmt.ctprintf("%s  New Odin Script (.odin)...", icons.ICON_MD_CODE)) {
			mem.zero(&_new_script_buf, len(_new_script_buf))
			copy_str := "new_script.odin"
			mem.copy(&_new_script_buf[0], raw_data(copy_str), len(copy_str))
			_new_script_template = 0
			_show_new_script = true
		}
		if im.MenuItem(fmt.ctprintf("%s  New Material (.mat)", icons.ICON_MD_PALETTE)) {
			_create_new_material_in_dir(_get_current_dir())
		}
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Refresh", icons.ICON_MD_REFRESH)) {
			_clear_preview_cache()
			_needs_refresh = true
		}
		im.EndPopup()
	}
}

@(private = "file")
_open_scene_in_editor :: proc(path: string) {
	clean_p, _ := filepath.clean(path, context.temp_allocator)
	norm_p, _ := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)

	if !wnd.request_open_scene(norm_p) {
		engine.asset_db_request_refresh()
		undo.purge_scenes(undo.get())
		if scene := engine.scene_load_single_path(norm_p); scene != nil {
			engine.sm_scene_set_active(scene)
		}
	}
}

@(private = "file")
_open_file_item :: proc(path: string) {
	clean_p, _ := filepath.clean(path, context.temp_allocator)
	norm_p, _ := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)

	ext := strings.to_lower(filepath.ext(norm_p), context.temp_allocator)

	// 1. Scene files (.scene) -> Open in MoonHug Editor
	if ext == ".scene" {
		_open_scene_in_editor(norm_p)
		return
	}

	// 2. Odin source scripts (.odin) -> Open in IDE; Unified Blueprint scripts (.bodin / .mhgraph) -> Unified Graph Studio
	if ext == ".bodin" || ext == ".mhgraph" {
		vs.open_blueprint_in_studio(norm_p)
		return
	}
	if ext == ".odin" {
		file_exp.open_script_in_ide(norm_p)
		return
	}

	// 3. Material files (.mat) -> Open directly in standalone Material Shader Graph (`void_material_editor`)
	if ext == ".mat" {
		_show_inspector_pane = true
		_connect_material_editor_to_mat(norm_p)
		wnd.open("void_material_editor")
		return
	}

	// 4. Faker CSG Prefab (.fmesh) -> Open Inspector Preview & Spawn in Scene3D!
	if ext == ".fmesh" {
		_show_inspector_pane = true
		if new_h := cad_csg.csg_spawn_faker_mesh_from_binary({0, 1.5, 0}, norm_p); new_h != {} {
			engine.inspector_request_select(new_h)
		}
		return
	}

	// 5. Audio clips (.wav / .ogg / .mp3 / .flac) -> Audition in Preview Pane!
	if ext == ".wav" || ext == ".ogg" || ext == ".mp3" || ext == ".flac" {
		_show_inspector_pane = true
		engine.asset_db_request_refresh()
		if guid, ok := _lookup_asset_guid_any_path(norm_p); ok {
			ag := engine.Asset_GUID(guid)
			if audio.preview_playing(ag) {
				audio.preview_stop()
			} else {
				_ = audio.preview_play(ag)
			}
		}
		return
	}

	// 6. Fallback: System OS default handler
	file_exp.open_in_os(norm_p)
}

// ─────────────────────────────────────────────────────────────
// LIVE ASSET PREVIEW BUILDER & RENDERER (UE5 CONTENT BROWSER STYLE)
// ─────────────────────────────────────────────────────────────

@(private = "file")
_normalize_preview_tris :: proc(tris: ^[dynamic]Preview_Tri, bmin, bmax: [3]f32) -> [3]f32 {
	if len(tris) == 0 do return {1, 1, 1}
	center := (bmin + bmax) * 0.5
	ext := (bmax - bmin) * 0.5
	max_ext := max(ext.x, max(ext.y, ext.z))
	if max_ext < 1e-5 do max_ext = 1.0
	inv_ext := 1.0 / max_ext
	for &t in tris {
		t.v0 = (t.v0 - center) * inv_ext
		t.v1 = (t.v1 - center) * inv_ext
		t.v2 = (t.v2 - center) * inv_ext
		e1 := t.v1 - t.v0
		e2 := t.v2 - t.v0
		n := [3]f32{
			e1.y * e2.z - e1.z * e2.y,
			e1.z * e2.x - e1.x * e2.z,
			e1.x * e2.y - e1.y * e2.x,
		}
		n_len := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
		if n_len > 1e-6 {
			t.normal = n / n_len
		} else {
			t.normal = {0, 1, 0}
		}
	}
	return ext * 2.0
}

@(private = "file")
_append_preview_box :: proc(tris: ^[dynamic]Preview_Tri, bmin, bmax: [3]f32) {
	p000 := [3]f32{bmin.x, bmin.y, bmin.z}
	p100 := [3]f32{bmax.x, bmin.y, bmin.z}
	p110 := [3]f32{bmax.x, bmax.y, bmin.z}
	p010 := [3]f32{bmin.x, bmax.y, bmin.z}
	p001 := [3]f32{bmin.x, bmin.y, bmax.z}
	p101 := [3]f32{bmax.x, bmin.y, bmax.z}
	p111 := [3]f32{bmax.x, bmax.y, bmax.z}
	p011 := [3]f32{bmin.x, bmax.y, bmax.z}
	// Front (+Z)
	append(tris, Preview_Tri{v0 = p001, v1 = p101, v2 = p111}, Preview_Tri{v0 = p001, v1 = p111, v2 = p011})
	// Back (-Z)
	append(tris, Preview_Tri{v0 = p100, v1 = p000, v2 = p010}, Preview_Tri{v0 = p100, v1 = p010, v2 = p110})
	// Right (+X)
	append(tris, Preview_Tri{v0 = p101, v1 = p100, v2 = p110}, Preview_Tri{v0 = p101, v1 = p110, v2 = p111})
	// Left (-X)
	append(tris, Preview_Tri{v0 = p000, v1 = p001, v2 = p011}, Preview_Tri{v0 = p000, v1 = p011, v2 = p010})
	// Top (+Y)
	append(tris, Preview_Tri{v0 = p011, v1 = p111, v2 = p110}, Preview_Tri{v0 = p011, v1 = p110, v2 = p010})
	// Bottom (-Y)
	append(tris, Preview_Tri{v0 = p000, v1 = p100, v2 = p101}, Preview_Tri{v0 = p000, v1 = p101, v2 = p001})
}

@(private = "file")
_build_procedural_fallback_mesh_preview :: proc(entry: ^Asset_Preview_Entry, item: file_exp.File_Item) {
	is_humanoid := strings.contains(item.name_lower, "rig") ||
	               strings.contains(item.name_lower, "ferra") ||
	               strings.contains(item.name_lower, "human") ||
	               strings.contains(item.name_lower, "char") ||
	               strings.contains(item.name_lower, "mannequin")
	if is_humanoid {
		// 3D Articulated Character / Skeletal Mesh Silhouette on Turntable
		entry.mesh_tris = make([dynamic]Preview_Tri, 0, 96)
		// Head
		_append_preview_box(&entry.mesh_tris, {-0.14,  0.60, -0.14}, { 0.14,  0.90, 0.14})
		// Upper Torso / Chest
		_append_preview_box(&entry.mesh_tris, {-0.26,  0.14, -0.15}, { 0.26,  0.56, 0.15})
		// Pelvis / Hips
		_append_preview_box(&entry.mesh_tris, {-0.22, -0.10, -0.14}, { 0.22,  0.12, 0.14})
		// Left & Right Arms (A-Pose)
		_append_preview_box(&entry.mesh_tris, {-0.62,  0.22, -0.09}, {-0.28,  0.52, 0.09})
		_append_preview_box(&entry.mesh_tris, { 0.28,  0.22, -0.09}, { 0.62,  0.52, 0.09})
		// Left & Right Legs
		_append_preview_box(&entry.mesh_tris, {-0.21, -0.90, -0.11}, {-0.05, -0.12, 0.11})
		_append_preview_box(&entry.mesh_tris, { 0.05, -0.90, -0.11}, { 0.21, -0.12, 0.11})
		entry.mesh_bounds_ext = _normalize_preview_tris(&entry.mesh_tris, {-0.65, -0.92, -0.20}, {0.65, 0.92, 0.20})
		if entry.vert_count == 0 do entry.vert_count = 56
		if entry.tri_count == 0  do entry.tri_count  = len(entry.mesh_tris)
		return
	}

	// Clean crystal/octahedron + pedestal 3D mesh preview if mesh isn't indexed in AssetDB yet
	entry.mesh_tris = make([dynamic]Preview_Tri, 0, 28)
	top := [3]f32{0, 0.92, 0}
	bot := [3]f32{0, -0.72, 0}
	ring := [4][3]f32{
		{0.72, 0.10, 0},
		{0, 0.10, 0.72},
		{-0.72, 0.10, 0},
		{0, 0.10, -0.72},
	}
	for i in 0 ..< 4 {
		next := (i + 1) % 4
		append(&entry.mesh_tris, Preview_Tri{v0 = top, v1 = ring[i], v2 = ring[next]})
		append(&entry.mesh_tris, Preview_Tri{v0 = bot, v1 = ring[next], v2 = ring[i]})
	}
	_append_preview_box(&entry.mesh_tris, {-0.55, -0.92, -0.55}, {0.55, -0.74, 0.55})
	entry.mesh_bounds_ext = _normalize_preview_tris(&entry.mesh_tris, {-0.75, -0.92, -0.75}, {0.75, 0.92, 0.75})
	if entry.vert_count == 0 do entry.vert_count = 14
	if entry.tri_count == 0 do entry.tri_count = len(entry.mesh_tris)
}

@(private = "file")
_get_or_build_asset_preview :: proc(item: file_exp.File_Item, force_load: bool = false) -> ^Asset_Preview_Entry {
	if existing, ok := &_preview_cache[item.path]; ok {
		return existing
	}

	// Frame-budgeted preview loading: cap uncached disk loads per frame so scrolling or
	// searching hundreds of assets never stalls the UI thread!
	if !force_load && _previews_loaded_this_frame >= MAX_PREVIEW_LOADS_PER_FRAME {
		return nil
	}
	_previews_loaded_this_frame += 1

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	entry: Asset_Preview_Entry
	entry.loaded = true
	ext := item.extension

	if item.is_dir {
		entry.kind = .Folder
		if h, err := os.open(item.path); err == nil {
			defer os.close(h)
			if subs, rerr := os.read_dir(h, -1, context.temp_allocator); rerr == nil {
				defer os.file_info_slice_delete(subs, context.temp_allocator)
				count := 0
				for s in subs {
					if !strings.has_prefix(s.name, ".") && !strings.has_suffix(s.name, ".meta") {
						count += 1
					}
				}
				entry.folder_child_count = count
			}
		}
	} else if ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tga" {
		entry.kind = .Texture
		// 1. Try engine asset_db + texture_load first
		if guid, ok := engine.asset_db_get_guid(item.path); ok {
			if tex, tok := engine.texture_load(engine.Asset_GUID(guid)); tok && tex != nil && tex.gfx != nil && tex.gfx.gpu != nil {
				entry.tex_imgui_id = im.TextureID(uintptr(gfx.texture_imgui_id(tex.gfx)))
				entry.tex_valid = true
				entry.img_w = int(tex.gfx.width)
				entry.img_h = int(tex.gfx.height)
			}
		}
		// 2. Fallback: load directly via stbi + engine.texture_upsert_procedural if not in asset_db yet
		if !entry.tex_valid && os.exists(item.path) {
			c_path := strings.clone_to_cstring(item.path, context.temp_allocator)
			w_i, h_i, ch: i32
			pixels := stbi.load(c_path, &w_i, &h_i, &ch, 4)
			if pixels != nil {
				defer stbi.image_free(pixels)
				entry.img_w = int(w_i)
				entry.img_h = int(h_i)
				byte_len := int(w_i) * int(h_i) * 4
				if byte_len > 0 {
					h_hash := hash.fnv64a(transmute([]u8)item.path)
					raw_id: [16]u8
					raw_id[0] = 0x50; raw_id[1] = 0x52; raw_id[2] = 0x56; raw_id[3] = 0x54
					_ = endian.put_u64(raw_id[8:16], .Little, h_hash)
					prv_guid := engine.Asset_GUID(raw_id)
					engine.texture_upsert_procedural(prv_guid, ([^]u8)(pixels)[:byte_len], w_i, h_i)
					if tex_p, tok_p := engine.texture_load(prv_guid); tok_p && tex_p != nil && tex_p.gfx != nil && tex_p.gfx.gpu != nil {
						entry.tex_imgui_id = im.TextureID(uintptr(gfx.texture_imgui_id(tex_p.gfx)))
						entry.tex_valid = true
					}
				}
			}
		}
	} else if ext == ".glb" || ext == ".gltf" || ext == ".obj" || ext == ".fmesh" || ext == ".fbx" || ext == ".dae" {
		entry.kind = .Mesh_3D
		bmin := [3]f32{1e9, 1e9, 1e9}
		bmax := [3]f32{-1e9, -1e9, -1e9}
		if (ext == ".glb" || ext == ".gltf" || ext == ".fmesh" || ext == ".fbx" || ext == ".dae") {
			target_mesh_guid: engine.Asset_GUID = {}
			if ext == ".fmesh" {
				if arch, aok := cad_csg.csg_read_faker_binary_header(item.path); aok && !engine.asset_guid_is_empty(arch.mesh_guid) {
					target_mesh_guid = arch.mesh_guid
				}
			} else if guid, ok := _lookup_asset_guid_any_path(item.path); ok {
				target_mesh_guid = engine.Asset_GUID(guid)
			}
			// For .fbx / .dae files, also check if a converted sibling .glb / .gltf exists in the same folder
			if (ext == ".fbx" || ext == ".dae") && engine.asset_guid_is_empty(target_mesh_guid) {
				stem := strings.trim_suffix(item.path, item.extension)
				sibling_glb := fmt.tprintf("%s.glb", stem)
				sibling_gltf := fmt.tprintf("%s.gltf", stem)
				if guid, ok := _lookup_asset_guid_any_path(sibling_glb); ok {
					target_mesh_guid = engine.Asset_GUID(guid)
				} else if guid2, ok2 := _lookup_asset_guid_any_path(sibling_gltf); ok2 {
					target_mesh_guid = engine.Asset_GUID(guid2)
				}
			}
			if !engine.asset_guid_is_empty(target_mesh_guid) {
				mf := engine.MeshFilter{mesh = engine.PPtr{guid = target_mesh_guid}}
				if verts, indices, mok := engine.mesh_read_cpu_geometry(&mf, context.temp_allocator); mok && len(verts) > 0 && len(indices) >= 3 {
					entry.vert_count = len(verts)
					total_tris := len(indices) / 3
					entry.tri_count = total_tris
					max_preview_tris := 200
					step := max(1, total_tris / max_preview_tris)
					entry.mesh_tris = make([dynamic]Preview_Tri, 0, min(total_tris, max_preview_tris + 1))
					for v in verts {
						p := v.position
						bmin = {min(bmin.x, p.x), min(bmin.y, p.y), min(bmin.z, p.z)}
						bmax = {max(bmax.x, p.x), max(bmax.y, p.y), max(bmax.z, p.z)}
					}
					for ti := 0; ti < total_tris; ti += step {
						i0 := indices[ti * 3 + 0]
						i1 := indices[ti * 3 + 1]
						i2 := indices[ti * 3 + 2]
						if int(i0) < len(verts) && int(i1) < len(verts) && int(i2) < len(verts) {
							append(&entry.mesh_tris, Preview_Tri{
								v0 = verts[i0].position,
								v1 = verts[i1].position,
								v2 = verts[i2].position,
							})
						}
					}
					entry.mesh_bounds_ext = _normalize_preview_tris(&entry.mesh_tris, bmin, bmax)
				}
			}
		} else if ext == ".obj" {
			if data, rerr := os.read_entire_file(item.path, context.temp_allocator); rerr == nil {
				positions := make([dynamic][3]f32, 0, 256, context.temp_allocator)
				raw_tris := make([dynamic][3]int, 0, 256, context.temp_allocator)
				lines := strings.split_lines(string(data), context.temp_allocator)
				for line in lines {
					trimmed := strings.trim_space(line)
					if strings.has_prefix(trimmed, "v ") {
						parts := strings.fields(trimmed, context.temp_allocator)
						if len(parts) >= 4 {
							vx, _ := strconv.parse_f32(parts[1])
							vy, _ := strconv.parse_f32(parts[2])
							vz, _ := strconv.parse_f32(parts[3])
							p := [3]f32{vx, vy, vz}
							append(&positions, p)
							bmin = {min(bmin.x, p.x), min(bmin.y, p.y), min(bmin.z, p.z)}
							bmax = {max(bmax.x, p.x), max(bmax.y, p.y), max(bmax.z, p.z)}
						}
					} else if strings.has_prefix(trimmed, "f ") {
						parts := strings.fields(trimmed, context.temp_allocator)
						if len(parts) >= 4 {
							face_idx := make([dynamic]int, 0, len(parts) - 1, context.temp_allocator)
							for fi in 1 ..< len(parts) {
								tok := parts[fi]
								slash := strings.index_byte(tok, '/')
								if slash > 0 do tok = tok[:slash]
								if vi, vok := strconv.parse_int(tok); vok && vi > 0 {
									append(&face_idx, vi - 1)
								}
							}
							for k := 1; k + 1 < len(face_idx); k += 1 {
								append(&raw_tris, [3]int{face_idx[0], face_idx[k], face_idx[k + 1]})
							}
						}
					}
				}
				entry.vert_count = len(positions)
				entry.tri_count = len(raw_tris)
				if len(raw_tris) > 0 {
					max_preview_tris := 200
					step := max(1, len(raw_tris) / max_preview_tris)
					entry.mesh_tris = make([dynamic]Preview_Tri, 0, min(len(raw_tris), max_preview_tris + 1))
					for ti := 0; ti < len(raw_tris); ti += step {
						f := raw_tris[ti]
						if f[0] < len(positions) && f[1] < len(positions) && f[2] < len(positions) {
							append(&entry.mesh_tris, Preview_Tri{
								v0 = positions[f[0]],
								v1 = positions[f[1]],
								v2 = positions[f[2]],
							})
						}
					}
					entry.mesh_bounds_ext = _normalize_preview_tris(&entry.mesh_tris, bmin, bmax)
				}
			}
		}
		if len(entry.mesh_tris) == 0 {
			_build_procedural_fallback_mesh_preview(&entry, item)
		}
	} else if ext == ".mat" {
		entry.kind = .Material
		entry.mat_color = {0.78, 0.48, 0.22, 1.0}
		loaded_from_engine := false
		if m_id, m_ok := _lookup_asset_guid_any_path(item.path); m_ok {
			if mat_obj, l_ok := engine.material_load(engine.Asset_GUID(m_id)); l_ok && mat_obj != nil {
				loaded_from_engine = true
				entry.mat_color  = mat_obj.color
				entry.mat_shader = strings.clone("Lit" if mat_obj.shader == .Lit else "Unlit")
				if !engine.asset_guid_is_empty(mat_obj.texture) {
					if tp, pok := engine.asset_db_get_path(uuid.Identifier(mat_obj.texture)); pok && len(tp) > 0 {
						entry.mat_tex_name = strings.clone(filepath.base(tp))
					} else {
						entry.mat_tex_name = strings.clone("Texture")
					}
					if tex, tok := engine.texture_load(mat_obj.texture); tok && tex != nil && tex.gfx != nil && tex.gfx.gpu != nil {
						entry.mat_has_tex = true
						entry.mat_tex_id  = im.TextureID(uintptr(gfx.texture_imgui_id(tex.gfx)))
					}
				}
			}
		}
		if !loaded_from_engine {
			if data, rerr := os.read_entire_file(item.path, context.temp_allocator); rerr == nil {
				Mat_Parse_Fallback :: struct {
					shader: int,
					color:  [4]f32,
				}
				parsed := Mat_Parse_Fallback{shader = 1, color = {0.82, 0.82, 0.86, 1.0}}
				if jerr := json.unmarshal(data, &parsed, allocator = context.temp_allocator); jerr == nil {
					if parsed.color[3] > 0 || parsed.color[0] > 0 || parsed.color[1] > 0 || parsed.color[2] > 0 {
						entry.mat_color = parsed.color
					}
					entry.mat_shader = strings.clone("Lit" if parsed.shader != 0 else "Unlit")
				}
			}
		}
	} else if ext == ".wav" || ext == ".ogg" || ext == ".mp3" || ext == ".flac" {
		entry.kind = .Audio
		decoded := false
		// Decode audio waveform directly for clips <= 4 MB so preview is instantaneous
		if item.size_bytes > 0 && item.size_bytes <= 4 * 1024 * 1024 {
			if pcm, spec, ok := audio.decode_file_f32(item.path, context.temp_allocator); ok && len(pcm) > 0 {
				decoded = true
				ch := max(1, int(spec.channels))
				rate := max(1, int(spec.freq))
				frames := len(pcm) / ch
				entry.audio_sample_rate  = rate
				entry.audio_channels     = ch
				entry.audio_duration_sec = f32(frames) / f32(rate)
				peak_all: f32 = 0.001
				for i in 0 ..< 32 {
					s_idx := (i * len(pcm)) / 32
					e_idx := ((i + 1) * len(pcm)) / 32
					step := max(1, (e_idx - s_idx) / 64)
					local_peak: f32 = 0.0
					for k := s_idx; k < e_idx; k += step {
						v := abs(pcm[k])
						if v > local_peak do local_peak = v
					}
					entry.audio_waveform[i] = local_peak
					if local_peak > peak_all do peak_all = local_peak
				}
				for i in 0 ..< 32 {
					entry.audio_waveform[i] = clamp(entry.audio_waveform[i] / peak_all, 0.08, 1.0)
				}
			}
		}
		if !decoded {
			// Lightweight envelope fallback for streaming / large music tracks
			entry.audio_sample_rate  = 44100
			entry.audio_channels     = 2
			entry.audio_duration_sec = max(0.5, f32(item.size_bytes) / (44100.0 * 4.0))
			seed := hash.fnv32a(transmute([]u8)item.name)
			for i in 0 ..< 32 {
				seed = seed * 1664525 + 1013904223
				env := math.sin(f32(i) / 31.0 * math.PI)
				rnd := f32((seed >> 8) & 0xFF) / 255.0
				entry.audio_waveform[i] = clamp(0.18 + env * (0.35 + rnd * 0.47), 0.12, 0.98)
			}
		}
	} else if ext == ".scene" {
		entry.kind = .Scene
		if data, rerr := os.read_entire_file(item.path, context.temp_allocator); rerr == nil {
			entry.scene_obj_count = max(1, strings.count(string(data), "\"components\""))
		}
	} else if ext == ".odin" || ext == ".json" || ext == ".glsl" || ext == ".vert" || ext == ".frag" || ext == ".md" || ext == ".txt" {
		entry.kind = .Code
		if data, rerr := os.read_entire_file(item.path, context.temp_allocator); rerr == nil {
			lines := strings.split_lines(string(data), context.temp_allocator)
			entry.code_lines = make([dynamic]string, 0, 14)
			for line in lines {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 do continue
				if len(trimmed) > 46 {
					trimmed = widgets.utf8_safe_prefix(trimmed, 46)
				}
				append(&entry.code_lines, strings.clone(trimmed))
				if len(entry.code_lines) >= 14 do break
			}
		}
	}

	key := strings.clone(item.path)
	_preview_cache[key] = entry
	return &_preview_cache[key]
}

@(private = "file")
_draw_preview_badge :: proc(dl: ^im.DrawList, p_max: im.Vec2, label: string, col: im.Vec4) {
	if len(label) == 0 do return
	cstr := strings.clone_to_cstring(label, context.temp_allocator)
	ts := im.CalcTextSize(cstr)
	pad_x: f32 = 4.5
	pad_y: f32 = 2.0
	b_max := im.Vec2{p_max.x - 4.0, p_max.y - 4.0}
	b_min := im.Vec2{b_max.x - ts.x - pad_x * 2.0, b_max.y - ts.y - pad_y * 2.0}
	im.DrawList_AddRectFilled(dl, b_min, b_max, im.ColorConvertFloat4ToU32({0.05, 0.06, 0.09, 0.88}), 3.5)
	im.DrawList_AddRect(dl, b_min, b_max, im.ColorConvertFloat4ToU32({col.x, col.y, col.z, 0.55}), 3.5, 1.0)
	im.DrawList_AddText(dl, {b_min.x + pad_x, b_min.y + pad_y}, im.ColorConvertFloat4ToU32({0.92, 0.95, 1.0, 0.95}), cstr)
}

@(private = "file")
_draw_card_live_preview :: proc(
	dl: ^im.DrawList,
	item: file_exp.File_Item,
	p_min, p_max: im.Vec2,
	icon_col: im.Vec4,
	is_hovered: bool,
	is_selected: bool,
	custom_yaw: f32 = 0.65,
	custom_pitch: f32 = 0.38,
	use_custom_angles: bool = false,
	force_load: bool = false,
) {
	w := p_max.x - p_min.x
	h := p_max.y - p_min.y
	if w < 16.0 || h < 16.0 do return

	entry := _get_or_build_asset_preview(item, force_load || use_custom_angles)
	im.PushClipRect(p_min, p_max, true)
	defer im.PopClipRect()

	// Clean Antigravity thumbnail well backdrop (adapts seamlessly to dark & light studio themes)
	p := thm.palette()
	well_top := p.is_light ? p.bg_canvas : p.bg_recessed
	well_bot := p.is_light ? thm.lerp_col(p.bg_canvas, p.border_subtle, 0.35) : p.bg_canvas
	if is_selected {
		well_top = thm.lerp_col(well_top, p.accent, 0.10)
		well_bot = thm.lerp_col(well_bot, p.accent, 0.06)
	} else if is_hovered {
		well_top = thm.lerp_col(well_top, p.bg_hover, 0.45)
	}
	top_bg := im.GetColorU32ImVec4(well_top)
	bot_bg := im.GetColorU32ImVec4(well_bot)
	im.DrawList_AddRectFilledMultiColor(dl, p_min, p_max, top_bg, top_bg, bot_bg, bot_bg)

	cx := (p_min.x + p_max.x) * 0.5
	cy := (p_min.y + p_max.y) * 0.5
	rad := min(w, h) * 0.40

	kind := Asset_Preview_Kind.None
	if entry != nil {
		kind = entry.kind
	}

	#partial switch kind {
	case .Folder:
		// Unreal Engine 5 style layered 3D folder graphic with custom color & document sheet peek
		fw := min(w * 0.64, h * 0.78)
		fh := fw * 0.72
		rnd := clamp(fw * 0.08, 2.5, 8.0)
		tab_rnd := clamp(rnd * 0.8, 2.0, 6.0)
		fx0 := cx - fw * 0.5
		fy0 := cy - fh * 0.44
		fx1 := cx + fw * 0.5
		fy1 := cy + fh * 0.52

		dark_col := im.ColorConvertFloat4ToU32({icon_col.x * 0.58, icon_col.y * 0.58, icon_col.z * 0.58, 1.0})
		main_col := im.ColorConvertFloat4ToU32({icon_col.x, icon_col.y, icon_col.z, 1.0})
		rim_col  := im.ColorConvertFloat4ToU32({min(1.0, icon_col.x * 1.25), min(1.0, icon_col.y * 1.25), min(1.0, icon_col.z * 1.25), 0.95})

		// Soft drop shadow
		im.DrawList_AddRectFilled(dl, {fx0 + 2, fy0 + 5}, {fx1 + 3, fy1 + 3}, im.ColorConvertFloat4ToU32({0, 0, 0, 0.42}), rnd)
		// Folder back tab + back plate
		im.DrawList_AddRectFilled(dl, {fx0, fy0 - fh * 0.14}, {fx0 + fw * 0.44, fy0 + 6}, dark_col, tab_rnd)
		im.DrawList_AddRectFilled(dl, {fx0, fy0}, {fx1, fy1}, dark_col, rnd)
		// White inner asset paper sheet peeking out if folder has items
		if entry.folder_child_count > 0 {
			im.DrawList_AddRectFilled(dl, {fx0 + fw * 0.12, fy0 + fh * 0.06}, {fx1 - fw * 0.10, fy0 + fh * 0.45}, im.ColorConvertFloat4ToU32({0.92, 0.95, 1.0, 0.88}), clamp(rnd * 0.5, 1.5, 4.0))
		}
		// Front beveled folder flap
		flap_top := fy0 + fh * 0.22
		im.DrawList_AddRectFilled(dl, {fx0, flap_top}, {fx1, fy1}, main_col, rnd)
		im.DrawList_AddLine(dl, {fx0 + 3, flap_top + 1}, {fx1 - 3, flap_top + 1}, rim_col, 1.5)
		if w >= 120.0 {
			item_lbl := "item" if entry.folder_child_count == 1 else "items"
			_draw_preview_badge(dl, p_max, fmt.tprintf("%d %s", entry.folder_child_count, item_lbl), icon_col)
		} else if w >= 82.0 {
			_draw_preview_badge(dl, p_max, fmt.tprintf("%d", entry.folder_child_count), icon_col)
		}

	case .Texture:
		if entry.tex_valid {
			// Alpha checkerboard backdrop
			chk_size: f32 = 8.0
			c_light := im.ColorConvertFloat4ToU32({0.20, 0.22, 0.26, 1.0})
			c_dark  := im.ColorConvertFloat4ToU32({0.13, 0.14, 0.18, 1.0})
			pad: f32 = w < 68.0 ? 2.5 : 5.0
			avail_tw := max(8.0, w - pad * 2.0)
			avail_th := max(8.0, h - pad * 2.0)
			aspect := f32(entry.img_w) / f32(max(1, entry.img_h))
			draw_w := avail_tw
			draw_h := avail_tw / max(0.05, aspect)
			if draw_h > avail_th {
				draw_h = avail_th
				draw_w = avail_th * aspect
			}
			ix0 := cx - draw_w * 0.5
			iy0 := cy - draw_h * 0.5
			ix1 := cx + draw_w * 0.5
			iy1 := cy + draw_h * 0.5
			cols_chk := int(draw_w / chk_size) + 1
			rows_chk := int(draw_h / chk_size) + 1
			for ry in 0 ..< rows_chk {
				for rx in 0 ..< cols_chk {
					x0 := ix0 + f32(rx) * chk_size
					y0 := iy0 + f32(ry) * chk_size
					x1 := min(ix1, x0 + chk_size)
					y1 := min(iy1, y0 + chk_size)
					if x1 > x0 && y1 > y0 {
						col_c := c_light if (rx + ry) % 2 == 0 else c_dark
						im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col_c)
					}
				}
			}
			im.DrawList_AddImageRounded(dl, im.TextureRef{_TexID = entry.tex_imgui_id}, {ix0, iy0}, {ix1, iy1}, {0, 0}, {1, 1}, im.ColorConvertFloat4ToU32({1, 1, 1, 1}), 3.0)
			im.DrawList_AddRect(dl, {ix0, iy0}, {ix1, iy1}, im.ColorConvertFloat4ToU32({1, 1, 1, 0.18}), 3.0, 1.0)
			if w >= 84.0 && entry.img_w > 0 {
				_draw_preview_badge(dl, p_max, fmt.tprintf("%dx%d", entry.img_w, entry.img_h), icon_col)
			}
		}

	case .Mesh_3D:
		// 3D Isometric / Turntable Mesh Preview with floor grid + shaded & wireframe triangles
		yaw: f32 = custom_yaw
		pitch: f32 = custom_pitch
		if !use_custom_angles {
			yaw = f32(im.GetTime()) * 1.25 if is_hovered else 0.68
			pitch = 0.38
		}
		cy_a := math.cos(yaw)
		sy_a := math.sin(yaw)
		cp_a := math.cos(pitch)
		sp_a := math.sin(pitch)

		project_pt :: proc(p: [3]f32, cy_a, sy_a, cp_a, sp_a, cx, cy, scale: f32) -> (im.Vec2, f32) {
			rx := p.x * cy_a + p.z * sy_a
			rz := -p.x * sy_a + p.z * cy_a
			ry := p.y * cp_a - rz * sp_a
			fz := p.y * sp_a + rz * cp_a
			return im.Vec2{cx + rx * scale, cy - ry * scale}, fz
		}

		// Subtle 3D ground grid on Y = -0.85
		grid_col := im.ColorConvertFloat4ToU32({0.25, 0.35, 0.45, 0.28})
		for gi in -2 ..= 2 {
			gf := f32(gi) * 0.48
			g0, _ := project_pt({gf, -0.85, -0.96}, cy_a, sy_a, cp_a, sp_a, cx, cy + 4.0, rad)
			g1, _ := project_pt({gf, -0.85,  0.96}, cy_a, sy_a, cp_a, sp_a, cx, cy + 4.0, rad)
			h0, _ := project_pt({-0.96, -0.85, gf}, cy_a, sy_a, cp_a, sp_a, cx, cy + 4.0, rad)
			h1, _ := project_pt({ 0.96, -0.85, gf}, cy_a, sy_a, cp_a, sp_a, cx, cy + 4.0, rad)
			im.DrawList_AddLine(dl, g0, g1, grid_col, 1.0)
			im.DrawList_AddLine(dl, h0, h1, grid_col, 1.0)
		}

		// Project & depth-sort triangles (painter's algorithm)
		Projected_Tri :: struct {
			p0, p1, p2: im.Vec2,
			z:          f32,
			lit:        f32,
		}
		proj := make([dynamic]Projected_Tri, 0, len(entry.mesh_tris), context.temp_allocator)
		for t in entry.mesh_tris {
			s0, z0 := project_pt(t.v0, cy_a, sy_a, cp_a, sp_a, cx, cy, rad)
			s1, z1 := project_pt(t.v1, cy_a, sy_a, cp_a, sp_a, cx, cy, rad)
			s2, z2 := project_pt(t.v2, cy_a, sy_a, cp_a, sp_a, cx, cy, rad)
			// Rotate normal for directional studio lighting
			nx := t.normal.x * cy_a + t.normal.z * sy_a
			nz := -t.normal.x * sy_a + t.normal.z * cy_a
			ny := t.normal.y * cp_a - nz * sp_a
			lit := clamp(0.38 + max(0.0, nx * 0.45 + ny * 0.65 - nz * 0.35) * 0.68, 0.22, 1.05)
			append(&proj, Projected_Tri{
				p0  = s0,
				p1  = s1,
				p2  = s2,
				z   = (z0 + z1 + z2) * 0.3333,
				lit = lit,
			})
		}
		slice.sort_by(proj[:], proc(a, b: Projected_Tri) -> bool {
			return a.z > b.z
		})

		wire_col := im.ColorConvertFloat4ToU32({icon_col.x, icon_col.y, icon_col.z, 0.42 if !is_hovered else 0.65})
		for pt in proj {
			fill_col := im.ColorConvertFloat4ToU32({
				clamp(icon_col.x * pt.lit, 0.08, 1.0),
				clamp(icon_col.y * pt.lit, 0.08, 1.0),
				clamp(icon_col.z * pt.lit, 0.08, 1.0),
				0.92,
			})
			im.DrawList_AddTriangleFilled(dl, pt.p0, pt.p1, pt.p2, fill_col)
			im.DrawList_AddLine(dl, pt.p0, pt.p1, wire_col, 1.0)
			im.DrawList_AddLine(dl, pt.p1, pt.p2, wire_col, 1.0)
		}
		if w >= 84.0 && entry.tri_count > 0 {
			_draw_preview_badge(dl, p_max, fmt.tprintf("%d tris", entry.tri_count), icon_col)
		}

	case .Material:
		// 3D Shaded Material Sphere + Specular Highlight + Texture Swatch
		s_rad := min(w, h) * 0.34
		im.DrawList_AddCircleFilled(dl, {cx + 2, cy + 4}, s_rad, im.ColorConvertFloat4ToU32({0, 0, 0, 0.50}), 28)
		mc := entry.mat_color
		for ring := 0; ring < 8; ring += 1 {
			t := f32(ring) / 7.0
			r_curr := s_rad * (1.0 - t * 0.72)
			ox := -s_rad * 0.26 * t
			oy := -s_rad * 0.26 * t
			shade := 0.35 + t * 0.85
			rc := im.ColorConvertFloat4ToU32({
				clamp(mc.x * shade, 0, 1),
				clamp(mc.y * shade, 0, 1),
				clamp(mc.z * shade, 0, 1),
				1.0,
			})
			im.DrawList_AddCircleFilled(dl, {cx + ox, cy + oy}, r_curr, rc, 28)
		}
		// Specular studio highlight
		im.DrawList_AddCircleFilled(dl, {cx - s_rad * 0.32, cy - s_rad * 0.32}, max(2.5, s_rad * 0.18), im.ColorConvertFloat4ToU32({1, 1, 1, 0.65}), 16)
		im.DrawList_AddCircle(dl, {cx, cy}, s_rad, im.ColorConvertFloat4ToU32({1, 1, 1, 0.22}), 28, 1.2)
		if entry.mat_has_tex {
			sw := min(w, h) * 0.30
			im.DrawList_AddImageRounded(dl, im.TextureRef{_TexID = entry.mat_tex_id}, {p_min.x + 5, p_max.y - sw - 5}, {p_min.x + 5 + sw, p_max.y - 5}, {0, 0}, {1, 1}, im.ColorConvertFloat4ToU32({1, 1, 1, 1}), 3.0)
			im.DrawList_AddRect(dl, {p_min.x + 5, p_max.y - sw - 5}, {p_min.x + 5 + sw, p_max.y - 5}, im.ColorConvertFloat4ToU32({1, 1, 1, 0.5}), 3.0, 1.0)
		}
		if w >= 84.0 {
			badge_txt := entry.mat_shader if len(entry.mat_shader) > 0 else "MAT"
			_draw_preview_badge(dl, p_max, badge_txt, icon_col)
		}

	case .Audio:
		// Studio 32-Bar Audio Waveform Visualizer
		pad_x: f32 = w < 68.0 ? 4.0 : 7.0
		avail_aw := max(16.0, w - pad_x * 2.0)
		max_amp_h := h * 0.38
		// Center zero-crossing reference line
		im.DrawList_AddLine(dl, {p_min.x + pad_x, cy}, {p_max.x - pad_x, cy}, im.ColorConvertFloat4ToU32({icon_col.x, icon_col.y, icon_col.z, 0.28}), 1.0)
		bar_step := avail_aw / 32.0
		bar_w := clamp(bar_step * 0.66, 1.2, 5.5)
		for bi in 0 ..< 32 {
			amp := clamp(entry.audio_waveform[bi], 0.06, 1.0)
			bh := max(2.0, amp * max_amp_h)
			bx := p_min.x + pad_x + f32(bi) * bar_step + (bar_step - bar_w) * 0.5
			bcol := im.ColorConvertFloat4ToU32({
				clamp(icon_col.x * (0.65 + amp * 0.45), 0.1, 1.0),
				clamp(icon_col.y * (0.65 + amp * 0.45), 0.1, 1.0),
				clamp(icon_col.z * (0.65 + amp * 0.45), 0.1, 1.0),
				0.92,
			})
			im.DrawList_AddRectFilled(dl, {bx, cy - bh}, {bx + bar_w, cy + bh}, bcol, 1.2)
		}
		if w >= 84.0 && entry.audio_duration_sec > 0 {
			_draw_preview_badge(dl, p_max, fmt.tprintf("%.1fs", entry.audio_duration_sec), icon_col)
		}

	case .Scene:
		// 3D Isometric Level Viewport Diorama Preview
		horizon_y := p_min.y + h * 0.44
		im.DrawList_AddRectFilledMultiColor(
			dl,
			p_min,
			{p_max.x, horizon_y},
			im.ColorConvertFloat4ToU32({0.14, 0.10, 0.24, 1.0}),
			im.ColorConvertFloat4ToU32({0.18, 0.12, 0.30, 1.0}),
			im.ColorConvertFloat4ToU32({0.28, 0.18, 0.42, 1.0}),
			im.ColorConvertFloat4ToU32({0.28, 0.18, 0.42, 1.0}),
		)
		// Sun disc
		im.DrawList_AddCircleFilled(dl, {p_max.x - w * 0.24, p_min.y + h * 0.22}, min(w, h) * 0.09, im.ColorConvertFloat4ToU32({1.0, 0.82, 0.45, 0.85}), 16)
		// Perspective floor grid lines
		grid_c := im.ColorConvertFloat4ToU32({0.65, 0.40, 0.95, 0.32})
		for gi in -3 ..= 3 {
			gx_top := cx + f32(gi) * (w * 0.06)
			gx_bot := cx + f32(gi) * (w * 0.22)
			im.DrawList_AddLine(dl, {gx_top, horizon_y}, {gx_bot, p_max.y}, grid_c, 1.0)
		}
		im.DrawList_AddLine(dl, {p_min.x, horizon_y}, {p_max.x, horizon_y}, im.ColorConvertFloat4ToU32({0.80, 0.50, 1.0, 0.55}), 1.2)
		// 3D level block silhouettes
		im.DrawList_AddRectFilled(dl, {cx - w * 0.26, horizon_y - h * 0.12}, {cx - w * 0.06, horizon_y + h * 0.16}, im.ColorConvertFloat4ToU32({0.55, 0.35, 0.80, 0.90}), 2.0)
		im.DrawList_AddRectFilled(dl, {cx + w * 0.02, horizon_y - h * 0.22}, {cx + w * 0.24, horizon_y + h * 0.12}, im.ColorConvertFloat4ToU32({0.75, 0.48, 0.98, 0.95}), 2.0)
		if w >= 84.0 {
			_draw_preview_badge(dl, p_max, fmt.tprintf("%d objs", entry.scene_obj_count), icon_col)
		}

	case .Code:
		// Mini Code Editor Preview with Gutter & Syntax Colored Bars/Text
		gutter_w: f32 = clamp(w * 0.08, 10.0, 18.0)
		im.DrawList_AddRectFilled(dl, p_min, {p_min.x + gutter_w, p_max.y}, im.ColorConvertFloat4ToU32({0.05, 0.06, 0.08, 0.95}))
		show_real_text := w >= 152.0
		mini_px := clamp(w * 0.055, 9.5, 11.5)
		row_step := (mini_px + 2.5) if show_real_text else clamp(h * 0.095, 7.5, 11.0)
		max_lines := min(len(entry.code_lines), max(3, int((h - 8.0) / row_step)))
		font := im.GetFont()
		for li in 0 ..< max_lines {
			ly := p_min.y + 5.0 + f32(li) * row_step
			if ly + 4.0 > p_max.y do break
			line_str := entry.code_lines[li]
			// Gutter line dot
			dot_y0 := ly + (row_step * 0.32 if show_real_text else 2.5)
			im.DrawList_AddRectFilled(dl, {p_min.x + gutter_w * 0.30, dot_y0}, {p_min.x + gutter_w * 0.70, dot_y0 + 2.5}, im.ColorConvertFloat4ToU32({0.35, 0.42, 0.52, 0.6}))
			// Syntax color heuristic
			line_col := im.Vec4{0.78, 0.84, 0.92, 0.90}
			if strings.has_prefix(line_str, "//") || strings.has_prefix(line_str, "#") {
				line_col = {0.42, 0.72, 0.45, 0.85}
			} else if strings.has_prefix(line_str, "package ") || strings.has_prefix(line_str, "import ") {
				line_col = {0.95, 0.62, 0.32, 0.95}
			} else if strings.contains(line_str, ":: proc") || strings.contains(line_str, ":: struct") {
				line_col = {0.38, 0.78, 1.0, 0.95}
			}
			if show_real_text {
				line_cstr := strings.clone_to_cstring(line_str, context.temp_allocator)
				im.DrawList_AddTextImFontPtr(dl, font, mini_px, {p_min.x + gutter_w + 5.0, ly}, im.ColorConvertFloat4ToU32(line_col), line_cstr)
			} else {
				bar_h := clamp(row_step * 0.46, 3.0, 5.0)
				bar_w := clamp(f32(len(line_str)) * 2.2, 10.0, w - gutter_w - 10.0)
				im.DrawList_AddRectFilled(dl, {p_min.x + gutter_w + 5.0, ly + 1.5}, {p_min.x + gutter_w + 5.0 + bar_w, ly + 1.5 + bar_h}, im.ColorConvertFloat4ToU32(line_col), 2.0)
			}
		}

	case:
		// Crisp centered icon with subtle glow ring
		im.DrawList_AddCircleFilled(dl, {cx, cy}, rad * 0.78, im.ColorConvertFloat4ToU32({icon_col.x, icon_col.y, icon_col.z, 0.12}), 24)
		icon_u32 := im.ColorConvertFloat4ToU32(icon_col)
		font := im.GetFont()
		icon_font_size := max(18.0, min(w, h) * 0.46)
		icon_str := strings.clone_to_cstring(item.icon_code, context.temp_allocator)
		icon_size := im.Font_CalcTextSizeA(font, icon_font_size, 999999.0, 0.0, icon_str)
		im.DrawList_AddTextImFontPtr(dl, font, icon_font_size, {cx - icon_size.x * 0.5, cy - icon_size.y * 0.5}, icon_u32, icon_str)
	}
}

// ─────────────────────────────────────────────────────────────
// GRID / CARD VIEW (UE5 CONTENT BROWSER STYLE — ZERO OVERLAP)
// ─────────────────────────────────────────────────────────────

@(private = "file")
_fit_card_name_to_px :: proc(name: string, ext: string, is_dir: bool, max_px: f32) -> cstring {
	full_cstr := strings.clone_to_cstring(name, context.temp_allocator)
	if im.CalcTextSize(full_cstr).x <= max_px {
		return full_cstr
	}
	total_runes := utf8.rune_count_in_string(name)
	avg_w := max(im.CalcTextSize("n").x * 0.88, 4.5)
	est_max := min(total_runes - 1, max(2, int(max_px / avg_w) + 5))
	for r := est_max; r >= 2; r -= 1 {
		cand := file_exp.format_middle_ellipsis(name, ext, is_dir, r, context.temp_allocator)
		cstr := strings.clone_to_cstring(cand, context.temp_allocator)
		if im.CalcTextSize(cstr).x <= max_px {
			return cstr
		}
	}
	short := file_exp.format_middle_ellipsis(name, ext, is_dir, 2, context.temp_allocator)
	return strings.clone_to_cstring(short, context.temp_allocator)
}

@(private = "file")
_draw_grid_view :: proc(items: []file_exp.File_Item) {
	avail_w := im.GetContentRegionAvail().x
	line_h := im.GetTextLineHeight()
	ui_s := max(im.GetFontSize() / 14.0, 0.6)

	base_sz := _current_card_size()
	card_w := math.round(base_sz * ui_s)
	is_compact := base_sz < 76.0
	thumb_h := math.round(card_w * (is_compact ? 0.84 : 0.80))
	footer_h := is_compact ? math.round(line_h + 10.0 * ui_s) : max(44.0 * ui_s, line_h * 2.25 + 12.0 * ui_s)
	card_h := thumb_h + footer_h
	spacing_x := clamp(math.round(base_sz * 0.095 * ui_s), math.round(6.0 * ui_s), math.round(13.0 * ui_s))
	spacing_y := spacing_x

	cols := max(1, int((avail_w + spacing_x) / (card_w + spacing_x)))
	dl := im.GetWindowDrawList()
	io := im.GetIO()

	any_card_hovered := false
	any_card_active  := false
	marquee_dragging := _marquee_active && im.IsMouseDown(.Left) && im.IsMouseDragging(.Left, 4.0)
	m_min := im.Vec2{min(_marquee_start.x, io.MousePos.x), min(_marquee_start.y, io.MousePos.y)}
	m_max := im.Vec2{max(_marquee_start.x, io.MousePos.x), max(_marquee_start.y, io.MousePos.y)}
	marquee_hits := make([dynamic]file_exp.File_Item, 0, 16, context.temp_allocator)

	im.PushStyleVarImVec2(.ItemSpacing, {spacing_x, spacing_y})
	defer im.PopStyleVar()

	for item, idx in items {
		im.PushIDInt(i32(idx))

		col_idx := idx % cols
		if col_idx > 0 {
			im.SameLine(0, spacing_x)
		}

		cursor_pos := im.GetCursorScreenPos()
		card_rect_max := im.Vec2{cursor_pos.x + card_w, cursor_pos.y + card_h}

		is_sel := _is_item_selected(item.path)
		btn_id := fmt.ctprintf("##CardBtn_%d", idx)

		// Invisible button covers card for interaction
		im.InvisibleButton(btn_id, {card_w, card_h})
		is_hovered := im.IsItemHovered()
		is_active  := im.IsItemActive()
		is_clicked := im.IsItemClicked(.Left)
		is_double_clicked := im.IsMouseDoubleClicked(.Left) && is_hovered

		if is_hovered do any_card_hovered = true
		if is_active  do any_card_active  = true

		if marquee_dragging {
			overlaps := card_rect_max.x >= m_min.x && cursor_pos.x <= m_max.x &&
			            card_rect_max.y >= m_min.y && cursor_pos.y <= m_max.y
			if overlaps {
				append(&marquee_hits, item)
			}
		}

		// Drag & Drop Source (Godot / UE5 style drag into Scene, Hierarchy, Inspector, or Folder)
		widgets.pin_active_drag_drop_tooltip()
		if im.BeginDragDropSource({}) {
			im.SetDragDropPayload("ASSET_PATH", raw_data(item.path), len(item.path))
			im.TextColoredUnformatted(item.badge_color, fmt.ctprintf("%s  %s", item.icon_code, item.name))
			if strings.has_suffix(item.name, ".odin") {
				im.TextDisabled("-> Drop into Scene, Inspector, or Folder to Move")
			} else if strings.has_suffix(item.name, ".scene") || strings.has_suffix(item.name, ".glb") || strings.has_suffix(item.name, ".gltf") || strings.has_suffix(item.name, ".obj") {
				im.TextDisabled("-> Drop into Scene, Hierarchy, Faker CSG Slot, or Folder")
			} else {
				im.TextDisabled("-> Drop onto any Folder, Breadcrumb, or Tree Node to Move")
			}
			im.EndDragDropSource()
		}

		// Folder cards accept Drag & Drop to move files/folders into them!
		if item.is_dir {
			_accept_folder_drop_target(item.path)
		}

		if is_clicked && !_marquee_active {
			if io.KeyCtrl {
				_toggle_selection(item)
			} else if io.KeyShift {
				_range_selection(item, items)
			} else {
				_set_selection(item)
			}
		}

		if _scroll_to_selected && is_sel {
			im.SetScrollHereY()
			_scroll_to_selected = false
		}

		if is_double_clicked {
			if item.is_dir {
				_navigate_to(item.path)
			} else {
				_open_file_item(item.path)
			}
		}

		// Right Click Context Menu
		if im.BeginPopupContextItem(fmt.ctprintf("##CardCtx_%d", idx)) {
			if !_is_item_selected(item.path) {
				_set_selection(item)
			}
			_draw_item_context_menu(item)
			im.EndPopup()
		}

		// Viewport Culling: skip all DrawList commands & uncached disk preview loads for off-screen cards!
		if !im.IsRectVisible(cursor_pos, card_rect_max) {
			im.PopID()
			continue
		}

		p := thm.palette()
		raw_icon_color := item.badge_color
		if item.is_dir {
			folder_key := filepath.base(item.path)
			fcol, has_fcol := editor_visuals.get_folder_color(folder_key)
			if has_fcol do raw_icon_color = fcol
		}
		icon_color := thm.adapt_badge_color(raw_icon_color)

		// 1. Soft Subtle Outer Drop Shadow
		im.DrawList_AddRectFilled(
			dl,
			{cursor_pos.x + 1.0, cursor_pos.y + 2.0},
			{card_rect_max.x + 1.5, card_rect_max.y + 2.5},
			im.GetColorU32ImVec4({0.0, 0.0, 0.0, p.is_light ? 0.08 : 0.26}),
			6.0,
		)

		// 2. Clean Antigravity Card Surface
		card_surf := p.is_light ? p.bg_recessed : p.bg_elevated
		if is_sel {
			card_surf = thm.lerp_col(card_surf, p.accent, p.is_light ? 0.10 : 0.15)
		} else if is_hovered {
			card_surf = p.bg_hover
		}
		im.DrawList_AddRectFilled(dl, cursor_pos, card_rect_max, im.GetColorU32ImVec4(card_surf), 6.0)

		// 3. Top Live Preview Viewport Box
		thumb_min := im.Vec2{cursor_pos.x + 2.0, cursor_pos.y + 2.0}
		thumb_max := im.Vec2{card_rect_max.x - 2.0, cursor_pos.y + thumb_h}
		_draw_card_live_preview(dl, item, thumb_min, thumb_max, icon_color, is_hovered, is_sel)

		// 4. Crisp 2px Category Accent Line separating Thumbnail and Footer
		accent_y := cursor_pos.y + thumb_h
		im.DrawList_AddRectFilled(
			dl,
			{cursor_pos.x + 1.0, accent_y},
			{card_rect_max.x - 1.0, accent_y + 2.0},
			im.GetColorU32ImVec4(thm.with_alpha(icon_color, (is_sel || is_hovered) ? 0.92 : 0.65)),
		)

		// 5. Clipped Footer Text + Type Pill Badge (Guaranteed Zero Overlap!)
		footer_clip_min := im.Vec2{cursor_pos.x + 4.0, accent_y + 4.0}
		footer_clip_max := im.Vec2{card_rect_max.x - 4.0, card_rect_max.y - 2.0}
		im.PushClipRect(footer_clip_min, footer_clip_max, true)

		// Row 1: Item Name (Pixel-accurate smart middle-ellipsis preserves extensions down to 48px tiles)
		pad_x: f32 = 4.0 if is_compact else 6.0
		max_text_w := max(16.0, card_w - pad_x * 2.0)
		name_cstr := _fit_card_name_to_px(item.name, item.extension, item.is_dir, max_text_w)
		name_y := accent_y + (4.5 if is_compact else 5.0)
		name_x := cursor_pos.x + pad_x
		if is_compact {
			name_w := im.CalcTextSize(name_cstr).x
			if name_w < max_text_w {
				name_x = cursor_pos.x + (card_w - name_w) * 0.5
			}
		}
		im.DrawList_AddText(dl, {name_x, name_y}, im.GetColorU32ImVec4(p.text_primary), name_cstr)

		if !is_compact {
			// Row 2: Clean Tonal Type Pill on Left + File Size on Right
			row2_y := name_y + line_h + 3.0
			tag_str := strings.to_upper(strings.trim_prefix(item.extension, "."), context.temp_allocator)
			if item.is_dir {
				tag_str = "FOLDER"
			} else if item.kind == .Model3D && len(tag_str) > 0 && len(tag_str) <= 4 {
				tag_str = fmt.tprintf("%s 3D", tag_str)
			} else if len(tag_str) == 0 {
				tag_str = "FILE"
			}
			tag_cstr := strings.clone_to_cstring(tag_str, context.temp_allocator)
			tag_sz := im.CalcTextSize(tag_cstr)
			pill_min := im.Vec2{cursor_pos.x + 5.0, row2_y}
			pill_max := im.Vec2{pill_min.x + tag_sz.x + 8.0, row2_y + line_h + 1.0}
			im.DrawList_AddRectFilled(
				dl,
				pill_min,
				pill_max,
				im.GetColorU32ImVec4(thm.with_alpha(icon_color, p.is_light ? 0.14 : 0.18)),
				3.5,
			)
			im.DrawList_AddText(
				dl,
				{pill_min.x + 4.0, row2_y + 0.5},
				im.GetColorU32ImVec4(icon_color),
				tag_cstr,
			)

			if !item.is_dir && card_w >= 88.0 * ui_s {
				sz_str := file_exp.format_file_size(item.size_bytes)
				sz_cstr := strings.clone_to_cstring(sz_str, context.temp_allocator)
				sz_w := im.CalcTextSize(sz_cstr).x
				sz_x := card_rect_max.x - sz_w - 6.0
				if sz_x > pill_max.x + 4.0 {
					im.DrawList_AddText(dl, {sz_x, row2_y + 0.5}, im.GetColorU32ImVec4(p.text_muted), sz_cstr)
				}
			}
		}

		im.PopClipRect()

		// 6. Clean Hairline Outer Border (crisp accent ring when selected)
		border_col := im.GetColorU32ImVec4(p.border_subtle)
		border_thick: f32 = 1.0
		if is_sel {
			border_col = im.GetColorU32ImVec4(p.accent)
			border_thick = 1.8
		} else if is_hovered {
			border_col = im.GetColorU32ImVec4(p.border_strong)
			border_thick = 1.2
		}
		im.DrawList_AddRect(dl, cursor_pos, card_rect_max, border_col, 6.0, border_thick)

		// Tooltip on Hover
		if is_hovered {
			size_str := file_exp.format_file_size(item.size_bytes)
			widgets.tooltip_unchecked(fmt.ctprintf("%s\nType: %s\nSize: %s\nPath: %s\nDouble-Click: Open\nRight-Click: Options", item.name, item.type_name, size_str, item.path))
		}

		im.PopID()
	}

	// Rubber-Band (Box / Marquee) Multi-Selection in Empty Grid Space
	if !any_card_hovered && !any_card_active && im.IsWindowHovered() && im.IsMouseClicked(.Left) {
		_marquee_active   = true
		_marquee_start    = io.MousePos
		_marquee_additive = io.KeyCtrl || io.KeyShift
		if !_marquee_additive {
			_clear_selection()
		}
	}
	if _marquee_active {
		if im.IsMouseDown(.Left) {
			if marquee_dragging {
				if !_marquee_additive {
					_clear_selection()
				}
				for hit, hi in marquee_hits {
					if hi == 0 && !_has_selection {
						_set_selection(hit)
					} else if !_is_item_selected(hit.path) {
						_selected_paths_append(hit.path)
						_has_selection = true
						_fe_selection_epoch += 1
					}
				}
				mp := thm.palette()
				im.DrawList_AddRectFilled(dl, m_min, m_max, im.GetColorU32ImVec4(thm.with_alpha(mp.accent, 0.14)), 4.0)
				im.DrawList_AddRect(dl, m_min, m_max, im.GetColorU32ImVec4(thm.with_alpha(mp.accent, 0.85)), 4.0, 1.2)
			}
		} else {
			_marquee_active = false
		}
	}
}

// ─────────────────────────────────────────────────────────────
// RIGHT-SIDE LIVE ASSET PREVIEW & METADATA INSPECTOR PANE
// ─────────────────────────────────────────────────────────────

@(private)
_find_selected_file_item :: proc() -> (file_exp.File_Item, bool) {
	if !_has_selection do return {}, false
	sel_path := _get_selected_path()
	for it in _items {
		if it.path == sel_path do return it, true
	}
	for it in _search_results {
		if it.path == sel_path do return it, true
	}
	return {}, false
}

@(private = "file")
_draw_asset_inspector_pane :: proc() {
	p := thm.palette()
	im.TextColoredUnformatted(p.text_muted, fmt.ctprintf("%s  Asset Preview", icons.ICON_MD_VISIBILITY))
	im.Separator()

	item, found := _find_selected_file_item()
	if !found {
		im.Spacing()
		im.TextDisabled("Select any file or folder to inspect its live 3D / Texture / Audio / Code preview and metadata.")
		return
	}

	icon_color := item.badge_color
	if item.is_dir {
		folder_key := filepath.base(item.path)
		if fcol, has_fcol := editor_visuals.get_folder_color(folder_key); has_fcol {
			icon_color = fcol
		}
	}

	avail_w := im.GetContentRegionAvail().x
	preview_sz := clamp(avail_w, 120.0, 220.0)
	pad_x := max(0.0, (avail_w - preview_sz) * 0.5)
	if pad_x > 0 do im.SetCursorPosX(im.GetCursorPosX() + pad_x)

	p_min := im.GetCursorScreenPos()
	p_max := im.Vec2{p_min.x + preview_sz, p_min.y + preview_sz}
	im.InvisibleButton("##InspectorPreviewCanvas", {preview_sz, preview_sz})
	is_canvas_active := im.IsItemActive()
	is_canvas_hovered := im.IsItemHovered()

	entry := _get_or_build_asset_preview(item, force_load = true)
	if entry == nil do return

	if entry.kind == .Mesh_3D {
		if is_canvas_active && im.IsMouseDragging(.Left) {
			delta := im.GetIO().MouseDelta
			_inspector_orbit_yaw += delta.x * 0.015
			_inspector_orbit_pitch = clamp(_inspector_orbit_pitch + delta.y * 0.012, -1.2, 1.2)
		} else if !is_canvas_hovered {
			_inspector_orbit_yaw = f32(im.GetTime()) * 0.75
		}
	}

	dl := im.GetWindowDrawList()
	_draw_card_live_preview(
		dl,
		item,
		p_min,
		p_max,
		icon_color,
		is_canvas_hovered,
		true,
		_inspector_orbit_yaw,
		_inspector_orbit_pitch,
		entry.kind == .Mesh_3D,
		force_load = true,
	)
	im.DrawList_AddRect(dl, p_min, p_max, im.ColorConvertFloat4ToU32({icon_color.x, icon_color.y, icon_color.z, 0.75}), 5.0, 1.5)

	if entry.kind == .Mesh_3D {
		im.TextDisabled("Drag preview above to orbit 3D mesh")
	}

	im.Spacing()
	im.TextColoredUnformatted(icon_color, fmt.ctprintf("%s  %s", item.icon_code, item.name))
	im.TextDisabledUnformatted(fmt.ctprintf("%s", item.type_name))
	im.Separator()

	// Asset-Specific Metadata Details
	if item.is_dir {
		im.TextUnformatted(fmt.ctprintf("Items: %d", entry.folder_child_count))
	} else {
		im.TextUnformatted(fmt.ctprintf("Size: %s", file_exp.format_file_size(item.size_bytes)))
	}
	if entry.kind == .Texture && entry.img_w > 0 {
		im.TextColoredUnformatted({0.95, 0.55, 0.75, 1.0}, fmt.ctprintf("Dimensions: %d x %d px", entry.img_w, entry.img_h))
	} else if entry.kind == .Audio {
		ch_str := "Stereo" if entry.audio_channels >= 2 else "Mono"
		im.TextColoredUnformatted({0.25, 0.92, 0.75, 1.0}, fmt.ctprintf("Duration: %.2f sec  |  %s", entry.audio_duration_sec, ch_str))
		if entry.audio_sample_rate > 0 {
			im.TextDisabledUnformatted(fmt.ctprintf("Sample Rate: %d Hz", entry.audio_sample_rate))
		}
		im.Spacing()
		engine.asset_db_request_refresh()
		if guid, gok := _lookup_asset_guid_any_path(item.path); gok {
			ag := engine.Asset_GUID(guid)
			is_playing := audio.preview_playing(ag)
			if is_playing {
				im.PushStyleColorImVec4(.Button, {0.75, 0.22, 0.25, 0.95})
				if im.Button(fmt.ctprintf("%s  Stop Audio Preview", icons.ICON_MD_CLOSE), {-1, 26}) {
					audio.preview_stop()
				}
				im.PopStyleColor()
			} else {
				im.PushStyleColorImVec4(.Button, {0.16, 0.58, 0.42, 0.95})
				if im.Button(fmt.ctprintf("%s  Play Audio Preview", icons.ICON_MD_PLAY_ARROW), {-1, 26}) {
					_ = audio.preview_play(ag)
				}
				im.PopStyleColor()
			}
		}
	} else if entry.kind == .Mesh_3D {
		im.TextColoredUnformatted({0.25, 0.92, 0.65, 1.0}, fmt.ctprintf("Geometry: %d verts | %d tris", entry.vert_count, entry.tri_count))
		im.TextDisabledUnformatted(fmt.ctprintf("Size: %.2f x %.2f x %.2f m", entry.mesh_bounds_ext.x, entry.mesh_bounds_ext.y, entry.mesh_bounds_ext.z))
		if item.extension == ".fmesh" {
			if arch, aok := cad_csg.csg_read_faker_binary_header(item.path); aok {
				im.SeparatorText("Faker CSG Prefab (.fmesh)")
				im.TextColoredUnformatted({0.45, 0.90, 1.0, 1.0}, fmt.ctprintf("CSG Hulls: %d  |  Margin: +%.3fm", arch.hull_count, arch.margin))
				fmesh_dirty := false
				preset_names := [8]cstring{
					"Concrete (Standard)",
					"Reinforced Concrete (High Resistance)",
					"Brick Masonry",
					"Wood Plank",
					"Steel Plate (Armored)",
					"Tempered Glass",
					"Brittle Rock",
					"Soft Metal Panel (Dentable)",
				}
				mp_idx := clamp(i32(arch.material_preset), 0, 7)
				im.TextDisabled("Material Preset:")
				im.SetNextItemWidth(-1)
				if im.ComboChar("##FmeshMatPreset", &mp_idx, raw_data(preset_names[:]), 8) {
					arch.material_preset = cad_csg.CSG_Material_Preset(mp_idx)
					fmesh_dirty = true
				}
				res_val := arch.blast_resistance if arch.blast_resistance > 0.05 else 1.0
				im.TextDisabled("Blast Resistance Multiplier:")
				im.SetNextItemWidth(-1)
				if im.SliderFloat("##FmeshBlastRes", &res_val, 0.10, 15.0, "%.2fx") {
					arch.blast_resistance = res_val
					fmesh_dirty = true
				}
				widgets.tooltip("1.0x = Default preset resistance; >1.0x = Harder to fracture / smaller craters; <1.0x = Brittle / larger craters")
				split_slice := arch.split_on_slice
				if im.Checkbox("Split into 2 Pieces on Slice", &split_slice) {
					arch.split_on_slice = split_slice
					fmesh_dirty = true
				}
				dyn_rb := arch.is_dynamic_rb
				if im.Checkbox("Dynamic Physics Rigidbody", &dyn_rb) {
					arch.is_dynamic_rb = dyn_rb
					fmesh_dirty = true
				}
				if fmesh_dirty {
					_ = cad_csg.csg_update_faker_binary_settings(
						item.path,
						arch.material_preset,
						arch.blast_resistance,
						arch.split_on_slice,
						arch.is_dynamic_rb,
					)
				}
				im.Spacing()
				im.PushStyleColorImVec4(.Button, {0.18, 0.58, 0.38, 0.96})
				if im.Button("Spawn .fmesh in Scene3D", {-1, 0}) {
					if new_h := cad_csg.csg_spawn_faker_mesh_from_binary({0, 1.5, 0}, item.path); new_h != {} {
						engine.inspector_request_select(new_h)
					}
				}
				im.PopStyleColor(1)
			}
		}
	} else if entry.kind == .Material {
		im.SeparatorText("Live Material (.mat) Editor")
		engine.asset_db_request_refresh()
		if m_id, m_ok := _lookup_asset_guid_any_path(item.path); m_ok {
			mat_guid := engine.Asset_GUID(m_id)
			if mat_ptr, l_ok := engine.material_load(mat_guid); l_ok && mat_ptr != nil {
				mat_val := mat_ptr^
				mat_changed := false

				shader_names := [2]cstring{"Unlit (Flat / Emissive)", "Lit (Multi-Light + Shadows)"}
				sh_idx := clamp(i32(mat_val.shader), 0, 1)
				im.SetNextItemWidth(-1)
				if im.ComboChar("##MatShader", &sh_idx, raw_data(shader_names[:]), 2) {
					mat_val.shader = engine.Material_Shader(sh_idx)
					mat_changed = true
				}
				widgets.tooltip("Selects the shader for this material (Lit vs Unlit)")

				im.TextDisabled("Base Albedo / Tint Color:")
				if im.ColorEdit4("##MatColorEdit", &mat_val.color) {
					mat_changed = true
				}

				im.TextDisabled("Base Texture (.png / .jpg):")
				tex_lbl: cstring = "None (Solid Color) - Drop Texture Here"
				if !engine.asset_guid_is_empty(mat_val.texture) {
					if tp, pok := engine.asset_db_get_path(uuid.Identifier(mat_val.texture)); pok && len(tp) > 0 {
						tex_lbl = strings.clone_to_cstring(filepath.base(tp), context.temp_allocator)
					} else {
						tex_lbl = "Assigned Texture"
					}
				}
				im.SetNextItemWidth(-1)
				if im.BeginCombo("##MatTexCombo", tex_lbl) {
					if im.Selectable("[None - Solid Color]", engine.asset_guid_is_empty(mat_val.texture)) {
						mat_val.texture = {}
						mat_changed = true
					}
					all_texs := _collect_all_project_textures(filepath.dir(item.path), context.temp_allocator)
					for rel_t in all_texs {
						if tid, tok := _lookup_asset_guid_any_path(rel_t); tok {
							tg := engine.Asset_GUID(tid)
							disp_lbl := fmt.ctprintf("%s  (%s)", filepath.base(rel_t), filepath.dir(rel_t))
							if im.Selectable(disp_lbl, mat_val.texture == tg) {
								mat_val.texture = tg
								mat_changed = true
							}
						}
					}
					im.EndCombo()
				}
				if im.BeginDragDropTarget() {
					if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
						dropped_p := strings.trim_right_null(string(([^]u8)(payload.Data)[:payload.DataSize]))
						lo_d := strings.to_lower(dropped_p, context.temp_allocator)
						if strings.has_suffix(lo_d, ".png") || strings.has_suffix(lo_d, ".jpg") || strings.has_suffix(lo_d, ".jpeg") || strings.has_suffix(lo_d, ".bmp") {
							engine.asset_db_request_refresh()
							_cached_best_tex_mat_len = 0
							if tid, tok := _lookup_asset_guid_any_path(dropped_p); tok {
								mat_val.texture = engine.Asset_GUID(tid)
								mat_changed = true
							}
						}
					}
					im.EndDragDropTarget()
				}

				if mat_changed {
					_save_and_preview_connected_material(item.path, mat_guid, mat_val, sync_graph = true)
					entry.mat_color = mat_val.color
					{
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						defer context.allocator = prev_alloc
						if len(entry.mat_shader) > 0 do delete(entry.mat_shader)
						entry.mat_shader = strings.clone("Lit" if mat_val.shader == .Lit else "Unlit")
					}
					entry.mat_has_tex = false
					if !engine.asset_guid_is_empty(mat_val.texture) {
						if tex, tok := engine.texture_load(mat_val.texture); tok && tex != nil && tex.gfx != nil && tex.gfx.gpu != nil {
							entry.mat_has_tex = true
							entry.mat_tex_id  = im.TextureID(uintptr(gfx.texture_imgui_id(tex.gfx)))
						}
					}
				}

				im.Spacing()
				if im.Button(fmt.ctprintf("%s  Open in Material Shader Graph", icons.ICON_MD_PALETTE), {-1, 24}) {
					_connect_material_editor_to_mat(item.path)
					wnd.open("void_material_editor")
				}
			}
		} else {
			if len(entry.mat_shader) > 0 do im.TextUnformatted(fmt.ctprintf("Shader: %s", entry.mat_shader))
			if len(entry.mat_tex_name) > 0 do im.TextUnformatted(fmt.ctprintf("Texture: %s", entry.mat_tex_name))
		}
	} else if entry.kind == .Scene {
		im.TextColoredUnformatted({0.80, 0.55, 1.0, 1.0}, fmt.ctprintf("Scene Entities: ~%d", entry.scene_obj_count))
	}

	im.Spacing()
	im.TextDisabled("Path:")
	im.TextWrappedUnformatted(fmt.ctprintf("%s", item.path))

	if entry.kind == .Code && len(entry.code_lines) > 0 {
		im.Spacing()
		im.Separator()
		im.TextDisabled("Code Preview:")
		im.BeginChild("##CodeSnippetBox", {0, 115}, {.Borders})
		for line in entry.code_lines {
			im.TextUnformatted(strings.clone_to_cstring(line, context.temp_allocator))
		}
		im.EndChild()
	}

	im.Spacing()
	im.Separator()
	if im.Button(fmt.ctprintf("%s  Open Asset", icons.ICON_MD_PLAY_ARROW), {-1, 26}) {
		if item.is_dir {
			_navigate_to(item.path)
		} else {
			_open_file_item(item.path)
		}
	}
	if im.Button(fmt.ctprintf("%s  Show in %s", icons.ICON_MD_FOLDER_OPEN, file_exp.get_os_explorer_name()), {-1, 26}) {
		file_exp.reveal_in_os(item.path)
	}
	if im.Button(fmt.ctprintf("%s  Copy Relative Path", icons.ICON_MD_LINK), {-1, 24}) {
		im.SetClipboardText(strings.clone_to_cstring(item.path, context.temp_allocator))
	}
}

// ─────────────────────────────────────────────────────────────
// DETAILS / LIST VIEW
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_list_view :: proc(items: []file_exp.File_Item) {
	list_scale := _current_list_scale()
	st := im.GetStyle()
	im.PushFontFloat(nil, st.FontSizeBase * list_scale)
	im.PushStyleVarImVec2(.CellPadding, {st.CellPadding.x * list_scale, max(2.0, st.CellPadding.y * list_scale)})

	ui_s := max(im.GetFontSize() / 14.0, 0.6)
	flags := im.TableFlags_Borders | im.TableFlags_RowBg | im.TableFlags_Resizable | im.TableFlags_ScrollY
	if im.BeginTable("##FilesListTable", 4, flags) {
		im.TableSetupColumn("Name", {.WidthStretch}, 0.45)
		im.TableSetupColumn("Type", {.WidthFixed}, 140.0 * ui_s)
		im.TableSetupColumn("Size", {.WidthFixed}, 90.0 * ui_s)
		im.TableSetupColumn("Path", {.WidthStretch}, 0.35)
		im.TableHeadersRow()

		for item, idx in items {
			im.PushIDInt(i32(idx))
			im.TableNextRow()

			is_sel := _is_item_selected(item.path)

			// Col 0: Icon + Name
			im.TableNextColumn()
			icon_col := item.badge_color
			if item.is_dir {
				folder_key := filepath.base(item.path)
				fcol, has_fcol := editor_visuals.get_folder_color(folder_key)
				if has_fcol do icon_col = fcol
			}

			label := fmt.ctprintf("%s  %s##Row_%d", item.icon_code, item.name, idx)
			im.PushStyleColorImVec4(.Text, icon_col)
			selected := im.Selectable(label, is_sel, {.SpanAllColumns})
			im.PopStyleColor()

			if _scroll_to_selected && is_sel {
				im.SetScrollHereY()
				_scroll_to_selected = false
			}

			// Drag & Drop Source (Godot style drag into Scene, Hierarchy, Inspector, or Folder)
			widgets.pin_active_drag_drop_tooltip()
			if im.BeginDragDropSource({}) {
				im.SetDragDropPayload("ASSET_PATH", raw_data(item.path), len(item.path))
				im.TextColoredUnformatted(icon_col, fmt.ctprintf("%s  %s", item.icon_code, item.name))
				if strings.has_suffix(item.name, ".odin") {
					im.TextDisabled("-> Drop into Scene, Inspector, or Folder to Move")
				} else if strings.has_suffix(item.name, ".scene") || strings.has_suffix(item.name, ".glb") || strings.has_suffix(item.name, ".gltf") {
					im.TextDisabled("-> Drop into Scene, Hierarchy, or Folder")
				} else {
					im.TextDisabled("-> Drop onto any Folder, Breadcrumb, or Tree Node to Move")
				}
				im.EndDragDropSource()
			}

			// Folder rows accept Drag & Drop to move files/folders into them!
			if item.is_dir {
				_accept_folder_drop_target(item.path)
			}

			if selected {
				io := im.GetIO()
				if io.KeyCtrl {
					_toggle_selection(item)
				} else if io.KeyShift {
					_range_selection(item, items)
				} else {
					_set_selection(item)
				}
			}

			if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
				if item.is_dir {
					_navigate_to(item.path)
				} else {
					_open_file_item(item.path)
				}
			}

			// Context Menu
			if im.BeginPopupContextItem(fmt.ctprintf("##ListRowCtx_%d", idx)) {
				if !_is_item_selected(item.path) {
					_set_selection(item)
				}
				_draw_item_context_menu(item)
				im.EndPopup()
			}

			// Col 1: Type
			im.TableNextColumn()
			im.TextUnformatted(fmt.ctprintf("%s", item.type_name))

			// Col 2: Size
			im.TableNextColumn()
			if item.is_dir {
				im.TextDisabled("-")
			} else {
				im.TextUnformatted(fmt.ctprintf("%s", file_exp.format_file_size(item.size_bytes)))
			}

			// Col 3: Path
			im.TableNextColumn()
			im.TextDisabledUnformatted(fmt.ctprintf("%s", item.path))

			im.PopID()
		}
		im.EndTable()
	}

	im.PopStyleVar()
	im.PopFont()
}

// ─────────────────────────────────────────────────────────────
// ITEM CONTEXT MENU
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_item_context_menu :: proc(item: file_exp.File_Item) {
	widgets.popup_header(strings.clone_to_cstring(item.icon_code, context.temp_allocator), item.name, {0.3, 0.75, 1.0, 1.0})

	if item.is_dir {
		if im.MenuItem(fmt.ctprintf("%s  Open Folder", icons.ICON_MD_FOLDER_OPEN)) {
			_navigate_to(item.path)
		}
	} else {
		if im.MenuItem(fmt.ctprintf("%s  Open / Launch", icons.ICON_MD_PLAY_ARROW)) {
			_open_file_item(item.path)
		}
	}

	if im.MenuItem(fmt.ctprintf("%s  Show in %s", icons.ICON_MD_FOLDER_OPEN, file_exp.get_os_explorer_name())) {
		file_exp.reveal_in_os(item.path)
	}

	if !item.is_dir {
		parent_folder := filepath.dir(item.path)
		clean_parent, _ := filepath.clean(parent_folder, context.temp_allocator)
		norm_parent, _ := strings.replace_all(clean_parent, "\\", "/", context.temp_allocator)
		if norm_parent != _get_current_dir() {
			if im.MenuItem(fmt.ctprintf("%s  Go to Containing Folder", icons.ICON_MD_FOLDER)) {
				_navigate_to(norm_parent)
				_set_selection(item)
			}
		}
	}

	// If folder, allow setting Unreal Engine color and Pin/Unpin
	if item.is_dir {
		im.Separator()
		if im.BeginMenu(fmt.ctprintf("%s  Set Color", icons.ICON_MD_PALETTE)) {
			_draw_color_palette_menu(item.path)
			im.EndMenu()
		}

		is_pinned := file_exp.is_bookmark(item.path)
		if is_pinned {
			if im.MenuItem(fmt.ctprintf("%s  Unpin from Quick Access", icons.ICON_MD_CLOSE)) {
				file_exp.remove_bookmark(item.path)
			}
		} else {
			if im.MenuItem(fmt.ctprintf("%s  Pin to Quick Access", icons.ICON_MD_ADD)) {
				file_exp.add_bookmark(item.name, item.path)
			}
		}
	}

	im.Separator()
	if im.MenuItem(fmt.ctprintf("%s  Copy (Ctrl+C)", icons.ICON_MD_CONTENT_COPY)) {
		_copy_selected_to_clipboard()
	}
	if im.MenuItem(fmt.ctprintf("%s  Paste (Ctrl+V)", icons.ICON_MD_CONTENT_PASTE)) {
		_paste_from_clipboard()
	}
	if im.MenuItem(fmt.ctprintf("%s  Duplicate (Ctrl+D)", icons.ICON_MD_CONTENT_COPY)) {
		_copy_selected_to_clipboard()
		_paste_from_clipboard()
	}

	im.Separator()
	abs_p, _ := filepath.abs(item.path, context.temp_allocator)
	widgets.menu_copy_item("Copy Absolute Path", abs_p, "fe_copy_abs")
	widgets.menu_copy_item("Copy Relative Path", item.path, "fe_copy_rel")

	im.Separator()
	if im.MenuItem(fmt.ctprintf("%s  Rename... (F2)", icons.ICON_MD_EDIT)) {
		_open_rename_modal_for_selected()
	}

	if im.MenuItem(fmt.ctprintf("%s  Delete... (Del)", icons.ICON_MD_DELETE)) {
		_open_delete_modal_for_selected()
	}
}

// ─────────────────────────────────────────────────────────────
// MAIN WINDOW ENTRY POINT
// ─────────────────────────────────────────────────────────────

@(editor_window={id="void_file_explorer", title="Void File Explorer", icon="FOLDER", width=980, height=640})
file_explorer_window_draw :: proc() {
	_ensure_init()
	_previews_loaded_this_frame = 0

	_explorer_window_hovered = im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows)
	_explorer_window_focused = im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows)

	// Content-only Ctrl + MouseWheel zoom: adjusts card size (Grid) or row density (List)
	// without distorting toolbars, chrome, or sidebars, and locks child scrolling while Ctrl is held.
	io := im.GetIO()
	ctrl_zoom_lock := io.KeyCtrl && !_any_explorer_modal_open()
	if _explorer_window_hovered && ctrl_zoom_lock && io.MouseWheel != 0 {
		_explorer_step_zoom(io.MouseWheel)
		io.MouseWheel = 0
	}

	// Keyboard shortcuts & Type-ahead jump (Del, F2, Ctrl+C, Ctrl+V, Ctrl+D, Ctrl+=/−/0, A-Z)
	// Active when hovering OR focused on Void File Explorer so Delete/F2 never leak to Scene3D/Hierarchy!
	if (_explorer_window_hovered || _explorer_window_focused) && !im.IsMouseDown(.Right) {
		_handle_keyboard_shortcuts()
	}

	_draw_modals()
	_draw_toolbar()
	_update_search_results()

	// Split view: Left pane (Bookmarks & Tree) | Resizable Divider | Right pane (Content Browser)
	avail_size := im.GetContentRegionAvail()
	bottom_bar_height: f32 = 26.0
	main_content_height := max(60.0, avail_size.y - bottom_bar_height)

	min_left_w: f32 = 140.0
	max_left_w := max(min_left_w, avail_size.x - 200.0)
	_left_pane_width = clamp(_left_pane_width, min_left_w, max_left_w)

	total_right_w := avail_size.x - _left_pane_width - widgets.SPLITTER_SIZE - 4.0
	show_insp := _show_inspector_pane && total_right_w > 460.0
	insp_w: f32 = 0.0
	insp_gap: f32 = 0.0
	if show_insp {
		_inspector_pane_width = clamp(_inspector_pane_width, 190.0, max(200.0, total_right_w * 0.45))
		insp_w = _inspector_pane_width
		insp_gap = widgets.SPLITTER_SIZE
	}
	browser_w := max(60.0, avail_size.x - _left_pane_width - widgets.SPLITTER_SIZE - insp_w - insp_gap - 2.0)

	pane_scroll_flags := ctrl_zoom_lock ? im.WindowFlags{.NoScrollWithMouse} : im.WindowFlags{}
	if im.BeginChild("##ExplorerMainRow", {0, main_content_height}, {}, {.NoScrollbar, .NoScrollWithMouse}) {
		row_h := im.GetContentRegionAvail().y
		// Left Pane: Bookmarks & Tree
		im.BeginChild("##ExplorerLeftPane", {_left_pane_width, row_h}, {.Borders}, pane_scroll_flags)
		_draw_left_pane()
		im.EndChild()

		im.SameLine(0, 0)
		widgets.splitter("##fe_left_split", true, &_left_pane_width, &browser_w, min_left_w, 60.0)
		im.SameLine(0, 0)

		// Center/Right Pane: Content Browser + Optional Live Asset Preview Inspector
		if browser_w >= 60.0 {
			im.BeginChild("##ExplorerRightPane", {browser_w, row_h}, {.Borders}, pane_scroll_flags)
			_draw_right_pane()
			im.EndChild()
		}

		if show_insp {
			im.SameLine(0, 0)
			widgets.splitter("##fe_insp_split", true, &browser_w, &_inspector_pane_width, 60.0, 190.0)
			im.SameLine(0, 0)
			im.BeginChild("##ExplorerInspectorPane", {_inspector_pane_width, row_h}, {.Borders}, pane_scroll_flags)
			_draw_asset_inspector_pane()
			im.EndChild()
		}
	}
	im.EndChild()

	// Bottom Status Bar
	im.Separator()
	q := _get_search_query()
	if len(q) > 0 {
		scope_str := "Folder+"
		if _search_scope == .Active_Folder_Flat {
			scope_str = "Here"
		} else if _search_scope == .All_Project {
			scope_str = "Project"
		}
		folder_count := 0
		file_count := 0
		for item in _search_results {
			if item.is_dir do folder_count += 1
			else do file_count += 1
		}
		im.TextColoredUnformatted({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("Search [%s]: %d matches (%d folders, %d files) for \"%s\"", scope_str, len(_search_results), folder_count, file_count, q))
	} else {
		folder_count := 0
		file_count := 0
		for item in _items {
			if item.is_dir do folder_count += 1
			else do file_count += 1
		}
		im.TextDisabledUnformatted(fmt.ctprintf("%d items (%d folders, %d files)  |  Path: %s", len(_items), folder_count, file_count, _get_current_dir()))
	}

	if _has_selection {
		im.SameLine(0, 20)
		if len(_selected_paths) > 1 {
			im.TextColoredUnformatted({0.2, 0.9, 0.5, 1.0}, fmt.ctprintf("Selected: %d items", len(_selected_paths)))
		} else {
			im.TextColoredUnformatted({0.2, 0.9, 0.5, 1.0}, fmt.ctprintf("Selected: %s (%s)", _get_selected_name(), _get_selected_type()))
		}
	}

	if _clipboard_has_item && _clipboard_path_len > 0 {
		clip_name := filepath.base(string(_clipboard_path_buf[:_clipboard_path_len]))
		im.SameLine(0, 20)
		im.TextColoredUnformatted({0.95, 0.75, 0.3, 1.0}, fmt.ctprintf("Clipboard: %s (Ctrl+V to Paste)", clip_name))
	}
}

// Returns the active Void File Explorer directory mapped into asset-DB space
// (e.g. "assets/..." or "packages/<pkg>/assets/..."), defaulting to "assets".
fe_active_asset_dir :: proc() -> string {
	rel := _to_asset_db_path(_get_current_dir(), context.temp_allocator)
	if strings.has_prefix(rel, "assets") || strings.has_prefix(rel, "packages/") {
		return rel
	}
	return "assets"
}

// Returns the currently selected item in Void File Explorer mapped into asset-DB space.
fe_selected_asset_path :: proc() -> string {
	if !_has_selection do return ""
	rel := _to_asset_db_path(_get_selected_path(), context.temp_allocator)
	if strings.has_prefix(rel, "assets") || strings.has_prefix(rel, "packages/") {
		return rel
	}
	return ""
}

// Navigates Void File Explorer to the folder containing `asset_db_path` and optionally selects it.
fe_reveal_asset_path :: proc(asset_db_path: string, select_item: bool) {
	if asset_db_path == "" do return
	disk_path := ""
	if os.exists(asset_db_path) {
		disk_path = asset_db_path
	} else if strings.has_prefix(asset_db_path, "packages/") {
		rel_pkg := strings.trim_prefix(asset_db_path, "packages/")
		cands := [?]string{
			filepath.join({engine.engine_plugins_dir(context.temp_allocator), rel_pkg}, context.temp_allocator) or_else "",
			filepath.join({engine.engine_packages_dir(context.temp_allocator), rel_pkg}, context.temp_allocator) or_else "",
			file_exp.resolve_workspace_path(fmt.tprintf("plugins/%s", rel_pkg), context.temp_allocator),
			file_exp.resolve_workspace_path(fmt.tprintf("haati/%s", asset_db_path), context.temp_allocator),
		}
		for cand in cands {
			if cand != "" && os.exists(cand) {
				disk_path = cand
				break
			}
		}
	} else if strings.has_prefix(asset_db_path, "assets") {
		cand := file_exp.resolve_workspace_path(fmt.tprintf("haati/%s", asset_db_path), context.temp_allocator)
		if os.exists(cand) {
			disk_path = cand
		} else {
			eng_cand := engine.engine_file_path(fmt.tprintf("haati/%s", asset_db_path), context.temp_allocator)
			if os.exists(eng_cand) do disk_path = eng_cand
		}
	} else {
		cand := file_exp.resolve_workspace_path(asset_db_path, context.temp_allocator)
		if os.exists(cand) do disk_path = cand
	}
	if disk_path == "" do return
	parent := disk_path if os.is_dir(disk_path) else filepath.dir(disk_path)
	if parent != "" {
		_set_current_dir(parent, true)
		_needs_refresh = true
	}
	if select_item {
		_selected_paths_clear()
		_selected_paths_append(disk_path)
		_selected_path_len = copy(_selected_path_buf[:], disk_path)
		_selected_name_len = copy(_selected_name_buf[:], filepath.base(disk_path))
		_selected_type_len = copy(_selected_type_buf[:], "Asset")
		_has_selection = true
		_fe_selection_epoch += 1
	}
}


