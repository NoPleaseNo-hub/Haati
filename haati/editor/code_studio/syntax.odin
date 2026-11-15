package code_studio

// =============================================================================
// PURE-ODIN TOKENIZER SYNTAX HIGHLIGHTER & AST PROCEDURE SLICER (`syntax.odin`)
// =============================================================================
// Uses Odin's built-in `core:odin/tokenizer` and `core:odin/parser` — zero C++
// text-editor dependencies! Provides:
//   1. Fast per-line semantic token coloring (`Keyword`, `Type`, `Attribute`,
//      `String`, `Number`, `Comment`, `Call`, `Operator`, `Ident`).
//   2. Exact AST procedure body slicing & splicing so any `.odin` procedure can
//      be edited safely inside the Scoped Function-Body Popup Micro-IDE!

import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"
import thm "haati:editor/theme"
import im "haati:external/odin-imgui"

Syntax_Role :: thm.Studio_Syntax_Role

Syntax_Span :: struct {
	line:      int, // 1-based line number
	col_start: int, // 0-based byte offset within line
	col_end:   int, // 0-based exclusive byte offset within line
	role:      Syntax_Role,
}

role_color :: proc(role: Syntax_Role, p: ^thm.Theme_Palette) -> im.Vec4 {
	return thm.studio_syntax_color(role, p)
}

@(private = "file")
_is_builtin_odin_type :: proc(ident: string) -> bool {
	switch ident {
	case "bool", "b8", "b16", "b32", "b64",
	     "int", "i8", "i16", "i32", "i64", "i128",
	     "uint", "u8", "u16", "u32", "u64", "u128", "uintptr", "byte",
	     "f16", "f32", "f64",
	     "rune", "string", "cstring", "rawptr", "typeid", "any",
	     "matrix", "quaternion64", "quaternion128", "quaternion256",
	     "Hot_Entity", "Engine_Hot_API", "Hot_Call_Frame", "Hot_Slot",
	     "Transform_Handle", "Handle", "World", "Scene", "Vec2", "Vec3", "Vec4", "Quat":
		return true
	}
	return false
}

@(private = "file")
_silent_tok_err :: proc(_pos: tokenizer.Pos, _fmt: string, _args: ..any) {}

// Tokenizes `src` using `core:odin/tokenizer` into line-relative `Syntax_Span`s.
// Runs in microseconds and never panics on incomplete/broken user code!
tokenize_odin_lines :: proc(src: string, line_starts: []int, allocator := context.temp_allocator) -> []Syntax_Span {
	spans := make([dynamic]Syntax_Span, 0, max(len(src) / 5, 32), allocator)
	if len(src) == 0 || len(line_starts) == 0 do return spans[:]

	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, src, "buffer.odin", _silent_tok_err)
	// Preserve comments so `//` and `/* */` highlight properly!
	tok.flags = {}

	prev_was_at := false
	in_attr_parens := 0

	cur := tokenizer.scan(&tok)
	for cur.kind != .EOF {
		next := tokenizer.scan(&tok)

		role := Syntax_Role.Plain
		if cur.kind == .Comment {
			role = .Comment
		} else if cur.kind == .At {
			role = .Attribute
			prev_was_at = true
		} else if prev_was_at && cur.kind == .Open_Paren {
			role = .Attribute
			in_attr_parens = 1
			prev_was_at = false
		} else if in_attr_parens > 0 {
			role = .Attribute
			if cur.kind == .Open_Paren {
				in_attr_parens += 1
			} else if cur.kind == .Close_Paren {
				in_attr_parens -= 1
			}
		} else {
			prev_was_at = false
			#partial switch cur.kind {
			case .String, .Rune:
				role = .String
			case .Integer, .Float, .Imag:
				role = .Number
			case .Pointer:
				role = .Pin_Ref
			case .Ident:
				if cur.text == "true" || cur.text == "false" || cur.text == "nil" {
					role = .Number
				} else if _is_builtin_odin_type(cur.text) {
					role = .Type
				} else if next.kind == .Open_Paren {
					role = .Call
				} else if len(cur.text) > 0 && cur.text[0] >= 'A' && cur.text[0] <= 'Z' {
					role = .Type
				}
			case:
				if tokenizer.is_keyword(cur.kind) {
					role = .Keyword
				} else if tokenizer.is_operator(cur.kind) {
					role = .Operator
				}
			}
		}

		// Map token across 1 or more lines (handles multiline strings / block comments cleanly)
		t_off := cur.pos.offset
		t_end := min(t_off + len(cur.text), len(src))
		if t_off >= 0 && t_end > t_off && role != .Plain {
			start_ln := clamp(cur.pos.line, 1, len(line_starts))
			for ln := start_ln; ln <= len(line_starts); ln += 1 {
				ln_s := line_starts[ln - 1]
				ln_e := ln < len(line_starts) ? (line_starts[ln] - 1) : len(src)
				if ln_e > ln_s && src[ln_e - 1] == '\r' do ln_e -= 1
				seg_s := max(t_off, ln_s)
				seg_e := min(t_end, ln_e)
				if seg_e > seg_s {
					append(&spans, Syntax_Span{
						line      = ln,
						col_start = seg_s - ln_s,
						col_end   = seg_e - ln_s,
						role      = role,
					})
				}
				if t_end <= ln_e + 2 do break
			}
		}

		cur = next
	}

	return spans[:]
}

