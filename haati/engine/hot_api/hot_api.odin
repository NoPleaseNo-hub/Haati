package hot_api

// =============================================================================
// MOONHUG TYPEID-SAFE C-ABI HOT CARTRIDGE INTERFACE (`Engine_Hot_API`)
// =============================================================================
// Zero-dependency leaf package shared between `MoonHug.exe` / standalone `app.exe`
// and hot-reloaded `builds/hot_cartridge_<N>.dll` cartridges.
//
// CRITICAL INVARIANT (docs/Plugins.md):
// Odin generates an independent RTTI `_type_table` per DLL, so `typeid` and `any`
// MUST NEVER cross this boundary. Everything here uses plain C-ABI value structs,
// explicit typed pointers (`^f32`, `^[3]f32`, `rawptr` resolved by 16-byte `Type_GUID`),
// and `proc "c"` function pointers owned by the host executable.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"

ENGINE_HOT_API_VERSION :: u32(3)
HOT_MAX_ARGS           :: 16
HOT_MAX_STRUCT_BYTES   :: 64

// ABI-stable 8-byte entity/transform reference (independent of generated `TypeKey` enum size).
Hot_Entity :: struct {
	index:      u32,
	generation: u16,
	_pad:       u16,
}

// Parameter passing discipline for Niagara Visual Script & Scoped Odin Function Nodes.
Hot_Pass_Mode :: enum u8 {
	Copy_Value   = 0, // `●` Passes an isolated value copy (`T`)
	By_Reference = 1, // `◆` Passes a mutable pointer (`^T`) to an addressable variable/field
}

Hot_Pin_Type :: enum u8 {
	Exec       = 0,
	Bool       = 1,
	Int        = 2,
	Float      = 3,
	Vec3       = 4,
	Quat       = 5,
	Entity     = 6,
	Delegate   = 7,  // `◇` Hot-swap-safe Odin Delegate / Blueprint Procedure reference (`Hot_Delegate`)
	Vec2       = 8,  // `[2]f32` 2D input / movement / look vector
	Vec4       = 9,  // `[4]f32` RGBA / Vector4
	Int64      = 10, // `i64` 64-bit integer / timestamp / ID
	String     = 11, // `cstring` C-ABI string literal / identifier
	Asset      = 12, // `cstring` Asset path / GUID string
	// V3 Native Odin Bit-Widths, Enums, BitSets & POD Structs (Ordinals 13..22 appended cleanly)
	U8         = 13, // `u8` / `byte` (0..255)
	I8         = 14, // `i8` (-128..127)
	U16        = 15, // `u16` (0..65535)
	I16        = 16, // `i16` (-32768..32767)
	U32        = 17, // `u32` (32-bit unsigned)
	U64        = 18, // `u64` (64-bit unsigned)
	F64        = 19, // `f64` double-precision float
	Enum_U8    = 20, // User-declared Odin `enum u8`
	BitSet_U8  = 21, // User-declared Odin `bit_set[MyEnum; u8]` (1-byte bitfield mask)
	Struct_Val = 22, // User-declared POD `struct` value (inline bytes in `val_bytes`)
	Raw_Ptr    = 23, // Untyped 64-bit memory address (`rawptr`) — zero-cost castable
}

// Input action / debug key trigger edge for `Bind Input Action` & `Bind Debug Key`.
Hot_Trigger_Edge :: enum u8 {
	Pressed  = 0,
	Released = 1,
	Both     = 2,
}

// 16-byte POD Odin-style Delegate handle (`size_of == 16`).
// Stores `_hot_reg` slot index (`proc_slot`) + Tier-1 `node_uid` instead of raw function
// pointers so pressing `F7` to hot-swap `hot_cartridge_<N>.dll` mid-Play-Mode routes all
// already-bound input & custom delegates to the newly compiled machine code with 0 dangling ptrs!
Hot_Delegate :: struct {
	entity:    Hot_Entity,
	proc_slot: i32,
	node_uid:  i32,
}

// Universal C-ABI slot carrying BOTH Copy-by-Value (`val_*`) AND Pass-by-Reference (`ref_ptr`)
// arguments across `Hot_Proc_Fn` calls without `any` or `typeid`.
Hot_Slot :: struct {
	pin_type:     Hot_Pin_Type,
	pass_mode:    Hot_Pass_Mode,
	val_u8:       u8,
	val_i8:       i8,
	val_bool:     bool,
	val_byte_len: u8,
	val_u16:      u16,
	val_i16:      i16,
	_pad_s:       [2]u8,
	val_int:      i32,
	val_u32:      u32,
	val_f32:      f32,
	val_vec2:     [2]f32,
	val_vec3:     [3]f32,
	val_quat:     [4]f32,
	val_vec4:     [4]f32,
	val_i64:      i64,
	val_u64:      u64,
	val_f64:      f64,
	val_cstr:     cstring,
	val_ent:      Hot_Entity,
	val_delegate: Hot_Delegate,
	val_bytes:    [HOT_MAX_STRUCT_BYTES]u8, // Inline value bytes for small POD `Struct_Val` slots
	ref_ptr:      rawptr,                   // Non-nil when `pass_mode == .By_Reference` (`^T`) or `[]T` data ptr
	val_ptr:      rawptr,                   // Untyped 64-bit `rawptr` value when `pin_type == .Raw_Ptr`
	slice_len:    i32,                      // Element count when slot carries a zero-copy `[]T` or `[dynamic]T` view
	slice_cap:    i32,                      // Capacity (`< 0` for read/write slice views)
}

