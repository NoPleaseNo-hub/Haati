package code_studio

// =============================================================================
// IN-ENGINE ODIN MICRO-STUDIO V2 (`code_studio.odin`)
// =============================================================================
// Provides BOTH:
//   1. Scoped Function-Node Popup Micro-IDE (`open_scoped_node_popup` / `open_scoped_proc_popup`):
//      Focused popup IDE showing a Locked Pin Signature Header (`Copy (T)` vs `^Ref (^T)`),
//      Smart `[Enlarge / Restore (F11)]` toggle, `Ctrl + MouseWheel` crisp vector zoom,
//      Async Smart Autocomplete (`Tab`/`Enter` accept, dot-member completion), Find & Replace
//      (`Ctrl+F`), Auto-Indent, Bracket Match, `Ctrl+/` Comment, `Ctrl+D` Duplicate Line, and
//      two-stage throttled async syntax & compiler checking!
//   2. Dockable Full-File Odin Micro-Studio (`draw_micro_studio_window`):
//      Syntax-highlighted `.odin` editor sharing the full V2 IDE surface, quick fuzzy file/symbol
//      browser, live `@(hot_proc)` cartridge monitor (`F7` ~240 ms hot-swap), and clickable
//      Compiler Diagnostics table.

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import "haati:engine"
import crash_journal "haati:engine/crash_journal"
import hot "haati:engine/hot_api"
import im "haati:external/odin-imgui"

STUDIO_MIN_BUF_CAP :: 128 * 1024 // Initial backing buffer for full files; grows dynamically via `.CallbackResize`
SCOPED_MIN_BUF_CAP :: 64 * 1024  // Initial backing buffer for scoped procedure/node bodies; grows dynamically

CODE_ZOOM_MIN  :: f32(0.65)
CODE_ZOOM_MAX  :: f32(2.40)
CODE_ZOOM_STEP :: f32(0.10)

Scoped_Pin_Badge :: struct {
	name:      string,
	odin_type: string,
	pass_mode: hot.Hot_Pass_Mode,
	is_output: bool,
}

// Callback invoked when the user clicks `[Apply & Hot-Swap (F7)]` or `Ctrl+S` inside a scoped node popup.
Scoped_Node_Commit_Fn :: #type proc(node_uid: int, updated_body: string, trigger_hot_swap: bool, user_ptr: rawptr)

// Full-declaration commit hook (used when editing complete `fn :: proc(...) -> (...) { ... }` declarations in RAM).
Scoped_Full_Node_Commit_Fn :: #type proc(node_uid: int, full_decl: string, trigger_hot_swap: bool, user_ptr: rawptr) -> (ok: bool, err_msg: string)
Scoped_Clone_To_Bodin_Fn   :: #type proc(full_decl: string, user_ptr: rawptr)
Scoped_Dock_Split_Fn       :: #type proc(user_ptr: rawptr)

// Optional hooks allowing the Scoped Popup IDE to toggle Blueprint `Using` namespaces (`using self`, `using math`, etc.)
Scoped_Using_Toggle_Fn :: #type proc(space_id: string, user_ptr: rawptr) -> string
Scoped_Using_Query_Fn  :: #type proc(space_id: string, user_ptr: rawptr) -> bool

// Per-editor interactive IDE state (shared cleanly by Scoped Popup and Docked Studio)
@(private = "file")
_Surface_IDE_State :: struct {
	cursor_pos:         int,
	sel_start:          int,
	sel_end:            int,
	caret_line:         int,
	caret_col:          int,

	// Autocomplete state
	ac_open:              bool,
	ac_dismissed_pos:     int, // Suppresses re-opening at exact same cursor offset after `Esc`
	ac_selected_idx:      int,
	ac_replace_start:     int,
	ac_force_open:        bool,
	ac_pending_accept:    bool,
	ac_refocus_input:     bool,
	ac_popup_interacting: bool,
	ac_popup_dragging:    bool,
	ac_accept_text:       [256]byte,
	ac_accept_len:        int,

	// Ctrl+Click symbol jump output (`req_jump_ident` set for 1 frame when user Ctrl+Clicks an identifier)
	req_jump_ident:     string,
	req_jump_rec:       string,

	// Pending IDE commands executed cleanly inside `CallbackAlways` where `ImGuiInputTextState` is live
	cmd_auto_indent:    bool,
	cmd_toggle_comment: bool,
	cmd_dup_line:       bool,
	cmd_outdent_tab:    bool,
	cmd_jump_offset:    int, // >= 0 jumps caret to byte offset (e.g. Find Next)
	cmd_jump_line:      int, // > 0 scrolls & moves caret to 1-based line on next draw
	cmd_paste_pending:  bool,
	cmd_paste_text:     string,

	// Autocomplete Up/Down cursor-lock (avoids ImGui forbidden `.CallbackHistory` on multiline inputs)
	ac_lock_cursor:     bool,
	ac_locked_cpos:     int,
	ac_locked_sels:     int,
	ac_locked_sele:     int,
	ac_nav_moved:       bool,

	// 64-Step Undo/Redo sync into active `ImGuiInputTextState` + immediate snapshot barrier
	next_edit_immediate: bool,
	cmd_restore_active:  bool,
	cmd_restore_applied: bool,
	cmd_restore_text:    string,
	cmd_restore_cursor:  int,

	// Inline Find & Replace bar (`Ctrl+F`) + Go-to-Line (`Ctrl+G`)
	find_open:           bool,
	find_focus_next:     bool,
	find_case_sensitive: bool,
	find_current_offset: int,
	find_match_len:      int,
	find_buf:            [128]byte,
	replace_buf:         [128]byte,
	goto_open:           bool,
	goto_focus_next:     bool,
	goto_buf:            [32]byte,
	cmd_move_line_dir:   int, // `-1` = Alt+Up, `+1` = Alt+Down
	cmd_jump_col:        int,
	flash_line:          int,
	flash_until_sec:     f64,
	qf_line:             int,
	qf_anchor:           im.Vec2,
	req_open_imports_popup: bool,
	read_only_surface:      bool,
	conflict_line:          int,
	conflict_col_start:     int,
	conflict_col_end:       int,

	// Document-revision syntax, line & unused-import cache (`0` tokenizer/layout work on idle frames)
	cache_valid:                bool,
	cache_hash:                 u64,
	cache_len:                  int,
	cache_max_cols:             int,
	active_buf:                 ^[]byte,
	cached_line_starts:         [dynamic]int,
	cached_spans:               [dynamic]Syntax_Span,
	cached_line_span_head:      [dynamic]int,
	cached_unused_import_lines: [dynamic]int,
}

CODE_UNDO_MAX                 :: 64
CODE_UNDO_TYPING_DEBOUNCE_SEC :: f64(0.45)

Code_Undo_Entry :: struct {
	text:   string,
	cursor: int,
}

Code_Undo_Stack :: struct {
	undo:             [dynamic]Code_Undo_Entry,
	redo:             [dynamic]Code_Undo_Entry,
	current_text:     string,
	current_cursor:   int,
	initialized:      bool,
	pending_typing:   bool,
	last_typing_time: f64,
}

@(private = "file")
_Refactor_File_Buf :: struct {
	file_abs:   string,
	file_title: string,
	pkg_dir:    string,
	buf:        []byte,
	undo:       Code_Undo_Stack,
	ide:        _Surface_IDE_State,
	scroll_line: int,
	dirty:      bool,
	is_bodin:   bool,
}

@(private = "file")
_Refactor_Site_Ref :: struct {
	file_idx:    int,
	line:        int,
	col:         int,
	end_col:     int,
	before_line: string,
	reviewed:    bool,
}

// Reusable embedded RAM Odin editor surface for the `::` Blueprint Omnibar Scratchpad.
Scratchpad_Surface :: struct {
	buf:      []byte,
	undo:     Code_Undo_Stack,
	ide:      _Surface_IDE_State,
	last_src: string,
}

@(private = "file")
_Scoped_Popup_State :: struct {
	open:               bool,
	just_opened:        bool,
	enlarged:           bool, // Smart Enlarge / Zen Maximize state (`F11` or header button)
	apply_enlarge_pos:  bool,
	apply_wheel_resize: bool,
	saved_pos:          im.Vec2,
	saved_size:         im.Vec2,
	has_saved_rect:     bool,

	title:              string,
	signature_banner:   string,
	pins:               [dynamic]Scoped_Pin_Badge,

	// Read-only protection & Full-Declaration RAM Mode
	read_only:          bool,
	is_snippet_preview: bool,
	is_full_decl:       bool,
	full_commit_cb:     Scoped_Full_Node_Commit_Fn,
	clone_cb:           Scoped_Clone_To_Bodin_Fn,
	clone_user_ptr:     rawptr,
	dock_split_cb:      Scoped_Dock_Split_Fn,
	dock_user_ptr:      rawptr,

	// Mode 1: Backing an in-memory Niagara `Odin_Function_Node`
	is_graph_node:      bool,
	node_uid:           int,
	commit_cb:          Scoped_Node_Commit_Fn,
	commit_user_ptr:    rawptr,
	using_toggle_cb:    Scoped_Using_Toggle_Fn,
	using_query_cb:     Scoped_Using_Query_Fn,
	using_search_buf:   [64]byte,

	// Mode 2: Backing a real `.odin`/`.bodin` procedure sliced out of `backing_file_abs`
	backing_file_abs:   string,
	backing_pkg_dir:    string,
	backing_proc_name:  string,
	full_file_cache:    string,
	orig_proc_name:     string,
	orig_sig_key:       string,
	orig_decl_s_line:   int,
	orig_decl_e_line:   int,

	// Rider-style Call-Site Impact Review Queue (RAM only until Commit)
	refactor_active:     bool,
	refactor_files:      [dynamic]_Refactor_File_Buf,
	refactor_sites:      [dynamic]_Refactor_Site_Ref,
	refactor_active_idx: int,
	pending_default_arg: string,

	buf:                []byte,
	dirty:              bool,
	focused:            bool,
	status_note:        string,
	status_is_err:      bool,
	ide:                _Surface_IDE_State,
	undo:               Code_Undo_Stack,
}

@(private = "file")
_Tab_Doc :: struct {
	uid:            int,
	title:          string,
	abs_path:       string,
	pkg_dir:        string,
	paired_bodin:   string,
	paired_checked: bool,
	buf:            []byte,
	dirty:          bool,
	uses_tabs:      bool,
	scroll_line:    int,
	cursor_pos:     int,
	scroll_y:       f32,
	undo:           Code_Undo_Stack,
}

@(private = "file")
_Code_Nav_Entry :: struct {
	abs_path: string,
	line:     int,
}

@(private = "file")
_Studio_State :: struct {
	initialized:            bool,
	next_tab_uid:           int,
	tabs:                   [dynamic]_Tab_Doc,
	active_tab:             int,
	request_tab_select:     int,
	search_buf:             [128]byte,
	sym_jump_buf:           [96]byte,
	using_search_buf:       [64]byte,
	discovered_files:       [dynamic]string,
	files_scanned:          bool,
	explorer_zoom:          f32, // Independent `Ctrl + MouseWheel` zoom for Left Explorer & Structure
	code_zoom:              f32, // Independent `Ctrl + MouseWheel` zoom for Center Code Surface
	problems_zoom:          f32, // Independent `Ctrl + MouseWheel` zoom for Bottom Problems / Output
	left_width:             f32,
	problems_height:        f32,
	show_breadcrumbs:       bool,
	show_error_lens:        bool,
	defaults_seeded:        bool,
	window_hovered:         bool,
	window_focused:         bool,
	emb_full_focused:       bool,
	last_undo_redo_frame:   i32,
	ide:                    _Surface_IDE_State,
	relaunch_cb:            proc(),
	open_ide_cb:            proc(abs_path: string, line: int) -> bool,
	switch_to_bp_cb:        proc(script_path: string),
	bodin_saved_cb:         proc(abs_path: string, trigger_hotswap: bool),
	bodin_sandbox_cb:       proc(abs_path: string, ram_src: string) -> bool,
	sandbox_mode:           bool,
	sandbox_toggle_cb:      proc(enabled: bool),
	nav_stack:              [32]_Code_Nav_Entry,
	nav_len:                int,
	nav_cursor:             int,

	// Document-revision outline symbol cache
	outline_valid:          bool,
	outline_hash:           u64,
	outline_len:            int,
	outline_arena_init:     bool,
	outline_arena:          mem.Dynamic_Arena,
	outline_syms:           []Outline_Symbol,

	// Watchdog dirty-tab revision, hover doc cache & embedded arg cache
	dirty_tabs_rev:         u64,
	diag_cycle_idx:         int,
	hot_doc_cache:          map[string]string,
	last_emb_arg:           string,
	last_emb_norm:          string,
	emb_user_closed:        bool,
}

@(private = "file")
_clamp_utf8_boundary :: #force_inline proc(s: string, pos: int) -> int {
	p := clamp(pos, 0, len(s))
	for p > 0 && p < len(s) && (s[p] & 0xC0) == 0x80 {
		p -= 1
	}
	return p
}

dirty_tabs_revision :: proc() -> u64 {
	return _studio.dirty_tabs_rev
}

@(private = "file")
_fnv1a_src :: #force_inline proc(s: string) -> u64 {
	return hash.fnv64a(transmute([]u8)s)
}

@(private = "file")
_free_ide_surface_cache :: proc(ide: ^_Surface_IDE_State) {
	if ide == nil do return
	_clear_ide_pending_paste(ide)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	delete(ide.cached_line_starts)
	delete(ide.cached_spans)
	delete(ide.cached_line_span_head)
	delete(ide.cached_unused_import_lines)
	ide.cached_line_starts         = nil
	ide.cached_spans               = nil
	ide.cached_line_span_head      = nil
	ide.cached_unused_import_lines = nil
	ide.cache_valid                = false
	ide.cache_hash                 = 0
	ide.cache_len                  = 0
	ide.cache_max_cols             = 0
}

@(private = "file")
_is_unused_import_line :: proc(ide: ^_Surface_IDE_State, line_num: int) -> bool {
	if ide == nil do return false
	for u_ln in ide.cached_unused_import_lines {
		if u_ln == line_num do return true
	}
	return false
}

@(private = "file")
_clear_ide_pending_paste :: proc(ide: ^_Surface_IDE_State) {
	if ide == nil do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if ide.cmd_paste_text != "" {
		delete(ide.cmd_paste_text)
		ide.cmd_paste_text = ""
	}
	ide.cmd_paste_pending = false
}

@(private = "file")
_trigger_line_flash :: #force_inline proc(ide: ^_Surface_IDE_State, line_1based: int) {
	if ide == nil || line_1based <= 0 do return
	ide.flash_line = line_1based
	if im.GetCurrentContext() != nil {
		ide.flash_until_sec = im.GetTime() + 1.25
	}
}

@(private = "file")
_jump_ide_to_line :: proc(ide: ^_Surface_IDE_State, target_ln: int, target_col: int = 1) {
	if ide == nil || target_ln <= 0 do return
	ide.cmd_jump_line = target_ln
	ide.cmd_jump_col  = max(target_col, 1)
	_trigger_line_flash(ide, target_ln)
}

@(private = "file")
_ensure_ide_surface_cache :: proc(ide: ^_Surface_IDE_State, src: string) {
	if ide == nil do return
	h := _fnv1a_src(src)
	if ide.cache_valid && ide.cache_hash == h && ide.cache_len == len(src) {
		return
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	clear(&ide.cached_line_starts)
	clear(&ide.cached_spans)
	clear(&ide.cached_line_span_head)
	clear(&ide.cached_unused_import_lines)

	// Single-pass line start + max column computation
	append(&ide.cached_line_starts, 0)
	line_start := 0
	max_cols := 0
	for i in 0 ..< len(src) {
		if src[i] == '\n' {
			cols := i - line_start
			if cols > 0 && src[i - 1] == '\r' do cols -= 1
			if cols > max_cols do max_cols = cols
			append(&ide.cached_line_starts, i + 1)
			line_start = i + 1
		}
	}
	tail_cols := len(src) - line_start
	if tail_cols > 0 && src[len(src) - 1] == '\r' do tail_cols -= 1
	if tail_cols > max_cols do max_cols = tail_cols

	spans := tokenize_odin_lines(src, ide.cached_line_starts[:], context.temp_allocator)
	for sp in spans {
		append(&ide.cached_spans, sp)
	}

	if strings.contains(src, "import") {
		unused := detect_unused_odin_imports(src, context.temp_allocator)
		for u in unused {
			append(&ide.cached_unused_import_lines, u.line)
		}
	}

	// Build O(1) first-span index per line so visible-line clipping jumps straight to first_ln_i
	n_lines := len(ide.cached_line_starts)
	resize(&ide.cached_line_span_head, n_lines)
	s_idx := 0
	for ln_i in 0 ..< n_lines {
		target_ln := ln_i + 1
		for s_idx < len(ide.cached_spans) && ide.cached_spans[s_idx].line < target_ln {
			s_idx += 1
		}
		ide.cached_line_span_head[ln_i] = s_idx
	}

	ide.cache_valid    = true
	ide.cache_hash     = h
	ide.cache_len      = len(src)
	ide.cache_max_cols = max_cols
}

@(private = "file")
_get_cached_outline_symbols :: proc(src: string) -> []Outline_Symbol {
	h := _fnv1a_src(src)
	if _studio.outline_valid && _studio.outline_hash == h && _studio.outline_len == len(src) {
		return _studio.outline_syms
	}
	if !_studio.outline_arena_init {
		mem.dynamic_arena_init(&_studio.outline_arena)
		_studio.outline_arena_init = true
	} else {
		mem.dynamic_arena_reset(&_studio.outline_arena)
	}
	_studio.outline_syms  = extract_odin_outline_symbols(src, mem.dynamic_arena_allocator(&_studio.outline_arena))
	_studio.outline_valid = true
	_studio.outline_hash  = h
	_studio.outline_len   = len(src)
	return _studio.outline_syms
}

@(private = "file")
_scoped: _Scoped_Popup_State

@(private = "file")
_emb_scoped: _Scoped_Popup_State

@(private = "file")
_studio: _Studio_State

@(private = "file")
_ensure_zoom_init :: #force_inline proc() {
	if _studio.code_zoom < CODE_ZOOM_MIN || _studio.code_zoom > CODE_ZOOM_MAX {
		_studio.code_zoom = 1.0
	}
	if _studio.explorer_zoom < CODE_ZOOM_MIN || _studio.explorer_zoom > CODE_ZOOM_MAX {
		_studio.explorer_zoom = 1.0
	}
	if _studio.problems_zoom < CODE_ZOOM_MIN || _studio.problems_zoom > CODE_ZOOM_MAX {
		_studio.problems_zoom = 1.0
	}
	if _studio.left_width < 180.0 || _studio.left_width > 560.0 {
		_studio.left_width = 264.0
	}
	if _studio.problems_height < 44.0 || _studio.problems_height > 360.0 {
		_studio.problems_height = 108.0
	}
	if !_studio.defaults_seeded {
		_studio.defaults_seeded      = true
		_studio.request_tab_select   = -1
		_studio.show_breadcrumbs     = true
		_studio.show_error_lens      = true
		_studio.sandbox_mode         = true
		_studio.last_undo_redo_frame = -1
	}
}

owns_keyboard_shortcuts :: proc() -> bool {
	return _studio.window_hovered || _studio.window_focused || _studio.emb_full_focused || _scoped.open || _emb_scoped.focused
}

// =============================================================================
// 64-Step Per-Tab & Scoped Undo/Redo Stack (`Code_Undo_Stack`)
// =============================================================================

@(private = "file")
_free_undo_entries :: proc(arr: ^[dynamic]Code_Undo_Entry) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for &e in arr^ {
		if e.text != "" do delete(e.text)
	}
	clear(arr)
}

@(private = "file")
_clear_ide_pending_restore :: proc(ide: ^_Surface_IDE_State) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if ide.cmd_restore_text != "" {
		delete(ide.cmd_restore_text)
		ide.cmd_restore_text = ""
	}
	ide.cmd_restore_active = false
}

@(private = "file")
_arm_ide_restore :: proc(ide: ^_Surface_IDE_State, text: string, cursor: int) {
	_clear_ide_pending_restore(ide)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	ide.cmd_restore_text   = strings.clone(text)
	ide.cmd_restore_cursor = cursor
	ide.cmd_restore_active = true
	ide.cmd_jump_offset    = cursor
}

code_undo_reset :: proc(st: ^Code_Undo_Stack, initial_text: string, initial_cursor: int = 0) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_free_undo_entries(&st.undo)
	_free_undo_entries(&st.redo)
	if st.current_text != "" {
		delete(st.current_text)
	}
	st.current_text     = strings.clone(initial_text)
	st.current_cursor   = initial_cursor
	st.initialized      = true
	st.pending_typing   = false
	st.last_typing_time = 0
}

code_undo_free :: proc(st: ^Code_Undo_Stack) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_free_undo_entries(&st.undo)
	_free_undo_entries(&st.redo)
	delete(st.undo)
	delete(st.redo)
	if st.current_text != "" {
		delete(st.current_text)
	}
	st^ = {}
}

code_undo_can_undo :: proc(st: ^Code_Undo_Stack) -> bool {
	return st != nil && st.initialized && len(st.undo) > 0
}

code_undo_can_redo :: proc(st: ^Code_Undo_Stack) -> bool {
	return st != nil && st.initialized && len(st.redo) > 0
}

@(private = "file")
_push_capped_undo_entry :: proc(arr: ^[dynamic]Code_Undo_Entry, entry: Code_Undo_Entry) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	append(arr, entry)
	for len(arr^) > CODE_UNDO_MAX {
		if arr[0].text != "" do delete(arr[0].text)
		ordered_remove(arr, 0)
	}
}

code_undo_record_edit :: proc(
	st: ^Code_Undo_Stack,
	new_text: string,
	new_cursor: int,
	now_sec: f64,
	immediate: bool = false,
	debounce_sec: f64 = CODE_UNDO_TYPING_DEBOUNCE_SEC,
) {
	if st == nil do return
	if !st.initialized {
		code_undo_reset(st, new_text, new_cursor)
		return
	}
	if new_text == st.current_text {
		st.current_cursor = new_cursor
		return
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_free_undo_entries(&st.redo)

	within_burst := !immediate && st.pending_typing && (now_sec - st.last_typing_time) < debounce_sec
	if within_burst {
		if st.current_text != "" do delete(st.current_text)
		st.current_text     = strings.clone(new_text)
		st.current_cursor   = new_cursor
		st.last_typing_time = now_sec
		return
	}

	_push_capped_undo_entry(&st.undo, Code_Undo_Entry{
		text   = st.current_text,
		cursor = st.current_cursor,
	})
	st.current_text     = strings.clone(new_text)
	st.current_cursor   = new_cursor
	st.pending_typing   = !immediate
	st.last_typing_time = now_sec
}

code_undo_step_undo :: proc(st: ^Code_Undo_Stack) -> (entry: Code_Undo_Entry, ok: bool) {
	if !code_undo_can_undo(st) do return {}, false
	_push_capped_undo_entry(&st.redo, Code_Undo_Entry{
		text   = st.current_text,
		cursor = st.current_cursor,
	})
	prev := st.undo[len(st.undo) - 1]
	resize(&st.undo, len(st.undo) - 1)
	st.current_text   = prev.text
	st.current_cursor = prev.cursor
	st.pending_typing = false
	return Code_Undo_Entry{text = st.current_text, cursor = st.current_cursor}, true
}

code_undo_step_redo :: proc(st: ^Code_Undo_Stack) -> (entry: Code_Undo_Entry, ok: bool) {
	if !code_undo_can_redo(st) do return {}, false
	_push_capped_undo_entry(&st.undo, Code_Undo_Entry{
		text   = st.current_text,
		cursor = st.current_cursor,
	})
	nxt := st.redo[len(st.redo) - 1]
	resize(&st.redo, len(st.redo) - 1)
	st.current_text   = nxt.text
	st.current_cursor = nxt.cursor
	st.pending_typing = false
	return Code_Undo_Entry{text = st.current_text, cursor = st.current_cursor}, true
}

@(private = "file")
_active_undo_context :: proc() -> (
	undo:      ^Code_Undo_Stack,
	buf:       ^[]byte,
	ide:       ^_Surface_IDE_State,
	dirty:     ^bool,
	pkg_dir:   string,
	is_scoped: bool,
	ok:        bool,
) {
	if _scoped.open && _scoped.focused {
		return &_scoped.undo, &_scoped.buf, &_scoped.ide, &_scoped.dirty, _scoped.backing_pkg_dir, true, true
	}
	if _emb_scoped.open && _emb_scoped.focused {
		return &_emb_scoped.undo, &_emb_scoped.buf, &_emb_scoped.ide, &_emb_scoped.dirty, "haati/hot_scripts", true, true
	}
	if (_studio.window_focused || _studio.emb_full_focused) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		t := &_studio.tabs[_studio.active_tab]
		return &t.undo, &t.buf, &_studio.ide, &t.dirty, t.pkg_dir, false, true
	}
	return nil, nil, nil, nil, "", false, false
}

code_studio_has_focus :: proc() -> bool {
	if _scoped.open && _scoped.focused do return true
	if _emb_scoped.open && _emb_scoped.focused do return true
	return _studio.window_focused || _studio.emb_full_focused
}

code_studio_can_undo :: proc() -> bool {
	if u, _, _, _, _, _, ok := _active_undo_context(); ok {
		return code_undo_can_undo(u)
	}
	return false
}

code_studio_can_redo :: proc() -> bool {
	if u, _, _, _, _, _, ok := _active_undo_context(); ok {
		return code_undo_can_redo(u)
	}
	return false
}

@(private = "file")
_apply_undo_or_redo_step :: proc(
	is_undo:   bool,
	undo:      ^Code_Undo_Stack,
	buf:       ^[]byte,
	ide:       ^_Surface_IDE_State,
	dirty:     ^bool,
	pkg_dir:   string,
	is_scoped: bool,
) -> bool {
	entry: Code_Undo_Entry
	ok: bool
	if is_undo {
		entry, ok = code_undo_step_undo(undo)
	} else {
		entry, ok = code_undo_step_redo(undo)
	}
	if !ok do return false
	_copy_to_c_buf_grow(buf, entry.text, is_scoped ? SCOPED_MIN_BUF_CAP : STUDIO_MIN_BUF_CAP)
	if dirty != nil do dirty^ = true
	_arm_ide_restore(ide, entry.text, entry.cursor)
	ide.ac_open          = false
	ide.ac_dismissed_pos = -1
	s_now := _c_buf_string(buf^)
	_notify_buffer_edited(s_now, is_scoped, pkg_dir)
	if im.GetCurrentContext() != nil {
		_studio.last_undo_redo_frame = im.GetFrameCount()
	}
	return true
}

code_studio_undo :: proc() -> bool {
	if u, buf, ide, dirty, pkg_dir, is_sc, ok := _active_undo_context(); ok {
		return _apply_undo_or_redo_step(true, u, buf, ide, dirty, pkg_dir, is_sc)
	}
	return false
}

code_studio_redo :: proc() -> bool {
	if u, buf, ide, dirty, pkg_dir, is_sc, ok := _active_undo_context(); ok {
		return _apply_undo_or_redo_step(false, u, buf, ide, dirty, pkg_dir, is_sc)
	}
	return false
}

@(private = "file")
_draw_undo_redo_buttons :: proc(
	undo:      ^Code_Undo_Stack,
	buf:       ^[]byte,
	ide:       ^_Surface_IDE_State,
	dirty:     ^bool,
	pkg_dir:   string,
	is_scoped: bool,
	id_suffix: cstring,
) {
	can_u := code_undo_can_undo(undo)
	if !can_u do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s##cs_undo_%s", icons.ICON_MD_UNDO, id_suffix)) {
		_apply_undo_or_redo_step(true, undo, buf, ide, dirty, pkg_dir, is_scoped)
	}
	if !can_u do im.EndDisabled()
	widgets.tooltip("Undo (Ctrl+Z — 64-step history)")

	im.SameLine(0, 2)
	can_r := code_undo_can_redo(undo)
	if !can_r do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s##cs_redo_%s", icons.ICON_MD_REDO, id_suffix)) {
		_apply_undo_or_redo_step(false, undo, buf, ide, dirty, pkg_dir, is_scoped)
	}
	if !can_r do im.EndDisabled()
	widgets.tooltip("Redo (Ctrl+Y / Ctrl+Shift+Z)")
}

configure_ide_defaults :: proc(explorer_zm, code_zm, problems_zm: f32, breadcrumbs, error_lens, sync_panes: bool, problem_delay_sec: f32 = 0.90) {
	_ensure_zoom_init()
	_studio.show_breadcrumbs = breadcrumbs
	_studio.show_error_lens  = error_lens
	set_problem_check_delay_sec(problem_delay_sec)
	if sync_panes {
		set_studio_explorer_zoom(explorer_zm)
		set_studio_code_zoom(code_zm)
		set_studio_problems_zoom(problems_zm)
	}
}

// Public getter/setter for unit tests & independent segment zoom controls.
studio_code_zoom :: proc() -> f32 {
	_ensure_zoom_init()
	return _studio.code_zoom
}

set_studio_code_zoom :: proc(zoom: f32) {
	_ensure_zoom_init()
	_studio.code_zoom = clamp(zoom, CODE_ZOOM_MIN, CODE_ZOOM_MAX)
}

studio_explorer_zoom :: proc() -> f32 {
	_ensure_zoom_init()
	return _studio.explorer_zoom
}

set_studio_explorer_zoom :: proc(zoom: f32) {
	_ensure_zoom_init()
	_studio.explorer_zoom = clamp(zoom, CODE_ZOOM_MIN, 2.00)
}

studio_problems_zoom :: proc() -> f32 {
	_ensure_zoom_init()
	return _studio.problems_zoom
}

set_studio_problems_zoom :: proc(zoom: f32) {
	_ensure_zoom_init()
	_studio.problems_zoom = clamp(zoom, CODE_ZOOM_MIN, 2.00)
}

// Registers Blueprint `Using` namespace toggle/query hooks for the Scoped Node Popup & Embedded Scoped IDEs.
set_scoped_using_hooks :: proc(toggle_cb: Scoped_Using_Toggle_Fn, query_cb: Scoped_Using_Query_Fn) {
	_scoped.using_toggle_cb     = toggle_cb
	_scoped.using_query_cb      = query_cb
	_emb_scoped.using_toggle_cb = toggle_cb
	_emb_scoped.using_query_cb  = query_cb
}

// Registers host editor hooks (`Relaunch (RAM Handoff)` and external IDE jump).
install_editor_hooks :: proc(relaunch_fn: proc(), open_ide_fn: proc(abs_path: string, line: int) -> bool) {
	_studio.relaunch_cb = relaunch_fn
	_studio.open_ide_cb = open_ide_fn
}

// Registers the callback that switches back to Unified Graph Studio for `.bodin` / `_mhgraph_generated.odin`.
install_blueprint_switch_hook :: proc(switch_fn: proc(script_path: string)) {
	_studio.switch_to_bp_cb = switch_fn
}

// Registers the callback invoked when standalone Odin Micro-Studio saves or hot-swaps a `.bodin` file.
register_bodin_save_hook :: proc(cb: proc(abs_path: string, trigger_hotswap: bool)) {
	_studio.bodin_saved_cb = cb
}

// Registers the RAM-sandbox hook invoked on `F7` when Sandbox Mode is active on an unsaved `.bodin` buffer.
register_bodin_sandbox_hook :: proc(cb: proc(abs_path: string, ram_src: string) -> bool) {
	_studio.bodin_sandbox_cb = cb
}

set_sandbox_mode :: proc(enabled: bool) {
	_ensure_zoom_init()
	_studio.sandbox_mode = enabled
}

sandbox_mode_enabled :: proc() -> bool {
	_ensure_zoom_init()
	return _studio.sandbox_mode
}

register_sandbox_toggle_hook :: proc(cb: proc(enabled: bool)) {
	_studio.sandbox_toggle_cb = cb
}

// Draws the live runtime Sandbox Fault Banner whenever a script triggered a caught panic/VEH fault.
draw_sandbox_fault_banner :: proc() {
	fault := engine.hot_cartridge_last_sandbox_fault()
	if !fault.has_fault do return
	p := thm.palette()
	im.PushStyleColorImVec4(.ChildBg, thm.with_alpha(p.status_error, 0.20))
	if im.BeginChild("##sandbox_fault_banner", {0, 34}, {.Borders}) {
		widgets.text_coloredf(p.status_error, "%s [SANDBOX CAUGHT CRASH] %s() (%s:%d): %s",
			icons.ICON_MD_WARNING, fault.proc_name, filepath.base(fault.file), max(fault.line, 1), fault.reason)
		im.SameLine(0, 10)
		if fault.file != "" && im.SmallButton("Jump to Line##sbf_jmp") {
			open_file_in_studio(fault.file, max(int(fault.line), 1))
			wnd.open("odin_micro_studio")
		}
		im.SameLine(0, 6)
		if im.SmallButton("Re-Arm / Dismiss##sbf_rst") {
			engine.hot_cartridge_clear_faults()
		}
	}
	im.EndChild()
	im.PopStyleColor()
}

// Returns the live in-memory buffer text for an open tab matching `abs_or_rel_path` (if any).
get_open_tab_text :: proc(abs_or_rel_path: string, allocator := context.temp_allocator) -> (text: string, is_open: bool) {
	if abs_or_rel_path == "" do return "", false
	norm_abs := resolve_workspace_path(abs_or_rel_path, context.temp_allocator)
	for &t in _studio.tabs {
		if strings.equal_fold(t.abs_path, norm_abs) {
			disk_like := format_studio_buffer_for_disk(_c_buf_string(t.buf), t.uses_tabs, context.temp_allocator)
			return strings.clone(disk_like, allocator), true
		}
	}
	return "", false
}

