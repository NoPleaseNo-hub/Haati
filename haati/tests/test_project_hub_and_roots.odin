package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "../engine"

@(test)
test_project_hub_slug_and_validation :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.project_slug_from_name("Void Odin!", context.temp_allocator), "void_odin")
	testing.expect_value(t, engine.project_slug_from_name("99 Bottles", context.temp_allocator), "p_99_bottles")
	testing.expect_value(t, engine.project_slug_from_name("My-Space_Project 2", context.temp_allocator), "my_space_project_2")
	testing.expect_value(t, engine.project_slug_from_name("___", context.temp_allocator), "project")

	_, _, empty_ok := engine.project_validate_new_name("   ")
	testing.expect(t, !empty_ok, "blank name must be rejected")

	_, _, bad_char_ok := engine.project_validate_new_name("bad:name")
	testing.expect(t, !bad_char_ok, "colon must be rejected")

	_, _, reserved_ok := engine.project_validate_new_name("CON")
	testing.expect(t, !reserved_ok, "Windows reserved device name must be rejected")

	trimmed, err_msg, good_ok := engine.project_validate_new_name("  MyCoolGame  ")
	testing.expectf(t, good_ok, "expected valid trimmed project name, got error: %s", err_msg)
	testing.expect_value(t, trimmed, "MyCoolGame")
}

@(test)
test_project_hub_scaffold_and_launcher :: proc(t: ^testing.T) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_root, jerr := filepath.join({repo_root, "builds", fmt.tprintf("_hub_test_%d", os.get_pid())}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	_ = os.remove_all(tmp_root)
	testing.expect_value(t, os.make_directory_all(tmp_root), nil)
	defer {
		_ = os.remove_all(tmp_root)
	}

	created, err_msg, ok := engine.project_scaffold_new(tmp_root, "Star Forge", context.temp_allocator)
	testing.expectf(t, ok, "project_scaffold_new failed: %s", err_msg)
	if !ok do return

	manifest_p, _ := filepath.join({created, engine.PROJECT_MANIFEST_FILE}, context.temp_allocator)
	scene_p, _ := filepath.join({created, "assets", "scenes", "main.scene"}, context.temp_allocator)
	meta_p, _ := filepath.join({created, "assets", "scenes", "main.scene.meta"}, context.temp_allocator)
	ed_cfg_p, _ := filepath.join({created, "UserSettings", "editor_settings.json"}, context.temp_allocator)

	testing.expect(t, os.exists(manifest_p), "haati.project should be created")
	testing.expect(t, os.exists(scene_p), "starter main.scene should be created")
	testing.expect(t, os.exists(meta_p), "starter main.scene.meta should be created")
	testing.expect(t, os.exists(ed_cfg_p), "starter UserSettings/editor_settings.json should be created")
	testing.expect(t, engine.project_is_valid_dir(created), "scaffolded folder should validate as a project")
	testing.expect_value(t, engine.project_read_display_name(created, context.temp_allocator), "Star Forge")

	// Non-empty folder collision should fail cleanly
	_, dup_err, dup_ok := engine.project_scaffold_new(tmp_root, "Star Forge", context.temp_allocator)
	testing.expect(t, !dup_ok && dup_err != "", "non-empty target project folder must be rejected")

	created2, err2, ok2 := engine.project_scaffold_new(tmp_root, "SecondGame", context.temp_allocator)
	testing.expectf(t, ok2, "second project scaffold failed: %s", err2)

	launcher_json, _ := filepath.join({tmp_root, "launcher.json"}, context.temp_allocator)
	testing.expect(t, engine.launcher_record_open_project(created, "", launcher_json), "record project 1")
	testing.expect(t, engine.launcher_record_open_project(created2, "", launcher_json), "record project 2")
	testing.expect(t, engine.launcher_record_open_project(created, "", launcher_json), "re-record project 1 for MRU + dedup")

	cfg := engine.launcher_load_config(launcher_json)
	defer engine.launcher_free_config(&cfg)
	testing.expect_value(t, len(cfg.recent_projects), 2)
	testing.expect(t, engine.paths_equal(cfg.last_project_path, created), "last_project_path should match most recently opened project")
	if len(cfg.recent_projects) >= 2 {
		testing.expect(t, engine.paths_equal(cfg.recent_projects[0].path, created), "recent[0] should be MRU project")
		testing.expect(t, engine.paths_equal(cfg.recent_projects[1].path, created2), "recent[1] should be prior project")
	}

	testing.expect(t, engine.launcher_remove_recent_project(created, launcher_json), "remove recent project")
	cfg_after_rm := engine.launcher_load_config(launcher_json)
	defer engine.launcher_free_config(&cfg_after_rm)
	testing.expect_value(t, len(cfg_after_rm.recent_projects), 1)
	testing.expect_value(t, cfg_after_rm.last_project_path, "")

	testing.expect(t, engine.launcher_record_open_project(created, "", launcher_json), "re-add created for clear_last test")
	testing.expect(t, engine.launcher_clear_last_project(launcher_json), "clear last_project_path")
	cfg_after_clr := engine.launcher_load_config(launcher_json)
	defer engine.launcher_free_config(&cfg_after_clr)
	testing.expect_value(t, cfg_after_clr.last_project_path, "")
	testing.expect_value(t, len(cfg_after_clr.recent_projects), 2)
}