Hot_Call_Frame :: struct {
	inputs:       [HOT_MAX_ARGS]Hot_Slot,
	outputs:      [HOT_MAX_ARGS]Hot_Slot,
	input_count:  i32,
	output_count: i32,
	user_data:    rawptr,
}

Hot_Raycast_Hit :: struct {
	hit:      bool,
	channel:  u8,
	_pad:     [2]u8,
	entity:   Hot_Entity,
	position: [3]f32,
	normal:   [3]f32,
	distance: f32,
	fraction: f32,
}

// Self-describing pin signature emitted by `hot_cartridge_gen` for `@(bp_node)` and `@(hot_proc)` procs.
Hot_Proc_Pin_Meta :: struct {
	name:         string,
	pin_type:     Hot_Pin_Type,
	is_output:    bool,
	by_ref:       bool,
	default_f32:  f32,
	default_i64:  i64,
	default_bool: bool,
	custom_type:  string,
}

Hot_Proc_Sig_Meta :: struct {
	proc_name:         string, // Canonical callable `@(hot_proc)` name (e.g. `__bpwrap_bp_remap_clamped` or `hot_harmonic_hover`)
	display_title:     string,
	namespace_name:    string,
	doc_comment:       string,
	source_proc_name:  string, // Original typed Odin proc name (e.g. `bp_remap_clamped`)
	is_pure:           bool,
	pins:              []Hot_Proc_Pin_Meta,
}

// Host-owned C-ABI function table passed into every `@(hot_proc)` and transpiled `.mhgraph` / `.bodin`.
Engine_Hot_API :: struct {
	version: u32,
	host_world: rawptr, // Opaque `^engine.World` for host-side callbacks only

	// Entity & Transform Queries / Mutations
	entity_valid:        proc "c" (self: Hot_Entity) -> bool,
	get_local_position:  proc "c" (self: Hot_Entity) -> [3]f32,
	set_local_position:  proc "c" (self: Hot_Entity, pos: [3]f32),
	ptr_local_position:  proc "c" (self: Hot_Entity) -> ^[3]f32, // Direct addressable `^[3]f32` for `◆ ^Ref` pins!
	get_local_rotation:  proc "c" (self: Hot_Entity) -> [4]f32,
	set_local_rotation:  proc "c" (self: Hot_Entity, rot: [4]f32),
	ptr_local_rotation:  proc "c" (self: Hot_Entity) -> ^[4]f32,
	get_local_scale:     proc "c" (self: Hot_Entity) -> [3]f32,
	set_local_scale:     proc "c" (self: Hot_Entity, scl: [3]f32),
	ptr_local_scale:     proc "c" (self: Hot_Entity) -> ^[3]f32,
	get_world_position:  proc "c" (self: Hot_Entity) -> [3]f32,
	get_forward:         proc "c" (self: Hot_Entity) -> [3]f32,
	get_up:              proc "c" (self: Hot_Entity) -> [3]f32,
	get_right:           proc "c" (self: Hot_Entity) -> [3]f32,

	// Unreal-Style Global & Per-Object TimeScale Controls
	get_time_scale:        proc "c" () -> f32,
	set_time_scale:        proc "c" (scale: f32),
	get_object_dt:         proc "c" (self: Hot_Entity, raw_dt: f32) -> f32,
	get_object_time_scale: proc "c" (self: Hot_Entity) -> f32,
	set_object_time_scale: proc "c" (self: Hot_Entity, scale: f32),

	// `typeid`-Free Component Raw Pointer Lookup by 16-byte `Type_GUID`
	get_component_by_guid: proc "c" (self: Hot_Entity, guid: [16]u8) -> rawptr,

	// Console Logging
	log_info: proc "c" (msg: cstring),

	// V2: Odin-Style Hot-Swap-Safe Delegate, Input Binding & Persistent Blueprint State API
	resolve_proc_slot:         proc "c" (proc_name: cstring) -> i32,
	bind_input_action:         proc "c" (self: Hot_Entity, action_name: cstring, trigger: Hot_Trigger_Edge, priority: i32, consume: bool, target_proc: cstring) -> u32,
	unbind_input_action:       proc "c" (self: Hot_Entity, action_name: cstring),
	bind_input_vector:         proc "c" (self: Hot_Entity, is_look: bool, priority: i32, consume: bool, target_proc: cstring) -> u32,
	unbind_input_vector:       proc "c" (self: Hot_Entity, is_look: bool),
	bind_debug_key:            proc "c" (self: Hot_Entity, key_code: i32, trigger: Hot_Trigger_Edge, target_proc: cstring) -> u32,
	unbind_debug_key:          proc "c" (self: Hot_Entity, key_code: i32),
	unbind_all_inputs:         proc "c" (self: Hot_Entity),
	bind_custom_delegate:      proc "c" (self: Hot_Entity, delegate_name: cstring, target_proc: cstring),
	unbind_custom_delegate:    proc "c" (self: Hot_Entity, delegate_name: cstring),
	broadcast_custom_delegate: proc "c" (self: Hot_Entity, delegate_name: cstring, payload_f32: f32),
	get_blueprint_var_ptr:     proc "c" (self: Hot_Entity, var_index: i32) -> rawptr,

	// V3: Persistent Struct/Array POD Blobs, Timers, Safety Fuse & Gameplay Package Bridges
	var_blob_ptr:          proc "c" (self: Hot_Entity, var_name: cstring, byte_size: i32) -> rawptr,
	var_ptr_raw:           proc "c" (self: Hot_Entity, var_name: cstring, pin_type: Hot_Pin_Type) -> rawptr,
	timer_step:            proc "c" (self: Hot_Entity, node_uid: u32, duration: f32, dt: f32, reset: bool, is_cooldown: bool, out_remaining: ^f32) -> bool,
	report_loop_fuse:      proc "c" (self: Hot_Entity, node_uid: u32),
	spawn_prefab:          proc "c" (prefab_guid_str: cstring, world_pos: [3]f32, world_rot: [4]f32) -> Hot_Entity,
	destroy_entity:        proc "c" (target: Hot_Entity),
	ai_find_path_move:     proc "c" (self: Hot_Entity, goal_pos: [3]f32) -> bool,
	ai_check_arrival:      proc "c" (self: Hot_Entity, goal_pos: [3]f32, accept_radius: f32) -> bool,
	physics_raycast:       proc "c" (ignore_self: Hot_Entity, origin: [3]f32, dir: [3]f32, max_dist: f32, channel_mask: u32, out_hit: ^Hot_Raycast_Hit) -> bool,
	physics_overlap_sphere: proc "c" (ignore_self: Hot_Entity, center: [3]f32, radius: f32, channel_mask: u32, out_closest: ^Hot_Entity) -> i32,
	physics_add_impulse:   proc "c" (target: Hot_Entity, impulse: [3]f32, is_vel_change: bool),
	audio_play_spatial_3d: proc "c" (self: Hot_Entity, cue_str: cstring, world_pos: [3]f32, volume: f32, pitch: f32),
	audio_set_bus_send:    proc "c" (bus_name: cstring, send_level: f32, lowpass_hz: f32),
	vfx_emitter_spawn:     proc "c" (self: Hot_Entity, vfx_str: cstring, spawn_rate: f32, burst_count: i32),
	anim_set_ik_target:    proc "c" (self: Hot_Entity, effector_name: cstring, world_target: [3]f32, weight: f32),
	csg_stamp_brush:       proc "c" (world_pos: [3]f32, radius: f32, impulse: f32, cut_mat_str: cstring) -> i32,
	get_unscaled_dt:       proc "c" () -> f32,

	// V4: Host allocators, Sandbox Fault Capture, and Dynamic Float Sequence Bridge
	host_allocator:        runtime.Allocator,
	host_temp_allocator:   runtime.Allocator,
	report_sandbox_fault:  proc "c" (msg: cstring, file: cstring, proc_name: cstring, line: i32),
	var_f32_seq_ptr:       proc "c" (self: Hot_Entity, var_name: cstring, out_len: ^i32, out_cap: ^i32) -> ^f32,
	var_f32_seq_sync:      proc "c" (self: Hot_Entity, var_name: cstring, data: ^f32, length: i32, capacity: i32),

	// V5: Universal Zero-Copy Strided Sequence Bridge (`[]T` / `[dynamic]T` for ANY Odin type/struct)
	var_seq_ptr:           proc "c" (self: Hot_Entity, var_name: cstring, elem_size: i32, elem_align: i32, out_len: ^i32, out_cap: ^i32) -> rawptr,
	var_seq_sync:          proc "c" (self: Hot_Entity, var_name: cstring, data: rawptr, elem_size: i32, elem_align: i32, length: i32, capacity: i32),
}

