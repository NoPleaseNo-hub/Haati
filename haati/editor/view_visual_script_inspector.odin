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
import "core:os"
import "core:path/filepath"
import "core:slice"
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
_list_mhgraph_assets :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 12, allocator)
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	search_dirs := [2]string{"assets/scripts", "haati/assets/scripts"}
	for sd in search_dirs {
		scripts_dir, _ := filepath.join({repo_root, sd}, context.temp_allocator)
		if h, err := os.open(scripts_dir); err == nil {
			if entries, rerr := os.read_dir(h, -1, context.temp_allocator); rerr == nil {
				for e in entries {
					if strings.has_suffix(e.name, ".bodin") || strings.has_suffix(e.name, ".mhgraph") {
						rel_cand := fmt.aprintf("assets/scripts/%s", e.name, allocator = allocator)
						already := false
						for ex in out do if ex == rel_cand { already = true; break }
						if !already do append(&out, rel_cand)
					}
				}
			}
			os.close(h)
		}
	}
	if len(out) == 0 {
		append(&out, strings.clone("assets/scripts/hover_oscillator.bodin", allocator))
	}
	slice.sort(out[:])
	return out[:]
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
	assets := _list_mhgraph_assets(context.temp_allocator)
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
		if !engine.vg_has_tick_event(g) {
			im.TextColored({0.28, 0.94, 0.62, 1.0}, icons.ICON_MD_BOLT + " Event-Driven Blueprint (0.00 ms Idle CPU)")
		} else {
			im.TextColored({0.96, 0.74, 0.30, 1.0}, icons.ICON_MD_REFRESH + " Opt-In Frame Tick Active")
		}

		// Evaluate current effective variable values (`defaults + instance_overrides`)
		bb: engine.VG_Runtime_Blackboard
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
				new_val_str := ""
				changed     := false

				#partial switch v.pin_type {
				case .Bool:
					bv := bb.slots[vi].val_bool
					if im.Checkbox(fmt.ctprintf("%s", v.name), &bv) {
						new_val_str = bv ? "true" : "false"
						changed     = true
					}
				case .Int:
					iv := bb.slots[vi].val_int
					if im.DragInt(fmt.ctprintf("%s", v.name), &iv, 1.0) {
						new_val_str = fmt.tprintf("%d", iv)
						changed     = true
					}
				case .Int64:
					i64v := bb.slots[vi].val_i64
					step_one: i64 = 1
					if im.InputScalar(fmt.ctprintf("%s", v.name), .S64, &i64v, &step_one) {
						new_val_str = fmt.tprintf("%d", i64v)
						changed     = true
					}
				case .Float:
					fv := bb.slots[vi].val_f32
					has_range := v.slider_max > v.slider_min
					ed := has_range \
						? im.SliderFloat(fmt.ctprintf("%s", v.name), &fv, v.slider_min, v.slider_max) \
						: im.DragFloat(fmt.ctprintf("%s", v.name), &fv, 0.05)
					if ed {
						new_val_str = fmt.tprintf("%.4f", fv)
						changed     = true
					}
				case .Vec2:
					v2 := bb.slots[vi].val_vec2
					if im.DragFloat2(fmt.ctprintf("%s", v.name), &v2, 0.05) {
						new_val_str = fmt.tprintf("%.4f,%.4f", v2.x, v2.y)
						changed     = true
					}
				case .Vec3:
					v3 := bb.slots[vi].val_vec3
					if im.DragFloat3(fmt.ctprintf("%s", v.name), &v3, 0.05) {
						new_val_str = fmt.tprintf("%.4f,%.4f,%.4f", v3.x, v3.y, v3.z)
						changed     = true
					}
				case .Vec4:
					v4 := bb.slots[vi].val_vec4
					if im.DragFloat4(fmt.ctprintf("%s", v.name), &v4, 0.05) {
						new_val_str = fmt.tprintf("%.4f,%.4f,%.4f,%.4f", v4.x, v4.y, v4.z, v4.w)
						changed     = true
					}
				case .Quat:
					q4 := bb.slots[vi].val_quat
					if im.DragFloat4(fmt.ctprintf("%s", v.name), &q4, 0.02) {
						new_val_str = fmt.tprintf("%.4f,%.4f,%.4f,%.4f", q4.x, q4.y, q4.z, q4.w)
						changed     = true
					}
				case .String, .Asset:
					sbuf: [128]u8
					if bb.slots[vi].val_cstr != nil {
						sval := string(bb.slots[vi].val_cstr)
						ncopy := min(len(sval), len(sbuf) - 1)
						copy(sbuf[:ncopy], sval[:ncopy])
					}
					hint: cstring = v.pin_type == .Asset ? "assets/..." : "string value..."
					if im.InputTextWithHint(fmt.ctprintf("%s", v.name), hint, cstring(raw_data(sbuf[:])), len(sbuf)) {
						new_val_str = strings.clone(string(cstring(raw_data(sbuf[:]))), context.temp_allocator)
						changed     = true
					}
				}

				if v.tooltip_text != "" {
					widgets.tooltip(fmt.ctprintf("%s", v.tooltip_text))
				}

				if changed {
					updated := engine.vg_set_instance_override_value(r.instance_overrides, v.name, new_val_str, context.temp_allocator)
					if r.instance_overrides != "" do delete(r.instance_overrides)
					r.instance_overrides = strings.clone(updated)
					// Live-push into active entity runtime slot if already running!
					if v.pin_type == .String || v.pin_type == .Asset {
						engine.visual_script_set_entity_string_var(r.owner, vi, new_val_str)
					} else if ptr := engine.visual_script_get_entity_var_ptr(r.owner, vi); ptr != nil {
						tmp_bb: engine.VG_Runtime_Blackboard
						engine.vg_sync_blackboard(g, &tmp_bb)
						engine.vg_apply_instance_overrides(g, &tmp_bb, r.instance_overrides)
						#partial switch v.pin_type {
						case .Bool:  (cast(^bool)ptr)^    = tmp_bb.slots[vi].val_bool
						case .Int:   (cast(^i32)ptr)^     = tmp_bb.slots[vi].val_int
						case .Int64: (cast(^i64)ptr)^     = tmp_bb.slots[vi].val_i64
						case .Float: (cast(^f32)ptr)^     = tmp_bb.slots[vi].val_f32
						case .Vec2:  (cast(^[2]f32)ptr)^  = tmp_bb.slots[vi].val_vec2
						case .Vec3:  (cast(^[3]f32)ptr)^  = tmp_bb.slots[vi].val_vec3
						case .Vec4:  (cast(^[4]f32)ptr)^  = tmp_bb.slots[vi].val_vec4
						case .Quat:  (cast(^[4]f32)ptr)^  = tmp_bb.slots[vi].val_quat
						}
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
