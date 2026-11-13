package theme

// Curated studio theme presets built on the unified Antigravity semantic token architecture.

import "core:strings"

to_key :: proc(id: Theme_Id) -> string {
	switch id {
	case .Antigravity_Dark:     return "antigravity_dark"
	case .Antigravity_Light:    return "antigravity_light"
	case .Antigravity_Midnight: return "antigravity_midnight"
	case .Void_Obsidian:        return "void_obsidian"
	case .Nordic_Slate:         return "nordic_slate"
	case .Spectrum_Neutral:     return "spectrum_neutral"
	case .Catppuccin_Mocha:     return "catppuccin_mocha"
	case .Paper_And_Ink:        return "paper_and_ink"
	}
	return "antigravity_dark"
}

from_key :: proc(key: string) -> (Theme_Id, bool) {
	k := strings.trim_space(key)
	switch k {
	case "antigravity_dark":     return .Antigravity_Dark, true
	case "antigravity_light":    return .Antigravity_Light, true
	case "antigravity_midnight": return .Antigravity_Midnight, true
	case "void_obsidian":        return .Void_Obsidian, true
	case "nordic_slate":         return .Nordic_Slate, true
	case "spectrum_neutral":     return .Spectrum_Neutral, true
	case "catppuccin_mocha":     return .Catppuccin_Mocha, true
	case "paper_and_ink":        return .Paper_And_Ink, true
	}
	return .Antigravity_Dark, false
}

display_name :: proc(id: Theme_Id) -> cstring {
	switch id {
	case .Antigravity_Dark:     return "Antigravity Dark"
	case .Antigravity_Light:    return "Antigravity Light"
	case .Antigravity_Midnight: return "Antigravity Midnight"
	case .Void_Obsidian:        return "Void Obsidian"
	case .Nordic_Slate:         return "Nordic Slate"
	case .Spectrum_Neutral:     return "Spectrum Neutral"
	case .Catppuccin_Mocha:     return "Catppuccin Mocha"
	case .Paper_And_Ink:        return "Paper & Ink"
	}
	return "Antigravity Dark"
}

subtitle :: proc(id: Theme_Id) -> cstring {
	switch id {
	case .Antigravity_Dark:     return "Clean calm charcoal slate with soft Google studio blue"
	case .Antigravity_Light:    return "Airy cool alabaster daylight with crisp hairline borders"
	case .Antigravity_Midnight: return "Deep pure carbon for dark-room & OLED focus"
	case .Void_Obsidian:        return "Subtle amethyst-slate with refined Void lavender accent"
	case .Nordic_Slate:         return "Calm cool blue-gray inspired by Godot & Nord"
	case .Spectrum_Neutral:     return "Unbiased achromatic gray for 3D lighting & color grading"
	case .Catppuccin_Mocha:     return "Warm pastel dusk slate with soft periwinkle-lavender"
	case .Paper_And_Ink:        return "Warm editorial parchment daylight with slate-navy ink"
	}
	return ""
}

