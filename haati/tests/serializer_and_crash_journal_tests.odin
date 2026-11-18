package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"
import "../editor"
import "../engine"
import catalog "../engine/catalog"
import crash_journal "../engine/crash_journal"
import clip "haati:editor/clipboard"
import cs "haati:editor/code_studio"
import wnd "haati:editor/window"

@(private = "file")
_append_u16le :: proc(buf: ^[dynamic]u8, val: u16) {
	v := u16le(val)
	append(buf, ..(cast([^]u8)&v)[:size_of(v)])
}

@(private = "file")
_append_u32le :: proc(buf: ^[dynamic]u8, val: u32) {
	v := u32le(val)
	append(buf, ..(cast([^]u8)&v)[:size_of(v)])
}

@(private = "file")
_append_u64le :: proc(buf: ^[dynamic]u8, val: u64) {
	v := u64le(val)
	append(buf, ..(cast([^]u8)&v)[:size_of(v)])
}

@(private = "file")
_append_pak_toc_entry :: proc(buf: ^[dynamic]u8, path: string, offset, size, hash: u64) {
	_append_u16le(buf, u16(len(path)))
	append(buf, ..transmute([]u8)path)
	_append_u64le(buf, offset)
	_append_u64le(buf, size)
	_append_u64le(buf, hash)
}

@(private = "file")
_write_pak_header :: proc(buf: ^[dynamic]u8, entry_count: u32, toc_offset: u64) {
	append(buf, ..transmute([]u8)string(catalog.PAK_MAGIC))
	_append_u32le(buf, catalog.PAK_VERSION)
	_append_u32le(buf, entry_count)
	_append_u64le(buf, toc_offset)
}

@(private = "file")
_free_parsed_shader_meta :: proc(props: []engine.Shader_Property, texs: []engine.Shader_Texture, allocator := context.allocator) {
	for p in props do delete(p.name, allocator)
	delete(props, allocator)
	for tx in texs do delete(tx.name, allocator)
	delete(texs, allocator)
}

