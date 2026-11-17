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
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import hot "hot_api"
import "input"

VG_MAX_LOOP_ITERATIONS :: 10_000

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
	For_Loop                 = 39, // Universal 4-Mode Odin `for` loop (`Range`, `For_In_Value`, `For_In_Ref`, `Condition`)

	// V6 Odin-Native Type Power, Universal Loops, Auto-Casts, Timers & Real Gameplay Bridges (40..59)
	Break_Loop               = 40, // Breaks out of the enclosing `For_Loop`
	Continue_Loop            = 41, // Jumps to next iteration of the enclosing `For_Loop`
	Switch_Value             = 42, // Exhaustive Odin `switch val { case ... }` multi-pin router
	BitSet_Op                = 43, // `bit_set[Enum; u8]` operations (`Set_Flag`, `Clear_Flag`, `Toggle_Flag`, `Has_Flag`, `Is_Empty`)
	Make_Struct              = 44, // Packs a user-declared POD `struct` from its field pins
	Break_Struct             = 45, // Unpacks a user-declared POD `struct` into field output pins
	Array_Op                 = 46, // Fixed `[N]T` & `Bounded_Array` operations (`Get_Copy`, `Get_Ref`, `Set`, `Append`, `Pop`, `Clear`, `Len`, `Swap_Remove`)
	Defer_Exec               = 47, // Odin `defer { ... }` scoped cleanup execution pin on exit from scope
	Or_Branch                = 48, // Odin `val, ok -> Valid / Failed` multi-return error branch
	Auto_Cast                = 49, // Compact implicit numeric conversion / `.xy` / `.xz` vector swizzle micro-pill
	Reroute_Knot             = 50, // Zero-overhead wire reroute junction dot
	Delay_Timer              = 51, // Hot-swap-safe elapsed timer (`Duration`, `Reset` -> `Elapsed`, `Completed`)
	Cooldown_Gate            = 52, // Hot-swap-safe cooldown gate (`Duration`, `Reset` -> `Ready`, `Blocked`, `Remaining`)
	Spawn_Prefab             = 53, // Instantiates a prefab scene by GUID/path at `Pos` & `Rot`
	Destroy_Entity           = 54, // Safely destroys target `Hot_Entity` at frame boundary
	Physics_Raycast          = 55, // Jolt channel-masked narrowphase raycast (`Hit`, `Point`, `Normal`, `Dist`, `Entity`)
	Physics_Overlap_Sphere   = 56, // Sphere overlap query returning count & closest entity
	Physics_Add_Impulse      = 57, // Applies impulse or velocity change to target `Rigidbody`
	Event_On_Trigger         = 58, // Event fired when Jolt trigger sensor / contact begins on `self` (`Exec`, `Other Entity`)
	CSG_Brush_Stamp          = 59, // Runtime Faker-CSG / Destructible CSG spherical cut/stamp on active scene volumes
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

VG_For_Mode :: enum u8 {
	Range_Inclusive = 0, // `for i in first..=last` (legacy default)
	Range_Half_Open = 1, // `for i in first..<last`
	For_In_Value    = 2, // `for elem, i in arr`
	For_In_Ref      = 3, // `for &elem, i in arr` (exposes addressable `◆ Element (^T)`)
	Condition       = 4, // `for cond` (Odin while loop)
}

VG_Array_Op_Mode :: enum u8 {
	Get_Copy    = 0,
	Get_Ref     = 1,
	Set_Elem    = 2,
	Append      = 3,
	Pop         = 4,
	Clear       = 5,
	Len         = 6,
	Swap_Remove = 7,
	Sub_Slice   = 8, // Zero-copy `arr[Start:End]` slice view
}

VG_BitSet_Op_Mode :: enum u8 {
	Set_Flag    = 0,
	Clear_Flag  = 1,
	Toggle_Flag = 2,
	Has_Flag    = 3,
	Is_Empty    = 4,
}

VG_Container_Kind :: enum u8 {
	Single        = 0,
	Fixed_Array   = 1,
	Bounded_Array = 2,
	Slice         = 3,
	Dynamic_Array = 4,
}

VG_Enum_Decl :: struct {
	name:          string,
	variants:      [dynamic]string,
	has_bitset:    bool,
	bitset_name:   string,
	code_authored: bool `json:"-"`,
	source_line:   int `json:"-"`,
}

VG_Struct_Field :: struct {
	name:         string,
	pin_type:     hot.Hot_Pin_Type,
	custom_type:  string,
	default_f32:  f32,
	default_int:  i32,
	default_u64:  u64,
	default_f64:  f64,
	default_bool: bool,
	default_vec2: [2]f32,
	default_vec3: [3]f32,
	default_vec4: [4]f32,
}

VG_Struct_Decl :: struct {
	name:              string,
	using_parent_name: string,
	fields:            [dynamic]VG_Struct_Field,
	code_authored:     bool `json:"-"`,
	source_line:       int `json:"-"`,
}

VG_Pin_Def :: struct {
	name:              string,
	pin_type:          hot.Hot_Pin_Type,
	pass_mode:         hot.Hot_Pass_Mode, // `.Copy_Value` (`●`) or `.By_Reference` (`◆ ^T`)
	is_addressable:    bool,              // For output pins: `true` if output carries a mutable lvalue pointer (`^T`)
	is_array:          bool,              // Container pin (`Fixed_Array`, `Bounded_Array`, `Slice`, `Dynamic_Array`)
	container_kind:    VG_Container_Kind,
	custom_type_name:  string,            // Enum / BitSet / Struct type name when applicable
	default_f32:       f32,
	default_int:       i32,
	default_i64:       i64,
	default_u64:       u64,
	default_f64:       f64,
	default_bool:      bool,
	default_vec2:      [2]f32,
	default_vec3:      [3]f32,
	default_vec4:      [4]f32,
	default_str:       string,
	split_expanded:    bool,   // Original pin expanded inline into sub-pins
	split_parent_name: string, // Non-empty on child sub-pins created by splitting `split_parent_name`
	split_field_name:  string, // Component (`x`,`y`,`z`,`w`) or struct field name on split child pins
}

VG_Var_Decl :: struct {
	name:              string,
	pin_type:          hot.Hot_Pin_Type,
	is_array:          bool,              // Fixed / Bounded / Slice / Dynamic container flag
	container_kind:    VG_Container_Kind, // `Single`, `Fixed_Array`, `Bounded_Array`, `Slice` (`[]T`), `Dynamic_Array` (`[dynamic]T`)
	array_count:       int,               // `0` -> legacy `[8]T` when Fixed/Bounded; `> 0` -> `[array_count]T`
	array_is_bounded:  bool,              // `true` -> zero-heap C-ABI `struct { data: [Cap]T, count: i32 }`
	custom_type_name:  string,            // Enum / BitSet / Struct type name
	default_f32:       f32,
	default_f32_list:  [dynamic]f32,      // Default element values for Slice / Dynamic / Fixed float arrays
	default_int:       i32,
	default_i64:       i64,
	default_u64:       u64,
	default_f64:       f64,
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

	// V6 Loop / Switch / Array / Struct / Cast configuration
	for_mode:           VG_For_Mode,
	loop_reverse:       bool,
	sub_op:             int,                  // `VG_Array_Op_Mode` / `VG_BitSet_Op_Mode` / `Switch_Value` case count
	target_var_or_type: string,               // Var name (`Array_Op`/`For_Loop`), Enum name (`Switch`/`BitSet_Op`), or Struct name (`Make`/`Break_Struct`)

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
	enums:          [dynamic]VG_Enum_Decl,
	structs:        [dynamic]VG_Struct_Decl,
	variables:      [dynamic]VG_Var_Decl,
	nodes:          [dynamic]VG_Node,
	wires:          [dynamic]VG_Wire,
}

// Runtime Blackboard held per entity (or preview session) for Tier-1 & Tier-2 execution.
VG_MAX_VARS :: 32

VG_Timer_Entry :: struct {
	remaining:       f32,
	is_cooldown:     bool,
	last_tick_epoch: u64,
}

VG_Raw_Seq_Entry :: struct {
	data:       rawptr,
	length:     int,
	capacity:   int,
	elem_size:  int,
	elem_align: int,
	owns_alloc: bool,
}

VG_BLOB_CANARY_HEAD :: u64(0xDEAD_4841_4154_0001)
VG_BLOB_CANARY_TAIL :: u64(0xBEEF_4841_4154_0002)
VG_BLOB_TAIL_BYTES  :: 16

VG_Runtime_Blackboard :: struct {
	initialized:             bool,
	slots:                   [VG_MAX_VARS]hot.Hot_Slot,
	str_bufs:                [VG_MAX_VARS][128]u8,
	var_blobs:               map[string][dynamic]u8,
	var_f32_seqs:            map[string][dynamic]f32,
	var_seqs:                map[string]VG_Raw_Seq_Entry,
	node_timers:             map[u32]VG_Timer_Entry,
	live_pin_values:         map[u64]hot.Hot_Slot,
	loop_indices:            [8]struct{ node_uid: int, cur_idx: i32, elem_ptr: rawptr, elem_pin_type: hot.Hot_Pin_Type, active: bool },
	loop_break_requested:    bool,
	loop_continue_requested: bool,
	loop_fuse_tripped_uid:   int,
	trigger_other_entity:    Transform_Handle,
	last_exec_path:          [dynamic]int,
	last_payload_f32:        f32,
	last_payload_v2:         [2]f32,
	last_pressed:            bool,
}

// =============================================================================
// ECS `@(component)` Visual Script / Blueprint Runner
// =============================================================================

@(component={max=1024, menu="Scripting/Blueprint Script Runner"})
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

Visual_Script_Trigger_Hit :: struct {
	self_entity:  Transform_Handle,
	other_entity: Transform_Handle,
}

Visual_Script_Physics_Bridge :: struct {
	raycast_masked: proc(origin, dir: [3]f32, max_dist: f32, mask: u32, ignore_owner: Transform_Handle) -> (hit: hot.Hot_Raycast_Hit, ok: bool),
	overlap_sphere: proc(center: [3]f32, radius: f32, mask: u32, ignore_owner: Transform_Handle) -> (count: i32, closest: Transform_Handle),
	add_impulse:    proc(target: Transform_Handle, impulse: [3]f32, is_velocity_change: bool),
	poll_triggers:  proc(allocator: runtime.Allocator) -> []Visual_Script_Trigger_Hit,
}

Visual_Script_Audio_Bridge :: struct {
	bus_send:        proc(bus_name: string, volume, cutoff_hz: f32),
	play_spatial_3d: proc(self: Transform_Handle, cue_name: string, pos: [3]f32, volume, pitch: f32),
}

Visual_Script_VFX_Bridge :: struct {
	emitter_spawn: proc(target: Transform_Handle, emitter_name: string, rate: f32, burst_count: i32),
}

Visual_Script_Anim_Bridge :: struct {
	set_ik_target: proc(target: Transform_Handle, effector_name: string, effector_pos: [3]f32, weight: f32),
}

Visual_Script_CSG_Bridge :: struct {
	brush_stamp: proc(world_pos: [3]f32, radius, impulse: f32, cut_mat_str: string) -> i32,
}

@(private = "file") _vs_physics_bridge: Visual_Script_Physics_Bridge
@(private = "file") _vs_audio_bridge:   Visual_Script_Audio_Bridge
@(private = "file") _vs_vfx_bridge:     Visual_Script_VFX_Bridge
@(private = "file") _vs_anim_bridge:    Visual_Script_Anim_Bridge
@(private = "file") _vs_csg_bridge:     Visual_Script_CSG_Bridge

visual_script_install_physics_bridge :: proc(b: Visual_Script_Physics_Bridge) { _vs_physics_bridge = b }
visual_script_install_audio_bridge   :: proc(b: Visual_Script_Audio_Bridge)   { _vs_audio_bridge = b }
visual_script_install_vfx_bridge     :: proc(b: Visual_Script_VFX_Bridge)     { _vs_vfx_bridge = b }
visual_script_install_anim_bridge    :: proc(b: Visual_Script_Anim_Bridge)    { _vs_anim_bridge = b }
visual_script_install_csg_bridge     :: proc(b: Visual_Script_CSG_Bridge)     { _vs_csg_bridge = b }

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
	initialized:         bool,
	next_token_id:       u32,
	tick_epoch:          u64,
	inside_runners_tick: bool,
	action_bindings:     [dynamic]_VS_Action_Binding,
	vector_bindings:     [dynamic]_VS_Vector_Binding,
	debug_bindings:      [dynamic]_VS_Debug_Key_Binding,
	entities:            map[u64]^_VS_Entity_State,
	disk_graphs:         map[string]^Visual_Graph,
	last_dt:             f32,
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
	if !vfs_has_file(rel_or_abs) && !filepath.is_abs(abs_p) {
		if vfs_exists(rel_or_abs) {
			abs_p = rel_or_abs
			if os.exists(rel_or_abs) {
				abs_p, _ = filepath.abs(rel_or_abs, context.temp_allocator)
			}
		} else if proj_dir := active_project_root(); proj_dir != "" {
			proj_cand, _ := filepath.join({proj_dir, rel_or_abs}, context.temp_allocator)
			if vfs_exists(proj_cand) do abs_p = proj_cand
		}
		if !vfs_exists(abs_p) {
			root := resolve_repo_root(context.temp_allocator)
			abs_p, _ = filepath.join({root, rel_or_abs}, context.temp_allocator)
			if !vfs_exists(abs_p) {
				alt_moon, _ := filepath.join({root, "haati", rel_or_abs}, context.temp_allocator)
				if vfs_exists(alt_moon) do abs_p = alt_moon
			}
		}
		// Seamless `.bodin` <-> `.mhgraph` fallback so older saved scenes and upgraded `.bodin` assets both resolve!
		if !vfs_exists(abs_p) {
			if strings.has_suffix(abs_p, ".mhgraph") {
				cand := fmt.tprintf("%s.bodin", strings.trim_suffix(abs_p, ".mhgraph"))
				if vfs_exists(cand) do abs_p = cand
			} else if strings.has_suffix(abs_p, ".bodin") {
				cand := fmt.tprintf("%s.mhgraph", strings.trim_suffix(abs_p, ".bodin"))
				if vfs_exists(cand) do abs_p = cand
			}
		}
	}
	if !vfs_exists(abs_p) do return nil

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
_is_unescaped_at :: proc(s: string, idx: int) -> bool {
	bs := 0
	for j := idx - 1; j >= 0 && s[j] == '\\'; j -= 1 {
		bs += 1
	}
	return (bs & 1) == 0
}

_split_unescaped_semicolons :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == ';' && _is_unescaped_at(s, i) {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	append(&out, s[start:])
	return out[:]
}

_index_unescaped_byte :: proc(s: string, needle: u8) -> int {
	for i := 0; i < len(s); i += 1 {
		if s[i] == needle && _is_unescaped_at(s, i) {
			return i
		}
	}
	return -1
}

