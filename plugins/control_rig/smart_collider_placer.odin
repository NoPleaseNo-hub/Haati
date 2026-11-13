package control_rig

// Smart Collider Placer & Anatomical Ray-Traced Rig Auto-Tools.
// Inspired by Unreal Engine's PhAT (Physics Asset Editor) + Topographic Surface Ray-Tracing:
// 1. Hand Box Ray-Tracer: Recognizes wrist start (`left_hand` / `right_hand`), derives palm/finger axes,
//    and fires orthogonal line traces past the wrist to fit an oriented BoxCollider (`size`, `center`, `rotation`).
// 2. Planted Foot Ray-Tracer: Ignores misleading ankle bone rest rotations, aligns flat with the floor (XZ),
//    and fires vertical sole traces + heel-to-toe horizontal traces to fit a floor-flush BoxCollider.
// 3. Adaptive Spinal Column & Radial Limb Cross-Section Tracer: Walks variable-length spine chains (`pelvis`..`head`)
//    and limb segments, firing radial cross-section traces while keeping the chest collider slim on the ribcage.
// 4. Topographic Breast "Hill" Tracer & Recursive Weight Auto-Rigger: Virtually flattens the ribcage baseline,
//    detects bilateral breast hills + gravity sag vectors, spawns `breast_l` / `breast_r` + `SpringBone` +
//    dedicated `SphereCollider`s, and performs multi-pass recursive topological weight distribution.
// 5. Async Multi-Pass Execution: Can run staged across frames in the editor so high-poly meshes never freeze UI.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import engine "haati:engine"
import gfx "haati:engine/gfx"
import cad_csg "haati:packages/cad_csg"
import physics3d "haati:packages/physics3d"

@(private = "file")
_quat_len2 :: #force_inline proc(q: [4]f32) -> f32 {
	return q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
}

@(private = "file")
_quat_native_len2 :: #force_inline proc(q: quaternion128) -> f32 {
	return q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
}

// =============================================================================
// ASYNC MULTI-PASS RIG AUTO-TOOL STATE
// =============================================================================

Smart_Rig_Async_Stage :: enum {
	Idle,
	Prepare_Bind_Pose,
	Trace_Spine_And_Torso,
	Trace_Arms_And_Hands,
	Trace_Legs_And_Feet,
	Trace_Breast_Hills_And_Weights,
	Completed,
}

Smart_Rig_Async_State :: struct {
	active:               bool,
	stage:                Smart_Rig_Async_Stage,
	run_colliders:        bool,
	run_breasts:          bool,
	has_breasts:          bool, // Whether the character has breasts (flattens chest collider baseline & fits breast SphereColliders)
	use_heatmap_bounds:   bool, // Uses vertex skin weight heatmap to anchor collider start, end, and volume centroid
	attach_breast_colls:  bool,
	multipass_count:      int, // 1..4 passes (default 3)
	recursion_passes:     int, // 1..6 weight smoothing passes (default 3)
	char_h:               engine.Transform_Handle,
	progress:             f32,
	status_text:          string,
	last_summary:         string,
	last_summary_buf:     [256]u8,
	last_tick_frame:      u64,
	colliders_fitted:     int,
	breast_verts_painted: int,
	left_hill_peak_mm:    f32,
	right_hill_peak_mm:   f32,
	left_sag_deg:         f32,
	right_sag_deg:        f32,
}

smart_rig_async_state: Smart_Rig_Async_State = {
	has_breasts         = false,
	use_heatmap_bounds  = true,
	multipass_count     = 3,
	recursion_passes    = 3,
	attach_breast_colls = true,
}

smart_rig_async_cancel :: proc() {
	smart_rig_async_state.active      = false
	smart_rig_async_state.stage       = .Idle
	smart_rig_async_state.progress    = 0.0
	smart_rig_async_state.status_text = "Cancelled."
}

smart_rig_async_start :: proc(char_h: engine.Transform_Handle, fit_colliders: bool, rig_breasts: bool) {
	if char_h == {} do return
	if rig_breasts {
		smart_rig_async_state.has_breasts = true
	}
	smart_rig_async_state.active        = true
	smart_rig_async_state.stage         = .Prepare_Bind_Pose
	smart_rig_async_state.run_colliders = fit_colliders
	smart_rig_async_state.run_breasts   = rig_breasts || (fit_colliders && smart_rig_async_state.has_breasts)
	smart_rig_async_state.char_h        = char_h
	smart_rig_async_state.progress      = 0.05
	smart_rig_async_state.status_text   = "Stage 1/5: Preparing bind pose & posed mesh surface..."
	if smart_rig_async_state.multipass_count < 1 do smart_rig_async_state.multipass_count = 3
	if smart_rig_async_state.recursion_passes < 1 do smart_rig_async_state.recursion_passes = 3
}

@(update={order=6})
smart_rig_async_tick :: proc(_: f32) {
	st := &smart_rig_async_state
	if !st.active do return
	if gfx.frame_index != 0 && st.last_tick_frame == gfx.frame_index do return
	st.last_tick_frame = gfx.frame_index

	w := engine.ctx_world()
	if w == nil || st.char_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(st.char_h)) {
		st.active = false
		st.stage = .Idle
		st.status_text = "Cancelled (character invalid)."
		return
	}

	adm := _resolve_character_adm(st.char_h)
	bones: Humanoid_Bones
	skeleton_bind_humanoid(&bones, st.char_h)

	switch st.stage {
	case .Idle:
		st.active = false

	case .Prepare_Bind_Pose:
		if adm != nil {
			_, _, _, _ = armature_ensure_posed_world_geometry(adm)
		}
		st.colliders_fitted = 0
		if st.run_colliders {
			st.stage = .Trace_Spine_And_Torso
			st.progress = 0.22
			st.status_text = "Stage 2/5: Tracing spinal column & flattened ribcage cross-sections..."
		} else if st.run_breasts {
			st.stage = .Trace_Breast_Hills_And_Weights
			st.progress = 0.65
			st.status_text = "Stage 5/5: Tracing topographic breast hills & recursive weights..."
		} else {
			st.stage = .Completed
		}

	case .Trace_Spine_And_Torso:
		st.colliders_fitted += _smart_trace_fit_spine_and_head(st.char_h, adm, &bones, st.multipass_count, st.has_breasts)
		st.stage = .Trace_Arms_And_Hands
		st.progress = 0.45
		st.status_text = "Stage 3/5: Tracing arms & fitting oriented wrist-to-finger hand boxes..."

	case .Trace_Arms_And_Hands:
		st.colliders_fitted += _smart_trace_fit_arms_and_hands(st.char_h, adm, &bones, st.multipass_count)
		st.stage = .Trace_Legs_And_Feet
		st.progress = 0.70
		st.status_text = "Stage 4/5: Tracing legs & floor-planted sole/heel/toe foot boxes..."

	case .Trace_Legs_And_Feet:
		st.colliders_fitted += _smart_trace_fit_legs_and_feet(st.char_h, adm, &bones, st.multipass_count)
		if st.run_breasts && adm != nil {
			st.stage = .Trace_Breast_Hills_And_Weights
			st.progress = 0.88
			st.status_text = "Stage 5/5: Cutting virtual flat chest to trace breast hills & recursive weights..."
		} else {
			st.stage = .Completed
		}

	case .Trace_Breast_Hills_And_Weights:
		if adm != nil {
			_, _, v_cnt, ok_b := smart_auto_rig_breasts_via_line_traces(
				adm,
				attach_colliders = st.attach_breast_colls,
				recursion_passes = st.recursion_passes,
			)
			st.breast_verts_painted = v_cnt
			if ok_b && st.attach_breast_colls {
				st.colliders_fitted += 2
			}
		}
		st.stage = .Completed

	case .Completed:
		st.active = false
		st.progress = 1.0
		msg: string
		if st.run_colliders && st.run_breasts {
			msg = fmt.bprintf(
				st.last_summary_buf[:],
				"Auto-Tool Complete: %d colliders fitted | Breasts rigged (%d verts, peak %.0f/%.0f mm, sag %.0f°/%.0f°)",
				st.colliders_fitted,
				st.breast_verts_painted,
				st.left_hill_peak_mm,
				st.right_hill_peak_mm,
				st.left_sag_deg,
				st.right_sag_deg,
			)
		} else if st.run_colliders {
			msg = fmt.bprintf(st.last_summary_buf[:], "Auto-Fit Complete: %d heatmap + ray-traced colliders fitted.", st.colliders_fitted)
		} else {
			msg = fmt.bprintf(
				st.last_summary_buf[:],
				"Breast Hill Auto-Rig Complete: %d vertices weighted (Peak L:%.0fmm R:%.0fmm, Sag L:%.0f° R:%.0f°)",
				st.breast_verts_painted,
				st.left_hill_peak_mm,
				st.right_hill_peak_mm,
				st.left_sag_deg,
				st.right_sag_deg,
			)
		}
		st.last_summary = msg
		st.status_text  = msg
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
}

// =============================================================================
// GEOMETRIC & RAY-TRACING HELPERS
// =============================================================================

@(private = "file")
_resolve_character_adm :: proc(char_h: engine.Transform_Handle) -> ^ArmatureDeformedMesh {
	w := engine.ctx_world()
	if w == nil || char_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(char_h)) do return nil

	if _, adm := engine.transform_get_comp(char_h, ArmatureDeformedMesh); adm != nil {
		return adm
	}
	t := engine.pool_get(&w.transforms, engine.Handle(char_h))
	if t != nil {
		if t.parent.handle != {} {
			if _, padm := engine.transform_get_comp(engine.Transform_Handle(t.parent.handle), ArmatureDeformedMesh); padm != nil {
				return padm
			}
		}
		for ch in t.children {
			if _, cadm := engine.transform_get_comp(engine.Transform_Handle(ch.handle), ArmatureDeformedMesh); cadm != nil {
				return cadm
			}
		}
	}
	return nil
}

@(private = "file")
_ray_intersect_tri :: #force_inline proc(
	orig, dir: [3]f32,
	v0, v1, v2: [3]f32,
) -> (t: f32, hit: bool) {
	eps :: f32(1e-6)
	e1 := v1 - v0
	e2 := v2 - v0
	h := linalg.cross(dir, e2)
	a := linalg.dot(e1, h)
	if a > -eps && a < eps do return 0, false
	f := 1.0 / a
	s := orig - v0
	u := f * linalg.dot(s, h)
	if u < 0.0 || u > 1.0 do return 0, false
	q := linalg.cross(s, e1)
	v := f * linalg.dot(dir, q)
	if v < 0.0 || u + v > 1.0 do return 0, false
	t_val := f * linalg.dot(e2, q)
	if t_val > eps {
		return t_val, true
	}
	return 0, false
}

// Collects all joint indices in `adm.joints` belonging to `root_bone_h` and its transform subtree,
// stopping recursion at `stop_child_h` (if provided).
@(private = "file")
_collect_subtree_joint_indices :: proc(
	adm:          ^ArmatureDeformedMesh,
	root_bone_h:  engine.Transform_Handle,
	stop_child_h: engine.Transform_Handle = {},
	include_children: bool = true,
	allocator := context.temp_allocator,
) -> [dynamic]int {
	out := make([dynamic]int, 0, 16, allocator)
	if adm == nil || root_bone_h == {} do return out
	w := engine.ctx_world()
	if w == nil do return out

	queue := make([dynamic]engine.Transform_Handle, 0, 16, context.temp_allocator)
	append(&queue, root_bone_h)

	for len(queue) > 0 {
		curr := pop_front(&queue)
		if curr == {} || !engine.pool_valid(&w.transforms, engine.Handle(curr)) do continue
		j_idx := armature_get_bone_joint_index(adm, curr)
		if j_idx >= 0 {
			already := false
			for existing in out {
				if existing == j_idx {
					already = true
					break
				}
			}
			if !already do append(&out, j_idx)
		}
		if !include_children do break
		t := engine.pool_get(&w.transforms, engine.Handle(curr))
		if t == nil do continue
		for ch in t.children {
			ch_h := engine.Transform_Handle(ch.handle)
			if ch_h == stop_child_h do continue
			append(&queue, ch_h)
		}
	}
	return out
}

@(private = "file")
_vertex_weight_for_joints :: #force_inline proc(sv: engine.Mesh_Skin_Vertex, joint_indices: []int) -> f32 {
	sum: f32 = 0.0
	for k in 0 ..< 4 {
		wgt := sv.weights[k]
		if wgt <= 0.001 do continue
		ji := int(sv.joints[k])
		for target_j in joint_indices {
			if ji == target_j {
				sum += wgt
				break
			}
		}
	}
	return sum
}

// Pre-filters mesh triangles whose vertices either carry skin weight on `joint_indices` OR fall within `[aabb_min, aabb_max]`.
@(private = "file")
_collect_region_triangles :: proc(
	world_verts:   []gfx.Vertex,
	indices:       []u32,
	skin:          []engine.Mesh_Skin_Vertex,
	joint_indices: []int,
	aabb_min:      [3]f32,
	aabb_max:      [3]f32,
	min_skin_w:    f32 = 0.12,
	allocator := context.temp_allocator,
) -> [dynamic][3][3]f32 {
	tris := make([dynamic][3][3]f32, 0, 256, allocator)
	tri_count := len(indices) / 3
	has_skin := len(skin) == len(world_verts) && len(joint_indices) > 0

	for ti in 0 ..< tri_count {
		i0 := int(indices[ti * 3 + 0])
		i1 := int(indices[ti * 3 + 1])
		i2 := int(indices[ti * 3 + 2])
		if i0 >= len(world_verts) || i1 >= len(world_verts) || i2 >= len(world_verts) do continue

		p0 := world_verts[i0].position
		p1 := world_verts[i1].position
		p2 := world_verts[i2].position

		t_min := [3]f32{min(p0.x, min(p1.x, p2.x)), min(p0.y, min(p1.y, p2.y)), min(p0.z, min(p1.z, p2.z))}
		t_max := [3]f32{max(p0.x, max(p1.x, p2.x)), max(p0.y, max(p1.y, p2.y)), max(p0.z, max(p1.z, p2.z))}

		in_aabb := !(t_max.x < aabb_min.x || t_min.x > aabb_max.x ||
		             t_max.y < aabb_min.y || t_min.y > aabb_max.y ||
		             t_max.z < aabb_min.z || t_min.z > aabb_max.z)
		if !in_aabb do continue

		if has_skin && min_skin_w > 0.0 {
			w0 := _vertex_weight_for_joints(skin[i0], joint_indices)
			w1 := _vertex_weight_for_joints(skin[i1], joint_indices)
			w2 := _vertex_weight_for_joints(skin[i2], joint_indices)
			if max(w0, max(w1, w2)) < min_skin_w do continue
		}

		append(&tris, [3][3]f32{p0, p1, p2})
	}

	// Fallback if skin weights weren't standard: use pure spatial AABB triangles
	if len(tris) < 8 && has_skin && min_skin_w > 0.0 {
		for ti in 0 ..< tri_count {
			i0 := int(indices[ti * 3 + 0])
			i1 := int(indices[ti * 3 + 1])
			i2 := int(indices[ti * 3 + 2])
			if i0 >= len(world_verts) || i1 >= len(world_verts) || i2 >= len(world_verts) do continue
			p0 := world_verts[i0].position
			p1 := world_verts[i1].position
			p2 := world_verts[i2].position
			t_min := [3]f32{min(p0.x, min(p1.x, p2.x)), min(p0.y, min(p1.y, p2.y)), min(p0.z, min(p1.z, p2.z))}
			t_max := [3]f32{max(p0.x, max(p1.x, p2.x)), max(p0.y, max(p1.y, p2.y)), max(p0.z, max(p1.z, p2.z))}
			if t_max.x < aabb_min.x || t_min.x > aabb_max.x ||
			   t_max.y < aabb_min.y || t_min.y > aabb_max.y ||
			   t_max.z < aabb_min.z || t_min.z > aabb_max.z {
				continue
			}
			append(&tris, [3][3]f32{p0, p1, p2})
		}
	}
	return tris
}

// =============================================================================
// FLOOR ROTATION & PRIMITIVE COLLIDER UPDATERS
// =============================================================================

