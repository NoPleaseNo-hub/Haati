package input_manager_editor

import "core:c"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import input "moonhug:engine/input"
import wnd "moonhug:editor/window"
import input_mgr "moonhug:packages/input_manager"
import icons "moonhug:editor/icons"
import widgets "moonhug:editor/widgets"

Input_Choice_Kind :: enum {
	Keyboard,
	Mouse,
	Gamepad,
}

Input_Choice :: struct {
	name:         string,
	search_terms: string,
	kind:         Input_Choice_Kind,
	key:          input.Key,
	mouse_btn:    input.Mouse_Button,
	gamepad_btn:  input_mgr.Gamepad_Button,
}

@(private = "file")
CURATED_INPUTS := []Input_Choice{
	// Keyboard - Special / Navigation / Common
	{"Escape (ESC)", "escape esc cancel exit menu pause", .Keyboard, .ESCAPE, {}, {}},
	{"Spacebar", "space spacebar jump activate", .Keyboard, .SPACE, {}, {}},
	{"Enter / Return", "return enter confirm accept ok", .Keyboard, .RETURN, {}, {}},
	{"Tab", "tab switch next cycle", .Keyboard, .TAB, {}, {}},
	{"Backspace", "backspace delete erase", .Keyboard, .BACKSPACE, {}, {}},
	{"Delete", "delete del remove", .Keyboard, .DELETE, {}, {}},
	{"Insert", "insert ins", .Keyboard, .INSERT, {}, {}},
	{"Home", "home start", .Keyboard, .HOME, {}, {}},
	{"End", "end finish", .Keyboard, .END, {}, {}},
	{"Page Up", "pageup pgup up", .Keyboard, .PAGEUP, {}, {}},
	{"Page Down", "pagedown pgdn down", .Keyboard, .PAGEDOWN, {}, {}},
	{"Up Arrow", "up arrow forward north", .Keyboard, .UP, {}, {}},
	{"Down Arrow", "down arrow back backward south", .Keyboard, .DOWN, {}, {}},
	{"Left Arrow", "left arrow west", .Keyboard, .LEFT, {}, {}},
	{"Right Arrow", "right arrow east", .Keyboard, .RIGHT, {}, {}},

	// Keyboard - Modifiers
	{"Left Shift", "left shift lshift sprint run", .Keyboard, .LSHIFT, {}, {}},
	{"Right Shift", "right shift rshift sprint run", .Keyboard, .RSHIFT, {}, {}},
	{"Left Ctrl", "left ctrl control lctrl crouch duck", .Keyboard, .LCTRL, {}, {}},
	{"Right Ctrl", "right ctrl control rctrl", .Keyboard, .RCTRL, {}, {}},
	{"Left Alt", "left alt lalt walk alternate", .Keyboard, .LALT, {}, {}},
	{"Right Alt", "right alt ralt alternate", .Keyboard, .RALT, {}, {}},
	{"Left Super (Windows)", "left super windows win cmd gui lgui", .Keyboard, .LGUI, {}, {}},
	{"Right Super (Windows)", "right super windows win cmd gui rgui", .Keyboard, .RGUI, {}, {}},
	{"Caps Lock", "caps lock capslock", .Keyboard, .CAPSLOCK, {}, {}},

	// Keyboard - Letters A-Z
	{"A", "a left strafe", .Keyboard, .A, {}, {}},
	{"B", "b buy backpack", .Keyboard, .B, {}, {}},
	{"C", "c crouch duck character", .Keyboard, .C, {}, {}},
	{"D", "d right strafe", .Keyboard, .D, {}, {}},
	{"E", "e use interact action", .Keyboard, .E, {}, {}},
	{"F", "f flashlight interact use pay", .Keyboard, .F, {}, {}},
	{"G", "g grenade drop throw", .Keyboard, .G, {}, {}},
	{"H", "h heal horn help", .Keyboard, .H, {}, {}},
	{"I", "i inventory items info", .Keyboard, .I, {}, {}},
	{"J", "j journal quest log", .Keyboard, .J, {}, {}},
	{"K", "k kill skill", .Keyboard, .K, {}, {}},
	{"L", "l light lock log", .Keyboard, .L, {}, {}},
	{"M", "m map menu", .Keyboard, .M, {}, {}},
	{"N", "n nightvision next notes", .Keyboard, .N, {}, {}},
	{"O", "o options objectives open", .Keyboard, .O, {}, {}},
	{"P", "p pause photo party", .Keyboard, .P, {}, {}},
	{"Q", "q lean ability switch", .Keyboard, .Q, {}, {}},
	{"R", "r reload restart ready", .Keyboard, .R, {}, {}},
	{"S", "s back backward down reverse", .Keyboard, .S, {}, {}},
	{"T", "t talk chat text team", .Keyboard, .T, {}, {}},
	{"U", "u ui undo", .Keyboard, .U, {}, {}},
	{"V", "v melee voice vault view", .Keyboard, .V, {}, {}},
	{"W", "w forward move up", .Keyboard, .W, {}, {}},
	{"X", "x prone extra examine", .Keyboard, .X, {}, {}},
	{"Y", "y chat yes yell", .Keyboard, .Y, {}, {}},
	{"Z", "z zoom prone sleep", .Keyboard, .Z, {}, {}},

	// Keyboard - Numbers 0-9
	{"1", "1 one slot weapon", .Keyboard, ._1, {}, {}},
	{"2", "2 two slot weapon", .Keyboard, ._2, {}, {}},
	{"3", "3 three slot weapon", .Keyboard, ._3, {}, {}},
	{"4", "4 four slot weapon", .Keyboard, ._4, {}, {}},
	{"5", "5 five slot weapon", .Keyboard, ._5, {}, {}},
	{"6", "6 six slot weapon", .Keyboard, ._6, {}, {}},
	{"7", "7 seven slot weapon", .Keyboard, ._7, {}, {}},
	{"8", "8 eight slot weapon", .Keyboard, ._8, {}, {}},
	{"9", "9 nine slot weapon", .Keyboard, ._9, {}, {}},
	{"0", "0 zero slot weapon", .Keyboard, ._0, {}, {}},

	// Keyboard - Function Keys F1-F12
	{"F1", "f1 help", .Keyboard, .F1, {}, {}},
	{"F2", "f2 rename", .Keyboard, .F2, {}, {}},
	{"F3", "f3 search find", .Keyboard, .F3, {}, {}},
	{"F4", "f4", .Keyboard, .F4, {}, {}},
	{"F5", "f5 quicksave save refresh", .Keyboard, .F5, {}, {}},
	{"F6", "f6 save", .Keyboard, .F6, {}, {}},
	{"F7", "f7", .Keyboard, .F7, {}, {}},
	{"F8", "f8", .Keyboard, .F8, {}, {}},
	{"F9", "f9 quickload load", .Keyboard, .F9, {}, {}},
	{"F10", "f10 menu", .Keyboard, .F10, {}, {}},
	{"F11", "f11 fullscreen", .Keyboard, .F11, {}, {}},
	{"F12", "f12 screenshot dev", .Keyboard, .F12, {}, {}},

	// Keyboard - Symbols & Punctuation
	{"Grave / Tilde (`/~)", "grave tilde console dev debug ` ~", .Keyboard, .GRAVE, {}, {}},
	{"Minus (-)", "minus dash hyphen subtract -", .Keyboard, .MINUS, {}, {}},
	{"Equals (=)", "equals equal plus add =", .Keyboard, .EQUALS, {}, {}},
	{"Left Bracket ([)", "bracket left [ {", .Keyboard, .LEFTBRACKET, {}, {}},
	{"Right Bracket (])", "bracket right ] }", .Keyboard, .RIGHTBRACKET, {}, {}},
	{"Backslash (\\)", "backslash pipe \\ |", .Keyboard, .BACKSLASH, {}, {}},
	{"Semicolon (;)", "semicolon colon ; :", .Keyboard, .SEMICOLON, {}, {}},
	{"Apostrophe (')", "apostrophe quote ' \"", .Keyboard, .APOSTROPHE, {}, {}},
	{"Comma (,)", "comma less , <", .Keyboard, .COMMA, {}, {}},
	{"Period (.)", "period dot greater . >", .Keyboard, .PERIOD, {}, {}},
	{"Slash (/)", "slash divide question / ?", .Keyboard, .SLASH, {}, {}},
	{"Print Screen", "printscreen prtscr capture", .Keyboard, .PRINTSCREEN, {}, {}},
	{"Scroll Lock", "scrolllock scroll", .Keyboard, .SCROLLLOCK, {}, {}},
	{"Pause / Break", "pause break", .Keyboard, .PAUSE, {}, {}},

	// Keyboard - Numpad
	{"NumPad 0", "numpad pad 0 zero", .Keyboard, .KP_0, {}, {}},
	{"NumPad 1", "numpad pad 1 one", .Keyboard, .KP_1, {}, {}},
	{"NumPad 2", "numpad pad 2 two", .Keyboard, .KP_2, {}, {}},
	{"NumPad 3", "numpad pad 3 three", .Keyboard, .KP_3, {}, {}},
	{"NumPad 4", "numpad pad 4 four", .Keyboard, .KP_4, {}, {}},
	{"NumPad 5", "numpad pad 5 five", .Keyboard, .KP_5, {}, {}},
	{"NumPad 6", "numpad pad 6 six", .Keyboard, .KP_6, {}, {}},
	{"NumPad 7", "numpad pad 7 seven", .Keyboard, .KP_7, {}, {}},
	{"NumPad 8", "numpad pad 8 eight", .Keyboard, .KP_8, {}, {}},
	{"NumPad 9", "numpad pad 9 nine", .Keyboard, .KP_9, {}, {}},
	{"NumPad Divide (/)", "numpad divide slash /", .Keyboard, .KP_DIVIDE, {}, {}},
	{"NumPad Multiply (*)", "numpad multiply star *", .Keyboard, .KP_MULTIPLY, {}, {}},
	{"NumPad Minus (-)", "numpad minus subtract -", .Keyboard, .KP_MINUS, {}, {}},
	{"NumPad Plus (+)", "numpad plus add +", .Keyboard, .KP_PLUS, {}, {}},
	{"NumPad Enter", "numpad enter return", .Keyboard, .KP_ENTER, {}, {}},
	{"NumPad Period (.)", "numpad dot period decimal .", .Keyboard, .KP_PERIOD, {}, {}},

	// Mouse Buttons & Wheel
	{"Mouse Left Click (M1)", "mouse left lmb primary fire attack click button 1 m1", .Mouse, .UNKNOWN, .Left, .None},
	{"Mouse Right Click (M2)", "mouse right rmb secondary aim zoom click button 2 m2", .Mouse, .UNKNOWN, .Right, .None},
	{"Mouse Middle Click (M3)", "mouse middle mmb wheel click button 3 m3", .Mouse, .UNKNOWN, .Middle, .None},
	{"Mouse Back (M4)", "mouse back x1 button 4 thumb side m4", .Mouse, .UNKNOWN, .X1, .None},
	{"Mouse Forward (M5)", "mouse forward x2 button 5 thumb side m5", .Mouse, .UNKNOWN, .X2, .None},
	{"Mouse Wheel Up", "mouse wheel scroll up roll weapon zoom up", .Mouse, .UNKNOWN, .Wheel_Up, .None},
	{"Mouse Wheel Down", "mouse wheel scroll down roll weapon zoom jump down", .Mouse, .UNKNOWN, .Wheel_Down, .None},

	// Gamepad Buttons
	{"Gamepad A / Cross (South)", "gamepad controller a cross south jump accept button", .Gamepad, .UNKNOWN, .Left, .Button_South},
	{"Gamepad B / Circle (East)", "gamepad controller b circle east crouch duck cancel back", .Gamepad, .UNKNOWN, .Left, .Button_East},
	{"Gamepad X / Square (West)", "gamepad controller x square west reload interact use", .Gamepad, .UNKNOWN, .Left, .Button_West},
	{"Gamepad Y / Triangle (North)", "gamepad controller y triangle north switch weapon", .Gamepad, .UNKNOWN, .Left, .Button_North},
	{"Gamepad Left Bumper (LB / L1)", "gamepad controller lb l1 bumper shoulder left", .Gamepad, .UNKNOWN, .Left, .Left_Bumper},
	{"Gamepad Right Bumper (RB / R1)", "gamepad controller rb r1 bumper shoulder right", .Gamepad, .UNKNOWN, .Left, .Right_Bumper},
	{"Gamepad Left Trigger (LT / L2)", "gamepad controller lt l2 trigger aim brake left", .Gamepad, .UNKNOWN, .Left, .Left_Trigger},
	{"Gamepad Right Trigger (RT / R2)", "gamepad controller rt r2 trigger fire shoot gas right", .Gamepad, .UNKNOWN, .Left, .Right_Trigger},
	{"Gamepad Back / View / Select", "gamepad controller back view select scoreboard map", .Gamepad, .UNKNOWN, .Left, .Select_Back},
	{"Gamepad Start / Menu", "gamepad controller start menu pause escape options", .Gamepad, .UNKNOWN, .Left, .Start_Menu},
	{"Gamepad Left Stick Click (L3)", "gamepad controller l3 thumb left stick click sprint run", .Gamepad, .UNKNOWN, .Left, .Left_Thumb},
	{"Gamepad Right Stick Click (R3)", "gamepad controller r3 thumb right stick click melee", .Gamepad, .UNKNOWN, .Left, .Right_Thumb},
	{"Gamepad D-Pad Up", "gamepad controller dpad up arrow north", .Gamepad, .UNKNOWN, .Left, .Dpad_Up},
	{"Gamepad D-Pad Down", "gamepad controller dpad down arrow south", .Gamepad, .UNKNOWN, .Left, .Dpad_Down},
	{"Gamepad D-Pad Left", "gamepad controller dpad left arrow west", .Gamepad, .UNKNOWN, .Left, .Dpad_Left},
	{"Gamepad D-Pad Right", "gamepad controller dpad right arrow east", .Gamepad, .UNKNOWN, .Left, .Dpad_Right},
}