// Canonical C-ABI entry signature for every hot-swappable procedure & transpiled `.mhgraph`.
Hot_Proc_Fn :: #type proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, dt: f32, frame: ^Hot_Call_Frame)

// Exported query proc inside `builds/hot_cartridge_<N>.dll`.
Hot_Cartridge_Query_Fn :: #type proc "c" (index: i32, out_name: ^cstring, out_fn: ^Hot_Proc_Fn) -> bool

// =============================================================================
// Ergonomic `contextless` Helpers for Scoped Odin Function Nodes & Hot Scripts
// =============================================================================

get_pos :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity) -> [3]f32 {
	if api == nil || api.get_local_position == nil do return {}
	return api.get_local_position(e)
}

set_pos :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity, p: [3]f32) {
	if api != nil && api.set_local_position != nil {
		api.set_local_position(e, p)
	}
}

pos_ref :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity) -> ^[3]f32 {
	if api == nil || api.ptr_local_position == nil do return nil
	return api.ptr_local_position(e)
}

get_rot :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity) -> [4]f32 {
	if api == nil || api.get_local_rotation == nil do return {0, 0, 0, 1}
	return api.get_local_rotation(e)
}

set_rot :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity, q: [4]f32) {
	if api != nil && api.set_local_rotation != nil {
		api.set_local_rotation(e, q)
	}
}

get_scale :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity) -> [3]f32 {
	if api == nil || api.get_local_scale == nil do return {1, 1, 1}
	return api.get_local_scale(e)
}

set_scale :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity, s: [3]f32) {
	if api != nil && api.set_local_scale != nil {
		api.set_local_scale(e, s)
	}
}

set_object_timescale :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity, s: f32) {
	if api != nil && api.set_object_time_scale != nil {
		api.set_object_time_scale(e, s)
	}
}

get_time_scale :: #force_inline proc "c" (api: ^Engine_Hot_API) -> f32 {
	if api == nil || api.get_time_scale == nil do return 1.0
	return api.get_time_scale()
}

set_time_scale :: #force_inline proc "c" (api: ^Engine_Hot_API, scale: f32) {
	if api != nil && api.set_time_scale != nil {
		api.set_time_scale(scale)
	}
}

get_unscaled_dt :: #force_inline proc "c" (api: ^Engine_Hot_API) -> f32 {
	if api == nil || api.get_unscaled_dt == nil do return 0.0
	return api.get_unscaled_dt()
}

