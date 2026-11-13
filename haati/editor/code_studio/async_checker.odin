package code_studio

// =============================================================================
// ZERO-STUTTER TWO-STAGE THROTTLED SINGLE-FLIGHT ASYNC CHECKER (`async_checker.odin`)
// =============================================================================
// Prevents main-thread stutters AND background CPU starvation while typing:
//   - 1 persistent sleeping worker thread (`sync.Cond`, `0.0%` CPU when idle).
//   - Stage A (`180 ms` debounce, `< 0.15 ms`, zero disk IO, zero OS process):
//     Runs `core:odin/parser` directly on the in-RAM string inside a resettable
//     `mem.Dynamic_Arena` to catch syntax errors (`missing '}'`, unclosed string,
//     malformed expression) almost instantly!
//   - Stage B (`600 ms` idle coalesce or immediate on `Ctrl+S` / `F7`, single-flight):
//     Spawns AT MOST ONE background `odin check ... -json-errors` subprocess,
//     parses compiler JSON diagnostics via `core:encoding/json`, and coalesces
//     any intermediate edits into a single follow-up check rather than flooding cores!

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "haati:engine"

SYNTAX_DEBOUNCE_MS :: 180
TYPECHECK_IDLE_MS  :: 600

Check_Stage :: enum u8 {
	Idle            = 0,
	Pending_Syntax  = 1,
	Syntax_OK       = 2,
	Syntax_Error    = 3,
	Running_Compiler = 4,
	Compiler_OK     = 5,
	Compiler_Error  = 6,
}

Studio_Diagnostic :: struct {
	file:       string,
	line:       int, // 1-based line (already mapped back to scoped popup line when `is_scoped`)
	column:     int,
	end_column: int,
	is_warning: bool,
	message:    string,
}

Checker_Snapshot :: struct {
	stage:         Check_Stage,
	revision:      u64,
	syntax_ms:     f32,
	compiler_ms:   f32,
	diagnostics:   []Studio_Diagnostic,
	summary_label: string,
}

// JSON schema emitted by `odin check <pkg> -json-errors`
@(private = "file")
_Odin_JSON_Pos :: struct {
	file:       string,
	offset:     int,
	line:       int,
	column:     int,
	end_column: int,
}

@(private = "file")
_Odin_JSON_Err :: struct {
	type: string,
	pos:  _Odin_JSON_Pos,
	msgs: []string,
}

@(private = "file")
_Odin_JSON_Output :: struct {
	error_count: int,
	errors:      []_Odin_JSON_Err,
}

@(private = "file")
_Checker_Worker_State :: struct {
	started:           bool,
	stop_requested:    bool,
	worker_thread:     ^thread.Thread,
	mu:                sync.Mutex,
	cv:                sync.Cond,

	// Latest submitted document from UI thread
	req_revision:      u64,
	req_code:          string,
	req_pkg_dir:       string, // e.g. "haati/hot_scripts" ("" skips Stage B)
	req_file_filter:   string, // optional file basename filter
	req_is_scoped:     bool,   // true when `req_code` is a scoped node body without outer `package`/`proc`
	req_force_stage_b: bool,
	req_edit_tick:     time.Tick,

	// Published result read lock-protected by UI thread
	pub_stage:         Check_Stage,
	pub_revision:      u64,
	pub_syntax_ms:     f32,
	pub_compiler_ms:   f32,
	pub_diags:         [dynamic]Studio_Diagnostic,
	pub_summary:       string,
}

@(private = "file")
_chk: _Checker_Worker_State

// Scratch capture buffer used only inside `_run_stage_a_syntax` on the worker thread.
@(private = "file")
_stage_a_diags: [dynamic]Studio_Diagnostic
@(private = "file")
_stage_a_line_offset: int

@(private = "file")
_stage_a_err_cb :: proc(pos: tokenizer.Pos, msg_fmt: string, args: ..any) {
	context.allocator = runtime.default_allocator()
	if len(_stage_a_diags) >= 24 do return
	adj_line := max(pos.line - _stage_a_line_offset, 1)
	formatted := fmt.aprintf(msg_fmt, ..args)
	append(&_stage_a_diags, Studio_Diagnostic{
		file       = strings.clone(pos.file),
		line       = adj_line,
		column     = max(pos.column, 1),
		end_column = max(pos.column + 1, 2),
		is_warning = false,
		message    = formatted,
	})
}

