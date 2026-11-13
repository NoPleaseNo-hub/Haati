package audio_tests

import "core:math"
import "core:testing"
import audio "haati:packages/audio"

@(test)
test_audio_biquad_lpf_sidechain_and_occlusion :: proc(t: ^testing.T) {
	defer {
		for b in audio.Audio_Bus_Kind {
			audio.audio_bus_set_volume(b, 1.0)
			audio.audio_bus_set_lowpass(b, 22000.0)
		}
		audio.audio_buses_reset_runtime()
	}

	// 1. 2-Pole Butterworth Biquad LPF (cutoff = 1 kHz @ 48 kHz)
	coeffs := audio.audio_biquad_lowpass_coeffs(1000.0, 48000.0)

	N :: 512
	sr := f32(48000.0)
	low_buf: [N]f32
	high_buf: [N]f32
	for i in 0 ..< N {
		phase := f32(i) / sr
		low_buf[i]  = math.sin(2.0 * f32(math.PI) * 200.0 * phase)
		high_buf[i] = math.sin(2.0 * f32(math.PI) * 8000.0 * phase)
	}

	z1_lo, z2_lo: [2]f32
	z1_hi, z2_hi: [2]f32
	audio.audio_biquad_process_interleaved(low_buf[:], 1, coeffs, &z1_lo, &z2_lo)
	audio.audio_biquad_process_interleaved(high_buf[:], 1, coeffs, &z1_hi, &z2_hi)

	sum_lo, sum_hi: f32
	for i in N / 2 ..< N {
		sum_lo += low_buf[i] * low_buf[i]
		sum_hi += high_buf[i] * high_buf[i]
	}
	rms_200hz := math.sqrt(sum_lo / f32(N / 2))
	rms_8khz  := math.sqrt(sum_hi / f32(N / 2))
	testing.expect(t, rms_200hz > 0.6, "expected 200 Hz signal to pass 1 kHz LPF with minimal loss")
	testing.expect(t, rms_8khz < 0.12, "expected 8 kHz signal to be strongly attenuated by 1 kHz LPF")

	// 2. Voice->Music Sidechain Envelope & Ducking
	env := audio.audio_sidechain_step_envelope(0.0, 0.9, 0.05)
	testing.expect(t, env > 0.5, "expected sidechain attack envelope > 0.5")
	testing.expect(t, audio.audio_sidechain_duck_gain(env) < 0.6, "expected ducked music gain < 0.6")
	testing.expect_value(t, audio.audio_sidechain_duck_gain(0.0), f32(1.0))

	// 3. Spatial Occlusion Curve & Bus Volume Routing
	g0, f0 := audio.audio_compute_occlusion_gain_and_cutoff(0.0)
	testing.expect(t, abs(g0 - 1.0) < 1e-4 && abs(f0 - 20000.0) < 1e-2, "unoccluded curve mismatch")
	g1, f1 := audio.audio_compute_occlusion_gain_and_cutoff(1.0, 1200.0)
	testing.expect(t, g1 < 0.4 && abs(f1 - 1200.0) < 1e-2, "occluded curve mismatch")

	audio.audio_bus_set_volume(.SFX, 0.5)
	testing.expect(t, abs(audio.audio_bus_effective_gain(.SFX) - 0.5) < 1e-4, "SFX bus gain mismatch")
}
