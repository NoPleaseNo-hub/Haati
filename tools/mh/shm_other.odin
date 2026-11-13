#+build !windows
package mh

SHM_Pin :: distinct rawptr

shm_bridge_try_pin :: proc(shm_name: string) -> SHM_Pin {
	return nil
}

shm_bridge_release_when_consumed :: proc(pin: SHM_Pin) {}

shm_bridge_join :: proc() {}
