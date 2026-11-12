package visual_script

// =============================================================================
// MOONHUG 3-COLUMN BLUEPRINT & ODIN-DELEGATE STUDIO (`visual_script_editor.odin`)
// =============================================================================
// Combines:
//   1. Unreal-Style 3-Column Layout:
//        - Left Dock (*My Blueprint*): Events & Procedures (`◇`), Variables (`👁` Instance-Editable),
//          and Odin Delegates (`◇`)
//        - Center Column: Niagara Auto-Sizing Graph Canvas with 4 Pin Disciplines:
//            `▷` Exec Flow, `◇` Odin Delegate (`Hot_Delegate`), `●` Copy (`T`), `◆` Mutable Ref (`^T`)
//        - Right Dock (*Details Inspector*): Context-sensitive Inspector for Variables, Input Action /
//          Vector / Debug-Key Bindings, Custom Odin Delegates, Procedures, and Scoped Odin Nodes
//   2. Pseudo-OOP `using self` + Interactive `[ + Using / Spaces ]` Namespace Selector:
//        - Compiles down to flat Data-Oriented Odin structs & `@(hot_proc)` machine code (`0.00 ms` VM overhead)
//        - Opt-In `Event_Tick` (`0.00 ns` per-frame runtime cost when `Event_Tick` is omitted!)
//   3. Explicit Odin-Style Delegate Binding (`Bind_Input_Action`, `Unbind_Input_Action`,
//        `Bind_Input_Vector`, `Bind_Debug_Key`, `Delegate_Bind`, `Delegate_Unbind`, `Delegate_Broadcast`)!

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import cs "moonhug:editor/code_studio"
import "moonhug:editor/icons"
import nc "moonhug:editor/node_canvas"
import thm "moonhug:editor/theme"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:engine"
import "moonhug:engine/input"
import hot "moonhug:engine/hot_api"
import im "moonhug:external/odin-imgui"

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
_VS_Editor_State :: struct {
	initialized:       bool,
	canvas:            nc.Node_Canvas,
	graph:             engine.Visual_Graph,
	preview_bb:        engine.VG_Runtime_Blackboard,
	graph_rel_path:    string,
	last_baked_odin:   string,
	dirty_unbaked:     bool,

	// 3-Column Selection State (drives Right *Details Inspector*)
	selected_node_uid: int,
	selected_var_idx:  int, // >= 0 when inspecting a Blueprint Variable in Right Details

	// Interactive wire drag state
	dragging_wire:     bool,
	drag_from_out:     bool,
	drag_node_uid:     int,
	drag_pin_idx:      int,
	drag_pin_def:      engine.VG_Pin_Def,

	// Search & Creation Buffers
	ctx_search_buf:    [128]byte,
	ctx_spawn_canvas:  im.Vec2,
	using_search_buf:  [64]byte,
	new_bp_name_buf:   [64]byte,
	new_proc_buf:      [64]byte,
	new_del_buf:       [64]byte,
	new_var_buf:       [64]byte,
	new_var_type:      i32,
	new_pin_buf:       [48]byte,
	new_pin_type:      i32,
	new_pin_is_ref:    bool,

	// Details Inspector edit buffers
	rename_buf:        [64]byte,
	rename_target_uid: int,
	rename_target_var: int,
	cat_buf:           [64]byte,
	tip_buf:           [128]byte,
	action_custom_buf: [64]byte,

	// Discovered `.mhgraph` assets in `assets/scripts/`
	discovered_graphs: [dynamic]string,
}

@(private = "file")
_vs: _VS_Editor_State

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

// Syncs Blueprint Variables, Custom Procedures, and `using` namespaces into `code_studio` Autocomplete!
@(private = "file")
_sync_ide_blueprint_context :: proc() {
	vars  := make([dynamic]cs.Scoped_Pin_Badge, 0, len(_vs.graph.variables), context.temp_allocator)
	procs := make([dynamic]string, 0, 8, context.temp_allocator)
	for v in _vs.graph.variables {
		append(&vars, cs.Scoped_Pin_Badge{
			name      = v.name,
			odin_type = engine.vg_pin_odin_type(v.pin_type),
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
	search_dirs := [2]string{"assets/scripts", "moonhug/assets/scripts"}
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
	_vs.initialized       = true
	_vs.selected_var_idx  = -1
	_vs.rename_target_var = -1
	nc.canvas_init(&_vs.canvas)
	engine.vg_init_default_demo_graph(&_vs.graph, "hover_oscillator")
	_vs.graph_rel_path = strings.clone("assets/scripts/hover_oscillator.bodin")
	_vs.new_var_type   = i32(hot.Hot_Pin_Type.Float)
	_vs.new_pin_type   = i32(hot.Hot_Pin_Type.Float)
	if len(_vs.graph.nodes) > 0 {
		_vs.selected_node_uid = _vs.graph.nodes[0].uid
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
	engine.vg_destroy_graph(&_vs.graph)
	delete(_vs.preview_bb.last_exec_path)
	if _vs.graph_rel_path  != "" do delete(_vs.graph_rel_path)
	if _vs.last_baked_odin != "" do delete(_vs.last_baked_odin)
	for s in _vs.discovered_graphs do delete(s)
	delete(_vs.discovered_graphs)
	_vs = {}
}

// Opens an existing `.mhgraph` asset inside the 3-Column Blueprint Studio (called from Scene Inspector!).
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
			_vs.graph_rel_path    = strings.clone(graph_rel_path)
			_vs.preview_bb.initialized = false
			_vs.dirty_unbaked     = false
			_vs.selected_var_idx  = -1
			_vs.selected_node_uid = len(_vs.graph.nodes) > 0 ? _vs.graph.nodes[0].uid : 0
			_sync_ide_blueprint_context()
		}
	}
	wnd.open("mh_visual_script")
	return true
}

// Creates a fresh Event-Driven Blueprint `.bodin` (single-file Odin + `@BODIN_GRAPH_V1` layout,
// with `Event_Init` -> `Bind_Input_Action` -> `◇ On_Action` ready to wire!), syncs its hot cartridge
// module, triggers hot-swap, and returns `(rel_path, compiled_proc_name, ok)`!
create_new_blueprint_asset :: proc(blueprint_name: string) -> (rel_path: string, proc_name: string, ok: bool) {
	ensure_visual_script_init()
	clean := sanitize_odin_ident(strings.trim_space(blueprint_name), context.temp_allocator)
	if clean == "" do return "", "", false

	rel := fmt.tprintf("assets/scripts/%s.bodin", clean)
	{
		context.allocator = runtime.default_allocator()
		engine.vg_destroy_graph(&_vs.graph)
		_vs.graph = {
			name     = strings.clone(clean),
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

		u_init := engine.vg_add_node(&_vs.graph, .Event_Init,        {40, 80})
		u_bind := engine.vg_add_node(&_vs.graph, .Bind_Input_Action, {380, 80},  "Jump")
		u_proc := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry, {40, 300},  "On_Jump")
		u_code := engine.vg_add_node(&_vs.graph, .Odin_Function_Node,{420, 300})

		if bnode := engine.vg_find_node(&_vs.graph, u_bind); bnode != nil {
			bnode.hot_proc_target = strings.clone("On_Jump")
		}
		if cnode := engine.vg_find_node(&_vs.graph, u_code); cnode != nil {
			delete(cnode.title)
			cnode.title = strings.clone("Apply Jump Impulse (using self)")
			delete(cnode.odin_body)
			cnode.odin_body = strings.clone("// `impulse_strength` comes directly from `using self`!\nif p := hot.pos_ref(api, self); p != nil {\n    p.y += impulse_strength * 0.25\n}")
		}

		// Wire: On_Init -> Bind_Input_Action, On_Jump.Delegate (pin 0) -> Bind_Input_Action.Target (pin 1), On_Jump.Exec (pin 1) -> Code
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_bind, to_pin = 0})
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 0, to_uid = u_bind, to_pin = 1})
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 1, to_uid = u_code, to_pin = 0})

		if _vs.graph_rel_path != "" do delete(_vs.graph_rel_path)
		_vs.graph_rel_path    = strings.clone(rel)
		_vs.selected_node_uid = u_bind
		_vs.selected_var_idx  = -1
		_vs.preview_bb.initialized = false
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
	if p.pin_type == .Delegate do return {0.22, 0.94, 0.92, 1.0} // Bright Cyan-Teal for `◇` Odin Delegate pins!
	if p.pass_mode == .By_Reference || p.is_addressable {
		return {1.00, 0.46, 0.66, 1.0} // Magenta-Rose for `◆ ^Ref` pointers!
	}
	#partial switch p.pin_type {
	case .Bool:   return {0.92, 0.34, 0.34, 1.0}
	case .Int:    return {0.28, 0.86, 0.76, 1.0}
	case .Float:  return {0.38, 0.88, 0.48, 1.0}
	case .Vec2:   return {0.96, 0.64, 0.28, 1.0}
	case .Vec3:   return {0.98, 0.78, 0.26, 1.0}
	case .Entity: return {0.48, 0.72, 1.00, 1.0}
	}
	return nc.PORT_VALUE
}

