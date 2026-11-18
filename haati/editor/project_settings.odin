package editor

// Unified Settings window (`Edit -> Settings...`, Ctrl+,) implementing the 3-tier cascade:
//   Tier 1: Factory Defaults Backdrop (`UserSettings/EngineSettings/_defaults_backdrop/<slug>.json`)
//   Tier 2: Shared Engine Settings (`UserSettings/EngineSettings/<slug>.json`, shared across projects)
//   Tier 3: Opt-in per-field Project Overrides (`ProjectSettings/project_overrides.json` + resolved
//           `ProjectSettings/<slug>.json` for standalone builds)
//
// Sections are package-level struct vars marked `@(project_settings={name="..."})`
// (project_settings_gen emits settings_add_tab calls) plus custom tabs like Plugins.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "../engine"
import "haati:editor/icons"
import "inspector"
import mcp "haati:editor/mcp"
import thm "haati:editor/theme"
import "undo"
import wnd "haati:editor/window"
import "haati:editor/widgets"

Settings_View_Filter :: enum {
	All = 0,
	Modified,
	Project_Overrides,
}

@(private = "file")
_Settings_Nav_Group :: enum {
	Editor = 0,
	Engine = 1,
	Project = 2,
}

@(private = "file")
_Settings_Tab :: struct {
	name:      string,
	ptr:       rawptr,
	tid:       typeid,
	last_json: []byte, // last persisted state, so saves happen only on change
	draw:      proc(), // custom self-drawn tab (e.g. Plugins)
	origin:    string,
}

@(private = "file")
_settings_tabs: [dynamic]_Settings_Tab

@(private = "file")
_settings_filter: [96]byte

@(private = "file")
_settings_view_filter: Settings_View_Filter = .All

@(private = "file")
_settings_split_ratio: f32 = 0.25

// Formats an Odin `snake_case` settings identifier into a clean, readable UI label
// with smart unit suffixes and acronym casing (`problem_check_delay_sec` -> `"Problem Check Delay (s)"`).
humanize_setting_label :: proc(ident: string, allocator := context.temp_allocator) -> string {
	if ident == "" do return ""
	s := ident
	unit_suffix := ""
	if strings.has_suffix(s, "_sec") {
		s = s[:len(s) - 4]
		unit_suffix = " (s)"
	} else if strings.has_suffix(s, "_ms") {
		s = s[:len(s) - 3]
		unit_suffix = " (ms)"
	} else if strings.has_suffix(s, "_hz") {
		s = s[:len(s) - 3]
		unit_suffix = " (Hz)"
	} else if strings.has_suffix(s, "_px") {
		s = s[:len(s) - 3]
		unit_suffix = " (px)"
	} else if strings.has_suffix(s, "_pct") {
		s = s[:len(s) - 4]
		unit_suffix = " (%)"
	} else if strings.has_suffix(s, "_deg") {
		s = s[:len(s) - 4]
		unit_suffix = " (deg)"
	} else if strings.has_suffix(s, "_mb") {
		s = s[:len(s) - 3]
		unit_suffix = " (MB)"
	}

	parts := strings.split(s, "_", context.temp_allocator)
	sb := strings.builder_make(0, len(ident) + 12, allocator)
	wrote := 0
	for raw_w in parts {
		if raw_w == "" do continue
		if wrote > 0 do strings.write_byte(&sb, ' ')
		wrote += 1
		lw := strings.to_lower(raw_w, context.temp_allocator)
		switch lw {
		case "ui":    strings.write_string(&sb, "UI")
		case "ide":   strings.write_string(&sb, "IDE")
		case "fps":   strings.write_string(&sb, "FPS")
		case "hz":    strings.write_string(&sb, "Hz")
		case "csg":   strings.write_string(&sb, "CSG")
		case "ik":    strings.write_string(&sb, "IK")
		case "mcp":   strings.write_string(&sb, "MCP")
		case "vfs":   strings.write_string(&sb, "VFS")
		case "ssao":  strings.write_string(&sb, "SSAO")
		case "fxaa":  strings.write_string(&sb, "FXAA")
		case "taa":   strings.write_string(&sb, "TAA")
		case "gi":    strings.write_string(&sb, "GI")
		case "fov":   strings.write_string(&sb, "FOV")
		case "lod":   strings.write_string(&sb, "LOD")
		case "gpu":   strings.write_string(&sb, "GPU")
		case "cpu":   strings.write_string(&sb, "CPU")
		case "dpi":   strings.write_string(&sb, "DPI")
		case "os":    strings.write_string(&sb, "OS")
		case "ram":   strings.write_string(&sb, "RAM")
		case "ai":    strings.write_string(&sb, "AI")
		case "vfx":   strings.write_string(&sb, "VFX")
		case "vsync": strings.write_string(&sb, "VSync")
		case "2d":    strings.write_string(&sb, "2D")
		case "3d":    strings.write_string(&sb, "3D")
		case:
			c0 := lw[0]
			if c0 >= 'a' && c0 <= 'z' {
				strings.write_byte(&sb, c0 - 32)
				strings.write_string(&sb, lw[1:])
			} else {
				strings.write_string(&sb, lw)
			}
		}
	}
	if unit_suffix != "" {
		strings.write_string(&sb, unit_suffix)
	}
	return strings.to_string(sb)
}

