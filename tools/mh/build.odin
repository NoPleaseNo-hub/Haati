package mh

// Building and running the editor, the game, the tests and the MCP shim.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

EDITOR_BIN :: "builds/Haati" + EXE
ROOT_LAUNCHER_BIN :: "Haati_Editor" + EXE
RELAUNCH_STAGE_BIN :: "builds/Haati_relaunch" + EXE
MCP_BIN :: "builds/mcp_shim" + EXE
OVERWATCH_BIN :: "builds/Haati_Overwatch" + EXE
WIN_ICON_RC :: "haati/editor/haati.rc"

// Code generation, always before a build. Two steps: prune imports of removed
// package generators first — a stale one fails the prebuild compile before
// prebuild can heal the file itself — then run the generators.
// Both are compiled once into builds/tools/ and reused while unchanged
// (tools_cache.odin). Prebuild also depends on the package generators it
// compiles in, so their gen/ folders count as its sources.
prebuild :: proc() -> bool {
	return prebuild_for_project(resolve_target_project_dir(g_cli_args))
}

prebuild_for_project :: proc(compiled_project_dir: string) -> bool {
	_ = ensure_package_links()
	prune, pok := tool_bin("prune_package_gens", "haati/prebuild/prune_package_gens", {})
	if !pok || !step("prune", prune) do return false
	env := env_with_compiled_project(compiled_project_dir)
	// Exit 2: the set of package generators changed and the prebuild rewrote
	// the file that imports them, so it is built again and run once more.
	for attempt in 0 ..< 2 {
		gen, gok := tool_bin("prebuild", "haati/prebuild", package_gen_dirs(), COLLECTION_HAATI, COLLECTION_COMPAT)
		if !gok do return false
		code := run_env(env, gen)
		if code == 0 do return true
		if code == 2 && attempt == 0 do continue
		fmt.eprintfln("haati: prebuild failed (exit %d)", code)
		return false
	}
	return false
}

// Compiled shader blobs are committed, so this toolchain is optional and the
// step is skipped when it is absent (only authoring shaders needs it).
// Unchanged shaders are skipped too — see shaders_compile.
shaders_if_available :: proc() -> bool {
	if !have("glslc") || !have("spirv-cross") do return true
	return shaders_compile()
}

build_overwatch :: proc(allow_skip_if_locked: bool = false) -> bool {
	os.make_directory_all("builds")
	if allow_skip_if_locked && file_is_write_locked(OVERWATCH_BIN) {
		fmt.printfln("haati: %s is currently active/recording — keeping live recorder binary", OVERWATCH_BIN)
		return true
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_bin(), "build", "tools/overwatch", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT, fmt.tprintf("-out:%s", OVERWATCH_BIN), "-o:minimal")
	when ODIN_OS == .Windows {
		append(&cmd, "-subsystem:windows")
		if os.exists(WIN_ICON_RC) {
			append(&cmd, fmt.tprintf("-resource:%s", WIN_ICON_RC))
		}
	}
	return step("overwatch build", ..cmd[:])
}

cmd_overwatch :: proc(args: []string) -> int {
	if !build_overwatch(false) do return 1
	fmt.printfln("haati: built %s", OVERWATCH_BIN)
	return 0
}

// build_root_launcher builds the tiny zero-lock root `Haati.exe` forwarder
// that launches `builds/Haati.exe` with the repo root as working directory and exits immediately.
build_root_launcher :: proc() -> bool {
	src :: "tools/launcher/main.odin"
	if !os.exists(src) do return true
	ico_fresh := !os.exists("haati/editor/haati.ico") || newer_than(ROOT_LAUNCHER_BIN, "haati/editor/haati.ico")
	rc_fresh  := !os.exists(WIN_ICON_RC) || newer_than(ROOT_LAUNCHER_BIN, WIN_ICON_RC)
	if os.exists(ROOT_LAUNCHER_BIN) && newer_than(ROOT_LAUNCHER_BIN, src) && ico_fresh && rc_fresh do return true
	if file_is_write_locked(ROOT_LAUNCHER_BIN) do return true

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_bin(), "build", "tools/launcher", fmt.tprintf("-out:%s", ROOT_LAUNCHER_BIN), "-o:minimal")
	when ODIN_OS == .Windows {
		append(&cmd, "-subsystem:windows")
		if os.exists(WIN_ICON_RC) {
			append(&cmd, fmt.tprintf("-resource:%s", WIN_ICON_RC))
		}
	}
	return step("root launcher build", ..cmd[:])
}

