package overwatch_ipc

// =============================================================================
// Overwatch Out-of-Process Flight Recorder — Lock-Free Shared Memory Wire ABI
// =============================================================================
// Shared between `moonhug/engine` (producer, only while hooks are EXTENDED) and
// `tools/overwatch` (`builds/MoonHug_Overwatch.exe`, out-of-process consumer).
//
// Zero mutexes, zero syscalls per frame, survives instant engine crashes
// (`EXCEPTION_ACCESS_VIOLATION`) and infinite-loop hangs!

import "base:intrinsics"

OW_MAGIC           :: u64(0x4D48_4F57_4950_4331) // "MHOWIPC1"
OW_VERSION         :: u32(1)
OW_FRAME_RING_CAP  :: 2048
OW_FRAME_RING_MASK :: u64(OW_FRAME_RING_CAP - 1)
OW_EVENT_RING_CAP  :: 512
OW_EVENT_RING_MASK :: u64(OW_EVENT_RING_CAP - 1)

OW_DEFAULT_SHM_PREFIX :: "Local\\MoonHug_Overwatch_IPC_"

Overwatch_Phase :: enum u8 {
	Idle              = 0,
	Asset_Refresh     = 1,
	Thumbnails        = 2,
	Sim_Tick          = 3,
	Editor_UI         = 4,
	Gizmo_Pass        = 5,
	Scene_3D_View     = 6,
	Scene_2D_View     = 7,
	Game_View         = 8,
	Plugin_Windows    = 9,
	Swapchain_Present = 10,
	Hot_Cartridge     = 11,
}

Overwatch_Event_Kind :: enum u8 {
	Session_Lifecycle = 0,
	User_Action       = 1,
	Window_Tab        = 2,
	Selection         = 3,
	Undo_Redo         = 4,
	Simulation        = 5,
	Hot_Reload        = 6,
	Frame_Spike       = 7,
	Bookmark          = 8,
	Warning_Error     = 9,
}

OW_FLAG_SPIKE_WARN   :: u8(1 << 0) // >= alert_threshold_ms (default 16.67 ms)
OW_FLAG_SPIKE_SEVERE :: u8(1 << 1) // >= 33.33 ms (< 30 FPS hitch)
OW_FLAG_SIM_ACTIVE   :: u8(1 << 2)

Overwatch_Frame_Sample :: struct {
	seq:             u64, // Written last with atomic_store_explicit(..., .Release)
	frame_number:    u64,
	elapsed_ms:      f64,
	dt_ms:           f32,
	fps:             f32,
	sim_ms:          f32,
	ui_ms:           f32,
	render_ms:       f32,
	present_ms:      f32,
	working_set_mb:  f32,
	transform_count: u32,
	raycast_count:   u16,
	culprit_phase:   Overwatch_Phase,
	flags:           u8,
}

#assert(size_of(Overwatch_Frame_Sample) == 64)

Overwatch_Event :: struct {
	seq:          u64, // Written last with atomic_store_explicit(..., .Release)
	frame_number: u64,
	elapsed_ms:   f64,
	kind:         Overwatch_Event_Kind,
	phase:        Overwatch_Phase,
	_pad:         [2]u8,
	duration_ms:  f32,
	category:     [32]u8,
	detail:       [192]u8,
}

#assert(size_of(Overwatch_Event) == 256)

Overwatch_SHM_Header :: struct {
	magic:                 u64,
	version:               u32,
	engine_pid:            u32,
	recorder_pid:          u32,
	hooks_extended:        b32,
	stop_requested:        b32,
	marker_requested:      b32,
	session_start_unix_ms: i64,
	engine_heartbeat_ns:   i64,
	inflight_enter_ns:     i64,
	frame_write_seq:       u64,
	event_write_seq:       u64,
	alert_threshold_ms:    f32,
	inflight_phase:        u32,
	total_spikes:          u32,
	max_dt_ms_x100:        u32,
	inflight_context:      [96]u8,
	active_scene:          [96]u8,
	selected_object:       [96]u8,
	pawn_state:            [64]u8,
	output_dir:            [128]u8,
}

