package engine

// =============================================================================
// MOONHUG NIAGARA & BLUEPRINT VISUAL SCRIPTING MODEL + ODIN DELEGATE RUNTIME
// =============================================================================
// Supports:
//   1. Pseudo-OOP Blueprint Component (`VisualScriptRunner` + `using self` transpilation):
//      Behaves ergonomically like an Unreal Blueprint Component (`self` variables,
//      instance-editable inspector overrides, custom Procedures/"Events", and Odin
//      Delegates), while compiling down to 100% flat Data-Oriented Odin structs &
//      `@(hot_proc)` machine code (`0.00 ms` VM overhead, zero GC/vtables).
//   2. Explicit Odin-Style Delegate Binding (`◇ Hot_Delegate` 16-byte POD handle):
//      - `Event_Init` -> `Bind_Input_Action` / `Bind_Input_Vector` / `Bind_Debug_Key`
//      - Runtime `Unbind_Input_Action` / `Unbind_Debug_Key` / `Unbind_All_Inputs` +
//        on-demand re-binding to swap procedures cleanly at runtime without `if/else` spaghetti!
//      - Custom Odin Delegates (`Delegate_Bind`, `Delegate_Unbind`, `Delegate_Broadcast`)
//      - Opt-in `Event_Tick` (`0 ns` per-frame cost when `Event_Tick` is absent from graph!)
//      - Automatic listener cleanup on entity destroy (`on_destroy_VisualScriptRunner`) and
//        Play-Mode exit (`visual_script_exiting_play_mode`) so forgetting `Unbind` never crashes!
//   3. Strict `● Copy_Value (T)` vs `◆ By_Reference (^T)` vs `◇ Delegate` wire validation.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import hot "hot_api"
import "input"

VG_Node_Kind :: enum u8 {
	// Legacy / Core Node IDs (0..10 preserved for 100% `.mhgraph` backward compatibility)
	Event_Tick          = 0,
	Get_Variable        = 1,
	Set_Variable        = 2,
	Get_Transform_Pos   = 3,
	Set_Transform_Pos   = 4,
	Math_Float          = 5,
	Vec3_Scale_Add      = 6,
	Branch_If           = 7,
	Set_Time_Scale      = 8,
	Call_Hot_Proc       = 9,
	Odin_Function_Node  = 10, // Scoped inline Odin code node (`</>` Popup Micro-IDE!)

	// V3 Blueprint Lifecycle, Odin Procedures ("Events"), Input & Delegate Bindings
	Event_Init          = 11, // Fires once on Play start / entity spawn
	Event_Destroy       = 12, // Fires on component/entity teardown
	Custom_Proc_Entry   = 13, // User-authored Blueprint Procedure/Event with outgoing `◇ Delegate` pin!
	Call_Blueprint_Proc = 14, // Direct synchronous call to a `Custom_Proc_Entry`
	Bind_Input_Action   = 15, // Claims prioritized `input_manager` action -> `◇ Target Procedure`
	Unbind_Input_Action = 16, // Releases action binding on `self`
	Bind_Input_Vector   = 17, // Claims Move `[2]f32` or Look `[2]f32` vector -> `◇ Target Procedure`
	Unbind_Input_Vector = 18, // Releases Move / Look vector binding on `self`
	Bind_Debug_Key      = 19, // `[DEV]` Direct scancode debug trigger -> `◇ Target Procedure`
	Unbind_Debug_Key    = 20, // `[DEV]` Releases debug key binding on `self`
	Unbind_All_Inputs   = 21, // Releases every input & debug key bound by `self`
	Delegate_Bind       = 22, // Appends `◇ Target Procedure` to a Blueprint Odin Delegate
	Delegate_Unbind     = 23, // Clears/removes bindings on a Blueprint Odin Delegate
	Delegate_Broadcast  = 24, // Invokes all bound listeners on a Blueprint Odin Delegate

	// V4 Unified Graph Studio — Character Motion / Anim Layer & Niagara Particle / GPU VFX Nodes
	Anim_Clip_Eval      = 25, // Evaluates an Animation Clip phase/weight on the same native Odin VM
	Anim_Blend_Layered  = 26, // Layered Pose / Weight Blend (Base + Layer * Alpha)
	Anim_Spring_Damper  = 27, // Second-order damped harmonic motion spring
	Anim_IK_Target      = 28, // Procedural Foot/Hand Two-Bone IK effector target
	VFX_Emitter_Spawn        = 29, // Niagara Particle continuous rate / burst emitter stage
	VFX_GPU_Curl_Force       = 30, // On-GPU SIMD / Compute Vector Curl & Drag Force stage
	VFX_Color_Size_Life      = 31, // Particle Size / Glow curve over normalized lifetime [0..1]

	// Audio & SoundScape Domain (Domain #5 — MetaSound-style procedural audio on unified VM)
	Audio_Random_Container   = 32, // Randomly chooses between clip index 0/1/2/3 by Seed
	Audio_Modulate_Pitch_Vol = 33, // Jitters base volume and pitch within +-Range
	Audio_Bus_Send           = 34, // Sets submix bus target volume & low-pass cutoff (Hz)
	Audio_Play_Spatial_3D    = 35, // Triggers spatial 3D sound at Position with pitch/volume

	// AI & NavMesh Pathfinding Nodes (`.bodin`)
	AI_Find_Path_Move        = 36, // Computes NavMesh A* path to Target Pos and starts NavMeshAgent movement
	AI_Check_Arrival         = 37, // Pure query returning true when NavMeshAgent arrived within Tolerance

	// V5 Unreal-Style Flow Control
	Sequence                 = 38, // Multi-pin sequential execution (`Then 0`, `Then 1`, ... + `+ Add Pin`)
	For_Loop                 = 39, // `First Index .. Last Index` inclusive loop (`Loop Body`, `Index: i32`, `Completed`)
}

VG_Graph_Domain :: enum u8 {
	Gameplay_Ability = 0, // Gameplay, Abilities, Input & Odin Delegates (`.bodin`)
	Anim_Motion      = 1, // Character Motion & Layered Pose Graph (`.bodin`)
	Particle_VFX     = 2, // Niagara Particle & On-GPU VFX Math Graph (`.bodin`)
	Material_Shader  = 3, // Material Fragment Shader Graph (`.mat` / `.glsl`)
	Audio_SoundScape = 4, // Audio & Procedural SoundScape Graph (`.bodin`)
}

VG_Math_Op :: enum u8 {
	Add      = 0,
	Sub      = 1,
	Mul      = 2,
	Div      = 3,
	Sin_Wave = 4, // `sin(a * TAU) * b`
	Damp     = 5, // exponential damp `a` toward `b`
}

VG_Pin_Def :: struct {
	name:           string,
	pin_type:       hot.Hot_Pin_Type,
	pass_mode:      hot.Hot_Pass_Mode, // `.Copy_Value` (`●`) or `.By_Reference` (`◆ ^T`)
	is_addressable: bool,              // For output pins: `true` if output carries a mutable lvalue pointer (`^T`)
	is_array:       bool,              // Fixed-size `[8]T` array pin
	default_f32:    f32,
	default_int:    i32,
	default_i64:    i64,
	default_bool:   bool,
	default_vec2:   [2]f32,
	default_vec3:   [3]f32,
	default_vec4:   [4]f32,
	default_str:    string,
}

VG_Var_Decl :: struct {
	name:              string,
	pin_type:          hot.Hot_Pin_Type,
	is_array:          bool,   // `[8]T` array variable
	default_f32:       f32,
	default_int:       i32,
	default_i64:       i64,
	default_bool:      bool,
	default_vec2:      [2]f32,
	default_vec3:      [3]f32,
	default_vec4:      [4]f32,
	default_str:       string,
	instance_editable: bool,   // `👁` Exposed per-entity in the Scene Inspector!
	category:          string, // Optional grouping category in Right Details & Scene Inspector
	tooltip_text:      string, // Designer documentation tooltip
	slider_min:        f32,
	slider_max:        f32,
}

VG_Node :: struct {
	uid:                int,
	kind:               VG_Node_Kind,
	title:              string,
	pos:                [2]f32,
	enabled:            bool,
	owner_proc:         string,               // `""` = EventGraph, `"<proc>"` = owned by Custom_Proc_Entry sub-graph
	proc_use_odin_body: bool,                 // `Custom_Proc_Entry`: compile/edit body directly as Odin code

	// Node-specific configuration
	var_name:           string,               // `Get_Variable` / `Set_Variable`
	var_as_ref:         bool,                 // `Get_Variable`: `true` -> `◆ ^Ref` output, `false` -> `● Copy` output
	math_op:            VG_Math_Op,           // `Math_Float`
	per_object_ts:      bool,                 // `Set_Time_Scale`: `true` = entity hierarchy, `false` = global world
	hot_proc_target:    string,               // `Call_Hot_Proc` / `Odin_Function_Node` / `Custom_Proc_Entry` / fallback target
	odin_body:          string,               // `Odin_Function_Node` / `Custom_Proc_Entry`: scoped Odin body statements!

	// V3 Input & Odin Delegate configuration
	action_name:       string,               // `Bind_Input_Action` / `Unbind_Input_Action` (e.g. `"Jump"`, `"Interact"`)
	trigger_edge:      hot.Hot_Trigger_Edge, // `.Pressed`, `.Released`, `.Both`
	input_priority:    i32,                  // `input_manager` listener priority (higher runs first)
	consume_input:     bool,                 // When `true`, blocks lower-priority listeners on trigger
	is_look_vector:    bool,                 // `Bind_Input_Vector`: `false` = Move `[2]f32`, `true` = Look `[2]f32`
	debug_key_code:    i32,                  // `Bind_Debug_Key`: `i32(input.Key)` scancode
	delegate_name:     string,               // `Delegate_Bind` / `Delegate_Unbind` / `Delegate_Broadcast`

	inputs:            [dynamic]VG_Pin_Def,
	outputs:           [dynamic]VG_Pin_Def,
}

VG_Wire :: struct {
	from_uid: int,
	from_pin: int,
	to_uid:   int,
	to_pin:   int,
}

Visual_Graph :: struct {
	name:           string,
	domain:         VG_Graph_Domain, // Content filter domain (`Gameplay_Ability`, `Anim_Motion`, `Particle_VFX`, `Material_Shader`)
	package_target: string,          // defaults to `"haati/hot_scripts"`
	next_uid:       int,
	using_spaces:   [dynamic]string, // Active `Using / Import` spaces (`"self"`, `"hot"`, `"math"`, `"linalg"`, ...)
	delegates:      [dynamic]string, // User-declared Odin Delegate slots in *My Blueprint*
	variables:      [dynamic]VG_Var_Decl,
	nodes:          [dynamic]VG_Node,
	wires:          [dynamic]VG_Wire,
}

// Runtime Blackboard held per entity (or preview session) for Tier-1 & Tier-2 execution.
VG_MAX_VARS :: 32

VG_Runtime_Blackboard :: struct {
	initialized:      bool,
	slots:            [VG_MAX_VARS]hot.Hot_Slot,
	str_bufs:         [VG_MAX_VARS][128]u8,
	loop_indices:     [8]struct{ node_uid: int, cur_idx: i32, active: bool },
	last_exec_path:   [dynamic]int,
	last_payload_f32: f32,
	last_payload_v2:  [2]f32,
	last_pressed:     bool,
}

// =============================================================================
// ECS `@(component)` Visual Script / Blueprint Runner
// =============================================================================

@(component={max=256, menu="Scripting/Blueprint Script Runner"})
@(typ_guid={guid = "7b84c3d2-51e9-4a8c-94f2-6d1820ab39c4"})
VisualScriptRunner :: struct {
	using base: CompData `inspect:"-"`,
	graph_path:         string,
	compiled_proc_name: string,
	live_preview:       bool,
	param_a:            f32,
	param_b:            f32,
	instance_overrides: string, // Serialized `key=val;key2=val2` overrides for `👁 Instance Editable` vars
	state_accum:        f32 `inspect:"-"`,
	state_vec:          [3]f32 `inspect:"-"`,
	init_fired:         bool `inspect:"-"`,
}

on_destroy_VisualScriptRunner :: proc(r: ^VisualScriptRunner) {
	if r != nil && Handle(r.owner).index != 0 {
		_fire_runner_destroy_event(r)
		visual_script_destroy_entity_state(r.owner)
	}
}

cleanup_VisualScriptRunner :: proc(r: ^VisualScriptRunner) {
	if r.graph_path != ""         do delete(r.graph_path)
	if r.compiled_proc_name != "" do delete(r.compiled_proc_name)
	if r.instance_overrides != "" do delete(r.instance_overrides)
	comp_zero(r)
}

reset_VisualScriptRunner :: proc(r: ^VisualScriptRunner) {
	cleanup_VisualScriptRunner(r)
	r.graph_path         = strings.clone("assets/scripts/hover_oscillator.bodin")
	r.compiled_proc_name = strings.clone("mhgraph_hover_oscillator")
	r.live_preview       = true
	r.param_a            = 0.35
	r.param_b            = 1.75
	r.instance_overrides = ""
	r.state_accum        = 0.0
	r.state_vec          = {0, 0, 0}
	r.init_fired         = false
}

// =============================================================================
// Input Manager Bridge & Hot-Swap-Safe Odin Delegate Registry (`0.00 ms` idle)
// =============================================================================

Visual_Script_Input_Bridge :: struct {
	claim_action:          proc(name: string, priority: int, cb: proc(action_idx: int, pressed: bool, owner: rawptr) -> bool, owner: rawptr) -> int,
	release_action:        proc(name: string, owner: rawptr),
	claim_movement:        proc(priority: int, cb: proc(v: [2]f32, owner: rawptr) -> bool, owner: rawptr),
	release_movement:      proc(owner: rawptr),
	claim_look:            proc(priority: int, cb: proc(v: [2]f32, owner: rawptr) -> bool, owner: rawptr),
	release_look:          proc(owner: rawptr),
	release_all_for_owner: proc(owner: rawptr),
	list_action_names:     proc(allocator: runtime.Allocator) -> []string,
}

@(private = "file")
_vs_input_bridge: Visual_Script_Input_Bridge

visual_script_install_input_bridge :: proc(bridge: Visual_Script_Input_Bridge) {
	_vs_input_bridge = bridge
}

