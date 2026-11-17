package editor

// Guards around imgui's multi-viewport platform windows (panels popped out
// into their own OS windows, plus the tooltips/popups that spill outside the
// main window). See window/viewports.odin for the pop-out feature itself.
//
// WHY: imgui's SDL3 backend parents every secondary OS window to another one
// (SDL_SetWindowParent: tooltips/popups to the window they belong to, panels
// to the main window). SDL_DestroyWindow destroys a window's CHILDREN too,
// behind imgui's back. When a popped panel's OS window went away (reunite,
// merge back, the temporary window used while dragging), SDL silently killed
// the tooltip/popup windows parented to it; imgui then released them from the
// GPU by window id, found nothing, and the SDL Vulkan driver kept a window
// event watch with a dangling SDL_Window pointer (plus a leaked swapchain).
// When a later window reused that address, a resize/focus event (alt-tab)
// ran the stale watch and SDL wrote through a NULL window-data pointer:
// access violation inside SDL3.dll (Windows event log, exception 0xc000041d).
//
// FIX: no SDL parent links between imgui's OS windows, so only imgui ever
// destroys them, always in its own order (renderer release, then window).
// The backend sets the parent at creation and re-applies it in UpdateWindow
// only when imgui's parent changes, so both hooks unparent after the original.

import "base:runtime"
import im "haati:external/odin-imgui"
import sdl "vendor:sdl3"
import gfx "../engine/gfx"
import input "../engine/input"

@(private = "file") _orig_platform_create_window:   proc "c" (vp: ^im.Viewport)
@(private = "file") _orig_platform_update_window:   proc "c" (vp: ^im.Viewport)
@(private = "file") _orig_platform_set_window_pos:  proc "c" (vp: ^im.Viewport, pos: im.Vec2)
@(private = "file") _orig_platform_set_window_size: proc "c" (vp: ^im.Viewport, size: im.Vec2)
@(private = "file") _orig_renderer_render_window:   proc "c" (vp: ^im.Viewport, render_arg: rawptr)
@(private = "file") _orig_renderer_swap_buffers:    proc "c" (vp: ^im.Viewport, render_arg: rawptr)

@(private = "file")
_Sec_Throttle_Slot :: struct {
	id:      im.ID,
	last_ns: u64,
	skipped: bool,
}

@(private = "file") _sec_throttle_slots: [32]_Sec_Throttle_Slot
@(private = "file") _editor_mouse_drag_active: bool

@(private = "file")
_sec_slot_for_vp :: proc "c" (vp_id: im.ID) -> ^_Sec_Throttle_Slot {
	free_idx := -1
	oldest_idx := 0
	for &s, i in _sec_throttle_slots {
		if s.id == vp_id do return &s
		if s.id == 0 && free_idx < 0 do free_idx = i
		if s.last_ns < _sec_throttle_slots[oldest_idx].last_ns do oldest_idx = i
	}
	idx := free_idx >= 0 ? free_idx : oldest_idx
	_sec_throttle_slots[idx] = {id = vp_id}
	return &_sec_throttle_slots[idx]
}

// Returns the secondary OS viewport currently being dragged by the user (or nil if none/main).
viewport_active_dragged_os_viewport :: proc "c" () -> ^im.Viewport {
	g_ctx := im.GetCurrentContext()
	if g_ctx == nil || g_ctx.MovingWindow == nil do return nil
	vp := g_ctx.MovingWindow.Viewport
	main_vp := im.GetMainViewport()
	if vp == nil || (main_vp != nil && vp.ID_ == main_vp.ID_) do return nil
	return (^im.Viewport)(vp)
}

@(private = "file")
_renderer_render_window_hook :: proc "c" (vp: ^im.Viewport, render_arg: rawptr) {
	if drag_vp := viewport_active_dragged_os_viewport(); drag_vp != nil && vp != nil && vp.ID_ != drag_vp.ID_ {
		slot := _sec_slot_for_vp(vp.ID_)
		now_ns := sdl.GetTicksNS()
		if slot.last_ns != 0 && now_ns - slot.last_ns < 40_000_000 {
			slot.skipped = true
			return
		}
		slot.last_ns = now_ns
		slot.skipped = false
	} else if vp != nil {
		slot := _sec_slot_for_vp(vp.ID_)
		slot.last_ns = sdl.GetTicksNS()
		slot.skipped = false
	}
	if _orig_renderer_render_window != nil do _orig_renderer_render_window(vp, render_arg)
}