Overwatch_SHM_Block :: struct {
	header: Overwatch_SHM_Header,
	frames: [OW_FRAME_RING_CAP]Overwatch_Frame_Sample,
	events: [OW_EVENT_RING_CAP]Overwatch_Event,
}

phase_name :: proc(p: Overwatch_Phase) -> string {
	switch p {
	case .Idle:              return "Idle"
	case .Asset_Refresh:     return "Asset_Refresh"
	case .Thumbnails:        return "Thumbnails"
	case .Sim_Tick:          return "Sim_Tick (Physics/GAS)"
	case .Editor_UI:         return "Editor_UI"
	case .Gizmo_Pass:        return "Gizmo_Pass"
	case .Scene_3D_View:     return "Scene_3D_View"
	case .Scene_2D_View:     return "Scene_2D_View"
	case .Game_View:         return "Game_View"
	case .Plugin_Windows:    return "Plugin_Windows"
	case .Swapchain_Present: return "Swapchain_Present"
	case .Hot_Cartridge:     return "Hot_Cartridge"
	}
	return "Unknown"
}

event_kind_name :: proc(k: Overwatch_Event_Kind) -> string {
	switch k {
	case .Session_Lifecycle: return "SESSION"
	case .User_Action:       return "ACTION"
	case .Window_Tab:        return "WINDOW"
	case .Selection:         return "SELECT"
	case .Undo_Redo:         return "UNDO"
	case .Simulation:        return "SIM"
	case .Hot_Reload:        return "HOTSWAP"
	case .Frame_Spike:       return "SPIKE"
	case .Bookmark:          return "MARKER"
	case .Warning_Error:     return "WARN"
	}
	return "EVENT"
}

write_fixed_str :: proc(dst: []u8, s: string) {
	if len(dst) == 0 do return
	n := min(len(s), len(dst) - 1)
	if n > 0 {
		copy(dst[:n], transmute([]u8)s[:n])
	}
	dst[n] = 0
}

read_fixed_str :: proc(src: []u8) -> string {
	n := 0
	for n < len(src) && src[n] != 0 {
		n += 1
	}
	return string(src[:n])
}

// Lock-free SPSC producer helpers
push_frame_sample :: proc(blk: ^Overwatch_SHM_Block, sample: Overwatch_Frame_Sample) {
	if blk == nil do return
	next_seq := intrinsics.atomic_load_explicit(&blk.header.frame_write_seq, .Relaxed) + 1
	slot := &blk.frames[next_seq & OW_FRAME_RING_MASK]
	s := sample
	s.seq = 0
	slot^ = s
	intrinsics.atomic_store_explicit(&slot.seq, next_seq, .Release)
	intrinsics.atomic_store_explicit(&blk.header.frame_write_seq, next_seq, .Release)
}

push_event :: proc(
	blk:          ^Overwatch_SHM_Block,
	frame_number: u64,
	elapsed_ms:   f64,
	kind:         Overwatch_Event_Kind,
	phase:        Overwatch_Phase,
	duration_ms:  f32,
	category:     string,
	detail:       string,
) {
	if blk == nil do return
	next_seq := intrinsics.atomic_load_explicit(&blk.header.event_write_seq, .Relaxed) + 1
	slot := &blk.events[next_seq & OW_EVENT_RING_MASK]
	ev: Overwatch_Event
	ev.frame_number = frame_number
	ev.elapsed_ms   = elapsed_ms
	ev.kind         = kind
	ev.phase        = phase
	ev.duration_ms  = duration_ms
	write_fixed_str(ev.category[:], category)
	write_fixed_str(ev.detail[:], detail)
	slot^ = ev
	intrinsics.atomic_store_explicit(&slot.seq, next_seq, .Release)
	intrinsics.atomic_store_explicit(&blk.header.event_write_seq, next_seq, .Release)
}
