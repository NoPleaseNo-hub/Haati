package visual_script

// =============================================================================
// UNIFIED GRAPH STUDIO (`visual_script_editor.odin`)
// =============================================================================
// Unifies Gameplay & Ability Blueprints, Character Motion / Layered Anim Graphs,
// Particle / GPU VFX Graphs, Audio SoundScapes, and Material Shader Graphs into a
// single 3-Column Studio with Blueprint vs Material content switching and
// Unreal-style Namespace node organization (`VG_Namespace`):
//   1. Mode Switcher Bar:
//        - `Blueprint Graph (.bodin)` (Unified native Data-Oriented Odin graph covering
//           Events, Flow, Input, Delegates, Variables, Transform, Math, Anim, VFX, Audio, AI)
//        - `Material Shader (.mat/.glsl)` (Material Fragment Shader Graph + live preview)
//   2. Unreal-Style 3-Column Layout:
//        - Left Dock (*My Graph*): Events & Procedures, Variables (Instance-Editable),
//          and Odin Delegates
//        - Center Column: Auto-Sizing Node Block Canvas with 4 Pin Disciplines:
//            Exec Flow, Odin Delegate (`Hot_Delegate`), Copy (`T`), Mutable Ref (`^T`)
//        - Right Dock (*Details Inspector*): Context-sensitive Inspector for Variables,
//          Input Bindings, Custom Odin Delegates, Procedures, and Scoped Odin Nodes
//   3. Stationary Idle-Delay Hover Tooltips reusing IDE `//` doc-comments above procedures!

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import cs "haati:editor/code_studio"
import "haati:editor/icons"
import nc "haati:editor/node_canvas"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import wnd "haati:editor/window"
import "haati:engine"
import "haati:engine/input"
import hot "haati:engine/hot_api"
import im "haati:external/odin-imgui"

@(private)
_Pin_Endpoint :: struct {
	node_uid: int,
	pin_idx:  int,
	is_out:   bool,
	screen_p: im.Vec2,
	pin_def:  engine.VG_Pin_Def,
}

@(private)
_Debug_Key_Preset :: struct {
	label: cstring,
	code:  i32,
}

@(private)
_DEBUG_KEY_PRESETS := [16]_Debug_Key_Preset{
	{"G (Dev Trigger)", i32(input.Key.G)},
	{"H (Dev Toggle)",  i32(input.Key.H)},
	{"J (Dev Step)",    i32(input.Key.J)},
	{"K (Dev Kill/Alt)",i32(input.Key.K)},
	{"L (Dev Log)",     i32(input.Key.L)},
	{"T (Dev Test)",    i32(input.Key.T)},
	{"Y (Dev Aux 1)",   i32(input.Key.Y)},
	{"U (Dev Aux 2)",   i32(input.Key.U)},
	{"F1",              i32(input.Key.F1)},
	{"F2",              i32(input.Key.F2)},
	{"F3",              i32(input.Key.F3)},
	{"F4",              i32(input.Key.F4)},
	{"F5",              i32(input.Key.F5)},
	{"F6",              i32(input.Key.F6)},
	{"F8",              i32(input.Key.F8)},
	{"F9",              i32(input.Key.F9)},
}

@(private)
_FALLBACK_INPUT_ACTIONS := [8]string{
	"Jump",
	"Interact",
	"Fire",
	"Aim",
	"Sprint",
	"Dash",
	"Crouch",
	"Reload",
}

@(private)
_Palette_Node_Spec :: struct {
	label:  string,
	kind:   engine.VG_Node_Kind,
	arg:    string,
	domain: engine.VG_Graph_Domain,
	shared: bool, // true = core Odin flow/math/delegate available across Gameplay, Anim & VFX
}

@(private)
_PALETTE_CATALOG := [?]_Palette_Node_Spec{
	// Gameplay & Input Binding Domain
	{"[Input] Bind Input Action -> Procedure",              .Bind_Input_Action,       "Jump",            .Gameplay_Ability, false},
	{"[Input] Unbind Input Action (Dynamic Swap)",          .Unbind_Input_Action,     "Jump",            .Gameplay_Ability, false},
	{"[Input] Bind Input Vector (Move / Look) -> Proc",     .Bind_Input_Vector,       "",                .Gameplay_Ability, false},
	{"[Input] Unbind Input Vector",                         .Unbind_Input_Vector,     "",                .Gameplay_Ability, false},
	{"[DEV] Bind Debug Key (Scancode) -> Procedure",        .Bind_Debug_Key,          "",                .Gameplay_Ability, false},
	{"[DEV] Unbind Debug Key",                              .Unbind_Debug_Key,        "",                .Gameplay_Ability, false},
	{"[Input] Unbind All Inputs (Self)",                    .Unbind_All_Inputs,       "",                .Gameplay_Ability, false},
	{"[Time] Set Time Scale (Object / Global)",             .Set_Time_Scale,          "",                .Gameplay_Ability, false},
	{"[AI] Find Path & Move (NavMeshAgent)",                .AI_Find_Path_Move,       "",                .Gameplay_Ability, false},
	{"[AI] Check Arrival (NavMeshAgent)",                   .AI_Check_Arrival,        "",                .Gameplay_Ability, false},
	{"[Physics] Raycast (Masked -> Hit Struct)",            .Physics_Raycast,         "",                .Gameplay_Ability, true},
	{"[Physics] Overlap Sphere (Radius & Mask)",            .Physics_Overlap_Sphere,  "",                .Gameplay_Ability, true},
	{"[Physics] Add Impulse / Velocity Change",             .Physics_Add_Impulse,     "",                .Gameplay_Ability, true},
	{"[Event] On Trigger Volume Overlap",                   .Event_On_Trigger,        "",                .Gameplay_Ability, true},
	{"[Entity] Spawn Prefab Asset at Pos/Rot",              .Spawn_Prefab,            "",                .Gameplay_Ability, true},
	{"[Entity] Destroy Entity",                             .Destroy_Entity,          "",                .Gameplay_Ability, true},
	{"[CSG] Stamp Additive / Subtractive Brush",            .CSG_Brush_Stamp,         "",                .Gameplay_Ability, true},

	// Character Motion & Layered Anim Domain (Runs on same zero-overhead Odin VM!)
	{"[Anim] Evaluate Clip Pose / Phase",                   .Anim_Clip_Eval,          "Locomotion_Run",  .Anim_Motion,      false},
	{"[Anim] Layered Pose / Weight Blend",                  .Anim_Blend_Layered,      "",                .Anim_Motion,      false},
	{"[Anim] Second-Order Motion Spring Damper",            .Anim_Spring_Damper,      "",                .Anim_Motion,      false},
	{"[Anim] Two-Bone Procedural IK Target",                .Anim_IK_Target,          "Foot_L",          .Anim_Motion,      false},

	// Particle & On-GPU VFX Namespace
	{"[VFX] Emitter Continuous / Burst Spawn",              .VFX_Emitter_Spawn,       "Sparks",          .Particle_VFX,     false},
	{"[VFX GPU] SIMD Vector Curl & Drag Force",             .VFX_GPU_Curl_Force,      "",                .Particle_VFX,     false},
	{"[VFX] Color & Size Over Normalized Life",             .VFX_Color_Size_Life,     "",                .Particle_VFX,     false},

	// Audio & Procedural SoundScape Domain (Domain #5)
	{"[Audio] Random Clip Container (Index)",               .Audio_Random_Container,  "",                .Audio_SoundScape, false},
	{"[Audio] Modulate Pitch / Volume (+/- Range)",         .Audio_Modulate_Pitch_Vol,"",                .Audio_SoundScape, false},
	{"[Audio] Submix Bus Send (Volume / Lowpass Hz)",       .Audio_Bus_Send,          "Music",           .Audio_SoundScape, false},
	{"[Audio] Play Spatial 3D Sound Cue",                   .Audio_Play_Spatial_3D,   "Cue_Impact",      .Audio_SoundScape, false},

	// Shared Core Odin Lifecycle, Flow Control, Types, Delegates, Transform & Math
	{"[Proc] + Custom Procedure / Event Entry",             .Custom_Proc_Entry,       "On_Custom_Event", .Gameplay_Ability, true},
	{"[Delegate] Bind Custom Odin Delegate",                .Delegate_Bind,           "On_Signal",       .Gameplay_Ability, true},
	{"[Delegate] Unbind Custom Odin Delegate",              .Delegate_Unbind,         "On_Signal",       .Gameplay_Ability, true},
	{"[Delegate] Broadcast Custom Odin Delegate",           .Delegate_Broadcast,      "On_Signal",       .Gameplay_Ability, true},
	{"[Event] On Init (BeginPlay / Spawn)",                 .Event_Init,              "",                .Gameplay_Ability, true},
	{"[Event] On Tick (Opt-In Frame Update)",               .Event_Tick,              "",                .Gameplay_Ability, true},
	{"[Event] On Destroy (EndPlay Cleanup)",                .Event_Destroy,           "",                .Gameplay_Ability, true},
	{"[Odin] Scoped Odin BP_Node (`</>` + `using`)",     .Odin_Function_Node,      "",                .Gameplay_Ability, true},
	{"[Transform] Get Position (Copy & ^Ref)",              .Get_Transform_Pos,       "",                .Gameplay_Ability, true},
	{"[Transform] Set Position",                            .Set_Transform_Pos,       "",                .Gameplay_Ability, true},
	{"[Math] Float Math (Add / Mul / Sin / Damp)",          .Math_Float,              "",                .Gameplay_Ability, true},
	{"[Math] Vec3 + Axis * Scale",                          .Vec3_Scale_Add,          "",                .Gameplay_Ability, true},
	{"[Math] Odin BitSet Op (+ / - / ~ / Has / Empty)",     .BitSet_Op,               "",                .Gameplay_Ability, true},
	{"[Math] Odin Explicit Cast (Auto_Cast)",               .Auto_Cast,               "",                .Gameplay_Ability, true},
	{"[Variable] Array Op (Get / ^Ref / Append / Pop)",     .Array_Op,                "",                .Gameplay_Ability, true},
	{"[Variable] Make POD Struct",                          .Make_Struct,             "",                .Gameplay_Ability, true},
	{"[Variable] Break POD Struct",                         .Break_Struct,            "",                .Gameplay_Ability, true},
	{"[Flow] Branch (If / Else) [B+Click]",                 .Branch_If,               "",                .Gameplay_Ability, true},
	{"[Flow] Sequence (Then 0..N) [S+Click]",               .Sequence,                "",                .Gameplay_Ability, true},
	{"[Flow] For Loop (Range / For-In / ^Ref / While) [F]", .For_Loop,                "",                .Gameplay_Ability, true},
	{"[Flow] Break Loop",                                   .Break_Loop,              "",                .Gameplay_Ability, true},
	{"[Flow] Continue Loop",                                .Continue_Loop,           "",                .Gameplay_Ability, true},
	{"[Flow] Switch on Enum / Int",                         .Switch_Value,            "",                .Gameplay_Ability, true},
	{"[Flow] Odin Defer (Scoped LIFO Cleanup)",             .Defer_Exec,              "",                .Gameplay_Ability, true},
	{"[Flow] Odin Or-Else Branch (val, ok)",                .Or_Branch,               "",                .Gameplay_Ability, true},
	{"[Flow] Delay Timer (Async Wait)",                     .Delay_Timer,             "",                .Gameplay_Ability, true},
	{"[Flow] Cooldown Gate (Ready / Blocked)",              .Cooldown_Gate,           "",                .Gameplay_Ability, true},
	{"[Flow] Reroute Wire Knot",                            .Reroute_Knot,            "",                .Gameplay_Ability, true},
}

Studio_View_Mode :: enum u8 {
	Blueprint_Graph    = 0,
	Split_Graph_And_Fn = 1,
	Full_Odin_Script   = 2,
}

// Unreal-inspired node Namespaces classifying all graph operations without redundant VM silos.
VG_Namespace :: thm.Studio_Namespace

@(private)
_NAMESPACE_PALETTE_ORDER := [12]VG_Namespace{
	.Event,
	.Flow,
	.Input,
	.Delegate,
	.Variable,
	.Transform,
	.Math,
	.Odin,
	.Anim,
	.VFX,
	.Audio,
	.AI,
}