@(private = "file")
_renderer_swap_buffers_hook :: proc "c" (vp: ^im.Viewport, render_arg: rawptr) {
	if drag_vp := viewport_active_dragged_os_viewport(); drag_vp != nil && vp != nil && vp.ID_ != drag_vp.ID_ {
		slot := _sec_slot_for_vp(vp.ID_)
		if slot.skipped do return
	}
	if _orig_renderer_swap_buffers != nil do _orig_renderer_swap_buffers(vp, render_arg)
}

// Resolve the SDL_Window from a viewport's PlatformHandle (handles both SDL_WindowID
// and direct ^sdl.Window pointer conventions across ImGui SDL3 backend versions).
@(private = "file")
_viewport_sdl_window :: proc "c" (vp: ^im.Viewport) -> ^sdl.Window {
	if vp == nil || vp.PlatformHandle == nil do return nil
	if w := sdl.GetWindowFromID(sdl.WindowID(uintptr(vp.PlatformHandle))); w != nil {
		return w
	}
	return (^sdl.Window)(vp.PlatformHandle)
}

@(private = "file")
_unparent_viewport_window :: proc "c" (vp: ^im.Viewport) {
	w := _viewport_sdl_window(vp)
	if w != nil && sdl.GetWindowParent(w) != nil {
		_ = sdl.SetWindowParent(w, nil)
	}
}

@(private = "file")
_platform_create_window_hook :: proc "c" (vp: ^im.Viewport) {
	if _orig_platform_create_window != nil do _orig_platform_create_window(vp)
	_unparent_viewport_window(vp)
	context = runtime.default_context()
	if w := _viewport_sdl_window(vp); w != nil {
		gfx.apply_dark_window_chrome(w)
	}
}

@(private = "file")
_platform_update_window_hook :: proc "c" (vp: ^im.Viewport) {
	if _orig_platform_update_window != nil do _orig_platform_update_window(vp)
	_unparent_viewport_window(vp)
}

@(private = "file")
_platform_set_window_pos_hook :: proc "c" (vp: ^im.Viewport, pos: im.Vec2) {
	if w := _viewport_sdl_window(vp); w != nil {
		cx, cy: i32
		_ = sdl.GetWindowPosition(w, &cx, &cy)
		tx := i32(pos.x)
		ty := i32(pos.y)
		if cx == tx && cy == ty do return
	}
	if _orig_platform_set_window_pos != nil do _orig_platform_set_window_pos(vp, pos)
}

@(private = "file")
_platform_set_window_size_hook :: proc "c" (vp: ^im.Viewport, size: im.Vec2) {
	if w := _viewport_sdl_window(vp); w != nil {
		cw, ch: i32
		_ = sdl.GetWindowSize(w, &cw, &ch)
		tw := i32(size.x)
		th := i32(size.y)
		if cw == tw && ch == th do return
	}
	if _orig_platform_set_window_size != nil do _orig_platform_set_window_size(vp, size)
}

// True when ImGui currently hosts any secondary platform window (popped-out panel,
// dragged floating window, or spilled-over popup).
viewport_any_secondary_window :: proc() -> bool {
	pio := im.GetPlatformIO()
	return pio != nil && pio.Viewports.Size > 1
}

// True while a left-mouse drag initiated inside any editor viewport is active.
viewport_is_mouse_dragging :: proc() -> bool {
	return _editor_mouse_drag_active
}

// True when ANY editor OS window (main or popped-out secondary viewport) currently holds
// keyboard or mouse focus.
viewport_any_editor_window_has_focus :: proc() -> bool {
	return _any_editor_sdl_window_has_focus()
}

@(private = "file")
_any_editor_sdl_window_has_focus :: proc() -> bool {
	mf := sdl.GetMouseFocus()
	kf := sdl.GetKeyboardFocus()
	if mf == nil && kf == nil do return false
	main_w := gfx.window()
	if main_w != nil && (mf == main_w || kf == main_w) do return true
	pio := im.GetPlatformIO()
	if pio != nil && pio.Viewports.Size > 0 && pio.Viewports.Data != nil {
		vps := ([^]^im.Viewport)(pio.Viewports.Data)[:pio.Viewports.Size]
		for vp in vps {
			w := _viewport_sdl_window(vp)
			if w != nil && (mf == w || kf == w) do return true
		}
	}
	return false
}

// Returns the refresh rate (Hz) of the main editor window's display.
viewport_main_refresh_hz :: proc() -> f32 {
	if w := gfx.window(); w != nil {
		if did := sdl.GetDisplayForWindow(w); did != 0 {
			dm := sdl.GetDesktopDisplayMode(did)
			if dm != nil && dm.refresh_rate > 1.0 {
				return clamp(dm.refresh_rate, 30.0, 500.0)
			}
		}
	}
	return 60.0
}

