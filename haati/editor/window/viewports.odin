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

import "base:runtime"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import im "haati:external/odin-imgui"

@(private = "file")
_Max_State :: struct {
	maximized:     bool,
	settle_frames: int,
	target_pos:    im.Vec2,
	target_size:   im.Vec2,
	restore_pos:   im.Vec2,
	restore_size:  im.Vec2,
}

@(private = "file")
_max_states: map[string]_Max_State

@(private = "file")
_frame_floating_dock_ids: [dynamic]im.ID

@(private = "file")
_Pending_Dock_Node_Op :: struct {
	node_id:     im.ID,
	pos:         im.Vec2,
	size:        im.Vec2,
	frames_left: int,
}

@(private = "file")
_pending_dock_ops: [dynamic]_Pending_Dock_Node_Op

resolve_leaf_dock_node :: proc(id: im.ID) -> im.ID {
	if id == 0 do return 0
	node := im.DockBuilderGetNode(id)
	if node == nil do return 0
	for node.ChildNodes[0] != nil {
		node = node.ChildNodes[0]
	}
	return node.ID_
}

apply_pending_dock_ops :: proc() {
	write_idx := 0
	for i := 0; i < len(_pending_dock_ops); i += 1 {
		op := _pending_dock_ops[i]
		node := im.DockBuilderGetNode(op.node_id)
		if node != nil {
			im.DockBuilderSetNodePos(op.node_id, op.pos)
			im.DockBuilderSetNodeSize(op.node_id, op.size)
			if node.HostWindow != nil {
				im.SetWindowPosStr(node.HostWindow.Name, op.pos, .Always)
				im.SetWindowSizeStr(node.HostWindow.Name, op.size, .Always)
			}
		}
		if _max_states != nil {
			dk := fmt.tprintf("__docknode_%d", op.node_id)
			if m, ok := &_max_states[dk]; ok && m.settle_frames > 0 {
				m.settle_frames -= 1
			}
		}
		op.frames_left -= 1
		if op.frames_left > 0 && node != nil {
			_pending_dock_ops[write_idx] = op
			write_idx += 1
		}
	}
	if _pending_dock_ops != nil {
		resize(&_pending_dock_ops, write_idx)
	}

	// Detect titlebar drag-out of maximized floating DockNode OS windows and restore `m.restore_size`.
	g := im.GetCurrentContext()
	if _max_states != nil && len(_frame_floating_dock_ids) > 0 && g != nil && g.MovingWindow != nil && g.MovingWindow.RootWindow != nil {
		io := im.GetIO()
		for dock_id in _frame_floating_dock_ids {
			node := im.DockBuilderGetNode(dock_id)
			if node == nil do continue
			root := node
			for root.ParentNode != nil do root = root.ParentNode
			if root.HostWindow == nil do continue
			if g.MovingWindow != root.HostWindow && g.MovingWindow.RootWindow != root.HostWindow do continue
			dk := fmt.tprintf("__docknode_%d", root.ID_)
			if m, ok := &_max_states[dk]; ok && m.maximized && m.settle_frames == 0 {
				rsz := m.restore_size
				if rsz.x < 160 || rsz.y < 100 {
					rsz = {max(min(root.Size.x * 0.72, 980), 320), max(min(root.Size.y * 0.72, 640), 240)}
				}
				ratio := clamp((io.MousePos.x - root.Pos.x) / max(root.Size.x, 1.0), 0.15, 0.85)
				m.maximized     = false
				m.target_pos    = {io.MousePos.x - ratio * rsz.x, io.MousePos.y - 14.0}
				m.target_size   = rsz
				m.settle_frames = 2
				_ = _queue_pending_dock_op(root.ID_, m.target_pos, m.target_size)
			}
		}
	}

	// Idle Anti-Narnia rescue for joined floating DockNode OS windows.
	if len(_frame_floating_dock_ids) > 0 && g != nil && g.MovingWindow == nil && !im.IsMouseDown(.Left) {
		mons := _collect_platform_monitors(context.temp_allocator)
		mvp := im.GetMainViewport()
		fb_pos  := mvp != nil ? mvp.WorkPos  : im.Vec2{0, 0}
		fb_size := mvp != nil ? mvp.WorkSize : im.Vec2{1280, 720}
		for dock_id in _frame_floating_dock_ids {
			node := im.DockBuilderGetNode(dock_id)
			if node == nil do continue
			root := node
			for root.ParentNode != nil do root = root.ParentNode
			if root.HostWindow == nil || root.Size.x <= 64 || root.Size.y <= 32 do continue
			if _max_states != nil {
				dk := fmt.tprintf("__docknode_%d", root.ID_)
				if m, ok := &_max_states[dk]; ok && m.settle_frames > 0 {
					continue
				}
			}
			cpos, _ := clamp_floating_rect_to_monitors(root.Pos, root.Size, mons, fb_pos, fb_size)
			if abs(cpos.x - root.Pos.x) > 1.0 || abs(cpos.y - root.Pos.y) > 1.0 {
				im.DockBuilderSetNodePos(root.ID_, cpos)
				im.SetWindowPosStr(root.HostWindow.Name, cpos, .Always)
			}
		}
	}
}

