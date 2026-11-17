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
import "core:slice"
import "core:strings"
import "haati:engine"
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

@(private = "file")
_sanitize_partial_for_headers :: proc(src: string, alloc: mem.Allocator, err_cb: parser.Error_Handler = nil) -> string {
	if len(src) == 0 || !strings.contains(src, "for") do return src

	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, src, "buffer.odin", _silent_tok_err)
	tok.flags = {.Insert_Semicolon}

	buf: []byte = nil
	in_for       := false
	semi_count   := 0
	clause_start := false
	paren_d      := 0
	brack_d      := 0

	t := tokenizer.scan(&tok)
	for t.kind != .EOF {
		if t.kind == .Comment {
			t = tokenizer.scan(&tok)
			continue
		}
		if !in_for {
			if t.kind == .For {
				in_for       = true
				semi_count   = 0
				clause_start = false
				paren_d      = 0
				brack_d      = 0
			}
			t = tokenizer.scan(&tok)
			continue
		}

		#partial switch t.kind {
		case .Open_Paren:
			paren_d += 1
			clause_start = false
		case .Close_Paren:
			if paren_d > 0 do paren_d -= 1
			clause_start = false
		case .Open_Bracket:
			brack_d += 1
			clause_start = false
		case .Close_Bracket:
			if brack_d > 0 do brack_d -= 1
			clause_start = false
		case .Open_Brace, .Do, .Close_Brace:
			if paren_d == 0 && brack_d == 0 {
				in_for = false
			}
		case .Semicolon:
			if paren_d == 0 && brack_d == 0 {
				semi_count  += 1
				clause_start = true
				if semi_count > 2 {
					in_for = false
				}
			}
		case .Ident:
			// Guard bundled `core:odin/parser/parser.odin:938` (`assert(as.op.kind == .In)`):
			// after a semicolon inside a `for` header, `<Ident> , ... = ...` triggers `parse_simple_stmt`
			// returning an Assign_Stmt whose `op != .In`. Neutralizing `,` -> `' '` prevents the panic cleanly.
			if clause_start && semi_count == 1 && paren_d == 0 && brack_d == 0 {
				t_next := tokenizer.scan(&tok)
				if t_next.kind == .Comma {
					comma_pos := t_next.pos
					scan_t := tokenizer.scan(&tok)
					pd := 0
					bd := 0
					saw_in := false
					for scan_t.kind != .EOF {
						if pd == 0 && bd == 0 {
							if scan_t.kind == .In {
								saw_in = true
								break
							}
							if scan_t.kind == .Open_Brace || scan_t.kind == .Do || scan_t.kind == .Semicolon {
								break
							}
						}
						if scan_t.kind == .Open_Paren do pd += 1
						else if scan_t.kind == .Close_Paren && pd > 0 do pd -= 1
						else if scan_t.kind == .Open_Bracket do bd += 1
						else if scan_t.kind == .Close_Bracket && bd > 0 do bd -= 1
						else if scan_t.kind == .Open_Brace && pd == 0 && bd == 0 do break
						scan_t = tokenizer.scan(&tok)
					}
					if !saw_in && comma_pos.offset >= 0 && comma_pos.offset < len(src) {
						if buf == nil {
							buf = make([]byte, len(src), alloc)
							copy(buf, src)
						}
						buf[comma_pos.offset] = ' '
						if err_cb != nil {
							err_cb(comma_pos, "expected 'in' after comma in 'for' condition header")
						}
					}
					if scan_t.kind == .Open_Brace || scan_t.kind == .Do {
						in_for = false
					}
					t = scan_t
					clause_start = (t.kind == .Semicolon)
					continue
				}
				clause_start = false
				t = t_next
				continue
			}
			clause_start = false
		case:
			clause_start = false
		}
		t = tokenizer.scan(&tok)
	}
	return buf != nil ? string(buf) : src
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
	used_src = _sanitize_partial_for_headers(used_src, arena_alloc, err_cb)
	file = ast.File{
		src      = used_src,
		fullpath = fullpath,
	}
	p := parser.Parser{
		err   = err_cb != nil ? err_cb : _silent_tok_err,
		warn  = warn_cb != nil ? warn_cb : _silent_tok_err,
		flags = {.Optional_Semicolons},
	}
	prev_alloc := context.allocator
	context.allocator = arena_alloc
	defer context.allocator = prev_alloc
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