@(private = "file")
_node_category_and_color :: proc(k: engine.VG_Node_Kind) -> (cat: cstring, col: im.Vec4) {
	switch k {
	case .Event_Init:          return "INIT EVENT",   {0.20, 0.78, 0.48, 1.0}
	case .Event_Tick:          return "OPT-IN TICK",  {0.86, 0.28, 0.28, 1.0}
	case .Event_Destroy:       return "DESTROY",      {0.72, 0.34, 0.34, 1.0}
	case .Custom_Proc_Entry:   return "◇ PROCEDURE",  {0.16, 0.78, 0.82, 1.0}
	case .Call_Blueprint_Proc: return "CALL PROC",    {0.22, 0.64, 0.86, 1.0}
	case .Bind_Input_Action:   return "INPUT BIND",   {0.94, 0.56, 0.18, 1.0}
	case .Unbind_Input_Action: return "INPUT UNBIND", {0.68, 0.44, 0.24, 1.0}
	case .Bind_Input_Vector:   return "AXIS BIND",    {0.90, 0.64, 0.20, 1.0}
	case .Unbind_Input_Vector: return "AXIS UNBIND",  {0.66, 0.48, 0.24, 1.0}
	case .Bind_Debug_Key:      return "[DEV] KEY",    {0.88, 0.42, 0.58, 1.0}
	case .Unbind_Debug_Key:    return "[DEV] UNBIND", {0.62, 0.36, 0.46, 1.0}
	case .Unbind_All_Inputs:   return "UNBIND ALL",   {0.64, 0.38, 0.38, 1.0}
	case .Delegate_Bind:       return "◇ BIND",       {0.20, 0.76, 0.76, 1.0}
	case .Delegate_Unbind:     return "◇ UNBIND",     {0.34, 0.56, 0.62, 1.0}
	case .Delegate_Broadcast:  return "◇ BROADCAST",  {0.26, 0.84, 0.68, 1.0}
	case .Get_Variable:        return "VARIABLE",     {0.24, 0.68, 0.88, 1.0}
	case .Set_Variable:        return "SET VAR",      {0.20, 0.58, 0.84, 1.0}
	case .Get_Transform_Pos:   return "TRANSFORM",    {0.88, 0.64, 0.20, 1.0}
	case .Set_Transform_Pos:   return "TRANSFORM",    {0.88, 0.54, 0.18, 1.0}
	case .Math_Float:          return "MATH",         {0.26, 0.78, 0.48, 1.0}
	case .Vec3_Scale_Add:      return "VECTOR",       {0.76, 0.68, 0.22, 1.0}
	case .Branch_If:           return "FLOW",         {0.58, 0.58, 0.66, 1.0}
	case .Set_Time_Scale:      return "TIMESCALE",    {0.32, 0.82, 0.78, 1.0}
	case .Call_Hot_Proc:       return "HOT PROC",     {0.54, 0.44, 0.94, 1.0}
	case .Odin_Function_Node:  return "ODIN CODE",    {0.72, 0.36, 0.96, 1.0}
	}
	return "MODULE", {0.4, 0.5, 0.6, 1.0}
}

