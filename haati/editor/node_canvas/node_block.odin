package node_canvas

// Haati Auto-Sizing Node Blocks for `Node_Canvas`.
//
// Unlike fixed-size property cards that clip titles or collide labels with values,
// a Haati Node Block dynamically sizes both its width and height to fit its
// header, badges, telemetry rows, and inline interactive ImGui controls (combos,
// sliders, checkboxes, buttons). Lightweight nodes stay compact; rich nodes expand
// cleanly into titled parameter sections, and any block can be collapsed (`v`/`>`)
// down to its header + pin strip while keeping its wires anchored in place.

import im "haati:external/odin-imgui"
import "haati:editor/icons"
import thm "haati:editor/theme"
import widgets "haati:editor/widgets"

NODE_HEADER_H    :: f32(28.0)
NODE_PIN_STRIP_H :: f32(22.0)
NODE_PAD_X       :: f32(10.0)
NODE_PAD_BOTTOM  :: f32(9.0)
NODE_PIN_Y       :: NODE_HEADER_H + NODE_PIN_STRIP_H * 0.5

Node_Block_Spec :: struct {
	id:                 int,
	title:              cstring,
	category:           cstring, // optional short module tag (e.g. "DUAL BASE", "FAKER GAS")
	step_badge:         cstring, // optional topological badge (e.g. "#1", "OFF", "ACTIVE")
	color:              im.Vec4, // category accent hue
	min_width:          f32,     // minimum canvas-unit width (defaults to 256 if <= 0)
	label_col_width:    f32,     // canvas-unit parameter label column width (defaults to 102 if <= 0)
	ctrl_col_width:     f32,     // canvas-unit parameter widget column width (defaults to 146 if <= 0)
	enabled_ptr:        ^bool,   // optional header `[check]` module enable/bypass toggle
	has_code_btn:       bool,    // optional `</>` quick Odin code inspector button in header
	in_label:           cstring, // left pin strip label (e.g. "Exec In")
	out_label:          cstring, // right pin strip status/label (e.g. "LINKED -> Out")
	has_in_port:        bool,
	has_out_port:       bool,
	in_connected:       bool,
	port_col:           im.Vec4,
	all_node_positions: []im.Vec2,
	base_node_id:       int,
}

Node_Block_Ctx :: struct {
	cv:                    ^Node_Canvas,
	dl:                    ^im.DrawList,
	spec:                  Node_Block_Spec,
	rmin:                  im.Vec2,
	zm:                    f32,
	hdr_h:                 f32,
	pin_h:                 f32,
	pad_x:                 f32,
	min_w_canvas:          f32,
	hdr_req_w_screen:      f32,
	pin_req_w_screen:      f32,
	est_w_screen:          f32,
	visual_inner_w:        f32,
	intrinsic_body_w:      f32,
	label_col_w_screen:    f32,
	ctrl_col_w_screen:     f32,
	selected:              bool,
	collapsed:             bool,
	enabled_val:           bool,
	body_open:             bool,
	toggled_enable:        bool,
	clicked_code:          bool,
	double_clicked_header: bool,
	header_drag_hovered:   bool,
}

// Screen-space input port position on a Haati Node Block's pin strip (invariant when collapsed).
canvas_node_port_in :: proc(cv: ^Node_Canvas, pos: im.Vec2, row: int = 0) -> im.Vec2 {
	return canvas_to_screen(cv, im.Vec2{pos.x, pos.y + NODE_PIN_Y + f32(row) * 20.0})
}

// Screen-space output port position on the right edge of a Haati Node Block's dynamically measured width.
canvas_node_port_out :: proc(cv: ^Node_Canvas, pos: im.Vec2, id: int, fallback_w: f32 = 276.0, row: int = 0) -> im.Vec2 {
	w := canvas_get_node_size(cv, id, {fallback_w, 64.0}).x
	return canvas_to_screen(cv, im.Vec2{pos.x + w, pos.y + NODE_PIN_Y + f32(row) * 20.0})
}