get_object_timescale :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity) -> f32 {
	if api == nil || api.get_object_time_scale == nil do return 1.0
	return api.get_object_time_scale(e)
}

get_object_dt :: #force_inline proc "c" (api: ^Engine_Hot_API, e: Hot_Entity, raw_dt: f32) -> f32 {
	if api == nil || api.get_object_dt == nil do return raw_dt
	return api.get_object_dt(e, raw_dt)
}

damp_f32 :: #force_inline proc "c" (current, target, speed, dt: f32) -> f32 {
	return linalg.lerp(current, target, 1.0 - math.exp(-max(speed, 0.0) * max(dt, 0.0)))
}

damp_vec2 :: #force_inline proc "c" (current, target: [2]f32, lambda, dt: f32) -> [2]f32 {
	alpha := 1.0 - math.exp(-max(lambda, 0.0) * max(dt, 0.0))
	return linalg.lerp(current, target, alpha)
}

damp_vec3 :: #force_inline proc "c" (current, target: [3]f32, speed, dt: f32) -> [3]f32 {
	alpha := 1.0 - math.exp(-max(speed, 0.0) * max(dt, 0.0))
	return linalg.lerp(current, target, alpha)
}

damp_quat :: #force_inline proc "c" (current, target: quaternion128, lambda, dt: f32) -> quaternion128 {
	alpha := 1.0 - math.exp(-max(lambda, 0.0) * max(dt, 0.0))
	dot := current.x * target.x + current.y * target.y + current.z * target.z + current.w * target.w
	t := target
	if dot < 0.0 {
		t = -target
	}
	res := quaternion(
		x = math.lerp(current.x, t.x, alpha),
		y = math.lerp(current.y, t.y, alpha),
		z = math.lerp(current.z, t.z, alpha),
		w = math.lerp(current.w, t.w, alpha),
	)
	mag := math.sqrt(res.x * res.x + res.y * res.y + res.z * res.z + res.w * res.w)
	if mag > 1e-8 {
		inv := 1.0 / mag
		return quaternion(x = res.x * inv, y = res.y * inv, z = res.z * inv, w = res.w * inv)
	}
	return quaternion(x = f32(0), y = f32(0), z = f32(0), w = f32(1))
}

spring_f32_critically_damped :: #force_inline proc "c" (val: ^f32, vel: ^f32, target: f32, omega: f32, dt: f32) {
	if val == nil || vel == nil || dt <= 0.0 do return
	w := max(omega, f32(0.001))
	x := val^ - target
	v := vel^
	exp_term := math.exp(-w * dt)
	temp := (v + w * x) * dt
	val^ = target + (x + temp) * exp_term
	vel^ = (v - w * temp) * exp_term
}

spring_vec3_critically_damped :: #force_inline proc "c" (val: ^[3]f32, vel: ^[3]f32, target: [3]f32, omega: f32, dt: f32) {
	if val == nil || vel == nil || dt <= 0.0 do return
	w := max(omega, f32(0.001))
	x := val^ - target
	v := vel^
	exp_term := math.exp(-w * dt)
	temp := (v + w * x) * dt
	val^ = target + (x + temp) * exp_term
	vel^ = (v - w * temp) * exp_term
}

// Slot readers/writers used by transpiled `.mhgraph` / `.bodin` wrappers to unpack `● Copy` vs `◆ ^Ref` pins cleanly.
slot_read_f32 :: #force_inline proc "c" (s: ^Hot_Slot) -> f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^f32)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .F64:              return f32(s.val_f64)
	case .Int:              return f32(s.val_int)
	case .Int64:            return f32(s.val_i64)
	case .U8, .Enum_U8, .BitSet_U8: return f32(s.val_u8)
	case .I8:               return f32(s.val_i8)
	case .U16:              return f32(s.val_u16)
	case .I16:              return f32(s.val_i16)
	case .U32:              return f32(s.val_u32)
	case .U64:              return f32(s.val_u64)
	case .Bool:             return s.val_bool ? 1.0 : 0.0
	}
	return s.val_f32
}

slot_ref_f32 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^f32)s.ref_ptr
	}
	return &s.val_f32
}

slot_read_f64 :: #force_inline proc "c" (s: ^Hot_Slot) -> f64 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^f64)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .F64:              return s.val_f64
	case .Float:            return f64(s.val_f32)
	case .Int:              return f64(s.val_int)
	case .Int64:            return f64(s.val_i64)
	case .U8, .Enum_U8, .BitSet_U8: return f64(s.val_u8)
	case .I8:               return f64(s.val_i8)
	case .U16:              return f64(s.val_u16)
	case .I16:              return f64(s.val_i16)
	case .U32:              return f64(s.val_u32)
	case .U64:              return f64(s.val_u64)
	case .Bool:             return s.val_bool ? 1.0 : 0.0
	}
	return s.val_f64 != 0 ? s.val_f64 : f64(s.val_f32)
}

slot_ref_f64 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^f64 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^f64)s.ref_ptr
	}
	return &s.val_f64
}

slot_read_vec3 :: #force_inline proc "c" (s: ^Hot_Slot) -> [3]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^[3]f32)s.ref_ptr)^
	}
	if s.pin_type == .Vec2 do return {s.val_vec2.x, s.val_vec2.y, 0}
	if s.pin_type == .Vec4 do return {s.val_vec4.x, s.val_vec4.y, s.val_vec4.z}
	return s.val_vec3
}

slot_ref_vec3 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^[3]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^[3]f32)s.ref_ptr
	}
	return &s.val_vec3
}

