package input_manager

// Unreal / Godot-style Input Action & Axis Router for MoonHug.
// Provides prioritized event routing, vector binding (Movement & Look),
// 3 binding slots per action (Primary PC, Secondary PC, Gamepad/Controller),
// dynamic action creation, in-editor remapping, and project settings persistence.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import core "haati:engine/core"
import engine "haati:engine"
import input "haati:engine/input"

Action :: enum u8 {
	Move_Forward,
	Move_Back,
	Move_Left,
	Move_Right,
	Jump,
	Duck,
	Wheel_Up,
	Wheel_Down,
	ToggleMenu,
	Look_Left,
	Look_Right,
	Look_Up,
	Look_Down,
	Dash_Action,
	Walk_Action,
}

ACTION_COUNT :: int(len(Action))

Gamepad_Button :: enum u8 {
	None,
	Button_South,      // A / Cross
	Button_East,       // B / Circle
	Button_West,       // X / Square
	Button_North,      // Y / Triangle
	Left_Bumper,       // LB / L1
	Right_Bumper,      // RB / R1
	Left_Trigger,      // LT / L2
	Right_Trigger,     // RT / R2
	Select_Back,       // Back / Select
	Start_Menu,        // Start / Menu
	Left_Thumb,        // L3
	Right_Thumb,       // R3
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
}

// Return true if the callback handled/consumed the input event
Action_Callback :: #type proc(action_idx: int, is_pressed: bool, owner: rawptr) -> bool

// Return true if the callback handled/consumed the vector
Vector_Callback :: #type proc(vector: [2]f32, owner: rawptr) -> bool

Listener_Binding :: struct {
	priority: int,
	callback: Action_Callback,
	owner:    rawptr,
}

Vector_Binding :: struct {
	priority: int,
	callback: Vector_Callback,
	owner:    rawptr,
}

Action_Mapping :: struct {
	primary_key:     input.Key,
	primary_mouse:   bool,
	primary_mbtn:    input.Mouse_Button,
	secondary_key:   input.Key,
	secondary_mouse: bool,
	secondary_mbtn:  input.Mouse_Button,
	gamepad_btn:     Gamepad_Button,
	use_mouse_btn:   bool,
	mouse_btn:       input.Mouse_Button,
}

Action_Item :: struct {
	name:      string,
	mapping:   Action_Mapping,
	is_custom: bool,
}

Input_Settings :: struct {
	mouse_sensitivity:   f32,
	mouse_yaw_mult:      f32,
	mouse_pitch_mult:    f32,
	gamepad_sensitivity: f32,
	deadzone:            f32,
	invert_y:            bool,
}

@(project_settings={name="Input Manager"})
settings := Input_Settings{
	mouse_sensitivity   = 1.0,
	mouse_yaw_mult      = 1.0,
	mouse_pitch_mult    = 1.0,
	gamepad_sensitivity = 1.0,
	deadzone            = 0.15,
	invert_y            = false,
}

// Global action state
@(private = "file")
_actions: [dynamic]Action_Item

@(private = "file")
_action_listeners: [dynamic][dynamic]Listener_Binding

@(private = "file")
_movement_listeners: [dynamic]Vector_Binding

@(private = "file")
_look_listeners: [dynamic]Vector_Binding

@(private = "file")
_initialized: bool = false

@(private = "file")
_game_mouse_captured: bool = false

@(private = "file")
_mouse_unlocked_by_escape: bool = false

@(private = "file")
_ui_overlay_blocks_mouse_capture: bool = false

// Explicitly locks or unlocks mouse capture and suppresses movement/look dispatch
// while an in-game UI overlay (such as QuickMenu or Developer Console) is open.
set_ui_overlay_mouse_unlock :: proc(unlocked: bool) {
	_ui_overlay_blocks_mouse_capture = unlocked
	if unlocked {
		_mouse_unlocked_by_escape = true
		if _game_mouse_captured {
			_game_mouse_captured = false
			input.set_mouse_relative(false)
		}
	} else {
		_mouse_unlocked_by_escape = false
	}
}

