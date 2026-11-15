package haati_tool

// Thin forwarding entry point so both `odin run tools/haati -- <cmd>` and
// `odin run tools/mh -- <cmd>` invoke the exact same single source of truth.

import "core:fmt"
import "core:os"
import "core:path/filepath"

main :: proc() {
	exe_name :: "odin.exe" when ODIN_OS == .Windows else "odin"
	odin_exe := "odin"
	// Prefer bundled `<repo>/tools/odin/` first for zero-external-dependency portability.
	if cwd, cerr := os.get_working_directory(context.temp_allocator); cerr == nil {
		dir := cwd
		for {
			cand, jerr := filepath.join({dir, "tools", "odin", exe_name}, context.temp_allocator)
			if jerr == nil && os.exists(cand) {
				odin_exe = cand
				break
			}
			parent: string
			{
				context.allocator = context.temp_allocator
				parent = filepath.dir(dir)
			}
			if parent == dir do break
			dir = parent
		}
	}
	if odin_exe == "odin" {
		root_odin, _ := filepath.join({ODIN_ROOT, exe_name}, context.temp_allocator)
		if os.exists(root_odin) do odin_exe = root_odin
	}

	cmd := make([dynamic]string, 0, len(os.args) + 4, context.temp_allocator)
	append(&cmd, odin_exe, "run", "tools/mh", "--")
	append(&cmd, ..os.args[1:])
	p, err := os.process_start({
		command = cmd[:],
		stdout  = os.stdout,
		stderr  = os.stderr,
		stdin   = os.stdin,
	})
	if err != nil {
		fmt.eprintfln("haati: cannot invoke tools/mh: %v", err)
		os.exit(1)
	}
	st, werr := os.process_wait(p)
	if werr != nil {
		os.exit(1)
	}
	os.exit(st.exit_code)
}
