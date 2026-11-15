package code_studio

// =============================================================================
// JETBRAINS / VS SYMBOL STRUCTURE, DOC-COMMENT TOOLTIPS & LINE MANIPULATION
// =============================================================================
// Shared by:
//   - `Odin Micro-Studio` (Left Structure Outline, Breadcrumbs, Symbol Jump `Ctrl+Shift+O`,
//     Idle-Delay Function Doc-Comment Tooltips, and `Alt+Up/Down` Move Line)
//   - `Unified Graph Studio` (Reuses `//` comments above `@(hot_proc)` and Odin procedures
//     as automatic idle-hover node documentation tooltips!)

import "core:os"
import "core:path/filepath"
import "core:strings"
import "haati:engine"

Outline_Symbol_Kind :: enum u8 {
	Proc     = 0,
	Hot_Proc = 1,
	Struct   = 2,
	Enum     = 3,
}

Outline_Symbol :: struct {
	name:        string,
	kind:        Outline_Symbol_Kind,
	line:        int,    // 1-based line number
	signature:   string, // trimmed declaration header
	doc_comment: string, // contiguous `//` lines immediately above declaration / attributes
}

is_odin_ident_start :: #force_inline proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

is_odin_ident_char :: #force_inline proc(c: byte) -> bool {
	return is_odin_ident_start(c) || (c >= '0' && c <= '9')
}

is_valid_odin_ident :: #force_inline proc(s: string) -> bool {
	if len(s) == 0 || !is_odin_ident_start(s[0]) do return false
	for i in 1 ..< len(s) {
		if !is_odin_ident_char(s[i]) do return false
	}
	return true
}

sanitize_odin_ident :: proc(raw: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(raw) {
		c := raw[i]
		if (i == 0 ? is_odin_ident_start(c) : is_odin_ident_char(c)) {
			strings.write_byte(&sb, c)
		} else {
			strings.write_byte(&sb, '_')
		}
	}
	res := strings.to_string(sb)
	return len(res) > 0 ? res : "unnamed"
}

// Extracts `receiver` before `.` or `^.` immediately preceding `ident_start`, ignoring `..` / `..<` ranges.
extract_dot_receiver_before :: proc(src: string, ident_start: int) -> string {
	dot_idx := ident_start - 1
	if dot_idx < 0 || dot_idx >= len(src) || src[dot_idx] != '.' do return ""
	if dot_idx > 0 && src[dot_idx - 1] == '.' do return ""
	rec_end := dot_idx
	if rec_end > 0 && src[rec_end - 1] == '^' {
		rec_end -= 1
	}
	rec_start := rec_end
	for rec_start > 0 && is_odin_ident_char(src[rec_start - 1]) {
		rec_start -= 1
	}
	return rec_end > rec_start ? src[rec_start:rec_end] : ""
}

// Extracts the identifier and optional `.` / `^.` receiver spanning byte column `col`.
odin_ident_at :: proc(line: string, col: int) -> (ident: string, receiver: string, ok: bool) {
	if col < 0 || col >= len(line) || !is_odin_ident_char(line[col]) do return "", "", false
	ws := col
	for ws > 0 && is_odin_ident_char(line[ws - 1]) do ws -= 1
	we := col + 1
	for we < len(line) && is_odin_ident_char(line[we]) do we += 1
	return line[ws:we], extract_dot_receiver_before(line, ws), true
}

extract_odin_package_name :: proc(src: string) -> string {
	for raw_ln in strings.split_lines(src, context.temp_allocator) {
		ln := strings.trim_space(strings.trim_suffix(raw_ln, "\r"))
		if strings.has_prefix(ln, "package ") {
			rest := strings.trim_space(ln[len("package "):])
			end := 0
			for end < len(rest) && is_odin_ident_char(rest[end]) {
				end += 1
			}
			if end > 0 do return rest[:end]
		}
	}
	return "main"
}

