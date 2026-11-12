#+build !windows
package gfx

import sdl "vendor:sdl3"

_apply_native_dark_window_chrome :: proc(_w: ^sdl.Window) {}
_cleanup_native_dark_window_chrome :: proc() {}
