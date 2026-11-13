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
import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
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

@(private = "file")
_Pin_Endpoint :: struct {
	node_uid: int,
	pin_idx:  int,
	is_out:   bool,
	screen_p: im.Vec2,
	pin_def:  engine.VG_Pin_Def,
}

@(private = "file")
_Debug_Key_Preset :: struct {
	label: cstring,
	code:  i32,
}

@(private = "file")
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

@(private = "file")
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

@(private = "file")
_Palette_Node_Spec :: struct {
	label:  string,
	kind:   engine.VG_Node_Kind,
	arg:    string,
	domain: engine.VG_Graph_Domain,
	shared: bool, // true = core Odin flow/math/delegate available across Gameplay, Anim & VFX
}

@(private = "file")
_PALETTE_CATALOG := [36]_Palette_Node_Spec{
	// Gameplay & Input Binding Domain
	{"[Input] Bind Input Action -> Procedure",              .Bind_Input_Action,   "Jump",            .Gameplay_Ability, false},
	{"[Input] Unbind Input Action (Dynamic Swap)",          .Unbind_Input_Action, "Jump",            .Gameplay_Ability, false},
	{"[Input] Bind Input Vector (Move / Look) -> Proc",     .Bind_Input_Vector,   "",                .Gameplay_Ability, false},
	{"[Input] Unbind Input Vector",                         .Unbind_Input_Vector, "",                .Gameplay_Ability, false},
	{"[DEV] Bind Debug Key (Scancode) -> Procedure",        .Bind_Debug_Key,      "",                .Gameplay_Ability, false},
	{"[DEV] Unbind Debug Key",                              .Unbind_Debug_Key,    "",                .Gameplay_Ability, false},
	{"[Input] Unbind All Inputs (Self)",                    .Unbind_All_Inputs,   "",                .Gameplay_Ability, false},
	{"[Time] Set Time Scale (Object / Global)",             .Set_Time_Scale,      "",                .Gameplay_Ability, false},
	{"[AI] Find Path & Move (NavMeshAgent)",                .AI_Find_Path_Move,   "",                .Gameplay_Ability, false},
	{"[AI] Check Arrival (NavMeshAgent)",                   .AI_Check_Arrival,    "",                .Gameplay_Ability, false},

	// Character Motion & Layered Anim Domain (Runs on same zero-overhead Odin VM!)
	{"[Anim] Evaluate Clip Pose / Phase",                   .Anim_Clip_Eval,      "Locomotion_Run",  .Anim_Motion,      false},
	{"[Anim] Layered Pose / Weight Blend",                  .Anim_Blend_Layered,  "",                .Anim_Motion,      false},
	{"[Anim] Second-Order Motion Spring Damper",            .Anim_Spring_Damper,  "",                .Anim_Motion,      false},
	{"[Anim] Two-Bone Procedural IK Target",                .Anim_IK_Target,      "Foot_L",          .Anim_Motion,      false},

	// Particle & On-GPU VFX Namespace
	{"[VFX] Emitter Continuous / Burst Spawn",              .VFX_Emitter_Spawn,   "Sparks",          .Particle_VFX,     false},
	{"[VFX GPU] SIMD Vector Curl & Drag Force",             .VFX_GPU_Curl_Force,  "",                .Particle_VFX,     false},
	{"[VFX] Color & Size Over Normalized Life",             .VFX_Color_Size_Life, "",                .Particle_VFX,     false},

	// Audio & Procedural SoundScape Domain (Domain #5)
	{"[Audio] Random Clip Container (Index)",               .Audio_Random_Container,   "",           .Audio_SoundScape, false},
	{"[Audio] Modulate Pitch / Volume (+/- Range)",         .Audio_Modulate_Pitch_Vol, "",           .Audio_SoundScape, false},
	{"[Audio] Submix Bus Send (Volume / Lowpass Hz)",       .Audio_Bus_Send,           "Music",      .Audio_SoundScape, false},
	{"[Audio] Play Spatial 3D Sound Cue",                   .Audio_Play_Spatial_3D,    "Cue_Impact", .Audio_SoundScape, false},

	// Shared Core Odin Lifecycle, Procedures, Delegates, Transform & Math
	{"[Proc] + Custom Procedure / Event Entry",             .Custom_Proc_Entry,   "On_Custom_Event", .Gameplay_Ability, true},
	{"[Delegate] Bind Custom Odin Delegate",                .Delegate_Bind,       "On_Signal",       .Gameplay_Ability, true},
	{"[Delegate] Unbind Custom Odin Delegate",              .Delegate_Unbind,     "On_Signal",       .Gameplay_Ability, true},
	{"[Delegate] Broadcast Custom Odin Delegate",           .Delegate_Broadcast,  "On_Signal",       .Gameplay_Ability, true},
	{"[Event] On Init (BeginPlay / Spawn)",                 .Event_Init,          "",                .Gameplay_Ability, true},
	{"[Event] On Tick (Opt-In Frame Update)",               .Event_Tick,          "",                .Gameplay_Ability, true},
	{"[Event] On Destroy (EndPlay Cleanup)",                .Event_Destroy,       "",                .Gameplay_Ability, true},
	{"[Odin] Scoped Odin BP_Node (`</>` + `using`)",     .Odin_Function_Node,  "",                .Gameplay_Ability, true},
	{"[Transform] Get Position (Copy & ^Ref)",              .Get_Transform_Pos,   "",                .Gameplay_Ability, true},
	{"[Transform] Set Position",                            .Set_Transform_Pos,   "",                .Gameplay_Ability, true},
	{"[Math] Float Math (Add / Mul / Sin / Damp)",          .Math_Float,          "",                .Gameplay_Ability, true},
	{"[Math] Vec3 + Axis * Scale",                          .Vec3_Scale_Add,      "",                .Gameplay_Ability, true},
	{"[Flow] Branch (If / Else) [B+Click]",                 .Branch_If,           "",                .Gameplay_Ability, true},
	{"[Flow] Sequence (Then 0..N) [S+Click]",               .Sequence,            "",                .Gameplay_Ability, true},
	{"[Flow] For Loop (First..Last) [F+Click]",             .For_Loop,            "",                .Gameplay_Ability, true},
}

Studio_View_Mode :: enum u8 {
	Blueprint_Graph    = 0,
	Split_Graph_And_Fn = 1,
	Full_Odin_Script   = 2,
}

// Unreal-inspired node Namespaces classifying all graph operations without redundant VM silos.
VG_Namespace :: enum u8 {
	Event     = 0,
	Flow      = 1,
	Input     = 2,
	Math      = 3,
	Transform = 4,
	Anim      = 5,
	VFX       = 6,
	Audio     = 7,
	AI        = 8,
	Delegate  = 9,
	Odin      = 10,
	Variable  = 11,
}

@(private = "file")
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
	graph_json: string,
	sel_uid:    int,
	sel_var:    int,
	subgraph:   string,
}

@(private = "file")
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

	// Unified Graph Studio Domain Content Filter & Focus State
	active_domain:          engine.VG_Graph_Domain,
	show_cross_domain:      bool,
	window_hovered:         bool,
	window_focused:         bool,
	mat_studio_draw_cb:     proc(),
	mat_studio_open_cb:     proc(mat_path: string),

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

@(private = "file")
_vs: _VS_Editor_State

