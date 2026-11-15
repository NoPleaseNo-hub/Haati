package physics3d

// CharacterController3D: Jolt CharacterVirtual capsule controller supporting
// slopes, stair-stepping, floor-sticking, and external transform teleports.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import jolt "haati:external/jolt"
import "haati:engine"

@(init)
_init_nav_controller_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.nav_agent_register_controller_mover(_nav_move_character_controller)
}

@(private = "file")
_nav_move_character_controller :: proc(owner: engine.Transform_Handle, desired_horizontal_vel: [3]f32, dt: f32) -> bool {
	w := engine.ctx_world()
	if w == nil do return false
	_, cc := engine.transform_get_comp(owner, CharacterController3D)
	if cc == nil || !cc.enabled do return false
	character_move(cc, desired_horizontal_vel)
	return true
}

@(component={menu="Physics/CharacterController3D"})
@(typ_guid={guid = "d3e4f5a6-1122-4c3d-8e9f-001122334455"})
CharacterController3D :: struct {
	using base:          engine.CompData `inspect:"-"`,
	radius:              f32 `decor:min(0.05)`,
	height:              f32 `decor:min(0.2)`,
	max_slope_deg:       f32 `decor:range(1,89)`,
	step_offset:         f32 `decor:min(0)`,
	skin_width:          f32 `decor:min(0.005)`,
	stick_to_floor_step: f32 `decor:min(0)`,
	mass:                f32 `decor:min(1)`,
	max_strength:        f32 `decor:min(0)`,
	gravity:             f32 `decor:min(0)`,

	desired_velocity:    [3]f32 `json:"-"`,
	velocity:            [3]f32 `json:"-"`,
	is_grounded:         bool   `json:"-"`,
	ground_normal:       [3]f32 `json:"-"`,

	character:           ^jolt.CharacterVirtual `json:"-" inspect:"-"`,
	shape:               ^jolt.Shape            `json:"-" inspect:"-"`,
	last_synced_pos:     [3]f32                 `json:"-" inspect:"-"`,
	has_synced:          bool                   `json:"-" inspect:"-"`,
	built_radius:        f32                    `json:"-" inspect:"-"`,
	built_height:        f32                    `json:"-" inspect:"-"`,
}

reset_CharacterController3D :: proc(cc: ^CharacterController3D) {
	cleanup_CharacterController3D(cc)
	cc.radius              = 0.35
	cc.height              = 1.8
	cc.max_slope_deg       = 45.0
	cc.step_offset         = 0.35
	cc.skin_width          = 0.02
	cc.stick_to_floor_step = 0.4
	cc.mass                = 70.0
	cc.max_strength        = 100.0
	cc.gravity             = 20.0
	cc.ground_normal       = {0, 1, 0}
}

_destroy_character_runtime :: proc(cc: ^CharacterController3D) {
	if cc == nil do return
	if cc.character != nil {
		if _state.world_ready && _state.system != nil {
			inner_id := jolt.CharacterVirtual_GetInnerBodyID(cc.character)
			if is_body_valid(inner_id) {
				delete_key(&_state.char_inner_bodies, inner_id)
			}
			if _state.char_vs_char != nil {
				jolt.CharacterVsCharacterCollisionSimple_RemoveCharacter(_state.char_vs_char, cc.character)
			}
		}
		jolt.CharacterBase_Destroy(auto_cast cc.character)
		cc.character = nil
	}
	delete_key(&_state.char_prev_pos, cc.owner)
	delete_key(&_state.char_curr_pos, cc.owner)
	if cc.shape != nil {
		jolt.Shape_Destroy(cc.shape)
		cc.shape = nil
	}
	cc.has_synced = false
}

cleanup_CharacterController3D :: proc(cc: ^CharacterController3D) {
	_destroy_character_runtime(cc)
	engine.comp_zero(cc)
}

on_destroy_CharacterController3D :: proc(cc: ^CharacterController3D) {
	_destroy_character_runtime(cc)
}

// Sets horizontal movement velocity for the next fixed physics step.
character_move :: proc(cc: ^CharacterController3D, horizontal_vel: [3]f32) {
	if cc == nil do return
	cc.desired_velocity = horizontal_vel
}

// Applies an upward jump impulse if currently grounded.
character_jump :: proc(cc: ^CharacterController3D, jump_speed: f32) {
	if cc == nil || !cc.is_grounded do return
	cc.velocity.y = max(jump_speed, 0.0)
	cc.is_grounded = false
}