// Updates an already-open Code Studio tab in RAM without writing to disk.
upsert_open_tab_ram_text :: proc(abs_or_rel_path: string, new_src: string) {
	if abs_or_rel_path == "" do return
	norm_abs := resolve_workspace_path(abs_or_rel_path, context.temp_allocator)
	for &t in _studio.tabs {
		if strings.equal_fold(t.abs_path, norm_abs) {
			t.uses_tabs = detect_odin_hard_tabs(new_src)
			_copy_to_c_buf_grow(&t.buf, new_src, STUDIO_MIN_BUF_CAP)
			t.dirty = true
			s := _c_buf_string(t.buf)
			if t.undo.initialized {
				code_undo_record_edit(&t.undo, s, 0, im.GetTime(), true)
			} else {
				code_undo_reset(&t.undo, s, 0)
			}
			_notify_buffer_edited(s, false, t.pkg_dir, false, t.abs_path)
			return
		}
	}
}

shutdown_studio :: proc() {
	shutdown_checker()
	shutdown_autocomplete()
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for &tab in _studio.tabs {
		delete(tab.title)
		delete(tab.abs_path)
		delete(tab.pkg_dir)
		if tab.paired_bodin != "" do delete(tab.paired_bodin)
		delete(tab.buf)
		code_undo_free(&tab.undo)
	}
	delete(_studio.tabs)
	for k, v in _studio.hot_doc_cache {
		delete(k)
		delete(v)
	}
	delete(_studio.hot_doc_cache)
	if _studio.last_emb_arg  != "" do delete(_studio.last_emb_arg)
	if _studio.last_emb_norm != "" do delete(_studio.last_emb_norm)
	_clear_ide_pending_restore(&_studio.ide)
	_free_ide_surface_cache(&_studio.ide)
	if _studio.outline_arena_init {
		mem.dynamic_arena_destroy(&_studio.outline_arena)
	}
	for f in _studio.discovered_files do delete(f)
	delete(_studio.discovered_files)
	for i in 0 ..< _studio.nav_len {
		if _studio.nav_stack[i].abs_path != "" do delete(_studio.nav_stack[i].abs_path)
	}
	_studio = {}

	_clear_scoped_state(&_scoped)
	if len(_scoped.buf) > 0 do delete(_scoped.buf)
	delete(_scoped.pins)
	_scoped = {}

	_clear_scoped_state(&_emb_scoped)
	if len(_emb_scoped.buf) > 0 do delete(_emb_scoped.buf)
	delete(_emb_scoped.pins)
	_emb_scoped = {}
}

@(private = "file")
_clear_scoped_strings :: #force_inline proc() {
	_clear_scoped_state(&_scoped)
}

@(private = "file")
_clear_scoped_refactor :: proc(s: ^_Scoped_Popup_State) {
	if s == nil do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for &rf in s.refactor_files {
		if rf.file_abs   != "" do delete(rf.file_abs)
		if rf.file_title != "" do delete(rf.file_title)
		if rf.pkg_dir    != "" do delete(rf.pkg_dir)
		if len(rf.buf) > 0 do delete(rf.buf)
		code_undo_free(&rf.undo)
		_clear_ide_pending_restore(&rf.ide)
		_free_ide_surface_cache(&rf.ide)
	}
	delete(s.refactor_files)
	for rs in s.refactor_sites {
		if rs.before_line != "" do delete(rs.before_line)
	}
	delete(s.refactor_sites)
	if s.pending_default_arg != "" do delete(s.pending_default_arg)
	s.refactor_files      = nil
	s.refactor_sites      = nil
	s.refactor_active     = false
	s.refactor_active_idx = -1
	s.pending_default_arg = ""
}

@(private = "file")
_clear_scoped_state :: proc(s: ^_Scoped_Popup_State) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_clear_scoped_refactor(s)
	if s.title             != "" do delete(s.title)
	if s.signature_banner  != "" do delete(s.signature_banner)
	if s.backing_file_abs  != "" do delete(s.backing_file_abs)
	if s.backing_pkg_dir   != "" do delete(s.backing_pkg_dir)
	if s.backing_proc_name != "" do delete(s.backing_proc_name)
	if s.full_file_cache   != "" do delete(s.full_file_cache)
	if s.orig_proc_name    != "" do delete(s.orig_proc_name)
	if s.orig_sig_key      != "" do delete(s.orig_sig_key)
	if s.status_note       != "" do delete(s.status_note)
	for p in s.pins {
		delete(p.name)
		delete(p.odin_type)
	}
	clear(&s.pins)
	_clear_ide_pending_restore(&s.ide)
	_free_ide_surface_cache(&s.ide)
	code_undo_free(&s.undo)
	s.title              = ""
	s.signature_banner   = ""
	s.backing_file_abs   = ""
	s.backing_pkg_dir    = ""
	s.backing_proc_name  = ""
	s.full_file_cache    = ""
	s.orig_proc_name     = ""
	s.orig_sig_key       = ""
	s.status_note        = ""
	s.status_is_err      = false
	s.read_only          = false
	s.is_snippet_preview = false
	s.is_full_decl       = false
	s.full_commit_cb     = nil
	s.clone_cb           = nil
	s.clone_user_ptr     = nil
	s.dock_split_cb      = nil
	s.dock_user_ptr      = nil
	s.is_graph_node      = false
	s.node_uid           = 0
	s.commit_cb          = nil
	s.commit_user_ptr    = nil
	s.using_toggle_cb    = nil
	s.using_query_cb     = nil
	s.using_search_buf   = {}
	s.orig_decl_s_line   = 0
	s.orig_decl_e_line   = 0
	s.focused            = false
	s.ide                = {ac_dismissed_pos = -1, cmd_jump_offset = -1}
}

@(private = "file")
_ensure_buf_capacity :: proc(buf: ^[]byte, min_bytes: int, min_cap: int = STUDIO_MIN_BUF_CAP) {
	if buf == nil do return
	needed := max(min_bytes + 4096, min_cap, 1024)
	if len(buf^) >= needed do return
	new_cap := max(len(buf^) * 2, needed, min_cap)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	new_buf := make([]byte, new_cap)
	if len(buf^) > 0 {
		old_str := widgets.buf_str(buf^)
		n := min(len(old_str), new_cap - 1)
		copy(new_buf[:n], old_str[:n])
		new_buf[n] = 0
		delete(buf^)
	}
	buf^ = new_buf
	context.allocator = prev_alloc
}

// Detects whether an Odin source file uses leading hard `\t` characters for indentation.
detect_odin_hard_tabs :: proc(src: string) -> bool {
	line_start := true
	for i := 0; i < len(src); i += 1 {
		b := src[i]
		if line_start {
			if b == '\t' do return true
			if b != ' ' && b != '\r' && b != '\n' {
				line_start = false
			}
		}
		if b == '\n' {
			line_start = true
		}
	}
	return false
}

// Restores leading `\t` hard tabs on save when `uses_tabs` is true, without corrupting
// lines inside raw backtick multiline string literals.
format_studio_buffer_for_disk :: proc(buf_str: string, uses_tabs: bool, allocator := context.temp_allocator) -> string {
	if !uses_tabs || len(buf_str) == 0 do return buf_str
	sb := strings.builder_make(0, len(buf_str), allocator)
	i := 0
	in_raw_str := false
	block_comment_depth := 0
	for i < len(buf_str) {
		line_end := i
		for line_end < len(buf_str) && buf_str[line_end] != '\n' {
			line_end += 1
		}
		line := buf_str[i:line_end]
		if in_raw_str || block_comment_depth > 0 {
			strings.write_string(&sb, line)
		} else {
			k := 0
			for k + 4 <= len(line) && line[k:k + 4] == "    " {
				strings.write_byte(&sb, '\t')
				k += 4
			}
			strings.write_string(&sb, line[k:])
		}
		if line_end < len(buf_str) && buf_str[line_end] == '\n' {
			strings.write_byte(&sb, '\n')
		}
		// Advance lexical state to know whether the next line begins inside a raw backtick literal.
		j := 0
		in_dquote := false
		in_squote := false
		for j < len(line) {
			ch := line[j]
			if in_raw_str {
				if ch == '`' do in_raw_str = false
				j += 1
				continue
			}
			if block_comment_depth > 0 {
				if ch == '/' && j + 1 < len(line) && line[j + 1] == '*' {
					block_comment_depth += 1
					j += 2
					continue
				}
				if ch == '*' && j + 1 < len(line) && line[j + 1] == '/' {
					block_comment_depth -= 1
					j += 2
					continue
				}
				j += 1
				continue
			}
			if in_dquote {
				if ch == '\\' && j + 1 < len(line) {
					j += 2
					continue
				}
				if ch == '"' do in_dquote = false
				j += 1
				continue
			}
			if in_squote {
				if ch == '\\' && j + 1 < len(line) {
					j += 2
					continue
				}
				if ch == '\'' do in_squote = false
				j += 1
				continue
			}
			if ch == '/' && j + 1 < len(line) {
				if line[j + 1] == '/' do break
				if line[j + 1] == '*' {
					block_comment_depth += 1
					j += 2
					continue
				}
			}
			if ch == '`' {
				in_raw_str = true
			} else if ch == '"' {
				in_dquote = true
			} else if ch == '\'' {
				in_squote = true
			}
			j += 1
		}
		i = line_end + 1
	}
	return strings.to_string(sb)
}

@(private = "file")
_copy_to_c_buf_grow :: proc(dst: ^[]byte, text: string, min_cap: int = STUDIO_MIN_BUF_CAP) {
	// Normalize `\t` to 4 spaces so `im.CalcTextSize` sub-pixel syntax overlay matches `InputTextMultiline` 1:1!
	// Disk writes convert leading 4-space indentation back to `\t` when `uses_tabs` is set.
	norm, _ := strings.replace_all(text, "\t", "    ", context.temp_allocator)
	clean, _ := strings.replace_all(norm, "\r\n", "\n", context.temp_allocator)
	_ensure_buf_capacity(dst, len(clean) + 1, min_cap)
	widgets.buf_set(dst^, clean)
}

@(private = "file")
_c_buf_string :: #force_inline proc(buf: []byte) -> string {
	return widgets.buf_str(buf)
}

@(private = "file")
_norm_slashes_alloc :: proc(s: string, allocator: mem.Allocator) -> string {
	res, was_alloc := strings.replace_all(s, "\\", "/", allocator)
	if !was_alloc {
		return strings.clone(s, allocator)
	}
	return res
}

@(private = "file")
_sync_dirty_checker_overlays :: proc() {
	list := make([dynamic]Dirty_File_Overlay, 0, len(_studio.tabs), context.temp_allocator)
	for &t in _studio.tabs {
		if !t.dirty || t.abs_path == "" do continue
		append(&list, Dirty_File_Overlay{
			abs_path = t.abs_path,
			code     = _c_buf_string(t.buf),
			is_bodin = strings.has_suffix(strings.to_lower(t.abs_path, context.temp_allocator), ".bodin"),
		})
	}
	set_checker_dirty_overlays(list[:])
}

@(private = "file")
_proc_sig_fingerprint :: proc(
	name:      string,
	params:    []Parsed_Proc_Param,
	results:   []Parsed_Proc_Param,
	allocator := context.temp_allocator,
) -> string {
	sb := strings.builder_make(0, 128, allocator)
	strings.write_string(&sb, name)
	strings.write_byte(&sb, '(')
	for pr, pi in params {
		if pi > 0 do strings.write_byte(&sb, ',')
		if pr.is_ref do strings.write_byte(&sb, '^')
		strings.write_string(&sb, pr.name)
		strings.write_byte(&sb, ':')
		strings.write_string(&sb, pr.type_expr)
	}
	strings.write_string(&sb, ")->(")
	for rs, ri in results {
		if ri > 0 do strings.write_byte(&sb, ',')
		if rs.is_ref do strings.write_byte(&sb, '^')
		strings.write_string(&sb, rs.name)
		strings.write_byte(&sb, ':')
		strings.write_string(&sb, rs.type_expr)
	}
	strings.write_byte(&sb, ')')
	return strings.to_string(sb)
}

@(private = "file")
_push_scoped_checker_overlays :: proc(spliced_backing: string = "") {
	list := make([dynamic]Dirty_File_Overlay, 0, len(_studio.tabs) + len(_scoped.refactor_files) + 1, context.temp_allocator)
	seen := make(map[string]bool, 16, context.temp_allocator)

	if spliced_backing != "" && _scoped.backing_file_abs != "" {
		norm_b := resolve_workspace_path(_scoped.backing_file_abs, context.temp_allocator)
		append(&list, Dirty_File_Overlay{
			abs_path = norm_b,
			code     = spliced_backing,
			is_bodin = strings.has_suffix(strings.to_lower(norm_b, context.temp_allocator), ".bodin"),
		})
		seen[strings.to_lower(norm_b, context.temp_allocator)] = true
	}
	if _scoped.refactor_active {
		for &rf in _scoped.refactor_files {
			if rf.file_abs == "" do continue
			norm_r := resolve_workspace_path(rf.file_abs, context.temp_allocator)
			r_key := strings.to_lower(norm_r, context.temp_allocator)
			if seen[r_key] do continue
			append(&list, Dirty_File_Overlay{
				abs_path = norm_r,
				code     = _c_buf_string(rf.buf),
				is_bodin = rf.is_bodin,
			})
			seen[r_key] = true
		}
	}
	for &t in _studio.tabs {
		if !t.dirty || t.abs_path == "" do continue
		t_key := strings.to_lower(t.abs_path, context.temp_allocator)
		if seen[t_key] do continue
		append(&list, Dirty_File_Overlay{
			abs_path = t.abs_path,
			code     = _c_buf_string(t.buf),
			is_bodin = strings.has_suffix(strings.to_lower(t.abs_path, context.temp_allocator), ".bodin"),
		})
		seen[t_key] = true
	}
	set_checker_dirty_overlays(list[:])
}

@(private = "file")
_notify_scoped_popup_edited :: proc(force_compiler_now: bool = false) {
	if _scoped.is_snippet_preview do return
	buf_str := _c_buf_string(_scoped.buf)
	if _scoped.is_graph_node {
		_notify_buffer_edited(buf_str, !_scoped.is_full_decl, "haati/hot_scripts", force_compiler_now)
		return
	}
	if _scoped.is_full_decl && _scoped.full_file_cache != "" && _scoped.orig_proc_name != "" {
		if spliced, ok := splice_full_odin_procedure_decl(_scoped.full_file_cache, _scoped.orig_proc_name, buf_str, context.temp_allocator); ok {
			_push_scoped_checker_overlays(spliced)
			submit_async_check(spliced, false, _scoped.backing_pkg_dir, force_compiler_now, _scoped.backing_file_abs)
			submit_async_autocomplete_index(spliced, false, _scoped.backing_pkg_dir != "" ? _scoped.backing_pkg_dir : "haati/hot_scripts")
			return
		}
		_push_scoped_checker_overlays("")
		submit_async_check(buf_str, false, _scoped.backing_pkg_dir, force_compiler_now, _scoped.backing_file_abs)
		submit_async_autocomplete_index(buf_str, false, _scoped.backing_pkg_dir != "" ? _scoped.backing_pkg_dir : "haati/hot_scripts")
		return
	}
	_notify_buffer_edited(buf_str, true, _scoped.backing_pkg_dir, force_compiler_now, _scoped.backing_file_abs)
}

@(private = "file")
_notify_buffer_edited :: proc(src: string, is_scoped: bool, pkg_dir: string, force_compiler_now: bool = false, file_abs: string = "") {
	resolved_file := file_abs
	if !is_scoped {
		_studio.dirty_tabs_rev += 1
		if resolved_file == "" && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			resolved_file = _studio.tabs[_studio.active_tab].abs_path
		}
		_sync_dirty_checker_overlays()
	}
	submit_async_check(src, is_scoped, pkg_dir, force_compiler_now, resolved_file)
	ac_pkg := is_scoped && pkg_dir == "" ? "haati/hot_scripts" : pkg_dir
	submit_async_autocomplete_index(src, is_scoped, ac_pkg)
}

// Resolves a workspace script/file path against active project, repo_root, and haati/ using forward slashes.
resolve_workspace_path :: proc(abs_or_rel_path: string, allocator := context.temp_allocator) -> string {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	resolved := abs_or_rel_path
	if !filepath.is_abs(resolved) || !os.exists(resolved) {
		proj_root := engine.active_project_root()
		proj_cand := ""
		if proj_root != "" {
			proj_cand, _ = filepath.join({proj_root, abs_or_rel_path}, context.temp_allocator)
		}
		cand1, _ := filepath.join({repo_root, abs_or_rel_path}, context.temp_allocator)
		cand2, _ := filepath.join({repo_root, "haati", abs_or_rel_path}, context.temp_allocator)
		if proj_cand != "" && os.exists(proj_cand) {
			resolved = proj_cand
		} else if os.exists(cand1) {
			resolved = cand1
		} else if os.exists(cand2) {
			resolved = cand2
		} else if !filepath.is_abs(resolved) && !os.exists(resolved) {
			resolved = proj_cand != "" ? proj_cand : cand1
		}
	}
	return _norm_slashes_alloc(resolved, allocator)
}

// Finds a registered @(hot_proc) entry by exact name.
resolve_hot_proc_info :: proc(proc_name: string) -> (entry: engine.Hot_Proc_Entry, ok: bool) {
	if proc_name == "" do return {}, false
	for he in engine.hot_proc_entries() {
		if he.name == proc_name do return he, true
	}
	return {}, false
}

@(private = "file")
_infer_pkg_dir :: proc(abs_path: string, allocator := context.temp_allocator) -> string {
	norm := _norm_slashes_alloc(abs_path, context.temp_allocator)
	if strings.has_suffix(norm, ".bodin") || strings.has_suffix(norm, ".mhgraph") {
		return ""
	}
	if engine.has_active_project() {
		proj_root := _norm_slashes_alloc(engine.active_project_root(), context.temp_allocator)
		proj_root = strings.trim_right(proj_root, "/")
		proj_prefix := strings.concatenate({proj_root, "/"}, context.temp_allocator)
		if len(norm) >= len(proj_prefix) && strings.equal_fold(norm[:len(proj_prefix)], proj_prefix) {
			prev_alloc := context.allocator
			context.allocator = context.temp_allocator
			dir := filepath.dir(norm)
			context.allocator = prev_alloc
			return _norm_slashes_alloc(dir, allocator)
		}
	}
	if idx := strings.index(norm, "haati/"); idx >= 0 {
		prev_alloc := context.allocator
		context.allocator = context.temp_allocator
		dir := filepath.dir(norm[idx:])
		context.allocator = prev_alloc
		return _norm_slashes_alloc(dir, allocator)
	}
	if idx := strings.index(norm, "plugins/"); idx >= 0 {
		rel := norm[idx + len("plugins/"):]
		prev_alloc := context.allocator
		context.allocator = context.temp_allocator
		dir := filepath.dir(rel)
		context.allocator = prev_alloc
		dnorm := _norm_slashes_alloc(dir, context.temp_allocator)
		return fmt.aprintf("haati/packages/%s", dnorm, allocator = allocator)
	}
	if filepath.is_abs(norm) {
		prev_alloc := context.allocator
		context.allocator = context.temp_allocator
		dir := filepath.dir(norm)
		context.allocator = prev_alloc
		return _norm_slashes_alloc(dir, allocator)
	}
	return ""
}

// =============================================================================
// Public Openers: Scoped Node Popup, Scoped `.odin` Procedure Popup, & Full File
// =============================================================================

open_scoped_node_popup :: proc(
	node_uid:         int,
	node_title:       string,
	signature_banner: string,
	pins:             []Scoped_Pin_Badge,
	initial_body:     string,
	commit_cb:        Scoped_Node_Commit_Fn,
	user_ptr:         rawptr = nil,
	is_full_decl:     bool = false,
	full_commit_cb:   Scoped_Full_Node_Commit_Fn = nil,
	dock_split_cb:    Scoped_Dock_Split_Fn = nil,
	dock_user_ptr:    rawptr = nil,
) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_clear_scoped_strings()

	_scoped.open             = true
	_scoped.just_opened      = true
	_scoped.is_graph_node    = true
	_scoped.is_full_decl     = is_full_decl
	_scoped.node_uid         = node_uid
	_scoped.title            = strings.clone(node_title)
	_scoped.signature_banner = strings.clone(signature_banner)
	_scoped.commit_cb        = commit_cb
	_scoped.commit_user_ptr  = user_ptr
	_scoped.full_commit_cb   = full_commit_cb
	_scoped.dock_split_cb    = dock_split_cb
	_scoped.dock_user_ptr    = dock_user_ptr
	_scoped.dirty            = false

	for pin in pins {
		append(&_scoped.pins, Scoped_Pin_Badge{
			name      = strings.clone(pin.name),
			odin_type = strings.clone(pin.odin_type),
			pass_mode = pin.pass_mode,
			is_output = pin.is_output,
		})
	}

	_copy_to_c_buf_grow(&_scoped.buf, initial_body, SCOPED_MIN_BUF_CAP)
	body_str := _c_buf_string(_scoped.buf)
	code_undo_reset(&_scoped.undo, body_str, 0)
	_notify_scoped_popup_edited(false)
}

open_scoped_proc_popup :: proc(
	title:           string,
	abs_or_rel_file: string,
	proc_name:       string,
	clone_cb:        Scoped_Clone_To_Bodin_Fn = nil,
	clone_user_ptr:  rawptr = nil,
) -> bool {
	resolved := resolve_workspace_path(abs_or_rel_file, context.temp_allocator)
	src_str, has_open := get_open_tab_text(resolved, context.temp_allocator)
	if !has_open {
		raw, rerr := os.read_entire_file(resolved, context.temp_allocator)
		if rerr != nil do return false
		src_str = string(raw)
	}

	sliced, ok := extract_full_odin_procedure_decl(src_str, proc_name, context.temp_allocator)
	if !ok {
		open_file_in_studio(resolved)
		wnd.open("odin_micro_studio")
		return true
	}
	defer destroy_proc_full_decl_slice(&sliced, context.temp_allocator)

	pkg_dir := _infer_pkg_dir(resolved, context.temp_allocator)
	is_ro := is_protected_readonly_script_path(resolved)
	{
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		_clear_scoped_strings()
		_scoped.open              = true
		_scoped.just_opened       = true
		_scoped.is_graph_node     = false
		_scoped.is_full_decl      = true
		_scoped.read_only         = is_ro
		_scoped.clone_cb          = clone_cb
		_scoped.clone_user_ptr    = clone_user_ptr
		_scoped.title             = strings.clone(title)
		_scoped.signature_banner  = strings.clone(sliced.proc_name)
		_scoped.backing_file_abs  = strings.clone(resolved)
		_scoped.backing_pkg_dir   = strings.clone(pkg_dir)
		_scoped.backing_proc_name = strings.clone(proc_name)
		_scoped.orig_proc_name    = strings.clone(sliced.proc_name)
		_scoped.orig_sig_key      = strings.clone(_proc_sig_fingerprint(sliced.proc_name, sliced.params[:], sliced.results[:], context.temp_allocator))
		_scoped.orig_decl_s_line  = sliced.decl_start_line
		_scoped.full_file_cache   = strings.clone(src_str)
		_scoped.dirty             = false
		context.allocator = prev_a
	}

	_copy_to_c_buf_grow(&_scoped.buf, sliced.full_decl_text, SCOPED_MIN_BUF_CAP)
	body_str := _c_buf_string(_scoped.buf)
	code_undo_reset(&_scoped.undo, body_str, 0)
	if !is_ro {
		_notify_scoped_popup_edited(false)
	}
	return true
}

// Opens a built-in read-only Odin snippet preview ("you can look and copy, cannot edit in place")
// with an optional clone callback to convert it into an editable Odin BP_Node / .bodin proc.
open_readonly_snippet_popup :: proc(
	title:          string,
	snippet_code:   string,
	clone_cb:       Scoped_Clone_To_Bodin_Fn = nil,
	clone_user_ptr: rawptr = nil,
) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	_clear_scoped_strings()

	_scoped.open               = true
	_scoped.just_opened        = true
	_scoped.read_only          = true
	_scoped.is_snippet_preview = true
	_scoped.is_full_decl       = true
	_scoped.clone_cb           = clone_cb
	_scoped.clone_user_ptr     = clone_user_ptr
	_scoped.title              = strings.clone(title)
	_scoped.signature_banner   = strings.clone(title)
	_scoped.dirty              = false

	_copy_to_c_buf_grow(&_scoped.buf, snippet_code, SCOPED_MIN_BUF_CAP)
	body_str := _c_buf_string(_scoped.buf)
	code_undo_reset(&_scoped.undo, body_str, 0)
}

open_file_in_studio :: proc(abs_or_rel_path: string, jump_line: int = 0) -> bool {
	_ensure_zoom_init()
	norm_abs := resolve_workspace_path(abs_or_rel_path, context.temp_allocator)

	for &t, idx in _studio.tabs {
		if t.abs_path == norm_abs {
			was_active := (_studio.active_tab == idx)
			_studio.active_tab = idx
			_studio.request_tab_select = idx
			if jump_line > 0 {
				_jump_to_tab_line(&t, jump_line)
			}
			if !was_active {
				if im.GetCurrentContext() != nil do im.ClearActiveID()
				_notify_buffer_edited(_c_buf_string(t.buf), false, t.pkg_dir, false, t.abs_path)
			}
			return true
		}
	}

	raw, rerr := os.read_entire_file(norm_abs, context.temp_allocator)
	if rerr != nil do return false

	pkg_dir := _infer_pkg_dir(norm_abs, context.temp_allocator)
	base_name := filepath.base(norm_abs)
	paired_bodin_path := ""
	lo_abs := strings.to_lower(norm_abs, context.temp_allocator)
	if strings.has_suffix(lo_abs, ".odin") && !strings.has_suffix(lo_abs, "_mhgraph_generated.odin") {
		cand := fmt.tprintf("%s.bodin", norm_abs[:len(norm_abs) - 5])
		if os.exists(cand) {
			paired_bodin_path = cand
		}
	}

	raw_str := string(raw)
	uses_tabs := detect_odin_hard_tabs(raw_str)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	buf: []byte
	_copy_to_c_buf_grow(&buf, raw_str, STUDIO_MIN_BUF_CAP)
	s := _c_buf_string(buf)
	tab_uid := max(_studio.next_tab_uid, 1)
	_studio.next_tab_uid = tab_uid + 1
	new_tab := _Tab_Doc{
		uid            = tab_uid,
		title          = strings.clone(base_name),
		abs_path       = strings.clone(norm_abs),
		pkg_dir        = strings.clone(pkg_dir),
		paired_bodin   = paired_bodin_path != "" ? strings.clone(paired_bodin_path) : "",
		paired_checked = true,
		buf            = buf,
		dirty          = false,
		uses_tabs      = uses_tabs,
		scroll_line    = jump_line,
	}
	code_undo_reset(&new_tab.undo, s, 0)
	append(&_studio.tabs, new_tab)
	_studio.active_tab = len(_studio.tabs) - 1
	_studio.request_tab_select = _studio.active_tab
	if im.GetCurrentContext() != nil do im.ClearActiveID()
	_clear_ide_pending_restore(&_studio.ide)
	_free_ide_surface_cache(&_studio.ide)
	_studio.ide = {ac_dismissed_pos = -1, cmd_jump_offset = -1}
	if jump_line > 0 {
		_jump_to_tab_line(&_studio.tabs[_studio.active_tab], jump_line)
	}
	_notify_buffer_edited(s, false, pkg_dir, false, _studio.tabs[_studio.active_tab].abs_path)
	return true
}

@(private = "file")
_Dirty_Tab_Snapshot :: struct {
	abs_path:  string,
	content:   string,
	uses_tabs: bool,
}

// Serializes raw unsaved Code Studio buffers into compact JSON for the Watchdog RAM Vault.
export_dirty_tabs_json :: proc(allocator := context.temp_allocator) -> []byte {
	dirty_list := make([dynamic]_Dirty_Tab_Snapshot, 0, len(_studio.tabs), context.temp_allocator)
	for &t in _studio.tabs {
		if !t.dirty || t.abs_path == "" do continue
		append(&dirty_list, _Dirty_Tab_Snapshot{
			abs_path  = t.abs_path,
			content   = _c_buf_string(t.buf),
			uses_tabs = t.uses_tabs,
		})
	}
	if len(dirty_list) == 0 do return nil
	b, err := json.marshal(dirty_list[:], {}, allocator)
	if err != nil do return nil
	return b
}

// Restores unsaved Code Studio buffers recovered from the Watchdog Kernel RAM Vault as live dirty tabs.
restore_dirty_tabs_json :: proc(raw_json: []byte) -> int {
	if len(raw_json) == 0 do return 0
	snaps: []_Dirty_Tab_Snapshot
	if json.unmarshal(raw_json, &snaps, allocator = context.temp_allocator) != nil || len(snaps) == 0 {
		return 0
	}
	restored := 0
	now_t := im.GetCurrentContext() != nil ? im.GetTime() : 0.0
	for s in snaps {
		if s.abs_path == "" do continue
		if open_file_in_studio(s.abs_path, 1) {
			norm_abs := resolve_workspace_path(s.abs_path, context.temp_allocator)
			for &t in _studio.tabs {
				if strings.equal_fold(t.abs_path, norm_abs) {
					t.uses_tabs = s.uses_tabs
					_copy_to_c_buf_grow(&t.buf, s.content, STUDIO_MIN_BUF_CAP)
					t.dirty = true
					cur := _c_buf_string(t.buf)
					code_undo_record_edit(&t.undo, cur, 0, now_t, true)
					restored += 1
					break
				}
			}
		}
	}
	if restored > 0 {
		_studio.dirty_tabs_rev += 1
		_sync_dirty_checker_overlays()
	}
	return restored
}

// Returns an explicit red `UNSAFE:` hover explanation for low-level Odin pointer/memory primitives.
odin_ident_unsafe_warning :: proc(ident: string) -> cstring {
	switch ident {
	case "rawptr", "uintptr":
		return "Untyped memory address bypassing Odin type & bounds checks. Dereferencing nil (< 0x10000), freed memory, or casting to a mismatched struct size causes access violations or silent heap corruption (0xC0000374) across the host editor."
	case "transmute":
		return "Reinterprets raw bit patterns with zero runtime validation. Transmuting mismatched sizes, slice headers, or integers to pointers can corrupt memory or fault on dereference."
	case "raw_data":
		return "Extracts an unguarded base multi-pointer without length bounds. Writing past len() corrupts adjacent heap allocations."
	case "ptr_offset", "ptr_add", "ptr_sub":
		return "Unchecked pointer arithmetic. Offsetting outside an allocation's bounds reads/writes arbitrary heap memory with no bounds panic."
	case "free", "free_all":
		return "Manual deallocation. Freeing memory while another variable, slice, or component holds a pointer to it creates a use-after-free crash."
	case "mem_copy", "mem_zero", "copy", "volatile_store":
		return "Raw memory mutation. Mismatched byte sizes or unmapped destination pointers bypass bounds checks and can overwrite engine/Vulkan state."
	}
	return nil
}

// =============================================================================
// Smart IDE Callback (`ImGuiInputTextCallback`): Autocomplete, Auto-Indent,
// Comment Toggle (`Ctrl+/`), Line Duplicate (`Ctrl+D`), Outdent (`Shift+Tab`)
// =============================================================================

@(private = "file")
_find_matching_bracket :: proc(src: string, pos: int) -> (p1, p2: int, ok: bool) {
	n := len(src)
	if n == 0 do return 0, 0, false

	check_at :: proc(s: string, idx: int) -> (open_c, close_c: byte, dir: int, valid: bool) {
		if idx < 0 || idx >= len(s) do return 0, 0, 0, false
		switch s[idx] {
		case '{': return '{', '}', +1, true
		case '(': return '(', ')', +1, true
		case '[': return '[', ']', +1, true
		case '}': return '{', '}', -1, true
		case ')': return '(', ')', -1, true
		case ']': return '[', ']', -1, true
		}
		return 0, 0, 0, false
	}

	idx := clamp(pos, 0, n - 1)
	oc, cc, dir, valid := check_at(src, idx)
	if !valid && pos > 0 {
		idx = clamp(pos - 1, 0, n - 1)
		oc, cc, dir, valid = check_at(src, idx)
	}
	if !valid do return 0, 0, false

	depth := 0
	i := idx
	for i >= 0 && i < n {
		ch := src[i]
		if ch == oc do depth += dir
		else if ch == cc do depth -= dir
		if depth == 0 {
			return idx, i, true
		}
		i += dir
	}
	return 0, 0, false
}

@(private = "file")
_line_bounds_at :: proc(s: string, offset: int) -> (ls, le: int) {
	pos := clamp(offset, 0, len(s))
	ls = pos
	for ls > 0 && s[ls - 1] != '\n' {
		ls -= 1
	}
	le = pos
	for le < len(s) && s[le] != '\n' {
		le += 1
	}
	return ls, le
}