// Calculates the local rotation quaternion needed so that a collider on bone_h
// has its bottom parallel and flat with the world horizontal ground plane (XZ).
calculate_flat_floor_rotation :: proc(bone_h: engine.Transform_Handle) -> [4]f32 {
	if bone_h == {} do return {0, 0, 0, 1}
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return {0, 0, 0, 1}

	tw := engine.transform_world(bone_h)
	q := engine.quat_to_native(tw.rotation)
	if _quat_native_len2(q) < 1e-4 do return {0, 0, 0, 1}
	q = linalg.normalize(q)

	// Bone forward in world space
	bone_fwd := linalg.quaternion_mul_vector3(q, [3]f32{0, 0, 1})
	bone_fwd.y = 0
	fwd_len := linalg.length(bone_fwd)
	if fwd_len < 1e-4 {
		// If bone forward was pointing purely vertically, try X axis
		bone_fwd = linalg.quaternion_mul_vector3(q, [3]f32{1, 0, 0})
		bone_fwd.y = 0
		fwd_len = linalg.length(bone_fwd)
		if fwd_len < 1e-4 do return {0, 0, 0, 1}
	}
	bone_fwd /= fwd_len

	// Right vector in horizontal plane
	right := linalg.cross([3]f32{0, 1, 0}, bone_fwd)
	r_len := linalg.length(right)
	if r_len < 1e-4 do return {0, 0, 0, 1}
	right /= r_len

	rot_mat := matrix[3, 3]f32{
		right.x, 0, bone_fwd.x,
		right.y, 1, bone_fwd.y,
		right.z, 0, bone_fwd.z,
	}
	flat_world_q := linalg.quaternion_from_matrix3(rot_mat)
	if _quat_native_len2(flat_world_q) < 1e-4 do return {0, 0, 0, 1}
	flat_world_q = linalg.normalize(flat_world_q)

	inv_bone := linalg.quaternion_inverse(q)
	local_q := inv_bone * flat_world_q
	if _quat_native_len2(local_q) < 1e-4 do return {0, 0, 0, 1}
	norm_q := linalg.normalize(local_q)
	out_q := engine.quat_from_native(norm_q)
	if math.is_nan(out_q.x) || math.is_nan(out_q.y) || math.is_nan(out_q.z) || math.is_nan(out_q.w) {
		return {0, 0, 0, 1}
	}
	return out_q
}

@(private = "file")
_attach_or_update_capsule :: proc(bone_h: engine.Transform_Handle, radius, height: f32, dir: physics3d.Capsule_Direction, center: [3]f32, rotation: [4]f32 = {0, 0, 0, 1}) {
	if bone_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	_, cap := engine.transform_get_comp(bone_h, physics3d.CapsuleCollider)
	if cap == nil {
		_, raw := engine.transform_add_comp(bone_h, .CapsuleCollider)
		cap = cast(^physics3d.CapsuleCollider)raw
	}
	if cap != nil {
		cap.radius = max(0.02, radius)
		cap.height = max(cap.radius * 2.0, height)
		cap.direction = dir
		cap.center = center
		clean_rot := rotation
		if clean_rot == {} || _quat_len2(clean_rot) < 1e-4 do clean_rot = {0, 0, 0, 1}
		cap.rotation = clean_rot
		cap.density = 1.0
		cap.friction = 0.6
	}
}

@(private = "file")
_attach_limb_capsule :: proc(bone_h: engine.Transform_Handle, child_h: engine.Transform_Handle, radius: f32, default_len: f32 = 0.28) {
	if bone_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	tw := engine.transform_world(bone_h)
	s := [3]f32{abs(tw.scale.x), abs(tw.scale.y), abs(tw.scale.z)}
	if s.x < 0.001 do s.x = 1
	if s.y < 0.001 do s.y = 1
	if s.z < 0.001 do s.z = 1

	if child_h != {} && engine.pool_valid(&w.transforms, engine.Handle(child_h)) {
		p0 := engine.transform_world_position(bone_h)
		p1 := engine.transform_world_position(child_h)
		d := p1 - p0
		dist := linalg.length(d)
		if dist > 0.02 {
			// Convert child vector into bone's local coordinate frame
			rot := engine.transform_world_rotation(bone_h)
			q_native := engine.quat_to_native(rot)
			inv_rot := linalg.quaternion_inverse(q_native)
			local_d := linalg.quaternion128_mul_vector3(inv_rot, d)

			ax := abs(local_d.x)
			ay := abs(local_d.y)
			az := abs(local_d.z)

			dir: physics3d.Capsule_Direction = .Y_Axis
			if ax >= ay && ax >= az {
				dir = .X_Axis
			} else if az >= ax && az >= ay {
				dir = .Z_Axis
			} else {
				dir = .Y_Axis
			}

			center := (local_d * 0.5) / s
			height := max(dist, radius * 2.0) / s.y
			rad := radius / max(s.x, s.z)
			_attach_or_update_capsule(bone_h, rad, height, dir, center)
			return
		}
	}

	// Fallback when child bone is missing or coincident
	rad := radius / max(s.x, s.z)
	h := default_len / s.y
	_attach_or_update_capsule(bone_h, rad, h, .Y_Axis, [3]f32{0, -default_len * 0.5, 0} / s)
}

@(private = "file")
_attach_or_update_box :: proc(bone_h: engine.Transform_Handle, size, center: [3]f32, rotation: [4]f32 = {0, 0, 0, 1}) {
	if bone_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	_, box := engine.transform_get_comp(bone_h, physics3d.BoxCollider)
	if box == nil {
		_, raw := engine.transform_add_comp(bone_h, .BoxCollider)
		box = cast(^physics3d.BoxCollider)raw
	}
	if box != nil {
		box.size = size
		box.center = center
		clean_rot := rotation
		if clean_rot == {} || _quat_len2(clean_rot) < 1e-4 do clean_rot = {0, 0, 0, 1}
		box.rotation = clean_rot
		box.density = 1.0
		box.friction = 0.7
	}
}

@(private = "file")
_attach_or_update_sphere :: proc(bone_h: engine.Transform_Handle, radius: f32, center: [3]f32) {
	if bone_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	_, sph := engine.transform_get_comp(bone_h, physics3d.SphereCollider)
	if sph == nil {
		_, raw := engine.transform_add_comp(bone_h, .SphereCollider)
		sph = cast(^physics3d.SphereCollider)raw
	}
	if sph != nil {
		sph.radius = radius
		sph.center = center
		sph.density = 1.0
		sph.friction = 0.5
	}
}

// =============================================================================
// 1. RAY-TRACED LIMB & VARIABLE SPINAL COLUMN CAPSULE FITTER
// =============================================================================

// Fires radial cross-section rays perpendicular to bone segment `p0 -> p1` across `passes` slices
// to measure the true anatomical radius of a limb or spine segment.
// When `exclude_anterior_hills` is true (used for chest/ribcage), rays hitting the bilateral
// anterior breast hill regions are clamped to the sternum/lateral ribcage baseline so the
// chest collider fits the flattened ribcage rather than ballooning over the breasts!
@(private = "file")
_trace_segment_radius :: proc(
	p0, p1:                 [3]f32,
	tris:                   [][3][3]f32,
	char_right, char_fwd:   [3]f32,
	default_radius:         f32,
	min_r, max_r:           f32,
	passes:                 int = 3,
	exclude_anterior_hills: bool = false,
) -> (fitted_radius: f32, center_shift: [3]f32) {
	if len(tris) < 4 do return default_radius, {}

	seg := p1 - p0
	seg_len := linalg.length(seg)
	if seg_len < 0.015 do return default_radius, {}
	axis := seg / seg_len

	// Build orthonormal cross-section basis (u, v) perpendicular to segment axis
	u := linalg.cross(axis, char_fwd)
	if linalg.length2(u) < 1e-4 {
		u = linalg.cross(axis, [3]f32{0, 0, 1})
		if linalg.length2(u) < 1e-4 do u = linalg.cross(axis, [3]f32{1, 0, 0})
	}
	u = linalg.normalize(u)
	v := linalg.normalize(linalg.cross(axis, u))

	num_slices := clamp(passes + 1, 2, 5)
	num_angles :: 12
	search_dist := max_r * 2.2

	samples := make([dynamic]f32, 0, num_slices * num_angles, context.temp_allocator)
	shift_accum := [3]f32{0, 0, 0}
	shift_count := 0

	for s_idx in 0 ..< num_slices {
		t_slice := (f32(s_idx) + 0.5) / f32(num_slices)
		slice_origin := math.lerp(p0, p1, t_slice)

		// If excluding anterior breast hills, measure the midline sternum depth first
		sternum_hit_d: f32 = max_r
		if exclude_anterior_hills {
			orig_front := slice_origin + char_fwd * search_dist
			for tri in tris {
				if t_hit, ok := _ray_intersect_tri(orig_front, -char_fwd, tri[0], tri[1], tri[2]); ok {
					d_center := search_dist - t_hit
					if d_center > min_r * 0.4 && d_center < sternum_hit_d {
						sternum_hit_d = d_center
					}
				}
			}
		}

		for a_idx in 0 ..< num_angles {
			angle := (f32(a_idx) / f32(num_angles)) * (2.0 * math.PI)
			rad_dir := u * math.cos(angle) + v * math.sin(angle)

			// Cast inward from outside the limb toward slice_origin
			ray_orig := slice_origin + rad_dir * search_dist
			ray_dir  := -rad_dir

			best_d: f32 = -1.0
			for tri in tris {
				if t_hit, ok := _ray_intersect_tri(ray_orig, ray_dir, tri[0], tri[1], tri[2]); ok {
					d_from_axis := search_dist - t_hit
					if d_from_axis >= min_r * 0.35 && d_from_axis <= max_r * 1.35 {
						if d_from_axis > best_d {
							best_d = d_from_axis
						}
					}
				}
			}

			if best_d > 0.0 {
				if exclude_anterior_hills {
					// Check if this radial direction points into the bilateral anterior chest hill
					fwd_align := linalg.dot(rad_dir, char_fwd)
					lat_align := abs(linalg.dot(rad_dir, char_right))
					if fwd_align > 0.35 && lat_align > 0.18 && sternum_hit_d < max_r {
						best_d = min(best_d, sternum_hit_d * 1.04)
					}
				}
				append(&samples, clamp(best_d, min_r, max_r))
			}
		}

		// Measure front vs back offset to center torso capsules on the actual body volume
		orig_f := slice_origin + char_fwd * search_dist
		orig_b := slice_origin - char_fwd * search_dist
		d_front: f32 = -1.0
		d_back:  f32 = -1.0
		for tri in tris {
			if tf, okf := _ray_intersect_tri(orig_f, -char_fwd, tri[0], tri[1], tri[2]); okf {
				df := search_dist - tf
				if df > 0.01 && df < max_r * 1.4 && df > d_front do d_front = df
			}
			if tb, okb := _ray_intersect_tri(orig_b, char_fwd, tri[0], tri[1], tri[2]); okb {
				db := search_dist - tb
				if db > 0.01 && db < max_r * 1.4 && db > d_back do d_back = db
			}
		}
		if d_front > 0 && d_back > 0 {
			if exclude_anterior_hills && sternum_hit_d < max_r {
				d_front = min(d_front, sternum_hit_d)
			}
			mid_f := 0.5 * (d_front - d_back)
			shift_accum += char_fwd * clamp(mid_f, -0.06, 0.06)
			shift_count += 1
		}
	}

	if len(samples) == 0 do return default_radius, {}
	slice.sort(samples[:])
	// Use 60th percentile so capsule hugs the limb tightly without outlier spikes
	idx := clamp(int(f32(len(samples) - 1) * 0.60), 0, len(samples) - 1)
	fitted_radius = clamp(samples[idx], min_r, max_r)
	if shift_count > 0 {
		center_shift = shift_accum / f32(shift_count)
	}
	return fitted_radius, center_shift
}

// Uses the bone's skin weight heatmap (`w >= 0.25`) to refine where the collider starts (`p_start`),
// where it ends (`p_end`), and its cross-sectional volume centroid (`perp_shift`), rather than relying
// solely on raw bone joint pivots!
@(private = "file")
_compute_heatmap_segment_bounds :: proc(
	p0, p1:                 [3]f32,
	world_verts:            []gfx.Vertex,
	skin:                   []engine.Mesh_Skin_Vertex,
	joint_indices:          []int,
	char_right, char_fwd:   [3]f32,
	exclude_anterior_hills: bool = false,
) -> (p_start, p_end: [3]f32, perp_shift: [3]f32, ok: bool) {
	if !smart_rig_async_state.use_heatmap_bounds do return p0, p1, {}, false
	if len(world_verts) == 0 || len(skin) != len(world_verts) || len(joint_indices) == 0 {
		return p0, p1, {}, false
	}

	seg := p1 - p0
	nom_len := linalg.length(seg)
	if nom_len < 0.02 do return p0, p1, {}, false
	axis := seg / nom_len

	t_min: f32 =  1e9
	t_max: f32 = -1e9
	weighted_pos_sum := [3]f32{0, 0, 0}
	weight_sum: f32  = 0.0
	count := 0

	// Allow heatmap to shift start/end within sensible anatomical tolerances around [0, nom_len]
	lo_limit := -0.30 * nom_len
	hi_limit :=  1.25 * nom_len

	for vi in 0 ..< len(world_verts) {
		wgt := _vertex_weight_for_joints(skin[vi], joint_indices)
		if wgt < 0.25 do continue

		vp := world_verts[vi].position
		rel := vp - p0
		t_proj := linalg.dot(rel, axis)
		if t_proj < lo_limit || t_proj > hi_limit do continue

		// Reject stray vertices far outside limb/torso radial bounds
		perp_vec := rel - axis * t_proj
		if linalg.length2(perp_vec) > 0.32 * 0.32 do continue

		// If excluding anterior breast hills on the chest bone, don't let breast vertices pull the chest centroid forward
		if exclude_anterior_hills {
			fwd_d := linalg.dot(perp_vec, char_fwd)
			lat_d := abs(linalg.dot(perp_vec, char_right))
			if fwd_d > 0.08 && lat_d > 0.03 {
				vp -= char_fwd * (fwd_d - 0.08)
				rel = vp - p0
			}
		}

		t_min = min(t_min, t_proj)
		t_max = max(t_max, t_proj)
		w2 := wgt * wgt
		weighted_pos_sum += vp * w2
		weight_sum       += w2
		count            += 1
	}

	if count < 6 || weight_sum <= 1e-5 || (t_max - t_min) < nom_len * 0.35 {
		return p0, p1, {}, false
	}

	// Blend bone segment endpoints with heatmap axial span (70% heatmap span, 30% joint pivot)
	final_t0 := math.lerp(f32(0.0), t_min, f32(0.70))
	final_t1 := math.lerp(nom_len,  t_max, f32(0.70))
	if final_t1 - final_t0 < nom_len * 0.50 {
		final_t0 = 0.0
		final_t1 = nom_len
	}

	heat_centroid := weighted_pos_sum / weight_sum
	rel_c := heat_centroid - p0
	perp_c := rel_c - axis * linalg.dot(rel_c, axis)
	// Clamp perpendicular heatmap centroid shift so it stays anatomically centered
	perp_len := linalg.length(perp_c)
	if perp_len > 0.065 {
		perp_c = (perp_c / perp_len) * 0.065
	}

	return p0 + axis * final_t0, p0 + axis * final_t1, perp_c, true
}

