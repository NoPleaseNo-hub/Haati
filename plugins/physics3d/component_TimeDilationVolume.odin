package physics3d

// =============================================================================
// TIME DILATION VOLUME — LOCALIZED SLOW-MO & FAST-FORWARD FIELDS (PLAN 4)
// =============================================================================
// Unreal-style per-object time dilation trigger field for singleplayer and
// multiplayer gameplay:
// - When any Rigidbody, HumanoidPawn, CamPawn, or root entity overlaps the
//   volume (`on_overlap_start`), its hierarchical `Transform` custom time scale
//   is set to `target_time_scale` (e.g. `0.15x` slow-mo or `0.0x` stasis).
// - When the entity exits the volume (`on_overlap_end`), its `custom_time_scale`
//   is restored to `1.0x` (or combined with any other overlapping volumes).
// - Supports both Jolt `sensor_begin_events` / `sensor_end_events` (when a
//   Trigger Collider is attached) AND analytic 3D OBB / Sphere / Capsule
//   containment (so character pawns without a Jolt Rigidbody or objects spawned
//   inside the field on frame 0 are also dilated immediately).

import "base:runtime"
import "core:math/linalg"
import "moonhug:engine"

Time_Dilation_Combine_Mode :: enum u8 {
	Multiply    = 0, // Unreal-style layered product (e.g. 0.5x * 0.2x = 0.10x)
	Min_Slowest = 1, // Strongest slow-mo wins (min of overlapping volumes)
	Override    = 2, // Latest / highest-priority volume overrides
}

Time_Dilation_Shape_Mode :: enum u8 {
	Box_Or_Collider = 0, // Uses attached Box/Sphere/CapsuleCollider if present, else `box_size`
	Sphere_Radius   = 1, // Uses `sphere_radius` around volume center
}

@(component={menu="Physics/TimeDilationVolume"})
@(typ_guid={guid = "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70"})
TimeDilationVolume :: struct {
	using base:             engine.CompData `inspect:"-"`,

	// Target custom time dilation applied to overlapping objects (0.0 = stasis, 0.15 = slow-mo, 1.0 = normal, 2.0 = haste)
	target_time_scale:      f32 `decor:range(0, 10)`,

	// Optional smooth ramp-in / ramp-out transition durations in unscaled seconds (0.0 = instant on overlap start/end)
	blend_in_duration:      f32 `decor:min(0)`,
	blend_out_duration:     f32 `decor:min(0)`,

	// Fallback volume dimensions when no BoxCollider / SphereCollider / CapsuleCollider is attached to the same Transform
	box_size:               [3]f32,
	center_offset:          [3]f32,
	sphere_radius:          f32 `decor:min(0.05)`,

	// Filter & combine configuration
	combine_mode:           Time_Dilation_Combine_Mode,
	shape_mode:             Time_Dilation_Shape_Mode,
	affect_rigidbodies:     bool,
	affect_pawns:           bool,
	apply_to_self_hierarchy:bool,

	// Runtime tracking of entities currently overlapping via Jolt Sensor events
	sensor_visitors:        [dynamic]engine.Transform_Handle `json:"-" inspect:"-"`,
	active_visitors:        [dynamic]engine.Transform_Handle `json:"-" inspect:"-"`,
}

@(private = "file")
_Dilated_Entity_Entry :: struct {
	current_scale: f32,
	target_scale:  f32,
	blend_in_dur:  f32,
	blend_out_dur: f32,
	is_inside:     bool,
}

@(private = "file")
_dilation_tracker: struct {
	world:    ^engine.World,
	world_id: u64,
	entities: map[engine.Transform_Handle]_Dilated_Entity_Entry,
}

reset_TimeDilationVolume :: proc(vol: ^TimeDilationVolume) {
	cleanup_TimeDilationVolume(vol)
	vol.target_time_scale       = 0.15
	vol.blend_in_duration       = 0.0
	vol.blend_out_duration      = 0.0
	vol.box_size                = {5.0, 4.0, 5.0}
	vol.center_offset           = {0.0, 0.0, 0.0}
	vol.sphere_radius           = 3.0
	vol.combine_mode            = .Multiply
	vol.shape_mode              = .Box_Or_Collider
	vol.affect_rigidbodies      = true
	vol.affect_pawns            = true
	vol.apply_to_self_hierarchy = false
}