// Draws all 4 distinct pin glyphs:
//   - `▷` Exec Triangle
//   - `◇` Odin Delegate Hollow Double-Ring Diamond (`Hot_Delegate`)
//   - `◆` Mutable Reference (`^T`) Filled Diamond
//   - `●` Value Copy (`T`) Circle
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
		// Distinct Odin Delegate `◇` Pin (Outer cyan diamond + inner center dot when wired!)
		d := r * 1.18
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
		d := r * 1.08
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
		delete(n.odin_body)
		n.odin_body = strings.clone(updated_body)
		_vs.dirty_unbaked = true
	}
	if trigger_hot_swap {
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
_delete_node_by_uid :: proc(uid: int) {
	if uid <= 0 do return
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
	_vs.dirty_unbaked = true
	_sync_ide_blueprint_context()
}

// =============================================================================
// Top Studio Toolbar: Asset Picker, New Blueprint, Bake F7, Using Bar, Sim Test
// =============================================================================

@(private = "file")
_draw_blueprint_top_toolbar :: proc() {
	p := thm.palette()

	// 1. Blueprint Asset Switcher + `[ + New Blueprint ]`
	cur_base := _vs.graph.name != "" ? _vs.graph.name : "Blueprint"
	im.SetNextItemWidth(168)
	if im.BeginCombo("##bp_asset_combo", fmt.ctprintf("BP: %s", cur_base)) {
		for rel in _vs.discovered_graphs {
			is_sel := rel == _vs.graph_rel_path
			if im.Selectable(fmt.ctprintf("%s", filepath.base(rel)), is_sel) {
				open_blueprint_in_studio(rel)
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Switch active `.bodin` / `.mhgraph` Blueprint asset")

	im.SameLine()
	if im.Button(fmt.ctprintf("%s + New BP", icons.ICON_MD_ADD)) {
		im.OpenPopup("##new_bp_popup")
	}
	widgets.tooltip("Create a new Event-Driven `.bodin` Blueprint Odin script (`assets/scripts/<name>.bodin`) — valid Odin code + visual graph layout in one file!")

	if im.BeginPopup("##new_bp_popup") {
		im.TextColored(p.accent, "Create New Blueprint Script")
		im.SetNextItemWidth(220)
		im.InputTextWithHint("##new_bp_in", "e.g. player_dash_bp", cstring(raw_data(_vs.new_bp_name_buf[:])), len(_vs.new_bp_name_buf))
		if im.Button("Create & Bake Blueprint", {-1, 0}) {
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

	// 2. Bake & Hot-Swap (`F7`)
	im.SameLine()
	im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.28))
	if im.Button(fmt.ctprintf("%s Bake .odin & Hot-Swap (F7)", icons.ICON_MD_PLAY_ARROW)) ||
	   (im.IsWindowFocused({.RootWindow, .ChildWindows}) && im.IsKeyPressed(.F7, false)) {
		_bake_and_hot_swap_current_graph()
	}
	im.PopStyleColor()
	widgets.tooltip("Compiles this Blueprint into flat Data-Oriented `.odin` (`using bp: ^State` + `@(hot_proc)` delegates) and hot-swaps `hot_cartridge_<N>.dll` (~240 ms)!")

	// 3. `+ Odin Code Node`
	im.SameLine()
	if im.Button(fmt.ctprintf("%s + Odin Node", icons.ICON_MD_CODE)) {
		context.allocator = runtime.default_allocator()
		center_c := (_vs.canvas.size * 0.42) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
		new_uid := engine.vg_add_node(&_vs.graph, .Odin_Function_Node, {center_c.x, center_c.y})
		_vs.selected_node_uid = new_uid
		_vs.selected_var_idx  = -1
		_vs.dirty_unbaked     = true
		if n := engine.vg_find_node(&_vs.graph, new_uid); n != nil {
			_open_odin_node_in_popup_ide(n)
		}
	}
	widgets.tooltip("Spawn a Scoped Odin Function Node (`using self`, `● Copy`, `◆ ^Ref`) and open its Popup Micro-IDE")

	// 4. Interactive `[ + Using / Spaces ▾ ]` Selector!
	im.SameLine()
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
			if im.MenuItem(fmt.ctprintf("%s %s", active ? "✓" : " ", spec.label)) {
				engine.vg_toggle_using_space(&_vs.graph, spec.id)
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
			widgets.tooltip(fmt.ctprintf("%s", spec.description))
		}
		im.EndPopup()
	}

	// 5. `[ Sim Input ▾ ]` Live Action / Debug-Key Tester + `[ View .odin ]`
	im.SameLine()
	if im.Button("Sim Input") {
		im.OpenPopup("##bp_sim_input_popup")
	}
	widgets.tooltip("Fire a bound `input_manager` Action or `[DEV]` Debug Key right now to test your `◇` Delegate wires!")

	if im.BeginPopup("##bp_sim_input_popup") {
		im.TextColored(p.accent, "Fire Bound Input / Debug Event")
		im.Separator()
		for act in engine.visual_script_list_input_actions(context.temp_allocator) {
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

	im.SameLine()
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
	im.SameLine()
	has_tick := engine.vg_has_tick_event(&_vs.graph)
	if !has_tick {
		im.TextColored({0.28, 0.94, 0.62, 1.0}, "⚡ Event-Driven (0.00 ms Idle)")
	} else {
		im.TextColored({0.96, 0.72, 0.30, 1.0}, "↻ Opt-In Tick Active")
	}
	widgets.tooltip("Omitting `Event: On Tick` makes this Blueprint 100% Event-Driven (`0.00 ns` per-frame CPU cost when idle)!")

	hot_st, _, _, hot_msg, _ := engine.hot_cartridge_status()
	if _vs.dirty_unbaked {
		im.SameLine()
		im.TextColored({0.98, 0.80, 0.30, 1.0}, "| ● Live Preview (F7 to Bake)")
	} else if hot_st != .Idle && hot_msg != "" {
		im.SameLine()
		im.TextColored({0.38, 0.94, 0.64, 1.0}, "%s", fmt.ctprintf("| ✓ %s", hot_msg))
	}
}

// =============================================================================
// Column 1 (Left Dock): Unreal-Style "My Blueprint" Panel
// =============================================================================

@(private = "file")
_draw_left_my_blueprint_dock :: proc(height: f32) {
	p := thm.palette()
	open := im.BeginChild("##bp_left_my_blueprint", {252, height}, {.Borders})
	defer im.EndChild()
	if !open do return

	im.TextColored(p.accent, icons.ICON_MD_ACCOUNT_TREE + " MY BLUEPRINT")
	im.Separator()

		// --- Section 1: Events & Procedures (`◇`) ---
		if im.CollapsingHeader("Events & Procedures (◇)", {.DefaultOpen}) {
			has_init    := false
			has_tick    := false
			has_destroy := false
			for &n in _vs.graph.nodes {
				if n.kind == .Event_Init    do has_init    = true
				if n.kind == .Event_Tick    do has_tick    = true
				if n.kind == .Event_Destroy do has_destroy = true

				if n.kind == .Event_Init || n.kind == .Event_Tick || n.kind == .Event_Destroy || n.kind == .Custom_Proc_Entry {
					is_sel := _vs.selected_node_uid == n.uid && _vs.selected_var_idx < 0
					prefix: cstring = n.kind == .Custom_Proc_Entry ? "◇" : "▷"
					lbl := n.kind == .Custom_Proc_Entry \
						? fmt.ctprintf("%s %s##ev_%d", prefix, n.hot_proc_target, n.uid) \
						: fmt.ctprintf("%s %s##ev_%d", prefix, n.title, n.uid)
					if im.Selectable(lbl, is_sel, {}, {n.kind == .Custom_Proc_Entry ? 172 : 0, 0}) {
						_focus_canvas_on_node(&n)
					}
					if n.kind == .Custom_Proc_Entry {
						im.SameLine()
						if im.SmallButton(fmt.ctprintf("Call##cp_%d", n.uid)) {
							context.allocator = runtime.default_allocator()
							cpos := (_vs.canvas.size * 0.4) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
							engine.vg_add_node(&_vs.graph, .Call_Blueprint_Proc, {cpos.x, cpos.y}, n.hot_proc_target)
							_vs.dirty_unbaked = true
						}
						widgets.tooltip("Spawn a `Call Blueprint Procedure` node for this procedure")
					}
				}
			}

			// Quick Lifecycle Event Spawners
			if !has_init {
				if im.SmallButton("+ On Init") {
					context.allocator = runtime.default_allocator()
					uid := engine.vg_add_node(&_vs.graph, .Event_Init, {40, 60})
					_vs.selected_node_uid = uid
					_vs.dirty_unbaked = true
				}
				im.SameLine()
			}
			if !has_tick {
				if im.SmallButton("+ On Tick (Opt-In)") {
					context.allocator = runtime.default_allocator()
					uid := engine.vg_add_node(&_vs.graph, .Event_Tick, {40, 220})
					_vs.selected_node_uid = uid
					_vs.dirty_unbaked = true
				}
				im.SameLine()
			}
			if !has_destroy {
				if im.SmallButton("+ On Destroy") {
					context.allocator = runtime.default_allocator()
					uid := engine.vg_add_node(&_vs.graph, .Event_Destroy, {40, 380})
					_vs.selected_node_uid = uid
					_vs.dirty_unbaked = true
				}
			}
			im.NewLine()

			// Add Custom Procedure / Event Entry (`◇`)
			im.SetNextItemWidth(164)
			im.InputTextWithHint("##new_proc_nm", "On_Jump / On_Interact...", cstring(raw_data(_vs.new_proc_buf[:])), len(_vs.new_proc_buf))
			im.SameLine()
			if im.Button("+ ◇ Proc") {
				pnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_proc_buf[:])), context.temp_allocator)
				if pnm != "" && engine.vg_find_custom_proc_node(&_vs.graph, pnm) == nil {
					context.allocator = runtime.default_allocator()
					cpos := (_vs.canvas.size * 0.28) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					uid := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry, {cpos.x, cpos.y}, pnm)
					_vs.new_proc_buf[0]   = 0
					_vs.selected_node_uid = uid
					_vs.selected_var_idx  = -1
					_vs.dirty_unbaked     = true
					_sync_ide_blueprint_context()
				}
			}
			widgets.tooltip("Create a new Blueprint Procedure (`◇`) that can be bound to `input_manager` Actions, Debug Keys, or Custom Odin Delegates!")
		}

		im.Separator()

		// --- Section 2: Variables (`using self` + `👁` Instance-Editable) ---
		if im.CollapsingHeader("Variables (using self)", {.DefaultOpen}) {
			engine.vg_sync_blackboard(&_vs.graph, &_vs.preview_bb)

			for &v, vi in _vs.graph.variables {
				im.PushIDInt(i32(vi))
				eye_col := v.instance_editable ? im.Vec4{0.34, 0.94, 0.62, 1.0} : im.Vec4{0.45, 0.50, 0.58, 0.75}
				im.PushStyleColorImVec4(.Text, eye_col)
				if im.SmallButton(v.instance_editable ? "👁" : "·") {
					v.instance_editable = !v.instance_editable
					_vs.dirty_unbaked   = true
					_sync_ide_blueprint_context()
				}
				im.PopStyleColor()
				widgets.tooltip(v.instance_editable ? "Instance Editable ON: Exposed per-entity in the Scene Inspector! (Click to hide)" : "Instance Editable OFF: Internal Blueprint variable (Click to expose in Scene Inspector)")

				im.SameLine()
				is_vsel := _vs.selected_var_idx == vi
				if im.Selectable(fmt.ctprintf("%s : %s", v.name, engine.vg_pin_odin_type(v.pin_type)), is_vsel, {}, {116, 0}) {
					_vs.selected_var_idx  = vi
					_vs.selected_node_uid = 0
				}
				widgets.tooltip("Click to edit Default Value, Slider Min/Max, Category, and Tooltip in the Right Details Inspector")

				im.SameLine()
				if im.SmallButton("Get") {
					context.allocator = runtime.default_allocator()
					cpos := (_vs.canvas.size * 0.34) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					engine.vg_add_node(&_vs.graph, .Get_Variable, {cpos.x, cpos.y}, v.name)
					_vs.dirty_unbaked = true
				}
				widgets.tooltip("Spawn Get node (`● Copy` & `◆ ^Ref` outputs)")
				im.SameLine()
				if im.SmallButton("Set") {
					context.allocator = runtime.default_allocator()
					cpos := (_vs.canvas.size * 0.38) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					engine.vg_add_node(&_vs.graph, .Set_Variable, {cpos.x, cpos.y}, v.name)
					_vs.dirty_unbaked = true
				}
				im.PopID()
			}

			im.SetNextItemWidth(134)
			im.InputTextWithHint("##new_vname", "var_name", cstring(raw_data(_vs.new_var_buf[:])), len(_vs.new_var_buf))
			im.SameLine()
			vtype_items := [5]struct{ lbl: cstring, pt: hot.Hot_Pin_Type }{
				{"bool", .Bool},
				{"i32",  .Int},
				{"f32",  .Float},
				{"Vec2", .Vec2},
				{"Vec3", .Vec3},
			}
			cur_vt_idx: i32 = 2
			for item, idx in vtype_items {
				if i32(item.pt) == _vs.new_var_type do cur_vt_idx = i32(idx)
			}
			vt_lbls := [5]cstring{"bool", "i32", "f32", "Vec2", "Vec3"}
			im.SetNextItemWidth(62)
			if im.ComboChar("##new_vtype", &cur_vt_idx, raw_data(vt_lbls[:]), 5) {
				_vs.new_var_type = i32(vtype_items[clamp(cur_vt_idx, 0, 4)].pt)
			}
			if im.Button("+ Add Variable", {-1, 0}) {
				vn := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_var_buf[:])), context.temp_allocator)
				if vn != "" && engine.vg_find_var_index(&_vs.graph, vn) < 0 {
					context.allocator = runtime.default_allocator()
					append(&_vs.graph.variables, engine.VG_Var_Decl{
						name              = strings.clone(vn),
						pin_type          = hot.Hot_Pin_Type(_vs.new_var_type),
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

		// --- Section 3: Custom Odin Delegates (`◇`) ---
		if im.CollapsingHeader("Odin Delegates (◇)", {.DefaultOpen}) {
			for d, di in _vs.graph.delegates {
				im.PushIDInt(i32(1000 + di))
				im.TextColored({0.22, 0.94, 0.92, 1.0}, "%s", fmt.ctprintf("◇ %s", d))
				if im.SmallButton("Bind") {
					context.allocator = runtime.default_allocator()
					cpos := (_vs.canvas.size * 0.36) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					uid := engine.vg_add_node(&_vs.graph, .Delegate_Bind, {cpos.x, cpos.y}, d)
					_vs.selected_node_uid = uid
					_vs.dirty_unbaked = true
				}
				im.SameLine()
				if im.SmallButton("Unbind") {
					context.allocator = runtime.default_allocator()
					cpos := (_vs.canvas.size * 0.40) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					uid := engine.vg_add_node(&_vs.graph, .Delegate_Unbind, {cpos.x, cpos.y}, d)
					_vs.selected_node_uid = uid
					_vs.dirty_unbaked = true
				}
				im.SameLine()
				if im.SmallButton("Broadcast") {
					context.allocator = runtime.default_allocator()
					cpos := (_vs.canvas.size * 0.44) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
					uid := engine.vg_add_node(&_vs.graph, .Delegate_Broadcast, {cpos.x, cpos.y}, d)
					_vs.selected_node_uid = uid
					_vs.dirty_unbaked = true
				}
				im.PopID()
			}

			im.SetNextItemWidth(154)
			im.InputTextWithHint("##new_del_nm", "On_Damaged...", cstring(raw_data(_vs.new_del_buf[:])), len(_vs.new_del_buf))
			im.SameLine()
			if im.Button("+ ◇ Del") {
				dnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_del_buf[:])), context.temp_allocator)
				if dnm != "" {
					exists := false
					for ed in _vs.graph.delegates do if ed == dnm { exists = true; break }
					if !exists {
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
			im.TextColored({0.94, 0.95, 0.98, 1.0}, "  ▷  Exec Flow")
			im.TextColored({0.22, 0.94, 0.92, 1.0}, "  ◇  Odin Delegate (Proc)")
			im.TextColored({0.42, 0.88, 0.54, 1.0}, "  ●  Copy Value (T)")
			im.TextColored({1.00, 0.46, 0.66, 1.0}, "  ◆  Mutable Ref (^T)")
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
	cur_lbl := n.hot_proc_target != "" ? n.hot_proc_target : "<Select ◇ Procedure>"
	im.SetNextItemWidth(-1)
	if im.BeginCombo("##det_target_proc", fmt.ctprintf("◇ %s", cur_lbl)) {
		for pnm in proc_names {
			if im.Selectable(fmt.ctprintf("◇ %s (Blueprint Proc)", pnm), n.hot_proc_target == pnm) {
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(pnm)
				_vs.dirty_unbaked = true
			}
		}
		im.Separator()
		for hp in engine.hot_proc_entries() {
			if im.Selectable(fmt.ctprintf("@(hot_proc) %s", hp.name), n.hot_proc_target == hp.name) {
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(hp.name)
				_vs.dirty_unbaked = true
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Select which Blueprint Procedure (`◇`) or `@(hot_proc)` this node binds/unbinds (or drag a `◇` wire on the canvas!)")

	if im.Button("+ Create & Wire New ◇ Procedure", {-1, 0}) {
		base_nm := n.action_name != "" ? fmt.tprintf("On_%s", sanitize_odin_ident(n.action_name, context.temp_allocator)) : "On_Bound_Event"
		cand := base_nm
		suffix := 2
		for engine.vg_find_custom_proc_node(&_vs.graph, cand) != nil {
			cand = fmt.tprintf("%s_%d", base_nm, suffix)
			suffix += 1
		}
		context.allocator = runtime.default_allocator()
		p_uid := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry, {max(n.pos.x - 320.0, 20.0), n.pos.y + 150.0}, cand)
		if n.hot_proc_target != "" do delete(n.hot_proc_target)
		n.hot_proc_target = strings.clone(cand)
		// Auto-wire `◇ Delegate` output pin (`0`) into `◇ Target Proc` input pin (`1`)!
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
	widgets.tooltip("Spawns a matching `◇ Custom Procedure` node and automatically connects its `◇ Delegate` wire!")
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

			im.TextColored({0.24, 0.78, 0.96, 1.0}, "Blueprint Variable")
			im.TextDisabled("Variable Name:")
			im.SetNextItemWidth(-1)
			if im.InputText("##var_ren", cstring(raw_data(_vs.rename_buf[:])), len(_vs.rename_buf), {.EnterReturnsTrue}) {
				new_nm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.rename_buf[:])), context.temp_allocator)
				if new_nm != "" && new_nm != v.name && engine.vg_find_var_index(&_vs.graph, new_nm) < 0 {
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

			im.TextDisabled("Odin Type: %s", fmt.ctprintf("%s", engine.vg_pin_odin_type(v.pin_type)))
			if im.Checkbox("👁 Instance Editable (Scene Inspector)", &v.instance_editable) {
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
			widgets.tooltip("When checked, every entity with this Blueprint attached displays a per-instance editable control in the Scene Inspector!")

			im.Separator()
			im.TextDisabled("Default Value:")
			#partial switch v.pin_type {
			case .Bool:
				if im.Checkbox("Default Bool##vd_b", &v.default_bool) {
					if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_bool = v.default_bool
					_vs.dirty_unbaked = true
				}
			case .Int:
				if im.DragInt("##vd_i", &v.default_int, 1.0) {
					if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_int = v.default_int
					_vs.dirty_unbaked = true
				}
			case .Float:
				if im.DragFloat("##vd_f", &v.default_f32, 0.02) {
					if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_f32 = v.default_f32
					_vs.dirty_unbaked = true
				}
				im.TextDisabled("Inspector Slider Range (Min / Max):")
				im.SetNextItemWidth(115)
				if im.DragFloat("##vd_smin", &v.slider_min, 0.1) do _vs.dirty_unbaked = true
				im.SameLine()
				im.SetNextItemWidth(115)
				if im.DragFloat("##vd_smax", &v.slider_max, 0.1) do _vs.dirty_unbaked = true
			case .Vec2:
				if im.DragFloat2("##vd_v2", &v.default_vec2, 0.05) {
					if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_vec2 = v.default_vec2
					_vs.dirty_unbaked = true
				}
			case .Vec3:
				if im.DragFloat3("##vd_v3", &v.default_vec3, 0.05) {
					if vi < engine.VG_MAX_VARS do _vs.preview_bb.slots[vi].val_vec3 = v.default_vec3
					_vs.dirty_unbaked = true
				}
			}

			im.Separator()
			im.TextDisabled("Category:")
			im.SetNextItemWidth(-1)
			if im.InputTextWithHint("##vd_cat", "Gameplay / Movement...", cstring(raw_data(_vs.cat_buf[:])), len(_vs.cat_buf)) {
				context.allocator = runtime.default_allocator()
				if v.category != "" do delete(v.category)
				v.category = strings.clone(_c_str(_vs.cat_buf[:]))
				_vs.dirty_unbaked = true
			}

			im.TextDisabled("Inspector Tooltip:")
			im.SetNextItemWidth(-1)
			if im.InputTextWithHint("##vd_tip", "Describe variable...", cstring(raw_data(_vs.tip_buf[:])), len(_vs.tip_buf)) {
				context.allocator = runtime.default_allocator()
				if v.tooltip_text != "" do delete(v.tooltip_text)
				v.tooltip_text = strings.clone(_c_str(_vs.tip_buf[:]))
				_vs.dirty_unbaked = true
			}

			im.Separator()
			if im.Button("Delete Variable", {-1, 0}) {
				context.allocator = runtime.default_allocator()
				if v.name         != "" do delete(v.name)
				if v.category     != "" do delete(v.category)
				if v.tooltip_text != "" do delete(v.tooltip_text)
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
			cat, col := _node_category_and_color(n.kind)
			im.TextColored(col, "%s", fmt.ctprintf("%s", cat))
			im.SameLine()
			im.TextDisabled("(#%d)", n.uid)
			im.TextWrapped("%s", fmt.ctprintf("%s", n.title))
			if im.Checkbox("Node Enabled", &n.enabled) {
				_vs.dirty_unbaked = true
			}
			im.Separator()

			#partial switch n.kind {
			case .Bind_Input_Action, .Unbind_Input_Action:
				im.TextDisabled("Input Manager Action:")
				actions := engine.visual_script_list_input_actions(context.temp_allocator)
				cur_act := n.action_name != "" ? n.action_name : "Jump"
				im.SetNextItemWidth(-1)
				if im.BeginCombo("##det_act_combo", fmt.ctprintf("%s", cur_act)) {
					for act in actions {
						if im.Selectable(fmt.ctprintf("%s", act), n.action_name == act) {
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
					if anm != "" {
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
						n.trigger_edge    = hot.Hot_Trigger_Edge(edge_i)
						_vs.dirty_unbaked = true
					}
					im.TextDisabled("Listener Priority:")
					im.SetNextItemWidth(-1)
					if im.DragInt("##det_prio", &n.input_priority, 1.0, -100, 1000) {
						_vs.dirty_unbaked = true
					}
					if im.Checkbox("Consume Input (Block lower priority)", &n.consume_input) {
						_vs.dirty_unbaked = true
					}
					im.Separator()
					im.TextDisabled("◇ Bound Target Procedure:")
					_draw_target_proc_selector(n)
				}

			case .Bind_Input_Vector, .Unbind_Input_Vector:
				chan_lbls := [2]cstring{"Movement Vector ([2]f32)", "Look / Aim Vector ([2]f32)"}
				chan_i: i32 = n.is_look_vector ? 1 : 0
				im.TextDisabled("Vector Channel:")
				im.SetNextItemWidth(-1)
				if im.ComboChar("##det_vchan", &chan_i, raw_data(chan_lbls[:]), 2) {
					n.is_look_vector = chan_i == 1
					context.allocator = runtime.default_allocator()
					delete(n.title)
					n.title = strings.clone(fmt.tprintf("%s Input Vector (%s)", n.kind == .Bind_Input_Vector ? "Bind" : "Unbind", n.is_look_vector ? "Look" : "Move"))
					_vs.dirty_unbaked = true
				}
				if n.kind == .Bind_Input_Vector {
					im.SetNextItemWidth(-1)
					if im.DragInt("Priority##det_vprio", &n.input_priority, 1.0, -100, 1000) do _vs.dirty_unbaked = true
					if im.Checkbox("Consume Vector", &n.consume_input) do _vs.dirty_unbaked = true
					im.Separator()
					im.TextDisabled("◇ Bound Target Procedure:")
					_draw_target_proc_selector(n)
				}

			case .Bind_Debug_Key, .Unbind_Debug_Key:
				im.TextColored({0.96, 0.56, 0.72, 1.0}, "[DEV] Direct Scancode Binding")
				im.SetNextItemWidth(-1)
				if im.BeginCombo("##det_dbg_key", _debug_key_label(n.debug_key_code)) {
					for preset in _DEBUG_KEY_PRESETS {
						if im.Selectable(preset.label, n.debug_key_code == preset.code) {
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
						n.trigger_edge    = hot.Hot_Trigger_Edge(edge_i)
						_vs.dirty_unbaked = true
					}
					im.Separator()
					im.TextDisabled("◇ Bound Target Procedure:")
					_draw_target_proc_selector(n)
				}

			case .Delegate_Bind, .Delegate_Unbind, .Delegate_Broadcast:
				im.TextDisabled("Custom Odin Delegate:")
				cur_d := n.delegate_name != "" ? n.delegate_name : "<Select Delegate>"
				im.SetNextItemWidth(-1)
				if im.BeginCombo("##det_del_nm", fmt.ctprintf("◇ %s", cur_d)) {
					for d in _vs.graph.delegates {
						if im.Selectable(fmt.ctprintf("◇ %s", d), n.delegate_name == d) {
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
					im.TextDisabled("◇ Target Procedure:")
					_draw_target_proc_selector(n)
				}

			case .Custom_Proc_Entry:
				if _vs.rename_target_uid != n.uid {
					_vs.rename_target_uid = n.uid
					_set_c_buf(_vs.rename_buf[:], n.hot_proc_target)
				}
				im.TextDisabled("Procedure Identifier (◇):")
				im.SetNextItemWidth(-1)
				if im.InputText("##det_proc_ren", cstring(raw_data(_vs.rename_buf[:])), len(_vs.rename_buf), {.EnterReturnsTrue}) {
					new_p := sanitize_odin_ident(strings.trim_space(_c_str(_vs.rename_buf[:])), context.temp_allocator)
					if new_p != "" && new_p != n.hot_proc_target && engine.vg_find_custom_proc_node(&_vs.graph, new_p) == nil {
						old_p := n.hot_proc_target
						context.allocator = runtime.default_allocator()
						for &other in _vs.graph.nodes {
							if other.uid != n.uid && other.hot_proc_target == old_p {
								delete(other.hot_proc_target)
								other.hot_proc_target = strings.clone(new_p)
							}
						}
						delete(n.hot_proc_target)
						n.hot_proc_target = strings.clone(new_p)
						delete(n.title)
						n.title = strings.clone(fmt.tprintf("◇ Proc: %s", new_p))
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
				}
				im.TextDisabled("Drag `◇ Delegate` pin into any `Bind` / `Unbind` node!")

			case .Call_Blueprint_Proc:
				im.TextDisabled("Target Blueprint Procedure:")
				_draw_target_proc_selector(n)

			case .Odin_Function_Node:
				if im.Button(fmt.ctprintf("%s Open Scoped Popup IDE", icons.ICON_MD_CODE), {-1, 0}) {
					_open_odin_node_in_popup_ide(n)
				}
				im.Separator()
				im.TextDisabled("Add Input Pin:")
				im.SetNextItemWidth(138)
				im.InputTextWithHint("##det_pnm", "pin_name", cstring(raw_data(_vs.new_pin_buf[:])), len(_vs.new_pin_buf))
				im.SameLine()
				pt_lbls := [3]cstring{"f32", "Vec2", "Vec3"}
				pt_sel := clamp(_vs.new_pin_type, 0, 2)
				im.SetNextItemWidth(68)
				if im.ComboChar("##det_pt", &pt_sel, raw_data(pt_lbls[:]), 3) {
					_vs.new_pin_type = pt_sel
				}
				im.Checkbox("Pass By Reference (◆ ^T)##det_pref", &_vs.new_pin_is_ref)
				if im.Button("+ Add Pin to Node", {-1, 0}) {
					pnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_pin_buf[:])), context.temp_allocator)
					if pnm != "" {
						context.allocator = runtime.default_allocator()
						pt: hot.Hot_Pin_Type = .Float
						if _vs.new_pin_type == 1 do pt = .Vec2
						if _vs.new_pin_type == 2 do pt = .Vec3
						append(&n.inputs, engine.VG_Pin_Def{
							name      = strings.clone(pnm),
							pin_type  = pt,
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
						if im.Checkbox(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &ip.default_bool) do _vs.dirty_unbaked = true
					case .Int:
						if im.DragInt(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &ip.default_int, 1.0) do _vs.dirty_unbaked = true
					case .Float:
						if im.DragFloat(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &ip.default_f32, 0.05) do _vs.dirty_unbaked = true
					case .Vec2:
						if im.DragFloat2(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &ip.default_vec2, 0.05) do _vs.dirty_unbaked = true
					case .Vec3:
						if im.DragFloat3(fmt.ctprintf("%s##uwd_%d", ip.name, ipi), &ip.default_vec3, 0.05) do _vs.dirty_unbaked = true
					}
				}
			}

			im.Separator()
			if im.Button("Delete Selected Node", {-1, 0}) {
				_delete_node_by_uid(n.uid)
			}
			return
		}

		// --- Mode C: Blueprint Class Overview ---
		im.TextDisabled("Blueprint Asset:")
		im.TextWrapped("%s", fmt.ctprintf("%s", _vs.graph_rel_path))
		im.Separator()
		im.TextDisabled("Active Using Spaces:")
		for sp in _vs.graph.using_spaces {
			im.BulletText("%s", fmt.ctprintf("using %s", sp))
		}
		im.Separator()
		im.TextDisabled("Select any Variable, Procedure, or Graph Node to inspect its properties.")
}

// =============================================================================
// Main Entry: 3-Column Unreal/Odin Blueprint Studio Window
// =============================================================================

@(private = "file")
_pin_pos_in :: proc(n: ^engine.VG_Node, pin_i: int) -> im.Vec2 {
	return nc.canvas_to_screen(&_vs.canvas, {n.pos.x, n.pos.y + nc.NIAGARA_HEADER_H + 14.0 + f32(pin_i) * 22.0})
}

@(private = "file")
_pin_pos_out :: proc(n: ^engine.VG_Node, node_idx: int, pin_i: int) -> im.Vec2 {
	w := nc.canvas_get_node_size(&_vs.canvas, 100 + node_idx, {290, 90}).x
	return nc.canvas_to_screen(&_vs.canvas, {n.pos.x + w, n.pos.y + nc.NIAGARA_HEADER_H + 14.0 + f32(pin_i) * 22.0})
}

draw_visual_script_studio_window :: proc() {
	ensure_visual_script_init()
	p  := thm.palette()
	io := im.GetIO()

	_draw_blueprint_top_toolbar()
	im.Separator()

	avail   := im.GetContentRegionAvail()
	left_w  := f32(252.0)
	right_w := f32(276.0)
	mid_w   := max(avail.x - left_w - right_w - 16.0, 260.0)

	// COLUMN 1: Left Dock (*My Blueprint*)
	_draw_left_my_blueprint_dock(avail.y)

	im.SameLine()

	// COLUMN 2: Center Blueprint & Niagara Graph Canvas
	{
		center_open := im.BeginChild("##bp_center_canvas_host", {mid_w, avail.y})
		defer im.EndChild()
		if center_open {
			if nc.canvas_begin(&_vs.canvas, "##mh_visual_script_canvas") {
				dl := im.GetWindowDrawList()
				zm := _vs.canvas.zoom

				pos_arr := make([]im.Vec2, len(_vs.graph.nodes), context.temp_allocator)
				for n, i in _vs.graph.nodes do pos_arr[i] = {n.pos.x, n.pos.y}

				endpoints := make([dynamic]_Pin_Endpoint, 0, 96, context.temp_allocator)

			// 1. Draw Existing Wires Underneath Niagara Cards
			for wire in _vs.graph.wires {
				src_n := engine.vg_find_node(&_vs.graph, wire.from_uid)
				dst_n := engine.vg_find_node(&_vs.graph, wire.to_uid)
				if src_n == nil || dst_n == nil do continue
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
				lbl: cstring = is_del_wire ? "◇ Delegate" : (is_ref_wire ? "◆ ^Ref" : (pdef.pin_type == .Exec ? nil : "● Copy"))
				nc.canvas_link(&_vs.canvas, p0, p1, im.GetColorU32ImVec4(wcol), (is_ref_wire || is_del_wire) ? 2.6 : 2.1, (pdef.pin_type == .Exec || is_del_wire) ? 0.9 : 0.35, lbl, pdef.pin_type == .Exec)
			}

			// 2. Draw Every Graph Node as an Auto-Sizing Niagara / Blueprint Module Block!
			delete_node_uid := 0
			for &n, ni in _vs.graph.nodes {
				cat, col := _node_category_and_color(n.kind)
				npos := im.Vec2{n.pos.x, n.pos.y}

				b, open := nc.canvas_niagara_block_begin(&_vs.canvas, &npos, {
					id                 = 100 + ni,
					title              = fmt.ctprintf("%s", n.title),
					category           = cat,
					step_badge         = fmt.ctprintf("#%d", n.uid),
					color              = col,
					min_width          = n.kind == .Odin_Function_Node ? 336.0 : 276.0,
					label_col_width    = 98.0,
					ctrl_col_width     = 148.0,
					enabled_ptr        = &n.enabled,
					has_code_btn       = n.kind == .Odin_Function_Node || n.kind == .Call_Hot_Proc,
					all_node_positions = pos_arr,
					base_node_id       = 100,
				})
				n.pos = {npos.x, npos.y}
				pos_arr[ni] = npos

				if b.selected && im.IsMouseClicked(.Left) {
					_vs.selected_node_uid = n.uid
					_vs.selected_var_idx  = -1
				}

				if open {
					max_pins := max(len(n.inputs), len(n.outputs))
					for pi in 0 ..< max_pins {
						in_lbl: cstring  = nil
						out_lbl: cstring = nil
						out_c := im.Vec4{}
						if pi < len(n.inputs) {
							ip := n.inputs[pi]
							badge := ip.pin_type == .Exec ? "▷ " : (ip.pin_type == .Delegate ? "◇ " : (ip.pass_mode == .By_Reference ? "◆ ^" : "● "))
							in_lbl = ip.pin_type == .Delegate \
								? fmt.ctprintf("%s%s", badge, ip.name) \
								: fmt.ctprintf("%s%s (%s)", badge, ip.name, engine.vg_pin_odin_type(ip.pin_type))
						}
						if pi < len(n.outputs) {
							op := n.outputs[pi]
							badge := op.pin_type == .Exec ? "▷ " : (op.pin_type == .Delegate ? "◇ " : (op.is_addressable ? "◆ ^" : "● "))
							out_lbl = fmt.ctprintf("%s%s", badge, op.name)
							out_c = _pin_color(op)
						}
						nc.canvas_niagara_kv(&b, in_lbl, out_lbl, out_c)
					}

					// Compact Inline Summary Badges & Quick Controls per Node Kind
					#partial switch n.kind {
					case .Bind_Input_Action:
						edge_s := n.trigger_edge == .Pressed ? "Pressed" : (n.trigger_edge == .Released ? "Released" : "Both")
						tgt_s  := n.hot_proc_target != "" ? n.hot_proc_target : "<Wire ◇ or Pick in Details>"
						im.TextColored({0.98, 0.78, 0.36, 1.0}, "%s", fmt.ctprintf("  Action: \"%s\" [%s] -> ◇ %s", n.action_name, edge_s, tgt_s))

					case .Unbind_Input_Action:
						im.TextColored({0.84, 0.66, 0.48, 1.0}, "%s", fmt.ctprintf("  Unbind Action: \"%s\"", n.action_name))

					case .Bind_Input_Vector:
						tgt_s := n.hot_proc_target != "" ? n.hot_proc_target : "<Wire ◇>"
						im.TextColored({0.96, 0.76, 0.36, 1.0}, "%s", fmt.ctprintf("  %s [2]f32 -> ◇ %s", n.is_look_vector ? "Look" : "Move", tgt_s))

					case .Bind_Debug_Key:
						tgt_s := n.hot_proc_target != "" ? n.hot_proc_target : "<Wire ◇>"
						im.TextColored({0.96, 0.58, 0.74, 1.0}, "%s", fmt.ctprintf("  [DEV] %s -> ◇ %s", string(_debug_key_label(n.debug_key_code)), tgt_s))

					case .Delegate_Bind, .Delegate_Unbind, .Delegate_Broadcast:
						im.TextColored({0.26, 0.92, 0.88, 1.0}, "%s", fmt.ctprintf("  Delegate: ◇ %s", n.delegate_name))

					case .Call_Blueprint_Proc:
						im.TextColored({0.42, 0.84, 1.00, 1.0}, "%s", fmt.ctprintf("  Call: ◇ %s()", n.hot_proc_target))

					case .Math_Float:
						op_names := [6]cstring{"Add (A + B)", "Sub (A - B)", "Mul (A * B)", "Div (A / B)", "Sin Wave", "Exp Damp"}
						op_idx := i32(n.math_op)
						nc.canvas_niagara_param(&b, "Math Op")
						if im.ComboChar("##mop", &op_idx, raw_data(op_names[:]), 6) {
							n.math_op = engine.VG_Math_Op(op_idx)
							_vs.dirty_unbaked = true
						}

					case .Set_Time_Scale:
						if im.Checkbox("Per-Object TimeScale##ts_mode", &n.per_object_ts) {
							_vs.dirty_unbaked = true
						}
						if len(n.inputs) > 1 {
							nc.canvas_niagara_param(&b, "Time Scale")
							if im.SliderFloat("##ts_val", &n.inputs[1].default_f32, 0.0, 2.0, "%.2fx") {
								_vs.dirty_unbaked = true
							}
						}

					case .Odin_Function_Node:
						nc.canvas_niagara_section(&b, "PIN PASSING MODE (COPY vs ^REF)")
						for &ip, ipi in n.inputs {
							if ip.pin_type == .Exec || ip.pin_type == .Delegate do continue
							is_ref := ip.pass_mode == .By_Reference
							mode_lbl := is_ref \
								? fmt.ctprintf("◆ %s: ^%s (Ref)##pm_%d", ip.name, engine.vg_pin_odin_type(ip.pin_type), ipi) \
								: fmt.ctprintf("● %s: %s (Copy)##pm_%d", ip.name, engine.vg_pin_odin_type(ip.pin_type), ipi)
							if im.SmallButton(mode_lbl) {
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
							widgets.tooltip("Toggle input pin between `● Copy Value (T)` and `◆ Mutable Reference (^T)`")
						}

						nc.canvas_niagara_section(&b, "SCOPED ODIN BODY PREVIEW")
						lines := strings.split_lines(n.odin_body, context.temp_allocator)
						for li in 0 ..< min(len(lines), 3) {
							im.TextColored({0.78, 0.86, 0.98, 1.0}, "%s", fmt.ctprintf("  %s", lines[li]))
						}
						if im.Button(fmt.ctprintf("%s Edit Node Odin Code (Popup IDE)##ed_%d", icons.ICON_MD_CODE, n.uid), {b.visual_inner_w, 0}) {
							_vs.selected_node_uid = n.uid
							_vs.selected_var_idx  = -1
							_open_odin_node_in_popup_ide(&n)
						}
					}
				}

				if b.clicked_code || b.double_clicked_header {
					_vs.selected_node_uid = n.uid
					_vs.selected_var_idx  = -1
					if n.kind == .Odin_Function_Node {
						_open_odin_node_in_popup_ide(&n)
					} else if n.kind == .Call_Hot_Proc && n.hot_proc_target != "" {
						cs.open_scoped_proc_popup(n.hot_proc_target, "moonhug/hot_scripts/builtin_hot_scripts.odin", n.hot_proc_target)
					}
				}

				nc.canvas_niagara_block_end(&b)

				for ip, ipi in n.inputs {
					sp := _pin_pos_in(&n, ipi)
					append(&endpoints, _Pin_Endpoint{node_uid = n.uid, pin_idx = ipi, is_out = false, screen_p = sp, pin_def = ip})
				}
				for op, opi in n.outputs {
					sp := _pin_pos_out(&n, ni, opi)
					append(&endpoints, _Pin_Endpoint{node_uid = n.uid, pin_idx = opi, is_out = true, screen_p = sp, pin_def = op})
				}
			}

			for &n, ni in _vs.graph.nodes {
				n.pos = {pos_arr[ni].x, pos_arr[ni].y}
			}

			// 3. Pin Hit-Testing, Wire Dragging & `▷` / `◇` / `●` / `◆` Connection Enforcement!
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

			if hovered_ep >= 0 && im.IsMouseClicked(.Left) {
				ep := endpoints[hovered_ep]
				if !ep.is_out {
					detached := false
					for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
						w := _vs.graph.wires[wi]
						if w.to_uid == ep.node_uid && w.to_pin == ep.pin_idx {
							if src_n := engine.vg_find_node(&_vs.graph, w.from_uid); src_n != nil {
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
					_vs.drag_from_out = true
					_vs.drag_node_uid = ep.node_uid
					_vs.drag_pin_idx  = ep.pin_idx
					_vs.drag_pin_def  = ep.pin_def
				}
			}

			if _vs.dragging_wire {
				start_pt := io.MousePos
				for ep in endpoints {
					if ep.node_uid == _vs.drag_node_uid && ep.pin_idx == _vs.drag_pin_idx && ep.is_out == _vs.drag_from_out {
						start_pt = ep.screen_p
						break
					}
				}

				wire_lbl: cstring = _vs.drag_pin_def.pin_type == .Delegate ? "Drag ◇ Delegate to Bind / Unbind node" : "Drag to compatible pin"
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
								wire_lbl = "✓ Bind ◇ Odin Delegate Procedure"
							} else if dst_def.pass_mode == .By_Reference {
								wire_lbl = "✓ Bind ◆ ^Ref Pointer"
							} else {
								wire_lbl = "✓ Connect Wire"
							}
						} else {
							wire_col = {1.0, 0.28, 0.30, 1.0}
							wire_lbl = fmt.ctprintf("✗ %s", reject_why)
						}
					}
				}

				p_a := _vs.drag_from_out ? start_pt : end_pt
				p_b := _vs.drag_from_out ? end_pt   : start_pt
				nc.canvas_draw_wire(dl, p_a, p_b, im.GetColorU32ImVec4(wire_col), _vs.canvas.wire_style, 2.5, 0.9, zm, wire_lbl, true)

				if !im.IsMouseDown(.Left) {
					if hovered_ep >= 0 {
						cand := endpoints[hovered_ep]
						if cand.is_out != _vs.drag_from_out && cand.node_uid != _vs.drag_node_uid {
							from_uid := _vs.drag_from_out ? _vs.drag_node_uid : cand.node_uid
							from_pin := _vs.drag_from_out ? _vs.drag_pin_idx  : cand.pin_idx
							to_uid   := _vs.drag_from_out ? cand.node_uid     : _vs.drag_node_uid
							to_pin   := _vs.drag_from_out ? cand.pin_idx      : _vs.drag_pin_idx
							src_def  := _vs.drag_from_out ? _vs.drag_pin_def  : cand.pin_def
							dst_def  := _vs.drag_from_out ? cand.pin_def     : _vs.drag_pin_def

							if ok_conn, _ := engine.vg_can_connect_pins(src_def, dst_def); ok_conn {
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
								// Sync `hot_proc_target` when wiring a `Custom_Proc_Entry` `◇` pin into a `Bind_*` / `Unbind_*` node!
								if dst_def.pin_type == .Delegate {
									src_n := engine.vg_find_node(&_vs.graph, from_uid)
									dst_n := engine.vg_find_node(&_vs.graph, to_uid)
									if src_n != nil && dst_n != nil && src_n.kind == .Custom_Proc_Entry && src_n.hot_proc_target != "" {
										if dst_n.hot_proc_target != "" do delete(dst_n.hot_proc_target)
										dst_n.hot_proc_target = strings.clone(src_n.hot_proc_target)
									}
								}
								_vs.selected_node_uid = to_uid
								_vs.selected_var_idx  = -1
								_vs.dirty_unbaked     = true
							}
						}
					}
					_vs.dragging_wire = false
				}
			}

			// 4. Categorized Right-Click Fuzzy Context Search Menu!
			if nc.canvas_begin_context_menu(&_vs.canvas, pos_arr, 100, _vs.dragging_wire) {
				ctx_ni := _vs.canvas.ctx_hovered_id - 100
				if ctx_ni >= 0 && ctx_ni < len(_vs.graph.nodes) {
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
					if im.MenuItem("Delete Node") {
						delete_node_uid = cn.uid
					}
					im.Separator()
				}

				_vs.ctx_spawn_canvas = (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
				im.TextColored(p.accent, icons.ICON_MD_SEARCH + " Blueprint & Odin-Delegate Search")
				im.SetNextItemWidth(290)
				im.InputTextWithHint("##vg_ctx_q", "Search bind, unbind, input, delegate, odin, var...", cstring(raw_data(_vs.ctx_search_buf[:])), len(_vs.ctx_search_buf))
				q := strings.to_lower(_c_str(_vs.ctx_search_buf[:]), context.temp_allocator)

				spawn_pos := [2]f32{_vs.ctx_spawn_canvas.x, _vs.ctx_spawn_canvas.y}
				palette_items := [20]struct{ label: string, kind: engine.VG_Node_Kind, arg: string }{
					{"[Input] Bind Input Action -> ◇ Procedure",         .Bind_Input_Action,   "Jump"},
					{"[Input] Unbind Input Action (Dynamic Swap)",       .Unbind_Input_Action, "Jump"},
					{"[Input] Bind Input Vector (Move / Look) -> ◇ Proc",.Bind_Input_Vector,   ""},
					{"[Input] Unbind Input Vector",                      .Unbind_Input_Vector, ""},
					{"[DEV] Bind Debug Key (Scancode) -> ◇ Procedure",   .Bind_Debug_Key,      ""},
					{"[DEV] Unbind Debug Key",                           .Unbind_Debug_Key,    ""},
					{"[Input] Unbind All Inputs (Self)",                 .Unbind_All_Inputs,   ""},
					{"[◇] + Custom Procedure / Event Entry (◇ Pin)",     .Custom_Proc_Entry,   "On_Custom_Event"},
					{"[◇] Bind Custom Odin Delegate",                    .Delegate_Bind,       "On_Signal"},
					{"[◇] Unbind Custom Odin Delegate",                  .Delegate_Unbind,     "On_Signal"},
					{"[◇] Broadcast Custom Odin Delegate",               .Delegate_Broadcast,  "On_Signal"},
					{"[Event] On Init (BeginPlay / Spawn)",              .Event_Init,          ""},
					{"[Event] On Tick (Opt-In Frame Update)",            .Event_Tick,          ""},
					{"[Event] On Destroy (EndPlay Cleanup)",             .Event_Destroy,       ""},
					{"[Odin] Scoped Odin Function Node (`</>` + `using`)",.Odin_Function_Node, ""},
					{"[Transform] Get Position (`● Copy` & `◆ ^Ref`)",   .Get_Transform_Pos,   ""},
					{"[Transform] Set Position",                         .Set_Transform_Pos,   ""},
					{"[Math] Float Math (Add / Mul / Sin / Damp)",       .Math_Float,          ""},
					{"[Math] Vec3 + Axis * Scale",                       .Vec3_Scale_Add,      ""},
					{"[Flow] Branch (If / Else) | Set Time Scale",       .Branch_If,           ""},
				}
				for item in palette_items {
					if q != "" && !strings.contains(strings.to_lower(item.label, context.temp_allocator), q) do continue
					if im.MenuItem(fmt.ctprintf("%s", item.label)) {
						context.allocator = runtime.default_allocator()
						arg := item.arg
						if item.kind == .Custom_Proc_Entry {
							idx := 1
							for engine.vg_find_custom_proc_node(&_vs.graph, arg) != nil {
								idx += 1
								arg = fmt.tprintf("On_Custom_Event_%d", idx)
							}
						}
						uid := engine.vg_add_node(&_vs.graph, item.kind, spawn_pos, arg)
						_vs.selected_node_uid = uid
						_vs.selected_var_idx  = -1
						_vs.dirty_unbaked     = true
						_sync_ide_blueprint_context()
						if item.kind == .Odin_Function_Node {
							if nn := engine.vg_find_node(&_vs.graph, uid); nn != nil {
								_open_odin_node_in_popup_ide(nn)
							}
						}
					}
				}
				if q == "" || strings.contains("set time scale timescale slowmo", q) {
					if im.MenuItem("[Time] Set Time Scale (Object / Global)") {
						context.allocator = runtime.default_allocator()
						_vs.selected_node_uid = engine.vg_add_node(&_vs.graph, .Set_Time_Scale, spawn_pos)
						_vs.dirty_unbaked = true
					}
				}

				// Blueprint Custom Procedures (`Call ◇ <Proc>`)
				for cn in _vs.graph.nodes {
					if cn.kind == .Custom_Proc_Entry && cn.hot_proc_target != "" {
						lbl := fmt.tprintf("Call Blueprint Proc ◇ %s()", cn.hot_proc_target)
						if q != "" && !strings.contains(strings.to_lower(lbl, context.temp_allocator), q) do continue
						if im.MenuItem(fmt.ctprintf("%s", lbl)) {
							context.allocator = runtime.default_allocator()
							_vs.selected_node_uid = engine.vg_add_node(&_vs.graph, .Call_Blueprint_Proc, spawn_pos, cn.hot_proc_target)
							_vs.dirty_unbaked = true
						}
					}
				}

				// Registered `@(hot_proc)` library procedures
				for hp in engine.hot_proc_entries() {
					lbl := fmt.tprintf("Call @(hot_proc) %s", hp.name)
					if q != "" && !strings.contains(strings.to_lower(lbl, context.temp_allocator), q) do continue
					if im.MenuItem(fmt.ctprintf("%s", lbl)) {
						context.allocator = runtime.default_allocator()
						_vs.selected_node_uid = engine.vg_add_node(&_vs.graph, .Call_Hot_Proc, spawn_pos, hp.name)
						_vs.dirty_unbaked = true
					}
				}

				// Blueprint Variables (`Get ● Copy & ◆ ^Ref` + `Set`)
				if len(_vs.graph.variables) > 0 {
					im.Separator()
					im.TextDisabled("Blueprint Variables (using self)")
					for v in _vs.graph.variables {
						if q != "" && !strings.contains(strings.to_lower(v.name, context.temp_allocator), q) && !strings.contains("variable get set ref", q) {
							continue
						}
						if im.MenuItem(fmt.ctprintf("Get `%s` (● Copy & ◆ ^Ref)", v.name)) {
							context.allocator = runtime.default_allocator()
							_vs.selected_node_uid = engine.vg_add_node(&_vs.graph, .Get_Variable, spawn_pos, v.name)
							_vs.dirty_unbaked = true
						}
						if im.MenuItem(fmt.ctprintf("Set `%s`", v.name)) {
							context.allocator = runtime.default_allocator()
							_vs.selected_node_uid = engine.vg_add_node(&_vs.graph, .Set_Variable, spawn_pos, v.name)
							_vs.dirty_unbaked = true
						}
					}
				}

				im.Separator()
				nc.canvas_draw_default_context_menu_items(&_vs.canvas, pos_arr, 100)
				im.EndPopup()
			}

			if delete_node_uid != 0 {
				_delete_node_by_uid(delete_node_uid)
			}
			}
			nc.canvas_end(&_vs.canvas)
		}
	}

	im.SameLine()

	// COLUMN 3: Right Dock (*Details Inspector*)
	_draw_right_details_inspector(avail.y)
}
