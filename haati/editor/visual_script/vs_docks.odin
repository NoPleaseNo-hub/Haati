package visual_script

// =============================================================================
// UNIFIED GRAPH STUDIO DOCKS & SHARED SLOT EDITORS (`vs_docks.odin`)
// =============================================================================
// Column 1 ("My Graph"), Column 3 ("Details Inspector"), shared variable/slot
// editors (`draw_hot_slot_value_editor`, `format_slot_override_value`), and
// enum/struct/delegate dock helpers.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import "haati:engine"
import hot "haati:engine/hot_api"
import im "haati:external/odin-imgui"

@(private = "file")
_container_short_badge :: #force_inline proc(ck: engine.VG_Container_Kind) -> cstring {
	switch ck {
	case .Single:        return icons.ICON_MD_CIRCLE
	case .Fixed_Array:   return "[N]"
	case .Bounded_Array: return "[<=]"
	case .Slice:         return fmt.ctprintf("%s []", icons.ICON_MD_VIEW_TIMELINE)
	case .Dynamic_Array: return fmt.ctprintf("%s [+]", icons.ICON_MD_STACKS)
	}
	return icons.ICON_MD_CIRCLE
}

@(private = "file")
_container_display_label :: #force_inline proc(ck: engine.VG_Container_Kind) -> cstring {
	switch ck {
	case .Single:        return "Single Value"
	case .Slice:         return fmt.ctprintf("%s [] Slice View ([]T)", icons.ICON_MD_VIEW_TIMELINE)
	case .Dynamic_Array: return fmt.ctprintf("%s [dynamic] Heap Array ([dynamic]T)", icons.ICON_MD_STACKS)
	case .Fixed_Array:   return "[N] Fixed Stack Array"
	case .Bounded_Array: return "[<=N] Bounded Stack Array"
	}
	return "Single Value"
}

@(private = "file")
_container_icon_and_color :: proc(v: engine.VG_Var_Decl) -> (c_icon: cstring, t_icon: cstring, col: im.Vec4) {
	ck := engine.vg_resolve_container_kind(v)
	c_icon, t_icon, col = thm.studio_var_icon_and_color(v.pin_type, ck != .Single, ck == .Bounded_Array, false)
	if ck == .Slice {
		c_icon = icons.ICON_MD_VIEW_TIMELINE
	} else if ck == .Dynamic_Array {
		c_icon = icons.ICON_MD_STACKS
	}
	return
}

@(private = "file")
_apply_var_container_kind :: proc(v: ^engine.VG_Var_Decl, ck: engine.VG_Container_Kind) {
	if v == nil do return
	v.container_kind   = ck
	v.is_array         = ck != .Single
	v.array_is_bounded = ck == .Bounded_Array
}

@(private = "file")
_draw_container_kind_menu_items :: proc(cur_ck: engine.VG_Container_Kind, pt: hot.Hot_Pin_Type) -> (chosen: engine.VG_Container_Kind, changed: bool) {
	_ = pt
	order := [5]engine.VG_Container_Kind{.Single, .Slice, .Dynamic_Array, .Fixed_Array, .Bounded_Array}
	for opt in order {
		if im.MenuItem(_container_display_label(opt), nil, cur_ck == opt) {
			return opt, opt != cur_ck
		}
		if opt == .Slice {
			widgets.tooltip_unsafe("Zero-copy []T view compatible with native Odin slices & sub-slices.", bp_unsafe_tooltip_warning(pt, .Slice, false))
		}
	}
	return cur_ck, false
}

// Shared inline `[+ Element]` / `DragFloat` / `[x]` float slice & dynamic-array editor used by Blueprint Details & Scene Inspector.
draw_f32_list_editor :: proc(
	id_prefix: string,
	list: ^[dynamic]f32,
	min_v: f32 = 0.0,
	max_v: f32 = 0.0,
	use_temp_alloc: bool = false,
) -> (changed: bool) {
	if list == nil do return false
	prev_alloc := context.allocator
	if use_temp_alloc {
		context.allocator = context.temp_allocator
	} else {
		context.allocator = runtime.default_allocator()
	}
	defer context.allocator = prev_alloc

	has_range := max_v > min_v
	for i := 0; i < len(list^); i += 1 {
		im.PushIDInt(i32(i))
		im.TextDisabled("[%d]", i32(i))
		im.SameLine(0, 4)
		im.SetNextItemWidth(max(im.GetContentRegionAvail().x - 28.0, 64.0))
		val := list^[i]
		ch := has_range \
			? im.SliderFloat(fmt.ctprintf("##%s_el", id_prefix), &val, min_v, max_v, "%.3f") \
			: im.DragFloat(fmt.ctprintf("##%s_el", id_prefix), &val, 0.05)
		_record_undo_on_widget_activate()
		if ch {
			list^[i] = val
			changed = true
		}
		im.SameLine(0, 4)
		if im.SmallButton(fmt.ctprintf("%s##%s_del", icons.ICON_MD_CLOSE, id_prefix)) {
			ordered_remove(list, i)
			changed = true
			im.PopID()
			break
		}
		im.PopID()
	}
	if im.SmallButton(fmt.ctprintf("+ Element##%s_add", id_prefix)) {
		append(list, f32(0.0))
		changed = true
	}
	if len(list^) > 0 {
		im.SameLine(0, 6)
		if im.SmallButton(fmt.ctprintf("Clear##%s_clr", id_prefix)) {
			clear(list)
			changed = true
		}
	}
	return changed
}

