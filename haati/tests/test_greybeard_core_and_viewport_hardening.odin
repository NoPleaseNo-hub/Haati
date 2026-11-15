package tests

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import "../engine"
import catalog "../engine/catalog"
import core "../engine/core"
import cs "haati:editor/code_studio"
import wnd "haati:editor/window"

@(test)
test_code_studio_hard_tabs_and_raw_strings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		tab_src := "package foo\n\nmain :: proc() {\n\treturn\n}\n"
		space_src := "package foo\n\nmain :: proc() {\n    return\n}\n"
		testing.expect(t, cs.detect_odin_hard_tabs(tab_src), "expected tab-indented Odin source to detect hard tabs")
		testing.expect(t, !cs.detect_odin_hard_tabs(space_src), "expected space-indented Odin source not to report hard tabs")

		edited_buf := "package foo\n\nmain :: proc() {\n    x := 1\n    raw := `\n        keep four spaces\n    `\n    /*\n        keep comment spaces\n    */\n        y := x + 1\n}\n"
		expected := "package foo\n\nmain :: proc() {\n\tx := 1\n\traw := `\n        keep four spaces\n    `\n\t/*\n        keep comment spaces\n    */\n\t\ty := x + 1\n}\n"

		formatted := cs.format_studio_buffer_for_disk(edited_buf, true, context.allocator)
		defer delete(formatted)
		testing.expectf(t, formatted == expected, "expected hard-tab formatting to preserve raw string & block comment spaces\ngot:\n%s\nwant:\n%s", formatted, expected)

		noop := cs.format_studio_buffer_for_disk(edited_buf, false, context.allocator)
		testing.expect(t, noop == edited_buf, "expected uses_tabs=false to keep edited buffer unchanged without allocation")
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaks in code_studio test, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in code_studio test, got %d", len(track.bad_free_array))
}

@(test)
test_viewport_anti_narnia_monitor_clamping :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		mons := [?]wnd.Monitor_Work_Rect{
			{main_pos = {0, 0}, main_size = {1920, 1080}, work_pos = {0, 0}, work_size = {1920, 1040}},
			{main_pos = {-1920, 0}, main_size = {1920, 1080}, work_pos = {-1920, 0}, work_size = {1920, 1040}},
		}

		wp, ws := wnd.resolve_monitor_work_rect({-900, 400}, mons[:], {0, 0}, {1920, 1040})
		testing.expectf(t, wp.x == -1920 && wp.y == 0 && ws.x == 1920 && ws.y == 1040, "expected secondary left monitor work rect, got pos=%v size=%v", wp, ws)

		rescued_pos, _ := wnd.clamp_floating_rect_to_monitors({-5000, -400}, {800, 600}, mons[:], {0, 0}, {1920, 1040})
		testing.expectf(t, rescued_pos.y >= 0 && rescued_pos.y <= 1040 - 28.0, "expected off-screen top Y to clamp inside work area, got %v", rescued_pos.y)
		testing.expectf(t, rescued_pos.x >= -1920.0 - 800.0 + 96.0, "expected off-screen left X to keep >= 96px visible on secondary monitor, got %v", rescued_pos.x)

		rescued_br, _ := wnd.clamp_floating_rect_to_monitors({4000, 3000}, {800, 600}, mons[:], {0, 0}, {1920, 1040})
		testing.expectf(t, rescued_br.x <= 1920.0 - 96.0 && rescued_br.y <= 1040.0 - 28.0, "expected far-right/bottom window to clamp back onto primary monitor, got %v", rescued_br)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaks in viewport test, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in viewport test, got %d", len(track.bad_free_array))
}