@(test)
test_project_hub_boot_resolve_roots :: proc(t: ^testing.T) {
	orig_cwd, cerr := os.get_working_directory(context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	defer {
		if orig_cwd != "" {
			_ = os.set_working_directory(orig_cwd)
		}
		engine.project_roots_shutdown()
	}

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_root, _ := filepath.join({repo_root, "builds", fmt.tprintf("_hub_boot_test_%d", os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(tmp_root)
	testing.expect_value(t, os.make_directory_all(tmp_root), nil)
	defer {
		_ = os.set_working_directory(orig_cwd)
		engine.project_roots_shutdown()
		_ = os.remove_all(tmp_root)
	}

	created, sc_err, sc_ok := engine.project_scaffold_new(tmp_root, "BootGame", context.temp_allocator)
	testing.expectf(t, sc_ok, "project_scaffold_new failed: %s", sc_err)
	launcher_json, _ := filepath.join({tmp_root, "launcher.json"}, context.temp_allocator)

	// 1. Unset last project -> Startup Project Hub
	p1, hub1 := engine.editor_boot_resolve_roots({"Haati.exe"}, launcher_json)
	testing.expect(t, hub1 && engine.is_project_hub_startup(), "unset launcher.json should enter Project Hub startup mode")
	testing.expect_value(t, p1, "")
	testing.expect(t, !engine.has_active_project(), "hub startup should have no active project")

	// 2. Recorded valid last_project_path -> auto-opens project
	testing.expect(t, engine.launcher_record_open_project(created, "", launcher_json), "record BootGame")
	p2, hub2 := engine.editor_boot_resolve_roots({"Haati.exe"}, launcher_json)
	testing.expect(t, !hub2 && !engine.is_project_hub_startup(), "valid last_project_path should open directly")
	testing.expect(t, engine.has_active_project(), "active project should be set")
	testing.expect(t, engine.paths_equal(p2, created), "active_proj should match BootGame")
	testing.expect_value(t, engine.active_project_name(), "BootGame")
	testing.expect_value(t, engine.active_project_slug(context.temp_allocator), "bootgame")

	// 3. Explicit --project-hub overrides last_project_path
	p3, hub3 := engine.editor_boot_resolve_roots({"Haati.exe", "--project-hub"}, launcher_json)
	testing.expect(t, hub3 && engine.is_project_hub_startup(), "--project-hub should force Hub mode")
	testing.expect_value(t, p3, "")

	// 4. --project=<dir> overrides unset launcher.json
	empty_launcher, _ := filepath.join({tmp_root, "empty_launcher.json"}, context.temp_allocator)
	proj_flag := fmt.tprintf("--project=%s", created)
	p4, hub4 := engine.editor_boot_resolve_roots({"Haati.exe", proj_flag}, empty_launcher)
	testing.expect(t, !hub4 && engine.paths_equal(p4, created), "--project= should override empty launcher.json")

	// 5. Missing/deleted last_project_path -> falls back cleanly to Hub without panicking
	missing_dir, _ := filepath.join({tmp_root, "MissingDeletedProject"}, context.temp_allocator)
	missing_launcher, _ := filepath.join({tmp_root, "missing_launcher.json"}, context.temp_allocator)
	_ = engine.launcher_record_open_project(missing_dir, "MissingDeletedProject", missing_launcher)
	p5, hub5 := engine.editor_boot_resolve_roots({"Haati.exe"}, missing_launcher)
	testing.expect(t, hub5 && p5 == "" && engine.is_project_hub_startup(), "deleted last project must fall back cleanly to Hub")
}
