package engine

// =============================================================================
// MOONHUG HOT CARTRIDGE HOST RUNTIME (`hot_cartridge_<N>.dll`)
// =============================================================================
// Owns the host-side `Engine_Hot_API` vtable, the static + hot-swapped `@(hot_proc)`
// dispatch table, non-blocking background DLL compilation, and component schema
// hash verification (so `@(component)` field layout changes cleanly trigger Tier-3
// Shared-Memory Relaunch Handoff instead of corrupting live pools).

import "base:runtime"
import "core:dynlib"
import "core:encoding/uuid"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "crash_journal"
import "gfx"
import hot "hot_api"
import "log"

Hot_Reload_Status :: enum u8 {
	Idle              = 0,
	Compiling         = 1,
	Swapped_OK        = 2,
	Compile_Failed    = 3,
	Schema_Changed    = 4, // Struct layout changed -> offer OS Shared-Memory Relaunch Handoff
}

Hot_Proc_Entry :: struct {
	name:        string,
	static_fn:   hot.Hot_Proc_Fn,
	active_fn:   hot.Hot_Proc_Fn,
	hot_gen:     int, // 0 = static binary proc, >= 1 = hot-swapped cartridge generation
	source_file: string,
	faulted:     bool,
}

Hot_Sandbox_Fault_Report :: struct {
	has_fault: bool,
	proc_name: string,
	reason:    string,
	file:      string,
	line:      i32,
	entity:    Transform_Handle,
	code:      u32,
}

Sandbox_File_Override :: struct {
	rel_hot_name: string, // Filename inside `hot_scripts/` (e.g. `my_script_mhgraph_generated.odin`)
	content:      string,
}

@(private = "file")
_Hot_Registry :: struct {
	initialized:         bool,
	entries:             [dynamic]Hot_Proc_Entry,
	by_name:             map[string]int,
	loaded_libs:         [dynamic]dynlib.Library,
	sig_metas:           [dynamic]hot.Hot_Proc_Sig_Meta,
	sig_by_name:         map[string]int,
	sig_defaults_seeded: bool,
	generation:          int,
	boot_schema_hash:    u64,
	status:              Hot_Reload_Status,
	last_swap_ms:        f32,
	last_message:        string,
	last_stderr:         string,
	last_fault:          Hot_Sandbox_Fault_Report,
	sandbox_active_mode: bool,
	quarantined:         bool, // Armed after Watchdog crash recovery until explicit user Re-Arm or F7

	// Single-flight async `mh hot` compiler child process (hidden on Windows via `CREATE_NO_WINDOW`)
	build_pending:       bool,
	build_proc:          BG_Process,
	build_target_gen:    int,
	build_target_dll:    string,
	build_err_file:      string,
	build_started_at:    time.Tick,
}

@(private = "file")
_hot_reg: _Hot_Registry

@(private = "file")
_hot_active_user_ctx: rawptr

@(private = "file")
_hot_api_table: hot.Engine_Hot_API

// Converts a MoonHug `Transform_Handle` to an ABI-stable 8-byte `Hot_Entity`.
transform_to_hot_entity :: #force_inline proc(tH: Transform_Handle) -> hot.Hot_Entity {
	h := Handle(tH)
	return hot.Hot_Entity{index = h.index, generation = h.generation}
}

// Converts an ABI-stable `Hot_Entity` back to a validated `Transform_Handle`.
hot_entity_to_transform :: #force_inline proc(e: hot.Hot_Entity) -> Transform_Handle {
	return Transform_Handle(Handle{index = e.index, generation = e.generation, type_key = .Transform})
}

@(private = "file")
_hot_restore_ctx :: #force_inline proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.user_ptr = _hot_active_user_ctx
	return c
}

// =============================================================================
// Host `proc "c"` VTable Implementations (Zero `typeid` Across Boundary)
// =============================================================================

@(private = "file")
_cb_entity_valid :: proc "c" (self: hot.Hot_Entity) -> bool {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return false
	return pool_valid(&w.transforms, Handle(hot_entity_to_transform(self)))
}

@(private = "file")
_cb_get_local_position :: proc "c" (self: hot.Hot_Entity) -> [3]f32 {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return {}
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	return t != nil ? t.position : [3]f32{}
}

@(private = "file")
_cb_set_local_position :: proc "c" (self: hot.Hot_Entity, pos: [3]f32) {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return
	if t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self))); t != nil {
		t.position = pos
	}
}

@(private = "file")
_cb_ptr_local_position :: proc "c" (self: hot.Hot_Entity) -> ^[3]f32 {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return nil
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	return t != nil ? &t.position : nil
}

@(private = "file")
_cb_get_local_rotation :: proc "c" (self: hot.Hot_Entity) -> [4]f32 {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return QUAT_IDENTITY
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	return t != nil ? t.rotation : QUAT_IDENTITY
}

@(private = "file")
_cb_set_local_rotation :: proc "c" (self: hot.Hot_Entity, rot: [4]f32) {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return
	if t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self))); t != nil {
		t.rotation = rot
	}
}

@(private = "file")
_cb_ptr_local_rotation :: proc "c" (self: hot.Hot_Entity) -> ^[4]f32 {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return nil
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	return t != nil ? &t.rotation : nil
}

@(private = "file")
_cb_get_local_scale :: proc "c" (self: hot.Hot_Entity) -> [3]f32 {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return {1, 1, 1}
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	return t != nil ? t.scale : [3]f32{1, 1, 1}
}

@(private = "file")
_cb_set_local_scale :: proc "c" (self: hot.Hot_Entity, scl: [3]f32) {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return
	if t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self))); t != nil {
		t.scale = scl
	}
}

@(private = "file")
_cb_ptr_local_scale :: proc "c" (self: hot.Hot_Entity) -> ^[3]f32 {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return nil
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	return t != nil ? &t.scale : nil
}

@(private = "file")
_cb_get_world_position :: proc "c" (self: hot.Hot_Entity) -> [3]f32 {
	context = _hot_restore_ctx()
	tH := hot_entity_to_transform(self)
	w := ctx_world()
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return {}
	return transform_world_position(tH)
}

@(private = "file")
_cb_get_forward :: proc "c" (self: hot.Hot_Entity) -> [3]f32 {
	context = _hot_restore_ctx()
	tH := hot_entity_to_transform(self)
	w := ctx_world()
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return {0, 0, 1}
	q := quat_to_native(transform_world(tH).rotation)
	return linalg.quaternion128_mul_vector3(q, [3]f32{0, 0, 1})
}

@(private = "file")
_cb_get_up :: proc "c" (self: hot.Hot_Entity) -> [3]f32 {
	context = _hot_restore_ctx()
	tH := hot_entity_to_transform(self)
	w := ctx_world()
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return {0, 1, 0}
	q := quat_to_native(transform_world(tH).rotation)
	return linalg.quaternion128_mul_vector3(q, [3]f32{0, 1, 0})
}

@(private = "file")
_cb_get_right :: proc "c" (self: hot.Hot_Entity) -> [3]f32 {
	context = _hot_restore_ctx()
	tH := hot_entity_to_transform(self)
	w := ctx_world()
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return {1, 0, 0}
	q := quat_to_native(transform_world(tH).rotation)
	return linalg.quaternion128_mul_vector3(q, [3]f32{1, 0, 0})
}

@(private = "file")
_cb_get_time_scale :: proc "c" () -> f32 {
	context = _hot_restore_ctx()
	return time_scale()
}

@(private = "file")
_cb_set_time_scale :: proc "c" (scale: f32) {
	context = _hot_restore_ctx()
	set_time_scale(scale)
}