VS_UNDO_MAX :: 64

VS_Undo_Entry :: struct {
	graph:    engine.Visual_Graph,
	sel_uid:  int,
	sel_var:  int,
	subgraph: string,
}

@(private)
_VS_Editor_State :: struct {
	initialized:            bool,
	canvas:                 nc.Node_Canvas,
	graph:                  engine.Visual_Graph,
	preview_bb:             engine.VG_Runtime_Blackboard,
	graph_rel_path:         string,
	last_baked_odin:        string,
	dirty_unbaked:          bool,
	auto_bake_on_save:      bool,

	// Hybrid View & Sub-Graph Navigation State
	view_mode:              Studio_View_Mode,
	active_subgraph:        [64]byte,
	show_all_subgraph_nodes: bool,
	nav_history:            [16][64]byte,
	nav_hist_len:           int,
	nav_hist_cursor:        int,

	// Blueprint Studio Domain Content Filter & Focus State
	active_domain:          engine.VG_Graph_Domain,
	show_cross_domain:      bool,
	window_hovered:         bool,
	window_focused:         bool,

	// 3-Column Selection State (drives Right *Details Inspector*)
	selected_node_uid:      int,
	selected_var_idx:       int, // >= 0 when inspecting a Blueprint Variable in Right Details

	// Interactive wire drag state (Left OR Right drag)
	dragging_wire:          bool,
	drag_from_out:          bool,
	drag_node_uid:          int,
	drag_pin_idx:           int,
	drag_pin_def:           engine.VG_Pin_Def,
	drag_mouse_btn:         im.MouseButton,
	drag_start_screen:      im.Vec2,

	// Context-sensitive Pin-Drop Spawner Popup State (Right/Left drag off pin -> empty canvas)
	pin_drop_pending:       bool,
	pin_drop_from_uid:      int,
	pin_drop_from_pin:      int,
	pin_drop_from_out:      bool,
	pin_drop_pin_def:       engine.VG_Pin_Def,
	pin_drop_canvas:        im.Vec2,
	pin_drop_screen:        im.Vec2,
	pin_drop_search_buf:    [128]byte,
	pin_drop_focus_search:  bool,

	// Search & Creation Buffers
	ctx_search_buf:         [128]byte,
	toolbar_add_search_buf: [128]byte,
	ctx_spawn_canvas:       im.Vec2,
	using_search_buf:       [64]byte,
	new_bp_name_buf:        [64]byte,
	new_proc_buf:           [64]byte,
	new_del_buf:            [64]byte,
	new_enum_buf:           [64]byte,
	new_enum_var_buf:       [64]byte,
	new_struct_buf:         [64]byte,
	new_struct_field_buf:   [64]byte,
	new_struct_field_type:  i32,
	new_var_buf:            [64]byte,
	new_var_type:           i32,
	new_var_is_array:       bool,
	new_pin_buf:            [48]byte,
	new_pin_type:           i32,
	new_pin_is_ref:         bool,
	new_proc_param_buf:     [64]byte,
	new_proc_param_type:    i32,
	proc_rename_buf:        [64]byte,
	proc_rename_uid:        int,
	del_rename_buf:         [64]byte,
	del_rename_idx:         int,
	pending_var_drop_name:  [64]byte,
	pending_var_drop_pos:   [2]f32,

	// Right-click Pin Context Menu & Live Play Debugger Entity
	pin_ctx_uid:            int,
	pin_ctx_idx:            int,
	pin_ctx_is_out:         bool,
	preview_entity:         engine.Transform_Handle,

	// Details Inspector edit buffers
	rename_buf:             [64]byte,
	rename_target_uid:      int,
	rename_target_var:      int,
	cat_buf:                [64]byte,
	tip_buf:                [128]byte,
	action_custom_buf:      [64]byte,

	// Discovered `.bodin` / `.mhgraph` assets in `assets/scripts/`
	discovered_graphs:      [dynamic]string,

	// 64-Step Graph Undo / Redo Stacks
	undo_stack:             [dynamic]VS_Undo_Entry,
	redo_stack:             [dynamic]VS_Undo_Entry,
	last_undo_redo_frame:   i32,
	drag_undo_armed:        bool,
}

@(private)
_vs: _VS_Editor_State

vg_node_namespace :: proc(kind: engine.VG_Node_Kind, hint: string = "") -> VG_Namespace {
	if hint != "" && (kind == .Call_Hot_Proc || kind == .Odin_Function_Node) {
		lh := strings.to_lower(hint, context.temp_allocator)
		switch lh {
		case "event":     return .Event
		case "flow":      return .Flow
		case "input":     return .Input
		case "math":      return .Math
		case "transform": return .Transform
		case "anim":      return .Anim
		case "vfx":       return .VFX
		case "audio":     return .Audio
		case "ai":        return .AI
		case "delegate":  return .Delegate
		case "variable":  return .Variable
		case "odin", "odin_hot": return .Odin
		}
		if strings.contains(lh, "anim") || strings.contains(lh, "pose") || strings.contains(lh, "spring") || strings.contains(lh, "_ik") {
			return .Anim
		}
		if strings.contains(lh, "vfx") || strings.contains(lh, "particle") || strings.contains(lh, "emitter") || strings.contains(lh, "curl") {
			return .VFX
		}
		if strings.contains(lh, "audio") || strings.contains(lh, "sound") || strings.contains(lh, "submix") || strings.contains(lh, "cue") {
			return .Audio
		}
		if strings.contains(lh, "nav") || strings.contains(lh, "ai_") || strings.contains(lh, "path") || strings.contains(lh, "arrival") {
			return .AI
		}
		if strings.contains(lh, "math") || strings.contains(lh, "lerp") || strings.contains(lh, "damp") || strings.contains(lh, "sin") || strings.contains(lh, "cos") || strings.contains(lh, "remap") || strings.contains(lh, "u8") {
			return .Math
		}
		if strings.contains(lh, "transform") || strings.contains(lh, "pos_") || strings.contains(lh, "position") || strings.contains(lh, "rot") || strings.contains(lh, "dir") || strings.contains(lh, "quat") {
			return .Transform
		}
		if strings.contains(lh, "input") || strings.contains(lh, "action") || strings.contains(lh, "key") {
			return .Input
		}
		if strings.contains(lh, "delegate") || strings.contains(lh, "signal") {
			return .Delegate
		}
	}
	switch kind {
	case .Event_Init, .Event_Tick, .Event_Destroy, .Custom_Proc_Entry, .Event_On_Trigger:
		return .Event
	case .Branch_If, .Sequence, .For_Loop, .Call_Blueprint_Proc, .Set_Time_Scale,
	     .Break_Loop, .Continue_Loop, .Switch_Value, .Defer_Exec, .Or_Branch,
	     .Delay_Timer, .Cooldown_Gate, .Reroute_Knot:
		return .Flow
	case .Bind_Input_Action, .Unbind_Input_Action, .Bind_Input_Vector, .Unbind_Input_Vector, .Bind_Debug_Key, .Unbind_Debug_Key, .Unbind_All_Inputs:
		return .Input
	case .Math_Float, .Vec3_Scale_Add, .BitSet_Op, .Auto_Cast:
		return .Math
	case .Get_Transform_Pos, .Set_Transform_Pos, .Spawn_Prefab, .Destroy_Entity,
	     .Physics_Raycast, .Physics_Overlap_Sphere, .Physics_Add_Impulse, .CSG_Brush_Stamp:
		return .Transform
	case .Anim_Clip_Eval, .Anim_Blend_Layered, .Anim_Spring_Damper, .Anim_IK_Target:
		return .Anim
	case .VFX_Emitter_Spawn, .VFX_GPU_Curl_Force, .VFX_Color_Size_Life:
		return .VFX
	case .Audio_Random_Container, .Audio_Modulate_Pitch_Vol, .Audio_Bus_Send, .Audio_Play_Spatial_3D:
		return .Audio
	case .AI_Find_Path_Move, .AI_Check_Arrival:
		return .AI
	case .Delegate_Bind, .Delegate_Unbind, .Delegate_Broadcast:
		return .Delegate
	case .Odin_Function_Node, .Call_Hot_Proc:
		return .Odin
	case .Get_Variable, .Set_Variable, .Make_Struct, .Break_Struct, .Array_Op:
		return .Variable
	}
	return .Odin
}

vg_namespace_style :: proc(ns: VG_Namespace) -> (badge: string, accent: im.Vec4) {
	b, _, col := thm.studio_namespace_style(ns)
	return string(b), col
}

@(private = "file")
_vs_free_undo_entry :: proc(e: ^VS_Undo_Entry) {
	engine.vg_destroy_graph(&e.graph)
	if e.subgraph != "" do delete(e.subgraph)
	e^ = {}
}

vs_clear_undo :: proc() {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	for &e in _vs.undo_stack do _vs_free_undo_entry(&e)
	clear(&_vs.undo_stack)
	for &e in _vs.redo_stack do _vs_free_undo_entry(&e)
	clear(&_vs.redo_stack)
	_vs.drag_undo_armed      = false
	_vs.last_undo_redo_frame = -1
}

vs_can_undo :: proc() -> bool {
	return _vs.initialized && len(_vs.undo_stack) > 0
}

vs_can_redo :: proc() -> bool {
	return _vs.initialized && len(_vs.redo_stack) > 0
}

@(private)
_vs_capture_undo_entry :: proc() -> (entry: VS_Undo_Entry, ok: bool) {
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	entry.graph    = engine.vg_clone_graph(&_vs.graph, runtime.default_allocator())
	entry.sel_uid  = _vs.selected_node_uid
	entry.sel_var  = _vs.selected_var_idx
	entry.subgraph = strings.clone(_active_subgraph_str())
	return entry, true
}

vs_push_undo :: proc() {
	if !_vs.initialized do return
	if n := len(_vs.undo_stack); n > 0 && engine.vg_graphs_equal(&_vs.undo_stack[n - 1].graph, &_vs.graph) {
		return
	}
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	entry := VS_Undo_Entry{
		graph    = engine.vg_clone_graph(&_vs.graph, runtime.default_allocator()),
		sel_uid  = _vs.selected_node_uid,
		sel_var  = _vs.selected_var_idx,
		subgraph = strings.clone(_active_subgraph_str()),
	}
	for &r in _vs.redo_stack do _vs_free_undo_entry(&r)
	clear(&_vs.redo_stack)
	if len(_vs.undo_stack) >= VS_UNDO_MAX {
		oldest := _vs.undo_stack[0]
		_vs_free_undo_entry(&oldest)
		ordered_remove(&_vs.undo_stack, 0)
	}
	append(&_vs.undo_stack, entry)
}

@(private)
_record_undo_on_widget_activate :: #force_inline proc() {
	if im.IsItemActivated() {
		vs_push_undo()
	}
}

@(private)
_vs_apply_undo_stack :: proc(src: ^[dynamic]VS_Undo_Entry, dst: ^[dynamic]VS_Undo_Entry) -> bool {
	if !_vs.initialized || len(src^) == 0 do return false
	cur_entry, cap_ok := _vs_capture_undo_entry()
	if !cap_ok do return false

	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	popped := src[len(src^) - 1]
	ordered_remove(src, len(src^) - 1)

	engine.vg_destroy_graph(&_vs.graph)
	_vs.graph = popped.graph
	engine.vg_ensure_default_spaces(&_vs.graph)

	if len(dst^) >= VS_UNDO_MAX {
		oldest := dst[0]
		_vs_free_undo_entry(&oldest)
		ordered_remove(dst, 0)
	}
	append(dst, cur_entry)

	_vs.selected_node_uid = popped.sel_uid
	_vs.selected_var_idx  = popped.sel_var
	if _vs.selected_var_idx >= len(_vs.graph.variables) do _vs.selected_var_idx = -1
	_set_c_buf(_vs.active_subgraph[:], popped.subgraph)
	if popped.subgraph != "" do delete(popped.subgraph)

	_vs.preview_bb.initialized = false
	_vs.dirty_unbaked          = true
	_vs.rename_target_uid      = 0
	_vs.rename_target_var      = -1
	_vs.proc_rename_uid        = 0
	_vs.del_rename_idx         = -1
	nc.canvas_clear_selection(&_vs.canvas)
	for n, ni in _vs.graph.nodes {
		if n.uid == _vs.selected_node_uid {
			nc.canvas_set_selected(&_vs.canvas, ni, true)
			break
		}
	}
	_sync_ide_blueprint_context()
	if im.GetCurrentContext() != nil {
		_vs.last_undo_redo_frame = im.GetFrameCount()
	}
	return true
}

