package editor

// Cached directory listings for the project view. Both panes used to hit the
// filesystem EVERY FRAME — draw_file_list re-read + re-sorted the current
// folder, draw_directory_tree re-read every open tree folder, and
// _project_dir_has_subdir re-scanned per visible node — with a sort
// comparator calling the ALLOCATING strings.to_lower per comparison. At
// 120 fps that was the editor's single biggest CPU consumer (profiled).
//
// Listings are sorted once per scan (case-insensitive, keys computed once)
// and cached per path. Invalidation: explicitly after editor-side file
// mutations (rename, file ops, asset refresh on focus), plus a short TTL so
// external changes still show up quickly — same "no file watcher" stance as
// the asset db, at 2 Hz instead of 120 Hz.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import strings "core:strings"

Project_Dir_Entry :: struct {
	name:    string, // owned
	is_dir:  bool,
	is_link: bool, // a symlink (is_dir says what it points at); drawn with its own icon
}

@(private = "file")
_Dir_Listing :: struct {
	entries: []Project_Dir_Entry, // owned; sorted case-insensitive, dirs mixed
	ok:      bool,                // false = the scan itself failed
}

@(private = "file")
_dir_listings: map[string]_Dir_Listing // keys owned

// Sorted listing of `path`. Cached in memory until invalidated by editor-side
// file operations or by the background asset_db_refresh_async worker detecting
// filesystem deltas (never blocks the render loop every 500ms with disk I/O).
project_dir_listing :: proc(path: string) -> (entries: []Project_Dir_Entry, ok: bool) {
	if l, found := _dir_listings[path]; found {
		return l.entries, l.ok
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _dir_listings == nil {
		_dir_listings = make(map[string]_Dir_Listing, 0, runtime.default_allocator())
	}
	fresh, scan_ok := _dir_scan(path)
	_dir_listings[strings.clone(path, runtime.default_allocator())] = _Dir_Listing{entries = fresh, ok = scan_ok}
	return fresh, scan_ok
}

// Drop everything — call after any editor-side file mutation so the UI
// updates the same frame (external changes ride the TTL).
project_dir_cache_invalidate :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for k, l in _dir_listings {
		_listing_free(l)
		delete(k, runtime.default_allocator())
	}
	clear(&_dir_listings)
}

project_dir_cache_shutdown :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	project_dir_cache_invalidate()
	delete(_dir_listings)
	_dir_listings = nil
}

@(private = "file")
_listing_free :: proc(l: _Dir_Listing) {
	for e in l.entries do delete(e.name, runtime.default_allocator())
	delete(l.entries, runtime.default_allocator())
}

@(private = "file")
_dir_scan :: proc(path: string) -> ([]Project_Dir_Entry, bool) {
	handle, err := os.open(path)
	if err != nil do return nil, false
	defer os.close(handle)
	infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return nil, false
	defer os.file_info_slice_delete(infos, context.temp_allocator)

	// Case-insensitive sort with the lowercase key computed ONCE per entry.
	Sort_Row :: struct {
		lower:   string,
		name:    string,
		is_dir:  bool,
		is_link: bool,
	}
	rows := make([dynamic]Sort_Row, 0, len(infos), context.temp_allocator)
	for info in infos {
		// Symlinked dirs (samples installed via symlink) count as dirs —
		// os.is_dir follows the link.
		is_dir := info.type == .Directory
		if !is_dir && info.type == .Symlink {
			full, _ := filepath.join({path, info.name}, context.temp_allocator)
			is_dir = os.is_dir(full)
		}
		append(&rows, Sort_Row{
			lower   = strings.to_lower(info.name, context.temp_allocator),
			name    = info.name,
			is_dir  = is_dir,
			is_link = info.type == .Symlink,
		})
	}
	slice.sort_by(rows[:], proc(a, b: Sort_Row) -> bool {
		return a.lower < b.lower
	})

	out := make([]Project_Dir_Entry, len(rows))
	for r, i in rows {
		out[i] = Project_Dir_Entry{name = strings.clone(r.name), is_dir = r.is_dir, is_link = r.is_link}
	}
	return out, true
}
