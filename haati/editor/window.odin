package editor

import gfx "../engine/gfx"
import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:hash"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import "menu"
import thm "haati:editor/theme"
import wnd "window"
import "haati:editor/handles"
import "../engine"
import "../engine/log"
import control_rig_editor "haati:packages/control_rig/editor"

WINDOW_TITLE :: "Haati Editor"
VERSION :: #load("../version", string)

// Per-DEVELOPER editor state, never committed (Unity's UserSettings): window
// geometry, which scenes and windows were open, panel visibility, theme, grid
// and snap choices, the selected run config. All of it is one person's working
// setup — sharing it means every developer's git status is dirty after a run
// and someone else's window position lands in an unrelated commit.
//
// The other half is engine.PROJECT_SETTINGS_DIR: settings about the PROJECT,
// committed, read by the game too (docs/Plugins.md "Project settings").
USER_SETTINGS_DIR :: "UserSettings"
EDITOR_SETTINGS_FILE :: USER_SETTINGS_DIR + "/editor_settings.json"

// Read once at startup to migrate a pre-split checkout, then ignored.
LEGACY_EDITOR_SETTINGS_FILE :: engine.PROJECT_SETTINGS_DIR + "/editor_settings.json"

EditorSettings :: struct {
    width:                    i32,
    height:                   i32,
    x:                        i32,
    y:                        i32,
    theme:                    menu.Theme,
    theme_id:                 string,
    ui_density:               thm.UI_Density,
    has_ui_density:           bool,
    corner_style:             thm.Corner_Style,
    use_custom_accent:        bool,
    custom_accent:            [4]f32,
    main_scale:               f32,
    window_scales:            map[string]f32,
    open_scene_guids:         [dynamic]string,
    open_scene_paths:         [dynamic]string,          // File paths of open scenes (for non-asset or external scenes)
    recent_scene_guids:       [dynamic]string,          // File/Recent Scenes, newest first (recent_scenes.odin)
    open_window_ids:          [dynamic]string,          // plugin editor windows open last session (window/window.odin)
    popped_window_ids:        [dynamic]string,          // panels popped out into their own OS window (window/viewports.odin)
    play_mode:                Play_Mode,                // what the Play button does (simulate_view.odin)
    show_console:             bool,
    show_scene:               bool,
    show_game:                bool,
    show_output:              bool,
    show_history:             bool,
    show_animation:           bool,
    show_playable_graph:      bool,
    has_view_state:           bool,
    scene_overlays:           [dynamic]Overlay_Setting, // dockable overlay placement (dock.odin)
    grid:                     Grid_Settings,            // scene grid (view_scene.odin)
    snap:                     Snap_Settings,            // gizmo snapping (view_scene.odin)
    run_config:               string,                   // Play button's selected run config (view_toolbar.odin), "pkg/name"
    sim_host:                 string,                   // Simulate's host package name (simulate.odin), e.g. "app"
    project_settings_tab:     string,                   // Project Settings window's selected section (project_settings.odin)
    project_zoom:             f32,                      // project view zoom: 0 = list, >0 = thumbnail grid (view_project.odin)
    scene_ortho:              bool,                     // scene view projection (view_scene.odin)
    scene_2d:                 bool,                     // scene view 2D mode (view_scene.odin)
    scene_2d_angle:           Scene_2D_Angle,           // scene view 2D orthographic angle (Front, Back, Right, Left, Top, Bottom)
    scene_2d_wheel_step:      f32,                      // 2D mode depth step per wheel notch
    has_workspace_state:      bool,                     // true when gizmo & viewport mode state has been saved
    gizmo_mode:               Gizmo_Mode,               // active transform tool (Q/W/E/R/T)
    gizmo_space:              Gizmo_Space,              // Global vs Local gizmo orientation
    gizmo_pivot:              Gizmo_Pivot,              // Pivot vs Center gizmo origin
    viewport_mode:            control_rig_editor.Scene_Viewport_Mode, // Default Scene vs Control Rig workspace
    char_edit_mode:           control_rig_editor.Character_Edit_Mode, // Bone Mode / Rig Controls / Hand Poses / Colliders
    game_size_index:          int,                      // game view size list entry (view_game.odin)
    game_scale:               f32,                      // game view zoom (view_game.odin)
    game_size_flipped:        bool,                     // game view size width/height swap (view_game.odin)
    game_gizmos:              bool,                     // game view Gizmos toggle (view_game.odin)
    scene_gizmos_off:         bool,                     // scene view Gizmos toggle, inverted so an older file keeps it on (gizmo_settings.odin)
    gizmo_icon_px:            f32,                      // gizmo settings' Icon Size, 0 = the default
    gizmo_hidden_icons:       [dynamic]string,          // component types whose icon the gizmo settings hide
    gizmo_hidden_gizmos:      [dynamic]string,          // component types whose gizmo the gizmo settings hide
    scene_fly_smooth_tau:     f32,                      // Flythrough stopping time constant (lower = snappier)
    scene_look_sensitivity:   f32,                      // Camera look & orbit sensitivity
    scene_fly_speed:          f32,                      // Camera fly / move speed in units/sec
    scene_cam_has_pos:        bool,                     // scene view camera position persisted
    scene_cam_pos:            [3]f32,                   // scene view camera eye position (view_scene.odin)
    scene_cam_yaw:            f32,                      // scene view camera yaw in radians
    scene_cam_pitch:          f32,                      // scene view camera pitch in radians
    scene_cam_dist:           f32,                      // scene view camera orbit distance
    scene_views:              map[string]SceneCameraView, // Persisted camera state per scene path
}

