package audio

// Pure spatial math, Unity's model:
// - logarithmic rolloff: full volume inside min_distance, min/d beyond it,
//   held constant past max_distance
// - balance pan from the listener-space azimuth (x/z plane), continuous
//   with 2D at center
// - spatial_blend lerps both effects between 2D (0) and 3D (1)

import "core:math"
import "core:math/linalg"
import engine "haati:engine"

Audio_Rolloff_Mode :: enum u8 {
	Logarithmic   = 0, // Unity default: mn / clamp(d, mn, mx)
	Linear        = 1, // Fades linearly to 0.0 at max_distance
	Smooth_Cutoff = 2, // Inverse-distance windowed smoothly to 0.0 at max_distance
}

Spatial_Gains :: struct {
	gain:  f32, // distance attenuation, multiply into the track gain
	left:  f32, // stereo balance, 1/1 = centered
	right: f32,
}

spatial_gains :: proc(
	listener_pos: [3]f32, listener_rot: [4]f32,
	source_pos: [3]f32,
	min_distance, max_distance, blend: f32,
	rolloff: Audio_Rolloff_Mode = .Logarithmic,
) -> Spatial_Gains {
	if blend <= 0 do return {1, 1, 1}

	rel_world := source_pos - listener_pos
	q := engine.quat_to_native(listener_rot)
	rel := linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(q), rel_world)

	mn := max(min_distance, 0.001)
	mx := max(max_distance, mn)
	raw_d := linalg.length(rel)
	d := clamp(raw_d, mn, mx)
	atten: f32
	switch rolloff {
	case .Logarithmic:
		atten = mn / d
	case .Linear:
		if raw_d <= mn {
			atten = 1.0
		} else if raw_d >= mx {
			atten = 0.0
		} else {
			atten = 1.0 - (raw_d - mn) / max(mx - mn, 0.001)
		}
	case .Smooth_Cutoff:
		if raw_d <= mn {
			atten = 1.0
		} else if raw_d >= mx {
			atten = 0.0
		} else {
			t := (raw_d - mn) / max(mx - mn, 0.001)
			window := (1.0 - t * t)
			atten = (mn / d) * (window * window)
		}
	}

	pan: f32
	horiz := math.sqrt(rel.x * rel.x + rel.z * rel.z)
	if horiz > 0.0001 do pan = clamp(rel.x / horiz, -1, 1)

	b := min(blend, 1)
	pan *= b
	return {
		gain  = 1 + (atten - 1) * b,
		left  = clamp(1 - pan, 0, 1),
		right = clamp(1 + pan, 0, 1),
	}
}

// Computes pinna/head-shadowing directional low-pass cutoff (Hz) from listener-to-source azimuth.
// Front-facing sources stay bright (~22 kHz); directly behind attenuates smoothly down to ~3.2 kHz.
spatial_hrtf_lowpass_hz :: proc(
	listener_pos: [3]f32, listener_rot: [4]f32,
	source_pos: [3]f32,
	spatial_blend: f32 = 1.0,
) -> f32 {
	if spatial_blend <= 0.001 do return 22000.0
	delta := source_pos - listener_pos
	d2 := linalg.length2(delta)
	if d2 <= 1e-6 do return 22000.0
	dir_to_src := delta / math.sqrt(d2)

	q := engine.quat_to_native(listener_rot)
	forward := linalg.normalize0(linalg.quaternion128_mul_vector3(q, [3]f32{0, 0, -1}))
	front_dot := clamp(linalg.dot(forward, dir_to_src), -1.0, 1.0)
	rear_factor := clamp((1.0 - front_dot) * 0.5, 0.0, 1.0) * clamp(spatial_blend, 0.0, 1.0)
	return math.lerp(f32(22000.0), f32(3200.0), rear_factor * rear_factor)
}