slot_read_bool :: #force_inline proc "c" (s: ^Hot_Slot) -> bool {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^bool)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .Float:                    return s.val_f32 != 0.0
	case .F64:                      return s.val_f64 != 0.0
	case .Int:                      return s.val_int != 0
	case .Int64:                    return s.val_i64 != 0
	case .U8, .Enum_U8, .BitSet_U8: return s.val_u8 != 0
	case .I8:                       return s.val_i8 != 0
	case .U16:                      return s.val_u16 != 0
	case .I16:                      return s.val_i16 != 0
	case .U32:                      return s.val_u32 != 0
	case .U64:                      return s.val_u64 != 0
	}
	return s.val_bool
}

slot_ref_bool :: #force_inline proc "c" (s: ^Hot_Slot) -> ^bool {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^bool)s.ref_ptr
	}
	return &s.val_bool
}

slot_read_int :: #force_inline proc "c" (s: ^Hot_Slot) -> i32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^i32)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .U8, .Enum_U8, .BitSet_U8: return i32(s.val_u8)
	case .I8:               return i32(s.val_i8)
	case .U16:              return i32(s.val_u16)
	case .I16:              return i32(s.val_i16)
	case .U32:              return i32(s.val_u32)
	case .Int64:            return i32(s.val_i64)
	case .U64:              return i32(s.val_u64)
	case .Float:            return i32(s.val_f32)
	case .F64:              return i32(s.val_f64)
	case .Bool:             return s.val_bool ? 1 : 0
	}
	return s.val_int
}

slot_ref_int :: #force_inline proc "c" (s: ^Hot_Slot) -> ^i32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^i32)s.ref_ptr
	}
	return &s.val_int
}

slot_read_i32 :: slot_read_int
slot_ref_i32  :: slot_ref_int

slot_read_u8 :: #force_inline proc "c" (s: ^Hot_Slot) -> u8 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^u8)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .U8, .Enum_U8, .BitSet_U8: return s.val_u8
	case .I8:   return u8(clamp(i32(s.val_i8), 0, 255))
	case .U16:  return u8(min(u32(s.val_u16), 255))
	case .I16:  return u8(clamp(i32(s.val_i16), 0, 255))
	case .Int:  return u8(clamp(s.val_int, 0, 255))
	case .U32:  return u8(min(s.val_u32, 255))
	case .Int64:return u8(clamp(s.val_i64, 0, 255))
	case .U64:  return u8(min(s.val_u64, 255))
	case .Float:return u8(clamp(s.val_f32, 0.0, 255.0))
	case .F64:  return u8(clamp(s.val_f64, 0.0, 255.0))
	case .Bool: return s.val_bool ? 1 : 0
	}
	return s.val_u8
}

slot_ref_u8 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^u8 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^u8)s.ref_ptr
	}
	return &s.val_u8
}

slot_read_i8 :: #force_inline proc "c" (s: ^Hot_Slot) -> i8 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^i8)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .I8:   return s.val_i8
	case .U8, .Enum_U8, .BitSet_U8: return i8(min(i32(s.val_u8), 127))
	case .Int:  return i8(clamp(s.val_int, -128, 127))
	case .Int64:return i8(clamp(s.val_i64, -128, 127))
	case .Float:return i8(clamp(s.val_f32, -128.0, 127.0))
	case .F64:  return i8(clamp(s.val_f64, -128.0, 127.0))
	}
	return s.val_i8
}

slot_ref_i8 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^i8 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^i8)s.ref_ptr
	}
	return &s.val_i8
}

slot_read_u16 :: #force_inline proc "c" (s: ^Hot_Slot) -> u16 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^u16)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .U16:  return s.val_u16
	case .U8, .Enum_U8, .BitSet_U8: return u16(s.val_u8)
	case .Int:  return u16(clamp(s.val_int, 0, 65535))
	case .Int64:return u16(clamp(s.val_i64, 0, 65535))
	case .U32:  return u16(min(s.val_u32, 65535))
	case .U64:  return u16(min(s.val_u64, 65535))
	case .Float:return u16(clamp(s.val_f32, 0.0, 65535.0))
	case .F64:  return u16(clamp(s.val_f64, 0.0, 65535.0))
	}
	return s.val_u16
}

slot_ref_u16 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^u16 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^u16)s.ref_ptr
	}
	return &s.val_u16
}

slot_read_i16 :: #force_inline proc "c" (s: ^Hot_Slot) -> i16 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^i16)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .I16:  return s.val_i16
	case .I8:   return i16(s.val_i8)
	case .U8, .Enum_U8, .BitSet_U8: return i16(s.val_u8)
	case .Int:  return i16(clamp(s.val_int, -32768, 32767))
	case .Int64:return i16(clamp(s.val_i64, -32768, 32767))
	case .Float:return i16(clamp(s.val_f32, -32768.0, 32767.0))
	case .F64:  return i16(clamp(s.val_f64, -32768.0, 32767.0))
	}
	return s.val_i16
}

slot_ref_i16 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^i16 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^i16)s.ref_ptr
	}
	return &s.val_i16
}

slot_read_u32 :: #force_inline proc "c" (s: ^Hot_Slot) -> u32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^u32)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .U32:  return s.val_u32
	case .U8, .Enum_U8, .BitSet_U8: return u32(s.val_u8)
	case .U16:  return u32(s.val_u16)
	case .Int:  return u32(max(s.val_int, 0))
	case .Int64:return u32(clamp(s.val_i64, 0, i64(max(u32))))
	case .U64:  return u32(min(s.val_u64, u64(max(u32))))
	case .Float:return u32(max(s.val_f32, 0.0))
	case .F64:  return u32(max(s.val_f64, 0.0))
	}
	return s.val_u32
}

