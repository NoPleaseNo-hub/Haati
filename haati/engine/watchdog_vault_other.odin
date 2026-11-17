#+build !windows
package engine

// POSIX stub for `watchdog_vault_*`.

WATCHDOG_VAULT_MAGIC          :: u64(0x4854_5744_564C_5432)
WATCHDOG_VAULT_CAP            :: 16 * 1024 * 1024
WATCHDOG_VAULT_HDR_ZONE_CAP   :: 4096
WATCHDOG_VAULT_TABS_ZONE_OFF  :: WATCHDOG_VAULT_HDR_ZONE_CAP
WATCHDOG_VAULT_TABS_ZONE_CAP  :: 2 * 1024 * 1024 - WATCHDOG_VAULT_TABS_ZONE_OFF
WATCHDOG_VAULT_SCENE_ZONE_OFF :: 2 * 1024 * 1024
WATCHDOG_VAULT_SCENE_ZONE_CAP :: WATCHDOG_VAULT_CAP - WATCHDOG_VAULT_SCENE_ZONE_OFF

Watchdog_Vault_Handle :: distinct rawptr

watchdog_vault_create :: proc(vault_name: string) -> (Watchdog_Vault_Handle, bool) {
	return nil, false
}

watchdog_vault_write_meta :: proc(h: Watchdog_Vault_Handle, snap: Relaunch_SHM_Snapshot) -> bool {
	return false
}

watchdog_vault_write_tabs :: proc(h: Watchdog_Vault_Handle, tabs_json: []byte) -> bool {
	return false
}

watchdog_vault_write_scene :: proc(h: Watchdog_Vault_Handle, has_scene_bytes: bool, scene_bytes: []byte) -> bool {
	return false
}

watchdog_vault_write :: proc(h: Watchdog_Vault_Handle, snap: Relaunch_SHM_Snapshot, tabs_json: []byte) -> bool {
	return false
}

watchdog_vault_mark_clean_exit :: proc(h: Watchdog_Vault_Handle) {}

watchdog_vault_close :: proc(h: Watchdog_Vault_Handle) {}

watchdog_vault_read_and_consume :: proc(
	vault_name: string,
	allocator := context.allocator,
) -> (snap: Relaunch_SHM_Snapshot, tabs_json: []byte, ok: bool) {
	return {}, nil, false
}

watchdog_run_guardian_blocking :: proc(editor_pid: int, vault_name: string, restart_exe: string, restart_args: []string) -> int {
	return 0
}
