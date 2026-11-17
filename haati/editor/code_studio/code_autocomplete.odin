package code_studio

// =============================================================================
// THROTTLED ASYNC SMART AUTOCOMPLETE ENGINE (`code_autocomplete.odin`)
// =============================================================================
// Zero-stutter, context-aware Odin autocomplete built on `core:odin/parser`:
//   - 1 persistent sleeping worker thread (`sync.Cond`, `0.0%` CPU when idle,
//     `120 ms` debounce so typing never floods cores or blocks the main thread).
//   - Understands:
//       1. Scoped Node Pins (`● Copy` vs `◆ ^Ref` with dereference hints & types)
//       2. Local variables, loop iterators, constants, procs & structs in the live buffer
//       3. Sibling `.odin` package procs, structs (with fields!), and enums
//       4. Dot-Member Completion (`hot.`, `api.`, `math.`, `linalg.`, vector `.x/.y/.z/.w`,
//          and AST-indexed struct fields!)
//       5. Fuzzy prefix + camelCase/snake_case subsequence ranking.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "haati:engine"
import crash_journal "haati:engine/crash_journal"

AUTOCOMPLETE_DEBOUNCE_MS :: 120
AUTOCOMPLETE_MAX_RESULTS :: 12

Completion_Kind :: enum u8 {
	Pin_Ref   = 0, // `◆ ^Ref` mutable pointer pin
	Pin_Copy  = 1, // `● Copy` value pin
	Pin_Out   = 2, // `-> Out` output pin
	Local_Var = 3, // Local variable or parameter
	Field     = 4, // Struct / vector member field
	Hot_API   = 5, // `hot.*` or `api.*` hot-cartridge helper
	Procedure = 6, // Odin `proc`
	Type_Sym  = 7, // Struct / Enum / Built-in type
	Keyword   = 8, // Odin keyword / built-in
}

Indexed_Symbol :: struct {
	name:        string,
	insert_text: string,
	detail:      string, // Type or signature badge shown on right of popup
	kind:        Completion_Kind,
	receiver:    string, // Empty for free identifiers; `"hot"`, `"math"`, or struct name for `.member`
}

Autocomplete_Item :: struct {
	label:       string,
	insert_text: string,
	detail:      string,
	kind:        Completion_Kind,
	score:       int,
}

@(private = "file")
_AC_Worker_State :: struct {
	started:        bool,
	stop_requested: bool,
	worker_thread:  ^thread.Thread,
	mu:             sync.Mutex,
	cv:             sync.Cond,

	// Latest indexing request from UI thread
	req_revision:   u64,
	req_code:       string,
	req_is_scoped:  bool,
	req_pkg_dir:    string,
	req_edit_tick:  time.Tick,

	// Cached package-level symbols (re-indexed only when `pkg_dir` or `extra_dirs_key` changes)
	req_extra_dirs:    string, // `;`-joined repo-relative package dirs (`alias=dir;alias2=dir2`)
	cached_pkg_dir:    string,
	cached_extra_dirs: string,
	pkg_symbols:       [dynamic]Indexed_Symbol,

	// Published buffer-local symbols + local variable type map (`var_name -> type_name`)
	pub_revision:   u64,
	buf_symbols:    [dynamic]Indexed_Symbol,
	local_types:    map[string]string,

	// Active Blueprint `using self` variables, custom procedures & `using` spaces
	bp_vars:        [dynamic]Scoped_Pin_Badge,
	bp_procs:       [dynamic]string,
	bp_spaces:      [dynamic]string,
}

@(private = "file")
_ac: _AC_Worker_State

@(private = "file")
_free_indexed_symbol :: proc(s: Indexed_Symbol) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if s.name        != "" do delete(s.name)
	if s.insert_text != "" do delete(s.insert_text)
	if s.detail      != "" do delete(s.detail)
	if s.receiver    != "" do delete(s.receiver)
}

@(private = "file")
_clone_indexed_symbol :: proc(s: Indexed_Symbol, allocator := context.allocator) -> Indexed_Symbol {
	return Indexed_Symbol{
		name        = s.name        != "" ? strings.clone(s.name, allocator)        : "",
		insert_text = s.insert_text != "" ? strings.clone(s.insert_text, allocator) : "",
		detail      = s.detail      != "" ? strings.clone(s.detail, allocator)      : "",
		kind        = s.kind,
		receiver    = s.receiver    != "" ? strings.clone(s.receiver, allocator)    : "",
	}
}

@(private = "file")
_node_slice :: proc(src: string, n: ^ast.Node) -> string {
	if n == nil do return ""
	s := clamp(n.pos.offset, 0, len(src))
	e := clamp(n.end.offset, s, len(src))
	return strings.trim_space(src[s:e])
}

@(private = "file")
_clean_type_name :: proc(raw_type: string) -> string {
	t := strings.trim_space(raw_type)
	for strings.has_prefix(t, "^") {
		t = strings.trim_space(t[1:])
	}
	if dot := strings.last_index_byte(t, '.'); dot >= 0 && dot + 1 < len(t) {
		t = t[dot + 1:]
	}
	return t
}

@(private = "file")
_infer_rhs_type :: proc(src: string, expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	txt := _node_slice(src, expr)
	if strings.has_prefix(txt, "hot.pos_ref(") || strings.has_prefix(txt, "hot.slot_ref_vec3(") {
		return "^[3]f32"
	}
	if strings.has_prefix(txt, "hot.get_pos(") || strings.has_prefix(txt, "hot.get_scale(") || strings.has_prefix(txt, "hot.damp_vec3(") || strings.has_prefix(txt, "hot.slot_read_vec3(") {
		return "[3]f32"
	}
	if strings.has_prefix(txt, "hot.get_rot(") {
		return "[4]f32"
	}
	if strings.has_prefix(txt, "hot.damp_f32(") || strings.has_prefix(txt, "hot.slot_read_f32(") || strings.has_prefix(txt, "math.sin(") || strings.has_prefix(txt, "math.cos(") {
		return "f32"
	}
	#partial switch d in expr.derived_expr {
	case ^ast.Comp_Lit:
		if d.type != nil do return _node_slice(src, d.type)
	case ^ast.Call_Expr:
		if d.expr != nil {
			fn_txt := _node_slice(src, d.expr)
			if len(fn_txt) > 0 && fn_txt[0] >= 'A' && fn_txt[0] <= 'Z' {
				return fn_txt
			}
		}
	case ^ast.Basic_Lit:
		#partial switch d.tok.kind {
		case .Float:   return "f32"
		case .Integer: return "int"
		case .String:  return "string"
		}
	case ^ast.Ident:
		if d.name == "true" || d.name == "false" do return "bool"
	}
	return ""
}

// Walks statement blocks recursively to extract local variable declarations, parameters, & inferred types.
@(private = "file")
_walk_stmt_locals :: proc(
	src:       string,
	stmt:      ^ast.Stmt,
	seen:      ^map[string]bool,
	out_syms:  ^[dynamic]Indexed_Symbol,
	out_types: ^map[string]string,
	allocator: runtime.Allocator,
) {
	if stmt == nil do return
	#partial switch s in stmt.derived_stmt {
	case ^ast.Block_Stmt:
		for sub in s.stmts {
			_walk_stmt_locals(src, sub, seen, out_syms, out_types, allocator)
		}
	case ^ast.If_Stmt:
		_walk_stmt_locals(src, s.init, seen, out_syms, out_types, allocator)
		_walk_stmt_locals(src, s.body, seen, out_syms, out_types, allocator)
		_walk_stmt_locals(src, s.else_stmt, seen, out_syms, out_types, allocator)
	case ^ast.For_Stmt:
		_walk_stmt_locals(src, s.init, seen, out_syms, out_types, allocator)
		_walk_stmt_locals(src, s.body, seen, out_syms, out_types, allocator)
	case ^ast.Range_Stmt:
		for val_expr in s.vals {
			if val_expr == nil do continue
			if id, ok := val_expr.derived_expr.(^ast.Ident); ok && id.name != "_" && !(id.name in seen^) {
				seen^[id.name] = true
				append(out_syms, Indexed_Symbol{
					name        = strings.clone(id.name, allocator),
					insert_text = strings.clone(id.name, allocator),
					detail      = strings.clone("iter", allocator),
					kind        = .Local_Var,
				})
			}
		}
		_walk_stmt_locals(src, s.body, seen, out_syms, out_types, allocator)
	case ^ast.Switch_Stmt:
		_walk_stmt_locals(src, s.init, seen, out_syms, out_types, allocator)
		_walk_stmt_locals(src, s.body, seen, out_syms, out_types, allocator)
	case ^ast.Case_Clause:
		for sub in s.body {
			_walk_stmt_locals(src, sub, seen, out_syms, out_types, allocator)
		}
	case ^ast.Value_Decl:
		explicit_t := s.type != nil ? _node_slice(src, s.type) : ""
		for name_expr, ni in s.names {
			if name_expr == nil do continue
			id, is_id := name_expr.derived_expr.(^ast.Ident)
			if !is_id || id.name == "_" || id.name == "_mh_body" do continue
			inferred_t := explicit_t
			if inferred_t == "" && ni < len(s.values) {
				inferred_t = _infer_rhs_type(src, s.values[ni])
			}
			if inferred_t != "" && out_types != nil && !(id.name in out_types^) {
				out_types^[strings.clone(id.name, allocator)] = strings.clone(inferred_t, allocator)
			}
			if !(id.name in seen^) {
				seen^[id.name] = true
				append(out_syms, Indexed_Symbol{
					name        = strings.clone(id.name, allocator),
					insert_text = strings.clone(id.name, allocator),
					detail      = strings.clone(inferred_t != "" ? inferred_t : (s.is_mutable ? "var" : "const"), allocator),
					kind        = .Local_Var,
				})
			}
		}
	}
}

