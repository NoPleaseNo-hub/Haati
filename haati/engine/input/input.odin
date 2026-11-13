// Input abstraction: the ONLY package that touches the input side of the
// underlying libraries. Call sites (app, editor, packages) import this and
// never read SDL — the platform layer (gfx.poll_events) feeds events in via
// frame_reset/apply_event and everything else reads the per-frame snapshot.
// Polling style is preserved (input.key_down(.W)), the event-driven model is
// contained here.
package input

import "core:math/linalg"
import sdl "vendor:sdl3"
import core "haati:engine/core"

// SDL scancodes are physical key positions (WASD stays WASD on AZERTY
// hardware layouts too). The TYPE is re-exported so call sites only import
// this package; the values being SDL's is an implementation detail.
Key :: sdl.Scancode
Gamepad_Button :: sdl.GamepadButton
Gamepad_Axis   :: sdl.GamepadAxis

MAX_GAMEPADS          :: 4
_MAX_GAMEPAD_BUTTONS  :: 32
_MAX_GAMEPAD_AXES     :: 8

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
	X1, // Mouse 4 / Back / Side 1
	X2, // Mouse 5 / Forward / Side 2
	Wheel_Up,
	Wheel_Down,
}

_MAX_KEYS :: 512

_input: struct {
	key_down:       [_MAX_KEYS]bool,
	key_pressed:    [_MAX_KEYS]bool,
	key_released:   [_MAX_KEYS]bool,
	mouse_down:     [Mouse_Button]bool,
	mouse_pressed:  [Mouse_Button]bool,
	mouse_released: [Mouse_Button]bool,
	mouse_pos:      [2]f32,
	mouse_delta:    [2]f32,
	wheel_y:        f32,
	text_runes:     [dynamic]rune, // text typed this frame
	is_focused:     bool,
	focus_edge:     bool, // gained focus this frame — drives the editor asset refresh
	was_focused:    bool, // is_focused at the start of this frame's events (focus_edge source)

	// The game's screen: mouse_position is relative to it and viewport_size
	// is what games measure the screen with. The whole window by default
	// (platform sets it every frame); the editor sets it to the Game view's
	// image instead, in which case the platform leaves it alone.
	viewport_pos:    [2]f32,
	viewport_size:   [2]f32,
	viewport_custom: bool,
	// Application focus (core.application_is_focused, docs/Simulate.md):
	// the window's focus standalone, the Game view's in the editor, which
	// sets it itself (focus_custom). Game reads report nothing while the
	// application is unfocused and inside the game scope; the editor's own
	// reads sit outside the scope. The raw state keeps tracking, so a key
	// held across the gap reads as down once focus returns.
	focus_custom:    bool,
	game_scope:      bool,
	unfocused_mouse: [2]f32, // the mouse where focus left; mouse_position holds it
	relative:        bool,   // relative mouse mode: the global cursor is meaningless

	// Fixed-tick input latching (docs/FixedTick.md): edges ACCUMULATE across
	// frames and are consumed once per fixed tick (fixed_latch), so a press
	// shorter than a tick still registers on the next tick. The non-accum
	// fields are the latched view fixed-update code reads.
	fixed_key_pressed_accum:    [_MAX_KEYS]bool,
	fixed_key_released_accum:   [_MAX_KEYS]bool,
	fixed_mouse_pressed_accum:  [Mouse_Button]bool,
	fixed_mouse_released_accum: [Mouse_Button]bool,
	fixed_key_pressed:          [_MAX_KEYS]bool,
	fixed_key_released:         [_MAX_KEYS]bool,
	fixed_key_down:             [_MAX_KEYS]bool,
	fixed_mouse_pressed:        [Mouse_Button]bool,
	fixed_mouse_released:       [Mouse_Button]bool,
	fixed_mouse_down:           [Mouse_Button]bool,

	// Gamepad state (up to MAX_GAMEPADS connected controllers)
	gamepad_handles:              [MAX_GAMEPADS]^sdl.Gamepad,
	gamepad_ids:                  [MAX_GAMEPADS]sdl.JoystickID,
	gamepad_connected:            [MAX_GAMEPADS]bool,
	gamepad_down:                 [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	gamepad_pressed:              [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	gamepad_released:             [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	gamepad_axes:                 [MAX_GAMEPADS][_MAX_GAMEPAD_AXES]f32,
	fixed_gamepad_pressed_accum:  [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	fixed_gamepad_released_accum: [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	fixed_gamepad_pressed:        [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	fixed_gamepad_released:       [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,
	fixed_gamepad_down:           [MAX_GAMEPADS][_MAX_GAMEPAD_BUTTONS]bool,

	// Lifetime diagnostics (never reset): raw SDL event counts, for the
	// editor's Input Debug window — discriminates "SDL stopped delivering
	// key events" from "imgui state stuck" when keyboard input dies.
	dbg_key_down:     u64,
	dbg_key_up:       u64,
	dbg_focus_gained: u64,
	dbg_focus_lost:   u64,
}

// The window relative mouse mode acts on; set once by the platform layer.
_window: ^sdl.Window

// The window relative mode was actually enabled on — the one under the mouse
// at the time, which in the editor may be a popped-out panel window. An id,
// not a pointer: that window can be destroyed while relative mode is on.
_relative_window_id:     sdl.WindowID
_relative_center_global: [2]f32
_relative_has_center:    bool

// --- Platform feed (gfx only) -------------------------------------------------

// attach_window registers the window relative mouse mode acts on. Called by
// gfx.init right after window creation.
attach_window :: proc(window: ^sdl.Window) {
	_window = window
}

// default_viewport is the platform's per-frame default (the window), taken
// only while no host has set its own.
default_viewport :: proc(size: [2]f32) {
	if _input.viewport_custom do return
	_input.viewport_pos = {}
	_input.viewport_size = size
}

// set_viewport declares the game's screen in window coordinates: an editor
// hosting the game in a panel calls it every frame with the panel's image.
set_viewport :: proc(pos, size: [2]f32) {
	_input.viewport_pos = pos
	_input.viewport_size = size
	_input.viewport_custom = true
}

// The game's screen size, the pair to mouse_position for unprojecting.
viewport_size :: proc() -> [2]f32 {
	return _input.viewport_size
}

viewport_pos :: proc() -> [2]f32 {
	return _input.viewport_pos
}

mouse_in_viewport :: proc() -> bool {
	p := _mouse_pos() - _input.viewport_pos
	return p.x >= 0 && p.y >= 0 && p.x < _input.viewport_size.x && p.y < _input.viewport_size.y
}

// set_app_focused is the host's statement of application focus (the editor:
// the Game view during a run). Set every frame or on change, only a change
// does anything: losing focus freezes the mouse where it was and drops the
// fixed-tick edges nothing consumed; gaining it seeds them from this frame's
// edges, so the click that gives focus reaches the game like in Unity while
// clicks from before it do not (apply_event skips the accumulators while
// unfocused).
set_app_focused :: proc(on: bool) {
	_input.focus_custom = true
	_apply_app_focus(on)
}

// The window's focus, applied unless a host owns the application focus.
@(private = "file")
_platform_app_focus :: proc(on: bool) {
	if _input.focus_custom do return
	_apply_app_focus(on)
}

@(private = "file")
_apply_app_focus :: proc(on: bool) {
	if on == core.application_is_focused() do return
	core.application_set_focused(on)
	if !on {
		_input.unfocused_mouse = _input.mouse_pos
		_input.fixed_key_pressed_accum = {}
		_input.fixed_key_released_accum = {}
		_input.fixed_mouse_pressed_accum = {}
		_input.fixed_mouse_released_accum = {}
		_input.fixed_gamepad_pressed_accum = {}
		_input.fixed_gamepad_released_accum = {}
		return
	}
	for i in 0 ..< _MAX_KEYS {
		if _input.key_pressed[i] do _input.fixed_key_pressed_accum[i] = true
		if _input.key_released[i] do _input.fixed_key_released_accum[i] = true
	}
	for b in Mouse_Button {
		if _input.mouse_pressed[b] do _input.fixed_mouse_pressed_accum[b] = true
		if _input.mouse_released[b] do _input.fixed_mouse_released_accum[b] = true
	}
	for p in 0 ..< MAX_GAMEPADS {
		for b in 0 ..< _MAX_GAMEPAD_BUTTONS {
			if _input.gamepad_pressed[p][b] do _input.fixed_gamepad_pressed_accum[p][b] = true
			if _input.gamepad_released[p][b] do _input.fixed_gamepad_released_accum[p][b] = true
		}
	}
}

// set_game_scope marks the stretch of the frame where the focus gate applies
// to reads. A standalone app sets it once; the editor opens it around the
// simulation tick and closes it after, so its own views read freely.
set_game_scope :: proc(on: bool) {
	_input.game_scope = on
}

@(private = "file")
_hidden :: proc() -> bool {
	return !core.application_is_focused() && _input.game_scope
}

// Drops every pending press and release, per-frame and fixed-tick
// accumulated. A host calls it when a run starts, so clicks from before the
// run (the Play button itself) never reach the first tick.
reset_edges :: proc() {
	_input.key_pressed = {}
	_input.key_released = {}
	_input.mouse_pressed = {}
	_input.mouse_released = {}
	_input.gamepad_pressed = {}
	_input.gamepad_released = {}
	_input.wheel_y = 0
	clear(&_input.text_runes)
	_input.fixed_key_pressed_accum = {}
	_input.fixed_key_released_accum = {}
	_input.fixed_mouse_pressed_accum = {}
	_input.fixed_mouse_released_accum = {}
	_input.fixed_gamepad_pressed_accum = {}
	_input.fixed_gamepad_released_accum = {}
}

@(private = "file")
_mouse_pos :: proc() -> [2]f32 {
	return _input.unfocused_mouse if _hidden() else _input.mouse_pos
}

// sync_global_mouse keeps mouse_pos following the cursor outside the window
// while the window has focus (SDL stops sending motion at the edge), as a
// windowed game expects when aiming. Called by the platform after the
// frame's events. Skipped in relative mode, where the cursor is pinned.
sync_global_mouse :: proc() {
	if _window == nil || !_input.is_focused || _input.relative do return
	gx, gy: f32
	_ = sdl.GetGlobalMouseState(&gx, &gy)
	wx, wy: i32
	if !sdl.GetWindowPosition(_window, &wx, &wy) do return
	_input.mouse_pos = {gx - f32(wx), gy - f32(wy)}
}

// frame_events_done runs after the frame's events applied (gfx.poll_events).
// The focus edge is decided HERE, over the whole frame, not per event: with
// several OS windows (editor panels popped out as imgui viewports) moving
// between them is "lost" on one window then "gained" on another — the app
// never lost focus, so it must not read as an alt-tab back in.
frame_events_done :: proc() {
	if sdl.GetKeyboardFocus() != nil {
		_input.is_focused = true
		_platform_app_focus(true)
	}
	_input.focus_edge = _input.is_focused && !_input.was_focused
	sync_global_mouse()
}

// SDL reports mouse positions relative to the window the event came from.
// Everything here works in MAIN window space (sync_global_mouse, the game
// viewport the editor declares), so a position from another window — an
// editor panel popped out into its own OS window — is shifted by the offset
// between the two windows. Main-window events pass through unchanged.
@(private = "file")
_to_main_window_space :: proc(window_id: sdl.WindowID, p: [2]f32) -> [2]f32 {
	if _window == nil do return p
	if window_id == 0 || window_id == sdl.GetWindowID(_window) do return p
	src := sdl.GetWindowFromID(window_id)
	if src == nil do return p
	sx, sy, mx, my: i32
	if !sdl.GetWindowPosition(src, &sx, &sy) do return p
	if !sdl.GetWindowPosition(_window, &mx, &my) do return p
	return p + {f32(sx - mx), f32(sy - my)}
}

// frame_reset clears the per-frame edges. Called by gfx.poll_events at the
// start of every frame, before events apply.
frame_reset :: proc() {
	_input.key_pressed = {}
	_input.key_released = {}
	_input.mouse_pressed = {}
	_input.mouse_released = {}
	_input.gamepad_pressed = {}
	_input.gamepad_released = {}
	_input.mouse_delta = {}
	_input.wheel_y = 0
	_input.focus_edge = false
	_input.was_focused = _input.is_focused
	clear(&_input.text_runes)
}

@(private = "file")
_gamepad_slot_for_id :: proc(id: sdl.JoystickID) -> int {
	for i in 0 ..< MAX_GAMEPADS {
		if _input.gamepad_connected[i] && _input.gamepad_ids[i] == id {
			return i
		}
	}
	if id == 0 {
		return 0
	}
	return -1
}

// apply_event folds one SDL event into the snapshot. Called by
// gfx.poll_events for every polled event.
apply_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		_input.dbg_key_down += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			if !e.key.repeat {
				_input.key_pressed[sc] = true
				if core.application_is_focused() do _input.fixed_key_pressed_accum[sc] = true
			}
			_input.key_down[sc] = true
		}
	case .KEY_UP:
		_input.dbg_key_up += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			_input.key_released[sc] = true
			if core.application_is_focused() do _input.fixed_key_released_accum[sc] = true
			_input.key_down[sc] = false
		}
	case .MOUSE_MOTION:
		_input.mouse_pos = _to_main_window_space(e.motion.windowID, {e.motion.x, e.motion.y})
		_input.mouse_delta += {e.motion.xrel, e.motion.yrel}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		btn: Mouse_Button
		switch e.button.button {
		case 1: btn = .Left
		case 2: btn = .Middle
		case 3: btn = .Right
		case 4: btn = .X1
		case 5: btn = .X2
		case:   return
		}
		_input.mouse_pos = _to_main_window_space(e.button.windowID, {e.button.x, e.button.y})
		if e.button.down {
			_input.mouse_down[btn] = true
			_input.mouse_pressed[btn] = true
			if core.application_is_focused() do _input.fixed_mouse_pressed_accum[btn] = true
		} else {
			_input.mouse_down[btn] = false
			_input.mouse_released[btn] = true
			if core.application_is_focused() do _input.fixed_mouse_released_accum[btn] = true
		}
	case .MOUSE_WHEEL:
		_input.wheel_y += e.wheel.y
	case .TEXT_INPUT:
		for r in string(e.text.text) {
			append(&_input.text_runes, r)
		}
	case .WINDOW_FOCUS_GAINED:
		_input.dbg_focus_gained += 1
		_input.is_focused = true
		_platform_app_focus(true)
	case .WINDOW_FOCUS_LOST:
		_input.dbg_focus_lost += 1
		if sdl.GetKeyboardFocus() == nil {
			_input.is_focused = false
			_platform_app_focus(false)
		}
	case .GAMEPAD_ADDED:
		id := e.gdevice.which
		if _gamepad_slot_for_id(id) >= 0 && id != 0 do return
		for i in 0 ..< MAX_GAMEPADS {
			if !_input.gamepad_connected[i] {
				_input.gamepad_handles[i] = sdl.OpenGamepad(id)
				_input.gamepad_ids[i] = id
				_input.gamepad_connected[i] = true
				break
			}
		}
	case .GAMEPAD_REMOVED:
		slot := _gamepad_slot_for_id(e.gdevice.which)
		if slot >= 0 {
			if _input.gamepad_handles[slot] != nil {
				sdl.CloseGamepad(_input.gamepad_handles[slot])
				_input.gamepad_handles[slot] = nil
			}
			_input.gamepad_ids[slot] = 0
			_input.gamepad_connected[slot] = false
			_input.gamepad_down[slot] = {}
			_input.gamepad_pressed[slot] = {}
			_input.gamepad_released[slot] = {}
			_input.gamepad_axes[slot] = {}
		}
	case .GAMEPAD_BUTTON_DOWN, .GAMEPAD_BUTTON_UP:
		slot := _gamepad_slot_for_id(e.gbutton.which)
		if slot < 0 do return
		btn := int(e.gbutton.button)
		if btn >= 0 && btn < _MAX_GAMEPAD_BUTTONS {
			if e.type == .GAMEPAD_BUTTON_DOWN || e.gbutton.down {
				if !_input.gamepad_down[slot][btn] {
					_input.gamepad_pressed[slot][btn] = true
					if core.application_is_focused() do _input.fixed_gamepad_pressed_accum[slot][btn] = true
				}
				_input.gamepad_down[slot][btn] = true
			} else {
				_input.gamepad_released[slot][btn] = true
				if core.application_is_focused() do _input.fixed_gamepad_released_accum[slot][btn] = true
				_input.gamepad_down[slot][btn] = false
			}
		}
	case .GAMEPAD_AXIS_MOTION:
		slot := _gamepad_slot_for_id(e.gaxis.which)
		if slot < 0 do return
		ax := int(e.gaxis.axis)
		if ax >= 0 && ax < _MAX_GAMEPAD_AXES {
			val := clamp(f32(e.gaxis.value) / 32767.0, -1.0, 1.0)
			_input.gamepad_axes[slot][ax] = val
		}
	}
}

// --- Per-frame reads -----------------------------------------------------------

key_down :: proc(k: Key) -> bool {
	return !_hidden() && _input.key_down[int(k)]
}

key_pressed :: proc(k: Key) -> bool {
	return !_hidden() && _input.key_pressed[int(k)]
}

key_released :: proc(k: Key) -> bool {
	return !_hidden() && _input.key_released[int(k)]
}

mouse_down :: proc(b: Mouse_Button) -> bool {
	if b == .Wheel_Up do return wheel_up()
	if b == .Wheel_Down do return wheel_down()
	return !_hidden() && _input.mouse_down[b]
}

mouse_pressed :: proc(b: Mouse_Button) -> bool {
	if b == .Wheel_Up do return wheel_up()
	if b == .Wheel_Down do return wheel_down()
	return !_hidden() && _input.mouse_pressed[b]
}

mouse_released :: proc(b: Mouse_Button) -> bool {
	if b == .Wheel_Up || b == .Wheel_Down do return false
	return !_hidden() && _input.mouse_released[b]
}

// The mouse in viewport coordinates (see set_viewport), y down. Frozen while
// blocked, so nothing in the game follows the cursor.
mouse_position :: proc() -> [2]f32 {
	return _mouse_pos() - _input.viewport_pos
}

// This frame's accumulated raw mouse motion (SDL xrel/yrel). Unlike imgui's
// MouseDelta (derived from cursor position), it keeps flowing in relative
// mouse mode, where the cursor is pinned.
mouse_delta :: proc() -> [2]f32 {
	if _hidden() do return {}
	return _input.mouse_delta
}

wheel :: proc() -> f32 {
	if _hidden() do return 0
	return _input.wheel_y
}

wheel_up :: proc() -> bool {
	return wheel() > 0
}

wheel_down :: proc() -> bool {
	return wheel() < 0
}

text :: proc() -> []rune {
	if _hidden() do return nil
	return _input.text_runes[:]
}

focused :: proc() -> bool {
	return _input.is_focused
}

focus_gained :: proc() -> bool {
	return _input.focus_edge
}

is_mouse_relative :: proc() -> bool {
	return _input.relative
}

// Relative mouse mode (camera capture): hides the cursor, confines it to the
// center of the optional viewport rect, and pins it there while SDL streams
// raw deltas — the cursor can never drift outside the Scene View or hover
// other editor panels.
set_mouse_relative :: proc(on: bool, global_rect_min: [2]f32 = {}, rect_size: [2]f32 = {}) {
	_input.relative = on
	if on {
		// The window under the mouse — in the editor that can be a panel
		// popped out into its own OS window, where relative mode on the
		// main window would do nothing.
		target := sdl.GetMouseFocus()
		if target == nil do target = _window
		if target == nil do return
		target_id := sdl.GetWindowID(target)
		if _relative_window_id != 0 && _relative_window_id != target_id {
			if prev := sdl.GetWindowFromID(_relative_window_id); prev != nil {
				_ = sdl.SetWindowMouseRect(prev, nil)
				_ = sdl.SetWindowRelativeMouseMode(prev, false)
			}
		}
		_relative_window_id = target_id
		if rect_size.x > 4 && rect_size.y > 4 {
			_relative_center_global = global_rect_min + rect_size * 0.5
			_relative_has_center = true
			wx, wy: i32
			if sdl.GetWindowPosition(target, &wx, &wy) {
				cx := _relative_center_global.x - f32(wx)
				cy := _relative_center_global.y - f32(wy)
				r := sdl.Rect{
					x = i32(cx) - 2,
					y = i32(cy) - 2,
					w = 4,
					h = 4,
				}
				sdl.WarpMouseInWindow(target, cx, cy)
				_ = sdl.SetWindowMouseRect(target, &r)
			}
		} else {
			_relative_has_center = false
		}
		_ = sdl.SetWindowRelativeMouseMode(target, true)
	} else {
		target := _window
		if _relative_window_id != 0 {
			// nil when that window is gone — SDL dropped its mode with it.
			target = sdl.GetWindowFromID(_relative_window_id)
		}
		if target != nil {
			_ = sdl.SetWindowMouseRect(target, nil)
			_ = sdl.SetWindowRelativeMouseMode(target, false)
			if _relative_has_center {
				wx, wy: i32
				if sdl.GetWindowPosition(target, &wx, &wy) {
					sdl.WarpMouseInWindow(target, _relative_center_global.x - f32(wx), _relative_center_global.y - f32(wy))
				}
			}
		}
		_relative_window_id = 0
		_relative_has_center = false
	}
}

// Raw SDL event counters for the editor's Input Debug window.
debug_counters :: proc() -> (key_down_events, key_up_events, focus_gained_events, focus_lost_events: u64) {
	return _input.dbg_key_down, _input.dbg_key_up, _input.dbg_focus_gained, _input.dbg_focus_lost
}

// --- Fixed-tick input (docs/FixedTick.md) -----------------------------------
// Call once at the START of every fixed tick: moves the accumulated edges
// into the latched view and clears the accumulators. With several ticks in
// one frame the first tick consumes the edges (a press fires once); with
// zero ticks the edges carry over to the next frame's first tick.

fixed_latch :: proc() {
	_input.fixed_key_pressed = _input.fixed_key_pressed_accum
	_input.fixed_key_released = _input.fixed_key_released_accum
	_input.fixed_mouse_pressed = _input.fixed_mouse_pressed_accum
	_input.fixed_mouse_released = _input.fixed_mouse_released_accum
	// Down = held now OR pressed since the last tick — a tap that started and
	// ended between ticks still reads as down for one tick.
	for i in 0 ..< _MAX_KEYS {
		_input.fixed_key_down[i] = _input.key_down[i] || _input.fixed_key_pressed_accum[i]
	}
	for b in Mouse_Button {
		_input.fixed_mouse_down[b] = _input.mouse_down[b] || _input.fixed_mouse_pressed_accum[b]
	}
	_input.fixed_gamepad_pressed = _input.fixed_gamepad_pressed_accum
	_input.fixed_gamepad_released = _input.fixed_gamepad_released_accum
	for p in 0 ..< MAX_GAMEPADS {
		for b in 0 ..< _MAX_GAMEPAD_BUTTONS {
			_input.fixed_gamepad_down[p][b] = _input.gamepad_down[p][b] || _input.fixed_gamepad_pressed_accum[p][b]
		}
	}
	_input.fixed_key_pressed_accum = {}
	_input.fixed_key_released_accum = {}
	_input.fixed_mouse_pressed_accum = {}
	_input.fixed_mouse_released_accum = {}
	_input.fixed_gamepad_pressed_accum = {}
	_input.fixed_gamepad_released_accum = {}
}

key_down_fixed :: proc(k: Key) -> bool {
	return !_hidden() && _input.fixed_key_down[int(k)]
}

key_pressed_fixed :: proc(k: Key) -> bool {
	return !_hidden() && _input.fixed_key_pressed[int(k)]
}

key_released_fixed :: proc(k: Key) -> bool {
	return !_hidden() && _input.fixed_key_released[int(k)]
}

mouse_down_fixed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.fixed_mouse_down[b]
}

mouse_pressed_fixed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.fixed_mouse_pressed[b]
}

mouse_released_fixed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.fixed_mouse_released[b]
}

