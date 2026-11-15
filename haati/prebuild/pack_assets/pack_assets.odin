package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "haati:engine/catalog"

_Artifact_Ref :: struct {
	artifact: string,
}

_scan_meta_root :: proc(disk_dir, cat_prefix: string, artifacts: map[string]_Artifact_Ref, assets: ^map[string]catalog.Entry) -> bool {
	if !os.is_dir(disk_dir) do return true
	handle, err := os.open(disk_dir)
	if err != nil do return false
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return false

	for e in entries {
		disk_path := strings.concatenate({disk_dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			sub_cat := strings.concatenate({cat_prefix, "/", e.name}, context.temp_allocator)
			if !_scan_meta_root(disk_path, sub_cat, artifacts, assets) do return false
			continue
		}
		if !strings.has_suffix(e.name, ".meta") || !os.is_file(disk_path) do continue
		asset_name := e.name[:len(e.name) - 5]
		asset_disk := strings.concatenate({disk_dir, "/", asset_name}, context.temp_allocator)
		if !os.exists(asset_disk) do continue

		raw, ferr := os.read_entire_file(disk_path, context.temp_allocator)
		if ferr != nil do continue
		prev := context.allocator
		context.allocator = context.temp_allocator
		val, perr := json.parse(raw, .JSON, true)
		context.allocator = prev
		if perr != nil do continue
		obj, is_obj := val.(json.Object)
		if !is_obj do continue
		guid_val, has_guid := obj["guid"].(json.String)
		if !has_guid || string(guid_val) == "" do continue
		guid_str := string(guid_val)

		entry := catalog.Entry{
			path = strings.concatenate({cat_prefix, "/", asset_name}, context.temp_allocator),
		}
		if aref, has_art := artifacts[guid_str]; has_art && aref.artifact != "" {
			entry.artifact = aref.artifact
		}
		if s_val, has_s := obj["settings"]; has_s {
			if s_blob, merr := json.marshal(s_val, {spec = .JSON}, context.temp_allocator); merr == nil {
				entry.settings = string(s_blob)
			}
		}
		assets[guid_str] = entry
	}
	return true
}

_load_artifacts_into :: proc(path: string, artifacts: ^map[string]_Artifact_Ref) {
	if !os.is_file(path) do return
	if abytes, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		tmp := make(map[string]_Artifact_Ref, 0, context.temp_allocator)
		if json.unmarshal(abytes, &tmp, allocator = context.temp_allocator) == nil {
			for k, v in tmp {
				artifacts[k] = v
			}
		}
	}
}

_bootstrap_catalog :: proc(out_catalog_path: string, proj_dir: string) -> bool {
	artifacts := make(map[string]_Artifact_Ref, 0, context.temp_allocator)
	_load_artifacts_into("haati/library/artifact_db.json", &artifacts)
	if proj_dir != "" {
		proj_adb := strings.concatenate({proj_dir, "/library/artifact_db.json"}, context.temp_allocator)
		_load_artifacts_into(proj_adb, &artifacts)
	}

	cf := catalog.File{
		version = catalog.VERSION,
		assets  = make(map[string]catalog.Entry, 64, context.temp_allocator),
	}
	assets_root := proj_dir != "" ? strings.concatenate({proj_dir, "/assets"}, context.temp_allocator) : "haati/assets"
	if !_scan_meta_root(assets_root, "assets", artifacts, &cf.assets) do return false

	if os.is_dir("haati/packages") {
		if ph, perr := os.open("haati/packages"); perr == nil {
			pkgs, rerr := os.read_dir(ph, -1, context.temp_allocator)
			os.close(ph)
			if rerr == nil {
				for pkg in pkgs {
					if pkg.type != .Directory || pkg.name == "void_odin" do continue
					pkg_assets := strings.concatenate({"haati/packages/", pkg.name, "/assets"}, context.temp_allocator)
					pkg_prefix := strings.concatenate({"packages/", pkg.name, "/assets"}, context.temp_allocator)
					if !_scan_meta_root(pkg_assets, pkg_prefix, artifacts, &cf.assets) do return false
				}
			}
		}
	}

	catalog.ensure_parent_dirs(out_catalog_path)
	if !catalog.save(&cf, out_catalog_path) do return false
	fmt.printfln("[Pak] bootstrapped %s (%d entries)", out_catalog_path, len(cf.assets))
	return true
}