// build_editor: generate, shaders, compile. `out` is named Haati so the OS
// displays Haati in window/process switchers.
build_editor :: proc(debug: bool, out_bin: string = EDITOR_BIN, want_console: bool = false, args_for_project: []string = nil) -> bool {
	cli := args_for_project if len(args_for_project) > 0 else g_cli_args
	mount := mount_project_for_compile(cli)
	defer unmount_project_for_compile(&mount)

	if !prebuild_for_project(mount.compiled_project_dir) do return false
	if !shaders_if_available() do return false
	if !build_overwatch(allow_skip_if_locked = true) do return false
	os.make_directory_all("builds")
	sync_runtime_dlls("builds", false)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_bin(), "build", "haati/editor", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
	if mount.collection_flag != "" {
		append(&cmd, mount.collection_flag)
	}
	append(&cmd, VET)
	if debug do append(&cmd, "-debug")
	when ODIN_OS == .Windows {
		if !want_console {
			append(&cmd, "-subsystem:windows")
		}
		if os.exists(WIN_ICON_RC) {
			append(&cmd, fmt.tprintf("-resource:%s", WIN_ICON_RC))
		}
	}
	append(&cmd, fmt.tprintf("-out:%s", out_bin))
	if !step("editor build", ..cmd[:]) do return false
	_ = build_root_launcher()
	return true
}

// Build then run as a CHILD process, not `odin run`: `odin run` keeps the
// ~1GB compiler resident for the whole life of the editor just to wait on it.
cmd_run :: proc(args: []string) -> int {
	return launch_editor("run", !has_flag(args, "--release"))
}

cmd_debug :: proc(args: []string) -> int {
	return launch_editor("debug", true)
}

// The file that tells a running editor its replacement is built. Lives under
// builds/ so `mh clean` removes a stale one.
RELAUNCH_MARKER :: "builds/relaunch_ready"