// Pure in-RAM AST symbol & struct-field extractor (`< 0.25 ms`, zero disk IO).
// Callable synchronously in unit tests and asynchronously on the autocomplete worker thread!
parse_buffer_symbols_in_ram :: proc(
	code:                string,
	is_scoped_body:      bool,
	allocator            := context.temp_allocator,
	include_body_locals: bool = true,
) -> (
	symbols:     []Indexed_Symbol,
	local_types: map[string]string,
) {
	arena: mem.Dynamic_Arena
	prev_arena_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	mem.dynamic_arena_init(&arena)
	context.allocator = prev_arena_alloc
	defer {
		pa := context.allocator
		context.allocator = runtime.default_allocator()
		mem.dynamic_arena_destroy(&arena)
		context.allocator = pa
	}

	f, _, wrapped := parse_odin_in_arena(code, "ac_buffer.odin", is_scoped_body, &arena)

	out := make([dynamic]Indexed_Symbol, 0, 32, allocator)
	ltypes := make(map[string]string, 16, allocator)
	seen := make(map[string]bool, 64, mem.dynamic_arena_allocator(&arena))

	for decl in f.decls {
		if decl == nil do continue
		vd, is_vd := decl.derived.(^ast.Value_Decl)
		if !is_vd do continue

		for name_expr, ni in vd.names {
			if name_expr == nil do continue
			id, is_id := name_expr.derived_expr.(^ast.Ident)
			if !is_id || id.name == "_" do continue

			val: ^ast.Expr = ni < len(vd.values) ? vd.values[ni] : nil
			if val != nil {
				#partial switch v in val.derived_expr {
				case ^ast.Proc_Lit:
					if id.name != "_mh_body" && !(id.name in seen) {
						seen[id.name] = true
						sig := v.type != nil ? _node_slice(wrapped, v.type) : "proc()"
						append(&out, Indexed_Symbol{
							name        = strings.clone(id.name, allocator),
							insert_text = strings.concatenate({id.name, "("}, allocator),
							detail      = strings.clone(sig, allocator),
							kind        = .Procedure,
						})
					}
					if include_body_locals {
						// Extract parameters & body locals
						if v.type != nil && v.type.params != nil {
							for field in v.type.params.list {
								if field == nil do continue
								ft := field.type != nil ? _node_slice(wrapped, field.type) : "param"
								for pn in field.names {
									if pn == nil do continue
									if pid, pok := pn.derived_expr.(^ast.Ident); pok && pid.name != "_" {
										if !(pid.name in ltypes) {
											ltypes[strings.clone(pid.name, allocator)] = strings.clone(ft, allocator)
										}
										if !(pid.name in seen) {
											seen[pid.name] = true
											append(&out, Indexed_Symbol{
												name        = strings.clone(pid.name, allocator),
												insert_text = strings.clone(pid.name, allocator),
												detail      = strings.clone(ft, allocator),
												kind        = .Local_Var,
											})
										}
									}
								}
							}
						}
						_walk_stmt_locals(wrapped, v.body, &seen, &out, &ltypes, allocator)
					}
					continue

				case ^ast.Struct_Type:
					if !(id.name in seen) {
						seen[id.name] = true
						append(&out, Indexed_Symbol{
							name        = strings.clone(id.name, allocator),
							insert_text = strings.clone(id.name, allocator),
							detail      = strings.clone("struct", allocator),
							kind        = .Type_Sym,
						})
					}
					if v.fields != nil {
						for fld in v.fields.list {
							if fld == nil do continue
							ft := fld.type != nil ? _node_slice(wrapped, fld.type) : "field"
							for fn in fld.names {
								if fn == nil do continue
								if fid, fok := fn.derived_expr.(^ast.Ident); fok && fid.name != "_" {
									append(&out, Indexed_Symbol{
										name        = strings.clone(fid.name, allocator),
										insert_text = strings.clone(fid.name, allocator),
										detail      = strings.clone(ft, allocator),
										kind        = .Field,
										receiver    = strings.clone(id.name, allocator),
									})
								}
							}
						}
					}
					continue

				case ^ast.Enum_Type:
					if !(id.name in seen) {
						seen[id.name] = true
						append(&out, Indexed_Symbol{
							name        = strings.clone(id.name, allocator),
							insert_text = strings.clone(id.name, allocator),
							detail      = strings.clone("enum", allocator),
							kind        = .Type_Sym,
						})
					}
					for ev in v.fields {
						if ev == nil do continue
						ev_txt := _node_slice(wrapped, ev)
						if eq := strings.index_byte(ev_txt, '='); eq > 0 {
							ev_txt = strings.trim_space(ev_txt[:eq])
						}
						if ev_txt != "" {
							append(&out, Indexed_Symbol{
								name        = strings.clone(ev_txt, allocator),
								insert_text = strings.clone(ev_txt, allocator),
								detail      = strings.clone(id.name, allocator),
								kind        = .Field,
								receiver    = strings.clone(id.name, allocator),
							})
						}
					}
					continue
				}
			}

			if id.name != "_mh_body" && !(id.name in seen) {
				seen[id.name] = true
				t_str := vd.type != nil ? _node_slice(wrapped, vd.type) : (val != nil ? _infer_rhs_type(wrapped, val) : "")
				if t_str != "" && !(id.name in ltypes) {
					ltypes[strings.clone(id.name, allocator)] = strings.clone(t_str, allocator)
				}
				append(&out, Indexed_Symbol{
					name        = strings.clone(id.name, allocator),
					insert_text = strings.clone(id.name, allocator),
					detail      = strings.clone(t_str != "" ? t_str : (vd.is_mutable ? "var" : "const"), allocator),
					kind        = .Local_Var,
				})
			}
		}
	}

	return out[:], ltypes
}

// Indexes top-level procs, types, and struct/enum fields across all non-test `.odin`
// files in `pkg_dir` using isolated heap-backed Dynamic_Arenas so indexing large engine
// packages (90+ files) never overflows or corrupts the 4 MB `context.temp_allocator` ring buffer.
index_package_dir_symbols :: proc(pkg_dir: string, allocator := context.temp_allocator) -> []Indexed_Symbol {
	out := make([dynamic]Indexed_Symbol, 0, 64, allocator)
	if pkg_dir == "" do return out[:]

	dir_arena: mem.Dynamic_Arena
	file_arena: mem.Dynamic_Arena
	prev_arena_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	mem.dynamic_arena_init(&dir_arena)
	mem.dynamic_arena_init(&file_arena)
	context.allocator = prev_arena_alloc
	defer {
		pa := context.allocator
		context.allocator = runtime.default_allocator()
		mem.dynamic_arena_destroy(&file_arena)
		mem.dynamic_arena_destroy(&dir_arena)
		context.allocator = pa
	}

	dir_alloc  := mem.dynamic_arena_allocator(&dir_arena)
	file_alloc := mem.dynamic_arena_allocator(&file_arena)

	abs_dir := pkg_dir
	if !filepath.is_abs(pkg_dir) {
		repo_root := engine.engine_root(dir_alloc)
		if repo_root == "" {
			repo_root = engine.resolve_repo_root(dir_alloc)
		}
		abs_dir, _ = filepath.join({repo_root, pkg_dir}, dir_alloc)
	}
	if !os.is_dir(abs_dir) do return out[:]
	entries, err := os.read_all_directory_by_path(abs_dir, dir_alloc)
	if err != nil do return out[:]

	seen := make(map[string]bool, 256, dir_alloc)
	for fi in entries {
		if !strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, "_test.odin") do continue
		mem.dynamic_arena_reset(&file_arena)
		raw, rerr := os.read_entire_file(fi.fullpath, file_alloc)
		if rerr != nil do continue
		file_syms, _ := parse_buffer_symbols_in_ram(string(raw), false, file_alloc, false)
		for s in file_syms {
			// Only keep top-level procs, types, and struct/enum fields from sibling files (not private locals)
			if s.kind == .Local_Var do continue
			key := s.receiver != "" ? fmt.aprintf("%s.%s", s.receiver, s.name, allocator = file_alloc) : s.name
			if key in seen do continue
			seen[strings.clone(key, dir_alloc)] = true
			append(&out, _clone_indexed_symbol(s, allocator))
		}
	}
	return out[:]
}

