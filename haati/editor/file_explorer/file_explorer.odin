package file_explorer

// Godot & Unreal Engine 5 style File Explorer & Content Browser for MoonHug.
// Provides grid/thumbnail cards, details list, recursive directory tree,
// Quick Access bookmarks (Game project, Assets, Godot import, Plugins),
// instant search, Windows Explorer reveal, and one-click level/script creation.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:sys/windows"
import "core:unicode/utf8"
import engine "haati:engine"

File_Type_Kind :: enum {
	Folder,
	Scene,       // .scene, .tscn, .level
	Model3D,     // .glb, .gltf, .fbx, .obj
	Texture,     // .png, .jpg, .jpeg, .tga, .bmp, .webp
	Audio,       // .wav, .ogg, .mp3, .flac
	Script,      // .odin, .gd, .cs, .c, .cpp
	DataConfig,  // .json, .toml, .yaml, .ini, .cfg
	Material,    // .mat, .material, .glsl, .shader
	Font,        // .ttf, .otf
	GenericFile, // other
}

File_Item :: struct {
	name:        string,
	path:        string,
	name_lower:  string,
	name_norm:   string,
	path_lower:  string,
	is_dir:      bool,
	size_bytes:  i64,
	mod_time:    time.Time,
	extension:   string,
	kind:        File_Type_Kind,
	type_name:   string,
	icon_code:   string,
	badge_color: [4]f32,
}

Search_Scope :: enum {
	Active_Folder_Recursive = 0, // Default: searches active folder and its subfolders
	Active_Folder_Flat      = 1, // Searches only immediate children of active folder
	All_Project             = 2, // Searches entire workspace (excluding derived/cache dirs)
}

Sort_Mode :: enum {
	Name_Asc = 0,
	Name_Desc,
	Date_Newest,
	Date_Oldest,
	Size_Largest,
	Size_Smallest,
	Type_Asc,
}

Bookmark :: struct {
	label: string,
	path:  string,
	icon:  string,
}

CARD_SIZE_MIN     :: f32(48.0)
CARD_SIZE_DEFAULT :: f32(104.0)
CARD_SIZE_MAX     :: f32(256.0)
CARD_SIZE_STEP    :: f32(12.0)

LIST_SCALE_MIN     :: f32(0.75)
LIST_SCALE_DEFAULT :: f32(1.00)
LIST_SCALE_MAX     :: f32(1.65)
LIST_SCALE_STEP    :: f32(0.10)

External_IDE_Preset :: enum {
	Auto_Detect = 0,
	VS_Code,
	Cursor,
	Antigravity,
	Rider,
	Custom,
}

Script_Jump_Target :: enum {
	Odin_Code = 0,
	Blueprint_Graph,
}

open_script_smart_fn: proc(path: string, line: int) -> bool

@(private = "file") _ide_prefer_external: bool
@(private = "file") _ide_preset: External_IDE_Preset = .Auto_Detect
@(private = "file") _ide_custom_exe: string

set_external_ide_config :: proc(prefer_external: bool, preset: External_IDE_Preset, custom_exe: string) {
	_ide_prefer_external = prefer_external
	_ide_preset          = preset
	if _ide_custom_exe != "" {
		delete(_ide_custom_exe, runtime.default_allocator())
		_ide_custom_exe = ""
	}
	if custom_exe != "" {
		_ide_custom_exe = strings.clone(custom_exe, runtime.default_allocator())
	}
}

prefer_external_ide_enabled :: proc() -> bool {
	return _ide_prefer_external
}

external_ide_preset_current :: proc() -> External_IDE_Preset {
	return _ide_preset
}

File_Explorer_Settings :: struct {
	show_hidden:       bool,
	grid_card_size:    f32,
	list_row_scale:    f32,
	is_grid_view:      bool,
	auto_refresh_sec:  f32,
	ide_executable:    string,
}

@(project_settings={name="Void File Explorer"})
settings := File_Explorer_Settings{
	show_hidden      = false,
	grid_card_size   = CARD_SIZE_DEFAULT,
	list_row_scale   = LIST_SCALE_DEFAULT,
	is_grid_view     = true,
	auto_refresh_sec = 2.0,
	ide_executable   = "",
}

@(phase={key=SerializationInit, order=10, mode=Editor})
_register_file_explorer_settings_types :: proc() {
	engine.register_pointer_type(File_Explorer_Settings)
}

// Clamps grid thumbnail card size in logical pixels to `[48, 256]`, falling back
// to `CARD_SIZE_DEFAULT` only when zero-initialized (`0`) from an older settings file.
clamp_card_size :: proc(px: f32) -> f32 {
	if px == 0 do return CARD_SIZE_DEFAULT
	return clamp(math.round(px), CARD_SIZE_MIN, CARD_SIZE_MAX)
}

// Steps grid thumbnail card size by mouse-wheel or hotkey notches within `[48, 256]`.
step_card_size :: proc(curr_px: f32, wheel_notches: f32) -> f32 {
	raw := clamp_card_size(curr_px) + wheel_notches * CARD_SIZE_STEP
	return clamp(math.round(raw), CARD_SIZE_MIN, CARD_SIZE_MAX)
}

// Clamps details/list row density scale to `[0.75, 1.65]`, defaulting zero-initialized
// legacy settings values cleanly to `1.00`.
clamp_list_scale :: proc(scale: f32) -> f32 {
	if scale == 0 do return LIST_SCALE_DEFAULT
	return clamp(math.round(scale * 100.0) / 100.0, LIST_SCALE_MIN, LIST_SCALE_MAX)
}

// Steps details/list density scale by wheel/hotkey notches within `[0.75, 1.65]`.
step_list_scale :: proc(curr_scale: f32, wheel_notches: f32) -> f32 {
	raw := clamp_list_scale(curr_scale) + wheel_notches * LIST_SCALE_STEP
	return clamp(math.round(raw * 100.0) / 100.0, LIST_SCALE_MIN, LIST_SCALE_MAX)
}

@(private = "file")
_utf8_prefix_bytes :: proc(s: string, n_runes: int) -> string {
	if n_runes <= 0 || len(s) == 0 do return ""
	count := 0
	for _, byte_idx in s {
		if count == n_runes {
			return s[:byte_idx]
		}
		count += 1
	}
	return s
}

// Truncates `name` using middle-ellipsis when it exceeds `max_runes`, preserving file
// extensions on files and slicing only on UTF-8 rune boundaries.
format_middle_ellipsis :: proc(name: string, ext: string, is_dir: bool, max_runes: int, allocator := context.temp_allocator) -> string {
	if max_runes <= 0 || len(name) == 0 do return ""
	total_runes := utf8.rune_count_in_string(name)
	if total_runes <= max_runes {
		return name
	}
	if max_runes <= 2 {
		return _utf8_prefix_bytes(name, max_runes)
	}
	ext_runes := utf8.rune_count_in_string(ext)
	if !is_dir && ext_runes > 0 && strings.has_suffix(name, ext) && ext_runes + 4 <= max_runes {
		keep_prefix := max(2, max_runes - ext_runes - 2)
		return fmt.aprintf("%s..%s", _utf8_prefix_bytes(name, keep_prefix), ext, allocator = allocator)
	}
	return fmt.aprintf("%s..", _utf8_prefix_bytes(name, max(1, max_runes - 2)), allocator = allocator)
}