is_ui_overlay_unlocked :: proc() -> bool {
	return _ui_overlay_blocks_mouse_capture
}

// Helper to format key names cleanly, replacing UNKNOWN with "-"
format_key_name :: proc(key: input.Key) -> string {
	if key == .UNKNOWN do return "-"
	#partial switch key {
	case .ESCAPE:    return "Escape"
	case .RETURN:    return "Enter"
	case .SPACE:     return "Space"
	case .TAB:       return "Tab"
	case .BACKSPACE: return "Backspace"
	case .DELETE:    return "Delete"
	case .INSERT:    return "Insert"
	case .HOME:      return "Home"
	case .END:       return "End"
	case .PAGEUP:    return "Page Up"
	case .PAGEDOWN:  return "Page Down"
	case .LSHIFT:    return "Left Shift"
	case .RSHIFT:    return "Right Shift"
	case .LCTRL:     return "Left Ctrl"
	case .RCTRL:     return "Right Ctrl"
	case .LALT:      return "Left Alt"
	case .RALT:      return "Right Alt"
	case .LGUI:      return "Left Super"
	case .RGUI:      return "Right Super"
	case .UP:        return "Up Arrow"
	case .DOWN:      return "Down Arrow"
	case .LEFT:      return "Left Arrow"
	case .RIGHT:     return "Right Arrow"
	case .CAPSLOCK:  return "Caps Lock"
	case ._1:        return "1"
	case ._2:        return "2"
	case ._3:        return "3"
	case ._4:        return "4"
	case ._5:        return "5"
	case ._6:        return "6"
	case ._7:        return "7"
	case ._8:        return "8"
	case ._9:        return "9"
	case ._0:        return "0"
	case:
		return fmt.tprintf("%v", key)
	}
}

format_mouse_button_name :: proc(btn: input.Mouse_Button) -> string {
	switch btn {
	case .Left:       return "Mouse Left (M1)"
	case .Right:      return "Mouse Right (M2)"
	case .Middle:     return "Mouse Middle (M3)"
	case .X1:         return "Mouse Back (M4)"
	case .X2:         return "Mouse Forward (M5)"
	case .Wheel_Up:   return "Mouse Wheel Up"
	case .Wheel_Down: return "Mouse Wheel Down"
	}
	return fmt.tprintf("Mouse %v", btn)
}

format_slot_display :: proc(item: Action_Item, slot: int) -> string {
	switch slot {
	case 0:
		if item.mapping.primary_mouse || item.mapping.use_mouse_btn {
			btn := item.mapping.primary_mbtn if item.mapping.primary_mouse else item.mapping.mouse_btn
			return format_mouse_button_name(btn)
		}
		return format_key_name(item.mapping.primary_key)
	case 1:
		if item.mapping.secondary_mouse {
			return format_mouse_button_name(item.mapping.secondary_mbtn)
		}
		return format_key_name(item.mapping.secondary_key)
	case 2:
		return format_gamepad_name(item.mapping.gamepad_btn)
	}
	return "-"
}

format_gamepad_name :: proc(btn: Gamepad_Button) -> string {
	switch btn {
	case .None:              return "-"
	case .Button_South:      return "A / Cross"
	case .Button_East:       return "B / Circle"
	case .Button_West:       return "X / Square"
	case .Button_North:      return "Y / Triangle"
	case .Left_Bumper:       return "LB / L1"
	case .Right_Bumper:      return "RB / R1"
	case .Left_Trigger:      return "LT / L2"
	case .Right_Trigger:     return "RT / R2"
	case .Select_Back:       return "Back / View"
	case .Start_Menu:        return "Start / Menu"
	case .Left_Thumb:        return "L-Thumb / L3"
	case .Right_Thumb:       return "R-Thumb / R3"
	case .Dpad_Up:           return "D-Pad Up"
	case .Dpad_Down:         return "D-Pad Down"
	case .Dpad_Left:         return "D-Pad Left"
	case .Dpad_Right:        return "D-Pad Right"
	}
	return "-"
}