@(private = "file")
_trace_fit_limb_capsule :: proc(
	bone_h, child_h:      engine.Transform_Handle,
	adm:                  ^ArmatureDeformedMesh,
	world_verts:          []gfx.Vertex,
	indices:              []u32,
	skin:                 []engine.Mesh_Skin_Vertex,
	char_right, char_fwd: [3]f32,
	default_radius:       f32,
	min_r, max_r:         f32,
	default_len:          f32,
	passes:               int,
	exclude_hills:        bool = false,
	is_torso:             bool = false,
	is_pelvis_seg:        bool = false,
) {
	if bone_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	bone_origin := engine.transform_world_position(bone_h)
	p0 := bone_origin
	p1 := p0 + [3]f32{0, -default_len, 0}
	if child_h != {} && engine.pool_valid(&w.transforms, engine.Handle(child_h)) {
		p1 = engine.transform_world_position(child_h)
	}

	radius := default_radius
	world_shift := [3]f32{0, 0, 0}

	if len(world_verts) >= 3 && len(indices) >= 3 {
		j_list := _collect_subtree_joint_indices(adm, bone_h, child_h, include_children = false)
		// 1. Use Bone Weight Heatmap to refine where this bone's collider starts, ends, and centers!
		hm_p0, hm_p1, hm_perp, hm_ok := _compute_heatmap_segment_bounds(
			p0, p1, world_verts, skin, j_list[:], char_right, char_fwd, exclude_hills,
		)
		if hm_ok {
			if !is_pelvis_seg {
				p0 = hm_p0
				p1 = hm_p1
			}
			world_shift = hm_perp
		}

		// 2. Ray-trace radial cross-sections along the heatmap-refined segment [p0, p1]
		pad := max_r * 1.6
		lo := [3]f32{min(p0.x, p1.x) - pad, min(p0.y, p1.y) - pad, min(p0.z, p1.z) - pad}
		hi := [3]f32{max(p0.x, p1.x) + pad, max(p0.y, p1.y) + pad, max(p0.z, p1.z) + pad}
		tris := _collect_region_triangles(world_verts, indices, skin, j_list[:], lo, hi, 0.10)
		traced_r, trace_shift := _trace_segment_radius(
			p0 + world_shift, p1 + world_shift, tris[:], char_right, char_fwd, default_radius, min_r, max_r, passes, exclude_hills,
		)
		radius = traced_r
		world_shift += trace_shift * 0.5

		if is_torso {
			// Measure true anterior (front) and posterior (back) surface extent of the torso/pelvis slice
			// so capsules sit centered between the front belly/chest/pelvis and the back, instead of
			// hugging the posterior spinal column!
			seg_mid := 0.5 * (p0 + p1)
			seg_axis := linalg.normalize0(p1 - p0)
			seg_len  := linalg.length(p1 - p0)
			max_front: f32 = 0.0
			max_back:  f32 = 0.0
			for tri in tris {
				for kv in 0 ..< 3 {
					rel_v := tri[kv] - seg_mid
					if abs(linalg.dot(rel_v, seg_axis)) > seg_len * 0.55 do continue
					if abs(linalg.dot(rel_v, char_right)) > radius * 0.85 do continue
					fd := linalg.dot(rel_v, char_fwd)
					if exclude_hills && fd > radius * 1.05 {
						fd = radius * 1.05
					}
					if fd > max_front do max_front = fd
					if -fd > max_back do max_back = -fd
				}
			}
			fwd_off := linalg.dot(world_shift, char_fwd)
			if max_front > 0.02 && max_back > 0.02 {
				ap_mid := 0.5 * (max_front - max_back)
				fwd_off = math.lerp(fwd_off, ap_mid, f32(0.75)) + 0.010
				// Ensure radius covers at least 88% of the front-to-back half-thickness
				ap_half := 0.5 * (max_front + max_back) * 0.88
				radius = clamp(max(radius, ap_half), min_r, max_r)
			} else {
				fwd_off += 0.018
			}
			if is_pelvis_seg {
				fwd_off = clamp(fwd_off, 0.010, 0.060)
			} else {
				fwd_off = clamp(fwd_off, 0.012, 0.068)
			}
			world_shift = char_fwd * fwd_off
		}
	}

	tw := engine.transform_world(bone_h)
	s := [3]f32{max(abs(tw.scale.x), 0.001), max(abs(tw.scale.y), 0.001), max(abs(tw.scale.z), 0.001)}

	d := p1 - p0
	dist := linalg.length(d)
	if dist > 0.02 {
		q_native := engine.quat_to_native(tw.rotation)
		inv_rot  := linalg.quaternion_inverse(q_native)
		seg_mid_world := 0.5 * (p0 + p1) + world_shift
		local_center  := linalg.quaternion128_mul_vector3(inv_rot, seg_mid_world - bone_origin) / s
		local_d       := linalg.quaternion128_mul_vector3(inv_rot, d)

		ax := abs(local_d.x)
		ay := abs(local_d.y)
		az := abs(local_d.z)

		dir: physics3d.Capsule_Direction = .Y_Axis
		if ax >= ay && ax >= az {
			dir = .X_Axis
		} else if az >= ax && az >= ay {
			dir = .Z_Axis
		}

		height := max(dist, radius * 2.0) / s.y
		rad    := radius / max(s.x, s.z)
		_attach_or_update_capsule(bone_h, rad, height, dir, local_center)
	} else {
		_attach_limb_capsule(bone_h, child_h, radius, default_len)
	}
}

// =============================================================================
// 2. RAY-TRACED HAND OBB FITTER (WRIST-TO-FINGERTIPS)
// =============================================================================

@(private = "file")
_trace_fit_hand_box :: proc(
	hand_h, lowerarm_h:   engine.Transform_Handle,
	is_right:             bool,
	adm:                  ^ArmatureDeformedMesh,
	world_verts:          []gfx.Vertex,
	indices:              []u32,
	skin:                 []engine.Mesh_Skin_Vertex,
	char_up, char_fwd:    [3]f32,
	passes:               int,
) {
	if hand_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(hand_h)) do return

	if _, sph := engine.transform_get_comp(hand_h, physics3d.SphereCollider); sph != nil {
		engine.transform_destroy_comp(hand_h, physics3d.SphereCollider)
	}

	wrist_pos := engine.transform_world_position(hand_h)
	hand_tw   := engine.transform_world(hand_h)
	s := [3]f32{max(abs(hand_tw.scale.x), 0.001), max(abs(hand_tw.scale.y), 0.001), max(abs(hand_tw.scale.z), 0.001)}

	// 1. Determine anatomical hand axes:
	//    hand_fwd   = wrist -> fingertips
	//    hand_right = across knuckles (index <-> pinky)
	//    hand_up    = dorsal/palm normal
	hand_fwd := [3]f32{0, -1, 0}
	if lowerarm_h != {} && engine.pool_valid(&w.transforms, engine.Handle(lowerarm_h)) {
		la_pos := engine.transform_world_position(lowerarm_h)
		if linalg.length2(wrist_pos - la_pos) > 1e-4 {
			hand_fwd = linalg.normalize(wrist_pos - la_pos)
		}
	}

	// Refine `hand_fwd` and knuckle spread `spread_vec` using actual child finger joints if present
	hand_t := engine.pool_get(&w.transforms, engine.Handle(hand_h))
	finger_dirs := make([dynamic][3]f32, 0, 16, context.temp_allocator)
	max_finger_bone_dist: f32 = 0.0

	if hand_t != nil && len(hand_t.children) > 0 {
		q := make([dynamic]engine.Transform_Handle, 0, 24, context.temp_allocator)
		for ch in hand_t.children do append(&q, engine.Transform_Handle(ch.handle))
		dir_sum := [3]f32{0, 0, 0}
		for len(q) > 0 {
			curr := pop_front(&q)
			if curr == {} || !engine.pool_valid(&w.transforms, engine.Handle(curr)) do continue
			cp := engine.transform_world_position(curr)
			dv := cp - wrist_pos
			d_len := linalg.length(dv)
			if d_len > 0.015 && d_len < 0.30 {
				dir_sum += dv / d_len
				append(&finger_dirs, dv)
				if d_len > max_finger_bone_dist do max_finger_bone_dist = d_len
			}
			if ct := engine.pool_get(&w.transforms, engine.Handle(curr)); ct != nil {
				for cch in ct.children do append(&q, engine.Transform_Handle(cch.handle))
			}
		}
		if linalg.length2(dir_sum) > 1e-4 {
			hand_fwd = linalg.normalize(dir_sum)
		}
	}

	// Derive knuckle spread axis `hand_right` perpendicular to `hand_fwd`
	hand_right := linalg.cross(char_up, hand_fwd)
	if linalg.length2(hand_right) < 0.15 {
		hand_right = linalg.cross(char_fwd, hand_fwd)
	}
	if len(finger_dirs) >= 3 {
		// Find maximum lateral spread between finger bones perpendicular to hand_fwd
		best_spread: f32 = 0.0
		best_vec := hand_right
		for i in 0 ..< len(finger_dirs) {
			pi := finger_dirs[i] - hand_fwd * linalg.dot(finger_dirs[i], hand_fwd)
			for j in i + 1 ..< len(finger_dirs) {
				pj := finger_dirs[j] - hand_fwd * linalg.dot(finger_dirs[j], hand_fwd)
				diff := pi - pj
				d2 := linalg.length2(diff)
				if d2 > best_spread {
					best_spread = d2
					best_vec = diff
				}
			}
		}
		if best_spread > 0.0004 {
			hand_right = linalg.normalize(best_vec)
		}
	}
	if linalg.length2(hand_right) < 1e-4 do hand_right = {0, 0, 1}
	hand_right = linalg.normalize(hand_right - hand_fwd * linalg.dot(hand_right, hand_fwd))
	hand_up    := linalg.normalize(linalg.cross(hand_fwd, hand_right))
	hand_right = linalg.normalize(linalg.cross(hand_up, hand_fwd))

	// Fallback defaults if no mesh vertices are available
	if len(world_verts) < 3 || len(indices) < 3 {
		def_sign: f32 = is_right ? -1.0 : 1.0
		_attach_or_update_box(hand_h, size = {0.052, 0.175, 0.105}, center = {0.012 * def_sign, 0.088, 0.004})
		return
	}

	// 2. Collect hand + finger skin vertices and triangles past the wrist plane
	j_list := _collect_subtree_joint_indices(adm, hand_h, {}, include_children = true)
	pad: f32 = 0.28
	lo := wrist_pos - [3]f32{pad, pad, pad}
	hi := wrist_pos + [3]f32{pad, pad, pad}
	tris := _collect_region_triangles(world_verts, indices, skin, j_list[:], lo, hi, 0.15)

	min_x: f32 =  1e9 // along hand_right (width across palm/knuckles)
	max_x: f32 = -1e9
	min_y: f32 =  1e9 // along hand_up    (palm-to-dorsal thickness)
	max_y: f32 = -1e9
	min_z: f32 = -0.008 // along hand_fwd  (starts right at wrist joint)
	max_z: f32 =  0.0

	has_skin := len(skin) == len(world_verts) && len(j_list) > 0
	vert_hits := 0
	for vi in 0 ..< len(world_verts) {
		vp := world_verts[vi].position
		rel := vp - wrist_pos
		pz := linalg.dot(rel, hand_fwd)
		if pz < -0.015 || pz > 0.26 do continue

		if has_skin {
			if _vertex_weight_for_joints(skin[vi], j_list[:]) < 0.20 do continue
		} else {
			px_t := linalg.dot(rel, hand_right)
			py_t := linalg.dot(rel, hand_up)
			if px_t * px_t + py_t * py_t > 0.11 * 0.11 do continue
		}

		px := linalg.dot(rel, hand_right)
		py := linalg.dot(rel, hand_up)
		if abs(px) > 0.12 || abs(py) > 0.08 do continue

		min_x = min(min_x, px)
		max_x = max(max_x, px)
		min_y = min(min_y, py)
		max_y = max(max_y, py)
		max_z = max(max_z, pz)
		vert_hits += 1
	}

	// 3. Multi-Pass Orthogonal Line Traces into the hand triangles for tight OBB fitting
	if len(tris) >= 4 {
		grid_n := clamp(passes * 2 + 2, 4, 10)
		est_len := max(max_z, max(max_finger_bone_dist * 1.18, 0.16))

		// Pass A: Palm & Dorsal Thickness Traces (±hand_up)
		for iz in 0 ..< grid_n {
			fz := 0.015 + (f32(iz) + 0.5) / f32(grid_n) * (est_len - 0.02)
			for ix in 0 ..< grid_n {
				fx := -0.055 + (f32(ix) + 0.5) / f32(grid_n) * 0.11
				base_pt := wrist_pos + hand_fwd * fz + hand_right * fx
				orig_top := base_pt + hand_up * 0.12
				orig_bot := base_pt - hand_up * 0.12
				for tri in tris {
					if th, ok := _ray_intersect_tri(orig_top, -hand_up, tri[0], tri[1], tri[2]); ok {
						py := 0.12 - th
						if abs(py) < 0.065 do max_y = max(max_y, py)
					}
					if th, ok := _ray_intersect_tri(orig_bot, hand_up, tri[0], tri[1], tri[2]); ok {
						py := -0.12 + th
						if abs(py) < 0.065 do min_y = min(min_y, py)
					}
				}
			}
		}

		// Pass B: Knuckle / Thumb-to-Pinky Width Traces (±hand_right)
		for iz in 0 ..< grid_n {
			fz := 0.015 + (f32(iz) + 0.5) / f32(grid_n) * (est_len - 0.02)
			for iy in 0 ..< 3 {
				fy := (f32(iy) - 1.0) * 0.012
				base_pt := wrist_pos + hand_fwd * fz + hand_up * fy
				orig_r := base_pt + hand_right * 0.14
				orig_l := base_pt - hand_right * 0.14
				for tri in tris {
					if th, ok := _ray_intersect_tri(orig_r, -hand_right, tri[0], tri[1], tri[2]); ok {
						px := 0.14 - th
						if abs(px) < 0.10 do max_x = max(max_x, px)
					}
					if th, ok := _ray_intersect_tri(orig_l, hand_right, tri[0], tri[1], tri[2]); ok {
						px := -0.14 + th
						if abs(px) < 0.10 do min_x = min(min_x, px)
					}
				}
			}
		}

		// Pass C: Fingertip Reach Traces (-hand_fwd from beyond fingertips)
		for ix in 0 ..< grid_n {
			fx := -0.045 + (f32(ix) + 0.5) / f32(grid_n) * 0.09
			orig_tip := wrist_pos + hand_fwd * 0.28 + hand_right * fx
			for tri in tris {
				if th, ok := _ray_intersect_tri(orig_tip, -hand_fwd, tri[0], tri[1], tri[2]); ok {
					pz := 0.28 - th
					if pz > 0.08 && pz < 0.25 do max_z = max(max_z, pz)
				}
			}
		}
	}

	if min_x > max_x || vert_hits < 3 {
		min_x, max_x = -0.048, 0.048
	}
	if min_y > max_y || vert_hits < 3 {
		min_y, max_y = -0.022, 0.022
	}
	if max_z < 0.10 {
		max_z = max(max_finger_bone_dist * 1.20, 0.175)
	}

	width     := clamp(max_x - min_x, 0.065, 0.135)
	thickness := clamp(max_y - min_y, 0.028, 0.068)
	length    := clamp(max_z - min_z, 0.120, 0.230)

	mid_x := clamp(0.5 * (min_x + max_x), -0.03, 0.03)
	mid_y := clamp(0.5 * (min_y + max_y), -0.02, 0.02)
	mid_z := min_z + 0.5 * length

	world_center := wrist_pos + hand_right * mid_x + hand_up * mid_y + hand_fwd * mid_z

	// Build world rotation matrix for the hand OBB (X = width, Y = length along fingers, Z = palm thickness)
	// so it matches MoonHug's standard hand collider convention where Y is finger length:
	obb_x := hand_up                        // palm thickness
	obb_y := hand_fwd                       // wrist-to-finger length
	obb_z := linalg.cross(obb_x, obb_y)     // knuckle width
	if linalg.length2(obb_z) < 1e-4 do obb_z = hand_right
	obb_z = linalg.normalize(obb_z)
	obb_x = linalg.normalize(linalg.cross(obb_y, obb_z))

	rot_mat := matrix[3, 3]f32{
		obb_x.x, obb_y.x, obb_z.x,
		obb_x.y, obb_y.y, obb_z.y,
		obb_x.z, obb_y.z, obb_z.z,
	}
	obb_world_q := linalg.normalize(linalg.quaternion_from_matrix3(rot_mat))

	bone_q := linalg.normalize(engine.quat_to_native(hand_tw.rotation))
	inv_bone_q := linalg.quaternion_inverse(bone_q)

	local_rot := engine.quat_from_native(linalg.normalize(inv_bone_q * obb_world_q))
	local_center := linalg.quaternion128_mul_vector3(inv_bone_q, world_center - wrist_pos) / s
	local_size   := [3]f32{thickness / s.x, length / s.y, width / s.z}

	_attach_or_update_box(hand_h, local_size, local_center, local_rot)
}

// =============================================================================
// 3. RAY-TRACED PLANTED FOOT BOX FITTER (FLOOR-ALIGNED SOLE, HEEL & TOE)
// =============================================================================

