package editor

// Toolbar and shortcuts for in-editor simulation (docs/Simulate.md). The state
// machine lives in editor/simulate; this file is its view plus the hooks that
// give it access to editor-root state (selection, phases, settings).

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "../engine"
import "../engine/input"
import "../engine/log"
import sim "./simulate"
import "moonhug:editor/icons"
import thm "moonhug:editor/theme"
import wnd "moonhug:editor/window"
import "menu"
import "widgets"

simulate_init :: proc() {
    hosts := make([]sim.Host, len(sim_hosts))
    for h, i in sim_hosts {
        hosts[i] = sim.Host{
            name = h.name, path = h.path,
            update = h.update, fixed_update = h.fixed_update,
        }
    }
    sim.install(sim.Hooks{
        selection_ids    = _sim_selection_ids,
        selection_clear  = sel_scene_clear,
        selection_add_id = _sim_selection_add_id,
        phase            = _sim_fire_phase,
        host_name_load   = _sim_host_name_load,
        host_name_store  = _sim_host_name_store,
    }, hosts)
}

simulate_shutdown :: proc() {
    sim.shutdown()
    delete(sim.hosts())
}

// True when `name` is the active sim host. Generated host-owned phase entries
// call this (phase_editor_run, phases_generated.odin).
sim_host_is :: proc(name: string) -> bool {
    return sim.host_is(name)
}

// Runs a Play queued by request_start — one call per frame, before the views.
sim_start_pending :: proc() {
    sim.tick_pending()
}

sim_tick :: proc(dt: f32) {
    sim.tick(dt)
}

// A run is in progress (playing or paused).
sim_is_active :: proc() -> bool {
    return sim.is_active()
}

@(private="file")
_sim_selection_ids :: proc() -> []engine.Local_ID {
    out := make([dynamic]engine.Local_ID, context.temp_allocator)
    for tH in sel_scene_items() {
        if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)); t != nil {
            append(&out, t.local_id)
        }
    }
    return out[:]
}

@(private="file")
_sim_selection_add_id :: proc(s: ^engine.Scene, id: engine.Local_ID) {
    if tH, ok := engine.scene_find_selectable_transform_local_id(s, id); ok {
        sel_scene_add(tH)
    }
}

// What the Play button (and Ctrl+P) does, picked from the dropdown beside it
// and kept in editor_settings. The first three run the game INSIDE the editor
// and differ only in where it shows; Standalone is a separate process.
Play_Mode :: enum {
    Game_View,  // default: open + focus the Game view (Unity's Play)
    New_Window, // the Game view lifts into its own OS window for the run
    Simulate,   // run without opening/focusing the Game view; the game gets no input (Unreal's Simulate)
    Standalone, // build and launch the game as its own process with the current scene state
}

PLAY_MODE_LABELS := [Play_Mode]cstring{
    .Game_View  = icons.ICON_MD_SPORTS_ESPORTS + "  Play in Game View",
    .New_Window = icons.ICON_MD_OPEN_IN_NEW + "  Play in New Window",
    .Simulate   = icons.ICON_MD_VISIBILITY + "  Simulate (no Game view)",
    .Standalone = icons.ICON_MD_RUN_CONFIG + "  Standalone Game (separate process)",
}

PLAY_MODE_TIPS := [Play_Mode]cstring{
    .Game_View  = "Run in the editor. Opens and focuses the Game view, which receives input.",
    .New_Window = "Run in the editor with the Game view in its own OS window (e.g. a second monitor).\nIt returns to its dock slot when the run stops.",
    .Simulate   = "Run in the editor without opening or focusing the Game view.\nWatch and inspect in the Scene view; the game receives no player input.",
    .Standalone = "Compile and launch the game as a separate process with the current scene state\n(unsaved edits included). Logs stream into the Console. Close its window to stop.\nSlower to start than in-editor play: the game is compiled first.",
}

// The Game view was lifted into its own OS window / opened by this run, so
// Stop puts it back the way it was. Package-level: settings save skips a
// pop-out that only exists for the run.
game_popped_for_play: bool
@(private = "file") _game_opened_for_play: bool

// Start a run in the selected mode (Play button, Edit/Play, Ctrl+P).
@(private = "file")
_play_start :: proc() {
    if editor_settings.play_mode == .Standalone {
        if sel := _selected_run_config(); sel != nil {
            mode := _run_mode_from_modifiers()
            if mode == .Build_And_Run {
                mode = .Dev
            }
            run_app_play(sel.id, sel.source, with_current_scene = true, mode = mode)
        } else {
            log.warning("Standalone play: no run config found (packages/*/run_configs/*.odin)")
        }
        return
    }
    // Deferred by one frame so editor previews unwind first (see
    // sim.request_start) — otherwise their restores land after the scene
    // swap and tracks release at visibly different moments.
    _leave_edit_mode_previews()
    sim.request_start()
}