vs_undo :: proc() -> bool {
	return _vs_apply_undo_stack(&_vs.undo_stack, &_vs.redo_stack)
}

vs_redo :: proc() -> bool {
	return _vs_apply_undo_stack(&_vs.redo_stack, &_vs.undo_stack)
}

active_visual_graph :: proc() -> ^engine.Visual_Graph {
	ensure_visual_script_init()
	return &_vs.graph
}

vs_undo_depth :: proc() -> (undo_n, redo_n: int) {
	return len(_vs.undo_stack), len(_vs.redo_stack)
}

vs_add_node :: proc(kind: engine.VG_Node_Kind, pos: [2]f32, custom_name: string = "") -> int {
	ensure_visual_script_init()
	context.allocator = runtime.default_allocator()
	return engine.vg_add_node(&_vs.graph, kind, pos, custom_name)
}

visual_script_has_focus :: proc() -> bool {
	if !_vs.initialized do return false
	if cs.code_studio_has_focus() do return false
	return _vs.window_focused || _vs.window_hovered
}

set_studio_view_mode_graph :: proc() {
	ensure_visual_script_init()
	_vs.view_mode = .Blueprint_Graph
	if _vs.active_domain == .Material_Shader {
		_vs.active_domain = _vs.graph.domain == .Material_Shader ? .Gameplay_Ability : _vs.graph.domain
	}
	wnd.open("mh_visual_script")
}

owns_keyboard_shortcuts :: proc() -> bool {
	return _vs.window_hovered || _vs.window_focused
}

configure_graph_studio_defaults :: proc(electronic_wires: bool, auto_bake_on_save: bool) {
	ensure_visual_script_init()
	_vs.canvas.wire_style = electronic_wires ? .Electronic_45 : .Smooth_Bezier
	_vs.auto_bake_on_save = auto_bake_on_save
}

open_unified_graph_domain :: proc(domain: engine.VG_Graph_Domain, asset_path: string = "") {
	ensure_visual_script_init()
	if domain == .Material_Shader {
		wnd.open("void_material_editor")
		return
	}
	_vs.active_domain = domain
	_vs.graph.domain  = domain
	if asset_path != "" {
		open_blueprint_in_studio(asset_path)
		_vs.active_domain = domain
		_vs.graph.domain  = domain
	}
	wnd.open("mh_visual_script")
}

@(private)
_c_str :: #force_inline proc(buf: []byte) -> string {
	return widgets.buf_str(buf)
}

@(private)
_set_c_buf :: proc(buf: []byte, s: string) {
	widgets.buf_set(buf, s)
}

@(private)
_canvas_view_spawn_pos :: proc(frac: f32 = 0.38) -> [2]f32 {
	c := (_vs.canvas.size * frac) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
	return {c.x, c.y}
}

@(private)
_merged_input_actions :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 16, allocator)
	for act in engine.visual_script_list_input_actions(context.temp_allocator) {
		if act != "" do append(&out, act)
	}
	for fb in _FALLBACK_INPUT_ACTIONS {
		exists := false
		for ex in out do if ex == fb { exists = true; break }
		if !exists do append(&out, fb)
	}
	return out[:]
}

@(private)
_graph_matches_runner :: proc(graph_path: string) -> bool {
	if _vs.graph_rel_path == "" do return false
	if graph_path == _vs.graph_rel_path do return true
	return strings.has_suffix(graph_path, fmt.tprintf("%s.bodin", _vs.graph.name)) ||
	       strings.has_suffix(graph_path, fmt.tprintf("%s.mhgraph", _vs.graph.name))
}

@(private)
_live_editor_hook :: proc(graph_path: string, tH: engine.Transform_Handle, dt: f32, r: ^engine.VisualScriptRunner) -> bool {
	if !_vs.initialized do return false
	if _graph_matches_runner(graph_path) {
		_vs.preview_entity = tH
	}
	if !_vs.dirty_unbaked do return false
	if !_graph_matches_runner(graph_path) do return false

	engine.vg_sync_blackboard(&_vs.graph, &_vs.preview_bb)
	if r.instance_overrides != "" {
		engine.vg_apply_instance_overrides(&_vs.graph, &_vs.preview_bb, r.instance_overrides)
	} else {
		if len(_vs.graph.variables) > 0 && _vs.graph.variables[0].pin_type == .Float {
			_vs.preview_bb.slots[0].val_f32 = r.param_a
		}
		if len(_vs.graph.variables) > 1 && _vs.graph.variables[1].pin_type == .Float {
			_vs.preview_bb.slots[1].val_f32 = r.param_b
		}
	}

	if !r.init_fired {
		r.init_fired = true
		engine.vg_eval_event_live(&_vs.graph, &_vs.preview_bb, tH, dt, .Event_Init)
	}
	if engine.vg_has_tick_event(&_vs.graph) {
		engine.vg_eval_graph_live(&_vs.graph, &_vs.preview_bb, tH, dt)
	}
	return true
}

@(private)
_live_callback_hook :: proc(tH: engine.Transform_Handle, node_uid: int, proc_name: string, dt: f32, payload_f32: f32, payload_v2: [2]f32, pressed: bool) -> bool {
	if !_vs.initialized do return false
	_vs.preview_entity = tH
	if !_vs.dirty_unbaked do return false
	engine.vg_sync_blackboard(&_vs.graph, &_vs.preview_bb)
	_vs.preview_bb.last_payload_f32 = payload_f32
	_vs.preview_bb.last_payload_v2  = payload_v2
	_vs.preview_bb.last_pressed     = pressed

	if node_uid > 0 && engine.vg_find_node(&_vs.graph, node_uid) != nil {
		engine.vg_eval_from_entry_uid(&_vs.graph, &_vs.preview_bb, tH, dt, node_uid)
		return true
	}
	clean_prefix := fmt.tprintf("mhgraph_%s__proc_", sanitize_odin_ident(_vs.graph.name, context.temp_allocator))
	short_proc := proc_name
	if strings.has_prefix(proc_name, clean_prefix) {
		short_proc = proc_name[len(clean_prefix):]
	}
	if short_proc != "" && engine.vg_find_custom_proc_node(&_vs.graph, short_proc) != nil {
		engine.vg_eval_custom_proc_live(&_vs.graph, &_vs.preview_bb, tH, dt, short_proc, payload_f32, payload_v2, pressed)
		return true
	}
	return false
}

@(private)
_active_subgraph_str :: proc() -> string {
	return _c_str(_vs.active_subgraph[:])
}

@(private)
_is_node_visible_in_subgraph :: proc(n: ^engine.VG_Node) -> bool {
	if n == nil do return false
	if _vs.show_all_subgraph_nodes do return true
	sub := _active_subgraph_str()
	if sub == "" {
		return n.owner_proc == "" || n.kind == .Custom_Proc_Entry
	}
	return n.owner_proc == sub
}

@(private)
_navigate_to_subgraph :: proc(target: string, push_hist: bool = true) {
	cur := _active_subgraph_str()
	if push_hist && (target != cur || _vs.nav_hist_len == 0) {
		if _vs.nav_hist_len == 0 {
			_set_c_buf(_vs.nav_history[0][:], cur)
			_vs.nav_hist_len    = 1
			_vs.nav_hist_cursor = 0
		}
		if _vs.nav_hist_cursor + 1 < len(_vs.nav_history) {
			_vs.nav_hist_cursor += 1
			_set_c_buf(_vs.nav_history[_vs.nav_hist_cursor][:], target)
			_vs.nav_hist_len = _vs.nav_hist_cursor + 1
		} else {
			for i in 0 ..< len(_vs.nav_history) - 1 {
				_vs.nav_history[i] = _vs.nav_history[i + 1]
			}
			_set_c_buf(_vs.nav_history[len(_vs.nav_history) - 1][:], target)
			_vs.nav_hist_cursor = len(_vs.nav_history) - 1
			_vs.nav_hist_len    = len(_vs.nav_history)
		}
	}
	_set_c_buf(_vs.active_subgraph[:], target)
	_vs.proc_rename_uid = 0
	if target != "" {
		if pn := engine.vg_find_custom_proc_node(&_vs.graph, target); pn != nil {
			_focus_canvas_on_node(pn)
		}
	}
}

@(private)
_nav_go_back :: proc() {
	if _vs.nav_hist_cursor > 0 {
		_vs.nav_hist_cursor -= 1
		_set_c_buf(_vs.active_subgraph[:], _c_str(_vs.nav_history[_vs.nav_hist_cursor][:]))
	}
}

@(private)
_nav_go_forward :: proc() {
	if _vs.nav_hist_cursor + 1 < _vs.nav_hist_len {
		_vs.nav_hist_cursor += 1
		_set_c_buf(_vs.active_subgraph[:], _c_str(_vs.nav_history[_vs.nav_hist_cursor][:]))
	}
}

@(private)
_spawn_graph_node :: proc(kind: engine.VG_Node_Kind, pos: [2]f32, arg: string = "") -> int {
	vs_push_undo()
	context.allocator = runtime.default_allocator()
	uid := engine.vg_add_node(&_vs.graph, kind, pos, arg)
	sub := _active_subgraph_str()
	if kind == .Custom_Proc_Entry {
		if sub != "" {
			_navigate_to_subgraph(arg != "" ? arg : fmt.tprintf("On_Custom_Event_%d", uid))
		}
	} else if sub != "" && kind != .Event_Init && kind != .Event_Tick && kind != .Event_Destroy {
		if nn := engine.vg_find_node(&_vs.graph, uid); nn != nil {
			if nn.owner_proc != "" do delete(nn.owner_proc)
			nn.owner_proc = strings.clone(sub)
		}
	}
	_vs.selected_node_uid = uid
	_vs.selected_var_idx  = -1
	_vs.dirty_unbaked     = true
	nc.canvas_clear_selection(&_vs.canvas)
	for n, ni in _vs.graph.nodes {
		if n.uid == uid {
			nc.canvas_set_selected(&_vs.canvas, ni, true)
			break
		}
	}
	_sync_ide_blueprint_context()
	return uid
}

@(private)
_vs_resolve_graph_path :: proc(graph_rel_path: string, allocator := context.temp_allocator) -> string {
	if graph_rel_path == "" do return ""
	if filepath.is_abs(graph_rel_path) {
		out, _ := strings.clone(graph_rel_path, allocator)
		return out
	}
	if proj_root := engine.active_project_root(); proj_root != "" {
		proj_cand, _ := filepath.join({proj_root, graph_rel_path}, context.temp_allocator)
		if os.exists(proj_cand) {
			out, _ := strings.clone(proj_cand, allocator)
			return out
		}
	}
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	repo_cand, _ := filepath.join({repo_root, graph_rel_path}, context.temp_allocator)
	if os.exists(repo_cand) {
		out, _ := strings.clone(repo_cand, allocator)
		return out
	}
	haati_cand, _ := filepath.join({repo_root, "haati", graph_rel_path}, context.temp_allocator)
	if os.exists(haati_cand) {
		out, _ := strings.clone(haati_cand, allocator)
		return out
	}
	if proj_root := engine.active_project_root(); proj_root != "" {
		proj_cand, _ := filepath.join({proj_root, graph_rel_path}, allocator)
		return proj_cand
	}
	out, _ := strings.clone(repo_cand, allocator)
	return out
}

