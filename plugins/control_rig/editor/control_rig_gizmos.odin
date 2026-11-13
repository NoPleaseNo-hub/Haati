package control_rig_editor

// Control Rig 3D Visualizer & Interactive Contour Gizmos.
// Renders clean Antigravity studio-styled 3D geometric controls with dual-pass depth
// perception (subtle occluded x-ray silhouette + crisp foreground rim) and true 3D
// contour hit-testing (rings, segments, and oriented boxes) so clicking anywhere along
// a control's visible silhouette selects or drags it reliably:
// 1. Pelvis, Spine & Chest: Torso rings with spoke indicators
// 2. Head, Eye Level Socket & LookAt Target: Vision & camera mount controls
// 3. Left & Right Feet + Toes: Oriented foot pedals with sole direction chevrons + toe roll rockers
// 4. Left & Right Hands: Oriented wrist boxes with IK rotation blending
// 5. Knee & Elbow Poles: Clean multi-ring target spheres with depth-cued pole rays

import "core:math"
import "core:math/linalg"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import "haati:engine/gizmos"
import "haati:editor/handles"
import undo "haati:editor/undo"
import crig "haati:packages/control_rig"

_default_control_color :: proc(ctrl_id: Active_Rig_Control) -> [4]f32 {
	switch ctrl_id {
	case .Pelvis:           return {0.96, 0.78, 0.28, 0.96} // Warm Studio Gold
	case .Spine:            return {0.96, 0.80, 0.32, 0.96} // Studio Gold
	case .Chest:            return {0.98, 0.82, 0.34, 0.96} // Bright Gold
	case .Head:             return {0.98, 0.88, 0.38, 0.96} // Sunlit Gold
	case .Eye_Level_Socket: return {0.34, 0.82, 0.98, 0.96} // Sky Cyan (Eye level & camera mount)
	case .Look_At:          return {0.98, 0.88, 0.38, 0.96} // Sunlit Gold
	case .Left_Foot:        return {0.96, 0.36, 0.38, 0.96} // Studio Coral-Rose
	case .Right_Foot:       return {0.26, 0.88, 0.54, 0.96} // Studio Emerald-Mint
	case .Left_Toe:         return {0.98, 0.58, 0.28, 0.96} // Tangerine
	case .Right_Toe:        return {0.44, 0.94, 0.62, 0.96} // Spring Mint
	case .Left_Knee_Pole:   return {0.38, 0.80, 0.98, 0.92} // Frost Cyan
	case .Right_Knee_Pole:  return {0.38, 0.80, 0.98, 0.92} // Frost Cyan
	case .Left_Hand:        return {0.96, 0.36, 0.38, 0.96} // Studio Coral-Rose
	case .Right_Hand:       return {0.26, 0.88, 0.54, 0.96} // Studio Emerald-Mint
	case .Left_Elbow_Pole:  return {0.98, 0.76, 0.34, 0.92} // Soft Amber
	case .Right_Elbow_Pole: return {0.98, 0.76, 0.34, 0.92} // Soft Amber
	}
	return {0.96, 0.78, 0.28, 0.96}
}

_default_control_scale :: proc(ctrl_id: Active_Rig_Control) -> f32 {
	#partial switch ctrl_id {
	case .Pelvis:                 return 0.25
	case .Spine:                  return 0.22
	case .Chest:                  return 0.24
	case .Head:                   return 0.14
	case .Eye_Level_Socket:       return 0.08
	case .Left_Foot, .Right_Foot: return 0.20
	case .Left_Hand, .Right_Hand: return 0.12
	case:                         return 0.20
	}
}

@(private="file")
_oriented_box_corners :: proc(pos, rgt, up, fwd, half: [3]f32) -> [8][3]f32 {
	rx := rgt * half.x
	uy := up * half.y
	fz := fwd * half.z
	return {
		pos - rx - uy - fz, // 0: blb
		pos + rx - uy - fz, // 1: brb
		pos + rx - uy + fz, // 2: brf
		pos - rx - uy + fz, // 3: blf
		pos - rx + uy - fz, // 4: tlb
		pos + rx + uy - fz, // 5: trb
		pos + rx + uy + fz, // 6: trf
		pos - rx + uy + fz, // 7: tlf
	}
}

@(private="file")
_BOX_EDGES :: [12][2]int{
	{0, 1}, {1, 2}, {2, 3}, {3, 0}, // bottom quad
	{4, 5}, {5, 6}, {6, 7}, {7, 4}, // top quad
	{0, 4}, {1, 5}, {2, 6}, {3, 7}, // vertical pillars
}

@(private="file")
_draw_oriented_wire_box :: proc(pos, rgt, up, fwd, half: [3]f32) {
	c := _oriented_box_corners(pos, rgt, up, fwd, half)
	for edge in _BOX_EDGES {
		gizmos.line(c[edge[0]], c[edge[1]])
	}
}

@(private="file")
_draw_oriented_solid_box :: proc(pos, rgt, up, fwd, half: [3]f32) {
	m := matrix[4, 4]f32{
		rgt.x, up.x, fwd.x, pos.x,
		rgt.y, up.y, fwd.y, pos.y,
		rgt.z, up.z, fwd.z, pos.z,
		0,     0,    0,     1,
	}
	gizmos.with_matrix(m)
	gizmos.solid_box({0, 0, 0}, half * 2.0)
}

// Draws a double-sided 3D ribbon strip (`solid_quad` flat-torus band) so rings stay bold and
// clearly readable at every zoom level instead of dissolving into 1px GPU hairlines.
@(private="file")
_draw_ribbon_ring :: proc(pos, u, v: [3]f32, r_inner, r_outer: f32, segments := 32) {
	n := max(segments, 8)
	ri := max(r_inner, 0.002)
	ro := max(r_outer, ri + 0.002)
	for i in 0 ..< n {
		t0 := math.TAU * f32(i) / f32(n)
		t1 := math.TAU * f32(i + 1) / f32(n)
		d0 := u * math.cos(t0) + v * math.sin(t0)
		d1 := u * math.cos(t1) + v * math.sin(t1)
		a0 := pos + d0 * ri
		b0 := pos + d0 * ro
		b1 := pos + d1 * ro
		a1 := pos + d1 * ri
		gizmos.solid_quad({a0, b0, b1, a1})
	}
}

@(private="file")
_draw_ribbon_quad_frame :: proc(pos, u, v: [3]f32, half_u, half_v, band: f32) {
	iu := max(half_u - band, 0.002)
	iv := max(half_v - band, 0.002)
	ou := half_u + band * 0.35
	ov := half_v + band * 0.35
	in_q := [4][3]f32{
		pos - u * iu - v * iv,
		pos + u * iu - v * iv,
		pos + u * iu + v * iv,
		pos - u * iu + v * iv,
	}
	out_q := [4][3]f32{
		pos - u * ou - v * ov,
		pos + u * ou - v * ov,
		pos + u * ou + v * ov,
		pos - u * ou + v * ov,
	}
	for i in 0 ..< 4 {
		j := (i + 1) % 4
		gizmos.solid_quad({in_q[i], out_q[i], out_q[j], in_q[j]})
	}
}

