package physics3d

// 3D physics on Jolt Physics (JoltC) with Unity-literal authoring — the 3D sibling
// of packages/physics2d, same architecture (docs/Plugins.md):
//
// - Components are plain data; this fixed step syncs them to Jolt. The
//   editor never simulates — bodies exist only while the app runs.
// - Units: 1 world unit = 1 meter.
// - A collider without a Rigidbody anywhere above it is STATIC (implicit
//   static body). A collider below a Rigidbody attaches to that body as a
//   shape with its relative transform baked at creation (compound bodies).
// - Contacts are POLLED, not called back: the step buffers Jolt's begin/end
//   contact + sensor events; read them from a @(fixed_update) subscriber
//   ordered AFTER this step (order > 1000), or next tick at any order.
// - Escape hatch: body_of(tH) returns the live jolt.BodyID — use body_interface()
//   directly for forces, joints, mass overrides, raycasts, runtime mutation.
//
// Transform scale affects shapes (Unity semantics — see collider_scale). The
// whole relative transform, scale included, is BAKED at shape creation:
// moving or rescaling a child collider afterwards doesn't re-bake, and
// component field edits at runtime don't re-sync (use the escape hatch).

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:sync"
import jolt "haati:external/jolt"
import "haati:engine"

GRAVITY_DEFAULT :: [3]f32{0, -9.81, 0}
_COLLISION_STEPS :: 1

// -----------------------------------------------------------------------------
// 6-Channel Jolt ObjectLayer & Raycast Trace Architecture
// -----------------------------------------------------------------------------
// 0: LAYER_NON_MOVING         — Solid static world (CSG chunks, floors, static walls)
// 1: LAYER_MOVING             — Dynamic rigidbodies, physics props, severed CSG islands
// 2: LAYER_CHARACTER          — Player & NPC character capsules / hitboxes
// 3: LAYER_GLASS_FENESTRATION — Shatterable 2D glass windows & grates (blocks movement,
//                               transparent to AI Vision/LOS, hit & shattered by Weapon Traces!)
// 4: LAYER_TRIGGER_SENSOR     — Trigger volumes & sensors (overlap-only, ignored by traces)
// 5: LAYER_DEBRIS_COSMETIC    — Rock rubble, popped Gothic trim & glass shards (collides ONLY
//                               with LAYER_NON_MOVING so debris never trips players or chokes CPU!)
LAYER_NON_MOVING         : jolt.ObjectLayer : 0
LAYER_MOVING             : jolt.ObjectLayer : 1
LAYER_CHARACTER          : jolt.ObjectLayer : 2
LAYER_GLASS_FENESTRATION : jolt.ObjectLayer : 3
LAYER_TRIGGER_SENSOR     : jolt.ObjectLayer : 4
LAYER_DEBRIS_COSMETIC    : jolt.ObjectLayer : 5
NUM_LAYERS               :: 6

BROAD_LAYER_NON_MOVING : jolt.BroadPhaseLayer : 0
BROAD_LAYER_MOVING     : jolt.BroadPhaseLayer : 1
NUM_BROAD_LAYERS       :: 2

Collision_Channel :: enum u8 {
	Solid_World        = 0,
	Dynamic_Body       = 1,
	Character          = 2,
	Glass_Fenestration = 3,
	Trigger_Sensor     = 4,
	Debris_Cosmetic    = 5,
}

Collision_Mask :: distinct u32

CHANNEL_SOLID_WORLD        :: Collision_Mask(1 << 0)
CHANNEL_DYNAMIC_BODY       :: Collision_Mask(1 << 1)
CHANNEL_CHARACTER          :: Collision_Mask(1 << 2)
CHANNEL_GLASS_FENESTRATION :: Collision_Mask(1 << 3)
CHANNEL_TRIGGER_SENSOR     :: Collision_Mask(1 << 4)
CHANNEL_DEBRIS_COSMETIC    :: Collision_Mask(1 << 5)

MASK_ALL            :: Collision_Mask(0x3F)
// Physical movement / character sweep: blocked by Solid World, Dynamic Props, Characters, and Unbroken Glass
MASK_SOLID_MOVEMENT :: CHANNEL_SOLID_WORLD | CHANNEL_DYNAMIC_BODY | CHANNEL_CHARACTER | CHANNEL_GLASS_FENESTRATION
// AI Vision / Line-of-Sight: sees right through Glass/Fenestration, Triggers, and Cosmetic Debris!
MASK_VISION_LOS     :: CHANNEL_SOLID_WORLD | CHANNEL_DYNAMIC_BODY
// Weapon / Ballistic / Geo-Mod Trace: hits Solid World, Dynamic Bodies, Characters, and Glass (to shatter it!), ignores Triggers & Debris
MASK_WEAPON_TRACE   :: CHANNEL_SOLID_WORLD | CHANNEL_DYNAMIC_BODY | CHANNEL_CHARACTER | CHANNEL_GLASS_FENESTRATION
// 3rd-Person Camera Spring-Arm: only blocked by Solid World so glass windows & small rubble never pop the camera
MASK_CAMERA_BOOM    :: CHANNEL_SOLID_WORLD

Raycast_Hit :: struct {
	body_id:    jolt.BodyID,
	owner:      engine.Transform_Handle,
	layer:      jolt.ObjectLayer,
	channel:    Collision_Channel,
	position:   [3]f32,
	normal:     [3]f32,
	distance:   f32,
	fraction:   f32,
	sub_shape:  jolt.SubShapeID,
}

Contact :: struct {
	a, b: engine.Transform_Handle, // sensor events: a = sensor, b = visitor
}

@(private = "file")
_contact_procs := jolt.ContactListener_Procs{
	OnContactValidate  = _on_contact_validate,
	OnContactAdded     = _on_contact_added,
	OnContactPersisted = _on_contact_persisted,
	OnContactRemoved   = _on_contact_removed,
}

_jolt_trace :: proc "c" (message: cstring) {
	context = runtime.default_context()
	fmt.eprintln("[JOLT TRACE]", message)
}

_jolt_assert_failed :: proc "c" (expression: cstring, message: cstring, file: cstring, line: u32) -> bool {
	context = runtime.default_context()
	fmt.eprintf("[JOLT ASSERT] %s:%d: (%s) %s\n", file, line, expression, message)
	return false
}

_state: struct {
	system:                 ^jolt.PhysicsSystem,
	body_interface:         ^jolt.BodyInterface,
	body_interface_no_lock: ^jolt.BodyInterface,
	job_system:             ^jolt.JobSystem,
	bp_interface:           ^jolt.BroadPhaseLayerInterface,
	obj_pair_filter:        ^jolt.ObjectLayerPairFilter,
	obj_vs_bp_filter:       ^jolt.ObjectVsBroadPhaseLayerFilter,
	contact_listener:       ^jolt.ContactListener,
	occlusion_bp_filter:    ^jolt.BroadPhaseLayerFilter,
	occlusion_layer_filter: ^jolt.ObjectLayerFilter,
	world_ready:      bool,
	current_world:    ^engine.World,
	current_world_id: u64,
	current_rb_pool:  rawptr,
	gravity:          [3]f32,
	shape_owner:      map[uintptr]engine.Transform_Handle,
	contact_begin:    [dynamic]Contact,
	contact_end:      [dynamic]Contact,
	sensor_begin:     [dynamic]Contact,
	sensor_end:       [dynamic]Contact,
	event_mutex:      sync.Mutex,
}

// --- Public API ---------------------------------------------------------------

set_gravity :: proc(g: [3]f32) {
	_state.gravity = g
	if _state.world_ready && _state.system != nil {
		grav := _state.gravity
		jolt.PhysicsSystem_SetGravity(_state.system, &grav)
	}
}

physics_system :: proc() -> ^jolt.PhysicsSystem {
	_ensure_world(engine.ctx_world())
	return _state.system
}

body_interface :: proc() -> ^jolt.BodyInterface {
	_ensure_world(engine.ctx_world())
	return _state.body_interface
}

// Backward-compatible escape hatch
world :: proc() -> ^jolt.PhysicsSystem {
	return physics_system()
}

is_body_valid :: proc(id: jolt.BodyID) -> bool {
	return id != 0 && id != max(u32)
}

// The live body for a transform carrying a Rigidbody ({}, false before the
// first step or without the component).
body_of :: proc(tH: engine.Transform_Handle) -> (jolt.BodyID, bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return 0, false
	owned, idx := engine.transform_find_comp(t, .Rigidbody)
	if idx < 0 do return 0, false
	pool := rigidbodies(w)
	if pool == nil do return 0, false
	rb := engine.pool_get(pool, owned.handle)
	if rb == nil || !is_body_valid(rb.body) do return 0, false
	return rb.body, true
}

// Events from the LAST physics step, valid until the next one.
contact_begin_events :: proc() -> []Contact { return _state.contact_begin[:] }
contact_end_events   :: proc() -> []Contact { return _state.contact_end[:] }
sensor_begin_events  :: proc() -> []Contact { return _state.sensor_begin[:] }
sensor_end_events    :: proc() -> []Contact { return _state.sensor_end[:] }

// Returns the Collision_Mask bit for a Jolt ObjectLayer (0..5).
layer_to_channel_mask :: #force_inline proc(layer: jolt.ObjectLayer) -> Collision_Mask {
	if layer >= NUM_LAYERS do return 0
	return Collision_Mask(u32(1) << u32(layer))
}