compute_line_starts :: proc(src: string, allocator := context.temp_allocator) -> []int {
	starts := make([dynamic]int, 0, 64, allocator)
	append(&starts, 0)
	for i in 0 ..< len(src) {
		if src[i] == '\n' {
			append(&starts, i + 1)
		}
	}
	return starts[:]
}

// =============================================================================
// AST Procedure Slicer & Body Splicer (For Scoped Popup Editing of Existing Procs)
// =============================================================================

Proc_Slice_Result :: struct {
	signature_banner: string, // Locked procedure header line (`my_proc :: proc(...)`)
	body_text:        string, // Inner statements between `{` and `}` (dedented by 1 tab)
	open_brace_off:   int,    // Byte offset right AFTER `{` in full file
	close_brace_off:  int,    // Byte offset OF `}` in full file
	body_first_line:  int,    // 1-based file line of first body line
}

// Parses `code` into `ast.File` inside `arena`, optionally wrapping a scoped node body
// in a 2-line stub procedure with `(api, self, dt)` in scope.
parse_odin_in_arena :: proc(
	code:           string,
	fullpath:       string,
	is_scoped_body: bool,
	arena:          ^mem.Dynamic_Arena,
	err_cb:         parser.Error_Handler = nil,
	warn_cb:        parser.Error_Handler = nil,
) -> (file: ast.File, parsed_ok: bool, used_src: string) {
	arena_alloc := mem.dynamic_arena_allocator(arena)
	used_src = is_scoped_body \
		? strings.concatenate({"package _mh_scoped\n_mh_body :: proc(api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, dt: f32) {\n", code, "\n}\n"}, arena_alloc) \
		: code
	file = ast.File{
		src      = used_src,
		fullpath = fullpath,
	}
	p := parser.Parser{
		err   = err_cb != nil ? err_cb : _silent_tok_err,
		warn  = warn_cb != nil ? warn_cb : _silent_tok_err,
		flags = {.Optional_Semicolons},
	}
	context.allocator = arena_alloc
	parsed_ok = parser.parse_file(&p, &file)
	return file, parsed_ok, used_src
}