@(private="file")
_draw_shape_wire_rims :: proc(
	pos: [3]f32,
	rgt, up, fwd: [3]f32,
	shape: crig.Control_Shape_Type,
	s, band: f32,
	draw_foot_chevron: bool,
) {
	switch shape {
	case .Circle:
		gizmos.wire_circle(pos, up, max(s - band * 0.5, 0.005), segments = 32)
		gizmos.wire_circle(pos, up, s + band * 0.5, segments = 32)
		gizmos.line(pos + fwd * (s * 0.84), pos + fwd * (s * 1.18))
	case .Circle_Normal:
		gizmos.wire_circle(pos, fwd, max(s - band * 0.5, 0.005), segments = 32)
		gizmos.wire_circle(pos, fwd, s + band * 0.5, segments = 32)
	case .Ring:
		gizmos.wire_circle(pos, up, s + band * 0.45, segments = 32)
		gizmos.wire_circle(pos, up, max(s * 0.74 - band * 0.35, 0.005), segments = 32)
		gizmos.line(pos + rgt * (s * 0.74), pos + rgt * (s + band * 0.45))
		gizmos.line(pos - rgt * (s * 0.74), pos - rgt * (s + band * 0.45))
		gizmos.line(pos + fwd * (s * 0.74), pos + fwd * (s * 1.20))
		gizmos.line(pos - fwd * (s * 0.74), pos - fwd * (s + band * 0.45))
	case .Square:
		c_quad := [4][3]f32{
			pos + (-rgt - fwd) * s,
			pos + ( rgt - fwd) * s,
			pos + ( rgt + fwd) * s,
			pos + (-rgt + fwd) * s,
		}
		gizmos.wire_quad(c_quad)
	case .Square_Normal:
		c_quad := [4][3]f32{
			pos + (-rgt - up) * s,
			pos + ( rgt - up) * s,
			pos + ( rgt + up) * s,
			pos + (-rgt + up) * s,
		}
		gizmos.wire_quad(c_quad)
	case .Diamond:
		h := s * 1.25
		c_quad := [4][3]f32{
			pos - fwd * h,
			pos + rgt * h,
			pos + fwd * h,
			pos - rgt * h,
		}
		gizmos.wire_quad(c_quad)
	case .Cross:
		gizmos.line(pos - rgt * s, pos + rgt * s)
		gizmos.line(pos - fwd * s, pos + fwd * s)
		gizmos.line(pos - up * (s * 0.65), pos + up * (s * 0.65))
	case .Arrow:
		gizmos.line_arrow(pos - fwd * (s * 0.6), pos + fwd * s, head = s * 0.38)
	case .Cube:
		half := [3]f32{s * 0.80, s * 0.50, s * 1.10}
		_draw_oriented_wire_box(pos, rgt, up, fwd, half)
	case .Sphere:
		gizmos.wire_circle(pos, up, s * 1.12, segments = 24)
		gizmos.wire_circle(pos, rgt, s * 1.12, segments = 24)
		gizmos.wire_circle(pos, fwd, s * 1.12, segments = 24)
	}

	if draw_foot_chevron {
		sole_y := -up * (s * 0.48 if shape == .Cube else 0.0)
		tip := pos + sole_y + fwd * (s * 1.34)
		wing_l := pos + sole_y + fwd * (s * 0.92) - rgt * (s * 0.42)
		wing_r := pos + sole_y + fwd * (s * 0.92) + rgt * (s * 0.42)
		gizmos.wire_triangle(wing_l, wing_r, tip)
	}
}

@(private="file")
_draw_shape_solid_band :: proc(
	pos: [3]f32,
	rgt, up, fwd: [3]f32,
	shape: crig.Control_Shape_Type,
	s, band: f32,
	fill_col, band_col: [4]f32,
	draw_foot_chevron: bool,
) {
	switch shape {
	case .Circle:
		if fill_col.a > 0.01 {
			gizmos.with_color(fill_col)
			gizmos.solid_circle(pos, up, max(s - band * 0.5, 0.005), segments = 28)
		}
		gizmos.with_color(band_col)
		_draw_ribbon_ring(pos, rgt, fwd, max(s - band * 0.55, 0.004), s + band * 0.55, segments = 32)
		// Forward direction nose tab so torso/pelvis yaw is unmistakable
		tip := pos + fwd * (s + band * 2.1)
		wl  := pos + fwd * (s + band * 0.35) - rgt * (band * 1.25)
		wr  := pos + fwd * (s + band * 0.35) + rgt * (band * 1.25)
		gizmos.solid_triangle(wl, wr, tip)

	case .Circle_Normal:
		if fill_col.a > 0.01 {
			gizmos.with_color(fill_col)
			gizmos.solid_circle(pos, fwd, max(s - band * 0.5, 0.005), segments = 28)
		}
		gizmos.with_color(band_col)
		_draw_ribbon_ring(pos, rgt, up, max(s - band * 0.55, 0.004), s + band * 0.55, segments = 32)

	case .Ring:
		gizmos.with_color(band_col)
		_draw_ribbon_ring(pos, rgt, fwd, max(s * 0.76, s - band * 1.35), s + band * 0.45, segments = 32)
		tip := pos + fwd * (s * 1.24)
		wl  := pos + fwd * (s + band * 0.25) - rgt * (band * 1.35)
		wr  := pos + fwd * (s + band * 0.25) + rgt * (band * 1.35)
		gizmos.solid_triangle(wl, wr, tip)

	case .Square:
		if fill_col.a > 0.01 {
			gizmos.with_color(fill_col)
			gizmos.solid_quad({
				pos + (-rgt - fwd) * s,
				pos + ( rgt - fwd) * s,
				pos + ( rgt + fwd) * s,
				pos + (-rgt + fwd) * s,
			})
		}
		gizmos.with_color(band_col)
		_draw_ribbon_quad_frame(pos, rgt, fwd, s, s, band)

	case .Square_Normal:
		if fill_col.a > 0.01 {
			gizmos.with_color(fill_col)
			gizmos.solid_quad({
				pos + (-rgt - up) * s,
				pos + ( rgt - up) * s,
				pos + ( rgt + up) * s,
				pos + (-rgt + up) * s,
			})
		}
		gizmos.with_color(band_col)
		_draw_ribbon_quad_frame(pos, rgt, up, s, s, band)

	case .Diamond:
		h := s * 1.28
		d_u := linalg.normalize0(rgt + fwd)
		d_v := linalg.normalize0(-rgt + fwd)
		hs  := h * 0.7071
		gizmos.with_color({band_col.r, band_col.g, band_col.b, min(band_col.a, 0.65)})
		_draw_oriented_solid_box(pos, d_u, up, d_v, {hs * 0.62, hs * 0.62, hs * 0.62})
		gizmos.with_color(band_col)
		_draw_ribbon_quad_frame(pos, d_u, d_v, hs, hs, band * 0.9)

	case .Cross:
		gizmos.with_color(band_col)
		w := band * 0.75
		gizmos.solid_quad({pos - rgt * s - fwd * w, pos + rgt * s - fwd * w, pos + rgt * s + fwd * w, pos - rgt * s + fwd * w})
		gizmos.solid_quad({pos - fwd * s - rgt * w, pos + fwd * s - rgt * w, pos + fwd * s + rgt * w, pos - fwd * s + rgt * w})

	case .Arrow:
		gizmos.with_color(band_col)
		w := band * 0.70
		gizmos.solid_quad({pos - fwd * (s * 0.55) - rgt * w, pos + fwd * (s * 0.62) - rgt * w, pos + fwd * (s * 0.62) + rgt * w, pos - fwd * (s * 0.55) + rgt * w})
		gizmos.solid_triangle(pos + fwd * (s * 0.60) - rgt * (s * 0.30), pos + fwd * (s * 0.60) + rgt * (s * 0.30), pos + fwd * (s * 1.08))

	case .Cube:
		half := [3]f32{s * 0.80, s * 0.50, s * 1.10}
		if fill_col.a > 0.01 {
			gizmos.with_color(fill_col)
			_draw_oriented_solid_box(pos, rgt, up, fwd, half)
		}
		// Crisp base/sole ribbon collar so foot & wrist boxes pop from every camera angle
		gizmos.with_color(band_col)
		sole_c := pos - up * (half.y * 0.92 if draw_foot_chevron else 0.0)
		_draw_ribbon_quad_frame(sole_c, rgt, fwd, half.x, half.z, band * 0.85)

	case .Sphere:
		gizmos.with_color({band_col.r, band_col.g, band_col.b, clamp(band_col.a * 0.82, 0.45, 0.95)})
		gizmos.solid_sphere(pos, s * 0.88, segments = 14)
		gizmos.with_color(band_col)
		_draw_ribbon_ring(pos, rgt, fwd, s * 0.96, s * 1.18, segments = 24)
	}

	if draw_foot_chevron {
		gizmos.with_color(band_col)
		sole_y := -up * (s * 0.48 if shape == .Cube else 0.0)
		tip := pos + sole_y + fwd * (s * 1.36)
		wing_l := pos + sole_y + fwd * (s * 0.92) - rgt * (s * 0.42)
		wing_r := pos + sole_y + fwd * (s * 0.92) + rgt * (s * 0.42)
		gizmos.solid_triangle(wing_l, wing_r, tip)
	}
}

