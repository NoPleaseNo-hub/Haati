package window

// Pop-out windows: editor panels as separate OS windows (imgui multi-viewport,
// enabled in editor/main.odin). A floating panel dragged outside the main
// window already becomes its own OS window and merges back when dragged over
// it again. This file adds the EXPLICIT version behind the floating title-bar
// button and the Play "New Window" mode:
//
//   pop_out  — the panel keeps its own OS window even while it overlaps the
//              main one (imgui's NoAutoMerge viewport flag, set through a
//              WindowClass every frame before Begin). Undocks it first.
//   reunite  — back into the main window: the dock slot it last sat in, else
//              the central dock node, else floating over the main window.
//
// A panel opts in by opening with `begin` instead of im.Begin (it still ends
// with im.End) and calling decorate_floating_window right after, which records
// where the panel is each frame and draws the button.

import "core:strings"
import im "moonhug:external/odin-imgui"

@(private = "file")
_Pop :: struct {
	popped:       bool,    // keep its own OS window (NoAutoMerge)
	request_out:  bool,    // pop_out asked; applied before the next Begin
	request_back: bool,    // reunite asked; applied before the next Begin
	// Last frame, from track (decorate_floating_window):
	docked:       bool,
	dock_id:      im.ID,   // last dock node while docked (reunite target)
	own_viewport: bool,    // sat in an OS window other than the main one
	pos:          im.Vec2,
	size:         im.Vec2,
}

// Keyed by the window's imgui id part (after "###"), so a title that changes
// (a dirty-scene star, a renamed tab) keeps its state.
@(private = "file")
_pops: map[string]_Pop

@(private = "file")
_key :: proc(title: cstring) -> string {
	s := string(title)
	if idx := strings.last_index(s, "###"); idx >= 0 do return s[idx + 3:]
	return s
}

@(private = "file")
_get :: proc(title: cstring) -> ^_Pop {
	k := _key(title)
	if p, ok := &_pops[k]; ok do return p
	if _pops == nil do _pops = make(map[string]_Pop)
	_pops[strings.clone(k)] = {}
	return &_pops[k]
}

// True when imgui can create OS windows (the editor turns this on at init).
viewports_enabled :: proc() -> bool {
	return .ViewportsEnable in im.GetIO().ConfigFlags
}

// Ask for the window to move into its own OS window, applied at its next
// Begin. Works on docked windows too (they are undocked in place).
pop_out :: proc(title: cstring) {
	p := _get(title)
	p.request_out = true
	p.request_back = false
}

// Ask for the window to come back into the main window (see file comment).
reunite :: proc(title: cstring) {
	p := _get(title)
	p.request_back = true
	p.request_out = false
}

// The window is (or is about to be) in its own OS window by explicit pop-out.
is_popped :: proc(title: cstring) -> bool {
	p := _get(title)
	return (p.popped || p.request_out) && !p.request_back
}

// The window sat in an OS window other than the main one last frame — by
// pop_out or by being dragged outside the main window.
in_own_os_window :: proc(title: cstring) -> bool {
	return _get(title).own_viewport
}

// Popped window ids for editor_settings, so a restart keeps them out.
popped_ids :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(_pops), allocator)
	for k, p in _pops {
		if p.popped do append(&out, k)
	}
	return out[:]
}

set_popped_ids :: proc(ids: []string) {
	if _pops == nil do _pops = make(map[string]_Pop)
	for id in ids {
		if p, ok := &_pops[id]; ok {
			p.popped = true
		} else {
			_pops[strings.clone(id)] = _Pop{popped = true}
		}
	}
}

// True if any panel is currently popped out or sitting in a secondary OS window.
any_popped_or_outside :: proc() -> bool {
	for _, p in _pops {
		if p.popped || p.own_viewport || p.request_out do return true
	}
	return false
}

