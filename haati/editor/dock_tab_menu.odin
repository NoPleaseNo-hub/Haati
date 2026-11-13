package editor

// Unity's tab context menu: a menu button pinned to the right of every dock
// node's tab bar, opening actions for the tab that node is showing.
//
// imgui's own dock-node buttons are both off (apply_theme, menu_content.odin):
// its close-all button closes every docked view at once, and its window-menu
// button's contents come from a handler that imgui reinstalls after startup,
// so neither is usable here. The button below is a real tab item
// (TabItemButton with Trailing) appended to the node's tab bar through
// DockNodeBeginAmendTabBar, which puts its look and its menu under our
// control.

import "base:runtime"
import im "haati:external/odin-imgui"
import "menu"
import "inspector"
import wnd "haati:editor/window"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import "core:fmt"
import "core:strconv"
import "core:strings"

@(private = "file")
_context_tab_title: cstring

// Walk the dockspace tree and give every leaf node a menu button. Call from
// the dockspace host window, after im.DockSpace.
tab_menu_draw_all :: proc(root: ^im.DockNode) {
	if root == nil do return
	if root.ChildNodes[0] == nil && root.ChildNodes[1] == nil {
		_tab_menu_node(root)
		return
	}
	tab_menu_draw_all(root.ChildNodes[0])
	tab_menu_draw_all(root.ChildNodes[1])
}

// Walks all standalone floating DockNodes (when 2+ windows are joined together
// outside the main dockspace) so joined floating windows get full right-side
// Dock-In, Maximize/Restore, Menu, and Close-Tab buttons!
tab_menu_draw_floating_nodes :: proc() {
	ids := wnd.consume_floating_dock_ids(context.temp_allocator)
	if len(ids) == 0 do return
	visited_roots := make([dynamic]im.ID, 0, len(ids), context.temp_allocator)
	for id in ids {
		n := im.DockBuilderGetNode(id)
		if n == nil do continue
		root := n
		for root.ParentNode != nil do root = root.ParentNode
		if !im.DockNode_IsFloatingNode(root) do continue
		seen := false
		for vr in visited_roots {
			if vr == root.ID_ { seen = true; break }
		}
		if !seen {
			append(&visited_roots, root.ID_)
			tab_menu_draw_all(root)
		}
	}
}

// The popup id must be unique per node, or every node's button opens the same
// popup. Built from the node id, which is stable across frames.
@(private = "file")
_popup_id :: proc(node: ^im.DockNode) -> cstring {
	return fmt.ctprintf("##tabmenu_%d", node.ID_)
}