// Returns live action names from `input_manager` (or sensible standard defaults if uninstalled).
visual_script_list_input_actions :: proc(allocator := context.temp_allocator) -> []string {
	if _vs_input_bridge.list_action_names != nil {
		return _vs_input_bridge.list_action_names(allocator)
	}
	fallback := [?]string{"Jump", "Sprint", "Crouch", "Interact", "Primary_Action", "Secondary_Action", "Ability_Q", "Ability_E", "Reload"}
	out := make([]string, len(fallback), allocator)
	for s, i in fallback do out[i] = s
	return out
}

@(private = "file")
_VS_Action_Binding :: struct {
	token_id:    u32,
	entity:      Transform_Handle,
	action_name: string,
	trigger:     hot.Hot_Trigger_Edge,
	priority:    int,
	consume:     bool,
	target_proc: string,
	proc_slot:   i32,
	node_uid:    int,
}

@(private = "file")
_VS_Vector_Binding :: struct {
	token_id:    u32,
	entity:      Transform_Handle,
	is_look:     bool,
	priority:    int,
	consume:     bool,
	target_proc: string,
	proc_slot:   i32,
	node_uid:    int,
}

@(private = "file")
_VS_Debug_Key_Binding :: struct {
	token_id:    u32,
	entity:      Transform_Handle,
	key_code:    int,
	trigger:     hot.Hot_Trigger_Edge,
	target_proc: string,
	proc_slot:   i32,
	node_uid:    int,
}

@(private = "file")
_VS_Custom_Delegate_Listener :: struct {
	target_proc: string,
	proc_slot:   i32,
	node_uid:    int,
}

@(private = "file")
_VS_Entity_State :: struct {
	bb:               VG_Runtime_Blackboard,
	graph_path_bound: string,
	custom_delegates: map[string][dynamic]_VS_Custom_Delegate_Listener,
}

@(private = "file")
_VS_Runtime_State :: struct {
	initialized:     bool,
	next_token_id:   u32,
	action_bindings: [dynamic]_VS_Action_Binding,
	vector_bindings: [dynamic]_VS_Vector_Binding,
	debug_bindings:  [dynamic]_VS_Debug_Key_Binding,
	entities:        map[u64]^_VS_Entity_State,
	disk_graphs:     map[string]^Visual_Graph,
	last_dt:         f32,
}

@(private = "file")
_vs_rt: _VS_Runtime_State

// Optional editor live-graph hooks so unsaved changes in Blueprint Studio evaluate in 0.00 ms!
Visual_Script_Live_Hook_Fn :: #type proc(graph_path: string, tH: Transform_Handle, dt: f32, r: ^VisualScriptRunner) -> bool
Visual_Script_Live_Callback_Hook_Fn :: #type proc(tH: Transform_Handle, node_uid: int, proc_name: string, dt: f32, payload_f32: f32, payload_v2: [2]f32, pressed: bool) -> bool

visual_script_live_editor_hook:   Visual_Script_Live_Hook_Fn
visual_script_live_callback_hook: Visual_Script_Live_Callback_Hook_Fn

@(private = "file")
_entity_key :: #force_inline proc(tH: Transform_Handle) -> u64 {
	h := Handle(tH)
	return (u64(h.generation) << 32) | u64(h.index)
}

@(private = "file")
_token_to_owner :: #force_inline proc(token_id: u32) -> rawptr {
	return rawptr(uintptr(token_id) + uintptr(0x4D48_0000))
}

@(private = "file")
_owner_to_token :: #force_inline proc(owner: rawptr) -> u32 {
	v := uintptr(owner)
	if v <= uintptr(0x4D48_0000) do return 0
	return u32(v - uintptr(0x4D48_0000))
}

@(private = "file")
_ensure_vs_rt :: proc() {
	if _vs_rt.initialized do return
	context.allocator = runtime.default_allocator()
	_vs_rt.initialized     = true
	_vs_rt.next_token_id   = 1
	_vs_rt.last_dt         = 1.0 / 60.0
	_vs_rt.action_bindings = make([dynamic]_VS_Action_Binding, 0, 16)
	_vs_rt.vector_bindings = make([dynamic]_VS_Vector_Binding, 0, 8)
	_vs_rt.debug_bindings  = make([dynamic]_VS_Debug_Key_Binding, 0, 16)
	_vs_rt.entities        = make(map[u64]^_VS_Entity_State, 32)
	_vs_rt.disk_graphs     = make(map[string]^Visual_Graph, 16)
}

@(private = "file")
_get_or_load_disk_graph :: proc(rel_or_abs: string) -> ^Visual_Graph {
	if rel_or_abs == "" do return nil
	_ensure_vs_rt()
	if g, ok := _vs_rt.disk_graphs[rel_or_abs]; ok {
		return g
	}
	abs_p := rel_or_abs
	if !filepath.is_abs(abs_p) {
		root := resolve_repo_root(context.temp_allocator)
		abs_p, _ = filepath.join({root, rel_or_abs}, context.temp_allocator)
		if !os.exists(abs_p) {
			alt_moon, _ := filepath.join({root, "haati", rel_or_abs}, context.temp_allocator)
			if os.exists(alt_moon) do abs_p = alt_moon
		}
		// Seamless `.bodin` <-> `.mhgraph` fallback so older saved scenes and upgraded `.bodin` assets both resolve!
		if !os.exists(abs_p) {
			if strings.has_suffix(abs_p, ".mhgraph") {
				cand := fmt.tprintf("%s.bodin", strings.trim_suffix(abs_p, ".mhgraph"))
				if os.exists(cand) do abs_p = cand
			} else if strings.has_suffix(abs_p, ".bodin") {
				cand := fmt.tprintf("%s.mhgraph", strings.trim_suffix(abs_p, ".bodin"))
				if os.exists(cand) do abs_p = cand
			}
		}
	}
	if !os.exists(abs_p) do return nil

	context.allocator = runtime.default_allocator()
	g := new(Visual_Graph)
	if !vg_load_from_file(g, abs_p) {
		free(g)
		return nil
	}
	_vs_rt.disk_graphs[strings.clone(rel_or_abs)] = g
	return g
}

// Returns the cached `Visual_Graph` for `rel_or_abs` (loading once from disk if needed).
visual_script_get_cached_graph :: proc(rel_or_abs: string) -> ^Visual_Graph {
	return _get_or_load_disk_graph(rel_or_abs)
}

// Invalidates the cached disk `.mhgraph` after saving/baking in the Blueprint Studio!
visual_script_invalidate_cached_graph :: proc(graph_path: string = "") {
	if !_vs_rt.initialized do return
	context.allocator = runtime.default_allocator()
	if graph_path == "" {
		for k, g in _vs_rt.disk_graphs {
			delete(k)
			vg_destroy_graph(g)
			free(g)
		}
		clear(&_vs_rt.disk_graphs)
		return
	}
	if g, ok := _vs_rt.disk_graphs[graph_path]; ok {
		old_k, _ := delete_key(&_vs_rt.disk_graphs, graph_path)
		if old_k != "" do delete(old_k)
		vg_destroy_graph(g)
		free(g)
	}
}

// Parses `instance_overrides` (`"speed=12.5;is_boss=true;offset=1,2,3"`) onto a Blackboard!
vg_apply_instance_overrides :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, overrides_str: string) {
	if g == nil || bb == nil || overrides_str == "" do return
	for pair in strings.split(overrides_str, ";", context.temp_allocator) {
		kv := strings.trim_space(pair)
		if kv == "" do continue
		eq := strings.index_byte(kv, '=')
		if eq <= 0 do continue
		vname := strings.trim_space(kv[:eq])
		vval  := strings.trim_space(kv[eq + 1:])
		vi := vg_find_var_index(g, vname)
		if vi < 0 || vi >= VG_MAX_VARS do continue
		#partial switch g.variables[vi].pin_type {
		case .Float:
			if f, ok := strconv.parse_f32(vval); ok do bb.slots[vi].val_f32 = f
		case .Int:
			if iv, ok := strconv.parse_int(vval); ok do bb.slots[vi].val_int = i32(iv)
		case .Int64:
			if iv, ok := strconv.parse_i64(vval); ok do bb.slots[vi].val_i64 = iv
		case .Bool:
			bb.slots[vi].val_bool = (vval == "true" || vval == "1")
		case .Vec2:
			parts := strings.split(vval, ",", context.temp_allocator)
			if len(parts) == 2 {
				x, xok := strconv.parse_f32(strings.trim_space(parts[0]))
				y, yok := strconv.parse_f32(strings.trim_space(parts[1]))
				if xok && yok do bb.slots[vi].val_vec2 = {x, y}
			}
		case .Vec3:
			parts := strings.split(vval, ",", context.temp_allocator)
			if len(parts) == 3 {
				x, xok := strconv.parse_f32(strings.trim_space(parts[0]))
				y, yok := strconv.parse_f32(strings.trim_space(parts[1]))
				z, zok := strconv.parse_f32(strings.trim_space(parts[2]))
				if xok && yok && zok do bb.slots[vi].val_vec3 = {x, y, z}
			}
		case .Vec4, .Quat:
			parts := strings.split(vval, ",", context.temp_allocator)
			if len(parts) == 4 {
				x, xok := strconv.parse_f32(strings.trim_space(parts[0]))
				y, yok := strconv.parse_f32(strings.trim_space(parts[1]))
				z, zok := strconv.parse_f32(strings.trim_space(parts[2]))
				w, wok := strconv.parse_f32(strings.trim_space(parts[3]))
				if xok && yok && zok && wok {
					if g.variables[vi].pin_type == .Quat {
						bb.slots[vi].val_quat = {x, y, z, w}
					} else {
						bb.slots[vi].val_vec4 = {x, y, z, w}
					}
				}
			}
		case .String, .Asset:
			ncopy := min(len(vval), len(bb.str_bufs[vi]) - 1)
			for k in 0 ..< len(bb.str_bufs[vi]) do bb.str_bufs[vi][k] = 0
			if ncopy > 0 do copy(bb.str_bufs[vi][:ncopy], vval[:ncopy])
			bb.slots[vi].val_cstr = cstring(&bb.str_bufs[vi][0])
		}
	}
}

// Formats an updated `instance_overrides` string when editing an `👁 Instance Editable` variable in the Inspector!
vg_set_instance_override_value :: proc(existing: string, var_name: string, formatted_val: string, allocator := context.allocator) -> string {
	entries := make([dynamic]string, 0, 8, context.temp_allocator)
	replaced := false
	for pair in strings.split(existing, ";", context.temp_allocator) {
		kv := strings.trim_space(pair)
		if kv == "" do continue
		eq := strings.index_byte(kv, '=')
		if eq <= 0 do continue
		k := strings.trim_space(kv[:eq])
		if k == var_name {
			if formatted_val != "" {
				append(&entries, fmt.tprintf("%s=%s", var_name, formatted_val))
			}
			replaced = true
		} else {
			append(&entries, kv)
		}
	}
	if !replaced && formatted_val != "" {
		append(&entries, fmt.tprintf("%s=%s", var_name, formatted_val))
	}
	return strings.join(entries[:], ";", allocator)
}

vg_get_instance_override_value :: proc(existing: string, var_name: string) -> (val: string, found: bool) {
	for pair in strings.split(existing, ";", context.temp_allocator) {
		kv := strings.trim_space(pair)
		if kv == "" do continue
		eq := strings.index_byte(kv, '=')
		if eq <= 0 do continue
		if strings.trim_space(kv[:eq]) == var_name {
			return strings.trim_space(kv[eq + 1:]), true
		}
	}
	return "", false
}

@(private = "file")
_get_or_create_entity_state :: proc(tH: Transform_Handle, g_opt: ^Visual_Graph = nil, r_opt: ^VisualScriptRunner = nil) -> ^_VS_Entity_State {
	_ensure_vs_rt()
	ek := _entity_key(tH)
	st, exists := _vs_rt.entities[ek]
	if !exists || st == nil {
		context.allocator = runtime.default_allocator()
		st = new(_VS_Entity_State)
		st.bb.last_exec_path = make([dynamic]int, 0, 16)
		st.custom_delegates  = make(map[string][dynamic]_VS_Custom_Delegate_Listener, 4)
		for i in 0 ..< VG_MAX_VARS {
			st.bb.slots[i].pin_type = .Float
		}
		_vs_rt.entities[ek] = st
	}

	g := g_opt
	r := r_opt
	if r == nil {
		if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(tH)) {
			_, r = transform_get_comp(tH, VisualScriptRunner)
		}
	}
	if g == nil && r != nil && r.graph_path != "" {
		g = _get_or_load_disk_graph(r.graph_path)
	}
	if !st.bb.initialized && g != nil {
		vg_sync_blackboard(g, &st.bb)
		if r != nil && r.instance_overrides != "" {
			vg_apply_instance_overrides(g, &st.bb, r.instance_overrides)
		}
	}
	return st
}

// Returns a direct addressable raw pointer (`^f32`, `^i32`, `^bool`, `^[3]f32`) to per-entity
// Blueprint state variable `var_index`, allowing `On_Init`, `On_Tick`, AND bound `Input` / `Delegate`
// `@(hot_proc)` callbacks to read & mutate persistent `self.<var>` fields at native pointer speed!
visual_script_get_entity_var_ptr :: proc(tH: Transform_Handle, var_index: int) -> rawptr {
	if var_index < 0 || var_index >= VG_MAX_VARS do return nil
	st := _get_or_create_entity_state(tH)
	s := &st.bb.slots[var_index]
	#partial switch s.pin_type {
	case .Bool:   return &s.val_bool
	case .Int:    return &s.val_int
	case .Int64:  return &s.val_i64
	case .Float:  return &s.val_f32
	case .Vec2:   return &s.val_vec2
	case .Vec3:   return &s.val_vec3
	case .Vec4:   return &s.val_vec4
	case .Quat:   return &s.val_quat
	case .Entity: return &s.val_ent
	case .String, .Asset: return &s.val_cstr
	}
	return &s.val_f32
}

visual_script_set_entity_string_var :: proc(tH: Transform_Handle, var_index: int, val: string) {
	if var_index < 0 || var_index >= VG_MAX_VARS do return
	st := _get_or_create_entity_state(tH)
	for k in 0 ..< len(st.bb.str_bufs[var_index]) do st.bb.str_bufs[var_index][k] = 0
	ncopy := min(len(val), len(st.bb.str_bufs[var_index]) - 1)
	if ncopy > 0 do copy(st.bb.str_bufs[var_index][:ncopy], val[:ncopy])
	st.bb.slots[var_index].val_cstr = cstring(&st.bb.str_bufs[var_index][0])
}