@(private = "file")
_settings_extract_decor_header :: proc(tag: reflect.Struct_Tag) -> string {
	s := string(tag)
	key := `decor:header("`
	idx := strings.index(s, key)
	if idx < 0 do return ""
	rest := s[idx + len(key):]
	end := strings.index_byte(rest, '"')
	if end <= 0 do return ""
	return rest[:end]
}

// Registers one tab.
settings_add_tab :: proc(name: string, ptr: rawptr, tid: typeid, origin := "") {
	append(&_settings_tabs, _Settings_Tab{
		name = name, ptr = ptr, tid = tid, origin = origin,
		last_json = undo.capture_json(ptr, tid),
	})
	slice.sort_by(_settings_tabs[:], proc(a, b: _Settings_Tab) -> bool {
		return a.name < b.name
	})
}

// Registers a tab drawn by `draw`, for state that is not a settings struct.
settings_add_custom_tab :: proc(name: string, draw: proc()) {
	append(&_settings_tabs, _Settings_Tab{name = name, draw = draw})
	slice.sort_by(_settings_tabs[:], proc(a, b: _Settings_Tab) -> bool {
		return a.name < b.name
	})
}

settings_save_all :: proc() {
	for &tab in _settings_tabs {
		_settings_persist(&tab)
	}
}

settings_shutdown :: proc() {
	for &tab in _settings_tabs {
		delete(tab.last_json)
	}
	delete(_settings_tabs)
	_settings_tabs = nil
	engine.project_settings_shutdown()
}

@(private = "file")
_settings_sync_after_write :: proc(tab_name: string) {
	if tab_name == "Editor & Appearance" || tab_name == "Code & Script IDE" || tab_name == "File Explorer" {
		editor_defaults_sync_from_settings(tab_name == "Code & Script IDE")
	} else if tab_name == "MCP" {
		mcp_bridge_set_enabled(engine.mcp_settings.enabled)
	}
}

@(private = "file")
_settings_force_save_and_sync :: proc(tab: ^_Settings_Tab) {
	if tab == nil || tab.draw != nil do return
	if cur := undo.capture_json(tab.ptr, tab.tid); cur != nil {
		delete(tab.last_json)
		tab.last_json = cur
	}
	_settings_sync_after_write(tab.name)
}

@(private = "file")
_settings_persist :: proc(tab: ^_Settings_Tab) {
	if tab.draw != nil do return
	cur := undo.capture_json(tab.ptr, tab.tid)
	if cur == nil do return
	if slice.equal(cur, tab.last_json) {
		delete(cur)
		return
	}
	engine.project_settings_save(tab.name, tab.ptr, tab.tid)
	delete(tab.last_json)
	tab.last_json = cur
	_settings_sync_after_write(tab.name)
}