@(private = "file")
_ac_worker_proc :: proc(_t: ^thread.Thread) {
	context = runtime.default_context()
	context.assertion_failure_proc = crash_journal.assertion_failure
	last_rev: u64 = 0

	for {
		sync.mutex_lock(&_ac.mu)
		for !_ac.stop_requested && _ac.req_revision <= last_rev {
			sync.cond_wait(&_ac.cv, &_ac.mu)
		}
		if _ac.stop_requested {
			sync.mutex_unlock(&_ac.mu)
			break
		}

		cur_rev := _ac.req_revision
		elapsed := time.duration_milliseconds(time.tick_since(_ac.req_edit_tick))
		if elapsed < AUTOCOMPLETE_DEBOUNCE_MS {
			wait_d := time.Duration(AUTOCOMPLETE_DEBOUNCE_MS - elapsed + 5) * time.Millisecond
			_ = sync.cond_wait_with_timeout(&_ac.cv, &_ac.mu, wait_d)
			sync.mutex_unlock(&_ac.mu)
			continue
		}

		pass_arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&pass_arena)
		pass_alloc := mem.dynamic_arena_allocator(&pass_arena)

		code_copy  := strings.clone(_ac.req_code, pass_alloc)
		is_scoped  := _ac.req_is_scoped
		pkg_dir    := strings.clone(_ac.req_pkg_dir, pass_alloc)
		extra_dirs := strings.clone(_ac.req_extra_dirs, pass_alloc)
		need_pkg   := (pkg_dir != "" && pkg_dir != _ac.cached_pkg_dir) || (extra_dirs != _ac.cached_extra_dirs)
		sync.mutex_unlock(&_ac.mu)

		buf_syms, ltypes := parse_buffer_symbols_in_ram(code_copy, is_scoped, pass_alloc)
		var_pkg_syms := make([dynamic]Indexed_Symbol, 0, 64, pass_alloc)
		if need_pkg {
			if pkg_dir != "" {
				for s in index_package_dir_symbols(pkg_dir, pass_alloc) {
					append(&var_pkg_syms, s)
				}
			}
			if extra_dirs != "" {
				for entry in strings.split(extra_dirs, ";", pass_alloc) {
					eq := strings.index_byte(entry, '=')
					if eq <= 0 do continue
					alias := strings.trim_space(entry[:eq])
					edir  := strings.trim_space(entry[eq + 1:])
					for s in index_package_dir_symbols(edir, pass_alloc) {
						if s.receiver == "" {
							cs := _clone_indexed_symbol(s, pass_alloc)
							cs.receiver = strings.clone(alias, pass_alloc)
							append(&var_pkg_syms, cs)
						} else {
							append(&var_pkg_syms, s)
						}
					}
				}
			}
		}
		last_rev = cur_rev

		sync.mutex_lock(&_ac.mu)
		if _ac.req_revision == cur_rev {
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			for s in _ac.buf_symbols do _free_indexed_symbol(s)
			clear(&_ac.buf_symbols)
			for s in buf_syms {
				append(&_ac.buf_symbols, _clone_indexed_symbol(s))
			}

			for k, v in _ac.local_types {
				delete(k)
				delete(v)
			}
			clear(&_ac.local_types)
			for k, v in ltypes {
				_ac.local_types[strings.clone(k)] = strings.clone(v)
			}

			if need_pkg {
				for s in _ac.pkg_symbols do _free_indexed_symbol(s)
				clear(&_ac.pkg_symbols)
				for s in var_pkg_syms {
					append(&_ac.pkg_symbols, _clone_indexed_symbol(s))
				}
				if _ac.cached_pkg_dir != "" do delete(_ac.cached_pkg_dir)
				if _ac.cached_extra_dirs != "" do delete(_ac.cached_extra_dirs)
				_ac.cached_pkg_dir    = strings.clone(pkg_dir)
				_ac.cached_extra_dirs = strings.clone(extra_dirs)
			}
			_ac.pub_revision = cur_rev
			context.allocator = prev_alloc
		}
		sync.mutex_unlock(&_ac.mu)
		mem.dynamic_arena_destroy(&pass_arena)
		free_all(context.temp_allocator)
	}
}

ensure_autocomplete_started :: proc() {
	sync.mutex_lock(&_ac.mu)
	defer sync.mutex_unlock(&_ac.mu)
	if _ac.started do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_ac.started        = true
	_ac.stop_requested = false
	_ac.local_types    = make(map[string]string, 32)
	t := thread.create(_ac_worker_proc)
	if t != nil {
		thread.start(t)
		_ac.worker_thread = t
	}
}

shutdown_autocomplete :: proc() {
	sync.mutex_lock(&_ac.mu)
	if !_ac.started {
		sync.mutex_unlock(&_ac.mu)
		return
	}
	_ac.stop_requested = true
	th := _ac.worker_thread
	sync.cond_broadcast(&_ac.cv)
	sync.mutex_unlock(&_ac.mu)

	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}

	sync.mutex_lock(&_ac.mu)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for s in _ac.buf_symbols do _free_indexed_symbol(s)
	delete(_ac.buf_symbols)
	for s in _ac.pkg_symbols do _free_indexed_symbol(s)
	delete(_ac.pkg_symbols)
	for k, v in _ac.local_types {
		delete(k)
		delete(v)
	}
	delete(_ac.local_types)
	if _ac.req_code          != "" do delete(_ac.req_code)
	if _ac.req_pkg_dir       != "" do delete(_ac.req_pkg_dir)
	if _ac.req_extra_dirs    != "" do delete(_ac.req_extra_dirs)
	if _ac.cached_pkg_dir    != "" do delete(_ac.cached_pkg_dir)
	if _ac.cached_extra_dirs != "" do delete(_ac.cached_extra_dirs)
	for v in _ac.bp_vars {
		delete(v.name)
		delete(v.odin_type)
	}
	delete(_ac.bp_vars)
	for p in _ac.bp_procs do delete(p)
	delete(_ac.bp_procs)
	for s in _ac.bp_spaces do delete(s)
	delete(_ac.bp_spaces)
	_ac = {}
	sync.mutex_unlock(&_ac.mu)
}

// Catalog entry for the interactive `[ + Using / Spaces ▾ ]` selector in Blueprint Studio & Code Studio!
Using_Space_Spec :: struct {
	id:          string,
	label:       string,
	import_line: string,
	pkg_alias:   string,
	repo_dir:    string, // Empty for `core:*` or `"self"`
	hot_safe:    bool,   // `true` = safe inside 240 ms `hot_cartridge.dll` Blueprints; `false` = full-file packages
	description: string,
}

USING_SPACE_CATALOG := [?]Using_Space_Spec{
	{"self",          "using self (Blueprint)", "",                                                                   "bp",            "",                                             true,  "Injects `using bp: ^Blueprint_State` so Blueprint variables read/write directly like OOP fields!"},
	{"hot",           "hot (Hot API & Bind)",   "import hot \"haati:engine/hot_api\"",                              "hot",           "haati/engine/hot_api",                       true,  "Entity transforms, TimeScale, Odin Input/Delegate `bind_action` / `unbind_action` helpers"},
	{"math",          "math",                   "@(require) import \"core:math\"",                                    "math",          "",                                             true,  "Standard trigonometry, `TAU`, `PI`, `lerp`, `to_radians`"},
	{"using_math",    "using math",             "@(require) import \"core:math\"",                                    "math",          "",                                             true,  "Brings `sin`, `cos`, `atan2`, `TAU`, `PI`, `lerp` directly into unqualified scope"},
	{"linalg",        "linalg",                 "@(require) import \"core:math/linalg\"",                             "linalg",        "",                                             true,  "Vector/Quaternion `dot`, `cross`, `normalize0`, `length`, `quaternion_angle_axis`"},
	{"using_linalg",  "using linalg",           "@(require) import \"core:math/linalg\"",                             "linalg",        "",                                             true,  "Brings `dot`, `cross`, `normalize0`, `length` directly into unqualified scope"},
	{"ease",          "ease (Curves)",          "@(require) import \"core:math/ease\"",                               "ease",          "",                                             true,  "Procedural easing curves (`cubic_in_out`, `elastic_out`, `back_out`)"},
	{"rand",          "rand",                   "@(require) import \"core:math/rand\"",                               "rand",          "",                                             true,  "Fast PRNG (`float32_range`, `int_max`, `float32`)"},
	{"engine",        "engine",                 "@(require) import \"haati:engine\"",                               "engine",        "haati/engine",                               false, "Haati ECS World, Transform pools, Scene & Asset APIs"},
	{"input",         "input",                  "@(require) import \"haati:engine/input\"",                         "input",         "haati/engine/input",                         false, "Low-level keyboard scancode, mouse & gamepad state queries"},
	{"input_manager", "input_manager",          "@(require) import \"haati:packages/input_manager\"",               "input_manager", "haati/packages/input_manager",               false, "Prioritized Action & Vector router (`claim_action_by_name`, `release_action_by_name`)"},
	{"physics3d",     "physics3d",              "@(require) import \"haati:packages/physics3d\"",                   "physics3d",     "haati/packages/physics3d",                   false, "Jolt 3D rigidbodies, raycasts, shapecasts & character controllers"},
	{"cad_csg",       "cad_csg",                "@(require) import \"haati:packages/cad_csg\"",                     "cad_csg",       "haati/packages/cad_csg",                     false, "Realtime CSG boolean primitives & procedural level brushes"},
	{"control_rig",   "control_rig",            "@(require) import \"haati:packages/control_rig\"",                 "control_rig",   "haati/packages/control_rig",                 false, "Procedural IK/FK skeletal rig evaluation & bone drivers"},
}

// Updates the Blueprint `using self` variables, custom procedures, and active `using_spaces` for zero-guess autocomplete!
set_blueprint_autocomplete_context :: proc(vars: []Scoped_Pin_Badge, procs: []string, active_spaces: []string) {
	sync.mutex_lock(&_ac.mu)
	defer sync.mutex_unlock(&_ac.mu)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	for v in _ac.bp_vars {
		delete(v.name)
		delete(v.odin_type)
	}
	clear(&_ac.bp_vars)
	for v in vars {
		append(&_ac.bp_vars, Scoped_Pin_Badge{
			name      = strings.clone(v.name),
			odin_type = strings.clone(v.odin_type),
			pass_mode = v.pass_mode,
			is_output = v.is_output,
		})
	}

	for p in _ac.bp_procs do delete(p)
	clear(&_ac.bp_procs)
	for p in procs {
		if p != "" do append(&_ac.bp_procs, strings.clone(p))
	}

	for s in _ac.bp_spaces do delete(s)
	clear(&_ac.bp_spaces)
	for s in active_spaces {
		if s != "" do append(&_ac.bp_spaces, strings.clone(s))
	}
}

