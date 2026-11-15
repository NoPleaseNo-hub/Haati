package control_rig

import "base:runtime"
import "core:math/linalg"
import "core:strings"
import "haati:engine"

@(init)
_install_anim_vs_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.visual_script_install_anim_bridge(engine.Visual_Script_Anim_Bridge{
		set_ik_target = _vs_set_ik_target,
	})
}

_vs_set_ik_target :: proc(target: engine.Transform_Handle, effector_name: string, effector_pos: [3]f32, weight: f32) {
	_, rig, ok := engine.vs_resolve_entity_comp(engine.Handle(target), ControlRig)
	if !ok do return

	t := clamp(weight, f32(0.0), f32(1.0))
	key := strings.to_lower(strings.trim_space(effector_name), context.temp_allocator)
	ctrl: ^Rig_Control
	switch key {
	case "foot_l", "left_foot":   ctrl = &rig.left_foot
	case "foot_r", "right_foot":  ctrl = &rig.right_foot
	case "hand_l", "left_hand":   ctrl = &rig.left_hand
	case "hand_r", "right_hand":  ctrl = &rig.right_hand
	case "pelvis":                ctrl = &rig.pelvis
	case "head":                  ctrl = &rig.head
	case "look_at":
		rig.look_at_target = linalg.lerp(rig.look_at_target, effector_pos, t)
		return
	case:
		ctrl = &rig.left_foot
	}
	ctrl.position = linalg.lerp(ctrl.position, effector_pos, t)
	ctrl.rotation_weight = t
}