@(private)
_sync_bodin_disk_to_hot_cartridge :: proc() {
	if _vs.graph_rel_path == "" do return
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	abs_bodin := _vs_resolve_graph_path(_vs.graph_rel_path, context.temp_allocator)
	if data, rerr := os.read_entire_file(abs_bodin, context.temp_allocator); rerr == nil {
		raw := string(data)
		code_part := raw
		if b_idx := strings.index(raw, engine.BODIN_GRAPH_BEGIN); b_idx >= 0 {
			code_part = raw[:b_idx]
		} else if b_leg := strings.index(raw, "/* @BODIN_GRAPH_V1"); b_leg >= 0 {
			code_part = raw[:b_leg]
		}
		clean_name := sanitize_odin_ident(_vs.graph.name != "" ? _vs.graph.name : "custom_graph", context.temp_allocator)
		rel_odin   := fmt.tprintf("haati/hot_scripts/%s_mhgraph_generated.odin", clean_name)
		abs_odin, _ := filepath.join({repo_root, rel_odin}, context.temp_allocator)
		_ = os.write_entire_file(abs_odin, transmute([]u8)strings.trim_space(code_part))
		engine.hot_cartridge_trigger_async_build(true)
	}
}

// Syncs Blueprint Variables, Custom Procedures, and `using` namespaces into `code_studio` Autocomplete!
@(private)
_sync_ide_blueprint_context :: proc() {
	vars  := make([dynamic]cs.Scoped_Pin_Badge, 0, len(_vs.graph.variables), context.temp_allocator)
	procs := make([dynamic]string, 0, 8, context.temp_allocator)
	for v in _vs.graph.variables {
		append(&vars, cs.Scoped_Pin_Badge{
			name      = v.name,
			odin_type = engine.vg_var_odin_type_ex(&_vs.graph, v, context.temp_allocator),
			pass_mode = .By_Reference,
			is_output = false,
		})
	}
	for n in _vs.graph.nodes {
		if n.kind == .Custom_Proc_Entry && n.hot_proc_target != "" {
			append(&procs, n.hot_proc_target)
		}
	}
	cs.set_blueprint_autocomplete_context(vars[:], procs[:], _vs.graph.using_spaces[:])
}

@(private)
_on_scoped_using_toggle :: proc(space_id: string, user_ptr: rawptr) -> string {
	_ = user_ptr
	vs_push_undo()
	engine.vg_toggle_using_space(&_vs.graph, space_id)
	_vs.dirty_unbaked = true
	_sync_ide_blueprint_context()
	if _vs.selected_node_uid > 0 {
		if n := engine.vg_find_node(&_vs.graph, _vs.selected_node_uid); n != nil && n.kind == .Odin_Function_Node {
			return build_scoped_node_signature(n, &_vs.graph, context.temp_allocator)
		}
	}
	return ""
}

@(private)
_on_scoped_using_query :: proc(space_id: string, _user_ptr: rawptr) -> bool {
	return engine.vg_has_using_space(&_vs.graph, space_id)
}

list_blueprint_assets :: proc(allocator := context.allocator) -> []string {
	res := make([dynamic]string, allocator)
	search_dirs := make([dynamic]string, context.temp_allocator)
	if proj_root := engine.active_project_root(); proj_root != "" {
		if d, err := filepath.join({proj_root, "assets", "scripts"}, context.temp_allocator); err == nil {
			append(&search_dirs, d)
		}
	}
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	for sd in ([?]string{"assets/scripts", "haati/assets/scripts"}) {
		if d, err := filepath.join({repo_root, sd}, context.temp_allocator); err == nil {
			append(&search_dirs, d)
		}
	}
	for scripts_dir in search_dirs {
		if h, err := os.open(scripts_dir); err == nil {
			if entries, rerr := os.read_dir(h, -1, context.temp_allocator); rerr == nil {
				for e in entries {
					if strings.has_suffix(e.name, ".bodin") || strings.has_suffix(e.name, ".mhgraph") {
						rel_cand := fmt.tprintf("assets/scripts/%s", e.name)
						already := false
						for ex in res do if ex == rel_cand { already = true; break }
						if !already do append(&res, strings.clone(rel_cand, allocator))
					}
				}
			}
			os.close(h)
		}
	}
	if len(res) == 0 {
		append(&res, strings.clone("assets/scripts/hover_oscillator.bodin", allocator))
	}
	slice.sort(res[:])
	return res[:]
}

@(private)
_rescan_blueprint_assets :: proc() {
	context.allocator = runtime.default_allocator()
	for s in _vs.discovered_graphs do delete(s)
	clear(&_vs.discovered_graphs)
	listed := list_blueprint_assets(context.temp_allocator)
	for s in listed {
		append(&_vs.discovered_graphs, strings.clone(s))
	}
}

ensure_visual_script_init :: proc() {
	if _vs.initialized do return
	context.allocator = runtime.default_allocator()
	_vs.initialized            = true
	_vs.auto_bake_on_save      = true
	_vs.show_all_subgraph_nodes = true
	_vs.selected_var_idx       = -1
	_vs.rename_target_var = -1
	_vs.del_rename_idx    = -1
	nc.canvas_init(&_vs.canvas)
	_vs.canvas.wire_style = nc.global_wire_style
	engine.vg_init_default_demo_graph(&_vs.graph, "hover_oscillator")
	_vs.graph_rel_path = strings.clone("assets/scripts/hover_oscillator.bodin")
	_vs.new_var_type   = i32(hot.Hot_Pin_Type.Float)
	_vs.new_pin_type   = i32(hot.Hot_Pin_Type.Float)
	_vs.new_proc_param_type = i32(hot.Hot_Pin_Type.Float)
	if len(_vs.graph.nodes) > 0 {
		_vs.selected_node_uid = _vs.graph.nodes[0].uid
		nc.canvas_set_selected(&_vs.canvas, 0, true)
	}
	engine.visual_script_live_editor_hook   = _live_editor_hook
	engine.visual_script_live_callback_hook = _live_callback_hook
	cs.set_scoped_using_hooks(_on_scoped_using_toggle, _on_scoped_using_query)
	_rescan_blueprint_assets()
	_sync_ide_blueprint_context()
}

shutdown_visual_script_studio :: proc() {
	if !_vs.initialized do return
	engine.visual_script_live_editor_hook   = nil
	engine.visual_script_live_callback_hook = nil
	context.allocator = runtime.default_allocator()
	vs_clear_undo()
	delete(_vs.undo_stack)
	delete(_vs.redo_stack)
	engine.vg_destroy_graph(&_vs.graph)
	delete(_vs.preview_bb.last_exec_path)
	if _vs.graph_rel_path  != "" do delete(_vs.graph_rel_path)
	if _vs.last_baked_odin != "" do delete(_vs.last_baked_odin)
	for s in _vs.discovered_graphs do delete(s)
	delete(_vs.discovered_graphs)
	_vs = {}
}

// Opens an existing `.bodin` / `.mhgraph` asset inside the Unified Graph Studio (called from Scene Inspector!).
open_blueprint_in_studio :: proc(graph_rel_path: string) -> bool {
	ensure_visual_script_init()
	if graph_rel_path == "" {
		wnd.open("mh_visual_script")
		return true
	}
	abs_p := _vs_resolve_graph_path(graph_rel_path, context.temp_allocator)
	if os.exists(abs_p) {
		context.allocator = runtime.default_allocator()
		if engine.vg_load_from_file(&_vs.graph, abs_p) {
			if _vs.graph_rel_path != "" do delete(_vs.graph_rel_path)
			_vs.graph_rel_path         = strings.clone(graph_rel_path)
			_vs.preview_bb.initialized = false
			_vs.dirty_unbaked          = false
			_vs.selected_var_idx       = -1
			_vs.selected_node_uid      = len(_vs.graph.nodes) > 0 ? _vs.graph.nodes[0].uid : 0
			_vs.active_domain           = _vs.graph.domain == .Material_Shader ? .Gameplay_Ability : _vs.graph.domain
			_vs.active_subgraph[0]      = 0
			_vs.show_all_subgraph_nodes = true
			_vs.nav_hist_len           = 0
			_vs.nav_hist_cursor        = 0
			_vs.proc_rename_uid        = 0
			_vs.del_rename_idx         = -1
			nc.canvas_clear_selection(&_vs.canvas)
			if len(_vs.graph.nodes) > 0 do nc.canvas_set_selected(&_vs.canvas, 0, true)
			vs_clear_undo()
			_sync_ide_blueprint_context()
		}
	}
	wnd.open("mh_visual_script")
	return true
}

// Creates a fresh Event-Driven Blueprint `.bodin` (single-file Odin + `@BODIN_GRAPH_V1` layout,
// with `Event_Init` -> `Bind_Input_Action` -> `On_Action` ready to wire!), syncs its hot cartridge
// module, triggers hot-swap, and returns `(rel_path, compiled_proc_name, ok)`!
create_new_blueprint_asset :: proc(blueprint_name: string) -> (rel_path: string, proc_name: string, ok: bool) {
	ensure_visual_script_init()
	clean := sanitize_odin_ident(strings.trim_space(blueprint_name), context.temp_allocator)
	if clean == "" do return "", "", false

	target_dom := _vs.active_domain == .Material_Shader ? engine.VG_Graph_Domain.Gameplay_Ability : _vs.active_domain
	rel := fmt.tprintf("assets/scripts/%s.bodin", clean)
	{
		context.allocator = runtime.default_allocator()
		engine.vg_destroy_graph(&_vs.graph)
		_vs.graph = {
			name     = strings.clone(clean),
			domain   = target_dom,
			next_uid = 1,
		}
		for sp in ([3]string{"self", "hot", "math"}) {
			append(&_vs.graph.using_spaces, strings.clone(sp))
		}
		append(&_vs.graph.variables, engine.VG_Var_Decl{
			name              = strings.clone("impulse_strength"),
			pin_type          = .Float,
			default_f32       = 4.5,
			instance_editable = true,
			category          = strings.clone("Gameplay"),
			tooltip_text      = strings.clone("Impulse height applied when the bound input action fires"),
			slider_min        = 0.0,
			slider_max        = 20.0,
		})

		u_init := engine.vg_add_node(&_vs.graph, .Event_Init,         {40, 80})
		u_bind := engine.vg_add_node(&_vs.graph, .Bind_Input_Action,  {380, 80},  "Jump")
		u_proc := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry,  {40, 320},  "On_Jump")
		u_code := engine.vg_add_node(&_vs.graph, .Odin_Function_Node, {420, 320})

		if bnode := engine.vg_find_node(&_vs.graph, u_bind); bnode != nil {
			bnode.hot_proc_target = strings.clone("On_Jump")
		}
		if cnode := engine.vg_find_node(&_vs.graph, u_code); cnode != nil {
			delete(cnode.title)
			cnode.title = strings.clone("Apply Jump Impulse (using self)")
			delete(cnode.odin_body)
			cnode.odin_body = strings.clone("// Applies upward impulse using Blueprint variable `impulse_strength`\nif p := hot.pos_ref(api, self); p != nil {\n    p.y += impulse_strength * 0.25\n}")
		}

		append(&_vs.graph.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_bind, to_pin = 0})
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 0, to_uid = u_bind, to_pin = 1})
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 1, to_uid = u_code, to_pin = 0})
		engine.vg_infer_missing_owner_procs(&_vs.graph)

		if _vs.graph_rel_path != "" do delete(_vs.graph_rel_path)
		_vs.graph_rel_path         = strings.clone(rel)
		_vs.selected_node_uid      = u_bind
		_vs.selected_var_idx       = -1
		_vs.preview_bb.initialized = false
		_vs.active_subgraph[0]      = 0
		_vs.show_all_subgraph_nodes = true
		_vs.nav_hist_len           = 0
		_vs.nav_hist_cursor        = 0
		_vs.proc_rename_uid        = 0
		_vs.del_rename_idx         = -1
		nc.canvas_clear_selection(&_vs.canvas)
		nc.canvas_set_selected(&_vs.canvas, 1, true)
		vs_clear_undo()
	}

	gen_abs, main_proc, baked_ok := bake_graph_to_odin_file(&_vs.graph, _vs.graph_rel_path)
	if !baked_ok do return "", "", false
	{
		context.allocator = runtime.default_allocator()
		if _vs.last_baked_odin != "" do delete(_vs.last_baked_odin)
		_vs.last_baked_odin = strings.clone(gen_abs)
		_vs.dirty_unbaked   = false
	}
	_rescan_blueprint_assets()
	_sync_ide_blueprint_context()
	engine.hot_cartridge_trigger_async_build(true)
	return rel, main_proc, true
}

