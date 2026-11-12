package tests

// Headless verification of the unified Antigravity semantic theme engine (`moonhug:editor/theme`):
//   1. Stable string-key persistence round-tripping across all 8 studio presets
//   2. WCAG 2.1 AA/AAA typography contrast across every dark & light palette
//   3. Monotonic Antigravity surface elevation hierarchy (canvas -> panel -> elevated -> hover)
//   4. Custom accent override, UI density, corner geometry, and light-mode badge adaptation

import "core:testing"
import thm "moonhug:editor/theme"
import "../editor/menu"

@(test)
test_theme_keys_round_trip_and_fallback :: proc(t: ^testing.T) {
	for id in thm.Theme_Id {
		key := thm.to_key(id)
		testing.expectf(t, len(key) > 0, "preset %v must have a non-empty persistence key", id)
		parsed, ok := thm.from_key(key)
		testing.expectf(t, ok, "key %q must parse cleanly", key)
		testing.expect_value(t, parsed, id)
		testing.expectf(t, len(string(thm.display_name(id))) > 0, "preset %v must have a display name", id)
	}

	// Empty or legacy unknown keys safely fall back to Antigravity Dark.
	def_empty, ok_empty := thm.from_key("")
	testing.expect(t, !ok_empty)
	testing.expect_value(t, def_empty, thm.Theme_Id.Antigravity_Dark)

	def_legacy, ok_legacy := thm.from_key("classic_purple_1998")
	testing.expect(t, !ok_legacy)
	testing.expect_value(t, def_legacy, thm.Theme_Id.Antigravity_Dark)
}

@(test)
test_theme_wcag_contrast_and_tonal_hierarchy :: proc(t: ^testing.T) {
	for id in thm.Theme_Id {
		p := thm.preset_palette(id)

		// Primary copy must maintain crisp AAA-grade readability (>= 7.0:1) on panels and >= 6.0:1 on cards.
		cr_primary_panel := thm.contrast_ratio(p.text_primary, p.bg_panel)
		cr_primary_card  := thm.contrast_ratio(p.text_primary, p.bg_elevated)
		cr_secondary     := thm.contrast_ratio(p.text_secondary, p.bg_panel)

		testing.expectf(
			t,
			cr_primary_panel >= 7.0,
			"%v: primary text vs bg_panel contrast %.2f must be >= 7.0 (WCAG AAA)",
			id,
			cr_primary_panel,
		)
		testing.expectf(
			t,
			cr_primary_card >= 6.0,
			"%v: primary text vs bg_elevated contrast %.2f must be >= 6.0",
			id,
			cr_primary_card,
		)
		testing.expectf(
			t,
			cr_secondary >= 4.5,
			"%v: secondary text vs bg_panel contrast %.2f must be >= 4.5 (WCAG AA)",
			id,
			cr_secondary,
		)

		lum_canvas   := thm.relative_luminance(p.bg_canvas)
		lum_panel    := thm.relative_luminance(p.bg_panel)
		lum_elevated := thm.relative_luminance(p.bg_elevated)
		lum_hover    := thm.relative_luminance(p.bg_hover)

		if id == .Antigravity_Light || id == .Paper_And_Ink {
			testing.expectf(t, p.is_light, "%v must declare is_light = true", id)
			testing.expectf(t, lum_panel > 0.75, "%v daylight panel luminance %.3f must be > 0.75", id, lum_panel)
		} else {
			testing.expectf(t, !p.is_light, "%v must declare is_light = false", id)
			// Dark Antigravity tonal elevation: canvas < panel < elevated < hover
			testing.expectf(
				t,
				lum_canvas < lum_panel && lum_panel < lum_elevated && lum_elevated < lum_hover,
				"%v dark surfaces must rise monotonically in luminance (%.4f < %.4f < %.4f < %.4f)",
				id,
				lum_canvas,
				lum_panel,
				lum_elevated,
				lum_hover,
			)
		}
	}
}

@(test)
test_theme_state_transitions_and_badge_adaptation :: proc(t: ^testing.T) {
	defer {
		thm.set_density(.Clean)
		thm.set_corners(.Rounded)
		thm.set_custom_accent(false)
		menu.set_theme(.Antigravity_Dark)
	}

	// Switch to Antigravity Light and verify badge adaptation darkens bright pastels for daylight legibility.
	menu.set_theme(.Antigravity_Light)
	testing.expect_value(t, thm.active(), thm.Theme_Id.Antigravity_Light)
	testing.expect(t, thm.palette().is_light)

	pastel_yellow := [4]f32{1.0, 0.90, 0.40, 1.0}
	adapted_light := thm.adapt_badge_color(pastel_yellow)
	testing.expect(t, adapted_light.x < pastel_yellow[0] && adapted_light.y < pastel_yellow[1])

	// Switch back to Antigravity Dark and verify pastel badge hue stays untouched.
	menu.set_theme(.Antigravity_Dark)
	adapted_dark := thm.adapt_badge_color(pastel_yellow)
	testing.expect_value(t, adapted_dark.x, pastel_yellow[0])
	testing.expect_value(t, adapted_dark.y, pastel_yellow[1])

	// Density, corner geometry, and custom accent overrides round-trip headlessly without an ImGui context.
	thm.set_density(.Compact)
	testing.expect_value(t, thm.density(), thm.UI_Density.Compact)

	thm.set_corners(.Soft_Pill)
	testing.expect_value(t, thm.corners(), thm.Corner_Style.Soft_Pill)

	custom := [4]f32{0.25, 0.80, 0.55, 1.0}
	thm.set_custom_accent(true, custom)
	en, col := thm.custom_accent_state()
	testing.expect(t, en)
	testing.expect_value(t, col[0], custom[0])
	testing.expect_value(t, thm.palette().accent.x, custom[0])
}
