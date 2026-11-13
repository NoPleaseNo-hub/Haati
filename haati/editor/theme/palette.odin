package theme

// Unified Semantic Editor Theme Engine for MoonHug.
//
// Designed around the Antigravity clean, calm, minimal IDE visual language:
//   - Soft charcoal / alabaster tonal surface hierarchy (canvas -> panel -> elevated -> hover)
//   - Whisper-thin 1px hairline borders instead of heavy contrasting boxes
//   - Quiet tonal pill buttons at rest; saturated hues reserved for primary actions & semantic badges
//   - Clean active-tab overline indicator with seamless tab-to-panel surface continuity
//   - Full dark & light mode semantic tokens exported to all built-in views and Void plugin panels
//
// Zero editor-internal package dependencies (imports only odin-imgui + core) so `menu`, `widgets`,
// `node_canvas`, `inspector`, `editor`, and all plugins can import `moonhug:editor/theme` cycle-free.

import "core:math"
import im "haati:external/odin-imgui"

Theme_Id :: enum {
	Antigravity_Dark,     // Default: calm obsidian-slate + signature Antigravity soft blue
	Antigravity_Light,    // Airy cool-alabaster daylight + clean studio blue
	Antigravity_Midnight, // Pure deep carbon for dark rooms / OLED displays
	Void_Obsidian,        // Subtle dark amethyst-slate + refined Void lavender-violet
	Nordic_Slate,         // Calm cool blue-gray + soft frost-cyan
	Spectrum_Neutral,     // Unbiased achromatic neutral gray for 3D lighting & color grading
	Catppuccin_Mocha,     // Refined Catppuccin Mocha built on Antigravity geometry
	Paper_And_Ink,        // Warm editorial parchment daylight + slate-navy ink
}

UI_Density :: enum {
	Compact,
	Clean,    // Default Antigravity balanced breathing room
	Spacious,
}

Corner_Style :: enum {
	Rounded,   // Default Antigravity 5-6px clean geometry
	Soft_Pill, // Softer 7-8px rounded geometry
	Crisp,     // Tight 2px studio corners
}

Theme_Palette :: struct {
	is_light: bool,

	// Surface elevation hierarchy
	bg_canvas:   im.Vec4, // Deepest backdrop: dock host, menu bar, toolbar, inactive tab strip
	bg_panel:    im.Vec4, // Primary docked panel background & active tab fill
	bg_recessed: im.Vec4, // Inputs, search fields, list wells, node canvas well
	bg_elevated: im.Vec4, // Cards, asset tiles, resting buttons, collapsible headers
	bg_hover:    im.Vec4, // Tonal hover state
	bg_active:   im.Vec4, // Pressed / active tonal surface
	bg_popup:    im.Vec4, // Context menus, dropdowns, and tooltips (high opacity)

	// Hairline borders & dividers
	border_subtle: im.Vec4, // Quiet 1px panel/frame/row divider
	border_strong: im.Vec4, // Popups, focused cards, active outlines

	// Typography hierarchy
	text_primary:   im.Vec4, // Crisp primary copy (off-white in dark, ink in light)
	text_secondary: im.Vec4, // Labels, inactive tabs, secondary controls
	text_muted:     im.Vec4, // Hints, metadata, disabled items

	// Brand & interactive accent
	accent:        im.Vec4, // Primary accent (overline, checkmarks, links, focus ring)
	accent_hover:  im.Vec4, // Hovered accent
	accent_active: im.Vec4, // Pressed accent
	accent_soft:   im.Vec4, // Translucent selection / active pill wash

	// Semantic status & simulation accents
	status_info:    im.Vec4,
	status_success: im.Vec4,
	status_warning: im.Vec4,
	status_error:   im.Vec4,
	sim_running:    im.Vec4, // Toolbar highlight while in-editor simulation is active

	// Harmonized 3D gizmo / transform badges
	axis_x: im.Vec4,
	axis_y: im.Vec4,
	axis_z: im.Vec4,
	axis_w: im.Vec4,
}

