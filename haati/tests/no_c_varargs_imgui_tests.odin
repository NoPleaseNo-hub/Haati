package tests

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../engine"

@(private = "file")
_collect_non_void_odin_files :: proc(dir: string, out: ^[dynamic]string, alloc := context.temp_allocator) {
	handle, oerr := os.open(dir)
	if oerr != nil do return
	entries, rerr := os.read_dir(handle, -1, alloc)
	os.close(handle)
	if rerr != nil do return
	for e in entries {
		if strings.has_prefix(e.name, ".") || e.name == "external" || e.name == "builds" || e.name == "void_odin" || e.name == "packages" {
			continue
		}
		full := strings.concatenate({dir, "/", e.name}, alloc)
		if strings.contains(full, "void_odin") do continue
		if e.type == .Directory || (e.type == .Symlink && os.is_dir(full)) {
			_collect_non_void_odin_files(full, out, alloc)
		} else if strings.has_suffix(e.name, ".odin") && !strings.has_suffix(e.name, "_generated.odin") {
			append(out, full)
		}
	}
}

@(private = "file")
_unwrap_paren :: proc(e: ^ast.Expr) -> ^ast.Expr {
	cur := e
	for cur != nil {
		if pe, ok := cur.derived.(^ast.Paren_Expr); ok {
			cur = pe.expr
			continue
		}
		break
	}
	return cur
}

// Compile-time string literal or concatenation of string literals / icon constants (no runtime '%' risk).
@(private = "file")
_is_static_fmt_literal :: proc(e: ^ast.Expr) -> bool {
	u := _unwrap_paren(e)
	if u == nil do return false
	#partial switch ex in u.derived {
	case ^ast.Basic_Lit:
		return ex.tok.kind == .String
	case ^ast.Binary_Expr:
		if ex.op.kind != .Add do return false
		return _is_static_fmt_literal(ex.left) && _is_static_fmt_literal(ex.right)
	case ^ast.Selector_Expr:
		if id, ok := ex.expr.derived.(^ast.Ident); ok && id.name == "icons" {
			return true
		}
		return false
	case ^ast.Ident:
		return strings.has_prefix(ex.name, "ICON_")
	}
	return false
}

// Safe C-ABI variadic arg: explicit cstring conversion, fmt.ctprintf, or explicit 32/64-bit C scalar cast.
@(private = "file")
_is_safe_c_vararg :: proc(e: ^ast.Expr) -> bool {
	u := _unwrap_paren(e)
	if u == nil do return false
	#partial switch ex in u.derived {
	case ^ast.Basic_Lit:
		// Only float literals are unambiguous; string/int literals in #c_vararg Odin become 16-byte string or 64-bit int.
		return ex.tok.kind == .Float
	case ^ast.Call_Expr:
		if ex.expr == nil do return false
		if id, ok := ex.expr.derived.(^ast.Ident); ok {
			switch id.name {
			case "cstring", "i32", "u32", "f32", "f64", "c_int", "c_uint":
				return true
			}
		}
		if sel, ok := ex.expr.derived.(^ast.Selector_Expr); ok && sel.field != nil {
			pname := ""
			if pid, pok := sel.expr.derived.(^ast.Ident); pok do pname = pid.name
			fname := sel.field.name
			if (pname == "fmt" && fname == "ctprintf") ||
			   (pname == "strings" && fname == "clone_to_cstring") ||
			   (pname == "c" && (fname == "int" || fname == "uint" || fname == "float" || fname == "double")) {
				return true
			}
		}
		return false
	case ^ast.Type_Cast:
		if ex.type == nil do return false
		if id, ok := ex.type.derived.(^ast.Ident); ok {
			switch id.name {
			case "cstring", "i32", "u32", "f32", "f64":
				return true
			}
		}
		if sel, ok := ex.type.derived.(^ast.Selector_Expr); ok && sel.field != nil {
			if pid, pok := sel.expr.derived.(^ast.Ident); pok && pid.name == "c" {
				return true
			}
		}
		return false
	case ^ast.Ternary_If_Expr:
		return _is_safe_c_vararg(ex.x) && _is_safe_c_vararg(ex.y)
	}
	return false
}

