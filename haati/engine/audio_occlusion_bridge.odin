package engine

// Thread-safe audio occlusion raycast bridge so `plugins/audio` stays cleanly
// decoupled from `plugins/physics3d` while still tracing `CHANNEL_SOLID_WORLD`
// geometry across `job_parallel_for` worker threads.

Audio_Occlusion_Raycast_Fn :: #type proc(origin: [3]f32, direction: [3]f32, max_dist: f32) -> (blocked: bool)

@(private = "file")
_audio_occlusion_raycast_fn: Audio_Occlusion_Raycast_Fn

// Registers or clears the active physics backend's thread-safe occlusion raycast proc.
register_audio_occlusion_raycast :: proc(fn: Audio_Occlusion_Raycast_Fn) {
	_audio_occlusion_raycast_fn = fn
}

// Traces from listener/source along `direction` up to `max_dist`. Safe to invoke
// from `job_parallel_for` workers once the physics backend registers a lock-free query.
audio_occlusion_raycast :: proc(origin: [3]f32, direction: [3]f32, max_dist: f32) -> bool {
	if max_dist <= 1e-4 || _audio_occlusion_raycast_fn == nil do return false
	return _audio_occlusion_raycast_fn(origin, direction, max_dist)
}