// Formats a float slice/dynamic array into `[a,b,c]` instance_overrides syntax.
format_f32_list_override :: proc(vals: []f32, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(0, len(vals) * 10 + 4, allocator)
	strings.write_byte(&sb, '[')
	for v, i in vals {
		if i > 0 do strings.write_byte(&sb, ',')
		fmt.sbprintf(&sb, "%.4g", v)
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

// =============================================================================
// Column 1 (Left Dock): Unreal-Style "My Blueprint" + Domain Quick Spawners
// =============================================================================

@(private)
_draw_pin_type_combo :: proc(id: cstring, cur_pt_i32: ^i32, width: f32 = 72.0) {
	cur_pt := hot.Hot_Pin_Type(clamp(cur_pt_i32^, 0, i32(len(hot.Hot_Pin_Type) - 1)))
	if cur_pt == .Exec do cur_pt = .Int
	cur_vis := thm.STUDIO_PIN_TABLE[cur_pt]
	im.SetNextItemWidth(width)
	if im.BeginCombo(id, fmt.ctprintf("%s %s", cur_vis.type_icon, cur_vis.odin_label)) {
		for pt in thm.STUDIO_PICKER_TYPES {
			vis := thm.STUDIO_PIN_TABLE[pt]
			col := thm.studio_pin_color(pt)
			is_sel := pt == cur_pt
			im.PushStyleColorImVec4(.Text, col)
			if im.Selectable(fmt.ctprintf("%s %s##pt_%d", vis.type_icon, vis.odin_label, int(pt)), is_sel) {
				cur_pt_i32^ = i32(pt)
			}
			im.PopStyleColor()
			if pt == .Raw_Ptr {
				widgets.tooltip_unsafe("Zero-cost 64-bit untyped Odin rawptr.", bp_unsafe_tooltip_warning(.Raw_Ptr, .Single, false))
			}
			if is_sel do im.SetItemDefaultFocus()
		}
		im.EndCombo()
	}
}

@(private)
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
					n_uid := n.uid
					n_target := strings.clone(n.hot_proc_target, context.temp_allocator)
					im.SameLine(0, 2)
					if im.SmallButton(fmt.ctprintf("Call##cp_%d", n_uid)) {
						_spawn_graph_node(.Call_Blueprint_Proc, _canvas_view_spawn_pos(0.4), n_target)
						break
					}
					widgets.tooltip("Spawn a `Call Blueprint Procedure` node for this procedure")
					im.SameLine(0, 2)
					if im.SmallButton(fmt.ctprintf("Ren##rnp_%d", n_uid)) {
						_vs.proc_rename_uid = n_uid
						_set_c_buf(_vs.proc_rename_buf[:], n_target)
						_navigate_to_subgraph(n_target)
					}
					widgets.tooltip("Rename procedure")
					im.SameLine(0, 2)
					if im.SmallButton(fmt.ctprintf("X##dlp_%d", n_uid)) {
						del_target := n_target
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						deleted := engine.vg_delete_custom_proc(&_vs.graph, n_uid)
						context.allocator = prev_alloc
						if deleted {
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
				_spawn_graph_node(.Custom_Proc_Entry, _canvas_view_spawn_pos(0.28), pnm)
				_vs.new_proc_buf[0] = 0
			}
		}
		widgets.tooltip("Create a new Blueprint Procedure that can be bound to `input_manager` Actions, Debug Keys, or Custom Odin Delegates!")
	}

	im.Separator()

	// --- Section 2: Unified Structs & Fields (Self State Component + POD Structs, Active Struct Target) ---
	if im.CollapsingHeader(icons.ICON_MD_DATA_OBJECT + " Structs & Fields", {.DefaultOpen}) {
		engine.vg_sync_blackboard(&_vs.graph, &_vs.preview_bb)

		// Ensure `_vs.active_struct_target` still resolves to an existing struct (else fall back to Self State).
		active_st_idx := -1
		if _vs.active_struct_target != "" {
			for &st, si in _vs.graph.structs {
				if st.name == _vs.active_struct_target {
					active_st_idx = si
					break
				}
			}
			if active_st_idx < 0 {
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				delete(_vs.active_struct_target)
				_vs.active_struct_target = ""
				context.allocator = prev_alloc
			}
		}

		active_lbl := active_st_idx >= 0 \
			? fmt.ctprintf("%s %s", icons.ICON_MD_WIDGETS, _vs.graph.structs[active_st_idx].name) \
			: fmt.ctprintf("%s Self State (Component)", icons.ICON_MD_DATA_OBJECT)
		im.TextDisabled("Active:")
		im.SameLine(0, 4)
		im.SetNextItemWidth(max(im.GetContentRegionAvail().x - 4.0, 120.0))
		if im.BeginCombo("##active_struct_sel", active_lbl) {
			if im.Selectable(fmt.ctprintf("%s Self State (Component — using self)", icons.ICON_MD_DATA_OBJECT), active_st_idx < 0) {
				if _vs.active_struct_target != "" {
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					delete(_vs.active_struct_target)
					_vs.active_struct_target = ""
					context.allocator = prev_alloc
				}
			}
			for &st, si in _vs.graph.structs {
				tag := st.code_authored ? " [Zone 1]" : ""
				if im.Selectable(fmt.ctprintf("%s %s%s##sel_st_%d", icons.ICON_MD_WIDGETS, st.name, tag, si), active_st_idx == si) {
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					if _vs.active_struct_target != "" do delete(_vs.active_struct_target)
					_vs.active_struct_target = strings.clone(st.name)
					context.allocator = prev_alloc
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Select which Struct (`Self State` or any POD struct) new variables/fields & the `::` RAM Scratchpad target")

		if active_st_idx < 0 {
			for &v, vi in _vs.graph.variables {
				im.PushIDInt(i32(vi))
				eye_col := v.instance_editable ? p.status_success : p.text_muted
				im.PushStyleColorImVec4(.Text, eye_col)
				if im.SmallButton(v.instance_editable ? icons.ICON_MD_VISIBILITY : icons.ICON_MD_VISIBILITY_OFF) {
					vs_push_undo()
					v.instance_editable = !v.instance_editable
					_vs.dirty_unbaked   = true
					_sync_ide_blueprint_context()
				}
				im.PopStyleColor()
				widgets.tooltip(v.instance_editable ? "Instance Editable ON: Exposed per-entity in the Scene Inspector! (Click to hide)" : "Instance Editable OFF: Internal Blueprint variable (Click to expose in Scene Inspector)")

				im.SameLine(0, 4)
				c_icon, t_icon, v_col := _container_icon_and_color(v)
				im.TextColored(v_col, "%s", fmt.ctprintf("%s %s", c_icon, t_icon))
				im.SameLine(0, 4)
				is_vsel := _vs.selected_var_idx == vi
				sel_w := max(im.GetContentRegionAvail().x - 42.0, 64.0)
				if im.Selectable(fmt.ctprintf("%s : %s", v.name, engine.vg_var_odin_type_ex(&_vs.graph, v)), is_vsel, {}, {sel_w, 0}) {
					_vs.selected_var_idx  = vi
					_vs.selected_node_uid = 0
				}
				if im.BeginDragDropSource() {
					cname := fmt.ctprintf("%s", v.name)
					im.SetDragDropPayload("MH_BP_VAR", rawptr(cname), uint(len(v.name) + 1))
					im.Text("%s", fmt.ctprintf("%s %s (Ctrl = Get, Alt = Set)", icons.ICON_MD_DATA_OBJECT, v.name))
					im.EndDragDropSource()
				}
				widgets.tooltip_unsafe_delayed(
					"Drag into canvas (plain = Get/Set popup, Ctrl = Get, Alt = Set), or click to inspect in Right Details",
					bp_unsafe_tooltip_warning(v.pin_type, engine.vg_resolve_container_kind(v), false),
				)

				im.SameLine(0, 4)
				v_ck := engine.vg_resolve_container_kind(v)
				im.PushStyleColorImVec4(.Button, thm.with_alpha(v_col, 0.20))
				im.PushStyleColorImVec4(.Text, v_col)
				if im.SmallButton(fmt.ctprintf("%s##vck_btn", _container_short_badge(v_ck))) {
					im.OpenPopup("##vck_pop")
				}
				im.PopStyleColor(2)
				widgets.tooltip_unsafe(
					"Switch container type: Single, Slice ([]T), Dynamic Array ([dynamic]T), Fixed ([N]T), Bounded ([<=N]T)",
					bp_unsafe_tooltip_warning(v.pin_type, v_ck, false),
				)
				if im.BeginPopup("##vck_pop") {
					if next_ck, ck_ch := _draw_container_kind_menu_items(v_ck, v.pin_type); ck_ch {
						vs_push_undo()
						_apply_var_container_kind(&v, next_ck)
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
					im.EndPopup()
				}
				im.PopID()
			}

			im.SetNextItemWidth(104)
			im.InputTextWithHint("##new_vname", "field_name", cstring(raw_data(_vs.new_var_buf[:])), len(_vs.new_var_buf))
			im.SameLine(0, 4)
			_draw_pin_type_combo("##new_vtype", &_vs.new_var_type, 72.0)
			im.SameLine(0, 4)
			new_vpt := hot.Hot_Pin_Type(clamp(_vs.new_var_type, 0, i32(len(hot.Hot_Pin_Type) - 1)))
			im.SetNextItemWidth(max(im.GetContentRegionAvail().x, 48.0))
			if im.BeginCombo("##new_vck", _container_short_badge(_vs.new_var_container)) {
				if next_ck, ck_ch := _draw_container_kind_menu_items(_vs.new_var_container, new_vpt); ck_ch {
					_vs.new_var_container = next_ck
					_vs.new_var_is_array  = next_ck != .Single
				}
				im.EndCombo()
			}
			widgets.tooltip_unsafe(
				"Container kind: Single, [] Slice (all types), [+] Dynamic Array (all types), [N] Fixed Stack Array, [<=] Bounded Array",
				bp_unsafe_tooltip_warning(new_vpt, _vs.new_var_container, false),
			)
			if im.Button("+ Add Field (Self State)", {-1, 0}) {
				vn := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_var_buf[:])), context.temp_allocator)
				if vn != "" && engine.vg_find_var_index(&_vs.graph, vn) < 0 {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					defer context.allocator = prev_alloc
					vpt := hot.Hot_Pin_Type(_vs.new_var_type)
					default_custom := ""
					if (vpt == .Enum_U8 || vpt == .BitSet_U8) && len(_vs.graph.enums) > 0 {
						default_custom = strings.clone(_vs.graph.enums[0].name)
					} else if vpt == .Struct_Val && len(_vs.graph.structs) > 0 {
						default_custom = strings.clone(_vs.graph.structs[0].name)
					}
					ck_add := _vs.new_var_container
					append(&_vs.graph.variables, engine.VG_Var_Decl{
						name              = strings.clone(vn),
						pin_type          = vpt,
						is_array          = ck_add != .Single,
						container_kind    = ck_add,
						array_is_bounded  = ck_add == .Bounded_Array,
						custom_type_name  = default_custom,
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
		} else {
			st := &_vs.graph.structs[active_st_idx]
			im.PushIDInt(i32(3000 + active_st_idx))
			im.TextColored(thm.studio_pin_color(.Struct_Val), "%s", fmt.ctprintf("%s", st.name))
			im.SameLine()
			if im.SmallButton("Make") {
				n_uid := _spawn_graph_node(.Make_Struct, _canvas_view_spawn_pos(0.36), st.name)
				if nd := engine.vg_find_node(&_vs.graph, n_uid); nd != nil {
					engine.vg_sync_struct_node_pins(&_vs.graph, nd, st.name)
					_vs.dirty_unbaked = true
				}
			}
			im.SameLine(0, 3)
			if im.SmallButton("Break") {
				n_uid := _spawn_graph_node(.Break_Struct, _canvas_view_spawn_pos(0.40), st.name)
				if nd := engine.vg_find_node(&_vs.graph, n_uid); nd != nil {
					engine.vg_sync_struct_node_pins(&_vs.graph, nd, st.name)
					_vs.dirty_unbaked = true
				}
			}
			im.SameLine(0, 3)
			if st.code_authored {
				im.PushStyleColorImVec4(.Text, thm.studio_tokens().domain_odin)
				if im.SmallButton(fmt.ctprintf("%s L%d##jcode_st", icons.ICON_MD_CODE, max(st.source_line, 1))) {
					_jump_to_bodin_line(st.source_line)
				}
				im.PopStyleColor()
				widgets.tooltip("Struct declared in Zone 1 raw Odin code — click to view in Full .bodin!")
			} else if im.SmallButton("X") {
				vs_push_undo()
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				delete(st.name)
				delete(st.using_parent_name)
				for &f in st.fields {
					delete(f.name)
					delete(f.custom_type)
				}
				delete(st.fields)
				ordered_remove(&_vs.graph.structs, active_st_idx)
				if _vs.active_struct_target != "" {
					delete(_vs.active_struct_target)
					_vs.active_struct_target = ""
				}
				context.allocator = prev_alloc
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
				im.PopID()
				active_st_idx = -1
			}

			if active_st_idx >= 0 {
				st = &_vs.graph.structs[active_st_idx]
				im.SetNextItemWidth(148)
				cur_par := st.using_parent_name != "" ? fmt.ctprintf("%s", st.using_parent_name) : cstring("(no using parent)")
				if im.BeginCombo("using##up", cur_par) {
					if im.Selectable("(no using parent)", st.using_parent_name == "") {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						delete(st.using_parent_name)
						st.using_parent_name = ""
						for &gn in _vs.graph.nodes {
							if (gn.kind == .Make_Struct || gn.kind == .Break_Struct) && gn.target_var_or_type == st.name {
								engine.vg_sync_struct_node_pins(&_vs.graph, &gn, st.name)
							}
						}
						context.allocator = prev_alloc
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
					for &ost in _vs.graph.structs {
						if ost.name == st.name do continue
						if im.Selectable(fmt.ctprintf("%s", ost.name), st.using_parent_name == ost.name) {
							vs_push_undo()
							prev_alloc := context.allocator
							context.allocator = runtime.default_allocator()
							delete(st.using_parent_name)
							st.using_parent_name = strings.clone(ost.name)
							for &gn in _vs.graph.nodes {
								if (gn.kind == .Make_Struct || gn.kind == .Break_Struct) && gn.target_var_or_type == st.name {
									engine.vg_sync_struct_node_pins(&_vs.graph, &gn, st.name)
								}
							}
							context.allocator = prev_alloc
							_vs.dirty_unbaked = true
							_sync_ide_blueprint_context()
						}
					}
					im.EndCombo()
				}

				for fi := 0; fi < len(st.fields); fi += 1 {
					fld := &st.fields[fi]
					im.PushIDInt(i32(fi))
					ft_lbl := fld.custom_type != "" ? fld.custom_type : engine.vg_pin_odin_type(fld.pin_type, false)
					im.TextDisabled("  %s", fmt.ctprintf("%s : %s", fld.name, ft_lbl))
					if !st.code_authored {
						im.SameLine()
						if im.SmallButton("-##rm_sf") {
							vs_push_undo()
							prev_alloc := context.allocator
							context.allocator = runtime.default_allocator()
							delete(fld.name)
							delete(fld.custom_type)
							ordered_remove(&st.fields, fi)
							for &gn in _vs.graph.nodes {
								if (gn.kind == .Make_Struct || gn.kind == .Break_Struct) && gn.target_var_or_type == st.name {
									engine.vg_sync_struct_node_pins(&_vs.graph, &gn, st.name)
								}
							}
							context.allocator = prev_alloc
							_vs.dirty_unbaked = true
							_sync_ide_blueprint_context()
							im.PopID()
							break
						}
					}
					im.PopID()
				}

				im.SetNextItemWidth(92)
				im.InputTextWithHint("##add_sf_nm", "field...", cstring(raw_data(_vs.new_struct_field_buf[:])), len(_vs.new_struct_field_buf))
				im.SameLine(0, 4)
				_draw_pin_type_combo("##add_sf_tp", &_vs.new_struct_field_type, 76.0)
				im.SameLine(0, 4)
				if im.SmallButton("+ Field") {
					fnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_struct_field_buf[:])), context.temp_allocator)
					fpt := hot.Hot_Pin_Type(clamp(_vs.new_struct_field_type, 0, i32(len(hot.Hot_Pin_Type) - 1)))
					ft_str := engine.vg_pin_odin_type(fpt, false)
					if _add_field_to_active_struct_in_ram(fnm, ft_str) {
						_vs.new_struct_field_buf[0] = 0
					}
				}
				im.PopID()
			}
		}

		im.Separator()
		im.SetNextItemWidth(144)
		im.InputTextWithHint("##new_struct_nm", "Damage_Info...", cstring(raw_data(_vs.new_struct_buf[:])), len(_vs.new_struct_buf))
		im.SameLine()
		if im.Button("+ Struct") {
			snm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_struct_buf[:])), context.temp_allocator)
			if snm != "" {
				dup := false
				for &es in _vs.graph.structs do if es.name == snm { dup = true; break }
				if !dup {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					append(&_vs.graph.structs, engine.VG_Struct_Decl{
						name = strings.clone(snm),
					})
					if _vs.active_struct_target != "" do delete(_vs.active_struct_target)
					_vs.active_struct_target = strings.clone(snm)
					context.allocator = prev_alloc
					_vs.new_struct_buf[0] = 0
					_vs.dirty_unbaked     = true
					_sync_ide_blueprint_context()
				}
			}
		}
		widgets.tooltip("Declare a zero-heap POD Odin struct (supports `using` inheritance & Pin Splitting) and set it as Active Struct")
	}

	im.Separator()

	// --- Section 2B: Odin Enums (`enum u8`) & `bit_set[Enum; u8]` ---
	if im.CollapsingHeader(icons.ICON_MD_LAYERS + " Enums & BitSets (u8)") {
		for ei := 0; ei < len(_vs.graph.enums); ei += 1 {
			en := &_vs.graph.enums[ei]
			im.PushIDInt(i32(2000 + ei))
			im.TextColored(thm.studio_pin_color(.Enum_U8), "%s", fmt.ctprintf("%s", en.name))
			im.SameLine()
			if im.SmallButton("Switch") {
				n_uid := _spawn_graph_node(.Switch_Value, _canvas_view_spawn_pos(0.36), en.name)
				if nd := engine.vg_find_node(&_vs.graph, n_uid); nd != nil {
					engine.vg_configure_switch_node(&_vs.graph, nd, en.name)
					_vs.dirty_unbaked = true
				}
			}
			widgets.tooltip("Spawn exhaustive Odin `switch` node for this enum")
			im.SameLine(0, 3)
			if im.SmallButton("BitSet") {
				n_uid := _spawn_graph_node(.BitSet_Op, _canvas_view_spawn_pos(0.40), en.name)
				if nd := engine.vg_find_node(&_vs.graph, n_uid); nd != nil {
					engine.vg_configure_bitset_op(&_vs.graph, nd, .Set_Flag, en.name)
					_vs.dirty_unbaked = true
				}
			}
			widgets.tooltip("Spawn `bit_set[Enum; u8]` operation node")
			im.SameLine(0, 3)
			if en.code_authored {
				im.PushStyleColorImVec4(.Text, thm.studio_tokens().domain_odin)
				if im.SmallButton(fmt.ctprintf("%s L%d##jcode_en", icons.ICON_MD_CODE, max(en.source_line, 1))) {
					_jump_to_bodin_line(en.source_line)
				}
				im.PopStyleColor()
				widgets.tooltip("Declared in Zone 1 raw Odin code — click to jump directly to its declaration in Full .bodin!")
			} else {
				if im.SmallButton("X") {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					delete(en.name)
					delete(en.bitset_name)
					for vr in en.variants do delete(vr)
					delete(en.variants)
					ordered_remove(&_vs.graph.enums, ei)
					context.allocator = prev_alloc
					_vs.dirty_unbaked = true
					_sync_ide_blueprint_context()
					im.PopID()
					break
				}
				widgets.tooltip("Delete enum declaration")
			}

			im.Indent(12)
			hb := en.has_bitset
			if im.Checkbox("bit_set[Enum; u8]##bs", &hb) {
				vs_push_undo()
				en.has_bitset = hb
				if hb && en.bitset_name == "" {
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					en.bitset_name = strings.clone(fmt.tprintf("%s_Flags", en.name))
					context.allocator = prev_alloc
				}
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
			for evi := 0; evi < len(en.variants); evi += 1 {
				im.PushIDInt(i32(evi))
				im.TextDisabled("  %s", fmt.ctprintf("%d: %s", evi, en.variants[evi]))
				if len(en.variants) > 1 {
					im.SameLine()
					if im.SmallButton("-##rm_ev") {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						delete(en.variants[evi])
						ordered_remove(&en.variants, evi)
						for &gn in _vs.graph.nodes {
							if gn.kind == .Switch_Value && gn.target_var_or_type == en.name {
								engine.vg_configure_switch_node(&_vs.graph, &gn, en.name)
							}
						}
						context.allocator = prev_alloc
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
						im.PopID()
						break
					}
				}
				im.PopID()
			}
			im.SetNextItemWidth(118)
			im.InputTextWithHint("##add_evar", "Add_Variant...", cstring(raw_data(_vs.new_enum_var_buf[:])), len(_vs.new_enum_var_buf))
			im.SameLine()
			if im.SmallButton("+ Var") {
				vnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_enum_var_buf[:])), context.temp_allocator)
				if vnm != "" {
					dup := false
					for ev in en.variants do if ev == vnm { dup = true; break }
					if !dup {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						defer context.allocator = prev_alloc
						append(&en.variants, strings.clone(vnm))
						_vs.new_enum_var_buf[0] = 0
						for &gn in _vs.graph.nodes {
							if gn.kind == .Switch_Value && gn.target_var_or_type == en.name {
								engine.vg_configure_switch_node(&_vs.graph, &gn, en.name)
							}
						}
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
				}
			}
			im.Unindent(12)
			im.PopID()
		}

		im.SetNextItemWidth(144)
		im.InputTextWithHint("##new_enum_nm", "Move_State...", cstring(raw_data(_vs.new_enum_buf[:])), len(_vs.new_enum_buf))
		im.SameLine()
		if im.Button("+ Enum") {
			enm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_enum_buf[:])), context.temp_allocator)
			if enm != "" {
				dup := false
				for &e in _vs.graph.enums do if e.name == enm { dup = true; break }
				if !dup {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					defer context.allocator = prev_alloc
					ed := engine.VG_Enum_Decl{
						name        = strings.clone(enm),
						has_bitset  = true,
						bitset_name = strings.clone(fmt.tprintf("%s_Flags", enm)),
					}
					append(&ed.variants, strings.clone("None"))
					append(&ed.variants, strings.clone("Active"))
					append(&_vs.graph.enums, ed)
					_vs.new_enum_buf[0] = 0
					_vs.dirty_unbaked   = true
					_sync_ide_blueprint_context()
				}
			}
		}
		widgets.tooltip("Declare an Odin `enum u8` + optional `bit_set[Enum; u8]`")
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
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						if engine.vg_rename_delegate(&_vs.graph, d, new_nm) {
							_vs.dirty_unbaked = true
						}
						context.allocator = prev_alloc
					}
					_vs.del_rename_idx = -1
				}
				im.SameLine()
				if im.SmallButton("Esc") {
					_vs.del_rename_idx = -1
				}
			} else {
				im.TextColored(thm.studio_pin_color(.Delegate), "%s", fmt.ctprintf("%s %s", icons.ICON_MD_DIAMOND, d))
				if im.SmallButton("Bind") {
					_spawn_graph_node(.Delegate_Bind, _canvas_view_spawn_pos(0.36), d)
				}
				im.SameLine(0, 3)
				if im.SmallButton("Unbind") {
					_spawn_graph_node(.Delegate_Unbind, _canvas_view_spawn_pos(0.40), d)
				}
				im.SameLine(0, 3)
				if im.SmallButton("Cast") {
					_spawn_graph_node(.Delegate_Broadcast, _canvas_view_spawn_pos(0.44), d)
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
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					if engine.vg_delete_delegate(&_vs.graph, d) {
						_vs.dirty_unbaked = true
						_vs.del_rename_idx = -1
					}
					context.allocator = prev_alloc
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
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					defer context.allocator = prev_alloc
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
		im.TextColored(thm.studio_pin_color(.Exec), "%s", fmt.ctprintf("  %s  Exec Flow", icons.ICON_MD_PLAY_ARROW))
		im.TextColored(thm.studio_pin_color(.Delegate), "%s", fmt.ctprintf("  %s  Odin Delegate (Proc)", icons.ICON_MD_DIAMOND))
		im.TextColored(thm.studio_pin_color(.Float), "%s", fmt.ctprintf("  %s  Copy Value (T)", icons.ICON_MD_CIRCLE))
		im.TextColored(thm.studio_pin_color(.Float, true), "%s", fmt.ctprintf("  %s  Mutable Ref (^T)", icons.ICON_MD_DIAMOND))
	}
}

