#+build !darwin
#+build !windows
package engine

// Non-macOS / non-Windows OS shell stubs.

import "core:fmt"

os_move_to_trash :: proc(path: string) -> bool {
	fmt.printf("[Engine] Move to trash: not implemented on this OS (%s)\n", path)
	return false
}

os_open_in_os :: proc(path: string) -> bool {
	fmt.printf("[Engine] Open with OS: not implemented on this OS (%s)\n", path)
	return false
}

os_reveal_in_os :: proc(path: string) -> bool {
	fmt.printf("[Engine] Show in file manager: not implemented on this OS (%s)\n", path)
	return false
}