// Opens an auto-sizing Haati Node-style module block. Always pair with `canvas_node_block_end(&b)`!
// Returns `b.body_open` (`true` when expanded so the caller should emit inline sections, KV rows, and controls).
canvas_node_block_begin :: proc(
	cv: ^Node_Canvas,
	pos: ^im.Vec2,
	spec: Node_Block_Spec,
) -> (b: Node_Block_Ctx, body_open: bool) {
	p  := thm.palette()
	dl := im.GetWindowDrawList()
	io := im.GetIO()
	zm := clamp(cv.zoom, CANVAS_ZOOM_MIN, CANVAS_ZOOM_MAX)
	st := im.GetStyle()

	im.PushIDInt(i32(spec.id))
	im.PushFontFloat(nil, clamp(st.FontSizeBase * zm, 8.0, 38.0))
	im.PushStyleVarImVec2(.FramePadding,     {6.0 * zm, 3.0 * zm})
	im.PushStyleVarImVec2(.ItemSpacing,      {6.0 * zm, 4.0 * zm})
	im.PushStyleVarImVec2(.ItemInnerSpacing, {5.0 * zm, 3.0 * zm})
	im.PushStyleVar(.FrameRounding,          4.0 * zm)

	// Recessed Haati Node dark/light field wells inside module cards
	well_bg  := p.is_light ? thm.lerp_col(p.bg_canvas, {0, 0, 0, 1}, 0.04) : thm.lerp_col(p.bg_canvas, {0, 0, 0, 1}, 0.25)
	well_hov := thm.lerp_col(well_bg, spec.color, 0.22)
	well_act := thm.lerp_col(well_bg, spec.color, 0.34)
	im.PushStyleColorImVec4(.FrameBg,        well_bg)
	im.PushStyleColorImVec4(.FrameBgHovered, well_hov)
	im.PushStyleColorImVec4(.FrameBgActive,  well_act)

	min_w_c   := spec.min_width       > 0.0 ? spec.min_width       : 264.0
	lbl_col_c := spec.label_col_width > 0.0 ? spec.label_col_width : 104.0
	ctl_col_c := spec.ctrl_col_width  > 0.0 ? spec.ctrl_col_width  : 148.0
	min_w_c    = max(min_w_c, lbl_col_c + ctl_col_c + NODE_PAD_X * 2 + 8.0)

	hdr_h := NODE_HEADER_H * zm
	pin_h := (spec.in_label != nil || spec.out_label != nil || spec.has_in_port || spec.has_out_port) ? (NODE_PIN_STRIP_H * zm) : 0.0
	pad_x := NODE_PAD_X * zm

	enabled_val := spec.enabled_ptr != nil ? spec.enabled_ptr^ : true
	collapsed   := canvas_is_collapsed(cv, spec.id)
	selected    := canvas_is_selected(cv, spec.id)

	// Measure exact header & pin-strip intrinsic widths so titles/badges NEVER clip!
	left_chk_w:  f32 = spec.enabled_ptr != nil ? (22.0 * zm) : 0.0
	badge_w:     f32 = spec.step_badge  != nil ? (im.CalcTextSize(spec.step_badge).x + 12.0 * zm) : 0.0
	title_w:     f32 = spec.title       != nil ? im.CalcTextSize(spec.title).x : 0.0
	cat_w:       f32 = spec.category    != nil ? (im.CalcTextSize(spec.category).x + 12.0 * zm) : 0.0
	code_btn_w:  f32 = spec.has_code_btn       ? (24.0 * zm) : 0.0
	coll_btn_w:  f32 = 22.0 * zm
	right_btns_w := code_btn_w + coll_btn_w + (spec.has_code_btn ? 4.0 * zm : 0.0)

	hdr_req_w := pad_x * 2 + left_chk_w + badge_w + title_w + 18.0 * zm + cat_w + right_btns_w
	in_lbl_w:  f32 = spec.in_label  != nil ? im.CalcTextSize(spec.in_label).x  : 0.0
	out_lbl_w: f32 = spec.out_label != nil ? im.CalcTextSize(spec.out_label).x : 0.0
	pin_req_w: f32 = pin_h > 0.0 ? (in_lbl_w + out_lbl_w + 38.0 * zm) : 0.0

	prev_w_screen := canvas_get_node_size(cv, spec.id, {min_w_c, 64.0}).x * zm
	est_w_screen  := max(min_w_c * zm, max(prev_w_screen, max(hdr_req_w, pin_req_w)))

	rmin := canvas_to_screen(cv, pos^)

	// 1. Header Drag Handle FIRST (reserving left checkbox & right action buttons so they click cleanly!)
	drag_x0 := rmin.x + (left_chk_w > 0.0 ? (pad_x + left_chk_w) : 0.0)
	drag_x1 := rmin.x + est_w_screen - pad_x - right_btns_w
	drag_w  := max(drag_x1 - drag_x0, 24.0 * zm)

	im.SetCursorScreenPos({drag_x0, rmin.y})
	im.InvisibleButton("##node_hdr_drag", {drag_w, hdr_h})
	hdr_drag_hov := im.IsItemHovered()
	if im.IsItemClicked(.Left) && !cv.suppress_node_drag {
		if io.KeyCtrl || io.KeyShift {
			canvas_set_selected(cv, spec.id, !canvas_is_selected(cv, spec.id))
		} else if !canvas_is_selected(cv, spec.id) {
			canvas_clear_selection(cv)
			canvas_set_selected(cv, spec.id, true)
		} else {
			cv.sel = spec.id
		}
		selected = canvas_is_selected(cv, spec.id)
	}
	double_clicked := im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) && !cv.suppress_node_drag

	if !cv.suppress_node_drag && im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
		delta := io.MouseDelta / zm
		if spec.all_node_positions != nil && canvas_is_selected(cv, spec.id) && canvas_selected_count(cv) > 1 {
			for &np, idx in spec.all_node_positions {
				if canvas_is_selected(cv, spec.base_node_id + idx) {
					np += delta
				}
			}
		} else {
			pos^ += delta
		}
		// Zero-lag same-frame screen anchor update!
		rmin = canvas_to_screen(cv, pos^)
	}

	// 2. Split DrawList into Background Chrome (Channel 0) & Foreground Content/Widgets (Channel 1)
	im.DrawList_ChannelsSplit(dl, 2)
	im.DrawList_ChannelsSetCurrent(dl, 1)

	font_h   := im.GetFontSize()
	text_y   := rmin.y + (hdr_h - font_h) * 0.5
	cur_hx   := rmin.x + pad_x
	toggled  := false
	clk_code := false

	// Optional Haati Node `[check]` Module Enable / Bypass Pill in Header
	if spec.enabled_ptr != nil {
		chk_sz := 16.0 * zm
		chk_p0 := im.Vec2{cur_hx, rmin.y + (hdr_h - chk_sz) * 0.5}
		im.SetCursorScreenPos(chk_p0)
		if im.InvisibleButton("##node_en_chk", {chk_sz, chk_sz}) {
			spec.enabled_ptr^ = !spec.enabled_ptr^
			enabled_val       = spec.enabled_ptr^
			toggled           = true
		}
		chk_hov := im.IsItemHovered()
		widgets.tooltip("Enable or Bypass this solver module")
		chk_bg  := enabled_val ? thm.with_alpha(spec.color, 0.88) : thm.with_alpha(p.bg_canvas, 0.75)
		chk_brd := chk_hov ? im.Vec4{1, 1, 1, 0.95} : thm.with_alpha(p.text_primary, 0.55)
		im.DrawList_AddRectFilled(dl, chk_p0, chk_p0 + {chk_sz, chk_sz}, im.GetColorU32ImVec4(chk_bg), 3.5 * zm)
		im.DrawList_AddRect(dl, chk_p0, chk_p0 + {chk_sz, chk_sz}, im.GetColorU32ImVec4(chk_brd), 3.5 * zm, 1.1 * zm)
		if enabled_val {
			ck_w := im.CalcTextSize(icons.ICON_MD_CHECK).x
			im.DrawList_AddText(dl, {chk_p0.x + (chk_sz - ck_w) * 0.5, rmin.y + (hdr_h - font_h) * 0.5}, im.GetColorU32ImVec4({1, 1, 1, 1}), icons.ICON_MD_CHECK)
		}
		cur_hx += left_chk_w
	}

	// Optional Execution Step / State Badge Pill (`#1`, `ACTIVE`, `OFF`)
	if spec.step_badge != nil {
		bt_sz  := im.CalcTextSize(spec.step_badge)
		bp_min := im.Vec2{cur_hx, rmin.y + (hdr_h - (bt_sz.y + 4.0 * zm)) * 0.5}
		bp_max := im.Vec2{cur_hx + bt_sz.x + 8.0 * zm, bp_min.y + bt_sz.y + 4.0 * zm}
		im.DrawList_AddRectFilled(dl, bp_min, bp_max, im.GetColorU32ImVec4(thm.with_alpha(p.bg_canvas, p.is_light ? 0.65 : 0.55)), 4.0 * zm)
		im.DrawList_AddRect(dl, bp_min, bp_max, im.GetColorU32ImVec4(thm.with_alpha(spec.color, 0.65)), 4.0 * zm, 1.0 * zm)
		im.DrawList_AddText(dl, {bp_min.x + 4.0 * zm, text_y}, im.GetColorU32ImVec4(enabled_val ? p.text_primary : p.text_muted), spec.step_badge)
		cur_hx = bp_max.x + 6.0 * zm
	}

	// Unclipped Module Title
	if spec.title != nil {
		t_col := enabled_val ? p.text_primary : p.text_muted
		im.DrawList_AddText(dl, {cur_hx, text_y}, im.GetColorU32ImVec4(t_col), spec.title)
	}

	// Right-Aligned Header Cluster: Category Tag + `</>` Code Button + `v`/`>` Collapse Button
	rx := rmin.x + est_w_screen - pad_x

	// Collapse / Expand Button (`v` / `>`)
	btn_h  := 18.0 * zm
	btn_y  := rmin.y + (hdr_h - btn_h) * 0.5
	coll_x := rx - 18.0 * zm
	im.SetCursorScreenPos({coll_x, btn_y})
	if im.InvisibleButton("##node_collapse", {18.0 * zm, btn_h}) {
		collapsed = !collapsed
		canvas_set_collapsed(cv, spec.id, collapsed)
	}
	coll_hov := im.IsItemHovered()
	widgets.tooltip(collapsed ? "Expand module parameters" : "Collapse module to compact header")
	if coll_hov {
		im.DrawList_AddRectFilled(dl, {coll_x, btn_y}, {coll_x + 18.0 * zm, btn_y + btn_h}, im.GetColorU32ImVec4(thm.with_alpha(p.text_primary, 0.14)), 3.5 * zm)
	}
	chev_ic := collapsed ? cstring(icons.ICON_MD_CHEVRON_RIGHT) : cstring(icons.ICON_MD_EXPAND_MORE)
	chev_w  := im.CalcTextSize(chev_ic).x
	im.DrawList_AddText(dl, {coll_x + (18.0 * zm - chev_w) * 0.5, text_y}, im.GetColorU32ImVec4(coll_hov ? p.text_primary : p.text_secondary), chev_ic)
	rx = coll_x - 4.0 * zm

	// Optional `</>` Quick Odin Code Inspector Button
	if spec.has_code_btn {
		code_w := 22.0 * zm
		code_x := rx - code_w
		im.SetCursorScreenPos({code_x, btn_y})
		if im.InvisibleButton("##node_code_btn", {code_w, btn_h}) {
			clk_code = true
		}
		code_hov := im.IsItemHovered()
		widgets.tooltip("Inspect / Edit Odin Solver Code")
		bg_c := code_hov ? thm.with_alpha(spec.color, 0.42) : thm.with_alpha(p.bg_canvas, 0.45)
		im.DrawList_AddRectFilled(dl, {code_x, btn_y}, {code_x + code_w, btn_y + btn_h}, im.GetColorU32ImVec4(bg_c), 3.5 * zm)
		cd_ic := cstring(icons.ICON_MD_CODE)
		cd_w  := im.CalcTextSize(cd_ic).x
		im.DrawList_AddText(dl, {code_x + (code_w - cd_w) * 0.5, text_y}, im.GetColorU32ImVec4(code_hov ? p.text_primary : p.text_secondary), cd_ic)
		rx = code_x - 6.0 * zm
	}

	// Category Pill Tag
	if spec.category != nil {
		csz := im.CalcTextSize(spec.category)
		cx  := rx - csz.x - 8.0 * zm
		if cx > cur_hx + title_w + 8.0 * zm {
			cp_min := im.Vec2{cx, rmin.y + (hdr_h - (csz.y + 3.0 * zm)) * 0.5}
			cp_max := im.Vec2{rx, cp_min.y + csz.y + 3.0 * zm}
			im.DrawList_AddRectFilled(dl, cp_min, cp_max, im.GetColorU32ImVec4(thm.with_alpha(spec.color, p.is_light ? 0.18 : 0.24)), 3.5 * zm)
			im.DrawList_AddText(dl, {cp_min.x + 4.0 * zm, text_y}, im.GetColorU32ImVec4(p.text_secondary), spec.category)
		}
	}

	// 3. Dedicated Pin / Execution Flow Strip (Always visible even when collapsed!)
	if pin_h > 0.0 {
		py_text := rmin.y + hdr_h + (pin_h - font_h) * 0.5
		if spec.in_label != nil {
			im.DrawList_AddText(dl, {rmin.x + 13.0 * zm, py_text}, im.GetColorU32ImVec4(p.text_secondary), spec.in_label)
		}
		if spec.out_label != nil {
			ow := im.CalcTextSize(spec.out_label).x
			ox := max(rmin.x + 13.0 * zm + in_lbl_w + 16.0 * zm, rmin.x + est_w_screen - 13.0 * zm - ow)
			out_c := enabled_val ? thm.lerp_col(p.text_secondary, spec.color, 0.45) : p.text_muted
			im.DrawList_AddText(dl, {ox, py_text}, im.GetColorU32ImVec4(out_c), spec.out_label)
		}
	}

	vis_inner_w := max(est_w_screen - pad_x * 2.0, (lbl_col_c + ctl_col_c) * zm)

	b = Node_Block_Ctx{
		cv                    = cv,
		dl                    = dl,
		spec                  = spec,
		rmin                  = rmin,
		zm                    = zm,
		hdr_h                 = hdr_h,
		pin_h                 = pin_h,
		pad_x                 = pad_x,
		min_w_canvas          = min_w_c,
		hdr_req_w_screen      = hdr_req_w,
		pin_req_w_screen      = pin_req_w,
		est_w_screen          = est_w_screen,
		visual_inner_w        = vis_inner_w,
		label_col_w_screen    = lbl_col_c * zm,
		ctrl_col_w_screen     = ctl_col_c * zm,
		selected              = selected,
		collapsed             = collapsed,
		enabled_val           = enabled_val,
		body_open             = !collapsed,
		toggled_enable        = toggled,
		clicked_code          = clk_code,
		double_clicked_header = double_clicked,
		header_drag_hovered   = hdr_drag_hov,
	}

	if b.body_open {
		im.SetCursorScreenPos({rmin.x + pad_x, rmin.y + hdr_h + pin_h + 6.0 * zm})
		im.BeginGroup()
		im.PushItemWidth(b.ctrl_col_w_screen)
	}

	return b, b.body_open
}