// Escapes `\`, `;`, and `=` in `instance_overrides` names/values so literal delimiters round-trip safely.
vg_escape_override_token :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "\\;=") {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(0, len(s) + 8, allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' || c == ';' || c == '=' {
			strings.write_byte(&sb, '\\')
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

// Decodes `\\`, `\;`, and `\=` escapes while keeping legacy unescaped backslashes intact.
vg_unescape_override_token :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\\') < 0 {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			nxt := s[i + 1]
			if nxt == '\\' || nxt == ';' || nxt == '=' {
				strings.write_byte(&sb, nxt)
				i += 1
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

vg_apply_instance_overrides :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, overrides_str: string) {
	if g == nil || bb == nil || overrides_str == "" do return
	for pair in _split_unescaped_semicolons(overrides_str, context.temp_allocator) {
		kv := strings.trim_space(pair)
		if kv == "" do continue
		eq := _index_unescaped_byte(kv, '=')
		if eq <= 0 do continue
		vname := vg_unescape_override_token(strings.trim_space(kv[:eq]), context.temp_allocator)
		vval  := vg_unescape_override_token(strings.trim_space(kv[eq + 1:]), context.temp_allocator)
		vi := vg_find_var_index(g, vname)
		if vi < 0 || vi >= VG_MAX_VARS do continue
		#partial switch g.variables[vi].pin_type {
		case .Float:
			if f, ok := strconv.parse_f32(vval); ok do bb.slots[vi].val_f32 = f
		case .F64:
			if f, ok := strconv.parse_f64(vval); ok do bb.slots[vi].val_f64 = f
		case .Int:
			if iv, ok := strconv.parse_int(vval); ok do bb.slots[vi].val_int = i32(iv)
		case .Int64:
			if iv, ok := strconv.parse_i64(vval); ok do bb.slots[vi].val_i64 = iv
		case .U8:
			if uv, ok := strconv.parse_u64(vval); ok do bb.slots[vi].val_u8 = u8(clamp(uv, 0, 255))
		case .I8:
			if iv, ok := strconv.parse_i64(vval); ok do bb.slots[vi].val_i8 = i8(clamp(iv, -128, 127))
		case .U16:
			if uv, ok := strconv.parse_u64(vval); ok do bb.slots[vi].val_u16 = u16(clamp(uv, 0, 65535))
		case .I16:
			if iv, ok := strconv.parse_i64(vval); ok do bb.slots[vi].val_i16 = i16(clamp(iv, -32768, 32767))
		case .U32:
			if uv, ok := strconv.parse_u64(vval); ok do bb.slots[vi].val_u32 = u32(uv)
		case .U64:
			if uv, ok := strconv.parse_u64(vval); ok do bb.slots[vi].val_u64 = uv
		case .Enum_U8, .BitSet_U8:
			if uv, ok := strconv.parse_u64(vval); ok {
				bb.slots[vi].val_u8 = u8(clamp(uv, 0, 255))
			} else if g.variables[vi].pin_type == .Enum_U8 {
				if ed := vg_find_enum_decl(g, g.variables[vi].custom_type_name); ed != nil {
					for vname, eidx in ed.variants {
						if vname == vval { bb.slots[vi].val_u8 = u8(eidx); break }
					}
				}
			}
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
		if g.variables[vi].pin_type == .Float && vg_resolve_container_kind(g.variables[vi]) != .Single {
			seq := _vg_ensure_f32_seq_bb(g, bb, g.variables[vi].name)
			if seq != nil {
				trim_list := strings.trim(strings.trim_space(vval), "[]")
				context.allocator = runtime.default_allocator()
				clear(seq)
				for item in strings.split(trim_list, ",", context.temp_allocator) {
					ts := strings.trim_space(item)
					if ts == "" do continue
					if fv, fok := strconv.parse_f32(ts); fok {
						append(seq, fv)
					}
				}
			}
		}
	}
}

// Formats an updated `instance_overrides` string when editing an `👁 Instance Editable` variable in the Inspector!
vg_set_instance_override_value :: proc(existing: string, var_name: string, formatted_val: string, allocator := context.allocator) -> string {
	entries := make([dynamic]string, 0, 8, context.temp_allocator)
	replaced := false
	esc_key := vg_escape_override_token(var_name, context.temp_allocator)
	for pair in _split_unescaped_semicolons(existing, context.temp_allocator) {
		kv := strings.trim_space(pair)
		if kv == "" do continue
		eq := _index_unescaped_byte(kv, '=')
		if eq <= 0 do continue
		k := vg_unescape_override_token(strings.trim_space(kv[:eq]), context.temp_allocator)
		if k == var_name {
			if formatted_val != "" {
				esc_val := vg_escape_override_token(formatted_val, context.temp_allocator)
				append(&entries, fmt.tprintf("%s=%s", esc_key, esc_val))
			}
			replaced = true
		} else {
			append(&entries, kv)
		}
	}
	if !replaced && formatted_val != "" {
		esc_val := vg_escape_override_token(formatted_val, context.temp_allocator)
		append(&entries, fmt.tprintf("%s=%s", esc_key, esc_val))
	}
	return strings.join(entries[:], ";", allocator)
}

vg_get_instance_override_value :: proc(existing: string, var_name: string, allocator := context.temp_allocator) -> (val: string, found: bool) {
	for pair in _split_unescaped_semicolons(existing, context.temp_allocator) {
		kv := strings.trim_space(pair)
		if kv == "" do continue
		eq := _index_unescaped_byte(kv, '=')
		if eq <= 0 do continue
		k := vg_unescape_override_token(strings.trim_space(kv[:eq]), context.temp_allocator)
		if k == var_name {
			return vg_unescape_override_token(strings.trim_space(kv[eq + 1:]), allocator), true
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
		st.bb.last_exec_path  = make([dynamic]int, 0, 16)
		st.bb.var_blobs       = make(map[string][dynamic]u8, 4)
		st.bb.node_timers     = make(map[u32]VG_Timer_Entry, 4)
		st.bb.live_pin_values = make(map[u64]hot.Hot_Slot, 16)
		st.custom_delegates   = make(map[string][dynamic]_VS_Custom_Delegate_Listener, 4)
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

@(private = "file")
_bb_live_key :: #force_inline proc(uid, pin_idx: int) -> u64 {
	return (u64(u32(uid)) << 16) | u64(u16(pin_idx))
}

_bb_set_live_pin :: proc(bb: ^VG_Runtime_Blackboard, uid, pin_idx: int, slot: hot.Hot_Slot) {
	if bb == nil do return
	if bb.live_pin_values == nil {
		context.allocator = runtime.default_allocator()
		bb.live_pin_values = make(map[u64]hot.Hot_Slot, 16)
	}
	bb.live_pin_values[_bb_live_key(uid, pin_idx)] = slot
}

_bb_get_live_pin :: proc(bb: ^VG_Runtime_Blackboard, uid, pin_idx: int) -> (slot: hot.Hot_Slot, ok: bool) {
	if bb == nil || bb.live_pin_values == nil do return {}, false
	return bb.live_pin_values[_bb_live_key(uid, pin_idx)]
}

visual_script_get_entity_bb :: proc(tH: Transform_Handle) -> ^VG_Runtime_Blackboard {
	if !_vs_rt.initialized do return nil
	if st, ok := _vs_rt.entities[_entity_key(tH)]; ok && st != nil {
		return &st.bb
	}
	return nil
}

visual_script_get_live_pin_value :: proc(tH: Transform_Handle, node_uid, out_pin_idx: int) -> (hot.Hot_Slot, bool) {
	bb := visual_script_get_entity_bb(tH)
	if bb == nil do return {}, false
	return _bb_get_live_pin(bb, node_uid, out_pin_idx)
}

visual_script_reset_loop_fuse :: proc(tH: Transform_Handle) {
	if bb := visual_script_get_entity_bb(tH); bb != nil {
		bb.loop_fuse_tripped_uid = 0
	}
}

visual_script_report_loop_fuse :: proc(tH: Transform_Handle, node_uid: u32) {
	st := _get_or_create_entity_state(tH)
	st.bb.loop_fuse_tripped_uid = int(node_uid)
}

// Returns a direct addressable raw pointer (`^f32`, `^i32`, `^bool`, `^[3]f32`, `^u8`, ...) to per-entity
// Blueprint state variable `var_index`, allowing `On_Init`, `On_Tick`, AND bound `Input` / `Delegate`
// `@(hot_proc)` callbacks to read & mutate persistent `self.<var>` fields at native pointer speed!
_bb_slot_value_ptr :: proc(bb: ^VG_Runtime_Blackboard, var_index: int, fallback_pt: hot.Hot_Pin_Type = .Float) -> rawptr {
	if bb == nil || var_index < 0 || var_index >= VG_MAX_VARS do return nil
	s := &bb.slots[var_index]
	pt := s.pin_type != .Exec ? s.pin_type : fallback_pt
	#partial switch pt {
	case .Bool:       return &s.val_bool
	case .Int:        return &s.val_int
	case .Int64:      return &s.val_i64
	case .Float:      return &s.val_f32
	case .Vec2:       return &s.val_vec2
	case .Vec3:       return &s.val_vec3
	case .Vec4:       return &s.val_vec4
	case .Quat:       return &s.val_quat
	case .Entity:     return &s.val_ent
	case .Delegate:   return &s.val_delegate
	case .U8, .Enum_U8, .BitSet_U8: return &s.val_u8
	case .I8:         return &s.val_i8
	case .U16:        return &s.val_u16
	case .I16:        return &s.val_i16
	case .U32:        return &s.val_u32
	case .U64:        return &s.val_u64
	case .F64:        return &s.val_f64
	case .Struct_Val: return &s.val_bytes[0]
	case .String, .Asset: return &s.val_cstr
	case .Raw_Ptr:    return &s.val_ptr
	}
	return &s.val_f32
}

visual_script_get_entity_var_ptr :: proc(tH: Transform_Handle, var_index: int) -> rawptr {
	if var_index < 0 || var_index >= VG_MAX_VARS do return nil
	st := _get_or_create_entity_state(tH)
	return _bb_slot_value_ptr(&st.bb, var_index)
}

@(private = "file")
_vg_ensure_canary_blob_bb :: proc(bb: ^VG_Runtime_Blackboard, var_name: string, payload_bytes: int) -> []u8 {
	if bb == nil || var_name == "" do return nil
	sz := max(payload_bytes, 1)
	total := sz + VG_BLOB_TAIL_BYTES
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	if bb.var_blobs == nil {
		bb.var_blobs = make(map[string][dynamic]u8, 4)
	}
	buf, exists := bb.var_blobs[var_name]
	if !exists {
		buf = make([dynamic]u8, total)
		(cast(^u64)&buf[sz])^     = VG_BLOB_CANARY_TAIL
		(cast(^u64)&buf[sz + 8])^ = VG_BLOB_CANARY_HEAD ~ u64(sz)
		bb.var_blobs[strings.clone(var_name)] = buf
		return buf[0:sz]
	}
	old_sz := len(buf) > VG_BLOB_TAIL_BYTES ? len(buf) - VG_BLOB_TAIL_BYTES : len(buf)
	if len(buf) < total {
		if old_sz > 0 && old_sz + VG_BLOB_TAIL_BYTES <= len(buf) {
			mem.zero(&buf[old_sz], VG_BLOB_TAIL_BYTES)
		}
		resize(&buf, total)
		(cast(^u64)&buf[sz])^     = VG_BLOB_CANARY_TAIL
		(cast(^u64)&buf[sz + 8])^ = VG_BLOB_CANARY_HEAD ~ u64(sz)
		bb.var_blobs[var_name] = buf
		return buf[0:sz]
	}
	return buf[0:old_sz]
}

visual_script_get_entity_var_blob_ptr :: proc(tH: Transform_Handle, var_name: string, byte_size: int) -> rawptr {
	if var_name == "" do return nil
	st := _get_or_create_entity_state(tH)
	payload := _vg_ensure_canary_blob_bb(&st.bb, var_name, byte_size)
	return len(payload) > 0 ? rawptr(&payload[0]) : nil
}

visual_script_get_entity_var_ptr_raw :: proc(tH: Transform_Handle, var_name: string, pin_type: hot.Hot_Pin_Type) -> rawptr {
	if var_name == "" do return nil
	if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(tH)) {
		if _, r := transform_get_comp(tH, VisualScriptRunner); r != nil && r.graph_path != "" {
			if g := _get_or_load_disk_graph(r.graph_path); g != nil {
				if vi := vg_find_var_index(g, var_name); vi >= 0 && vi < VG_MAX_VARS {
					return visual_script_get_entity_var_ptr(tH, vi)
				}
			}
		}
	}
	// Headless / standalone Cartridge fallback: allocate named POD backing storage!
	blob_key := fmt.tprintf("__raw_%s", var_name)
	_ = pin_type
	return visual_script_get_entity_var_blob_ptr(tH, blob_key, 64)
}

@(private = "file")
_vg_ensure_f32_seq_bb :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, var_name: string) -> ^[dynamic]f32 {
	if bb == nil || var_name == "" do return nil
	context.allocator = runtime.default_allocator()
	if bb.var_f32_seqs == nil {
		bb.var_f32_seqs = make(map[string][dynamic]f32, 4)
	}
	if var_name in bb.var_f32_seqs {
		return &bb.var_f32_seqs[var_name]
	}
	seq := make([dynamic]f32, 0, 8, runtime.default_allocator())
	if g != nil {
		if vi := vg_find_var_index(g, var_name); vi >= 0 && vi < len(g.variables) {
			v := g.variables[vi]
			if len(v.default_f32_list) > 0 {
				resize(&seq, len(v.default_f32_list))
				copy(seq[:], v.default_f32_list[:])
			}
		}
	}
	key_c := strings.clone(var_name, runtime.default_allocator())
	bb.var_f32_seqs[key_c] = seq
	return &bb.var_f32_seqs[var_name]
}

visual_script_get_entity_var_f32_seq_ptr :: proc(tH: Transform_Handle, var_name: string) -> (data: ^f32, length: i32, capacity: i32) {
	if var_name == "" do return nil, 0, 0
	st := _get_or_create_entity_state(tH)
	var_g: ^Visual_Graph = nil
	if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(tH)) {
		if _, r := transform_get_comp(tH, VisualScriptRunner); r != nil && r.graph_path != "" {
			var_g = _get_or_load_disk_graph(r.graph_path)
		}
	}
	seq := _vg_ensure_f32_seq_bb(var_g, &st.bb, var_name)
	if seq == nil do return nil, 0, 0
	raw := (cast(^runtime.Raw_Dynamic_Array)seq)^
	return (^f32)(raw.data), i32(raw.len), i32(raw.cap)
}

visual_script_sync_entity_var_f32_seq :: proc(tH: Transform_Handle, var_name: string, data: ^f32, length: i32, capacity: i32) {
	if var_name == "" do return
	st := _get_or_create_entity_state(tH)
	seq := _vg_ensure_f32_seq_bb(nil, &st.bb, var_name)
	if seq == nil do return
	n := max(int(length), 0)
	// `capacity >= 0` signals `[dynamic]f32` allocated directly via `api.host_allocator`; update header without double-freeing!
	if capacity >= 0 {
		raw := cast(^runtime.Raw_Dynamic_Array)seq
		raw.data      = data
		raw.len       = n
		raw.cap       = max(int(capacity), n)
		raw.allocator = runtime.default_allocator()
		return
	}
	// `capacity < 0` signals a `[]f32` slice view (possibly reassigned to a temporary slice in user code).
	context.allocator = runtime.default_allocator()
	if data != raw_data(seq^) {
		resize(seq, n)
		if n > 0 && data != nil {
			src_sl := ([^]f32)(data)[:n]
			copy(seq^[:n], src_sl)
		}
	} else {
		raw := cast(^runtime.Raw_Dynamic_Array)seq
		raw.len = n
	}
}

@(private = "file")
_vg_raw_seq_reserve :: proc(entry: ^VG_Raw_Seq_Entry, min_cap: int) {
	if entry == nil || min_cap <= entry.capacity do return
	elem_sz := max(entry.elem_size, 1)
	elem_al := max(entry.elem_align, 8)
	new_cap := max(entry.capacity * 2, min_cap, 8)
	new_buf, err := mem.alloc(new_cap * elem_sz, elem_al, runtime.default_allocator())
	if err != nil || new_buf == nil do return
	if entry.data != nil && entry.length > 0 {
		mem.copy(new_buf, entry.data, entry.length * elem_sz)
	}
	if entry.owns_alloc && entry.data != nil {
		mem.free(entry.data, runtime.default_allocator())
	}
	entry.data       = new_buf
	entry.capacity   = new_cap
	entry.owns_alloc = true
}

@(private = "file")
_vg_raw_seq_elem_ptr :: #force_inline proc(entry: ^VG_Raw_Seq_Entry, idx: int) -> rawptr {
	if entry == nil || entry.data == nil || idx < 0 || idx >= entry.length do return nil
	return rawptr(uintptr(entry.data) + uintptr(idx * max(entry.elem_size, 1)))
}

@(private = "file")
_vg_raw_seq_append :: proc(entry: ^VG_Raw_Seq_Entry, src: rawptr) -> bool {
	if entry == nil do return false
	elem_sz := max(entry.elem_size, 1)
	if entry.length + 1 > entry.capacity || !entry.owns_alloc {
		_vg_raw_seq_reserve(entry, entry.length + 1)
	}
	if entry.data == nil || entry.length + 1 > entry.capacity do return false
	dst := rawptr(uintptr(entry.data) + uintptr(entry.length * elem_sz))
	if src != nil {
		mem.copy(dst, src, elem_sz)
	} else {
		mem.zero(dst, elem_sz)
	}
	entry.length += 1
	return true
}

@(private = "file")
_vg_ensure_seq_bb :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, var_name: string, elem_size, elem_align: int) -> ^VG_Raw_Seq_Entry {
	if bb == nil || var_name == "" do return nil
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	if bb.var_seqs == nil {
		bb.var_seqs = make(map[string]VG_Raw_Seq_Entry, 4)
	}
	if var_name in bb.var_seqs {
		ep := &bb.var_seqs[var_name]
		if elem_size > ep.elem_size do ep.elem_size = elem_size
		if elem_align > ep.elem_align do ep.elem_align = elem_align
		return ep
	}
	esz := max(elem_size, 1)
	eal := max(elem_align, 8)
	init_cap := 8
	init_len := 0
	if g != nil {
		if vi := vg_find_var_index(g, var_name); vi >= 0 && vi < len(g.variables) {
			v := g.variables[vi]
			if v.pin_type == .Float && len(v.default_f32_list) > 0 {
				init_len = len(v.default_f32_list)
				init_cap = max(init_len, 8)
			}
		}
	}
	buf, _ := mem.alloc(init_cap * esz, eal, runtime.default_allocator())
	if g != nil && init_len > 0 && buf != nil {
		if vi := vg_find_var_index(g, var_name); vi >= 0 && vi < len(g.variables) {
			v := g.variables[vi]
			if v.pin_type == .Float && len(v.default_f32_list) >= init_len && esz >= size_of(f32) {
				mem.copy(buf, raw_data(v.default_f32_list[:]), init_len * size_of(f32))
			}
		}
	}
	key_c := strings.clone(var_name)
	bb.var_seqs[key_c] = VG_Raw_Seq_Entry{
		data       = buf,
		length     = init_len,
		capacity   = init_cap,
		elem_size  = esz,
		elem_align = eal,
		owns_alloc = true,
	}
	return &bb.var_seqs[var_name]
}

visual_script_get_entity_var_seq_ptr :: proc(tH: Transform_Handle, var_name: string, elem_size, elem_align: i32) -> (data: rawptr, length: i32, capacity: i32) {
	if var_name == "" do return nil, 0, 0
	st := _get_or_create_entity_state(tH)
	var_g: ^Visual_Graph = nil
	if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(tH)) {
		if _, r := transform_get_comp(tH, VisualScriptRunner); r != nil && r.graph_path != "" {
			var_g = _get_or_load_disk_graph(r.graph_path)
		}
	}
	entry := _vg_ensure_seq_bb(var_g, &st.bb, var_name, int(elem_size), int(elem_align))
	if entry == nil do return nil, 0, 0
	return entry.data, i32(entry.length), i32(entry.capacity)
}

visual_script_sync_entity_var_seq :: proc(tH: Transform_Handle, var_name: string, data: rawptr, elem_size, elem_align, length, capacity: i32) {
	if var_name == "" do return
	st := _get_or_create_entity_state(tH)
	esz := max(int(elem_size), 1)
	eal := max(int(elem_align), 8)
	entry := _vg_ensure_seq_bb(nil, &st.bb, var_name, esz, eal)
	if entry == nil do return
	n := max(int(length), 0)
	// `capacity >= 0` signals `[dynamic]T` managed via `api.host_allocator`; adopt header in place!
	if capacity >= 0 {
		entry.data       = data
		entry.length     = n
		entry.capacity   = max(int(capacity), n)
		entry.elem_size  = esz
		entry.elem_align = eal
		entry.owns_alloc = (data != nil)
		return
	}
	// `capacity < 0` signals a `[]T` slice view (possibly reassigned to a temporary slice); clone into owned buffer!
	if data != entry.data {
		if n > 0 {
			_vg_raw_seq_reserve(entry, n)
			if entry.data != nil && data != nil {
				mem.copy(entry.data, data, n * esz)
			}
		}
		entry.length = n
	} else {
		entry.length = min(n, entry.capacity)
	}
}

// Verifies per-entity blackboard heap canaries and sanitizes NaN/Inf Transform fields written by scripts.
visual_script_verify_and_repair_entity :: proc(
	tH:        Transform_Handle,
	pre_pos:   [3]f32,
	pre_rot:   [4]f32,
	pre_scale: [3]f32,
) -> (corrupted_var: string, nan_repaired: bool) {
	if bb := visual_script_get_entity_bb(tH); bb != nil && bb.var_blobs != nil {
		for k, &buf in bb.var_blobs {
			if len(buf) < VG_BLOB_TAIL_BYTES + 1 do continue
			clean_len := len(buf) - VG_BLOB_TAIL_BYTES
			tail := (cast(^u64)&buf[clean_len])^
			tag  := (cast(^u64)&buf[clean_len + 8])^
			if tail != VG_BLOB_CANARY_TAIL || tag != (VG_BLOB_CANARY_HEAD ~ u64(clean_len)) {
				// Repair smashed trailing canary + clear poisoned payload so subsequent frames stay memory-safe
				mem.zero(&buf[0], clean_len)
				(cast(^u64)&buf[clean_len])^     = VG_BLOB_CANARY_TAIL
				(cast(^u64)&buf[clean_len + 8])^ = VG_BLOB_CANARY_HEAD ~ u64(clean_len)
				corrupted_var = strings.clone(k, context.temp_allocator)
				break
			}
		}
	}
	if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(tH)) {
		if t := pool_get(&w.transforms, Handle(tH)); t != nil {
			pos_bad := math.is_nan(t.position.x) || math.is_nan(t.position.y) || math.is_nan(t.position.z) || math.is_inf(t.position.x) || math.is_inf(t.position.y) || math.is_inf(t.position.z)
			scl_bad := math.is_nan(t.scale.x) || math.is_nan(t.scale.y) || math.is_nan(t.scale.z) || math.is_inf(t.scale.x) || math.is_inf(t.scale.y) || math.is_inf(t.scale.z)
			rq := t.rotation
			rot_bad := math.is_nan(rq.x) || math.is_nan(rq.y) || math.is_nan(rq.z) || math.is_nan(rq.w) || math.is_inf(rq.x) || math.is_inf(rq.y) || math.is_inf(rq.z) || math.is_inf(rq.w)
			if pos_bad || scl_bad || rot_bad {
				if pos_bad do t.position = pre_pos
				if scl_bad do t.scale    = pre_scale
				if rot_bad do t.rotation = pre_rot
				nan_repaired = true
			}
		}
	}
	return corrupted_var, nan_repaired
}

visual_script_timer_step_runtime :: proc(
	tH:          Transform_Handle,
	node_uid:    u32,
	duration:    f32,
	dt:          f32,
	reset:       bool,
	is_cooldown: bool,
) -> (ready: bool, rem: f32) {
	st := _get_or_create_entity_state(tH)
	if st.bb.node_timers == nil {
		context.allocator = runtime.default_allocator()
		st.bb.node_timers = make(map[u32]VG_Timer_Entry, 4)
	}
	dur := max(duration, f32(0.0))
	if is_cooldown {
		if reset {
			delete_key(&st.bb.node_timers, node_uid)
			return true, f32(0.0)
		}
		entry, exists := st.bb.node_timers[node_uid]
		if exists && entry.remaining > 0.0 && (!_vs_rt.inside_runners_tick || entry.last_tick_epoch != _vs_rt.tick_epoch) {
			entry.remaining = max(entry.remaining - dt, f32(0.0))
			entry.last_tick_epoch = _vs_rt.tick_epoch
			st.bb.node_timers[node_uid] = entry
		}
		if !exists || entry.remaining <= 0.0 {
			st.bb.node_timers[node_uid] = VG_Timer_Entry{
				remaining       = dur,
				is_cooldown     = true,
				last_tick_epoch = _vs_rt.tick_epoch,
			}
			return true, dur
		}
		return false, entry.remaining
	}

	// Delay Timer
	entry, exists := st.bb.node_timers[node_uid]
	if !exists || reset {
		entry = VG_Timer_Entry{
			remaining       = dur,
			is_cooldown     = false,
			last_tick_epoch = _vs_rt.tick_epoch,
		}
		if reset {
			st.bb.node_timers[node_uid] = entry
			return dur <= 0.0, entry.remaining
		}
		entry.last_tick_epoch = 0
	}
	if entry.remaining > 0.0 && (!_vs_rt.inside_runners_tick || entry.last_tick_epoch != _vs_rt.tick_epoch) {
		entry.remaining = max(entry.remaining - dt, f32(0.0))
		entry.last_tick_epoch = _vs_rt.tick_epoch
	}
	st.bb.node_timers[node_uid] = entry
	return entry.remaining <= 0.0, entry.remaining
}

