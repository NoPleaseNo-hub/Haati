package visual_script

// =============================================================================
// UNIFIED GRAPH STUDIO CANVAS, POPUPS & WIRE ROUTING (`vs_canvas.odin`)
// =============================================================================
// Subgraph navigation bar, embedded scoped IDE panel, pin drop/right-click
// context menus, interactive wire routing, and `draw_visual_script_studio_window`.

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import cs "haati:editor/code_studio"
import "haati:editor/icons"
import nc "haati:editor/node_canvas"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import "haati:engine"
import hot "haati:engine/hot_api"
import im "haati:external/odin-imgui"

@(private)
_pin_pos_in :: proc(n: ^engine.VG_Node, pin_i: int) -> im.Vec2 {
	return nc.canvas_to_screen(&_vs.canvas, {n.pos.x, n.pos.y + nc.NODE_HEADER_H + 14.0 + f32(pin_i) * 22.0})
}

@(private)
_pin_pos_out :: proc(n: ^engine.VG_Node, node_idx: int, pin_i: int) -> im.Vec2 {
	w := nc.canvas_get_node_size(&_vs.canvas, node_idx, {290, 90}).x
	return nc.canvas_to_screen(&_vs.canvas, {n.pos.x + w, n.pos.y + nc.NODE_HEADER_H + 14.0 + f32(pin_i) * 22.0})
}

@(private)
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

@(private)
_connect_vg_wire_checked :: proc(from_uid, from_pin, to_uid, to_pin: int, push_undo := true) -> bool {
	src_n := engine.vg_find_node(&_vs.graph, from_uid)
	dst_n := engine.vg_find_node(&_vs.graph, to_uid)
	if src_n == nil || dst_n == nil || from_uid == to_uid do return false
	if from_pin < 0 || from_pin >= len(src_n.outputs) do return false
	if to_pin < 0 || to_pin >= len(dst_n.inputs) do return false

	src_def := src_n.outputs[from_pin]
	dst_def := dst_n.inputs[to_pin]
	direct_ok, needs_cast, _ := engine.vg_can_connect_or_autocast_pins(src_def, dst_def)
	if !direct_ok && !needs_cast do return false

	if push_undo do vs_push_undo()
	context.allocator = runtime.default_allocator()
	for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
		ew := _vs.graph.wires[wi]
		if (ew.to_uid == to_uid && ew.to_pin == to_pin && dst_def.pin_type != .Exec) ||
		   (src_def.pin_type == .Exec && ew.from_uid == from_uid && ew.from_pin == from_pin) {
			ordered_remove(&_vs.graph.wires, wi)
		}
	}

	if needs_cast && !direct_ok {
		src_pos   := src_n.pos
		dst_pos   := dst_n.pos
		owner     := dst_n.owner_proc != "" ? dst_n.owner_proc : src_n.owner_proc
		mid       := [2]f32{(src_pos.x + dst_pos.x) * 0.5, (src_pos.y + dst_pos.y) * 0.5}
		cast_uid  := engine.vg_add_node(&_vs.graph, .Auto_Cast, mid)
		if cn := engine.vg_find_node(&_vs.graph, cast_uid); cn != nil {
			if owner != "" {
				if cn.owner_proc != "" do delete(cn.owner_proc)
				cn.owner_proc = strings.clone(owner)
			}
			if len(cn.inputs) > 0 {
				cn.inputs[0].pin_type = src_def.pin_type
				cn.inputs[0].is_array = src_def.is_array
				if cn.inputs[0].custom_type_name != "" do delete(cn.inputs[0].custom_type_name)
				cn.inputs[0].custom_type_name = src_def.custom_type_name != "" ? strings.clone(src_def.custom_type_name) : ""
			}
			if len(cn.outputs) > 0 {
				cn.outputs[0].pin_type = dst_def.pin_type
				cn.outputs[0].is_array = dst_def.is_array
				if cn.outputs[0].custom_type_name != "" do delete(cn.outputs[0].custom_type_name)
				cn.outputs[0].custom_type_name = dst_def.custom_type_name != "" ? strings.clone(dst_def.custom_type_name) : ""
			}
			delete(cn.title)
			src_tl := src_def.custom_type_name != "" ? src_def.custom_type_name : engine.vg_pin_odin_type(src_def.pin_type, false)
			dst_tl := dst_def.custom_type_name != "" ? dst_def.custom_type_name : engine.vg_pin_odin_type(dst_def.pin_type, false)
			cn.title = strings.clone(fmt.tprintf("%s -> %s", src_tl, dst_tl))
		}
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = from_uid, from_pin = from_pin, to_uid = cast_uid, to_pin = 0})
		append(&_vs.graph.wires, engine.VG_Wire{from_uid = cast_uid, from_pin = 0, to_uid = to_uid, to_pin = to_pin})
	} else {
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
	}
	_vs.selected_node_uid = to_uid
	_vs.selected_var_idx  = -1
	_vs.dirty_unbaked     = true
	return true
}

@(private)
_is_exec_wire_hot :: proc(bb: ^engine.VG_Runtime_Blackboard, src_uid, dst_uid: int) -> bool {
	if bb == nil || len(bb.last_exec_path) < 2 do return false
	for k := 0; k < len(bb.last_exec_path) - 1; k += 1 {
		if bb.last_exec_path[k] == src_uid && bb.last_exec_path[k + 1] == dst_uid {
			return true
		}
	}
	return false
}

@(private)
_dist_point_to_segment :: proc(pt, a, b: im.Vec2) -> f32 {
	ab := b - a
	l2 := ab.x * ab.x + ab.y * ab.y
	if l2 < 1e-4 do return linalg.length(pt - a)
	t := clamp(((pt.x - a.x) * ab.x + (pt.y - a.y) * ab.y) / l2, 0.0, 1.0)
	return linalg.length(pt - (a + ab * t))
}

@(private)
_dist_point_to_wire :: proc(pt, p0, p1: im.Vec2, zm: f32) -> f32 {
	tang := max(abs(p1.x - p0.x) * 0.45, 42.0 * zm)
	c1 := im.Vec2{p0.x + tang, p0.y}
	c2 := im.Vec2{p1.x - tang, p1.y}
	best := f32(1e9)
	prev := p0
	for s in 1 ..= 8 {
		t := f32(s) / 8.0
		u := 1.0 - t
		cur := p0 * (u*u*u) + c1 * (3.0*u*u*t) + c2 * (3.0*u*t*t) + p1 * (t*t*t)
		best = min(best, _dist_point_to_segment(pt, prev, cur))
		prev = cur
	}
	return best
}