@(private = "file")
_resolve_import_spec_to_dir :: proc(imp_spec: string, allocator := context.temp_allocator) -> (dir: string, default_alias: string) {
	spec := strings.trim_space(imp_spec)
	if spec == "" do return "", ""

	colon := strings.index_byte(spec, ':')
	if colon < 0 do return "", ""
	col_name := spec[:colon]
	sub_raw, _ := strings.replace_all(spec[colon + 1:], "\\", "/", context.temp_allocator)
	sub := strings.trim_prefix(strings.trim_space(sub_raw), "/")

	has_proj := engine.has_active_project()
	proj_root := has_proj ? engine.active_project_root() : ""
	proj_slug := (has_proj && proj_root != "") ? engine.active_project_slug(context.temp_allocator) : ""

	_map_packages_sub :: proc(p_sub, p_root, p_slug: string, alloc: mem.Allocator) -> string {
		rest := strings.trim_prefix(p_sub, "packages/")
		if p_slug != "" && p_root != "" {
			if rest == p_slug {
				return strings.clone(p_root, alloc)
			}
			pref := fmt.tprintf("%s/", p_slug)
			if strings.has_prefix(rest, pref) {
				joined, _ := filepath.join({p_root, rest[len(pref):]}, alloc)
				return joined
			}
		}
		return fmt.aprintf("haati/packages/%s", rest, allocator = alloc)
	}

	switch col_name {
	case "haati":
		if sub == "" || sub == "." {
			dir = strings.clone("haati", allocator)
		} else if strings.has_prefix(sub, "packages/") {
			dir = _map_packages_sub(sub, proj_root, proj_slug, allocator)
		} else {
			dir = fmt.aprintf("haati/%s", sub, allocator = allocator)
		}
	case "moonhug":
		if sub == "" || sub == "." {
			dir = strings.clone("haati", allocator)
		} else if strings.has_prefix(sub, "packages/") {
			dir = _map_packages_sub(sub, proj_root, proj_slug, allocator)
		} else if strings.has_prefix(sub, "app") {
			dir = fmt.aprintf("haati/packages/%s", sub, allocator = allocator)
		} else {
			dir = fmt.aprintf("haati/%s", sub, allocator = allocator)
		}
	case "project":
		if proj_root != "" && proj_slug != "" {
			if sub == "" || sub == "." {
				dir = strings.clone(proj_root, allocator)
			} else {
				dir, _ = filepath.join({proj_root, sub}, allocator)
			}
		}
	case:
		if proj_root != "" && proj_slug != "" && col_name == proj_slug {
			if sub == "" || sub == "." {
				dir = strings.clone(proj_root, allocator)
			} else {
				dir, _ = filepath.join({proj_root, sub}, allocator)
			}
		}
	}

	if dir == "" {
		return "", ""
	}
	if sub != "" && sub != "." {
		trimmed := strings.trim_suffix(sub, "/")
		if sl := strings.last_index_byte(trimmed, '/'); sl >= 0 {
			default_alias = strings.clone(trimmed[sl + 1:], allocator)
		} else {
			default_alias = strings.clone(trimmed, allocator)
		}
	} else {
		norm_dir, _ := strings.replace_all(dir, "\\", "/", context.temp_allocator)
		norm_dir = strings.trim_suffix(norm_dir, "/")
		if sl := strings.last_index_byte(norm_dir, '/'); sl >= 0 {
			default_alias = strings.clone(norm_dir[sl + 1:], allocator)
		} else {
			default_alias = strings.clone(norm_dir, allocator)
		}
	}
	return dir, default_alias
}

@(private = "file")
_extract_imported_package_dirs :: proc(code: string, allocator := context.temp_allocator) -> string {
	pairs := make([dynamic]string, 0, 8, allocator)
	seen := make(map[string]bool, 16, context.temp_allocator)

	_push_pair :: proc(pairs: ^[dynamic]string, seen: ^map[string]bool, alias, dir: string, alloc: mem.Allocator) {
		if alias == "" || alias == "_" || dir == "" do return
		entry := fmt.aprintf("%s=%s", alias, dir, allocator = alloc)
		if !(entry in seen^) {
			seen^[entry] = true
			append(pairs, entry)
		}
	}

	for raw_ln in strings.split_lines(code, context.temp_allocator) {
		tl := strings.trim_space(strings.trim_suffix(raw_ln, "\r"))
		if tl == "" || strings.has_prefix(tl, "//") || strings.has_prefix(tl, "package ") do continue

		// Check catalog shortcuts first for exact line matches
		for spec in USING_SPACE_CATALOG {
			if spec.repo_dir == "" do continue
			q1 := strings.index_byte(spec.import_line, '"')
			q2 := strings.last_index_byte(spec.import_line, '"')
			if q1 >= 0 && q2 > q1 {
				imp_path := spec.import_line[q1:q2 + 1]
				if strings.contains(tl, imp_path) {
					_push_pair(&pairs, &seen, spec.pkg_alias, spec.repo_dir, allocator)
				}
			}
		}

		// Strip leading `@(...)` attributes (e.g. `@(require) import ...`)
		work := tl
		for strings.has_prefix(work, "@(") {
			rp := strings.index_byte(work, ')')
			if rp < 0 do break
			work = strings.trim_left_space(work[rp + 1:])
		}
		if strings.has_prefix(work, "import ") {
			work = strings.trim_left_space(work[len("import "):])
		} else if strings.has_prefix(work, "import\t") {
			work = strings.trim_left_space(work[len("import\t"):])
		} else {
			continue
		}

		q1 := strings.index_byte(work, '"')
		if q1 < 0 do continue
		q2_rel := strings.index_byte(work[q1 + 1:], '"')
		if q2_rel <= 0 do continue

		explicit_alias := strings.trim_space(work[:q1])
		imp_spec := work[q1 + 1 : q1 + 1 + q2_rel]
		dir, def_alias := _resolve_import_spec_to_dir(imp_spec, context.temp_allocator)
		if dir != "" {
			alias := explicit_alias != "" ? explicit_alias : def_alias
			_push_pair(&pairs, &seen, alias, dir, allocator)
		}
	}
	return strings.join(pairs[:], ";", allocator)
}

// Non-blocking submission (`< 0.01 ms`) from UI thread on edit/open.
submit_async_autocomplete_index :: proc(code: string, is_scoped_body: bool, pkg_dir: string) {
	ensure_autocomplete_started()
	extra := !is_scoped_body ? _extract_imported_package_dirs(code, context.temp_allocator) : ""

	sync.mutex_lock(&_ac.mu)
	defer sync.mutex_unlock(&_ac.mu)

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _ac.req_code       != "" do delete(_ac.req_code)
	if _ac.req_pkg_dir    != "" do delete(_ac.req_pkg_dir)
	if _ac.req_extra_dirs != "" do delete(_ac.req_extra_dirs)
	_ac.req_code       = strings.clone(code)
	_ac.req_is_scoped  = is_scoped_body
	_ac.req_pkg_dir    = pkg_dir != "" ? strings.clone(pkg_dir) : ""
	_ac.req_extra_dirs = extra != "" ? strings.clone(extra) : ""
	_ac.req_revision  += 1
	_ac.req_edit_tick  = time.tick_now()
	sync.cond_signal(&_ac.cv)
}

// =============================================================================
// Caret Prefix & Dot-Receiver Extractor + Fuzzy Matcher
// =============================================================================

// Extracts `receiver` (if right after `ident.`) and `prefix` before `cursor_pos`.
extract_completion_context :: proc(src: string, cursor_pos: int) -> (receiver: string, prefix: string, replace_start: int) {
	pos := clamp(cursor_pos, 0, len(src))
	start := pos
	for start > 0 && is_odin_ident_char(src[start - 1]) {
		start -= 1
	}
	return extract_dot_receiver_before(src, start), src[start:pos], start
}

// Fuzzy matcher returning `> 0` when `pattern` is a prefix or camel/snake subsequence of `candidate`.
fuzzy_match_score :: proc(pattern: string, candidate: string) -> int {
	if len(candidate) == 0 do return 0
	if len(pattern) == 0 do return 100 // Empty prefix valid after `.` or `Ctrl+Space`

	if candidate == pattern do return 1200
	if strings.has_prefix(candidate, pattern) {
		return 950 - min(len(candidate) - len(pattern), 40)
	}

	// Case-insensitive prefix
	if len(candidate) >= len(pattern) {
		ci_prefix := true
		for i in 0 ..< len(pattern) {
			pa := pattern[i] >= 'A' && pattern[i] <= 'Z' ? pattern[i] + 32 : pattern[i]
			ca := candidate[i] >= 'A' && candidate[i] <= 'Z' ? candidate[i] + 32 : candidate[i]
			if pa != ca {
				ci_prefix = false
				break
			}
		}
		if ci_prefix {
			return 820 - min(len(candidate) - len(pattern), 40)
		}
	}

	// Subsequence match with word-boundary bonus (`_`, camelCase)
	pi := 0
	score := 400
	last_match := -2
	for ci in 0 ..< len(candidate) {
		pa := pattern[pi] >= 'A' && pattern[pi] <= 'Z' ? pattern[pi] + 32 : pattern[pi]
		ca := candidate[ci] >= 'A' && candidate[ci] <= 'Z' ? candidate[ci] + 32 : candidate[ci]
		if pa == ca {
			if ci == 0 || candidate[ci - 1] == '_' || (candidate[ci] >= 'A' && candidate[ci] <= 'Z') {
				score += 35
			} else if ci == last_match + 1 {
				score += 20
			}
			last_match = ci
			pi += 1
			if pi == len(pattern) {
				return max(score - min(len(candidate), 30), 50)
			}
		}
	}
	return 0
}

