package audio

import "core:c"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "haati:engine"

// =============================================================================
// Multi-Core Spatial Audio Occlusion & Per-Source Biquad Low-Pass Filtering
// =============================================================================

// Maps smoothed occlusion factor `[0..1]` into volume attenuation multiplier and cutoff frequency.
audio_compute_occlusion_gain_and_cutoff :: proc(occlusion_factor: f32, target_lpf_hz: f32 = 1400.0) -> (gain_mult: f32, cutoff_hz: f32) {
	occ := clamp(occlusion_factor, 0.0, 1.0)
	gain_mult = math.lerp(f32(1.0), f32(0.32), occ)
	min_hz := clamp(target_lpf_hz, 200.0, 12000.0)
	cutoff_hz = math.lerp(f32(20000.0), min_hz, occ)
	return gain_mult, cutoff_hz
}

// Zero-allocation per-track cooked PCM callback executing on SDL3_mixer's audio thread.
_track_cooked_lpf_cb :: proc "c" (userdata: rawptr, track: ^mix.Track, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	_ = track
	if userdata == nil || pcm == nil || samples <= 0 do return
	src := cast(^AudioSource)userdata
	if !src.lpf_active do return
	buf := ([^]f32)(pcm)[:int(samples)]
	ch := spec != nil ? int(spec.channels) : 2
	audio_biquad_process_interleaved(buf, ch, src.lpf_coeffs, &src.lpf_z1, &src.lpf_z2)
}

@(private = "file")
_Audio_Occlusion_Job :: struct {
	src:         ^AudioSource,
	src_pos:     [3]f32,
	blocked:     bool,
}

@(private = "file")
_Audio_Occlusion_Ctx :: struct {
	jobs:         []_Audio_Occlusion_Job,
	listener_pos: [3]f32,
}

@(private = "file")
_occlusion_trace_worker :: proc(start, end: int, userdata: rawptr) {
	ctx := cast(^_Audio_Occlusion_Ctx)userdata
	for i := start; i < end; i += 1 {
		job := &ctx.jobs[i]
		delta := job.src_pos - ctx.listener_pos
		dist := linalg.length(delta)
		if dist <= 0.15 {
			job.blocked = false
			continue
		}
		dir := delta / dist
		// Pull slightly back from the emitter surface so walls hosting a speaker don't self-hit.
		trace_dist := max(dist - 0.15, 0.05)
		job.blocked = engine.audio_occlusion_raycast(ctx.listener_pos, dir, trace_dist)
	}
}

// Traces ear-to-source occlusion rays concurrently via `engine.job_parallel_for`, then
// smoothly damps `occlusion_factor` and updates biquad LPF coefficients on the main thread.
audio_step_multicore_occlusion :: proc(w: ^engine.World, listener_pos: [3]f32, dt: f32) {
	if w == nil do return
	pool := audio_sources(w)
	if pool == nil do return

	jobs := make([dynamic]_Audio_Occlusion_Job, 0, 16, context.temp_allocator)
	it := engine.pool_iterator(pool)
	for src, _ in engine.pool_next(&it) {
		if !src.enabled || !engine.pool_valid(&w.transforms, engine.Handle(src.owner)) do continue
		if !src.enable_occlusion || !_listener.ok || src.spatial_blend <= 0 {
			src.occlusion_factor = 0
			src.lpf_active       = false
			continue
		}
		if src.track == nil || !bool(mix.TrackPlaying(src.track)) {
			src.occlusion_factor = 0
			src.lpf_active       = false
			continue
		}
		sw := engine.transform_world(src.owner)
		append(&jobs, _Audio_Occlusion_Job{src = src, src_pos = sw.position})
	}

	if len(jobs) == 0 do return

	ctx := _Audio_Occlusion_Ctx{
		jobs         = jobs[:],
		listener_pos = listener_pos,
	}
	engine.job_parallel_for(len(jobs), 4, _occlusion_trace_worker, &ctx)

	alpha := 1.0 - math.exp(-max(dt, 0.0) * 10.0)
	for j in jobs {
		target: f32 = j.blocked ? 1.0 : 0.0
		j.src.occlusion_factor = j.src.occlusion_factor + (target - j.src.occlusion_factor) * clamp(alpha, 0.0, 1.0)
		_, cutoff := audio_compute_occlusion_gain_and_cutoff(j.src.occlusion_factor, j.src.occlusion_lowpass_hz)
		j.src.lpf_active = j.src.occlusion_factor > 0.02
		if j.src.lpf_active {
			j.src.lpf_coeffs = audio_biquad_lowpass_coeffs(cutoff, 48000.0)
		}
	}
}