@(private = "file")
_play_mode_enter :: proc() {
    switch editor_settings.play_mode {
    case .Simulate:
        // The Scene view stays in front; the game reads no input.
        game_view_focused = false
    case .New_Window:
        _game_opened_for_play = !menu.show_game
        menu.show_game = true
        if !wnd.is_popped(icons.TITLE_GAME) && !wnd.in_own_os_window(icons.TITLE_GAME) {
            wnd.pop_out(icons.TITLE_GAME)
            game_popped_for_play = true
        }
        game_view_focus()
    case .Game_View, .Standalone:
        // Standalone never starts an in-editor run from Play; Pause/Step can,
        // and those behave like the default.
        menu.show_game = true
        game_view_focus()
    }
}

@(private = "file")
_play_mode_exit :: proc() {
    if game_popped_for_play {
        wnd.reunite(icons.TITLE_GAME)
        game_popped_for_play = false
    }
    if _game_opened_for_play {
        menu.show_game = false
        _game_opened_for_play = false
    }
}

@(private="file")
_sim_fire_phase :: proc(p: sim.Phase) {
    switch p {
    case .ExitingEditMode:
        console_clear_on_play()
        phase_editor_run(.ExitingEditMode)
    case .EnteredPlayMode:
        _play_mode_enter()
        input.reset_edges() // the Play click is not the game's
        phase_editor_run(.EnteredPlayMode)
    case .ExitingPlayMode:
        _play_mode_exit()
        phase_editor_run(.ExitingPlayMode)
    case .EnteredEditMode: phase_editor_run(.EnteredEditMode)
    }
}

@(private="file")
_sim_host_name_load :: proc() -> string {
    return editor_settings.sim_host
}

@(private="file")
_sim_host_name_store :: proc(name: string) {
    if editor_settings.sim_host != "" do delete(editor_settings.sim_host)
    editor_settings.sim_host = strings.clone(name)
}

@(menu_item={path="Edit/Play", order=30, shortcut="Ctrl+P"})
simulate_menu_play :: proc() {
    if sim.is_active() {
        sim.stop()
    } else {
        _play_start() // in the mode picked beside the Play button
    }
}

// Editor previews pose the world for the render only. They end themselves on
// ExitingEditMode, but that fires INSIDE start() — after the snapshot — so a
// preview running when Play is pressed must be told here, a frame ahead.
@(private = "file")
_leave_edit_mode_previews :: proc() {
    phase_editor_run(.ExitingEditMode)
}

@(menu_item={path="Edit/Pause", order=31, shortcut="Ctrl+Shift+P"})
simulate_menu_pause :: proc() {
    sim.toggle_pause()
}

// Cmd/Ctrl+P toggles Simulate, Cmd/Ctrl+Shift+P pauses. Routed globally so they
// work regardless of which view has focus.
_process_simulate_shortcuts :: proc() {
    toggle := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.P)
    pause := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.ImGuiMod_Shift) | im.KeyChord(im.Key.P)

    // Shift variant first: the plain chord is a prefix of it.
    if im.Shortcut(pause, {.RouteGlobal}) {
        sim.toggle_pause()
        return
    }
    if im.Shortcut(toggle, {.RouteGlobal}) {
        if sim.is_active() {
            sim.stop()
        } else {
            _play_start()
        }
    }
}