visual_script_spawn_prefab_runtime :: proc(prefab_guid_str: string, world_pos: [3]f32, world_rot: [4]f32) -> Transform_Handle {
	w := ctx_world()
	if w == nil do return {}
	parent: Transform_Handle
	if sc := sm_scene_get_active(); sc != nil {
		parent = Transform_Handle(sc.root.handle)
	}
	res: Transform_Handle
	if prefab_guid_str != "" && prefab_guid_str != "__empty_entity__" {
		guid: Asset_GUID
		has_guid := false
		if parsed, perr := uuid.read(prefab_guid_str); perr == nil {
			guid = Asset_GUID(parsed)
			has_guid = true
		} else if found, gok := asset_db_get_guid(prefab_guid_str); gok {
			guid = Asset_GUID(found)
			has_guid = true
		}
		if has_guid && parent != {} {
			res = scene_instantiate_guid(guid, parent)
		}
	}
	if res == {} && (prefab_guid_str == "" || prefab_guid_str == "__empty_entity__") {
		res = transform_new("SpawnedEntity", parent)
	}
	if res != {} && pool_valid(&w.transforms, Handle(res)) {
		transform_set_world_position(res, world_pos)
		if world_rot != ([4]f32{0, 0, 0, 0}) {
			transform_set_world_rotation(res, world_rot)
		}
	}
	return res
}

visual_script_destroy_entity_runtime :: proc(target: Transform_Handle) {
	if target == {} do return
	if w := ctx_world(); w != nil && pool_valid(&w.transforms, Handle(target)) {
		transform_destroy(target)
	}
}

visual_script_ai_move_runtime :: proc(tH: Transform_Handle, goal_pos: [3]f32, speed_override: f32) -> bool {
	w := ctx_world()
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return false
	if _, ag := transform_get_comp(tH, NavMeshAgent); ag != nil {
		if speed_override > 0 do ag.speed = speed_override
		return nav_agent_set_destination(w, tH, goal_pos)
	}
	return false
}

visual_script_ai_arrived_runtime :: proc(tH: Transform_Handle, accept_radius: f32) -> bool {
	w := ctx_world()
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return false
	if nav_agent_has_arrived(w, tH) do return true
	if _, ag := transform_get_comp(tH, NavMeshAgent); ag != nil && ag.has_destination {
		tw := transform_world(tH)
		return linalg.distance(tw.position, ag.target_position) <= max(accept_radius, ag.stopping_distance)
	}
	return false
}

visual_script_physics_raycast_runtime :: proc(ignore_self: Transform_Handle, origin, dir: [3]f32, max_dist: f32, channel_mask: u32) -> hot.Hot_Raycast_Hit {
	if _vs_physics_bridge.raycast_masked != nil {
		hit, _ := _vs_physics_bridge.raycast_masked(origin, dir, max_dist, channel_mask, ignore_self)
		return hit
	}
	return {}
}

visual_script_physics_overlap_sphere_runtime :: proc(ignore_self: Transform_Handle, center: [3]f32, radius: f32, channel_mask: u32) -> (i32, Transform_Handle) {
	if _vs_physics_bridge.overlap_sphere != nil {
		return _vs_physics_bridge.overlap_sphere(center, radius, channel_mask, ignore_self)
	}
	return 0, {}
}

visual_script_physics_add_impulse_runtime :: proc(target: Transform_Handle, impulse: [3]f32, is_vel_change: bool) {
	if _vs_physics_bridge.add_impulse != nil {
		_vs_physics_bridge.add_impulse(target, impulse, is_vel_change)
	}
}

visual_script_audio_play_3d_runtime :: proc(tH: Transform_Handle, cue_str: string, world_pos: [3]f32, volume: f32, pitch: f32) {
	if _vs_audio_bridge.play_spatial_3d != nil {
		_vs_audio_bridge.play_spatial_3d(tH, cue_str, world_pos, volume, pitch)
	}
}

visual_script_audio_bus_send_runtime :: proc(bus_name: string, send_level: f32, lowpass_hz: f32) {
	if _vs_audio_bridge.bus_send != nil {
		_vs_audio_bridge.bus_send(bus_name, send_level, lowpass_hz)
	}
}

visual_script_vfx_spawn_runtime :: proc(tH: Transform_Handle, vfx_str: string, spawn_rate: f32, burst_count: i32) {
	if _vs_vfx_bridge.emitter_spawn != nil {
		_vs_vfx_bridge.emitter_spawn(tH, vfx_str, spawn_rate, burst_count)
	}
}

visual_script_anim_ik_target_runtime :: proc(tH: Transform_Handle, effector_name: string, world_target: [3]f32, weight: f32) {
	if _vs_anim_bridge.set_ik_target != nil {
		_vs_anim_bridge.set_ik_target(tH, effector_name, world_target, weight)
	}
}

