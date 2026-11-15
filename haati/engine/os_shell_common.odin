package engine

import "core:os"
import "core:path/filepath"
import "core:strings"

// Recursively copies a file or directory from `src` to `dst`.
// Skips `.meta` sidecar files by default so duplicated assets mint fresh GUIDs on AssetDB refresh.
asset_fs_copy_recursive :: proc(src, dst: string, keep_meta_files := false) -> bool {
	if os.is_dir(src) {
		if os.make_directory(dst) != nil && !os.is_dir(dst) do return false
		handle, err := os.open(src)
		if err != nil do return false
		defer os.close(handle)
		entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
		if rerr != nil do return false
		defer os.file_info_slice_delete(entries, context.temp_allocator)
		ok := true
		for entry in entries {
			if !keep_meta_files && strings.has_suffix(entry.name, ".meta") do continue
			sub_src, _ := filepath.join({src, entry.name}, context.temp_allocator)
			sub_dst, _ := filepath.join({dst, entry.name}, context.temp_allocator)
			if !asset_fs_copy_recursive(sub_src, sub_dst, keep_meta_files) do ok = false
		}
		return ok
	}
	if !keep_meta_files && strings.has_suffix(src, ".meta") do return true
	data, rerr := os.read_entire_file(src, context.temp_allocator)
	if rerr != nil do return false
	return os.write_entire_file(dst, data) == nil
}
