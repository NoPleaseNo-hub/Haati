package node_canvas

// Shared node-graph canvas (docs/PlayableGraph.md, Graph UI) — an editor
// subpackage like inspector/menu/undo, so package editors can draw with it:
// pan/zoom grid,
// node chrome with ports, bezier edge routing, node dragging and selection.
// Strictly presentation and interaction — no document model. Each client
// (the PlayableGraph visualizer today; Controller/ShaderGraph/VfxGraph
// canvases later) supplies node content, port meaning and what happens on
// edit. The first client is read-only, so ports render but do not interact —
// marquee selection and edit undo arrive with the first editing client.
//
// Coordinates: nodes live in CANVAS units (zoom-independent). screen =
// origin + (p + pan) * zoom. Client code converts through canvas_to_screen
// and the port helpers so pan/zoom stays the canvas's business.
//
// A node's body is a list of ROWS, each a label and a value, the same shape a
// property row has everywhere else in the editor. A row can carry an input
// port, so an edge lands on the row it feeds rather than at some fraction of
// the node's height — that is what makes a mixer with six inputs readable.

import "base:runtime"
import "core:fmt"
import "core:math"
import im "haati:external/odin-imgui"
import thm "haati:editor/theme"
import widgets "haati:editor/widgets"

global_wire_style: Canvas_Wire_Style = .Electronic_45
on_global_wire_style_changed: proc(style: Canvas_Wire_Style)

set_global_wire_style :: proc(style: Canvas_Wire_Style, notify := true) {
	global_wire_style = style
	if notify && on_global_wire_style_changed != nil {
		on_global_wire_style_changed(style)
	}
}