// Pure deterministic width resolver (never feeds `grp_span_w` back across frames -> 0 oscillation!).
compute_node_block_width :: proc(min_w_screen, hdr_req_w, pin_req_w, intrinsic_body_w, pad_x: f32) -> f32 {
	body_req_w := intrinsic_body_w > 0.0 ? (intrinsic_body_w + pad_x * 2.0) : 0.0
	return max(min_w_screen, max(hdr_req_w, max(pin_req_w, body_req_w)))
}

// Records the exact screen width of a custom body widget row into `b.intrinsic_body_w`.
canvas_node_note_body_width :: proc(b: ^Node_Block_Ctx, item_w_screen: f32) {
	if b != nil {
		b.intrinsic_body_w = max(b.intrinsic_body_w, item_w_screen)
	}
}

// Draws colored body text while measuring its exact pixel width into `b.intrinsic_body_w`
// so wide lines widen the block deterministically on frame 1 with zero 2-frame strobe!
canvas_node_text :: proc(b: ^Node_Block_Ctx, text: cstring, col: im.Vec4) {
	if b == nil || text == nil do return
	tsz := im.CalcTextSize(text)
	b.intrinsic_body_w = max(b.intrinsic_body_w, tsz.x + 8.0 * b.zm)
	im.TextColored(col, "%s", text)
}