// Build and launch the editor for `mode` ("run" or "debug"). The editor gets
// MH_LAUNCH=<mode> so its Relaunch button can rerun this exact command.
//
// Relaunch handshake (editor/relaunch.odin): the editor spawns `mh <mode>`
// with MH_RELAUNCH_PID set to its own pid and keeps running while the build
// goes. On Windows, a running .exe is locked by the OS against overwrite, so
// relaunch compiles to RELAUNCH_STAGE_BIN first. On a successful build this
// writes RELAUNCH_MARKER, waits for the old editor to exit, swaps the staged
// binary into EDITOR_BIN, removes the marker and launches the new one.
launch_editor :: proc(mode: string, with_debug: bool = true) -> int {
	pid_str, relaunching := os.lookup_env("MH_RELAUNCH_PID", context.temp_allocator)
	seq_str, _ := os.lookup_env("MH_RELAUNCH_SEQ", context.temp_allocator)
	shm_name, _ := os.lookup_env("MH_SHM_NAME", context.temp_allocator)
	stage_tag := pid_str != "" ? (seq_str != "" ? fmt.tprintf("%s_%s", pid_str, seq_str) : pid_str) : "stage"
	stage_bin := fmt.tprintf("builds/Haati_relaunch_%s%s", stage_tag, EXE)
	target_bin := stage_bin if relaunching else EDITOR_BIN
	if !relaunching && file_is_write_locked(EDITOR_BIN) {
		target_bin = fmt.tprintf("builds/Haati_live_%d%s", os.get_pid(), EXE)
	}
	want_console := false
	if v, ok := os.lookup_env("MH_CONSOLE", context.temp_allocator); ok && v == "1" do want_console = true
	if !build_editor(with_debug, target_bin, want_console) do return 1

	pinned_shm: SHM_Pin = nil
	defer shm_bridge_join()

	if relaunching {
		if pid, ok := strconv.parse_int(pid_str); ok {
			_ = os.write_entire_file(RELAUNCH_MARKER, "ready")
			fmt.printfln("mh: built, waiting for editor %d to exit", pid)
			// Poll instead of waiting: the old editor is not our child.
			// Also pin the OS RAM shared-memory snapshot (`MH_SHM_NAME`) before the old process exits!
			t0 := time.tick_now()
			for process_alive(pid) && time.tick_since(t0) < 15 * time.Second {
				if pinned_shm == nil && shm_name != "" {
					pinned_shm = shm_bridge_try_pin(shm_name)
				}
				time.sleep(15 * time.Millisecond)
			}
			if pinned_shm == nil && shm_name != "" {
				pinned_shm = shm_bridge_try_pin(shm_name)
			}
			_ = os.remove(RELAUNCH_MARKER)
		}
		// Swap staged binary into EDITOR_BIN (retry briefly on Windows while
		// the kernel releases the exiting process's file lock).
		swapped := false
		for _ in 0 ..< 40 {
			if os.exists(EDITOR_BIN) {
				_ = os.remove(EDITOR_BIN)
			}
			if os.rename(stage_bin, EDITOR_BIN) == nil {
				swapped = true
				break
			}
			time.sleep(50 * time.Millisecond)
		}
		if !swapped {
			if data, rerr := os.read_entire_file(stage_bin, context.temp_allocator); rerr == nil {
				if os.write_entire_file(EDITOR_BIN, data) == nil {
					_ = os.remove(stage_bin)
					swapped = true
				}
			}
		}
		launch_bin := EDITOR_BIN if swapped else stage_bin
		if !swapped {
			fmt.eprintfln("mh: could not replace %s with %s; launching staged binary directly", EDITOR_BIN, stage_bin)
		}
		env := make([dynamic]string, context.temp_allocator)
		if cur, err := os.environ(context.temp_allocator); err == nil {
			for kv in cur {
				if strings.has_prefix(kv, "MH_RELAUNCH_PID=") || strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") || strings.has_prefix(kv, "MH_LAUNCH=") || strings.has_prefix(kv, "MH_SHM_NAME=") || strings.has_prefix(kv, "MH_SHM_HANDOFF=") do continue
				append(&env, kv)
			}
		}
		append(&env, fmt.tprintf("MH_LAUNCH=%s", mode))
		if pinned_shm != nil && shm_name != "" {
			append(&env, fmt.tprintf("MH_SHM_HANDOFF=%s", shm_name))
			shm_bridge_release_when_consumed(pinned_shm)
		}
		launch_cmd := make([dynamic]string, context.temp_allocator)
		append(&launch_cmd, launch_bin)
		if proj_arg := flag_value(g_cli_args, "--project"); proj_arg != "" {
			append(&launch_cmd, fmt.tprintf("--project=%s", proj_arg))
		} else if has_flag(g_cli_args, "--project-hub") {
			append(&launch_cmd, "--project-hub")
		}
		// Spawn replacement editor detached so `mh_relaunch` exits as soon as `shm_bridge_join()` finishes!
		return 0 if spawn_detached_env(env[:], ..launch_cmd[:]) else 1
	}

	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			// Never inherit the handshake pid: the new editor is not relaunching.
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") || strings.has_prefix(kv, "MH_RELAUNCH_SEQ=") || strings.has_prefix(kv, "MH_LAUNCH=") || strings.has_prefix(kv, "MH_SHM_NAME=") || strings.has_prefix(kv, "MH_SHM_HANDOFF=") do continue
			append(&env, kv)
		}
	}
	append(&env, fmt.tprintf("MH_LAUNCH=%s", mode))
	if pinned_shm != nil && shm_name != "" {
		append(&env, fmt.tprintf("MH_SHM_HANDOFF=%s", shm_name))
		shm_bridge_release_when_consumed(pinned_shm)
	}
	launch_cmd := make([dynamic]string, context.temp_allocator)
	append(&launch_cmd, target_bin)
	if proj_arg := flag_value(g_cli_args, "--project"); proj_arg != "" {
		append(&launch_cmd, fmt.tprintf("--project=%s", proj_arg))
	} else if has_flag(g_cli_args, "--project-hub") {
		append(&launch_cmd, "--project-hub")
	}
	return run_env(env[:], ..launch_cmd[:])
}

