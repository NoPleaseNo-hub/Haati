#+build !windows
package overwatch_app

import "core:time"

run_overwatch_gui :: proc(s: ^Recorder_Session) {
	for {
		session_poll_and_drain(s)
		if s.health == .Stopped || s.health == .Crashed do break
		time.sleep(16 * time.Millisecond)
	}
}