@(test)
test_corrupt_shader_and_pak_deserializers_no_oom_or_leak :: proc(t: ^testing.T) {
	_ = os.make_directory_all("haati/tests/fixtures")
	pid := os.get_pid()
	pak_bad_cnt := fmt.tprintf("haati/tests/fixtures/_tmp_bad_cnt_%d.pak", pid)
	pak_bad_off := fmt.tprintf("haati/tests/fixtures/_tmp_bad_off_%d.pak", pid)
	pak_dup_toc := fmt.tprintf("haati/tests/fixtures/_tmp_dup_toc_%d.pak", pid)
	defer _ = os.remove(pak_bad_cnt)
	defer _ = os.remove(pak_bad_off)
	defer _ = os.remove(pak_dup_toc)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	prev_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = prev_alloc

	{
		// 1. Corrupt shader: 0xFFFFFFFF property_count on header-only blob.
		blob1 := make([dynamic]u8)
		defer delete(blob1)
		hdr1 := engine.Shader_Artifact_Header{
			property_count = 0xFFFFFFFF,
		}
		copy(hdr1.magic[:], engine.SHADER_ARTIFACT_MAGIC)
		append(&blob1, ..(cast([^]u8)&hdr1)[:size_of(engine.Shader_Artifact_Header)])

		_, _, _, props1, texs1, ok1 := engine._shader_artifact_parse(blob1[:])
		if ok1 do _free_parsed_shader_meta(props1, texs1)
		testing.expect(t, !ok1, "expected 0xFFFFFFFF property_count shader blob to fail cleanly")

		// 2. Corrupt shader: 1st property valid (allocates cloned name), 2nd property truncated name_len.
		blob2 := make([dynamic]u8)
		defer delete(blob2)
		hdr2 := engine.Shader_Artifact_Header{
			property_count = 2,
		}
		copy(hdr2.magic[:], engine.SHADER_ARTIFACT_MAGIC)
		append(&blob2, ..(cast([^]u8)&hdr2)[:size_of(engine.Shader_Artifact_Header)])
		_append_u32le(&blob2, 0)
		_append_u32le(&blob2, 16)
		_append_u32le(&blob2, 4)
		append(&blob2, ..transmute([]u8)string("tint"))
		_append_u32le(&blob2, 16)
		_append_u32le(&blob2, 16)
		_append_u32le(&blob2, 64)
		append(&blob2, ..transmute([]u8)string("ab"))

		_, _, _, props2, texs2, ok2 := engine._shader_artifact_parse(blob2[:])
		if ok2 do _free_parsed_shader_meta(props2, texs2)
		testing.expect(t, !ok2, "expected truncated 2nd property name_len shader blob to fail without leaking 1st property")

		// 3. Corrupt shader: 1 valid property followed by 0xFFFFFFFF texture_count.
		blob3 := make([dynamic]u8)
		defer delete(blob3)
		hdr3 := engine.Shader_Artifact_Header{
			property_count = 1,
			texture_count  = 0xFFFFFFFF,
		}
		copy(hdr3.magic[:], engine.SHADER_ARTIFACT_MAGIC)
		append(&blob3, ..(cast([^]u8)&hdr3)[:size_of(engine.Shader_Artifact_Header)])
		_append_u32le(&blob3, 0)
		_append_u32le(&blob3, 16)
		_append_u32le(&blob3, 5)
		append(&blob3, ..transmute([]u8)string("color"))

		_, _, _, props3, texs3, ok3 := engine._shader_artifact_parse(blob3[:])
		if ok3 do _free_parsed_shader_meta(props3, texs3)
		testing.expect(t, !ok3, "expected 0xFFFFFFFF texture_count shader blob to fail without leaking properties")

		// 4. Corrupt .pak: 0xFFFFFFFF entry_count.
		pak1 := make([dynamic]u8)
		defer delete(pak1)
		_write_pak_header(&pak1, 0xFFFFFFFF, 24)
		testing.expect(t, os.write_entire_file(pak_bad_cnt, pak1[:]) == nil, "write corrupt entry_count pak")
		ar1, pok1 := catalog.pak_open(pak_bad_cnt)
		if pok1 do catalog.pak_close(&ar1)
		testing.expect(t, !pok1, "expected 0xFFFFFFFF entry_count .pak to fail cleanly")

		// 5. Corrupt .pak: u64 overflow in entry offset + size (0xFFFFFFFF_FFFFFFF0 + 32).
		pak2 := make([dynamic]u8)
		defer delete(pak2)
		_write_pak_header(&pak2, 1, 24)
		_append_pak_toc_entry(&pak2, "a.bin", 0xFFFFFFFF_FFFFFFF0, 32, 0)
		testing.expect(t, os.write_entire_file(pak_bad_off, pak2[:]) == nil, "write corrupt offset overflow pak")
		ar2, pok2 := catalog.pak_open(pak_bad_off)
		if pok2 do catalog.pak_close(&ar2)
		testing.expect(t, !pok2, "expected 0xFFFFFFFF_FFFFFFF0 offset overflow .pak to fail cleanly")

		// 6. Corrupt .pak: duplicate TOC path.
		pak3 := make([dynamic]u8)
		defer delete(pak3)
		payload := string("ABCD")
		toc_off := u64(24 + len(payload))
		_write_pak_header(&pak3, 2, toc_off)
		append(&pak3, ..transmute([]u8)payload)
		_append_pak_toc_entry(&pak3, "dup/a.bin", 24, u64(len(payload)), 0)
		_append_pak_toc_entry(&pak3, "dup/a.bin", 24, u64(len(payload)), 0)
		testing.expect(t, os.write_entire_file(pak_dup_toc, pak3[:]) == nil, "write duplicate TOC path pak")
		ar3, pok3 := catalog.pak_open(pak_dup_toc)
		if pok3 do catalog.pak_close(&ar3)
		testing.expect(t, !pok3, "expected duplicate TOC path .pak to fail cleanly")
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaked allocations across corrupt deserializers, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees across corrupt deserializers, got %d", len(track.bad_free_array))
}

@(test)
test_window_rect_multimonitor_and_minimized_bounds :: proc(t: ^testing.T) {
	displays := [?]sdl.Rect{
		{x = 0, y = 0, w = 1920, h = 1080},
		{x = -1920, y = 0, w = 1920, h = 1080},
	}

	// Visible on negative-X secondary monitor.
	testing.expect(t, editor.window_rect_visible_in_bounds(-1600, 100, 1280, 720, displays[:]), "window on negative-X monitor should be visible")
	// Sentinel NO_SAVED_WINDOW_POS / minimized Windows position (-32000).
	testing.expect(t, !editor.window_rect_visible_in_bounds(editor.NO_SAVED_WINDOW_POS, 100, 1280, 720, displays[:]), "NO_SAVED_WINDOW_POS X should be rejected")
	testing.expect(t, !editor.window_rect_visible_in_bounds(100, editor.NO_SAVED_WINDOW_POS, 1280, 720, displays[:]), "NO_SAVED_WINDOW_POS Y should be rejected")
	// Completely off-screen.
	testing.expect(t, !editor.window_rect_visible_in_bounds(2500, 100, 1280, 720, displays[:]), "off-screen window should be rejected")
	// Overlap < 64px vs exact >= 64px boundary.
	testing.expect(t, !editor.window_rect_visible_in_bounds(1860, 100, 1280, 720, displays[:]), "60px overlap (< 64px) should be rejected")
	testing.expect(t, editor.window_rect_visible_in_bounds(1856, 100, 1280, 720, displays[:]), "64px overlap (>= 64px) should be accepted")
	// Degenerate < 100px window size.
	testing.expect(t, !editor.window_rect_visible_in_bounds(100, 100, 80, 720, displays[:]), "width < 100px should be rejected")
	testing.expect(t, !editor.window_rect_visible_in_bounds(100, 100, 720, 90, displays[:]), "height < 100px should be rejected")
}

@(test)
test_bg_process_isolated_handles_and_share_delete :: proc(t: ^testing.T) {
	repo_root := engine.resolve_repo_root(context.temp_allocator)
	log_path, _ := filepath.join({repo_root, "builds", fmt.tprintf("_tmp_isolated_%d.log", os.get_pid())}, context.temp_allocator)
	_ = os.remove(log_path)
	defer _ = os.remove(log_path)

	when ODIN_OS == .Windows {
		cmd := [?]string{"cmd.exe", "/c", "echo foundation_isolated_ok"}
	} else {
		cmd := [?]string{"/bin/sh", "-c", "echo foundation_isolated_ok"}
	}

	bp, started := engine.bg_process_start_to_file(repo_root, cmd[:], nil, log_path)
	testing.expect(t, started, "expected handle-isolated bg_process_start_to_file to start")
	if !started do return

	exited, exit_code := engine.bg_process_wait(&bp, 10000)
	testing.expect(t, exited && exit_code == 0, "expected echo subprocess to exit cleanly with code 0")

	data, rerr := os.read_entire_file(log_path, context.temp_allocator)
	testing.expect(t, rerr == nil && strings.contains(string(data), "foundation_isolated_ok"), "expected redirected log output to contain foundation_isolated_ok")

	rm_err := os.remove(log_path)
	testing.expect(t, rm_err == nil, "expected os.remove to succeed cleanly on FILE_SHARE_DELETE log file")
}

@(test)
test_cross_allocator_safety_tracking_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	prev_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = prev_alloc

	{
		// Window rename/text dialog open + close.
		wnd.show_text_input_dialog(wnd.Text_Dialog_Opts{
			title            = "Rename Script",
			prompt           = "New filename:",
			initial_text     = "Player.odin",
			confirm_label    = "Rename",
			cancel_label     = "Cancel",
			select_stem_only = true,
		})
		wnd.close_rename_dialog()

		// Clipboard cross-allocator copy_hierarchy + copy_files + clear_all/shutdown.
		clip.init()
		defer clip.shutdown()
		hier_payload := make([]byte, 32, context.allocator)
		for i in 0 ..< len(hier_payload) {
			hier_payload[i] = u8(i)
		}
		clip.copy_hierarchy(hier_payload)
		clip.copy_files({"assets/a.odin", "assets/b.odin"}, false)
		clip.clear_all()

		// Code Studio RAM syntax checker (valid + invalid to exercise diagnostic cloning/cleanup).
		ok_diags, _ := cs.check_odin_syntax_in_ram("package demo\nf :: proc() -> int { return 42 }\n", false, context.allocator)
		for d in ok_diags {
			delete(d.file)
			delete(d.message)
		}
		delete(ok_diags)

		bad_diags, _ := cs.check_odin_syntax_in_ram("package demo\nbad :: proc( {\n", false, context.allocator)
		testing.expect(t, len(bad_diags) > 0, "expected syntax diagnostics on malformed Odin input")
		for d in bad_diags {
			delete(d.file)
			delete(d.message)
		}
		delete(bad_diags)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 leaked allocations across cross-allocator paths, got %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees across cross-allocator paths, got %d", len(track.bad_free_array))
}

@(test)
test_crash_journal_symbolicated_and_last_log :: proc(t: ^testing.T) {
	defer {
		if p := crash_journal.path(); p != "" do _ = os.remove(p)
		if lp := crash_journal.last_path(); lp != "" do _ = os.remove(lp)
		crash_journal.breadcrumb_clear()
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		prev_alloc := context.allocator
		context.allocator = mem.tracking_allocator(&track)
		defer context.allocator = prev_alloc

		crash_journal.init("hardening-test")
		crash_journal.refresh_symbols()
		crash_journal.breadcrumb("hardening breadcrumb")
		crash_journal.write_test_entry("TEST (zero-heap symbolicated)")
	}

	testing.expectf(t, track.total_memory_allocated == 0, "expected zero heap allocations in crash_journal path, got %d bytes", track.total_memory_allocated)
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees in crash_journal path, got %d", len(track.bad_free_array))

	p := crash_journal.path()
	lp := crash_journal.last_path()
	testing.expect(t, p != "", "crash_journal.path() should be non-empty")
	testing.expect_value(t, lp, "logs/crash_last.log")
	if p == "" || lp == "" do return

	data_p, err_p := os.read_entire_file(p, context.temp_allocator)
	data_lp, err_lp := os.read_entire_file(lp, context.temp_allocator)
	testing.expect(t, err_p == nil, "crash_<pid>.log should exist")
	testing.expect(t, err_lp == nil, "logs/crash_last.log should exist")
	if err_p != nil || err_lp != nil do return

	txt_p := string(data_p)
	txt_lp := string(data_lp)
	testing.expect_value(t, txt_p, txt_lp)
	testing.expect(t, strings.contains(txt_p, "Haati crash"), "expected crash journal header")
	testing.expect(t, strings.contains(txt_p, "hardening breadcrumb"), "expected breadcrumb in crash journal")
	testing.expect(t, strings.contains(txt_p, "TEST (zero-heap symbolicated)"), "expected reason in crash journal")
	testing.expect(t, strings.contains(txt_p, "stack:"), "expected stack section in crash journal")
}