// --- Gamepad & Analog Stick API ----------------------------------------------

gamepad_connected :: proc(pad: int = 0) -> bool {
	if pad < 0 || pad >= MAX_GAMEPADS do return false
	return _input.gamepad_connected[pad]
}

gamepad_down :: proc(btn: Gamepad_Button, pad: int = 0) -> bool {
	b := int(btn)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || b < 0 || b >= _MAX_GAMEPAD_BUTTONS do return false
	return _input.gamepad_down[pad][b]
}

gamepad_pressed :: proc(btn: Gamepad_Button, pad: int = 0) -> bool {
	b := int(btn)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || b < 0 || b >= _MAX_GAMEPAD_BUTTONS do return false
	return _input.gamepad_pressed[pad][b]
}

gamepad_released :: proc(btn: Gamepad_Button, pad: int = 0) -> bool {
	b := int(btn)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || b < 0 || b >= _MAX_GAMEPAD_BUTTONS do return false
	return _input.gamepad_released[pad][b]
}

gamepad_down_fixed :: proc(btn: Gamepad_Button, pad: int = 0) -> bool {
	b := int(btn)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || b < 0 || b >= _MAX_GAMEPAD_BUTTONS do return false
	return _input.fixed_gamepad_down[pad][b]
}

gamepad_pressed_fixed :: proc(btn: Gamepad_Button, pad: int = 0) -> bool {
	b := int(btn)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || b < 0 || b >= _MAX_GAMEPAD_BUTTONS do return false
	return _input.fixed_gamepad_pressed[pad][b]
}

