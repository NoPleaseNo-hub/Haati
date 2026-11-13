package mh

// Running other programs, finding things on disk. The pieces every command
// needs and neither Odin's core nor a shell gives us portably.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Appended to every binary this tool produces, so one spelling names one file
// on every platform. Windows `odin build` also refuses an extension-less -out.
EXE :: ".exe" when ODIN_OS == .Windows else ""

// Flags every package in this repo needs. One definition — commands never
// repeat them. Dual collection mapping keeps `haati:` as canonical while
// allowing exempted external plugins (e.g. `void_odin`) importing `moonhug:`
// to compile unmodified.
COLLECTION_HAATI  :: "-collection:haati=haati"
COLLECTION_COMPAT :: "-collection:moonhug=haati"
IGNORE_ATTRS :: "-ignore-unknown-attributes"

// Unused imports and variables are compile errors here. They accumulate
// silently otherwise — a moved call leaves its import behind and nothing ever
// says so.
//
// Only this check, not full -vet: -vet-shadowing fires on `if x, ok := v.(T)`
// chains, where each branch reopens `ok` in its own scope, which is the
// idiomatic spelling and appears throughout the inspector and scene code.
// -vet-cast is also out — it reports the transmute in view_animation.odin as
// unneeded, but Asset_GUID is a distinct [16]u8 and Odin has no cast for that.
VET :: "-vet-unused"

// run executes a command to completion with this process's stdio, so compiler
// diagnostics and program output reach the terminal unbuffered and in order.
// Returns its exit code, or -1 when it could not start.
run :: proc(command: ..string) -> int {
	p, err := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("mh: cannot start %s: %v", command[0], err)
		return -1
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintfln("mh: wait failed for %s: %v", command[0], werr)
		return -1
	}
	return state.exit_code
}

// run_timeout executes a command with a hard watchdog timeout so a hung test binary
// or subprocess is automatically killed and never blocks the build/test pipeline forever.
run_timeout :: proc(timeout: time.Duration, command: ..string) -> int {
	p, err := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("mh: cannot start %s: %v", command[0], err)
		return -1
	}
	state, werr := os.process_wait(p, timeout)
	if werr != nil {
		_ = os.process_kill(p)
		fmt.eprintfln("mh: %s timed out or wait failed after %v (%v) — killed process", command[0], timeout, werr)
		return -1
	}
	return state.exit_code
}