// Queries whether two Jolt ObjectLayers are configured to collide in the active 6-channel matrix.
should_layers_collide :: proc(layer1, layer2: jolt.ObjectLayer) -> bool {
	_ensure_world(engine.ctx_world())
	if !_state.world_ready || _state.obj_pair_filter == nil do return false
	return jolt.ObjectLayerPairFilterTable_ShouldCollide(_state.obj_pair_filter, layer1, layer2)
}

_AUDIO_OCCLUSION_FILTER_TAG :: uintptr(0x10000001)

@(private = "file")
_ray_layer_filter_should_collide :: proc "c" (userData: rawptr, layer: jolt.ObjectLayer) -> bool {
	if layer >= NUM_LAYERS do return false
	if uintptr(userData) == _AUDIO_OCCLUSION_FILTER_TAG {
		return layer == LAYER_NON_MOVING
	}
	mask := u32(uintptr(userData))
	if mask == 0 do return false
	if layer == LAYER_TRIGGER_SENSOR {
		return (mask & (u32(1) << u32(LAYER_TRIGGER_SENSOR))) != 0
	}
	return true
}

@(private = "file")
_ray_layer_filter_procs := jolt.ObjectLayerFilter_Procs{
	ShouldCollide = _ray_layer_filter_should_collide,
}

@(private = "file")
_ray_bp_solid_only_should_collide :: proc "c" (userData: rawptr, layer: jolt.BroadPhaseLayer) -> bool {
	return layer == BROAD_LAYER_NON_MOVING
}

@(private = "file")
_ray_bp_solid_only_procs := jolt.BroadPhaseLayerFilter_Procs{
	ShouldCollide = _ray_bp_solid_only_should_collide,
}

@(private = "file")
_Ray_Body_Ignore_Ctx :: struct {
	world:         ^engine.World,
	ignore_owner:  engine.Transform_Handle,
	ignore_owner2: engine.Transform_Handle,
	query_mask:    Collision_Mask,
}

@(private = "file")
_owner_effective_masks :: proc(w: ^engine.World, owner: engine.Transform_Handle) -> (blocks, mask: Collision_Mask, has_collider: bool) {
	if w == nil || owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner)) do return 0, 0, false
	t := engine.pool_get(&w.transforms, engine.Handle(owner))
	if t == nil do return 0, 0, false

	if owned, _ := engine.transform_find_comp(t, .BoxCollider); owned.handle.type_key == .BoxCollider {
		if pool := box_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil {
				if c.blocks_channels == 0 && c.collision_mask == 0 {
					return (c.is_trigger ? 0 : Collision_Mask(1 << u32(c.channel))), Collision_Mask(0xFF), true
				}
				return c.blocks_channels, c.collision_mask, true
			}
		}
	}
	if owned, _ := engine.transform_find_comp(t, .SphereCollider); owned.handle.type_key == .SphereCollider {
		if pool := sphere_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil {
				if c.blocks_channels == 0 && c.collision_mask == 0 {
					return (c.is_trigger ? 0 : Collision_Mask(1 << u32(c.channel))), Collision_Mask(0xFF), true
				}
				return c.blocks_channels, c.collision_mask, true
			}
		}
	}
	if owned, _ := engine.transform_find_comp(t, .CapsuleCollider); owned.handle.type_key == .CapsuleCollider {
		if pool := capsule_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil {
				if c.blocks_channels == 0 && c.collision_mask == 0 {
					return (c.is_trigger ? 0 : Collision_Mask(1 << u32(c.channel))), Collision_Mask(0xFF), true
				}
				return c.blocks_channels, c.collision_mask, true
			}
		}
	}
	if owned, _ := engine.transform_find_comp(t, .MeshCollider); owned.handle.type_key == .MeshCollider {
		if pool := mesh_colliders(w); pool != nil {
			if c := engine.pool_get(pool, owned.handle); c != nil {
				if c.blocks_channels == 0 && c.collision_mask == 0 {
					return (c.is_trigger ? 0 : Collision_Mask(1 << u32(c.channel))), Collision_Mask(0xFF), true
				}
				return c.blocks_channels, c.collision_mask, true
			}
		}
	}
	return 0, 0, false
}

@(private = "file")
_is_transform_or_descendant_raw :: proc(w: ^engine.World, candidate, ancestor: engine.Transform_Handle) -> bool {
	if w == nil || candidate == {} || ancestor == {} do return false
	cur := candidate
	for step := 0; step < 32 && engine.pool_valid(&w.transforms, engine.Handle(cur)); step += 1 {
		if cur == ancestor do return true
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		next_h := t.parent.handle
		if next_h == {} && t.parent.pptr.local_id != 0 && t.scene != nil {
			if resolved_h, ok := engine.bimap_get(&t.scene.local_ids, t.parent.pptr.local_id); ok {
				next_h = resolved_h
			}
		}
		cur = engine.Transform_Handle(next_h)
	}
	return false
}

@(private = "file")
_ray_body_ignore_should_collide :: proc "c" (userData: rawptr, bodyID: jolt.BodyID) -> bool {
	context = runtime.default_context()
	if userData == nil || !is_body_valid(bodyID) do return true
	ctx := cast(^_Ray_Body_Ignore_Ctx)userData
	if _state.body_interface_no_lock == nil do return true
	u_data := jolt.BodyInterface_GetUserData(_state.body_interface_no_lock, bodyID)
	owner := engine.Transform_Handle(transmute(engine.Handle)u_data)
	if ctx.ignore_owner != {} && _is_transform_or_descendant_raw(ctx.world, owner, ctx.ignore_owner) do return false
	if ctx.ignore_owner2 != {} && _is_transform_or_descendant_raw(ctx.world, owner, ctx.ignore_owner2) do return false
	if ctx.query_mask != 0 {
		if blocks, _, has_c := _owner_effective_masks(ctx.world, owner); has_c {
			return (blocks & ctx.query_mask) != 0
		}
		layer := jolt.BodyInterface_GetObjectLayer(_state.body_interface_no_lock, bodyID)
		if layer >= NUM_LAYERS do return false
		return (u32(ctx.query_mask) & (u32(1) << u32(layer))) != 0
	}
	return true
}

@(private = "file")
_ray_body_ignore_should_collide_locked :: proc "c" (userData: rawptr, body: ^jolt.Body) -> bool {
	context = runtime.default_context()
	if userData == nil || body == nil do return true
	ctx := cast(^_Ray_Body_Ignore_Ctx)userData
	u_data := jolt.Body_GetUserData(body)
	owner := engine.Transform_Handle(transmute(engine.Handle)u_data)
	if ctx.ignore_owner != {} && _is_transform_or_descendant_raw(ctx.world, owner, ctx.ignore_owner) do return false
	if ctx.ignore_owner2 != {} && _is_transform_or_descendant_raw(ctx.world, owner, ctx.ignore_owner2) do return false
	if ctx.query_mask != 0 {
		if blocks, _, has_c := _owner_effective_masks(ctx.world, owner); has_c {
			return (blocks & ctx.query_mask) != 0
		}
		layer := jolt.Body_GetObjectLayer(body)
		if layer >= NUM_LAYERS do return false
		return (u32(ctx.query_mask) & (u32(1) << u32(layer))) != 0
	}
	return true
}

@(private = "file")
_ray_body_ignore_procs := jolt.BodyFilter_Procs{
	ShouldCollide       = _ray_body_ignore_should_collide,
	ShouldCollideLocked = _ray_body_ignore_should_collide_locked,
}

// Fast Channel-0-only (Solid Static World) Jolt raycast that skips the Moving
// BroadPhase BVH tree and optionally ignores `ignore_owner` and `ignore_owner2` (and their children).
raycast_solid_ignore :: proc(
	origin:        [3]f32,
	direction:     [3]f32,
	max_distance:  f32 = 1000.0,
	ignore_owner:  engine.Transform_Handle = {},
	ignore_owner2: engine.Transform_Handle = {},
) -> (hit: Raycast_Hit, ok: bool) {
	return raycast_masked(origin, direction, max_distance, CHANNEL_SOLID_WORLD, ignore_owner, ignore_owner2)
}