@(private = "file")
_cb_get_unscaled_dt :: proc "c" () -> f32 {
	context = _hot_restore_ctx()
	return gfx.delta_time()
}

@(private = "file")
_cb_get_object_dt :: proc "c" (self: hot.Hot_Entity, raw_dt: f32) -> f32 {
	context = _hot_restore_ctx()
	return transform_dt(hot_entity_to_transform(self), raw_dt)
}

@(private = "file")
_cb_get_object_time_scale :: proc "c" (self: hot.Hot_Entity) -> f32 {
	context = _hot_restore_ctx()
	return transform_hierarchy_time_scale(hot_entity_to_transform(self))
}

@(private = "file")
_cb_set_object_time_scale :: proc "c" (self: hot.Hot_Entity, scale: f32) {
	context = _hot_restore_ctx()
	transform_set_custom_time_scale(hot_entity_to_transform(self), scale)
}

@(private = "file")
_cb_get_component_by_guid :: proc "c" (self: hot.Hot_Entity, guid: [16]u8) -> rawptr {
	context = _hot_restore_ctx()
	w := ctx_world()
	if w == nil do return nil
	t := pool_get(&w.transforms, Handle(hot_entity_to_transform(self)))
	if t == nil do return nil
	id := uuid.Identifier(guid)
	key, has := _component_registry_by_guid[id]
	if !has do return nil
	for c in t.components {
		if c.handle.type_key == key {
			return world_pool_get(w, c.handle)
		}
	}
	return nil
}

@(private = "file")
_cb_log_info :: proc "c" (msg: cstring) {
	context = _hot_restore_ctx()
	if msg != nil {
		log.infof("[HotScript] %s", string(msg))
	}
}

@(private = "file")
_cb_resolve_proc_slot :: proc "c" (proc_name: cstring) -> i32 {
	context = _hot_restore_ctx()
	if proc_name == nil do return -1
	return hot_proc_slot_index(string(proc_name))
}

@(private = "file")
_cb_bind_input_action :: proc "c" (self: hot.Hot_Entity, action_name: cstring, trigger: hot.Hot_Trigger_Edge, priority: i32, consume: bool, target_proc: cstring) -> u32 {
	context = _hot_restore_ctx()
	if action_name == nil || target_proc == nil do return 0
	return visual_script_bind_action_runtime(hot_entity_to_transform(self), string(action_name), trigger, int(priority), consume, string(target_proc), 0)
}

@(private = "file")
_cb_unbind_input_action :: proc "c" (self: hot.Hot_Entity, action_name: cstring) {
	context = _hot_restore_ctx()
	if action_name == nil do return
	visual_script_unbind_action_runtime(hot_entity_to_transform(self), string(action_name))
}

@(private = "file")
_cb_bind_input_vector :: proc "c" (self: hot.Hot_Entity, is_look: bool, priority: i32, consume: bool, target_proc: cstring) -> u32 {
	context = _hot_restore_ctx()
	if target_proc == nil do return 0
	return visual_script_bind_vector_runtime(hot_entity_to_transform(self), is_look, int(priority), consume, string(target_proc), 0)
}

@(private = "file")
_cb_unbind_input_vector :: proc "c" (self: hot.Hot_Entity, is_look: bool) {
	context = _hot_restore_ctx()
	visual_script_unbind_vector_runtime(hot_entity_to_transform(self), is_look)
}

@(private = "file")
_cb_bind_debug_key :: proc "c" (self: hot.Hot_Entity, key_code: i32, trigger: hot.Hot_Trigger_Edge, target_proc: cstring) -> u32 {
	context = _hot_restore_ctx()
	if target_proc == nil do return 0
	return visual_script_bind_debug_key_runtime(hot_entity_to_transform(self), int(key_code), trigger, string(target_proc), 0)
}

@(private = "file")
_cb_unbind_debug_key :: proc "c" (self: hot.Hot_Entity, key_code: i32) {
	context = _hot_restore_ctx()
	visual_script_unbind_debug_key_runtime(hot_entity_to_transform(self), int(key_code))
}

@(private = "file")
_cb_unbind_all_inputs :: proc "c" (self: hot.Hot_Entity) {
	context = _hot_restore_ctx()
	visual_script_unbind_all_for_entity(hot_entity_to_transform(self))
}

@(private = "file")
_cb_bind_custom_delegate :: proc "c" (self: hot.Hot_Entity, delegate_name: cstring, target_proc: cstring) {
	context = _hot_restore_ctx()
	if delegate_name == nil || target_proc == nil do return
	visual_script_bind_custom_delegate_runtime(hot_entity_to_transform(self), string(delegate_name), string(target_proc), 0)
}

@(private = "file")
_cb_unbind_custom_delegate :: proc "c" (self: hot.Hot_Entity, delegate_name: cstring) {
	context = _hot_restore_ctx()
	if delegate_name == nil do return
	visual_script_unbind_custom_delegate_runtime(hot_entity_to_transform(self), string(delegate_name))
}

@(private = "file")
_cb_broadcast_custom_delegate :: proc "c" (self: hot.Hot_Entity, delegate_name: cstring, payload_f32: f32) {
	context = _hot_restore_ctx()
	if delegate_name == nil do return
	visual_script_broadcast_custom_delegate_runtime(hot_entity_to_transform(self), string(delegate_name), payload_f32)
}

@(private = "file")
_cb_get_blueprint_var_ptr :: proc "c" (self: hot.Hot_Entity, var_index: i32) -> rawptr {
	context = _hot_restore_ctx()
	return visual_script_get_entity_var_ptr(hot_entity_to_transform(self), int(var_index))
}

@(private = "file")
_cb_var_blob_ptr :: proc "c" (self: hot.Hot_Entity, var_name: cstring, byte_size: i32) -> rawptr {
	context = _hot_restore_ctx()
	if var_name == nil do return nil
	return visual_script_get_entity_var_blob_ptr(hot_entity_to_transform(self), string(var_name), int(byte_size))
}

@(private = "file")
_cb_var_ptr_raw :: proc "c" (self: hot.Hot_Entity, var_name: cstring, pin_type: hot.Hot_Pin_Type) -> rawptr {
	context = _hot_restore_ctx()
	if var_name == nil do return nil
	return visual_script_get_entity_var_ptr_raw(hot_entity_to_transform(self), string(var_name), pin_type)
}

@(private = "file")
_cb_timer_step :: proc "c" (self: hot.Hot_Entity, node_uid: u32, duration: f32, dt: f32, reset: bool, is_cooldown: bool, out_remaining: ^f32) -> bool {
	context = _hot_restore_ctx()
	ready, rem := visual_script_timer_step_runtime(hot_entity_to_transform(self), node_uid, duration, dt, reset, is_cooldown)
	if out_remaining != nil do out_remaining^ = rem
	return ready
}

@(private = "file")
_cb_report_loop_fuse :: proc "c" (self: hot.Hot_Entity, node_uid: u32) {
	context = _hot_restore_ctx()
	visual_script_report_loop_fuse(hot_entity_to_transform(self), node_uid)
}

@(private = "file")
_cb_spawn_prefab :: proc "c" (prefab_guid_str: cstring, world_pos: [3]f32, world_rot: [4]f32) -> hot.Hot_Entity {
	context = _hot_restore_ctx()
	if prefab_guid_str == nil do return {}
	tH := visual_script_spawn_prefab_runtime(string(prefab_guid_str), world_pos, world_rot)
	return transform_to_hot_entity(tH)
}

@(private = "file")
_cb_destroy_entity :: proc "c" (target: hot.Hot_Entity) {
	context = _hot_restore_ctx()
	visual_script_destroy_entity_runtime(hot_entity_to_transform(target))
}