get_workspace_root :: proc() -> string {
	if engine.has_active_project() do return "."
	if eng_root := engine.engine_root(context.temp_allocator); eng_root != "" {
		return eng_root
	}
	if os.exists("../plugins") do return ".."
	if os.exists("plugins") do return "."
	return ".."
}

resolve_workspace_path :: proc(rel: string, allocator := context.allocator) -> string {
	clean_rel, _ := filepath.clean(rel, context.temp_allocator)
	norm_rel, _ := strings.replace_all(clean_rel, "\\", "/", context.temp_allocator)
	if norm_rel == "." || norm_rel == "" {
		return strings.clone(get_workspace_root(), allocator)
	}
	if strings.has_prefix(norm_rel, "..") || filepath.is_abs(norm_rel) {
		return strings.clone(norm_rel, allocator)
	}
	ws := get_workspace_root()
	if ws == "." {
		return strings.clone(norm_rel, allocator)
	}
	joined, _ := filepath.join({ws, norm_rel}, context.temp_allocator)
	clean_joined, _ := filepath.clean(joined, context.temp_allocator)
	norm_joined, _ := strings.replace_all(clean_joined, "\\", "/", context.temp_allocator)
	return strings.clone(norm_joined, allocator)
}

@(private = "file")
_bookmarks: [dynamic]Bookmark
@(private = "file")
_bookmarks_init := false

_init_bookmarks :: proc() {
	if _bookmarks_init do return
	_bookmarks_init = true
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	_bookmarks = make([dynamic]Bookmark)
	if engine.has_active_project() {
		append(&_bookmarks, Bookmark{
			label = fmt.aprintf("Project (%s)", engine.active_project_name()),
			path  = strings.clone("."),
			icon  = "\uf720",
		})
		append(&_bookmarks, Bookmark{
			label = strings.clone("Project Assets"),
			path  = strings.clone("assets"),
			icon  = "\ue2c7",
		})
	} else {
		append(&_bookmarks, Bookmark{
			label = strings.clone("Workspace Root"),
			path  = strings.clone(get_workspace_root()),
			icon  = "\ue2c8",
		})
	}
	if eng_plugins := engine.engine_plugins_dir(context.temp_allocator); eng_plugins != "" {
		append(&_bookmarks, Bookmark{
			label = strings.clone("Engine Plugins"),
			path  = strings.clone(eng_plugins),
			icon  = "\ue87b",
		})
		ctrl_rig, _ := filepath.join({eng_plugins, "control_rig", "assets"}, context.temp_allocator)
		if os.exists(ctrl_rig) {
			append(&_bookmarks, Bookmark{
				label = strings.clone("Control Rig"),
				path  = strings.clone(ctrl_rig),
				icon  = "\ue71c",
			})
		}
	}
	if eng_haati := engine.engine_haati_dir(context.temp_allocator); eng_haati != "" {
		append(&_bookmarks, Bookmark{
			label = strings.clone("Engine Core (haati)"),
			path  = strings.clone(eng_haati),
			icon  = "\ue869",
		})
	}
}

get_bookmarks :: proc() -> []Bookmark {
	_init_bookmarks()
	return _bookmarks[:]
}

is_bookmark :: proc(path: string) -> bool {
	_init_bookmarks()
	clean, _ := filepath.clean(path, context.temp_allocator)
	norm, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
	for bm in _bookmarks {
		if bm.path == norm || bm.path == path do return true
	}
	return false
}

add_bookmark :: proc(label: string, path: string) -> bool {
	_init_bookmarks()
	clean, _ := filepath.clean(path, context.temp_allocator)
	norm, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
	for bm in _bookmarks {
		if bm.path == norm do return false
	}
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	append(&_bookmarks, Bookmark{
		label = strings.clone(label),
		path  = strings.clone(norm),
		icon  = "\ue2c7",
	})
	return true
}

remove_bookmark :: proc(path: string) -> bool {
	_init_bookmarks()
	clean, _ := filepath.clean(path, context.temp_allocator)
	norm, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	for i in 0 ..< len(_bookmarks) {
		if _bookmarks[i].path == norm || _bookmarks[i].path == path {
			delete(_bookmarks[i].label)
			delete(_bookmarks[i].path)
			ordered_remove(&_bookmarks, i)
			return true
		}
	}
	return false
}

format_file_size :: proc(size_bytes: i64) -> string {
	if size_bytes < 1024 {
		return fmt.tprintf("%d B", size_bytes)
	} else if size_bytes < 1024 * 1024 {
		return fmt.tprintf("%.1f KB", f32(size_bytes) / 1024.0)
	} else if size_bytes < 1024 * 1024 * 1024 {
		return fmt.tprintf("%.2f MB", f32(size_bytes) / (1024.0 * 1024.0))
	} else {
		return fmt.tprintf("%.2f GB", f32(size_bytes) / (1024.0 * 1024.0 * 1024.0))
	}
}

classify_file :: proc(name: string, is_dir: bool) -> (kind: File_Type_Kind, type_name: string, icon_code: string, color: [4]f32) {
	if is_dir {
		return .Folder, "Folder", "\ue2c7", {1.0, 0.82, 0.28, 1.0} // Folder icon
	}

	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	switch ext {
	case ".scene":
		return .Scene, "Moonhug Scene", "\uf720", {0.82, 0.45, 1.0, 1.0}
	case ".tscn", ".scn":
		return .Scene, "Godot Scene", "\uf720", {0.72, 0.40, 0.95, 1.0}
	case ".level":
		return .Scene, "Level Map", "\uf720", {0.88, 0.50, 1.0, 1.0}
	case ".glb", ".gltf":
		return .Model3D, "3D Model (glTF)", "\ue1bd", {0.25, 0.90, 0.55, 1.0}
	case ".fmesh":
		return .Model3D, "Faker CSG Prefab (.fmesh)", "\ue1bd", {0.35, 0.95, 0.72, 1.0}
	case ".fbx", ".obj", ".dae":
		return .Model3D, "3D Mesh", "\ue1bd", {0.20, 0.82, 0.65, 1.0}
	case ".png", ".jpg", ".jpeg", ".tga", ".bmp", ".webp":
		return .Texture, "Texture / Image", "\ue3f4", {0.30, 0.85, 1.0, 1.0}
	case ".wav", ".ogg", ".mp3", ".flac":
		return .Audio, "Audio Sound", "\ue405", {1.0, 0.45, 0.65, 1.0}
	case ".odin":
		return .Script, "Odin Script", "\ue86f", {0.35, 0.70, 1.0, 1.0}
	case ".gd":
		return .Script, "GDScript", "\ue86f", {0.45, 0.75, 1.0, 1.0}
	case ".cs":
		return .Script, "C# Script", "\ue86f", {0.55, 0.65, 0.95, 1.0}
	case ".json":
		return .DataConfig, "JSON Data", "\ue873", {1.0, 0.65, 0.25, 1.0}
	case ".toml", ".yaml", ".yml", ".ini", ".cfg", ".tres", ".res":
		return .DataConfig, "Config / Resource", "\ue873", {1.0, 0.60, 0.30, 1.0}
	case ".mat", ".material":
		return .Material, "Material Asset", "\ue40a", {1.0, 0.80, 0.20, 1.0}
	case ".glsl", ".shader":
		return .Material, "GLSL Shader", "\ue40a", {1.0, 0.75, 0.30, 1.0}
	case ".ttf", ".otf":
		return .Font, "TrueType Font", "\ue873", {0.90, 0.90, 0.50, 1.0}
	case:
		return .GenericFile, "File", "\ue873", {0.70, 0.75, 0.80, 1.0}
	}
}

