package file_explorer_editor

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import stbi "vendor:stb/image"
import im "haati:external/odin-imgui"
import gfx "haati:engine/gfx"
import wnd "haati:editor/window"
import icons "haati:editor/icons"
import thm "haati:editor/theme"
import inspector "haati:editor/inspector"
import engine "haati:engine"
import file_exp "haati:editor/file_explorer"
import cad_csg "haati:packages/cad_csg"
import widgets "haati:editor/widgets"
import nc "haati:editor/node_canvas"

@(private = "file") _mat_left_pane_w: f32 = 315.0
@(private = "file") _pending_mat_disk_flush: bool = false
@(private = "file") _pending_mat_flush_guid: engine.Asset_GUID = {}

// ─────────────────────────────────────────────────────────────────────────────
// UNIFIED VOID MATERIAL EDITOR (MERGES .MAT INSPECTOR, UNREAL/BLENDER VISUAL
// NODE GRAPH & PHYSICAL CSG / SOFT DEFORMER STUDIO INTO ONE WINDOW!)
// ─────────────────────────────────────────────────────────────────────────────

Mat_Graph_Node_Kind :: enum u8 {
	UV_Panner       = 0,  // Outputs transformed UV coordinates (u, v, 0, 1)
	Texture_Sample  = 1,  // Samples a real .png/.jpg image file from disk (drag & drop from Explorer!)
	Proc_Pattern    = 2,  // Generates a procedural pattern (Brick, Concrete, Glass, Ice, Voronoi, Metal, etc.)
	Color_Constant  = 3,  // Outputs a constant RGBA color
	Scalar_Constant = 4,  // Outputs a constant float (v, v, v, 1)
	Math_Blend      = 5,  // Combines In A, In B, and Factor/Alpha via Multiply/Add/Sub/Div/Lerp/Overlay/Screen/Power/OneMinus
	Channel_Adjust  = 6,  // Swizzles channels (RGBA/R/G/B/A/Invert) + Brightness & Contrast
	Material_Output = 7,  // Master PBR Material Output node (Base Color, Tint, Bump/Normal, Emissive/Halo)
	Named_Param     = 8,  // Named Material Parameter (Float, Bool Switch, Vec2, Vec3, Vec4) synced with .mat `properties`!
	Bump_Offset     = 9,  // Unreal `BumpOffset` (Parallax Depth UV Offset from Height Map + View Angle!)
	Bump_Normal     = 10, // Bump / Normal Map Relief (computes surface normal dH/du, dH/dv & directional bump lighting)
	Fresnel_Halo    = 11, // Fresnel Rim / Halo Edge Glow (`pow(1 - dot(N, V), exp) * halo_color`)
	Comment_Box     = 12, // Resizable group comment box / frame (drags enclosed nodes together!)
}

Mat_Graph_Wire_Style :: enum u8 {
	Electronic_45   = 0, // Unreal Electronic Nodes plugin style: crisp 45° circuit-board / subway lines
	Electric_Jagged = 1, // Jagged electric lightning zig-zag lines
	Smooth_Bezier   = 2, // Classic smooth cubic Bezier curves
}

Mat_Graph_Param_Type :: enum u8 {
	Float_Param = 0, // 1D scalar parameter (.x)
	Bool_Switch = 1, // Boolean parameter (.x >= 0.5); if pins connected, switches between Pin 0 (True) & Pin 1 (False)
	Vec2_Param  = 2, // 2D vector parameter (.xy, e.g. UV scale/offset)
	Vec3_Param  = 3, // 3D vector / RGB parameter (.xyz)
	Vec4_Param  = 4, // 4D vector / RGBA parameter (.xyzw)
}

Mat_Graph_Blend_Op :: enum u8 {
	Multiply  = 0,
	Add       = 1,
	Subtract  = 2,
	Divide    = 3,
	Lerp_Mix  = 4,
	Overlay   = 5,
	Screen    = 6,
	Power     = 7,
	One_Minus = 8,
	Min_Val   = 9,
	Max_Val   = 10,
}

Mat_Graph_Swizzle :: enum u8 {
	RGBA         = 0,
	RGB_No_Alpha = 1, // RGB with Alpha forced to 1.0 (strips packed Alpha mask!)
	RRRR_Mask    = 2,
	GGGG_Mask    = 3,
	BBBB_Mask    = 4,
	AAAA_Mask    = 5,
	Invert_RGB   = 6,
}

Mat_Graph_Node :: struct {
	id:                i32,
	kind:              Mat_Graph_Node_Kind,
	pos:               [2]f32, // Position in unzoomed canvas space
	// Input connections (`in_node_id[pin]` = connected source node ID, `in_src_out_pin[pin]` = source output pin index `0..5`)
	in_node_id:        [4]i32,
	in_src_out_pin:    [4]u8,
	// UV_Panner parameters
	uv_scale:          [2]f32,
	uv_offset:         [2]f32,
	uv_rot_deg:        f32,
	// Texture_Sample parameters + cached CPU RGBA8 buffer for real-time texture math!
	tex_path:          string,
	tex_guid:          engine.Asset_GUID,
	cpu_pixels:        []u8,
	cpu_w, cpu_h:      i32,
	// Proc_Pattern parameters
	proc_pat:          cad_csg.CSG_Proc_Texture_Pattern,
	proc_scale:        f32,
	col_a:             [4]f32,
	col_b:             [4]f32,
	proc_cache:        []u8,
	proc_cache_w:      i32,
	// Scalar / Math / Channel parameters
	scalar_val:        f32,
	blend_op:          Mat_Graph_Blend_Op,
	mix_factor:        f32,
	contrast_pow:      f32,
	brightness:        f32,
	swizzle:           Mat_Graph_Swizzle,
	// Named_Param parameters (synced with `Material.properties` by name!)
	param_type:        Mat_Graph_Param_Type,
	param_name_buf:    [48]u8,
	param_name_len:    int,
	param_bool:        bool,
	// BumpOffset (Unreal Parallax Depth) & Bump_Normal & Fresnel_Halo parameters
	bump_height_ratio: f32,
	bump_ref_plane:    f32,
	bump_view_dir:     [2]f32,
	bump_strength:     f32,
	fresnel_exp:       f32,
	fresnel_base:      f32,
	// Material_Output parameters
	out_shader:        engine.Material_Shader,
	rough_frost:       f32,
	// Comment_Box dimensions in unzoomed canvas units
	comment_size:      [2]f32,
	collapsed:         bool,
}

@(private = "file")
_mat_graph: struct {
	initialized:          bool,
	cv:                   nc.Node_Canvas,
	nodes:                [dynamic]Mat_Graph_Node,
	next_node_id:         i32,
	// Multi-selection & Marquee box drag state
	selected_node_ids:    [dynamic]i32,
	marquee_dragging:     bool,
	marquee_start:        [2]f32,
	marquee_end:          [2]f32,
	wire_style:           Mat_Graph_Wire_Style,
	// Canvas Pan & Mouse-Wheel Zoom state (kept in sync with `cv` for legacy callers)
	pan:                  [2]f32,
	zoom:                 f32,
	// Interactive Bidirectional Wire Dragging state
	wire_dragging:        bool,
	wire_drag_from_input: bool, // false = dragging from Output Pin (`wire_from_node_id`, `wire_from_out_pin`); true = dragging from Input Pin (`wire_to_node_id`, `wire_to_pin_idx`)
	wire_from_node_id:    i32,
	wire_from_out_pin:    int,
	wire_to_node_id:      i32,
	wire_to_pin_idx:      int,
	// Context menu spawn position in canvas coords
	ctx_spawn_pos:        [2]f32,
	// Export & Live Preview state
	export_name:          [64]u8,
	export_len:           int,
	preview_guid:         engine.Asset_GUID,
	preview_dirty:        bool,
	status_buf:           [192]u8,
	status_len:           int,
}

// One-shot per-material folder & asset_db caches to avoid filesystem scans inside the frame loop
@(private = "file") _last_refreshed_mat_buf:    [512]u8
@(private = "file") _last_refreshed_mat_len:    int
@(private = "file") _cached_best_tex_mat_buf:   [512]u8
@(private)          _cached_best_tex_mat_len:   int
@(private = "file") _cached_best_tex_res_buf:   [512]u8
@(private = "file") _cached_best_tex_res_len:   int

@(private = "file")
_set_mat_graph_status :: proc(msg: string) {
	n := min(len(msg), len(_mat_graph.status_buf) - 1)
	if n > 0 {
		copy(_mat_graph.status_buf[:n], msg[:n])
	}
	_mat_graph.status_buf[n] = 0
	_mat_graph.status_len = n
}

_resolve_disk_path_from_db_path :: proc(path: string, alloc := context.temp_allocator) -> string {
	if len(path) == 0 do return ""
	clean_p, _ := filepath.clean(path, alloc)
	norm_p, _  := strings.replace_all(clean_p, "\\", "/", alloc)
	if os.exists(norm_p) do return norm_p
	ws_p := file_exp.resolve_workspace_path(norm_p, alloc)
	if os.exists(ws_p) do return ws_p
	if strings.has_prefix(norm_p, "packages/") {
		after_pkg := strings.trim_prefix(norm_p, "packages/")
		cand_ws := file_exp.resolve_workspace_path(fmt.tprintf("plugins/%s", after_pkg), alloc)
		if os.exists(cand_ws) do return cand_ws
		cand0 := fmt.tprintf("../plugins/%s", after_pkg)
		if os.exists(cand0) do return cand0
		cand1 := fmt.tprintf("plugins/%s", after_pkg)
		if os.exists(cand1) do return cand1
		cand2 := fmt.tprintf("haati/%s", norm_p)
		if os.exists(cand2) do return cand2
		// Check sample package mounts (e.g. `packages/animation_sample/...` -> `plugins/animation/samples/animation_sample/...`)
		for parent_pkg in ([?]string{"animation", "particles"}) {
			cand_sample_ws := file_exp.resolve_workspace_path(fmt.tprintf("plugins/%s/samples/%s", parent_pkg, after_pkg), alloc)
			if os.exists(cand_sample_ws) do return cand_sample_ws
			cand_sample := fmt.tprintf("plugins/%s/samples/%s", parent_pkg, after_pkg)
			if os.exists(cand_sample) do return cand_sample
		}
	}
	return norm_p
}

@(private = "file")
_scan_dir_for_extensions :: proc(dir_path: string, exts: []string, out: ^[dynamic]string, depth: int = 0, max_depth: int = 5, alloc := context.temp_allocator) {
	if depth > max_depth || len(dir_path) == 0 do return
	fd, err := os.open(dir_path)
	if err != nil do return
	defer os.close(fd)

	fis, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil do return

	for fi in fis {
		if strings.has_prefix(fi.name, ".") do continue
		rel_p := fmt.tprintf("%s/%s", dir_path, fi.name)
		norm_p, _ := strings.replace_all(rel_p, "\\", "/", alloc)
		if fi.type == .Directory {
			_scan_dir_for_extensions(norm_p, exts, out, depth + 1, max_depth, alloc)
		} else {
			lo_n := strings.to_lower(fi.name, context.temp_allocator)
			matched := false
			for ext in exts {
				if strings.has_suffix(lo_n, ext) {
					matched = true
					break
				}
			}
			if matched {
				already := false
				for existing in out^ {
					if existing == norm_p {
						already = true
						break
					}
				}
				if !already {
					append(out, norm_p)
				}
			}
		}
	}
}

@(private = "file")
_collect_project_assets_by_ext :: proc(exts: []string, priority_dir := "", fallback_roots: []string, alloc := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 32, alloc)

	if len(engine.asset_db.path_to_guid) > 0 {
		prio_disk := ""
		prio_db   := ""
		if len(priority_dir) > 0 && priority_dir != "." {
			p_clean, _ := filepath.clean(priority_dir, context.temp_allocator)
			p_norm, _ := strings.replace_all(p_clean, "\\", "/", context.temp_allocator)
			prio_disk = strings.to_lower(strings.trim_right(p_norm, "/"), context.temp_allocator)
			prio_db   = strings.to_lower(strings.trim_right(_to_asset_db_path(p_norm, context.temp_allocator), "/"), context.temp_allocator)
		}

		prio_list := make([dynamic]string, 0, 8, context.temp_allocator)
		rest_list := make([dynamic]string, 0, 32, context.temp_allocator)
		for path_key in engine.asset_db.path_to_guid {
			lo_p := strings.to_lower(path_key, context.temp_allocator)
			matched := false
			for ext in exts {
				if strings.has_suffix(lo_p, ext) {
					matched = true
					break
				}
			}
			if !matched do continue

			item_dir_lo := strings.to_lower(strings.trim_right(filepath.dir(path_key), "/\\"), context.temp_allocator)
			in_prio := (len(prio_db) > 0 && item_dir_lo == prio_db) || (len(prio_disk) > 0 && item_dir_lo == prio_disk)
			cloned, _ := strings.clone(path_key, alloc)
			if in_prio {
				append(&prio_list, cloned)
			} else {
				append(&rest_list, cloned)
			}
		}
		if len(prio_list) > 1 do slice.sort(prio_list[:])
		if len(rest_list) > 1 do slice.sort(rest_list[:])
		for s in prio_list do append(&out, s)
		for s in rest_list do append(&out, s)
		return out
	}

	if len(priority_dir) > 0 && priority_dir != "." {
		disk_d := _resolve_disk_path_from_db_path(priority_dir, alloc)
		_scan_dir_for_extensions(disk_d, exts, &out, 0, 2, alloc)
	}
	for r in fallback_roots {
		_scan_dir_for_extensions(r, exts, &out, 0, 5, alloc)
	}
	return out
}

@(private)
_collect_all_project_textures :: proc(priority_dir := "", alloc := context.temp_allocator) -> [dynamic]string {
	exts := [4]string{".png", ".jpg", ".jpeg", ".bmp"}
	roots := [?]string{"assets", engine.engine_file_path("plugins/app/assets", context.temp_allocator)}
	return _collect_project_assets_by_ext(exts[:], priority_dir, roots[:], alloc)
}

@(private = "file")
_collect_all_project_materials :: proc(alloc := context.temp_allocator) -> [dynamic]string {
	exts := [1]string{".mat"}
	roots := [?]string{"assets", engine.engine_file_path("plugins/app/assets", context.temp_allocator)}
	return _collect_project_assets_by_ext(exts[:], "", roots[:], alloc)
}

@(private = "file") _mg_tex_node_search_buf: [128]u8
@(private = "file") _mg_mat_sel_search_buf:  [128]u8
@(private = "file") _mg_conn_tex_search_buf: [128]u8

// Draws an inline filter bar inside a Material Graph combo popup and returns search terms.
@(private = "file")
_mg_combo_search :: proc(buf: []u8, id: cstring, hint: cstring) -> []string {
	appearing := im.IsWindowAppearing()
	if appearing {
		mem.zero(raw_data(buf), len(buf))
	}
	sr := widgets.search_bar(buf, widgets.Search_Bar_Opts{
		id         = id,
		hint       = hint,
		mode       = .Popup,
		width      = 260,
		auto_focus = appearing,
	})
	if sr.escape_close {
		im.CloseCurrentPopup()
	}
	im.Separator()
	return widgets.search_terms(sr.query)
}

@(private = "file")
_find_best_matching_texture_in_folder :: proc(mat_path: string, alloc := context.temp_allocator) -> string {
	disk_mat := _resolve_disk_path_from_db_path(mat_path, alloc)
	mat_dir  := filepath.dir(disk_mat)
	if len(mat_dir) == 0 || mat_dir == "." do return ""

	exts := [4]string{".png", ".jpg", ".jpeg", ".bmp"}
	candidates := make([dynamic]string, 0, 8, alloc)
	_scan_dir_for_extensions(mat_dir, exts[:], &candidates, 0, 1, alloc)
	if len(candidates) == 0 do return ""

	mat_stem := strings.to_lower(strings.trim_suffix(filepath.base(disk_mat), filepath.ext(disk_mat)), alloc)
	// 1. Prefer *albedo*, *basecolor*, *diffuse*, or exact stem match (excluding baked *_graph.png outputs!)
	for c in candidates {
		lo_b := strings.to_lower(filepath.base(c), alloc)
		if strings.has_suffix(lo_b, "_graph.png") do continue
		if strings.contains(lo_b, "albedo") || strings.contains(lo_b, "basecolor") || strings.contains(lo_b, "diffuse") || strings.has_prefix(lo_b, mat_stem) {
			return c
		}
	}
	// 2. Otherwise pick the first non-normal/non-metalRoughness/non-emissive/non-AO/non-graph texture if possible
	for c in candidates {
		lo_b := strings.to_lower(filepath.base(c), alloc)
		if strings.has_suffix(lo_b, "_graph.png") do continue
		if !strings.contains(lo_b, "normal") && !strings.contains(lo_b, "rough") && !strings.contains(lo_b, "metal") && !strings.contains(lo_b, "ao") && !strings.contains(lo_b, "emissive") {
			return c
		}
	}
	return candidates[0]
}

@(private = "file")
_load_node_cpu_texture :: proc(n: ^Mat_Graph_Node, path: string) -> bool {
	if n == nil || len(path) == 0 do return false
	prev_a := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_a

	disk_p := _resolve_disk_path_from_db_path(path, context.temp_allocator)
	clean_p, _ := filepath.clean(disk_p, context.temp_allocator)
	norm_p, _  := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)

	c_path := strings.clone_to_cstring(norm_p, context.temp_allocator)
	w, h, ch: i32
	raw_px := stbi.load(c_path, &w, &h, &ch, 4)
	if raw_px == nil || w <= 0 || h <= 0 {
		return false
	}
	defer stbi.image_free(raw_px)

	if n.cpu_pixels != nil do delete(n.cpu_pixels)
	if len(n.tex_path) > 0 do delete(n.tex_path)
	n.tex_path   = strings.clone(norm_p)
	n.cpu_w      = w
	n.cpu_h      = h
	byte_cnt    := int(w * h * 4)
	n.cpu_pixels = make([]u8, byte_cnt)
	mem.copy(raw_data(n.cpu_pixels), raw_px, byte_cnt)

	engine.asset_db_request_refresh()
	if tid, tok := _lookup_asset_guid_any_path(norm_p); tok {
		n.tex_guid = engine.Asset_GUID(tid)
	}
	_mat_graph.preview_dirty = true
	return true
}

@(private = "file")
_node_param_name :: proc(n: ^Mat_Graph_Node) -> string {
	if n == nil || n.param_name_len <= 0 do return "CustomParam"
	return string(n.param_name_buf[:n.param_name_len])
}

@(private = "file")
_node_param_vec4_value :: proc(n: Mat_Graph_Node) -> [4]f32 {
	switch n.param_type {
	case .Float_Param:
		return {n.scalar_val, 0, 0, 0}
	case .Bool_Switch:
		return {1.0 if n.param_bool else 0.0, 0, 0, 0}
	case .Vec2_Param:
		return {n.col_a.x, n.col_a.y, 0, 0}
	case .Vec3_Param:
		return {n.col_a.x, n.col_a.y, n.col_a.z, 0}
	case .Vec4_Param:
		return n.col_a
	}
	return n.col_a
}

@(private = "file")
_apply_vec4_to_node_param :: proc(n: ^Mat_Graph_Node, v: [4]f32) {
	if n == nil do return
	switch n.param_type {
	case .Float_Param:
		n.scalar_val = v.x
	case .Bool_Switch:
		n.param_bool = v.x >= 0.5
		n.scalar_val = 1.0 if n.param_bool else 0.0
	case .Vec2_Param:
		n.col_a.x = v.x
		n.col_a.y = v.y
	case .Vec3_Param:
		n.col_a.x = v.x
		n.col_a.y = v.y
		n.col_a.z = v.z
	case .Vec4_Param:
		n.col_a = v
	}
}