draw_wire_style_combo :: proc(id: cstring = "##nc_global_wire_style", width: f32 = 152.0) -> bool {
	names := [4]cstring{"Wires: Smooth Bezier", "Wires: 45° Subway", "Wires: Electric", "Wires: 90° Orthogonal"}
	cur := clamp(i32(global_wire_style), 0, 3)
	im.SetNextItemWidth(width)
	changed := false
	if im.BeginCombo(id, names[cur]) {
		for nm, idx in names {
			if im.Selectable(nm, i32(idx) == cur) {
				set_global_wire_style(Canvas_Wire_Style(idx), true)
				changed = true
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Global Graph Wire Routing Style (persisted and synchronized across Gameplay, Anim, VFX, Material Shader & Audio graphs)")
	return changed
}

CANVAS_NODE_W :: f32(184) // node width, canvas units
CANVAS_HEADER_H :: f32(24) // node title bar
CANVAS_ROW_H :: f32(18) // one body row
CANVAS_PAD :: f32(7) // body inset, all four sides
CANVAS_PORT_R :: f32(4.5) // port dot radius
CANVAS_GRID :: f32(28)
CANVAS_GRID_MAJOR :: 4 // every Nth grid line draws brighter
CANVAS_ZOOM_MIN :: f32(0.25)
CANVAS_ZOOM_MAX :: f32(2.5)

// Port hues by what flows through them, so an edge says what it carries
// without following it to both ends.
PORT_POSE :: im.Vec4{0.56, 0.78, 0.44, 1}
PORT_VALUE :: im.Vec4{0.87, 0.44, 0.47, 1}

// Shared wire routing style used by both Faker State Machine Graph and Void Material Graph Editor.
Canvas_Wire_Style :: enum {
	Smooth_Bezier,
	Electronic_45,
	Electric_Jagged,
	Orthogonal_90,
}

// One body row. `value` is right-aligned in the value column, `label` left in
// the label column. `port` gives the row an input dot on the left edge.
Canvas_Row :: struct {
	label: cstring,
	value: cstring,
	port:  bool,
	col:   im.Vec4, // port hue; zero alpha takes PORT_POSE
}

// Interactive Comment Box frame stored directly on a `Node_Canvas`.
Canvas_Comment_Box :: struct {
	active:    bool,
	pos:       im.Vec2,
	size:      im.Vec2,
	color:     im.Vec4,
	title_buf: [64]u8,
}

Node_Canvas :: struct {
	pan:                   im.Vec2, // canvas-unit offset of the origin
	zoom:                  f32,
	sel:                   int, // primary selected node id, -1 = none
	selected_ids:          map[int]bool, // unbounded multi-selection set (runtime.default_allocator)
	marquee_active:        bool,
	marquee_start:         im.Vec2,
	marquee_end:           im.Vec2,
	ctx_hovered_id:        int, // node id right-clicked for context menu (-1 = empty canvas)
	ctx_handled:           bool,
	suppress_node_drag:    bool, // set by pin-wiring clients so dragging a port never drags the node card
	rmb_pressed_in_canvas: bool,
	rmb_pressed_node_id:   int,
	rmb_pan_travel:        f32,
	wire_style:            Canvas_Wire_Style,
	lock_local_wire_style: bool,
	default_collapsed:     bool, // bulk collapse default toggled by `canvas_set_all_collapsed`
	collapsed_ids:         map[int]bool, // per-node collapse overrides (unbounded ids)
	node_sizes:            map[int]im.Vec2, // live measured canvas-unit sizes (unbounded ids)
	comments:              [8]Canvas_Comment_Box,

	// Per-frame, set by canvas_begin.
	origin: im.Vec2, // screen top-left of the canvas rect
	size:   im.Vec2,
}

canvas_init :: proc(cv: ^Node_Canvas) {
	cv.zoom = 1
	cv.sel = -1
	clear(&cv.selected_ids)
	cv.marquee_active = false
	cv.ctx_hovered_id = -1
	cv.rmb_pressed_in_canvas = false
	cv.rmb_pressed_node_id = -1
	cv.rmb_pan_travel = 0
	cv.default_collapsed = false
	clear(&cv.collapsed_ids)
	clear(&cv.node_sizes)
}

canvas_destroy :: proc(cv: ^Node_Canvas) {
	if cv == nil do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	delete(cv.selected_ids)
	delete(cv.collapsed_ids)
	delete(cv.node_sizes)
	cv.selected_ids  = nil
	cv.collapsed_ids = nil
	cv.node_sizes    = nil
}

canvas_get_node_size :: proc(cv: ^Node_Canvas, id: int, fallback: im.Vec2 = {CANVAS_NODE_W, 96}) -> im.Vec2 {
	if cv != nil && id >= 0 && cv.node_sizes != nil {
		if sz, ok := cv.node_sizes[id]; ok && sz.x > 1.0 && sz.y > 1.0 {
			return sz
		}
	}
	return fallback
}

canvas_set_node_size :: proc(cv: ^Node_Canvas, id: int, sz_canvas: im.Vec2) {
	if cv == nil || id < 0 do return
	if cv.node_sizes == nil {
		cv.node_sizes = make(map[int]im.Vec2, 32, runtime.default_allocator())
	}
	cv.node_sizes[id] = sz_canvas
}

canvas_is_collapsed :: proc(cv: ^Node_Canvas, id: int) -> bool {
	if cv == nil || id < 0 do return false
	if cv.collapsed_ids != nil {
		if collapsed, ok := cv.collapsed_ids[id]; ok {
			return collapsed
		}
	}
	return cv.default_collapsed
}

canvas_set_collapsed :: proc(cv: ^Node_Canvas, id: int, collapsed: bool) {
	if cv == nil || id < 0 do return
	if collapsed == cv.default_collapsed {
		if cv.collapsed_ids != nil {
			delete_key(&cv.collapsed_ids, id)
		}
		return
	}
	if cv.collapsed_ids == nil {
		cv.collapsed_ids = make(map[int]bool, 16, runtime.default_allocator())
	}
	cv.collapsed_ids[id] = collapsed
}

canvas_set_all_collapsed :: proc(cv: ^Node_Canvas, collapsed: bool) {
	if cv == nil do return
	cv.default_collapsed = collapsed
	clear(&cv.collapsed_ids)
}

canvas_is_selected :: proc(cv: ^Node_Canvas, id: int) -> bool {
	if cv == nil do return false
	if cv.sel == id do return true
	if id >= 0 && cv.selected_ids != nil {
		return cv.selected_ids[id] or_else false
	}
	return false
}

canvas_set_selected :: proc(cv: ^Node_Canvas, id: int, selected: bool) {
	if cv == nil do return
	if id >= 0 {
		if selected {
			if cv.selected_ids == nil {
				cv.selected_ids = make(map[int]bool, 16, runtime.default_allocator())
			}
			cv.selected_ids[id] = true
			cv.sel = id
		} else {
			if cv.selected_ids != nil {
				delete_key(&cv.selected_ids, id)
			}
			if cv.sel == id do cv.sel = -1
		}
	} else if !selected && cv.sel == id {
		cv.sel = -1
	}
}

canvas_clear_selection :: proc(cv: ^Node_Canvas) {
	if cv == nil do return
	cv.sel = -1
	clear(&cv.selected_ids)
}

canvas_selected_count :: proc(cv: ^Node_Canvas) -> int {
	if cv == nil do return 0
	cnt := 0
	if cv.selected_ids != nil {
		for _, sel in cv.selected_ids {
			if sel do cnt += 1
		}
	}
	if cnt == 0 && cv.sel >= 0 && cv.sel < 9000 {
		return 1
	}
	return cnt
}

canvas_to_screen :: proc(cv: ^Node_Canvas, p: im.Vec2) -> im.Vec2 {
	return cv.origin + (p + cv.pan) * cv.zoom
}

canvas_node_size :: proc(n_rows: int) -> im.Vec2 {
	return im.Vec2{CANVAS_NODE_W, CANVAS_HEADER_H + CANVAS_PAD * 2 + f32(n_rows) * CANVAS_ROW_H}
}

// Dynamically measures the unscaled canvas-unit size needed so neither `title` nor any
// `label + gutter + value` row ever clips or overlaps.
canvas_measure_node_size :: proc(title: cstring, rows: []Canvas_Row) -> im.Vec2 {
	req_w := CANVAS_NODE_W
	if title != nil {
		req_w = max(req_w, im.CalcTextSize(title).x + CANVAS_PAD * 2 + 12.0)
	}
	for row in rows {
		lw: f32 = row.label != nil ? im.CalcTextSize(row.label).x : 0.0
		vw: f32 = row.value != nil ? im.CalcTextSize(row.value).x : 0.0
		gutter: f32 = (row.label != nil && row.value != nil) ? 20.0 : 0.0
		req_w = max(req_w, lw + gutter + vw + CANVAS_PAD * 2 + 8.0)
	}
	return im.Vec2{req_w, CANVAS_HEADER_H + CANVAS_PAD * 2 + f32(len(rows)) * CANVAS_ROW_H}
}

// Centre of row `i`, in canvas units from the node's top-left.
@(private = "file")
_row_y :: proc(i: int) -> f32 {
	return CANVAS_HEADER_H + CANVAS_PAD + f32(i) * CANVAS_ROW_H + CANVAS_ROW_H * 0.5
}

// Input port of row `row`, on the node's left edge (screen coords).
canvas_port_in :: proc(cv: ^Node_Canvas, pos: im.Vec2, row: int) -> im.Vec2 {
	return canvas_to_screen(cv, im.Vec2{pos.x, pos.y + _row_y(row)})
}

// The output port on the node's right edge, on row `row` (screen coords).
// When `node_id >= 0`, uses that node's dynamically measured canvas width instead of `CANVAS_NODE_W`.
canvas_port_out :: proc(cv: ^Node_Canvas, pos: im.Vec2, row: int = 0, node_id: int = -1) -> im.Vec2 {
	w := CANVAS_NODE_W
	if node_id >= 0 {
		w = canvas_get_node_size(cv, node_id, {CANVAS_NODE_W, 96}).x
	}
	return canvas_to_screen(cv, im.Vec2{pos.x + w, pos.y + _row_y(row)})
}

// Child region + grid. Draw edges, then nodes, then canvas_end. The
// background pan surface is submitted by canvas_end: overlapping imgui items
// go to the FIRST submitted one, so the node buttons (submitted between
// begin and end) win their clicks and the background takes the rest.
canvas_begin :: proc(cv: ^Node_Canvas, id: cstring) -> bool {
	if cv.zoom == 0 do canvas_init(cv)
	if !cv.lock_local_wire_style {
		cv.wire_style = global_wire_style
	}
	// No window padding: the canvas IS the child's whole rect. With the default
	// padding the content region is inset, so the surface and the grid stop
	// short of the border and the panel colour shows through as a frame.
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	open := im.BeginChild(id, im.Vec2{0, 0}, {.Borders}, {.NoScrollbar, .NoScrollWithMouse})
	im.PopStyleVar()
	if !open {
		im.EndChild()
		return false
	}
	cv.origin = im.GetCursorScreenPos()
	cv.size = im.GetContentRegionAvail()
	cv.ctx_handled = false
	if cv.size.x < 1 || cv.size.y < 1 {
		return true
	}

	// Track cumulative Right-Mouse travel across the gesture so holding RMB to pan
	// NEVER pops open the right-click menu on release (even if cursor slows down at the end).
	io := im.GetIO()
	in_rect := io.MousePos.x >= cv.origin.x && io.MousePos.x <= cv.origin.x + cv.size.x &&
	           io.MousePos.y >= cv.origin.y && io.MousePos.y <= cv.origin.y + cv.size.y
	if im.IsMouseClicked(.Right) && in_rect && im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
		cv.rmb_pressed_in_canvas = true
		cv.rmb_pressed_node_id   = -1
		cv.rmb_pan_travel        = 0
	}
	if cv.rmb_pressed_in_canvas && im.IsMouseDown(.Right) {
		cv.rmb_pan_travel += math.hypot(io.MouseDelta.x, io.MouseDelta.y)
	}

	dl := im.GetWindowDrawList()
	canvas_draw_grid_surface(dl, cv.origin, cv.origin + cv.size, cv.pan, cv.zoom)
	return true
}

// Shared clean canvas surface + pan-pinned minor/major grid used by both Node_Canvas and Material Graph Editor.
canvas_draw_grid_surface :: proc(dl: ^im.DrawList, c_min, c_max, pan: im.Vec2, zoom: f32 = 1.0) {
	sz := c_max - c_min
	if sz.x < 1 || sz.y < 1 do return

	p := thm.palette()

	// Recessed canvas backdrop so elevated node cards lift cleanly in both dark and light themes.
	im.DrawList_AddRectFilled(dl, c_min, c_max, im.GetColorU32ImVec4(p.bg_canvas))

	// Grid, offset with the pan so it reads as a surface. Every CANVAS_GRID_MAJOR
	// line draws brighter: a uniform grid gives the eye no scale, so panning far
	// out looks like standing still.
	minor := im.GetColorU32ImVec4(thm.with_alpha(p.border_subtle, p.is_light ? 0.55 : 0.42))
	major := im.GetColorU32ImVec4(thm.with_alpha(p.border_strong, p.is_light ? 0.68 : 0.58))
	sp := CANVAS_GRID * max(zoom, 0.1)
	for x := math.mod(pan.x * zoom, sp); x < sz.x; x += sp {
		if x < 0 do continue
		idx := int(math.round((x / zoom - pan.x) / CANVAS_GRID))
		col := idx % CANVAS_GRID_MAJOR == 0 ? major : minor
		im.DrawList_AddLine(dl, im.Vec2{c_min.x + x, c_min.y}, im.Vec2{c_min.x + x, c_max.y}, col, 1)
	}
	for y := math.mod(pan.y * zoom, sp); y < sz.y; y += sp {
		if y < 0 do continue
		idx := int(math.round((y / zoom - pan.y) / CANVAS_GRID))
		col := idx % CANVAS_GRID_MAJOR == 0 ? major : minor
		im.DrawList_AddLine(dl, im.Vec2{c_min.x, c_min.y + y}, im.Vec2{c_max.x, c_min.y + y}, col, 1)
	}
	im.DrawList_AddRect(dl, c_min, c_max, im.GetColorU32ImVec4(p.border_subtle), 0.0, 1.0)
}

// Processes empty-canvas interactions (Left-Drag Marquee Box Selection, Middle/Right-Drag Panning,
// Mouse-Wheel Zoom, and Right-Click Context Menu) and returns true if the context menu popup is open
// so the caller can append custom menu items before calling `im.EndPopup()`.
canvas_begin_context_menu :: proc(
	cv: ^Node_Canvas,
	node_positions: []im.Vec2 = nil,
	base_node_id: int = 0,
	suppress_marquee: bool = false,
) -> bool {
	if cv == nil do return false
	cv.ctx_handled = true
	if cv.size.x >= 1 && cv.size.y >= 1 {
		io := im.GetIO()
		dl := im.GetWindowDrawList()

		im.SetCursorScreenPos(cv.origin)
		im.InvisibleButton("##canvas_bg", {max(cv.size.x, 1.0), max(cv.size.y, 1.0)})
		bg_clicked_left  := im.IsItemClicked(.Left)
		bg_active_left   := im.IsItemActive() && im.IsMouseDown(.Left)
		bg_hovered       := im.IsItemHovered()

		// 1. Left-Click / Left-Drag on Empty Space -> Marquee Box Multi-Selection!
		if !suppress_marquee {
			if bg_clicked_left {
				if !io.KeyCtrl && !io.KeyShift {
					canvas_clear_selection(cv)
				}
				cv.marquee_active = true
				cv.marquee_start  = io.MousePos
				cv.marquee_end    = io.MousePos
			}
			if cv.marquee_active {
				if bg_active_left || im.IsMouseDown(.Left) {
					cv.marquee_end = io.MousePos
					m_min := im.Vec2{min(cv.marquee_start.x, cv.marquee_end.x), min(cv.marquee_start.y, cv.marquee_end.y)}
					m_max := im.Vec2{max(cv.marquee_start.x, cv.marquee_end.x), max(cv.marquee_start.y, cv.marquee_end.y)}
					canvas_draw_marquee(dl, m_min, m_max)

					if (m_max.x - m_min.x) > 3.0 || (m_max.y - m_min.y) > 3.0 {
						if !io.KeyCtrl && !io.KeyShift {
							canvas_clear_selection(cv)
						}
						for np, idx in node_positions {
							node_sz := canvas_get_node_size(cv, base_node_id + idx, canvas_node_size(4)) * cv.zoom
							n_min := canvas_to_screen(cv, np)
							n_max := n_min + node_sz
							if n_max.x >= m_min.x && n_min.x <= m_max.x && n_max.y >= m_min.y && n_min.y <= m_max.y {
								canvas_set_selected(cv, base_node_id + idx, true)
							}
						}
					}
				} else {
					cv.marquee_active = false
				}
			}
		} else {
			cv.marquee_active = false
		}

		// 2. Middle-Mouse Drag OR Right-Mouse Drag -> Pan Canvas!
		// Works whether RMB started on empty space OR over a node card.
		if im.IsWindowHovered(im.HoveredFlags_ChildWindows) || (cv.rmb_pressed_in_canvas && im.IsMouseDown(.Right)) {
			if im.IsMouseDragging(.Middle, 0) || (cv.rmb_pressed_in_canvas && im.IsMouseDown(.Right) && cv.rmb_pan_travel >= 3.0) {
				cv.pan += io.MouseDelta / max(cv.zoom, 0.1)
			}
		}
		if im.IsWindowHovered(im.HoveredFlags_ChildWindows) && !im.IsPopupOpen("", im.PopupFlags_AnyPopup) {
			wheel := io.MouseWheel
			if wheel != 0 && !im.IsAnyItemActive() {
				mp := im.GetMousePos()
				world := (mp - cv.origin) / cv.zoom - cv.pan
				cv.zoom = clamp(cv.zoom * math.pow(f32(1.1), wheel), CANVAS_ZOOM_MIN, CANVAS_ZOOM_MAX)
				cv.pan = (mp - cv.origin) / cv.zoom - world
			}
		}

		// 3. Right-Click Release (ONLY when cumulative travel < 5px — never after RMB drag-panning!)
		if im.IsMouseReleased(.Right) {
			if cv.rmb_pressed_in_canvas && cv.rmb_pan_travel < 5.0 && (bg_hovered || cv.rmb_pressed_node_id >= 0) {
				cv.ctx_hovered_id = cv.rmb_pressed_node_id
				im.OpenPopup("##nc_context_popup")
			}
			cv.rmb_pressed_in_canvas = false
			cv.rmb_pressed_node_id   = -1
		} else if !im.IsMouseDown(.Right) {
			cv.rmb_pressed_in_canvas = false
		}
	}
	return im.BeginPopup("##nc_context_popup")
}

// Background interaction (Left-Drag Marquee selects nodes, Middle/Right-Drag pans,
// wheel zooms around the cursor, Right-Click opens context menu), then closes child.
canvas_end :: proc(cv: ^Node_Canvas, node_positions: []im.Vec2 = nil, base_node_id: int = 0) {
	if cv != nil && !cv.ctx_handled {
		if canvas_begin_context_menu(cv, node_positions, base_node_id, false) {
			canvas_draw_default_context_menu_items(cv, node_positions, base_node_id)
			im.EndPopup()
		}
	}
	im.EndChild()
}

// Default context menu items shared across all `Node_Canvas` graphs (Wrap in Comment Box, Select All, Wire Style, Reset View).
canvas_draw_default_context_menu_items :: proc(cv: ^Node_Canvas, node_positions: []im.Vec2 = nil, base_node_id: int = 0) {
	if cv == nil do return
	sel_cnt := canvas_selected_count(cv)
	cmt_lbl: cstring = sel_cnt > 0 ? fmt.ctprintf("+ Wrap %d Selected Node(s) in Comment Box (C)", sel_cnt) : "+ Add Comment Box Here (C)"
	if im.MenuItem(cmt_lbl) {
		canvas_spawn_comment_for_selection(cv, node_positions, base_node_id, "Comment Group")
	}
	if node_positions != nil && len(node_positions) > 0 {
		if im.MenuItem("Select All Nodes") {
			for _, idx in node_positions {
				canvas_set_selected(cv, base_node_id + idx, true)
			}
		}
	}
	if sel_cnt > 0 {
		if im.MenuItem("Clear Selection") {
			canvas_clear_selection(cv)
		}
	}
	im.Separator()
	im.TextDisabled("Wire Routing Style (Global)")
	if im.MenuItem("Smooth Bezier Wires", nil, cv.wire_style == .Smooth_Bezier) {
		cv.wire_style = .Smooth_Bezier
		if !cv.lock_local_wire_style do set_global_wire_style(.Smooth_Bezier, true)
	}
	if im.MenuItem("Electronic 45° Wires (UE)", nil, cv.wire_style == .Electronic_45) {
		cv.wire_style = .Electronic_45
		if !cv.lock_local_wire_style do set_global_wire_style(.Electronic_45, true)
	}
	if im.MenuItem("Electric Jagged Wires", nil, cv.wire_style == .Electric_Jagged) {
		cv.wire_style = .Electric_Jagged
		if !cv.lock_local_wire_style do set_global_wire_style(.Electric_Jagged, true)
	}
	if im.MenuItem("Orthogonal 90° Wires", nil, cv.wire_style == .Orthogonal_90) {
		cv.wire_style = .Orthogonal_90
		if !cv.lock_local_wire_style do set_global_wire_style(.Orthogonal_90, true)
	}
	im.Separator()
	if im.MenuItem("Reset Canvas View (Pan & Zoom)") {
		cv.pan  = {0, 0}
		cv.zoom = 1.0
	}
}

// One node: a header tinted by `color` with the title centred in it, `rows` in
// the body, an input dot on every row that asks for one, and one output dot on
// `out_row`. Draggable (writes `pos` back in canvas units, and moves all selected
// nodes in `all_node_positions` together when multi-selected), click selects,
// right-click opens context menu.
canvas_node :: proc(
	cv: ^Node_Canvas,
	id: int,
	pos: ^im.Vec2,
	title: cstring,
	color: im.Vec4,
	rows: []Canvas_Row,
	has_out: bool,
	out_row: int = 0,
	all_node_positions: []im.Vec2 = nil,
	base_node_id: int = 0,
) {
	dl := im.GetWindowDrawList()
	io := im.GetIO()
	sz := canvas_measure_node_size(title, rows)
	canvas_set_node_size(cv, id, sz)
	rmin := canvas_to_screen(cv, pos^)
	rmax := rmin + sz * cv.zoom
	font := im.GetFont()
	font_sz := max(im.GetFontSize() * cv.zoom, 7)
	selected := canvas_is_selected(cv, id)

	// Interaction first: the button claims hover over the background surface,
	// the visuals draw over both.
	im.SetCursorScreenPos(rmin)
	btn_sz := rmax - rmin
	im.InvisibleButton(fmt.ctprintf("##canvas_node_%d", id), {max(btn_sz.x, 1.0), max(btn_sz.y, 1.0)})
	if im.IsItemClicked(.Left) && !cv.suppress_node_drag {
		if io.KeyCtrl || io.KeyShift {
			canvas_set_selected(cv, id, !canvas_is_selected(cv, id))
		} else if !canvas_is_selected(cv, id) {
			canvas_clear_selection(cv)
			canvas_set_selected(cv, id, true)
		} else {
			cv.sel = id
		}
		selected = canvas_is_selected(cv, id)
	}
	if im.IsItemClicked(.Right) {
		if !canvas_is_selected(cv, id) {
			canvas_clear_selection(cv)
			canvas_set_selected(cv, id, true)
			selected = true
		} else {
			cv.sel = id
		}
		// Record node for RMB release; do NOT open popup on mouse-down so RMB-hold pans cleanly!
		cv.rmb_pressed_in_canvas = true
		cv.rmb_pressed_node_id   = id
	}
	if !cv.suppress_node_drag && im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
		delta := io.MouseDelta / cv.zoom
		if all_node_positions != nil && canvas_is_selected(cv, id) && canvas_selected_count(cv) > 1 {
			for &np, idx in all_node_positions {
				if canvas_is_selected(cv, base_node_id + idx) {
					np += delta
				}
			}
		} else {
			pos^ += delta
		}
		// Immediately recompute rmin/rmax in the same frame so card chrome, text,
		// and ports all render at the exact same position with zero 1-frame lag!
		rmin = canvas_to_screen(cv, pos^)
		rmax = rmin + sz * cv.zoom
	}

	// Shared high-contrast Faker-style card chrome (drop shadow, dark body, top-rounded
	// hue-scaled header, outer selection halo, and bright hue-tinted border).
	header_h := CANVAS_HEADER_H * cv.zoom
	canvas_draw_card_chrome(dl, rmin, rmax, header_h, color, selected, im.IsItemHovered(), cv.zoom, 6.0)

	// Text stays inside the node: a long clip name would otherwise run across
	// the canvas and over its neighbours. Popped before the ports, which sit ON
	// the edge and would be cut in half by it.
	im.DrawList_PushClipRect(dl, rmin, rmax, true)

	p := thm.palette()
	pad := CANVAS_PAD * cv.zoom
	tw := im.CalcTextSize(title).x * cv.zoom
	title_x := max(rmin.x + pad, rmin.x + (rmax.x - rmin.x - tw) * 0.5)
	im.DrawList_AddTextImFontPtr(dl, font, font_sz,
		im.Vec2{title_x, rmin.y + (header_h - font_sz) * 0.5},
		im.GetColorU32ImVec4(p.text_primary), title)

	label_col := im.GetColorU32ImVec4(p.text_secondary)
	value_col := im.GetColorU32ImVec4(p.text_primary)
	for row, i in rows {
		y := rmin.y + (_row_y(i) * cv.zoom) - font_sz * 0.5
		lw: f32 = 0.0
		if row.label != nil {
			lw = im.CalcTextSize(row.label).x * cv.zoom
			im.DrawList_AddTextImFontPtr(dl, font, font_sz, im.Vec2{rmin.x + pad, y}, label_col, row.label)
		}
		if row.value != nil {
			vw := im.CalcTextSize(row.value).x * cv.zoom
			vx := max(rmin.x + pad + lw + 14.0 * cv.zoom, rmax.x - pad - vw)
			im.DrawList_AddTextImFontPtr(dl, font, font_sz, im.Vec2{vx, y}, value_col, row.value)
		}
	}

	im.DrawList_PopClipRect(dl)

	for row, i in rows {
		if !row.port do continue
		_port(dl, cv, canvas_port_in(cv, pos^, i), row.col)
	}
	if has_out do _port(dl, cv, canvas_port_out(cv, pos^, out_row, id), PORT_POSE)
}

// Shared Antigravity-clean node card chrome used by both Body Harmonics Graph and Void Material Graph Editor.
canvas_draw_card_chrome :: proc(
	dl: ^im.DrawList,
	rmin, rmax: im.Vec2,
	header_h: f32,
	color: im.Vec4,
	selected: bool,
	hovered: bool = false,
	zoom: f32 = 1.0,
	rounding_base: f32 = 6.0,
) {
	p := thm.palette()
	rounding := rounding_base * zoom
	// Subtle soft drop shadow so cards lift cleanly off the grid
	im.DrawList_AddRectFilled(
		dl,
		rmin + im.Vec2{2, 3} * zoom,
		rmax + im.Vec2{2, 3} * zoom,
		im.GetColorU32ImVec4({0.0, 0.0, 0.0, p.is_light ? 0.10 : 0.32}),
		rounding,
	)

	// Clean elevated card surface (pure white card in daylight, soft obsidian-slate in dark mode)
	body_base := p.is_light ? p.bg_recessed : p.bg_elevated
	body := hovered ? p.bg_hover : body_base
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(body), rounding)

	// Calm tonal header wash tinted by the node's category hue
	hdr_col := thm.lerp_col(body_base, color, p.is_light ? 0.20 : 0.30)
	im.DrawList_AddRectFilled(
		dl,
		rmin,
		im.Vec2{rmax.x, rmin.y + header_h},
		im.GetColorU32ImVec4(hdr_col),
		rounding,
		im.DrawFlags_RoundCornersTop,
	)

	// Crisp 1px divider line beneath the header
	im.DrawList_AddLine(
		dl,
		im.Vec2{rmin.x + 1, rmin.y + header_h},
		im.Vec2{rmax.x - 1, rmin.y + header_h},
		im.GetColorU32ImVec4(thm.lerp_col(p.border_subtle, color, 0.38)),
		1.0 * zoom,
	)

	// Hairline border at rest; crisp accent ring + soft halo when selected
	border := selected ? p.accent : thm.lerp_col(p.border_subtle, color, hovered ? 0.50 : 0.20)
	if selected {
		im.DrawList_AddRect(
			dl,
			rmin - im.Vec2{2.0, 2.0} * zoom,
			rmax + im.Vec2{2.0, 2.0} * zoom,
			im.GetColorU32ImVec4(thm.with_alpha(p.accent, p.is_light ? 0.22 : 0.30)),
			rounding + 2.0 * zoom,
			2.6 * zoom,
		)
	}
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(border), rounding, (selected ? 1.8 : 1.0) * zoom)
}

