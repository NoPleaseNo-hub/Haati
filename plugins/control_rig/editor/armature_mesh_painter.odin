package control_rig_editor

// Interactive 3D Mesh Weight Paintbrush Tool.
// Inspired by Blender's Weight Paint Mode.
// Provides:
// 1. Precise geometric surface raycasting onto deformed skinned mesh triangles.
// 2. 3D surface circular brush gizmo aligned with surface normal and radius.
// 3. Interactive live painting with smooth polynomial falloff and real-time normalization.
// 4. Paint modes: Paint (lerp target), Add, Subtract, Smooth (blur neighbor weights).
// 5. Multi-frame grouped undo session per paint stroke.
// 6. Immediate real-time vertex color heatmap updates on the deformed GPU mesh.

import "core:math"
import "core:math/linalg"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import "haati:engine/gizmos"
import handles "haati:editor/handles"
import undo "haati:editor/undo"
import crig "haati:packages/control_rig"

Weight_Paint_Mode :: enum {
	Paint,    // Blends smoothly towards target weight (0.0 to 1.0)
	Add,      // Adds weight to selected joint up to 1.0
	Subtract, // Removes weight from selected joint down to 0.0
	Smooth,   // Blurs weights with surrounding neighbor vertices in radius
}

Weight_Painter_State :: struct {
	enabled:     bool,
	radius:      f32, // meters, default 0.06 (6 cm), range 0.002 to 0.250
	strength:    f32, // 0.05 to 1.0, default 0.35
	flow_rate:   f32, // accumulation speed per frame, 0.02 to 1.0, default 0.15
	weight:      f32, // target weight, default 1.0
	mode:        Weight_Paint_Mode,
	is_painting: bool,
	has_hit:     bool,
	hit_pos:     [3]f32,
	hit_normal:  [3]f32,
	hit_dist:    f32,
	undo_sess:   undo.Edit_Session,
}

weight_painter: Weight_Painter_State = {
	enabled   = false,
	radius    = 0.06,
	strength  = 0.35,
	flow_rate = 0.15,
	weight    = 1.0,
	mode      = .Paint,
}

// True while the weight painter owns mouse interaction in the scene view
is_brush_painting :: proc() -> bool {
	return scene_viewport_mode == .Control_Rig &&
	       character_edit_mode == .Bone_Mode &&
	       weight_painter.enabled &&
	       (weight_painter.is_painting || (weight_painter.has_hit && im.IsMouseDown(.Left)))
}

@(private = "file")
_ray_hit_triangle_bary :: proc(ray: engine.Ray, a, b, c: [3]f32) -> (t, u, v: f32, hit: bool) {
	EPS :: f32(1e-9)
	edge1 := b - a
	edge2 := c - a
	h := linalg.cross(ray.direction, edge2)
	det := linalg.dot(edge1, h)
	if abs(det) < EPS do return 0, 0, 0, false

	inv_det := 1.0 / det
	s := ray.origin - a
	u_bary := linalg.dot(s, h) * inv_det
	if u_bary < 0 || u_bary > 1 do return 0, 0, 0, false

	q := linalg.cross(s, edge1)
	v_bary := linalg.dot(ray.direction, q) * inv_det
	if v_bary < 0 || u_bary + v_bary > 1 do return 0, 0, 0, false

	t_hit := linalg.dot(edge2, q) * inv_det
	if t_hit < 0 do return 0, 0, 0, false
	return t_hit, u_bary, v_bary, true
}

