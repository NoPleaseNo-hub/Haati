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
_Settings_Tab :: struct {
	name:      string,
	ptr:       rawptr,
	tid:       typeid,
	last_json: []byte, // last persisted state, so saves happen only on change
	// A tab that draws itself instead of a settings struct (the Plugins tab,
	// whose state is the filesystem). No undo owner, nothing persisted.
	draw:      proc(),
	// The @(project_settings) that created the tab, with its file and line, as
	// rendered by the generator. Shown in the tab row's tooltip with debug tooltips on.
	// A hand-registered tab (settings_add_custom_tab) has none.
	origin:    string,
}

@(private = "file")
_settings_tabs: [dynamic]_Settings_Tab

@(private = "file")
_settings_filter: [96]byte

@(private = "file")
_settings_view_filter: Settings_View_Filter = .All

// Left pane's share of the window width, dragged via the pane splitter.
@(private = "file")
_settings_split_ratio: f32 = 0.28

// Registers one tab. The generated _register_project_settings loads the var's
// persisted values (a typed engine.project_settings_load) right before this
// call, so the editor session starts from the resolved Engine + Override values.
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

// Persists every tab that differs from its last saved state. Called at editor
// shutdown, so changes made outside the window's diff-save (an undo after the
// window closed) still land on disk.
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
	if tab_name == "Editor & Appearance" || tab_name == "Code & Script IDE" || tab_name == "Void File Explorer" {
		editor_defaults_sync_from_settings(tab_name == "Code & Script IDE")
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
	pretty, _ := strings.replace_all(fname, "_", " ", context.temp_allocator)
	if widgets.search_match(pretty, filter) do return true
	tag_str := string(tag)
	if len(tag_str) > 0 && widgets.search_match(tag_str, filter) do return true
	return false
}