// Shared port dot renderer with dark outer ring, hover/magnetic glow, and connected/unconnected indicator.
canvas_draw_port :: proc(
	dl: ^im.DrawList,
	at: im.Vec2,
	col: im.Vec4,
	hovered: bool = false,
	magnetic: bool = false,
	connected: bool = true,
	zoom: f32 = 1.0,
) {
	c := col
	if c.w == 0 do c = PORT_POSE
	r := (hovered || magnetic ? (CANVAS_PORT_R + 1.5) : CANVAS_PORT_R) * zoom

	if hovered || magnetic {
		im.DrawList_AddCircleFilled(dl, at, r + 3.5 * zoom, im.GetColorU32ImVec4(_tint(c, 0.4, 0.32)))
	}
	im.DrawList_AddCircleFilled(dl, at, r, im.GetColorU32ImVec4(c))
	if !connected && !hovered && !magnetic {
		// Subtle dark inner core for unconnected pins while keeping the bright colored ring
		im.DrawList_AddCircleFilled(dl, at, max(r * 0.45, 1.5), im.GetColorU32ImVec4(_scale(c, 0.25, 0.95)))
	}
	im.DrawList_AddCircle(
		dl,
		at,
		r,
		hovered || magnetic ? im.GetColorU32ImVec4({1, 1, 1, 0.95}) : im.GetColorU32ImVec4(_scale(c, 0.28, 1.0)),
		0,
		(hovered || magnetic ? 1.8 : 1.3) * zoom,
	)
}