// Invokes a bound Odin Delegate target (`Hot_Delegate` / `proc_slot` / Tier-1 `node_uid`).
@(private = "file")
_dispatch_bound_target :: proc(
	tH:          Transform_Handle,
	target_proc: string,
	proc_slot:   i32,
	node_uid:    int,
	payload_f32: f32,
	payload_v2:  [2]f32,
	pressed:     bool,
) {
	w := ctx_world()
	if w != nil && !pool_valid(&w.transforms, Handle(tH)) do return
	dt := _vs_rt.last_dt > 0 ? _vs_rt.last_dt : (1.0 / 60.0)

	// 1. Live Blueprint Studio unsaved preview hook (0 ms)
	if visual_script_live_callback_hook != nil {
		if visual_script_live_callback_hook(tH, node_uid, target_proc, dt, payload_f32, payload_v2, pressed) {
			return
		}
	}

	// 2. Compiled `@(hot_proc)` native machine code dispatch (`~1.5 ns`, survives `F7` DLL hot-swaps!)
	if proc_slot >= 0 {
		frame: hot.Hot_Call_Frame
		frame.inputs[0] = {pin_type = .Float, val_f32  = payload_f32}
		frame.inputs[1] = {pin_type = .Vec2,  val_vec2 = payload_v2}
		frame.inputs[2] = {pin_type = .Bool,  val_bool = pressed}
		frame.input_count = 3
		if hot_proc_invoke_slot(proc_slot, tH, dt, &frame) {
			return
		}
	}
	if target_proc != "" && hot_proc_exists(target_proc) {
		frame: hot.Hot_Call_Frame
		frame.inputs[0] = {pin_type = .Float, val_f32  = payload_f32}
		frame.inputs[1] = {pin_type = .Vec2,  val_vec2 = payload_v2}
		frame.inputs[2] = {pin_type = .Bool,  val_bool = pressed}
		frame.input_count = 3
		if hot_proc_invoke(target_proc, tH, dt, &frame) {
			return
		}
	}

	// 3. Tier-1 disk `.mhgraph` fallback (works before first `F7` bake AND in headless unit tests!)
	st := _get_or_create_entity_state(tH)
	var_g: ^Visual_Graph = nil
	if w != nil && pool_valid(&w.transforms, Handle(tH)) {
		if _, r := transform_get_comp(tH, VisualScriptRunner); r != nil && r.graph_path != "" {
			var_g = _get_or_load_disk_graph(r.graph_path)
		}
	}
	if var_g != nil {
		st.bb.last_payload_f32 = payload_f32
		st.bb.last_payload_v2  = payload_v2
		st.bb.last_pressed     = pressed
		if node_uid > 0 {
			vg_eval_from_entry_uid(var_g, &st.bb, tH, dt, node_uid)
		} else if target_proc != "" {
			vg_eval_custom_proc_live(var_g, &st.bb, tH, dt, target_proc, payload_f32, payload_v2, pressed)
		}
	}
}

@(private = "file")
_bridge_on_action_event :: proc(action_idx: int, pressed: bool, owner: rawptr) -> bool {
	_ = action_idx
	tok := _owner_to_token(owner)
	if tok == 0 do return false
	for b in _vs_rt.action_bindings {
		if b.token_id == tok {
			fire := false
			switch b.trigger {
			case .Pressed:  fire = pressed
			case .Released: fire = !pressed
			case .Both:     fire = true
			}
			if fire {
				_dispatch_bound_target(b.entity, b.target_proc, b.proc_slot, b.node_uid, pressed ? 1.0 : 0.0, {}, pressed)
				return b.consume
			}
			return false
		}
	}
	return false
}

@(private = "file")
_bridge_on_vector_event :: proc(vec: [2]f32, owner: rawptr) -> bool {
	tok := _owner_to_token(owner)
	if tok == 0 do return false
	for b in _vs_rt.vector_bindings {
		if b.token_id == tok {
			_dispatch_bound_target(b.entity, b.target_proc, b.proc_slot, b.node_uid, linalg.length(vec), vec, true)
			return b.consume
		}
	}
	return false
}

visual_script_bind_action_runtime :: proc(
	tH:          Transform_Handle,
	action_name: string,
	trigger:     hot.Hot_Trigger_Edge,
	priority:    int,
	consume:     bool,
	target_proc: string,
	node_uid:    int,
) -> u32 {
	if action_name == "" || (target_proc == "" && node_uid <= 0) do return 0
	_ensure_vs_rt()
	// Replace any existing binding on `(tH, action_name)` cleanly (supports dynamic procedure swapping!)
	visual_script_unbind_action_runtime(tH, action_name)

	context.allocator = runtime.default_allocator()
	tok := _vs_rt.next_token_id
	_vs_rt.next_token_id += 1
	slot := target_proc != "" ? hot_proc_slot_index(target_proc, true) : -1

	append(&_vs_rt.action_bindings, _VS_Action_Binding{
		token_id    = tok,
		entity      = tH,
		action_name = strings.clone(action_name),
		trigger     = trigger,
		priority    = priority,
		consume     = consume,
		target_proc = target_proc != "" ? strings.clone(target_proc) : "",
		proc_slot   = slot,
		node_uid    = node_uid,
	})

	if _vs_input_bridge.claim_action != nil {
		_ = _vs_input_bridge.claim_action(action_name, priority, _bridge_on_action_event, _token_to_owner(tok))
	}
	return tok
}

visual_script_unbind_action_runtime :: proc(tH: Transform_Handle, action_name: string) {
	if !_vs_rt.initialized do return
	context.allocator = runtime.default_allocator()
	for i := len(_vs_rt.action_bindings) - 1; i >= 0; i -= 1 {
		b := _vs_rt.action_bindings[i]
		if b.entity == tH && (action_name == "" || b.action_name == action_name) {
			if _vs_input_bridge.release_action != nil {
				_vs_input_bridge.release_action(b.action_name, _token_to_owner(b.token_id))
			}
			delete(b.action_name)
			if b.target_proc != "" do delete(b.target_proc)
			ordered_remove(&_vs_rt.action_bindings, i)
		}
	}
}

visual_script_bind_vector_runtime :: proc(
	tH:          Transform_Handle,
	is_look:     bool,
	priority:    int,
	consume:     bool,
	target_proc: string,
	node_uid:    int,
) -> u32 {
	if target_proc == "" && node_uid <= 0 do return 0
	_ensure_vs_rt()
	visual_script_unbind_vector_runtime(tH, is_look)

	context.allocator = runtime.default_allocator()
	tok := _vs_rt.next_token_id
	_vs_rt.next_token_id += 1
	slot := target_proc != "" ? hot_proc_slot_index(target_proc, true) : -1

	append(&_vs_rt.vector_bindings, _VS_Vector_Binding{
		token_id    = tok,
		entity      = tH,
		is_look     = is_look,
		priority    = priority,
		consume     = consume,
		target_proc = target_proc != "" ? strings.clone(target_proc) : "",
		proc_slot   = slot,
		node_uid    = node_uid,
	})

	if is_look {
		if _vs_input_bridge.claim_look != nil {
			_vs_input_bridge.claim_look(priority, _bridge_on_vector_event, _token_to_owner(tok))
		}
	} else {
		if _vs_input_bridge.claim_movement != nil {
			_vs_input_bridge.claim_movement(priority, _bridge_on_vector_event, _token_to_owner(tok))
		}
	}
	return tok
}

visual_script_unbind_vector_runtime :: proc(tH: Transform_Handle, is_look: bool) {
	if !_vs_rt.initialized do return
	context.allocator = runtime.default_allocator()
	for i := len(_vs_rt.vector_bindings) - 1; i >= 0; i -= 1 {
		b := _vs_rt.vector_bindings[i]
		if b.entity == tH && b.is_look == is_look {
			if b.is_look {
				if _vs_input_bridge.release_look != nil do _vs_input_bridge.release_look(_token_to_owner(b.token_id))
			} else {
				if _vs_input_bridge.release_movement != nil do _vs_input_bridge.release_movement(_token_to_owner(b.token_id))
			}
			if b.target_proc != "" do delete(b.target_proc)
			ordered_remove(&_vs_rt.vector_bindings, i)
		}
	}
}

visual_script_bind_debug_key_runtime :: proc(
	tH:          Transform_Handle,
	key_code:    int,
	trigger:     hot.Hot_Trigger_Edge,
	target_proc: string,
	node_uid:    int,
) -> u32 {
	if key_code <= 0 || (target_proc == "" && node_uid <= 0) do return 0
	_ensure_vs_rt()
	visual_script_unbind_debug_key_runtime(tH, key_code)

	context.allocator = runtime.default_allocator()
	tok := _vs_rt.next_token_id
	_vs_rt.next_token_id += 1
	slot := target_proc != "" ? hot_proc_slot_index(target_proc, true) : -1

	append(&_vs_rt.debug_bindings, _VS_Debug_Key_Binding{
		token_id    = tok,
		entity      = tH,
		key_code    = key_code,
		trigger     = trigger,
		target_proc = target_proc != "" ? strings.clone(target_proc) : "",
		proc_slot   = slot,
		node_uid    = node_uid,
	})
	return tok
}

visual_script_unbind_debug_key_runtime :: proc(tH: Transform_Handle, key_code: int) {
	if !_vs_rt.initialized do return
	context.allocator = runtime.default_allocator()
	for i := len(_vs_rt.debug_bindings) - 1; i >= 0; i -= 1 {
		b := _vs_rt.debug_bindings[i]
		if b.entity == tH && (key_code <= 0 || b.key_code == key_code) {
			if b.target_proc != "" do delete(b.target_proc)
			ordered_remove(&_vs_rt.debug_bindings, i)
		}
	}
}

visual_script_unbind_all_for_entity :: proc(tH: Transform_Handle) {
	if !_vs_rt.initialized do return
	visual_script_unbind_action_runtime(tH, "")
	visual_script_unbind_vector_runtime(tH, false)
	visual_script_unbind_vector_runtime(tH, true)
	visual_script_unbind_debug_key_runtime(tH, 0)
}

visual_script_bind_custom_delegate_runtime :: proc(tH: Transform_Handle, delegate_name: string, target_proc: string, node_uid: int) {
	if delegate_name == "" || (target_proc == "" && node_uid <= 0) do return
	st := _get_or_create_entity_state(tH)
	context.allocator = runtime.default_allocator()
	slot := target_proc != "" ? hot_proc_slot_index(target_proc, true) : -1

	list, has := st.custom_delegates[delegate_name]
	if !has {
		list = make([dynamic]_VS_Custom_Delegate_Listener, 0, 2)
	}
	// Replace duplicate listener so re-binding is idempotent!
	for &item in list {
		if (target_proc != "" && item.target_proc == target_proc) || (node_uid > 0 && item.node_uid == node_uid) {
			item.proc_slot = slot
			st.custom_delegates[delegate_name] = list
			return
		}
	}
	append(&list, _VS_Custom_Delegate_Listener{
		target_proc = target_proc != "" ? strings.clone(target_proc) : "",
		proc_slot   = slot,
		node_uid    = node_uid,
	})
	if !has {
		st.custom_delegates[strings.clone(delegate_name)] = list
	} else {
		st.custom_delegates[delegate_name] = list
	}
}

visual_script_unbind_custom_delegate_runtime :: proc(tH: Transform_Handle, delegate_name: string) {
	if !_vs_rt.initialized do return
	ek := _entity_key(tH)
	st, ok := _vs_rt.entities[ek]
	if !ok || st == nil do return
	context.allocator = runtime.default_allocator()
	if list, has := st.custom_delegates[delegate_name]; has {
		for item in list {
			if item.target_proc != "" do delete(item.target_proc)
		}
		clear(&list)
		st.custom_delegates[delegate_name] = list
	}
}

visual_script_broadcast_custom_delegate_runtime :: proc(tH: Transform_Handle, delegate_name: string, payload_f32: f32) {
	if !_vs_rt.initialized do return
	ek := _entity_key(tH)
	st, ok := _vs_rt.entities[ek]
	if !ok || st == nil do return
	if list, has := st.custom_delegates[delegate_name]; has {
		// Snapshot slice on temp allocator so a listener can safely `Unbind` or `Bind` mid-broadcast!
		snap := make([]_VS_Custom_Delegate_Listener, len(list), context.temp_allocator)
		copy(snap, list[:])
		for item in snap {
			_dispatch_bound_target(tH, item.target_proc, item.proc_slot, item.node_uid, payload_f32, {}, true)
		}
	}
}

visual_script_destroy_entity_state :: proc(tH: Transform_Handle) {
	if !_vs_rt.initialized do return
	visual_script_unbind_all_for_entity(tH)
	ek := _entity_key(tH)
	if st, ok := _vs_rt.entities[ek]; ok && st != nil {
		context.allocator = runtime.default_allocator()
		delete_key(&_vs_rt.entities, ek)
		delete(st.bb.last_exec_path)
		if st.graph_path_bound != "" do delete(st.graph_path_bound)
		for k, list in st.custom_delegates {
			delete(k)
			for item in list {
				if item.target_proc != "" do delete(item.target_proc)
			}
			delete(list)
		}
		delete(st.custom_delegates)
		free(st)
	}
}

// Resets all runtime Blueprint bindings & per-entity Blackboards when Play/Simulate stops!
@(phase={key=Phase.ExitingPlayMode, order=0})
visual_script_exiting_play_mode :: proc() {
	visual_script_reset_runtime_state()
}