slot_ref_u32 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^u32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^u32)s.ref_ptr
	}
	return &s.val_u32
}

slot_read_u64 :: #force_inline proc "c" (s: ^Hot_Slot) -> u64 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^u64)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .U64:  return s.val_u64
	case .U8, .Enum_U8, .BitSet_U8: return u64(s.val_u8)
	case .U16:  return u64(s.val_u16)
	case .U32:  return u64(s.val_u32)
	case .Int:  return u64(max(s.val_int, 0))
	case .Int64:return u64(max(s.val_i64, 0))
	case .Float:return u64(max(s.val_f32, 0.0))
	case .F64:  return u64(max(s.val_f64, 0.0))
	}
	return s.val_u64
}

slot_ref_u64 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^u64 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^u64)s.ref_ptr
	}
	return &s.val_u64
}

slot_read_vec2 :: #force_inline proc "c" (s: ^Hot_Slot) -> [2]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^[2]f32)s.ref_ptr)^
	}
	if s.pin_type == .Vec3 do return {s.val_vec3.x, s.val_vec3.y}
	if s.pin_type == .Vec4 do return {s.val_vec4.x, s.val_vec4.y}
	return s.val_vec2
}

slot_ref_vec2 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^[2]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^[2]f32)s.ref_ptr
	}
	return &s.val_vec2
}

slot_read_delegate :: #force_inline proc "c" (s: ^Hot_Slot) -> Hot_Delegate {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^Hot_Delegate)s.ref_ptr)^
	}
	return s.val_delegate
}

slot_read_vec4 :: #force_inline proc "c" (s: ^Hot_Slot) -> [4]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^[4]f32)s.ref_ptr)^
	}
	if s.pin_type == .Vec3 do return {s.val_vec3.x, s.val_vec3.y, s.val_vec3.z, 1.0}
	if s.pin_type == .Vec2 do return {s.val_vec2.x, s.val_vec2.y, 0.0, 1.0}
	return s.val_vec4
}

slot_ref_vec4 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^[4]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^[4]f32)s.ref_ptr
	}
	return &s.val_vec4
}

slot_read_i64 :: #force_inline proc "c" (s: ^Hot_Slot) -> i64 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^i64)s.ref_ptr)^
	}
	#partial switch s.pin_type {
	case .Int:  return i64(s.val_int)
	case .U8, .Enum_U8, .BitSet_U8: return i64(s.val_u8)
	case .I8:   return i64(s.val_i8)
	case .U16:  return i64(s.val_u16)
	case .I16:  return i64(s.val_i16)
	case .U32:  return i64(s.val_u32)
	case .U64:  return i64(s.val_u64)
	case .Float:return i64(s.val_f32)
	case .F64:  return i64(s.val_f64)
	case .Bool: return s.val_bool ? 1 : 0
	}
	return s.val_i64
}

slot_ref_i64 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^i64 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^i64)s.ref_ptr
	}
	return &s.val_i64
}

slot_read_quat :: #force_inline proc "c" (s: ^Hot_Slot) -> [4]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^[4]f32)s.ref_ptr)^
	}
	return s.val_quat
}

slot_ref_quat :: #force_inline proc "c" (s: ^Hot_Slot) -> ^[4]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^[4]f32)s.ref_ptr
	}
	return &s.val_quat
}

slot_read_entity :: #force_inline proc "c" (s: ^Hot_Slot) -> Hot_Entity {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^Hot_Entity)s.ref_ptr)^
	}
	return s.val_ent
}

slot_ref_entity :: #force_inline proc "c" (s: ^Hot_Slot) -> ^Hot_Entity {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^Hot_Entity)s.ref_ptr
	}
	return &s.val_ent
}

slot_read_cstr :: #force_inline proc "c" (s: ^Hot_Slot) -> cstring {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		res := (cast(^cstring)s.ref_ptr)^
		return res != nil ? res : ""
	}
	return s.val_cstr != nil ? s.val_cstr : ""
}

slot_ref_struct_bytes :: #force_inline proc "c" (s: ^Hot_Slot) -> rawptr {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return s.ref_ptr
	}
	return &s.val_bytes[0]
}

slot_read_rawptr :: #force_inline proc "c" (s: ^Hot_Slot) -> rawptr {
	if s == nil do return nil
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		if s.pin_type == .Raw_Ptr {
			return (cast(^rawptr)s.ref_ptr)^
		}
		return s.ref_ptr
	}
	return s.val_ptr != nil ? s.val_ptr : s.ref_ptr
}

slot_ref_rawptr :: #force_inline proc "c" (s: ^Hot_Slot) -> ^rawptr {
	if s == nil do return nil
	if s.pass_mode == .By_Reference && s.ref_ptr != nil && s.pin_type == .Raw_Ptr {
		return cast(^rawptr)s.ref_ptr
	}
	return &s.val_ptr
}

slot_read_slice_raw :: #force_inline proc "c" (s: ^Hot_Slot) -> (data: rawptr, length: i32) {
	if s == nil do return nil, 0
	return s.ref_ptr, max(s.slice_len, 0)
}

// Fast sanity check for raw pointers before dereferencing across `.Raw_Ptr` casts.
validate_raw_ptr :: #force_inline proc "c" (p: rawptr, min_align: uintptr = 1) -> (ok: bool, reason: cstring) {
	addr := uintptr(p)
	if p == nil do return false, "nil pointer (address 0x0)"
	if addr < 0x10000 do return false, "null-page guard address (< 0x10000)"
	if addr > 0x00007FFFFFFFFFFF do return false, "non-canonical or kernel-range pointer address (> 0x7FFFFFFFFFFF)"
	if min_align > 1 && (addr & (min_align - 1)) != 0 {
		return false, "misaligned memory address for target type"
	}
	return true, ""
}