draw_rig_control_shape :: proc(pos: [3]f32, rot: quaternion128, shape: crig.Control_Shape_Type, col: [4]f32, scale: f32, is_selected: bool) {
	_draw_rig_control_shape_studio(pos, rot, shape, col, scale, is_selected, false, false)
}

@(private="file")
_draw_rig_control_shape_studio :: proc(
	pos: [3]f32,
	rot: quaternion128,
	shape: crig.Control_Shape_Type,
	col: [4]f32,
	scale: f32,
	is_selected: bool,
	is_hovered: bool,
	is_foot_pedal: bool,
) {
	c := col
	if c.a < 0.1 {
		c = {0.96, 0.78, 0.28, 0.96}
	}

	fwd := linalg.quaternion128_mul_vector3(rot, [3]f32{0, 0, 1})
	up  := linalg.quaternion128_mul_vector3(rot, [3]f32{0, 1, 0})
	rgt := linalg.quaternion128_mul_vector3(rot, [3]f32{1, 0, 0})
	s   := scale > 0.02 ? scale : 0.20

	active_col := c
	if is_selected {
		active_col = {1.00, 0.95, 0.36, 1.00}
	} else if is_hovered {
		active_col = {
			clamp(c.r * 1.20 + 0.12, 0.0, 1.0),
			clamp(c.g * 1.20 + 0.12, 0.0, 1.0),
			clamp(c.b * 1.20 + 0.12, 0.0, 1.0),
			1.00,
		}
	}

	px   := handles.world_per_pixels(pos, 1.0)
	band := clamp(max(s * 0.13, px * 4.5), 0.004, s * 0.34)
	if is_selected {
		band *= 1.24
	} else if is_hovered {
		band *= 1.14
	}

	// Pass 1: Clear X-ray discovery pass (through character mesh) so controls inside
	// hips, chest, wrists, or shoes are always easy to spot and click!
	xray_band_alpha := f32(0.62) if is_selected else (f32(0.50) if is_hovered else f32(0.36))
	xray_fill_alpha := f32(0.18) if is_selected else (f32(0.12) if is_hovered else f32(0.05))
	gizmos.with_depth_test(false)
	_draw_shape_solid_band(
		pos, rgt, up, fwd, shape, s, band,
		{active_col.r, active_col.g, active_col.b, xray_fill_alpha},
		{active_col.r, active_col.g, active_col.b, xray_band_alpha},
		is_foot_pedal,
	)
	gizmos.with_color({0.04, 0.06, 0.09, is_selected || is_hovered ? 0.65 : 0.42})
	_draw_shape_wire_rims(pos, rgt, up, fwd, shape, s, band, false)

	// Pass 2: Full-vibrancy foreground 3D volumetric ribbon + high-contrast dark/white rim strokes.
	fg_fill_alpha := f32(0.30) if is_selected else (f32(0.22) if is_hovered else f32(0.12))
	fg_band_alpha := f32(0.98) if (is_selected || is_hovered) else f32(0.90)
	gizmos.with_depth_test(true)
	_draw_shape_solid_band(
		pos, rgt, up, fwd, shape, s, band,
		{active_col.r, active_col.g, active_col.b, fg_fill_alpha},
		{active_col.r, active_col.g, active_col.b, fg_band_alpha},
		is_foot_pedal,
	)
	// Crisp dark outline for daylight/bright-surface contrast
	gizmos.with_color({0.02, 0.03, 0.05, 0.90})
	_draw_shape_wire_rims(pos, rgt, up, fwd, shape, s, band, is_foot_pedal)

	// Crisp luminous inner highlight when hovered or selected
	if is_selected || is_hovered {
		gizmos.with_depth_test(false)
		hi_col := [4]f32{1.0, 1.0, 0.96, 0.95} if is_selected else [4]f32{1.0, 1.0, 1.0, 0.72}
		gizmos.with_color(hi_col)
		_draw_shape_wire_rims(pos, rgt, up, fwd, shape, s, band * 0.15, is_foot_pedal)
	}

	gizmos.with_depth_test(false)
}

// Registers composite 3D hit shapes matching the exact visible contour of `shape`
// so clicking anywhere along a ring, box edge, or sphere rim picks/drags immediately.
@(private="file")
_register_shape_contour_handles :: proc(
	rig: ^crig.ControlRig,
	ctrl_id: Active_Rig_Control,
	pos: [3]f32,
	rot: quaternion128,
	shape: crig.Control_Shape_Type,
	scale: f32,
	cam_pos: [3]f32,
	prio := 2,
) -> handles.Drag {
	d: handles.Drag
	fwd := linalg.quaternion128_mul_vector3(rot, [3]f32{0, 0, 1})
	up  := linalg.quaternion128_mul_vector3(rot, [3]f32{0, 1, 0})
	rgt := linalg.quaternion128_mul_vector3(rot, [3]f32{1, 0, 0})
	s   := scale > 0.02 ? scale : 0.20

	cam_n := linalg.normalize0(cam_pos - pos)
	if cam_n == {} do cam_n = {0, 0, 1}

	base_salt := u64(ctrl_id) * 64 + 0xA000
	hover_edge := f32(12.0)

	// Center fallback handle (tight radius so interior doesn't swallow neighbors, but direct pivot clicks always land)
	handles.merge_drag(&d, handles.point(handles.id_of(rig.owner, base_salt + 0), pos, cam_n, hover_px = 9.0, prio = prio))

	switch shape {
	case .Circle:
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 1), pos, rgt, fwd, s, cam_n, hover_px = hover_edge, segments = 32, prio = prio))
	case .Circle_Normal:
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 1), pos, rgt, up, s, cam_n, hover_px = hover_edge, segments = 32, prio = prio))
	case .Ring:
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 1), pos, rgt, fwd, s, cam_n, hover_px = hover_edge, segments = 32, prio = prio))
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 2), pos, rgt, fwd, s * 0.72, cam_n, hover_px = 10.0, segments = 28, prio = prio))
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 3), pos + fwd * (s * 0.72), pos + fwd * (s * 1.12), cam_n, hover_px = 10.0, prio = prio))
	case .Square:
		q := [4][3]f32{
			pos + (-rgt - fwd) * s,
			pos + ( rgt - fwd) * s,
			pos + ( rgt + fwd) * s,
			pos + (-rgt + fwd) * s,
		}
		for i in 0 ..< 4 {
			handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + u64(1 + i)), q[i], q[(i + 1) % 4], cam_n, hover_px = hover_edge, prio = prio))
		}
	case .Square_Normal:
		q := [4][3]f32{
			pos + (-rgt - up) * s,
			pos + ( rgt - up) * s,
			pos + ( rgt + up) * s,
			pos + (-rgt + up) * s,
		}
		for i in 0 ..< 4 {
			handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + u64(1 + i)), q[i], q[(i + 1) % 4], cam_n, hover_px = hover_edge, prio = prio))
		}
	case .Diamond:
		h := s * 1.2
		q := [4][3]f32{
			pos - fwd * h,
			pos + rgt * h,
			pos + fwd * h,
			pos - rgt * h,
		}
		for i in 0 ..< 4 {
			handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + u64(1 + i)), q[i], q[(i + 1) % 4], cam_n, hover_px = hover_edge, prio = prio))
		}
	case .Cross:
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 1), pos - rgt * s, pos + rgt * s, cam_n, hover_px = hover_edge, prio = prio))
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 2), pos - fwd * s, pos + fwd * s, cam_n, hover_px = hover_edge, prio = prio))
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 3), pos - up * (s * 0.55), pos + up * (s * 0.55), cam_n, hover_px = hover_edge, prio = prio))
	case .Arrow:
		tip := pos + fwd * s
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 1), pos - fwd * (s * 0.6), tip, cam_n, hover_px = hover_edge, prio = prio))
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 2), tip - (fwd + rgt * 0.6) * (s * 0.35), tip, cam_n, hover_px = hover_edge, prio = prio))
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 3), tip - (fwd - rgt * 0.6) * (s * 0.35), tip, cam_n, hover_px = hover_edge, prio = prio))
	case .Cube:
		half := [3]f32{s * 0.78, s * 0.48, s * 1.08}
		c := _oriented_box_corners(pos, rgt, up, fwd, half)
		for edge, ei in _BOX_EDGES {
			handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + u64(1 + ei)), c[edge[0]], c[edge[1]], cam_n, hover_px = hover_edge, prio = prio))
		}
	case .Sphere:
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 1), pos, rgt, fwd, s, cam_n, hover_px = hover_edge, segments = 24, prio = prio))
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 2), pos, rgt, up, s, cam_n, hover_px = hover_edge, segments = 24, prio = prio))
		handles.merge_drag(&d, handles.ring(handles.id_of(rig.owner, base_salt + 3), pos, up, fwd, s, cam_n, hover_px = hover_edge, segments = 24, prio = prio))
	}

	return d
}

