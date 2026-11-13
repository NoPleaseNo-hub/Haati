package physics3d

// SpringArm3D component: positions its first child transform (typically PlayerCam)
// along local -Z (or custom arm_direction) up to `spring_length`, pulling in when
// Channel 0 (Solid_World) geometry blocks the line of sight, while ignoring
// `ignore_owner` (e.g. the possessed HumanoidPawn / CamPawn).
//
// Uses pure delegate math-block swapping (`tick_math_block`) rather than mode
// enums or switch statements, and supports frame-budget trace amortization
// (`trace_every_n_frames`) for high-framerate rendering.

import "core:math"
import "core:math/linalg"
import "haati:engine"

SpringArm_Tick_Proc :: #type proc(arm: ^SpringArm3D, w: ^engine.World, dt: f32)

@(component={menu="Physics/SpringArm3D"})
@(typ_guid={guid = "7c8e9f1a-4b5d-4e6f-9a2c-3d4e5f6a7b8c"})
SpringArm3D :: struct {
	using base:           engine.CompData `inspect:"-"`,
	// Optional root Transform (and all its descendants) to ignore during traces (e.g. possessed pawn)
	ignore_owner:         engine.Ref,
	tick_math_block:      SpringArm_Tick_Proc `json:"-" inspect:"-"`,

	// 4-byte aligned f32 fields
	spring_length:        f32,
	probe_radius:         f32,
	shoulder_offset:      [3]f32,
	arm_direction_local:  [3]f32,
	smooth_recover_speed: f32,
	current_length:       f32                 `json:"-" inspect:"-"`,
	target_hit_length:    f32                 `json:"-" inspect:"-"`,

	// 1-byte packed tail (4 x 1-byte = 1 exact 32-bit word, zero padding!)
	collision_mask:       Collision_Mask, // Which collision channels (1..8) block this SpringArm3D (default = Channel 1)
	// 1 = trace every frame; >1 = amortize Jolt trace across N frames while interpolating every frame
	trace_every_n_frames: u8,
	frame_counter:        u8                  `json:"-" inspect:"-"`,
	in_play_mode:         bool                `json:"-" inspect:"-"`,
}

reset_SpringArm3D :: proc(arm: ^SpringArm3D) {
	engine.comp_zero(arm)
	arm.spring_length        = 2.5
	arm.probe_radius         = 0.2
	arm.arm_direction_local  = {0, 0, -1}
	arm.smooth_recover_speed = 18.0
	arm.collision_mask       = CHANNEL_SOLID_WORLD
	arm.trace_every_n_frames = 1
	arm.current_length       = 2.5
	arm.target_hit_length    = 1e9
	arm.in_play_mode         = false
	arm.tick_math_block      = spring_arm_active_trace_math
}

// Computes the local-space tip position of the SpringArm3D for a given arm length.
spring_arm_tip_local :: proc(arm: ^SpringArm3D, length: f32) -> [3]f32 {
	if arm == nil do return {}
	dir_local := linalg.normalize0(arm.arm_direction_local)
	if linalg.length2(dir_local) < 1e-6 do dir_local = {0, 0, -1}
	return arm.shoulder_offset + dir_local * max(length, 0.0)
}

// Returns the effective probe radius, taking the maximum of `arm.probe_radius`
// and any enabled `SphereCollider` attached to a direct child of the SpringArm3D.
spring_arm_effective_probe_radius :: proc(arm: ^SpringArm3D, w: ^engine.World) -> f32 {
	if arm == nil do return 0.0
	r := max(arm.probe_radius, 0.0)
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(arm.owner)) do return r
	t := engine.pool_get(&w.transforms, engine.Handle(arm.owner))
	if t == nil do return r
	curr_sc := t.scene if t.scene != nil else engine.sm_scene_get_active()
	for ch_ref in t.children {
		ch_h, ok := engine.scene_ref_resolve_transform(curr_sc, ch_ref, arm.owner)
		if !ok && engine.pool_valid(&w.transforms, ch_ref.handle) {
			ch_h = engine.Transform_Handle(ch_ref.handle)
			ok = true
		}
		if !ok do continue
		if _, sc_comp := get_comp(ch_h, SphereCollider); sc_comp != nil && sc_comp.enabled {
			r = max(r, sc_comp.radius)
		}
	}
	return r
}

// Positions all direct child transforms of `SpringArm3D` at the tip of the arm (`length`).
// Called every frame in both Edit Mode (using `spring_length`) and Play Mode (using `current_length`).
spring_arm_sync_children :: proc(arm: ^SpringArm3D, w: ^engine.World, length: f32) {
	if arm == nil || w == nil do return
	if !engine.pool_valid(&w.transforms, engine.Handle(arm.owner)) do return
	t := engine.pool_get(&w.transforms, engine.Handle(arm.owner))
	if t == nil || len(t.children) == 0 do return

	tip := spring_arm_tip_local(arm, length)
	curr_sc := t.scene if t.scene != nil else engine.sm_scene_get_active()
	for ch_ref in t.children {
		ch_h, ok := engine.scene_ref_resolve_transform(curr_sc, ch_ref, arm.owner)
		if !ok && engine.pool_valid(&w.transforms, ch_ref.handle) {
			ch_h = engine.Transform_Handle(ch_ref.handle)
			ok = true
		}
		if !ok do continue
		if child := engine.pool_get(&w.transforms, engine.Handle(ch_h)); child != nil {
			child.position = tip
		}
	}
}