@(private)
_pin_color :: proc(p: engine.VG_Pin_Def) -> im.Vec4 {
	return thm.studio_pin_color(p.pin_type, p.pass_mode == .By_Reference || p.is_addressable)
}

@(private)
_node_category_and_color :: proc(k: engine.VG_Node_Kind, hint: string = "") -> (cat: cstring, col: im.Vec4) {
	ns := vg_node_namespace(k, hint)
	badge, accent := vg_namespace_style(ns)
	if k == .Custom_Proc_Entry || k == .Delegate_Bind || k == .Delegate_Unbind || k == .Delegate_Broadcast {
		return fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, badge), accent
	}
	return fmt.ctprintf("%s", badge), accent
}

// Resolves stationary hover documentation for any graph node or palette kind, reusing IDE `//`
// doc-comments written above `@(hot_proc)` declarations and leading `//` lines in Scoped Odin nodes!
@(private)
_kind_builtin_doc :: proc(k: engine.VG_Node_Kind) -> string {
	switch k {
	case .Event_Init:
		return "Fires once when the entity spawns or enters Play Mode.\nIdeal place to wire Bind Input Action / Delegate Bind!\nRuntime Cost: 0.00 ms per frame after initialization."
	case .Event_Tick:
		return "Opt-In Per-Frame Update.\nOmitting this node makes the entire Blueprint 100% Event-Driven (0.00 ns idle CPU cost)!"
	case .Event_Destroy:
		return "Fires when the entity or VisualScriptRunner is destroyed.\nNote: Bound inputs & delegates also auto-clean on teardown."
	case .Custom_Proc_Entry:
		return "Defines a reusable Data-Oriented Odin Procedure (`Hot_Delegate`).\nConnect its cyan Delegate pin into Bind Input Action or Delegate Bind!"
	case .Call_Blueprint_Proc:
		return "Synchronously invokes a Custom Procedure defined in this graph."
	case .Bind_Input_Action:
		return "Registers a prioritized listener on `input_manager` for the selected Action and Trigger Edge.\nHigher Priority listeners execute first and can optionally Consume the input."
	case .Unbind_Input_Action:
		return "Dynamically releases this entity's binding for the selected Input Action at runtime (e.g. swapping abilities or entering vehicles)."
	case .Bind_Input_Vector:
		return "Binds a 2D movement or look/aim axis (`[2]f32`) from `input_manager` to a Blueprint Procedure with listener priority."
	case .Unbind_Input_Vector:
		return "Releases this entity's Move or Look `[2]f32` vector binding."
	case .Bind_Debug_Key:
		return "[DEV] Binds a raw keyboard scancode directly to a Blueprint Procedure for rapid prototyping."
	case .Unbind_Debug_Key:
		return "[DEV] Releases a raw keyboard scancode debug binding."
	case .Unbind_All_Inputs:
		return "Releases all input actions, vectors, and debug keys currently bound by `self`."
	case .Delegate_Bind:
		return "Appends a Blueprint Procedure (`Hot_Delegate`) to a named Odin Delegate signal."
	case .Delegate_Unbind:
		return "Clears listeners bound to the selected Odin Delegate signal."
	case .Delegate_Broadcast:
		return "Broadcasts a payload to every Procedure currently bound to this Odin Delegate."
	case .Get_Variable:
		return "Reads a `using self` Blueprint Variable — exposes both a safe Value Copy (`T`) and an addressable Mutable Reference (`^T`)."
	case .Set_Variable:
		return "Writes a new value into a `using self` Blueprint Variable."
	case .Get_Transform_Pos:
		return "Reads the entity's world/local Transform position (`Copy` + addressable `^Vec3` reference)."
	case .Set_Transform_Pos:
		return "Sets the entity's Transform position in `[3]f32` world/local coordinates."
	case .Math_Float:
		return "Inline native Odin scalar math (`Add`, `Sub`, `Mul`, `Div`, `Sin Wave`, `Exp Damp`)."
	case .Vec3_Scale_Add:
		return "Computes `Base + Axis * Scale` in native `[3]f32` SIMD-friendly Odin math."
	case .Branch_If:
		return "Conditional execution branch (`True` vs `False` exec flow) [B+Click]."
	case .Sequence:
		return "Executes output pins `Then 0`, `Then 1`, ... strictly in top-to-bottom order [S+Click]."
	case .For_Loop:
		return "Inclusive integer loop from First Index to Last Index, firing Loop Body per index then Completed [F+Click]."
	case .Set_Time_Scale:
		return "Modulates per-object TimeScale (hitstop / local bullet-time) or global simulation TimeScale."
	case .Call_Hot_Proc:
		return "Calls a native `@(hot_proc)` Odin procedure compiled into `hot_cartridge.dll`."
	case .Odin_Function_Node:
		return "Inline Scoped Odin Procedure Node (`using self`).\nDouble-click header or click `</>` to edit in the Popup Micro-IDE!"
	case .Anim_Clip_Eval:
		return "[Unified Anim Domain] Advances and evaluates normalized clip phase & pose weight on the native Odin VM (no separate AnimBP VM!)."
	case .Anim_Blend_Layered:
		return "[Unified Anim Domain] Blends Base & Layer channels by Alpha (`lerp(base, layer, clamp(alpha, 0, 1))`)."
	case .Anim_Spring_Damper:
		return "[Unified Anim Domain] Framerate-independent damped harmonic spring toward Target."
	case .Anim_IK_Target:
		return "[Unified Anim Domain] Solves blended Two-Bone / Effector IK target position."
	case .VFX_Emitter_Spawn:
		return "[Unified VFX Domain] Accumulates `Rate * dt + Burst` and outputs integer spawn count for this frame."
	case .VFX_GPU_Curl_Force:
		return "[Unified VFX GPU Stage] Evaluates trigonometric curl turbulence + velocity drag (CPU preview & GPU compute-compatible math)."
	case .VFX_Color_Size_Life:
		return "[Unified VFX Domain] Evaluates particle size & emissive curve over normalized age `[0..1]`."
	case .Audio_Random_Container:
		return "[Audio SoundScape] Selects a randomized sound index `[0..Count-1]` from Seed without repeating boilerplate."
	case .Audio_Modulate_Pitch_Vol:
		return "[Audio SoundScape] Jitters base pitch/volume symmetrically by `+-Range` from Seed."
	case .Audio_Bus_Send:
		return "[Audio SoundScape] Drives an Audio Submix Bus volume & 2-pole Biquad low-pass filter cutoff (Hz)."
	case .Audio_Play_Spatial_3D:
		return "[Audio SoundScape] Triggers a spatialized 3D audio cue with occlusion and pitch/volume modulation."
	case .AI_Find_Path_Move:
		return "[AI Navigation] Computes a multi-core baked NavMesh A* path to Target Pos and steers NavMeshAgent."
	case .AI_Check_Arrival:
		return "[AI Navigation] Returns true once the entity's NavMeshAgent has reached its destination within Tolerance."
	case .Break_Loop:
		return "[Flow Loop] Immediately breaks out of the enclosing For Loop (`break`)."
	case .Continue_Loop:
		return "[Flow Loop] Skips the remainder of the current iteration and continues the enclosing For Loop (`continue`)."
	case .Switch_Value:
		return "[Odin Switch] Multi-pin branch over all declared `enum u8` variants or integer cases (zero missing cases!)."
	case .BitSet_Op:
		return "[Odin BitSet] Sets, clears, toggles, or tests bit flags in a compact 1-byte `bit_set[Enum; u8]` mask."
	case .Make_Struct:
		return "[Odin POD Struct] Packs fields (including flattened `using` parent fields) into a value-type struct."
	case .Break_Struct:
		return "[Odin POD Struct] Unpacks every field (including `using` parent fields) from a value-type struct."
	case .Array_Op:
		return "[Odin Array] Indexed Copy (`T`), Mutable Pointer (`^T`), `Len`, `Set`, or `Bounded_Array` `Append`/`Pop`/`Swap_Remove`/`Clear`."
	case .Defer_Exec:
		return "[Odin Defer] Runs primary `Exec` first, then guarantees `Deferred Cleanup` runs on scope exit in LIFO order."
	case .Or_Branch:
		return "[Odin Error Idiom] Checks `(Value, Ok)` — routes `Valid` when `ok`, or handles fallback on `Failed`."
	case .Auto_Cast:
		return "[Odin Explicit Cast] Auto-inserted typed conversion pill between compatible scalar/vector widths (`T(val)`)."
	case .Reroute_Knot:
		return "[Wire Reroute] Clean pass-through knot keeping complex Exec and Data wiring readable."
	case .Delay_Timer:
		return "[Async Timer] Fires `Active` immediately and fires `Completed` once `Duration` seconds elapse."
	case .Cooldown_Gate:
		return "[Ability Gate] Fires `Ready` and enters cooldown when off timer, or routes `Blocked` with `Remaining` time."
	case .Spawn_Prefab:
		return "[World Bridge] Spawns a Prefab entity at `Pos` and `Rot` via `Engine_Hot_API`."
	case .Destroy_Entity:
		return "[World Bridge] Safely queues `Target` entity for destruction at end of frame."
	case .Physics_Raycast:
		return "[Physics3D Bridge] Casts a masked ray from `Origin` along `Dir` returning `Hit`, `Point`, `Normal`, `Dist`, and `Entity`."
	case .Physics_Overlap_Sphere:
		return "[Physics3D Bridge] Queries physics colliders inside a sphere returning `Count` and `Closest Entity`."
	case .Physics_Add_Impulse:
		return "[Physics3D Bridge] Applies an instant impulse or velocity change to `Target`'s Rigidbody."
	case .Event_On_Trigger:
		return "[Physics3D Event] Fires whenever another physics entity enters this trigger collider (`Other Entity`)."
	case .CSG_Brush_Stamp:
		return "[CAD CSG Bridge] Stamps a runtime blast/cut modifier at `World Pos` within `Radius`."
	}
	return ""
}

@(private)
_active_debug_bb :: proc() -> (^engine.VG_Runtime_Blackboard, engine.Transform_Handle) {
	if bb := engine.visual_script_get_entity_bb(_vs.preview_entity); bb != nil {
		return bb, _vs.preview_entity
	}
	if _vs.preview_bb.initialized {
		return &_vs.preview_bb, _vs.preview_entity
	}
	return nil, _vs.preview_entity
}

@(private)
_format_live_slot :: proc(slot: hot.Hot_Slot) -> string {
	#partial switch slot.pin_type {
	case .Bool:       return slot.val_bool ? "true" : "false"
	case .U8:         return fmt.tprintf("%d (u8)", slot.val_u8)
	case .I8:         return fmt.tprintf("%d (i8)", slot.val_i8)
	case .U16:        return fmt.tprintf("%d (u16)", slot.val_u16)
	case .I16:        return fmt.tprintf("%d (i16)", slot.val_i16)
	case .Int:        return fmt.tprintf("%d", slot.val_int)
	case .U32:        return fmt.tprintf("%d (u32)", slot.val_u32)
	case .Int64:      return fmt.tprintf("%d (i64)", slot.val_i64)
	case .U64:        return fmt.tprintf("%d (u64)", slot.val_u64)
	case .Float:      return fmt.tprintf("%.3f", slot.val_f32)
	case .F64:        return fmt.tprintf("%.4f", slot.val_f64)
	case .Vec2:       return fmt.tprintf("{%.2f, %.2f}", slot.val_vec2.x, slot.val_vec2.y)
	case .Vec3:       return fmt.tprintf("{%.2f, %.2f, %.2f}", slot.val_vec3.x, slot.val_vec3.y, slot.val_vec3.z)
	case .Vec4, .Quat:return fmt.tprintf("{%.2f, %.2f, %.2f, %.2f}", slot.val_vec4.x, slot.val_vec4.y, slot.val_vec4.z, slot.val_vec4.w)
	case .Entity:     return fmt.tprintf("Entity(#%d)", slot.val_ent.index)
	case .Enum_U8:    return fmt.tprintf("#%d (enum u8)", slot.val_u8)
	case .BitSet_U8:  return fmt.tprintf("0x%02x (bit_set)", slot.val_u8)
	}
	return "..."
}