// =============================================================================
// Column 3 (Right Dock): Context-Sensitive Unreal-Style "Details" Inspector
// =============================================================================

@(private)
_draw_target_proc_selector :: proc(n: ^engine.VG_Node) {
	n := n
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
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(pnm)
				context.allocator = prev_alloc
				_vs.dirty_unbaked = true
			}
		}
		im.Separator()
		for hp in engine.hot_proc_entries() {
			if im.Selectable(fmt.ctprintf("%s @(hot_proc) %s", icons.ICON_MD_BOLT, hp.name), n.hot_proc_target == hp.name) {
				vs_push_undo()
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				if n.hot_proc_target != "" do delete(n.hot_proc_target)
				n.hot_proc_target = strings.clone(hp.name)
				context.allocator = prev_alloc
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
		n_uid := n.uid
		n_pos := n.pos
		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		defer context.allocator = prev_alloc
		p_uid := engine.vg_add_node(&_vs.graph, .Custom_Proc_Entry, {max(n_pos.x - 320.0, 20.0), n_pos.y + 180.0}, cand)
		// vg_add_node appends to _vs.graph.nodes and can reallocate the backing slice, invalidating `n`.
		n = engine.vg_find_node(&_vs.graph, n_uid)
		if n == nil do return
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

@(private)
_prune_oob_wires_for_node :: proc(uid: int) {
	nd := engine.vg_find_node(&_vs.graph, uid)
	in_len  := nd != nil ? len(nd.inputs)  : 0
	out_len := nd != nil ? len(nd.outputs) : 0
	for wi := len(_vs.graph.wires) - 1; wi >= 0; wi -= 1 {
		w := _vs.graph.wires[wi]
		if (w.to_uid == uid && (w.to_pin < 0 || w.to_pin >= in_len)) ||
		   (w.from_uid == uid && (w.from_pin < 0 || w.from_pin >= out_len)) {
			ordered_remove(&_vs.graph.wires, wi)
		}
	}
}

@(private)
_sync_var_default_to_preview_bb :: proc(vi: int, v: ^engine.VG_Var_Decl) {
	if vi < 0 || vi >= engine.VG_MAX_VARS do return
	#partial switch v.pin_type {
	case .Bool:                   _vs.preview_bb.slots[vi].val_bool = v.default_bool
	case .Int:                    _vs.preview_bb.slots[vi].val_int  = v.default_int
	case .Int64:                  _vs.preview_bb.slots[vi].val_i64  = v.default_i64
	case .U8:                     _vs.preview_bb.slots[vi].val_u8   = u8(v.default_u64 != 0 ? v.default_u64 : u64(max(v.default_int, 0)))
	case .I8:                     _vs.preview_bb.slots[vi].val_i8   = i8(clamp(v.default_int, -128, 127))
	case .U16:                    _vs.preview_bb.slots[vi].val_u16  = u16(v.default_u64 != 0 ? v.default_u64 : u64(max(v.default_int, 0)))
	case .I16:                    _vs.preview_bb.slots[vi].val_i16  = i16(clamp(v.default_int, -32768, 32767))
	case .U32:                    _vs.preview_bb.slots[vi].val_u32  = u32(v.default_u64 != 0 ? v.default_u64 : u64(max(v.default_int, 0)))
	case .U64:                    _vs.preview_bb.slots[vi].val_u64  = v.default_u64
	case .Enum_U8, .BitSet_U8:    _vs.preview_bb.slots[vi].val_u8   = u8(v.default_u64)
	case .Float:                  _vs.preview_bb.slots[vi].val_f32  = v.default_f32
	case .F64:                    _vs.preview_bb.slots[vi].val_f64  = v.default_f64 != 0 ? v.default_f64 : f64(v.default_f32)
	case .Vec2:                   _vs.preview_bb.slots[vi].val_vec2 = v.default_vec2
	case .Vec3:                   _vs.preview_bb.slots[vi].val_vec3 = v.default_vec3
	case .Vec4:                   _vs.preview_bb.slots[vi].val_vec4 = v.default_vec4
	case .Quat:                   _vs.preview_bb.slots[vi].val_quat = v.default_vec4
	case .String, .Asset:         _vs.preview_bb.initialized = false
	}
	if ck := engine.vg_resolve_container_kind(v^); v.pin_type == .Float && (ck == .Slice || ck == .Dynamic_Array) {
		if seq, has := &_vs.preview_bb.var_f32_seqs[v.name]; has {
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			resize(seq, len(v.default_f32_list))
			if len(v.default_f32_list) > 0 do copy(seq^[:], v.default_f32_list[:])
			context.allocator = prev_alloc
		}
	}
}

// Formats a runtime/default `Hot_Slot` value into the string serialization format used by
// entity `instance_overrides` and scene inspector live pushes.
format_slot_override_value :: proc(
	pin_type:     hot.Hot_Pin_Type,
	slot:         ^hot.Hot_Slot,
	str_override: string = "",
	allocator := context.temp_allocator,
) -> string {
	if slot == nil && pin_type != .String && pin_type != .Asset do return ""
	#partial switch pin_type {
	case .Bool:             return strings.clone(slot.val_bool ? "true" : "false", allocator)
	case .U8:               return fmt.aprintf("%d", slot.val_u8, allocator = allocator)
	case .I8:               return fmt.aprintf("%d", slot.val_i8, allocator = allocator)
	case .U16:              return fmt.aprintf("%d", slot.val_u16, allocator = allocator)
	case .I16:              return fmt.aprintf("%d", slot.val_i16, allocator = allocator)
	case .Int:              return fmt.aprintf("%d", slot.val_int, allocator = allocator)
	case .U32:              return fmt.aprintf("%d", slot.val_u32, allocator = allocator)
	case .Int64:            return fmt.aprintf("%d", slot.val_i64, allocator = allocator)
	case .U64:              return fmt.aprintf("%d", slot.val_u64, allocator = allocator)
	case .Float:            return fmt.aprintf("%.4f", slot.val_f32, allocator = allocator)
	case .F64:              return fmt.aprintf("%.8f", slot.val_f64, allocator = allocator)
	case .Enum_U8, .BitSet_U8:
		return fmt.aprintf("%d", slot.val_u8, allocator = allocator)
	case .Vec2:             return fmt.aprintf("%.4f,%.4f", slot.val_vec2.x, slot.val_vec2.y, allocator = allocator)
	case .Vec3:             return fmt.aprintf("%.4f,%.4f,%.4f", slot.val_vec3.x, slot.val_vec3.y, slot.val_vec3.z, allocator = allocator)
	case .Vec4:             return fmt.aprintf("%.4f,%.4f,%.4f,%.4f", slot.val_vec4.x, slot.val_vec4.y, slot.val_vec4.z, slot.val_vec4.w, allocator = allocator)
	case .Quat:             return fmt.aprintf("%.4f,%.4f,%.4f,%.4f", slot.val_quat.x, slot.val_quat.y, slot.val_quat.z, slot.val_quat.w, allocator = allocator)
	case .String, .Asset:
		s := str_override
		if s == "" && slot != nil && slot.val_cstr != nil {
			s = string(slot.val_cstr)
		}
		return strings.clone(s, allocator)
	}
	return ""
}