@(private)
_sever_wires_on_pin :: proc(node_uid, pin_idx: int, is_out: bool, push_undo := true) -> int {
	removed := 0
	for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
		w := _vs.graph.wires[wi]
		match := (is_out && w.from_uid == node_uid && w.from_pin == pin_idx) ||
		         (!is_out && w.to_uid == node_uid && w.to_pin == pin_idx)
		if match {
			if push_undo && removed == 0 do vs_push_undo()
			ordered_remove(&_vs.graph.wires, wi)
			removed += 1
		}
	}
	if removed > 0 do _vs.dirty_unbaked = true
	return removed
}

@(private)
_insert_reroute_knot_on_wire :: proc(wire_idx: int, canvas_pos: [2]f32) {
	if wire_idx < 0 || wire_idx >= len(_vs.graph.wires) do return
	w := _vs.graph.wires[wire_idx]
	src_n := engine.vg_find_node(&_vs.graph, w.from_uid)
	if src_n == nil || w.from_pin < 0 || w.from_pin >= len(src_n.outputs) do return
	pdef := src_n.outputs[w.from_pin]

	vs_push_undo()
	context.allocator = runtime.default_allocator()
	knot_arg := pdef.pin_type == .Exec ? "Exec" : ""
	k_uid := engine.vg_add_node(&_vs.graph, .Reroute_Knot, canvas_pos, knot_arg)
	if kn := engine.vg_find_node(&_vs.graph, k_uid); kn != nil {
		sub := _active_subgraph_str()
		if sub != "" {
			if kn.owner_proc != "" do delete(kn.owner_proc)
			kn.owner_proc = strings.clone(sub)
		}
		if len(kn.inputs) > 0 {
			kn.inputs[0].pin_type = pdef.pin_type
			kn.inputs[0].is_array = pdef.is_array
			if kn.inputs[0].custom_type_name != "" do delete(kn.inputs[0].custom_type_name)
			kn.inputs[0].custom_type_name = pdef.custom_type_name != "" ? strings.clone(pdef.custom_type_name) : ""
		}
		if len(kn.outputs) > 0 {
			kn.outputs[0].pin_type = pdef.pin_type
			kn.outputs[0].is_array = pdef.is_array
			if kn.outputs[0].custom_type_name != "" do delete(kn.outputs[0].custom_type_name)
			kn.outputs[0].custom_type_name = pdef.custom_type_name != "" ? strings.clone(pdef.custom_type_name) : ""
		}
	}
	ordered_remove(&_vs.graph.wires, wire_idx)
	append(&_vs.graph.wires, engine.VG_Wire{from_uid = w.from_uid, from_pin = w.from_pin, to_uid = k_uid, to_pin = 0})
	append(&_vs.graph.wires, engine.VG_Wire{from_uid = k_uid, from_pin = 0, to_uid = w.to_uid, to_pin = w.to_pin})
	_vs.selected_node_uid = k_uid
	_vs.selected_var_idx  = -1
	_vs.dirty_unbaked     = true
}

@(private)
_collapse_selected_to_odin_node :: proc() -> bool {
	sel_uids := make([dynamic]int, 0, 8, context.temp_allocator)
	sum_pos  := [2]f32{0, 0}
	for &n, ni in _vs.graph.nodes {
		if !_is_node_visible_in_subgraph(&n) do continue
		if n.kind == .Event_Init || n.kind == .Event_Tick || n.kind == .Event_Destroy || n.kind == .Event_On_Trigger || n.kind == .Custom_Proc_Entry do continue
		if nc.canvas_is_selected(&_vs.canvas, ni) || n.uid == _vs.selected_node_uid {
			dup := false
			for u in sel_uids do if u == n.uid { dup = true; break }
			if !dup {
				append(&sel_uids, n.uid)
				sum_pos += n.pos
			}
		}
	}
	if len(sel_uids) == 0 do return false

	in_sel :: proc(uids: []int, uid: int) -> bool {
		for u in uids do if u == uid do return true
		return false
	}

	_Pin_Key :: struct {
		uid:  int,
		pin:  int,
		pdef: engine.VG_Pin_Def,
	}
	ext_in  := make([dynamic]_Pin_Key, 0, 8, context.temp_allocator)
	ext_out := make([dynamic]_Pin_Key, 0, 8, context.temp_allocator)

	for w in _vs.graph.wires {
		from_in := in_sel(sel_uids[:], w.from_uid)
		to_in   := in_sel(sel_uids[:], w.to_uid)
		if !from_in && to_in {
			if dn := engine.vg_find_node(&_vs.graph, w.to_uid); dn != nil && w.to_pin >= 0 && w.to_pin < len(dn.inputs) {
				dp := dn.inputs[w.to_pin]
				if dp.pin_type != .Exec {
					found := false
					for ek in ext_in do if ek.uid == w.from_uid && ek.pin == w.from_pin { found = true; break }
					if !found do append(&ext_in, _Pin_Key{uid = w.from_uid, pin = w.from_pin, pdef = dp})
				}
			}
		} else if from_in && !to_in {
			if sn := engine.vg_find_node(&_vs.graph, w.from_uid); sn != nil && w.from_pin >= 0 && w.from_pin < len(sn.outputs) {
				sp := sn.outputs[w.from_pin]
				if sp.pin_type != .Exec {
					found := false
					for ek in ext_out do if ek.uid == w.from_uid && ek.pin == w.from_pin { found = true; break }
					if !found do append(&ext_out, _Pin_Key{uid = w.from_uid, pin = w.from_pin, pdef = sp})
				}
			}
		}
	}

	vs_push_undo()
	context.allocator = runtime.default_allocator()
	centroid := [2]f32{sum_pos.x / f32(len(sel_uids)), sum_pos.y / f32(len(sel_uids))}
	new_uid := engine.vg_add_node(&_vs.graph, .Odin_Function_Node, centroid, "Collapsed_Odin_Block")
	if nn := engine.vg_find_node(&_vs.graph, new_uid); nn != nil {
		sub := _active_subgraph_str()
		if sub != "" {
			if nn.owner_proc != "" do delete(nn.owner_proc)
			nn.owner_proc = strings.clone(sub)
		}
		for len(nn.inputs) > 1 {
			p := pop(&nn.inputs)
			delete(p.name)
			delete(p.custom_type_name)
			delete(p.default_str)
		}
		for len(nn.outputs) > 1 {
			p := pop(&nn.outputs)
			delete(p.name)
			delete(p.custom_type_name)
			delete(p.default_str)
		}
		for ek, idx in ext_in {
			base := sanitize_odin_ident(ek.pdef.name, context.temp_allocator)
			if base == "" do base = "in"
			pnm := fmt.tprintf("%s_%d", base, idx)
			append(&nn.inputs, engine.VG_Pin_Def{
				name             = strings.clone(pnm),
				pin_type         = ek.pdef.pin_type,
				is_array         = ek.pdef.is_array,
				custom_type_name = ek.pdef.custom_type_name != "" ? strings.clone(ek.pdef.custom_type_name) : "",
			})
		}
		for ek, idx in ext_out {
			base := sanitize_odin_ident(ek.pdef.name, context.temp_allocator)
			if base == "" do base = "out"
			pnm := fmt.tprintf("%s_%d", base, idx)
			append(&nn.outputs, engine.VG_Pin_Def{
				name             = strings.clone(pnm),
				pin_type         = ek.pdef.pin_type,
				is_array         = ek.pdef.is_array,
				custom_type_name = ek.pdef.custom_type_name != "" ? strings.clone(ek.pdef.custom_type_name) : "",
			})
		}
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "// Collapsed %d BP_Nodes into native Odin scope:\n", len(sel_uids))
		for uid in sel_uids {
			if sn := engine.vg_find_node(&_vs.graph, uid); sn != nil {
				fmt.sbprintf(&sb, "//   - #%d %s\n", sn.uid, sn.title)
			}
		}
		for opi := 1; opi < len(nn.outputs); opi += 1 {
			if opi - 1 < len(nn.inputs) - 1 && nn.inputs[opi].pin_type == nn.outputs[opi].pin_type {
				fmt.sbprintf(&sb, "%s = %s\n", nn.outputs[opi].name, nn.inputs[opi].name)
			}
		}
		if nn.odin_body != "" do delete(nn.odin_body)
		nn.odin_body = strings.clone(strings.to_string(sb))
	}

	for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
		w := &_vs.graph.wires[wi]
		from_in := in_sel(sel_uids[:], w.from_uid)
		to_in   := in_sel(sel_uids[:], w.to_uid)
		if from_in && to_in {
			ordered_remove(&_vs.graph.wires, wi)
		} else if !from_in && to_in {
			dn := engine.vg_find_node(&_vs.graph, w.to_uid)
			if dn != nil && w.to_pin >= 0 && w.to_pin < len(dn.inputs) && dn.inputs[w.to_pin].pin_type == .Exec {
				w.to_uid = new_uid
				w.to_pin = 0
			} else {
				mapped := 1
				for ek, idx in ext_in {
					if ek.uid == w.from_uid && ek.pin == w.from_pin { mapped = 1 + idx; break }
				}
				w.to_uid = new_uid
				w.to_pin = mapped
			}
		} else if from_in && !to_in {
			sn := engine.vg_find_node(&_vs.graph, w.from_uid)
			if sn != nil && w.from_pin >= 0 && w.from_pin < len(sn.outputs) && sn.outputs[w.from_pin].pin_type == .Exec {
				w.from_uid = new_uid
				w.from_pin = 0
			} else {
				mapped := 1
				for ek, idx in ext_out {
					if ek.uid == w.from_uid && ek.pin == w.from_pin { mapped = 1 + idx; break }
				}
				w.from_uid = new_uid
				w.from_pin = mapped
			}
		}
	}

	for uid in sel_uids {
		_delete_node_by_uid(uid, false)
	}
	nc.canvas_clear_selection(&_vs.canvas)
	for n, ni in _vs.graph.nodes {
		if n.uid == new_uid { nc.canvas_set_selected(&_vs.canvas, ni, true); break }
	}
	_vs.selected_node_uid = new_uid
	_vs.selected_var_idx  = -1
	_vs.dirty_unbaked     = true
	_sync_ide_blueprint_context()
	return true
}

