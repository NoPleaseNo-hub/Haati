package code_studio

// =============================================================================
// ZERO-STUTTER TWO-STAGE THROTTLED SINGLE-FLIGHT ASYNC CHECKER (`async_checker.odin`)
// =============================================================================
// Prevents main-thread stutters AND background CPU starvation while typing:
//   - 1 persistent sleeping worker thread (`sync.Cond`, `0.0%` CPU when idle).
//   - Stage A (`150 ms–5000 ms` debounce, `< 0.15 ms`, zero disk IO, zero OS process):
//     Lock-free TLS `core:odin/parser` on the in-RAM string inside a resettable
//     `mem.Dynamic_Arena` to catch syntax errors almost instantly without stalling UI.
//   - Stage B (single-flight coalesced `odin check -json-errors`, BELOW_NORMAL priority):
//     Stages an isolated `builds/_studio_check_env/` collection mirror (`haati_col`,
//     incremental `proj_mirror/<slug>`, and `pkg_sandbox`) with live dirty-tab RAM
//     overlays so unsaved edits across all workspace/project `.odin`/`.bodin` files
//     typecheck accurately with zero writes into `haati/packages/<slug>`.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "haati:engine"
import crash_journal "haati:engine/crash_journal"

DEFAULT_PROBLEM_CHECK_DELAY_MS :: i64(900)

@(private = "file")
_problem_check_delay_ms: i64 = DEFAULT_PROBLEM_CHECK_DELAY_MS

// Configures the repeatable idle delay (in seconds) waited after the last sequential
// keypress before running syntax/typecheck diagnostics. Clamped to [0.15s, 5.00s].
set_problem_check_delay_sec :: proc(sec: f32) {
	ms := clamp(i64(sec * 1000.0 + 0.5), 150, 5000)
	sync.atomic_store(&_problem_check_delay_ms, ms)
}

get_problem_check_delay_sec :: proc() -> f32 {
	ms := clamp(sync.atomic_load(&_problem_check_delay_ms), 150, 5000)
	return f32(ms) / 1000.0
}

@(private = "file")
_get_problem_delay_ms :: proc() -> f64 {
	return f64(clamp(sync.atomic_load(&_problem_check_delay_ms), 150, 5000))
}