cleanup_TimeDilationVolume :: proc(vol: ^TimeDilationVolume) {
	if vol == nil do return
	if _dilation_tracker.world != nil {
		for vis in vol.active_visitors {
			if engine.pool_valid(&_dilation_tracker.world.transforms, engine.Handle(vis)) {
				engine.transform_reset_custom_time_scale(vis)
			}
			delete_key(&_dilation_tracker.entities, vis)
		}
		if vol.apply_to_self_hierarchy && vol.owner != {} && engine.pool_valid(&_dilation_tracker.world.transforms, engine.Handle(vol.owner)) {
			engine.transform_reset_custom_time_scale(vol.owner)
		}
	}
	delete(vol.sensor_visitors)
	delete(vol.active_visitors)
	engine.comp_zero(vol)
}

on_destroy_TimeDilationVolume :: proc(vol: ^TimeDilationVolume) {
	cleanup_TimeDilationVolume(vol)
}

time_dilation_volumes_shutdown :: proc() {
	delete(_dilation_tracker.entities)
	_dilation_tracker.entities = nil
	_dilation_tracker.world    = nil
	_dilation_tracker.world_id = 0
}

// Resolves the logical root entity to dilate when `candidate` overlaps a `TimeDilationVolume`:
// - If `candidate` is or has a `Rigidbody` ancestor, returns that `Rigidbody` owner.
// - Otherwise, climbs up to the top-most non-scene-root entity so child colliders
//   dilate the entire character/pawn hierarchy (`HumanoidRoot`, `CamRoot`, etc.).
@(private = "file")
_is_transform_or_descendant :: proc(w: ^engine.World, candidate, ancestor: engine.Transform_Handle) -> bool {
	if w == nil || candidate == {} || ancestor == {} do return false
	if candidate == ancestor do return true
	cur := candidate
	for step := 0; step < 32 && engine.pool_valid(&w.transforms, engine.Handle(cur)); step += 1 {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		parent_h := t.parent.handle
		if parent_h == {} || !engine.pool_valid(&w.transforms, parent_h) do break
		p_tH := engine.Transform_Handle(parent_h)
		p_tH.type_key = .Transform
		if p_tH == ancestor do return true
		cur = p_tH
	}
	return false
}

@(private = "file")
_resolve_dilatable_entity_root :: proc(w: ^engine.World, candidate: engine.Transform_Handle) -> engine.Transform_Handle {
	if w == nil || candidate == {} || !engine.pool_valid(&w.transforms, engine.Handle(candidate)) do return {}
	if rb_owner, is_rb := _ancestor_body_owner(w, candidate); is_rb {
		return rb_owner
	}
	cur := candidate
	for step := 0; step < 32 && engine.pool_valid(&w.transforms, engine.Handle(cur)); step += 1 {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		parent_h := t.parent.handle
		if parent_h == {} || !engine.pool_valid(&w.transforms, parent_h) do break
		if t.scene != nil && t.scene.root.handle == parent_h do break
		cur = engine.Transform_Handle(parent_h)
	}
	return cur
}