// Ergonomic V2 Odin-Style Delegate & Input Binding Helpers
bind_action :: #force_inline proc "c" (
	api:         ^Engine_Hot_API,
	self:        Hot_Entity,
	action_name: cstring,
	target_proc: cstring,
	trigger:     Hot_Trigger_Edge = .Pressed,
	priority:    i32              = 10,
	consume:     bool             = false,
) -> u32 {
	if api == nil || api.bind_input_action == nil do return 0
	return api.bind_input_action(self, action_name, trigger, priority, consume, target_proc)
}

unbind_action :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, action_name: cstring) {
	if api != nil && api.unbind_input_action != nil {
		api.unbind_input_action(self, action_name)
	}
}

bind_vector :: #force_inline proc "c" (
	api:         ^Engine_Hot_API,
	self:        Hot_Entity,
	is_look:     bool,
	target_proc: cstring,
	priority:    i32  = 10,
	consume:     bool = false,
) -> u32 {
	if api == nil || api.bind_input_vector == nil do return 0
	return api.bind_input_vector(self, is_look, priority, consume, target_proc)
}

unbind_vector :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, is_look: bool) {
	if api != nil && api.unbind_input_vector != nil {
		api.unbind_input_vector(self, is_look)
	}
}

bind_debug_key :: #force_inline proc "c" (
	api:         ^Engine_Hot_API,
	self:        Hot_Entity,
	key_code:    i32,
	target_proc: cstring,
	trigger:     Hot_Trigger_Edge = .Pressed,
) -> u32 {
	if api == nil || api.bind_debug_key == nil do return 0
	return api.bind_debug_key(self, key_code, trigger, target_proc)
}

unbind_debug_key :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, key_code: i32) {
	if api != nil && api.unbind_debug_key != nil {
		api.unbind_debug_key(self, key_code)
	}
}

unbind_all :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity) {
	if api != nil && api.unbind_all_inputs != nil {
		api.unbind_all_inputs(self)
	}
}

bind_delegate :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, delegate_name: cstring, target_proc: cstring) {
	if api != nil && api.bind_custom_delegate != nil {
		api.bind_custom_delegate(self, delegate_name, target_proc)
	}
}

unbind_delegate :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, delegate_name: cstring) {
	if api != nil && api.unbind_custom_delegate != nil {
		api.unbind_custom_delegate(self, delegate_name)
	}
}

broadcast_delegate :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, delegate_name: cstring, payload_f32: f32 = 0.0) {
	if api != nil && api.broadcast_custom_delegate != nil {
		api.broadcast_custom_delegate(self, delegate_name, payload_f32)
	}
}

var_ptr :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_index: i32) -> rawptr {
	if api == nil || api.get_blueprint_var_ptr == nil do return nil
	return api.get_blueprint_var_ptr(self, var_index)
}

var_blob_ptr :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_name: cstring, byte_size: int) -> rawptr {
	if api == nil || api.var_blob_ptr == nil do return nil
	return api.var_blob_ptr(self, var_name, i32(byte_size))
}

var_ptr_raw :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_name: cstring, pin_type: Hot_Pin_Type) -> rawptr {
	if api == nil || api.var_ptr_raw == nil do return nil
	return api.var_ptr_raw(self, var_name, pin_type)
}

timer_step :: #force_inline proc "c" (
	api:           ^Engine_Hot_API,
	self:          Hot_Entity,
	node_uid:      u32,
	duration:      f32,
	dt:            f32,
	reset:         bool,
	is_cooldown:   bool,
	out_remaining: ^f32 = nil,
) -> bool {
	if api == nil || api.timer_step == nil do return true
	return api.timer_step(self, node_uid, duration, dt, reset, is_cooldown, out_remaining)
}

report_loop_fuse :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, node_uid: u32) {
	if api != nil && api.report_loop_fuse != nil {
		api.report_loop_fuse(self, node_uid)
	}
}

spawn_prefab :: #force_inline proc "c" (api: ^Engine_Hot_API, prefab_guid_str: cstring, world_pos: [3]f32, world_rot: [4]f32 = {0, 0, 0, 1}) -> Hot_Entity {
	if api == nil || api.spawn_prefab == nil do return {}
	return api.spawn_prefab(prefab_guid_str, world_pos, world_rot)
}

destroy_entity :: #force_inline proc "c" (api: ^Engine_Hot_API, target: Hot_Entity) {
	if api != nil && api.destroy_entity != nil {
		api.destroy_entity(target)
	}
}

ai_find_path_move :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, goal_pos: [3]f32) -> bool {
	if api == nil || api.ai_find_path_move == nil do return false
	return api.ai_find_path_move(self, goal_pos)
}

ai_check_arrival :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, goal_pos: [3]f32, accept_radius: f32) -> bool {
	if api == nil || api.ai_check_arrival == nil do return false
	return api.ai_check_arrival(self, goal_pos, accept_radius)
}

physics_raycast :: #force_inline proc "c" (
	api:          ^Engine_Hot_API,
	ignore_self:  Hot_Entity,
	origin:       [3]f32,
	dir:          [3]f32,
	max_dist:     f32,
	channel_mask: u32 = 0,
	out_hit:      ^Hot_Raycast_Hit = nil,
) -> bool {
	if api == nil || api.physics_raycast == nil do return false
	return api.physics_raycast(ignore_self, origin, dir, max_dist, channel_mask, out_hit)
}