@(private)
viewports_shutdown :: proc() {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	if _pops != nil {
		for k in _pops do delete(k)
		delete(_pops)
		_pops = nil
	}
	if _max_states != nil {
		for k in _max_states do delete(k)
		delete(_max_states)
		_max_states = nil
	}
	if _frame_floating_dock_ids != nil {
		delete(_frame_floating_dock_ids)
		_frame_floating_dock_ids = nil
	}
	if _pending_dock_ops != nil {
		delete(_pending_dock_ops)
		_pending_dock_ops = nil
	}
}

@(private = "file")
_record_floating_dock_id :: proc(dock_id: im.ID) {
	if dock_id == 0 do return
	for existing in _frame_floating_dock_ids {
		if existing == dock_id do return
	}
	if _frame_floating_dock_ids == nil {
		_frame_floating_dock_ids = make([dynamic]im.ID, 0, 8, runtime.default_allocator())
	}
	append(&_frame_floating_dock_ids, dock_id)
}

// Returns and clears the deduplicated list of floating DockNode IDs active this frame
// so `dock_tab_menu.odin` can draw right-side action buttons on joined floating windows!
consume_floating_dock_ids :: proc(allocator := context.temp_allocator) -> []im.ID {
	if len(_frame_floating_dock_ids) == 0 do return nil
	out := make([]im.ID, len(_frame_floating_dock_ids), allocator)
	copy(out, _frame_floating_dock_ids[:])
	clear(&_frame_floating_dock_ids)
	return out
}

Monitor_Work_Rect :: struct {
	main_pos:  im.Vec2,
	main_size: im.Vec2,
	work_pos:  im.Vec2,
	work_size: im.Vec2,
}

@(private = "file")
_monitor_work_or_main :: #force_inline proc(m: Monitor_Work_Rect) -> (im.Vec2, im.Vec2) {
	if m.work_size.x > 64 && m.work_size.y > 64 {
		return m.work_pos, m.work_size
	}
	if m.main_size.x > 64 && m.main_size.y > 64 {
		return m.main_pos, m.main_size
	}
	return {}, {}
}

@(private = "file")
_collect_platform_monitors :: proc(allocator := context.temp_allocator) -> []Monitor_Work_Rect {
	pio := im.GetPlatformIO()
	if pio == nil || pio.Monitors.Size <= 0 || pio.Monitors.Data == nil do return nil
	src := ([^]im.PlatformMonitor)(pio.Monitors.Data)[:pio.Monitors.Size]
	out := make([]Monitor_Work_Rect, len(src), allocator)
	for m, i in src {
		out[i] = Monitor_Work_Rect{
			main_pos  = m.MainPos,
			main_size = m.MainSize,
			work_pos  = m.WorkPos,
			work_size = m.WorkSize,
		}
	}
	return out
}

