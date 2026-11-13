package physics3d

// Physics 3D (Jolt) project settings.
// Displayed in Edit -> Project Settings with full reflection, undo/redo,
// and saved automatically to ProjectSettings/physics_3d_jolt.json.

import "core:math"
import jolt "haati:external/jolt"
import "haati:engine"

Physics3D_Settings :: struct {
	async_multithreaded_solver: bool `decor:tooltip(desc="When enabled (default), Jolt Physics dispatches broadphase, narrowphase GJK/EPA, and constraint island solving across background CPU worker threads via JobSystemThreadPool. Disable to force single-threaded execution.")`,
	worker_threads:             int  `decor:tooltip(desc="Number of Jolt worker threads when Async Multithreaded Solver is enabled (0 = Auto-detect all available CPU cores).")`,
	fixed_framerate_hz:         f32  `decor:tooltip(desc="Physics simulation fixed tick rate in Hz (ticks per second). Synced with Time.fixed_rate.")`,
	fixed_update_interval_ms:   f32  `decor:tooltip(desc="Fixed physics update interval in milliseconds (1000 / fixed_framerate_hz). Editing either Hz or ms automatically updates the other.")`,
	gravity:                    [3]f32,
	collision_steps:            int  `decor:tooltip(desc="Number of Jolt collision sub-steps per fixed physics tick.")`,
	max_bodies:                 int,
	max_body_pairs:             int,
	max_contact_constraints:    int,
	contact_tolerance:          f32,
	default_linear_damping:     f32,
	default_angular_damping:    f32,
	enable_continuous_cd:       bool,
	channel_1_name:             string,
	channel_2_name:             string,
	channel_3_name:             string,
	channel_4_name:             string,
	channel_5_name:             string,
	channel_6_name:             string,
	channel_7_name:             string,
	channel_8_name:             string,
}

@(project_settings={name="Physics 3D (Jolt)"})
physics3d_settings := Physics3D_Settings{
	async_multithreaded_solver = true,
	worker_threads             = 0,
	fixed_framerate_hz         = 60.0,
	fixed_update_interval_ms   = 16.6667,
	gravity                    = GRAVITY_DEFAULT,
	collision_steps            = 1,
	max_bodies                 = 10240,
	max_body_pairs             = 65536,
	max_contact_constraints    = 10240,
	contact_tolerance          = 0.02,
	default_linear_damping     = 0.05,
	default_angular_damping    = 0.05,
	enable_continuous_cd       = true,
	channel_1_name             = "Channel 1",
	channel_2_name             = "Channel 2",
	channel_3_name             = "Channel 3",
	channel_4_name             = "Channel 4",
	channel_5_name             = "Channel 5",
	channel_6_name             = "Channel 6",
	channel_7_name             = "Channel 7",
	channel_8_name             = "Channel 8",
}

collision_channel_label :: proc(idx: int) -> string {
	switch idx {
	case 0: return len(physics3d_settings.channel_1_name) > 0 ? physics3d_settings.channel_1_name : "Channel 1"
	case 1: return len(physics3d_settings.channel_2_name) > 0 ? physics3d_settings.channel_2_name : "Channel 2"
	case 2: return len(physics3d_settings.channel_3_name) > 0 ? physics3d_settings.channel_3_name : "Channel 3"
	case 3: return len(physics3d_settings.channel_4_name) > 0 ? physics3d_settings.channel_4_name : "Channel 4"
	case 4: return len(physics3d_settings.channel_5_name) > 0 ? physics3d_settings.channel_5_name : "Channel 5"
	case 5: return len(physics3d_settings.channel_6_name) > 0 ? physics3d_settings.channel_6_name : "Channel 6"
	case 6: return len(physics3d_settings.channel_7_name) > 0 ? physics3d_settings.channel_7_name : "Channel 7"
	case 7: return len(physics3d_settings.channel_8_name) > 0 ? physics3d_settings.channel_8_name : "Channel 8"
	}
	return "Channel"
}

@(private = "file")
_settings: struct {
	loaded:         bool,
	applied_grav:   [3]f32,
	applied_async:  bool,
	applied_threads: int,
	applied_hz:     f32,
	applied_ms:     f32,
}