// Simulate / Pause / Step, all three always visible and enabled. Pressing Pause
// or Step while stopped enters a held run. The centre of the toolbar, first.
@(toolbar={zone="center", order=0})
_draw_simulate_controls :: proc() {
    style := im.GetStyle()

    active := sim.is_active()
    paused := sim.state() == .Paused

    // Slots sized to their widest glyph, so a button keeps its width when its
    // icon swaps and nothing to the right shifts.
    pad := style.FramePadding.x * 2
    sim_slot := im.Vec2{
        max(im.CalcTextSize(icons.ICON_MD_PLAY_ARROW, nil, false, -1).x,
            im.CalcTextSize(icons.ICON_MD_STOP, nil, false, -1).x) + pad,
        0,
    }
    pause_slot := im.Vec2{
        max(im.CalcTextSize(icons.ICON_MD_PAUSE, nil, false, -1).x,
            im.CalcTextSize(icons.ICON_MD_PLAY_CIRCLE, nil, false, -1).x) + pad,
        0,
    }

    _push_sim_button_bg(active, is_play_btn = true)
    if im.ButtonWithFlags(active \
        ? icons.ICON_MD_STOP + "###SimToggle" \
        : icons.ICON_MD_PLAY_ARROW + "###SimToggle", sim_slot) {
        if active {
            sim.stop()
        } else {
            _play_start()
        }
    }
    _pop_sim_button_bg()
    mode := editor_settings.play_mode
    widgets.tooltip(active \
        ? cstring("Stop (Cmd/Ctrl+P)") \
        : fmt.ctprintf("%s (Cmd/Ctrl+P)\n%s", PLAY_MODE_LABELS[mode], PLAY_MODE_TIPS[mode]))

    // Play mode dropdown: a narrow arrow glued to the Play button.
    im.SameLine(0, 1)
    arrow_slot := im.Vec2{im.CalcTextSize(icons.ICON_MD_EXPAND_MORE, nil, false, -1).x + style.FramePadding.x, 0}
    im.PushStyleVarImVec2(.FramePadding, {style.FramePadding.x * 0.5, style.FramePadding.y})
    if im.ButtonWithFlags(icons.ICON_MD_EXPAND_MORE + "###SimPlayMode", arrow_slot) {
        im.OpenPopup("##sim_play_mode")
    }
    im.PopStyleVar()
    widgets.tooltip(fmt.ctprintf("Play mode: %s", PLAY_MODE_LABELS[mode]))
    if im.BeginPopup("##sim_play_mode") {
        im.TextDisabled("Play Mode")
        im.Separator()
        for m in Play_Mode {
            if im.Selectable(PLAY_MODE_LABELS[m], m == mode) {
                editor_settings.play_mode = m
            }
            widgets.tooltip(PLAY_MODE_TIPS[m])
        }
        all_hosts := sim.hosts()
        if len(all_hosts) > 0 {
            im.Spacing()
            im.Separator()
            im.TextDisabled("In-Editor Sim Host")
            for h, i in all_hosts {
                h_lbl := strings.clone_to_cstring(h.name, context.temp_allocator)
                if im.Selectable(h_lbl, i == sim.host_index()) {
                    sim.set_host(i)
                }
            }
        }
        im.EndPopup()
    }

    im.SameLine(0, style.ItemSpacing.x)
    _push_sim_button_bg(active)
    if im.ButtonWithFlags(paused \
        ? icons.ICON_MD_PLAY_CIRCLE + "###SimPause" \
        : icons.ICON_MD_PAUSE + "###SimPause", pause_slot) {
        if active {
            sim.toggle_pause()
        } else {
            sim.start(paused = true)
        }
    }
    _pop_sim_button_bg()
    widgets.tooltip(active && paused ? "Resume (Cmd/Ctrl+Shift+P)" : "Pause (Cmd/Ctrl+Shift+P)")

    im.SameLine(0, style.ItemSpacing.x)
    _push_sim_button_bg(active)
    if im.Button(icons.ICON_MD_SKIP_NEXT + "###SimStep") {
        sim.step()
    }
    _pop_sim_button_bg()
    widgets.tooltip("Step Frame")
}

// `on` tints with the theme's sim_running accent; off keeps clean tonal pills
// (with a calm status_success emerald glyph on the Play button).
_push_sim_button_bg :: proc(on: bool, is_play_btn: bool = false) {
    style := im.GetStyle()
    p := thm.palette()
    if on {
        hi := thm.lerp_col(p.sim_running, thm.rgb(0xFFFFFF), 0.16)
        lo := thm.lerp_col(p.sim_running, thm.rgb(0x000000), 0.14)
        im.PushStyleColorImVec4(.Button, p.sim_running)
        im.PushStyleColorImVec4(.ButtonHovered, hi)
        im.PushStyleColorImVec4(.ButtonActive, lo)
        im.PushStyleColorImVec4(.Text, thm.rgb(0xFFFFFF))
    } else {
        im.PushStyleColorImVec4(.Button, style.Colors[im.Col.Button])
        im.PushStyleColorImVec4(.ButtonHovered, style.Colors[im.Col.ButtonHovered])
        im.PushStyleColorImVec4(.ButtonActive, style.Colors[im.Col.ButtonActive])
        im.PushStyleColorImVec4(.Text, is_play_btn ? p.status_success : style.Colors[im.Col.Text])
    }
}

_pop_sim_button_bg :: proc() {
    im.PopStyleColor(4)
}