@(private="file")
_begin_free_contour_drag :: proc(rig: ^crig.ControlRig, actor_m: matrix[4, 4]f32, char_rot: quaternion128, base_delta: [3]f32, label: string) {
	_free_drag.dragging   = true
	_free_drag.base_delta = base_delta
	for c in Active_Rig_Control {
		if c in selected_rig_controls {
			_free_drag.start_wpos[c] = _get_control_world_pos(rig, c, actor_m, char_rot)
		}
	}
	_free_drag.start_l_toe_pitch = rig.left_toe_pitch
	_free_drag.start_r_toe_pitch = rig.right_toe_pitch
	if !_free_drag.undo_active {
		owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
		_free_drag.undo_sess = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, label)
		_free_drag.undo_active = true
	}
}

@(private="file")
_end_free_contour_drag :: proc() {
	_free_drag.dragging   = false
	_free_drag.armed_ctrl = nil
	_free_drag.base_delta = {}
	if _free_drag.undo_active {
		undo.edit_session_end(&_free_drag.undo_sess)
		_free_drag.undo_active = false
	}
}

@(private="file")
_apply_free_contour_drag :: proc(rig: ^crig.ControlRig, raw_delta_w: [3]f32, inv_actor_m: matrix[4, 4]f32, char_rot: quaternion128) {
	delta_w := raw_delta_w - _free_drag.base_delta
	for c in Active_Rig_Control {
		if c in selected_rig_controls {
			if c == .Left_Toe {
				foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.left_foot.rotation))
				foot_up := linalg.quaternion128_mul_vector3(foot_rot, [3]f32{0, 1, 0})
				rig.left_toe_pitch = clamp(_free_drag.start_l_toe_pitch - linalg.dot(delta_w, foot_up) * 6.5, -1.2, 1.2)
			} else if c == .Right_Toe {
				foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.right_foot.rotation))
				foot_up := linalg.quaternion128_mul_vector3(foot_rot, [3]f32{0, 1, 0})
				rig.right_toe_pitch = clamp(_free_drag.start_r_toe_pitch - linalg.dot(delta_w, foot_up) * 6.5, -1.2, 1.2)
			} else {
				_set_control_world_pos(rig, c, _free_drag.start_wpos[c] + delta_w, inv_actor_m, char_rot)
			}
		}
	}
	rig.active = true
	if _, s := engine.transform_get_comp(rig.owner, crig.HumanoidIkSolver); s != nil do s.active = true
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(private="file")
_interact_rig_contour :: proc(
	rig: ^crig.ControlRig,
	owner_h: engine.Transform_Handle,
	ctrl_id: Active_Rig_Control,
	pos_w: [3]f32,
	d: handles.Drag,
	actor_m: matrix[4, 4]f32,
	inv_actor_m: matrix[4, 4]f32,
	char_rot: quaternion128,
	ctrl_held: bool,
	tool: handles.Tool,
	undo_label: string,
) -> (is_sel: bool, did_move: bool) {
	is_sel = is_rig_control_selected(owner_h, ctrl_id)
	if d.started && !_drag_state.dragging {
		if is_sel && !ctrl_held {
			active_rig_control = ctrl_id
		} else {
			select_rig_control(owner_h, ctrl_id, ctrl_held)
		}
		is_sel = is_rig_control_selected(owner_h, ctrl_id)
		if is_sel && !ctrl_held {
			if tool == .Handles {
				_begin_free_contour_drag(rig, actor_m, char_rot, {}, undo_label)
			} else {
				_free_drag.armed_ctrl = ctrl_id
			}
		}
	}
	// Allow direct grab-and-drag on any 3D ribbon control after a 5px deadzone even in W/E/R mode,
	// while keeping plain click-and-release (< 5px) a pure, jitter-free selection!
	if !_free_drag.dragging && _free_drag.armed_ctrl == ctrl_id && is_sel && d.dragging && !_drag_state.dragging {
		deadzone_w := handles.world_per_pixels(pos_w, 5.0)
		if linalg.length(d.delta) > deadzone_w {
			_begin_free_contour_drag(rig, actor_m, char_rot, d.delta, undo_label)
		}
	}
	if _free_drag.dragging && is_sel && (d.dragging || d.released) {
		_apply_free_contour_drag(rig, d.delta, inv_actor_m, char_rot)
		did_move = true
	}
	if d.released {
		if _free_drag.armed_ctrl == ctrl_id do _free_drag.armed_ctrl = nil
		if _free_drag.dragging do _end_free_contour_drag()
	}
	return is_sel, did_move
}

@(private="file")
_handle_rig_control :: proc(
	rig: ^crig.ControlRig,
	ctrl_id: Active_Rig_Control,
	ctrl: ^crig.Rig_Control,
	actor_m: matrix[4, 4]f32,
	inv_actor_m: matrix[4, 4]f32,
	char_rot: quaternion128,
	cam_pos: [3]f32,
	label_text: string,
	ctrl_held: bool,
	tool: handles.Tool,
) {
	// Sanitize zero/uninitialized fields from older scene saves
	rot_len2 := ctrl.rotation.x * ctrl.rotation.x + ctrl.rotation.y * ctrl.rotation.y + ctrl.rotation.z * ctrl.rotation.z + ctrl.rotation.w * ctrl.rotation.w
	if rot_len2 < 0.0001 || math.is_nan(ctrl.rotation.x) || math.is_nan(ctrl.rotation.y) || math.is_nan(ctrl.rotation.z) || math.is_nan(ctrl.rotation.w) {
		ctrl.rotation = engine.QUAT_IDENTITY
	}
	if ctrl.color.a < 0.1 {
		ctrl.color = _default_control_color(ctrl_id)
	}
	if ctrl.scale < 0.02 {
		ctrl.scale = _default_control_scale(ctrl_id)
	}

	pos_w: [3]f32
	rot_w: quaternion128
	if ctrl_id == .Eye_Level_Socket {
		pos_w = _get_control_world_pos(rig, .Eye_Level_Socket, actor_m, char_rot)
		rot_w = _get_control_world_rot(rig, .Eye_Level_Socket, char_rot)
	} else {
		pos_w = (actor_m * [4]f32{ctrl.position.x, ctrl.position.y, ctrl.position.z, 1}).xyz
		rot_w = linalg.quaternion_normalize(char_rot * engine.quat_to_native(ctrl.rotation))
	}

	owner_h := engine.Transform_Handle(rig.owner)
	// Always register contour handles every frame at prio = 1 (below active TRS gizmo prio = 10)
	// so clicking a control never drops `handles._active` on the frame after selection!
	d := _register_shape_contour_handles(rig, ctrl_id, pos_w, rot_w, ctrl.shape, ctrl.scale, cam_pos, prio = 1)
	is_sel, moved := _interact_rig_contour(rig, owner_h, ctrl_id, pos_w, d, actor_m, inv_actor_m, char_rot, ctrl_held, tool, "Drag Rig Control")
	if moved {
		pos_w = _get_control_world_pos(rig, ctrl_id, actor_m, char_rot)
	}

	is_foot := (ctrl_id == .Left_Foot || ctrl_id == .Right_Foot)
	_draw_rig_control_shape_studio(pos_w, rot_w, ctrl.shape, ctrl.color, ctrl.scale, is_sel, d.hot, is_foot)

	if show_all_rig_labels || d.hot || is_sel {
		gizmos.label(pos_w, label_text, align = {-0.5, 1.0}, offset_px = {0, -10}, scale = 0.82)
	}
}