// Returns the target display refresh rate (Hz) of whichever editor OS window
// currently owns drag focus or focus, falling back across active ImGui viewports or 60 Hz.
viewport_target_refresh_hz :: proc() -> f32 {
	g_ctx := im.GetCurrentContext()
	if g_ctx != nil && (g_ctx.MovingWindow != nil || g_ctx.DragDropActive) {
		gx, gy: f32
		_ = sdl.GetGlobalMouseState(&gx, &gy)
		if did := sdl.GetDisplayForPoint({i32(gx), i32(gy)}); did != 0 {
			dm := sdl.GetDesktopDisplayMode(did)
			if dm != nil && dm.refresh_rate > 1.0 {
				return clamp(dm.refresh_rate, 30.0, 500.0)
			}
		}
	}
	target_win := sdl.GetKeyboardFocus()
	if target_win == nil do target_win = sdl.GetMouseFocus()
	if target_win == nil do target_win = gfx.window()
	if target_win != nil {
		did := sdl.GetDisplayForWindow(target_win)
		if did != 0 {
			dm := sdl.GetDesktopDisplayMode(did)
			if dm != nil && dm.refresh_rate > 1.0 {
				return clamp(dm.refresh_rate, 30.0, 500.0)
			}
		}
	}
	pio := im.GetPlatformIO()
	if pio != nil && pio.Viewports.Size > 0 && pio.Viewports.Data != nil {
		max_hz := f32(0)
		vps := ([^]^im.Viewport)(pio.Viewports.Data)[:pio.Viewports.Size]
		for vp in vps {
			w := _viewport_sdl_window(vp)
			if w == nil do continue
			did := sdl.GetDisplayForWindow(w)
			if did == 0 do continue
			dm := sdl.GetDesktopDisplayMode(did)
			if dm != nil && dm.refresh_rate > max_hz {
				max_hz = dm.refresh_rate
			}
		}
		if max_hz > 1.0 do return clamp(max_hz, 30.0, 500.0)
	}
	return 60.0
}

viewport_main_covered_by_secondary :: proc() -> bool {
	pio := im.GetPlatformIO()
	if pio == nil || pio.Viewports.Size <= 1 || pio.Viewports.Data == nil do return false
	main_vp := im.GetMainViewport()
	if main_vp == nil || main_vp.Size.x <= 0 || main_vp.Size.y <= 0 do return false
	vps := ([^]^im.Viewport)(pio.Viewports.Data)[:pio.Viewports.Size]
	for i in 1 ..< int(pio.Viewports.Size) {
		vp := vps[i]
		w := _viewport_sdl_window(vp)
		if vp == nil || w == nil do continue
		flags := sdl.GetWindowFlags(w)
		if .MINIMIZED in flags || .HIDDEN in flags do continue
		if vp.Pos.x <= main_vp.Pos.x &&
		   vp.Pos.y <= main_vp.Pos.y &&
		   vp.Pos.x + vp.Size.x >= main_vp.Pos.x + main_vp.Size.x &&
		   vp.Pos.y + vp.Size.y >= main_vp.Pos.y + main_vp.Size.y {
			return true
		}
	}
	return false
}

@(private = "file")
_prev_global_left_down: bool