// Polled to sync changes from Project Settings editor (`Physics 3D (Jolt)` <-> `Time` & Jolt `JobSystem`)
_settings_sync :: proc() {
	if !_settings.loaded {
		_settings.loaded = true
		engine.project_settings_load("Physics 3D (Jolt)", &physics3d_settings)
		if physics3d_settings.fixed_framerate_hz <= 1.0 {
			physics3d_settings.fixed_framerate_hz = max(engine.time_settings.fixed_rate, 60.0)
		}
		physics3d_settings.fixed_update_interval_ms = 1000.0 / physics3d_settings.fixed_framerate_hz
		engine.time_settings.fixed_rate = physics3d_settings.fixed_framerate_hz

		_settings.applied_grav    = physics3d_settings.gravity
		_settings.applied_async   = physics3d_settings.async_multithreaded_solver
		_settings.applied_threads = physics3d_settings.worker_threads
		_settings.applied_hz      = physics3d_settings.fixed_framerate_hz
		_settings.applied_ms      = physics3d_settings.fixed_update_interval_ms

		if _state.gravity == {} && physics3d_settings.gravity != {} {
			set_gravity(physics3d_settings.gravity)
		}
		return
	}

	if physics3d_settings.gravity != _settings.applied_grav {
		_settings.applied_grav = physics3d_settings.gravity
		set_gravity(physics3d_settings.gravity)
	}

	// Bidirectional sync between `fixed_framerate_hz`, `fixed_update_interval_ms`, and `engine.time_settings.fixed_rate`
	if abs(physics3d_settings.fixed_framerate_hz - _settings.applied_hz) > 0.01 {
		hz := clamp(physics3d_settings.fixed_framerate_hz, 10.0, 240.0)
		physics3d_settings.fixed_framerate_hz = hz
		physics3d_settings.fixed_update_interval_ms = 1000.0 / hz
		engine.time_settings.fixed_rate = hz
		_settings.applied_hz = hz
		_settings.applied_ms = physics3d_settings.fixed_update_interval_ms
	} else if abs(physics3d_settings.fixed_update_interval_ms - _settings.applied_ms) > 0.01 {
		ms := clamp(physics3d_settings.fixed_update_interval_ms, 4.0, 100.0)
		hz := math.round(1000.0 / ms)
		physics3d_settings.fixed_update_interval_ms = ms
		physics3d_settings.fixed_framerate_hz = hz
		engine.time_settings.fixed_rate = hz
		_settings.applied_ms = ms
		_settings.applied_hz = hz
	} else if abs(engine.time_settings.fixed_rate - _settings.applied_hz) > 0.01 && engine.time_settings.fixed_rate >= 1.0 {
		hz := engine.time_settings.fixed_rate
		physics3d_settings.fixed_framerate_hz = hz
		physics3d_settings.fixed_update_interval_ms = 1000.0 / hz
		_settings.applied_hz = hz
		_settings.applied_ms = physics3d_settings.fixed_update_interval_ms
	}

	// Rebuild Jolt JobSystemThreadPool if async toggle or worker thread count changed
	if physics3d_settings.async_multithreaded_solver != _settings.applied_async ||
	   physics3d_settings.worker_threads != _settings.applied_threads {
		_settings.applied_async   = physics3d_settings.async_multithreaded_solver
		_settings.applied_threads = physics3d_settings.worker_threads
		if _state.job_system != nil {
			jolt.JobSystem_Destroy(_state.job_system)
			_state.job_system = nil
		}
		if _state.world_ready {
			_recreate_job_system()
		}
	}
}

_recreate_job_system :: proc() {
	if _state.job_system != nil do return
	num_threads: i32 = 1
	if physics3d_settings.async_multithreaded_solver {
		if physics3d_settings.worker_threads > 0 {
			num_threads = i32(clamp(physics3d_settings.worker_threads, 1, 16))
		} else {
			num_threads = i32(clamp(engine.cpu_logical_core_count() - 2, 1, 8))
		}
	}
	job_config := jolt.JobSystemThreadPoolConfig{
		maxJobs     = 2048,
		maxBarriers = 1024,
		numThreads  = num_threads,
	}
	_state.job_system = jolt.JobSystemThreadPool_Create(&job_config)
}