// A port dot with a dark ring, so it stays visible against both the node body
// and the canvas behind it.
@(private = "file")
_port :: proc(dl: ^im.DrawList, cv: ^Node_Canvas, at: im.Vec2, col: im.Vec4) {
	canvas_draw_port(dl, at, col, false, false, true, cv.zoom)
}

// Shared Comment Box chrome used by both Material Graph Editor and Faker State Machine Graph.
canvas_draw_comment_box :: proc(
	dl: ^im.DrawList,
	bmin, bmax: im.Vec2,
	header_h: f32,
	color: im.Vec4,
	title: cstring,
	selected: bool,
	zoom: f32 = 1.0,
) {
	p := thm.palette()
	rounding := 6.0 * zoom
	fill_col := im.Vec4{color.x, color.y, color.z, clamp(color.w, 0.08, 0.22)}
	hdr_col  := thm.lerp_col(p.bg_elevated, im.Vec4{color.x, color.y, color.z, 1.0}, p.is_light ? 0.24 : 0.34)
	brd_col  := selected ? p.accent : thm.lerp_col(p.border_strong, im.Vec4{color.x, color.y, color.z, 1.0}, 0.45)

	im.DrawList_AddRectFilled(dl, bmin, bmax, im.GetColorU32ImVec4(fill_col), rounding)
	im.DrawList_AddRectFilled(dl, bmin, {bmax.x, bmin.y + header_h}, im.GetColorU32ImVec4(hdr_col), rounding, im.DrawFlags_RoundCornersTop)
	if selected {
		im.DrawList_AddRect(dl, bmin - im.Vec2{2, 2} * zoom, bmax + im.Vec2{2, 2} * zoom, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.26)), rounding + 2 * zoom, 2.2 * zoom)
	}
	im.DrawList_AddRect(dl, bmin, bmax, im.GetColorU32ImVec4(brd_col), rounding, (selected ? 1.8 : 1.0) * zoom)

	if title != nil {
		im.DrawList_AddText(dl, {bmin.x + 10 * zoom, bmin.y + (header_h - im.GetFontSize()) * 0.5}, im.GetColorU32ImVec4(p.text_primary), title)
	}
	// Resize grip lines in bottom-right corner
	im.DrawList_AddLine(dl, {bmax.x - 12 * zoom, bmax.y - 3 * zoom}, {bmax.x - 3 * zoom, bmax.y - 12 * zoom}, im.GetColorU32ImVec4(brd_col), 1.5)
	im.DrawList_AddLine(dl, {bmax.x - 7 * zoom,  bmax.y - 3 * zoom}, {bmax.x - 3 * zoom, bmax.y - 7 * zoom},  im.GetColorU32ImVec4(brd_col), 1.5)
}