@(private = "file")
_tab_menu_node :: proc(node: ^im.DockNode) {
	if node.TabBar == nil || node.HostWindow == nil do return
	// An empty node has no tab to act on. A node whose tab bar is hidden
	// (single window, tab bar collapsed) has no bar to put the button on.
	if node.Windows.Size == 0 do return

	popup := _popup_id(node)
	tab_bar := node.TabBar
	active_title: cstring
	if node.VisibleWindow != nil do active_title = node.VisibleWindow.Name
	is_floating := im.DockNode_IsFloatingNode(node)

	// Drawn in the host window at the FAR RIGHT of the tab bar rect, past
	// where tabs flow, so it reads as chrome on the bar rather than as
	// another tab. A plain InvisibleButton carries the click; the look is
	// drawn by hand (no tab shape, no frame) — hover only tints the square.
	im.Begin(node.HostWindow.Name)
	{
		bar := tab_bar.BarRect
		size := im.GetFrameHeight()
		style := im.GetStyle()
		right := node.Pos.x + node.Size.x - style.WindowBorderSize

		root_node := node
		for root_node.ParentNode != nil do root_node = root_node.ParentNode
		is_floating_corner := is_floating &&
			abs((node.Pos.x + node.Size.x) - (root_node.Pos.x + root_node.Size.x)) < 6.0 &&
			abs(node.Pos.y - root_node.Pos.y) < 6.0

		// Layout right-to-left:
		// Docked inside main workspace: [Undock] [Menu]
		// Joined Floating OS Window:    [Return Tab] [Maximize/Restore] [Menu] [Close Tab]
		close_bmin := im.Vec2{right - size, bar.Min.y}
		bmin       := is_floating_corner ? im.Vec2{right - 2 * size - 2.0, bar.Min.y} : im.Vec2{right - size, bar.Min.y}
		max_bmin   := im.Vec2{bmin.x - size - 2.0, bar.Min.y}
		undock_bmin := is_floating_corner ? im.Vec2{max_bmin.x - size - 2.0, bar.Min.y} : im.Vec2{bmin.x - size, bar.Min.y}
		req_w := is_floating_corner ? size * 4.5 : size * 2.0

		// Nothing to click if the bar is too narrow for the buttons.
		if bar.Max.x - bar.Min.x > req_w {
			dl := im.GetWindowDrawList()

			// 1. Undock / Return Button (pop out as floating OS window, or return to main dock)
			undock_id := fmt.ctprintf("##tabundock_%d", node.ID_)
			im.SetCursorScreenPos(undock_bmin)
			undock_clicked := im.InvisibleButton(undock_id, {size, size})
			undock_hovered := im.IsItemHovered({})
			widgets.tooltip(is_floating ? "Return active tab to main editor window" : "Dock out as external floating window")
			if undock_clicked && active_title != nil {
				if is_floating {
					wnd.reunite(active_title)
				} else {
					wnd.pop_out(active_title)
				}
			}
			if is_floating_corner {
				ubg := undock_hovered ? im.GetColorU32ImVec4({0.28, 0.50, 0.80, 1.0}) : im.GetColorU32ImVec4({0.22, 0.32, 0.46, 0.85})
				im.DrawList_AddRectFilled(dl, undock_bmin, undock_bmin + {size, size}, ubg, 2.0)
			} else if undock_hovered {
				im.DrawList_AddRectFilled(dl, undock_bmin, undock_bmin + {size, size}, im.GetColorU32(.ButtonHovered), 3)
			}
			undock_icon: cstring = is_floating ? icons.ICON_MD_DOCK : icons.ICON_MD_OPEN_IN_NEW
			undock_glyph_sz := im.CalcTextSize(undock_icon, nil, false, -1)
			undock_glyph_pos := undock_bmin + (im.Vec2{size, size} - undock_glyph_sz) * 0.5
			undock_col_u32 := is_floating_corner \
				? im.GetColorU32ImVec4({0.94, 0.97, 1.0, 1.0}) \
				: im.GetColorU32(undock_hovered ? .Text : .TextDisabled)
			im.DrawList_AddText(dl, undock_glyph_pos, undock_col_u32, undock_icon)

			// 1b. Maximize / Restore Button on Joined Floating OS Windows
			if is_floating_corner {
				max_id := fmt.ctprintf("##tabmax_%d", node.ID_)
				im.SetCursorScreenPos(max_bmin)
				max_clicked := im.InvisibleButton(max_id, {size, size})
				max_hovered := im.IsItemHovered({})
				is_max := wnd.is_dock_node_maximized(node)
				widgets.tooltip(is_max ? "Restore Joined Window Size" : "Maximize Joined Window")
				if max_clicked {
					wnd.toggle_maximize_dock_node(node)
				}
				mbg := max_hovered ? im.GetColorU32ImVec4({0.26, 0.46, 0.58, 1.0}) : im.GetColorU32ImVec4({0.20, 0.25, 0.34, 0.88})
				im.DrawList_AddRectFilled(dl, max_bmin, max_bmin + {size, size}, mbg, 2.0)
				wnd.draw_maximize_restore_icon(dl, max_bmin, max_bmin + {size, size}, is_max, im.GetColorU32ImVec4({0.92, 0.96, 1.0, 0.96}))
			}

			// 2. Menu Button (...)
			origin_prev := widgets.ui_origin_push(_window_origin(active_title))
			im.SetCursorScreenPos(bmin)
			clicked := im.InvisibleButton(popup, {size, size})
			hovered := im.IsItemHovered({})
			widgets.tooltip("Tab & Window Options")
			widgets.ui_origin_pop(origin_prev)
			if clicked {
				_context_tab_title = active_title
				im.OpenPopup(popup)
			}

			if hovered {
				im.DrawList_AddRectFilled(dl, bmin, bmin + {size, size}, im.GetColorU32(.ButtonHovered), 3)
			}
			glyph_sz := im.CalcTextSize(icons.ICON_MD_MENU, nil, false, -1)
			glyph_pos := bmin + (im.Vec2{size, size} - glyph_sz) * 0.5
			col: im.Col = hovered ? .Text : .TextDisabled
			im.DrawList_AddText(dl, glyph_pos, im.GetColorU32(col), icons.ICON_MD_MENU)

			// 2b. Close Active Tab Button on Joined Floating OS Windows
			if is_floating_corner {
				close_id := fmt.ctprintf("##tabclose_%d", node.ID_)
				im.SetCursorScreenPos(close_bmin)
				close_clicked := im.InvisibleButton(close_id, {size, size})
				close_hovered := im.IsItemHovered({})
				widgets.tooltip("Close Active Tab")
				if close_clicked && active_title != nil {
					close_editor_view(active_title)
				}
				cbg := close_hovered ? im.GetColorU32ImVec4({0.96, 0.22, 0.22, 1.0}) : im.GetColorU32ImVec4({0.80, 0.16, 0.16, 0.90})
				im.DrawList_AddRectFilled(dl, close_bmin, close_bmin + {size, size}, cbg, 2.0)
				cc := close_bmin + {size * 0.5, size * 0.5}
				cr := size * 0.20
				white := im.GetColorU32ImVec4({1.0, 1.0, 1.0, 1.0})
				im.DrawList_AddLine(dl, {cc.x - cr, cc.y - cr}, {cc.x + cr, cc.y + cr}, white, 2.0)
				im.DrawList_AddLine(dl, {cc.x - cr, cc.y + cr}, {cc.x + cr, cc.y - cr}, white, 2.0)
			}

			// 3. Hover & Right-Click on any Dock Tab in `tab_bar.Tabs` -> Focus Tab + Open Tab / Script Inspector Menu!
			if tab_bar.Tabs.Size > 0 {
				mp := im.GetMousePos()
				if mp.y >= bar.Min.y && mp.y <= bar.Max.y && mp.x >= bar.Min.x && mp.x < undock_bmin.x {
					tabs := ([^]im.TabItem)(tab_bar.Tabs.Data)[:tab_bar.Tabs.Size]
					for &tab in tabs {
						if transmute(i32)tab.Flags & _TAB_ITEM_FLAG_BUTTON != 0 do continue
						tx0 := max(bar.Min.x, bar.Min.x + tab.Offset - tab_bar.ScrollingAnim)
						tx1 := min(undock_bmin.x, bar.Min.x + tab.Offset - tab_bar.ScrollingAnim + tab.Width)
						if mp.x >= tx0 && mp.x <= tx1 {
							tab_title: cstring = tab.Window_.Name if tab.Window_ != nil else im.TabBarGetTabName(tab_bar, &tab)
							if widgets.ui_debug_tooltips && !im.IsPopupOpen("", im.PopupFlags_AnyPopupId) {
								t_orig := widgets.ui_origin_push(_window_origin(tab_title))
								widgets.tooltip_unchecked(im.TabBarGetTabName(tab_bar, &tab))
								widgets.ui_origin_pop(t_orig)
							}
							if im.IsMouseClicked(.Right) {
								if tab.ID_ != tab_bar.SelectedTabId {
									im.TabBarQueueFocus(tab_bar, &tab)
								}
								_context_tab_title = tab_title
								im.OpenPopup(popup)
							}
							break
						}
					}
				}
			}

			// The visible tab's toolbar items, left of the undock button.
			if active_title != nil {
				bar_h := bar.Max.y - bar.Min.y
				INSET :: f32(4)
				pad_y := max((bar_h - im.GetFontSize() - INSET) * 0.5, 0)
				im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
				im.PushStyleVarImVec2(.FramePadding, {style.FramePadding.x, pad_y})
				im.PushStyleVar(.FrameRounding, 3) // matches the menu button's hover
				im.PushIDInt(i32(node.ID_))

				view := view_id_of(active_title)
				items_w := view_tab_bar_width(view)
				if items_w > 0 && undock_bmin.x - items_w - style.ItemSpacing.x > bar.Min.x + tab_bar.WidthAllTabs {
					item_h := im.GetFrameHeight()
					y := bar.Min.y + max((bar_h - item_h) * 0.5, 0)
					im.SetCursorScreenPos({undock_bmin.x - items_w, y})
					view_tab_bar_draw(view)
				}

				im.PopID()
				im.PopStyleVar(2)
				im.PopStyleColor()
			}
		}

		if im.BeginPopup(popup, {}) {
			_tab_menu_contents(node)
			im.EndPopup()
		}
	}
	im.End()
}