// run_env is `run` with an explicit environment, for launching the editor
// with the variables it reads back (MH_LAUNCH, see launch_editor).
run_env :: proc(env: []string, command: ..string) -> int {
	p, err := os.process_start({command = command, env = env, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("mh: cannot start %s: %v", command[0], err)
		return -1
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintfln("mh: wait failed for %s: %v", command[0], werr)
		return -1
	}
	return state.exit_code
}

// spawn_detached_env starts `command` without waiting on its lifetime, used during
// Relaunch so the `mh_relaunch` helper can exit immediately after SHM handoff
// instead of staying OS-locked for the entire life of the new editor session.
spawn_detached_env :: proc(env: []string, command: ..string) -> bool {
	p, err := os.process_start({command = command, env = env})
	if err != nil {
		fmt.eprintfln("mh: cannot start detached %s: %v", command[0], err)
		return false
	}
	_, _ = os.process_wait(p, 0)
	return true
}

// Reports true when `path` exists on disk and is currently write-locked by a running OS process.
file_is_write_locked :: proc(path: string) -> bool {
	if !os.exists(path) do return false
	fd, err := os.open(path, {.Write})
	if err != nil do return true
	os.close(fd)
	return false
}

// run_in is `run` with a working directory, for the vendored library builds
// that only work from their own source folder.
run_in :: proc(dir: string, command: ..string) -> int {
	p, err := os.process_start({command = command, working_dir = dir, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("mh: cannot start %s in %s: %v", command[0], dir, err)
		return -1
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintfln("mh: wait failed for %s: %v", command[0], werr)
		return -1
	}
	return state.exit_code
}

// step runs a command and reports failure with the stage that failed, so a
// broken chain names its own broken link.
step :: proc(what: string, command: ..string) -> bool {
	if code := run(..command); code != 0 {
		fmt.eprintfln("mh: %s failed (exit %d)", what, code)
		return false
	}
	return true
}

// have reports whether an executable is on PATH. Replaces the shell's
// `command -v`, which has no Windows equivalent — this is why the optional
// shader step could only ever be guarded from sh.
have :: proc(tool: string) -> bool {
	_, ok := resolve_shader_tool(tool)
	return ok
}

// resolve_shader_tool locates a CLI executable first under MH_SHADER_TOOLS_DIR
// (so portable toolchains work without mutating system PATH) and then on PATH.
resolve_shader_tool :: proc(tool: string) -> (string, bool) {
	name := strings.concatenate({tool, EXE}, context.temp_allocator)
	if custom_dir, custom_ok := os.lookup_env("MH_SHADER_TOOLS_DIR", context.temp_allocator); custom_ok && custom_dir != "" {
		cand, cerr := filepath.join({custom_dir, name}, context.temp_allocator)
		if cerr == nil && os.exists(cand) do return cand, true
	}
	path, found := os.lookup_env("PATH", context.temp_allocator)
	if !found do return "", false
	sep := ";" when ODIN_OS == .Windows else ":"
	for dir in strings.split(path, sep, context.temp_allocator) {
		if dir == "" do continue
		p, err := filepath.join({dir, name}, context.temp_allocator)
		if err == nil && os.exists(p) do return p, true
	}
	return "", false
}

// odin_bin resolves the path to the odin executable: either "odin" if found on PATH,
// or falling back to the ODIN_ROOT executable if PATH is not configured.
odin_bin :: proc() -> string {
	if have("odin") do return "odin"
	root_odin, _ := filepath.join({ODIN_ROOT, "odin" + EXE}, context.temp_allocator)
	if os.exists(root_odin) do return root_odin
	return "odin"
}

// newer_than reports whether `out` exists and was written after `src`. False
// when either cannot be read, so an unreadable file rebuilds rather than
// silently keeping stale output.
newer_than :: proc(out, src: string) -> bool {
	out_t, oerr := os.modification_time_by_path(out)
	if oerr != nil do return false
	src_t, serr := os.modification_time_by_path(src)
	if serr != nil do return false
	return time.diff(src_t, out_t) > 0
}

// The Odin installation's vendor/ tree, for the libraries setup builds.
// ODIN_ROOT is filled in by the compiler, so this needs no `odin root` call.
odin_vendor :: proc(rest: ..string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, ODIN_ROOT, "vendor")
	append(&parts, ..rest)
	joined, _ := filepath.join(parts[:], context.temp_allocator)
	return joined
}

// The repo root, found by walking up for the haati/ (or legacy moonhug/)
// folder every path here is relative to. Commands run from the root whatever directory invoked them.
repo_root :: proc() -> (root: string, ok: bool) {
	dir, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return "", false
	for {
		for marker_name in ([?]string{"haati", "moonhug"}) {
			marker, jerr := filepath.join({dir, marker_name}, context.temp_allocator)
			if jerr == nil && os.is_dir(marker) do return dir, true
		}
		parent: string
		{
			// filepath.dir has no allocator parameter.
			context.allocator = context.temp_allocator
			parent = filepath.dir(dir)
		}
		if parent == dir do return "", false // filesystem root
		dir = parent
	}
}

chdir_repo_root :: proc() -> bool {
	root, ok := repo_root()
	if !ok {
		fmt.eprintln("mh: cannot find the repo root (no moonhug/ folder at or above the working directory)")
		return false
	}
	if err := os.set_working_directory(root); err != nil {
		fmt.eprintfln("mh: cannot enter repo root %s: %v", root, err)
		return false
	}
	return true
}