// Resolves the work area of the monitor containing `center`, or nearest monitor by squared box distance.
resolve_monitor_work_rect :: proc(
	center:        im.Vec2,
	monitors:      []Monitor_Work_Rect,
	fallback_pos:  im.Vec2,
	fallback_size: im.Vec2,
) -> (pos: im.Vec2, size: im.Vec2) {
	if len(monitors) == 0 {
		return fallback_pos, fallback_size
	}
	for m in monitors {
		if m.main_size.x <= 0 || m.main_size.y <= 0 do continue
		if center.x >= m.main_pos.x && center.x < m.main_pos.x + m.main_size.x &&
		   center.y >= m.main_pos.y && center.y < m.main_pos.y + m.main_size.y {
			wp, ws := _monitor_work_or_main(m)
			if ws.x > 64 && ws.y > 64 do return wp, ws
		}
	}
	best_idx := -1
	best_dist_sq := f32(1e30)
	for m, i in monitors {
		if m.main_size.x <= 0 || m.main_size.y <= 0 do continue
		cx := clamp(center.x, m.main_pos.x, m.main_pos.x + m.main_size.x)
		cy := clamp(center.y, m.main_pos.y, m.main_pos.y + m.main_size.y)
		dx := center.x - cx
		dy := center.y - cy
		d2 := dx * dx + dy * dy
		if best_idx < 0 || d2 < best_dist_sq {
			best_dist_sq = d2
			best_idx = i
		}
	}
	if best_idx >= 0 {
		wp, ws := _monitor_work_or_main(monitors[best_idx])
		if ws.x > 64 && ws.y > 64 do return wp, ws
	}
	return fallback_pos, fallback_size
}

// Clamps a floating window onto its target monitor work area so its title bar never drifts off-screen ("Anti-Narnia").
clamp_floating_rect_to_monitors :: proc(
	pos:           im.Vec2,
	size:          im.Vec2,
	monitors:      []Monitor_Work_Rect,
	fallback_pos:  im.Vec2,
	fallback_size: im.Vec2,
	title_bar_h:   f32  = 28.0,
	min_visible_w: f32  = 96.0,
	clamp_size:    bool = false,
) -> (out_pos: im.Vec2, out_size: im.Vec2) {
	out_pos  = pos
	out_size = size
	wpos, wsz := resolve_monitor_work_rect(pos + size * 0.5, monitors, fallback_pos, fallback_size)
	if wsz.x <= 0 || wsz.y <= 0 do return out_pos, out_size

	if clamp_size {
		if out_size.x > wsz.x do out_size.x = wsz.x
		if out_size.y > wsz.y do out_size.y = wsz.y
	}

	max_y := max(wpos.y, wpos.y + wsz.y - title_bar_h)
	out_pos.y = clamp(out_pos.y, wpos.y, max_y)

	if wsz.x <= min_visible_w {
		out_pos.x = wpos.x
	} else {
		min_x := wpos.x - out_size.x + min_visible_w
		max_x := wpos.x + wsz.x - min_visible_w
		if min_x > max_x {
			out_pos.x = wpos.x
		} else {
			out_pos.x = clamp(out_pos.x, min_x, max_x)
		}
	}
	return out_pos, out_size
}

// Finds the work area (excluding OS taskbar) of the monitor containing `center` (or main viewport work area).
monitor_work_rect_at :: proc(center: im.Vec2, outside_main: bool) -> (pos: im.Vec2, size: im.Vec2) {
	mvp := im.GetMainViewport()
	fb_pos  := mvp != nil ? mvp.WorkPos  : im.Vec2{0, 0}
	fb_size := mvp != nil ? mvp.WorkSize : im.Vec2{1280, 720}
	if !outside_main {
		return fb_pos, fb_size
	}
	mons := _collect_platform_monitors(context.temp_allocator)
	return resolve_monitor_work_rect(center, mons, fb_pos, fb_size)
}

