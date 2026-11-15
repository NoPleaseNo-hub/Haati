package mh

// Plugin links. Plugins live in plugins/ at the repository root, and a plugin
// is enabled by a symlink to it in moonhug/packages/ (presence in packages/ is
// the switch, the link avoids a copy). Git stores those links, but a clone
// does not always produce working ones:
//
// - Git for Windows checks links out as plain text files holding the target
//   path when core.symlinks is off, its default without Developer Mode.
// - A link created before its target existed during checkout can be the
//   wrong kind on Windows, or dangle anywhere.
//
// setup repairs both from the index, so the developer never edits a link by
// hand. It never removes a link (that is the enable switch) and never touches
// plugins/ itself.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

PACKAGES_DIR :: "haati/packages"

Link_State :: enum {
	Healthy,     // symlink resolving to a directory
	Placeholder, // plain file holding the target path (core.symlinks off)
	Dangling,    // symlink whose target is missing or not a directory
	Directory,   // a real directory in place of the link (hand copy)
	Missing,     // nothing on disk
}

Link_Entry :: struct {
	path:   string, // moonhug/packages/<name>
	target: string, // what git says the link points to
}

// Every symlink git tracks under packages/, from the index rather than the
// working tree, so a broken checkout still tells us what SHOULD be there.
tracked_links :: proc(allocator := context.temp_allocator) -> []Link_Entry {
	state, out, _, err := os.process_exec({command = {"git", "ls-files", "-s", PACKAGES_DIR}}, allocator)
	if err != nil || state.exit_code != 0 do return nil
	entries := make([dynamic]Link_Entry, allocator)
	text := string(out)
	for line in strings.split_lines_iterator(&text) {
		// "<mode> <hash> <stage>\t<path>"
		if !strings.has_prefix(line, "120000 ") do continue
		tab := strings.index_byte(line, '\t')
		if tab < 0 do continue
		path := line[tab + 1:]
		// The blob holds the target text.
		_, blob, _, berr := os.process_exec({command = {"git", "show", fmt.tprintf(":%s", path)}}, allocator)
		if berr != nil do continue
		append(&entries, Link_Entry{path = path, target = strings.trim_space(string(blob))})
	}
	return entries[:]
}

link_state :: proc(e: Link_Entry) -> Link_State {
	if _, err := os.read_link(e.path, context.temp_allocator); err == nil {
		return .Healthy if os.is_dir(e.path) else .Dangling
	}
	if os.is_dir(e.path) do return .Directory
	if os.exists(e.path) do return .Placeholder
	return .Missing
}

// Recreates one link from the index. Runs after the whole tree exists, so the
// target is present and the link comes out as a directory link.
repair_link :: proc(e: Link_Entry) -> bool {
	if os.exists(e.path) {
		if err := os.remove(e.path); err != nil {
			fmt.eprintfln("  %-16s cannot remove broken entry: %v", e.path, err)
			return false
		}
	}
	if code := run("git", "checkout", "--", e.path); code != 0 do return false
	return link_state(e) == .Healthy
}