@(private = "file")
_settings_field_visible :: proc(tag: reflect.Struct_Tag) -> bool {
	if iv, has_i := reflect.struct_tag_lookup(tag, "inspect"); has_i {
		return iv != "-"
	}
	if jv, has_j := reflect.struct_tag_lookup(tag, "json"); has_j && jv == "-" {
		return false
	}
	return true
}

@(private = "file")
_settings_field_matches :: proc(fname: string, tag: reflect.Struct_Tag, filter: []string) -> bool {
	if len(filter) == 0 do return true
	if widgets.search_match(fname, filter) do return true
	pretty := humanize_setting_label(fname, context.temp_allocator)
	if widgets.search_match(pretty, filter) do return true
	tag_str := string(tag)
	if len(tag_str) > 0 && widgets.search_match(tag_str, filter) do return true
	return false
}

@(private = "file")
_settings_tab_group_and_icon :: proc(tab: ^_Settings_Tab) -> (grp: _Settings_Nav_Group, icon: cstring) {
	switch tab.name {
	case "Editor & Appearance": return .Editor, icons.ICON_MD_PALETTE
	case "Code & Script IDE":   return .Editor, icons.ICON_MD_CODE
	case "File Explorer":       return .Editor, icons.ICON_MD_FOLDER
	case "Editor Visuals":      return .Editor, icons.ICON_MD_TUNE
	case "Plugins":             return .Editor, icons.ICON_MD_EXTENSION
	}
	low_ori := strings.to_lower(tab.origin, context.temp_allocator)
	if strings.contains(low_ori, "plugins/") || strings.contains(low_ori, "/projects/") {
		return .Project, icons.ICON_MD_DEPLOYED_CODE
	}
	switch tab.name {
	case "Input Manager":          return .Engine, icons.ICON_MD_KEYBOARD
	case "CAD & Destructible CSG": return .Engine, icons.ICON_MD_ARCHITECTURE
	case "Skeleton & Bones":       return .Engine, icons.ICON_MD_HUB
	case "Serialization":          return .Engine, icons.ICON_MD_SAVE
	case "Time":                   return .Engine, icons.ICON_MD_HISTORY
	}
	return .Engine, icons.ICON_MD_WIDGETS
}

@(private = "file")
_settings_mcp_matches_filter :: proc(filter: []string, view: Settings_View_Filter) -> bool {
	is_ovr := engine.project_settings_has_field_override("MCP", "enabled")
	is_mod := !engine.mcp_settings.enabled // compiled default is true
	switch view {
	case .All:
	case .Project_Overrides:
		if !is_ovr do return false
	case .Modified:
		if !is_mod && !is_ovr do return false
	}
	if len(filter) == 0 do return true
	return widgets.search_match("AI Agent Bridge MCP server enabled claude antigravity tools", filter)
}

@(private = "file")
_settings_tab_visible :: proc(tab: ^_Settings_Tab, filter: []string, view: Settings_View_Filter) -> (visible: bool, tab_name_matched: bool) {
	// Standalone 1-bool "MCP" tab is folded cleanly into the Editor & Appearance card.
	if tab.name == "MCP" do return false, false

	tab_name_matched = len(filter) == 0 || widgets.search_match(tab.name, filter)
	if tab.name == "Editor & Appearance" && _settings_mcp_matches_filter(filter, view) && (len(filter) > 0 || view != .All) {
		return true, tab_name_matched
	}

	if tab.draw != nil {
		return view == .All && tab_name_matched, tab_name_matched
	}

	ovr_cnt := engine.project_settings_tab_override_count(tab.name)
	if view == .Project_Overrides && ovr_cnt == 0 {
		return false, tab_name_matched
	}
	if view == .All && tab_name_matched {
		return true, true
	}
	if _, is_custom := inspector.mapPropertyDrawer[tab.tid]; is_custom {
		return view == .All && tab_name_matched, tab_name_matched
	}

	cur_json: []byte
	if view == .Modified {
		cur_json = undo.capture_json(tab.ptr, tab.tid)
	}
	defer if cur_json != nil do delete(cur_json)

	names := reflect.struct_field_names(tab.tid)
	types := reflect.struct_field_types(tab.tid)
	for i in 0 ..< len(names) {
		if types[i].id == typeid_of(engine.CompData) do continue
		finfo := reflect.struct_field_at(tab.tid, i)
		if !_settings_field_visible(finfo.tag) do continue
		if !tab_name_matched && !_settings_field_matches(names[i], finfo.tag, filter) do continue

		switch view {
		case .All:
			return true, tab_name_matched
		case .Project_Overrides:
			if engine.project_settings_has_field_override(tab.name, names[i]) {
				return true, tab_name_matched
			}
		case .Modified:
			if engine.project_settings_has_field_override(tab.name, names[i]) ||
			   engine.project_settings_is_field_modified_from_default(tab.name, names[i], cur_json) {
				return true, tab_name_matched
			}
		}
	}
	return false, tab_name_matched
}