visual_script_csg_stamp_runtime :: proc(world_pos: [3]f32, radius: f32, impulse: f32, cut_mat_str: string) -> i32 {
	if _vs_csg_bridge.brush_stamp != nil {
		return _vs_csg_bridge.brush_stamp(world_pos, radius, impulse, cut_mat_str)
	}
	return 0
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

vg_destroy_blackboard :: proc(bb: ^VG_Runtime_Blackboard) {
	if bb == nil do return
	context.allocator = runtime.default_allocator()
	delete(bb.last_exec_path)
	for k, v in bb.var_blobs {
		delete(k)
		delete(v)
	}
	delete(bb.var_blobs)
	for k, v in bb.var_f32_seqs {
		delete(k)
		delete(v)
	}
	delete(bb.var_f32_seqs)
	for k, entry in bb.var_seqs {
		delete(k)
		if entry.owns_alloc && entry.data != nil {
			mem.free(entry.data, runtime.default_allocator())
		}
	}
	delete(bb.var_seqs)
	delete(bb.node_timers)
	delete(bb.live_pin_values)
	bb^ = {}
}

@(private = "file")
_free_entity_state :: proc(st: ^_VS_Entity_State) {
	if st == nil do return
	context.allocator = runtime.default_allocator()
	vg_destroy_blackboard(&st.bb)
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

visual_script_destroy_entity_state :: proc(tH: Transform_Handle) {
	if !_vs_rt.initialized do return
	visual_script_unbind_all_for_entity(tH)
	ek := _entity_key(tH)
	if st, ok := _vs_rt.entities[ek]; ok && st != nil {
		context.allocator = runtime.default_allocator()
		delete_key(&_vs_rt.entities, ek)
		_free_entity_state(st)
	}
}

// Resets all runtime Blueprint bindings & per-entity Blackboards when Play/Simulate stops!
@(phase={key=Phase.ExitingPlayMode, order=0})
visual_script_exiting_play_mode :: proc() {
	visual_script_reset_runtime_state()
}

visual_script_reset_runtime_state :: proc() {
	hot_cartridge_clear_faults()
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
		_free_entity_state(st)
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
	_vs_rt.tick_epoch += 1
	_vs_rt.inside_runners_tick = true
	defer _vs_rt.inside_runners_tick = false

	// 0. Advance active Blueprint Delay & Cooldown timers ONCE per tick frame.
	for _, st in _vs_rt.entities {
		if st == nil || st.bb.node_timers == nil do continue
		for _, &entry in st.bb.node_timers {
			if entry.remaining > 0.0 && entry.last_tick_epoch != _vs_rt.tick_epoch {
				entry.remaining = max(entry.remaining - dt, f32(0.0))
				entry.last_tick_epoch = _vs_rt.tick_epoch
			}
		}
	}

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

	// 1b. Poll Physics trigger / contact begin events for `.Event_On_Trigger`
	if _vs_physics_bridge.poll_triggers != nil {
		hits := _vs_physics_bridge.poll_triggers(context.temp_allocator)
		for h in hits {
			if h.self_entity == {} || !pool_valid(&w.transforms, Handle(h.self_entity)) do continue
			if _, r := transform_get_comp(h.self_entity, VisualScriptRunner); r != nil && r.enabled {
				st := _get_or_create_entity_state(h.self_entity, nil, r)
				st.bb.trigger_other_entity = h.other_entity
				trig_sym := fmt.tprintf("%s__on_trigger", r.compiled_proc_name)
				if r.compiled_proc_name != "" && hot_proc_exists(trig_sym) {
					frame: hot.Hot_Call_Frame
					frame.inputs[0] = {pin_type = .Entity, val_ent = transform_to_hot_entity(h.other_entity)}
					frame.input_count = 1
					hot_proc_invoke(trig_sym, h.self_entity, dt, &frame)
				} else if g_disk := _get_or_load_disk_graph(r.graph_path); g_disk != nil {
					vg_eval_event_live(g_disk, &st.bb, h.self_entity, dt, .Event_On_Trigger)
				}
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
	.Exec       = "exec",
	.Bool       = "bool",
	.Int        = "i32",
	.Float      = "f32",
	.Vec3       = "[3]f32",
	.Quat       = "[4]f32",
	.Entity     = "hot.Hot_Entity",
	.Delegate   = "hot.Hot_Delegate",
	.Vec2       = "[2]f32",
	.Vec4       = "[4]f32",
	.Int64      = "i64",
	.String     = "cstring",
	.Asset      = "cstring",
	.U8         = "u8",
	.I8         = "i8",
	.U16        = "u16",
	.I16        = "i16",
	.U32        = "u32",
	.U64        = "u64",
	.F64        = "f64",
	.Enum_U8    = "u8",
	.BitSet_U8  = "u8",
	.Struct_Val = "rawptr",
	.Raw_Ptr    = "rawptr",
}

@(rodata)
_PIN_ODIN_ARRAY_TYPE := [hot.Hot_Pin_Type]string{
	.Exec       = "exec",
	.Bool       = "[8]bool",
	.Int        = "[8]i32",
	.Float      = "[8]f32",
	.Vec3       = "[8][3]f32",
	.Quat       = "[8][4]f32",
	.Entity     = "[8]hot.Hot_Entity",
	.Delegate   = "hot.Hot_Delegate",
	.Vec2       = "[8][2]f32",
	.Vec4       = "[8][4]f32",
	.Int64      = "[8]i64",
	.String     = "[8]cstring",
	.Asset      = "[8]cstring",
	.U8         = "[8]u8",
	.I8         = "[8]i8",
	.U16        = "[8]u16",
	.I16        = "[8]i16",
	.U32        = "[8]u32",
	.U64        = "[8]u64",
	.F64        = "[8]f64",
	.Enum_U8    = "[8]u8",
	.BitSet_U8  = "[8]u8",
	.Struct_Val = "[8]rawptr",
	.Raw_Ptr    = "[8]rawptr",
}

vg_pin_odin_type :: proc(pt: hot.Hot_Pin_Type, is_array: bool = false) -> string {
	if is_array do return _PIN_ODIN_ARRAY_TYPE[pt]
	return _PIN_ODIN_SCALAR_TYPE[pt]
}

vg_sanitize_bp_token :: proc(raw: string, allocator := context.temp_allocator) -> string {
	if raw == "" do return strings.clone("raw", allocator)
	switch raw {
	case "[2]f32": return strings.clone("Vec2", allocator)
	case "[3]f32": return strings.clone("Vec3", allocator)
	case "[4]f32": return strings.clone("Vec4", allocator)
	}
	b := strings.builder_make(0, len(raw), allocator)
	for i in 0 ..< len(raw) {
		ch := raw[i]
		is_ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
		strings.write_byte(&b, is_ok ? ch : '_')
	}
	return strings.to_string(b)
}

vg_find_enum_decl :: proc(g: ^Visual_Graph, name: string) -> ^VG_Enum_Decl {
	if g == nil || name == "" do return nil
	for &e in g.enums {
		if e.name == name || (e.bitset_name != "" && e.bitset_name == name) do return &e
	}
	return nil
}

vg_find_struct_decl :: proc(g: ^Visual_Graph, name: string) -> ^VG_Struct_Decl {
	if g == nil || name == "" do return nil
	for &s in g.structs {
		if s.name == name do return &s
	}
	return nil
}

VG_Struct_Field_Layout :: struct {
	name:        string,
	pin_type:    hot.Hot_Pin_Type,
	custom_type: string,
	offset:      int,
	size:        int,
	align:       int,
}

vg_scalar_type_size :: proc(g: ^Visual_Graph, pt: hot.Hot_Pin_Type, custom_type: string = "", depth: int = 0) -> (size: int, align: int) {
	switch pt {
	case .Exec:       return 0, 1
	case .Bool, .U8, .I8, .Enum_U8, .BitSet_U8: return 1, 1
	case .U16, .I16:  return 2, 2
	case .Int, .U32, .Float: return 4, 4
	case .Int64, .U64, .F64: return 8, 8
	case .Vec2:       return 8, 4
	case .Vec3:       return 12, 4
	case .Vec4, .Quat:return 16, 4
	case .Entity:     return size_of(hot.Hot_Entity), align_of(hot.Hot_Entity)
	case .Delegate:   return size_of(hot.Hot_Delegate), align_of(hot.Hot_Delegate)
	case .String, .Asset: return size_of(cstring), align_of(cstring)
	case .Raw_Ptr:    return size_of(rawptr), align_of(rawptr)
	case .Struct_Val:
		if depth >= 4 || g == nil || custom_type == "" do return 16, 4
		_, total_sz, total_al := vg_struct_layout(g, custom_type, context.temp_allocator, depth + 1)
		return max(total_sz, 1), max(total_al, 1)
	}
	return 4, 4
}

vg_struct_layout :: proc(
	g:           ^Visual_Graph,
	struct_name: string,
	allocator := context.temp_allocator,
	depth:       int = 0,
) -> (fields: []VG_Struct_Field_Layout, total_size: int, total_align: int) {
	if g == nil || struct_name == "" || depth >= 4 do return nil, 0, 1
	sd := vg_find_struct_decl(g, struct_name)
	if sd == nil do return nil, 0, 1

	out := make([dynamic]VG_Struct_Field_Layout, 0, len(sd.fields) + 4, allocator)
	cur_off := 0
	max_align := 1

	if sd.using_parent_name != "" && sd.using_parent_name != struct_name {
		p_fields, p_size, p_align := vg_struct_layout(g, sd.using_parent_name, allocator, depth + 1)
		for pf in p_fields {
			append(&out, pf)
		}
		cur_off = p_size
		max_align = max(max_align, p_align)
	}

	for f in sd.fields {
		f_sz, f_al := vg_scalar_type_size(g, f.pin_type, f.custom_type, depth + 1)
		f_al = max(f_al, 1)
		cur_off = (cur_off + f_al - 1) &~ (f_al - 1)
		append(&out, VG_Struct_Field_Layout{
			name        = f.name,
			pin_type    = f.pin_type,
			custom_type = f.custom_type,
			offset      = cur_off,
			size        = f_sz,
			align       = f_al,
		})
		cur_off += f_sz
		max_align = max(max_align, f_al)
	}

	aligned_total := cur_off == 0 ? 0 : ((cur_off + max_align - 1) &~ (max_align - 1))
	return out[:], aligned_total, max_align
}

vg_bounded_array_count_offset :: proc(g: ^Visual_Graph, v: VG_Var_Decl) -> int {
	elem_sz, _ := vg_scalar_type_size(g, v.pin_type, v.custom_type_name)
	cnt := v.array_count > 0 ? v.array_count : 8
	data_bytes := cnt * max(elem_sz, 1)
	return (data_bytes + 3) &~ 3
}

vg_var_byte_size :: proc(g: ^Visual_Graph, v: VG_Var_Decl) -> int {
	elem_sz, elem_al := vg_scalar_type_size(g, v.pin_type, v.custom_type_name)
	elem_sz = max(elem_sz, 1)
	elem_al = max(elem_al, 1)
	if !v.is_array do return elem_sz
	cnt := v.array_count > 0 ? v.array_count : 8
	if v.array_is_bounded {
		cnt_off := vg_bounded_array_count_offset(g, v)
		st_al := max(elem_al, 4)
		return ((cnt_off + 4) + st_al - 1) &~ (st_al - 1)
	}
	return cnt * elem_sz
}

vg_resolve_container_kind :: #force_inline proc(v: VG_Var_Decl) -> VG_Container_Kind {
	if v.container_kind != .Single do return v.container_kind
	if v.is_array {
		return v.array_is_bounded ? .Bounded_Array : .Fixed_Array
	}
	return .Single
}

vg_pin_container_kind :: #force_inline proc(p: VG_Pin_Def) -> VG_Container_Kind {
	if p.container_kind != .Single do return p.container_kind
	return p.is_array ? .Fixed_Array : .Single
}

vg_var_odin_type_ex :: proc(g: ^Visual_Graph, v: VG_Var_Decl, allocator := context.temp_allocator) -> string {
	base := vg_pin_odin_type(v.pin_type, false)
	if v.pin_type == .Enum_U8 && v.custom_type_name != "" {
		base = v.custom_type_name
	} else if v.pin_type == .BitSet_U8 && v.custom_type_name != "" {
		if ed := vg_find_enum_decl(g, v.custom_type_name); ed != nil {
			if ed.bitset_name != "" {
				base = ed.bitset_name
			} else {
				base = fmt.tprintf("bit_set[%s; u8]", ed.name)
			}
		} else {
			base = v.custom_type_name
		}
	} else if v.pin_type == .Struct_Val && v.custom_type_name != "" {
		base = v.custom_type_name
	}
	ck := vg_resolve_container_kind(v)
	switch ck {
	case .Single:
		return strings.clone(base, allocator)
	case .Slice:
		return fmt.aprintf("[]%s", base, allocator = allocator)
	case .Dynamic_Array:
		return fmt.aprintf("[dynamic]%s", base, allocator = allocator)
	case .Bounded_Array:
		cnt := v.array_count > 0 ? v.array_count : 8
		return fmt.aprintf("BP_Bounded_%s_%d", vg_sanitize_bp_token(base, context.temp_allocator), cnt, allocator = allocator)
	case .Fixed_Array:
		cnt := v.array_count > 0 ? v.array_count : 8
		if v.array_count <= 0 && v.pin_type not_in (bit_set[hot.Hot_Pin_Type]{.Enum_U8, .BitSet_U8, .Struct_Val}) {
			return strings.clone(vg_pin_odin_type(v.pin_type, true), allocator)
		}
		return fmt.aprintf("[%d]%s", cnt, base, allocator = allocator)
	}
	return strings.clone(base, allocator)
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

_vg_destroy_pin_strings :: proc(p: ^VG_Pin_Def) {
	delete(p.name)
	delete(p.default_str)
	delete(p.custom_type_name)
	delete(p.split_parent_name)
	delete(p.split_field_name)
}

vg_destroy_node :: proc(n: ^VG_Node) {
	delete(n.title)
	delete(n.owner_proc)
	delete(n.var_name)
	delete(n.hot_proc_target)
	delete(n.odin_body)
	delete(n.action_name)
	delete(n.delegate_name)
	delete(n.target_var_or_type)
	for &p in n.inputs  do _vg_destroy_pin_strings(&p)
	for &p in n.outputs do _vg_destroy_pin_strings(&p)
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
	for &e in g.enums {
		delete(e.name)
		delete(e.bitset_name)
		for v in e.variants do delete(v)
		delete(e.variants)
	}
	delete(g.enums)
	for &s in g.structs {
		delete(s.name)
		delete(s.using_parent_name)
		for &f in s.fields {
			delete(f.name)
			delete(f.custom_type)
		}
		delete(s.fields)
	}
	delete(g.structs)
	for v in g.variables {
		delete(v.name)
		delete(v.default_str)
		delete(v.custom_type_name)
		delete(v.category)
		delete(v.tooltip_text)
		delete(v.default_f32_list)
	}
	delete(g.variables)
	for &n in g.nodes do vg_destroy_node(&n)
	delete(g.nodes)
	delete(g.wires)
	g^ = {}
}

@(private = "file")
_vg_clone_pin :: proc(p: ^VG_Pin_Def, allocator: runtime.Allocator) -> VG_Pin_Def {
	out := p^
	out.name              = p.name != "" ? strings.clone(p.name, allocator) : ""
	out.default_str       = p.default_str != "" ? strings.clone(p.default_str, allocator) : ""
	out.custom_type_name  = p.custom_type_name != "" ? strings.clone(p.custom_type_name, allocator) : ""
	out.split_parent_name = p.split_parent_name != "" ? strings.clone(p.split_parent_name, allocator) : ""
	out.split_field_name  = p.split_field_name != "" ? strings.clone(p.split_field_name, allocator) : ""
	return out
}

@(private = "file")
_vg_pins_equal :: proc(a, b: []VG_Pin_Def) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		pa, pb := a[i], b[i]
		if pa.pin_type != pb.pin_type || pa.pass_mode != pb.pass_mode || pa.is_addressable != pb.is_addressable || pa.is_array != pb.is_array || pa.container_kind != pb.container_kind {
			return false
		}
		if pa.default_f32 != pb.default_f32 || pa.default_int != pb.default_int || pa.default_i64 != pb.default_i64 || pa.default_u64 != pb.default_u64 || pa.default_f64 != pb.default_f64 || pa.default_bool != pb.default_bool {
			return false
		}
		if pa.default_vec2 != pb.default_vec2 || pa.default_vec3 != pb.default_vec3 || pa.default_vec4 != pb.default_vec4 || pa.split_expanded != pb.split_expanded {
			return false
		}
		if pa.name != pb.name || pa.default_str != pb.default_str || pa.custom_type_name != pb.custom_type_name || pa.split_parent_name != pb.split_parent_name || pa.split_field_name != pb.split_field_name {
			return false
		}
	}
	return true
}

vg_clone_graph :: proc(src: ^Visual_Graph, allocator := context.allocator) -> Visual_Graph {
	if src == nil do return {}
	dst := Visual_Graph{
		name           = src.name != "" ? strings.clone(src.name, allocator) : "",
		domain         = src.domain,
		package_target = src.package_target != "" ? strings.clone(src.package_target, allocator) : "",
		next_uid       = src.next_uid,
		using_spaces   = make([dynamic]string, len(src.using_spaces), allocator),
		delegates      = make([dynamic]string, len(src.delegates), allocator),
		enums          = make([dynamic]VG_Enum_Decl, len(src.enums), allocator),
		structs        = make([dynamic]VG_Struct_Decl, len(src.structs), allocator),
		variables      = make([dynamic]VG_Var_Decl, len(src.variables), allocator),
		nodes          = make([dynamic]VG_Node, len(src.nodes), allocator),
		wires          = make([dynamic]VG_Wire, len(src.wires), allocator),
	}
	for s, i in src.using_spaces {
		dst.using_spaces[i] = s != "" ? strings.clone(s, allocator) : ""
	}
	for d, i in src.delegates {
		dst.delegates[i] = d != "" ? strings.clone(d, allocator) : ""
	}
	for &e, ei in src.enums {
		ce := VG_Enum_Decl{
			name        = e.name != "" ? strings.clone(e.name, allocator) : "",
			variants    = make([dynamic]string, len(e.variants), allocator),
			has_bitset  = e.has_bitset,
			bitset_name = e.bitset_name != "" ? strings.clone(e.bitset_name, allocator) : "",
		}
		for v, vi in e.variants {
			ce.variants[vi] = v != "" ? strings.clone(v, allocator) : ""
		}
		dst.enums[ei] = ce
	}
	for &s, si in src.structs {
		cs := VG_Struct_Decl{
			name              = s.name != "" ? strings.clone(s.name, allocator) : "",
			using_parent_name = s.using_parent_name != "" ? strings.clone(s.using_parent_name, allocator) : "",
			fields            = make([dynamic]VG_Struct_Field, len(s.fields), allocator),
		}
		for &f, fi in s.fields {
			cf := f
			cf.name        = f.name != "" ? strings.clone(f.name, allocator) : ""
			cf.custom_type = f.custom_type != "" ? strings.clone(f.custom_type, allocator) : ""
			cs.fields[fi] = cf
		}
		dst.structs[si] = cs
	}
	for &v, vi in src.variables {
		cv := v
		cv.name             = v.name != "" ? strings.clone(v.name, allocator) : ""
		cv.default_str      = v.default_str != "" ? strings.clone(v.default_str, allocator) : ""
		cv.custom_type_name = v.custom_type_name != "" ? strings.clone(v.custom_type_name, allocator) : ""
		cv.category         = v.category != "" ? strings.clone(v.category, allocator) : ""
		cv.tooltip_text     = v.tooltip_text != "" ? strings.clone(v.tooltip_text, allocator) : ""
		if len(v.default_f32_list) > 0 {
			cv.default_f32_list = make([dynamic]f32, len(v.default_f32_list), allocator)
			copy(cv.default_f32_list[:], v.default_f32_list[:])
		} else {
			cv.default_f32_list = nil
		}
		dst.variables[vi] = cv
	}
	for &n, ni in src.nodes {
		cn := n
		cn.title              = n.title != "" ? strings.clone(n.title, allocator) : ""
		cn.owner_proc         = n.owner_proc != "" ? strings.clone(n.owner_proc, allocator) : ""
		cn.var_name           = n.var_name != "" ? strings.clone(n.var_name, allocator) : ""
		cn.hot_proc_target    = n.hot_proc_target != "" ? strings.clone(n.hot_proc_target, allocator) : ""
		cn.odin_body          = n.odin_body != "" ? strings.clone(n.odin_body, allocator) : ""
		cn.action_name        = n.action_name != "" ? strings.clone(n.action_name, allocator) : ""
		cn.delegate_name      = n.delegate_name != "" ? strings.clone(n.delegate_name, allocator) : ""
		cn.target_var_or_type = n.target_var_or_type != "" ? strings.clone(n.target_var_or_type, allocator) : ""
		cn.inputs             = make([dynamic]VG_Pin_Def, len(n.inputs), allocator)
		cn.outputs            = make([dynamic]VG_Pin_Def, len(n.outputs), allocator)
		for &p, pi in n.inputs  do cn.inputs[pi] = _vg_clone_pin(&p, allocator)
		for &p, pi in n.outputs do cn.outputs[pi] = _vg_clone_pin(&p, allocator)
		dst.nodes[ni] = cn
	}
	copy(dst.wires[:], src.wires[:])
	return dst
}

vg_graphs_equal :: proc(a, b: ^Visual_Graph) -> bool {
	if a == nil || b == nil do return a == b
	if a.domain != b.domain || a.next_uid != b.next_uid || a.name != b.name || a.package_target != b.package_target {
		return false
	}
	if len(a.using_spaces) != len(b.using_spaces) || len(a.delegates) != len(b.delegates) || len(a.enums) != len(b.enums) || len(a.structs) != len(b.structs) || len(a.variables) != len(b.variables) || len(a.nodes) != len(b.nodes) || len(a.wires) != len(b.wires) {
		return false
	}
	for i in 0 ..< len(a.using_spaces) do if a.using_spaces[i] != b.using_spaces[i] do return false
	for i in 0 ..< len(a.delegates)    do if a.delegates[i] != b.delegates[i]       do return false
	for i in 0 ..< len(a.enums) {
		ea, eb := &a.enums[i], &b.enums[i]
		if ea.name != eb.name || ea.has_bitset != eb.has_bitset || ea.bitset_name != eb.bitset_name || len(ea.variants) != len(eb.variants) do return false
		for vi in 0 ..< len(ea.variants) do if ea.variants[vi] != eb.variants[vi] do return false
	}
	for i in 0 ..< len(a.structs) {
		sa, sb := &a.structs[i], &b.structs[i]
		if sa.name != sb.name || sa.using_parent_name != sb.using_parent_name || len(sa.fields) != len(sb.fields) do return false
		for fi in 0 ..< len(sa.fields) {
			fa, fb := sa.fields[fi], sb.fields[fi]
			if fa.name != fb.name || fa.pin_type != fb.pin_type || fa.custom_type != fb.custom_type || fa.default_f32 != fb.default_f32 || fa.default_int != fb.default_int || fa.default_u64 != fb.default_u64 || fa.default_f64 != fb.default_f64 || fa.default_bool != fb.default_bool || fa.default_vec2 != fb.default_vec2 || fa.default_vec3 != fb.default_vec3 || fa.default_vec4 != fb.default_vec4 {
				return false
			}
		}
	}
	for i in 0 ..< len(a.variables) {
		va, vb := &a.variables[i], &b.variables[i]
		if va.pin_type != vb.pin_type || va.is_array != vb.is_array || vg_resolve_container_kind(va^) != vg_resolve_container_kind(vb^) || va.array_count != vb.array_count || va.array_is_bounded != vb.array_is_bounded || va.instance_editable != vb.instance_editable || va.slider_min != vb.slider_min || va.slider_max != vb.slider_max {
			return false
		}
		if va.default_f32 != vb.default_f32 || va.default_int != vb.default_int || va.default_i64 != vb.default_i64 || va.default_u64 != vb.default_u64 || va.default_f64 != vb.default_f64 || va.default_bool != vb.default_bool || va.default_vec2 != vb.default_vec2 || va.default_vec3 != vb.default_vec3 || va.default_vec4 != vb.default_vec4 {
			return false
		}
		if va.name != vb.name || va.default_str != vb.default_str || va.custom_type_name != vb.custom_type_name || va.category != vb.category || va.tooltip_text != vb.tooltip_text {
			return false
		}
		if len(va.default_f32_list) != len(vb.default_f32_list) do return false
		for li in 0 ..< len(va.default_f32_list) do if va.default_f32_list[li] != vb.default_f32_list[li] do return false
	}
	for i in 0 ..< len(a.nodes) {
		na, nb := &a.nodes[i], &b.nodes[i]
		if na.uid != nb.uid || na.kind != nb.kind || na.pos != nb.pos || na.enabled != nb.enabled || na.proc_use_odin_body != nb.proc_use_odin_body || na.var_as_ref != nb.var_as_ref || na.math_op != nb.math_op || na.per_object_ts != nb.per_object_ts || na.for_mode != nb.for_mode || na.loop_reverse != nb.loop_reverse || na.sub_op != nb.sub_op || na.trigger_edge != nb.trigger_edge || na.input_priority != nb.input_priority || na.consume_input != nb.consume_input || na.is_look_vector != nb.is_look_vector || na.debug_key_code != nb.debug_key_code {
			return false
		}
		if na.title != nb.title || na.owner_proc != nb.owner_proc || na.var_name != nb.var_name || na.hot_proc_target != nb.hot_proc_target || na.odin_body != nb.odin_body || na.action_name != nb.action_name || na.delegate_name != nb.delegate_name || na.target_var_or_type != nb.target_var_or_type {
			return false
		}
		if !_vg_pins_equal(na.inputs[:], nb.inputs[:]) || !_vg_pins_equal(na.outputs[:], nb.outputs[:]) {
			return false
		}
	}
	for i in 0 ..< len(a.wires) {
		if a.wires[i] != b.wires[i] do return false
	}
	return true
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
	src_ck := vg_pin_container_kind(src)
	dst_ck := vg_pin_container_kind(dst)
	if (src_ck != .Single) != (dst_ck != .Single) {
		return false, "Array/Slice pin cannot connect directly to scalar pin"
	}
	if src_ck != dst_ck && dst_ck != .Slice {
		return false, "Array container kinds do not match (target requires exact array layout)"
	}
	if src.custom_type_name != "" && dst.custom_type_name != "" && src.custom_type_name != dst.custom_type_name {
		return false, "Custom enum/struct types do not match"
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

_vg_is_scalar_castable :: #force_inline proc(pt: hot.Hot_Pin_Type) -> bool {
	return pt in (bit_set[hot.Hot_Pin_Type]{.Int, .Int64, .Float, .U8, .I8, .U16, .I16, .U32, .U64, .F64, .Enum_U8})
}

vg_are_types_autocastable :: proc(src: VG_Pin_Def, dst: VG_Pin_Def) -> bool {
	if src.pin_type == dst.pin_type do return false
	if src.is_array || dst.is_array || src.container_kind != .Single || dst.container_kind != .Single do return false
	if dst.pass_mode == .By_Reference do return false
	if dst.pin_type == .Raw_Ptr && src.is_addressable do return true
	if src.pin_type == .Raw_Ptr && dst.pin_type not_in (bit_set[hot.Hot_Pin_Type]{.Exec, .Delegate}) do return true
	if src.pin_type in (bit_set[hot.Hot_Pin_Type]{.Exec, .Delegate, .Bool, .Struct_Val, .BitSet_U8, .String, .Asset, .Entity, .Raw_Ptr}) do return false
	if dst.pin_type in (bit_set[hot.Hot_Pin_Type]{.Exec, .Delegate, .Bool, .Struct_Val, .BitSet_U8, .String, .Asset, .Entity, .Raw_Ptr}) do return false
	if _vg_is_scalar_castable(src.pin_type) && _vg_is_scalar_castable(dst.pin_type) do return true
	// Vector component demotion (Vec4->Vec3/Vec2/Float, Vec3->Vec2/Float, Vec2->Float)
	if (src.pin_type == .Vec4 && dst.pin_type in (bit_set[hot.Hot_Pin_Type]{.Vec3, .Vec2, .Float})) do return true
	if (src.pin_type == .Vec3 && dst.pin_type in (bit_set[hot.Hot_Pin_Type]{.Vec2, .Float})) do return true
	if (src.pin_type == .Vec2 && dst.pin_type == .Float) do return true
	// Scalar splat to vector (Float/F64 -> Vec2/Vec3/Vec4)
	if (src.pin_type == .Float || src.pin_type == .F64) && dst.pin_type in (bit_set[hot.Hot_Pin_Type]{.Vec2, .Vec3, .Vec4}) do return true
	return false
}

vg_can_connect_or_autocast_pins :: proc(src: VG_Pin_Def, dst: VG_Pin_Def) -> (direct_ok: bool, needs_cast: bool, reason: string) {
	if ok, r := vg_can_connect_pins(src, dst); ok {
		return true, false, ""
	} else {
		if vg_are_types_autocastable(src, dst) {
			return false, true, ""
		}
		return false, false, r
	}
}

vg_can_split_pin :: proc(g: ^Visual_Graph, p: VG_Pin_Def) -> bool {
	if p.split_expanded || p.split_parent_name != "" || p.is_array || p.pass_mode == .By_Reference {
		return false
	}
	#partial switch p.pin_type {
	case .Vec2, .Vec3, .Vec4, .Quat:
		return true
	case .Struct_Val:
		if sd := vg_find_struct_decl(g, p.custom_type_name); sd != nil {
			fields, _, _ := vg_struct_layout(g, p.custom_type_name, context.temp_allocator)
			return len(fields) > 0
		}
	}
	return false
}

_remove_wires_on_pin_and_shift :: proc(g: ^Visual_Graph, node_uid: int, is_output: bool, pin_idx: int) {
	if g == nil do return
	for wi := len(g.wires) - 1; wi >= 0; wi -= 1 {
		w := &g.wires[wi]
		if is_output {
			if w.from_uid == node_uid {
				if w.from_pin == pin_idx {
					ordered_remove(&g.wires, wi)
				} else if w.from_pin > pin_idx {
					w.from_pin -= 1
				}
			}
		} else {
			if w.to_uid == node_uid {
				if w.to_pin == pin_idx {
					ordered_remove(&g.wires, wi)
				} else if w.to_pin > pin_idx {
					w.to_pin -= 1
				}
			}
		}
	}
}

vg_split_pin_inline :: proc(g: ^Visual_Graph, node_uid: int, is_output: bool, pin_idx: int) -> bool {
	n := vg_find_node(g, node_uid)
	if n == nil do return false
	pins := is_output ? &n.outputs : &n.inputs
	if pin_idx < 0 || pin_idx >= len(pins^) do return false
	p := &pins^[pin_idx]
	if !vg_can_split_pin(g, p^) do return false

	// Disconnect any wire previously bound directly to the parent pin
	for wi := len(g.wires) - 1; wi >= 0; wi -= 1 {
		w := g.wires[wi]
		if (is_output && w.from_uid == node_uid && w.from_pin == pin_idx) ||
		   (!is_output && w.to_uid == node_uid && w.to_pin == pin_idx) {
			ordered_remove(&g.wires, wi)
		}
	}

	parent_name := strings.clone(p.name, context.temp_allocator)
	parent_addr := p.is_addressable
	p.split_expanded = true

	#partial switch p.pin_type {
	case .Vec2:
		comps := [2]struct{ f: string, def: f32 }{{"x", p.default_vec2.x}, {"y", p.default_vec2.y}}
		for c in comps {
			append(pins, VG_Pin_Def{
				name              = strings.clone(fmt.tprintf("%s.%s", parent_name, c.f)),
				pin_type          = .Float,
				is_addressable    = is_output && parent_addr,
				default_f32       = c.def,
				split_parent_name = strings.clone(parent_name),
				split_field_name  = strings.clone(c.f),
			})
		}
	case .Vec3:
		comps := [3]struct{ f: string, def: f32 }{{"x", p.default_vec3.x}, {"y", p.default_vec3.y}, {"z", p.default_vec3.z}}
		for c in comps {
			append(pins, VG_Pin_Def{
				name              = strings.clone(fmt.tprintf("%s.%s", parent_name, c.f)),
				pin_type          = .Float,
				is_addressable    = is_output && parent_addr,
				default_f32       = c.def,
				split_parent_name = strings.clone(parent_name),
				split_field_name  = strings.clone(c.f),
			})
		}
	case .Vec4, .Quat:
		def4 := p.pin_type == .Quat && p.default_vec4 == ({0, 0, 0, 0}) ? [4]f32{0, 0, 0, 1} : p.default_vec4
		comps := [4]struct{ f: string, def: f32 }{{"x", def4.x}, {"y", def4.y}, {"z", def4.z}, {"w", def4.w}}
		for c in comps {
			append(pins, VG_Pin_Def{
				name              = strings.clone(fmt.tprintf("%s.%s", parent_name, c.f)),
				pin_type          = .Float,
				is_addressable    = is_output && parent_addr,
				default_f32       = c.def,
				split_parent_name = strings.clone(parent_name),
				split_field_name  = strings.clone(c.f),
			})
		}
	case .Struct_Val:
		fl, _, _ := vg_struct_layout(g, p.custom_type_name, context.temp_allocator)
		for f in fl {
			append(pins, VG_Pin_Def{
				name              = strings.clone(fmt.tprintf("%s.%s", parent_name, f.name)),
				pin_type          = f.pin_type,
				custom_type_name  = f.custom_type != "" ? strings.clone(f.custom_type) : "",
				is_addressable    = is_output && parent_addr,
				split_parent_name = strings.clone(parent_name),
				split_field_name  = strings.clone(f.name),
			})
		}
	}
	return true
}

vg_recombine_split_pin :: proc(g: ^Visual_Graph, node_uid: int, is_output: bool, pin_idx: int) -> bool {
	n := vg_find_node(g, node_uid)
	if n == nil do return false
	pins := is_output ? &n.outputs : &n.inputs
	if pin_idx < 0 || pin_idx >= len(pins^) do return false
	if !pins^[pin_idx].split_expanded do return false

	parent_name := strings.clone(pins^[pin_idx].name, context.temp_allocator)
	for i := len(pins^) - 1; i >= 0; i -= 1 {
		if pins^[i].split_parent_name == parent_name {
			_remove_wires_on_pin_and_shift(g, node_uid, is_output, i)
			_vg_destroy_pin_strings(&pins^[i])
			ordered_remove(pins, i)
		}
	}
	// Refresh parent index (in case any earlier pins shifted, though child pins always sit after parent)
	for &p in pins^ {
		if p.name == parent_name {
			p.split_expanded = false
		}
	}
	return true
}

// Returns the index (>= 0) of the first opposite-direction pin on `cand` that can legally
// connect with `drag_pin` (respecting `pin_type`, `is_array`, `custom_type_name`, `Copy T` vs `^Ref ^T`, and `Auto_Cast`),
// or `-1` if `cand` has no compatible pin.
vg_find_compatible_pin_on_node :: proc(drag_from_out: bool, drag_pin: VG_Pin_Def, cand: ^VG_Node, allow_autocast: bool = true) -> int {
	if cand == nil do return -1
	if drag_from_out {
		for ip, ii in cand.inputs {
			if ip.split_expanded do continue
			if ok, _ := vg_can_connect_pins(drag_pin, ip); ok do return ii
		}
		if allow_autocast {
			for ip, ii in cand.inputs {
				if ip.split_expanded do continue
				if vg_are_types_autocastable(drag_pin, ip) do return ii
			}
		}
	} else {
		for op, oi in cand.outputs {
			if op.split_expanded do continue
			if ok, _ := vg_can_connect_pins(op, drag_pin); ok do return oi
		}
		if allow_autocast {
			for op, oi in cand.outputs {
				if op.split_expanded do continue
				if vg_are_types_autocastable(op, drag_pin) do return oi
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
		if len(g.enums) > 0 {
			scratch.enums = make([dynamic]VG_Enum_Decl, len(g.enums), context.temp_allocator)
			copy(scratch.enums[:], g.enums[:])
		}
		if len(g.structs) > 0 {
			scratch.structs = make([dynamic]VG_Struct_Decl, len(g.structs), context.temp_allocator)
			copy(scratch.structs[:], g.structs[:])
		}
		if len(g.nodes) > 0 {
			scratch.nodes = make([dynamic]VG_Node, len(g.nodes), len(g.nodes) + 1, context.temp_allocator)
			copy(scratch.nodes[:], g.nodes[:])
		}
	}
	uid := vg_add_node(&scratch, kind, {}, custom_name)
	cand := vg_find_node(&scratch, uid)
	return vg_find_compatible_pin_on_node(drag_from_out, drag_pin, cand, false)
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
					name             = strings.clone(ep.name),
					pin_type         = ep.pin_type,
					is_array         = ep.is_array,
					container_kind   = ep.container_kind,
					custom_type_name = ep.custom_type_name != "" ? strings.clone(ep.custom_type_name) : "",
					default_f32      = ep.default_f32,
					default_int      = ep.default_int,
					default_i64      = ep.default_i64,
					default_bool     = ep.default_bool,
					default_vec2     = ep.default_vec2,
					default_vec3     = ep.default_vec3,
					default_vec4     = ep.default_vec4,
					default_str      = ep.default_str != "" ? strings.clone(ep.default_str) : "",
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
		vck   := VG_Container_Kind.Single
		vct   := ""
		if vi := vg_find_var_index(g, vname); vi >= 0 {
			vtype = g.variables[vi].pin_type
			varr  = g.variables[vi].is_array
			vck   = vg_resolve_container_kind(g.variables[vi])
			vct   = g.variables[vi].custom_type_name
		}
		n.var_name   = strings.clone(vname)
		n.var_as_ref = false
		n.title      = strings.clone(fmt.tprintf("Get %s", vname))
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Value (Copy)"), pin_type = vtype, is_array = varr || vck != .Single, container_kind = vck, custom_type_name = vct != "" ? strings.clone(vct) : "", pass_mode = .Copy_Value,   is_addressable = false})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Ref (^Ptr)"),   pin_type = vtype, is_array = varr || vck != .Single, container_kind = vck, custom_type_name = vct != "" ? strings.clone(vct) : "", pass_mode = .By_Reference, is_addressable = true})

	case .Set_Variable:
		vname := custom_name != "" ? custom_name : (len(g.variables) > 0 ? g.variables[0].name : "phase")
		vtype := hot.Hot_Pin_Type.Float
		varr  := false
		vck   := VG_Container_Kind.Single
		vct   := ""
		if vi := vg_find_var_index(g, vname); vi >= 0 {
			vtype = g.variables[vi].pin_type
			varr  = g.variables[vi].is_array
			vck   = vg_resolve_container_kind(g.variables[vi])
			vct   = g.variables[vi].custom_type_name
		}
		n.var_name = strings.clone(vname)
		n.title    = strings.clone(fmt.tprintf("Set %s", vname))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Value"), pin_type = vtype, is_array = varr || vck != .Single, container_kind = vck, custom_type_name = vct != "" ? strings.clone(vct) : "", pass_mode = .Copy_Value})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"),   pin_type = vtype, is_array = varr || vck != .Single, container_kind = vck, custom_type_name = vct != "" ? strings.clone(vct) : "", pass_mode = .Copy_Value})

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
		if meta, has_meta := hot_proc_find_sig_meta(pname); has_meta {
			n.title           = strings.clone(meta.display_title != "" ? meta.display_title : fmt.tprintf("Call %s", meta.proc_name))
			n.hot_proc_target = strings.clone(meta.proc_name)
			if !meta.is_pure {
				append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
				append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
			}
			for pm in meta.pins {
				p := VG_Pin_Def{
					name             = strings.clone(pm.name),
					pin_type         = pm.pin_type,
					pass_mode        = pm.by_ref ? .By_Reference : .Copy_Value,
					is_addressable   = pm.is_output && pm.by_ref,
					custom_type_name = pm.custom_type != "" ? strings.clone(pm.custom_type) : "",
					default_f32      = pm.default_f32,
					default_f64      = f64(pm.default_f32),
					default_int      = i32(pm.default_i64),
					default_i64      = pm.default_i64,
					default_u64      = u64(pm.default_i64),
					default_bool     = pm.default_bool,
				}
				if pm.is_output {
					append(&n.outputs, p)
				} else {
					append(&n.inputs, p)
				}
			}
		} else {
			n.title           = strings.clone(fmt.tprintf("Call %s", pname))
			n.hot_proc_target = strings.clone(pname)
			append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
			append(&n.inputs,  VG_Pin_Def{name = strings.clone("Amp"),       pin_type = .Float, pass_mode = .Copy_Value,   default_f32 = 0.30})
			append(&n.inputs,  VG_Pin_Def{name = strings.clone("Freq"),      pin_type = .Float, pass_mode = .Copy_Value,   default_f32 = 2.00})
			append(&n.inputs,  VG_Pin_Def{name = strings.clone("Phase Ref"), pin_type = .Float, pass_mode = .By_Reference, default_f32 = 0.00})
			append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
			append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"),       pin_type = .Float})
		}

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
		vg_configure_for_loop(g, &n, .Range_Inclusive, custom_name)

	case .Break_Loop:
		n.title = strings.clone("Break Loop")
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Continue_Loop:
		n.title = strings.clone("Continue Loop")
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

	case .Switch_Value:
		vg_configure_switch_node(g, &n, custom_name)

	case .BitSet_Op:
		vg_configure_bitset_op(g, &n, .Set_Flag, custom_name)

	case .Make_Struct:
		vg_sync_struct_node_pins(g, &n, custom_name)

	case .Break_Struct:
		vg_sync_struct_node_pins(g, &n, custom_name)

	case .Array_Op:
		vg_configure_array_op(g, &n, .Get_Copy, custom_name)

	case .Defer_Exec:
		n.title = strings.clone("Defer (Scoped Cleanup)")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),             pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),             pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Deferred Cleanup"), pin_type = .Exec})

	case .Or_Branch:
		n.title = strings.clone("Or Else (val, ok)")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Value"), pin_type = .Float, default_f32 = 0.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Ok"),    pin_type = .Bool,  default_bool = true})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Valid"),  pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Failed"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Value"),  pin_type = .Float})

	case .Auto_Cast:
		n.title = strings.clone("Cast")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("In"),  pin_type = .Float})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"), pin_type = .Int})

	case .Reroute_Knot:
		n.title = strings.clone("Reroute")
		pt := custom_name == "Exec" ? hot.Hot_Pin_Type.Exec : hot.Hot_Pin_Type.Float
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("In"),  pin_type = pt})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out"), pin_type = pt})

	case .Delay_Timer:
		n.title = strings.clone("Delay Timer")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),     pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Duration"), pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Reset"),    pin_type = .Bool,  default_bool = false})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Active"),    pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Completed"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Elapsed"),   pin_type = .Float})

	case .Cooldown_Gate:
		n.title = strings.clone("Cooldown Gate")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),     pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Duration"), pin_type = .Float, default_f32 = 1.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Reset"),    pin_type = .Bool,  default_bool = false})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Ready"),     pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Blocked"),   pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Remaining"), pin_type = .Float})

	case .Spawn_Prefab:
		n.title = strings.clone("Spawn Prefab")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Prefab"), pin_type = .Asset, default_str = strings.clone(custom_name)})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Pos"),    pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Rot"),    pin_type = .Quat,  default_vec4 = {0, 0, 0, 1}})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Spawned"), pin_type = .Entity})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Success"), pin_type = .Bool})

	case .Destroy_Entity:
		n.title = strings.clone("Destroy Entity")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target"), pin_type = .Entity})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})

	case .Physics_Raycast:
		n.title = strings.clone("[Physics] Raycast")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),     pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Origin"),   pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Dir"),      pin_type = .Vec3,  default_vec3 = {0, -1, 0}})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Max Dist"), pin_type = .Float, default_f32  = 100.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Mask"),     pin_type = .U32,   default_u64  = 0xFFFFFFFF})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Hit"),    pin_type = .Bool})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Point"),  pin_type = .Vec3})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Normal"), pin_type = .Vec3})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Dist"),   pin_type = .Float})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Entity"), pin_type = .Entity})

	case .Physics_Overlap_Sphere:
		n.title = strings.clone("[Physics] Overlap Sphere")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),   pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Center"), pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Radius"), pin_type = .Float, default_f32 = 3.0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Mask"),   pin_type = .U32,   default_u64 = 0xFFFFFFFF})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),           pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Count"),          pin_type = .Int})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Closest Entity"), pin_type = .Entity})

	case .Physics_Add_Impulse:
		n.title = strings.clone("[Physics] Add Impulse")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Target"),     pin_type = .Entity})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Impulse"),    pin_type = .Vec3, default_vec3 = {0, 8, 0}})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Vel Change"), pin_type = .Bool, default_bool = false})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),       pin_type = .Exec})

	case .Event_On_Trigger:
		n.title = strings.clone("Event: On Trigger")
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),         pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Other Entity"), pin_type = .Entity})

	case .CSG_Brush_Stamp:
		n.title = strings.clone("[CSG] Stamp Blast / Cut")
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),      pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("World Pos"), pin_type = .Vec3})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Radius"),    pin_type = .Float, default_f32 = 1.6})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Impulse"),   pin_type = .Float, default_f32 = 12.0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),           pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Affected Count"), pin_type = .Int})
	}

	append(&g.nodes, n)
	return uid
}