// im.Begin for a pop-out capable window: applies pending pop-out / reunite
// requests and the NoAutoMerge class, then begins. End with im.End as usual.
begin :: proc(title: cstring, p_open: ^bool = nil, flags: im.WindowFlags = {}) -> bool {
	p := _get(title)

	if p.request_back {
		p.request_back = false
		p.popped = false
		target := p.dock_id
		if target != 0 && im.DockBuilderGetNode(target) == nil do target = 0
		if target == 0 do target = _get_central_dock_target()
		if target != 0 {
			im.DockBuilderDockWindow(title, target)
			if main_dockspace_id != 0 do im.DockBuilderFinish(main_dockspace_id)
		} else {
			main := im.GetMainViewport()
			im.SetNextWindowViewport(main.ID_)
			im.SetNextWindowPos(main.WorkPos + main.WorkSize * 0.5, .Always, {0.5, 0.5})
		}
	}

	if p.request_out {
		p.request_out = false
		p.popped = true
		// Always detach from any dock node (even if the window was an inactive
		// background tab last frame so _track_current had not run).
		im.DockBuilderDockWindow(title, 0)
		main := im.GetMainViewport()
		if p.size.x > 64 && p.size.y > 64 {
			im.SetNextWindowSize(p.size, .Always)
			im.SetNextWindowPos(p.pos + {24, 24}, .Always)
		} else {
			im.SetNextWindowSize({960, 600}, .Always)
			im.SetNextWindowPos(main.WorkPos + {64, 64}, .Always)
		}
	}

	actual_flags := flags
	if p.popped {
		// Popped-out OS windows reunite via their title-bar Return button, not
		// by scanning dock-split targets on every mouse-move over the main window.
		wc := im.WindowClass{
			ParentViewportId         = 0,
			DockingAllowUnclassed    = false,
			ViewportFlagsOverrideSet = {.NoAutoMerge},
		}
		im.SetNextWindowClass(&wc)
		actual_flags += {.NoDocking}
	} else if !p.docked && (p.own_viewport || im.IsMouseDown(.Left)) {
		// Keep a dragged/floating panel's secondary OS window & swapchain alive
		// even while passing back over the main window (preventing mid-drag
		// SDL_DestroyWindow + Win32 SetCapture drop), while still allowing
		// full DockSpace drop-target docking via DockingAllowUnclassed = true.
		wc := im.WindowClass{
			ParentViewportId         = 0,
			DockingAllowUnclassed    = true,
			ViewportFlagsOverrideSet = {.NoAutoMerge},
		}
		im.SetNextWindowClass(&wc)
	}

	// A borderless OS window shows rounded imgui corners as black notches.
	square := p.own_viewport && !p.docked
	if square do im.PushStyleVar(.WindowRounding, 0)
	open := im.Begin(title, p_open, actual_flags)
	if square do im.PopStyleVar()

	// Always record dock state inside Begin (even when `open == false` for
	// inactive tabs) so `p.docked`, `p.dock_id`, `p.pos`, and `p.size` stay
	// accurate when `pop_out` is triggered while the tab is hidden.
	p.docked = im.IsWindowDocked()
	if p.docked do p.dock_id = im.GetWindowDockID()
	vp := im.GetWindowViewport()
	p.own_viewport = vp != nil && vp.ID_ != im.GetMainViewport().ID_
	if open {
		p.pos = im.GetWindowPos()
		p.size = im.GetWindowSize()
	}
	if p.popped && p.docked && !p.own_viewport do p.popped = false

	return open
}

// Record where the current window is (called right after Begin by
// decorate_floating_window, docked or not).
@(private)
_track_current :: proc(title: cstring) {
	p := _get(title)
	p.docked = im.IsWindowDocked()
	if p.docked do p.dock_id = im.GetWindowDockID()
	p.pos = im.GetWindowPos()
	p.size = im.GetWindowSize()
	vp := im.GetWindowViewport()
	p.own_viewport = vp != nil && vp.ID_ != im.GetMainViewport().ID_
	// Docked by dragging into the main window: it is reunited.
	if p.popped && p.docked && !p.own_viewport do p.popped = false
}
