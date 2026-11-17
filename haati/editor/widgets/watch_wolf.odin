package widgets

// =============================================================================
// WATCH-WOLF EMBEDDED MASCOT TEXTURE (Lorc / game-icons.net, CC-BY 3.0)
// =============================================================================

import gfx "haati:engine/gfx"
import im "haati:external/odin-imgui"
import stbi "vendor:stb/image"

@(private = "file")
_WATCH_WOLF_PNG := #load("../../external/icons/watch_wolf_96.png")

@(private = "file")
_wolf: struct {
	failed: bool,
	tex:    ^gfx.Texture,
	id:     im.TextureID,
	w, h:   f32,
}

@(private = "file")
_watch_wolf_ensure_loaded :: proc() -> bool {
	if _wolf.tex != nil do return true
	if _wolf.failed do return false

	w, h, ch: i32
	px := stbi.load_from_memory(raw_data(_WATCH_WOLF_PNG), i32(len(_WATCH_WOLF_PNG)), &w, &h, &ch, 4)
	if px == nil || w <= 0 || h <= 0 {
		if px != nil do stbi.image_free(px)
		_wolf.failed = true
		return false
	}
	defer stbi.image_free(px)

	tex := gfx.texture_create(px[:w * h * 4], w, h)
	if tex == nil do return false
	_wolf.tex = tex
	_wolf.id  = im.TextureID(uintptr(gfx.texture_imgui_id(tex)))
	_wolf.w   = f32(w)
	_wolf.h   = f32(h)
	return true
}

// Exposes the embedded raw PNG bytes for asset validation tests without requiring a GL context.
watch_wolf_png_bytes :: proc() -> []byte {
	return _WATCH_WOLF_PNG[:]
}

// Draws the crisp 96x96 Watch-Wolf mascot tinted with `tint` (defaults to opaque white when alpha <= 0)
// and reserves a matching `size x size` ImGui layout square.
watch_wolf_draw :: proc(size: f32 = 34.0, tint := im.Vec4{}) -> bool {
	s := max(size, 8.0)
	cur := im.GetCursorScreenPos()
	im.Dummy({s, s})
	if !_watch_wolf_ensure_loaded() || _wolf.id == 0 do return false

	col := tint
	if col.w <= 0 {
		col = {1.0, 1.0, 1.0, 1.0}
	}
	dl := im.GetWindowDrawList()
	im.DrawList_AddImage(dl, im.TextureRef{_TexID = _wolf.id}, cur, cur + {s, s}, {0, 0}, {1, 1}, im.ColorConvertFloat4ToU32(col))
	return true
}