@(private = "file")
_cb_ai_find_path_move :: proc "c" (self: hot.Hot_Entity, goal_pos: [3]f32) -> bool {
	context = _hot_restore_ctx()
	return visual_script_ai_move_runtime(hot_entity_to_transform(self), goal_pos, -1.0)
}

@(private = "file")
_cb_ai_check_arrival :: proc "c" (self: hot.Hot_Entity, goal_pos: [3]f32, accept_radius: f32) -> bool {
	context = _hot_restore_ctx()
	_ = goal_pos
	return visual_script_ai_arrived_runtime(hot_entity_to_transform(self), accept_radius)
}

@(private = "file")
_cb_physics_raycast :: proc "c" (ignore_self: hot.Hot_Entity, origin: [3]f32, dir: [3]f32, max_dist: f32, channel_mask: u32, out_hit: ^hot.Hot_Raycast_Hit) -> bool {
	context = _hot_restore_ctx()
	hit := visual_script_physics_raycast_runtime(hot_entity_to_transform(ignore_self), origin, dir, max_dist, channel_mask)
	if out_hit != nil do out_hit^ = hit
	return hit.hit
}

@(private = "file")
_cb_physics_overlap_sphere :: proc "c" (ignore_self: hot.Hot_Entity, center: [3]f32, radius: f32, channel_mask: u32, out_closest: ^hot.Hot_Entity) -> i32 {
	context = _hot_restore_ctx()
	cnt, closest := visual_script_physics_overlap_sphere_runtime(hot_entity_to_transform(ignore_self), center, radius, channel_mask)
	if out_closest != nil do out_closest^ = transform_to_hot_entity(closest)
	return cnt
}

@(private = "file")
_cb_physics_add_impulse :: proc "c" (target: hot.Hot_Entity, impulse: [3]f32, is_vel_change: bool) {
	context = _hot_restore_ctx()
	visual_script_physics_add_impulse_runtime(hot_entity_to_transform(target), impulse, is_vel_change)
}

@(private = "file")
_cb_audio_play_spatial_3d :: proc "c" (self: hot.Hot_Entity, cue_str: cstring, world_pos: [3]f32, volume: f32, pitch: f32) {
	context = _hot_restore_ctx()
	visual_script_audio_play_3d_runtime(hot_entity_to_transform(self), cue_str != nil ? string(cue_str) : "", world_pos, volume, pitch)
}

@(private = "file")
_cb_audio_set_bus_send :: proc "c" (bus_name: cstring, send_level: f32, lowpass_hz: f32) {
	context = _hot_restore_ctx()
	visual_script_audio_bus_send_runtime(bus_name != nil ? string(bus_name) : "Master", send_level, lowpass_hz)
}

@(private = "file")
_cb_vfx_emitter_spawn :: proc "c" (self: hot.Hot_Entity, vfx_str: cstring, spawn_rate: f32, burst_count: i32) {
	context = _hot_restore_ctx()
	visual_script_vfx_spawn_runtime(hot_entity_to_transform(self), vfx_str != nil ? string(vfx_str) : "", spawn_rate, burst_count)
}

@(private = "file")
_cb_anim_set_ik_target :: proc "c" (self: hot.Hot_Entity, effector_name: cstring, world_target: [3]f32, weight: f32) {
	context = _hot_restore_ctx()
	visual_script_anim_ik_target_runtime(hot_entity_to_transform(self), effector_name != nil ? string(effector_name) : "Right_Hand", world_target, weight)
}

@(private = "file")
_cb_csg_stamp_brush :: proc "c" (world_pos: [3]f32, radius: f32, impulse: f32, cut_mat_str: cstring) -> i32 {
	context = _hot_restore_ctx()
	return visual_script_csg_stamp_runtime(world_pos, radius, impulse, cut_mat_str != nil ? string(cut_mat_str) : "")
}

@(private = "file")
_cb_report_sandbox_fault :: proc "c" (msg, file, proc_name: cstring, line: i32) {
	crash_journal.sandbox_record_assertion_fault(msg, file, proc_name, line)
}

@(private = "file")
_cb_var_f32_seq_ptr :: proc "c" (self: hot.Hot_Entity, var_name: cstring, out_len: ^i32, out_cap: ^i32) -> ^f32 {
	context = _hot_restore_ctx()
	name := var_name != nil ? string(var_name) : ""
	p, l, c := visual_script_get_entity_var_f32_seq_ptr(hot_entity_to_transform(self), name)
	if out_len != nil do out_len^ = l
	if out_cap != nil do out_cap^ = c
	return p
}

@(private = "file")
_cb_var_f32_seq_sync :: proc "c" (self: hot.Hot_Entity, var_name: cstring, data: ^f32, length: i32, capacity: i32) {
	context = _hot_restore_ctx()
	name := var_name != nil ? string(var_name) : ""
	visual_script_sync_entity_var_f32_seq(hot_entity_to_transform(self), name, data, length, capacity)
}

@(private = "file")
_cb_var_seq_ptr :: proc "c" (self: hot.Hot_Entity, var_name: cstring, elem_size, elem_align: i32, out_len, out_cap: ^i32) -> rawptr {
	context = _hot_restore_ctx()
	name := var_name != nil ? string(var_name) : ""
	p, l, c := visual_script_get_entity_var_seq_ptr(hot_entity_to_transform(self), name, elem_size, elem_align)
	if out_len != nil do out_len^ = l
	if out_cap != nil do out_cap^ = c
	return p
}

@(private = "file")
_cb_var_seq_sync :: proc "c" (self: hot.Hot_Entity, var_name: cstring, data: rawptr, elem_size, elem_align, length, capacity: i32) {
	context = _hot_restore_ctx()
	name := var_name != nil ? string(var_name) : ""
	visual_script_sync_entity_var_seq(hot_entity_to_transform(self), name, data, elem_size, elem_align, length, capacity)
}

// Best-effort sweep of stale `hot_cartridge_<N>.*` files from previous crashed/closed runs.
// Leaves `hot_cartridge_latest.*` untouched and ignores locked DLLs in active sessions.
@(private = "file")
_sweep_stale_hot_cartridge_files :: proc() {
	repo_root := resolve_repo_root(context.temp_allocator)
	if repo_root == "" do return
	builds_dir, _ := filepath.join({repo_root, "builds"}, context.temp_allocator)
	if !os.is_dir(builds_dir) do return

	dh, derr := os.open(builds_dir)
	if derr != nil do return
	entries, rerr := os.read_dir(dh, -1, context.temp_allocator)
	os.close(dh)
	if rerr != nil do return

	prefix :: "hot_cartridge_"
	sweep_exts := [?]string{".dll", ".pdb", ".exp", ".lib", ".rdi", ".err", ".dylib", ".so"}
	for e in entries {
		if e.type == .Directory do continue
		lower := strings.to_lower(e.name, context.temp_allocator)
		if !strings.has_prefix(lower, prefix) || len(lower) <= len(prefix) do continue
		first := lower[len(prefix)]
		if first < '0' || first > '9' do continue

		match_ext := false
		for ext in sweep_exts {
			if strings.has_suffix(lower, ext) {
				match_ext = true
				break
			}
		}
		if !match_ext do continue
		if full, jerr := filepath.join({builds_dir, e.name}, context.temp_allocator); jerr == nil {
			_ = os.remove(full)
		}
	}
}