vg_node_namespace :: proc(kind: engine.VG_Node_Kind, hint: string = "") -> VG_Namespace {
	if hint != "" && (kind == .Call_Hot_Proc || kind == .Odin_Function_Node) {
		lh := strings.to_lower(hint, context.temp_allocator)
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
		if strings.contains(lh, "math") || strings.contains(lh, "lerp") || strings.contains(lh, "damp") || strings.contains(lh, "sin") || strings.contains(lh, "cos") {
			return .Math
		}
		if strings.contains(lh, "transform") || strings.contains(lh, "pos_") || strings.contains(lh, "position") || strings.contains(lh, "rot") {
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
	case .Event_Init, .Event_Tick, .Event_Destroy, .Custom_Proc_Entry:
		return .Event
	case .Branch_If, .Sequence, .For_Loop, .Call_Blueprint_Proc, .Set_Time_Scale:
		return .Flow
	case .Bind_Input_Action, .Unbind_Input_Action, .Bind_Input_Vector, .Unbind_Input_Vector, .Bind_Debug_Key, .Unbind_Debug_Key, .Unbind_All_Inputs:
		return .Input
	case .Math_Float, .Vec3_Scale_Add:
		return .Math
	case .Get_Transform_Pos, .Set_Transform_Pos:
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
	case .Get_Variable, .Set_Variable:
		return .Variable
	}
	return .Odin
}

vg_namespace_style :: proc(ns: VG_Namespace) -> (badge: string, accent: im.Vec4) {
	switch ns {
	case .Event:     return "EVENT",     {0.84, 0.28, 0.30, 1.0}
	case .Flow:      return "FLOW",      {0.58, 0.64, 0.78, 1.0}
	case .Input:     return "INPUT",     {0.94, 0.56, 0.18, 1.0}
	case .Math:      return "MATH",      {0.26, 0.78, 0.48, 1.0}
	case .Transform: return "TRANSFORM", {0.88, 0.62, 0.20, 1.0}
	case .Anim:      return "ANIM",      {0.28, 0.72, 0.58, 1.0}
	case .VFX:       return "VFX",       {0.94, 0.48, 0.24, 1.0}
	case .Audio:     return "AUDIO",     {0.28, 0.78, 0.88, 1.0}
	case .AI:        return "AI",        {0.34, 0.84, 0.56, 1.0}
	case .Delegate:  return "DELEGATE",  {0.18, 0.82, 0.84, 1.0}
	case .Odin:      return "ODIN",      {0.66, 0.38, 0.94, 1.0}
	case .Variable:  return "VARIABLE",  {0.22, 0.66, 0.88, 1.0}
	}
	return "ODIN", {0.66, 0.38, 0.94, 1.0}
}

vs_clear_undo :: proc() {
	context.allocator = runtime.default_allocator()
	for e in _vs.undo_stack {
		if e.graph_json != "" do delete(e.graph_json)
		if e.subgraph != "" do delete(e.subgraph)
	}
	clear(&_vs.undo_stack)
	for e in _vs.redo_stack {
		if e.graph_json != "" do delete(e.graph_json)
		if e.subgraph != "" do delete(e.subgraph)
	}
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

@(private = "file")
_vs_capture_undo_entry :: proc() -> (entry: VS_Undo_Entry, ok: bool) {
	bytes, err := json.marshal(_vs.graph, {}, context.temp_allocator)
	if err != nil do return {}, false
	context.allocator = runtime.default_allocator()
	entry.graph_json = strings.clone(string(bytes))
	entry.sel_uid    = _vs.selected_node_uid
	entry.sel_var    = _vs.selected_var_idx
	entry.subgraph   = strings.clone(_active_subgraph_str())
	return entry, true
}

vs_push_undo :: proc() {
	if !_vs.initialized do return
	entry, ok := _vs_capture_undo_entry()
	if !ok do return
	context.allocator = runtime.default_allocator()
	for r in _vs.redo_stack {
		if r.graph_json != "" do delete(r.graph_json)
		if r.subgraph != "" do delete(r.subgraph)
	}
	clear(&_vs.redo_stack)
	if len(_vs.undo_stack) >= VS_UNDO_MAX {
		oldest := _vs.undo_stack[0]
		if oldest.graph_json != "" do delete(oldest.graph_json)
		if oldest.subgraph != "" do delete(oldest.subgraph)
		ordered_remove(&_vs.undo_stack, 0)
	}
	append(&_vs.undo_stack, entry)
}

@(private = "file")
_record_undo_on_widget_activate :: #force_inline proc() {
	if im.IsItemActivated() {
		vs_push_undo()
	}
}

@(private = "file")
_vs_apply_undo_stack :: proc(src: ^[dynamic]VS_Undo_Entry, dst: ^[dynamic]VS_Undo_Entry) -> bool {
	if !_vs.initialized || len(src^) == 0 do return false
	cur_entry, cap_ok := _vs_capture_undo_entry()
	if !cap_ok do return false

	context.allocator = runtime.default_allocator()
	popped := src[len(src^) - 1]
	ordered_remove(src, len(src^) - 1)

	restored: engine.Visual_Graph
	if uerr := json.unmarshal(transmute([]u8)popped.graph_json, &restored); uerr != nil {
		engine.vg_destroy_graph(&restored)
		append(src, popped)
		if cur_entry.graph_json != "" do delete(cur_entry.graph_json)
		if cur_entry.subgraph != "" do delete(cur_entry.subgraph)
		return false
	}

	engine.vg_destroy_graph(&_vs.graph)
	_vs.graph = restored
	engine.vg_ensure_default_spaces(&_vs.graph)

	if len(dst^) >= VS_UNDO_MAX {
		oldest := dst[0]
		if oldest.graph_json != "" do delete(oldest.graph_json)
		if oldest.subgraph != "" do delete(oldest.subgraph)
		ordered_remove(dst, 0)
	}
	append(dst, cur_entry)

	_vs.selected_node_uid = popped.sel_uid
	_vs.selected_var_idx  = popped.sel_var
	if _vs.selected_var_idx >= len(_vs.graph.variables) do _vs.selected_var_idx = -1
	_set_c_buf(_vs.active_subgraph[:], popped.subgraph)
	if popped.graph_json != "" do delete(popped.graph_json)
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
	if _vs.active_domain == .Material_Shader do return false
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

register_material_studio_drawer :: proc(draw_fn: proc(), open_mat_fn: proc(mat_path: string) = nil) {
	_vs.mat_studio_draw_cb = draw_fn
	_vs.mat_studio_open_cb = open_mat_fn
}

open_unified_graph_domain :: proc(domain: engine.VG_Graph_Domain, asset_path: string = "") {
	ensure_visual_script_init()
	_vs.active_domain = domain
	if domain == .Material_Shader {
		if asset_path != "" && _vs.mat_studio_open_cb != nil {
			_vs.mat_studio_open_cb(asset_path)
		}
	} else {
		_vs.graph.domain = domain
		if asset_path != "" {
			open_blueprint_in_studio(asset_path)
			_vs.active_domain = domain
			_vs.graph.domain  = domain
		}
	}
	wnd.open("mh_visual_script")
}

@(private = "file")
_c_str :: #force_inline proc(buf: []byte) -> string {
	return string(cstring(raw_data(buf)))
}

@(private = "file")
_set_c_buf :: proc(buf: []byte, s: string) {
	n := min(len(s), len(buf) - 1)
	if n > 0 do copy(buf[:n], s[:n])
	for i := n; i < len(buf); i += 1 do buf[i] = 0
}

@(private = "file")
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

@(private = "file")
_graph_matches_runner :: proc(graph_path: string) -> bool {
	if _vs.graph_rel_path == "" do return false
	if graph_path == _vs.graph_rel_path do return true
	return strings.has_suffix(graph_path, fmt.tprintf("%s.bodin", _vs.graph.name)) ||
	       strings.has_suffix(graph_path, fmt.tprintf("%s.mhgraph", _vs.graph.name))
}

@(private = "file")
_live_editor_hook :: proc(graph_path: string, tH: engine.Transform_Handle, dt: f32, r: ^engine.VisualScriptRunner) -> bool {
	if !_vs.initialized || !_vs.dirty_unbaked do return false
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

@(private = "file")
_live_callback_hook :: proc(tH: engine.Transform_Handle, node_uid: int, proc_name: string, dt: f32, payload_f32: f32, payload_v2: [2]f32, pressed: bool) -> bool {
	if !_vs.initialized || !_vs.dirty_unbaked do return false
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

@(private = "file")
_active_subgraph_str :: proc() -> string {
	return _c_str(_vs.active_subgraph[:])
}

@(private = "file")
_is_node_visible_in_subgraph :: proc(n: ^engine.VG_Node) -> bool {
	if n == nil do return false
	if _vs.show_all_subgraph_nodes do return true
	sub := _active_subgraph_str()
	if sub == "" {
		return n.owner_proc == "" || n.kind == .Custom_Proc_Entry
	}
	return n.owner_proc == sub
}

@(private = "file")
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

@(private = "file")
_nav_go_back :: proc() {
	if _vs.nav_hist_cursor > 0 {
		_vs.nav_hist_cursor -= 1
		_set_c_buf(_vs.active_subgraph[:], _c_str(_vs.nav_history[_vs.nav_hist_cursor][:]))
	}
}

@(private = "file")
_nav_go_forward :: proc() {
	if _vs.nav_hist_cursor + 1 < _vs.nav_hist_len {
		_vs.nav_hist_cursor += 1
		_set_c_buf(_vs.active_subgraph[:], _c_str(_vs.nav_history[_vs.nav_hist_cursor][:]))
	}
}

@(private = "file")
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

@(private = "file")
_sync_bodin_disk_to_hot_cartridge :: proc() {
	if _vs.graph_rel_path == "" do return
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	abs_bodin := _vs.graph_rel_path
	if !filepath.is_abs(abs_bodin) {
		abs_bodin, _ = filepath.join({repo_root, _vs.graph_rel_path}, context.temp_allocator)
	}
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
@(private = "file")
_sync_ide_blueprint_context :: proc() {
	vars  := make([dynamic]cs.Scoped_Pin_Badge, 0, len(_vs.graph.variables), context.temp_allocator)
	procs := make([dynamic]string, 0, 8, context.temp_allocator)
	for v in _vs.graph.variables {
		append(&vars, cs.Scoped_Pin_Badge{
			name      = v.name,
			odin_type = engine.vg_pin_odin_type(v.pin_type, v.is_array),
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

@(private = "file")
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

@(private = "file")
_on_scoped_using_query :: proc(space_id: string, _user_ptr: rawptr) -> bool {
	return engine.vg_has_using_space(&_vs.graph, space_id)
}

@(private = "file")
_rescan_blueprint_assets :: proc() {
	context.allocator = runtime.default_allocator()
	for s in _vs.discovered_graphs do delete(s)
	clear(&_vs.discovered_graphs)

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	search_dirs := [2]string{"assets/scripts", "haati/assets/scripts"}
	for sd in search_dirs {
		scripts_dir, _ := filepath.join({repo_root, sd}, context.temp_allocator)
		if h, err := os.open(scripts_dir); err == nil {
			if entries, rerr := os.read_dir(h, -1, context.temp_allocator); rerr == nil {
				for e in entries {
					if strings.has_suffix(e.name, ".bodin") || strings.has_suffix(e.name, ".mhgraph") {
						rel_cand := fmt.tprintf("assets/scripts/%s", e.name)
						already := false
						for ex in _vs.discovered_graphs do if ex == rel_cand { already = true; break }
						if !already do append(&_vs.discovered_graphs, strings.clone(rel_cand))
					}
				}
			}
			os.close(h)
		}
	}
	if len(_vs.discovered_graphs) == 0 {
		append(&_vs.discovered_graphs, strings.clone("assets/scripts/hover_oscillator.bodin"))
	}
	slice.sort(_vs.discovered_graphs[:])
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
	saved_draw := _vs.mat_studio_draw_cb
	saved_open := _vs.mat_studio_open_cb
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
	_vs = {
		mat_studio_draw_cb = saved_draw,
		mat_studio_open_cb = saved_open,
	}
}

// Opens an existing `.bodin` / `.mhgraph` asset inside the Unified Graph Studio (called from Scene Inspector!).
open_blueprint_in_studio :: proc(graph_rel_path: string) -> bool {
	ensure_visual_script_init()
	if graph_rel_path == "" {
		wnd.open("mh_visual_script")
		return true
	}
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	abs_p := graph_rel_path
	if !filepath.is_abs(abs_p) {
		abs_p, _ = filepath.join({repo_root, graph_rel_path}, context.temp_allocator)
	}
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

@(private = "file")
_pin_color :: proc(p: engine.VG_Pin_Def) -> im.Vec4 {
	if p.pin_type == .Exec     do return {0.95, 0.96, 0.98, 1.0}
	if p.pin_type == .Delegate do return {0.22, 0.94, 0.92, 1.0} // Bright Cyan-Teal for Odin Delegate pins!
	if p.pass_mode == .By_Reference || p.is_addressable {
		return {1.00, 0.46, 0.66, 1.0} // Magenta-Rose for `^Ref` pointers!
	}
	#partial switch p.pin_type {
	case .Bool:           return {0.92, 0.34, 0.34, 1.0}
	case .Int, .Int64:    return {0.28, 0.86, 0.76, 1.0}
	case .Float:          return {0.38, 0.88, 0.48, 1.0}
	case .Vec2:           return {0.96, 0.64, 0.28, 1.0}
	case .Vec3:           return {0.98, 0.78, 0.26, 1.0}
	case .Vec4, .Quat:    return {0.94, 0.54, 0.86, 1.0}
	case .String, .Asset: return {0.96, 0.46, 0.66, 1.0}
	case .Entity:         return {0.48, 0.72, 1.00, 1.0}
	}
	return nc.PORT_VALUE
}

@(private = "file")
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
@(private = "file")
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
	}
	return ""
}

@(private = "file")
_resolve_node_doc_tooltip :: proc(n: ^engine.VG_Node, allocator := context.temp_allocator) -> string {
	if n == nil do return ""

	// 1. `@(hot_proc)` Node -> Reuse `//` doc-comments written above the Odin procedure!
	if n.kind == .Call_Hot_Proc && n.hot_proc_target != "" {
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
@(private = "file")
_draw_typed_pin :: proc(dl: ^im.DrawList, pt: im.Vec2, pdef: engine.VG_Pin_Def, hovered: bool, connected: bool, zoom: f32) {
	col := _pin_color(pdef)
	r   := (hovered ? 6.6 : 5.2) * clamp(zoom, 0.5, 2.0)
	bg  := im.GetColorU32ImVec4({0.07, 0.08, 0.10, 0.96})
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

@(private = "file")
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

@(private = "file")
_open_odin_node_in_popup_ide :: proc(n: ^engine.VG_Node) {
	_sync_ide_blueprint_context()
	badges := make([dynamic]cs.Scoped_Pin_Badge, context.temp_allocator)
	for p in n.inputs {
		if p.pin_type == .Exec || p.pin_type == .Delegate do continue
		append(&badges, cs.Scoped_Pin_Badge{
			name      = p.name,
			odin_type = engine.vg_pin_odin_type(p.pin_type),
			pass_mode = p.pass_mode,
			is_output = false,
		})
	}
	for p in n.outputs {
		if p.pin_type == .Exec || p.pin_type == .Delegate do continue
		append(&badges, cs.Scoped_Pin_Badge{
			name      = p.name,
			odin_type = engine.vg_pin_odin_type(p.pin_type),
			pass_mode = .Copy_Value,
			is_output = true,
		})
	}
	sig := build_scoped_node_signature(n, &_vs.graph, context.temp_allocator)
	cs.open_scoped_node_popup(n.uid, n.title, sig, badges[:], n.odin_body, _on_scoped_node_commit, nil)
}

@(private = "file")
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

@(private = "file")
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

@(private = "file")
_debug_key_label :: proc(code: i32) -> cstring {
	for preset in _DEBUG_KEY_PRESETS {
		if preset.code == code do return preset.label
	}
	return fmt.ctprintf("Key#%d", code)
}

@(private = "file")
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
@(private = "file")
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

@(private = "file")
_draw_unified_domain_switcher_bar :: proc() {
	p := thm.palette()
	im.TextDisabled("Studio Mode:")
	im.SameLine(0, 6)

	is_bp  := _vs.active_domain != .Material_Shader
	is_mat := _vs.active_domain == .Material_Shader

	bp_tint  := im.Vec4{0.24, 0.78, 0.96, 1.0}
	mat_tint := im.Vec4{0.92, 0.46, 0.84, 1.0}

	im.PushStyleColorImVec4(.Button,        is_bp ? thm.with_alpha(bp_tint, 0.38) : thm.with_alpha(bp_tint, 0.10))
	im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(bp_tint, 0.48))
	im.PushStyleColorImVec4(.ButtonActive,  thm.with_alpha(bp_tint, 0.58))
	if is_bp do im.PushStyleColorImVec4(.Text, {1.0, 1.0, 1.0, 1.0})
	if im.Button(fmt.ctprintf("%s Blueprint Graph (.bodin)", icons.ICON_MD_ACCOUNT_TREE)) {
		_vs.active_domain = _vs.graph.domain == .Material_Shader ? .Gameplay_Ability : _vs.graph.domain
	}
	if is_bp do im.PopStyleColor()
	im.PopStyleColor(3)
	widgets.tooltip("Unified Native Data-Oriented Odin Graph (.bodin) — Events, Flow, Input, Delegates, Anim, VFX, Audio, and AI grouped by Unreal-style Namespaces")
	im.SameLine(0, 5)

	im.PushStyleColorImVec4(.Button,        is_mat ? thm.with_alpha(mat_tint, 0.38) : thm.with_alpha(mat_tint, 0.10))
	im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(mat_tint, 0.48))
	im.PushStyleColorImVec4(.ButtonActive,  thm.with_alpha(mat_tint, 0.58))
	if is_mat do im.PushStyleColorImVec4(.Text, {1.0, 1.0, 1.0, 1.0})
	if im.Button(fmt.ctprintf("%s Material Shader (.mat/.glsl)", icons.ICON_MD_PALETTE)) {
		_vs.active_domain = .Material_Shader
	}
	if is_mat do im.PopStyleColor()
	im.PopStyleColor(3)
	widgets.tooltip("Strictly content-filtered Material Fragment Shader Graph (.mat / .glsl compiler + live 3D preview)")

	// Right-side Undo/Redo + Persistent Global Wire Style Dropdown + Editor Defaults shortcut
	right_group_w := f32(286.0)
	if im.GetContentRegionAvail().x > right_group_w {
		im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - right_group_w)
	} else {
		im.NewLine()
	}

	im.BeginDisabled(!vs_can_undo() || is_mat)
	if im.Button(fmt.ctprintf("%s Undo", icons.ICON_MD_UNDO)) {
		vs_undo()
	}
	im.EndDisabled()
	widgets.tooltip("Undo (Ctrl+Z)")
	im.SameLine(0, 4)

	im.BeginDisabled(!vs_can_redo() || is_mat)
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
		wnd.open("editor_defaults")
	}
	widgets.tooltip("Open Editor Defaults (Global wire routing style, stationary tooltip delay, IDE per-pane zoom defaults)")
	_ = p
}

@(private = "file")
_Palette_Item :: struct {
	ns:         VG_Namespace,
	label:      string,
	kind:       engine.VG_Node_Kind,
	arg:        string,
	is_hot:     bool,
	hot_file:   string,
	hot_name:   string,
	compat_pin: int,
}

@(private = "file")
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
	for hp in engine.hot_proc_entries() {
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
	}
	return items
}

@(private = "file")
_draw_palette_item_menu :: proc(item: _Palette_Item, spawn_pos: [2]f32, show_badge: bool, auto_wire_pin_drop := false) -> bool {
	badge, accent := vg_namespace_style(item.ns)
	if show_badge {
		im.TextColored(accent, "[%s]", fmt.ctprintf("%s", badge))
		im.SameLine(0, 6)
	}
	clicked := im.MenuItem(fmt.ctprintf("%s##pal_%d_%s_%s_%v", item.label, int(item.kind), item.arg, badge, auto_wire_pin_drop))
	if item.is_hot {
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

@(private = "file")
_draw_namespace_node_palette :: proc(spawn_pos: [2]f32, q: string) -> (spawned: bool) {
	items := _collect_palette_items(context.temp_allocator)

	ql := strings.to_lower(strings.trim_space(q), context.temp_allocator)
	if ql != "" {
		matched := 0
		for item in items {
			badge, _ := vg_namespace_style(item.ns)
			if !strings.contains(strings.to_lower(item.label, context.temp_allocator), ql) &&
			   !strings.contains(strings.to_lower(badge, context.temp_allocator), ql) {
				continue
			}
			matched += 1
			if _draw_palette_item_menu(item, spawn_pos, true) {
				return true
			}
		}
		if matched == 0 {
			im.TextDisabled("No matching BP_Nodes in any namespace.")
		}
		return false
	}

	for ns in _NAMESPACE_PALETTE_ORDER {
		count := 0
		for item in items do if item.ns == ns do count += 1
		if count == 0 do continue

		badge, accent := vg_namespace_style(ns)
		im.PushStyleColorImVec4(.Text, accent)
		hdr_lbl := fmt.ctprintf("%s  (%d)##ns_%d", badge, count, int(ns))
		open := im.TreeNodeEx(hdr_lbl, {.SpanAvailWidth})
		im.PopStyleColor()
		if open {
			for item in items {
				if item.ns != ns do continue
				if _draw_palette_item_menu(item, spawn_pos, false) {
					im.TreePop()
					return true
				}
			}
			im.TreePop()
		}
	}
	return false
}

@(private = "file")
_enter_full_odin_script_mode :: proc() {
	if _, _, ok := bake_graph_to_odin_file(&_vs.graph, _vs.graph_rel_path); ok {
		cs.reload_file_tab_from_disk(_vs.graph_rel_path)
	}
	_vs.view_mode = .Full_Odin_Script
}

@(private = "file")
_toolbar_wrap :: #force_inline proc(est_w: f32) {
	im.SameLine()
	if im.GetContentRegionAvail().x < est_w {
		im.NewLine()
	}
}

@(private = "file")
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
		center_c := (_vs.canvas.size * 0.42) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
		new_uid := _spawn_graph_node(.Odin_Function_Node, {center_c.x, center_c.y})
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
		im.SetNextItemWidth(340)
		im.InputTextWithHint("##vs_tb_add_q", "Search nodes, namespaces, @hot_proc, variables...", cstring(raw_data(_vs.toolbar_add_search_buf[:])), len(_vs.toolbar_add_search_buf))
		im.Separator()
		tq := _c_str(_vs.toolbar_add_search_buf[:])
		center_c := (_vs.canvas.size * 0.42) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
		if im.BeginChild("##vs_tb_add_scroll", {360, 290}) {
			_draw_namespace_node_palette({center_c.x, center_c.y}, tq)
		}
		im.EndChild()
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
		im.SetNextItemWidth(260)
		im.InputTextWithHint("##bp_us_q", "Search self, math, linalg, ease...", cstring(raw_data(_vs.using_search_buf[:])), len(_vs.using_search_buf))
		uq := strings.to_lower(_c_str(_vs.using_search_buf[:]), context.temp_allocator)
		im.Separator()
		for spec in cs.USING_SPACE_CATALOG {
			if !spec.hot_safe do continue
			if uq != "" && !strings.contains(strings.to_lower(spec.label, context.temp_allocator), uq) && !strings.contains(strings.to_lower(spec.description, context.temp_allocator), uq) {
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
			repo_root := engine.resolve_repo_root(context.temp_allocator)
			bodin_abs, _ := filepath.join({repo_root, _vs.graph_rel_path}, context.temp_allocator)
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
	has_tick := engine.vg_has_tick_event(&_vs.graph)
	if !has_tick {
		im.TextColored({0.28, 0.94, 0.62, 1.0}, "%s", fmt.ctprintf("%s Event-Driven (0.00 ms Idle)", icons.ICON_MD_BOLT))
	} else {
		im.TextColored({0.96, 0.72, 0.30, 1.0}, "%s", fmt.ctprintf("%s Opt-In Tick Active", icons.ICON_MD_SYNC))
	}
	widgets.tooltip("Omitting `Event: On Tick` makes this graph 100% Event-Driven (`0.00 ns` per-frame CPU cost when idle)!")

	hot_st, _, _, hot_msg, _ := engine.hot_cartridge_status()
	if _vs.dirty_unbaked {
		im.SameLine()
		im.TextColored({0.98, 0.80, 0.30, 1.0}, "%s", fmt.ctprintf("| %s Live Preview (F7 to Bake)", icons.ICON_MD_CIRCLE))
	} else if hot_st != .Idle && hot_msg != "" {
		im.SameLine()
		im.TextColored({0.38, 0.94, 0.64, 1.0}, "%s", fmt.ctprintf("| %s %s", icons.ICON_MD_CHECK, hot_msg))
	}
}

// =============================================================================
// Column 1 (Left Dock): Unreal-Style "My Blueprint" + Domain Quick Spawners
// =============================================================================

@(private = "file")
_BP_TYPE_SPECS := [11]struct {
	lbl: cstring,
	pt:  hot.Hot_Pin_Type,
}{
	{"bool",    .Bool},
	{"i32",     .Int},
	{"i64",     .Int64},
	{"f32",     .Float},
	{"Vec2",    .Vec2},
	{"Vec3",    .Vec3},
	{"Vec4",    .Vec4},
	{"Quat",    .Quat},
	{"string",  .String},
	{"Entity",  .Entity},
	{"Asset",   .Asset},
}

@(private = "file")
_draw_pin_type_combo :: proc(id: cstring, cur_pt_i32: ^i32, width: f32 = 72.0) {
	cur_idx: i32 = 3
	for spec, idx in _BP_TYPE_SPECS {
		if i32(spec.pt) == cur_pt_i32^ {
			cur_idx = i32(idx)
			break
		}
	}
	lbls: [len(_BP_TYPE_SPECS)]cstring
	for spec, idx in _BP_TYPE_SPECS do lbls[idx] = spec.lbl
	im.SetNextItemWidth(width)
	if im.ComboChar(id, &cur_idx, raw_data(lbls[:]), i32(len(lbls))) {
		cur_pt_i32^ = i32(_BP_TYPE_SPECS[clamp(cur_idx, 0, i32(len(_BP_TYPE_SPECS) - 1))].pt)
	}
}

@(private = "file")
_draw_left_my_blueprint_dock :: proc(height: f32) {
	p := thm.palette()
	open := im.BeginChild("##bp_left_my_blueprint", {256, height}, {.Borders})
	defer im.EndChild()
	if !open do return

	im.TextColored(p.accent, icons.ICON_MD_ACCOUNT_TREE + " MY GRAPH")
	im.Separator()

	// --- Section 1: Events & Procedures ---
	if im.CollapsingHeader(icons.ICON_MD_DIAMOND + " Events & Procedures", {.DefaultOpen}) {
		has_init    := false
		has_tick    := false
		has_destroy := false
		for n_idx := 0; n_idx < len(_vs.graph.nodes); n_idx += 1 {
			n := &_vs.graph.nodes[n_idx]
			if n.kind == .Event_Init    do has_init    = true
			if n.kind == .Event_Tick    do has_tick    = true
			if n.kind == .Event_Destroy do has_destroy = true

			if n.kind == .Event_Init || n.kind == .Event_Tick || n.kind == .Event_Destroy || n.kind == .Custom_Proc_Entry {
				is_sel := _vs.selected_node_uid == n.uid && _vs.selected_var_idx < 0
				is_sub_active := n.kind == .Custom_Proc_Entry && _active_subgraph_str() == n.hot_proc_target
				prefix: cstring = n.kind == .Custom_Proc_Entry ? icons.ICON_MD_DIAMOND : icons.ICON_MD_PLAY_ARROW
				lbl := n.kind == .Custom_Proc_Entry \
					? fmt.ctprintf("%s %s##ev_%d", prefix, n.hot_proc_target, n.uid) \
					: fmt.ctprintf("%s %s##ev_%d", prefix, n.title, n.uid)
				if im.Selectable(lbl, is_sel || is_sub_active, {}, {n.kind == .Custom_Proc_Entry ? 120 : 0, 0}) {
					if n.kind == .Custom_Proc_Entry {
						_navigate_to_subgraph(n.hot_proc_target)
					} else {
						_navigate_to_subgraph("")
						_focus_canvas_on_node(n)
					}
				}
				if n.kind == .Custom_Proc_Entry {
					im.SameLine(0, 2)
					if im.SmallButton(fmt.ctprintf("Call##cp_%d", n.uid)) {
						cpos := (_vs.canvas.size * 0.4) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
						_spawn_graph_node(.Call_Blueprint_Proc, {cpos.x, cpos.y}, n.hot_proc_target)
					}
					widgets.tooltip("Spawn a `Call Blueprint Procedure` node for this procedure")
					im.SameLine(0, 2)
					if im.SmallButton(fmt.ctprintf("Ren##rnp_%d", n.uid)) {
						_vs.proc_rename_uid = n.uid
						_set_c_buf(_vs.proc_rename_buf[:], n.hot_proc_target)
						_navigate_to_subgraph(n.hot_proc_target)
					}
					widgets.tooltip("Rename procedure")
					im.SameLine(0, 2)
					if im.SmallButton(fmt.ctprintf("X##dlp_%d", n.uid)) {
						del_target := n.hot_proc_target
						vs_push_undo()
						context.allocator = runtime.default_allocator()
						if engine.vg_delete_custom_proc(&_vs.graph, n.uid) {
							if _active_subgraph_str() == del_target {
								_navigate_to_subgraph("")
							}
							_vs.dirty_unbaked = true
							_sync_ide_blueprint_context()
							break
						}
					}
					widgets.tooltip("Delete procedure & clean up callers")
				}
			}
		}

		if !has_init {
			if im.SmallButton("+ On Init") {
				_spawn_graph_node(.Event_Init, {40, 60})
			}
			im.SameLine()
		}
		if !has_tick {
			if im.SmallButton("+ On Tick (Opt-In)") {
				_spawn_graph_node(.Event_Tick, {40, 220})
			}
			im.SameLine()
		}
		if !has_destroy {
			if im.SmallButton("+ On Destroy") {
				_spawn_graph_node(.Event_Destroy, {40, 380})
			}
		}
		im.NewLine()

		im.SetNextItemWidth(164)
		im.InputTextWithHint("##new_proc_nm", "On_Jump / On_Interact...", cstring(raw_data(_vs.new_proc_buf[:])), len(_vs.new_proc_buf))
		im.SameLine()
		if im.Button(fmt.ctprintf("+ %s Proc", icons.ICON_MD_DIAMOND)) {
			pnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_proc_buf[:])), context.temp_allocator)
			if pnm != "" && engine.vg_find_custom_proc_node(&_vs.graph, pnm) == nil {
				cpos := (_vs.canvas.size * 0.28) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
				_spawn_graph_node(.Custom_Proc_Entry, {cpos.x, cpos.y}, pnm)
				_vs.new_proc_buf[0] = 0
			}
		}
		widgets.tooltip("Create a new Blueprint Procedure that can be bound to `input_manager` Actions, Debug Keys, or Custom Odin Delegates!")
	}

	im.Separator()

	// --- Section 2: Variables (`using self` + Eye Instance-Editable + Unreal Drag-Drop) ---
	if im.CollapsingHeader(icons.ICON_MD_DATA_OBJECT + " Variables (using self)", {.DefaultOpen}) {
		engine.vg_sync_blackboard(&_vs.graph, &_vs.preview_bb)

		for &v, vi in _vs.graph.variables {
			im.PushIDInt(i32(vi))
			eye_col := v.instance_editable ? im.Vec4{0.34, 0.94, 0.62, 1.0} : im.Vec4{0.45, 0.50, 0.58, 0.75}
			im.PushStyleColorImVec4(.Text, eye_col)
			if im.SmallButton(v.instance_editable ? icons.ICON_MD_VISIBILITY : icons.ICON_MD_VISIBILITY_OFF) {
				vs_push_undo()
				v.instance_editable = !v.instance_editable
				_vs.dirty_unbaked   = true
				_sync_ide_blueprint_context()
			}
			im.PopStyleColor()
			widgets.tooltip(v.instance_editable ? "Instance Editable ON: Exposed per-entity in the Scene Inspector! (Click to hide)" : "Instance Editable OFF: Internal Blueprint variable (Click to expose in Scene Inspector)")

			im.SameLine()
			is_vsel := _vs.selected_var_idx == vi
			if im.Selectable(fmt.ctprintf("%s : %s", v.name, engine.vg_pin_odin_type(v.pin_type, v.is_array)), is_vsel, {}, {116, 0}) {
				_vs.selected_var_idx  = vi
				_vs.selected_node_uid = 0
			}
			if im.BeginDragDropSource() {
				cname := fmt.ctprintf("%s", v.name)
				im.SetDragDropPayload("MH_BP_VAR", rawptr(cname), uint(len(v.name) + 1))
				im.Text("%s", fmt.ctprintf("%s %s (Ctrl = Get, Alt = Set)", icons.ICON_MD_DATA_OBJECT, v.name))
				im.EndDragDropSource()
			}
			widgets.tooltip_delayed("Drag into canvas (Ctrl=Get, Alt=Set, plain=choose) or click to edit in Right Details")

			im.SameLine()
			if im.SmallButton("Get") {
				cpos := (_vs.canvas.size * 0.34) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
				_spawn_graph_node(.Get_Variable, {cpos.x, cpos.y}, v.name)
			}
			widgets.tooltip("Spawn Get node (Copy `T` & Mutable `^Ref` outputs)")
			im.SameLine()
			if im.SmallButton("Set") {
				cpos := (_vs.canvas.size * 0.38) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
				_spawn_graph_node(.Set_Variable, {cpos.x, cpos.y}, v.name)
			}
			im.PopID()
		}

		im.SetNextItemWidth(110)
		im.InputTextWithHint("##new_vname", "var_name", cstring(raw_data(_vs.new_var_buf[:])), len(_vs.new_var_buf))
		im.SameLine()
		_draw_pin_type_combo("##new_vtype", &_vs.new_var_type, 74.0)
		im.SameLine()
		im.Checkbox("[8]", &_vs.new_var_is_array)
		widgets.tooltip("Create as fixed `[8]T` stack array variable")
		if im.Button("+ Add Variable", {-1, 0}) {
			vn := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_var_buf[:])), context.temp_allocator)
			if vn != "" && engine.vg_find_var_index(&_vs.graph, vn) < 0 {
				vs_push_undo()
				context.allocator = runtime.default_allocator()
				append(&_vs.graph.variables, engine.VG_Var_Decl{
					name              = strings.clone(vn),
					pin_type          = hot.Hot_Pin_Type(_vs.new_var_type),
					is_array          = _vs.new_var_is_array,
					instance_editable = true,
					category          = strings.clone("Default"),
					slider_min        = 0.0,
					slider_max        = 10.0,
				})
				_vs.new_var_buf[0]         = 0
				_vs.selected_var_idx       = len(_vs.graph.variables) - 1
				_vs.selected_node_uid      = 0
				_vs.preview_bb.initialized = false
				_vs.dirty_unbaked          = true
				_sync_ide_blueprint_context()
			}
		}
	}

	im.Separator()

	// --- Section 3: Custom Odin Delegates (with Rename & Delete!) ---
	if im.CollapsingHeader(icons.ICON_MD_HUB + " Odin Delegates", {.DefaultOpen}) {
		for di := 0; di < len(_vs.graph.delegates); di += 1 {
			d := _vs.graph.delegates[di]
			im.PushIDInt(i32(1000 + di))
			if _vs.del_rename_idx == di {
				im.SetNextItemWidth(134)
				entered := im.InputText("##del_ren_in", cstring(raw_data(_vs.del_rename_buf[:])), len(_vs.del_rename_buf), {.EnterReturnsTrue})
				im.SameLine()
				if im.SmallButton("OK") || entered {
					new_nm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.del_rename_buf[:])), context.temp_allocator)
					if new_nm != "" && new_nm != d {
						vs_push_undo()
						context.allocator = runtime.default_allocator()
						if engine.vg_rename_delegate(&_vs.graph, d, new_nm) {
							_vs.dirty_unbaked = true
						}
					}
					_vs.del_rename_idx = -1
				}
				im.SameLine()
				if im.SmallButton("Esc") {
					_vs.del_rename_idx = -1
				}
			} else {
				im.TextColored({0.22, 0.94, 0.92, 1.0}, "%s", fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, d))
				if im.SmallButton("Bind") {
					cpos := (_vs.canvas.size * 0.36) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					_spawn_graph_node(.Delegate_Bind, {cpos.x, cpos.y}, d)
				}
				im.SameLine(0, 3)
				if im.SmallButton("Unbind") {
					cpos := (_vs.canvas.size * 0.40) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					_spawn_graph_node(.Delegate_Unbind, {cpos.x, cpos.y}, d)
				}
				im.SameLine(0, 3)
				if im.SmallButton("Cast") {
					cpos := (_vs.canvas.size * 0.44) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					_spawn_graph_node(.Delegate_Broadcast, {cpos.x, cpos.y}, d)
				}
				widgets.tooltip("Spawn Delegate Broadcast node")
				im.SameLine(0, 3)
				if im.SmallButton("Ren") {
					_vs.del_rename_idx = di
					_set_c_buf(_vs.del_rename_buf[:], d)
				}
				widgets.tooltip("Rename Delegate signal (updates Bind / Unbind / Broadcast nodes)")
				im.SameLine(0, 3)
				if im.SmallButton("X") {
					vs_push_undo()
					context.allocator = runtime.default_allocator()
					if engine.vg_delete_delegate(&_vs.graph, d) {
						_vs.dirty_unbaked = true
						_vs.del_rename_idx = -1
					}
					im.PopID()
					break
				}
				widgets.tooltip("Delete Delegate signal & orphaned Delegate nodes")
			}
			im.PopID()
		}

		im.SetNextItemWidth(154)
		im.InputTextWithHint("##new_del_nm", "On_Damaged...", cstring(raw_data(_vs.new_del_buf[:])), len(_vs.new_del_buf))
		im.SameLine()
		if im.Button(fmt.ctprintf("+ %s Del", icons.ICON_MD_DIAMOND)) {
			dnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_del_buf[:])), context.temp_allocator)
			if dnm != "" {
				exists := false
				for ed in _vs.graph.delegates do if ed == dnm { exists = true; break }
				if !exists {
					vs_push_undo()
					context.allocator = runtime.default_allocator()
					append(&_vs.graph.delegates, strings.clone(dnm))
					_vs.new_del_buf[0] = 0
					_vs.dirty_unbaked  = true
				}
			}
		}
		widgets.tooltip("Declare a custom Odin Delegate signal (`Bind` / `Unbind` / `Broadcast` dynamically at runtime)")
	}

	im.Separator()

	// --- Section 4: Pin Legend ---
	if im.CollapsingHeader("Pin Discipline Legend") {
		im.TextColored({0.94, 0.95, 0.98, 1.0}, "%s", fmt.ctprintf("  %s  Exec Flow", icons.ICON_MD_PLAY_ARROW))
		im.TextColored({0.22, 0.94, 0.92, 1.0}, "%s", fmt.ctprintf("  %s  Odin Delegate (Proc)", icons.ICON_MD_DIAMOND))
		im.TextColored({0.42, 0.88, 0.54, 1.0}, "%s", fmt.ctprintf("  %s  Copy Value (T)", icons.ICON_MD_CIRCLE))
		im.TextColored({1.00, 0.46, 0.66, 1.0}, "%s", fmt.ctprintf("  %s  Mutable Ref (^T)", icons.ICON_MD_DIAMOND))
	}
}