preset_palette :: proc(id: Theme_Id) -> Theme_Palette {
	switch id {
	case .Antigravity_Dark:
		return Theme_Palette{
			is_light       = false,
			bg_canvas      = rgb(0x111317),
			bg_panel       = rgb(0x171A20),
			bg_recessed    = rgb(0x121419),
			bg_elevated    = rgb(0x1F232B),
			bg_hover       = rgb(0x282D38),
			bg_active      = rgb(0x313746),
			bg_popup       = rgba(0x1C2028, 0.99),
			border_subtle  = rgb(0x262B35),
			border_strong  = rgb(0x363D4C),
			text_primary   = rgb(0xE6E9EF),
			text_secondary = rgb(0xA3AAB8),
			text_muted     = rgb(0x737B8C),
			accent         = rgb(0x7AA8F8),
			accent_hover   = rgb(0x96BBFA),
			accent_active  = rgb(0x5E92F3),
			accent_soft    = rgba(0x7AA8F8, 0.16),
			status_info    = rgb(0x7AA8F8),
			status_success = rgb(0x4CC38A),
			status_warning = rgb(0xF5B13C),
			status_error   = rgb(0xF26464),
			sim_running    = rgb(0xD97724),
			axis_x         = rgb(0xD95353),
			axis_y         = rgb(0x46B467),
			axis_z         = rgb(0x4C8BF5),
			axis_w         = rgb(0x9B6EF3),
		}

	case .Antigravity_Light:
		return Theme_Palette{
			is_light       = true,
			bg_canvas      = rgb(0xEBEEF4),
			bg_panel       = rgb(0xF7F8FB),
			bg_recessed    = rgb(0xFFFFFF),
			bg_elevated    = rgb(0xEEF1F7),
			bg_hover       = rgb(0xE3E8F2),
			bg_active      = rgb(0xD6DFEE),
			bg_popup       = rgba(0xFFFFFF, 0.99),
			border_subtle  = rgb(0xDCE1EB),
			border_strong  = rgb(0xC2CAD8),
			text_primary   = rgb(0x1B1F27),
			text_secondary = rgb(0x4B5363),
			text_muted     = rgb(0x757E91),
			accent         = rgb(0x1A73E8),
			accent_hover   = rgb(0x1557B0),
			accent_active  = rgb(0x174EA6),
			accent_soft    = rgba(0x1A73E8, 0.13),
			status_info    = rgb(0x1A73E8),
			status_success = rgb(0x188038),
			status_warning = rgb(0xB06000),
			status_error   = rgb(0xC5221F),
			sim_running    = rgb(0xC95D0B),
			axis_x         = rgb(0xC93B3B),
			axis_y         = rgb(0x268E47),
			axis_z         = rgb(0x2563EB),
			axis_w         = rgb(0x7C3AED),
		}

	case .Antigravity_Midnight:
		return Theme_Palette{
			is_light       = false,
			bg_canvas      = rgb(0x0B0C0F),
			bg_panel       = rgb(0x111318),
			bg_recessed    = rgb(0x0D0F13),
			bg_elevated    = rgb(0x191C23),
			bg_hover       = rgb(0x222630),
			bg_active      = rgb(0x2B303D),
			bg_popup       = rgba(0x161920, 0.99),
			border_subtle  = rgb(0x20242D),
			border_strong  = rgb(0x303644),
			text_primary   = rgb(0xE4E7EE),
			text_secondary = rgb(0x9BA3B2),
			text_muted     = rgb(0x6D7586),
			accent         = rgb(0x82B1FF),
			accent_hover   = rgb(0x9EC3FF),
			accent_active  = rgb(0x649EFF),
			accent_soft    = rgba(0x82B1FF, 0.16),
			status_info    = rgb(0x82B1FF),
			status_success = rgb(0x52CCA0),
			status_warning = rgb(0xF6B749),
			status_error   = rgb(0xF46B6B),
			sim_running    = rgb(0xDC7A28),
			axis_x         = rgb(0xD95353),
			axis_y         = rgb(0x46B467),
			axis_z         = rgb(0x4C8BF5),
			axis_w         = rgb(0x9B6EF3),
		}

	case .Void_Obsidian:
		return Theme_Palette{
			is_light       = false,
			bg_canvas      = rgb(0x121118),
			bg_panel       = rgb(0x181721),
			bg_recessed    = rgb(0x13121A),
			bg_elevated    = rgb(0x211F2D),
			bg_hover       = rgb(0x2B283A),
			bg_active      = rgb(0x353148),
			bg_popup       = rgba(0x1D1B28, 0.99),
			border_subtle  = rgb(0x2A2738),
			border_strong  = rgb(0x3B374F),
			text_primary   = rgb(0xEAE7F2),
			text_secondary = rgb(0xA8A2BA),
			text_muted     = rgb(0x79738C),
			accent         = rgb(0xA485FF),
			accent_hover   = rgb(0xB9A1FF),
			accent_active  = rgb(0x8E69FA),
			accent_soft    = rgba(0xA485FF, 0.17),
			status_info    = rgb(0x7EB2FF),
			status_success = rgb(0x52C991),
			status_warning = rgb(0xF5B342),
			status_error   = rgb(0xF26878),
			sim_running    = rgb(0xDE7A29),
			axis_x         = rgb(0xDF5664),
			axis_y         = rgb(0x48B874),
			axis_z         = rgb(0x5890F6),
			axis_w         = rgb(0xA485FF),
		}

	case .Nordic_Slate:
		return Theme_Palette{
			is_light       = false,
			bg_canvas      = rgb(0x181C22),
			bg_panel       = rgb(0x1F242C),
			bg_recessed    = rgb(0x191E25),
			bg_elevated    = rgb(0x282F3A),
			bg_hover       = rgb(0x323B48),
			bg_active      = rgb(0x3B4656),
			bg_popup       = rgba(0x242A34, 0.99),
			border_subtle  = rgb(0x2E3643),
			border_strong  = rgb(0x404B5C),
			text_primary   = rgb(0xE5E9F0),
			text_secondary = rgb(0xA7B1C2),
			text_muted     = rgb(0x788396),
			accent         = rgb(0x6CB8E6),
			accent_hover   = rgb(0x88C8EE),
			accent_active  = rgb(0x53A5D9),
			accent_soft    = rgba(0x6CB8E6, 0.17),
			status_info    = rgb(0x6CB8E6),
			status_success = rgb(0x6AC48C),
			status_warning = rgb(0xEBCB8B),
			status_error   = rgb(0xE06C75),
			sim_running    = rgb(0xD08748),
			axis_x         = rgb(0xD65A62),
			axis_y         = rgb(0x5AB87A),
			axis_z         = rgb(0x5B9BD5),
			axis_w         = rgb(0xB48EAD),
		}

	case .Spectrum_Neutral:
		return Theme_Palette{
			is_light       = false,
			bg_canvas      = rgb(0x191919),
			bg_panel       = rgb(0x222222),
			bg_recessed    = rgb(0x1B1B1B),
			bg_elevated    = rgb(0x2C2C2C),
			bg_hover       = rgb(0x363636),
			bg_active      = rgb(0x404040),
			bg_popup       = rgba(0x262626, 0.99),
			border_subtle  = rgb(0x313131),
			border_strong  = rgb(0x454545),
			text_primary   = rgb(0xE8E8E8),
			text_secondary = rgb(0xA8A8A8),
			text_muted     = rgb(0x7A7A7A),
			accent         = rgb(0x549EF6),
			accent_hover   = rgb(0x73B1F8),
			accent_active  = rgb(0x3A8CEB),
			accent_soft    = rgba(0x549EF6, 0.18),
			status_info    = rgb(0x549EF6),
			status_success = rgb(0x4BBF83),
			status_warning = rgb(0xF0AD38),
			status_error   = rgb(0xEC6262),
			sim_running    = rgb(0xD87624),
			axis_x         = rgb(0xD95353),
			axis_y         = rgb(0x46B467),
			axis_z         = rgb(0x4C8BF5),
			axis_w         = rgb(0x9872F0),
		}

	case .Catppuccin_Mocha:
		return Theme_Palette{
			is_light       = false,
			bg_canvas      = rgb(0x14141F),
			bg_panel       = rgb(0x1E1E2E),
			bg_recessed    = rgb(0x181825),
			bg_elevated    = rgb(0x28293D),
			bg_hover       = rgb(0x33354D),
			bg_active      = rgb(0x3E405C),
			bg_popup       = rgba(0x232436, 0.99),
			border_subtle  = rgb(0x2F3146),
			border_strong  = rgb(0x434662),
			text_primary   = rgb(0xCDD6F4),
			text_secondary = rgb(0xA6ADC8),
			text_muted     = rgb(0x7F849C),
			accent         = rgb(0x89B4FA),
			accent_hover   = rgb(0xB4BEFE),
			accent_active  = rgb(0x74C7EC),
			accent_soft    = rgba(0x89B4FA, 0.17),
			status_info    = rgb(0x89B4FA),
			status_success = rgb(0xA6E3A1),
			status_warning = rgb(0xF9E2AF),
			status_error   = rgb(0xF38BA8),
			sim_running    = rgb(0xFAB387),
			axis_x         = rgb(0xE66884),
			axis_y         = rgb(0x6EC479),
			axis_z         = rgb(0x6A9CF5),
			axis_w         = rgb(0xCBA6F7),
		}

	case .Paper_And_Ink:
		return Theme_Palette{
			is_light       = true,
			bg_canvas      = rgb(0xEAE7DF),
			bg_panel       = rgb(0xF6F4EE),
			bg_recessed    = rgb(0xFDFCF9),
			bg_elevated    = rgb(0xEDEAE2),
			bg_hover       = rgb(0xE2DED4),
			bg_active      = rgb(0xD5D0C3),
			bg_popup       = rgba(0xFDFCF9, 0.99),
			border_subtle  = rgb(0xD8D4C8),
			border_strong  = rgb(0xBEB9AA),
			text_primary   = rgb(0x1E1D1A),
			text_secondary = rgb(0x4F4C45),
			text_muted     = rgb(0x7A766C),
			accent         = rgb(0x2B5B94),
			accent_hover   = rgb(0x1F4675),
			accent_active  = rgb(0x17375E),
			accent_soft    = rgba(0x2B5B94, 0.13),
			status_info    = rgb(0x2B5B94),
			status_success = rgb(0x237A43),
			status_warning = rgb(0xA66308),
			status_error   = rgb(0xBD2C28),
			sim_running    = rgb(0xC25E12),
			axis_x         = rgb(0xC23D3D),
			axis_y         = rgb(0x2D8A4E),
			axis_z         = rgb(0x2B5B94),
			axis_w         = rgb(0x6E42A3),
		}
	}
	return preset_palette(.Antigravity_Dark)
}