@(private = "file")
_builtin_view_loc :: proc(title: cstring) -> (loc: runtime.Source_Code_Location, ok: bool) {
	switch title {
	case icons.TITLE_SCENE, icons.ICON_MD_LANDSCAPE + " Scene3D *###Scene":
		return #location(draw_scene_view), true
	case icons.TITLE_SCENE_2D:
		return #location(draw_scene_2d_view), true
	case icons.TITLE_GAME:
		return #location(draw_game_view), true
	case icons.TITLE_INSPECTOR:
		return #location(draw_hierarchy_inspector), true
	case icons.TITLE_PROJECT_INSPECTOR:
		return #location(inspector.view_inspector_draw), true
	case icons.TITLE_CONSOLE:
		return #location(draw_console_view), true
	case icons.TITLE_OUTPUT:
		return #location(draw_output_view), true
	case icons.TITLE_HISTORY:
		return #location(draw_history_view), true
	}
	return {}, false
}

// The @(editor_window) or built-in view origin behind the tab whose imgui window title is `title`.
@(private = "file")
_window_origin :: proc(title: cstring) -> string {
	if title == nil do return ""
	s := string(title)
	if idx := strings.last_index(s, "###"); idx >= 0 {
		if orig := wnd.origin_of(s[idx + 3:]); len(orig) > 0 {
			return orig
		}
	}
	if loc, ok := _builtin_view_loc(title); ok {
		return fmt.tprintf("built-in view  %s:%d  %s", loc.file_path, loc.line, loc.procedure)
	}
	return ""
}

