package haati_tool

// Thin forwarding entry point so both `odin run tools/haati -- <cmd>` and
// `odin run tools/mh -- <cmd>` invoke the exact same single source of truth.

import "core:fmt"
import "core:os"
import "core:path/filepath"

main :: proc() {
	odin_exe := "odin"
	when ODIN_OS == .Windows {
		root_odin, _ := filepath.join({ODIN_ROOT, "odin.exe"}, context.temp_allocator)
		if os.exists(root_odin) do odin_exe = root_odin
	} else {
		root_odin, _ := filepath.join({ODIN_ROOT, "odin"}, context.temp_allocator)
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
