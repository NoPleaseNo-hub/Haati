package editor

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"
import im "haati:external/odin-imgui"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import gfx "../engine/gfx"
import "../engine"
import "../engine/registration"

@(private = "file")
_Picker_Purpose :: enum {
	Open_Project,
	New_Project_Parent,
}

@(private = "file")
_Hub_Workspace_Entry :: struct {
	name: string,
	path: string,
}

@(private = "file")
_picker: struct {
	mu:      sync.Mutex,
	open:    bool,
	ready:   bool,
	purpose: _Picker_Purpose,
	path:    string,
}

@(private = "file")
_hub: struct {
	initialized:        bool,
	modal_open:         bool,
	modal_open_pending: bool,
	search_buf:         [128]u8,
	browse_path_buf:    [512]u8,
	new_name_buf:       [128]u8,
	new_parent_buf:     [512]u8,
	status_msg:         [512]u8,
	status_is_error:    bool,
	launcher_loaded:    bool,
	launcher_cfg:       engine.Launcher_Config,
	workspace_scanned:  bool,
	workspace_projects: [dynamic]_Hub_Workspace_Entry,
	zoom:               f32,
	modal_zoom_resized: bool,
}

@(private = "file")
_set_buf :: proc(buf: []u8, text: string) {
	mem.zero(raw_data(buf), len(buf))
	if text == "" || len(buf) <= 1 do return
	n := min(len(text), len(buf) - 1)
	copy(buf[:n], text[:n])
}

@(private = "file")
_buf_str :: proc(buf: []u8) -> string {
	return strings.trim_space(string(cstring(raw_data(buf))))
}

@(private = "file")
_set_status :: proc(msg: string, is_error: bool) {
	_set_buf(_hub.status_msg[:], msg)
	_hub.status_is_error = is_error
}

@(private = "file")
_folder_dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	_ = userdata
	_ = filter
	context = runtime.default_context()
	sync.mutex_lock(&_picker.mu)
	defer sync.mutex_unlock(&_picker.mu)
	_picker.open = false
	if filelist != nil && filelist[0] != nil {
		raw_s := string(filelist[0])
		if raw_s != "" {
			if _picker.path != "" {
				delete(_picker.path, runtime.default_allocator())
				_picker.path = ""
			}
			trimmed := strings.trim_right(raw_s, "/\\")
			norm, _ := strings.replace_all(trimmed, "\\", "/", runtime.default_allocator())
			_picker.path = norm
			_picker.ready = true
		}
	}
}

@(private = "file")
_open_folder_picker :: proc(purpose: _Picker_Purpose, default_dir: string) {
	sync.mutex_lock(&_picker.mu)
	already_open := _picker.open
	if !already_open {
		_picker.open = true
		_picker.ready = false
		_picker.purpose = purpose
	}
	sync.mutex_unlock(&_picker.mu)
	if already_open do return

	loc: cstring = nil
	if default_dir != "" && os.is_dir(default_dir) {
		loc = strings.clone_to_cstring(default_dir, context.temp_allocator)
	}
	sdl.ShowOpenFolderDialog(_folder_dialog_cb, nil, gfx.window(), loc, false)
}

@(private = "file")
_default_umbrella_dir :: proc(allocator := context.temp_allocator) -> string {
	eng := engine.engine_root(context.temp_allocator)
	if eng == "" do return ""
	parent: string
	{
		context.allocator = context.temp_allocator
		parent = filepath.dir(eng)
	}
	norm, _ := strings.replace_all(parent, "\\", "/", allocator)
	return strings.trim_right(norm, "/")
}

@(private = "file")
_clear_workspace_projects :: proc() {
	for e in _hub.workspace_projects {
		delete(e.name, runtime.default_allocator())
		delete(e.path, runtime.default_allocator())
	}
	clear(&_hub.workspace_projects)
}

