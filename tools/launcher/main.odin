package haati_launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import win "core:sys/windows"

when ODIN_OS == .Windows {
	foreign import user32 "system:User32.lib"

	@(default_calling_convention = "system")
	foreign user32 {
		MessageBoxW :: proc(hWnd: rawptr, lpText: cstring16, lpCaption: cstring16, uType: u32) -> i32 ---
	}

	MB_ICONERROR :: 0x00000010
}

_show_error :: proc(text_win: cstring16, text_cli: string) {
	when ODIN_OS == .Windows {
		_ = MessageBoxW(nil, text_win, "Haati Engine", MB_ICONERROR)
	} else {
		fmt.eprintln(text_cli)
	}
}

main :: proc() {
	exe_dir, derr := os.get_executable_directory(context.temp_allocator)
	if derr != nil || exe_dir == "" {
		cwd, cerr := os.get_working_directory(context.temp_allocator)
		if cerr != nil {
			_show_error(
				"Failed to resolve the Haati directory.",
				"Haati: failed to resolve the Haati directory.",
			)
			os.exit(1)
		}
		exe_dir = cwd
	}

	editor_name :: "Haati.exe" when ODIN_OS == .Windows else "Haati"
	editor_exe, _ := filepath.join({exe_dir, "builds", editor_name}, context.temp_allocator)
	if !os.exists(editor_exe) {
		_show_error(
			"builds\\Haati.exe was not found.\n\nBuild it first with:\nodin run tools/haati -- build",
			"Haati: builds/Haati not found; run: odin run tools/haati -- build",
		)
		os.exit(1)
	}

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, editor_exe)
	if len(os.args) > 1 {
		append(&cmd, ..os.args[1:])
	}

	p, perr := os.process_start({command = cmd[:], working_dir = exe_dir})
	if perr != nil {
		when ODIN_OS == .Windows {
			msg := fmt.tprintf("Failed to start %s:\n%v", editor_exe, perr)
			_ = MessageBoxW(nil, cstring16(win.utf8_to_wstring(msg, context.temp_allocator)), "Haati Engine", MB_ICONERROR)
		} else {
			fmt.eprintfln("Haati: failed to start %s: %v", editor_exe, perr)
		}
		os.exit(1)
	}
	_, _ = os.process_wait(p, 0)
}