@(private = "file")
_trace_fit_foot_box :: proc(
	foot_h, toe_h, calf_h: engine.Transform_Handle,
	char_h:                engine.Transform_Handle,
	adm:                   ^ArmatureDeformedMesh,
	world_verts:           []gfx.Vertex,
	indices:               []u32,
	skin:                  []engine.Mesh_Skin_Vertex,
	char_fwd:              [3]f32,
	passes:                int,
) {
	if foot_h == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(foot_h)) do return

	ankle_pos := engine.transform_world_position(foot_h)
	foot_tw   := engine.transform_world(foot_h)
	s := [3]f32{max(abs(foot_tw.scale.x), 0.001), max(abs(foot_tw.scale.y), 0.001), max(abs(foot_tw.scale.z), 0.001)}

	// 1. Construct horizontal floor-planted coordinate frame (ignoring ankle bone pitch/roll!):
	//    foot_up  = {0, 1, 0} (strictly vertical so sole is 100% parallel to the ground)
	//    foot_fwd = horizontal ankle->toe direction (or character horizontal forward)
	foot_up  := [3]f32{0, 1, 0}
	foot_fwd := [3]f32{char_fwd.x, 0, char_fwd.z}
	if linalg.length2(foot_fwd) < 1e-4 do foot_fwd = {0, 0, 1}
	foot_fwd = linalg.normalize(foot_fwd)

	if toe_h != {} && engine.pool_valid(&w.transforms, engine.Handle(toe_h)) {
		toe_pos := engine.transform_world_position(toe_h)
		horiz := [3]f32{toe_pos.x - ankle_pos.x, 0.0, toe_pos.z - ankle_pos.z}
		if linalg.length(horiz) > 0.025 {
			foot_fwd = linalg.normalize(horiz)
		}
	}

	foot_right := linalg.normalize(linalg.cross(foot_up, foot_fwd))

	rot_mat := matrix[3, 3]f32{
		foot_right.x, 0, foot_fwd.x,
		foot_right.y, 1, foot_fwd.y,
		foot_right.z, 0, foot_fwd.z,
	}
	flat_world_q := linalg.normalize(linalg.quaternion_from_matrix3(rot_mat))
	bone_q       := linalg.normalize(engine.quat_to_native(foot_tw.rotation))
	inv_bone_q   := linalg.quaternion_inverse(bone_q)
	flat_local_q := engine.quat_from_native(linalg.normalize(inv_bone_q * flat_world_q))

	if len(world_verts) < 3 || len(indices) < 3 {
		_attach_or_update_box(foot_h, size = {0.10, 0.08, 0.22}, center = {0, -0.04, 0.06}, rotation = flat_local_q)
		return
	}

	// 2. Gather foot + toe triangles and skin vertices below the lower shin
	j_list := _collect_subtree_joint_indices(adm, foot_h, {}, include_children = true)
	max_instep_y: f32 = 0.010 // relative to ankle_pos.y (low-profile planted foot box)
	if calf_h != {} && engine.pool_valid(&w.transforms, engine.Handle(calf_h)) {
		calf_y := engine.transform_world_position(calf_h).y
		if calf_y > ankle_pos.y {
			max_instep_y = min(0.016, (calf_y - ankle_pos.y) * 0.08)
		}
	}

	lo := ankle_pos - [3]f32{0.22, 0.20, 0.28}
	hi := ankle_pos + [3]f32{0.22, max_instep_y + 0.04, 0.28}
	tris := _collect_region_triangles(world_verts, indices, skin, j_list[:], lo, hi, 0.12)

	min_x: f32 =  1e9 // medial/lateral width
	max_x: f32 = -1e9
	min_y: f32 =  1e9 // planted sole bottom (relative to ankle_pos.y)
	max_y: f32 =  max_instep_y
	min_z: f32 =  1e9 // heel back (relative to ankle_pos along foot_fwd)
	max_z: f32 = -1e9 // toe tip front

	has_skin := len(skin) == len(world_verts) && len(j_list) > 0
	vert_hits := 0
	for vi in 0 ..< len(world_verts) {
		vp := world_verts[vi].position
		rel := vp - ankle_pos
		py := rel.y
		if py > max_instep_y + 0.015 || py < -0.18 do continue

		px := linalg.dot(rel, foot_right)
		pz := linalg.dot(rel, foot_fwd)
		if abs(px) > 0.12 || pz < -0.14 || pz > 0.26 do continue

		if has_skin {
			if _vertex_weight_for_joints(skin[vi], j_list[:]) < 0.15 do continue
		}

		min_x = min(min_x, px)
		max_x = max(max_x, px)
		min_y = min(min_y, py)
		min_z = min(min_z, pz)
		max_z = max(max_z, pz)
		vert_hits += 1
	}

	// 3. Multi-Pass Line Traces for Planted Sole, Heel, Toe Tip, and Foot Width
	if len(tris) >= 4 {
		grid_n := clamp(passes * 2 + 2, 4, 10)

		// Pass A: Upward Ground-Sole Traces (+Y from beneath the floor) & Downward Instep Traces (-Y)
		for iz in 0 ..< grid_n {
			fz := -0.07 + (f32(iz) + 0.5) / f32(grid_n) * 0.27
			for ix in 0 ..< grid_n {
				fx := -0.055 + (f32(ix) + 0.5) / f32(grid_n) * 0.11
				col_pt   := ankle_pos + foot_fwd * fz + foot_right * fx
				orig_bot := [3]f32{col_pt.x, ankle_pos.y - 0.22, col_pt.z}
				for tri in tris {
					if th, ok := _ray_intersect_tri(orig_bot, [3]f32{0, 1, 0}, tri[0], tri[1], tri[2]); ok {
						py := -0.22 + th
						if py >= -0.16 && py <= 0.01 {
							min_y = min(min_y, py)
						}
					}
				}
			}
		}

		sole_y := min_y if min_y < 0.0 else -0.075

		// Pass B: Heel-to-Toe Horizontal Traces (±foot_fwd) at sole & mid-foot heights
		for iy in 0 ..< 3 {
			fy := math.lerp(sole_y + 0.012, max_y - 0.005, f32(iy) / 2.0)
			for ix in 0 ..< grid_n {
				fx := -0.045 + (f32(ix) + 0.5) / f32(grid_n) * 0.09
				row_pt := ankle_pos + foot_up * fy + foot_right * fx
				orig_front := row_pt + foot_fwd * 0.30
				orig_back  := row_pt - foot_fwd * 0.18
				for tri in tris {
					if th, ok := _ray_intersect_tri(orig_front, -foot_fwd, tri[0], tri[1], tri[2]); ok {
						pz := 0.30 - th
						if pz > 0.04 && pz < 0.26 do max_z = max(max_z, pz)
					}
					if th, ok := _ray_intersect_tri(orig_back, foot_fwd, tri[0], tri[1], tri[2]); ok {
						pz := -0.18 + th
						if pz > -0.14 && pz < 0.02 do min_z = min(min_z, pz)
					}
				}
			}
		}

		// Pass C: Medial / Lateral Width Traces (±foot_right)
		z_lo := min_z if min_z < 0.0 else -0.05
		z_hi := max_z if max_z > 0.05 else 0.17
		for iz in 0 ..< grid_n {
			fz := math.lerp(z_lo + 0.01, z_hi - 0.01, (f32(iz) + 0.5) / f32(grid_n))
			for iy in 0 ..< 2 {
				fy := math.lerp(sole_y + 0.015, max_y - 0.01, f32(iy))
				slice_pt := ankle_pos + foot_fwd * fz + foot_up * fy
				orig_r := slice_pt + foot_right * 0.14
				orig_l := slice_pt - foot_right * 0.14
				for tri in tris {
					if th, ok := _ray_intersect_tri(orig_r, -foot_right, tri[0], tri[1], tri[2]); ok {
						px := 0.14 - th
						if abs(px) < 0.11 do max_x = max(max_x, px)
					}
					if th, ok := _ray_intersect_tri(orig_l, foot_right, tri[0], tri[1], tri[2]); ok {
						px := -0.14 + th
						if abs(px) < 0.11 do min_x = min(min_x, px)
					}
				}
			}
		}
	}

	if min_x > max_x || vert_hits < 3 {
		min_x, max_x = -0.048, 0.048
	}
	if min_y > 0.01 || min_y < -0.18 {
		// Fall back to character actor ground y if ankle height is known
		if char_h != {} && engine.pool_valid(&w.transforms, engine.Handle(char_h)) {
			actor_y := engine.transform_world_position(char_h).y
			if ankle_pos.y > actor_y && ankle_pos.y - actor_y < 0.18 {
				min_y = actor_y - ankle_pos.y
			} else {
				min_y = -0.075
			}
		} else {
			min_y = -0.075
		}
	}
	if min_z > max_z {
		min_z, max_z = -0.055, 0.165
	}

	width  := clamp(max_x - min_x, 0.068, 0.130)
	height := clamp(max_y - min_y, 0.042, 0.088)
	length := clamp(max_z - min_z, 0.155, 0.295)

	mid_x := clamp(0.5 * (min_x + max_x), -0.03, 0.03)
	mid_y := min_y + 0.5 * height // Keeps bottom face locked at `ankle_pos.y + min_y`!
	mid_z := 0.5 * (min_z + max_z)

	world_center := ankle_pos + foot_right * mid_x + foot_up * mid_y + foot_fwd * mid_z
	local_center := linalg.quaternion128_mul_vector3(inv_bone_q, world_center - ankle_pos) / s
	local_size   := [3]f32{width / s.x, height / s.y, length / s.z}

	_attach_or_update_box(foot_h, local_size, local_center, flat_local_q)
}

// =============================================================================
// STAGED HUMANOID COLLIDER FITTERS
// =============================================================================

@(private = "file")
_get_character_axes :: proc(char_h: engine.Transform_Handle, bones: ^Humanoid_Bones) -> (char_right, char_up, char_fwd: [3]f32) {
	char_up    = {0, 1, 0}
	char_right = {1, 0, 0}
	char_fwd   = {0, 0, 1}

	w := engine.ctx_world()
	if w == nil do return

	// Derive true character right vector from left -> right hip/shoulder positions
	if bones != nil && bones.left_thigh != {} && bones.right_thigh != {} {
		lp := engine.transform_world_position(bones.left_thigh)
		rp := engine.transform_world_position(bones.right_thigh)
		diff := [3]f32{lp.x - rp.x, 0, lp.z - rp.z}
		if linalg.length2(diff) > 1e-4 {
			char_right = linalg.normalize(diff)
			char_fwd   = linalg.normalize(linalg.cross(char_right, char_up))
			// Verify forward sign against toe bones if available
			if bones.left_foot != {} && bones.left_toe != {} {
				fp := engine.transform_world_position(bones.left_foot)
				tp := engine.transform_world_position(bones.left_toe)
				if linalg.dot(tp - fp, char_fwd) < 0 {
					char_fwd = -char_fwd
				}
			}
			return
		}
	}

	if char_h != {} && engine.pool_valid(&w.transforms, engine.Handle(char_h)) {
		tw := engine.transform_world(char_h)
		q := linalg.normalize(engine.quat_to_native(tw.rotation))
		char_right = linalg.normalize(linalg.quaternion128_mul_vector3(q, [3]f32{1, 0, 0}))
		char_fwd   = linalg.normalize(linalg.quaternion128_mul_vector3(q, [3]f32{0, 0, 1}))
	}
	return
}

// Walks the actual spine chain from `pelvis` up to `head` so skeletons with 2, 3, 4, or 5 spine bones
// get accurately fitted torso colliders. When `has_breasts` is true, the upper chest collider is fitted
// to the flattened ribcage baseline so it doesn't oversize over the breasts!
@(private = "file")
_smart_trace_fit_spine_and_head :: proc(
	char_h:      engine.Transform_Handle,
	adm:         ^ArmatureDeformedMesh,
	bones:       ^Humanoid_Bones,
	passes:      int,
	has_breasts: bool = false,
) -> int {
	w := engine.ctx_world()
	if w == nil do return 0

	world_verts: []gfx.Vertex
	indices:     []u32
	mesh:        ^engine.Mesh
	skin:        []engine.Mesh_Skin_Vertex
	if adm != nil {
		if vs, is, m, ok := armature_ensure_posed_world_geometry(adm); ok {
			world_verts = vs
			indices     = is
			mesh        = m
			skin        = adm.custom_skin[:] if len(adm.custom_skin) == len(m.bind_vertices) else m.skin
		}
	}

	char_right, _, char_fwd := _get_character_axes(char_h, bones)
	count := 0

	// Collect all spine chain bones from pelvis up to head
	spine_chain := make([dynamic]engine.Transform_Handle, 0, 8, context.temp_allocator)
	if bones.head != {} && bones.pelvis != {} {
		// Walk parent links from head down to pelvis
		rev := make([dynamic]engine.Transform_Handle, 0, 8, context.temp_allocator)
		curr := bones.head
		for step := 0; step < 12 && curr != {}; step += 1 {
			t := engine.pool_get(&w.transforms, engine.Handle(curr))
			if t == nil || t.parent.handle == {} do break
			parent_h := engine.Transform_Handle(t.parent.handle)
			if parent_h == char_h do break
			// Exclude neck if it's very short (< 6cm from head) so head and chest don't overlap
			if curr == bones.head {
				hp := engine.transform_world_position(bones.head)
				pp := engine.transform_world_position(parent_h)
				if linalg.distance(hp, pp) < 0.065 && parent_h != bones.pelvis && parent_h != bones.chest {
					curr = parent_h
					continue
				}
			}
			append(&rev, parent_h)
			if parent_h == bones.pelvis do break
			curr = parent_h
		}
		for i := len(rev) - 1; i >= 0; i -= 1 {
			append(&spine_chain, rev[i])
		}
	}

	if len(spine_chain) == 0 {
		if bones.pelvis != {} do append(&spine_chain, bones.pelvis)
		if bones.spine != {} && bones.spine != bones.pelvis do append(&spine_chain, bones.spine)
		if bones.chest != {} && bones.chest != bones.spine && bones.chest != bones.pelvis do append(&spine_chain, bones.chest)
	}

	// Fit each bone in the spinal column to the segment leading to the next spinal bone (or head)
	for i in 0 ..< len(spine_chain) {
		b_h := spine_chain[i]
		next_h := spine_chain[i + 1] if i + 1 < len(spine_chain) else bones.head
		is_upper_chest := (i == len(spine_chain) - 1) || (b_h == bones.chest)
		is_pelvis      := (i == 0) || (b_h == bones.pelvis)

		_trace_fit_limb_capsule(
			b_h,
			next_h,
			adm,
			world_verts,
			indices,
			skin,
			char_right,
			char_fwd,
			default_radius = is_upper_chest ? 0.140 : (is_pelvis ? 0.130 : 0.128),
			min_r          = 0.095,
			max_r          = is_pelvis ? 0.155 : 0.175,
			default_len    = is_upper_chest ? 0.28 : 0.22,
			passes         = passes,
			exclude_hills  = is_upper_chest && has_breasts, // Only flatten chest baseline if character has breasts!
			is_torso       = true,
			is_pelvis_seg  = is_pelvis,
		)
		count += 1
	}

	// Fit Head Capsule (using cranium vertices above the head/neck pivot)
	if bones.head != {} {
		head_pos := engine.transform_world_position(bones.head)
		head_tw  := engine.transform_world(bones.head)
		s := [3]f32{max(abs(head_tw.scale.x), 0.001), max(abs(head_tw.scale.y), 0.001), max(abs(head_tw.scale.z), 0.001)}

		top_y := head_pos.y + 0.22
		rad: f32 = 0.110
		fwd_shift: f32 = 0.012

		if len(world_verts) >= 3 && len(indices) >= 3 {
			j_list := _collect_subtree_joint_indices(adm, bones.head, {}, include_children = true)
			lo := head_pos - [3]f32{0.22, 0.04, 0.22}
			hi := head_pos + [3]f32{0.22, 0.34, 0.22}
			tris := _collect_region_triangles(world_verts, indices, skin, j_list[:], lo, hi, 0.10)
			// Fallback if head weights are shared or sparse: include all mesh triangles inside the cranium box
			if len(tris) < 12 {
				empty_joints: [0]int
				tris = _collect_region_triangles(world_verts, indices, skin, empty_joints[:], lo, hi, 0.0)
			}

			min_hx, max_hx: f32 =  1e9, -1e9
			min_hz, max_hz: f32 =  1e9, -1e9
			found_cranium := false
			for tri in tris {
				for k in 0 ..< 3 {
					pt := tri[k]
					if pt.y > top_y do top_y = pt.y
					// Measure cranium cross-section above the jaw/neck pivot
					if pt.y >= head_pos.y + 0.035 {
						rel := pt - head_pos
						rx := linalg.dot(rel, char_right)
						rz := linalg.dot(rel, char_fwd)
						if abs(rx) < 0.18 && abs(rz) < 0.20 {
							min_hx = min(min_hx, rx)
							max_hx = max(max_hx, rx)
							min_hz = min(min_hz, rz)
							max_hz = max(max_hz, rz)
							found_cranium = true
						}
					}
				}
			}
			// Also scan all world vertices inside the head column so hair/crown tips are never missed
			for v in world_verts {
				pt := v.position
				if pt.y > top_y && pt.y <= head_pos.y + 0.36 {
					rel := pt - head_pos
					if abs(linalg.dot(rel, char_right)) < 0.16 && abs(linalg.dot(rel, char_fwd)) < 0.18 {
						top_y = pt.y
					}
				}
			}
			top_y = clamp(top_y, head_pos.y + 0.20, head_pos.y + 0.35)

			// Trace cranium starting 4cm above the neck/head pivot so the narrow neck doesn't shrink the head radius
			cranium_p0 := head_pos + [3]f32{0, 0.04, 0}
			cranium_p1 := [3]f32{head_pos.x, top_y - 0.01, head_pos.z}
			r_traced, shift := _trace_segment_radius(
				cranium_p0,
				cranium_p1,
				tris[:],
				char_right,
				char_fwd,
				0.110,
				0.096,
				0.140,
				passes,
			)
			rad = r_traced
			if found_cranium {
				box_rad := 0.25 * ((max_hx - min_hx) + (max_hz - min_hz))
				rad = clamp(max(rad, box_rad * 0.96), 0.096, 0.140)
				fwd_shift = clamp(0.5 * (min_hz + max_hz), -0.020, 0.040)
			} else {
				fwd_shift = clamp(linalg.dot(shift, char_fwd), -0.020, 0.040)
			}
		}

		// Span from jaw/skull base (`head_pos.y - 0.025`) all the way to the top crown (`top_y + 0.015`)
		crown_y  := top_y + 0.015
		bot_y    := head_pos.y - 0.025
		head_h   := clamp(crown_y - bot_y, max(rad * 2.05, 0.22), 0.36)
		center_y := (crown_y - head_pos.y) - 0.5 * head_h
		world_c  := head_pos + [3]f32{0, center_y, 0} + char_fwd * fwd_shift
		inv_q    := linalg.quaternion_inverse(linalg.normalize(engine.quat_to_native(head_tw.rotation)))
		local_c  := linalg.quaternion128_mul_vector3(inv_q, world_c - head_pos) / s
		_attach_or_update_capsule(bones.head, rad / max(s.x, s.z), head_h / s.y, .Y_Axis, local_c)
		count += 1
	}

	return count
}

