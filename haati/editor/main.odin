package editor

import "core:fmt"
// Debug builds only (the tracking allocator below) — @(require) keeps -vet
// from reading it as unused in a release build.
@(require) import "core:mem"
import sdl "vendor:sdl3"
import gfx "../engine/gfx"
import input "../engine/input"
import strings "core:strings"
import im "haati:external/odin-imgui"
import "haati:engine/gizmos"
import im_sdl "haati:external/odin-imgui/imgui_impl_sdl3"
import im_sdlgpu "haati:external/odin-imgui/imgui_impl_sdlgpu3"
import "inspector"
import "menu"
import thm "haati:editor/theme"
import clip "clipboard"
import "undo"
import wnd "haati:editor/window"
import "haati:editor/widgets"
import "haati:editor/preview"
import "../engine/registration"
import "core:os"
import "../engine"
import "haati:engine_editor/asset_pipeline"
import "haati:editor/progress"
import crash_journal "../engine/crash_journal"
import "core:path/filepath"
import "../engine/log"
import "core:encoding/uuid"
import cs "haati:editor/code_studio"
import vs "haati:editor/visual_script"

main :: proc() {
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)

        defer {
            for _, entry in track.allocation_map {
                fmt.eprintf("leak %v bytes @ %v\n", entry.size, entry.location)
            }
            for entry in track.bad_free_array {
                fmt.eprintf("bad free @ %v\n", entry.location)
            }
            mem.tracking_allocator_destroy(&track)
        }
    }

    // Anchor at moonhug/ before anything reads a relative path. Detection is
    // by directory content, not folder name (engine/project_root.odin).
    engine.project_chdir_root()

    // Before anything that can fault: from here on a crash lands in
    // logs/crash_<pid>.log with a stack (docs/CrashJournal.md).
    crash_journal.init(VERSION)
    // Must be set HERE, not inside init: assertion_failure_proc lives on the
    // context, so it only persists in the scope that assigns it.
    context.assertion_failure_proc = crash_journal.assertion_failure
    for arg in os.args[1:] {
        if arg == "--crash-test" {
            fmt.eprintfln("crash journal self-test: writing %s and faulting", crash_journal.path())
            crash_journal.test_crash()
        }
    }

    win_w, win_h, win_x, win_y := load_editor_settings()
    has_saved_settings := win_w > 0 && win_h > 0
    // Window starts hidden so saved geometry applies before first present.
    if !gfx.init(WINDOW_TITLE, has_saved_settings ? win_w : 800, has_saved_settings ? win_h : 600, show = false) {
        fmt.eprintln("gfx init failed (is SDL3 installed? brew install sdl3)")
        return
    }
    defer gfx.shutdown()

    if has_saved_settings && win_x >= 0 && win_y >= 0 {
        gfx.set_window_geometry(win_x, win_y, win_w, win_h)
    } else if !has_saved_settings {
        apply_default_window_size()
    }
    // NOTE: Do NOT call `gfx.show_window()` here! Keeping the window hidden until
    // ImGui, editor fonts, GPU pipelines, and the dark theme are initialized prevents
    // the Win32 `#FFFFFF` white window flashbang during startup & relaunch!
    dock_icon_pending := true

    // Setup ImGui
    im.CHECKVERSION()
    ctx := im.CreateContext()
    // Before imgui's first frame reads imgui.ini (the loading screen renders
    // frames during startup): the plugin window declarations, then the saved
    // window placement renamed onto the windows' current ids.
    _register_editor_windows()
    migrate_imgui_ini()
    defer im.DestroyContext(ctx)

    // Enable docking (drag window title bars to dock/undock) and
    // multi-viewports: a panel dragged outside the main window (or popped
    // out with its title-bar button, window/viewports.odin) becomes its own
    // OS window. The SDL3 + SDL_GPU backends implement the platform side.
    io := im.GetIO()
    io.ConfigFlags += {.DockingEnable, .ViewportsEnable}
    // Popped-out panels are independent top-level OS windows (own taskbar
    // entry, alt-tab like any app window), not owned by the main window.
    io.ConfigViewportsNoDefaultParent = true
    io.ConfigWindowsMoveFromTitleBarOnly = true

    // Load UI fonts (default text font + merged Material Symbols icons). Must run
    // before the backend builds the font atlas texture.
    editor_fonts_init()

    // SDL3 platform backend (input, DisplaySize, clipboard, text input) +
    // SDLGPU3 renderer backend.
    im_sdl.InitForSDLGPU(gfx.window())
    defer im_sdl.Shutdown()
    imgui_gpu_info := im_sdlgpu.InitInfo{
        Device               = gfx.device(),
        ColorTargetFormat    = gfx.swapchain_format(),
        MSAASamples          = ._1,
        SwapchainComposition = .SDR,
        // Popped-out windows must not add vsync waits of their own
        // (viewport_platform.odin).
        PresentMode          = viewport_secondary_present_mode(gfx.device(), gfx.window()),
    }
    im_sdlgpu.Init(&imgui_gpu_info)
    defer im_sdlgpu.Shutdown()
    // After both backends installed their platform callbacks: keep SDL from
    // destroying imgui's OS windows behind its back (viewport_platform.odin).
    viewport_platform_install()

    apply_editor_theme()
    // Apply window/taskbar icon before showing the window so the MoonHug logo is present from frame 0!
    set_dock_icon("../EditorIcon.png")
    // From here reports draw pumped frames — startup shows dark-themed progress
    // instead of a white/black flash (progress_overlay.odin).
    progress_overlay_install()
    gfx.show_window()

    // Init user context and world
    uc := new(engine.UserContext)
    context.user_ptr = uc
    uc.is_editor = true // engine.application_is_editor; never changes at runtime
    engine.job_system_init()
    defer engine.job_system_shutdown()

    w := new(engine.World)
    engine.w_init(w)
    engine.ctx_get().world = w

    undo_stack := new(undo.Undo_Stack)
    undo.init(undo_stack)
    undo.install(undo_stack)
    // Selection restore/record goes through hooks (undo can't import editor).
    selection_undo_install()
    defer selection_undo_shutdown()
    defer { undo.destroy(undo_stack); free(undo_stack) }

    defer { engine.world_destroy_all(w); free(w) }
    defer free(uc)

    progress.begin("Starting Haati")
    phase_editor_run(.EditorInit)
    progress.end()
    defer phase_editor_run(.EditorShutdown)
    queue_scenes_from_settings()
    frames_presented := 0

    // Resolve which host Simulate ticks, from the generated table
    // (sim_hosts_generated.odin) and the persisted setting. Must follow
    // load_editor_settings.
    simulate_init()
    defer simulate_shutdown()
    // Reopen what was open last session — declarations must exist first.
    if len(editor_settings.open_window_ids) > 0 {
        wnd.open_saved(editor_settings.open_window_ids[:])
    } else {
        wnd.open("void_file_explorer")
        wnd.open("void_hierarchy")
        wnd.open("void_inspector")
    }

    // Guarantee all docked windows in imgui.ini are reopened so ImGui doesn't drop or collapse tabs
    docked_ids := docked_window_ids_from_imgui_ini(context.temp_allocator)
    if len(docked_ids) > 0 {
        wnd.open_saved(docked_ids)
    }
    defer wnd.shutdown()
    defer preview.shutdown()
    _register_project_settings() // @(project_settings) vars -> settings tabs
    project_plugins_register()   // the Plugins tab: plugins/ with a link toggle each
    editor_defaults_init()       // UserSettings/editor_defaults.json + Editor Defaults tab
    defer editor_defaults_shutdown()
    defer settings_shutdown()
    defer thumbnails_shutdown()
    defer asset_previews_shutdown()
    defer preview_world_shutdown()
    mcp_bridge_init() // agent bridge on loopback TCP (docs/McpBridge.md)
    defer mcp_bridge_shutdown()
    defer relaunch_shm_cleanup()
    defer overwatch_recorder_shutdown()
    studio_windows_init()

    for !menu.quit_requested && !gfx.quit_requested() {
        engine.overwatch_frame_begin()
        relaunch_tick()
        studio_windows_frame_tick()
        overwatch_recorder_tick(gfx.delta_time())
        // Startup scenes load here, one per frame, once the dock layout has
        // settled (imgui sizes docked windows over the first few frames) —
        // the user sees the full layout, then scenes appear, instead of a
        // blank window behind a blocking load.
        SCENE_LOAD_WARMUP_FRAMES :: 3
        if frames_presented >= SCENE_LOAD_WARMUP_FRAMES do load_next_pending_scene()
        relaunch_shm_tick_restore(frames_presented)

        // Events feed both the editor input snapshot and imgui (the SDL3
        // backend owns keyboard/mouse/text/clipboard/DisplaySize/DeltaTime).
        gfx.poll_events(proc(e: ^sdl.Event) { im_sdl.ProcessEvent(e) })

        // Unity-style Auto Refresh: re-scan assets when the editor window
        // regains focus (git checkouts, external editors). Incremental
        // mtime-diff — an unchanged tree costs one stat pass.
        // Runs asynchronously off the main thread so that window focus
        // never stalls rendering or freezes the frame loop!
        if input.focus_gained() {
            asset_pipeline.asset_db_refresh_async()
            if dock_icon_pending {
                dock_icon_pending = false
                set_dock_icon("../EditorIcon.png") // cwd was normalized to moonhug/ at startup
            }
        }
        if asset_pipeline.asset_db_refresh_tick() {
            project_dir_cache_invalidate()
        }

        // Skip GPU command buffer creation & offscreen rendering when minimized/hidden ONLY if no
        // popped-out secondary OS windows exist; otherwise keep the frame lifeline running for secondary windows!
        win_flags := sdl.GetWindowFlags(gfx.window())
        has_secondary_lifeline := editor_defaults.keep_secondary_alive_min && (viewport_any_secondary_window() || wnd.any_popped_or_outside())
        if (.MINIMIZED in win_flags || .HIDDEN in win_flags) && !sim_is_active() && !has_secondary_lifeline {
            sdl.Delay(50)
            free_all(context.temp_allocator)
            continue
        }

        // Gently pace the loop when completely unfocused in the background (and not simulating)
        // so the editor never spins the GPU or triggers Windows EcoQoS working-set paging.
        if !input.focused() && !wnd.any_popped_or_outside() && !viewport_any_secondary_window() && !viewport_is_mouse_dragging() && sdl.GetKeyboardFocus() == nil && sdl.GetMouseFocus() == nil && !sim_is_active() && len(_pending_scene_loads) == 0 {
            sdl.Delay(33)
        }

        if !gfx.frame_begin() do continue
        progress_overlay_frame_scope(true)

        // Apply any pending selection operations from other windows or plugins
        hierarchy_apply_pending_select()

        // Publish the selection for package editor windows (the read side of
        // the UserContext inspector channel — engine/user_context.odin).
        // Once per frame rather than at every mutation site: selection moves
        // from clicks, picking, pending-select and undo restore alike.
        engine.inspector_set_active_selection(sel_scene_active())
        engine.inspector_set_inspected_selection(inspector_active_target())
        engine.inspector_set_selection_all(sel_scene_items())

        // Thumbnail generation before ANY view draws: scene previews spawn and
        // destroy live content within this call, so nothing leaks into the
        // frame's visible rendering (thumbnails.odin).
        thumbnails_tick()

        // Agent bridge: before views draw, so screenshot readbacks see the
        // PREVIOUS frame's submitted render targets (mcp_bridge.odin).
        mcp_bridge_tick()

        // Start ImGui frame
        im_sdlgpu.NewFrame()
        im_sdl.NewFrame()
        viewport_platform_sync_drag_mouse()
        im.NewFrame()
        im.GetStyle().FontScaleMain = wnd.get_main_scale()
        text_input_escape_frame() // Escape commits text fields (text_input.odin)

        menu.process_shortcuts()
        draw_tool_bar()
        // Dockspace host under the toolbar; must precede the dockable views'
        // Begin() calls (dock.odin — builds the default layout on first run).
        draw_dockspace()

        _process_undo_shortcuts()
        _process_simulate_shortcuts()
        // Ctrl+Shift+T: Reopen most recently closed editor tab (LIFO stack)
        if !im.GetIO().WantTextInput && im.GetIO().KeyCtrl && im.GetIO().KeyShift && im.IsKeyPressed(.T, false) {
            if reopened, ok := wnd.reopen_last_closed(); ok {
                engine.overwatch_record_event(.Window_Tab, "Shortcut", fmt.tprintf("Reopened closed tab '%s' (Ctrl+Shift+T)", reopened))
            }
        }

        // A Play requested LAST frame starts here: the frame in between let
        // every editor preview restore the world it had posed, so the
        // snapshot captures authored values and tracks release together
        // (sim.request_start).
        sim_start_pending()

        // Advance the in-editor simulation before the views draw, so hierarchy,
        // inspector and scene all show the same frame. Placed AFTER the toolbar
        // so a Stop pressed this frame takes effect before the tick, never
        // ticking a scene that is already being torn down.
        // The game reads input only while the Game view has focus
        // (view_game.odin); editor views read it unblocked.
        // Application focus for the game is the Game view's focus during a
        // run (view_game.odin); the tick is the game scope, editor views
        // read outside it.
        game_view_frame_begin()
        // Gameplay gizmos measure against the game camera: the sim draws them
        // once, and the game view is the one they are for (docs/Gizmos.md).
        if v, ok := _game_gizmo_view(); ok do gizmos.set_view(v)
        input.set_app_focused(!sim_is_active() || game_view_focused)
        input.set_game_scope(true)
        engine.overwatch_phase_begin(.Sim_Tick, "sim_tick")
        sim_tick(gfx.delta_time())
        engine.overwatch_phase_end(.Sim_Tick)
        input.set_game_scope(false)

        // ImGui UI
        engine.overwatch_phase_begin(.Editor_UI, "editor_views")
        scene_2d_sync_viewport()
        project_selection_frame_sync()
        if menu.show_inspector {
            draw_hierarchy_inspector()
        }

        if menu.show_project_inspector {
            inspector.view_inspector_draw(&menu.show_project_inspector)
        }

        if menu.show_console {
            draw_console_view()
        }

        if menu.show_history {
            draw_history_view()
        }

        // Package editor views (animation, playable graph, ...) — each owns
        // its own visibility flag (editor/preview).
        preview.draw_views()
        engine.overwatch_phase_end(.Editor_UI)

        // The scrub preview poses the world ONLY for the scene/game render:
        // apply here, restore right after, so every other consumer of the
        // world this frame (saves, undo, inspector) sees authored values.
        preview.apply_all()
        // Handles and gizmo hooks record once per frame, before any view
        // renders: every view draws the same shapes (gizmo_pass.odin).
        engine.overwatch_phase_begin(.Gizmo_Pass, "gizmo_pass")
        gizmo_pass()
        engine.overwatch_phase_end(.Gizmo_Pass)
        if menu.show_scene {
            engine.overwatch_phase_begin(.Scene_3D_View, "Scene3D")
            draw_scene_view()
            engine.overwatch_phase_end(.Scene_3D_View)
        }

        if menu.show_scene_2d {
            engine.overwatch_phase_begin(.Scene_2D_View, "Scene2D")
            draw_scene_2d_view()
            engine.overwatch_phase_end(.Scene_2D_View)
        }

        if menu.show_game {
            engine.overwatch_phase_begin(.Game_View, "Game")
            draw_game_view()
            engine.overwatch_phase_end(.Game_View)
        }
        preview.restore_all()

        engine.overwatch_phase_begin(.Plugin_Windows, "plugin_windows")
        if menu.show_input_debug {
            draw_input_debug()
        }

        if menu.show_output {
            draw_output_view()
        }

        // Plugin-opened windows (editor/window, docs/Plugins.md).
        wnd.draw_all()
        tab_menu_draw_floating_nodes()
        studio_windows_draw_popups()

        draw_about_popup()
        // Confirmations and other modal questions (widgets/dialog.odin).
        widgets.dialog_draw()
        widgets.code_jump_popup_draw()
        draw_status_bar()
        draw_pending_scene_overlay()
        engine.overwatch_phase_end(.Plugin_Windows)

        // Import settings undo steps: a finished change to a settings document
        // becomes one step (inspector/import_settings_docs.odin).
        inspector.import_settings_track(_frame_may_finish_edit())

        // Selection undo steps (Unity model): diff selection against the
        // frame's baseline after all views handled input.
        selection_undo_track()

        // Render. Scene/game views already encoded their offscreen passes
        // into this frame's command buffer during the UI calls above; imgui's
        // copy passes (PrepareDrawData) must come BEFORE the swapchain render
        // pass, and its draw happens inside it (pass_end callback).
        engine.overwatch_phase_begin(.Swapchain_Present, "swapchain_present")
        im.Render()
        dd := im.GetDrawData()
        im_sdlgpu.PrepareDrawData(dd, gfx.command_buffer())
        swap_bg := thm.palette().bg_canvas
        if gfx.pass_begin_swapchain([4]f32{swap_bg.x, swap_bg.y, swap_bg.z, 1}, depth = false) {
            gfx.pass_end(proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) {
                im_sdlgpu.RenderDrawData(im.GetDrawData(), cmd, rp)
            })
            // A queued full-window screenshot copies the swapchain HERE: the UI
            // has drawn into it and the command buffer is still open. Costs
            // nothing on frames nobody asked for one.
            mcp_bridge_capture_frame()
        } else {
            // Only throttle in software when the main window is genuinely minimized/hidden.
            // Transient single-frame non-blocking swapchain skips during drags must not sleep.
            cur_flags := sdl.GetWindowFlags(gfx.window())
            if .MINIMIZED in cur_flags || .HIDDEN in cur_flags {
                if has_secondary_lifeline && viewport_any_editor_window_has_focus() {
                    sdl.Delay(8)
                } else if !viewport_is_mouse_dragging() {
                    sdl.Delay(editor_defaults_background_delay_ms())
                }
            }
        }
        gfx.frame_end()
        imgui_present_platform_windows()
        engine.overwatch_phase_end(.Swapchain_Present)
        engine.overwatch_frame_end(gfx.delta_time(), sim_is_active())
        progress_overlay_frame_scope(false)
        frames_presented += 1

        @(static) _settings_autosave_sec: f32 = 0
        if input.focused() {
            _settings_autosave_sec += gfx.delta_time()
            if _settings_autosave_sec >= 4.0 {
                _settings_autosave_sec = 0.0
                save_editor_settings()
            }
        }

        free_all(context.temp_allocator)
    }
    delete(_pending_scene_loads)

    save_editor_settings()
    settings_save_all()
}