_ensure_initialized :: proc() {
	if _initialized do return
	_initialized = true

	// Process-global arrays: never borrow a test's scoped tracking allocator.
	context.allocator = runtime.default_allocator()
	_actions            = make([dynamic]Action_Item, runtime.default_allocator())
	_action_listeners   = make([dynamic][dynamic]Listener_Binding, runtime.default_allocator())
	_movement_listeners = make([dynamic]Vector_Binding, runtime.default_allocator())
	_look_listeners     = make([dynamic]Vector_Binding, runtime.default_allocator())

	// Seed standard 15 actions
	DEFAULT_ACTIONS := [ACTION_COUNT]struct {
		name:      string,
		primary:   input.Key,
		secondary: input.Key,
		gamepad:   Gamepad_Button,
	}{
		{"Move_Forward", .W, .UP, .Dpad_Up},
		{"Move_Back", .S, .DOWN, .Dpad_Down},
		{"Move_Left", .A, .LEFT, .Dpad_Left},
		{"Move_Right", .D, .RIGHT, .Dpad_Right},
		{"Jump", .SPACE, .UNKNOWN, .Button_South},
		{"Duck", .C, .LCTRL, .Button_East},
		{"Wheel_Up", .UNKNOWN, .UNKNOWN, .None},
		{"Wheel_Down", .UNKNOWN, .UNKNOWN, .None},
		{"ToggleMenu", .ESCAPE, .TAB, .Start_Menu},
		{"Look_Left", .UNKNOWN, .UNKNOWN, .None},
		{"Look_Right", .UNKNOWN, .UNKNOWN, .None},
		{"Look_Up", .UNKNOWN, .UNKNOWN, .None},
		{"Look_Down", .UNKNOWN, .UNKNOWN, .None},
		{"Dash_Action", .LSHIFT, .UNKNOWN, .Left_Bumper},
		{"Walk_Action", .LALT, .UNKNOWN, .None},
	}

	for def in DEFAULT_ACTIONS {
		mapping := Action_Mapping{
			primary_key   = def.primary,
			secondary_key = def.secondary,
			gamepad_btn   = def.gamepad,
		}
		if def.name == "Wheel_Up" {
			mapping.primary_mouse = true
			mapping.primary_mbtn = .Wheel_Up
			mapping.use_mouse_btn = true
			mapping.mouse_btn = .Wheel_Up
		} else if def.name == "Wheel_Down" {
			mapping.primary_mouse = true
			mapping.primary_mbtn = .Wheel_Down
			mapping.use_mouse_btn = true
			mapping.mouse_btn = .Wheel_Down
		}
		append(&_actions, Action_Item{
			name = def.name,
			mapping = mapping,
			is_custom = false,
		})
		append(&_action_listeners, make([dynamic]Listener_Binding, runtime.default_allocator()))
	}

	_load_persisted_actions()
}

INPUT_ACTIONS_SAVE_PATH :: "ProjectSettings/input_actions.json"

@(private = "file")
_save_persisted_actions :: proc() {
	os.make_directory("ProjectSettings")
	opts := json.Marshal_Options{
		spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
	}
	if data, err := json.marshal(_actions[:], opts, context.temp_allocator); err == nil {
		_ = os.write_entire_file(INPUT_ACTIONS_SAVE_PATH, data)
	}
}