// Tests whether `world_pt` lies inside the 3D volume of `vol` (checking attached
// BoxCollider, SphereCollider, CapsuleCollider first, or `vol.box_size` / `vol.sphere_radius`).
time_dilation_volume_contains_point :: proc(w: ^engine.World, vol: ^TimeDilationVolume, world_pt: [3]f32) -> bool {
	if w == nil || vol == nil || vol.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(vol.owner)) {
		return false
	}
	t := engine.pool_get(&w.transforms, engine.Handle(vol.owner))
	if t == nil || !t.is_active do return false

	tw := engine.transform_world(vol.owner)
	s  := [3]f32{max(abs(tw.scale.x), 1e-4), max(abs(tw.scale.y), 1e-4), max(abs(tw.scale.z), 1e-4)}
	inv_q := linalg.quaternion_inverse(_world_quat(tw.rotation))
	local_pt := linalg.quaternion128_mul_vector3(inv_q, world_pt - tw.position)

	if vol.shape_mode == .Sphere_Radius {
		center := vol.center_offset * s
		r := max(vol.sphere_radius * max(s.x, max(s.y, s.z)), 0.01)
		return linalg.length2(local_pt - center) <= r * r
	}

	// 1. Check attached BoxCollider
	if owned, idx := engine.transform_find_comp(t, .BoxCollider); idx >= 0 {
		if pool := box_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled {
				size, center := box_scaled(c, s)
				half := size * 0.5
				p_rel := local_pt - center
				if c.rotation != {} && c.rotation != {0, 0, 0, 1} {
					p_rel = linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(_world_quat(c.rotation)), p_rel)
				}
				return abs(p_rel.x) <= half.x && abs(p_rel.y) <= half.y && abs(p_rel.z) <= half.z
			}
		}
	}

	// 2. Check attached SphereCollider
	if owned, idx := engine.transform_find_comp(t, .SphereCollider); idx >= 0 {
		if pool := sphere_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled {
				radius, center := sphere_scaled(c, s)
				return linalg.length2(local_pt - center) <= radius * radius
			}
		}
	}

	// 3. Check attached CapsuleCollider
	if owned, idx := engine.transform_find_comp(t, .CapsuleCollider); idx >= 0 {
		if pool := capsule_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled {
				radius, height, center := capsule_scaled(c, s)
				half_seg := max(height * 0.5 - radius, 0.0)
				p_rel := local_pt - center
				axis_coord: f32
				switch c.direction {
				case .X_Axis: axis_coord = clamp(p_rel.x, -half_seg, half_seg); p_rel.x -= axis_coord
				case .Y_Axis: axis_coord = clamp(p_rel.y, -half_seg, half_seg); p_rel.y -= axis_coord
				case .Z_Axis: axis_coord = clamp(p_rel.z, -half_seg, half_seg); p_rel.z -= axis_coord
				}
				return linalg.length2(p_rel) <= radius * radius
			}
		}
	}

	// 4. Fallback to `vol.box_size` and `vol.center_offset`
	bsize := [3]f32{
		max(vol.box_size.x, 0.01) * s.x,
		max(vol.box_size.y, 0.01) * s.y,
		max(vol.box_size.z, 0.01) * s.z,
	}
	bhalf   := bsize * 0.5
	bcenter := vol.center_offset * s
	diff    := local_pt - bcenter
	return abs(diff.x) <= bhalf.x && abs(diff.y) <= bhalf.y && abs(diff.z) <= bhalf.z
}

@(private = "file")
_contains_handle :: #force_inline proc(list: []engine.Transform_Handle, h: engine.Transform_Handle) -> bool {
	for item in list {
		if item == h do return true
	}
	return false
}

@(private = "file")
_remove_handle :: proc(list: ^[dynamic]engine.Transform_Handle, h: engine.Transform_Handle) {
	if list == nil do return
	for i := len(list^) - 1; i >= 0; i -= 1 {
		if list^[i] == h {
			unordered_remove(list, i)
		}
	}
}

// Ensures any collider on a `TimeDilationVolume` transform (without its own Rigidbody)
// is marked `is_trigger = true` and `channel = .Trigger_Sensor` so Jolt emits sensor overlap events
// instead of physically blocking players and projectiles at the slow-mo boundary!
@(private = "file")
_ensure_volume_colliders_are_triggers :: proc(w: ^engine.World, vol: ^TimeDilationVolume) {
	if w == nil || vol == nil || vol.owner == {} do return
	t := engine.pool_get(&w.transforms, engine.Handle(vol.owner))
	if t == nil do return
	if _, rb_idx := engine.transform_find_comp(t, .Rigidbody); rb_idx >= 0 do return

	if owned, idx := engine.transform_find_comp(t, .BoxCollider); idx >= 0 {
		if pool := box_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil && !c.is_trigger {
				c.is_trigger = true
				c.channel    = .Trigger_Sensor
				_destroy_shape(&c.shape, &c.static_body)
			}
		}
	}
	if owned, idx := engine.transform_find_comp(t, .SphereCollider); idx >= 0 {
		if pool := sphere_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil && !c.is_trigger {
				c.is_trigger = true
				c.channel    = .Trigger_Sensor
				_destroy_shape(&c.shape, &c.static_body)
			}
		}
	}
	if owned, idx := engine.transform_find_comp(t, .CapsuleCollider); idx >= 0 {
		if pool := capsule_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil && !c.is_trigger {
				c.is_trigger = true
				c.channel    = .Trigger_Sensor
				_destroy_shape(&c.shape, &c.static_body)
			}
		}
	}
}