_vg_clear_node_pins :: proc(n: ^VG_Node) {
	for &p in n.inputs  do _vg_destroy_pin_strings(&p)
	for &p in n.outputs do _vg_destroy_pin_strings(&p)
	clear(&n.inputs)
	clear(&n.outputs)
}

_vg_find_first_array_var :: proc(g: ^Visual_Graph) -> string {
	if g == nil do return ""
	for v in g.variables {
		if v.is_array do return v.name
	}
	return ""
}

_vg_resolve_array_elem_type :: proc(g: ^Visual_Graph, var_name: string) -> (pt: hot.Hot_Pin_Type, custom_t: string) {
	if vi := vg_find_var_index(g, var_name); vi >= 0 {
		return g.variables[vi].pin_type, g.variables[vi].custom_type_name
	}
	return .Float, ""
}

vg_configure_for_loop :: proc(g: ^Visual_Graph, n: ^VG_Node, mode: VG_For_Mode, target_var: string = "") {
	if n == nil do return
	n.for_mode = mode
	vname := target_var
	if vname == "" && n.target_var_or_type != "" {
		vname = n.target_var_or_type
	} else if vname == "" && (mode == .For_In_Value || mode == .For_In_Ref) {
		vname = _vg_find_first_array_var(g)
	}
	if n.target_var_or_type != vname {
		delete(n.target_var_or_type)
		n.target_var_or_type = vname != "" ? strings.clone(vname) : ""
	}
	_vg_clear_node_pins(n)
	append(&n.inputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
	append(&n.outputs, VG_Pin_Def{name = strings.clone("Loop Body"), pin_type = .Exec})
	append(&n.outputs, VG_Pin_Def{name = strings.clone("Index"),     pin_type = .Int})
	append(&n.outputs, VG_Pin_Def{name = strings.clone("Completed"), pin_type = .Exec})
	delete(n.title)
	switch mode {
	case .Range_Inclusive:
		n.title = strings.clone("For Loop")
		append(&n.inputs, VG_Pin_Def{name = strings.clone("First Index"), pin_type = .Int, default_int = 0})
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Last Index"),  pin_type = .Int, default_int = 4})
	case .Range_Half_Open:
		n.title = strings.clone("For Loop (..<)")
		append(&n.inputs, VG_Pin_Def{name = strings.clone("First Index"), pin_type = .Int, default_int = 0})
		append(&n.inputs, VG_Pin_Def{name = strings.clone("End (<)"),     pin_type = .Int, default_int = 4})
	case .For_In_Value, .For_In_Ref:
		elem_pt, elem_ct := _vg_resolve_array_elem_type(g, vname)
		is_ref := (mode == .For_In_Ref)
		n.title = strings.clone(fmt.tprintf(is_ref ? "For &Elem in %s" : "For Elem in %s", vname != "" ? vname : "arr"))
		append(&n.outputs, VG_Pin_Def{
			name             = strings.clone(is_ref ? "Element (^Ref)" : "Element"),
			pin_type         = elem_pt,
			custom_type_name = elem_ct != "" ? strings.clone(elem_ct) : "",
			pass_mode        = is_ref ? .By_Reference : .Copy_Value,
			is_addressable   = is_ref,
		})
	case .Condition:
		n.title = strings.clone("For (While Condition)")
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Condition"), pin_type = .Bool, default_bool = true})
	}
}

vg_configure_array_op :: proc(g: ^Visual_Graph, n: ^VG_Node, mode: VG_Array_Op_Mode, target_var: string = "") {
	if n == nil do return
	n.sub_op = int(mode)
	vname := target_var
	if vname == "" && n.target_var_or_type != "" {
		vname = n.target_var_or_type
	} else if vname == "" {
		vname = _vg_find_first_array_var(g)
	}
	if n.target_var_or_type != vname {
		delete(n.target_var_or_type)
		n.target_var_or_type = vname != "" ? strings.clone(vname) : ""
	}
	elem_pt, elem_ct := _vg_resolve_array_elem_type(g, vname)
	_vg_clear_node_pins(n)
	delete(n.title)

	ct := elem_ct != "" ? strings.clone(elem_ct) : ""
	ct2 := elem_ct != "" ? strings.clone(elem_ct) : ""
	switch mode {
	case .Get_Copy:
		delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Get: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Index"), pin_type = .Int, default_int = 0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Value"), pin_type = elem_pt, custom_type_name = ct, pass_mode = .Copy_Value})
	case .Get_Ref:
		delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Get Ref (^T): %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Index"),      pin_type = .Int, default_int = 0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Elem (^Ptr)"), pin_type = elem_pt, custom_type_name = ct, pass_mode = .By_Reference, is_addressable = true})
	case .Len:
		delete(ct); delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Len: %s", vname != "" ? vname : "arr"))
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Count"), pin_type = .Int})
	case .Set_Elem:
		delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Set: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Index"), pin_type = .Int, default_int = 0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Value"), pin_type = elem_pt, custom_type_name = ct})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
	case .Append:
		delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Append: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Value"), pin_type = elem_pt, custom_type_name = ct})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Ok"),    pin_type = .Bool})
	case .Pop:
		delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Pop: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Value"), pin_type = elem_pt, custom_type_name = ct})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Valid"), pin_type = .Bool})
	case .Clear:
		delete(ct); delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Clear: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
	case .Swap_Remove:
		delete(ct); delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Swap Remove: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Index"), pin_type = .Int, default_int = 0})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),  pin_type = .Exec})
	case .Sub_Slice:
		delete(ct2)
		n.title = strings.clone(fmt.tprintf("Array Sub-Slice: %s", vname != "" ? vname : "arr"))
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Start"), pin_type = .Int, default_int = 0})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("End"),   pin_type = .Int, default_int = 1})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Slice"), pin_type = elem_pt, custom_type_name = ct, is_array = true, container_kind = .Slice})
	}
}

vg_configure_bitset_op :: proc(g: ^Visual_Graph, n: ^VG_Node, mode: VG_BitSet_Op_Mode, enum_name: string = "") {
	if n == nil do return
	n.sub_op = int(mode)
	en := enum_name
	if en == "" && n.target_var_or_type != "" {
		en = n.target_var_or_type
	} else if en == "" && g != nil && len(g.enums) > 0 {
		en = g.enums[0].name
	}
	if n.target_var_or_type != en {
		delete(n.target_var_or_type)
		n.target_var_or_type = en != "" ? strings.clone(en) : ""
	}
	_vg_clear_node_pins(n)
	delete(n.title)
	op_names := [VG_BitSet_Op_Mode]string{.Set_Flag = "BitSet +", .Clear_Flag = "BitSet -", .Toggle_Flag = "BitSet ~", .Has_Flag = "BitSet Has?", .Is_Empty = "BitSet Empty?"}
	n.title = strings.clone(fmt.tprintf("%s %s", op_names[mode], en))
	bs_ct := en != "" ? strings.clone(en) : ""
	en_ct := en != "" ? strings.clone(en) : ""
	out_ct := en != "" ? strings.clone(en) : ""
	if mode == .Has_Flag || mode == .Is_Empty {
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Set"), pin_type = .BitSet_U8, custom_type_name = bs_ct})
		if mode == .Has_Flag {
			append(&n.inputs, VG_Pin_Def{name = strings.clone("Flag"), pin_type = .Enum_U8, custom_type_name = en_ct})
		} else {
			delete(en_ct)
		}
		delete(out_ct)
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Result"), pin_type = .Bool})
	} else {
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Set"),     pin_type = .BitSet_U8, custom_type_name = bs_ct})
		append(&n.inputs,  VG_Pin_Def{name = strings.clone("Flag"),    pin_type = .Enum_U8,   custom_type_name = en_ct})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Exec"),    pin_type = .Exec})
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Out Set"), pin_type = .BitSet_U8, custom_type_name = out_ct})
	}
}

vg_configure_switch_node :: proc(g: ^Visual_Graph, n: ^VG_Node, enum_name: string = "") {
	if n == nil do return
	en := enum_name
	if en == "" && n.target_var_or_type != "" {
		en = n.target_var_or_type
	}
	ed := vg_find_enum_decl(g, en)
	if n.target_var_or_type != en {
		delete(n.target_var_or_type)
		n.target_var_or_type = en != "" ? strings.clone(en) : ""
	}
	_vg_clear_node_pins(n)
	delete(n.title)
	append(&n.inputs, VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
	if ed != nil {
		n.title = strings.clone(fmt.tprintf("Switch %s", ed.name))
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Value"), pin_type = .Enum_U8, custom_type_name = strings.clone(ed.name)})
		for v in ed.variants {
			append(&n.outputs, VG_Pin_Def{name = strings.clone(v), pin_type = .Exec})
		}
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Default"), pin_type = .Exec})
		n.sub_op = len(ed.variants)
	} else {
		cnt := clamp(n.sub_op > 0 ? n.sub_op : 2, 1, 16)
		n.sub_op = cnt
		n.title = strings.clone("Switch (Int)")
		append(&n.inputs, VG_Pin_Def{name = strings.clone("Selection"), pin_type = .Int, default_int = 0})
		for c in 0 ..< cnt {
			append(&n.outputs, VG_Pin_Def{name = strings.clone(fmt.tprintf("Case %d", c)), pin_type = .Exec})
		}
		append(&n.outputs, VG_Pin_Def{name = strings.clone("Default"), pin_type = .Exec})
	}
}

vg_sync_struct_node_pins :: proc(g: ^Visual_Graph, n: ^VG_Node, struct_name: string = "") {
	if n == nil do return
	sn := struct_name
	if sn == "" && n.target_var_or_type != "" {
		sn = n.target_var_or_type
	} else if sn == "" && g != nil && len(g.structs) > 0 {
		sn = g.structs[0].name
	}
	if n.target_var_or_type != sn {
		delete(n.target_var_or_type)
		n.target_var_or_type = sn != "" ? strings.clone(sn) : ""
	}
	_vg_clear_node_pins(n)
	delete(n.title)
	fl, _, _ := vg_struct_layout(g, sn, context.temp_allocator)
	if n.kind == .Make_Struct {
		n.title = strings.clone(fmt.tprintf("Make %s", sn != "" ? sn : "Struct"))
		for f in fl {
			append(&n.inputs, VG_Pin_Def{
				name             = strings.clone(f.name),
				pin_type         = f.pin_type,
				custom_type_name = f.custom_type != "" ? strings.clone(f.custom_type) : "",
			})
		}
		append(&n.outputs, VG_Pin_Def{name = strings.clone(sn != "" ? sn : "Struct"), pin_type = .Struct_Val, custom_type_name = sn != "" ? strings.clone(sn) : ""})
	} else {
		n.title = strings.clone(fmt.tprintf("Break %s", sn != "" ? sn : "Struct"))
		append(&n.inputs, VG_Pin_Def{name = strings.clone(sn != "" ? sn : "Struct"), pin_type = .Struct_Val, custom_type_name = sn != "" ? strings.clone(sn) : ""})
		for f in fl {
			append(&n.outputs, VG_Pin_Def{
				name             = strings.clone(f.name),
				pin_type         = f.pin_type,
				custom_type_name = f.custom_type != "" ? strings.clone(f.custom_type) : "",
			})
		}
	}
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

BODIN_GENERATED_BEGIN :: "// @BODIN_GENERATED_BEGIN"
BODIN_GENERATED_END   :: "// @BODIN_GENERATED_END"
BODIN_GRAPH_BEGIN     :: "// @BODIN_GRAPH_V1"
BODIN_GRAPH_END       :: "// @BODIN_GRAPH_END"

// Extracts the user-owned Zone 1 Odin source above `// @BODIN_GENERATED_BEGIN` from a
// `.bodin` buffer or file on disk so Blueprint bakes never clobber custom user Odin code.
vg_extract_bodin_user_zone :: proc(raw_bodin: string, allocator := context.temp_allocator) -> (user_zone: string, has_zone: bool) {
	if gen_i := strings.index(raw_bodin, BODIN_GENERATED_BEGIN); gen_i >= 0 {
		return strings.clone(strings.trim_right_space(raw_bodin[:gen_i]), allocator), true
	}
	return "", false
}

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
	data, rerr := vfs_read_entire_file(path, context.temp_allocator)
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
		for &v in g.variables {
			if v.container_kind == .Single && v.is_array {
				v.container_kind = v.array_is_bounded ? .Bounded_Array : .Fixed_Array
			}
			v.is_array = vg_resolve_container_kind(v) != .Single
			v.array_is_bounded = v.container_kind == .Bounded_Array
		}
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
	} else {
		vg_destroy_graph(g)
	}
	return ok
}