// Spawns a new interactive Comment Box on `cv` (wrapping the given position/size).
canvas_spawn_comment :: proc(cv: ^Node_Canvas, pos: im.Vec2, size: im.Vec2 = {320, 190}, title: string = "Comment Group") {
	if cv == nil do return
	for &c in cv.comments {
		if !c.active {
			c.active = true
			c.pos    = pos
			c.size   = {max(size.x, 180.0), max(size.y, 110.0)}
			c.color  = {0.26, 0.52, 0.78, 0.18}
			c.title_buf = {}
			n_copy := min(len(title), len(c.title_buf) - 1)
			for i in 0 ..< n_copy {
				c.title_buf[i] = title[i]
			}
			return
		}
	}
}

// Spawns a Comment Box that automatically wraps all currently selected nodes in `node_positions`
// (or spawns at the cursor/center if no nodes are selected).
canvas_spawn_comment_for_selection :: proc(
	cv: ^Node_Canvas,
	node_positions: []im.Vec2 = nil,
	base_node_id: int = 0,
	title: string = "Comment Group",
) {
	if cv == nil do return
	zm := max(cv.zoom, 0.25)

	if node_positions != nil && len(node_positions) > 0 {
		found := false
		bmin := im.Vec2{ 1e9,  1e9}
		bmax := im.Vec2{-1e9, -1e9}
		for np, idx in node_positions {
			if canvas_is_selected(cv, base_node_id + idx) {
				node_sz := canvas_get_node_size(cv, base_node_id + idx, canvas_node_size(4))
				found = true
				bmin.x = min(bmin.x, np.x)
				bmin.y = min(bmin.y, np.y)
				bmax.x = max(bmax.x, np.x + node_sz.x)
				bmax.y = max(bmax.y, np.y + node_sz.y)
			}
		}
		if found {
			pos := im.Vec2{bmin.x - 22.0, bmin.y - 38.0}
			sz  := im.Vec2{max((bmax.x - bmin.x) + 44.0, 240.0), max((bmax.y - bmin.y) + 56.0, 150.0)}
			canvas_spawn_comment(cv, pos, sz, title)
			return
		}
	}

	io := im.GetIO()
	if io.MousePos.x >= cv.origin.x && io.MousePos.x <= cv.origin.x + cv.size.x &&
	   io.MousePos.y >= cv.origin.y && io.MousePos.y <= cv.origin.y + cv.size.y {
		spawn_pos := (io.MousePos - cv.origin) / zm - cv.pan - im.Vec2{40, 28}
		canvas_spawn_comment(cv, spawn_pos, {320, 190}, title)
	} else {
		center_world := (cv.size * 0.5) / zm - cv.pan - im.Vec2{160, 90}
		canvas_spawn_comment(cv, center_world, {340, 190}, title)
	}
}