// Shared ImGui widget editor operating directly on a `hot.Hot_Slot` (used by Blueprint defaults,
// inline node controls, AND the Scene Inspector `VisualScriptRunner` card).
draw_hot_slot_value_editor :: proc(
	g:                ^engine.Visual_Graph,
	id_tag:           string,
	pin_type:         hot.Hot_Pin_Type,
	custom_type_name: string,
	slot:             ^hot.Hot_Slot,
	in_str:           string = "",
	display_lbl:      string = "",
	slider_min:       f32 = 0,
	slider_max:       f32 = 0,
	width:            f32 = -1.0,
	compact:          bool = false,
	record_vs_undo:   bool = false,
) -> (changed: bool, new_str: string) {
	if slot == nil do return false, in_str
	lbl := display_lbl != "" ? fmt.ctprintf("%s##%s", display_lbl, id_tag) : fmt.ctprintf("##%s", id_tag)
	#partial switch pin_type {
	case .Bool:
		bt := slot.val_bool
		if im.Checkbox(lbl, &bt) {
			if record_vs_undo do vs_push_undo()
			slot.val_bool = bt
			return true, in_str
		}
	case .U8:
		s1: u8 = 1
		uv := slot.val_u8
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .U8, &uv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_u8 = uv; slot.val_u64 = u64(uv); slot.val_int = i32(uv); return true, in_str }
	case .I8:
		s1: i8 = 1
		iv := slot.val_i8
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .S8, &iv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_i8 = iv; slot.val_int = i32(iv); return true, in_str }
	case .U16:
		s1: u16 = 1
		uv := slot.val_u16
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .U16, &uv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_u16 = uv; slot.val_u64 = u64(uv); slot.val_int = i32(uv); return true, in_str }
	case .I16:
		s1: i16 = 1
		iv := slot.val_i16
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .S16, &iv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_i16 = iv; slot.val_int = i32(iv); return true, in_str }
	case .Int:
		it := slot.val_int
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.DragInt(lbl, &it, 1.0)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_int = it; return true, in_str }
	case .U32:
		s1: u32 = 1
		uv := slot.val_u32
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .U32, &uv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_u32 = uv; slot.val_u64 = u64(uv); slot.val_int = i32(min(uv, u32(max(i32)))); return true, in_str }
	case .Int64:
		s1: i64 = 1
		iv := slot.val_i64
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .S64, &iv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_i64 = iv; return true, in_str }
	case .U64:
		s1: u64 = 1
		uv := slot.val_u64
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .U64, &uv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_u64 = uv; return true, in_str }
	case .Float:
		fv := slot.val_f32
		if width != 0 do im.SetNextItemWidth(width)
		ch := (!compact && slider_max > slider_min) \
			? im.SliderFloat(lbl, &fv, slider_min, slider_max) \
			: im.DragFloat(lbl, &fv, 0.05)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_f32 = fv; return true, in_str }
	case .F64:
		s1: f64 = 0.05
		dv := slot.val_f64
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .Double, &dv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_f64 = dv; slot.val_f32 = f32(dv); return true, in_str }
	case .Enum_U8:
		if ed := g != nil ? engine.vg_find_enum_decl(g, custom_type_name) : nil; ed != nil && len(ed.variants) > 0 {
			cur_i := clamp(int(slot.val_u8), 0, len(ed.variants) - 1)
			if width != 0 do im.SetNextItemWidth(width)
			enum_ch := false
			if im.BeginCombo(lbl, fmt.ctprintf("%s", ed.variants[cur_i])) {
				for vr, evi in ed.variants {
					if im.Selectable(fmt.ctprintf("%s##ev_%s", vr, id_tag), cur_i == evi) {
						if record_vs_undo do vs_push_undo()
						slot.val_u8  = u8(evi)
						slot.val_u64 = u64(evi)
						slot.val_int = i32(evi)
						enum_ch      = true
					}
				}
				im.EndCombo()
			}
			if enum_ch do return true, in_str
		} else {
			s1: u8 = 1
			uv := slot.val_u8
			if width != 0 do im.SetNextItemWidth(width)
			ch := im.InputScalar(lbl, .U8, &uv, &s1)
			if record_vs_undo do _record_undo_on_widget_activate()
			if ch { slot.val_u8 = uv; slot.val_u64 = u64(uv); slot.val_int = i32(uv); return true, in_str }
		}
	case .BitSet_U8:
		if !compact {
			if ed := g != nil ? engine.vg_find_enum_decl(g, custom_type_name) : nil; ed != nil && len(ed.variants) > 0 {
				if display_lbl != "" do im.TextDisabled("%s:", fmt.ctprintf("%s", display_lbl))
				mask_v := slot.val_u8
				for vr, evi in ed.variants {
					if evi >= 8 do break
					bit := u8(1) << u8(evi)
					has := (mask_v & bit) != 0
					if im.Checkbox(fmt.ctprintf("%s##bs_%s_%d", vr, id_tag, evi), &has) {
						if record_vs_undo do vs_push_undo()
						if has do mask_v |= bit
						else   do mask_v &= ~bit
						slot.val_u8  = mask_v
						slot.val_u64 = u64(mask_v)
						return true, in_str
					}
				}
				return false, in_str
			}
		}
		s1: u8 = 1
		uv := slot.val_u8
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.InputScalar(lbl, .U8, &uv, &s1)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_u8 = uv; slot.val_u64 = u64(uv); return true, in_str }
	case .Vec2:
		v2 := slot.val_vec2
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.DragFloat2(lbl, &v2, 0.05)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_vec2 = v2; return true, in_str }
	case .Vec3:
		v3 := slot.val_vec3
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.DragFloat3(lbl, &v3, 0.05)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_vec3 = v3; return true, in_str }
	case .Vec4:
		v4 := slot.val_vec4
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.DragFloat4(lbl, &v4, 0.05)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_vec4 = v4; return true, in_str }
	case .Quat:
		q4 := slot.val_quat
		if width != 0 do im.SetNextItemWidth(width)
		ch := im.DragFloat4(lbl, &q4, compact ? 0.05 : 0.02)
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch { slot.val_quat = q4; slot.val_vec4 = q4; return true, in_str }
	case .String, .Asset:
		sbuf: [128]byte
		src_s := in_str
		if src_s == "" && slot.val_cstr != nil do src_s = string(slot.val_cstr)
		_set_c_buf(sbuf[:], src_s)
		if width != 0 do im.SetNextItemWidth(width)
		hint: cstring = pin_type == .Asset ? "assets/..." : "default string..."
		ch := im.InputTextWithHint(lbl, hint, cstring(raw_data(sbuf[:])), len(sbuf))
		if record_vs_undo do _record_undo_on_widget_activate()
		if ch {
			return true, strings.clone(_c_str(sbuf[:]), context.temp_allocator)
		}
	}
	return false, in_str
}