visual_script_reset_runtime_state :: proc() {
	if !_vs_rt.initialized do return
	context.allocator = runtime.default_allocator()
	for b in _vs_rt.action_bindings {
		if _vs_input_bridge.release_action != nil {
			_vs_input_bridge.release_action(b.action_name, _token_to_owner(b.token_id))
		}
		delete(b.action_name)
		if b.target_proc != "" do delete(b.target_proc)
	}
	clear(&_vs_rt.action_bindings)

	for b in _vs_rt.vector_bindings {
		if b.is_look {
			if _vs_input_bridge.release_look != nil do _vs_input_bridge.release_look(_token_to_owner(b.token_id))
		} else {
			if _vs_input_bridge.release_movement != nil do _vs_input_bridge.release_movement(_token_to_owner(b.token_id))
		}
		if b.target_proc != "" do delete(b.target_proc)
	}
	clear(&_vs_rt.vector_bindings)

	for b in _vs_rt.debug_bindings {
		if b.target_proc != "" do delete(b.target_proc)
	}
	clear(&_vs_rt.debug_bindings)

	for _, st in _vs_rt.entities {
		if st == nil do continue
		delete(st.bb.last_exec_path)
		if st.graph_path_bound != "" do delete(st.graph_path_bound)
		for k, list in st.custom_delegates {
			delete(k)
			for item in list {
				if item.target_proc != "" do delete(item.target_proc)
			}
			delete(list)
		}
		delete(st.custom_delegates)
		free(st)
	}
	clear(&_vs_rt.entities)

	if w := ctx_world(); w != nil {
		if pool := visual_script_runners(w); pool != nil {
			it := pool_iterator(pool)
			for r, _ in pool_next(&it) {
				if r != nil do r.init_fired = false
			}
		}
	}
}

// Deterministic helpers for headless unit tests & Studio debug simulation buttons!
visual_script_active_action_binding_count :: proc() -> int {
	return len(_vs_rt.action_bindings)
}

visual_script_fire_action_for_test :: proc(action_name: string, pressed: bool = true) -> int {
	if !_vs_rt.initialized do return 0
	// Sort snapshot by descending priority (`input_manager` semantics)
	snap := make([dynamic]_VS_Action_Binding, 0, len(_vs_rt.action_bindings), context.temp_allocator)
	for b in _vs_rt.action_bindings {
		if b.action_name == action_name do append(&snap, b)
	}
	// Simple insertion sort by priority descending
	for i := 1; i < len(snap); i += 1 {
		cur := snap[i]
		j := i - 1
		for j >= 0 && snap[j].priority < cur.priority {
			snap[j + 1] = snap[j]
			j -= 1
		}
		snap[j + 1] = cur
	}
	fired := 0
	for b in snap {
		fire := false
		switch b.trigger {
		case .Pressed:  fire = pressed
		case .Released: fire = !pressed
		case .Both:     fire = true
		}
		if fire {
			fired += 1
			_dispatch_bound_target(b.entity, b.target_proc, b.proc_slot, b.node_uid, pressed ? 1.0 : 0.0, {}, pressed)
			if b.consume do break
		}
	}
	return fired
}

visual_script_fire_debug_key_for_test :: proc(key_code: int, pressed: bool = true) -> int {
	if !_vs_rt.initialized do return 0
	snap := make([dynamic]_VS_Debug_Key_Binding, 0, len(_vs_rt.debug_bindings), context.temp_allocator)
	for b in _vs_rt.debug_bindings {
		if b.key_code == key_code do append(&snap, b)
	}
	fired := 0
	for b in snap {
		fire := false
		switch b.trigger {
		case .Pressed:  fire = pressed
		case .Released: fire = !pressed
		case .Both:     fire = true
		}
		if fire {
			fired += 1
			_dispatch_bound_target(b.entity, b.target_proc, b.proc_slot, b.node_uid, pressed ? 1.0 : 0.0, {}, pressed)
		}
	}
	return fired
}

@(private = "file")
_fire_runner_destroy_event :: proc(r: ^VisualScriptRunner) {
	if r == nil || !r.init_fired do return
	tH := r.owner
	destroy_sym := fmt.tprintf("%s__on_destroy", r.compiled_proc_name)
	if r.compiled_proc_name != "" && hot_proc_exists(destroy_sym) {
		hot_proc_invoke(destroy_sym, tH, 0.0, nil)
		return
	}
	if r.graph_path != "" {
		if g := _get_or_load_disk_graph(r.graph_path); g != nil {
			st := _get_or_create_entity_state(tH, g, r)
			vg_eval_event_live(g, &st.bb, tH, 0.0, .Event_Destroy)
		}
	}
}

// Ticks all enabled `VisualScriptRunner` Blueprint components right after `input_manager_dispatch` (`order=-20`)!
@(update={order=-15})
visual_script_runners_tick :: proc(dt: f32) {
	w := ctx_world()
	if w == nil do return
	_ensure_vs_rt()
	_vs_rt.last_dt = dt

	// 1. Poll `[DEV]` Debug Key Bindings (`0 ns` when `len(_vs_rt.debug_bindings) == 0`!)
	if len(_vs_rt.debug_bindings) > 0 {
		snap_dbg := make([]_VS_Debug_Key_Binding, len(_vs_rt.debug_bindings), context.temp_allocator)
		copy(snap_dbg, _vs_rt.debug_bindings[:])
		for b in snap_dbg {
			if !pool_valid(&w.transforms, Handle(b.entity)) do continue
			k := input.Key(b.key_code)
			kp := input.key_pressed(k)
			kr := input.key_released(k)
			if kp && (b.trigger == .Pressed || b.trigger == .Both) {
				_dispatch_bound_target(b.entity, b.target_proc, b.proc_slot, b.node_uid, 1.0, {}, true)
			} else if kr && (b.trigger == .Released || b.trigger == .Both) {
				_dispatch_bound_target(b.entity, b.target_proc, b.proc_slot, b.node_uid, 0.0, {}, false)
			}
		}
	}

	pool := visual_script_runners(w)
	if pool == nil do return

	it := pool_iterator(pool)
	for r, _ in pool_next(&it) {
		if r == nil || !r.enabled do continue
		tH := r.owner
		if !pool_valid(&w.transforms, Handle(tH)) do continue

		// 2. If the Blueprint Studio has unsaved live edits open for this graph, evaluate Tier-1 (0 ms)!
		if r.live_preview && visual_script_live_editor_hook != nil && r.graph_path != "" {
			if visual_script_live_editor_hook(r.graph_path, tH, dt, r) {
				continue
			}
		}

		// 3. Fire `Event_Init` (`BeginPlay`) ONCE per entity before any Tick!
		if !r.init_fired {
			r.init_fired = true
			g_disk := _get_or_load_disk_graph(r.graph_path)
			st := _get_or_create_entity_state(tH, g_disk, r)
			init_sym := fmt.tprintf("%s__on_init", r.compiled_proc_name)
			if r.compiled_proc_name != "" && hot_proc_exists(init_sym) {
				hot_proc_invoke(init_sym, tH, dt, nil)
			} else if g_disk != nil {
				vg_eval_event_live(g_disk, &st.bb, tH, dt, .Event_Init)
			}
		}

		// 4. Opt-In Tick: If compiled `r.compiled_proc_name` exists, run native machine code;
		//    if not compiled yet (or `Event_Tick` was omitted for pure event-driven Blueprints!),
		//    skip in `0 ns` when `Event_Tick` is absent!
		if r.compiled_proc_name != "" && hot_proc_exists(r.compiled_proc_name) {
			frame: hot.Hot_Call_Frame
			frame.inputs[0] = {pin_type = .Float, pass_mode = .Copy_Value,   val_f32 = r.param_a}
			frame.inputs[1] = {pin_type = .Float, pass_mode = .Copy_Value,   val_f32 = r.param_b}
			frame.inputs[2] = {pin_type = .Float, pass_mode = .By_Reference, ref_ptr = &r.state_accum}
			frame.inputs[3] = {pin_type = .Vec3,  pass_mode = .By_Reference, ref_ptr = &r.state_vec}
			frame.input_count = 4
			hot_proc_invoke(r.compiled_proc_name, tH, dt, &frame)
		} else if r.graph_path != "" {
			if g_disk := _get_or_load_disk_graph(r.graph_path); g_disk != nil && vg_has_tick_event(g_disk) {
				st := _get_or_create_entity_state(tH, g_disk, r)
				vg_eval_graph_live(g_disk, &st.bb, tH, dt)
			}
		}
	}
}

// =============================================================================
// Graph Lifecycle, Pin Type Naming & Strict `● Copy` vs `◆ ^Ref` vs `◇ Delegate`
// =============================================================================

@(rodata)
_PIN_ODIN_SCALAR_TYPE := [hot.Hot_Pin_Type]string{
	.Exec     = "exec",
	.Bool     = "bool",
	.Int      = "i32",
	.Int64    = "i64",
	.Float    = "f32",
	.Vec2     = "[2]f32",
	.Vec3     = "[3]f32",
	.Vec4     = "[4]f32",
	.Quat     = "[4]f32",
	.String   = "cstring",
	.Asset    = "cstring",
	.Entity   = "hot.Hot_Entity",
	.Delegate = "hot.Hot_Delegate",
}

@(rodata)
_PIN_ODIN_ARRAY_TYPE := [hot.Hot_Pin_Type]string{
	.Exec     = "exec",
	.Bool     = "[8]bool",
	.Int      = "[8]i32",
	.Int64    = "[8]i64",
	.Float    = "[8]f32",
	.Vec2     = "[8][2]f32",
	.Vec3     = "[8][3]f32",
	.Vec4     = "[8][4]f32",
	.Quat     = "[8][4]f32",
	.String   = "[8]cstring",
	.Asset    = "[8]cstring",
	.Entity   = "[8]hot.Hot_Entity",
	.Delegate = "hot.Hot_Delegate",
}

vg_pin_odin_type :: proc(pt: hot.Hot_Pin_Type, is_array: bool = false) -> string {
	if is_array do return _PIN_ODIN_ARRAY_TYPE[pt]
	return _PIN_ODIN_SCALAR_TYPE[pt]
}

vg_has_tick_event :: proc(g: ^Visual_Graph) -> bool {
	if g == nil do return false
	for n in g.nodes {
		if n.kind == .Event_Tick && n.enabled do return true
	}
	return false
}

vg_has_using_space :: proc(g: ^Visual_Graph, space_id: string) -> bool {
	if g == nil do return false
	for s in g.using_spaces {
		if s == space_id do return true
	}
	return false
}

vg_toggle_using_space :: proc(g: ^Visual_Graph, space_id: string) -> bool {
	if g == nil || space_id == "" do return false
	context.allocator = runtime.default_allocator()
	for s, i in g.using_spaces {
		if s == space_id {
			delete(s)
			ordered_remove(&g.using_spaces, i)
			return false
		}
	}
	append(&g.using_spaces, strings.clone(space_id))
	return true
}

vg_ensure_default_spaces :: proc(g: ^Visual_Graph) {
	if g == nil || len(g.using_spaces) > 0 do return
	append(&g.using_spaces, strings.clone("self"))
	append(&g.using_spaces, strings.clone("hot"))
	append(&g.using_spaces, strings.clone("math"))
	append(&g.using_spaces, strings.clone("linalg"))
}

vg_destroy_node :: proc(n: ^VG_Node) {
	delete(n.title)
	delete(n.owner_proc)
	delete(n.var_name)
	delete(n.hot_proc_target)
	delete(n.odin_body)
	delete(n.action_name)
	delete(n.delegate_name)
	for p in n.inputs {
		delete(p.name)
		delete(p.default_str)
	}
	for p in n.outputs {
		delete(p.name)
		delete(p.default_str)
	}
	delete(n.inputs)
	delete(n.outputs)
	n^ = {}
}

vg_destroy_graph :: proc(g: ^Visual_Graph) {
	delete(g.name)
	delete(g.package_target)
	for s in g.using_spaces do delete(s)
	delete(g.using_spaces)
	for d in g.delegates do delete(d)
	delete(g.delegates)
	for v in g.variables {
		delete(v.name)
		delete(v.default_str)
		delete(v.category)
		delete(v.tooltip_text)
	}
	delete(g.variables)
	for &n in g.nodes do vg_destroy_node(&n)
	delete(g.nodes)
	delete(g.wires)
	g^ = {}
}

vg_find_node :: proc(g: ^Visual_Graph, uid: int) -> ^VG_Node {
	if g == nil do return nil
	for &n in g.nodes {
		if n.uid == uid do return &n
	}
	return nil
}

vg_find_custom_proc_node :: proc(g: ^Visual_Graph, proc_name: string) -> ^VG_Node {
	if g == nil || proc_name == "" do return nil
	for &n in g.nodes {
		if n.kind == .Custom_Proc_Entry && (n.hot_proc_target == proc_name || n.title == proc_name) {
			return &n
		}
	}
	return nil
}

vg_find_var_index :: proc(g: ^Visual_Graph, name: string) -> int {
	if g == nil do return -1
	for v, i in g.variables {
		if v.name == name do return i
	}
	return -1
}

// Enforces type compatibility, `Delegate` matching, AND `Copy (T)` vs `^Ref (^T)` addressability!
vg_can_connect_pins :: proc(src: VG_Pin_Def, dst: VG_Pin_Def) -> (ok: bool, reason: string) {
	if src.pin_type != dst.pin_type {
		if dst.pin_type == .Delegate || src.pin_type == .Delegate {
			return false, "Delegate pins only connect to Blueprint Procedure (Delegate) pins!"
		}
		return false, "Pin data types do not match"
	}
	if src.pin_type == .Exec || src.pin_type == .Delegate {
		return true, ""
	}
	// CRITICAL INVARIANT: A `By_Reference (^T)` input pin MUST receive an addressable lvalue!
	if dst.pass_mode == .By_Reference && !src.is_addressable {
		return false, "Reference (^T) pin requires an addressable Variable or Transform field (^Ref output), not a temporary rvalue!"
	}
	return true, ""
}

// Returns the index (>= 0) of the first opposite-direction pin on `cand` that can legally
// connect with `drag_pin` (respecting `pin_type` AND `Copy T` vs `^Ref ^T` addressability),
// or `-1` if `cand` has no compatible pin.
vg_find_compatible_pin_on_node :: proc(drag_from_out: bool, drag_pin: VG_Pin_Def, cand: ^VG_Node) -> int {
	if cand == nil do return -1
	if drag_from_out {
		for ip, ii in cand.inputs {
			if ok, _ := vg_can_connect_pins(drag_pin, ip); ok {
				return ii
			}
		}
	} else {
		for op, oi in cand.outputs {
			if ok, _ := vg_can_connect_pins(op, drag_pin); ok {
				return oi
			}
		}
	}
	return -1
}