@(private = "file")
_draw_mcp_bridge_card :: proc() {
	p := thm.palette()
	mcp_tab: ^_Settings_Tab = nil
	for &t in _settings_tabs {
		if t.name == "MCP" {
			mcp_tab = &t
			break
		}
	}

	im.Spacing()
	im.TextColoredUnformatted(p.accent, "AI Agent Bridge (MCP)")
	im.Separator()

	active, port := mcp_bridge_status()
	has_proj := engine.has_active_project()
	is_ovr   := has_proj && engine.project_settings_has_field_override("MCP", "enabled")
	is_mod   := !engine.mcp_settings.enabled

	im.PushIDInt(901234)
	defer im.PopID()

	if has_proj {
		ovr_col := is_ovr ? p.accent : im.Vec4{0.25, 0.28, 0.34, 0.70}
		if widgets.small_toggle_button("P##mcp_p", is_ovr, ovr_col, !is_ovr) {
			_ = engine.project_settings_set_field_override("MCP", "enabled", !is_ovr, &engine.mcp_settings, typeid_of(type_of(engine.mcp_settings)))
			_settings_force_save_and_sync(mcp_tab)
		}
		widgets.tooltip(is_ovr \
			? "Project Override ACTIVE for MCP setting. Click [P] to inherit Engine Settings." \
			: "Shared Engine Setting. Click [P] to override MCP for this project only.")
		im.SameLine(0, 4)
	}

	im.BeginDisabled(!is_mod)
	if im.SmallButton(fmt.ctprintf("%s##mcp_rst", icons.ICON_MD_REFRESH)) {
		engine.mcp_settings.enabled = true
		mcp_bridge_set_enabled(true)
		_settings_force_save_and_sync(mcp_tab)
	}
	im.EndDisabled()
	if is_mod {
		widgets.tooltip("Reset AI Agent Bridge (MCP) back to Enabled default")
	}

	im.SameLine(0, 8)
	en_tmp := engine.mcp_settings.enabled
	if im.Checkbox("Enable Built-In MCP Bridge (18 Editor Tools)##mcp_en", &en_tmp) {
		mcp_bridge_set_enabled(en_tmp)
		_settings_force_save_and_sync(mcp_tab)
	}
	widgets.tooltip("Exposes live screenshot, logs, reflection, play/simulate, and undoable scene edits on 127.0.0.1 for Antigravity / Claude Code.")

	im.SameLine(0, 10)
	if active {
		widgets.text_coloredf(p.status_success, "%s Listening on 127.0.0.1:%d", icons.ICON_MD_CHECK, port)
	} else {
		widgets.text_disabledf("%s Offline", icons.ICON_MD_CLOSE)
	}

	disc_path := engine.engine_file_path(mcp.BRIDGE_FILE_USER_SETTINGS, context.temp_allocator)
	im.TextDisabled("Discovery: %s", fmt.ctprintf("%s", disc_path))
	im.SameLine(0, 8)
	if im.SmallButton(fmt.ctprintf("%s Copy .mcp.json##mcp_cpy", icons.ICON_MD_CONTENT_COPY)) {
		snippet := `{"mcpServers":{"haati":{"command":"tools/odin/odin.exe","args":["run","haati/mcp_shim","-collection:haati=haati","--"]}}}`
		im.SetClipboardText(strings.clone_to_cstring(snippet, context.temp_allocator))
	}
	widgets.tooltip("Copy ready-to-use Haati `.mcp.json` configuration snippet to clipboard")
}

