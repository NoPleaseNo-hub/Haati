package editor_visuals_editor

import "core:fmt"
import "core:strings"
import im "haati:external/odin-imgui"
import wnd "haati:editor/window"
import ev "haati:editor/editor_visuals"
import icons "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"

@(private = "file")
_new_folder_buf: [64]u8

@(private = "file")
_new_folder_color: [4]f32 = {0.48, 0.66, 0.97, 1.0}

// Draws an Antigravity-styled segmented pill button that highlights when `active` is true.
@(private = "file")
_choice_pill :: proc(label: cstring, active: bool) -> bool {
	p := thm.palette()
	if active {
		im.PushStyleColorImVec4(.Button, p.accent_soft)
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.accent, 0.24))
		im.PushStyleColorImVec4(.ButtonActive, thm.with_alpha(p.accent, 0.32))
		im.PushStyleColorImVec4(.Border, p.accent)
		im.PushStyleColorImVec4(.Text, p.is_light ? p.accent : p.text_primary)
		im.PushStyleVar(.FrameBorderSize, 1.0)
	}
	clicked := im.Button(label)
	if active {
		im.PopStyleVar()
		im.PopStyleColor(5)
	}
	return clicked
}

// Draws an interactive miniature UI preview card for a studio theme preset.
@(private = "file")
_draw_theme_card :: proc(tid: thm.Theme_Id, card_w: f32) -> bool {
	p := thm.palette()
	tp := thm.preset_palette(tid)
	is_cur := thm.active() == tid
	card_h :: f32(94)

	im.PushIDInt(i32(tid))
	defer im.PopID()

	rmin := im.GetCursorScreenPos()
	rmax := rmin + im.Vec2{card_w, card_h}
	im.InvisibleButton("##theme_card", {card_w, card_h})
	clicked := im.IsItemClicked(.Left)
	hovered := im.IsItemHovered()
	widgets.tooltip(thm.subtitle(tid))

	dl := im.GetWindowDrawList()
	rounding: f32 = 6.0

	// Outer card container
	card_bg := hovered ? p.bg_hover : p.bg_elevated
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(card_bg), rounding)

	// Top miniature IDE chrome preview (56px tall)
	pv_min := rmin + im.Vec2{6, 6}
	pv_max := im.Vec2{rmax.x - 6, rmin.y + 58}
	im.DrawList_AddRectFilled(dl, pv_min, pv_max, im.GetColorU32ImVec4(tp.bg_panel), 4.0)

	// Mini top bar + active tab with 2px Antigravity overline
	bar_max := im.Vec2{pv_max.x, pv_min.y + 14}
	im.DrawList_AddRectFilled(dl, pv_min, bar_max, im.GetColorU32ImVec4(tp.bg_canvas), 4.0, im.DrawFlags_RoundCornersTop)
	tab_min := im.Vec2{pv_min.x + 8, pv_min.y + 2}
	tab_max := im.Vec2{pv_min.x + 54, bar_max.y}
	im.DrawList_AddRectFilled(dl, tab_min, tab_max, im.GetColorU32ImVec4(tp.bg_panel), 2.0, im.DrawFlags_RoundCornersTop)
	im.DrawList_AddLine(dl, {tab_min.x + 1, tab_min.y + 1}, {tab_max.x - 1, tab_min.y + 1}, im.GetColorU32ImVec4(tp.accent), 2.0)

	// Mini elevated content cards + accent pill inside preview
	c1_min := im.Vec2{pv_min.x + 8, bar_max.y + 6}
	c1_max := im.Vec2{pv_min.x + (pv_max.x - pv_min.x) * 0.56, pv_max.y - 6}
	im.DrawList_AddRectFilled(dl, c1_min, c1_max, im.GetColorU32ImVec4(tp.bg_elevated), 3.0)
	im.DrawList_AddRect(dl, c1_min, c1_max, im.GetColorU32ImVec4(tp.border_subtle), 3.0, 1.0)
	im.DrawList_AddLine(dl, {c1_min.x + 6, c1_min.y + 8}, {c1_max.x - 14, c1_min.y + 8}, im.GetColorU32ImVec4(tp.text_primary), 2.0)
	im.DrawList_AddLine(dl, {c1_min.x + 6, c1_min.y + 15}, {c1_max.x - 26, c1_min.y + 15}, im.GetColorU32ImVec4(tp.text_muted), 2.0)

	// Accent pill & status dots on right half of preview
	pill_min := im.Vec2{c1_max.x + 6, bar_max.y + 6}
	pill_max := im.Vec2{pv_max.x - 8, bar_max.y + 17}
	im.DrawList_AddRectFilled(dl, pill_min, pill_max, im.GetColorU32ImVec4(tp.accent_soft), 3.0)
	im.DrawList_AddRect(dl, pill_min, pill_max, im.GetColorU32ImVec4(tp.accent), 3.0, 1.0)

	dot_y := pv_max.y - 11
	im.DrawList_AddCircleFilled(dl, {pill_min.x + 5,  dot_y}, 3.5, im.GetColorU32ImVec4(tp.accent))
	im.DrawList_AddCircleFilled(dl, {pill_min.x + 16, dot_y}, 3.5, im.GetColorU32ImVec4(tp.status_success))
	im.DrawList_AddCircleFilled(dl, {pill_min.x + 27, dot_y}, 3.5, im.GetColorU32ImVec4(tp.status_warning))
	im.DrawList_AddRect(dl, pv_min, pv_max, im.GetColorU32ImVec4(tp.border_subtle), 4.0, 1.0)

	// Label & active checkmark below preview
	title := thm.display_name(tid)
	im.DrawList_AddText(dl, {rmin.x + 8, pv_max.y + 8}, im.GetColorU32ImVec4(p.text_primary), title)
	if is_cur {
		chk := fmt.ctprintf("%s", icons.ICON_MD_CHECK)
		cw := im.CalcTextSize(chk).x
		im.DrawList_AddText(dl, {rmax.x - cw - 8, pv_max.y + 8}, im.GetColorU32ImVec4(p.accent), chk)
	}

	// Card border
	border_col := is_cur ? p.accent : (hovered ? p.border_strong : p.border_subtle)
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(border_col), rounding, is_cur ? 1.8 : 1.0)
	return clicked
}