@(private = "file")
_Builtin_Entry :: struct {
	receiver: string,
	name:     string,
	insert:   string,
	detail:   string,
	kind:     Completion_Kind,
}

@(private = "file")
_BUILTIN_ENTRIES := [?]_Builtin_Entry{
	// `hot.*` (`moonhug:engine/hot_api` ergonomic C-ABI helpers)
	{"hot", "pos_ref",              "pos_ref(api, self)",                    "proc(api, e) -> ^[3]f32", .Hot_API},
	{"hot", "get_pos",              "get_pos(api, self)",                    "proc(api, e) -> [3]f32",  .Hot_API},
	{"hot", "set_pos",              "set_pos(api, self, ",                   "proc(api, e, [3]f32)",    .Hot_API},
	{"hot", "get_rot",              "get_rot(api, self)",                    "proc(api, e) -> [4]f32",  .Hot_API},
	{"hot", "set_rot",              "set_rot(api, self, ",                   "proc(api, e, [4]f32)",    .Hot_API},
	{"hot", "get_scale",            "get_scale(api, self)",                  "proc(api, e) -> [3]f32",  .Hot_API},
	{"hot", "set_scale",            "set_scale(api, self, ",                 "proc(api, e, [3]f32)",    .Hot_API},
	{"hot", "set_object_timescale", "set_object_timescale(api, self, ",      "proc(api, e, scale: f32)",.Hot_API},
	{"hot", "damp_f32",             "damp_f32(",                             "proc(cur, tgt, spd, dt) -> f32", .Hot_API},
	{"hot", "damp_vec3",            "damp_vec3(",                            "proc(cur, tgt, spd, dt) -> [3]f32", .Hot_API},
	{"hot", "slot_read_f32",        "slot_read_f32(",                        "proc(^Hot_Slot) -> f32",  .Hot_API},
	{"hot", "slot_ref_f32",         "slot_ref_f32(",                         "proc(^Hot_Slot) -> ^f32", .Hot_API},
	{"hot", "slot_read_vec3",       "slot_read_vec3(",                       "proc(^Hot_Slot) -> [3]f32", .Hot_API},
	{"hot", "slot_ref_vec3",        "slot_ref_vec3(",                        "proc(^Hot_Slot) -> ^[3]f32", .Hot_API},
	{"hot", "bind_action",          "bind_action(api, self, \"Jump\", ",     "proc(api, self, action, target_proc, trigger, prio, consume)", .Hot_API},
	{"hot", "unbind_action",        "unbind_action(api, self, \"Jump\")",    "proc(api, self, action: cstring)", .Hot_API},
	{"hot", "bind_vector",          "bind_vector(api, self, false, ",        "proc(api, self, is_look, target_proc, prio, consume)", .Hot_API},
	{"hot", "unbind_vector",        "unbind_vector(api, self, false)",       "proc(api, self, is_look: bool)", .Hot_API},
	{"hot", "bind_debug_key",       "bind_debug_key(api, self, 10, ",        "proc(api, self, scancode, target_proc, trigger)", .Hot_API},
	{"hot", "unbind_debug_key",     "unbind_debug_key(api, self, 10)",       "proc(api, self, scancode: i32)", .Hot_API},
	{"hot", "unbind_all",           "unbind_all(api, self)",                 "proc(api, self)", .Hot_API},
	{"hot", "bind_delegate",        "bind_delegate(api, self, ",             "proc(api, self, delegate_name, target_proc)", .Hot_API},
	{"hot", "unbind_delegate",      "unbind_delegate(api, self, ",           "proc(api, self, delegate_name)", .Hot_API},
	{"hot", "broadcast_delegate",   "broadcast_delegate(api, self, ",        "proc(api, self, delegate_name, payload_f32)", .Hot_API},
	{"hot", "var_ptr",              "var_ptr(api, self, 0)",                 "proc(api, self, var_index: i32) -> rawptr", .Hot_API},

	// `ease.*` (`core:math/ease`)
	{"ease", "cubic_in_out",        "cubic_in_out(",                         "proc(t: f32) -> f32", .Procedure},
	{"ease", "cubic_out",           "cubic_out(",                            "proc(t: f32) -> f32", .Procedure},
	{"ease", "quad_in_out",         "quad_in_out(",                          "proc(t: f32) -> f32", .Procedure},
	{"ease", "elastic_out",         "elastic_out(",                          "proc(t: f32) -> f32", .Procedure},
	{"ease", "back_out",            "back_out(",                             "proc(t: f32) -> f32", .Procedure},
	{"ease", "sine_in_out",         "sine_in_out(",                          "proc(t: f32) -> f32", .Procedure},

	// `rand.*` (`core:math/rand`)
	{"rand", "float32",             "float32()",                             "proc() -> f32 [0..1)", .Procedure},
	{"rand", "float32_range",       "float32_range(",                        "proc(lo, hi: f32) -> f32", .Procedure},
	{"rand", "int_max",             "int_max(",                              "proc(n: int) -> int", .Procedure},

	// `api.*` (`Engine_Hot_API` vtable fields)
	{"api", "entity_valid",         "entity_valid(self)",                    "proc(Hot_Entity) -> bool", .Hot_API},
	{"api", "get_world_position",   "get_world_position(self)",              "proc(Hot_Entity) -> [3]f32", .Hot_API},
	{"api", "get_forward",          "get_forward(self)",                     "proc(Hot_Entity) -> [3]f32", .Hot_API},
	{"api", "get_up",               "get_up(self)",                          "proc(Hot_Entity) -> [3]f32", .Hot_API},
	{"api", "get_right",            "get_right(self)",                       "proc(Hot_Entity) -> [3]f32", .Hot_API},
	{"api", "get_time_scale",       "get_time_scale()",                      "proc() -> f32", .Hot_API},
	{"api", "set_time_scale",       "set_time_scale(",                       "proc(scale: f32)", .Hot_API},
	{"api", "get_object_dt",        "get_object_dt(self, dt)",               "proc(self, raw_dt) -> f32", .Hot_API},
	{"api", "log_info",             "log_info(",                             "proc(msg: cstring)", .Hot_API},

	// `math.*`
	{"math", "sin",        "sin(",        "proc(f32) -> f32",      .Procedure},
	{"math", "cos",        "cos(",        "proc(f32) -> f32",      .Procedure},
	{"math", "tan",        "tan(",        "proc(f32) -> f32",      .Procedure},
	{"math", "atan2",      "atan2(",      "proc(y, x: f32) -> f32",.Procedure},
	{"math", "sqrt",       "sqrt(",       "proc(f32) -> f32",      .Procedure},
	{"math", "abs",        "abs(",        "proc(x) -> x",          .Procedure},
	{"math", "lerp",       "lerp(",       "proc(a, b, t) -> T",    .Procedure},
	{"math", "floor",      "floor(",      "proc(f32) -> f32",      .Procedure},
	{"math", "ceil",       "ceil(",       "proc(f32) -> f32",      .Procedure},
	{"math", "round",      "round(",      "proc(f32) -> f32",      .Procedure},
	{"math", "to_radians", "to_radians(", "proc(deg) -> rad",      .Procedure},
	{"math", "to_degrees", "to_degrees(", "proc(rad) -> deg",      .Procedure},
	{"math", "PI",         "PI",          "3.14159265",            .Local_Var},
	{"math", "TAU",        "TAU",         "6.28318530",            .Local_Var},

	// `linalg.*`
	{"linalg", "dot",                       "dot(",                       "proc(a, b) -> f32",      .Procedure},
	{"linalg", "cross",                     "cross(",                     "proc(a, b: [3]f32)",     .Procedure},
	{"linalg", "length",                    "length(",                    "proc(v) -> f32",         .Procedure},
	{"linalg", "length2",                   "length2(",                   "proc(v) -> f32",         .Procedure},
	{"linalg", "normalize0",                "normalize0(",                "proc(v) -> v",           .Procedure},
	{"linalg", "distance",                  "distance(",                  "proc(a, b) -> f32",      .Procedure},
	{"linalg", "lerp",                      "lerp(",                      "proc(a, b, t)",          .Procedure},
	{"linalg", "quaternion_angle_axis",     "quaternion_angle_axis(",     "proc(rad, axis) -> quat",.Procedure},
	{"linalg", "quaternion128_mul_vector3", "quaternion128_mul_vector3(", "proc(q, v) -> [3]f32",   .Procedure},

	// Top-level namespaces, Odin keywords & built-ins
	{"", "hot",           "hot.",          "package haati:engine/hot_api", .Hot_API},
	{"", "bp",            "bp.",           "^Blueprint_State (self fields)", .Pin_Ref},
	{"", "math",          "math.",         "package core:math",              .Type_Sym},
	{"", "linalg",        "linalg.",       "package core:math/linalg",       .Type_Sym},
	{"", "ease",          "ease.",         "package core:math/ease",         .Type_Sym},
	{"", "rand",          "rand.",         "package core:math/rand",         .Type_Sym},
	{"", "api",           "api",           "^Engine_Hot_API",                .Hot_API},
	{"", "self",          "self",          "Hot_Entity",                     .Hot_API},
	{"", "dt",            "dt",            "f32 (frame delta sec)",          .Local_Var},
	{"", "clamp",         "clamp(",        "builtin(v, lo, hi)",             .Procedure},
	{"", "min",           "min(",          "builtin(a, b)",                  .Procedure},
	{"", "max",           "max(",          "builtin(a, b)",                  .Procedure},
	{"", "abs",           "abs(",          "builtin(x)",                     .Procedure},
	{"", "len",           "len(",          "builtin(slice) -> int",          .Procedure},
	{"", "append",        "append(&",      "builtin(&dyn, elem)",            .Procedure},
	{"", "import",        "import ",       "keyword (import package)",       .Keyword},
	{"", "defer",         "defer ",        "keyword",                        .Keyword},
	{"", "return",        "return",        "keyword",                        .Keyword},
	{"", "switch",        "switch ",       "keyword",                        .Keyword},
	{"", "for",           "for ",          "keyword",                        .Keyword},
	{"", "proc",          "proc(",         "keyword",                        .Keyword},
	{"", "struct",        "struct {",      "keyword",                        .Keyword},
	{"", "enum",          "enum {",        "keyword",                        .Keyword},
	{"", "f32",           "f32",           "32-bit float",                   .Type_Sym},
	{"", "i32",           "i32",           "32-bit int",                     .Type_Sym},
	{"", "bool",          "bool",          "boolean",                        .Type_Sym},
	{"", "string",        "string",        "UTF-8 slice",                    .Type_Sym},
	{"", "quaternion128", "quaternion128", "128-bit quaternion",             .Type_Sym},
}