// Finalizes auto-sizing measurement, renders the UE5 Node module chrome on Channel 0,
// merges DrawList channels, and renders optional default port dots.
canvas_node_block_end :: proc(b: ^Node_Block_Ctx) {
	measured_h: f32 = b.hdr_h + b.pin_h + 3.0 * b.zm

	if b.body_open {
		im.PopItemWidth()
		im.EndGroup()
		gmax      := im.GetItemRectMax()
		measured_h = max((gmax.y - b.rmin.y) + NODE_PAD_BOTTOM * b.zm, b.hdr_h + b.pin_h + 12.0 * b.zm)
	}

	// Deterministic width from explicit intrinsic measurements ONLY (zero ImGui group-feedback oscillation!).
	raw_w_screen  := compute_node_block_width(b.min_w_canvas * b.zm, b.hdr_req_w_screen, b.pin_req_w_screen, b.intrinsic_body_w, b.pad_x)
	draw_w_screen := raw_w_screen
	rmax          := im.Vec2{b.rmin.x + draw_w_screen, b.rmin.y + measured_h}

	canvas_set_node_size(b.cv, b.spec.id, im.Vec2{raw_w_screen / b.zm, measured_h / b.zm})

	io := im.GetIO()
	card_hovered := io.MousePos.x >= b.rmin.x && io.MousePos.x <= rmax.x &&
	                io.MousePos.y >= b.rmin.y && io.MousePos.y <= rmax.y &&
	                im.IsWindowHovered(im.HoveredFlags_ChildWindows)

	// Clicking anywhere inside the block selects it; Right-Clicking arms context menu on release (unless panned)
	if card_hovered {
		if im.IsMouseClicked(.Left) && !b.cv.suppress_node_drag {
			if !canvas_is_selected(b.cv, b.spec.id) && !io.KeyCtrl && !io.KeyShift {
				canvas_clear_selection(b.cv)
				canvas_set_selected(b.cv, b.spec.id, true)
				b.selected = true
			} else if !io.KeyCtrl && !io.KeyShift {
				b.cv.sel = b.spec.id
			}
		}
		if im.IsMouseClicked(.Right) {
			if !canvas_is_selected(b.cv, b.spec.id) {
				canvas_clear_selection(b.cv)
				canvas_set_selected(b.cv, b.spec.id, true)
				b.selected = true
			} else {
				b.cv.sel = b.spec.id
			}
			b.cv.rmb_pressed_in_canvas = true
			b.cv.rmb_pressed_node_id   = b.spec.id
		}
	}

	// Draw Node module Chrome on Channel 0 (behind all foreground text & ImGui widgets)
	im.DrawList_ChannelsSetCurrent(b.dl, 0)
	canvas_draw_node_chrome(
		b.dl,
		b.rmin,
		rmax,
		b.hdr_h,
		b.pin_h,
		b.spec.color,
		b.selected,
		card_hovered,
		b.enabled_val,
		b.zm,
	)
	im.DrawList_ChannelsMerge(b.dl)

	// Draw Pin Strip Ports on top of the card edge
	pcol := b.spec.port_col.w > 0.0 ? b.spec.port_col : PORT_POSE
	pin_sy := b.rmin.y + NODE_PIN_Y * b.zm
	if b.spec.has_in_port {
		canvas_draw_port(b.dl, {b.rmin.x, pin_sy}, pcol, false, false, b.spec.in_connected, b.zm)
	}
	if b.spec.has_out_port {
		canvas_draw_port(b.dl, {rmax.x, pin_sy}, pcol, false, false, true, b.zm)
	}

	// Reset child cursor to canvas origin so off-screen nodes never perturb child bounds
	im.SetCursorScreenPos(b.cv.origin)

	im.PopStyleColor(3)
	im.PopStyleVar(4)
	im.PopFont()
	im.PopID()
}

