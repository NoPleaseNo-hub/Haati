package engine

// Camera + render-command pipeline on the gfx package (docs/SDL3Renderer.md).
// Cameras collect per-frame command lists (temp allocator) from the world's
// renderer pools and execute them through gfx draws. The editor scene view
// reuses the SAME collect/execute path with its own (non-component) camera,
// so game view and scene view render identically by construction.

import gfx "gfx"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

PIXELS_PER_UNIT :: 100.0

// Unity's CameraType: which surface a view renders. Collectors differentiate
// — the particles edit preview draws in scene views but never in an
// edit-mode game view.
View_Kind :: enum u8 {
	Game,      // a scene Camera component
	SceneView, // the editor's scene view
	Preview,   // thumbnails and inspector previews
}

Render_View :: struct {
	view, proj:     matrix[4, 4]f32,
	view_proj:      matrix[4, 4]f32,
	inv_view_proj:  matrix[4, 4]f32,
	cam_pos:        [3]f32, // camera world position (specular shaders, LOD later)
	width, height:  f32, // viewport pixels (screen->ray, gizmo sizing)
	layer_mask:     u32,
	kind:           View_Kind,
	camera:         Transform_Handle, // the Camera node a Game view renders for; {} for editor views
	frustum_planes: [6][4]f32,        // Gribb-Hartmann normalized planes (nx, ny, nz, d): L, R, B, T, Near, Far
	has_frustum:    bool,
}

// Alpha-blended commands sort by a lexicographic multi-level key — collectors
// build it (sprite layout: packages/sprites/sprite_sort.odin). 4 levels (32 B)
// supports 3 nested SpriteSortingGroups + leaf sprite while halving command
// sort-key footprint; single-level keys fast-path in one 64-bit register compare.
SORT_KEY_LEVELS :: 4

Sort_Key :: [SORT_KEY_LEVELS]u64

sort_key_less :: #force_inline proc(a, b: Sort_Key) -> bool {
	if a[0] != b[0] do return a[0] < b[0]
	if (a[1] | b[1]) == 0 do return false
	for i in 1 ..< SORT_KEY_LEVELS {
		if a[i] != b[i] do return a[i] < b[i]
	}
	return false
}

// One transparent-sort word — the packing convention every alpha-blended
// collector shares, so sprites and particles interleave correctly:
//   layer:8 (biased) | order:16 (biased) | ~depth:24 | seq:16
// Depth quantization: positive f32 bit patterns are monotonic as integers,
// so the top 24 bits of the view-space distance's bit pattern order
// correctly without knowing near/far; inverted so a larger distance
// (farther) yields a smaller word (drawn first, back-to-front).
sort_key_word :: proc(layer, order: i32, view_depth: f32, seq: u16) -> u64 {
	l := u64(u32(clamp(layer, -128, 127) + 128))
	o := u64(u32(clamp(order, -32768, 32767) + 32768))
	d := u64(transmute(u32)max(view_depth, 0) >> 8) & 0xFFFFFF
	d = 0xFFFFFF - d
	return l << 56 | o << 40 | d << 16 | u64(seq)
}

// View-space distance of a world position (right-handed view looks down -Z,
// larger = farther) — the depth every collector feeds sort_key_word.
sort_key_depth :: proc(view: Render_View, world_pos: [3]f32) -> f32 {
	pos4 := view.view * [4]f32{world_pos.x, world_pos.y, world_pos.z, 1}
	return -pos4.z
}