@(private = "file")
_is_vec_like_type :: proc(t: string) -> (dim: int) {
	clean := strings.trim_space(t)
	for strings.has_prefix(clean, "^") {
		clean = strings.trim_space(clean[1:])
	}
	if strings.has_prefix(clean, "[2]") || clean == "Vec2" do return 2
	if strings.has_prefix(clean, "[3]") || clean == "Vec3" do return 3
	if strings.has_prefix(clean, "[4]") || clean == "Vec4" || clean == "Quat" || clean == "quaternion128" do return 4
	return 0
}

@(private = "file")
_IMPORT_PKG_SUGGESTIONS := [?][3]string{
	{"core:math",              "\"core:math\"",               "Odin std math (sin, cos, lerp)"},
	{"core:math/linalg",       "\"core:math/linalg\"",        "Odin std vector/matrix/quat math"},
	{"core:math/ease",         "\"core:math/ease\"",          "Odin easing curves"},
	{"core:math/rand",         "\"core:math/rand\"",          "Odin random utilities"},
	{"core:fmt",               "\"core:fmt\"",                "Odin formatting"},
	{"core:strings",           "\"core:strings\"",            "Odin string helpers"},
	{"core:slice",             "\"core:slice\"",              "Odin slice sort/search"},
	{"core:time",              "\"core:time\"",               "Odin time & Tick"},
	{"core:os",                "\"core:os\"",                 "Odin filesystem OS ops"},
	{"haati:engine/hot_api", "hot \"haati:engine/hot_api\"", "Haati C-ABI hot cartridge API"},
	{"haati:engine",         "\"haati:engine\"",          "Engine package (Plugins/Engine only)"},
}

@(private = "file")
_is_import_query_char :: #force_inline proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
	       c == '_' || c == ':' || c == '/' || c == '.' || c == '-'
}

@(private = "file")
_line_import_context :: proc(src: string, cursor_pos: int) -> (is_import_line: bool, pkg_query: string, replace_start: int, inside_quotes: bool, has_close_quote: bool, has_alias: bool) {
	pos := clamp(cursor_pos, 0, len(src))
	ls := pos
	for ls > 0 && src[ls - 1] != '\n' {
		ls -= 1
	}
	le := pos
	for le < len(src) && src[le] != '\n' && src[le] != '\r' {
		le += 1
	}
	line_prefix := src[ls:pos]
	line_rest := src[pos:le]

	work := strings.trim_left_space(line_prefix)
	for strings.has_prefix(work, "@(") {
		rp := strings.index_byte(work, ')')
		if rp < 0 do break
		work = strings.trim_left_space(work[rp + 1:])
	}
	if strings.has_prefix(work, "import ") || strings.has_prefix(work, "import\t") || work == "import" {
		if work == "import" {
			return false, "", pos, false, false, false
		}
		after_imp := strings.trim_left_space(work[len("import"):])
		after_imp_abs := ls + len(line_prefix) - len(after_imp)

		if q1 := strings.index_byte(line_prefix, '"'); q1 >= 0 {
			if strings.index_byte(line_prefix[q1 + 1:], '"') >= 0 {
				return false, "", pos, false, false, false
			}
			q_abs := ls + q1
			has_al := q_abs > after_imp_abs && strings.trim_space(src[after_imp_abs:q_abs]) != ""
			has_close := strings.index_byte(line_rest, '"') >= 0
			return true, line_prefix[q1 + 1:], q_abs, true, has_close, has_al
		}

		// User typed `import ` or `import foo` without quotes yet
		sp := pos
		for sp > after_imp_abs && _is_import_query_char(src[sp - 1]) {
			sp -= 1
		}
		has_al := sp > after_imp_abs && strings.trim_space(src[after_imp_abs:sp]) != ""
		return true, src[sp:pos], sp, false, false, has_al
	}
	return false, "", pos, false, false, false
}

@(private = "file")
_dir_has_odin_files :: proc(abs_dir: string) -> bool {
	if abs_dir == "" || !os.is_dir(abs_dir) do return false
	dh, derr := os.open(abs_dir)
	if derr != nil do return false
	defer os.close(dh)
	entries, rerr := os.read_dir(dh, -1, context.temp_allocator)
	if rerr != nil do return false
	for fi in entries {
		if fi.type == .Regular && strings.has_suffix(fi.name, ".odin") && !strings.has_suffix(fi.name, "_test.odin") {
			return true
		}
	}
	return false
}

@(private = "file")
_collect_dynamic_import_packages :: proc(allocator := context.temp_allocator) -> [][2]string {
	out := make([dynamic][2]string, 0, 24, allocator)
	eng_root := engine.engine_root(context.temp_allocator)
	if eng_root == "" {
		eng_root = engine.resolve_repo_root(context.temp_allocator)
	}

	_scan_subdirs :: proc(base_abs, imp_prefix, desc: string, skip_names: []string, out: ^[dynamic][2]string, alloc: mem.Allocator) {
		if base_abs == "" || !os.is_dir(base_abs) do return
		dh, derr := os.open(base_abs)
		if derr != nil do return
		defer os.close(dh)
		entries, rerr := os.read_dir(dh, -1, context.temp_allocator)
		if rerr != nil do return
		for fi in entries {
			if fi.type != .Directory do continue
			if strings.has_prefix(fi.name, ".") do continue
			skip := false
			for s in skip_names do if fi.name == s { skip = true; break }
			if skip do continue
			sub_abs, _ := filepath.join({base_abs, fi.name}, context.temp_allocator)
			if _dir_has_odin_files(sub_abs) {
				append(out, [2]string{
					fmt.aprintf("%s%s", imp_prefix, fi.name, allocator = alloc),
					strings.clone(desc, alloc),
				})
			}
		}
	}

	if eng_root != "" {
		h_dir, _ := filepath.join({eng_root, "haati"}, context.temp_allocator)
		_scan_subdirs(h_dir, "haati:", "Haati engine package", []string{"packages", "external", "builds"}, &out, allocator)

		e_dir, _ := filepath.join({h_dir, "engine"}, context.temp_allocator)
		_scan_subdirs(e_dir, "haati:engine/", "Haati engine subpackage", nil, &out, allocator)

		p_dir, _ := filepath.join({h_dir, "packages"}, context.temp_allocator)
		_scan_subdirs(p_dir, "haati:packages/", "Haati package", []string{"void_odin"}, &out, allocator)
	}

	if engine.has_active_project() {
		proj_root := engine.active_project_root()
		slug := engine.active_project_slug(context.temp_allocator)
		if proj_root != "" && slug != "" && os.is_dir(proj_root) {
			if _dir_has_odin_files(proj_root) {
				append(&out, [2]string{strings.clone("project:.", allocator), strings.clone("Active project root package", allocator)})
			}
			proj_skip := []string{"builds", "cache"}
			if dh1, d1err := os.open(proj_root); d1err == nil {
				if e1, r1err := os.read_dir(dh1, -1, context.temp_allocator); r1err == nil {
					for fi1 in e1 {
						if fi1.type != .Directory || strings.has_prefix(fi1.name, ".") do continue
						skip1 := false
						for s in proj_skip do if fi1.name == s { skip1 = true; break }
						if skip1 do continue
						abs1, _ := filepath.join({proj_root, fi1.name}, context.temp_allocator)
						if _dir_has_odin_files(abs1) {
							append(&out, [2]string{fmt.aprintf("project:%s", fi1.name, allocator = allocator), strings.clone("Active project package", allocator)})
						}
						if dh2, d2err := os.open(abs1); d2err == nil {
							if e2, r2err := os.read_dir(dh2, -1, context.temp_allocator); r2err == nil {
								for fi2 in e2 {
									if fi2.type != .Directory || strings.has_prefix(fi2.name, ".") do continue
									skip2 := false
									for s in proj_skip do if fi2.name == s { skip2 = true; break }
									if skip2 do continue
									abs2, _ := filepath.join({abs1, fi2.name}, context.temp_allocator)
									if _dir_has_odin_files(abs2) {
										append(&out, [2]string{fmt.aprintf("project:%s/%s", fi1.name, fi2.name, allocator = allocator), strings.clone("Active project subpackage", allocator)})
									}
								}
							}
							os.close(dh2)
						}
					}
				}
				os.close(dh1)
			}
		}
	}
	return out[:]
}

