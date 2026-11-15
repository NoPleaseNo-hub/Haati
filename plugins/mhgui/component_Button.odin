package mhgui

// Button: a clickable graphic with Unity's Selectable transition. The pointer
// pass (engine.canvas_pointer_update, run by ui_tick below before any game
// update) says which node is hovered, pressed, selected and clicked; every
// Button derives its state from that and tints its target graphic's
// CanvasRenderer with the matching color, fading over fade_duration. A click
// (press and release on the node) sets `clicked` for the rest of the frame;
// game code polls button_clicked. The node needs a graphic with
// raycast_target on (Image or Text) to be hit at all.

import "base:runtime"
import "haati:engine"
import input "haati:engine/input"

Selectable_Transition :: enum u8 {
	None,
	Color_Tint,
}

Selectable_State :: enum u8 {
	Normal,
	Highlighted,
	Pressed,
	Selected,
	Disabled,
}

// Unity's ColorBlock. Colors multiply the graphic's own color.
Color_Block :: struct {
	normal:           [4]f32 `decor:color()`,
	highlighted:      [4]f32 `decor:color()`,
	pressed:          [4]f32 `decor:color()`,
	selected:         [4]f32 `decor:color()`,
	disabled:         [4]f32 `decor:color()`,
	color_multiplier: f32,
	fade_duration:    f32, // seconds
}

@(component={menu="UI/Button"})
@(typ_guid={guid = "df76380d-f03d-4b86-9872-9f35af0d58e6"})
Button :: struct {
	using base:     engine.CompData `inspect:"-"`,
	interactable:   bool,
	transition:     Selectable_Transition,
	target_graphic: engine.Ref_Local `ref:"Transform"`, // the node whose graphic takes the tint; empty = this node
	colors:         Color_Block,
	// Runtime state, never saved.
	state:   Selectable_State `json:"-" inspect:"-"`,
	clicked: bool             `json:"-" inspect:"-"`, // pressed and released on this node this frame
}

reset_Button :: proc(b: ^Button) {
	b.interactable = true
	b.transition = .Color_Tint
	b.colors = Color_Block{
		normal           = {1, 1, 1, 1},
		highlighted      = {0.96, 0.96, 0.96, 1},
		pressed          = {0.78, 0.78, 0.78, 1},
		selected         = {0.96, 0.96, 0.96, 1},
		disabled         = {0.78, 0.78, 0.78, 0.5},
		color_multiplier = 1,
		fade_duration    = 0.1,
	}
}

Button_Click_Proc :: #type proc(b: ^Button)

@(private = "file")
_button_click_callbacks: map[engine.Transform_Handle]Button_Click_Proc

button_set_on_click :: proc(b: ^Button, cb: Button_Click_Proc) {
	if b == nil || b.owner == {} do return
	context.allocator = runtime.default_allocator()
	if cb == nil {
		delete_key(&_button_click_callbacks, b.owner)
	} else {
		_button_click_callbacks[b.owner] = cb
	}
}

button_clear_callbacks :: proc(free_map := false) {
	context.allocator = runtime.default_allocator()
	clear(&_button_click_callbacks)
	if free_map {
		delete(_button_click_callbacks)
		_button_click_callbacks = nil
	}
}

@(private = "file")
_button_clear_owner_callback :: proc(b: ^Button) {
	if b == nil || b.owner == {} do return
	context.allocator = runtime.default_allocator()
	delete_key(&_button_click_callbacks, b.owner)
}

cleanup_Button :: proc(b: ^Button) {
	_button_clear_owner_callback(b)
	engine.comp_zero(b)
}

on_destroy_Button :: proc(b: ^Button) {
	_button_clear_owner_callback(b)
}

@(phase={key=ExitingPlayMode})
_mhgui_buttons_exiting_play_mode :: proc() {
	button_clear_callbacks(true)
}