slice_odin_procedure :: proc(full_src: string, proc_name: string, allocator := context.allocator) -> (res: Proc_Slice_Result, ok: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	f, parsed_ok, _ := parse_odin_in_arena(full_src, "slice.odin", false, &arena)
	if !parsed_ok && len(f.decls) == 0 {
		return {}, false
	}

	for decl in f.decls {
		vd, is_vd := decl.derived.(^ast.Value_Decl)
		if !is_vd || len(vd.names) == 0 || len(vd.values) == 0 do continue
		ident, is_id := vd.names[0].derived.(^ast.Ident)
		if !is_id || ident.name != proc_name do continue

		plit, is_proc := vd.values[0].derived.(^ast.Proc_Lit)
		if !is_proc || plit.body == nil do continue
		blk, is_blk := plit.body.derived.(^ast.Block_Stmt)
		if !is_blk do continue

		open_off  := blk.open.offset + 1
		close_off := blk.close.offset
		if open_off < 0 || close_off < open_off || close_off > len(full_src) do return {}, false

		sig_start := vd.pos.offset
		sig_end   := blk.open.offset
		sig_raw   := sig_start >= 0 && sig_end > sig_start ? strings.trim_space(full_src[sig_start:sig_end]) : proc_name

		raw_inner := full_src[open_off:close_off]
		raw_inner  = strings.trim_prefix(raw_inner, "\r\n")
		raw_inner  = strings.trim_prefix(raw_inner, "\n")
		raw_inner  = strings.trim_right(raw_inner, " \t\r\n")

		// Dedent 1 leading tab per line so the popup feels clean and spacious
		sb := strings.builder_make(allocator)
		lines := strings.split_lines(raw_inner, context.temp_allocator)
		for ln, li in lines {
			clean := strings.has_prefix(ln, "\t") ? ln[1:] : (strings.has_prefix(ln, "    ") ? ln[4:] : ln)
			strings.write_string(&sb, clean)
			if li + 1 < len(lines) do strings.write_byte(&sb, '\n')
		}

		return Proc_Slice_Result{
			signature_banner = strings.clone(sig_raw, allocator),
			body_text        = strings.to_string(sb),
			open_brace_off   = open_off,
			close_brace_off  = close_off,
			body_first_line  = blk.open.line + 1,
		}, true
	}
	return {}, false
}

// Re-splices an edited scoped procedure body cleanly back into `full_src` with 1-tab indentation!
splice_odin_procedure_body :: proc(full_src: string, proc_name: string, new_body: string, allocator := context.allocator) -> (updated_src: string, ok: bool) {
	sliced, found := slice_odin_procedure(full_src, proc_name, context.temp_allocator)
	if !found do return "", false

	sb := strings.builder_make(allocator)
	strings.write_string(&sb, full_src[:sliced.open_brace_off])
	strings.write_byte(&sb, '\n')

	trimmed := strings.trim_right(new_body, "\r\n")
	if len(trimmed) > 0 {
		for ln in strings.split_lines(trimmed, context.temp_allocator) {
			if len(strings.trim_space(ln)) > 0 {
				strings.write_byte(&sb, '\t')
				strings.write_string(&sb, strings.trim_suffix(ln, "\r"))
			}
			strings.write_byte(&sb, '\n')
		}
	}
	strings.write_string(&sb, full_src[sliced.close_brace_off:])
	return strings.to_string(sb), true
}

// =============================================================================
// UNUSED ODIN IMPORT DETECTION & 1-CLICK COMMENT CLEANUP
// =============================================================================

Unused_Import_Info :: struct {
	line:        int,
	alias:       string,
	import_path: string,
}

@(private = "file")
_derive_import_alias :: proc(import_path: string) -> string {
	p := strings.trim(import_path, "\"`")
	if idx := strings.last_index_byte(p, '/'); idx >= 0 {
		p = p[idx + 1:]
	}
	if idx := strings.last_index_byte(p, ':'); idx >= 0 {
		p = p[idx + 1:]
	}
	return p
}

