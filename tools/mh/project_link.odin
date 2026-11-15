package mh

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

COMPILE_MOUNT_MARKER :: "builds/.active_compile_mount"

@(private = "file")
_active_mount_link: string

Compile_Project_Mount :: struct {
	project_dir:          string, // normalized absolute project directory (or "")
	compiled_project_dir: string, // non-empty only when project has .odin code
	slug:                 string,
	link_path:            string,
	collection_flag:      string, // "-collection:project=<abs>" when project_dir != ""
	mounted_by_us:        bool,
}

@(private = "file")
_LAUNCHER_CFG_JSON :: struct {
	last_project_path: string,
}

@(private = "file")
_remove_dir_link_os :: proc(link_path: string) -> bool {
	when ODIN_OS == .Windows {
		win_link, _ := strings.replace_all(link_path, "/", "\\", context.temp_allocator)
		return run("cmd", "/C", "rmdir", win_link) == 0
	} else {
		return os.remove(link_path) == nil
	}
}

@(private = "file")
_create_dir_link_os :: proc(link_path, target_dir: string) -> bool {
	abs_target, aerr := filepath.abs(target_dir, context.temp_allocator)
	if aerr != nil || abs_target == "" do abs_target = target_dir
	when ODIN_OS == .Windows {
		win_link, _ := strings.replace_all(link_path, "/", "\\", context.temp_allocator)
		win_target, _ := strings.replace_all(abs_target, "/", "\\", context.temp_allocator)
		return run("cmd", "/C", "mklink", "/J", win_link, win_target) == 0
	} else {
		return os.symlink(abs_target, link_path) == nil
	}
}

// Removes any leftover compile-time project junction if a previous `mh` run was
// terminated mid-compile before its defer ran.
sweep_stale_compile_mount :: proc() -> bool {
	if !os.exists(COMPILE_MOUNT_MARKER) do return true
	data, err := os.read_entire_file(COMPILE_MOUNT_MARKER, context.temp_allocator)
	if err == nil {
		stale_link := strings.trim_space(string(data))
		if stale_link != "" {
			if _active_mount_link != "" && strings.equal_fold(stale_link, _active_mount_link) {
				return true
			}
			if _, lerr := os.lstat(stale_link, context.temp_allocator); lerr == nil {
				fmt.printfln("mh: removing stale compile project mount %s", stale_link)
				_ = _remove_dir_link_os(stale_link)
			}
		}
	}
	_ = os.remove(COMPILE_MOUNT_MARKER)
	return true
}

@(private = "file")
_slug_from_dir :: proc(dir: string, allocator := context.temp_allocator) -> string {
	clean, _ := filepath.clean(dir, context.temp_allocator)
	name := filepath.base(clean)
	b := strings.builder_make(context.temp_allocator)
	prev_us := false
	for r in name {
		lo := r
		if lo >= 'A' && lo <= 'Z' do lo += 'a' - 'A'
		if (lo >= 'a' && lo <= 'z') || (lo >= '0' && lo <= '9') {
			strings.write_byte(&b, u8(lo))
			prev_us = false
		} else if !prev_us && strings.builder_len(b) > 0 {
			strings.write_byte(&b, '_')
			prev_us = true
		}
	}
	s := strings.trim_right(strings.to_string(b), "_")
	if len(s) == 0 do return strings.clone("game_project", allocator)
	if s[0] >= '0' && s[0] <= '9' {
		return strings.concatenate({"p_", s}, allocator)
	}
	return strings.clone(s, allocator)
}

dir_has_odin_files :: proc(dir: string, depth: int = 0) -> bool {
	if depth > 4 || dir == "" || !os.is_dir(dir) do return false
	h, err := os.open(dir)
	if err != nil do return false
	entries, rerr := os.read_dir(h, -1, context.temp_allocator)
	os.close(h)
	if rerr != nil do return false
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		if e.type != .Directory {
			if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".odin") {
				return true
			}
			continue
		}
		switch e.name {
		case "external", "library", "builds", "logs", "UserSettings", "ProjectSettings", "samples":
			continue
		}
		sub, _ := filepath.join({dir, e.name}, context.temp_allocator)
		if dir_has_odin_files(sub, depth + 1) do return true
	}
	return false
}