Check_Stage :: enum u8 {
	Idle             = 0,
	Pending_Syntax   = 1,
	Syntax_OK        = 2,
	Syntax_Error     = 3,
	Running_Compiler = 4,
	Compiler_OK      = 5,
	Compiler_Error   = 6,
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

Dirty_File_Overlay :: struct {
	abs_path: string,
	code:     string,
	is_bodin: bool,
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

	// Latest submitted document & dirty-tab RAM overlays from UI thread
	req_revision:      u64,
	req_code:          string,
	req_pkg_dir:       string,
	req_file_abs:      string,
	req_file_filter:   string,
	req_is_scoped:     bool,
	req_force_stage_b: bool,
	req_edit_tick:     time.Tick,
	req_overlays:      [dynamic]Dirty_File_Overlay,

	// Mirror cleanup tracking
	linked_proj_slug:  string,

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

// Lock-free per-thread scratch capture buffer used only inside `check_odin_syntax_in_ram`.
@(private = "file", thread_local)
_stage_a_diags: [dynamic]Studio_Diagnostic
@(private = "file", thread_local)
_stage_a_line_offset: int

@(private = "file")
_stage_a_err_cb :: proc(pos: tokenizer.Pos, msg_fmt: string, args: ..any) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
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

@(private = "file")
_norm_path :: proc(p: string, allocator := context.temp_allocator) -> string {
	res, allocated := strings.replace_all(p, "\\", "/", allocator)
	if !allocated {
		return strings.clone(p, allocator)
	}
	return res
}

@(private = "file")
_norm_path_key :: proc(p: string, allocator := context.temp_allocator) -> string {
	norm := _norm_path(p, context.temp_allocator)
	norm = strings.trim_suffix(norm, "/")
	when ODIN_OS == .Windows {
		return strings.to_lower(norm, allocator)
	} else {
		return strings.clone(norm, allocator)
	}
}

@(private = "file")
_resolve_active_slug_safe :: proc(active_slug: string, allocator := context.temp_allocator) -> string {
	if active_slug != "" {
		return strings.clone(active_slug, allocator)
	}
	if !engine.has_active_project() do return ""
	return engine.active_project_slug(allocator)
}

// Computes the modern `haati:` or `project:` import path for a legacy `moonhug:*` import string.
compute_haati_import_migration :: proc(
	old_imp: string,
	active_slug: string = "",
	allocator := context.temp_allocator,
) -> (new_imp: string, ok: bool) {
	if !strings.has_prefix(old_imp, "moonhug:") {
		return "", false
	}
	rest_raw, _ := strings.replace_all(old_imp[len("moonhug:"):], "\\", "/", context.temp_allocator)
	rest := strings.trim_prefix(strings.trim_space(rest_raw), "/")
	slug := _resolve_active_slug_safe(active_slug, context.temp_allocator)

	if strings.has_prefix(rest, "packages/") {
		pkg_sub := rest[len("packages/"):]
		if slug != "" {
			if pkg_sub == slug {
				return strings.clone("project:.", allocator), true
			}
			pref := fmt.tprintf("%s/", slug)
			if strings.has_prefix(pkg_sub, pref) {
				tail := pkg_sub[len(pref):]
				if tail == "" {
					return strings.clone("project:.", allocator), true
				}
				return fmt.aprintf("project:%s", tail, allocator = allocator), true
			}
		}
		return fmt.aprintf("haati:%s", rest, allocator = allocator), true
	}
	if strings.has_prefix(rest, "app") {
		return fmt.aprintf("haati:packages/%s", rest, allocator = allocator), true
	}
	if rest == "" || rest == "." {
		return strings.clone("haati:.", allocator), true
	}
	return fmt.aprintf("haati:%s", rest, allocator = allocator), true
}

@(private = "file")
_find_legacy_moonhug_on_line :: proc(raw_ln: string) -> (q1_quote, q2_quote: int, old_imp: string, found: bool) {
	ln := strings.trim_suffix(raw_ln, "\r")
	tr := strings.trim_left_space(ln)
	if tr == "" || strings.has_prefix(tr, "//") do return 0, 0, "", false

	// Strip optional `@(...)` prefix such as `@(require)`
	work := tr
	for strings.has_prefix(work, "@(") {
		rp := strings.index_byte(work, ')')
		if rp < 0 do break
		work = strings.trim_left_space(work[rp + 1:])
	}
	if !strings.has_prefix(work, "import ") && !strings.has_prefix(work, "import\t") {
		return 0, 0, "", false
	}

	work_off := len(ln) - len(work)
	if cm := strings.index(work, "//"); cm >= 0 {
		work = work[:cm]
	}
	q1 := strings.index_byte(work, '"')
	if q1 < 0 do return 0, 0, "", false
	q2_rel := strings.index_byte(work[q1 + 1:], '"')
	if q2_rel <= 0 do return 0, 0, "", false

	imp := work[q1 + 1 : q1 + 1 + q2_rel]
	if !strings.has_prefix(imp, "moonhug:") do return 0, 0, "", false
	return work_off + q1, work_off + q1 + 1 + q2_rel, imp, true
}

// Scans Odin source lines for legacy `moonhug:` imports and emits 1-click migrateable warnings.
lint_legacy_moonhug_imports :: proc(
	code: string,
	file_label: string = "buffer.odin",
	active_slug: string = "",
	allocator := context.temp_allocator,
) -> []Studio_Diagnostic {
	out := make([dynamic]Studio_Diagnostic, 0, 4, allocator)
	if !strings.contains(code, "moonhug:") do return out[:]

	slug := _resolve_active_slug_safe(active_slug, context.temp_allocator)
	lines := strings.split_lines(code, context.temp_allocator)
	for raw_ln, idx in lines {
		q1, q2, old_imp, ok_imp := _find_legacy_moonhug_on_line(raw_ln)
		if !ok_imp do continue
		new_imp, ok_mig := compute_haati_import_migration(old_imp, slug, context.temp_allocator)
		if !ok_mig do continue
		append(&out, Studio_Diagnostic{
			file       = strings.clone(file_label, allocator),
			line       = idx + 1,
			column     = q1 + 1,
			end_column = q2 + 2,
			is_warning = true,
			message    = fmt.aprintf("[Legacy Import] Legacy \"moonhug:\" import detected — migrate `%s` -> `%s`", old_imp, new_imp, allocator = allocator),
		})
	}
	return out[:]
}

// Rewrites all active legacy `"moonhug:..."` imports in `src` to `haati:` / `project:` preserving line endings.
migrate_all_legacy_moonhug_imports :: proc(
	src: string,
	active_slug: string = "",
	allocator := context.temp_allocator,
) -> (updated: string, replaced_count: int) {
	if !strings.contains(src, "moonhug:") {
		return strings.clone(src, allocator), 0
	}
	slug := _resolve_active_slug_safe(active_slug, context.temp_allocator)
	sb := strings.builder_make(0, len(src) + 32, allocator)
	i := 0
	for i < len(src) {
		nl_rel := strings.index_byte(src[i:], '\n')
		line_end := nl_rel >= 0 ? i + nl_rel : len(src)
		has_nl := nl_rel >= 0
		has_cr := line_end > i && src[line_end - 1] == '\r'
		content_end := has_cr ? line_end - 1 : line_end
		ln := src[i:content_end]

		if q1, q2, old_imp, ok_imp := _find_legacy_moonhug_on_line(ln); ok_imp {
			if new_imp, ok_mig := compute_haati_import_migration(old_imp, slug, context.temp_allocator); ok_mig {
				strings.write_string(&sb, ln[:q1 + 1])
				strings.write_string(&sb, new_imp)
				strings.write_string(&sb, ln[q2:])
				replaced_count += 1
			} else {
				strings.write_string(&sb, ln)
			}
		} else {
			strings.write_string(&sb, ln)
		}
		if has_cr do strings.write_byte(&sb, '\r')
		if has_nl do strings.write_byte(&sb, '\n')
		i = has_nl ? line_end + 1 : len(src)
	}
	return strings.to_string(sb), replaced_count
}

@(private = "file")
_merge_diagnostics_no_dup_line :: proc(dst: ^[dynamic]Studio_Diagnostic, extra: []Studio_Diagnostic, alloc: mem.Allocator) {
	for ex in extra {
		dup := false
		for d in dst^ {
			if d.line == ex.line && !d.is_warning {
				dup = true
				break
			}
			if d.line == ex.line && d.message == ex.message {
				dup = true
				break
			}
		}
		if !dup {
			append(dst, Studio_Diagnostic{
				file       = strings.clone(ex.file, alloc),
				line       = ex.line,
				column     = ex.column,
				end_column = ex.end_column,
				is_warning = ex.is_warning,
				message    = strings.clone(ex.message, alloc),
			})
		}
	}
}

// Pure in-RAM syntax validation (`< 0.15 ms`, lock-free TLS, zero disk IO, zero process spawn).
// Also callable synchronously in unit tests!
check_odin_syntax_in_ram :: proc(code: string, is_scoped_body: bool, allocator := context.temp_allocator) -> (diags: []Studio_Diagnostic, elapsed_ms: f32) {
	t0 := time.tick_now()

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	local_out := make([dynamic]Studio_Diagnostic, 0, 8, allocator)
	defer {
		for d in _stage_a_diags {
			delete(d.file, runtime.default_allocator())
			delete(d.message, runtime.default_allocator())
		}
		delete(_stage_a_diags)
		_stage_a_diags = {}
	}

	{
		prev_alloc := context.allocator
		context.allocator = mem.dynamic_arena_allocator(&arena)
		defer context.allocator = prev_alloc
		parse_src := code
		trimmed_l := strings.trim_left_space(code)
		needs_decl_pkg := !is_scoped_body && len(trimmed_l) > 0 && !odin_source_has_package_decl(code)
		if needs_decl_pkg {
			parse_src = strings.concatenate({"package _ram_decl\n", code}, context.allocator)
			_stage_a_line_offset = 1
		} else {
			_stage_a_line_offset = is_scoped_body ? 2 : 0
		}
		clear(&_stage_a_diags)
		_, _, _ = parse_odin_in_arena(parse_src, "in_ram_buffer.odin", is_scoped_body, &arena, _stage_a_err_cb)
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
	}

	ms := f32(time.duration_milliseconds(time.tick_since(t0)))
	if len(local_out) == 0 {
		hazards := predict_unsafe_odin_hazards(code, "in_ram_buffer.odin", allocator)
		defer delete(hazards, allocator)
		for h in hazards {
			append(&local_out, h)
		}
	}
	if !is_scoped_body && strings.contains(code, "moonhug:") {
		leg := lint_legacy_moonhug_imports(code, "in_ram_buffer.odin", "", context.temp_allocator)
		_merge_diagnostics_no_dup_line(&local_out, leg, allocator)
	}
	return local_out[:], ms
}

// Proactive lightweight static failure predictor scanning Odin code for common crash & dangling-memory hazards
// (stack slice/pointer returns, unchecked integer-to-rawptr casts, and append()-invalidated slice/elem pointers).
predict_unsafe_odin_hazards :: proc(code: string, file_label: string = "buffer.odin", allocator := context.temp_allocator) -> []Studio_Diagnostic {
	out := make([dynamic]Studio_Diagnostic, allocator)
	if len(code) == 0 do return out[:]

	_is_ident_ch :: #force_inline proc(c: byte) -> bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
	}
	_first_ident :: proc(s: string) -> string {
		t := strings.trim_space(s)
		i := 0
		for i < len(t) && _is_ident_ch(t[i]) do i += 1
		return i > 0 ? t[:i] : ""
	}
	_slice_alias_source :: proc(rhs: string) -> string {
		t := strings.trim_space(rhs)
		if strings.has_prefix(t, "&") {
			rest := strings.trim_space(t[1:])
			nm := _first_ident(rest)
			if nm != "" && len(rest) > len(nm) && rest[len(nm)] == '[' do return nm
		} else {
			nm := _first_ident(t)
			if nm != "" && len(t) > len(nm) + 1 && t[len(nm)] == '[' && strings.contains(t[len(nm):], ":") {
				return nm
			}
		}
		return ""
	}

	stack_locals := make(map[string]int, 8, context.temp_allocator)
	slice_views  := make(map[string]int, 8, context.temp_allocator)

	lines := strings.split_lines(code, context.temp_allocator)
	for raw_ln, idx in lines {
		ln_no := idx + 1
		ln := raw_ln
		if cm := strings.index(ln, "//"); cm >= 0 do ln = ln[:cm]
		trimmed := strings.trim_space(ln)
		if trimmed == "" do continue

		if strings.contains(trimmed, ":: proc") && !strings.has_prefix(trimmed, "\t") && !strings.has_prefix(trimmed, " ") {
			clear(&stack_locals)
			clear(&slice_views)
		}

		if col_eq := strings.index(trimmed, ":="); col_eq > 0 {
			lhs := _first_ident(trimmed[:col_eq])
			rhs := strings.trim_space(trimmed[col_eq + 2:])
			if lhs != "" {
				if strings.has_prefix(rhs, "[") && !strings.has_prefix(rhs, "[dynamic]") && !strings.has_prefix(rhs, "[]") {
					stack_locals[lhs] = ln_no
				} else if !strings.has_prefix(rhs, "[") && !strings.contains(rhs, "make(") && !strings.contains(rhs, "new(") {
					stack_locals[lhs] = ln_no
				}
				if src_arr := _slice_alias_source(rhs); src_arr != "" {
					slice_views[src_arr] = ln_no
				}
			}
		} else if colon := strings.index_byte(trimmed, ':'); colon > 0 && colon + 1 < len(trimmed) && trimmed[colon + 1] != ':' {
			lhs := _first_ident(trimmed[:colon])
			rhs := strings.trim_space(trimmed[colon + 1:])
			if lhs != "" && rhs != "" && !strings.contains(trimmed, "proc(") && !strings.has_prefix(rhs, "[dynamic]") && !strings.has_prefix(rhs, "[]") {
				stack_locals[lhs] = ln_no
			}
		}

		if strings.has_prefix(trimmed, "return ") {
			ret_e := strings.trim_space(trimmed[len("return "):])
			if strings.has_prefix(ret_e, "&") {
				nm := _first_ident(ret_e[1:])
				if _, is_local := stack_locals[nm]; is_local {
					append(&out, Studio_Diagnostic{
						file       = strings.clone(file_label, allocator),
						line       = ln_no,
						column     = 1,
						end_column = len(raw_ln) + 1,
						is_warning = true,
						message    = strings.clone(fmt.tprintf("[UNSAFE] Returning `&%s` escapes stack memory and produces a dangling pointer on return.", nm), allocator),
					})
				}
			} else if br := strings.index_byte(ret_e, '['); br > 0 && strings.contains(ret_e[br:], ":") {
				nm := _first_ident(ret_e[:br])
				if _, is_local := stack_locals[nm]; is_local {
					append(&out, Studio_Diagnostic{
						file       = strings.clone(file_label, allocator),
						line       = ln_no,
						column     = 1,
						end_column = len(raw_ln) + 1,
						is_warning = true,
						message    = strings.clone(fmt.tprintf("[UNSAFE] Returning slice `%s[:]` of a stack-local array returns a dangling pointer.", nm), allocator),
					})
				}
			}
		}

		if strings.contains(trimmed, "rawptr(uintptr(") || strings.contains(trimmed, "cast(rawptr)uintptr(") {
			append(&out, Studio_Diagnostic{
				file       = strings.clone(file_label, allocator),
				line       = ln_no,
				column     = 1,
				end_column = len(raw_ln) + 1,
				is_warning = true,
				message    = strings.clone("[UNSAFE] Casting raw integer to `rawptr` bypasses allocator bounds; call `hot.validate_raw_ptr()` before dereferencing.", allocator),
			})
		}

		if app_idx := strings.index(trimmed, "append(&"); app_idx >= 0 {
			rest := trimmed[app_idx + len("append(&"):]
			arr_nm := _first_ident(rest)
			if view_ln, has_view := slice_views[arr_nm]; has_view {
				append(&out, Studio_Diagnostic{
					file       = strings.clone(file_label, allocator),
					line       = ln_no,
					column     = app_idx + 1,
					end_column = len(raw_ln) + 1,
					is_warning = true,
					message    = strings.clone(fmt.tprintf("[UNSAFE] `append(&%s)` may reallocate heap memory and invalidate the earlier slice/element pointer on line %d.", arr_nm, view_ln), allocator),
				})
			}
		}
	}
	return out[:]
}

// Parses `odin check ... -json-errors` output text into `Studio_Diagnostic` entries,
// elevating fatal syntax/import errors even when Odin tags `type` as `"warning"`.
parse_odin_json_errors :: proc(json_text: string, allocator := context.temp_allocator) -> []Studio_Diagnostic {
	out := make([dynamic]Studio_Diagnostic, 0, 8, allocator)
	trimmed := strings.trim_space(json_text)
	if len(trimmed) == 0 do return out[:]

	brace_idx := strings.index(trimmed, "{\"error_count\"")
	if brace_idx < 0 {
		brace_idx = strings.index_byte(trimmed, '{')
	}
	if brace_idx < 0 do return out[:]
	payload := trimmed[brace_idx:]
	if last_b := strings.last_index_byte(payload, '}'); last_b >= 0 {
		payload = payload[:last_b + 1]
	}

	parsed: _Odin_JSON_Output
	if jerr := json.unmarshal(transmute([]u8)payload, &parsed, .JSON, context.temp_allocator); jerr != nil {
		return out[:]
	}

	for e in parsed.errors {
		joined := len(e.msgs) > 0 ? strings.join(e.msgs, " — ", context.temp_allocator) : "Compiler error"
		type_lo := strings.to_lower(e.type, context.temp_allocator)
		msg_lo  := strings.to_lower(joined, context.temp_allocator)
		is_warn := strings.contains(type_lo, "warn")
		is_fatal_msg := strings.contains(msg_lo, "syntax error") ||
		                strings.contains(msg_lo, "invalid path") ||
		                strings.contains(msg_lo, "cannot find package") ||
		                strings.contains(msg_lo, "does not exist") ||
		                strings.contains(msg_lo, "undeclared name")
		if is_fatal_msg || (parsed.error_count > 0 && parsed.error_count >= len(parsed.errors)) {
			is_warn = false
		}
		norm_file := _norm_path(e.pos.file, context.temp_allocator)
		append(&out, Studio_Diagnostic{
			file       = strings.clone(norm_file, allocator),
			line       = max(e.pos.line, 1),
			column     = max(e.pos.column, 1),
			end_column = max(e.pos.end_column, e.pos.column + 1),
			is_warning = is_warn,
			message    = strings.clone(joined, allocator),
		})
	}
	return out[:]
}

@(private = "file")
_parse_odin_plain_text_errors :: proc(raw_out, fallback_file: string, exit_code: int, allocator := context.temp_allocator) -> []Studio_Diagnostic {
	out := make([dynamic]Studio_Diagnostic, 0, 4, allocator)
	first_meaningful := ""
	for raw_ln in strings.split_lines(raw_out, context.temp_allocator) {
		ln := strings.trim_space(strings.trim_suffix(raw_ln, "\r"))
		if ln == "" do continue
		if first_meaningful == "" && !strings.has_prefix(ln, "{") {
			first_meaningful = ln
		}
		// Match Odin format `<path>(<line>:<col>) <msg>`
		rp := strings.index(ln, ") ")
		if rp > 3 {
			lp := strings.last_index_byte(ln[:rp], '(')
			if lp > 0 {
				coord := ln[lp + 1 : rp]
				if colon := strings.index_byte(coord, ':'); colon > 0 {
					ln_no, ok1 := strconv.parse_int(coord[:colon])
					col_no, ok2 := strconv.parse_int(coord[colon + 1:])
					if ok1 && ok2 && ln_no > 0 {
						f_norm := _norm_path(strings.trim_space(ln[:lp]), context.temp_allocator)
						msg_s := strings.trim_space(ln[rp + 2:])
						if msg_s == "" do msg_s = "Typecheck error"
						append(&out, Studio_Diagnostic{
							file       = strings.clone(f_norm, allocator),
							line       = ln_no,
							column     = max(col_no, 1),
							end_column = max(col_no + 1, 2),
							is_warning = false,
							message    = strings.clone(msg_s, allocator),
						})
					}
				}
			}
		}
	}
	if len(out) == 0 {
		msg := first_meaningful != "" ? first_meaningful : fmt.tprintf("odin check failed (exit %d)", exit_code)
		fb := fallback_file != "" ? _norm_path(fallback_file, allocator) : strings.clone("buffer.odin", allocator)
		append(&out, Studio_Diagnostic{
			file       = fb,
			line       = 1,
			column     = 1,
			end_column = 2,
			is_warning = false,
			message    = strings.clone(msg, allocator),
		})
	}
	return out[:]
}

@(private = "file")
_clear_pub_diags_locked :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for d in _chk.pub_diags {
		delete(d.file)
		delete(d.message)
	}
	clear(&_chk.pub_diags)
}