// =============================================================================
// Column 3 (Right Dock): Context-Sensitive Unreal-Style "Details" Inspector
// =============================================================================

@(private = "file")
_draw_target_proc_selector :: proc(n: ^engine.VG_Node) {
	proc_names := make([dynamic]string, 0, 12, context.temp_allocator)
	for cn in _vs.graph.nodes {
		if cn.kind == .Custom_Proc_Entry && cn.hot_proc_target != "" {
			append(&proc_names, cn.hot_proc_target)
		}
	}
	cur_lbl := n.hot_proc_target != "" ? n.hot_proc_target : "<Select Procedure>"
	im.SetNextItemWidth(-1)
	if im.BeginCombo("##det_target_proc", fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, cur_lbl)) {
		for pnm in proc_names {
			if im.Selectable(fmt.ctprintf("%s %s (Graph Proc)", icons.ICON_MD_DIAMOND, pnm), n.hot_proc_target == pnm) {
				vs_push_undo()
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(pnm)
				_vs.dirty_unbaked = true
			}
		}
		im.Separator()
		for hp in engine.hot_proc_entries() {
			if im.Selectable(fmt.ctprintf("%s @(hot_proc) %s", icons.ICON_MD_BOLT, hp.name), n.hot_proc_target == hp.name) {
				vs_push_undo()
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(hp.name)
				_vs.dirty_unbaked = true
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Select which Blueprint Procedure or `@(hot_proc)` this node binds/unbinds (or drag a Delegate wire on the canvas!)")

	if im.Button(fmt.ctprintf("+ Create & Wire %s Procedure", icons.ICON_MD_DIAMOND), {-1, 0}) {
		vs_push_undo()
		base_nm := n.action_name != "" ? fmt.tprintf("On_%s", sanitize_odin_ident(n.action_name, context.temp_allocator)) : "On_Bound_Event"
		cand := base_nm
		suffix := 2
		for engine.vg_find_custom_proc_node(&_vs.graph, cand) != nil {
			cand = fmt.tprintf("%s_%d", base_nm, suffix)
			suffix += 1
		}
		context.allocator = runtime.default_allocator()
		p_uid := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry, {max(n.pos.x - 320.0, 20.0), n.pos.y + 180.0}, cand)
		if n.hot_proc_target != "" do delete(n.hot_proc_target)
		n.hot_proc_target = strings.clone(cand)
		if len(n.inputs) > 1 && n.inputs[1].pin_type == .Delegate {
			for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
				if _vs.graph.wires[wi].to_uid == n.uid && _vs.graph.wires[wi].to_pin == 1 {
					ordered_remove(&_vs.graph.wires, wi)
				}
			}
			append(&_vs.graph.wires, engine.VG_Wire{from_uid = p_uid, from_pin = 0, to_uid = n.uid, to_pin = 1})
		}
		_vs.dirty_unbaked = true
		_sync_ide_blueprint_context()
	}
	widgets.tooltip("Spawns a matching Custom Procedure node and automatically connects its Delegate wire!")
}