// Scrubs any `val_cstr` pointers inside entity blackboards that point outside
// `bb.str_bufs[vi]` (e.g. `.rodata` string literals from a hot-reloaded DLL)
// by copying them into host-owned inline `str_bufs` and clearing volatile
// `live_pin_values` before unloading the cartridge DLLs.
visual_script_scrub_external_cstrings :: proc() {
	if !_vs_rt.initialized do return
	for _, st in _vs_rt.entities {
		if st == nil do continue
		bb := &st.bb
		for vi in 0 ..< VG_MAX_VARS {
			slot := &bb.slots[vi]
			if slot.pin_type != .String && slot.pin_type != .Asset do continue
			if slot.val_cstr == nil do continue
			buf_start := uintptr(&bb.str_bufs[vi][0])
			buf_end   := buf_start + uintptr(len(bb.str_bufs[vi]))
			ptr_val   := uintptr(rawptr(slot.val_cstr))
			if ptr_val >= buf_start && ptr_val < buf_end do continue
			s := string(slot.val_cstr)
			ncopy := min(len(s), len(bb.str_bufs[vi]) - 1)
			for k in 0 ..< len(bb.str_bufs[vi]) do bb.str_bufs[vi][k] = 0
			if ncopy > 0 do copy(bb.str_bufs[vi][:ncopy], s[:ncopy])
			slot.val_cstr = cstring(&bb.str_bufs[vi][0])
		}
		if bb.live_pin_values != nil {
			clear(&bb.live_pin_values)
		}
	}
}

// =============================================================================
// Tier-1 Crash-Proof In-RAM Graph Evaluator (`0.00 ms`, Zero Segfault Risk)
// =============================================================================

// Writes a scalar/vector/handle `Hot_Slot` value into a live cartridge variable pointer (shared by evaluator & inspector).
vg_write_slot_to_var_ptr :: proc(dst: rawptr, pt: hot.Hot_Pin_Type, val: ^hot.Hot_Slot, copy_bytes: int = 0) {
	_slot_write_to_ptr(dst, pt, val, copy_bytes)
}

_slot_write_to_ptr :: proc(dst: rawptr, pt: hot.Hot_Pin_Type, val: ^hot.Hot_Slot, copy_bytes: int = 0) {
	if dst == nil || val == nil do return
	#partial switch pt {
	case .Bool:       (cast(^bool)dst)^           = hot.slot_read_bool(val)
	case .Int:        (cast(^i32)dst)^            = hot.slot_read_int(val)
	case .Int64:      (cast(^i64)dst)^            = hot.slot_read_i64(val)
	case .Float:      (cast(^f32)dst)^            = hot.slot_read_f32(val)
	case .F64:        (cast(^f64)dst)^            = hot.slot_read_f64(val)
	case .U8, .Enum_U8, .BitSet_U8: (cast(^u8)dst)^ = hot.slot_read_u8(val)
	case .I8:         (cast(^i8)dst)^             = hot.slot_read_i8(val)
	case .U16:        (cast(^u16)dst)^            = hot.slot_read_u16(val)
	case .I16:        (cast(^i16)dst)^            = hot.slot_read_i16(val)
	case .U32:        (cast(^u32)dst)^            = hot.slot_read_u32(val)
	case .U64:        (cast(^u64)dst)^            = hot.slot_read_u64(val)
	case .Vec2:       (cast(^[2]f32)dst)^         = hot.slot_read_vec2(val)
	case .Vec3:       (cast(^[3]f32)dst)^         = hot.slot_read_vec3(val)
	case .Vec4:       (cast(^[4]f32)dst)^         = hot.slot_read_vec4(val)
	case .Quat:       (cast(^[4]f32)dst)^         = hot.slot_read_quat(val)
	case .Entity:     (cast(^hot.Hot_Entity)dst)^ = hot.slot_read_entity(val)
	case .Delegate:   (cast(^hot.Hot_Delegate)dst)^ = hot.slot_read_delegate(val)
	case .String, .Asset: (cast(^cstring)dst)^    = hot.slot_read_cstr(val)
	case .Raw_Ptr:    (cast(^rawptr)dst)^         = hot.slot_read_rawptr(val)
	case .Struct_Val:
		nbytes := clamp(copy_bytes > 0 ? copy_bytes : int(val.val_byte_len), 0, hot.HOT_MAX_STRUCT_BYTES)
		if nbytes > 0 {
			src := hot.slot_ref_struct_bytes(val)
			runtime.mem_copy(dst, src, nbytes)
		}
	}
}

_slot_read_from_ptr :: proc(src: rawptr, pt: hot.Hot_Pin_Type, by_ref: bool = false, copy_bytes: int = 0) -> hot.Hot_Slot {
	out := hot.Hot_Slot{
		pin_type  = pt,
		pass_mode = by_ref ? .By_Reference : .Copy_Value,
		ref_ptr   = by_ref ? src : nil,
	}
	if src == nil do return out
	#partial switch pt {
	case .Bool:       out.val_bool     = (cast(^bool)src)^
	case .Int:        out.val_int      = (cast(^i32)src)^
	case .Int64:      out.val_i64      = (cast(^i64)src)^
	case .Float:      out.val_f32      = (cast(^f32)src)^
	case .F64:        out.val_f64      = (cast(^f64)src)^
	case .U8, .Enum_U8, .BitSet_U8: out.val_u8 = (cast(^u8)src)^
	case .I8:         out.val_i8       = (cast(^i8)src)^
	case .U16:        out.val_u16      = (cast(^u16)src)^
	case .I16:        out.val_i16      = (cast(^i16)src)^
	case .U32:        out.val_u32      = (cast(^u32)src)^
	case .U64:        out.val_u64      = (cast(^u64)src)^
	case .Vec2:       out.val_vec2     = (cast(^[2]f32)src)^
	case .Vec3:       out.val_vec3     = (cast(^[3]f32)src)^
	case .Vec4:       out.val_vec4     = (cast(^[4]f32)src)^
	case .Quat:       out.val_quat     = (cast(^[4]f32)src)^
	case .Entity:     out.val_ent      = (cast(^hot.Hot_Entity)src)^
	case .Delegate:   out.val_delegate = (cast(^hot.Hot_Delegate)src)^
	case .String, .Asset: out.val_cstr = (cast(^cstring)src)^
	case .Raw_Ptr:    out.val_ptr      = (cast(^rawptr)src)^
	case .Struct_Val:
		nbytes := clamp(copy_bytes > 0 ? copy_bytes : hot.HOT_MAX_STRUCT_BYTES, 0, hot.HOT_MAX_STRUCT_BYTES)
		out.val_byte_len = u8(nbytes)
		if nbytes > 0 {
			runtime.mem_copy(&out.val_bytes[0], src, nbytes)
		}
	}
	return out
}

_cast_hot_slot :: proc(in_s: hot.Hot_Slot, target_pt: hot.Hot_Pin_Type) -> hot.Hot_Slot {
	s := in_s
	if target_pt == .Raw_Ptr {
		ptr := s.pass_mode == .By_Reference && s.ref_ptr != nil && s.pin_type != .Raw_Ptr ? s.ref_ptr : hot.slot_read_rawptr(&s)
		return {pin_type = .Raw_Ptr, pass_mode = .Copy_Value, val_ptr = ptr}
	}
	if s.pin_type == .Raw_Ptr && target_pt != .Raw_Ptr {
		p := hot.slot_read_rawptr(&s)
		if pok, _ := hot.validate_raw_ptr(p, 1); pok {
			return _slot_read_from_ptr(p, target_pt, false, hot.HOT_MAX_STRUCT_BYTES)
		}
		return {pin_type = target_pt, pass_mode = .Copy_Value}
	}
	out := hot.Hot_Slot{pin_type = target_pt, pass_mode = .Copy_Value}
	#partial switch target_pt {
	case .Bool:  out.val_bool = hot.slot_read_bool(&s)
	case .Int:   out.val_int  = hot.slot_read_int(&s)
	case .Int64: out.val_i64  = hot.slot_read_i64(&s)
	case .Float: out.val_f32  = hot.slot_read_f32(&s)
	case .F64:   out.val_f64  = hot.slot_read_f64(&s)
	case .U8, .Enum_U8, .BitSet_U8: out.val_u8 = hot.slot_read_u8(&s)
	case .I8:    out.val_i8   = hot.slot_read_i8(&s)
	case .U16:   out.val_u16  = hot.slot_read_u16(&s)
	case .I16:   out.val_i16  = hot.slot_read_i16(&s)
	case .U32:   out.val_u32  = hot.slot_read_u32(&s)
	case .U64:   out.val_u64  = hot.slot_read_u64(&s)
	case .Vec2:
		if s.pin_type == .Float || s.pin_type == .F64 {
			fv := hot.slot_read_f32(&s)
			out.val_vec2 = {fv, fv}
		} else {
			out.val_vec2 = hot.slot_read_vec2(&s)
		}
	case .Vec3:
		if s.pin_type == .Float || s.pin_type == .F64 {
			fv := hot.slot_read_f32(&s)
			out.val_vec3 = {fv, fv, fv}
		} else {
			out.val_vec3 = hot.slot_read_vec3(&s)
		}
	case .Vec4:
		if s.pin_type == .Float || s.pin_type == .F64 {
			fv := hot.slot_read_f32(&s)
			out.val_vec4 = {fv, fv, fv, fv}
		} else {
			out.val_vec4 = hot.slot_read_vec4(&s)
		}
	case .Quat: out.val_quat = hot.slot_read_quat(&s)
	}
	return out
}

_vg_get_var_blob :: proc(g: ^Visual_Graph, bb: ^VG_Runtime_Blackboard, var_name: string) -> (v: VG_Var_Decl, blob: []u8, ok: bool) {
	vi := vg_find_var_index(g, var_name)
	if vi < 0 || vi >= len(g.variables) do return {}, nil, false
	v = g.variables[vi]
	needed := vg_var_byte_size(g, v)
	payload := _vg_ensure_canary_blob_bb(bb, v.name, needed)
	if len(payload) == 0 do return {}, nil, false
	return v, payload, true
}

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
			val_f64   = v.default_f64 != 0 ? v.default_f64 : f64(v.default_f32),
			val_int   = v.default_int,
			val_i64   = v.default_i64 != 0 ? v.default_i64 : i64(v.default_int),
			val_u8    = u8(clamp(v.default_u64, 0, 255)),
			val_i8    = i8(clamp(v.default_int, -128, 127)),
			val_u16   = u16(clamp(v.default_u64, 0, 65535)),
			val_i16   = i16(clamp(v.default_int, -32768, 32767)),
			val_u32   = u32(v.default_u64),
			val_u64   = v.default_u64,
			val_bool  = v.default_bool,
			val_vec2  = v.default_vec2,
			val_vec3  = v.default_vec3,
			val_vec4  = v.default_vec4,
			val_quat  = v.pin_type == .Quat ? {0, 0, 0, 1} : v.default_vec4,
			val_cstr  = cstring(&bb.str_bufs[i][0]),
		}
		ck := vg_resolve_container_kind(v)
		if ck == .Slice || ck == .Dynamic_Array {
			if v.pin_type == .Float {
				_ = _vg_ensure_f32_seq_bb(g, bb, v.name)
			} else {
				esz, eal := vg_scalar_type_size(g, v.pin_type, v.custom_type_name)
				_ = _vg_ensure_seq_bb(g, bb, v.name, esz, eal)
			}
		} else if ck != .Single || v.pin_type == .Struct_Val {
			_, _, _ = _vg_get_var_blob(g, bb, v.name)
		}
	}
}