// Performs a channel-masked narrowphase Jolt raycast (`MASK_WEAPON_TRACE`, `MASK_VISION_LOS`, `MASK_SOLID_MOVEMENT`, etc.).
// - `MASK_VISION_LOS` automatically ignores `LAYER_GLASS_FENESTRATION`, `LAYER_TRIGGER_SENSOR`, and `LAYER_DEBRIS_COSMETIC`.
// - `MASK_WEAPON_TRACE` hits `LAYER_GLASS_FENESTRATION` (so gameplay can shatter hit glass panes!) while ignoring triggers and debris.
// - When `mask == CHANNEL_SOLID_WORLD`, automatically filters the BroadPhase to `BROAD_LAYER_NON_MOVING` so moving bodies are never visited.
raycast_masked :: proc(
	origin:        [3]f32,
	direction:     [3]f32,
	max_distance:  f32 = 1000.0,
	mask:          Collision_Mask = MASK_WEAPON_TRACE,
	ignore_owner:  engine.Transform_Handle = {},
	ignore_owner2: engine.Transform_Handle = {},
) -> (hit: Raycast_Hit, ok: bool) {
	w := engine.ctx_world()
	_ensure_world(w)
	if !_state.world_ready || _state.system == nil || max_distance <= 1e-4 do return {}, false

	dir_n := linalg.normalize0(direction)
	if linalg.length2(dir_n) < 1e-6 do return {}, false
	ray_vec := dir_n * max_distance

	nq := jolt.PhysicsSystem_GetNarrowPhaseQuery(_state.system)
	if nq == nil do return {}, false

	bp_filter: ^jolt.BroadPhaseLayerFilter = nil
	if mask == CHANNEL_SOLID_WORLD {
		jolt.BroadPhaseLayerFilter_SetProcs(&_ray_bp_solid_only_procs)
		bp_filter = jolt.BroadPhaseLayerFilter_Create(nil)
	}
	defer if bp_filter != nil do jolt.BroadPhaseLayerFilter_Destroy(bp_filter)

	jolt.ObjectLayerFilter_SetProcs(&_ray_layer_filter_procs)
	layer_filter := jolt.ObjectLayerFilter_Create(rawptr(uintptr(u32(mask))))
	defer if layer_filter != nil do jolt.ObjectLayerFilter_Destroy(layer_filter)

	ignore_ctx := _Ray_Body_Ignore_Ctx{
		world         = w,
		ignore_owner  = ignore_owner,
		ignore_owner2 = ignore_owner2,
		query_mask    = mask,
	}
	jolt.BodyFilter_SetProcs(&_ray_body_ignore_procs)
	body_filter := jolt.BodyFilter_Create(&ignore_ctx)
	defer if body_filter != nil do jolt.BodyFilter_Destroy(body_filter)

	orig := origin
	res: jolt.RayCastResult
	if !jolt.NarrowPhaseQuery_CastRay(nq, &orig, &ray_vec, &res, bp_filter, layer_filter, body_filter) {
		return {}, false
	}

	bi := _state.body_interface
	hit_pos := origin + ray_vec * res.fraction
	hit_norm := -dir_n
	layer: jolt.ObjectLayer = LAYER_NON_MOVING
	owner: engine.Transform_Handle = {}

	if bi != nil && is_body_valid(res.bodyID) {
		layer = jolt.BodyInterface_GetObjectLayer(bi, res.bodyID)
		u_data := jolt.BodyInterface_GetUserData(bi, res.bodyID)
		owner = engine.Transform_Handle(transmute(engine.Handle)u_data)
	}
	if lock_iface := jolt.PhysicsSystem_GetBodyLockInterface(_state.system); lock_iface != nil && is_body_valid(res.bodyID) {
		lock_read: jolt.BodyLockRead
		jolt.BodyLockInterface_LockRead(lock_iface, res.bodyID, &lock_read)
		if lock_read.body != nil {
			hp := hit_pos
			n_out: [3]f32
			jolt.Body_GetWorldSpaceSurfaceNormal(lock_read.body, res.subShapeID2, &hp, &n_out)
			if linalg.length2(n_out) > 1e-6 {
				hit_norm = linalg.normalize0(n_out)
			}
		}
		jolt.BodyLockInterface_UnlockRead(lock_iface, &lock_read)
	}

	hit = Raycast_Hit{
		body_id   = res.bodyID,
		owner     = owner,
		layer     = layer,
		channel   = Collision_Channel(min(u8(layer), u8(NUM_LAYERS - 1))),
		position  = hit_pos,
		normal    = hit_norm,
		distance  = max_distance * res.fraction,
		fraction  = res.fraction,
		sub_shape = res.subShapeID2,
	}
	return hit, true
}

// --- Contact Listener Callbacks ------------------------------------------------

_on_contact_validate :: proc "c" (userData: rawptr, body1: ^jolt.Body, body2: ^jolt.Body, baseOffset: ^jolt.RVec3, collisionResult: ^jolt.CollideShapeResult) -> jolt.ValidateResult {
	context = runtime.default_context()
	if body1 != nil && body2 != nil && _state.current_world != nil {
		owner1 := engine.Transform_Handle(transmute(engine.Handle)jolt.Body_GetUserData(body1))
		owner2 := engine.Transform_Handle(transmute(engine.Handle)jolt.Body_GetUserData(body2))
		blocks1, mask1, has1 := _owner_effective_masks(_state.current_world, owner1)
		blocks2, mask2, has2 := _owner_effective_masks(_state.current_world, owner2)
		if has1 || has2 {
			if !has1 {
				l1 := min(u32(jolt.Body_GetObjectLayer(body1)), u32(NUM_LAYERS - 1))
				blocks1 = Collision_Mask(1 << l1)
				mask1 = Collision_Mask(0xFF)
			}
			if !has2 {
				l2 := min(u32(jolt.Body_GetObjectLayer(body2)), u32(NUM_LAYERS - 1))
				blocks2 = Collision_Mask(1 << l2)
				mask2 = Collision_Mask(0xFF)
			}
			if !jolt.Body_IsSensor(body1) && !jolt.Body_IsSensor(body2) {
				if (blocks1 & mask2) == 0 || (blocks2 & mask1) == 0 {
					return .RejectAllContactsForThisBodyPair
				}
			}
		}
	}
	return .AcceptAllContactsForThisBodyPair
}

_on_contact_added :: proc "c" (userData: rawptr, body1: ^jolt.Body, body2: ^jolt.Body, manifold: ^jolt.ContactManifold, settings: ^jolt.ContactSettings) {
	context = runtime.default_context()
	sync.lock(&_state.event_mutex)
	defer sync.unlock(&_state.event_mutex)

	a_handle := engine.Transform_Handle(transmute(engine.Handle)jolt.Body_GetUserData(body1))
	b_handle := engine.Transform_Handle(transmute(engine.Handle)jolt.Body_GetUserData(body2))
	if a_handle != {} && b_handle != {} {
		is_sensor := jolt.Body_IsSensor(body1) || jolt.Body_IsSensor(body2)
		if is_sensor {
			append(&_state.sensor_begin, Contact{a_handle, b_handle})
		} else {
			append(&_state.contact_begin, Contact{a_handle, b_handle})
		}
	}
}

_on_contact_persisted :: proc "c" (userData: rawptr, body1: ^jolt.Body, body2: ^jolt.Body, manifold: ^jolt.ContactManifold, settings: ^jolt.ContactSettings) {
}

_on_contact_removed :: proc "c" (userData: rawptr, subShapePair: ^jolt.SubShapeIDPair) {
	context = runtime.default_context()
	sync.lock(&_state.event_mutex)
	defer sync.unlock(&_state.event_mutex)

	bi := _state.body_interface_no_lock
	if bi == nil do return
	a_u := jolt.BodyInterface_GetUserData(bi, subShapePair.Body1ID)
	b_u := jolt.BodyInterface_GetUserData(bi, subShapePair.Body2ID)
	a_handle := engine.Transform_Handle(transmute(engine.Handle)a_u)
	b_handle := engine.Transform_Handle(transmute(engine.Handle)b_u)
	if a_handle != {} && b_handle != {} {
		is_sensor := jolt.BodyInterface_IsSensor(bi, subShapePair.Body1ID) ||
		             jolt.BodyInterface_IsSensor(bi, subShapePair.Body2ID)
		if is_sensor {
			append(&_state.sensor_end, Contact{a_handle, b_handle})
		} else {
			append(&_state.contact_end, Contact{a_handle, b_handle})
		}
	}
}

// --- Fixed step -----------------------------------------------------------------

@(fixed_update={order=1000})
physics_step :: proc(fixed_dt: f32) {
	context.allocator = runtime.default_allocator()
	w := engine.ctx_world()
	_ensure_world(w)
	if !_state.world_ready do return
	_settings_sync()

	// When called directly outside `engine.fixed_frame_ticks` (e.g. unit tests or custom steppers),
	// scale `fixed_dt` by `engine.time_scale()`. Inside `fixed_frame_ticks`, `simulate.odin` and `app.odin`
	// already pass `engine.scaled_fixed_dt()`.
	step_dt := fixed_dt if engine.fixed_in_tick() else fixed_dt * engine.time_scale()

	// Pre-sync pass: ensure `TimeDilationVolume` colliders are marked as sensors and evaluate initial
	// analytic volume overlaps before `_sync_bodies` scales Jolt velocities for this step.
	time_dilation_volumes_step(w, 0.0)

	sync.lock(&_state.event_mutex)
	clear(&_state.contact_begin)
	clear(&_state.contact_end)
	clear(&_state.sensor_begin)
	clear(&_state.sensor_end)
	sync.unlock(&_state.event_mutex)

	_sync_static_colliders(w)
	if step_dt <= 1e-6 {
		return
	}
	_sync_bodies(w, step_dt)
	_sync_joints(w)
	sub_steps := i32(clamp(physics3d_settings.collision_steps, 1, 8))
	jolt.PhysicsSystem_Update(_state.system, step_dt, sub_steps, _state.job_system)
	_step_character_controllers(w, step_dt)
	_step_joints(w)
	_write_back(w)
	time_dilation_volumes_step(w, step_dt)
}

@(private = "file")
_audio_occlusion_raycast_threadsafe :: proc(origin: [3]f32, direction: [3]f32, max_dist: f32) -> bool {
	if !_state.world_ready || _state.system == nil || max_dist <= 1e-4 do return false
	dir_n := linalg.normalize0(direction)
	if linalg.length2(dir_n) < 1e-6 do return false
	nq := jolt.PhysicsSystem_GetNarrowPhaseQuery(_state.system)
	if nq == nil do return false
	orig := origin
	ray_vec := dir_n * max_dist
	res: jolt.RayCastResult
	return jolt.NarrowPhaseQuery_CastRay(nq, &orig, &ray_vec, &res, _state.occlusion_bp_filter, _state.occlusion_layer_filter, nil)
}