@(test)
test_core_pool_paged_overflow_pointer_stability :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		N_ITEMS :: 2500
		p: core.Pool(u64, 8)
		core.pool_init(&p)
		defer core.pool_free(&p)

		handles := make([]core.Handle, N_ITEMS)
		defer delete(handles)
		ptrs := make([]^u64, N_ITEMS)
		defer delete(ptrs)

		for i in 0 ..< N_ITEMS {
			h, ptr := core.pool_create(&p)
			testing.expect(t, ptr != nil, "expected pool_create to return non-nil pointer")
			ptr^ = u64(i * 1337 + 7)
			handles[i] = h
			ptrs[i] = ptr
		}
		testing.expectf(t, p.count == N_ITEMS, "expected count=%d, got %d", N_ITEMS, p.count)

		// All earlier inline and page pointers must stay address-stable after later page allocations.
		for i in 0 ..< N_ITEMS {
			cur := core.pool_get(&p, handles[i])
			testing.expect(t, cur == ptrs[i], "expected pool slot pointer never to move across overflow page growth")
			testing.expectf(t, cur^ == u64(i * 1337 + 7), "expected sentinel preserved at slot %d", i)
		}

		// Destroy inline + overflow slots and verify generational invalidation + reuse.
		for i in 0 ..< 1000 {
			core.pool_destroy(&p, handles[i])
			testing.expect(t, !core.pool_valid(&p, handles[i]), "destroyed handle must immediately become invalid")
			testing.expect(t, core.pool_get(&p, handles[i]) == nil, "pool_get on destroyed handle must return nil")
		}
		testing.expectf(t, p.count == N_ITEMS - 1000, "expected count=%d after destroys, got %d", N_ITEMS - 1000, p.count)

		for i in 0 ..< 1000 {
			nh, nptr := core.pool_create(&p)
			nptr^ = u64(90000 + i)
			testing.expect(t, core.pool_valid(&p, nh), "reused handle must be valid")
			testing.expect(t, !core.pool_valid(&p, handles[i]), "stale prior-generation handle must remain invalid after slot reuse")
		}
		testing.expectf(t, p.count == N_ITEMS, "expected count=%d after refills, got %d", N_ITEMS, p.count)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaks in pool test, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in pool test, got %d", len(track.bad_free_array))
}

@(test)
test_visual_script_escaped_overrides_and_scene_epsilon :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		val1 :: "a=1;b=2\\c"
		key2 :: "k;2=x"
		val2 :: "val=9;ok\\end"

		ov1 := engine.vg_set_instance_override_value("", "msg", val1)
		defer delete(ov1)
		ov2 := engine.vg_set_instance_override_value(ov1, key2, val2)
		defer delete(ov2)

		got1, ok1 := engine.vg_get_instance_override_value(ov2, "msg", context.allocator)
		defer if ok1 do delete(got1)
		got2, ok2 := engine.vg_get_instance_override_value(ov2, key2, context.allocator)
		defer if ok2 do delete(got2)

		testing.expect(t, ok1 && got1 == val1, "expected escaped value with ';', '=', '\\' to round-trip")
		testing.expect(t, ok2 && got2 == val2, "expected escaped key+value with ';', '=', '\\' to round-trip")

		g: engine.Visual_Graph
		append(&g.variables, engine.VG_Var_Decl{name = "msg", pin_type = .String})
		defer delete(g.variables)
		bb: engine.VG_Runtime_Blackboard
		engine.vg_apply_instance_overrides(&g, &bb, ov2)
		applied := bb.slots[0].val_cstr != nil ? string(bb.slots[0].val_cstr) : ""
		testing.expectf(t, applied == val1, "expected blackboard String slot to receive unescaped '%s', got '%s'", val1, applied)

		base_json := `{"transforms":[{"local_id":101,"pos_x":1.0,"pos_y":2.0}]}`
		work_json := `{"transforms":[{"local_id":101,"pos_x":1.0000004,"pos_y":2.5}]}`
		ovs := engine.nested_scene_diff_overrides(transmute([]u8)base_json, transmute([]u8)work_json)
		defer {
			for &o in ovs {
				delete(o.property_path)
				json.destroy_value(o.value)
			}
			delete(ovs)
		}
		testing.expectf(t, len(ovs) == 1, "expected pos_x float drift <= 1e-6 to be ignored leaving 1 override, got %d", len(ovs))
		if len(ovs) == 1 {
			testing.expectf(t, ovs[0].property_path == "pos_y", "expected pos_y override, got %s", ovs[0].property_path)
		}
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaks in visual_script/nested_scene test, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in visual_script/nested_scene test, got %d", len(track.bad_free_array))
}