// =============================================================================
// READ-ONLY ENGINE BLACKLIST, FULL-DECL PROC SLICER, CALL-SITE AST & SCRATCHPAD
// =============================================================================

// Returns true for protected Haati Engine / editor / built-in runtime scripts that can be inspected
// and copied as text in Blueprint/Code Studio, but must NEVER be mutated in place by visual users.
is_protected_readonly_script_path :: proc(abs_or_rel_path: string) -> bool {
	if abs_or_rel_path == "" do return false
	norm, _ := strings.replace_all(abs_or_rel_path, "\\", "/", context.temp_allocator)
	norm = strings.trim_right(norm, "/")
	lo := strings.to_lower(norm, context.temp_allocator)

	// User project scripts (outside any nested engine dir) are always editable.
	if proj := engine.active_project_root(); proj != "" {
		p_norm, _ := strings.replace_all(proj, "\\", "/", context.temp_allocator)
		p_lo := strings.to_lower(strings.trim_right(p_norm, "/"), context.temp_allocator)
		if p_lo != "" && strings.has_prefix(lo, p_lo) && !strings.contains(lo, "/engine/") {
			return false
		}
	}

	if strings.contains(lo, "builtin_hot_scripts.odin") do return true
	if strings.has_suffix(lo, ".bodin") || strings.has_suffix(lo, "_mhgraph_generated.odin") {
		if !strings.contains(lo, "/haati/engine") && !strings.has_prefix(lo, "haati/engine") &&
		   !strings.contains(lo, "/haati/editor") && !strings.has_prefix(lo, "haati/editor") {
			return false
		}
	}
	if strings.contains(lo, "/assets/scripts/") || strings.has_prefix(lo, "assets/scripts/") {
		return false
	}

	protected_prefixes := [?]string{
		"haati/engine",
		"haati/editor",
		"haati/packages/",
		"plugins/",
		"tools/",
	}
	for pref in protected_prefixes {
		slash_pref := strings.concatenate({"/", pref}, context.temp_allocator)
		if strings.has_prefix(lo, pref) || strings.contains(lo, slash_pref) {
			return true
		}
	}
	return false
}

Parsed_Proc_Param :: struct {
	name:         string,
	type_expr:    string,
	default_expr: string,
	is_ref:       bool,
}

Proc_Full_Decl_Slice :: struct {
	proc_name:       string,
	full_decl_text:  string,
	decl_start_off:  int,
	decl_end_off:    int,
	decl_start_line: int,
	params:          [dynamic]Parsed_Proc_Param,
	results:         [dynamic]Parsed_Proc_Param,
}

Proc_Call_Site :: struct {
	file:           string,
	line:           int,
	col:            int,
	end_col:        int,
	call_start_off: int,
	call_end_off:   int,
	arg_count:      int,
	call_text:      string,
	line_text:      string,
}

Scratch_Decl_Kind :: enum {
	Unknown,
	Proc_Decl,
	Struct_Decl,
	Enum_Decl,
	Const_Decl,
	Var_Decl,
	Field_Decl,
}

destroy_parsed_proc_params :: proc(list: []Parsed_Proc_Param, allocator := context.allocator) {
	for p in list {
		if p.name != "" do delete(p.name, allocator)
		if p.type_expr != "" do delete(p.type_expr, allocator)
		if p.default_expr != "" do delete(p.default_expr, allocator)
	}
}

destroy_proc_full_decl_slice :: proc(s: ^Proc_Full_Decl_Slice, allocator := context.allocator) {
	if s == nil do return
	if s.proc_name != "" do delete(s.proc_name, allocator)
	if s.full_decl_text != "" do delete(s.full_decl_text, allocator)
	destroy_parsed_proc_params(s.params[:], allocator)
	delete(s.params)
	destroy_parsed_proc_params(s.results[:], allocator)
	delete(s.results)
	s^ = {}
}

@(private = "file")
_ast_node_slice_raw :: proc(src: string, n: ^ast.Node) -> string {
	if n == nil do return ""
	s := clamp(n.pos.offset, 0, len(src))
	e := clamp(n.end.offset, s, len(src))
	return strings.trim_space(src[s:e])
}