@(private)
_draw_default_value_widgets :: proc(
	g: ^engine.Visual_Graph,
	id_tag: string,
	pin_type: hot.Hot_Pin_Type,
	custom_type_name: string,
	p_bool: ^bool,
	p_int: ^i32,
	p_i64: ^i64,
	p_u64: ^u64,
	p_f32: ^f32,
	p_f64: ^f64,
	p_v2: ^[2]f32,
	p_v3: ^[3]f32,
	p_v4: ^[4]f32,
	p_str: ^string,
	display_lbl: string = "",
	width: f32 = -1.0,
	compact: bool = false,
) -> bool {
	slot := hot.Hot_Slot{
		pin_type = pin_type,
		val_bool = p_bool^,
		val_u8   = (pin_type == .Enum_U8 || pin_type == .BitSet_U8) ? u8(p_u64^) : u8(p_u64^ != 0 ? p_u64^ : u64(clamp(p_int^, 0, 255))),
		val_i8   = i8(clamp(p_int^, -128, 127)),
		val_u16  = u16(p_u64^ != 0 ? p_u64^ : u64(clamp(p_int^, 0, 65535))),
		val_i16  = i16(clamp(p_int^, -32768, 32767)),
		val_int  = p_int^,
		val_u32  = u32(p_u64^ != 0 ? p_u64^ : u64(max(p_int^, 0))),
		val_i64  = p_i64^,
		val_u64  = p_u64^,
		val_f32  = p_f32^,
		val_f64  = p_f64^ != 0 ? p_f64^ : f64(p_f32^),
		val_vec2 = p_v2^,
		val_vec3 = p_v3^,
		val_vec4 = p_v4^,
		val_quat = p_v4^,
	}
	ch, ed_s := draw_hot_slot_value_editor(
		g, id_tag, pin_type, custom_type_name, &slot, p_str^, display_lbl,
		0, 0, width, compact, record_vs_undo = true,
	)
	if !ch do return false
	#partial switch pin_type {
	case .Bool:             p_bool^ = slot.val_bool
	case .U8, .U16, .U32, .Enum_U8:
		p_u64^ = slot.val_u64
		p_int^ = slot.val_int
	case .BitSet_U8:        p_u64^ = slot.val_u64
	case .I8, .I16, .Int:   p_int^ = slot.val_int
	case .Int64:            p_i64^ = slot.val_i64
	case .U64:              p_u64^ = slot.val_u64
	case .Float:            p_f32^ = slot.val_f32
	case .F64:              p_f64^ = slot.val_f64; p_f32^ = slot.val_f32
	case .Vec2:             p_v2^  = slot.val_vec2
	case .Vec3:             p_v3^  = slot.val_vec3
	case .Vec4, .Quat:      p_v4^  = slot.val_vec4
	case .String, .Asset:
		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		if p_str^ != "" do delete(p_str^)
		p_str^ = strings.clone(ed_s)
		context.allocator = prev_alloc
	}
	return true
}