_step_character_controllers :: proc(w: ^engine.World, dt: f32) {
	pool := character_controller3_ds(w)
	if pool == nil || !_state.world_ready || _state.system == nil do return

	it := engine.pool_iterator(pool)
	for cc, _ in engine.pool_next(&it) {
		if !cc.enabled || !engine.pool_valid(&w.transforms, engine.Handle(cc.owner)) do continue
		if !engine.transform_active_in_hierarchy(cc.owner) do continue

		r := max(cc.radius, f32(0.05))
		h := max(cc.height, r * 2.0 + 0.1)
		half_cyl := max((h - 2.0 * r) * 0.5, f32(0.05))

		if cc.character != nil && (abs(cc.built_radius - r) > 1e-4 || abs(cc.built_height - h) > 1e-4) {
			_destroy_character_runtime(cc)
		}

		tw := engine.transform_world(cc.owner)
		if cc.character == nil {
			cap_shape := jolt.CapsuleShape_Create(half_cyl, r)
			if cap_shape == nil do continue
			cc.shape = auto_cast cap_shape

			settings: jolt.CharacterVirtualSettings
			jolt.CharacterVirtualSettings_Init(&settings)
			settings.base.up = {0, 1, 0}
			settings.base.maxSlopeAngle = math.to_radians(clamp(cc.max_slope_deg > 0 ? cc.max_slope_deg : 45.0, f32(1.0), f32(89.0)))
			settings.base.enhancedInternalEdgeRemoval = true
			settings.base.shape = cc.shape
			settings.innerBodyShape = cc.shape
			settings.innerBodyLayer = LAYER_CHARACTER
			settings.mass = max(cc.mass, f32(1.0))
			settings.maxStrength = max(cc.max_strength, f32(0.0))
			settings.characterPadding = clamp(cc.skin_width > 0 ? cc.skin_width : f32(0.02), f32(0.005), f32(0.25))

			pos := tw.position
			rot := _world_quat(tw.rotation)
			cc.character = jolt.CharacterVirtual_Create(&settings, &pos, &rot, transmute(u64)engine.Handle(cc.owner), _state.system)
			if cc.character == nil {
				jolt.Shape_Destroy(cc.shape)
				cc.shape = nil
				continue
			}
			if _state.char_vs_char != nil {
				jolt.CharacterVsCharacterCollisionSimple_AddCharacter(_state.char_vs_char, cc.character)
				jolt.CharacterVirtual_SetCharacterVsCharacterCollision(cc.character, _state.char_vs_char)
			}
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			inner_id := jolt.CharacterVirtual_GetInnerBodyID(cc.character)
			if is_body_valid(inner_id) && _state.body_interface != nil {
				jolt.BodyInterface_SetUserData(_state.body_interface, inner_id, transmute(u64)engine.Handle(cc.owner))
				_state.char_inner_bodies[inner_id] = cc.owner
			}
			_state.char_prev_pos[cc.owner] = pos
			_state.char_curr_pos[cc.owner] = pos
			context.allocator = prev_alloc
			cc.built_radius = r
			cc.built_height = h
			cc.last_synced_pos = pos
			cc.has_synced = true
		} else if cc.has_synced && linalg.length2(tw.position - cc.last_synced_pos) > 1e-6 {
			pos := tw.position
			jolt.CharacterVirtual_SetPosition(cc.character, &pos)
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			_state.char_prev_pos[cc.owner] = pos
			_state.char_curr_pos[cc.owner] = pos
			context.allocator = prev_alloc
			cc.last_synced_pos = pos
		}

		time_scale := max(engine.transform_hierarchy_time_scale(cc.owner), f32(0.0))
		char_dt := dt * time_scale
		if char_dt <= 1e-6 {
			continue
		}

		if cc.is_grounded && cc.velocity.y < 0.0 {
			cc.velocity.y = 0.0
		} else {
			cc.velocity.y -= max(cc.gravity, f32(0.0)) * char_dt
		}

		move_vel := [3]f32{cc.desired_velocity.x, cc.velocity.y, cc.desired_velocity.z}
		jolt.CharacterVirtual_SetLinearVelocity(cc.character, &move_vel)

		stick_down := max(cc.stick_to_floor_step, f32(0.0)) * clamp(time_scale, 0.05, 1.0)
		ext := jolt.ExtendedUpdateSettings{
			stickToFloorStepDown             = {0, -stick_down, 0},
			walkStairsStepUp                 = {0, max(cc.step_offset, f32(0.0)), 0},
			walkStairsMinStepForward         = 0.02,
			walkStairsStepForwardTest        = 0.15,
			walkStairsCosAngleForwardContact = math.cos(math.to_radians(f32(75.0))),
		}
		jolt.CharacterVirtual_ExtendedUpdate(cc.character, char_dt, &ext, LAYER_CHARACTER, _state.system, _state.char_body_filter, nil)

		out_pos: jolt.RVec3
		out_vel: jolt.Vec3
		out_n: jolt.Vec3
		jolt.CharacterVirtual_GetPosition(cc.character, &out_pos)
		jolt.CharacterVirtual_GetLinearVelocity(cc.character, &out_vel)
		jolt.CharacterBase_GetGroundNormal(auto_cast cc.character, &out_n)

		cc.velocity = out_vel
		cc.is_grounded = jolt.CharacterBase_IsSupported(auto_cast cc.character)
		cc.ground_normal = linalg.length2(out_n) > 1e-6 ? out_n : [3]f32{0, 1, 0}

		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		prev_p := out_pos
		if cur_p, has_cur := _state.char_curr_pos[cc.owner]; has_cur && linalg.length2(out_pos - cur_p) <= 25.0 {
			prev_p = cur_p
		}
		_state.char_prev_pos[cc.owner] = prev_p
		_state.char_curr_pos[cc.owner] = out_pos
		context.allocator = prev_alloc

		engine.transform_set_world_position(cc.owner, out_pos)
		cc.last_synced_pos = out_pos
		cc.has_synced = true
	}
}