// True on the frame the button was clicked. Read after ui_tick (any
// @(update) at order 0 or later).
button_clicked :: proc(b: ^Button) -> bool {
	return b.clicked
}

// The pointer pass, then every Button's state and tint. Before the game's
// updates so they see this frame's clicks.
@(update={order=-100})
ui_tick :: proc(dt: f32) {
	engine.canvas_pointer_update()
	w := engine.ctx_world()
	if w == nil do return

	if !input.is_mouse_relative() {
		nav := engine.ui_nav_move_pressed()
		step := int(nav.y) if nav.y != 0 else int(nav.x)
		if step != 0 {
			focusable := make([dynamic]engine.Transform_Handle, 0, 8, context.temp_allocator)
			it_nav := engine.pool_iterator(buttons(w))
			for b, _ in engine.pool_next(&it_nav) {
				if !b.enabled || !b.interactable || !engine.transform_active_in_hierarchy(b.owner) do continue
				append(&focusable, b.owner)
			}
			if len(focusable) > 0 {
				cur := engine.ui_pointer().selected
				cur_idx := -1
				for h, idx in focusable {
					if h == cur {
						cur_idx = idx
						break
					}
				}
				next_idx := 0
				if cur_idx < 0 {
					next_idx = 0 if step > 0 else len(focusable) - 1
				} else {
					n := len(focusable)
					delta := 1 if step > 0 else -1
					next_idx = ((cur_idx + delta) % n + n) % n
				}
				engine.ui_set_selected(focusable[next_idx])
			}
		}
	}

	pointer := engine.ui_pointer()
	submit := !input.is_mouse_relative() && engine.ui_submit_pressed()
	fired := make([dynamic]engine.Transform_Handle, 0, 4, context.temp_allocator)

	it := engine.pool_iterator(buttons(w))
	for b, _ in engine.pool_next(&it) {
		if !b.enabled || !engine.transform_active_in_hierarchy(b.owner) {
			b.clicked = false
			continue
		}
		node := b.owner
		b.clicked = b.interactable && (pointer.clicked == node || (submit && pointer.selected == node))
		if b.clicked {
			append(&fired, node)
		}
		switch {
		case !b.interactable:          b.state = .Disabled
		case pointer.pressed == node:  b.state = .Pressed
		case pointer.hovered == node:  b.state = .Highlighted
		case pointer.selected == node: b.state = .Selected
		case:                          b.state = .Normal
		}
		if b.transition == .Color_Tint do _button_tint(b, dt)
	}

	for node in fired {
		if !engine.pool_valid(&w.transforms, engine.Handle(node)) do continue
		if !engine.transform_active_in_hierarchy(node) do continue
		_, live_btn := engine.transform_get_comp(node, Button)
		if live_btn == nil || !live_btn.enabled || !live_btn.interactable do continue
		if cb, ok := _button_click_callbacks[node]; ok && cb != nil {
			cb(live_btn)
		}
	}
}

@(private = "file")
_button_tint :: proc(b: ^Button, dt: f32) {
	target_tH := engine.Transform_Handle(b.target_graphic.handle)
	if target_tH == {} do target_tH = b.owner
	_, cr := engine.transform_get_comp(target_tH, engine.CanvasRenderer)
	if cr == nil do return
	c := b.colors
	want: [4]f32
	switch b.state {
	case .Normal:      want = c.normal
	case .Highlighted: want = c.highlighted
	case .Pressed:     want = c.pressed
	case .Selected:    want = c.selected
	case .Disabled:    want = c.disabled
	}
	want *= c.color_multiplier
	if !cr.tinted || c.fade_duration <= 0 {
		engine.canvas_renderer_set_tint(cr, want)
		return
	}
	// Move a fraction of the way each frame: done within fade_duration.
	t := min(dt / c.fade_duration, 1)
	engine.canvas_renderer_set_tint(cr, cr.tint + (want - cr.tint) * t)
}