SceneCameraView :: struct {
    has_pos:  bool,
    pos:      [3]f32,
    yaw:      f32,
    pitch:    f32,
    dist:     f32,
    ortho:    bool,
    is_2d:    bool,
    angle_2d: Scene_2D_Angle,
}

NO_SAVED_WINDOW_POS :: i32(-32000)

// Pure bounds check factored out so dual-monitor and minimized-window cases can be unit-tested without SDL displays.
window_rect_visible_in_bounds :: proc(x, y, w, h: i32, usable_bounds: []sdl.Rect) -> bool {
    if x == NO_SAVED_WINDOW_POS || y == NO_SAVED_WINDOW_POS do return false
    if w < 100 || h < 100 do return false
    for bounds in usable_bounds {
        ix0 := max(x, bounds.x)
        iy0 := max(y, bounds.y)
        ix1 := min(x + w, bounds.x + bounds.w)
        iy1 := min(y + h, bounds.y + bounds.h)
        if ix1 - ix0 >= 64 && iy1 - iy0 >= 64 {
            return true
        }
    }
    return false
}

window_rect_visible_on_any_display :: proc(x, y, w, h: i32) -> bool {
    if x == NO_SAVED_WINDOW_POS || y == NO_SAVED_WINDOW_POS || w < 100 || h < 100 {
        return false
    }
    count: i32
    displays := sdl.GetDisplays(&count)
    if displays == nil || count <= 0 do return false
    defer sdl.free(displays)
    bounds_buf: [16]sdl.Rect
    bounds_count := 0
    for i in 0 ..< count {
        if bounds_count >= len(bounds_buf) do break
        bounds: sdl.Rect
        if !sdl.GetDisplayUsableBounds(displays[i], &bounds) do continue
        bounds_buf[bounds_count] = bounds
        bounds_count += 1
    }
    return window_rect_visible_in_bounds(x, y, w, h, bounds_buf[:bounds_count])
}

editor_settings: EditorSettings