// Popped-out panels (imgui multi-viewport): create, move, resize, destroy
// their OS windows, then draw each into its own swapchain. Every path that
// ends an imgui frame calls this — the main loop and the progress overlay's
// pumped frames — or the extra windows would freeze while that path runs.
// After gfx.frame_end: the main command buffer (scene/game render targets
// the panels show) is submitted first, on the same GPU queue.
imgui_present_platform_windows :: proc() {
    if .ViewportsEnable not_in im.GetIO().ConfigFlags do return
    viewport_platform_frame_tick()
    im.UpdatePlatformWindows()
    im.RenderPlatformWindowsDefault()
}

@(phase={key=engine.Phase.EditorInit, order=0, mode=Editor})
editor_init :: proc() {
    registration.register_packages()
    // Type keys before the phases, the same order as the app and the tests:
    // SerializationInit subscribers look them up.
    registration.register_type_guids()
    inspector.init()
    phase_editor_run(.SerializationInit)
    phase_editor_run(.ImportersInit)
    clip.init()
    _init_context_menu_registry()
    _register_asset_previews()
    init_project_view()
    progress.report("Scanning assets")
    engine.asset_catalog_auto = true // editor maintains library/catalog.json
    asset_pipeline.asset_pipeline_init()
    engine.asset_db_init("assets")
    asset_pipeline.asset_pipeline_import_all()
    progress.report("Initializing caches")
    engine.texture_cache_init()
    engine.mesh_cache_init()
    engine.material_cache_init()
    engine.shader_cache_init()

    init_scene_view()
    init_scene_2d_view()
    init_game_view()
    setup_menu_items()

    return

    setup_menu_items :: proc() {
        _register_menu_items()
        _register_view_chrome()
        _load_user_settings() // @(user_settings) vars -> UserSettings/*.json
        register_create_asset_menus()
        register_component_menus()

        top_order := make(map[string]int)
        defer delete(top_order)

        top_order["File"] = 0
        top_order["Edit"] = 4
        top_order["Assets"] = 8
        // Create submenu pinned to the top of the Assets menu (Unity).
        top_order["Assets/Create"] = -100
        top_order["GameObject"] = 10 // creation band also mirrors into the hierarchy popup
        top_order["Component"] = 15
        top_order["Tools"] = 20 // plugin/tooling menu items (e.g. packages)
        // Window menu sits before Help (Unity). Submenus first: General,
        // then domain groups (Animation), separator at -7, Theme, Reset
        // Layout (item order 20).
        top_order["Window"] = 25
        top_order["Window/General"] = -20
        top_order["Window/Animation"] = -15
        top_order["Window/Theme"] = 10
        top_order["Help"] = 30
        menu.sort_top_menu(top_order)
    }
}