@(private = "file")
_refresh_launcher_and_workspace :: proc() {
	engine.launcher_free_config(&_hub.launcher_cfg, runtime.default_allocator())
	_hub.launcher_cfg = engine.launcher_load_config("", runtime.default_allocator())
	_hub.launcher_loaded = true

	_clear_workspace_projects()
	_hub.workspace_scanned = true

	umbrella := _default_umbrella_dir(context.temp_allocator)
	if umbrella == "" || !os.is_dir(umbrella) do return

	eng_root := engine.engine_root(context.temp_allocator)
	h, err := os.open(umbrella)
	if err != nil do return
	defer os.close(h)
	entries, rerr := os.read_dir(h, -1, context.temp_allocator)
	if rerr != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for e in entries {
		if e.type != .Directory || strings.has_prefix(e.name, ".") do continue
		switch e.name {
		case "Agent_Docs", "Engine_Backups", "Haati_Engine":
			continue
		}
		full, _ := filepath.join({umbrella, e.name}, context.temp_allocator)
		norm, _ := strings.replace_all(full, "\\", "/", context.temp_allocator)
		norm = strings.trim_right(norm, "/")
		if engine.paths_equal(norm, eng_root) do continue
		// Wait: only inspect top-level markers/manifest, never traverse inside Void_Odin.
		if !engine.project_is_valid_dir(norm) do continue

		in_recents := false
		for r in _hub.launcher_cfg.recent_projects {
			if engine.paths_equal(r.path, norm) {
				in_recents = true
				break
			}
		}
		if in_recents do continue

		disp := engine.project_read_display_name(norm, context.temp_allocator)
		append(&_hub.workspace_projects, _Hub_Workspace_Entry{
			name = strings.clone(disp, runtime.default_allocator()),
			path = strings.clone(norm, runtime.default_allocator()),
		})
	}
}

@(private = "file")
_ensure_hub_init :: proc() {
	if !_hub.initialized {
		_hub.initialized = true
		_hub.zoom = 1.20
		_hub.workspace_projects = make([dynamic]_Hub_Workspace_Entry, runtime.default_allocator())
		_set_buf(_hub.new_name_buf[:], "MyHaatiGame")
		if umb := _default_umbrella_dir(context.temp_allocator); umb != "" {
			_set_buf(_hub.new_parent_buf[:], umb)
		}
	}
	if !_hub.launcher_loaded || !_hub.workspace_scanned {
		_refresh_launcher_and_workspace()
	}
}

@(private = "file")
_try_open_project :: proc(dir: string) {
	ok, err := open_or_switch_project(dir)
	if !ok {
		_set_status(err, true)
	} else if relaunch_pending() {
		_set_status("Building project gameplay code... Haati Editor will restart into the project.", false)
	}
}

@(private = "file")
_poll_folder_picker :: proc() {
	picked := ""
	purpose: _Picker_Purpose
	sync.mutex_lock(&_picker.mu)
	if _picker.ready {
		picked = strings.clone(_picker.path, context.temp_allocator)
		purpose = _picker.purpose
		_picker.ready = false
	}
	sync.mutex_unlock(&_picker.mu)
	if picked == "" do return

	switch purpose {
	case .Open_Project:
		_set_buf(_hub.browse_path_buf[:], picked)
		if engine.project_is_valid_dir(picked) {
			_try_open_project(picked)
		} else {
			_set_status("Selected folder has no haati.project or assets/ yet — click 'Open Folder' anyway if intentional.", false)
		}
	case .New_Project_Parent:
		_set_buf(_hub.new_parent_buf[:], picked)
		_set_buf(_hub.status_msg[:], "")
	}
}

project_hub_open_modal :: proc() {
	_ensure_hub_init()
	_refresh_launcher_and_workspace()
	_set_buf(_hub.status_msg[:], "")
	_hub.modal_open = true
	_hub.modal_open_pending = true
}

@(menu_item={path="File/Project Hub (New & Open)...", order=-100, shortcut="Ctrl+Shift+O"})
file_project_hub_menu :: proc() {
	project_hub_open_modal()
}