@(private = "file")
_weight_painter_raycast :: proc(ray: engine.Ray, adm: ^crig.ArmatureDeformedMesh) -> (hit_pos: [3]f32, hit_normal: [3]f32, hit_dist: f32, hit: bool) {
	if adm == nil || len(adm.posed) == 0 do return {}, {}, 0, false

	// 1. Fast AABB rejection with generous margin
	if adm.posed_min != adm.posed_max {
		margin := [3]f32{0.15, 0.15, 0.15}
		lo := adm.posed_min - margin
		hi := adm.posed_max + margin
		if _, aabb_hit := engine.ray_hit_aabb(ray, lo, hi); !aabb_hit {
			return {}, {}, 0, false
		}
	}

	// 2. Load mesh indices
	mesh_guid := adm.mesh
	if engine.asset_guid_is_empty(mesh_guid) do return {}, {}, 0, false
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	if !mok || mesh == nil || len(mesh.bind_indices) == 0 do return {}, {}, 0, false

	indices := mesh.bind_indices
	best_dist: f32 = 1e20
	best_pos: [3]f32
	best_norm: [3]f32
	has_hit := false

	// Test triangles
	for i := 0; i + 2 < len(indices); i += 3 {
		i0 := int(indices[i])
		i1 := int(indices[i + 1])
		i2 := int(indices[i + 2])
		if i0 >= len(adm.posed) || i1 >= len(adm.posed) || i2 >= len(adm.posed) do continue

		p0 := adm.posed[i0].position
		p1 := adm.posed[i1].position
		p2 := adm.posed[i2].position

		if t, u_bary, v_bary, ok := _ray_hit_triangle_bary(ray, p0, p1, p2); ok {
			if t < best_dist && t > 0.0001 {
				best_dist = t
				best_pos = ray.origin + ray.direction * t

				// 1. Primary: smooth barycentric-interpolated vertex normal from posed mesh
				w_bary := 1.0 - u_bary - v_bary
				n0 := adm.posed[i0].normal
				n1 := adm.posed[i1].normal
				n2 := adm.posed[i2].normal
				smooth_n := w_bary * n0 + u_bary * n1 + v_bary * n2
				s_len2 := smooth_n.x * smooth_n.x + smooth_n.y * smooth_n.y + smooth_n.z * smooth_n.z

				if s_len2 > 1e-4 {
					best_norm = linalg.normalize(smooth_n)
				} else {
					// 2. Secondary: geometric triangle face normal
					tri_norm := linalg.cross(p1 - p0, p2 - p0)
					t_len2 := tri_norm.x * tri_norm.x + tri_norm.y * tri_norm.y + tri_norm.z * tri_norm.z
					if t_len2 > 1e-6 {
						best_norm = linalg.normalize(tri_norm)
					} else {
						// 3. Fallback: face camera along view ray (NEVER floor-aligned {0, 1, 0})
						best_norm = -ray.direction
					}
				}

				if linalg.dot(best_norm, ray.direction) > 0 {
					best_norm = -best_norm
				}
				has_hit = true
			}
		}
	}

	if has_hit {
		return best_pos, best_norm, best_dist, true
	}
	return {}, {}, 0, false
}