@(private = "file")
_viewport_sdl_win :: proc(vp: ^im.Viewport) -> ^sdl.Window {
	if vp == nil || vp.PlatformHandle == nil do return nil
	if w := sdl.GetWindowFromID(sdl.WindowID(uintptr(vp.PlatformHandle))); w != nil {
		return w
	}
	return (^sdl.Window)(vp.PlatformHandle)
}

@(private = "file")
_usable_work_rect_for_sdl_win :: proc(w: ^sdl.Window, fallback_center: im.Vec2, outside_main: bool) -> (pos: im.Vec2, size: im.Vec2) {
	if w != nil {
		if did := sdl.GetDisplayForWindow(w); did != 0 {
			rect: sdl.Rect
			if sdl.GetDisplayUsableBounds(did, &rect) && rect.w > 64 && rect.h > 64 {
				return {f32(rect.x), f32(rect.y)}, {f32(rect.w), f32(rect.h)}
			}
		}
	}
	return monitor_work_rect_at(fallback_center, outside_main)
}

@(private = "file")
_queue_pending_dock_op :: proc(root_id: im.ID, pos, size: im.Vec2) -> bool {
	if _pending_dock_ops == nil {
		_pending_dock_ops = make([dynamic]_Pending_Dock_Node_Op, 0, 4, runtime.default_allocator())
	}
	for &existing in _pending_dock_ops {
		if existing.node_id == root_id {
			existing.pos         = pos
			existing.size        = size
			existing.frames_left = 2
			return true
		}
	}
	append(&_pending_dock_ops, _Pending_Dock_Node_Op{
		node_id     = root_id,
		pos         = pos,
		size        = size,
		frames_left = 2,
	})
	return true
}

@(private = "file")
_get_max_state :: proc(k: string) -> ^_Max_State {
	if m, ok := &_max_states[k]; ok do return m
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	if _max_states == nil do _max_states = make(map[string]_Max_State)
	_max_states[strings.clone(k)] = {}
	return &_max_states[k]
}

is_window_maximized :: proc(title: cstring) -> bool {
	if _max_states == nil do return false
	k := _key(title)
	if m, ok := _max_states[k]; ok do return m.maximized
	return false
}

toggle_maximize_window :: proc(title: cstring, cur_pos, cur_size: im.Vec2, outside_main: bool) {
	k := _key(title)
	m := _get_max_state(k)
	vp := im.GetWindowViewport()
	sdl_w := outside_main ? _viewport_sdl_win(vp) : nil
	if !m.maximized {
		eff_pos := cur_pos
		eff_size := cur_size
		if sdl_w != nil {
			wx, wy, ww, wh: i32
			_ = sdl.GetWindowPosition(sdl_w, &wx, &wy)
			_ = sdl.GetWindowSize(sdl_w, &ww, &wh)
			if ww > 64 && wh > 32 {
				eff_pos = {f32(wx), f32(wy)}
				eff_size = {f32(ww), f32(wh)}
			}
		}
		wpos, wsz := _usable_work_rect_for_sdl_win(sdl_w, eff_pos + eff_size * 0.5, outside_main)
		if eff_size.x >= 120 && eff_size.y >= 80 && (eff_size.x < wsz.x - 16 || eff_size.y < wsz.y - 16) {
			m.restore_pos  = eff_pos
			m.restore_size = eff_size
		} else if m.restore_size.x < 160 || m.restore_size.y < 100 {
			rsize := im.Vec2{max(wsz.x * 0.72, 320), max(wsz.y * 0.72, 240)}
			m.restore_size = rsize
			m.restore_pos  = wpos + (wsz - rsize) * 0.5
		}
		m.target_pos    = wpos
		m.target_size   = wsz
		m.maximized     = true
		m.settle_frames = 2
	} else {
		mons := outside_main ? _collect_platform_monitors(context.temp_allocator) : nil
		mvp := im.GetMainViewport()
		fb_pos  := mvp != nil ? mvp.WorkPos  : im.Vec2{0, 0}
		fb_size := mvp != nil ? mvp.WorkSize : im.Vec2{1280, 720}
		rpos := m.restore_pos
		rsz  := m.restore_size
		if rsz.x < 160 || rsz.y < 100 {
			wpos, wsz := _usable_work_rect_for_sdl_win(sdl_w, m.target_pos + m.target_size * 0.5, outside_main)
			rsz  = {max(min(wsz.x * 0.72, 960), 320), max(min(wsz.y * 0.72, 620), 240)}
			rpos = wpos + (wsz - rsz) * 0.5
		}
		cpos, csz := clamp_floating_rect_to_monitors(rpos, rsz, mons, fb_pos, fb_size, clamp_size = true)
		m.target_pos    = cpos
		m.target_size   = csz
		m.maximized     = false
		m.settle_frames = 2
	}
}

