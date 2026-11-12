package engine

// =============================================================================
// UNREAL-STYLE GLOBAL & HIERARCHICAL PER-OBJECT TIME DILATION (PLAN 4)
// =============================================================================
// Provides:
// 1. Three-Tier Clock:
//    - `unscaled_dt()` / `unscaled_dt_or(dt)`: Raw wall-clock frame delta for
//      Editor UI, QuickMenu, Console, and 6DOF `DebugCam` inspection.
//    - `time_scale()` / `set_time_scale(s)`: Global simulation time dilation
//      (`0.0` = frozen, `< 1.0` = slow-mo inspection, `1.0` = normal, `> 1.0` = fast-forward).
//    - `scaled_dt(raw_dt)` & `scaled_fixed_dt()`: Smooth 60Hz sub-stepped slow-mo
//      and multi-step fast-forward without 3 FPS accumulator stair-stepping.
// 2. Per-Object Hierarchical Custom Time Dilation (`Transform`):
//    - `transform_set_custom_time_scale(tH, s)` / `transform_get_custom_time_scale(tH)`
//    - `transform_hierarchy_time_scale(tH)`: O(1) version-cached product of
//      `custom_time_scale` down the parent->child `Transform` chain.
//    - `transform_dt(tH, dt)`: Effective delta time for any component on `tH`,
//      safe whether called inside `simulate.tick` / `app.main` or directly in unit tests.

import "core:math"

TIME_SCALE_MAX :: f32(20.0)

@(private = "file")
_Time_Dilation_State :: struct {
	global_override:     f32,
	has_global_override: bool,
	last_unscaled_dt:    f32,
	in_sim_update:       bool,
}

@(private = "file")
_time_dilation := _Time_Dilation_State{
	global_override  = 1.0,
	last_unscaled_dt = 1.0 / 60.0,
}

// Returns the active global time dilation multiplier (`0.0 .. TIME_SCALE_MAX`, default `1.0`).
time_scale :: #force_inline proc() -> f32 {
	if _time_dilation.has_global_override {
		return clamp(_time_dilation.global_override, 0.0, TIME_SCALE_MAX)
	}
	_ensure_time_settings()
	if time_settings.time_scale < 0.0 {
		return 1.0
	}
	return clamp(time_settings.time_scale, 0.0, TIME_SCALE_MAX)
}

// Sets the global time dilation multiplier (`0.0` = freeze-frame, `0.05` = 20x slow-mo, `1.0` = normal, `>1.0` = fast-forward).
set_time_scale :: proc(scale: f32) {
	clamped := clamp(scale, 0.0, TIME_SCALE_MAX)
	_time_dilation.global_override     = clamped
	_time_dilation.has_global_override = true
	_ensure_time_settings()
	time_settings.time_scale = clamped
}

// Resets the global time dilation multiplier back to `1.0`.
reset_time_scale :: proc() {
	_time_dilation.global_override     = 1.0
	_time_dilation.has_global_override = false
	_ensure_time_settings()
	time_settings.time_scale = 1.0
}

// Called at the start of a simulation frame (`simulate.tick` / `app.main`) to record the raw unscaled frame delta.
begin_frame_time :: #force_inline proc(raw_dt: f32) {
	if raw_dt > 0.0 {
		_time_dilation.last_unscaled_dt = raw_dt
	}
}

// Marks the scope of the generated `__update(scaled_dt)` pass so `transform_dt` knows
// `dt` already includes `time_scale()` (preventing double-scaling while keeping direct unit test calls scaled).
sim_update_begin :: #force_inline proc() {
	_time_dilation.in_sim_update = true
}

sim_update_end :: #force_inline proc() {
	_time_dilation.in_sim_update = false
}

sim_in_update :: #force_inline proc() -> bool {
	return _time_dilation.in_sim_update
}

// Raw unscaled frame delta time (for DebugCam, QuickMenu, Console, and UI).
unscaled_dt :: #force_inline proc() -> f32 {
	return _time_dilation.last_unscaled_dt > 0.0 ? _time_dilation.last_unscaled_dt : (1.0 / 60.0)
}

// Returns `unscaled_dt()` when inside a scaled simulation update, or `fallback_dt` when called directly.
unscaled_dt_or :: #force_inline proc(fallback_dt: f32) -> f32 {
	if _time_dilation.in_sim_update && _time_dilation.last_unscaled_dt > 0.0 {
		return _time_dilation.last_unscaled_dt
	}
	return fallback_dt
}

// Scales a raw frame delta by the global `time_scale()`.
scaled_dt :: #force_inline proc(raw_dt: f32) -> f32 {
	if raw_dt > 0.0 {
		_time_dilation.last_unscaled_dt = raw_dt
	}
	return max(raw_dt, 0.0) * time_scale()
}