@(private = "file")
_load_persisted_actions :: proc() {
	context.allocator = runtime.default_allocator()
	data, read_err := engine.vfs_read_entire_file(INPUT_ACTIONS_SAVE_PATH, context.temp_allocator)
	if read_err != nil do return
	loaded: [dynamic]Action_Item
	if json.unmarshal(data, &loaded, allocator = context.temp_allocator) != nil do return
	if len(loaded) == 0 do return

	for a in _actions {
		if a.is_custom do delete(a.name)
	}
	clear(&_actions)
	for item in loaded {
		append(&_actions, Action_Item{
			name      = strings.clone(item.name),
			mapping   = item.mapping,
			is_custom = true,
		})
		if len(_action_listeners) < len(_actions) {
			append(&_action_listeners, make([dynamic]Listener_Binding, runtime.default_allocator()))
		}
	}
}

find_action_by_name :: proc(name: string) -> (int, bool) {
	_ensure_initialized()
	for a, i in _actions {
		if strings.equal_fold(a.name, name) {
			return i, true
		}
	}
	return -1, false
}

get_action_count :: proc() -> int {
	_ensure_initialized()
	return len(_actions)
}

get_action_item :: proc(idx: int) -> Action_Item {
	_ensure_initialized()
	if idx < 0 || idx >= len(_actions) do return {}
	return _actions[idx]
}

add_custom_action :: proc(name: string, primary: input.Key = .UNKNOWN, secondary: input.Key = .UNKNOWN, gamepad: Gamepad_Button = .None) -> int {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	cloned_name := strings.clone(name)
	idx := len(_actions)
	append(&_actions, Action_Item{
		name = cloned_name,
		mapping = {
			primary_key   = primary,
			secondary_key = secondary,
			gamepad_btn   = gamepad,
		},
		is_custom = true,
	})
	append(&_action_listeners, make([dynamic]Listener_Binding, runtime.default_allocator()))
	_save_persisted_actions()
	return idx
}

remove_custom_action :: proc(idx: int) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	if idx < ACTION_COUNT || idx >= len(_actions) do return // Protected standard actions
	if _actions[idx].is_custom {
		delete(_actions[idx].name)
	}
	delete(_action_listeners[idx])
	ordered_remove(&_actions, idx)
	ordered_remove(&_action_listeners, idx)
	_save_persisted_actions()
}

rename_action :: proc(idx: int, new_name: string) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	trimmed := strings.trim_space(new_name)
	if len(trimmed) == 0 do return
	if idx < 0 || idx >= len(_actions) do return
	if _actions[idx].is_custom {
		delete(_actions[idx].name)
	}
	_actions[idx].name = strings.clone(trimmed)
	_actions[idx].is_custom = true
	_save_persisted_actions()
}

delete_action :: proc(idx: int) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	if idx < 0 || idx >= len(_actions) do return
	if _actions[idx].is_custom {
		delete(_actions[idx].name)
	}
	delete(_action_listeners[idx])
	ordered_remove(&_actions, idx)
	ordered_remove(&_action_listeners, idx)
	_save_persisted_actions()
}

rebind_primary :: proc(idx: int, key: input.Key) {
	_ensure_initialized()
	if idx >= 0 && idx < len(_actions) {
		_actions[idx].mapping.primary_key = key
		_actions[idx].mapping.primary_mouse = false
		_actions[idx].mapping.use_mouse_btn = false
		_save_persisted_actions()
	}
}

rebind_secondary :: proc(idx: int, key: input.Key) {
	_ensure_initialized()
	if idx >= 0 && idx < len(_actions) {
		_actions[idx].mapping.secondary_key = key
		_actions[idx].mapping.secondary_mouse = false
		_save_persisted_actions()
	}
}

rebind_gamepad :: proc(idx: int, btn: Gamepad_Button) {
	_ensure_initialized()
	if idx >= 0 && idx < len(_actions) {
		_actions[idx].mapping.gamepad_btn = btn
		_save_persisted_actions()
	}
}

