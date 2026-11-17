package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import stbi "vendor:stb/image"
import "../engine"
import widgets "haati:editor/widgets"

// Out-of-process Watchdog 16 MB Kernel RAM Vault write + read_and_consume roundtrip on Windows.
@(test)
test_watchdog_kernel_ram_vault_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	when ODIN_OS == .Windows {
		vault_name := fmt.tprintf("Local\\Haati_WD_UnitTest_%d", os.get_pid())
		vh, vok := engine.watchdog_vault_create(vault_name)
		testing.expect(t, vok && vh != nil, "watchdog_vault_create must create Windows pagefile section")
		if !vok || vh == nil do return
		defer engine.watchdog_vault_close(vh)

		scene_str := "{\"root\":1,\"entities\":4}"
		tabs_str  := "[{\"path\":\"hot_scripts/player.odin\",\"text\":\"package hot_scripts\"}]"
		lids      := [?]u64{101, 202}
		snap := engine.Relaunch_SHM_Snapshot{
			has_scene_bytes = true,
			cam_pos         = {12.5, 4.0, -8.5},
			cam_yaw         = 0.75,
			cam_pitch       = -0.25,
			cam_dist        = 15.0,
			cam_target      = {1, 2, 3},
			cam_ortho       = false,
			cam_2d_mode     = true,
			selected_lids   = lids[:],
			scene_path      = "assets/scenes/arena.scene",
			scene_bytes     = transmute([]byte)scene_str,
		}

		testing.expect(t, engine.watchdog_vault_write(vh, snap, transmute([]byte)tabs_str), "watchdog_vault_write must succeed")

		rsnap, rtabs, rok := engine.watchdog_vault_read_and_consume(vault_name, context.temp_allocator)
		testing.expect(t, rok, "watchdog_vault_read_and_consume must restore staged snapshot")
		testing.expect(t, rsnap.has_scene_bytes && rsnap.cam_2d_mode, "camera and scene flags must roundtrip through Kernel RAM Vault")
		testing.expect(t, rsnap.cam_pos == snap.cam_pos, "cam_pos must roundtrip accurately")
		testing.expect_value(t, len(rsnap.selected_lids), 2)
		testing.expect_value(t, rsnap.selected_lids[1], u64(202))
		testing.expect_value(t, rsnap.scene_path, "assets/scenes/arena.scene")
		testing.expect_value(t, string(rsnap.scene_bytes), scene_str)
		testing.expect_value(t, string(rtabs), tabs_str)
	}
}

// 3-Zone Watchdog Vault independent zone writes preserve untouched zones.
@(test)
test_watchdog_vault_3zone_independent_updates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	when ODIN_OS == .Windows {
		vault_name := fmt.tprintf("Local\\Haati_WD_3ZoneTest_%d", os.get_pid())
		vh, vok := engine.watchdog_vault_create(vault_name)
		testing.expect(t, vok && vh != nil, "watchdog_vault_create must succeed")
		if !vok || vh == nil do return
		defer engine.watchdog_vault_close(vh)

		scene_str := "{\"scene\":1}"
		tabs_v1   := "[{\"abs_path\":\"a.odin\",\"content\":\"v1\"}]"
		tabs_v2   := "[{\"abs_path\":\"a.odin\",\"content\":\"v2\"}]"

		m1 := engine.Relaunch_SHM_Snapshot{
			cam_pos    = {1, 2, 3},
			cam_yaw    = 1.0,
			scene_path = "assets/s1.scene",
		}
		testing.expect(t, engine.watchdog_vault_write_meta(vh, m1), "initial Zone 0 meta write must succeed")
		testing.expect(t, engine.watchdog_vault_write_tabs(vh, transmute([]byte)tabs_v1), "initial Zone 1 tabs write must succeed")
		testing.expect(t, engine.watchdog_vault_write_scene(vh, true, transmute([]byte)scene_str), "initial Zone 2 scene write must succeed")

		// Update ONLY Zone 0 and Zone 1 without re-writing Zone 2
		m2 := m1
		m2.cam_yaw = 2.5
		testing.expect(t, engine.watchdog_vault_write_meta(vh, m2), "updated Zone 0 meta write must succeed")
		testing.expect(t, engine.watchdog_vault_write_tabs(vh, transmute([]byte)tabs_v2), "updated Zone 1 tabs write must succeed")

		rsnap, rtabs, rok := engine.watchdog_vault_read_and_consume(vault_name, context.temp_allocator)
		testing.expect(t, rok, "watchdog_vault_read_and_consume must read updated 3-zone vault")
		testing.expect_value(t, rsnap.cam_yaw, f32(2.5))
		testing.expect_value(t, string(rtabs), tabs_v2)
		testing.expect(t, rsnap.has_scene_bytes, "Zone 2 has_scene_bytes must remain intact across Zone 0/1 writes")
		testing.expect_value(t, string(rsnap.scene_bytes), scene_str)
	}
}

// Embedded Watch-Wolf mascot asset decodes as a valid 96x96 PNG.
@(test)
test_watch_wolf_png_asset_embedded_valid :: proc(t: ^testing.T) {
	png := widgets.watch_wolf_png_bytes()
	testing.expect(t, len(png) > 64, "watch_wolf_96.png bytes must be embedded non-empty")
	if len(png) < 8 do return
	sig := [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}
	testing.expect(t, mem.compare(png[:8], sig[:]) == 0, "embedded asset must start with valid PNG header")

	w, h, comp: i32
	ok := bool(stbi.info_from_memory(raw_data(png), i32(len(png)), &w, &h, &comp))
	testing.expect(t, ok, "stbi.info_from_memory must parse embedded Watch-Wolf PNG")
	testing.expect_value(t, w, 96)
	testing.expect_value(t, h, 96)
}