@(private = "file")
_smart_trace_fit_arms_and_hands :: proc(
	char_h: engine.Transform_Handle,
	adm:    ^ArmatureDeformedMesh,
	bones:  ^Humanoid_Bones,
	passes: int,
) -> int {
	world_verts: []gfx.Vertex
	indices:     []u32
	skin:        []engine.Mesh_Skin_Vertex
	if adm != nil {
		if vs, is, m, ok := armature_ensure_posed_world_geometry(adm); ok {
			world_verts = vs
			indices     = is
			skin        = adm.custom_skin[:] if len(adm.custom_skin) == len(m.bind_vertices) else m.skin
		}
	}

	char_right, char_up, char_fwd := _get_character_axes(char_h, bones)
	count := 0

	if bones.left_upperarm != {} {
		_trace_fit_limb_capsule(bones.left_upperarm, bones.left_lowerarm, adm, world_verts, indices, skin, char_right, char_fwd, 0.052, 0.032, 0.085, 0.28, passes)
		count += 1
	}
	if bones.left_lowerarm != {} {
		_trace_fit_limb_capsule(bones.left_lowerarm, bones.left_hand, adm, world_verts, indices, skin, char_right, char_fwd, 0.044, 0.026, 0.072, 0.25, passes)
		count += 1
	}
	if bones.left_hand != {} {
		_trace_fit_hand_box(bones.left_hand, bones.left_lowerarm, false, adm, world_verts, indices, skin, char_up, char_fwd, passes)
		count += 1
	}

	if bones.right_upperarm != {} {
		_trace_fit_limb_capsule(bones.right_upperarm, bones.right_lowerarm, adm, world_verts, indices, skin, char_right, char_fwd, 0.052, 0.032, 0.085, 0.28, passes)
		count += 1
	}
	if bones.right_lowerarm != {} {
		_trace_fit_limb_capsule(bones.right_lowerarm, bones.right_hand, adm, world_verts, indices, skin, char_right, char_fwd, 0.044, 0.026, 0.072, 0.25, passes)
		count += 1
	}
	if bones.right_hand != {} {
		_trace_fit_hand_box(bones.right_hand, bones.right_lowerarm, true, adm, world_verts, indices, skin, char_up, char_fwd, passes)
		count += 1
	}

	if _, hpd := engine.transform_get_comp(char_h, HandPoseDriver); hpd != nil {
		hand_pose_driver_evaluate(hpd, 0.0)
	}
	return count
}

@(private = "file")
_smart_trace_fit_legs_and_feet :: proc(
	char_h: engine.Transform_Handle,
	adm:    ^ArmatureDeformedMesh,
	bones:  ^Humanoid_Bones,
	passes: int,
) -> int {
	world_verts: []gfx.Vertex
	indices:     []u32
	skin:        []engine.Mesh_Skin_Vertex
	if adm != nil {
		if vs, is, m, ok := armature_ensure_posed_world_geometry(adm); ok {
			world_verts = vs
			indices     = is
			skin        = adm.custom_skin[:] if len(adm.custom_skin) == len(m.bind_vertices) else m.skin
		}
	}

	char_right, _, char_fwd := _get_character_axes(char_h, bones)
	count := 0

	if bones.left_thigh != {} {
		_trace_fit_limb_capsule(bones.left_thigh, bones.left_calf, adm, world_verts, indices, skin, char_right, char_fwd, 0.082, 0.050, 0.135, 0.40, passes)
		count += 1
	}
	if bones.left_calf != {} {
		_trace_fit_limb_capsule(bones.left_calf, bones.left_foot, adm, world_verts, indices, skin, char_right, char_fwd, 0.060, 0.038, 0.095, 0.38, passes)
		count += 1
	}
	if bones.left_foot != {} {
		_trace_fit_foot_box(bones.left_foot, bones.left_toe, bones.left_calf, char_h, adm, world_verts, indices, skin, char_fwd, passes)
		count += 1
	}

	if bones.right_thigh != {} {
		_trace_fit_limb_capsule(bones.right_thigh, bones.right_calf, adm, world_verts, indices, skin, char_right, char_fwd, 0.082, 0.050, 0.135, 0.40, passes)
		count += 1
	}
	if bones.right_calf != {} {
		_trace_fit_limb_capsule(bones.right_calf, bones.right_foot, adm, world_verts, indices, skin, char_right, char_fwd, 0.060, 0.038, 0.095, 0.38, passes)
		count += 1
	}
	if bones.right_foot != {} {
		_trace_fit_foot_box(bones.right_foot, bones.right_toe, bones.right_calf, char_h, adm, world_verts, indices, skin, char_fwd, passes)
		count += 1
	}

	return count
}

// Automatically fits and attaches ray-traced ragdoll/hitbox colliders across all humanoid bones.
smart_collider_place_humanoid :: proc(
	char_h:          engine.Transform_Handle,
	multipass_count: int  = 3,
	has_breasts:     bool = smart_rig_async_state.has_breasts,
) -> int {
	bones: Humanoid_Bones
	if !skeleton_bind_humanoid(&bones, char_h) do return 0

	adm := _resolve_character_adm(char_h)
	passes := clamp(multipass_count, 1, 4)

	count := 0
	count += _smart_trace_fit_spine_and_head(char_h, adm, &bones, passes, has_breasts)
	count += _smart_trace_fit_arms_and_hands(char_h, adm, &bones, passes)
	count += _smart_trace_fit_legs_and_feet(char_h, adm, &bones, passes)
	if has_breasts && adm != nil {
		if _, _, _, ok_b := smart_auto_rig_breasts_via_line_traces(adm, attach_colliders = true, recursion_passes = smart_rig_async_state.recursion_passes); ok_b {
			count += 2
		}
	}

	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return count
}