@(private = "file")
_spawn_mat_graph_node :: proc(kind: Mat_Graph_Node_Kind, pos: [2]f32, tex_path := "", init_param_type := Mat_Graph_Param_Type.Float_Param, init_param_name := "") -> i32 {
	prev_a := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_a

	id := _mat_graph.next_node_id
	_mat_graph.next_node_id += 1

	node := Mat_Graph_Node{
		id                = id,
		kind              = kind,
		pos               = pos,
		uv_scale          = {1.0, 1.0},
		uv_offset         = {0.0, 0.0},
		uv_rot_deg        = 0.0,
		proc_pat          = .Brick_Masonry,
		proc_scale        = 4.0,
		col_a             = {1.0, 1.0, 1.0, 1.0},
		col_b             = {0.90, 0.88, 0.84, 1.0},
		scalar_val        = 1.0,
		blend_op          = .Multiply,
		mix_factor        = 0.50,
		contrast_pow      = 1.0,
		brightness        = 0.0,
		swizzle           = .RGBA,
		param_type        = init_param_type,
		param_bool        = true,
		bump_height_ratio = 0.08,
		bump_ref_plane    = 0.50,
		bump_view_dir     = {0.45, 0.35},
		bump_strength     = 2.50,
		fresnel_exp       = 3.00,
		fresnel_base      = 0.04,
		out_shader        = .Lit,
		rough_frost       = 0.25,
		comment_size      = {360.0, 230.0},
	}
	def_pname := init_param_name
	if len(def_pname) == 0 {
		if kind == .Comment_Box {
			def_pname = "Comment Group"
		} else {
			switch init_param_type {
			case .Float_Param: def_pname = fmt.tprintf("FloatParam_%d", id)
			case .Bool_Switch: def_pname = fmt.tprintf("UseEffect_%d", id)
			case .Vec2_Param:  def_pname = fmt.tprintf("UVParam_%d", id)
			case .Vec3_Param:  def_pname = fmt.tprintf("Vec3Param_%d", id)
			case .Vec4_Param:  def_pname = fmt.tprintf("ColorParam_%d", id)
			}
		}
	}
	node.param_name_len = copy(node.param_name_buf[:], def_pname)

	if kind == .Comment_Box {
		node.col_a = {0.20, 0.36, 0.52, 0.28}
	} else if kind == .Proc_Pattern {
		node.col_a = {0.78, 0.36, 0.28, 1.0}
	} else if kind == .Color_Constant {
		node.col_a = {1.0, 0.82, 0.35, 1.0}
	} else if kind == .Fresnel_Halo {
		node.col_a = {0.22, 0.82, 1.00, 1.0} // Electric cyan rim halo default
	} else if kind == .Named_Param {
		if init_param_type == .Vec2_Param {
			node.col_a = {1.0, 1.0, 0.0, 1.0}
		} else if init_param_type == .Vec3_Param || init_param_type == .Vec4_Param {
			node.col_a = {0.30, 0.85, 1.0, 1.0}
		}
	}
	if kind == .Texture_Sample && len(tex_path) > 0 {
		_ = _load_node_cpu_texture(&node, tex_path)
	}
	append(&_mat_graph.nodes, node)
	_mat_graph.preview_dirty = true
	return id
}

@(private = "file")
_reset_default_mat_graph :: proc() {
	prev_a := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_a

	for &n in _mat_graph.nodes {
		if n.cpu_pixels != nil do delete(n.cpu_pixels)
		if n.proc_cache != nil do delete(n.proc_cache)
		if len(n.tex_path) > 0 do delete(n.tex_path)
	}
	clear(&_mat_graph.nodes)
	clear(&_mat_graph.selected_node_ids)
	_mat_graph.marquee_dragging = false
	_mat_graph.next_node_id = 1
	_mat_graph.pan          = {0, 0}
	_mat_graph.zoom         = 1.0
	_mat_graph.cv.pan       = {0, 0}
	_mat_graph.cv.zoom      = 1.0

	id_uv  := _spawn_mat_graph_node(.UV_Panner,       {16,  50})
	id_tex := _spawn_mat_graph_node(.Texture_Sample,  {225, 25})
	id_out := _spawn_mat_graph_node(.Material_Output, {470, 25})

	// Clean 1:1 Pass-Through Graph: UV Coordinates -> Texture Sample -> Material Output (NO unsolicited red-brick procedural node!)
	if n_tex := _find_mat_node(id_tex); n_tex != nil {
		n_tex.in_node_id[0] = id_uv
		n_tex.col_a         = {1, 1, 1, 1}
	}
	if n_out := _find_mat_node(id_out); n_out != nil {
		n_out.in_node_id[0] = id_tex
		n_out.col_a         = {1, 1, 1, 1}
	}
	_mat_graph.preview_dirty = true
}

@(private = "file")
_sync_mat_graph_to_material :: proc(mat_path: string, mat_val: engine.Material) {
	_ensure_mat_graph_init()

	// Only reset to 3-node default if the graph currently has only the default nodes (preserve custom user graphs when tweaking inspector!)
	has_custom_nodes := len(_mat_graph.nodes) > 3
	if !has_custom_nodes {
		for n in _mat_graph.nodes {
			if n.kind != .UV_Panner && n.kind != .Texture_Sample && n.kind != .Material_Output {
				has_custom_nodes = true
				break
			}
		}
	}
	if !has_custom_nodes {
		_reset_default_mat_graph()
	}

	stem := strings.trim_suffix(filepath.base(mat_path), filepath.ext(mat_path))
	if len(stem) > 0 {
		_mat_graph.export_len = copy(_mat_graph.export_name[:], stem)
	}

	source_tex_guid := mat_val.texture
	tex_disk_path   := ""
	if !engine.asset_guid_is_empty(source_tex_guid) {
		if tp, pok := engine.asset_db_get_path(uuid.Identifier(source_tex_guid)); pok && len(tp) > 0 {
			tex_disk_path = _resolve_disk_path_from_db_path(tp, context.temp_allocator)
		}
	}
	// If `mat_val.texture` points to a previously baked `*_graph.png`, restore the original source albedo texture
	// so the graph never feeds its own baked output back into `Texture_Sample`!
	if strings.has_suffix(strings.to_lower(tex_disk_path, context.temp_allocator), "_graph.png") {
		found_src := false
		for tx in mat_val.textures {
			if tx.name == "_SourceAlbedo" && !engine.asset_guid_is_empty(tx.texture) {
				if tp2, pok2 := engine.asset_db_get_path(uuid.Identifier(tx.texture)); pok2 && len(tp2) > 0 {
					cand_p := _resolve_disk_path_from_db_path(tp2, context.temp_allocator)
					if !strings.has_suffix(strings.to_lower(cand_p, context.temp_allocator), "_graph.png") {
						source_tex_guid = tx.texture
						tex_disk_path   = cand_p
						found_src       = true
						break
					}
				}
			}
		}
		if !found_src {
			best_src := _find_best_matching_texture_in_folder(mat_path, context.temp_allocator)
			if len(best_src) > 0 {
				tex_disk_path = best_src
				if tid, tok := _lookup_asset_guid_any_path(best_src); tok {
					source_tex_guid = engine.Asset_GUID(tid)
				}
			}
		}
	}

	out_id: i32 = 0
	for &n in _mat_graph.nodes {
		if n.kind == .Material_Output {
			out_id = n.id
			n.out_shader = mat_val.shader
			n.col_a      = mat_val.color
		}
	}
	for &n in _mat_graph.nodes {
		if n.kind == .Texture_Sample {
			// Update the primary albedo Texture_Sample node (or the only Texture_Sample node)
			if !has_custom_nodes || (out_id > 0 && _find_mat_node(out_id).in_node_id[0] == n.id) {
				n.col_a = {1, 1, 1, 1}
				if len(tex_disk_path) > 0 && !strings.has_suffix(strings.to_lower(tex_disk_path, context.temp_allocator), "_graph.png") && n.tex_path != tex_disk_path {
					_ = _load_node_cpu_texture(&n, tex_disk_path)
				}
				if !engine.asset_guid_is_empty(source_tex_guid) && !strings.has_suffix(strings.to_lower(tex_disk_path, context.temp_allocator), "_graph.png") {
					n.tex_guid = source_tex_guid
				}
			}
		} else if n.kind == .Named_Param {
			pname := _node_param_name(&n)
			for prop in mat_val.properties {
				if prop.name == pname {
					_apply_vec4_to_node_param(&n, prop.value)
					break
				}
			}
		}
	}
	_mat_graph.preview_dirty = true
}

@(private)
_save_and_preview_connected_material :: proc(mat_path: string, mat_guid: engine.Asset_GUID, mat_val: engine.Material, sync_graph := true, allow_defer := true) {
	disk_p := _resolve_disk_path_from_db_path(mat_path, context.temp_allocator)
	if !engine.asset_guid_is_empty(mat_guid) {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		engine.material_preview(mat_guid, mat_val)
		context.allocator = prev_a
	}
	if sync_graph {
		_sync_mat_graph_to_material(disk_p, mat_val)
	}
	drag_active := allow_defer && im.GetCurrentContext() != nil && (im.IsAnyItemActive() || im.IsMouseDown(.Left))
	if drag_active {
		_pending_mat_disk_flush = true
		_pending_mat_flush_guid = mat_guid
		return
	}
	_pending_mat_disk_flush = false
	if len(disk_p) > 0 {
		_ = engine.material_save_to_file(disk_p, mat_val)
	}
	prev_alloc := context.allocator
	inspector.load_from_file(_to_asset_db_path(disk_p, context.temp_allocator))
	context.allocator = prev_alloc
}

@(private = "file")
_flush_pending_material_disk_write :: proc() {
	if !_pending_mat_disk_flush do return
	if _active_mat_path_len <= 0 {
		_pending_mat_disk_flush = false
		return
	}
	if im.GetCurrentContext() != nil && (im.IsAnyItemActive() || im.IsMouseDown(.Left)) {
		return
	}
	_pending_mat_disk_flush = false
	if !engine.asset_guid_is_empty(_pending_mat_flush_guid) {
		if latest, ok := engine.material_load(_pending_mat_flush_guid); ok && latest != nil {
			active_mat_path := string(_active_mat_path_buf[:_active_mat_path_len])
			_save_and_preview_connected_material(active_mat_path, _pending_mat_flush_guid, latest^, sync_graph = false, allow_defer = false)
		}
	}
}

@(private)
_connect_material_editor_to_mat :: proc(mat_path: string) -> bool {
	if len(mat_path) == 0 do return false
	_ensure_mat_graph_init()

	disk_p := _resolve_disk_path_from_db_path(mat_path, context.temp_allocator)
	clean_p, _ := filepath.clean(disk_p, context.temp_allocator)
	norm_p, _  := strings.replace_all(clean_p, "\\", "/", context.temp_allocator)

	switching_files := string(_active_mat_path_buf[:_active_mat_path_len]) != norm_p
	if switching_files && _pending_mat_disk_flush && !engine.asset_guid_is_empty(_pending_mat_flush_guid) {
		_pending_mat_disk_flush = false
		if latest, ok := engine.material_load(_pending_mat_flush_guid); ok && latest != nil {
			prev_path := string(_active_mat_path_buf[:_active_mat_path_len])
			_save_and_preview_connected_material(prev_path, _pending_mat_flush_guid, latest^, sync_graph = false, allow_defer = false)
		}
	}
	_active_mat_path_len = copy(_active_mat_path_buf[:], norm_p)
	engine.asset_db_request_refresh()

	db_p := _to_asset_db_path(norm_p, context.temp_allocator)
	prev_alloc := context.allocator
	inspector.load_from_file(db_p)
	context.allocator = prev_alloc

	if m_id, m_ok := _lookup_asset_guid_any_path(norm_p); m_ok {
		mat_guid := engine.Asset_GUID(m_id)
		if mat_ptr, l_ok := engine.material_load(mat_guid); l_ok && mat_ptr != nil {
			mat_val := mat_ptr^
			if switching_files {
				_reset_default_mat_graph()
			}
			// Auto-heal missing texture if a matching albedo texture exists in the same folder!
			if engine.asset_guid_is_empty(mat_val.texture) {
				best_tex := _find_best_matching_texture_in_folder(norm_p, context.temp_allocator)
				if len(best_tex) > 0 {
					if tid, tok := _lookup_asset_guid_any_path(best_tex); tok {
						mat_val.texture = engine.Asset_GUID(tid)
						_save_and_preview_connected_material(norm_p, mat_guid, mat_val, sync_graph = true)
						_set_mat_graph_status(fmt.tprintf("Connected to '%s' & auto-linked '%s'!", filepath.base(norm_p), filepath.base(best_tex)))
						return true
					}
				}
			}
			_sync_mat_graph_to_material(norm_p, mat_val)
			_set_mat_graph_status(fmt.tprintf("Connected to '%s'", norm_p))
			return true
		}
	}
	return false
}

@(private = "file")
_try_connect_material_from_selected_3d_object :: proc() -> bool {
	w := engine.ctx_world()
	sel := engine.inspector_active_selection()
	if w == nil || sel == {} || !engine.pool_valid(&w.transforms, engine.Handle(sel)) do return false

	target_guid: engine.Asset_GUID = {}
	if _, vol := engine.transform_get_comp(sel, cad_csg.CSGVolume); vol != nil {
		if !engine.asset_guid_is_empty(vol.faker_material_guid) {
			target_guid = vol.faker_material_guid
		} else if !engine.asset_guid_is_empty(vol.custom_material_guid) {
			target_guid = vol.custom_material_guid
		}
	}
	if engine.asset_guid_is_empty(target_guid) {
		if _, mr := engine.transform_get_comp(sel, engine.MeshRenderer); mr != nil && len(mr.materials) > 0 {
			target_guid = mr.materials[0]
		}
	}
	if !engine.asset_guid_is_empty(target_guid) {
		if mp, pok := engine.asset_db_get_path(uuid.Identifier(target_guid)); pok && len(mp) > 0 {
			return _connect_material_editor_to_mat(mp)
		}
	}
	return false
}

@(private = "file")
_ensure_mat_graph_init :: proc() {
	if _mat_graph.initialized do return
	_mat_graph.initialized = true
	prev_a := context.allocator
	context.allocator = runtime.default_allocator()
	_mat_graph.nodes = make([dynamic]Mat_Graph_Node, 0, 16)
	_mat_graph.selected_node_ids = make([dynamic]i32, 0, 16)
	_mat_graph.wire_style = .Electronic_45
	context.allocator = prev_a

	def_name := "Graph_Custom_Mat"
	_mat_graph.export_len = copy(_mat_graph.export_name[:], def_name)
	_mat_graph.preview_guid = engine.Asset_GUID([16]u8{
		0x4D, 0x41, 0x54, 0x5F, 0x47, 0x52, 0x41, 0x50,
		0x48, 0x5F, 0x50, 0x52, 0x56, 0x00, 0x00, 0x01,
	})
	_reset_default_mat_graph()
}

@(private = "file")
_find_mat_node :: proc(id: i32) -> ^Mat_Graph_Node {
	if id <= 0 do return nil
	for &n in _mat_graph.nodes {
		if n.id == id do return &n
	}
	return nil
}

@(private = "file")
_is_mat_node_selected :: proc(id: i32) -> bool {
	if id <= 0 do return false
	for sid in _mat_graph.selected_node_ids {
		if sid == id do return true
	}
	return false
}

@(private = "file")
_set_mat_node_selected :: proc(id: i32, selected: bool) {
	if id <= 0 do return
	for i := 0; i < len(_mat_graph.selected_node_ids); i += 1 {
		if _mat_graph.selected_node_ids[i] == id {
			if !selected {
				ordered_remove(&_mat_graph.selected_node_ids, i)
			}
			return
		}
	}
	if selected {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		append(&_mat_graph.selected_node_ids, id)
		context.allocator = prev_a
	}
}

@(private = "file")
_spawn_comment_box_for_selection :: proc(fallback_pos: [2]f32) -> i32 {
	pos := fallback_pos
	sz  := [2]f32{360.0, 230.0}
	if len(_mat_graph.selected_node_ids) > 0 {
		bmin := [2]f32{ 1e9,  1e9}
		bmax := [2]f32{-1e9, -1e9}
		found := false
		for sid in _mat_graph.selected_node_ids {
			if sn := _find_mat_node(sid); sn != nil && sn.kind != .Comment_Box {
				found = true
				bmin.x = min(bmin.x, sn.pos.x)
				bmin.y = min(bmin.y, sn.pos.y)
				bmax.x = max(bmax.x, sn.pos.x + 220.0)
				bmax.y = max(bmax.y, sn.pos.y + 180.0)
			}
		}
		if found {
			pos = {bmin.x - 24.0, bmin.y - 42.0}
			sz  = {max((bmax.x - bmin.x) + 48.0, 260.0), max((bmax.y - bmin.y) + 64.0, 170.0)}
		}
	}
	cid := _spawn_mat_graph_node(.Comment_Box, pos, "", .Float_Param, "Comment Group")
	if cn := _find_mat_node(cid); cn != nil {
		cn.comment_size = sz
	}
	return cid
}

// Prevents wiring loops: returns true if `candidate_src_id` is `target_dst_id` or depends on `target_dst_id`.
@(private = "file")
_mat_graph_would_create_cycle :: proc(candidate_src_id, target_dst_id: i32, depth: int = 0) -> bool {
	if candidate_src_id <= 0 || target_dst_id <= 0 || depth > 16 do return false
	if candidate_src_id == target_dst_id do return true
	src_n := _find_mat_node(candidate_src_id)
	if src_n == nil do return false
	for p in 0 ..< 4 {
		up_id := src_n.in_node_id[p]
		if up_id > 0 && _mat_graph_would_create_cycle(up_id, target_dst_id, depth + 1) {
			return true
		}
	}
	return false
}

// Applies multi-channel output pin swizzle (`0 = RGBA`, `1 = RGB (No Alpha, A=1)`, `2 = R`, `3 = G`, `4 = B`, `5 = A`).
@(private = "file")
_apply_out_pin_channel :: proc(c: [4]f32, out_pin: u8) -> [4]f32 {
	switch out_pin {
	case 0: return c
	case 1: return {c.r, c.g, c.b, 1.0}
	case 2: return {c.r, c.r, c.r, 1.0}
	case 3: return {c.g, c.g, c.g, 1.0}
	case 4: return {c.b, c.b, c.b, 1.0}
	case 5: return {c.a, c.a, c.a, 1.0}
	}
	return c
}

@(private = "file")
_wrap_uv_safe :: #force_inline proc "contextless" (v: f32) -> f32 {
	if !(v == v) || v > 1e6 || v < -1e6 do return 0.0
	w := v - math.floor(v)
	return clamp(w, 0.0, 0.999999)
}

