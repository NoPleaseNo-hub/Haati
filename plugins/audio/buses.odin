package audio

import "base:intrinsics"
import "core:c"
import "core:math"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"

// =============================================================================
// Submix Audio Buses, 2-Pole Biquad Low-Pass Filter & Voice->Music Sidechain
// =============================================================================

Audio_Bus_Kind :: enum u8 {
	Master         = 0,
	Music          = 1,
	SFX            = 2,
	Voice_Dialogue = 3,
	UI             = 4,
	Ambience       = 5,
}

AUDIO_BUS_COUNT :: 6

// Direct Form II Transposed 2-pole Biquad filter coefficients.
Audio_Biquad_Coeffs :: struct {
	b0, b1, b2: f32,
	a1, a2:     f32,
}

_Audio_Bus_Runtime :: struct {
	group:       ^mix.Group,
	volume:      f32,
	lowpass_hz:  f32,
	lpf_active:  bool,
	lpf_coeffs:  Audio_Biquad_Coeffs,
	lpf_z1:      [2]f32,
	lpf_z2:      [2]f32,
}

@(private = "file")
_bus_mgr: struct {
	initialized:        bool,
	buses:              [AUDIO_BUS_COUNT]_Audio_Bus_Runtime,
	dialogue_peak_bits: u32, // Written from Voice_Dialogue post-mix callback, consumed on main thread
	duck_env:           f32,
}

@(private = "file")
_ensure_bus_defaults :: proc() {
	if _bus_mgr.initialized do return
	_bus_mgr.initialized = true
	for i in 0 ..< AUDIO_BUS_COUNT {
		_bus_mgr.buses[i].volume     = 1.0
		_bus_mgr.buses[i].lowpass_hz = 22000.0
		_bus_mgr.buses[i].lpf_active = false
		_bus_mgr.buses[i].lpf_coeffs = audio_biquad_lowpass_coeffs(22000.0)
	}
}

// Computes normalized Audio EQ Cookbook 2-pole Butterworth low-pass biquad coefficients.
audio_biquad_lowpass_coeffs :: proc(cutoff_hz: f32, sample_rate: f32 = 48000.0, q: f32 = 0.70710678) -> Audio_Biquad_Coeffs {
	sr := max(sample_rate, 8000.0)
	nyquist := sr * 0.49
	fc := clamp(cutoff_hz, 20.0, nyquist)
	q_safe := max(q, 0.1)

	w0 := 2.0 * f32(math.PI) * fc / sr
	cos_w0 := math.cos(w0)
	sin_w0 := math.sin(w0)
	alpha := sin_w0 / (2.0 * q_safe)

	b0 := (1.0 - cos_w0) * 0.5
	b1 := 1.0 - cos_w0
	b2 := (1.0 - cos_w0) * 0.5
	a0 := 1.0 + alpha
	a1 := -2.0 * cos_w0
	a2 := 1.0 - alpha

	inv_a0 := 1.0 / max(a0, 1e-6)
	return Audio_Biquad_Coeffs{
		b0 = b0 * inv_a0,
		b1 = b1 * inv_a0,
		b2 = b2 * inv_a0,
		a1 = a1 * inv_a0,
		a2 = a2 * inv_a0,
	}
}

// Filters interleaved float32 PCM samples in-place (Direct Form II Transposed, 0 allocations).
audio_biquad_process_interleaved :: proc "contextless" (
	pcm:      []f32,
	channels: int,
	coeffs:   Audio_Biquad_Coeffs,
	z1:       ^[2]f32,
	z2:       ^[2]f32,
) {
	ch := clamp(channels, 1, 2)
	if len(pcm) == 0 || z1 == nil || z2 == nil do return

	for i := 0; i < len(pcm); i += 1 {
		c_idx := i % ch
		x := pcm[i]
		y := coeffs.b0 * x + z1[c_idx]
		z1_next := coeffs.b1 * x - coeffs.a1 * y + z2[c_idx]
		z2_next := coeffs.b2 * x - coeffs.a2 * y
		z1[c_idx] = z1_next
		z2[c_idx] = z2_next
		pcm[i] = y
	}
}

// Exponential attack/release envelope follower for voice->music sidechain ducking.
audio_sidechain_step_envelope :: proc(
	current_env: f32,
	trigger_peak: f32,
	dt:          f32,
	attack_sec:  f32 = 0.015,
	release_sec: f32 = 0.22,
) -> f32 {
	dt_c := max(dt, 0.0)
	tgt  := max(trigger_peak, 0.0)
	rate := tgt > current_env ? max(attack_sec, 0.001) : max(release_sec, 0.005)
	alpha := 1.0 - math.exp(-dt_c / rate)
	return current_env + (tgt - current_env) * clamp(alpha, 0.0, 1.0)
}