@(private)
_draw_pin_right_click_popup :: proc() {
	if !im.BeginPopup("##vs_pin_context_popup") do return
	defer im.EndPopup()

	nd := engine.vg_find_node(&_vs.graph, _vs.pin_ctx_uid)
	if nd == nil {
		im.TextDisabled("Pin no longer exists")
		return
	}
	pins := _vs.pin_ctx_is_out ? nd.outputs[:] : nd.inputs[:]
	if _vs.pin_ctx_idx < 0 || _vs.pin_ctx_idx >= len(pins) {
		im.TextDisabled("Invalid pin index")
		return
	}
	pdef := pins[_vs.pin_ctx_idx]
	im.TextColored(_pin_color(pdef), "%s", fmt.ctprintf("%s (%s)", pdef.name, pdef.custom_type_name != "" ? pdef.custom_type_name : engine.vg_pin_odin_type(pdef.pin_type, pdef.is_array)))
	im.Separator()

	if engine.vg_can_split_pin(&_vs.graph, pdef) {
		if im.MenuItem("Split Pin Inline (Components / Fields)") {
			vs_push_undo()
			context.allocator = runtime.default_allocator()
			if engine.vg_split_pin_inline(&_vs.graph, _vs.pin_ctx_uid, _vs.pin_ctx_is_out, _vs.pin_ctx_idx) {
				_vs.dirty_unbaked = true
			}
		}
	}
	if pdef.split_expanded || pdef.split_parent_name != "" {
		if im.MenuItem("Recombine Split Pin") {
			vs_push_undo()
			context.allocator = runtime.default_allocator()
			if engine.vg_recombine_split_pin(&_vs.graph, _vs.pin_ctx_uid, _vs.pin_ctx_is_out, _vs.pin_ctx_idx) {
				_prune_oob_wires_for_node(_vs.pin_ctx_uid)
				_vs.dirty_unbaked = true
			}
		}
	}
	if pdef.pin_type != .Exec && pdef.pin_type != .Delegate {
		if im.MenuItem("Promote to Variable") {
			vs_push_undo()
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			defer context.allocator = prev_alloc
			nd_uid   := nd.uid
			nd_pos   := nd.pos
			nd_owner := nd.owner_proc != "" ? strings.clone(nd.owner_proc, context.temp_allocator) : ""
			base := sanitize_odin_ident(pdef.name, context.temp_allocator)
			if base == "" do base = "promoted_var"
			vnm := base
			suf := 2
			for engine.vg_find_var_index(&_vs.graph, vnm) >= 0 {
				vnm = fmt.tprintf("%s_%d", base, suf)
				suf += 1
			}
			append(&_vs.graph.variables, engine.VG_Var_Decl{
				name              = strings.clone(vnm),
				pin_type          = pdef.pin_type,
				is_array          = pdef.is_array,
				custom_type_name  = pdef.custom_type_name != "" ? strings.clone(pdef.custom_type_name) : "",
				instance_editable = true,
				category          = strings.clone("Default"),
				slider_max        = 10.0,
			})
			vpos := nd_pos + (_vs.pin_ctx_is_out ? [2]f32{300, 0} : [2]f32{-290, 0})
			vkind: engine.VG_Node_Kind = _vs.pin_ctx_is_out ? .Set_Variable : .Get_Variable
			v_uid := engine.vg_add_node(&_vs.graph, vkind, vpos, vnm)
			if vn := engine.vg_find_node(&_vs.graph, v_uid); vn != nil {
				if nd_owner != "" {
					if vn.owner_proc != "" do delete(vn.owner_proc)
					vn.owner_proc = strings.clone(nd_owner)
				}
				compat := engine.vg_find_compatible_pin_on_node(_vs.pin_ctx_is_out, pdef, vn)
				if compat >= 0 {
					if _vs.pin_ctx_is_out {
						_connect_vg_wire_checked(nd_uid, _vs.pin_ctx_idx, v_uid, compat, push_undo = false)
					} else {
						_connect_vg_wire_checked(v_uid, compat, _vs.pin_ctx_uid, _vs.pin_ctx_idx, push_undo = false)
					}
				}
			}
			_vs.dirty_unbaked = true
			_sync_ide_blueprint_context()
		}
	}
	if im.MenuItem("Disconnect All Wires [Alt+Click]") {
		_sever_wires_on_pin(_vs.pin_ctx_uid, _vs.pin_ctx_idx, _vs.pin_ctx_is_out, push_undo = true)
	}
}