// The scenes to reopen, resolved once at startup. The main loop loads ONE
// per frame after the first full frame presented — views and dock layout
// are ready, each scene appears on the next frame, and the UI never blanks
// behind a blocking load.
_pending_scene_loads: [dynamic]string

queue_scenes_from_settings :: proc() {
    seen_guids := make(map[uuid.Identifier]bool, context.temp_allocator)
    seen_paths := make(map[string]bool, context.temp_allocator)

    for guid_str in editor_settings.open_scene_guids {
        guid, err := uuid.read(guid_str)
        if err != nil || guid == {} do continue
        if seen_guids[guid] do continue
        path, ok := engine.asset_db_get_path(guid)
        if !ok || len(path) == 0 do continue
        norm_p, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
        if seen_paths[norm_p] do continue
        seen_guids[guid] = true
        seen_paths[norm_p] = true
        append(&_pending_scene_loads, strings.clone(norm_p))
    }
    for path in editor_settings.open_scene_paths {
        if len(path) == 0 do continue
        clean_p, _ := filepath.clean(path, context.temp_allocator)
        norm_p, _ := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)
        if guid, gok := engine.asset_db_get_guid(norm_p); gok && guid != {} {
            if seen_guids[guid] do continue
            if db_path, pok := engine.asset_db_get_path(guid); pok && len(db_path) > 0 {
                norm_p, _ = strings.replace_all(db_path, "\\", "/", context.temp_allocator)
            }
            seen_guids[guid] = true
        }
        if seen_paths[norm_p] do continue
        if os.exists(norm_p) {
            seen_paths[norm_p] = true
            append(&_pending_scene_loads, strings.clone(norm_p))
        } else {
            alt, _ := filepath.join({"packages", norm_p}, context.temp_allocator)
            norm_alt, _ := strings.replace_all(alt, "\\", "/", context.temp_allocator)
            if !seen_paths[norm_alt] && os.exists(norm_alt) {
                seen_paths[norm_alt] = true
                append(&_pending_scene_loads, strings.clone(norm_alt))
            }
        }
    }
}