// Evaluates any node `node_id` (and specific output pin `out_pin`) at UV coordinates `(u, v)` in `[0..1]`,
// recursively evaluating upstream wired nodes!
@(private = "file")
_eval_graph_node_rgba :: proc(node_id: i32, u, v: f32, depth: int = 0, out_pin: u8 = 0) -> [4]f32 {
	if node_id <= 0 || depth > 10 do return {1, 1, 1, 1}
	n := _find_mat_node(node_id)
	if n == nil do return {1, 1, 1, 1}

	raw_out := [4]f32{1, 1, 1, 1}
	switch n.kind {
	case .UV_Panner:
		base_u, base_v := u, v
		if n.in_node_id[0] > 0 {
			uv_in := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0])
			base_u, base_v = uv_in.r, uv_in.g
		}
		u0 := (base_u - 0.5) * n.uv_scale.x
		v0 := (base_v - 0.5) * n.uv_scale.y
		rad := n.uv_rot_deg * (math.PI / 180.0)
		ca, sa := math.cos(rad), math.sin(rad)
		ru := (u0 * ca - v0 * sa) + 0.5 + n.uv_offset.x
		rv := (u0 * sa + v0 * ca) + 0.5 + n.uv_offset.y
		raw_out = {_wrap_uv_safe(ru), _wrap_uv_safe(rv), 0.0, 1.0}

	case .Texture_Sample:
		su, sv := u, v
		if n.in_node_id[0] > 0 {
			uv_in := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0])
			su, sv = uv_in.r, uv_in.g
		}
		su = _wrap_uv_safe(su * n.uv_scale.x + n.uv_offset.x)
		sv = _wrap_uv_safe(sv * n.uv_scale.y + n.uv_offset.y)
		if n.cpu_pixels != nil && n.cpu_w > 0 && n.cpu_h > 0 {
			px := clamp(int(su * f32(n.cpu_w)), 0, int(n.cpu_w) - 1)
			py := clamp(int(sv * f32(n.cpu_h)), 0, int(n.cpu_h) - 1)
			idx := (py * int(n.cpu_w) + px) * 4
			if idx >= 0 && idx + 3 < len(n.cpu_pixels) {
				raw_out = {
					(f32(n.cpu_pixels[idx + 0]) / 255.0) * n.col_a.r,
					(f32(n.cpu_pixels[idx + 1]) / 255.0) * n.col_a.g,
					(f32(n.cpu_pixels[idx + 2]) / 255.0) * n.col_a.b,
					(f32(n.cpu_pixels[idx + 3]) / 255.0) * n.col_a.a,
				}
			}
		} else {
			// Fallback checker if no image file is loaded yet
			cx := (int(math.floor(su * 8.0)) + int(math.floor(sv * 8.0))) & 1
			c_val: f32 = 0.85 if cx == 0 else 0.35
			raw_out = {c_val * n.col_a.r, c_val * n.col_a.g, c_val * n.col_a.b, n.col_a.a}
		}

	case .Proc_Pattern:
		su, sv := u, v
		if n.in_node_id[0] > 0 {
			uv_in := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0])
			su, sv = uv_in.r, uv_in.g
		}
		if n.proc_cache == nil || n.proc_cache_w != 128 {
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			if n.proc_cache != nil do delete(n.proc_cache)
			params := cad_csg.csg_default_proc_texture_params(n.proc_pat)
			params.width           = 128
			params.height          = 128
			params.primary_color   = n.col_a
			params.secondary_color = n.col_b
			params.scale           = max(n.proc_scale, 0.5)
			n.proc_cache           = cad_csg.csg_generate_procedural_texture_rgba(params, runtime.default_allocator())
			n.proc_cache_w         = 128
			context.allocator = prev_a
		}
		su = _wrap_uv_safe(su)
		sv = _wrap_uv_safe(sv)
		px := clamp(int(su * 128.0), 0, 127)
		py := clamp(int(sv * 128.0), 0, 127)
		idx := (py * 128 + px) * 4
		if idx >= 0 && idx + 3 < len(n.proc_cache) {
			raw_out = {
				f32(n.proc_cache[idx + 0]) / 255.0,
				f32(n.proc_cache[idx + 1]) / 255.0,
				f32(n.proc_cache[idx + 2]) / 255.0,
				f32(n.proc_cache[idx + 3]) / 255.0,
			}
		}

	case .Color_Constant:
		raw_out = n.col_a

	case .Scalar_Constant:
		raw_out = {n.scalar_val, n.scalar_val, n.scalar_val, 1.0}

	case .Named_Param:
		switch n.param_type {
		case .Float_Param:
			raw_out = {n.scalar_val, n.scalar_val, n.scalar_val, 1.0}
		case .Bool_Switch:
			// If either True (Pin 0) or False (Pin 1) input pin is wired, act as an Unreal Switch node!
			if n.in_node_id[0] > 0 || n.in_node_id[1] > 0 {
				if n.param_bool {
					raw_out = _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0]) if n.in_node_id[0] > 0 else n.col_a
				} else {
					raw_out = _eval_graph_node_rgba(n.in_node_id[1], u, v, depth + 1, n.in_src_out_pin[1]) if n.in_node_id[1] > 0 else n.col_b
				}
			} else {
				bval: f32 = 1.0 if n.param_bool else 0.0
				raw_out = {bval, bval, bval, 1.0}
			}
		case .Vec2_Param:
			raw_out = {n.col_a.x, n.col_a.y, 0.0, 1.0}
		case .Vec3_Param:
			raw_out = {n.col_a.x, n.col_a.y, n.col_a.z, 1.0}
		case .Vec4_Param:
			raw_out = n.col_a
		}

	case .Bump_Offset:
		// Unreal Engine `BumpOffset` / Steep Parallax UV Offset node:
		// Shifts UV coordinates along `bump_view_dir` proportional to `(height - bump_ref_plane) * bump_height_ratio`!
		base_u, base_v := u, v
		if n.in_node_id[0] > 0 {
			uv_in := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0])
			base_u, base_v = uv_in.r, uv_in.g
		}
		sample_height :: proc(hm_id: i32, hm_pin: u8, su, sv: f32, d: int) -> f32 {
			if hm_id > 0 {
				c := _eval_graph_node_rgba(hm_id, su - math.floor(su), sv - math.floor(sv), d, hm_pin)
				return c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			}
			// Procedural beveled tile height map fallback if Pin 1 is unconnected
			tu := abs(math.mod(su * 4.0, 1.0) - 0.5) * 2.0
			tv := abs(math.mod(sv * 4.0, 1.0) - 0.5) * 2.0
			return clamp(1.0 - max(tu, tv), 0.0, 1.0)
		}
		// 2-step iterative parallax refinement for authentic angle depth without swimming
		h0 := sample_height(n.in_node_id[1], n.in_src_out_pin[1], base_u, base_v, depth + 1)
		du0 := (h0 - n.bump_ref_plane) * n.bump_height_ratio * n.bump_view_dir.x
		dv0 := (h0 - n.bump_ref_plane) * n.bump_height_ratio * n.bump_view_dir.y
		h1 := sample_height(n.in_node_id[1], n.in_src_out_pin[1], base_u + du0, base_v + dv0, depth + 1)
		h_avg := 0.5 * (h0 + h1)
		pu := base_u + (h_avg - n.bump_ref_plane) * n.bump_height_ratio * n.bump_view_dir.x
		pv := base_v + (h_avg - n.bump_ref_plane) * n.bump_height_ratio * n.bump_view_dir.y
		raw_out = {pu - math.floor(pu), pv - math.floor(pv), h_avg, 1.0}

	case .Bump_Normal:
		// Computes tangent-space surface normal perturbation from a Height/Bump map on Pin 0 (`dH/du`, `dH/dv`)
		eps: f32 = 1.0 / 128.0
		eval_lum :: proc(src_id: i32, src_pin: u8, su, sv: f32, d: int) -> f32 {
			if src_id > 0 {
				c := _eval_graph_node_rgba(src_id, su - math.floor(su), sv - math.floor(sv), d, src_pin)
				return c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			}
			return 0.5 + 0.5 * math.sin(su * math.PI * 8.0) * math.cos(sv * math.PI * 8.0)
		}
		hc := eval_lum(n.in_node_id[0], n.in_src_out_pin[0], u, v, depth + 1)
		hr := eval_lum(n.in_node_id[0], n.in_src_out_pin[0], u + eps, v, depth + 1)
		hu := eval_lum(n.in_node_id[0], n.in_src_out_pin[0], u, v + eps, depth + 1)
		dx := (hr - hc) * n.bump_strength * 20.0
		dy := (hu - hc) * n.bump_strength * 20.0
		inv_l := 1.0 / math.sqrt(dx * dx + dy * dy + 1.0)
		nx := -dx * inv_l
		ny := -dy * inv_l
		nz := 1.0 * inv_l
		// If Pin 1 (Base Color) is connected, apply directional bump relief + specular directly to Base Color!
		if n.in_node_id[1] > 0 {
			base_c := _eval_graph_node_rgba(n.in_node_id[1], u, v, depth + 1, n.in_src_out_pin[1])
			// Key light from top-left-front `{ -0.45, -0.45, 0.77 }`
			ndotl := clamp(nx * (-0.45) + ny * (-0.45) + nz * 0.77, 0.15, 1.35)
			spec  := math.pow(clamp(nz, 0.0, 1.0), 16.0) * 0.18 * clamp(n.bump_strength * 0.3, 0.0, 1.0)
			raw_out = {
				clamp(base_c.r * ndotl + spec, 0.0, 1.0),
				clamp(base_c.g * ndotl + spec, 0.0, 1.0),
				clamp(base_c.b * ndotl + spec, 0.0, 1.0),
				base_c.a,
			}
		} else {
			// Otherwise output standard encoded tangent-space normal `{nx*0.5+0.5, ny*0.5+0.5, nz*0.5+0.5, 1}`
			raw_out = {nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0}
		}

	case .Fresnel_Halo:
		// Fresnel Edge / Rim Halo Glow: `fresnel = base + (1 - base) * pow(1 - max(dot(N, V), 0), exp)`
		// Evaluates over a virtual 3D hemisphere in 2D preview AND perturbs `N` if Pin 0 (Normal/Bump) is wired!
		sx := (u - 0.5) * 2.0
		sy := (v - 0.5) * 2.0
		if n.in_node_id[0] > 0 {
			n_in := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0])
			sx += (n_in.r * 2.0 - 1.0) * 0.35
			sy += (n_in.g * 2.0 - 1.0) * 0.35
		}
		r2 := clamp(sx * sx + sy * sy, 0.0, 1.0)
		ndotv := math.sqrt(max(1.0 - r2, 0.0))
		rim := clamp(n.fresnel_base + (1.0 - n.fresnel_base) * math.pow(clamp(1.0 - ndotv, 0.0, 1.0), max(n.fresnel_exp, 0.1)), 0.0, 1.0)
		halo_rgb := [3]f32{n.col_a.r * rim, n.col_a.g * rim, n.col_a.b * rim}
		if n.in_node_id[1] > 0 {
			base_c := _eval_graph_node_rgba(n.in_node_id[1], u, v, depth + 1, n.in_src_out_pin[1])
			raw_out = {
				clamp(base_c.r + halo_rgb.r * n.col_a.a, 0.0, 1.0),
				clamp(base_c.g + halo_rgb.g * n.col_a.a, 0.0, 1.0),
				clamp(base_c.b + halo_rgb.b * n.col_a.a, 0.0, 1.0),
				base_c.a,
			}
		} else {
			raw_out = {halo_rgb.r, halo_rgb.g, halo_rgb.b, clamp(rim * n.col_a.a, 0.0, 1.0)}
		}

	case .Math_Blend:
		a := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0]) if n.in_node_id[0] > 0 else n.col_a
		b := _eval_graph_node_rgba(n.in_node_id[1], u, v, depth + 1, n.in_src_out_pin[1]) if n.in_node_id[1] > 0 else n.col_b
		t := clamp(n.mix_factor, 0.0, 1.0)
		if n.in_node_id[2] > 0 {
			fac_in := _eval_graph_node_rgba(n.in_node_id[2], u, v, depth + 1, n.in_src_out_pin[2])
			t = clamp(fac_in.r, 0.0, 1.0)
		}
		res: [4]f32
		switch n.blend_op {
		case .Multiply:
			res = {math.lerp(a.r, a.r * b.r, t), math.lerp(a.g, a.g * b.g, t), math.lerp(a.b, a.b * b.b, t), a.a}
		case .Add:
			res = {clamp(a.r + b.r * t, 0, 1), clamp(a.g + b.g * t, 0, 1), clamp(a.b + b.b * t, 0, 1), a.a}
		case .Subtract:
			res = {clamp(a.r - b.r * t, 0, 1), clamp(a.g - b.g * t, 0, 1), clamp(a.b - b.b * t, 0, 1), a.a}
		case .Divide:
			res = {clamp(a.r / max(b.r, 0.01), 0, 1), clamp(a.g / max(b.g, 0.01), 0, 1), clamp(a.b / max(b.b, 0.01), 0, 1), a.a}
		case .Lerp_Mix:
			res = {math.lerp(a.r, b.r, t), math.lerp(a.g, b.g, t), math.lerp(a.b, b.b, t), math.lerp(a.a, b.a, t)}
		case .Overlay:
			ovr := (2.0 * a.r * b.r) if a.r < 0.5 else (1.0 - 2.0 * (1.0 - a.r) * (1.0 - b.r))
			ovg := (2.0 * a.g * b.g) if a.g < 0.5 else (1.0 - 2.0 * (1.0 - a.g) * (1.0 - b.g))
			ovb := (2.0 * a.b * b.b) if a.b < 0.5 else (1.0 - 2.0 * (1.0 - a.b) * (1.0 - b.b))
			res = {math.lerp(a.r, ovr, t), math.lerp(a.g, ovg, t), math.lerp(a.b, ovb, t), a.a}
		case .Screen:
			scr := 1.0 - (1.0 - a.r) * (1.0 - b.r)
			scg := 1.0 - (1.0 - a.g) * (1.0 - b.g)
			scb := 1.0 - (1.0 - a.b) * (1.0 - b.b)
			res = {math.lerp(a.r, scr, t), math.lerp(a.g, scg, t), math.lerp(a.b, scb, t), a.a}
		case .Power:
			pw := max(n.contrast_pow, 0.1)
			res = {math.pow(clamp(a.r, 0, 1), pw), math.pow(clamp(a.g, 0, 1), pw), math.pow(clamp(a.b, 0, 1), pw), a.a}
		case .One_Minus:
			res = {1.0 - a.r, 1.0 - a.g, 1.0 - a.b, a.a}
		case .Min_Val:
			res = {min(a.r, b.r), min(a.g, b.g), min(a.b, b.b), a.a}
		case .Max_Val:
			res = {max(a.r, b.r), max(a.g, b.g), max(a.b, b.b), a.a}
		}
		raw_out = res

	case .Channel_Adjust:
		a := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0]) if n.in_node_id[0] > 0 else [4]f32{1, 1, 1, 1}
		switch n.swizzle {
		case .RGBA:
		case .RGB_No_Alpha: a = {a.r, a.g, a.b, 1.0}
		case .RRRR_Mask:    a = {a.r, a.r, a.r, 1.0}
		case .GGGG_Mask:    a = {a.g, a.g, a.g, 1.0}
		case .BBBB_Mask:    a = {a.b, a.b, a.b, 1.0}
		case .AAAA_Mask:    a = {a.a, a.a, a.a, 1.0}
		case .Invert_RGB:   a = {1.0 - a.r, 1.0 - a.g, 1.0 - a.b, a.a}
		}
		pw := clamp(n.contrast_pow, 0.2, 4.0)
		a.r = clamp(math.pow(clamp(a.r + n.brightness, 0, 1), pw), 0, 1)
		a.g = clamp(math.pow(clamp(a.g + n.brightness, 0, 1), pw), 0, 1)
		a.b = clamp(math.pow(clamp(a.b + n.brightness, 0, 1), pw), 0, 1)
		raw_out = a

	case .Material_Output:
		base_c := _eval_graph_node_rgba(n.in_node_id[0], u, v, depth + 1, n.in_src_out_pin[0]) if n.in_node_id[0] > 0 else [4]f32{0.85, 0.85, 0.85, 1.0}
		tint_c := _eval_graph_node_rgba(n.in_node_id[1], u, v, depth + 1, n.in_src_out_pin[1]) if n.in_node_id[1] > 0 else n.col_a
		out_r := clamp(base_c.r * tint_c.r, 0, 1)
		out_g := clamp(base_c.g * tint_c.g, 0, 1)
		out_b := clamp(base_c.b * tint_c.b, 0, 1)
		out_a := clamp(base_c.a * tint_c.a, 0, 1)
		// Pin 2: Bump / Normal Relief Input
		if n.in_node_id[2] > 0 {
			n_map := _eval_graph_node_rgba(n.in_node_id[2], u, v, depth + 1, n.in_src_out_pin[2])
			nx := n_map.r * 2.0 - 1.0
			ny := n_map.g * 2.0 - 1.0
			nz := max(n_map.b * 2.0 - 1.0, 0.1)
			inv_l := 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
			nx *= inv_l; ny *= inv_l; nz *= inv_l
			ndotl := clamp(nx * (-0.45) + ny * (-0.45) + nz * 0.77, 0.20, 1.35)
			out_r = clamp(out_r * ndotl, 0, 1)
			out_g = clamp(out_g * ndotl, 0, 1)
			out_b = clamp(out_b * ndotl, 0, 1)
		}
		// Pin 3: Emissive / Fresnel Halo Glow Input
		if n.in_node_id[3] > 0 {
			emis_c := _eval_graph_node_rgba(n.in_node_id[3], u, v, depth + 1, n.in_src_out_pin[3])
			out_r = clamp(out_r + emis_c.r * emis_c.a, 0, 1)
			out_g = clamp(out_g + emis_c.g * emis_c.a, 0, 1)
			out_b = clamp(out_b + emis_c.b * emis_c.a, 0, 1)
		}
		raw_out = {out_r, out_g, out_b, out_a}

	case .Comment_Box:
		raw_out = n.col_a
	}
	return _apply_out_pin_channel(raw_out, out_pin)
}

@(private = "file")
_eval_mat_graph_pixels :: proc(width, height: i32, alloc := context.temp_allocator) -> []u8 {
	_ensure_mat_graph_init()
	w := max(width, 16)
	h := max(height, 16)
	out := make([]u8, int(w * h * 4), alloc)

	// Invalidate procedural caches when graph is dirty
	for &n in _mat_graph.nodes {
		if n.kind == .Proc_Pattern && n.proc_cache != nil {
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			delete(n.proc_cache)
			n.proc_cache = nil
			n.proc_cache_w = 0
			context.allocator = prev_a
		}
	}

	out_node_id: i32 = 0
	for n in _mat_graph.nodes {
		if n.kind == .Material_Output {
			out_node_id = n.id
			break
		}
	}

	for py in 0 ..< h {
		v := f32(py) / f32(h)
		for px in 0 ..< w {
			u := f32(px) / f32(w)
			rgba := _eval_graph_node_rgba(out_node_id, u, v, 0)
			d_idx := (int(py) * int(w) + int(px)) * 4
			out[d_idx + 0] = u8(clamp(rgba.r * 255.0, 0, 255))
			out[d_idx + 1] = u8(clamp(rgba.g * 255.0, 0, 255))
			out[d_idx + 2] = u8(clamp(rgba.b * 255.0, 0, 255))
			out[d_idx + 3] = u8(clamp(rgba.a * 255.0, 0, 255))
		}
	}
	return out
}