// Sets the target length for smooth FPS-independent exponential decay (`1.0 - exp(-speed * dt)`).
// If transitioning down to 0.0 (Third-Person -> First-Person), `spring_arm_active_trace_math`
// smoothly decays `current_length` to 0.0 and then automatically hot-swaps to `spring_arm_collapsed_math`.
spring_arm_set_length :: proc(arm: ^SpringArm3D, new_length: f32) {
	if arm == nil do return
	arm.spring_length = max(new_length, 0.0)
	if arm.spring_length <= 0.001 && arm.current_length <= 0.001 {
		arm.target_hit_length = 1e9
		arm.current_length    = 0.0
		arm.tick_math_block   = spring_arm_collapsed_math
	} else {
		arm.tick_math_block = spring_arm_active_trace_math
	}
}

// Immediately snaps both target and current length without decay blending (used on initial scene start).
spring_arm_snap_length :: proc(arm: ^SpringArm3D, new_length: f32) {
	if arm == nil do return
	clamped := max(new_length, 0.0)
	arm.spring_length     = clamped
	arm.target_hit_length = 1e9
	arm.current_length    = clamped
	if clamped <= 0.001 {
		arm.tick_math_block = spring_arm_collapsed_math
	} else {
		arm.tick_math_block = spring_arm_active_trace_math
	}
}

// Math Block 1: Collapsed (First-Person / Zero-Length) — zero raycasts, pins children to shoulder_offset.
spring_arm_collapsed_math :: proc(arm: ^SpringArm3D, w: ^engine.World, dt: f32) {
	spring_arm_sync_children(arm, w, 0.0)
}

// Math Block 2: Active Channel-0 Solid Trace + FPS-Independent Exponential Decay (`1 - exp(-speed * dt)`).
spring_arm_active_trace_math :: proc(arm: ^SpringArm3D, w: ^engine.World, dt: f32) {
	t := engine.pool_get(&w.transforms, engine.Handle(arm.owner))
	if t == nil do return

	max_len := max(arm.spring_length, 0.0)

	// 1. FPS-independent exponential decay toward desired `spring_length` (smooth zoom IN and OUT, plus TP <-> FP)
	decay_rate  := max(arm.smooth_recover_speed, 1.0)
	decay_alpha := clamp(1.0 - math.exp(-decay_rate * max(dt, 0.0)), 0.0, 1.0)
	arm.current_length = linalg.lerp(arm.current_length, max_len, decay_alpha)
	if abs(arm.current_length - max_len) <= 0.001 {
		arm.current_length = max_len
	}

	// If decaying down to First-Person (0.0) and we've reached 0.0, lock into collapsed mode (0 raycasts)
	if max_len <= 0.001 && arm.current_length <= 0.001 {
		arm.current_length    = 0.0
		arm.target_hit_length = 1e9
		arm.tick_math_block   = spring_arm_collapsed_math
		spring_arm_sync_children(arm, w, 0.0)
		return
	}

	// 2. Raycast solid geometry across trace_len (at least current_length or max_len)
	trace_len := max(max_len, arm.current_length)
	cadence := max(arm.trace_every_n_frames, 1)
	arm.frame_counter += 1

	if arm.frame_counter >= cadence {
		arm.frame_counter = 0
		tw := engine.transform_world(arm.owner)
		world_q := _world_quat(tw.rotation)
		origin := tw.position + linalg.quaternion128_mul_vector3(world_q, arm.shoulder_offset)
		dir_local := linalg.normalize0(arm.arm_direction_local)
		if linalg.length2(dir_local) < 1e-6 do dir_local = {0, 0, -1}
		world_dir := linalg.normalize0(linalg.quaternion128_mul_vector3(world_q, dir_local))

		curr_sc := t.scene if t.scene != nil else engine.sm_scene_get_active()
		ignored_tH, ok := engine.scene_ref_resolve_transform(curr_sc, arm.ignore_owner, arm.owner)
		if !ok && engine.pool_valid(&w.transforms, arm.ignore_owner.handle) {
			ignored_tH = engine.Transform_Handle(arm.ignore_owner.handle)
		}
		probe_r := spring_arm_effective_probe_radius(arm, w)
		eff_mask := arm.collision_mask if arm.collision_mask != 0 else CHANNEL_SOLID_WORLD
		// Always ignore `arm.owner` (so child colliders on the SpringArm tip never self-hit) plus `ignored_tH`.
		if hit, hit_ok := raycast_masked(origin, world_dir, trace_len + probe_r, eff_mask, arm.owner, ignored_tH); hit_ok {
			arm.target_hit_length = max(hit.distance - probe_r, 0.0)
		} else {
			arm.target_hit_length = 1e9
		}
	}

	// 3. Snap in immediately ONLY when a physical wall hit (`target_hit_length`) is closer than `current_length`
	// so the camera never clips inside geometry, while user scroll zoom-in/out stays smoothly decay-lerped.
	if arm.target_hit_length < arm.current_length {
		arm.current_length = arm.target_hit_length
	}

	spring_arm_sync_children(arm, w, arm.current_length)
}

@(update={order=10})
spring_arm_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	it := engine.pool_iterator(spring_arm3_ds(w))
	for arm, _ in engine.pool_next(&it) {
		if !arm.enabled do continue
		arm.in_play_mode = true
		if arm.tick_math_block == nil {
			arm.tick_math_block = arm.spring_length <= 0.001 ? spring_arm_collapsed_math : spring_arm_active_trace_math
		}
		arm.tick_math_block(arm, w, dt)
	}
}