@(private = "file")
_set_pub_summary_locked :: proc(s: string) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _chk.pub_summary != "" do delete(_chk.pub_summary)
	_chk.pub_summary = strings.clone(s)
}

@(private = "file")
_clear_req_overlays_locked :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for ov in _chk.req_overlays {
		if ov.abs_path != "" do delete(ov.abs_path)
		if ov.code     != "" do delete(ov.code)
	}
	clear(&_chk.req_overlays)
}

// Publishes all open dirty Code Studio tabs so background `odin check` includes unsaved sibling files.
set_checker_dirty_overlays :: proc(overlays: []Dirty_File_Overlay) {
	ensure_checker_started()
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	_clear_req_overlays_locked()
	for ov in overlays {
		if ov.abs_path == "" do continue
		append(&_chk.req_overlays, Dirty_File_Overlay{
			abs_path = _norm_path(ov.abs_path, context.allocator),
			code     = strings.clone(ov.code),
			is_bodin = ov.is_bodin,
		})
	}
}

@(private = "file")
_is_bodin_ram_source :: proc(file_abs, code: string) -> bool {
	if file_abs != "" && strings.has_suffix(strings.to_lower(file_abs, context.temp_allocator), ".bodin") {
		return true
	}
	return strings.contains(code, "// @BODIN_GRAPH_V1") || strings.contains(code, "// @BODIN_GENERATED_BEGIN")
}