// One pending scene per call (the per-frame step). The frame presented just
// before this call drew the loading overlay, so THAT is what the user sees
// while the load blocks.
load_next_pending_scene :: proc() {
    if len(_pending_scene_loads) == 0 do return
    path := _pending_scene_loads[0]
    ordered_remove(&_pending_scene_loads, 0)
    defer delete(path)

    // Guard against loading a duplicate copy of an already-loaded scene.
    if sm := engine.ctx_scene_manager(); sm != nil {
        if guid, gok := engine.asset_db_get_guid(path); gok && guid != {} {
            if engine.sm_scene_find_by_guid(engine.Asset_GUID(guid)) != nil {
                return
            }
        }
        for i in 0 ..< sm.count {
            sc := sm.loaded[i]
            if sc != nil && sc.path == path {
                return
            }
        }
    }

    // No pumped frames here — an overlay-only frame would blank the views.
    progress_overlay_frame_scope(true)
    defer progress_overlay_frame_scope(false)
    engine.scene_load_additive_path(path)
}

// Drawn as part of the NORMAL frame while scene loads are pending — the
// views stay visible behind it.
draw_pending_scene_overlay :: proc() {
    if len(_pending_scene_loads) == 0 do return
    vp := im.GetMainViewport()
    im.SetNextWindowPos(
        im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5},
        .Always, im.Vec2{0.5, 0.5},
    )
    scale := wnd.get_main_scale()
    im.SetNextWindowSize(im.Vec2{440 * scale, 0}, .Always)
    if im.Begin("##scene_loading", nil,
        {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking}) {
        im.TextUnformatted("Loading scene")
        im.ProgressBar(-1 * f32(im.GetTime()), im.Vec2{-1, 0}, "")
        im.TextDisabled("%s", fmt.ctprintf("%s", _pending_scene_loads[0]))
    }
    im.End()
}