rebind_mouse :: proc(idx: int, btn: input.Mouse_Button, slot: int = 0) {
	_ensure_initialized()
	if idx >= 0 && idx < len(_actions) {
		if slot == 1 {
			_actions[idx].mapping.secondary_mouse = true
			_actions[idx].mapping.secondary_mbtn = btn
			_actions[idx].mapping.secondary_key = .UNKNOWN
		} else {
			_actions[idx].mapping.primary_mouse = true
			_actions[idx].mapping.primary_mbtn = btn
			_actions[idx].mapping.use_mouse_btn = true
			_actions[idx].mapping.mouse_btn = btn
			_actions[idx].mapping.primary_key = .UNKNOWN
		}
		_save_persisted_actions()
	}
}

rebind_wheel :: proc(idx: int, wheel_up: bool, slot: int = 0) {
	btn: input.Mouse_Button = .Wheel_Up if wheel_up else .Wheel_Down
	rebind_mouse(idx, btn, slot)
}

clear_binding_slot :: proc(idx: int, slot: int) {
	_ensure_initialized()
	if idx < 0 || idx >= len(_actions) do return
	switch slot {
	case 0:
		_actions[idx].mapping.primary_key = .UNKNOWN
		_actions[idx].mapping.primary_mouse = false
		_actions[idx].mapping.use_mouse_btn = false
	case 1:
		_actions[idx].mapping.secondary_key = .UNKNOWN
		_actions[idx].mapping.secondary_mouse = false
	case 2:
		_actions[idx].mapping.gamepad_btn = .None
	}
	_save_persisted_actions()
}

// ─────────────────────────────────────────────────────────────
// REGISTRATION / ROUTING API
// ─────────────────────────────────────────────────────────────

claim_action :: proc(action: Action, priority: int, callback: Action_Callback, owner: rawptr = nil) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	idx := int(action)
	if idx >= len(_action_listeners) do return

	i := 0
	for i < len(_action_listeners[idx]) {
		b := _action_listeners[idx][i]
		if (owner != nil && b.owner == owner) || b.callback == callback {
			unordered_remove(&_action_listeners[idx], i)
		} else {
			i += 1
		}
	}
	append(&_action_listeners[idx], Listener_Binding{priority = priority, callback = callback, owner = owner})
	slice.sort_by(_action_listeners[idx][:], proc(a, b: Listener_Binding) -> bool {
		return a.priority > b.priority
	})
}

claim_action_by_index :: proc(idx: int, priority: int, callback: Action_Callback, owner: rawptr = nil) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	if idx < 0 || idx >= len(_action_listeners) do return

	i := 0
	for i < len(_action_listeners[idx]) {
		b := _action_listeners[idx][i]
		if (owner != nil && b.owner == owner) || b.callback == callback {
			unordered_remove(&_action_listeners[idx], i)
		} else {
			i += 1
		}
	}
	append(&_action_listeners[idx], Listener_Binding{priority = priority, callback = callback, owner = owner})
	slice.sort_by(_action_listeners[idx][:], proc(a, b: Listener_Binding) -> bool {
		return a.priority > b.priority
	})
}

release_action :: proc(action: Action, owner: rawptr) {
	_ensure_initialized()
	if owner == nil do return
	idx := int(action)
	if idx >= len(_action_listeners) do return

	i := 0
	for i < len(_action_listeners[idx]) {
		if _action_listeners[idx][i].owner == owner {
			unordered_remove(&_action_listeners[idx], i)
		} else {
			i += 1
		}
	}
}

// Claims any standard or custom action by its string name (e.g., "Ability_A").
// If the action doesn't exist yet, auto-registers it as a custom action so scripts never fail on first run.
claim_action_by_name :: proc(name: string, priority: int, callback: Action_Callback, owner: rawptr = nil, default_key: input.Key = .F8) -> int {
	_ensure_initialized()
	idx, ok := find_action_by_name(name)
	if !ok {
		idx = add_custom_action(name, primary = default_key)
	}
	claim_action_by_index(idx, priority, callback, owner)
	return idx
}