@(private = "file")
_draw_right_details_inspector :: proc(height: f32) {
	p := thm.palette()
	open := im.BeginChild("##bp_right_details", {276, height}, {.Borders})
	defer im.EndChild()
	if !open do return

	im.TextColored(p.accent, icons.ICON_MD_TUNE + " DETAILS INSPECTOR")
	im.Separator()

	// --- Mode A: Variable Details Inspector ---
	if _vs.selected_var_idx >= 0 && _vs.selected_var_idx < len(_vs.graph.variables) {
		vi := _vs.selected_var_idx
		v  := &_vs.graph.variables[vi]
		if _vs.rename_target_var != vi {
			_vs.rename_target_var = vi
			_set_c_buf(_vs.rename_buf[:], v.name)
			_set_c_buf(_vs.cat_buf[:],    v.category)
			_set_c_buf(_vs.tip_buf[:],    v.tooltip_text)
		}

		im.TextColored({0.24, 0.78, 0.96, 1.0}, "Graph Variable")
		im.TextDisabled("Variable Name:")
		im.SetNextItemWidth(-1)
		if im.InputText("##var_ren", cstring(raw_data(_vs.rename_buf[:])), len(_vs.rename_buf), {.EnterReturnsTrue}) {
			new_nm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.rename_buf[:])), context.temp_allocator)
			if new_nm != "" && new_nm != v.name && engine.vg_find_var_index(&_vs.graph, new_nm) < 0 {
				vs_push_undo()
				old_nm := v.name
				context.allocator = runtime.default_allocator()
				for &nd in _vs.graph.nodes {
					if (nd.kind == .Get_Variable || nd.kind == .Set_Variable) && nd.var_name == old_nm {
						delete(nd.var_name)
						nd.var_name = strings.clone(new_nm)
					}
				}
				delete(v.name)
				v.name = strings.clone(new_nm)
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
		}

		im.TextDisabled("Odin Type: %s", fmt.ctprintf("%s", engine.vg_pin_odin_type(v.pin_type, v.is_array)))
		arr_tmp := v.is_array
		if im.Checkbox("Fixed Array `[8]T`##vd_arr", &arr_tmp) {
			vs_push_undo()
			v.is_array = arr_tmp
			_vs.dirty_unbaked = true
			_sync_ide_blueprint_context()
		}
		edit_tmp := v.instance_editable
		if im.Checkbox(fmt.ctprintf("%s Instance Editable (Scene Inspector)", icons.ICON_MD_VISIBILITY), &edit_tmp) {
			vs_push_undo()
			v.instance_editable = edit_tmp
			_vs.dirty_unbaked = true
			_sync_ide_blueprint_context()
		}
		widgets.tooltip("When checked, every entity with this graph attached displays a per-instance editable control in the Scene Inspector!")

		im.Separator()
		im.TextDisabled("Default Value:")
		#partial switch v.pin_type {
		case .Bool:
			b_tmp := v.default_bool
			if im.Checkbox("Default Bool##vd_b", &b_tmp) {
				vs_push_undo()
				v.default_bool = b_tmp
				if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_bool = v.default_bool
				_vs.dirty_unbaked = true
			}
		case .Int:
			i_tmp := v.default_int
			changed := im.DragInt("##vd_i", &i_tmp, 1.0)
			_record_undo_on_widget_activate()
			if changed {
				v.default_int = i_tmp
				if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_int = v.default_int
				_vs.dirty_unbaked = true
			}
		case .Int64:
			step_one: i64 = 1
			i64_tmp := v.default_i64
			changed := im.InputScalar("##vd_i64", .S64, &i64_tmp, &step_one)
			_record_undo_on_widget_activate()
			if changed {
				v.default_i64 = i64_tmp
				if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_i64 = v.default_i64
				_vs.dirty_unbaked = true
			}
		case .Float:
			f_tmp := v.default_f32
			changed := im.DragFloat("##vd_f", &f_tmp, 0.02)
			_record_undo_on_widget_activate()
			if changed {
				v.default_f32 = f_tmp
				if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_f32 = v.default_f32
				_vs.dirty_unbaked = true
			}
			im.TextDisabled("Inspector Slider Range (Min / Max):")
			im.SetNextItemWidth(115)
			smin_tmp := v.slider_min
			smin_ch := im.DragFloat("##vd_smin", &smin_tmp, 0.1)
			_record_undo_on_widget_activate()
			if smin_ch { v.slider_min = smin_tmp; _vs.dirty_unbaked = true }
			im.SameLine()
			im.SetNextItemWidth(115)
			smax_tmp := v.slider_max
			smax_ch := im.DragFloat("##vd_smax", &smax_tmp, 0.1)
			_record_undo_on_widget_activate()
			if smax_ch { v.slider_max = smax_tmp; _vs.dirty_unbaked = true }
		case .Vec2:
			v2_tmp := v.default_vec2
			changed := im.DragFloat2("##vd_v2", &v2_tmp, 0.05)
			_record_undo_on_widget_activate()
			if changed {
				v.default_vec2 = v2_tmp
				if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_vec2 = v.default_vec2
				_vs.dirty_unbaked = true
			}
		case .Vec3:
			v3_tmp := v.default_vec3
			changed := im.DragFloat3("##vd_v3", &v3_tmp, 0.05)
			_record_undo_on_widget_activate()
			if changed {
				v.default_vec3 = v3_tmp
				if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_vec3 = v.default_vec3
				_vs.dirty_unbaked = true
			}
		case .Vec4, .Quat:
			v4_tmp := v.default_vec4
			changed := im.DragFloat4("##vd_v4", &v4_tmp, 0.05)
			_record_undo_on_widget_activate()
			if changed {
				v.default_vec4 = v4_tmp
				if vi < engine.VG_MAX_VARS {
					_vs.preview_bb.slots[vi].val_vec4 = v.default_vec4
					_vs.preview_bb.slots[vi].val_quat = v.default_vec4
				}
				_vs.dirty_unbaked = true
			}
		case .String, .Asset:
			sbuf: [128]byte
			_set_c_buf(sbuf[:], v.default_str)
			im.SetNextItemWidth(-1)
			hint: cstring = v.pin_type == .Asset ? "assets/..." : "default string..."
			str_ch := im.InputTextWithHint("##vd_str", hint, cstring(raw_data(sbuf[:])), len(sbuf))
			_record_undo_on_widget_activate()
			if str_ch {
				context.allocator = runtime.default_allocator()
				if v.default_str != "" do delete(v.default_str)
				v.default_str = strings.clone(_c_str(sbuf[:]))
				_vs.preview_bb.initialized = false
				_vs.dirty_unbaked = true
			}
		}

		im.Separator()
		im.TextDisabled("Category:")
		im.SetNextItemWidth(-1)
		cat_ch := im.InputTextWithHint("##vd_cat", "Gameplay / Movement...", cstring(raw_data(_vs.cat_buf[:])), len(_vs.cat_buf))
		_record_undo_on_widget_activate()
		if cat_ch {
			context.allocator = runtime.default_allocator()
			if v.category != "" do delete(v.category)
			v.category = strings.clone(_c_str(_vs.cat_buf[:]))
			_vs.dirty_unbaked = true
		}

		im.TextDisabled("Documentation / Tooltip:")
		im.SetNextItemWidth(-1)
		tip_ch := im.InputTextWithHint("##vd_tip", "Describe variable...", cstring(raw_data(_vs.tip_buf[:])), len(_vs.tip_buf))
		_record_undo_on_widget_activate()
		if tip_ch {
			context.allocator = runtime.default_allocator()
			if v.tooltip_text != "" do delete(v.tooltip_text)
			v.tooltip_text = strings.clone(_c_str(_vs.tip_buf[:]))
			_vs.dirty_unbaked = true
		}

		im.Separator()
		if im.Button("Delete Variable", {-1, 0}) {
			vs_push_undo()
			context.allocator = runtime.default_allocator()
			if v.name         != "" do delete(v.name)
			if v.category     != "" do delete(v.category)
			if v.tooltip_text != "" do delete(v.tooltip_text)
			if v.default_str  != "" do delete(v.default_str)
			ordered_remove(&_vs.graph.variables, vi)
			_vs.selected_var_idx       = -1
			_vs.rename_target_var      = -1
			_vs.preview_bb.initialized = false
			_vs.dirty_unbaked          = true
			_sync_ide_blueprint_context()
		}
		return
	}

	// --- Mode B: Selected Graph Node Details Inspector ---
	if n := engine.vg_find_node(&_vs.graph, _vs.selected_node_uid); n != nil {
		hint := n.hot_proc_target != "" ? n.hot_proc_target : n.title
		cat, col := _node_category_and_color(n.kind, hint)
		im.TextColored(col, "%s", fmt.ctprintf("%s", cat))
		im.SameLine()
		im.TextDisabled("(#%d)", n.uid)
		im.TextWrapped("%s", fmt.ctprintf("%s", n.title))
		en_tmp := n.enabled
		if im.Checkbox("Node Enabled", &en_tmp) {
			vs_push_undo()
			n.enabled = en_tmp
			_vs.dirty_unbaked = true
		}
		im.Separator()

		#partial switch n.kind {
		case .Bind_Input_Action, .Unbind_Input_Action:
			im.TextDisabled("Input Manager Action:")
			actions := _merged_input_actions(context.temp_allocator)
			cur_act := n.action_name != "" ? n.action_name : "Jump"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("##det_act_combo", fmt.ctprintf("%s", cur_act)) {
				for act in actions {
					if im.Selectable(fmt.ctprintf("%s", act), n.action_name == act) {
						vs_push_undo()
						context.allocator = runtime.default_allocator()
						if n.action_name != "" do delete(n.action_name)
						n.action_name = strings.clone(act)
						delete(n.title)
						n.title = strings.clone(fmt.tprintf("%s Input Action (%s)", n.kind == .Bind_Input_Action ? "Bind" : "Unbind", act))
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}
			if _vs.rename_target_uid != n.uid {
				_vs.rename_target_uid = n.uid
				_set_c_buf(_vs.action_custom_buf[:], n.action_name)
			}
			im.SetNextItemWidth(-1)
			if im.InputTextWithHint("##det_act_txt", "Custom action name...", cstring(raw_data(_vs.action_custom_buf[:])), len(_vs.action_custom_buf), {.EnterReturnsTrue}) {
				anm := strings.trim_space(_c_str(_vs.action_custom_buf[:]))
				if anm != "" && anm != n.action_name {
					vs_push_undo()
					context.allocator = runtime.default_allocator()
					if n.action_name != "" do delete(n.action_name)
					n.action_name = strings.clone(anm)
					delete(n.title)
					n.title = strings.clone(fmt.tprintf("%s Input Action (%s)", n.kind == .Bind_Input_Action ? "Bind" : "Unbind", anm))
					_vs.dirty_unbaked = true
				}
			}

			if n.kind == .Bind_Input_Action {
				edge_lbls := [3]cstring{"Pressed", "Released", "Both (Pressed & Released)"}
				edge_i := i32(n.trigger_edge)
				im.TextDisabled("Trigger Edge:")
				im.SetNextItemWidth(-1)
				if im.ComboChar("##det_edge", &edge_i, raw_data(edge_lbls[:]), 3) {
					vs_push_undo()
					n.trigger_edge    = hot.Hot_Trigger_Edge(edge_i)
					_vs.dirty_unbaked = true
				}
				im.TextDisabled("Listener Priority:")
				im.SetNextItemWidth(-1)
				pri_tmp := n.input_priority
				pri_ch := im.DragInt("##det_prio", &pri_tmp, 1.0, -100, 1000)
				_record_undo_on_widget_activate()
				if pri_ch {
					n.input_priority  = pri_tmp
					_vs.dirty_unbaked = true
				}
				con_tmp := n.consume_input
				if im.Checkbox("Consume Input (Block lower priority)", &con_tmp) {
					vs_push_undo()
					n.consume_input   = con_tmp
					_vs.dirty_unbaked = true
				}
				im.Separator()
				im.TextDisabled("Bound Target Procedure:")
				_draw_target_proc_selector(n)
			}

		case .Bind_Input_Vector, .Unbind_Input_Vector:
			chan_lbls := [2]cstring{"Movement Vector ([2]f32)", "Look / Aim Vector ([2]f32)"}
			chan_i: i32 = n.is_look_vector ? 1 : 0
			im.TextDisabled("Vector Channel:")
			im.SetNextItemWidth(-1)
			if im.ComboChar("##det_vchan", &chan_i, raw_data(chan_lbls[:]), 2) {
				vs_push_undo()
				n.is_look_vector = chan_i == 1
				context.allocator = runtime.default_allocator()
				delete(n.title)
				n.title = strings.clone(fmt.tprintf("%s Input Vector (%s)", n.kind == .Bind_Input_Vector ? "Bind" : "Unbind", n.is_look_vector ? "Look" : "Move"))
				_vs.dirty_unbaked = true
			}
			if n.kind == .Bind_Input_Vector {
				im.SetNextItemWidth(-1)
				vpri_tmp := n.input_priority
				vpri_ch := im.DragInt("Priority##det_vprio", &vpri_tmp, 1.0, -100, 1000)
				_record_undo_on_widget_activate()
				if vpri_ch { n.input_priority = vpri_tmp; _vs.dirty_unbaked = true }
				vcon_tmp := n.consume_input
				if im.Checkbox("Consume Vector", &vcon_tmp) { vs_push_undo(); n.consume_input = vcon_tmp; _vs.dirty_unbaked = true }
				im.Separator()
				im.TextDisabled("Bound Target Procedure:")
				_draw_target_proc_selector(n)
			}

		case .Bind_Debug_Key, .Unbind_Debug_Key:
			im.TextColored({0.96, 0.56, 0.72, 1.0}, "[DEV] Direct Scancode Binding")
			im.SetNextItemWidth(-1)
			if im.BeginCombo("##det_dbg_key", _debug_key_label(n.debug_key_code)) {
				for preset in _DEBUG_KEY_PRESETS {
					if im.Selectable(preset.label, n.debug_key_code == preset.code) {
						vs_push_undo()
						n.debug_key_code = preset.code
						context.allocator = runtime.default_allocator()
						delete(n.title)
						n.title = strings.clone(fmt.tprintf("[DEV] %s Debug Key (%s)", n.kind == .Bind_Debug_Key ? "Bind" : "Unbind", string(preset.label)))
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}
			if n.kind == .Bind_Debug_Key {
				edge_lbls := [3]cstring{"Pressed", "Released", "Both"}
				edge_i := i32(n.trigger_edge)
				im.SetNextItemWidth(-1)
				if im.ComboChar("Edge##det_dk_edge", &edge_i, raw_data(edge_lbls[:]), 3) {
					vs_push_undo()
					n.trigger_edge    = hot.Hot_Trigger_Edge(edge_i)
					_vs.dirty_unbaked = true
				}
				im.SetNextItemWidth(-1)
				dkpri_tmp := n.input_priority
				dkpri_ch := im.DragInt("Priority##det_dk_prio", &dkpri_tmp, 1.0, -100, 1000)
				_record_undo_on_widget_activate()
				if dkpri_ch { n.input_priority = dkpri_tmp; _vs.dirty_unbaked = true }
				im.Separator()
				im.TextDisabled("Bound Target Procedure:")
				_draw_target_proc_selector(n)
			}

		case .Delegate_Bind, .Delegate_Unbind, .Delegate_Broadcast:
			im.TextDisabled("Custom Odin Delegate:")
			cur_d := n.delegate_name != "" ? n.delegate_name : "<Select Delegate>"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("##det_del_nm", fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, cur_d)) {
				for d in _vs.graph.delegates {
					if im.Selectable(fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, d), n.delegate_name == d) {
						vs_push_undo()
						context.allocator = runtime.default_allocator()
						if n.delegate_name != "" do delete(n.delegate_name)
						n.delegate_name = strings.clone(d)
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}
			if n.kind != .Delegate_Broadcast {
				im.Separator()
				im.TextDisabled("Target Procedure:")
				_draw_target_proc_selector(n)
			}

		case .Custom_Proc_Entry:
			if _vs.rename_target_uid != n.uid {
				_vs.rename_target_uid = n.uid
				_set_c_buf(_vs.rename_buf[:], n.hot_proc_target)
			}
			im.TextDisabled("Procedure Identifier:")
			im.SetNextItemWidth(-1)
			if im.InputText("##det_proc_ren", cstring(raw_data(_vs.rename_buf[:])), len(_vs.rename_buf), {.EnterReturnsTrue}) {
				new_p := sanitize_odin_ident(strings.trim_space(_c_str(_vs.rename_buf[:])), context.temp_allocator)
				old_p := n.hot_proc_target
				if new_p != "" && new_p != old_p {
					vs_push_undo()
					context.allocator = runtime.default_allocator()
					if engine.vg_rename_custom_proc(&_vs.graph, n.uid, new_p) {
						if _active_subgraph_str() == old_p {
							_set_c_buf(_vs.active_subgraph[:], new_p)
						}
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
				}
			}
			im.TextDisabled("Drag Delegate pin or switch to its Procedure Tab above!")

		case .Call_Blueprint_Proc:
			im.TextDisabled("Target Blueprint Procedure:")
			_draw_target_proc_selector(n)

		case .Odin_Function_Node:
			if im.Button(fmt.ctprintf("%s Open Scoped Popup IDE", icons.ICON_MD_CODE), {-1, 0}) {
				_open_odin_node_in_popup_ide(n)
			}
			im.Separator()
			im.TextDisabled("Add Input Pin:")
			im.SetNextItemWidth(134)
			im.InputTextWithHint("##det_pnm", "pin_name", cstring(raw_data(_vs.new_pin_buf[:])), len(_vs.new_pin_buf))
			im.SameLine()
			_draw_pin_type_combo("##det_pt", &_vs.new_pin_type, 74.0)
			im.Checkbox(fmt.ctprintf("Pass By Reference (%s ^T)##det_pref", icons.ICON_MD_DIAMOND), &_vs.new_pin_is_ref)
			if im.Button("+ Add Pin to Node", {-1, 0}) {
				pnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_pin_buf[:])), context.temp_allocator)
				if pnm != "" {
					vs_push_undo()
					context.allocator = runtime.default_allocator()
					append(&n.inputs, engine.VG_Pin_Def{
						name      = strings.clone(pnm),
						pin_type  = hot.Hot_Pin_Type(_vs.new_pin_type),
						pass_mode = _vs.new_pin_is_ref ? .By_Reference : .Copy_Value,
					})
					_vs.new_pin_buf[0] = 0
					_vs.dirty_unbaked  = true
				}
			}
		}

		// Unwired Input Pin Defaults
		has_unwired := false
		for &ip, ipi in n.inputs {
			if ip.pin_type == .Exec || ip.pin_type == .Delegate || ip.pass_mode == .By_Reference do continue
			wired := false
			for w in _vs.graph.wires do if w.to_uid == n.uid && w.to_pin == ipi { wired = true; break }
			if !wired {
				if !has_unwired {
					im.Separator()
					im.TextDisabled("Unwired Input Defaults:")
					has_unwired = true
				}
				#partial switch ip.pin_type {
				case .Bool:
					bt := ip.default_bool
					if im.Checkbox(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &bt) {
						vs_push_undo()
						ip.default_bool = bt
						_vs.dirty_unbaked = true
					}
				case .Int:
					it_v := ip.default_int
					ch := im.DragInt(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &it_v, 1.0)
					_record_undo_on_widget_activate()
					if ch { ip.default_int = it_v; _vs.dirty_unbaked = true }
				case .Int64:
					s1: i64 = 1
					i64_v := ip.default_i64
					ch := im.InputScalar(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), .S64, &i64_v, &s1)
					_record_undo_on_widget_activate()
					if ch { ip.default_i64 = i64_v; _vs.dirty_unbaked = true }
				case .Float:
					f_v := ip.default_f32
					ch := im.DragFloat(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &f_v, 0.05)
					_record_undo_on_widget_activate()
					if ch { ip.default_f32 = f_v; _vs.dirty_unbaked = true }
				case .Vec2:
					v2_v := ip.default_vec2
					ch := im.DragFloat2(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &v2_v, 0.05)
					_record_undo_on_widget_activate()
					if ch { ip.default_vec2 = v2_v; _vs.dirty_unbaked = true }
				case .Vec3:
					v3_v := ip.default_vec3
					ch := im.DragFloat3(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &v3_v, 0.05)
					_record_undo_on_widget_activate()
					if ch { ip.default_vec3 = v3_v; _vs.dirty_unbaked = true }
				case .Vec4, .Quat:
					v4_v := ip.default_vec4
					ch := im.DragFloat4(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &v4_v, 0.05)
					_record_undo_on_widget_activate()
					if ch { ip.default_vec4 = v4_v; _vs.dirty_unbaked = true }
				case .String, .Asset:
					pbuf: [128]byte
					_set_c_buf(pbuf[:], ip.default_str)
					ch := im.InputText(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), cstring(raw_data(pbuf[:])), len(pbuf))
					_record_undo_on_widget_activate()
					if ch {
						context.allocator = runtime.default_allocator()
						if ip.default_str != "" do delete(ip.default_str)
						ip.default_str = strings.clone(_c_str(pbuf[:]))
						_vs.dirty_unbaked = true
					}
				}
			}
		}

		im.Separator()
		if im.Button(fmt.ctprintf("%s Delete Selected BP_Node (Del)", icons.ICON_MD_DELETE), {-1, 0}) {
			_delete_node_by_uid(n.uid)
		}
		return
	}

	// --- Mode C: Graph Overview ---
	im.TextDisabled("Active Graph Asset:")
	im.TextWrapped("%s", fmt.ctprintf("%s", _vs.graph_rel_path))
	im.Separator()
	im.TextDisabled("Active Using Spaces:")
	for sp in _vs.graph.using_spaces {
		im.BulletText("%s", fmt.ctprintf("using %s", sp))
	}
	im.Separator()
	im.TextDisabled("Shortcuts:\n  - Del / Backspace: Delete selected BP_Node(s)\n  - F7: Bake .odin & Hot-Swap\n  - Right/Left-Drag Pin: Context-Sensitive BP_Node Spawner\n  - Right-Click Canvas: Domain-Filtered BP_Node Palette\n  - Hover BP_Node (Idle): View Function Doc-Comment")
}