@(private = "file")
_code_input_callback :: proc "c" (data: ^im.InputTextCallbackData) -> i32 {
	context = runtime.default_context()
	context.assertion_failure_proc = crash_journal.assertion_failure
	if data == nil || data.UserData == nil do return 0
	ide := cast(^_Surface_IDE_State)data.UserData

	if .CallbackResize in data.EventFlag {
		if ide.active_buf != nil {
			_ensure_buf_capacity(ide.active_buf, int(data.BufSize) + 4096, STUDIO_MIN_BUF_CAP)
			if int(data.BufTextLen) >= 0 && int(data.BufTextLen) < len(ide.active_buf^) {
				ide.active_buf^[data.BufTextLen] = 0
			}
			data.Buf     = cstring(raw_data(ide.active_buf^))
			data.BufSize = i32(len(ide.active_buf^))
		}
		return 0
	}

	// 1. Character Filter (`Enter` accepts autocomplete when open, or triggers Smart Auto-Indent!)
	if .CallbackCharFilter in data.EventFlag {
		if ide.read_only_surface {
			data.EventChar = 0
			return 1
		}
		if data.EventChar == '\n' || data.EventChar == '\r' {
			if ide.ac_open && ide.ac_accept_len > 0 {
				ide.ac_pending_accept   = true
				ide.next_edit_immediate = true
				data.EventChar = 0
				return 1
			}
			ide.cmd_auto_indent = true
		} else if data.EventChar == '}' {
			// Leave normal '}' insertion; auto-indent handles opening `{` cleanly
		}
		return 0
	}

	// 2. `Tab` Key (`CallbackCompletion`)
	if .CallbackCompletion in data.EventFlag {
		if ide.read_only_surface do return 0
		ide.next_edit_immediate = true
		if ide.ac_open && ide.ac_accept_len > 0 {
			ide.ac_pending_accept = true
		} else if ide.cmd_outdent_tab {
			ide.cmd_outdent_tab = false
			if data.Buf != nil && data.BufTextLen > 0 {
				raw_ptr := cast([^]byte)data.Buf
				s := string(raw_ptr[:data.BufTextLen])
				ls, _ := _line_bounds_at(s, int(data.CursorPos))
				spaces := 0
				for spaces < 4 && ls + spaces < len(s) && s[ls + spaces] == ' ' {
					spaces += 1
				}
				if spaces > 0 {
					im.InputTextCallbackData_DeleteChars(data, i32(ls), i32(spaces))
				}
			}
		} else {
			im.InputTextCallbackData_InsertChars(data, data.CursorPos, "    ")
		}
		return 0
	}

	// 3. Per-Frame State Sync & Pending Command Execution (`CallbackAlways`)
	//    Note: `.CallbackHistory` is NEVER passed to `InputTextMultiline` (Dear ImGui forbids
	//    it on multiline inputs and asserts). Autocomplete Up/Down is handled cleanly via
	//    `ac_lock_cursor` below.
	if .CallbackAlways in data.EventFlag {
		// 3a. Restore caret/selection when autocomplete Up/Down consumed arrow keys this frame
		if ide.ac_lock_cursor {
			ide.ac_lock_cursor = false
			clamped := clamp(i32(ide.ac_locked_cpos), 0, data.BufTextLen)
			data.CursorPos      = clamped
			data.SelectionStart = clamp(i32(ide.ac_locked_sels), 0, data.BufTextLen)
			data.SelectionEnd   = clamp(i32(ide.ac_locked_sele), 0, data.BufTextLen)
		}

		// 3b. Sync 64-Step Undo/Redo buffer restoration cleanly into live `ImGuiInputTextState`
		if ide.cmd_restore_active {
			if data.BufTextLen > 0 {
				im.InputTextCallbackData_DeleteChars(data, 0, data.BufTextLen)
			}
			if len(ide.cmd_restore_text) > 0 {
				c_txt := strings.clone_to_cstring(ide.cmd_restore_text, context.temp_allocator)
				im.InputTextCallbackData_InsertChars(data, 0, c_txt)
			}
			cpos := clamp(i32(ide.cmd_restore_cursor), 0, data.BufTextLen)
			data.CursorPos       = cpos
			data.SelectionStart  = cpos
			data.SelectionEnd    = cpos
			ide.cmd_restore_applied = true
			ide.cmd_jump_offset     = -1
			_clear_ide_pending_restore(ide)
		}

		// 4a. Apply pending Autocomplete Accept (`Tab`, `Enter`, or mouse click on popup item)
		if ide.ac_pending_accept && ide.ac_accept_len > 0 {
			ide.ac_pending_accept    = false
			ide.next_edit_immediate  = true
			cur_cpos := clamp(data.CursorPos, 0, data.BufTextLen)
			data.CursorPos      = cur_cpos
			data.SelectionStart = cur_cpos
			data.SelectionEnd   = cur_cpos
			rep_s := clamp(i32(ide.ac_replace_start), 0, cur_cpos)
			del_n := cur_cpos - rep_s
			if del_n > 0 {
				im.InputTextCallbackData_DeleteChars(data, rep_s, del_n)
			}
			ide.ac_accept_text[min(ide.ac_accept_len, len(ide.ac_accept_text) - 1)] = 0
			im.InputTextCallbackData_InsertChars(data, rep_s, cstring(raw_data(ide.ac_accept_text[:])))
			new_cpos := clamp(rep_s + i32(ide.ac_accept_len), 0, data.BufTextLen)
			data.CursorPos           = new_cpos
			data.SelectionStart      = new_cpos
			data.SelectionEnd        = new_cpos
			ide.ac_open              = false
			ide.ac_popup_interacting = false
			ide.ac_popup_dragging    = false
			ide.ac_dismissed_pos     = int(new_cpos)
		}

		// 4a-bis. Context-menu Paste at saved caret / selection
		if ide.cmd_paste_pending {
			if len(ide.cmd_paste_text) > 0 {
				ide.next_edit_immediate = true
				s_lo := clamp(i32(min(ide.sel_start, ide.sel_end)), 0, data.BufTextLen)
				s_hi := clamp(i32(max(ide.sel_start, ide.sel_end)), 0, data.BufTextLen)
				if s_hi <= s_lo {
					s_lo = clamp(i32(ide.cursor_pos), 0, data.BufTextLen)
					s_hi = s_lo
				}
				if s_hi > s_lo {
					im.InputTextCallbackData_DeleteChars(data, s_lo, s_hi - s_lo)
				}
				clip := ide.cmd_paste_text
				if len(clip) > 0 {
					c_clip := strings.clone_to_cstring(clip, context.temp_allocator)
					im.InputTextCallbackData_InsertChars(data, s_lo, c_clip)
					new_p := clamp(s_lo + i32(len(clip)), 0, data.BufTextLen)
					data.CursorPos      = new_p
					data.SelectionStart = new_p
					data.SelectionEnd   = new_p
				}
			}
			_clear_ide_pending_paste(ide)
		}

		// 4b. Apply Smart Auto-Indent right after ImGui inserts `'\n'`!
		if ide.cmd_auto_indent {
			ide.cmd_auto_indent = false
			if data.Buf != nil && data.BufTextLen > 0 {
				cpos := int(data.CursorPos)
				raw_ptr := cast([^]byte)data.Buf
				s := string(raw_ptr[:data.BufTextLen])
				if cpos > 0 && cpos <= len(s) && s[cpos - 1] == '\n' {
					prev_ls, prev_le := _line_bounds_at(s, cpos - 1)
					indent_n := 0
					for prev_ls + indent_n < prev_le && s[prev_ls + indent_n] == ' ' {
						indent_n += 1
					}
					// Trim trailing spaces on previous line to check if it opened a block (`{`, `(`, `:`)
					trim_end := prev_le
					for trim_end > prev_ls && (s[trim_end - 1] == ' ' || s[trim_end - 1] == '\r') {
						trim_end -= 1
					}
					if trim_end > prev_ls {
						last_ch := s[trim_end - 1]
						if last_ch == '{' || last_ch == '(' || last_ch == ':' {
							indent_n += 4
						}
					}
					if indent_n > 0 {
						indent_n = min(indent_n, 64)
						var_spaces: [65]byte
						for i in 0 ..< indent_n do var_spaces[i] = ' '
						var_spaces[indent_n] = 0
						im.InputTextCallbackData_InsertChars(data, data.CursorPos, cstring(raw_data(var_spaces[:])))
					}
				}
			}
		}

		// 4c. `Ctrl + /` Toggle Line Comment (`// `)
		if ide.cmd_toggle_comment {
			ide.cmd_toggle_comment  = false
			ide.next_edit_immediate = true
			if data.Buf != nil && data.BufTextLen >= 0 {
				raw_ptr := cast([^]byte)data.Buf
				s := string(raw_ptr[:data.BufTextLen])
				ls, le := _line_bounds_at(s, int(data.CursorPos))
				first_non_ws := ls
				for first_non_ws < le && s[first_non_ws] == ' ' {
					first_non_ws += 1
				}
				if first_non_ws + 2 <= le && s[first_non_ws] == '/' && s[first_non_ws + 1] == '/' {
					del_cnt: i32 = (first_non_ws + 3 <= le && s[first_non_ws + 2] == ' ') ? 3 : 2
					im.InputTextCallbackData_DeleteChars(data, i32(first_non_ws), del_cnt)
				} else {
					im.InputTextCallbackData_InsertChars(data, i32(first_non_ws), "// ")
				}
			}
		}

		// 4d. `Ctrl + D` Duplicate Current Line
		if ide.cmd_dup_line {
			ide.cmd_dup_line        = false
			ide.next_edit_immediate = true
			if data.Buf != nil && data.BufTextLen >= 0 {
				raw_ptr := cast([^]byte)data.Buf
				s := string(raw_ptr[:data.BufTextLen])
				ls, le := _line_bounds_at(s, int(data.CursorPos))
				line_len := le - ls
				dup_slice := make([]byte, line_len + 2, context.temp_allocator)
				dup_slice[0] = '\n'
				if line_len > 0 {
					copy(dup_slice[1:1 + line_len], s[ls:le])
				}
				dup_slice[1 + line_len] = 0
				im.InputTextCallbackData_InsertChars(data, i32(le), cstring(raw_data(dup_slice)))
			}
		}

		// 4e. `Alt + Up / Down` Move Current Line
		if ide.cmd_move_line_dir != 0 {
			dir := ide.cmd_move_line_dir
			ide.cmd_move_line_dir   = 0
			ide.next_edit_immediate = true
			if data.Buf != nil && data.BufTextLen > 0 {
				raw_ptr := cast([^]byte)data.Buf
				s := string(raw_ptr[:data.BufTextLen])
				if moved, new_cpos, ok := move_line_in_source(s, int(data.CursorPos), dir, context.temp_allocator); ok {
					c_moved := strings.clone_to_cstring(moved, context.temp_allocator)
					im.InputTextCallbackData_DeleteChars(data, 0, data.BufTextLen)
					im.InputTextCallbackData_InsertChars(data, 0, c_moved)
					clamped := clamp(i32(new_cpos), 0, data.BufTextLen)
					data.CursorPos      = clamped
					data.SelectionStart = clamped
					data.SelectionEnd   = clamped
				}
			}
		}

		// 4f. Jump to byte offset (Find Next / Go to Line / Symbol Outline)
		if ide.cmd_jump_offset >= 0 {
			target := clamp(i32(ide.cmd_jump_offset), 0, data.BufTextLen)
			data.CursorPos      = target
			data.SelectionStart = target
			data.SelectionEnd   = target
			ide.cmd_jump_offset = -1
		}

		ide.cursor_pos = int(data.CursorPos)
		ide.sel_start  = int(data.SelectionStart)
		ide.sel_end    = int(data.SelectionEnd)
	}
	return 0
}

// =============================================================================
// Inline Go-to-Line Bar (`Ctrl+G`)
// =============================================================================

@(private = "file")
_draw_goto_line_bar :: proc(ide: ^_Surface_IDE_State, buf: []byte, scroll_to_line: ^int = nil) {
	if !ide.goto_open do return

	p          := thm.palette()
	src        := _c_buf_string(buf)
	ls_starts  := compute_line_starts(src, context.temp_allocator)
	max_lines  := max(len(ls_starts), 1)

	im.PushStyleColorImVec4(.ChildBg, p.is_light ? thm.lerp_col(p.bg_canvas, p.accent, 0.08) : thm.lerp_col(p.bg_canvas, p.accent, 0.14))
	if im.BeginChild("##ide_goto_bar", {0, 32}, {.Borders}) {
		im.TextColored(p.accent, "%s", fmt.ctprintf("%s Go to Line (1..%d):", icons.ICON_MD_ARROW_RIGHT, max_lines))
		im.SameLine()
		if ide.goto_focus_next {
			im.SetKeyboardFocusHere()
			ide.goto_focus_next = false
		}
		im.SetNextItemWidth(110)
		enter_pressed := im.InputTextWithHint(
			"##ide_goto_num",
			"Line #...",
			cstring(raw_data(ide.goto_buf[:])),
			len(ide.goto_buf),
			{.CharsDecimal, .EnterReturnsTrue},
		)
		im.SameLine()
		if im.SmallButton("Jump") || enter_pressed {
			raw_num := strings.trim_space(_c_buf_string(ide.goto_buf[:]))
			if target_ln, ok := strconv.parse_int(raw_num); ok {
				clamped_ln := clamp(target_ln, 1, max_lines)
				ide.cmd_jump_offset = ls_starts[clamped_ln - 1]
				if scroll_to_line != nil {
					scroll_to_line^ = clamped_ln
				}
				ide.goto_open = false
			}
		}
		im.SameLine()
		if im.SmallButton(fmt.ctprintf("%s##close_goto", icons.ICON_MD_CLOSE)) {
			ide.goto_open = false
		}
		widgets.tooltip("Close Go to Line (Esc)")
	}
	im.EndChild()
	im.PopStyleColor()
}

// =============================================================================
// Inline Find & Replace Bar (`Ctrl+F`)
// =============================================================================

@(private = "file")
_ascii_eq_fold :: #force_inline proc(a, b: byte) -> bool {
	if a == b do return true
	la := (a >= 'A' && a <= 'Z') ? (a + 32) : a
	lb := (b >= 'A' && b <= 'Z') ? (b + 32) : b
	return la == lb
}

@(private = "file")
_matches_at :: #force_inline proc(src, q: string, off: int, case_sensitive: bool) -> bool {
	if len(q) == 0 || off < 0 || off + len(q) > len(src) do return false
	if case_sensitive {
		return src[off : off + len(q)] == q
	}
	for i in 0 ..< len(q) {
		if !_ascii_eq_fold(src[off + i], q[i]) do return false
	}
	return true
}

@(private = "file")
_find_next_match :: proc(src, q: string, from_off: int, case_sensitive: bool) -> (abs_idx: int, found: bool) {
	if len(q) == 0 || len(q) > len(src) do return -1, false
	if case_sensitive {
		sf := clamp(from_off, 0, len(src))
		if i := strings.index(src[sf:], q); i >= 0 do return sf + i, true
		if i := strings.index(src, q); i >= 0 do return i, true
		return -1, false
	}
	sf := clamp(from_off, 0, len(src))
	limit := len(src) - len(q)
	for i := sf; i <= limit; i += 1 {
		if _matches_at(src, q, i, false) do return i, true
	}
	for i := 0; i < min(sf, limit + 1); i += 1 {
		if _matches_at(src, q, i, false) do return i, true
	}
	return -1, false
}

@(private = "file")
_find_prev_match :: proc(src, q: string, before_off: int, case_sensitive: bool) -> (abs_idx: int, found: bool) {
	if len(q) == 0 || len(q) > len(src) do return -1, false
	limit := len(src) - len(q)
	sb := clamp(before_off - 1, -1, limit)
	for i := sb; i >= 0; i -= 1 {
		if _matches_at(src, q, i, case_sensitive) do return i, true
	}
	for i := limit; i > max(sb, -1); i -= 1 {
		if _matches_at(src, q, i, case_sensitive) do return i, true
	}
	return -1, false
}

@(private = "file")
_replace_all_matches :: proc(src, q, rep: string, case_sensitive: bool, allocator := context.temp_allocator) -> (out: string, count: int) {
	if len(q) == 0 do return src, 0
	if case_sensitive {
		res, _ := strings.replace_all(src, q, rep, allocator)
		return res, 1
	}
	sb := strings.builder_make(0, len(src) + 32, allocator)
	i := 0
	for i <= len(src) - len(q) {
		if _matches_at(src, q, i, false) {
			strings.write_string(&sb, rep)
			i += len(q)
			count += 1
		} else {
			strings.write_byte(&sb, src[i])
			i += 1
		}
	}
	if i < len(src) do strings.write_string(&sb, src[i:])
	return strings.to_string(sb), count
}

@(private = "file")
_line_num_at_offset :: proc(src: string, off: int) -> int {
	lim := clamp(off, 0, len(src))
	ln := 1
	for i in 0 ..< lim {
		if src[i] == '\n' do ln += 1
	}
	return ln
}

@(private = "file")
_draw_find_replace_bar :: proc(
	ide:            ^_Surface_IDE_State,
	buf:            ^[]byte,
	scroll_to_line: ^int             = nil,
	undo:           ^Code_Undo_Stack = nil,
) -> (modified: bool) {
	if !ide.find_open || buf == nil do return false

	p := thm.palette()
	im.PushStyleColorImVec4(.ChildBg, p.is_light ? thm.lerp_col(p.bg_canvas, p.accent, 0.08) : thm.lerp_col(p.bg_canvas, p.accent, 0.14))
	if im.BeginChild("##ide_find_bar", {0, 32}, {.Borders}) {
		im.TextColored(p.accent, icons.ICON_MD_SEARCH + " Find:")
		im.SameLine()
		if ide.find_focus_next {
			im.SetKeyboardFocusHere()
			ide.find_focus_next = false
			if ide.find_current_offset < 0 {
				ide.find_current_offset = ide.cursor_pos
			}
		}
		im.SetNextItemWidth(156)
		find_enter := im.InputTextWithHint("##ide_find_q", "Search text...", cstring(raw_data(ide.find_buf[:])), len(ide.find_buf), {.EnterReturnsTrue})

		src := _c_buf_string(buf^)
		q   := _c_buf_string(ide.find_buf[:])
		rep := _c_buf_string(ide.replace_buf[:])

		match_count := 0
		if len(q) > 0 && len(q) <= len(src) {
			scan_off := 0
			for scan_off <= len(src) - len(q) {
				if _matches_at(src, q, scan_off, ide.find_case_sensitive) {
					match_count += 1
					scan_off += len(q)
				} else {
					scan_off += 1
				}
			}
		}

		im.SameLine()
		im.PushStyleColorImVec4(.Button, ide.find_case_sensitive ? thm.with_alpha(p.accent, 0.30) : thm.with_alpha(p.text_muted, 0.12))
		if im.SmallButton("Aa##find_case") {
			ide.find_case_sensitive = !ide.find_case_sensitive
		}
		im.PopStyleColor()
		widgets.tooltip("Toggle Case-Sensitive Search")

		_select_find_hit :: proc(ide: ^_Surface_IDE_State, src: string, hit, qlen: int, scroll_to_line: ^int, keep_input_focus: bool) {
			ide.find_current_offset = hit
			ide.find_match_len      = qlen
			ide.cmd_jump_offset     = hit
			ln := _line_num_at_offset(src, hit)
			ide.cmd_jump_line = ln
			if scroll_to_line != nil {
				scroll_to_line^ = ln
			}
			_trigger_line_flash(ide, ln)
			if !keep_input_focus {
				ide.ac_refocus_input = true
			}
		}

		im.SameLine()
		if im.SmallButton("Prev##find_prev") && len(q) > 0 {
			before := ide.find_current_offset >= 0 ? ide.find_current_offset : ide.cursor_pos
			if hit, ok := _find_prev_match(src, q, before, ide.find_case_sensitive); ok {
				_select_find_hit(ide, src, hit, len(q), scroll_to_line, false)
			}
		}
		widgets.tooltip("Previous match")

		im.SameLine()
		click_next := im.SmallButton("Next##find_next")
		if (click_next || find_enter) && len(q) > 0 {
			search_from := ide.find_current_offset >= 0 ? (ide.find_current_offset + 1) : max(ide.cursor_pos, 0)
			if hit, ok := _find_next_match(src, q, search_from, ide.find_case_sensitive); ok {
				_select_find_hit(ide, src, hit, len(q), scroll_to_line, find_enter && !click_next)
			}
		}
		widgets.tooltip("Next match (Enter)")

		im.SameLine()
		im.TextDisabled("%s", fmt.ctprintf("(%d)", match_count))

		im.SameLine()
		im.TextDisabled("Replace:")
		im.SameLine()
		im.SetNextItemWidth(136)
		im.InputTextWithHint("##ide_rep_q", "With...", cstring(raw_data(ide.replace_buf[:])), len(ide.replace_buf))

		im.SameLine()
		if im.SmallButton("Replace##find_rep1") && len(q) > 0 && match_count > 0 {
			rep_pos := ide.find_current_offset
			if rep_pos < 0 || !_matches_at(src, q, rep_pos, ide.find_case_sensitive) {
				if hit, ok := _find_next_match(src, q, max(ide.cursor_pos, 0), ide.find_case_sensitive); ok {
					rep_pos = hit
				} else {
					rep_pos = -1
				}
			}
			if rep_pos >= 0 && rep_pos + len(q) <= len(src) {
				updated := strings.concatenate({src[:rep_pos], rep, src[rep_pos + len(q):]}, context.temp_allocator)
				after_pos := rep_pos + len(rep)
				if undo != nil {
					code_undo_record_edit(undo, updated, after_pos, im.GetTime(), true)
				}
				_arm_ide_restore(ide, updated, after_pos)
				if next_hit, nok := _find_next_match(updated, q, after_pos, ide.find_case_sensitive); nok {
					ide.find_current_offset = next_hit
					ide.find_match_len      = len(q)
					ln := _line_num_at_offset(updated, next_hit)
					ide.cmd_jump_line = ln
					if scroll_to_line != nil do scroll_to_line^ = ln
				} else {
					ide.find_current_offset = after_pos
					ide.find_match_len      = 0
				}
				ide.ac_refocus_input = true
				modified = true
			}
		}
		widgets.tooltip("Replace current match and advance to next")

		im.SameLine()
		if im.SmallButton("Replace All##find_rep_all") && len(q) > 0 && match_count > 0 {
			replaced, _ := _replace_all_matches(src, q, rep, ide.find_case_sensitive, context.temp_allocator)
			cpos := clamp(ide.cursor_pos, 0, len(replaced))
			if undo != nil {
				code_undo_record_edit(undo, replaced, cpos, im.GetTime(), true)
			}
			_arm_ide_restore(ide, replaced, cpos)
			ide.find_current_offset = cpos
			ide.ac_refocus_input    = true
			modified = true
		}
		widgets.tooltip("Replace all occurrences in this buffer")

		im.SameLine()
		if im.SmallButton(fmt.ctprintf("%s##close_find", icons.ICON_MD_CLOSE)) {
			ide.find_open = false
		}
		widgets.tooltip("Close Find & Replace (Esc)")
	}
	im.EndChild()
	im.PopStyleColor()
	return modified
}

// =============================================================================
// Compact Zoom Controls Pill (`Ctrl + MouseWheel` / `[-]` `100%` `[+]`)
// =============================================================================

@(private = "file")
_draw_zoom_pill_controls :: proc(id_suffix: cstring) {
	_ensure_zoom_init()
	im.TextDisabled("Zoom:")
	im.SameLine(0, 3)
	if im.SmallButton(fmt.ctprintf("-##zm_dn_%s", id_suffix)) {
		set_studio_code_zoom(_studio.code_zoom - CODE_ZOOM_STEP)
	}
	widgets.tooltip("Zoom Out (`Ctrl + MouseWheel Down` or `Ctrl + -`)")
	im.SameLine(0, 2)
	pct := int(math.round(_studio.code_zoom * 100.0))
	if im.SmallButton(fmt.ctprintf("%d%%##zm_rst_%s", pct, id_suffix)) {
		set_studio_code_zoom(1.0)
	}
	widgets.tooltip("Reset Code Zoom to 100% (`Ctrl + 0`)")
	im.SameLine(0, 2)
	if im.SmallButton(fmt.ctprintf("+##zm_up_%s", id_suffix)) {
		set_studio_code_zoom(_studio.code_zoom + CODE_ZOOM_STEP)
	}
	widgets.tooltip("Zoom In (`Ctrl + MouseWheel Up` or `Ctrl + =`)")
}

// =============================================================================
// Shared Syntax-Highlighted + Autocomplete + Zoomable Code Surface Renderer
// =============================================================================

Quick_Fix_Kind :: enum {
	Comment_Line,
	Remove_Line,
	Suppress_Unused_Var,
	Replace_Ident,
	Inject_Import,
	Open_Imports_Popup,
	Migrate_Legacy_Import,
	Migrate_All_Legacy_Imports,
}

Quick_Fix_Action :: struct {
	kind:        Quick_Fix_Kind,
	label:       string,
	old_ident:   string,
	replacement: string,
	spec_id:     string,
	target_line: int,
}

// Returns true when diagnostic `diag_file` applies to `active_file` (filtering out
// diagnostics emitted for sibling files in the same Odin package).
diagnostic_matches_active_file :: proc(diag_file, active_file: string) -> bool {
	df, _ := strings.replace_all(strings.trim_space(diag_file), "\\", "/", context.temp_allocator)
	af, _ := strings.replace_all(strings.trim_space(active_file), "\\", "/", context.temp_allocator)
	if df == "" || af == "" do return true
	if df == "in_ram_buffer.odin" || df == "<ram>" || strings.has_suffix(df, "/in_ram_buffer.odin") {
		return true
	}
	if strings.equal_fold(df, af) do return true

	has_slash_df := strings.index_byte(df, '/') >= 0
	has_slash_af := strings.index_byte(af, '/') >= 0
	if !has_slash_df || !has_slash_af {
		return strings.equal_fold(filepath.base(df), filepath.base(af))
	}
	if len(af) > len(df) + 1 && af[len(af) - len(df) - 1] == '/' && strings.equal_fold(af[len(af) - len(df):], df) {
		return true
	}
	if len(df) > len(af) + 1 && df[len(df) - len(af) - 1] == '/' && strings.equal_fold(df[len(df) - len(af):], af) {
		return true
	}
	return false
}

@(private = "file")
_line_slice_1based :: proc(src: string, line_1based: int) -> (line_start, line_end: int, line_text: string) {
	if line_1based <= 0 do return 0, 0, ""
	cur_line := 1
	ls := 0
	for i := 0; i <= len(src); i += 1 {
		if i == len(src) || src[i] == '\n' {
			if cur_line == line_1based {
				le := i
				if le > ls && src[le - 1] == '\r' do le -= 1
				return ls, le, src[ls:le]
			}
			cur_line += 1
			ls = i + 1
		}
	}
	return 0, 0, ""
}

@(private = "file")
_extract_first_quoted :: proc(s: string) -> string {
	for i := 0; i < len(s); i += 1 {
		q := s[i]
		if q != '\'' && q != '`' && q != '"' do continue
		for j := i + 1; j < len(s); j += 1 {
			if s[j] == q {
				return strings.trim_space(s[i + 1:j])
			}
		}
	}
	return ""
}

