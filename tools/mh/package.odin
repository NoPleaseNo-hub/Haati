package mh

// Standalone shipping packager (`mh package`): builds optimized `packages/app`
// binary, stages & packs runtime assets into `<name>.pak` via `pack_assets`,
// copies required runtime DLLs, and strips debug artifacts from `<out>`.
//
// Imports ONLY `core:*` (never `moonhug:`!).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
_Pkg_Manifest :: struct {
	name:       string,
	main_scene: string,
}

RUNTIME_DLLS := []string{
	"SDL3.dll",
	"SDL3_mixer.dll",
	"joltc.dll",
	"libgme.dll",
	"libogg-0.dll",
	"libopus-0.dll",
	"libopusfile-0.dll",
	"libwavpack-1.dll",
	"libxmp.dll",
}

@(private = "file")
_copy_file :: proc(src, dst: string) -> bool {
	data, err := os.read_entire_file(src, context.temp_allocator)
	if err != nil do return false
	return os.write_entire_file(dst, data) == nil
}

// sync_runtime_dlls copies Windows runtime DLLs (SDL3, SDL3_mixer, joltc, audio codecs)
// into `dst_dir`, skipping files whose size already matches so running builds stay untouched.
sync_runtime_dlls :: proc(dst_dir: string, strict: bool = false) -> bool {
	when ODIN_OS == .Windows {
		os.make_directory_all(dst_dir)
		for dll in RUNTIME_DLLS {
			src := ""
			if os.exists(dll) {
				src = dll
			} else {
				alt := fmt.tprintf("haati/%s", dll)
				if os.exists(alt) {
					src = alt
				}
			}
			if src == "" do continue

			dst := fmt.tprintf("%s/%s", dst_dir, dll)
			src_info, serr := os.stat(src, context.temp_allocator)
			dst_info, derr := os.stat(dst, context.temp_allocator)
			if serr == nil && derr == nil && src_info.size == dst_info.size {
				continue
			}
			if file_is_write_locked(dst) {
				if strict {
					fmt.eprintfln("haati: %s is currently locked and cannot be updated", dst)
					return false
				}
				continue
			}
			if !_copy_file(src, dst) {
				fmt.eprintfln("haati: failed to copy %s -> %s", src, dst)
				if strict do return false
			}
		}
	}
	return true
}

cmd_package :: proc(args: []string) -> int {
	out_dir := flag_value(args, "--out")
	if out_dir == "" do out_dir = "builds/dist"
	app_name := flag_value(args, "--name")
	scene := flag_value(args, "--scene")
	want_console := has_flag(args, "--console")

	mount := mount_project_for_compile(args)
	defer unmount_project_for_compile(&mount)

	src_catalog := "haati/library/catalog.json"
	if mount.project_dir != "" {
		manifest := _Pkg_Manifest{}
		mpath := fmt.tprintf("%s/haati.project", mount.project_dir)
		if mdata, merr := os.read_entire_file(mpath, context.temp_allocator); merr == nil && len(mdata) > 0 {
			_ = json.unmarshal(mdata, &manifest, allocator = context.temp_allocator)
		}
		if app_name == "" {
			if manifest.name != "" {
				app_name = manifest.name
			} else {
				context.allocator = context.temp_allocator
				app_name = filepath.base(mount.project_dir)
			}
		}
		if scene == "" && manifest.main_scene != "" {
			scene = manifest.main_scene
		}
		src_catalog = fmt.tprintf("%s/library/catalog.json", mount.project_dir)
	} else {
		if app_name == "" do app_name = "HaatiGame"
		if scene == "" do scene = "packages/app/assets/demo_menu/menu.scene"
	}

	if !prebuild_for_project(mount.compiled_project_dir) do return 1
	if !shaders_if_available() do return 1
	{
		hot_args := make([dynamic]string, context.temp_allocator)
		append(&hot_args, "--fast", "--release")
		if mount.project_dir != "" {
			append(&hot_args, fmt.tprintf("--project=%s", mount.project_dir))
		}
		if cmd_hot_res := hot_build_internal(hot_args[:], manage_mount = false); cmd_hot_res != 0 do return 1
	}

	os.make_directory_all(out_dir)

	exe_out := fmt.tprintf("%s/%s%s", out_dir, app_name, EXE)
	build_cmd := make([dynamic]string, context.temp_allocator)
	append(&build_cmd, odin_bin(), "build", "haati/packages/app", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
	if mount.collection_flag != "" do append(&build_cmd, mount.collection_flag)
	append(&build_cmd, VET, "-o:speed", fmt.tprintf("-out:%s", exe_out))
	when ODIN_OS == .Windows {
		if !want_console {
			append(&build_cmd, "-subsystem:windows")
		}
		if os.exists(WIN_ICON_RC) {
			append(&build_cmd, fmt.tprintf("-resource:%s", WIN_ICON_RC))
		}
	}
	if !step("shipping executable build", ..build_cmd[:]) do return 1

	if !os.exists(src_catalog) {
		fmt.printfln("mh: %s missing — bootstrapping headlessly from .meta files", src_catalog)
	}

	pack_bin, pok := tool_bin("pack_assets", "haati/prebuild/pack_assets", {"haati/engine/catalog"}, COLLECTION_HAATI, COLLECTION_COMPAT)
	if !pok do return 1

	stage_dir := fmt.tprintf("%s/_stage_data", out_dir)
	if os.exists(stage_dir) do os.remove_all(stage_dir)
	defer if os.exists(stage_dir) do os.remove_all(stage_dir)

	pak_out := fmt.tprintf("%s/%s.pak", out_dir, app_name)
	pak_args := make([dynamic]string, context.temp_allocator)
	append(&pak_args, pack_bin)
	if mount.project_dir != "" {
		append(&pak_args, fmt.tprintf("--project=%s", mount.project_dir))
	}
	append(&pak_args, src_catalog, stage_dir, pak_out)
	if scene != "" {
		append(&pak_args, scene)
	}
	if !step("asset pak archive", ..pak_args[:]) {
		return 1
	}

	when ODIN_OS == .Windows {
		if !sync_runtime_dlls(out_dir, strict = true) do return 1
	}

	// Strip debug & linker artifacts from the shipping directory.
	if dh, derr := os.open(out_dir); derr == nil {
		entries, rerr := os.read_dir(dh, -1, context.temp_allocator)
		os.close(dh)
		if rerr == nil {
			strip_exts := []string{".pdb", ".ilk", ".exp", ".lib"}
			for e in entries {
				lower := strings.to_lower(e.name, context.temp_allocator)
				for ext in strip_exts {
					if strings.has_suffix(lower, ext) {
						_ = os.remove(fmt.tprintf("%s/%s", out_dir, e.name))
						break
					}
				}
			}
		}
	}

	fmt.printfln("mh: packaged %s + %s", exe_out, pak_out)
	return 0
}