// Effective step delta for `__fixed_update`:
// - When `0 < time_scale() < 1.0`: `fixed_frame_ticks` ticks at full 60Hz wall-clock cadence
//   and each tick steps by `fixed_dt() * time_scale()` so slow-mo is 60+ FPS smooth with zero stutter!
// - When `time_scale() >= 1.0`: `fixed_frame_ticks` runs multiple `fixed_dt()` ticks per frame
//   so fast-forward never tunnels through colliders.
scaled_fixed_dt :: #force_inline proc() -> f32 {
	g := time_scale()
	if g <= 0.0 do return 0.0
	if g < 1.0  do return fixed_dt() * g
	return fixed_dt()
}

// -----------------------------------------------------------------------------
// Per-Object / Hierarchical Transform Custom Time Dilation
// -----------------------------------------------------------------------------

transform_local_time_scale :: #force_inline proc(t: ^Transform) -> f32 {
	if t == nil || !t._has_custom_time_scale do return 1.0
	if t._custom_time_scale != t._custom_time_scale do return 1.0
	return clamp(t._custom_time_scale, 0.0, TIME_SCALE_MAX)
}

// Sets a custom per-object time dilation multiplier on `tH` (inherited by all child transforms!).
// Passing `0.0` freezes the object and its children in stasis; passing `1.0` restores normal relative speed.
transform_set_custom_time_scale :: proc(tH: Transform_Handle, scale: f32) {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	clamped := clamp(scale, 0.0, TIME_SCALE_MAX)
	t._custom_time_scale     = clamped
	t._has_custom_time_scale = true
}

// Clears any custom per-object time dilation override on `tH` (restoring it to `1.0`).
transform_reset_custom_time_scale :: proc(tH: Transform_Handle) {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	t._custom_time_scale     = 1.0
	t._has_custom_time_scale = false
}

// Returns the local custom time dilation multiplier authored/set directly on `tH` (default `1.0`).
transform_get_custom_time_scale :: proc(tH: Transform_Handle) -> f32 {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return 1.0
	t := pool_get(&w.transforms, Handle(tH))
	return transform_local_time_scale(t)
}

// Configures whether `tH` (and its descendants) ignore `global_time_scale` (e.g. for debug/UI entities).
transform_set_ignore_global_time_scale :: proc(tH: Transform_Handle, ignore: bool) {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	t._ignore_global_time_scale = ignore
}

transform_get_ignore_global_time_scale :: proc(tH: Transform_Handle) -> bool {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return false
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return false
	return t._ignore_global_time_scale
}

// Returns the hierarchical custom time scale for `tH` (product of `custom_time_scale` from root down to `tH`),
// evaluated and cached in O(1) alongside `_transform_world_with_ver`.
transform_hierarchy_time_scale :: proc(tH: Transform_Handle) -> f32 {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return 1.0
	_, _ = _transform_world_with_ver(w, tH)
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return 1.0
	return t._cached_world_time_scale
}

transform_ignores_global_in_hierarchy :: proc(tH: Transform_Handle) -> bool {
	w := ctx_world()
	if w == nil || tH == {} || !pool_valid(&w.transforms, Handle(tH)) do return false
	_, _ = _transform_world_with_ver(w, tH)
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return false
	return t._cached_ignore_global_ts
}

// Returns the total effective time scale (`global_time_scale * hierarchy_time_scale`) for `tH`.
transform_effective_time_scale :: proc(tH: Transform_Handle) -> f32 {
	h_scale := transform_hierarchy_time_scale(tH)
	if transform_ignores_global_in_hierarchy(tH) {
		return h_scale
	}
	return h_scale * time_scale()
}

// Returns the effective delta time `dt` for a component owned by `tH`:
// - Automatically multiplies by `transform_hierarchy_time_scale(tH)`.
// - Applies `time_scale()` if not already applied by the outer `simulate.tick` / `app.main` loop
//   (so direct unit test calls like `update_humanoid_pawns(1.0/60.0)` also respect `set_time_scale()`!).
transform_dt :: proc(tH: Transform_Handle, dt: f32) -> f32 {
	if dt <= 0.0 do return 0.0
	h_scale := transform_hierarchy_time_scale(tH)
	if transform_ignores_global_in_hierarchy(tH) {
		return unscaled_dt_or(dt) * h_scale
	}
	if _time_dilation.in_sim_update || fixed_in_tick() {
		return dt * h_scale
	}
	return dt * time_scale() * h_scale
}

// Helper for Smooth Exponential Blending of Time Dilation (used by TimeDilationVolume)
move_towards_time_scale :: #force_inline proc(current, target, max_delta: f32) -> f32 {
	if abs(target - current) <= max_delta do return target
	return current + math.copy_sign(max_delta, target - current)
}