@(private = "file")
_extract_undeclared_ident :: proc(msg: string) -> string {
	msg_lo := strings.to_lower(msg, context.temp_allocator)
	start := -1
	for pat in ([2]string{"undeclared name:", "undeclared identifier:"}) {
		if idx := strings.index(msg_lo, pat); idx >= 0 {
			start = idx + len(pat)
			break
		}
	}
	if start < 0 do return _extract_first_quoted(msg)
	rest := strings.trim_left_space(msg[start:])
	if len(rest) > 0 && (rest[0] == '\'' || rest[0] == '`' || rest[0] == '"') {
		return _extract_first_quoted(rest)
	}
	end := 0
	for end < len(rest) {
		b := rest[end]
		is_id := (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
		if !is_id do break
		end += 1
	}
	return rest[:end]
}

@(private = "file")
_is_word_char :: #force_inline proc(b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// Generates deterministic, JetBrains-style Quick-Fix actions for a source line & diagnostic.
build_line_quick_fixes :: proc(src: string, line_1based: int, diag_msg: string, is_unused_import: bool, allocator := context.temp_allocator) -> []Quick_Fix_Action {
	if line_1based <= 0 do return nil
	_, _, line_text := _line_slice_1based(src, line_1based)
	trimmed := strings.trim_space(line_text)
	msg_lo  := strings.to_lower(diag_msg, context.temp_allocator)

	out := make([dynamic]Quick_Fix_Action, 0, 4, allocator)

	// 0. Legacy `"moonhug:..."` import migration
	if strings.contains(line_text, "\"moonhug:") {
		if q1 := strings.index(line_text, "\"moonhug:"); q1 >= 0 {
			if q2_rel := strings.index_byte(line_text[q1 + 1:], '"'); q2_rel > 0 {
				old_imp := line_text[q1 + 1 : q1 + 1 + q2_rel]
				if new_imp, mok := compute_haati_import_migration(old_imp, "", context.temp_allocator); mok {
					append(&out, Quick_Fix_Action{
						kind        = .Migrate_Legacy_Import,
						label       = fmt.aprintf("Migrate \"%s\" -> \"%s\"", old_imp, new_imp, allocator = allocator),
						old_ident   = strings.clone(old_imp, allocator),
						replacement = strings.clone(new_imp, allocator),
						target_line = line_1based,
					})
					if strings.contains(src, "moonhug:") {
						append(&out, Quick_Fix_Action{
							kind        = .Migrate_All_Legacy_Imports,
							label       = strings.clone("Migrate ALL legacy \"moonhug:\" imports -> \"haati:\" / \"project:\"", allocator),
							target_line = line_1based,
						})
					}
				}
			}
		}
	}

	// 1. Unused import line
	is_unused_imp_diag := is_unused_import || strings.contains(msg_lo, "imported and not used") || strings.contains(msg_lo, "unused import")
	if is_unused_imp_diag {
		if trimmed != "" && !strings.has_prefix(trimmed, "//") {
			append(&out, Quick_Fix_Action{
				kind        = .Comment_Line,
				label       = strings.clone("Comment out unused import", allocator),
				target_line = line_1based,
			})
		}
		if line_text != "" {
			append(&out, Quick_Fix_Action{
				kind        = .Remove_Line,
				label       = strings.clone("Remove unused import line", allocator),
				target_line = line_1based,
			})
		}
	} else if (strings.has_prefix(trimmed, "import ") || strings.contains(trimmed, "import \"")) && (strings.contains(msg_lo, "invalid path") || strings.contains(msg_lo, "cannot find package") || strings.contains(msg_lo, "import")) {
		// 2. Broken / invalid import path
		if !strings.has_prefix(trimmed, "//") {
			append(&out, Quick_Fix_Action{
				kind        = .Comment_Line,
				label       = strings.clone("Comment out broken import", allocator),
				target_line = line_1based,
			})
		}
		append(&out, Quick_Fix_Action{
			kind        = .Open_Imports_Popup,
			label       = strings.clone("Open + Import / Using Selector...", allocator),
			target_line = line_1based,
		})
	}

	// 3. Compiler `'did you mean ...'` typo fix
	if dym_i := strings.index(msg_lo, "did you mean"); dym_i >= 0 {
		sug := _extract_first_quoted(diag_msg[dym_i:])
		if sug != "" {
			before := diag_msg[:dym_i]
			old_tok := _extract_first_quoted(before)
			if old_tok == "" {
				old_tok = _extract_undeclared_ident(before)
			}
			append(&out, Quick_Fix_Action{
				kind        = .Replace_Ident,
				label       = strings.clone(fmt.tprintf("Replace with '%s'", sug), allocator),
				old_ident   = strings.clone(old_tok, allocator),
				replacement = strings.clone(sug, allocator),
				target_line = line_1based,
			})
		}
	}

	// 4. Undeclared package alias (`math`, `linalg`, `engine`, `hot`, `physics3d`, etc.)
	if strings.contains(msg_lo, "undeclared name:") || strings.contains(msg_lo, "undeclared identifier") {
		undec := _extract_undeclared_ident(diag_msg)
		if undec != "" {
			for spec in USING_SPACE_CATALOG {
				if spec.import_line == "" || strings.has_prefix(spec.id, "using_") do continue
				alias_match := spec.pkg_alias == undec || (undec == "input_mgr" && spec.id == "input_manager")
				if alias_match && !strings.contains(src, spec.import_line) {
					append(&out, Quick_Fix_Action{
						kind        = .Inject_Import,
						label       = strings.clone(fmt.tprintf("Import %s (%s)", spec.label, spec.import_line), allocator),
						replacement = strings.clone(spec.import_line, allocator),
						spec_id     = strings.clone(spec.id, allocator),
						target_line = line_1based,
					})
					break
				}
			}
		}
	}

	// 5. Unused local variable (`declared and not used`)
	if (strings.contains(msg_lo, "declared and not used") || strings.contains(msg_lo, "is not used")) && !strings.contains(msg_lo, "imported and not used") {
		var_name := _extract_first_quoted(diag_msg)
		if var_name == "" {
			if decl_i := strings.index(trimmed, ":="); decl_i > 0 {
				cand := strings.trim_space(trimmed[:decl_i])
				if len(cand) > 0 && _is_word_char(cand[0]) {
					end_c := 0
					for end_c < len(cand) && _is_word_char(cand[end_c]) do end_c += 1
					var_name = cand[:end_c]
				}
			}
		}
		if var_name != "" && var_name != "_" {
			append(&out, Quick_Fix_Action{
				kind        = .Suppress_Unused_Var,
				label       = strings.clone(fmt.tprintf("Suppress with '_ = %s'", var_name), allocator),
				replacement = strings.clone(var_name, allocator),
				target_line = line_1based,
			})
		}
	}

	return out[:]
}

@(private = "file")
_apply_quick_fix :: proc(src: string, act: Quick_Fix_Action) -> (updated: string, new_cursor: int, opened_imports: bool, ok: bool) {
	switch act.kind {
	case .Open_Imports_Popup:
		return "", 0, true, false
	case .Inject_Import:
		for spec in USING_SPACE_CATALOG {
			if spec.id == act.spec_id {
				if new_src, changed := _inject_using_space_into_full_file(src, spec, context.temp_allocator); changed {
					return new_src, min(len(new_src), 0), false, true
				}
			}
		}
		return "", 0, false, false
	case .Comment_Line:
		ls, le, line_txt := _line_slice_1based(src, act.target_line)
		if le <= ls do return "", 0, false, false
		indent_n := 0
		for indent_n < len(line_txt) && (line_txt[indent_n] == ' ' || line_txt[indent_n] == '\t') {
			indent_n += 1
		}
		rest := line_txt[indent_n:]
		if rest == "" || strings.has_prefix(rest, "//") do return "", 0, false, false
		rep := fmt.tprintf("%s// %s", line_txt[:indent_n], rest)
		out := strings.concatenate({src[:ls], rep, src[le:]}, context.temp_allocator)
		return out, ls + len(rep), false, true
	case .Remove_Line:
		ls, le, _ := _line_slice_1based(src, act.target_line)
		if le == 0 && ls == 0 && act.target_line > 1 do return "", 0, false, false
		del_s := ls
		del_e := le
		if del_e < len(src) && src[del_e] == '\r' do del_e += 1
		if del_e < len(src) && src[del_e] == '\n' {
			del_e += 1
		} else if del_s > 0 && src[del_s - 1] == '\n' {
			del_s -= 1
			if del_s > 0 && src[del_s - 1] == '\r' do del_s -= 1
		}
		out := strings.concatenate({src[:del_s], src[del_e:]}, context.temp_allocator)
		return out, min(del_s, len(out)), false, true
	case .Suppress_Unused_Var:
		_, le, line_txt := _line_slice_1based(src, act.target_line)
		if act.replacement == "" do return "", 0, false, false
		indent_n := 0
		for indent_n < len(line_txt) && (line_txt[indent_n] == ' ' || line_txt[indent_n] == '\t') {
			indent_n += 1
		}
		eol := le
		has_nl := false
		if eol < len(src) && src[eol] == '\r' {
			eol += 1
			has_nl = true
		}
		if eol < len(src) && src[eol] == '\n' {
			eol += 1
			has_nl = true
		}
		ins := has_nl \
			? fmt.tprintf("%s_ = %s\n", line_txt[:indent_n], act.replacement) \
			: fmt.tprintf("\n%s_ = %s\n", line_txt[:indent_n], act.replacement)
		out := strings.concatenate({src[:eol], ins, src[eol:]}, context.temp_allocator)
		return out, eol + len(ins) - 1, false, true
	case .Replace_Ident:
		if act.replacement == "" || act.old_ident == "" do return "", 0, false, false
		ls, le, line_txt := _line_slice_1based(src, act.target_line)
		if le <= ls do return "", 0, false, false
		search_from := 0
		for search_from < len(line_txt) {
			idx := strings.index(line_txt[search_from:], act.old_ident)
			if idx < 0 do break
			abs_i := search_from + idx
			end_i := abs_i + len(act.old_ident)
			left_ok  := abs_i == 0 || !_is_word_char(line_txt[abs_i - 1])
			right_ok := end_i >= len(line_txt) || !_is_word_char(line_txt[end_i])
			if left_ok && right_ok {
				out := strings.concatenate({src[:ls + abs_i], act.replacement, src[ls + end_i:]}, context.temp_allocator)
				return out, ls + abs_i + len(act.replacement), false, true
			}
			search_from = abs_i + 1
		}
		return "", 0, false, false
	case .Migrate_Legacy_Import:
		if act.old_ident == "" || act.replacement == "" do return "", 0, false, false
		ls, le, line_txt := _line_slice_1based(src, act.target_line)
		if le <= ls do return "", 0, false, false
		if idx := strings.index(line_txt, act.old_ident); idx >= 0 {
			out := strings.concatenate({src[:ls + idx], act.replacement, src[ls + idx + len(act.old_ident):]}, context.temp_allocator)
			return out, ls + idx + len(act.replacement), false, true
		}
		return "", 0, false, false
	case .Migrate_All_Legacy_Imports:
		updated_all, cnt := migrate_all_legacy_moonhug_imports(src, "", context.temp_allocator)
		if cnt > 0 {
			ls, _, _ := _line_slice_1based(updated_all, act.target_line)
			return updated_all, clamp(ls, 0, len(updated_all)), false, true
		}
		return "", 0, false, false
	}
	return "", 0, false, false
}

@(private = "file")
_draw_syntax_code_surface :: proc(
	child_id:       cstring,
	buf:            ^[]byte,
	size:           im.Vec2,
	diags:          []Studio_Diagnostic,
	ide:            ^_Surface_IDE_State,
	pins:           []Scoped_Pin_Badge = nil,
	is_scoped_body: bool               = false,
	scroll_to_line: ^int               = nil,
	undo:           ^Code_Undo_Stack   = nil,
	dirty:          ^bool              = nil,
	pkg_dir:        string             = "",
	active_file:    string             = "",
	read_only:      bool               = false,
) -> (edited: bool) {
	if buf == nil do return false
	ide.read_only_surface = read_only
	min_cap := is_scoped_body ? SCOPED_MIN_BUF_CAP : STUDIO_MIN_BUF_CAP
	_ensure_buf_capacity(buf, 1, min_cap)
	_ensure_zoom_init()
	p  := thm.palette()
	st := thm.studio_tokens()
	io := im.GetIO()

	// Inline Find & Replace Bar (`Ctrl+F`) + Go-to-Line Bar (`Ctrl+G`)
	discrete_replace := false
	if _draw_find_replace_bar(ide, buf, scroll_to_line, undo) {
		edited           = true
		discrete_replace = true
	}
	_draw_goto_line_bar(ide, buf^, scroll_to_line)

	child_size := size
	if ide.find_open && child_size.y > 40.0 {
		child_size.y -= 36.0
	}
	if ide.goto_open && child_size.y > 40.0 {
		child_size.y -= 36.0
	}

	// Push crisp vector-rasterized scaled font (`PushFontFloat` in ImGui 1.92) BEFORE `BeginChild`
	// so line heights, gutter numbers, caret, selection, and colored syntax tokens match 1:1!
	// Popped right after `im.EndChild()` so popups/tooltips stay cleanly readable even at 240% code zoom.
	scaled_font_px := im.GetStyle().FontSizeBase * _studio_zoom_val()
	im.PushFontFloat(nil, scaled_font_px)

	im.PushStyleColorImVec4(.ChildBg, st.code_child_bg)
	im.PushStyleVarImVec2(.WindowPadding, {0, 0})
	// Disable wheel scrolling on the child container while `Ctrl` is held so `Ctrl + MouseWheel`
	// zooms cleanly without jumping the vertical scrollbar!
	child_win_flags: im.WindowFlags = {.HorizontalScrollbar}
	if io.KeyCtrl {
		child_win_flags += {.NoScrollWithMouse}
	}
	open := im.BeginChild(child_id, child_size, {.Borders}, child_win_flags)
	im.PopStyleVar()
	im.PopStyleColor()
	if !open {
		im.EndChild()
		im.PopFont()
		return edited
	}

	// Handle `Ctrl + MouseWheel` and `Ctrl + =/- / 0` Zoom inside hovered/focused code surface!
	surface_hovered := im.IsWindowHovered(im.HoveredFlags_ChildWindows | im.HoveredFlags_AllowWhenBlockedByActiveItem)
	surface_focused := im.IsWindowFocused({.ChildWindows})
	if surface_hovered && io.KeyCtrl && io.MouseWheel != 0 {
		set_studio_code_zoom(_studio.code_zoom + io.MouseWheel * CODE_ZOOM_STEP)
		io.MouseWheel = 0
	}
	if surface_focused && io.KeyCtrl {
		if im.IsKeyPressed(.Equal, false) || im.IsKeyPressed(.KeypadAdd, false) {
			set_studio_code_zoom(_studio.code_zoom + CODE_ZOOM_STEP)
		} else if im.IsKeyPressed(.Minus, false) || im.IsKeyPressed(.KeypadSubtract, false) {
			set_studio_code_zoom(_studio.code_zoom - CODE_ZOOM_STEP)
		} else if im.IsKeyPressed(._0, false) || im.IsKeyPressed(.Keypad0, false) {
			set_studio_code_zoom(1.0)
		} else if im.IsKeyPressed(.F, false) || im.IsKeyPressed(.H, false) {
			ide.find_open           = true
			ide.find_focus_next     = true
			ide.find_current_offset = ide.cursor_pos
		} else if im.IsKeyPressed(.G, false) {
			ide.goto_open       = !ide.goto_open
			ide.goto_focus_next = ide.goto_open
		} else if !read_only && im.IsKeyPressed(.Slash, false) {
			ide.cmd_toggle_comment = true
		} else if !read_only && im.IsKeyPressed(.D, false) {
			ide.cmd_dup_line = true
		} else if !read_only && (im.IsKeyPressed(.V, false) || im.IsKeyPressed(.X, false)) {
			ide.next_edit_immediate = true
		} else if !read_only && im.IsKeyPressed(.Space, false) {
			ide.ac_force_open    = true
			ide.ac_dismissed_pos = -1
		}
		if !read_only && undo != nil && im.GetFrameCount() != _studio.last_undo_redo_frame {
			if (io.KeyShift && im.IsKeyPressed(.Z, true)) || im.IsKeyPressed(.Y, true) {
				if _apply_undo_or_redo_step(false, undo, buf, ide, dirty, pkg_dir, is_scoped_body) {
					edited = true
				}
			} else if !io.KeyShift && im.IsKeyPressed(.Z, true) {
				if _apply_undo_or_redo_step(true, undo, buf, ide, dirty, pkg_dir, is_scoped_body) {
					edited = true
				}
			}
		}
	}
	if !read_only && surface_focused && ide.ac_open && !io.KeyAlt && !io.KeyCtrl {
		if im.IsKeyPressed(.UpArrow, true) {
			ide.ac_selected_idx -= 1
			ide.ac_lock_cursor   = true
			ide.ac_locked_cpos   = ide.cursor_pos
			ide.ac_locked_sels   = ide.sel_start
			ide.ac_locked_sele   = ide.sel_end
			ide.ac_nav_moved     = true
		} else if im.IsKeyPressed(.DownArrow, true) {
			ide.ac_selected_idx += 1
			ide.ac_lock_cursor   = true
			ide.ac_locked_cpos   = ide.cursor_pos
			ide.ac_locked_sels   = ide.sel_start
			ide.ac_locked_sele   = ide.sel_end
			ide.ac_nav_moved     = true
		}
	}
	req_alt_enter_qf := false
	if !read_only && surface_focused && io.KeyAlt && !io.KeyCtrl {
		if im.IsKeyPressed(.UpArrow, false) {
			ide.cmd_move_line_dir = -1
		} else if im.IsKeyPressed(.DownArrow, false) {
			ide.cmd_move_line_dir = 1
		} else if im.IsKeyPressed(.Enter, false) || im.IsKeyPressed(.KeypadEnter, false) {
			req_alt_enter_qf = true
		}
	}
	if !read_only && surface_focused && io.KeyShift && im.IsKeyPressed(.Tab, false) && !ide.ac_open {
		ide.cmd_outdent_tab = true
	}
	if surface_focused && im.IsKeyPressed(.Escape, false) {
		if ide.ac_open {
			ide.ac_open              = false
			ide.ac_force_open        = false
			ide.ac_popup_interacting = false
			ide.ac_popup_dragging    = false
			ide.ac_dismissed_pos     = ide.cursor_pos
		} else if ide.goto_open {
			ide.goto_open = false
		} else if ide.find_open {
			ide.find_open = false
		}
	}

	src_before := _c_buf_string(buf^)
	_ensure_ide_surface_cache(ide, src_before)
	line_starts := ide.cached_line_starts[:]
	num_lines   := max(len(line_starts), 1)
	line_h      := im.GetTextLineHeight()
	gutter_w    := max(im.CalcTextSize("9999").x + 22.0, 46.0)
	pad_x       := f32(8.0)
	pad_y       := f32(6.0)

	// Compute 1-based `(caret_line, caret_col)` from `ide.cursor_pos`
	cpos_clamped := clamp(ide.cursor_pos, 0, len(src_before))
	caret_ln := 1
	caret_col := 1
	for li := len(line_starts) - 1; li >= 0; li -= 1 {
		if cpos_clamped >= line_starts[li] {
			caret_ln  = li + 1
			caret_col = (cpos_clamped - line_starts[li]) + 1
			break
		}
	}
	ide.caret_line = caret_ln
	ide.caret_col  = caret_col

	win_pos := im.GetWindowPos()
	win_h   := im.GetWindowHeight()
	win_w   := im.GetWindowWidth()
	vis_right_x := win_pos.x + max(win_w - 16.0, gutter_w + 80.0)

	if ide.cmd_jump_line > 0 && len(line_starts) > 0 {
		clamped_jmp := clamp(ide.cmd_jump_line, 1, len(line_starts))
		if ide.cmd_jump_offset < 0 {
			col_off := max(ide.cmd_jump_col - 1, 0)
			ide.cmd_jump_offset = _clamp_utf8_boundary(src_before, line_starts[clamped_jmp - 1] + col_off)
		}
		ide.cmd_jump_line    = 0
		ide.cmd_jump_col     = 0
		ide.ac_refocus_input = true
		center_y := max(f32(clamped_jmp - 1) * line_h + pad_y - max(win_h * 0.35, 48.0), 0.0)
		im.SetScrollY(center_y)
	}
	if scroll_to_line != nil && scroll_to_line^ > 0 {
		center_y := max(f32(scroll_to_line^ - 1) * line_h + pad_y - max(win_h * 0.35, 48.0), 0.0)
		im.SetScrollY(center_y)
		scroll_to_line^ = 0
	}

	flash_alpha := f32(0.0)
	if ide.flash_line > 0 && ide.flash_until_sec > 0 {
		rem_flash := ide.flash_until_sec - im.GetTime()
		if rem_flash > 0 {
			flash_alpha = clamp(f32(rem_flash / 1.25), 0.0, 1.0) * 0.36
		} else {
			ide.flash_line      = 0
			ide.flash_until_sec = 0
		}
	}

	diag_by_line := make(map[int]Studio_Diagnostic, context.temp_allocator)
	for d in diags {
		if !diagnostic_matches_active_file(d.file, active_file) do continue
		prev_d, existed := diag_by_line[d.line]
		if !existed || (prev_d.is_warning && !d.is_warning) {
			diag_by_line[d.line] = d
		}
	}

	origin  := im.GetCursorScreenPos()
	dl      := im.GetWindowDrawList()
	avail   := im.GetContentRegionAvail()
	total_h := max(f32(num_lines + 5) * line_h + pad_y * 2.0, avail.y)

	char_adv_est := max(im.CalcTextSize("M").x, 7.0)
	max_line_px  := max(avail.x - gutter_w, f32(ide.cache_max_cols) * char_adv_est + 64.0)
	first_ln_i   := clamp(int(math.floor((win_pos.y - origin.y - pad_y) / max(line_h, 1.0))) - 2, 0, num_lines - 1)
	last_ln_i    := clamp(int(math.ceil((win_pos.y + win_h - origin.y - pad_y) / max(line_h, 1.0))) + 2, first_ln_i, num_lines - 1)

	// 1. Gutter backdrop, Active Caret Line Highlight, Flash Highlight & Error Line Tinting (clipped to visible viewport)
	im.DrawList_AddRectFilled(dl, origin, {origin.x + gutter_w, origin.y + total_h}, im.GetColorU32ImVec4(st.gutter_bg))
	im.DrawList_AddLine(dl, {origin.x + gutter_w, origin.y}, {origin.x + gutter_w, origin.y + total_h}, im.GetColorU32ImVec4(p.border_subtle), 1.0)

	qf_clicked_line      := 0
	qf_clicked_anchor    := im.Vec2{}
	gutter_tooltip_shown := false
	for ln_i in first_ln_i ..= last_ln_i {
		ln := ln_i + 1
		ly := origin.y + pad_y + f32(ln_i) * line_h
		if ln == caret_ln && surface_focused {
			im.DrawList_AddRectFilled(dl, {origin.x + gutter_w + 1, ly}, {origin.x + gutter_w + max_line_px, ly + line_h}, im.GetColorU32ImVec4(st.active_line_tint))
		}
		if ln == ide.flash_line && flash_alpha > 0.001 {
			im.DrawList_AddRectFilled(dl, {origin.x + gutter_w + 1, ly}, {origin.x + gutter_w + max_line_px, ly + line_h}, im.GetColorU32ImVec4(thm.with_alpha(p.accent, flash_alpha)))
		}
		if d, has_d := diag_by_line[ln]; has_d {
			row_tint := d.is_warning ? st.diag_warn_row : st.diag_err_row
			im.DrawList_AddRectFilled(dl, {origin.x + gutter_w + 1, ly}, {origin.x + gutter_w + max_line_px, ly + line_h}, im.GetColorU32ImVec4(row_tint))
			dot_col := d.is_warning ? st.diag_warn_fg : st.diag_err_fg
			im.DrawList_AddCircleFilled(dl, {origin.x + 8.0, ly + line_h * 0.5}, 3.5, im.GetColorU32ImVec4(dot_col))

			im.SetCursorScreenPos({origin.x, ly})
			if im.InvisibleButton(fmt.ctprintf("##ln_err_%d", ln), {gutter_w, line_h}) {
				qf_clicked_line   = ln
				qf_clicked_anchor = {origin.x + gutter_w + 4.0, ly + line_h + 2.0}
			}
			if im.IsItemHovered() {
				gutter_tooltip_shown = true
			}
			widgets.tooltip(fmt.ctprintf("Line %d:%d — %s\n(Click gutter marker for Quick Fixes)", d.line, d.column, d.message))
		}
		num_col := ln == caret_ln ? p.accent : p.text_muted
		num_txt := fmt.ctprintf("%3d", ln)
		im.DrawList_AddText(dl, {origin.x + 14.0, ly}, im.GetColorU32ImVec4(num_col), num_txt)
	}

	// 2. Matching Bracket Highlight (`{}` / `()` / `[]`)
	code_x := origin.x + gutter_w
	if surface_focused {
		if b1, b2, bok := _find_matching_bracket(src_before, cpos_clamped); bok {
			char_w := max(im.CalcTextSize("M").x, 7.0)
			for b_off in ([2]int{b1, b2}) {
				for li := len(line_starts) - 1; li >= 0; li -= 1 {
					if b_off >= line_starts[li] {
						col_i := b_off - line_starts[li]
						x_px  := col_i > 0 ? im.CalcTextSize(fmt.ctprintf("%s", src_before[line_starts[li]:b_off])).x : 0.0
						by    := origin.y + pad_y + f32(li) * line_h
						bx    := code_x + pad_x + x_px
						im.DrawList_AddRectFilled(dl, {bx - 1, by}, {bx + char_w + 1, by + line_h}, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.24)), 2.0)
						im.DrawList_AddRect(dl, {bx - 1, by}, {bx + char_w + 1, by + line_h}, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.80)), 2.0)
						break
					}
				}
			}
		}
	}

	// 3. Native ImGui Multiline Input with V2 IDE Callback
	//    Note: Never pass `.CallbackHistory` to `InputTextMultiline` (ImGui asserts `!is_multiline`);
	//    `.NoUndoRedo` delegates Ctrl+Z/Y history cleanly to our 64-step `Code_Undo_Stack`.
	im.SetCursorScreenPos({code_x, origin.y})
	im.PushStyleVarImVec2(.FramePadding, {pad_x, pad_y})
	im.PushStyleVar(.FrameBorderSize, 0.0)
	im.PushStyleColorImVec4(.FrameBg, {0, 0, 0, 0})
	im.PushStyleColorImVec4(.Text, {0, 0, 0, 0})
	im.PushStyleColorImVec4(.InputTextCursor, p.accent)
	im.PushStyleColorImVec4(.TextSelectedBg, thm.with_alpha(p.accent, 0.28))

	in_flags: im.InputTextFlags = {.NoUndoRedo, .CallbackResize, .CallbackAlways, .CallbackCompletion, .CallbackCharFilter}
	if read_only {
		in_flags += {.ReadOnly}
	}

	prev_cursor := ide.cursor_pos
	if ide.ac_refocus_input {
		im.SetKeyboardFocusHere()
		ide.ac_refocus_input = false
	}
	ide.active_buf = buf
	if im.InputTextMultiline(
		"##odin_code_input",
		cstring(raw_data(buf^)),
		uint(len(buf^)),
		{max_line_px, total_h},
		in_flags,
		_code_input_callback,
		ide,
	) {
		edited = true
	}
	ide.active_buf = nil
	input_active := im.IsItemActive()
	im.PopStyleColor(4)
	im.PopStyleVar(2)

	just_restored := ide.cmd_restore_applied
	if ide.cmd_restore_active {
		if !ide.cmd_restore_applied {
			_copy_to_c_buf_grow(buf, ide.cmd_restore_text, is_scoped_body ? SCOPED_MIN_BUF_CAP : STUDIO_MIN_BUF_CAP)
			ide.cursor_pos = _clamp_utf8_boundary(ide.cmd_restore_text, ide.cmd_restore_cursor)
			ide.sel_start  = ide.cursor_pos
			ide.sel_end    = ide.cursor_pos
			just_restored  = true
		}
		_clear_ide_pending_restore(ide)
	}
	ide.cmd_restore_applied = false

	if edited {
		cur_s := _c_buf_string(buf^)
		if strings.contains_rune(cur_s, '\t') {
			norm_tabs, _ := strings.replace_all(cur_s, "\t", "    ", context.temp_allocator)
			new_c := _clamp_utf8_boundary(norm_tabs, ide.cursor_pos + (len(norm_tabs) - len(cur_s)))
			_copy_to_c_buf_grow(buf, norm_tabs, is_scoped_body ? SCOPED_MIN_BUF_CAP : STUDIO_MIN_BUF_CAP)
			_arm_ide_restore(ide, norm_tabs, new_c)
			cur_s = _c_buf_string(buf^)
		}
		if !just_restored && undo != nil {
			code_undo_record_edit(undo, cur_s, ide.cursor_pos, im.GetTime(), discrete_replace || ide.next_edit_immediate)
		}
		ide.next_edit_immediate = false
		ide.ac_dismissed_pos = -1 // Re-enable autocomplete on fresh edits
	} else {
		ide.next_edit_immediate = false
		if ide.cursor_pos != prev_cursor && !ide.ac_open {
			ide.ac_dismissed_pos = ide.cursor_pos // Moving caret without typing doesn't randomly pop autocomplete
		}
	}

	// 4. Paint cached `core:odin/tokenizer` Syntax Spans, Find Highlights, Diagnostic Underlines & Viewport-Clamped Error Lens
	src_now := _c_buf_string(buf^)
	_ensure_ide_surface_cache(ide, src_now)
	ls_now := ide.cached_line_starts[:]
	spans  := ide.cached_spans[:]

	mpos_chip        := io.MousePos
	allow_chip_hover := surface_hovered && !ide.ac_open
	find_q           := ide.find_open ? _c_buf_string(ide.find_buf[:]) : ""

	vis_first := clamp(first_ln_i, 0, max(len(ls_now) - 1, 0))
	vis_last  := clamp(last_ln_i, vis_first, max(len(ls_now) - 1, 0))
	span_idx := len(ide.cached_line_span_head) > vis_first ? ide.cached_line_span_head[vis_first] : 0
	if len(ls_now) > 0 do for ln_i in vis_first ..= vis_last {
		ln := ln_i + 1
		ls := ls_now[ln_i]
		le := ln_i + 1 < len(ls_now) ? (ls_now[ln_i + 1] - 1) : len(src_now)
		if le > ls && src_now[le - 1] == '\r' do le -= 1
		line_str := le > ls ? src_now[ls:le] : ""
		ly := origin.y + pad_y + f32(ln_i) * line_h
		base_x := code_x + pad_x

		if len(find_q) > 0 && len(find_q) <= len(line_str) {
			f_off := 0
			for f_off <= len(line_str) - len(find_q) {
				if _matches_at(line_str, find_q, f_off, ide.find_case_sensitive) {
					s0 := _clamp_utf8_boundary(line_str, f_off)
					s1 := _clamp_utf8_boundary(line_str, f_off + len(find_q))
					fx0 := s0 > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:s0])).x : 0.0
					fx1 := s1 > s0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:s1])).x : (fx0 + 12.0)
					is_cur_hit := (ls + f_off) == ide.find_current_offset
					hl_col := is_cur_hit ? thm.with_alpha(p.accent, 0.42) : thm.with_alpha(p.status_warning, 0.24)
					im.DrawList_AddRectFilled(dl, {base_x + fx0, ly}, {base_x + fx1, ly + line_h}, im.GetColorU32ImVec4(hl_col), 2.0)
					if is_cur_hit {
						im.DrawList_AddRect(dl, {base_x + fx0, ly}, {base_x + fx1, ly + line_h}, im.GetColorU32ImVec4(p.accent), 2.0, 1.0)
					}
					f_off += len(find_q)
				} else {
					f_off += 1
				}
			}
		}

		is_unused_imp := !is_scoped_body && _is_unused_import_line(ide, ln)
		if len(line_str) > 0 {
			col_cursor := 0
			for span_idx < len(spans) && spans[span_idx].line < ln {
				span_idx += 1
			}
			for span_idx < len(spans) && spans[span_idx].line == ln {
				sp := spans[span_idx]
				span_idx += 1
				cs := _clamp_utf8_boundary(line_str, clamp(sp.col_start, col_cursor, len(line_str)))
				ce := _clamp_utf8_boundary(line_str, clamp(sp.col_end, cs, len(line_str)))
				if cs > col_cursor {
					x_off := col_cursor > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:col_cursor])).x : 0.0
					plain_col := is_unused_imp ? p.text_muted : p.text_primary
					im.DrawList_AddText(dl, {base_x + x_off, ly}, im.GetColorU32ImVec4(plain_col), fmt.ctprintf("%s", line_str[col_cursor:cs]))
				}
				if ce > cs {
					x_off := cs > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:cs])).x : 0.0
					col := is_unused_imp ? p.text_muted : role_color(sp.role, &p)
					im.DrawList_AddText(dl, {base_x + x_off, ly}, im.GetColorU32ImVec4(col), fmt.ctprintf("%s", line_str[cs:ce]))
				}
				col_cursor = ce
			}
			if col_cursor < len(line_str) {
				x_off := col_cursor > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:col_cursor])).x : 0.0
				tail_col := is_unused_imp ? p.text_muted : p.text_primary
				im.DrawList_AddText(dl, {base_x + x_off, ly}, im.GetColorU32ImVec4(tail_col), fmt.ctprintf("%s", line_str[col_cursor:]))
			}
		}

		d, has_d := diag_by_line[ln]
		if has_d {
			c0 := _clamp_utf8_boundary(line_str, clamp(d.column - 1, 0, len(line_str)))
			c1 := _clamp_utf8_boundary(line_str, clamp(max(d.end_column - 1, c0 + 4), 0, len(line_str)))
			x0 := c0 > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:c0])).x : 0.0
			x1 := c1 > c0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:c1])).x : (x0 + 28.0)
			u_col := d.is_warning ? thm.with_alpha(st.diag_warn_fg, 0.95) : thm.with_alpha(st.diag_err_fg, 0.95)
			im.DrawList_AddLine(dl, {base_x + x0, ly + line_h - 1.0}, {base_x + max(x1, x0 + 18.0), ly + line_h - 1.0}, im.GetColorU32ImVec4(u_col), 2.0)
		}

		// Rider call-site conflict highlight (`ide.conflict_line / conflict_col_start..end`)
		if ide.conflict_line == ln && len(line_str) > 0 {
			c0 := _clamp_utf8_boundary(line_str, clamp(ide.conflict_col_start - 1, 0, len(line_str)))
			c1 := _clamp_utf8_boundary(line_str, clamp(max(ide.conflict_col_end - 1, c0 + 4), 0, len(line_str)))
			x0 := c0 > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:c0])).x : 0.0
			x1 := c1 > c0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:c1])).x : (x0 + 36.0)
			red_col := thm.with_alpha(st.diag_err_fg, 0.98)
			im.DrawList_AddRectFilled(dl, {base_x + x0, ly}, {base_x + max(x1, x0 + 24.0), ly + line_h}, im.GetColorU32ImVec4(thm.with_alpha(st.diag_err_fg, 0.14)), 2.0)
			im.DrawList_AddLine(dl, {base_x + x0, ly + line_h - 1.0}, {base_x + max(x1, x0 + 24.0), ly + line_h - 1.0}, im.GetColorU32ImVec4(red_col), 2.5)
		}

		if has_d || (is_unused_imp && len(line_str) > 0) {
			d_msg := has_d ? d.message : "Unused import"
			fixes := build_line_quick_fixes(src_now, ln, d_msg, is_unused_imp, context.temp_allocator)
			line_end_x := len(line_str) > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str)).x : 0.0
			pill_col := !has_d ? p.text_muted : (d.is_warning ? st.diag_warn_fg : st.diag_err_fg)
			tag_lbl  := !has_d ? "// [Unused]" : (d.is_warning ? "// [Warn]" : "// [Error]")

			chip_lbl := fmt.ctprintf("%s Fix", icons.ICON_MD_BOLT)
			chip_pad := f32(6.0)
			chip_w   := len(fixes) > 0 ? (im.CalcTextSize(chip_lbl).x + chip_pad * 2.0) : f32(0.0)
			gap_w    := len(fixes) > 0 ? f32(6.0) : f32(0.0)
			max_badge_span := max(vis_right_x - (code_x + pad_x + 28.0) - chip_w - gap_w, 96.0)

			pill_txt: cstring
			if _studio.show_error_lens && d_msg != "" {
				lens_pref := widgets.utf8_safe_prefix(d_msg, 64)
				lens_msg  := len(lens_pref) < len(d_msg) ? fmt.tprintf("%s...", lens_pref) : d_msg
				cand_txt  := fmt.ctprintf("%s %s", tag_lbl, lens_msg)
				if im.CalcTextSize(cand_txt).x + 12.0 > max_badge_span {
					short_pref := widgets.utf8_safe_prefix(d_msg, 24)
					short_msg  := len(short_pref) < len(d_msg) ? fmt.tprintf("%s...", short_pref) : d_msg
					cand_txt = fmt.ctprintf("%s %s", tag_lbl, short_msg)
					if im.CalcTextSize(cand_txt).x + 12.0 > max_badge_span {
						cand_txt = fmt.ctprintf("%s", tag_lbl)
					}
				}
				pill_txt = cand_txt
			} else {
				pill_txt = fmt.ctprintf("%s", tag_lbl)
			}

			pad_px   := f32(6.0)
			txt_sz   := im.CalcTextSize(pill_txt)
			pill_w   := txt_sz.x + pad_px * 2.0
			total_w  := pill_w + gap_w + chip_w
			ideal_x  := base_x + line_end_x + 14.0 * _studio_zoom_val()
			clamp_x  := max(vis_right_x - total_w - 8.0, code_x + pad_x + 24.0)
			pill_x   := min(ideal_x, clamp_x)

			pill_min := im.Vec2{pill_x, ly + 1.0}
			pill_max := im.Vec2{pill_x + pill_w, ly + line_h - 1.0}
			pill_bg  := thm.with_alpha(thm.lerp_col(st.code_child_bg, pill_col, p.is_light ? 0.18 : 0.24), 0.96)
			im.DrawList_AddRectFilled(dl, pill_min, pill_max, im.GetColorU32ImVec4(pill_bg), 4.0)
			im.DrawList_AddRect(dl, pill_min, pill_max, im.GetColorU32ImVec4(thm.with_alpha(pill_col, 0.70)), 4.0)
			im.DrawList_AddText(dl, {pill_x + pad_px, ly + 1.0}, im.GetColorU32ImVec4(pill_col), pill_txt)

			pill_hov := allow_chip_hover && mpos_chip.x >= pill_min.x && mpos_chip.x <= pill_max.x && mpos_chip.y >= pill_min.y && mpos_chip.y <= pill_max.y
			if pill_hov {
				gutter_tooltip_shown = true
				im.SetMouseCursor(.Hand)
				widgets.tooltip(fmt.ctprintf("Line %d:%d — %s\n(Click for Quick Fixes / `Alt+Enter`)", ln, has_d ? max(d.column, 1) : 1, d_msg))
				if im.IsMouseClicked(.Left) && len(fixes) > 0 {
					qf_clicked_line   = ln
					qf_clicked_anchor = {pill_min.x, pill_max.y + 3.0}
				}
			}

			if len(fixes) > 0 {
				chip_x   := pill_max.x + gap_w
				chip_min := im.Vec2{chip_x, ly + 1.0}
				chip_max := im.Vec2{chip_x + chip_w, ly + line_h - 1.0}
				chip_hov := allow_chip_hover && mpos_chip.x >= chip_min.x && mpos_chip.x <= chip_max.x && mpos_chip.y >= chip_min.y && mpos_chip.y <= chip_max.y
				chip_bg  := thm.with_alpha(thm.lerp_col(st.code_child_bg, p.accent, chip_hov ? 0.36 : 0.22), 0.96)
				im.DrawList_AddRectFilled(dl, chip_min, chip_max, im.GetColorU32ImVec4(chip_bg), 4.0)
				im.DrawList_AddRect(dl, chip_min, chip_max, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.78)), 4.0)
				im.DrawList_AddText(dl, {chip_min.x + chip_pad, ly + 1.0}, im.GetColorU32ImVec4(p.accent), chip_lbl)
				if chip_hov {
					gutter_tooltip_shown = true
					im.SetMouseCursor(.Hand)
					widgets.tooltip("Quick Fix (`Alt+Enter`) — click for suggested actions")
					if im.IsMouseClicked(.Left) {
						qf_clicked_line   = ln
						qf_clicked_anchor = {chip_min.x, chip_max.y + 3.0}
					}
				}
			}
		}
	}

	// Scrollbar Overview Ruler diagnostic tick marks on right edge of viewport
	if len(diags) > 0 && win_h > 36.0 {
		ov_x0 := win_pos.x + win_w - 13.0
		ov_x1 := win_pos.x + win_w - 4.0
		ov_h  := max(win_h - 24.0, 20.0)
		for d in diags {
			if !diagnostic_matches_active_file(d.file, active_file) do continue
			frac := f32(clamp(d.line - 1, 0, max(num_lines - 1, 1))) / f32(max(num_lines, 1))
			ry := win_pos.y + 6.0 + frac * ov_h
			rcol := d.is_warning ? st.diag_warn_fg : st.diag_err_fg
			im.DrawList_AddRectFilled(dl, {ov_x0, ry}, {ov_x1, ry + 3.0}, im.GetColorU32ImVec4(thm.with_alpha(rcol, 0.90)), 1.0)
		}
	}

	// Compute screen coordinates of the live caret for anchoring Autocomplete / Call-Tip / Quick-Fix popups!
	caret_top_y      := origin.y + pad_y + f32(max(ide.caret_line - 1, 0)) * line_h
	caret_bottom_y   := caret_top_y + line_h
	caret_screen_pos := im.Vec2{code_x + pad_x, caret_bottom_y + 2.0}
	if ide.caret_line >= 1 && ide.caret_line <= len(ls_now) {
		ls_c := ls_now[ide.caret_line - 1]
		c_end := clamp(ide.cursor_pos, ls_c, len(src_now))
		if c_end > ls_c {
			caret_screen_pos.x += im.CalcTextSize(fmt.ctprintf("%s", src_now[ls_c:c_end])).x
		}
	}
	if req_alt_enter_qf && qf_clicked_line == 0 {
		qf_clicked_line   = clamp(ide.caret_line, 1, num_lines)
		qf_clicked_anchor = {caret_screen_pos.x, caret_bottom_y + 4.0}
	}

	// Stationary Idle-Delay Hover Symbol Type, Signature & `//` Doc-Comment Peek (`0 ms` main-thread hit-test!)
	// PLUS JetBrains `Ctrl + Left-Click` Go-To-Definition!
	hover_peek_str     := ""
	hover_unsafe_warn  := cstring(nil)
	hover_ident_hash   := u64(0)
	ide.req_jump_ident = ""
	ide.req_jump_rec   = ""
	if im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByPopup) && !gutter_tooltip_shown && !ide.ac_open && (!im.IsMouseDown(.Left) || im.IsMouseClicked(.Left)) {
		mpos := im.GetIO().MousePos
		if mpos.x >= code_x + pad_x {
			h_ln_i := int(math.floor((mpos.y - (origin.y + pad_y)) / max(line_h, 1.0)))
			if h_ln_i >= 0 && h_ln_i < len(ls_now) {
				hls := ls_now[h_ln_i]
				hle := h_ln_i + 1 < len(ls_now) ? (ls_now[h_ln_i + 1] - 1) : len(src_now)
				if hle > hls && src_now[hle - 1] == '\r' do hle -= 1
				hline := hle > hls ? src_now[hls:hle] : ""
				rel_x := mpos.x - (code_x + pad_x)
				if len(hline) > 0 && rel_x >= 0 {
					hit_col := -1
					max_scan := min(len(hline), 180)
					for ci in 0 ..< max_scan {
						if ci + 1 < len(hline) && (hline[ci + 1] & 0xC0) == 0x80 do continue
						w_ci := im.CalcTextSize(fmt.ctprintf("%s", hline[:ci + 1])).x
						if rel_x <= w_ci {
							hit_col = ci
							break
						}
					}
					if ident, rec, ok := odin_ident_at(hline, hit_col); ok {
						if io.KeyCtrl {
							im.SetMouseCursor(.Hand)
							if im.IsMouseClicked(.Left) {
								ide.req_jump_ident = strings.clone(ident, context.temp_allocator)
								ide.req_jump_rec   = rec != "" ? strings.clone(rec, context.temp_allocator) : ""
							}
						}
						base_info := resolve_symbol_hover_info(ident, rec, pins, context.temp_allocator)
						doc_str   := extract_odin_proc_doc_comment(src_now, ident, context.temp_allocator)
						if doc_str == "" {
							if he, hok := resolve_hot_proc_info(ident); hok && he.source_file != "" {
								cache_key := fmt.tprintf("%s::%s", he.source_file, ident)
								if cached_doc, ok_cache := _studio.hot_doc_cache[cache_key]; ok_cache {
									doc_str = cached_doc
								} else {
									loaded_doc := extract_odin_proc_doc_from_file(he.source_file, ident, context.temp_allocator)
									prev_a := context.allocator
									context.allocator = runtime.default_allocator()
									_studio.hot_doc_cache[strings.clone(cache_key)] = strings.clone(loaded_doc)
									context.allocator = prev_a
									doc_str = loaded_doc
								}
							}
						}
						hover_unsafe_warn = odin_ident_unsafe_warning(ident)
						if doc_str != "" && !strings.contains(base_info, doc_str) {
							hover_peek_str = base_info != "" \
								? fmt.tprintf("%s\n\n%s", base_info, doc_str) \
								: fmt.tprintf("proc %s\n\n%s", ident, doc_str)
						} else if base_info != "" {
							hover_peek_str = base_info
						} else if hover_unsafe_warn != nil {
							hover_peek_str = fmt.tprintf("Odin Low-Level / Pointer Primitive: %s", ident)
						}
						hover_ident_hash = _fnv1a_src(ident) ~ (u64(h_ln_i + 1) << 32)
					}
				}
			}
		}
	}

	// Right-click editor context menu (Copy, Paste, Toggle Comment, Duplicate, Find/Go-to, Comment Unused Imports)
	if im.IsWindowHovered(im.HoveredFlags_ChildWindows | im.HoveredFlags_AllowWhenBlockedByActiveItem) && im.IsMouseReleased(.Right) && !ide.ac_open {
		im.OpenPopup("##odin_code_ctx_popup")
	}
	if im.BeginPopup("##odin_code_ctx_popup") {
		im.PushFontFloat(nil, im.GetStyle().FontSizeBase)
		defer im.PopFont()
		widgets.popup_header(icons.ICON_MD_CODE, "Odin Editor")
		s_min := clamp(min(ide.sel_start, ide.sel_end), 0, len(src_now))
		s_max := clamp(max(ide.sel_start, ide.sel_end), 0, len(src_now))
		if s_max > s_min {
			_ = widgets.menu_copy_item("Copy Selection", src_now[s_min:s_max], "code_ctx_sel", "Ctrl+C")
		} else {
			im.BeginDisabled()
			_ = im.MenuItem(fmt.ctprintf("%s  Copy Selection", icons.ICON_MD_CONTENT_COPY), "Ctrl+C")
			im.EndDisabled()
		}

		cur_line_txt := ""
		if ide.caret_line >= 1 && ide.caret_line <= len(ls_now) {
			cls := ls_now[ide.caret_line - 1]
			cle := ide.caret_line < len(ls_now) ? (ls_now[ide.caret_line] - 1) : len(src_now)
			if cle > cls && src_now[cle - 1] == '\r' do cle -= 1
			if cle > cls do cur_line_txt = src_now[cls:cle]
		}
		if cur_line_txt != "" {
			_ = widgets.menu_copy_item("Copy Current Line", cur_line_txt, "code_ctx_line")
		} else {
			im.BeginDisabled()
			_ = im.MenuItem(fmt.ctprintf("%s  Copy Current Line", icons.ICON_MD_CONTENT_COPY))
			im.EndDisabled()
		}

		if !read_only {
			if im.MenuItem(fmt.ctprintf("%s  Paste", icons.ICON_MD_CONTENT_PASTE), "Ctrl+V") {
				clip_c := im.GetClipboardText()
				if clip_c != nil {
					clip_s := string(clip_c)
					if clip_s != "" {
						prev_a := context.allocator
						context.allocator = runtime.default_allocator()
						_clear_ide_pending_paste(ide)
						ide.cmd_paste_text    = strings.clone(clip_s)
						ide.cmd_paste_pending = true
						ide.ac_refocus_input  = true
						context.allocator = prev_a
					}
				}
			}
			im.Separator()
			if im.MenuItem("Toggle Line Comment", "Ctrl+/") {
				ide.cmd_toggle_comment = true
				ide.ac_refocus_input   = true
			}
			if im.MenuItem("Duplicate Line", "Ctrl+D") {
				ide.cmd_dup_line     = true
				ide.ac_refocus_input = true
			}
		} else {
			im.Separator()
		}
		if im.MenuItem(fmt.ctprintf("%s  Find & Replace", icons.ICON_MD_SEARCH), "Ctrl+F") {
			ide.find_open       = true
			ide.find_focus_next = true
		}
		if im.MenuItem("Go to Line...", "Ctrl+G") {
			ide.goto_open       = true
			ide.goto_focus_next = true
		}
		if !read_only && !is_scoped_body && len(ide.cached_unused_import_lines) > 0 {
			im.Separator()
			if im.MenuItem(fmt.ctprintf("Comment Unused Imports (%d)", len(ide.cached_unused_import_lines))) {
				if updated, cnt := comment_out_unused_odin_imports(src_now, context.temp_allocator); cnt > 0 {
					c_jump := _clamp_utf8_boundary(updated, ide.cursor_pos)
					_copy_to_c_buf_grow(buf, updated, is_scoped_body ? SCOPED_MIN_BUF_CAP : STUDIO_MIN_BUF_CAP)
					_arm_ide_restore(ide, updated, c_jump)
					ide.ac_refocus_input = true
					if undo != nil {
						code_undo_record_edit(undo, updated, c_jump, im.GetTime(), true)
					}
					if dirty != nil do dirty^ = true
					_notify_buffer_edited(updated, false, pkg_dir)
				}
			}
		}
		im.EndPopup()
	}

	im.EndChild()
	im.PopFont()

	if qf_clicked_line > 0 {
		ide.qf_line   = qf_clicked_line
		ide.qf_anchor = qf_clicked_anchor
		im.OpenPopup("##ide_quickfix_popup")
	}
	if ide.qf_line > 0 {
		qf_scale := clamp(_studio_zoom_val(), 1.0, 1.35)
		im.PushFontFloat(nil, im.GetStyle().FontSizeBase * qf_scale)
		im.SetNextWindowPos(ide.qf_anchor, .Appearing)
		if im.BeginPopup("##ide_quickfix_popup") {
			widgets.popup_header(icons.ICON_MD_BOLT, fmt.tprintf("Quick Fixes — Line %d", ide.qf_line))
			d_qf, has_dqf := diag_by_line[ide.qf_line]
			un_qf := !is_scoped_body && _is_unused_import_line(ide, ide.qf_line)
			d_msg := has_dqf ? d_qf.message : (un_qf ? "Unused import" : "")
			qf_list := build_line_quick_fixes(src_now, ide.qf_line, d_msg, un_qf, context.temp_allocator)
			if len(qf_list) == 0 {
				im.TextDisabled("No automatic Quick-Fix available for this diagnostic.")
			} else {
				for qf in qf_list {
					if (qf.kind == .Inject_Import || qf.kind == .Open_Imports_Popup) && is_scoped_body {
						continue
					}
					if im.MenuItem(fmt.ctprintf("%s  %s", icons.ICON_MD_BOLT, qf.label)) {
						updated, c_jump_raw, req_imp, aok := _apply_quick_fix(src_now, qf)
						if req_imp {
							ide.req_open_imports_popup = true
						} else if aok {
							c_jump := qf.kind == .Inject_Import \
								? _clamp_utf8_boundary(updated, ide.cursor_pos + (len(updated) - len(src_now))) \
								: _clamp_utf8_boundary(updated, c_jump_raw)
							_copy_to_c_buf_grow(buf, updated, is_scoped_body ? SCOPED_MIN_BUF_CAP : STUDIO_MIN_BUF_CAP)
							_arm_ide_restore(ide, updated, c_jump)
							if undo != nil {
								code_undo_record_edit(undo, updated, c_jump, im.GetTime(), true)
							}
							if dirty != nil do dirty^ = true
							_notify_buffer_edited(updated, is_scoped_body, pkg_dir)
							edited = true
						}
						ide.ac_refocus_input = true
					}
				}
			}
			im.EndPopup()
		}
		im.PopFont()
	}

	if hover_peek_str != "" || hover_unsafe_warn != nil {
		widgets.tooltip_unchecked_unsafe_delayed(hover_ident_hash, fmt.ctprintf("%s", hover_peek_str), hover_unsafe_warn)
	}

	// 5. Evaluate & Render Non-Blocking Floating Smart Autocomplete Popup + Inline Call-Tip Signature Pill!
	ac_active_drawn := false
	ac_placed_above := false
	keep_ac_for_popup := ide.ac_open && (ide.ac_popup_interacting || ide.ac_pending_accept)
	caret_in_view := caret_bottom_y >= win_pos.y - line_h && caret_top_y <= win_pos.y + win_h + line_h
	if (input_active || keep_ac_for_popup) && caret_in_view && ide.cursor_pos != ide.ac_dismissed_pos {
		ac_items, rep_start := query_autocomplete_suggestions(src_now, ide.cursor_pos, pins, ide.ac_force_open, is_scoped_body, context.temp_allocator)
		if len(ac_items) > 0 {
			ide.ac_open          = true
			ide.ac_replace_start = rep_start
			if ide.ac_selected_idx < 0 {
				ide.ac_selected_idx = len(ac_items) - 1
			} else if ide.ac_selected_idx >= len(ac_items) {
				ide.ac_selected_idx = 0
			}
			sel_ins := ac_items[ide.ac_selected_idx].insert_text
			n_ins := min(len(sel_ins), len(ide.ac_accept_text) - 1)
			if n_ins > 0 do copy(ide.ac_accept_text[:n_ins], sel_ins[:n_ins])
			ide.ac_accept_text[n_ins] = 0
			ide.ac_accept_len = n_ins

			ac_placed_above = _draw_autocomplete_popup(caret_screen_pos.x, caret_top_y, caret_bottom_y, ac_items, ide)
			ac_active_drawn = true
		} else {
			ide.ac_open              = false
			ide.ac_accept_len        = 0
			ide.ac_popup_interacting = false
			ide.ac_popup_dragging    = false
		}
	} else if !input_active && !keep_ac_for_popup {
		ide.ac_open              = false
		ide.ac_force_open        = false
		ide.ac_accept_len        = 0
		ide.ac_popup_interacting = false
		ide.ac_popup_dragging    = false
	}

	if input_active {
		if tip, has_tip := extract_call_tip_info(src_now, ide.cursor_pos, context.temp_allocator); has_tip {
			prefer_above := !ac_active_drawn || !ac_placed_above
			_draw_call_tip_pill(caret_screen_pos.x, caret_top_y, caret_bottom_y, prefer_above, tip)
		}
	}

	return edited
}

