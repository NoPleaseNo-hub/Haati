package tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../engine"
import cs "moonhug:editor/code_studio"
import vs "moonhug:editor/visual_script"
import hot "moonhug:engine/hot_api"
import "moonhug:engine/input"
import cad_csg "moonhug:packages/cad_csg"

@(private = "file")
_bp_local_pos :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	w := engine.ctx_world()
	if w == nil do return {}
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	return t != nil ? t.position : {}
}

// 1. Verifies explicit Odin-style Delegate Input Binding (`Event_Init` -> `Bind_Input_Action` -> `◇ Proc`),
//    `Unbind_Input_Action`, dynamic on-demand re-binding to a DIFFERENT procedure (`On_Double_Jump`),
//    `[DEV] Bind_Debug_Key` / `Unbind_Debug_Key`, `0.00 ns` idle when `Event_Tick` is omitted, and
//    automatic listener cleanup when the entity / `VisualScriptRunner` is destroyed!
@(test)
test_blueprint_odin_delegate_bind_unbind_and_dynamic_swap :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Build an Event-Driven Blueprint (`Event_Tick` intentionally omitted!)
	g: engine.Visual_Graph
	g.name           = strings.clone("unit_test_jump_bp")
	g.package_target = strings.clone("moonhug/hot_scripts")
	for sp in ([3]string{"self", "hot", "math"}) {
		append(&g.using_spaces, strings.clone(sp))
	}

	u_init    := engine.vg_add_node(&g, .Event_Init,        {0, 0})
	u_bind    := engine.vg_add_node(&g, .Bind_Input_Action, {240, 0}, "Jump")
	u_bind_dk := engine.vg_add_node(&g, .Bind_Debug_Key,    {480, 0})
	u_p1      := engine.vg_add_node(&g, .Custom_Proc_Entry, {0, 180}, "On_Single_Jump")
	u_set1    := engine.vg_add_node(&g, .Set_Transform_Pos, {280, 180})
	u_p2      := engine.vg_add_node(&g, .Custom_Proc_Entry, {0, 340}, "On_Double_Jump")
	u_set2    := engine.vg_add_node(&g, .Set_Transform_Pos, {280, 340})
	u_p_dbg   := engine.vg_add_node(&g, .Custom_Proc_Entry, {0, 500}, "On_Debug_G")
	u_set_dbg := engine.vg_add_node(&g, .Set_Transform_Pos, {280, 500})

	if s1 := engine.vg_find_node(&g, u_set1);    s1 != nil && len(s1.inputs) > 1    do s1.inputs[1].default_vec3    = {0, 2.5, 0}
	if s2 := engine.vg_find_node(&g, u_set2);    s2 != nil && len(s2.inputs) > 1    do s2.inputs[1].default_vec3    = {0, 12.0, 0}
	if sd := engine.vg_find_node(&g, u_set_dbg); sd != nil && len(sd.inputs) > 1    do sd.inputs[1].default_vec3    = {7.0, 12.0, 0}

	// Wire `On_Init -> Bind_Input_Action("Jump") -> Bind_Debug_Key(G)`
	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_bind,    to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_bind, from_pin = 0, to_uid = u_bind_dk, to_pin = 0})

	// Wire `◇ Delegate` pins (output `0`) and `▷ Exec` bodies (output `1`)!
	append(&g.wires, engine.VG_Wire{from_uid = u_p1,    from_pin = 0, to_uid = u_bind,    to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_p1,    from_pin = 1, to_uid = u_set1,    to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_p2,    from_pin = 1, to_uid = u_set2,    to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_p_dbg, from_pin = 0, to_uid = u_bind_dk, to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_p_dbg, from_pin = 1, to_uid = u_set_dbg, to_pin = 0})
	defer engine.vg_destroy_graph(&g)
	defer engine.visual_script_reset_runtime_state()

	testing.expect(t, !engine.vg_has_tick_event(&g), "expected Event-Driven Blueprint without Event_Tick to report vg_has_tick_event == false")

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_rel   := fmt.tprintf("assets/scripts/_tmp_unit_jump_%d.mhgraph", os.get_pid())
	tmp_abs, _ := filepath.join({repo_root, tmp_rel}, context.temp_allocator)
	testing.expect(t, engine.vg_save_to_file(&g, tmp_abs), "expected temp .mhgraph save to succeed")
	defer {
		_ = os.remove(tmp_abs)
		engine.visual_script_invalidate_cached_graph(tmp_rel)
	}

	hero := engine.transform_new("DelegateHero")
	engine.transform_set_local_position(hero, {0, 0, 0})
	_, comp_ptr := engine.transform_add_comp(hero, .VisualScriptRunner)
	runner := cast(^engine.VisualScriptRunner)comp_ptr
	testing.expect(t, runner != nil, "expected VisualScriptRunner component")
	if runner != nil {
		if runner.graph_path != ""         do delete(runner.graph_path)
		if runner.compiled_proc_name != "" do delete(runner.compiled_proc_name)
		runner.graph_path         = strings.clone(tmp_rel)
		runner.compiled_proc_name = strings.clone("mhgraph_unit_test_jump_bp")
		runner.init_fired         = false
	}

	// First runner tick fires `Event_Init` once (which binds `"Jump"` -> `On_Single_Jump` and `G` -> `On_Debug_G`),
	// and subsequent ticks do ZERO per-frame work because `Event_Tick` is omitted!
	for _ in 0 ..< 5 {
		engine.visual_script_runners_tick(0.016)
	}
	testing.expect(t, runner.init_fired, "expected Event_Init to fire once on first runner tick")
	testing.expect(t, math.abs(_bp_local_pos(hero).y) < 1e-4, "expected 0 position change while idle before input fires")

	// Fire `"Jump"` -> `On_Single_Jump` sets `y = 2.5`!
	fired_1 := engine.visual_script_fire_action_for_test("Jump", true)
	testing.expect_value(t, fired_1, 1)
	testing.expect(t, math.abs(_bp_local_pos(hero).y - 2.5) < 1e-4, "expected bound On_Single_Jump procedure to set y = 2.5")

	// Unbind `"Jump"` dynamically -> firing `"Jump"` must now do NOTHING!
	engine.visual_script_unbind_action_runtime(hero, "Jump")
	engine.transform_set_local_position(hero, {0, 1.0, 0})
	fired_after_unbind := engine.visual_script_fire_action_for_test("Jump", true)
	testing.expect_value(t, fired_after_unbind, 0)
	testing.expect(t, math.abs(_bp_local_pos(hero).y - 1.0) < 1e-4, "expected unbound action not to mutate position")

	// Dynamically re-bind `"Jump"` on demand to `On_Double_Jump`!
	p2_node := engine.vg_find_custom_proc_node(&g, "On_Double_Jump")
	testing.expect(t, p2_node != nil, "expected On_Double_Jump node")
	if p2_node != nil {
		engine.visual_script_bind_action_runtime(hero, "Jump", .Pressed, 10, true, "On_Double_Jump", p2_node.uid)
	}
	fired_rebind := engine.visual_script_fire_action_for_test("Jump", true)
	testing.expect_value(t, fired_rebind, 1)
	testing.expect(t, math.abs(_bp_local_pos(hero).y - 12.0) < 1e-4, "expected dynamically rebound On_Double_Jump to set y = 12.0")

	// Fire `[DEV]` Debug Key `G` -> `On_Debug_G` sets `x = 7.0`!
	fired_dbg := engine.visual_script_fire_debug_key_for_test(int(input.Key.G), true)
	testing.expect_value(t, fired_dbg, 1)
	testing.expect(t, math.abs(_bp_local_pos(hero).x - 7.0) < 1e-4, "expected bound [DEV] Debug Key G to set x = 7.0")

	// Destroy entity / `VisualScriptRunner` -> all bound actions & debug keys MUST auto-unbind!
	engine.transform_destroy(hero)
	testing.expect_value(t, engine.visual_script_fire_action_for_test("Jump", true), 0)
	testing.expect_value(t, engine.visual_script_fire_debug_key_for_test(int(input.Key.G), true), 0)
}