@(private = "file")
_ensure_hot_init :: proc() {
	if _hot_reg.initialized do return
	context.allocator = runtime.default_allocator()
	_hot_reg.initialized = true
	_sweep_stale_hot_cartridge_files()
	_hot_api_table = hot.Engine_Hot_API{
		version                   = hot.ENGINE_HOT_API_VERSION,
		entity_valid              = _cb_entity_valid,
		get_local_position        = _cb_get_local_position,
		set_local_position        = _cb_set_local_position,
		ptr_local_position        = _cb_ptr_local_position,
		get_local_rotation        = _cb_get_local_rotation,
		set_local_rotation        = _cb_set_local_rotation,
		ptr_local_rotation        = _cb_ptr_local_rotation,
		get_local_scale           = _cb_get_local_scale,
		set_local_scale           = _cb_set_local_scale,
		ptr_local_scale           = _cb_ptr_local_scale,
		get_world_position        = _cb_get_world_position,
		get_forward               = _cb_get_forward,
		get_up                    = _cb_get_up,
		get_right                 = _cb_get_right,
		get_time_scale            = _cb_get_time_scale,
		set_time_scale            = _cb_set_time_scale,
		get_object_dt             = _cb_get_object_dt,
		get_object_time_scale     = _cb_get_object_time_scale,
		set_object_time_scale     = _cb_set_object_time_scale,
		get_component_by_guid     = _cb_get_component_by_guid,
		log_info                  = _cb_log_info,
		resolve_proc_slot         = _cb_resolve_proc_slot,
		bind_input_action         = _cb_bind_input_action,
		unbind_input_action       = _cb_unbind_input_action,
		bind_input_vector         = _cb_bind_input_vector,
		unbind_input_vector       = _cb_unbind_input_vector,
		bind_debug_key            = _cb_bind_debug_key,
		unbind_debug_key          = _cb_unbind_debug_key,
		unbind_all_inputs         = _cb_unbind_all_inputs,
		bind_custom_delegate      = _cb_bind_custom_delegate,
		unbind_custom_delegate    = _cb_unbind_custom_delegate,
		broadcast_custom_delegate = _cb_broadcast_custom_delegate,
		get_blueprint_var_ptr     = _cb_get_blueprint_var_ptr,
		var_blob_ptr              = _cb_var_blob_ptr,
		var_ptr_raw               = _cb_var_ptr_raw,
		timer_step                = _cb_timer_step,
		report_loop_fuse          = _cb_report_loop_fuse,
		spawn_prefab              = _cb_spawn_prefab,
		destroy_entity            = _cb_destroy_entity,
		ai_find_path_move         = _cb_ai_find_path_move,
		ai_check_arrival          = _cb_ai_check_arrival,
		physics_raycast           = _cb_physics_raycast,
		physics_overlap_sphere    = _cb_physics_overlap_sphere,
		physics_add_impulse       = _cb_physics_add_impulse,
		audio_play_spatial_3d     = _cb_audio_play_spatial_3d,
		audio_set_bus_send        = _cb_audio_set_bus_send,
		vfx_emitter_spawn         = _cb_vfx_emitter_spawn,
		anim_set_ik_target        = _cb_anim_set_ik_target,
		csg_stamp_brush           = _cb_csg_stamp_brush,
		get_unscaled_dt           = _cb_get_unscaled_dt,
		host_allocator            = runtime.default_allocator(),
		host_temp_allocator       = context.temp_allocator,
		report_sandbox_fault      = _cb_report_sandbox_fault,
		var_f32_seq_ptr           = _cb_var_f32_seq_ptr,
		var_f32_seq_sync          = _cb_var_f32_seq_sync,
		var_seq_ptr               = _cb_var_seq_ptr,
		var_seq_sync              = _cb_var_seq_sync,
	}
	if !_hot_reg.sig_defaults_seeded {
		_hot_reg.sig_defaults_seeded = true
		_seed_builtin_hot_sig_metas()
	}
}

@(private = "file")
_seed_builtin_hot_sig_metas :: proc() {
	hot_proc_register_sig_meta(hot.Hot_Proc_Sig_Meta{
		proc_name      = "hot_harmonic_hover",
		display_title  = "Harmonic Hover",
		namespace_name = "Odin_Hot",
		doc_comment    = "Smooth harmonic vertical oscillation mutating Phase Ref in-place.",
		pins = []hot.Hot_Proc_Pin_Meta{
			{name = "Amp",       pin_type = .Float, is_output = false, by_ref = false, default_f32 = 0.25},
			{name = "Freq",      pin_type = .Float, is_output = false, by_ref = false, default_f32 = 2.00},
			{name = "Phase Ref", pin_type = .Float, is_output = false, by_ref = true,  default_f32 = 0.00},
			{name = "Out",       pin_type = .Float, is_output = true},
		},
	})
	hot_proc_register_sig_meta(hot.Hot_Proc_Sig_Meta{
		proc_name      = "hot_spring_vec3_ref",
		display_title  = "Spring Vec3 Ref",
		namespace_name = "Odin_Hot",
		doc_comment    = "Damped spring mutating a ^[3]f32 vector in-place toward Target.",
		pins = []hot.Hot_Proc_Pin_Meta{
			{name = "Vec Ref", pin_type = .Vec3,  is_output = false, by_ref = true},
			{name = "Target",  pin_type = .Vec3,  is_output = false, by_ref = false},
			{name = "Speed",   pin_type = .Float, is_output = false, by_ref = false, default_f32 = 8.0},
			{name = "Out",     pin_type = .Vec3,  is_output = true},
		},
	})
	hot_proc_register_sig_meta(hot.Hot_Proc_Sig_Meta{
		proc_name      = "hot_apply_timescale_zone",
		display_title  = "Apply TimeScale Zone",
		namespace_name = "Odin_Hot",
		doc_comment    = "Sets custom per-object time scale on self.",
		pins = []hot.Hot_Proc_Pin_Meta{
			{name = "Scale", pin_type = .Float, is_output = false, by_ref = false, default_f32 = 0.5},
		},
	})
}

// Registers self-describing pin signature metadata for `@(bp_node)` / `@(hot_proc)` nodes.
hot_proc_register_sig_meta :: proc(sig: hot.Hot_Proc_Sig_Meta) {
	_ensure_hot_init()
	if sig.proc_name == "" do return
	context.allocator = runtime.default_allocator()

	cloned_pins: []hot.Hot_Proc_Pin_Meta
	if len(sig.pins) > 0 {
		cloned_pins = make([]hot.Hot_Proc_Pin_Meta, len(sig.pins))
		for p, i in sig.pins {
			cloned_pins[i] = p
			cloned_pins[i].name        = strings.clone(p.name)
			cloned_pins[i].custom_type = p.custom_type != "" ? strings.clone(p.custom_type) : ""
		}
	}
	entry := hot.Hot_Proc_Sig_Meta{
		proc_name        = strings.clone(sig.proc_name),
		display_title    = strings.clone(sig.display_title != "" ? sig.display_title : sig.proc_name),
		namespace_name   = strings.clone(sig.namespace_name != "" ? sig.namespace_name : "Odin_Hot"),
		doc_comment      = sig.doc_comment != "" ? strings.clone(sig.doc_comment) : "",
		source_proc_name = sig.source_proc_name != "" ? strings.clone(sig.source_proc_name) : "",
		is_pure          = sig.is_pure,
		pins             = cloned_pins,
	}

	if idx, exists := _hot_reg.sig_by_name[sig.proc_name]; exists {
		old := _hot_reg.sig_metas[idx]
		if old.source_proc_name != "" {
			delete_key(&_hot_reg.sig_by_name, old.source_proc_name)
		}
		delete(old.display_title)
		delete(old.namespace_name)
		if old.doc_comment != "" do delete(old.doc_comment)
		if old.source_proc_name != "" do delete(old.source_proc_name)
		for p in old.pins {
			delete(p.name)
			if p.custom_type != "" do delete(p.custom_type)
		}
		delete(old.pins)
		// Keep existing map key string alive for `entry.proc_name`
		delete(entry.proc_name)
		entry.proc_name = old.proc_name
		_hot_reg.sig_metas[idx] = entry
		if entry.source_proc_name != "" {
			_hot_reg.sig_by_name[entry.source_proc_name] = idx
		}
		return
	}

	idx := len(_hot_reg.sig_metas)
	append(&_hot_reg.sig_metas, entry)
	_hot_reg.sig_by_name[entry.proc_name] = idx
	if entry.source_proc_name != "" {
		_hot_reg.sig_by_name[entry.source_proc_name] = idx
	}
}