@(private = "file")
_Scan_State :: struct {
	file_rel:      string,
	im_aliases:    []string,
	violations:    ^[dynamic]string,
	visited_calls: int,
	alloc:         mem.Allocator,
}

@(private = "file")
_scan_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil || node.derived == nil do return nil
	st := (^_Scan_State)(v.data)
	if call, ok := node.derived.(^ast.Call_Expr); ok && call.expr != nil {
		st.visited_calls += 1
		if sel, sok := call.expr.derived.(^ast.Selector_Expr); sok && sel.field != nil {
			if recv, rok := sel.expr.derived.(^ast.Ident); rok {
				matched_im := false
				for al in st.im_aliases {
					if recv.name == al {
						matched_im = true
						break
					}
				}
				if matched_im {
					fmt_idx := -1
					switch sel.field.name {
					case "Text", "TextDisabled", "TextWrapped", "BulletText", "SetTooltip", "SetItemTooltip":
						fmt_idx = 0
					case "TextColored", "LabelText":
						fmt_idx = 1
					}
					if fmt_idx >= 0 && len(call.args) > fmt_idx {
						fmt_arg := call.args[fmt_idx]
						line := call.pos.line
						if !_is_static_fmt_literal(fmt_arg) {
							append(st.violations, fmt.aprintf("%s:%d im.%s -> non-literal format string (use widgets.text* or TextUnformatted)", st.file_rel, line, sel.field.name, allocator = st.alloc))
						} else if len(call.args) > fmt_idx + 1 {
							for va in call.args[fmt_idx + 1:] {
								if !_is_safe_c_vararg(va) {
									append(st.violations, fmt.aprintf("%s:%d im.%s -> unsafe #c_vararg argument (use widgets.text*f instead)", st.file_rel, line, sel.field.name, allocator = st.alloc))
									break
								}
							}
						}
					}
				}
			}
		}
	}
	return v
}

@(private = "file")
_for_each_imgui_ast_file :: proc(
	t: ^testing.T,
	user_data: rawptr,
	cb: proc(rel: string, af: ^ast.File, im_aliases: []string, user_data: rawptr),
) -> (scanned_files: int) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	haati_dir, _ := filepath.join({repo_root, "haati"}, context.temp_allocator)
	plugins_dir, _ := filepath.join({repo_root, "plugins"}, context.temp_allocator)

	files := make([dynamic]string, context.temp_allocator)
	_collect_non_void_odin_files(haati_dir, &files, context.temp_allocator)
	_collect_non_void_odin_files(plugins_dir, &files, context.temp_allocator)
	testing.expect(t, len(files) > 50, "expected AST scanner to discover repo .odin files")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	arena_alloc := mem.dynamic_arena_allocator(&arena)

	for abs_path in files {
		data, err := os.read_entire_file(abs_path, arena_alloc)
		if err != nil {
			mem.dynamic_arena_free_all(&arena)
			continue
		}
		src := string(data)
		if !strings.contains(src, "odin-imgui") {
			mem.dynamic_arena_free_all(&arena)
			continue
		}

		rel := abs_path
		if strings.has_prefix(rel, repo_root) {
			rel = strings.trim_left(rel[len(repo_root):], "/\\")
		}

		ast_file: ^ast.File
		{
			context.allocator = arena_alloc
			ast_file = ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
			ast_file.src = src
			ast_file.fullpath = rel
			p := parser.default_parser()
			p.err = nil
			p.warn = nil
			_ = parser.parse_file(&p, ast_file)
		}

		aliases := make([dynamic]string, arena_alloc)
		for imp in ast_file.imports {
			if strings.contains(imp.fullpath, "odin-imgui") {
				if imp.name.text != "" {
					append(&aliases, imp.name.text)
				} else {
					append(&aliases, "odin_imgui")
				}
			}
		}
		if len(aliases) > 0 {
			scanned_files += 1
			cb(rel, ast_file, aliases[:], user_data)
		}
		mem.dynamic_arena_free_all(&arena)
	}
	return scanned_files
}