physics_overlap_sphere :: #force_inline proc "c" (
	api:          ^Engine_Hot_API,
	ignore_self:  Hot_Entity,
	center:       [3]f32,
	radius:       f32,
	channel_mask: u32 = 0,
	out_closest:  ^Hot_Entity = nil,
) -> i32 {
	if api == nil || api.physics_overlap_sphere == nil do return 0
	return api.physics_overlap_sphere(ignore_self, center, radius, channel_mask, out_closest)
}

physics_add_impulse :: #force_inline proc "c" (api: ^Engine_Hot_API, target: Hot_Entity, impulse: [3]f32, is_vel_change: bool = false) {
	if api != nil && api.physics_add_impulse != nil {
		api.physics_add_impulse(target, impulse, is_vel_change)
	}
}

audio_play_spatial_3d :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, cue_str: cstring, world_pos: [3]f32, volume: f32 = 1.0, pitch: f32 = 1.0) {
	if api != nil && api.audio_play_spatial_3d != nil {
		api.audio_play_spatial_3d(self, cue_str, world_pos, volume, pitch)
	}
}

audio_set_bus_send :: #force_inline proc "c" (api: ^Engine_Hot_API, bus_name: cstring, send_level: f32, lowpass_hz: f32 = 0.0) {
	if api != nil && api.audio_set_bus_send != nil {
		api.audio_set_bus_send(bus_name, send_level, lowpass_hz)
	}
}

vfx_emitter_spawn :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, vfx_str: cstring, spawn_rate: f32, burst_count: i32 = 0) {
	if api != nil && api.vfx_emitter_spawn != nil {
		api.vfx_emitter_spawn(self, vfx_str, spawn_rate, burst_count)
	}
}

anim_set_ik_target :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, effector_name: cstring, world_target: [3]f32, weight: f32 = 1.0) {
	if api != nil && api.anim_set_ik_target != nil {
		api.anim_set_ik_target(self, effector_name, world_target, weight)
	}
}

csg_stamp_brush :: #force_inline proc "c" (api: ^Engine_Hot_API, world_pos: [3]f32, radius: f32, impulse: f32 = 12.0, cut_mat_str: cstring = "") -> i32 {
	if api == nil || api.csg_stamp_brush == nil do return 0
	return api.csg_stamp_brush(world_pos, radius, impulse, cut_mat_str)
}

var_f32_seq_ptr :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_name: cstring, out_len: ^i32, out_cap: ^i32) -> ^f32 {
	if api == nil || api.var_f32_seq_ptr == nil {
		if out_len != nil do out_len^ = 0
		if out_cap != nil do out_cap^ = 0
		return nil
	}
	return api.var_f32_seq_ptr(self, var_name, out_len, out_cap)
}

var_f32_seq_sync :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_name: cstring, data: ^f32, length: i32, capacity: i32 = -1) {
	if api != nil && api.var_f32_seq_sync != nil {
		api.var_f32_seq_sync(self, var_name, data, length, capacity)
	}
}

var_seq_ptr :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_name: cstring, elem_size: i32, elem_align: i32, out_len: ^i32, out_cap: ^i32) -> rawptr {
	if api == nil || api.var_seq_ptr == nil {
		if out_len != nil do out_len^ = 0
		if out_cap != nil do out_cap^ = 0
		return nil
	}
	return api.var_seq_ptr(self, var_name, elem_size, elem_align, out_len, out_cap)
}

var_seq_sync :: #force_inline proc "c" (api: ^Engine_Hot_API, self: Hot_Entity, var_name: cstring, data: rawptr, elem_size: i32, elem_align: i32, length: i32, capacity: i32 = -1) {
	if api != nil && api.var_seq_sync != nil {
		api.var_seq_sync(self, var_name, data, elem_size, elem_align, length, capacity)
	}
}

@(private = "file")
_copy_cstr_buf :: proc "contextless" (dst: []byte, s: string) -> cstring {
	if len(dst) == 0 do return cstring("")
	n := min(len(s), len(dst) - 1)
	if n > 0 do copy(dst[:n], s[:n])
	dst[n] = 0
	return cstring(raw_data(dst))
}

@(private = "file")
_hot_script_assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	api := (^Engine_Hot_API)(context.user_ptr)
	if api != nil && api.report_sandbox_fault != nil {
		msg_buf:  [256]byte
		file_buf: [260]byte
		proc_buf: [128]byte
		formatted := fmt.bprintf(msg_buf[:len(msg_buf) - 1], "%s: %s", prefix, message)
		msg_buf[len(formatted)] = 0
		fc := _copy_cstr_buf(file_buf[:], loc.file_path)
		pc := _copy_cstr_buf(proc_buf[:], loc.procedure)
		api.report_sandbox_fault(cstring(raw_data(msg_buf[:])), fc, pc, loc.line)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// Constructs a full Odin Context backed by the host executable's allocators and sandbox
// assertion trap so hot-cartridge / `.bodin` scripts can freely use `defer`, raw allocators,
// `context.temp_allocator`, slices, and dynamic arrays safely.
make_script_context :: proc "c" (api: ^Engine_Hot_API) -> runtime.Context {
	ctx := runtime.default_context()
	if api != nil {
		if api.host_allocator.procedure != nil {
			ctx.allocator = api.host_allocator
		}
		if api.host_temp_allocator.procedure != nil {
			ctx.temp_allocator = api.host_temp_allocator
		}
		ctx.user_ptr = api
		ctx.assertion_failure_proc = _hot_script_assertion_failure_proc
	}
	return ctx
}