_copy_dir_files :: proc(src_dir, dst_dir: string, skip_subdir: string = "") -> bool {
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
			if skip_subdir != "" && e.name == skip_subdir do continue
			if !_copy_dir_files(src_path, dst_path) do return false
		} else if os.is_file(src_path) {
			data, ferr := os.read_entire_file(src_path, context.temp_allocator)
			if ferr != nil do return false
			if os.write_entire_file(dst_path, data) != nil do return false
		}
	}
	return true
}

_stage_project_scripts :: proc(proj_root, cur_dir, rel_prefix, stage_dir: string) {
	handle, err := os.open(cur_dir)
	if err != nil do return
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return

	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		rel := rel_prefix == "" ? e.name : strings.concatenate({rel_prefix, "/", e.name}, context.temp_allocator)
		src_path := strings.concatenate({cur_dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if rel_prefix == "" && (e.name == "library" || e.name == "builds" || e.name == "UserSettings" || e.name == "logs") {
				continue
			}
			_stage_project_scripts(proj_root, src_path, rel, stage_dir)
		} else if os.is_file(src_path) && (strings.has_suffix(e.name, ".bodin") || strings.has_suffix(e.name, ".mhgraph")) {
			dst_path := strings.concatenate({stage_dir, "/", rel}, context.temp_allocator)
			if !os.exists(dst_path) {
				if data, ferr := os.read_entire_file(src_path, context.temp_allocator); ferr == nil {
					catalog.ensure_parent_dirs(dst_path)
					_ = os.write_entire_file(dst_path, data)
				}
			}
		}
	}
}

main :: proc() {
	proj_dir := ""
	pos := make([dynamic]string, 0, len(os.args), context.temp_allocator)
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--project=") {
			raw := arg[len("--project="):]
			norm, _ := strings.replace_all(raw, "\\", "/", context.temp_allocator)
			proj_dir = strings.trim_right(norm, "/")
		} else {
			append(&pos, arg)
		}
	}
	if len(pos) < 3 {
		fmt.eprintln("usage: pack_assets [--project=<dir>] <src_catalog> <stage_dir> <out_pak> [boot_scene]")
		os.exit(1)
	}
	src_catalog := pos[0]
	stage_dir   := pos[1]
	out_pak     := pos[2]
	boot_scene  := len(pos) >= 4 ? pos[3] : ""

	if !os.exists(src_catalog) {
		if !_bootstrap_catalog(src_catalog, proj_dir) {
			fmt.eprintfln("[Pak] failed to bootstrap missing catalog %s", src_catalog)
			os.exit(1)
		}
	}

	exp_root := proj_dir != "" ? proj_dir : "haati"
	fb_root  := proj_dir != "" ? "haati" : ""
	fb_art   := proj_dir != "" ? "haati/library/artifacts" : ""
	if !catalog.export_from(src_catalog, stage_dir, boot_scene, root = exp_root, fallback_root = fb_root, fallback_artifact_dir = fb_art) {
		os.exit(1)
	}

	dst_ps := strings.concatenate({stage_dir, "/ProjectSettings"}, context.temp_allocator)
	if os.is_dir("UserSettings/EngineSettings") {
		if !_copy_dir_files("UserSettings/EngineSettings", dst_ps, skip_subdir = "_defaults_backdrop") {
			fmt.eprintln("[Pak] failed to copy EngineSettings backdrop")
			os.exit(1)
		}
	}
	proj_ps := proj_dir != "" ? strings.concatenate({proj_dir, "/ProjectSettings"}, context.temp_allocator) : "haati/ProjectSettings"
	if os.is_dir(proj_ps) {
		if !_copy_dir_files(proj_ps, dst_ps) {
			fmt.eprintln("[Pak] failed to copy ProjectSettings")
			os.exit(1)
		}
	}
	if proj_dir != "" {
		manifest_src := strings.concatenate({proj_dir, "/haati.project"}, context.temp_allocator)
		if os.is_file(manifest_src) {
			if mdata, merr := os.read_entire_file(manifest_src, context.temp_allocator); merr == nil {
				_ = os.write_entire_file(strings.concatenate({stage_dir, "/haati.project"}, context.temp_allocator), mdata)
			}
		}
		_stage_project_scripts(proj_dir, proj_dir, "", stage_dir)
	}

	count, pok := catalog.pak_pack_directory(stage_dir, out_pak)
	if !pok {
		fmt.eprintfln("[Pak] failed to pack %s -> %s", stage_dir, out_pak)
		os.exit(1)
	}
	fmt.printfln("[Pak] wrote %s (%d files)", out_pak, count)
	os.exit(0)
}