// Scans Odin source with `core:odin/tokenizer` and returns every non-blank `import`
// whose package alias never appears as an identifier elsewhere in the file.
detect_unused_odin_imports :: proc(src: string, allocator := context.temp_allocator) -> [dynamic]Unused_Import_Info {
	unused := make([dynamic]Unused_Import_Info, 0, 8, allocator)
	if len(src) == 0 || !strings.contains(src, "import") do return unused

	_Import_Decl :: struct {
		line:        int,
		alias:       string,
		import_path: string,
	}
	decls := make([dynamic]_Import_Decl, 0, 16, context.temp_allocator)
	used_idents := make(map[string]bool, 64, context.temp_allocator)

	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, src, "buffer.odin", _silent_tok_err)
	tok.flags = {}

	prev_kind := tokenizer.Token_Kind.Invalid
	cur := tokenizer.scan(&tok)
	for cur.kind != .EOF {
		if cur.kind == .Comment {
			cur = tokenizer.scan(&tok)
			continue
		}
		if cur.kind == .Import && prev_kind != .Foreign {
			t1 := tokenizer.scan(&tok)
			for t1.kind == .Comment {
				t1 = tokenizer.scan(&tok)
			}
			if t1.kind == .Ident {
				t2 := tokenizer.scan(&tok)
				for t2.kind == .Comment {
					t2 = tokenizer.scan(&tok)
				}
				if t2.kind == .String {
					if t1.text != "_" {
						append(&decls, _Import_Decl{
							line        = cur.pos.line,
							alias       = t1.text,
							import_path = strings.trim(t2.text, "\"`"),
						})
					}
					prev_kind = t2.kind
					cur = tokenizer.scan(&tok)
					continue
				}
				prev_kind = cur.kind
				cur = t1
				continue
			} else if t1.kind == .String {
				alias := _derive_import_alias(t1.text)
				if alias != "" && alias != "_" {
					append(&decls, _Import_Decl{
						line        = cur.pos.line,
						alias       = alias,
						import_path = strings.trim(t1.text, "\"`"),
					})
				}
				prev_kind = t1.kind
				cur = tokenizer.scan(&tok)
				continue
			}
		} else if cur.kind == .Ident && prev_kind != .Period {
			used_idents[cur.text] = true
		}

		prev_kind = cur.kind
		cur = tokenizer.scan(&tok)
	}

	for d in decls {
		if !(d.alias in used_idents) {
			append(&unused, Unused_Import_Info{
				line        = d.line,
				alias       = d.alias,
				import_path = d.import_path,
			})
		}
	}
	return unused
}

// Comments out all unused `import` lines in `src` (preserving indentation) so `odin check` succeeds cleanly.
comment_out_unused_odin_imports :: proc(src: string, allocator := context.temp_allocator) -> (updated: string, commented_count: int) {
	unused := detect_unused_odin_imports(src, context.temp_allocator)
	if len(unused) == 0 do return src, 0

	unused_lines := make(map[int]bool, len(unused), context.temp_allocator)
	for u in unused do unused_lines[u.line] = true

	sb := strings.builder_make(allocator)
	lines := strings.split_lines(src, context.temp_allocator)
	has_trailing_nl := strings.has_suffix(src, "\n")
	for ln_raw, i in lines {
		ln := strings.trim_suffix(ln_raw, "\r")
		if unused_lines[i + 1] {
			ws_end := 0
			for ws_end < len(ln) && (ln[ws_end] == ' ' || ln[ws_end] == '\t') {
				ws_end += 1
			}
			if ws_end < len(ln) && !strings.has_prefix(ln[ws_end:], "//") {
				strings.write_string(&sb, ln[:ws_end])
				strings.write_string(&sb, "// ")
				strings.write_string(&sb, ln[ws_end:])
				commented_count += 1
			} else {
				strings.write_string(&sb, ln)
			}
		} else {
			strings.write_string(&sb, ln)
		}
		if i + 1 < len(lines) || has_trailing_nl {
			strings.write_byte(&sb, '\n')
		}
	}
	if commented_count == 0 {
		strings.builder_destroy(&sb)
		return src, 0
	}
	return strings.to_string(sb), commented_count
}