// Maps sidechain envelope `[0..1+]` into linear gain attenuation (down to `duck_db`).
audio_sidechain_duck_gain :: proc(env: f32, threshold: f32 = 0.05, duck_db: f32 = -9.0) -> f32 {
	if env <= threshold do return 1.0
	excess := clamp((env - threshold) / max(1.0 - threshold, 0.05), 0.0, 1.0)
	min_gain := math.pow(f32(10.0), duck_db / 20.0)
	return math.lerp(f32(1.0), min_gain, excess)
}

@(private = "file")
_group_post_mix_cb :: proc "c" (userdata: rawptr, group: ^mix.Group, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	_ = group
	if pcm == nil || samples <= 0 do return
	idx := int(uintptr(userdata))
	if idx < 0 || idx >= AUDIO_BUS_COUNT do return

	buf := ([^]f32)(pcm)[:int(samples)]
	bus := &_bus_mgr.buses[idx]

	if idx == int(Audio_Bus_Kind.Voice_Dialogue) {
		peak: f32 = 0
		for s in buf {
			a := abs(s)
			if a > peak do peak = a
		}
		prev := transmute(f32)intrinsics.atomic_load(&_bus_mgr.dialogue_peak_bits)
		if peak > prev {
			intrinsics.atomic_store(&_bus_mgr.dialogue_peak_bits, transmute(u32)peak)
		}
	}

	if bus.lpf_active {
		ch := spec != nil ? int(spec.channels) : 2
		audio_biquad_process_interleaved(buf, ch, bus.lpf_coeffs, &bus.lpf_z1, &bus.lpf_z2)
	}
}

audio_bus_set_volume :: proc(bus: Audio_Bus_Kind, vol: f32) {
	_ensure_bus_defaults()
	_bus_mgr.buses[int(bus)].volume = clamp(vol, 0.0, 2.0)
}

audio_bus_get_volume :: proc(bus: Audio_Bus_Kind) -> f32 {
	_ensure_bus_defaults()
	return _bus_mgr.buses[int(bus)].volume
}

audio_bus_set_lowpass :: proc(bus: Audio_Bus_Kind, cutoff_hz: f32, sample_rate: f32 = 48000.0) {
	_ensure_bus_defaults()
	b := &_bus_mgr.buses[int(bus)]
	b.lowpass_hz = clamp(cutoff_hz, 80.0, 22000.0)
	b.lpf_active = b.lowpass_hz < 19500.0
	b.lpf_coeffs = audio_biquad_lowpass_coeffs(b.lowpass_hz, sample_rate)
}

audio_bus_effective_gain :: proc(bus: Audio_Bus_Kind) -> f32 {
	_ensure_bus_defaults()
	master := _bus_mgr.buses[int(Audio_Bus_Kind.Master)].volume
	own    := _bus_mgr.buses[int(bus)].volume
	if bus == .Master do own = 1.0
	duck: f32 = 1.0
	if bus == .Music || bus == .Ambience {
		duck = audio_sidechain_duck_gain(_bus_mgr.duck_env)
	}
	return master * own * duck
}

audio_buses_step :: proc(dt: f32) {
	_ensure_bus_defaults()
	peak := transmute(f32)intrinsics.atomic_exchange(&_bus_mgr.dialogue_peak_bits, u32(0))
	_bus_mgr.duck_env = audio_sidechain_step_envelope(_bus_mgr.duck_env, peak, dt)
}

audio_buses_ensure_groups :: proc(mixer: ^mix.Mixer) {
	_ensure_bus_defaults()
	if mixer == nil do return
	for i in 0 ..< AUDIO_BUS_COUNT {
		b := &_bus_mgr.buses[i]
		if b.group == nil {
			b.group = mix.CreateGroup(mixer)
			if b.group != nil {
				_ = mix.SetGroupPostMixCallback(
					b.group,
					transmute(mix.GroupMixCallback)_group_post_mix_cb,
					rawptr(uintptr(i)),
				)
			}
		}
	}
}

audio_bus_group :: proc(bus: Audio_Bus_Kind) -> ^mix.Group {
	_ensure_bus_defaults()
	return _bus_mgr.buses[int(bus)].group
}

audio_buses_reset_runtime :: proc() {
	_ensure_bus_defaults()
	intrinsics.atomic_store(&_bus_mgr.dialogue_peak_bits, u32(0))
	_bus_mgr.duck_env = 0.0
	for i in 0 ..< AUDIO_BUS_COUNT {
		_bus_mgr.buses[i].lpf_z1 = {}
		_bus_mgr.buses[i].lpf_z2 = {}
	}
}

audio_buses_destroy_groups :: proc() {
	audio_buses_reset_runtime()
	for i in 0 ..< AUDIO_BUS_COUNT {
		if _bus_mgr.buses[i].group != nil {
			_ = mix.SetGroupPostMixCallback(_bus_mgr.buses[i].group, nil, nil)
			mix.DestroyGroup(_bus_mgr.buses[i].group)
			_bus_mgr.buses[i].group = nil
		}
	}
}