@(private="file")
_handle_pure_pos_control :: proc(
	rig: ^crig.ControlRig,
	ctrl_id: Active_Rig_Control,
	local_pos: ^[3]f32,
	actor_m: matrix[4, 4]f32,
	inv_actor_m: matrix[4, 4]f32,
	char_rot: quaternion128,
	cam_pos: [3]f32,
	color: [4]f32,
	label_text: string,
	ctrl_held: bool,
	tool: handles.Tool,
) {
	pos_w := (actor_m * [4]f32{local_pos.x, local_pos.y, local_pos.z, 1}).xyz
	owner_h := engine.Transform_Handle(rig.owner)
	radius := f32(0.062) if ctrl_id == .Look_At else f32(0.054)

	d := _register_shape_contour_handles(rig, ctrl_id, pos_w, quaternion128(1), .Sphere, radius, cam_pos, prio = 2)
	cam_n := linalg.normalize0(cam_pos - pos_w)
	if cam_n == {} do cam_n = {0, 0, 1}
	handles.merge_drag(&d, handles.point(handles.id_of(rig.owner, u64(ctrl_id) * 64 + 0xA03F), pos_w, cam_n, hover_px = 16.0, prio = 2))

	is_sel, moved := _interact_rig_contour(rig, owner_h, ctrl_id, pos_w, d, actor_m, inv_actor_m, char_rot, ctrl_held, tool, "Drag Pole / Target")
	if moved {
		pos_w = (actor_m * [4]f32{local_pos.x, local_pos.y, local_pos.z, 1}).xyz
	}

	_draw_rig_control_shape_studio(pos_w, quaternion128(1), .Diamond if ctrl_id == .Look_At else .Sphere, color, radius, is_sel, d.hot, false)

	if show_all_rig_labels || d.hot || is_sel {
		gizmos.label(pos_w, label_text, align = {-0.5, 1.0}, offset_px = {0, -9}, scale = 0.80)
	}
}

// Interactive 3D Toe / Ball-of-Foot Rocker Handle (Volumetric 3D Studio Pedal Tab)
@(private="file")
_handle_toe_control :: proc(
	rig: ^crig.ControlRig,
	ctrl_id: Active_Rig_Control,
	actor_m: matrix[4, 4]f32,
	inv_actor_m: matrix[4, 4]f32,
	char_rot: quaternion128,
	cam_pos: [3]f32,
	label_text: string,
	ctrl_held: bool,
	tool: handles.Tool,
) {
	owner_h := engine.Transform_Handle(rig.owner)
	pos_w := _get_control_world_pos(rig, ctrl_id, actor_m, char_rot)
	rot_w := _get_control_world_rot(rig, ctrl_id, char_rot)
	foot_scale := rig.left_foot.scale if ctrl_id == .Left_Toe else rig.right_foot.scale
	s := clamp(foot_scale * 0.48, 0.060, 0.15)

	rgt := linalg.quaternion128_mul_vector3(rot_w, [3]f32{1, 0, 0})
	up  := linalg.quaternion128_mul_vector3(rot_w, [3]f32{0, 1, 0})
	fwd := linalg.quaternion128_mul_vector3(rot_w, [3]f32{0, 0, 1})

	arc_pts:    [5][3]f32
	arc_in_pts: [5][3]f32
	for i in 0 ..< 5 {
		ang := (f32(i) / 4.0 - 0.5) * math.PI * 0.85
		arc_pts[i]    = pos_w + rgt * (math.sin(ang) * s * 1.18) + fwd * (math.cos(ang) * s * 0.90)
		arc_in_pts[i] = pos_w + rgt * (math.sin(ang) * s * 0.82) + fwd * (math.cos(ang) * s * 0.58)
	}

	cam_n := linalg.normalize0(cam_pos - pos_w)
	if cam_n == {} do cam_n = {0, 0, 1}
	base_salt := u64(ctrl_id) * 64 + 0xA000
	d: handles.Drag
	handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + 0), pos_w - rgt * (s * 1.12), pos_w + rgt * (s * 1.12), cam_n, hover_px = 13.0, prio = 3))
	for i in 0 ..< 4 {
		handles.merge_drag(&d, handles.segment(handles.id_of(rig.owner, base_salt + u64(1 + i)), arc_pts[i], arc_pts[i + 1], cam_n, hover_px = 13.0, prio = 3))
	}

	is_sel, moved := _interact_rig_contour(rig, owner_h, ctrl_id, pos_w, d, actor_m, inv_actor_m, char_rot, ctrl_held, tool, "Roll Toe Hinge")
	if moved {
		rot_w = _get_control_world_rot(rig, ctrl_id, char_rot)
		rgt = linalg.quaternion128_mul_vector3(rot_w, [3]f32{1, 0, 0})
		up  = linalg.quaternion128_mul_vector3(rot_w, [3]f32{0, 1, 0})
		fwd = linalg.quaternion128_mul_vector3(rot_w, [3]f32{0, 0, 1})
		for i in 0 ..< 5 {
			ang := (f32(i) / 4.0 - 0.5) * math.PI * 0.85
			arc_pts[i]    = pos_w + rgt * (math.sin(ang) * s * 1.18) + fwd * (math.cos(ang) * s * 0.90)
			arc_in_pts[i] = pos_w + rgt * (math.sin(ang) * s * 0.82) + fwd * (math.cos(ang) * s * 0.58)
		}
	}

	base_col := _default_control_color(ctrl_id)
	draw_col := [4]f32{1.00, 0.95, 0.36, 1.00} if is_sel else (handles.COLOR_HOT if d.hot else base_col)

	// Dual-pass 3D ribbon rendering for toe rocker tab
	gizmos.with_depth_test(false)
	gizmos.with_color({draw_col.r, draw_col.g, draw_col.b, is_sel || d.hot ? 0.55 : 0.34})
	for i in 0 ..< 4 {
		gizmos.solid_quad({arc_in_pts[i], arc_pts[i], arc_pts[i + 1], arc_in_pts[i + 1]})
	}

	gizmos.with_depth_test(true)
	gizmos.with_color({draw_col.r, draw_col.g, draw_col.b, 0.94})
	for i in 0 ..< 4 {
		gizmos.solid_quad({arc_in_pts[i], arc_pts[i], arc_pts[i + 1], arc_in_pts[i + 1]})
	}
	gizmos.with_color({0.02, 0.03, 0.05, 0.90})
	gizmos.line(pos_w - rgt * (s * 1.05), pos_w + rgt * (s * 1.05))
	for i in 0 ..< 4 {
		gizmos.line(arc_pts[i], arc_pts[i + 1])
		gizmos.line(arc_in_pts[i], arc_in_pts[i + 1])
	}
	if is_sel || d.hot {
		gizmos.with_depth_test(false)
		gizmos.with_color({1.0, 1.0, 0.96, 0.92})
		for i in 0 ..< 4 do gizmos.line(arc_pts[i], arc_pts[i + 1])
	}
	gizmos.with_depth_test(false)

	if show_all_rig_labels || d.hot || is_sel {
		gizmos.label(arc_pts[2] + up * 0.01, label_text, align = {-0.5, 1.0}, offset_px = {0, -9}, scale = 0.78)
	}
}