@(editor_window={id="editor_visuals", title="Themes & Visuals", icon="PALETTE", width=840, height=700})
editor_visuals_window_draw :: proc() {
	p := thm.palette()

	im.TextColored(p.text_primary, icons.ICON_MD_PALETTE + "  Themes, Clean Studio Geometry & UI Scaling")
	im.TextDisabled("Switch between Antigravity Dark/Light and studio palettes, adjust density & corner geometry, or tune window zoom.")
	im.Separator()
	im.Spacing()

	// ─────────────────────────────────────────────────────────────
	// 1. STUDIO THEMES & ANTIGRAVITY GEOMETRY
	// ─────────────────────────────────────────────────────────────
	if im.CollapsingHeader("Studio Themes & Clean Style", {.DefaultOpen}) {
		im.Spacing()
		avail_w := im.GetContentRegionAvail().x
		cols := avail_w >= 640 ? 4 : 2
		gap  := im.GetStyle().ItemSpacing.x
		card_w := max((avail_w - gap * f32(cols - 1)) / f32(cols), 140.0)

		idx := 0
		for tid in thm.Theme_Id {
			if idx > 0 && (idx % cols) != 0 {
				im.SameLine()
			}
			if _draw_theme_card(tid, card_w) {
				thm.set(tid)
			}
			idx += 1
		}

		im.Spacing()
		im.Separator()
		im.Spacing()

		ui_s := max(im.GetFontSize() / 14.0, 0.6)
		lbl_col_x := 150.0 * ui_s

		// UI Density
		cur_d := thm.density()
		im.AlignTextToFramePadding()
		im.TextColored(p.text_secondary, "UI Density:")
		im.SameLine(lbl_col_x)
		if _choice_pill("Compact", cur_d == .Compact)               do thm.set_density(.Compact)
		im.SameLine()
		if _choice_pill("Clean (Antigravity)", cur_d == .Clean)     do thm.set_density(.Clean)
		im.SameLine()
		if _choice_pill("Spacious", cur_d == .Spacious)             do thm.set_density(.Spacious)

		// Corner Geometry
		cur_c := thm.corners()
		im.AlignTextToFramePadding()
		im.TextColored(p.text_secondary, "Corner Geometry:")
		im.SameLine(lbl_col_x)
		if _choice_pill("Rounded (Default)", cur_c == .Rounded)     do thm.set_corners(.Rounded)
		im.SameLine()
		if _choice_pill("Soft Pill", cur_c == .Soft_Pill)           do thm.set_corners(.Soft_Pill)
		im.SameLine()
		if _choice_pill("Crisp (2px)", cur_c == .Crisp)             do thm.set_corners(.Crisp)

		// Custom Accent Color Override
		use_acc, acc_col := thm.custom_accent_state()
		im.AlignTextToFramePadding()
		im.TextColored(p.text_secondary, "Accent Color:")
		im.SameLine(lbl_col_x)
		if _choice_pill("Theme Default", !use_acc) {
			thm.set_custom_accent(false, acc_col)
			use_acc = false
		}
		im.SameLine()
		Accent_Preset :: struct { name: cstring, col: [4]f32 }
		acc_presets := [?]Accent_Preset{
			{"Antigravity Blue", {0.478, 0.659, 0.973, 1.0}},
			{"Studio Blue",      {0.102, 0.451, 0.910, 1.0}},
			{"Void Lavender",    {0.643, 0.522, 1.000, 1.0}},
			{"Mint Green",       {0.298, 0.765, 0.541, 1.0}},
			{"Warm Amber",       {0.961, 0.694, 0.235, 1.0}},
		}
		for ap, ai in acc_presets {
			im.PushIDInt(i32(ai))
			if im.ColorButton(ap.name, {ap.col[0], ap.col[1], ap.col[2], 1.0}, {}, {20, 20}) {
				thm.set_custom_accent(true, ap.col)
				use_acc = true
				acc_col = ap.col
			}
			im.PopID()
			im.SameLine()
		}
		if im.ColorEdit4("##CustomAccentPicker", &acc_col, {.NoInputs, .NoLabel}) {
			thm.set_custom_accent(true, acc_col)
		}
		im.Spacing()
	}

	im.Spacing()

	// ─────────────────────────────────────────────────────────────
	// 2. MAIN UI SCALE (GLOBAL)
	// ─────────────────────────────────────────────────────────────
	if im.CollapsingHeader("Main UI Scale (Global)", {.DefaultOpen}) {
		main_scale := wnd.get_main_scale()
		im.TextColored(p.text_secondary, "Global Scale Factor:")
		im.SameLine()
		im.TextDisabled("(Scales default editor text, dock panels, and all windows)")

		if im.SliderFloat("##MainScaleSlider", &main_scale, 0.6, 2.5, "%.2fx") {
			wnd.set_main_scale(main_scale)
		}
		im.SameLine()
		if im.Button("Reset Global##ResetMain") {
			wnd.set_main_scale(1.0)
		}

		im.Spacing()
		im.TextDisabled("Quick Presets:")
		im.SameLine()
		if _choice_pill("Small (0.85x)", abs(main_scale - 0.85) < 0.02)       do wnd.set_main_scale(0.85)
		im.SameLine()
		if _choice_pill("Default (1.00x)", abs(main_scale - 1.00) < 0.02)     do wnd.set_main_scale(1.00)
		im.SameLine()
		if _choice_pill("Medium (1.15x)", abs(main_scale - 1.15) < 0.02)      do wnd.set_main_scale(1.15)
		im.SameLine()
		if _choice_pill("Large (1.30x)", abs(main_scale - 1.30) < 0.02)       do wnd.set_main_scale(1.30)
		im.SameLine()
		if _choice_pill("Extra Large (1.50x)", abs(main_scale - 1.50) < 0.02) do wnd.set_main_scale(1.50)
		im.SameLine()
		if _choice_pill("HiDPI (1.75x)", abs(main_scale - 1.75) < 0.02)       do wnd.set_main_scale(1.75)

		im.Spacing()
		im.TextColored(p.accent, icons.ICON_MD_INFO + "  Zoom Shortcut:")
		im.SameLine()
		im.TextDisabled("Hold Ctrl and roll your Mouse Wheel over any window to smoothly zoom in or out.")
	}

	im.Spacing()

	// ─────────────────────────────────────────────────────────────
	// 3. PER-WINDOW INDIVIDUAL SCALING
	// ─────────────────────────────────────────────────────────────
	if im.CollapsingHeader("Per-Window Individual Scaling") {
		im.TextColored(p.text_secondary, "Independent Window Tuning:")
		im.SameLine()
		im.TextDisabled("Each tool/window can have its own independent magnification.")

		if im.Button(fmt.ctprintf("%s  Reset All Window Scales", icons.ICON_MD_REFRESH)) {
			wnd.reset_all_scales()
		}

		im.Spacing()
		ui_s_tbl := max(im.GetFontSize() / 14.0, 0.6)
		reg_list := wnd.registered()
		table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter | im.TableFlags_BordersInnerH
		if im.BeginTable("##PerWindowScaleTable", 4, table_flags) {
			im.TableSetupColumn("Window / Tool", {.WidthStretch})
			im.TableSetupColumn("Window Scale Multiplier", {.WidthFixed}, 220.0 * ui_s_tbl)
			im.TableSetupColumn("Effective Size", {.WidthFixed}, 115.0 * ui_s_tbl)
			im.TableSetupColumn("Action", {.WidthFixed}, 76.0 * ui_s_tbl)
			im.TableHeadersRow()

			for item, i in reg_list {
				im.PushIDInt(i32(i))
				im.TableNextRow()

				im.TableNextColumn()
				im.TextUnformatted(fmt.ctprintf("%s", item.title))
				im.SameLine()
				im.TextDisabledUnformatted(fmt.ctprintf("[%s]", item.id))

				im.TableNextColumn()
				win_scale := wnd.get_window_scale(item.id)
				if im.SliderFloat("##WinScaleSlider", &win_scale, 0.6, 2.5, "%.2fx") {
					wnd.set_window_scale(item.id, win_scale)
				}

				im.TableNextColumn()
				eff_scale := wnd.get_effective_scale(item.id)
				if abs(eff_scale - 1.0) > 0.01 {
					im.TextColoredUnformatted(p.status_success, fmt.ctprintf("%.2fx", eff_scale))
				} else {
					im.TextDisabledUnformatted(fmt.ctprintf("%.2fx (100%%)", eff_scale))
				}

				im.TableNextColumn()
				if im.Button("Reset") {
					wnd.reset_window_scale(item.id)
				}

				im.PopID()
			}

			im.EndTable()
		}
	}

	im.Spacing()

	// ─────────────────────────────────────────────────────────────
	// 4. OBJECT SELECTION OUTLINE & GIZMO VISUALS (SCENE VIEW)
	// ─────────────────────────────────────────────────────────────
	if im.CollapsingHeader("Object Selection Outline (Scene View)") {
		im.TextColored(p.text_secondary, "Selection Wireframe & Outline Styling:")
		im.TextDisabled("Configures how selected objects are highlighted in the Scene viewport.")

		im.Spacing()
		im.AlignTextToFramePadding()
		im.Text("Outline Color:")
		im.SameLine(0, 10)
		im.ColorEdit4("##OutlineColor", &ev.settings.outline_color, {.NoInputs})
		im.SameLine(0, 8)
		if im.Button("Reset Color##ResetOutCol") {
			ev.settings.outline_color = {1.0, 0.60, 0.10, 1.0}
		}

		im.Spacing()
		im.SetNextItemWidth(260)
		im.SliderFloat("Outline Margin / Scale", &ev.settings.outline_scale, 1.00, 1.25, "%.2fx")
		im.SameLine()
		im.TextDisabled("(1.00x = exact bound, 1.02x+ avoids z-fighting)")

		im.SetNextItemWidth(260)
		im.SliderFloat("Outline Line Thickness", &ev.settings.outline_thickness, 1.0, 3.0, "%.1fpx")
		im.SameLine()
		im.TextDisabled("(1.0px = standard, 2.0px = bold)")

		im.SetNextItemWidth(260)
		im.SliderFloat("Empty Object Cross Size", &ev.settings.outline_cross_size, 0.2, 2.0, "%.2f units")
		im.SameLine()
		im.TextDisabled("(Size of the 3D axis cross on empty objects)")
	}

	im.Spacing()

	// ─────────────────────────────────────────────────────────────
	// 5. FOLDER COLOR MARKINGS
	// ─────────────────────────────────────────────────────────────
	if im.CollapsingHeader("Folder Color Markings") {
		im.Checkbox("Enable Custom Folder Colors in Project Browser", &ev.settings.enable_folder_colors)
		im.TextDisabled("   Folders in Void File Explorer are tinted calmly using their assigned tag color.")

		im.Spacing()
		im.TextColored(p.text_secondary, "Assign Color to Folder:")
		im.InputTextWithHint("##NewFolderKey", "Folder keyword (e.g. 'void_odin', 'assets')", cstring(&_new_folder_buf[0]), len(_new_folder_buf))
		im.SameLine()
		im.ColorEdit4("##NewFolderCol", &_new_folder_color, {.NoInputs})
		im.SameLine()
		if im.Button("+ Add / Update Color") {
			name := strings.trim_right_null(string(_new_folder_buf[:]))
			if len(name) > 0 {
				ev.set_folder_color(name, _new_folder_color)
				_new_folder_buf[0] = 0
			}
		}

		im.Spacing()
		im.TextDisabled("Color presets: ")
		im.SameLine()
		if im.Button("Blue")     do _new_folder_color = {0.48, 0.66, 0.97, 1.0}
		im.SameLine()
		if im.Button("Lavender") do _new_folder_color = {0.64, 0.52, 1.00, 1.0}
		im.SameLine()
		if im.Button("Mint")     do _new_folder_color = {0.30, 0.76, 0.54, 1.0}
		im.SameLine()
		if im.Button("Amber")    do _new_folder_color = {0.96, 0.69, 0.24, 1.0}
		im.SameLine()
		if im.Button("Teal")     do _new_folder_color = {0.32, 0.76, 0.86, 1.0}
		im.SameLine()
		if im.Button("Coral")    do _new_folder_color = {0.95, 0.42, 0.45, 1.0}

		im.Spacing()
		ui_s_fc := max(im.GetFontSize() / 14.0, 0.6)
		table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter | im.TableFlags_BordersInnerH
		if im.BeginTable("##FolderColorsTable", 4, table_flags) {
			im.TableSetupColumn("Folder Name / Keyword", {.WidthStretch})
			im.TableSetupColumn("Color Tag", {.WidthFixed}, 110.0 * ui_s_fc)
			im.TableSetupColumn("Edit Color", {.WidthFixed}, 160.0 * ui_s_fc)
			im.TableSetupColumn("Action", {.WidthFixed}, 74.0 * ui_s_fc)
			im.TableHeadersRow()

			entries := ev.get_all_folder_colors()
			for i in 0 ..< len(entries) {
				entry := entries[i]
				im.PushIDInt(i32(i))
				im.TableNextRow()

				im.TableNextColumn()
				im.TextColored(thm.adapt_badge_color(entry.color), "%s", fmt.ctprintf("%s", entry.folder_key))

				im.TableNextColumn()
				im.ColorButton("##swatch", entry.color, {.NoTooltip})

				im.TableNextColumn()
				cur_col := entry.color
				if im.ColorEdit4("##picker", &cur_col, {.NoInputs}) {
					ev.set_folder_color(entry.folder_key, cur_col)
				}

				im.TableNextColumn()
				if im.Button("Remove") {
					ev.clear_folder_color(entry.folder_key)
					im.PopID()
					break
				}

				im.PopID()
			}
			im.EndTable()
		}
	}

	im.Spacing()

	// ─────────────────────────────────────────────────────────────
	// 6. BUNDLED SHARED FONT (SEGOE UI)
	// ─────────────────────────────────────────────────────────────
	if im.CollapsingHeader("Bundled Shared Font (TrueType)") {
		im.TextColoredUnformatted(p.accent, fmt.ctprintf("Bundled Font: %s", ev.get_shared_font_name()))
		im.TextDisabled("Location: haati/editor/editor_visuals/assets/fonts/segoeui.ttf")
		im.TextDisabledUnformatted(fmt.ctprintf("File Size: %d bytes (~975 KB TrueType with full Unicode Latin & Greek coverage)", len(ev.get_shared_font_data())))
		im.Spacing()
		im.TextWrappedUnformatted("This font is bundled directly into the Editor Visuals plugin so other plugins can load it without requiring separate font files.")
		im.TextDisabled("Plugin API usage: data := editor_visuals.get_shared_font_data()")
	}
}

@(menu_item={path="Window/Themes & Visuals", shortcut=""})
editor_visuals_window_open :: proc() {
	wnd.open("editor_visuals")
}
