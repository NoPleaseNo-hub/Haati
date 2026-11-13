#+build !windows
package overwatch_ipc

SHM_Mapping :: struct {
	handle: rawptr,
	block:  ^Overwatch_SHM_Block,
}

shm_create :: proc(name: string) -> (m: SHM_Mapping, ok: bool) {
	b := new(Overwatch_SHM_Block)
	return SHM_Mapping{handle = b, block = b}, true
}

shm_open :: proc(name: string) -> (m: SHM_Mapping, ok: bool) {
	return {}, false
}

shm_close :: proc(m: ^SHM_Mapping) {
	if m != nil && m.block != nil {
		free(m.block)
		m.block = nil
		m.handle = nil
	}
}

current_working_set_mb :: proc() -> f32 {
	return 0
}

is_pid_alive :: proc(pid: u32) -> (alive: bool, exit_code: u32) {
	return false, 0
}