// Pre-computes lowercase and delimiter-stripped ("node_3.odin" -> "node3odin") keys once
// so multi-core search matching performs zero allocations and zero string building per item.
normalize_search_key :: proc(s: string, allocator := context.allocator) -> (lower: string, norm: string) {
	return engine.normalize_search_key(s, allocator)
}

should_skip_search_dir :: proc(dir_name: string, show_hidden: bool = false) -> bool {
	if !show_hidden && strings.has_prefix(dir_name, ".") do return true
	switch dir_name {
	case "builds", "bin", "library", ".git", ".gemini", ".system_generated", ".vscode", ".idea", ".junie", "node_modules":
		return true
	}
	return false
}

make_file_item :: proc(name: string, norm_path: string, is_dir: bool, size_bytes: i64, mod_time: time.Time, allocator := context.allocator) -> File_Item {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	kind, type_name, icon, col := classify_file(name, is_dir)
	name_lower, name_norm := normalize_search_key(name, allocator)
	path_lower := strings.to_lower(norm_path, allocator)
	return File_Item{
		name        = strings.clone(name, allocator),
		path        = strings.clone(norm_path, allocator),
		name_lower  = name_lower,
		name_norm   = name_norm,
		path_lower  = path_lower,
		is_dir      = is_dir,
		size_bytes  = size_bytes,
		mod_time    = mod_time,
		extension   = strings.clone(ext, allocator),
		kind        = kind,
		type_name   = type_name,
		icon_code   = icon,
		badge_color = col,
	}
}

sort_file_items :: proc(items: []File_Item, mode: Sort_Mode = .Name_Asc) {
	if len(items) <= 1 do return
	switch mode {
	case .Name_Asc:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			return a.name_lower < b.name_lower
		})
	case .Name_Desc:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			return a.name_lower > b.name_lower
		})
	case .Date_Newest:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			if a.mod_time._nsec != b.mod_time._nsec do return a.mod_time._nsec > b.mod_time._nsec
			return a.name_lower < b.name_lower
		})
	case .Date_Oldest:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			if a.mod_time._nsec != b.mod_time._nsec do return a.mod_time._nsec < b.mod_time._nsec
			return a.name_lower < b.name_lower
		})
	case .Size_Largest:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			if a.size_bytes != b.size_bytes do return a.size_bytes > b.size_bytes
			return a.name_lower < b.name_lower
		})
	case .Size_Smallest:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			if a.size_bytes != b.size_bytes do return a.size_bytes < b.size_bytes
			return a.name_lower < b.name_lower
		})
	case .Type_Asc:
		slice.sort_by(items, proc(a, b: File_Item) -> bool {
			if a.is_dir != b.is_dir do return a.is_dir
			if a.extension != b.extension do return a.extension < b.extension
			return a.name_lower < b.name_lower
		})
	}
}

read_dir_items :: proc(dir_path: string, show_hidden: bool = false, allocator := context.allocator, sort_mode: Sort_Mode = .Name_Asc) -> [dynamic]File_Item {
	items := make([dynamic]File_Item, allocator)
	clean_dir, _ := filepath.clean(dir_path, context.temp_allocator)

	handle, err := os.open(clean_dir)
	if err != nil do return items
	defer os.close(handle)

	fi_slice, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return items
	defer os.file_info_slice_delete(fi_slice, context.temp_allocator)

	for fi in fi_slice {
		if !show_hidden && strings.has_prefix(fi.name, ".") do continue
		if strings.has_suffix(fi.name, ".meta") do continue

		is_dir := fi.type == .Directory
		full, _ := filepath.join({clean_dir, fi.name}, context.temp_allocator)
		normalized_path, _ := strings.replace_all(full, "\\", "/", context.temp_allocator)

		append(&items, make_file_item(fi.name, normalized_path, is_dir, fi.size, fi.modification_time, allocator))
	}

	sort_file_items(items[:], sort_mode)
	return items
}

// ─────────────────────────────────────────────────────────────
// MULTI-CORE SLICED SEARCH & INCREMENTAL NARROWING ENGINE
// ─────────────────────────────────────────────────────────────

Prepared_Query :: engine.Prepared_Search_Query

prepare_search_query :: proc(query: string, allocator := context.temp_allocator) -> Prepared_Query {
	return engine.prepare_search_query(query, allocator)
}

// Pure, lock-free, zero-allocation predicate safe to execute across worker threads.
item_matches_prepared_query :: proc(item: File_Item, pq: ^Prepared_Query) -> bool {
	return engine.search_match_cached(item.name_lower, item.name_norm, pq, item.path_lower, require_primary_hit = true)
}

// Returns true when `new_query` is a strict narrowing refinement of `old_query`
// (e.g. user typed additional characters at the end or beginning of `old_query`),
// allowing the search engine to slice and filter ONLY the previous match list
// instead of rescanning the full scope index.
can_narrow_search_query :: proc(old_query: string, new_query: string) -> bool {
	return engine.can_narrow_search_query(old_query, new_query)
}

@(private = "file")
_collect_scope_recursive :: proc(
	dir_path: string,
	show_hidden: bool,
	out_items: ^[dynamic]File_Item,
	depth: int,
	alloc: runtime.Allocator,
	max_depth: int,
	max_items: int,
) {
	if depth > max_depth || len(out_items^) >= max_items do return

	clean_dir, _ := filepath.clean(dir_path, context.temp_allocator)
	norm_dir, _ := strings.replace_all(clean_dir, "\\", "/", context.temp_allocator)

	handle, err := os.open(clean_dir)
	if err != nil do return
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for entry in entries {
		if len(out_items^) >= max_items do break
		if strings.has_suffix(entry.name, ".meta") do continue

		is_dir := entry.type == .Directory
		if is_dir {
			if should_skip_search_dir(entry.name, show_hidden) do continue
		} else {
			if !show_hidden && strings.has_prefix(entry.name, ".") do continue
		}

		full_path, _ := filepath.join({norm_dir, entry.name}, context.temp_allocator)
		norm_path, _ := strings.replace_all(full_path, "\\", "/", context.temp_allocator)

		append(out_items, make_file_item(entry.name, norm_path, is_dir, entry.size, entry.modification_time, alloc))

		if is_dir {
			_collect_scope_recursive(norm_path, show_hidden, out_items, depth + 1, alloc, max_depth, max_items)
		}
	}
}

// Builds an in-memory index of `File_Item`s for the given `root_dir` and `scope`.
// Rebuilt only when the folder/scope changes or on explicit refresh — never on keystrokes!
build_scope_index :: proc(
	root_dir: string,
	scope: Search_Scope,
	show_hidden: bool = false,
	allocator := context.allocator,
	max_depth: int = 12,
	max_items: int = 8192,
) -> [dynamic]File_Item {
	if scope == .Active_Folder_Flat {
		return read_dir_items(root_dir, show_hidden, allocator)
	}
	items := make([dynamic]File_Item, allocator)
	target_root := get_workspace_root() if scope == .All_Project else root_dir
	_collect_scope_recursive(target_root, show_hidden, &items, 0, allocator, max_depth, max_items)
	return items
}

@(private = "file")
_Parallel_Search_Batch_Ctx :: struct {
	candidates:  []File_Item,
	pq:          Prepared_Query,
	match_flags: []u8,
}