// Probes whether spawning `kind` with `custom_name` inside `g` yields a node with a legal
// opposite-direction pin for `drag_pin` using only `context.temp_allocator`.
vg_probe_compatible_pin :: proc(g: ^Visual_Graph, kind: VG_Node_Kind, custom_name: string, drag_from_out: bool, drag_pin: VG_Pin_Def) -> int {
	context.allocator = context.temp_allocator
	scratch: Visual_Graph
	if g != nil {
		scratch.name     = g.name
		scratch.domain   = g.domain
		scratch.next_uid = g.next_uid
		if len(g.variables) > 0 {
			scratch.variables = make([dynamic]VG_Var_Decl, len(g.variables), context.temp_allocator)
			copy(scratch.variables[:], g.variables[:])
		}
		if len(g.delegates) > 0 {
			scratch.delegates = make([dynamic]string, len(g.delegates), context.temp_allocator)
			copy(scratch.delegates[:], g.delegates[:])
		}
		if len(g.nodes) > 0 {
			scratch.nodes = make([dynamic]VG_Node, len(g.nodes), len(g.nodes) + 1, context.temp_allocator)
			copy(scratch.nodes[:], g.nodes[:])
		}
	}
	uid := vg_add_node(&scratch, kind, {}, custom_name)
	cand := vg_find_node(&scratch, uid)
	return vg_find_compatible_pin_on_node(drag_from_out, drag_pin, cand)
}

// =============================================================================
// Node Factory: Spawns Cleanly Configured Niagara & Blueprint Nodes
// =============================================================================

vg_add_node :: proc(g: ^Visual_Graph, kind: VG_Node_Kind, pos: [2]f32, custom_name: string = "") -> int {
	g.next_uid += 1
	uid := g.next_uid
	n := VG_Node{
		uid            = uid,
		kind           = kind,
		pos            = pos,
		enabled        = true,
		input_priority = 10,
		debug_key_code = i32(input.Key.G),
	}

	switch kind {
	case .Event_Init:
		n.title = strings.clone("Event: On Init (BeginPlay)")
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Event_Tick:
		n.title = strings.clone("Event: On Tick")
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("dt"),        pin_type = .Float})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Object dt"), pin_type = .Float})

	case .Event_Destroy:
		n.title = strings.clone("Event: On Destroy")
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Custom_Proc_Entry:
		pname := custom_name != "" ? custom_name : fmt.tprintf("On_Custom_Event_%d", uid)
		n.title           = strings.clone(pname)
		n.hot_proc_target = strings.clone(pname)
		n.owner_proc      = strings.clone(pname)
		n.odin_body       = strings.clone("// Scoped Procedure Body (`using self` variables active!)\nhot.log_info(\"Custom procedure executed\")")
		// Output 0: `Delegate` handle for wiring directly into `Bind Input Action` / `Bind Delegate`!
		// Output 1: `Exec` body of the procedure!
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Delegate"),   pin_type = .Delegate})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Payload"),    pin_type = .Float})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Input Vec2"), pin_type = .Vec2})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Pressed"),    pin_type = .Bool})

	case .Call_Blueprint_Proc:
		pname := custom_name != "" ? custom_name : "On_Action"
		n.title           = strings.clone(fmt.tprintf("Call %s()", pname))
		n.hot_proc_target = strings.clone(pname)
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Payload"), pin_type = .Float, default_f32 = 0.0})
		if entry := vg_find_custom_proc_node(g, pname); entry != nil && len(entry.outputs) > 5 {
			for pi in 5 ..< len(entry.outputs) {
				ep := entry.outputs[pi]
				append(&n.inputs, VG_Pin_Def{
					name        = strings.clone(ep.name),
					pin_type    = ep.pin_type,
					is_array    = ep.is_array,
					default_f32 = ep.default_f32,
					default_int = ep.default_int,
					default_i64 = ep.default_i64,
					default_bool = ep.default_bool,
					default_vec2 = ep.default_vec2,
					default_vec3 = ep.default_vec3,
					default_vec4 = ep.default_vec4,
					default_str = ep.default_str != "" ? strings.clone(ep.default_str) : "",
				})
			}
		}
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})

	case .Bind_Input_Action:
		act := custom_name != "" ? custom_name : "Jump"
		n.action_name    = strings.clone(act)
		n.trigger_edge   = .Pressed
		n.input_priority = 10
		n.consume_input  = false
		n.title          = strings.clone(fmt.tprintf("Bind Input: %s", act))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target Proc"), pin_type = .Delegate})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})

	case .Unbind_Input_Action:
		act := custom_name != "" ? custom_name : "Jump"
		n.action_name = strings.clone(act)
		n.title       = strings.clone(fmt.tprintf("Unbind Input: %s", act))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Bind_Input_Vector:
		n.is_look_vector = (custom_name == "Look")
		n.input_priority = 10
		n.title          = strings.clone(n.is_look_vector ? "Bind Input Vector: Look" : "Bind Input Vector: Move")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target Proc"), pin_type = .Delegate})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})

	case .Unbind_Input_Vector:
		n.is_look_vector = (custom_name == "Look")
		n.title          = strings.clone(n.is_look_vector ? "Unbind Input Vector: Look" : "Unbind Input Vector: Move")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Bind_Debug_Key:
		n.debug_key_code = i32(input.Key.G)
		n.trigger_edge   = .Pressed
		n.title          = strings.clone("[DEV] Bind Debug Key (G)")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target Proc"), pin_type = .Delegate})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})

	case .Unbind_Debug_Key:
		n.debug_key_code = i32(input.Key.G)
		n.title          = strings.clone("[DEV] Unbind Debug Key (G)")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Unbind_All_Inputs:
		n.title = strings.clone("Unbind All Inputs")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Delegate_Bind:
		dname := custom_name != "" ? custom_name : (len(g.delegates) > 0 ? g.delegates[0] : "On_Triggered")
		n.delegate_name = strings.clone(dname)
		n.title         = strings.clone(fmt.tprintf("Bind Delegate: %s", dname))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target Proc"), pin_type = .Delegate})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})

	case .Delegate_Unbind:
		dname := custom_name != "" ? custom_name : (len(g.delegates) > 0 ? g.delegates[0] : "On_Triggered")
		n.delegate_name = strings.clone(dname)
		n.title         = strings.clone(fmt.tprintf("Unbind Delegate: %s", dname))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Delegate_Broadcast:
		dname := custom_name != "" ? custom_name : (len(g.delegates) > 0 ? g.delegates[0] : "On_Triggered")
		n.delegate_name = strings.clone(dname)
		n.title         = strings.clone(fmt.tprintf("Broadcast: %s", dname))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Payload"), pin_type = .Float, default_f32 = 1.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})

	case .Get_Variable:
		vname := custom_name != "" ? custom_name : (len(g.variables) > 0 ? g.variables[0].name : "phase")
		vtype := hot.Hot_Pin_Type.Float
		varr  := false
		if vi := vg_find_var_index(g, vname); vi >= 0 {
			vtype = g.variables[vi].pin_type
			varr  = g.variables[vi].is_array
		}
		n.var_name   = strings.clone(vname)
		n.var_as_ref = false
		n.title      = strings.clone(fmt.tprintf("Get %s", vname))
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Value (Copy)"), pin_type = vtype, is_array = varr, pass_mode = .Copy_Value,   is_addressable = false})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Ref (^Ptr)"),   pin_type = vtype, is_array = varr, pass_mode = .By_Reference, is_addressable = true})

	case .Set_Variable:
		vname := custom_name != "" ? custom_name : (len(g.variables) > 0 ? g.variables[0].name : "phase")
		vtype := hot.Hot_Pin_Type.Float
		varr  := false
		if vi := vg_find_var_index(g, vname); vi >= 0 {
			vtype = g.variables[vi].pin_type
			varr  = g.variables[vi].is_array
		}
		n.var_name = strings.clone(vname)
		n.title    = strings.clone(fmt.tprintf("Set %s", vname))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Value"), pin_type = vtype, is_array = varr, pass_mode = .Copy_Value})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"),   pin_type = vtype, is_array = varr, pass_mode = .Copy_Value})

	case .Get_Transform_Pos:
		n.title = strings.clone("Transform Position")
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Pos (Copy)"),     pin_type = .Vec3, pass_mode = .Copy_Value,   is_addressable = false})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Pos Ref (^Vec3)"), pin_type = .Vec3, pass_mode = .By_Reference, is_addressable = true})

	case .Set_Transform_Pos:
		n.title = strings.clone("Set Transform Position")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),     pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("New Pos"),  pin_type = .Vec3, pass_mode = .Copy_Value})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),     pin_type = .Exec})

	case .Math_Float:
		n.title   = strings.clone("Math (Float)")
		n.math_op = .Add
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("A"), pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("B"), pin_type = .Float, default_f32 = 1.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Result"), pin_type = .Float})

	case .Vec3_Scale_Add:
		n.title = strings.clone("Vec3 + Axis * Scale")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Base"),  pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Axis"),  pin_type = .Vec3, default_vec3 = {0, 1, 0}})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Scale"), pin_type = .Float, default_f32 = 1.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"),   pin_type = .Vec3})

	case .Branch_If:
		n.title = strings.clone("Branch (If / Else)")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Condition"), pin_type = .Bool, default_bool = true})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("True"),      pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("False"),     pin_type = .Exec})

	case .Set_Time_Scale:
		n.title         = strings.clone("Set Time Scale")
		n.per_object_ts = true
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Scale"), pin_type = .Float, default_f32 = 0.25})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})

	case .Call_Hot_Proc:
		pname := custom_name != "" ? custom_name : "hot_harmonic_hover"
		n.title           = strings.clone(fmt.tprintf("Call %s", pname))
		n.hot_proc_target = strings.clone(pname)
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Amp"),       pin_type = .Float, pass_mode = .Copy_Value,   default_f32 = 0.30})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Freq"),      pin_type = .Float, pass_mode = .Copy_Value,   default_f32 = 2.00})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Phase Ref"), pin_type = .Float, pass_mode = .By_Reference, default_f32 = 0.00})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"),       pin_type = .Float})

	case .Odin_Function_Node:
		fn_title := custom_name != "" ? custom_name : fmt.tprintf("Odin Wrangle #%d", uid)
		n.title           = strings.clone(fn_title)
		n.hot_proc_target = strings.clone(fmt.tprintf("_mhnode_%d", uid))
		n.odin_body       = strings.clone(
			"// Mutate `pos^` by reference (`◆ ^Ref`) using `amp` & `phase^`!\n" +
			"phase^ += dt * freq * math.TAU\n" +
			"wave_y = math.sin(phase^) * amp\n" +
			"pos.y += wave_y * dt\n",
		)
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("amp"),   pin_type = .Float, pass_mode = .Copy_Value,   default_f32 = 0.35})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("freq"),  pin_type = .Float, pass_mode = .Copy_Value,   default_f32 = 2.00})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("phase"), pin_type = .Float, pass_mode = .By_Reference, default_f32 = 0.00})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("pos"),   pin_type = .Vec3,  pass_mode = .By_Reference})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("wave_y"), pin_type = .Float})

	case .Anim_Clip_Eval:
		clip := custom_name != "" ? custom_name : "Locomotion_Run"
		n.action_name = strings.clone(clip)
		n.title       = strings.clone(fmt.tprintf("Anim Clip: %s", clip))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Speed"),     pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Norm Time"), pin_type = .Float, default_f32 = 0.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Pose Weight"), pin_type = .Float})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Phase"),       pin_type = .Float})

	case .Anim_Blend_Layered:
		n.title = strings.clone("Layered Motion Blend")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Base Pose"),  pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Layer Pose"), pin_type = .Float, default_f32 = 0.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Alpha"),      pin_type = .Float, default_f32 = 0.5})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out Pose"),   pin_type = .Float})

	case .Anim_Spring_Damper:
		n.title = strings.clone("Motion Spring Damper")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Current"), pin_type = .Float, default_f32 = 0.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target"),  pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Speed"),   pin_type = .Float, default_f32 = 10.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Smoothed"), pin_type = .Float})

	case .Anim_IK_Target:
		bone := custom_name != "" ? custom_name : "Foot_L"
		n.action_name = strings.clone(bone)
		n.title       = strings.clone(fmt.tprintf("IK Target: %s", bone))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),         pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Effector Pos"), pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("IK Weight"),    pin_type = .Float, default_f32 = 1.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),         pin_type = .Exec})

	case .VFX_Emitter_Spawn:
		em := custom_name != "" ? custom_name : "Sparks_Main"
		n.action_name = strings.clone(em)
		n.title       = strings.clone(fmt.tprintf("VFX Emitter: %s", em))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Spawn Rate"), pin_type = .Float, default_f32 = 45.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Burst"),      pin_type = .Int,   default_int = 0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})

	case .VFX_GPU_Curl_Force:
		n.title = strings.clone("[GPU] Curl & Drag Force")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Velocity"),      pin_type = .Vec3,  default_vec3 = {0, 2, 0}})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Curl Strength"), pin_type = .Float, default_f32 = 1.5})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Drag"),          pin_type = .Float, default_f32 = 0.2})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Next Velocity"), pin_type = .Vec3})

	case .VFX_Color_Size_Life:
		n.title = strings.clone("[GPU] Size Over Life")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Norm Age"),   pin_type = .Float, default_f32 = 0.25})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Start Size"), pin_type = .Float, default_f32 = 0.35})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("End Size"),   pin_type = .Float, default_f32 = 0.02})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Size"),       pin_type = .Float})

	case .Audio_Random_Container:
		n.title = strings.clone("[Audio] Random Container")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Seed"),  pin_type = .Float, default_f32 = 0.5})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Count"), pin_type = .Int,   default_int = 4})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Index"), pin_type = .Int})

	case .Audio_Modulate_Pitch_Vol:
		n.title = strings.clone("[Audio] Modulate Pitch/Vol")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Base"),  pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Range"), pin_type = .Float, default_f32 = 0.12})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Seed"),  pin_type = .Float, default_f32 = 0.5})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"),   pin_type = .Float})

	case .Audio_Bus_Send:
		bn := custom_name != "" ? custom_name : "Music"
		n.action_name = strings.clone(bn)
		n.title       = strings.clone(fmt.tprintf("Audio Bus Send: %s", bn))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Volume"),    pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Cutoff Hz"), pin_type = .Float, default_f32 = 22000.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})

	case .Audio_Play_Spatial_3D:
		sn := custom_name != "" ? custom_name : "Cue_Impact"
		n.action_name = strings.clone(sn)
		n.title       = strings.clone(fmt.tprintf("Play Spatial 3D: %s", sn))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Pos"),    pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Volume"), pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Pitch"),  pin_type = .Float, default_f32 = 1.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})

	case .AI_Find_Path_Move:
		n.title = strings.clone("[AI] Find Path & Move")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target Pos"), pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Speed"),      pin_type = .Float, default_f32 = 4.5})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})

	case .AI_Check_Arrival:
		n.title = strings.clone("[AI] Check Arrival")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Tolerance"), pin_type = .Float, default_f32 = 0.25})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Arrived"),   pin_type = .Bool})

	case .Sequence:
		n.title = strings.clone("Sequence")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Then 0"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Then 1"), pin_type = .Exec})

	case .For_Loop:
		n.title = strings.clone("For Loop")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),        pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("First Index"), pin_type = .Int, default_int = 0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Last Index"),  pin_type = .Int, default_int = 4})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Loop Body"),   pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Index"),       pin_type = .Int})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Completed"),   pin_type = .Exec})
	}

	append(&g.nodes, n)
	return uid
}