@(private = "file")
_studio_monitor_bounds :: proc(anchor: im.Vec2) -> (pos: im.Vec2, size: im.Vec2) {
	pio := im.GetPlatformIO()
	if pio != nil && pio.Monitors.Data != nil && pio.Monitors.Size > 0 {
		mons := (cast([^]im.PlatformMonitor)pio.Monitors.Data)[:pio.Monitors.Size]
		for m in mons {
			if anchor.x >= m.MainPos.x && anchor.x < m.MainPos.x + m.MainSize.x &&
			   anchor.y >= m.MainPos.y && anchor.y < m.MainPos.y + m.MainSize.y {
				if m.WorkSize.x > 0 && m.WorkSize.y > 0 do return m.WorkPos, m.WorkSize
				return m.MainPos, m.MainSize
			}
		}
	}
	vp := im.GetWindowViewport()
	if vp == nil do vp = im.GetMainViewport()
	if vp.WorkSize.x > 0 && vp.WorkSize.y > 0 do return vp.WorkPos, vp.WorkSize
	return vp.Pos, vp.Size
}

@(private = "file")
_draw_call_tip_pill :: proc(caret_x, line_top_y, line_bottom_y: f32, prefer_above: bool, tip: Call_Tip_Info) {
	pop_scale := clamp(_studio_zoom_val(), 1.0, 1.35)
	im.PushFontFloat(nil, im.GetStyle().FontSizeBase * pop_scale)
	defer im.PopFont()

	p  := thm.palette()
	st := thm.studio_tokens()
	mon_pos, mon_size := _studio_monitor_bounds({caret_x, line_top_y})
	tip_h := im.GetTextLineHeight() + 10.0
	max_x := max(mon_pos.x + 12.0, mon_pos.x + mon_size.x - 380.0 * pop_scale)
	pos_y := prefer_above ? (line_top_y - tip_h - 4.0) : (line_bottom_y + 4.0)
	if prefer_above && pos_y < mon_pos.y + 12.0 {
		pos_y = min(line_bottom_y + 4.0, mon_pos.y + mon_size.y - tip_h - 12.0)
	} else if !prefer_above && pos_y + tip_h > mon_pos.y + mon_size.y - 12.0 {
		pos_y = max(mon_pos.y + 12.0, line_top_y - tip_h - 4.0)
	}
	pos := im.Vec2{
		clamp(caret_x, mon_pos.x + 12.0, max_x),
		pos_y,
	}

	im.SetNextWindowPos(pos, .Always)
	im.PushStyleColorImVec4(.WindowBg, p.bg_popup)
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.accent, 0.72))
	im.PushStyleVar(.WindowBorderSize, 1.1)
	im.PushStyleVar(.WindowRounding, 5.0)
	im.PushStyleVarImVec2(.WindowPadding, {8, 4})

	// NOTE: Never pass internal `WindowFlag.Tooltip` (bit 25) to `im.Begin()` — Dear ImGui asserts `IM_ASSERT` (`SIGABRT`)!
	widgets.pin_tooltip_to_current_viewport()
	im.SetNextWindowBgAlpha(0.96)
	flags: im.WindowFlags = {.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings, .NoFocusOnAppearing, .NoMouseInputs, .NoNavInputs, .NoNavFocus, .NoDocking, .AlwaysAutoResize}
	if im.Begin("##mh_odin_call_tip", nil, flags) {
		if tip.receiver != "" {
			im.TextColored(st.sig_call_fg, "%s", fmt.ctprintf("%s.%s(", tip.receiver, tip.callee))
		} else {
			im.TextColored(st.sig_call_fg, "%s", fmt.ctprintf("%s(", tip.callee))
		}
		for param, pi in tip.params {
			if pi > 0 {
				im.SameLine(0, 0)
				im.TextDisabled(", ")
			}
			im.SameLine(0, 0)
			if pi == tip.active_param {
				im.TextColored(st.sig_active_param_fg, "%s", fmt.ctprintf("[%s]", param))
			} else {
				im.TextColored(p.text_primary, "%s", fmt.ctprintf("%s", param))
			}
		}
		im.SameLine(0, 0)
		im.TextColored(st.sig_call_fg, ")")
		if ret_idx := strings.index(tip.signature, "->"); ret_idx >= 0 {
			im.SameLine(0, 5)
			im.TextColored(st.sig_return_fg, "%s", fmt.ctprintf("%s", tip.signature[ret_idx:]))
		}
	}
	im.End()
	im.PopStyleVar(3)
	im.PopStyleColor(2)
}

@(private = "file")
_studio_zoom_val :: #force_inline proc() -> f32 {
	_ensure_zoom_init()
	return _studio.code_zoom
}

@(private = "file")
_completion_kind_badge :: proc(k: Completion_Kind) -> (icon: cstring, badge: cstring, col: im.Vec4) {
	sk: thm.Studio_Symbol_Kind = .Local_Var
	switch k {
	case .Pin_Ref:   sk = .Pin_Ref
	case .Pin_Copy:  sk = .Pin_Copy
	case .Pin_Out:   sk = .Pin_Out
	case .Field:     sk = .Field
	case .Local_Var: sk = .Local_Var
	case .Hot_API:   sk = .Hot_API
	case .Procedure: sk = .Procedure
	case .Type_Sym:  sk = .Type_Sym
	case .Keyword:   sk = .Keyword
	}
	return thm.studio_symbol_visual(sk)
}

@(private = "file")
_draw_autocomplete_popup :: proc(caret_x, line_top_y, line_bottom_y: f32, items: []Autocomplete_Item, ide: ^_Surface_IDE_State) -> (placed_above: bool) {
	pop_scale := clamp(_studio_zoom_val(), 1.0, 1.35)
	im.PushFontFloat(nil, im.GetStyle().FontSizeBase * pop_scale)
	defer im.PopFont()

	p  := thm.palette()
	mon_pos, mon_size := _studio_monitor_bounds({caret_x, line_bottom_y})

	pop_w := f32(440.0) * pop_scale
	row_h := im.GetTextLineHeightWithSpacing()
	pop_h := min(f32(len(items)) * row_h + row_h + 16.0, 290.0 * pop_scale)

	pos := im.Vec2{caret_x, line_bottom_y + 4.0}
	if pos.x + pop_w > mon_pos.x + mon_size.x - 12.0 {
		pos.x = max(mon_pos.x + 12.0, mon_pos.x + mon_size.x - pop_w - 12.0)
	}
	if pos.y + pop_h > mon_pos.y + mon_size.y - 12.0 {
		pos.y = max(mon_pos.y + 12.0, line_top_y - pop_h - 4.0)
		placed_above = true
	}

	im.SetNextWindowPos(pos, .Always)
	im.SetNextWindowSize({pop_w, pop_h}, .Always)
	im.PushStyleColorImVec4(.WindowBg, p.bg_popup)
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.accent, 0.65))
	im.PushStyleVar(.WindowBorderSize, 1.2)
	im.PushStyleVar(.WindowRounding, 6.0)

	// NOTE: Never pass internal `WindowFlag.Tooltip` (bit 25) to `im.Begin()` — Dear ImGui asserts `IM_ASSERT` (`SIGABRT`)!
	widgets.pin_tooltip_to_current_viewport()
	im.SetNextWindowBgAlpha(0.98)
	flags: im.WindowFlags = {.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings, .NoFocusOnAppearing, .NoNavInputs, .NoNavFocus, .NoDocking}
	if im.Begin("##mh_odin_ac_popup", nil, flags) {
		hov := im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows | im.HoveredFlags_AllowWhenBlockedByActiveItem)
		if im.IsMouseClicked(.Left) && hov {
			ide.ac_popup_dragging = true
		}
		if !im.IsMouseDown(.Left) {
			ide.ac_popup_dragging = false
		}
		ide.ac_popup_interacting = hov || ide.ac_popup_dragging || im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows)

		for item, idx in items {
			is_sel := idx == ide.ac_selected_idx
			ic, badge, bcol := _completion_kind_badge(item.kind)
			row_min := im.GetCursorScreenPos()
			avail_w := im.GetContentRegionAvail().x

			if is_sel {
				im.DrawList_AddRectFilled(
					im.GetWindowDrawList(),
					row_min,
					{row_min.x + avail_w, row_min.y + row_h},
					im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.24)),
					3.0,
				)
				if ide.ac_nav_moved {
					im.SetScrollHereY(0.5)
					ide.ac_nav_moved = false
				}
			}

			if im.InvisibleButton(fmt.ctprintf("##ac_it_%d", idx), {avail_w, row_h}) {
				ide.ac_selected_idx     = idx
				n_ins := min(len(item.insert_text), len(ide.ac_accept_text) - 1)
				if n_ins > 0 do copy(ide.ac_accept_text[:n_ins], item.insert_text[:n_ins])
				ide.ac_accept_text[n_ins] = 0
				ide.ac_accept_len       = n_ins
				ide.ac_pending_accept   = true
				ide.next_edit_immediate = true
				ide.ac_refocus_input    = true
			}

			dl := im.GetWindowDrawList()
			im.DrawList_AddText(dl, {row_min.x + 6.0 * pop_scale, row_min.y + 1.0}, im.GetColorU32ImVec4(bcol), fmt.ctprintf("%s %s", ic, badge))
			lbl_x := row_min.x + 84.0 * pop_scale
			if item.detail != "" {
				det_c := fmt.ctprintf("%s", item.detail)
				det_w := im.CalcTextSize(det_c).x
				det_x := max(row_min.x + avail_w - det_w - 6.0 * pop_scale, row_min.x + 220.0 * pop_scale)
				im.DrawList_PushClipRect(dl, {lbl_x, row_min.y}, {max(det_x - 8.0 * pop_scale, lbl_x + 24.0), row_min.y + row_h}, true)
				im.DrawList_AddText(dl, {lbl_x, row_min.y + 1.0}, im.GetColorU32ImVec4(p.text_primary), fmt.ctprintf("%s", item.label))
				im.DrawList_PopClipRect(dl)
				im.DrawList_AddText(dl, {det_x, row_min.y + 1.0}, im.GetColorU32ImVec4(p.text_muted), det_c)
			} else {
				im.DrawList_AddText(dl, {lbl_x, row_min.y + 1.0}, im.GetColorU32ImVec4(p.text_primary), fmt.ctprintf("%s", item.label))
			}
		}
		im.Separator()
		im.TextDisabled("Tab / Enter: Accept   Up/Down: Select   Esc: Dismiss")
	}
	im.End()
	im.PopStyleVar(2)
	im.PopStyleColor(2)
	return placed_above
}

// =============================================================================
// Status Pill Helper (Shows Live Async Checker, Caret Ln/Col & Hot-Reload State)
// =============================================================================

@(private = "file")
_draw_scoped_pin_badge :: proc(pin: Scoped_Pin_Badge, show_mode_tag: bool) {
	if pin.is_output {
		ic, _, col := thm.studio_symbol_visual(.Pin_Out)
		im.TextColored(col, "%s", fmt.ctprintf("%s %s: %s", ic, pin.name, pin.odin_type))
	} else if pin.pass_mode == .By_Reference {
		ic, _, col := thm.studio_symbol_visual(.Pin_Ref)
		tag := show_mode_tag ? " (Ref)" : ""
		im.TextColored(col, "%s", fmt.ctprintf("%s %s: ^%s%s", ic, pin.name, pin.odin_type, tag))
	} else {
		ic, _, col := thm.studio_symbol_visual(.Pin_Copy)
		tag := show_mode_tag ? " (Copy)" : ""
		im.TextColored(col, "%s", fmt.ctprintf("%s %s: %s%s", ic, pin.name, pin.odin_type, tag))
	}
}

@(private = "file")
_jump_studio_to_diagnostic :: proc(d: Studio_Diagnostic) {
	if _scoped.open && _scoped.focused {
		_jump_ide_to_line(&_scoped.ide, d.line, d.column)
		return
	}
	if _emb_scoped.open && _emb_scoped.focused {
		_jump_ide_to_line(&_emb_scoped.ide, d.line, d.column)
		return
	}
	if d.file != "" && os.exists(d.file) {
		has_act := _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)
		if !has_act || !diagnostic_matches_active_file(d.file, _studio.tabs[_studio.active_tab].abs_path) {
			if open_file_in_studio(d.file, d.line) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
				_jump_to_tab_line(&_studio.tabs[_studio.active_tab], d.line, d.column)
				return
			}
		}
	}
	if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		_jump_to_tab_line(&_studio.tabs[_studio.active_tab], d.line, d.column)
	} else {
		_jump_ide_to_line(&_studio.ide, d.line, d.column)
	}
}

@(private = "file")
_cycle_next_diagnostic :: proc(snap: Checker_Snapshot, dir: int = 1) {
	if len(snap.diagnostics) == 0 do return
	ordered := make([dynamic]Studio_Diagnostic, 0, len(snap.diagnostics), context.temp_allocator)
	for d in snap.diagnostics do if !d.is_warning do append(&ordered, d)
	for d in snap.diagnostics do if  d.is_warning do append(&ordered, d)
	if len(ordered) == 0 do return
	n := len(ordered)
	idx := ((_studio.diag_cycle_idx % n) + n) % n
	_jump_studio_to_diagnostic(ordered[idx])
	_studio.diag_cycle_idx = ((idx + (dir >= 0 ? 1 : -1)) % n + n) % n
}

@(private = "file")
_draw_checker_and_hot_pills :: proc(snap: Checker_Snapshot) {
	p := thm.palette()
	has_hard_err := snap.stage == .Syntax_Error || snap.stage == .Compiler_Error
	has_warn := false
	for d in snap.diagnostics {
		if !d.is_warning do has_hard_err = true
		else do has_warn = true
	}

	chk_col := p.text_muted
	pill_ic := icons.ICON_MD_CHECK
	switch snap.stage {
	case .Idle, .Pending_Syntax:
		chk_col = has_warn ? p.status_warning : p.text_muted
		pill_ic = has_warn ? icons.ICON_MD_WARNING : icons.ICON_MD_SYNC
	case .Syntax_OK, .Compiler_OK:
		chk_col = (has_hard_err ? p.status_error : (has_warn ? p.status_warning : p.status_success))
		pill_ic = (has_hard_err ? icons.ICON_MD_ERROR : (has_warn ? icons.ICON_MD_WARNING : icons.ICON_MD_CHECK))
	case .Running_Compiler:
		chk_col = p.status_info
		pill_ic = icons.ICON_MD_SYNC
	case .Syntax_Error, .Compiler_Error:
		chk_col = p.status_error
		pill_ic = icons.ICON_MD_ERROR
	}
	lbl_txt := snap.summary_label != "" ? snap.summary_label : "Idle (Typecheck ready)"
	if len(snap.diagnostics) > 0 {
		im.PushStyleColorImVec4(.Button, thm.with_alpha(chk_col, 0.22))
		im.PushStyleColorImVec4(.Text, chk_col)
		if im.SmallButton(fmt.ctprintf("%s %s##chk_pill_btn", pill_ic, lbl_txt)) {
			_cycle_next_diagnostic(snap, 1)
		}
		im.PopStyleColor(2)
		first_d := snap.diagnostics[0]
		for d in snap.diagnostics {
			if !d.is_warning {
				first_d = d
				break
			}
		}
		widgets.tooltip(fmt.ctprintf("Click or press F2 to jump to next diagnostic (%d total):\n%s:%d:%d — %s\n\nRead-only background typecheck (`odin check`). Does NOT build .dll/.exe.", len(snap.diagnostics), filepath.base(first_d.file), first_d.line, first_d.column, first_d.message))
	} else {
		im.TextColored(chk_col, "%s", fmt.ctprintf("%s %s", pill_ic, lbl_txt))
		widgets.tooltip("Read-only background syntax/typecheck (`odin check`). Does NOT build .dll/.exe or overwrite hot cartridges.\nFull hot-swap compilation only runs when you click Play / Save+Rebuild / F7.")
	}

	hot_st, hot_gen, hot_ms, hot_msg, _ := engine.hot_cartridge_status()
	if hot_st != .Idle && hot_msg != "" {
		im.SameLine()
		im.TextDisabled("|")
		im.SameLine()
		hcol := p.status_info
		if hot_st == .Swapped_OK do hcol = p.status_success
		else if hot_st == .Compile_Failed do hcol = p.status_error
		else if hot_st == .Schema_Changed do hcol = p.status_warning
		_ = hot_gen
		_ = hot_ms
		im.TextColored(hcol, "%s", fmt.ctprintf("%s %s", icons.ICON_MD_PLAY_ARROW, hot_msg))
	}
}

@(private = "file")
_draw_ide_footer_telemetry :: proc(ide: ^_Surface_IDE_State) {
	sel_len := abs(ide.sel_end - ide.sel_start)
	if sel_len > 0 {
		im.TextDisabled("%s", fmt.ctprintf("Ln %d, Col %d (%d selected)  |  Ctrl+Space: Autocomplete  |  Ctrl+F: Find  |  Ctrl+/: Comment  |  Ctrl+Wheel: Zoom (%d%%)", max(ide.caret_line, 1), max(ide.caret_col, 1), sel_len, int(math.round(_studio_zoom_val() * 100.0))))
	} else {
		im.TextDisabled("%s", fmt.ctprintf("Ln %d, Col %d  |  Ctrl+Space: Autocomplete  |  Ctrl+F: Find  |  Ctrl+/: Comment  |  Ctrl+Wheel: Zoom (%d%%)", max(ide.caret_line, 1), max(ide.caret_col, 1), int(math.round(_studio_zoom_val() * 100.0))))
	}
}

// =============================================================================
// 1. Scoped Function-Node Popup Micro-IDE (Call once per frame from Editor Root / Graph)
// =============================================================================

@(private = "file")
_toggle_scoped_enlarge :: proc() {
	_scoped.enlarged          = !_scoped.enlarged
	_scoped.apply_enlarge_pos = true
}

@(private = "file")
_draw_using_spaces_popup :: proc(
	popup_id:   cstring,
	search_id:  cstring,
	search_buf: []byte,
	sc:         ^_Scoped_Popup_State = nil,
	tab:        ^_Tab_Doc            = nil,
	ide:        ^_Surface_IDE_State  = nil,
) {
	if !im.BeginPopup(popup_id) do return
	defer im.EndPopup()

	p := thm.palette()
	is_scoped := sc != nil
	if is_scoped {
		im.TextColored(p.accent, icons.ICON_MD_CODE + " Blueprint Using & Spaces")
		sr := widgets.search_bar(search_buf, widgets.Search_Bar_Opts{
			id    = search_id,
			hint  = "Search math, linalg, self, ease...",
			mode  = .Popup,
			width = 260,
		})
		if sr.escape_close {
			im.CloseCurrentPopup()
			return
		}
		terms := widgets.search_terms(sr.query)
		im.Separator()
		for spec in USING_SPACE_CATALOG {
			if !spec.hot_safe do continue
			if len(terms) > 0 && !widgets.search_match(fmt.tprintf("%s %s %s", spec.label, spec.description, spec.pkg_alias), terms) {
				continue
			}
			active := sc.using_query_cb != nil && sc.using_query_cb(spec.id, sc.commit_user_ptr)
			if im.MenuItem(fmt.ctprintf("%s %s", active ? icons.ICON_MD_CHECK : " ", spec.label)) && sc.using_toggle_cb != nil {
				new_sig := sc.using_toggle_cb(spec.id, sc.commit_user_ptr)
				if new_sig != "" {
					prev_a := context.allocator
					context.allocator = runtime.default_allocator()
					delete(sc.signature_banner)
					sc.signature_banner = strings.clone(new_sig)
					context.allocator = prev_a
				}
				_notify_buffer_edited(_c_buf_string(sc.buf[:]), !sc.is_full_decl, sc.backing_pkg_dir)
			}
			widgets.tooltip(fmt.ctprintf("%s", spec.description))
		}
		return
	}

	if tab == nil do return
	is_hot_script := strings.contains(tab.pkg_dir, "hot_scripts")
	src_cur := _c_buf_string(tab.buf)

	im.TextColored(p.accent, icons.ICON_MD_CODE + " Import & Using Spaces")
	sr := widgets.search_bar(search_buf, widgets.Search_Bar_Opts{
		id    = search_id,
		hint  = "Search engine, input_manager, math, physics3d...",
		mode  = .Popup,
		width = 300,
	})
	if sr.escape_close {
		im.CloseCurrentPopup()
		return
	}
	terms := widgets.search_terms(sr.query)
	unused_now := detect_unused_odin_imports(src_cur, context.temp_allocator)
	if len(unused_now) > 0 {
		if im.SmallButton(fmt.ctprintf("Comment Unused Imports (%d)", len(unused_now))) {
			if updated, cnt := comment_out_unused_odin_imports(src_cur, context.temp_allocator); cnt > 0 {
				im.ClearActiveID()
				_copy_to_c_buf_grow(&tab.buf, updated, STUDIO_MIN_BUF_CAP)
				tab.dirty = true
				s_after := _c_buf_string(tab.buf)
				cpos := ide != nil ? min(ide.cursor_pos, len(s_after)) : 0
				code_undo_record_edit(&tab.undo, s_after, cpos, im.GetTime(), true)
				_notify_buffer_edited(s_after, false, tab.pkg_dir)
			}
		}
		widgets.tooltip("Comment out unused import lines (shown grayed out) so Odin check compiles cleanly")
	}
	im.Separator()

	for spec in USING_SPACE_CATALOG {
		if spec.id == "self" do continue
		if len(terms) > 0 && !widgets.search_match(fmt.tprintf("%s %s %s", spec.label, spec.description, spec.pkg_alias), terms) {
			continue
		}
		using_line := strings.has_prefix(spec.id, "using_") ? fmt.tprintf("using %s", spec.pkg_alias) : ""
		already_in := (spec.import_line != "" && strings.contains(src_cur, spec.import_line)) && (using_line == "" || strings.contains(src_cur, using_line))
		blocked_in_hot := is_hot_script && !spec.hot_safe
		if blocked_in_hot do im.BeginDisabled()
		lbl := blocked_in_hot \
			? fmt.ctprintf("  %s (Plugin/Engine files only)", spec.label) \
			: fmt.ctprintf("%s %s", already_in ? icons.ICON_MD_CHECK : "+", spec.label)
		if im.MenuItem(lbl) && !already_in {
			if new_src, changed := _inject_using_space_into_full_file(src_cur, spec, context.temp_allocator); changed {
				im.ClearActiveID()
				_copy_to_c_buf_grow(&tab.buf, new_src, STUDIO_MIN_BUF_CAP)
				tab.dirty = true
				s_after := _c_buf_string(tab.buf)
				cpos := ide != nil ? ide.cursor_pos : 0
				code_undo_record_edit(&tab.undo, s_after, cpos, im.GetTime(), true)
				_notify_buffer_edited(s_after, false, tab.pkg_dir)
			}
		}
		if blocked_in_hot do im.EndDisabled()
		widgets.tooltip(fmt.ctprintf("%s", spec.description))
	}
}

