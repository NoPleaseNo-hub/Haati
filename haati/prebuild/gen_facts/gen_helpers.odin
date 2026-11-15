package gen_facts

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import db "../gen_db"

Import_Path_Opts :: struct {
	collection_prefix: string,
}

// resolve_import_path computes the Odin import path from `out_dir` to `source_path`.
resolve_import_path :: proc(out_dir: string, source_path: string, opts: Import_Path_Opts = {}, allocator := context.temp_allocator) -> string {
	if source_path == "" do return ""
	if opts.collection_prefix != "" && strings.has_prefix(source_path, opts.collection_prefix) {
		return strings.clone(source_path[len(opts.collection_prefix):], allocator)
	}
	out_dir_slash := strings.concatenate({out_dir, "/"}, context.temp_allocator)
	if strings.has_prefix(source_path, out_dir_slash) {
		return strings.clone(source_path[len(out_dir_slash):], allocator)
	}
	out_parts := strings.split(out_dir, "/", context.temp_allocator)
	src_parts := strings.split(source_path, "/", context.temp_allocator)
	common := 0
	for common < len(out_parts) && common < len(src_parts) && out_parts[common] == src_parts[common] {
		common += 1
	}
	b := strings.builder_make(allocator)
	for _ in 0 ..< len(out_parts) - common {
		strings.write_string(&b, "../")
	}
	for i in common ..< len(src_parts) {
		if i > common do strings.write_string(&b, "/")
		strings.write_string(&b, src_parts[i])
	}
	return strings.to_string(b)
}

// qualified_ident returns `source_pkg.ident` unless `source_pkg` is empty or matches `home_pkg`.
qualified_ident :: proc(home_pkg, source_pkg, ident: string, allocator := context.temp_allocator) -> string {
	if source_pkg != "" && source_pkg != home_pkg {
		return strings.concatenate({source_pkg, ".", ident}, allocator)
	}
	return strings.clone(ident, allocator)
}

// unwrap_named_type strips leading whitespace, pointer (`^`), and array/slice (`[...]`) prefixes,
// then splits a valid named type expression into `(full_named, pkg_prefix, bare_name, ok)`.
unwrap_named_type :: proc(type_expr: string) -> (full_named, pkg_prefix, bare_name: string, ok: bool) {
	t := strings.trim_space(type_expr)
	for {
		if strings.has_prefix(t, "^") {
			t = strings.trim_space(t[1:])
			continue
		}
		if strings.has_prefix(t, "[") {
			close := strings.index_byte(t, ']')
			if close < 0 do return "", "", "", false
			t = strings.trim_space(t[close + 1:])
			continue
		}
		break
	}
	if t == "" do return "", "", "", false
	for c in t {
		if !(c == '_' || c == '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return "", "", "", false
		}
	}
	if dot := strings.index_byte(t, '.'); dot >= 0 {
		return t, t[:dot], t[dot + 1:], true
	}
	return t, "", t, true
}

// dir_has_odin_files returns true when `dir` directly contains at least one `.odin` file.
dir_has_odin_files :: proc(dir: string, ignore_generated := false) -> bool {
	handle, err := os.open(dir)
	if err != nil do return false
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return false
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".odin") do continue
		if ignore_generated && strings.has_suffix(entry.name, "_generated.odin") do continue
		return true
	}
	return false
}

// is_included_for_host returns true if `owner_pkg` belongs in `host_name`'s generated dispatcher
// (either `host_name == ""`, `owner_pkg == ""`, `owner_pkg == host_name`, or not another runnable host).
is_included_for_host :: proc(runnables: []Runnable_Pkg, host_name, owner_pkg: string) -> bool {
	if host_name == "" || owner_pkg == "" do return true
	return owner_pkg == host_name || !is_runnable(runnables, owner_pkg)
}

Import_Entry :: struct {
	alias: string, // empty omits alias (`import "path"`)
	path:  string,
}

Import_Set :: struct {
	home_pkg: string,
	out_dir:  string,
	entries:  map[string]Import_Entry,
}

import_set_make :: proc(home_pkg, out_dir: string, allocator := context.temp_allocator) -> Import_Set {
	return Import_Set{
		home_pkg = home_pkg,
		out_dir  = out_dir,
		entries  = make(map[string]Import_Entry, allocator),
	}
}

import_set_destroy :: proc(s: ^Import_Set) {
	delete(s.entries)
}

import_set_add :: proc(s: ^Import_Set, source_pkg, source_path: string) {
	if source_pkg == "" || source_pkg == s.home_pkg do return
	if existing, ok := s.entries[source_pkg]; ok && existing.path != "" do return
	path := resolve_import_path(s.out_dir, source_path, allocator = s.entries.allocator)
	s.entries[source_pkg] = Import_Entry{alias = source_pkg, path = path}
}