@(private = "file")
_draw_watch_wolf_guardian_card :: proc() {
	p := thm.palette()
	im.Spacing()
	im.TextColoredUnformatted(p.accent, "Watch-Wolf Out-of-Process Crash Guardian")
	im.Separator()

	armed := watchdog_is_armed()
	wanted := watchdog_want_enabled()
	quarantined := engine.hot_cartridge_is_quarantined()

	tint := armed ? p.status_success : (wanted ? p.status_warning : p.text_muted)
	widgets.watch_wolf_draw(34.0, tint)
	im.SameLine(0, 10)
	im.BeginGroup()
	if armed {
		widgets.text_coloredf(p.status_success, "%s Guardian Armed (16 MB Kernel RAM Vault + 90s Safe-Hub Circuit Breaker)", icons.ICON_MD_CHECK)
	} else if wanted {
		widgets.text_coloredf(p.status_warning, "%s Guardian Warming Up (arms after 3s stable startup)", icons.ICON_MD_MEMORY)
	} else {
		widgets.text_disabledf("%s Guardian Disabled in Code & Script IDE settings", icons.ICON_MD_CLOSE)
	}

	if quarantined {
		widgets.text_coloredf(p.status_warning, "%s Hot Cartridge QUARANTINED after previous crash — fix script and click Re-Arm or press F7.", icons.ICON_MD_WARNING)
		if im.SmallButton(fmt.ctprintf("%s Re-Arm Hot Scripts##ww_rearm", icons.ICON_MD_REFRESH)) {
			engine.hot_cartridge_clear_faults()
		}
	} else {
		widgets.text_disabledf("Hot Cartridge armed. Double-crash within 90s auto-boots to Project Hub.")
	}
	if !engine.is_project_hub_startup() {
		if quarantined do im.SameLine(0, 8)
		if im.SmallButton(fmt.ctprintf("%s Boot to Project Hub##ww_hub", icons.ICON_MD_FOLDER_OPEN)) {
			relaunch_boot_to_project_hub()
		}
	}
	im.EndGroup()
}

