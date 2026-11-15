package editor

// =============================================================================
// BLUEPRINT COMPONENT SCENE INSPECTOR (`view_visual_script_inspector.odin`)
// =============================================================================
// Upgrades `engine.VisualScriptRunner` inside the Scene Entity Inspector into an
// Unreal-style Blueprint Component Card:
//   - Blueprint Asset Selector (`assets/scripts/*.mhgraph`)
//   - `[ + New Blueprint... ]` 1-click inline Blueprint script creator & baker
//   - `[ Open in Blueprint Studio ]` 1-click launcher
//   - `⚡ Event-Driven (0.00 ms Idle)` vs `↻ Opt-In Frame Tick` runtime badge
//   - Live per-entity `👁 Instance Editable` variable controls grouped by Category
//     with Slider Min/Max & Tooltips, persisted in `r.instance_overrides`!

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "haati:editor/icons"
import "haati:editor/inspector"
import thm "haati:editor/theme"
import vs "haati:editor/visual_script"
import "haati:editor/widgets"
import "haati:engine"
import im "haati:external/odin-imgui"

@(private = "file")
_bp_insp_new_name: [64]byte

@(phase={key=engine.Phase.EditorInit, order=2, mode=Editor})
visual_script_runner_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.VisualScriptRunner), _visual_script_runner_inspector)
}