// Haati Node Stack / Module Card Chrome
canvas_draw_node_chrome :: proc(
	dl: ^im.DrawList,
	rmin, rmax: im.Vec2,
	hdr_h: f32,
	pin_h: f32,
	color: im.Vec4,
	selected: bool,
	hovered: bool,
	enabled: bool,
	zoom: f32,
) {
	p        := thm.palette()
	rounding := 6.0 * zoom
	accent_c := enabled ? color : im.Vec4{0.42, 0.45, 0.50, 1.0}

	// 1. Soft elevated drop shadow
	im.DrawList_AddRectFilled(
		dl,
		rmin + im.Vec2{2.0, 4.0} * zoom,
		rmax + im.Vec2{2.0, 4.0} * zoom,
		im.GetColorU32ImVec4({0.0, 0.0, 0.0, p.is_light ? 0.12 : 0.38}),
		rounding,
	)

	// 2. Module card body surface
	body_base := p.is_light ? p.bg_recessed : p.bg_elevated
	if !enabled {
		body_base = thm.lerp_col(body_base, p.bg_canvas, 0.45)
	}
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(body_base), rounding)

	// 3. Tonal Node header banner + top 2.5px category stripe
	hdr_fill := thm.lerp_col(body_base, accent_c, p.is_light ? 0.24 : 0.34)
	im.DrawList_AddRectFilled(
		dl,
		rmin,
		{rmax.x, rmin.y + hdr_h},
		im.GetColorU32ImVec4(hdr_fill),
		rounding,
		im.DrawFlags_RoundCornersTop,
	)
	im.DrawList_AddRectFilled(
		dl,
		rmin,
		{rmax.x, rmin.y + max(2.5 * zoom, 1.5)},
		im.GetColorU32ImVec4(thm.with_alpha(accent_c, 0.92)),
		rounding,
		im.DrawFlags_RoundCornersTop,
	)

	// 4. Dedicated Pin / Execution Flow Sub-Header Strip
	if pin_h > 0.0 {
		pin_bg := thm.lerp_col(body_base, p.bg_canvas, p.is_light ? 0.40 : 0.50)
		im.DrawList_AddRectFilled(
			dl,
			{rmin.x + 1.0, rmin.y + hdr_h},
			{rmax.x - 1.0, rmin.y + hdr_h + pin_h},
			im.GetColorU32ImVec4(pin_bg),
		)
		im.DrawList_AddLine(
			dl,
			{rmin.x + 1.0, rmin.y + hdr_h + pin_h},
			{rmax.x - 1.0, rmin.y + hdr_h + pin_h},
			im.GetColorU32ImVec4(p.border_subtle),
			1.0 * zoom,
		)
	}

	// Header bottom divider
	im.DrawList_AddLine(
		dl,
		{rmin.x + 1.0, rmin.y + hdr_h},
		{rmax.x - 1.0, rmin.y + hdr_h},
		im.GetColorU32ImVec4(thm.lerp_col(p.border_subtle, accent_c, 0.42)),
		1.0 * zoom,
	)

	// 5. Outer selection halo & border
	border_c := selected ? p.accent : thm.lerp_col(p.border_subtle, accent_c, hovered ? 0.52 : 0.24)
	if selected {
		im.DrawList_AddRect(
			dl,
			rmin - im.Vec2{2.2, 2.2} * zoom,
			rmax + im.Vec2{2.2, 2.2} * zoom,
			im.GetColorU32ImVec4(thm.with_alpha(p.accent, p.is_light ? 0.24 : 0.34)),
			rounding + 2.0 * zoom,
			2.6 * zoom,
		)
	}
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(border_c), rounding, (selected ? 1.8 : 1.0) * zoom)
}