@(private = "file")
_weight_painter_apply_stroke :: proc(adm: ^crig.ArmatureDeformedMesh, joint_idx: int) {
	if adm == nil || joint_idx < 0 || !weight_painter.has_hit do return

	mesh_guid := adm.mesh
	if engine.asset_guid_is_empty(mesh_guid) do return
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	if !mok || mesh == nil do return

	// If this bone is a custom bone and currently has NO weights assigned on the mesh,
	// automatically establish its current position as its rest/bind pose before applying the first stroke!
	bone_h := adm.joints[joint_idx] if joint_idx < len(adm.joints) else engine.Transform_Handle{}
	if bone_h != {} {
		count, _, _ := crig.armature_get_bone_weight_stats(adm, bone_h)
		if count == 0 {
			crig.armature_set_bone_rest_pose(adm, bone_h)
		}
	}

	// Lazy initialize custom_skin copy if empty
	if len(adm.custom_skin) != len(mesh.bind_vertices) {
		if adm.custom_skin == nil do adm.custom_skin = make([dynamic]engine.Mesh_Skin_Vertex)
		resize(&adm.custom_skin, len(mesh.bind_vertices))
		copy(adm.custom_skin[:], mesh.skin)
	}

	R := max(0.01, weight_painter.radius)
	brush_pos := weight_painter.hit_pos
	strength := clamp(weight_painter.strength, 0.01, 1.0)
	target_w := clamp(weight_painter.weight, 0.0, 1.0)
	mode := weight_painter.mode

	// For Smooth mode: precalculate average weight of this joint across vertices in brush radius
	avg_weight: f32 = 0.0
	smooth_count := 0
	if mode == .Smooth {
		sum_w: f32 = 0.0
		for i in 0 ..< len(adm.posed) {
			v_pos := adm.posed[i].position
			if linalg.distance(v_pos, brush_pos) <= R {
				sv := &adm.custom_skin[i]
				for k in 0 ..< 4 {
					if int(sv.joints[k]) == joint_idx {
						sum_w += sv.weights[k]
						break
					}
				}
				smooth_count += 1
			}
		}
		if smooth_count > 0 {
			avg_weight = sum_w / f32(smooth_count)
		}
	}

	// Determine parent bone joint index to give weight back when erasing
	w := engine.ctx_world()
	parent_j_idx := -1
	if w != nil && joint_idx < len(adm.joints) {
		jh := adm.joints[joint_idx]
		if jh != {} && engine.pool_valid(&w.transforms, engine.Handle(jh)) {
			bt := engine.pool_get(&w.transforms, engine.Handle(jh))
			if bt != nil && bt.parent.handle != {} {
				parent_h := engine.Transform_Handle(bt.parent.handle)
				parent_j_idx = crig.armature_get_bone_joint_index(adm, parent_h)
			}
		}
	}

	flow := clamp(weight_painter.flow_rate, 0.01, 1.0)

	changed := false
	for i in 0 ..< len(adm.posed) {
		v_pos := adm.posed[i].position
		dist := linalg.distance(v_pos, brush_pos)
		if dist > R do continue

		// Smooth cubic polynomial falloff: (1 - (d/R)^2)^2
		t := dist / R
		falloff := (1.0 - t * t) * (1.0 - t * t)
		rate := clamp(strength * falloff * flow, 0.002, 1.0)

		sv := &adm.custom_skin[i]

		// Find joint slot
		slot := -1
		for k in 0 ..< 4 {
			if int(sv.joints[k]) == joint_idx {
				slot = k
				break
			}
		}

		if slot < 0 {
			// If target weight is 0 or subtracting, don't allocate a slot for 0 weight!
			if (mode == .Paint && target_w <= 0.001) || mode == .Subtract {
				continue
			}
			// Find empty or minimum weight slot
			min_k := 0
			min_val: f32 = 999.0
			for k in 0 ..< 4 {
				if sv.weights[k] < 0.001 {
					min_k = k
					break
				}
				if sv.weights[k] < min_val {
					min_val = sv.weights[k]
					min_k = k
				}
			}
			slot = min_k
			sv.joints[slot] = u16(joint_idx)
			sv.weights[slot] = 0.0
		}

		cur_w := sv.weights[slot]
		new_w := cur_w

		switch mode {
		case .Paint:
			if target_w <= 0.001 {
				// Linear clean erase towards 0 so it actually reaches 0 instead of asymptotic decay
				new_w = max(0.0, cur_w - max(0.015, cur_w * rate * 1.5))
				if new_w < 0.008 do new_w = 0.0
			} else {
				new_w = math.lerp(cur_w, target_w, rate)
				if abs(new_w - target_w) < 0.005 do new_w = target_w
			}
		case .Add:
			new_w = clamp(cur_w + target_w * rate, 0.0, 1.0)
		case .Subtract:
			new_w = max(0.0, cur_w - max(0.015, (target_w > 0.001 ? target_w : 1.0) * rate))
			if new_w < 0.008 do new_w = 0.0
		case .Smooth:
			new_w = math.lerp(cur_w, avg_weight, rate)
		}

		diff := new_w - cur_w
		if abs(diff) < 0.0001 do continue

		sv.weights[slot] = new_w

		// Distribute remainder across other slots
		other_sum: f32 = 0.0
		for k in 0 ..< 4 {
			if k != slot do other_sum += sv.weights[k]
		}

		if diff > 0 {
			if other_sum > 0.0001 {
				for k in 0 ..< 4 {
					if k != slot {
						ratio := sv.weights[k] / other_sum
						sv.weights[k] = max(0.0, sv.weights[k] - diff * ratio)
					}
				}
			}
		} else {
			// Returning weight (erasing / subtracting)
			if other_sum > 0.0001 {
				for k in 0 ..< 4 {
					if k != slot {
						ratio := sv.weights[k] / other_sum
						sv.weights[k] += (-diff) * ratio
					}
				}
			} else if parent_j_idx >= 0 {
				// Give entire erased weight to parent bone
				p_slot := (slot + 1) % 4
				for k in 0 ..< 4 {
					if int(sv.joints[k]) == parent_j_idx {
						p_slot = k
						break
					}
				}
				sv.joints[p_slot] = u16(parent_j_idx)
				sv.weights[p_slot] += (-diff)
			} else {
				next_slot := (slot + 1) % 4
				sv.weights[next_slot] += (-diff)
			}
		}

		// Enforce partition of unity: sum(weights) == 1.0
		total: f32 = 0.0
		for k in 0 ..< 4 do total += sv.weights[k]
		if total > 0.001 {
			for k in 0 ..< 4 do sv.weights[k] /= total
		} else {
			// If completely zeroed out, assign 1.0 to parent bone or slot 0
			if parent_j_idx >= 0 {
				sv.joints[0] = u16(parent_j_idx)
			}
			sv.weights[0] = 1.0
		}

		// If this bone's weight dropped to 0, clean up joint slot
		if new_w <= 0.001 {
			sv.weights[slot] = 0.0
		}

		changed = true
	}

	if changed {
		adm.posed_frame = 0
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
}

weight_painter_frame :: proc(adm: ^crig.ArmatureDeformedMesh, joint_idx: int) {
	if adm == nil do return
	if scene_viewport_mode != .Control_Rig || character_edit_mode != .Bone_Mode {
		if weight_painter.is_painting {
			undo.edit_session_end(&weight_painter.undo_sess)
			weight_painter.is_painting = false
		}
		weight_painter.has_hit = false
		crig.weight_painting_active = false
		return
	}

	if !weight_painter.enabled {
		if weight_painter.is_painting {
			undo.edit_session_end(&weight_painter.undo_sess)
			weight_painter.is_painting = false
		}
		weight_painter.has_hit = false
		crig.weight_painting_active = false
		return
	}

	crig.weight_painting_active = true

	hf := handles.frame()
	if !hf.valid {
		if weight_painter.is_painting {
			undo.edit_session_end(&weight_painter.undo_sess)
			weight_painter.is_painting = false
		}
		weight_painter.has_hit = false
		return
	}

	if !hf.input.hovered && !weight_painter.is_painting {
		weight_painter.has_hit = false
		return
	}

	// 1. Raycast against mesh surface
	hit_p, hit_n, hit_d, hit := _weight_painter_raycast(hf.ray, adm)
	weight_painter.has_hit = hit
	if hit {
		weight_painter.hit_pos = hit_p
		weight_painter.hit_normal = hit_n
		weight_painter.hit_dist = hit_d
	}

	// 2. Handle Hotkeys & Shortcuts
	io := im.GetIO()
	if !io.WantTextInput && hf.input.hovered {
		// [ and ] : Brush Radius (or Shift+[ / Shift+] for Strength, Ctrl+[ / Ctrl+] for Weight)
		if im.IsKeyPressed(im.Key.LeftBracket) {
			if io.KeyShift {
				weight_painter.strength = max(0.05, weight_painter.strength - 0.05)
			} else if io.KeyCtrl {
				weight_painter.weight = max(0.0, weight_painter.weight - 0.10)
			} else {
				weight_painter.radius = max(0.002, weight_painter.radius - 0.005)
			}
		}
		if im.IsKeyPressed(im.Key.RightBracket) {
			if io.KeyShift {
				weight_painter.strength = min(1.00, weight_painter.strength + 0.05)
			} else if io.KeyCtrl {
				weight_painter.weight = min(1.0, weight_painter.weight + 0.10)
			} else {
				weight_painter.radius = min(0.250, weight_painter.radius + 0.005)
			}
		}

		// Quick numeric weight presets
		if im.IsKeyPressed(im.Key._0) do weight_painter.weight = 0.0  // Erase
		if im.IsKeyPressed(im.Key._1) do weight_painter.weight = 0.25
		if im.IsKeyPressed(im.Key._2) do weight_painter.weight = 0.50
		if im.IsKeyPressed(im.Key._3) do weight_painter.weight = 0.75
		if im.IsKeyPressed(im.Key._4) do weight_painter.weight = 1.00
		if im.IsKeyPressed(im.Key.X) {
			// Toggle between 1.0 (paint) and 0.0 (erase)
			weight_painter.weight = 0.0 if weight_painter.weight > 0.05 else 1.0
		}

		// Mouse wheel radius resize when holding B or Shift
		if (im.IsKeyDown(im.Key.B) || (io.KeyShift && !io.KeyCtrl)) && io.MouseWheel != 0 {
			weight_painter.radius = clamp(weight_painter.radius + io.MouseWheel * 0.005, 0.002, 0.250)
		}
	}

	// 3. Handle Stroke (LMB drag)
	alt_down := io.KeyAlt
	lmb_down := im.IsMouseDown(.Left) && !alt_down && hf.input.hovered

	if lmb_down && hit && joint_idx >= 0 {
		if !weight_painter.is_painting {
			// Begin stroke
			weight_painter.undo_sess = undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Paint Mesh Weights")
			weight_painter.is_painting = true
		}
		_weight_painter_apply_stroke(adm, joint_idx)
	} else if weight_painter.is_painting {
		// End stroke
		undo.edit_session_end(&weight_painter.undo_sess)
		weight_painter.is_painting = false
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
}

weight_painter_draw_gizmo :: proc() {
	if !weight_painter.enabled || !weight_painter.has_hit do return
	if scene_viewport_mode != .Control_Rig || character_edit_mode != .Bone_Mode do return

	pos := weight_painter.hit_pos
	norm := weight_painter.hit_normal
	rad := weight_painter.radius

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// A. Translucent Inner Surface Fill
	fill_col := [4]f32{1.0, 0.85, 0.20, 0.14} if weight_painter.is_painting else [4]f32{0.20, 0.85, 1.00, 0.08}
	gizmos.with_color(fill_col)
	gizmos.solid_circle(pos, norm, rad)

	// B. Crisp Brush Circumference Ring
	ring_col := [4]f32{1.0, 0.90, 0.20, 0.95} if weight_painter.is_painting else [4]f32{0.25, 0.85, 1.00, 0.85}
	gizmos.with_color(ring_col)
	gizmos.wire_circle(pos, norm, rad, segments = 36)

	// C. Surface Contact Dot and Normal Pointer Tick
	gizmos.with_color(ring_col)
	gizmos.wire_sphere(pos, 0.005)
	gizmos.line(pos, pos + norm * 0.025)
}