@(private = "file")
_draw_scoped_using_chip_bar :: proc(sc: ^_Scoped_Popup_State, popup_id: cstring, search_id: cstring) {
	if sc == nil || !sc.is_graph_node || sc.using_toggle_cb == nil || sc.using_query_cb == nil do return
	p := thm.palette()
	if im.SmallButton(fmt.ctprintf("%s + Using / Spaces##btn_%s", icons.ICON_MD_ADD, popup_id)) {
		im.OpenPopup(popup_id)
	}
	widgets.tooltip("Select Odin `using` scopes and packages (`using self` Blueprint vars, `using math`, `using linalg`, `ease`, `rand`) without guessing imports!")

	for spec in USING_SPACE_CATALOG {
		if !spec.hot_safe do continue
		if sc.using_query_cb(spec.id, sc.commit_user_ptr) {
			im.SameLine()
			im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.24))
			if im.SmallButton(fmt.ctprintf("%s %s##uchip_%s_%s", icons.ICON_MD_CHECK, spec.label, spec.id, popup_id)) {
				new_sig := sc.using_toggle_cb(spec.id, sc.commit_user_ptr)
				if new_sig != "" {
					prev_a := context.allocator
					context.allocator = runtime.default_allocator()
					delete(sc.signature_banner)
					sc.signature_banner = strings.clone(new_sig)
					context.allocator = prev_a
				}
				_notify_buffer_edited(_c_buf_string(sc.buf[:]), !sc.is_full_decl, sc.backing_pkg_dir)
			}
			im.PopStyleColor()
			widgets.tooltip(fmt.ctprintf("%s (Click chip to toggle)", spec.description))
		}
	}

	_draw_using_spaces_popup(popup_id, search_id, sc.using_search_buf[:], sc = sc)
}

@(private = "file")
_draw_surface_diagnostics_panel :: proc(
	id_prefix:        string,
	diags:            []Studio_Diagnostic,
	ide:              ^_Surface_IDE_State,
	tab:              ^_Tab_Doc = nil,
	hot_stderr:       string    = "",
	stderr_height:    f32       = 68.0,
	show_file_in_loc: bool      = false,
	allow_open_file:  bool      = false,
) {
	st := thm.studio_tokens()
	for d, di in diags {
		col := d.is_warning ? st.diag_warn_fg : st.diag_err_fg
		sev_ic := cstring(d.is_warning ? icons.ICON_MD_WARNING : icons.ICON_MD_ERROR)
		sev_lb := d.is_warning ? "Warn" : "Error"
		loc_str := show_file_in_loc \
			? fmt.tprintf("%s:%d:%d", filepath.base(d.file), d.line, d.column) \
			: fmt.tprintf("Line %d:%d", d.line, d.column)
		if jumped, _ := widgets.diagnostic_row(fmt.tprintf("%s_%d", id_prefix, di), col, sev_ic, sev_lb, loc_str, d.message); jumped {
			if allow_open_file && d.file != "" && os.exists(d.file) && (tab == nil || !diagnostic_matches_active_file(d.file, tab.abs_path)) {
				if open_file_in_studio(d.file, d.line) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
					_jump_to_tab_line(&_studio.tabs[_studio.active_tab], d.line, d.column)
				}
			} else if tab != nil {
				_jump_to_tab_line(tab, d.line, d.column)
			} else if ide != nil {
				_jump_ide_to_line(ide, d.line, d.column)
			}
		}
	}
	if hot_stderr != "" {
		_ = widgets.copyable_code_block(fmt.tprintf("##%s_stderr", id_prefix), hot_stderr, "Hot Cartridge Build Output", stderr_height)
	}
}

@(private = "file")
_scoped_set_status_note :: proc(msg: string, is_err: bool) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _scoped.status_note != "" do delete(_scoped.status_note)
	_scoped.status_note   = msg != "" ? strings.clone(msg) : ""
	_scoped.status_is_err = is_err
}

@(private = "file")
_default_literal_for_odin_type :: proc(t_expr: string, def_expr: string, allocator := context.temp_allocator) -> string {
	if strings.trim_space(def_expr) != "" do return strings.clone(strings.trim_space(def_expr), allocator)
	t := strings.trim_space(t_expr)
	if strings.has_prefix(t, "^") || strings.has_prefix(t, "[]") || t == "rawptr" || t == "cstring" {
		return strings.clone("nil", allocator)
	}
	switch t {
	case "bool":
		return strings.clone("false", allocator)
	case "f32", "f64":
		return strings.clone("0.0", allocator)
	case "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "int", "uint", "byte":
		return strings.clone("0", allocator)
	case "string":
		return strings.clone("\"\"", allocator)
	case "[2]f32":
		return strings.clone("{0, 0}", allocator)
	case "[3]f32":
		return strings.clone("{0, 0, 0}", allocator)
	case "[4]f32":
		return strings.clone("{0, 0, 0, 0}", allocator)
	}
	return strings.clone("{}", allocator)
}

@(private = "file")
_scoped_walk_writable_scripts :: proc(dir: string, out: ^[dynamic]string, seen: ^map[string]bool, depth: int) {
	if depth > 4 || dir == "" || !os.is_dir(dir) do return
	h, err := os.open(dir)
	if err != nil do return
	entries, rerr := os.read_dir(h, -1, context.temp_allocator)
	os.close(h)
	if rerr != nil do return

	for e in entries {
		lo_nm := strings.to_lower(e.name, context.temp_allocator)
		if strings.has_prefix(e.name, ".") || lo_nm == "external" || lo_nm == "library" || lo_nm == "builds" || lo_nm == "void_odin" {
			continue
		}
		full, _ := filepath.join({dir, e.name}, context.temp_allocator)
		norm := resolve_workspace_path(full, context.temp_allocator)
		if e.type == .Directory || (e.type == .Symlink && os.is_dir(full)) {
			_scoped_walk_writable_scripts(full, out, seen, depth + 1)
			continue
		}
		if !(strings.has_suffix(lo_nm, ".odin") || strings.has_suffix(lo_nm, ".bodin")) do continue
		if is_protected_readonly_script_path(norm) do continue
		k := strings.to_lower(norm, context.temp_allocator)
		if !seen[k] {
			seen[k] = true
			append(out, norm)
		}
	}
}

@(private = "file")
_scoped_focus_refactor_site :: proc(site_idx: int) {
	if site_idx < 0 || site_idx >= len(_scoped.refactor_sites) do return
	_scoped.refactor_active_idx = site_idx
	for &rf in _scoped.refactor_files {
		rf.ide.conflict_line      = 0
		rf.ide.conflict_col_start = 0
		rf.ide.conflict_col_end   = 0
	}
	site := _scoped.refactor_sites[site_idx]
	if site.file_idx >= 0 && site.file_idx < len(_scoped.refactor_files) {
		rf := &_scoped.refactor_files[site.file_idx]
		rf.scroll_line            = site.line
		rf.ide.cmd_jump_line      = site.line
		rf.ide.cmd_jump_col       = max(site.col, 1)
		rf.ide.conflict_line      = site.line
		rf.ide.conflict_col_start = max(site.col, 1)
		rf.ide.conflict_col_end   = max(site.end_col, site.col + 4)
	}
}

@(private = "file")
_scoped_scan_refactor_impact :: proc(new_decl: string) -> (sig_valid: bool, site_count: int) {
	new_name, new_params, new_results, _, parsed_ok := parse_odin_proc_decl_header(new_decl, context.temp_allocator)
	if !parsed_ok {
		_scoped_set_status_note("Invalid Odin procedure declaration syntax.", true)
		return false, 0
	}
	_scoped_set_status_note("", false)
	new_key := _proc_sig_fingerprint(new_name, new_params, new_results, context.temp_allocator)
	if new_key == _scoped.orig_sig_key {
		return true, 0
	}

	_clear_scoped_refactor(&_scoped)
	orig_param_count := 0
	if orig_s, o_ok := extract_full_odin_procedure_decl(_scoped.full_file_cache, _scoped.orig_proc_name, context.temp_allocator); o_ok {
		orig_param_count = len(orig_s.params)
		destroy_proc_full_decl_slice(&orig_s, context.temp_allocator)
	}
	if len(new_params) > orig_param_count && len(new_params) > 0 {
		last_p := new_params[len(new_params) - 1]
		def_s := _default_literal_for_odin_type(last_p.type_expr, last_p.default_expr, context.temp_allocator)
		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		_scoped.pending_default_arg = strings.clone(def_s)
		context.allocator = prev_alloc
	}

	spliced_backing, sp_ok := splice_full_odin_procedure_decl(_scoped.full_file_cache, _scoped.orig_proc_name, new_decl, context.temp_allocator)
	if !sp_ok do spliced_backing = _scoped.full_file_cache

	cand_paths := make([dynamic]string, 0, 24, context.temp_allocator)
	seen_paths := make(map[string]bool, 32, context.temp_allocator)
	if _scoped.backing_file_abs != "" {
		norm_b := resolve_workspace_path(_scoped.backing_file_abs, context.temp_allocator)
		seen_paths[strings.to_lower(norm_b, context.temp_allocator)] = true
		append(&cand_paths, norm_b)
	}
	for &t in _studio.tabs {
		if t.abs_path == "" || is_protected_readonly_script_path(t.abs_path) do continue
		norm_t := resolve_workspace_path(t.abs_path, context.temp_allocator)
		kt := strings.to_lower(norm_t, context.temp_allocator)
		if !seen_paths[kt] {
			seen_paths[kt] = true
			append(&cand_paths, norm_t)
		}
	}
	if proj_root := engine.active_project_root(); proj_root != "" {
		_scoped_walk_writable_scripts(proj_root, &cand_paths, &seen_paths, 0)
	}
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	for rel_r in ([2]string{"assets/scripts", "haati/hot_scripts"}) {
		abs_r, _ := filepath.join({repo_root, rel_r}, context.temp_allocator)
		_scoped_walk_writable_scripts(abs_r, &cand_paths, &seen_paths, 0)
	}

	backing_norm := resolve_workspace_path(_scoped.backing_file_abs, context.temp_allocator)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	for fp in cand_paths {
		src_raw := ""
		if strings.equal_fold(fp, backing_norm) {
			src_raw = spliced_backing
		} else if tab_src, is_open := get_open_tab_text(fp, context.temp_allocator); is_open {
			src_raw = tab_src
		} else if raw, rerr := os.read_entire_file(fp, context.temp_allocator); rerr == nil {
			src_raw = string(raw)
		}
		if src_raw == "" || !strings.contains(src_raw, _scoped.orig_proc_name) do continue

		norm_tabs, _ := strings.replace_all(src_raw, "\t", "    ", context.temp_allocator)
		clean_src, _ := strings.replace_all(norm_tabs, "\r\n", "\n", context.temp_allocator)
		sites := find_odin_proc_call_sites(clean_src, fp, _scoped.orig_proc_name, context.temp_allocator)
		if len(sites) == 0 do continue

		rf := _Refactor_File_Buf{
			file_abs   = strings.clone(fp),
			file_title = strings.clone(filepath.base(fp)),
			pkg_dir    = strings.clone(_infer_pkg_dir(fp, context.temp_allocator)),
			ide        = {ac_dismissed_pos = -1, cmd_jump_offset = -1},
			is_bodin   = strings.has_suffix(strings.to_lower(fp, context.temp_allocator), ".bodin"),
		}
		_copy_to_c_buf_grow(&rf.buf, clean_src, STUDIO_MIN_BUF_CAP)
		code_undo_reset(&rf.undo, _c_buf_string(rf.buf), 0)
		f_idx := len(_scoped.refactor_files)
		append(&_scoped.refactor_files, rf)

		for cs in sites {
			append(&_scoped.refactor_sites, _Refactor_Site_Ref{
				file_idx    = f_idx,
				line        = cs.line,
				col         = cs.col,
				end_col     = cs.end_col,
				before_line = strings.clone(cs.line_text),
				reviewed    = false,
			})
		}
	}

	if len(_scoped.refactor_sites) > 0 {
		_scoped.refactor_active = true
		_scoped_focus_refactor_site(0)
		_push_scoped_checker_overlays(spliced_backing)
		submit_async_check(spliced_backing, false, _scoped.backing_pkg_dir, true, _scoped.backing_file_abs)
		return true, len(_scoped.refactor_sites)
	}
	return true, 0
}

@(private = "file")
_scoped_autofill_default_args :: proc() {
	decl_now := _c_buf_string(_scoped.buf)
	new_name, new_params, _, _, parsed_ok := parse_odin_proc_decl_header(decl_now, context.temp_allocator)
	if !parsed_ok do return

	orig_param_count := 0
	if orig_s, o_ok := extract_full_odin_procedure_decl(_scoped.full_file_cache, _scoped.orig_proc_name, context.temp_allocator); o_ok {
		orig_param_count = len(orig_s.params)
		destroy_proc_full_decl_slice(&orig_s, context.temp_allocator)
	}
	has_new_param := _scoped.pending_default_arg != "" && len(new_params) > orig_param_count
	has_rename    := new_name != "" && new_name != _scoped.orig_proc_name
	if !has_new_param && !has_rename do return

	for &rf in _scoped.refactor_files {
		cur := _c_buf_string(rf.buf)
		sites := find_odin_proc_call_sites(cur, rf.file_abs, _scoped.orig_proc_name, context.temp_allocator)
		if len(sites) == 0 do continue

		patched := cur
		did_edit := false
		for si := len(sites) - 1; si >= 0; si -= 1 {
			cs := sites[si]
			if cs.call_start_off < 0 || cs.call_end_off <= cs.call_start_off || cs.call_end_off > len(patched) do continue
			orig_call := patched[cs.call_start_off:cs.call_end_off]
			lp := strings.index_byte(orig_call, '(')
			if lp < 0 || orig_call[len(orig_call) - 1] != ')' do continue

			callee_part := orig_call[:lp]
			args_inner  := orig_call[lp + 1 : len(orig_call) - 1]
			changed_this := false
			if has_rename && strings.has_suffix(callee_part, _scoped.orig_proc_name) {
				callee_part = strings.concatenate({callee_part[:len(callee_part) - len(_scoped.orig_proc_name)], new_name}, context.temp_allocator)
				changed_this = true
			}
			if has_new_param && cs.arg_count == orig_param_count {
				tr_a := strings.trim_right_space(args_inner)
				sep := len(tr_a) > 0 && !strings.has_suffix(tr_a, ",") ? ", " : ""
				args_inner = strings.concatenate({tr_a, sep, _scoped.pending_default_arg}, context.temp_allocator)
				changed_this = true
			}
			if changed_this {
				new_call := strings.concatenate({callee_part, "(", args_inner, ")"}, context.temp_allocator)
				patched = strings.concatenate({patched[:cs.call_start_off], new_call, patched[cs.call_end_off:]}, context.temp_allocator)
				did_edit = true
			}
		}
		if did_edit {
			_copy_to_c_buf_grow(&rf.buf, patched, STUDIO_MIN_BUF_CAP)
			rf.dirty                  = true
			rf.ide.conflict_line      = 0
			rf.ide.conflict_col_start = 0
			rf.ide.conflict_col_end   = 0
			s_rf := _c_buf_string(rf.buf)
			_arm_ide_restore(&rf.ide, s_rf, 0)
			code_undo_record_edit(&rf.undo, s_rf, 0, im.GetTime(), true)
		}
	}
	for &rs in _scoped.refactor_sites {
		rs.reviewed = true
	}
	_notify_scoped_popup_edited(true)
}

@(private = "file")
_scoped_commit_all_files_to_disk :: proc(updated_backing: string, new_proc_name: string, new_sig_key: string, trigger_hot_swap: bool) {
	body_now := _c_buf_string(_scoped.buf)
	backing_norm := resolve_workspace_path(_scoped.backing_file_abs, context.temp_allocator)
	backing_written_from_rf := false

	for &rf in _scoped.refactor_files {
		if !rf.dirty && !strings.equal_fold(resolve_workspace_path(rf.file_abs, context.temp_allocator), backing_norm) {
			continue
		}
		rf_src := _c_buf_string(rf.buf)
		if strings.equal_fold(resolve_workspace_path(rf.file_abs, context.temp_allocator), backing_norm) {
			if spliced_rf, sok := splice_full_odin_procedure_decl(rf_src, _scoped.orig_proc_name, body_now, context.temp_allocator); sok {
				rf_src = spliced_rf
			} else if !rf.dirty {
				rf_src = updated_backing
			}
			backing_written_from_rf = true
		}
		disk_src := format_studio_buffer_for_disk(rf_src, detect_odin_hard_tabs(rf_src), context.temp_allocator)
		if os.write_entire_file(rf.file_abs, transmute([]u8)disk_src) == nil {
			reload_file_tab_from_disk(rf.file_abs)
		}
	}

	final_backing := updated_backing
	if !backing_written_from_rf {
		disk_backing := format_studio_buffer_for_disk(updated_backing, detect_odin_hard_tabs(_scoped.full_file_cache), context.temp_allocator)
		if os.write_entire_file(_scoped.backing_file_abs, transmute([]u8)disk_backing) != nil {
			_scoped_set_status_note("Failed to write procedure changes to disk.", true)
			return
		}
		reload_file_tab_from_disk(_scoped.backing_file_abs)
		final_backing = disk_backing
	}

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	delete(_scoped.full_file_cache)
	_scoped.full_file_cache = strings.clone(final_backing)
	if new_proc_name != "" {
		delete(_scoped.backing_proc_name)
		delete(_scoped.orig_proc_name)
		delete(_scoped.signature_banner)
		_scoped.backing_proc_name = strings.clone(new_proc_name)
		_scoped.orig_proc_name    = strings.clone(new_proc_name)
		_scoped.signature_banner  = strings.clone(new_proc_name)
	}
	if new_sig_key != "" {
		delete(_scoped.orig_sig_key)
		_scoped.orig_sig_key = strings.clone(new_sig_key)
	}
	context.allocator = prev_alloc

	_clear_scoped_refactor(&_scoped)
	_scoped.dirty = false
	_scoped_set_status_note("", false)
	_sync_dirty_checker_overlays()
	_notify_scoped_popup_edited(true)
	if trigger_hot_swap {
		if strings.contains(_scoped.backing_pkg_dir, "hot_scripts") {
			engine.hot_cartridge_trigger_async_build(false)
		} else if _studio.relaunch_cb != nil {
			_studio.relaunch_cb()
		}
	}
}

@(private = "file")
_commit_scoped_popup :: proc(trigger_hot_swap: bool) {
	if _scoped.read_only do return
	body_now := _c_buf_string(_scoped.buf)
	if _scoped.is_graph_node {
		if _scoped.is_full_decl && _scoped.full_commit_cb != nil {
			ok, err_msg := _scoped.full_commit_cb(_scoped.node_uid, body_now, trigger_hot_swap, _scoped.commit_user_ptr)
			if !ok {
				_scoped_set_status_note(err_msg != "" ? err_msg : "Failed to parse procedure declaration.", true)
				return
			}
			_scoped_set_status_note("", false)
			_scoped.dirty = false
			return
		}
		if _scoped.commit_cb != nil {
			_scoped.commit_cb(_scoped.node_uid, body_now, trigger_hot_swap, _scoped.commit_user_ptr)
		}
		_scoped.dirty = false
		return
	}

	if _scoped.backing_file_abs != "" && _scoped.backing_proc_name != "" {
		if _scoped.is_full_decl {
			new_name, new_params, new_results, _, parsed_ok := parse_odin_proc_decl_header(body_now, context.temp_allocator)
			if !parsed_ok {
				_scoped_set_status_note("Fix procedure declaration syntax before committing.", true)
				return
			}
			new_key := _proc_sig_fingerprint(new_name, new_params, new_results, context.temp_allocator)
			updated_full, sp_ok := splice_full_odin_procedure_decl(_scoped.full_file_cache, _scoped.orig_proc_name, body_now, context.temp_allocator)
			if !sp_ok {
				_scoped_set_status_note("Could not match procedure declaration in backing file.", true)
				return
			}
			if !_scoped.refactor_active {
				_, hit_cnt := _scoped_scan_refactor_impact(body_now)
				if hit_cnt > 0 {
					return // Rider-style Call-Site Impact Review Queue opened in RAM; await Commit All
				}
			}
			_scoped_commit_all_files_to_disk(updated_full, new_name, new_key, trigger_hot_swap)
			return
		}

		if updated_full, ok := splice_odin_procedure_body(_scoped.full_file_cache, _scoped.backing_proc_name, body_now, context.temp_allocator); ok {
			if os.write_entire_file(_scoped.backing_file_abs, transmute([]u8)updated_full) == nil {
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				delete(_scoped.full_file_cache)
				_scoped.full_file_cache = strings.clone(updated_full)
				context.allocator = prev_alloc
				_scoped.dirty = false
				_notify_buffer_edited(body_now, true, _scoped.backing_pkg_dir, true)
				if trigger_hot_swap {
					if strings.contains(_scoped.backing_pkg_dir, "hot_scripts") {
						engine.hot_cartridge_trigger_async_build(false)
					} else if _studio.relaunch_cb != nil {
						_studio.relaunch_cb()
					}
				}
			}
		}
	}
}

draw_scoped_node_popup :: proc() {
	if !_scoped.open do return

	p  := thm.palette()
	vp := im.GetMainViewport()
	max_w := max(vp.WorkSize.x * 0.85, 560.0)
	max_h := max(vp.WorkSize.y * 0.85, 380.0)

	if _scoped.just_opened {
		im.SetNextWindowSize({min(880.0, max_w), min(580.0, max_h)}, .FirstUseEver)
		im.SetNextWindowPos({vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}, .Appearing, {0.5, 0.5})
		_scoped.just_opened = false
	}

	// Apply Smart Enlarge (`92%`), Restore, OR Coupled `Ctrl+Wheel` Resize (`<= 85%` work rect)!
	if _scoped.apply_enlarge_pos {
		_scoped.apply_enlarge_pos = false
		if _scoped.enlarged {
			im.SetNextWindowPos({vp.Pos.x + vp.Size.x * 0.04, vp.Pos.y + vp.Size.y * 0.04}, .Always)
			im.SetNextWindowSize({vp.Size.x * 0.92, vp.Size.y * 0.92}, .Always)
		} else if _scoped.has_saved_rect {
			im.SetNextWindowPos(_scoped.saved_pos, .Always)
			im.SetNextWindowSize(_scoped.saved_size, .Always)
		} else {
			im.SetNextWindowPos({vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}, .Always, {0.5, 0.5})
			im.SetNextWindowSize({min(880.0, max_w), min(580.0, max_h)}, .Always)
		}
	} else if _scoped.apply_wheel_resize {
		_scoped.apply_wheel_resize = false
		if !_scoped.enlarged && _scoped.has_saved_rect {
			im.SetNextWindowSize({clamp(_scoped.saved_size.x, 560.0, max_w), clamp(_scoped.saved_size.y, 380.0, max_h)}, .Always)
		}
	}

	ro_tag := _scoped.read_only ? " [Read-Only]" : ""
	win_title := fmt.ctprintf("%s Scoped Odin Micro-IDE — %s%s%s###mh_scoped_node_ide", icons.ICON_MD_CODE, _scoped.title, ro_tag, (_scoped.dirty && !_scoped.read_only) ? " *" : "")
	open_flag := _scoped.open
	_scoped.focused = false
	if im.Begin(win_title, &open_flag, {.NoCollapse}) {
		_scoped.focused = im.IsWindowFocused({.RootWindow, .ChildWindows})
		if !_scoped.enlarged {
			_scoped.saved_pos      = im.GetWindowPos()
			_scoped.saved_size     = im.GetWindowSize()
			_scoped.has_saved_rect = true
		}

		if _scoped.focused && im.IsKeyPressed(.F11, false) {
			_toggle_scoped_enlarge()
		}

		snap := read_checker_snapshot(context.temp_allocator)
		zoom_before := _studio_zoom_val()

		if _scoped.read_only {
			im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_warning, 0.22))
			im.PushStyleColorImVec4(.Text, p.status_warning)
			im.SmallButton(fmt.ctprintf("%s READ-ONLY ENGINE SOURCE — Look & Copy Only##ro_badge", icons.ICON_MD_LOCK))
			im.PopStyleColor(2)

			im.SameLine()
			if im.Button(fmt.ctprintf("%s Copy as Text", icons.ICON_MD_CONTENT_COPY)) {
				im.SetClipboardText(fmt.ctprintf("%s", _c_buf_string(_scoped.buf)))
				_scoped_set_status_note("Copied Odin code to clipboard.", false)
			}

			if _scoped.clone_cb != nil {
				im.SameLine()
				im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
				if im.Button(fmt.ctprintf("%s Clone as Editable Proc in .bodin", icons.ICON_MD_CONTENT_COPY)) {
					src_txt := _c_buf_string(_scoped.buf)
					cb := _scoped.clone_cb
					uptr := _scoped.clone_user_ptr
					open_flag = false
					cb(src_txt, uptr)
				}
				im.PopStyleColor()
				widgets.tooltip("Copy into your writable Blueprint script as an editable `@(bp_node)` / Odin_Function_Node")
			}

			im.SameLine()
			_draw_zoom_pill_controls("scoped")
		} else {
			can_apply := snap.stage != .Syntax_Error
			if !can_apply do im.BeginDisabled()
			im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
			if im.Button(fmt.ctprintf("%s Apply & Hot-Swap (F7)", icons.ICON_MD_PLAY_ARROW)) || (_scoped.focused && im.IsKeyPressed(.F7, false)) {
				_commit_scoped_popup(true)
			}
			im.PopStyleColor()
			if !can_apply do im.EndDisabled()
			widgets.tooltip("Validate changes, review any affected call sites, bake, and hot-swap!")

			im.SameLine()
			if im.Button(fmt.ctprintf("%s Save (Ctrl+S)", icons.ICON_MD_SAVE)) || (_scoped.focused && im.GetIO().KeyCtrl && im.IsKeyPressed(.S, false)) {
				_commit_scoped_popup(false)
			}
			widgets.tooltip("Apply changes without triggering a DLL build yet")

			im.SameLine()
			_draw_undo_redo_buttons(&_scoped.undo, &_scoped.buf, &_scoped.ide, &_scoped.dirty, _scoped.backing_pkg_dir, !_scoped.is_full_decl, "scoped")

			im.SameLine()
			if im.Button(fmt.ctprintf("%s Find (Ctrl+F)", icons.ICON_MD_SEARCH)) {
				_scoped.ide.find_open       = !_scoped.ide.find_open
				_scoped.ide.find_focus_next = _scoped.ide.find_open
			}
			widgets.tooltip("Toggle inline Find & Replace bar (`Ctrl+F`)")

			im.SameLine()
			if im.Button(fmt.ctprintf("%s Snippets v", icons.ICON_MD_CODE)) {
				im.OpenPopup("##scoped_snippets_pop")
			}
			widgets.tooltip("Insert common Haati Odin hot-script snippets at the buffer end")
			if im.BeginPopup("##scoped_snippets_pop") {
				snippets := [5]struct{ lbl, code: string }{
					{"pos_ref^ (Mutate Entity Position)", "if p := hot.pos_ref(api, self); p != nil { p.y += dt }\n"},
					{"bind_action (Input Delegate)",       "hot.bind_action(api, self, \"Jump\", .Pressed, 0, true, \"On_Jump\")\n"},
					{"damp_vec3 (Exponential Smooth)",     "hot.damp_vec3(cur, target, 10.0, dt)"},
					{"sin wave (Oscillator)",              "math.sin(phase) * amp"},
					{"set_timescale (Slow-Mo)",            "hot.set_object_timescale(api, self, 0.25)\n"},
				}
				for sn, si in snippets {
					if im.MenuItem(fmt.ctprintf("%s##snip_m_%d", sn.lbl, si)) {
						cur := _c_buf_string(_scoped.buf)
						sep := len(cur) > 0 && !strings.has_suffix(cur, "\n") ? "\n" : ""
						_copy_to_c_buf_grow(&_scoped.buf, strings.concatenate({cur, sep, sn.code}, context.temp_allocator), SCOPED_MIN_BUF_CAP)
						_scoped.dirty = true
						s_after := _c_buf_string(_scoped.buf)
						code_undo_record_edit(&_scoped.undo, s_after, len(s_after), im.GetTime(), true)
						_notify_scoped_popup_edited(false)
					}
				}
				im.EndPopup()
			}

			im.SameLine()
			_draw_zoom_pill_controls("scoped")
		}

		// Right-aligned Smart Enlarge, Dock to Split Pane, & Full Studio controls
		btn_right_w: f32 = 122.0
		if _scoped.dock_split_cb != nil do btn_right_w += 132.0
		if !_scoped.is_graph_node && _scoped.backing_file_abs != "" do btn_right_w += 116.0
		if avail_x := im.GetContentRegionAvail().x; avail_x > btn_right_w + 16.0 {
			im.SameLine(im.GetCursorPosX() + avail_x - btn_right_w)
		} else {
			im.SameLine()
		}

		if _scoped.dock_split_cb != nil {
			if im.Button(fmt.ctprintf("%s Dock Split", icons.ICON_MD_DOCK)) {
				dcb := _scoped.dock_split_cb
				duptr := _scoped.dock_user_ptr
				_commit_scoped_popup(false)
				open_flag = false
				dcb(duptr)
			}
			widgets.tooltip("Switch Blueprint Studio to Split: Graph + Fn and dock this procedure cleanly into the bottom pane")
			im.SameLine()
		}

		enlarge_lbl := _scoped.enlarged \
			? fmt.ctprintf("%s Restore (F11)", icons.ICON_MD_DOCK) \
			: fmt.ctprintf("%s Enlarge (F11)", icons.ICON_MD_OPEN_IN_FULL)
		im.PushStyleColorImVec4(.Button, _scoped.enlarged ? thm.with_alpha(p.accent, 0.34) : thm.with_alpha(p.accent, 0.16))
		if im.Button(enlarge_lbl) {
			_toggle_scoped_enlarge()
		}
		im.PopStyleColor()
		widgets.tooltip("Smart Enlarge (`F11`): Expand popup to 92% of screen or restore compact size")

		if !_scoped.is_graph_node && _scoped.backing_file_abs != "" {
			im.SameLine()
			if im.Button(fmt.ctprintf("%s Full Studio", icons.ICON_MD_OPEN_IN_NEW)) {
				open_file_in_studio(_scoped.backing_file_abs, max(_scoped.orig_decl_s_line, 1))
				wnd.open("odin_micro_studio")
			}
			widgets.tooltip("Open the full file in Odin Micro-Studio")
		}

		if !_scoped.is_snippet_preview {
			_draw_checker_and_hot_pills(snap)
		}
		im.Separator()

		// Optional Blueprint Using Bar & Inline Pin Scope Chips (never a locked banner!)
		if !_scoped.read_only {
			_draw_scoped_using_chip_bar(&_scoped, "##scoped_using_spaces_popup", "##sc_using_q")
		}
		if len(_scoped.pins) > 0 {
			im.TextDisabled("Pins:")
			for pin in _scoped.pins {
				im.SameLine()
				_draw_scoped_pin_badge(pin, true)
			}
		}

		if _scoped.status_note != "" {
			ncol := _scoped.status_is_err ? p.status_error : p.status_success
			im.TextColored(ncol, "%s", fmt.ctprintf("%s", _scoped.status_note))
		}

		// Main Editable / Read-Only Declaration Surface + Optional Rider Call-Site Review Split
		err_panel_h: f32 = len(snap.diagnostics) > 0 ? 104.0 : 28.0
		avail_body := im.GetContentRegionAvail()
		ref_panel_h: f32 = _scoped.refactor_active ? clamp(avail_body.y * 0.44, 180.0, 320.0) : 0.0
		code_h := max(avail_body.y - err_panel_h - ref_panel_h - 10.0, 120.0)

		if _draw_syntax_code_surface("##scoped_node_code", &_scoped.buf, {0, code_h}, snap.diagnostics, &_scoped.ide, _scoped.pins[:], !_scoped.is_full_decl, nil, &_scoped.undo, &_scoped.dirty, _scoped.backing_pkg_dir, _scoped.backing_file_abs, _scoped.read_only) {
			_scoped.dirty = true
			_notify_scoped_popup_edited(false)
		}

		if !_scoped.is_full_decl {
			im.TextColored(p.accent, "} // end node body")
			im.SameLine(0, 16)
		}
		_draw_ide_footer_telemetry(&_scoped.ide)

		// Coupled `Ctrl+Wheel` zoom + popup OS/ImGui window scaling (clamped <= 85% work rect)
		zoom_after := _studio_zoom_val()
		if abs(zoom_after - zoom_before) > 0.001 && !_scoped.enlarged && zoom_before > 0.1 {
			ratio := zoom_after / zoom_before
			cur_sz := im.GetWindowSize()
			_scoped.saved_size = {clamp(cur_sz.x * ratio, 560.0, max_w), clamp(cur_sz.y * ratio, 380.0, max_h)}
			_scoped.has_saved_rect     = true
			_scoped.apply_wheel_resize = true
		}

		// Rider-Style Signature Impact & Call-Site Review Queue
		if _scoped.refactor_active {
			im.Separator()
			im.PushStyleColorImVec4(.ChildBg, thm.with_alpha(p.status_warning, 0.07))
			if im.BeginChild("##scoped_refactor_queue", {0, ref_panel_h}, {.Borders}) {
				im.TextColored(p.status_warning, "%s", fmt.ctprintf("%s Signature Impact & Call-Site Review (%d site(s) across %d file(s))", icons.ICON_MD_WARNING, len(_scoped.refactor_sites), len(_scoped.refactor_files)))
				if _scoped.pending_default_arg != "" || _c_buf_string(_scoped.buf) != "" {
					im.SameLine()
					if im.SmallButton("Auto-Fill Default Args##rf_auto") {
						_scoped_autofill_default_args()
					}
					widgets.tooltip("Automatically insert default parameter values and/or rename call sites across reviewed buffers")
				}
				im.SameLine()
				if im.SmallButton("Cancel Review##rf_cancel") {
					_clear_scoped_refactor(&_scoped)
					_notify_scoped_popup_edited(false)
				}
				im.SameLine()
				can_commit_all := snap.stage != .Syntax_Error
				if !can_commit_all do im.BeginDisabled()
				im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_success, 0.28))
				if im.SmallButton("Commit All & Hot-Swap##rf_commit") {
					body_now := _c_buf_string(_scoped.buf)
					new_nm, new_prms, new_rets, _, pok := parse_odin_proc_decl_header(body_now, context.temp_allocator)
					if pok {
						new_k := _proc_sig_fingerprint(new_nm, new_prms, new_rets, context.temp_allocator)
						if upd_b, sp_ok := splice_full_odin_procedure_decl(_scoped.full_file_cache, _scoped.orig_proc_name, body_now, context.temp_allocator); sp_ok {
							_scoped_commit_all_files_to_disk(upd_b, new_nm, new_k, true)
						}
					}
				}
				im.PopStyleColor()
				if !can_commit_all do im.EndDisabled()

				if _scoped.refactor_active && len(_scoped.refactor_sites) > 0 {
					rem_ref := im.GetContentRegionAvail()
					list_w := clamp(rem_ref.x * 0.30, 190.0, 260.0)
					if im.BeginChild("##rf_site_list", {list_w, 0}, {.Borders}) {
						for rs, rsi in _scoped.refactor_sites {
							rf_title := (rs.file_idx >= 0 && rs.file_idx < len(_scoped.refactor_files)) ? _scoped.refactor_files[rs.file_idx].file_title : "file.odin"
							mark := rs.reviewed ? icons.ICON_MD_CHECK : icons.ICON_MD_EDIT
							is_sel := _scoped.refactor_active_idx == rsi
							if im.Selectable(fmt.ctprintf("%s %s:%d##rfs_%d", mark, rf_title, rs.line, rsi), is_sel) {
								_scoped_focus_refactor_site(rsi)
							}
						}
					}
					im.EndChild()
					im.SameLine()
					if im.BeginChild("##rf_site_ed", {0, 0}, {.Borders}) {
						cur_si := clamp(_scoped.refactor_active_idx, 0, len(_scoped.refactor_sites) - 1)
						cur_site := &_scoped.refactor_sites[cur_si]
						if cur_site.file_idx >= 0 && cur_site.file_idx < len(_scoped.refactor_files) {
							rf := &_scoped.refactor_files[cur_site.file_idx]
							im.TextDisabled("Before:")
							im.SameLine()
							im.TextColored(p.status_warning, "%s", fmt.ctprintf("%s", strings.trim_space(cur_site.before_line)))
							im.SameLine()
							if im.SmallButton(cur_site.reviewed ? "Reviewed##rfs_ok" : "Mark Reviewed##rfs_ok") {
								cur_site.reviewed = !cur_site.reviewed
								if cur_site.reviewed && cur_si + 1 < len(_scoped.refactor_sites) {
									_scoped_focus_refactor_site(cur_si + 1)
								}
							}
							rf_h := max(im.GetContentRegionAvail().y - 4.0, 90.0)
							if _draw_syntax_code_surface("##rf_caller_surf", &rf.buf, {0, rf_h}, snap.diagnostics, &rf.ide, nil, false, &rf.scroll_line, &rf.undo, &rf.dirty, rf.pkg_dir, rf.file_abs, false) {
								rf.dirty = true
								cur_site.reviewed = true
								_notify_scoped_popup_edited(false)
							}
						}
					}
					im.EndChild()
				}
			}
			im.EndChild()
			im.PopStyleColor()
		}

		if len(snap.diagnostics) > 0 && !_scoped.is_snippet_preview {
			if im.BeginChild("##scoped_node_diags", {0, 0}, {.Borders}) {
				_draw_surface_diagnostics_panel("scoped_diag", snap.diagnostics, &_scoped.ide)
			}
			im.EndChild()
		}
	}
	im.End()
	if !_scoped.just_opened {
		_scoped.open = open_flag
	}
}

