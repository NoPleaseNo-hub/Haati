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

import "core:math"
import "core:math/linalg"

ENGINE_HOT_API_VERSION :: u32(2)
HOT_MAX_ARGS           :: 16

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
	Exec     = 0,
	Bool     = 1,
	Int      = 2,
	Float    = 3,
	Vec3     = 4,
	Quat     = 5,
	Entity   = 6,
	Delegate = 7, // `◇` Hot-swap-safe Odin Delegate / Blueprint Procedure reference (`Hot_Delegate`)
	Vec2     = 8, // `[2]f32` 2D input / movement / look vector
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
	_pad:         [2]u8,
	val_bool:     bool,
	_pad_b:       [3]u8,
	val_int:      i32,
	val_f32:      f32,
	val_vec2:     [2]f32,
	val_vec3:     [3]f32,
	val_quat:     [4]f32,
	val_ent:      Hot_Entity,
	val_delegate: Hot_Delegate,
	ref_ptr:      rawptr, // Non-nil when `pass_mode == .By_Reference` (`^bool`, `^i32`, `^f32`, `^[2]f32`, `^[3]f32`, `^[4]f32`, `^Hot_Entity`)
}

Hot_Call_Frame :: struct {
	inputs:       [HOT_MAX_ARGS]Hot_Slot,
	outputs:      [HOT_MAX_ARGS]Hot_Slot,
	input_count:  i32,
	output_count: i32,
	user_data:    rawptr,
}

// Host-owned C-ABI function table passed into every `@(hot_proc)` and transpiled `.mhgraph`.
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

damp_f32 :: #force_inline proc "c" (current, target, speed, dt: f32) -> f32 {
	return linalg.lerp(current, target, 1.0 - math.exp(-max(speed, 0.0) * max(dt, 0.0)))
}

damp_vec3 :: #force_inline proc "c" (current, target: [3]f32, speed, dt: f32) -> [3]f32 {
	alpha := 1.0 - math.exp(-max(speed, 0.0) * max(dt, 0.0))
	return linalg.lerp(current, target, alpha)
}

// Slot readers/writers used by transpiled `.mhgraph` wrappers to unpack `● Copy` vs `◆ ^Ref` pins cleanly.
slot_read_f32 :: #force_inline proc "c" (s: ^Hot_Slot) -> f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^f32)s.ref_ptr)^
	}
	return s.val_f32
}

slot_ref_f32 :: #force_inline proc "c" (s: ^Hot_Slot) -> ^f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^f32)s.ref_ptr
	}
	return &s.val_f32
}

slot_read_vec3 :: #force_inline proc "c" (s: ^Hot_Slot) -> [3]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^[3]f32)s.ref_ptr)^
	}
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
	return s.val_int
}

slot_ref_int :: #force_inline proc "c" (s: ^Hot_Slot) -> ^i32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return cast(^i32)s.ref_ptr
	}
	return &s.val_int
}

slot_read_vec2 :: #force_inline proc "c" (s: ^Hot_Slot) -> [2]f32 {
	if s.pass_mode == .By_Reference && s.ref_ptr != nil {
		return (cast(^[2]f32)s.ref_ptr)^
	}
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
