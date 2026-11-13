package audio_editor

// Audio importer registration + run proc (editor-side, docs/Audio.md):
// decodes the source to float32 PCM (audio.decode_file_f32), applies the
// import settings (volume gain, normalize) and writes a float32 WAV
// artifact — playback loads the ARTIFACT, so every consumer hears the
// mastered result. The settings type stays in the runtime package
// (packages/audio/audio.odin): the catalog pipeline materializes settings
// in game binaries too.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "haati:engine_editor/asset_pipeline"
import engine "haati:engine"
import audio "haati:packages/audio"

_AUDIO_EXTS := []string{".mp3", ".wav", ".ogg", ".flac"}

@(phase={key=ImportersInit, order=1, mode=Editor})
audio_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	asset_pipeline.importer_register({
		name         = "audio",
		version      = 2,
		extensions   = _AUDIO_EXTS,
		settings_tid = typeid_of(audio.AudioSettings),
		run          = _import_audio,
	})
	engine.asset_pipeline_add_reimport_hook(audio._clip_reimported)
}

// The pipeline creates the artifact directory before calling run.
_import_audio :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	volume: f32 = 1
	normalize := false
	if settings != nil {
		s := cast(^audio.AudioSettings)settings
		volume = s.volume
		normalize = s.normalize
	}

	ext := strings.to_lower(filepath.ext(source_path), context.temp_allocator)
	is_compressed := ext == ".ogg" || ext == ".mp3" || ext == ".flac"
	if is_compressed && !normalize && math.abs(volume - 1.0) < 1e-4 {
		if raw, rerr := os.read_entire_file(source_path, context.temp_allocator); rerr == nil {
			if os.write_entire_file(artifact_path, raw) == nil {
				fmt.printf("[Pipeline] Imported audio (compressed pass-through %s): %s -> %s\n", ext, source_path, artifact_path)
				return true
			}
		}
	}

	pcm, spec, ok := audio.decode_file_f32(source_path)
	if !ok {
		fmt.printf("[Pipeline] Failed to decode audio: %s\n", source_path)
		return false
	}
	defer delete(pcm)

	gain := volume
	if normalize {
		peak: f32
		for s in pcm {
			if abs(s) > peak do peak = abs(s)
		}
		if peak > 0 do gain = volume / peak
	}
	if gain != 1 {
		for &s in pcm do s *= gain
	}

	if !audio._write_wav_f32(artifact_path, pcm, spec) {
		fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
		return false
	}
	fmt.printf("[Pipeline] Imported audio: %s -> %s\n", source_path, artifact_path)
	return true
}