@(private)
_resolve_node_doc_tooltip :: proc(n: ^engine.VG_Node, allocator := context.temp_allocator) -> string {
	if n == nil do return ""

	// 1. `@(bp_node)` / `@(hot_proc)` Node -> Reuse AST / `//` doc-comments written above the Odin procedure!
	if n.kind == .Call_Hot_Proc && n.hot_proc_target != "" {
		if meta, ok := engine.hot_proc_find_sig_meta(n.hot_proc_target); ok && meta.doc_comment != "" {
			src_nm := meta.source_proc_name != "" ? meta.source_proc_name : meta.proc_name
			return fmt.tprintf("@(bp_node) %s\n\n%s\n\n(Double-click header to view Odin proc)", src_nm, meta.doc_comment)
		}
		doc := ""
		src_file := "haati/hot_scripts/builtin_hot_scripts.odin"
		for he in engine.hot_proc_entries() {
			if he.name == n.hot_proc_target && he.source_file != "" {
				src_file = he.source_file
				break
			}
		}
		doc = cs.extract_odin_proc_doc_from_file(src_file, n.hot_proc_target, allocator)
		if doc != "" {
			return fmt.tprintf("@(hot_proc) %s\n\n%s\n\n(Double-click header to open in Scoped Odin Micro-IDE)", n.hot_proc_target, doc)
		}
	}

	// 2. Scoped Odin Function Node -> Reuse leading `//` doc-comment lines inside `n.odin_body`!
	if n.kind == .Odin_Function_Node && n.odin_body != "" {
		db := strings.builder_make(0, 128, allocator)
		for raw_ln in strings.split_lines(n.odin_body, context.temp_allocator) {
			trimmed := strings.trim_space(strings.trim_suffix(raw_ln, "\r"))
			if strings.has_prefix(trimmed, "//") {
				clean := strings.trim_space(strings.trim_prefix(trimmed, "//"))
				if clean != "" {
					if strings.builder_len(db) > 0 do strings.write_byte(&db, '\n')
					strings.write_string(&db, clean)
				}
			} else if trimmed == "" {
				continue
			} else {
				break
			}
		}
		if strings.builder_len(db) > 0 {
			return fmt.tprintf("%s\n\n%s\n\n(Double-click header or click </> to edit Odin code)", n.title, strings.to_string(db))
		}
	}

	// 3. Blueprint Variable Get/Set -> Show designer `tooltip_text` if authored on the variable!
	if (n.kind == .Get_Variable || n.kind == .Set_Variable) && n.var_name != "" {
		if vi := engine.vg_find_var_index(&_vs.graph, n.var_name); vi >= 0 {
			v := _vs.graph.variables[vi]
			if v.tooltip_text != "" {
				return fmt.tprintf("%s (%s : %s)\n\n%s", n.title, v.name, engine.vg_pin_odin_type(v.pin_type, v.is_array), v.tooltip_text)
			}
		}
	}

	// 4. Built-in technical documentation
	base_doc := _kind_builtin_doc(n.kind)
	if base_doc != "" {
		return fmt.tprintf("%s\n\n%s", n.title, base_doc)
	}
	return n.title
}

// Draws all 4 distinct vector pin shapes on the DrawList:
//   - Exec Triangle
//   - Odin Delegate Hollow Double-Ring Diamond (`Hot_Delegate`)
//   - Mutable Reference (`^T`) Filled Diamond
//   - Value Copy (`T`) Circle
@(private)
_draw_typed_pin :: proc(dl: ^im.DrawList, pt: im.Vec2, pdef: engine.VG_Pin_Def, hovered: bool, connected: bool, zoom: f32) {
	col := _pin_color(pdef)
	r   := (hovered ? 6.6 : 5.2) * clamp(zoom, 0.5, 2.0)
	bg  := im.GetColorU32ImVec4(thm.studio_tokens().pin_socket_bg)
	fg  := im.GetColorU32ImVec4(col)

	if hovered {
		im.DrawList_AddCircleFilled(dl, pt, r + 4.2 * zoom, im.GetColorU32ImVec4(thm.with_alpha(col, 0.32)))
	}

	if pdef.pin_type == .Exec {
		p0 := im.Vec2{pt.x - r * 0.75, pt.y - r * 0.85}
		p1 := im.Vec2{pt.x + r * 0.95, pt.y}
		p2 := im.Vec2{pt.x - r * 0.75, pt.y + r * 0.85}
		im.DrawList_AddTriangleFilled(dl, p0, p1, p2, connected ? fg : bg)
		im.DrawList_AddTriangle(dl, p0, p1, p2, fg, 1.6 * zoom)
	} else if pdef.pin_type == .Delegate {
		d  := r * 1.18
		q0 := im.Vec2{pt.x, pt.y - d}
		q1 := im.Vec2{pt.x + d, pt.y}
		q2 := im.Vec2{pt.x, pt.y + d}
		q3 := im.Vec2{pt.x - d, pt.y}
		im.DrawList_AddQuadFilled(dl, q0, q1, q2, q3, bg)
		im.DrawList_AddQuad(dl, q0, q1, q2, q3, fg, 2.0 * zoom)
		if connected {
			im.DrawList_AddCircleFilled(dl, pt, r * 0.44, fg)
		}
	} else if pdef.pass_mode == .By_Reference || pdef.is_addressable {
		d  := r * 1.08
		q0 := im.Vec2{pt.x, pt.y - d}
		q1 := im.Vec2{pt.x + d, pt.y}
		q2 := im.Vec2{pt.x, pt.y + d}
		q3 := im.Vec2{pt.x - d, pt.y}
		im.DrawList_AddQuadFilled(dl, q0, q1, q2, q3, connected ? fg : bg)
		im.DrawList_AddQuad(dl, q0, q1, q2, q3, fg, 1.8 * zoom)
	} else {
		nc.canvas_draw_port(dl, pt, col, hovered, false, connected, zoom)
	}
}

@(private)
_on_scoped_node_commit :: proc(node_uid: int, updated_body: string, trigger_hot_swap: bool, _user_ptr: rawptr) {
	context.allocator = runtime.default_allocator()
	if n := engine.vg_find_node(&_vs.graph, node_uid); n != nil {
		if n.odin_body != updated_body {
			vs_push_undo()
		}
		delete(n.odin_body)
		n.odin_body = strings.clone(updated_body)
		_vs.dirty_unbaked = true
	}
	if trigger_hot_swap || _vs.auto_bake_on_save {
		_bake_and_hot_swap_current_graph()
	}
}

collect_node_scoped_pin_badges :: proc(
	g: ^engine.Visual_Graph,
	n: ^engine.VG_Node,
	allocator := context.temp_allocator,
) -> []cs.Scoped_Pin_Badge {
	badges := make([dynamic]cs.Scoped_Pin_Badge, allocator)
	for p in n.inputs {
		if p.pin_type == .Exec || p.pin_type == .Delegate do continue
		append(&badges, cs.Scoped_Pin_Badge{
			name      = p.name,
			odin_type = _pin_odin_type_in_graph(g, p, allocator),
			pass_mode = p.pass_mode,
			is_output = false,
		})
	}
	for p in n.outputs {
		if p.pin_type == .Exec || p.pin_type == .Delegate do continue
		append(&badges, cs.Scoped_Pin_Badge{
			name      = p.name,
			odin_type = _pin_odin_type_in_graph(g, p, allocator),
			pass_mode = .Copy_Value,
			is_output = n.kind != .Custom_Proc_Entry,
		})
	}
	return badges[:]
}

@(private)
_open_odin_node_in_popup_ide :: proc(n: ^engine.VG_Node) {
	_sync_ide_blueprint_context()
	badges := collect_node_scoped_pin_badges(&_vs.graph, n, context.temp_allocator)
	sig := build_scoped_node_signature(n, &_vs.graph, context.temp_allocator)
	cs.open_scoped_node_popup(n.uid, n.title, sig, badges, n.odin_body, _on_scoped_node_commit, nil)
}

@(private)
_bake_and_hot_swap_current_graph :: proc() {
	if gen_abs, _, ok := bake_graph_to_odin_file(&_vs.graph, _vs.graph_rel_path); ok {
		context.allocator = runtime.default_allocator()
		if _vs.last_baked_odin != "" do delete(_vs.last_baked_odin)
		_vs.last_baked_odin = strings.clone(gen_abs)
		_vs.dirty_unbaked   = false
		_sync_ide_blueprint_context()
		engine.hot_cartridge_trigger_async_build(true)
	}
}

@(private)
_focus_canvas_on_node :: proc(n: ^engine.VG_Node) {
	if n == nil do return
	_vs.selected_node_uid = n.uid
	_vs.selected_var_idx  = -1
	nc.canvas_clear_selection(&_vs.canvas)
	for check_n, idx in _vs.graph.nodes {
		if check_n.uid == n.uid {
			nc.canvas_set_selected(&_vs.canvas, idx, true)
			break
		}
	}
	if _vs.canvas.size.x > 40 && _vs.canvas.size.y > 40 {
		zm := max(_vs.canvas.zoom, 0.25)
		_vs.canvas.pan = (_vs.canvas.size * 0.35) / zm - im.Vec2{n.pos.x, n.pos.y}
	}
}

@(private)
_debug_key_label :: proc(code: i32) -> cstring {
	for preset in _DEBUG_KEY_PRESETS {
		if preset.code == code do return preset.label
	}
	return fmt.ctprintf("Key#%d", code)
}

@(private)
_delete_node_by_uid :: proc(uid: int, push_undo := true) {
	if uid <= 0 do return
	if engine.vg_find_node(&_vs.graph, uid) == nil do return
	if push_undo do vs_push_undo()
	context.allocator = runtime.default_allocator()
	for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
		w := _vs.graph.wires[wi]
		if w.from_uid == uid || w.to_uid == uid {
			ordered_remove(&_vs.graph.wires, wi)
		}
	}
	for ni := len(_vs.graph.nodes) - 1; ni >= 0; ni -= 1 {
		if _vs.graph.nodes[ni].uid == uid {
			engine.vg_destroy_node(&_vs.graph.nodes[ni])
			ordered_remove(&_vs.graph.nodes, ni)
			break
		}
	}
	if _vs.selected_node_uid == uid do _vs.selected_node_uid = 0
	nc.canvas_clear_selection(&_vs.canvas)
	_vs.dirty_unbaked = true
	_sync_ide_blueprint_context()
}

// Deletes all currently selected visible graph nodes (`_vs.canvas` multi-selection + `_vs.selected_node_uid`).
@(private)
_delete_selected_graph_nodes :: proc() -> int {
	uids := make([dynamic]int, 0, 8, context.temp_allocator)
	for &n, ni in _vs.graph.nodes {
		if !_is_node_visible_in_subgraph(&n) do continue
		if nc.canvas_is_selected(&_vs.canvas, ni) || n.uid == _vs.selected_node_uid {
			already := false
			for u in uids do if u == n.uid { already = true; break }
			if !already do append(&uids, n.uid)
		}
	}
	if len(uids) > 0 {
		vs_push_undo()
	}
	for uid in uids {
		_delete_node_by_uid(uid, false)
	}
	nc.canvas_clear_selection(&_vs.canvas)
	_vs.selected_node_uid = 0
	return len(uids)
}

// =============================================================================
// Top Domain Filter Bar + Asset / Hot-Swap Toolbar
// =============================================================================

