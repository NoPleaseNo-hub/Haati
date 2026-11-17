package editor

import im "haati:external/odin-imgui"
import "core:math"
import "haati:editor/icons"
import "haati:editor/handles"
import "haati:editor/widgets"

// Roboto Medium (shipped with imgui under misc/fonts, Apache-2.0) is the base
// UI font. 15px is the size imgui's own font notes recommend for it on a 1x
// display and matches the x-height of the old 13px ProggyClean rows.
FONT_SIZE :: 15

ROBOTO_FONT_DATA := #load("Roboto-Medium.ttf")

// Large Material-icon font size for spots that show an icon spanning ~2 text
// rows (e.g. the console's per-entry icon column, Unity-style).
ICON_FONT_SIZE_LG :: 26

// Standalone (non-merged) large Material icon font. Push it around a single
// icon glyph, then pop back. Set by editor_fonts_init.
editor_icon_font_lg: ^im.Font

// Composite Roboto + Phosphor icon font (`ICON_PH_*`), set by editor_fonts_init.
// Push/pop with `widgets.push_phosphor_font()` / `widgets.pop_phosphor_font()` or
// draw buttons via `widgets.phosphor_icon_button()`.
editor_phosphor_font: ^im.Font

// Embedded Material Symbols & Phosphor glyph ranges; MUST outlive ImFontAtlas because ImGui v1.92
// lazily rasterizes scaled glyph sizes (`PushFontFloat`) from `ImFontConfig.GlyphRanges`.
@(private = "file")
_editor_icon_ranges := [3]im.Wchar{ icons.ICON_MD_MIN, icons.ICON_MD_MAX, 0 }

@(private = "file")
_phosphor_icon_ranges := [3]im.Wchar{ icons.ICON_PH_MIN, icons.ICON_PH_MAX, 0 }

// Material Symbols Outlined (Apache-2.0) and Phosphor Regular (MIT), embedded at compile time
// so the editor binary is independent of the runtime working directory.
MATERIAL_FONT_DATA := #load("haati:external/fonts/material/MaterialSymbolsOutlined.ttf")
PHOSPHOR_FONT_DATA := #load("haati:external/fonts/phosphor/Phosphor.ttf")

// A VALID FontConfig at an EXPLICIT reference size. Odin zero-inits, but imgui
// 1.92's rasterizer relies on several non-zero ctor defaults — missing any bakes
// INVISIBLE glyphs (no assert). ExtraSizeScale is the sneaky one (0 => zero glyph
// size). An explicit SizePixels (vs the implicit-size default font) is what lets
// the merged icon font use GlyphOffset for baseline alignment.
@(private = "file")
_font_config :: proc(size_px: f32 = FONT_SIZE) -> im.FontConfig {
	cfg: im.FontConfig
	cfg.OversampleH = 0
	cfg.OversampleV = 0
	cfg.RasterizerMultiply = 1.0
	cfg.RasterizerDensity = 1.0
	cfg.ExtraSizeScale = 1.0            // 0 => invisible glyphs
	cfg.GlyphMaxAdvanceX = math.F32_MAX // ctor default (FLT_MAX)
	cfg.SizePixels = size_px            // explicit ref size
	return cfg
}

// Load editor UI fonts: Roboto Medium at FONT_SIZE with Material Symbols icons
// merged into it. Call once after im.CreateContext() and before the first
// NewFrame / backend texture build. The backend advertises RendererHasTextures,
// so the atlas builds lazily.
editor_fonts_init :: proc() {
	fonts := im.GetIO().Fonts

	// Base text font at an EXPLICIT size (config with SizePixels > 0 keeps it
	// explicit-size, so the icon merge below can use GlyphOffset). The config
	// must be fully defaulted or text bakes invisible.
	base_cfg := _font_config()
	base_cfg.FontDataOwnedByAtlas = false // static (#load) data; imgui must not free
	im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(ROBOTO_FONT_DATA),
		i32(len(ROBOTO_FONT_DATA)),
		FONT_SIZE,
		&base_cfg,
	)

	// Merge Material icons into the base font at the same explicit size.
	// GlyphOffset nudges the icons down onto the text baseline (Material's em
	// box is taller than Roboto's).
	icon_cfg := _font_config()
	icon_cfg.MergeMode = true
	icon_cfg.PixelSnapH = true
	icon_cfg.GlyphMinAdvanceX = FONT_SIZE
	icon_cfg.GlyphOffset = im.Vec2{0, 2}
	icon_cfg.FontDataOwnedByAtlas = false // static (#load) data; imgui must not free
	im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(MATERIAL_FONT_DATA),
		i32(len(MATERIAL_FONT_DATA)),
		FONT_SIZE,
		&icon_cfg,
		&_editor_icon_ranges[0],
	)
	// Scene icons draw Material Symbols glyphs from the same static data
	// (editor/handles/icons.odin).
	handles.icon_font_set(MATERIAL_FONT_DATA)

	// Standalone large icon font (NOT merged) for the console's 2-row icon
	// column. Same range, no GlyphOffset — it's drawn on its own, centered by
	// the caller. FontDataOwnedByAtlas=false: shares the static #load buffer.
	lg_cfg := _font_config(ICON_FONT_SIZE_LG)
	lg_cfg.PixelSnapH = true
	lg_cfg.GlyphMinAdvanceX = ICON_FONT_SIZE_LG
	lg_cfg.FontDataOwnedByAtlas = false
	editor_icon_font_lg = im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(MATERIAL_FONT_DATA),
		i32(len(MATERIAL_FONT_DATA)),
		ICON_FONT_SIZE_LG,
		&lg_cfg,
		&_editor_icon_ranges[0],
	)
	widgets.dialog_icon_font = editor_icon_font_lg

	// Composite Roboto Medium + Phosphor Regular font (`ICON_PH_*` glyphs alongside readable text).
	ph_base_cfg := _font_config()
	ph_base_cfg.FontDataOwnedByAtlas = false
	editor_phosphor_font = im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(ROBOTO_FONT_DATA),
		i32(len(ROBOTO_FONT_DATA)),
		FONT_SIZE,
		&ph_base_cfg,
	)

	ph_icon_cfg := _font_config()
	ph_icon_cfg.MergeMode = true
	ph_icon_cfg.PixelSnapH = true
	ph_icon_cfg.GlyphMinAdvanceX = FONT_SIZE
	ph_icon_cfg.GlyphOffset = im.Vec2{0, 2}
	ph_icon_cfg.FontDataOwnedByAtlas = false
	im.FontAtlas_AddFontFromMemoryTTF(
		fonts,
		raw_data(PHOSPHOR_FONT_DATA),
		i32(len(PHOSPHOR_FONT_DATA)),
		FONT_SIZE,
		&ph_icon_cfg,
		&_phosphor_icon_ranges[0],
	)
	widgets.phosphor_font = editor_phosphor_font
}