load_editor_settings :: proc() -> (w, h, x, y: i32) {
    context.allocator = runtime.default_allocator()
    editor_settings.x = NO_SAVED_WINDOW_POS
    editor_settings.y = NO_SAVED_WINDOW_POS
    data, read_err := os.read_entire_file(EDITOR_SETTINGS_FILE, context.temp_allocator)
    if read_err != nil && engine.has_active_project() && !os.exists("haati.project") {
        eng_path := strings.concatenate({engine.engine_haati_dir(context.temp_allocator), "/", EDITOR_SETTINGS_FILE}, context.temp_allocator)
        data, read_err = os.read_entire_file(eng_path, context.temp_allocator)
        if read_err == nil {
            log.infof("[startup] adopting %q into %q", eng_path, EDITOR_SETTINGS_FILE)
        }
    }
    if read_err != nil {
        // Pre-split checkout: adopt the committed file's values once. The next
        // save writes UserSettings/ and this branch stops being taken.
        data, read_err = os.read_entire_file(LEGACY_EDITOR_SETTINGS_FILE, context.temp_allocator)
        if read_err == nil {
            log.infof("[startup] migrating %q to %q", LEGACY_EDITOR_SETTINGS_FILE, EDITOR_SETTINGS_FILE)
        }
    }
    if read_err == nil {
        _last_settings_fnv = hash.fnv64a(data)
        err := json.unmarshal(data, &editor_settings)
        if err == nil {
            // Zero grid/snap = settings file predates the field; keep code defaults.
            if editor_settings.grid.cells_count > 0 && editor_settings.grid.cell_size > 0 {
                grid_settings = editor_settings.grid
            }
            if editor_settings.snap.angle > 0 {
                snap_settings = editor_settings.snap
            }
            scene_cam_ortho = editor_settings.scene_ortho
            scene_2d_angle = editor_settings.scene_2d_angle
            if editor_settings.scene_2d_wheel_step > 0 {
                scene_2d_wheel_step = editor_settings.scene_2d_wheel_step
            }
            if editor_settings.has_workspace_state {
                gizmo_mode = editor_settings.gizmo_mode
                gizmo_space = editor_settings.gizmo_space
                gizmo_pivot = editor_settings.gizmo_pivot
                control_rig_editor.scene_viewport_mode = editor_settings.viewport_mode
                control_rig_editor.character_edit_mode = editor_settings.char_edit_mode
            }
            game_size_index = editor_settings.game_size_index
            // Zero = the field predates this setting; keep the 1x default.
            if editor_settings.game_scale > 0 do game_scale = editor_settings.game_scale
            game_size_flipped = editor_settings.game_size_flipped
            game_gizmos = editor_settings.game_gizmos
            scene_gizmos = !editor_settings.scene_gizmos_off
            if editor_settings.gizmo_icon_px > 0 do handles.icon_px = editor_settings.gizmo_icon_px
            for name in editor_settings.gizmo_hidden_icons do gizmo_type_set(name, .Icon, false)
            for name in editor_settings.gizmo_hidden_gizmos do gizmo_type_set(name, .Gizmo, false)
            if editor_settings.scene_fly_smooth_tau > 0 do scene_fly_move_smooth_tau = editor_settings.scene_fly_smooth_tau
            if editor_settings.scene_look_sensitivity > 0 do scene_look_sensitivity = editor_settings.scene_look_sensitivity
            if editor_settings.scene_fly_speed >= FLYTHROUGH_MIN_SPEED {
                scene_fly_speed = editor_settings.scene_fly_speed
                _fly_speed_cur = scene_fly_speed
            } else {
                scene_fly_speed = FLYTHROUGH_BASE_SPEED
                _fly_speed_cur = FLYTHROUGH_BASE_SPEED
            }
            if editor_settings.scene_2d do _scene_2d_pending = true
            if editor_settings.has_view_state {
                menu.show_console           = editor_settings.show_console
                menu.show_scene             = editor_settings.show_scene
                menu.show_game              = editor_settings.show_game
                menu.show_output            = editor_settings.show_output
                menu.show_history           = editor_settings.show_history
                menu.show_animation         = editor_settings.show_animation
                menu.show_playable_graph    = editor_settings.show_playable_graph
            }
            if editor_settings.main_scale > 0.1 {
                wnd.set_main_scale(editor_settings.main_scale)
            }
            if len(editor_settings.window_scales) > 0 {
                wnd.set_all_window_scales(editor_settings.window_scales)
            }
            if len(editor_settings.scene_views) > 0 {
                clean_views := make(map[string]SceneCameraView)
                for k, v in editor_settings.scene_views {
                    if strings.has_suffix(k, ".scene") {
                        clean_views[strings.clone(k)] = v
                    }
                    delete(k)
                }
                delete(editor_settings.scene_views)
                editor_settings.scene_views = clean_views
            }
            if len(editor_settings.popped_window_ids) > 0 {
                // Clear legacy persisted NoAutoMerge locks so every floating panel stays dockable.
                for s in editor_settings.popped_window_ids do delete(s)
                clear(&editor_settings.popped_window_ids)
            }
            if editor_settings.width > 0 && editor_settings.height > 0 {
                return editor_settings.width, editor_settings.height, editor_settings.x, editor_settings.y
            }
        }
    }
    return 0, 0, NO_SAVED_WINDOW_POS, NO_SAVED_WINDOW_POS
}