@(private = "file")
_apply_material_guid_to_selected_scene_object :: proc(mat_guid: engine.Asset_GUID) -> bool {
	if engine.asset_guid_is_empty(mat_guid) do return false
	w := engine.ctx_world()
	sel := engine.inspector_active_selection()
	if w == nil || sel == {} || !engine.pool_valid(&w.transforms, engine.Handle(sel)) do return false

	applied := false
	if _, vol := engine.transform_get_comp(sel, cad_csg.CSGVolume); vol != nil {
		vol.custom_material_guid = mat_guid
		if vol.is_faker_mesh {
			vol.faker_material_guid = mat_guid
		}
		for &b in vol.brushes {
			b.color = {255, 255, 255, 255}
		}
		for &rh in vol.runtime_hulls {
			for &pl in rh.planes {
				pl.color = {255, 255, 255, 255}
			}
		}
		cad_csg.csg_volume_rebuild(vol)
		cad_csg.csg_volume_upload_gpu_now(vol)
		applied = true
	}
	if _, mr := engine.transform_get_comp(sel, engine.MeshRenderer); mr != nil {
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		if len(mr.materials) == 0 {
			append(&mr.materials, mat_guid)
		} else {
			mr.materials[0] = mat_guid
		}
		context.allocator = prev_a
		applied = true
	}
	if applied {
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	return applied
}

@(private = "file")
_draw_add_mat_node_menu_items :: proc(spawn_pos: [2]f32) {
	im.TextDisabled("Textures & Coordinates")
	if im.MenuItem("Texture Sample (.png / .jpg)") {
		_ = _spawn_mat_graph_node(.Texture_Sample, spawn_pos)
	}
	if im.MenuItem("UV Coordinates / Panner") {
		_ = _spawn_mat_graph_node(.UV_Panner, spawn_pos)
	}
	if im.MenuItem("BumpOffset (Unreal Parallax Depth UV Offset)") {
		_ = _spawn_mat_graph_node(.Bump_Offset, spawn_pos)
	}
	if im.MenuItem("Procedural Pattern (Brick, Concrete, Cracks, Glass, Ice)") {
		_ = _spawn_mat_graph_node(.Proc_Pattern, spawn_pos)
	}
	im.Separator()
	im.TextDisabled("3D Surface & Halo Effects")
	if im.MenuItem("Fresnel (Halo / Rim Edge Glow)") {
		_ = _spawn_mat_graph_node(.Fresnel_Halo, spawn_pos)
	}
	if im.MenuItem("Bump / Normal Map (Height-to-Normal Relief)") {
		_ = _spawn_mat_graph_node(.Bump_Normal, spawn_pos)
	}
	im.Separator()
	im.TextDisabled("Named Material Parameters (Synced with .mat)")
	if im.MenuItem("Parameter: Float (Named Scalar)") {
		_ = _spawn_mat_graph_node(.Named_Param, spawn_pos, "", .Float_Param)
	}
	if im.MenuItem("Parameter: Bool / Switch (Named True/False Branch)") {
		_ = _spawn_mat_graph_node(.Named_Param, spawn_pos, "", .Bool_Switch)
	}
	if im.MenuItem("Parameter: Vector2 (Named UV / 2D Value)") {
		_ = _spawn_mat_graph_node(.Named_Param, spawn_pos, "", .Vec2_Param)
	}
	if im.MenuItem("Parameter: Vector3 (Named 3D Vector / RGB)") {
		_ = _spawn_mat_graph_node(.Named_Param, spawn_pos, "", .Vec3_Param)
	}
	if im.MenuItem("Parameter: Vector4 / Color (Named RGBA)") {
		_ = _spawn_mat_graph_node(.Named_Param, spawn_pos, "", .Vec4_Param)
	}
	im.Separator()
	im.TextDisabled("Math, Blending & Constants")
	if im.MenuItem("Math / Blend (Multiply, Add, Lerp, Subtract, Power...)") {
		_ = _spawn_mat_graph_node(.Math_Blend, spawn_pos)
	}
	if im.MenuItem("Channel Mask / Adjust (R, G, B, A, Invert, Contrast)") {
		_ = _spawn_mat_graph_node(.Channel_Adjust, spawn_pos)
	}
	if im.MenuItem("Color / Vector4 Constant") {
		_ = _spawn_mat_graph_node(.Color_Constant, spawn_pos)
	}
	if im.MenuItem("Scalar / Float Constant") {
		_ = _spawn_mat_graph_node(.Scalar_Constant, spawn_pos)
	}
	im.Separator()
	im.TextDisabled("Organization & Comments")
	if im.MenuItem("Comment Box / Group Frame (Shortcut: C)") {
		_ = _spawn_comment_box_for_selection(spawn_pos)
	}
}

@(private = "file")
_sync_graph_named_params_into_material :: proc(mat: ^engine.Material) {
	if mat == nil do return
	prev_a := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_a

	for &n in _mat_graph.nodes {
		if n.kind != .Named_Param do continue
		pname := _node_param_name(&n)
		pval  := _node_param_vec4_value(n)
		found := false
		for &prop in mat.properties {
			if prop.name == pname {
				prop.value = pval
				found = true
				break
			}
		}
		if !found {
			append(&mat.properties, engine.Material_Property{
				name  = strings.clone(pname),
				value = pval,
			})
		}
	}
}

@(private = "file")
_save_mat_graph_to_connected_mat :: proc(force_bake := false) -> bool {
	if _active_mat_path_len <= 0 do return false
	active_mat_path := _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
	if len(active_mat_path) == 0 do return false

	out_node: ^Mat_Graph_Node = nil
	for &n in _mat_graph.nodes {
		if n.kind == .Material_Output {
			out_node = &n
			break
		}
	}
	if out_node == nil do return false

	out_shader := out_node.out_shader
	out_tint   := out_node.col_a

	// Check if the graph is a direct 1:1 Texture_Sample pass-through (no math/procedural/bump/fresnel nodes, channel swizzle, or custom UV tiling)
	is_direct_passthrough := false
	direct_tex_guid: engine.Asset_GUID = {}
	if !force_bake && out_node.in_node_id[1] == 0 && out_node.in_node_id[2] == 0 && out_node.in_node_id[3] == 0 && out_node.in_src_out_pin[0] == 0 {
		if src_n := _find_mat_node(out_node.in_node_id[0]); src_n != nil && src_n.kind == .Texture_Sample {
			uv_default := src_n.uv_scale == {1, 1} && src_n.uv_offset == {0, 0}
			if uv_default && src_n.in_node_id[0] > 0 {
				if uv_n := _find_mat_node(src_n.in_node_id[0]); uv_n != nil && uv_n.kind == .UV_Panner {
					uv_default = uv_n.uv_scale == {1, 1} && uv_n.uv_offset == {0, 0} && abs(uv_n.uv_rot_deg) < 0.01 && uv_n.in_node_id[0] == 0
				} else {
					uv_default = false
				}
			}
			if uv_default {
				is_direct_passthrough = true
				direct_tex_guid = src_n.tex_guid
				out_tint = {
					clamp(out_tint.r * src_n.col_a.r, 0, 1),
					clamp(out_tint.g * src_n.col_a.g, 0, 1),
					clamp(out_tint.b * src_n.col_a.b, 0, 1),
					clamp(out_tint.a * src_n.col_a.a, 0, 1),
				}
			}
		}
	}

	tex_guid_to_save := direct_tex_guid
	if !is_direct_passthrough {
		mat_dir  := filepath.dir(active_mat_path)
		mat_stem := strings.trim_suffix(filepath.base(active_mat_path), filepath.ext(active_mat_path))
		if len(mat_dir) == 0 || mat_dir == "." {
			_ = os.make_directory("assets/textures")
			mat_dir = "assets/textures"
		}
		tex_rel := fmt.tprintf("%s/%s_graph.png", mat_dir, mat_stem)
		if force_bake {
			bake_px := _eval_mat_graph_pixels(256, 256, context.temp_allocator)
			_ = stbi.write_png(strings.clone_to_cstring(tex_rel, context.temp_allocator), 256, 256, 4, raw_data(bake_px), 256 * 4)
			engine.asset_db_request_refresh()
			if tid, tok := _lookup_asset_guid_any_path(tex_rel); tok {
				tex_guid_to_save = engine.Asset_GUID(tid)
				engine.texture_upsert_procedural(tex_guid_to_save, bake_px, 256, 256)
			}
		} else {
			// Fast interactive preview sync (no disk PNG write or Asset DB scan stall on UI thread!)
			if tid, tok := _lookup_asset_guid_any_path(tex_rel); tok {
				tex_guid_to_save = engine.Asset_GUID(tid)
				fast_px := _eval_mat_graph_pixels(128, 128, context.temp_allocator)
				engine.texture_upsert_procedural(tex_guid_to_save, fast_px, 128, 128)
			}
		}
	}

	// Find the primary non-graph source albedo texture GUID so we can preserve it in `_SourceAlbedo`
	source_albedo_guid: engine.Asset_GUID = {}
	for n in _mat_graph.nodes {
		if n.kind == .Texture_Sample && !engine.asset_guid_is_empty(n.tex_guid) {
			if !strings.has_suffix(strings.to_lower(n.tex_path, context.temp_allocator), "_graph.png") {
				source_albedo_guid = n.tex_guid
				break
			}
		}
	}

	if mid, mok := _lookup_asset_guid_any_path(active_mat_path); mok {
		mat_guid := engine.Asset_GUID(mid)
		compiled_mat := engine.Material{
			shader  = out_shader,
			texture = tex_guid_to_save,
			color   = out_tint,
		}
		// Preserve existing properties/custom_shader and sync all `Named_Param` nodes into `compiled_mat.properties`!
		if existing_ptr, eok := engine.material_load(mat_guid); eok && existing_ptr != nil {
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			compiled_mat.custom_shader = existing_ptr.custom_shader
			for prop in existing_ptr.properties {
				append(&compiled_mat.properties, engine.Material_Property{
					name  = strings.clone(prop.name),
					value = prop.value,
				})
			}
			for tx in existing_ptr.textures {
				if tx.name == "_SourceAlbedo" && !engine.asset_guid_is_empty(source_albedo_guid) do continue
				append(&compiled_mat.textures, engine.Material_Texture{
					name    = strings.clone(tx.name),
					texture = tx.texture,
				})
			}
			if !engine.asset_guid_is_empty(source_albedo_guid) {
				append(&compiled_mat.textures, engine.Material_Texture{
					name    = strings.clone("_SourceAlbedo"),
					texture = source_albedo_guid,
				})
			}
			context.allocator = prev_a
		}
		_sync_graph_named_params_into_material(&compiled_mat)
		_save_and_preview_connected_material(active_mat_path, mat_guid, compiled_mat, sync_graph = false, allow_defer = !force_bake)
		_set_mat_graph_status(fmt.tprintf("Saved & updated connected material '%s'!", filepath.base(active_mat_path)))
		return true
	}
	return false
}

// Generates a real GPU fragment shader (`assets/shaders/<MatStem>_graph.glsl`) implementing the graph's
// Named Parameters (`MaterialUBO`), Unreal `BumpOffset` parallax depth, `dFdx/dFdy` Bump/Normal mapping,
// and `Fresnel` rim halo glow!
@(private = "file")
_compile_mat_graph_to_glsl_shader :: proc() -> bool {
	if _active_mat_path_len <= 0 do return false
	active_mat_path := _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
	if len(active_mat_path) == 0 do return false

	mat_stem := strings.trim_suffix(filepath.base(active_mat_path), filepath.ext(active_mat_path))
	if len(mat_stem) == 0 do mat_stem = "CustomMaterial"

	_ = os.make_directory("assets")
	_ = os.make_directory("assets/shaders")
	glsl_path := fmt.tprintf("assets/shaders/%s_graph.glsl", mat_stem)

	has_fresnel     := false
	fresnel_exp     : f32 = 3.0
	fresnel_base    : f32 = 0.04
	fresnel_col     := [4]f32{0.22, 0.82, 1.0, 1.0}
	has_bump_offset := false
	bump_ratio      : f32 = 0.08
	bump_ref        : f32 = 0.50
	has_bump_normal := false
	bump_strength   : f32 = 2.50

	for n in _mat_graph.nodes {
		if n.kind == .Fresnel_Halo {
			has_fresnel  = true
			fresnel_exp  = n.fresnel_exp
			fresnel_base = n.fresnel_base
			fresnel_col  = n.col_a
		} else if n.kind == .Bump_Offset {
			has_bump_offset = true
			bump_ratio      = n.bump_height_ratio
			bump_ref        = n.bump_ref_plane
		} else if n.kind == .Bump_Normal {
			has_bump_normal = true
			bump_strength   = n.bump_strength
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "// Auto-Generated by Haati Material Studio for '%s'\n", filepath.base(active_mat_path))
	fmt.sbprintln(&sb, "#version 450\n")
	fmt.sbprintln(&sb, "layout(location = 0) in vec2 frag_uv;")
	fmt.sbprintln(&sb, "layout(location = 1) in vec4 frag_color;")
	fmt.sbprintln(&sb, "layout(location = 2) in vec3 frag_normal;")
	fmt.sbprintln(&sb, "layout(location = 3) in vec3 frag_world_pos;\n")
	fmt.sbprintln(&sb, "layout(set = 2, binding = 0) uniform sampler2D tex;\n")
	fmt.sbprintln(&sb, "#include \"lighting_common.glsl\"\n")

	fmt.sbprintln(&sb, "layout(set = 3, binding = 1) uniform MaterialUBO {")
	fmt.sbprintln(&sb, "    vec4  u_fresnel_color;")
	fmt.sbprintln(&sb, "    float u_fresnel_exp;")
	fmt.sbprintln(&sb, "    float u_bump_strength;")
	fmt.sbprintln(&sb, "    float u_bump_height_ratio;")
	fmt.sbprintln(&sb, "    float u_bump_ref_plane;")
	for &n in _mat_graph.nodes {
		if n.kind != .Named_Param do continue
		pname := _node_param_name(&n)
		switch n.param_type {
		case .Float_Param, .Bool_Switch:
			fmt.sbprintf(&sb, "    float %s;\n", pname)
		case .Vec2_Param:
			fmt.sbprintf(&sb, "    vec2  %s;\n", pname)
		case .Vec3_Param:
			fmt.sbprintf(&sb, "    vec3  %s;\n", pname)
		case .Vec4_Param:
			fmt.sbprintf(&sb, "    vec4  %s;\n", pname)
		}
	}
	fmt.sbprintln(&sb, "};\n")

	fmt.sbprintln(&sb, "layout(location = 0) out vec4 out_color;\n")
	fmt.sbprintln(&sb, "void main() {")
	fmt.sbprintln(&sb, "    vec3 V = normalize(cam_pos.xyz - frag_world_pos);")
	fmt.sbprintln(&sb, "    vec3 N = normalize(frag_normal);")
	fmt.sbprintln(&sb, "    vec2 uv = frag_uv;")
	if has_bump_offset {
		fmt.sbprintf(&sb, "    float h_sample = dot(texture(tex, uv).rgb, vec3(0.299, 0.587, 0.114));\n")
		fmt.sbprintf(&sb, "    float h_ratio = (abs(u_bump_height_ratio) > 1e-4) ? u_bump_height_ratio : %.4f;\n", bump_ratio)
		fmt.sbprintf(&sb, "    float h_ref   = (u_bump_ref_plane > 1e-4) ? u_bump_ref_plane : %.4f;\n", bump_ref)
		fmt.sbprintln(&sb, "    uv += (h_sample - h_ref) * h_ratio * V.xy;")
	}
	fmt.sbprintln(&sb, "    vec4 base = texture(tex, uv) * frag_color;")
	if has_bump_normal {
		fmt.sbprintf(&sb, "    float b_str = (u_bump_strength > 1e-4) ? u_bump_strength : %.4f;\n", bump_strength)
		fmt.sbprintln(&sb, "    float lum = dot(base.rgb, vec3(0.299, 0.587, 0.114));")
		fmt.sbprintln(&sb, "    vec3 dpdx = dFdx(frag_world_pos);")
		fmt.sbprintln(&sb, "    vec3 dpdy = dFdy(frag_world_pos);")
		fmt.sbprintln(&sb, "    float dhdx = dFdx(lum) * b_str;")
		fmt.sbprintln(&sb, "    float dhdy = dFdy(lum) * b_str;")
		fmt.sbprintln(&sb, "    N = normalize(N - (dpdx * dhdx + dpdy * dhdy) * 8.0);")
	}
	fmt.sbprintln(&sb, "    float ambient = ambient_count.x;")
	fmt.sbprintln(&sb, "    int count = int(ambient_count.y);")
	fmt.sbprintln(&sb, "    bool dir_shadow_used = false;")
	fmt.sbprintln(&sb, "    vec3 light = vec3(ambient);")
	fmt.sbprintln(&sb, "    for (int i = 0; i < count; ++i) {")
	fmt.sbprintln(&sb, "        GpuLight l = lights[i];")
	fmt.sbprintln(&sb, "        vec3 L;")
	fmt.sbprintln(&sb, "        float dist = 0.0;")
	fmt.sbprintln(&sb, "        if (l.pos_type.w < 0.5) {")
	fmt.sbprintln(&sb, "            L = l.dir_range.xyz;")
	fmt.sbprintln(&sb, "        } else {")
	fmt.sbprintln(&sb, "            vec3 d = frag_world_pos - l.pos_type.xyz;")
	fmt.sbprintln(&sb, "            dist = length(d);")
	fmt.sbprintln(&sb, "            L = d / max(dist, 1e-6);")
	fmt.sbprintln(&sb, "        }")
	fmt.sbprintln(&sb, "        float diff = max(dot(N, -L), 0.0);")
	fmt.sbprintln(&sb, "        float atten = light_attenuation(l, L, dist);")
	fmt.sbprintln(&sb, "        if (l.pos_type.w < 0.5 && l.params.y < -1.5 && !dir_shadow_used) {")
	fmt.sbprintln(&sb, "            dir_shadow_used = true;")
	fmt.sbprintln(&sb, "            if (atten > 1e-4 && diff > 0.0) {")
	fmt.sbprintln(&sb, "                float shadow = eval_light_shadow(i, l, frag_world_pos, N, L, diff);")
	fmt.sbprintln(&sb, "                light += l.color_outer.rgb * (diff * atten * shadow);")
	fmt.sbprintln(&sb, "            }")
	fmt.sbprintln(&sb, "            continue;")
	fmt.sbprintln(&sb, "        }")
	fmt.sbprintln(&sb, "        if (atten <= 1e-4 || diff <= 0.0) continue;")
	fmt.sbprintln(&sb, "        float shadow = (l.pos_type.w >= 0.5) ? eval_light_shadow(i, l, frag_world_pos, N, L, diff) : 1.0;")
	fmt.sbprintln(&sb, "        light += l.color_outer.rgb * (diff * atten * shadow);")
	fmt.sbprintln(&sb, "    }")
	fmt.sbprintln(&sb, "    vec3 final_rgb = srgb_to_linear(base.rgb) * light;")
	if has_fresnel {
		fmt.sbprintf(&sb, "    float f_exp = (u_fresnel_exp > 1e-3) ? u_fresnel_exp : %.4f;\n", fresnel_exp)
		fmt.sbprintf(&sb, "    vec3  f_col = (dot(u_fresnel_color.rgb, u_fresnel_color.rgb) > 1e-4) ? u_fresnel_color.rgb : vec3(%.4f, %.4f, %.4f);\n", fresnel_col.r, fresnel_col.g, fresnel_col.b)
		fmt.sbprintf(&sb, "    float rim = %.4f + (1.0 - %.4f) * pow(1.0 - clamp(dot(N, V), 0.0, 1.0), f_exp);\n", fresnel_base, fresnel_base)
		fmt.sbprintln(&sb, "    final_rgb += f_col * rim;")
	}
	fmt.sbprintln(&sb, "    out_color = vec4(final_rgb, base.a);")
	fmt.sbprintln(&sb, "}")

	glsl_src := strings.to_string(sb)
	_ = os.write_entire_file(glsl_path, transmute([]u8)glsl_src)
	engine.asset_db_request_refresh()
	_ = _save_mat_graph_to_connected_mat(force_bake = true)
	_set_mat_graph_status(fmt.tprintf("Generated GPU Shader '%s' & baked material!", glsl_path))
	return true
}

@(private = "file")
_draw_visual_material_node_graph_tab :: proc() {
	_ensure_mat_graph_init()
	_flush_pending_material_disk_write()

	active_mat_path := ""
	if _active_mat_path_len > 0 {
		active_mat_path = string(_active_mat_path_buf[:_active_mat_path_len])
	}

	_, cached := engine.texture_load(_mat_graph.preview_guid)
	if _mat_graph.preview_dirty || !cached {
		_mat_graph.preview_dirty = false
		pixels := _eval_mat_graph_pixels(128, 128, context.temp_allocator)
		engine.texture_upsert_procedural(_mat_graph.preview_guid, pixels, 128, 128)
	}

	// Top Action Bar for the Visual Node Graph
	im.PushStyleColorImVec4(.Button, {0.20, 0.50, 0.78, 0.98})
	if im.Button("+ Add Node...") {
		_mat_graph.ctx_spawn_pos = {240.0 - _mat_graph.cv.pan.x, 120.0 - _mat_graph.cv.pan.y}
		im.OpenPopup("##AddMatNodeTopPopup")
	}
	im.PopStyleColor(1)
	if im.BeginPopup("##AddMatNodeTopPopup") {
		_draw_add_mat_node_menu_items(_mat_graph.ctx_spawn_pos)
		im.EndPopup()
	}

	im.SameLine()
	im.PushStyleColorImVec4(.Button, {0.26, 0.42, 0.56, 0.95})
	if im.SmallButton("+ Comment (C)") {
		_ = _spawn_comment_box_for_selection({200.0 - _mat_graph.cv.pan.x, 90.0 - _mat_graph.cv.pan.y})
	}
	im.PopStyleColor(1)
	if im.IsItemHovered() {
		widgets.tooltip_unchecked("Spawns a resizable Comment Box (wraps currently selected nodes if any!). Dragging a Comment Box moves all nodes inside it.")
	}

	im.SameLine()
	nc.draw_wire_style_combo("##MatWireStyle", 168.0)

	_frame_all_mat_nodes :: proc() {
		if len(_mat_graph.nodes) == 0 do return
		min_p := [2]f32{ 1e9,  1e9}
		max_p := [2]f32{-1e9, -1e9}
		for n in _mat_graph.nodes {
			if n.kind == .Comment_Box do continue
			min_p.x = min(min_p.x, n.pos.x)
			min_p.y = min(min_p.y, n.pos.y)
			max_p.x = max(max_p.x, n.pos.x + 240.0)
			max_p.y = max(max_p.y, n.pos.y + 220.0)
		}
		if min_p.x > max_p.x do return
		span := max_p - min_p
		avail := _mat_graph.cv.size
		if avail.x < 60 do avail.x = 640
		if avail.y < 60 do avail.y = 400
		zx := (avail.x - 80.0) / max(span.x, 120.0)
		zy := (avail.y - 80.0) / max(span.y, 120.0)
		nz := clamp(min(zx, zy), 0.35, 1.35)
		center := (min_p + max_p) * 0.5
		_mat_graph.cv.zoom = nz
		_mat_graph.cv.pan  = (avail * 0.5) / nz - center
	}

	im.SameLine()
	if im.SmallButton("Frame All (F)") {
		_frame_all_mat_nodes()
	}
	im.SameLine()
	if im.SmallButton("Reset View") {
		_mat_graph.cv.pan  = {0, 0}
		_mat_graph.cv.zoom = 1.0
		_mat_graph.pan     = {0, 0}
		_mat_graph.zoom    = 1.0
	}
	im.SameLine()
	if im.SmallButton("Reset Graph") {
		if len(active_mat_path) > 0 {
			_reset_default_mat_graph()
			_ = _connect_material_editor_to_mat(active_mat_path)
		} else {
			_reset_default_mat_graph()
		}
	}
	im.SameLine()
	im.PushStyleColorImVec4(.Button, {0.16, 0.62, 0.36, 0.98})
	if im.Button(fmt.ctprintf("%s  Save / Apply Graph to %s", icons.ICON_MD_SAVE, filepath.base(active_mat_path) if len(active_mat_path) > 0 else ".mat")) {
		_ = _save_mat_graph_to_connected_mat(force_bake = true)
	}
	im.PopStyleColor(1)

	im.SameLine()
	im.PushStyleColorImVec4(.Button, {0.46, 0.28, 0.72, 0.98})
	if im.Button("Compile Graph to .glsl") {
		_ = _compile_mat_graph_to_glsl_shader()
	}
	im.PopStyleColor(1)
	if im.IsItemHovered() {
		widgets.tooltip_unchecked("Generates a real #version 450 fragment shader in assets/shaders/ with MaterialUBO uniforms (Float, Bool, Vec2, Vec3, Vec4), Unreal BumpOffset parallax, Bump/Normal relief, and Fresnel rim halo!")
	}

	_mat_graph.zoom = _mat_graph.cv.zoom > 0 ? _mat_graph.cv.zoom : 1.0
	im.TextDisabledUnformatted(fmt.ctprintf("Zoom: %.0f%%  |  Empty Drag=Box Select  |  F=Frame All  |  C=Comment Box  |  Ctrl+Drag Pin=Move Wire  |  Alt+Click Pin=Disconnect", _mat_graph.zoom * 100.0))

	if _mat_graph.status_len > 0 {
		im.TextColoredUnformatted({0.45, 0.95, 0.65, 1.0}, cstring(&_mat_graph.status_buf[0]))
	}

	// Interactive Node Graph Canvas via Shared `nc.Node_Canvas`
	if !nc.canvas_begin(&_mat_graph.cv, "##MatNodeGraphCanvas") {
		nc.canvas_end(&_mat_graph.cv, nil, 0)
		return
	}
	canvas_p0      := _mat_graph.cv.origin
	canvas_sz      := _mat_graph.cv.size
	dl             := im.GetWindowDrawList()
	io             := im.GetIO()
	canvas_hovered := im.IsWindowHovered(im.HoveredFlags_ChildWindows)
	zm             := _mat_graph.cv.zoom
	_mat_graph.zoom = zm
	_mat_graph.pan  = _mat_graph.cv.pan

	// Helpers to compute screen-space positions of Node Input & Output Pins
	node_screen_pos :: proc(n: Mat_Graph_Node, canvas_p0: im.Vec2) -> im.Vec2 {
		_ = canvas_p0
		return nc.canvas_to_screen(&_mat_graph.cv, {n.pos.x, n.pos.y})
	}
	node_in_pin_count_raw :: proc(n: Mat_Graph_Node) -> int {
		switch n.kind {
		case .UV_Panner:       return 1
		case .Texture_Sample:  return 1
		case .Proc_Pattern:    return 1
		case .Color_Constant:  return 0
		case .Scalar_Constant: return 0
		case .Math_Blend:      return 3
		case .Channel_Adjust:  return 1
		case .Material_Output: return 4
		case .Named_Param:     return 2 if n.param_type == .Bool_Switch else 0
		case .Bump_Offset:     return 2
		case .Bump_Normal:     return 2
		case .Fresnel_Halo:    return 2
		case .Comment_Box:     return 0
		}
		return 1
	}
	node_card_size :: proc(n: Mat_Graph_Node) -> [2]f32 {
		base: [2]f32 = {190, 135}
		switch n.kind {
		case .UV_Panner:       base = {185, 130}
		case .Texture_Sample:  base = {235, 206}
		case .Proc_Pattern:    base = {205, 156}
		case .Color_Constant:  base = {175, 96}
		case .Scalar_Constant: base = {175, 90}
		case .Math_Blend:      base = {205, 158}
		case .Channel_Adjust:  base = {195, 146}
		case .Material_Output: base = {210, 272}
		case .Named_Param:     base = {210, 148}
		case .Bump_Offset:     base = {215, 152}
		case .Bump_Normal:     base = {205, 124}
		case .Fresnel_Halo:    base = {210, 150}
		case .Comment_Box:     return {max(n.comment_size.x, 200.0), max(n.comment_size.y, 120.0)}
		}
		if n.collapsed {
			out_c := 6 if n.kind == .Texture_Sample else (0 if n.kind == .Material_Output else 1)
			in_c  := node_in_pin_count_raw(n)
			max_p := max(in_c, out_c)
			coll_h := max(46.0, 48.0 + f32(max_p) * 30.0)
			return {base.x, min(base.y, coll_h)}
		}
		return base
	}
	node_out_pin_count :: proc(n: Mat_Graph_Node) -> int {
		if n.kind == .Material_Output || n.kind == .Comment_Box do return 0
		if n.kind == .Texture_Sample  do return 6 // 0=RGBA, 1=RGB (No A), 2=R, 3=G, 4=B, 5=A
		return 1
	}
	node_out_pin_label :: proc(n: Mat_Graph_Node, out_idx: int) -> cstring {
		if n.kind == .Texture_Sample {
			switch out_idx {
			case 0: return "RGBA (All)"
			case 1: return "RGB (No Alpha, A=1)"
			case 2: return "R (Red / AO)"
			case 3: return "G (Green / Roughness)"
			case 4: return "B (Blue / Metallic)"
			case 5: return "A (Alpha Mask)"
			}
		}
		return "Output"
	}
	node_out_pin_short_tag :: proc(out_idx: int) -> cstring {
		switch out_idx {
		case 0: return "RGBA"
		case 1: return "RGB"
		case 2: return "R"
		case 3: return "G"
		case 4: return "B"
		case 5: return "A"
		}
		return "Out"
	}
	node_out_pin_color :: proc(n: Mat_Graph_Node, out_idx: int) -> im.Vec4 {
		if n.kind == .Texture_Sample {
			switch out_idx {
			case 0: return {0.95, 0.96, 0.98, 1.0} // RGBA (White)
			case 1: return {0.35, 0.92, 0.98, 1.0} // RGB No A (Cyan)
			case 2: return {0.98, 0.32, 0.32, 1.0} // R (Red)
			case 3: return {0.32, 0.96, 0.42, 1.0} // G (Green)
			case 4: return {0.36, 0.62, 1.00, 1.0} // B (Blue)
			case 5: return {0.78, 0.80, 0.86, 1.0} // A (Gray/Alpha)
			}
		}
		return {0.35, 0.96, 0.55, 1.0}
	}
	node_out_pin_screen :: proc(n: Mat_Graph_Node, out_idx: int, canvas_p0: im.Vec2) -> im.Vec2 {
		sp := node_screen_pos(n, canvas_p0)
		sz := node_card_size(n) * _mat_graph.zoom
		if n.kind == .Texture_Sample {
			y_off: f32 = 38.0 + f32(clamp(out_idx, 0, 5)) * 28.0
			return {sp.x + sz.x, sp.y + y_off * _mat_graph.zoom}
		}
		return {sp.x + sz.x, sp.y + sz.y * 0.5}
	}
	node_in_pin_screen :: proc(n: Mat_Graph_Node, pin_idx: int, canvas_p0: im.Vec2) -> im.Vec2 {
		sp := node_screen_pos(n, canvas_p0)
		y_off: f32 = 46.0 + f32(pin_idx) * 32.0
		return {sp.x, sp.y + y_off * _mat_graph.zoom}
	}
	node_in_pin_count :: proc(n: Mat_Graph_Node) -> int {
		switch n.kind {
		case .UV_Panner:       return 1
		case .Texture_Sample:  return 1
		case .Proc_Pattern:    return 1
		case .Color_Constant:  return 0
		case .Scalar_Constant: return 0
		case .Math_Blend:      return 3
		case .Channel_Adjust:  return 1
		case .Material_Output: return 4
		case .Named_Param:     return 2 if n.param_type == .Bool_Switch else 0
		case .Bump_Offset:     return 2
		case .Bump_Normal:     return 2
		case .Fresnel_Halo:    return 2
		case .Comment_Box:     return 0
		}
		return 1
	}
	node_in_pin_label :: proc(n: Mat_Graph_Node, pin_idx: int) -> cstring {
		switch n.kind {
		case .UV_Panner, .Texture_Sample, .Proc_Pattern:
			return "UV Coords"
		case .Math_Blend:
			if pin_idx == 0 do return "In A"
			if pin_idx == 1 do return "In B"
			return "Factor / Alpha"
		case .Channel_Adjust:
			return "RGBA In"
		case .Material_Output:
			if pin_idx == 0 do return "Base Color (Albedo)"
			if pin_idx == 1 do return "Tint / Multiply"
			if pin_idx == 2 do return "Bump / Normal Relief"
			return "Emissive / Halo Glow"
		case .Named_Param:
			return "True Branch (A)" if pin_idx == 0 else "False Branch (B)"
		case .Bump_Offset:
			return "UV Coords" if pin_idx == 0 else "Height Map (Depth)"
		case .Bump_Normal:
			return "Height / Bump Map" if pin_idx == 0 else "Base Color (Optional)"
		case .Fresnel_Halo:
			return "Normal Perturb" if pin_idx == 0 else "Base Color (Optional)"
		case .Color_Constant, .Scalar_Constant, .Comment_Box:
			return "In"
		}
		return "Input"
	}

	// ═══════════════════════════════════════════════════════════════════════════
	// MAGNETIC PIN HIT-TESTING (PIN CLICK RADIUS + MAGNETIC SNAP RADIUS,
	// BIDIRECTIONAL DRAG, CTRL+DRAG TO MOVE EXISTING WIRE, ALT+CLICK TO DISCONNECT)
	// ═══════════════════════════════════════════════════════════════════════════
	auto_sync_to_mat := false
	pin_click_radius := max(11.5 * zm, 8.5)
	snap_radius      := max(20.0 * zm, 14.0)
	hover_in_node_id : i32 = 0
	hover_in_pin_idx : int = -1
	hover_in_dist2   : f32 = pin_click_radius * pin_click_radius
	hover_out_node_id: i32 = 0
	hover_out_pin_idx: int = 0
	hover_out_dist2  : f32 = pin_click_radius * pin_click_radius

	if canvas_hovered && !im.IsAnyItemActive() {
		for n in _mat_graph.nodes {
			p_cnt := node_in_pin_count(n)
			for pi in 0 ..< p_cnt {
				p_in := node_in_pin_screen(n, pi, canvas_p0)
				dx   := io.MousePos.x - p_in.x
				dy   := io.MousePos.y - p_in.y
				d2   := dx * dx + dy * dy
				if d2 < hover_in_dist2 {
					hover_in_dist2   = d2
					hover_in_node_id = n.id
					hover_in_pin_idx = pi
				}
			}
			out_cnt := node_out_pin_count(n)
			for oi in 0 ..< out_cnt {
				p_out := node_out_pin_screen(n, oi, canvas_p0)
				dx    := io.MousePos.x - p_out.x
				dy    := io.MousePos.y - p_out.y
				d2    := dx * dx + dy * dy
				if d2 < hover_out_dist2 {
					hover_out_dist2   = d2
					hover_out_node_id = n.id
					hover_out_pin_idx = oi
				}
			}
		}
		// If both an input and output pin are within snap_radius, pick whichever is strictly closer to the cursor
		if hover_in_node_id > 0 && hover_out_node_id > 0 {
			if hover_in_dist2 <= hover_out_dist2 {
				hover_out_node_id = 0
			} else {
				hover_in_node_id = 0
				hover_in_pin_idx = -1
			}
		}
	}

	// Handle Pin Click / Alt+Click Disconnect / Ctrl+Drag Move Connection / Start Dragging
	if canvas_hovered && !_mat_graph.wire_dragging {
		if hover_in_node_id > 0 && hover_in_pin_idx >= 0 {
			if hn := _find_mat_node(hover_in_node_id); hn != nil {
				// Tooltip on hovered Input Pin
				p_lbl := node_in_pin_label(hn^, hover_in_pin_idx)
				widgets.tooltip_unchecked(fmt.ctprintf(
					"%s (Pin %d)\n• Drag from or to this pin to connect\n• Ctrl + Drag to move existing wire to another pin\n• Alt + Click (or Right-Click) to disconnect",
					p_lbl, hover_in_pin_idx + 1,
				))
				// Alt + Left-Click OR Right-Click -> Disconnect immediately!
				if im.IsMouseClicked(.Right) || (im.IsMouseClicked(.Left) && io.KeyAlt) {
					hn.in_node_id[hover_in_pin_idx]     = 0
					hn.in_src_out_pin[hover_in_pin_idx] = 0
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
					_set_mat_graph_status(fmt.tprintf("Disconnected %s.", p_lbl))
				} else if im.IsMouseClicked(.Left) {
					if io.KeyCtrl && hn.in_node_id[hover_in_pin_idx] > 0 {
						// Ctrl + Drag on connected Input Pin -> Unplug wire and drag from its original Output Pin!
						orig_src := hn.in_node_id[hover_in_pin_idx]
						orig_out := int(hn.in_src_out_pin[hover_in_pin_idx])
						hn.in_node_id[hover_in_pin_idx]     = 0
						hn.in_src_out_pin[hover_in_pin_idx] = 0
						_mat_graph.wire_dragging            = true
						_mat_graph.wire_drag_from_input     = false
						_mat_graph.wire_from_node_id        = orig_src
						_mat_graph.wire_from_out_pin        = orig_out
						_mat_graph.preview_dirty            = true
						auto_sync_to_mat                    = true
						_set_mat_graph_status("Moving wire connection (drop on any Input pin)...")
					} else {
						// Normal Drag from Input Pin -> Drag backwards to any Output Pin!
						_mat_graph.wire_dragging        = true
						_mat_graph.wire_drag_from_input = true
						_mat_graph.wire_to_node_id      = hn.id
						_mat_graph.wire_to_pin_idx      = hover_in_pin_idx
					}
				}
			}
		} else if hover_out_node_id > 0 {
			if hn := _find_mat_node(hover_out_node_id); hn != nil {
				out_lbl := node_out_pin_label(hn^, hover_out_pin_idx)
				widgets.tooltip_unchecked(fmt.ctprintf(
					"Output Pin: %s\n• Drag to any Input Pin to connect\n• Ctrl + Drag to move outgoing wire to another Output Pin\n• Alt + Click (or Right-Click) to disconnect wires from this pin",
					out_lbl,
				))
				if im.IsMouseClicked(.Right) || (im.IsMouseClicked(.Left) && io.KeyAlt) {
					for &other in _mat_graph.nodes {
						for k in 0 ..< 4 {
							if other.in_node_id[k] == hn.id && int(other.in_src_out_pin[k]) == hover_out_pin_idx {
								other.in_node_id[k]     = 0
								other.in_src_out_pin[k] = 0
							}
						}
					}
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
					_set_mat_graph_status(fmt.tprintf("Disconnected wires from %s.", out_lbl))
				} else if im.IsMouseClicked(.Left) {
					moved_existing := false
					if io.KeyCtrl {
						// Ctrl + Drag on connected Output Pin -> Unplug first connected destination Input pin and move it!
						outer_move: for &other in _mat_graph.nodes {
							for k in 0 ..< 4 {
								if other.in_node_id[k] == hn.id && int(other.in_src_out_pin[k]) == hover_out_pin_idx {
									other.in_node_id[k]              = 0
									other.in_src_out_pin[k]          = 0
									_mat_graph.wire_dragging         = true
									_mat_graph.wire_drag_from_input  = true
									_mat_graph.wire_to_node_id       = other.id
									_mat_graph.wire_to_pin_idx       = k
									_mat_graph.preview_dirty         = true
									auto_sync_to_mat                 = true
									_set_mat_graph_status("Moving wire to a new Output pin...")
									moved_existing                   = true
									break outer_move
								}
							}
						}
					}
					if !moved_existing {
						_mat_graph.wire_dragging        = true
						_mat_graph.wire_drag_from_input = false
						_mat_graph.wire_from_node_id    = hn.id
						_mat_graph.wire_from_out_pin    = hover_out_pin_idx
					}
				}
			}
		}
	}

	// Determine Magnetic Snap Target while dragging a wire!
	snap_target_node_id : i32 = 0
	snap_target_pin_idx : int = -1
	snap_target_pos     : im.Vec2 = io.MousePos
	has_snap_target     := false

	if _mat_graph.wire_dragging {
		if !_mat_graph.wire_drag_from_input {
			// Dragging from Output Pin `(wire_from_node_id, wire_from_out_pin)` -> looking for an Input Pin!
			best_d2 := (snap_radius * 1.35) * (snap_radius * 1.35)
			for n in _mat_graph.nodes {
				if n.id == _mat_graph.wire_from_node_id do continue
				if _mat_graph_would_create_cycle(_mat_graph.wire_from_node_id, n.id) do continue
				p_cnt := node_in_pin_count(n)
				for pi in 0 ..< p_cnt {
					p_in := node_in_pin_screen(n, pi, canvas_p0)
					dx   := io.MousePos.x - p_in.x
					dy   := io.MousePos.y - p_in.y
					d2   := dx * dx + dy * dy
					if d2 < best_d2 {
						best_d2             = d2
						snap_target_node_id = n.id
						snap_target_pin_idx = pi
						snap_target_pos     = p_in
						has_snap_target     = true
					}
				}
			}
			// Fallback: if cursor is inside a compatible node's card body, snap to its nearest Input Pin!
			if !has_snap_target {
				for n in _mat_graph.nodes {
					if n.id == _mat_graph.wire_from_node_id do continue
					if _mat_graph_would_create_cycle(_mat_graph.wire_from_node_id, n.id) do continue
					p_cnt := node_in_pin_count(n)
					if p_cnt <= 0 do continue
					sp  := node_screen_pos(n, canvas_p0)
					bsz := node_card_size(n) * zm
					if io.MousePos.x >= sp.x - 10.0 && io.MousePos.x <= sp.x + bsz.x + 10.0 &&
					   io.MousePos.y >= sp.y && io.MousePos.y <= sp.y + bsz.y {
						best_pi := 0
						best_py := f32(1e9)
						for pi in 0 ..< p_cnt {
							p_in := node_in_pin_screen(n, pi, canvas_p0)
							dy   := abs(io.MousePos.y - p_in.y)
							if dy < best_py {
								best_py = dy
								best_pi = pi
							}
						}
						snap_target_node_id = n.id
						snap_target_pin_idx = best_pi
						snap_target_pos     = node_in_pin_screen(n, best_pi, canvas_p0)
						has_snap_target     = true
						break
					}
				}
			}
		} else {
			// Dragging from Input Pin `(wire_to_node_id, wire_to_pin_idx)` -> looking for an Output Pin!
			best_d2 := (snap_radius * 1.35) * (snap_radius * 1.35)
			for n in _mat_graph.nodes {
				if n.id == _mat_graph.wire_to_node_id || n.kind == .Material_Output do continue
				if _mat_graph_would_create_cycle(n.id, _mat_graph.wire_to_node_id) do continue
				out_cnt := node_out_pin_count(n)
				for oi in 0 ..< out_cnt {
					p_out := node_out_pin_screen(n, oi, canvas_p0)
					dx    := io.MousePos.x - p_out.x
					dy    := io.MousePos.y - p_out.y
					d2    := dx * dx + dy * dy
					if d2 < best_d2 {
						best_d2             = d2
						snap_target_node_id = n.id
						snap_target_pin_idx = oi
						snap_target_pos     = p_out
						has_snap_target     = true
					}
				}
			}
			// Fallback: if cursor is inside a compatible source node's card body, snap to its nearest Output Pin!
			if !has_snap_target {
				for n in _mat_graph.nodes {
					if n.id == _mat_graph.wire_to_node_id || n.kind == .Material_Output do continue
					if _mat_graph_would_create_cycle(n.id, _mat_graph.wire_to_node_id) do continue
					out_cnt := node_out_pin_count(n)
					if out_cnt <= 0 do continue
					sp  := node_screen_pos(n, canvas_p0)
					bsz := node_card_size(n) * zm
					if io.MousePos.x >= sp.x - 10.0 && io.MousePos.x <= sp.x + bsz.x + 10.0 &&
					   io.MousePos.y >= sp.y && io.MousePos.y <= sp.y + bsz.y {
						best_oi := 0
						best_oy := f32(1e9)
						for oi in 0 ..< out_cnt {
							p_out := node_out_pin_screen(n, oi, canvas_p0)
							dy    := abs(io.MousePos.y - p_out.y)
							if dy < best_oy {
								best_oy = dy
								best_oi = oi
							}
						}
						snap_target_node_id = n.id
						snap_target_pin_idx = best_oi
						snap_target_pos     = node_out_pin_screen(n, best_oi, canvas_p0)
						has_snap_target     = true
						break
					}
				}
			}
		}
	}

	// 1b. Draw Comment Boxes FIRST (in the background layer behind wires and shader nodes!)
	delete_node_id: i32 = 0
	any_comment_or_node_active := false

	for &cn in _mat_graph.nodes {
		if cn.kind != .Comment_Box do continue
		im.PushIDInt(cn.id)
		sp    := node_screen_pos(cn, canvas_p0)
		bsz   := node_card_size(cn)
		sz    := im.Vec2{bsz.x * zm, bsz.y * zm}
		hdr_h := 28.0 * zm
		is_sel := _is_mat_node_selected(cn.id)

		nc.canvas_draw_comment_box(dl, sp, {sp.x + sz.x, sp.y + sz.y}, hdr_h, cn.col_a, nil, is_sel, zm)

		// Delete `[X]` button in top-right of Comment Box
		im.SetCursorScreenPos({sp.x + sz.x - 22.0 * zm, sp.y + 4.0 * zm})
		if im.SmallButton("X") {
			delete_node_id = cn.id
		}
		// Color swatch in top-right next to `[X]`
		im.SetCursorScreenPos({sp.x + sz.x - 48.0 * zm, sp.y + 3.0 * zm})
		im.ColorEdit4("##CmtCol", &cn.col_a, {.NoInputs, .NoLabel})

		// Editable Comment Title inside Header
		im.SetCursorScreenPos({sp.x + 8.0 * zm, sp.y + 4.0 * zm})
		im.PushItemWidth(max(sz.x - 120.0 * zm, 70.0))
		if im.InputText("##CmtTitle", cstring(&cn.param_name_buf[0]), len(cn.param_name_buf)) {
			cn.param_name_len = len(strings.trim_right_null(string(cn.param_name_buf[:])))
		}
		im.PopItemWidth()

		// Draggable handle on header bar (to the right of title input) — drags Comment Box AND all enclosed nodes!
		drag_x0 := sp.x + max(sz.x - 108.0 * zm, 80.0)
		im.SetCursorScreenPos({drag_x0, sp.y})
		im.InvisibleButton("##CmtHdrDrag", {max(56.0 * zm, 24.0), hdr_h})
		if im.IsItemHovered() {
			widgets.tooltip_unchecked("Drag here to move Comment Box and all nodes inside it!")
		}
		if im.IsItemClicked(.Left) {
			if io.KeyCtrl || io.KeyShift {
				_set_mat_node_selected(cn.id, !_is_mat_node_selected(cn.id))
			} else if !_is_mat_node_selected(cn.id) {
				clear(&_mat_graph.selected_node_ids)
				_set_mat_node_selected(cn.id, true)
			}
		}
		if !_mat_graph.wire_dragging && im.IsItemActive() {
			any_comment_or_node_active = true
			if im.IsMouseDragging(.Left) {
				dx := io.MouseDelta.x / zm
				dy := io.MouseDelta.y / zm
				old_min := cn.pos
				old_max := cn.pos + bsz
				cn.pos.x += dx
				cn.pos.y += dy
				// Move all nodes whose top-left or center lies inside the Comment Box!
				for &inner in _mat_graph.nodes {
					if inner.id == cn.id do continue
					ic := inner.pos + node_card_size(inner) * 0.5
					if ic.x >= old_min.x && ic.x <= old_max.x && ic.y >= old_min.y && ic.y <= old_max.y {
						inner.pos.x += dx
						inner.pos.y += dy
					}
				}
			}
		}

		// Bottom-right Resize Grip for Comment Box
		grip_sz := 16.0 * zm
		grip_p0 := im.Vec2{sp.x + sz.x - grip_sz, sp.y + sz.y - grip_sz}
		im.SetCursorScreenPos(grip_p0)
		im.InvisibleButton("##CmtResize", {grip_sz, grip_sz})
		if im.IsItemActive() {
			any_comment_or_node_active = true
			if im.IsMouseDragging(.Left) {
				cn.comment_size.x = max(cn.comment_size.x + io.MouseDelta.x / zm, 200.0)
				cn.comment_size.y = max(cn.comment_size.y + io.MouseDelta.y / zm, 120.0)
			}
		}
		im.PopID()
	}

	// 2. Draw Wires for all active Node Connections via Shared Global `node_canvas` Renderer
	draw_wire :: proc(dl: ^im.DrawList, p_out, p_in: im.Vec2, col: im.Vec4, flow: f32 = 0.72) {
		c_u32 := im.ColorConvertFloat4ToU32(col)
		nc.canvas_draw_wire(dl, p_out, p_in, c_u32, nc.global_wire_style, 2.2, flow, _mat_graph.cv.zoom, nil)
	}

	for dst_n in _mat_graph.nodes {
		p_cnt := node_in_pin_count(dst_n)
		for pi in 0 ..< p_cnt {
			src_id  := dst_n.in_node_id[pi]
			src_out := int(dst_n.in_src_out_pin[pi])
			if src_id > 0 {
				if src_n := _find_mat_node(src_id); src_n != nil {
					p_out := node_out_pin_screen(src_n^, src_out, canvas_p0)
					p_in  := node_in_pin_screen(dst_n, pi, canvas_p0)
					w_col := im.Vec4{0.38, 0.86, 1.0, 0.95}
					if src_n.kind == .Texture_Sample && src_out > 0 {
						w_col = node_out_pin_color(src_n^, src_out)
					} else if pi == 1 {
						w_col = {0.98, 0.68, 0.25, 0.95}
					} else if pi == 2 {
						w_col = {0.52, 0.66, 1.00, 0.95}
					} else if pi == 3 {
						w_col = {0.98, 0.42, 0.88, 0.95}
					}
					draw_wire(dl, p_out, p_in, w_col)
				}
			}
		}
	}

	// Draw in-progress dragged wire (snaps visually to `snap_target_pos` when within magnetic radius!)
	if _mat_graph.wire_dragging {
		wire_col := im.Vec4{0.35, 1.0, 0.55, 1.0} if has_snap_target else im.Vec4{1.0, 0.92, 0.28, 1.0}
		if !_mat_graph.wire_drag_from_input {
			if src_n := _find_mat_node(_mat_graph.wire_from_node_id); src_n != nil {
				p_out := node_out_pin_screen(src_n^, _mat_graph.wire_from_out_pin, canvas_p0)
				draw_wire(dl, p_out, snap_target_pos, wire_col)
			}
		} else {
			if dst_n := _find_mat_node(_mat_graph.wire_to_node_id); dst_n != nil {
				p_in := node_in_pin_screen(dst_n^, _mat_graph.wire_to_pin_idx, canvas_p0)
				draw_wire(dl, snap_target_pos, p_in, wire_col)
			}
		}
		if has_snap_target {
			im.DrawList_AddCircle(dl, snap_target_pos, max(11.0 * zm, 8.0), im.ColorConvertFloat4ToU32({0.35, 1.0, 0.55, 1.0}), 0, 2.5)
		}
	}

	// Complete Wire Connection on Mouse Release!
	if _mat_graph.wire_dragging && !im.IsMouseDown(.Left) {
		if has_snap_target && snap_target_node_id > 0 {
			if !_mat_graph.wire_drag_from_input {
				if dst_n := _find_mat_node(snap_target_node_id); dst_n != nil && snap_target_pin_idx >= 0 && snap_target_pin_idx < 4 {
					dst_n.in_node_id[snap_target_pin_idx]     = _mat_graph.wire_from_node_id
					dst_n.in_src_out_pin[snap_target_pin_idx] = u8(clamp(_mat_graph.wire_from_out_pin, 0, 5))
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
					_set_mat_graph_status(fmt.tprintf("Connected to %s!", node_in_pin_label(dst_n^, snap_target_pin_idx)))
				}
			} else {
				if dst_n := _find_mat_node(_mat_graph.wire_to_node_id); dst_n != nil && _mat_graph.wire_to_pin_idx >= 0 && _mat_graph.wire_to_pin_idx < 4 {
					dst_n.in_node_id[_mat_graph.wire_to_pin_idx]     = snap_target_node_id
					dst_n.in_src_out_pin[_mat_graph.wire_to_pin_idx] = u8(clamp(snap_target_pin_idx, 0, 5))
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
					_set_mat_graph_status(fmt.tprintf("Connected %s!", node_in_pin_label(dst_n^, _mat_graph.wire_to_pin_idx)))
				}
			}
		}
		_mat_graph.wire_dragging = false
	}

	pat_names := [9]cstring{
		"Frosted Glass", "Wired Glass", "Sheet Ice", "Pitted Concrete",
		"Brick Masonry", "Brushed Metal", "Voronoi Cracks", "Gradient Ramp", "UV Checker",
	}
	blend_names := [11]cstring{
		"Multiply (A*B)", "Add (A+B)", "Subtract (A-B)", "Divide (A/B)",
		"Lerp / Mix", "Overlay", "Screen", "Power (A^Pow)",
		"OneMinus (1-A)", "Min (A, B)", "Max (A, B)",
	}
	swiz_names := [7]cstring{
		"RGBA (All)", "RGB (No Alpha, A=1)", "RRRR (Red Mask)", "GGGG (Green Mask)",
		"BBBB (Blue Mask)", "AAAA (Alpha Mask)", "Invert (1-RGB)",
	}
	param_type_names := [5]cstring{
		"Float (Scalar)", "Bool / Switch", "Vector2 (XY)", "Vector3 (XYZ)", "Vector4 (RGBA)",
	}

	// 3. Draw Each Node Card, Interactive Pins, and Controls (Niagara Chrome + Zoom-Scaled Typography)
	mat_pal := thm.palette()
	mat_st  := im.GetStyle()
	well_bg_m  := mat_pal.is_light ? thm.lerp_col(mat_pal.bg_canvas, {0, 0, 0, 1}, 0.04) : thm.lerp_col(mat_pal.bg_canvas, {0, 0, 0, 1}, 0.25)
	for &n, n_idx in _mat_graph.nodes {
		if n.kind == .Comment_Box do continue // Already drawn in background layer!
		im.PushIDInt(n.id)
		im.PushFontFloat(nil, clamp(mat_st.FontSizeBase * zm, 8.0, 36.0))
		im.PushStyleVarImVec2(.FramePadding,     {5.0 * zm, 2.5 * zm})
		im.PushStyleVarImVec2(.ItemSpacing,      {5.0 * zm, 3.5 * zm})
		im.PushStyleVarImVec2(.ItemInnerSpacing, {4.0 * zm, 2.5 * zm})
		im.PushStyleVar(.FrameRounding,          3.5 * zm)

		sp  := node_screen_pos(n, canvas_p0)
		bsz := node_card_size(n)
		sz  := im.Vec2{bsz.x * zm, bsz.y * zm}
		hdr_h := 24.0 * zm
		is_sel := _is_mat_node_selected(n.id)

		hdr_col := im.Vec4{0.20, 0.46, 0.68, 1.0}
		title: cstring = "Node"
		switch n.kind {
		case .UV_Panner:       hdr_col = {0.16, 0.48, 0.68, 1.0}; title = "UV Coordinates"
		case .Texture_Sample:  hdr_col = {0.72, 0.38, 0.14, 1.0}; title = "Texture Sample"
		case .Proc_Pattern:    hdr_col = {0.48, 0.26, 0.68, 1.0}; title = "Procedural Pattern"
		case .Color_Constant:  hdr_col = {0.62, 0.52, 0.16, 1.0}; title = "Color Constant"
		case .Scalar_Constant: hdr_col = {0.36, 0.52, 0.62, 1.0}; title = "Scalar Constant"
		case .Math_Blend:      hdr_col = {0.20, 0.58, 0.44, 1.0}; title = "Math / Blend"
		case .Channel_Adjust:  hdr_col = {0.58, 0.26, 0.48, 1.0}; title = "Channel / Contrast"
		case .Material_Output: hdr_col = {0.18, 0.62, 0.28, 1.0}; title = "Material Output"
		case .Named_Param:     hdr_col = {0.22, 0.56, 0.66, 1.0}; title = "Named Parameter"
		case .Bump_Offset:     hdr_col = {0.66, 0.30, 0.42, 1.0}; title = "BumpOffset (Parallax)"
		case .Bump_Normal:     hdr_col = {0.34, 0.42, 0.76, 1.0}; title = "Bump / Normal Map"
		case .Fresnel_Halo:    hdr_col = {0.14, 0.64, 0.78, 1.0}; title = "Fresnel (Halo Rim)"
		case .Comment_Box:     hdr_col = {0.24, 0.40, 0.56, 1.0}; title = "Comment"
		}

		well_hov_m := thm.lerp_col(well_bg_m, hdr_col, 0.22)
		well_act_m := thm.lerp_col(well_bg_m, hdr_col, 0.34)
		im.PushStyleColorImVec4(.FrameBg,        well_bg_m)
		im.PushStyleColorImVec4(.FrameBgHovered, well_hov_m)
		im.PushStyleColorImVec4(.FrameBgActive,  well_act_m)

		// Draggable Node Header evaluated BEFORE drawing card chrome so card, title, and pins share exact same-frame `sp`!
		right_btn_pad := 24.0 * zm if n.kind == .Material_Output else 44.0 * zm
		hdr_drag_w := max(sz.x - right_btn_pad, 20.0)
		im.SetCursorScreenPos(sp)
		im.InvisibleButton("##HdrDrag", {hdr_drag_w, hdr_h})
		if im.IsItemClicked(.Left) {
			if io.KeyCtrl || io.KeyShift {
				_set_mat_node_selected(n.id, !_is_mat_node_selected(n.id))
			} else if !_is_mat_node_selected(n.id) {
				clear(&_mat_graph.selected_node_ids)
				_set_mat_node_selected(n.id, true)
			}
			is_sel = _is_mat_node_selected(n.id)
		}
		if !_mat_graph.wire_dragging && im.IsItemActive() {
			any_comment_or_node_active = true
			if im.IsMouseDragging(.Left) {
				dx := io.MouseDelta.x / zm
				dy := io.MouseDelta.y / zm
				if _is_mat_node_selected(n.id) && len(_mat_graph.selected_node_ids) > 1 {
					for sid in _mat_graph.selected_node_ids {
						if sn := _find_mat_node(sid); sn != nil {
							sn.pos.x += dx
							sn.pos.y += dy
						}
					}
				} else {
					n.pos.x += dx
					n.pos.y += dy
				}
				sp = node_screen_pos(n, canvas_p0)
			}
		}

		// Unified Node Card Chrome behind foreground text, buttons & widgets
		is_card_hov := io.MousePos.x >= sp.x && io.MousePos.x <= sp.x + sz.x && io.MousePos.y >= sp.y && io.MousePos.y <= sp.y + sz.y
		nc.canvas_draw_node_chrome(dl, sp, {sp.x + sz.x, sp.y + sz.y}, hdr_h, 0.0, hdr_col, is_sel, is_card_hov, true, zm)
		im.DrawList_AddText(dl, {sp.x + 8.0 * zm, sp.y + 4.0 * zm}, im.ColorConvertFloat4ToU32({0.96, 0.97, 0.99, 1.0}), title)

		// Collapse chevron (`v`/`>`) + Delete `[X]` button in top-right
		coll_x := sp.x + sz.x - (22.0 * zm if n.kind == .Material_Output else 42.0 * zm)
		im.SetCursorScreenPos({coll_x, sp.y + 3.0 * zm})
		if im.InvisibleButton("##MatColl", {18.0 * zm, 18.0 * zm}) {
			n.collapsed = !n.collapsed
		}
		chev_ic := n.collapsed ? cstring(icons.ICON_MD_CHEVRON_RIGHT) : cstring(icons.ICON_MD_EXPAND_MORE)
		im.DrawList_AddText(dl, {coll_x + 3.0 * zm, sp.y + 4.0 * zm}, im.GetColorU32ImVec4(mat_pal.text_secondary), chev_ic)

		if n.kind != .Material_Output {
			im.SetCursorScreenPos({sp.x + sz.x - 22.0 * zm, sp.y + 2.0 * zm})
			if im.SmallButton("X") {
				delete_node_id = n.id
			}
		}

		// Draw Input Pins (Left Edge) via Shared `node_canvas` Port Renderer
		p_cnt := node_in_pin_count(n)
		pin_r := max(6.5 * zm, 5.0)
		for pi in 0 ..< p_cnt {
			p_in     := node_in_pin_screen(n, pi, canvas_p0)
			has_conn := n.in_node_id[pi] > 0
			is_hov   := (hover_in_node_id == n.id && hover_in_pin_idx == pi)
			is_mag   := (has_snap_target && !_mat_graph.wire_drag_from_input && snap_target_node_id == n.id && snap_target_pin_idx == pi)
			p_col    := im.Vec4{0.38, 0.88, 1.0, 1.0} if has_conn else im.Vec4{0.58, 0.66, 0.78, 0.95}
			nc.canvas_draw_port(dl, p_in, p_col, is_hov, is_mag, has_conn, zm)
		}

		// Draw Output Pin(s) (Right Edge) — `Texture_Sample` has 6 multi-channel pins (`RGBA`, `RGB`, `R`, `G`, `B`, `A`)!
		out_cnt := node_out_pin_count(n)
		for oi in 0 ..< out_cnt {
			p_out  := node_out_pin_screen(n, oi, canvas_p0)
			is_hov := (hover_out_node_id == n.id && hover_out_pin_idx == oi)
			is_mag := (has_snap_target && _mat_graph.wire_drag_from_input && snap_target_node_id == n.id && snap_target_pin_idx == oi)
			o_col  := node_out_pin_color(n, oi)
			nc.canvas_draw_port(dl, p_out, o_col, is_hov, is_mag, true, zm)
			if n.kind == .Texture_Sample {
				tag := node_out_pin_short_tag(oi)
				tsz := im.CalcTextSize(tag)
				im.DrawList_AddText(dl, {p_out.x - tsz.x - pin_r - 4.0 * zm, p_out.y - tsz.y * 0.5}, im.ColorConvertFloat4ToU32(o_col), tag)
			}
		}

		// Node Body Controls (hidden when collapsed, keeping pins & wires anchored!)
		if !n.collapsed {
			im.SetCursorScreenPos({sp.x + 18.0 * zm, sp.y + hdr_h + 6.0 * zm})
			im.BeginGroup()
			right_pad: f32 = 92.0 if n.kind == .Texture_Sample else 70.0
			item_w := max((bsz.x - right_pad) * zm, 60.0)
			im.PushItemWidth(item_w)
			prev_dirty_before_node := _mat_graph.preview_dirty

		switch n.kind {
		case .UV_Panner:
			if im.DragFloat2("Tile", &n.uv_scale, 0.05, 0.1, 32.0, "%.2f") do _mat_graph.preview_dirty = true
			if im.DragFloat2("Pan",  &n.uv_offset, 0.02, -4.0, 4.0, "%.2f") do _mat_graph.preview_dirty = true
			if im.SliderFloat("Rot", &n.uv_rot_deg, -180.0, 180.0, "%.0f°") do _mat_graph.preview_dirty = true

		case .Texture_Sample:
			tex_lbl: cstring = "[Drop .png/.jpg Here]"
			if len(n.tex_path) > 0 {
				tex_lbl = strings.clone_to_cstring(filepath.base(n.tex_path), context.temp_allocator)
			}
			if im.BeginCombo("Tex", tex_lbl) {
				terms := _mg_combo_search(_mg_tex_node_search_buf[:], "##MgTexNodeSearch", "Search textures...")
				all_texs := _collect_all_project_textures(filepath.dir(active_mat_path), context.temp_allocator)
				for rel_t in all_texs {
					if len(terms) > 0 && !widgets.search_match(rel_t, terms) do continue
					disp_lbl := fmt.ctprintf("%s  (%s)", filepath.base(rel_t), filepath.dir(rel_t))
					if im.Selectable(disp_lbl, n.tex_path == rel_t) {
						if _load_node_cpu_texture(&n, rel_t) {
							auto_sync_to_mat = true
						}
					}
				}
				im.EndCombo()
			}
			if im.BeginDragDropTarget() {
				if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
					dropped_p := strings.trim_right_null(string(([^]u8)(payload.Data)[:payload.DataSize]))
					if _load_node_cpu_texture(&n, dropped_p) {
						auto_sync_to_mat = true
					}
				}
				im.EndDragDropTarget()
			}
			if im.DragFloat2("Tile", &n.uv_scale, 0.05, 0.1, 32.0, "%.2f") do _mat_graph.preview_dirty = true
			if im.ColorEdit4("Tint", &n.col_a, {.NoInputs}) {
				_mat_graph.preview_dirty = true
				auto_sync_to_mat = true
			}
			if !engine.asset_guid_is_empty(n.tex_guid) {
				if t_obj, tok := engine.texture_load(n.tex_guid); tok && t_obj != nil && t_obj.gfx != nil && t_obj.gfx.gpu != nil {
					im.SameLine()
					tid := im.TextureID(uintptr(gfx.texture_imgui_id(t_obj.gfx)))
					im.Image(im.TextureRef{_TexID = tid}, {54 * zm, 54 * zm})
				}
			}

		case .Proc_Pattern:
			pi := clamp(i32(n.proc_pat), 0, 8)
			if im.ComboChar("Pat", &pi, raw_data(pat_names[:]), 9) {
				n.proc_pat = cad_csg.CSG_Proc_Texture_Pattern(pi)
				_mat_graph.preview_dirty = true
			}
			if im.SliderFloat("Scale", &n.proc_scale, 0.5, 16.0, "%.1f") do _mat_graph.preview_dirty = true
			if im.ColorEdit4("Col A", &n.col_a, {.NoInputs}) do _mat_graph.preview_dirty = true
			im.SameLine()
			if im.ColorEdit4("Col B", &n.col_b, {.NoInputs}) do _mat_graph.preview_dirty = true

		case .Color_Constant:
			if im.ColorEdit4("Color", &n.col_a) do _mat_graph.preview_dirty = true

		case .Scalar_Constant:
			if im.SliderFloat("Val", &n.scalar_val, -2.0, 4.0, "%.2f") do _mat_graph.preview_dirty = true

		case .Named_Param:
			pt_i := clamp(i32(n.param_type), 0, 4)
			if im.ComboChar("Type", &pt_i, raw_data(param_type_names[:]), 5) {
				n.param_type             = Mat_Graph_Param_Type(pt_i)
				_mat_graph.preview_dirty = true
				auto_sync_to_mat         = true
			}
			if im.InputText("Name", cstring(&n.param_name_buf[0]), len(n.param_name_buf)) {
				n.param_name_len         = len(strings.trim_right_null(string(n.param_name_buf[:])))
				_mat_graph.preview_dirty = true
				auto_sync_to_mat         = true
			}
			switch n.param_type {
			case .Float_Param:
				if im.SliderFloat("Val", &n.scalar_val, -2.0, 4.0, "%.2f") {
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
				}
			case .Bool_Switch:
				if im.Checkbox("Active (Pin1 / Pin2)", &n.param_bool) {
					n.scalar_val             = 1.0 if n.param_bool else 0.0
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
				}
			case .Vec2_Param:
				v2 := [2]f32{n.col_a.x, n.col_a.y}
				if im.DragFloat2("XY", &v2, 0.02, -16.0, 16.0, "%.2f") {
					n.col_a.x                = v2.x
					n.col_a.y                = v2.y
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
				}
			case .Vec3_Param:
				v3 := [3]f32{n.col_a.x, n.col_a.y, n.col_a.z}
				if im.DragFloat3("XYZ", &v3, 0.02, -16.0, 16.0, "%.2f") {
					n.col_a.x                = v3.x
					n.col_a.y                = v3.y
					n.col_a.z                = v3.z
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
				}
			case .Vec4_Param:
				if im.ColorEdit4("RGBA", &n.col_a) {
					_mat_graph.preview_dirty = true
					auto_sync_to_mat         = true
				}
			}

		case .Bump_Offset:
			if im.SliderFloat("Depth", &n.bump_height_ratio, -0.25, 0.25, "%.3f") do _mat_graph.preview_dirty = true
			if im.SliderFloat("RefPl", &n.bump_ref_plane, 0.0, 1.0, "%.2f") do _mat_graph.preview_dirty = true
			if im.DragFloat2("ViewXY", &n.bump_view_dir, 0.02, -1.5, 1.5, "%.2f") do _mat_graph.preview_dirty = true
			im.TextDisabled("Pin1: UV  |  Pin2: HeightMap")

		case .Bump_Normal:
			if im.SliderFloat("BumpStr", &n.bump_strength, 0.0, 8.0, "%.2f") do _mat_graph.preview_dirty = true
			im.TextDisabled("Pin1: Height  |  Pin2: Albedo")

		case .Fresnel_Halo:
			if im.SliderFloat("Power", &n.fresnel_exp, 0.2, 10.0, "%.2f") do _mat_graph.preview_dirty = true
			if im.SliderFloat("Base",  &n.fresnel_base, 0.0, 0.5, "%.2f") do _mat_graph.preview_dirty = true
			if im.ColorEdit4("HaloCol", &n.col_a, {.NoInputs}) do _mat_graph.preview_dirty = true
			im.SameLine()
			im.TextDisabled("Rim Glow")

		case .Math_Blend:
			bi := clamp(i32(n.blend_op), 0, 10)
			if im.ComboChar("Op", &bi, raw_data(blend_names[:]), 11) {
				n.blend_op = Mat_Graph_Blend_Op(bi)
				_mat_graph.preview_dirty = true
			}
			if n.blend_op == .Power {
				if im.SliderFloat("Exp", &n.contrast_pow, 0.2, 4.0, "%.2f") do _mat_graph.preview_dirty = true
			} else if n.in_node_id[2] == 0 {
				if im.SliderFloat("Mix", &n.mix_factor, 0.0, 1.0, "%.2f") do _mat_graph.preview_dirty = true
			} else {
				im.TextDisabled("Factor: Driven by Pin 3")
			}
			if n.in_node_id[0] == 0 {
				if im.ColorEdit4("Def A", &n.col_a, {.NoInputs}) do _mat_graph.preview_dirty = true
				im.SameLine()
			}
			if n.in_node_id[1] == 0 {
				if im.ColorEdit4("Def B", &n.col_b, {.NoInputs}) do _mat_graph.preview_dirty = true
			}

		case .Channel_Adjust:
			si := clamp(i32(n.swizzle), 0, 6)
			if im.ComboChar("Mask", &si, raw_data(swiz_names[:]), 7) {
				n.swizzle = Mat_Graph_Swizzle(si)
				_mat_graph.preview_dirty = true
			}
			if im.SliderFloat("Bright", &n.brightness, -0.8, 0.8, "%.2f") do _mat_graph.preview_dirty = true
			if im.SliderFloat("Contr",  &n.contrast_pow, 0.25, 3.5, "%.2f") do _mat_graph.preview_dirty = true

		case .Material_Output:
			sh_names := [2]cstring{"Unlit", "Lit (Shadows)"}
			sh_i := clamp(i32(n.out_shader), 0, 1)
			if im.ComboChar("Shd", &sh_i, raw_data(sh_names[:]), 2) {
				n.out_shader = engine.Material_Shader(sh_i)
				auto_sync_to_mat = true
			}
			if n.in_node_id[1] == 0 {
				if im.ColorEdit4("Tint", &n.col_a, {.NoInputs}) {
					_mat_graph.preview_dirty = true
					auto_sync_to_mat = true
				}
				im.SameLine()
			}
			im.TextDisabled("P1:Col P2:Tint P3:Bump P4:Halo")
			if tex_obj, tok := engine.texture_load(_mat_graph.preview_guid); tok && tex_obj != nil && tex_obj.gfx != nil && tex_obj.gfx.gpu != nil {
				tid := im.TextureID(uintptr(gfx.texture_imgui_id(tex_obj.gfx)))
				im.Image(im.TextureRef{_TexID = tid}, {132 * zm, 132 * zm})
			}
		case .Comment_Box:
		}

		if (_mat_graph.preview_dirty && !prev_dirty_before_node && !im.IsMouseDown(.Left)) || im.IsItemDeactivatedAfterEdit() {
			auto_sync_to_mat = true
		}

		im.PopItemWidth()
		im.EndGroup()
		} // end if !n.collapsed
		im.PopStyleColor(3)
		im.PopStyleVar(4)
		im.PopFont()
		im.PopID()
		_ = n_idx
	}

	// 4. Marquee Box Drag Selection & Keyboard Shortcuts (`F` = Frame All, `C` = Comment Box, `Delete`/`Backspace` = Delete Selected)
	if canvas_hovered && !_mat_graph.wire_dragging && !any_comment_or_node_active && hover_in_node_id == 0 && hover_out_node_id == 0 && !im.IsAnyItemHovered() && !im.IsAnyItemActive() {
		if im.IsMouseClicked(.Left) {
			if !io.KeyCtrl && !io.KeyShift {
				clear(&_mat_graph.selected_node_ids)
			}
			_mat_graph.marquee_dragging = true
			_mat_graph.marquee_start    = {io.MousePos.x, io.MousePos.y}
			_mat_graph.marquee_end      = {io.MousePos.x, io.MousePos.y}
		}
	}
	if _mat_graph.marquee_dragging {
		_mat_graph.marquee_end = {io.MousePos.x, io.MousePos.y}
		m_min := im.Vec2{min(_mat_graph.marquee_start.x, _mat_graph.marquee_end.x), min(_mat_graph.marquee_start.y, _mat_graph.marquee_end.y)}
		m_max := im.Vec2{max(_mat_graph.marquee_start.x, _mat_graph.marquee_end.x), max(_mat_graph.marquee_start.y, _mat_graph.marquee_end.y)}
		nc.canvas_draw_marquee(dl, m_min, m_max)

		if (m_max.x - m_min.x) > 3.0 || (m_max.y - m_min.y) > 3.0 {
			if !io.KeyCtrl && !io.KeyShift {
				clear(&_mat_graph.selected_node_ids)
			}
			for n in _mat_graph.nodes {
				if n.kind == .Comment_Box do continue
				sp  := node_screen_pos(n, canvas_p0)
				bsz := node_card_size(n) * zm
				if sp.x + bsz.x >= m_min.x && sp.x <= m_max.x && sp.y + bsz.y >= m_min.y && sp.y <= m_max.y {
					_set_mat_node_selected(n.id, true)
				}
			}
		}
		if !im.IsMouseDown(.Left) {
			_mat_graph.marquee_dragging = false
		}
	}

	// Keyboard shortcuts when canvas is hovered and not typing in a text box:
	// • `F` -> Frame All nodes
	// • `C` -> Spawn Comment Box wrapping selected nodes (just like Unreal Engine!)
	// • `Delete` or `Backspace` -> Delete all selected non-output nodes
	if canvas_hovered && !io.WantTextInput {
		if im.IsKeyPressed(.F, false) {
			_frame_all_mat_nodes()
		}
		if im.IsKeyPressed(.C, false) {
			spawn_p := [2]f32{
				(io.MousePos.x - canvas_p0.x) / max(zm, 0.1) - _mat_graph.cv.pan.x,
				(io.MousePos.y - canvas_p0.y) / max(zm, 0.1) - _mat_graph.cv.pan.y,
			}
			_ = _spawn_comment_box_for_selection(spawn_p)
		}
		if (im.IsKeyPressed(.Delete, false) || im.IsKeyPressed(.Backspace, false)) && len(_mat_graph.selected_node_ids) > 0 {
			prev_a := context.allocator
			context.allocator = runtime.default_allocator()
			deleted_any := false
			for sid in _mat_graph.selected_node_ids {
				for i := 0; i < len(_mat_graph.nodes); i += 1 {
					if _mat_graph.nodes[i].id == sid && _mat_graph.nodes[i].kind != .Material_Output {
						if _mat_graph.nodes[i].cpu_pixels != nil do delete(_mat_graph.nodes[i].cpu_pixels)
						if _mat_graph.nodes[i].proc_cache != nil do delete(_mat_graph.nodes[i].proc_cache)
						if len(_mat_graph.nodes[i].tex_path) > 0 do delete(_mat_graph.nodes[i].tex_path)
						ordered_remove(&_mat_graph.nodes, i)
						deleted_any = true
						break
					}
				}
				for &other in _mat_graph.nodes {
					for k in 0 ..< 4 {
						if other.in_node_id[k] == sid do other.in_node_id[k] = 0
					}
				}
			}
			clear(&_mat_graph.selected_node_ids)
			context.allocator = prev_a
			if deleted_any {
				_mat_graph.preview_dirty = true
				auto_sync_to_mat = true
			}
		}
	}

	if auto_sync_to_mat {
		_ = _save_mat_graph_to_connected_mat(force_bake = false)
	}

	// Delete node if `[X]` was clicked
	if delete_node_id > 0 {
		_set_mat_node_selected(delete_node_id, false)
		prev_a := context.allocator
		context.allocator = runtime.default_allocator()
		for i := 0; i < len(_mat_graph.nodes); i += 1 {
			if _mat_graph.nodes[i].id == delete_node_id {
				if _mat_graph.nodes[i].cpu_pixels != nil do delete(_mat_graph.nodes[i].cpu_pixels)
				if _mat_graph.nodes[i].proc_cache != nil do delete(_mat_graph.nodes[i].proc_cache)
				if len(_mat_graph.nodes[i].tex_path) > 0 do delete(_mat_graph.nodes[i].tex_path)
				ordered_remove(&_mat_graph.nodes, i)
				break
			}
		}
		for &other in _mat_graph.nodes {
			for k in 0 ..< 4 {
				if other.in_node_id[k] == delete_node_id do other.in_node_id[k] = 0
			}
		}
		context.allocator = prev_a
		_mat_graph.preview_dirty = true
		_ = _save_mat_graph_to_connected_mat(force_bake = false)
	}

	// Right-Click Context Menu via Shared `Node_Canvas` (MouseWheel zoom, RMB pan without popup, Comment + Wire Style)
	if _mat_graph.wire_dragging || hover_in_node_id != 0 || hover_out_node_id != 0 {
		_mat_graph.cv.rmb_pressed_in_canvas = false
	}
	if nc.canvas_begin_context_menu(&_mat_graph.cv, nil, 0, true) {
		_mat_graph.ctx_spawn_pos = {
			(io.MousePos.x - canvas_p0.x) / max(zm, 0.1) - _mat_graph.cv.pan.x,
			(io.MousePos.y - canvas_p0.y) / max(zm, 0.1) - _mat_graph.cv.pan.y,
		}
		im.TextColored({0.45, 0.88, 1.0, 1.0}, "Add Material Graph Node")
		im.Separator()
		_draw_add_mat_node_menu_items(_mat_graph.ctx_spawn_pos)
		im.Separator()
		nc.canvas_draw_default_context_menu_items(&_mat_graph.cv, nil, 0)
		im.EndPopup()
	}

	// Whole-Canvas Drag-and-Drop Target (only active during an external drag-and-drop operation so it never intercepts node widgets!):
	if im.GetDragDropPayload() != nil {
		im.SetCursorScreenPos(canvas_p0)
		im.Dummy(canvas_sz)
		if im.BeginDragDropTarget() {
			if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
				dropped_p := strings.trim_right_null(string(([^]u8)(payload.Data)[:payload.DataSize]))
				lo_d := strings.to_lower(dropped_p, context.temp_allocator)
				if strings.has_suffix(lo_d, ".png") || strings.has_suffix(lo_d, ".jpg") || strings.has_suffix(lo_d, ".jpeg") || strings.has_suffix(lo_d, ".bmp") {
					drop_pos := [2]f32{
						(io.MousePos.x - canvas_p0.x) / max(zm, 0.1) - _mat_graph.cv.pan.x,
						(io.MousePos.y - canvas_p0.y) / max(zm, 0.1) - _mat_graph.cv.pan.y,
					}
					_ = _spawn_mat_graph_node(.Texture_Sample, drop_pos, dropped_p)
					_set_mat_graph_status(fmt.tprintf("Spawned Texture Sample node for '%s'!", filepath.base(dropped_p)))
				} else if strings.has_suffix(lo_d, ".mat") {
					_ = _connect_material_editor_to_mat(dropped_p)
				}
			}
			im.EndDragDropTarget()
		}
	}

	nc.canvas_end(&_mat_graph.cv, nil, 0)
}

