#+build windows
package overwatch_app

// =============================================================================
// Lightweight Win32 GDI Dashboard for `MoonHug_Overwatch.exe` (Zero GPU Usage!)
// =============================================================================
// Renders a clean Antigravity-styled dark telemetry monitor at 15 Hz on a Win32
// timer while polling the lock-free shared memory ring buffers every 16 ms.
// Survives even if `MoonHug.exe` hard-crashes or GPU-hangs!

import "base:runtime"
import "core:fmt"
import win32 "core:sys/windows"
import ow "moonhug:engine/overwatch_ipc"

foreign import user32 "system:User32.lib"
foreign import gdi32 "system:Gdi32.lib"

@(default_calling_convention = "system")
foreign gdi32 {
	SetTextColor       :: proc(hdc: win32.HDC, color: win32.COLORREF) -> win32.COLORREF ---
	CreateFontW        :: proc(cHeight, cWidth, cEscapement, cOrientation, cWeight: win32.INT, bItalic, bUnderline, bStrikeOut, iCharSet, iOutPrecision, iClipPrecision, iQuality, iPitchAndFamily: win32.DWORD, pszFaceName: win32.LPCWSTR) -> win32.HFONT ---
	MoveToEx           :: proc(hdc: win32.HDC, x, y: win32.INT, lppt: ^win32.POINT) -> win32.BOOL ---
	LineTo             :: proc(hdc: win32.HDC, x, y: win32.INT) -> win32.BOOL ---
	CreatePen          :: proc(iStyle, cWidth: win32.INT, color: win32.COLORREF) -> win32.HPEN ---
	RoundRect          :: proc(hdc: win32.HDC, left, top, right, bottom, width, height: win32.INT) -> win32.BOOL ---
}

OW_BK_TRANSPARENT :: 1
OW_DT_LEFT        :: 0x00000000
OW_DT_SINGLELINE  :: 0x00000020
OW_DT_NOPREFIX    :: 0x00000800

@(private = "file") _font_ui:    win32.HFONT
@(private = "file") _font_bold:  win32.HFONT
@(private = "file") _font_mono:  win32.HFONT
@(private = "file") _btn_stop:   win32.RECT
@(private = "file") _btn_mark:   win32.RECT

@(private = "file")
_rgb :: #force_inline proc "contextless" (r, g, b: u8) -> win32.COLORREF {
	return win32.COLORREF(u32(r) | (u32(g) << 8) | (u32(b) << 16))
}

@(private = "file")
_fill_rect :: proc(hdc: win32.HDC, rc: win32.RECT, col: win32.COLORREF) {
	rc_mut := rc
	br := win32.CreateSolidBrush(col)
	win32.FillRect(hdc, &rc_mut, br)
	win32.DeleteObject(win32.HGDIOBJ(br))
}

@(private = "file")
_draw_text :: proc(hdc: win32.HDC, x, y: i32, s: string, col: win32.COLORREF, font: win32.HFONT) {
	if s == "" do return
	old := win32.SelectObject(hdc, win32.HGDIOBJ(font))
	SetTextColor(hdc, col)
	ws := win32.utf8_to_wstring(s, context.temp_allocator)
	rc := win32.RECT{x, y, x + 900, y + 26}
	win32.DrawTextW(hdc, cstring16(ws), -1, &rc, win32.DrawTextFormat(OW_DT_LEFT | OW_DT_SINGLELINE | OW_DT_NOPREFIX))
	win32.SelectObject(hdc, old)
}