@(private = "file") _active_theme:      Theme_Id     = .Antigravity_Dark
@(private = "file") _active_density:    UI_Density   = .Clean
@(private = "file") _active_corners:    Corner_Style = .Rounded
@(private = "file") _use_custom_accent: bool         = false
@(private = "file") _custom_accent:     [4]f32       = {0.478, 0.659, 0.973, 1.0} // #7AA8F8
@(private = "file") _cached_palette:    Theme_Palette
@(private = "file") _palette_ready:     bool         = false

@(private = "file") _default_style:          im.Style
@(private = "file") _default_style_captured: bool

// 0xRRGGBB -> opaque ImVec4
rgb :: proc(hex: u32) -> im.Vec4 {
	return im.Vec4{
		f32((hex >> 16) & 0xFF) / 255.0,
		f32((hex >> 8) & 0xFF) / 255.0,
		f32(hex & 0xFF) / 255.0,
		1.0,
	}
}

// 0xRRGGBB + alpha -> ImVec4
rgba :: proc(hex: u32, a: f32) -> im.Vec4 {
	c := rgb(hex)
	c.w = a
	return c
}

with_alpha :: proc(c: im.Vec4, a: f32) -> im.Vec4 {
	return im.Vec4{c.x, c.y, c.z, a}
}

lerp_col :: proc(a, b: im.Vec4, t: f32) -> im.Vec4 {
	return im.Vec4{
		a.x + (b.x - a.x) * t,
		a.y + (b.y - a.y) * t,
		a.z + (b.z - a.z) * t,
		a.w + (b.w - a.w) * t,
	}
}