@(private)
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

		im.TextColored(thm.studio_tokens().domain_blueprint, "Graph Variable")
		im.TextDisabled("Variable Name:")
		im.SetNextItemWidth(-1)
		if im.InputText("##var_ren", cstring(raw_data(_vs.rename_buf[:])), len(_vs.rename_buf), {.EnterReturnsTrue}) {
			new_nm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.rename_buf[:])), context.temp_allocator)
			if new_nm != "" && new_nm != v.name && engine.vg_find_var_index(&_vs.graph, new_nm) < 0 {
				vs_push_undo()
				old_nm := v.name
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				for &nd in _vs.graph.nodes {
					if (nd.kind == .Get_Variable || nd.kind == .Set_Variable) && nd.var_name == old_nm {
						delete(nd.var_name)
						nd.var_name = strings.clone(new_nm)
					}
				}
				delete(v.name)
				v.name = strings.clone(new_nm)
				context.allocator = prev_alloc
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
		}

		im.TextDisabled("Odin Type: %s", fmt.ctprintf("%s", engine.vg_var_odin_type_ex(&_vs.graph, v^)))
		cur_ck := engine.vg_resolve_container_kind(v^)
		im.SetNextItemWidth(-1)
		if im.BeginCombo("Container##vd_ck", _container_display_label(cur_ck)) {
			if next_ck, ck_ch := _draw_container_kind_menu_items(cur_ck, v.pin_type); ck_ch {
				vs_push_undo()
				_apply_var_container_kind(v, next_ck)
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
			im.EndCombo()
		}
		if cur_ck == .Fixed_Array || cur_ck == .Bounded_Array {
			cap_tmp := i32(v.array_count)
			im.SetNextItemWidth(-1)
			cap_ch := im.DragInt("Capacity (0=[8]T)##vd_cap", &cap_tmp, 0.25, 0, 64)
			_record_undo_on_widget_activate()
			if cap_ch {
				v.array_count = clamp(int(cap_tmp), 0, 64)
				_vs.dirty_unbaked = true
				_sync_ide_blueprint_context()
			}
		}
		if v.pin_type == .Enum_U8 || v.pin_type == .BitSet_U8 {
			cur_en := v.custom_type_name != "" ? v.custom_type_name : "<Select Enum>"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("Enum Type##vd_enm", fmt.ctprintf("%s", cur_en)) {
				for &ed in _vs.graph.enums {
					if im.Selectable(fmt.ctprintf("%s", ed.name), v.custom_type_name == ed.name) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						if v.custom_type_name != "" do delete(v.custom_type_name)
						v.custom_type_name = strings.clone(ed.name)
						context.allocator = prev_alloc
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
				}
				im.EndCombo()
			}
		} else if v.pin_type == .Struct_Val {
			cur_st := v.custom_type_name != "" ? v.custom_type_name : "<Select Struct>"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("Struct Type##vd_st", fmt.ctprintf("%s", cur_st)) {
				for &st in _vs.graph.structs {
					if im.Selectable(fmt.ctprintf("%s", st.name), v.custom_type_name == st.name) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						if v.custom_type_name != "" do delete(v.custom_type_name)
						v.custom_type_name = strings.clone(st.name)
						context.allocator = prev_alloc
						_vs.dirty_unbaked = true
						_sync_ide_blueprint_context()
					}
				}
				im.EndCombo()
			}
			if v.custom_type_name != "" {
				flds, sz, al := engine.vg_struct_layout(&_vs.graph, v.custom_type_name, context.temp_allocator)
				im.TextDisabled("Layout: %s", fmt.ctprintf("%d fields, %dB (align %d)", len(flds), sz, al))
			}
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
		if v.pin_type == .Float && cur_ck != .Single {
			if draw_f32_list_editor(fmt.tprintf("vd_f32l_%d", vi), &v.default_f32_list, v.slider_min, v.slider_max) {
				_sync_var_default_to_preview_bb(vi, v)
				_vs.dirty_unbaked = true
			}
		} else if _draw_default_value_widgets(
			&_vs.graph, fmt.tprintf("vd_%d", vi), v.pin_type, v.custom_type_name,
			&v.default_bool, &v.default_int, &v.default_i64, &v.default_u64,
			&v.default_f32, &v.default_f64, &v.default_vec2, &v.default_vec3, &v.default_vec4,
			&v.default_str,
		) {
			_sync_var_default_to_preview_bb(vi, v)
			_vs.dirty_unbaked = true
		}
		if v.pin_type == .Float {
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
		}

		im.Separator()
		im.TextDisabled("Category:")
		im.SetNextItemWidth(-1)
		cat_ch := im.InputTextWithHint("##vd_cat", "Gameplay / Movement...", cstring(raw_data(_vs.cat_buf[:])), len(_vs.cat_buf))
		_record_undo_on_widget_activate()
		if cat_ch {
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			if v.category != "" do delete(v.category)
			v.category = strings.clone(_c_str(_vs.cat_buf[:]))
			context.allocator = prev_alloc
			_vs.dirty_unbaked = true
		}

		im.TextDisabled("Documentation / Tooltip:")
		im.SetNextItemWidth(-1)
		tip_ch := im.InputTextWithHint("##vd_tip", "Describe variable...", cstring(raw_data(_vs.tip_buf[:])), len(_vs.tip_buf))
		_record_undo_on_widget_activate()
		if tip_ch {
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			if v.tooltip_text != "" do delete(v.tooltip_text)
			v.tooltip_text = strings.clone(_c_str(_vs.tip_buf[:]))
			context.allocator = prev_alloc
			_vs.dirty_unbaked = true
		}

		im.Separator()
		if im.Button("Delete Variable", {-1, 0}) {
			vs_push_undo()
			prev_alloc := context.allocator
			context.allocator = runtime.default_allocator()
			if v.name             != "" do delete(v.name)
			if v.category         != "" do delete(v.category)
			if v.tooltip_text     != "" do delete(v.tooltip_text)
			if v.default_str      != "" do delete(v.default_str)
			if v.custom_type_name != "" do delete(v.custom_type_name)
			ordered_remove(&_vs.graph.variables, vi)
			context.allocator = prev_alloc
			_vs.selected_var_idx       = -1
			_vs.rename_target_var      = -1
			_vs.preview_bb.initialized = false
			_vs.dirty_unbaked          = true
			_sync_ide_blueprint_context()
		}
		return
	}

	// --- Mode B: Selected Graph Node Details Inspector ---
	sel_uid := _vs.selected_node_uid
	if n := engine.vg_find_node(&_vs.graph, sel_uid); n != nil {
		hint := n.hot_proc_target != "" ? n.hot_proc_target : n.title
		cat, col := _node_category_and_color(n.kind, hint)
		im.TextColored(col, "%s", fmt.ctprintf("%s", cat))
		im.SameLine()
		widgets.text_disabledf("(#%d)", n.uid)
		im.TextWrapped("%s", fmt.ctprintf("%s", n.title))
		en_tmp := n.enabled
		if im.Checkbox("Node Enabled", &en_tmp) {
			vs_push_undo()
			n.enabled = en_tmp
			_vs.dirty_unbaked = true
		}
		im.Separator()

		#partial switch n.kind {
		case .For_Loop:
			im.TextDisabled("Odin `for` Loop Mode:")
			mode_lbls := [5]cstring{
				"Range (first..=last)",
				"Range (first..<last)",
				"For Elem in Array",
				"For &Elem (^Ref) in Array",
				"While Condition",
			}
			mi := i32(n.for_mode)
			im.SetNextItemWidth(-1)
			if im.ComboChar("##det_for_mode", &mi, raw_data(mode_lbls[:]), 5) {
				vs_push_undo()
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				engine.vg_configure_for_loop(&_vs.graph, n, engine.VG_For_Mode(mi), n.target_var_or_type)
				context.allocator = prev_alloc
				_prune_oob_wires_for_node(n.uid)
				_vs.dirty_unbaked = true
			}
			if n.for_mode == .For_In_Value || n.for_mode == .For_In_Ref {
				cur_av := n.target_var_or_type != "" ? n.target_var_or_type : "<Select Array Var>"
				im.SetNextItemWidth(-1)
				if im.BeginCombo("Array Var##det_for_arr", fmt.ctprintf("%s", cur_av)) {
					for &v in _vs.graph.variables {
						if !v.is_array do continue
						if im.Selectable(fmt.ctprintf("%s : %s", v.name, engine.vg_var_odin_type_ex(&_vs.graph, v)), n.target_var_or_type == v.name) {
							vs_push_undo()
							prev_alloc := context.allocator
							context.allocator = runtime.default_allocator()
							engine.vg_configure_for_loop(&_vs.graph, n, n.for_mode, v.name)
							context.allocator = prev_alloc
							_prune_oob_wires_for_node(n.uid)
							_vs.dirty_unbaked = true
						}
					}
					im.EndCombo()
				}
			}
			rev_tmp := n.loop_reverse
			if im.Checkbox("#reverse Iteration Order##det_for_rev", &rev_tmp) {
				vs_push_undo()
				n.loop_reverse    = rev_tmp
				_vs.dirty_unbaked = true
			}

		case .Array_Op:
			im.TextDisabled("Array Operation Mode:")
			aop_lbls := [9]cstring{"Get Copy arr[i]", "Get ^Ref (&arr[i])", "Set Element", "Append", "Pop", "Clear", "Len / Count", "Swap Remove", "Sub-Slice (arr[start:end])"}
			ai := clamp(i32(n.sub_op), 0, 8)
			im.SetNextItemWidth(-1)
			if im.ComboChar("##det_aop_mode", &ai, raw_data(aop_lbls[:]), 9) {
				vs_push_undo()
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				engine.vg_configure_array_op(&_vs.graph, n, engine.VG_Array_Op_Mode(ai), n.target_var_or_type)
				context.allocator = prev_alloc
				_prune_oob_wires_for_node(n.uid)
				_vs.dirty_unbaked = true
			}
			cur_av := n.target_var_or_type != "" ? n.target_var_or_type : "<Select Array Var>"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("Array Var##det_aop_var", fmt.ctprintf("%s", cur_av)) {
				for &v in _vs.graph.variables {
					if !v.is_array do continue
					if im.Selectable(fmt.ctprintf("%s : %s", v.name, engine.vg_var_odin_type_ex(&_vs.graph, v)), n.target_var_or_type == v.name) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						engine.vg_configure_array_op(&_vs.graph, n, engine.VG_Array_Op_Mode(ai), v.name)
						context.allocator = prev_alloc
						_prune_oob_wires_for_node(n.uid)
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}

		case .BitSet_Op:
			im.TextDisabled("BitSet Operation:")
			bs_lbls := [5]cstring{"Set Flag (+=)", "Clear Flag (-=)", "Toggle Flag (~)", "Has Flag (in)", "Is Empty (== {})"}
			bi := clamp(i32(n.sub_op), 0, 4)
			im.SetNextItemWidth(-1)
			if im.ComboChar("##det_bs_mode", &bi, raw_data(bs_lbls[:]), 5) {
				vs_push_undo()
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				engine.vg_configure_bitset_op(&_vs.graph, n, engine.VG_BitSet_Op_Mode(bi), n.target_var_or_type)
				context.allocator = prev_alloc
				_prune_oob_wires_for_node(n.uid)
				_vs.dirty_unbaked = true
			}
			cur_en := n.target_var_or_type != "" ? n.target_var_or_type : "<Select Enum>"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("Enum Type##det_bs_enum", fmt.ctprintf("%s", cur_en)) {
				for &ed in _vs.graph.enums {
					if im.Selectable(fmt.ctprintf("%s", ed.name), n.target_var_or_type == ed.name) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						engine.vg_configure_bitset_op(&_vs.graph, n, engine.VG_BitSet_Op_Mode(bi), ed.name)
						context.allocator = prev_alloc
						_prune_oob_wires_for_node(n.uid)
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}

		case .Switch_Value:
			im.TextDisabled("Exhaustive Odin `switch` Target:")
			cur_en := n.target_var_or_type != "" ? n.target_var_or_type : "(Integer 0..N Cases)"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("Enum Type##det_sw_enum", fmt.ctprintf("%s", cur_en)) {
				if im.Selectable("(Integer 0..N Cases)", n.target_var_or_type == "") {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					engine.vg_configure_switch_node(&_vs.graph, n, "")
					context.allocator = prev_alloc
					_prune_oob_wires_for_node(n.uid)
					_vs.dirty_unbaked = true
				}
				for &ed in _vs.graph.enums {
					if im.Selectable(fmt.ctprintf("%s", ed.name), n.target_var_or_type == ed.name) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						engine.vg_configure_switch_node(&_vs.graph, n, ed.name)
						context.allocator = prev_alloc
						_prune_oob_wires_for_node(n.uid)
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}
			if n.target_var_or_type == "" {
				cc := i32(clamp(n.sub_op > 0 ? n.sub_op : 3, 2, 16))
				im.SetNextItemWidth(-1)
				if im.DragInt("Case Count##det_sw_cnt", &cc, 0.25, 2, 16) {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					n.sub_op = int(clamp(cc, 2, 16))
					engine.vg_configure_switch_node(&_vs.graph, n, "")
					context.allocator = prev_alloc
					_prune_oob_wires_for_node(n.uid)
					_vs.dirty_unbaked = true
				}
			}

		case .Make_Struct, .Break_Struct:
			cur_st := n.target_var_or_type != "" ? n.target_var_or_type : "<Select Struct>"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("Struct Type##det_st_nm", fmt.ctprintf("%s", cur_st)) {
				for &st in _vs.graph.structs {
					if im.Selectable(fmt.ctprintf("%s", st.name), n.target_var_or_type == st.name) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						engine.vg_sync_struct_node_pins(&_vs.graph, n, st.name)
						context.allocator = prev_alloc
						_prune_oob_wires_for_node(n.uid)
						_vs.dirty_unbaked = true
					}
				}
				im.EndCombo()
			}

		case .Bind_Input_Action, .Unbind_Input_Action:
			im.TextDisabled("Input Manager Action:")
			actions := _merged_input_actions(context.temp_allocator)
			cur_act := n.action_name != "" ? n.action_name : "Jump"
			im.SetNextItemWidth(-1)
			if im.BeginCombo("##det_act_combo", fmt.ctprintf("%s", cur_act)) {
				for act in actions {
					if im.Selectable(fmt.ctprintf("%s", act), n.action_name == act) {
						vs_push_undo()
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						if n.action_name != "" do delete(n.action_name)
						n.action_name = strings.clone(act)
						delete(n.title)
						n.title = strings.clone(fmt.tprintf("%s Input Action (%s)", n.kind == .Bind_Input_Action ? "Bind" : "Unbind", act))
						context.allocator = prev_alloc
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
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					if n.action_name != "" do delete(n.action_name)
					n.action_name = strings.clone(anm)
					delete(n.title)
					n.title = strings.clone(fmt.tprintf("%s Input Action (%s)", n.kind == .Bind_Input_Action ? "Bind" : "Unbind", anm))
					context.allocator = prev_alloc
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
				prev_alloc := context.allocator
				context.allocator = runtime.default_allocator()
				delete(n.title)
				n.title = strings.clone(fmt.tprintf("%s Input Vector (%s)", n.kind == .Bind_Input_Vector ? "Bind" : "Unbind", n.is_look_vector ? "Look" : "Move"))
				context.allocator = prev_alloc
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
			im.TextColored(thm.studio_tokens().scancode_badge_fg, "[DEV] Direct Scancode Binding")
			im.SetNextItemWidth(-1)
			if im.BeginCombo("##det_dbg_key", _debug_key_label(n.debug_key_code)) {
				for preset in _DEBUG_KEY_PRESETS {
					if im.Selectable(preset.label, n.debug_key_code == preset.code) {
						vs_push_undo()
						n.debug_key_code = preset.code
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						delete(n.title)
						n.title = strings.clone(fmt.tprintf("[DEV] %s Debug Key (%s)", n.kind == .Bind_Debug_Key ? "Bind" : "Unbind", string(preset.label)))
						context.allocator = prev_alloc
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
						prev_alloc := context.allocator
						context.allocator = runtime.default_allocator()
						if n.delegate_name != "" do delete(n.delegate_name)
						n.delegate_name = strings.clone(d)
						context.allocator = prev_alloc
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
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					renamed := engine.vg_rename_custom_proc(&_vs.graph, n.uid, new_p)
					context.allocator = prev_alloc
					if renamed {
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
			if im.Checkbox(fmt.ctprintf("Pass By Reference (%s ^T)##det_pref", icons.ICON_MD_DIAMOND), &_vs.new_pin_is_ref) && _vs.new_pin_is_ref {
				_vs.new_pin_is_slice = false
			}
			widgets.tooltip_unsafe("Pass mutable ^T address directly into node.", bp_unsafe_tooltip_warning(.Float, .Single, true))
			if im.Checkbox("Pass As Slice ([]T)##det_pslice", &_vs.new_pin_is_slice) && _vs.new_pin_is_slice {
				_vs.new_pin_is_ref = false
			}
			widgets.tooltip_unsafe("Pass a zero-copy []T slice into node.", bp_unsafe_tooltip_warning(.Float, .Slice, false))
			if im.Button("+ Add Pin to Node", {-1, 0}) {
				pnm := sanitize_odin_ident(strings.trim_space(_c_str(_vs.new_pin_buf[:])), context.temp_allocator)
				if pnm != "" {
					vs_push_undo()
					prev_alloc := context.allocator
					context.allocator = runtime.default_allocator()
					append(&n.inputs, engine.VG_Pin_Def{
						name           = strings.clone(pnm),
						pin_type       = hot.Hot_Pin_Type(_vs.new_pin_type),
						pass_mode      = _vs.new_pin_is_ref ? .By_Reference : .Copy_Value,
						is_array       = _vs.new_pin_is_slice,
						container_kind = _vs.new_pin_is_slice ? .Slice : .Single,
					})
					context.allocator = prev_alloc
					_vs.new_pin_buf[0] = 0
					_vs.dirty_unbaked  = true
				}
			}
		}

		// _draw_target_proc_selector above can append to _vs.graph.nodes and invalidate `n`.
		n = engine.vg_find_node(&_vs.graph, sel_uid)
		if n == nil do return

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
				if _draw_default_value_widgets(
					&_vs.graph, fmt.tprintf("uwd_%d", ipi), ip.pin_type, ip.custom_type_name,
					&ip.default_bool, &ip.default_int, &ip.default_i64, &ip.default_u64,
					&ip.default_f32, &ip.default_f64, &ip.default_vec2, &ip.default_vec3, &ip.default_vec4,
					&ip.default_str, ip.name,
				) {
					_vs.dirty_unbaked = true
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