run_overwatch_gui :: proc(s: ^Recorder_Session) {
	hinst := win32.HANDLE(win32.GetModuleHandleW(nil))
	cls_name: cstring16 = "MoonHugOverwatchWndClass"

	wc: win32.WNDCLASSEXW
	wc.cbSize        = size_of(win32.WNDCLASSEXW)
	wc.style         = win32.CS_HREDRAW | win32.CS_VREDRAW
	wc.lpfnWndProc   = _ow_wnd_proc
	wc.hInstance     = win32.HINSTANCE(hinst)
	wc.hCursor       = win32.LoadCursorA(nil, win32.IDC_ARROW)
	wc.lpszClassName = cls_name
	win32.RegisterClassExW(&wc)

	_font_ui   = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, win32.L("Segoe UI"))
	_font_bold = CreateFontW(-15, 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 5, 0, win32.L("Segoe UI"))
	_font_mono = CreateFontW(-13, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, win32.L("Consolas"))

	hwnd := win32.CreateWindowExW(
		win32.WS_EX_TOPMOST,
		cls_name,
		"MoonHug Overwatch — Out-of-Process Flight Recorder",
		win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
		80, 80, 580, 460,
		nil, nil, win32.HINSTANCE(hinst), nil,
	)
	if hwnd == nil do return

	win32.SetTimer(hwnd, 1, 16, nil)  // 60 Hz lock-free SHM drain
	win32.SetTimer(hwnd, 2, 66, nil)  // 15 Hz zero-GPU GDI repaint

	msg: win32.MSG
	for win32.GetMessageW(&msg, nil, 0, 0) > 0 {
		win32.TranslateMessage(&msg)
		win32.DispatchMessageW(&msg)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
_ow_wnd_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	context = runtime.default_context()
	switch msg {
	case win32.WM_TIMER:
		if wparam == 1 {
			session_poll_and_drain(&g_session)
		} else if wparam == 2 {
			win32.InvalidateRect(hwnd, nil, false)
		}
		return 0

	case win32.WM_LBUTTONDOWN:
		mx := i32(i16(lparam & 0xFFFF))
		my := i32(i16((lparam >> 16) & 0xFFFF))
		if mx >= _btn_mark.left && mx <= _btn_mark.right && my >= _btn_mark.top && my <= _btn_mark.bottom {
			session_request_bookmark(&g_session)
			win32.InvalidateRect(hwnd, nil, false)
		} else if mx >= _btn_stop.left && mx <= _btn_stop.right && my >= _btn_stop.top && my <= _btn_stop.bottom {
			session_request_stop(&g_session)
			session_finalize(&g_session)
			win32.InvalidateRect(hwnd, nil, false)
		}
		return 0

	case win32.WM_PAINT:
		ps: win32.PAINTSTRUCT
		hdc := win32.BeginPaint(hwnd, &ps)
		rc: win32.RECT
		win32.GetClientRect(hwnd, &rc)
		w := rc.right - rc.left
		h := rc.bottom - rc.top
		if w > 0 && h > 0 {
			mem_dc := win32.CreateCompatibleDC(hdc)
			bmp    := win32.CreateCompatibleBitmap(hdc, w, h)
			old_bm := win32.SelectObject(mem_dc, win32.HGDIOBJ(bmp))
			_paint_dashboard(mem_dc, w, h, &g_session)
			win32.BitBlt(hdc, 0, 0, w, h, mem_dc, 0, 0, win32.SRCCOPY)
			win32.SelectObject(mem_dc, old_bm)
			win32.DeleteObject(win32.HGDIOBJ(bmp))
			win32.DeleteDC(mem_dc)
		}
		win32.EndPaint(hwnd, &ps)
		return 0

	case win32.WM_CLOSE, win32.WM_DESTROY:
		// Closing the Overwatch window automatically signals the engine to retract its hooks!
		session_request_stop(&g_session)
		session_finalize(&g_session)
		win32.PostQuitMessage(0)
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private = "file")
_paint_dashboard :: proc(hdc: win32.HDC, w, h: i32, s: ^Recorder_Session) {
	win32.SetBkMode(hdc, win32.BKMODE(OW_BK_TRANSPARENT))

	// Antigravity Dark Palette
	bg_main   := _rgb(16, 18, 23)
	bg_card   := _rgb(24, 27, 34)
	txt_prim  := _rgb(235, 240, 248)
	txt_muted := _rgb(142, 152, 170)
	col_ok    := _rgb(68, 226, 142)
	col_warn  := _rgb(248, 192, 58)
	col_err   := _rgb(255, 82, 88)
	col_acc   := _rgb(92, 178, 255)

	_fill_rect(hdc, {0, 0, w, h}, bg_main)

	// 1. Top Status Island
	_fill_rect(hdc, {10, 10, w - 10, 52}, bg_card)
	badge_col := col_ok
	badge_txt := "● RECORDING LIVE (Hooks Extended)"
	switch s.health {
	case .Connecting:
		badge_col = col_acc
		badge_txt = "◌ CONNECTING TO ENGINE..."
	case .Recording:
		badge_col = col_ok
		badge_txt = fmt.tprintf("● RECORDING LIVE  |  PID %d  |  Frames: %d  |  Spikes: %d", s.engine_pid, s.total_frames, s.total_spikes)
	case .Frozen:
		badge_col = col_warn
		badge_txt = fmt.tprintf("⚠ ENGINE HANG DETECTED (%.1fs) in %s!", s.hang_duration_ms / 1000.0, ow.phase_name(s.last_phase))
	case .Crashed:
		badge_col = col_err
		badge_txt = fmt.tprintf("💥 ENGINE CRASHED (0x%X) — Autopsy Saved to overwatch_latest.md!", s.engine_exit_code)
	case .Stopped:
		badge_col = txt_muted
		badge_txt = "■ STOPPED & HOOKS RETRACTED — Report Saved to logs/overwatch/"
	}
	_draw_text(hdc, 20, 20, badge_txt, badge_col, _font_bold)

	// Action Buttons in Top-Right of Overwatch Window
	_btn_mark = {w - 208, 16, w - 114, 46}
	_btn_stop = {w - 106, 16, w - 18, 46}
	_fill_rect(hdc, _btn_mark, _rgb(38, 52, 76))
	_draw_text(hdc, _btn_mark.left + 10, _btn_mark.top + 6, "+ Bookmark", col_acc, _font_ui)
	_fill_rect(hdc, _btn_stop, _rgb(84, 32, 38))
	_draw_text(hdc, _btn_stop.left + 10, _btn_stop.top + 6, "Stop & Save", _rgb(255, 160, 165), _font_ui)

	// 2. Frame-Time Sparkline Graph (0..50 ms)
	gx0: i32 = 10
	gy0: i32 = 60
	gx1: i32 = w - 10
	gy1: i32 = 178
	_fill_rect(hdc, {gx0, gy0, gx1, gy1}, bg_card)
	f := s.latest_frame
	_draw_text(hdc, gx0 + 10, gy0 + 6, fmt.tprintf("Frame Time: %.2f ms (%.0f FPS)   |   Max Spike: %.2f ms   |   RAM: %.1f MB", f.dt_ms, f.fps, s.max_dt_ms, f.working_set_mb), txt_prim, _font_ui)

	plot_top := gy0 + 28
	plot_bot := gy1 - 8
	plot_h   := max(plot_bot - plot_top, 10)
	max_scale_ms: f32 = 50.0

	// 16.67ms & 33.33ms threshold guide lines
	y_16 := plot_bot - i32((16.667 / max_scale_ms) * f32(plot_h))
	y_33 := plot_bot - i32((33.333 / max_scale_ms) * f32(plot_h))
	pen_16 := CreatePen(0, 1, _rgb(48, 86, 68))
	old_p  := win32.SelectObject(hdc, win32.HGDIOBJ(pen_16))
	MoveToEx(hdc, gx0 + 8, y_16, nil); LineTo(hdc, gx1 - 8, y_16)
	win32.SelectObject(hdc, old_p)
	win32.DeleteObject(win32.HGDIOBJ(pen_16))

	pen_33 := CreatePen(0, 1, _rgb(96, 48, 52))
	old_p2 := win32.SelectObject(hdc, win32.HGDIOBJ(pen_33))
	MoveToEx(hdc, gx0 + 8, y_33, nil); LineTo(hdc, gx1 - 8, y_33)
	win32.SelectObject(hdc, old_p2)
	win32.DeleteObject(win32.HGDIOBJ(pen_33))

	if s.sparkline_count > 0 {
		avail_w := max((gx1 - gx0) - 16, 1)
		bar_w   := max(avail_w / SPARKLINE_CAP, 2)
		start_i := (s.sparkline_head - s.sparkline_count + SPARKLINE_CAP) % SPARKLINE_CAP
		for i in 0 ..< s.sparkline_count {
			idx := (start_i + i) % SPARKLINE_CAP
			ms  := s.sparkline_ms[idx]
			fl  := s.sparkline_flags[idx]
			bh  := clamp(i32((ms / max_scale_ms) * f32(plot_h)), 2, plot_h)
			bx  := gx0 + 8 + i32(i) * bar_w
			if bx + bar_w > gx1 - 6 do break
			bcol := (fl & ow.OW_FLAG_SPIKE_SEVERE) != 0 ? col_err : ((fl & ow.OW_FLAG_SPIKE_WARN) != 0 ? col_warn : col_ok)
			_fill_rect(hdc, {bx, plot_bot - bh, bx + max(bar_w - 1, 1), plot_bot}, bcol)
		}
	}

	// 3. Subsystem Phase Breakdown & Live Context Card
	cy0: i32 = 186
	cy1: i32 = 242
	_fill_rect(hdc, {10, cy0, w - 10, cy1}, bg_card)
	_draw_text(hdc, 20, cy0 + 8, fmt.tprintf("Sim/Phys: %.2f ms  |  Editor UI: %.2f ms  |  3D/2D Render: %.2f ms  |  Present: %.2f ms", f.sim_ms, f.ui_ms, f.render_ms, f.present_ms), col_acc, _font_mono)
	_draw_text(hdc, 20, cy0 + 28, fmt.tprintf("Scene: %s   |   Selected: %s   |   In-Flight: %s", s.last_scene != "" ? s.last_scene : "-", s.last_selected != "" ? s.last_selected : "-", ow.phase_name(s.last_phase)), txt_muted, _font_ui)

	// 4. Live "What You Did & Spikes" Event Feed
	ey0: i32 = 250
	ey1: i32 = h - 10
	_fill_rect(hdc, {10, ey0, w - 10, ey1}, bg_card)
	_draw_text(hdc, 20, ey0 + 6, "What You Did & Performance Spikes (Live Stream -> overwatch_latest.md):", txt_prim, _font_bold)

	max_rows := max((ey1 - (ey0 + 30)) / 18, 1)
	ev_total := len(s.events_log)
	first_ev := max(ev_total - int(max_rows), 0)
	row_y    := ey0 + 30
	for ei := ev_total - 1; ei >= first_ev; ei -= 1 {
		ev  := s.events_log[ei]
		det := ow.read_fixed_str(ev.detail[:])
		ecol := txt_prim
		if ev.kind == .Frame_Spike do ecol = col_warn
		else if ev.kind == .Bookmark do ecol = col_acc
		else if ev.kind == .Session_Lifecycle do ecol = col_ok
		line := fmt.tprintf("[%6.1fs #%d] %-7s %s", ev.elapsed_ms / 1000.0, ev.frame_number, ow.event_kind_name(ev.kind), det)
		_draw_text(hdc, 20, row_y, line, ecol, _font_mono)
		row_y += 18
	}
}