connect_material_editor_to_path :: proc(mat_path: string) {
	_ensure_init()
	_ensure_mat_graph_init()
	if mat_path != "" {
		_ = _connect_material_editor_to_mat(mat_path)
	}
}

@(editor_window={id="void_material_editor", title="Material Shader Graph", icon="PALETTE", width=980, height=700})
void_material_editor_window_draw :: proc() {
	_draw_void_material_editor_impl()
}

@(private = "file")
_draw_void_material_editor_impl :: proc() {
	_ensure_init()
	_ensure_mat_graph_init()
	_flush_pending_material_disk_write()

	_mat_ed_window_hovered = im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows)
	_mat_ed_window_focused = im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows)

	// Ensure the editor is connected to a real `.mat` file (preferring selected 3D object's `.mat` or project `.mat` files)
	if _active_mat_path_len <= 0 {
		if !_try_connect_material_from_selected_3d_object() {
			all_mats := _collect_all_project_materials(context.temp_allocator)
			for mp in all_mats {
				if strings.contains(mp, "DamagedHelmet.mat") {
					_ = _connect_material_editor_to_mat(mp)
					break
				}
			}
			if _active_mat_path_len <= 0 && len(all_mats) > 0 {
				_ = _connect_material_editor_to_mat(all_mats[0])
			}
		}
	}

	active_mat_path := ""
	if _active_mat_path_len > 0 {
		active_mat_path = _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
	}

	// ═══════════════════════════════════════════════════════════════════════════
	// TOP BANNER: CONNECTED MATERIAL (.MAT) BAR (ALWAYS LOCKED TO YOUR .MAT!)
	// ═══════════════════════════════════════════════════════════════════════════
	im.TextColoredUnformatted({0.35, 0.90, 1.0, 1.0}, fmt.ctprintf("%s  Connected .mat:", icons.ICON_MD_PALETTE))
	im.SameLine()
	im.SetNextItemWidth(290)
	mat_combo_lbl: cstring = "[Select or Drop a .mat File]"
	if len(active_mat_path) > 0 {
		mat_combo_lbl = fmt.ctprintf("%s  (%s)", filepath.base(active_mat_path), filepath.dir(active_mat_path))
	}
	if im.BeginCombo("##ConnectedMatSelector", mat_combo_lbl) {
		terms := _mg_combo_search(_mg_mat_sel_search_buf[:], "##MgMatSelSearch", "Search .mat files...")
		all_mats := _collect_all_project_materials(context.temp_allocator)
		for mp in all_mats {
			if len(terms) > 0 && !widgets.search_match(mp, terms) do continue
			lbl := fmt.ctprintf("%s  (%s)", filepath.base(mp), filepath.dir(mp))
			if im.Selectable(lbl, mp == active_mat_path) {
				_ = _connect_material_editor_to_mat(mp)
				active_mat_path = _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
			}
		}
		im.EndCombo()
	}
	if im.BeginDragDropTarget() {
		if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
			dropped_p := strings.trim_right_null(string(([^]u8)(payload.Data)[:payload.DataSize]))
			if strings.has_suffix(strings.to_lower(dropped_p, context.temp_allocator), ".mat") {
				_ = _connect_material_editor_to_mat(dropped_p)
				active_mat_path = _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
			}
		}
		im.EndDragDropTarget()
	}

	im.SameLine()
	if im.Button("Get .mat from Selected 3D Object") {
		if _try_connect_material_from_selected_3d_object() {
			active_mat_path = _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
		} else {
			_set_mat_graph_status("Selected 3D object has no .mat assigned yet (click 'Assign to Selected 3D Object' to assign).")
		}
	}
	im.SameLine()
	if len(active_mat_path) > 0 {
		if m_id, m_ok := _lookup_asset_guid_any_path(active_mat_path); m_ok {
			im.PushStyleColorImVec4(.Button, {0.18, 0.56, 0.36, 0.96})
			if im.Button("Assign .mat to Selected 3D Object") {
				if _apply_material_guid_to_selected_scene_object(engine.Asset_GUID(m_id)) {
					_set_mat_graph_status(fmt.tprintf("Assigned '%s' to selected 3D object!", filepath.base(active_mat_path)))
				}
			}
			im.PopStyleColor(1)
			im.SameLine()
		}
	}
	if im.Button("+ New .mat") {
		_ = os.make_directory("assets/materials")
		new_mat_path := "assets/materials/New_Material.mat"
		for idx in 1 ..= 99 {
			cand := fmt.tprintf("assets/materials/New_Material_%d.mat", idx)
			if !os.exists(cand) {
				new_mat_path = cand
				break
			}
		}
		_ = engine.material_save_to_file(new_mat_path, engine.Material{
			shader = .Lit,
			color  = {1.0, 1.0, 1.0, 1.0},
		})
		engine.asset_db_request_refresh()
		_ = _connect_material_editor_to_mat(new_mat_path)
		active_mat_path = _resolve_disk_path_from_db_path(string(_active_mat_path_buf[:_active_mat_path_len]), context.temp_allocator)
	}

	im.Separator()

	// ═══════════════════════════════════════════════════════════════════════════
	// UNIFIED SPLIT VIEW: LEFT = CONNECTED .MAT INSPECTOR & TEXTURE FIXER
	//                     RIGHT = VISUAL MATERIAL NODE GRAPH (BOUND TO .MAT)
	// ═══════════════════════════════════════════════════════════════════════════
	avail := im.GetContentRegionAvail()
	left_w  := clamp(_mat_left_pane_w, 240.0, max(240.0, avail.x - 320.0 - widgets.SPLITTER_SIZE))
	right_w := max(320.0, avail.x - left_w - widgets.SPLITTER_SIZE)

	im.BeginChild("##ConnectedMatLeftInspector", {left_w, avail.y}, {.Borders})
	if len(active_mat_path) == 0 {
		im.TextColored({1.0, 0.78, 0.28, 1.0}, "No .mat file connected.")
		im.TextWrapped("Select a .mat file in the dropdown above or click '+ New .mat'.")
	} else {
		if active_mat_path != string(_last_refreshed_mat_buf[:_last_refreshed_mat_len]) {
			engine.asset_db_request_refresh()
			n_copy := min(len(active_mat_path), len(_last_refreshed_mat_buf))
			if n_copy > 0 do copy(_last_refreshed_mat_buf[:n_copy], active_mat_path[:n_copy])
			_last_refreshed_mat_len = n_copy
			_cached_best_tex_mat_len = 0
		}
		if m_id, m_ok := _lookup_asset_guid_any_path(active_mat_path); m_ok {
			mat_guid := engine.Asset_GUID(m_id)
			if mat_ptr, l_ok := engine.material_load(mat_guid); l_ok && mat_ptr != nil {
				mat_val := mat_ptr^
				mat_changed := false

				im.TextColoredUnformatted({0.40, 0.95, 0.65, 1.0}, fmt.ctprintf("%s", filepath.base(active_mat_path)))
				im.TextDisabledUnformatted(fmt.ctprintf("%s", active_mat_path))
				im.Separator()

				// ── 1. ALBEDO / BASE TEXTURE ASSIGNMENT & 1-CLICK FIXER ──
				im.TextColored({0.98, 0.80, 0.32, 1.0}, "1. Base / Albedo Texture (.png / .jpg)")

				tex_name: string = "None (Solid Color)"
				tex_path_str: string = ""
				if !engine.asset_guid_is_empty(mat_val.texture) {
					if tp, pok := engine.asset_db_get_path(uuid.Identifier(mat_val.texture)); pok && len(tp) > 0 {
						tex_path_str = _resolve_disk_path_from_db_path(tp, context.temp_allocator)
						tex_name     = filepath.base(tex_path_str)
					} else {
						tex_name = "Assigned Texture"
					}
				}

				// Thumbnail + Drag & Drop Box
				if !engine.asset_guid_is_empty(mat_val.texture) {
					if tex_obj, tok := engine.texture_load(mat_val.texture); tok && tex_obj != nil && tex_obj.gfx != nil && tex_obj.gfx.gpu != nil {
						tid := im.TextureID(uintptr(gfx.texture_imgui_id(tex_obj.gfx)))
						im.Image(im.TextureRef{_TexID = tid}, {84, 84})
						im.SameLine()
					}
				}
				im.BeginGroup()
				im.TextWrappedUnformatted(fmt.ctprintf("%s", tex_name))
				im.PushStyleColorImVec4(.Button, {0.22, 0.34, 0.52, 0.92})
				im.Button("Drop .png / .jpg Texture Here", {-1, 32})
				im.PopStyleColor(1)
				if im.BeginDragDropTarget() {
					if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil && payload.DataSize > 0 {
						dropped_p := strings.trim_right_null(string(([^]u8)(payload.Data)[:payload.DataSize]))
						lo_d := strings.to_lower(dropped_p, context.temp_allocator)
						if strings.has_suffix(lo_d, ".png") || strings.has_suffix(lo_d, ".jpg") || strings.has_suffix(lo_d, ".jpeg") || strings.has_suffix(lo_d, ".bmp") {
							engine.asset_db_request_refresh()
							_cached_best_tex_mat_len = 0
							if tid, tok := _lookup_asset_guid_any_path(dropped_p); tok {
								mat_val.texture = engine.Asset_GUID(tid)
								mat_changed = true
							}
						}
					}
					im.EndDragDropTarget()
				}
				im.EndGroup()

				// All-Project Texture Dropdown (lists same-folder textures first!)
				im.SetNextItemWidth(-1)
				if im.BeginCombo("##ConnectedMatTexCombo", strings.clone_to_cstring(tex_name, context.temp_allocator)) {
					terms := _mg_combo_search(_mg_conn_tex_search_buf[:], "##MgConnTexSearch", "Search textures...")
					if len(terms) == 0 && im.Selectable("[None - Solid Color]", engine.asset_guid_is_empty(mat_val.texture)) {
						mat_val.texture = {}
						mat_changed = true
					}
					all_texs := _collect_all_project_textures(filepath.dir(active_mat_path), context.temp_allocator)
					for rel_t in all_texs {
						if len(terms) > 0 && !widgets.search_match(rel_t, terms) do continue
						if tid, tok := _lookup_asset_guid_any_path(rel_t); tok {
							tg := engine.Asset_GUID(tid)
							disp_lbl := fmt.ctprintf("%s  (%s)", filepath.base(rel_t), filepath.dir(rel_t))
							if im.Selectable(disp_lbl, mat_val.texture == tg) {
								mat_val.texture = tg
								mat_changed = true
							}
						}
					}
					im.EndCombo()
				}

				// One-click button if a texture is currently clicked/selected in Void File Explorer!
				if sel_item, s_ok := _find_selected_file_item(); s_ok && !sel_item.is_dir {
					lo_ext := strings.to_lower(sel_item.extension, context.temp_allocator)
					if lo_ext == ".png" || lo_ext == ".jpg" || lo_ext == ".jpeg" || lo_ext == ".bmp" {
						im.PushStyleColorImVec4(.Button, {0.16, 0.58, 0.34, 0.96})
						if im.Button(fmt.ctprintf("Use Selected Explorer Texture: %s", sel_item.name), {-1, 24}) {
							if tid, tok := _lookup_asset_guid_any_path(sel_item.path); tok {
								mat_val.texture = engine.Asset_GUID(tid)
								mat_changed = true
							}
						}
						im.PopStyleColor(1)
					}
				}

				// One-click Auto-Detect Matching Texture in Folder (cached per active_mat_path, zero per-frame disk scan!)
				if active_mat_path != string(_cached_best_tex_mat_buf[:_cached_best_tex_mat_len]) {
					bt := _find_best_matching_texture_in_folder(active_mat_path, context.temp_allocator)
					nm := min(len(active_mat_path), len(_cached_best_tex_mat_buf))
					if nm > 0 do copy(_cached_best_tex_mat_buf[:nm], active_mat_path[:nm])
					_cached_best_tex_mat_len = nm
					nr := min(len(bt), len(_cached_best_tex_res_buf))
					if nr > 0 do copy(_cached_best_tex_res_buf[:nr], bt[:nr])
					_cached_best_tex_res_len = nr
				}
				best_folder_tex := string(_cached_best_tex_res_buf[:_cached_best_tex_res_len])
				if len(best_folder_tex) > 0 {
					if im.Button(fmt.ctprintf("Auto-Fix Texture (%s)", filepath.base(best_folder_tex)), {-1, 23}) {
						if tid, tok := _lookup_asset_guid_any_path(best_folder_tex); tok {
							mat_val.texture = engine.Asset_GUID(tid)
							mat_val.color   = {1, 1, 1, 1}
							mat_changed = true
						}
					}
				}
				if !engine.asset_guid_is_empty(mat_val.texture) {
					if im.SmallButton("Clear Texture (Solid Color)") {
						mat_val.texture = {}
						mat_changed = true
					}
				}

				im.Spacing()
				im.Separator()

				// ── 2. SHADER MODE & BASE COLOR / TINT ──
				im.TextColored({0.98, 0.80, 0.32, 1.0}, "2. Shader & Base Color / Tint")
				shader_names := [2]cstring{"Unlit (Flat / Emissive)", "Lit (Multi-Light + Shadows)"}
				sh_idx := clamp(i32(mat_val.shader), 0, 1)
				im.SetNextItemWidth(-1)
				if im.ComboChar("##ConnectedMatShader", &sh_idx, raw_data(shader_names[:]), 2) {
					mat_val.shader = engine.Material_Shader(sh_idx)
					mat_changed = true
				}

				if im.ColorEdit4("Tint", &mat_val.color) {
					mat_changed = true
				}
				if im.SmallButton("Reset Tint to Pure White {1,1,1,1}") {
					mat_val.color = {1, 1, 1, 1}
					mat_changed = true
				}

				// ── 3. NAMED GRAPH PARAMETERS (FLOAT / BOOL / VEC2 / VEC3 / VEC4) ──
				im.Spacing()
				im.Separator()
				im.TextColored({0.98, 0.80, 0.32, 1.0}, "3. Named Material Parameters")
				param_count := 0
				param_changed_from_insp := false
				for &gn in _mat_graph.nodes {
					if gn.kind != .Named_Param do continue
					param_count += 1
					im.PushIDInt(gn.id)
					pname := _node_param_name(&gn)
					switch gn.param_type {
					case .Float_Param:
						if im.SliderFloat(strings.clone_to_cstring(pname, context.temp_allocator), &gn.scalar_val, -2.0, 4.0, "%.2f") {
							param_changed_from_insp = true
						}
					case .Bool_Switch:
						if im.Checkbox(strings.clone_to_cstring(pname, context.temp_allocator), &gn.param_bool) {
							gn.scalar_val           = 1.0 if gn.param_bool else 0.0
							param_changed_from_insp = true
						}
					case .Vec2_Param:
						v2 := [2]f32{gn.col_a.x, gn.col_a.y}
						if im.DragFloat2(strings.clone_to_cstring(pname, context.temp_allocator), &v2, 0.02, -16.0, 16.0, "%.2f") {
							gn.col_a.x              = v2.x
							gn.col_a.y              = v2.y
							param_changed_from_insp = true
						}
					case .Vec3_Param:
						v3 := [3]f32{gn.col_a.x, gn.col_a.y, gn.col_a.z}
						if im.DragFloat3(strings.clone_to_cstring(pname, context.temp_allocator), &v3, 0.02, -16.0, 16.0, "%.2f") {
							gn.col_a.x              = v3.x
							gn.col_a.y              = v3.y
							gn.col_a.z              = v3.z
							param_changed_from_insp = true
						}
					case .Vec4_Param:
						if im.ColorEdit4(strings.clone_to_cstring(pname, context.temp_allocator), &gn.col_a, {.NoInputs}) {
							param_changed_from_insp = true
						}
					}
					im.PopID()
				}
				if param_count == 0 {
					im.TextDisabled("No Named Parameter nodes in graph yet.")
				}
				if im.SmallButton("+ Float") {
					_ = _spawn_mat_graph_node(.Named_Param, {40, 200}, "", .Float_Param)
				}
				im.SameLine()
				if im.SmallButton("+ Bool") {
					_ = _spawn_mat_graph_node(.Named_Param, {40, 230}, "", .Bool_Switch)
				}
				im.SameLine()
				if im.SmallButton("+ Vec2") {
					_ = _spawn_mat_graph_node(.Named_Param, {40, 260}, "", .Vec2_Param)
				}
				im.SameLine()
				if im.SmallButton("+ Vec3") {
					_ = _spawn_mat_graph_node(.Named_Param, {40, 290}, "", .Vec3_Param)
				}
				im.SameLine()
				if im.SmallButton("+ Vec4") {
					_ = _spawn_mat_graph_node(.Named_Param, {40, 320}, "", .Vec4_Param)
				}
				if param_changed_from_insp {
					_mat_graph.preview_dirty = true
					_ = _save_mat_graph_to_connected_mat(force_bake = false)
					_clear_preview_cache()
				}

				if mat_changed {
					_save_and_preview_connected_material(active_mat_path, mat_guid, mat_val, sync_graph = true)
					_clear_preview_cache()
				}

				// ── 4. CUSTOM .GLSL SHADER & RAW UNIFORMS ──
				if inspector.inspectorData.doc != nil {
					im.Spacing()
					im.Separator()
					if im.CollapsingHeader("4. Custom Shader (.glsl) & Raw Uniforms") {
						inspector.draw_asset_doc(inspector.inspectorData.doc)
					}
				}
			} else {
				im.TextColored({1.0, 0.45, 0.45, 1.0}, "Failed to parse .mat file.")
				if im.Button("Repair / Reset .mat File Now", {-1, 26}) {
					repaired := engine.Material{shader = .Lit, color = {1, 1, 1, 1}}
					best_t := _find_best_matching_texture_in_folder(active_mat_path, context.temp_allocator)
					if len(best_t) > 0 {
						if tid, tok := _lookup_asset_guid_any_path(best_t); tok {
							repaired.texture = engine.Asset_GUID(tid)
						}
					}
					_save_and_preview_connected_material(active_mat_path, mat_guid, repaired, sync_graph = true)
				}
			}
		}
	}
	im.EndChild()

	im.SameLine(0, 0)
	if widgets.splitter("##mat_graph_split", true, &left_w, &right_w, 240, 320) {
		_mat_left_pane_w = left_w
	}
	im.SameLine(0, 0)

	im.BeginChild("##ConnectedMatRightNodeGraph", {0, avail.y}, {.Borders})
	_draw_visual_material_node_graph_tab()
	im.EndChild()
}

@(menu_item={path="Window/Material Shader Graph", shortcut=""})
void_material_editor_window_open :: proc() {
	wnd.open("void_material_editor")
}