@(private = "file")
_parallel_search_worker :: proc(start, end: int, userdata: rawptr) {
	ctx := cast(^_Parallel_Search_Batch_Ctx)userdata
	// Odin array slicing: each worker operates strictly on its disjoint slice `candidates[start:end]`
	// and writes to its disjoint slice `match_flags[start:end]`.
	sub_candidates := ctx.candidates[start:end]
	sub_flags      := ctx.match_flags[start:end]
	for i in 0 ..< len(sub_candidates) {
		sub_flags[i] = 1 if item_matches_prepared_query(sub_candidates[i], &ctx.pq) else 0
	}
}

// Filters `candidates` against `query` by slicing the array across worker threads via `engine.job_parallel_for`,
// then compacts the surviving items into `out_results` on the main thread and sorts them by `sort_mode`.
filter_items_parallel :: proc(
	candidates: []File_Item,
	query: string,
	out_results: ^[dynamic]File_Item,
	sort_mode: Sort_Mode = .Name_Asc,
	max_results: int = 2000,
) {
	clear(out_results)
	if len(candidates) == 0 do return

	pq := prepare_search_query(query, context.temp_allocator)
	if len(pq.raw_lower) == 0 {
		count := min(len(candidates), max_results)
		for i in 0 ..< count {
			append(out_results, candidates[i])
		}
		sort_file_items(out_results[:], sort_mode)
		return
	}

	// For small candidate slices (< 256 items, e.g. Active Folder search or narrowed results),
	// filter directly on the calling core to avoid worker thread wake/sync micro-stutters!
	if len(candidates) < 256 {
		for i in 0 ..< len(candidates) {
			if item_matches_prepared_query(candidates[i], &pq) {
				append(out_results, candidates[i])
				if len(out_results^) >= max_results do break
			}
		}
		sort_file_items(out_results[:], sort_mode)
		return
	}

	flags := make([]u8, len(candidates), context.temp_allocator)
	batch_ctx := _Parallel_Search_Batch_Ctx{
		candidates  = candidates,
		pq          = pq,
		match_flags = flags,
	}

	// Slice array into cache-line friendly chunks across the engine worker pool
	batch_size := max(64, len(candidates) / 8)
	engine.job_parallel_for(len(candidates), batch_size, _parallel_search_worker, &batch_ctx)

	for i in 0 ..< len(candidates) {
		if flags[i] != 0 {
			append(out_results, candidates[i])
			if len(out_results^) >= max_results do break
		}
	}

	sort_file_items(out_results[:], sort_mode)
}

free_items :: proc(items: ^[dynamic]File_Item) {
	if items == nil do return
	clear(items)
}

// Returns the human-readable name of the current operating system's file explorer.
get_os_explorer_name :: proc() -> string {
	when ODIN_OS == .Windows {
		return "Windows Explorer"
	} else when ODIN_OS == .Darwin {
		return "Finder (macOS)"
	} else {
		return "OS File Explorer"
	}
}

// Resolves a relative or `../`-prefixed workspace path into a canonical, dot-dot-free OS path.
// Crucial on Windows because `explorer.exe /select,"..."` rejects paths containing `\..\`!
canonicalize_os_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	resolved := path
	if r, ok := resolve_source_file_path(path, allocator); ok && len(r) > 0 {
		resolved = r
	} else {
		clean_first, _ := filepath.clean(path, allocator)
		if abs_p, err := filepath.abs(clean_first, allocator); err == nil && len(abs_p) > 0 {
			resolved = abs_p
		} else {
			resolved = clean_first
		}
	}
	// Clean AFTER `filepath.abs` to strip any `..` segments that `filepath.abs` concatenated!
	clean_abs, _ := filepath.clean(resolved, allocator)
	when ODIN_OS == .Windows {
		win_p, _ := strings.replace_all(clean_abs, "/", "\\", allocator)
		return win_p
	} else {
		return clean_abs
	}
}

// Reveal a file or folder in the OS File Explorer (Windows Explorer with `/select,`)
reveal_in_os :: proc(path: string) -> bool {
	return engine.os_reveal_in_os(path)
}

// Open file or directory using system default program
open_in_os :: proc(path: string) -> bool {
	return engine.os_open_in_os(path)
}

