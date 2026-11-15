package engine

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "catalog"
import "log"

// Read-only thread-safe Virtual File System backed by a mounted `.pak` archive.
// Positional `os.read_at` reads inside `catalog.pak_read_entry` combined with
// a RW mutex allow concurrent job threads to read entries without extraction
// or mutating shared file offsets.

@(private = "file") _vfs_mu:      sync.RW_Mutex
@(private = "file") _vfs_pak:     catalog.Pak_Archive
@(private = "file") _vfs_mounted: bool

@(private = "file")
_vfs_strip_prefix_ci :: proc(path, prefix: string) -> (rest: string, stripped: bool) {
	if prefix == "" || len(path) < len(prefix) do return path, false
	when ODIN_OS == .Windows {
		lp := strings.to_lower(path[:len(prefix)], context.temp_allocator)
		lpre := strings.to_lower(prefix, context.temp_allocator)
		if lp != lpre do return path, false
	} else {
		if path[:len(prefix)] != prefix do return path, false
	}
	if len(path) == len(prefix) do return "", true
	if path[len(prefix)] == '/' {
		return path[len(prefix)+1:], true
	}
	if strings.has_suffix(prefix, "/") {
		return path[len(prefix):], true
	}
	return path, false
}

@(private = "file")
_vfs_collapse_segments :: proc(raw_slashed: string, allocator := context.temp_allocator) -> string {
	drive := ""
	rest := raw_slashed
	if len(rest) >= 2 && rest[1] == ':' {
		drive = rest[:2]
		rest = rest[2:]
	}
	has_leading_slash := len(rest) > 0 && rest[0] == '/'
	parts := strings.split(rest, "/", context.temp_allocator)
	stack := make([dynamic]string, 0, len(parts), context.temp_allocator)
	for seg in parts {
		if seg == "" || seg == "." do continue
		if seg == ".." {
			if len(stack) > 0 && stack[len(stack)-1] != ".." {
				pop(&stack)
			} else if !has_leading_slash && drive == "" {
				append(&stack, seg)
			}
			continue
		}
		append(&stack, seg)
	}
	b := strings.builder_make(context.temp_allocator)
	if drive != "" {
		strings.write_string(&b, drive)
		if has_leading_slash || len(stack) > 0 do strings.write_byte(&b, '/')
	} else if has_leading_slash && len(stack) > 0 {
		strings.write_byte(&b, '/')
	}
	for i := 0; i < len(stack); i += 1 {
		if i > 0 do strings.write_byte(&b, '/')
		strings.write_string(&b, stack[i])
	}
	r, _ := strings.clone(strings.to_string(b), allocator)
	return r
}

// Normalizes `path` into forward-slashed `.pak`-relative form by cleaning `.` / `..`
// segments and stripping active project root, engine dirs, or CWD prefixes when present.
vfs_normalize_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if path == "" do return strings.clone("", allocator)
	slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	cleaned := _vfs_collapse_segments(slashed, context.temp_allocator)

	// Strip active project / engine / cwd prefix if path is absolute or root-qualified.
	roots := [4]string{
		active_project_root(),
		engine_haati_dir(context.temp_allocator),
		engine_root(context.temp_allocator),
		"",
	}
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
		cwds, _ := strings.replace_all(cwd, "\\", "/", context.temp_allocator)
		roots[3] = strings.trim_right(cwds, "/")
	}
	for r in roots {
		if r == "" do continue
		rclean := _vfs_collapse_segments(r, context.temp_allocator)
		if trimmed, ok := _vfs_strip_prefix_ci(cleaned, rclean); ok {
			cleaned = trimmed
			break
		}
	}

	for strings.has_prefix(cleaned, "./") {
		cleaned = cleaned[2:]
	}
	cleaned = strings.trim_left(cleaned, "/")
	r, _ := strings.clone(cleaned, allocator)
	return r
}

// Assumes caller holds at least a shared lock on `_vfs_mu`.
@(private = "file")
_vfs_lookup_key_locked :: proc(norm_path: string) -> (key: string, found: bool) {
	if !_vfs_mounted || norm_path == "" do return "", false
	if norm_path in _vfs_pak.entries do return norm_path, true
	if strings.has_prefix(norm_path, "haati/") {
		stripped := norm_path[len("haati/"):]
		if stripped in _vfs_pak.entries do return stripped, true
	}
	return "", false
}

// Mounts `pak_path` as the active read-only `.pak` VFS (unmounting any prior mount).
vfs_mount_pak :: proc(pak_path: string) -> bool {
	if pak_path == "" do return false
	ar, ok := catalog.pak_open(pak_path, runtime.default_allocator())
	if !ok do return false

	sync.rw_mutex_lock(&_vfs_mu)
	if _vfs_mounted {
		catalog.pak_close(&_vfs_pak)
		_vfs_mounted = false
	}
	_vfs_pak = ar
	_vfs_mounted = true
	count := len(_vfs_pak.entries)
	sync.rw_mutex_unlock(&_vfs_mu)

	log.infof("[VFS] Mounted read-only pak %s (%d entries)", pak_path, count)
	return true
}

// Unmounts the active `.pak` VFS if mounted and releases archive handles.
vfs_unmount :: proc() {
	sync.rw_mutex_lock(&_vfs_mu)
	if _vfs_mounted {
		catalog.pak_close(&_vfs_pak)
		_vfs_mounted = false
	}
	sync.rw_mutex_unlock(&_vfs_mu)
}

// Returns true when a `.pak` archive is currently mounted.
vfs_is_mounted :: proc() -> bool {
	sync.rw_mutex_shared_lock(&_vfs_mu)
	defer sync.rw_mutex_shared_unlock(&_vfs_mu)
	return _vfs_mounted
}

// Returns true when `path` exists inside the currently mounted `.pak` archive.
vfs_has_file :: proc(path: string) -> bool {
	norm := vfs_normalize_path(path, context.temp_allocator)
	sync.rw_mutex_shared_lock(&_vfs_mu)
	defer sync.rw_mutex_shared_unlock(&_vfs_mu)
	_, ok := _vfs_lookup_key_locked(norm)
	return ok
}

// Returns true if `path` exists either in the mounted `.pak` VFS or on disk.
vfs_exists :: proc(path: string) -> bool {
	if path == "" do return false
	if vfs_has_file(path) do return true
	return os.exists(path)
}

// Reads `path` from the mounted `.pak` VFS first; falls back to `os.read_entire_file`.
vfs_read_entire_file :: proc(path: string, allocator := context.allocator) -> (bytes: []u8, err: os.Error) {
	if path == "" do return nil, os.General_Error.Invalid_Path
	norm := vfs_normalize_path(path, context.temp_allocator)

	sync.rw_mutex_shared_lock(&_vfs_mu)
	key, in_pak := _vfs_lookup_key_locked(norm)
	if in_pak {
		data, ok := catalog.pak_read_entry(&_vfs_pak, key, allocator)
		sync.rw_mutex_shared_unlock(&_vfs_mu)
		if !ok {
			return nil, os.General_Error.Invalid_File
		}
		return data, nil
	}
	sync.rw_mutex_shared_unlock(&_vfs_mu)

	return os.read_entire_file(path, allocator)
}