// =============================================================================
// Main Entry: Unified Graph Studio Window (`mh_visual_script`)
// =============================================================================

@(private = "file")
_pin_pos_in :: proc(n: ^engine.VG_Node, pin_i: int) -> im.Vec2 {
	return nc.canvas_to_screen(&_vs.canvas, {n.pos.x, n.pos.y + nc.NODE_HEADER_H + 14.0 + f32(pin_i) * 22.0})
}

@(private = "file")
_pin_pos_out :: proc(n: ^engine.VG_Node, node_idx: int, pin_i: int) -> im.Vec2 {
	w := nc.canvas_get_node_size(&_vs.canvas, node_idx, {290, 90}).x
	return nc.canvas_to_screen(&_vs.canvas, {n.pos.x + w, n.pos.y + nc.NODE_HEADER_H + 14.0 + f32(pin_i) * 22.0})
}

@(private = "file")
_next_unique_custom_event_name :: proc(base_hint: string, allocator := context.temp_allocator) -> string {
	base := base_hint != "" ? base_hint : "On_Custom_Event"
	if engine.vg_find_custom_proc_node(&_vs.graph, base) == nil {
		return strings.clone(base, allocator)
	}
	suffix := 2
	for {
		cand := fmt.tprintf("%s_%d", base, suffix)
		if engine.vg_find_custom_proc_node(&_vs.graph, cand) == nil {
			return strings.clone(cand, allocator)
		}
		suffix += 1
	}
}

@(private = "file")
_connect_vg_wire_checked :: proc(from_uid, from_pin, to_uid, to_pin: int, push_undo := true) -> bool {
	src_n := engine.vg_find_node(&_vs.graph, from_uid)
	dst_n := engine.vg_find_node(&_vs.graph, to_uid)
	if src_n == nil || dst_n == nil || from_uid == to_uid do return false
	if from_pin < 0 || from_pin >= len(src_n.outputs) do return false
	if to_pin < 0 || to_pin >= len(dst_n.inputs) do return false

	src_def := src_n.outputs[from_pin]
	dst_def := dst_n.inputs[to_pin]
	if ok_conn, _ := engine.vg_can_connect_pins(src_def, dst_def); !ok_conn do return false

	if push_undo do vs_push_undo()
	context.allocator = runtime.default_allocator()
	for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
		ew := _vs.graph.wires[wi]
		if (ew.to_uid == to_uid && ew.to_pin == to_pin && dst_def.pin_type != .Exec) ||
		   (src_def.pin_type == .Exec && ew.from_uid == from_uid && ew.from_pin == from_pin) {
			ordered_remove(&_vs.graph.wires, wi)
		}
	}
	append(&_vs.graph.wires, engine.VG_Wire{
		from_uid = from_uid,
		from_pin = from_pin,
		to_uid   = to_uid,
		to_pin   = to_pin,
	})
	if dst_def.pin_type == .Delegate && src_n.kind == .Custom_Proc_Entry && src_n.hot_proc_target != "" {
		if dst_n.hot_proc_target != "" do delete(dst_n.hot_proc_target)
		dst_n.hot_proc_target = strings.clone(src_n.hot_proc_target)
	}
	_vs.selected_node_uid = to_uid
	_vs.selected_var_idx  = -1
	_vs.dirty_unbaked     = true
	return true
}

@(private = "file")
_create_and_wire_custom_event_for_node :: proc(dst_uid, dst_pin: int, spawn_pos: [2]f32) -> int {
	dst_n := engine.vg_find_node(&_vs.graph, dst_uid)
	if dst_n == nil do return 0
	hint := "Bound_Event"
	if dst_n.action_name != "" {
		hint = dst_n.action_name
	} else if dst_n.delegate_name != "" {
		hint = dst_n.delegate_name
	}
	base := fmt.tprintf("On_%s", sanitize_odin_ident(hint, context.temp_allocator))
	cand := _next_unique_custom_event_name(base, context.temp_allocator)

	vs_push_undo()
	context.allocator = runtime.default_allocator()
	p_uid := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry, spawn_pos, cand)
	_connect_vg_wire_checked(p_uid, 0, dst_uid, dst_pin, push_undo = false)
	_vs.selected_node_uid = p_uid
	_vs.selected_var_idx  = -1
	_vs.dirty_unbaked     = true
	_sync_ide_blueprint_context()
	return p_uid
}

@(private = "file")
_draw_inline_target_proc_combo :: proc(b: ^nc.BP_Node_Ctx, n: ^engine.VG_Node, out_create_evt_uid: ^int = nil) {
	nc.canvas_bp_node_param(b, "Target Proc")
	cur_lbl := n.hot_proc_target != "" ? n.hot_proc_target : "<Select Custom Event>"
	if im.BeginCombo(fmt.ctprintf("##inl_tproc_%d", n.uid), fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, cur_lbl)) {
		for &cn in _vs.graph.nodes {
			if cn.kind != .Custom_Proc_Entry || cn.hot_proc_target == "" do continue
			pnm := cn.hot_proc_target
			if im.Selectable(fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, pnm), n.hot_proc_target == pnm) {
				vs_push_undo()
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(pnm)
				if len(n.inputs) > 1 && n.inputs[1].pin_type == .Delegate {
					_connect_vg_wire_checked(cn.uid, 0, n.uid, 1, push_undo = false)
				}
				_vs.dirty_unbaked = true
			}
		}
		im.Separator()
		if im.Selectable("+ Create & Wire Custom Event...") {
			if out_create_evt_uid != nil {
				out_create_evt_uid^ = n.uid
			}
		}
		im.EndCombo()
	}

	if len(n.inputs) > 1 && n.inputs[1].pin_type == .Delegate {
		new_evt_lbl := fmt.ctprintf("%s + New Custom Event##inl_newevt_%d", icons.ICON_MD_DIAMOND, n.uid)
		nc.canvas_bp_node_note_body_width(b, im.CalcTextSize(new_evt_lbl).x + 24.0 * _vs.canvas.zoom)
		if im.SmallButton(new_evt_lbl) && out_create_evt_uid != nil {
			out_create_evt_uid^ = n.uid
		}
		widgets.tooltip("Create a new Custom Event (`Custom_Proc_Entry`) BP_Node on this graph and wire its cyan Delegate pin into `Target Proc`.")
	}
}

@(private = "file")
_draw_pin_drop_context_popup :: proc() {
	im.SetNextWindowPos(_vs.pin_drop_screen, .Appearing)
	if !im.BeginPopup("##vs_pin_drop_popup") {
		_vs.pin_drop_pending = false
		return
	}
	defer im.EndPopup()

	p := thm.palette()
	dir_txt := _vs.pin_drop_from_out ? "Output" : "Input"
	t_txt := engine.vg_pin_odin_type(_vs.pin_drop_pin_def.pin_type, _vs.pin_drop_pin_def.is_array)
	im.TextColored(
		_pin_color(_vs.pin_drop_pin_def),
		"%s %s Pin: %s (%s)",
		icons.ICON_MD_BOLT,
		fmt.ctprintf("%s", dir_txt),
		fmt.ctprintf("%s", _vs.pin_drop_pin_def.name),
		fmt.ctprintf("%s", t_txt),
	)

	if _vs.pin_drop_focus_search {
		im.SetKeyboardFocusHere()
		_vs.pin_drop_focus_search = false
	}
	im.SetNextItemWidth(360)
	im.InputTextWithHint(
		"##vs_pin_drop_q",
		"Filter compatible BP_Nodes, variables, Custom Events...",
		cstring(raw_data(_vs.pin_drop_search_buf[:])),
		len(_vs.pin_drop_search_buf),
	)
	im.Separator()

	spawn_pos := [2]f32{_vs.pin_drop_canvas.x, _vs.pin_drop_canvas.y - 36.0}

	// Quick Custom Event creation & existing Custom Event binding for Delegate inputs (`Target Proc`)
	is_delegate_in := !_vs.pin_drop_from_out && _vs.pin_drop_pin_def.pin_type == .Delegate
	if is_delegate_in {
		im.PushStyleColorImVec4(.Text, {0.22, 0.94, 0.92, 1.0})
		if im.MenuItem(fmt.ctprintf("%s + Create & Wire New Custom Event", icons.ICON_MD_DIAMOND)) {
			_create_and_wire_custom_event_for_node(_vs.pin_drop_from_uid, _vs.pin_drop_from_pin, {max(spawn_pos.x - 280.0, 20.0), spawn_pos.y})
			im.CloseCurrentPopup()
			_vs.pin_drop_pending = false
			return
		}
		im.PopStyleColor()
		for cn in _vs.graph.nodes {
			if cn.kind != .Custom_Proc_Entry || cn.hot_proc_target == "" do continue
			if im.MenuItem(fmt.ctprintf("Bind Existing Custom Event: %s %s##bind_ex_%d", icons.ICON_MD_DIAMOND, cn.hot_proc_target, cn.uid)) {
				_connect_vg_wire_checked(cn.uid, 0, _vs.pin_drop_from_uid, _vs.pin_drop_from_pin, push_undo = true)
				im.CloseCurrentPopup()
				_vs.pin_drop_pending = false
				return
			}
		}
		im.Separator()
	}

	// Quick auto-wired Scoped Odin BP_Node for any data pin (including Bool / Int / Vec2 / String)
	if _vs.pin_drop_pin_def.pin_type != .Exec && _vs.pin_drop_pin_def.pin_type != .Delegate {
		im.PushStyleColorImVec4(.Text, p.accent)
		odin_lbl := fmt.ctprintf("%s + Scoped Odin BP_Node (%s %s)", icons.ICON_MD_CODE, t_txt, _vs.pin_drop_from_out ? "In" : "Out")
		if im.MenuItem(odin_lbl) {
			adj := spawn_pos
			if !_vs.pin_drop_from_out do adj.x = max(spawn_pos.x - 280.0, 20.0)
			uid := _spawn_graph_node(.Odin_Function_Node, adj)
			if nn := engine.vg_find_node(&_vs.graph, uid); nn != nil {
				compat := engine.vg_find_compatible_pin_on_node(_vs.pin_drop_from_out, _vs.pin_drop_pin_def, nn)
				if compat < 0 {
					context.allocator = runtime.default_allocator()
					p_name := sanitize_odin_ident(_vs.pin_drop_pin_def.name, context.temp_allocator)
					if p_name == "" do p_name = "value"
					new_pin := engine.VG_Pin_Def{
						name     = strings.clone(p_name),
						pin_type = _vs.pin_drop_pin_def.pin_type,
						is_array = _vs.pin_drop_pin_def.is_array,
					}
					if _vs.pin_drop_from_out {
						append(&nn.inputs, new_pin)
						compat = len(nn.inputs) - 1
					} else {
						append(&nn.outputs, new_pin)
						compat = len(nn.outputs) - 1
					}
				}
				from_uid := _vs.pin_drop_from_out ? _vs.pin_drop_from_uid : uid
				from_pin := _vs.pin_drop_from_out ? _vs.pin_drop_from_pin : compat
				to_uid   := _vs.pin_drop_from_out ? uid                   : _vs.pin_drop_from_uid
				to_pin   := _vs.pin_drop_from_out ? compat                : _vs.pin_drop_from_pin
				_connect_vg_wire_checked(from_uid, from_pin, to_uid, to_pin, push_undo = false)
				_open_odin_node_in_popup_ide(nn)
			}
			im.CloseCurrentPopup()
			_vs.pin_drop_pending = false
			return
		}
		im.PopStyleColor()
		im.Separator()
	}

	items := _collect_palette_items(context.temp_allocator)
	compat_count := 0
	for &item in items {
		if is_delegate_in && item.kind == .Custom_Proc_Entry do continue
		item.compat_pin = engine.vg_probe_compatible_pin(&_vs.graph, item.kind, item.arg, _vs.pin_drop_from_out, _vs.pin_drop_pin_def)
		if item.compat_pin >= 0 do compat_count += 1
	}

	ql := strings.to_lower(strings.trim_space(_c_str(_vs.pin_drop_search_buf[:])), context.temp_allocator)
	if im.BeginChild("##vs_pin_drop_scroll", {380, 290}) {
		if compat_count == 0 {
			im.TextDisabled("No built-in BP_Nodes match this pin type.")
		} else if ql != "" {
			matched := 0
			for item in items {
				if item.compat_pin < 0 do continue
				badge, _ := vg_namespace_style(item.ns)
				if !strings.contains(strings.to_lower(item.label, context.temp_allocator), ql) &&
				   !strings.contains(strings.to_lower(badge, context.temp_allocator), ql) {
					continue
				}
				matched += 1
				if _draw_palette_item_menu(item, spawn_pos, true, auto_wire_pin_drop = true) {
					_vs.pin_drop_pending = false
					break
				}
			}
			if matched == 0 {
				im.TextDisabled("No compatible BP_Nodes match your search.")
			}
		} else {
			picked := false
			for ns in _NAMESPACE_PALETTE_ORDER {
				ns_cnt := 0
				for item in items do if item.compat_pin >= 0 && item.ns == ns do ns_cnt += 1
				if ns_cnt == 0 do continue

				badge, accent := vg_namespace_style(ns)
				im.PushStyleColorImVec4(.Text, accent)
				im.SetNextItemOpen(compat_count <= 14, .Appearing)
				open := im.TreeNodeEx(fmt.ctprintf("%s  (%d)##pdrop_ns_%d", badge, ns_cnt, int(ns)), {.SpanAvailWidth})
				im.PopStyleColor()
				if open {
					for item in items {
						if item.compat_pin < 0 || item.ns != ns do continue
						if _draw_palette_item_menu(item, spawn_pos, false, auto_wire_pin_drop = true) {
							_vs.pin_drop_pending = false
							picked = true
							break
						}
					}
					im.TreePop()
				}
				if picked do break
			}
		}
	}
	im.EndChild()
}