@(private = "file")
_visual_script_runner_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	r := cast(^engine.VisualScriptRunner)ctx.ptr
	if r == nil {
		inspector.draw_component(ctx)
		return
	}
	p := thm.palette()

	// 1. Blueprint Asset Selector + `[ + New ]` + `[ Open Studio ]`
	im.TextColored(p.accent, icons.ICON_MD_ACCOUNT_TREE + " Blueprint Script Asset (.bodin)")
	assets := vs.list_blueprint_assets(context.temp_allocator)
	cur_lbl := r.graph_path != "" ? filepath.base(r.graph_path) : "<Select .bodin>"

	im.SetNextItemWidth(max(im.GetContentRegionAvail().x - 74.0, 110.0))
	if im.BeginCombo("##vsr_bp_combo", fmt.ctprintf("%s", cur_lbl)) {
		for rel in assets {
			if im.Selectable(fmt.ctprintf("%s", filepath.base(rel)), r.graph_path == rel) {
				if r.graph_path != "" do delete(r.graph_path)
				r.graph_path = strings.clone(rel)
				base_no_ext := strings.trim_suffix(strings.trim_suffix(filepath.base(rel), ".bodin"), ".mhgraph")
				proc_sym := fmt.tprintf("mhgraph_%s", vs.sanitize_odin_ident(base_no_ext, context.temp_allocator))
				if r.compiled_proc_name != "" do delete(r.compiled_proc_name)
				r.compiled_proc_name = strings.clone(proc_sym)
				r.init_fired = false
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Select which `.bodin` (Blueprint Odin) or `.mhgraph` script drives this entity")

	im.SameLine()
	if im.Button("+ New##vsr_new_bp", {66, 0}) {
		im.OpenPopup("##vsr_create_bp_popup")
	}
	widgets.tooltip("Create a brand-new Blueprint script, attach it to this entity, and open it in Blueprint Studio!")

	if im.BeginPopup("##vsr_create_bp_popup") {
		im.TextColored(p.accent, "New Entity Blueprint Script")
		im.SetNextItemWidth(220)
		im.InputTextWithHint("##vsr_new_nm", "e.g. door_switch_bp", cstring(raw_data(_bp_insp_new_name[:])), len(_bp_insp_new_name))
		if im.Button("Create, Attach & Open Studio", {-1, 0}) {
			nm := strings.trim_space(string(cstring(raw_data(_bp_insp_new_name[:]))))
			if nm != "" {
				if rel_p, proc_nm, ok := vs.create_new_blueprint_asset(nm); ok {
					if r.graph_path != ""         do delete(r.graph_path)
					if r.compiled_proc_name != "" do delete(r.compiled_proc_name)
					r.graph_path         = strings.clone(rel_p)
					r.compiled_proc_name = strings.clone(proc_nm)
					r.init_fired         = false
					_bp_insp_new_name[0] = 0
					vs.open_blueprint_in_studio(rel_p)
					im.CloseCurrentPopup()
				}
			}
		}
		im.EndPopup()
	}

	im.PushStyleColorImVec4(.Button, thm.with_alpha(p.accent, 0.24))
	if im.Button(fmt.ctprintf("%s Open in Blueprint Studio", icons.ICON_MD_CODE), {-1, 0}) {
		vs.open_blueprint_in_studio(r.graph_path)
	}
	im.PopStyleColor()
	widgets.tooltip("Open this Blueprint in the 3-Column Unreal/Odin Blueprint Studio (`My Blueprint` | `Graph` | `Details`)")

	// 2. Cached Graph Metadata: Runtime Cost Badge + `👁 Instance Editable` Variables!
	g := engine.visual_script_get_cached_graph(r.graph_path)
	if g != nil {
		vs.draw_runner_perf_and_fuse_status(g, engine.visual_script_get_entity_bb(r.owner), r.owner, inline = false, reset_btn_id = "Reset Loop Fuse##vsr_fuse")

		// Evaluate current effective variable values (`defaults + instance_overrides`)
		bb: engine.VG_Runtime_Blackboard
		defer engine.vg_destroy_blackboard(&bb)
		engine.vg_sync_blackboard(g, &bb)
		if r.instance_overrides != "" {
			engine.vg_apply_instance_overrides(g, &bb, r.instance_overrides)
		}

		editable_count := 0
		for v in g.variables do if v.instance_editable do editable_count += 1

		if editable_count > 0 {
			im.Separator()
			im.TextColored(p.accent, icons.ICON_MD_VISIBILITY + " Instance Editable Variables")
			last_cat := ""
			for v, vi in g.variables {
				if !v.instance_editable || vi >= engine.VG_MAX_VARS do continue
				cat := v.category != "" ? v.category : "Default"
				if cat != last_cat {
					last_cat = cat
					im.TextDisabled("[%s]", fmt.ctprintf("%s", cat))
				}

				im.PushIDInt(i32(vi))
				c_icon, t_icon, v_col := thm.studio_var_icon_and_color(v.pin_type, v.is_array, v.array_is_bounded, false)
				if v.is_array {
					im.TextColored(v_col, "%s", fmt.ctprintf("%s", c_icon))
					im.SameLine(0, 4)
					im.TextDisabled("%s", fmt.ctprintf("%s : %s (Array)", v.name, engine.vg_var_odin_type_ex(g, v)))
					if v.tooltip_text != "" {
						widgets.tooltip(fmt.ctprintf("%s", v.tooltip_text))
					}
					im.PopID()
					continue
				}
				if v.pin_type == .Struct_Val {
					flds, sz, _ := engine.vg_struct_layout(g, v.custom_type_name, context.temp_allocator)
					im.TextColored(v_col, "%s", fmt.ctprintf("%s", t_icon))
					im.SameLine(0, 4)
					im.TextDisabled("%s", fmt.ctprintf("%s : %s (%d fields, %dB)", v.name, engine.vg_var_odin_type_ex(g, v), len(flds), sz))
					if v.tooltip_text != "" {
						widgets.tooltip(fmt.ctprintf("%s", v.tooltip_text))
					}
					im.PopID()
					continue
				}

				im.TextColored(v_col, "%s", fmt.ctprintf("%s", t_icon))
				im.SameLine(0, 4)

				init_str := bb.slots[vi].val_cstr != nil ? string(bb.slots[vi].val_cstr) : ""
				id_tag   := fmt.tprintf("vsr_var_%d", vi)
				changed, edited_str := vs.draw_hot_slot_value_editor(
					g,
					id_tag,
					v.pin_type,
					v.custom_type_name,
					&bb.slots[vi],
					init_str,
					v.name,
					v.slider_min,
					v.slider_max,
					0,
					false,
					false,
				)

				if v.tooltip_text != "" {
					widgets.tooltip(fmt.ctprintf("%s", v.tooltip_text))
				}

				if changed {
					new_val_str := (v.pin_type == .String || v.pin_type == .Asset) \
						? edited_str \
						: vs.format_slot_override_value(v.pin_type, &bb.slots[vi], "", context.temp_allocator)
					updated := engine.vg_set_instance_override_value(r.instance_overrides, v.name, new_val_str, context.temp_allocator)
					if r.instance_overrides != "" do delete(r.instance_overrides)
					r.instance_overrides = strings.clone(updated)
					// Live-push into active entity runtime slot if already running!
					if v.pin_type == .String || v.pin_type == .Asset {
						engine.visual_script_set_entity_string_var(r.owner, vi, new_val_str)
					} else if ptr := engine.visual_script_get_entity_var_ptr(r.owner, vi); ptr != nil {
						tmp_bb: engine.VG_Runtime_Blackboard
						defer engine.vg_destroy_blackboard(&tmp_bb)
						engine.vg_sync_blackboard(g, &tmp_bb)
						engine.vg_apply_instance_overrides(g, &tmp_bb, r.instance_overrides)
						engine.vg_write_slot_to_var_ptr(ptr, v.pin_type, &tmp_bb.slots[vi])
					}
				}
				im.PopID()
			}

			if r.instance_overrides != "" {
				if im.SmallButton("Reset Overrides to Blueprint Defaults") {
					delete(r.instance_overrides)
					r.instance_overrides = ""
				}
			}
		}
	}

	im.Separator()
	if im.TreeNodeEx("Advanced Runner Properties##vsr_raw", {}) {
		inspector.draw_component(ctx)
		im.TreePop()
	}
}