// Resolves which external project directory to compile with for a build command:
// --project=<dir> -> HAATI_PROJECT env -> UserSettings/launcher.json last_project_path.
// When explicit_only is true (e.g. `mh test`), ignores launcher.json and HAATI_PROJECT.
resolve_target_project_dir :: proc(args: []string, explicit_only: bool = false) -> string {
	if has_flag(args, "--project-hub") || has_flag(args, "--no-project") {
		return ""
	}
	raw := flag_value(args, "--project")
	if raw == "" && !explicit_only {
		if env_p, ok := os.lookup_env("HAATI_PROJECT", context.temp_allocator); ok {
			raw = strings.trim_space(env_p)
		}
	}
	if raw == "" && !explicit_only {
		if data, rerr := os.read_entire_file("UserSettings/launcher.json", context.temp_allocator); rerr == nil && len(data) > 0 {
			cfg: _LAUNCHER_CFG_JSON
			if json.unmarshal(data, &cfg, allocator = context.temp_allocator) == nil {
				raw = strings.trim_space(cfg.last_project_path)
			}
		}
	}
	if raw == "" do return ""
	abs_p, aerr := filepath.abs(raw, context.temp_allocator)
	if aerr != nil || abs_p == "" || !os.is_dir(abs_p) do return ""
	norm, _ := strings.replace_all(abs_p, "\\", "/", context.temp_allocator)
	return strings.trim_right(norm, "/")
}

mount_project_for_compile :: proc(args: []string, explicit_only: bool = false) -> Compile_Project_Mount {
	_ = sweep_stale_compile_mount()
	proj_dir := resolve_target_project_dir(args, explicit_only)
	if proj_dir == "" do return {}

	slug := _slug_from_dir(proj_dir, context.temp_allocator)
	link_path := fmt.tprintf("%s/%s", PACKAGES_DIR, slug)
	mount := Compile_Project_Mount{
		project_dir     = proj_dir,
		slug            = slug,
		link_path       = link_path,
		collection_flag = fmt.tprintf("-collection:project=%s", proj_dir),
	}

	if !dir_has_odin_files(proj_dir) {
		return mount
	}
	mount.compiled_project_dir = proj_dir

	// Pre-split (`plugins/void_odin`) or existing healthy manual package dir: keep untouched.
	// Remove dangling reparse points before mounting.
	if _, lerr := os.lstat(link_path, context.temp_allocator); lerr == nil {
		if os.is_dir(link_path) {
			return mount
		}
		_ = _remove_dir_link_os(link_path)
	}
	os.make_directory_all(PACKAGES_DIR)
	if _create_dir_link_os(link_path, proj_dir) {
		os.make_directory_all("builds")
		_ = os.write_entire_file(COMPILE_MOUNT_MARKER, link_path)
		if _active_mount_link != "" do delete(_active_mount_link)
		_active_mount_link = strings.clone(link_path)
		mount.mounted_by_us = true
	} else {
		fmt.eprintfln("mh: warning — could not temporarily mount %s -> %s", link_path, proj_dir)
	}
	return mount
}

unmount_project_for_compile :: proc(mount: ^Compile_Project_Mount) {
	if mount == nil do return
	if mount.mounted_by_us && mount.link_path != "" {
		_ = _remove_dir_link_os(mount.link_path)
		mount.mounted_by_us = false
		if _active_mount_link != "" {
			delete(_active_mount_link)
			_active_mount_link = ""
		}
	}
	if os.exists(COMPILE_MOUNT_MARKER) {
		_ = os.remove(COMPILE_MOUNT_MARKER)
	}
}

env_with_compiled_project :: proc(proj_dir: string) -> []string {
	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			if strings.has_prefix(kv, "MH_COMPILED_PROJECT_DIR=") do continue
			append(&env, kv)
		}
	}
	norm, _ := strings.replace_all(proj_dir, "\\", "/", context.temp_allocator)
	append(&env, fmt.tprintf("MH_COMPILED_PROJECT_DIR=%s", norm))
	return env[:]
}