// Global modal triggers & state
@(private = "file") _trigger_open_selector: bool = false
@(private = "file") _selector_open:          bool = false
@(private = "file") _selector_action_idx:    int = 0
@(private = "file") _selector_slot:          int = 0
@(private = "file") _selector_search_buf:    [64]u8
@(private = "file") _selector_filter_cat:    int = 0 // 0: All, 1: Keyboard, 2: Mouse, 3: Gamepad
@(private = "file") _selector_focus_search:  bool = false

@(private = "file") _trigger_open_listener: bool = false
@(private = "file") _listener_open:         bool = false
@(private = "file") _listener_action_idx:   int = 0
@(private = "file") _listener_slot:         int = 0
@(private = "file") _listener_ready:        bool = false

@(private = "file") _delete_action_idx:     int = 0

@(private = "file") _trigger_open_manual_modal: bool = false
@(private = "file") _manual_modal_open:         bool = false
@(private = "file") _manual_modal_label:        string = ""
@(private = "file") _manual_target_ptr:         ^f32 = nil
@(private = "file") _manual_temp_val:           f32 = 0.0
@(private = "file") _manual_min:                f32 = 0.0
@(private = "file") _manual_max:                f32 = 5.0
@(private = "file") _manual_focus:              bool = false
@(private = "file") _quick_input_val:           f32 = 0.0

