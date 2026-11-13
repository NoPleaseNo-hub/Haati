package main

import "core:fmt"
import "core:os"
import "core:strings"
import "haati:engine/catalog"

_copy_dir_files :: proc(src_dir, dst_dir: string) -> bool {
	if !os.is_dir(src_dir) do return true
	handle, err := os.open(src_dir)
	if err != nil do return false
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return false

	_ = os.make_directory_all(dst_dir)
	for e in entries {
		src_path := strings.concatenate({src_dir, "/", e.name}, context.temp_allocator)
		dst_path := strings.concatenate({dst_dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if !_copy_dir_files(src_path, dst_path) do return false
		} else if os.is_file(src_path) {
			data, ferr := os.read_entire_file(src_path, context.temp_allocator)
			if ferr != nil do return false
			if os.write_entire_file(dst_path, data) != nil do return false
		}
	}
	return true
}

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: pack_assets <src_catalog> <stage_dir> <out_pak> [boot_scene]")
		os.exit(1)
	}
	src_catalog := os.args[1]
	stage_dir   := os.args[2]
	out_pak     := os.args[3]
	boot_scene  := len(os.args) >= 5 ? os.args[4] : ""

	if !catalog.export_from(src_catalog, stage_dir, boot_scene, root = "haati") {
		os.exit(1)
	}
	if os.is_dir("haati/ProjectSettings") {
		dst_ps := strings.concatenate({stage_dir, "/ProjectSettings"}, context.temp_allocator)
		if !_copy_dir_files("haati/ProjectSettings", dst_ps) {
			fmt.eprintln("[Pak] failed to copy ProjectSettings")
			os.exit(1)
		}
	}

	count, pok := catalog.pak_pack_directory(stage_dir, out_pak)
	if !pok {
		fmt.eprintfln("[Pak] failed to pack %s -> %s", stage_dir, out_pak)
		os.exit(1)
	}
	fmt.printfln("[Pak] wrote %s (%d files)", out_pak, count)
	os.exit(0)
}