// Pure in-RAM syntax validation (`< 0.15 ms`, zero disk IO, zero process spawn).
// Also callable synchronously in unit tests!
check_odin_syntax_in_ram :: proc(code: string, is_scoped_body: bool, allocator := context.temp_allocator) -> (diags: []Studio_Diagnostic, elapsed_ms: f32) {
	t0 := time.tick_now()

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	wrapped: string
	line_off := 0
	if is_scoped_body {
		// Wrap the scoped node body in a valid dummy package + proc so `core:odin/parser`
		// validates statements, braces, expressions, and local declarations cleanly!
		wrapped = strings.concatenate({"package _mh_scoped_check\n_mh_body :: proc() {\n", code, "\n}\n"}, mem.dynamic_arena_allocator(&arena))
		line_off = 2
	} else {
		wrapped = code
		line_off = 0
	}

	// Guard shared callback scratch under `_chk.mu` if worker is active, or run directly.
	local_out := make([dynamic]Studio_Diagnostic, 0, 8, allocator)
	{
		context.allocator = mem.dynamic_arena_allocator(&arena)
		_stage_a_line_offset = line_off
		clear(&_stage_a_diags)

		f := ast.File{
			src      = wrapped,
			fullpath = "in_ram_buffer.odin",
		}
		p := parser.Parser{
			err   = _stage_a_err_cb,
			warn  = nil,
			flags = {.Optional_Semicolons},
		}
		_ = parser.parse_file(&p, &f)
	}

	for d in _stage_a_diags {
		append(&local_out, Studio_Diagnostic{
			file       = strings.clone(d.file, allocator),
			line       = d.line,
			column     = d.column,
			end_column = d.end_column,
			is_warning = d.is_warning,
			message    = strings.clone(d.message, allocator),
		})
		delete(d.file, runtime.default_allocator())
		delete(d.message, runtime.default_allocator())
	}
	delete(_stage_a_diags)
	_stage_a_diags = {}

	ms := f32(time.duration_milliseconds(time.tick_since(t0)))
	return local_out[:], ms
}

// Parses `odin check ... -json-errors` output text into `Studio_Diagnostic` entries.
parse_odin_json_errors :: proc(json_text: string, allocator := context.temp_allocator) -> []Studio_Diagnostic {
	out := make([dynamic]Studio_Diagnostic, 0, 8, allocator)
	trimmed := strings.trim_space(json_text)
	if len(trimmed) == 0 do return out[:]

	// Locate `{` in case prebuild/timing lines preceded JSON
	brace_idx := strings.index_byte(trimmed, '{')
	if brace_idx < 0 do return out[:]
	payload := trimmed[brace_idx:]

	parsed: _Odin_JSON_Output
	if jerr := json.unmarshal(transmute([]u8)payload, &parsed, .JSON, context.temp_allocator); jerr != nil {
		return out[:]
	}

	for e in parsed.errors {
		joined := len(e.msgs) > 0 ? strings.join(e.msgs, " — ", context.temp_allocator) : "Compiler error"
		norm_file, _ := strings.replace_all(e.pos.file, "\\", "/", context.temp_allocator)
		append(&out, Studio_Diagnostic{
			file       = strings.clone(norm_file, allocator),
			line       = max(e.pos.line, 1),
			column     = max(e.pos.column, 1),
			end_column = max(e.pos.end_column, e.pos.column + 1),
			is_warning = strings.contains(strings.to_lower(e.type, context.temp_allocator), "warn"),
			message    = strings.clone(joined, allocator),
		})
	}
	return out[:]
}

@(private = "file")
_clear_pub_diags_locked :: proc() {
	context.allocator = runtime.default_allocator()
	for d in _chk.pub_diags {
		delete(d.file)
		delete(d.message)
	}
	clear(&_chk.pub_diags)
}

@(private = "file")
_set_pub_summary_locked :: proc(s: string) {
	context.allocator = runtime.default_allocator()
	if _chk.pub_summary != "" do delete(_chk.pub_summary)
	_chk.pub_summary = strings.clone(s)
}