hot_proc_find_sig_meta :: proc(name: string) -> (meta: hot.Hot_Proc_Sig_Meta, ok: bool) {
	_ensure_hot_init()
	if name == "" do return {}, false
	idx, found := _hot_reg.sig_by_name[name]
	if !found || idx < 0 || idx >= len(_hot_reg.sig_metas) do return {}, false
	return _hot_reg.sig_metas[idx], true
}

hot_proc_all_sig_metas :: proc() -> []hot.Hot_Proc_Sig_Meta {
	_ensure_hot_init()
	return _hot_reg.sig_metas[:]
}

// =============================================================================
// Static Registration, Dynamic DLL Swap & Invocation
// =============================================================================

hot_cartridge_set_boot_schema_hash :: proc(hash: u64) {
	_ensure_hot_init()
	_hot_reg.boot_schema_hash = hash
}

hot_cartridge_boot_schema_hash :: proc() -> u64 {
	return _hot_reg.boot_schema_hash
}

// Registers a compiled-in `@(hot_proc)` at startup (pinned to default allocator).
hot_proc_register_static :: proc(name: string, fn: hot.Hot_Proc_Fn, source_file: string = "") {
	_ensure_hot_init()
	context.allocator = runtime.default_allocator()
	if idx, exists := _hot_reg.by_name[name]; exists {
		_hot_reg.entries[idx].static_fn = fn
		if _hot_reg.entries[idx].hot_gen == 0 {
			_hot_reg.entries[idx].active_fn = fn
		}
		if source_file != "" {
			if _hot_reg.entries[idx].source_file != "" do delete(_hot_reg.entries[idx].source_file)
			_hot_reg.entries[idx].source_file = strings.clone(source_file)
		}
		return
	}
	cname := strings.clone(name)
	csrc  := source_file != "" ? strings.clone(source_file) : ""
	idx   := len(_hot_reg.entries)
	append(&_hot_reg.entries, Hot_Proc_Entry{
		name        = cname,
		static_fn   = fn,
		active_fn   = fn,
		hot_gen     = 0,
		source_file = csrc,
	})
	_hot_reg.by_name[cname] = idx
}

hot_proc_entries :: proc() -> []Hot_Proc_Entry {
	_ensure_hot_init()
	return _hot_reg.entries[:]
}

hot_proc_exists :: proc(name: string) -> bool {
	_ensure_hot_init()
	_, ok := _hot_reg.by_name[name]
	return ok
}

// Resolves (or reserves) a hot-swap-immortal slot index in `_hot_reg.entries` (`O(1)` dispatch).
// Even if `name` hasn't been compiled into a DLL yet, reserving its slot now means when `F7`
// hot-swaps `hot_cartridge_<N>.dll`, `active_fn` is populated at this exact same `slot_idx`!
hot_proc_slot_index :: proc(name: string, reserve_if_missing: bool = true) -> i32 {
	_ensure_hot_init()
	if name == "" do return -1
	if idx, ok := _hot_reg.by_name[name]; ok {
		return i32(idx)
	}
	if !reserve_if_missing do return -1
	context.allocator = runtime.default_allocator()
	cname := strings.clone(name)
	idx := len(_hot_reg.entries)
	append(&_hot_reg.entries, Hot_Proc_Entry{
		name = cname,
	})
	_hot_reg.by_name[cname] = idx
	return i32(idx)
}

@(private = "file")
_Hot_Call_Thunk :: struct {
	fn:    hot.Hot_Proc_Fn,
	api:   ^hot.Engine_Hot_API,
	self:  hot.Hot_Entity,
	dt:    f32,
	frame: ^hot.Hot_Call_Frame,
}

@(private = "file")
_hot_call_thunk_proc :: proc "c" (arg: rawptr) {
	t := (^_Hot_Call_Thunk)(arg)
	t.fn(t.api, t.self, t.dt, t.frame)
}

@(private = "file")
_invoke_entry_sandboxed :: proc(idx: int, self_tH: Transform_Handle, dt: f32, frame: ^hot.Hot_Call_Frame) -> bool {
	if _hot_reg.quarantined do return false
	if idx < 0 || idx >= len(_hot_reg.entries) do return false
	entry := &_hot_reg.entries[idx]
	if entry.faulted || entry.active_fn == nil do return false

	prev_ctx := _hot_active_user_ctx
	_hot_active_user_ctx = context.user_ptr
	_hot_api_table.host_world          = ctx_world()
	_hot_api_table.host_allocator      = runtime.default_allocator()
	_hot_api_table.host_temp_allocator = context.temp_allocator
	defer _hot_active_user_ctx = prev_ctx

	// Snapshot finite Transform state before invoking native script so NaN/Inf explosions repair cleanly.
	pre_pos   := [3]f32{}
	pre_rot   := QUAT_IDENTITY
	pre_scale := [3]f32{1, 1, 1}
	if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(self_tH)) {
		if t := pool_get(&w.transforms, Handle(self_tH)); t != nil {
			pre_pos   = t.position
			pre_rot   = t.rotation
			pre_scale = t.scale
		}
	}

	local_frame: hot.Hot_Call_Frame
	f_ptr := frame != nil ? frame : &local_frame
	thunk := _Hot_Call_Thunk{
		fn    = entry.active_fn,
		api   = &_hot_api_table,
		self  = transform_to_hot_entity(self_tH),
		dt    = dt,
		frame = f_ptr,
	}
	fault, ok := crash_journal.sandbox_exec(_hot_call_thunk_proc, &thunk)
	if !ok {
		entry.faulted = true
		reason := crash_journal.sandbox_fault_reason(&fault)
		ffile  := crash_journal.sandbox_fault_file(&fault)
		fproc  := crash_journal.sandbox_fault_proc(&fault)
		if reason == "" do reason = "Unhandled runtime exception inside hot cartridge"
		if ffile == ""  do ffile  = entry.source_file

		context.allocator = runtime.default_allocator()
		_free_last_sandbox_fault()
		_hot_reg.last_fault = Hot_Sandbox_Fault_Report{
			has_fault = true,
			proc_name = strings.clone(fproc != "" ? fproc : entry.name),
			reason    = strings.clone(reason),
			file      = strings.clone(ffile),
			line      = fault.line,
			entity    = self_tH,
			code      = fault.code,
		}
		log.error(fmt.tprintf("[Sandbox] Caught runtime crash in '%s' (%s:%d): %s — procedure disarmed safely without crashing editor",
			entry.name, ffile, fault.line, reason))
		return false
	}

	// Post-call runtime integrity scrubber: verify heap canaries and sanitize NaN/Inf Transforms.
	corrupted_var, nan_repaired := visual_script_verify_and_repair_entity(self_tH, pre_pos, pre_rot, pre_scale)
	if nan_repaired {
		log.warning(fmt.tprintf("[Watchdog Scrubber] Repaired NaN/Inf Transform written by '%s' before Physics/GPU corruption", entry.name))
	}
	if corrupted_var != "" {
		entry.faulted = true
		context.allocator = runtime.default_allocator()
		_free_last_sandbox_fault()
		msg := fmt.tprintf("Heap buffer overflow detected (canary smashed on variable '%s') — buffer repaired & procedure disarmed", corrupted_var)
		_hot_reg.last_fault = Hot_Sandbox_Fault_Report{
			has_fault = true,
			proc_name = strings.clone(entry.name),
			reason    = strings.clone(msg),
			file      = strings.clone(entry.source_file),
			line      = 1,
			entity    = self_tH,
			code      = 0xC0000374,
		}
		log.error(fmt.tprintf("[Sandbox Scrubber] %s", msg))
		return false
	}
	return true
}