@(private = "file") _renaming_action_idx:   int = -1
@(private = "file") _rename_buf:            [64]u8
@(private = "file") _rename_focus:          bool = false
@(private = "file") _rename_just_opened:    bool = false

@(private = "file") _new_action_buf:        [64]u8
@(private = "file") _show_add_action:       bool = false

@(private = "file")
_start_rename :: proc(idx: int) {
	_renaming_action_idx = idx
	action_item := input_mgr.get_action_item(idx)
	wnd.show_rename_dialog("Rename Input Action", action_item.name, proc(new_name: string) {
		trimmed := strings.trim_space(new_name)
		if len(trimmed) > 0 {
			input_mgr.rename_action(_renaming_action_idx, trimmed)
		}
	})
}

@(private = "file")
_assign_choice_to_slot :: proc(action_idx: int, slot: int, choice: Input_Choice) {
	switch choice.kind {
	case .Keyboard:
		if slot == 0 {
			input_mgr.rebind_primary(action_idx, choice.key)
		} else if slot == 1 {
			input_mgr.rebind_secondary(action_idx, choice.key)
		} else {
			input_mgr.rebind_primary(action_idx, choice.key)
		}
	case .Mouse:
		if slot == 1 {
			input_mgr.rebind_mouse(action_idx, choice.mouse_btn, slot = 1)
		} else {
			input_mgr.rebind_mouse(action_idx, choice.mouse_btn, slot = 0)
		}
	case .Gamepad:
		input_mgr.rebind_gamepad(action_idx, choice.gamepad_btn)
	}
}

