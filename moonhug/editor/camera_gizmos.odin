package editor

// Camera frustum gizmo (Unity's): the selected camera draws its view frustum
// as a wire frustum (near rect, far rect, connecting edges). Aspect comes from
// the game view's render target so the wires show exactly what the game view
// sees. Runs through the @(on_draw_gizmos) hook for cameras in the selection, drawn with
// engine/gizmos. Every camera also gets a scene icon.

import "core:math"
import "core:math/linalg"
import "moonhug:engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"

@(phase={key=engine.Phase.EditorInit, order=2, mode=Editor})
camera_picker_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	handles.pick_register(handles.Pick_Provider{
		click = _camera_pick_click,
		band  = _camera_pick_band,
	})
}

CAM_AABB_MIN :: [3]f32{-0.26, -0.20, -0.58}
CAM_AABB_MAX :: [3]f32{ 0.26,  0.28,  0.40}

@(private = "file")
_camera_pick_click :: proc(view: engine.Render_View, ray: engine.Ray) -> (tH: engine.Transform_Handle, t: f32, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return {}, 0, false

	min_t: f32 = 1e30
	hit_cam := engine.Transform_Handle{}

	cam_it := engine.pool_iterator(engine.cameras(w))
	for cam, _ in engine.pool_next(&cam_it) {
		if !cam.enabled do continue
		cam_h := engine.Transform_Handle(cam.owner)
		if cam_h == {} || !engine.transform_active_in_hierarchy(cam.owner) do continue
		if engine.node_is_locked_in_hierarchy(cam_h) do continue

		tw := engine.transform_world(cam_h)
		inv := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		local_o := inv * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
		local_d := inv * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}
		local_ray := engine.Ray{origin = local_o.xyz, direction = local_d.xyz}

		if hit_t, hit := engine.ray_hit_aabb(local_ray, CAM_AABB_MIN, CAM_AABB_MAX); hit {
			if hit_t > 0 && hit_t < min_t {
				min_t = hit_t
				hit_cam = cam_h
			}
		}
	}

	if hit_cam != {} {
		return hit_cam, min_t, true
	}
	return {}, 0, false
}

@(private = "file")
_camera_pick_band :: proc(view: engine.Render_View, rmin, rmax: [2]f32, out: ^[dynamic]engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return

	corners: [8][3]f32 = {
		{CAM_AABB_MIN.x, CAM_AABB_MIN.y, CAM_AABB_MIN.z},
		{CAM_AABB_MAX.x, CAM_AABB_MIN.y, CAM_AABB_MIN.z},
		{CAM_AABB_MIN.x, CAM_AABB_MAX.y, CAM_AABB_MIN.z},
		{CAM_AABB_MAX.x, CAM_AABB_MAX.y, CAM_AABB_MIN.z},
		{CAM_AABB_MIN.x, CAM_AABB_MIN.y, CAM_AABB_MAX.z},
		{CAM_AABB_MAX.x, CAM_AABB_MIN.y, CAM_AABB_MAX.z},
		{CAM_AABB_MIN.x, CAM_AABB_MAX.y, CAM_AABB_MAX.z},
		{CAM_AABB_MAX.x, CAM_AABB_MAX.y, CAM_AABB_MAX.z},
	}

	cam_it := engine.pool_iterator(engine.cameras(w))
	for cam, _ in engine.pool_next(&cam_it) {
		if !cam.enabled do continue
		cam_h := engine.Transform_Handle(cam.owner)
		if cam_h == {} || !engine.transform_active_in_hierarchy(cam.owner) do continue
		if engine.node_is_locked_in_hierarchy(cam_h) do continue

		tw := engine.transform_world(cam_h)
		trs := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		world_corners: [8][3]f32
		for k in 0 ..< 8 {
			p4 := trs * [4]f32{corners[k].x, corners[k].y, corners[k].z, 1.0}
			world_corners[k] = p4.xyz
		}

		if _rect_hits_points(view, rmin, rmax, world_corners[:]) {
			append(out, cam_h)
		}
	}
}

