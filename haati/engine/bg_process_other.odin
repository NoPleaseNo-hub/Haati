#+build !windows
package engine

import "core:os"
import "core:time"

BG_Process :: struct {
	proc_h: os.Process,
	active: bool,
	pid:    int,
}

bg_process_start_to_file :: proc(
	working_dir:   string,
	command:       []string,
	env:           []string = nil,
	log_file_path: string   = "",
) -> (proc_out: BG_Process, ok: bool) {
	if len(command) == 0 do return {}, false

	out_fd: ^os.File = nil
	if len(log_file_path) > 0 {
		fd, ferr := os.open(log_file_path, {.Write, .Create, .Trunc})
		if ferr != nil do return {}, false
		out_fd = fd
	}
	defer if out_fd != nil do os.close(out_fd)

	desc := os.Process_Desc{
		working_dir = working_dir,
		command     = command,
		env         = env,
		stdout      = out_fd,
		stderr      = out_fd,
	}
	ph, err := os.process_start(desc)
	if err != nil do return {}, false
	return BG_Process{proc_h = ph, active = true, pid = ph.pid}, true
}

bg_process_poll :: proc(p: ^BG_Process) -> (exited: bool, exit_code: int) {
	if p == nil || !p.active do return true, 0
	st, err := os.process_wait(p.proc_h, 0)
	if err != nil || !st.exited do return false, 0
	p^ = {}
	return true, st.exit_code
}

bg_process_wait :: proc(p: ^BG_Process, timeout_ms: u32 = 25000) -> (exited: bool, exit_code: int) {
	if p == nil || !p.active do return true, 0
	st, err := os.process_wait(p.proc_h, time.Duration(timeout_ms) * time.Millisecond)
	if err != nil {
		_ = os.process_kill(p.proc_h)
		p^ = {}
		return false, -1
	}
	p^ = {}
	return true, st.exit_code
}

bg_process_kill :: proc(p: ^BG_Process) {
	if p == nil || !p.active do return
	_ = os.process_kill(p.proc_h)
	p^ = {}
}