@(private = "file")
_draw_settings_tab_fields :: proc(
	tab: ^_Settings_Tab,
	filter: []string,
	view: Settings_View_Filter,
	show_tab_card_header: bool,
) -> (drawn_fields: int) {
	if tab == nil do return 0
	p := thm.palette()
	has_proj := engine.has_active_project()

	if show_tab_card_header {
		_, icon := _settings_tab_group_and_icon(tab)
		im.Spacing()
		widgets.text_coloredf(p.accent, "%s %s", icon, tab.name)
		im.Separator()
	}

	if tab.draw != nil {
		tab.draw()
		return 1
	}

	if _, is_custom := inspector.mapPropertyDrawer[tab.tid]; is_custom {
		undo.push_raw_owner(tab.ptr, tab.tid)
		inspector.draw_inspector(any{tab.ptr, tab.tid})
		undo.pop_owner()
		if !im.IsAnyItemActive() do _settings_persist(tab)
		return 1
	}

	cur_json := undo.capture_json(tab.ptr, tab.tid)
	defer if cur_json != nil do delete(cur_json)

	undo.push_raw_owner(tab.ptr, tab.tid)
	defer undo.pop_owner()

	tab_matched := len(filter) == 0 || widgets.search_match(tab.name, filter)
	names := reflect.struct_field_names(tab.tid)
	types := reflect.struct_field_types(tab.tid)

	inspector.suppress_field_headers = true
	defer inspector.suppress_field_headers = false

	im.PushID(fmt.ctprintf("stab_%s", tab.name))
	defer im.PopID()

	for i in 0 ..< len(names) {
		if types[i].id == typeid_of(engine.CompData) do continue
		finfo := reflect.struct_field_at(tab.tid, i)
		if !_settings_field_visible(finfo.tag) do continue

		fname := names[i]
		if !tab_matched && !_settings_field_matches(fname, finfo.tag, filter) do continue

		is_ovr := engine.project_settings_has_field_override(tab.name, fname)
		is_mod := engine.project_settings_is_field_modified_from_default(tab.name, fname, cur_json)

		switch view {
		case .All:
		case .Project_Overrides:
			if !is_ovr do continue
		case .Modified:
			if !is_mod && !is_ovr do continue
		}

		if hdr := _settings_extract_decor_header(finfo.tag); hdr != "" {
			im.Spacing()
			im.TextColoredUnformatted(p.accent, fmt.ctprintf("%s", hdr))
			im.Separator()
		}

		drawn_fields += 1
		im.PushIDInt(i32(i))

		if has_proj {
			ovr_col := is_ovr ? p.accent : im.Vec4{0.25, 0.28, 0.34, 0.70}
			if widgets.small_toggle_button("P", is_ovr, ovr_col, !is_ovr) {
				if engine.project_settings_set_field_override(tab.name, fname, !is_ovr, tab.ptr, tab.tid) {
					_settings_force_save_and_sync(tab)
				}
			}
			widgets.tooltip(is_ovr \
				? "Project Override ACTIVE: saved per-project in ProjectSettings/project_overrides.json. Click [P] to revert to shared Engine Settings." \
				: "Using shared Engine Setting. Click [P] to override this setting for the active project only.")
			im.SameLine(0, 4)
		}

		if is_mod {
			if im.SmallButton(icons.ICON_MD_REFRESH) {
				if engine.project_settings_reset_field_to_default(tab.name, fname, tab.ptr, tab.tid) {
					_settings_force_save_and_sync(tab)
				}
			}
			widgets.tooltip("Reset this setting to its Tier 1 Factory Default")
		} else {
			im.BeginDisabled()
			im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
			im.SmallButton(icons.ICON_MD_REFRESH)
			im.PopStyleColor()
			im.EndDisabled()
		}

		im.SameLine(0, 8)
		im.BeginGroup()
		pretty_lbl := humanize_setting_label(fname, context.temp_allocator)
		inspector.draw_struct_field_at(tab.ptr, tab.tid, i, "", pretty_lbl)
		im.EndGroup()

		im.PopID()
	}

	if tab.name == "Editor & Appearance" && (!show_tab_card_header || _settings_mcp_matches_filter(filter, view)) {
		if view == .All || _settings_mcp_matches_filter(filter, view) {
			_draw_mcp_bridge_card()
			drawn_fields += 1
		}
	}

	if tab.name == "Code & Script IDE" && (view == .All || len(filter) == 0 || widgets.search_match("watchdog watch wolf guardian crash vault safe mode quarantine hub", filter)) {
		_draw_watch_wolf_guardian_card()
		drawn_fields += 1
	}

	if !im.IsAnyItemActive() {
		_settings_persist(tab)
	}
	return drawn_fields
}