@(private = "file")
_draw_project_row :: proc(
	id_prefix: string,
	name: string,
	path: string,
	exists_on_disk: bool,
	is_active: bool,
	can_remove: bool,
) {
	p := thm.palette()
	needs_rebuild := exists_on_disk && relaunch_needs_project_rebuild(path)

	im.PushID(fmt.ctprintf("%s_%s", id_prefix, path))
	defer im.PopID()

	im.PushStyleColorImVec4(.ChildBg, p.bg_elevated)
	row_h := max(im.GetFrameHeight() * 2.55, 52.0)
	if im.BeginChild("##proj_card", {0, row_h}, {.Borders}) {
		im.AlignTextToFramePadding()
		if is_active {
			im.TextColoredUnformatted(p.status_success, fmt.ctprintf("%s  %s  [Active]", icons.ICON_MD_FOLDER_OPEN, name))
		} else if !exists_on_disk {
			im.TextColoredUnformatted(p.status_error, fmt.ctprintf("%s  %s  [Missing]", icons.ICON_MD_WARNING, name))
		} else {
			im.TextColoredUnformatted(p.text_primary, fmt.ctprintf("%s  %s", icons.ICON_MD_FOLDER, name))
		}

		st := im.GetStyle()
		open_lbl := cstring(needs_rebuild ? "Build & Open" : "Open")
		open_w := max(im.CalcTextSize(open_lbl).x + st.FramePadding.x * 2.4, 72.0)
		rem_w := can_remove ? max(im.CalcTextSize("Remove").x + st.FramePadding.x * 2.4, 60.0) + 6.0 : f32(0)
		avail_x := im.GetContentRegionAvail().x
		im.SameLine(max(140.0, avail_x - open_w - rem_w))

		im.BeginDisabled(!exists_on_disk || is_active || relaunch_pending())
		open_col := needs_rebuild ? p.status_warning : p.status_success
		im.PushStyleColorImVec4(.Button, thm.with_alpha(open_col, 0.24))
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(open_col, 0.38))
		if im.Button(open_lbl, {open_w, 0}) {
			_try_open_project(path)
		}
		im.PopStyleColor(2)
		im.EndDisabled()

		if can_remove {
			im.SameLine(0, 6)
			if im.Button("Remove", {rem_w - 6.0, 0}) {
				_ = engine.launcher_remove_recent_project(path)
				_refresh_launcher_and_workspace()
			}
		}

		im.TextDisabled("%s", fmt.ctprintf("%s  %s", path, needs_rebuild ? "  •  Rebuilds C/Odin Code" : (exists_on_disk ? "  •  Instant Open" : "")))
	}
	im.EndChild()
	im.PopStyleColor(1)
}

