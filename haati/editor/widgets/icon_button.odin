package widgets

// Icon buttons, in the shared package so every view gets the same look and
// the same centering.
//
// A glyph is NOT centered by passing it as the button's label: imgui centers
// a label by its advance width, and these glyphs carry side bearing, so the
// icon sits visibly off-center in a square box. Every icon button here takes
// an EMPTY label and draws the glyph centered on the button's own rect. That
// mistake has been made twice in this codebase, so it is fixed in one place.

import "core:strings"
import im "haati:external/odin-imgui"
import icons "haati:editor/icons"
import thm "haati:editor/theme"

// icon_button's `tooltip` parameter shadows the tooltip proc, so the package
// reaches it under a second name (ui_help.odin).
_tooltip :: tooltip

// Draws `glyph` centered inside [rmin, rmax] on the current draw list, in the
// current text color. For a caller that owns its own button or frame.
icon_draw_centered :: proc(glyph: cstring, rmin, rmax: im.Vec2) {
	sz := im.CalcTextSize(glyph, nil, false, -1)
	pos := im.Vec2{
		rmin.x + (rmax.x - rmin.x - sz.x) * 0.5,
		rmin.y + (rmax.y - rmin.y - sz.y) * 0.5,
	}
	im.DrawList_AddText(im.GetWindowDrawList(), pos, im.GetColorU32(.Text), glyph)
}

// A square icon button. `id` must start with "##" — it is the button's imgui
// id and never shows. `size` 0 takes one frame height, so a row of them lines
// up with the fields beside it.
//
// `active` lights the button the way a held toggle reads, and `tooltip` is
// shown on hover (also while disabled, so a disabled control can say why).
icon_button :: proc(
	glyph: cstring,
	id: cstring,
	tooltip: cstring = "",
	active := false,
	size: f32 = 0,
	active_color := im.Vec4{},
	loc := #caller_location,
) -> (clicked: bool) {
	h := size > 0 ? size : im.GetFrameHeight()
	n: i32 = 0
	if active {
		p := thm.palette()
		bg := active_color.w > 0 ? active_color : p.accent_soft
		n = _push_toggle_style(true, bg, false)
	}
	clicked = im.Button(id, im.Vec2{h, h})
	icon_draw_centered(glyph, im.GetItemRectMin(), im.GetItemRectMax())
	if n > 0 do im.PopStyleColor(n)
	// Through the shared tooltip so debug tooltips can add the attribute that
	// registered whatever this button is part of. The parameter shadows the
	// proc name, so the call goes through the alias. `loc` is the CALLER's,
	// forwarded — a hand-drawn button should name the line that drew it, not
	// this helper.
	_tooltip(tooltip, im.HoveredFlags_AllowWhenDisabled, loc)
	return
}

// Transparent-at-rest toolbar/inline icon button using theme hover/active washes.
ghost_icon_button :: proc(
	glyph: cstring,
	id: cstring,
	tooltip: cstring = "",
	active := false,
	size: f32 = 0,
	active_color := im.Vec4{},
	loc := #caller_location,
) -> (clicked: bool) {
	h := size > 0 ? size : im.GetFrameHeight()
	p := thm.palette()
	if active {
		bg := active_color.w > 0 ? active_color : p.accent_soft
		n := _push_toggle_style(true, bg, false)
		clicked = im.Button(id, im.Vec2{h, h})
		icon_draw_centered(glyph, im.GetItemRectMin(), im.GetItemRectMax())
		im.PopStyleColor(n)
	} else {
		im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
		im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
		im.PushStyleColorImVec4(.ButtonActive, p.bg_active)
		im.PushStyleColorImVec4(.Text, p.text_muted)
		clicked = im.Button(id, im.Vec2{h, h})
		icon_draw_centered(glyph, im.GetItemRectMin(), im.GetItemRectMax())
		im.PopStyleColor(4)
	}
	_tooltip(tooltip, im.HoveredFlags_AllowWhenDisabled, loc)
	return
}

// Composite Roboto + Phosphor font handle populated at startup by `editor_fonts_init`.
phosphor_font: ^im.Font

// Monospace vector font + Material Symbols icon merge populated at startup by `editor_fonts_init`.
mono_font: ^im.Font

// Pushes the Phosphor Regular composite font so `icons.ICON_PH_*` glyphs render cleanly.
// Always pair with `pop_phosphor_font()`.
push_phosphor_font :: proc(size: f32 = 0) {
	if phosphor_font != nil {
		px := size > 0 ? size : im.GetStyle().FontSizeBase
		im.PushFontFloat(phosphor_font, px)
	}
}