// Extracts top-level Odin procedures, `@(hot_proc)` entries, structs, and enums along with
// any contiguous `//` doc-comment block written above them (walking past `@(...)` attributes!).
extract_odin_outline_symbols :: proc(src: string, allocator := context.temp_allocator) -> []Outline_Symbol {
	lines := strings.split_lines(src, context.temp_allocator)
	out   := make([dynamic]Outline_Symbol, 0, 24, allocator)

	for i in 0 ..< len(lines) {
		ln := strings.trim_space(strings.trim_suffix(lines[i], "\r"))
		if ln == "" || strings.has_prefix(ln, "//") || strings.has_prefix(ln, "@(") do continue
		// Only consider unindented top-level declarations
		raw_no_cr := strings.trim_suffix(lines[i], "\r")
		if len(raw_no_cr) > 0 && (raw_no_cr[0] == ' ' || raw_no_cr[0] == '\t') do continue

		cc := strings.index(ln, "::")
		if cc <= 0 do continue
		lhs := strings.trim_space(ln[:cc])
		if !is_valid_odin_ident(lhs) do continue

		rhs := strings.trim_space(ln[cc + 2:])
		kind: Outline_Symbol_Kind
		matched := false
		if strings.has_prefix(rhs, "proc") || strings.has_prefix(rhs, "#force_inline proc") {
			kind    = .Proc
			matched = true
		} else if strings.has_prefix(rhs, "struct") {
			kind    = .Struct
			matched = true
		} else if strings.has_prefix(rhs, "enum") {
			kind    = .Enum
			matched = true
		}
		if !matched do continue

		// Walk upward past `@(...)` attributes to gather `//` doc-comments AND detect `@(hot_proc)`!
		is_hot := false
		scan   := i - 1
		for scan >= 0 {
			prev := strings.trim_space(strings.trim_suffix(lines[scan], "\r"))
			if strings.has_prefix(prev, "@") {
				if strings.contains(prev, "hot_proc") do is_hot = true
				scan -= 1
			} else {
				break
			}
		}
		if kind == .Proc && is_hot {
			kind = .Hot_Proc
		}

		doc_end := scan
		for scan >= 0 {
			prev := strings.trim_space(strings.trim_suffix(lines[scan], "\r"))
			if strings.has_prefix(prev, "//") && !strings.has_prefix(prev, "// ===") && !strings.has_prefix(prev, "// ---") && !strings.has_prefix(prev, "// @BODIN") {
				scan -= 1
			} else {
				break
			}
		}
		doc_start := scan + 1
		doc_str   := ""
		if doc_start <= doc_end {
			db := strings.builder_make(0, 128, allocator)
			for di in doc_start ..= doc_end {
				raw_c := strings.trim_space(strings.trim_suffix(lines[di], "\r"))
				clean := strings.trim_space(strings.trim_prefix(raw_c, "//"))
				if clean == "" do continue
				if strings.builder_len(db) > 0 do strings.write_byte(&db, '\n')
				strings.write_string(&db, clean)
			}
			doc_str = strings.to_string(db)
		}

		sig := ln
		if brace := strings.index_byte(sig, '{'); brace > 0 {
			sig = strings.trim_space(sig[:brace])
		}

		append(&out, Outline_Symbol{
			name        = strings.clone(lhs, allocator),
			kind        = kind,
			line        = i + 1,
			signature   = strings.clone(sig, allocator),
			doc_comment = doc_str,
		})
	}
	return out[:]
}

// Returns the doc-comment written above `proc_name` in `src` (or `""` if none).
extract_odin_proc_doc_comment :: proc(src: string, proc_name: string, allocator := context.temp_allocator) -> string {
	if src == "" || proc_name == "" do return ""
	syms := extract_odin_outline_symbols(src, context.temp_allocator)
	for s in syms {
		if s.name == proc_name && s.doc_comment != "" {
			return strings.clone(s.doc_comment, allocator)
		}
	}
	return ""
}

// Reads `abs_or_rel_path` (resolving against repo root if relative) and returns the `//` doc-comment above `proc_name`.
extract_odin_proc_doc_from_file :: proc(abs_or_rel_path: string, proc_name: string, allocator := context.temp_allocator) -> string {
	if abs_or_rel_path == "" || proc_name == "" do return ""
	cand := abs_or_rel_path
	if !os.exists(cand) {
		repo_root := engine.resolve_repo_root(context.temp_allocator)
		cand, _ = filepath.join({repo_root, abs_or_rel_path}, context.temp_allocator)
	}
	data, err := os.read_entire_file(cand, context.temp_allocator)
	if err != nil do return ""
	return extract_odin_proc_doc_comment(string(data), proc_name, allocator)
}

// Finds which top-level symbol encloses `caret_line` for the JetBrains/VS Breadcrumb bar!
enclosing_odin_symbol_at_line :: proc(symbols: []Outline_Symbol, caret_line: int) -> (name: string, kind: Outline_Symbol_Kind, ok: bool) {
	best_idx := -1
	for s, i in symbols {
		if s.line <= caret_line {
			best_idx = i
		} else {
			break
		}
	}
	if best_idx >= 0 {
		return symbols[best_idx].name, symbols[best_idx].kind, true
	}
	return "", .Proc, false
}

// Moves the line containing `cursor_pos` up (`dir = -1`) or down (`dir = +1`), preserving caret column!
move_line_in_source :: proc(src: string, cursor_pos: int, dir: int, allocator := context.temp_allocator) -> (updated: string, new_cursor_pos: int, changed: bool) {
	if len(src) == 0 || (dir != -1 && dir != 1) do return src, cursor_pos, false
	cpos := clamp(cursor_pos, 0, len(src))
	lines := strings.split_lines(src, context.temp_allocator)
	if len(lines) <= 1 do return src, cursor_pos, false

	// Locate current line index and column offset
	off := 0
	cur_idx := 0
	col_off := 0
	for ln, i in lines {
		ln_len := len(ln)
		if cpos <= off + ln_len || i == len(lines) - 1 {
			cur_idx = i
			col_off = clamp(cpos - off, 0, ln_len)
			break
		}
		off += ln_len + 1
	}

	target_idx := cur_idx + dir
	if target_idx < 0 || target_idx >= len(lines) do return src, cursor_pos, false

	// Swap lines
	lines[cur_idx], lines[target_idx] = lines[target_idx], lines[cur_idx]

	sb := strings.builder_make(0, len(src) + 4, allocator)
	new_cpos := 0
	for ln, i in lines {
		if i > 0 do strings.write_byte(&sb, '\n')
		if i == target_idx {
			new_cpos = strings.builder_len(sb) + min(col_off, len(ln))
		}
		strings.write_string(&sb, ln)
	}
	return strings.to_string(sb), new_cpos, true
}