// Full-texture uvs, bl br tr tl. uv origin is top-left (stb rows are
// top-down), so bl/br carry v=1 and tr/tl v=0.
QUAD_UVS_FULL :: [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// A textured quad with a transparent sort key — sprites, any 2D emitter.
Draw_Quad :: struct {
	texture:  Asset_GUID,
	material: Asset_GUID, // shader/tint/properties; texture stays the quad's own. empty = unlit
	corners:  [4][3]f32, // world-space bl, br, tr, tl — shared with picking
	uvs:      [4][2]f32, // per corner; QUAD_UVS_FULL for the whole texture, a sub-rect for slices
	color:    [4]f32,
}

Draw_Mesh :: struct {
	mesh:          Asset_GUID,
	part:          i32, // resolved FILE-ORDER part: 0 = whole model, N = glTF mesh N-1 (mesh_filter_part)
	materials:     []Asset_GUID, // per-submesh; view into the renderer's array (frame lifetime). missing/empty = white unlit
	model:         matrix[4, 4]f32,
	// Posed vertices from a SkinnedMeshRenderer, drawn instead of the asset's
	// own buffers. The asset is still loaded, for its submesh ranges and
	// materials. nil for a static draw.
	skinned:       ^gfx.Mesh,
	// Hardware wireframe overlay: if non-nil and wire_color.a > 0, renders line topology
	wire_mesh:     ^gfx.Mesh,
	wire_color:    [4]f32,
	// Heatmap / weight paint mode: draws unlit with white texture so vertex heat colors are 100% vibrant
	unlit_heatmap: bool,
	// Opt out of GPU shadow map casting (cast_shadows = false / translucent / unlit overlays)
	no_shadow:     bool,
}

Render_Command :: struct {
	key:     Sort_Key, // alpha-blended quads only; zero for meshes
	// The transform whose renderer emits the command. The editor picks,
	// outlines and frames package renderers by the quads they draw.
	owner:   Transform_Handle,
	variant: union #no_nil {
		Draw_Mesh,
		Draw_Quad,
	},
}

Ray :: struct {
	origin, direction: [3]f32,
}

// Highest-order enabled camera — for game logic queries (mouse rays).
// Rendering iterates ALL enabled cameras (render_world_cameras).
camera_active :: proc() -> ^Camera {
	world := ctx_world()
	best: ^Camera
	best_order: i32 = min(i32)
	it := pool_iterator(cameras(world))
	for cam, _ in pool_next(&it) {
		if !cam.enabled do continue
		if !transform_active_in_hierarchy(cam.owner) do continue
		if cam.order > best_order {
			best_order = cam.order
			best = cam
		}
	}
	return best
}

_extract_frustum_planes :: proc(vp: matrix[4, 4]f32) -> (planes: [6][4]f32, valid: bool) {
	r0 := [4]f32{vp[0, 0], vp[0, 1], vp[0, 2], vp[0, 3]}
	r1 := [4]f32{vp[1, 0], vp[1, 1], vp[1, 2], vp[1, 3]}
	r2 := [4]f32{vp[2, 0], vp[2, 1], vp[2, 2], vp[2, 3]}
	r3 := [4]f32{vp[3, 0], vp[3, 1], vp[3, 2], vp[3, 3]}

	raw_planes := [6][4]f32{
		r3 + r0, // Left
		r3 - r0, // Right
		r3 + r1, // Bottom
		r3 - r1, // Top
		r2,      // Near (z01: 0 <= z_clip <= w_clip)
		r3 - r2, // Far
	}
	for i in 0 ..< 6 {
		p := raw_planes[i]
		n_len := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		if n_len < 1e-6 do return {}, false
		planes[i] = p / n_len
	}
	return planes, true
}

// Tests whether a world-space sphere intersects or lies inside `view`'s frustum (`REV-10`).
render_view_frustum_test_sphere :: #force_inline proc(view: Render_View, center: [3]f32, radius: f32) -> bool {
	if !view.has_frustum do return true
	for p in view.frustum_planes {
		dist := p.x * center.x + p.y * center.y + p.z * center.z + p.w
		if dist < -radius do return false
	}
	return true
}

// Tests whether a local-space AABB (`aabb_min`, `aabb_max`) transformed by `model`
// intersects or lies inside `view`'s frustum using Arvo's O(1) abs-extent projection (`REV-10`).
render_view_frustum_test_aabb :: proc(view: Render_View, aabb_min, aabb_max: [3]f32, model: matrix[4, 4]f32) -> bool {
	if !view.has_frustum do return true
	local_center  := (aabb_min + aabb_max) * 0.5
	local_extents := (aabb_max - aabb_min) * 0.5
	if local_extents.x < 0 || local_extents.y < 0 || local_extents.z < 0 do return true

	wc4 := model * [4]f32{local_center.x, local_center.y, local_center.z, 1.0}
	wc  := wc4.xyz
	wx  := abs(model[0, 0]) * local_extents.x + abs(model[0, 1]) * local_extents.y + abs(model[0, 2]) * local_extents.z
	wy  := abs(model[1, 0]) * local_extents.x + abs(model[1, 1]) * local_extents.y + abs(model[1, 2]) * local_extents.z
	wz  := abs(model[2, 0]) * local_extents.x + abs(model[2, 1]) * local_extents.y + abs(model[2, 2]) * local_extents.z

	for p in view.frustum_planes {
		r := abs(p.x) * wx + abs(p.y) * wy + abs(p.z) * wz
		s := p.x * wc.x + p.y * wc.y + p.z * wc.z + p.w
		if s + r < 0 do return false
	}
	return true
}