apply_editor_theme :: proc() {
    resolved: thm.Theme_Id = .Antigravity_Dark
    if parsed, ok := thm.from_key(editor_settings.theme_id); ok {
        resolved = parsed
    }
    thm.set_density(editor_settings.has_ui_density ? editor_settings.ui_density : .Clean)
    thm.set_corners(editor_settings.corner_style)
    thm.set_custom_accent(editor_settings.use_custom_accent, editor_settings.custom_accent)
    menu.set_theme(resolved)
}

apply_default_window_size :: proc() {
    dx, dy, dw, dh := gfx.display_usable_bounds()
    w := i32(f32(dw) * 0.85)
    h := i32(f32(dh) * 0.85)
    gfx.set_window_geometry(dx + (dw - w) / 2, dy + (dh - h) / 2, w, h)
}

@(private = "file")
_last_settings_fnv: u64
@(private = "file")
_settings_dir_ready: bool

save_editor_settings :: proc() {
    prev_alloc := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev_alloc
    if !_settings_dir_ready {
        os.make_directory(USER_SETTINGS_DIR)
        _settings_dir_ready = true
    }
    if w := gfx.window(); w != nil && .MINIMIZED not_in sdl.GetWindowFlags(w) && !engine.is_project_hub_startup() {
        pos := gfx.window_position()
        size := gfx.window_size()
        if size.x > 0 && size.y > 0 {
            editor_settings.width  = size.x
            editor_settings.height = size.y
            editor_settings.x      = pos.x
            editor_settings.y      = pos.y
        }
    }
    editor_settings.theme  = thm.active()
    if len(editor_settings.theme_id) > 0 do delete(editor_settings.theme_id)
    editor_settings.theme_id = strings.clone(thm.to_key(thm.active()))
    editor_settings.ui_density     = thm.density()
    editor_settings.has_ui_density = true
    editor_settings.corner_style   = thm.corners()
    editor_settings.use_custom_accent, editor_settings.custom_accent = thm.custom_accent_state()
    editor_settings.show_console           = menu.show_console
    editor_settings.show_scene             = menu.show_scene
    editor_settings.show_game              = menu.show_game
    editor_settings.show_output            = menu.show_output
    editor_settings.show_history           = menu.show_history
    editor_settings.show_animation         = menu.show_animation
    editor_settings.show_playable_graph    = menu.show_playable_graph
    editor_settings.has_view_state         = true

    // Plugin windows: imgui.ini keeps their dock and size, not whether they
    // existed — the id list is what reopens them.
    for s in editor_settings.open_window_ids do delete(s)
    delete(editor_settings.open_window_ids)
    editor_settings.open_window_ids = make([dynamic]string)
    for id in wnd.open_ids(context.temp_allocator) {
        append(&editor_settings.open_window_ids, strings.clone(id))
    }

    // Panels popped out into their own OS window (NoAutoMerge is per-session
    // state imgui does not save; imgui.ini keeps only their position).
    for s in editor_settings.popped_window_ids do delete(s)
    delete(editor_settings.popped_window_ids)
    editor_settings.popped_window_ids = make([dynamic]string)
    for id in wnd.popped_ids(context.temp_allocator) {
        // Lifted out only for a "New Window" run: it goes back on Stop.
        if game_popped_for_play && id == "Game" do continue
        append(&editor_settings.popped_window_ids, strings.clone(id))
    }

    // Window scale persistence (main scale + per-window zooms)
    editor_settings.main_scale = wnd.get_main_scale()
    for k in editor_settings.window_scales do delete(k)
    delete(editor_settings.window_scales)
    editor_settings.window_scales = make(map[string]f32)
    for k, v in wnd.get_all_window_scales(context.temp_allocator) {
        editor_settings.window_scales[strings.clone(k)] = v
    }

    overlays_capture_settings()
    editor_settings.grid = grid_settings
    editor_settings.snap = snap_settings
    editor_settings.scene_ortho = _pre_2d_ortho if scene_2d_mode else scene_cam_ortho
    editor_settings.scene_2d = scene_2d_mode
    editor_settings.scene_2d_angle = scene_2d_angle
    editor_settings.scene_2d_wheel_step = scene_2d_wheel_step
    editor_settings.has_workspace_state = true
    editor_settings.gizmo_mode = gizmo_mode
    editor_settings.gizmo_space = gizmo_space
    editor_settings.gizmo_pivot = gizmo_pivot
    editor_settings.viewport_mode = control_rig_editor.scene_viewport_mode
    editor_settings.char_edit_mode = control_rig_editor.character_edit_mode
    editor_settings.game_size_index = game_size_index
    editor_settings.game_scale = game_scale
    editor_settings.game_size_flipped = game_size_flipped
    editor_settings.game_gizmos = game_gizmos
    editor_settings.scene_gizmos_off = !scene_gizmos
    editor_settings.gizmo_icon_px = handles.icon_px
    for s in editor_settings.gizmo_hidden_icons do delete(s)
    delete(editor_settings.gizmo_hidden_icons)
    for s in editor_settings.gizmo_hidden_gizmos do delete(s)
    delete(editor_settings.gizmo_hidden_gizmos)
    editor_settings.gizmo_hidden_icons = gizmo_types_hiding(.Icon)
    editor_settings.gizmo_hidden_gizmos = gizmo_types_hiding(.Gizmo)
    editor_settings.scene_fly_smooth_tau = scene_fly_move_smooth_tau
    editor_settings.scene_look_sensitivity = scene_look_sensitivity
    editor_settings.scene_fly_speed = scene_fly_speed
    editor_settings.scene_cam_has_pos = true
    editor_settings.scene_cam_pos = scene_cam_pos
    editor_settings.scene_cam_yaw = _pre_2d_yaw if scene_2d_mode else scene_cam_yaw
    editor_settings.scene_cam_pitch = _pre_2d_pitch if scene_2d_mode else scene_cam_pitch
    editor_settings.scene_cam_dist = scene_cam_dist

    active_sc := engine.sm_scene_get_active()
    if active_sc != nil && len(active_sc.path) > 0 {
        if editor_settings.scene_views == nil {
            editor_settings.scene_views = make(map[string]SceneCameraView)
        }
        key_to_use := active_sc.path
        if !(active_sc.path in editor_settings.scene_views) {
            key_to_use = strings.clone(active_sc.path)
        }
        editor_settings.scene_views[key_to_use] = SceneCameraView{
            has_pos  = true,
            pos      = scene_cam_pos,
            yaw      = _pre_2d_yaw if scene_2d_mode else scene_cam_yaw,
            pitch    = _pre_2d_pitch if scene_2d_mode else scene_cam_pitch,
            dist     = scene_cam_dist,
            ortho    = _pre_2d_ortho if scene_2d_mode else scene_cam_ortho,
            is_2d    = scene_2d_mode,
            angle_2d = scene_2d_angle,
        }
    }

    for s in editor_settings.open_scene_guids do delete(s)
    delete(editor_settings.open_scene_guids)
    for s in editor_settings.open_scene_paths do delete(s)
    delete(editor_settings.open_scene_paths)
    editor_settings.open_scene_guids = make([dynamic]string)
    editor_settings.open_scene_paths = make([dynamic]string)

    sm := engine.ctx_scene_manager()
    seen_save_guids := make(map[uuid.Identifier]bool, context.temp_allocator)
    seen_save_paths := make(map[string]bool, context.temp_allocator)
    for i in 0..<sm.count {
        scene := sm.loaded[i]
        if scene == nil || !engine.sm_scene_is_valid(scene) || len(scene.path) == 0 do continue
        save_path := scene.path
        if guid, ok := engine.asset_db_get_guid(scene.path); ok && guid != {} {
            if seen_save_guids[guid] do continue
            seen_save_guids[guid] = true
            if db_path, pok := engine.asset_db_get_path(guid); pok && len(db_path) > 0 {
                save_path = db_path
            }
            guid_str := uuid.to_string(guid, context.temp_allocator)
            append(&editor_settings.open_scene_guids, strings.clone(guid_str))
        }
        if !seen_save_paths[save_path] {
            seen_save_paths[save_path] = true
            append(&editor_settings.open_scene_paths, strings.clone(save_path))
        }
    }

    opts := json.Marshal_Options{
        spec       = .JSON,
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
    }
    if data, err := json.marshal(editor_settings, opts, allocator = context.temp_allocator); err == nil {
        h := hash.fnv64a(data)
        if h == _last_settings_fnv {
            return
        }
        _last_settings_fnv = h
        _ = os.write_entire_file(EDITOR_SETTINGS_FILE, data)
    }
}