@(private = "file")
_format_import_insert_text :: proc(pkg: string, inside_quotes, has_close_quote, has_alias: bool, allocator: mem.Allocator) -> string {
	if inside_quotes {
		return has_close_quote ? fmt.aprintf("\"%s", pkg, allocator = allocator) : fmt.aprintf("\"%s\"", pkg, allocator = allocator)
	}
	if !has_alias && pkg == "haati:engine/hot_api" {
		return strings.clone("hot \"haati:engine/hot_api\"", allocator)
	}
	return fmt.aprintf("\"%s\"", pkg, allocator = allocator)
}

// Queries ranked smart completions for `(src, cursor_pos)` without blocking the main thread!
// If the background worker hasn't indexed yet (e.g., in headless unit tests), falls back cleanly
// to an instant in-RAM parse for small buffers (`< 16 KB`).
query_autocomplete_suggestions :: proc(
	src:          string,
	cursor_pos:   int,
	pins:         []Scoped_Pin_Badge = nil,
	force_open:   bool               = false,
	is_scoped:    bool               = true,
	allocator     := context.temp_allocator,
) -> (
	items:         []Autocomplete_Item,
	replace_start: int,
) {
	if is_imp, imp_q, imp_rep, in_quotes, has_close, has_al := _line_import_context(src, cursor_pos); is_imp {
		cands := make([dynamic]Autocomplete_Item, 0, 24, allocator)
		_push_imp_cand :: proc(
			cands: ^[dynamic]Autocomplete_Item,
			pkg, det, imp_q: string,
			base_score: int,
			kind: Completion_Kind,
			in_quotes, has_close, has_al: bool,
			alloc: mem.Allocator,
		) {
			if pkg == "" do return
			for ex in cands^ {
				if ex.label == pkg do return
			}
			sc := len(imp_q) == 0 ? base_score : fuzzy_match_score(imp_q, pkg)
			if sc > 0 {
				append(cands, Autocomplete_Item{
					label       = strings.clone(pkg, alloc),
					insert_text = _format_import_insert_text(pkg, in_quotes, has_close, has_al, alloc),
					detail      = strings.clone(det, alloc),
					kind        = kind,
					score       = sc,
				})
			}
		}

		for entry in _IMPORT_PKG_SUGGESTIONS {
			_push_imp_cand(&cands, entry[0], entry[2], imp_q, 900, .Type_Sym, in_quotes, has_close, has_al, allocator)
		}
		for spec in USING_SPACE_CATALOG {
			q1 := strings.index_byte(spec.import_line, '"')
			q2 := strings.last_index_byte(spec.import_line, '"')
			if q1 < 0 || q2 <= q1 do continue
			pkg := spec.import_line[q1 + 1:q2]
			_push_imp_cand(&cands, pkg, spec.description, imp_q, 850, spec.hot_safe ? .Hot_API : .Type_Sym, in_quotes, has_close, has_al, allocator)
		}
		for dyn in _collect_dynamic_import_packages(context.temp_allocator) {
			_push_imp_cand(&cands, dyn[0], dyn[1], imp_q, 800, .Type_Sym, in_quotes, has_close, has_al, allocator)
		}
		slice.sort_by(cands[:], proc(a, b: Autocomplete_Item) -> bool {
			if a.score != b.score do return a.score > b.score
			return a.label < b.label
		})
		lim := min(len(cands), AUTOCOMPLETE_MAX_RESULTS)
		return cands[:lim], imp_rep
	}

	receiver, prefix, rep_start := extract_completion_context(src, cursor_pos)
	replace_start = rep_start

	// Only open automatically after `.` or once >= 1 identifier character is typed (or on `Ctrl+Space` `force_open`)
	if !force_open && receiver == "" && len(prefix) == 0 {
		return nil, replace_start
	}

	candidates := make([dynamic]Autocomplete_Item, 0, 32, allocator)
	seen := make(map[string]bool, 64, context.temp_allocator)

	kind_boost :: proc(k: Completion_Kind) -> int {
		switch k {
		case .Pin_Ref, .Pin_Copy, .Pin_Out: return 320
		case .Field:                        return 280
		case .Local_Var:                    return 240
		case .Hot_API:                      return 200
		case .Procedure:                    return 150
		case .Type_Sym:                     return 110
		case .Keyword:                      return 60
		}
		return 0
	}

	push_candidate :: proc(
		cands: ^[dynamic]Autocomplete_Item,
		seen:  ^map[string]bool,
		prefix: string,
		lbl, ins, det: string,
		k: Completion_Kind,
		alloc: runtime.Allocator,
	) {
		if lbl == "" || (lbl in seen^) do return
		sc := fuzzy_match_score(prefix, lbl)
		if sc <= 0 do return
		seen^[lbl] = true
		append(cands, Autocomplete_Item{
			label       = strings.clone(lbl, alloc),
			insert_text = strings.clone(ins, alloc),
			detail      = strings.clone(det, alloc),
			kind        = k,
			score       = sc + kind_boost(k),
		})
	}

	buf_syms:  []Indexed_Symbol   = nil
	pkg_syms:  []Indexed_Symbol   = nil
	bp_vars:   []Scoped_Pin_Badge = nil
	bp_procs:  []string           = nil
	bp_spaces: []string           = nil
	rec_type := ""

	for pin in pins {
		if pin.name == receiver {
			rec_type = pin.odin_type
			break
		}
	}

	sync.mutex_lock(&_ac.mu)
	if len(_ac.bp_vars) > 0 {
		tv := make([dynamic]Scoped_Pin_Badge, 0, len(_ac.bp_vars), context.temp_allocator)
		for v in _ac.bp_vars {
			append(&tv, Scoped_Pin_Badge{
				name      = strings.clone(v.name, context.temp_allocator),
				odin_type = strings.clone(v.odin_type, context.temp_allocator),
				pass_mode = v.pass_mode,
				is_output = v.is_output,
			})
			if rec_type == "" && v.name == receiver {
				rec_type = strings.clone(v.odin_type, context.temp_allocator)
			}
		}
		bp_vars = tv[:]
	}
	if len(_ac.bp_procs) > 0 {
		tp := make([dynamic]string, 0, len(_ac.bp_procs), context.temp_allocator)
		for p in _ac.bp_procs do append(&tp, strings.clone(p, context.temp_allocator))
		bp_procs = tp[:]
	}
	if len(_ac.bp_spaces) > 0 {
		ts := make([dynamic]string, 0, len(_ac.bp_spaces), context.temp_allocator)
		for s in _ac.bp_spaces do append(&ts, strings.clone(s, context.temp_allocator))
		bp_spaces = ts[:]
	}
	if _ac.started && _ac.pub_revision > 0 {
		tmp_b := make([dynamic]Indexed_Symbol, 0, len(_ac.buf_symbols), context.temp_allocator)
		for s in _ac.buf_symbols do append(&tmp_b, _clone_indexed_symbol(s, context.temp_allocator))
		buf_syms = tmp_b[:]

		tmp_p := make([dynamic]Indexed_Symbol, 0, len(_ac.pkg_symbols), context.temp_allocator)
		for s in _ac.pkg_symbols do append(&tmp_p, _clone_indexed_symbol(s, context.temp_allocator))
		pkg_syms = tmp_p[:]

		if rec_type == "" && receiver != "" {
			if lt, ok := _ac.local_types[receiver]; ok {
				rec_type = strings.clone(lt, context.temp_allocator)
			}
		}
	}
	sync.mutex_unlock(&_ac.mu)

	has_space :: proc(spaces: []string, want: string) -> bool {
		for s in spaces do if s == want do return true
		return false
	}

	if buf_syms == nil && len(src) <= 16384 {
		sync_syms, sync_ltypes := parse_buffer_symbols_in_ram(src, is_scoped, context.temp_allocator)
		buf_syms = sync_syms
		if rec_type == "" && receiver != "" {
			if lt, ok := sync_ltypes[receiver]; ok {
				rec_type = lt
			}
		}
	}

	// --- CASE A: Dot-Member Completion (`receiver.<prefix>`) ---
	if receiver != "" {
		if receiver == "bp" || receiver == "self" {
			for bv in bp_vars {
				push_candidate(&candidates, &seen, prefix, bv.name, bv.name, fmt.tprintf("[self] %s", bv.odin_type), .Field, allocator)
			}
		}
		for b in _BUILTIN_ENTRIES {
			if b.receiver == receiver {
				push_candidate(&candidates, &seen, prefix, b.name, b.insert, b.detail, b.kind, allocator)
			}
		}

		if vdim := _is_vec_like_type(rec_type); vdim >= 2 {
			push_candidate(&candidates, &seen, prefix, "x", "x", "f32", .Field, allocator)
			push_candidate(&candidates, &seen, prefix, "y", "y", "f32", .Field, allocator)
			if vdim >= 3 {
				push_candidate(&candidates, &seen, prefix, "z", "z", "f32", .Field, allocator)
				push_candidate(&candidates, &seen, prefix, "xyz", "xyz", "[3]f32", .Field, allocator)
			}
			if vdim >= 4 {
				push_candidate(&candidates, &seen, prefix, "w", "w", "f32", .Field, allocator)
			}
			push_candidate(&candidates, &seen, prefix, "xy", "xy", "[2]f32", .Field, allocator)
		}

		struct_key := rec_type != "" ? _clean_type_name(rec_type) : receiver
		for s in buf_syms {
			if s.receiver != "" && (s.receiver == receiver || s.receiver == struct_key) {
				push_candidate(&candidates, &seen, prefix, s.name, s.insert_text, s.detail, s.kind, allocator)
			}
		}
		for s in pkg_syms {
			if s.receiver != "" && (s.receiver == receiver || s.receiver == struct_key) {
				push_candidate(&candidates, &seen, prefix, s.name, s.insert_text, s.detail, s.kind, allocator)
			}
		}
	} else {
		// --- CASE B: Free Identifier Completion (`<prefix>`) ---
		for pin in pins {
			if pin.is_output {
				push_candidate(&candidates, &seen, prefix, pin.name, pin.name, fmt.tprintf("-> Out %s", pin.odin_type), .Pin_Out, allocator)
			} else if pin.pass_mode == .By_Reference {
				push_candidate(&candidates, &seen, prefix, pin.name, pin.name, fmt.tprintf("[Ref] ^%s", pin.odin_type), .Pin_Ref, allocator)
				deref_lbl := fmt.tprintf("%s^", pin.name)
				push_candidate(&candidates, &seen, prefix, deref_lbl, deref_lbl, fmt.tprintf("[Deref] %s", pin.odin_type), .Pin_Ref, allocator)
			} else {
				push_candidate(&candidates, &seen, prefix, pin.name, pin.name, fmt.tprintf("[Copy] %s", pin.odin_type), .Pin_Copy, allocator)
			}
		}

		// Blueprint `using self` variables & custom procedures!
		if is_scoped && (len(bp_spaces) == 0 || has_space(bp_spaces, "self")) {
			for bv in bp_vars {
				push_candidate(&candidates, &seen, prefix, bv.name, bv.name, fmt.tprintf("[using self] %s", bv.odin_type), .Pin_Ref, allocator)
			}
			for bproc in bp_procs {
				push_candidate(&candidates, &seen, prefix, bproc, fmt.tprintf("\"%s\"", bproc), "[Blueprint Proc]", .Hot_API, allocator)
			}
		}

		// Active `using math` / `using linalg` unqualified symbol injection!
		if has_space(bp_spaces, "using_math") {
			for b in _BUILTIN_ENTRIES {
				if b.receiver == "math" {
					push_candidate(&candidates, &seen, prefix, b.name, b.insert, fmt.tprintf("[using math] %s", b.detail), b.kind, allocator)
				}
			}
		}
		if has_space(bp_spaces, "using_linalg") {
			for b in _BUILTIN_ENTRIES {
				if b.receiver == "linalg" {
					push_candidate(&candidates, &seen, prefix, b.name, b.insert, fmt.tprintf("[using linalg] %s", b.detail), b.kind, allocator)
				}
			}
		}

		// Package aliases from imported / selected `Using` spaces
		for spec in USING_SPACE_CATALOG {
			if spec.repo_dir != "" && spec.pkg_alias != "" {
				push_candidate(&candidates, &seen, prefix, spec.pkg_alias, fmt.tprintf("%s.", spec.pkg_alias), spec.label, .Type_Sym, allocator)
			}
		}

		for s in buf_syms {
			if s.receiver == "" && s.name != prefix {
				push_candidate(&candidates, &seen, prefix, s.name, s.insert_text, s.detail, s.kind, allocator)
			}
		}

		for s in pkg_syms {
			if s.receiver == "" && s.name != prefix {
				push_candidate(&candidates, &seen, prefix, s.name, s.insert_text, s.detail, s.kind, allocator)
			}
		}
		for he in engine.hot_proc_entries() {
			push_candidate(&candidates, &seen, prefix, he.name, fmt.tprintf("%s(", he.name), "@(hot_proc)", .Hot_API, allocator)
		}

		for b in _BUILTIN_ENTRIES {
			if b.receiver == "" {
				push_candidate(&candidates, &seen, prefix, b.name, b.insert, b.detail, b.kind, allocator)
			}
		}
	}

	slice.sort_by(candidates[:], proc(a, b: Autocomplete_Item) -> bool {
		if a.score != b.score do return a.score > b.score
		return a.label < b.label
	})

	limit := min(len(candidates), AUTOCOMPLETE_MAX_RESULTS)
	return candidates[:limit], replace_start
}