release_action_by_name :: proc(name: string, owner: rawptr) {
	_ensure_initialized()
	if owner == nil do return
	idx, ok := find_action_by_name(name)
	if !ok || idx < 0 || idx >= len(_action_listeners) do return

	i := 0
	for i < len(_action_listeners[idx]) {
		if _action_listeners[idx][i].owner == owner {
			unordered_remove(&_action_listeners[idx], i)
		} else {
			i += 1
		}
	}
}

claim_movement :: proc(priority: int, callback: Vector_Callback, owner: rawptr = nil) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	i := 0
	for i < len(_movement_listeners) {
		b := _movement_listeners[i]
		if (owner != nil && b.owner == owner) || b.callback == callback {
			unordered_remove(&_movement_listeners, i)
		} else {
			i += 1
		}
	}
	append(&_movement_listeners, Vector_Binding{priority = priority, callback = callback, owner = owner})
	slice.sort_by(_movement_listeners[:], proc(a, b: Vector_Binding) -> bool {
		return a.priority > b.priority
	})
}

release_movement :: proc(owner: rawptr) {
	_ensure_initialized()
	if owner == nil do return
	i := 0
	for i < len(_movement_listeners) {
		if _movement_listeners[i].owner == owner {
			unordered_remove(&_movement_listeners, i)
		} else {
			i += 1
		}
	}
}

claim_look :: proc(priority: int, callback: Vector_Callback, owner: rawptr = nil) {
	_ensure_initialized()
	context.allocator = runtime.default_allocator()
	i := 0
	for i < len(_look_listeners) {
		b := _look_listeners[i]
		if (owner != nil && b.owner == owner) || b.callback == callback {
			unordered_remove(&_look_listeners, i)
		} else {
			i += 1
		}
	}
	append(&_look_listeners, Vector_Binding{priority = priority, callback = callback, owner = owner})
	slice.sort_by(_look_listeners[:], proc(a, b: Vector_Binding) -> bool {
		return a.priority > b.priority
	})
}

release_look :: proc(owner: rawptr) {
	_ensure_initialized()
	if owner == nil do return
	i := 0
	for i < len(_look_listeners) {
		if _look_listeners[i].owner == owner {
			unordered_remove(&_look_listeners, i)
		} else {
			i += 1
		}
	}
	if len(_look_listeners) == 0 && _game_mouse_captured {
		_game_mouse_captured      = false
		_mouse_unlocked_by_escape = false
		input.set_mouse_relative(false)
	}
}

release_all_for_owner :: proc(owner: rawptr) {
	_ensure_initialized()
	if owner == nil do return
	for a in 0 ..< len(_action_listeners) {
		i := 0
		for i < len(_action_listeners[a]) {
			if _action_listeners[a][i].owner == owner {
				unordered_remove(&_action_listeners[a], i)
			} else {
				i += 1
			}
		}
	}
	release_movement(owner)
	release_look(owner)
}

// ─────────────────────────────────────────────────────────────
// STATE QUERIES
// ─────────────────────────────────────────────────────────────

@(private = "file")
_eval_action_trigger :: proc(idx: int, just_pressed: bool) -> bool {
	_ensure_initialized()
	if idx < 0 || idx >= len(_actions) do return false
	m := _actions[idx].mapping
	ui_blocks_mouse := !(_game_mouse_captured || input.is_mouse_relative()) && engine.ui_is_pointer_over_ui()

	if m.primary_mouse || m.use_mouse_btn {
		if !ui_blocks_mouse {
			btn := m.primary_mbtn if m.primary_mouse else m.mouse_btn
			hit := input.mouse_pressed(btn) if just_pressed else input.mouse_down(btn)
			if hit do return true
		}
	} else if m.primary_key != .UNKNOWN {
		hit := input.key_pressed(m.primary_key) if just_pressed else input.key_down(m.primary_key)
		if hit do return true
	}

	if m.secondary_mouse {
		if !ui_blocks_mouse {
			hit := input.mouse_pressed(m.secondary_mbtn) if just_pressed else input.mouse_down(m.secondary_mbtn)
			if hit do return true
		}
	} else if m.secondary_key != .UNKNOWN {
		hit := input.key_pressed(m.secondary_key) if just_pressed else input.key_down(m.secondary_key)
		if hit do return true
	}

	// Legacy fallback
	if !ui_blocks_mouse {
		if idx == int(Action.Wheel_Up) && input.wheel() > 0 do return true
		if idx == int(Action.Wheel_Down) && input.wheel() < 0 do return true
	}
	return false
}