// =============================================================================
// 2. Dockable Full-File Odin Micro-Studio Window (`odin_micro_studio`)
// =============================================================================

@(private = "file")
_refresh_workspace_odin_files :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for f in _studio.discovered_files do delete(f)
	clear(&_studio.discovered_files)

	if proj_root := engine.active_project_root(); proj_root != "" {
		_walk_odin_dir(proj_root, proj_root, 0)
	}
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	roots := [4]string{"assets/scripts", "haati/hot_scripts", "haati/packages", "haati/engine"}
	for r in roots {
		abs_r, _ := filepath.join({repo_root, r}, context.temp_allocator)
		_walk_odin_dir(abs_r, repo_root, 0)
	}
	slice.sort(_studio.discovered_files[:])
	_studio.files_scanned = true
}

@(private = "file")
_walk_odin_dir :: proc(dir: string, repo_root: string, depth: int) {
	if depth > 4 do return
	h, err := os.open(dir)
	if err != nil do return
	entries, rerr := os.read_dir(h, -1, context.temp_allocator)
	os.close(h)
	if rerr != nil do return

	for e in entries {
		if strings.has_prefix(e.name, ".") || e.name == "external" || e.name == "library" do continue
		full, _ := filepath.join({dir, e.name}, context.temp_allocator)
		norm_full, _ := strings.replace_all(full, "\\", "/", context.temp_allocator)
		if e.type == .Directory || (e.type == .Symlink && os.is_dir(full)) {
			_walk_odin_dir(full, repo_root, depth + 1)
		} else if strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, ".bodin") {
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			append(&_studio.discovered_files, strings.clone(norm_full))
			context.allocator = prev_a
		}
	}
}

@(private = "file")
_toolbar_sameline_if_fits :: #force_inline proc(next_item_est_w: f32) {
	im.SameLine()
	if im.GetContentRegionAvail().x < next_item_est_w {
		im.NewLine()
	}
}

@(private = "file")
_outline_symbol_visual :: proc(k: Outline_Symbol_Kind) -> (icon: cstring, col: im.Vec4) {
	sk: thm.Studio_Symbol_Kind = .Procedure
	switch k {
	case .Hot_Proc: sk = .Hot_Proc
	case .Proc:     sk = .Procedure
	case .Struct:   sk = .Struct
	case .Enum:     sk = .Enum
	}
	ic, _, scol := thm.studio_symbol_visual(sk)
	return ic, scol
}

@(private = "file")
_jump_to_tab_line :: proc(tab: ^_Tab_Doc, target_ln: int, target_col: int = 1) {
	if tab == nil do return
	src := _c_buf_string(tab.buf)
	ls  := compute_line_starts(src, context.temp_allocator)
	if len(ls) > 0 {
		clamped := clamp(target_ln, 1, len(ls))
		col_off := max(target_col - 1, 0)
		_studio.ide.cmd_jump_offset  = _clamp_utf8_boundary(src, ls[clamped - 1] + col_off)
		_studio.ide.cmd_jump_line    = clamped
		_studio.ide.cmd_jump_col     = max(target_col, 1)
		_studio.ide.ac_refocus_input = true
		tab.scroll_line              = clamped
		_trigger_line_flash(&_studio.ide, clamped)
	}
}

@(private = "file")
_nav_push_current :: proc() {
	if _studio.active_tab < 0 || _studio.active_tab >= len(_studio.tabs) do return
	act := _studio.tabs[_studio.active_tab]
	cur_ln := max(_studio.ide.caret_line, 1)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	// Avoid pushing exact duplicate adjacent entry
	if _studio.nav_cursor > 0 && _studio.nav_cursor <= _studio.nav_len {
		prev := _studio.nav_stack[_studio.nav_cursor - 1]
		if prev.abs_path == act.abs_path && abs(prev.line - cur_ln) <= 1 do return
	}

	// Trim forward tail when navigating from mid-history
	for i := _studio.nav_cursor; i < _studio.nav_len; i += 1 {
		if _studio.nav_stack[i].abs_path != "" {
			delete(_studio.nav_stack[i].abs_path)
			_studio.nav_stack[i].abs_path = ""
		}
	}
	_studio.nav_len = _studio.nav_cursor

	if _studio.nav_len >= len(_studio.nav_stack) {
		if _studio.nav_stack[0].abs_path != "" do delete(_studio.nav_stack[0].abs_path)
		for i in 1 ..< len(_studio.nav_stack) {
			_studio.nav_stack[i - 1] = _studio.nav_stack[i]
		}
		_studio.nav_len = len(_studio.nav_stack) - 1
	}
	_studio.nav_stack[_studio.nav_len] = _Code_Nav_Entry{
		abs_path = strings.clone(act.abs_path),
		line     = cur_ln,
	}
	_studio.nav_len   += 1
	_studio.nav_cursor = _studio.nav_len
}

@(private = "file")
_nav_can_back :: proc() -> bool {
	return _studio.nav_cursor > 0 && _studio.nav_len > 0
}

@(private = "file")
_nav_can_forward :: proc() -> bool {
	return _studio.nav_cursor < _studio.nav_len
}

@(private = "file")
_nav_step :: proc(delta: int) {
	if delta < 0 {
		if !_nav_can_back() do return
		// Record current location once if sitting at tip so Forward returns here!
		if _studio.nav_cursor == _studio.nav_len {
			_nav_push_current()
			_studio.nav_cursor = max(_studio.nav_len - 2, 0)
		} else {
			_studio.nav_cursor = max(_studio.nav_cursor - 1, 0)
		}
		target := _studio.nav_stack[_studio.nav_cursor]
		if open_file_in_studio(target.abs_path, target.line) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			_jump_to_tab_line(&_studio.tabs[_studio.active_tab], target.line)
		}
	} else if delta > 0 {
		if _studio.nav_cursor + 1 >= _studio.nav_len do return
		_studio.nav_cursor += 1
		target := _studio.nav_stack[_studio.nav_cursor]
		if open_file_in_studio(target.abs_path, target.line) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			_jump_to_tab_line(&_studio.tabs[_studio.active_tab], target.line)
		}
	}
}

@(private = "file")
_jump_to_definition_by_ident :: proc(act: ^_Tab_Doc, ident: string, outline_syms: []Outline_Symbol) -> bool {
	if ident == "" do return false
	// 1. Search symbols in the active file outline first
	for sym in outline_syms {
		if sym.name == ident {
			_nav_push_current()
			_jump_to_tab_line(act, sym.line)
			return true
		}
	}
	// 2. Search `@(hot_proc)` registry entries
	decl_pat := fmt.tprintf("%s ::", ident)
	if he, hok := resolve_hot_proc_info(ident); hok && he.source_file != "" {
		if raw, err := os.read_entire_file(he.source_file, context.temp_allocator); err == nil {
			ln := 1
			for line in strings.split_lines(string(raw), context.temp_allocator) {
				if strings.contains(line, decl_pat) {
					_nav_push_current()
					if open_file_in_studio(he.source_file, ln) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
						_jump_to_tab_line(&_studio.tabs[_studio.active_tab], ln)
					}
					return true
				}
				ln += 1
			}
		}
	}
	// 3. Scan discovered workspace `.odin` / `.bodin` files for `<ident> ::`
	for fp in _studio.discovered_files {
		if raw, err := os.read_entire_file(fp, context.temp_allocator); err == nil {
			txt := string(raw)
			if strings.contains(txt, decl_pat) {
				ln := 1
				for line in strings.split_lines(txt, context.temp_allocator) {
					if strings.has_prefix(strings.trim_space(line), decl_pat) {
						_nav_push_current()
						if open_file_in_studio(fp, ln) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
							_jump_to_tab_line(&_studio.tabs[_studio.active_tab], ln)
						}
						return true
					}
					ln += 1
				}
			}
		}
	}
	return false
}

draw_micro_studio_window :: proc() {
	_ensure_zoom_init()
	p  := thm.palette()
	st := thm.studio_tokens()
	io := im.GetIO()

	_studio.window_hovered = im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows)
	_studio.window_focused = im.IsWindowFocused({.RootWindow, .ChildWindows})

	if !_studio.files_scanned {
		_refresh_workspace_odin_files()
	}

	open_sym_jump := false
	if _studio.window_focused && io.KeyCtrl && io.KeyShift && im.IsKeyPressed(.O, false) {
		open_sym_jump = true
	}
	if _studio.window_focused && io.KeyAlt && !io.KeyCtrl {
		if im.IsKeyPressed(.LeftArrow, false)  do _nav_step(-1)
		if im.IsKeyPressed(.RightArrow, false) do _nav_step(+1)
	}

	snap := read_checker_snapshot(context.temp_allocator)
	if _studio.window_focused && im.IsKeyPressed(.F2, false) {
		_cycle_next_diagnostic(snap, io.KeyShift ? -1 : 1)
	}

	// -------------------------------------------------------------------------
	// Responsive Non-Clipping Top IDE Toolbar (Fixed 1.0x Chrome — Never Clips!)
	// -------------------------------------------------------------------------
	can_back := _nav_can_back()
	if !can_back do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s##ide_nav_back", icons.ICON_MD_ARROW_LEFT)) {
		_nav_step(-1)
	}
	if !can_back do im.EndDisabled()
	widgets.tooltip("Navigate Back (Alt+Left)")

	im.SameLine(0, 2)
	can_fwd := _nav_can_forward()
	if !can_fwd do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s##ide_nav_fwd", icons.ICON_MD_ARROW_RIGHT)) {
		_nav_step(+1)
	}
	if !can_fwd do im.EndDisabled()
	widgets.tooltip("Navigate Forward (Alt+Right)")

	_toolbar_sameline_if_fits(66.0)
	if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		act_tb := &_studio.tabs[_studio.active_tab]
		_draw_undo_redo_buttons(&act_tb.undo, &act_tb.buf, &_studio.ide, &act_tb.dirty, act_tb.pkg_dir, false, "main")
	} else {
		im.BeginDisabled()
		im.Button(fmt.ctprintf("%s##cs_undo_none", icons.ICON_MD_UNDO))
		im.SameLine(0, 2)
		im.Button(fmt.ctprintf("%s##cs_redo_none", icons.ICON_MD_REDO))
		im.EndDisabled()
	}

	_toolbar_sameline_if_fits(108.0)
	sb_col := _studio.sandbox_mode ? p.status_success : p.text_muted
	im.PushStyleColorImVec4(.Button, thm.with_alpha(sb_col, _studio.sandbox_mode ? 0.22 : 0.12))
	im.PushStyleColorImVec4(.Text, sb_col)
	if im.Button(fmt.ctprintf("%s Sandbox: %s##cs_sb_tog", icons.ICON_MD_LOCK, _studio.sandbox_mode ? "ON" : "OFF")) {
		_studio.sandbox_mode = !_studio.sandbox_mode
		if _studio.sandbox_toggle_cb != nil {
			_studio.sandbox_toggle_cb(_studio.sandbox_mode)
		}
	}
	im.PopStyleColor(2)
	widgets.tooltip("Sandbox Mode: F7 hot-swaps unsaved edits via builds/sandbox_cartridge/ without writing project files on drive, and traps script crashes safely. Use Ctrl+S when ready to commit to disk.")

	_toolbar_sameline_if_fits(126.0)
	im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.26))
	f7_lbl := _studio.sandbox_mode ? fmt.ctprintf("%s Sandbox (F7)", icons.ICON_MD_BOLT) : fmt.ctprintf("%s Hot-Swap (F7)", icons.ICON_MD_BOLT)
	if im.Button(f7_lbl) || (_studio.window_focused && im.IsKeyPressed(.F7, false)) {
		handled := false
		if _studio.sandbox_mode {
			if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
				t := &_studio.tabs[_studio.active_tab]
				is_bodin_tab := strings.has_suffix(strings.to_lower(t.abs_path, context.temp_allocator), ".bodin")
				if t.dirty && is_bodin_tab && _studio.bodin_sandbox_cb != nil {
					ram_src := format_studio_buffer_for_disk(_c_buf_string(t.buf), t.uses_tabs, context.temp_allocator)
					handled = _studio.bodin_sandbox_cb(t.abs_path, ram_src)
				}
			}
			if !handled {
				overrides := make([dynamic]engine.Sandbox_File_Override, 0, len(_studio.tabs), context.temp_allocator)
				for &tb in _studio.tabs {
					if !tb.dirty || !strings.contains(tb.pkg_dir, "hot_scripts") do continue
					append(&overrides, engine.Sandbox_File_Override{
						rel_hot_name = filepath.base(tb.abs_path),
						content      = format_studio_buffer_for_disk(_c_buf_string(tb.buf), tb.uses_tabs, context.temp_allocator),
					})
				}
				if len(overrides) > 0 {
					_ = engine.hot_cartridge_trigger_sandbox_build(overrides[:])
					handled = true
				}
			}
		} else {
			if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
				t := &_studio.tabs[_studio.active_tab]
				is_bodin_tab := strings.has_suffix(strings.to_lower(t.abs_path, context.temp_allocator), ".bodin")
				if t.dirty {
					disk_src := format_studio_buffer_for_disk(_c_buf_string(t.buf), t.uses_tabs, context.temp_allocator)
					_ = os.write_entire_file(t.abs_path, transmute([]u8)disk_src)
					t.dirty = false
				}
				if is_bodin_tab && _studio.bodin_saved_cb != nil {
					_studio.bodin_saved_cb(t.abs_path, true)
					handled = true
				}
			}
		}
		if !handled {
			engine.hot_cartridge_trigger_async_build(true)
		}
	}
	im.PopStyleColor()
	widgets.tooltip(_studio.sandbox_mode \
		? "Test unsaved RAM edits safely via builds/sandbox_cartridge/ (`hot_cartridge_<N>.dll`) without modifying files on disk! (`Ctrl+S` commits to disk.)" \
		: "Save active tab and hot-swap all `@(hot_proc)` + transpiled `.bodin` scripts via `hot_cartridge_<N>.dll` without restarting!")

	_toolbar_sameline_if_fits(128.0)
	if im.Button(fmt.ctprintf("%s Save (Ctrl+S)", icons.ICON_MD_SAVE)) || (_studio.window_focused && io.KeyCtrl && im.IsKeyPressed(.S, false)) {
		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			t := &_studio.tabs[_studio.active_tab]
			is_bodin_tab := strings.has_suffix(strings.to_lower(t.abs_path, context.temp_allocator), ".bodin")
			disk_src := format_studio_buffer_for_disk(_c_buf_string(t.buf), t.uses_tabs, context.temp_allocator)
			if os.write_entire_file(t.abs_path, transmute([]u8)disk_src) == nil {
				t.dirty = false
				if is_bodin_tab && _studio.bodin_saved_cb != nil {
					_studio.bodin_saved_cb(t.abs_path, false)
				}
				_notify_buffer_edited(_c_buf_string(t.buf), false, t.pkg_dir, true)
			}
		}
	}
	widgets.tooltip("Save active `.odin` file and run ground-truth `odin check -json-errors`")

	_toolbar_sameline_if_fits(110.0)
	if im.Button(fmt.ctprintf("%s Relaunch", icons.ICON_MD_REFRESH)) {
		if _studio.relaunch_cb != nil do _studio.relaunch_cb()
	}
	widgets.tooltip("For `@(component)` struct layout or core engine changes: rebuilds `Haati.exe` in the background and hands off your live scene & camera in OS Shared Memory (0 disk writes)!")

	has_act_for_bp := _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)
	act_path_bp    := has_act_for_bp ? _studio.tabs[_studio.active_tab].abs_path : ""
	is_bp_script   := strings.has_suffix(act_path_bp, ".bodin") || strings.has_suffix(act_path_bp, "_mhgraph_generated.odin")
	paired_bodin   := ""
	if has_act_for_bp && !is_bp_script {
		act_bp_tab := &_studio.tabs[_studio.active_tab]
		if !act_bp_tab.paired_checked {
			act_bp_tab.paired_checked = true
			if strings.has_suffix(strings.to_lower(act_path_bp, context.temp_allocator), ".odin") {
				cand := fmt.tprintf("%s.bodin", act_path_bp[:len(act_path_bp) - 5])
				if os.exists(cand) {
					prev_a := context.allocator
					context.allocator = runtime.default_allocator()
					act_bp_tab.paired_bodin = strings.clone(cand)
					context.allocator = prev_a
				}
			}
		}
		paired_bodin = act_bp_tab.paired_bodin
	}

	bp_btn_w: f32 = is_bp_script ? 210.0 : (paired_bodin != "" ? 170.0 : 124.0)
	_toolbar_sameline_if_fits(bp_btn_w)
	if is_bp_script {
		im.PushStyleColorImVec4(.Button, st.compile_btn_bg)
		im.PushStyleColorImVec4(.Text, st.compile_btn_fg)
		if im.Button(fmt.ctprintf("%s Switch to Blueprint Graph (F12)", icons.ICON_MD_ACCOUNT_TREE)) || (_studio.window_focused && im.IsKeyPressed(.F12, false)) {
			if _studio.switch_to_bp_cb != nil {
				_studio.switch_to_bp_cb(act_path_bp)
			} else {
				wnd.open("mh_visual_script")
			}
		}
		im.PopStyleColor(2)
		widgets.tooltip("Switch back to visual node graph view for this `.bodin` Blueprint (`F12`)")
	} else if has_act_for_bp && paired_bodin != "" {
		if im.Button(fmt.ctprintf("%s Open %s", icons.ICON_MD_ACCOUNT_TREE, filepath.base(paired_bodin))) {
			if _studio.switch_to_bp_cb != nil {
				_studio.switch_to_bp_cb(paired_bodin)
			} else {
				wnd.open("mh_visual_script")
			}
		}
		widgets.tooltip("Open paired visual `.bodin` Blueprint graph for this script")
	} else if has_act_for_bp {
		if im.Button(fmt.ctprintf("%s + @(bp_node)", icons.ICON_MD_ACCOUNT_TREE)) {
			act_t := &_studio.tabs[_studio.active_tab]
			cur_s := _c_buf_string(act_t.buf)
			sep := (cur_s != "" && !strings.has_suffix(cur_s, "\n")) ? "\n\n" : "\n"
			tmpl := "@(bp_node={title=\"Custom_Node\", namespace=\"Custom\"})\ncustom_bp_node :: proc(value: f32 = 1.0) -> f32 {\n    return value\n}\n"
			updated := strings.concatenate({cur_s, sep, tmpl}, context.temp_allocator)
			im.ClearActiveID()
			_copy_to_c_buf_grow(&act_t.buf, updated, STUDIO_MIN_BUF_CAP)
			act_t.dirty = true
			s_after := _c_buf_string(act_t.buf)
			code_undo_record_edit(&act_t.undo, s_after, len(s_after), im.GetTime(), true)
			_notify_buffer_edited(s_after, false, act_t.pkg_dir)
		}
		widgets.tooltip("Expose a pure `.odin` procedure as a visual Blueprint Studio node via `@(bp_node)`")
	} else {
		im.BeginDisabled()
		im.Button(fmt.ctprintf("%s Blueprint Studio", icons.ICON_MD_ACCOUNT_TREE))
		im.EndDisabled()
		widgets.tooltip("Open a `.bodin` file or create one from Void File Explorer to edit a visual Blueprint graph")
	}

	if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		_toolbar_sameline_if_fits(136.0)
		if im.Button(fmt.ctprintf("%s + Import / Using", icons.ICON_MD_ADD)) {
			im.OpenPopup("##studio_using_spaces_popup")
		}
		widgets.tooltip("Zero-Guess Odin `import` & `using` Namespace Selector — injects imports cleanly and indexes all symbols into Async Autocomplete!")

		_toolbar_sameline_if_fits(110.0)
		if im.Button(fmt.ctprintf("%s Symbols", icons.ICON_MD_FUNCTIONS)) {
			open_sym_jump = true
		}
		widgets.tooltip("Fuzzy Jump to Procedure / `@(hot_proc)` / Struct / Enum (`Ctrl + Shift + O`)")

		if _studio.ide.req_open_imports_popup {
			_studio.ide.req_open_imports_popup = false
			im.OpenPopup("##studio_using_spaces_popup")
		}
		_draw_using_spaces_popup("##studio_using_spaces_popup", "##st_using_q", _studio.using_search_buf[:], tab = &_studio.tabs[_studio.active_tab], ide = &_studio.ide)
	}

	if _studio.open_ide_cb != nil && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		_toolbar_sameline_if_fits(120.0)
		if im.Button(fmt.ctprintf("%s External IDE", icons.ICON_MD_OPEN_IN_NEW)) {
			t := &_studio.tabs[_studio.active_tab]
			_studio.open_ide_cb(t.abs_path, max(_studio.ide.caret_line, 1))
		}
		widgets.tooltip("Open current file at caret line in Antigravity / external IDE")
	}

	_toolbar_sameline_if_fits(44.0)
	if im.Button(fmt.ctprintf("%s##ide_defs", icons.ICON_MD_SETTINGS)) {
		wnd.open_settings_tab("Code & Script IDE")
	}
	widgets.tooltip("Open Settings -> Code & Script IDE (External IDE preset, problem check idle delay, per-pane zooms, Error Lens & Breadcrumbs)")

	// Per-Segment Independent Zoom Status Pills (Click any segment badge to reset that pane to 100%)
	_toolbar_sameline_if_fits(235.0)
	im.TextDisabled("Zoom:")
	im.SameLine(0, 3)
	if im.SmallButton(fmt.ctprintf("Nav %d%%##rst_nav_zm", int(math.round(_studio.explorer_zoom * 100.0)))) {
		set_studio_explorer_zoom(1.0)
	}
	widgets.tooltip("Left Explorer & Structure Zoom (`Ctrl + MouseWheel` over Left Pane — click to reset to 100%)")
	im.SameLine(0, 3)
	if im.SmallButton(fmt.ctprintf("Code %d%%##rst_code_zm", int(math.round(_studio.code_zoom * 100.0)))) {
		set_studio_code_zoom(1.0)
	}
	widgets.tooltip("Center Code Editor Zoom (`Ctrl + MouseWheel` over Code — independent from UI chrome & sidebars!)")
	im.SameLine(0, 3)
	if im.SmallButton(fmt.ctprintf("Out %d%%##rst_prob_zm", int(math.round(_studio.problems_zoom * 100.0)))) {
		set_studio_problems_zoom(1.0)
	}
	widgets.tooltip("Bottom Problems / Output Zoom (`Ctrl + MouseWheel` over Problems Dock — click to reset to 100%)")

	_toolbar_sameline_if_fits(190.0)
	_draw_checker_and_hot_pills(snap)
	im.Separator()
	draw_sandbox_fault_banner()

	// Precompute active tab symbols for Left Structure Outline, Breadcrumbs, and `Ctrl+Shift+O` popup
	has_active_tab := _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)
	active_src     := has_active_tab ? _c_buf_string(_studio.tabs[_studio.active_tab].buf) : ""
	outline_syms   := has_active_tab ? _get_cached_outline_symbols(active_src) : nil
	encl_name, encl_kind, has_encl := enclosing_odin_symbol_at_line(outline_syms, max(_studio.ide.caret_line, 1))

	if open_sym_jump {
		im.OpenPopup("##studio_symbol_jump_popup")
	}
	if im.BeginPopup("##studio_symbol_jump_popup") {
		im.TextColored(p.accent, icons.ICON_MD_FUNCTIONS + " Jump to Symbol in File (Ctrl+Shift+O)")
		sr := widgets.search_bar(_studio.sym_jump_buf[:], widgets.Search_Bar_Opts{
			id            = "##sym_jump_q",
			hint          = "Filter procedures, @(hot_proc), structs...",
			mode          = .Popup,
			width         = 320,
			enter_returns = true,
		})
		if sr.escape_close {
			im.CloseCurrentPopup()
			im.EndPopup()
			return
		}
		terms := widgets.search_terms(sr.query)
		enter_sym := sr.submitted || (sr.active && (im.IsKeyPressed(.Enter) || im.IsKeyPressed(.KeypadEnter)))
		im.Separator()
		first_match_ln := 0
		if im.BeginChild("##sym_jump_list", {340, 240}) {
			for sym, si in outline_syms {
				if len(terms) > 0 && !widgets.search_match(sym.name, terms) do continue
				if first_match_ln == 0 do first_match_ln = sym.line
				ic, scol := _outline_symbol_visual(sym.kind)
				im.PushStyleColorImVec4(.Text, scol)
				clicked := im.Selectable(fmt.ctprintf("%s %s  (Ln %d)##sj_%d", ic, sym.name, sym.line, si), sym.name == encl_name)
				im.PopStyleColor()
				if sym.doc_comment != "" {
					widgets.tooltip_delayed(fmt.ctprintf("%s\n\n%s", sym.signature, sym.doc_comment))
				}
				if clicked && has_active_tab {
					_jump_to_tab_line(&_studio.tabs[_studio.active_tab], sym.line)
					im.CloseCurrentPopup()
				}
			}
		}
		im.EndChild()
		if enter_sym && first_match_ln > 0 && has_active_tab {
			_jump_to_tab_line(&_studio.tabs[_studio.active_tab], first_match_ln)
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// -------------------------------------------------------------------------
	// 3-Segment Independent-Zoom IDE Layout:
	//   [1. Left Structure & Explorer] |splitter| [2. Breadcrumbs + Code] /splitter/ [3. Problems]
	// -------------------------------------------------------------------------
	avail  := im.GetContentRegionAvail()
	left_w := clamp(_studio.left_width, 175.0, max(avail.x * 0.46, 185.0))

	// SEGMENT 1: Left Structure Outline + Hot Procs + Workspace Explorer (`_studio.explorer_zoom`)
	{
		im.PushFontFloat(nil, im.GetStyle().FontSizeBase * _studio.explorer_zoom)
		defer im.PopFont()

		left_flags: im.WindowFlags = io.KeyCtrl ? {.NoScrollWithMouse} : {}
		if im.BeginChild("##studio_left_nav", {left_w, avail.y}, {.Borders}, left_flags) {
			if im.IsWindowHovered(im.HoveredFlags_ChildWindows | im.HoveredFlags_AllowWhenBlockedByActiveItem) && io.KeyCtrl && io.MouseWheel != 0 {
				set_studio_explorer_zoom(_studio.explorer_zoom + io.MouseWheel * CODE_ZOOM_STEP)
				io.MouseWheel = 0
			}

			// 1A. JetBrains / VS Structure Outline of Active File
			if im.CollapsingHeaderBoolPtr(fmt.ctprintf("%s Structure (%d)###hdr_structure", icons.ICON_MD_FUNCTIONS, len(outline_syms)), nil, {.DefaultOpen}) {
				if len(outline_syms) == 0 {
					im.TextDisabled("  No top-level symbols")
				} else {
					outline_h := min(f32(len(outline_syms)) * im.GetTextLineHeightWithSpacing() + 8.0, max(avail.y * 0.28, 96.0))
					if im.BeginChild("##outline_scroll", {0, outline_h}, {}, left_flags) {
						for sym, si in outline_syms {
							ic, scol := _outline_symbol_visual(sym.kind)
							is_cur_sym := has_encl && sym.name == encl_name
							im.PushStyleColorImVec4(.Text, scol)
							if im.Selectable(fmt.ctprintf(" %s %s##out_s_%d", ic, sym.name, si), is_cur_sym) && has_active_tab {
								_jump_to_tab_line(&_studio.tabs[_studio.active_tab], sym.line)
							}
							im.PopStyleColor()
							if sym.doc_comment != "" {
								widgets.tooltip_delayed(fmt.ctprintf("%s\n\n%s", sym.signature, sym.doc_comment))
							} else {
								widgets.tooltip_delayed(fmt.ctprintf("%s  (Line %d)", sym.signature, sym.line))
							}
						}
					}
					im.EndChild()
				}
			}

			// 1B. Live `@(hot_proc)` Cartridge Registry
			hot_entries := engine.hot_proc_entries()
			if im.CollapsingHeaderBoolPtr(fmt.ctprintf("%s Hot Procs (%d)###hdr_hotprocs", icons.ICON_MD_BOLT, len(hot_entries)), nil, {.DefaultOpen}) {
				if len(hot_entries) == 0 {
					im.TextDisabled("  No @(hot_proc) registered")
				} else {
					hp_h := min(f32(len(hot_entries)) * im.GetTextLineHeightWithSpacing() + 8.0, max(avail.y * 0.22, 78.0))
					if im.BeginChild("##hot_proc_scroll", {0, hp_h}, {}, left_flags) {
						for he in hot_entries {
							gen_tag := he.hot_gen > 0 ? fmt.ctprintf("[#%d]", he.hot_gen) : cstring("[Static]")
							if im.Selectable(fmt.ctprintf(" %s %s %s##hp_%s", icons.ICON_MD_BOLT, he.name, gen_tag, he.name), false) {
								if he.source_file != "" {
									open_scoped_proc_popup(he.name, he.source_file, he.name)
								}
							}
							if im.IsItemHovered() {
								doc := he.source_file != "" ? extract_odin_proc_doc_from_file(he.source_file, he.name, context.temp_allocator) : ""
								if doc != "" {
									widgets.tooltip_delayed(fmt.ctprintf("@(hot_proc) %s\n\n%s\n\n(Click to edit in Scoped Micro-IDE)", he.name, doc))
								} else {
									widgets.tooltip_delayed(fmt.ctprintf("@(hot_proc) %s — Click to edit in Scoped Micro-IDE", he.name))
								}
							}
						}
					}
					im.EndChild()
				}
			}

			// 1C. Workspace Odin / Bodin Explorer
			im.Separator()
			im.TextColored(p.accent, icons.ICON_MD_FOLDER + " Workspace Odin Files")
			_ = widgets.search_input("##file_filter", _studio.search_buf[:], "Filter files...", max(im.GetContentRegionAvail().x - 34.0, 96.0))
			im.SameLine()
			if im.Button(fmt.ctprintf("%s##rescan", icons.ICON_MD_REFRESH)) {
				_refresh_workspace_odin_files()
			}
			widgets.tooltip("Rescan workspace `.odin` and `.bodin` files")

			file_terms := widgets.search_terms(_c_buf_string(_studio.search_buf[:]))
			if im.BeginChild("##file_list_scroll", {0, 0}, {}, left_flags) {
				shown := 0
				for f in _studio.discovered_files {
					if len(file_terms) > 0 && !widgets.search_match(f, file_terms) do continue
					base := filepath.base(f)
					is_cur := has_active_tab && _studio.tabs[_studio.active_tab].abs_path == f
					file_ic := strings.has_suffix(base, ".bodin") ? icons.ICON_MD_ACCOUNT_TREE : icons.ICON_MD_DESCRIPTION
					if im.Selectable(fmt.ctprintf(" %s %s##wf_%d", file_ic, base, shown), is_cur) {
						open_file_in_studio(f)
					}
					widgets.tooltip_delayed(fmt.ctprintf("%s", f))
					shown += 1
					if shown >= 140 do break
				}
			}
			im.EndChild()
		}
		im.EndChild()
	}

	// Vertical Splitter between Left Explorer & Right Editor
	im.SameLine(0, 0)
	right_w := max(avail.x - left_w - widgets.SPLITTER_SIZE, 240.0)
	if widgets.splitter("##studio_vsplit", true, &left_w, &right_w, 175.0, 240.0) {
		_studio.left_width = clamp(left_w, 175.0, 560.0)
	}
	im.SameLine(0, 0)
	if im.BeginChild("##studio_right_main", {0, avail.y}) {
		if len(_studio.tabs) > 0 && im.BeginTabBar("##studio_tabs", {.FittingPolicyScroll}) {
			remove_idx := -1
			for &tab, ti in _studio.tabs {
				tab_open := true
				lbl := fmt.ctprintf("%s%s###st_tab_%d", tab.title, tab.dirty ? " *" : "", ti)
				t_flags: im.TabItemFlags
				if _studio.request_tab_select == ti do t_flags |= {.SetSelected}
				if im.BeginTabItem(lbl, &tab_open, t_flags) {
					if _studio.request_tab_select == ti do _studio.request_tab_select = -1
					if _studio.active_tab != ti {
						_studio.active_tab = ti
						im.ClearActiveID()
						_clear_ide_pending_restore(&_studio.ide)
						_notify_buffer_edited(_c_buf_string(tab.buf), false, tab.pkg_dir)
					}
					im.EndTabItem()
				}
				if !tab_open do remove_idx = ti
			}
			im.EndTabBar()

			if remove_idx >= 0 {
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				old := _studio.tabs[remove_idx]
				if _studio.last_emb_norm != "" && strings.equal_fold(old.abs_path, _studio.last_emb_norm) {
					_studio.emb_user_closed = true
				}
				delete(old.title)
				delete(old.abs_path)
				delete(old.pkg_dir)
				if old.paired_bodin != "" do delete(old.paired_bodin)
				delete(old.buf)
				code_undo_free(&old.undo)
				im.ClearActiveID()
				_clear_ide_pending_restore(&_studio.ide)
				_free_ide_surface_cache(&_studio.ide)
				ordered_remove(&_studio.tabs, remove_idx)
				context.allocator = prev_alloc
				if _studio.active_tab >= len(_studio.tabs) {
					_studio.active_tab = max(len(_studio.tabs) - 1, 0)
				}
				_studio.request_tab_select = _studio.active_tab
				_studio.dirty_tabs_rev += 1
				if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
					nt := &_studio.tabs[_studio.active_tab]
					_notify_buffer_edited(_c_buf_string(nt.buf), false, nt.pkg_dir, false, nt.abs_path)
				} else {
					set_checker_dirty_overlays(nil)
				}
			}
		}

		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			act := &_studio.tabs[_studio.active_tab]
			active_src = _c_buf_string(act.buf)
			outline_syms = _get_cached_outline_symbols(active_src)
			encl_name, encl_kind, has_encl = enclosing_odin_symbol_at_line(outline_syms, max(_studio.ide.caret_line, 1))

			// JetBrains / VS Scope Breadcrumb Bar + Quick Go-to-Line & Error Lens Pills
			if _studio.show_breadcrumbs {
				pkg_name := extract_odin_package_name(active_src)
				im.TextColored(p.text_muted, "%s", fmt.ctprintf("%s %s", icons.ICON_MD_FOLDER, pkg_name))
				im.SameLine(0, 5)
				im.TextDisabled(icons.ICON_MD_CHEVRON_RIGHT)
				im.SameLine(0, 5)
				im.TextColored(p.text_primary, "%s", fmt.ctprintf("%s %s", icons.ICON_MD_CODE, act.title))
				if has_encl {
					ic, scol := _outline_symbol_visual(encl_kind)
					im.SameLine(0, 5)
					im.TextDisabled(icons.ICON_MD_CHEVRON_RIGHT)
					im.SameLine(0, 5)
					im.PushStyleColorImVec4(.Text, scol)
					if im.SmallButton(fmt.ctprintf("%s %s()##bc_sym", ic, encl_name)) {
						im.OpenPopup("##studio_symbol_jump_popup")
					}
					im.PopStyleColor()
					widgets.tooltip("Click to jump to another symbol in this file (`Ctrl+Shift+O`)")
				}

				im.SameLine(0, 14)
				if im.SmallButton(fmt.ctprintf("Ln %d, Col %d##bc_goto", max(_studio.ide.caret_line, 1), max(_studio.ide.caret_col, 1))) {
					_studio.ide.goto_open       = !_studio.ide.goto_open
					_studio.ide.goto_focus_next = _studio.ide.goto_open
				}
				widgets.tooltip("Go to Line (`Ctrl+G`)  |  Move Line (`Alt+Up/Down`)  |  Find (`Ctrl+F`)  |  Autocomplete (`Ctrl+Space`)")

				im.SameLine(0, 6)
				if im.SmallButton(fmt.ctprintf("Lens: %s##bc_lens", _studio.show_error_lens ? "ON" : "OFF")) {
					_studio.show_error_lens = !_studio.show_error_lens
				}
				widgets.tooltip("Toggle Inline Diagnostic Error Lens after source lines")

				if len(_studio.ide.cached_unused_import_lines) > 0 {
					im.SameLine(0, 6)
					im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_warning, 0.24))
					if im.SmallButton(fmt.ctprintf("Comment Unused Imports (%d)##bc_comment_imp", len(_studio.ide.cached_unused_import_lines))) {
						if updated, cnt := comment_out_unused_odin_imports(active_src, context.temp_allocator); cnt > 0 {
							im.ClearActiveID()
							cpos := _clamp_utf8_boundary(updated, _studio.ide.cursor_pos)
							_copy_to_c_buf_grow(&act.buf, updated, STUDIO_MIN_BUF_CAP)
							_arm_ide_restore(&_studio.ide, updated, cpos)
							_studio.ide.ac_refocus_input = true
							act.dirty = true
							_studio.dirty_tabs_rev += 1
							code_undo_record_edit(&act.undo, updated, cpos, im.GetTime(), true)
							_notify_buffer_edited(updated, false, act.pkg_dir, true)
						}
					}
					im.PopStyleColor()
					widgets.tooltip("One-click comment out unused Odin imports in this file")
				}

				if strings.contains(active_src, "moonhug:") {
					im.SameLine(0, 6)
					im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_warning, 0.24))
					if im.SmallButton("Migrate moonhug: -> haati:##bc_mig_mh") {
						if updated, cnt := migrate_all_legacy_moonhug_imports(active_src, "", context.temp_allocator); cnt > 0 {
							im.ClearActiveID()
							cpos := _clamp_utf8_boundary(updated, _studio.ide.cursor_pos)
							_copy_to_c_buf_grow(&act.buf, updated, STUDIO_MIN_BUF_CAP)
							_arm_ide_restore(&_studio.ide, updated, cpos)
							_studio.ide.ac_refocus_input = true
							act.dirty = true
							_studio.dirty_tabs_rev += 1
							code_undo_record_edit(&act.undo, updated, cpos, im.GetTime(), true)
							_notify_buffer_edited(updated, false, act.pkg_dir, true)
						}
					}
					im.PopStyleColor()
					widgets.tooltip("One-click migrate legacy `moonhug:` imports in this file to `haati:` / `project:`")
				}

				if _studio.switch_to_bp_cb != nil && strings.has_suffix(strings.to_lower(act.abs_path, context.temp_allocator), ".bodin") {
					im.SameLine(0, 8)
					im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.22))
					im.PushStyleColorImVec4(.Text, p.accent)
					if im.SmallButton(fmt.ctprintf("%s View in Blueprint Graph##bc_view_bp", icons.ICON_MD_ACCOUNT_TREE)) {
						_studio.switch_to_bp_cb(act.abs_path)
					}
					im.PopStyleColor(2)
					if has_encl {
						widgets.tooltip(fmt.ctprintf("Jump to Blueprint Graph view (`F12`) — currently inside `%s`", encl_name))
					} else {
						widgets.tooltip("Jump to Blueprint Graph view (`F12`)")
					}
				}
			} else {
				_draw_ide_footer_telemetry(&_studio.ide)
			}

			_ = _draw_sibling_diag_banner(snap.diagnostics, act.abs_path)

			// SEGMENT 2: Center Code Surface (`_studio.code_zoom`)
			prob_h := clamp(_studio.problems_height, 44.0, max(im.GetContentRegionAvail().y * 0.45, 56.0))
			ed_h   := max(im.GetContentRegionAvail().y - prob_h - widgets.SPLITTER_SIZE - 4.0, 120.0)
			im.PushIDInt(i32(act.uid))
			main_surf_edited := _draw_syntax_code_surface("##main_studio_code", &act.buf, {0, ed_h}, snap.diagnostics, &_studio.ide, nil, false, &act.scroll_line, &act.undo, &act.dirty, act.pkg_dir, act.abs_path)
			im.PopID()
			if main_surf_edited {
				act.dirty = true
				_notify_buffer_edited(_c_buf_string(act.buf), false, act.pkg_dir)
			}
			if _studio.ide.req_jump_ident != "" {
				_jump_to_definition_by_ident(act, _studio.ide.req_jump_ident, outline_syms)
				// _jump_to_definition_by_ident may open a new tab and reallocate _studio.tabs.
				act = (_studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)) ? &_studio.tabs[_studio.active_tab] : nil
			}

			// Horizontal Splitter between Code Surface & Problems Dock
			if widgets.splitter("##studio_hsplit", false, &ed_h, &prob_h, 120.0, 44.0) {
				_studio.problems_height = clamp(prob_h, 44.0, 360.0)
			}

			// SEGMENT 3: Bottom Compiler Problems & Cartridge Output Dock (`_studio.problems_zoom`)
			{
				im.PushFontFloat(nil, im.GetStyle().FontSizeBase * _studio.problems_zoom)
				defer im.PopFont()

				prob_flags: im.WindowFlags = io.KeyCtrl ? {.NoScrollWithMouse} : {}
				if im.BeginChild("##studio_problems_dock", {0, 0}, {.Borders}, prob_flags) {
					if im.IsWindowHovered(im.HoveredFlags_ChildWindows | im.HoveredFlags_AllowWhenBlockedByActiveItem) && io.KeyCtrl && io.MouseWheel != 0 {
						set_studio_problems_zoom(_studio.problems_zoom + io.MouseWheel * CODE_ZOOM_STEP)
						io.MouseWheel = 0
					}

					_, _, _, _, hot_stderr := engine.hot_cartridge_status()
					if snap.stage == .Pending_Syntax && hot_stderr == "" {
						widgets.text_disabledf("Typing... waiting %.2fs idle before checking problems", get_problem_check_delay_sec())
					} else if len(snap.diagnostics) == 0 && hot_stderr == "" && snap.stage != .Compiler_Error && snap.stage != .Syntax_Error {
						im.TextColored(p.status_success, icons.ICON_MD_CHECK + " 0 Compiler Problems — Syntax & Types Clean")
					} else if len(snap.diagnostics) == 0 && hot_stderr == "" {
						im.TextColored(p.status_error, "%s", fmt.ctprintf("%s Typecheck Error — click status pill or Save & Check", icons.ICON_MD_ERROR))
					} else if act != nil {
						_draw_surface_diagnostics_panel("studio_diag", snap.diagnostics, &_studio.ide, act, hot_stderr, 84.0, true, true)
					}
				}
				im.EndChild()
			}
		} else {
			im.Spacing()
			widgets.text_coloredf(p.text_secondary, "%s No Script Open", icons.ICON_MD_CODE)
			im.TextDisabled("Select a `.odin` or `.bodin` file on the left explorer or open one from Void File Explorer.")
			im.Spacing()
			if im.Button(fmt.ctprintf("%s Open Built-in Hot Scripts", icons.ICON_MD_BOLT)) {
				_ = open_file_in_studio("haati/hot_scripts/builtin_hot_scripts.odin")
			}
		}
	}
	im.EndChild()
	_ = c.int(0)
}