// =============================================================================
// 4. TOPOGRAPHIC BREAST "HILL" TRACER, GRAVITY-SAG BONE PLACER & RECURSIVE WEIGHTS
// =============================================================================
// Mathematical approach:
// 1. Locate the anatomical upper-chest zone from shoulder/clavicle height down to mid-torso
//    (independent of whether the skeleton has 1, 2, 3, or 4 spine bones).
// 2. Fire a 2D front-to-back line-trace grid across the chest surface to sample Z_surf(x, y).
// 3. Construct the "Virtual Flattened Ribcage Baseline" Z_flat(x, y) by interpolating the sternum
//    valley (x ~ 0), sub-clavicular upper shelf, under-bust lower ribs, and lateral ribcage margins:
//    "If we cut off the breasts, we get a flattish chest."
// 4. Compute protrusion height Delta_Z(x, y) = max(0, Z_surf(x, y) - Z_flat(x, y)).
//    Detect the Left and Right Breast Hills:
//    - Apex point P_apex (top of the hill)
//    - Base footprint & P_root on the flattened chest plane
//    - Gravity Sag Vector (P_apex - P_root): handles breasts pointing downward / compressed by gravity!
// 5. Spawn `breast_l` and `breast_r` parented to the anatomical chest bone, attach `SpringBone` dynamics
//    and fitted `SphereCollider`s, and run multi-pass recursive topological weight distribution!
smart_auto_rig_breasts_via_line_traces :: proc(
	adm:              ^ArmatureDeformedMesh,
	attach_colliders: bool = true,
	recursion_passes: int  = 3,
) -> (left_h, right_h: engine.Transform_Handle, weighted_verts: int, ok: bool) {
	if adm == nil do return {}, {}, 0, false
	w := engine.ctx_world()
	if w == nil do return {}, {}, 0, false

	owner_h := engine.Transform_Handle(adm.owner)
	if owner_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner_h)) do return {}, {}, 0, false

	bones: Humanoid_Bones
	skeleton_bind_humanoid(&bones, owner_h)

	// Clean out existing custom breast bones first so any previous weights return cleanly to parent
	search_root := engine.Transform_Handle(adm.root_bone.handle) if adm.root_bone.handle != {} else owner_h
	for bname in ([?]string{"breast_l", "breast_r", "l_breast", "r_breast", "l_breastBone", "r_breastBone"}) {
		if ex_h, found := skeleton_find_bone_by_name(search_root, bname); found && ex_h != {} {
			armature_remove_custom_bone(adm, ex_h)
		}
	}

	world_verts, indices, mesh, geom_ok := armature_ensure_posed_world_geometry(adm)
	if !geom_ok || mesh == nil || len(mesh.bind_vertices) < 12 do return {}, {}, 0, false

	// Work in character actor-local space (matches `mesh.bind_vertices`)
	actor_tw  := engine.transform_world(owner_h)
	actor_pos := actor_tw.position
	actor_rot := linalg.normalize(engine.quat_to_native(actor_tw.rotation))
	inv_actor_rot := linalg.quaternion_inverse(actor_rot)
	actor_scale := [3]f32{
		max(abs(actor_tw.scale.x), 0.001),
		max(abs(actor_tw.scale.y), 0.001),
		max(abs(actor_tw.scale.z), 0.001),
	}

	to_local :: proc(wp, a_pos: [3]f32, inv_q: quaternion128, a_scale: [3]f32) -> [3]f32 {
		return linalg.quaternion128_mul_vector3(inv_q, wp - a_pos) / a_scale
	}
	to_world :: proc(lp, a_pos: [3]f32, a_q: quaternion128, a_scale: [3]f32) -> [3]f32 {
		return a_pos + linalg.quaternion128_mul_vector3(a_q, lp * a_scale)
	}

	// 1. Determine anatomical chest search bounds [y_bot..y_top], [-x_max..+x_max] from skeleton anatomy
	mesh_min := mesh.aabb_min
	mesh_max := mesh.aabb_max
	mesh_h   := max(mesh_max.y - mesh_min.y, 0.5)

	y_top := mesh_min.y + mesh_h * 0.80
	y_bot := mesh_min.y + mesh_h * 0.60
	x_max := max((mesh_max.x - mesh_min.x) * 0.22, 0.14)
	left_x_sign: f32 = 1.0 // +1 if left_upperarm has +X in local space, -1 otherwise
	fwd_z_sign:  f32 = 1.0 // +1 if character faces +Z in local space

	if bones.left_upperarm != {} && bones.right_upperarm != {} {
		l_sh := to_local(engine.transform_world_position(bones.left_upperarm), actor_pos, inv_actor_rot, actor_scale)
		r_sh := to_local(engine.transform_world_position(bones.right_upperarm), actor_pos, inv_actor_rot, actor_scale)
		left_x_sign = l_sh.x >= r_sh.x ? 1.0 : -1.0
		sh_y := 0.5 * (l_sh.y + r_sh.y)
		half_sh_w := 0.5 * abs(l_sh.x - r_sh.x)
		if half_sh_w > 0.06 {
			x_max = half_sh_w * 0.88
		}
		y_top = sh_y - 0.015 * mesh_h
		if bones.pelvis != {} {
			pelv_p := to_local(engine.transform_world_position(bones.pelvis), actor_pos, inv_actor_rot, actor_scale)
			torso_span := max(sh_y - pelv_p.y, 0.20)
			y_bot = pelv_p.y + torso_span * 0.42
		} else {
			y_bot = y_top - 0.22 * mesh_h
		}
	}

	if bones.left_foot != {} && bones.left_toe != {} {
		lf := to_local(engine.transform_world_position(bones.left_foot), actor_pos, inv_actor_rot, actor_scale)
		lt := to_local(engine.transform_world_position(bones.left_toe), actor_pos, inv_actor_rot, actor_scale)
		if (lt.z - lf.z) < -0.01 do fwd_z_sign = -1.0
	}

	// Find the best anatomical parent bone in the spinal column (closest spine/chest bone below `y_top`)
	target_pectoral_y := math.lerp(y_bot, y_top, f32(0.58))
	chest_bone := bones.chest != {} ? bones.chest : bones.spine
	best_spine_dist: f32 = 1e9
	for j_h in adm.joints {
		if j_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(j_h)) do continue
		jt := engine.pool_get(&w.transforms, engine.Handle(j_h))
		if jt == nil do continue
		norm_n := strings.to_lower(jt.name, context.temp_allocator)
		is_torso_joint := strings.contains(norm_n, "spine") || strings.contains(norm_n, "chest") || strings.contains(norm_n, "thorax") || strings.contains(norm_n, "pect") || strings.contains(norm_n, "upper")
		if is_torso_joint && !strings.contains(norm_n, "arm") && !strings.contains(norm_n, "leg") {
			jp := to_local(engine.transform_world_position(j_h), actor_pos, inv_actor_rot, actor_scale)
			if abs(jp.x) < 0.04 && jp.y >= y_bot - 0.12 && jp.y <= y_top + 0.05 {
				d := abs(jp.y - target_pectoral_y)
				if d < best_spine_dist {
					best_spine_dist = d
					chest_bone = j_h
				}
			}
		}
	}
	if chest_bone == {} {
		chest_bone, _ = skeleton_find_bone_by_name(search_root, "chest")
		if chest_bone == {} do chest_bone, _ = skeleton_find_bone_by_name(search_root, "spine_02")
		if chest_bone == {} do chest_bone, _ = skeleton_find_bone_by_name(search_root, "spine")
	}
	if chest_bone == {} do return {}, {}, 0, false

	// 2. Collect front-facing chest triangles in local space
	bind_verts := mesh.bind_vertices
	chest_tris := make([dynamic][3][3]f32, 0, 512, context.temp_allocator)
	tri_count  := len(indices) / 3
	for ti in 0 ..< tri_count {
		i0 := int(indices[ti * 3 + 0])
		i1 := int(indices[ti * 3 + 1])
		i2 := int(indices[ti * 3 + 2])
		if i0 >= len(bind_verts) || i1 >= len(bind_verts) || i2 >= len(bind_verts) do continue
		p0 := bind_verts[i0].position
		p1 := bind_verts[i1].position
		p2 := bind_verts[i2].position

		lo_y := min(p0.y, min(p1.y, p2.y))
		hi_y := max(p0.y, max(p1.y, p2.y))
		if hi_y < y_bot - 0.04 || lo_y > y_top + 0.04 do continue

		lo_x := min(p0.x, min(p1.x, p2.x))
		hi_x := max(p0.x, max(p1.x, p2.x))
		if hi_x < -x_max * 1.15 || lo_x > x_max * 1.15 do continue

		// Only front side of torso
		mid_z := (p0.z + p1.z + p2.z) * (1.0 / 3.0) * fwd_z_sign
		if mid_z < -0.02 do continue
		append(&chest_tris, [3][3]f32{p0, p1, p2})
	}
	_ = world_verts

	// 3. Fire a 2D Front-to-Back Line-Trace Grid across `[-x_max..+x_max] x [y_bot..y_top]`
	GRID_X :: 28
	GRID_Y :: 22
	z_surf: [GRID_Y][GRID_X]f32
	z_valid: [GRID_Y][GRID_X]bool

	ray_z_start := 1.0 * fwd_z_sign
	ray_dir     := [3]f32{0, 0, -fwd_z_sign}

	for iy in 0 ..< GRID_Y {
		fy := math.lerp(y_bot, y_top, (f32(iy) + 0.5) / f32(GRID_Y))
		for ix in 0 ..< GRID_X {
			fx := math.lerp(-x_max, x_max, (f32(ix) + 0.5) / f32(GRID_X))
			orig := [3]f32{fx, fy, ray_z_start}
			best_z: f32 = -1e9
			found_hit := false
			for tri in chest_tris {
				if th, hit := _ray_intersect_tri(orig, ray_dir, tri[0], tri[1], tri[2]); hit {
					hit_z_signed := (ray_z_start + ray_dir.z * th) * fwd_z_sign
					if hit_z_signed > -0.02 && hit_z_signed < 0.45 {
						if hit_z_signed > best_z {
							best_z = hit_z_signed
							found_hit = true
						}
					}
				}
			}
			z_surf[iy][ix]  = best_z
			z_valid[iy][ix] = found_hit
		}
	}

	// 4. Construct the "Virtual Flattened Ribcage Baseline" Z_flat(iy, ix):
	//    If we sliced the breast hills off the torso, the flat chest surface at height `y`
	//    runs from the sternum midline (x ~ 0) out to the lateral ribcage edge, tapering
	//    smoothly between the upper sub-clavicular shelf and lower under-bust ribs!
	row_sternum_z: [GRID_Y]f32
	row_edge_l_z:  [GRID_Y]f32
	row_edge_r_z:  [GRID_Y]f32
	global_sternum_z: f32 = 0.08
	sternum_cnt := 0

	mid_ix0 := GRID_X / 2 - 1
	mid_ix1 := GRID_X / 2

	for iy in 0 ..< GRID_Y {
		// Sternum midline (center 2 columns around x = 0)
		s_sum: f32 = 0
		s_n := 0
		for ix in max(0, mid_ix0 - 1) ..= min(GRID_X - 1, mid_ix1 + 1) {
			if z_valid[iy][ix] {
				s_sum += z_surf[iy][ix]
				s_n += 1
			}
		}
		if s_n > 0 {
			row_sternum_z[iy] = s_sum / f32(s_n)
			global_sternum_z += row_sternum_z[iy]
			sternum_cnt += 1
		} else {
			row_sternum_z[iy] = -1.0
		}

		// Lateral ribcage margin depths (outermost valid columns on each side)
		row_edge_r_z[iy] = -1.0
		for ix in 0 ..< GRID_X / 3 {
			if z_valid[iy][ix] {
				row_edge_r_z[iy] = z_surf[iy][ix]
				break
			}
		}
		row_edge_l_z[iy] = -1.0
		for ix := GRID_X - 1; ix >= (2 * GRID_X) / 3; ix -= 1 {
			if z_valid[iy][ix] {
				row_edge_l_z[iy] = z_surf[iy][ix]
				break
			}
		}
	}
	if sternum_cnt > 1 {
		global_sternum_z = (global_sternum_z - 0.08) / f32(sternum_cnt)
	}

	// Fill any missing sternum rows and clamp sternum against top/bottom ribcage chord
	top_sternum := row_sternum_z[GRID_Y - 1] > 0 ? row_sternum_z[GRID_Y - 1] : global_sternum_z
	bot_sternum := row_sternum_z[0] > 0          ? row_sternum_z[0]          : global_sternum_z * 0.90
	for iy in 0 ..< GRID_Y {
		ty := (f32(iy) + 0.5) / f32(GRID_Y)
		chord_z := math.lerp(bot_sternum, top_sternum, ty)
		if row_sternum_z[iy] <= 0 {
			row_sternum_z[iy] = chord_z
		} else {
			// Prevent fused cleavage meshes from fooling the sternum baseline
			row_sternum_z[iy] = min(row_sternum_z[iy], chord_z + 0.012)
		}
	}

	eval_flat_chest_z :: proc(
		fx, fy: f32,
		x_max, y_bot, y_top: f32,
		row_sternum_z, row_edge_l_z, row_edge_r_z: ^[GRID_Y]f32,
	) -> f32 {
		ty := clamp((fy - y_bot) / max(y_top - y_bot, 0.01), 0.0, 1.0)
		iy := clamp(int(ty * f32(GRID_Y - 1)), 0, GRID_Y - 1)
		stern_z := row_sternum_z[iy]
		edge_z  := fx >= 0 ? row_edge_l_z[iy] : row_edge_r_z[iy]
		if edge_z <= 0 || edge_z > stern_z {
			edge_z = stern_z - 0.028
		}
		tx := clamp(abs(fx) / max(x_max, 0.04), 0.0, 1.0)
		// Natural cylindrical ribcage curvature from sternum midline out to lateral ribs
		return stern_z - (stern_z - edge_z) * (tx * tx * 0.65)
	}

	// 5. Analyze Left and Right Breast Hills above the Flattened Ribcage Baseline
	Breast_Hill_Analysis :: struct {
		apex_pos:     [3]f32, // Local point of peak hill elevation
		base_pos:     [3]f32, // Center of hill footprint on the flattened ribcage plane
		root_pos:     [3]f32, // Bone pivot placement slightly inside the ribcage wall
		sag_dir:      [3]f32, // Unit vector from root_pos -> apex_pos (captures gravity sag!)
		bone_len:     f32,
		peak_dz:      f32,    // Maximum protrusion height above flattened chest (meters)
		radius_horiz: f32,
		radius_upper: f32,
		radius_lower: f32,    // Tighter under-bust crease radius when gravity-compressed
		sag_deg:      f32,
		valid:        bool,
	}

	analyze_side_hill :: proc(
		side_x_sign: f32,
		x_max, y_bot, y_top, fwd_z_sign: f32,
		z_surf:  ^[GRID_Y][GRID_X]f32,
		z_valid: ^[GRID_Y][GRID_X]bool,
		row_sternum_z, row_edge_l_z, row_edge_r_z: ^[GRID_Y]f32,
	) -> Breast_Hill_Analysis {
		res: Breast_Hill_Analysis
		peak_dz: f32 = 0.0
		peak_pt := [3]f32{0.075 * side_x_sign, math.lerp(y_bot, y_top, f32(0.50)), 0.11 * fwd_z_sign}

		// Pass 1: Find peak protrusion Delta_Z above flattened ribcage
		for iy in 0 ..< GRID_Y {
			fy := math.lerp(y_bot, y_top, (f32(iy) + 0.5) / f32(GRID_Y))
			for ix in 0 ..< GRID_X {
				if !z_valid[iy][ix] do continue
				fx := math.lerp(-x_max, x_max, (f32(ix) + 0.5) / f32(GRID_X))
				if fx * side_x_sign < 0.022 || abs(fx) > x_max * 0.90 do continue

				flat_z := eval_flat_chest_z(fx, fy, x_max, y_bot, y_top, row_sternum_z, row_edge_l_z, row_edge_r_z)
				dz := z_surf[iy][ix] - flat_z
				if dz > peak_dz {
					peak_dz = dz
					peak_pt = {fx, fy, z_surf[iy][ix] * fwd_z_sign}
				}
			}
		}

		// Pass 2: Compute prominence-weighted Hill Apex and Hill Footprint Base
		if peak_dz >= 0.008 {
			apex_sum   := [3]f32{0, 0, 0}
			apex_w_sum: f32 = 0.0
			base_sum_x: f32 = 0.0
			base_sum_y: f32 = 0.0
			base_w_sum: f32 = 0.0
			min_hx, max_hx: f32 =  1e9, -1e9
			min_hy, max_hy: f32 =  1e9, -1e9

			for iy in 0 ..< GRID_Y {
				fy := math.lerp(y_bot, y_top, (f32(iy) + 0.5) / f32(GRID_Y))
				for ix in 0 ..< GRID_X {
					if !z_valid[iy][ix] do continue
					fx := math.lerp(-x_max, x_max, (f32(ix) + 0.5) / f32(GRID_X))
					if fx * side_x_sign < 0.018 || abs(fx) > x_max * 0.92 do continue

					flat_z := eval_flat_chest_z(fx, fy, x_max, y_bot, y_top, row_sternum_z, row_edge_l_z, row_edge_r_z)
					dz := z_surf[iy][ix] - flat_z
					if dz > peak_dz * 0.18 {
						// Footprint base (where the breast hill rises from the flat ribcage)
						bw := dz / peak_dz
						base_sum_x += fx * bw
						base_sum_y += fy * bw
						base_w_sum += bw
						min_hx = min(min_hx, abs(fx))
						max_hx = max(max_hx, abs(fx))
						min_hy = min(min_hy, fy)
						max_hy = max(max_hy, fy)
					}
					if dz > peak_dz * 0.72 {
						// Apex region (top of the hill)
						aw := dz * dz
						apex_sum += [3]f32{fx, fy, z_surf[iy][ix] * fwd_z_sign} * aw
						apex_w_sum += aw
					}
				}
			}

			res.apex_pos = apex_w_sum > 0 ? (apex_sum / apex_w_sum) : peak_pt
			bx := base_w_sum > 0 ? (base_sum_x / base_w_sum) : res.apex_pos.x
			by := base_w_sum > 0 ? (base_sum_y / base_w_sum) : res.apex_pos.y + 0.012
			// If gravity pulls the breast down, the anatomical pectoral attachment on the ribcage
			// sits slightly higher than the hill centroid:
			pectoral_root_y := max(by, math.lerp(res.apex_pos.y, max_hy if max_hy > min_hy else by, f32(0.38)))
			flat_root_z     := eval_flat_chest_z(bx, pectoral_root_y, x_max, y_bot, y_top, row_sternum_z, row_edge_l_z, row_edge_r_z)

			res.base_pos = {bx, pectoral_root_y, flat_root_z * fwd_z_sign}
			res.root_pos = {bx, pectoral_root_y, (flat_root_z - 0.012) * fwd_z_sign}
			res.peak_dz  = peak_dz

			res.radius_horiz = clamp(0.55 * (max_hx - min_hx) + 0.028, 0.060, 0.140)
			// Extend upper vertical reach across the sub-clavicular pectoralis major muscle shelf
			res.radius_upper = clamp((max_hy - res.apex_pos.y) * 1.45 + 0.042, 0.088, 0.180)
			res.radius_lower = clamp((res.apex_pos.y - min_hy) * 1.05 + 0.015, 0.042, 0.115)
			res.valid = true
		} else {
			// Fallback anatomical estimate when chest is flat / armored
			bx := 0.072 * side_x_sign
			by := math.lerp(y_bot, y_top, f32(0.52))
			fz := eval_flat_chest_z(bx, by, x_max, y_bot, y_top, row_sternum_z, row_edge_l_z, row_edge_r_z)
			res.root_pos     = {bx, by, (fz - 0.01) * fwd_z_sign}
			res.base_pos     = {bx, by, fz * fwd_z_sign}
			res.apex_pos     = {bx, by - 0.008, (fz + 0.045) * fwd_z_sign}
			res.peak_dz      = 0.045
			res.radius_horiz = 0.088
			res.radius_upper = 0.120
			res.radius_lower = 0.075
			res.valid        = true
		}

		sag_vec := res.apex_pos - res.root_pos
		res.bone_len = clamp(linalg.length(sag_vec), 0.045, 0.16)
		res.sag_dir  = linalg.normalize0(sag_vec)
		if linalg.length2(res.sag_dir) < 1e-4 {
			res.sag_dir = {0, 0, fwd_z_sign}
		}
		horiz_fwd := linalg.normalize0([3]f32{res.sag_dir.x * 0.25, 0.0, res.sag_dir.z})
		res.sag_deg = math.to_degrees(math.acos(clamp(linalg.dot(res.sag_dir, horiz_fwd), -1.0, 1.0)))
		if res.sag_dir.y < 0 do res.sag_deg = -res.sag_deg
		return res
	}

	hill_l := analyze_side_hill( left_x_sign, x_max, y_bot, y_top, fwd_z_sign, &z_surf, &z_valid, &row_sternum_z, &row_edge_l_z, &row_edge_r_z)
	hill_r := analyze_side_hill(-left_x_sign, x_max, y_bot, y_top, fwd_z_sign, &z_surf, &z_valid, &row_sternum_z, &row_edge_l_z, &row_edge_r_z)

	smart_rig_async_state.left_hill_peak_mm  = hill_l.peak_dz * 1000.0
	smart_rig_async_state.right_hill_peak_mm = hill_r.peak_dz * 1000.0
	smart_rig_async_state.left_sag_deg       = hill_l.sag_deg
	smart_rig_async_state.right_sag_deg      = hill_r.sag_deg

	// 6. Convert hill roots into `chest_bone` local coordinates and spawn `breast_l` & `breast_r`
	chest_tw := engine.transform_world(chest_bone)
	chest_q  := linalg.normalize(engine.quat_to_native(chest_tw.rotation))
	inv_chest_q := linalg.quaternion_inverse(chest_q)
	chest_s  := [3]f32{max(abs(chest_tw.scale.x), 0.001), max(abs(chest_tw.scale.y), 0.001), max(abs(chest_tw.scale.z), 0.001)}

	world_root_l := to_world(hill_l.root_pos, actor_pos, actor_rot, actor_scale)
	world_root_r := to_world(hill_r.root_pos, actor_pos, actor_rot, actor_scale)
	world_apex_l := to_world(hill_l.apex_pos, actor_pos, actor_rot, actor_scale)
	world_apex_r := to_world(hill_r.apex_pos, actor_pos, actor_rot, actor_scale)

	chest_local_l := linalg.quaternion128_mul_vector3(inv_chest_q, world_root_l - chest_tw.position) / chest_s
	chest_local_r := linalg.quaternion128_mul_vector3(inv_chest_q, world_root_r - chest_tw.position) / chest_s

	ok_l, ok_r: bool
	left_h, ok_l  = armature_add_child_bone(adm, chest_bone, "breast_l", chest_local_l)
	right_h, ok_r = armature_add_child_bone(adm, chest_bone, "breast_r", chest_local_r)
	if !ok_l || !ok_r do return left_h, right_h, 0, false

	// 7. Recursive Topographic Weight Distribution (with Gravity-Crease Asymmetry & Pectoral Muscle Blend)
	if len(adm.custom_skin) != len(bind_verts) {
		if adm.custom_skin == nil do adm.custom_skin = make([dynamic]engine.Mesh_Skin_Vertex)
		resize(&adm.custom_skin, len(bind_verts))
		copy(adm.custom_skin[:], mesh.skin)
	} else if len(adm.custom_joint_names) <= 2 && len(mesh.skin) == len(bind_verts) {
		// Always reset from the clean bind skin when re-running breast auto-weights so changing
		// recursion_passes (e.g. 1..6) computes a fresh weight map instead of stacking!
		copy(adm.custom_skin[:], mesh.skin)
	}

	idx_l := armature_get_bone_joint_index(adm, left_h)
	idx_r := armature_get_bone_joint_index(adm, right_h)
	if idx_l < 0 || idx_r < 0 do return left_h, right_h, 0, false

	// Collect all torso/spine/clavicle joint indices that are allowed to donate skin weight to the breasts
	// (ensures we NEVER steal weight from arms, hands, neck, or head!)
	donor_joints := make([dynamic]int, 0, 12, context.temp_allocator)
	for j_h, ji in adm.joints {
		if j_h == {} || j_h == left_h || j_h == right_h do continue
		if j_h == chest_bone || j_h == bones.chest || j_h == bones.spine || j_h == bones.pelvis {
			append(&donor_joints, ji)
			continue
		}
		if jt := engine.pool_get(&w.transforms, engine.Handle(j_h)); jt != nil {
			nn := strings.to_lower(jt.name, context.temp_allocator)
			if strings.contains(nn, "spine") || strings.contains(nn, "chest") || strings.contains(nn, "rib") ||
			   strings.contains(nn, "pect") || strings.contains(nn, "clavicle") || strings.contains(nn, "collar") ||
			   strings.contains(nn, "shoulder") || strings.contains(nn, "torso") || strings.contains(nn, "upper") {
				if !strings.contains(nn, "arm") && !strings.contains(nn, "hand") && !strings.contains(nn, "leg") {
					append(&donor_joints, ji)
				}
			}
		}
	}

	num_v := len(bind_verts)
	w_left  := make([]f32, num_v, context.temp_allocator)
	w_right := make([]f32, num_v, context.temp_allocator)
	pinned  := make([]bool, num_v, context.temp_allocator) // True for ribcage/sternum vertices that must remain 0

	// Weld coincident 3D bind vertex positions (within 0.5mm) so flat-shaded / UV-split meshes
	// share smoothed normals, smooth weights across triangle seams, and receive 100% identical
	// joint weights at shared 3D corners (eliminating "balloon puzzle-piece" triangle separation!).
	Weld_Key :: struct {
		qx, qy, qz: i32,
	}
	weld_map    := make(map[Weld_Key]int, num_v, context.temp_allocator)
	canon_idx   := make([]int, num_v, context.temp_allocator)
	welded_norm := make([][3]f32, num_v, context.temp_allocator)

	for vi in 0 ..< num_v {
		vp := bind_verts[vi].position
		key := Weld_Key{
			qx = i32(math.round(vp.x * 2000.0)),
			qy = i32(math.round(vp.y * 2000.0)),
			qz = i32(math.round(vp.z * 2000.0)),
		}
		if rep, exists := weld_map[key]; exists {
			canon_idx[vi] = rep
			welded_norm[rep] += bind_verts[vi].normal
		} else {
			weld_map[key] = vi
			canon_idx[vi] = vi
			welded_norm[vi] = bind_verts[vi].normal
		}
	}
	for vi in 0 ..< num_v {
		if canon_idx[vi] == vi {
			welded_norm[vi] = linalg.normalize0(welded_norm[vi])
		}
	}

	eval_hill_weight :: proc(
		vp, vn: [3]f32,
		hill: Breast_Hill_Analysis,
		side_x_sign, fwd_z_sign: f32,
		x_max, y_bot, y_top: f32,
		row_sternum_z, row_edge_l_z, row_edge_r_z: ^[GRID_Y]f32,
	) -> (w: f32, is_ribcage_pin: bool) {
		if vp.x * side_x_sign < 0.006 do return 0.0, true
		if vp.y < y_bot - 0.035 || vp.y > y_top + 0.025 do return 0.0, true
		if vp.z * fwd_z_sign < (hill.base_pos.z * fwd_z_sign - 0.020) do return 0.0, true
		// Back-facing vertices on the shoulder blades must never be weighted to breasts
		if linalg.length2(vn) > 0.1 && vn.z * fwd_z_sign < -0.15 do return 0.0, true

		flat_z := eval_flat_chest_z(vp.x, vp.y, x_max, y_bot, y_top, row_sternum_z, row_edge_l_z, row_edge_r_z)
		dz := max(0.0, vp.z * fwd_z_sign - flat_z)

		// Project vertex onto the root -> apex hill segment
		seg := hill.apex_pos - hill.base_pos
		seg_len2 := linalg.length2(seg)
		t_seg := seg_len2 > 1e-6 ? clamp(linalg.dot(vp - hill.base_pos, seg) / seg_len2, 0.0, 1.0) : 0.5
		closest := hill.base_pos + seg * t_seg

		// Asymmetric vertical radius: tighter below apex (gravity under-bust crease), softer above apex (upper pectoral muscle shelf)
		ry := vp.y >= closest.y ? hill.radius_upper : hill.radius_lower
		dy := (vp.y - closest.y) / max(ry, 0.035)
		// Pectoralis major fans upward and slightly outward toward the anterior shoulder/clavicle
		upper_t   := vp.y > closest.y ? clamp(dy, 0.0, 1.0) : 0.0
		eff_rx    := max(hill.radius_horiz * (1.0 + 0.28 * upper_t), 0.04)
		pect_x_c  := closest.x + side_x_sign * (0.014 * upper_t)
		dx        := (vp.x - pect_x_c) / eff_rx
		dz_rel    := (vp.z - closest.z) / max(hill.radius_horiz, 0.045)
		dz_weight := vp.y >= closest.y ? f32(0.18) : f32(0.35)

		d2 := dx * dx + dy * dy + dz_rel * dz_rel * dz_weight
		if d2 >= 1.0 {
			// Only hard-pin vertices far outside the pectoral fan or below the lower rib crease
			// so recursive smoothing passes (1..6) can smoothly diffuse across the upper pectoral muscle!
			is_outer_pin := d2 > 1.38 || vp.y < closest.y - hill.radius_lower * 1.05 || abs(vp.x) < 0.012
			return 0.0, is_outer_pin
		}

		// Smooth C2 quartic radial falloff
		radial_w := (1.0 - d2) * (1.0 - d2)

		// Hill elevation boost: vertices sitting high on the breast hill receive strong influence,
		// while the upper pectoral muscle shelf (`vp.y >= closest.y`) retains a smooth muscular flex blend!
		elev_floor := vp.y >= closest.y ? f32(0.42) : f32(0.20)
		elev_ratio := clamp(dz / max(hill.peak_dz * 0.65, 0.012), elev_floor, 1.0)
		sternum_guard := math.smoothstep(f32(0.008), f32(0.034), abs(vp.x))

		final_w := radial_w * math.lerp(f32(0.48), f32(1.0), elev_ratio) * sternum_guard * 0.88
		return clamp(final_w, 0.0, 0.90), false
	}

	for vi in 0 ..< num_v {
		c := canon_idx[vi]
		if c != vi {
			w_left[vi]  = w_left[c]
			w_right[vi] = w_right[c]
			pinned[vi]  = pinned[c]
			continue
		}
		vp := bind_verts[c].position
		vn := welded_norm[c]
		wl, pin_l := eval_hill_weight(vp, vn, hill_l,  left_x_sign, fwd_z_sign, x_max, y_bot, y_top, &row_sternum_z, &row_edge_l_z, &row_edge_r_z)
		wr, pin_r := eval_hill_weight(vp, vn, hill_r, -left_x_sign, fwd_z_sign, x_max, y_bot, y_top, &row_sternum_z, &row_edge_l_z, &row_edge_r_z)
		w_left[c]  = wl
		w_right[c] = wr
		pinned[c]  = (wl <= 0.001 && wr <= 0.001) && (pin_l && pin_r)
	}

	// Build welded chest triangle adjacency for recursive topological weight smoothing across split seams
	num_rec := clamp(recursion_passes, 1, 6)
	if num_rec > 0 {
		w_left_next  := make([]f32, num_v, context.temp_allocator)
		w_right_next := make([]f32, num_v, context.temp_allocator)
		deg          := make([]f32, num_v, context.temp_allocator)

		for _ in 0 ..< num_rec {
			copy(w_left_next, w_left)
			copy(w_right_next, w_right)
			for i in 0 ..< num_v do deg[i] = 1.0

			for ti in 0 ..< tri_count {
				raw0 := int(indices[ti * 3 + 0])
				raw1 := int(indices[ti * 3 + 1])
				raw2 := int(indices[ti * 3 + 2])
				if raw0 >= num_v || raw1 >= num_v || raw2 >= num_v do continue
				i0 := canon_idx[raw0]
				i1 := canon_idx[raw1]
				i2 := canon_idx[raw2]
				if pinned[i0] && pinned[i1] && pinned[i2] do continue

				w_left_next[i0]  += (w_left[i1] + w_left[i2]) * 0.35
				w_right_next[i0] += (w_right[i1] + w_right[i2]) * 0.35
				deg[i0]          += 0.70

				w_left_next[i1]  += (w_left[i0] + w_left[i2]) * 0.35
				w_right_next[i1] += (w_right[i0] + w_right[i2]) * 0.35
				deg[i1]          += 0.70

				w_left_next[i2]  += (w_left[i0] + w_left[i1]) * 0.35
				w_right_next[i2] += (w_right[i0] + w_right[i1]) * 0.35
				deg[i2]          += 0.70
			}

			for vi in 0 ..< num_v {
				if canon_idx[vi] != vi do continue
				if pinned[vi] {
					w_left[vi]  = 0.0
					w_right[vi] = 0.0
				} else {
					// Preserve peak apex anchor while smoothing contour transitions
					w_left[vi]  = max(w_left[vi] * 0.82, w_left_next[vi] / deg[vi])
					w_right[vi] = max(w_right[vi] * 0.82, w_right_next[vi] / deg[vi])
				}
			}
			for vi in 0 ..< num_v {
				c := canon_idx[vi]
				if c != vi {
					w_left[vi]  = w_left[c]
					w_right[vi] = w_right[c]
				}
			}
		}
	}

	// Apply computed recursive weights into `adm.custom_skin` while enforcing strict partition of unity
	apply_vertex_breast_weight :: proc(sv: ^engine.Mesh_Skin_Vertex, breast_j_idx: int, desired_w: f32, donors: []int) -> bool {
		if desired_w <= 0.002 do return false

		// Sum available weight on torso donor joints
		donor_sum: f32 = 0.0
		for k in 0 ..< 4 {
			if sv.weights[k] <= 0.001 do continue
			ji := int(sv.joints[k])
			for d_idx in donors {
				if ji == d_idx {
					donor_sum += sv.weights[k]
					break
				}
			}
		}
		if donor_sum <= 0.02 do return false

		stolen := min(desired_w, donor_sum * 0.92)
		if stolen <= 0.002 do return false

		// Deduct proportionally from torso donor joints
		for k in 0 ..< 4 {
			if sv.weights[k] <= 0.001 do continue
			ji := int(sv.joints[k])
			for d_idx in donors {
				if ji == d_idx {
					ratio := sv.weights[k] / donor_sum
					sv.weights[k] = max(0.0, sv.weights[k] - stolen * ratio)
					break
				}
			}
		}

		// Find target slot for `breast_j_idx`
		slot := -1
		for k in 0 ..< 4 {
			if int(sv.joints[k]) == breast_j_idx {
				slot = k
				break
			}
		}
		if slot < 0 {
			min_k := 0
			min_v: f32 = 999.0
			for k in 0 ..< 4 {
				if sv.weights[k] <= 0.001 {
					min_k = k
					break
				}
				if sv.weights[k] < min_v {
					min_v = sv.weights[k]
					min_k = k
				}
			}
			slot = min_k
			sv.joints[slot]  = u16(breast_j_idx)
			sv.weights[slot] = 0.0
		}
		sv.weights[slot] = stolen

		// Normalize partition of unity
		tot: f32 = 0.0
		for k in 0 ..< 4 do tot += sv.weights[k]
		if tot > 0.0001 {
			for k in 0 ..< 4 do sv.weights[k] /= tot
		}
		return true
	}

	canon_changed := make([]bool, num_v, context.temp_allocator)
	for vi in 0 ..< num_v {
		if canon_idx[vi] != vi do continue
		sv := &adm.custom_skin[vi]
		changed_l := apply_vertex_breast_weight(sv, idx_l, w_left[vi], donor_joints[:])
		changed_r := apply_vertex_breast_weight(sv, idx_r, w_right[vi], donor_joints[:])
		if changed_l || changed_r {
			canon_changed[vi] = true
			weighted_verts += 1
		}
	}
	// Copy exact custom_skin weights to all coincident split vertices so triangles sharing a 3D corner
	// move as a 100% seamless watertight surface without ever peeling apart!
	for vi in 0 ..< num_v {
		c := canon_idx[vi]
		if c != vi && canon_changed[c] {
			adm.custom_skin[vi] = adm.custom_skin[c]
			weighted_verts += 1
		}
	}

	// 8. Attach `SpringBone` dynamics aligned with the natural gravity-sag vector + fitted `SphereCollider`s!
	setup_breast_spring_and_collider :: proc(
		bone_h:       engine.Transform_Handle,
		world_root:   [3]f32,
		world_apex:   [3]f32,
		hill:         Breast_Hill_Analysis,
		with_collider: bool,
	) {
		bt := engine.transform_world(bone_h)
		bq := linalg.normalize(engine.quat_to_native(bt.rotation))
		inv_bq := linalg.quaternion_inverse(bq)
		bs := [3]f32{max(abs(bt.scale.x), 0.001), max(abs(bt.scale.y), 0.001), max(abs(bt.scale.z), 0.001)}

		local_tip_vec := linalg.quaternion128_mul_vector3(inv_bq, world_apex - world_root) / bs
		tip_len := linalg.length(local_tip_vec)
		fwd_axis := tip_len > 0.005 ? (local_tip_vec / tip_len) : [3]f32{0, 0, 1}

		_, raw_sb := engine.transform_add_comp(bone_h, .SpringBone)
		if raw_sb != nil {
			sb := cast(^SpringBone)raw_sb
			sb.stiffness     = 42.0
			sb.damping       = 0.68
			sb.gravity       = {0, -0.85, 0}
			sb.drag          = 0.06
			sb.max_angle_deg = 28.0
			sb.bone_length   = clamp(tip_len, 0.05, 0.14)
			sb.forward_axis  = fwd_axis
			sb.initialized   = false
		}

		if with_collider {
			sph_rad := clamp(hill.radius_horiz * 0.72, 0.038, 0.095) / max(bs.x, max(bs.y, bs.z))
			sph_center := local_tip_vec * 0.52
			_attach_or_update_sphere(bone_h, sph_rad, sph_center)
		}
	}

	setup_breast_spring_and_collider(left_h, world_root_l, world_apex_l, hill_l, attach_colliders)
	setup_breast_spring_and_collider(right_h, world_root_r, world_apex_r, hill_r, attach_colliders)

	// Also refit the parent chest bone collider to the flattened ribcage so it doesn't oversize over the breasts!
	if attach_colliders {
		char_right, _, char_fwd := _get_character_axes(owner_h, &bones)
		skin := adm.custom_skin[:]
		_trace_fit_limb_capsule(
			chest_bone,
			bones.head,
			adm,
			world_verts,
			indices,
			skin,
			char_right,
			char_fwd,
			default_radius = 0.14,
			min_r          = 0.09,
			max_r          = 0.175,
			default_len    = 0.28,
			passes         = 3,
			exclude_hills  = true,
		)
	}

	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return left_h, right_h, weighted_verts, true
}