// Samples the hardware OS cursor right before `im.NewFrame()` during active
// editor mouse drags so window dragging has minimal intra-frame latency inside
// the main window and never drops motion/release events when crossing into or
// out of secondary OS viewports over the desktop.
viewport_platform_sync_drag_mouse :: proc() {
	io := im.GetIO()
	if io == nil || .ViewportsEnable not_in io.ConfigFlags {
		gfx.skip_swapchain_wait_on_drag = false
		gfx.skip_swapchain_wait_secondary = false
		gfx.skip_main_swapchain = false
		return
	}
	if input.is_mouse_relative() {
		_editor_mouse_drag_active = false
		_prev_global_left_down = false
		gfx.skip_swapchain_wait_on_drag = false
		gfx.skip_swapchain_wait_secondary = viewport_any_secondary_window()
		gfx.skip_main_swapchain = viewport_main_covered_by_secondary()
		return
	}

	gx, gy: f32
	btns := sdl.GetGlobalMouseState(&gx, &gy)
	left_down := .LEFT in btns
	left_clicked_edge := left_down && !_prev_global_left_down
	_prev_global_left_down = left_down

	if left_clicked_edge {
		mf := sdl.GetMouseFocus()
		if mf != nil && mf != sdl.GetKeyboardFocus() && _any_editor_sdl_window_has_focus() {
			_ = sdl.RaiseWindow(mf)
		}
	}

	g_ctx := im.GetCurrentContext()
	moving_win := g_ctx != nil && g_ctx.MovingWindow != nil
	drag_drop_active := g_ctx != nil && g_ctx.DragDropActive
	active_drag := moving_win || drag_drop_active

	if !_editor_mouse_drag_active {
		if left_down && active_drag && (_any_editor_sdl_window_has_focus() || im.IsMouseDown(.Left)) {
			_editor_mouse_drag_active = true
		}
	}

	if _editor_mouse_drag_active {
		if active_drag {
			im.IO_AddMousePosEvent(io, gx, gy)
		}
		if !left_down {
			if active_drag {
				im.IO_AddMouseButtonEvent(io, 0, false)
			}
			_editor_mouse_drag_active = false
		}
	}

	if io.WantTextInput {
		kf := sdl.GetKeyboardFocus()
		if kf != nil && _any_editor_sdl_window_has_focus() && !sdl.TextInputActive(kf) {
			_ = sdl.StartTextInput(kf)
		}
	}

	has_secondary := viewport_any_secondary_window()
	gfx.set_multi_viewport_present_mode(has_secondary)
	gfx.skip_swapchain_wait_on_drag = _editor_mouse_drag_active && active_drag && has_secondary
	gfx.skip_swapchain_wait_secondary = has_secondary
	gfx.skip_main_swapchain = viewport_main_covered_by_secondary()
}

// Kept as a no-op hook point in imgui_present_platform_windows (previously toggled
// SetGPUSwapchainParameters on the main window mid-drag, which triggered Vulkan
// swapchain rebuild stalls; secondary windows already use MAILBOX/IMMEDIATE).
viewport_platform_frame_tick :: proc() {
}

// After both imgui backends are initialized (they install the callbacks).
viewport_platform_install :: proc() {
	pio := im.GetPlatformIO()
	if pio.Platform_CreateWindow != nil && pio.Platform_CreateWindow != _platform_create_window_hook {
		_orig_platform_create_window = pio.Platform_CreateWindow
		pio.Platform_CreateWindow = _platform_create_window_hook
	}
	if pio.Platform_UpdateWindow != nil && pio.Platform_UpdateWindow != _platform_update_window_hook {
		_orig_platform_update_window = pio.Platform_UpdateWindow
		pio.Platform_UpdateWindow = _platform_update_window_hook
	}
	if pio.Platform_SetWindowPos != nil && pio.Platform_SetWindowPos != _platform_set_window_pos_hook {
		_orig_platform_set_window_pos = pio.Platform_SetWindowPos
		pio.Platform_SetWindowPos = _platform_set_window_pos_hook
	}
	if pio.Platform_SetWindowSize != nil && pio.Platform_SetWindowSize != _platform_set_window_size_hook {
		_orig_platform_set_window_size = pio.Platform_SetWindowSize
		pio.Platform_SetWindowSize = _platform_set_window_size_hook
	}
	if pio.Renderer_RenderWindow != nil && pio.Renderer_RenderWindow != _renderer_render_window_hook {
		_orig_renderer_render_window = pio.Renderer_RenderWindow
		pio.Renderer_RenderWindow = _renderer_render_window_hook
	}
	if pio.Renderer_SwapBuffers != nil && pio.Renderer_SwapBuffers != _renderer_swap_buffers_hook {
		_orig_renderer_swap_buffers = pio.Renderer_SwapBuffers
		pio.Renderer_SwapBuffers = _renderer_swap_buffers_hook
	}
}

// Present mode for the secondary OS windows. The main window's vsync paces
// the loop; a second vsynced (FIFO) swapchain can wait for another vblank on
// its own and halve the frame rate while a panel is popped out or being
// dragged. MAILBOX, else IMMEDIATE (windowed + compositor: no visible
// tearing), else VSYNC, the one mode every driver supports. Probed on the
// main window — secondary windows share the device and display path.
viewport_secondary_present_mode :: proc "contextless" (device: ^sdl.GPUDevice, main_window: ^sdl.Window) -> sdl.GPUPresentMode {
	if sdl.WindowSupportsGPUPresentMode(device, main_window, .IMMEDIATE) do return .IMMEDIATE
	if sdl.WindowSupportsGPUPresentMode(device, main_window, .MAILBOX) do return .MAILBOX
	return .VSYNC
}