// ─────────────────────────────────────────────────────────────
// 1. SEARCHABLE INPUT SELECTOR MODAL (M1 / LEFT-CLICK)
// ─────────────────────────────────────────────────────────────
@(private = "file")
_draw_selector_modal :: proc() {
	if !_selector_open do return

	st := im.GetStyle()
	im.PushFontFloat(nil, st.FontSizeBase * wnd.get_modal_scale())
	defer im.PopFont()

	vp := im.GetMainViewport()
	center := im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize({580, 520}, .Appearing)

	if im.BeginPopupModal("Select Input Binding", &_selector_open, {}) {
		action_item := input_mgr.get_action_item(_selector_action_idx)
		slot_name := "Primary PC Key"
		if _selector_slot == 1 do slot_name = "Secondary PC Key"
		else if _selector_slot == 2 do slot_name = "Gamepad / Controller"

		im.TextColored({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("Action: %s  |  Slot: %s", action_item.name, slot_name))
		im.TextDisabled("Type below to filter, select from list, or switch to Direct Key / Mouse Listener.")
		im.Separator()

		// Quick Switch to Direct Key Listener
		im.PushStyleColorImVec4(.Button, {0.2, 0.35, 0.55, 1.0})
		im.PushStyleColorImVec4(.ButtonHovered, {0.28, 0.48, 0.75, 1.0})
		if im.Button(">> Switch to Direct Input Listener Mode (Key / Mouse / Wheel)", {-1, 32}) {
			_selector_open = false
			im.CloseCurrentPopup()
			_trigger_open_listener = true
			_listener_action_idx = _selector_action_idx
			_listener_slot = _selector_slot
		}
		im.PopStyleColor(2)

		im.Spacing()
		im.Separator()
		im.Spacing()

		// Search Filter & Category Chips
		im.Text("Search Filter:")
		im.SameLine()
		if _selector_focus_search {
			im.SetKeyboardFocusHere()
			_selector_focus_search = false
		}
		im.SetNextItemWidth(200)
		im.InputTextWithHint("##KeySearchInput", "e.g. Escape, Space, Shift...", cstring(raw_data(_selector_search_buf[:])), len(_selector_search_buf))

		im.SameLine()
		if im.Button("Clear##Search") {
			_selector_search_buf[0] = 0
		}

		im.SameLine()
		im.TextDisabled("|")
		im.SameLine()
		if im.RadioButton("All", _selector_filter_cat == 0) do _selector_filter_cat = 0
		im.SameLine()
		if im.RadioButton("Keyboard", _selector_filter_cat == 1) do _selector_filter_cat = 1
		im.SameLine()
		if im.RadioButton("Mouse", _selector_filter_cat == 2) do _selector_filter_cat = 2
		im.SameLine()
		if im.RadioButton("Gamepad", _selector_filter_cat == 3) do _selector_filter_cat = 3

		// Query lowercase string
		query_str := strings.trim_space(string(cstring(raw_data(_selector_search_buf[:]))))
		query_lower := strings.to_lower(query_str, context.temp_allocator)

		// Filtered scrollable list
		im.BeginChild("##KeySearchResults", {-1, 230}, {.Borders})

		match_count := 0
		for choice, i in CURATED_INPUTS {
			if _selector_filter_cat == 1 && choice.kind != .Keyboard do continue
			if _selector_filter_cat == 2 && choice.kind != .Mouse do continue
			if _selector_filter_cat == 3 && choice.kind != .Gamepad do continue

			if len(query_lower) > 0 {
				name_lower := strings.to_lower(choice.name, context.temp_allocator)
				if !strings.contains(name_lower, query_lower) && !strings.contains(choice.search_terms, query_lower) {
					continue
				}
			}

			match_count += 1
			im.PushIDInt(i32(i))

			tag_col := im.Vec4{0.3, 0.7, 1.0, 1.0}
			tag_str: cstring = "[KB]"
			if choice.kind == .Mouse {
				tag_col = {0.2, 0.9, 0.8, 1.0}
				tag_str = "[Mouse]"
			} else if choice.kind == .Gamepad {
				tag_col = {0.4, 0.9, 0.3, 1.0}
				tag_str = "[Pad]"
			}

			im.TextColored(tag_col, tag_str)
			im.SameLine(75)

			label := fmt.ctprintf("%s##choice", choice.name)
			if im.Selectable(label, false) {
				_assign_choice_to_slot(_selector_action_idx, _selector_slot, choice)
				_selector_open = false
				im.CloseCurrentPopup()
				im.PopID()
				break
			}

			im.PopID()
		}

		if match_count == 0 {
			im.Spacing()
			im.TextDisabled("No matching keys or buttons found.")
		}

		im.EndChild()

		im.Separator()
		im.Spacing()

		// Footer buttons
		if im.Button("Clear / Unbind Slot", {160, 28}) {
			input_mgr.clear_binding_slot(_selector_action_idx, _selector_slot)
			_selector_open = false
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Close / Cancel", {120, 28}) {
			_selector_open = false
			im.CloseCurrentPopup()
		}

		im.EndPopup()
	} else {
		_selector_open = false
	}
}

// ─────────────────────────────────────────────────────────────
// 2. LIVE KEY / MOUSE / WHEEL LISTENER MODAL WITH RED X
// ─────────────────────────────────────────────────────────────
@(private = "file")
_draw_listener_modal :: proc() {
	if !_listener_open do return

	st := im.GetStyle()
	im.PushFontFloat(nil, st.FontSizeBase * wnd.get_modal_scale())
	defer im.PopFont()

	vp := im.GetMainViewport()
	center := im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize({500, 260}, .Appearing)

	if im.BeginPopupModal("Listening for Input", &_listener_open, {.NoResize}) {
		action_item := input_mgr.get_action_item(_listener_action_idx)
		slot_name := "Primary PC Key"
		if _listener_slot == 1 do slot_name = "Secondary PC Key"
		else if _listener_slot == 2 do slot_name = "Gamepad / Controller"

		im.TextColored({1.0, 0.85, 0.2, 1.0}, "● LISTENING FOR INPUT...")
		im.TextUnformatted(fmt.ctprintf("Binding [%s] -> %s", action_item.name, slot_name))
		im.TextDisabled("Press ANY key, click mouse button (M1, M2, M3, M4, M5), or roll Mouse Wheel.")
		im.TextDisabled("All keys (including Escape, Space, Enter, Tab) will bind directly.")
		im.Spacing()
		im.Separator()
		im.Spacing()

		// BIG RED X BUTTON TO CANCEL LISTENING
		im.PushStyleColorImVec4(.Button, {0.8, 0.2, 0.2, 1.0})
		im.PushStyleColorImVec4(.ButtonHovered, {0.95, 0.28, 0.28, 1.0})
		im.PushStyleColorImVec4(.ButtonActive, {0.6, 0.1, 0.1, 1.0})
		im.PushStyleColorImVec4(.Text, {1.0, 1.0, 1.0, 1.0})
		red_x_pressed := im.Button(fmt.ctprintf("%s  Cancel / Abort Listening (X)", icons.ICON_MD_CLOSE), {-1, 44})
		red_x_hovered := im.IsItemHovered()
		im.PopStyleColor(4)

		// Safety Check: cancel immediately if Red X is clicked
		if red_x_pressed {
			_listener_open = false
			im.CloseCurrentPopup()
			im.EndPopup()
			return
		}

		// Wait until opening click has been fully released before accepting input
		if !_listener_ready {
			io := im.GetIO()
			if !io.MouseDown[0] && !io.MouseDown[1] && !input.mouse_down(.Left) && !input.mouse_down(.Right) {
				_listener_ready = true
			}
		} else if !red_x_hovered {
			bound := false

			// 1. Check Mouse Wheel (Wheel Up / Wheel Down)
			io := im.GetIO()
			wheel_delta := io.MouseWheel
			if wheel_delta == 0 {
				wheel_delta = input.wheel()
			}
			if wheel_delta > 0.1 {
				input_mgr.rebind_wheel(_listener_action_idx, true, _listener_slot)
				_listener_open = false
				im.CloseCurrentPopup()
				bound = true
			} else if wheel_delta < -0.1 {
				input_mgr.rebind_wheel(_listener_action_idx, false, _listener_slot)
				_listener_open = false
				im.CloseCurrentPopup()
				bound = true
			}

			// 2. Check Mouse Buttons (M1, M2, M3, M4, M5)
			if !bound {
				if im.IsMouseClicked(.Left) || input.mouse_pressed(.Left) {
					input_mgr.rebind_mouse(_listener_action_idx, .Left, _listener_slot)
					_listener_open = false
					im.CloseCurrentPopup()
					bound = true
				} else if im.IsMouseClicked(.Right) || input.mouse_pressed(.Right) {
					input_mgr.rebind_mouse(_listener_action_idx, .Right, _listener_slot)
					_listener_open = false
					im.CloseCurrentPopup()
					bound = true
				} else if im.IsMouseClicked(.Middle) || input.mouse_pressed(.Middle) {
					input_mgr.rebind_mouse(_listener_action_idx, .Middle, _listener_slot)
					_listener_open = false
					im.CloseCurrentPopup()
					bound = true
				} else if im.IsMouseClicked(im.MouseButton(3)) || input.mouse_pressed(.X1) {
					input_mgr.rebind_mouse(_listener_action_idx, .X1, _listener_slot)
					_listener_open = false
					im.CloseCurrentPopup()
					bound = true
				} else if im.IsMouseClicked(im.MouseButton(4)) || input.mouse_pressed(.X2) {
					input_mgr.rebind_mouse(_listener_action_idx, .X2, _listener_slot)
					_listener_open = false
					im.CloseCurrentPopup()
					bound = true
				}
			}

			// 3. Check Keyboard Keys
			if !bound {
				for choice in CURATED_INPUTS {
					if choice.kind == .Keyboard && choice.key != .UNKNOWN {
						if input.key_pressed(choice.key) {
							_assign_choice_to_slot(_listener_action_idx, _listener_slot, choice)
							_listener_open = false
							im.CloseCurrentPopup()
							bound = true
							break
						}
					}
				}
			}
		}

		im.EndPopup()
	} else {
		_listener_open = false
	}
}

// ─────────────────────────────────────────────────────────────
// 3. MANUAL NUMBER INPUT MODAL FOR SLIDERS
// ─────────────────────────────────────────────────────────────
@(private = "file")
_draw_manual_input_modal :: proc() {
	if !_manual_modal_open do return

	vp := im.GetMainViewport()
	center := im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize({380, 200}, .Appearing)

	if im.BeginPopupModal("Manual Number Input", &_manual_modal_open, {.NoResize}) {
		im.TextColored({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("%s  Manual Number Input", icons.ICON_MD_EDIT))
		im.TextUnformatted(fmt.ctprintf("Setting: %s", _manual_modal_label))
		im.Separator()
		im.Spacing()

		im.Text("Enter exact numeric value:")
		im.SetNextItemWidth(-1)
		if _manual_focus {
			im.SetKeyboardFocusHere()
			_manual_focus = false
		}
		enter_pressed := im.InputFloat("##ManualFloatInput", &_manual_temp_val, 0.0, 0.0, "%.2f", {.EnterReturnsTrue})

		im.Spacing()
		im.Separator()
		im.Spacing()

		// Green Apply button
		im.PushStyleColorImVec4(.Button, {0.2, 0.7, 0.3, 1.0})
		im.PushStyleColorImVec4(.ButtonHovered, {0.25, 0.85, 0.35, 1.0})
		im.PushStyleColorImVec4(.ButtonActive, {0.15, 0.55, 0.2, 1.0})
		im.PushStyleColorImVec4(.Text, {1.0, 1.0, 1.0, 1.0})
		if im.Button(fmt.ctprintf("%s  Apply", icons.ICON_MD_CHECK), {120, 32}) || enter_pressed {
			if _manual_target_ptr != nil {
				val := _manual_temp_val
				if _manual_max <= 1.0 {
					val = clamp(val, _manual_min, 0.95)
				} else {
					val = clamp(val, max(0.01, _manual_min), 50.0)
				}
				_manual_target_ptr^ = val
			}
			_manual_modal_open = false
			im.CloseCurrentPopup()
		}
		im.PopStyleColor(4)

		im.SameLine(0, 15)

		// Red Cancel button
		im.PushStyleColorImVec4(.Button, {0.75, 0.2, 0.2, 1.0})
		im.PushStyleColorImVec4(.ButtonHovered, {0.9, 0.3, 0.3, 1.0})
		im.PushStyleColorImVec4(.ButtonActive, {0.6, 0.15, 0.15, 1.0})
		im.PushStyleColorImVec4(.Text, {1.0, 1.0, 1.0, 1.0})
		if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {120, 32}) {
			_manual_modal_open = false
			im.CloseCurrentPopup()
		}
		im.PopStyleColor(4)

		im.EndPopup()
	} else {
		_manual_modal_open = false
	}
}

@(private = "file")
_draw_slider_with_dropdown :: proc(
	label: string,
	val_ptr: ^f32,
	min_val: f32,
	max_val: f32,
	default_val: f32,
	format: string,
) {
	label_cstr := strings.clone_to_cstring(label, context.temp_allocator)
	format_cstr := strings.clone_to_cstring(format, context.temp_allocator)

	im.SliderFloat(label_cstr, val_ptr, min_val, max_val, format_cstr)

	widgets.tooltip("Drag to slide\nRight-Click (M2): Dropdown Menu to input number manually or reset")

	// Dropdown Context Menu on Right Click (M2)
	ctx_id := fmt.ctprintf("##SliderCtx_%s", label)
	if im.BeginPopupContextItem(ctx_id) {
		if im.IsWindowAppearing() {
			_quick_input_val = val_ptr^
		}

		im.TextColored({0.3, 0.75, 1.0, 1.0}, fmt.ctprintf("%s  %s", icons.ICON_MD_TUNE, label))
		im.Separator()

		// 1. Dropdown Option: "Input Number Manually..."
		if im.MenuItem(fmt.ctprintf("%s  Input Number Manually...", icons.ICON_MD_EDIT)) {
			_manual_modal_label = label
			_manual_target_ptr = val_ptr
			_manual_temp_val = val_ptr^
			_manual_min = min_val
			_manual_max = max_val
			_trigger_open_manual_modal = true
			im.CloseCurrentPopup()
		}

		// 2. Quick inline numeric field in the dropdown
		im.Separator()
		im.TextDisabled("Quick Manual Input:")
		im.SetNextItemWidth(100)
		if im.InputFloat("##quick_num_input", &_quick_input_val, 0.0, 0.0, "%.2f", {.EnterReturnsTrue}) {
			if max_val <= 1.0 {
				val_ptr^ = clamp(_quick_input_val, min_val, 0.95)
			} else {
				val_ptr^ = clamp(_quick_input_val, max(0.01, min_val), 50.0)
			}
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Apply") {
			if max_val <= 1.0 {
				val_ptr^ = clamp(_quick_input_val, min_val, 0.95)
			} else {
				val_ptr^ = clamp(_quick_input_val, max(0.01, min_val), 50.0)
			}
			im.CloseCurrentPopup()
		}

		// 3. Reset to Default option
		im.Separator()
		if im.MenuItem(fmt.ctprintf("%s  Reset to Default (%.2f)", icons.ICON_MD_REFRESH, default_val)) {
			val_ptr^ = default_val
		}

		im.EndPopup()
	}
}

// ─────────────────────────────────────────────────────────────
// MAIN EDITOR WINDOW
// ─────────────────────────────────────────────────────────────
@(editor_window={id="input_manager", title="Input Manager", icon="KEYBOARD", width=800, height=620})
input_manager_window_draw :: proc() {
	// Trigger modals from window root ID scope
	if _trigger_open_selector {
		_trigger_open_selector = false
		_selector_open = true
		_selector_search_buf = {}
		_selector_focus_search = true
		im.OpenPopup("Select Input Binding", {})
	}
	if _trigger_open_listener {
		_trigger_open_listener = false
		_listener_open = true
		_listener_ready = false
		im.OpenPopup("Listening for Input", {})
	}
	if _trigger_open_manual_modal {
		_trigger_open_manual_modal = false
		_manual_modal_open = true
		_manual_focus = true
		im.OpenPopup("Manual Number Input", {})
	}

	im.TextColored({0.3, 0.75, 1.0, 1.0}, "Unreal / Godot Style Input Action & Axis Router")
	im.TextDisabled("Priority-based routing, 3 binding slots (PC Primary, PC Secondary, Gamepad), and searchable input rebinding.")
	im.Separator()

	if im.CollapsingHeader("Global Input Settings (Direct Type or Slide)", {.DefaultOpen}) {
		im.Columns(2, "settings_cols", false)
		im.SetColumnWidth(0, 360)

		// Direct typing + slider support with right-click dropdown menu
		_draw_slider_with_dropdown("Mouse Sensitivity (Master)", &input_mgr.settings.mouse_sensitivity, 0.05, 5.0, 1.0, "%.2fx")
		_draw_slider_with_dropdown("Mouse Yaw Mult (Horizontal)", &input_mgr.settings.mouse_yaw_mult, 0.05, 5.0, 1.0, "%.2fx")
		_draw_slider_with_dropdown("Mouse Pitch Mult (Vertical)", &input_mgr.settings.mouse_pitch_mult, 0.05, 5.0, 1.0, "%.2fx")

		im.NextColumn()
		_draw_slider_with_dropdown("Gamepad Sensitivity", &input_mgr.settings.gamepad_sensitivity, 0.1, 5.0, 1.0, "%.2fx")
		_draw_slider_with_dropdown("Stick Deadzone", &input_mgr.settings.deadzone, 0.0, 0.5, 0.15, "%.2f")
		im.Checkbox("Invert Look Y-Axis", &input_mgr.settings.invert_y)

		if im.Button("Reset Settings to Default") {
			input_mgr.settings.mouse_sensitivity   = 1.0
			input_mgr.settings.mouse_yaw_mult      = 1.0
			input_mgr.settings.mouse_pitch_mult    = 1.0
			input_mgr.settings.gamepad_sensitivity = 1.0
			input_mgr.settings.deadzone            = 0.15
			input_mgr.settings.invert_y            = false
		}

		im.Columns(1)
	}

	im.Spacing()
	if im.CollapsingHeader("Live Input Telemetry (Radar & Look)", {.DefaultOpen}) {
		mv := input_mgr.get_movement_vector()
		lk := input_mgr.get_look_vector()

		im.Columns(2, "telemetry_cols", false)
		im.SetColumnWidth(0, 140)

		// 2D Movement Radar Widget
		canvas_pos := im.GetCursorScreenPos()
		canvas_size := im.Vec2{110, 110}
		center := im.Vec2{canvas_pos.x + canvas_size.x * 0.5, canvas_pos.y + canvas_size.y * 0.5}
		radius: f32 = 48.0

		dl := im.GetWindowDrawList()
		bg_col := im.ColorConvertFloat4ToU32({0.12, 0.14, 0.18, 1.0})
		border_col := im.ColorConvertFloat4ToU32({0.3, 0.35, 0.45, 1.0})
		cross_col := im.ColorConvertFloat4ToU32({0.2, 0.25, 0.3, 1.0})
		stick_col := im.ColorConvertFloat4ToU32({0.2, 0.9, 0.5, 1.0})
		line_col := im.ColorConvertFloat4ToU32({0.2, 0.8, 0.4, 0.6})

		im.DrawList_AddRectFilled(dl, canvas_pos, {canvas_pos.x + canvas_size.x, canvas_pos.y + canvas_size.y}, bg_col, 6.0)
		im.DrawList_AddCircle(dl, center, radius, border_col, 32, 1.5)
		im.DrawList_AddLine(dl, {center.x - radius, center.y}, {center.x + radius, center.y}, cross_col, 1.0)
		im.DrawList_AddLine(dl, {center.x, center.y - radius}, {center.x, center.y + radius}, cross_col, 1.0)

		dot_pos := im.Vec2{center.x + mv.x * radius, center.y - mv.y * radius}
		im.DrawList_AddLine(dl, center, dot_pos, line_col, 2.0)
		im.DrawList_AddCircleFilled(dl, dot_pos, 5.0, stick_col)

		im.Dummy(canvas_size)

		im.NextColumn()
		im.Text("Movement Vector:")
		im.TextColored({0.2, 0.9, 0.5, 1.0}, fmt.ctprintf("  X: %+.2f", mv.x))
		im.TextColored({0.2, 0.9, 0.5, 1.0}, fmt.ctprintf("  Y: %+.2f", mv.y))
		im.Spacing()
		im.Text("Mouse Look Delta:")
		im.TextColored({0.4, 0.8, 1.0, 1.0}, fmt.ctprintf("  dX: %+.2f", lk.x))
		im.TextColored({0.4, 0.8, 1.0, 1.0}, fmt.ctprintf("  dY: %+.2f", lk.y))
		im.Columns(1)
	}

	im.Spacing()
	if im.CollapsingHeader("Action Mappings & Rebinding (3 Slots)", {.DefaultOpen}) {
		// Responsive Add Action Bar with adaptive width so Cancel is never clipped
		if !_show_add_action {
			if im.Button("+ Add Custom Action") {
				_show_add_action = true
				_new_action_buf[0] = 0
			}
		} else {
			avail_w := im.GetContentRegionAvail().x
			input_w := max(avail_w - 330.0, 140.0)

			im.TextColored({0.4, 0.8, 1.0, 1.0}, "New Action Name:")
			im.SameLine()
			im.SetNextItemWidth(input_w)
			im.InputTextWithHint("##NewActionName", "e.g. Fire_Primary", cstring(&_new_action_buf[0]), len(_new_action_buf))
			im.SameLine()
			if im.Button("Confirm Add", {95, 0}) {
				name := strings.trim_right_null(string(_new_action_buf[:]))
				if len(name) > 0 {
					input_mgr.add_custom_action(name)
					_show_add_action = false
				}
			}
			im.SameLine()
			if im.Button("Cancel", {70, 0}) {
				_show_add_action = false
			}
		}

		im.Spacing()
		table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter | im.TableFlags_BordersInnerH
		if im.BeginTable("##ActionMappings3Col", 6, table_flags) {
			im.TableSetupColumn("Action (2x-Click: Rename)", {.WidthFixed}, 175)
			im.TableSetupColumn("Status", {.WidthFixed}, 75)
			im.TableSetupColumn("Primary PC", {.WidthStretch})
			im.TableSetupColumn("Secondary PC", {.WidthStretch})
			im.TableSetupColumn("Gamepad / Controller", {.WidthStretch})
			im.TableSetupColumn("Delete", {.WidthFixed}, 65)
			im.TableHeadersRow()

			total_actions := input_mgr.get_action_count()
			for i in 0 ..< total_actions {
				item := input_mgr.get_action_item(i)
				down := input_mgr.is_action_down_idx(i)

				im.PushIDInt(i32(i))
				im.TableNextRow()

				// Col 0: Action name (Inline Rename on Double-Click, Context Menu on Right-Click)
				im.TableNextColumn()
				if _renaming_action_idx == i {
					if _rename_focus {
						im.SetKeyboardFocusHere()
						_rename_focus = false
					}
					im.SetNextItemWidth(-1)
					buf_cstr := cstring(raw_data(_rename_buf[:]))
					flags := im.InputTextFlags{.EnterReturnsTrue, .AutoSelectAll}
					if im.InputText("##InlineRename", buf_cstr, c.size_t(len(_rename_buf)), flags) {
						new_name := strings.trim_space(string(cstring(raw_data(_rename_buf[:]))))
						if len(new_name) > 0 {
							input_mgr.rename_action(i, new_name)
						}
						_renaming_action_idx = -1
					}
					if _rename_just_opened {
						_rename_just_opened = false
					} else if !im.IsItemActive() {
						if im.IsItemDeactivatedAfterEdit() {
							new_name := strings.trim_space(string(cstring(raw_data(_rename_buf[:]))))
							if len(new_name) > 0 {
								input_mgr.rename_action(i, new_name)
							}
						}
						_renaming_action_idx = -1
					}
				} else {
					label := fmt.ctprintf("%s##ActRow_%d", item.name, i)
					_ = im.Selectable(label, false)

					// Dropdown context menu on Right-Click (M2)
					if im.BeginPopupContextItem(fmt.ctprintf("##ActionCtxMenu_%d", i)) {
						if im.MenuItem(fmt.ctprintf("%s  Rename", icons.ICON_MD_EDIT)) {
							_start_rename(i)
						}
						im.Separator()
						if im.MenuItem(fmt.ctprintf("%s  Delete", icons.ICON_MD_DELETE)) {
							_delete_action_idx = i
							action_item := input_mgr.get_action_item(i)
							wnd.show_confirm_dialog(
								"Delete Action Mapping",
								fmt.tprintf("You are about to delete mapped input: '%s'.\nThis will NOT automatically fix any script or code that may listen to this input mapping!", action_item.name),
								confirm_label = "Confirm Delete",
								on_confirm = proc() {
									input_mgr.delete_action(_delete_action_idx)
								},
								is_danger = true,
							)
						}
						im.EndPopup()
					}

					widgets.tooltip("M1 Double-Click: Rename Action\nM2 (Right-Click): Menu (Rename / Delete)")
					if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
						_start_rename(i)
					}
				}

				// Col 1: Status badge
				im.TableNextColumn()
				if down {
					im.TextColored({0.2, 1.0, 0.4, 1.0}, "[ DOWN ]")
				} else {
					im.TextDisabled("[ IDLE ]")
				}

				// Col 2: Primary PC Key button
				im.TableNextColumn()
				p_str := input_mgr.format_slot_display(item, 0)
				btn_p := fmt.ctprintf("%s##P_%d", p_str, i)
				if im.Button(btn_p, {-1, 0}) {
					_selector_action_idx = i
					_selector_slot = 0
					_selector_filter_cat = 0
					_selector_search_buf = {}
					_trigger_open_selector = true
				}
				if im.IsItemClicked(.Right) {
					_listener_action_idx = i
					_listener_slot = 0
					_trigger_open_listener = true
				}
				widgets.tooltip("Left-Click (M1): Open Searchable Key Selector\nRight-Click (M2): Direct Input Listener (Key / Mouse / Wheel)")

				// Col 3: Secondary PC Key button
				im.TableNextColumn()
				s_str := input_mgr.format_slot_display(item, 1)
				btn_s := fmt.ctprintf("%s##S_%d", s_str, i)
				if im.Button(btn_s, {-1, 0}) {
					_selector_action_idx = i
					_selector_slot = 1
					_selector_filter_cat = 0
					_selector_search_buf = {}
					_trigger_open_selector = true
				}
				if im.IsItemClicked(.Right) {
					_listener_action_idx = i
					_listener_slot = 1
					_trigger_open_listener = true
				}
				widgets.tooltip("Left-Click (M1): Open Searchable Key Selector\nRight-Click (M2): Direct Input Listener (Key / Mouse / Wheel)")

				// Col 4: Gamepad Button
				im.TableNextColumn()
				g_str := input_mgr.format_slot_display(item, 2)
				btn_g := fmt.ctprintf("%s##G_%d", g_str, i)
				if im.Button(btn_g, {-1, 0}) {
					_selector_action_idx = i
					_selector_slot = 2
					_selector_filter_cat = 3 // Gamepad tab default
					_selector_search_buf = {}
					_trigger_open_selector = true
				}
				if im.IsItemClicked(.Right) {
					_listener_action_idx = i
					_listener_slot = 2
					_trigger_open_listener = true
				}
				widgets.tooltip("Left-Click (M1): Open Gamepad Button Selector\nRight-Click (M2): Direct Input Listener")

				// Col 5: Big Ass Red X Button (with confirmation warning modal)
				im.TableNextColumn()
				im.PushStyleColorImVec4(.Button, {0.75, 0.18, 0.18, 1.0})
				im.PushStyleColorImVec4(.ButtonHovered, {0.95, 0.25, 0.25, 1.0})
				im.PushStyleColorImVec4(.ButtonActive, {0.6, 0.1, 0.1, 1.0})
				im.PushStyleColorImVec4(.Text, {1.0, 1.0, 1.0, 1.0})
				if im.Button(fmt.ctprintf("%s##Del_%d", icons.ICON_MD_CLOSE, i), {-1, 0}) {
					_delete_action_idx = i
					action_item := input_mgr.get_action_item(i)
					wnd.show_confirm_dialog(
						"Delete Action Mapping",
						fmt.tprintf("You are about to delete mapped input: '%s'.\nThis will NOT automatically fix any script or code that may listen to this input mapping!", action_item.name),
						confirm_label = "Confirm Delete",
						on_confirm = proc() {
							input_mgr.delete_action(_delete_action_idx)
						},
						is_danger = true,
					)
				}
				im.PopStyleColor(4)
				widgets.tooltip("Delete or clear this action mapping")

				im.PopID()
			}
			im.EndTable()
		}
	}

	im.Spacing()
	if im.CollapsingHeader("Developer Integration Guide", {.DefaultOpen}) {
		im.TextColored({1.0, 0.85, 0.3, 1.0}, "How to claim actions with priority:")
		im.Text("1. In your player or UI controller, claim an action:")
		widgets.copyable_text("ig_claim_action", "input_mgr.claim_action(.Jump, priority = 10, callback = on_jump_callback, owner = my_ptr)")

		im.Spacing()
		im.Text("2. If your callback returns 'true', it consumes the event, preventing lower-priority listeners from receiving it.")

		im.Spacing()
		im.Text("3. Register continuous 2D vector consumers (Movement & Look):")
		widgets.copyable_text("ig_claim_movement", "input_mgr.claim_movement(priority = 10, callback = on_move_callback, owner = my_ptr)")
		widgets.copyable_text("ig_claim_look", "input_mgr.claim_look(priority = 10, callback = on_look_callback, owner = my_ptr)")

		im.Spacing()
		im.Text("4. When cleaning up or disabling an entity:")
		widgets.copyable_text("ig_release_all", "input_mgr.release_all_for_owner(my_ptr)")

		im.Spacing()
		im.Separator()
		im.Spacing()

		full_code := `// --- MoonHug Input Manager Integration Boilerplate ---
// 1. Claim discrete actions (callbacks return true if consumed)
input_mgr.claim_action(.Jump, priority = 10, callback = proc(action: input_mgr.Action_Type, phase: input_mgr.Action_Phase, owner: rawptr) -> bool {
	// Handle Jump...
	return true
}, owner = self)

// 2. Claim continuous 2D axes (WASD movement & mouse look)
input_mgr.claim_movement(priority = 10, callback = proc(delta: [2]f32, owner: rawptr) {
	// Handle move vector...
}, owner = self)

input_mgr.claim_look(priority = 10, callback = proc(delta: [2]f32, owner: rawptr) {
	// Handle look vector...
}, owner = self)

// 3. Release listeners on cleanup/destroy
input_mgr.release_all_for_owner(self)`

		widgets.copyable_code_block("ig_full_code", full_code, "Full Input Integration Snippet")
	}

	// Always render modals at window root ID scope
	_draw_selector_modal()
	_draw_listener_modal()
	_draw_manual_input_modal()
}

@(menu_item={path="Window/Input Manager", shortcut=""})
input_manager_window_open :: proc() {
	wnd.open("input_manager")
}
