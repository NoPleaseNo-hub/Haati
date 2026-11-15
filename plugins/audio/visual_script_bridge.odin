package audio

import "base:runtime"
import "core:strings"
import "haati:engine"

@(init)
_install_audio_vs_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.visual_script_install_audio_bridge(engine.Visual_Script_Audio_Bridge{
		bus_send        = _vs_bus_send,
		play_spatial_3d = _vs_play_spatial_3d,
	})
}

_parse_bus_kind :: proc(bus_name: string) -> Audio_Bus_Kind {
	s := strings.to_lower(strings.trim_space(bus_name), context.temp_allocator)
	switch s {
	case "master":                  return .Master
	case "music":                   return .Music
	case "sfx":                     return .SFX
	case "voice", "voice_dialogue", "dialogue": return .Voice_Dialogue
	case "ui":                      return .UI
	case "ambience", "ambient":     return .Ambience
	}
	return .SFX
}

_vs_bus_send :: proc(bus_name: string, volume, cutoff_hz: f32) {
	bus := _parse_bus_kind(bus_name)
	audio_bus_set_volume(bus, volume)
	if cutoff_hz > 0 {
		audio_bus_set_lowpass(bus, cutoff_hz)
	}
}

_vs_play_spatial_3d :: proc(self: engine.Transform_Handle, cue_name: string, pos: [3]f32, volume, pitch: f32) {
	if _, src, ok := engine.vs_resolve_entity_comp(engine.Handle(self), AudioSource); ok {
		src.volume = clamp(volume, 0.0, 4.0)
		src.pitch = max(pitch, 0.05)
		src.spatial_blend = 1.0
		if src.clip != {} {
			_ = audio_play(src)
			return
		}
	}
	if cue_name != "" {
		if guid, ok := engine.asset_db_lookup_guid_any(cue_name); ok {
			_ = play_clip_at_point(guid, pos, clamp(volume, 0.0, 4.0))
		}
	}
}