hot_cartridge_set_quarantined :: proc(q: bool) {
	_ensure_hot_init()
	_hot_reg.quarantined = q
}

hot_cartridge_is_quarantined :: proc() -> bool {
	return _hot_reg.quarantined
}

@(private = "file")
_free_last_sandbox_fault :: proc() {
	if _hot_reg.last_fault.proc_name != "" do delete(_hot_reg.last_fault.proc_name)
	if _hot_reg.last_fault.reason    != "" do delete(_hot_reg.last_fault.reason)
	if _hot_reg.last_fault.file      != "" do delete(_hot_reg.last_fault.file)
	_hot_reg.last_fault = {}
}

hot_cartridge_clear_faults :: proc() {
	if !_hot_reg.initialized do return
	context.allocator = runtime.default_allocator()
	for &e in _hot_reg.entries {
		e.faulted = false
	}
	_hot_reg.quarantined = false
	_free_last_sandbox_fault()
}

hot_cartridge_last_sandbox_fault :: proc() -> Hot_Sandbox_Fault_Report {
	return _hot_reg.last_fault
}

// Direct O(1) (`~1.5 ns`) invocation by immortal `slot_idx` — survives `F7` DLL hot-swaps!
hot_proc_invoke_slot :: proc(slot_idx: i32, self_tH: Transform_Handle, dt: f32, frame: ^hot.Hot_Call_Frame) -> bool {
	_ensure_hot_init()
	return _invoke_entry_sandboxed(int(slot_idx), self_tH, dt, frame)
}

// Invokes a registered `@(hot_proc)` or transpiled `.mhgraph` procedure.
hot_proc_invoke :: proc(name: string, self_tH: Transform_Handle, dt: f32, frame: ^hot.Hot_Call_Frame) -> bool {
	_ensure_hot_init()
	idx, ok := _hot_reg.by_name[name]
	if !ok do return false
	return _invoke_entry_sandboxed(idx, self_tH, dt, frame)
}

// Loads a compiled `hot_cartridge_<N>.dll` and atomically swaps every exported
// `@(hot_proc)` / `.mhgraph` procedure pointer in `< 1 ms` without touching World or VRAM!
hot_cartridge_load_dll :: proc(dll_path: string) -> (swapped_count: int, ok: bool) {
	_ensure_hot_init()
	lib, loaded := dynlib.load_library(dll_path)
	if !loaded {
		_set_hot_status(.Compile_Failed, fmt.tprintf("Failed to load cartridge DLL: %s", dll_path), "")
		return 0, false
	}

	// Optional schema-hash guard exported by the cartridge (`mh_hot_cartridge_schema_hash`).
	if sym_hash, has_hash := dynlib.symbol_address(lib, "mh_hot_cartridge_schema_hash"); has_hash && sym_hash != nil {
		hash_fn := cast(proc "c" () -> u64)sym_hash
		dll_hash := hash_fn()
		if _hot_reg.boot_schema_hash != 0 && dll_hash != 0 && dll_hash != _hot_reg.boot_schema_hash {
			_ = dynlib.unload_library(lib)
			_set_hot_status(.Schema_Changed, "Component struct layout changed — click Relaunch (RAM Handoff) to apply!", "")
			return 0, false
		}
	}

	sym_query, found := dynlib.symbol_address(lib, "mh_hot_cartridge_query")
	if !found || sym_query == nil {
		_ = dynlib.unload_library(lib)
		_set_hot_status(.Compile_Failed, "Cartridge DLL missing `mh_hot_cartridge_query` export", "")
		return 0, false
	}

	query_fn := cast(hot.Hot_Cartridge_Query_Fn)sym_query
	{
		context.allocator = runtime.default_allocator()
		_hot_reg.generation += 1
		gen := _hot_reg.generation
		append(&_hot_reg.loaded_libs, lib)

		i: i32 = 0
		for {
			c_name: cstring = nil
			fn_ptr: hot.Hot_Proc_Fn = nil
			if !query_fn(i, &c_name, &fn_ptr) do break
			i += 1
			if c_name == nil || fn_ptr == nil do continue
			s_name := string(c_name)
			if idx, exists := _hot_reg.by_name[s_name]; exists {
				_hot_reg.entries[idx].active_fn = fn_ptr
				_hot_reg.entries[idx].hot_gen   = gen
				_hot_reg.entries[idx].faulted   = false
			} else {
				cname := strings.clone(s_name)
				nidx  := len(_hot_reg.entries)
				append(&_hot_reg.entries, Hot_Proc_Entry{
					name      = cname,
					static_fn = nil,
					active_fn = fn_ptr,
					hot_gen   = gen,
				})
				_hot_reg.by_name[cname] = nidx
			}
			swapped_count += 1
		}
	}

	crash_journal.refresh_symbols()
	_hot_reg.quarantined = false
	_free_last_sandbox_fault()
	return swapped_count, true
}

// Unloads all dynamically loaded cartridge DLLs and reverts active pointers to static procs.
hot_cartridge_unload_all :: proc() {
	if !_hot_reg.initialized do return
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if _hot_reg.build_pending {
		bg_process_kill(&_hot_reg.build_proc)
		_hot_reg.build_pending = false
	}
	visual_script_scrub_external_cstrings()
	for &e in _hot_reg.entries {
		e.active_fn = e.static_fn
		e.hot_gen   = 0
	}
	for lib in _hot_reg.loaded_libs {
		_ = dynlib.unload_library(lib)
	}
	clear(&_hot_reg.loaded_libs)
}

// Frees all hot-cartridge registry allocations and unloads loaded cartridge DLLs at shutdown.
hot_cartridge_shutdown :: proc() {
	if !_hot_reg.initialized do return
	hot_cartridge_unload_all()
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	for e in _hot_reg.entries {
		if e.name != "" do delete(e.name)
		if e.source_file != "" do delete(e.source_file)
	}
	delete(_hot_reg.entries)
	delete(_hot_reg.by_name)
	delete(_hot_reg.loaded_libs)

	for m in _hot_reg.sig_metas {
		if m.proc_name != "" do delete(m.proc_name)
		if m.display_title != "" do delete(m.display_title)
		if m.namespace_name != "" do delete(m.namespace_name)
		if m.doc_comment != "" do delete(m.doc_comment)
		if m.source_proc_name != "" do delete(m.source_proc_name)
		for p in m.pins {
			if p.name != "" do delete(p.name)
			if p.custom_type != "" do delete(p.custom_type)
		}
		if len(m.pins) > 0 do delete(m.pins)
	}
	delete(_hot_reg.sig_metas)
	delete(_hot_reg.sig_by_name)

	if _hot_reg.last_message != "" do delete(_hot_reg.last_message)
	if _hot_reg.last_stderr != "" do delete(_hot_reg.last_stderr)
	if _hot_reg.build_target_dll != "" do delete(_hot_reg.build_target_dll)
	if _hot_reg.build_err_file != "" do delete(_hot_reg.build_err_file)
	_free_last_sandbox_fault()
	_hot_reg = {}
}

