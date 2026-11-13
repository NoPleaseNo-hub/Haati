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
import "core:fmt"
import "core:math"
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
import hot "haati:engine/hot_api"
import im "haati:external/odin-imgui"

STUDIO_BUF_CAP :: 96 * 1024 // 96 KB buffer for full files; scoped bodies are typically < 4 KB

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
	ac_open:            bool,
	ac_dismissed_pos:   int, // Suppresses re-opening at exact same cursor offset after `Esc`
	ac_selected_idx:    int,
	ac_replace_start:   int,
	ac_force_open:      bool,
	ac_pending_accept:  bool,
	ac_refocus_input:   bool,
	ac_accept_text:     [256]byte,
	ac_accept_len:      int,

	// Ctrl+Click symbol jump output (`req_jump_ident` set for 1 frame when user Ctrl+Clicks an identifier)
	req_jump_ident:     string,
	req_jump_rec:       string,

	// Pending IDE commands executed cleanly inside `CallbackAlways` where `ImGuiInputTextState` is live
	cmd_auto_indent:    bool,
	cmd_toggle_comment: bool,
	cmd_dup_line:       bool,
	cmd_outdent_tab:    bool,
	cmd_jump_offset:    int, // >= 0 jumps caret to byte offset (e.g. Find Next)

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
	find_open:          bool,
	find_focus_next:    bool,
	find_buf:           [128]byte,
	replace_buf:        [128]byte,
	goto_open:          bool,
	goto_focus_next:    bool,
	goto_buf:           [32]byte,
	cmd_move_line_dir:  int, // `-1` = Alt+Up, `+1` = Alt+Down
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
_Scoped_Popup_State :: struct {
	open:              bool,
	just_opened:       bool,
	enlarged:          bool, // Smart Enlarge / Zen Maximize state (`F11` or header button)
	apply_enlarge_pos: bool,
	saved_pos:         im.Vec2,
	saved_size:        im.Vec2,
	has_saved_rect:    bool,

	title:             string,
	signature_banner:  string,
	pins:              [dynamic]Scoped_Pin_Badge,

	// Mode 1: Backing an in-memory Niagara `Odin_Function_Node`
	is_graph_node:     bool,
	node_uid:          int,
	commit_cb:         Scoped_Node_Commit_Fn,
	commit_user_ptr:   rawptr,
	using_toggle_cb:   Scoped_Using_Toggle_Fn,
	using_query_cb:    Scoped_Using_Query_Fn,
	using_search_buf:  [64]byte,

	// Mode 2: Backing a real `.odin` procedure sliced out of `backing_file_abs`
	backing_file_abs:  string,
	backing_pkg_dir:   string,
	backing_proc_name: string,
	full_file_cache:   string,

	buf:               [32768]byte,
	dirty:             bool,
	focused:           bool,
	status_note:       string,
	ide:               _Surface_IDE_State,
	undo:              Code_Undo_Stack,
}

@(private = "file")
_Tab_Doc :: struct {
	title:       string,
	abs_path:    string,
	pkg_dir:     string,
	buf:         []byte,
	dirty:       bool,
	scroll_line: int,
	undo:        Code_Undo_Stack,
}

@(private = "file")
_Code_Nav_Entry :: struct {
	abs_path: string,
	line:     int,
}

@(private = "file")
_Studio_State :: struct {
	initialized:            bool,
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
	nav_stack:              [32]_Code_Nav_Entry,
	nav_len:                int,
	nav_cursor:             int,
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
	context.allocator = runtime.default_allocator()
	for &e in arr^ {
		if e.text != "" do delete(e.text)
	}
	clear(arr)
}

@(private = "file")
_clear_ide_pending_restore :: proc(ide: ^_Surface_IDE_State) {
	context.allocator = runtime.default_allocator()
	if ide.cmd_restore_text != "" {
		delete(ide.cmd_restore_text)
		ide.cmd_restore_text = ""
	}
	ide.cmd_restore_active = false
}

@(private = "file")
_arm_ide_restore :: proc(ide: ^_Surface_IDE_State, text: string, cursor: int) {
	_clear_ide_pending_restore(ide)
	context.allocator = runtime.default_allocator()
	ide.cmd_restore_text   = strings.clone(text)
	ide.cmd_restore_cursor = cursor
	ide.cmd_restore_active = true
	ide.cmd_jump_offset    = cursor
}