// Evaluates all `TimeDilationVolume` components, processes Jolt sensor begin/end overlap events
// plus analytic 3D volume containment, and updates `custom_time_scale` on overlapping entities.
time_dilation_volumes_step :: proc(w: ^engine.World, raw_dt: f32) {
	context.allocator = runtime.default_allocator()
	if w == nil do return
	vol_pool := time_dilation_volumes(w)
	if vol_pool == nil do return

	if _dilation_tracker.world != w || _dilation_tracker.world_id != w.id {
		delete(_dilation_tracker.entities)
		_dilation_tracker.entities = make(map[engine.Transform_Handle]_Dilated_Entity_Entry)
		_dilation_tracker.world    = w
		_dilation_tracker.world_id = w.id
	} else if _dilation_tracker.entities == nil {
		_dilation_tracker.entities = make(map[engine.Transform_Handle]_Dilated_Entity_Entry)
	}

	// 1. Pre-pass: ensure volume colliders are triggers and consume Jolt sensor_begin / sensor_end events
	s_begin := sensor_begin_events()
	s_end   := sensor_end_events()

	any_enabled_vol := false
	it_v := engine.pool_iterator(vol_pool)
	for vol, _ in engine.pool_next(&it_v) {
		if !vol.enabled || vol.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(vol.owner)) || !engine.transform_active_in_hierarchy(vol.owner) {
			if len(vol.active_visitors) > 0 {
				clear(&vol.active_visitors)
				clear(&vol.sensor_visitors)
			}
			continue
		}
		any_enabled_vol = true
		_ensure_volume_colliders_are_triggers(w, vol)

		if vol.apply_to_self_hierarchy {
			engine.transform_set_custom_time_scale(vol.owner, vol.target_time_scale)
		}

		// Process Jolt sensor begin events where `a` or `b` belongs to `vol.owner`
		for ev in s_begin {
			visitor: engine.Transform_Handle = {}
			if _is_transform_or_descendant(w, ev.a, vol.owner) && !_is_transform_or_descendant(w, ev.b, vol.owner) {
				visitor = _resolve_dilatable_entity_root(w, ev.b)
			} else if _is_transform_or_descendant(w, ev.b, vol.owner) && !_is_transform_or_descendant(w, ev.a, vol.owner) {
				visitor = _resolve_dilatable_entity_root(w, ev.a)
			}
			if visitor != {} && visitor != vol.owner && !_contains_handle(vol.sensor_visitors[:], visitor) {
				append(&vol.sensor_visitors, visitor)
			}
		}

		// Process Jolt sensor end events
		for ev in s_end {
			visitor: engine.Transform_Handle = {}
			if _is_transform_or_descendant(w, ev.a, vol.owner) && !_is_transform_or_descendant(w, ev.b, vol.owner) {
				visitor = _resolve_dilatable_entity_root(w, ev.b)
			} else if _is_transform_or_descendant(w, ev.b, vol.owner) && !_is_transform_or_descendant(w, ev.a, vol.owner) {
				visitor = _resolve_dilatable_entity_root(w, ev.a)
			}
			if visitor != {} {
				_remove_handle(&vol.sensor_visitors, visitor)
			}
		}
	}

	if !any_enabled_vol && len(_dilation_tracker.entities) == 0 do return

	// Mark all tracked entities as not-inside before gathering current overlaps
	for _, &entry in _dilation_tracker.entities {
		entry.is_inside    = false
		entry.target_scale = 1.0
	}

	// Collect candidate roots in `w` (Rigidbodies + top-level scene entities / pawns)
	candidates := make([dynamic]engine.Transform_Handle, 0, 64, context.temp_allocator)
	is_rb_map  := make(map[engine.Transform_Handle]bool, context.temp_allocator)

	if rb_pool := rigidbodies(w); rb_pool != nil {
		it_rb := engine.pool_iterator(rb_pool)
		for rb, _ in engine.pool_next(&it_rb) {
			if !rb.enabled || rb.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue
			if !engine.transform_active_in_hierarchy(rb.owner) do continue
			is_rb_map[rb.owner] = true
			if !_contains_handle(candidates[:], rb.owner) {
				append(&candidates, rb.owner)
			}
		}
	}

	it_t := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it_t) {
		if !t.is_active || t.destroy do continue
		tH := engine.Transform_Handle(h)
		tH.type_key = .Transform
		// Skip scene roots themselves; include top-level children of scene root or root-level entities
		if t.scene != nil && t.scene.root.handle == engine.Handle(tH) do continue
		is_top_entity := (t.parent.handle == {}) || (t.scene != nil && t.scene.root.handle == t.parent.handle)
		if is_top_entity && len(t.components) > 0 {
			if !_contains_handle(candidates[:], tH) {
				append(&candidates, tH)
			}
		}
	}

	// 2. Evaluate overlap for each enabled `TimeDilationVolume`
	it_v2 := engine.pool_iterator(vol_pool)
	for vol, _ in engine.pool_next(&it_v2) {
		if !vol.enabled || vol.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(vol.owner)) || !engine.transform_active_in_hierarchy(vol.owner) {
			continue
		}
		clear(&vol.active_visitors)

		for cand in candidates {
			if cand == vol.owner || _is_transform_or_descendant(w, cand, vol.owner) do continue
			cand_is_rb := is_rb_map[cand]
			if cand_is_rb && !vol.affect_rigidbodies do continue
			if !cand_is_rb && !vol.affect_pawns do continue

			// Check Jolt sensor overlap OR analytic 3D containment
			overlapping := _contains_handle(vol.sensor_visitors[:], cand)
			if !overlapping {
				cw := engine.transform_world(cand)
				overlapping = time_dilation_volume_contains_point(w, vol, cw.position)
			}

			if overlapping {
				append(&vol.active_visitors, cand)
				entry, exists := _dilation_tracker.entities[cand]
				if !exists {
					entry = _Dilated_Entity_Entry{
						current_scale = engine.transform_get_custom_time_scale(cand),
						target_scale  = 1.0,
						is_inside     = false,
					}
				}
				if !entry.is_inside {
					entry.is_inside     = true
					entry.target_scale  = clamp(vol.target_time_scale, 0.0, engine.TIME_SCALE_MAX)
					entry.blend_in_dur  = max(vol.blend_in_duration, 0.0)
					entry.blend_out_dur = max(vol.blend_out_duration, 0.0)
				} else {
					v_scale := clamp(vol.target_time_scale, 0.0, engine.TIME_SCALE_MAX)
					switch vol.combine_mode {
					case .Multiply:
						entry.target_scale = clamp(entry.target_scale * v_scale, 0.0, engine.TIME_SCALE_MAX)
					case .Min_Slowest:
						entry.target_scale = min(entry.target_scale, v_scale)
					case .Override:
						entry.target_scale = v_scale
					}
					entry.blend_in_dur  = max(entry.blend_in_dur, vol.blend_in_duration)
					entry.blend_out_dur = max(entry.blend_out_dur, vol.blend_out_duration)
				}
				_dilation_tracker.entities[cand] = entry
			}
		}
	}

	// 3. Apply target_scale (or blend back to 1.0 on overlap end) for all tracked entities
	dt_unscaled := engine.unscaled_dt_or(raw_dt)
	to_remove := make([dynamic]engine.Transform_Handle, 0, 16, context.temp_allocator)

	for ent_h, &entry in _dilation_tracker.entities {
		if !engine.pool_valid(&w.transforms, engine.Handle(ent_h)) {
			append(&to_remove, ent_h)
			continue
		}
		if entry.is_inside {
			if entry.blend_in_dur <= 1e-4 || dt_unscaled <= 0.0 {
				entry.current_scale = entry.target_scale
			} else {
				rate := max(abs(1.0 - entry.target_scale), 0.1) / entry.blend_in_dur
				entry.current_scale = engine.move_towards_time_scale(entry.current_scale, entry.target_scale, rate * dt_unscaled)
			}
			engine.transform_set_custom_time_scale(ent_h, entry.current_scale)
		} else {
			// Overlap ended: restore to 1.0 (instant if blend_out_dur == 0, else smooth ramp)
			if entry.blend_out_dur <= 1e-4 || dt_unscaled <= 0.0 {
				engine.transform_reset_custom_time_scale(ent_h)
				append(&to_remove, ent_h)
			} else {
				rate := max(abs(1.0 - entry.current_scale), 0.1) / entry.blend_out_dur
				entry.current_scale = engine.move_towards_time_scale(entry.current_scale, 1.0, rate * dt_unscaled)
				if abs(entry.current_scale - 1.0) <= 1e-3 {
					engine.transform_reset_custom_time_scale(ent_h)
					append(&to_remove, ent_h)
				} else {
					engine.transform_set_custom_time_scale(ent_h, entry.current_scale)
				}
			}
		}
	}

	for rem_h in to_remove {
		delete_key(&_dilation_tracker.entities, rem_h)
	}
}

@(update={order=-5})
time_dilation_volumes_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	time_dilation_volumes_step(w, dt)
}