// 2. Verifies Custom Odin Delegates (`Bind` / `Broadcast` / `Unbind`) and per-entity
//    `👁 Instance Editable` `instance_overrides` serialization & blackboard application!
@(test)
test_blueprint_custom_delegates_and_instance_overrides :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	g: engine.Visual_Graph
	g.name = strings.clone("unit_delegate_bp")
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("speed"),   pin_type = .Float, default_f32  = 5.0,   instance_editable = true})
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("is_boss"), pin_type = .Bool,  default_bool = false, instance_editable = true})
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("charges"), pin_type = .Int,   default_int  = 1,     instance_editable = true})
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("offset"),  pin_type = .Vec3,  default_vec3 = {0,0,0}, instance_editable = true})

	u_proc := engine.vg_add_node(&g, .Custom_Proc_Entry, {0, 0},   "On_Shield_Broken")
	u_set  := engine.vg_add_node(&g, .Set_Transform_Pos, {260, 0})
	if sn := engine.vg_find_node(&g, u_set); sn != nil && len(sn.inputs) > 1 {
		sn.inputs[1].default_vec3 = {3.0, 9.0, -2.0}
	}
	append(&g.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 1, to_uid = u_set, to_pin = 0})
	defer engine.vg_destroy_graph(&g)
	defer engine.visual_script_reset_runtime_state()

	// Test `vg_set_instance_override_value` + `vg_apply_instance_overrides`
	ov := ""
	ov = engine.vg_set_instance_override_value(ov, "speed",   "18.5",          context.temp_allocator)
	ov = engine.vg_set_instance_override_value(ov, "is_boss", "true",          context.temp_allocator)
	ov = engine.vg_set_instance_override_value(ov, "charges", "4",             context.temp_allocator)
	ov = engine.vg_set_instance_override_value(ov, "offset",  "1.5,2.5,-3.5",  context.temp_allocator)
	// Updating an existing key replaces it cleanly without duplicating
	ov = engine.vg_set_instance_override_value(ov, "speed",   "22.25",         context.temp_allocator)

	bb: engine.VG_Runtime_Blackboard
	engine.vg_sync_blackboard(&g, &bb)
	engine.vg_apply_instance_overrides(&g, &bb, ov)
	testing.expect(t, math.abs(bb.slots[0].val_f32 - 22.25) < 1e-3, "expected overridden f32 speed == 22.25")
	testing.expect_value(t, bb.slots[1].val_bool, true)
	testing.expect_value(t, bb.slots[2].val_int, i32(4))
	testing.expect(t, math.abs(bb.slots[3].val_vec3.z - (-3.5)) < 1e-3, "expected overridden Vec3 offset.z == -3.5")

	// Test Custom Odin Delegate `bind -> broadcast -> unbind`
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_rel   := fmt.tprintf("assets/scripts/_tmp_unit_del_%d.mhgraph", os.get_pid())
	tmp_abs, _ := filepath.join({repo_root, tmp_rel}, context.temp_allocator)
	_ = engine.vg_save_to_file(&g, tmp_abs)
	defer {
		_ = os.remove(tmp_abs)
		engine.visual_script_invalidate_cached_graph(tmp_rel)
	}

	ent := engine.transform_new("ShieldEntity")
	_, cptr := engine.transform_add_comp(ent, .VisualScriptRunner)
	r := cast(^engine.VisualScriptRunner)cptr
	if r != nil {
		if r.graph_path != "" do delete(r.graph_path)
		r.graph_path = strings.clone(tmp_rel)
	}
	p_node := engine.vg_find_custom_proc_node(&g, "On_Shield_Broken")
	testing.expect(t, p_node != nil, "expected On_Shield_Broken procedure")
	if p_node != nil {
		engine.visual_script_bind_custom_delegate_runtime(ent, "On_Shield_Break", "On_Shield_Broken", p_node.uid)
		engine.visual_script_broadcast_custom_delegate_runtime(ent, "On_Shield_Break", 1.0)
		testing.expect(t, math.abs(_bp_local_pos(ent).y - 9.0) < 1e-4, "expected Delegate Broadcast to execute bound On_Shield_Broken procedure")

		engine.transform_set_local_position(ent, {0, 0, 0})
		engine.visual_script_unbind_custom_delegate_runtime(ent, "On_Shield_Break")
		engine.visual_script_broadcast_custom_delegate_runtime(ent, "On_Shield_Break", 1.0)
		testing.expect(t, math.abs(_bp_local_pos(ent).y) < 1e-4, "expected Delegate Broadcast after Unbind to fire 0 callbacks")
	}
}

