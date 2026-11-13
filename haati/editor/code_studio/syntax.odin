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

Syntax_Role :: enum u8 {
	Plain     = 0,
	Keyword   = 1,
	Type      = 2,
	Attribute = 3,
	String    = 4,
	Number    = 5,
	Comment   = 6,
	Call      = 7,
	Operator  = 8,
	Pin_Ref   = 9, // `^` pointer/reference indicator
}

Syntax_Span :: struct {
	line:      int, // 1-based line number
	col_start: int, // 0-based byte offset within line
	col_end:   int, // 0-based exclusive byte offset within line
	role:      Syntax_Role,
}

role_color :: proc(role: Syntax_Role, p: ^thm.Theme_Palette) -> im.Vec4 {
	light := p.is_light
	switch role {
	case .Keyword:
		return light ? im.Vec4{0.62, 0.14, 0.72, 1.0} : im.Vec4{0.78, 0.52, 0.98, 1.0}
	case .Type:
		return light ? im.Vec4{0.05, 0.48, 0.58, 1.0} : im.Vec4{0.36, 0.84, 0.94, 1.0}
	case .Attribute:
		return light ? im.Vec4{0.72, 0.42, 0.04, 1.0} : im.Vec4{0.98, 0.76, 0.32, 1.0}
	case .String:
		return light ? im.Vec4{0.14, 0.54, 0.22, 1.0} : im.Vec4{0.58, 0.88, 0.54, 1.0}
	case .Number:
		return light ? im.Vec4{0.76, 0.34, 0.08, 1.0} : im.Vec4{0.96, 0.64, 0.38, 1.0}
	case .Comment:
		return p.text_muted
	case .Call:
		return light ? im.Vec4{0.12, 0.38, 0.78, 1.0} : im.Vec4{0.46, 0.74, 1.00, 1.0}
	case .Operator:
		return p.text_secondary
	case .Pin_Ref:
		return light ? im.Vec4{0.82, 0.22, 0.38, 1.0} : im.Vec4{1.00, 0.48, 0.62, 1.0}
	case .Plain:
		return p.text_primary
	}
	return p.text_primary
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

slice_odin_procedure :: proc(full_src: string, proc_name: string, allocator := context.allocator) -> (res: Proc_Slice_Result, ok: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	f := ast.File{
		src      = full_src,
		fullpath = "slice.odin",
	}
	p := parser.Parser{
		err   = _silent_tok_err,
		warn  = _silent_tok_err,
		flags = {.Optional_Semicolons},
	}
	parsed_ok: bool
	{
		context.allocator = mem.dynamic_arena_allocator(&arena)
		parsed_ok = parser.parse_file(&p, &f)
	}
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
