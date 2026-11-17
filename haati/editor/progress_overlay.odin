package editor

// The editor's progress sink: draws a pumped frame per report while
// blocking work runs on the main thread (startup init, import passes).
// Installed after imgui init and before EditorInit fires, so the window
// shows progress instead of a black square.
//
// Each pump is a complete minimal frame through the SAME begin/end path as
// the main loop — swapchain state stays consistent. Throttled so per-item
// reports cost nothing.

import "core:time"
import sdl "vendor:sdl3"
import gfx "../engine/gfx"
import im "haati:external/odin-imgui"
import im_sdl "haati:external/odin-imgui/imgui_impl_sdl3"
import im_sdlgpu "haati:external/odin-imgui/imgui_impl_sdlgpu3"
import "haati:editor/progress"
import thm "haati:editor/theme"
import wnd "haati:editor/window"
import "haati:editor/widgets"
import "core:fmt"

@(private = "file")
_progress_last_pump: time.Tick

// True while the main loop has a frame in flight — a report from inside a
// frame must NOT pump (nested frame_begin corrupts the swapchain). The
// work still runs, only the redraw is skipped.
@(private = "file")
_in_main_frame: bool

progress_overlay_install :: proc() {
	progress.set_sink(_progress_pump)
}

progress_overlay_uninstall :: proc() {
	progress.set_sink(nil)
}

progress_overlay_frame_scope :: proc(active: bool) {
	_in_main_frame = active
}

@(private = "file")
_progress_pump :: proc(title, info: string, fraction: f32) {
	if _in_main_frame || viewport_any_secondary_window() do return
	now := time.tick_now()
	if time.tick_diff(_progress_last_pump, now) < 33 * time.Millisecond do return
	_progress_last_pump = now

	// Keep the OS responsive (no beachball) — the backend consumes the
	// events, input snapshots resume with the real loop.
	gfx.poll_events(proc(e: ^sdl.Event) { im_sdl.ProcessEvent(e) })

	if !gfx.frame_begin() do return
	im_sdlgpu.NewFrame()
	im_sdl.NewFrame()
	im.NewFrame()
	im.GetStyle().FontScaleMain = wnd.get_main_scale()

	scale := wnd.get_main_scale()
	vp := im.GetMainViewport()
	// Full-viewport transparent host: rippling logo on top, the progress
	// panel (title / bar with percentage / step info) underneath.
	im.SetNextWindowPos(vp.Pos, .Always)
	im.SetNextWindowSize(vp.Size, .Always)
	if im.Begin("##progress_overlay", nil,
		{.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking,
		 .NoBackground, .NoScrollbar, .NoScrollWithMouse}) {
		dl := im.GetWindowDrawList()
		style := im.GetStyle()
		pad := 14 * scale
		panel_w := min(440 * scale, vp.Size.x - 2 * pad)
		panel_h := im.GetTextLineHeightWithSpacing() * 2 + im.GetFrameHeightWithSpacing() + 2 * pad
		logo_size := clamp(min(vp.Size.x, vp.Size.y * 0.8) * 0.42, 96 * scale, 380 * scale)
		gap := 28 * scale
		cx := vp.Pos.x + vp.Size.x * 0.5
		top := vp.Pos.y + (vp.Size.y - (logo_size + gap + panel_h)) * 0.5

		panel_y := vp.Pos.y + (vp.Size.y - panel_h) * 0.5
		if widgets.splash_logo_draw(dl, {cx, top + logo_size * 0.5}, logo_size, f32(im.GetTime())) {
			panel_y = top + logo_size + gap
		}

		p_min := im.Vec2{cx - panel_w * 0.5, panel_y}
		p_max := im.Vec2{p_min.x + panel_w, panel_y + panel_h}
		im.DrawList_AddRectFilled(dl, p_min, p_max, im.GetColorU32ImVec4(thm.palette().bg_panel), style.WindowRounding)
		im.DrawList_PushClipRect(dl, p_min, p_max, true)
		im.SetCursorScreenPos({p_min.x + pad, p_min.y + pad})
		im.BeginGroup()
		inner_w := panel_w - 2 * pad
		im.TextUnformatted(fmt.ctprintf("%s", title))
		if fraction >= 0 {
			// Default overlay text is the percentage.
			im.ProgressBar(clamp(fraction, 0, 1), im.Vec2{inner_w, 0})
		} else {
			// Indeterminate: imgui's moving-bar idiom for unknown totals.
			im.ProgressBar(-1 * f32(im.GetTime()), im.Vec2{inner_w, 0}, "")
		}
		im.TextDisabled("%s", fmt.ctprintf("%s", info))
		im.EndGroup()
		im.DrawList_PopClipRect(dl)
	}
	im.End()

	im.Render()
	swap_bg := thm.palette().bg_canvas
	if gfx.pass_begin_swapchain([4]f32{swap_bg.x, swap_bg.y, swap_bg.z, 1}, depth = false) {
		dd := im.GetDrawData()
		im_sdlgpu.PrepareDrawData(dd, gfx.command_buffer())
		gfx.pass_end(proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) {
			im_sdlgpu.RenderDrawData(im.GetDrawData(), cmd, rp)
		})
	}
	gfx.frame_end()
	imgui_present_platform_windows()
}