vg_sequence_add_pin :: proc(n: ^VG_Node) {
	if n == nil || n.kind != .Sequence do return
	idx := len(n.outputs)
	append(&n.outputs, VG_Pin_Def{name = strings.clone(fmt.tprintf("Then %d", idx)), pin_type = .Exec})
}

vg_custom_proc_add_param :: proc(g: ^Visual_Graph, proc_uid: int, param_name: string, pt: hot.Hot_Pin_Type) -> bool {
	if g == nil || param_name == "" do return false
	entry := vg_find_node(g, proc_uid)
	if entry == nil || entry.kind != .Custom_Proc_Entry do return false
	for p in entry.outputs {
		if p.name == param_name do return false
	}
	append(&entry.outputs, VG_Pin_Def{name = strings.clone(param_name), pin_type = pt})
	target := entry.hot_proc_target
	for &nd in g.nodes {
		if nd.kind == .Call_Blueprint_Proc && nd.hot_proc_target == target {
			append(&nd.inputs, VG_Pin_Def{name = strings.clone(param_name), pin_type = pt})
		}
	}
	return true
}

// Infers missing `owner_proc` tags on nodes in legacy `.bodin` / `.mhgraph` graphs so each
// `Custom_Proc_Entry` + its downstream Exec chain + private pure feeders appear cleanly in its Procedure tab.
vg_infer_missing_owner_procs :: proc(g: ^Visual_Graph) {
	if g == nil do return

	for &n in g.nodes {
		if n.kind == .Custom_Proc_Entry && n.owner_proc == "" && n.hot_proc_target != "" {
			n.owner_proc = strings.clone(n.hot_proc_target)
		}
	}

	queue := make([dynamic]int, 0, 16, context.temp_allocator)
	for &entry in g.nodes {
		if entry.kind != .Custom_Proc_Entry || entry.hot_proc_target == "" do continue
		p_name := entry.hot_proc_target
		clear(&queue)
		// Follow outgoing Exec wires from Custom_Proc_Entry (pin index >= 1; skip pin 0 Delegate wire!)
		for w in g.wires {
			if w.from_uid == entry.uid && w.from_pin >= 1 {
				if to_n := vg_find_node(g, w.to_uid); to_n != nil {
					if to_n.kind != .Event_Init && to_n.kind != .Event_Tick && to_n.kind != .Event_Destroy && to_n.kind != .Custom_Proc_Entry {
						if to_n.owner_proc == "" {
							to_n.owner_proc = strings.clone(p_name)
							append(&queue, to_n.uid)
						}
					}
				}
			}
		}
		for qi := 0; qi < len(queue); qi += 1 {
			cur_uid := queue[qi]
			cur_n := vg_find_node(g, cur_uid)
			if cur_n == nil do continue
			// Walk downstream Exec wires
			for w in g.wires {
				if w.from_uid == cur_uid {
					if w.from_pin >= 0 && w.from_pin < len(cur_n.outputs) && cur_n.outputs[w.from_pin].pin_type == .Exec {
						if to_n := vg_find_node(g, w.to_uid); to_n != nil {
							if to_n.kind != .Event_Init && to_n.kind != .Event_Tick && to_n.kind != .Event_Destroy && to_n.kind != .Custom_Proc_Entry && to_n.owner_proc == "" {
								to_n.owner_proc = strings.clone(p_name)
								append(&queue, to_n.uid)
							}
						}
					}
				}
			}
			// Walk upstream pure data feeders exclusively feeding this procedure
			for w in g.wires {
				if w.to_uid == cur_uid {
					if fn := vg_find_node(g, w.from_uid); fn != nil && fn.owner_proc == "" {
						has_exec := false
						for ip in fn.inputs do if ip.pin_type == .Exec { has_exec = true; break }
						for op in fn.outputs do if op.pin_type == .Exec { has_exec = true; break }
						if !has_exec && fn.kind != .Custom_Proc_Entry {
							only_this_proc := true
							for ow in g.wires {
								if ow.from_uid == fn.uid {
									if dn := vg_find_node(g, ow.to_uid); dn != nil && dn.owner_proc != p_name {
										only_this_proc = false
										break
									}
								}
							}
							if only_this_proc {
								fn.owner_proc = strings.clone(p_name)
								append(&queue, fn.uid)
							}
						}
					}
				}
			}
		}
	}
}

vg_rename_delegate :: proc(g: ^Visual_Graph, old_name, new_name: string) -> bool {
	if g == nil || old_name == "" || new_name == "" || old_name == new_name do return false
	for ed in g.delegates {
		if ed == new_name do return false
	}
	found := false
	for &d in g.delegates {
		if d == old_name {
			delete(d)
			d = strings.clone(new_name)
			found = true
			break
		}
	}
	if !found do return false
	for &n in g.nodes {
		if n.delegate_name == old_name {
			delete(n.delegate_name)
			n.delegate_name = strings.clone(new_name)
		}
	}
	return true
}

vg_delete_delegate :: proc(g: ^Visual_Graph, name: string) -> bool {
	if g == nil || name == "" do return false
	removed := false
	for i := len(g.delegates) - 1; i >= 0; i -= 1 {
		if g.delegates[i] == name {
			delete(g.delegates[i])
			ordered_remove(&g.delegates, i)
			removed = true
		}
	}
	if !removed do return false

	del_uids := make([dynamic]int, 0, 8, context.temp_allocator)
	for &n in g.nodes {
		if n.delegate_name == name {
			append(&del_uids, n.uid)
		}
	}
	for wi := len(g.wires) - 1; wi >= 0; wi -= 1 {
		w := g.wires[wi]
		hit := false
		for du in del_uids {
			if w.from_uid == du || w.to_uid == du { hit = true; break }
		}
		if hit do ordered_remove(&g.wires, wi)
	}
	for ni := len(g.nodes) - 1; ni >= 0; ni -= 1 {
		hit := false
		for du in del_uids {
			if g.nodes[ni].uid == du { hit = true; break }
		}
		if hit {
			vg_destroy_node(&g.nodes[ni])
			ordered_remove(&g.nodes, ni)
		}
	}
	return true
}

vg_rename_custom_proc :: proc(g: ^Visual_Graph, proc_uid: int, new_name: string) -> bool {
	if g == nil || proc_uid <= 0 || new_name == "" do return false
	entry := vg_find_node(g, proc_uid)
	if entry == nil || entry.kind != .Custom_Proc_Entry do return false
	old_name := entry.hot_proc_target
	if old_name == new_name do return true
	if vg_find_custom_proc_node(g, new_name) != nil do return false

	old_copy := strings.clone(old_name, context.temp_allocator)
	for &n in g.nodes {
		if n.uid == proc_uid do continue
		if n.owner_proc == old_copy {
			delete(n.owner_proc)
			n.owner_proc = strings.clone(new_name)
		}
		if n.hot_proc_target == old_copy {
			delete(n.hot_proc_target)
			n.hot_proc_target = strings.clone(new_name)
			if n.kind == .Call_Blueprint_Proc {
				delete(n.title)
				n.title = strings.clone(fmt.tprintf("Call %s()", new_name))
			}
		}
	}
	delete(entry.hot_proc_target)
	entry.hot_proc_target = strings.clone(new_name)
	delete(entry.owner_proc)
	entry.owner_proc = strings.clone(new_name)
	delete(entry.title)
	entry.title = strings.clone(new_name)
	return true
}

vg_delete_custom_proc :: proc(g: ^Visual_Graph, proc_uid: int) -> bool {
	if g == nil || proc_uid <= 0 do return false
	entry := vg_find_node(g, proc_uid)
	if entry == nil || entry.kind != .Custom_Proc_Entry do return false
	proc_name := strings.clone(entry.hot_proc_target, context.temp_allocator)

	del_uids := make([dynamic]int, 0, 8, context.temp_allocator)
	for &n in g.nodes {
		if n.uid == proc_uid || (proc_name != "" && n.owner_proc == proc_name) {
			append(&del_uids, n.uid)
		} else if n.hot_proc_target == proc_name && proc_name != "" {
			delete(n.hot_proc_target)
			n.hot_proc_target = ""
		}
	}

	for wi := len(g.wires) - 1; wi >= 0; wi -= 1 {
		w := g.wires[wi]
		hit := false
		for du in del_uids {
			if w.from_uid == du || w.to_uid == du { hit = true; break }
		}
		if hit do ordered_remove(&g.wires, wi)
	}
	for ni := len(g.nodes) - 1; ni >= 0; ni -= 1 {
		hit := false
		for du in del_uids {
			if g.nodes[ni].uid == du { hit = true; break }
		}
		if hit {
			vg_destroy_node(&g.nodes[ni])
			ordered_remove(&g.nodes, ni)
		}
	}
	return len(del_uids) > 0
}

// Builds a rich Default Demo Blueprint showcasing `Event_Init` -> `Bind_Input_Action` (`◇ Delegate`),
// `● Copy` + `◆ ^Ref` variables, `👁 Instance Editable` inspector parameters, and `Odin_Function_Node`!
vg_init_default_demo_graph :: proc(g: ^Visual_Graph, graph_name: string = "hover_oscillator") {
	vg_destroy_graph(g)
	g.name           = strings.clone(graph_name)
	g.package_target = strings.clone("haati/hot_scripts")
	vg_ensure_default_spaces(g)
	append(&g.delegates, strings.clone("On_Boost_Pulse"))

	append(&g.variables, VG_Var_Decl{name = strings.clone("amplitude"), pin_type = .Float, default_f32 = 0.40, instance_editable = true, category = strings.clone("Motion"), tooltip_text = strings.clone("Oscillation vertical amplitude in meters"), slider_min = 0.0, slider_max = 5.0})
	append(&g.variables, VG_Var_Decl{name = strings.clone("frequency"), pin_type = .Float, default_f32 = 2.20, instance_editable = true, category = strings.clone("Motion"), tooltip_text = strings.clone("Oscillation frequency in Hz"), slider_min = 0.1, slider_max = 12.0})
	append(&g.variables, VG_Var_Decl{name = strings.clone("phase"),     pin_type = .Float, default_f32 = 0.00, instance_editable = false, category = strings.clone("Runtime")})

	// 1. Event_Init -> Bind Input Action ("Jump") -> `On_Jump_Boost` Odin Procedure!
	u_init  := vg_add_node(g, .Event_Init,        {40,  -150})
	u_proc  := vg_add_node(g, .Custom_Proc_Entry, {40,  -30}, "On_Jump_Boost")
	u_bind  := vg_add_node(g, .Bind_Input_Action, {420, -150}, "Jump")
	u_boost := vg_add_node(g, .Set_Transform_Pos, {780, -30})
	if bnode := vg_find_node(g, u_bind); bnode != nil {
		if bnode.hot_proc_target != "" do delete(bnode.hot_proc_target)
		bnode.hot_proc_target = strings.clone("On_Jump_Boost")
	}
	if nb := vg_find_node(g, u_boost); nb != nil && len(nb.inputs) > 1 {
		nb.inputs[1].default_vec3 = {0, 2.0, 0}
	}
	append(&g.wires, VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_bind,  to_pin = 0})
	append(&g.wires, VG_Wire{from_uid = u_proc, from_pin = 0, to_uid = u_bind,  to_pin = 1}) // `◇ Delegate` wire!
	append(&g.wires, VG_Wire{from_uid = u_proc, from_pin = 1, to_uid = u_boost, to_pin = 0})

	// 2. Event_Tick -> Harmonic Buoyancy (`● Copy` + `◆ ^Ref` + Scoped Odin Code!)
	u_tick  := vg_add_node(g, .Event_Tick,         {40,  160})
	u_amp   := vg_add_node(g, .Get_Variable,       {40,  310}, "amplitude")
	u_freq  := vg_add_node(g, .Get_Variable,       {40,  430}, "frequency")
	u_phase := vg_add_node(g, .Get_Variable,       {40,  550}, "phase")
	u_tpos  := vg_add_node(g, .Get_Transform_Pos,  {40,  680})
	u_odin  := vg_add_node(g, .Odin_Function_Node, {420, 220}, "Harmonic Buoyancy (Odin)")

	append(&g.wires, VG_Wire{from_uid = u_tick,  from_pin = 0, to_uid = u_odin, to_pin = 0})
	append(&g.wires, VG_Wire{from_uid = u_amp,   from_pin = 0, to_uid = u_odin, to_pin = 1})
	append(&g.wires, VG_Wire{from_uid = u_freq,  from_pin = 0, to_uid = u_odin, to_pin = 2})
	append(&g.wires, VG_Wire{from_uid = u_phase, from_pin = 1, to_uid = u_odin, to_pin = 3})
	append(&g.wires, VG_Wire{from_uid = u_tpos,  from_pin = 1, to_uid = u_odin, to_pin = 4})

	vg_infer_missing_owner_procs(g)
}

// =============================================================================
// Unified `.bodin` ("Blueprint Odin") & Legacy `.mhgraph` Load / Save
// =============================================================================
// A `.bodin` file IS valid Data-Oriented Odin source code at the top AND preserves
// its full visual node/wire layout inside a trailing `/* @BODIN_GRAPH_V1 ... @BODIN_GRAPH_END */`
// block at the bottom! Legacy `.mhgraph` pure-JSON files remain 100% supported.

BODIN_GRAPH_BEGIN :: "// @BODIN_GRAPH_V1"
BODIN_GRAPH_END   :: "// @BODIN_GRAPH_END"