@(private = "file")
_draw_project_hub_contents :: proc(is_modal: bool) {
	_ensure_hub_init()
	_poll_folder_picker()
	p := thm.palette()
	io := im.GetIO()
	if _hub.zoom < 0.90 || _hub.zoom > 1.80 {
		_hub.zoom = 1.20
	}

	if io.KeyCtrl && io.MouseWheel != 0 && im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows) {
		next_zm := clamp(_hub.zoom + io.MouseWheel * 0.08, 0.90, 1.80)
		io.MouseWheel = 0
		if abs(next_zm - _hub.zoom) > 0.005 {
			_hub.zoom = next_zm
			_hub.modal_zoom_resized = true
			if !is_modal {
				dx, dy, dw, dh := gfx.display_usable_bounds()
				cur_pos := gfx.window_position()
				cur_sz := gfx.window_size()
				cx := cur_pos.x + cur_sz.x / 2
				cy := cur_pos.y + cur_sz.y / 2
				nw := clamp(i32(f32(860) * (_hub.zoom / 1.20)), 660, max(dw - 60, 660))
				nh := clamp(i32(f32(540) * (_hub.zoom / 1.20)), 440, max(dh - 60, 440))
				nx := clamp(cx - nw / 2, dx, max(dx + dw - nw, dx))
				ny := clamp(cy - nh / 2, dy, max(dy + dh - nh, dy))
				gfx.set_window_geometry(nx, ny, nw, nh)
			}
		}
	}

	st := im.GetStyle()
	im.PushFontFloat(nil, st.FontSizeBase * _hub.zoom)
	defer im.PopFont()
	zoom_style := clamp(_hub.zoom, 0.95, 1.50)
	im.PushStyleVarImVec2(.FramePadding, {st.FramePadding.x * zoom_style, st.FramePadding.y * zoom_style})
	im.PushStyleVarImVec2(.ItemSpacing, {st.ItemSpacing.x * zoom_style, st.ItemSpacing.y * zoom_style})
	defer im.PopStyleVar(2)

	// Header banner
	im.TextColoredUnformatted(p.accent, fmt.ctprintf("%s  Haati Engine — Project Hub", icons.ICON_MD_HUB))
	compiled_label := "Empty Engine"
	if registration.COMPILED_PROJECT_DIR != "" {
		compiled_label = filepath.base(registration.COMPILED_PROJECT_DIR)
	}
	im.SameLine(0, 12)
	im.TextDisabled("%s", fmt.ctprintf("Compiled: %s | Hold Shift for Hub", compiled_label))
	zoom_pill := fmt.ctprintf("Zoom %d%%##hub_zoom_rst", int(_hub.zoom * 100.0 + 0.5))
	zoom_w := im.CalcTextSize(zoom_pill).x + 14.0
	if im.GetContentRegionAvail().x > zoom_w + 16.0 {
		im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - zoom_w)
	} else {
		im.SameLine()
	}
	if im.SmallButton(zoom_pill) {
		_hub.zoom = 1.20
		_hub.modal_zoom_resized = true
	}
	widgets.tooltip("Ctrl+MouseWheel scales both Hub text and window size (click to reset to 120%)")
	im.Separator()
	im.Spacing()

	// Active compile / swap progress banner
	if relaunch_pending() {
		im.PushStyleColorImVec4(.ChildBg, thm.with_alpha(p.status_warning, 0.14))
		if im.BeginChild("##hub_relaunch_banner", {0, 58}, {.Borders}) {
			im.TextColoredUnformatted(p.status_warning, fmt.ctprintf("%s  Compiling project gameplay package... Editor restarts automatically when ready.", icons.ICON_MD_CONSTRUCTION))
			im.ProgressBar(-1 * f32(im.GetTime()), {-1, 0}, "")
		}
		im.EndChild()
		im.PopStyleColor(1)
		im.Spacing()
	}

	// Status message (error or info)
	status_txt := _buf_str(_hub.status_msg[:])
	if status_txt != "" {
		col := _hub.status_is_error ? p.status_error : p.status_warning
		im.TextColoredUnformatted(col, fmt.ctprintf("%s", status_txt))
		im.Spacing()
	}

	avail := im.GetContentRegionAvail()
	left_w := max(320.0, avail.x * 0.56)
	right_h := max(260.0, avail.y - (is_modal ? 38.0 : 4.0))

	// ── Left Pane: Recent & Workspace Sibling Projects ─────────────────────────
	if im.BeginChild("##hub_left_pane", {left_w, right_h}, {.Borders}) {
		sres := widgets.search_bar(_hub.search_buf[:], widgets.Search_Bar_Opts{
			id   = "##hub_search",
			hint = "Search projects...",
		})
		terms := widgets.search_terms(sres.query)

		im.SameLine(0, 8)
		if im.SmallButton(fmt.ctprintf("%s Refresh", icons.ICON_MD_REFRESH)) {
			_refresh_launcher_and_workspace()
		}
		im.Spacing()

		cur_proj := engine.active_project_root()

		im.TextColoredUnformatted(p.text_primary, fmt.ctprintf("%s  Recent Projects", icons.ICON_MD_HISTORY))
		im.Separator()
		shown_recent := 0
		for r in _hub.launcher_cfg.recent_projects {
			if !widgets.search_match(fmt.tprintf("%s %s", r.name, r.path), terms) do continue
			exists := os.is_dir(r.path)
			is_active := cur_proj != "" && engine.paths_equal(cur_proj, r.path)
			_draw_project_row("recent", r.name, r.path, exists, is_active, can_remove = true)
			shown_recent += 1
		}
		if shown_recent == 0 {
			im.TextDisabled("  No matching recent projects yet.")
		}

		im.Spacing()
		im.Spacing()
		im.TextColoredUnformatted(p.text_primary, fmt.ctprintf("%s  Workspace Folder (%s)", icons.ICON_MD_FOLDER, _default_umbrella_dir(context.temp_allocator)))
		im.Separator()
		shown_ws := 0
		for w in _hub.workspace_projects {
			if !widgets.search_match(fmt.tprintf("%s %s", w.name, w.path), terms) do continue
			is_active := cur_proj != "" && engine.paths_equal(cur_proj, w.path)
			_draw_project_row("ws", w.name, w.path, true, is_active, can_remove = false)
			shown_ws += 1
		}
		if shown_ws == 0 {
			im.TextDisabled("  No additional project folders detected beside Haati_Engine.")
		}
	}
	im.EndChild()

	im.SameLine(0, 12)

	// ── Right Pane: Browse Existing / Create New Project ───────────────────────
	if im.BeginChild("##hub_right_pane", {0, right_h}, {.Borders}) {
		im.BeginDisabled(relaunch_pending())

		// Section 1: Open Existing Folder
		im.TextColoredUnformatted(p.text_primary, fmt.ctprintf("%s  Open Project Folder", icons.ICON_MD_FOLDER_OPEN))
		im.TextDisabled("Select any standalone project folder on disk (zero coupling to Haati_Engine).")
		im.SetNextItemWidth(-1)
		enter_open := im.InputTextWithHint(
			"##hub_open_path",
			"C:/Path/To/MyGame",
			cstring(raw_data(_hub.browse_path_buf[:])),
			len(_hub.browse_path_buf),
			{.EnterReturnsTrue},
		)
		btn_h := max(im.GetFrameHeight() * 1.15, 28.0)
		browse_lbl := fmt.ctprintf("%s  Browse Folder...", icons.ICON_MD_SEARCH)
		browse_w := max(im.CalcTextSize(browse_lbl).x + im.GetStyle().FramePadding.x * 2.4, 140.0)
		if im.Button(browse_lbl, {browse_w, btn_h}) {
			start_dir := _buf_str(_hub.browse_path_buf[:])
			if start_dir == "" do start_dir = _default_umbrella_dir(context.temp_allocator)
			_open_folder_picker(.Open_Project, start_dir)
		}
		im.SameLine(0, 8)
		open_cand := _buf_str(_hub.browse_path_buf[:])
		im.BeginDisabled(open_cand == "")
		open_f_w := max(im.CalcTextSize("Open Folder").x + im.GetStyle().FramePadding.x * 2.4, 118.0)
		if im.Button("Open Folder", {open_f_w, btn_h}) || (enter_open && open_cand != "") {
			_try_open_project(open_cand)
		}
		im.EndDisabled()

		im.Spacing()
		im.Separator()
		im.Spacing()

		// Section 2: Create New Standalone Project
		im.TextColoredUnformatted(p.status_success, fmt.ctprintf("%s  Create New Project", icons.ICON_MD_ADD_CIRCLE_OUTLINE))
		im.TextDisabled("Creates an isolated project folder with haati.project, main.scene, and settings.")
		im.Spacing()

		im.TextUnformatted("Project Name:")
		im.SetNextItemWidth(-1)
		enter_create := im.InputTextWithHint(
			"##hub_new_name",
			"MyHaatiGame",
			cstring(raw_data(_hub.new_name_buf[:])),
			len(_hub.new_name_buf),
			{.EnterReturnsTrue},
		)

		im.Spacing()
		im.TextUnformatted("Location (Parent Folder):")
		im.SetNextItemWidth(max(120.0, im.GetContentRegionAvail().x - 96.0))
		_ = im.InputTextWithHint(
			"##hub_new_parent",
			"C:/Users/.../Projects",
			cstring(raw_data(_hub.new_parent_buf[:])),
			len(_hub.new_parent_buf),
			{},
		)
		im.SameLine(0, 6)
		if im.Button("Browse...", {88, 0}) {
			cur_parent := _buf_str(_hub.new_parent_buf[:])
			if cur_parent == "" do cur_parent = _default_umbrella_dir(context.temp_allocator)
			_open_folder_picker(.New_Project_Parent, cur_parent)
		}

		raw_name := _buf_str(_hub.new_name_buf[:])
		raw_parent := _buf_str(_hub.new_parent_buf[:])
		clean_name, name_err, name_ok := engine.project_validate_new_name(raw_name)
		if !name_ok {
			im.TextColoredUnformatted(p.status_error, fmt.ctprintf("%s", name_err))
		} else {
			slug := engine.project_slug_from_name(clean_name, context.temp_allocator)
			preview_dir, _ := filepath.join({raw_parent, clean_name}, context.temp_allocator)
			preview_norm, _ := strings.replace_all(preview_dir, "\\", "/", context.temp_allocator)
			im.TextDisabled("%s", fmt.ctprintf("Folder: %s", preview_norm))
			im.TextDisabled("%s", fmt.ctprintf("Odin Package Slug: %s", slug))
		}

		im.Spacing()
		can_create := name_ok && raw_parent != ""
		im.BeginDisabled(!can_create)
		im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_success, 0.28))
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.status_success, 0.42))
		create_lbl := fmt.ctprintf("%s  Create & Open Project", icons.ICON_MD_ADD_CIRCLE_OUTLINE)
		create_w := max(im.CalcTextSize(create_lbl).x + im.GetStyle().FramePadding.x * 2.6, 195.0)
		create_h := max(im.GetFrameHeight() * 1.25, 32.0)
		if im.Button(create_lbl, {create_w, create_h}) || (enter_create && can_create) {
			created_dir, sc_err, sc_ok := engine.project_scaffold_new(raw_parent, raw_name, context.temp_allocator)
			if !sc_ok {
				_set_status(sc_err, true)
			} else {
				_try_open_project(created_dir)
			}
		}
		im.PopStyleColor(2)
		im.EndDisabled()

		im.EndDisabled()
	}
	im.EndChild()
}