@(private = "file")
_extract_bodin_odin_for_check :: proc(raw_bodin: string, allocator := context.temp_allocator) -> string {
	code := raw_bodin
	if b_idx := strings.index(code, engine.BODIN_GRAPH_BEGIN); b_idx >= 0 {
		code = code[:b_idx]
	} else if c_idx := strings.index(code, "/* @BODIN_GRAPH_V1"); c_idx >= 0 {
		code = code[:c_idx]
	}
	sb := strings.builder_make(0, len(code), allocator)
	for raw_ln in strings.split_lines(code, context.temp_allocator) {
		ln := strings.trim_suffix(raw_ln, "\r")
		tr := strings.trim_space(ln)
		// Preserve line count 1:1 with the `.bodin` file when eliding sentinel markers!
		if tr == engine.BODIN_GENERATED_BEGIN || tr == engine.BODIN_GENERATED_END {
			strings.write_byte(&sb, '\n')
			continue
		}
		strings.write_string(&sb, ln)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

@(private = "file")
_clean_dir_regular_files :: proc(abs_dir: string) {
	if abs_dir == "" || !os.is_dir(abs_dir) do return
	if dh, derr := os.open(abs_dir); derr == nil {
		if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.type == .Directory do continue
				if fp, jerr := filepath.join({abs_dir, e.name}, context.temp_allocator); jerr == nil {
					_ = os.remove(fp)
				}
			}
		}
		os.close(dh)
	}
}

@(private = "file")
_unlink_junctions_in_dir :: proc(dir_abs: string) {
	if dir_abs == "" || !os.is_dir(dir_abs) do return
	if dh, derr := os.open(dir_abs); derr == nil {
		if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.name == "." || e.name == ".." do continue
				full, _ := filepath.join({dir_abs, e.name}, context.temp_allocator)
				if e.type == .Directory {
					_ = engine.os_remove_dir_link(full)
				}
			}
		}
		os.close(dh)
	}
}

@(private = "file")
_unlink_checker_env_junctions :: proc(repo_root: string) {
	if repo_root == "" do return
	env_root, _ := filepath.join({repo_root, "builds", "_studio_check_env"}, context.temp_allocator)
	haati_col, _ := filepath.join({env_root, "haati_col"}, context.temp_allocator)
	if !os.is_dir(haati_col) do return

	pkgs_dir, _ := filepath.join({haati_col, "packages"}, context.temp_allocator)
	_unlink_junctions_in_dir(pkgs_dir)
	// Unlink top-level junctions inside `haati_col/` (everything except real `packages/` dir)
	if dh, derr := os.open(haati_col); derr == nil {
		if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.name == "." || e.name == ".." || e.name == "packages" do continue
				if e.type == .Directory {
					full, _ := filepath.join({haati_col, e.name}, context.temp_allocator)
					_ = engine.os_remove_dir_link(full)
				}
			}
		}
		os.close(dh)
	}
}

@(private = "file")
_sync_dir_link :: proc(link_path, target_dir: string) {
	if target_dir == "" || !os.is_dir(target_dir) do return
	if os.is_dir(link_path) do return
	_ = engine.os_create_dir_link(link_path, target_dir)
}

@(private = "file")
_ensure_haati_col_links :: proc(repo_root, env_root: string, proj_slug: string) -> (haati_col_dir: string) {
	haati_col_dir, _ = filepath.join({env_root, "haati_col"}, context.temp_allocator)
	pkgs_col_dir, _ := filepath.join({haati_col_dir, "packages"}, context.temp_allocator)
	_ = os.make_directory_all(pkgs_col_dir)

	src_haati, _ := filepath.join({repo_root, "haati"}, context.temp_allocator)
	if dh, derr := os.open(src_haati); derr == nil {
		if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.type != .Directory || e.name == "packages" do continue
				src_d, _ := filepath.join({src_haati, e.name}, context.temp_allocator)
				dst_d, _ := filepath.join({haati_col_dir, e.name}, context.temp_allocator)
				_sync_dir_link(dst_d, src_d)
			}
		}
		os.close(dh)
	}

	src_pkgs, _ := filepath.join({src_haati, "packages"}, context.temp_allocator)
	if os.is_dir(src_pkgs) {
		if dh, derr := os.open(src_pkgs); derr == nil {
			if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
				for e in entries {
					if e.type != .Directory do continue
					// Keep active project pointed at `proj_mirror/<slug>` rather than `haati/packages/`
					if proj_slug != "" && strings.equal_fold(e.name, proj_slug) do continue
					src_d, _ := filepath.join({src_pkgs, e.name}, context.temp_allocator)
					if !os.is_dir(src_d) do continue
					dst_d, _ := filepath.join({pkgs_col_dir, e.name}, context.temp_allocator)
					_sync_dir_link(dst_d, src_d)
				}
			}
			os.close(dh)
		}
	}

	// Unlink stale project mirror junction when switching active projects
	if _chk.linked_proj_slug != "" && _chk.linked_proj_slug != proj_slug {
		old_link, _ := filepath.join({pkgs_col_dir, _chk.linked_proj_slug}, context.temp_allocator)
		if os.is_dir(old_link) {
			_ = engine.os_remove_dir_link(old_link)
		}
		delete(_chk.linked_proj_slug, runtime.default_allocator())
		_chk.linked_proj_slug = ""
	}
	return haati_col_dir
}