@(phase={key=engine.Phase.EditorShutdown, order=0, mode=Editor})
editor_shutdown :: proc() {
    join_play_thread()
    studio_windows_shutdown()
    asset_pipeline.asset_db_refresh_shutdown()
    shutdown_game_view()
    shutdown_scene_2d_view()
    shutdown_scene_view()
    engine.texture_cache_shutdown()
    engine.mesh_cache_shutdown()
    engine.material_cache_shutdown()
    engine.shader_cache_shutdown()
    engine.asset_db_shutdown()
    engine.sm_shutdown()
    engine.scene_lib_shutdown()
    _shutdown_context_menu_registry()
    inspector.shutdown_registries()
    shutdown_hierarchy_views()
    shutdown_project_view()
    _save_user_settings()
    menu.shutdown_menu()
    view_chrome_shutdown()
    inspector_lock_shutdown()
    log.info("Editor Shutdown")
    log.shutdown()
}

// Saves the active scene to its file (the hierarchy header menu's Save).
@(menu_item={path="File/Save Scene", order=1, shortcut=""})
scene_save_menu :: proc() {
	scene := engine.sm_scene_get_active()
	if scene == nil || len(scene.path) == 0 do return
	engine.scene_save(scene, scene.path)
}

@(menu_item={path="Assets/Create/Scene", order=0, shortcut=""})
scene_create_menu :: proc() {
	scene := engine.scene_new()
	save_path, _ := filepath.join({projectViewData.currentPath, "Scene.scene"}, context.temp_allocator)
	engine.scene_save(scene, save_path)
}