@(private = "file")
_parse_origin_file_line :: proc(origin: string) -> (file: string, line: int, proc_name: string, ok: bool) {
	if len(origin) == 0 do return "", 0, "", false
	parts := strings.split(origin, "  ", context.temp_allocator)
	if len(parts) < 2 do return "", 0, "", false
	fl := parts[1]
	colon := strings.last_index_byte(fl, ':')
	if colon <= 0 || colon + 1 >= len(fl) do return "", 0, "", false
	l, lok := strconv.parse_int(fl[colon + 1:])
	if !lok || l <= 0 do return "", 0, "", false
	p_name := parts[2] if len(parts) >= 3 else ""
	return fl[:colon], l, p_name, true
}

// Close the view whose imgui window title is `title`: a built-in view clears
// its open flag, a plugin window closes by id. Titles are "<icon> Name###id",
// and a plugin window's id is the text after "###".
close_editor_view :: proc(title: cstring) {
	if title == nil do return
	if flag := menu.view_show_flag(title); flag != nil {
		flag^ = false
		return
	}
	s := string(title)
	if idx := strings.last_index(s, "###"); idx >= 0 {
		wnd.close(s[idx + 3:])
		return
	}
	wnd.close(s)
}

@(private = "file")
_tab_menu_contents :: proc(node: ^im.DockNode) {
	// Acts on the tab right-clicked (or the tab the node is currently showing).
	active_title: cstring = _context_tab_title
	if active_title == nil && node.VisibleWindow != nil {
		active_title = node.VisibleWindow.Name
	}
	is_floating := im.DockNode_IsFloatingNode(node)

	if active_title != nil {
		// Clean display name (strip "###id")
		raw_s := string(active_title)
		disp_s := raw_s
		if h_idx := strings.last_index(raw_s, "###"); h_idx >= 0 {
			disp_s = raw_s[:h_idx]
		}
		p := thm.palette()
		im.TextColored(p.accent, strings.clone_to_cstring(disp_s, context.temp_allocator))
		im.Separator()

		// The visible view's OWN options first: they are what this menu is for,
		// and the tab actions below are the same on every view.
		if view_menu_draw_items(view_id_of(active_title)) {
			im.Separator()
		}

		// Script Inspector section for this Window / Tab!
		orig := _window_origin(active_title)
		if f_path, f_line, f_proc, ok := _parse_origin_file_line(orig); ok {
			im.TextColored(p.text_secondary, "Script Inspector")
			if len(f_proc) > 0 {
				im.TextDisabled(fmt.ctprintf("%s:%d (%s)", f_path, f_line, f_proc))
			} else {
				im.TextDisabled(fmt.ctprintf("%s:%d", f_path, f_line))
			}
			if im.MenuItem(fmt.ctprintf("%s  Inspect Window Code (.odin)", icons.ICON_MD_CODE)) {
				if widgets.open_source_in_ide_fn != nil {
					widgets.open_source_in_ide_fn(f_path, f_line)
				}
			}
			if im.MenuItem(fmt.ctprintf("%s  Copy Script Path & Line", icons.ICON_MD_CONTENT_COPY)) {
				im.SetClipboardText(fmt.ctprintf("%s:%d", f_path, f_line))
			}
			im.Checkbox("Always Show Script Info in Tooltips", &widgets.ui_debug_tooltips)
			im.Separator()
		}

		if is_floating {
			if im.MenuItem(fmt.ctprintf("%s  Return to Main Window", icons.ICON_MD_DOCK)) {
				wnd.reunite(active_title)
			}
		} else {
			if im.MenuItem(fmt.ctprintf("%s  Dock Out Window", icons.ICON_MD_OPEN_IN_NEW)) {
				wnd.pop_out(active_title)
			}
		}
		if im.MenuItem(fmt.ctprintf("%s  Close Tab", icons.ICON_MD_CLOSE)) {
			close_editor_view(active_title)
		}
		im.Separator()
	}

	// The editor keeps one tab per view at a saved place, so this opens a
	// view rather than adding a tab — it mirrors the main Window menu, minus
	// the entries that are editor-wide rather than per-tab.
	if im.BeginMenu("Window") {
		menu.draw_menu_subtree_except("Window", {"Theme", "Reset Layout"})
		im.EndMenu()
	}

	// The node's own tabs, to switch between them.
	tab_bar := node.TabBar
	if tab_bar != nil && tab_bar.Tabs.Size > 1 {
		im.Separator()
		tabs := ([^]im.TabItem)(tab_bar.Tabs.Data)[:tab_bar.Tabs.Size]
		for &tab in tabs {
			// ImGuiTabItemFlags_Button, private to imgui: a tab acting as a
			// button, not a window to switch to.
			if transmute(i32)tab.Flags & _TAB_ITEM_FLAG_BUTTON != 0 do continue
			name := im.TabBarGetTabName(tab_bar, &tab)
			if im.Selectable(name, tab.ID_ == tab_bar.SelectedTabId) {
				im.TabBarQueueFocus(tab_bar, &tab)
			}
		}
	}
}

// ImGuiTabItemFlags_Button (1<<21) — private to imgui, not in the bindings.
@(private = "file")
_TAB_ITEM_FLAG_BUTTON :: i32(1 << 21)
