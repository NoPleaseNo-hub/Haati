package editor

import "base:runtime"
import im "haati:external/odin-imgui"
import engine "../engine"
import "inspector"
import "undo"

@(private)
_inspector_euler_cache: [3]f32

// WHICH object the euler cache describes. Without it the cache is keyed only by
// "the quaternion changed", so it survives a selection change: after editing one
// object the next selected object shows the previous one's angles until their
// quaternions happen to differ. Two objects at the same orientation show each
// other's numbers indefinitely.
@(private)
_inspector_euler_owner: engine.Transform_Handle

@(private)
_inspector_euler_quat_src: [4]f32

@(private)
_rotation_peer_start: map[engine.Transform_Handle][4]f32

// Axes touched at any point during the current drag. Accumulated because the
// commit frame itself shows no movement.
@(private)
_rotation_moved_axes: [3]bool

@(private)
_rotation_peer_start_clear :: proc() {
	if _rotation_peer_start != nil do clear(&_rotation_peer_start)
	_rotation_moved_axes = {}
}

rotation_euler_cache_shutdown :: proc() {
	if _rotation_peer_start != nil {
		delete(_rotation_peer_start)
		_rotation_peer_start = nil
	}
	_rotation_moved_axes = {}
	_inspector_euler_owner = {}
	_inspector_euler_cache = {}
	_inspector_euler_quat_src = {}
}

@(private)
_rotation_apply_to_peers :: proc(
	t: ^engine.Transform,
	multi_offset: uintptr,
	euler_before: [3]f32,
	euler_after: [3]f32,
	moved: [3]bool,
	commit: bool,
) {
	peers := inspector.multi_peers()
	if len(peers) == 0 do return
	if _rotation_peer_start == nil {
		_rotation_peer_start = make(map[engine.Transform_Handle][4]f32, 16, runtime.default_allocator())
	}

	for peer in peers {
		if peer.base == nil do continue
		pt := cast(^engine.Transform)peer.base
		ph := engine.Transform_Handle(peer.handle)

		// Remember where this peer started, the first time the drag touches it.
		if ph not_in _rotation_peer_start {
			_rotation_peer_start[ph] = pt.rotation
		}

		// The peer's own orientation, in the same terms the user is editing —
		// taken from its PRE-DRAG value so a running preview does not compound
		// (each frame would otherwise re-read the angle the last frame wrote).
		pe := engine.quat_to_euler_xyz(_rotation_peer_start[ph])
		for i in 0 ..< 3 {
			if moved[i] do pe[i] = euler_after[i]
		}
		new_rot := engine.quat_from_euler_xyz(pe.x, pe.y, pe.z)

		if !commit && new_rot == pt.rotation do continue
		if commit && new_rot == _rotation_peer_start[ph] do continue

		if commit {
			// Rewind to the pre-drag value so edit_begin captures the real "old",
			// then apply — otherwise undo restores where the preview left it.
			start := _rotation_peer_start[ph]
			pt.rotation = start
			e := undo.edit_begin(peer.handle, &pt.rotation, typeid_of([4]f32), "Rotation")
			pt.rotation = new_rot
			undo.edit_end(&e)
		} else {
			pt.rotation = new_rot
		}
	}
	// The commit ends the drag, so the next one starts from fresh values.
	if commit do _rotation_peer_start_clear()
	inspector.mark_inspector_changed()
}

// Drives the Rotation ROW the way the inspector does, for tests.
rotation_row_drive_for_test :: proc(
	tH: engine.Transform_Handle,
	write_euler: proc(euler: ^[3]f32),
	commit := false,
) {
	w := engine.ctx_world()
	if w == nil do return
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	euler_before := _rotation_cache_sync(tH, t)
	write_euler(&_inspector_euler_cache)

	if _inspector_euler_cache != euler_before {
		t.rotation = engine.quat_from_euler_xyz(
			_inspector_euler_cache.x, _inspector_euler_cache.y, _inspector_euler_cache.z)
		_inspector_euler_quat_src = t.rotation
	}

	moved := false
	for i in 0 ..< 3 {
		if euler_before[i] != _inspector_euler_cache[i] {
			_rotation_moved_axes[i] = true
			moved = true
		}
	}
	if commit || moved {
		multi_offset := uintptr(uintptr(rawptr(&t.rotation)) - uintptr(t))
		_rotation_apply_to_peers(t, multi_offset, euler_before,
			_inspector_euler_cache, _rotation_moved_axes, commit)
	}
	if commit do _rotation_moved_axes = {}
}