project_hub_draw_startup_screen :: proc() {
	vp := im.GetMainViewport()
	im.SetNextWindowPos(vp.Pos, .Always)
	im.SetNextWindowSize(vp.Size, .Always)
	im.SetNextWindowViewport(vp.ID_)

	flags := im.WindowFlags{.NoTitleBar, .NoResize, .NoScrollbar, .NoCollapse, .NoMove, .NoSavedSettings, .NoDocking, .NoBringToFrontOnFocus}
	if im.Begin("##haati_startup_project_hub", nil, flags) {
		_draw_project_hub_contents(is_modal = false)
	}
	im.End()
}

project_hub_draw_modal :: proc() {
	if !_hub.modal_open do return
	_ensure_hub_init()
	if _hub.modal_open_pending || !im.IsPopupOpen("Project Hub##modal", {}) {
		im.OpenPopup("Project Hub##modal", {})
		_hub.modal_open_pending = false
	}
	widgets.center_next_window_on_active_monitor(.Appearing)
	vp := im.GetMainViewport()
	max_w := vp != nil ? vp.WorkSize.x * 0.88 : f32(1080)
	max_h := vp != nil ? vp.WorkSize.y * 0.88 : f32(760)
	zm := clamp(_hub.zoom, 0.90, 1.80) / 1.20
	target_sz := im.Vec2{clamp(760.0 * zm, 620.0, max(max_w, 620.0)), clamp(490.0 * zm, 400.0, max(max_h, 400.0))}
	sz_cond: im.Cond = _hub.modal_zoom_resized ? .Always : .Appearing
	_hub.modal_zoom_resized = false
	im.SetNextWindowSize(target_sz, sz_cond)
	if im.BeginPopupModal("Project Hub##modal", &_hub.modal_open, {.NoSavedSettings}) {
		_draw_project_hub_contents(is_modal = true)
		im.Spacing()
		im.BeginDisabled(relaunch_pending())
		if im.Button("Close", {90, 0}) {
			_hub.modal_open = false
			im.CloseCurrentPopup()
		}
		im.EndDisabled()
		im.EndPopup()
	}
}

project_hub_shutdown :: proc() {
	if _hub.initialized {
		engine.launcher_free_config(&_hub.launcher_cfg, runtime.default_allocator())
		_clear_workspace_projects()
		delete(_hub.workspace_projects)
	}
	_hub = {}

	sync.mutex_lock(&_picker.mu)
	if _picker.path != "" {
		delete(_picker.path, runtime.default_allocator())
		_picker.path = ""
	}
	_picker.open = false
	_picker.ready = false
	sync.mutex_unlock(&_picker.mu)
}