@(on_draw_gizmos={component=ControlRig})
control_rig_gizmos :: proc(rig: ^crig.ControlRig, ctx: handles.Gizmo_Context) {
	// STRICT: Rig controls are ONLY drawn in Control Rig -> Rig_Controls mode and when toggled on!
	if scene_viewport_mode != .Control_Rig || character_edit_mode != .Rig_Controls || !show_rig_controls {
		if _free_drag.undo_active do _end_free_contour_drag()
		return
	}

	w := engine.ctx_world()
	if w == nil do return

	owner_h := engine.Transform_Handle(rig.owner)
	if !engine.transform_active_in_hierarchy(owner_h) do return

	// ISOLATION: ONLY the active skeletal mesh draws rig controls and responds to selection!
	active_owner := get_active_character_owner()
	if active_owner != {} && owner_h != active_owner do return

	// Auto-bind bones if not bound or invalid so edit mode has full skeletal awareness
	if !rig.bones.bound || !crig.skeleton_bones_alive(&rig.bones) {
		crig.skeleton_bind_humanoid(&rig.bones, rig.owner)
	}

	// Ensure healthy controls (position, rotation, scale, color)
	crig.control_rig_sanitize(rig)

	tw := engine.transform_world(owner_h)
	actor_m := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
	inv_actor_m := linalg.inverse(actor_m)
	cam_pos := handles.frame().view.cam_pos
	char_rot := engine.quat_to_native(tw.rotation)
	ctrl_held := im.GetIO().KeyCtrl || im.GetIO().KeySuper || im.IsKeyDown(im.Key.LeftCtrl) || im.IsKeyDown(im.Key.RightCtrl)

	if _free_drag.dragging && !handles.frame().input.down {
		_end_free_contour_drag()
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// 1. Pelvis (Waist Ring)
	_handle_rig_control(rig, .Pelvis, &rig.pelvis, actor_m, inv_actor_m, char_rot, cam_pos, "Pelvis", ctrl_held, ctx.tool)

	// 2. Spine (Mid Spine waist crunch)
	_handle_rig_control(rig, .Spine, &rig.spine, actor_m, inv_actor_m, char_rot, cam_pos, "Spine", ctrl_held, ctx.tool)

	// 3. Chest (Upper Spine chest twist/lean)
	_handle_rig_control(rig, .Chest, &rig.chest, actor_m, inv_actor_m, char_rot, cam_pos, "Chest", ctrl_held, ctx.tool)

	// 4. Head & Eye Level Socket Controls
	_handle_rig_control(rig, .Head, &rig.head, actor_m, inv_actor_m, char_rot, cam_pos, "Head", ctrl_held, ctx.tool)
	_handle_rig_control(rig, .Eye_Level_Socket, &rig.eye_level_socket, actor_m, inv_actor_m, char_rot, cam_pos, "Eye Socket", ctrl_held, ctx.tool)

	// 5. LookAt Target (Vision Aiming)
	_handle_pure_pos_control(rig, .Look_At, &rig.look_at_target, actor_m, inv_actor_m, char_rot, cam_pos, {0.98, 0.88, 0.38, 0.96}, "LookAt", ctrl_held, ctx.tool)
	look_w := (actor_m * [4]f32{rig.look_at_target.x, rig.look_at_target.y, rig.look_at_target.z, 1}).xyz
	eye_pos_w := _get_control_world_pos(rig, .Eye_Level_Socket, actor_m, char_rot)
	gizmos.with_color({0.98, 0.88, 0.38, 0.38})
	gizmos.line_dashed(eye_pos_w, look_w, 0.06)

	// 6. Feet & Interactive 3D Toe Rockers
	_handle_rig_control(rig, .Left_Foot, &rig.left_foot, actor_m, inv_actor_m, char_rot, cam_pos, "L_Foot", ctrl_held, ctx.tool)
	_handle_rig_control(rig, .Right_Foot, &rig.right_foot, actor_m, inv_actor_m, char_rot, cam_pos, "R_Foot", ctrl_held, ctx.tool)
	_handle_toe_control(rig, .Left_Toe, actor_m, inv_actor_m, char_rot, cam_pos, "L_Toe", ctrl_held, ctx.tool)
	_handle_toe_control(rig, .Right_Toe, actor_m, inv_actor_m, char_rot, cam_pos, "R_Toe", ctrl_held, ctx.tool)

	// 7. Knee Pole Controls (Frost Cyan Spheres + Subtle Dashed Rays)
	_handle_pure_pos_control(rig, .Left_Knee_Pole, &rig.left_knee_pole, actor_m, inv_actor_m, char_rot, cam_pos, {0.38, 0.80, 0.98, 0.92}, "L_Knee_Pole", ctrl_held, ctx.tool)
	_handle_pure_pos_control(rig, .Right_Knee_Pole, &rig.right_knee_pole, actor_m, inv_actor_m, char_rot, cam_pos, {0.38, 0.80, 0.98, 0.92}, "R_Knee_Pole", ctrl_held, ctx.tool)

	lk_pole_w := (actor_m * [4]f32{rig.left_knee_pole.x, rig.left_knee_pole.y, rig.left_knee_pole.z, 1}).xyz
	rk_pole_w := (actor_m * [4]f32{rig.right_knee_pole.x, rig.right_knee_pole.y, rig.right_knee_pole.z, 1}).xyz

	gizmos.with_color({0.38, 0.80, 0.98, 0.36})
	if rig.bones.left_calf != {} && engine.pool_valid(&w.transforms, engine.Handle(rig.bones.left_calf)) {
		lk_bone := engine.transform_world_position(rig.bones.left_calf)
		gizmos.line_dashed(lk_bone, lk_pole_w, 0.05)
	}
	if rig.bones.right_calf != {} && engine.pool_valid(&w.transforms, engine.Handle(rig.bones.right_calf)) {
		rk_bone := engine.transform_world_position(rig.bones.right_calf)
		gizmos.line_dashed(rk_bone, rk_pole_w, 0.05)
	}

	// 8. Hands (Oriented Wrist Controls)
	_handle_rig_control(rig, .Left_Hand, &rig.left_hand, actor_m, inv_actor_m, char_rot, cam_pos, "L_Hand", ctrl_held, ctx.tool)
	_handle_rig_control(rig, .Right_Hand, &rig.right_hand, actor_m, inv_actor_m, char_rot, cam_pos, "R_Hand", ctrl_held, ctx.tool)

	// 9. Elbow Pole Controls (Soft Amber Spheres + Subtle Dashed Rays)
	_handle_pure_pos_control(rig, .Left_Elbow_Pole, &rig.left_elbow_pole, actor_m, inv_actor_m, char_rot, cam_pos, {0.98, 0.76, 0.34, 0.92}, "L_Elbow_Pole", ctrl_held, ctx.tool)
	_handle_pure_pos_control(rig, .Right_Elbow_Pole, &rig.right_elbow_pole, actor_m, inv_actor_m, char_rot, cam_pos, {0.98, 0.76, 0.34, 0.92}, "R_Elbow_Pole", ctrl_held, ctx.tool)

	le_pole_w := (actor_m * [4]f32{rig.left_elbow_pole.x, rig.left_elbow_pole.y, rig.left_elbow_pole.z, 1}).xyz
	re_pole_w := (actor_m * [4]f32{rig.right_elbow_pole.x, rig.right_elbow_pole.y, rig.right_elbow_pole.z, 1}).xyz

	gizmos.with_color({0.98, 0.76, 0.34, 0.36})
	if rig.bones.left_lowerarm != {} && engine.pool_valid(&w.transforms, engine.Handle(rig.bones.left_lowerarm)) {
		le_bone := engine.transform_world_position(rig.bones.left_lowerarm)
		gizmos.line_dashed(le_bone, le_pole_w, 0.05)
	}
	if rig.bones.right_lowerarm != {} && engine.pool_valid(&w.transforms, engine.Handle(rig.bones.right_lowerarm)) {
		re_bone := engine.transform_world_position(rig.bones.right_lowerarm)
		gizmos.line_dashed(re_bone, re_pole_w, 0.05)
	}

	// 10. Unified Selection Transform Gizmo (Translate / Picker, Rotate, Scale)
	_handle_selection_transform(rig, actor_m, inv_actor_m, char_rot, cam_pos, ctx.tool)

	// Immediately solve IK in Edit Mode when Rig Controls are active so 3D gizmo drags pose the character live
	if rig.active {
		bones := crig.control_rig_ensure_bones(rig)
		if bones != nil && bones.bound {
			look_max := f32(85.0)
			wrist_twist := f32(0.5)
			if _, s := engine.transform_get_comp(rig.owner, crig.HumanoidIkSolver); s != nil {
				look_max = s.look_at_max_angle
				wrist_twist = s.wrist_twist_ratio
			}
			crig.humanoid_ik_solve(bones, rig.owner, rig, look_max, wrist_twist)
		}
	}
}

@(private="file")
Free_Contour_Drag_State :: struct {
	dragging:          bool,
	undo_active:       bool,
	armed_ctrl:        Maybe(Active_Rig_Control),
	base_delta:        [3]f32,
	undo_sess:         undo.Edit_Session,
	start_wpos:        [Active_Rig_Control][3]f32,
	start_l_toe_pitch: f32,
	start_r_toe_pitch: f32,
}

@(private="file")
_free_drag: Free_Contour_Drag_State

@(private="file")
Selection_Drag_State :: struct {
	dragging:        bool,
	start_gizmo_pos: [3]f32,
	cur_gizmo_pos:   [3]f32,
	start_gizmo_rot: quaternion128,
	cur_gizmo_rot:   quaternion128,
	start_wpos:      [Active_Rig_Control][3]f32,
	start_wrot:      [Active_Rig_Control]quaternion128,
	start_scale:     [Active_Rig_Control]f32,
}

@(private="file")
_drag_state: Selection_Drag_State

@(private="file")
_drag_undo_sess:   undo.Edit_Session
@(private="file")
_drag_undo_active: bool

@(private)
_get_rig_control :: proc(rig: ^crig.ControlRig, ctrl: Active_Rig_Control) -> ^crig.Rig_Control {
	switch ctrl {
	case .Pelvis:           return &rig.pelvis
	case .Spine:            return &rig.spine
	case .Chest:            return &rig.chest
	case .Head:             return &rig.head
	case .Eye_Level_Socket: return &rig.eye_level_socket
	case .Left_Foot:        return &rig.left_foot
	case .Right_Foot:       return &rig.right_foot
	case .Left_Hand:        return &rig.left_hand
	case .Right_Hand:       return &rig.right_hand
	case .Look_At, .Left_Toe, .Right_Toe, .Left_Knee_Pole, .Right_Knee_Pole, .Left_Elbow_Pole, .Right_Elbow_Pole:
		return nil
	}
	return nil
}

@(private="file")
_get_control_world_pos :: proc(rig: ^crig.ControlRig, ctrl: Active_Rig_Control, actor_m: matrix[4, 4]f32, char_rot: quaternion128) -> [3]f32 {
	if ctrl == .Eye_Level_Socket {
		return crig.control_rig_get_eye_level_world_position(rig)
	}
	if rc := _get_rig_control(rig, ctrl); rc != nil {
		return (actor_m * [4]f32{rc.position.x, rc.position.y, rc.position.z, 1}).xyz
	}
	switch ctrl {
	case .Look_At:
		return (actor_m * [4]f32{rig.look_at_target.x, rig.look_at_target.y, rig.look_at_target.z, 1}).xyz
	case .Left_Knee_Pole:
		return (actor_m * [4]f32{rig.left_knee_pole.x, rig.left_knee_pole.y, rig.left_knee_pole.z, 1}).xyz
	case .Right_Knee_Pole:
		return (actor_m * [4]f32{rig.right_knee_pole.x, rig.right_knee_pole.y, rig.right_knee_pole.z, 1}).xyz
	case .Left_Elbow_Pole:
		return (actor_m * [4]f32{rig.left_elbow_pole.x, rig.left_elbow_pole.y, rig.left_elbow_pole.z, 1}).xyz
	case .Right_Elbow_Pole:
		return (actor_m * [4]f32{rig.right_elbow_pole.x, rig.right_elbow_pole.y, rig.right_elbow_pole.z, 1}).xyz
	case .Left_Toe:
		foot_w := (actor_m * [4]f32{rig.left_foot.position.x, rig.left_foot.position.y, rig.left_foot.position.z, 1}).xyz
		foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.left_foot.rotation))
		reach := max(rig.left_foot.scale * 0.70, 0.12)
		return foot_w + linalg.quaternion128_mul_vector3(foot_rot, [3]f32{0, 0, reach})
	case .Right_Toe:
		foot_w := (actor_m * [4]f32{rig.right_foot.position.x, rig.right_foot.position.y, rig.right_foot.position.z, 1}).xyz
		foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.right_foot.rotation))
		reach := max(rig.right_foot.scale * 0.70, 0.12)
		return foot_w + linalg.quaternion128_mul_vector3(foot_rot, [3]f32{0, 0, reach})
	case .Pelvis, .Spine, .Chest, .Head, .Eye_Level_Socket, .Left_Foot, .Right_Foot, .Left_Hand, .Right_Hand:
		return {}
	}
	return {}
}