// =============================================================================
// CLEANUP & SINGLE-BONE AUTO FITTERS
// =============================================================================

// Cleans up all generated colliders from the character's humanoid bones (and any custom spine/breast bones).
smart_collider_remove_humanoid :: proc(char_h: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil || char_h == {} do return

	adm := _resolve_character_adm(char_h)
	if adm != nil {
		for j in adm.joints {
			if j == {} || !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue
			engine.transform_destroy_comp(j, physics3d.CapsuleCollider)
			engine.transform_destroy_comp(j, physics3d.BoxCollider)
			engine.transform_destroy_comp(j, physics3d.SphereCollider)
		}
	}

	bones: Humanoid_Bones
	if skeleton_bind_humanoid(&bones, char_h) {
		bone_list := [15]engine.Transform_Handle{
			bones.head, bones.pelvis, bones.spine, bones.chest,
			bones.left_upperarm, bones.left_lowerarm, bones.left_hand,
			bones.right_upperarm, bones.right_lowerarm, bones.right_hand,
			bones.left_thigh, bones.left_calf, bones.left_foot,
			bones.right_thigh, bones.right_calf,
		}
		for b in bone_list {
			if b == {} do continue
			engine.transform_destroy_comp(b, physics3d.CapsuleCollider)
			engine.transform_destroy_comp(b, physics3d.BoxCollider)
			engine.transform_destroy_comp(b, physics3d.SphereCollider)
		}
	}

	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

smart_collider_add_capsule :: proc(bone_h: engine.Transform_Handle, radius: f32 = 0.08, height: f32 = 0.30, dir: physics3d.Capsule_Direction = .Y_Axis, center: [3]f32 = {0, 0, 0}, rotation: [4]f32 = {0, 0, 0, 1}) {
	_attach_or_update_capsule(bone_h, radius, height, dir, center, rotation)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

smart_collider_add_box :: proc(bone_h: engine.Transform_Handle, size: [3]f32 = {0.12, 0.12, 0.12}, center: [3]f32 = {0, 0, 0}, rotation: [4]f32 = {0, 0, 0, 1}) {
	_attach_or_update_box(bone_h, size, center, rotation)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

smart_collider_add_sphere :: proc(bone_h: engine.Transform_Handle, radius: f32 = 0.08, center: [3]f32 = {0, 0, 0}) {
	_attach_or_update_sphere(bone_h, radius, center)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

smart_collider_remove_from_bone :: proc(bone_h: engine.Transform_Handle) {
	if bone_h == {} do return
	engine.transform_destroy_comp(bone_h, physics3d.CapsuleCollider)
	engine.transform_destroy_comp(bone_h, physics3d.BoxCollider)
	engine.transform_destroy_comp(bone_h, physics3d.SphereCollider)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

smart_collider_add_bone_auto :: proc(bone_h: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil || bone_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	t := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if t == nil do return

	// Find owning character & ArmatureDeformedMesh if this bone belongs to a rigged mesh
	owner_h: engine.Transform_Handle = {}
	adm: ^ArmatureDeformedMesh = nil
	it := engine.pool_iterator(armature_deformed_meshes(w))
	for candidate, _ in engine.pool_next(&it) {
		for j in candidate.joints {
			if j == bone_h {
				adm = candidate
				owner_h = engine.Transform_Handle(candidate.owner)
				break
			}
		}
		if adm != nil do break
	}

	if adm != nil && owner_h != {} {
		bones: Humanoid_Bones
		skeleton_bind_humanoid(&bones, owner_h)
		world_verts, indices, m, ok := armature_ensure_posed_world_geometry(adm)
		if ok && m != nil {
			skin := adm.custom_skin[:] if len(adm.custom_skin) == len(m.bind_vertices) else m.skin
			char_right, char_up, char_fwd := _get_character_axes(owner_h, &bones)

			if bone_h == bones.left_hand || bone_h == bones.right_hand {
				la := bone_h == bones.left_hand ? bones.left_lowerarm : bones.right_lowerarm
				_trace_fit_hand_box(bone_h, la, bone_h == bones.right_hand, adm, world_verts, indices, skin, char_up, char_fwd, 3)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				return
			}
			if bone_h == bones.left_foot || bone_h == bones.right_foot {
				toe  := bone_h == bones.left_foot ? bones.left_toe  : bones.right_toe
				calf := bone_h == bones.left_foot ? bones.left_calf : bones.right_calf
				_trace_fit_foot_box(bone_h, toe, calf, owner_h, adm, world_verts, indices, skin, char_fwd, 3)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				return
			}

			child_h: engine.Transform_Handle = {}
			for ch_ref in t.children {
				ch := engine.Transform_Handle(ch_ref.handle)
				if ch != {} && engine.pool_valid(&w.transforms, ch_ref.handle) {
					child_h = ch
					break
				}
			}
			_trace_fit_limb_capsule(
				bone_h,
				child_h,
				adm,
				world_verts,
				indices,
				skin,
				char_right,
				char_fwd,
				default_radius = 0.065,
				min_r          = 0.025,
				max_r          = 0.165,
				default_len    = 0.25,
				passes         = 3,
				exclude_hills  = (bone_h == bones.chest),
			)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			return
		}
	}

	// Fallback if no mesh is bound
	child_h: engine.Transform_Handle = {}
	if len(t.children) > 0 {
		for ch_ref in t.children {
			ch := engine.Transform_Handle(ch_ref.handle)
			if ch != {} && engine.pool_valid(&w.transforms, ch_ref.handle) {
				child_h = ch
				break
			}
		}
	}

	_attach_limb_capsule(bone_h, child_h, radius = 0.065, default_len = 0.25)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// =============================================================================
// 6. GHOUL CSG BODY COLLIDER & LIMB DISMEMBERMENT SYSTEM
//    (Soldier of Fortune "Ghoul" / Helldivers Limb Destruction Mode)
// =============================================================================

// Builds or updates a bone-attached `cad_csg.CSGVolume` from `bone_h`'s current `CapsuleCollider`,
// `BoxCollider`, or `SphereCollider` (including its full 3D `rotation` quaternion!) AND contours an
// oriented 18-plane convex polyhedron (`CSG_Convex`) around both the rotated collider and `bone_h`'s
// weighted skin vertices in `adm`. Keeps the bone's primitive collider 100% intact!
smart_collider_build_ghoul_csg_from_bone :: proc(
	bone_h:            engine.Transform_Handle,
	adm:               ^ArmatureDeformedMesh = nil,
	tight_heatmap_fit: bool = true,
) -> bool {
	w := engine.ctx_world()
	if w == nil || bone_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return false

	_, cap := engine.transform_get_comp(bone_h, physics3d.CapsuleCollider)
	_, box := engine.transform_get_comp(bone_h, physics3d.BoxCollider)
	_, sph := engine.transform_get_comp(bone_h, physics3d.SphereCollider)
	if cap == nil && box == nil && sph == nil do return false

	col_center := [3]f32{0, 0, 0}
	col_rot_q  := linalg.QUATERNIONF32_IDENTITY
	half_ext   := [3]f32{0.06, 0.10, 0.06}
	is_box_col := false

	if cap != nil {
		col_center = cap.center
		col_rot_q  = engine.quat_to_native(cap.rotation)
		r          := max(cap.radius, 0.018)
		half_h     := max(cap.height * 0.5, 0.005) + r
		half_ext   = {r, half_h, r}
	} else if box != nil {
		col_center = box.center
		col_rot_q  = engine.quat_to_native(box.rotation)
		half_ext   = {max(box.size.x * 0.5, 0.015), max(box.size.y * 0.5, 0.015), max(box.size.z * 0.5, 0.015)}
		is_box_col = true
	} else if sph != nil {
		col_center = sph.center
		r          := max(sph.radius, 0.02)
		half_ext   = {r, r, r}
	}

	// Orthonormal basis of the bone's rotated collider in `bone_h` local space
	ax_x := linalg.normalize0(linalg.quaternion128_mul_vector3(col_rot_q, [3]f32{1, 0, 0}))
	ax_y := linalg.normalize0(linalg.quaternion128_mul_vector3(col_rot_q, [3]f32{0, 1, 0}))
	ax_z := linalg.normalize0(linalg.quaternion128_mul_vector3(col_rot_q, [3]f32{0, 0, 1}))
	if linalg.length2(ax_x) < 0.5 do ax_x = {1, 0, 0}
	if linalg.length2(ax_y) < 0.5 do ax_y = {0, 1, 0}
	if linalg.length2(ax_z) < 0.5 do ax_z = {0, 0, 1}

	// Build 18 oriented DOP plane normals aligned with the rotated collider's axes `(ax_x, ax_y, ax_z)`
	// (6 principal faces + 4 octagonal cylinder bevels around `ax_y` + 8 dome/tip bevels at `±ax_y`)
	dirs := make([dynamic][3]f32, 0, 18, context.temp_allocator)
	append(&dirs,  ax_x, -ax_x,  ax_y, -ax_y,  ax_z, -ax_z)
	if !is_box_col {
		// Octagonal limb/torso cross-section around `ax_y`
		append(&dirs,
			linalg.normalize0( ax_x + ax_z),
			linalg.normalize0( ax_x - ax_z),
			linalg.normalize0(-ax_x + ax_z),
			linalg.normalize0(-ax_x - ax_z),
		)
		// Rounded capsule end-caps at +ax_y and -ax_y
		append(&dirs,
			linalg.normalize0( ax_y + ax_x * 0.85),
			linalg.normalize0( ax_y - ax_x * 0.85),
			linalg.normalize0( ax_y + ax_z * 0.85),
			linalg.normalize0( ax_y - ax_z * 0.85),
			linalg.normalize0(-ax_y + ax_x * 0.85),
			linalg.normalize0(-ax_y - ax_x * 0.85),
			linalg.normalize0(-ax_y + ax_z * 0.85),
			linalg.normalize0(-ax_y - ax_z * 0.85),
		)
	}

	// Collect weighted skin vertices (`w >= 0.15`) in `bone_h` local space so the Ghoul CSG hull
	// wraps the actual mesh triangles of this bone while respecting the rotated collider frame!
	skin_pts := make([dynamic][3]f32, 0, 64, context.temp_allocator)
	if tight_heatmap_fit && adm != nil {
		j_idx := armature_get_bone_joint_index(adm, bone_h)
		world_verts, _, m, ok := armature_ensure_posed_world_geometry(adm)
		if ok && m != nil && j_idx >= 0 {
			skin := adm.custom_skin[:] if len(adm.custom_skin) == len(m.bind_vertices) else m.skin
			bone_tw := engine.transform_world(bone_h)
			inv_bone := linalg.inverse(engine.trs_matrix(bone_tw.position, bone_tw.rotation, bone_tw.scale))
			max_reach := linalg.length(half_ext) * 1.65 + 0.08
			for v_i in 0 ..< min(len(world_verts), len(skin)) {
				sv := skin[v_i]
				w_val: f32 = 0
				for k in 0 ..< 4 {
					if int(sv.joints[k]) == j_idx {
						w_val = sv.weights[k]
						break
					}
				}
				if w_val >= 0.18 {
					wp := world_verts[v_i].position
					lp := (inv_bone * [4]f32{wp.x, wp.y, wp.z, 1.0}).xyz
					if linalg.length(lp - col_center) <= max_reach {
						append(&skin_pts, lp)
					}
				}
			}
		}
	}

	prev_a := context.allocator
	alloc := runtime.default_allocator()
	context.allocator = alloc
	defer context.allocator = prev_a

	_, vol := engine.transform_get_comp(bone_h, cad_csg.CSGVolume)
	if vol == nil {
		_, ptr := engine.transform_add_comp(bone_h, .CSGVolume)
		vol = cast(^cad_csg.CSGVolume)ptr
		if vol != nil {
			cad_csg.reset_CSGVolume(vol)
		}
	}
	if vol == nil do return false

	if vol.brushes != nil {
		for &b in vol.brushes {
			if len(b.name) > 0 do delete(b.name)
			if b.profile_points != nil do delete(b.profile_points)
		}
		clear(&vol.brushes)
	}
	if vol.runtime_hulls != nil {
		for &rh in vol.runtime_hulls do cad_csg.convex_destroy(&rh)
		clear(&vol.runtime_hulls)
	} else {
		vol.runtime_hulls = make([dynamic]cad_csg.CSG_Convex, 0, 2, alloc)
	}
	if vol.recorded_blasts != nil {
		clear(&vol.recorded_blasts)
	}

	// Build the oriented 3D `CSG_Convex` hull from `dirs`
	hull := cad_csg.CSG_Convex{
		planes   = make([dynamic]cad_csg.CSG_Plane, 0, len(dirs), alloc),
		anchored = true,
		brush_id = 1,
	}

	// Analytical support of the rotated capsule/box/sphere along direction `d`, blended with `skin_pts` support
	cyl_half_y := max(half_ext.y - half_ext.x, 0.0) if cap != nil else 0.0
	for d in dirs {
		// 1. Collider support distance along `d`
		col_sup: f32 = -1e9
		if cap != nil {
			// Capsule = segment `col_center ± ax_y * cyl_half_y` + sphere of radius `half_ext.x`
			p_top := col_center + ax_y * cyl_half_y
			p_bot := col_center - ax_y * cyl_half_y
			col_sup = max(linalg.dot(d, p_top), linalg.dot(d, p_bot)) + half_ext.x
		} else if sph != nil {
			col_sup = linalg.dot(d, col_center) + half_ext.x
		} else {
			// Rotated OBB support function
			col_sup = linalg.dot(d, col_center) +
			          abs(linalg.dot(d, ax_x)) * half_ext.x +
			          abs(linalg.dot(d, ax_y)) * half_ext.y +
			          abs(linalg.dot(d, ax_z)) * half_ext.z
		}

		// 2. Weighted skin vertex support along `d` (if available):
		//    Fit radial cross-section planes tightly to `skin_sup + 0.005m` (like `.fmesh`!) so wound caps match the actual limb contour,
		//    and ensure the bone's proximal joint origin `{0, 0, 0}` is always enclosed inside the un-blasted hull!
		final_dist := col_sup
		if len(skin_pts) >= 6 {
			skin_sup: f32 = -1e9
			for sp in skin_pts {
				pr := linalg.dot(d, sp)
				if pr > skin_sup do skin_sup = pr
			}
			is_radial := abs(linalg.dot(d, ax_y)) < 0.75
			if is_radial {
				final_dist = clamp(skin_sup + 0.005, col_sup * 0.45, col_sup + 0.015)
			} else {
				final_dist = max(math.lerp(col_sup, skin_sup + 0.008, f32(0.65)), skin_sup + 0.006)
			}
		}
		// Guarantee the bone's proximal joint origin `{0, 0, 0}` lies inside the un-blasted Ghoul hull
		final_dist = max(final_dist, 0.018)

		append(&hull.planes, cad_csg.quantize_plane(cad_csg.CSG_Plane{
			normal        = d,
			dist          = final_dist,
			mat_slot      = 0,
			uv_scale      = 1.0,
			uv_lock_brush = true, // Marks original outer anatomy envelope planes (vs. newly carved cut/partition planes)
			color         = {155, 28, 28, 255}, // Crimson flesh interior tint for carved wounds
		}))
	}

	if !cad_csg.convex_rebuild_bounds_and_prune(&hull, prune_redundant = true) {
		cad_csg.convex_destroy(&hull)
		return false
	}
	append(&vol.runtime_hulls, hull)

	// Retire/disable primitive colliders while Ghoul CSGVolume is active so Jolt & wireframe gizmos
	// use ONLY the destructible Ghoul CSG hulls (and never leave floating green capsules on severed limbs!).
	if cap != nil do cap.enabled = false
	if box != nil do box.enabled = false
	if sph != nil do sph.enabled = false

	vol.enabled                    = true
	vol.chunk_size                 = 4.0
	vol.material_preset            = .Wood_Plank
	vol.blast_resistance           = 0.75
	vol.enable_structural_collapse = false
	vol.spawn_debris               = false
	vol.cast_planar_shadows        = false
	vol.soft_deform_enabled        = false
	vol.is_ghoul_bone_csg          = true
	vol.destruction_backend        = .Pure_Convex_CSG
	vol.is_faker_mesh              = false
	vol.faker_hide_outer_shell     = true
	vol.faker_render_cut_interior  = true
	vol.next_brush_id              = 2

	cad_csg.csg_volume_rebuild(vol)
	cad_csg.csg_volume_sync_colliders_only(vol)
	if adm != nil {
		adm.last_ghoul_blast_sig = ~u64(0)
	}
	return true
}

// Converts all collider-equipped bones of `character_root` into Ghoul CSG volumes!
smart_collider_build_ghoul_csg_humanoid :: proc(
	character_root:    engine.Transform_Handle,
	tight_heatmap_fit: bool = true,
) -> int {
	w := engine.ctx_world()
	if w == nil || character_root == {} || !engine.pool_valid(&w.transforms, engine.Handle(character_root)) do return 0

	_, adm := engine.transform_get_comp(character_root, ArmatureDeformedMesh)
	count := 0

	build_rec :: proc(
		w:     ^engine.World,
		tH:    engine.Transform_Handle,
		adm:   ^ArmatureDeformedMesh,
		tight: bool,
		cnt:   ^int,
	) {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return
		if smart_collider_build_ghoul_csg_from_bone(tH, adm, tight) {
			cnt^ += 1
		}
		for ch in t.children {
			if ch.handle != {} && engine.pool_valid(&w.transforms, ch.handle) {
				build_rec(w, engine.Transform_Handle(ch.handle), adm, tight, cnt)
			}
		}
	}

	build_rec(w, character_root, adm, tight_heatmap_fit, &count)
	if adm != nil do adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return count
}

// Removes all bone-attached Ghoul `CSGVolume` components from `character_root` while keeping standard primitive colliders intact.
smart_collider_remove_ghoul_csg_humanoid :: proc(character_root: engine.Transform_Handle) -> int {
	w := engine.ctx_world()
	if w == nil || character_root == {} || !engine.pool_valid(&w.transforms, engine.Handle(character_root)) do return 0

	_, adm := engine.transform_get_comp(character_root, ArmatureDeformedMesh)
	removed := 0

	rem_rec :: proc(w: ^engine.World, root_h, tH: engine.Transform_Handle, cnt: ^int) {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return
		if tH != root_h {
			if _, vol := engine.transform_get_comp(tH, cad_csg.CSGVolume); vol != nil {
				engine.transform_destroy_comp(tH, cad_csg.CSGVolume)
				if _, cap := engine.transform_get_comp(tH, physics3d.CapsuleCollider); cap != nil do cap.enabled = true
				if _, box := engine.transform_get_comp(tH, physics3d.BoxCollider);     box != nil do box.enabled = true
				if _, sph := engine.transform_get_comp(tH, physics3d.SphereCollider);  sph != nil do sph.enabled = true
				cnt^ += 1
			}
		}
		for ch in t.children {
			if ch.handle != {} && engine.pool_valid(&w.transforms, ch.handle) {
				rem_rec(w, root_h, engine.Transform_Handle(ch.handle), cnt)
			}
		}
	}

	rem_rec(w, character_root, character_root, &removed)
	if adm != nil do adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return removed
}

// Heals / resets all Ghoul CSG blast craters, clip-plane slices, and boolean cuts across all bones of `character_root`,
// restoring the character mesh and bone Ghoul CSG hulls to pristine!
smart_collider_reset_ghoul_wounds :: proc(character_root: engine.Transform_Handle) -> int {
	w := engine.ctx_world()
	if w == nil || character_root == {} || !engine.pool_valid(&w.transforms, engine.Handle(character_root)) do return 0

	_, adm := engine.transform_get_comp(character_root, ArmatureDeformedMesh)
	healed := 0

	heal_rec :: proc(w: ^engine.World, tH: engine.Transform_Handle, adm: ^ArmatureDeformedMesh, cnt: ^int) {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return
		if _, vol := engine.transform_get_comp(tH, cad_csg.CSGVolume); vol != nil {
			if smart_collider_build_ghoul_csg_from_bone(tH, adm, true) {
				cnt^ += 1
			}
		}
		for ch in t.children {
			if ch.handle != {} && engine.pool_valid(&w.transforms, ch.handle) {
				heal_rec(w, engine.Transform_Handle(ch.handle), adm, cnt)
			}
		}
	}

	heal_rec(w, character_root, adm, &healed)
	if adm != nil {
		adm.posed_frame = 0
		adm.last_ghoul_blast_sig = ~u64(0)
	}
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return healed
}

// Fires a Geo-Mod Ghoul blast directly at `bone_h`'s collider center to test wound carving / limb dismemberment!
smart_collider_test_ghoul_blast_on_bone :: proc(bone_h: engine.Transform_Handle, radius: f32 = 0.14) {
	w := engine.ctx_world()
	if w == nil || bone_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	_, vol := engine.transform_get_comp(bone_h, cad_csg.CSGVolume)
	if vol == nil {
		// Automatically build Ghoul CSG on this bone first if not yet built!
		_ = smart_collider_build_ghoul_csg_from_bone(bone_h, nil, true)
		_, vol = engine.transform_get_comp(bone_h, cad_csg.CSGVolume)
	}
	if vol == nil do return

	local_c := [3]f32{0, 0, 0}
	if len(vol.runtime_hulls) > 0 {
		local_c = vol.runtime_hulls[0].centroid
	} else if len(vol.brushes) > 0 {
		local_c = vol.brushes[0].center
	}
	tw := engine.transform_world(bone_h)
	model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	world_hit := (model * [4]f32{local_c.x, local_c.y, local_c.z, 1.0}).xyz

	cad_csg.csg_trigger_blast(world_hit, max(radius, 0.08), 8.0)

	// Force character mesh to re-evaluate skin pose with the new Ghoul wound!
	it := engine.pool_iterator(armature_deformed_meshes(w))
	for adm, _ in engine.pool_next(&it) {
		adm.posed_frame = 0
		adm.last_ghoul_blast_sig = ~u64(0)
	}
}