editor_settings_shutdown :: proc() {
    context.allocator = runtime.default_allocator()
    if editor_settings.theme_id != "" do delete(editor_settings.theme_id)
    if editor_settings.run_config != "" do delete(editor_settings.run_config)
    if editor_settings.sim_host != "" do delete(editor_settings.sim_host)
    if editor_settings.project_settings_tab != "" do delete(editor_settings.project_settings_tab)

    for s in editor_settings.open_scene_guids do delete(s)
    delete(editor_settings.open_scene_guids)
    for s in editor_settings.open_scene_paths do delete(s)
    delete(editor_settings.open_scene_paths)
    for s in editor_settings.recent_scene_guids do delete(s)
    delete(editor_settings.recent_scene_guids)
    for s in editor_settings.open_window_ids do delete(s)
    delete(editor_settings.open_window_ids)
    for s in editor_settings.popped_window_ids do delete(s)
    delete(editor_settings.popped_window_ids)
    for s in editor_settings.scene_overlays do delete(s.id)
    delete(editor_settings.scene_overlays)
    for s in editor_settings.gizmo_hidden_icons do delete(s)
    delete(editor_settings.gizmo_hidden_icons)
    for s in editor_settings.gizmo_hidden_gizmos do delete(s)
    delete(editor_settings.gizmo_hidden_gizmos)

    for k in editor_settings.window_scales do delete(k)
    delete(editor_settings.window_scales)
    for k in editor_settings.scene_views do delete(k)
    delete(editor_settings.scene_views)

    editor_settings = {}
}