// =============================================================================
// Haati Node Inline Section, Telemetry & Parameter Row Helpers
// =============================================================================

// Draws a subtle Haati Node section divider strip (`POSE SLOTS`, `PARAMETERS`, `LIVE TELEMETRY`).
canvas_node_section :: proc(b: ^Node_Block_Ctx, label: cstring) {
	p     := thm.palette()
	cur   := im.GetCursorScreenPos()
	ts    := im.CalcTextSize(label)
	row_h := ts.y + 4.0 * b.zm
	w     := max(b.visual_inner_w, ts.x + 28.0 * b.zm)

	im.DrawList_AddText(
		b.dl,
		{cur.x, cur.y + 2.0 * b.zm},
		im.GetColorU32ImVec4(thm.lerp_col(p.text_muted, b.spec.color, 0.45)),
		label,
	)
	line_x0 := cur.x + ts.x + 8.0 * b.zm
	line_y  := cur.y + row_h * 0.55
	if line_x0 < cur.x + w {
		im.DrawList_AddLine(
			b.dl,
			{line_x0, line_y},
			{cur.x + w, line_y},
			im.GetColorU32ImVec4(thm.with_alpha(p.border_subtle, 0.75)),
			1.0 * b.zm,
		)
	}
	im.Dummy({ts.x + 28.0 * b.zm, row_h})
	b.intrinsic_body_w = max(b.intrinsic_body_w, ts.x + 28.0 * b.zm)
}