@(private="file")
_get_control_world_rot :: proc(rig: ^crig.ControlRig, ctrl: Active_Rig_Control, char_rot: quaternion128) -> quaternion128 {
	if ctrl == .Eye_Level_Socket {
		_, rot := crig.control_rig_get_eye_level_world_transform(rig)
		return rot
	}
	if rc := _get_rig_control(rig, ctrl); rc != nil {
		return linalg.quaternion_normalize(char_rot * engine.quat_to_native(rc.rotation))
	}
	#partial switch ctrl {
	case .Left_Toe:
		foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.left_foot.rotation))
		toe_pitch_q := linalg.quaternion_angle_axis_f32(rig.left_toe_pitch, [3]f32{1, 0, 0})
		return linalg.quaternion_normalize(foot_rot * toe_pitch_q)
	case .Right_Toe:
		foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.right_foot.rotation))
		toe_pitch_q := linalg.quaternion_angle_axis_f32(rig.right_toe_pitch, [3]f32{1, 0, 0})
		return linalg.quaternion_normalize(foot_rot * toe_pitch_q)
	case:
		return quaternion128(1)
	}
}

@(private="file")
_set_control_world_pos :: proc(rig: ^crig.ControlRig, ctrl: Active_Rig_Control, wpos: [3]f32, inv_actor_m: matrix[4, 4]f32, char_rot: quaternion128) {
	if ctrl == .Eye_Level_Socket {
		head_pos, right, up, fwd := crig.control_rig_get_head_face_basis(rig)
		delta := wpos - head_pos
		rig.eye_level_socket.position.x = linalg.dot(delta, right)
		rig.eye_level_socket.position.y = linalg.dot(delta, up)
		rig.eye_level_socket.position.z = linalg.dot(delta, fwd)
		return
	}
	local_pos := (inv_actor_m * [4]f32{wpos.x, wpos.y, wpos.z, 1}).xyz
	if rc := _get_rig_control(rig, ctrl); rc != nil {
		rc.position = local_pos
		return
	}
	switch ctrl {
	case .Look_At:
		rig.look_at_target = local_pos
	case .Left_Knee_Pole:
		rig.left_knee_pole = local_pos
	case .Right_Knee_Pole:
		rig.right_knee_pole = local_pos
	case .Left_Elbow_Pole:
		rig.left_elbow_pole = local_pos
	case .Right_Elbow_Pole:
		rig.right_elbow_pole = local_pos
	case .Left_Toe, .Right_Toe:
		// Toe position is rigidly linked to foot; toe orientation is controlled by pitch
	case .Pelvis, .Spine, .Chest, .Head, .Eye_Level_Socket, .Left_Foot, .Right_Foot, .Left_Hand, .Right_Hand:
	}
}

@(private="file")
_set_control_world_rot :: proc(rig: ^crig.ControlRig, ctrl: Active_Rig_Control, wrot: quaternion128, char_rot: quaternion128) {
	if ctrl == .Eye_Level_Socket {
		_, base_rot := crig.control_rig_get_eye_level_world_transform(rig)
		inv_base := linalg.quaternion_inverse(base_rot)
		local_rot := linalg.quaternion_normalize(inv_base * wrot)
		rig.eye_level_socket.rotation = engine.quat_from_native(local_rot)
		return
	}
	inv_char_rot := linalg.quaternion_inverse(char_rot)
	if rc := _get_rig_control(rig, ctrl); rc != nil {
		local_rot := linalg.quaternion_normalize(inv_char_rot * wrot)
		rc.rotation = engine.quat_from_native(local_rot)
		return
	}
	switch ctrl {
	case .Left_Toe:
		foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.left_foot.rotation))
		rel := linalg.quaternion_normalize(linalg.quaternion_inverse(foot_rot) * wrot)
		if rel.w < 0 do rel = -rel
		pitch := 2.0 * math.atan2(rel.x, rel.w)
		rig.left_toe_pitch = math.clamp(pitch, -1.2, 1.2)
	case .Right_Toe:
		foot_rot := linalg.quaternion_normalize(char_rot * engine.quat_to_native(rig.right_foot.rotation))
		rel := linalg.quaternion_normalize(linalg.quaternion_inverse(foot_rot) * wrot)
		if rel.w < 0 do rel = -rel
		pitch := 2.0 * math.atan2(rel.x, rel.w)
		rig.right_toe_pitch = math.clamp(pitch, -1.2, 1.2)
	case .Look_At, .Left_Knee_Pole, .Right_Knee_Pole, .Left_Elbow_Pole, .Right_Elbow_Pole:
	case .Pelvis, .Spine, .Chest, .Head, .Eye_Level_Socket, .Left_Foot, .Right_Foot, .Left_Hand, .Right_Hand:
	}
}