@(private = "file")
_sync_proj_mirror_tree :: proc(
	src_dir, dst_dir: string,
	prev_overlaid: ^map[string]bool,
	staged_map: ^map[string]string,
) {
	_ = os.make_directory_all(dst_dir)
	dh, derr := os.open(src_dir)
	if derr != nil do return
	defer os.close(dh)

	entries, rerr := os.read_dir(dh, -1, context.temp_allocator)
	if rerr != nil do return

	live_names := make(map[string]bool, len(entries) + 4, context.temp_allocator)
	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		if e.type == .Directory {
			if e.name == "builds" || e.name == "cache" || e.name == "Library" || e.name == "Temp" do continue
			sub_src, _ := filepath.join({src_dir, e.name}, context.temp_allocator)
			sub_dst, _ := filepath.join({dst_dir, e.name}, context.temp_allocator)
			live_names[strings.to_lower(e.name, context.temp_allocator)] = true
			_sync_proj_mirror_tree(sub_src, sub_dst, prev_overlaid, staged_map)
			continue
		}
		if e.type != .Regular || !strings.has_suffix(e.name, ".odin") do continue

		src_f, _ := filepath.join({src_dir, e.name}, context.temp_allocator)
		dst_f, _ := filepath.join({dst_dir, e.name}, context.temp_allocator)
		dst_key := _norm_path_key(dst_f, context.temp_allocator)
		live_names[strings.to_lower(e.name, context.temp_allocator)] = true
		staged_map^[dst_key] = _norm_path(src_f, context.temp_allocator)

		need_copy := dst_key in prev_overlaid^
		if !need_copy {
			if dinfo, sterr := os.stat(dst_f, context.temp_allocator); sterr == nil && dinfo.type == .Regular {
				if dinfo.size != e.size || time.diff(dinfo.modification_time, e.modification_time) > 0 {
					need_copy = true
				}
			} else {
				need_copy = true
			}
		}
		if need_copy {
			if raw, rerr2 := os.read_entire_file(src_f, context.temp_allocator); rerr2 == nil {
				_ = os.write_entire_file(dst_f, raw)
			}
		}
	}

	// Remove orphaned mirrored files/dirs deleted from the source tree
	if ddh, dderr := os.open(dst_dir); dderr == nil {
		if dentries, drerr := os.read_dir(ddh, -1, context.temp_allocator); drerr == nil {
			for de in dentries {
				if de.name == "." || de.name == ".." do continue
				if !(strings.to_lower(de.name, context.temp_allocator) in live_names) {
					rm_p, _ := filepath.join({dst_dir, de.name}, context.temp_allocator)
					if de.type == .Regular {
						_ = os.remove(rm_p)
					}
				}
			}
		}
		os.close(ddh)
	}
}

@(private = "file")
_staged_bodin_odin_filename :: proc(file_abs: string, allocator := context.temp_allocator) -> string {
	stem := strings.trim_suffix(filepath.base(file_abs), ".bodin")
	if stem == "" do stem = "custom_graph"
	return fmt.aprintf("%s_mhgraph_generated.odin", engine.vg_sanitize_bp_token(stem, context.temp_allocator), allocator = allocator)
}

@(private = "file")
_dir_of_temp :: proc(p: string) -> string {
	prev := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = prev
	return filepath.dir(p)
}

@(private = "file")
_join_path :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	res, _ := filepath.join(elems, allocator)
	return res
}

@(private = "file")
_write_overlay_file :: proc(
	dst_file, orig_abs, raw_code: string,
	is_bodin: bool,
	staged_map: ^map[string]string,
	new_overlaid: ^map[string]bool,
) -> bool {
	content := is_bodin ? _extract_bodin_odin_for_check(raw_code, context.temp_allocator) : raw_code
	_ = os.make_directory_all(_dir_of_temp(dst_file))
	if os.write_entire_file(dst_file, transmute([]u8)content) != nil {
		return false
	}
	dst_key := _norm_path_key(dst_file, context.temp_allocator)
	staged_map^[dst_key] = _norm_path(orig_abs, context.temp_allocator)
	new_overlaid^[dst_key] = true
	return true
}