// Resolves any source file path (relative, plugin-relative, two-root engine/project, or
// moonhug/packages-relative) to a canonical, guaranteed-existing absolute path on disk.
resolve_source_file_path :: proc(raw_path: string, allocator := context.temp_allocator) -> (abs_path: string, ok: bool) {
	if len(raw_path) == 0 do return "", false

	norm_raw, _ := strings.replace_all(raw_path, "\\", "/", context.temp_allocator)
	for strings.has_prefix(norm_raw, "./") {
		norm_raw = norm_raw[2:]
	}

	// If already absolute and exists
	if filepath.is_abs(norm_raw) && os.exists(norm_raw) {
		clean_abs, _ := filepath.clean(norm_raw, context.temp_allocator)
		abs, err := filepath.abs(clean_abs, allocator)
		if err == nil do return abs, true
		return strings.clone(clean_abs, allocator), true
	}

	proj_root := engine.has_active_project() ? engine.active_project_root() : ""
	eng_root  := engine.engine_root(context.temp_allocator)
	eng_haati := engine.engine_haati_dir(context.temp_allocator)
	eng_plugs := engine.engine_plugins_dir(context.temp_allocator)
	eng_pkgs  := engine.engine_packages_dir(context.temp_allocator)
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	ws_root   := get_workspace_root()
	ws_abs, _ := filepath.abs(ws_root, context.temp_allocator)

	search_roots := make([dynamic]string, context.temp_allocator)
	_append_unique_root :: proc(roots: ^[dynamic]string, dir: string) {
		if dir == "" do return
		clean_d, _ := filepath.clean(dir, context.temp_allocator)
		abs_d, err := filepath.abs(clean_d, context.temp_allocator)
		val := err == nil ? abs_d : clean_d
		for r in roots^ {
			if strings.equal_fold(r, val) do return
		}
		append(roots, val)
	}
	_append_unique_root(&search_roots, proj_root)
	_append_unique_root(&search_roots, ws_abs)
	_append_unique_root(&search_roots, eng_root)
	_append_unique_root(&search_roots, eng_haati)
	_append_unique_root(&search_roots, repo_root)

	candidates := make([dynamic]string, context.temp_allocator)

	// 1. Package prefixes: "haati/packages/<pkg>/...", "moonhug/packages/<pkg>/...", "packages/<pkg>/..."
	pkg_sub := ""
	if strings.has_prefix(norm_raw, "haati/packages/") {
		pkg_sub = norm_raw[len("haati/packages/"):]
	} else if strings.has_prefix(norm_raw, "moonhug/packages/") {
		pkg_sub = norm_raw[len("moonhug/packages/"):]
	} else if strings.has_prefix(norm_raw, "packages/") {
		pkg_sub = norm_raw[len("packages/"):]
	}
	if pkg_sub != "" {
		if eng_plugs != "" {
			if c, err := filepath.join({eng_plugs, pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		if eng_pkgs != "" {
			if c, err := filepath.join({eng_pkgs, pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		if eng_root != "" {
			if c, err := filepath.join({eng_root, "plugins", pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
			if c, err := filepath.join({eng_root, "haati", "packages", pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		if proj_root != "" {
			if slug := engine.active_project_slug(context.temp_allocator); slug != "" {
				slug_prefix := strings.concatenate({slug, "/"}, context.temp_allocator)
				if len(pkg_sub) >= len(slug_prefix) && strings.equal_fold(pkg_sub[:len(slug_prefix)], slug_prefix) {
					if c, err := filepath.join({proj_root, pkg_sub[len(slug_prefix):]}, context.temp_allocator); err == nil {
						append(&candidates, c)
					}
				}
			}
		}
		for r in search_roots {
			if c, err := filepath.join({r, "plugins", pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
			if c, err := filepath.join({r, "haati", "packages", pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
			if c, err := filepath.join({r, "packages", pkg_sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
	}

	// 2. "moonhug/<rest>" -> legacy alias of "haati/<rest>"
	if strings.has_prefix(norm_raw, "moonhug/") {
		sub := norm_raw[len("moonhug/"):]
		if eng_haati != "" {
			if c, err := filepath.join({eng_haati, sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		if eng_root != "" {
			if c, err := filepath.join({eng_root, "haati", sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		for r in search_roots {
			if c, err := filepath.join({r, sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
	}

	// 3. "haati/<rest>" -> check engine_root/haati/<rest>, engine_haati/<rest>, or stripped <rest>
	if strings.has_prefix(norm_raw, "haati/") {
		sub := norm_raw[len("haati/"):]
		if eng_haati != "" {
			if c, err := filepath.join({eng_haati, sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		if eng_root != "" {
			if c, err := filepath.join({eng_root, norm_raw}, context.temp_allocator); err == nil do append(&candidates, c)
		}
		for r in search_roots {
			if c, err := filepath.join({r, sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
	}

	// 4. "plugins/<rest>"
	if strings.has_prefix(norm_raw, "plugins/") {
		sub := norm_raw[len("plugins/"):]
		if eng_plugs != "" {
			if c, err := filepath.join({eng_plugs, sub}, context.temp_allocator); err == nil do append(&candidates, c)
		}
	}

	// 5. Direct relative across search roots + cwd
	for r in search_roots {
		if c, err := filepath.join({r, norm_raw}, context.temp_allocator); err == nil do append(&candidates, c)
	}
	append(&candidates, norm_raw)

	for cand in candidates {
		clean_c, _ := filepath.clean(cand, context.temp_allocator)
		if os.exists(clean_c) {
			abs, err := filepath.abs(clean_c, allocator)
			if err == nil do return abs, true
			return strings.clone(clean_c, allocator), true
		}
	}

	fallback_root := eng_root != "" ? eng_root : ws_abs
	fallback, _ := filepath.join({fallback_root, norm_raw}, context.temp_allocator)
	return strings.clone(fallback, allocator), false
}

@(private = "file")
_find_blueprint_companion :: proc(stem: string, near_dir: string, allocator := context.temp_allocator) -> (string, bool) {
	if stem == "" do return "", false
	exts := [2]string{".bodin", ".mhgraph"}
	search_dirs := make([dynamic]string, context.temp_allocator)
	if near_dir != "" do append(&search_dirs, near_dir)
	if pr := engine.active_project_root(); pr != "" {
		if d, err := filepath.join({pr, "assets", "scripts"}, context.temp_allocator); err == nil do append(&search_dirs, d)
	}
	if er := engine.engine_root(context.temp_allocator); er != "" {
		if d, err := filepath.join({er, "assets", "scripts"}, context.temp_allocator); err == nil do append(&search_dirs, d)
	}
	if eh := engine.engine_haati_dir(context.temp_allocator); eh != "" {
		if d, err := filepath.join({eh, "assets", "scripts"}, context.temp_allocator); err == nil do append(&search_dirs, d)
	}
	for dir in search_dirs {
		for ext in exts {
			cand, err := filepath.join({dir, fmt.tprintf("%s%s", stem, ext)}, context.temp_allocator)
			if err == nil && os.exists(cand) {
				abs, aerr := filepath.abs(cand, allocator)
				if aerr == nil do return abs, true
				return strings.clone(cand, allocator), true
			}
		}
	}
	return "", false
}

// Classifies a script path so jump-to-code routes `.bodin` / `.mhgraph` (and generated
// companion Odin files) to Blueprint Studio while genuine `.odin` sources open in an IDE.
classify_script_jump_target :: proc(path: string, allocator := context.temp_allocator) -> (kind: Script_Jump_Target, target_path: string) {
	if len(path) == 0 do return .Odin_Code, ""
	norm, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	lo := strings.to_lower(norm, context.temp_allocator)
	if strings.has_suffix(lo, ".bodin") || strings.has_suffix(lo, ".mhgraph") {
		return .Blueprint_Graph, strings.clone(path, allocator)
	}
	base := filepath.base(norm)
	dir: string
	{
		context.allocator = context.temp_allocator
		dir = filepath.dir(norm)
	}
	if strings.has_suffix(lo, "_mhgraph_generated.odin") && len(base) > len("_mhgraph_generated.odin") {
		stem := base[:len(base) - len("_mhgraph_generated.odin")]
		if comp, ok := _find_blueprint_companion(stem, dir, allocator); ok {
			return .Blueprint_Graph, comp
		}
		return .Blueprint_Graph, strings.clone(path, allocator)
	}
	if strings.has_suffix(lo, ".odin") && len(base) > len(".odin") {
		if strings.contains(lo, "/hot_scripts/") || strings.contains(lo, "/assets/scripts/") {
			stem := base[:len(base) - len(".odin")]
			if comp, ok := _find_blueprint_companion(stem, dir, allocator); ok {
				return .Blueprint_Graph, comp
			}
		}
	}
	return .Odin_Code, strings.clone(path, allocator)
}

@(private = "file")
_win_shell_launch :: proc(exe_path: string, params: string, win_dir: string) -> bool {
	when ODIN_OS == .Windows {
		w_exe := windows.utf8_to_wstring(exe_path, context.temp_allocator)
		w_params := windows.utf8_to_wstring(params, context.temp_allocator)
		w_dir := windows.utf8_to_wstring(win_dir, context.temp_allocator)
		show_cmd: i32 = strings.has_suffix(strings.to_lower(exe_path, context.temp_allocator), ".cmd") ? 0 : 1
		res := windows.ShellExecuteW(nil, nil, w_exe, w_params, w_dir, show_cmd)
		return int(uintptr(res)) > 32
	} else {
		return false
	}
}

@(private = "file")
_launch_external_ide_preset :: proc(preset: External_IDE_Preset, custom_exe: string, win_r: string, win_f: string, line: int) -> bool {
	when ODIN_OS == .Windows {
		local_app := os.get_env("LOCALAPPDATA", context.temp_allocator)
		prog_files := os.get_env("ProgramFiles", context.temp_allocator)

		_try_vscode_like :: proc(candidates: []string, win_r, win_f: string, line: int) -> bool {
			params := line > 1 \
				? fmt.tprintf("\"%s\" -g \"%s:%d\"", win_r, win_f, line) \
				: fmt.tprintf("\"%s\" -g \"%s\"", win_r, win_f)
			for cand in candidates {
				if cand == "" do continue
				if strings.contains(cand, "\\") || strings.contains(cand, "/") {
					if !os.exists(cand) do continue
				}
				if _win_shell_launch(cand, params, win_r) do return true
			}
			return false
		}

		_try_rider :: proc(prog_files, local_app, win_r, win_f: string, line: int) -> bool {
			params := line > 1 \
				? fmt.tprintf("\"%s\" --line %d \"%s\"", win_r, line, win_f) \
				: fmt.tprintf("\"%s\" \"%s\"", win_r, win_f)
			cands := make([dynamic]string, context.temp_allocator)
			append(&cands, "H:\\JetBrains Rider 2025.3.0.4\\bin\\rider64.exe")
			if prog_files != "" {
				append(&cands, fmt.tprintf("%s\\JetBrains\\JetBrains Rider\\bin\\rider64.exe", prog_files))
				append(&cands, fmt.tprintf("%s\\JetBrains\\Rider\\bin\\rider64.exe", prog_files))
			}
			if local_app != "" {
				append(&cands, fmt.tprintf("%s\\Programs\\Rider\\bin\\rider64.exe", local_app))
			}
			for cand in cands {
				if os.exists(cand) && _win_shell_launch(cand, params, win_r) do return true
			}
			if _win_shell_launch("rider64.exe", params, win_r) do return true
			if _win_shell_launch("rider.exe", params, win_r) do return true
			return false
		}

		_try_custom :: proc(exe: string, win_r, win_f: string, line: int) -> bool {
			if len(exe) == 0 do return false
			clean_exe, _ := filepath.clean(exe, context.temp_allocator)
			abs_exe, err := filepath.abs(clean_exe, context.temp_allocator)
			win_exe, _ := strings.replace_all(err == nil ? abs_exe : clean_exe, "/", "\\", context.temp_allocator)
			exe_lower := strings.to_lower(clean_exe, context.temp_allocator)
			params: string
			if strings.contains(exe_lower, "code") || strings.contains(exe_lower, "cursor") || strings.contains(exe_lower, "antigravity") || strings.contains(exe_lower, "agy") {
				params = line > 1 ? fmt.tprintf("\"%s\" -g \"%s:%d\"", win_r, win_f, line) : fmt.tprintf("\"%s\" -g \"%s\"", win_r, win_f)
			} else {
				params = line > 1 ? fmt.tprintf("\"%s\" --line %d \"%s\"", win_r, line, win_f) : fmt.tprintf("\"%s\" \"%s\"", win_r, win_f)
			}
			return _win_shell_launch(win_exe, params, win_r)
		}

		vscode_cands := [5]string{
			local_app != "" ? fmt.tprintf("%s\\Programs\\Microsoft VS Code\\Code.exe", local_app) : "",
			local_app != "" ? fmt.tprintf("%s\\Programs\\Microsoft VS Code\\bin\\code.cmd", local_app) : "",
			prog_files != "" ? fmt.tprintf("%s\\Microsoft VS Code\\Code.exe", prog_files) : "",
			"code.cmd",
			"code.exe",
		}
		cursor_cands := [4]string{
			local_app != "" ? fmt.tprintf("%s\\Programs\\cursor\\Cursor.exe", local_app) : "",
			local_app != "" ? fmt.tprintf("%s\\Programs\\cursor\\resources\\app\\bin\\cursor.cmd", local_app) : "",
			"cursor.cmd",
			"cursor.exe",
		}
		agy_cands := [5]string{
			local_app != "" ? fmt.tprintf("%s\\Programs\\Antigravity\\Antigravity.exe", local_app) : "",
			local_app != "" ? fmt.tprintf("%s\\Programs\\Antigravity\\bin\\antigravity.cmd", local_app) : "",
			"antigravity.cmd",
			"agy.cmd",
			"antigravity.exe",
		}

		switch preset {
		case .Custom:
			if _try_custom(custom_exe, win_r, win_f, line) do return true
		case .VS_Code:
			if _try_vscode_like(vscode_cands[:], win_r, win_f, line) do return true
		case .Cursor:
			if _try_vscode_like(cursor_cands[:], win_r, win_f, line) do return true
		case .Antigravity:
			if _try_vscode_like(agy_cands[:], win_r, win_f, line) do return true
		case .Rider:
			if _try_rider(prog_files, local_app, win_r, win_f, line) do return true
		case .Auto_Detect:
			if _try_custom(custom_exe, win_r, win_f, line) do return true
			if _try_rider(prog_files, local_app, win_r, win_f, line) do return true
			if _try_vscode_like(vscode_cands[:], win_r, win_f, line) do return true
			if _try_vscode_like(cursor_cands[:], win_r, win_f, line) do return true
			if _try_vscode_like(agy_cands[:], win_r, win_f, line) do return true
		}
		return false
	} else {
		return false
	}
}

// Opens a source script (.odin) directly in the configured external IDE (Rider, VS Code,
// Cursor, Antigravity, or Custom executable) with project/engine workspace context.
open_script_in_external_ide :: proc(file_path: string, line: int = 1) -> bool {
	resolved, ok := resolve_source_file_path(file_path)
	target_file := resolved if ok else file_path

	clean_f, _ := filepath.clean(target_file, context.temp_allocator)
	abs_f, _ := filepath.abs(clean_f, context.temp_allocator)
	win_f, _ := strings.replace_all(abs_f, "/", "\\", context.temp_allocator)
	norm_f, _ := strings.replace_all(abs_f, "\\", "/", context.temp_allocator)

	root := ""
	if engine.has_active_project() {
		proj_norm, _ := strings.replace_all(engine.active_project_root(), "\\", "/", context.temp_allocator)
		proj_norm = strings.trim_right(proj_norm, "/")
		if proj_norm != "" && len(norm_f) >= len(proj_norm) && strings.equal_fold(norm_f[:len(proj_norm)], proj_norm) {
			root = proj_norm
		}
	}
	if root == "" {
		if eng_root := engine.engine_root(context.temp_allocator); eng_root != "" {
			root = eng_root
		} else {
			root = get_workspace_root()
		}
	}
	clean_r, _ := filepath.clean(root, context.temp_allocator)
	abs_r, _ := filepath.abs(clean_r, context.temp_allocator)
	win_r, _ := strings.replace_all(abs_r, "/", "\\", context.temp_allocator)

	custom_exe := _ide_custom_exe != "" ? _ide_custom_exe : settings.ide_executable
	if _launch_external_ide_preset(_ide_preset, custom_exe, win_r, win_f, line) {
		return true
	}
	return open_in_os(target_file)
}

// Unified jump-to-script entry point used by File Explorer, Inspector, and Hierarchy:
// delegates to `open_script_smart_fn` (routes `.bodin` -> Blueprint Studio and `.odin` ->
// Odin Micro-Studio or External IDE per settings), falling back to external IDE.
open_script_in_ide :: proc(file_path: string, line: int = 1) -> bool {
	if open_script_smart_fn != nil {
		return open_script_smart_fn(file_path, line)
	}
	return open_script_in_external_ide(file_path, line)
}

create_folder :: proc(parent_dir: string, name: string) -> (string, bool) {
	trimmed := strings.trim_space(name)
	if len(trimmed) == 0 do return "", false
	full, _ := filepath.join({parent_dir, trimmed}, context.temp_allocator)
	err := os.make_directory(full)
	if err != nil do return "", false
	return strings.clone(full), true
}

create_file :: proc(parent_dir: string, filename: string, content: string) -> (string, bool) {
	trimmed := strings.trim_space(filename)
	if len(trimmed) == 0 do return "", false
	full, _ := filepath.join({parent_dir, trimmed}, context.temp_allocator)
	err := os.write_entire_file(full, content)
	if err != nil do return "", false
	return strings.clone(full), true
}

delete_entry :: proc(path: string) -> bool {
	clean_p, _ := filepath.clean(path, context.temp_allocator)
	if !os.exists(clean_p) do return false

	ok := engine.os_move_to_trash(clean_p)
	if ok {
		meta_p := fmt.tprintf("%s.meta", clean_p)
		if os.exists(meta_p) {
			_ = engine.os_move_to_trash(meta_p)
		}
		engine.asset_db_request_refresh()
	}
	return ok
}

rename_entry :: proc(old_path: string, new_name: string) -> (string, bool) {
	trimmed := strings.trim_space(new_name)
	if len(trimmed) == 0 do return "", false
	if !os.is_dir(old_path) {
		old_ext := filepath.ext(old_path)
		new_ext := filepath.ext(trimmed)
		if len(old_ext) > 0 && len(new_ext) == 0 {
			trimmed = fmt.tprintf("%s%s", trimmed, old_ext)
		}
	}
	dir := filepath.dir(old_path)
	new_full, _ := filepath.join({dir, trimmed}, context.temp_allocator)
	norm_new, _ := strings.replace_all(new_full, "\\", "/", context.temp_allocator)
	err := os.rename(old_path, norm_new)
	if err != nil do return "", false
	old_meta := fmt.tprintf("%s.meta", old_path)
	if os.exists(old_meta) {
		new_meta := fmt.tprintf("%s.meta", norm_new)
		_ = os.rename(old_meta, new_meta)
	}
	return strings.clone(norm_new), true
}

@(private = "file")
_sync_odin_scripts_in_dir_recursive :: proc(dir_path: string) {
	handle, err := os.open(dir_path)
	if err != nil do return
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for e in entries {
		child, _ := filepath.join({dir_path, e.name}, context.temp_allocator)
		norm_child, _ := strings.replace_all(child, "\\", "/", context.temp_allocator)
		if e.type == .Directory {
			_sync_odin_scripts_in_dir_recursive(norm_child)
		} else if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".odin") {
			_ = sync_odin_script_package_for_dir(norm_child)
		}
	}
}

// Moves a file or folder into `dest_dir`, preserving any `.meta` sidecar file,
// preventing moving a folder into itself/descendant, and syncing `.odin` package headers.
move_entry :: proc(src_path: string, dest_dir: string) -> (string, bool) {
	clean_src, _ := filepath.clean(src_path, context.temp_allocator)
	norm_src, _ := strings.replace_all(clean_src, "\\", "/", context.temp_allocator)
	clean_dest, _ := filepath.clean(dest_dir, context.temp_allocator)
	norm_dest, _ := strings.replace_all(clean_dest, "\\", "/", context.temp_allocator)

	if !os.exists(norm_src) || !os.exists(norm_dest) || !os.is_dir(norm_dest) {
		return "", false
	}

	if norm_src == norm_dest do return "", false

	src_parent, _ := filepath.clean(filepath.dir(norm_src), context.temp_allocator)
	norm_parent, _ := strings.replace_all(src_parent, "\\", "/", context.temp_allocator)
	if norm_parent == norm_dest do return "", false

	is_dir := os.is_dir(norm_src)
	if is_dir {
		src_prefix := fmt.tprintf("%s/", norm_src)
		if strings.has_prefix(norm_dest, src_prefix) {
			return "", false // Cannot move a directory into its own subdirectory
		}
	}

	base := filepath.base(norm_src)
	if base == "" || base == "." || base == ".." do return "", false

	target_joined, _ := filepath.join({norm_dest, base}, context.temp_allocator)
	norm_target, _ := strings.replace_all(target_joined, "\\", "/", context.temp_allocator)
	if os.exists(norm_target) {
		return "", false // Do not silently overwrite an existing file or folder
	}

	if os.rename(norm_src, norm_target) != nil {
		return "", false
	}

	old_meta := fmt.tprintf("%s.meta", norm_src)
	if os.exists(old_meta) {
		new_meta := fmt.tprintf("%s.meta", norm_target)
		_ = os.rename(old_meta, new_meta)
	}

	if is_dir {
		_sync_odin_scripts_in_dir_recursive(norm_target)
	} else {
		_ = sync_odin_script_package_for_dir(norm_target)
	}

	engine.asset_db_request_refresh()
	return strings.clone(norm_target), true
}

get_unique_copy_path :: proc(src_path: string, dest_dir: string) -> string {
	clean_src, _ := filepath.clean(src_path, context.temp_allocator)
	norm_src, _ := strings.replace_all(clean_src, "\\", "/", context.temp_allocator)
	clean_dest, _ := filepath.clean(dest_dir, context.temp_allocator)
	norm_dest, _ := strings.replace_all(clean_dest, "\\", "/", context.temp_allocator)

	is_dir := os.is_dir(norm_src)
	base := filepath.base(norm_src)
	src_parent := filepath.dir(norm_src)

	same_dir := (src_parent == norm_dest)

	if is_dir {
		target_name := base
		if same_dir {
			target_name = fmt.tprintf("%s_copy", base)
		}
		candidate, _ := filepath.join({norm_dest, target_name}, context.temp_allocator)
		norm_cand, _ := strings.replace_all(candidate, "\\", "/", context.temp_allocator)
		if !os.exists(norm_cand) do return norm_cand

		for i := 2; i < 1000; i += 1 {
			target_name = fmt.tprintf("%s_copy_%d", base, i)
			candidate, _ = filepath.join({norm_dest, target_name}, context.temp_allocator)
			norm_cand, _ = strings.replace_all(candidate, "\\", "/", context.temp_allocator)
			if !os.exists(norm_cand) do return norm_cand
		}
		return norm_cand
	} else {
		stem := filepath.stem(base)
		ext := filepath.ext(base)

		target_name := base
		if same_dir {
			target_name = fmt.tprintf("%s_copy%s", stem, ext)
		}
		candidate, _ := filepath.join({norm_dest, target_name}, context.temp_allocator)
		norm_cand, _ := strings.replace_all(candidate, "\\", "/", context.temp_allocator)
		if !os.exists(norm_cand) do return norm_cand

		for i := 2; i < 1000; i += 1 {
			target_name = fmt.tprintf("%s_copy_%d%s", stem, i, ext)
			candidate, _ = filepath.join({norm_dest, target_name}, context.temp_allocator)
			norm_cand, _ = strings.replace_all(candidate, "\\", "/", context.temp_allocator)
			if !os.exists(norm_cand) do return norm_cand
		}
		return norm_cand
	}
}

copy_dir_recursive :: proc(src_dir: string, dest_dir: string) -> bool {
	return engine.asset_fs_copy_recursive(src_dir, dest_dir, keep_meta_files = false)
}

copy_entry :: proc(src_path: string, dest_dir: string) -> (string, bool) {
	if !os.exists(src_path) || !os.exists(dest_dir) do return "", false
	target_path := get_unique_copy_path(src_path, dest_dir)
	is_dir := os.is_dir(src_path)
	if is_dir {
		ok := copy_dir_recursive(src_path, target_path)
		if ok do return strings.clone(target_path), true
		return "", false
	} else {
		when ODIN_OS == .Windows {
			src_w := windows.utf8_to_wstring(src_path, context.temp_allocator)
			dest_w := windows.utf8_to_wstring(target_path, context.temp_allocator)
			if bool(windows.CopyFileW(src_w, dest_w, false)) {
				_ = sync_odin_script_package_for_dir(target_path)
				return strings.clone(target_path), true
			}
		}
		bytes, err := os.read_entire_file(src_path, context.temp_allocator)
		if err != nil do return "", false
		werr := os.write_entire_file(target_path, bytes)
		if werr != nil do return "", false
		_ = sync_odin_script_package_for_dir(target_path)
		return strings.clone(target_path), true
	}
}

// ─────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────
// LEVEL / SCENE CREATION
// ─────────────────────────────────────────────────────────────

LEVEL_TEMPLATE_EMPTY :: `{"root": 1, "transforms": [{"local_id": 1, "name": "Root", "is_active": true, "position": [0.0, 0.0, 0.0], "rotation": [0.0, 0.0, 0.0, 1.0], "scale": [1.0, 1.0, 1.0], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}]}`

create_level_scene :: proc(dir: string, name: string, template_idx: int = 0) -> (string, bool) {
	trimmed := strings.trim_space(name)
	if len(trimmed) == 0 do return "", false
	if !strings.has_suffix(strings.to_lower(trimmed, context.temp_allocator), ".scene") {
		trimmed = fmt.tprintf("%s.scene", trimmed)
	}
	return create_file(dir, trimmed, LEVEL_TEMPLATE_EMPTY)
}

// ─────────────────────────────────────────────────────────────
// ODIN SCRIPT CREATION & PACKAGE HEADER SYNC
// ─────────────────────────────────────────────────────────────

// Computes the required Odin `package <name>` declaration for any directory:
// 1. If sibling `.odin` files already exist in `dir`, matches their `package <name>` declaration so compilation never breaks.
// 2. Otherwise computes the package name from `plugins/<root>/<sub...>` or the folder basename.
expected_odin_package_for_dir :: proc(dir: string, exclude_file: string = "") -> string {
	clean_dir, _ := filepath.clean(dir, context.temp_allocator)
	norm_dir, _ := strings.replace_all(clean_dir, "\\", "/", context.temp_allocator)
	exclude_base := filepath.base(exclude_file) if len(exclude_file) > 0 else ""

	if h, err := os.open(clean_dir); err == nil {
		defer os.close(h)
		if entries, rerr := os.read_dir(h, -1, context.temp_allocator); rerr == nil {
			defer os.file_info_slice_delete(entries, context.temp_allocator)
			for e in entries {
				if e.type == .Directory do continue
				if len(exclude_base) > 0 && strings.equal_fold(e.name, exclude_base) do continue
				if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".odin") {
					sib_path, _ := filepath.join({clean_dir, e.name}, context.temp_allocator)
					if raw, ferr := os.read_entire_file(sib_path, context.temp_allocator); ferr == nil {
						for line in strings.split_lines(string(raw), context.temp_allocator) {
							trimmed := strings.trim_space(line)
							if strings.has_prefix(trimmed, "package ") {
								fields := strings.fields(trimmed, context.temp_allocator)
								if len(fields) >= 2 && len(fields[1]) > 0 {
									return fields[1]
								}
							}
						}
					}
				}
			}
		}
	}

	norm_dir = strings.trim(norm_dir, "/")
	if engine.has_active_project() {
		proj_root, _ := strings.replace_all(engine.active_project_root(), "\\", "/", context.temp_allocator)
		proj_root = strings.trim_right(proj_root, "/")
		if norm_dir == "." || norm_dir == "" || (len(norm_dir) == len(proj_root) && strings.equal_fold(norm_dir, proj_root)) {
			if slug := engine.active_project_slug(context.temp_allocator); slug != "" do return slug
		}
		proj_prefix := strings.concatenate({proj_root, "/"}, context.temp_allocator)
		if len(norm_dir) > len(proj_prefix) && strings.equal_fold(norm_dir[:len(proj_prefix)], proj_prefix) {
			rest := strings.trim(norm_dir[len(proj_prefix):], "/")
			if len(rest) > 0 {
				flat, _ := strings.replace_all(rest, "/", "_", context.temp_allocator)
				flat, _ = strings.replace_all(flat, "-", "_", context.temp_allocator)
				return flat
			}
		}
	}
	for marker in ([?]string{"plugins/", "packages/"}) {
		if idx := strings.index(norm_dir, marker); idx >= 0 {
			rest := strings.trim(norm_dir[idx + len(marker):], "/")
			if len(rest) > 0 {
				flat, _ := strings.replace_all(rest, "/", "_", context.temp_allocator)
				return flat
			}
		}
	}
	base := filepath.base(norm_dir)
	if len(base) > 0 && base != "." && base != ".." {
		flat, _ := strings.replace_all(base, "-", "_", context.temp_allocator)
		return flat
	}
	if slug := engine.active_project_slug(context.temp_allocator); slug != "" do return slug
	return "game"
}

// Updates the top-of-file `package <old>` declaration of a `.odin` script when copied or moved to a new folder.
sync_odin_script_package_for_dir :: proc(file_path: string) -> bool {
	if !strings.has_suffix(strings.to_lower(file_path, context.temp_allocator), ".odin") {
		return false
	}
	raw_bytes, err := os.read_entire_file(file_path, context.temp_allocator)
	if err != nil do return false
	content := string(raw_bytes)
	expected_pkg := expected_odin_package_for_dir(filepath.dir(file_path), file_path)
	if len(expected_pkg) == 0 do return false

	lines := strings.split_lines(content, context.temp_allocator)
	changed := false
	for &line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "package ") {
			new_decl := fmt.tprintf("package %s", expected_pkg)
			if trimmed != new_decl {
				line = new_decl
				changed = true
			}
			break
		}
	}
	if changed {
		joined := strings.join(lines, "\n", context.temp_allocator)
		_ = os.write_entire_file(file_path, joined)
	}
	return changed
}

create_odin_script :: proc(dir: string, name: string, template_idx: int = 0) -> (string, bool) {
	trimmed := strings.trim_space(name)
	if len(trimmed) == 0 do return "", false
	stem := trimmed
	if strings.has_suffix(strings.to_lower(stem, context.temp_allocator), ".odin") {
		stem = stem[:len(stem) - 5]
	} else {
		trimmed = fmt.tprintf("%s.odin", trimmed)
	}

	b := strings.builder_make(context.temp_allocator)
	for r, idx in stem {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_' || (idx > 0 && r >= '0' && r >= '9') {
			strings.write_rune(&b, r)
		}
	}
	struct_name := strings.to_string(b)
	if len(struct_name) == 0 do struct_name = "NewComponent"

	pkg_name := expected_odin_package_for_dir(dir)
	content := format_new_component_scaffold(pkg_name, struct_name)
	return create_file(dir, trimmed, content)
}

format_new_component_scaffold :: proc(pkg_name, struct_name: string, allocator := context.temp_allocator) -> string {
	seed := fmt.tprintf("%s.%s", pkg_name, struct_name)
	h1 := hash.fnv64a(transmute([]u8)seed)
	h2: u64 = 1099511628211
	for b_ch in transmute([]u8)seed {
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
	return fmt.aprintf(
		"package %s\n\nimport \"haati:engine\"\n\n@" + "(component={{menu=\"Void/%s\"}})\n@" + "(typ_guid={{guid = \"%s\"}})\n%s :: struct {{\n\tusing base: engine.CompData,\n\t// Tip: Use engine.Ref_Local to reference a Scene Node,\n\t// or f32, int, bool, [3]f32 for tunable Inspector variables.\n}}\n\nreset_%s :: proc(c: ^%s) {{\n}}\n",
		pkg_name,
		struct_name,
		guid_str,
		struct_name,
		struct_name,
		struct_name,
		allocator = allocator,
	)
}