@(test)
test_streaming_pak_roundtrip_and_corrupt_rejection :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	tmp_root, _ := filepath.join({repo_root, "builds", fmt.tprintf("_tmp_greybeard_pak_%d", os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(tmp_root)
	defer _ = os.remove_all(tmp_root)

	{
		src_dir := fmt.tprintf("%s/src", tmp_root)
		sub_dir := fmt.tprintf("%s/sub", src_dir)
		ext_dir := fmt.tprintf("%s/ext", tmp_root)
		pak_path := fmt.tprintf("%s/archive.pak", tmp_root)
		bad_pak_path := fmt.tprintf("%s/corrupt.pak", tmp_root)

		testing.expect(t, os.make_directory_all(sub_dir) == nil, "mkdir src/sub")

		BIG_SIZE :: 600 * 1024
		big_data := make([]u8, BIG_SIZE)
		defer delete(big_data)
		for i in 0 ..< BIG_SIZE {
			big_data[i] = u8((i * 131 + 17) & 0xFF)
		}
		nested_txt :: "nested_streaming_payload_v1"

		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/big.bin", src_dir), big_data) == nil, "write >600KB test payload")
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/nested.txt", sub_dir), transmute([]u8)string(nested_txt)) == nil, "write nested text")
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/empty.bin", src_dir), nil) == nil, "write 0-byte entry")

		cnt, pok := catalog.pak_pack_directory(src_dir, pak_path)
		testing.expectf(t, pok && cnt == 3, "expected 3 packed entries, got ok=%v cnt=%d", pok, cnt)

		ar, o_ok := catalog.pak_open(pak_path)
		testing.expect(t, o_ok && ar.file != nil, "expected seek-based pak_open to succeed with live file handle")
		{
			defer catalog.pak_close(&ar)

			got_big, b_ok := catalog.pak_read_entry(&ar, "big.bin", context.allocator)
			testing.expect(t, b_ok && slice.equal(got_big, big_data), "expected >600KB streamed payload exact match")
			if b_ok do delete(got_big)

			got_nested, n_ok := catalog.pak_read_entry(&ar, "sub/nested.txt", context.allocator)
			testing.expect(t, n_ok && string(got_nested) == nested_txt, "expected nested entry match")
			if n_ok do delete(got_nested)

			got_empty, e_ok := catalog.pak_read_entry(&ar, "empty.bin", context.allocator)
			testing.expect(t, e_ok && len(got_empty) == 0, "expected 0-byte entry match")
			if e_ok do delete(got_empty)
		}

		testing.expect(t, catalog.pak_extract_directory(pak_path, ext_dir), "expected pak_extract_directory to succeed")
		ext_big, rerr := os.read_entire_file(fmt.tprintf("%s/big.bin", ext_dir), context.allocator)
		testing.expect(t, rerr == nil && slice.equal(ext_big, big_data), "expected extracted big.bin exact match")
		if rerr == nil do delete(ext_big)

		// Corrupt 1 payload byte after header: TOC open succeeds, payload checksum fails with 0 leaks.
		raw_pak, perr := os.read_entire_file(pak_path, context.allocator)
		testing.expect(t, perr == nil && len(raw_pak) > 64, "read packed pak for corruption test")
		if perr == nil {
			defer delete(raw_pak)
			raw_pak[32] ~= 0xFF
			testing.expect(t, os.write_entire_file(bad_pak_path, raw_pak) == nil, "write tampered pak")

			bad_ar, bad_open := catalog.pak_open(bad_pak_path)
			testing.expect(t, bad_open, "expected TOC-only pak_open to accept untouched TOC")
			if bad_open {
				defer catalog.pak_close(&bad_ar)
				bad_bytes, bad_read := catalog.pak_read_entry(&bad_ar, "big.bin", context.allocator)
				if bad_read do delete(bad_bytes)
				testing.expect(t, !bad_read, "expected pak_read_entry to reject tampered payload checksum")
			}
		}
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaks in streaming pak test, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in streaming pak test, got %d", len(track.bad_free_array))
}

@(test)
test_binary_savegame_hsvg_roundtrip_and_tamper_detection :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	repo_root := engine.resolve_repo_root(context.temp_allocator)
	save_dir, _ := filepath.join({repo_root, "builds", fmt.tprintf("_tmp_greybeard_save_%d", os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(save_dir)
	defer _ = os.remove_all(save_dir)

	{
		save_path := fmt.tprintf("%s/slot0.hsvg", save_dir)
		defer _ = os.remove(save_path)

		sg := engine.savegame_init()
		defer engine.savegame_destroy(&sg)

		testing.expect(t, engine.savegame_set_i64(&sg, "score", -900123456789), "set i64")
		testing.expect(t, engine.savegame_set_f32(&sg, "hp", 3.14159), "set f32")
		testing.expect(t, engine.savegame_set_f64(&sg, "world_time", -271828.1828459), "set f64")
		testing.expect(t, engine.savegame_set_bool(&sg, "cleared", true), "set bool")
		testing.expect(t, engine.savegame_set_string(&sg, "profile", "temp_initial"), "set initial string")
		testing.expect(t, engine.savegame_set_string(&sg, "profile", "Hero;Slot=1\\Save"), "overwrite string without leak")
		testing.expect(t, engine.savegame_set_vec3(&sg, "pos", {12.5, -4.25, 99.0}), "set vec3")
		testing.expect(t, engine.savegame_set_quat(&sg, "rot", {0.0, 0.70710677, 0.0, 0.70710677}), "set quat")
		raw_init := [?]u8{0x01, 0x02}
		raw_final := [?]u8{0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42}
		testing.expect(t, engine.savegame_set_bytes(&sg, "fog_mask", raw_init[:]), "set initial bytes")
		testing.expect(t, engine.savegame_set_bytes(&sg, "fog_mask", raw_final[:]), "overwrite bytes without leak")

		// Write twice atomically to exercise Windows replace-rename over existing destination.
		testing.expect(t, engine.savegame_write_atomic(save_path, &sg), "first savegame_write_atomic")
		testing.expect(t, engine.savegame_write_atomic(save_path, &sg), "second savegame_write_atomic overwrite")

		loaded, lok := engine.savegame_read_file(save_path)
		testing.expect(t, lok, "savegame_read_file must succeed")
		if lok {
			defer engine.savegame_destroy(&loaded)

			iv, iok := engine.savegame_get_i64(&loaded, "score")
			f32v, f32ok := engine.savegame_get_f32(&loaded, "hp")
			f64v, f64ok := engine.savegame_get_f64(&loaded, "world_time")
			bv, bok := engine.savegame_get_bool(&loaded, "cleared")
			sv, sok := engine.savegame_get_string(&loaded, "profile")
			v3, v3ok := engine.savegame_get_vec3(&loaded, "pos")
			qv, qok := engine.savegame_get_quat(&loaded, "rot")
			byv, byok := engine.savegame_get_bytes(&loaded, "fog_mask")

			testing.expect(t, iok && iv == -900123456789, "roundtrip i64")
			testing.expect(t, f32ok && f32v == 3.14159, "roundtrip f32")
			testing.expect(t, f64ok && f64v == -271828.1828459, "roundtrip f64")
			testing.expect(t, bok && bv == true, "roundtrip bool")
			testing.expect(t, sok && sv == "Hero;Slot=1\\Save", "roundtrip string")
			testing.expect(t, v3ok && v3 == [3]f32{12.5, -4.25, 99.0}, "roundtrip vec3")
			testing.expect(t, qok && qv == [4]f32{0.0, 0.70710677, 0.0, 0.70710677}, "roundtrip quat")
			testing.expect(t, byok && slice.equal(byv, raw_final[:]), "roundtrip bytes")
		}

		// Tamper detection + truncation rejection must return ok=false with 0 leaks.
		encoded, eok := engine.savegame_encode(&sg)
		testing.expect(t, eok && len(encoded) > engine.SAVEGAME_HEADER_SIZE, "encode savegame")
		if eok {
			defer delete(encoded)

			trunc1, t1_ok := engine.savegame_decode(encoded[:16])
			if t1_ok do engine.savegame_destroy(&trunc1)
			testing.expect(t, !t1_ok, "expected truncated header to be rejected")

			trunc2, t2_ok := engine.savegame_decode(encoded[:len(encoded)-1])
			if t2_ok do engine.savegame_destroy(&trunc2)
			testing.expect(t, !t2_ok, "expected truncated payload to be rejected")

			encoded[len(encoded)-1] ~= 0x01
			corrupt, c_ok := engine.savegame_decode(encoded)
			if c_ok do engine.savegame_destroy(&corrupt)
			testing.expect(t, !c_ok, "expected flipped payload byte to fail FNV-1a verification")
		}
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaks in savegame test, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in savegame test, got %d", len(track.bad_free_array))
}