// 3. Verifies Pseudo-OOP `using bp: ^<Name>_Blueprint_State` + `using math` transpilation,
//    Opt-In `Event_Tick` omission (`0.00 ns` idle), pin-name collision guard, AND ground-truth
//    `odin check -vet-unused` compilation of the generated `.odin` source!
@(test)
test_blueprint_pseudo_oop_transpiler_and_opt_in_tick :: proc(t: ^testing.T) {
	g: engine.Visual_Graph
	g.name = strings.clone("pseudo_oop_actor")
	for sp in ([4]string{"self", "hot", "math", "using_math"}) {
		append(&g.using_spaces, strings.clone(sp))
	}
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("impulse_power"), pin_type = .Float, default_f32 = 6.0, instance_editable = true})
	append(&g.variables, engine.VG_Var_Decl{name = strings.clone("jump_counter"),  pin_type = .Int,   default_int = 0})

	u_init := engine.vg_add_node(&g, .Event_Init,         {0, 0})
	u_bind := engine.vg_add_node(&g, .Bind_Input_Action,  {250, 0}, "Jump")
	u_proc := engine.vg_add_node(&g, .Custom_Proc_Entry,  {0, 180}, "On_Actor_Jump")
	u_code := engine.vg_add_node(&g, .Odin_Function_Node, {300, 180}, "Pseudo OOP Jump Step")
	// Second Odin node intentionally has an input pin named `impulse_power` (colliding with Blueprint var!)
	// to verify `_node_has_var_pin_collision` automatically drops `using` on that node!
	u_coll := engine.vg_add_node(&g, .Odin_Function_Node, {620, 180}, "Collision Guard Node")

	if cn := engine.vg_find_node(&g, u_code); cn != nil {
		// Clear default demo pins so this node uses ONLY `using self` + `using math`!
		for p in cn.inputs do if p.name != "" do delete(p.name)
		clear(&cn.inputs)
		append(&cn.inputs, engine.VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		for p in cn.outputs do if p.name != "" do delete(p.name)
		clear(&cn.outputs)
		append(&cn.outputs, engine.VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})

		delete(cn.odin_body)
		cn.odin_body = strings.clone(
			"// Direct OOP-style field access via `using bp` + unqualified `sin` via `using math`!\n" +
			"jump_counter += 1\n" +
			"if p := hot.pos_ref(api, self); p != nil {\n" +
			"\tp.y += sin(f32(jump_counter)) * impulse_power\n" +
			"}\n",
		)
	}

	if col_n := engine.vg_find_node(&g, u_coll); col_n != nil {
		for p in col_n.inputs do if p.name != "" do delete(p.name)
		clear(&col_n.inputs)
		append(&col_n.inputs, engine.VG_Pin_Def{name = strings.clone("Exec"),          pin_type = .Exec})
		append(&col_n.inputs, engine.VG_Pin_Def{name = strings.clone("impulse_power"), pin_type = .Float, default_f32 = 2.0})
		for p in col_n.outputs do if p.name != "" do delete(p.name)
		clear(&col_n.outputs)
		append(&col_n.outputs, engine.VG_Pin_Def{name = strings.clone("Exec"), pin_type = .Exec})
		delete(col_n.odin_body)
		col_n.odin_body = strings.clone("bp.impulse_power = impulse_power\n")
	}

	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_bind, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 0, to_uid = u_bind, to_pin = 1})
	append(&g.wires, engine.VG_Wire{from_uid = u_proc, from_pin = 1, to_uid = u_code, to_pin = 0})
	append(&g.wires, engine.VG_Wire{from_uid = u_code, from_pin = 0, to_uid = u_coll, to_pin = 0})
	defer engine.vg_destroy_graph(&g)

	odin_src, main_proc := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	testing.expect_value(t, main_proc, "mhgraph_pseudo_oop_actor")
	testing.expect(t, strings.contains(odin_src, "pseudo_oop_actor_Blueprint_State :: struct"), "expected flat Blueprint_State struct emission")
	testing.expect(t, strings.contains(odin_src, "using bp: ^pseudo_oop_actor_Blueprint_State"), "expected `using bp: ^State` Pseudo-OOP injection")
	testing.expect(t, strings.contains(odin_src, "using math"), "expected `using math` emission")
	testing.expect(t, strings.contains(odin_src, "mhgraph_pseudo_oop_actor__on_init :: proc"), "expected `__on_init` @(hot_proc)")
	testing.expect(t, strings.contains(odin_src, "mhgraph_pseudo_oop_actor__proc_On_Actor_Jump :: proc"), "expected `__proc_On_Actor_Jump` @(hot_proc)")
	testing.expect(t, !strings.contains(odin_src, "mhgraph_pseudo_oop_actor :: proc"), "expected `mhgraph_pseudo_oop_actor` Tick proc to be OMITTED when Event_Tick is absent!")

	// Fast Stage-A syntax check
	syn_diags, _ := cs.check_odin_syntax_in_ram(odin_src, false, context.temp_allocator)
	testing.expect_value(t, len(syn_diags), 0)

	// Ground-truth `odin check -vet-unused` on the generated `.odin` file in an isolated temp dir!
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	odin_exe  := engine.resolve_odin_binary(context.temp_allocator)
	tmp_dir, _ := filepath.join({repo_root, "builds", fmt.tprintf("_bp_check_%d", os.get_pid())}, context.temp_allocator)
	_ = os.make_directory_all(tmp_dir)
	defer {
		_ = os.remove_all(tmp_dir)
	}
	gen_file, _ := filepath.join({tmp_dir, "pseudo_oop_actor_mhgraph_generated.odin"}, context.temp_allocator)
	_ = os.write_entire_file(gen_file, transmute([]u8)odin_src)
	log_file, _ := filepath.join({tmp_dir, "odin_check.log"}, context.temp_allocator)

	args := [?]string{
		odin_exe, "check", tmp_dir,
		"-no-entry-point",
		fmt.tprintf("-collection:moonhug=%s/moonhug", repo_root),
		"-ignore-unknown-attributes",
		"-vet-unused",
	}
	bg, ok := engine.bg_process_start_to_file(repo_root, args[:], nil, log_file)
	testing.expect(t, ok, "expected bg_process_start_to_file to spawn odin check")
	if ok {
		done, exit_code := false, -1
		t0 := time.tick_now()
		for !done {
			done, exit_code = engine.bg_process_poll(&bg)
			if !done {
				if time.duration_seconds(time.tick_since(t0)) > 20.0 {
					engine.bg_process_kill(&bg)
					testing.expect(t, false, "odin check timed out after 20s")
					break
				}
				time.sleep(10 * time.Millisecond)
			}
		}
		if done && exit_code != 0 {
			err_txt, _ := os.read_entire_file(log_file, context.temp_allocator)
			testing.expectf(t, exit_code == 0, "expected generated Blueprint .odin to pass `odin check -vet-unused`, got exit %d:\n%s", exit_code, string(err_txt))
		} else if done {
			testing.expect_value(t, exit_code, 0)
		}
	}
}

