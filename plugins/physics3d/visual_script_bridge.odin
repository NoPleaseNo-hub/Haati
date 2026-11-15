package physics3d

import "base:runtime"
import "core:math/linalg"
import jolt "haati:external/jolt"
import "haati:engine"
import hot "haati:engine/hot_api"

@(init)
_install_physics_vs_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.visual_script_install_physics_bridge(engine.Visual_Script_Physics_Bridge{
		raycast_masked = _vs_raycast_masked,
		overlap_sphere = _vs_overlap_sphere,
		add_impulse    = _vs_add_impulse,
		poll_triggers  = _vs_poll_triggers,
	})
}

_vs_raycast_masked :: proc(
	origin, dir:  [3]f32,
	max_dist:     f32,
	mask:         u32,
	ignore_owner: engine.Transform_Handle,
) -> (out: hot.Hot_Raycast_Hit, ok: bool) {
	m := mask != 0 ? Collision_Mask(mask) : MASK_WEAPON_TRACE
	h, hit_ok := raycast_masked(origin, dir, max_dist, m, ignore_owner)
	if !hit_ok do return {}, false
	ho := engine.Handle(h.owner)
	return hot.Hot_Raycast_Hit{
		hit      = true,
		channel  = u8(h.channel),
		entity   = hot.Hot_Entity{index = u32(ho.index), generation = u16(ho.generation)},
		position = h.position,
		normal   = h.normal,
		distance = h.distance,
		fraction = h.fraction,
	}, true
}

_vs_check_overlap_candidate :: proc(
	w:          ^engine.World,
	owner:      engine.Transform_Handle,
	ignore:     engine.Transform_Handle,
	channel:    Collision_Channel,
	mask:       u32,
	local_off:  [3]f32,
	bound_r:    f32,
	center:     [3]f32,
	radius:     f32,
	seen:       ^map[u64]bool,
	best_d:     ^f32,
	best_owner: ^engine.Transform_Handle,
	count:      ^i32,
) {
	if owner == {} || owner == ignore do return
	oh := engine.Handle(owner)
	if !engine.pool_valid(&w.transforms, oh) do return
	bit := u32(1) << u32(channel)
	if mask != 0 && (mask & bit) == 0 do return
	ek := (u64(oh.index) << 32) | u64(oh.generation)
	if seen^[ek] do return

	tw := engine.transform_world(owner)
	pos := tw.position + local_off
	d := linalg.distance(center, pos) - max(bound_r, 0.0)
	if d <= radius {
		seen^[ek] = true
		count^ += 1
		if d < best_d^ {
			best_d^ = d
			best_owner^ = owner
		}
	}
}

_vs_overlap_sphere :: proc(
	center:       [3]f32,
	radius:       f32,
	mask:         u32,
	ignore_owner: engine.Transform_Handle,
) -> (count: i32, closest: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil || radius <= 0 do return 0, {}

	seen := make(map[u64]bool, 16, context.temp_allocator)
	best_d := f32(1e30)

	if spool := sphere_colliders(w); spool != nil {
		it := engine.pool_iterator(spool)
		for sc, _ in engine.pool_next(&it) {
			if !sc.enabled do continue
			_vs_check_overlap_candidate(w, sc.owner, ignore_owner, sc.channel, mask, sc.center, sc.radius, center, radius, &seen, &best_d, &closest, &count)
		}
	}
	if bpool := box_colliders(w); bpool != nil {
		it := engine.pool_iterator(bpool)
		for bc, _ in engine.pool_next(&it) {
			if !bc.enabled do continue
			br := 0.5 * linalg.length(bc.size)
			_vs_check_overlap_candidate(w, bc.owner, ignore_owner, bc.channel, mask, bc.center, br, center, radius, &seen, &best_d, &closest, &count)
		}
	}
	if cpool := capsule_colliders(w); cpool != nil {
		it := engine.pool_iterator(cpool)
		for cc, _ in engine.pool_next(&it) {
			if !cc.enabled do continue
			br := max(cc.radius, cc.height * 0.5)
			_vs_check_overlap_candidate(w, cc.owner, ignore_owner, cc.channel, mask, cc.center, br, center, radius, &seen, &best_d, &closest, &count)
		}
	}
	if rpool := rigidbodies(w); rpool != nil {
		it := engine.pool_iterator(rpool)
		for rb, _ in engine.pool_next(&it) {
			if !rb.enabled do continue
			_vs_check_overlap_candidate(w, rb.owner, ignore_owner, rb.channel, mask, {}, 0.0, center, radius, &seen, &best_d, &closest, &count)
		}
	}
	return count, closest
}

_vs_add_impulse :: proc(target: engine.Transform_Handle, impulse: [3]f32, is_velocity_change: bool) {
	_, rb, ok := engine.vs_resolve_entity_comp(engine.Handle(target), Rigidbody)
	if !ok do return

	if is_velocity_change {
		rb_set_velocity(rb, rb_get_velocity(rb) + impulse, rb.true_angular_vel)
		return
	}
	if _state.world_ready && _state.body_interface != nil && is_body_valid(rb.body) && !rb.frozen_by_time_scale {
		imp := impulse
		jolt.BodyInterface_AddImpulse(_state.body_interface, rb.body, &imp)
		rb.true_linear_vel = rb_get_velocity(rb)
	} else {
		rb.true_linear_vel += impulse
	}
}

_vs_poll_triggers :: proc(allocator: runtime.Allocator) -> []engine.Visual_Script_Trigger_Hit {
	sb := sensor_begin_events()
	cb := contact_begin_events()
	total := len(sb) + len(cb)
	if total == 0 do return nil

	out := make([dynamic]engine.Visual_Script_Trigger_Hit, 0, total * 2, allocator)
	for c in sb {
		if c.a != {} && c.b != {} {
			append(&out, engine.Visual_Script_Trigger_Hit{self_entity = c.a, other_entity = c.b})
			if c.a != c.b {
				append(&out, engine.Visual_Script_Trigger_Hit{self_entity = c.b, other_entity = c.a})
			}
		}
	}
	for c in cb {
		if c.a != {} && c.b != {} {
			append(&out, engine.Visual_Script_Trigger_Hit{self_entity = c.a, other_entity = c.b})
			if c.a != c.b {
				append(&out, engine.Visual_Script_Trigger_Hit{self_entity = c.b, other_entity = c.a})
			}
		}
	}
	return out[:]
}