// Creates a prefab variant of the currently-selected scene asset, written
// alongside it as "<name>_Variant.scene". Registered into the same menu system
// as "Create/Scene", so it appears in the project panel's right-click menu and
// the top Assets menu. Acts on projectViewData.selectedFile (the asset the user
// last clicked); no-op with a console note if no .scene is selected.
@(menu_item={path="Assets/Create/Scene Variant", order=-10, shortcut=""})
scene_create_variant_menu :: proc() {
	if !strings.has_suffix(projectViewData.selectedFile, ".scene") {
		fmt.println("[Editor] Create Scene Variant: select a .scene asset first")
		return
	}
	// selectedFile holds the FULL path (search results span folders).
	create_scene_variant(projectViewData.selectedFile)
}

@(menu_separator={path="Assets/Create", order=-9})
scene_create_variant_separator :: proc() {}

// True on a frame where an edit may have just finished: a widget was let go, a
// mouse button went up, or a key was pressed. Only then can a document differ
// from its last recorded state, so the import settings check runs on those
// frames alone and idle frames cost nothing (comparing a model with 40 clips
// takes about a quarter of a millisecond).
@(private = "file")
_frame_may_finish_edit :: proc() -> bool {
	@(static) was_active: bool
	active := im.IsAnyItemActive()
	defer was_active = active
	if active do return false
	if was_active do return true
	for released in im.GetIO().MouseReleased do if released do return true
	for k in int(im.Key.NamedKey_BEGIN) ..< int(im.Key.NamedKey_END) {
		if im.IsKeyPressed(im.Key(k), false) do return true
	}
	return false
}

// Ctrl+Z / Ctrl+Shift+Z live on the Edit/Undo and Edit/Redo menu items
// (hierarchy_menu.odin) — only the Ctrl+Y redo alias is handled here.
_process_undo_shortcuts :: proc() {
	redo_chord_y := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.Y)
	if im.Shortcut(redo_chord_y, {.RouteGlobal}) {
		if cs.code_studio_has_focus() {
			cs.code_studio_redo()
			return
		}
		if vs.visual_script_has_focus() {
			vs.vs_redo()
			return
		}
		if s := undo.get(); s != nil {
			undo.apply_redo(s)
		}
	}
}
