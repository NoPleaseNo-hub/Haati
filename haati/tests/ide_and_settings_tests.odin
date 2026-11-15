package tests

import "core:encoding/json"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import "../engine"
import cs "haati:editor/code_studio"
import fe "haati:editor/file_explorer"
import widgets "haati:editor/widgets"

@(test)
test_utf8_safe_prefix_preserves_multibyte_runes :: proc(t: ^testing.T) {
	sample := "📁✓—Hello 世界"
	testing.expect_value(t, widgets.utf8_safe_prefix(sample, -5), "")
	testing.expect_value(t, widgets.utf8_safe_prefix(sample, 0), "")
	for limit in 0 ..= len(sample) + 2 {
		pref := widgets.utf8_safe_prefix(sample, limit)
		testing.expect(t, len(pref) <= limit, "prefix must not exceed byte budget")
		testing.expect(t, utf8.valid_string(pref), "truncated prefix must remain valid UTF-8")
		testing.expect(t, strings.has_prefix(sample, pref), "prefix must be a true leading slice")
	}
}

@(test)
test_problem_check_delay_clamping_and_roundtrip :: proc(t: ^testing.T) {
	orig := cs.get_problem_check_delay_sec()
	defer cs.set_problem_check_delay_sec(orig)

	testing.expect(t, orig >= 0.15 && orig <= 5.0, "default delay should be within valid bounds")

	cs.set_problem_check_delay_sec(0.01)
	testing.expect(t, math.abs(cs.get_problem_check_delay_sec() - 0.15) < 0.002, "delay below min should clamp to 0.15s")

	cs.set_problem_check_delay_sec(99.0)
	testing.expect(t, math.abs(cs.get_problem_check_delay_sec() - 5.0) < 0.002, "delay above max should clamp to 5.0s")

	cs.set_problem_check_delay_sec(1.25)
	testing.expect(t, math.abs(cs.get_problem_check_delay_sec() - 1.25) < 0.002, "valid delay should round-trip accurately")
}

@(test)
test_script_jump_routing_and_two_root_source_resolution :: proc(t: ^testing.T) {
	k1, _ := fe.classify_script_jump_target("assets/scripts/hero.bodin", context.temp_allocator)
	testing.expect_value(t, k1, fe.Script_Jump_Target.Blueprint_Graph)

	k2, _ := fe.classify_script_jump_target("assets/scripts/hero.mhgraph", context.temp_allocator)
	testing.expect_value(t, k2, fe.Script_Jump_Target.Blueprint_Graph)

	k3, _ := fe.classify_script_jump_target("assets/hot_scripts/hero_mhgraph_generated.odin", context.temp_allocator)
	testing.expect_value(t, k3, fe.Script_Jump_Target.Blueprint_Graph)

	k4, _ := fe.classify_script_jump_target("haati/engine/project_settings.odin", context.temp_allocator)
	testing.expect_value(t, k4, fe.Script_Jump_Target.Odin_Code)

	res_haati, ok_haati := fe.resolve_source_file_path("haati/engine/project_settings.odin", context.temp_allocator)
	testing.expect(t, ok_haati && os.exists(res_haati), "should resolve haati engine source path")

	res_alias, ok_alias := fe.resolve_source_file_path("moonhug/engine/project_settings.odin", context.temp_allocator)
	testing.expect(t, ok_alias && os.exists(res_alias), "should resolve legacy moonhug/ source alias")
}

@(test)
test_unified_3_tier_settings_cascade :: proc(t: ^testing.T) {
	tmp_root := "haati/tests/_tmp_unified_settings_cascade"
	_ = os.remove_all(tmp_root)
	defer _ = os.remove_all(tmp_root)
	defer engine.project_settings_shutdown()

	eng_dir := strings.concatenate({tmp_root, "/engine_settings"}, context.temp_allocator)
	proj_a  := strings.concatenate({tmp_root, "/proj_a"}, context.temp_allocator)
	proj_b  := strings.concatenate({tmp_root, "/proj_b"}, context.temp_allocator)

	Cascade_Probe :: struct {
		speed:   f32,
		count:   int,
		enabled: bool,
	}
	tab_name :: "Cascade Test Tab"

	engine.project_settings_set_tiered_mode(true)
	engine.project_settings_set_dirs_for_test(eng_dir, proj_a)

	// Fresh load registers Tier 1 Factory Defaults Backdrop.
	va := Cascade_Probe{speed = 10.0, count = 3, enabled = true}
	testing.expect(t, !engine.project_settings_load(tab_name, &va), "missing files should preserve defaults")

	// Saving non-overridden field writes Tier 2 Engine Settings shared across projects.
	va.speed = 25.0
	testing.expect(t, engine.project_settings_save(tab_name, &va, typeid_of(Cascade_Probe)))
	testing.expect(t, !engine.project_settings_has_field_override(tab_name, "speed"))

	// Enabling [P] override on `count` stores only `count` in Project A's overrides.
	va.count = 99
	testing.expect(t, engine.project_settings_set_field_override(tab_name, "count", true, &va, typeid_of(Cascade_Probe)))
	testing.expect(t, engine.project_settings_has_field_override(tab_name, "count"))
	testing.expect_value(t, engine.project_settings_tab_override_count(tab_name), 1)

	cur_json, jerr := json.marshal(va, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, jerr == nil)
	testing.expect(t, engine.project_settings_is_field_modified_from_default(tab_name, "speed", cur_json))
	testing.expect(t, !engine.project_settings_is_field_modified_from_default(tab_name, "enabled", cur_json))

	// Switching to Project B inherits Engine Settings (`speed = 25.0`) without Project A's override (`count = 3`).
	engine.project_settings_shutdown()
	engine.project_settings_set_tiered_mode(true)
	engine.project_settings_set_dirs_for_test(eng_dir, proj_b)

	vb := Cascade_Probe{speed = 10.0, count = 3, enabled = true}
	testing.expect(t, engine.project_settings_load(tab_name, &vb), "Project B should load shared Engine Settings")
	testing.expect_value(t, vb.speed, f32(25.0))
	testing.expect_value(t, vb.count, 3)

	// Switching back to Project A restores both Engine Setting and Project Override.
	engine.project_settings_shutdown()
	engine.project_settings_set_tiered_mode(true)
	engine.project_settings_set_dirs_for_test(eng_dir, proj_a)

	va2 := Cascade_Probe{speed = 10.0, count = 3, enabled = true}
	testing.expect(t, engine.project_settings_load(tab_name, &va2), "Project A should restore Tier 2 + Tier 3")
	testing.expect_value(t, va2.speed, f32(25.0))
	testing.expect_value(t, va2.count, 99)

	// Disabling [P] override reverts `count` to Tier 2 Engine Default (3).
	testing.expect(t, engine.project_settings_set_field_override(tab_name, "count", false, &va2, typeid_of(Cascade_Probe)))
	testing.expect(t, !engine.project_settings_has_field_override(tab_name, "count"))
	testing.expect_value(t, va2.count, 3)

	// Resetting `speed` to default restores Tier 1 Factory Backdrop (10.0).
	testing.expect(t, engine.project_settings_reset_field_to_default(tab_name, "speed", &va2, typeid_of(Cascade_Probe)))
	testing.expect_value(t, va2.speed, f32(10.0))
}