// 4. Verifies `Using / Spaces` Zero-Guess Autocomplete (`[using self]`, `[using math]`),
//    `inject_using_space_into_source`, Inline Signature Call-Tips, and Hover Type Peek!
@(test)
test_using_spaces_autocomplete_call_tips_and_hover :: proc(t: ^testing.T) {
	bp_vars := [2]cs.Scoped_Pin_Badge{
		{name = "impulse_strength", odin_type = "f32", pass_mode = .By_Reference},
		{name = "dash_cooldown",    odin_type = "f32", pass_mode = .By_Reference},
	}
	bp_procs  := [1]string{"On_Dash_Pressed"}
	bp_spaces := [3]string{"self", "using_math", "hot"}
	cs.set_blueprint_autocomplete_context(bp_vars[:], bp_procs[:], bp_spaces[:])
	defer cs.set_blueprint_autocomplete_context(nil, nil, nil)

	// 1. `using self` Blueprint variable completion
	items_self, _ := cs.query_autocomplete_suggestions("imp", 3, nil, false, true, context.temp_allocator)
	found_imp := false
	for it in items_self {
		if it.label == "impulse_strength" && strings.contains(it.detail, "[using self]") {
			found_imp = true
			break
		}
	}
	testing.expect(t, found_imp, "expected `impulse_strength` with `[using self]` badge in scoped autocomplete")

	// 2. `using math` unqualified function completion (`atan2`)
	items_math, _ := cs.query_autocomplete_suggestions("atan", 4, nil, false, true, context.temp_allocator)
	found_atan2 := false
	for it in items_math {
		if it.label == "atan2" && strings.contains(it.detail, "[using math]") {
			found_atan2 = true
			break
		}
	}
	testing.expect(t, found_atan2, "expected unqualified `atan2` with `[using math]` badge when `using_math` space is active")

	// 3. `inject_using_space_into_source` inserts `import` & `using` cleanly below `package`
	raw_src := "package sample_plugin\n\nfoo :: proc() {}\n"
	for spec in cs.USING_SPACE_CATALOG {
		if spec.id == "using_math" {
			inj, changed := cs.inject_using_space_into_source(raw_src, spec, context.temp_allocator)
			testing.expect(t, changed, "expected inject_using_space_into_source to modify source")
			testing.expect(t, strings.contains(inj, "import \"core:math\"") && strings.contains(inj, "using math"), "expected both `import \"core:math\"` and `using math`")
		}
	}

	// 4. Inline Call-Tip Signature Parameter Hints (`active_param`)
	call_src := "v := hot.damp_vec3(cur_p, target_p, "
	tip, tip_ok := cs.extract_call_tip_info(call_src, len(call_src), context.temp_allocator)
	testing.expect(t, tip_ok, "expected extract_call_tip_info to detect enclosing `hot.damp_vec3(` call")
	if tip_ok {
		testing.expect_value(t, tip.receiver, "hot")
		testing.expect_value(t, tip.callee, "damp_vec3")
		testing.expect_value(t, tip.active_param, 2)
	}

	// 5. Hover Symbol Type Peek
	hover := cs.resolve_symbol_hover_info("impulse_strength", "", nil, context.temp_allocator)
	testing.expect(t, strings.contains(hover, "impulse_strength") && strings.contains(hover, "f32"), "expected hover peek to report Blueprint `using self` variable type")
}