@(private)
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

@(private)
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

Delegate_Bind_Target_Kind :: enum u8 {
	Custom_Event,
	Hot_Proc,
}

Delegate_Bind_Target :: struct {
	kind:        Delegate_Bind_Target_Kind,
	name:        string,
	source_file: string,
	node_uid:    int,
}

// Collects all bindable targets for a `.Delegate` pin (`Custom_Proc_Entry` nodes on the
// active Blueprint graph plus `@(hot_proc)` targets), filtered by `query`.
collect_delegate_pin_bind_targets :: proc(
	g:               ^engine.Visual_Graph,
	query:           string = "",
	extra_hot_procs: []string = nil,
	allocator := context.temp_allocator,
) -> [dynamic]Delegate_Bind_Target {
	out   := make([dynamic]Delegate_Bind_Target, 0, 16, allocator)
	seen  := make(map[string]bool, 32, context.temp_allocator)
	terms := widgets.search_terms(query)

	if g != nil {
		for n in g.nodes {
			if n.kind != .Custom_Proc_Entry do continue
			name := n.hot_proc_target != "" ? n.hot_proc_target : n.title
			if name == "" || seen[name] do continue
			if !widgets.search_match(name, terms) do continue
			seen[name] = true
			append(&out, Delegate_Bind_Target{
				kind     = .Custom_Event,
				name     = name,
				node_uid = n.uid,
			})
		}
	}

	for he in engine.hot_proc_entries() {
		if he.name == "" || strings.has_prefix(he.name, "mhgraph_") || seen[he.name] do continue
		if !widgets.search_match(fmt.tprintf("%s %s", he.name, he.source_file), terms) do continue
		seen[he.name] = true
		append(&out, Delegate_Bind_Target{
			kind        = .Hot_Proc,
			name        = he.name,
			source_file = he.source_file,
		})
	}

	for name in extra_hot_procs {
		if name == "" || strings.has_prefix(name, "mhgraph_") || seen[name] do continue
		if !widgets.search_match(name, terms) do continue
		seen[name] = true
		append(&out, Delegate_Bind_Target{
			kind = .Hot_Proc,
			name = name,
		})
	}

	return out
}