is_action_down_idx :: proc(idx: int) -> bool {
	return _eval_action_trigger(idx, false)
}

is_action_down :: proc(action: Action) -> bool {
	return is_action_down_idx(int(action))
}

is_action_pressed_idx :: proc(idx: int) -> bool {
	return _eval_action_trigger(idx, true)
}

is_action_pressed :: proc(action: Action) -> bool {
	return is_action_pressed_idx(int(action))
}

is_action_released_idx :: proc(idx: int) -> bool {
	_ensure_initialized()
	if idx < 0 || idx >= len(_actions) do return false
	m := _actions[idx].mapping

	if m.primary_mouse || m.use_mouse_btn {
		btn := m.primary_mbtn if m.primary_mouse else m.mouse_btn
		if input.mouse_released(btn) do return true
	} else if m.primary_key != .UNKNOWN {
		if input.key_released(m.primary_key) do return true
	}

	if m.secondary_mouse {
		if input.mouse_released(m.secondary_mbtn) do return true
	} else if m.secondary_key != .UNKNOWN {
		if input.key_released(m.secondary_key) do return true
	}
	return false
}

is_action_released :: proc(action: Action) -> bool {
	return is_action_released_idx(int(action))
}

get_movement_vector :: proc() -> [2]f32 {
	v := [2]f32{0, 0}
	if is_action_down(.Move_Right)   do v.x += 1
	if is_action_down(.Move_Left)    do v.x -= 1
	if is_action_down(.Move_Forward) do v.y += 1
	if is_action_down(.Move_Back)    do v.y -= 1

	len_sq := v.x * v.x + v.y * v.y
	if len_sq > 1.0 {
		return linalg.normalize(v)
	}
	return v
}

// Base conversion from raw mouse pixel counts to radians (~0.115 deg per count at sensitivity 1.0).
// Folded directly into `get_look_vector` so downstream cameras receive clean radian deltas with zero extra multiply!
MOUSE_COUNT_TO_RAD :: f32(0.002)

get_look_vector :: proc() -> [2]f32 {
	delta := input.mouse_delta()
	yaw_m   := settings.mouse_yaw_mult   if settings.mouse_yaw_mult > 0.0   else 1.0
	pitch_m := settings.mouse_pitch_mult if settings.mouse_pitch_mult > 0.0 else 1.0
	look := [2]f32{delta.x * yaw_m, delta.y * pitch_m}
	if settings.invert_y do look.y = -look.y
	return look * (settings.mouse_sensitivity * MOUSE_COUNT_TO_RAD)
}

get_axis :: proc(negative_action, positive_action: Action) -> f32 {
	val: f32 = 0.0
	if is_action_down(positive_action) do val += 1.0
	if is_action_down(negative_action) do val -= 1.0
	return val
}

// ─────────────────────────────────────────────────────────────
// PER-FRAME DISPATCHER
// ─────────────────────────────────────────────────────────────

