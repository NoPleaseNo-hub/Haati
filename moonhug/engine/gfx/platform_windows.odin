#+build windows
package gfx

// Applies Windows 10/11 Immersive Dark Mode (`DWMWA_USE_IMMERSIVE_DARK_MODE`) and
// replaces the Win32 class background erase brush with `#14161A` BEFORE the window
// is ever shown, guaranteeing zero `#FFFFFF` white flashbang on startup or relaunch!

import sdl "vendor:sdl3"
import win "core:sys/windows"

foreign import dwmapi "system:dwmapi.lib"
foreign import user32 "system:user32.lib"

@(default_calling_convention = "system")
foreign dwmapi {
	DwmSetWindowAttribute :: proc(hwnd: win.HWND, dwAttribute: win.DWORD, pvAttribute: rawptr, cbAttribute: win.DWORD) -> win.HRESULT ---
}

@(default_calling_convention = "system")
foreign user32 {
	SetClassLongPtrW :: proc(hWnd: win.HWND, nIndex: i32, dwNewLong: uintptr) -> uintptr ---
}

@(private = "file")
_dark_bg_brush: win.HBRUSH

_apply_native_dark_window_chrome :: proc(w: ^sdl.Window) {
	if w == nil do return
	props := sdl.GetWindowProperties(w)
	hwnd_ptr := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
	if hwnd_ptr == nil do return
	hwnd := win.HWND(hwnd_ptr)

	// 1. Dark title bar & border (`DWMWA_USE_IMMERSIVE_DARK_MODE = 20`)
	dark_mode: win.BOOL = win.TRUE
	_ = DwmSetWindowAttribute(hwnd, 20, &dark_mode, size_of(win.BOOL))

	// 2. Dark caption color (`DWMWA_CAPTION_COLOR = 35`) on Windows 11 (`COLORREF` BGR `0x001A1614` = `#14161A`)
	caption_col: win.DWORD = 0x001A1614
	_ = DwmSetWindowAttribute(hwnd, 35, &caption_col, size_of(win.DWORD))

	// 3. Dark client-area background brush (`GCLP_HBRBACKGROUND = -10`) so `WM_ERASEBKGND` never paints `#FFFFFF`!
	if _dark_bg_brush == nil {
		_dark_bg_brush = win.CreateSolidBrush(0x001A1614)
	}
	if _dark_bg_brush != nil {
		_ = SetClassLongPtrW(hwnd, -10, uintptr(_dark_bg_brush))
	}
}

_cleanup_native_dark_window_chrome :: proc() {
	if _dark_bg_brush != nil {
		_ = win.DeleteObject(win.HGDIOBJ(_dark_bg_brush))
		_dark_bg_brush = nil
	}
}