@(private)
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
	widgets.text_coloredf(
		_pin_color(_vs.pin_drop_pin_def),
		"%s %s Pin: %s (%s)",
		icons.ICON_MD_BOLT,
		dir_txt,
		_vs.pin_drop_pin_def.name,
		t_txt,
	)

	auto_focus := _vs.pin_drop_focus_search || im.IsWindowAppearing()
	_vs.pin_drop_focus_search = false
	sr := widgets.search_bar(_vs.pin_drop_search_buf[:], widgets.Search_Bar_Opts{
		id         = "##vs_pin_drop_q",
		hint       = "Filter compatible BP_Nodes, Custom Events, @(hot_proc)...",
		mode       = .Popup,
		width      = 360,
		auto_focus = auto_focus,
	})
	if sr.escape_close {
		_vs.pin_drop_pending = false
		im.CloseCurrentPopup()
		return
	}
	im.Separator()

	spawn_pos := [2]f32{_vs.pin_drop_canvas.x, _vs.pin_drop_canvas.y - 36.0}
	q_raw := strings.trim_space(sr.query)

	// Quick Custom Event & Delegate Binding actions for `.Delegate` pins (`Input` and `Output`)
	is_delegate_pin := _vs.pin_drop_pin_def.pin_type == .Delegate
	is_delegate_in  := !_vs.pin_drop_from_out && is_delegate_pin
	is_delegate_out := _vs.pin_drop_from_out  && is_delegate_pin
	del_targets: [dynamic]Delegate_Bind_Target
	if is_delegate_in {
		if widgets.menu_item_colored(
			fmt.ctprintf("%s + Create & Wire New Custom Event", icons.ICON_MD_DIAMOND),
			thm.studio_pin_color(.Delegate),
		) {
			_create_and_wire_custom_event_for_node(_vs.pin_drop_from_uid, _vs.pin_drop_from_pin, {max(spawn_pos.x - 280.0, 20.0), spawn_pos.y})
			im.CloseCurrentPopup()
			_vs.pin_drop_pending = false
			return
		}
		del_targets = collect_delegate_pin_bind_targets(&_vs.graph, q_raw, nil, context.temp_allocator)
		im.Separator()
	} else if is_delegate_out {
		if widgets.menu_item_colored(
			fmt.ctprintf("%s + Bind Input Action", icons.ICON_MD_BOLT),
			thm.studio_pin_color(.Delegate),
		) {
			b_uid := _spawn_graph_node(.Bind_Input_Action, spawn_pos, "Jump")
			_connect_vg_wire_checked(_vs.pin_drop_from_uid, _vs.pin_drop_from_pin, b_uid, 1, push_undo = false)
			im.CloseCurrentPopup()
			_vs.pin_drop_pending = false
			return
		}
		if widgets.menu_item_colored(
			fmt.ctprintf("%s + Bind Custom Odin Delegate", icons.ICON_MD_DIAMOND),
			thm.studio_pin_color(.Delegate),
		) {
			d_uid := _spawn_graph_node(.Delegate_Bind, spawn_pos, "On_Event")
			_connect_vg_wire_checked(_vs.pin_drop_from_uid, _vs.pin_drop_from_pin, d_uid, 1, push_undo = false)
			im.CloseCurrentPopup()
			_vs.pin_drop_pending = false
			return
		}
		im.Separator()
	}

	// Quick auto-wired Scoped Odin BP_Node for any data pin (including Bool / Int / Vec2 / String)
	if _vs.pin_drop_pin_def.pin_type != .Exec && !is_delegate_pin {
		odin_lbl := fmt.ctprintf("%s + Scoped Odin BP_Node (%s %s)", icons.ICON_MD_CODE, t_txt, _vs.pin_drop_from_out ? "In" : "Out")
		if widgets.menu_item_colored(odin_lbl, p.accent) {
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
		im.Separator()
	}

	items := _collect_palette_items(context.temp_allocator)
	compat_count := 0
	for &item in items {
		if is_delegate_in && item.kind == .Custom_Proc_Entry do continue
		item.compat_pin = engine.vg_probe_compatible_pin(&_vs.graph, item.kind, item.arg, _vs.pin_drop_from_out, _vs.pin_drop_pin_def)
		if item.compat_pin >= 0 do compat_count += 1
	}

	if im.BeginChild("##vs_pin_drop_scroll", {380, 290}) {
		if is_delegate_in && len(del_targets) > 0 {
			ce_count := 0
			hp_count := 0
			for dt in del_targets {
				if dt.kind == .Custom_Event {
					ce_count += 1
				} else {
					hp_count += 1
				}
			}
			if ce_count > 0 {
				widgets.popup_header(icons.ICON_MD_DIAMOND, "Custom Events in Graph", thm.studio_pin_color(.Delegate))
				for dt in del_targets {
					if dt.kind != .Custom_Event do continue
					if im.MenuItem(fmt.ctprintf("Bind Event: %s %s##bind_ex_%d", icons.ICON_MD_DIAMOND, dt.name, dt.node_uid)) {
						_connect_vg_wire_checked(dt.node_uid, 0, _vs.pin_drop_from_uid, _vs.pin_drop_from_pin, push_undo = true)
						im.CloseCurrentPopup()
						_vs.pin_drop_pending = false
						break
					}
				}
			}
			if hp_count > 0 && _vs.pin_drop_pending {
				widgets.popup_header(icons.ICON_MD_BOLT, "@(hot_proc) Targets", p.accent)
				for dt, hpi in del_targets {
					if dt.kind != .Hot_Proc do continue
					if im.MenuItem(fmt.ctprintf("Bind @(hot_proc): %s %s##bind_hp_%d", icons.ICON_MD_BOLT, dt.name, hpi)) {
						vs_push_undo()
						_sever_wires_on_pin(_vs.pin_drop_from_uid, _vs.pin_drop_from_pin, false, push_undo = false)
						if dst_n := engine.vg_find_node(&_vs.graph, _vs.pin_drop_from_uid); dst_n != nil {
							context.allocator = runtime.default_allocator()
							if dst_n.hot_proc_target != "" do delete(dst_n.hot_proc_target)
							dst_n.hot_proc_target = strings.clone(dt.name)
							_vs.dirty_unbaked = true
						}
						im.CloseCurrentPopup()
						_vs.pin_drop_pending = false
						break
					}
				}
			}
			if compat_count > 0 {
				im.Separator()
			}
		}

		if compat_count == 0 {
			if !is_delegate_pin {
				im.TextDisabled("No built-in BP_Nodes match this pin type.")
			} else if is_delegate_in && len(del_targets) == 0 && q_raw != "" {
				im.TextDisabled("No Custom Events or @(hot_proc) targets match your filter.")
			}
		} else {
			if _draw_namespace_palette_filtered(
				items[:],
				spawn_pos,
				q_raw,
				only_compat = true,
				auto_expand_max = 14,
				tree_prefix = "pdrop_ns",
				auto_wire_pin_drop = true,
				empty_search_msg = "No compatible BP_Nodes match your search.",
			) {
				_vs.pin_drop_pending = false
			}
		}
	}
	im.EndChild()
}

@(private = "file")
_draw_inline_priority_param :: proc(b: ^nc.Node_Block_Ctx, n: ^engine.VG_Node, widget_id: cstring) {
	nc.canvas_bp_node_param(b, "Priority")
	pri_i := n.input_priority
	pri_ch := im.DragInt(widget_id, &pri_i, 1.0, -100, 1000, "Pri: %d")
	_record_undo_on_widget_activate()
	if pri_ch {
		n.input_priority  = pri_i
		_vs.dirty_unbaked = true
	}
}

@(private = "file")
_draw_inline_bool_field :: proc(label: cstring, val: ^bool) {
	v := val^
	if im.Checkbox(label, &v) {
		vs_push_undo()
		val^ = v
		_vs.dirty_unbaked = true
	}
}

@(private = "file")
_draw_inline_pin_f32_param :: proc(
	b: ^nc.Node_Block_Ctx,
	n: ^engine.VG_Node,
	pin_idx: int,
	label: cstring,
	widget_id: cstring,
	speed: f32,
	min_v: f32,
	max_v: f32,
	fmt_str: cstring,
	is_drag := false,
) {
	if len(n.inputs) <= pin_idx do return
	nc.canvas_bp_node_param(b, label)
	val := n.inputs[pin_idx].default_f32
	ch := is_drag \
		? im.DragFloat(widget_id, &val, speed, min_v, max_v, fmt_str) \
		: im.SliderFloat(widget_id, &val, min_v, max_v, fmt_str)
	_record_undo_on_widget_activate()
	if ch {
		n.inputs[pin_idx].default_f32 = val
		_vs.dirty_unbaked = true
	}
}