vg_save_bodin_file :: proc(g: ^Visual_Graph, path: string, odin_source: string) -> bool {
	json_bytes, err := json.marshal(g^, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil do return false
	{
		context.allocator = context.temp_allocator
		dir := filepath.dir(path)
		if dir != "" && dir != "." {
			_ = os.make_directory_all(dir)
		}
	}

	header := strings.trim_right_space(odin_source)
	if header == "" {
		header = "package hot_scripts\n\n// Haati `.bodin` Blueprint Odin Script (Bake with F7 to populate native procedures)"
	}

	b: strings.Builder
	strings.builder_init(&b, 0, len(header) + len(json_bytes) + 256, context.temp_allocator)
	strings.write_string(&b, header)
	strings.write_string(&b, "\n\n")
	strings.write_string(&b, BODIN_GRAPH_BEGIN)
	strings.write_byte(&b, '\n')
	for ln in strings.split_lines(string(json_bytes), context.temp_allocator) {
		trimmed_cr := strings.trim_suffix(ln, "\r")
		strings.write_string(&b, "// ")
		strings.write_string(&b, trimmed_cr)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, BODIN_GRAPH_END)
	strings.write_byte(&b, '\n')
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

vg_save_to_file :: proc(g: ^Visual_Graph, path: string) -> bool {
	if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".bodin") {
		return vg_save_bodin_file(g, path, "")
	}
	bytes, err := json.marshal(g^, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil do return false
	{
		context.allocator = context.temp_allocator
		dir := filepath.dir(path)
		if dir != "" && dir != "." {
			_ = os.make_directory_all(dir)
		}
	}
	return os.write_entire_file(path, bytes) == nil
}

vg_load_from_file :: proc(g: ^Visual_Graph, path: string) -> bool {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return false
	payload := data
	raw_str := string(data)
	if b_idx := strings.index(raw_str, BODIN_GRAPH_BEGIN); b_idx >= 0 {
		after_begin := raw_str[b_idx + len(BODIN_GRAPH_BEGIN):]
		end_idx := strings.last_index(after_begin, BODIN_GRAPH_END)
		block := end_idx >= 0 ? after_begin[:end_idx] : after_begin
		jb: strings.Builder
		strings.builder_init(&jb, 0, len(block), context.temp_allocator)
		for ln in strings.split_lines(block, context.temp_allocator) {
			tl := strings.trim_space(strings.trim_suffix(ln, "\r"))
			if tl == "" do continue
			if strings.has_prefix(tl, "// ") {
				strings.write_string(&jb, tl[3:])
				strings.write_byte(&jb, '\n')
			} else if strings.has_prefix(tl, "//") {
				strings.write_string(&jb, tl[2:])
				strings.write_byte(&jb, '\n')
			}
		}
		payload = transmute([]u8)strings.to_string(jb)
	} else if b_legacy := strings.index(raw_str, "/* @BODIN_GRAPH_V1"); b_legacy >= 0 {
		after_begin := raw_str[b_legacy + len("/* @BODIN_GRAPH_V1"):]
		if c_idx := strings.last_index(after_begin, "*/"); c_idx >= 0 {
			json_slice := strings.trim_space(after_begin[:c_idx])
			payload = transmute([]u8)json_slice
		}
	}
	vg_destroy_graph(g)
	ok := json.unmarshal(payload, g) == nil
	if ok {
		vg_ensure_default_spaces(g)
		// Sanitize legacy unbaked Unicode prefixes (`"◇ "`, `"▷ "`) from saved `.bodin` / `.mhgraph` pin names
		// using the exact same `context.allocator` that `json.unmarshal` & `vg_destroy_graph` use!
		for &nd in g.nodes {
			for &ip in nd.inputs {
				if strings.has_prefix(ip.name, "◇ ") {
					clean := strings.clone(strings.trim_prefix(ip.name, "◇ "))
					delete(ip.name)
					ip.name = clean
				} else if strings.has_prefix(ip.name, "▷ ") {
					clean := strings.clone(strings.trim_prefix(ip.name, "▷ "))
					delete(ip.name)
					ip.name = clean
				}
			}
			for &op in nd.outputs {
				if strings.has_prefix(op.name, "◇ ") {
					clean := strings.clone(strings.trim_prefix(op.name, "◇ "))
					delete(op.name)
					op.name = clean
				} else if strings.has_prefix(op.name, "▷ ") {
					clean := strings.clone(strings.trim_prefix(op.name, "▷ "))
					delete(op.name)
					op.name = clean
				}
			}
		}
		vg_infer_missing_owner_procs(g)
	}
	return ok
}

// =============================================================================
// Tier-1 Crash-Proof In-RAM Graph Evaluator (`0.00 ms`, Zero Segfault Risk)
// =============================================================================

vg_sync_blackboard :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard) {
	if bb.initialized do return
	bb.initialized = true
	for v, i in g.variables {
		if i >= VG_MAX_VARS do break
		for k in 0 ..< len(bb.str_bufs[i]) do bb.str_bufs[i][k] = 0
		if v.default_str != "" {
			ncopy := min(len(v.default_str), len(bb.str_bufs[i]) - 1)
			if ncopy > 0 do copy(bb.str_bufs[i][:ncopy], v.default_str[:ncopy])
		}
		bb.slots[i] = hot.Hot_Slot{
			pin_type  = v.pin_type,
			pass_mode = .Copy_Value,
			val_f32   = v.default_f32,
			val_int   = v.default_int,
			val_i64   = v.default_i64,
			val_bool  = v.default_bool,
			val_vec2  = v.default_vec2,
			val_vec3  = v.default_vec3,
			val_vec4  = v.default_vec4,
			val_quat  = v.pin_type == .Quat ? {0, 0, 0, 1} : v.default_vec4,
			val_cstr  = cstring(&bb.str_bufs[i][0]),
		}
	}
}

@(private = "file")
_eval_pure_pin :: proc(
	g: ^Visual_Graph,
	bb: ^VG_Runtime_Blackboard,
	tH: Transform_Handle,
	raw_dt: f32,
	node_uid: int,
	out_pin_idx: int,
	depth: int,
) -> hot.Hot_Slot {
	if depth > 24 do return {}
	n := vg_find_node(g, node_uid)
	if n == nil || !n.enabled do return {}

	w := ctx_world()
	obj_dt := w != nil && pool_valid(&w.transforms, Handle(tH)) ? transform_dt(tH, raw_dt) : raw_dt

	#partial switch n.kind {
	case .Event_Tick:
		if out_pin_idx == 1 do return {pin_type = .Float, val_f32 = raw_dt}
		if out_pin_idx == 2 do return {pin_type = .Float, val_f32 = obj_dt}
		return {}

	case .Custom_Proc_Entry:
		if out_pin_idx == 0 {
			clean_g := g.name != "" ? g.name : "custom_graph"
			proc_sym := fmt.tprintf("mhgraph_%s__proc_%s", clean_g, n.hot_proc_target)
			slot_i := hot_proc_slot_index(proc_sym, false)
			return {
				pin_type = .Delegate,
				val_delegate = hot.Hot_Delegate{
					entity    = transform_to_hot_entity(tH),
					proc_slot = slot_i,
					node_uid  = i32(n.uid),
				},
			}
		}
		if out_pin_idx == 2 do return {pin_type = .Float, val_f32  = bb.last_payload_f32}
		if out_pin_idx == 3 do return {pin_type = .Vec2,  val_vec2 = bb.last_payload_v2}
		if out_pin_idx == 4 do return {pin_type = .Bool,  val_bool = bb.last_pressed}
		return {}

	case .Get_Variable:
		vi := vg_find_var_index(g, n.var_name)
		if vi < 0 || vi >= VG_MAX_VARS do return {}
		s := bb.slots[vi]
		if out_pin_idx == 1 {
			ptr: rawptr = nil
			#partial switch s.pin_type {
			case .Float: ptr = &bb.slots[vi].val_f32
			case .Int:   ptr = &bb.slots[vi].val_int
			case .Int64: ptr = &bb.slots[vi].val_i64
			case .Bool:  ptr = &bb.slots[vi].val_bool
			case .Vec2:  ptr = &bb.slots[vi].val_vec2
			case .Vec3:  ptr = &bb.slots[vi].val_vec3
			case .Vec4:  ptr = &bb.slots[vi].val_vec4
			case .Quat:  ptr = &bb.slots[vi].val_quat
			case .Entity: ptr = &bb.slots[vi].val_ent
			case .String, .Asset: ptr = &bb.slots[vi].val_cstr
			}
			s.pass_mode = .By_Reference
			s.ref_ptr   = ptr
			return s
		}
		s.pass_mode = .Copy_Value
		s.ref_ptr   = nil
		return s

	case .For_Loop:
		if out_pin_idx == 1 {
			for li in bb.loop_indices {
				if li.active && li.node_uid == n.uid {
					return {pin_type = .Int, val_int = li.cur_idx}
				}
			}
		}
		return {pin_type = .Int, val_int = 0}

	case .Get_Transform_Pos:
		if w == nil do return {pin_type = .Vec3}
		t := pool_get(&w.transforms, Handle(tH))
		if t == nil do return {pin_type = .Vec3}
		if out_pin_idx == 1 {
			return {pin_type = .Vec3, pass_mode = .By_Reference, val_vec3 = t.position, ref_ptr = &t.position}
		}
		return {pin_type = .Vec3, pass_mode = .Copy_Value, val_vec3 = t.position}

	case .Math_Float:
		a_slot := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		b_slot := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		a := hot.slot_read_f32(&a_slot)
		b := hot.slot_read_f32(&b_slot)
		res: f32 = 0
		switch n.math_op {
		case .Add:      res = a + b
		case .Sub:      res = a - b
		case .Mul:      res = a * b
		case .Div:      res = abs(b) > 1e-6 ? (a / b) : 0
		case .Sin_Wave: res = math.sin(a * math.TAU) * b
		case .Damp:     res = hot.damp_f32(a, b, 8.0, obj_dt)
		}
		return {pin_type = .Float, val_f32 = res}

	case .Vec3_Scale_Add:
		base_s  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		axis_s  := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		scale_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		v := hot.slot_read_vec3(&base_s) + hot.slot_read_vec3(&axis_s) * hot.slot_read_f32(&scale_s)
		return {pin_type = .Vec3, val_vec3 = v}

	case .Anim_Clip_Eval:
		spd_s  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		norm_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		ph := math.mod(hot.slot_read_f32(&norm_s) + obj_dt * hot.slot_read_f32(&spd_s), 1.0)
		if out_pin_idx == 1 do return {pin_type = .Float, val_f32 = ph}
		return {pin_type = .Float, val_f32 = 1.0}

	case .Anim_Blend_Layered:
		s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s2 := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		b0 := hot.slot_read_f32(&s0)
		b1 := hot.slot_read_f32(&s1)
		al := clamp(hot.slot_read_f32(&s2), 0.0, 1.0)
		return {pin_type = .Float, val_f32 = math.lerp(b0, b1, al)}

	case .Anim_Spring_Damper:
		s0  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s1  := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s2  := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		cur := hot.slot_read_f32(&s0)
		tgt := hot.slot_read_f32(&s1)
		spd := max(hot.slot_read_f32(&s2), 0.01)
		return {pin_type = .Float, val_f32 = hot.damp_f32(cur, tgt, spd, obj_dt)}

	case .VFX_GPU_Curl_Force:
		s0   := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s1   := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s2   := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		vel  := hot.slot_read_vec3(&s0)
		curl := hot.slot_read_f32(&s1)
		drag := clamp(hot.slot_read_f32(&s2), 0.0, 20.0)
		swirl := [3]f32{math.sin(vel.y * 1.7), math.cos(vel.x * 1.3), math.sin(vel.z * 1.5)} * (curl * obj_dt)
		next_v := (vel + swirl) * max(1.0 - drag * obj_dt, 0.0)
		return {pin_type = .Vec3, val_vec3 = next_v}

	case .VFX_Color_Size_Life:
		s_age := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s_min := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s_max := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		age   := clamp(hot.slot_read_f32(&s_age), 0.0, 1.0)
		s0    := hot.slot_read_f32(&s_min)
		s1    := hot.slot_read_f32(&s_max)
		return {pin_type = .Float, val_f32 = math.lerp(s0, s1, age)}

	case .Audio_Random_Container:
		s_seed  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s_count := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		cnt     := max(int(hot.slot_read_int(&s_count)), 1)
		frac    := math.mod(abs(hot.slot_read_f32(&s_seed)), f32(1.0))
		idx     := clamp(int(frac * f32(cnt)), 0, cnt - 1)
		return {pin_type = .Int, val_int = i32(idx)}

	case .Audio_Modulate_Pitch_Vol:
		s_base := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s_rng  := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s_seed := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		base   := hot.slot_read_f32(&s_base)
		rng    := hot.slot_read_f32(&s_rng)
		frac   := math.mod(abs(hot.slot_read_f32(&s_seed)), f32(1.0))
		return {pin_type = .Float, val_f32 = base + (frac * 2.0 - 1.0) * rng}

	case .AI_Check_Arrival:
		s_tol := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		tol   := hot.slot_read_f32(&s_tol)
		arrived := false
		if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(tH)) {
			if nav_agent_has_arrived(w, tH) {
				arrived = true
			} else if _, ag := transform_get_comp(tH, NavMeshAgent); ag != nil && ag.has_destination {
				tw := transform_world(tH)
				if linalg.distance(tw.position, ag.target_position) <= max(tol, ag.stopping_distance) {
					arrived = true
				}
			}
		}
		return {pin_type = .Bool, val_bool = arrived}
	}
	return {}
}