is_dock_node_maximized :: proc(node: ^im.DockNode) -> bool {
	if node == nil || _max_states == nil do return false
	root := node
	for root.ParentNode != nil do root = root.ParentNode
	dk := fmt.tprintf("__docknode_%d", root.ID_)
	if m, ok := &_max_states[dk]; ok {
		return m.maximized
	}
	return false
}

toggle_maximize_dock_node :: proc(node: ^im.DockNode) {
	if node == nil do return
	root := node
	for root.ParentNode != nil do root = root.ParentNode
	dk := fmt.tprintf("__docknode_%d", root.ID_)
	m := _get_max_state(dk)
	vp := root.HostWindow != nil ? im.FindViewportByID(root.HostWindow.ViewportId) : nil
	main_vp := im.GetMainViewport()
	outside := vp != nil && (main_vp == nil || vp.ID_ != main_vp.ID_)
	sdl_w := outside ? _viewport_sdl_win(vp) : nil
	if !m.maximized {
		eff_pos := root.Pos
		eff_size := root.Size
		if sdl_w != nil {
			wx, wy, ww, wh: i32
			_ = sdl.GetWindowPosition(sdl_w, &wx, &wy)
			_ = sdl.GetWindowSize(sdl_w, &ww, &wh)
			if ww > 64 && wh > 32 {
				eff_pos = {f32(wx), f32(wy)}
				eff_size = {f32(ww), f32(wh)}
			}
		}
		wpos, wsz := _usable_work_rect_for_sdl_win(sdl_w, eff_pos + eff_size * 0.5, true)
		if eff_size.x >= 120 && eff_size.y >= 80 && (eff_size.x < wsz.x - 16 || eff_size.y < wsz.y - 16) {
			m.restore_pos  = eff_pos
			m.restore_size = eff_size
		} else if m.restore_size.x < 160 || m.restore_size.y < 100 {
			rsize := im.Vec2{max(wsz.x * 0.72, 320), max(wsz.y * 0.72, 240)}
			m.restore_size = rsize
			m.restore_pos  = wpos + (wsz - rsize) * 0.5
		}
		m.target_pos  = wpos
		m.target_size = wsz
		m.maximized   = true
	} else {
		mons := _collect_platform_monitors(context.temp_allocator)
		mvp := im.GetMainViewport()
		fb_pos  := mvp != nil ? mvp.WorkPos  : im.Vec2{0, 0}
		fb_size := mvp != nil ? mvp.WorkSize : im.Vec2{1280, 720}
		rpos := m.restore_pos
		rsz  := m.restore_size
		if rsz.x < 160 || rsz.y < 100 {
			wpos, wsz := _usable_work_rect_for_sdl_win(sdl_w, m.target_pos + m.target_size * 0.5, true)
			rsz  = {max(min(wsz.x * 0.72, 980), 320), max(min(wsz.y * 0.72, 640), 240)}
			rpos = wpos + (wsz - rsz) * 0.5
		}
		cpos, csz := clamp_floating_rect_to_monitors(rpos, rsz, mons, fb_pos, fb_size, clamp_size = true)
		m.target_pos  = cpos
		m.target_size = csz
		m.maximized   = false
	}
	m.settle_frames = 2
	_ = _queue_pending_dock_op(root.ID_, m.target_pos, m.target_size)
}

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
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
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
	if _max_states != nil {
		if m, ok := &_max_states[_key(title)]; ok {
			m^ = {}
		}
	}
}