// Pops the Phosphor Regular composite font pushed by `push_phosphor_font`.
pop_phosphor_font :: proc() {
	if phosphor_font != nil {
		im.PopFont()
	}
}

// Square button rendering an `icons.ICON_PH_*` Phosphor icon glyph.
phosphor_icon_button :: proc(
	glyph: cstring,
	id: cstring,
	tooltip: cstring = "",
	active := false,
	size: f32 = 0,
	active_color := im.Vec4{},
	loc := #caller_location,
) -> (clicked: bool) {
	push_phosphor_font()
	clicked = icon_button(glyph, id, tooltip, active, size, active_color, loc)
	pop_phosphor_font()
	return
}

// Transparent-at-rest square button rendering an `icons.ICON_PH_*` Phosphor icon glyph.
phosphor_ghost_icon_button :: proc(
	glyph: cstring,
	id: cstring,
	tooltip: cstring = "",
	active := false,
	size: f32 = 0,
	active_color := im.Vec4{},
	loc := #caller_location,
) -> (clicked: bool) {
	push_phosphor_font()
	clicked = ghost_icon_button(glyph, id, tooltip, active, size, active_color, loc)
	pop_phosphor_font()
	return
}

// Clickable asset/object slot button paired with an optional inline picker trigger.
object_field_button :: proc(
	id: cstring,
	display: cstring,
	empty_hint: cstring = "None",
	width: f32 = 0,
	has_value := false,
	missing := false,
	tooltip: cstring = "",
	picker_tooltip: cstring = "Pick...",
	show_picker := true,
	loc := #caller_location,
) -> (clicked, picker_clicked: bool) {
	p := thm.palette()
	im.PushID(id)
	defer im.PopID()

	picker_w := show_picker ? (im.GetFrameHeight() + im.GetStyle().ItemSpacing.x) : f32(0)
	avail := width > 0 ? width : im.GetContentRegionAvail().x
	slot_w := max(f32(60.0), avail - picker_w)

	shown := display
	if shown == nil || len(string(shown)) == 0 {
		shown = empty_hint
	}
	lbl := temp_cstr(strings.concatenate({string(shown), "##slot"}, context.temp_allocator))

	text_col := p.text_primary
	if missing {
		text_col = p.status_error
	} else if !has_value {
		text_col = p.text_muted
	}

	im.PushStyleVarImVec2(.ButtonTextAlign, {0.0, 0.5})
	im.PushStyleColorImVec4(.Button, p.bg_recessed)
	im.PushStyleColorImVec4(.ButtonHovered, p.bg_hover)
	im.PushStyleColorImVec4(.ButtonActive, p.bg_active)
	im.PushStyleColorImVec4(.Text, text_col)
	clicked = im.Button(lbl, {slot_w, 0})
	im.PopStyleColor(4)
	im.PopStyleVar()
	_tooltip(tooltip, im.HoveredFlags_AllowWhenDisabled, loc)

	if show_picker {
		im.SameLine(0, im.GetStyle().ItemSpacing.x)
		picker_clicked = icon_button(icons.ICON_MD_SEARCH, "##pick", picker_tooltip, loc = loc)
	}
	return
}

// Draws a rounded pill badge at `pos` using `dl` and returns its rendered size.
draw_pill_badge :: proc(
	dl: ^im.DrawList,
	pos: im.Vec2,
	text: cstring,
	bg_col: im.Vec4,
	text_col := im.Vec4{},
	pad := im.Vec2{6, 2},
	rounding: f32 = 4,
	border_col := im.Vec4{},
) -> im.Vec2 {
	sz := im.CalcTextSize(text, nil, false, -1)
	box_sz := im.Vec2{sz.x + pad.x * 2, sz.y + pad.y * 2}
	if dl != nil {
		pmax := pos + box_sz
		im.DrawList_AddRectFilled(dl, pos, pmax, im.GetColorU32ImVec4(bg_col), rounding)
		if border_col.w > 0 {
			im.DrawList_AddRect(dl, pos, pmax, im.GetColorU32ImVec4(border_col), rounding, 1.0, {})
		}
		fg := text_col.w > 0 ? text_col : _contrast_button_fg(bg_col)
		im.DrawList_AddText(dl, pos + pad, im.GetColorU32ImVec4(fg), text)
	}
	return box_sz
}