// Draws and handles interactive dragging/resizing/editing of Comment Boxes on `cv`
// (plus the `C` keyboard shortcut to spawn a Comment Box wrapping selected nodes or at the cursor).
// Dragging a Comment Box header automatically moves all node positions in `node_positions` enclosed inside it!
canvas_update_and_draw_comments :: proc(cv: ^Node_Canvas, node_positions: []im.Vec2 = nil, base_node_id: int = 0) {
	if cv == nil do return
	dl := im.GetWindowDrawList()
	io := im.GetIO()
	zm := max(cv.zoom, 0.25)

	// Press `C` when hovering canvas (and not typing in a text widget) to spawn a Comment Box wrapping selected nodes!
	if im.IsWindowHovered(im.HoveredFlags_ChildWindows) && !io.WantTextInput && im.IsKeyPressed(.C, false) {
		canvas_spawn_comment_for_selection(cv, node_positions, base_node_id, "Comment Group")
	}

	for &c, c_idx in cv.comments {
		if !c.active do continue
		im.PushIDInt(i32(9000 + c_idx))
		sp    := canvas_to_screen(cv, c.pos)
		bsz   := im.Vec2{max(c.size.x, 180.0), max(c.size.y, 110.0)}
		sz    := bsz * zm
		hdr_h := 26.0 * zm
		is_sel := cv.sel == (9000 + c_idx)

		// 1. Header Drag Handle FIRST so `sp` updates before drawing (zero 1-frame lag!)
		drag_x0 := sp.x + max(sz.x - 105.0 * zm, 76.0)
		im.SetCursorScreenPos({drag_x0, sp.y})
		im.InvisibleButton("##nc_cmt_hdr_drag", {max(54.0 * zm, 24.0), max(hdr_h, 1.0)})
		if im.IsItemClicked(.Left) {
			cv.sel = 9000 + c_idx
			is_sel = true
		}
		if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
			delta := io.MouseDelta / zm
			old_min := c.pos
			old_max := c.pos + bsz
			c.pos += delta
			sp = canvas_to_screen(cv, c.pos)
			for &np, n_i in node_positions {
				nsz := canvas_get_node_size(cv, base_node_id + n_i, canvas_node_size(4))
				nc_center := np + nsz * 0.5
				if nc_center.x >= old_min.x && nc_center.x <= old_max.x &&
				   nc_center.y >= old_min.y && nc_center.y <= old_max.y {
					np += delta
				}
			}
		}

		// 2. Bottom-Right Resize Grip
		grip_sz := max(16.0 * zm, 1.0)
		im.SetCursorScreenPos({sp.x + sz.x - grip_sz, sp.y + sz.y - grip_sz})
		im.InvisibleButton("##nc_cmt_resize", {grip_sz, grip_sz})
		if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
			c.size.x = max(c.size.x + io.MouseDelta.x / zm, 180.0)
			c.size.y = max(c.size.y + io.MouseDelta.y / zm, 110.0)
			bsz = c.size
			sz  = bsz * zm
		}

		// 3. Draw Comment Box Frame
		canvas_draw_comment_box(dl, sp, sp + sz, hdr_h, c.color, nil, is_sel, zm)

		// 4. Editable Title, Color Swatch & Delete `[X]` Button
		im.SetCursorScreenPos({sp.x + 8.0 * zm, sp.y + 3.0 * zm})
		im.PushItemWidth(max(sz.x - 115.0 * zm, 68.0))
		_ = im.InputText("##nc_cmt_title", cstring(&c.title_buf[0]), len(c.title_buf))
		im.PopItemWidth()

		im.SetCursorScreenPos({sp.x + sz.x - 46.0 * zm, sp.y + 3.0 * zm})
		_ = im.ColorEdit4("##nc_cmt_col", &c.color, {.NoInputs, .NoLabel})

		im.SetCursorScreenPos({sp.x + sz.x - 22.0 * zm, sp.y + 3.0 * zm})
		if im.SmallButton("X") {
			c.active = false
		}
		im.PopID()
	}
}