// Ask for the window to come back into the main window (see file comment).
reunite :: proc(title: cstring) {
	p := _get(title)
	p.request_back = true
	p.request_out = false
	if _max_states != nil {
		if m, ok := &_max_states[_key(title)]; ok {
			m^ = {}
		}
	}
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
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
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
		target := resolve_leaf_dock_node(p.dock_id)
		if target == 0 do target = resolve_leaf_dock_node(_get_central_dock_target())
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

	settle_active := false
	if _max_states != nil {
		if m, ok := &_max_states[_key(title)]; ok && m.settle_frames > 0 {
			settle_active = true
			m.settle_frames -= 1
			im.SetNextWindowPos(m.target_pos, .Always)
			im.SetNextWindowSize(m.target_size, .Always)
		}
	}

	actual_flags := flags
	g_pre := im.GetCurrentContext()
	if p.popped || (p.own_viewport && g_pre != nil && g_pre.MovingWindow != nil) {
		// Keep a popped or actively dragged external OS window & swapchain alive while passing
		// back over the main window (avoiding mid-drag Vulkan swapchain destroy/recreate stalls),
		// while keeping full DockSpace drop-target docking enabled (and allowing auto-merge when
		// dropped back inside the main window).
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
	// accurate across frames.
	p.docked = im.IsWindowDocked()
	if p.docked do p.dock_id = im.GetWindowDockID()
	vp := im.GetWindowViewport()
	p.own_viewport = vp != nil && vp.ID_ != im.GetMainViewport().ID_
	if p.docked && p.own_viewport && p.dock_id != 0 {
		_record_floating_dock_id(p.dock_id)
	}
	if open {
		p.pos = im.GetWindowPos()
		p.size = im.GetWindowSize()
		g := im.GetCurrentContext()
		if !p.docked && p.own_viewport && !settle_active && g != nil && g.MovingWindow == nil && !im.IsMouseDown(.Left) && p.size.x > 64 && p.size.y > 32 {
			mons := _collect_platform_monitors(context.temp_allocator)
			mvp := im.GetMainViewport()
			fb_pos  := mvp != nil ? mvp.WorkPos  : im.Vec2{0, 0}
			fb_size := mvp != nil ? mvp.WorkSize : im.Vec2{1280, 720}
			cpos, _ := clamp_floating_rect_to_monitors(p.pos, p.size, mons, fb_pos, fb_size)
			if abs(cpos.x - p.pos.x) > 1.0 || abs(cpos.y - p.pos.y) > 1.0 {
				im.SetWindowPosStr(title, cpos, .Always)
				p.pos = cpos
			}
		}
		cur_win := im.GetCurrentWindow()
		if _max_states != nil && g != nil && cur_win != nil && g.MovingWindow == cur_win {
			if m, ok := &_max_states[_key(title)]; ok && m.maximized && m.settle_frames == 0 {
				io := im.GetIO()
				rsz := m.restore_size
				if rsz.x < 160 || rsz.y < 100 {
					rsz = {max(min(p.size.x * 0.72, 960), 320), max(min(p.size.y * 0.72, 620), 240)}
				}
				ratio := clamp((io.MousePos.x - p.pos.x) / max(p.size.x, 1.0), 0.15, 0.85)
				m.maximized     = false
				m.target_pos    = {io.MousePos.x - ratio * rsz.x, io.MousePos.y - 14.0}
				m.target_size   = rsz
				m.settle_frames = 2
			}
		}
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
	if p.docked && p.own_viewport && p.dock_id != 0 {
		_record_floating_dock_id(p.dock_id)
	}
	// Docked by dragging into the main window: it is reunited.
	if p.popped && p.docked && !p.own_viewport do p.popped = false
}