@(private = "file")
_stage_check_environment :: proc(
	repo_root, abs_pkg_dir, pkg_dir, file_abs, ram_code: string,
	is_bodin: bool,
	overlays: []Dirty_File_Overlay,
	prev_overlaid: ^map[string]bool,
	allocator := context.temp_allocator,
) -> (
	check_target: string,
	haati_col_dir: string,
	proj_mirror_slug: string,
	proj_root: string,
	proj_slug: string,
	staged_map: map[string]string,
	new_overlaid: map[string]bool,
	ok: bool,
) {
	staged_map = make(map[string]string, 32, allocator)
	new_overlaid = make(map[string]bool, 16, context.temp_allocator)
	env_root, _ := filepath.join({repo_root, "builds", "_studio_check_env"}, context.temp_allocator)
	_ = os.make_directory_all(env_root)

	has_proj := engine.has_active_project()
	proj_root = has_proj ? engine.active_project_root() : ""
	proj_slug = (has_proj && proj_root != "") ? engine.active_project_slug(allocator) : ""

	haati_col_dir = _ensure_haati_col_links(repo_root, env_root, proj_slug)

	// Sync active project mirror if present (never mutating `haati/packages/<slug>`)
	if proj_root != "" && proj_slug != "" && os.is_dir(proj_root) {
		proj_mirror_slug, _ = filepath.join({env_root, "proj_mirror", proj_slug}, allocator)
		_sync_proj_mirror_tree(proj_root, proj_mirror_slug, prev_overlaid, &staged_map)
		pkg_link, _ := filepath.join({haati_col_dir, "packages", proj_slug}, context.temp_allocator)
		_sync_dir_link(pkg_link, proj_mirror_slug)
		if _chk.linked_proj_slug == "" {
			_chk.linked_proj_slug = strings.clone(proj_slug, runtime.default_allocator())
		}

		// Overlay dirty project files into `proj_mirror/<slug>`
		norm_proj_key := _norm_path_key(proj_root, context.temp_allocator)
		for ov in overlays {
			ov_key := _norm_path_key(ov.abs_path, context.temp_allocator)
			if strings.has_prefix(ov_key, norm_proj_key) {
				rel_sub := strings.trim_prefix(_norm_path(ov.abs_path, context.temp_allocator)[len(norm_proj_key):], "/")
				if ov.is_bodin {
					gen_nm := _staged_bodin_odin_filename(ov.abs_path, context.temp_allocator)
					rel_dir := _dir_of_temp(rel_sub)
					dst_ov := (rel_dir == "." || rel_dir == "") ? _join_path({proj_mirror_slug, gen_nm}) : _join_path({proj_mirror_slug, rel_dir, gen_nm})
					_write_overlay_file(dst_ov, ov.abs_path, ov.code, true, &staged_map, &new_overlaid)
				} else {
					dst_ov, _ := filepath.join({proj_mirror_slug, rel_sub}, context.temp_allocator)
					_write_overlay_file(dst_ov, ov.abs_path, ov.code, false, &staged_map, &new_overlaid)
				}
			}
		}

		// If the currently focused buffer is inside the active project, check its mirrored dir!
		file_key := _norm_path_key(file_abs, context.temp_allocator)
		if file_abs != "" && strings.has_prefix(file_key, norm_proj_key) {
			rel_sub := strings.trim_prefix(_norm_path(file_abs, context.temp_allocator)[len(norm_proj_key):], "/")
			rel_dir := _dir_of_temp(rel_sub)
			dst_active: string
			if is_bodin {
				gen_nm := _staged_bodin_odin_filename(file_abs, context.temp_allocator)
				dst_active = (rel_dir == "." || rel_dir == "") ? _join_path({proj_mirror_slug, gen_nm}) : _join_path({proj_mirror_slug, rel_dir, gen_nm})
			} else {
				dst_active, _ = filepath.join({proj_mirror_slug, rel_sub}, context.temp_allocator)
			}
			if _write_overlay_file(dst_active, file_abs, ram_code, is_bodin, &staged_map, &new_overlaid) {
				check_target = (rel_dir == "." || rel_dir == "") ? strings.clone(proj_mirror_slug, allocator) : _join_path({proj_mirror_slug, rel_dir}, allocator)
				return check_target, haati_col_dir, proj_mirror_slug, proj_root, proj_slug, staged_map, new_overlaid, true
			}
		}
	}

	// Packages using relative `"../..."` imports (like `haati/editor`) check their real pkg_dir
	// against `haati_col` so relative paths resolve naturally.
	uses_rel_parent := pkg_dir == "haati/editor" || strings.contains(ram_code, "\"../")
	if uses_rel_parent && abs_pkg_dir != "" && os.is_dir(abs_pkg_dir) && !is_bodin {
		return strings.clone(pkg_dir, allocator), haati_col_dir, proj_mirror_slug, proj_root, proj_slug, staged_map, new_overlaid, true
	}

	// Stage any other workspace/plugin/sandbox `.odin`/`.bodin` package in `pkg_sandbox/`
	sandbox_dir, _ := filepath.join({env_root, "pkg_sandbox"}, context.temp_allocator)
	_ = os.make_directory_all(sandbox_dir)
	_clean_dir_regular_files(sandbox_dir)

	active_is_test := file_abs != "" && strings.has_suffix(file_abs, "_test.odin")
	if abs_pkg_dir != "" && os.is_dir(abs_pkg_dir) {
		if dh, derr := os.open(abs_pkg_dir); derr == nil {
			if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
				for e in entries {
					if e.type != .Regular || !strings.has_suffix(e.name, ".odin") do continue
					if strings.has_suffix(e.name, "_test.odin") && !active_is_test do continue
					src_f, _ := filepath.join({abs_pkg_dir, e.name}, context.temp_allocator)
					dst_f, _ := filepath.join({sandbox_dir, e.name}, context.temp_allocator)
					if raw, rerr2 := os.read_entire_file(src_f, context.temp_allocator); rerr2 == nil {
						if os.write_entire_file(dst_f, raw) == nil {
							staged_map[_norm_path_key(dst_f, context.temp_allocator)] = _norm_path(src_f, context.temp_allocator)
						}
					}
				}
			}
			os.close(dh)
		}
	}

	norm_pkg_key := abs_pkg_dir != "" ? _norm_path_key(abs_pkg_dir, context.temp_allocator) : ""
	for ov in overlays {
		ov_dir_key := _norm_path_key(_dir_of_temp(ov.abs_path), context.temp_allocator)
		if norm_pkg_key != "" && ov_dir_key == norm_pkg_key {
			ov_name := ov.is_bodin ? _staged_bodin_odin_filename(ov.abs_path, context.temp_allocator) : filepath.base(ov.abs_path)
			dst_ov, _ := filepath.join({sandbox_dir, ov_name}, context.temp_allocator)
			tmp_overlaid := make(map[string]bool, 4, context.temp_allocator)
			_write_overlay_file(dst_ov, ov.abs_path, ov.code, ov.is_bodin, &staged_map, &tmp_overlaid)
		}
	}

	if strings.trim_space(ram_code) != "" {
		ov_name := is_bodin ? _staged_bodin_odin_filename(file_abs, context.temp_allocator) : (file_abs != "" ? filepath.base(file_abs) : "in_ram_script.odin")
		orig_label := file_abs != "" ? file_abs : ov_name
		dst_ov, _ := filepath.join({sandbox_dir, ov_name}, context.temp_allocator)
		tmp_overlaid := make(map[string]bool, 4, context.temp_allocator)
		if !_write_overlay_file(dst_ov, orig_label, ram_code, is_bodin, &staged_map, &tmp_overlaid) {
			return "", "", "", "", "", staged_map, new_overlaid, false
		}
	}

	return strings.clone("builds/_studio_check_env/pkg_sandbox", allocator), haati_col_dir, proj_mirror_slug, proj_root, proj_slug, staged_map, new_overlaid, true
}

@(private = "file")
_remap_checker_diag_path :: proc(
	raw_path: string,
	repo_root: string,
	proj_root: string,
	proj_slug: string,
	staged_map: ^map[string]string,
	allocator := context.temp_allocator,
) -> string {
	norm := _norm_path(raw_path, context.temp_allocator)
	key  := _norm_path_key(norm, context.temp_allocator)
	if orig, ok := staged_map^[key]; ok && orig != "" {
		return strings.clone(orig, allocator)
	}
	if !filepath.is_abs(norm) && repo_root != "" {
		abs_joined, _ := filepath.join({repo_root, norm}, context.temp_allocator)
		abs_key := _norm_path_key(abs_joined, context.temp_allocator)
		if orig, ok := staged_map^[abs_key]; ok && orig != "" {
			return strings.clone(orig, allocator)
		}
	}

	if proj_slug != "" && proj_root != "" {
		marker := fmt.tprintf("builds/_studio_check_env/proj_mirror/%s/", proj_slug)
		if idx := strings.index(strings.to_lower(norm, context.temp_allocator), strings.to_lower(marker, context.temp_allocator)); idx >= 0 {
			rel := norm[idx + len(marker):]
			mapped, _ := filepath.join({proj_root, rel}, allocator)
			return _norm_path(mapped, allocator)
		}
	}

	col_marker := "builds/_studio_check_env/haati_col/"
	if idx := strings.index(strings.to_lower(norm, context.temp_allocator), col_marker); idx >= 0 {
		rel := norm[idx + len(col_marker):]
		if !filepath.is_abs(repo_root) {
			return fmt.aprintf("haati/%s", rel, allocator = allocator)
		}
		mapped, _ := filepath.join({repo_root, "haati", rel}, allocator)
		return _norm_path(mapped, allocator)
	}

	if !filepath.is_abs(norm) && repo_root != "" {
		mapped, _ := filepath.join({repo_root, norm}, context.temp_allocator)
		return _norm_path(mapped, allocator)
	}
	return strings.clone(norm, allocator)
}