@(private = "file")
_C_Vararg_Run :: struct {
	violations:    ^[dynamic]string,
	visited_calls: int,
}

@(private = "file")
_check_c_varargs_in_file :: proc(rel: string, af: ^ast.File, im_aliases: []string, user_data: rawptr) {
	run := (^_C_Vararg_Run)(user_data)
	st := _Scan_State{
		file_rel   = rel,
		im_aliases = im_aliases,
		violations = run.violations,
		alloc      = context.temp_allocator,
	}
	vis := ast.Visitor{
		visit = _scan_visit,
		data  = &st,
	}
	ast.walk(&vis, af)
	run.visited_calls += st.visited_calls
}

// AST regression guard: prevents C #c_varargs ABI corruption (e.g., 16-byte Odin string
// passed to %s across multi-line calls as in crash_15572.log) and non-literal format
// string crashes across haati/ and plugins/ (excluding void_odin & external/).
@(test)
test_no_unsafe_c_varargs_or_dynamic_fmt_in_imgui_calls :: proc(t: ^testing.T) {
	violations := make([dynamic]string, context.temp_allocator)
	run := _C_Vararg_Run{violations = &violations}
	scanned_files := _for_each_imgui_ast_file(t, &run, _check_c_varargs_in_file)
	testing.expect(t, scanned_files >= 30 && run.visited_calls >= 500, "expected AST scanner to inspect >= 30 ImGui files and >= 500 calls")

	if len(violations) > 0 {
		max_show := min(len(violations), 60)
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< max_show {
			strings.write_string(&sb, "\n  ")
			strings.write_string(&sb, violations[i])
		}
		if len(violations) > max_show {
			strings.write_string(&sb, "\n  ... (more violations truncated)")
		}
		testing.expectf(t, false, "found %d unsafe im.Text*/Set*Tooltip call(s):%s", len(violations), strings.to_string(sb))
	}
}

@(private = "file")
_Im_Push_Kind :: enum u8 {
	None,
	StyleColor,
	StyleVar,
	ID,
	Font,
	ItemWidth,
	TextWrapPos,
	ClipRect,
}

@(private = "file")
_Push_Stack_Tracker :: struct {
	depth: [len(_Im_Push_Kind)]int,
	line:  [len(_Im_Push_Kind)]int,
	name:  [len(_Im_Push_Kind)]string,
}

@(private = "file")
_Push_Scan_Ctx :: struct {
	rel:           string,
	im_aliases:    []string,
	violations:    ^[dynamic]string,
	alloc:         mem.Allocator,
	is_begin_proc: bool,
}