physics_shutdown :: proc() {
	engine.register_audio_occlusion_raycast(nil)
	time_dilation_volumes_shutdown()
	if !_state.world_ready do return
	if _state.current_world != nil && _state.system != nil {
		if jpool := physics_joint3_ds(_state.current_world); jpool != nil {
			jit := engine.pool_iterator(jpool)
			for j, _ in engine.pool_next(&jit) {
				_destroy_joint_runtime(j)
			}
		}
		if cpool := character_controller3_ds(_state.current_world); cpool != nil {
			cit := engine.pool_iterator(cpool)
			for cc, _ in engine.pool_next(&cit) {
				_destroy_character_runtime(cc)
			}
		}
	}
	if _state.system != nil {
		jolt.PhysicsSystem_Destroy(_state.system)
		_state.system = nil
		// Note: PhysicsSystem_Destroy in Jolt automatically frees the broadPhaseLayerInterface,
		// objectLayerPairFilter, and objectVsBroadPhaseLayerFilter passed into it.
		_state.bp_interface = nil
		_state.obj_pair_filter = nil
		_state.obj_vs_bp_filter = nil
	}
	if _state.contact_listener != nil {
		jolt.ContactListener_Destroy(_state.contact_listener)
		_state.contact_listener = nil
	}
	if _state.occlusion_bp_filter != nil {
		jolt.BroadPhaseLayerFilter_Destroy(_state.occlusion_bp_filter)
		_state.occlusion_bp_filter = nil
	}
	if _state.occlusion_layer_filter != nil {
		jolt.ObjectLayerFilter_Destroy(_state.occlusion_layer_filter)
		_state.occlusion_layer_filter = nil
	}
	delete(_state.shape_owner)
	delete(_state.contact_begin)
	delete(_state.contact_end)
	delete(_state.sensor_begin)
	delete(_state.sensor_end)
	_state.shape_owner = nil
	_state.contact_begin = nil
	_state.contact_end = nil
	_state.sensor_begin = nil
	_state.sensor_end = nil
	_state.world_ready = false
	_state.current_world = nil
	_state.current_world_id = 0
	_state.current_rb_pool = nil
}

@(phase={key=ExitingPlayMode})
physics3d_exiting_play_mode :: proc() {
	physics_shutdown()
}

@(phase={key=Shutdown})
physics3d_shutdown :: proc() {
	physics_shutdown()
}

_ensure_world :: proc(w: ^engine.World) {
	world_id := w.id if w != nil else 0
	rb_pool := rawptr(rigidbodies(w)) if w != nil else nil
	if _state.world_ready {
		if _state.current_world != w || _state.current_world_id != world_id || world_id == 0 || _state.current_rb_pool != rb_pool {
			physics_shutdown()
		} else {
			return
		}
	}
	if !jolt.Init() do return
	jolt.SetTraceHandler(_jolt_trace)
	jolt.SetAssertFailureHandler(_jolt_assert_failed)
	_settings_sync()

	if _state.gravity == {} do _state.gravity = GRAVITY_DEFAULT

	if _state.job_system == nil {
		_recreate_job_system()
	}

	_state.obj_pair_filter = jolt.ObjectLayerPairFilterTable_Create(NUM_LAYERS)
	enable_pair :: proc(f: ^jolt.ObjectLayerPairFilter, a, b: jolt.ObjectLayer) {
		jolt.ObjectLayerPairFilterTable_EnableCollision(f, a, b)
		jolt.ObjectLayerPairFilterTable_EnableCollision(f, b, a)
	}
	// 0: Solid World (CSG Chunks / Static Colliders) collides with Dynamic Bodies, Characters, and Cosmetic Debris
	enable_pair(_state.obj_pair_filter, LAYER_NON_MOVING, LAYER_MOVING)
	enable_pair(_state.obj_pair_filter, LAYER_NON_MOVING, LAYER_CHARACTER)
	enable_pair(_state.obj_pair_filter, LAYER_NON_MOVING, LAYER_DEBRIS_COSMETIC)

	// 1: Dynamic Bodies collide with Solid World, Dynamic Bodies, Characters, Glass, and Trigger Sensors
	enable_pair(_state.obj_pair_filter, LAYER_MOVING, LAYER_MOVING)
	enable_pair(_state.obj_pair_filter, LAYER_MOVING, LAYER_CHARACTER)
	enable_pair(_state.obj_pair_filter, LAYER_MOVING, LAYER_GLASS_FENESTRATION)
	enable_pair(_state.obj_pair_filter, LAYER_MOVING, LAYER_TRIGGER_SENSOR)

	// 2: Characters collide with Solid World, Dynamic Bodies, Characters, Glass, and Trigger Sensors (NEVER Cosmetic Debris!)
	enable_pair(_state.obj_pair_filter, LAYER_CHARACTER, LAYER_CHARACTER)
	enable_pair(_state.obj_pair_filter, LAYER_CHARACTER, LAYER_GLASS_FENESTRATION)
	enable_pair(_state.obj_pair_filter, LAYER_CHARACTER, LAYER_TRIGGER_SENSOR)

	// Note: LAYER_DEBRIS_COSMETIC (5) intentionally ONLY collides with LAYER_NON_MOVING (0)!
	// It never collides with LAYER_CHARACTER (2), LAYER_MOVING (1), or itself, so 100 rubble/glass shards
	// bounce realistically on CSG floors/walls without ever tripping players or choking Jolt narrowphase!

	_state.bp_interface = jolt.BroadPhaseLayerInterfaceTable_Create(NUM_LAYERS, NUM_BROAD_LAYERS)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(_state.bp_interface, LAYER_NON_MOVING,         BROAD_LAYER_NON_MOVING)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(_state.bp_interface, LAYER_MOVING,             BROAD_LAYER_MOVING)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(_state.bp_interface, LAYER_CHARACTER,          BROAD_LAYER_MOVING)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(_state.bp_interface, LAYER_GLASS_FENESTRATION, BROAD_LAYER_NON_MOVING)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(_state.bp_interface, LAYER_TRIGGER_SENSOR,     BROAD_LAYER_NON_MOVING)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(_state.bp_interface, LAYER_DEBRIS_COSMETIC,    BROAD_LAYER_MOVING)

	_state.obj_vs_bp_filter = jolt.ObjectVsBroadPhaseLayerFilterTable_Create(
		_state.bp_interface,
		NUM_BROAD_LAYERS,
		_state.obj_pair_filter,
		NUM_LAYERS,
	)

	_state.system = jolt.PhysicsSystem_Create(&{
		maxBodies                     = 65536,
		numBodyMutexes                = 0,
		maxBodyPairs                  = 65536,
		maxContactConstraints         = 65536,
		broadPhaseLayerInterface      = _state.bp_interface,
		objectLayerPairFilter         = _state.obj_pair_filter,
		objectVsBroadPhaseLayerFilter = _state.obj_vs_bp_filter,
	})
	_state.body_interface = jolt.PhysicsSystem_GetBodyInterface(_state.system)
	_state.body_interface_no_lock = jolt.PhysicsSystem_GetBodyInterfaceNoLock(_state.system)

	grav := _state.gravity
	jolt.PhysicsSystem_SetGravity(_state.system, &grav)

	jolt.ContactListener_SetProcs(&_contact_procs)
	_state.contact_listener = jolt.ContactListener_Create(nil)
	jolt.PhysicsSystem_SetContactListener(_state.system, _state.contact_listener)

	_state.shape_owner = make(map[uintptr]engine.Transform_Handle)
	_state.contact_begin = make([dynamic]Contact)
	_state.contact_end = make([dynamic]Contact)
	_state.sensor_begin = make([dynamic]Contact)
	_state.sensor_end = make([dynamic]Contact)

	jolt.BroadPhaseLayerFilter_SetProcs(&_ray_bp_solid_only_procs)
	_state.occlusion_bp_filter = jolt.BroadPhaseLayerFilter_Create(nil)
	jolt.ObjectLayerFilter_SetProcs(&_ray_layer_filter_procs)
	_state.occlusion_layer_filter = jolt.ObjectLayerFilter_Create(rawptr(_AUDIO_OCCLUSION_FILTER_TAG))

	_state.current_world = w
	_state.current_world_id = world_id
	_state.current_rb_pool = rb_pool
	_state.world_ready = true
	engine.register_audio_occlusion_raycast(_audio_occlusion_raycast_threadsafe)
}

// --- Scale & Dimensions (Unity semantics) --------------------------------------

collider_scale :: proc(owner: engine.Transform_Handle) -> [3]f32 {
	tw := engine.transform_world(owner)
	return {abs(tw.scale.x), abs(tw.scale.y), abs(tw.scale.z)}
}

box_scaled :: proc(c: ^BoxCollider, s: [3]f32) -> (size, center: [3]f32) {
	return c.size * s, c.center * s
}

sphere_scaled :: proc(c: ^SphereCollider, s: [3]f32) -> (radius: f32, center: [3]f32) {
	return c.radius * max(s.x, s.y, s.z), c.center * s
}

capsule_scaled :: proc(c: ^CapsuleCollider, s: [3]f32) -> (radius, height: f32, center: [3]f32) {
	switch c.direction {
	case .X_Axis: return c.radius * max(s.y, s.z), c.height * s.x, c.center * s
	case .Y_Axis: return c.radius * max(s.x, s.z), c.height * s.y, c.center * s
	case .Z_Axis: return c.radius * max(s.x, s.y), c.height * s.z, c.center * s
	}
	return c.radius, c.height, c.center * s
}

