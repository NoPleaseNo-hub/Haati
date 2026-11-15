package widgets

// Unified search filtering and search bar controls used across panels and popups.

import "core:fmt"
import "core:strings"
import im "haati:external/odin-imgui"
import icons "haati:editor/icons"
import engine "../../engine"

Search_Bar_Mode :: enum {
	Toolbar,
	Popup,
}

Search_Bar_Opts :: struct {
	id:            cstring,
	hint:          cstring,
	mode:          Search_Bar_Mode,
	width:         f32, // <= 0 fills available width including trailing clear slot
	clear_tooltip: cstring,
	auto_focus:    bool,
	enter_returns: bool,
}

Search_Bar_Result :: struct {
	query:        string,
	changed:      bool,
	cleared:      bool,
	submitted:    bool,
	escape_close: bool,
	active:       bool,
}

@(private = "file")
_active_search_id: im.ID

// The query's words, lowercased. Temp-allocated. Empty for an empty query,
// which matches everything.
search_terms :: proc(query: string) -> []string {
	q := strings.trim_space(query)
	if len(q) == 0 do return nil
	return strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
}

// Case-insensitive, delimiter-smart match routed through engine.Prepared_Search_Query.
search_match :: proc(text: string, terms: []string) -> bool {
	if len(terms) == 0 do return true
	pq: engine.Prepared_Search_Query
	for t in terms {
		if len(t) == 0 do continue
		if pq.term_count >= engine.MAX_SEARCH_TERMS do break
		idx := pq.term_count
		lo, norm := engine.normalize_search_key(t, context.temp_allocator)
		pq.terms[idx] = lo
		pq.term_norms[idx] = norm
		pq.term_count += 1
	}
	if pq.term_count == 0 do return true
	if pq.term_count == 1 {
		pq.raw_lower = pq.terms[0]
		pq.norm = pq.term_norms[0]
	} else {
		joined := strings.join(pq.terms[:pq.term_count], " ", context.temp_allocator)
		pq.raw_lower, pq.norm = engine.normalize_search_key(joined, context.temp_allocator)
	}
	return engine.search_match_fields(&pq, text)
}

// Unified search bar with reserved zero-jitter clear slot and mode-specific Escape handling.
search_bar :: proc(buf: []u8, opts := Search_Bar_Opts{}) -> (res: Search_Bar_Result) {
	if len(buf) == 0 do return {}

	id := opts.id
	if id == nil || len(string(id)) == 0 do id = "##search"
	hint := opts.hint
	if hint == nil || len(string(hint)) == 0 do hint = "Search..."
	clear_tip := opts.clear_tooltip
	if clear_tip == nil || len(string(clear_tip)) == 0 do clear_tip = "Clear search"

	im.PushID(id)
	defer im.PopID()

	q_id := im.GetID("##query")
	was_active := _active_search_id == q_id
	had_text_before := buf[0] != 0

	spacing := im.GetStyle().ItemSpacing.x
	clear_sz := im.GetFrameHeight()
	reserve_w := clear_sz + spacing

	if opts.width <= 0 {
		avail := im.GetContentRegionAvail().x
		im.SetNextItemWidth(max(f32(60.0), avail - reserve_w))
	} else {
		im.SetNextItemWidth(max(f32(40.0), opts.width - reserve_w))
	}

	if opts.mode == .Popup && (opts.auto_focus || im.IsWindowAppearing()) {
		im.SetKeyboardFocusHere(0)
	}

	flags: im.InputTextFlags = {}
	if opts.enter_returns do flags += {.EnterReturnsTrue}

	full_hint := fmt.ctprintf("%s %s", icons.ICON_MD_SEARCH, hint)
	submitted := im.InputTextWithHint("##query", full_hint, cstring(raw_data(buf)), uint(len(buf)), flags)
	edited := im.IsItemEdited()
	now_active := im.IsItemActive()
	deactivated := im.IsItemDeactivated()

	if now_active {
		_active_search_id = q_id
	} else if _active_search_id == q_id {
		_active_search_id = 0
	}

	if opts.enter_returns && submitted {
		res.submitted = true
	} else if submitted || edited {
		res.changed = true
	}

	esc := im.IsKeyPressed(.Escape, false)
	if esc {
		switch opts.mode {
		case .Toolbar:
			if was_active || now_active || deactivated {
				if had_text_before || buf[0] != 0 {
					buf[0] = 0
					res.changed = true
					res.cleared = true
				}
				im.ClearActiveID()
				_active_search_id = 0
			}
		case .Popup:
			if was_active || now_active || deactivated || im.IsItemFocused() || im.IsWindowFocused() {
				if had_text_before || buf[0] != 0 {
					buf[0] = 0
					res.changed = true
					res.cleared = true
					im.SetKeyboardFocusHere(-1)
				} else {
					res.escape_close = true
				}
			}
		}
	}

	has_text := buf[0] != 0
	im.SameLine(0, spacing)
	if has_text {
		if ghost_icon_button(icons.ICON_MD_CLOSE, "##clear", clear_tip, size = clear_sz) {
			buf[0] = 0
			res.changed = true
			res.cleared = true
			if opts.mode == .Popup {
				im.SetKeyboardFocusHere(-1)
			}
		}
	} else {
		im.Dummy({clear_sz, clear_sz})
	}

	res.active = now_active
	res.query = engine.buf_str(buf)
	return res
}

// Draws a themed filter/search input with leading search icon hint and inline clear 'X' button.
search_input :: proc(
	id: cstring,
	buf: []u8,
	hint: cstring = "Search...",
	width: f32 = -1,
	clear_tooltip: cstring = "Clear search",
) -> bool {
	res := search_bar(buf, Search_Bar_Opts{
		id            = id,
		hint          = hint,
		mode          = .Toolbar,
		width         = width,
		clear_tooltip = clear_tooltip,
	})
	return res.changed || res.cleared
}

// Handles Up/Down/PageUp/PageDown/Enter keyboard navigation for search result lists.
search_list_nav :: proc(count: int, sel_idx: ^int, page_size := 10) -> (activated: bool) {
	if sel_idx == nil || count <= 0 {
		if sel_idx != nil do sel_idx^ = -1
		return false
	}
	if sel_idx^ < 0 || sel_idx^ >= count {
		sel_idx^ = 0
	}

	if im.IsKeyPressed(.DownArrow) {
		sel_idx^ = (sel_idx^ + 1) % count
	} else if im.IsKeyPressed(.UpArrow) {
		sel_idx^ = (sel_idx^ - 1 + count) % count
	} else if im.IsKeyPressed(.PageDown) {
		sel_idx^ = min(sel_idx^ + max(page_size, 1), count - 1)
	} else if im.IsKeyPressed(.PageUp) {
		sel_idx^ = max(sel_idx^ - max(page_size, 1), 0)
	}

	if im.IsKeyPressed(.Enter, false) || im.IsKeyPressed(.KeypadEnter, false) {
		return sel_idx^ >= 0 && sel_idx^ < count
	}
	return false
}