@(private = "file")
_set_hot_status :: proc(st: Hot_Reload_Status, msg: string, err_detail: string) {
	context.allocator = runtime.default_allocator()
	_hot_reg.status = st
	if _hot_reg.last_message != "" do delete(_hot_reg.last_message)
	if _hot_reg.last_stderr  != "" do delete(_hot_reg.last_stderr)
	_hot_reg.last_message = msg != "" ? strings.clone(msg) : ""
	_hot_reg.last_stderr  = err_detail != "" ? strings.clone(err_detail) : ""
}

hot_cartridge_status :: proc() -> (status: Hot_Reload_Status, generation: int, last_ms: f32, msg: string, stderr_text: string) {
	return _hot_reg.status, _hot_reg.generation, _hot_reg.last_swap_ms, _hot_reg.last_message, _hot_reg.last_stderr
}

hot_cartridge_next_generation :: proc() -> int {
	_ensure_hot_init()
	return _hot_reg.generation + 1
}

// Resolves Odin compiler binary: bundled `<repo>/tools/odin/` first for standalone portability,
// then `ODIN_ROOT`, then `PATH`.
resolve_odin_binary :: proc(allocator := context.temp_allocator) -> string {
	path, _ := resolve_host_tool("odin", "tools/odin", "", true, allocator)
	return path
}

// Triggers an asynchronous, single-flight `odin build builds/hot_cartridge_src -build-mode:dll`
// (or `mh hot` if `full_regen` is requested for brand-new `@(hot_proc)` names).
// Never blocks the render or physics loop!
hot_cartridge_trigger_async_build :: proc(full_regen: bool = false) -> bool {
	_ensure_hot_init()
	if _hot_reg.build_pending do return false

	repo_root := resolve_repo_root(context.temp_allocator)
	odin_exe  := resolve_odin_binary(context.temp_allocator)
	next_gen  := _hot_reg.generation + 1
	dll_ext   :: ".dll" when ODIN_OS == .Windows else (".dylib" when ODIN_OS == .Darwin else ".so")

	builds_dir, _ := filepath.join({repo_root, "builds"}, context.temp_allocator)
	_ = os.make_directory_all(builds_dir)

	dll_rel := fmt.tprintf("builds/hot_cartridge_%d%s", next_gen, dll_ext)
	dll_abs, _ := filepath.join({repo_root, dll_rel}, context.temp_allocator)
	err_abs, _ := filepath.join({repo_root, fmt.tprintf("builds/hot_cartridge_%d.err", next_gen)}, context.temp_allocator)
	src_abs, _ := filepath.join({repo_root, "builds/hot_cartridge_src"}, context.temp_allocator)

	proj_dir := active_project_root()
	need_mh_hot := full_regen || !os.exists(src_abs) || (proj_dir != "" && project_dir_has_odin_code(proj_dir))
	cmd := make([dynamic]string, context.temp_allocator)
	if need_mh_hot {
		append(&cmd, odin_exe, "run", "tools/mh", "--", "hot", fmt.tprintf("--out=%s", dll_rel))
		if proj_dir != "" {
			append(&cmd, fmt.tprintf("--project=%s", proj_dir))
		}
	} else {
		append(
			&cmd,
			odin_exe,
			"build",
			"builds/hot_cartridge_src",
			"-build-mode:dll",
			"-collection:haati=haati",
			"-collection:moonhug=haati",
			"-ignore-unknown-attributes",
		)
		if proj_dir != "" {
			append(&cmd, fmt.tprintf("-collection:project=%s", proj_dir))
			slug := active_project_slug(context.temp_allocator)
			if slug != "" && slug != "project" && slug != "haati" && slug != "moonhug" && slug != "void_odin" {
				append(&cmd, fmt.tprintf("-collection:%s=%s", slug, proj_dir))
			}
		}
		append(&cmd, fmt.tprintf("-out:%s", dll_rel))
	}

	proc_handle, started := bg_process_start_to_file(repo_root, cmd[:], nil, err_abs)
	if !started {
		_set_hot_status(.Compile_Failed, "Failed to start hidden Odin compiler for hot cartridge", "")
		return false
	}

	context.allocator = runtime.default_allocator()
	_hot_reg.build_pending    = true
	_hot_reg.build_proc       = proc_handle
	_hot_reg.build_target_gen = next_gen
	if _hot_reg.build_target_dll != "" do delete(_hot_reg.build_target_dll)
	if _hot_reg.build_err_file   != "" do delete(_hot_reg.build_err_file)
	_hot_reg.build_target_dll = strings.clone(dll_abs)
	_hot_reg.build_err_file   = strings.clone(err_abs)
	_hot_reg.build_started_at = time.tick_now()
	_hot_reg.sandbox_active_mode = false
	_set_hot_status(.Compiling, fmt.tprintf("Compiling hot_cartridge_%d...", next_gen), "")
	return true
}