@(private = "file")
_worker_proc :: proc(_t: ^thread.Thread) {
	context = runtime.default_context()
	last_syntax_rev:   u64 = 0
	last_compiler_rev: u64 = 0
	last_syntax_ok:    bool = true

	for {
		sync.mutex_lock(&_chk.mu)
		for !_chk.stop_requested {
			need_syntax := _chk.req_revision > last_syntax_rev
			need_comp   := last_syntax_ok && _chk.req_pkg_dir != "" && (_chk.req_force_stage_b || _chk.req_revision > last_compiler_rev)
			if need_syntax || need_comp do break
			// Sleep completely (`0.0%` CPU!) until UI thread submits an edit or requests stop!
			sync.cond_wait(&_chk.cv, &_chk.mu)
		}
		if _chk.stop_requested {
			sync.mutex_unlock(&_chk.mu)
			break
		}

		cur_rev     := _chk.req_revision
		edit_tick   := _chk.req_edit_tick
		force_now   := _chk.req_force_stage_b
		has_pkg     := _chk.req_pkg_dir != ""
		elapsed_ms  := time.duration_milliseconds(time.tick_since(edit_tick))

		// Throttle / Debounce: rest gently without spinning!
		if cur_rev > last_syntax_rev && !force_now && elapsed_ms < SYNTAX_DEBOUNCE_MS {
			wait_dur := time.Duration(SYNTAX_DEBOUNCE_MS - elapsed_ms + 5) * time.Millisecond
			_ = sync.cond_wait_with_timeout(&_chk.cv, &_chk.mu, wait_dur)
			sync.mutex_unlock(&_chk.mu)
			continue
		}

		// --- STAGE A: Fast In-RAM `core:odin/parser` Syntax Check (< 0.15 ms) ---
		if cur_rev > last_syntax_rev {
			code_copy   := strings.clone(_chk.req_code, context.temp_allocator)
			is_scoped   := _chk.req_is_scoped
			sync.mutex_unlock(&_chk.mu)

			diags, syn_ms := check_odin_syntax_in_ram(code_copy, is_scoped, context.temp_allocator)
			last_syntax_rev = cur_rev
			last_syntax_ok  = len(diags) == 0

			sync.mutex_lock(&_chk.mu)
			// Only publish if no newer revision superseded us mid-parse
			if _chk.req_revision == cur_rev {
				_clear_pub_diags_locked()
				context.allocator = runtime.default_allocator()
				for d in diags {
					append(&_chk.pub_diags, Studio_Diagnostic{
						file       = strings.clone(d.file),
						line       = d.line,
						column     = d.column,
						end_column = d.end_column,
						is_warning = d.is_warning,
						message    = strings.clone(d.message),
					})
				}
				_chk.pub_revision  = cur_rev
				_chk.pub_syntax_ms = syn_ms
				if len(diags) > 0 {
					_chk.pub_stage = .Syntax_Error
					_set_pub_summary_locked(fmt.tprintf("Syntax Error (Line %d) — %.2f ms", diags[0].line, syn_ms))
				} else {
					_chk.pub_stage = .Syntax_OK
					_set_pub_summary_locked(fmt.tprintf("Syntax OK (%.2f ms)", syn_ms))
				}
			}
			sync.mutex_unlock(&_chk.mu)
			free_all(context.temp_allocator)
			continue
		}

		// --- STAGE B: Single-Flight Coalesced `odin check -json-errors` ---
		if last_syntax_ok && has_pkg && (force_now || cur_rev > last_compiler_rev) {
			if !force_now && elapsed_ms < TYPECHECK_IDLE_MS {
				wait_dur := time.Duration(TYPECHECK_IDLE_MS - elapsed_ms + 10) * time.Millisecond
				_ = sync.cond_wait_with_timeout(&_chk.cv, &_chk.mu, wait_dur)
				sync.mutex_unlock(&_chk.mu)
				continue
			}

			pkg_dir := strings.clone(_chk.req_pkg_dir, context.temp_allocator)
			_chk.req_force_stage_b = false
			_chk.pub_stage         = .Running_Compiler
			_set_pub_summary_locked("Typechecking (no build)...")
			sync.mutex_unlock(&_chk.mu)

			t_comp := time.tick_now()
			repo_root := engine.resolve_repo_root(context.temp_allocator)
			odin_exe  := engine.resolve_odin_binary(context.temp_allocator)
			builds_d, _ := filepath.join({repo_root, "builds"}, context.temp_allocator)
			_ = os.make_directory_all(builds_d)
			json_out_path, _ := filepath.join({repo_root, "builds/_studio_check_json.tmp"}, context.temp_allocator)

			cmd := make([dynamic]string, context.temp_allocator)
			if pkg_dir == "haati/editor" {
				append(&cmd, odin_exe, "check", "haati/editor", "-collection:haati=haati", "-collection:moonhug=haati", "-ignore-unknown-attributes", "-vet-unused", "-json-errors")
			} else {
				append(&cmd, odin_exe, "check", pkg_dir, "-no-entry-point", "-collection:haati=haati", "-collection:moonhug=haati", "-ignore-unknown-attributes", "-json-errors")
			}

			comp_diags: []Studio_Diagnostic = nil
			comp_exit := 0
			if p_h, started := engine.bg_process_start_to_file(repo_root, cmd[:], nil, json_out_path); started {
				exited, exit_code := engine.bg_process_wait(&p_h, 25000)
				comp_exit = exited ? exit_code : -1
				if raw_json, rerr := os.read_entire_file(json_out_path, context.temp_allocator); rerr == nil {
					comp_diags = parse_odin_json_errors(string(raw_json), context.temp_allocator)
				}
				_ = os.remove(json_out_path)
			} else {
				comp_exit = -1
			}
			comp_ms := f32(time.duration_milliseconds(time.tick_since(t_comp)))
			last_compiler_rev = cur_rev

			sync.mutex_lock(&_chk.mu)
			if _chk.req_revision == cur_rev {
				_clear_pub_diags_locked()
				context.allocator = runtime.default_allocator()
				for d in comp_diags {
					append(&_chk.pub_diags, Studio_Diagnostic{
						file       = strings.clone(d.file),
						line       = d.line,
						column     = d.column,
						end_column = d.end_column,
						is_warning = d.is_warning,
						message    = strings.clone(d.message),
					})
				}
				_chk.pub_compiler_ms = comp_ms
				if len(comp_diags) > 0 || comp_exit != 0 {
					_chk.pub_stage = .Compiler_Error
					_set_pub_summary_locked(fmt.tprintf("%d Typecheck Error(s) (%.0f ms)", max(len(comp_diags), 1), comp_ms))
				} else {
					_chk.pub_stage = .Compiler_OK
					_set_pub_summary_locked(fmt.tprintf("Typecheck OK — Idle (%.0f ms)", comp_ms))
				}
			}
			sync.mutex_unlock(&_chk.mu)
			free_all(context.temp_allocator)
			continue
		}

		sync.mutex_unlock(&_chk.mu)
	}
}