@(private = "file")
_worker_proc :: proc(_t: ^thread.Thread) {
	context = runtime.default_context()
	context.assertion_failure_proc = crash_journal.assertion_failure

	last_syntax_rev:   u64 = 0
	last_compiler_rev: u64 = 0
	last_syntax_ok:    bool = true
	run_seq:           u64 = 0

	prev_overlaid_mirrors := make(map[string]bool, 8, runtime.default_allocator())
	defer {
		for k in prev_overlaid_mirrors do delete(k, runtime.default_allocator())
		delete(prev_overlaid_mirrors)
	}

	for {
		sync.mutex_lock(&_chk.mu)
		for !_chk.stop_requested {
			need_syntax := _chk.req_revision > last_syntax_rev
			has_stage_b_target := !_chk.req_is_scoped && (_chk.req_pkg_dir != "" || _req_file_valid_for_stage_b(_chk.req_file_abs, _chk.req_code))
			need_comp := last_syntax_ok && has_stage_b_target && (_chk.req_force_stage_b || _chk.req_revision > last_compiler_rev)
			if need_syntax || need_comp do break
			sync.cond_wait(&_chk.cv, &_chk.mu)
		}
		if _chk.stop_requested {
			sync.mutex_unlock(&_chk.mu)
			break
		}

		cur_rev      := _chk.req_revision
		edit_tick    := _chk.req_edit_tick
		force_now    := _chk.req_force_stage_b
		cur_is_bodin := !_chk.req_is_scoped && _is_bodin_ram_source(_chk.req_file_abs, _chk.req_code)
		has_pkg      := !_chk.req_is_scoped && (_chk.req_pkg_dir != "" || _req_file_valid_for_stage_b(_chk.req_file_abs, _chk.req_code))
		elapsed_ms   := time.duration_milliseconds(time.tick_since(edit_tick))
		delay_ms     := _get_problem_delay_ms()

		if cur_rev > last_syntax_rev && !force_now && elapsed_ms < delay_ms {
			wait_dur := time.Duration(delay_ms - elapsed_ms + 10) * time.Millisecond
			_ = sync.cond_wait_with_timeout(&_chk.cv, &_chk.mu, wait_dur)
			sync.mutex_unlock(&_chk.mu)
			continue
		}

		// --- STAGE A: Lock-Free Fast In-RAM `core:odin/parser` Syntax Check (< 0.15 ms) ---
		if cur_rev > last_syntax_rev {
			code_copy   := strings.clone(_chk.req_code, context.temp_allocator)
			file_copy   := strings.clone(_chk.req_file_abs, context.temp_allocator)
			is_scoped   := _chk.req_is_scoped
			sync.mutex_unlock(&_chk.mu)

			diags, syn_ms := check_odin_syntax_in_ram(code_copy, is_scoped, context.temp_allocator)
			last_syntax_rev = cur_rev
			has_syn_errors := false
			first_err_line := 1
			for d in diags {
				if !d.is_warning {
					if !has_syn_errors do first_err_line = d.line
					has_syn_errors = true
				}
			}
			last_syntax_ok = !has_syn_errors

			sync.mutex_lock(&_chk.mu)
			if _chk.req_revision == cur_rev {
				_clear_pub_diags_locked()
				prev_a := context.allocator
				context.allocator = runtime.default_allocator()
				for d in diags {
					df := (d.file == "in_ram_buffer.odin" && file_copy != "") ? file_copy : d.file
					append(&_chk.pub_diags, Studio_Diagnostic{
						file       = strings.clone(df),
						line       = d.line,
						column     = d.column,
						end_column = d.end_column,
						is_warning = d.is_warning,
						message    = strings.clone(d.message),
					})
				}
				_chk.pub_revision  = cur_rev
				_chk.pub_syntax_ms = syn_ms
				if has_syn_errors {
					_chk.pub_stage = .Syntax_Error
					_set_pub_summary_locked(fmt.tprintf("Syntax Error (Line %d) — %.2f ms", first_err_line, syn_ms))
				} else {
					_chk.pub_stage = .Syntax_OK
					_set_pub_summary_locked(fmt.tprintf("Syntax OK (%.2f ms)", syn_ms))
				}
				context.allocator = prev_a
			}
			sync.mutex_unlock(&_chk.mu)
			free_all(context.temp_allocator)
			continue
		}

		// --- STAGE B: Isolated Single-Flight `odin check -json-errors` ---
		if last_syntax_ok && has_pkg && (force_now || cur_rev > last_compiler_rev) {
			if !force_now && elapsed_ms < delay_ms {
				wait_dur := time.Duration(delay_ms - elapsed_ms + 10) * time.Millisecond
				_ = sync.cond_wait_with_timeout(&_chk.cv, &_chk.mu, wait_dur)
				sync.mutex_unlock(&_chk.mu)
				continue
			}

			pkg_dir  := strings.clone(_chk.req_pkg_dir, context.temp_allocator)
			file_abs := strings.clone(_chk.req_file_abs, context.temp_allocator)
			ram_code := strings.clone(_chk.req_code, context.temp_allocator)
			overlays_copy := make([]Dirty_File_Overlay, len(_chk.req_overlays), context.temp_allocator)
			for ov, i in _chk.req_overlays {
				overlays_copy[i] = Dirty_File_Overlay{
					abs_path = strings.clone(ov.abs_path, context.temp_allocator),
					code     = strings.clone(ov.code, context.temp_allocator),
					is_bodin = ov.is_bodin,
				}
			}

			eng_root := engine.engine_root(context.temp_allocator)
			if eng_root == "" {
				eng_root = engine.resolve_repo_root(context.temp_allocator)
			}
			abs_pkg_dir := pkg_dir
			if pkg_dir != "" && !filepath.is_abs(pkg_dir) {
				abs_pkg_dir, _ = filepath.join({eng_root, pkg_dir}, context.temp_allocator)
			}

			_chk.req_force_stage_b = false
			_chk.pub_stage         = .Running_Compiler
			_set_pub_summary_locked("Typechecking RAM Sandbox...")
			sync.mutex_unlock(&_chk.mu)

			run_seq += 1
			t_comp := time.tick_now()
			repo_root := eng_root
			odin_exe  := engine.resolve_odin_binary(context.temp_allocator)
			builds_d, _ := filepath.join({repo_root, "builds"}, context.temp_allocator)
			_ = os.make_directory_all(builds_d)
			json_out_path, _ := filepath.join({repo_root, fmt.tprintf("builds/_studio_check_%d_%d.tmp", os.get_pid(), run_seq)}, context.temp_allocator)

			check_target, haati_col_dir, proj_mirror_slug, proj_root, proj_slug, staged_map, new_overlaid, stage_ok :=
				_stage_check_environment(repo_root, abs_pkg_dir, pkg_dir, file_abs, ram_code, cur_is_bodin, overlays_copy, &prev_overlaid_mirrors, context.temp_allocator)

			for k in prev_overlaid_mirrors do delete(k, runtime.default_allocator())
			clear(&prev_overlaid_mirrors)
			for k, v in new_overlaid {
				if v {
					prev_overlaid_mirrors[strings.clone(k, runtime.default_allocator())] = true
				}
			}

			comp_diags: []Studio_Diagnostic = nil
			comp_exit := 0
			if stage_ok && check_target != "" {
				cmd := make([dynamic]string, context.temp_allocator)
				if check_target == "haati/editor" {
					append(&cmd, odin_exe, "check", "haati/editor")
				} else {
					append(&cmd, odin_exe, "check", check_target, "-no-entry-point")
				}
				append(&cmd,
					"-thread-count:2",
					fmt.tprintf("-collection:haati=%s", haati_col_dir),
					fmt.tprintf("-collection:moonhug=%s", haati_col_dir),
				)
				if proj_mirror_slug != "" && proj_slug != "" {
					append(&cmd,
						fmt.tprintf("-collection:project=%s", proj_mirror_slug),
						fmt.tprintf("-collection:%s=%s", proj_slug, proj_mirror_slug),
					)
				} else if proj_root != "" && proj_slug != "" {
					append(&cmd,
						fmt.tprintf("-collection:project=%s", proj_root),
						fmt.tprintf("-collection:%s=%s", proj_slug, proj_root),
					)
				}
				append(&cmd, "-vet-unused", "-ignore-unknown-attributes", "-json-errors")

				if p_h, started := engine.bg_process_start_to_file(repo_root, cmd[:], nil, json_out_path, true); started {
					exited, exit_code := engine.bg_process_wait(&p_h, 25000)
					comp_exit = exited ? exit_code : -1
					if raw_json, rerr := os.read_entire_file(json_out_path, context.temp_allocator); rerr == nil {
						raw_str := string(raw_json)
						comp_diags = parse_odin_json_errors(raw_str, context.temp_allocator)
						if comp_exit != 0 && len(comp_diags) == 0 {
							fb_file := file_abs != "" ? file_abs : "buffer.odin"
							comp_diags = _parse_odin_plain_text_errors(raw_str, fb_file, comp_exit, context.temp_allocator)
						}
					} else if comp_exit != 0 {
						comp_diags = _parse_odin_plain_text_errors("", file_abs, comp_exit, context.temp_allocator)
					}
					_ = os.remove(json_out_path)
				} else {
					comp_exit = -1
					comp_diags = _parse_odin_plain_text_errors("", file_abs, comp_exit, context.temp_allocator)
				}
			}

			comp_ms := f32(time.duration_milliseconds(time.tick_since(t_comp)))
			last_compiler_rev = cur_rev

			display_file := file_abs != "" ? file_abs : "buffer.odin"
			hazards_b := predict_unsafe_odin_hazards(ram_code, display_file, context.temp_allocator)
			legacy_b  := strings.contains(ram_code, "moonhug:") ? lint_legacy_moonhug_imports(ram_code, display_file, proj_slug, context.temp_allocator) : nil

			// Map staged compiler diagnostics back to exact workspace/project file paths and count real errors.
			final_diags := make([dynamic]Studio_Diagnostic, 0, len(comp_diags) + len(hazards_b) + len(legacy_b), context.temp_allocator)
			hard_err_count := 0
			warn_count := 0
			for d in comp_diags {
				df := _remap_checker_diag_path(d.file, repo_root, proj_root, proj_slug, &staged_map, context.temp_allocator)
				if !d.is_warning {
					hard_err_count += 1
				} else {
					warn_count += 1
				}
				append(&final_diags, Studio_Diagnostic{
					file       = df,
					line       = d.line,
					column     = d.column,
					end_column = d.end_column,
					is_warning = d.is_warning,
					message    = d.message,
				})
			}
			_merge_diagnostics_no_dup_line(&final_diags, hazards_b, context.temp_allocator)
			if len(legacy_b) > 0 {
				_merge_diagnostics_no_dup_line(&final_diags, legacy_b, context.temp_allocator)
			}

			sync.mutex_lock(&_chk.mu)
			if _chk.req_revision == cur_rev {
				_clear_pub_diags_locked()
				prev_a := context.allocator
				context.allocator = runtime.default_allocator()
				for d in final_diags {
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
				if hard_err_count > 0 || comp_exit != 0 {
					_chk.pub_stage = .Compiler_Error
					_set_pub_summary_locked(fmt.tprintf("%d Typecheck Error(s) (%.0f ms)", max(hard_err_count, 1), comp_ms))
				} else if warn_count > 0 || len(final_diags) > 0 {
					_chk.pub_stage = .Compiler_OK
					_set_pub_summary_locked(fmt.tprintf("%d Warning(s) — Idle (%.0f ms)", len(final_diags), comp_ms))
				} else {
					_chk.pub_stage = .Compiler_OK
					_set_pub_summary_locked(fmt.tprintf("Typecheck OK — Idle (%.0f ms)", comp_ms))
				}
				context.allocator = prev_a
			}
			sync.mutex_unlock(&_chk.mu)
			free_all(context.temp_allocator)
			continue
		}

		sync.mutex_unlock(&_chk.mu)
	}
}

@(private = "file")
_req_file_valid_for_stage_b :: proc(file_abs, code: string) -> bool {
	if _is_bodin_ram_source(file_abs, code) do return true
	if file_abs != "" && strings.has_suffix(strings.to_lower(file_abs, context.temp_allocator), ".odin") {
		return true
	}
	return false
}

ensure_checker_started :: proc() {
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)
	if _chk.started do return
	// Sweep stale temp diagnostics from previous crashed sessions for this repo.
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	builds_d, _ := filepath.join({repo_root, "builds"}, context.temp_allocator)
	if dh, derr := os.open(builds_d); derr == nil {
		if entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.type == .Regular && strings.has_prefix(e.name, "_studio_check_") && strings.has_suffix(e.name, ".tmp") {
					full, _ := filepath.join({builds_d, e.name}, context.temp_allocator)
					_ = os.remove(full)
				}
			}
		}
		os.close(dh)
	}
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
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

	repo_root := engine.engine_root(context.temp_allocator)
	if repo_root == "" {
		repo_root = engine.resolve_repo_root(context.temp_allocator)
	}
	_unlink_checker_env_junctions(repo_root)

	sync.mutex_lock(&_chk.mu)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	_clear_pub_diags_locked()
	delete(_chk.pub_diags)
	_clear_req_overlays_locked()
	delete(_chk.req_overlays)
	if _chk.linked_proj_slug != "" do delete(_chk.linked_proj_slug)
	if _chk.req_code         != "" do delete(_chk.req_code)
	if _chk.req_pkg_dir      != "" do delete(_chk.req_pkg_dir)
	if _chk.req_file_abs     != "" do delete(_chk.req_file_abs)
	if _chk.req_file_filter  != "" do delete(_chk.req_file_filter)
	if _chk.pub_summary      != "" do delete(_chk.pub_summary)
	_chk = {}
	context.allocator = prev_alloc
	sync.mutex_unlock(&_chk.mu)
}

