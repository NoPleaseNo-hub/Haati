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

// run_test_checked runs the test command via inheritable OS pipes, streaming live
// stdout/stderr while scanning combined output for Tracking_Allocator errors.
run_test_checked :: proc(timeout: time.Duration, command: ..string) -> int {
	stdout_r, stdout_w, oerr := os.pipe()
	if oerr != nil {
		return run_timeout(timeout, ..command)
	}
	defer os.close(stdout_r)

	stderr_r, stderr_w, eerr := os.pipe()
	if eerr != nil {
		os.close(stdout_w)
		return run_timeout(timeout, ..command)
	}
	defer os.close(stderr_r)

	p: os.Process
	{
		defer os.close(stdout_w)
		defer os.close(stderr_w)
		perr: os.Error
		p, perr = os.process_start({command = command, stdout = stdout_w, stderr = stderr_w, stdin = os.stdin})
		if perr != nil {
			fmt.eprintfln("mh: cannot start %s: %v", command[0], perr)
			return -1
		}
	}

	captured := make([dynamic]byte, 0, 16 * 1024, context.temp_allocator)
	start_tick := time.tick_now()
	stdout_done, stderr_done, waited: bool
	final_state: os.Process_State
	buf: [4096]byte = ---

	drain_pipe :: proc(pipe: ^os.File, sink: ^os.File, captured: ^[dynamic]byte, buf: []byte) -> (did_work: bool, done: bool) {
		for {
			has_data, herr := os.pipe_has_data(pipe)
			if herr != nil {
				return did_work, true
			}
			if !has_data {
				return did_work, false
			}
			n, rerr := os.read(pipe, buf)
			if n > 0 {
				_, _ = os.write(sink, buf[:n])
				append(captured, ..buf[:n])
				did_work = true
			}
			if rerr != nil {
				return did_work, true
			}
		}
	}

	for !stdout_done || !stderr_done {
		did_work := false
		if !stdout_done {
			w, d := drain_pipe(stdout_r, os.stdout, &captured, buf[:])
			if w do did_work = true
			if d do stdout_done = true
		}
		if !stderr_done {
			w, d := drain_pipe(stderr_r, os.stderr, &captured, buf[:])
			if w do did_work = true
			if d do stderr_done = true
		}
		if stdout_done && stderr_done do break

		if !waited {
			st, werr := os.process_wait(p, 0)
			if werr == nil {
				waited = true
				final_state = st
			} else if werr != .Timeout {
				waited = true
				fmt.eprintfln("mh: wait failed for %s: %v", command[0], werr)
				return -1
			}
		} else if !did_work {
			break
		}

		if !waited && time.tick_since(start_tick) > timeout {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p, 5 * time.Second)
			fmt.eprintfln("mh: %s timed out after %v — killed process", command[0], timeout)
			return -1
		}
		if !did_work && !waited {
			time.sleep(2 * time.Millisecond)
		}
	}

	if !waited {
		rem := max(timeout - time.tick_since(start_tick), time.Second)
		st, werr := os.process_wait(p, rem)
		if werr != nil {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p, 5 * time.Second)
			fmt.eprintfln("mh: %s timed out or wait failed after %v (%v) — killed process", command[0], timeout, werr)
			return -1
		}
		final_state = st
	}

	if final_state.exit_code != 0 {
		return final_state.exit_code
	}
	txt := string(captured[:])
	if strings.contains(txt, "+++ bad free") || strings.contains(txt, "+++ leak") {
		fmt.eprintln("mh: test runner reported Tracking_Allocator errors (+++ bad free / +++ leak) — failing test gate!")
		return 1
	}
	return 0
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

// _bundled_tools_path resolves `<repo>/tools/...` so the bundled standalone
// toolchain (`tools/odin`, `tools/shader_tools`) always takes priority over
// global PATH or external ODIN_ROOT installs.
@(private = "file")
_bundled_tools_path :: proc(parts: ..string) -> (string, bool) {
	base := ""
	if root, ok := repo_root(); ok {
		base = root
	}
	seg := make([dynamic]string, 0, len(parts) + 2, context.temp_allocator)
	if base != "" do append(&seg, base)
	append(&seg, "tools")
	append(&seg, ..parts)
	cand, err := filepath.join(seg[:], context.temp_allocator)
	if err == nil && os.exists(cand) do return cand, true
	return "", false
}

@(private = "file")
_resolve_on_path :: proc(tool: string) -> (string, bool) {
	name := strings.concatenate({tool, EXE}, context.temp_allocator)
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

@(private = "file")
_resolve_tool :: proc(tool, bundled_subdir, env_var: string, check_odin_root := false) -> (string, bool) {
	name := strings.concatenate({tool, EXE}, context.temp_allocator)
	if bundled_subdir != "" {
		if bundled, ok := _bundled_tools_path(bundled_subdir, name); ok {
			return bundled, true
		}
	}
	if env_var != "" {
		if custom_dir, custom_ok := os.lookup_env(env_var, context.temp_allocator); custom_ok && custom_dir != "" {
			cand, cerr := filepath.join({custom_dir, name}, context.temp_allocator)
			if cerr == nil && os.exists(cand) do return cand, true
		}
	}
	if check_odin_root {
		root_bin, _ := filepath.join({ODIN_ROOT, name}, context.temp_allocator)
		if os.exists(root_bin) do return root_bin, true
	}
	return _resolve_on_path(tool)
}

// have reports whether a tool is available via bundled tools/, env override, ODIN_ROOT, or PATH.
have :: proc(tool: string) -> bool {
	if tool == "odin" {
		_, ok := _resolve_tool("odin", "odin", "", true)
		return ok
	}
	_, ok := resolve_shader_tool(tool)
	return ok
}

// resolve_shader_tool locates a CLI executable first in bundled `tools/shader_tools/`,
// then under MH_SHADER_TOOLS_DIR, and finally on PATH.
resolve_shader_tool :: proc(tool: string) -> (string, bool) {
	return _resolve_tool(tool, "shader_tools", "MH_SHADER_TOOLS_DIR", false)
}

// odin_bin resolves the Odin compiler binary: bundled `tools/odin/` first,
// then ODIN_ROOT, then PATH.
odin_bin :: proc() -> string {
	if p, ok := _resolve_tool("odin", "odin", "", true); ok {
		return p
	}
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

// The Odin installation's vendor/ tree, preferring bundled `tools/odin/vendor/`
// before falling back to compile-time `ODIN_ROOT/vendor/`.
odin_vendor :: proc(rest: ..string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if bundled_vendor, ok := _bundled_tools_path("odin", "vendor"); ok {
		append(&parts, bundled_vendor)
	} else {
		append(&parts, ODIN_ROOT, "vendor")
	}
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