// 5. Core ABI Locks + UI Safety Contracts (including BeginChild/EndChild & #c_varargs ICON_ ban) across Blueprint & IDE files!
@(test)
test_blueprint_abi_locks_and_ui_safety_contracts :: proc(t: ^testing.T) {
	// Engine Hot-API Delegate ABI Lock (`void_odin` component ABI locks live in `plugins/void_odin/tests/`)
	testing.expect_value(t, size_of(hot.Hot_Delegate), 16)

	// UI Safety Contracts
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	files := [5]string{
		"moonhug/editor/code_studio/code_studio.odin",
		"moonhug/editor/code_studio/code_autocomplete.odin",
		"moonhug/editor/visual_script/visual_script_editor.odin",
		"moonhug/editor/view_visual_script_inspector.odin",
		"moonhug/editor/view_manual.odin",
	}
	for rel in files {
		abs_p, _ := filepath.join({repo_root, rel}, context.temp_allocator)
		raw, err := os.read_entire_file(abs_p, context.temp_allocator)
		testing.expectf(t, err == nil, "expected %s to be readable", rel)
		if err != nil do continue

		lines := strings.split_lines(string(raw), context.temp_allocator)
		in_if_begin_child := false
		if_child_depth    := 0
		for line, li in lines {
			trimmed := strings.trim_space(line)
			if strings.has_prefix(trimmed, "//") do continue

			// 1. Tooltip Contract
			has_raw_tip := strings.contains(trimmed, "im.SetTooltip(") || strings.contains(trimmed, "im.SetItemTooltip(")
			testing.expectf(t, !has_raw_tip, "%s:%d violates widgets.tooltip contract: %s", rel, li + 1, trimmed)

			// 2. `DrawList_AddRect` parameter order contract
			if strings.contains(trimmed, "DrawList_AddRect(") {
				testing.expectf(t, !strings.contains(trimmed, ", {}, "), "%s:%d swaps thickness and flags in DrawList_AddRect: %s", rel, li + 1, trimmed)
			}

			// 3. `#c_varargs` ImGui CString Contract (`icons.ICON_*` untyped strings MUST NOT be passed directly as varargs!)
			is_vararg_txt := strings.contains(trimmed, "im.Text(") ||
			                 strings.contains(trimmed, "im.TextColored(") ||
			                 strings.contains(trimmed, "im.TextDisabled(") ||
			                 strings.contains(trimmed, "im.TextWrapped(") ||
			                 strings.contains(trimmed, "im.BulletText(")
			if is_vararg_txt && strings.contains(trimmed, "%s") {
				safe := strings.contains(trimmed, "fmt.ctprintf(") ||
				        strings.contains(trimmed, "cstring(")
				testing.expectf(t, safe, "%s:%d passes raw Odin string or untyped ICON constant to #c_varargs ImGui text proc: %s", rel, li + 1, trimmed)
			}

			// 4. `if im.BeginChild(...)` Early-Return Guard: an `if im.BeginChild` block MUST NEVER execute a bare `return`
			//    that skips its matching `im.EndChild()`! Use `open := im.BeginChild(...); defer im.EndChild()` instead.
			if strings.has_prefix(trimmed, "if im.BeginChild(") {
				in_if_begin_child = true
				if_child_depth    = 0
			}
			if in_if_begin_child {
				for ch in trimmed {
					if ch == '{' do if_child_depth += 1
					if ch == '}' do if_child_depth -= 1
				}
				if trimmed == "return" || strings.has_prefix(trimmed, "return ") {
					testing.expectf(t, false, "%s:%d executes early `return` inside `if im.BeginChild(...)` without `defer im.EndChild()`!", rel, li + 1)
				}
				if if_child_depth <= 0 && strings.contains(trimmed, "}") {
					in_if_begin_child = false
				}
			}
		}
	}
}

