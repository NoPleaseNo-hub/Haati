package mh

// `scene-info` CLI command — reads HTSCN001 binary `.scene` files (in O(1) header +
// summary read) or legacy JSON `.scene` files and prints a compact human/AI-readable manifest.

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

cmd_scene_info :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.println("usage: odin run tools/haati -- scene-info <path/to/scene.scene>")
		return len(args) == 0 ? 1 : 0
	}

	path := args[0]
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("scene-info: failed to read %q: %v", path, rerr)
		return 1
	}

	if len(data) >= 8 && string(data[:8]) == "HTSCN001" {
		if len(data) < 32 {
			fmt.eprintfln("scene-info: truncated HTSCN001 header in %q (%d bytes)", path, len(data))
			return 1
		}
		fmt_ver, _ := endian.get_u32(data[8:12], .Little)
		sch_ver, _ := endian.get_u32(data[12:16], .Little)
		soff, _    := endian.get_u32(data[20:24], .Little)
		slen, _    := endian.get_u32(data[24:28], .Little)
		crc, _     := endian.get_u32(data[28:32], .Little)
		end_sum := u64(soff) + u64(slen)
		if fmt_ver != 1 || int(soff) < 32 || end_sum > u64(len(data)) {
			fmt.eprintfln("scene-info: invalid HTSCN001 section bounds in %q", path)
			return 1
		}
		poff := int(end_sum)
		if hash.crc32(data[poff:]) != crc {
			fmt.eprintfln("scene-info: HTSCN001 payload CRC32 mismatch in %q (file corrupted)", path)
			return 1
		}
		fmt.printfln("file: %s (%d bytes, HTSCN001 v%d, schema v%d, payload_crc32=0x%08x)", path, len(data), fmt_ver, sch_ver, crc)
		fmt.print(strings.trim_right_space(string(data[soff:poff])))
		fmt.println()
		return 0
	}

	val, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil {
		fmt.eprintfln("scene-info: %q is neither HTSCN001 nor valid JSON (%v)", path, perr)
		return 1
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		fmt.eprintfln("scene-info: %q JSON root is not an object", path)
		return 1
	}

	n_tr := 0
	n_cp := 0
	n_ns := 0
	n_bc := 0
	if a, ok := obj["transforms"].(json.Array); ok do n_tr = len(a)
	if a, ok := obj["components"].(json.Array); ok do n_cp = len(a)
	if a, ok := obj["nested_scenes"].(json.Array); ok do n_ns = len(a)
	if a, ok := obj["breadcrumbs"].(json.Array); ok do n_bc = len(a)

	fmt.printfln("file: %s (%d bytes, legacy JSON)", path, len(data))
	fmt.printfln("counts: transforms=%d components=%d nested_scenes=%d breadcrumbs=%d", n_tr, n_cp, n_ns, n_bc)
	if arr, ok := obj["transforms"].(json.Array); ok && len(arr) > 0 {
		fmt.println("transforms:")
		limit := min(len(arr), 48)
		for i in 0 ..< limit {
			if to, ok_o := arr[i].(json.Object); ok_o {
				nm := ""
				if nv, has_n := to["name"].(json.String); has_n do nm = string(nv)
				fmt.printfln("  - %q", nm != "" ? nm : "(unnamed)")
			}
		}
		if len(arr) > limit {
			fmt.printfln("  ... (%d more transform(s))", len(arr) - limit)
		}
	}
	return 0
}