_capsule_rot :: proc(dir: Capsule_Direction) -> jolt.Quat {
	switch dir {
	case .X_Axis: return linalg.quaternion_angle_axis(f32(math.PI * 0.5), [3]f32{0, 0, 1})
	case .Y_Axis: return jolt.Quat(1)
	case .Z_Axis: return linalg.quaternion_angle_axis(f32(math.PI * 0.5), [3]f32{1, 0, 0})
	}
	return jolt.Quat(1)
}

_world_quat :: proc(rotation: [4]f32) -> jolt.Quat {
	q := rotation
	if linalg.length2(q) < 1e-6 {
		q = {0, 0, 0, 1}
	} else {
		q = linalg.normalize(q)
	}
	return engine.quat_to_native(q)
}

_dofs :: proc(freeze_pos, freeze_rot: [3]bool) -> jolt.AllowedDOFs {
	dofs: i32 = 63 // All
	if freeze_pos.x do dofs &= ~i32(1)
	if freeze_pos.y do dofs &= ~i32(2)
	if freeze_pos.z do dofs &= ~i32(4)
	if freeze_rot.x do dofs &= ~i32(8)
	if freeze_rot.y do dofs &= ~i32(16)
	if freeze_rot.z do dofs &= ~i32(32)
	return jolt.AllowedDOFs(dofs)
}

// --- Shape helpers -------------------------------------------------------------

_create_box_shape :: proc(c: ^BoxCollider, s: [3]f32) -> ^jolt.Shape {
	size, _ := box_scaled(c, s)
	half := [3]f32{
		max(size.x * 0.5, 0.005),
		max(size.y * 0.5, 0.005),
		max(size.z * 0.5, 0.005),
	}
	min_half := min(half.x, min(half.y, half.z))
	convex_r := min(f32(jolt.DEFAULT_CONVEX_RADIUS), min_half * 0.45)
	return auto_cast jolt.BoxShape_Create(&half, convex_r)
}

_create_sphere_shape :: proc(c: ^SphereCollider, s: [3]f32) -> ^jolt.Shape {
	radius, _ := sphere_scaled(c, s)
	return auto_cast jolt.SphereShape_Create(max(radius, 0.005))
}

_create_capsule_shape :: proc(c: ^CapsuleCollider, s: [3]f32) -> ^jolt.Shape {
	radius, height, _ := capsule_scaled(c, s)
	r := max(radius, 0.005)
	half := max(height * 0.5 - r, 0.001)
	return auto_cast jolt.CapsuleShape_Create(half, r)
}

resolve_mesh_collider_pptr :: proc(w: ^engine.World, c: ^MeshCollider) -> (engine.PPtr, bool) {
	if c == nil do return {}, false
	if !engine.asset_guid_is_empty(c.mesh.guid) {
		return c.mesh, true
	}
	if w == nil || c.owner == {} || !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) {
		return {}, false
	}
	_, mf := engine.transform_get_comp(c.owner, engine.MeshFilter)
	if mf == nil || engine.asset_guid_is_empty(mf.mesh.guid) do return {}, false
	return mf.mesh, true
}

_create_mesh_shape :: proc(w: ^engine.World, c: ^MeshCollider, s: [3]f32, force_convex: bool) -> ^jolt.Shape {
	pptr, ok := resolve_mesh_collider_pptr(w, c)
	if !ok do return nil

	tmp_mf := engine.MeshFilter{mesh = pptr}
	verts, inds, g_ok := engine.mesh_read_cpu_geometry(&tmp_mf, context.temp_allocator)
	if !g_ok || len(verts) < 3 do return nil

	use_convex := c.convex || force_convex || len(inds) < 3
	if use_convex {
		hull_pts := make([dynamic]jolt.Vec3, 0, min(len(verts), 256), context.temp_allocator)
		if len(verts) <= 256 {
			for v in verts {
				append(&hull_pts, v.position * s)
			}
		} else {
			// Include the 6 AABB extreme vertices first so the outer hull extent is exact,
			// then stride uniformly up to 256 points so Jolt quickhull runs in microseconds.
			ext_idx: [6]int
			for v, idx in verts {
				if v.position.x < verts[ext_idx[0]].position.x do ext_idx[0] = idx
				if v.position.x > verts[ext_idx[1]].position.x do ext_idx[1] = idx
				if v.position.y < verts[ext_idx[2]].position.y do ext_idx[2] = idx
				if v.position.y > verts[ext_idx[3]].position.y do ext_idx[3] = idx
				if v.position.z < verts[ext_idx[4]].position.z do ext_idx[4] = idx
				if v.position.z > verts[ext_idx[5]].position.z do ext_idx[5] = idx
			}
			for ei in ext_idx {
				append(&hull_pts, verts[ei].position * s)
			}
			step := max(len(verts) / 250, 1)
			for idx := 0; idx < len(verts) && len(hull_pts) < 256; idx += step {
				append(&hull_pts, verts[idx].position * s)
			}
		}
		settings := jolt.ConvexHullShapeSettings_Create(raw_data(hull_pts[:]), u32(len(hull_pts)), f32(jolt.DEFAULT_CONVEX_RADIUS))
		if settings == nil do return nil
		shape := jolt.ConvexHullShapeSettings_CreateShape(settings)
		jolt.ShapeSettings_Destroy(auto_cast settings)
		return auto_cast shape
	}

	tri_count := len(inds) / 3
	if tri_count == 0 do return nil
	scaled_verts := make([]jolt.Vec3, len(verts), context.temp_allocator)
	for v, i in verts {
		scaled_verts[i] = v.position * s
	}
	tris := make([]jolt.IndexedTriangle, tri_count, context.temp_allocator)
	for t in 0 ..< tri_count {
		tris[t] = jolt.IndexedTriangle{
			i1 = inds[t * 3 + 0],
			i2 = inds[t * 3 + 1],
			i3 = inds[t * 3 + 2],
		}
	}
	settings := jolt.MeshShapeSettings_Create2(
		raw_data(scaled_verts),
		u32(len(scaled_verts)),
		raw_data(tris),
		u32(tri_count),
	)
	if settings == nil do return nil
	jolt.MeshShapeSettings_Sanitize(settings)
	shape := jolt.MeshShapeSettings_CreateShape(settings)
	jolt.ShapeSettings_Destroy(auto_cast settings)
	return auto_cast shape
}

_Sub_Shape :: struct {
	shape:   ^jolt.Shape,
	pos:     [3]f32,
	rot:     jolt.Quat,
	owner:   engine.Transform_Handle,
	channel: Collision_Channel,
	fric:    f32,
	restit:  f32,
	sensor:  bool,
}

_ancestor_body_owner :: proc(w: ^engine.World, tH: engine.Transform_Handle) -> (body_owner: engine.Transform_Handle, is_rb: bool) {
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		_, idx := engine.transform_find_comp(t, .Rigidbody)
		if idx >= 0 {
			return cur, true
		}
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return tH, false
}