// Shared Marquee selection rectangle.
canvas_draw_marquee :: proc(dl: ^im.DrawList, m_min, m_max: im.Vec2) {
	p := thm.palette()
	im.DrawList_AddRectFilled(dl, m_min, m_max, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.14)), 4.0)
	im.DrawList_AddRect(dl, m_min, m_max, im.GetColorU32ImVec4(thm.with_alpha(p.accent, 0.85)), 4.0, 1.2)
}

// Evaluates point along a 4-segment Electronic 45-degree polyline for t in [0..1]
@(private = "file")
_electronic_45_pts :: proc(p1, p2: im.Vec2) -> [4]im.Vec2 {
	dx := p2.x - p1.x
	dy := p2.y - p1.y
	abs_dy := abs(dy)
	stub := clamp(abs(dx) * 0.25, 16.0, 48.0)
	diag := min(abs_dy * 0.5, max((abs(dx) - stub * 2.0) * 0.45, 0.0))
	sign_x: f32 = dx >= 0.0 ? 1.0 : -1.0
	k1 := im.Vec2{p1.x + sign_x * (stub + max(0.0, (abs(dx) * 0.5 - stub - diag))), p1.y}
	k2 := im.Vec2{p2.x - sign_x * (stub + max(0.0, (abs(dx) * 0.5 - stub - diag))), p2.y}
	return {p1, k1, k2, p2}
}

@(private = "file")
_orthogonal_90_pts :: proc(p1, p2: im.Vec2) -> [4]im.Vec2 {
	mid_x := (p1.x + p2.x) * 0.5
	if p2.x < p1.x + 24.0 {
		mid_x = p1.x + 24.0
	}
	return {p1, {mid_x, p1.y}, {mid_x, p2.y}, p2}
}

@(private = "file")
_seg_dist :: proc(pt, a, b: im.Vec2) -> f32 {
	ab := b - a
	len_sq := ab.x * ab.x + ab.y * ab.y
	if len_sq < 0.0001 {
		d := pt - a
		return math.hypot(d.x, d.y)
	}
	t := clamp(((pt.x - a.x) * ab.x + (pt.y - a.y) * ab.y) / len_sq, 0.0, 1.0)
	proj := a + ab * t
	d := pt - proj
	return math.hypot(d.x, d.y)
}

// Minimum screen distance from `pt` to the routed wire curve/polyline between `from` and `to`.
canvas_dist_point_to_wire :: proc(pt, from, to: im.Vec2, style: Canvas_Wire_Style, zoom: f32) -> f32 {
	zm := max(zoom, 0.25)
	switch style {
	case .Electronic_45:
		pts := _electronic_45_pts(from, to)
		best := f32(1e9)
		for s in 0 ..< 3 {
			best = min(best, _seg_dist(pt, pts[s], pts[s + 1]))
		}
		return best
	case .Orthogonal_90:
		pts := _orthogonal_90_pts(from, to)
		best := f32(1e9)
		for s in 0 ..< 3 {
			best = min(best, _seg_dist(pt, pts[s], pts[s + 1]))
		}
		return best
	case .Electric_Jagged:
		return _seg_dist(pt, from, to)
	case .Smooth_Bezier:
		d := clamp(abs(to.x - from.x) * 0.5, 30 * zm, 120 * zm)
		c1 := from + im.Vec2{d, 0}
		c2 := to - im.Vec2{d, 0}
		best := f32(1e9)
		prev := from
		for s in 1 ..= 8 {
			cur := _bezier(from, c1, c2, to, f32(s) / 8.0)
			best = min(best, _seg_dist(pt, prev, cur))
			prev = cur
		}
		return best
	}
	return _seg_dist(pt, from, to)
}

@(private = "file")
_sample_polyline4 :: proc(pts: [4]im.Vec2, t: f32) -> im.Vec2 {
	l0 := math.hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
	l1 := math.hypot(pts[2].x - pts[1].x, pts[2].y - pts[1].y)
	l2 := math.hypot(pts[3].x - pts[2].x, pts[3].y - pts[2].y)
	tot := max(l0 + l1 + l2, 0.001)
	d := clamp(t, 0.0, 1.0) * tot
	if d <= l0 {
		u := l0 > 0.0001 ? d / l0 : 0.0
		return pts[0] + (pts[1] - pts[0]) * u
	}
	d -= l0
	if d <= l1 {
		u := l1 > 0.0001 ? d / l1 : 0.0
		return pts[1] + (pts[2] - pts[1]) * u
	}
	d -= l1
	u := l2 > 0.0001 ? d / l2 : 0.0
	return pts[2] + (pts[3] - pts[2]) * u
}