render_view_make :: proc(view, proj: matrix[4, 4]f32, width, height: f32, layer_mask: u32, kind: View_Kind = .Game) -> Render_View {
	vp := proj * view
	// Camera world position = translation column of the inverted view matrix
	// — derived here so every caller (game cameras, editor scene view) gets it
	// without extra plumbing.
	inv_view := linalg.inverse(view)
	planes, has_frustum := _extract_frustum_planes(vp)
	return Render_View{
		view           = view,
		proj           = proj,
		view_proj      = vp,
		inv_view_proj  = linalg.inverse(vp),
		cam_pos        = {inv_view[0, 3], inv_view[1, 3], inv_view[2, 3]},
		width          = width,
		height         = height,
		layer_mask     = layer_mask,
		kind           = kind,
		frustum_planes = planes,
		has_frustum    = has_frustum,
	}
}

// View from the camera transform's world rotation (forward = -Z column,
// up = +Y column); projection honors the component's projection mode,
// fov/orthographic_size, and near/far clip planes.
camera_render_view :: proc(cam: ^Camera, width, height: f32) -> Render_View {
	tw := transform_world(Transform_Handle(cam.owner))
	rot := quat_to_matrix3(tw.rotation)
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	view := linalg.matrix4_look_at_f32(tw.position, tw.position + forward, up)
	aspect := width / max(height, 1)
	proj: matrix[4, 4]f32
	if cam.projection == .Orthographic {
		half_h := cam.orthographic_size > 0 ? cam.orthographic_size : 5.0
		half_w := half_h * aspect
		proj = gfx.matrix4_ortho_z01(-half_w, half_w, -half_h, half_h, cam.near_clip, cam.far_clip)
	} else {
		proj = gfx.matrix4_perspective_z01(math.to_radians(cam.fov), aspect, cam.near_clip, cam.far_clip)
	}
	rv := render_view_make(view, proj, width, height, cam.render_layer_mask)
	rv.camera = Transform_Handle(cam.owner)
	return rv
}

// Unprojects a viewport pixel (origin top-left) into a world ray. Replaces
// rl.GetScreenToWorldRay for game code (turret_aim) and feeds scene picking.
render_view_screen_ray :: proc(view: Render_View, px, py: f32) -> Ray {
	ndc_x := 2 * px / max(view.width, 1) - 1
	ndc_y := 1 - 2 * py / max(view.height, 1)
	near4 := view.inv_view_proj * [4]f32{ndc_x, ndc_y, 0, 1} // z01: near plane at 0
	far4 := view.inv_view_proj * [4]f32{ndc_x, ndc_y, 1, 1}
	near := near4.xyz / near4.w
	far := far4.xyz / far4.w
	return Ray{origin = near, direction = linalg.normalize(far - near)}
}

camera_screen_ray :: proc(cam: ^Camera, screen_pos: [2]f32, viewport: [2]f32) -> Ray {
	view := camera_render_view(cam, viewport.x, viewport.y)
	return render_view_screen_ray(view, screen_pos.x, screen_pos.y)
}

trs_matrix :: proc(position: [3]f32, rotation: [4]f32, scale: [3]f32) -> matrix[4, 4]f32 {
	q := quaternion(x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w)
	return linalg.matrix4_from_trs_f32(position, q, scale)
}

// A collector appends commands for the renderers it owns that are visible to
// `view` (enabled, active in hierarchy, layer mask intersecting). `out` lives
// on the temp allocator. Packages register theirs once at an init phase —
// the registry is the seam that lets renderer components live outside the
// engine. Collection order does not matter: render_execute sorts the
// combined list.
Render_Collector :: proc(view: Render_View, out: ^[dynamic]Render_Command)