@(private = "file")
_vg_extract_split_child :: proc(
	g:             ^Visual_Graph,
	parent_val:    hot.Hot_Slot,
	parent_pt:     hot.Hot_Pin_Type,
	parent_ct:     string,
	child_pt:      hot.Hot_Pin_Type,
	field_name:    string,
	want_by_ref:   bool,
) -> hot.Hot_Slot {
	comp_idx := -1
	if field_name == "x" do comp_idx = 0
	else if field_name == "y" do comp_idx = 1
	else if field_name == "z" do comp_idx = 2
	else if field_name == "w" do comp_idx = 3

	if comp_idx >= 0 && parent_pt in (bit_set[hot.Hot_Pin_Type]{.Vec2, .Vec3, .Vec4, .Quat}) {
		val := f32(0)
		if parent_pt == .Vec2 && comp_idx < 2      do val = parent_val.val_vec2[comp_idx]
		else if parent_pt == .Vec3 && comp_idx < 3 do val = parent_val.val_vec3[comp_idx]
		else if (parent_pt == .Vec4 || parent_pt == .Quat) && comp_idx < 4 do val = parent_val.val_quat[comp_idx]
		if parent_pt == .Vec4 && comp_idx < 4 && parent_val.val_vec4 != ({0,0,0,0}) do val = parent_val.val_vec4[comp_idx]

		rptr: rawptr = nil
		if want_by_ref && parent_val.ref_ptr != nil {
			rptr = rawptr(&(cast([^]f32)parent_val.ref_ptr)[comp_idx])
		}
		return {
			pin_type  = .Float,
			pass_mode = rptr != nil ? .By_Reference : .Copy_Value,
			val_f32   = val,
			ref_ptr   = rptr,
		}
	}

	if parent_pt == .Struct_Val {
		pv := parent_val
		fl, _, _ := vg_struct_layout(g, parent_ct, context.temp_allocator)
		for f in fl {
			if f.name == field_name {
				src_base := pv.ref_ptr != nil ? pv.ref_ptr : rawptr(&pv.val_bytes[0])
				if f.offset + f.size <= hot.HOT_MAX_STRUCT_BYTES || pv.ref_ptr != nil {
					f_ptr := rawptr(uintptr(src_base) + uintptr(f.offset))
					return _slot_read_from_ptr(f_ptr, child_pt, want_by_ref && pv.ref_ptr != nil, f.size)
				}
			}
		}
	}
	return {pin_type = child_pt}
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
	if out_pin_idx < 0 || out_pin_idx >= len(n.outputs) do return {}

	// 1. Handle Split Child Output Pin transparently from parent output pin
	op_def := n.outputs[out_pin_idx]
	if op_def.split_parent_name != "" {
		for pi in 0 ..< len(n.outputs) {
			if n.outputs[pi].name == op_def.split_parent_name {
				pv := _eval_pure_pin(g, bb, tH, raw_dt, node_uid, pi, depth + 1)
				res := _vg_extract_split_child(g, pv, n.outputs[pi].pin_type, n.outputs[pi].custom_type_name, op_def.pin_type, op_def.split_field_name, op_def.pass_mode == .By_Reference || op_def.is_addressable)
				_bb_set_live_pin(bb, n.uid, out_pin_idx, res)
				return res
			}
		}
	}

	w := ctx_world()
	obj_dt := w != nil && pool_valid(&w.transforms, Handle(tH)) ? transform_dt(tH, raw_dt) : raw_dt

	res: hot.Hot_Slot
	handled := true

	#partial switch n.kind {
	case .Event_Tick:
		if out_pin_idx == 1      do res = {pin_type = .Float, val_f32 = raw_dt}
		else if out_pin_idx == 2 do res = {pin_type = .Float, val_f32 = obj_dt}

	case .Event_On_Trigger:
		if out_pin_idx == 1 do res = {pin_type = .Entity, val_ent = transform_to_hot_entity(bb.trigger_other_entity)}

	case .Custom_Proc_Entry:
		if out_pin_idx == 0 {
			clean_g := g.name != "" ? g.name : "custom_graph"
			proc_sym := fmt.tprintf("mhgraph_%s__proc_%s", clean_g, n.hot_proc_target)
			slot_i := hot_proc_slot_index(proc_sym, false)
			res = {
				pin_type = .Delegate,
				val_delegate = hot.Hot_Delegate{
					entity    = transform_to_hot_entity(tH),
					proc_slot = slot_i,
					node_uid  = i32(n.uid),
				},
			}
		} else if out_pin_idx == 2 {
			res = {pin_type = .Float, val_f32 = bb.last_payload_f32}
		} else if out_pin_idx == 3 {
			res = {pin_type = .Vec2, val_vec2 = bb.last_payload_v2}
		} else if out_pin_idx == 4 {
			res = {pin_type = .Bool, val_bool = bb.last_pressed}
		}

	case .Get_Variable:
		vi := vg_find_var_index(g, n.var_name)
		if vi >= 0 && vi < VG_MAX_VARS {
			vdecl := g.variables[vi]
			s := bb.slots[vi]
			var_ptr := _bb_slot_value_ptr(bb, vi, vdecl.pin_type)
			ck := vg_resolve_container_kind(vdecl)
			if ck == .Slice || ck == .Dynamic_Array {
				if vdecl.pin_type == .Float {
					seq := _vg_ensure_f32_seq_bb(g, bb, vdecl.name)
					if seq != nil {
						s.ref_ptr   = rawptr(raw_data(seq^))
						s.slice_len = i32(len(seq^))
						s.slice_cap = i32(cap(seq^))
						var_ptr     = s.ref_ptr
					}
				} else {
					esz, eal := vg_scalar_type_size(g, vdecl.pin_type, vdecl.custom_type_name)
					seq_e := _vg_ensure_seq_bb(g, bb, vdecl.name, esz, eal)
					if seq_e != nil {
						s.ref_ptr   = seq_e.data
						s.slice_len = i32(seq_e.length)
						s.slice_cap = i32(seq_e.capacity)
						var_ptr     = s.ref_ptr
					}
				}
				s.pass_mode = out_pin_idx == 1 ? .By_Reference : .Copy_Value
			} else {
				if vdecl.is_array || vdecl.pin_type == .Struct_Val {
					_, blob, bok := _vg_get_var_blob(g, bb, vdecl.name)
					if bok && len(blob) > 0 {
						var_ptr = rawptr(&blob[0])
						if vdecl.is_array {
							cnt := vdecl.array_count > 0 ? vdecl.array_count : 8
							if vdecl.array_is_bounded {
								coff := vg_bounded_array_count_offset(g, vdecl)
								if coff + 4 <= len(blob) do cnt = clamp(int((cast(^i32)&blob[coff])^), 0, cnt)
							}
							s.slice_len = i32(cnt)
						}
						if vdecl.pin_type == .Struct_Val {
							nc := min(len(blob), hot.HOT_MAX_STRUCT_BYTES)
							s.val_byte_len = u8(nc)
							runtime.mem_copy(&s.val_bytes[0], &blob[0], nc)
						}
					}
				}
				if out_pin_idx == 1 {
					s.pass_mode = .By_Reference
					s.ref_ptr   = var_ptr
				} else {
					s.pass_mode = .Copy_Value
					s.ref_ptr   = ck == .Fixed_Array ? var_ptr : nil
				}
			}
			res = s
		}

	case .For_Loop:
		for li in bb.loop_indices {
			if li.active && li.node_uid == n.uid {
				if out_pin_idx == 1 {
					res = {pin_type = .Int, val_int = li.cur_idx}
				} else if out_pin_idx == 3 && li.elem_ptr != nil {
					sz, _ := vg_scalar_type_size(g, li.elem_pin_type, op_def.custom_type_name)
					res = _slot_read_from_ptr(li.elem_ptr, li.elem_pin_type, n.for_mode == .For_In_Ref, sz)
				}
				break
			}
		}
		if res.pin_type == .Exec {
			res = {pin_type = op_def.pin_type}
		}

	case .Get_Transform_Pos:
		if w != nil {
			if t := pool_get(&w.transforms, Handle(tH)); t != nil {
				if out_pin_idx == 1 {
					res = {pin_type = .Vec3, pass_mode = .By_Reference, val_vec3 = t.position, ref_ptr = &t.position}
				} else {
					res = {pin_type = .Vec3, pass_mode = .Copy_Value, val_vec3 = t.position}
				}
			}
		}
		if res.pin_type == .Exec do res = {pin_type = .Vec3}

	case .Math_Float:
		a_slot := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		b_slot := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		a := hot.slot_read_f32(&a_slot)
		b := hot.slot_read_f32(&b_slot)
		val: f32 = 0
		switch n.math_op {
		case .Add:      val = a + b
		case .Sub:      val = a - b
		case .Mul:      val = a * b
		case .Div:      val = abs(b) > 1e-6 ? (a / b) : 0
		case .Sin_Wave: val = math.sin(a * math.TAU) * b
		case .Damp:     val = hot.damp_f32(a, b, 8.0, obj_dt)
		}
		res = {pin_type = .Float, val_f32 = val}

	case .Vec3_Scale_Add:
		base_s  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		axis_s  := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		scale_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		res = {pin_type = .Vec3, val_vec3 = hot.slot_read_vec3(&base_s) + hot.slot_read_vec3(&axis_s) * hot.slot_read_f32(&scale_s)}

	case .Auto_Cast:
		in_s := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		res = _cast_hot_slot(in_s, op_def.pin_type)

	case .Reroute_Knot:
		res = _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)

	case .Make_Struct:
		fl, total_sz, _ := vg_struct_layout(g, n.target_var_or_type, context.temp_allocator)
		res = {pin_type = .Struct_Val, val_byte_len = u8(clamp(total_sz, 0, hot.HOT_MAX_STRUCT_BYTES))}
		for f, fi in fl {
			if fi >= len(n.inputs) do break
			in_s := _eval_node_input(g, bb, tH, raw_dt, n, fi, depth + 1)
			if f.offset + f.size <= hot.HOT_MAX_STRUCT_BYTES {
				_slot_write_to_ptr(&res.val_bytes[f.offset], f.pin_type, &in_s, f.size)
			}
		}

	case .Break_Struct:
		fl, _, _ := vg_struct_layout(g, n.target_var_or_type, context.temp_allocator)
		if out_pin_idx < len(fl) {
			in_s := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
			f := fl[out_pin_idx]
			src_base := in_s.ref_ptr != nil ? in_s.ref_ptr : rawptr(&in_s.val_bytes[0])
			if f.offset + f.size <= hot.HOT_MAX_STRUCT_BYTES || in_s.ref_ptr != nil {
				f_ptr := rawptr(uintptr(src_base) + uintptr(f.offset))
				res = _slot_read_from_ptr(f_ptr, f.pin_type, false, f.size)
			}
		}

	case .Array_Op:
		mode := VG_Array_Op_Mode(clamp(n.sub_op, 0, int(VG_Array_Op_Mode.Sub_Slice)))
		if mode == .Get_Copy || mode == .Get_Ref || mode == .Len || mode == .Sub_Slice {
			vi := vg_find_var_index(g, n.target_var_or_type)
			if vi >= 0 {
				vd := g.variables[vi]
				v_ck := vg_resolve_container_kind(vd)
				if vd.pin_type == .Float && (v_ck == .Slice || v_ck == .Dynamic_Array) {
					seq := _vg_ensure_f32_seq_bb(g, bb, n.target_var_or_type)
					if seq != nil {
						if mode == .Len {
							res = {pin_type = .Int, val_int = i32(len(seq^))}
						} else if mode == .Sub_Slice {
							s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
							s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
							lo := clamp(int(hot.slot_read_int(&s0)), 0, len(seq^))
							hi := clamp(int(hot.slot_read_int(&s1)), lo, len(seq^))
							res = {pin_type = .Float, ref_ptr = (hi > lo) ? rawptr(&seq^[lo]) : nil, slice_len = i32(hi - lo), slice_cap = -1}
						} else if len(seq^) > 0 {
							idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
							idx := clamp(int(hot.slot_read_int(&idx_s)), 0, len(seq^) - 1)
							if mode == .Get_Ref {
								res = {pin_type = .Float, pass_mode = .By_Reference, ref_ptr = rawptr(&seq^[idx])}
							} else {
								res = {pin_type = .Float, val_f32 = seq^[idx]}
							}
						}
					}
				} else if v_ck == .Slice || v_ck == .Dynamic_Array {
					esz, eal := vg_scalar_type_size(g, vd.pin_type, vd.custom_type_name)
					seq_e := _vg_ensure_seq_bb(g, bb, n.target_var_or_type, esz, eal)
					if seq_e != nil {
						if mode == .Len {
							res = {pin_type = .Int, val_int = i32(seq_e.length)}
						} else if mode == .Sub_Slice {
							s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
							s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
							lo := clamp(int(hot.slot_read_int(&s0)), 0, seq_e.length)
							hi := clamp(int(hot.slot_read_int(&s1)), lo, seq_e.length)
							res = {pin_type = vd.pin_type, ref_ptr = (hi > lo) ? _vg_raw_seq_elem_ptr(seq_e, lo) : nil, slice_len = i32(hi - lo), slice_cap = -1}
						} else if seq_e.length > 0 {
							idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
							idx := clamp(int(hot.slot_read_int(&idx_s)), 0, seq_e.length - 1)
							eptr := _vg_raw_seq_elem_ptr(seq_e, idx)
							res = _slot_read_from_ptr(eptr, vd.pin_type, mode == .Get_Ref, seq_e.elem_size)
						}
					}
				} else if v, blob, bok := _vg_get_var_blob(g, bb, n.target_var_or_type); bok && len(blob) > 0 {
					cnt := v.array_count > 0 ? v.array_count : 8
					cur_len := cnt
					if v.array_is_bounded {
						coff := vg_bounded_array_count_offset(g, v)
						if coff + 4 <= len(blob) {
							cur_len = clamp(int((cast(^i32)&blob[coff])^), 0, cnt)
						}
					}
					elem_sz, _ := vg_scalar_type_size(g, v.pin_type, v.custom_type_name)
					elem_sz = max(elem_sz, 1)
					if mode == .Len {
						res = {pin_type = .Int, val_int = i32(cur_len)}
					} else if mode == .Sub_Slice {
						s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
						s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
						lo := clamp(int(hot.slot_read_int(&s0)), 0, cur_len)
						hi := clamp(int(hot.slot_read_int(&s1)), lo, cur_len)
						res = {pin_type = v.pin_type, ref_ptr = (hi > lo) ? rawptr(&blob[lo * elem_sz]) : nil, slice_len = i32(hi - lo), slice_cap = -1}
					} else if cur_len > 0 {
						idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
						idx := clamp(int(hot.slot_read_int(&idx_s)), 0, cur_len - 1)
						eptr := rawptr(&blob[idx * elem_sz])
						res = _slot_read_from_ptr(eptr, v.pin_type, mode == .Get_Ref, elem_sz)
					}
				}
			}
		} else {
			handled = false
		}

	case .BitSet_Op:
		mode := VG_BitSet_Op_Mode(clamp(n.sub_op, 0, int(VG_BitSet_Op_Mode.Is_Empty)))
		if mode == .Has_Flag || mode == .Is_Empty {
			s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
			mask := hot.slot_read_u8(&s0)
			if mode == .Is_Empty {
				res = {pin_type = .Bool, val_bool = (mask == 0)}
			} else {
				s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
				bit := clamp(hot.slot_read_u8(&s1), 0, 7)
				res = {pin_type = .Bool, val_bool = (mask & (u8(1) << bit)) != 0}
			}
		} else {
			handled = false
		}

	case .Anim_Clip_Eval:
		spd_s  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		norm_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		ph := math.mod(hot.slot_read_f32(&norm_s) + obj_dt * hot.slot_read_f32(&spd_s), 1.0)
		res = {pin_type = .Float, val_f32 = out_pin_idx == 1 ? ph : 1.0}

	case .Anim_Blend_Layered:
		s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s2 := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		res = {pin_type = .Float, val_f32 = math.lerp(hot.slot_read_f32(&s0), hot.slot_read_f32(&s1), clamp(hot.slot_read_f32(&s2), 0.0, 1.0))}

	case .Anim_Spring_Damper:
		s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s2 := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		res = {pin_type = .Float, val_f32 = hot.damp_f32(hot.slot_read_f32(&s0), hot.slot_read_f32(&s1), max(hot.slot_read_f32(&s2), 0.01), obj_dt)}

	case .VFX_GPU_Curl_Force:
		s0 := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s1 := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s2 := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		vel := hot.slot_read_vec3(&s0)
		swirl := [3]f32{math.sin(vel.y * 1.7), math.cos(vel.x * 1.3), math.sin(vel.z * 1.5)} * (hot.slot_read_f32(&s1) * obj_dt)
		res = {pin_type = .Vec3, val_vec3 = (vel + swirl) * math.exp(-max(hot.slot_read_f32(&s2), f32(0.0)) * max(obj_dt, f32(0.0)))}

	case .VFX_Color_Size_Life:
		s_age := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s_min := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s_max := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		res = {pin_type = .Float, val_f32 = math.lerp(hot.slot_read_f32(&s_min), hot.slot_read_f32(&s_max), clamp(hot.slot_read_f32(&s_age), 0.0, 1.0))}

	case .Audio_Random_Container:
		s_seed  := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s_count := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		cnt     := max(int(hot.slot_read_int(&s_count)), 1)
		frac    := math.mod(abs(hot.slot_read_f32(&s_seed)), f32(1.0))
		res = {pin_type = .Int, val_int = i32(clamp(int(frac * f32(cnt)), 0, cnt - 1))}

	case .Audio_Modulate_Pitch_Vol:
		s_base := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		s_rng  := _eval_node_input(g, bb, tH, raw_dt, n, 1, depth + 1)
		s_seed := _eval_node_input(g, bb, tH, raw_dt, n, 2, depth + 1)
		frac   := math.mod(abs(hot.slot_read_f32(&s_seed)), f32(1.0))
		res = {pin_type = .Float, val_f32 = hot.slot_read_f32(&s_base) + (frac * 2.0 - 1.0) * hot.slot_read_f32(&s_rng)}

	case .AI_Check_Arrival:
		s_tol := _eval_node_input(g, bb, tH, raw_dt, n, 0, depth + 1)
		res = {pin_type = .Bool, val_bool = visual_script_ai_arrived_runtime(tH, hot.slot_read_f32(&s_tol))}

	case .Call_Hot_Proc:
		if len(n.inputs) == 0 || n.inputs[0].pin_type != .Exec {
			if n.hot_proc_target != "" && hot_proc_exists(n.hot_proc_target) {
				frame: hot.Hot_Call_Frame
				for pin_i in 0 ..< min(len(n.inputs), hot.HOT_MAX_ARGS) {
					frame.inputs[pin_i] = _eval_node_input(g, bb, tH, raw_dt, n, pin_i, depth + 1)
				}
				frame.input_count = i32(min(len(n.inputs), hot.HOT_MAX_ARGS))
				hot_proc_invoke(n.hot_proc_target, tH, obj_dt, &frame)
				for oi in 0 ..< min(len(n.outputs), int(frame.output_count)) {
					_bb_set_live_pin(bb, n.uid, oi, frame.outputs[oi])
				}
				if out_pin_idx < int(frame.output_count) {
					res = frame.outputs[out_pin_idx]
				}
			}
		} else {
			handled = false
		}

	case:
		handled = false
	}

	if !handled {
		if cached, ok := _bb_get_live_pin(bb, n.uid, out_pin_idx); ok {
			return cached
		}
		return {pin_type = op_def.pin_type}
	}

	_bb_set_live_pin(bb, n.uid, out_pin_idx, res)
	return res
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

	// Assemble split parent input value dynamically from its expanded child pins
	if pdef.split_expanded {
		assembled := hot.Hot_Slot{pin_type = pdef.pin_type, pass_mode = .Copy_Value}
		if pdef.pin_type == .Vec2 do assembled.val_vec2 = pdef.default_vec2
		else if pdef.pin_type == .Vec3 do assembled.val_vec3 = pdef.default_vec3
		else if pdef.pin_type == .Vec4 do assembled.val_vec4 = pdef.default_vec4
		else if pdef.pin_type == .Quat do assembled.val_quat = {0, 0, 0, 1}
		fl: []VG_Struct_Field_Layout
		if pdef.pin_type == .Struct_Val {
			tot: int
			fl, tot, _ = vg_struct_layout(g, pdef.custom_type_name, context.temp_allocator)
			assembled.val_byte_len = u8(clamp(tot, 0, hot.HOT_MAX_STRUCT_BYTES))
		}
		for ci in 0 ..< len(dst_node.inputs) {
			cp := dst_node.inputs[ci]
			if cp.split_parent_name != pdef.name do continue
			cs := _eval_node_input(g, bb, tH, raw_dt, dst_node, ci, depth + 1)
			if pdef.pin_type in (bit_set[hot.Hot_Pin_Type]{.Vec2, .Vec3, .Vec4, .Quat}) {
				fv := hot.slot_read_f32(&cs)
				cidx := -1
				if cp.split_field_name == "x" do cidx = 0
				else if cp.split_field_name == "y" do cidx = 1
				else if cp.split_field_name == "z" do cidx = 2
				else if cp.split_field_name == "w" do cidx = 3
				if cidx >= 0 {
					if pdef.pin_type == .Vec2 && cidx < 2      do assembled.val_vec2[cidx] = fv
					else if pdef.pin_type == .Vec3 && cidx < 3 do assembled.val_vec3[cidx] = fv
					else if pdef.pin_type == .Vec4 && cidx < 4 do assembled.val_vec4[cidx] = fv
					else if pdef.pin_type == .Quat && cidx < 4 do assembled.val_quat[cidx] = fv
				}
			} else if pdef.pin_type == .Struct_Val {
				for f in fl {
					if f.name == cp.split_field_name && f.offset + f.size <= hot.HOT_MAX_STRUCT_BYTES {
						_slot_write_to_ptr(&assembled.val_bytes[f.offset], f.pin_type, &cs, f.size)
						break
					}
				}
			}
		}
		return assembled
	}

	for wire in g.wires {
		if wire.to_uid == dst_node.uid && wire.to_pin == in_pin_idx {
			val := _eval_pure_pin(g, bb, tH, raw_dt, wire.from_uid, wire.from_pin, depth)
			if vg_pin_container_kind(pdef) == .Single && pdef.pass_mode == .Copy_Value && val.pass_mode == .By_Reference && val.ref_ptr != nil {
				val = _slot_read_from_ptr(val.ref_ptr, val.pin_type, false, int(val.val_byte_len))
			}
			return val
		}
	}

	return hot.Hot_Slot{
		pin_type  = pdef.pin_type,
		pass_mode = .Copy_Value,
		val_f32   = pdef.default_f32,
		val_f64   = pdef.default_f64 != 0 ? pdef.default_f64 : f64(pdef.default_f32),
		val_int   = pdef.default_int,
		val_i64   = pdef.default_i64 != 0 ? pdef.default_i64 : i64(pdef.default_int),
		val_u8    = u8(clamp(pdef.default_u64, 0, 255)),
		val_i8    = i8(clamp(pdef.default_int, -128, 127)),
		val_u16   = u16(clamp(pdef.default_u64, 0, 65535)),
		val_i16   = i16(clamp(pdef.default_int, -32768, 32767)),
		val_u32   = u32(pdef.default_u64),
		val_u64   = pdef.default_u64,
		val_bool  = pdef.default_bool,
		val_vec2  = pdef.default_vec2,
		val_vec3  = pdef.default_vec3,
		val_vec4  = pdef.default_vec4,
		val_quat  = pdef.pin_type == .Quat && pdef.default_vec4 == ({0, 0, 0, 0}) ? {0, 0, 0, 1} : pdef.default_vec4,
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
		bb.loop_break_requested    = false
		bb.loop_continue_requested = false
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

	deferred_uids := make([dynamic]int, 0, 4, context.temp_allocator)
	defer {
		for di := len(deferred_uids) - 1; di >= 0; di -= 1 {
			saved_brk := bb.loop_break_requested
			saved_cnt := bb.loop_continue_requested
			bb.loop_break_requested    = false
			bb.loop_continue_requested = false
			_eval_exec_chain_from_uid(g, bb, tH, raw_dt, deferred_uids[di], call_depth + 1)
			bb.loop_break_requested    = saved_brk
			bb.loop_continue_requested = saved_cnt
		}
	}

	hops := 0
	for cur_uid != 0 && hops < 128 {
		if bb.loop_break_requested || bb.loop_continue_requested do break
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
					vdecl := g.variables[vi]
					v_ck := vg_resolve_container_kind(vdecl)
					if v_ck == .Slice || v_ck == .Dynamic_Array {
						if vdecl.pin_type == .Float {
							seq := _vg_ensure_f32_seq_bb(g, bb, vdecl.name)
							if seq != nil && in_val.slice_len >= 0 {
								visual_script_sync_entity_var_f32_seq(tH, vdecl.name, (^f32)(in_val.ref_ptr), in_val.slice_len, -1)
							}
						} else {
							esz, eal := vg_scalar_type_size(g, vdecl.pin_type, vdecl.custom_type_name)
							_ = _vg_ensure_seq_bb(g, bb, vdecl.name, esz, eal)
							if in_val.slice_len >= 0 {
								visual_script_sync_entity_var_seq(tH, vdecl.name, in_val.ref_ptr, i32(esz), i32(eal), in_val.slice_len, -1)
							}
						}
					} else if vdecl.is_array || vdecl.pin_type == .Struct_Val {
						_, blob, bok := _vg_get_var_blob(g, bb, vdecl.name)
						if bok && len(blob) > 0 {
							if vdecl.pin_type == .Struct_Val {
								nc := min(len(blob), hot.HOT_MAX_STRUCT_BYTES)
								src := hot.slot_ref_struct_bytes(&in_val)
								runtime.mem_copy(&blob[0], src, nc)
								runtime.mem_copy(&bb.slots[vi].val_bytes[0], src, nc)
								bb.slots[vi].val_byte_len = u8(nc)
							}
						}
					} else {
						bb.slots[vi].pin_type = vdecl.pin_type
						_slot_write_to_ptr(_bb_slot_value_ptr(bb, vi, vdecl.pin_type), vdecl.pin_type, &in_val)
						if ent_bb := visual_script_get_entity_bb(tH); ent_bb != nil && ent_bb != bb {
							ent_bb.slots[vi].pin_type = vdecl.pin_type
							_slot_write_to_ptr(_bb_slot_value_ptr(ent_bb, vi, vdecl.pin_type), vdecl.pin_type, &in_val)
						}
						if cs_in := hot.slot_read_cstr(&in_val); cs_in != "" {
							s_in := string(cs_in)
							for k in 0 ..< len(bb.str_bufs[vi]) do bb.str_bufs[vi][k] = 0
							ncopy := min(len(s_in), len(bb.str_bufs[vi]) - 1)
							if ncopy > 0 do copy(bb.str_bufs[vi][:ncopy], s_in[:ncopy])
							bb.slots[vi].val_cstr = cstring(&bb.str_bufs[vi][0])
						}
					}
					_bb_set_live_pin(bb, cur_uid, 1, in_val)
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
						if bb.loop_break_requested || bb.loop_continue_requested do break
					}
				}
				cur_uid = 0
				continue

			case .Break_Loop:
				bb.loop_break_requested = true
				cur_uid = 0
				continue

			case .Continue_Loop:
				bb.loop_continue_requested = true
				cur_uid = 0
				continue

			case .Defer_Exec:
				if du := _find_exec_target(g, cur_uid, 1); du != 0 {
					append(&deferred_uids, du)
				}
				next_exec_pin = 0

			case .Switch_Value:
				sel_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				def_pin := max(len(n.outputs) - 1, 0)
				if ed := vg_find_enum_decl(g, n.target_var_or_type); ed != nil {
					ev := int(hot.slot_read_u8(&sel_s))
					next_exec_pin = (ev >= 0 && ev < len(ed.variants)) ? ev : def_pin
				} else {
					iv := int(hot.slot_read_int(&sel_s))
					next_exec_pin = (iv >= 0 && iv < def_pin) ? iv : def_pin
				}

			case .BitSet_Op:
				mode := VG_BitSet_Op_Mode(clamp(n.sub_op, 0, int(VG_BitSet_Op_Mode.Is_Empty)))
				if mode != .Has_Flag && mode != .Is_Empty {
					s_in := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
					s_fl := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
					mask := hot.slot_read_u8(&s_in)
					bit  := u8(1) << clamp(hot.slot_read_u8(&s_fl), 0, 7)
					switch mode {
					case .Set_Flag:    mask |= bit
					case .Clear_Flag:  mask &~= bit
					case .Toggle_Flag: mask ~= bit
					case .Has_Flag, .Is_Empty:
					}
					_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .BitSet_U8, val_u8 = mask})
				}

			case .Array_Op:
				mode := VG_Array_Op_Mode(clamp(n.sub_op, 0, int(VG_Array_Op_Mode.Sub_Slice)))
				vi := vg_find_var_index(g, n.target_var_or_type)
				v_ck := (vi >= 0) ? vg_resolve_container_kind(g.variables[vi]) : .Single
				if vi >= 0 && g.variables[vi].pin_type == .Float && (v_ck == .Slice || v_ck == .Dynamic_Array) {
					seq := _vg_ensure_f32_seq_bb(g, bb, n.target_var_or_type)
					if seq != nil {
						switch mode {
						case .Set_Elem:
							idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
							val_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
							idx := int(hot.slot_read_int(&idx_s))
							if idx >= 0 && idx < len(seq^) {
								seq^[idx] = hot.slot_read_f32(&val_s)
							}
						case .Append:
							val_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
							context.allocator = runtime.default_allocator()
							append(seq, hot.slot_read_f32(&val_s))
							_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Bool, val_bool = true})
						case .Pop:
							if len(seq^) > 0 {
								val := seq^[len(seq^) - 1]
								resize(seq, len(seq^) - 1)
								_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Float, val_f32 = val})
								_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Bool, val_bool = true})
							} else {
								_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Float})
								_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Bool, val_bool = false})
							}
						case .Clear:
							clear(seq)
						case .Swap_Remove:
							idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
							idx := int(hot.slot_read_int(&idx_s))
							if idx >= 0 && idx < len(seq^) {
								unordered_remove(seq, idx)
							}
						case .Get_Copy, .Get_Ref, .Len, .Sub_Slice:
						}
					}
				} else if vi >= 0 && (v_ck == .Slice || v_ck == .Dynamic_Array) {
					vd := g.variables[vi]
					esz, eal := vg_scalar_type_size(g, vd.pin_type, vd.custom_type_name)
					seq_e := _vg_ensure_seq_bb(g, bb, n.target_var_or_type, esz, eal)
					if seq_e != nil {
						switch mode {
						case .Set_Elem:
							idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
							val_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
							idx   := int(hot.slot_read_int(&idx_s))
							if eptr := _vg_raw_seq_elem_ptr(seq_e, idx); eptr != nil {
								_slot_write_to_ptr(eptr, vd.pin_type, &val_s, seq_e.elem_size)
							}
						case .Append:
							val_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
							tmp_el: [hot.HOT_MAX_STRUCT_BYTES]u8
							_slot_write_to_ptr(&tmp_el[0], vd.pin_type, &val_s, min(seq_e.elem_size, hot.HOT_MAX_STRUCT_BYTES))
							ok_app := _vg_raw_seq_append(seq_e, &tmp_el[0])
							_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Bool, val_bool = ok_app})
						case .Pop:
							if seq_e.length > 0 {
								seq_e.length -= 1
								eptr := rawptr(uintptr(seq_e.data) + uintptr(seq_e.length * max(seq_e.elem_size, 1)))
								out_v := _slot_read_from_ptr(eptr, vd.pin_type, false, seq_e.elem_size)
								_bb_set_live_pin(bb, cur_uid, 1, out_v)
								_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Bool, val_bool = true})
							} else {
								_bb_set_live_pin(bb, cur_uid, 1, {pin_type = vd.pin_type})
								_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Bool, val_bool = false})
							}
						case .Clear:
							seq_e.length = 0
						case .Swap_Remove:
							idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
							idx   := int(hot.slot_read_int(&idx_s))
							if idx >= 0 && idx < seq_e.length {
								last := seq_e.length - 1
								if idx != last {
									dst_p := _vg_raw_seq_elem_ptr(seq_e, idx)
									src_p := _vg_raw_seq_elem_ptr(seq_e, last)
									if dst_p != nil && src_p != nil {
										mem.copy(dst_p, src_p, max(seq_e.elem_size, 1))
									}
								}
								seq_e.length -= 1
							}
						case .Get_Copy, .Get_Ref, .Len, .Sub_Slice:
						}
					}
				} else if v, blob, bok := _vg_get_var_blob(g, bb, n.target_var_or_type); bok && len(blob) > 0 {
					cap_len := v.array_count > 0 ? v.array_count : 8
					elem_sz, _ := vg_scalar_type_size(g, v.pin_type, v.custom_type_name)
					elem_sz = max(elem_sz, 1)
					coff := v.array_is_bounded ? vg_bounded_array_count_offset(g, v) : 0
					cur_len := cap_len
					if v.array_is_bounded && coff + 4 <= len(blob) {
						cur_len = clamp(int((cast(^i32)&blob[coff])^), 0, cap_len)
					}
					switch mode {
					case .Set_Elem:
						idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
						val_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
						idx   := int(hot.slot_read_int(&idx_s))
						if idx >= 0 && idx < cur_len {
							_slot_write_to_ptr(&blob[idx * elem_sz], v.pin_type, &val_s, elem_sz)
						}
					case .Append:
						val_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
						ok := false
						if v.array_is_bounded && coff + 4 <= len(blob) && cur_len < cap_len {
							_slot_write_to_ptr(&blob[cur_len * elem_sz], v.pin_type, &val_s, elem_sz)
							(cast(^i32)&blob[coff])^ = i32(cur_len + 1)
							ok = true
						}
						_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Bool, val_bool = ok})
					case .Pop:
						out_v := hot.Hot_Slot{pin_type = v.pin_type}
						ok := false
						if v.array_is_bounded && coff + 4 <= len(blob) && cur_len > 0 {
							new_len := cur_len - 1
							out_v = _slot_read_from_ptr(&blob[new_len * elem_sz], v.pin_type, false, elem_sz)
							(cast(^i32)&blob[coff])^ = i32(new_len)
							ok = true
						}
						_bb_set_live_pin(bb, cur_uid, 1, out_v)
						_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Bool, val_bool = ok})
					case .Clear:
						if v.array_is_bounded && coff + 4 <= len(blob) {
							(cast(^i32)&blob[coff])^ = 0
						} else {
							runtime.mem_zero(&blob[0], len(blob))
						}
					case .Swap_Remove:
						idx_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
						idx   := int(hot.slot_read_int(&idx_s))
						if v.array_is_bounded && coff + 4 <= len(blob) && idx >= 0 && idx < cur_len {
							last := cur_len - 1
							if idx != last {
								runtime.mem_copy(&blob[idx * elem_sz], &blob[last * elem_sz], elem_sz)
							}
							(cast(^i32)&blob[coff])^ = i32(last)
						}
					case .Get_Copy, .Get_Ref, .Len, .Sub_Slice:
					}
				}

			case .Or_Branch:
				val_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				ok_s  := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				_bb_set_live_pin(bb, cur_uid, 2, val_s)
				next_exec_pin = hot.slot_read_bool(&ok_s) ? 0 : 1

			case .Reroute_Knot:
				next_exec_pin = 0

			case .For_Loop:
				body_uid := _find_exec_target(g, cur_uid, 0)
				loop_slot := -1
				for &li, idx in bb.loop_indices {
					if !li.active || li.node_uid == cur_uid {
						li.node_uid = cur_uid
						li.active   = true
						li.elem_ptr = nil
						loop_slot   = idx
						break
					}
				}
				iters := 0
				switch n.for_mode {
				case .Range_Inclusive, .Range_Half_Open:
					first_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
					last_s  := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
					first_i := hot.slot_read_int(&first_s)
					raw_end := hot.slot_read_int(&last_s)
					last_inc := n.for_mode == .Range_Half_Open ? (raw_end - 1) : raw_end
					if last_inc >= first_i {
						idx := n.loop_reverse ? last_inc : first_i
						step: i32 = n.loop_reverse ? -1 : 1
						for (n.loop_reverse ? (idx >= first_i) : (idx <= last_inc)) {
							iters += 1
							if iters > VG_MAX_LOOP_ITERATIONS {
								visual_script_report_loop_fuse(tH, u32(cur_uid))
								break
							}
							if loop_slot >= 0 do bb.loop_indices[loop_slot].cur_idx = idx
							if body_uid != 0 {
								bb.loop_continue_requested = false
								_eval_exec_chain_from_uid(g, bb, tH, raw_dt, body_uid, call_depth + 1)
								if bb.loop_break_requested {
									bb.loop_break_requested = false
									break
								}
								bb.loop_continue_requested = false
							}
							idx += step
						}
					}
				case .For_In_Value, .For_In_Ref:
					vi_for := vg_find_var_index(g, n.target_var_or_type)
					for_ck := (vi_for >= 0) ? vg_resolve_container_kind(g.variables[vi_for]) : .Single
					if vi_for >= 0 && g.variables[vi_for].pin_type == .Float && (for_ck == .Slice || for_ck == .Dynamic_Array) {
						seq := _vg_ensure_f32_seq_bb(g, bb, n.target_var_or_type)
						if seq != nil && len(seq^) > 0 {
							if loop_slot >= 0 do bb.loop_indices[loop_slot].elem_pin_type = .Float
							cnt := len(seq^)
							idx := n.loop_reverse ? (cnt - 1) : 0
							step := n.loop_reverse ? -1 : 1
							for (n.loop_reverse ? (idx >= 0) : (idx < cnt)) {
								iters += 1
								if iters > VG_MAX_LOOP_ITERATIONS {
									visual_script_report_loop_fuse(tH, u32(cur_uid))
									break
								}
								if loop_slot >= 0 {
									bb.loop_indices[loop_slot].cur_idx  = i32(idx)
									bb.loop_indices[loop_slot].elem_ptr = rawptr(&seq^[idx])
								}
								if body_uid != 0 {
									bb.loop_continue_requested = false
									_eval_exec_chain_from_uid(g, bb, tH, raw_dt, body_uid, call_depth + 1)
									if bb.loop_break_requested {
										bb.loop_break_requested = false
										break
									}
									bb.loop_continue_requested = false
								}
								cnt = len(seq^)
								idx += step
							}
						}
					} else if vi_for >= 0 && (for_ck == .Slice || for_ck == .Dynamic_Array) {
						vd := g.variables[vi_for]
						esz, eal := vg_scalar_type_size(g, vd.pin_type, vd.custom_type_name)
						seq_e := _vg_ensure_seq_bb(g, bb, n.target_var_or_type, esz, eal)
						if seq_e != nil && seq_e.length > 0 {
							if loop_slot >= 0 do bb.loop_indices[loop_slot].elem_pin_type = vd.pin_type
							cnt := seq_e.length
							idx := n.loop_reverse ? (cnt - 1) : 0
							step := n.loop_reverse ? -1 : 1
							for (n.loop_reverse ? (idx >= 0) : (idx < cnt)) {
								iters += 1
								if iters > VG_MAX_LOOP_ITERATIONS {
									visual_script_report_loop_fuse(tH, u32(cur_uid))
									break
								}
								if loop_slot >= 0 {
									bb.loop_indices[loop_slot].cur_idx  = i32(idx)
									bb.loop_indices[loop_slot].elem_ptr = _vg_raw_seq_elem_ptr(seq_e, idx)
								}
								if body_uid != 0 {
									bb.loop_continue_requested = false
									_eval_exec_chain_from_uid(g, bb, tH, raw_dt, body_uid, call_depth + 1)
									if bb.loop_break_requested {
										bb.loop_break_requested = false
										break
									}
									bb.loop_continue_requested = false
								}
								cnt = seq_e.length
								idx += step
							}
						}
					} else if v, blob, bok := _vg_get_var_blob(g, bb, n.target_var_or_type); bok && len(blob) > 0 {
						cap_len := v.array_count > 0 ? v.array_count : 8
						cnt := cap_len
						if v.array_is_bounded {
							coff := vg_bounded_array_count_offset(g, v)
							if coff + 4 <= len(blob) do cnt = clamp(int((cast(^i32)&blob[coff])^), 0, cap_len)
						}
						elem_sz, _ := vg_scalar_type_size(g, v.pin_type, v.custom_type_name)
						elem_sz = max(elem_sz, 1)
						if loop_slot >= 0 do bb.loop_indices[loop_slot].elem_pin_type = v.pin_type
						if cnt > 0 {
							idx := n.loop_reverse ? (cnt - 1) : 0
							step := n.loop_reverse ? -1 : 1
							for (n.loop_reverse ? (idx >= 0) : (idx < cnt)) {
								iters += 1
								if iters > VG_MAX_LOOP_ITERATIONS {
									visual_script_report_loop_fuse(tH, u32(cur_uid))
									break
								}
								if loop_slot >= 0 {
									bb.loop_indices[loop_slot].cur_idx  = i32(idx)
									bb.loop_indices[loop_slot].elem_ptr = rawptr(&blob[idx * elem_sz])
								}
								if body_uid != 0 {
									bb.loop_continue_requested = false
									_eval_exec_chain_from_uid(g, bb, tH, raw_dt, body_uid, call_depth + 1)
									if bb.loop_break_requested {
										bb.loop_break_requested = false
										break
									}
									bb.loop_continue_requested = false
								}
								idx += step
							}
						}
					}
				case .Condition:
					for {
						cond_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
						if !hot.slot_read_bool(&cond_s) do break
						iters += 1
						if iters > VG_MAX_LOOP_ITERATIONS {
							visual_script_report_loop_fuse(tH, u32(cur_uid))
							break
						}
						if loop_slot >= 0 do bb.loop_indices[loop_slot].cur_idx = i32(iters - 1)
						if body_uid != 0 {
							bb.loop_continue_requested = false
							_eval_exec_chain_from_uid(g, bb, tH, raw_dt, body_uid, call_depth + 1)
							if bb.loop_break_requested {
								bb.loop_break_requested = false
								break
							}
							bb.loop_continue_requested = false
						}
					}
				}
				if loop_slot >= 0 {
					bb.loop_indices[loop_slot].active   = false
					bb.loop_indices[loop_slot].elem_ptr = nil
				}
				next_exec_pin = 2

			case .Delay_Timer:
				dur_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				rst_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				dur   := hot.slot_read_f32(&dur_s)
				ready, rem := visual_script_timer_step_runtime(tH, u32(cur_uid), dur, obj_dt, hot.slot_read_bool(&rst_s), false)
				_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Float, val_f32 = max(dur - rem, f32(0.0))})
				next_exec_pin = ready ? 1 : 0

			case .Cooldown_Gate:
				dur_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				rst_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				dur   := hot.slot_read_f32(&dur_s)
				ready, rem := visual_script_timer_step_runtime(tH, u32(cur_uid), dur, obj_dt, hot.slot_read_bool(&rst_s), true)
				_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Float, val_f32 = rem})
				next_exec_pin = ready ? 0 : 1

			case .Spawn_Prefab:
				pf_s  := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				pos_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				rot_s := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				sp_h := visual_script_spawn_prefab_runtime(string(hot.slot_read_cstr(&pf_s)), hot.slot_read_vec3(&pos_s), hot.slot_read_quat(&rot_s))
				_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Entity, val_ent = transform_to_hot_entity(sp_h)})
				_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Bool, val_bool = (sp_h != {})})

			case .Destroy_Entity:
				tgt_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				te    := hot.slot_read_entity(&tgt_s)
				tgt_h := te.index != 0 ? hot_entity_to_transform(te) : tH
				visual_script_destroy_entity_runtime(tgt_h)

			case .Physics_Raycast:
				org_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				dir_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				dst_s := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				msk_s := _eval_node_input(g, bb, tH, raw_dt, n, 4, 0)
				rh := visual_script_physics_raycast_runtime(tH, hot.slot_read_vec3(&org_s), hot.slot_read_vec3(&dir_s), hot.slot_read_f32(&dst_s), hot.slot_read_u32(&msk_s))
				_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Bool,   val_bool = rh.hit})
				_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Vec3,   val_vec3 = rh.position})
				_bb_set_live_pin(bb, cur_uid, 3, {pin_type = .Vec3,   val_vec3 = rh.normal})
				_bb_set_live_pin(bb, cur_uid, 4, {pin_type = .Float,  val_f32  = rh.distance})
				_bb_set_live_pin(bb, cur_uid, 5, {pin_type = .Entity, val_ent  = rh.entity})

			case .Physics_Overlap_Sphere:
				ctr_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				rad_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				msk_s := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				cnt, closest := visual_script_physics_overlap_sphere_runtime(tH, hot.slot_read_vec3(&ctr_s), hot.slot_read_f32(&rad_s), hot.slot_read_u32(&msk_s))
				_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Int,    val_int = cnt})
				_bb_set_live_pin(bb, cur_uid, 2, {pin_type = .Entity, val_ent = transform_to_hot_entity(closest)})

			case .Physics_Add_Impulse:
				tgt_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				imp_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				vc_s  := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				te    := hot.slot_read_entity(&tgt_s)
				tgt_h := te.index != 0 ? hot_entity_to_transform(te) : tH
				visual_script_physics_add_impulse_runtime(tgt_h, hot.slot_read_vec3(&imp_s), hot.slot_read_bool(&vc_s))

			case .CSG_Brush_Stamp:
				pos_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				rad_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				imp_s := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				aff   := visual_script_csg_stamp_runtime(hot.slot_read_vec3(&pos_s), hot.slot_read_f32(&rad_s), hot.slot_read_f32(&imp_s), "")
				_bb_set_live_pin(bb, cur_uid, 1, {pin_type = .Int, val_int = aff})

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
				visual_script_anim_ik_target_runtime(tH, n.action_name != "" ? n.action_name : "Right_Hand", hot.slot_read_vec3(&eff_s), hot.slot_read_f32(&wt_s))

			case .VFX_Emitter_Spawn:
				rate_s  := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				burst_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				visual_script_vfx_spawn_runtime(tH, n.action_name, hot.slot_read_f32(&rate_s), hot.slot_read_int(&burst_s))

			case .Audio_Bus_Send:
				vol_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				cut_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				visual_script_audio_bus_send_runtime(n.action_name != "" ? n.action_name : "Music", hot.slot_read_f32(&vol_s), hot.slot_read_f32(&cut_s))

			case .Audio_Play_Spatial_3D:
				pos_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				vol_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				pit_s := _eval_node_input(g, bb, tH, raw_dt, n, 3, 0)
				visual_script_audio_play_3d_runtime(tH, n.action_name, hot.slot_read_vec3(&pos_s), hot.slot_read_f32(&vol_s), hot.slot_read_f32(&pit_s))

			case .AI_Find_Path_Move:
				pos_s := _eval_node_input(g, bb, tH, raw_dt, n, 1, 0)
				spd_s := _eval_node_input(g, bb, tH, raw_dt, n, 2, 0)
				_ = visual_script_ai_move_runtime(tH, hot.slot_read_vec3(&pos_s), hot.slot_read_f32(&spd_s))

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
					for oi in 0 ..< int(frame.output_count) {
						if 1 + oi < len(n.outputs) {
							_bb_set_live_pin(bb, cur_uid, 1 + oi, frame.outputs[oi])
						}
					}
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