@(private="file")
_handle_selection_transform :: proc(
	rig: ^crig.ControlRig,
	actor_m: matrix[4, 4]f32,
	inv_actor_m: matrix[4, 4]f32,
	char_rot: quaternion128,
	cam_pos: [3]f32,
	tool: handles.Tool,
) {
	sel_count := active_rig_control_count(engine.Transform_Handle(rig.owner))
	if sel_count == 0 {
		if _drag_undo_active {
			undo.edit_session_end(&_drag_undo_sess)
			_drag_undo_active = false
		}
		_drag_state.dragging = false
		return
	}

	primary_ctrl := active_rig_control
	if primary_ctrl not_in selected_rig_controls {
		for c in Active_Rig_Control {
			if c in selected_rig_controls {
				primary_ctrl = c
				active_rig_control = c
				break
			}
		}
	}

	gizmo_pos: [3]f32
	if handles.is_pivot_center() && sel_count > 1 {
		sum: [3]f32
		n: f32 = 0
		for c in Active_Rig_Control {
			if c in selected_rig_controls {
				sum += _get_control_world_pos(rig, c, actor_m, char_rot)
				n += 1.0
			}
		}
		gizmo_pos = sum / n
	} else {
		gizmo_pos = _get_control_world_pos(rig, primary_ctrl, actor_m, char_rot)
	}

	// Toe controls cannot translate independently of their foot; when a toe is the sole selection,
	// default Translate/Picker gizmos to Rotate so the ball-of-foot hinge rolls naturally!
	effective_tool := tool
	if effective_tool == .Picker {
		effective_tool = .Translate
	}
	if sel_count == 1 && (primary_ctrl == .Left_Toe || primary_ctrl == .Right_Toe) && effective_tool == .Translate {
		effective_tool = .Rotate
	}

	gizmo_rot: quaternion128
	if handles.is_local_space() || (sel_count == 1 && (primary_ctrl == .Left_Toe || primary_ctrl == .Right_Toe)) {
		gizmo_rot = _get_control_world_rot(rig, primary_ctrl, char_rot)
	} else {
		gizmo_rot = quaternion128(1)
	}

	v := handles.frame().view
	dist: f32
	if abs(v.proj[3, 3]) > 0.5 && abs(v.proj[1, 1]) > 1e-6 {
		half_h := 1.0 / abs(v.proj[1, 1])
		dist = half_h / math.tan(math.to_radians(f32(45.0)) * 0.5)
	} else {
		cam_fwd := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
		cam_depth := linalg.dot(gizmo_pos - cam_pos, cam_fwd)
		if cam_depth <= 0.01 do return
		if abs(v.proj[1, 1]) > 1e-6 {
			half_h := cam_depth / abs(v.proj[1, 1])
			dist = half_h / math.tan(math.to_radians(f32(45.0)) * 0.5)
		} else {
			dist = cam_depth
		}
	}
	size := clamp(dist * 0.16, 0.002, 0.85)

	switch effective_tool {
	case .Picker, .Handles:
		// In Free Drag (.Handles / T) mode, contour handles own direct camera-plane dragging.
		if _drag_undo_active {
			undo.edit_session_end(&_drag_undo_sess)
			_drag_undo_active = false
		}
		if _drag_state.dragging do _drag_state.dragging = false
		return

	case .Translate:
		pos := _drag_state.cur_gizmo_pos if _drag_state.dragging else gizmo_pos
		d := handles.position_handle(handles.id_of(rig.owner, 0x516_0001), &pos, gizmo_rot, size, prio = 10)
		if d.started {
			_drag_state.dragging = true
			_drag_state.start_gizmo_pos = gizmo_pos
			_drag_state.cur_gizmo_pos = gizmo_pos
			for c in Active_Rig_Control {
				if c in selected_rig_controls {
					_drag_state.start_wpos[c] = _get_control_world_pos(rig, c, actor_m, char_rot)
				}
			}
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			_drag_undo_sess = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Translate Rig Control")
			_drag_undo_active = true
		}
		if _drag_state.dragging && (d.dragging || d.released) {
			_drag_state.cur_gizmo_pos = pos
			delta_w := pos - _drag_state.start_gizmo_pos
			for c in Active_Rig_Control {
				if c in selected_rig_controls {
					new_wpos := _drag_state.start_wpos[c] + delta_w
					_set_control_world_pos(rig, c, new_wpos, inv_actor_m, char_rot)
				}
			}
			rig.active = true
			if _, s := engine.transform_get_comp(rig.owner, crig.HumanoidIkSolver); s != nil do s.active = true
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		if d.released || (_drag_state.dragging && !d.dragging) {
			_drag_state.dragging = false
			if _drag_undo_active {
				undo.edit_session_end(&_drag_undo_sess)
				_drag_undo_active = false
			}
		}

	case .Rotate:
		rot := _drag_state.cur_gizmo_rot if _drag_state.dragging else gizmo_rot
		use_local := handles.is_local_space() || (sel_count == 1 && (primary_ctrl == .Left_Toe || primary_ctrl == .Right_Toe))
		d := handles.rotation_handle(handles.id_of(rig.owner, 0x516_0002), &rot, gizmo_pos, size, local = use_local, prio = 10)
		if d.started {
			_drag_state.dragging = true
			_drag_state.start_gizmo_pos = gizmo_pos
			_drag_state.start_gizmo_rot = gizmo_rot
			_drag_state.cur_gizmo_rot = gizmo_rot
			for c in Active_Rig_Control {
				if c in selected_rig_controls {
					_drag_state.start_wpos[c] = _get_control_world_pos(rig, c, actor_m, char_rot)
					_drag_state.start_wrot[c] = _get_control_world_rot(rig, c, char_rot)
				}
			}
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			_drag_undo_sess = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Rotate Rig Control")
			_drag_undo_active = true
		}
		if _drag_state.dragging && (d.dragging || d.released) {
			_drag_state.cur_gizmo_rot = rot
			turn := rot * conj(_drag_state.start_gizmo_rot)
			for c in Active_Rig_Control {
				if c in selected_rig_controls {
					new_wrot := turn * _drag_state.start_wrot[c]
					_set_control_world_rot(rig, c, new_wrot, char_rot)
					off := _drag_state.start_wpos[c] - _drag_state.start_gizmo_pos
					if linalg.length(off) > 1e-5 {
						new_wpos := _drag_state.start_gizmo_pos + linalg.quaternion128_mul_vector3(turn, off)
						_set_control_world_pos(rig, c, new_wpos, inv_actor_m, char_rot)
					}
				}
			}
			rig.active = true
			if _, s := engine.transform_get_comp(rig.owner, crig.HumanoidIkSolver); s != nil do s.active = true
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		if d.released || (_drag_state.dragging && !d.dragging) {
			_drag_state.dragging = false
			if _drag_undo_active {
				undo.edit_session_end(&_drag_undo_sess)
				_drag_undo_active = false
			}
		}

	case .Scale:
		scale_vec := [3]f32{1, 1, 1}
		d := handles.scale_handle(handles.id_of(rig.owner, 0x516_0003), &scale_vec, gizmo_pos, gizmo_rot, size, prio = 10)
		if d.started {
			_drag_state.dragging = true
			for c in Active_Rig_Control {
				if c in selected_rig_controls {
					if rc := _get_rig_control(rig, c); rc != nil {
						_drag_state.start_scale[c] = rc.scale
					}
				}
			}
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			_drag_undo_sess = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Scale Rig Control")
			_drag_undo_active = true
		}
		if _drag_state.dragging && (d.dragging || d.released) {
			avg := (scale_vec.x + scale_vec.y + scale_vec.z) / 3.0
			for c in Active_Rig_Control {
				if c in selected_rig_controls {
					if rc := _get_rig_control(rig, c); rc != nil {
						rc.scale = clamp(_drag_state.start_scale[c] * avg, 0.05, 1.5)
					}
				}
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		if d.released || (_drag_state.dragging && !d.dragging) {
			_drag_state.dragging = false
			if _drag_undo_active {
				undo.edit_session_end(&_drag_undo_sess)
				_drag_undo_active = false
			}
		}
	}
}
