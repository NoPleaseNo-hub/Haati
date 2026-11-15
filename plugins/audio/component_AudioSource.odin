package audio

// Unity-literal AudioSource: a clip reference plus per-instance mixing
// controls. The live SDL3_mixer track is runtime-only.

import mix "vendor:sdl3/mixer"
import engine "haati:engine"

// ref_tags="Output": something a timeline track can drive. A `has:"@Output"`
// picker offers objects carrying one.
@(component={menu="Audio/AudioSource", ref_tags="Output"})
@(typ_guid={guid="6f7fb020-d764-4ce1-bc09-d8088356bd22"})
AudioSource :: struct {
	using base:    engine.CompData `inspect:"-"`,
	clip:                 engine.Asset_GUID `ext:"mp3,wav,ogg,flac"`,
	volume:               f32,
	pitch:                f32, // playback frequency ratio (1 = as authored)
	mute:                 bool,
	loop:                 bool,
	play_on_awake:        bool,
	// 0 = 2D (full volume, centered), 1 = 3D (attenuated + panned relative
	// to the AudioListener). Unity's Spatial Blend.
	spatial_blend:        f32,
	min_distance:         f32, // full volume inside this radius
	max_distance:         f32, // attenuation stops falling past this radius
	rolloff_mode:         Audio_Rolloff_Mode,
	bus:                  Audio_Bus_Kind,
	enable_occlusion:     bool,
	occlusion_lowpass_hz: f32,

	track:            ^mix.Track `json:"-" inspect:"-"`,
	started:          bool `json:"-" inspect:"-"`,
	occlusion_factor: f32 `json:"-" inspect:"-"`,
	lpf:              Audio_Atomic_Biquad `json:"-" inspect:"-"`,
}

reset_AudioSource :: proc(comp: ^AudioSource) {
	cleanup_AudioSource(comp)
	comp.volume = 1
	comp.pitch = 1
	comp.play_on_awake = true
	comp.min_distance = 1
	comp.max_distance = 500
	comp.bus = .SFX
	comp.occlusion_lowpass_hz = 1400.0
}

cleanup_AudioSource :: proc(comp: ^AudioSource) {
	_destroy_track(comp)
	engine.comp_zero(comp)
}

// Live destroy — the track must die with the component or it keeps playing.
on_destroy_AudioSource :: proc(comp: ^AudioSource) {
	_destroy_track(comp)
}

_destroy_track :: proc(comp: ^AudioSource) {
	if comp.track != nil {
		_ = mix.SetTrackCookedCallback(comp.track, nil, nil)
		mix.DestroyTrack(comp.track)
		comp.track = nil
	}
}