@(private = "file")
_draw_embedded_scoped_node_or_proc :: proc(n: ^engine.VG_Node, avail_sz: im.Vec2) {
	if n == nil {
		im.TextDisabled("Select an Odin Function Node or Custom Procedure to edit its scoped Odin body.")
		return
	}
	_sync_ide_blueprint_context()
	badges := make([dynamic]cs.Scoped_Pin_Badge, context.temp_allocator)
	for p in n.inputs {
		if p.pin_type == .Exec || p.pin_type == .Delegate do continue
		append(&badges, cs.Scoped_Pin_Badge{
			name      = p.name,
			odin_type = engine.vg_pin_odin_type(p.pin_type, p.is_array),
			pass_mode = p.pass_mode,
			is_output = false,
		})
	}
	for p in n.outputs {
		if p.pin_type == .Exec || p.pin_type == .Delegate do continue
		append(&badges, cs.Scoped_Pin_Badge{
			name      = p.name,
			odin_type = engine.vg_pin_odin_type(p.pin_type, p.is_array),
			pass_mode = .Copy_Value,
			is_output = n.kind != .Custom_Proc_Entry,
		})
	}

	sig: string
	if n.kind == .Custom_Proc_Entry {
		pname := sanitize_odin_ident(n.hot_proc_target != "" ? n.hot_proc_target : n.title, context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "mhgraph_%s__proc_%s :: proc \"c\" (api: ^hot.Engine_Hot_API, self: hot.Hot_Entity, using &_bp, dt: f32", sanitize_odin_ident(_vs.graph.name, context.temp_allocator), pname)
		for oi in 2 ..< len(n.outputs) {
			op := n.outputs[oi]
			if op.pin_type == .Exec || op.pin_type == .Delegate do continue
			fmt.sbprintf(&sb, ", %s: %s", sanitize_odin_ident(op.name, context.temp_allocator), engine.vg_pin_odin_type(op.pin_type, op.is_array))
		}
		strings.write_byte(&sb, ')')
		sig = strings.to_string(sb)
	} else {
		sig = build_scoped_node_signature(n, &_vs.graph, context.temp_allocator)
	}

	upd, edited, trig_hs := cs.sync_and_draw_embedded_scoped_editor(n.uid, n.title, sig, badges[:], n.odin_body, avail_sz)
	if edited {
		context.allocator = runtime.default_allocator()
		if n.odin_body != "" do delete(n.odin_body)
		n.odin_body = strings.clone(upd)
		_vs.dirty_unbaked = true
	}
	if trig_hs {
		_bake_and_hot_swap_current_graph()
	}
}

@(private = "file")
_draw_subgraph_tab_bar_and_header :: proc() -> ^engine.VG_Node {
	p   := thm.palette()
	io  := im.GetIO()
	sub := _active_subgraph_str()

	// Back / Forward History Buttons + Alt+Left / Alt+Right
	if _vs.window_focused && !io.WantTextInput && !im.IsAnyItemActive() && io.KeyAlt {
		if im.IsKeyPressed(.LeftArrow, false)  do _nav_go_back()
		if im.IsKeyPressed(.RightArrow, false) do _nav_go_forward()
	}

	im.BeginDisabled(_vs.nav_hist_cursor <= 0)
	if im.SmallButton(icons.ICON_MD_ARROW_LEFT) do _nav_go_back()
	im.EndDisabled()
	widgets.tooltip("Back in graph navigation history (Alt+Left)")

	im.SameLine(0, 3)
	im.BeginDisabled(_vs.nav_hist_cursor + 1 >= _vs.nav_hist_len)
	if im.SmallButton(icons.ICON_MD_ARROW_RIGHT) do _nav_go_forward()
	im.EndDisabled()
	widgets.tooltip("Forward in graph navigation history (Alt+Right)")

	im.SameLine(0, 8)
	// EventGraph Root Tab
	ev_act := sub == "" && !_vs.show_all_subgraph_nodes
	im.PushStyleColorImVec4(.Button, ev_act ? thm.with_alpha(p.accent, 0.38) : thm.with_alpha(p.text_muted, 0.14))
	if im.SmallButton("EventGraph") {
		_vs.show_all_subgraph_nodes = false
		_navigate_to_subgraph("")
	}
	im.PopStyleColor()

	// Procedure Sub-Graph Tabs
	for &cn in _vs.graph.nodes {
		if cn.kind != .Custom_Proc_Entry || cn.hot_proc_target == "" do continue
		im.SameLine(0, 4)
		p_act := sub == cn.hot_proc_target && !_vs.show_all_subgraph_nodes
		col := cn.proc_use_odin_body ? im.Vec4{0.66, 0.42, 0.96, 0.42} : thm.with_alpha({0.16, 0.78, 0.82, 1.0}, 0.40)
		im.PushStyleColorImVec4(.Button, p_act ? col : thm.with_alpha(p.text_muted, 0.14))
		if im.SmallButton(fmt.ctprintf("%s %s##sgt_%d", icons.ICON_MD_DIAMOND, cn.hot_proc_target, cn.uid)) {
			_vs.show_all_subgraph_nodes = false
			_navigate_to_subgraph(cn.hot_proc_target)
		}
		im.PopStyleColor()
	}

	im.SameLine(0, 6)
	all_col := _vs.show_all_subgraph_nodes ? thm.with_alpha(p.accent, 0.36) : thm.with_alpha(p.text_muted, 0.12)
	im.PushStyleColorImVec4(.Button, all_col)
	if im.SmallButton("All Nodes") {
		_vs.show_all_subgraph_nodes = !_vs.show_all_subgraph_nodes
	}
	im.PopStyleColor()
	widgets.tooltip("Toggle showing EventGraph + all Custom Procedure sub-graphs on one canvas")

	im.SameLine(0, 6)
	if im.SmallButton("+ Custom Event") {
		cand := _next_unique_custom_event_name("On_Action_1", context.temp_allocator)
		cpos := (_vs.canvas.size * 0.25) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
		_spawn_graph_node(.Custom_Proc_Entry, {cpos.x, cpos.y}, cand)
	}

	// Procedure Header Bar when viewing a specific Custom Procedure Sub-Graph
	if sub != "" && !_vs.show_all_subgraph_nodes {
		if entry := engine.vg_find_custom_proc_node(&_vs.graph, sub); entry != nil {
			im.Separator()
			im.TextColored({0.22, 0.94, 0.92, 1.0}, "%s PROCEDURE: %s", icons.ICON_MD_DIAMOND, fmt.ctprintf("%s", entry.hot_proc_target))

			im.SameLine(0, 10)
			bp_col   := !entry.proc_use_odin_body ? thm.with_alpha({0.16, 0.78, 0.82, 1.0}, 0.44) : thm.with_alpha(p.text_muted, 0.14)
			odin_col := entry.proc_use_odin_body  ? thm.with_alpha({0.66, 0.42, 0.96, 1.0}, 0.46) : thm.with_alpha(p.text_muted, 0.14)
			im.PushStyleColorImVec4(.Button, bp_col)
			if im.SmallButton("Blueprint Graph Body") {
				if entry.proc_use_odin_body do vs_push_undo()
				entry.proc_use_odin_body = false
				_vs.dirty_unbaked = true
			}
			im.PopStyleColor()
			im.SameLine(0, 2)
			im.PushStyleColorImVec4(.Button, odin_col)
			if im.SmallButton("Pure Odin Code Body") {
				if !entry.proc_use_odin_body do vs_push_undo()
				entry.proc_use_odin_body = true
				_vs.dirty_unbaked = true
			}
			im.PopStyleColor()
			widgets.tooltip("Toggle whether this procedure executes its visual node chain OR compiles your handwritten Odin code directly!")

			// Inline Rename / + Param / Delete
			im.SameLine(0, 8)
			if _vs.proc_rename_uid == entry.uid {
				im.SetNextItemWidth(120)
				entered := im.InputText("##sg_proc_ren", cstring(raw_data(_vs.proc_rename_buf[:])), len(_vs.proc_rename_buf), {.EnterReturnsTrue})
				im.SameLine(0, 2)
				if im.SmallButton("Apply") || entered {
					new_p := sanitize_odin_ident(strings.trim_space(_c_str(_vs.proc_rename_buf[:])), context.temp_allocator)
					if new_p != "" && new_p != entry.hot_proc_target {
						vs_push_undo()
						context.allocator = runtime.default_allocator()
						if engine.vg_rename_custom_proc(&_vs.graph, entry.uid, new_p) {
							_set_c_buf(_vs.active_subgraph[:], new_p)
							_vs.dirty_unbaked = true
							_sync_ide_blueprint_context()
						}
					}
					_vs.proc_rename_uid = 0
				}
			} else {
				if im.SmallButton("Rename") {
					_vs.proc_rename_uid = entry.uid
					_set_c_buf(_vs.proc_rename_buf[:], entry.hot_proc_target)
				}
			}
			im.SameLine(0, 4)
			if im.SmallButton("Delete Proc") {
				vs_push_undo()
				context.allocator = runtime.default_allocator()
				if engine.vg_delete_custom_proc(&_vs.graph, entry.uid) {
					_navigate_to_subgraph("")
					_vs.dirty_unbaked = true
					_sync_ide_blueprint_context()
					return nil
				}
			}

			// Row 2: + Param
			im.SetNextItemWidth(116)
			im.InputTextWithHint("##sg_new_pnm", "param_name", cstring(raw_data(_vs.new_proc_param_buf[:])), len(_vs.new_proc_param_buf))
			im.SameLine(0, 4)
			_draw_pin_type_combo("##sg_new_pt", &_vs.new_proc_param_type, 74.0)
			im.SameLine(0, 4)
			if im.SmallButton("+ Param") {
				pnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_proc_param_buf[:])), context.temp_allocator)
				if pnm != "" {
					vs_push_undo()
					context.allocator = runtime.default_allocator()
					if engine.vg_custom_proc_add_param(&_vs.graph, entry.uid, pnm, hot.Hot_Pin_Type(_vs.new_proc_param_type)) {
						_vs.new_proc_param_buf[0] = 0
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
				}
			}
			if entry.proc_use_odin_body {
				return entry
			}
		}
	}
	return nil
}