_collect_colliders_for_body :: proc(w: ^engine.World, body_owner: engine.Transform_Handle) -> [dynamic]_Sub_Shape {
	subs := make([dynamic]_Sub_Shape, context.temp_allocator)
	bw := engine.transform_world(body_owner)
	inv_bq := linalg.quaternion_inverse(_world_quat(bw.rotation))

	bt := engine.pool_get(&w.transforms, engine.Handle(body_owner))
	if bt == nil do return subs
	rb_owned, body_has_rb := engine.transform_find_comp(bt, .Rigidbody)
	has_rb := body_has_rb >= 0
	is_dynamic_rb := false
	if has_rb {
		if rb_pool := rigidbodies(w); rb_pool != nil {
			if rb_comp := engine.pool_get(rb_pool, rb_owned.handle); rb_comp != nil {
				is_dynamic_rb = !rb_comp.is_kinematic
			}
		}
	}

	box_pool    := box_colliders(w)
	sphere_pool := sphere_colliders(w)
	cap_pool    := capsule_colliders(w)
	mesh_pool   := mesh_colliders(w)

	_visit_node :: proc(
		w:             ^engine.World,
		tH:            engine.Transform_Handle,
		bw:            engine.Transform_World,
		inv_bq:        jolt.Quat,
		is_root:       bool,
		recurse_rb:    bool,
		is_dynamic_rb: bool,
		box_pool:      ^engine.Pool(BoxCollider),
		sphere_pool:   ^engine.Pool(SphereCollider),
		cap_pool:      ^engine.Pool(CapsuleCollider),
		mesh_pool:     ^engine.Pool(MeshCollider),
		subs:          ^[dynamic]_Sub_Shape,
	) {
		if !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil || !t.is_active do return

		if !is_root {
			if _, rb_idx := engine.transform_find_comp(t, .Rigidbody); rb_idx >= 0 {
				return // Child has its own Rigidbody; its colliders belong to that body
			}
		}

		for owned in t.components {
			#partial switch owned.handle.type_key {
			case .BoxCollider:
				if box_pool == nil do continue
				c := engine.pool_get(box_pool, owned.handle)
				if c == nil || !c.enabled do continue
				s := collider_scale(tH)
				if c.shape != nil && (c.size != c.last_size || linalg.length2(s - c.last_scale) > 1e-6) {
					delete_key(&_state.shape_owner, transmute(uintptr)c.shape)
					jolt.Shape_Destroy(c.shape)
					c.shape = nil
				}
				if c.shape == nil {
					c.shape = _create_box_shape(c, s)
					c.last_size = c.size
					c.last_scale = s
				}
				if c.shape == nil do continue
				cw := is_root ? bw : engine.transform_world(tH)
				local_q := _world_quat(c.rotation)
				cw_q := _world_quat(cw.rotation)
				rel_q := linalg.normalize(inv_bq * cw_q * local_q)
				_, center := box_scaled(c, s)
				rel_p := linalg.quaternion128_mul_vector3(inv_bq, cw.position - bw.position) + linalg.quaternion128_mul_vector3(inv_bq * cw_q, center)
				append(subs, _Sub_Shape{
					shape   = c.shape,
					pos     = rel_p,
					rot     = rel_q,
					owner   = tH,
					channel = c.channel,
					fric    = c.friction,
					restit  = c.bounciness,
					sensor  = c.is_trigger,
				})
			case .SphereCollider:
				if sphere_pool == nil do continue
				c := engine.pool_get(sphere_pool, owned.handle)
				if c == nil || !c.enabled do continue
				s := collider_scale(tH)
				if c.shape != nil && (abs(c.radius - c.last_radius) > 1e-6 || linalg.length2(s - c.last_scale) > 1e-6) {
					delete_key(&_state.shape_owner, transmute(uintptr)c.shape)
					jolt.Shape_Destroy(c.shape)
					c.shape = nil
				}
				if c.shape == nil {
					c.shape = _create_sphere_shape(c, s)
					c.last_radius = c.radius
					c.last_scale = s
				}
				if c.shape == nil do continue
				cw := is_root ? bw : engine.transform_world(tH)
				rel_q := linalg.normalize(inv_bq * _world_quat(cw.rotation))
				_, center := sphere_scaled(c, s)
				rel_p := linalg.quaternion128_mul_vector3(inv_bq, cw.position - bw.position) + linalg.quaternion128_mul_vector3(rel_q, center)
				append(subs, _Sub_Shape{
					shape   = c.shape,
					pos     = rel_p,
					rot     = rel_q,
					owner   = tH,
					channel = c.channel,
					fric    = c.friction,
					restit  = c.bounciness,
					sensor  = c.is_trigger,
				})
			case .CapsuleCollider:
				if cap_pool == nil do continue
				c := engine.pool_get(cap_pool, owned.handle)
				if c == nil || !c.enabled do continue
				s := collider_scale(tH)
				if c.shape != nil && (abs(c.radius - c.last_radius) > 1e-6 || abs(c.height - c.last_height) > 1e-6 || c.direction != c.last_dir || linalg.length2(s - c.last_scale) > 1e-6) {
					delete_key(&_state.shape_owner, transmute(uintptr)c.shape)
					jolt.Shape_Destroy(c.shape)
					c.shape = nil
				}
				if c.shape == nil {
					c.shape = _create_capsule_shape(c, s)
					c.last_radius = c.radius
					c.last_height = c.height
					c.last_dir = c.direction
					c.last_scale = s
				}
				if c.shape == nil do continue
				cw := is_root ? bw : engine.transform_world(tH)
				local_q := _world_quat(c.rotation)
				cw_q := _world_quat(cw.rotation)
				rel_q := linalg.normalize(inv_bq * cw_q * _capsule_rot(c.direction) * local_q)
				_, _, center := capsule_scaled(c, s)
				rel_p := linalg.quaternion128_mul_vector3(inv_bq, cw.position - bw.position) + linalg.quaternion128_mul_vector3(inv_bq * cw_q, center)
				append(subs, _Sub_Shape{
					shape   = c.shape,
					pos     = rel_p,
					rot     = rel_q,
					owner   = tH,
					channel = c.channel,
					fric    = c.friction,
					restit  = c.bounciness,
					sensor  = c.is_trigger,
				})
			case .MeshCollider:
				if mesh_pool == nil do continue
				c := engine.pool_get(mesh_pool, owned.handle)
				if c == nil || !c.enabled do continue
				s := collider_scale(tH)
				pptr, _ := resolve_mesh_collider_pptr(w, c)
				use_convex := c.convex || is_dynamic_rb
				if c.shape != nil && (pptr.guid != c.last_mesh_guid || use_convex != c.last_convex || linalg.length2(s - c.last_scale) > 1e-6) {
					delete_key(&_state.shape_owner, transmute(uintptr)c.shape)
					jolt.Shape_Destroy(c.shape)
					c.shape = nil
				}
				if c.shape == nil {
					c.shape = _create_mesh_shape(w, c, s, is_dynamic_rb)
					c.last_mesh_guid = pptr.guid
					c.last_convex = use_convex
					c.last_scale = s
				}
				if c.shape == nil do continue
				cw := is_root ? bw : engine.transform_world(tH)
				local_q := _world_quat(c.rotation)
				cw_q := _world_quat(cw.rotation)
				rel_q := linalg.normalize(inv_bq * cw_q * local_q)
				center := c.center * s
				rel_p := linalg.quaternion128_mul_vector3(inv_bq, cw.position - bw.position) + linalg.quaternion128_mul_vector3(inv_bq * cw_q, center)
				append(subs, _Sub_Shape{
					shape   = c.shape,
					pos     = rel_p,
					rot     = rel_q,
					owner   = tH,
					channel = c.channel,
					fric    = c.friction,
					restit  = c.bounciness,
					sensor  = c.is_trigger,
				})
			}
		}

		if recurse_rb {
			for child in t.children {
				_visit_node(w, engine.Transform_Handle(child.handle), bw, inv_bq, false, true, is_dynamic_rb, box_pool, sphere_pool, cap_pool, mesh_pool, subs)
			}
		}
	}

	_visit_node(w, body_owner, bw, inv_bq, true, has_rb, is_dynamic_rb, box_pool, sphere_pool, cap_pool, mesh_pool, &subs)
	return subs
}

// --- Sync Static Colliders -----------------------------------------------------

_sync_static_colliders :: proc(w: ^engine.World) {
	_sync_static_group :: proc(w: ^engine.World, owner: engine.Transform_Handle, static_body: ^jolt.BodyID, last_pos: ^[3]f32, last_rot: ^[4]f32) {
		if is_body_valid(static_body^) {
			if _state.body_interface != nil {
				// Fast path for root-level stationary static colliders: avoid recursive transform_world()
				// and avoid Jolt C FFI BodyInterface_GetPositionAndRotation() when local transform is unchanged!
				t := engine.pool_get(&w.transforms, engine.Handle(owner))
				if t != nil && t.parent.handle == {} {
					if linalg.length2(t.position - last_pos^) <= 1e-6 && linalg.length2(t.rotation - last_rot^) <= 1e-5 {
						return
					}
				}
				tw := engine.transform_world(owner)
				if linalg.length2(tw.position - last_pos^) <= 1e-6 && linalg.length2(tw.rotation - last_rot^) <= 1e-5 {
					return
				}
				if jolt.BodyInterface_IsAdded(_state.body_interface, static_body^) {
					target_pos := tw.position
					target_rot := _world_quat(tw.rotation)
					jolt.BodyInterface_SetPositionAndRotation(_state.body_interface, static_body^, &target_pos, &target_rot, .Activate)
					last_pos^ = tw.position
					last_rot^ = tw.rotation
				}
			}
			return
		}
		if !engine.transform_active_in_hierarchy(owner) do return
		_, is_rb := _ancestor_body_owner(w, owner)
		if is_rb do return // attached to a dynamic/kinematic Rigidbody

		subs := _collect_colliders_for_body(w, owner)
		if len(subs) == 0 do return

		shape: ^jolt.Shape
		if len(subs) == 1 {
			if subs[0].pos == {} && subs[0].rot == jolt.Quat(1) {
				shape = subs[0].shape
			} else {
				pos := subs[0].pos
				rot := subs[0].rot
				shape = auto_cast jolt.RotatedTranslatedShape_Create(&pos, &rot, subs[0].shape)
			}
		} else {
			settings := jolt.StaticCompoundShapeSettings_Create()
			for sub in subs {
				pos := sub.pos
				rot := sub.rot
				jolt.CompoundShapeSettings_AddShape2(auto_cast settings, &pos, &rot, sub.shape, 0)
			}
			shape = auto_cast jolt.StaticCompoundShape_Create(settings)
		}
		if shape == nil do return

		tw := engine.transform_world(owner)
		pos := tw.position
		rot := _world_quat(tw.rotation)
		static_layer := LAYER_TRIGGER_SENSOR if subs[0].sensor else jolt.ObjectLayer(min(u8(subs[0].channel), u8(NUM_LAYERS - 1)))
		def := jolt.BodyCreationSettings_Create3(shape, &pos, &rot, .Static, static_layer)
		if def == nil do return
		jolt.BodyCreationSettings_SetUserData(def, transmute(u64)engine.Handle(owner))
		if subs[0].fric > 0 do jolt.BodyCreationSettings_SetFriction(def, subs[0].fric)
		if subs[0].restit > 0 do jolt.BodyCreationSettings_SetRestitution(def, subs[0].restit)
		if subs[0].sensor do jolt.BodyCreationSettings_SetIsSensor(def, true)

		static_body^ = jolt.BodyInterface_CreateAndAddBody(_state.body_interface, def, .DontActivate)
		jolt.BodyCreationSettings_Destroy(def)
		last_pos^ = tw.position
		last_rot^ = tw.rotation

		for sub in subs {
			_state.shape_owner[transmute(uintptr)sub.shape] = sub.owner
		}
	}

	{
		it := engine.pool_iterator(box_colliders(w))
		for c, _ in engine.pool_next(&it) {
			if !c.enabled do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) || !engine.transform_active_in_hierarchy(c.owner) do continue
			if is_body_valid(c.static_body) && c.size != c.last_size {
				_destroy_shape(&c.shape, &c.static_body)
			}
			_sync_static_group(w, c.owner, &c.static_body, &c.last_sync_pos, &c.last_sync_rot)
		}
	}
	{
		it := engine.pool_iterator(sphere_colliders(w))
		for c, _ in engine.pool_next(&it) {
			if !c.enabled do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) || !engine.transform_active_in_hierarchy(c.owner) do continue
			if is_body_valid(c.static_body) && abs(c.radius - c.last_radius) > 1e-6 {
				_destroy_shape(&c.shape, &c.static_body)
			}
			_sync_static_group(w, c.owner, &c.static_body, &c.last_sync_pos, &c.last_sync_rot)
		}
	}
	{
		it := engine.pool_iterator(capsule_colliders(w))
		for c, _ in engine.pool_next(&it) {
			if !c.enabled do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) || !engine.transform_active_in_hierarchy(c.owner) do continue
			if is_body_valid(c.static_body) && (abs(c.radius - c.last_radius) > 1e-6 || abs(c.height - c.last_height) > 1e-6 || c.direction != c.last_dir) {
				_destroy_shape(&c.shape, &c.static_body)
			}
			_sync_static_group(w, c.owner, &c.static_body, &c.last_sync_pos, &c.last_sync_rot)
		}
	}
	{
		it := engine.pool_iterator(mesh_colliders(w))
		for c, _ in engine.pool_next(&it) {
			if !c.enabled do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) || !engine.transform_active_in_hierarchy(c.owner) do continue
			if is_body_valid(c.static_body) {
				pptr, _ := resolve_mesh_collider_pptr(w, c)
				if pptr.guid != c.last_mesh_guid || c.convex != c.last_convex {
					_destroy_shape(&c.shape, &c.static_body)
				}
			}
			_sync_static_group(w, c.owner, &c.static_body, &c.last_sync_pos, &c.last_sync_rot)
		}
	}
}