// Guaranteed zero-overlap 2-column Key / Value readout row.
// Reserves `lw + 20px + vw` via `im.Dummy` so the Node block widens automatically whenever needed!
canvas_node_kv :: proc(b: ^Node_Block_Ctx, label: cstring, value: cstring, custom_val_col: im.Vec4 = {}) {
	p      := thm.palette()
	cur    := im.GetCursorScreenPos()
	lw     := label != nil ? im.CalcTextSize(label).x : 0.0
	vw     := value != nil ? im.CalcTextSize(value).x : 0.0
	font_h := im.GetFontSize()
	row_h  := font_h + 3.0 * b.zm
	gutter := (label != nil && value != nil) ? (20.0 * b.zm) : 0.0
	req_w  := lw + gutter + vw
	span_w := max(b.visual_inner_w, req_w)

	if label != nil {
		im.DrawList_AddText(b.dl, {cur.x, cur.y + 1.0 * b.zm}, im.GetColorU32ImVec4(p.text_secondary), label)
	}
	if value != nil {
		vc := custom_val_col.w > 0.0 ? custom_val_col : p.text_primary
		im.DrawList_AddText(b.dl, {cur.x + span_w - vw, cur.y + 1.0 * b.zm}, im.GetColorU32ImVec4(vc), value)
	}
	im.Dummy({req_w, row_h})
	b.intrinsic_body_w = max(b.intrinsic_body_w, req_w)
}

// Haati Node inline telemetry bar (label on left, recessed progress meter with value text on right).
canvas_node_meter :: proc(b: ^Node_Block_Ctx, label: cstring, fraction_01: f32, overlay: cstring, fill_col: im.Vec4) {
	p      := thm.palette()
	cur    := im.GetCursorScreenPos()
	lw     := im.CalcTextSize(label).x
	font_h := im.GetFontSize()
	row_h  := font_h + 5.0 * b.zm
	lbl_w  := max(b.label_col_w_screen, lw + 10.0 * b.zm)
	bar_w  := max(b.visual_inner_w - lbl_w, b.ctrl_col_w_screen)

	im.DrawList_AddText(b.dl, {cur.x, cur.y + 2.0 * b.zm}, im.GetColorU32ImVec4(p.text_secondary), label)

	bx0  := cur.x + lbl_w
	by0  := cur.y + 2.0 * b.zm
	bx1  := bx0 + bar_w
	by1  := cur.y + row_h - 1.0 * b.zm
	rnd  := 3.5 * b.zm
	frac := clamp(fraction_01, 0.0, 1.0)

	well_c := p.is_light ? thm.lerp_col(p.bg_canvas, {0, 0, 0, 1}, 0.06) : thm.lerp_col(p.bg_canvas, {0, 0, 0, 1}, 0.30)
	im.DrawList_AddRectFilled(b.dl, {bx0, by0}, {bx1, by1}, im.GetColorU32ImVec4(well_c), rnd)
	if frac > 0.005 {
		fw := max((bx1 - bx0) * frac, 4.0 * b.zm)
		im.DrawList_AddRectFilled(b.dl, {bx0, by0}, {bx0 + fw, by1}, im.GetColorU32ImVec4(thm.with_alpha(fill_col, 0.72)), rnd)
	}
	im.DrawList_AddRect(b.dl, {bx0, by0}, {bx1, by1}, im.GetColorU32ImVec4(p.border_subtle), rnd, 1.0 * b.zm)

	if overlay != nil {
		ow := im.CalcTextSize(overlay).x
		im.DrawList_AddText(
			b.dl,
			{bx0 + (bar_w - ow) * 0.5, cur.y + (row_h - font_h) * 0.5},
			im.GetColorU32ImVec4(p.text_primary),
			overlay,
		)
	}
	ow_req := overlay != nil ? (im.CalcTextSize(overlay).x + 14.0 * b.zm) : 0.0
	req_w  := lbl_w + max(b.ctrl_col_w_screen, ow_req)
	im.Dummy({req_w, row_h})
	b.intrinsic_body_w = max(b.intrinsic_body_w, req_w)
}