// Ensures `moonhug/packages/<plugin>` links exist for every plugin folder under `plugins/`
// when `moonhug/packages/` is gitignored (uses `mklink /J` NTFS junctions on Windows so
// zero Developer Mode or admin elevation is ever required, and `ln -s` on Unix).
ensure_package_links :: proc() -> bool {
	os.make_directory_all(PACKAGES_DIR)

	// Prune dangling symlinks/junctions inside packages/ whose target directory no longer exists.
	if ph, perr := os.open(PACKAGES_DIR); perr == nil {
		if pentries, prerr := os.read_dir(ph, -1, context.temp_allocator); prerr == nil {
			for pe in pentries {
				if strings.has_prefix(pe.name, ".") do continue
				cand := fmt.tprintf("%s/%s", PACKAGES_DIR, pe.name)
				_, lerr := os.read_link(cand, context.temp_allocator)
				is_link := pe.type == .Symlink || lerr == nil
				if !is_link do continue
				if _, sterr := os.stat(cand, context.temp_allocator); sterr != nil && !os.is_dir(cand) {
					when ODIN_OS == .Windows {
						win_cand, _ := strings.replace_all(cand, "/", "\\", context.temp_allocator)
						_ = run("cmd", "/C", "rmdir", win_cand)
					} else {
						_ = os.remove(cand)
					}
				}
			}
		}
		os.close(ph)
	}

	h, err := os.open("plugins")
	if err != nil do return true
	defer os.close(h)
	entries, rerr := os.read_dir(h, -1, context.temp_allocator)
	if rerr != nil do return true

	all_ok := true
	for e in entries {
		if strings.has_prefix(e.name, ".") || e.name == "plugin_example" do continue
		plug_dir := fmt.tprintf("plugins/%s", e.name)
		if !os.is_dir(plug_dir) do continue

		dst_link := fmt.tprintf("%s/%s", PACKAGES_DIR, e.name)
		if !os.is_dir(dst_link) {
			if !_create_dir_link(dst_link, plug_dir, fmt.tprintf("../../plugins/%s", e.name)) {
				all_ok = false
			}
		}

		// Link sample sub-plugins (`animation_sample`, `timeline_sample`, `particles_sample`) when present
		samples_dir := fmt.tprintf("plugins/%s/samples", e.name)
		if sh, serr2 := os.open(samples_dir); serr2 == nil {
			if sentries, srerr := os.read_dir(sh, -1, context.temp_allocator); srerr == nil {
				for se in sentries {
					if strings.has_prefix(se.name, ".") || !strings.has_suffix(se.name, "_sample") do continue
					// Only link top-level samples that were enabled in standard setups (animation & particles samples)
					if e.name != "animation" && e.name != "particles" do continue
					s_src := fmt.tprintf("plugins/%s/samples/%s", e.name, se.name)
					s_dst := fmt.tprintf("%s/%s", PACKAGES_DIR, se.name)
					if info2, sterr := os.stat(s_src, context.temp_allocator); sterr == nil && info2.type == .Directory && !os.is_dir(s_dst) {
						_ = _create_dir_link(s_dst, s_src, fmt.tprintf("../../plugins/%s/samples/%s", e.name, se.name))
					}
				}
			}
			os.close(sh)
		}
	}
	return all_ok
}

@(private = "file")
_create_dir_link :: proc(dst_path: string, win_src_rel: string, unix_target: string) -> bool {
	when ODIN_OS == .Windows {
		win_dst, _ := strings.replace_all(dst_path, "/", "\\", context.temp_allocator)
		target_src := win_src_rel
		if resolved, rerr := os.read_link(win_src_rel, context.temp_allocator); rerr == nil && os.is_dir(resolved) {
			target_src = resolved
		} else if abs_p, aerr := filepath.abs(win_src_rel, context.temp_allocator); aerr == nil {
			target_src = abs_p
		}
		win_src, _ := strings.replace_all(target_src, "/", "\\", context.temp_allocator)
		return run("cmd", "/C", "mklink", "/J", win_dst, win_src) == 0
	} else {
		return run("ln", "-s", unix_target, dst_path) == 0
	}
}

// The setup step. Returns false when a link is still broken afterwards.
repair_package_links :: proc() -> bool {
	links := tracked_links()
	if len(links) == 0 {
		ok := ensure_package_links()
		fmt.printfln("mh: verified local plugin links in %s", PACKAGES_DIR)
		return ok
	}
	fmt.printfln("mh: plugin links in %s", PACKAGES_DIR)

	need_symlinks := false
	broken := 0
	for e in links {
		name := e.path[len(PACKAGES_DIR) + 1:]
		switch link_state(e) {
		case .Healthy:
			fmt.printfln("  %-16s ok -> %s", name, e.target)
		case .Directory:
			// A real folder where the link should be. Deleting it could throw
			// away edits, so it is reported and left alone.
			fmt.eprintfln("  %-16s is a real directory, expected a link to %s (a copy? remove it by hand and rerun)", name, e.target)
			broken += 1
		case .Placeholder, .Dangling, .Missing:
			if !need_symlinks {
				// Only this clone's config, never the user's global git setup.
				need_symlinks = true
				_ = run("git", "config", "core.symlinks", "true")
			}
			if repair_link(e) {
				fmt.printfln("  %-16s repaired -> %s", name, e.target)
			} else {
				fmt.eprintfln("  %-16s BROKEN, could not create the link to %s", name, e.target)
				broken += 1
			}
		}
	}
	if broken > 0 {
		when ODIN_OS == .Windows {
			fmt.eprintln("mh: creating symlinks needs Developer Mode (Settings > For developers) or an elevated shell. Enable it, then rerun: odin run tools/mh -- setup")
		}
		return false
	}
	return true
}