@(private = "file")
_rb_has_dirty_collider :: proc(w: ^engine.World, owner: engine.Transform_Handle, is_root: bool = true) -> bool {
	if !engine.pool_valid(&w.transforms, engine.Handle(owner)) do return false
	t := engine.pool_get(&w.transforms, engine.Handle(owner))
	if t == nil || !t.is_active do return false
	if !is_root {
		if _, rb_idx := engine.transform_find_comp(t, .Rigidbody); rb_idx >= 0 do return false
	}
	for owned in t.components {
		#partial switch owned.handle.type_key {
		case .BoxCollider:
			if pool := box_colliders(w); pool != nil {
				if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled && c.shape != nil {
					if c.size != c.last_size || linalg.length2(collider_scale(owner) - c.last_scale) > 1e-6 do return true
				}
			}
		case .SphereCollider:
			if pool := sphere_colliders(w); pool != nil {
				if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled && c.shape != nil {
					if abs(c.radius - c.last_radius) > 1e-6 || linalg.length2(collider_scale(owner) - c.last_scale) > 1e-6 do return true
				}
			}
		case .CapsuleCollider:
			if pool := capsule_colliders(w); pool != nil {
				if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled && c.shape != nil {
					if abs(c.radius - c.last_radius) > 1e-6 || abs(c.height - c.last_height) > 1e-6 || c.direction != c.last_dir || linalg.length2(collider_scale(owner) - c.last_scale) > 1e-6 do return true
				}
			}
		case .MeshCollider:
			if pool := mesh_colliders(w); pool != nil {
				if c := engine.pool_get(pool, owned.handle); c != nil && c.enabled && c.shape != nil {
					pptr, _ := resolve_mesh_collider_pptr(w, c)
					if pptr.guid != c.last_mesh_guid || linalg.length2(collider_scale(owner) - c.last_scale) > 1e-6 do return true
				}
			}
		}
	}
	for child in t.children {
		if _rb_has_dirty_collider(w, engine.Transform_Handle(child.handle), false) do return true
	}
	return false
}

// --- Sync Dynamic/Kinematic Bodies ---------------------------------------------

_sync_bodies :: proc(w: ^engine.World, fixed_dt: f32) {
	it := engine.pool_iterator(rigidbodies(w))
	for rb, _ in engine.pool_next(&it) {
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) || !engine.transform_active_in_hierarchy(rb.owner) do continue

		restore_vel := false
		prev_lin_v, prev_ang_v: [3]f32
		if is_body_valid(rb.body) && _rb_has_dirty_collider(w, rb.owner) {
			if !rb.is_kinematic && _state.body_interface != nil {
				jolt.BodyInterface_GetLinearAndAngularVelocity(_state.body_interface, rb.body, &prev_lin_v, &prev_ang_v)
				restore_vel = true
			}
			_destroy_body(&rb.body)
		}

		if !is_body_valid(rb.body) {
			if !rb.enabled do continue
			subs := _collect_colliders_for_body(w, rb.owner)
			if len(subs) == 0 do continue

			shape: ^jolt.Shape
			if len(subs) == 1 {
				if subs[0].pos == {} && subs[0].rot == jolt.Quat(1) {
					shape = subs[0].shape
				} else {
					pos := subs[0].pos
					rot := subs[0].rot
					shape = auto_cast jolt.RotatedTranslatedShape_Create(&pos, &rot, subs[0].shape)
				}
			} else {
				settings := jolt.StaticCompoundShapeSettings_Create()
				for sub in subs {
					pos := sub.pos
					rot := sub.rot
					jolt.CompoundShapeSettings_AddShape2(auto_cast settings, &pos, &rot, sub.shape, 0)
				}
				shape = auto_cast jolt.StaticCompoundShape_Create(settings)
			}
			if shape == nil do continue

			tw := engine.transform_world(rb.owner)
			pos := tw.position
			rot := _world_quat(tw.rotation)
			motion_type: jolt.MotionType = .Kinematic if rb.is_kinematic else .Dynamic
			rb_chan := rb.channel if rb.channel != .Solid_World else (subs[0].channel if subs[0].channel != .Solid_World else .Dynamic_Body)
			layer: jolt.ObjectLayer = LAYER_TRIGGER_SENSOR if subs[0].sensor else jolt.ObjectLayer(min(u8(rb_chan), u8(NUM_LAYERS - 1)))

			def := jolt.BodyCreationSettings_Create3(shape, &pos, &rot, motion_type, layer)
			if def == nil do continue
			jolt.BodyCreationSettings_SetLinearDamping(def, rb.linear_damping)
			jolt.BodyCreationSettings_SetAngularDamping(def, rb.angular_damping)
			jolt.BodyCreationSettings_SetGravityFactor(def, 1 if rb.use_gravity else 0)
			jolt.BodyCreationSettings_SetAllowedDOFs(def, _dofs(rb.freeze_position, rb.freeze_rotation))
			if rb.continuous {
				jolt.BodyCreationSettings_SetMotionQuality(def, .LinearCast)
			}
			jolt.BodyCreationSettings_SetUserData(def, transmute(u64)engine.Handle(rb.owner))
			if subs[0].fric > 0 do jolt.BodyCreationSettings_SetFriction(def, subs[0].fric)
			if subs[0].restit > 0 do jolt.BodyCreationSettings_SetRestitution(def, subs[0].restit)
			if subs[0].sensor do jolt.BodyCreationSettings_SetIsSensor(def, true)

			rb.body = jolt.BodyInterface_CreateAndAddBody(_state.body_interface, def, .Activate)
			jolt.BodyCreationSettings_Destroy(def)
			if restore_vel && is_body_valid(rb.body) {
				jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &prev_lin_v, &prev_ang_v)
			}
			rb.last_synced_pos      = pos
			rb.last_synced_rot      = tw.rotation
			rb.prev_pos             = pos
			rb.prev_rot             = tw.rotation
			rb.curr_pos             = pos
			rb.curr_rot             = tw.rotation
			rb.has_prev_pose        = true
			rb.has_synced_transform = true

			for sub in subs {
				_state.shape_owner[transmute(uintptr)sub.shape] = sub.owner
			}
		} else {
			is_active := jolt.BodyInterface_IsActive(_state.body_interface, rb.body)
			if rb.enabled != is_active {
				if rb.enabled do jolt.BodyInterface_ActivateBody(_state.body_interface, rb.body)
				else do jolt.BodyInterface_DeactivateBody(_state.body_interface, rb.body)
			}

			if rb.is_kinematic && rb.enabled {
				tw := engine.transform_world(rb.owner)
				target_pos := tw.position
				target_rot := _world_quat(tw.rotation)
				jolt.BodyInterface_MoveKinematic(_state.body_interface, rb.body, &target_pos, &target_rot, fixed_dt)
				rb.last_synced_pos      = tw.position
				rb.last_synced_rot      = tw.rotation
				rb.prev_pos             = rb.curr_pos if rb.has_prev_pose else tw.position
				rb.prev_rot             = rb.curr_rot if rb.has_prev_pose else tw.rotation
				rb.curr_pos             = tw.position
				rb.curr_rot             = tw.rotation
				rb.has_prev_pose        = true
				rb.has_synced_transform = true
			} else if !rb.is_kinematic && rb.enabled && rb.has_synced_transform {
				// Detect runtime Transform changes (e.g. Scene Gizmo drag, Inspector edit, or script teleport)
				// and teleport the Jolt dynamic body instead of snapping the Transform back!
				tw := engine.transform_world(rb.owner)
				if linalg.length2(tw.position - rb.last_synced_pos) > 1e-6 ||
				   linalg.length2(tw.rotation - rb.last_synced_rot) > 1e-5 {
					target_pos := tw.position
					target_rot := _world_quat(tw.rotation)
					jolt.BodyInterface_SetPositionAndRotation(_state.body_interface, rb.body, &target_pos, &target_rot, .Activate)
					zero_v := [3]f32{0, 0, 0}
					jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &zero_v, &zero_v)
					rb.last_synced_pos = tw.position
					rb.last_synced_rot = tw.rotation
					rb.prev_pos        = tw.position
					rb.prev_rot        = tw.rotation
					rb.curr_pos        = tw.position
					rb.curr_rot        = tw.rotation
					rb.has_prev_pose   = true
				}
			}
		}

		// Per-Object Relativistic Time Dilation (s * v, s^2 * g):
		// Since global `engine.time_scale()` is already applied to `fixed_dt`, we scale each dynamic
		// body's Jolt velocity by its hierarchy custom time scale `s` and its GravityFactor by `s^2`.
		if !rb.is_kinematic && rb.enabled && is_body_valid(rb.body) {
			s := engine.transform_hierarchy_time_scale(rb.owner)
			if engine.transform_ignores_global_in_hierarchy(rb.owner) && engine.time_scale() > 1e-4 {
				s /= engine.time_scale()
			}
			base_grav: f32 = 1.0 if rb.use_gravity else 0.0

			if s <= 1e-5 {
				if !rb.frozen_by_time_scale {
					jolt.BodyInterface_GetLinearAndAngularVelocity(_state.body_interface, rb.body, &rb.true_linear_vel, &rb.true_angular_vel)
					zero_v := [3]f32{0, 0, 0}
					jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &zero_v, &zero_v)
					jolt.BodyInterface_SetGravityFactor(_state.body_interface, rb.body, 0.0)
					rb.frozen_by_time_scale = true
				}
				rb.applied_time_scale = 0.0
				rb.has_dilated_vel    = true
			} else {
				if rb.frozen_by_time_scale {
					jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &rb.true_linear_vel, &rb.true_angular_vel)
					jolt.BodyInterface_SetGravityFactor(_state.body_interface, rb.body, base_grav)
					jolt.BodyInterface_ActivateBody(_state.body_interface, rb.body)
					rb.frozen_by_time_scale = false
				}
				if abs(s - 1.0) > 1e-4 {
					jolt.BodyInterface_GetLinearAndAngularVelocity(_state.body_interface, rb.body, &rb.true_linear_vel, &rb.true_angular_vel)
					sim_lin := rb.true_linear_vel * s
					sim_ang := rb.true_angular_vel * s
					jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &sim_lin, &sim_ang)
					jolt.BodyInterface_SetGravityFactor(_state.body_interface, rb.body, base_grav * s * s)
					if s < 1.0 && (linalg.length2(rb.true_linear_vel) > 1e-4 || linalg.length2(rb.true_angular_vel) > 1e-4 || rb.use_gravity) {
						jolt.BodyInterface_ResetSleepTimer(_state.body_interface, rb.body)
					}
					rb.applied_time_scale = s
					rb.has_dilated_vel    = true
				} else if rb.has_dilated_vel {
					jolt.BodyInterface_SetGravityFactor(_state.body_interface, rb.body, base_grav)
					rb.applied_time_scale = 1.0
					rb.has_dilated_vel    = false
				}
			}
		}
	}
}

