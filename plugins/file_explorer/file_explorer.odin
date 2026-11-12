package file_explorer

// Godot & Unreal Engine 5 style File Explorer & Content Browser for MoonHug.
// Provides grid/thumbnail cards, details list, recursive directory tree,
// Quick Access bookmarks (Game project, Assets, Godot import, Plugins),
// instant search, Windows Explorer reveal, and one-click level/script creation.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:sys/windows"
import engine "moonhug:engine"

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

File_Explorer_Settings :: struct {
	show_hidden:       bool,
	grid_card_size:    f32,
	is_grid_view:      bool,
	auto_refresh_sec:  f32,
	ide_executable:    string,
}

@(project_settings={name="Void File Explorer"})
settings := File_Explorer_Settings{
	show_hidden      = false,
	grid_card_size   = 86.0,
	is_grid_view     = true,
	auto_refresh_sec = 2.0,
	ide_executable   = "",
}

@(phase={key=SerializationInit, order=10})
_register_file_explorer_settings_types :: proc() {
	engine.register_pointer_type(File_Explorer_Settings)
}

get_workspace_root :: proc() -> string {
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
	_bookmarks = make([dynamic]Bookmark)
	append(&_bookmarks, Bookmark{
		label = strings.clone("Game (Void_Odin)"),
		path  = resolve_workspace_path("plugins/void_odin"),
		icon  = "\uf720",
	})
	append(&_bookmarks, Bookmark{
		label = strings.clone("Game Assets"),
		path  = resolve_workspace_path("plugins/void_odin/assets"),
		icon  = "\ue2c7",
	})
	append(&_bookmarks, Bookmark{
		label = strings.clone("Godot Project"),
		path  = resolve_workspace_path("Godot test"),
		icon  = "\ue1bd",
	})
	append(&_bookmarks, Bookmark{
		label = strings.clone("Control Rig"),
		path  = resolve_workspace_path("plugins/control_rig/assets"),
		icon  = "\ue71c",
	})
	append(&_bookmarks, Bookmark{
		label = strings.clone("All Plugins"),
		path  = resolve_workspace_path("plugins"),
		icon  = "\ue87b",
	})
	append(&_bookmarks, Bookmark{
		label = strings.clone("Workspace Root"),
		path  = strings.clone(get_workspace_root()),
		icon  = "\ue2c8",
	})
	append(&_bookmarks, Bookmark{
		label = strings.clone("Engine Core (moonhug)"),
		path  = resolve_workspace_path("moonhug"),
		icon  = "\ue869",
	})
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
	lower_buf := make([]u8, len(s), allocator)
	norm_buf := make([dynamic]u8, 0, len(s), allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch >= 'A' && ch <= 'Z' {
			ch += 'a' - 'A'
		}
		lower_buf[i] = ch
		if ch != '_' && ch != '-' && ch != ' ' && ch != '.' && ch != '/' && ch != '\\' {
			append(&norm_buf, ch)
		}
	}
	return string(lower_buf), string(norm_buf[:])
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

Prepared_Query :: struct {
	raw_lower:  string,
	norm:       string,
	terms:      [8]string,
	term_norms: [8]string,
	term_count: int,
}

prepare_search_query :: proc(query: string, allocator := context.temp_allocator) -> Prepared_Query {
	trimmed := strings.trim_space(query)
	if len(trimmed) == 0 do return {}

	pq: Prepared_Query
	pq.raw_lower, pq.norm = normalize_search_key(trimmed, allocator)

	fields := strings.fields(pq.raw_lower, allocator)
	if len(fields) > 1 {
		pq.term_count = min(len(fields), len(pq.terms))
		for i in 0 ..< pq.term_count {
			pq.terms[i] = fields[i]
			_, pq.term_norms[i] = normalize_search_key(fields[i], allocator)
		}
	}
	return pq
}

// Pure, lock-free, zero-allocation predicate safe to execute across worker threads.
item_matches_prepared_query :: proc(item: File_Item, pq: ^Prepared_Query) -> bool {
	if len(pq.raw_lower) == 0 do return true

	// 1. Direct substring match on filename (only match full path when query explicitly contains a path separator)
	if strings.contains(item.name_lower, pq.raw_lower) do return true
	if (strings.contains_rune(pq.raw_lower, '/') || strings.contains_rune(pq.raw_lower, '\\')) &&
	   strings.contains(item.path_lower, pq.raw_lower) {
		return true
	}

	// 2. Delimiter-stripped normalized match on filename (e.g. "node3" matches "node_3.odin")
	if len(pq.norm) > 0 && strings.contains(item.name_norm, pq.norm) do return true

	// 3. Multi-word terms match (all terms must match either name_lower, path_lower, or name_norm,
	//    and at least one term must match the item's own filename so parent folder names alone don't match every child)
	if pq.term_count > 1 {
		any_name_match := false
		for i in 0 ..< pq.term_count {
			t := pq.terms[i]
			tn := pq.term_norms[i]
			name_hit := strings.contains(item.name_lower, t) || (len(tn) > 0 && strings.contains(item.name_norm, tn))
			if name_hit do any_name_match = true
			matched := name_hit || strings.contains(item.path_lower, t)
			if !matched do return false
		}
		return any_name_match
	}

	return false
}

// Returns true when `new_query` is a strict narrowing refinement of `old_query`
// (e.g. user typed additional characters at the end or beginning of `old_query`),
// allowing the search engine to slice and filter ONLY the previous match list
// instead of rescanning the full scope index.
can_narrow_search_query :: proc(old_query: string, new_query: string) -> bool {
	old_t := strings.trim_space(old_query)
	new_t := strings.trim_space(new_query)
	if len(old_t) == 0 || len(new_t) <= len(old_t) do return false

	old_lo := strings.to_lower(old_t, context.temp_allocator)
	new_lo := strings.to_lower(new_t, context.temp_allocator)
	return strings.contains(new_lo, old_lo)
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
	win_p := canonicalize_os_path(path, context.temp_allocator)

	when ODIN_OS == .Windows {
		is_dir := os.is_dir(win_p) || os.is_dir(path)
		if is_dir {
			op := windows.utf8_to_wstring("open", context.temp_allocator)
			file := windows.utf8_to_wstring("explorer.exe", context.temp_allocator)
			prms := windows.utf8_to_wstring(win_p, context.temp_allocator)
			res := windows.ShellExecuteW(nil, op, file, prms, nil, 1)
			return int(uintptr(res)) > 32
		} else {
			params := fmt.tprintf("/select,\"%s\"", win_p)
			op := windows.utf8_to_wstring("open", context.temp_allocator)
			file := windows.utf8_to_wstring("explorer.exe", context.temp_allocator)
			prms := windows.utf8_to_wstring(params, context.temp_allocator)
			res := windows.ShellExecuteW(nil, op, file, prms, nil, 1)
			return int(uintptr(res)) > 32
		}
	} else {
		return false
	}
}

// Open file or directory using system default program
open_in_os :: proc(path: string) -> bool {
	win_p := canonicalize_os_path(path, context.temp_allocator)

	when ODIN_OS == .Windows {
		op := windows.utf8_to_wstring("open", context.temp_allocator)
		target := windows.utf8_to_wstring(win_p, context.temp_allocator)
		res := windows.ShellExecuteW(nil, op, target, nil, nil, 1)
		return int(uintptr(res)) > 32
	} else {
		return false
	}
}

// Resolves any source file path (relative, plugin-relative, or moonhug/packages-relative)
// to a canonical, guaranteed-existing absolute path on disk without path-doubling bugs.
resolve_source_file_path :: proc(raw_path: string, allocator := context.temp_allocator) -> (abs_path: string, ok: bool) {
	if len(raw_path) == 0 do return "", false

	norm_raw, _ := strings.replace_all(raw_path, "\\", "/", allocator)

	// If already absolute and exists
	if filepath.is_abs(norm_raw) && os.exists(norm_raw) {
		abs, err := filepath.abs(norm_raw, allocator)
		if err == nil do return abs, true
		return strings.clone(norm_raw, allocator), true
	}

	ws_root := get_workspace_root()
	ws_abs, _ := filepath.abs(ws_root, allocator)

	// Test candidates in order of workspace specificity
	candidates := make([dynamic]string, allocator)

	// 1. If path starts with "moonhug/packages/<pkg>/..." -> map to "<ws_abs>/plugins/<pkg>/..."
	if strings.has_prefix(norm_raw, "moonhug/packages/") {
		sub := norm_raw[len("moonhug/packages/"):]
		c1, _ := filepath.join({ws_abs, "plugins", sub}, allocator)
		append(&candidates, c1)
		c2, _ := filepath.join({ws_abs, "moonhug", "packages", sub}, allocator)
		append(&candidates, c2)
		c3, _ := filepath.join({".", "packages", sub}, allocator)
		append(&candidates, c3)
	}

	// 2. If path starts with "packages/<pkg>/..." -> map to "<ws_abs>/plugins/<pkg>/..."
	if strings.has_prefix(norm_raw, "packages/") {
		sub := norm_raw[len("packages/"):]
		c1, _ := filepath.join({ws_abs, "plugins", sub}, allocator)
		append(&candidates, c1)
		c2, _ := filepath.join({ws_abs, "moonhug", "packages", sub}, allocator)
		append(&candidates, c2)
		c3, _ := filepath.join({".", "packages", sub}, allocator)
		append(&candidates, c3)
	}

	// 3. Direct relative to workspace root (e.g. "plugins/...", "moonhug/engine/...")
	c_ws, _ := filepath.join({ws_abs, norm_raw}, allocator)
	append(&candidates, c_ws)

	// 4. If path starts with "moonhug/" and we are running inside "moonhug" cwd:
	if strings.has_prefix(norm_raw, "moonhug/") {
		sub := norm_raw[len("moonhug/"):]
		c_s1, _ := filepath.join({ws_abs, sub}, allocator)
		append(&candidates, c_s1)
		c_s2, _ := filepath.join({".", sub}, allocator)
		append(&candidates, c_s2)
	}

	// 5. Direct relative to current working directory
	append(&candidates, norm_raw)

	for cand in candidates {
		clean_c, _ := filepath.clean(cand, allocator)
		if os.exists(clean_c) {
			abs, err := filepath.abs(clean_c, allocator)
			if err == nil do return abs, true
			return strings.clone(clean_c, allocator), true
		}
	}

	fallback, _ := filepath.join({ws_abs, norm_raw}, allocator)
	return fallback, false
}

// Opens a source script (.odin) inside an IDE (Rider / VS Code) WITH the workspace project context,
// preventing Rider from treating individual scripts as isolated temporary projects and losing the Odin SDK toolchain.
// Supports jumping directly to a definition line.
open_script_in_ide :: proc(file_path: string, line: int = 1) -> bool {
	resolved, ok := resolve_source_file_path(file_path)
	target_file := resolved if ok else file_path

	clean_f, _ := filepath.clean(target_file, context.temp_allocator)
	abs_f, _ := filepath.abs(clean_f, context.temp_allocator)
	win_f, _ := strings.replace_all(abs_f, "/", "\\", context.temp_allocator)

	root := get_workspace_root()
	clean_r, _ := filepath.clean(root, context.temp_allocator)
	abs_r, _ := filepath.abs(clean_r, context.temp_allocator)
	win_r, _ := strings.replace_all(abs_r, "/", "\\", context.temp_allocator)

	when ODIN_OS == .Windows {
		w_dir := windows.utf8_to_wstring(win_r, context.temp_allocator)

		// 1. User-configured custom IDE executable in Project Settings ("Void File Explorer" settings)
		if len(settings.ide_executable) > 0 {
			clean_exe, _ := filepath.clean(settings.ide_executable, context.temp_allocator)
			abs_exe, _ := filepath.abs(clean_exe, context.temp_allocator)
			win_exe, _ := strings.replace_all(abs_exe, "/", "\\", context.temp_allocator)
			w_exe := windows.utf8_to_wstring(win_exe, context.temp_allocator)

			exe_lower, _ := strings.to_lower(clean_exe, context.temp_allocator)
			params: string
			if strings.contains(exe_lower, "rider") {
				if line > 1 {
					params = fmt.tprintf("\"%s\" --line %d \"%s\"", win_r, line, win_f)
				} else {
					params = fmt.tprintf("\"%s\" \"%s\"", win_r, win_f)
				}
			} else if strings.contains(exe_lower, "code") {
				if line > 1 {
					params = fmt.tprintf("\"%s\" -g \"%s:%d\"", win_r, win_f, line)
				} else {
					params = fmt.tprintf("\"%s\" -g \"%s\"", win_r, win_f)
				}
			} else {
				if line > 1 {
					params = fmt.tprintf("\"%s\" --line %d \"%s\"", win_r, line, win_f)
				} else {
					params = fmt.tprintf("\"%s\" \"%s\"", win_r, win_f)
				}
			}
			w_params := windows.utf8_to_wstring(params, context.temp_allocator)
			res := windows.ShellExecuteW(nil, nil, w_exe, w_params, w_dir, 1)
			if int(uintptr(res)) > 32 do return true
		}

		// 2. JetBrains Rider CLI: syntax is `rider64.exe "<project_dir>" --line <line> "<file_path>"`
		// Passing the project directory as the first argument ensures Rider targets the existing
		// project window, loads .idea/OdinSdkConfig.xml, and retains the configured Odin toolchain.
		params_rider := fmt.tprintf("\"%s\" --line %d \"%s\"", win_r, line, win_f) if line > 1 else fmt.tprintf("\"%s\" \"%s\"", win_r, win_f)
		w_params_rider := windows.utf8_to_wstring(params_rider, context.temp_allocator)

		// Check known standard install paths
		known_rider_paths := []string{
			"H:\\JetBrains Rider 2025.3.0.4\\bin\\rider64.exe",
			"C:\\Program Files\\JetBrains\\JetBrains Rider\\bin\\rider64.exe",
			"C:\\Program Files\\JetBrains\\Rider\\bin\\rider64.exe",
		}
		for rp in known_rider_paths {
			if os.exists(rp) {
				w_rp := windows.utf8_to_wstring(rp, context.temp_allocator)
				res_known := windows.ShellExecuteW(nil, nil, w_rp, w_params_rider, w_dir, 1)
				if int(uintptr(res_known)) > 32 do return true
			}
		}

		w_rider64 := windows.utf8_to_wstring("rider64.exe", context.temp_allocator)
		res64 := windows.ShellExecuteW(nil, nil, w_rider64, w_params_rider, w_dir, 1)
		if int(uintptr(res64)) > 32 do return true

		w_rider := windows.utf8_to_wstring("rider.exe", context.temp_allocator)
		res_r := windows.ShellExecuteW(nil, nil, w_rider, w_params_rider, w_dir, 1)
		if int(uintptr(res_r)) > 32 do return true

		// 3. VS Code: `code.exe "<project_dir>" -g "<file_path>:<line>"`
		params_code := fmt.tprintf("\"%s\" -g \"%s:%d\"", win_r, win_f, line) if line > 1 else fmt.tprintf("\"%s\" -g \"%s\"", win_r, win_f)
		w_params_code := windows.utf8_to_wstring(params_code, context.temp_allocator)
		w_code := windows.utf8_to_wstring("code.exe", context.temp_allocator)
		res_c := windows.ShellExecuteW(nil, nil, w_code, w_params_code, w_dir, 1)
		if int(uintptr(res_c)) > 32 do return true

		// 4. Fallback to OS file association
		return open_in_os(target_file)
	} else {
		return open_in_os(target_file)
	}
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

	ok := false
	if os.is_dir(clean_p) {
		ok = os.remove_all(clean_p) == nil
	} else {
		if os.remove(clean_p) == nil {
			ok = true
		} else {
			when ODIN_OS == .Windows {
				win_p, _ := strings.replace_all(clean_p, "/", "\\", context.temp_allocator)
				wp := windows.utf8_to_wstring(win_p, context.temp_allocator)
				ok = bool(windows.DeleteFileW(wp))
			}
		}
	}

	if ok {
		meta_p := fmt.tprintf("%s.meta", clean_p)
		if os.exists(meta_p) {
			_ = os.remove(meta_p)
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
	clean_src, _ := filepath.clean(src_dir, context.temp_allocator)
	norm_src, _ := strings.replace_all(clean_src, "\\", "/", context.temp_allocator)
	clean_dest, _ := filepath.clean(dest_dir, context.temp_allocator)
	norm_dest, _ := strings.replace_all(clean_dest, "\\", "/", context.temp_allocator)

	_ = os.make_directory(norm_dest)

	handle, err := os.open(norm_src)
	if err != nil do return false
	defer os.close(handle)

	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return false

	for entry in entries {
		s_child, _ := filepath.join({norm_src, entry.name}, context.temp_allocator)
		d_child, _ := filepath.join({norm_dest, entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			if !copy_dir_recursive(s_child, d_child) do return false
		} else {
			when ODIN_OS == .Windows {
				sw := windows.utf8_to_wstring(s_child, context.temp_allocator)
				dw := windows.utf8_to_wstring(d_child, context.temp_allocator)
				if !bool(windows.CopyFileW(sw, dw, false)) {
					b, _ := os.read_entire_file(s_child, context.temp_allocator)
					_ = os.write_entire_file(d_child, b)
				}
			} else {
				b, _ := os.read_entire_file(s_child, context.temp_allocator)
				_ = os.write_entire_file(d_child, b)
			}
		}
	}
	return true
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
	return "void_odin"
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

	content := fmt.tprintf(
		"package %s\n\nimport \"moonhug:engine\"\n\n@" + "(component={{menu=\"Void/%s\"}})\n@" + "(typ_guid={{guid = \"%s\"}})\n%s :: struct {{\n\tusing base: engine.CompData,\n\t// Tip: Use engine.Ref_Local to reference a Scene Node,\n\t// or f32, int, bool, [3]f32 for tunable Inspector variables.\n}}\n\nreset_%s :: proc(c: ^%s) {{\n}}\n",
		pkg_name,
		struct_name,
		guid_str,
		struct_name,
		struct_name,
		struct_name,
	)

	return create_file(dir, trimmed, content)
}