_fallback_import_entry :: proc(pkg: string, allocator := context.temp_allocator) -> Import_Entry {
	if pkg == "engine" || pkg == "editor" {
		return Import_Entry{alias = "", path = strings.concatenate({"../../", pkg}, allocator)}
	}
	return Import_Entry{alias = pkg, path = strings.concatenate({"haati:packages/", pkg}, allocator)}
}

// import_set_add_type_and_source adds any package referenced by `type_name` (fixing e.g. `[4]pkg.Foo`)
// and overrides or adds `source_pkg` using `source_path` (or convention fallback when empty).
import_set_add_type_and_source :: proc(s: ^Import_Set, type_name, source_pkg, source_path: string) {
	if _, pkg, _, ok := unwrap_named_type(type_name); ok && pkg != "" && pkg != s.home_pkg {
		if pkg not_in s.entries do s.entries[pkg] = _fallback_import_entry(pkg, s.entries.allocator)
	}
	if source_pkg != "" && source_pkg != s.home_pkg {
		if source_path != "" {
			path := resolve_import_path(s.out_dir, source_path, allocator = s.entries.allocator)
			s.entries[source_pkg] = Import_Entry{alias = source_pkg, path = path}
		} else if source_pkg not_in s.entries {
			s.entries[source_pkg] = _fallback_import_entry(source_pkg, s.entries.allocator)
		}
	}
}

Header_Opts :: struct {
	pkg_name:                  string,
	gen_name:                  string,
	preamble_imports:          []Import_Entry,
	skip_pkg_in_set:           string,
	blank_line_before_comment: bool,
}

// write_gen_header emits `package ...`, deterministic sorted imports, and `// Code generated by ...`.
write_gen_header :: proc(b: ^strings.Builder, s: ^Import_Set, opts: Header_Opts) {
	strings.write_string(b, "package ")
	strings.write_string(b, opts.pkg_name)
	strings.write_string(b, "\n\n")

	for imp in opts.preamble_imports {
		if imp.alias != "" {
			fmt.sbprintf(b, "import %s %q\n", imp.alias, imp.path)
		} else {
			fmt.sbprintf(b, "import %q\n", imp.path)
		}
	}

	keys := make([dynamic]string, context.temp_allocator)
	for k in s.entries {
		if opts.skip_pkg_in_set != "" && k == opts.skip_pkg_in_set do continue
		append(&keys, k)
	}
	slice.sort(keys[:])
	for k in keys {
		e := s.entries[k]
		if e.alias != "" {
			fmt.sbprintf(b, "import %s %q\n", e.alias, e.path)
		} else {
			fmt.sbprintf(b, "import %q\n", e.path)
		}
	}

	if opts.blank_line_before_comment || len(opts.preamble_imports) > 0 || len(keys) > 0 {
		strings.write_string(b, "\n")
	}
	fmt.sbprintf(b, "// Code generated by %s. Do not edit.\n\n", opts.gen_name)
}

Settings_Entry :: struct {
	tab_name:    string,
	name:        string,
	source_pkg:  string,
	source_path: string,
	origin:      string,
}

// collect_settings_entries gathers and sorts declarations tagged with `@(attr_key={name="..."})`.
collect_settings_entries :: proc(w: ^db.World, attr_key: string, include_origin: bool) -> [dynamic]Settings_Entry {
	decls := db.get_comps_DeclInfo()
	attrs := db.get_comps(w, Attrs_GenComp)
	entries := make([dynamic]Settings_Entry)
	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)
		for args in attr_set.attrs {
			if args.key != attr_key do continue
			tab_name := args.fields["name"]
			if tab_name == "" {
				fmt.eprintf("%s: %s.%s needs name=\"...\"\n", attr_key, decl.pkg.name, decl.name)
				continue
			}
			origin := include_origin ? attr_origin(args, decl_rel_path(decl), decl.decl.pos.line, decl.name) : ""
			append(&entries, Settings_Entry{
				tab_name    = tab_name,
				name        = decl.name,
				source_pkg  = decl.pkg.name,
				source_path = decl.pkg_path,
				origin      = origin,
			})
		}
	}
	slice.sort_by(entries[:], proc(a, b: Settings_Entry) -> bool {
		if a.tab_name != b.tab_name do return a.tab_name < b.tab_name
		return a.name < b.name
	})
	return entries
}

// emit_settings_header writes package, `__engine` alias (when needed), and sorted tab imports.
emit_settings_header :: proc(b: ^strings.Builder, out_dir, gen_name: string, entries: []Settings_Entry, always_import_engine: bool) {
	imports := import_set_make("editor", out_dir)
	defer import_set_destroy(&imports)
	for e in entries {
		import_set_add(&imports, e.source_pkg, e.source_path)
	}
	preamble := [?]Import_Entry{{alias = "__engine", path = "../engine"}}
	opts := Header_Opts{
		pkg_name                  = "editor",
		gen_name                  = gen_name,
		blank_line_before_comment = true,
	}
	if always_import_engine || len(entries) > 0 {
		opts.preamble_imports = preamble[:]
	}
	write_gen_header(b, &imports, opts)
}