@(private)
_draw_embedded_scoped_node_or_proc :: proc(n: ^engine.VG_Node, avail_sz: im.Vec2) {
	if n == nil {
		im.TextDisabled("Select an Odin Function Node or Custom Procedure to edit its scoped Odin body.")
		return
	}
	_sync_ide_blueprint_context()
	badges := collect_node_scoped_pin_badges(&_vs.graph, n, context.temp_allocator)

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

	upd, edited, trig_hs := cs.sync_and_draw_embedded_scoped_editor(n.uid, n.title, sig, badges, n.odin_body, avail_sz)
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

@(private)
_draw_subgraph_tab_bar_and_header :: proc() -> ^engine.VG_Node {
	p   := thm.palette()
	st  := thm.studio_tokens()
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
		col := cn.proc_use_odin_body ? thm.with_alpha(st.subgraph_odin_tint, 0.42) : thm.with_alpha(st.subgraph_bp_tint, 0.40)
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
		_spawn_graph_node(.Custom_Proc_Entry, _canvas_view_spawn_pos(0.25), cand)
	}

	// Procedure Header Bar when viewing a specific Custom Procedure Sub-Graph
	if sub != "" && !_vs.show_all_subgraph_nodes {
		if entry := engine.vg_find_custom_proc_node(&_vs.graph, sub); entry != nil {
			im.Separator()
			widgets.text_coloredf(thm.studio_pin_color(.Delegate), "%s PROCEDURE: %s", icons.ICON_MD_DIAMOND, entry.hot_proc_target)

			im.SameLine(0, 10)
			bp_col   := !entry.proc_use_odin_body ? thm.with_alpha(st.subgraph_bp_tint, 0.44) : thm.with_alpha(p.text_muted, 0.14)
			odin_col := entry.proc_use_odin_body  ? thm.with_alpha(st.subgraph_odin_tint, 0.46) : thm.with_alpha(p.text_muted, 0.14)
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
	st := thm.studio_tokens()
	io := im.GetIO()

	_vs.window_hovered = im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows)
	_vs.window_focused = im.IsWindowFocused({.RootWindow, .ChildWindows})

	// 1. Unified Domain Content Filter Switcher
	_draw_unified_domain_switcher_bar()
	im.Separator()

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

						// Build O(1) per-frame lookup maps for node UIDs & wired pin membership
						uid_to_idx := make(map[int]int, max(len(_vs.graph.nodes), 1), context.temp_allocator)
						for &nd, ni in _vs.graph.nodes {
							uid_to_idx[nd.uid] = ni
						}
						_Pin_Key :: struct { uid: int, pin: int }
						wired_inputs  := make(map[_Pin_Key]bool, max(len(_vs.graph.wires), 1), context.temp_allocator)
						wired_outputs := make(map[_Pin_Key]bool, max(len(_vs.graph.wires), 1), context.temp_allocator)
						for w in _vs.graph.wires {
							wired_outputs[_Pin_Key{w.from_uid, w.from_pin}] = true
							wired_inputs[_Pin_Key{w.to_uid, w.to_pin}]     = true
						}

						// 1. Draw Existing Wires Underneath Node Blocks (only between visible nodes!)
						dbg_bb, dbg_ent := _active_debug_bb()
						_Drawn_Wire :: struct {
							wire_idx: int,
							p0, p1:   im.Vec2,
						}
						drawn_wires := make([dynamic]_Drawn_Wire, 0, len(_vs.graph.wires), context.temp_allocator)

						for wire, wire_idx in _vs.graph.wires {
							src_idx, src_ok := uid_to_idx[wire.from_uid]
							dst_idx, dst_ok := uid_to_idx[wire.to_uid]
							if !src_ok || !dst_ok do continue
							src_n := &_vs.graph.nodes[src_idx]
							dst_n := &_vs.graph.nodes[dst_idx]
							if !_is_node_visible_in_subgraph(src_n) || !_is_node_visible_in_subgraph(dst_n) do continue
							if wire.from_pin < 0 || wire.from_pin >= len(src_n.outputs) do continue
							if wire.to_pin   < 0 || wire.to_pin   >= len(dst_n.inputs)  do continue

							p0   := _pin_pos_out(src_n, src_idx, wire.from_pin)
							p1   := _pin_pos_in(dst_n, wire.to_pin)
							append(&drawn_wires, _Drawn_Wire{wire_idx = wire_idx, p0 = p0, p1 = p1})

							pdef := src_n.outputs[wire.from_pin]
							wcol := _pin_color(pdef)
							is_ref_wire := dst_n.inputs[wire.to_pin].pass_mode == .By_Reference
							is_del_wire := pdef.pin_type == .Delegate
							is_hot_exec := pdef.pin_type == .Exec && _is_exec_wire_hot(dbg_bb, src_n.uid, dst_n.uid)
							if is_hot_exec {
								wcol = thm.studio_exec_pulse_color(f32(im.GetTime()))
							}
							ck  := thm.studio_resolve_container(pdef.pin_type, pdef.is_array, false, is_ref_wire)
							lbl := thm.STUDIO_CONTAINER_TABLE[ck].wire_badge
							nc.canvas_link(
								&_vs.canvas,
								p0,
								p1,
								im.GetColorU32ImVec4(wcol),
								is_hot_exec ? 3.5 : ((is_ref_wire || is_del_wire) ? 2.6 : 2.1),
								is_hot_exec ? 2.2 : ((pdef.pin_type == .Exec || is_del_wire) ? 0.9 : 0.35),
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
							lbl_col_w:  f32 = 96.0
							ctrl_col_w: f32 = 162.0
							if n.kind == .Odin_Function_Node do min_card_w = 336.0
							if n.kind == .Bind_Input_Action || n.kind == .Bind_Input_Vector || n.kind == .Bind_Debug_Key || n.kind == .Delegate_Bind {
								min_card_w = 304.0
							}
							if n.kind == .Auto_Cast || n.kind == .Reroute_Knot || n.kind == .Break_Loop || n.kind == .Continue_Loop {
								min_card_w = 164.0
								lbl_col_w  = 58.0
								ctrl_col_w = 80.0
							}

							b, open := nc.canvas_bp_node_begin(&_vs.canvas, &npos, {
								id                 = ni,
								title              = fmt.ctprintf("%s", n.title),
								category           = cat,
								step_badge         = fmt.ctprintf("#%d", n.uid),
								color              = col,
								min_width          = min_card_w,
								label_col_width    = lbl_col_w,
								ctrl_col_width     = ctrl_col_w,
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
										if ip.split_expanded {
											in_lbl = fmt.ctprintf("%s %s (Split)", icons.ICON_MD_EXPAND_MORE, clean_in)
										} else {
											badge := ip.pin_type == .Exec \
												? icons.ICON_MD_PLAY_ARROW \
												: (ip.pin_type == .Delegate ? icons.ICON_MD_DIAMOND : (ip.pass_mode == .By_Reference ? icons.ICON_MD_DIAMOND : icons.ICON_MD_CIRCLE))
											in_type_nm := ip.custom_type_name != "" ? ip.custom_type_name : engine.vg_pin_odin_type(ip.pin_type, ip.is_array)
											if ip.pin_type == .Delegate || ip.pin_type == .Exec {
												in_lbl = fmt.ctprintf("%s %s", badge, clean_in)
											} else if ip.pass_mode == .By_Reference {
												in_lbl = fmt.ctprintf("%s ^%s (%s)", badge, clean_in, in_type_nm)
											} else {
												in_lbl = fmt.ctprintf("%s %s (%s)", badge, clean_in, in_type_nm)
											}
										}
									}
									if pi < len(n.outputs) {
										op := n.outputs[pi]
										clean_out := strings.trim_space(strings.trim_prefix(op.name, "\u25c7"))
										if op.split_expanded {
											out_lbl = fmt.ctprintf("%s %s (Split)", icons.ICON_MD_EXPAND_MORE, clean_out)
										} else {
											badge := op.pin_type == .Exec \
												? icons.ICON_MD_PLAY_ARROW \
												: (op.pin_type == .Delegate ? icons.ICON_MD_DIAMOND : (op.is_addressable ? icons.ICON_MD_DIAMOND : icons.ICON_MD_CIRCLE))
											out_lbl = fmt.ctprintf("%s %s", badge, clean_out)
										}
										out_c = _pin_color(op)
									}
									nc.canvas_bp_node_kv(&b, in_lbl, out_lbl, out_c)
								}

								// Zero-Spaghetti Compact Inline Unwired Input Widgets
								if n.kind != .Odin_Function_Node && n.kind != .Auto_Cast && n.kind != .Reroute_Knot &&
								   n.kind != .Break_Loop && n.kind != .Continue_Loop && n.kind != .Custom_Proc_Entry &&
								   n.kind != .Event_Init && n.kind != .Event_Tick && n.kind != .Event_Destroy && n.kind != .Event_On_Trigger {
									inl_cnt := 0
									for &ip, ipi in n.inputs {
										if inl_cnt >= 3 do break
										if ip.split_expanded || ip.pin_type == .Exec || ip.pin_type == .Delegate ||
										   ip.pin_type == .Entity || ip.pin_type == .Struct_Val ||
										   ip.pass_mode == .By_Reference || ip.is_array {
											continue
										}
										if (n.kind == .Set_Time_Scale && ipi == 1) ||
										   (n.kind == .Anim_Blend_Layered && ipi == 2) ||
										   (n.kind == .VFX_Emitter_Spawn && ipi == 1) {
											continue
										}
										if wired_inputs[_Pin_Key{n.uid, ipi}] do continue
										nc.canvas_bp_node_param(&b, fmt.ctprintf("%s", ip.name))
										if _draw_default_value_widgets(
											&_vs.graph, fmt.tprintf("inl_%d_%d", n.uid, ipi), ip.pin_type, ip.custom_type_name,
											&ip.default_bool, &ip.default_int, &ip.default_i64, &ip.default_u64,
											&ip.default_f32, &ip.default_f64, &ip.default_vec2, &ip.default_vec3, &ip.default_vec4,
											&ip.default_str, "", 138.0 * zm, compact = true,
										) {
											_vs.dirty_unbaked = true
										}
										inl_cnt += 1
									}
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

									_draw_inline_priority_param(&b, &n, fmt.ctprintf("##inl_pri_%d", n.uid))
									_draw_inline_bool_field(fmt.ctprintf("Consume Input##inl_con_%d", n.uid), &n.consume_input)
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
									_draw_inline_priority_param(&b, &n, fmt.ctprintf("##inl_vpri_%d", n.uid))
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
									_draw_inline_priority_param(&b, &n, fmt.ctprintf("##inl_dkpri_%d", n.uid))
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Delegate_Bind:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  Delegate: %s %s", icons.ICON_MD_DIAMOND, n.delegate_name), thm.studio_pin_color(.Delegate))
									_draw_inline_target_proc_combo(&b, &n, &create_evt_for_uid)

								case .Delegate_Unbind, .Delegate_Broadcast:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  Delegate: %s %s", icons.ICON_MD_DIAMOND, n.delegate_name), thm.studio_pin_color(.Delegate))

								case .Call_Blueprint_Proc:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  Call: %s %s()", icons.ICON_MD_DIAMOND, n.hot_proc_target), st.sig_call_fg)
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
									_draw_inline_bool_field("Per-Object TimeScale##ts_mode", &n.per_object_ts)
									_draw_inline_pin_f32_param(&b, &n, 1, "Time Scale", "##ts_val", 0, 0.0, 2.0, "%.2fx")

								case .Anim_Blend_Layered:
									_draw_inline_pin_f32_param(&b, &n, 2, "Layer Alpha", "##an_alpha", 0, 0.0, 1.0, "%.2f")

								case .VFX_Emitter_Spawn:
									_draw_inline_pin_f32_param(&b, &n, 1, "Spawn Rate", "##vfx_rate", 1.0, 0.0, 5000.0, "%.1f /s", is_drag = true)

								case .VFX_GPU_Curl_Force:
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  %s On-GPU / SIMD Curl Field", icons.ICON_MD_BLUR_ON), st.node_meta_fg)

								case .For_Loop:
									mode_tag := "Range ..="
									switch n.for_mode {
									case .Range_Inclusive: mode_tag = "Range ..="
									case .Range_Half_Open: mode_tag = "Range ..<"
									case .For_In_Value:    mode_tag = "for elem in"
									case .For_In_Ref:      mode_tag = "for &elem in"
									case .Condition:       mode_tag = "for cond"
									}
									nc.canvas_bp_node_text(&b, fmt.ctprintf("  %s %s", mode_tag, n.target_var_or_type), st.node_meta_fg)
									rev_i := n.loop_reverse
									if im.Checkbox(fmt.ctprintf("#reverse##inl_rev_%d", n.uid), &rev_i) {
										vs_push_undo()
										n.loop_reverse    = rev_i
										_vs.dirty_unbaked = true
									}

								case .Array_Op, .BitSet_Op, .Switch_Value, .Make_Struct, .Break_Struct:
									if n.target_var_or_type != "" {
										nc.canvas_bp_node_text(&b, fmt.ctprintf("  Target: %s", n.target_var_or_type), st.node_meta_fg)
									}

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
										nc.canvas_bp_node_text(&b, fmt.ctprintf("  %s", lines[li]), st.node_code_preview_fg)
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
									proc_nm  := n.hot_proc_target
									if sm, ok := engine.hot_proc_find_sig_meta(n.hot_proc_target); ok && sm.source_proc_name != "" {
										proc_nm = sm.source_proc_name
									}
									if he, hok := cs.resolve_hot_proc_info(n.hot_proc_target); hok && he.source_file != "" {
										src_file = he.source_file
									} else if he2, hok2 := cs.resolve_hot_proc_info(proc_nm); hok2 && he2.source_file != "" {
										src_file = he2.source_file
									}
									cs.open_scoped_proc_popup(n.hot_proc_target, src_file, proc_nm)
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
							if dbg_bb != nil && dbg_bb.loop_fuse_tripped_uid == n.uid {
								im.DrawList_AddRect(dl, card_min - {3, 3}, card_max + {3, 3}, im.GetColorU32ImVec4(p.status_error), 6.0 * zm, 3.0 * zm)
							}
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
						if hovered_ep >= 0 && !_vs.dragging_wire && !im.IsPopupOpen("", im.PopupFlags_AnyPopup) {
							hep := endpoints[hovered_ep]
							if dbg_bb != nil && hep.is_out && hep.pin_def.pin_type != .Exec {
								if lslot, lok := engine.visual_script_get_live_pin_value(dbg_ent, hep.node_uid, hep.pin_idx); lok {
									tname := hep.pin_def.custom_type_name != "" ? hep.pin_def.custom_type_name : engine.vg_pin_odin_type(hep.pin_def.pin_type, hep.pin_def.is_array)
									widgets.tooltip_unchecked(fmt.ctprintf("%s : %s\nLive: %s", hep.pin_def.name, tname, _format_live_slot(lslot)))
								}
							}
						}

						for ep, epi in endpoints {
							is_conn := ep.is_out ? wired_outputs[_Pin_Key{ep.node_uid, ep.pin_idx}] : wired_inputs[_Pin_Key{ep.node_uid, ep.pin_idx}]
							_draw_typed_pin(dl, ep.screen_p, ep.pin_def, hovered_ep == epi, is_conn, zm)
						}

						start_btn      := im.MouseButton.Left
						start_pin_drag := false
						if hovered_ep >= 0 {
							if io.KeyAlt && im.IsMouseClicked(.Left) {
								ep := endpoints[hovered_ep]
								_sever_wires_on_pin(ep.node_uid, ep.pin_idx, ep.is_out, push_undo = true)
							} else if im.IsMouseClicked(.Left) {
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
							} else if ep.is_out && start_btn == .Left && io.KeyCtrl {
								transplanted := false
								for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
									w := _vs.graph.wires[wi]
									if w.from_uid == ep.node_uid && w.from_pin == ep.pin_idx {
										if dst_n := engine.vg_find_node(&_vs.graph, w.to_uid); dst_n != nil && w.to_pin >= 0 && w.to_pin < len(dst_n.inputs) {
											vs_push_undo()
											_vs.dragging_wire = true
											_vs.drag_from_out = false
											_vs.drag_node_uid = w.to_uid
											_vs.drag_pin_idx  = w.to_pin
											_vs.drag_pin_def  = dst_n.inputs[w.to_pin]
											ordered_remove(&_vs.graph.wires, wi)
											_vs.dirty_unbaked = true
											transplanted = true
											break
										}
									}
								}
								if !transplanted {
									_vs.dragging_wire = true
									_vs.drag_from_out = true
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
									direct_ok, needs_cast, reject_why := engine.vg_can_connect_or_autocast_pins(src_def, dst_def)
									if direct_ok || needs_cast {
										end_pt = cand.screen_p
										if needs_cast && !direct_ok {
											wire_col = p.status_warning
											wire_lbl = fmt.ctprintf("%s Auto-Cast (%s -> %s)", icons.ICON_MD_BOLT, engine.vg_pin_odin_type(src_def.pin_type, false), engine.vg_pin_odin_type(dst_def.pin_type, false))
										} else if dst_def.pin_type == .Delegate {
											wire_lbl = fmt.ctprintf("%s Bind Odin Delegate Procedure", icons.ICON_MD_CHECK)
										} else if dst_def.pass_mode == .By_Reference {
											wire_lbl = fmt.ctprintf("%s Bind ^Ref Pointer", icons.ICON_MD_CHECK)
										} else {
											wire_lbl = fmt.ctprintf("%s Connect Wire", icons.ICON_MD_CHECK)
										}
									} else {
										wire_col = p.status_error
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
								} else if _vs.drag_mouse_btn == .Right && linalg.length(io.MousePos - _vs.drag_start_screen) < 5.0 {
									_vs.pin_ctx_uid    = _vs.drag_node_uid
									_vs.pin_ctx_idx    = _vs.drag_pin_idx
									_vs.pin_ctx_is_out = _vs.drag_from_out
									im.OpenPopup("##vs_pin_context_popup")
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

						// 3a. Double-Click Existing Wire -> Insert Reroute Knot
						if canvas_hovered && hovered_ep < 0 && !hovered_hdr_drag && !_vs.dragging_wire && !just_finished_pin_drag &&
						   !im.IsAnyItemHovered() && !im.IsPopupOpen("", im.PopupFlags_AnyPopup) && im.IsMouseDoubleClicked(.Left) {
							best_wi := -1
							best_wd := f32(10.0 * clamp(zm, 0.6, 1.8))
							for dw in drawn_wires {
								d := _dist_point_to_wire(io.MousePos, dw.p0, dw.p1, zm)
								if d < best_wd {
									best_wd = d
									best_wi = dw.wire_idx
								}
							}
							if best_wi >= 0 {
								drop_c := (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
								_insert_reroute_knot_on_wire(best_wi, {drop_c.x - 45.0, drop_c.y - 22.0})
							}
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
								if im.MenuItem("Collapse Selected to Scoped Odin BP_Node") {
									_collapse_selected_to_odin_node()
								}
								if im.MenuItem("Delete BP_Node (Del)") {
									delete_node_uid = cn.uid
								}
								im.Separator()
							} else if nc.canvas_selected_count(&_vs.canvas) >= 1 {
								if im.MenuItem("Collapse Selected to Scoped Odin BP_Node") {
									_collapse_selected_to_odin_node()
								}
								im.Separator()
							}

							_vs.ctx_spawn_canvas = (io.MousePos - _vs.canvas.origin) / max(_vs.canvas.zoom, 0.2) - _vs.canvas.pan
							im.TextColored(p.accent, "%s", fmt.ctprintf("%s Add BP_Node (by Namespace)", icons.ICON_MD_SEARCH))
							sr := widgets.search_bar(_vs.ctx_search_buf[:], widgets.Search_Bar_Opts{
								id         = "##vg_ctx_q",
								hint       = "Search BP_Nodes, namespaces, @hot_proc, variables...",
								mode       = .Popup,
								width      = 340,
								auto_focus = im.IsWindowAppearing(),
							})
							if sr.escape_close {
								im.CloseCurrentPopup()
							} else {
								spawn_pos := [2]f32{_vs.ctx_spawn_canvas.x, _vs.ctx_spawn_canvas.y}
								if im.BeginChild("##vg_palette_scroll", {360, 280}) {
									_draw_namespace_node_palette(spawn_pos, sr.query)
								}
								im.EndChild()
								im.Separator()
								nc.canvas_draw_default_context_menu_items(&_vs.canvas, pos_arr, 0)
							}
							im.EndPopup()
						}

						_draw_pin_drop_context_popup()
						_draw_pin_right_click_popup()

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