// Refreshes the euler cache for `tH` and returns the pre-edit angles.
@(private)
_rotation_cache_sync :: proc(tH: engine.Transform_Handle, t: ^engine.Transform) -> [3]f32 {
	if _inspector_euler_owner != tH {
		_inspector_euler_cache = engine.quat_to_euler_xyz(t.rotation)
		_inspector_euler_quat_src = t.rotation
		_inspector_euler_owner = tH
		return _inspector_euler_cache
	}
	if _inspector_euler_quat_src != t.rotation {
		round := engine.quat_from_euler_xyz(
			_inspector_euler_cache.x, _inspector_euler_cache.y, _inspector_euler_cache.z)
		if _quat_approx_equal(round, t.rotation) {
			_inspector_euler_quat_src = t.rotation
		} else {
			_inspector_euler_cache = engine.quat_to_euler_xyz(t.rotation)
			_inspector_euler_quat_src = t.rotation
		}
	}
	return _inspector_euler_cache
}

// The euler cache's current spelling, so a test can assert the boxes stay
// continuous rather than flipping to a gimbal-equivalent representation.
rotation_euler_cache_for_test :: proc() -> [3]f32 {
	return _inspector_euler_cache
}

// Two quaternions naming the same orientation, within float tolerance. q and -q
// are the same rotation, so the sign is normalized before comparing.
@(private)
_inspector_rot_drag: undo.Edit_Scope

@(private = "file")
_draw_vec3_row_shim :: proc(ptr: rawptr, _tid: typeid, lbl: cstring) {
	if d := inspector.resolve_property_drawer(typeid_of(^[3]f32)); d != nil {
		d(ptr, typeid_of(^[3]f32), lbl)
	}
}

@(private)
_wrap_transform_field_override :: proc(
	tH:         engine.Transform_Handle,
	t:          ^engine.Transform,
	field_ptr:  rawptr,
	field_name: string,
	field_tid:  typeid,
	drawer:     proc(ptr: rawptr, tid: typeid, label: cstring),
	drawer_tid: typeid,
	label:      cstring,
) {
	_ = tH
	_ = drawer
	_ = drawer_tid
	if t == nil || field_ptr == nil do return
	offset := uintptr(uintptr(field_ptr) - uintptr(t))

	if field_tid == typeid_of([3]f32) {
		base_v := (cast(^[3]f32)field_ptr)^
		for peer in inspector.multi_peers() {
			if peer.base == nil do continue
			pv := cast(^[3]f32)(uintptr(peer.base) + offset)
			if pv^ != base_v {
				inspector.current_field_mixed = true
				break
			}
		}
	}

	prev_path := inspector.field_edit_set_path(field_name)
	defer inspector.field_edit_set_path(prev_path)

	committed := inspector.field_edit_row(field_ptr, field_tid, offset, string(label), _draw_vec3_row_shim, label)
	if committed {
		inspector.record_nested_override(field_ptr, field_tid, field_name, true)
	}
}

@(private)
_wrap_transform_rotation_override :: proc(
	tH:     engine.Transform_Handle,
	t:      ^engine.Transform,
	drawer: proc(ptr: rawptr, tid: typeid, label: cstring),
) {
	if t == nil || drawer == nil do return
	prev_euler := _rotation_cache_sync(tH, t)

	for peer in inspector.multi_peers() {
		if peer.base == nil do continue
		pt := cast(^engine.Transform)peer.base
		if !_quat_approx_equal(pt.rotation, t.rotation) {
			inspector.current_field_mixed = true
			break
		}
	}

	im.BeginGroup()
	drawer(&_inspector_euler_cache, typeid_of(^[3]f32), "Rotation")
	im.EndGroup()
	inspector.multi_clear_mixed()

	activated := im.IsItemActivated()
	committed := im.IsItemDeactivatedAfterEdit()
	if activated && !_inspector_rot_drag.active {
		_inspector_rot_drag = undo.edit_begin(tH, &t.rotation, typeid_of([4]f32), "Rotation")
	}

	euler_changed := _inspector_euler_cache != prev_euler
	if euler_changed {
		t.rotation = engine.quat_from_euler_xyz(
			_inspector_euler_cache.x, _inspector_euler_cache.y, _inspector_euler_cache.z,
		)
		_inspector_euler_quat_src = t.rotation
		for i in 0 ..< 3 {
			if _inspector_euler_cache[i] != prev_euler[i] {
				_rotation_moved_axes[i] = true
			}
		}
		inspector.mark_inspector_changed()
	}

	if committed && _inspector_rot_drag.active {
		undo.edit_end(&_inspector_rot_drag)
	}

	if committed || euler_changed {
		multi_offset := uintptr(uintptr(rawptr(&t.rotation)) - uintptr(t))
		_rotation_apply_to_peers(t, multi_offset, prev_euler, _inspector_euler_cache, _rotation_moved_axes, committed)
	}
	if committed {
		inspector.record_nested_override(&t.rotation, typeid_of([4]f32), "rotation", true)
		for peer in inspector.multi_peers() {
			if peer.base == nil do continue
			pt := cast(^engine.Transform)peer.base
			inspector.record_peer_override(peer, &pt.rotation, typeid_of([4]f32), "rotation")
		}
		_rotation_moved_axes = {}
	}
}

@(private)
_quat_approx_equal :: proc(a, b: [4]f32) -> bool {
	dot := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	return abs(abs(dot) - 1) < 1e-5
}
