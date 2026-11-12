#+build !darwin
package editor

import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import gfx "moonhug:engine/gfx"

// Sets the native OS window and taskbar icon on Windows and Linux via SDL3.
set_dock_icon :: proc(image_path: string) {
	win := gfx.window()
	if win == nil || len(image_path) == 0 do return
	cpath := strings.clone_to_cstring(image_path, context.temp_allocator)
	w, h, channels: i32
	pixels := stbi.load(cpath, &w, &h, &channels, 4)
	if pixels == nil do return
	defer stbi.image_free(pixels)
	surface := sdl.CreateSurfaceFrom(w, h, .RGBA32, pixels, w * 4)
	if surface != nil {
		_ = sdl.SetWindowIcon(win, surface)
		sdl.DestroySurface(surface)
	}
}