// Process-lifetime registry on the default allocator — registration must not
// capture the caller's context allocator (a test-local or temp allocator
// would free the backing array under the registry).
_render_collectors: [dynamic]Render_Collector

@(init)
_render_collectors_init :: proc "contextless" () {
	context = runtime.default_context()
	_render_collectors = make([dynamic]Render_Collector, runtime.default_allocator())
}

render_register_collector :: proc(c: Render_Collector) {
	append(&_render_collectors, c)
}

// Appends commands for every renderer visible to `view`: the engine's
// built-in collectors, then every registered one. meshes=false leaves out the
// engine's mesh and skinned mesh renderers: the editor's quad queries need
// neither, and collecting skinned meshes poses them for the frame.
render_collect_commands :: proc(view: Render_View, out: ^[dynamic]Render_Command, meshes := true, canvases := true) {
	transform_update_world_parallel(ctx_world())
	if meshes {
		_collect_mesh_renderers(view, out)
		skinned_mesh_collect(out, view) // component_SkinnedMeshRenderer.odin
	}
	if canvases {
		canvas_collect_graphics(view, out) // the canvas tree (ui_canvas.odin)
	}
	for c in _render_collectors do c(view, out)
}

@(private = "file")
_Mesh_Collect_Item :: struct {
	owner:     Transform_Handle,
	mesh:      Asset_GUID,
	part:      i32,
	materials: []Asset_GUID,
	tw:        Transform_World,
	no_shadow: bool,
}

@(private = "file")
_Mesh_Collect_Ctx :: struct {
	view:    Render_View,
	items:   []_Mesh_Collect_Item,
	buckets: [MAX_WORKER_THREADS + 1][dynamic]Render_Command,
}

@(private = "file")
_build_mesh_render_command :: proc(view: Render_View, item: _Mesh_Collect_Item) -> (Render_Command, bool) {
	model := trs_matrix(item.tw.position, item.tw.rotation, item.tw.scale)

	// View frustum culling (`REV-10`): when the mesh is already resident in
	// `mesh_cache` with non-degenerate local bounds, test its world AABB
	// against the camera's 6 frustum planes before emitting a Draw_Mesh.
	if view.has_frustum && len(mesh_cache) > 0 {
		if m, ok := &mesh_cache[Mesh_Key{item.mesh, item.part}]; ok {
			if m.aabb_max != m.aabb_min {
				if !render_view_frustum_test_aabb(view, m.aabb_min, m.aabb_max, model) {
					return {}, false
				}
			}
		}
	}

	return Render_Command{
		owner = item.owner,
		variant = Draw_Mesh{
			mesh      = item.mesh,
			part      = item.part,
			materials = item.materials,
			model     = model,
			no_shadow = item.no_shadow,
		},
	}, true
}

@(private = "file")
_collect_mesh_worker :: proc(start_idx, end_idx: int, user_data: rawptr) {
	ctx := (^_Mesh_Collect_Ctx)(user_data)
	slot := job_current_worker_index()
	if slot < 0 || slot >= MAX_WORKER_THREADS {
		slot = MAX_WORKER_THREADS
	}
	bucket := &ctx.buckets[slot]
	for i in start_idx ..< end_idx {
		if cmd, ok := _build_mesh_render_command(ctx.view, ctx.items[i]); ok {
			append(bucket, cmd)
		}
	}
}