// =============================================================================
// V3: Zero-Cost Inline Signature Call-Tip Hints & Hover Symbol Type Peek
// =============================================================================

Call_Tip_Info :: struct {
	callee:       string,
	receiver:     string,
	signature:    string,
	params:       []string,
	active_param: int,
}

// Scans backward on the current expression from `cursor_pos` to detect an enclosing `callee(arg0, |)` call!
extract_call_tip_info :: proc(src: string, cursor_pos: int, allocator := context.temp_allocator) -> (tip: Call_Tip_Info, ok: bool) {
	pos := clamp(cursor_pos, 0, len(src))
	if pos == 0 do return {}, false

	depth_paren   := 0
	depth_bracket := 0
	depth_brace   := 0
	commas        := 0
	in_str        := false
	open_paren_at := -1

	// Bounded backward scan (`<= 320` chars keeps worst-case cost `< 0.002 ms`!)
	min_scan := max(pos - 320, 0)
	for i := pos - 1; i >= min_scan; i -= 1 {
		c := src[i]
		if c == '"' && (i == 0 || src[i - 1] != '\\') {
			in_str = !in_str
			continue
		}
		if in_str do continue

		switch c {
		case ')': depth_paren   += 1
		case ']': depth_bracket += 1
		case '}': depth_brace   += 1
		case '[':
			if depth_bracket > 0 do depth_bracket -= 1
		case '{':
			if depth_brace > 0 do depth_brace -= 1
			else do return {}, false // Hit enclosing statement block `{` before any call `(`
		case ';':
			if depth_paren == 0 && depth_bracket == 0 && depth_brace == 0 do return {}, false
		case ',':
			if depth_paren == 0 && depth_bracket == 0 && depth_brace == 0 {
				commas += 1
			}
		case '(':
			if depth_paren > 0 {
				depth_paren -= 1
			} else {
				open_paren_at = i
				break
			}
		}
		if open_paren_at >= 0 do break
	}

	if open_paren_at <= 0 do return {}, false

	// Extract `callee` and optional `receiver.` before `(`
	fn_end := open_paren_at
	for fn_end > 0 && (src[fn_end - 1] == ' ' || src[fn_end - 1] == '\t') {
		fn_end -= 1
	}
	fn_start := fn_end
	for fn_start > 0 && is_odin_ident_char(src[fn_start - 1]) {
		fn_start -= 1
	}
	if fn_end <= fn_start do return {}, false
	callee := src[fn_start:fn_end]
	if callee == "if" || callee == "for" || callee == "switch" || callee == "proc" do return {}, false

	rec := extract_dot_receiver_before(src, fn_start)

	sig := ""
	for b in _BUILTIN_ENTRIES {
		if b.name == callee && (b.receiver == rec || (rec == "" && (b.receiver == "math" || b.receiver == "linalg" || b.receiver == ""))) {
			if strings.contains(b.detail, "(") {
				sig = b.detail
				break
			}
		}
	}

	if sig == "" && _ac.started {
		sync.mutex_lock(&_ac.mu)
		for s in _ac.buf_symbols {
			if s.name == callee && s.receiver == rec && strings.contains(s.detail, "(") {
				sig = strings.clone(s.detail, allocator)
				break
			}
		}
		if sig == "" {
			for s in _ac.pkg_symbols {
				if s.name == callee && (s.receiver == rec || rec == "") && strings.contains(s.detail, "(") {
					sig = strings.clone(s.detail, allocator)
					break
				}
			}
		}
		sync.mutex_unlock(&_ac.mu)
	}

	if sig == "" do return {}, false

	p_open  := strings.index_byte(sig, '(')
	p_close := strings.index_byte(sig, ')')
	params := make([dynamic]string, 0, 6, allocator)
	if p_open >= 0 && p_close > p_open {
		inner := strings.trim_space(sig[p_open + 1:p_close])
		if inner != "" {
			for part in strings.split(inner, ",", allocator) {
				append(&params, strings.trim_space(part))
			}
		}
	}

	return Call_Tip_Info{
		callee       = callee,
		receiver     = rec,
		signature    = sig,
		params       = params[:],
		active_param = commas,
	}, true
}

// Resolves a type / signature summary for an identifier hovered in the code surface (`0 ms`).
resolve_symbol_hover_info :: proc(ident: string, receiver: string, pins: []Scoped_Pin_Badge = nil, allocator := context.temp_allocator) -> string {
	if ident == "" do return ""
	for p in pins {
		if p.name == ident {
			mode_s := p.is_output ? "-> Output Pin" : (p.pass_mode == .By_Reference ? "[Ref Pin ^Ptr]" : "[Value Copy Pin]")
			return fmt.tprintf("%s `%s`: %s", mode_s, p.name, p.odin_type)
		}
	}
	for b in _BUILTIN_ENTRIES {
		if b.name == ident && (b.receiver == receiver || receiver == "") {
			if b.receiver != "" {
				return fmt.tprintf("%s.%s — %s", b.receiver, b.name, b.detail)
			}
			return fmt.tprintf("%s — %s", b.name, b.detail)
		}
	}
	sync.mutex_lock(&_ac.mu)
	defer sync.mutex_unlock(&_ac.mu)
	for bv in _ac.bp_vars {
		if bv.name == ident {
			return fmt.tprintf("[Blueprint `using self`] %s: %s", bv.name, bv.odin_type)
		}
	}
	if _ac.started {
		if lt, has_lt := _ac.local_types[ident]; has_lt {
			return fmt.tprintf("local `%s`: %s", ident, lt)
		}
		for s in _ac.buf_symbols {
			if s.name == ident && (s.receiver == receiver || receiver == "") {
				return fmt.tprintf("%s — %s", s.name, s.detail)
			}
		}
		for s in _ac.pkg_symbols {
			if s.name == ident && (s.receiver == receiver || receiver == "") {
				return fmt.tprintf("%s — %s", s.name, s.detail)
			}
		}
	}
	return ""
}