// WCAG 2.1 relative luminance for sRGB 0..1 channels (used by theme contrast tests & badge adaptation).
relative_luminance :: proc(c: im.Vec4) -> f32 {
	chan :: proc(v: f32) -> f32 {
		x := clamp(v, 0.0, 1.0)
		return x / 12.92 if x <= 0.04045 else math.pow((x + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * chan(c.x) + 0.7152 * chan(c.y) + 0.0722 * chan(c.z)
}

contrast_ratio :: proc(fg, bg: im.Vec4) -> f32 {
	l1 := relative_luminance(fg)
	l2 := relative_luminance(bg)
	hi := max(l1, l2)
	lo := min(l1, l2)
	return (hi + 0.05) / (lo + 0.05)
}

// Adapts a dark-tuned category/folder color so it stays legible on light surfaces too.
adapt_badge_color :: proc(col: [4]f32) -> im.Vec4 {
	p := palette()
	v := im.Vec4{col[0], col[1], col[2], col[3]}
	if !p.is_light do return v
	// Darken bright pastel badges on daylight surfaces so text & icons maintain crisp contrast.
	return im.Vec4{
		clamp(v.x * 0.68, 0.05, 0.85),
		clamp(v.y * 0.68, 0.05, 0.85),
		clamp(v.z * 0.68, 0.05, 0.85),
		v.w,
	}
}

active :: proc() -> Theme_Id {
	return _active_theme
}

density :: proc() -> UI_Density {
	return _active_density
}

corners :: proc() -> Corner_Style {
	return _active_corners
}

custom_accent_state :: proc() -> (enabled: bool, color: [4]f32) {
	return _use_custom_accent, _custom_accent
}

palette :: proc() -> Theme_Palette {
	if !_palette_ready {
		_rebuild_palette()
	}
	return _cached_palette
}

set :: proc(id: Theme_Id) {
	_active_theme = id
	apply()
}

set_density :: proc(d: UI_Density) {
	_active_density = d
	apply()
}

set_corners :: proc(c: Corner_Style) {
	_active_corners = c
	apply()
}

set_custom_accent :: proc(enabled: bool, color: [4]f32 = {0.478, 0.659, 0.973, 1.0}) {
	_use_custom_accent = enabled
	if color[3] > 0.01 {
		_custom_accent = {clamp(color[0], 0, 1), clamp(color[1], 0, 1), clamp(color[2], 0, 1), 1.0}
	}
	apply()
}

@(private = "file")
_rebuild_palette :: proc() {
	p := preset_palette(_active_theme)
	if _use_custom_accent {
		acc := im.Vec4{_custom_accent[0], _custom_accent[1], _custom_accent[2], 1.0}
		p.accent = acc
		if p.is_light {
			p.accent_hover  = lerp_col(acc, rgb(0x000000), 0.14)
			p.accent_active = lerp_col(acc, rgb(0x000000), 0.25)
			p.accent_soft   = with_alpha(acc, 0.14)
		} else {
			p.accent_hover  = lerp_col(acc, rgb(0xFFFFFF), 0.18)
			p.accent_active = lerp_col(acc, rgb(0x000000), 0.14)
			p.accent_soft   = with_alpha(acc, 0.18)
		}
	}
	_cached_palette = p
	_palette_ready = true
}

// Rebuilds the semantic palette and applies all ImGui colors & clean Antigravity scalars
// whenever an ImGui context is live (safe to call headlessly in unit tests too).
apply :: proc() {
	_rebuild_palette()
	if im.GetCurrentContext() == nil do return

	s := im.GetStyle()
	if !_default_style_captured {
		_default_style = s^
		_default_style_captured = true
	}
	s^ = _default_style

	p := _cached_palette
	c := &s.Colors

	// Selection & header washes stay translucent so primary text maintains >= 4.5:1 contrast.
	sel_idle   := p.accent_soft
	sel_hover  := with_alpha(p.accent, p.is_light ? 0.20 : 0.26)
	sel_active := with_alpha(p.accent, p.is_light ? 0.28 : 0.34)

	c[im.Col.Text]                      = p.text_primary
	c[im.Col.TextDisabled]              = p.text_muted
	c[im.Col.WindowBg]                  = p.bg_panel
	c[im.Col.ChildBg]                   = {0, 0, 0, 0}
	c[im.Col.PopupBg]                   = p.bg_popup
	c[im.Col.Border]                    = p.border_subtle
	c[im.Col.BorderShadow]              = {0, 0, 0, 0}

	c[im.Col.FrameBg]                   = p.bg_recessed
	c[im.Col.FrameBgHovered]            = p.bg_hover
	c[im.Col.FrameBgActive]             = p.bg_active

	c[im.Col.TitleBg]                   = p.bg_canvas
	c[im.Col.TitleBgActive]             = p.bg_canvas
	c[im.Col.TitleBgCollapsed]          = p.bg_canvas
	c[im.Col.MenuBarBg]                 = p.bg_canvas

	c[im.Col.ScrollbarBg]               = with_alpha(p.bg_canvas, 0.0)
	c[im.Col.ScrollbarGrab]             = with_alpha(p.text_muted, 0.36)
	c[im.Col.ScrollbarGrabHovered]      = with_alpha(p.text_secondary, 0.62)
	c[im.Col.ScrollbarGrabActive]       = p.accent

	c[im.Col.CheckMark]                 = p.accent
	c[im.Col.SliderGrab]                = p.accent
	c[im.Col.SliderGrabActive]          = p.accent_hover

	// Quiet tonal pill buttons (Antigravity signature: calm at rest, clear lift on hover)
	c[im.Col.Button]                    = p.bg_elevated
	c[im.Col.ButtonHovered]             = p.bg_hover
	c[im.Col.ButtonActive]              = p.bg_active

	// Clean soft selection washes for trees, menus, selectables, and collapsible headers
	c[im.Col.Header]                    = sel_idle
	c[im.Col.HeaderHovered]             = sel_hover
	c[im.Col.HeaderActive]              = sel_active

	c[im.Col.Separator]                 = p.border_subtle
	c[im.Col.SeparatorHovered]          = p.accent
	c[im.Col.SeparatorActive]           = p.accent_hover

	c[im.Col.ResizeGrip]                = with_alpha(p.border_strong, 0.30)
	c[im.Col.ResizeGripHovered]         = with_alpha(p.accent, 0.75)
	c[im.Col.ResizeGripActive]          = p.accent

	// Seamless Antigravity tab strip: inactive tabs sit quietly on bg_canvas;
	// selected tab matches bg_panel with a crisp 2px accent overline on top.
	c[im.Col.Tab]                       = p.bg_canvas
	c[im.Col.TabHovered]                = p.bg_hover
	c[im.Col.TabSelected]               = p.bg_panel
	c[im.Col.TabSelectedOverline]       = p.accent
	c[im.Col.TabDimmed]                 = p.bg_canvas
	c[im.Col.TabDimmedSelected]         = p.bg_panel
	c[im.Col.TabDimmedSelectedOverline] = with_alpha(p.accent, 0.45)

	c[im.Col.DockingPreview]            = with_alpha(p.accent, 0.38)
	c[im.Col.DockingEmptyBg]            = p.bg_canvas

	c[im.Col.PlotLines]                 = p.accent
	c[im.Col.PlotLinesHovered]          = p.accent_hover
	c[im.Col.PlotHistogram]             = p.accent
	c[im.Col.PlotHistogramHovered]      = p.accent_hover

	c[im.Col.TableHeaderBg]             = p.bg_elevated
	c[im.Col.TableBorderStrong]         = p.border_strong
	c[im.Col.TableBorderLight]          = p.border_subtle
	c[im.Col.TableRowBg]                = {0, 0, 0, 0}
	c[im.Col.TableRowBgAlt]             = p.is_light ? im.Vec4{0, 0, 0, 0.022} : im.Vec4{1, 1, 1, 0.022}

	c[im.Col.TextLink]                  = p.accent
	c[im.Col.TextSelectedBg]            = with_alpha(p.accent, 0.26)
	c[im.Col.DragDropTarget]            = p.accent
	c[im.Col.DragDropTargetBg]          = with_alpha(p.accent, 0.10)
	c[im.Col.NavCursor]                 = p.accent
	c[im.Col.NavWindowingHighlight]     = with_alpha(p.accent, 0.80)
	c[im.Col.NavWindowingDimBg]         = {0, 0, 0, 0.35}
	c[im.Col.ModalWindowDimBg]          = {0, 0, 0, p.is_light ? 0.32 : 0.52}
	c[im.Col.CheckboxSelectedBg]        = with_alpha(p.accent, p.is_light ? 0.14 : 0.18)
	c[im.Col.InputTextCursor]           = p.accent
	c[im.Col.TreeLines]                 = with_alpha(p.border_strong, 0.55)
	c[im.Col.UnsavedMarker]             = p.status_warning

	// Clean Antigravity layout geometry & breathing room
	switch _active_density {
	case .Compact:
		s.WindowPadding    = {8, 8}
		s.FramePadding     = {6, 3}
		s.ItemSpacing      = {6, 4}
		s.ItemInnerSpacing = {4, 3}
		s.CellPadding      = {5, 3}
	case .Clean:
		s.WindowPadding    = {10, 10}
		s.FramePadding     = {8, 5}
		s.ItemSpacing      = {8, 5}
		s.ItemInnerSpacing = {6, 4}
		s.CellPadding      = {6, 4}
	case .Spacious:
		s.WindowPadding    = {12, 12}
		s.FramePadding     = {10, 6}
		s.ItemSpacing      = {10, 7}
		s.ItemInnerSpacing = {7, 5}
		s.CellPadding      = {8, 5}
	}

	switch _active_corners {
	case .Rounded:
		s.WindowRounding = 6
		s.ChildRounding  = 5
		s.FrameRounding  = 5
		s.PopupRounding  = 6
		s.GrabRounding   = 4
		s.TabRounding    = 5
	case .Soft_Pill:
		s.WindowRounding = 8
		s.ChildRounding  = 7
		s.FrameRounding  = 7
		s.PopupRounding  = 8
		s.GrabRounding   = 6
		s.TabRounding    = 6
	case .Crisp:
		s.WindowRounding = 2
		s.ChildRounding  = 2
		s.FrameRounding  = 2
		s.PopupRounding  = 3
		s.GrabRounding   = 2
		s.TabRounding    = 2
	}

	s.WindowBorderSize         = 1
	s.ChildBorderSize          = 1
	s.PopupBorderSize          = 1
	s.FrameBorderSize          = 1
	s.TabBorderSize            = 0
	s.TabBarOverlineSize       = 2
	s.DockingSeparatorSize     = 1
	s.ScrollbarSize            = 10
	s.ScrollbarRounding        = 8
	s.GrabMinSize              = 9
	s.IndentSpacing            = 14
	s.DisabledAlpha            = 0.52
	s.WindowTitleAlign         = {0.0, 0.5}
	s.ColorButtonPosition      = .Right
	s.WindowMenuButtonPosition = .None
	s.DockingNodeHasCloseButton = false
}