CAMERA_GIZMO_COLOR :: [4]f32{0.95, 0.95, 0.95, 0.9}
CAMERA_BODY_COLOR  :: [4]f32{0.55, 0.75, 0.95, 0.70}
CAMERA_SEL_COLOR   :: [4]f32{1.0, 0.82, 0.25, 0.95}

// Scene icon: small fallback symbol
@(private = "file")
_icon_camera :: proc() {
	gizmos.wire_rect({-0.1, 0, 0}, {0.6, 0.4})
	gizmos.wire_triangle({0.2, 0, 0}, {0.5, 0.2, 0}, {0.5, -0.2, 0})
}

@(on_draw_gizmos={component=Camera})
camera_gizmos :: proc(cam: ^engine.Camera, ctx: handles.Gizmo_Context) {
	cam_h := engine.Transform_Handle(cam.owner)
	if cam_h == {} do return

	tw := engine.transform_world(cam_h)
	is_selected := (.In_Selection in ctx.state)

	// 1. 3D Wireframe Camera Body (Blender / Unreal style: scene view only)
	if gizmos.channel() == .Editor {
		gizmos.in_local_space(cam_h, false)
		body_col := is_selected ? CAMERA_SEL_COLOR : CAMERA_BODY_COLOR
		gizmos.with_color(body_col)

		// A. Main camera body chassis (behind lens)
		gizmos.wire_box({0, 0, 0.22}, {0.34, 0.26, 0.30})

		// B. Lens cone / matte box (expanding forward towards -Z)
		lens_back: [4][3]f32 = {
			{-0.12, -0.09, 0.07},
			{ 0.12, -0.09, 0.07},
			{ 0.12,  0.09, 0.07},
			{-0.12,  0.09, 0.07},
		}
		lens_front: [4][3]f32 = {
			{-0.22, -0.15, -0.18},
			{ 0.22, -0.15, -0.18},
			{ 0.22,  0.15, -0.18},
			{-0.22,  0.15, -0.18},
		}
		gizmos.wire_frustum(lens_back, lens_front)

		// C. Blender-style top orientation / up-direction triangle
		gizmos.line({0, 0.24, 0.08}, {-0.10, 0.13, 0.22})
		gizmos.line({0, 0.24, 0.08}, { 0.10, 0.13, 0.22})
		gizmos.line({0, 0.24, 0.08}, { 0,     0.13, -0.02})
		gizmos.line({-0.10, 0.13, 0.22}, { 0.10, 0.13, 0.22})
		gizmos.line({ 0.10, 0.13, 0.22}, { 0,     0.13, -0.02})
		gizmos.line({ 0,     0.13, -0.02}, {-0.10, 0.13, 0.22})

		// D. Optical forward axis arrow (points in camera view direction: -Z)
		gizmos.line_arrow({0, 0, -0.18}, {0, 0, -0.55}, 0.08)
	}

	// 2. Clickable scene handle
	handles.icon(tw.position, cam_h, _icon_camera)

	// 3. View Frustum (only when selected)
	if !is_selected do return

	rot := engine.quat_to_matrix3(tw.rotation)
	right := [3]f32{rot[0, 0], rot[1, 0], rot[2, 0]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}

	aspect := f32(16.0 / 9.0)
	if game_rt != nil && game_rt.height > 0 {
		aspect = f32(game_rt.width) / f32(game_rt.height)
	}
	tan_half := math.tan(math.to_radians(cam.fov) * 0.5)

	rect :: proc(origin: [3]f32, right, up, forward: [3]f32, d, tan_half, aspect: f32) -> [4][3]f32 {
		hh := d * tan_half
		hw := hh * aspect
		c := origin + forward * d
		return {
			c - right * hw - up * hh,
			c + right * hw - up * hh,
			c + right * hw + up * hh,
			c - right * hw + up * hh,
		}
	}
	near := rect(tw.position, right, up, forward, max(cam.near_clip, 0.01), tan_half, aspect)
	far := rect(tw.position, right, up, forward, max(cam.far_clip, cam.near_clip), tan_half, aspect)

	gizmos.with_color(CAMERA_GIZMO_COLOR)
	gizmos.wire_frustum(near, far)
}