// 6. Verifies `.bodin` ("Blueprint Odin") unified single-file format:
//    - Valid native Odin source on top + `/* @BODIN_GRAPH_V1 ... @BODIN_GRAPH_END */` layout block at bottom
//    - Block-comment escape safety (`/* nested comment */` inside an Odin node body never breaks Odin lexer OR JSON round-trip!)
//    - Ground-truth `odin check -file -no-entry-point` directly on a `.bodin` file!
@(test)
test_bodin_unified_file_format_roundtrip_and_compiler_check :: proc(t: ^testing.T) {
	// Ensure starter `assets/scripts/hover_oscillator.bodin` is freshly baked on disk
	{
		demo_g: engine.Visual_Graph
		engine.vg_init_default_demo_graph(&demo_g, "hover_oscillator")
		defer engine.vg_destroy_graph(&demo_g)
		_, main_p, demo_ok := vs.bake_graph_to_odin_file(&demo_g, "assets/scripts/hover_oscillator.bodin")
		testing.expect(t, demo_ok, "expected hover_oscillator.bodin bake to succeed")
		testing.expect_value(t, main_p, "mhgraph_hover_oscillator")
	}

	g: engine.Visual_Graph
	g.name     = strings.clone("bodin_roundtrip_spec")
	g.next_uid = 1
	defer engine.vg_destroy_graph(&g)

	for sp in ([3]string{"self", "hot", "using_math"}) {
		append(&g.using_spaces, strings.clone(sp))
	}
	append(&g.variables, engine.VG_Var_Decl{
		name              = strings.clone("boost_speed"),
		pin_type          = .Float,
		default_f32       = 12.5,
		instance_editable = true,
		category          = strings.clone("Movement"),
	})

	u_init := engine.vg_add_node(&g, .Event_Init,         {30, 50})
	u_code := engine.vg_add_node(&g, .Odin_Function_Node, {320, 50})
	comment_edge_body := "/* nested C-style comment inside .bodin! */\nif p := hot.pos_ref(api, self); p != nil {\n\tp.y += sin(boost_speed) * 0.1\n}"
	if cn := engine.vg_find_node(&g, u_code); cn != nil {
		delete(cn.odin_body)
		cn.odin_body = strings.clone(comment_edge_body)
	}
	append(&g.wires, engine.VG_Wire{from_uid = u_init, from_pin = 0, to_uid = u_code, to_pin = 0})

	odin_src, _ := vs.transpile_graph_to_odin(&g, context.temp_allocator)
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_dir, _ := filepath.join({repo_root, "builds", "bodin_test_tmp"}, context.temp_allocator)
	_ = os.make_directory_all(tmp_dir)
	bodin_file, _ := filepath.join({tmp_dir, "bodin_roundtrip_spec.odin"}, context.temp_allocator)
	bodin_asset, _ := filepath.join({tmp_dir, "bodin_roundtrip_spec.bodin"}, context.temp_allocator)
	defer {
		_ = os.remove(bodin_file)
		_ = os.remove(bodin_asset)
	}

	testing.expect(t, engine.vg_save_bodin_file(&g, bodin_asset, odin_src), "expected vg_save_bodin_file (.bodin) to succeed")
	testing.expect(t, engine.vg_save_bodin_file(&g, bodin_file, odin_src),  "expected vg_save_bodin_file (.odin copy for odin check) to succeed")

	// Round-trip load from `.bodin`!
	loaded: engine.Visual_Graph
	defer engine.vg_destroy_graph(&loaded)
	testing.expect(t, engine.vg_load_from_file(&loaded, bodin_asset), "expected vg_load_from_file to parse `.bodin` layout block")
	testing.expect_value(t, loaded.name, "bodin_roundtrip_spec")
	testing.expect_value(t, len(loaded.variables), 1)
	testing.expect_value(t, len(loaded.nodes), 2)
	testing.expect_value(t, len(loaded.wires), 1)
	if ln := engine.vg_find_node(&loaded, u_code); ln != nil {
		testing.expect_value(t, ln.odin_body, comment_edge_body)
	} else {
		testing.expect(t, false, "expected Odin_Function_Node to survive .bodin round-trip")
	}

	// Verify the combined `.bodin` text passes ground-truth `odin check` with zero errors!
	odin_exe := "odin"
	root_cand, _ := filepath.join({ODIN_ROOT, ODIN_OS == .Windows ? "odin.exe" : "odin"}, context.temp_allocator)
	if os.exists(root_cand) do odin_exe = root_cand
	log_file, _ := filepath.join({tmp_dir, "bodin_check.log"}, context.temp_allocator)
	defer _ = os.remove(log_file)

	args := [6]string{
		odin_exe, "check", bodin_file,
		"-file", "-no-entry-point",
		fmt.tprintf("-collection:moonhug=%s/moonhug", repo_root),
	}
	// Need -ignore-unknown-attributes for @(hot_proc)
	args_full := [7]string{
		args[0], args[1], args[2], args[3], args[4], args[5], "-ignore-unknown-attributes",
	}
	bg, ok := engine.bg_process_start_to_file(repo_root, args_full[:], nil, log_file)
	testing.expect(t, ok, "expected bg_process_start_to_file to spawn odin check on .bodin content")
	if ok {
		done, code := false, -1
		t0 := time.tick_now()
		for !done {
			done, code = engine.bg_process_poll(&bg)
			if !done {
				if time.duration_seconds(time.tick_since(t0)) > 20.0 {
					engine.bg_process_kill(&bg)
					break
				}
				time.sleep(10 * time.Millisecond)
			}
		}
		if code != 0 {
			err_b, _ := os.read_entire_file(log_file, context.temp_allocator)
			testing.expectf(t, code == 0, "expected .bodin file content to be 100%% valid Odin code, got exit %d:\n%s", code, string(err_b))
		} else {
			testing.expect_value(t, code, 0)
		}
	}
}