code_undo_reset :: proc(st: ^Code_Undo_Stack, initial_text: string, initial_cursor: int = 0) {
	context.allocator = runtime.default_allocator()
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
	context.allocator = runtime.default_allocator()
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
	context.allocator = runtime.default_allocator()
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

	context.allocator = runtime.default_allocator()
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
	buf:       []byte,
	ide:       ^_Surface_IDE_State,
	dirty:     ^bool,
	pkg_dir:   string,
	is_scoped: bool,
	ok:        bool,
) {
	if _scoped.open && _scoped.focused {
		return &_scoped.undo, _scoped.buf[:], &_scoped.ide, &_scoped.dirty, _scoped.backing_pkg_dir, true, true
	}
	if _emb_scoped.open && _emb_scoped.focused {
		return &_emb_scoped.undo, _emb_scoped.buf[:], &_emb_scoped.ide, &_emb_scoped.dirty, "haati/hot_scripts", true, true
	}
	if (_studio.window_focused || _studio.emb_full_focused) && _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		t := &_studio.tabs[_studio.active_tab]
		return &t.undo, t.buf, &_studio.ide, &t.dirty, t.pkg_dir, false, true
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
	buf:       []byte,
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
	_copy_to_c_buf(buf, entry.text)
	if dirty != nil do dirty^ = true
	_arm_ide_restore(ide, entry.text, entry.cursor)
	ide.ac_open          = false
	ide.ac_dismissed_pos = -1
	s_now := _c_buf_string(buf)
	submit_async_check(s_now, is_scoped, pkg_dir)
	submit_async_autocomplete_index(s_now, is_scoped, is_scoped && pkg_dir == "" ? "haati/hot_scripts" : pkg_dir)
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
	buf:       []byte,
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

configure_ide_defaults :: proc(explorer_zm, code_zm, problems_zm: f32, breadcrumbs, error_lens, sync_panes: bool) {
	_ensure_zoom_init()
	_studio.show_breadcrumbs = breadcrumbs
	_studio.show_error_lens  = error_lens
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

// Registers Blueprint `Using` namespace toggle/query hooks for the Scoped Node Popup IDE.
set_scoped_using_hooks :: proc(toggle_cb: Scoped_Using_Toggle_Fn, query_cb: Scoped_Using_Query_Fn) {
	_scoped.using_toggle_cb = toggle_cb
	_scoped.using_query_cb  = query_cb
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

shutdown_studio :: proc() {
	shutdown_checker()
	shutdown_autocomplete()
	context.allocator = runtime.default_allocator()
	for &tab in _studio.tabs {
		delete(tab.title)
		delete(tab.abs_path)
		delete(tab.pkg_dir)
		delete(tab.buf)
		code_undo_free(&tab.undo)
	}
	delete(_studio.tabs)
	_clear_ide_pending_restore(&_studio.ide)
	for f in _studio.discovered_files do delete(f)
	delete(_studio.discovered_files)
	for i in 0 ..< _studio.nav_len {
		if _studio.nav_stack[i].abs_path != "" do delete(_studio.nav_stack[i].abs_path)
	}
	_studio = {}

	_clear_scoped_state(&_scoped)
	delete(_scoped.pins)
	_scoped = {}

	_clear_scoped_state(&_emb_scoped)
	delete(_emb_scoped.pins)
	_emb_scoped = {}
}

@(private = "file")
_clear_scoped_strings :: #force_inline proc() {
	_clear_scoped_state(&_scoped)
}

@(private = "file")
_clear_scoped_state :: proc(s: ^_Scoped_Popup_State) {
	context.allocator = runtime.default_allocator()
	if s.title             != "" do delete(s.title)
	if s.signature_banner  != "" do delete(s.signature_banner)
	if s.backing_file_abs  != "" do delete(s.backing_file_abs)
	if s.backing_pkg_dir   != "" do delete(s.backing_pkg_dir)
	if s.backing_proc_name != "" do delete(s.backing_proc_name)
	if s.full_file_cache   != "" do delete(s.full_file_cache)
	if s.status_note       != "" do delete(s.status_note)
	for p in s.pins {
		delete(p.name)
		delete(p.odin_type)
	}
	clear(&s.pins)
	_clear_ide_pending_restore(&s.ide)
	code_undo_free(&s.undo)
	s.title             = ""
	s.signature_banner  = ""
	s.backing_file_abs  = ""
	s.backing_pkg_dir   = ""
	s.backing_proc_name = ""
	s.full_file_cache   = ""
	s.status_note       = ""
	s.focused           = false
	s.ide               = {ac_dismissed_pos = -1, cmd_jump_offset = -1}
}

@(private = "file")
_copy_to_c_buf :: proc(dst: []byte, text: string) {
	// Normalize `\t` to 4 spaces so `im.CalcTextSize` sub-pixel syntax overlay matches `InputTextMultiline` 1:1!
	norm, _ := strings.replace_all(text, "\t", "    ", context.temp_allocator)
	clean, _ := strings.replace_all(norm, "\r\n", "\n", context.temp_allocator)
	n := min(len(clean), len(dst) - 1)
	if n > 0 do copy(dst[:n], clean[:n])
	for i := n; i < len(dst); i += 1 do dst[i] = 0
}

@(private = "file")
_c_buf_string :: proc(buf: []byte) -> string {
	return string(cstring(raw_data(buf)))
}

@(private = "file")
_infer_pkg_dir :: proc(abs_path: string, allocator := context.temp_allocator) -> string {
	norm, _ := strings.replace_all(abs_path, "\\", "/", context.temp_allocator)
	if strings.has_suffix(norm, ".bodin") {
		return strings.clone("haati/hot_scripts", allocator)
	}
	if idx := strings.index(norm, "haati/"); idx >= 0 {
		dir: string
		{
			context.allocator = context.temp_allocator
			dir = filepath.dir(norm[idx:])
		}
		dnorm, _ := strings.replace_all(dir, "\\", "/", allocator)
		return dnorm
	}
	if idx := strings.index(norm, "plugins/"); idx >= 0 {
		rel := norm[idx + len("plugins/"):]
		dir: string
		{
			context.allocator = context.temp_allocator
			dir = filepath.dir(rel)
		}
		dnorm, _ := strings.replace_all(dir, "\\", "/", context.temp_allocator)
		return fmt.aprintf("haati/packages/%s", dnorm, allocator = allocator)
	}
	return ""
}

// =============================================================================
// Public Openers: Scoped Node Popup, Scoped `.odin` Procedure Popup, & Full File
// =============================================================================

open_scoped_node_popup :: proc(
	node_uid: int,
	node_title: string,
	signature_banner: string,
	pins: []Scoped_Pin_Badge,
	initial_body: string,
	commit_cb: Scoped_Node_Commit_Fn,
	user_ptr: rawptr = nil,
) {
	context.allocator = runtime.default_allocator()
	_clear_scoped_strings()

	_scoped.open             = true
	_scoped.just_opened      = true
	_scoped.is_graph_node    = true
	_scoped.node_uid         = node_uid
	_scoped.title            = strings.clone(node_title)
	_scoped.signature_banner = strings.clone(signature_banner)
	_scoped.commit_cb        = commit_cb
	_scoped.commit_user_ptr  = user_ptr
	_scoped.dirty            = false

	for pin in pins {
		append(&_scoped.pins, Scoped_Pin_Badge{
			name      = strings.clone(pin.name),
			odin_type = strings.clone(pin.odin_type),
			pass_mode = pin.pass_mode,
			is_output = pin.is_output,
		})
	}

	_copy_to_c_buf(_scoped.buf[:], initial_body)
	body_str := _c_buf_string(_scoped.buf[:])
	code_undo_reset(&_scoped.undo, body_str, 0)
	submit_async_check(body_str, true, "")
	submit_async_autocomplete_index(body_str, true, "haati/hot_scripts")
}

open_scoped_proc_popup :: proc(title: string, abs_or_rel_file: string, proc_name: string) -> bool {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	resolved := abs_or_rel_file
	if !os.exists(resolved) {
		cand1, _ := filepath.join({repo_root, abs_or_rel_file}, context.temp_allocator)
		cand2, _ := filepath.join({repo_root, "haati", abs_or_rel_file}, context.temp_allocator)
		if os.exists(cand1) do resolved = cand1
		else if os.exists(cand2) do resolved = cand2
	}
	raw, rerr := os.read_entire_file(resolved, context.temp_allocator)
	if rerr != nil do return false

	sliced, ok := slice_odin_procedure(string(raw), proc_name, context.temp_allocator)
	if !ok {
		open_file_in_studio(resolved)
		wnd.open("odin_micro_studio")
		return true
	}

	pkg_dir := _infer_pkg_dir(resolved, context.temp_allocator)
	{
		context.allocator = runtime.default_allocator()
		_clear_scoped_strings()
		_scoped.open              = true
		_scoped.just_opened       = true
		_scoped.is_graph_node     = false
		_scoped.title             = strings.clone(title)
		_scoped.signature_banner  = strings.clone(sliced.signature_banner)
		_scoped.backing_file_abs  = strings.clone(resolved)
		_scoped.backing_pkg_dir   = strings.clone(pkg_dir)
		_scoped.backing_proc_name = strings.clone(proc_name)
		_scoped.full_file_cache   = strings.clone(string(raw))
		_scoped.dirty             = false
	}

	_copy_to_c_buf(_scoped.buf[:], sliced.body_text)
	body_str := _c_buf_string(_scoped.buf[:])
	code_undo_reset(&_scoped.undo, body_str, 0)
	submit_async_check(body_str, true, pkg_dir)
	submit_async_autocomplete_index(body_str, true, pkg_dir)
	return true
}

@(private = "file")
_canonical_studio_path :: proc(abs_or_rel_path: string, allocator := context.temp_allocator) -> string {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	resolved := abs_or_rel_path
	if !filepath.is_abs(resolved) {
		cand1, _ := filepath.join({repo_root, abs_or_rel_path}, context.temp_allocator)
		cand2, _ := filepath.join({repo_root, "haati", abs_or_rel_path}, context.temp_allocator)
		if os.exists(cand1) {
			resolved = cand1
		} else if os.exists(cand2) {
			resolved = cand2
		} else if !os.exists(resolved) {
			resolved = cand1
		}
	}
	norm, _ := strings.replace_all(resolved, "\\", "/", allocator)
	return norm
}

open_file_in_studio :: proc(abs_or_rel_path: string, jump_line: int = 0) -> bool {
	_ensure_zoom_init()
	norm_abs := _canonical_studio_path(abs_or_rel_path, context.temp_allocator)

	for &t, idx in _studio.tabs {
		if t.abs_path == norm_abs {
			was_active := (_studio.active_tab == idx)
			_studio.active_tab = idx
			_studio.request_tab_select = idx
			if jump_line > 0 do t.scroll_line = jump_line
			if !was_active {
				s := _c_buf_string(t.buf)
				submit_async_check(s, false, t.pkg_dir)
				submit_async_autocomplete_index(s, false, t.pkg_dir)
			}
			return true
		}
	}

	raw, rerr := os.read_entire_file(norm_abs, context.temp_allocator)
	if rerr != nil do return false

	pkg_dir := _infer_pkg_dir(norm_abs, context.temp_allocator)
	base_name := filepath.base(norm_abs)

	context.allocator = runtime.default_allocator()
	buf := make([]byte, STUDIO_BUF_CAP)
	_copy_to_c_buf(buf, string(raw))
	s := _c_buf_string(buf)
	new_tab := _Tab_Doc{
		title       = strings.clone(base_name),
		abs_path    = strings.clone(norm_abs),
		pkg_dir     = strings.clone(pkg_dir),
		buf         = buf,
		dirty       = false,
		scroll_line = jump_line,
	}
	code_undo_reset(&new_tab.undo, s, 0)
	append(&_studio.tabs, new_tab)
	_studio.active_tab = len(_studio.tabs) - 1
	_studio.request_tab_select = _studio.active_tab
	_clear_ide_pending_restore(&_studio.ide)
	_studio.ide = {ac_dismissed_pos = -1, cmd_jump_offset = -1}
	submit_async_check(s, false, pkg_dir)
	submit_async_autocomplete_index(s, false, pkg_dir)
	return true
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
	if data == nil || data.UserData == nil do return 0
	ide := cast(^_Surface_IDE_State)data.UserData

	// 1. Character Filter (`Enter` accepts autocomplete when open, or triggers Smart Auto-Indent!)
	if .CallbackCharFilter in data.EventFlag {
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
		ide.next_edit_immediate = true
		if ide.ac_open && ide.ac_accept_len > 0 {
			ide.ac_pending_accept = true
		} else if ide.cmd_outdent_tab {
			ide.cmd_outdent_tab = false
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
				max_ins := max(int(data.BufSize) - 1, 0)
				src_txt := len(ide.cmd_restore_text) > max_ins ? ide.cmd_restore_text[:max_ins] : ide.cmd_restore_text
				c_txt := strings.clone_to_cstring(src_txt, context.temp_allocator)
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
			ide.ac_pending_accept   = false
			ide.next_edit_immediate = true
			rep_s := clamp(i32(ide.ac_replace_start), 0, data.CursorPos)
			del_n := data.CursorPos - rep_s
			if del_n > 0 {
				im.InputTextCallbackData_DeleteChars(data, rep_s, del_n)
			}
			ide.ac_accept_text[min(ide.ac_accept_len, len(ide.ac_accept_text) - 1)] = 0
			im.InputTextCallbackData_InsertChars(data, rep_s, cstring(raw_data(ide.ac_accept_text[:])))
			ide.ac_open = false
			ide.ac_dismissed_pos = int(data.CursorPos)
		}

		// 4b. Apply Smart Auto-Indent right after ImGui inserts `'\n'`!
		if ide.cmd_auto_indent {
			ide.cmd_auto_indent = false
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

		// 4c. `Ctrl + /` Toggle Line Comment (`// `)
		if ide.cmd_toggle_comment {
			ide.cmd_toggle_comment  = false
			ide.next_edit_immediate = true
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

		// 4d. `Ctrl + D` Duplicate Current Line
		if ide.cmd_dup_line {
			ide.cmd_dup_line        = false
			ide.next_edit_immediate = true
			raw_ptr := cast([^]byte)data.Buf
			s := string(raw_ptr[:data.BufTextLen])
			ls, le := _line_bounds_at(s, int(data.CursorPos))
			line_len := le - ls
			if line_len + 2 < 1024 && int(data.BufTextLen) + line_len + 2 < int(data.BufSize) {
				var_dup: [1024]byte
				var_dup[0] = '\n'
				if line_len > 0 {
					for k in 0 ..< line_len do var_dup[1 + k] = s[ls + k]
				}
				var_dup[1 + line_len] = 0
				im.InputTextCallbackData_InsertChars(data, i32(le), cstring(raw_data(var_dup[:])))
			}
		}

		// 4e. `Alt + Up / Down` Move Current Line
		if ide.cmd_move_line_dir != 0 {
			dir := ide.cmd_move_line_dir
			ide.cmd_move_line_dir   = 0
			ide.next_edit_immediate = true
			raw_ptr := cast([^]byte)data.Buf
			s := string(raw_ptr[:data.BufTextLen])
			if moved, new_cpos, ok := move_line_in_source(s, int(data.CursorPos), dir, context.temp_allocator); ok {
				if len(moved) + 1 < int(data.BufSize) {
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
_draw_find_replace_bar :: proc(ide: ^_Surface_IDE_State, buf: []byte, scroll_to_line: ^int = nil) -> (modified: bool) {
	if !ide.find_open do return false

	p := thm.palette()
	im.PushStyleColorImVec4(.ChildBg, p.is_light ? thm.lerp_col(p.bg_canvas, p.accent, 0.08) : thm.lerp_col(p.bg_canvas, p.accent, 0.14))
	if im.BeginChild("##ide_find_bar", {0, 32}, {.Borders}) {
		im.TextColored(p.accent, icons.ICON_MD_SEARCH + " Find:")
		im.SameLine()
		if ide.find_focus_next {
			im.SetKeyboardFocusHere()
			ide.find_focus_next = false
		}
		im.SetNextItemWidth(170)
		find_enter := im.InputTextWithHint("##ide_find_q", "Search text...", cstring(raw_data(ide.find_buf[:])), len(ide.find_buf), {.EnterReturnsTrue})

		src := _c_buf_string(buf)
		q   := _c_buf_string(ide.find_buf[:])
		rep := _c_buf_string(ide.replace_buf[:])

		// Count matches
		match_count := 0
		if len(q) > 0 {
			scan_off := 0
			for scan_off <= len(src) - len(q) {
				if idx := strings.index(src[scan_off:], q); idx >= 0 {
					match_count += 1
					scan_off += idx + max(len(q), 1)
				} else {
					break
				}
			}
		}

		im.SameLine()
		if (im.SmallButton("Next") || find_enter) && len(q) > 0 {
			search_from := clamp(ide.cursor_pos + 1, 0, len(src))
			found := strings.index(src[search_from:], q)
			abs_idx := found >= 0 ? (search_from + found) : strings.index(src, q)
			if abs_idx >= 0 {
				ide.cmd_jump_offset = abs_idx
				if scroll_to_line != nil {
					ln := 1
					for i in 0 ..< abs_idx do if src[i] == '\n' do ln += 1
					scroll_to_line^ = ln
				}
			}
		}
		im.SameLine()
		im.TextDisabled("%s", fmt.ctprintf("(%d)", match_count))

		im.SameLine()
		im.TextDisabled("Replace:")
		im.SameLine()
		im.SetNextItemWidth(150)
		im.InputTextWithHint("##ide_rep_q", "With...", cstring(raw_data(ide.replace_buf[:])), len(ide.replace_buf))

		im.SameLine()
		if im.SmallButton("Replace All") && len(q) > 0 && match_count > 0 {
			replaced, was_alloc := strings.replace_all(src, q, rep, context.temp_allocator)
			_ = was_alloc
			_copy_to_c_buf(buf, replaced)
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

@(private = "file")
_draw_syntax_code_surface :: proc(
	child_id:       cstring,
	buf:            []byte,
	size:           im.Vec2,
	diags:          []Studio_Diagnostic,
	ide:            ^_Surface_IDE_State,
	pins:           []Scoped_Pin_Badge = nil,
	is_scoped_body: bool               = false,
	scroll_to_line: ^int               = nil,
	undo:           ^Code_Undo_Stack   = nil,
	dirty:          ^bool              = nil,
	pkg_dir:        string             = "",
) -> (edited: bool) {
	_ensure_zoom_init()
	p  := thm.palette()
	io := im.GetIO()

	// Inline Find & Replace Bar (`Ctrl+F`) + Go-to-Line Bar (`Ctrl+G`)
	discrete_replace := false
	if _draw_find_replace_bar(ide, buf, scroll_to_line) {
		edited           = true
		discrete_replace = true
	}
	_draw_goto_line_bar(ide, buf, scroll_to_line)

	child_size := size
	if ide.find_open && child_size.y > 40.0 {
		child_size.y -= 36.0
	}
	if ide.goto_open && child_size.y > 40.0 {
		child_size.y -= 36.0
	}

	// Push crisp vector-rasterized scaled font (`PushFontFloat` in ImGui 1.92) BEFORE `BeginChild`
	// so line heights, gutter numbers, caret, selection, and colored syntax tokens match 1:1!
	scaled_font_px := im.GetStyle().FontSizeBase * _studio_zoom_val()
	im.PushFontFloat(nil, scaled_font_px)
	defer im.PopFont()

	im.PushStyleColorImVec4(.ChildBg, p.is_light ? thm.lerp_col(p.bg_canvas, {1, 1, 1, 1}, 0.5) : thm.lerp_col(p.bg_canvas, {0, 0, 0, 1}, 0.28))
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
		} else if im.IsKeyPressed(.F, false) {
			ide.find_open       = true
			ide.find_focus_next = true
		} else if im.IsKeyPressed(.G, false) {
			ide.goto_open       = !ide.goto_open
			ide.goto_focus_next = ide.goto_open
		} else if im.IsKeyPressed(.Slash, false) {
			ide.cmd_toggle_comment = true
		} else if im.IsKeyPressed(.D, false) {
			ide.cmd_dup_line = true
		} else if im.IsKeyPressed(.V, false) || im.IsKeyPressed(.X, false) {
			ide.next_edit_immediate = true
		} else if im.IsKeyPressed(.Space, false) {
			ide.ac_force_open    = true
			ide.ac_dismissed_pos = -1
		}
		if undo != nil && im.GetFrameCount() != _studio.last_undo_redo_frame {
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
	if surface_focused && ide.ac_open && !io.KeyAlt && !io.KeyCtrl {
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
	if surface_focused && io.KeyAlt && !io.KeyCtrl {
		if im.IsKeyPressed(.UpArrow, false) {
			ide.cmd_move_line_dir = -1
		} else if im.IsKeyPressed(.DownArrow, false) {
			ide.cmd_move_line_dir = 1
		}
	}
	if surface_focused && io.KeyShift && im.IsKeyPressed(.Tab, false) && !ide.ac_open {
		ide.cmd_outdent_tab = true
	}
	if surface_focused && im.IsKeyPressed(.Escape, false) {
		if ide.ac_open {
			ide.ac_open          = false
			ide.ac_force_open    = false
			ide.ac_dismissed_pos = ide.cursor_pos
		} else if ide.goto_open {
			ide.goto_open = false
		} else if ide.find_open {
			ide.find_open = false
		}
	}

	src_before  := _c_buf_string(buf)
	line_starts := compute_line_starts(src_before, context.temp_allocator)
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

	if scroll_to_line != nil && scroll_to_line^ > 0 {
		im.SetScrollY(max(f32(scroll_to_line^ - 3) * line_h, 0.0))
		scroll_to_line^ = 0
	}

	diag_by_line := make(map[int]Studio_Diagnostic, context.temp_allocator)
	for d in diags {
		if !(d.line in diag_by_line) {
			diag_by_line[d.line] = d
		}
	}

	origin  := im.GetCursorScreenPos()
	dl      := im.GetWindowDrawList()
	avail   := im.GetContentRegionAvail()
	total_h := max(f32(num_lines + 5) * line_h + pad_y * 2.0, avail.y)

	max_line_px := avail.x - gutter_w
	for ln_i in 0 ..< len(line_starts) {
		ls := line_starts[ln_i]
		le := ln_i + 1 < len(line_starts) ? (line_starts[ln_i + 1] - 1) : len(src_before)
		if le > ls && src_before[le - 1] == '\r' do le -= 1
		if le > ls {
			w := im.CalcTextSize(fmt.ctprintf("%s", src_before[ls:le])).x + 64.0
			if w > max_line_px do max_line_px = w
		}
	}

	// 1. Gutter backdrop, Active Caret Line Highlight, & Error Line Tinting
	gutter_bg := p.is_light ? thm.lerp_col(p.bg_canvas, {0, 0, 0, 1}, 0.04) : thm.lerp_col(p.bg_canvas, {1, 1, 1, 1}, 0.03)
	im.DrawList_AddRectFilled(dl, origin, {origin.x + gutter_w, origin.y + total_h}, im.GetColorU32ImVec4(gutter_bg))
	im.DrawList_AddLine(dl, {origin.x + gutter_w, origin.y}, {origin.x + gutter_w, origin.y + total_h}, im.GetColorU32ImVec4(p.border_subtle), 1.0)

	for ln := 1; ln <= num_lines; ln += 1 {
		ly := origin.y + pad_y + f32(ln - 1) * line_h
		if ln == caret_ln && surface_focused {
			act_tint := p.is_light ? thm.with_alpha(p.accent, 0.07) : im.Vec4{1.0, 1.0, 1.0, 0.04}
			im.DrawList_AddRectFilled(dl, {origin.x + gutter_w + 1, ly}, {origin.x + gutter_w + max_line_px, ly + line_h}, im.GetColorU32ImVec4(act_tint))
		}
		if d, has_d := diag_by_line[ln]; has_d {
			row_tint := d.is_warning ? im.Vec4{0.95, 0.72, 0.20, 0.14} : im.Vec4{0.96, 0.26, 0.28, 0.16}
			im.DrawList_AddRectFilled(dl, {origin.x + gutter_w + 1, ly}, {origin.x + gutter_w + max_line_px, ly + line_h}, im.GetColorU32ImVec4(row_tint))
			dot_col := d.is_warning ? im.Vec4{0.98, 0.78, 0.25, 1.0} : im.Vec4{1.0, 0.34, 0.36, 1.0}
			im.DrawList_AddCircleFilled(dl, {origin.x + 8.0, ly + line_h * 0.5}, 3.5, im.GetColorU32ImVec4(dot_col))

			im.SetCursorScreenPos({origin.x, ly})
			im.InvisibleButton(fmt.ctprintf("##ln_err_%d", ln), {gutter_w, line_h})
			widgets.tooltip(fmt.ctprintf("Line %d:%d — %s", d.line, d.column, d.message))
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

	in_flags: im.InputTextFlags = {.NoUndoRedo, .CallbackAlways, .CallbackCompletion, .CallbackCharFilter}

	prev_cursor := ide.cursor_pos
	if ide.ac_refocus_input {
		im.SetKeyboardFocusHere()
		ide.ac_refocus_input = false
	}
	if im.InputTextMultiline(
		"##odin_code_input",
		cstring(raw_data(buf)),
		uint(len(buf)),
		{max_line_px, total_h},
		in_flags,
		_code_input_callback,
		ide,
	) {
		edited = true
	}
	input_active := im.IsItemActive()
	im.PopStyleColor(4)
	im.PopStyleVar(2)

	if ide.cmd_restore_active {
		_clear_ide_pending_restore(ide)
	}
	just_restored := ide.cmd_restore_applied
	ide.cmd_restore_applied = false

	if edited {
		cur_s := _c_buf_string(buf)
		if strings.contains_rune(cur_s, '\t') {
			_copy_to_c_buf(buf, cur_s)
			cur_s = _c_buf_string(buf)
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

	// 4. Paint `core:odin/tokenizer` Syntax Spans & Red Diagnostic Underlines!
	src_now := _c_buf_string(buf)
	ls_now  := compute_line_starts(src_now, context.temp_allocator)
	spans   := tokenize_odin_lines(src_now, ls_now, context.temp_allocator)

	span_idx := 0
	for ln_i in 0 ..< len(ls_now) {
		ln := ln_i + 1
		ls := ls_now[ln_i]
		le := ln_i + 1 < len(ls_now) ? (ls_now[ln_i + 1] - 1) : len(src_now)
		if le > ls && src_now[le - 1] == '\r' do le -= 1
		line_str := le > ls ? src_now[ls:le] : ""
		ly := origin.y + pad_y + f32(ln_i) * line_h
		base_x := code_x + pad_x

		if len(line_str) > 0 {
			col_cursor := 0
			for span_idx < len(spans) && spans[span_idx].line < ln {
				span_idx += 1
			}
			for span_idx < len(spans) && spans[span_idx].line == ln {
				sp := spans[span_idx]
				span_idx += 1
				cs := clamp(sp.col_start, col_cursor, len(line_str))
				ce := clamp(sp.col_end, cs, len(line_str))
				if cs > col_cursor {
					x_off := col_cursor > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:col_cursor])).x : 0.0
					im.DrawList_AddText(dl, {base_x + x_off, ly}, im.GetColorU32ImVec4(p.text_primary), fmt.ctprintf("%s", line_str[col_cursor:cs]))
				}
				if ce > cs {
					x_off := cs > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:cs])).x : 0.0
					col := role_color(sp.role, &p)
					im.DrawList_AddText(dl, {base_x + x_off, ly}, im.GetColorU32ImVec4(col), fmt.ctprintf("%s", line_str[cs:ce]))
				}
				col_cursor = ce
			}
			if col_cursor < len(line_str) {
				x_off := col_cursor > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:col_cursor])).x : 0.0
				im.DrawList_AddText(dl, {base_x + x_off, ly}, im.GetColorU32ImVec4(p.text_primary), fmt.ctprintf("%s", line_str[col_cursor:]))
			}
		}

		if d, has_d := diag_by_line[ln]; has_d {
			c0 := clamp(d.column - 1, 0, len(line_str))
			c1 := clamp(max(d.end_column - 1, c0 + 4), 0, len(line_str))
			x0 := c0 > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:c0])).x : 0.0
			x1 := c1 > c0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str[:c1])).x : (x0 + 28.0)
			u_col := d.is_warning ? im.Vec4{0.98, 0.78, 0.25, 0.95} : im.Vec4{1.0, 0.32, 0.34, 0.95}
			im.DrawList_AddLine(dl, {base_x + x0, ly + line_h - 1.0}, {base_x + max(x1, x0 + 18.0), ly + line_h - 1.0}, im.GetColorU32ImVec4(u_col), 2.0)

			// Inline Diagnostic Error Lens (JetBrains / VS Error Lens right after line content)
			if _studio.show_error_lens && d.message != "" {
				line_end_x := len(line_str) > 0 ? im.CalcTextSize(fmt.ctprintf("%s", line_str)).x : 0.0
				lens_col   := d.is_warning ? im.Vec4{0.96, 0.78, 0.30, 0.80} : im.Vec4{1.0, 0.44, 0.46, 0.86}
				lens_msg   := len(d.message) > 96 ? fmt.tprintf("%s...", d.message[:96]) : d.message
				im.DrawList_AddText(
					dl,
					{base_x + line_end_x + 22.0, ly},
					im.GetColorU32ImVec4(lens_col),
					fmt.ctprintf("// [%s] %s", d.is_warning ? "Warn" : "Error", lens_msg),
				)
			}
		}
	}

	// Compute screen coordinates of the live caret for anchoring the Smart Autocomplete Popup!
	caret_screen_pos := im.Vec2{code_x + pad_x, origin.y + pad_y + f32(max(ide.caret_line - 1, 0) + 1) * line_h + 2.0}
	if ide.caret_line >= 1 && ide.caret_line <= len(ls_now) {
		ls_c := ls_now[ide.caret_line - 1]
		c_end := clamp(ide.cursor_pos, ls_c, len(src_now))
		if c_end > ls_c {
			caret_screen_pos.x += im.CalcTextSize(fmt.ctprintf("%s", src_now[ls_c:c_end])).x
		}
	}

	// Stationary Idle-Delay Hover Symbol Type, Signature & `//` Doc-Comment Peek (`0 ms` main-thread hit-test!)
	// PLUS JetBrains `Ctrl + Left-Click` Go-To-Definition!
	hover_peek_str   := ""
	hover_ident_hash := u64(0)
	ide.req_jump_ident = ""
	ide.req_jump_rec   = ""
	if im.IsWindowHovered() && !ide.ac_open && (!im.IsMouseDown(.Left) || im.IsMouseClicked(.Left)) {
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
						w_ci := im.CalcTextSize(fmt.ctprintf("%s", hline[:ci + 1])).x
						if rel_x <= w_ci {
							hit_col = ci
							break
						}
					}
					if hit_col >= 0 && _is_code_ident_byte(hline[hit_col]) {
						ws := hit_col
						for ws > 0 && _is_code_ident_byte(hline[ws - 1]) do ws -= 1
						we := hit_col + 1
						for we < len(hline) && _is_code_ident_byte(hline[we]) do we += 1
						ident := hline[ws:we]
						rec := ""
						if ws > 1 && hline[ws - 1] == '.' {
							rs := ws - 1
							for rs > 0 && _is_code_ident_byte(hline[rs - 1]) do rs -= 1
							if ws - 1 > rs do rec = hline[rs:ws - 1]
						}
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
							for he in engine.hot_proc_entries() {
								if he.name == ident && he.source_file != "" {
									doc_str = extract_odin_proc_doc_from_file(he.source_file, ident, context.temp_allocator)
									break
								}
							}
						}
						if doc_str != "" && !strings.contains(base_info, doc_str) {
							hover_peek_str = base_info != "" \
								? fmt.tprintf("%s\n\n%s", base_info, doc_str) \
								: fmt.tprintf("proc %s\n\n%s", ident, doc_str)
						} else {
							hover_peek_str = base_info
						}
						h := u64(14695981039346656037)
						for b in transmute([]byte)ident {
							h = (h ~ u64(b)) * 1099511628211
						}
						hover_ident_hash = h ~ (u64(h_ln_i + 1) << 32)
					}
				}
			}
		}
	}

	im.EndChild()

	if hover_peek_str != "" {
		widgets.tooltip_unchecked_delayed(hover_ident_hash, fmt.ctprintf("%s", hover_peek_str))
	}

	// 5. Evaluate & Render Non-Blocking Floating Smart Autocomplete Popup + Inline Call-Tip Signature Pill!
	if input_active {
		if tip, has_tip := extract_call_tip_info(src_now, ide.cursor_pos, context.temp_allocator); has_tip {
			_draw_call_tip_pill({caret_screen_pos.x, caret_screen_pos.y - line_h * 2.15 - 6.0}, tip)
		}
	}

	if input_active && ide.cursor_pos != ide.ac_dismissed_pos {
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

			_draw_autocomplete_popup(caret_screen_pos, ac_items, ide)
		} else {
			ide.ac_open       = false
			ide.ac_accept_len = 0
		}
	} else if !input_active {
		ide.ac_open       = false
		ide.ac_force_open = false
		ide.ac_accept_len = 0
	}

	return edited
}