@(private = "file")
_extract_field_list_params :: proc(src: string, fl: ^ast.Field_List, out: ^[dynamic]Parsed_Proc_Param, allocator := context.allocator) {
	if fl == nil do return
	for fld in fl.list {
		raw_t := fld.type != nil ? _ast_node_slice_raw(src, fld.type) : ""
		is_ref := false
		base_t := raw_t
		if strings.has_prefix(base_t, "^") {
			is_ref = true
			base_t = strings.trim_space(base_t[1:])
		}
		def_t := fld.default_value != nil ? _ast_node_slice_raw(src, fld.default_value) : ""
		if len(fld.names) == 0 {
			append(out, Parsed_Proc_Param{
				name         = strings.clone("", allocator),
				type_expr    = strings.clone(base_t, allocator),
				default_expr = strings.clone(def_t, allocator),
				is_ref       = is_ref,
			})
			continue
		}
		for nm in fld.names {
			nm_txt := _ast_node_slice_raw(src, nm)
			append(out, Parsed_Proc_Param{
				name         = strings.clone(nm_txt, allocator),
				type_expr    = strings.clone(base_t, allocator),
				default_expr = strings.clone(def_t, allocator),
				is_ref       = is_ref,
			})
		}
	}
}

@(private = "file")
_dedent_odin_block_inner :: proc(raw_inner: string, allocator := context.allocator) -> string {
	cleaned := strings.trim_prefix(raw_inner, "\r\n")
	cleaned = strings.trim_prefix(cleaned, "\n")
	cleaned = strings.trim_right(cleaned, " \t\r\n")
	sb := strings.builder_make(0, len(cleaned), allocator)
	lines := strings.split_lines(cleaned, context.temp_allocator)
	for ln, li in lines {
		ln_no_cr := strings.trim_suffix(ln, "\r")
		ded := strings.has_prefix(ln_no_cr, "\t") ? ln_no_cr[1:] : (strings.has_prefix(ln_no_cr, "    ") ? ln_no_cr[4:] : ln_no_cr)
		strings.write_string(&sb, ded)
		if li + 1 < len(lines) do strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// Extracts the complete top-level Odin procedure declaration (`@(...)` attrs + leading `//` doc comments +
// `name :: proc(...) -> ... { ... }`) so popup/split editors can edit full signatures in RAM.
extract_full_odin_procedure_decl :: proc(full_src: string, proc_name: string, allocator := context.allocator) -> (res: Proc_Full_Decl_Slice, ok: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	f, parsed_ok, used_src := parse_odin_in_arena(full_src, "full_decl.odin", false, &arena)
	if !parsed_ok && len(f.decls) == 0 do return {}, false

	line_starts := compute_line_starts(used_src, context.temp_allocator)

	for decl in f.decls {
		vd, is_vd := decl.derived.(^ast.Value_Decl)
		if !is_vd || len(vd.names) == 0 || len(vd.values) == 0 do continue
		ident, is_id := vd.names[0].derived.(^ast.Ident)
		if !is_id || ident.name != proc_name do continue

		plit, is_proc := vd.values[0].derived.(^ast.Proc_Lit)
		if !is_proc || plit.body == nil do continue
		blk, is_blk := plit.body.derived.(^ast.Block_Stmt)
		if !is_blk do continue

		start_ln_idx := clamp(vd.pos.line - 1, 0, max(len(line_starts) - 1, 0))
		for start_ln_idx > 0 {
			p_start := line_starts[start_ln_idx - 1]
			p_end := line_starts[start_ln_idx] - 1
			if p_end < p_start do break
			prev_tr := strings.trim_space(strings.trim_suffix(used_src[p_start:p_end], "\r"))
			if strings.has_prefix(prev_tr, "@(") || strings.has_prefix(prev_tr, "//") {
				start_ln_idx -= 1
			} else {
				break
			}
		}

		decl_start := len(line_starts) > 0 ? min(line_starts[start_ln_idx], vd.pos.offset) : max(vd.pos.offset, 0)
		if decl_start < 0 do decl_start = 0
		decl_end := min(blk.close.offset + 1, len(used_src))
		if decl_end <= decl_start do return {}, false

		res.proc_name       = strings.clone(ident.name, allocator)
		res.full_decl_text  = strings.clone(used_src[decl_start:decl_end], allocator)
		res.decl_start_off  = decl_start
		res.decl_end_off    = decl_end
		res.decl_start_line = start_ln_idx + 1
		res.params          = make([dynamic]Parsed_Proc_Param, 0, 8, allocator)
		res.results         = make([dynamic]Parsed_Proc_Param, 0, 4, allocator)
		if plit.type != nil {
			_extract_field_list_params(used_src, plit.type.params, &res.params, allocator)
			_extract_field_list_params(used_src, plit.type.results, &res.results, allocator)
		}
		return res, true
	}
	return {}, false
}

// Returns true when Odin source starts with a `package <ident>` declaration
// (skipping leading whitespace, `//` comments, `#+` file build tags, and `/* ... */` comments).
odin_source_has_package_decl :: proc(src: string) -> bool {
	if !strings.contains(src, "package") do return false
	in_block_comment := false
	for raw_ln in strings.split_lines(src, context.temp_allocator) {
		ln := strings.trim_space(strings.trim_suffix(raw_ln, "\r"))
		if in_block_comment {
			if idx := strings.index(ln, "*/"); idx >= 0 {
				in_block_comment = false
				ln = strings.trim_space(ln[idx + 2:])
			} else {
				continue
			}
		}
		for strings.has_prefix(ln, "/*") {
			if idx := strings.index(ln[2:], "*/"); idx >= 0 {
				ln = strings.trim_space(ln[2 + idx + 2:])
			} else {
				in_block_comment = true
				ln = ""
				break
			}
		}
		if ln == "" || strings.has_prefix(ln, "//") || strings.has_prefix(ln, "#+") {
			continue
		}
		return strings.has_prefix(ln, "package ") || strings.has_prefix(ln, "package\t")
	}
	return false
}

// Parses a standalone or packaged full procedure declaration into name, parameters, return results, and inner body.
parse_odin_proc_decl_header :: proc(decl_src: string, allocator := context.temp_allocator) -> (
	proc_name:  string,
	params:     []Parsed_Proc_Param,
	results:    []Parsed_Proc_Param,
	body_inner: string,
	ok:         bool,
) {
	trimmed := strings.trim_left_space(decl_src)
	if trimmed == "" do return "", nil, nil, "", false

	needs_pkg := !odin_source_has_package_decl(decl_src)
	parse_src := needs_pkg ? strings.concatenate({"package _ram_decl\n", decl_src}, context.temp_allocator) : decl_src

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	err_cb :: proc(_pos: tokenizer.Pos, _fmt: string, _args: ..any) {
		_ = _pos; _ = _fmt; _ = _args
	}
	f, parsed_ok, used_src := parse_odin_in_arena(parse_src, "decl_header.odin", false, &arena, err_cb)
	if !parsed_ok || len(f.decls) == 0 {
		return "", nil, nil, "", false
	}

	for decl in f.decls {
		vd, is_vd := decl.derived.(^ast.Value_Decl)
		if !is_vd || vd.is_mutable || len(vd.names) == 0 || len(vd.values) == 0 do continue
		ident, is_id := vd.names[0].derived.(^ast.Ident)
		if !is_id || ident.name == "" do continue
		plit, is_proc := vd.values[0].derived.(^ast.Proc_Lit)
		if !is_proc || plit.body == nil do continue
		blk, is_blk := plit.body.derived.(^ast.Block_Stmt)
		if !is_blk do continue

		p_dyn := make([dynamic]Parsed_Proc_Param, 0, 8, allocator)
		r_dyn := make([dynamic]Parsed_Proc_Param, 0, 4, allocator)
		if plit.type != nil {
			_extract_field_list_params(used_src, plit.type.params, &p_dyn, allocator)
			_extract_field_list_params(used_src, plit.type.results, &r_dyn, allocator)
		}

		open_off  := blk.open.offset + 1
		close_off := blk.close.offset
		inner := ""
		if open_off >= 0 && close_off >= open_off && close_off <= len(used_src) {
			inner = _dedent_odin_block_inner(used_src[open_off:close_off], allocator)
		}
		return strings.clone(ident.name, allocator), p_dyn[:], r_dyn[:], inner, true
	}
	return "", nil, nil, "", false
}

// Replaces an entire existing procedure declaration (`@(...)` + doc comments + `name :: proc(...) { ... }`) cleanly.
splice_full_odin_procedure_decl :: proc(full_src: string, old_proc_name: string, new_full_decl: string, allocator := context.allocator) -> (updated_src: string, ok: bool) {
	sliced, found := extract_full_odin_procedure_decl(full_src, old_proc_name, context.temp_allocator)
	if !found do return "", false

	sb := strings.builder_make(0, len(full_src) + len(new_full_decl), allocator)
	strings.write_string(&sb, full_src[:sliced.decl_start_off])
	strings.write_string(&sb, strings.trim_right(new_full_decl, "\r\n"))
	strings.write_string(&sb, full_src[sliced.decl_end_off:])
	return strings.to_string(sb), true
}

// Uses `core:odin/ast.walk` to locate every real Odin call expression invoking `proc_name`,
// ignoring comments and string literals automatically.
find_odin_proc_call_sites :: proc(src: string, file_label: string, proc_name: string, allocator := context.temp_allocator) -> []Proc_Call_Site {
	if src == "" || proc_name == "" || !strings.contains(src, proc_name) {
		return nil
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	f, _, used_src := parse_odin_in_arena(src, file_label != "" ? file_label : "call_sites.odin", false, &arena)
	if len(f.decls) == 0 do return nil

	line_starts := compute_line_starts(used_src, context.temp_allocator)

	_Walk_Ctx :: struct {
		src:         string,
		file_label:  string,
		proc_name:   string,
		line_starts: []int,
		out:         ^[dynamic]Proc_Call_Site,
		alloc:       mem.Allocator,
	}

	out := make([dynamic]Proc_Call_Site, 0, 8, allocator)
	ctx := _Walk_Ctx{
		src         = used_src,
		file_label  = file_label,
		proc_name   = proc_name,
		line_starts = line_starts,
		out         = &out,
		alloc       = allocator,
	}

	vis := ast.Visitor{
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			c := (^_Walk_Ctx)(v.data)
			if ce, is_ce := node.derived.(^ast.Call_Expr); is_ce && ce.expr != nil {
				callee_ok := false
				if id, is_id := ce.expr.derived.(^ast.Ident); is_id {
					callee_ok = id.name == c.proc_name
				} else if se, is_se := ce.expr.derived.(^ast.Selector_Expr); is_se && se.field != nil {
					callee_ok = se.field.name == c.proc_name
				}
				if callee_ok {
					cs := clamp(ce.pos.offset, 0, len(c.src))
					c_end := ce.close.offset >= cs ? min(ce.close.offset + 1, len(c.src)) : min(ce.end.offset, len(c.src))
					ln := max(ce.pos.line, 1)
					ln_text := ""
					if ln - 1 < len(c.line_starts) {
						ls := c.line_starts[ln - 1]
						le := ln < len(c.line_starts) ? c.line_starts[ln] - 1 : len(c.src)
						if le > ls && c.src[le - 1] == '\r' do le -= 1
						if le >= ls do ln_text = c.src[ls:le]
					}
					append(c.out, Proc_Call_Site{
						file           = strings.clone(c.file_label, c.alloc),
						line           = ln,
						col            = max(ce.pos.column, 1),
						end_col        = max(ce.close.column + 1, max(ce.pos.column + len(c.proc_name), 1)),
						call_start_off = cs,
						call_end_off   = c_end,
						arg_count      = len(ce.args),
						call_text      = c_end > cs ? strings.clone(c.src[cs:c_end], c.alloc) : "",
						line_text      = strings.clone(ln_text, c.alloc),
					})
				}
			}
			return v
		},
		data = &ctx,
	}

	for d in f.decls {
		ast.walk(&vis, d)
	}
	slice.sort_by(out[:], proc(a, b: Proc_Call_Site) -> bool {
		if a.line != b.line do return a.line < b.line
		return a.col < b.col
	})
	return out[:]
}

// Classifies an Odin snippet typed inside the `::` Blueprint Omnibar Scratchpad via `core:odin/parser`.
analyze_odin_scratch_snippet :: proc(src: string, allocator := context.temp_allocator) -> (
	kind:       Scratch_Decl_Kind,
	ident_name: string,
	infer_type: string,
	infer_expr: string,
) {
	tr := strings.trim_space(src)
	if tr == "" do return .Unknown, "", "", ""

	infer_lit_type :: proc(expr: ^ast.Expr, expr_txt: string) -> string {
		if expr == nil do return "f32"
		#partial switch v in expr.derived_expr {
		case ^ast.Basic_Lit:
			#partial switch v.tok.kind {
			case .Integer: return "i32"
			case .Float:   return "f32"
			case .String:  return "string"
			}
		case ^ast.Ident:
			if v.name == "true" || v.name == "false" do return "bool"
		case ^ast.Comp_Lit:
			if v.type != nil {
				_ = expr_txt
				return ""
			}
			if len(v.elems) == 2 do return "[2]f32"
			if len(v.elems) == 3 do return "[3]f32"
			if len(v.elems) == 4 do return "[4]f32"
		}
		return "f32"
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	// 1. Try top-level declaration (`foo :: proc`, `Foo :: struct`, `MAX :: 5`, `x := 1.0`)
	pkg_src := odin_source_has_package_decl(src) ? src : strings.concatenate({"package _ram_scratch\n", src}, context.temp_allocator)
	f, _, used_src := parse_odin_in_arena(pkg_src, "scratch.odin", false, &arena)
	for decl in f.decls {
		vd, is_vd := decl.derived.(^ast.Value_Decl)
		if !is_vd || len(vd.names) == 0 do continue
		nm := _ast_node_slice_raw(used_src, vd.names[0])
		if nm == "" do continue
		if len(vd.values) > 0 && vd.values[0] != nil {
			val_node := vd.values[0]
			val_txt := _ast_node_slice_raw(used_src, val_node)
			if !vd.is_mutable {
				#partial switch _ in val_node.derived_expr {
				case ^ast.Proc_Lit:   return .Proc_Decl, strings.clone(nm, allocator), "", ""
				case ^ast.Struct_Type: return .Struct_Decl, strings.clone(nm, allocator), "", ""
				case ^ast.Enum_Type:   return .Enum_Decl, strings.clone(nm, allocator), "", ""
				}
				return .Const_Decl, strings.clone(nm, allocator), "", strings.clone(val_txt, allocator)
			}
			// Mutable `x := expr` or `x: T = expr` -> infer struct field!
			t_str := vd.type != nil ? _ast_node_slice_raw(used_src, vd.type) : infer_lit_type(val_node, val_txt)
			if t_str == "" && vd.type == nil {
				if cl, is_cl := val_node.derived_expr.(^ast.Comp_Lit); is_cl && cl.type != nil {
					t_str = _ast_node_slice_raw(used_src, cl.type)
				}
			}
			if t_str == "" do t_str = "f32"
			return .Var_Decl, strings.clone(nm, allocator), strings.clone(t_str, allocator), strings.clone(val_txt, allocator)
		}
		if vd.type != nil {
			t_str := _ast_node_slice_raw(used_src, vd.type)
			return .Field_Decl, strings.clone(nm, allocator), strings.clone(t_str, allocator), ""
		}
	}

	// 2. Fallback: wrap as struct field (`hp: f32` or `arr: []f32`)
	mem.dynamic_arena_free_all(&arena)
	sf_src := strings.concatenate({"package _ram_scratch\n_S :: struct {\n", src, ",\n}\n"}, context.temp_allocator)
	sf_f, _, sf_used := parse_odin_in_arena(sf_src, "scratch_field.odin", false, &arena)
	for decl in sf_f.decls {
		vd, is_vd := decl.derived.(^ast.Value_Decl)
		if !is_vd || len(vd.values) == 0 do continue
		if st, is_st := vd.values[0].derived_expr.(^ast.Struct_Type); is_st && st.fields != nil && len(st.fields.list) > 0 {
			fld := st.fields.list[0]
			if len(fld.names) > 0 && fld.type != nil {
				fnm := _ast_node_slice_raw(sf_used, fld.names[0])
				ft  := _ast_node_slice_raw(sf_used, fld.type)
				def := fld.default_value != nil ? _ast_node_slice_raw(sf_used, fld.default_value) : ""
				if fnm != "" && ft != "" {
					return .Field_Decl, strings.clone(fnm, allocator), strings.clone(ft, allocator), strings.clone(def, allocator)
				}
			}
		}
	}

	return .Unknown, "", "", ""
}