// Unified wire renderer supporting Smooth Bezier, Electronic 45-degree, and Electric Jagged
// styles, soft glow halo, animated flow beads, and optional pill-backed midpoint label.
canvas_draw_wire :: proc(
	dl: ^im.DrawList,
	from, to: im.Vec2,
	col: u32,
	style: Canvas_Wire_Style = .Smooth_Bezier,
	thickness: f32 = 2.0,
	flow: f32 = 0.0,
	zoom: f32 = 1.0,
	label: cstring = nil,
	draw_arrow: bool = false,
) {
	th := thickness * zoom
	halo_col := (col & 0x00FFFFFF) | (u32(46) << 24)

	d := clamp(abs(to.x - from.x) * 0.5, 30 * zoom, 120 * zoom)
	c1 := from + im.Vec2{d, 0}
	c2 := to - im.Vec2{d, 0}
	e_pts := _electronic_45_pts(from, to)
	o_pts := _orthogonal_90_pts(from, to)

	switch style {
	case .Smooth_Bezier:
		im.DrawList_AddBezierCubic(dl, from, c1, c2, to, halo_col, th + 3.2 * zoom)
		im.DrawList_AddBezierCubic(dl, from, c1, c2, to, col, th)
	case .Electronic_45:
		for s in 0 ..< 3 {
			im.DrawList_AddLine(dl, e_pts[s], e_pts[s + 1], halo_col, th + 3.2 * zoom)
			im.DrawList_AddLine(dl, e_pts[s], e_pts[s + 1], col, th)
		}
		im.DrawList_AddCircleFilled(dl, e_pts[1], th * 0.85, col)
		im.DrawList_AddCircleFilled(dl, e_pts[2], th * 0.85, col)
	case .Orthogonal_90:
		for s in 0 ..< 3 {
			im.DrawList_AddLine(dl, o_pts[s], o_pts[s + 1], halo_col, th + 3.2 * zoom)
			im.DrawList_AddLine(dl, o_pts[s], o_pts[s + 1], col, th)
		}
		im.DrawList_AddCircleFilled(dl, o_pts[1], th * 0.80, col)
		im.DrawList_AddCircleFilled(dl, o_pts[2], th * 0.80, col)
	case .Electric_Jagged:
		segments :: 14
		prev_pt := from
		t_sec := f32(im.GetTime())
		dx := to.x - from.x
		dy := to.y - from.y
		len_w := max(math.sqrt(dx * dx + dy * dy), 1.0)
		nx := -dy / len_w
		ny :=  dx / len_w
		for s := 1; s <= segments; s += 1 {
			t := f32(s) / f32(segments)
			bx := from.x + dx * t
			by := from.y + dy * t
			if s < segments {
				envelope := math.sin(t * math.PI)
				jitter := (math.sin(t * 37.0 + t_sec * 24.0 + from.x * 0.13) * 0.65 +
				           math.cos(t * 73.0 - t_sec * 39.0 + from.y * 0.17) * 0.35) * 8.5 * envelope * zoom
				bx += nx * jitter
				by += ny * jitter
			}
			next_pt := im.Vec2{bx, by}
			im.DrawList_AddLine(dl, prev_pt, next_pt, halo_col, th + 4.0 * zoom)
			im.DrawList_AddLine(dl, prev_pt, next_pt, col, th)
			prev_pt = next_pt
		}
	}

	if draw_arrow {
		// Compute incoming direction right at `to` so arrowhead aligns with Bezier/45-deg/90-deg stub
		prev := style == .Electronic_45 ? _sample_polyline4(e_pts, 0.92) : (style == .Orthogonal_90 ? _sample_polyline4(o_pts, 0.92) : _bezier(from, c1, c2, to, 0.92))
		dir := to - prev
		dl_len := math.hypot(dir.x, dir.y)
		if dl_len < 0.001 {
			dir = {1.0, 0.0}
		} else {
			dir /= dl_len
		}
		perp := im.Vec2{-dir.y, dir.x}
		arrow_len := 9.5 * zoom
		arrow_hw  := 4.8 * zoom
		tip := to
		b1  := to - dir * arrow_len + perp * arrow_hw
		b2  := to - dir * arrow_len - perp * arrow_hw
		im.DrawList_AddTriangleFilled(dl, tip, b1, b2, col)
	}

	if flow > 0.001 {
		span := max(abs(to.x - from.x), abs(to.y - from.y))
		n := clamp(int(span / (BEAD_SPACING * zoom)), 2, 10)
		phase := f32(math.mod(im.GetTime() * f64((0.25 + 0.75 * flow) * BEAD_SPEED), 1))
		r := (thickness + 0.8) * zoom
		bead := (col & 0x00FFFFFF) | (u32(clamp(105 + 150 * flow, 0, 255)) << 24)
		bead_halo := (col & 0x00FFFFFF) | (u32(clamp(45 + 70 * flow, 0, 255)) << 24)
		for i in 0 ..< n {
			t := math.mod(phase + f32(i) / f32(n), 1)
			pt: im.Vec2
			switch style {
			case .Smooth_Bezier:
				pt = _bezier(from, c1, c2, to, t)
			case .Electronic_45:
				pt = _sample_polyline4(e_pts, t)
			case .Orthogonal_90:
				pt = _sample_polyline4(o_pts, t)
			case .Electric_Jagged:
				pt = from + (to - from) * t
			}
			im.DrawList_AddCircleFilled(dl, pt, r + 2.0 * zoom, bead_halo)
			im.DrawList_AddCircleFilled(dl, pt, r, bead)
		}
	}

	if label != nil {
		p := thm.palette()
		mid := style == .Electronic_45 ? _sample_polyline4(e_pts, 0.5) : (style == .Orthogonal_90 ? _sample_polyline4(o_pts, 0.5) : _bezier(from, c1, c2, to, 0.5))
		font_sz := max(im.GetFontSize() * zoom * 0.9, 7)
		ts := im.CalcTextSize(label) * (font_sz / max(im.GetFontSize(), 1.0))
		lpos := mid + im.Vec2{-ts.x * 0.5, -font_sz - 4 * zoom}
		p_min := lpos - im.Vec2{5, 2} * zoom
		p_max := lpos + ts + im.Vec2{5, 2} * zoom
		im.DrawList_AddRectFilled(dl, p_min, p_max, im.GetColorU32ImVec4(p.bg_popup), 4.0 * zoom)
		im.DrawList_AddRect(dl, p_min, p_max, im.GetColorU32ImVec4(p.border_subtle), 4.0 * zoom, 1.0)
		im.DrawList_AddTextImFontPtr(dl, im.GetFont(), font_sz, lpos, im.GetColorU32ImVec4(p.text_primary), label)
	}
}

// Bezier/Electronic/Electric edge between two port positions (screen coords).
canvas_link :: proc(
	cv: ^Node_Canvas,
	from, to: im.Vec2,
	col: u32,
	thickness: f32 = 1.5,
	flow: f32 = 0,
	label: cstring = nil,
	draw_arrow: bool = false,
) {
	dl := im.GetWindowDrawList()
	canvas_draw_wire(dl, from, to, col, cv.wire_style, thickness, flow, cv.zoom, label, draw_arrow)
}

// Screen pixels between flowing beads at zoom 1.
BEAD_SPACING :: f32(26)
// Bead travel, in edge-lengths per second at full weight.
BEAD_SPEED :: f32(0.75)

@(private = "file")
_bezier :: proc(p0, p1, p2, p3: im.Vec2, t: f32) -> im.Vec2 {
	u := 1 - t
	return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
}

// Multiplies a colour toward black, for a muted fill of the same hue.
@(private = "file")
_scale :: proc(c: im.Vec4, f: f32, a: f32) -> im.Vec4 {
	return im.Vec4{c.x * f, c.y * f, c.z * f, a}
}

// Mixes a colour toward white, for a bright border of the same hue.
@(private = "file")
_tint :: proc(c: im.Vec4, t: f32, a: f32 = 1) -> im.Vec4 {
	return im.Vec4{c.x + (1 - c.x) * t, c.y + (1 - c.y) * t, c.z + (1 - c.z) * t, a}
}