@(private = "file")
_classify_im_push_or_pop :: proc(expr: ^ast.Expr, im_aliases: []string) -> (kind: _Im_Push_Kind, is_pop: bool, count: int, call_name: string) {
	u := _unwrap_paren(expr)
	if u == nil do return .None, false, 0, ""
	call, ok := u.derived.(^ast.Call_Expr)
	if !ok || call.expr == nil do return .None, false, 0, ""
	sel, sok := call.expr.derived.(^ast.Selector_Expr)
	if !sok || sel.field == nil do return .None, false, 0, ""
	recv, rok := sel.expr.derived.(^ast.Ident)
	if !rok do return .None, false, 0, ""

	matched := false
	for al in im_aliases {
		if recv.name == al {
			matched = true
			break
		}
	}
	if !matched do return .None, false, 0, ""

	pop_count := 1
	if len(call.args) > 0 {
		if arg := _unwrap_paren(call.args[0]); arg != nil {
			if lit, lok := arg.derived.(^ast.Basic_Lit); lok && lit.tok.kind == .Integer {
				if parsed, pok := strconv.parse_int(lit.tok.text); pok && parsed > 0 {
					pop_count = parsed
				}
			}
		}
	}

	fname := sel.field.name
	switch fname {
	case "PushStyleColor", "PushStyleColorImVec4", "PushStyleColorU32":
		return .StyleColor, false, 1, fname
	case "PopStyleColor":
		return .StyleColor, true, pop_count, fname
	case "PushStyleVar", "PushStyleVarImVec2":
		return .StyleVar, false, 1, fname
	case "PopStyleVar":
		return .StyleVar, true, pop_count, fname
	case "PushID", "PushIDInt", "PushIDStr", "PushIDPtr", "PushIDRange":
		return .ID, false, 1, fname
	case "PopID":
		return .ID, true, 1, fname
	case "PushFont", "PushFontFloat":
		return .Font, false, 1, fname
	case "PopFont":
		return .Font, true, 1, fname
	case "PushItemWidth":
		return .ItemWidth, false, 1, fname
	case "PopItemWidth":
		return .ItemWidth, true, 1, fname
	case "PushTextWrapPos":
		return .TextWrapPos, false, 1, fname
	case "PopTextWrapPos":
		return .TextWrapPos, true, 1, fname
	case "PushClipRect":
		return .ClipRect, false, 1, fname
	case "PopClipRect":
		return .ClipRect, true, 1, fname
	}
	return .None, false, 0, ""
}

@(private = "file")
_apply_im_stack_op :: proc(tr: ^_Push_Stack_Tracker, kind: _Im_Push_Kind, is_pop: bool, count: int, line: int, call_name: string) {
	if kind == .None do return
	idx := int(kind)
	if is_pop {
		tr.depth[idx] = max(0, tr.depth[idx] - count)
	} else {
		if tr.depth[idx] == 0 {
			tr.line[idx] = line
			tr.name[idx] = call_name
		}
		tr.depth[idx] += count
	}
}

@(private = "file")
_scan_stmt_for_unpopped_return :: proc(ctx: ^_Push_Scan_Ctx, stmt: ^ast.Stmt, tracker: ^_Push_Stack_Tracker, top_level := false) {
	if stmt == nil || stmt.derived == nil do return
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		sub := tracker^
		for child, ci in s.stmts {
			if top_level && ctx.is_begin_proc && ci == len(s.stmts) - 1 {
				if _, is_ret := child.derived.(^ast.Return_Stmt); is_ret do continue
			}
			_scan_stmt_for_unpopped_return(ctx, child, &sub, false)
		}
	case ^ast.Expr_Stmt:
		kind, is_pop, count, call_name := _classify_im_push_or_pop(s.expr, ctx.im_aliases)
		_apply_im_stack_op(tracker, kind, is_pop, count, stmt.pos.line, call_name)
	case ^ast.Defer_Stmt:
		if es, ok := s.stmt.derived.(^ast.Expr_Stmt); ok {
			kind, is_pop, count, _ := _classify_im_push_or_pop(es.expr, ctx.im_aliases)
			if is_pop {
				_apply_im_stack_op(tracker, kind, true, count, stmt.pos.line, "")
			}
		}
	case ^ast.Return_Stmt:
		for k in 1 ..< len(_Im_Push_Kind) {
			if tracker.depth[k] > 0 {
				append(ctx.violations, fmt.aprintf(
					"%s:%d (im.%s left unpopped before early return at line %d)",
					ctx.rel, tracker.line[k], tracker.name[k], stmt.pos.line,
					allocator = ctx.alloc,
				))
				break
			}
		}
	case ^ast.If_Stmt:
		then_tr := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &then_tr)
		if s.else_stmt != nil {
			else_tr := tracker^
			_scan_stmt_for_unpopped_return(ctx, s.else_stmt, &else_tr)
		}
	case ^ast.When_Stmt:
		then_tr := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &then_tr)
		if s.else_stmt != nil {
			else_tr := tracker^
			_scan_stmt_for_unpopped_return(ctx, s.else_stmt, &else_tr)
		}
	case ^ast.For_Stmt:
		sub := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &sub)
	case ^ast.Range_Stmt:
		sub := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &sub)
	case ^ast.Unroll_Range_Stmt:
		sub := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &sub)
	case ^ast.Switch_Stmt:
		sub := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &sub)
	case ^ast.Type_Switch_Stmt:
		sub := tracker^
		_scan_stmt_for_unpopped_return(ctx, s.body, &sub)
	case ^ast.Case_Clause:
		sub := tracker^
		for child in s.body {
			_scan_stmt_for_unpopped_return(ctx, child, &sub)
		}
	}
}