_collect_mesh_renderers :: proc(view: Render_View, out: ^[dynamic]Render_Command) {
	world := ctx_world()
	items := make([dynamic]_Mesh_Collect_Item, 0, min(mesh_renderers(world).count, 512), runtime.default_allocator())
	defer delete(items)

	mr_it := pool_iterator(mesh_renderers(world))
	for mr, _ in pool_next(&mr_it) {
		if !mr.enabled do continue

		t := pool_get(&world.transforms, Handle(mr.owner))
		if t == nil || !transform_active_in_hierarchy(mr.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		_, mf := transform_get_comp(Transform_Handle(mr.owner), MeshFilter)
		if mf == nil || asset_guid_is_empty(mf.mesh.guid) do continue
		part, part_ok := mesh_filter_part(mf)
		if !part_ok do continue

		append(&items, _Mesh_Collect_Item{
			owner     = Transform_Handle(mr.owner),
			mesh      = mf.mesh.guid,
			part      = part,
			materials = mr.materials[:],
			tw        = transform_world(Transform_Handle(mr.owner)),
			no_shadow = !mr.cast_shadows,
		})
	}

	if len(items) < 64 || job_system_worker_count() <= 1 {
		for item in items {
			if cmd, ok := _build_mesh_render_command(view, item); ok {
				append(out, cmd)
			}
		}
		return
	}

	cctx: _Mesh_Collect_Ctx
	cctx.view = view
	cctx.items = items[:]
	for bi in 0 ..< len(cctx.buckets) {
		cctx.buckets[bi] = make([dynamic]Render_Command, 0, 32, runtime.default_allocator())
	}
	defer for bi in 0 ..< len(cctx.buckets) {
		delete(cctx.buckets[bi])
	}

	job_parallel_for(len(items), 16, _collect_mesh_worker, &cctx)

	for bi in 0 ..< len(cctx.buckets) {
		for cmd in cctx.buckets[bi] {
			append(out, cmd)
		}
	}
}

// Sorts and replays commands into the CURRENT gfx pass: opaque meshes first
// (depth-write pipeline handles their ordering; grouped by material to batch
// pipeline/texture binds), then alpha-blended quads by their sort key
// (lexicographic over levels — the sprite collector makes keys unique, so
// their order is total and deterministic regardless of sort stability).
// Every enabled Light (up to gfx.MAX_LIGHTS, the pool max) fills `buf` in pool
// order. The ambient floor is the first enabled light's. Returns the count and
// ambient; count 0 leaves the gfx default in effect.
scene_collect_lights :: proc(buf: []gfx.Light) -> (n: int, ambient: f32) {
	world := ctx_world()
	it := pool_iterator(lights(world))
	for l, _ in pool_next(&it) {
		if n >= len(buf) do break
		if !l.enabled do continue
		if !transform_active_in_hierarchy(l.owner) do continue

		tw := transform_world(Transform_Handle(l.owner))
		if n == 0 do ambient = l.ambient
		buf[n] = light_to_gfx(l, tw)
		n += 1
	}
	return n, ambient
}

// Scene-view lighting override modes (`Game` views ignore this and always render true `Lit`).
Scene_Lighting_Mode :: enum u8 {
	Lit,       // Real-time scene lighting (0 lights = true pitch black)
	Unlit,     // Flat full-bright ambient (`ambient = 1.0`, 0 lights)
	FakeLight, // Studio angled directional light casting 3-cascade CSM shadows (`ambient = 0.35`)
}

// Active editor Scene View lighting mode. Also mirrors `render_scene_unlit_override`
// so existing callers and tests reading or toggling that boolean keep working.
render_scene_lighting_mode: Scene_Lighting_Mode = .Lit

// When true, the editor Scene View overrides lighting with flat full-bright ambient
// (`ambient = 1.0`, 0 directional/point/spot lights). Game views ignore this flag.
render_scene_unlit_override: bool

render_set_scene_lighting_mode :: proc(mode: Scene_Lighting_Mode) {
	render_scene_lighting_mode  = mode
	render_scene_unlit_override = (mode == .Unlit)
}

render_effective_scene_lighting_mode :: proc() -> Scene_Lighting_Mode {
	if render_scene_unlit_override do return .Unlit
	if render_scene_lighting_mode == .Unlit do return .Lit
	return render_scene_lighting_mode
}

// Studio fake directional key light used by `Scene_Lighting_Mode.FakeLight`:
// matches the classic angled directional light with real 3-cascade CSM shadows enabled.
render_fake_studio_light :: proc() -> gfx.Light {
	return gfx.Light{
		kind            = .Directional,
		direction       = linalg.normalize([3]f32{-0.5, -1.0, -0.4}),
		color           = {1, 1, 1},
		intensity       = 1.0,
		cast_shadows    = true,
		shadow_strength = 0.65,
		shadow_bias     = 0.0015,
	}
}

// Resolves per-view lighting before draw submission:
//   - Preview views keep their explicit temporary headlight / default light.
//   - SceneView + `unlit_override` forces flat `ambient = 1.0` with 0 lights.
//   - Lit SceneView and Game views use collected scene lights or true pitch black (`ambient = 0.0`) when 0 lights exist.
render_resolve_view_lighting :: proc(kind: View_Kind, scene_light_count: int, scene_ambient: f32, unlit_override: bool) -> (apply_lights: bool, use_count: int, out_ambient: f32) {
	mode: Scene_Lighting_Mode = unlit_override ? .Unlit : .Lit
	apply, count, amb, _ := render_resolve_view_lighting_mode(kind, scene_light_count, scene_ambient, mode)
	return apply, count, amb
}

render_resolve_view_lighting_mode :: proc(kind: View_Kind, scene_light_count: int, scene_ambient: f32, mode: Scene_Lighting_Mode) -> (apply_lights: bool, use_count: int, out_ambient: f32, use_fake_light: bool) {
	if kind == .Preview do return false, 0, 0.0, false
	if kind == .SceneView {
		switch mode {
		case .Lit:
			// Fall through to true scene lighting below.
		case .Unlit:
			return true, 0, 1.0, false
		case .FakeLight:
			return true, 1, 0.35, true
		}
	}
	if scene_light_count > 0 do return true, scene_light_count, scene_ambient, false
	return true, 0, 0.0, false
}

// Enabled Lights drive the pass's lit-shader uniforms; without any, Lit SceneView
// and Game views render true pitch black (0 lights, 0.0 ambient).
_apply_scene_light :: proc(kind: View_Kind) {
	buf: [gfx.MAX_LIGHTS]gfx.Light
	n, ambient := scene_collect_lights(buf[:])
	mode := render_effective_scene_lighting_mode()
	apply, use_n, out_amb, use_fake := render_resolve_view_lighting_mode(kind, n, ambient, mode)
	if !apply do return
	if use_fake {
		buf[0] = render_fake_studio_light()
		gfx.set_lights(buf[:1], out_amb)
	} else if use_n > 0 {
		gfx.set_lights(buf[:use_n], out_amb)
	} else {
		gfx.set_lights(nil, out_amb)
	}
}

@(private = "file")
@(thread_local)
_sort_cam_pos: [3]f32

// Sorts render commands: opaque meshes first (grouped by first material GUID
// and ordered front-to-back by distance squared to reduce overdraw), then quads
// by deterministic back-to-front sort keys.
render_sort_commands :: proc(commands: []Render_Command, cam_pos: [3]f32) {
	_sort_cam_pos = cam_pos
	slice.sort_by(commands, proc(a, b: Render_Command) -> bool {
		am, a_mesh := a.variant.(Draw_Mesh)
		bm, b_mesh := b.variant.(Draw_Mesh)
		if a_mesh != b_mesh do return a_mesh // meshes first
		if a_mesh {
			// Group by first material so same-material runs share binds, then front-to-back.
			ak: u128 = len(am.materials) > 0 ? transmute(u128)am.materials[0] : 0
			bk: u128 = len(bm.materials) > 0 ? transmute(u128)bm.materials[0] : 0
			if ak != bk do return ak < bk
			ap := [3]f32{am.model[0, 3], am.model[1, 3], am.model[2, 3]} - _sort_cam_pos
			bp := [3]f32{bm.model[0, 3], bm.model[1, 3], bm.model[2, 3]} - _sort_cam_pos
			da := ap.x * ap.x + ap.y * ap.y + ap.z * ap.z
			db := bp.x * bp.x + bp.y * bp.y + bp.z * bp.z
			return da < db
		}
		return sort_key_less(a.key, b.key)
	})
}

render_execute :: proc(view: Render_View, commands: []Render_Command) {
	// A command without its owner is a collector's bug: the editor could
	// neither pick nor outline what it draws.
	for c in commands do assert(c.owner != {}, "render_execute: a render command names no owner (its collector must set Render_Command.owner)")
	_apply_scene_light(view.kind)
	render_sort_commands(commands, view.cam_pos)

	gfx.set_view_proj(view.view_proj, view.cam_pos)

	// One resolve per material guid: equal-material quads then share the
	// SAME packed property slice, which is what lets their draws merge in
	// the gfx batch (material compares by pointer).
	Quad_Mat :: struct {
		shader: string,
		color:  [4]f32,
		data:   []u8,
		extra:  []^gfx.Texture, // sampler bindings 1+ (binding 0 is the quad's own texture)
	}
	quad_mats := make(map[Asset_GUID]Quad_Mat, context.temp_allocator)

	for &cmd in commands {
		switch d in cmd.variant {
		case Draw_Quad:
			tex, ok := texture_load(d.texture)
			if !ok do continue
			sm, cached := quad_mats[d.material]
			if !cached {
				shader, _, mcolor, mdata, mextra := _resolve_material(d.material) // material texture ignored: quads use their own
				sm = Quad_Mat{shader = shader, color = mcolor, data = mdata, extra = mextra}
				quad_mats[d.material] = sm
			}
			// Quad facing for lighting shaders (quads are transform-
			// oriented, not billboards).
			normal := linalg.normalize0(linalg.cross(d.corners[1] - d.corners[0], d.corners[3] - d.corners[0]))
			gfx.draw_quad(d.corners, d.uvs, d.color * sm.color, tex.gfx, sm.shader, sm.data, normal, sm.extra)
		case Draw_Mesh:
			mesh, ok := mesh_load(d.mesh, d.part)
			if !ok do continue
			gpu := d.skinned != nil ? d.skinned^ : mesh.gpu
			for sub, i in mesh.submeshes {
				if sub.index_count == 0 do continue
				if d.unlit_heatmap {
					// Weight Heatmap / Inspection mode:
					// Draw unlit with white texture so vertex heat colors (Red = 1.0, Yellow = 0.75, Green = 0.5, Blue = 0.25)
					// display at 100% full, vibrant brightness without being darkened by scene shadows, ambient falloff, or material textures!
					gfx.draw_mesh(gpu, nil, d.model, {1, 1, 1, 1}, "", sub.first_index, sub.index_count, no_shadow = true)
				} else {
					mat_guid: Asset_GUID
					if i < len(d.materials) do mat_guid = d.materials[i]
					shader, gpu_tex, color, mat_data, extra_tex := _resolve_material(mat_guid, .Lit)
					gfx.draw_mesh(gpu, gpu_tex, d.model, color, shader, sub.first_index, sub.index_count, mat_data, extra_tex, no_shadow = d.no_shadow)
				}
			}
			if d.wire_mesh != nil && d.wire_mesh.index_count > 0 && d.wire_color.a > 0.001 {
				gfx.draw_mesh_lines(d.wire_mesh^, d.model, d.wire_color)
			}
		}
	}
	if gfx.command_buffer() != nil {
		gfx.shadow_render_pass(view.cam_pos)
	}
}

// In-app debug drawing (collider wireframes etc): when on, the app loop runs
// the DebugDraw phase (@(phase={key=DebugDraw, mode=App}) subscribers) inside
// the open world pass. Toggled with F3.
debug_draw_enabled: bool

// Renders ALL enabled cameras ascending by Camera.order into `target`
// (nil = swapchain). Begins the pass — cleared by the lowest-order camera's
// clear_color, black when no camera — and LEAVES IT OPEN so the caller can
// draw overlays (demo menu, editor grid) before gfx.pass_end().
// Returns false only when no pass could begin (window minimized).
render_world_cameras :: proc(target: ^gfx.Render_Target = nil) -> bool {
	world := ctx_world()
	cams := make([dynamic]^Camera, 0, 8, context.temp_allocator)
	it := pool_iterator(cameras(world))
	for cam, _ in pool_next(&it) {
		if !cam.enabled do continue
		if !transform_active_in_hierarchy(cam.owner) do continue
		append(&cams, cam)
	}
	slice.sort_by(cams[:], proc(a, b: ^Camera) -> bool {
		return a.order < b.order
	})

	clear_color := [4]f32{0, 0, 0, 1}
	if len(cams) > 0 do clear_color = cams[0].clear_color

	width, height: f32
	if target != nil {
		gfx.pass_begin_target(target, clear_color)
		width, height = f32(target.width), f32(target.height)
	} else {
		if !gfx.pass_begin_swapchain(clear_color) do return false
		ws := gfx.window_size()
		width, height = f32(ws.x), f32(ws.y)
	}
	canvas_set_game_viewport({width, height}) // the canvas tree measures against the game viewport

	for cam in cams {
		view := camera_render_view(cam, width, height)
		commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
		render_collect_commands(view, &commands)
		render_execute(view, commands[:])
	}
	return true
}