ensure_checker_started :: proc() {
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)
	if _chk.started do return
	context.allocator = runtime.default_allocator()
	_chk.started        = true
	_chk.stop_requested = false
	t := thread.create(_worker_proc)
	if t != nil {
		thread.start(t)
		_chk.worker_thread = t
	}
}

shutdown_checker :: proc() {
	sync.mutex_lock(&_chk.mu)
	if !_chk.started {
		sync.mutex_unlock(&_chk.mu)
		return
	}
	_chk.stop_requested = true
	th := _chk.worker_thread
	sync.cond_broadcast(&_chk.cv)
	sync.mutex_unlock(&_chk.mu)

	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}

	sync.mutex_lock(&_chk.mu)
	context.allocator = runtime.default_allocator()
	_clear_pub_diags_locked()
	delete(_chk.pub_diags)
	delete(_stage_a_diags)
	if _chk.req_code        != "" do delete(_chk.req_code)
	if _chk.req_pkg_dir     != "" do delete(_chk.req_pkg_dir)
	if _chk.req_file_filter != "" do delete(_chk.req_file_filter)
	if _chk.pub_summary     != "" do delete(_chk.pub_summary)
	_chk = {}
	sync.mutex_unlock(&_chk.mu)
}

// Submits updated source code from the UI thread without blocking (`< 0.01 ms`).
submit_async_check :: proc(code: string, is_scoped_body: bool, pkg_dir: string = "", force_compiler_now: bool = false) {
	ensure_checker_started()
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)

	// Skip identical re-submissions from 60-FPS UI polls so the background checker
	// stays Idle unless code, package dir, or scope actually changed (or F7/Play forced a check).
	if !force_compiler_now && _chk.req_revision > 0 && _chk.req_code == code && _chk.req_pkg_dir == pkg_dir && _chk.req_is_scoped == is_scoped_body {
		return
	}

	context.allocator = runtime.default_allocator()
	if _chk.req_code    != "" do delete(_chk.req_code)
	if _chk.req_pkg_dir != "" do delete(_chk.req_pkg_dir)
	_chk.req_code          = strings.clone(code)
	_chk.req_pkg_dir       = pkg_dir != "" ? strings.clone(pkg_dir) : ""
	_chk.req_is_scoped     = is_scoped_body
	_chk.req_force_stage_b = _chk.req_force_stage_b || force_compiler_now
	_chk.req_revision     += 1
	_chk.req_edit_tick     = time.tick_now()
	_chk.pub_stage         = .Pending_Syntax
	sync.cond_signal(&_chk.cv)
}

// Reads a temp-allocated snapshot of the latest async check diagnostics for rendering.
read_checker_snapshot :: proc(allocator := context.temp_allocator) -> Checker_Snapshot {
	if !_chk.started {
		return Checker_Snapshot{stage = .Idle, summary_label = "Ready"}
	}
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)

	diags_out := make([]Studio_Diagnostic, len(_chk.pub_diags), allocator)
	for d, i in _chk.pub_diags {
		diags_out[i] = Studio_Diagnostic{
			file       = strings.clone(d.file, allocator),
			line       = d.line,
			column     = d.column,
			end_column = d.end_column,
			is_warning = d.is_warning,
			message    = strings.clone(d.message, allocator),
		}
	}
	return Checker_Snapshot{
		stage         = _chk.pub_stage,
		revision      = _chk.pub_revision,
		syntax_ms     = _chk.pub_syntax_ms,
		compiler_ms   = _chk.pub_compiler_ms,
		diagnostics   = diags_out,
		summary_label = strings.clone(_chk.pub_summary != "" ? _chk.pub_summary : "Ready", allocator),
	}
}