// Left-column label + Right-column widget cursor setup for inline Node parameters (`Combo`, `DragFloat`, `SliderFloat`).
// Call right before an `##id`-labeled ImGui widget!
canvas_node_param :: proc(b: ^Node_Block_Ctx, label: cstring) -> f32 {
	p     := thm.palette()
	cur   := im.GetCursorScreenPos()
	lw    := im.CalcTextSize(label).x
	lbl_w := max(b.label_col_w_screen, lw + 10.0 * b.zm)
	ctl_w := max(b.visual_inner_w - lbl_w, b.ctrl_col_w_screen)

	b.intrinsic_body_w = max(b.intrinsic_body_w, lbl_w + b.ctrl_col_w_screen)

	im.AlignTextToFramePadding()
	im.TextColored(p.text_secondary, "%s", label)
	im.SameLine()
	im.SetCursorScreenPos({cur.x + lbl_w, cur.y})
	im.SetNextItemWidth(ctl_w)
	return ctl_w
}

// Canonical Haati Blueprint Node (`BP_Node`) aliases for visual-scripting / node-canvas graphs.
BP_NODE_HEADER_H               :: NODE_HEADER_H
BP_NODE_PIN_STRIP_H            :: NODE_PIN_STRIP_H
BP_NODE_PAD_X                  :: NODE_PAD_X
BP_NODE_PAD_BOTTOM             :: NODE_PAD_BOTTOM
BP_NODE_PIN_Y                  :: NODE_PIN_Y
BP_Node_Spec                   :: Node_Block_Spec
BP_Node_Ctx                    :: Node_Block_Ctx
canvas_bp_node_port_in         :: canvas_node_port_in
canvas_bp_node_port_out        :: canvas_node_port_out
canvas_bp_node_begin           :: canvas_node_block_begin
canvas_bp_node_note_body_width :: canvas_node_note_body_width
canvas_bp_node_text            :: canvas_node_text
canvas_bp_node_end             :: canvas_node_block_end
canvas_bp_node_section         :: canvas_node_section
canvas_bp_node_kv              :: canvas_node_kv
canvas_bp_node_meter           :: canvas_node_meter
canvas_bp_node_param           :: canvas_node_param

// Legacy symbol aliases preserved so external/game plugins (`void_odin`) remain zero-touch compatible.
NIAGARA_HEADER_H              :: NODE_HEADER_H
NIAGARA_PIN_STRIP_H           :: NODE_PIN_STRIP_H
NIAGARA_PAD_X                 :: NODE_PAD_X
NIAGARA_PAD_BOTTOM            :: NODE_PAD_BOTTOM
NIAGARA_PIN_Y                 :: NODE_PIN_Y
Niagara_Block_Spec            :: Node_Block_Spec
Niagara_Block_Ctx             :: Node_Block_Ctx
canvas_niagara_port_in        :: canvas_node_port_in
canvas_niagara_port_out       :: canvas_node_port_out
canvas_niagara_block_begin    :: canvas_node_block_begin
canvas_niagara_note_body_width :: canvas_node_note_body_width
canvas_niagara_text           :: canvas_node_text
canvas_niagara_block_end      :: canvas_node_block_end
canvas_niagara_section        :: canvas_node_section
canvas_niagara_kv             :: canvas_node_kv
canvas_niagara_meter          :: canvas_node_meter
canvas_niagara_param          :: canvas_node_param