@(private = "file")
_draw_sibling_diag_banner :: proc(diags: []Studio_Diagnostic, active_abs: string) -> bool {
	if len(diags) == 0 do return false
	sib: Studio_Diagnostic
	sib_cnt := 0
	for d in diags {
		if diagnostic_matches_active_file(d.file, active_abs) do continue
		if sib_cnt == 0 || (sib.is_warning && !d.is_warning) {
			sib = d
		}
		sib_cnt += 1
	}
	if sib_cnt == 0 do return false

	st := thm.studio_tokens()
	col := sib.is_warning ? st.diag_warn_fg : st.diag_err_fg
	ic  := sib.is_warning ? icons.ICON_MD_WARNING : icons.ICON_MD_ERROR
	im.PushStyleColorImVec4(.ChildBg, thm.with_alpha(col, 0.14))
	if im.BeginChild("##studio_sibling_diag_banner", {0, 30}, {.Borders}) {
		short_msg := widgets.utf8_safe_prefix(sib.message, 90)
		im.TextColored(col, "%s", fmt.ctprintf("%s %d problem(s) in %s:%d:%d — %s", ic, sib_cnt, filepath.base(sib.file), sib.line, sib.column, short_msg))
		im.SameLine(0, 10)
		if im.SmallButton("Jump to File & Line##sib_jmp_btn") {
			_jump_studio_to_diagnostic(sib)
		}
	}
	im.EndChild()
	im.PopStyleColor()
	return true
}
// Cleanly inserts a selected `Using_Space_Spec` (`import` and/or `using` + `#+feature using-stmt`) right around `package <name>`.
inject_using_space_into_source :: proc(src: string, spec: Using_Space_Spec, allocator := context.temp_allocator) -> (updated: string, changed: bool) {
	using_line := strings.has_prefix(spec.id, "using_") ? fmt.tprintf("using %s", spec.pkg_alias) : ""
	need_feat  := using_line       != "" && !strings.contains(src, "#+feature using-stmt")
	need_imp   := spec.import_line != "" && !strings.contains(src, spec.import_line)
	need_using := using_line       != "" && !strings.contains(src, using_line)
	if !need_feat && !need_imp && !need_using do return src, false

	sb := strings.builder_make(0, len(src) + 160, allocator)
	inserted := false
	for line in strings.split_lines(src, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if !inserted && strings.has_prefix(trimmed, "package ") {
			if need_feat {
				strings.write_string(&sb, "#+feature using-stmt\n")
			}
			strings.write_string(&sb, line)
			strings.write_byte(&sb, '\n')
			if need_imp {
				strings.write_string(&sb, spec.import_line)
				strings.write_byte(&sb, '\n')
			}
			if need_using {
				strings.write_string(&sb, using_line)
				strings.write_byte(&sb, '\n')
			}
			inserted = true
			continue
		}
		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}
	if !inserted {
		if need_feat {
			strings.write_string(&sb, "#+feature using-stmt\n")
		}
		if need_imp {
			strings.write_string(&sb, spec.import_line)
			strings.write_byte(&sb, '\n')
		}
		if need_using {
			strings.write_string(&sb, using_line)
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb), true
}

@(private = "file")
_inject_using_space_into_full_file :: #force_inline proc(src: string, spec: Using_Space_Spec, allocator := context.temp_allocator) -> (string, bool) {
	return inject_using_space_into_source(src, spec, allocator)
}

// =============================================================================
// Embedded Scoped Procedure / Node Editor & Embedded Full `.bodin` Script Panel
// (Hosted directly inside `Unified Graph Studio` for Split View & Script Mode!)
// =============================================================================

sync_and_draw_embedded_scoped_editor :: proc(
	target_key:       int,
	title:            string,
	signature_banner: string,
	pins:             []Scoped_Pin_Badge,
	current_body:     string,
	size:             im.Vec2 = {0, 0},
	full_decl_mode:   bool    = false,
) -> (
	updated_body:     string,
	body_edited:      bool,
	trigger_hotswap:  bool,
) {
	_ensure_zoom_init()
	p := thm.palette()

	need_reload := _emb_scoped.node_uid != target_key || !_emb_scoped.open || _emb_scoped.is_full_decl != full_decl_mode
	if need_reload {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		_clear_scoped_state(&_emb_scoped)
		_emb_scoped.open             = true
		_emb_scoped.is_graph_node    = true
		_emb_scoped.is_full_decl     = full_decl_mode
		_emb_scoped.node_uid         = target_key
		_emb_scoped.title            = strings.clone(title)
		_emb_scoped.signature_banner = strings.clone(signature_banner)
		for pin in pins {
			append(&_emb_scoped.pins, Scoped_Pin_Badge{
				name      = strings.clone(pin.name),
				odin_type = strings.clone(pin.odin_type),
				pass_mode = pin.pass_mode,
				is_output = pin.is_output,
			})
		}
		_copy_to_c_buf_grow(&_emb_scoped.buf, current_body, SCOPED_MIN_BUF_CAP)
		s_now := _c_buf_string(_emb_scoped.buf)
		code_undo_reset(&_emb_scoped.undo, s_now, 0)
		_notify_buffer_edited(s_now, !full_decl_mode, "")
		context.allocator = prev_a
	} else if _emb_scoped.signature_banner != signature_banner {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		if _emb_scoped.signature_banner != "" do delete(_emb_scoped.signature_banner)
		_emb_scoped.signature_banner = strings.clone(signature_banner)
		context.allocator = prev_a
	}

	snap := read_checker_snapshot(context.temp_allocator)
	_emb_scoped.focused = false
	if im.BeginChild("##emb_scoped_host", size, {.Borders}) {
		_emb_scoped.focused = im.IsWindowFocused({.ChildWindows})
		im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
		if im.Button(fmt.ctprintf("%s Bake & Hot-Swap (F7)", icons.ICON_MD_BOLT)) || (_emb_scoped.focused && im.IsKeyPressed(.F7, false)) {
			trigger_hotswap = true
		}
		im.PopStyleColor()
		widgets.tooltip("Save Odin code, transpile `.bodin`, and Hot-Swap `hot_cartridge` (~240 ms)!")

		im.SameLine()
		_draw_undo_redo_buttons(&_emb_scoped.undo, &_emb_scoped.buf, &_emb_scoped.ide, &_emb_scoped.dirty, "haati/hot_scripts", !full_decl_mode, "emb_sc")

		im.SameLine()
		if im.Button(fmt.ctprintf("%s Find (Ctrl+F)", icons.ICON_MD_SEARCH)) {
			_emb_scoped.ide.find_open       = !_emb_scoped.ide.find_open
			_emb_scoped.ide.find_focus_next = _emb_scoped.ide.find_open
		}
		im.SameLine()
		_draw_zoom_pill_controls("emb_sc")
		im.SameLine()
		_draw_checker_and_hot_pills(snap)
		im.Separator()

		_draw_scoped_using_chip_bar(&_emb_scoped, "##emb_using_spaces_popup", "##emb_using_q")

		if len(_emb_scoped.pins) > 0 {
			im.TextDisabled("Pins:")
			for pin in _emb_scoped.pins {
				im.SameLine()
				_draw_scoped_pin_badge(pin, false)
			}
		}

		err_h: f32 = len(snap.diagnostics) > 0 ? 110.0 : 28.0
		code_h := max(im.GetContentRegionAvail().y - err_h - 6.0, 96.0)
		if _draw_syntax_code_surface("##emb_scoped_code_surf", &_emb_scoped.buf, {0, code_h}, snap.diagnostics, &_emb_scoped.ide, _emb_scoped.pins[:], !full_decl_mode, nil, &_emb_scoped.undo, &_emb_scoped.dirty, "haati/hot_scripts") {
			body_edited = true
			_notify_buffer_edited(_c_buf_string(_emb_scoped.buf), !full_decl_mode, "")
		}
		if !full_decl_mode {
			im.TextColored(p.accent, "}")
			im.SameLine(0, 12)
		}
		_draw_ide_footer_telemetry(&_emb_scoped.ide)
		if len(snap.diagnostics) > 0 {
			if im.BeginChild("##emb_scoped_diags", {0, 0}, {.Borders}) {
				_draw_surface_diagnostics_panel("emb_sc_diag", snap.diagnostics, &_emb_scoped.ide)
			}
			im.EndChild()
		}
	}
	im.EndChild()

	updated_body = _c_buf_string(_emb_scoped.buf[:])
	if !body_edited && _emb_scoped.dirty && updated_body != current_body {
		body_edited       = true
		_emb_scoped.dirty = false
	}
	return updated_body, body_edited, trigger_hotswap
}

// =============================================================================
// Reusable `::` Blueprint Omnibar Scratchpad Surface (100% RAM Until Stage)
// =============================================================================

scratchpad_init_or_seed :: proc(sp: ^Scratchpad_Surface, seed_text: string) {
	if sp == nil do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	_copy_to_c_buf_grow(&sp.buf, seed_text, SCOPED_MIN_BUF_CAP)
	s_now := _c_buf_string(sp.buf)
	if !sp.undo.initialized {
		sp.ide = {ac_dismissed_pos = -1, cmd_jump_offset = -1}
		code_undo_reset(&sp.undo, s_now, len(s_now))
	} else {
		code_undo_record_edit(&sp.undo, s_now, len(s_now), im.GetTime(), true)
	}
	_arm_ide_restore(&sp.ide, s_now, len(s_now))
	if sp.last_src != "" do delete(sp.last_src)
	sp.last_src = strings.clone(s_now)
}

scratchpad_destroy :: proc(sp: ^Scratchpad_Surface) {
	if sp == nil do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if len(sp.buf) > 0 do delete(sp.buf)
	if sp.last_src != "" do delete(sp.last_src)
	code_undo_free(&sp.undo)
	_clear_ide_pending_restore(&sp.ide)
	_free_ide_surface_cache(&sp.ide)
	sp^ = {}
}

scratchpad_text :: proc(sp: ^Scratchpad_Surface) -> string {
	if sp == nil || len(sp.buf) == 0 do return ""
	return _c_buf_string(sp.buf)
}

scratchpad_draw_editor :: proc(
	sp:            ^Scratchpad_Surface,
	id:            cstring,
	max_work_size: im.Vec2,
) -> (
	code_now:           string,
	diags_err_count:    int,
	ctrl_enter_pressed: bool,
) {
	if sp == nil do return "", 0, false
	_ensure_zoom_init()
	if !sp.undo.initialized || len(sp.buf) == 0 {
		scratchpad_init_or_seed(sp, "my_proc :: proc(x: f32) -> f32 {\n    return x\n}")
	}

	src_before := _c_buf_string(sp.buf)
	sk, _, _, _ := analyze_odin_scratch_snippet(src_before, context.temp_allocator)
	ram_diags, _ := check_odin_syntax_in_ram(src_before, false, context.temp_allocator)
	// Struct field (`hp: f32`) & shorthand var (`hp := 1`) snippets target the Active Struct, not file-scope proc syntax.
	active_diags: []Studio_Diagnostic = nil
	if sk != .Field_Decl && sk != .Var_Decl {
		active_diags = ram_diags
	}
	for d in active_diags {
		if !d.is_warning do diags_err_count += 1
	}

	line_count := 1 + strings.count(src_before, "\n")
	zm := _studio_zoom_val()
	line_h := max(im.GetStyle().FontSizeBase * zm + 5.0, 18.0)
	max_w := max(max_work_size.x * 0.85, 420.0)
	max_h := max(max_work_size.y * 0.55, 180.0)
	ed_w := clamp(480.0 * zm, 380.0, max_w)
	ed_h := clamp(f32(clamp(line_count + 2, 4, 18)) * line_h + 18.0, 128.0, max_h)

	_ = _draw_syntax_code_surface(id, &sp.buf, {ed_w, ed_h}, active_diags, &sp.ide, nil, false, nil, &sp.undo, nil, "haati/hot_scripts")
	code_now = _c_buf_string(sp.buf)
	if code_now != sp.last_src {
		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		if sp.last_src != "" do delete(sp.last_src)
		sp.last_src = strings.clone(code_now)
		context.allocator = prev_alloc
	}

	if im.IsWindowFocused({.RootWindow, .ChildWindows}) && im.GetIO().KeyCtrl && (im.IsKeyPressed(.Enter, false) || im.IsKeyPressed(.KeypadEnter, false)) {
		ctrl_enter_pressed = true
	}
	return code_now, diags_err_count, ctrl_enter_pressed
}

// Forces an already-open tab for `abs_or_rel_path` to reload cleanly from disk (used after Blueprint bake!).
reload_file_tab_from_disk :: proc(abs_or_rel_path: string) {
	norm_abs := resolve_workspace_path(abs_or_rel_path, context.temp_allocator)
	for &t in _studio.tabs {
		if t.abs_path == norm_abs {
			if raw, err := os.read_entire_file(norm_abs, context.temp_allocator); err == nil {
				raw_str := string(raw)
				t.uses_tabs = detect_odin_hard_tabs(raw_str)
				_copy_to_c_buf_grow(&t.buf, raw_str, STUDIO_MIN_BUF_CAP)
				t.dirty = false
				s := _c_buf_string(t.buf)
				if t.undo.initialized {
					code_undo_record_edit(&t.undo, s, 0, im.GetTime(), true)
				} else {
					code_undo_reset(&t.undo, s, 0)
				}
				_notify_buffer_edited(s, false, t.pkg_dir)
			}
			return
		}
	}
}

draw_embedded_script_panel :: proc(abs_or_rel_path: string, size: im.Vec2 = {0, 0}) -> (req_save: bool, req_hotswap: bool) {
	_ensure_zoom_init()
	p  := thm.palette()
	io := im.GetIO()

	target_norm := _studio.last_emb_norm
	if abs_or_rel_path != "" {
		if abs_or_rel_path != _studio.last_emb_arg || target_norm == "" {
			norm_abs := resolve_workspace_path(abs_or_rel_path, context.temp_allocator)
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			if _studio.last_emb_arg  != "" do delete(_studio.last_emb_arg)
			if _studio.last_emb_norm != "" do delete(_studio.last_emb_norm)
			_studio.last_emb_arg    = strings.clone(abs_or_rel_path)
			_studio.last_emb_norm   = strings.clone(norm_abs)
			_studio.emb_user_closed = false
			context.allocator = prev_a
			target_norm = _studio.last_emb_norm
			_ = open_file_in_studio(norm_abs)
		}
	}

	emb_tab_idx := -1
	if target_norm != "" {
		for &tb, ti in _studio.tabs {
			if strings.equal_fold(tb.abs_path, target_norm) {
				emb_tab_idx = ti
				break
			}
		}
	} else if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		emb_tab_idx = _studio.active_tab
	}

	snap := read_checker_snapshot(context.temp_allocator)
	_studio.emb_full_focused = false
	if im.BeginChild("##emb_full_script_host", size, {.Borders}) {
		_studio.emb_full_focused = im.IsWindowFocused({.ChildWindows})
		if _studio.emb_full_focused && im.IsKeyPressed(.F2, false) {
			_cycle_next_diagnostic(snap, io.KeyShift ? -1 : 1)
		}
		has_emb := emb_tab_idx >= 0 && emb_tab_idx < len(_studio.tabs)
		if !has_emb do im.BeginDisabled()
		if im.Button(fmt.ctprintf("%s Save File (Ctrl+S)", icons.ICON_MD_SAVE)) || (has_emb && _studio.emb_full_focused && io.KeyCtrl && im.IsKeyPressed(.S, false)) {
			if has_emb {
				t := &_studio.tabs[emb_tab_idx]
				disk_src := format_studio_buffer_for_disk(_c_buf_string(t.buf), t.uses_tabs, context.temp_allocator)
				if os.write_entire_file(t.abs_path, transmute([]u8)disk_src) == nil {
					t.dirty = false
					req_save = true
					_notify_buffer_edited(_c_buf_string(t.buf), false, t.pkg_dir, true)
				}
			}
		}
		im.SameLine()
		im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
		if im.Button(fmt.ctprintf("%s Save & Hot-Swap (F7)", icons.ICON_MD_BOLT)) || (has_emb && _studio.emb_full_focused && im.IsKeyPressed(.F7, false)) {
			if has_emb {
				t := &_studio.tabs[emb_tab_idx]
				disk_src := format_studio_buffer_for_disk(_c_buf_string(t.buf), t.uses_tabs, context.temp_allocator)
				_ = os.write_entire_file(t.abs_path, transmute([]u8)disk_src)
				t.dirty = false
				_notify_buffer_edited(_c_buf_string(t.buf), false, t.pkg_dir, true)
			}
			req_save = true
			req_hotswap = true
		}
		im.PopStyleColor()
		if !has_emb do im.EndDisabled()

		if has_emb {
			act_emb := &_studio.tabs[emb_tab_idx]
			im.SameLine()
			_draw_undo_redo_buttons(&act_emb.undo, &act_emb.buf, &_studio.ide, &act_emb.dirty, act_emb.pkg_dir, false, "emb_full")
		}

		im.SameLine()
		if im.Button(fmt.ctprintf("%s Find (Ctrl+F)", icons.ICON_MD_SEARCH)) {
			_studio.ide.find_open       = !_studio.ide.find_open
			_studio.ide.find_focus_next = _studio.ide.find_open
		}
		im.SameLine()
		_draw_zoom_pill_controls("emb_full")
		im.SameLine()
		_draw_checker_and_hot_pills(snap)
		im.Separator()

		if has_emb {
			act := &_studio.tabs[emb_tab_idx]
			outline_syms := _get_cached_outline_symbols(_c_buf_string(act.buf))
			// Compact Symbol Jump strip
			im.TextColored(p.text_muted, "%s", fmt.ctprintf("%s%s:", act.title, act.dirty ? " *" : ""))
			im.SameLine()
			widgets.text_disabledf("Ln %d, Col %d", max(_studio.ide.caret_line, 1), max(_studio.ide.caret_col, 1))
			if len(outline_syms) > 0 {
				im.SameLine()
				im.TextDisabled("| Procs:")
				max_pills := min(len(outline_syms), 6)
				for si in 0 ..< max_pills {
					sym := outline_syms[si]
					im.SameLine()
					if im.SmallButton(fmt.ctprintf("%s##emb_sym_%d", sym.name, si)) {
						_jump_to_tab_line(act, sym.line)
					}
				}
			}

			_ = _draw_sibling_diag_banner(snap.diagnostics, act.abs_path)

			_, _, _, _, hot_stderr := engine.hot_cartridge_status()
			has_err_area := len(snap.diagnostics) > 0 || hot_stderr != ""
			err_h: f32 = has_err_area ? 116.0 : 28.0
			ed_h := max(im.GetContentRegionAvail().y - err_h - 6.0, 120.0)
			im.PushIDInt(i32(act.uid + 100000))
			emb_surf_edited := _draw_syntax_code_surface("##emb_full_code_surf", &act.buf, {0, ed_h}, snap.diagnostics, &_studio.ide, nil, false, &act.scroll_line, &act.undo, &act.dirty, act.pkg_dir, act.abs_path)
			im.PopID()
			if emb_surf_edited {
				act.dirty = true
				_notify_buffer_edited(_c_buf_string(act.buf), false, act.pkg_dir)
			}
			if _studio.ide.req_jump_ident != "" {
				_jump_to_definition_by_ident(act, _studio.ide.req_jump_ident, outline_syms)
				// _jump_to_definition_by_ident may open a new tab and reallocate _studio.tabs.
				if target_norm != "" {
					act = nil
					for &tb in _studio.tabs {
						if strings.equal_fold(tb.abs_path, target_norm) { act = &tb; break }
					}
				} else {
					act = (_studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)) ? &_studio.tabs[_studio.active_tab] : nil
				}
			}
			if snap.stage == .Pending_Syntax && hot_stderr == "" {
				widgets.text_disabledf("Typing... waiting %.2fs idle before checking problems", get_problem_check_delay_sec())
			} else if !has_err_area && snap.stage != .Compiler_Error && snap.stage != .Syntax_Error {
				im.TextColored(p.status_success, icons.ICON_MD_CHECK + " 0 Compiler Problems")
			} else if !has_err_area {
				im.TextColored(p.status_error, "%s", fmt.ctprintf("%s Typecheck Error — click status pill or Save", icons.ICON_MD_ERROR))
			} else {
				if im.BeginChild("##emb_full_diags", {0, 0}, {.Borders}) {
					if act != nil {
						_draw_surface_diagnostics_panel("emb_full_diag", snap.diagnostics, &_studio.ide, act, hot_stderr, 68.0, true, true)
					}
				}
				im.EndChild()
			}
		} else if _studio.emb_user_closed && target_norm != "" {
			im.Spacing()
			im.TextDisabled("Script tab was closed in Odin Micro-Studio.")
			if im.Button(fmt.ctprintf("%s Reopen Script Buffer", icons.ICON_MD_REFRESH)) {
				_studio.emb_user_closed = false
				_ = open_file_in_studio(target_norm)
			}
		} else {
			im.TextDisabled("Bake or save this `.bodin` script to open its full Odin source here.")
		}
	}
	im.EndChild()
	return req_save, req_hotswap
}