@(private = "file")
_is_code_ident_byte :: #force_inline proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
_draw_call_tip_pill :: proc(above_caret_pos: im.Vec2, tip: Call_Tip_Info) {
	p  := thm.palette()
	vp := im.GetMainViewport()
	pos := im.Vec2{
		clamp(above_caret_pos.x, vp.Pos.x + 12.0, vp.Pos.x + vp.Size.x - 360.0),
		max(above_caret_pos.y, vp.Pos.y + 12.0),
	}

	im.SetNextWindowPos(pos, .Always)
	im.PushStyleColorImVec4(.WindowBg, p.is_light ? im.Vec4{0.96, 0.98, 1.0, 0.98} : im.Vec4{0.08, 0.11, 0.16, 0.97})
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.accent, 0.72))
	im.PushStyleVar(.WindowBorderSize, 1.1)
	im.PushStyleVar(.WindowRounding, 5.0)
	im.PushStyleVarImVec2(.WindowPadding, {8, 4})

	// NOTE: Never pass internal `WindowFlag.Tooltip` (bit 25) to `im.Begin()` — Dear ImGui asserts `IM_ASSERT` (`SIGABRT`)!
	im.SetNextWindowBgAlpha(0.96)
	flags: im.WindowFlags = {.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings, .NoFocusOnAppearing, .NoMouseInputs, .NoNavInputs, .NoNavFocus, .NoDocking, .AlwaysAutoResize}
	if im.Begin("##mh_odin_call_tip", nil, flags) {
		if tip.receiver != "" {
			im.TextColored({0.52, 0.80, 1.00, 1.0}, "%s", fmt.ctprintf("%s.%s(", tip.receiver, tip.callee))
		} else {
			im.TextColored({0.52, 0.80, 1.00, 1.0}, "%s", fmt.ctprintf("%s(", tip.callee))
		}
		for param, pi in tip.params {
			if pi > 0 {
				im.SameLine(0, 0)
				im.TextDisabled(", ")
			}
			im.SameLine(0, 0)
			if pi == tip.active_param {
				im.TextColored({1.00, 0.84, 0.32, 1.0}, "%s", fmt.ctprintf("[%s]", param))
			} else {
				im.TextColored(p.text_primary, "%s", fmt.ctprintf("%s", param))
			}
		}
		im.SameLine(0, 0)
		im.TextColored({0.52, 0.80, 1.00, 1.0}, ")")
		if ret_idx := strings.index(tip.signature, "->"); ret_idx >= 0 {
			im.SameLine(0, 5)
			im.TextColored({0.46, 0.94, 0.62, 1.0}, "%s", fmt.ctprintf("%s", tip.signature[ret_idx:]))
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
_completion_kind_badge :: proc(k: Completion_Kind) -> (badge: string, col: im.Vec4) {
	switch k {
	case .Pin_Ref:   return "^Ref",   {1.00, 0.50, 0.66, 1.0}
	case .Pin_Copy:  return "Copy",   {0.48, 0.84, 1.00, 1.0}
	case .Pin_Out:   return "-> Out", {0.46, 0.94, 0.62, 1.0}
	case .Field:     return "field",  {0.42, 0.88, 0.94, 1.0}
	case .Local_Var: return "local",  {0.92, 0.82, 0.48, 1.0}
	case .Hot_API:   return "hot",    {0.40, 0.96, 0.68, 1.0}
	case .Procedure: return "proc",   {0.52, 0.74, 1.00, 1.0}
	case .Type_Sym:  return "type",   {0.36, 0.84, 0.94, 1.0}
	case .Keyword:   return "kw",     {0.80, 0.56, 0.98, 1.0}
	}
	return "sym", {0.75, 0.78, 0.82, 1.0}
}

@(private = "file")
_draw_autocomplete_popup :: proc(anchor_pos: im.Vec2, items: []Autocomplete_Item, ide: ^_Surface_IDE_State) {
	p  := thm.palette()
	vp := im.GetMainViewport()

	pop_w := f32(430.0)
	row_h := im.GetTextLineHeightWithSpacing()
	pop_h := min(f32(len(items)) * row_h + 30.0, 270.0)

	pos := anchor_pos
	if pos.x + pop_w > vp.Pos.x + vp.Size.x - 12.0 {
		pos.x = max(vp.Pos.x + 12.0, vp.Pos.x + vp.Size.x - pop_w - 12.0)
	}
	if pos.y + pop_h > vp.Pos.y + vp.Size.y - 12.0 {
		pos.y = max(vp.Pos.y + 12.0, anchor_pos.y - pop_h - im.GetTextLineHeight() - 6.0)
	}

	im.SetNextWindowPos(pos, .Always)
	im.SetNextWindowSize({pop_w, pop_h}, .Always)
	im.PushStyleColorImVec4(.WindowBg, p.is_light ? im.Vec4{0.97, 0.98, 1.0, 0.98} : im.Vec4{0.10, 0.12, 0.16, 0.98})
	im.PushStyleColorImVec4(.Border, thm.with_alpha(p.accent, 0.65))
	im.PushStyleVar(.WindowBorderSize, 1.2)
	im.PushStyleVar(.WindowRounding, 6.0)

	// NOTE: Never pass internal `WindowFlag.Tooltip` (bit 25) to `im.Begin()` — Dear ImGui asserts `IM_ASSERT` (`SIGABRT`)!
	im.SetNextWindowBgAlpha(0.98)
	flags: im.WindowFlags = {.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings, .NoFocusOnAppearing, .NoNavInputs, .NoNavFocus, .NoDocking}
	if im.Begin("##mh_odin_ac_popup", nil, flags) {
		for item, idx in items {
			is_sel := idx == ide.ac_selected_idx
			badge, bcol := _completion_kind_badge(item.kind)
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
			im.DrawList_AddText(dl, {row_min.x + 6.0, row_min.y + 1.0}, im.GetColorU32ImVec4(bcol), fmt.ctprintf("%s", badge))
			im.DrawList_AddText(dl, {row_min.x + 68.0, row_min.y + 1.0}, im.GetColorU32ImVec4(p.text_primary), fmt.ctprintf("%s", item.label))
			if item.detail != "" {
				det_c := fmt.ctprintf("%s", item.detail)
				det_w := im.CalcTextSize(det_c).x
				det_x := max(row_min.x + avail_w - det_w - 6.0, row_min.x + 210.0)
				im.DrawList_AddText(dl, {det_x, row_min.y + 1.0}, im.GetColorU32ImVec4(p.text_muted), det_c)
			}
		}
		im.Separator()
		im.TextDisabled("Tab / Enter: Accept   Up/Down: Select   Esc: Dismiss")
	}
	im.End()
	im.PopStyleVar(2)
	im.PopStyleColor(2)
}

// =============================================================================
// Status Pill Helper (Shows Live Async Checker, Caret Ln/Col & Hot-Reload State)
// =============================================================================

@(private = "file")
_draw_checker_and_hot_pills :: proc(snap: Checker_Snapshot) {
	chk_col := im.Vec4{0.55, 0.62, 0.70, 1.0}
	switch snap.stage {
	case .Idle, .Pending_Syntax:
		chk_col = {0.72, 0.78, 0.88, 1.0}
	case .Syntax_OK:
		chk_col = {0.36, 0.88, 0.60, 1.0}
	case .Compiler_OK:
		chk_col = {0.28, 0.94, 0.56, 1.0}
	case .Running_Compiler:
		chk_col = {0.42, 0.78, 1.00, 1.0}
	case .Syntax_Error, .Compiler_Error:
		chk_col = {1.00, 0.38, 0.40, 1.0}
	}
	lbl_txt := snap.summary_label != "" ? snap.summary_label : "Idle (Typecheck ready)"
	im.TextColored(chk_col, "%s", fmt.ctprintf("%s %s", icons.ICON_MD_CHECK, lbl_txt))
	widgets.tooltip("Read-only background syntax/typecheck (`odin check`). Does NOT build .dll/.exe or overwrite hot cartridges.\nFull hot-swap compilation only runs when you click Play / Save+Rebuild / F7.")

	hot_st, hot_gen, hot_ms, hot_msg, _ := engine.hot_cartridge_status()
	if hot_st != .Idle && hot_msg != "" {
		im.SameLine()
		im.TextDisabled("|")
		im.SameLine()
		hcol := im.Vec4{0.42, 0.86, 1.0, 1.0}
		if hot_st == .Swapped_OK do hcol = {0.34, 0.96, 0.62, 1.0}
		else if hot_st == .Compile_Failed do hcol = {1.0, 0.40, 0.40, 1.0}
		else if hot_st == .Schema_Changed do hcol = {1.0, 0.78, 0.28, 1.0}
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
_commit_scoped_popup :: proc(trigger_hot_swap: bool) {
	body_now := _c_buf_string(_scoped.buf[:])
	if _scoped.is_graph_node {
		if _scoped.commit_cb != nil {
			_scoped.commit_cb(_scoped.node_uid, body_now, trigger_hot_swap, _scoped.commit_user_ptr)
		}
		_scoped.dirty = false
		return
	}

	if _scoped.backing_file_abs != "" && _scoped.backing_proc_name != "" {
		if updated_full, ok := splice_odin_procedure_body(_scoped.full_file_cache, _scoped.backing_proc_name, body_now, context.temp_allocator); ok {
			if os.write_entire_file(_scoped.backing_file_abs, transmute([]u8)updated_full) == nil {
				context.allocator = runtime.default_allocator()
				delete(_scoped.full_file_cache)
				_scoped.full_file_cache = strings.clone(updated_full)
				_scoped.dirty = false
				submit_async_check(body_now, true, _scoped.backing_pkg_dir, true)
				submit_async_autocomplete_index(body_now, true, _scoped.backing_pkg_dir)
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

	if _scoped.just_opened {
		im.SetNextWindowSize({840, 560}, .FirstUseEver)
		im.SetNextWindowPos({vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}, .Appearing, {0.5, 0.5})
		_scoped.just_opened = false
	}

	// Apply Smart Enlarge (`92%` of viewport) or Restore back to floating rect!
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
			im.SetNextWindowSize({840, 560}, .Always)
		}
	}

	win_title := fmt.ctprintf("%s Scoped Node Odin Micro-IDE — %s%s###mh_scoped_node_ide", icons.ICON_MD_CODE, _scoped.title, _scoped.dirty ? " *" : "")
	open_flag := _scoped.open
	_scoped.focused = false
	if im.Begin(win_title, &open_flag, {.NoCollapse}) {
		_scoped.focused = im.IsWindowFocused({.RootWindow, .ChildWindows})
		// Track floating rect while NOT enlarged so Restore returns to your exact preferred size & position!
		if !_scoped.enlarged {
			_scoped.saved_pos      = im.GetWindowPos()
			_scoped.saved_size     = im.GetWindowSize()
			_scoped.has_saved_rect = true
		}

		// `F11` toggles Smart Enlarge / Restore!
		if _scoped.focused && im.IsKeyPressed(.F11, false) {
			_toggle_scoped_enlarge()
		}

		snap := read_checker_snapshot(context.temp_allocator)

		// Top Action & Window-Management Bar
		can_apply := snap.stage != .Syntax_Error
		if !can_apply do im.BeginDisabled()
		im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
		if im.Button(fmt.ctprintf("%s Apply & Hot-Swap (F7)", icons.ICON_MD_PLAY_ARROW)) || (_scoped.focused && im.IsKeyPressed(.F7, false)) {
			_commit_scoped_popup(true)
		}
		im.PopStyleColor()
		if !can_apply do im.EndDisabled()
		widgets.tooltip("Save this node's Odin body, transpile the graph, and hot-swap `hot_cartridge_<N>.dll` (~240 ms) without restarting!")

		im.SameLine()
		if im.Button(fmt.ctprintf("%s Save (Ctrl+S)", icons.ICON_MD_SAVE)) || (_scoped.focused && im.GetIO().KeyCtrl && im.IsKeyPressed(.S, false)) {
			_commit_scoped_popup(false)
		}
		widgets.tooltip("Save scoped body changes without triggering a DLL build yet")

		im.SameLine()
		_draw_undo_redo_buttons(&_scoped.undo, _scoped.buf[:], &_scoped.ide, &_scoped.dirty, _scoped.backing_pkg_dir, true, "scoped")

		im.SameLine()
		if im.Button(fmt.ctprintf("%s Find (Ctrl+F)", icons.ICON_MD_SEARCH)) {
			_scoped.ide.find_open       = !_scoped.ide.find_open
			_scoped.ide.find_focus_next = _scoped.ide.find_open
		}
		widgets.tooltip("Toggle inline Find & Replace bar (`Ctrl+F`)")

		im.SameLine()
		_draw_zoom_pill_controls("scoped")

		// Right-aligned Smart Enlarge (`92%` Zen Mode) & Open in Docked Studio buttons!
		enlarge_lbl := _scoped.enlarged \
			? fmt.ctprintf("%s Restore (F11)", icons.ICON_MD_DOCK) \
			: fmt.ctprintf("%s Enlarge (F11)", icons.ICON_MD_OPEN_IN_FULL)
		btn_right_w: f32 = (!_scoped.is_graph_node && _scoped.backing_file_abs != "") ? 248.0 : 124.0
		if avail_x := im.GetContentRegionAvail().x; avail_x > btn_right_w + 16.0 {
			im.SameLine(im.GetCursorPosX() + avail_x - btn_right_w)
		} else {
			im.SameLine()
		}
		im.PushStyleColorImVec4(.Button, _scoped.enlarged ? thm.with_alpha(p.accent, 0.34) : thm.with_alpha(p.accent, 0.16))
		if im.Button(enlarge_lbl) {
			_toggle_scoped_enlarge()
		}
		im.PopStyleColor()
		widgets.tooltip("Smart Enlarge (`F11` or Double-Click Signature Header): Quickly expand this popup to 92% of the screen, or restore back to compact floating size!")

		if !_scoped.is_graph_node && _scoped.backing_file_abs != "" {
			im.SameLine()
			if im.Button(fmt.ctprintf("%s Full Studio", icons.ICON_MD_OPEN_IN_NEW)) {
				open_file_in_studio(_scoped.backing_file_abs)
				wnd.open("odin_micro_studio")
			}
			widgets.tooltip("Open the full `.odin` file in the Dockable Odin Micro-Studio")
		}

		_draw_checker_and_hot_pills(snap)
		im.Separator()

		// Interactive `[ + Using / Spaces ▾ ]` Namespace Chip Bar (Zero-Guess `using` & package discovery!)
		if _scoped.is_graph_node && _scoped.using_toggle_cb != nil && _scoped.using_query_cb != nil {
			if im.SmallButton(fmt.ctprintf("%s + Using / Spaces", icons.ICON_MD_ADD)) {
				im.OpenPopup("##scoped_using_spaces_popup")
			}
			widgets.tooltip("Select Odin `using` scopes and packages (`using self` Blueprint vars, `using math`, `using linalg`, `ease`, `rand`) without guessing imports!")

			for spec in USING_SPACE_CATALOG {
				if !spec.hot_safe do continue
				if _scoped.using_query_cb(spec.id, _scoped.commit_user_ptr) {
					im.SameLine()
					im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.24))
					if im.SmallButton(fmt.ctprintf("%s %s##uchip_%s", icons.ICON_MD_CHECK, spec.label, spec.id)) {
						new_sig := _scoped.using_toggle_cb(spec.id, _scoped.commit_user_ptr)
						if new_sig != "" {
							context.allocator = runtime.default_allocator()
							delete(_scoped.signature_banner)
							_scoped.signature_banner = strings.clone(new_sig)
						}
						s_cur := _c_buf_string(_scoped.buf[:])
						submit_async_check(s_cur, true, _scoped.backing_pkg_dir)
						submit_async_autocomplete_index(s_cur, true, "haati/hot_scripts")
					}
					im.PopStyleColor()
					widgets.tooltip(fmt.ctprintf("%s (Click chip to toggle)", spec.description))
				}
			}

			if im.BeginPopup("##scoped_using_spaces_popup") {
				im.TextColored(p.accent, icons.ICON_MD_CODE + " Blueprint Using & Spaces")
				im.SetNextItemWidth(260)
				im.InputTextWithHint("##sc_using_q", "Search math, linalg, self, ease...", cstring(raw_data(_scoped.using_search_buf[:])), len(_scoped.using_search_buf))
				uq := strings.to_lower(_c_buf_string(_scoped.using_search_buf[:]), context.temp_allocator)
				im.Separator()
				for spec in USING_SPACE_CATALOG {
					if !spec.hot_safe do continue
					if uq != "" && !strings.contains(strings.to_lower(spec.label, context.temp_allocator), uq) && !strings.contains(strings.to_lower(spec.description, context.temp_allocator), uq) {
						continue
					}
					active := _scoped.using_query_cb(spec.id, _scoped.commit_user_ptr)
					if im.MenuItem(fmt.ctprintf("%s %s", active ? icons.ICON_MD_CHECK : " ", spec.label)) {
						new_sig := _scoped.using_toggle_cb(spec.id, _scoped.commit_user_ptr)
						if new_sig != "" {
							context.allocator = runtime.default_allocator()
							delete(_scoped.signature_banner)
							_scoped.signature_banner = strings.clone(new_sig)
						}
						s_cur := _c_buf_string(_scoped.buf[:])
						submit_async_check(s_cur, true, _scoped.backing_pkg_dir)
						submit_async_autocomplete_index(s_cur, true, "haati/hot_scripts")
					}
					widgets.tooltip(fmt.ctprintf("%s", spec.description))
				}
				im.EndPopup()
			}
		}

		// Locked Pin Signature Header (Double-clicking also toggles Smart Enlarge!)
		banner_bg := p.is_light ? thm.lerp_col(p.bg_canvas, p.accent, 0.08) : thm.lerp_col(p.bg_canvas, p.accent, 0.14)
		im.PushStyleColorImVec4(.ChildBg, banner_bg)
		if im.BeginChild("##locked_sig_banner", {0, len(_scoped.pins) > 0 ? 58 : 34}, {.Borders}) {
			if im.IsWindowHovered() && im.IsMouseDoubleClicked(.Left) {
				_toggle_scoped_enlarge()
			}
			im.TextColored(p.text_muted, "LOCKED SIGNATURE:")
			im.SameLine()
			im.TextColored(p.accent, "%s", fmt.ctprintf("%s {", _scoped.signature_banner))

			if len(_scoped.pins) > 0 {
				im.TextDisabled("Pins in Scope:")
				for pin in _scoped.pins {
					im.SameLine()
					if pin.is_output {
						im.TextColored({0.46, 0.94, 0.62, 1.0}, "%s", fmt.ctprintf("-> %s: %s", pin.name, pin.odin_type))
					} else if pin.pass_mode == .By_Reference {
						im.TextColored({1.00, 0.50, 0.66, 1.0}, "%s", fmt.ctprintf("%s %s: ^%s (Ref)", icons.ICON_MD_DIAMOND, pin.name, pin.odin_type))
					} else {
						im.TextColored({0.48, 0.82, 1.00, 1.0}, "%s", fmt.ctprintf("%s %s: %s (Copy)", icons.ICON_MD_CIRCLE, pin.name, pin.odin_type))
					}
				}
			}
		}
		im.EndChild()
		im.PopStyleColor()

		// Quick Snippet Insert Strip
		im.TextDisabled("Quick Insert:")
		snippets := [5]struct{ lbl, code: string }{
			{"pos_ref^",       "if p := hot.pos_ref(api, self); p != nil { p.y += dt }\n"},
			{"bind_action",    "hot.bind_action(api, self, \"Jump\", .Pressed, 0, true, \"On_Jump\")\n"},
			{"damp_vec3",      "hot.damp_vec3(cur, target, 10.0, dt)"},
			{"sin wave",       "math.sin(phase) * amp"},
			{"set_timescale",  "hot.set_object_timescale(api, self, 0.25)\n"},
		}
		for sn, si in snippets {
			im.SameLine()
			if im.SmallButton(fmt.ctprintf("%s##snip_%d", sn.lbl, si)) {
				cur := _c_buf_string(_scoped.buf[:])
				sep := len(cur) > 0 && !strings.has_suffix(cur, "\n") ? "\n" : ""
				_copy_to_c_buf(_scoped.buf[:], strings.concatenate({cur, sep, sn.code}, context.temp_allocator))
				_scoped.dirty = true
				s_after := _c_buf_string(_scoped.buf[:])
				code_undo_record_edit(&_scoped.undo, s_after, len(s_after), im.GetTime(), true)
				submit_async_check(s_after, true, _scoped.backing_pkg_dir)
				submit_async_autocomplete_index(s_after, true, _scoped.backing_pkg_dir != "" ? _scoped.backing_pkg_dir : "haati/hot_scripts")
			}
		}

		// Main Scoped Body Code Surface (with Smart Autocomplete, Zoom, Auto-Indent, Bracket Match)
		err_panel_h: f32 = len(snap.diagnostics) > 0 ? 92.0 : 44.0
		code_h := max(im.GetContentRegionAvail().y - err_panel_h - 6.0, 120.0)
		if _draw_syntax_code_surface("##scoped_node_code", _scoped.buf[:], {0, code_h}, snap.diagnostics, &_scoped.ide, _scoped.pins[:], true, nil, &_scoped.undo, &_scoped.dirty, _scoped.backing_pkg_dir) {
			_scoped.dirty = true
			s_now := _c_buf_string(_scoped.buf[:])
			submit_async_check(s_now, true, _scoped.backing_pkg_dir)
			submit_async_autocomplete_index(s_now, true, _scoped.backing_pkg_dir != "" ? _scoped.backing_pkg_dir : "haati/hot_scripts")
		}

		// Closing brace + Caret Telemetry + Live Diagnostics Footer
		im.TextColored(p.accent, "} // end node body")
		im.SameLine(0, 16)
		_draw_ide_footer_telemetry(&_scoped.ide)

		if len(snap.diagnostics) > 0 {
			for d in snap.diagnostics {
				col := d.is_warning ? im.Vec4{0.98, 0.78, 0.25, 1.0} : im.Vec4{1.0, 0.38, 0.40, 1.0}
				im.TextColored(col, "%s", fmt.ctprintf("  Line %d:%d — %s", d.line, d.column, d.message))
			}
		}
	}
	im.End()
	_scoped.open = open_flag
}

// =============================================================================
// 2. Dockable Full-File Odin Micro-Studio Window (`odin_micro_studio`)
// =============================================================================

@(private = "file")
_refresh_workspace_odin_files :: proc() {
	context.allocator = runtime.default_allocator()
	for f in _studio.discovered_files do delete(f)
	clear(&_studio.discovered_files)

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
			context.allocator = runtime.default_allocator()
			append(&_studio.discovered_files, strings.clone(norm_full))
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
_outline_symbol_visual :: proc(k: Outline_Symbol_Kind) -> (icon: string, col: im.Vec4) {
	switch k {
	case .Hot_Proc: return icons.ICON_MD_BOLT,        {0.40, 0.96, 0.68, 1.0}
	case .Proc:     return icons.ICON_MD_FUNCTIONS,   {0.52, 0.78, 1.00, 1.0}
	case .Struct:   return icons.ICON_MD_DATA_OBJECT, {0.42, 0.88, 0.94, 1.0}
	case .Enum:     return icons.ICON_MD_LIST_ALT,    {0.94, 0.78, 0.42, 1.0}
	}
	return icons.ICON_MD_CODE, {0.78, 0.82, 0.88, 1.0}
}

@(private = "file")
_jump_to_tab_line :: proc(tab: ^_Tab_Doc, target_ln: int) {
	src := _c_buf_string(tab.buf)
	ls  := compute_line_starts(src, context.temp_allocator)
	if len(ls) > 0 {
		clamped := clamp(target_ln, 1, len(ls))
		_studio.ide.cmd_jump_offset = ls[clamped - 1]
		tab.scroll_line             = clamped
	}
}

@(private = "file")
_nav_push_current :: proc() {
	if _studio.active_tab < 0 || _studio.active_tab >= len(_studio.tabs) do return
	act := _studio.tabs[_studio.active_tab]
	cur_ln := max(_studio.ide.caret_line, 1)
	context.allocator = runtime.default_allocator()

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
	for he in engine.hot_proc_entries() {
		if he.name == ident && he.source_file != "" {
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
	io := im.GetIO()

	_studio.window_hovered = im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows)
	_studio.window_focused = im.IsWindowFocused({.RootWindow, .ChildWindows})

	if !_studio.files_scanned {
		_refresh_workspace_odin_files()
		if len(_studio.tabs) == 0 {
			open_file_in_studio("haati/hot_scripts/builtin_hot_scripts.odin")
		}
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

	// -------------------------------------------------------------------------
	// Responsive Non-Clipping Top IDE Toolbar (Fixed 1.0x Chrome — Never Clips!)
	// -------------------------------------------------------------------------
	if !_nav_can_back() do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s##ide_nav_back", icons.ICON_MD_ARROW_LEFT)) {
		_nav_step(-1)
	}
	if !_nav_can_back() do im.EndDisabled()
	widgets.tooltip("Navigate Back (Alt+Left)")

	im.SameLine(0, 2)
	if !_nav_can_forward() do im.BeginDisabled()
	if im.Button(fmt.ctprintf("%s##ide_nav_fwd", icons.ICON_MD_ARROW_RIGHT)) {
		_nav_step(+1)
	}
	if !_nav_can_forward() do im.EndDisabled()
	widgets.tooltip("Navigate Forward (Alt+Right)")

	_toolbar_sameline_if_fits(66.0)
	if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
		act_tb := &_studio.tabs[_studio.active_tab]
		_draw_undo_redo_buttons(&act_tb.undo, act_tb.buf, &_studio.ide, &act_tb.dirty, act_tb.pkg_dir, false, "main")
	} else {
		im.BeginDisabled()
		im.Button(fmt.ctprintf("%s##cs_undo_none", icons.ICON_MD_UNDO))
		im.SameLine(0, 2)
		im.Button(fmt.ctprintf("%s##cs_redo_none", icons.ICON_MD_REDO))
		im.EndDisabled()
	}

	_toolbar_sameline_if_fits(126.0)
	im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.26))
	if im.Button(fmt.ctprintf("%s Hot-Swap (F7)", icons.ICON_MD_BOLT)) || (_studio.window_focused && im.IsKeyPressed(.F7, false)) {
		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			t := &_studio.tabs[_studio.active_tab]
			if t.dirty {
				_ = os.write_entire_file(t.abs_path, transmute([]u8)_c_buf_string(t.buf))
				t.dirty = false
			}
		}
		engine.hot_cartridge_trigger_async_build(true)
	}
	im.PopStyleColor()
	widgets.tooltip("Save active tab and hot-swap all `@(hot_proc)` + transpiled `.bodin` scripts via `hot_cartridge_<N>.dll` without restarting!")

	_toolbar_sameline_if_fits(128.0)
	if im.Button(fmt.ctprintf("%s Save (Ctrl+S)", icons.ICON_MD_SAVE)) || (_studio.window_focused && io.KeyCtrl && im.IsKeyPressed(.S, false)) {
		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			t := &_studio.tabs[_studio.active_tab]
			if os.write_entire_file(t.abs_path, transmute([]u8)_c_buf_string(t.buf)) == nil {
				t.dirty = false
				s_now := _c_buf_string(t.buf)
				submit_async_check(s_now, false, t.pkg_dir, true)
				submit_async_autocomplete_index(s_now, false, t.pkg_dir)
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

	_toolbar_sameline_if_fits(is_bp_script ? 210.0 : 136.0)
	if is_bp_script {
		im.PushStyleColorImVec4(.Button, {0.16, 0.56, 0.44, 0.85})
		im.PushStyleColorImVec4(.Text, {0.96, 1.0, 0.98, 1.0})
		if im.Button(fmt.ctprintf("%s Switch to Blueprint Graph (F12)", icons.ICON_MD_ACCOUNT_TREE)) || (_studio.window_focused && im.IsKeyPressed(.F12, false)) {
			if _studio.switch_to_bp_cb != nil {
				_studio.switch_to_bp_cb(act_path_bp)
			} else {
				wnd.open("mh_visual_script")
			}
		}
		im.PopStyleColor(2)
		widgets.tooltip("Switch back to visual node graph view for this `.bodin` Blueprint (`F12`)")
	} else {
		if im.Button(fmt.ctprintf("%s Unified Graph", icons.ICON_MD_ACCOUNT_TREE)) {
			wnd.open("mh_visual_script")
		}
		widgets.tooltip("Open Unified Graph Studio (Gameplay BP, Anim & Motion Layer, Particle / GPU VFX, Material Shader)")
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

		if im.BeginPopup("##studio_using_spaces_popup") {
			act := &_studio.tabs[_studio.active_tab]
			is_hot_script := strings.contains(act.pkg_dir, "hot_scripts")
			src_cur := _c_buf_string(act.buf)

			im.TextColored(p.accent, icons.ICON_MD_CODE + " Import & Using Spaces")
			im.SetNextItemWidth(300)
			im.InputTextWithHint("##st_using_q", "Search engine, input_manager, math, physics3d...", cstring(raw_data(_studio.using_search_buf[:])), len(_studio.using_search_buf))
			uq := strings.to_lower(_c_buf_string(_studio.using_search_buf[:]), context.temp_allocator)
			im.Separator()

			for spec in USING_SPACE_CATALOG {
				if spec.id == "self" do continue
				if uq != "" && !strings.contains(strings.to_lower(spec.label, context.temp_allocator), uq) && !strings.contains(strings.to_lower(spec.description, context.temp_allocator), uq) {
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
						_copy_to_c_buf(act.buf, new_src)
						act.dirty = true
						s_after := _c_buf_string(act.buf)
						code_undo_record_edit(&act.undo, s_after, _studio.ide.cursor_pos, im.GetTime(), true)
						submit_async_check(s_after, false, act.pkg_dir)
						submit_async_autocomplete_index(s_after, false, act.pkg_dir)
					}
				}
				if blocked_in_hot do im.EndDisabled()
				widgets.tooltip(fmt.ctprintf("%s", spec.description))
			}
			im.EndPopup()
		}
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
		wnd.open("editor_defaults")
	}
	widgets.tooltip("Open Editor Defaults (Configure per-pane zoom defaults, tooltip idle delay, Error Lens & Breadcrumbs)")

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

	// Precompute active tab symbols for Left Structure Outline, Breadcrumbs, and `Ctrl+Shift+O` popup
	has_active_tab := _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)
	active_src     := has_active_tab ? _c_buf_string(_studio.tabs[_studio.active_tab].buf) : ""
	outline_syms   := has_active_tab ? extract_odin_outline_symbols(active_src, context.temp_allocator) : nil
	encl_name, encl_kind, has_encl := enclosing_odin_symbol_at_line(outline_syms, max(_studio.ide.caret_line, 1))

	if open_sym_jump {
		im.OpenPopup("##studio_symbol_jump_popup")
	}
	if im.BeginPopup("##studio_symbol_jump_popup") {
		im.TextColored(p.accent, icons.ICON_MD_FUNCTIONS + " Jump to Symbol in File (Ctrl+Shift+O)")
		if im.IsWindowAppearing() {
			im.SetKeyboardFocusHere()
		}
		im.SetNextItemWidth(320)
		enter_sym := im.InputTextWithHint("##sym_jump_q", "Filter procedures, @(hot_proc), structs...", cstring(raw_data(_studio.sym_jump_buf[:])), len(_studio.sym_jump_buf), {.EnterReturnsTrue})
		sq := strings.to_lower(_c_buf_string(_studio.sym_jump_buf[:]), context.temp_allocator)
		im.Separator()
		first_match_ln := 0
		if im.BeginChild("##sym_jump_list", {340, 240}) {
			for sym, si in outline_syms {
				if sq != "" && !strings.contains(strings.to_lower(sym.name, context.temp_allocator), sq) do continue
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
			im.SetNextItemWidth(-32)
			im.InputTextWithHint("##file_filter", "Filter files...", cstring(raw_data(_studio.search_buf[:])), len(_studio.search_buf))
			im.SameLine()
			if im.Button(fmt.ctprintf("%s##rescan", icons.ICON_MD_REFRESH)) {
				_refresh_workspace_odin_files()
			}
			widgets.tooltip("Rescan workspace `.odin` and `.bodin` files")

			q := strings.to_lower(_c_buf_string(_studio.search_buf[:]), context.temp_allocator)
			if im.BeginChild("##file_list_scroll", {0, 0}, {}, left_flags) {
				shown := 0
				for f in _studio.discovered_files {
					if q != "" && !strings.contains(strings.to_lower(f, context.temp_allocator), q) do continue
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
	im.SameLine(0, 2)
	im.InvisibleButton("##studio_vsplit", {5.0, max(avail.y, 16.0)})
	if im.IsItemHovered() || im.IsItemActive() {
		im.SetMouseCursor(.ResizeEW)
		s_min := im.GetItemRectMin()
		s_max := im.GetItemRectMax()
		im.DrawList_AddRectFilled(im.GetWindowDrawList(), s_min, s_max, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.55)), 2.0)
	}
	if im.IsItemActive() && io.MouseDelta.x != 0 {
		_studio.left_width = clamp(_studio.left_width + io.MouseDelta.x, 175.0, 560.0)
	}

	im.SameLine(0, 2)
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
						_clear_ide_pending_restore(&_studio.ide)
						s_tab := _c_buf_string(tab.buf)
						submit_async_check(s_tab, false, tab.pkg_dir)
						submit_async_autocomplete_index(s_tab, false, tab.pkg_dir)
					}
					im.EndTabItem()
				}
				if !tab_open do remove_idx = ti
			}
			im.EndTabBar()

			if remove_idx >= 0 {
				context.allocator = runtime.default_allocator()
				old := _studio.tabs[remove_idx]
				delete(old.title)
				delete(old.abs_path)
				delete(old.pkg_dir)
				delete(old.buf)
				code_undo_free(&old.undo)
				_clear_ide_pending_restore(&_studio.ide)
				ordered_remove(&_studio.tabs, remove_idx)
				if _studio.active_tab >= len(_studio.tabs) {
					_studio.active_tab = max(len(_studio.tabs) - 1, 0)
				}
				_studio.request_tab_select = _studio.active_tab
			}
		}

		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			act := &_studio.tabs[_studio.active_tab]

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
			} else {
				_draw_ide_footer_telemetry(&_studio.ide)
			}

			// SEGMENT 2: Center Code Surface (`_studio.code_zoom`)
			prob_h := clamp(_studio.problems_height, 44.0, max(im.GetContentRegionAvail().y * 0.45, 56.0))
			ed_h   := max(im.GetContentRegionAvail().y - prob_h - 10.0, 120.0)
			if _draw_syntax_code_surface("##main_studio_code", act.buf, {0, ed_h}, snap.diagnostics, &_studio.ide, nil, false, &act.scroll_line, &act.undo, &act.dirty, act.pkg_dir) {
				act.dirty = true
				s_now := _c_buf_string(act.buf)
				submit_async_check(s_now, false, act.pkg_dir)
				submit_async_autocomplete_index(s_now, false, act.pkg_dir)
			}
			if _studio.ide.req_jump_ident != "" {
				_jump_to_definition_by_ident(act, _studio.ide.req_jump_ident, outline_syms)
			}

			// Horizontal Splitter between Code Surface & Problems Dock
			im.InvisibleButton("##studio_hsplit", {max(im.GetContentRegionAvail().x, 16.0), 5.0})
			if im.IsItemHovered() || im.IsItemActive() {
				im.SetMouseCursor(.ResizeNS)
				s_min := im.GetItemRectMin()
				s_max := im.GetItemRectMax()
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), s_min, s_max, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.55)), 2.0)
			}
			if im.IsItemActive() && io.MouseDelta.y != 0 {
				_studio.problems_height = clamp(_studio.problems_height - io.MouseDelta.y, 44.0, 360.0)
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
					if len(snap.diagnostics) == 0 && hot_stderr == "" {
						im.TextColored({0.36, 0.90, 0.58, 1.0}, icons.ICON_MD_CHECK + " 0 Compiler Problems — Syntax & Types Clean")
					} else {
						for d, di in snap.diagnostics {
							col := d.is_warning ? im.Vec4{0.98, 0.78, 0.25, 1.0} : im.Vec4{1.0, 0.38, 0.40, 1.0}
							im.PushStyleColorImVec4(.Text, col)
							if im.Selectable(fmt.ctprintf("%s:%d:%d — %s##diag_%d", filepath.base(d.file), d.line, d.column, d.message, di), false) {
								if d.file != "" && os.exists(d.file) && d.file != act.abs_path {
									open_file_in_studio(d.file, d.line)
								} else {
									_jump_to_tab_line(act, d.line)
								}
							}
							im.PopStyleColor()
							widgets.tooltip("Click to jump directly to this diagnostic line")
						}
						if hot_stderr != "" {
							im.TextColored({1.0, 0.42, 0.42, 1.0}, "%s", fmt.ctprintf("Hot Cartridge Build Output: %s", hot_stderr))
						}
					}
				}
				im.EndChild()
			}
		} else {
			im.TextDisabled("Select a `.odin` or `.bodin` file on the left to start editing.")
		}
	}
	im.EndChild()
	_ = c.int(0)
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
) -> (
	updated_body:     string,
	body_edited:      bool,
	trigger_hotswap:  bool,
) {
	_ensure_zoom_init()
	p := thm.palette()

	need_reload := _emb_scoped.node_uid != target_key || !_emb_scoped.open
	if need_reload {
		context.allocator = runtime.default_allocator()
		_clear_scoped_state(&_emb_scoped)
		_emb_scoped.open             = true
		_emb_scoped.is_graph_node    = true
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
		_copy_to_c_buf(_emb_scoped.buf[:], current_body)
		s_now := _c_buf_string(_emb_scoped.buf[:])
		code_undo_reset(&_emb_scoped.undo, s_now, 0)
		submit_async_check(s_now, true, "")
		submit_async_autocomplete_index(s_now, true, "haati/hot_scripts")
	} else if _emb_scoped.signature_banner != signature_banner {
		context.allocator = runtime.default_allocator()
		if _emb_scoped.signature_banner != "" do delete(_emb_scoped.signature_banner)
		_emb_scoped.signature_banner = strings.clone(signature_banner)
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
		widgets.tooltip("Save Odin body, transpile `.bodin`, and Hot-Swap `hot_cartridge` (~240 ms)!")

		im.SameLine()
		_draw_undo_redo_buttons(&_emb_scoped.undo, _emb_scoped.buf[:], &_emb_scoped.ide, &_emb_scoped.dirty, "haati/hot_scripts", true, "emb_sc")

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

		// Locked Signature Header
		banner_bg := p.is_light ? thm.lerp_col(p.bg_canvas, p.accent, 0.08) : thm.lerp_col(p.bg_canvas, p.accent, 0.14)
		im.PushStyleColorImVec4(.ChildBg, banner_bg)
		if im.BeginChild("##emb_sig_banner", {0, len(_emb_scoped.pins) > 0 ? 54 : 32}, {.Borders}) {
			im.TextColored(p.accent, "%s", fmt.ctprintf("%s {", _emb_scoped.signature_banner))
			if len(_emb_scoped.pins) > 0 {
				im.TextDisabled("Pins:")
				for pin in _emb_scoped.pins {
					im.SameLine()
					if pin.is_output {
						im.TextColored({0.46, 0.94, 0.62, 1.0}, "%s", fmt.ctprintf("-> %s: %s", pin.name, pin.odin_type))
					} else if pin.pass_mode == .By_Reference {
						im.TextColored({1.00, 0.50, 0.66, 1.0}, "%s", fmt.ctprintf("%s %s: ^%s", icons.ICON_MD_DIAMOND, pin.name, pin.odin_type))
					} else {
						im.TextColored({0.48, 0.82, 1.00, 1.0}, "%s", fmt.ctprintf("%s %s: %s", icons.ICON_MD_CIRCLE, pin.name, pin.odin_type))
					}
				}
			}
		}
		im.EndChild()
		im.PopStyleColor()

		err_h: f32 = len(snap.diagnostics) > 0 ? 78.0 : 28.0
		code_h := max(im.GetContentRegionAvail().y - err_h - 6.0, 96.0)
		if _draw_syntax_code_surface("##emb_scoped_code_surf", _emb_scoped.buf[:], {0, code_h}, snap.diagnostics, &_emb_scoped.ide, _emb_scoped.pins[:], true, nil, &_emb_scoped.undo, &_emb_scoped.dirty, "haati/hot_scripts") {
			body_edited = true
			s_now := _c_buf_string(_emb_scoped.buf[:])
			submit_async_check(s_now, true, "")
			submit_async_autocomplete_index(s_now, true, "haati/hot_scripts")
		}
		im.TextColored(p.accent, "}")
		im.SameLine(0, 12)
		_draw_ide_footer_telemetry(&_emb_scoped.ide)
		if len(snap.diagnostics) > 0 {
			for d in snap.diagnostics {
				col := d.is_warning ? im.Vec4{0.98, 0.78, 0.25, 1.0} : im.Vec4{1.0, 0.38, 0.40, 1.0}
				im.TextColored(col, "%s", fmt.ctprintf("  Line %d:%d — %s", d.line, d.column, d.message))
			}
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

// Forces an already-open tab for `abs_or_rel_path` to reload cleanly from disk (used after Blueprint bake!).
reload_file_tab_from_disk :: proc(abs_or_rel_path: string) {
	norm_abs := _canonical_studio_path(abs_or_rel_path, context.temp_allocator)
	for &t in _studio.tabs {
		if t.abs_path == norm_abs {
			if raw, err := os.read_entire_file(norm_abs, context.temp_allocator); err == nil {
				_copy_to_c_buf(t.buf, string(raw))
				t.dirty = false
				s := _c_buf_string(t.buf)
				if t.undo.initialized {
					code_undo_record_edit(&t.undo, s, 0, im.GetTime(), true)
				} else {
					code_undo_reset(&t.undo, s, 0)
				}
				submit_async_check(s, false, t.pkg_dir)
				submit_async_autocomplete_index(s, false, t.pkg_dir)
			}
			return
		}
	}
}

draw_embedded_script_panel :: proc(abs_or_rel_path: string, size: im.Vec2 = {0, 0}) -> (req_save: bool, req_hotswap: bool) {
	_ensure_zoom_init()
	p  := thm.palette()
	io := im.GetIO()

	if abs_or_rel_path != "" {
		has_act := _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs)
		norm_abs := _canonical_studio_path(abs_or_rel_path, context.temp_allocator)
		if !has_act || _studio.tabs[_studio.active_tab].abs_path != norm_abs {
			_ = open_file_in_studio(norm_abs)
		}
	}

	snap := read_checker_snapshot(context.temp_allocator)
	_studio.emb_full_focused = false
	if im.BeginChild("##emb_full_script_host", size, {.Borders}) {
		_studio.emb_full_focused = im.IsWindowFocused({.ChildWindows})
		if im.Button(fmt.ctprintf("%s Save File (Ctrl+S)", icons.ICON_MD_SAVE)) || (_studio.emb_full_focused && io.KeyCtrl && im.IsKeyPressed(.S, false)) {
			if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
				t := &_studio.tabs[_studio.active_tab]
				if os.write_entire_file(t.abs_path, transmute([]u8)_c_buf_string(t.buf)) == nil {
					t.dirty = false
					req_save = true
					s_now := _c_buf_string(t.buf)
					submit_async_check(s_now, false, t.pkg_dir, true)
					submit_async_autocomplete_index(s_now, false, t.pkg_dir)
				}
			}
		}
		im.SameLine()
		im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
		if im.Button(fmt.ctprintf("%s Save & Hot-Swap (F7)", icons.ICON_MD_BOLT)) || (_studio.emb_full_focused && im.IsKeyPressed(.F7, false)) {
			if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
				t := &_studio.tabs[_studio.active_tab]
				_ = os.write_entire_file(t.abs_path, transmute([]u8)_c_buf_string(t.buf))
				t.dirty = false
			}
			req_save = true
			req_hotswap = true
		}
		im.PopStyleColor()

		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			act_emb := &_studio.tabs[_studio.active_tab]
			im.SameLine()
			_draw_undo_redo_buttons(&act_emb.undo, act_emb.buf, &_studio.ide, &act_emb.dirty, act_emb.pkg_dir, false, "emb_full")
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

		if _studio.active_tab >= 0 && _studio.active_tab < len(_studio.tabs) {
			act := &_studio.tabs[_studio.active_tab]
			outline_syms := extract_odin_outline_symbols(_c_buf_string(act.buf), context.temp_allocator)
			// Compact Symbol Jump strip
			im.TextColored(p.text_muted, "%s", fmt.ctprintf("%s%s:", act.title, act.dirty ? " *" : ""))
			im.SameLine()
			im.TextDisabled("Ln %d, Col %d", max(_studio.ide.caret_line, 1), max(_studio.ide.caret_col, 1))
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

			err_h: f32 = len(snap.diagnostics) > 0 ? 78.0 : 28.0
			ed_h := max(im.GetContentRegionAvail().y - err_h - 6.0, 120.0)
			if _draw_syntax_code_surface("##emb_full_code_surf", act.buf, {0, ed_h}, snap.diagnostics, &_studio.ide, nil, false, &act.scroll_line, &act.undo, &act.dirty, act.pkg_dir) {
				act.dirty = true
				s_now := _c_buf_string(act.buf)
				submit_async_check(s_now, false, act.pkg_dir)
				submit_async_autocomplete_index(s_now, false, act.pkg_dir)
			}
			if _studio.ide.req_jump_ident != "" {
				_jump_to_definition_by_ident(act, _studio.ide.req_jump_ident, outline_syms)
			}
			if len(snap.diagnostics) == 0 {
				im.TextColored({0.36, 0.90, 0.58, 1.0}, icons.ICON_MD_CHECK + " 0 Compiler Problems")
			} else {
				for d in snap.diagnostics {
					col := d.is_warning ? im.Vec4{0.98, 0.78, 0.25, 1.0} : im.Vec4{1.0, 0.38, 0.40, 1.0}
					im.TextColored(col, "%s", fmt.ctprintf("Line %d:%d — %s", d.line, d.column, d.message))
				}
			}
		} else {
			im.TextDisabled("Bake or save this `.bodin` script to open its full Odin source here.")
		}
	}
	im.EndChild()
	return req_save, req_hotswap
}