@(editor_window={id="project_settings", title="Settings", icon="SETTINGS", width=940, height=640})
project_settings_window_draw :: proc() {
	if len(_settings_tabs) == 0 {
		im.TextDisabled("No settings registered")
		return
	}

	if pending := wnd.consume_pending_settings_tab(); pending != "" {
		target_tab := pending == "MCP" ? "Editor & Appearance" : pending
		if editor_settings.project_settings_tab != "" {
			delete(editor_settings.project_settings_tab, runtime.default_allocator())
		}
		editor_settings.project_settings_tab = strings.clone(target_tab, runtime.default_allocator())
		_settings_filter[0] = 0
		_settings_view_filter = .All
	}
	if editor_settings.project_settings_tab == "MCP" {
		delete(editor_settings.project_settings_tab, runtime.default_allocator())
		editor_settings.project_settings_tab = strings.clone("Editor & Appearance", runtime.default_allocator())
	}

	p := thm.palette()

	// Top header + global search + segmented filter bar
	widgets.text_coloredf(p.accent, "%s Settings", icons.ICON_MD_SETTINGS)
	im.SameLine(0, 10)
	if engine.has_active_project() {
		widgets.small_toggle_button(fmt.ctprintf("Project: %s##ps_scope", engine.active_project_slug(context.temp_allocator)), true, p.accent)
		im.SameLine(0, 8)
		im.TextDisabled("Engine Settings shared globally; [P] overrides per-project.")
	} else {
		widgets.small_toggle_button("Engine Defaults##ps_scope", false)
		im.SameLine(0, 8)
		im.TextDisabled("Shared across all projects (UserSettings/EngineSettings/).")
	}

	sr := widgets.search_bar(_settings_filter[:], widgets.Search_Bar_Opts{
		id    = "##ps_filter",
		hint  = "Search all settings, tooltips, or sections...",
		mode  = .Toolbar,
		width = max(im.GetContentRegionAvail().x - 270.0, 160.0),
	})
	filter := widgets.search_terms(sr.query)

	im.SameLine(0, 8)
	if widgets.small_toggle_button("All", _settings_view_filter == .All) {
		_settings_view_filter = .All
	}
	im.SameLine(0, 4)
	if widgets.small_toggle_button("Modified", _settings_view_filter == .Modified) {
		_settings_view_filter = .Modified
	}
	im.SameLine(0, 4)
	if widgets.small_toggle_button("Overrides [P]", _settings_view_filter == .Project_Overrides, p.accent) {
		_settings_view_filter = .Project_Overrides
	}
	im.Separator()

	// Draggable pane split.
	avail := im.GetContentRegionAvail()
	split_total := avail.x - widgets.SPLITTER_SIZE
	MIN_LEFT :: f32(185)
	MIN_RIGHT :: f32(260)
	left_w := split_total * _settings_split_ratio
	if left_w < MIN_LEFT do left_w = MIN_LEFT
	if left_w > split_total - MIN_RIGHT do left_w = split_total - MIN_RIGHT
	right_w := split_total - left_w

	im.BeginChild("##ps_sections", im.Vec2{left_w, 0}, {.Borders}, {})
	selected := _settings_selected_tab()
	any_tab_shown := false

	group_specs := [3]struct {
		grp:   _Settings_Nav_Group,
		title: cstring,
	}{
		{.Editor,  "EDITOR"},
		{.Engine,  "ENGINE"},
		{.Project, "PROJECT"},
	}

	for gs in group_specs {
		group_has_any := false
		for &tab in _settings_tabs {
			t_grp, _ := _settings_tab_group_and_icon(&tab)
			if t_grp != gs.grp do continue
			tab_vis, _ := _settings_tab_visible(&tab, filter, _settings_view_filter)
			if !tab_vis do continue
			if !group_has_any {
				group_has_any = true
				im.Spacing()
				widgets.text_disabledf("  %s", gs.title)
			}
			any_tab_shown = true

			_, icon := _settings_tab_group_and_icon(&tab)
			ovr_count := tab.draw == nil ? engine.project_settings_tab_override_count(tab.name) : 0
			if tab.name == "Editor & Appearance" && engine.project_settings_has_field_override("MCP", "enabled") {
				ovr_count += 1
			}
			row_label: cstring
			if ovr_count > 0 {
				row_label = fmt.ctprintf("%s %s  [%dP]###tab_%s", icon, tab.name, ovr_count, tab.name)
			} else {
				row_label = fmt.ctprintf("%s %s###tab_%s", icon, tab.name, tab.name)
			}

			prev := widgets.ui_origin_push(tab.origin)
			is_sel := selected != nil && selected.name == tab.name && len(filter) == 0 && _settings_view_filter == .All
			if im.Selectable(row_label, is_sel) {
				if editor_settings.project_settings_tab != "" do delete(editor_settings.project_settings_tab, runtime.default_allocator())
				editor_settings.project_settings_tab = strings.clone(tab.name, runtime.default_allocator())
				selected = &tab
				_settings_filter[0] = 0
				_settings_view_filter = .All
			}
			widgets.tooltip("")
			widgets.ui_origin_pop(prev)
		}
	}
	if !any_tab_shown {
		im.TextDisabled("No matching settings tabs")
	}
	im.EndChild()

	im.SameLine(0, 0)
	if widgets.splitter("##ps_split", true, &left_w, &right_w, MIN_LEFT, MIN_RIGHT) {
		_settings_split_ratio = left_w / split_total
	}
	im.SameLine(0, 0)

	im.PushStyleVarImVec2(.WindowPadding, {16, 12})
	im.BeginChild("##ps_section", im.Vec2{0, 0}, {.Borders}, {})

	is_cross_tab := len(filter) > 0 || _settings_view_filter != .All
	if is_cross_tab {
		total_matches := 0
		for &tab in _settings_tabs {
			tab_vis, _ := _settings_tab_visible(&tab, filter, _settings_view_filter)
			if !tab_vis do continue
			total_matches += _draw_settings_tab_fields(&tab, filter, _settings_view_filter, true)
		}
		if total_matches == 0 {
			im.TextDisabled("No settings match your current search or filter.")
		}
	} else if selected != nil {
		if selected.draw != nil {
			_, icon := _settings_tab_group_and_icon(selected)
			im.SeparatorText(fmt.ctprintf("%s %s", icon, selected.name))
			selected.draw()
		} else {
			_, icon := _settings_tab_group_and_icon(selected)
			ovr_count := engine.project_settings_tab_override_count(selected.name)
			im.SeparatorText(fmt.ctprintf("%s %s", icon, selected.name))

			if ovr_count > 0 {
				widgets.text_coloredf(p.accent, "%s %d Project Override(s) active", icons.ICON_MD_TUNE, ovr_count)
			} else if engine.has_active_project() {
				im.TextDisabled("All fields inherited from shared Engine Settings")
			} else {
				im.TextDisabled("Shared Engine Defaults")
			}
			im.SameLine()
			if im.SmallButton(fmt.ctprintf("%s Reset Tab", icons.ICON_MD_REFRESH)) {
				if engine.project_settings_reset_tab_to_defaults(selected.name, selected.ptr, selected.tid, false) {
					_settings_force_save_and_sync(selected)
				}
			}
			widgets.tooltip("Reset non-overridden fields in this tab back to Tier 1 Factory Defaults")
			if ovr_count > 0 {
				im.SameLine(0, 6)
				if im.SmallButton(fmt.ctprintf("%s Clear Overrides", icons.ICON_MD_CLOSE)) {
					if engine.project_settings_reset_tab_to_defaults(selected.name, selected.ptr, selected.tid, true) {
						_settings_force_save_and_sync(selected)
					}
				}
				widgets.tooltip("Remove all [P] Project Overrides in this tab and revert to Engine Defaults")
			}
			im.Spacing()

			_ = _draw_settings_tab_fields(selected, nil, .All, false)
		}
	}
	im.EndChild()
	im.PopStyleVar()
}

// The persisted selection when it still exists (excluding folded tabs like MCP), the first visible tab otherwise.
@(private = "file")
_settings_selected_tab :: proc() -> ^_Settings_Tab {
	for &tab in _settings_tabs {
		if tab.name == "MCP" do continue
		if tab.name == editor_settings.project_settings_tab do return &tab
	}
	for &tab in _settings_tabs {
		if tab.name != "MCP" do return &tab
	}
	return nil
}

@(menu_separator={path="Edit", order=99})
@(menu_item={path="Edit/Settings...", order=100, shortcut="Ctrl+,"})
open_project_settings :: proc() {
	wnd.open("project_settings")
}