// Builds `hot_cartridge_<N>.dll` inside `builds/sandbox_cartridge/` by mirroring `haati/hot_scripts`
// and overlaying unsaved RAM edits without modifying project files on disk.
hot_cartridge_trigger_sandbox_build :: proc(overrides: []Sandbox_File_Override) -> bool {
	_ensure_hot_init()
	if _hot_reg.build_pending do return false

	repo_root := resolve_repo_root(context.temp_allocator)
	odin_exe  := resolve_odin_binary(context.temp_allocator)
	next_gen  := _hot_reg.generation + 1
	dll_ext   :: ".dll" when ODIN_OS == .Windows else (".dylib" when ODIN_OS == .Darwin else ".so")

	builds_dir, _      := filepath.join({repo_root, "builds"}, context.temp_allocator)
	sb_root, _         := filepath.join({builds_dir, "sandbox_cartridge"}, context.temp_allocator)
	sb_hot_dir, _      := filepath.join({sb_root, "hot_scripts"}, context.temp_allocator)
	sb_src_dir, _      := filepath.join({sb_root, "src"}, context.temp_allocator)
	_ = os.make_directory_all(sb_hot_dir)
	_ = os.make_directory_all(sb_src_dir)

	// Clear old sandbox hot_scripts files before seeding mirror.
	if dh, derr := os.open(sb_hot_dir); derr == nil {
		if old_entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for oe in old_entries {
				if oe.type == .Directory do continue
				if fp, jerr := filepath.join({sb_hot_dir, oe.name}, context.temp_allocator); jerr == nil {
					_ = os.remove(fp)
				}
			}
		}
		os.close(dh)
	}

	// Copy committed `haati/hot_scripts/*.odin` files first.
	orig_hot_dir, _ := filepath.join({repo_root, "haati", "hot_scripts"}, context.temp_allocator)
	if dh, derr := os.open(orig_hot_dir); derr == nil {
		if cur_entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for ce in cur_entries {
				if ce.type == .Directory || !strings.has_suffix(ce.name, ".odin") do continue
				src_f, _ := filepath.join({orig_hot_dir, ce.name}, context.temp_allocator)
				dst_f, _ := filepath.join({sb_hot_dir, ce.name}, context.temp_allocator)
				if raw, rerr2 := os.read_entire_file(src_f, context.temp_allocator); rerr2 == nil {
					_ = os.write_entire_file(dst_f, raw)
				}
			}
		}
		os.close(dh)
	}

	// Apply in-RAM sandbox overrides (unsaved script buffers / Zone 1+2 .bodin outputs).
	for ov in overrides {
		if ov.rel_hot_name == "" do continue
		dst_f, _ := filepath.join({sb_hot_dir, filepath.base(ov.rel_hot_name)}, context.temp_allocator)
		_ = os.write_entire_file(dst_f, transmute([]u8)ov.content)
	}

	// Collect all `@(hot_proc)` procedure symbols from `sb_hot_dir/*.odin`.
	hot_syms := make([dynamic]string, 0, 16, context.temp_allocator)
	seen_syms := make(map[string]bool, 16, context.temp_allocator)
	if dh, derr := os.open(sb_hot_dir); derr == nil {
		if sb_entries, rerr := os.read_dir(dh, -1, context.temp_allocator); rerr == nil {
			for se in sb_entries {
				if se.type == .Directory || !strings.has_suffix(se.name, ".odin") do continue
				fp, _ := filepath.join({sb_hot_dir, se.name}, context.temp_allocator)
				raw, rerr2 := os.read_entire_file(fp, context.temp_allocator)
				if rerr2 != nil do continue
				saw_attr := false
				for ln in strings.split_lines(string(raw), context.temp_allocator) {
					tl := strings.trim_space(strings.trim_suffix(ln, "\r"))
					if strings.contains(tl, "@(hot_proc)") {
						saw_attr = true
						if rest_i := strings.index(tl, ":: proc"); rest_i > 0 {
							toks := strings.fields(tl[:rest_i], context.temp_allocator)
							if len(toks) > 0 {
								sym := toks[len(toks) - 1]
								if !(sym in seen_syms) {
									seen_syms[sym] = true
									append(&hot_syms, sym)
								}
							}
							saw_attr = false
						}
						continue
					}
					if saw_attr {
						if tl == "" || strings.has_prefix(tl, "//") do continue
						if rest_i := strings.index(tl, "::"); rest_i > 0 {
							sym := strings.trim_space(tl[:rest_i])
							if !(sym in seen_syms) {
								seen_syms[sym] = true
								append(&hot_syms, sym)
							}
						}
						saw_attr = false
					}
				}
			}
		}
		os.close(dh)
	}

	sb_src_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb_src_b, "package hot_cartridge_sandbox_dll\n\n")
	strings.write_string(&sb_src_b, "import hot \"haati:engine/hot_api\"\n")
	strings.write_string(&sb_src_b, "import hot_scripts \"../hot_scripts\"\n\n")
	strings.write_string(&sb_src_b, "_Entry :: struct {\n\tname: cstring,\n\tfn:   hot.Hot_Proc_Fn,\n}\n\n")
	strings.write_string(&sb_src_b, "@(rodata)\n_ENTRIES := [?]_Entry{\n")
	for sym in hot_syms {
		fmt.sbprintf(&sb_src_b, "\t{{%q, hot_scripts.%s}},\n", sym, sym)
	}
	strings.write_string(&sb_src_b, "}\n\n")
	fmt.sbprintf(&sb_src_b, "@(export)\nmh_hot_cartridge_schema_hash :: proc \"c\" () -> u64 {{\n\treturn 0x%x\n}}\n\n", hot_cartridge_boot_schema_hash())
	strings.write_string(&sb_src_b, "@(export)\nmh_hot_cartridge_query :: proc \"c\" (index: i32, out_name: ^cstring, out_fn: ^hot.Hot_Proc_Fn) -> bool {\n\tif index < 0 || int(index) >= len(_ENTRIES) do return false\n\tif out_name != nil do out_name^ = _ENTRIES[index].name\n\tif out_fn   != nil do out_fn^   = _ENTRIES[index].fn\n\treturn true\n}\n")

	cart_src_path, _ := filepath.join({sb_src_dir, "cartridge_generated.odin"}, context.temp_allocator)
	if os.write_entire_file(cart_src_path, transmute([]u8)strings.to_string(sb_src_b)) != nil {
		return false
	}

	dll_rel := fmt.tprintf("builds/hot_cartridge_%d%s", next_gen, dll_ext)
	dll_abs, _ := filepath.join({repo_root, dll_rel}, context.temp_allocator)
	err_abs, _ := filepath.join({repo_root, fmt.tprintf("builds/hot_cartridge_%d.err", next_gen)}, context.temp_allocator)

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_exe, "build", "builds/sandbox_cartridge/src", "-build-mode:dll", "-collection:haati=haati", "-collection:moonhug=haati", "-ignore-unknown-attributes")
	if proj_dir := active_project_root(); proj_dir != "" {
		append(&cmd, fmt.tprintf("-collection:project=%s", proj_dir))
		slug := active_project_slug(context.temp_allocator)
		if slug != "" && slug != "project" && slug != "haati" && slug != "moonhug" && slug != "void_odin" {
			append(&cmd, fmt.tprintf("-collection:%s=%s", slug, proj_dir))
		}
	}
	append(&cmd, fmt.tprintf("-out:%s", dll_rel))

	proc_handle, started := bg_process_start_to_file(repo_root, cmd[:], nil, err_abs)
	if !started {
		_set_hot_status(.Compile_Failed, "Failed to start sandbox Odin compiler", "")
		return false
	}

	context.allocator = runtime.default_allocator()
	_hot_reg.build_pending       = true
	_hot_reg.build_proc          = proc_handle
	_hot_reg.build_target_gen    = next_gen
	_hot_reg.sandbox_active_mode = true
	if _hot_reg.build_target_dll != "" do delete(_hot_reg.build_target_dll)
	if _hot_reg.build_err_file   != "" do delete(_hot_reg.build_err_file)
	_hot_reg.build_target_dll = strings.clone(dll_abs)
	_hot_reg.build_err_file   = strings.clone(err_abs)
	_hot_reg.build_started_at = time.tick_now()
	_set_hot_status(.Compiling, fmt.tprintf("Sandbox compiling hot_cartridge_%d (RAM heap)...", next_gen), "")
	return true
}

// Polls the background cartridge build once per frame (`timeout = 0`, non-blocking)
// and swaps the new DLL at frame boundary as soon as compilation succeeds.
hot_cartridge_poll :: proc() -> (just_swapped: bool) {
	if !_hot_reg.build_pending do return false

	exited, exit_code := bg_process_poll(&_hot_reg.build_proc)
	if !exited {
		if time.duration_seconds(time.tick_since(_hot_reg.build_started_at)) > 30.0 {
			bg_process_kill(&_hot_reg.build_proc)
			_hot_reg.build_pending = false
			if _hot_reg.build_err_file != "" {
				_ = os.remove(_hot_reg.build_err_file)
			}
			_set_hot_status(.Compile_Failed, "Hot-Swap compile timed out (>30s)", "")
			log.error("[HotReload] Compile timed out (>30s); killed child process")
		}
		return false
	}

	_hot_reg.build_pending = false
	elapsed_ms := f32(time.duration_milliseconds(time.tick_since(_hot_reg.build_started_at)))
	_hot_reg.last_swap_ms = elapsed_ms

	err_bytes, _ := os.read_entire_file(_hot_reg.build_err_file, context.temp_allocator)
	err_txt := strings.trim_space(string(err_bytes))
	_ = os.remove(_hot_reg.build_err_file)

	if exit_code != 0 {
		_set_hot_status(.Compile_Failed, fmt.tprintf("Hot-Swap compile failed (exit %d)", exit_code), err_txt)
		log.errorf("[HotReload] Compile failed:\n%s", err_txt)
		return false
	}

	cnt, ok := hot_cartridge_load_dll(_hot_reg.build_target_dll)
	if !ok do return false

	_set_hot_status(
		.Swapped_OK,
		fmt.tprintf("Hot-Swapped %d proc(s) in %.0f ms (Gen #%d)", cnt, elapsed_ms, _hot_reg.generation),
		"",
	)
	log.infof("[HotReload] Swapped %d proc(s) from %s in %.1f ms (Gen #%d)", cnt, _hot_reg.build_target_dll, elapsed_ms, _hot_reg.generation)
	return true
}