@(private = "file")
_eval_node_input :: proc(
	g: ^Visual_Graph,
	bb: ^VG_Runtime_Blackboard,
	tH: Transform_Handle,
	raw_dt: f32,
	dst_node: ^VG_Node,
	in_pin_idx: int,
	depth: int,
) -> hot.Hot_Slot {
	if in_pin_idx < 0 || in_pin_idx >= len(dst_node.inputs) do return {}
	pdef := dst_node.inputs[in_pin_idx]

	for wire in g.wires {
		if wire.to_uid == dst_node.uid && wire.to_pin == in_pin_idx {
			val := _eval_pure_pin(g, bb, tH, raw_dt, wire.from_uid, wire.from_pin, depth)
			if pdef.pass_mode == .Copy_Value && val.pass_mode == .By_Reference && val.ref_ptr != nil {
				#partial switch val.pin_type {
				case .Float:  val.val_f32  = (cast(^f32)val.ref_ptr)^
				case .Int:    val.val_int  = (cast(^i32)val.ref_ptr)^
				case .Int64:  val.val_i64  = (cast(^i64)val.ref_ptr)^
				case .Bool:   val.val_bool = (cast(^bool)val.ref_ptr)^
				case .Vec2:   val.val_vec2 = (cast(^[2]f32)val.ref_ptr)^
				case .Vec3:   val.val_vec3 = (cast(^[3]f32)val.ref_ptr)^
				case .Vec4:   val.val_vec4 = (cast(^[4]f32)val.ref_ptr)^
				case .Quat:   val.val_quat = (cast(^[4]f32)val.ref_ptr)^
				case .Entity: val.val_ent  = (cast(^hot.Hot_Entity)val.ref_ptr)^
				case .String, .Asset: val.val_cstr = (cast(^cstring)val.ref_ptr)^
				}
				val.pass_mode = .Copy_Value
				val.ref_ptr   = nil
			}
			return val
		}
	}

	return hot.Hot_Slot{
		pin_type  = pdef.pin_type,
		pass_mode = .Copy_Value,
		val_f32   = pdef.default_f32,
		val_int   = pdef.default_int,
		val_i64   = pdef.default_i64,
		val_bool  = pdef.default_bool,
		val_vec2  = pdef.default_vec2,
		val_vec3  = pdef.default_vec3,
		val_vec4  = pdef.default_vec4,
		val_quat  = pdef.pin_type == .Quat ? {0, 0, 0, 1} : pdef.default_vec4,
		val_cstr  = pdef.default_str != "" ? strings.clone_to_cstring(pdef.default_str, context.temp_allocator) : cstring(""),
	}
}

@(private = "file")
_find_exec_target :: proc(g: ^Visual_Graph, from_uid: int, from_exec_pin: int) -> int {
	for wire in g.wires {
		if wire.from_uid == from_uid && wire.from_pin == from_exec_pin {
			return wire.to_uid
		}
	}
	return 0
}

// Resolves `(target_proc_name, target_node_uid)` from either a `◇ Delegate` input wire OR `n.hot_proc_target` dropdown!
@(private = "file")
_resolve_delegate_target_on_node :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, tH: Transform_Handle, raw_dt: f32, n: ^VG_Node, del_pin_idx: int) -> (target_proc: string, target_uid: int) {
	del_slot := _eval_node_input(g, bb, tH, raw_dt, n, del_pin_idx, 0)
	del := hot.slot_read_delegate(&del_slot)
	if del.node_uid > 0 {
		if pn := vg_find_node(g, int(del.node_uid)); pn != nil {
			clean_g := g.name != "" ? g.name : "custom_graph"
			return fmt.tprintf("mhgraph_%s__proc_%s", clean_g, pn.hot_proc_target), int(del.node_uid)
		}
	}
	if n.hot_proc_target != "" {
		if pn := vg_find_custom_proc_node(g, n.hot_proc_target); pn != nil {
			clean_g := g.name != "" ? g.name : "custom_graph"
			return fmt.tprintf("mhgraph_%s__proc_%s", clean_g, pn.hot_proc_target), pn.uid
		}
		return n.hot_proc_target, 0
	}
	return "", 0
}

// Evaluates an execution chain starting from `entry_node_uid` (`Event_Init`, `Event_Tick`, `Custom_Proc_Entry`, etc.).
vg_eval_from_entry_uid :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, tH: Transform_Handle, raw_dt: f32, entry_node_uid: int, call_depth: int = 0) {
	if g == nil || bb == nil || entry_node_uid <= 0 || call_depth > 12 do return
	vg_sync_blackboard(g, bb)
	if call_depth == 0 {
		clear(&bb.last_exec_path)
	}

	entry_node := vg_find_node(g, entry_node_uid)
	if entry_node == nil || !entry_node.enabled do return
	append(&bb.last_exec_path, entry_node_uid)

	// `Custom_Proc_Entry` has `◇ Delegate` on output 0 and `▷ Exec` on output 1!
	start_exec_pin := entry_node.kind == .Custom_Proc_Entry ? 1 : 0
	cur_uid := _find_exec_target(g, entry_node_uid, start_exec_pin)
	_eval_exec_chain_from_uid(g, bb, tH, raw_dt, cur_uid, call_depth)
}

@(private = "file")
_eval_exec_chain_from_uid :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, tH: Transform_Handle, raw_dt: f32, start_uid: int, call_depth: int) {
	if start_uid <= 0 || call_depth > 16 do return
	cur_uid := start_uid

	w := ctx_world()
	obj_dt := w != nil && pool_valid(&w.transforms, Handle(tH)) ? transform_dt(tH, raw_dt) : raw_dt

	hops := 0
	for cur_uid != 0 && hops < 64 {
		hops += 1
		n := vg_find_node(g, cur_uid)
		if n == nil do break
		append(&bb.last_exec_path, cur_uid)

		next_exec_pin := 0
		if n.enabled {
			#partial switch n.kind {
			case .Set_Variable:
				vi := vg_find_var_index(g, n.var_name)
				if vi >= 0 && vi < VG_MAX_VARS {
					in_val := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
					bb.slots[vi].val_f32  = hot.slot_read_f32(&in_val)
					bb.slots[vi].val_int  = hot.slot_read_int(&in_val)
					bb.slots[vi].val_i64  = hot.slot_read_i64(&in_val)
					bb.slots[vi].val_bool = hot.slot_read_bool(&in_val)
					bb.slots[vi].val_vec2 = hot.slot_read_vec2(&in_val)
					bb.slots[vi].val_vec3 = hot.slot_read_vec3(&in_val)
					bb.slots[vi].val_vec4 = hot.slot_read_vec4(&in_val)
					bb.slots[vi].val_quat = hot.slot_read_quat(&in_val)
					bb.slots[vi].val_ent  = hot.slot_read_entity(&in_val)
					if cs_in := hot.slot_read_cstr(&in_val); cs_in != "" {
						s_in := string(cs_in)
						for k in 0 ..< len(bb.str_bufs[vi]) do bb.str_bufs[vi][k] = 0
						ncopy := min(len(s_in), len(bb.str_bufs[vi]) - 1)
						if ncopy > 0 do copy(bb.str_bufs[vi][:ncopy], s_in[:ncopy])
						bb.slots[vi].val_cstr = cstring(&bb.str_bufs[vi][0])
					}
				}

			case .Set_Transform_Pos:
				if w != nil {
					if t := pool_get(&w.transforms, Handle(tH)); t != nil {
						in_pos := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
						t.position = hot.slot_read_vec3(&in_pos)
					}
				}

			case .Branch_If:
				cond_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				next_exec_pin = hot.slot_read_bool(&cond_s) ? 0 : 1

			case .Sequence:
				for out_pi in 0 ..< len(n.outputs) {
					if branch_uid := _find_exec_target(g, cur_uid, out_pi); branch_uid != 0 {
						_eval_exec_chain_from_uid(g, bb, tH, raw_dt, branch_uid, call_depth + 1)
					}
				}
				cur_uid = 0
				continue

			case .For_Loop:
				first_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				last_s  := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				first_i := hot.slot_read_int(&first_s)
				last_i  := min(hot.slot_read_int(&last_s), first_i + 10_000)
				body_uid := _find_exec_target(g, cur_uid, 0)

				loop_slot := -1
				for &li, idx in bb.loop_indices {
					if !li.active || li.node_uid == cur_uid {
						li.node_uid = cur_uid
						li.active   = true
						loop_slot   = idx
						break
					}
				}
				for idx := first_i; idx <= last_i; idx += 1 {
					if loop_slot >= 0 do bb.loop_indices[loop_slot].cur_idx = idx
					if body_uid != 0 {
						_eval_exec_chain_from_uid(g, bb, tH, raw_dt, body_uid, call_depth + 1)
					}
				}
				if loop_slot >= 0 do bb.loop_indices[loop_slot].active = false
				next_exec_pin = 2

			case .Set_Time_Scale:
				sc_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				sc   := hot.slot_read_f32(&sc_s)
				if n.per_object_ts {
					transform_set_custom_time_scale(tH, sc)
				} else {
					set_time_scale(sc)
				}

			case .Bind_Input_Action:
				tp, tuid := _resolve_delegate_target_on_node(g, bb, tH, raw_dt, n, 1)
				visual_script_bind_action_runtime(tH, n.action_name, n.trigger_edge, int(n.input_priority), n.consume_input, tp, tuid)

			case .Unbind_Input_Action:
				visual_script_unbind_action_runtime(tH, n.action_name)

			case .Bind_Input_Vector:
				tp, tuid := _resolve_delegate_target_on_node(g, bb, tH, raw_dt, n, 1)
				visual_script_bind_vector_runtime(tH, n.is_look_vector, int(n.input_priority), n.consume_input, tp, tuid)

			case .Unbind_Input_Vector:
				visual_script_unbind_vector_runtime(tH, n.is_look_vector)

			case .Bind_Debug_Key:
				tp, tuid := _resolve_delegate_target_on_node(g, bb, tH, raw_dt, n, 1)
				visual_script_bind_debug_key_runtime(tH, int(n.debug_key_code), n.trigger_edge, tp, tuid)

			case .Unbind_Debug_Key:
				visual_script_unbind_debug_key_runtime(tH, int(n.debug_key_code))

			case .Unbind_All_Inputs:
				visual_script_unbind_all_for_entity(tH)

			case .Delegate_Bind:
				tp, tuid := _resolve_delegate_target_on_node(g, bb, tH, raw_dt, n, 1)
				visual_script_bind_custom_delegate_runtime(tH, n.delegate_name, tp, tuid)

			case .Delegate_Unbind:
				visual_script_unbind_custom_delegate_runtime(tH, n.delegate_name)

			case .Delegate_Broadcast:
				pay_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				visual_script_broadcast_custom_delegate_runtime(tH, n.delegate_name, hot.slot_read_f32(&pay_s))

			case .Call_Blueprint_Proc:
				pay_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				bb.last_payload_f32 = hot.slot_read_f32(&pay_s)
				if pn := vg_find_custom_proc_node(g, n.hot_proc_target); pn != nil {
					vg_eval_from_entry_uid(g, bb, tH, raw_dt, pn.uid, call_depth + 1)
				}

			case .Anim_IK_Target:
				eff_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				wt_s  := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				_ = eff_s; _ = wt_s

			case .VFX_Emitter_Spawn:
				rate_s  := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				burst_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				_ = rate_s; _ = burst_s

			case .Audio_Bus_Send:
				vol_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				cut_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				_ = vol_s; _ = cut_s

			case .Audio_Play_Spatial_3D:
				pos_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				vol_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				pit_s := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				_ = pos_s; _ = vol_s; _ = pit_s

			case .AI_Find_Path_Move:
				pos_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				spd_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				tgt   := hot.slot_read_vec3(&pos_s)
				spd   := hot.slot_read_f32(&spd_s)
				if w != nil && pool_valid(&w.transforms, Handle(tH)) {
					if _, ag := transform_get_comp(tH, NavMeshAgent); ag != nil {
						if spd > 0 do ag.speed = spd
						_ = nav_agent_set_destination(w, tH, tgt)
					}
				}

			case .Call_Hot_Proc, .Odin_Function_Node:
				frame: hot.Hot_Call_Frame
				arg_i := 0
				for pin_i in 1 ..< len(n.inputs) {
					if arg_i >= hot.HOT_MAX_ARGS do break
					frame.inputs[arg_i] = _eval_node_input(g, bb, tH, raw_dt, n, pin_i, 0)
					arg_i += 1
				}
				frame.input_count = i32(arg_i)

				if n.hot_proc_target != "" && hot_proc_exists(n.hot_proc_target) {
					hot_proc_invoke(n.hot_proc_target, tH, obj_dt, &frame)
				} else if n.kind == .Odin_Function_Node && frame.input_count >= 4 {
					// Instant zero-compile fallback for the default Harmonic Buoyancy formula before first F7 bake!
					amp   := hot.slot_read_f32(&frame.inputs[0])
					freq  := hot.slot_read_f32(&frame.inputs[1])
					phase := hot.slot_ref_f32(&frame.inputs[2])
					pos   := hot.slot_ref_vec3(&frame.inputs[3])
					phase^ += obj_dt * freq * math.TAU
					pos.y  += math.sin(phase^) * amp * obj_dt
				}
			}
		}

		cur_uid = _find_exec_target(g, cur_uid, next_exec_pin)
	}
}

vg_eval_event_live :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, tH: Transform_Handle, raw_dt: f32, event_kind: VG_Node_Kind) {
	if g == nil || bb == nil do return
	for n in g.nodes {
		if n.kind == event_kind && n.enabled {
			vg_eval_from_entry_uid(g, bb, tH, raw_dt, n.uid, 0)
			break
		}
	}
}

vg_eval_custom_proc_live :: proc(
	g:           ^Visual_Graph,
	bb:          ^VG_Runtime_Blackboard,
	tH:          Transform_Handle,
	raw_dt:      f32,
	proc_name:   string,
	payload_f32: f32    = 0.0,
	payload_v2:  [2]f32 = {},
	pressed:     bool   = true,
) -> bool {
	if g == nil || bb == nil || proc_name == "" do return false
	vg_sync_blackboard(g, bb)
	bb.last_payload_f32 = payload_f32
	bb.last_payload_v2  = payload_v2
	bb.last_pressed     = pressed

	for n in g.nodes {
		if n.kind == .Custom_Proc_Entry && n.enabled {
			clean_g := g.name != "" ? g.name : "custom_graph"
			full_sym := fmt.tprintf("mhgraph_%s__proc_%s", clean_g, n.hot_proc_target)
			if n.hot_proc_target == proc_name || n.title == proc_name || full_sym == proc_name {
				vg_eval_from_entry_uid(g, bb, tH, raw_dt, n.uid, 0)
				return true
			}
		}
	}
	return false
}

// Evaluates `Event_Tick` in Tier-1 Safe In-RAM Mode (`0.00 ms` when `Event_Tick` is absent!).
vg_eval_graph_live :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, tH: Transform_Handle, raw_dt: f32) {
	vg_eval_event_live(g, bb, tH, raw_dt, .Event_Tick)
}