gamepad_released_fixed :: proc(btn: Gamepad_Button, pad: int = 0) -> bool {
	b := int(btn)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || b < 0 || b >= _MAX_GAMEPAD_BUTTONS do return false
	return _input.fixed_gamepad_released[pad][b]
}

// Returns deadzone-filtered normalized axis in [-1..1] (or [0..1] for triggers).
gamepad_axis :: proc(axis: Gamepad_Axis, deadzone: f32 = 0.12, pad: int = 0) -> f32 {
	ax := int(axis)
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS || ax < 0 || ax >= _MAX_GAMEPAD_AXES do return 0
	raw := _input.gamepad_axes[pad][ax]
	dz := clamp(deadzone, 0.0, 0.95)
	mag := abs(raw)
	if mag <= dz do return 0
	rescaled := (mag - dz) / (1.0 - dz)
	return raw < 0 ? -rescaled : rescaled
}

// Returns a radially deadzoned 2D stick vector in [-1..1]^2.
gamepad_stick :: proc(left: bool = true, deadzone: f32 = 0.12, pad: int = 0) -> [2]f32 {
	if _hidden() || pad < 0 || pad >= MAX_GAMEPADS do return {}
	ax_x := int(Gamepad_Axis.LEFTX if left else Gamepad_Axis.RIGHTX)
	ax_y := int(Gamepad_Axis.LEFTY if left else Gamepad_Axis.RIGHTY)
	v := [2]f32{_input.gamepad_axes[pad][ax_x], _input.gamepad_axes[pad][ax_y]}
	len_v := linalg.length(v)
	dz := clamp(deadzone, 0.0, 0.95)
	if len_v <= dz do return {}
	norm_len := min((len_v - dz) / (1.0 - dz), 1.0)
	return (v / len_v) * norm_len
}