// 7. Verifies Practical CSG Level-Building Ergonomics:
//    - Non-destructive brush join (`csg_merge_volumes_non_destructive` with `consume_tools = true`)
//    - Brush Stack ordering (`csg_volume_move_subtracts_to_end`, `csg_volume_duplicate_brush`)
//    - World-invariant `csg_volume_recenter_pivot` + `csg_volume_drop_to_ground`!
@(test)
test_csg_practical_ergonomics_merge_pivot_and_stack_order :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	w := engine.ctx_world()
	h_a := engine.transform_new("CSG_Wall_A")
	h_b := engine.transform_new("CSG_Pillar_B")
	engine.transform_set_local_position(h_a, {2.0, 3.0, -1.0})
	engine.transform_set_local_position(h_b, {6.0, 4.0, 1.0})

	_, ptr_a := engine.transform_add_comp(h_a, .CSGVolume)
	_, ptr_b := engine.transform_add_comp(h_b, .CSGVolume)
	vol_a := cast(^cad_csg.CSGVolume)ptr_a
	vol_b := cast(^cad_csg.CSGVolume)ptr_b
	vol_a.enabled = true
	vol_b.enabled = true

	// Add a Subtract brush BEFORE an Add brush in A, plus an Add brush in B
	_ = cad_csg.csg_volume_add_brush(vol_a, "Cut_Hole", .Subtract, .Box, {0.5, 0.0, 0.0}, {0.6, 1.2, 1.2})
	_ = cad_csg.csg_volume_add_brush(vol_a, "Wall_Main", .Add, .Box, {0.5, 0.0, 0.0}, {2.0, 2.0, 1.0})
	_ = cad_csg.csg_volume_add_brush(vol_b, "Pillar",    .Add, .Box, {0.0, 0.0, 0.0}, {1.0, 3.0, 1.0})
	cad_csg.csg_volume_rebuild(vol_a)
	cad_csg.csg_volume_rebuild(vol_b)

	// 1. Move '-' Subtract Cuts to End of Stack -> Subtract brush now sits at index 1 and carves Add brush 0!
	moved_cuts := cad_csg.csg_volume_move_subtracts_to_end(vol_a)
	testing.expect_value(t, moved_cuts, 1)
	testing.expect_value(t, vol_a.brushes[0].op, cad_csg.Brush_Op.Add)
	testing.expect_value(t, vol_a.brushes[1].op, cad_csg.Brush_Op.Subtract)

	// 2. Non-destructive Join of B into A with `consume_tools = true`
	tools := [1]engine.Transform_Handle{h_b}
	merged_ok := cad_csg.csg_merge_volumes_non_destructive(h_a, tools[:], false, true)
	testing.expect(t, merged_ok, "expected csg_merge_volumes_non_destructive to succeed")
	testing.expect_value(t, len(vol_a.brushes), 3)
	testing.expect(t, !engine.pool_valid(&w.transforms, engine.Handle(h_b)), "expected consumed Tool CSG B to be destroyed after merge")

	// Verify B's brush landed at `{6,4,1} - {2,3,-1} = {4, 1, 2}` in A's local space!
	diff_b := vol_a.brushes[2].center - [3]f32{4.0, 1.0, 2.0}
	testing.expect(t, math.abs(diff_b.x) < 0.001 && math.abs(diff_b.y) < 0.001 && math.abs(diff_b.z) < 0.001, "expected merged brush world-to-local offset {4, 1, 2}")

	// 3. World-Space Invariant Pivot Recentering!
	lo_b, hi_b, ok_b := cad_csg.csg_volume_local_aabb(vol_a)
	testing.expect(t, ok_b, "expected valid local AABB before recenter")
	tw_before := engine.transform_world(h_a)
	model_before := engine.trs_matrix(tw_before.position, tw_before.rotation, tw_before.scale)
	wmin_before := (model_before * [4]f32{lo_b.x, lo_b.y, lo_b.z, 1.0}).xyz
	wmax_before := (model_before * [4]f32{hi_b.x, hi_b.y, hi_b.z, 1.0}).xyz

	testing.expect(t, cad_csg.csg_volume_recenter_pivot(vol_a), "expected csg_volume_recenter_pivot to recenter off-origin CSG")

	lo_a, hi_a, ok_a := cad_csg.csg_volume_local_aabb(vol_a)
	testing.expect(t, ok_a, "expected valid local AABB after recenter")
	tw_after := engine.transform_world(h_a)
	model_after := engine.trs_matrix(tw_after.position, tw_after.rotation, tw_after.scale)
	wmin_after := (model_after * [4]f32{lo_a.x, lo_a.y, lo_a.z, 1.0}).xyz
	wmax_after := (model_after * [4]f32{hi_a.x, hi_a.y, hi_a.z, 1.0}).xyz
	testing.expect(t, math.abs(wmin_before.x - wmin_after.x) < 0.002 && math.abs(wmax_before.z - wmax_after.z) < 0.002, "expected world geometry AABB to stay fixed after pivot recentering")

	// 4. Drop Bottom to Ground (`Y = 0`)
	testing.expect(t, cad_csg.csg_volume_drop_to_ground(vol_a, 0.0), "expected csg_volume_drop_to_ground to snap bottom to Y=0")
	lo_g, _, _ := cad_csg.csg_volume_local_aabb(vol_a)
	tw_ground := engine.transform_world(h_a)
	model_ground := engine.trs_matrix(tw_ground.position, tw_ground.rotation, tw_ground.scale)
	wmin_ground := (model_ground * [4]f32{lo_g.x, lo_g.y, lo_g.z, 1.0}).y
	testing.expectf(t, math.abs(wmin_ground) < 0.002, "expected world bottom Y == 0.0 after drop_to_ground, got %.4f", wmin_ground)
}