// --- Write back: Jolt -> transforms --------------------------------------------

_write_back :: proc(w: ^engine.World) {
	it := engine.pool_iterator(rigidbodies(w))
	for rb, _ in engine.pool_next(&it) {
		if rb.is_kinematic || !rb.enabled || !is_body_valid(rb.body) do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue
		if rb.frozen_by_time_scale {
			target_pos := rb.last_synced_pos
			target_rot := _world_quat(rb.last_synced_rot)
			jolt.BodyInterface_SetPositionAndRotation(_state.body_interface, rb.body, &target_pos, &target_rot, .DontActivate)
			zero_v := [3]f32{0, 0, 0}
			jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &zero_v, &zero_v)
			continue
		}
		pos: jolt.RVec3
		q: jolt.Quat
		jolt.BodyInterface_GetPosition(_state.body_interface, rb.body, &pos)
		jolt.BodyInterface_GetRotation(_state.body_interface, rb.body, &q)
		rot_v := engine.quat_from_native(q)
		prev_p := rb.curr_pos if rb.has_prev_pose else pos
		prev_r := rb.curr_rot if rb.has_prev_pose else rot_v
		if linalg.length2(pos - prev_p) > 25.0 { // > 5m teleport snap
			prev_p = pos
			prev_r = rot_v
		}
		rb.prev_pos             = prev_p
		rb.prev_rot             = prev_r
		rb.curr_pos             = pos
		rb.curr_rot             = rot_v
		rb.has_prev_pose        = true

		engine.transform_set_world_position(rb.owner, pos)
		engine.transform_set_world_rotation(rb.owner, rot_v)
		rb.last_synced_pos      = pos
		rb.last_synced_rot      = rot_v
		rb.has_synced_transform = true

		// Restore unscaled true velocity (v_true = v_post / s) in Jolt so external queries and
		// exit from `TimeDilationVolume` preserve 100% of the body's real-world momentum!
		if rb.has_dilated_vel && rb.applied_time_scale > 1e-5 && abs(rb.applied_time_scale - 1.0) > 1e-4 {
			post_lin, post_ang: [3]f32
			jolt.BodyInterface_GetLinearAndAngularVelocity(_state.body_interface, rb.body, &post_lin, &post_ang)
			inv_s := 1.0 / rb.applied_time_scale
			rb.true_linear_vel  = post_lin * inv_s
			rb.true_angular_vel = post_ang * inv_s
			jolt.BodyInterface_SetLinearAndAngularVelocity(_state.body_interface, rb.body, &rb.true_linear_vel, &rb.true_angular_vel)
		}
	}
}

// Pure pose interpolation helper (5.0m teleport snap + shortest-path slerp).
physics_interpolate_pose :: proc(rb: ^Rigidbody, alpha: f32) -> (pos: [3]f32, rot: [4]f32) {
	if rb == nil do return {}, {0, 0, 0, 1}
	if !rb.interpolate || !rb.has_prev_pose {
		return rb.curr_pos, rb.curr_rot
	}
	if linalg.length2(rb.curr_pos - rb.prev_pos) > 25.0 {
		return rb.curr_pos, rb.curr_rot
	}
	a := clamp(alpha, f32(0.0), f32(1.0))
	pos = linalg.lerp(rb.prev_pos, rb.curr_pos, a)
	q0 := engine.quat_to_native(rb.prev_rot)
	q1 := engine.quat_to_native(rb.curr_rot)
	if q0.x*q1.x + q0.y*q1.y + q0.z*q1.z + q0.w*q1.w < 0 {
		q1 = -q1
	}
	rot = engine.quat_from_native(linalg.quaternion_normalize(linalg.quaternion_slerp(q0, q1, a)))
	return pos, rot
}

@(update={order=1000})
physics_interpolate_update :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil || !_state.world_ready || _state.current_world != w do return
	if engine.time_scale() <= 1e-5 do return

	alpha := engine.fixed_interpolation_alpha()
	pool := rigidbodies(w)
	if pool == nil do return
	it := engine.pool_iterator(pool)
	for rb, _ in engine.pool_next(&it) {
		if !rb.interpolate || !rb.has_prev_pose || !rb.has_synced_transform do continue
		if rb.is_kinematic || !rb.enabled || rb.frozen_by_time_scale || !is_body_valid(rb.body) do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue

		tw := engine.transform_world(rb.owner)
		if linalg.length2(tw.position - rb.last_synced_pos) > 1e-5 ||
		   linalg.length2(tw.rotation - rb.last_synced_rot) > 1e-4 {
			continue // Script moved transform manually this frame; keep it untouched
		}

		pos, rot := physics_interpolate_pose(rb, alpha)
		engine.transform_set_world_position(rb.owner, pos)
		engine.transform_set_world_rotation(rb.owner, rot)
		rb.last_synced_pos = pos
		rb.last_synced_rot = rot
	}
}

// --- Teardown (component cleanup/on_destroy hooks) --------------------------------

_destroy_body :: proc(body: ^jolt.BodyID) {
	if _state.world_ready && _state.body_interface != nil && is_body_valid(body^) {
		jolt.BodyInterface_RemoveAndDestroyBody(_state.body_interface, body^)
	}
	body^ = 0
}

_destroy_shape :: proc(shape: ^^jolt.Shape, static_body: ^jolt.BodyID) {
	if _state.world_ready && shape^ != nil {
		delete_key(&_state.shape_owner, transmute(uintptr)shape^)
		jolt.Shape_Destroy(shape^)
	}
	shape^ = nil
	_destroy_body(static_body)
}