cmd_build :: proc(args: []string) -> int {
	out_bin := EDITOR_BIN
	if file_is_write_locked(EDITOR_BIN) {
		out_bin = "builds/Haati_staged" + EXE
		fmt.printfln("haati: %s is currently open/locked — staging build to %s", EDITOR_BIN, out_bin)
	}
	if !build_editor(!has_flag(args, "--release"), out_bin, has_flag(args, "--console"), args) do return 1
	fmt.printfln("haati: built %s", out_bin)
	return 0
}

// Ground-truth compiler typecheck (`odin check`). Runs prebuild first by default
// so newly added `@(component)` / `@(editor_window)` declarations are generated;
// pass `--fast` on file-save hooks to skip prebuild (~420ms full-repo check),
// `--pkg=<dir>` to check an isolated package (`-no-entry-point`), and `--json`
// to emit machine-readable `-json-errors` for Antigravity and the in-engine studio.
cmd_check :: proc(args: []string) -> int {
	mount := mount_project_for_compile(args)
	defer unmount_project_for_compile(&mount)

	if !has_flag(args, "--fast") {
		if !prebuild_for_project(mount.compiled_project_dir) do return 1
	}
	pkg := flag_value(args, "--pkg")
	cmd := make([dynamic]string, context.temp_allocator)
	if pkg == "" {
		append(&cmd, odin_bin(), "check", "haati/editor", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
		if mount.collection_flag != "" do append(&cmd, mount.collection_flag)
		append(&cmd, VET)
	} else {
		append(&cmd, odin_bin(), "check", pkg, "-no-entry-point", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
		if mount.collection_flag != "" do append(&cmd, mount.collection_flag)
	}
	if has_flag(args, "--json") {
		append(&cmd, "-json-errors")
	}
	return run(..cmd[:])
}

// Compiles the `typeid`-isolated C-ABI hot cartridge (`builds/hot_cartridge_src` -> `.dll`).
// Pass `--fast` when no `@(hot_proc)` declarations were added/removed to skip prebuild (~130 ms).
hot_build_internal :: proc(args: []string, manage_mount: bool = true) -> int {
	mount: Compile_Project_Mount
	if manage_mount {
		mount = mount_project_for_compile(args)
	} else {
		proj_dir := resolve_target_project_dir(args)
		if proj_dir != "" {
			mount.project_dir = proj_dir
			if dir_has_odin_files(proj_dir) {
				mount.compiled_project_dir = proj_dir
			}
			mount.collection_flag = fmt.tprintf("-collection:project=%s", proj_dir)
		}
	}
	defer if manage_mount do unmount_project_for_compile(&mount)

	if !has_flag(args, "--fast") || !os.exists("builds/hot_cartridge_src/cartridge_generated.odin") {
		if !prebuild_for_project(mount.compiled_project_dir) do return 1
	}
	os.make_directory_all("builds")
	dll_ext :: ".dll" when ODIN_OS == .Windows else (".dylib" when ODIN_OS == .Darwin else ".so")
	out_path := flag_value(args, "--out")
	if out_path == "" {
		out_path = fmt.tprintf("builds/hot_cartridge_latest%s", dll_ext)
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_bin(), "build", "builds/hot_cartridge_src", "-build-mode:dll", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
	if mount.collection_flag != "" do append(&cmd, mount.collection_flag)
	append(&cmd, VET)
	if has_flag(args, "--release") {
		append(&cmd, "-o:speed")
	}
	append(&cmd, fmt.tprintf("-out:%s", out_path))
	if !step("hot cartridge build", ..cmd[:]) do return 1
	fmt.printfln("haati: built %s", out_path)
	return 0
}

cmd_hot :: proc(args: []string) -> int {
	return hot_build_internal(args, manage_mount = true)
}

cmd_prebuild :: proc(args: []string) -> int {
	mount := mount_project_for_compile(args)
	defer unmount_project_for_compile(&mount)
	return 0 if prebuild_for_project(mount.compiled_project_dir) else 1
}

// Gathers dependencies into each plugin's mh_plugin.json. The work lives
// beside prebuild, which reads the same imports.
cmd_deps :: proc(args: []string) -> int {
	bin, ok := tool_bin("gather_plugin_deps", "haati/prebuild/gather_plugin_deps", {"haati/prebuild/gen_facts"}, COLLECTION_HAATI, COLLECTION_COMPAT)
	if !ok do return 1
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, bin)
	append(&cmd, ..args)
	return 0 if step("deps", ..cmd[:]) else 1
}

// The game, through its run config — the same path the editor's Play button
// takes, so a terminal run and a Play run agree.
cmd_app :: proc(args: []string) -> int {
	if !prebuild() do return 1
	config := "run_debug.odin" if has_flag(args, "--debug") else "run.odin"
	return run(odin_bin(), "run", fmt.tprintf("haati/packages/app/run_configs/%s", config), "-file", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
}

// -define:ODIN_TEST_THREADS=1 keeps tests serial: they share the asset db and
// fixture files on disk. Codegen runs first: the test binary compiles the
// generated registrations, and a stale one fails the compile against renamed
// types. Supports --pkg=<path> (default: haati/tests) and --name=<filter>.
cmd_test :: proc(args: []string) -> int {
	mount := mount_project_for_compile(args, explicit_only = true)
	defer unmount_project_for_compile(&mount)

	if !prebuild_for_project(mount.compiled_project_dir) do return 1
	os.make_directory_all("builds")
	sync_runtime_dlls("builds", false)
	pkg := flag_value(args, "--pkg")
	if pkg == "" do pkg = "haati/tests"
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_bin(), "test", pkg)
	if pkg == "haati/tests" {
		append(&cmd, "-all-packages")
	}
	append(&cmd, IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT)
	if mount.collection_flag != "" do append(&cmd, mount.collection_flag)
	append(&cmd, VET, "-define:ODIN_TEST_THREADS=1", fmt.tprintf("-out:builds/test_runner%s", EXE))
	if name := flag_value(args, "--name"); name != "" {
		append(&cmd, fmt.tprintf("-define:ODIN_TEST_NAMES=%s", name))
	}
	return run_timeout(120 * time.Second, ..cmd[:])
}

// The MCP stdio server the client spawns.
// Build diagnostics go to stderr so stdout stays a clean JSON-RPC stream.
cmd_mcp :: proc(args: []string) -> int {
	os.make_directory_all("builds")
	if code := run(odin_bin(), "build", "haati/mcp_shim", IGNORE_ATTRS, COLLECTION_HAATI, COLLECTION_COMPAT, fmt.tprintf("-out:%s", MCP_BIN), "-o:minimal"); code != 0 {
		return code
	}
	return run(MCP_BIN)
}

// builds/ is build output and library/ is derived data — both are gitignored
// and rebuild on the next run. builds/ itself is committed (a .gitkeep), so
// the directory is emptied rather than removed.
cmd_clean :: proc(args: []string) -> int {
	_ = sweep_stale_compile_mount()
	os.remove_all("builds")
	os.make_directory_all("builds")
	_ = os.write_entire_file("builds/.gitkeep", []u8{})
	if os.exists(ROOT_LAUNCHER_BIN) && !file_is_write_locked(ROOT_LAUNCHER_BIN) {
		_ = os.remove(ROOT_LAUNCHER_BIN)
	}
	fmt.println("mh: emptied builds/")
	if has_flag(args, "--all") {
		os.remove_all("haati/library")
		fmt.println("haati: removed haati/library/")
	}
	return 0
}