@(private = "file")
_proc_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil || node.derived == nil do return nil
	ctx := (^_Push_Scan_Ctx)(v.data)
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		for name_expr, idx in n.names {
			proc_name := ""
			if id, ok := name_expr.derived.(^ast.Ident); ok {
				proc_name = strings.to_lower(id.name, context.temp_allocator)
			}
			if idx < len(n.values) && n.values[idx] != nil {
				if pl, ok := _unwrap_paren(n.values[idx]).derived.(^ast.Proc_Lit); ok {
					// Intentional stack-push helpers (e.g. `_push_override_style`, `scoped_style_color`) push onto the caller's stack.
					if !strings.contains(proc_name, "push") && !strings.contains(proc_name, "scoped_") {
						prev_begin := ctx.is_begin_proc
						ctx.is_begin_proc = strings.has_suffix(proc_name, "_begin") || strings.has_prefix(proc_name, "begin_")
						tr: _Push_Stack_Tracker
						_scan_stmt_for_unpopped_return(ctx, pl.body, &tr, true)
						ctx.is_begin_proc = prev_begin
					}
					// Still recurse into pl.body so nested procedures inside it are also visited cleanly with fresh stacks.
					return v
				}
			}
		}
	case ^ast.Proc_Lit:
		// Anonymous or non-Value_Decl proc literals are checked with an empty tracker unless already handled by Value_Decl above.
		return v
	}
	return v
}

@(private = "file")
_check_unpopped_push_in_file :: proc(rel: string, af: ^ast.File, im_aliases: []string, user_data: rawptr) {
	ctx := (^_Push_Scan_Ctx)(user_data)
	ctx.rel = rel
	ctx.im_aliases = im_aliases
	vis := ast.Visitor{
		visit = _proc_visit,
		data  = ctx,
	}
	ast.walk(&vis, af)
}

// AST regression guard: prevents Dear ImGui `SIGABRT` stack-imbalance assertions caused by
// returning early inside a block after `im.Push*` without calling `im.Pop*` first (e.g. crash_9028.log).
@(test)
test_no_unpopped_imgui_push_before_early_return :: proc(t: ^testing.T) {
	violations := make([dynamic]string, context.temp_allocator)
	ctx := _Push_Scan_Ctx{
		violations = &violations,
		alloc      = context.temp_allocator,
	}
	scanned_files := _for_each_imgui_ast_file(t, &ctx, _check_unpopped_push_in_file)
	testing.expect(t, scanned_files >= 30, "expected AST push/pop scanner to inspect >= 30 ImGui files")

	if len(violations) > 0 {
		max_show := min(len(violations), 40)
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< max_show {
			strings.write_string(&sb, "\n  ")
			strings.write_string(&sb, violations[i])
		}
		testing.expectf(t, false, "found %d unpopped im.Push* before early return:%s", len(violations), strings.to_string(sb))
	}
}