// Submits updated source code from the UI thread without blocking (`< 0.01 ms`).
submit_async_check :: proc(code: string, is_scoped_body: bool, pkg_dir: string = "", force_compiler_now: bool = false, file_abs: string = "") {
	ensure_checker_started()
	norm_in := file_abs != "" ? _norm_path(file_abs, context.temp_allocator) : ""
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)

	// Skip identical re-submissions from 60-FPS UI polls so the background checker
	// stays Idle unless code, package dir, file path, or scope actually changed (or F7/Play forced a check).
	if !force_compiler_now && _chk.req_revision > 0 && _chk.req_code == code && _chk.req_pkg_dir == pkg_dir && _chk.req_file_abs == norm_in && _chk.req_is_scoped == is_scoped_body {
		return
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _chk.req_code     != "" do delete(_chk.req_code)
	if _chk.req_pkg_dir  != "" do delete(_chk.req_pkg_dir)
	if _chk.req_file_abs != "" do delete(_chk.req_file_abs)
	_chk.req_code          = strings.clone(code)
	_chk.req_pkg_dir       = pkg_dir != "" ? strings.clone(pkg_dir) : ""
	_chk.req_file_abs      = norm_in != "" ? strings.clone(norm_in) : ""
	_chk.req_is_scoped     = is_scoped_body
	_chk.req_force_stage_b = _chk.req_force_stage_b || force_compiler_now
	_chk.req_revision     += 1
	_chk.req_edit_tick     = time.tick_now()
	_chk.pub_stage         = .Pending_Syntax
	_set_pub_summary_locked("Typing... (checking after idle)")
	sync.cond_signal(&_chk.cv)
}

// Reads a temp-allocated snapshot of the latest async check diagnostics for rendering.
read_checker_snapshot :: proc(allocator := context.temp_allocator) -> Checker_Snapshot {
	if !_chk.started {
		return Checker_Snapshot{stage = .Idle, summary_label = "Ready"}
	}
	sync.mutex_lock(&_chk.mu)
	defer sync.mutex_unlock(&_chk.mu)

	if _chk.pub_stage == .Pending_Syntax {
		return Checker_Snapshot{
			stage         = .Pending_Syntax,
			revision      = _chk.pub_revision,
			syntax_ms     = _chk.pub_syntax_ms,
			compiler_ms   = _chk.pub_compiler_ms,
			diagnostics   = nil,
			summary_label = strings.clone("Typing... (waiting to check)", allocator),
		}
	}

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