@(private = "file")
_settings_tab_visible :: proc(tab: ^_Settings_Tab, filter: []string, view: Settings_View_Filter) -> (visible: bool, tab_name_matched: bool) {
	tab_name_matched = len(filter) == 0 || widgets.search_match(tab.name, filter)
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

@(editor_window={id="project_settings", title="Settings", icon="SETTINGS", width=880, height=600})
project_settings_window_draw :: proc() {
	if len(_settings_tabs) == 0 {
		im.TextDisabled("No settings registered")
		return
	}

	if pending := wnd.consume_pending_settings_tab(); pending != "" {
		if editor_settings.project_settings_tab != "" {
			delete(editor_settings.project_settings_tab, runtime.default_allocator())
		}
		editor_settings.project_settings_tab = strings.clone(pending, runtime.default_allocator())
		_settings_filter[0] = 0
		_settings_view_filter = .All
	}

	p := thm.palette()

	// Top tier summary + filter bar
	if engine.has_active_project() {
		widgets.text_coloredf(p.accent, "%s Unified Settings", icons.ICON_MD_SETTINGS)
		im.SameLine(0, 10)
		widgets.text_disabledf("Shared Engine Settings apply across projects; toggle [P] to override any field for project '%s'.", engine.active_project_slug(context.temp_allocator))
	} else {
		widgets.text_coloredf(p.accent, "%s Unified Settings", icons.ICON_MD_SETTINGS)
		im.SameLine(0, 10)
		im.TextDisabled("Shared Engine Settings (UserSettings/EngineSettings/) with optional per-field [P] Project Overrides.")
	}

	if widgets.small_toggle_button("All", _settings_view_filter == .All) {
		_settings_view_filter = .All
	}
	im.SameLine(0, 6)
	if widgets.small_toggle_button("Modified", _settings_view_filter == .Modified) {
		_settings_view_filter = .Modified
	}
	im.SameLine(0, 6)
	if widgets.small_toggle_button("Project Overrides [P]", _settings_view_filter == .Project_Overrides, p.accent) {
		_settings_view_filter = .Project_Overrides
	}
	im.Separator()

	// Draggable pane split.
	avail := im.GetContentRegionAvail()
	split_total := avail.x - widgets.SPLITTER_SIZE
	MIN_LEFT :: f32(170)
	MIN_RIGHT :: f32(220)
	left_w := split_total * _settings_split_ratio
	if left_w < MIN_LEFT do left_w = MIN_LEFT
	if left_w > split_total - MIN_RIGHT do left_w = split_total - MIN_RIGHT
	right_w := split_total - left_w

	im.BeginChild("##ps_sections", im.Vec2{left_w, 0}, {}, {})
	sr := widgets.search_bar(_settings_filter[:], widgets.Search_Bar_Opts{
		id    = "##ps_filter",
		hint  = "Search tabs or fields...",
		mode  = .Toolbar,
		width = max(60.0, im.GetContentRegionAvail().x),
	})
	filter := widgets.search_terms(sr.query)

	selected := _settings_selected_tab()
	any_tab_shown := false
	for &tab in _settings_tabs {
		tab_vis, _ := _settings_tab_visible(&tab, filter, _settings_view_filter)
		if !tab_vis do continue
		any_tab_shown = true

		ovr_count := tab.draw == nil ? engine.project_settings_tab_override_count(tab.name) : 0
		row_label: cstring
		if ovr_count > 0 {
			row_label = fmt.ctprintf("%s  [%dP]###tab_%s", tab.name, ovr_count, tab.name)
		} else {
			row_label = fmt.ctprintf("%s###tab_%s", tab.name, tab.name)
		}

		// A tab row has no tooltip of its own, so the empty text below draws
		// nothing outside debug tooltips.
		prev := widgets.ui_origin_push(tab.origin)
		if im.Selectable(row_label, selected != nil && selected.name == tab.name) {
			if editor_settings.project_settings_tab != "" do delete(editor_settings.project_settings_tab, runtime.default_allocator())
			editor_settings.project_settings_tab = strings.clone(tab.name, runtime.default_allocator())
			selected = &tab
		}
		widgets.tooltip("")
		widgets.ui_origin_pop(prev)
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
	im.PushStyleVarImVec2(.WindowPadding, {14, 10})
	im.BeginChild("##ps_section", im.Vec2{0, 0}, {}, {})
	if selected != nil {
		if selected.draw != nil {
			im.SeparatorText(strings.clone_to_cstring(selected.name, context.temp_allocator))
			selected.draw()
		} else {
			ovr_count := engine.project_settings_tab_override_count(selected.name)
			im.SeparatorText(strings.clone_to_cstring(selected.name, context.temp_allocator))

			if ovr_count > 0 {
				widgets.text_coloredf(p.accent, "%s %d Project Override(s) active", icons.ICON_MD_TUNE, ovr_count)
			} else {
				im.TextDisabled("All fields inherited from shared Engine Settings")
			}
			im.SameLine()
			if im.SmallButton(fmt.ctprintf("%s Reset Tab to Defaults", icons.ICON_MD_REFRESH)) {
				if engine.project_settings_reset_tab_to_defaults(selected.name, selected.ptr, selected.tid, false) {
					_settings_force_save_and_sync(selected)
				}
			}
			widgets.tooltip("Reset non-overridden fields in this tab back to Tier 1 Factory Defaults")
			if ovr_count > 0 {
				im.SameLine(0, 6)
				if im.SmallButton(fmt.ctprintf("%s Clear Project Overrides", icons.ICON_MD_CLOSE)) {
					if engine.project_settings_reset_tab_to_defaults(selected.name, selected.ptr, selected.tid, true) {
						_settings_force_save_and_sync(selected)
					}
				}
				widgets.tooltip("Remove all [P] Project Overrides in this tab and revert to Engine Defaults")
			}
			im.Spacing()

			if _, is_custom := inspector.mapPropertyDrawer[selected.tid]; is_custom {
				undo.push_raw_owner(selected.ptr, selected.tid)
				inspector.draw_inspector(any{selected.ptr, selected.tid})
				undo.pop_owner()
			} else {
				cur_json := undo.capture_json(selected.ptr, selected.tid)
				defer if cur_json != nil do delete(cur_json)

				undo.push_raw_owner(selected.ptr, selected.tid)
				defer undo.pop_owner()

				tab_matched := len(filter) == 0 || widgets.search_match(selected.name, filter)
				names := reflect.struct_field_names(selected.tid)
				types := reflect.struct_field_types(selected.tid)
				drawn_fields := 0

				for i in 0 ..< len(names) {
					if types[i].id == typeid_of(engine.CompData) do continue
					finfo := reflect.struct_field_at(selected.tid, i)
					if !_settings_field_visible(finfo.tag) do continue

					fname := names[i]
					if !tab_matched && !_settings_field_matches(fname, finfo.tag, filter) do continue

					is_ovr := engine.project_settings_has_field_override(selected.name, fname)
					is_mod := engine.project_settings_is_field_modified_from_default(selected.name, fname, cur_json)

					switch _settings_view_filter {
					case .All:
					case .Project_Overrides:
						if !is_ovr do continue
					case .Modified:
						if !is_mod && !is_ovr do continue
					}

					drawn_fields += 1
					im.PushIDInt(i32(i))

					ovr_col := is_ovr ? p.accent : im.Vec4{0.25, 0.28, 0.34, 0.70}
					if widgets.small_toggle_button("P", is_ovr, ovr_col, !is_ovr) {
						if engine.project_settings_set_field_override(selected.name, fname, !is_ovr, selected.ptr, selected.tid) {
							_settings_force_save_and_sync(selected)
						}
					}
					widgets.tooltip(is_ovr \
						? "Project Override ACTIVE: saved per-project in ProjectSettings/project_overrides.json. Click [P] to revert to shared Engine Settings." \
						: "Using shared Engine Setting. Click [P] to override this setting for the active project only.")

					im.SameLine(0, 4)
					im.BeginDisabled(!is_mod)
					if im.SmallButton(icons.ICON_MD_REFRESH) {
						if engine.project_settings_reset_field_to_default(selected.name, fname, selected.ptr, selected.tid) {
							_settings_force_save_and_sync(selected)
						}
					}
					im.EndDisabled()
					if is_mod {
						widgets.tooltip("Reset this setting to its Tier 1 Factory Default")
					}

					im.SameLine(0, 8)
					im.BeginGroup()
					inspector.draw_struct_field_at(selected.ptr, selected.tid, i, "")
					im.EndGroup()

					im.PopID()
				}

				if drawn_fields == 0 {
					im.TextDisabled("No settings match the current search/filter in this tab.")
				}
			}

			// Diff-save once the edit is over — not per keystroke or drag frame.
			if !im.IsAnyItemActive() {
				_settings_persist(selected)
			}
		}
	}
	im.EndChild()
	im.PopStyleVar()
}

// The persisted selection when it still exists, the first tab otherwise.
@(private = "file")
_settings_selected_tab :: proc() -> ^_Settings_Tab {
	for &tab in _settings_tabs {
		if tab.name == editor_settings.project_settings_tab do return &tab
	}
	if len(_settings_tabs) > 0 do return &_settings_tabs[0]
	return nil
}

@(menu_separator={path="Edit", order=99})
@(menu_item={path="Edit/Settings...", order=100, shortcut="Ctrl+,"})
open_project_settings :: proc() {
	wnd.open("project_settings")
}