@(private)
_draw_unified_domain_switcher_bar :: proc() {
	p  := thm.palette()
	st := thm.studio_tokens()
	im.TextDisabled("Studio Mode:")
	im.SameLine(0, 6)

	bp_tint := st.domain_blueprint
	im.PushStyleColorImVec4(.Button,        thm.with_alpha(bp_tint, 0.38))
	im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(bp_tint, 0.48))
	im.PushStyleColorImVec4(.ButtonActive,  thm.with_alpha(bp_tint, 0.58))
	im.PushStyleColorImVec4(.Text,          st.pill_active_text)
	if im.Button(fmt.ctprintf("%s Blueprint Graph (.bodin)", icons.ICON_MD_ACCOUNT_TREE)) {
		if _vs.graph.domain != .Material_Shader {
			_vs.active_domain = _vs.graph.domain
		} else {
			_vs.active_domain = .Gameplay_Ability
		}
	}
	im.PopStyleColor(4)
	widgets.tooltip("Native Data-Oriented Odin Blueprint Studio (.bodin) — Events, Flow, Input, Delegates, Anim, VFX, and Audio")

	// Right-side Undo/Redo + Persistent Global Wire Style Dropdown + Editor Defaults shortcut
	right_group_w := f32(286.0)
	if im.GetContentRegionAvail().x > right_group_w {
		im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - right_group_w)
	} else {
		im.NewLine()
	}

	im.BeginDisabled(!vs_can_undo())
	if im.Button(fmt.ctprintf("%s Undo", icons.ICON_MD_UNDO)) {
		vs_undo()
	}
	im.EndDisabled()
	widgets.tooltip("Undo (Ctrl+Z)")
	im.SameLine(0, 4)

	im.BeginDisabled(!vs_can_redo())
	if im.Button(fmt.ctprintf("%s Redo", icons.ICON_MD_REDO)) {
		vs_redo()
	}
	im.EndDisabled()
	widgets.tooltip("Redo (Ctrl+Shift+Z / Ctrl+Y)")
	im.SameLine(0, 6)

	nc.draw_wire_style_combo("##ug_global_wire_style", 118.0)
	_vs.canvas.wire_style = nc.global_wire_style
	im.SameLine(0, 6)
	if im.Button(fmt.ctprintf("%s##ug_defs", icons.ICON_MD_SETTINGS)) {
		wnd.open_settings_tab("Code & Script IDE")
	}
	widgets.tooltip("Open Settings -> Code & Script IDE (Wire routing style, problem check delay, external IDE & per-pane zooms)")
	_ = p
}

@(private)
_Palette_Item :: struct {
	ns:           VG_Namespace,
	label:        string,
	kind:         engine.VG_Node_Kind,
	arg:          string,
	is_hot:       bool,
	hot_file:     string,
	hot_name:     string,
	doc_override: string,
	compat_pin:   int,
}

@(private)
_collect_palette_items :: proc(allocator := context.temp_allocator) -> [dynamic]_Palette_Item {
	items := make([dynamic]_Palette_Item, 0, len(_PALETTE_CATALOG) + 32, allocator)
	for spec in _PALETTE_CATALOG {
		hint := spec.arg != "" ? spec.arg : spec.label
		append(&items, _Palette_Item{
			ns         = vg_node_namespace(spec.kind, hint),
			label      = spec.label,
			kind       = spec.kind,
			arg        = spec.arg,
			compat_pin = -1,
		})
	}
	for cn in _vs.graph.nodes {
		if cn.kind == .Custom_Proc_Entry && cn.hot_proc_target != "" {
			append(&items, _Palette_Item{
				ns         = .Flow,
				label      = fmt.tprintf("%s Call Graph Proc %s()", icons.ICON_MD_DIAMOND, cn.hot_proc_target),
				kind       = .Call_Blueprint_Proc,
				arg        = cn.hot_proc_target,
				compat_pin = -1,
			})
		}
	}
	for meta in engine.hot_proc_all_sig_metas() {
		src_f := ""
		if he, hok := cs.resolve_hot_proc_info(meta.proc_name); hok {
			src_f = he.source_file
		}
		append(&items, _Palette_Item{
			ns           = vg_node_namespace(.Call_Hot_Proc, meta.namespace_name != "" ? meta.namespace_name : meta.display_title),
			label        = fmt.tprintf("%s @(bp_node) %s", icons.ICON_MD_BOLT, meta.display_title != "" ? meta.display_title : meta.proc_name),
			kind         = .Call_Hot_Proc,
			arg          = meta.proc_name,
			is_hot       = true,
			hot_file     = src_f,
			hot_name     = meta.source_proc_name != "" ? meta.source_proc_name : meta.proc_name,
			doc_override = meta.doc_comment,
			compat_pin   = -1,
		})
	}
	for hp in engine.hot_proc_entries() {
		if strings.has_prefix(hp.name, "__bpwrap_") do continue
		if _, has_sig := engine.hot_proc_find_sig_meta(hp.name); has_sig do continue
		append(&items, _Palette_Item{
			ns         = vg_node_namespace(.Call_Hot_Proc, hp.name),
			label      = fmt.tprintf("%s Call @(hot_proc) %s", icons.ICON_MD_BOLT, hp.name),
			kind       = .Call_Hot_Proc,
			arg        = hp.name,
			is_hot     = true,
			hot_file   = hp.source_file,
			hot_name   = hp.name,
			compat_pin = -1,
		})
	}
	for s in _vs.graph.structs {
		append(&items, _Palette_Item{ns = .Variable, label = fmt.tprintf("Make %s (POD Struct)", s.name), kind = .Make_Struct, arg = s.name, compat_pin = -1})
		append(&items, _Palette_Item{ns = .Variable, label = fmt.tprintf("Break %s (POD Struct)", s.name), kind = .Break_Struct, arg = s.name, compat_pin = -1})
	}
	for e in _vs.graph.enums {
		append(&items, _Palette_Item{ns = .Flow, label = fmt.tprintf("Switch on %s (enum u8)", e.name), kind = .Switch_Value, arg = e.name, compat_pin = -1})
		append(&items, _Palette_Item{ns = .Math, label = fmt.tprintf("BitSet Op (%s)", e.name), kind = .BitSet_Op, arg = e.name, compat_pin = -1})
	}
	for v in _vs.graph.variables {
		append(&items, _Palette_Item{
			ns         = .Variable,
			label      = fmt.tprintf("Get `%s` (Copy & ^Ref)", v.name),
			kind       = .Get_Variable,
			arg        = v.name,
			compat_pin = -1,
		})
		append(&items, _Palette_Item{
			ns         = .Variable,
			label      = fmt.tprintf("Set `%s`", v.name),
			kind       = .Set_Variable,
			arg        = v.name,
			compat_pin = -1,
		})
		if v.is_array {
			append(&items, _Palette_Item{
				ns         = .Variable,
				label      = fmt.tprintf("Array Op `%s` (Get / Append / Len)", v.name),
				kind       = .Array_Op,
				arg        = v.name,
				compat_pin = -1,
			})
			append(&items, _Palette_Item{
				ns         = .Flow,
				label      = fmt.tprintf("For Elem in `%s`", v.name),
				kind       = .For_Loop,
				arg        = v.name,
				compat_pin = -1,
			})
		}
	}
	return items
}

@(private)
_draw_palette_item_menu :: proc(item: _Palette_Item, spawn_pos: [2]f32, show_badge: bool, auto_wire_pin_drop := false) -> bool {
	badge, accent := vg_namespace_style(item.ns)
	if show_badge {
		im.TextColored(accent, "[%s]", fmt.ctprintf("%s", badge))
		im.SameLine(0, 6)
	}
	clicked := im.MenuItem(fmt.ctprintf("%s##pal_%d_%s_%s_%v", item.label, int(item.kind), item.arg, badge, auto_wire_pin_drop))
	if item.doc_override != "" {
		widgets.tooltip_delayed(fmt.ctprintf("@(bp_node) %s\n\n%s", item.hot_name, item.doc_override))
	} else if item.is_hot {
		if im.IsItemHovered() {
			src_f := item.hot_file != "" ? item.hot_file : "haati/hot_scripts/builtin_hot_scripts.odin"
			doc := cs.extract_odin_proc_doc_from_file(src_f, item.hot_name, context.temp_allocator)
			if doc != "" {
				widgets.tooltip_delayed(fmt.ctprintf("@(hot_proc) %s\n\n%s", item.hot_name, doc))
			}
		}
	} else if tip := _kind_builtin_doc(item.kind); tip != "" {
		widgets.tooltip_delayed(fmt.ctprintf("%s", tip))
	}
	if clicked {
		arg := item.arg
		if item.kind == .Custom_Proc_Entry {
			arg = _next_unique_custom_event_name(arg != "" ? arg : "On_Custom_Event", context.temp_allocator)
		}
		adj_pos := spawn_pos
		if auto_wire_pin_drop && !_vs.pin_drop_from_out {
			adj_pos.x = max(spawn_pos.x - 280.0, 20.0)
		}
		uid := _spawn_graph_node(item.kind, adj_pos, arg)
		if auto_wire_pin_drop {
			if sn := engine.vg_find_node(&_vs.graph, uid); sn != nil {
				compat := engine.vg_find_compatible_pin_on_node(_vs.pin_drop_from_out, _vs.pin_drop_pin_def, sn)
				if compat >= 0 {
					from_uid := _vs.pin_drop_from_out ? _vs.pin_drop_from_uid : uid
					from_pin := _vs.pin_drop_from_out ? _vs.pin_drop_from_pin : compat
					to_uid   := _vs.pin_drop_from_out ? uid                   : _vs.pin_drop_from_uid
					to_pin   := _vs.pin_drop_from_out ? compat                : _vs.pin_drop_from_pin
					_connect_vg_wire_checked(from_uid, from_pin, to_uid, to_pin, push_undo = false)
				}
			}
		}
		if item.kind == .Odin_Function_Node {
			if nn := engine.vg_find_node(&_vs.graph, uid); nn != nil {
				_open_odin_node_in_popup_ide(nn)
			}
		}
		im.CloseCurrentPopup()
		return true
	}
	return false
}

@(private)
_draw_namespace_palette_filtered :: proc(
	items: []_Palette_Item,
	spawn_pos: [2]f32,
	q: string,
	only_compat: bool,
	auto_expand_max := 0,
	tree_prefix := "ns",
	auto_wire_pin_drop := false,
	empty_search_msg: cstring = "No matching BP_Nodes in any namespace.",
) -> (spawned: bool) {
	terms := widgets.search_terms(q)
	if len(terms) > 0 {
		matched := 0
		for item in items {
			if only_compat && item.compat_pin < 0 do continue
			badge, _ := vg_namespace_style(item.ns)
			search_hay := fmt.tprintf("%s %s %s %s", item.label, badge, item.hot_name, item.arg)
			if !widgets.search_match(search_hay, terms) do continue
			matched += 1
			if _draw_palette_item_menu(item, spawn_pos, true, auto_wire_pin_drop = auto_wire_pin_drop) {
				return true
			}
		}
		if matched == 0 {
			im.TextDisabledUnformatted(empty_search_msg)
		}
		return false
	}

	total_compat := 0
	if auto_expand_max > 0 {
		if only_compat {
			for it in items do if it.compat_pin >= 0 do total_compat += 1
		} else {
			total_compat = len(items)
		}
	}

	for ns in _NAMESPACE_PALETTE_ORDER {
		count := 0
		for item in items {
			if only_compat && item.compat_pin < 0 do continue
			if item.ns == ns do count += 1
		}
		if count == 0 do continue

		badge, accent := vg_namespace_style(ns)
		im.PushStyleColorImVec4(.Text, accent)
		if auto_expand_max > 0 {
			im.SetNextItemOpen(total_compat <= auto_expand_max, .Appearing)
		}
		hdr_lbl := fmt.ctprintf("%s  (%d)##%s_%d", badge, count, tree_prefix, int(ns))
		open := im.TreeNodeEx(hdr_lbl, {.SpanAvailWidth})
		im.PopStyleColor()
		if open {
			for item in items {
				if (only_compat && item.compat_pin < 0) || item.ns != ns do continue
				if _draw_palette_item_menu(item, spawn_pos, false, auto_wire_pin_drop = auto_wire_pin_drop) {
					im.TreePop()
					return true
				}
			}
			im.TreePop()
		}
	}
	return false
}

@(private)
_draw_namespace_node_palette :: proc(spawn_pos: [2]f32, q: string) -> (spawned: bool) {
	items := _collect_palette_items(context.temp_allocator)
	return _draw_namespace_palette_filtered(items[:], spawn_pos, q, only_compat = false)
}

@(private)
_enter_full_odin_script_mode :: proc() {
	if _, _, ok := bake_graph_to_odin_file(&_vs.graph, _vs.graph_rel_path); ok {
		cs.reload_file_tab_from_disk(_vs.graph_rel_path)
	}
	_vs.view_mode = .Full_Odin_Script
}

@(private)
_toolbar_wrap :: #force_inline proc(est_w: f32) {
	im.SameLine()
	if im.GetContentRegionAvail().x < est_w {
		im.NewLine()
	}
}