@(update={order=-20})
input_manager_dispatch :: proc(dt: f32) {
	_ensure_initialized()

	// 1. Dispatch action pressed & released events
	count := len(_actions)
	for a in 0 ..< count {
		if is_action_pressed_idx(a) {
			for listener in _action_listeners[a] {
				consumed := listener.callback(a, true, listener.owner)
				if consumed do break
			}
		} else if is_action_released_idx(a) {
			for listener in _action_listeners[a] {
				consumed := listener.callback(a, false, listener.owner)
				if consumed do break
			}
		}
	}

	// 2. Dispatch Movement vector (suppressed while QuickMenu / Console UI overlay is open)
	if len(_movement_listeners) > 0 && !_ui_overlay_blocks_mouse_capture {
		move := get_movement_vector()
		for listener in _movement_listeners {
			consumed := listener.callback(move, listener.owner)
			if consumed do break
		}
	}

	// 3. Dispatch Look vector & manage automatic Game Window mouse capture
	if len(_look_listeners) > 0 {
		app_active := core.application_is_focused() && input.focused()
		if _ui_overlay_blocks_mouse_capture {
			if _game_mouse_captured {
				_game_mouse_captured = false
				input.set_mouse_relative(false)
			}
		} else if app_active {
			if input.key_pressed(.ESCAPE) {
				_mouse_unlocked_by_escape = true
				if _game_mouse_captured {
					_game_mouse_captured = false
					input.set_mouse_relative(false)
				}
			} else if _mouse_unlocked_by_escape && input.mouse_pressed(.Left) && input.mouse_in_viewport() && !engine.ui_is_pointer_over_ui() {
				_mouse_unlocked_by_escape = false
			}

			if !_mouse_unlocked_by_escape && !_game_mouse_captured {
				_game_mouse_captured = true
				input.set_mouse_relative(true)
			}
		} else if _game_mouse_captured {
			// Alt-tabbed or clicked outside the Game View -> release mouse immediately
			_game_mouse_captured = false
			input.set_mouse_relative(false)
		}

		if _game_mouse_captured && !_ui_overlay_blocks_mouse_capture {
			look := get_look_vector()
			if look.x != 0 || look.y != 0 {
				for listener in _look_listeners {
					consumed := listener.callback(look, listener.owner)
					if consumed do break
				}
			}
		}
	} else if _game_mouse_captured {
		_game_mouse_captured      = false
		_mouse_unlocked_by_escape = false
		input.set_mouse_relative(false)
	}
}

// ─────────────────────────────────────────────────────────────
// BLUEPRINT / VISUAL SCRIPT ODIN-DELEGATE BRIDGE
// ─────────────────────────────────────────────────────────────

@(private = "file")
_list_all_action_names :: proc(allocator: runtime.Allocator) -> []string {
	_ensure_initialized()
	out := make([]string, len(_actions), allocator)
	for a, i in _actions {
		out[i] = strings.clone(a.name, allocator)
	}
	return out
}

@(private = "file")
_claim_action_bridge :: proc(name: string, priority: int, cb: proc(action_idx: int, pressed: bool, owner: rawptr) -> bool, owner: rawptr) -> int {
	return claim_action_by_name(name, priority, Action_Callback(cb), owner)
}

@(private = "file")
_claim_movement_bridge :: proc(priority: int, cb: proc(v: [2]f32, owner: rawptr) -> bool, owner: rawptr) {
	claim_movement(priority, Vector_Callback(cb), owner)
}

@(private = "file")
_claim_look_bridge :: proc(priority: int, cb: proc(v: [2]f32, owner: rawptr) -> bool, owner: rawptr) {
	claim_look(priority, Vector_Callback(cb), owner)
}

@(init)
_install_visual_script_input_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.visual_script_install_input_bridge({
		claim_action          = _claim_action_bridge,
		release_action        = release_action_by_name,
		claim_movement        = _claim_movement_bridge,
		release_movement      = release_movement,
		claim_look            = _claim_look_bridge,
		release_look          = release_look,
		release_all_for_owner = release_all_for_owner,
		list_action_names     = _list_all_action_names,
	})
}
