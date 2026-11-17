package widgets

// Animated Haati splash logo for the loading screen (progress_overlay.odin)
// and the Themes & Visuals preview.
//
// No shader or material: the logo (EditorIcon.png, already alpha-keyed) is
// drawn as a GRID x GRID mesh of ImGui image quads. Each vertex keeps its
// screen position but samples a displaced UV, so a radial sine wave reads as
// water refracting over the medallion. Vertex shading darkens the wave
// troughs, two tinted enlarged passes give a pulsing ice-blue halo, and two
// expanding rings sell the "ripple" outward.

import "core:math"
import gfx "haati:engine/gfx"
import im "haati:external/odin-imgui"
import stbi "vendor:stb/image"

@(private = "file")
_SPLASH_PNG := #load("../../../EditorIcon.png")

@(private = "file")
_SPLASH_GRID :: 40

@(private = "file")
_splash: struct {
	tex:    ^gfx.Texture,
	id:     im.TextureID,
	failed: bool,
}

@(private = "file")
_Splash_UVs :: [_SPLASH_GRID + 1][_SPLASH_GRID + 1][2]f32

@(private = "file")
_Splash_Shade :: [_SPLASH_GRID + 1][_SPLASH_GRID + 1]f32

@(private = "file")
_splash_ensure :: proc() -> bool {
	if _splash.tex != nil do return true
	if _splash.failed do return false
	w, h, ch: i32
	px := stbi.load_from_memory(raw_data(_SPLASH_PNG), i32(len(_SPLASH_PNG)), &w, &h, &ch, 4)
	if px == nil {
		_splash.failed = true
		return false
	}
	defer stbi.image_free(px)
	// nil when no GPU device yet — not marked failed, retried next frame.
	tex := gfx.texture_create(px[:w * h * 4], w, h)
	if tex == nil do return false
	_splash.tex = tex
	_splash.id = im.TextureID(uintptr(gfx.texture_imgui_id(tex)))
	return true
}

@(private = "file")
_smoothstep :: #force_inline proc(a, b, x: f32) -> f32 {
	t := clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private = "file")
_splash_draw_grid :: proc(
	dl: ^im.DrawList,
	tex: im.TextureRef,
	center: im.Vec2,
	half: f32,
	uvs: ^_Splash_UVs,
	shade: ^_Splash_Shade,
	tint: im.Vec4,
) {
	N :: _SPLASH_GRID
	cell := 2 * half / f32(N)
	x0 := center.x - half
	y0 := center.y - half
	flat_col := im.ColorConvertFloat4ToU32(tint)
	for j in 0 ..< N {
		for i in 0 ..< N {
			col := flat_col
			if shade != nil {
				s := (shade[j][i] + shade[j][i + 1] + shade[j + 1][i + 1] + shade[j + 1][i]) * 0.25
				col = im.ColorConvertFloat4ToU32({tint.x * s, tint.y * s, tint.z * s, tint.w})
			}
			ax := x0 + f32(i) * cell
			ay := y0 + f32(j) * cell
			bx := ax + cell
			by := ay + cell
			uv1 := uvs[j][i]
			uv2 := uvs[j][i + 1]
			uv3 := uvs[j + 1][i + 1]
			uv4 := uvs[j + 1][i]
			im.DrawList_AddImageQuad(dl, tex,
				{ax, ay}, {bx, ay}, {bx, by}, {ax, by},
				{uv1.x, uv1.y}, {uv2.x, uv2.y}, {uv3.x, uv3.y}, {uv4.x, uv4.y},
				col)
		}
	}
}

// Draws the rippling logo centred at `center`, `size` pixels across.
// `time` is seconds (im.GetTime()); `ripple` scales wave strength (0 = still).
// Returns false when the texture is unavailable (no GPU device yet).
splash_logo_draw :: proc(
	dl: ^im.DrawList,
	center: im.Vec2,
	size: f32,
	time: f32,
	ripple: f32 = 1.0,
	glow := true,
	rings := true,
) -> bool {
	if dl == nil || size < 8 || !_splash_ensure() do return false
	N :: _SPLASH_GRID
	tex := im.TextureRef{_TexID = _splash.id}
	t := time
	half := size * 0.5 * (1.0 + 0.012 * math.sin(t * 1.3))

	// Expanding ripple rings behind the medallion.
	if rings && ripple > 0 {
		PERIOD :: f32(2.6)
		for k in 0 ..< 2 {
			ph := math.mod(t + f32(k) * PERIOD * 0.5, PERIOD) / PERIOD
			fade := (1 - ph) * (1 - ph)
			col := im.ColorConvertFloat4ToU32({0.55, 0.80, 1.0, fade * 0.55 * min(ripple, 1.5)})
			im.DrawList_AddCircle(dl, center, half * (0.92 + 0.40 * ph), col, 96, 1.0 + 2.5 * fade)
		}
	}

	// Wave field: radial travelling wave + a slow diagonal swell.
	uvs: _Splash_UVs
	shade: _Splash_Shade
	amp := 0.0085 * ripple
	for j in 0 ..= N {
		for i in 0 ..= N {
			u := f32(i) / f32(N)
			v := f32(j) / f32(N)
			dx := u - 0.5
			dy := v - 0.5
			r := math.sqrt(dx * dx + dy * dy) * 2 // 0 centre, 1 at the inscribed circle
			env := _smoothstep(0.0, 0.12, r) * (1 - _smoothstep(0.95, 1.35, r))
			phase := r * 16.0 - t * 3.4
			wave := math.sin(phase) * env
			dir := r > 1e-4 ? [2]f32{dx, dy} / (r * 0.5) : [2]f32{}
			swell := math.sin((u * 0.8 + v * 0.55) * 11.0 + t * 1.9) * 0.0025 * ripple * env
			uvs[j][i] = {
				clamp(u - dir.x * wave * amp + swell, 0, 1),
				clamp(v - dir.y * wave * amp - swell * 0.6, 0, 1),
			}
			trough := 0.5 - 0.5 * math.cos(phase)
			shade[j][i] = max(1.0 - 0.14 * ripple * trough * env, 0.6)
		}
	}

	// Pulsing ice-blue halo: two tinted, slightly enlarged passes underneath.
	if glow {
		pulse := 0.5 + 0.5 * math.sin(t * 2.2)
		_splash_draw_grid(dl, tex, center, half * (1.075 + 0.03 * pulse), &uvs, nil, {0.40, 0.70, 1.0, 0.10 + 0.10 * pulse})
		_splash_draw_grid(dl, tex, center, half * (1.035 + 0.015 * pulse), &uvs, nil, {0.55, 0.82, 1.0, 0.18 + 0.14 * pulse})
	}

	_splash_draw_grid(dl, tex, center, half, &uvs, &shade, {1, 1, 1, 1})
	return true
}

// Releases the logo texture. Call before gfx.shutdown.
splash_logo_shutdown :: proc() {
	if _splash.tex != nil {
		gfx.texture_destroy(_splash.tex)
	}
	_splash = {}
}