@(private)
_draw_blueprint_top_toolbar :: proc() {
	p := thm.palette()

	// 1. Blueprint Asset Switcher + `[ + New BP ]`
	cur_base := _vs.graph.name != "" ? _vs.graph.name : "Blueprint"
	im.SetNextItemWidth(168)
	if im.BeginCombo("##bp_asset_combo", fmt.ctprintf("Graph: %s", cur_base)) {
		for rel in _vs.discovered_graphs {
			is_sel := rel == _vs.graph_rel_path
			if im.Selectable(fmt.ctprintf("%s", filepath.base(rel)), is_sel) {
				open_blueprint_in_studio(rel)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Switch active `.bodin` / `.mhgraph` graph asset")

	_toolbar_wrap(95.0)
	if im.Button(fmt.ctprintf("%s + New", icons.ICON_MD_ADD)) {
		im.OpenPopup("##new_bp_popup")
	}
	widgets.tooltip("Create a new Event-Driven `.bodin` script (`assets/scripts/<name>.bodin`) — valid Odin code + visual graph layout in one file!")

	if im.BeginPopup("##new_bp_popup") {
		im.TextColored(p.accent, "Create New Unified .bodin Graph")
		im.SetNextItemWidth(220)
		im.InputTextWithHint("##new_bp_in", "e.g. player_dash_bp", cstring(raw_data(_vs.new_bp_name_buf[:])), len(_vs.new_bp_name_buf))
		if im.Button("Create & Bake .bodin", {-1, 0}) {
			nm := strings.trim_space(_c_str(_vs.new_bp_name_buf[:]))
			if nm != "" {
				if _, _, ok := create_new_blueprint_asset(nm); ok {
					_vs.new_bp_name_buf[0] = 0
					im.CloseCurrentPopup()
				}
			}
		}
		im.EndPopup()
	}

	// 2. Bake & Hot-Swap (`F7`) + Prominent 3-Way Hybrid View Switcher (`F12`)
	_toolbar_wrap(175.0)
	im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
	if im.Button(fmt.ctprintf("%s Bake & Hot-Swap (F7)", icons.ICON_MD_BOLT)) ||
	   (_vs.window_focused && im.IsKeyPressed(.F7, false)) {
		_bake_and_hot_swap_current_graph()
	}
	im.PopStyleColor()
	widgets.tooltip("Compiles this graph into flat Data-Oriented `.odin` (`using bp: ^State` + `@(hot_proc)` delegates) and hot-swaps `hot_cartridge_<N>.dll` (~240 ms)!")

	_toolbar_wrap(290.0)
	{
		mode_specs := [3]struct {
			m:   Studio_View_Mode,
			lbl: cstring,
			tip: cstring,
		}{
			{.Blueprint_Graph,    "Blueprint Graph",     "Full visual Blueprint node graph (F12 toggles Script)"},
			{.Split_Graph_And_Fn, "Split: Graph + Fn",   "Side-by-side / split node graph + live scoped Odin code editor for selected node/procedure"},
			{.Full_Odin_Script,   "Full .bodin Script",  "Open the full native .bodin Odin IDE source view (F12 returns to Graph)"},
		}
		for ms, mi in mode_specs {
			if mi > 0 do im.SameLine(0, 2)
			act := _vs.view_mode == ms.m
			im.PushStyleColorImVec4(.Button,        act ? thm.with_alpha(p.accent, 0.42) : thm.with_alpha(p.text_muted, 0.14))
			im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.accent, 0.54))
			if im.Button(ms.lbl) {
				if ms.m == .Full_Odin_Script {
					_enter_full_odin_script_mode()
				} else {
					_vs.view_mode = ms.m
				}
			}
			im.PopStyleColor(2)
			widgets.tooltip(ms.tip)
		}
	}

	io := im.GetIO()
	if _vs.window_focused && !io.WantTextInput && !im.IsAnyItemActive() && im.IsKeyPressed(.F12, false) {
		if _vs.view_mode == .Full_Odin_Script {
			_vs.view_mode = .Blueprint_Graph
		} else {
			_enter_full_odin_script_mode()
		}
	}

	// 3. `+ Odin BP_Node` & `+ Add BP_Node`
	_toolbar_wrap(128.0)
	if im.Button(fmt.ctprintf("%s + Odin BP_Node", icons.ICON_MD_CODE)) {
		new_uid := _spawn_graph_node(.Odin_Function_Node, _canvas_view_spawn_pos(0.42))
		if n := engine.vg_find_node(&_vs.graph, new_uid); n != nil {
			_open_odin_node_in_popup_ide(n)
		}
	}
	widgets.tooltip("Spawn a Scoped Odin BP_Node (`using self`, Copy `T`, Mutable `^Ref`) and open its Popup Micro-IDE [O+Click]")

	_toolbar_wrap(118.0)
	if im.Button(fmt.ctprintf("%s Add BP_Node", icons.ICON_MD_ADD_CIRCLE_OUTLINE)) {
		im.OpenPopup("##vs_toolbar_add_node_popup")
	}
	widgets.tooltip("Browse all Blueprint BP_Nodes, Anim, VFX, Audio, Math, Delegates & @hot_proc functions organized by Unreal-style Namespaces")
	if im.BeginPopup("##vs_toolbar_add_node_popup") {
		im.TextColored(p.accent, icons.ICON_MD_SEARCH + " Add BP_Node by Namespace")
		sr := widgets.search_bar(_vs.toolbar_add_search_buf[:], widgets.Search_Bar_Opts{
			id         = "##vs_tb_add_q",
			hint       = "Search nodes, namespaces, @hot_proc, variables...",
			mode       = .Popup,
			width      = 340,
			auto_focus = im.IsWindowAppearing(),
		})
		if sr.escape_close {
			im.CloseCurrentPopup()
		} else {
			im.Separator()
			center_c := _canvas_view_spawn_pos(0.42)
			if im.BeginChild("##vs_tb_add_scroll", {360, 290}) {
				_draw_namespace_node_palette(center_c, sr.query)
			}
			im.EndChild()
		}
		im.EndPopup()
	}

	// 4. Interactive `[ Using ▾ ]` Selector!
	_toolbar_wrap(105.0)
	if im.Button(fmt.ctprintf("%s Using (%d)", icons.ICON_MD_TUNE, len(_vs.graph.using_spaces))) {
		im.OpenPopup("##bp_using_popup")
	}
	widgets.tooltip("Select Odin `using` & package namespaces (`using self` Blueprint vars, `using math`, `using linalg`, `ease`, `rand`) — zero import guesswork!")

	if im.BeginPopup("##bp_using_popup") {
		im.TextColored(p.accent, icons.ICON_MD_CODE + " Blueprint Using & Spaces")
		sr := widgets.search_bar(_vs.using_search_buf[:], widgets.Search_Bar_Opts{
			id         = "##bp_us_q",
			hint       = "Search self, math, linalg, ease...",
			mode       = .Popup,
			width      = 260,
			auto_focus = im.IsWindowAppearing(),
		})
		if sr.escape_close {
			im.CloseCurrentPopup()
		} else {
			uterms := widgets.search_terms(sr.query)
			im.Separator()
			for spec in cs.USING_SPACE_CATALOG {
				if !spec.hot_safe do continue
				if len(uterms) > 0 && !widgets.search_match(fmt.tprintf("%s %s", spec.label, spec.description), uterms) {
					continue
				}
				active := engine.vg_has_using_space(&_vs.graph, spec.id)
				if im.MenuItem(fmt.ctprintf("%s %s", active ? icons.ICON_MD_CHECK : " ", spec.label)) {
					vs_push_undo()
					engine.vg_toggle_using_space(&_vs.graph, spec.id)
					_vs.dirty_unbaked = true
					_sync_ide_blueprint_context()
				}
				widgets.tooltip(fmt.ctprintf("%s", spec.description))
			}
		}
		im.EndPopup()
	}

	// 5. `[ Sim Input ▾ ]` Live Action / Debug-Key Tester + `[ .bodin ]`
	_toolbar_wrap(90.0)
	if im.Button("Sim Input") {
		im.OpenPopup("##bp_sim_input_popup")
	}
	widgets.tooltip("Fire a bound `input_manager` Action or `[DEV]` Debug Key right now to test your Delegate wires!")

	if im.BeginPopup("##bp_sim_input_popup") {
		im.TextColored(p.accent, "Fire Bound Input / Debug Event")
		im.Separator()
		for act in _merged_input_actions(context.temp_allocator) {
			if im.MenuItem(fmt.ctprintf("Fire Action: %s (Pressed)", act)) {
				engine.visual_script_fire_action_for_test(act, true)
			}
		}
		im.Separator()
		for kp in _DEBUG_KEY_PRESETS[:6] {
			if im.MenuItem(fmt.ctprintf("Fire [DEV] Key: %s", kp.label)) {
				engine.visual_script_fire_debug_key_for_test(int(kp.code), true)
			}
		}
		im.EndPopup()
	}

	_toolbar_wrap(82.0)
	if im.Button(fmt.ctprintf("%s .bodin", icons.ICON_MD_DESCRIPTION)) {
		if gen_abs, _, ok := bake_graph_to_odin_file(&_vs.graph, _vs.graph_rel_path); ok {
			context.allocator = runtime.default_allocator()
			if _vs.last_baked_odin != "" do delete(_vs.last_baked_odin)
			_vs.last_baked_odin = strings.clone(gen_abs)
		}
		target_open := _vs.last_baked_odin
		if strings.has_suffix(_vs.graph_rel_path, ".bodin") {
			bodin_abs := _vs_resolve_graph_path(_vs.graph_rel_path, context.temp_allocator)
			if os.exists(bodin_abs) do target_open = bodin_abs
		}
		if target_open != "" {
			cs.open_file_in_studio(target_open)
			wnd.open("odin_micro_studio")
		}
	}
	widgets.tooltip("Open this unified `.bodin` file (native Odin source on top + `@BODIN_GRAPH_V1` layout block below) in Odin Micro-Studio!")

	// 6. Runtime Cost & Hot-Swap Telemetry Badge
	_toolbar_wrap(210.0)
	bb, ent := _active_debug_bb()
	draw_runner_perf_and_fuse_status(&_vs.graph, bb, ent, inline = true, reset_btn_id = "Reset Loop Fuse")
}

draw_runner_perf_and_fuse_status :: proc(
	g: ^engine.Visual_Graph,
	bb: ^engine.VG_Runtime_Blackboard,
	ent: engine.Transform_Handle,
	inline := false,
	reset_btn_id: cstring = "Reset Loop Fuse##bp_fuse",
) {
	p := thm.palette()
	has_tick := engine.vg_has_tick_event(g)
	if !has_tick {
		im.TextColored(p.status_success, "%s", fmt.ctprintf("%s Event-Driven (0.00 ms Idle)", icons.ICON_MD_BOLT))
	} else {
		im.TextColored(p.status_warning, "%s", fmt.ctprintf("%s Opt-In Tick Active", icons.ICON_MD_SYNC))
	}
	widgets.tooltip("Omitting `Event: On Tick` makes this graph 100% Event-Driven (`0.00 ns` per-frame CPU cost when idle)!")

	if inline {
		hot_st, _, _, hot_msg, _ := engine.hot_cartridge_status()
		if _vs.dirty_unbaked {
			im.SameLine()
			im.TextColored(p.status_warning, "%s", fmt.ctprintf("| %s Live Preview (F7 to Bake)", icons.ICON_MD_CIRCLE))
		} else if hot_st != .Idle && hot_msg != "" {
			im.SameLine()
			im.TextColored(p.status_success, "%s", fmt.ctprintf("| %s %s", icons.ICON_MD_CHECK, hot_msg))
		}
	}
	if bb != nil && bb.loop_fuse_tripped_uid != 0 {
		if inline do im.SameLine()
		widgets.text_coloredf(p.status_error, "%s%s LOOP FUSE TRIPPED (#%d >= 10000)", inline ? "| " : "", icons.ICON_MD_WARNING, bb.loop_fuse_tripped_uid)
		im.SameLine()
		if im.SmallButton(reset_btn_id) {
			engine.visual_script_reset_loop_fuse(ent)
		}
	}
}