draw_visual_script_studio_window :: proc() {
	ensure_visual_script_init()
	p  := thm.palette()
	io := im.GetIO()

	_vs.window_hovered = im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows)
	_vs.window_focused = im.IsWindowFocused({.RootWindow, .ChildWindows})

	// 1. Unified Domain Content Filter Switcher
	_draw_unified_domain_switcher_bar()
	im.Separator()

	// When filtered to Material Shader domain, render the unified Material Shader Graph Studio directly in-place!
	if _vs.active_domain == .Material_Shader {
		avail_mat := im.GetContentRegionAvail()
		mat_open  := im.BeginChild("##unified_mat_shader_host", avail_mat)
		defer im.EndChild()
		if mat_open {
			if _vs.mat_studio_draw_cb != nil {
				_vs.mat_studio_draw_cb()
			} else {
				im.TextDisabled("Material Shader Graph module is not registered.")
			}
		}
		return
	}

	if visual_script_has_focus() && !io.WantTextInput && !im.IsAnyItemActive() && !im.IsPopupOpen("", im.PopupFlags_AnyPopupId) && io.KeyCtrl && im.GetFrameCount() != _vs.last_undo_redo_frame {
		if im.IsKeyPressed(.Z, false) {
			if io.KeyShift {
				vs_redo()
			} else {
				vs_undo()
			}
		} else if im.IsKeyPressed(.Y, false) {
			vs_redo()
		}
	}

	// 2. `.bodin` Native Odin Graph Toolbar (Unified Namespace Graph)
	_draw_blueprint_top_toolbar()
	im.Separator()

	// Full `.bodin` Script View (`F12`)
	if _vs.view_mode == .Full_Odin_Script {
		if im.Button(fmt.ctprintf("%s <- Return to Blueprint Graph (F12)", icons.ICON_MD_ACCOUNT_TREE)) {
			_vs.view_mode = .Blueprint_Graph
		}
		im.SameLine(0, 10)
		im.TextDisabled("%s", fmt.ctprintf("Editing Unified File: %s", _vs.graph_rel_path))
		req_save, req_hs := cs.draw_embedded_script_panel(_vs.graph_rel_path, im.GetContentRegionAvail())
		if req_save || req_hs {
			repo_root := engine.resolve_repo_root(context.temp_allocator)
			abs_p := _vs.graph_rel_path
			if !filepath.is_abs(abs_p) {
				abs_p, _ = filepath.join({repo_root, _vs.graph_rel_path}, context.temp_allocator)
			}
			if os.exists(abs_p) {
				context.allocator = runtime.default_allocator()
				if engine.vg_load_from_file(&_vs.graph, abs_p) {
					vs_clear_undo()
				}
				_vs.preview_bb.initialized = false
				_vs.dirty_unbaked = false
				_sync_ide_blueprint_context()
			}
			if req_hs {
				_sync_bodin_disk_to_hot_cartridge()
			}
		}
		return
	}

	avail   := im.GetContentRegionAvail()
	left_w  := f32(256.0)
	right_w := f32(276.0)
	mid_w   := max(avail.x - left_w - right_w - 16.0, 260.0)

	// COLUMN 1: Left Dock (*My Graph*)
	_draw_left_my_blueprint_dock(avail.y)

	im.SameLine()

	// COLUMN 2: Center Sub-Graph Tabs + Node Block Canvas (+ Optional Split Scoped IDE)
	{
		center_open := im.BeginChild("##bp_center_canvas_host", {mid_w, avail.y})
		if center_open {
			pure_proc_entry := _draw_subgraph_tab_bar_and_header()
			im.Separator()

			rem_avail := im.GetContentRegionAvail()
			if pure_proc_entry != nil {
				_draw_embedded_scoped_node_or_proc(pure_proc_entry, rem_avail)
			} else {
				canvas_h := _vs.view_mode == .Split_Graph_And_Fn ? max(rem_avail.y * 0.56, 160.0) : rem_avail.y
				if im.BeginChild("##bp_canvas_split_top", {0, canvas_h}) {
					_vs.canvas.wire_style = nc.global_wire_style
					if nc.canvas_begin(&_vs.canvas, "##mh_visual_script_canvas") {
						dl             := im.GetWindowDrawList()
						zm             := _vs.canvas.zoom
						canvas_hovered := im.IsWindowHovered(im.HoveredFlags_ChildWindows)
						if !im.IsMouseDown(.Left) {
							_vs.drag_undo_armed = false
						}

						pos_arr := make([]im.Vec2, len(_vs.graph.nodes), context.temp_allocator)
						for &n, i in _vs.graph.nodes {
							if _is_node_visible_in_subgraph(&n) {
								pos_arr[i] = {n.pos.x, n.pos.y}
							} else {
								pos_arr[i] = {-1e6, -1e6}
								nc.canvas_set_selected(&_vs.canvas, i, false)
							}
						}

						// Interactive Comment Boxes (`C` shortcut)
						nc.canvas_update_and_draw_comments(&_vs.canvas, pos_arr, 0)
						comment_moved := false
						for &n, i in _vs.graph.nodes {
							if _is_node_visible_in_subgraph(&n) && (abs(pos_arr[i].x - n.pos.x) > 0.001 || abs(pos_arr[i].y - n.pos.y) > 0.001) {
								comment_moved = true
								break
							}
						}
						if comment_moved {
							if !_vs.drag_undo_armed {
								vs_push_undo()
								_vs.drag_undo_armed = true
							}
							_vs.dirty_unbaked = true
						}
						for &n, i in _vs.graph.nodes {
							if _is_node_visible_in_subgraph(&n) {
								n.pos = {pos_arr[i].x, pos_arr[i].y}
							}
						}

						endpoints := make([dynamic]_Pin_Endpoint, 0, 96, context.temp_allocator)

						// 1. Draw Existing Wires Underneath Node Blocks (only between visible nodes!)
						for wire in _vs.graph.wires {
							src_n := engine.vg_find_node(&_vs.graph, wire.from_uid)
							dst_n := engine.vg_find_node(&_vs.graph, wire.to_uid)
							if src_n == nil || dst_n == nil do continue
							if !_is_node_visible_in_subgraph(src_n) || !_is_node_visible_in_subgraph(dst_n) do continue
							if wire.from_pin < 0 || wire.from_pin >= len(src_n.outputs) do continue
							if wire.to_pin   < 0 || wire.to_pin   >= len(dst_n.inputs)  do continue

							src_idx := 0
							for check_n, ci in _vs.graph.nodes do if check_n.uid == src_n.uid { src_idx = ci; break }

							p0   := _pin_pos_out(src_n, src_idx, wire.from_pin)
							p1   := _pin_pos_in(dst_n, wire.to_pin)
							pdef := src_n.outputs[wire.from_pin]
							wcol := _pin_color(pdef)
							is_ref_wire := dst_n.inputs[wire.to_pin].pass_mode == .By_Reference
							is_del_wire := pdef.pin_type == .Delegate
							lbl: cstring = is_del_wire \
								? fmt.ctprintf("%s Delegate", icons.ICON_MD_DIAMOND) \
								: (is_ref_wire ? fmt.ctprintf("%s ^Ref", icons.ICON_MD_DIAMOND) : (pdef.pin_type == .Exec ? nil : fmt.ctprintf("%s Copy", icons.ICON_MD_CIRCLE)))
							nc.canvas_link(
								&_vs.canvas,
								p0,
								p1,
								im.GetColorU32ImVec4(wcol),
								(is_ref_wire || is_del_wire) ? 2.6 : 2.1,
								(pdef.pin_type == .Exec || is_del_wire) ? 0.9 : 0.35,
								lbl,
								pdef.pin_type == .Exec,
							)
						}

						// 2. Draw Visible Graph BP_Nodes as Auto-Sizing Namespace-Styled Module Blocks!
						delete_node_uid    := 0
						create_evt_for_uid := 0
						hovered_doc_uid  := 0
						hovered_doc_txt  := ""
						hovered_hdr_drag := false
						all_actions      := _merged_input_actions(context.temp_allocator)

						for &n, ni in _vs.graph.nodes {
							if !_is_node_visible_in_subgraph(&n) do continue

							hint := n.hot_proc_target != "" ? n.hot_proc_target : n.title
							cat, col := _node_category_and_color(n.kind, hint)
							npos := im.Vec2{n.pos.x, n.pos.y}

							min_card_w: f32 = 276.0
							if n.kind == .Odin_Function_Node do min_card_w = 336.0
							if n.kind == .Bind_Input_Action || n.kind == .Bind_Input_Vector || n.kind == .Bind_Debug_Key || n.kind == .Delegate_Bind {
								min_card_w = 304.0
							}

							b, open := nc.canvas_bp_node_begin(&_vs.canvas, &npos, {
								id                 = ni,
								title              = fmt.ctprintf("%s", n.title),
								category           = cat,
								step_badge         = fmt.ctprintf("#%d", n.uid),
								color              = col,
								min_width          = min_card_w,
								label_col_width    = 96.0,
								ctrl_col_width     = 162.0,
								enabled_ptr        = &n.enabled,
								has_code_btn       = n.kind == .Odin_Function_Node || n.kind == .Call_Hot_Proc,
								all_node_positions = pos_arr,
								base_node_id       = 0,
							})
							if abs(npos.x - n.pos.x) > 0.001 || abs(npos.y - n.pos.y) > 0.001 {
								if !_vs.drag_undo_armed {
									vs_push_undo()
									_vs.drag_undo_armed = true
								}
								_vs.dirty_unbaked = true
							}
							n.pos       = {npos.x, npos.y}
							pos_arr[ni] = npos

							if b.selected && im.IsMouseClicked(.Left) {
								_vs.selected_node_uid = n.uid
								_vs.selected_var_idx  = -1
							}

							if open {
								max_pins := max(len(n.inputs), len(n.outputs))
								for pi in 0 ..< max_pins {
									in_lbl:  cstring = nil
									out_lbl: cstring = nil
									out_c := im.Vec4{}
									if pi < len(n.inputs) {
										ip := n.inputs[pi]
										clean_in := strings.trim_space(strings.trim_prefix(ip.name, "\u25c7"))
										badge := ip.pin_type == .Exec \
											? icons.ICON_MD_PLAY_ARROW \
											: (ip.pin_type == .Delegate ? icons.ICON_MD_DIAMOND : (ip.pass_mode == .By_Reference ? icons.ICON_MD_DIAMOND : icons.ICON_MD_CIRCLE))
										if ip.pin_type == .Delegate || ip.pin_type == .Exec {
											in_lbl = fmt.ctprintf("%s %s", badge, clean_in)
										} else if ip.pass_mode == .By_Reference {
											in_lbl = fmt.ctprintf("%s ^%s (%s)", badge, clean_in, engine.vg_pin_odin_type(ip.pin_type, ip.is_array))
										} else {
											in_lbl = fmt.ctprintf("%s %s (%s)", badge, clean_in, engine.vg_pin_odin_type(ip.pin_type, ip.is_array))
										}
									}
									if pi < len(n.outputs) {
										op := n.outputs[pi]
										clean_out := strings.trim_space(strings.trim_prefix(op.name, "\u25c7"))
										badge := op.pin_type == .Exec \
											? icons.ICON_MD_PLAY_ARROW \
											: (op.pin_type == .Delegate ? icons.ICON_MD_DIAMOND : (op.is_addressable ? icons.ICON_MD_DIAMOND : icons.ICON_MD_CIRCLE))
										out_lbl = fmt.ctprintf("%s %s", badge, clean_out)
										out_c = _pin_color(op)
									}
									nc.canvas_bp_node_kv(&b, in_lbl, out_lbl, out_c)
								}

								// Inline Interactive BP_Node Controls (using zoom-safe `nc.canvas_bp_node_text`)
								#partial switch n.kind {
								case .Bind_Input_Action:
									cur_act := n.action_name != "" ? n.action_name : "Jump"
									nc.canvas_bp_node_param(&b, "Action")
									if im.BeginCombo(fmt.ctprintf("##inl_act_%d", n.uid), fmt.ctprintf("%s", cur_act)) {
										for act in all_actions {
											if im.Selectable(fmt.ctprintf("%s", act), n.action_name == act) {
												vs_push_undo()
												context.allocator = runtime.default_allocator()
												if n.action_name != "" do delete(n.action_name)
												n.action_name = strings.clone(act)
												delete(n.title)
												n.title = strings.clone(fmt.tprintf("Bind Input Action (%s)", act))
												_vs.dirty_unbaked = true
											}
										}
										im.EndCombo()
									}

									edge_lbls := [3]cstring{"Pressed", "Released", "Both"}
									edge_i    := i32(n.trigger_edge)
									nc.canvas_bp_node_param(&b, "Trigger Edge")
									if im.ComboChar(fmt.ctprintf("##inl_edge_%d", n.uid), &edge_i, raw_data(edge_lbls[:]), 3) {
										vs_push_undo()
										n.trigger_edge    = hot.Hot_Trigger_Edge(edge_i)
										_vs.dirty_unbaked = true
									}

									nc.canvas_bp_node_param(&b, "Priority")
									pri_i := n.input_priority
									pri_ch := im.DragInt(fmt.ctprintf("##inl_pri_%d", n.uid), &pri_i, 1.0, -100, 1000, "Pri: %d")
									_record_undo_on_widget_activate()
									if pri_ch {
										n.input_priority  = pri_i
										_vs.dirty_unbaked = true
									}
									con_i := n.consume_input
									if im.Checkbox(fmt.ctprintf("Consume Input##inl_con_%d", n.uid), &con_i) {
										vs_push_undo()
										n.consume_input   = con_i
										_vs.dirty_unbaked = true
									}
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Unbind_Input_Action:
									cur_act := n.action_name != "" ? n.action_name : "Jump"
									nc.canvas_bp_node_param(&b, "Unbind Action")
									if im.BeginCombo(fmt.ctprintf("##inl_uact_%d", n.uid), fmt.ctprintf("%s", cur_act)) {
										for act in all_actions {
											if im.Selectable(fmt.ctprintf("%s", act), n.action_name == act) {
												vs_push_undo()
												context.allocator = runtime.default_allocator()
												if n.action_name != "" do delete(n.action_name)
												n.action_name = strings.clone(act)
												delete(n.title)
												n.title = strings.clone(fmt.tprintf("Unbind Input Action (%s)", act))
												_vs.dirty_unbaked = true
											}
										}
										im.EndCombo()
									}

								case .Bind_Input_Vector:
									chan_lbls := [2]cstring{"Move [2]f32", "Look [2]f32"}
									chan_i: i32 = n.is_look_vector ? 1 : 0
									nc.canvas_bp_node_param(&b, "Channel")
									if im.ComboChar(fmt.ctprintf("##inl_vch_%d", n.uid), &chan_i, raw_data(chan_lbls[:]), 2) {
										vs_push_undo()
										n.is_look_vector = chan_i == 1
										context.allocator = runtime.default_allocator()
										delete(n.title)
										n.title = strings.clone(fmt.tprintf("Bind Input Vector (%s)", n.is_look_vector ? "Look" : "Move"))
										_vs.dirty_unbaked = true
									}
									nc.canvas_bp_node_param(&b, "Priority")
									vpri_i := n.input_priority
									vpri_ch := im.DragInt(fmt.ctprintf("##inl_vpri_%d", n.uid), &vpri_i, 1.0, -100, 1000, "Pri: %d")
									_record_undo_on_widget_activate()
									if vpri_ch {
										n.input_priority  = vpri_i
										_vs.dirty_unbaked = true
									}
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Bind_Debug_Key:
									nc.canvas_bp_node_param(&b, "Debug Key")
									if im.BeginCombo(fmt.ctprintf("##inl_dk_%d", n.uid), _debug_key_label(n.debug_key_code)) {
										for preset in _DEBUG_KEY_PRESETS {
											if im.Selectable(preset.label, n.debug_key_code == preset.code) {
												vs_push_undo()
												n.debug_key_code = preset.code
												context.allocator = runtime.default_allocator()
												delete(n.title)
												n.title = strings.clone(fmt.tprintf("[DEV] Bind Debug Key (%s)", string(preset.label)))
												_vs.dirty_unbaked = true
											}
										}
										im.EndCombo()
									}
									nc.canvas_bp_node_param(&b, "Priority")
									dkpri_i := n.input_priority
									dkpri_ch := im.DragInt(fmt.ctprintf("##inl_dkpri_%d", n.uid), &dkpri_i, 1.0, -100, 1000, "Pri: %d")
									_record_undo_on_widget_activate()
									if dkpri_ch {
										n.input_priority  = dkpri_i
										_vs.dirty_unbaked = true
									}
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Delegate_Bind:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  Delegate: %s %s", icons.ICON_MD_DIAMOND, n.delegate_name), {0.26, 0.92, 0.88, 1.0})
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Delegate_Unbind, .Delegate_Broadcast:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  Delegate: %s %s", icons.ICON_MD_DIAMOND, n.delegate_name), {0.26, 0.92, 0.88, 1.0})

								case .Call_Blueprint_Proc:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  Call: %s %s()", icons.ICON_MD_DIAMOND, n.hot_proc_target), {0.42, 0.84, 1.00, 1.0})
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Sequence:
									add_lbl := fmt.ctprintf("+ Add Pin##seq_add_%d", n.uid)
									nc.canvas_bp_node_note_body_width(&b, im.CalcTextSize(add_lbl).x + 24.0 * zm)
									if im.SmallButton(add_lbl) {
										vs_push_undo()
										context.allocator = runtime.default_allocator()
										engine.vg_sequence_add_pin(&n)
										_vs.dirty_unbaked = true
									}

								case .Math_Float:
									op_names := [6]cstring{"Add (A + B)", "Sub (A - B)", "Mul (A * B)", "Div (A / B)", "Sin Wave", "Exp Damp"}
									op_idx := i32(n.math_op)
									nc.canvas_bp_node_param(&b, "Math Op")
									if im.ComboChar("##mop", &op_idx, raw_data(op_names[:]), 6) {
										vs_push_undo()
										n.math_op = engine.VG_Math_Op(op_idx)
										_vs.dirty_unbaked = true
									}

								case .Set_Time_Scale:
									pts := n.per_object_ts
									if im.Checkbox("Per-Object TimeScale##ts_mode", &pts) {
										vs_push_undo()
										n.per_object_ts   = pts
										_vs.dirty_unbaked = true
									}
									if len(n.inputs) > 1 {
										nc.canvas_bp_node_param(&b, "Time Scale")
										ts_v := n.inputs[1].default_f32
										ch := im.SliderFloat("##ts_val", &ts_v, 0.0, 2.0, "%.2fx")
										_record_undo_on_widget_activate()
										if ch {
											n.inputs[1].default_f32 = ts_v
											_vs.dirty_unbaked = true
										}
									}

								case .Anim_Blend_Layered:
									if len(n.inputs) > 2 {
										nc.canvas_bp_node_param(&b, "Layer Alpha")
										al_v := n.inputs[2].default_f32
										ch := im.SliderFloat("##an_alpha", &al_v, 0.0, 1.0, "%.2f")
										_record_undo_on_widget_activate()
										if ch {
											n.inputs[2].default_f32 = al_v
											_vs.dirty_unbaked = true
										}
									}

								case .VFX_Emitter_Spawn:
									if len(n.inputs) > 1 {
										nc.canvas_bp_node_param(&b, "Spawn Rate")
										vr_v := n.inputs[1].default_f32
										ch := im.DragFloat("##vfx_rate", &vr_v, 1.0, 0.0, 5000.0, "%.1f /s")
										_record_undo_on_widget_activate()
										if ch {
											n.inputs[1].default_f32 = vr_v
											_vs.dirty_unbaked = true
										}
									}

								case .VFX_GPU_Curl_Force:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  %s On-GPU / SIMD Curl Field", icons.ICON_MD_BLUR_ON), {0.36, 0.86, 0.98, 1.0})

								case .Odin_Function_Node:
									nc.canvas_bp_node_section(&b, "PIN PASSING MODE (COPY vs ^REF)")
									for &ip, ipi in n.inputs {
										if ip.pin_type == .Exec || ip.pin_type == .Delegate do continue
										is_ref := ip.pass_mode == .By_Reference
										mode_lbl := is_ref \
											? fmt.ctprintf("%s %s: ^%s (Ref)##pm_%d", icons.ICON_MD_DIAMOND, ip.name, engine.vg_pin_odin_type(ip.pin_type, ip.is_array), ipi) \
											: fmt.ctprintf("%s %s: %s (Copy)##pm_%d", icons.ICON_MD_CIRCLE, ip.name, engine.vg_pin_odin_type(ip.pin_type, ip.is_array), ipi)
										if im.SmallButton(mode_lbl) {
											vs_push_undo()
											ip.pass_mode = is_ref ? .Copy_Value : .By_Reference
											if ip.pass_mode == .By_Reference {
												for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
													w := _vs.graph.wires[wi]
													if w.to_uid == n.uid && w.to_pin == ipi {
														src_n := engine.vg_find_node(&_vs.graph, w.from_uid)
														if src_n == nil || !src_n.outputs[w.from_pin].is_addressable {
															ordered_remove(&_vs.graph.wires, wi)
														}
													}
												}
											}
											_vs.dirty_unbaked = true
										}
										widgets.tooltip("Toggle input pin between Copy Value (`T`) and Mutable Reference (`^T`)")
									}

									nc.canvas_bp_node_section(&b, "SCOPED ODIN BODY PREVIEW")
									lines := strings.split_lines(n.odin_body, context.temp_allocator)
									for li in 0 ..< min(len(lines), 3) {
										nc.canvas_bp_node_text(&b, fmt.ctprintf("  %s", lines[li]), {0.78, 0.86, 0.98, 1.0})
									}
									btn_lbl := fmt.ctprintf("%s Edit Node Odin Code (Popup IDE)##ed_%d", icons.ICON_MD_CODE, n.uid)
									nc.canvas_bp_node_note_body_width(&b, im.CalcTextSize(btn_lbl).x + 24.0 * zm)
									if im.Button(btn_lbl, {b.visual_inner_w, 0}) {
										_vs.selected_node_uid = n.uid
										_vs.selected_var_idx  = -1
										_open_odin_node_in_popup_ide(&n)
									}
								}
							}

							// Header-Only Double-Click Action (IDE jump or Sub-Graph Drill-In!)
							if b.clicked_code || b.double_clicked_header {
								_vs.selected_node_uid = n.uid
								_vs.selected_var_idx  = -1
								if n.kind == .Odin_Function_Node {
									if _vs.view_mode != .Split_Graph_And_Fn {
										_open_odin_node_in_popup_ide(&n)
									}
								} else if n.kind == .Call_Hot_Proc && n.hot_proc_target != "" {
									src_file := "haati/hot_scripts/builtin_hot_scripts.odin"
									for he in engine.hot_proc_entries() {
										if he.name == n.hot_proc_target && he.source_file != "" {
											src_file = he.source_file
											break
										}
									}
									cs.open_scoped_proc_popup(n.hot_proc_target, src_file, n.hot_proc_target)
								} else if n.kind == .Custom_Proc_Entry && n.hot_proc_target != "" {
									_navigate_to_subgraph(n.hot_proc_target)
								} else if n.kind == .Bind_Input_Action || n.kind == .Bind_Input_Vector || n.kind == .Bind_Debug_Key || n.kind == .Delegate_Bind || n.kind == .Call_Blueprint_Proc {
									tgt := n.hot_proc_target
									for w in _vs.graph.wires {
										if w.to_uid == n.uid && w.to_pin == 1 {
											if sp := engine.vg_find_node(&_vs.graph, w.from_uid); sp != nil && sp.kind == .Custom_Proc_Entry {
												tgt = sp.hot_proc_target
											}
											break
										}
									}
									if tgt != "" && engine.vg_find_custom_proc_node(&_vs.graph, tgt) != nil {
										_navigate_to_subgraph(tgt)
									}
								}
							}

							nc.canvas_bp_node_end(&b)

							// Hit-test node card rect for Stationary Idle-Delay Function Doc-Comment Tooltip!
							card_sz_c := nc.canvas_get_node_size(&_vs.canvas, ni, {min_card_w, 90.0})
							card_min  := nc.canvas_to_screen(&_vs.canvas, npos)
							card_max  := card_min + card_sz_c * zm
							if canvas_hovered && !_vs.dragging_wire && !im.IsMouseDown(.Left) &&
							   io.MousePos.x >= card_min.x && io.MousePos.x <= card_max.x &&
							   io.MousePos.y >= card_min.y && io.MousePos.y <= card_max.y {
								hovered_doc_uid  = n.uid
								hovered_doc_txt  = _resolve_node_doc_tooltip(&n, context.temp_allocator)
								hovered_hdr_drag = b.header_drag_hovered
							}

							for ip, ipi in n.inputs {
								sp := _pin_pos_in(&n, ipi)
								append(&endpoints, _Pin_Endpoint{node_uid = n.uid, pin_idx = ipi, is_out = false, screen_p = sp, pin_def = ip})
							}
							for op, opi in n.outputs {
								sp := _pin_pos_out(&n, ni, opi)
								append(&endpoints, _Pin_Endpoint{node_uid = n.uid, pin_idx = opi, is_out = true, screen_p = sp, pin_def = op})
							}
						}

						multi_moved := false
						for &n, ni in _vs.graph.nodes {
							if _is_node_visible_in_subgraph(&n) && (abs(pos_arr[ni].x - n.pos.x) > 0.001 || abs(pos_arr[ni].y - n.pos.y) > 0.001) {
								multi_moved = true
								break
							}
						}
						if multi_moved {
							if !_vs.drag_undo_armed {
								vs_push_undo()
								_vs.drag_undo_armed = true
							}
							_vs.dirty_unbaked = true
						}
						for &n, ni in _vs.graph.nodes {
							if _is_node_visible_in_subgraph(&n) {
								n.pos = {pos_arr[ni].x, pos_arr[ni].y}
							}
						}
						if create_evt_for_uid != 0 {
							if dn := engine.vg_find_node(&_vs.graph, create_evt_for_uid); dn != nil {
								_create_and_wire_custom_event_for_node(create_evt_for_uid, 1, {max(dn.pos.x - 320.0, 20.0), dn.pos.y + 180.0})
							}
						}

						// Keep `_vs.selected_node_uid` synced with marquee / click selection in `_vs.canvas`
						if _vs.canvas.sel >= 0 && _vs.canvas.sel < len(_vs.graph.nodes) && _is_node_visible_in_subgraph(&_vs.graph.nodes[_vs.canvas.sel]) {
							_vs.selected_node_uid = _vs.graph.nodes[_vs.canvas.sel].uid
						}

						// 3. Pin Hit-Testing & Wire Dragging
						hovered_ep := -1
						best_d: f32 = 13.0 * clamp(zm, 0.6, 1.8)
						for ep, epi in endpoints {
							d := linalg.length(io.MousePos - ep.screen_p)
							if d < best_d {
								best_d     = d
								hovered_ep = epi
							}
						}
						_vs.canvas.suppress_node_drag = hovered_ep >= 0 || _vs.dragging_wire

						// Render Stationary Idle-Delay Tooltip strictly when resting calmly on card background/header
						if hovered_doc_uid > 0 && hovered_ep < 0 && hovered_doc_txt != "" &&
						   (!im.IsAnyItemHovered() || hovered_hdr_drag) &&
						   !im.IsPopupOpen("", im.PopupFlags_AnyPopup) {
							widgets.tooltip_unchecked_delayed(u64(hovered_doc_uid) ~ 0x517cc1b727220a95, fmt.ctprintf("%s", hovered_doc_txt))
						}

						for ep, epi in endpoints {
							is_conn := false
							for w in _vs.graph.wires {
								if (ep.is_out && w.from_uid == ep.node_uid && w.from_pin == ep.pin_idx) ||
								   (!ep.is_out && w.to_uid == ep.node_uid && w.to_pin == ep.pin_idx) {
									is_conn = true
									break
								}
							}
							_draw_typed_pin(dl, ep.screen_p, ep.pin_def, hovered_ep == epi, is_conn, zm)
						}

						start_btn      := im.MouseButton.Left
						start_pin_drag := false
						if hovered_ep >= 0 {
							if im.IsMouseClicked(.Left) {
								start_btn      = .Left
								start_pin_drag = true
							} else if im.IsMouseClicked(.Right) {
								start_btn      = .Right
								start_pin_drag = true
								_vs.canvas.rmb_pressed_in_canvas = false
								_vs.canvas.rmb_pressed_node_id   = -1
								_vs.canvas.rmb_pan_travel        = 0
							}
						}
						if start_pin_drag {
							ep := endpoints[hovered_ep]
							_vs.drag_mouse_btn    = start_btn
							_vs.drag_start_screen = io.MousePos
							_vs.pin_drop_pending  = false
							if !ep.is_out && start_btn == .Left {
								detached := false
								for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
									w := _vs.graph.wires[wi]
									if w.to_uid == ep.node_uid && w.to_pin == ep.pin_idx {
										if src_n := engine.vg_find_node(&_vs.graph, w.from_uid); src_n != nil {
											vs_push_undo()
											_vs.dragging_wire = true
											_vs.drag_from_out = true
											_vs.drag_node_uid = w.from_uid
											_vs.drag_pin_idx  = w.from_pin
											_vs.drag_pin_def  = src_n.outputs[w.from_pin]
											ordered_remove(&_vs.graph.wires, wi)
											_vs.dirty_unbaked = true
											detached = true
											break
										}
									}
								}
								if !detached {
									_vs.dragging_wire = true
									_vs.drag_from_out = false
									_vs.drag_node_uid = ep.node_uid
									_vs.drag_pin_idx  = ep.pin_idx
									_vs.drag_pin_def  = ep.pin_def
								}
							} else {
								_vs.dragging_wire = true
								_vs.drag_from_out = ep.is_out
								_vs.drag_node_uid = ep.node_uid
								_vs.drag_pin_idx  = ep.pin_idx
								_vs.drag_pin_def  = ep.pin_def
							}
						}

						just_finished_pin_drag := false
						if _vs.dragging_wire {
							if _vs.drag_mouse_btn == .Right {
								_vs.canvas.rmb_pressed_in_canvas = false
								_vs.canvas.rmb_pan_travel        = 0
							}

							start_pt := io.MousePos
							for ep in endpoints {
								if ep.node_uid == _vs.drag_node_uid && ep.pin_idx == _vs.drag_pin_idx && ep.is_out == _vs.drag_from_out {
									start_pt = ep.screen_p
									break
								}
							}

							wire_lbl: cstring = _vs.drag_pin_def.pin_type == .Delegate \
								? fmt.ctprintf("Drag %s Delegate (drop on canvas for Custom Event / Bind)", icons.ICON_MD_DIAMOND) \
								: "Drag to pin (or drop on canvas -> Context BP_Node Menu)"
							wire_col := _pin_color(_vs.drag_pin_def)
							end_pt   := io.MousePos

							if hovered_ep >= 0 {
								cand := endpoints[hovered_ep]
								if cand.is_out != _vs.drag_from_out && cand.node_uid != _vs.drag_node_uid {
									src_def := _vs.drag_from_out ? _vs.drag_pin_def : cand.pin_def
									dst_def := _vs.drag_from_out ? cand.pin_def     : _vs.drag_pin_def
									ok_conn, reject_why := engine.vg_can_connect_pins(src_def, dst_def)
									if ok_conn {
										end_pt = cand.screen_p
										if dst_def.pin_type == .Delegate {
											wire_lbl = fmt.ctprintf("%s Bind Odin Delegate Procedure", icons.ICON_MD_CHECK)
										} else if dst_def.pass_mode == .By_Reference {
											wire_lbl = fmt.ctprintf("%s Bind ^Ref Pointer", icons.ICON_MD_CHECK)
										} else {
											wire_lbl = fmt.ctprintf("%s Connect Wire", icons.ICON_MD_CHECK)
										}
									} else {
										wire_col = {1.0, 0.28, 0.30, 1.0}
										wire_lbl = fmt.ctprintf("%s %s", icons.ICON_MD_CLOSE, reject_why)
									}
								}
							}

							p_a := _vs.drag_from_out ? start_pt : end_pt
							p_b := _vs.drag_from_out ? end_pt   : start_pt
							nc.canvas_draw_wire(dl, p_a, p_b, im.GetColorU32ImVec4(wire_col), _vs.canvas.wire_style, 2.5, 0.9, zm, wire_lbl, true)

							if !im.IsMouseDown(_vs.drag_mouse_btn) {
								just_finished_pin_drag = true
								if hovered_ep >= 0 {
									cand := endpoints[hovered_ep]
									if cand.is_out != _vs.drag_from_out && cand.node_uid != _vs.drag_node_uid {
										from_uid := _vs.drag_from_out ? _vs.drag_node_uid : cand.node_uid
										from_pin := _vs.drag_from_out ? _vs.drag_pin_idx  : cand.pin_idx
										to_uid   := _vs.drag_from_out ? cand.node_uid     : _vs.drag_node_uid
										to_pin   := _vs.drag_from_out ? cand.pin_idx      : _vs.drag_pin_idx
										_connect_vg_wire_checked(from_uid, from_pin, to_uid, to_pin, push_undo = true)
									}
								} else if linalg.length(io.MousePos - _vs.drag_start_screen) >= 5.0 {
									drop_c := (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
									_vs.pin_drop_pending       = true
									_vs.pin_drop_from_uid      = _vs.drag_node_uid
									_vs.pin_drop_from_pin      = _vs.drag_pin_idx
									_vs.pin_drop_from_out      = _vs.drag_from_out
									_vs.pin_drop_pin_def       = _vs.drag_pin_def
									_vs.pin_drop_canvas        = drop_c
									_vs.pin_drop_screen        = io.MousePos
									_vs.pin_drop_search_buf[0] = 0
									_vs.pin_drop_focus_search  = true
									im.OpenPopup("##vs_pin_drop_popup")
								}
								_vs.dragging_wire = false
							}
						} else if im.IsPopupOpen("##vs_pin_drop_popup") {
							start_pt := _vs.pin_drop_screen
							for ep in endpoints {
								if ep.node_uid == _vs.pin_drop_from_uid && ep.pin_idx == _vs.pin_drop_from_pin && ep.is_out == _vs.pin_drop_from_out {
									start_pt = ep.screen_p
									break
								}
							}
							p_a := _vs.pin_drop_from_out ? start_pt            : _vs.pin_drop_screen
							p_b := _vs.pin_drop_from_out ? _vs.pin_drop_screen : start_pt
							nc.canvas_draw_wire(dl, p_a, p_b, im.GetColorU32ImVec4(_pin_color(_vs.pin_drop_pin_def)), _vs.canvas.wire_style, 2.4, 0.85, zm, "Select compatible BP_Node...", true)
						}

						// 3b. Unreal-Style Chord + Click Quick Spawning (`B`, `S`, `F`, `O`, `G` + Left Click)
						chord_spawned := false
						if canvas_hovered && hovered_ep < 0 && !hovered_hdr_drag && !im.IsAnyItemHovered() && !io.WantTextInput && !im.IsPopupOpen("", im.PopupFlags_AnyPopup) && im.IsMouseClicked(.Left) {
							click_c := (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
							c_pos := [2]f32{click_c.x, click_c.y}
							if im.IsKeyDown(.B) {
								_spawn_graph_node(.Branch_If, c_pos)
								chord_spawned = true
							} else if im.IsKeyDown(.S) {
								_spawn_graph_node(.Sequence, c_pos)
								chord_spawned = true
							} else if im.IsKeyDown(.F) {
								_spawn_graph_node(.For_Loop, c_pos)
								chord_spawned = true
							} else if im.IsKeyDown(.O) {
								_spawn_graph_node(.Odin_Function_Node, c_pos)
								chord_spawned = true
							} else if im.IsKeyDown(.G) && len(_vs.graph.variables) > 0 {
								v_idx := (_vs.selected_var_idx >= 0 && _vs.selected_var_idx < len(_vs.graph.variables)) ? _vs.selected_var_idx : 0
								_spawn_graph_node(.Get_Variable, c_pos, _vs.graph.variables[v_idx].name)
								chord_spawned = true
							}
						}

						// 4. `Delete` / `Backspace` Key Deletes Selected Graph Node(s) (NOT Scene Hierarchy!)
						if (_vs.window_focused || canvas_hovered) &&
						   !io.WantTextInput &&
						   !im.IsAnyItemActive() &&
						   !im.IsPopupOpen("", im.PopupFlags_AnyPopupId) &&
						   (im.IsKeyPressed(.Delete, false) || im.IsKeyPressed(.Backspace, false)) {
							_delete_selected_graph_nodes()
						}

						// 5. Namespace-Grouped Right-Click Context Search Menu + Context-Sensitive Pin-Drop Spawner!
						suppress_ctx := _vs.dragging_wire || chord_spawned || _vs.pin_drop_pending || just_finished_pin_drag || im.IsPopupOpen("##vs_pin_drop_popup")
						if nc.canvas_begin_context_menu(&_vs.canvas, pos_arr, 0, suppress_ctx) {
							ctx_ni := _vs.canvas.ctx_hovered_id
							if ctx_ni >= 0 && ctx_ni < len(_vs.graph.nodes) && _is_node_visible_in_subgraph(&_vs.graph.nodes[ctx_ni]) {
								cn := &_vs.graph.nodes[ctx_ni]
								im.TextColored(p.accent, "%s", fmt.ctprintf("%s", cn.title))
								im.Separator()
								if im.MenuItem("Inspect in Right Details Panel") {
									_vs.selected_node_uid = cn.uid
									_vs.selected_var_idx  = -1
								}
								if cn.kind == .Odin_Function_Node && im.MenuItem("Edit Scoped Odin Code (Popup IDE)...") {
									_open_odin_node_in_popup_ide(cn)
								}
								if im.MenuItem("Delete BP_Node (Del)") {
									delete_node_uid = cn.uid
								}
								im.Separator()
							}

							_vs.ctx_spawn_canvas = (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
							im.TextColored(p.accent, "%s", fmt.ctprintf("%s Add BP_Node (by Namespace)", icons.ICON_MD_SEARCH))
							im.SetNextItemWidth(340)
							im.InputTextWithHint("##vg_ctx_q", "Search BP_Nodes, namespaces, @hot_proc, variables...", cstring(raw_data(_vs.ctx_search_buf[:])), len(_vs.ctx_search_buf))

							q         := _c_str(_vs.ctx_search_buf[:])
							spawn_pos := [2]f32{_vs.ctx_spawn_canvas.x, _vs.ctx_spawn_canvas.y}

							if im.BeginChild("##vg_palette_scroll", {360, 280}) {
								_draw_namespace_node_palette(spawn_pos, q)
							}
							im.EndChild()

							im.Separator()
							nc.canvas_draw_default_context_menu_items(&_vs.canvas, pos_arr, 0)
							im.EndPopup()
						}

						_draw_pin_drop_context_popup()

						if delete_node_uid != 0 {
							_delete_node_by_uid(delete_node_uid)
						}

						// 6. Unreal-Style `"MH_BP_VAR"` Drag-Drop onto Inner Canvas (`Ctrl`=Get, `Alt`=Set, plain=menu)
						if im.GetDragDropPayload() != nil {
							im.SetCursorScreenPos(_vs.canvas.origin)
							im.Dummy(_vs.canvas.size)
							if im.BeginDragDropTarget() {
								if pay := im.AcceptDragDropPayload("MH_BP_VAR", {}); pay != nil && pay.Data != nil && pay.DataSize > 0 {
									vnm := strings.trim_right_null(string(([^]byte)(pay.Data)[:pay.DataSize]))
									drop_c := (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
									d_pos := [2]f32{drop_c.x, drop_c.y}
									if io.KeyCtrl {
										_spawn_graph_node(.Get_Variable, d_pos, vnm)
									} else if io.KeyAlt {
										_spawn_graph_node(.Set_Variable, d_pos, vnm)
									} else {
										_set_c_buf(_vs.pending_var_drop_name[:], vnm)
										_vs.pending_var_drop_pos = d_pos
										im.OpenPopup("##bp_var_drop_menu")
									}
								}
								im.EndDragDropTarget()
							}
						}
						if im.BeginPopup("##bp_var_drop_menu") {
							dv := _c_str(_vs.pending_var_drop_name[:])
							if im.MenuItem(fmt.ctprintf("Get `%s` (Copy & ^Ref) [Ctrl+Drag]", dv)) {
								_spawn_graph_node(.Get_Variable, _vs.pending_var_drop_pos, dv)
								im.CloseCurrentPopup()
							}
							if im.MenuItem(fmt.ctprintf("Set `%s` [Alt+Drag]", dv)) {
								_spawn_graph_node(.Set_Variable, _vs.pending_var_drop_pos, dv)
								im.CloseCurrentPopup()
							}
							im.EndPopup()
						}
					}
					nc.canvas_end(&_vs.canvas, nil, 0)
				}
				im.EndChild()

				// Bottom Pane when in `Split: Graph + Fn` View Mode
				if _vs.view_mode == .Split_Graph_And_Fn {
					split_h := max(avail.y - canvas_h - 36.0, 120.0)
					target_n: ^engine.VG_Node = nil
					if _vs.selected_node_uid > 0 {
						cand := engine.vg_find_node(&_vs.graph, _vs.selected_node_uid)
						if cand != nil && (cand.kind == .Odin_Function_Node || cand.kind == .Custom_Proc_Entry) {
							target_n = cand
						}
					}
					if target_n == nil && _active_subgraph_str() != "" {
						target_n = engine.vg_find_custom_proc_node(&_vs.graph, _active_subgraph_str())
					}
					if target_n == nil {
						for &nd in _vs.graph.nodes {
							if (nd.kind == .Odin_Function_Node || nd.kind == .Custom_Proc_Entry) && _is_node_visible_in_subgraph(&nd) {
								target_n = &nd
								break
							}
						}
					}
					_draw_embedded_scoped_node_or_proc(target_n, {0, split_h})
				}
			}
		}
		im.EndChild()
	}

	im.SameLine()

	// COLUMN 3: Right Dock (*Details Inspector*)
	_draw_right_details_inspector(avail.y)
}
