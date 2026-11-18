package file_explorer_editor

// Inspector: entity & asset inspector.
// Features:
// 1. Unified Identity Card: Entity icon, active toggle, instant inline rename, layer/ID badges, and quick scene actions.
// 2. Proportional Transform Widget: Color-coded X (red), Y (green), Z (blue) inputs, quick [R] zero/reset buttons,
//    uniform scale lock [Link], and Local vs World space coordinate toggling.
// 3. Category-Themed Component Cards: Collapsible cards with category colors (Mesh, Physics, Lighting, Control Rig,
//    Audio, Scripts), context menus (Reset, Copy, Move Up, Move Down, Remove), and deep reflected field inspection.
// 4. Quick Add Component Menu: Searchable categorization for 3D Nodes, Physics, Animation, Audio, 2D, and UI.
// 5. Inspector Pin/Lock: Padlock toggle to freeze inspection on a target entity while navigating the viewport.

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import "haati:editor/icons"
import thm "haati:editor/theme"
import "haati:editor/widgets"
import "haati:editor/inspector"
import file_exp "haati:editor/file_explorer"
import undo "haati:editor/undo"
import clip "haati:editor/clipboard"

@(private = "file")
_vi_locked: bool = false
@(private = "file")
_vi_locked_target: engine.Transform_Handle = {}
@(private = "file")
_vi_render_layer_recursive: bool = true

@(private = "file")
_vi_uniform_scale: bool = false
@(private = "file")
_vi_world_space: bool = false
@(private = "file")
_vi_comp_open: map[engine.Handle]bool
@(private = "file")
_vi_rot_mode_quat: bool = false
@(private = "file")
_vi_cached_euler_deg: [3]f32
@(private = "file")
_vi_cached_euler_owner: engine.Transform_Handle = {}
@(private = "file")
_vi_name_buf: [256]byte
@(private = "file")
_vi_name_owner: engine.Transform_Handle = {}

@(private = "file")
_vi_add_comp_open: bool = false
@(private = "file")
_vi_add_comp_open_pending: bool = false
@(private = "file")
_vi_search_buf: [128]byte

@(editor_window={id="inspector", title="Inspector", icon="TUNE", width=420, height=720})
inspector_window :: proc() {
	inspector.field_edit_frame_begin(im.IsAnyItemActive())

	im.PushStyleVarImVec2(.WindowPadding, {10, 10})
	defer im.PopStyleVar()

	w := engine.ctx_world()
	if w == nil {
		im.TextDisabled("World not initialized")
		return
	}

	// 1. Resolve Target Handle or Asset Mode
	tH: engine.Transform_Handle = {}
	asset_mode := false
	if _vi_locked && _vi_locked_target != {} && engine.pool_valid(&w.transforms, engine.Handle(_vi_locked_target)) {
		tH = _vi_locked_target
	} else {
		if _vi_locked && _vi_locked_target != {} && !engine.pool_valid(&w.transforms, engine.Handle(_vi_locked_target)) {
			_vi_locked = false
			_vi_locked_target = {}
		}
		if inspector.is_locked() && inspector.has_selected_asset() {
			asset_mode = true
		} else {
			tH = engine.inspector_active_selection()
			if tH == {} {
				if inspector.has_selected_asset() {
					asset_mode = true
				} else {
					tH = engine.inspector_inspected_selection()
					if tH == {} {
						all := engine.inspector_selection_all()
						if len(all) > 0 {
							tH = all[len(all) - 1]
						}
					}
				}
			}
		}
	}

	_draw_top_bar(tH, asset_mode)
	im.Separator()
	im.Spacing()

	if asset_mode {
		inspector.draw_selected_asset_inspector()
		return
	}

	if tH == {} || !engine.pool_valid(&w.transforms, engine.Handle(tH)) {
		_draw_empty_selection_card()
		return
	}

	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil {
		_draw_empty_selection_card()
		return
	}

	undo.push_transform_owner(tH)
	defer undo.pop_owner()

	// 2. Entity Identity Card
	_draw_identity_card(t, tH)
	im.Spacing()

	// 3. Modern Transform Widget
	_draw_transform_widget(t, tH)
	im.Spacing()

	// 4. Component Cards
	_draw_components_list(t, tH)
	im.Spacing()

	// 5. Add Component Button & Modal
	_draw_add_component_section(t, tH)
}

// ─────────────────────────────────────────────────────────────
// TOP STATUS & ACTION BAR
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_top_bar :: proc(tH: engine.Transform_Handle, asset_mode: bool = false) {
	// Lock Toggle
	locked := asset_mode ? inspector.is_locked() : _vi_locked
	lock_icon := locked ? icons.ICON_MD_LOCK : icons.ICON_MD_LOCK_OPEN
	lock_label := fmt.ctprintf("%s##ViLock", lock_icon)
	if im.Button(lock_label, {28, 24}) {
		if asset_mode {
			inspector.set_locked(!locked)
		} else {
			_vi_locked = !_vi_locked
			if _vi_locked {
				_vi_locked_target = tH
			} else {
				_vi_locked_target = {}
			}
		}
	}
	widgets.tooltip(locked ? "Unlock (follow active selection)" : "Lock (freeze on current target)")

	p := thm.palette()
	im.SameLine()
	if locked {
		im.TextColored(p.status_warning, "[PINNED]")
	} else {
		im.TextDisabled("[AUTO]")
	}

	if tH != {} {
		im.SameLine(0, 15)
		im.TextColoredUnformatted(p.accent, fmt.ctprintf("%s GameObject", icons.ICON_MD_ACCOUNT_TREE))

		// Quick Action Icons on the right
		btn_w: f32 = 26
		avail := im.GetContentRegionAvail().x
		right_margin: f32 = 3 * (btn_w + 4)
		if avail > right_margin {
			im.SameLine(im.GetWindowWidth() - right_margin - 12)
		} else {
			im.SameLine()
		}

		// Focus
		if im.Button(fmt.ctprintf("%s##ViFocus", icons.ICON_MD_CENTER_FOCUS), {btn_w, 24}) {
			engine.inspector_request_ping(tH)
		}
		widgets.tooltip("Focus in Scene (F)")

		im.SameLine()
		// Duplicate
		if im.Button(fmt.ctprintf("%s##ViDup", icons.ICON_MD_CONTENT_COPY), {btn_w, 24}) {
			w_dup := engine.ctx_world()
			t_cur := w_dup != nil ? engine.pool_get(&w_dup.transforms, engine.Handle(tH)) : nil
			parentH := t_cur != nil ? engine.Transform_Handle(t_cur.parent.handle) : {}
			g := undo.group_begin("Duplicate Object")
			defer undo.group_end(&g)
			undo.record_selection_snapshot()
			new_h := engine.scene_duplicate_subtree(tH)
			if new_h != {} {
				undo.record_create(new_h, parentH)
				engine.transform_ensure_unique_name(new_h)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				undo.group_commit(&g)
				_vh_select_node(new_h, true)
			}
		}
		widgets.tooltip("Duplicate Object (Ctrl+D)")

		im.SameLine()
		// Delete
		if im.Button(fmt.ctprintf("%s##ViDel", icons.ICON_MD_DELETE), {btn_w, 24}) {
			targets := [1]engine.Transform_Handle{tH}
			_vh_delete_handles(targets[:])
		}
		widgets.tooltip("Delete Object (Del)")
	} else if asset_mode {
		im.SameLine(0, 15)
		im.TextColoredUnformatted(p.accent, fmt.ctprintf("%s Asset", icons.ICON_MD_DESCRIPTION))
	}
}

// ─────────────────────────────────────────────────────────────
// EMPTY PLACEHOLDER
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_empty_selection_card :: proc() {
	p := thm.palette()
	im.Spacing()
	im.Spacing()
	center_x := im.GetWindowWidth() * 0.5

	im.SetCursorPosX(center_x - 30)
	im.TextColoredUnformatted(p.text_muted, fmt.ctprintf("%s", icons.ICON_MD_TUNE))

	im.Spacing()
	t1_w := im.CalcTextSize("No GameObject Selected").x
	im.SetCursorPosX(center_x - t1_w * 0.5)
	im.TextColored(p.text_secondary, "No GameObject Selected")

	im.Spacing()
	im.TextWrapped("Select an object in the Scene Viewport or Hierarchy to inspect its properties.")

	im.Spacing()
	im.Separator()
	im.Spacing()

	im.TextDisabled("Quick Creation:")
	if im.Button(fmt.ctprintf("%s  Create Empty Node", icons.ICON_MD_ADD), {-1, 30}) {
		s := engine.sm_scene_get_active()
		parentH := s != nil ? engine.Transform_Handle(s.root.handle) : {}
		g := undo.group_begin("Create Empty Node")
		defer undo.group_end(&g)
		undo.record_selection_snapshot()
		h := engine.transform_new("GameObject", parentH)
		if h != {} {
			undo.record_create(h, parentH)
			if s != nil do s.dirty = true
			engine.transform_ensure_unique_name(h)
			undo.group_commit(&g)
			_vh_select_node(h, true)
		}
	}
	if im.Button(fmt.ctprintf("%s  Create Armature Deformed Mesh", icons.ICON_MD_ANIMATION), {-1, 30}) {
		s := engine.sm_scene_get_active()
		parentH := s != nil ? engine.Transform_Handle(s.root.handle) : {}
		g := undo.group_begin("Create Armature Deformed Mesh")
		defer undo.group_end(&g)
		undo.record_selection_snapshot()
		h := engine.transform_new("ArmatureDeformedMesh", parentH)
		if h != {} {
			undo.record_create(h, parentH)
			engine.transform_add_comp(h, .ArmatureDeformedMesh)
			if s != nil do s.dirty = true
			engine.transform_ensure_unique_name(h)
			undo.group_commit(&g)
			_vh_select_node(h, true)
		}
	}
}

// ─────────────────────────────────────────────────────────────
// ENTITY IDENTITY CARD
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_identity_card :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	badge := _get_component_badge(t.name)

	// Active Checkbox
	is_active := t.is_active
	if im.Checkbox("##ActiveToggle", &is_active) {
		e := undo.edit_begin(tH, &t.is_active, typeid_of(bool), "Toggle Active")
		t.is_active = is_active
		undo.edit_end(&e)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Toggle GameObject Active / Enabled")

	im.SameLine()
	im.TextColoredUnformatted(badge.text_color, badge.icon)
	im.SameLine()

	// Inline Name Edit
	if _vi_name_owner != tH {
		_vi_name_owner = tH
		_vi_name_buf = {}
		copy(_vi_name_buf[:], t.name)
	}

	im.SetNextItemWidth(-145)
	buf_cstr := cstring(raw_data(_vi_name_buf[:]))
	if im.InputText("##EntityName", buf_cstr, c.size_t(len(_vi_name_buf)), {.EnterReturnsTrue}) {
		new_name := strings.trim_space(string(buf_cstr))
		if len(new_name) > 0 && new_name != t.name {
			e := undo.edit_begin(tH, &t.name, typeid_of(string), "Rename GameObject")
			delete(t.name)
			t.name = strings.clone(new_name)
			undo.edit_end(&e)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
	widgets.tooltip("Entity Name (press Enter to apply)")

	// Render Layer Selector + ID Badge on right
	im.SameLine()
	im.SetNextItemWidth(92)
	cur_layer_name := strings.clone_to_cstring(engine.render_layer_name(t.render_layer), context.temp_allocator)
	if im.BeginCombo("##VIRenderLayer", cur_layer_name) {
		im.Checkbox("Apply Recursively to Children", &_vi_render_layer_recursive)
		widgets.tooltip("When checked, changing this node's Render Layer also assigns the same layer to all child nodes below it.")
		im.Separator()
		for def in engine.RENDER_LAYER_DEFS {
			is_sel := t.render_layer == def.mask
			if im.Selectable(strings.clone_to_cstring(def.name, context.temp_allocator), is_sel) {
				if _vi_render_layer_recursive {
					engine.transform_set_render_layer_recursive(tH, def.mask)
				} else {
					t.render_layer = def.mask
					if t.scene != nil do t.scene.dirty = true
				}
			}
		}
		im.EndCombo()
	}
	widgets.tooltip(
		"Visual Culling Layer (matched against Camera.render_layer_mask).\n" +
		"• Cameras only draw Mesh / Sprite / UI nodes whose Render Layer bit is enabled on that Camera.\n" +
		"• Why Empty Nodes have it: every Transform stores a layer so you can set a layer on a parent/root container and cascade it down to all child meshes at once.\n" +
		"• Recursive by default (toggleable inside the dropdown).",
	)

	im.SameLine()
	im.TextDisabledUnformatted(fmt.ctprintf("#%d", t.local_id))
}

// ─────────────────────────────────────────────────────────────
// GODOT / UNREAL STYLE TRANSFORM WIDGET
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_colored_axis_badge :: proc(axis: cstring, bg_col: [4]f32) -> bool {
	im.PushStyleColorImVec4(im.Col.Button, bg_col)
	im.PushStyleColorImVec4(im.Col.ButtonHovered, {min(1.0, bg_col.r * 1.2), min(1.0, bg_col.g * 1.2), min(1.0, bg_col.b * 1.2), 1.0})
	ui_s := max(im.GetFontSize() / 14.0, 0.6)
	fh := im.GetFrameHeight()
	im.PushStyleColorImVec4(im.Col.ButtonActive, {bg_col.r * 0.8, bg_col.g * 0.8, bg_col.b * 0.8, 1.0})
	im.PushStyleColorImVec4(im.Col.Text, {1.0, 1.0, 1.0, 1.0})
	clicked := im.Button(axis, {math.ceil(max(18.0 * ui_s, fh * 0.80)), fh})
	im.PopStyleColor(4)
	return clicked
}

@(private = "file")
_draw_transform_widget :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	p := thm.palette()
	im.PushStyleColorImVec4(im.Col.Header, p.bg_elevated)
	im.PushStyleColorImVec4(im.Col.HeaderHovered, p.bg_hover)
	im.PushStyleColorImVec4(im.Col.HeaderActive, p.bg_active)
	defer im.PopStyleColor(3)

	open := im.CollapsingHeader(fmt.ctprintf("%s  Transform", icons.ICON_MD_OPEN_WITH), {.DefaultOpen})
	if !open do return

	ui_s := max(im.GetFontSize() / 14.0, 0.6)
	fh := im.GetFrameHeight()
	badge_w := math.ceil(max(18.0 * ui_s, fh * 0.80))
	icon_btn_sz := im.Vec2{fh, fh}
	lbl_x := math.ceil(max(62.0 * ui_s, im.CalcTextSize("Position").x + 12.0 * ui_s))
	link_x := lbl_x + fh + math.ceil(4.0 * ui_s)
	X_OFFSET := link_x + fh + math.ceil(6.0 * ui_s)
	three_badges_pad := (badge_w + 2.0 * ui_s) * 3.0 + 8.0 * ui_s + 2.0
	four_badges_pad  := (badge_w + 2.0 * ui_s) * 4.0 + 12.0 * ui_s + 2.0

	im.Indent(4.0 * ui_s)
	defer im.Unindent(4.0 * ui_s)

	tw := engine.transform_world(tH)

	// Top Options Bar: Space Mode (Local / World) & Rotation Mode (Euler / Quat)
	im.TextDisabled("Space:")
	im.SameLine(0, 4)
	if im.RadioButton("Local##Spc", !_vi_world_space) {
		_vi_world_space = false
	}
	im.SameLine(0, 6)
	if im.RadioButton("World##Spc", _vi_world_space) {
		_vi_world_space = true
	}

	im.SameLine(0, 16)
	im.TextDisabled("Rot Mode:")
	im.SameLine(0, 4)
	if im.RadioButton("Euler##RotM", !_vi_rot_mode_quat) {
		if _vi_rot_mode_quat {
			_vi_rot_mode_quat = false
			curr_q := _vi_world_space ? tw.rotation : t.rotation
			rad := engine.quat_to_euler_xyz(curr_q)
			_vi_cached_euler_deg = [3]f32{
				rad.x * (180.0 / math.PI),
				rad.y * (180.0 / math.PI),
				rad.z * (180.0 / math.PI),
			}
		}
	}
	im.SameLine(0, 6)
	if im.RadioButton("Quat##RotM", _vi_rot_mode_quat) {
		_vi_rot_mode_quat = true
	}
	im.Spacing()

	// ── 1. POSITION ──────────────────────────────────────────
	pos := _vi_world_space ? tw.position : t.position
	im.AlignTextToFramePadding()
	im.TextColored(p.text_secondary, "Position")
	im.SameLine(lbl_x)

	// Reset button [↺]
	if im.Button(fmt.ctprintf("%s##ResPos", icons.ICON_MD_REFRESH), icon_btn_sz) {
		e := undo.edit_begin(tH, &t.position, typeid_of([3]f32), "Reset Position")
		if _vi_world_space {
			engine.transform_set_world_position(tH, {0, 0, 0})
		} else {
			t.position = {0, 0, 0}
		}
		undo.edit_end(&e)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Reset Position to (0, 0, 0)")

	im.SameLine(X_OFFSET)
	avail_w := im.GetContentRegionAvail().x
	if avail_w < three_badges_pad + 90.0 * ui_s {
		im.NewLine()
		avail_w = im.GetContentRegionAvail().x
	}
	item_w := max(25.0, (avail_w - three_badges_pad) / 3.0)

	pos_changed := false

	// X Axis
	if _draw_colored_axis_badge("X##Pos", p.axis_x) {
		pos.x = 0
		pos_changed = true
	}
	widgets.tooltip("Click to reset X to 0")
	im.SameLine(0, 2)
	im.SetNextItemWidth(item_w)
	if im.DragFloat("##PosX", &pos.x, 0.05, -10000.0, 10000.0, "%.2f") {
		pos_changed = true
	}

	// Y Axis
	im.SameLine(0, 4)
	if _draw_colored_axis_badge("Y##Pos", p.axis_y) {
		pos.y = 0
		pos_changed = true
	}
	widgets.tooltip("Click to reset Y to 0")
	im.SameLine(0, 2)
	im.SetNextItemWidth(item_w)
	if im.DragFloat("##PosY", &pos.y, 0.05, -10000.0, 10000.0, "%.2f") {
		pos_changed = true
	}

	// Z Axis
	im.SameLine(0, 4)
	if _draw_colored_axis_badge("Z##Pos", p.axis_z) {
		pos.z = 0
		pos_changed = true
	}
	widgets.tooltip("Click to reset Z to 0")
	im.SameLine(0, 2)
	im.SetNextItemWidth(item_w)
	if im.DragFloat("##PosZ", &pos.z, 0.05, -10000.0, 10000.0, "%.2f") {
		pos_changed = true
	}

	if pos_changed {
		e := undo.edit_begin(tH, &t.position, typeid_of([3]f32), "Change Position")
		if _vi_world_space {
			engine.transform_set_world_position(tH, pos)
		} else {
			t.position = pos
		}
		undo.edit_end(&e)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}

	// ── 2. ROTATION (Euler degrees or Quaternion) ───────────
	im.AlignTextToFramePadding()
	im.TextColored(p.text_secondary, "Rotation")
	im.SameLine(lbl_x)

	// Reset button [↺]
	if im.Button(fmt.ctprintf("%s##ResRot", icons.ICON_MD_REFRESH), icon_btn_sz) {
		e := undo.edit_begin(tH, &t.rotation, typeid_of([4]f32), "Reset Rotation")
		if _vi_world_space {
			engine.transform_set_world_rotation(tH, engine.QUAT_IDENTITY)
		} else {
			t.rotation = engine.QUAT_IDENTITY
		}
		_vi_cached_euler_deg = {0, 0, 0}
		undo.edit_end(&e)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Reset Rotation to Identity")

	im.SameLine(X_OFFSET)
	avail_w = im.GetContentRegionAvail().x

	if !_vi_rot_mode_quat {
		// Euler Mode: 3 fields (Pitch X, Yaw Y, Roll Z in degrees)
		if avail_w < three_badges_pad + 90.0 * ui_s {
			im.NewLine()
			avail_w = im.GetContentRegionAvail().x
		}
		item_w = max(25.0, (avail_w - three_badges_pad) / 3.0)

		curr_q := _vi_world_space ? tw.rotation : t.rotation
		if _vi_cached_euler_owner != tH {
			_vi_cached_euler_owner = tH
			rad := engine.quat_to_euler_xyz(curr_q)
			_vi_cached_euler_deg = [3]f32{
				rad.x * (180.0 / math.PI),
				rad.y * (180.0 / math.PI),
				rad.z * (180.0 / math.PI),
			}
		}

		euler_deg := _vi_cached_euler_deg
		rot_changed := false

		// X
		if _draw_colored_axis_badge("X##Rot", p.axis_x) {
			euler_deg.x = 0
			rot_changed = true
		}
		widgets.tooltip("Click to reset Pitch (X) to 0°")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##RotX", &euler_deg.x, 0.5, -360.0, 360.0, "%.1f°") {
			rot_changed = true
		}

		// Y
		im.SameLine(0, 4)
		if _draw_colored_axis_badge("Y##Rot", p.axis_y) {
			euler_deg.y = 0
			rot_changed = true
		}
		widgets.tooltip("Click to reset Yaw (Y) to 0°")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##RotY", &euler_deg.y, 0.5, -360.0, 360.0, "%.1f°") {
			rot_changed = true
		}

		// Z
		im.SameLine(0, 4)
		if _draw_colored_axis_badge("Z##Rot", p.axis_z) {
			euler_deg.z = 0
			rot_changed = true
		}
		widgets.tooltip("Click to reset Roll (Z) to 0°")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##RotZ", &euler_deg.z, 0.5, -360.0, 360.0, "%.1f°") {
			rot_changed = true
		}

		if rot_changed {
			_vi_cached_euler_deg = euler_deg
			rad := [3]f32{
				euler_deg.x * (math.PI / 180.0),
				euler_deg.y * (math.PI / 180.0),
				euler_deg.z * (math.PI / 180.0),
			}
			new_q := engine.quat_from_euler_xyz(rad.x, rad.y, rad.z)
			e := undo.edit_begin(tH, &t.rotation, typeid_of([4]f32), "Change Rotation")
			if _vi_world_space {
				engine.transform_set_world_rotation(tH, new_q)
			} else {
				t.rotation = new_q
			}
			undo.edit_end(&e)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	} else {
		// Quaternion Mode: 4 fields [X, Y, Z, W]
		if avail_w < four_badges_pad + 100.0 * ui_s {
			im.NewLine()
			avail_w = im.GetContentRegionAvail().x
		}
		item_w = max(20.0, (avail_w - four_badges_pad) / 4.0)

		quat := _vi_world_space ? tw.rotation : t.rotation
		quat_changed := false

		// X
		if _draw_colored_axis_badge("X##Quat", p.axis_x) {
			quat.x = 0
			quat_changed = true
		}
		widgets.tooltip("Quaternion X")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##QuatX", &quat.x, 0.01, -1.0, 1.0, "%.3f") {
			quat_changed = true
		}

		// Y
		im.SameLine(0, 4)
		if _draw_colored_axis_badge("Y##Quat", p.axis_y) {
			quat.y = 0
			quat_changed = true
		}
		widgets.tooltip("Quaternion Y")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##QuatY", &quat.y, 0.01, -1.0, 1.0, "%.3f") {
			quat_changed = true
		}

		// Z
		im.SameLine(0, 4)
		if _draw_colored_axis_badge("Z##Quat", p.axis_z) {
			quat.z = 0
			quat_changed = true
		}
		widgets.tooltip("Quaternion Z")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##QuatZ", &quat.z, 0.01, -1.0, 1.0, "%.3f") {
			quat_changed = true
		}

		// W
		im.SameLine(0, 4)
		if _draw_colored_axis_badge("W##Quat", p.axis_w) {
			quat.w = 1.0
			quat_changed = true
		}
		widgets.tooltip("Quaternion W (Scalar)")
		im.SameLine(0, 2)
		im.SetNextItemWidth(item_w)
		if im.DragFloat("##QuatW", &quat.w, 0.01, -1.0, 1.0, "%.3f") {
			quat_changed = true
		}

		if quat_changed {
			len_sq := quat.x*quat.x + quat.y*quat.y + quat.z*quat.z + quat.w*quat.w
			if len_sq > 0.000001 && !math.is_nan(len_sq) && !math.is_inf(len_sq) {
				inv_len := 1.0 / math.sqrt(len_sq)
				quat.x *= inv_len
				quat.y *= inv_len
				quat.z *= inv_len
				quat.w *= inv_len
			} else {
				quat = engine.QUAT_IDENTITY
			}

			e := undo.edit_begin(tH, &t.rotation, typeid_of([4]f32), "Change Rotation")
			if _vi_world_space {
				engine.transform_set_world_rotation(tH, quat)
			} else {
				t.rotation = quat
			}
			undo.edit_end(&e)

			rad := engine.quat_to_euler_xyz(quat)
			_vi_cached_euler_deg = [3]f32{
				rad.x * (180.0 / math.PI),
				rad.y * (180.0 / math.PI),
				rad.z * (180.0 / math.PI),
			}
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}

	// ── 3. SCALE ─────────────────────────────────────────────
	// Transform scale in scene graphs is inherently local.
	scl := t.scale
	im.AlignTextToFramePadding()
	im.TextColored(p.text_secondary, "Scale")
	im.SameLine(lbl_x)

	// Reset button [↺]
	if im.Button(fmt.ctprintf("%s##ResScl", icons.ICON_MD_REFRESH), icon_btn_sz) {
		e := undo.edit_begin(tH, &t.scale, typeid_of([3]f32), "Reset Scale")
		t.scale = {1, 1, 1}
		undo.edit_end(&e)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Reset Scale to (1, 1, 1)")

	// Uniform Scale Lock [🔗] in the action column
	im.SameLine(link_x)
	if _vi_uniform_scale {
		im.PushStyleColorImVec4(im.Col.Button, p.accent)
		im.PushStyleColorImVec4(im.Col.ButtonHovered, p.accent_hover)
		im.PushStyleColorImVec4(im.Col.Text, {1.0, 1.0, 1.0, 1.0})
	} else {
		im.PushStyleColorImVec4(im.Col.Button, p.bg_elevated)
		im.PushStyleColorImVec4(im.Col.ButtonHovered, p.bg_hover)
		im.PushStyleColorImVec4(im.Col.Text, p.text_muted)
	}
	clicked_link := im.Button(fmt.ctprintf("%s##LinkScl", icons.ICON_MD_LINK), icon_btn_sz)
	im.PopStyleColor(3)
	if clicked_link {
		_vi_uniform_scale = !_vi_uniform_scale
	}
	widgets.tooltip(_vi_uniform_scale ? "Uniform Scale: LOCKED (axes scale proportionally)" : "Uniform Scale: UNLOCKED (independent axes)")

	im.SameLine(X_OFFSET)
	avail_w = im.GetContentRegionAvail().x
	if avail_w < three_badges_pad + 90.0 * ui_s {
		im.NewLine()
		avail_w = im.GetContentRegionAvail().x
	}
	item_w = max(25.0, (avail_w - three_badges_pad) / 3.0)

	scale_changed := false
	old_scl := scl

	// X
	if _draw_colored_axis_badge("X##Scl", p.axis_x) {
		scl.x = 1.0
		if _vi_uniform_scale {
			scl.y = 1.0
			scl.z = 1.0
		}
		scale_changed = true
	}
	widgets.tooltip("Click to reset X scale to 1.0")
	im.SameLine(0, 2)
	im.SetNextItemWidth(item_w)
	if im.DragFloat("##SclX", &scl.x, 0.02, 0.0001, 10000.0, "%.2f") {
		scl.x = max(0.0001, scl.x)
		if _vi_uniform_scale && abs(old_scl.x) > 0.0001 {
			ratio := scl.x / old_scl.x
			scl.y = max(0.0001, scl.y * ratio)
			scl.z = max(0.0001, scl.z * ratio)
		}
		scale_changed = true
	}

	// Y
	im.SameLine(0, 4)
	if _draw_colored_axis_badge("Y##Scl", p.axis_y) {
		scl.y = 1.0
		if _vi_uniform_scale {
			scl.x = 1.0
			scl.z = 1.0
		}
		scale_changed = true
	}
	widgets.tooltip("Click to reset Y scale to 1.0")
	im.SameLine(0, 2)
	im.SetNextItemWidth(item_w)
	if im.DragFloat("##SclY", &scl.y, 0.02, 0.0001, 10000.0, "%.2f") {
		scl.y = max(0.0001, scl.y)
		if _vi_uniform_scale && abs(old_scl.y) > 0.0001 {
			ratio := scl.y / old_scl.y
			scl.x = max(0.0001, scl.x * ratio)
			scl.z = max(0.0001, scl.z * ratio)
		}
		scale_changed = true
	}

	// Z
	im.SameLine(0, 4)
	if _draw_colored_axis_badge("Z##Scl", p.axis_z) {
		scl.z = 1.0
		if _vi_uniform_scale {
			scl.x = 1.0
			scl.y = 1.0
		}
		scale_changed = true
	}
	widgets.tooltip("Click to reset Z scale to 1.0")
	im.SameLine(0, 2)
	im.SetNextItemWidth(item_w)
	if im.DragFloat("##SclZ", &scl.z, 0.02, 0.0001, 10000.0, "%.2f") {
		scl.z = max(0.0001, scl.z)
		if _vi_uniform_scale && abs(old_scl.z) > 0.0001 {
			ratio := scl.z / old_scl.z
			scl.x = max(0.0001, scl.x * ratio)
			scl.y = max(0.0001, scl.y * ratio)
		}
		scale_changed = true
	}

	if scale_changed {
		if math.is_nan(scl.x) || math.is_inf(scl.x) do scl.x = 1.0
		if math.is_nan(scl.y) || math.is_inf(scl.y) do scl.y = 1.0
		if math.is_nan(scl.z) || math.is_inf(scl.z) do scl.z = 1.0
		e := undo.edit_begin(tH, &t.scale, typeid_of([3]f32), "Change Scale")
		t.scale = scl
		undo.edit_end(&e)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}

	im.Spacing()
}

// ─────────────────────────────────────────────────────────────
// COMPONENT CARDS LIST
// ─────────────────────────────────────────────────────────────

@(private = "file")
_draw_components_list :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return

	remove_idx: int = -1
	move_from: int = -1
	move_to: int = -1

	for idx in 0 ..< len(t.components) {
		comp := &t.components[idx]
		if comp.handle.type_key == engine.INVALID_TYPE_KEY do continue
		tid := engine.get_typeid_by_type_key(comp.handle.type_key)
		if tid == nil do continue

		pComp := engine.world_pool_get(w, comp.handle)
		if pComp == nil do continue

		// Category badge styling
		type_name := fmt.tprintf("%v", tid)
		badge := _get_component_badge(type_name)

		im.PushIDPtr(pComp)

		// Clean Antigravity Card Header: calm tonal surface + crisp 2.5px left category accent bar
		p := thm.palette()
		im.PushStyleColorImVec4(im.Col.Header, badge.bg_color)
		im.PushStyleColorImVec4(im.Col.HeaderHovered, p.bg_hover)
		im.PushStyleColorImVec4(im.Col.HeaderActive, p.bg_active)

		card_title := fmt.ctprintf("%s  %s###Card_%v_%v", badge.icon, type_name, comp.handle.type_key, comp.handle.index)
		is_open := _vi_comp_open[comp.handle] or_else true
		im.SetNextItemOpen(is_open)
		header_open := im.CollapsingHeader(card_title, {.AllowOverlap})
		im.PopStyleColor(3)

		// Subtle 2.5px semantic category indicator strip along left edge of header
		h_min := im.GetItemRectMin()
		h_max := im.GetItemRectMax()
		im.DrawList_AddRectFilled(
			im.GetWindowDrawList(),
			{h_min.x, h_min.y + 3},
			{h_min.x + 2.5, h_max.y - 3},
			im.GetColorU32ImVec4(badge.text_color),
			1.5,
		)

		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			inspector.open_component_source(comp.handle.type_key)
		}
		if im.IsItemHovered() && im.IsMouseClicked(.Right) {
			im.OpenPopup("##CompMenu")
		}

		// Button bar on the right side of the card header
		wall_spacer: f32 = 14.0 // Generous clearance from window wall/scrollbar for easy mouse hovering
		btn_w: f32 = 22.0
		gap: f32 = 4.0

		src_path, src_line, has_src := inspector.component_source_location(comp.handle.type_key)

		avail_right := im.GetCursorPosX() + im.GetContentRegionAvail().x
		menu_btn_x := avail_right - btn_w - wall_spacer
		code_btn_x := menu_btn_x - btn_w - gap

		code_clicked := false
		if has_src {
			im.SameLine(code_btn_x)
			code_btn_label := fmt.ctprintf("%s##CodeBtn_%v_%v", icons.ICON_MD_CODE, comp.handle.type_key, comp.handle.index)
			if im.SmallButton(code_btn_label) {
				code_clicked = true
				inspector.open_component_source(comp.handle.type_key)
			}
			widgets.tooltip(fmt.ctprintf("Edit Script: Open %s source code\n%s:%d", type_name, src_path, src_line))
		}

		// Context Menu Button on the top-right of the card header
		im.SameLine(menu_btn_x)
		ctx_btn_label := fmt.ctprintf("%s##CtxBtn_%v_%v", icons.ICON_MD_MORE_HORIZ, comp.handle.type_key, comp.handle.index)
		menu_clicked := im.SmallButton(ctx_btn_label)
		if menu_clicked {
			im.OpenPopup("##CompMenu")
		}

		if code_clicked || menu_clicked {
			header_open = is_open
			_vi_comp_open[comp.handle] = is_open
		} else {
			_vi_comp_open[comp.handle] = header_open
		}

		if im.BeginPopup("##CompMenu") {
			im.TextColoredUnformatted(badge.text_color, fmt.ctprintf("%s  %s", badge.icon, type_name))
			im.Separator()

			if has_src {
				im.TextDisabledUnformatted(fmt.ctprintf("%s:%d", src_path, src_line))
				if im.MenuItem(fmt.ctprintf("%s  Inspect Component Script (.odin)...", icons.ICON_MD_CODE)) {
					inspector.open_component_source(comp.handle.type_key)
				}
				if im.MenuItem(fmt.ctprintf("%s  Copy Script Path & Line", icons.ICON_MD_CONTENT_COPY)) {
					im.SetClipboardText(fmt.ctprintf("%s:%d", src_path, src_line))
				}
				im.Separator()
			}

			if im.MenuItem(fmt.ctprintf("%s  Copy Values", icons.ICON_MD_CONTENT_COPY)) {
				clip.copy(any{pComp, tid})
			}
			if clip.can_paste(tid) {
				if im.MenuItem(fmt.ctprintf("%s  Paste Values", icons.ICON_MD_CONTENT_PASTE)) {
					e := undo.edit_begin(comp.handle, tid, "Paste Component Values")
					clip.paste_component_values(pComp, tid, comp.handle.type_key)
					undo.edit_end(&e)
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
			}

			im.Separator()
			if idx > 0 {
				if im.MenuItem(fmt.ctprintf("%s  Move Up", icons.ICON_MD_EXPAND_LESS)) {
					move_from = idx
					move_to = idx - 1
				}
			}
			if idx < len(t.components) - 1 {
				if im.MenuItem(fmt.ctprintf("%s  Move Down", icons.ICON_MD_EXPAND_MORE)) {
					move_from = idx
					move_to = idx + 1
				}
			}

			im.Separator()
			if im.MenuItem(fmt.ctprintf("%s  Remove Component", icons.ICON_MD_DELETE)) {
				remove_idx = idx
			}
			im.EndPopup()
		}

		if header_open {
			im.Indent(8)
			im.Spacing()

			// Draw reflected fields using Haati's property drawer system
			undo.push_component_owner(comp.handle)
			inspector.draw_inspector(any{pComp, tid})
			undo.pop_owner()

			im.Spacing()
			im.Unindent(8)
		}

		im.PopID()
		im.Spacing()
	}

	// Apply deferred removals and reorders
	if remove_idx >= 0 && remove_idx < len(t.components) {
		comp_to_remove := t.components[remove_idx]
		undo.record_remove_component(tH, comp_to_remove.handle)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	if move_from >= 0 && move_to >= 0 && move_from < len(t.components) && move_to < len(t.components) {
		t.components[move_from], t.components[move_to] = t.components[move_to], t.components[move_from]
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
}

// ─────────────────────────────────────────────────────────────
// ADD COMPONENT SECTION & SEARCH MENU
// ─────────────────────────────────────────────────────────────

@(private = "file")
_vi_cat_filter: int = 0
@(private = "file")
_vi_highlight_idx: int = 0
@(private = "file")
_vi_inline_new_script_open: bool = false
@(private = "file")
_vi_inline_new_script_focus: bool = false
@(private = "file")
_vi_catalog_new_script_mode: bool = false
@(private = "file")
_vi_catalog_new_script_focus: bool = false
@(private = "file")
_vi_new_script_name_buf: [128]u8
@(private = "file")
_vi_new_script_folder_buf: [256]u8
@(private = "file")
_vi_last_created_script_path: [256]u8
@(private = "file")
_vi_last_created_script_name: [128]u8

@(private = "file")
_vi_prefill_new_script_buf :: proc(preferred: string) {
	mem.zero(&_vi_new_script_name_buf, len(_vi_new_script_name_buf))
	mem.zero(&_vi_new_script_folder_buf, len(_vi_new_script_folder_buf))
	def_name := _vh_default_odin_component_name(preferred)
	copy(_vi_new_script_name_buf[:len(_vi_new_script_name_buf) - 1], def_name)
	def_folder := _vh_default_odin_component_folder()
	if len(def_folder) > 0 {
		copy(_vi_new_script_folder_buf[:len(_vi_new_script_folder_buf) - 1], def_folder)
	}
}

@(private = "file")
_vi_record_created_script :: proc(struct_name, norm_path: string) {
	mem.zero(&_vi_last_created_script_path, len(_vi_last_created_script_path))
	mem.zero(&_vi_last_created_script_name, len(_vi_last_created_script_name))
	copy(_vi_last_created_script_path[:len(_vi_last_created_script_path) - 1], norm_path)
	copy(_vi_last_created_script_name[:len(_vi_last_created_script_name) - 1], struct_name)
}

@(private = "file")
_draw_add_component_section :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	im.Spacing()
	im.Separator()
	im.Spacing()

	p := thm.palette()
	avail_w := im.GetContentRegionAvail().x
	new_script_w: f32 = 128.0
	add_btn_w := max(120.0, avail_w - new_script_w - 6.0)

	im.PushStyleColorImVec4(im.Col.Button, p.accent_soft)
	im.PushStyleColorImVec4(im.Col.ButtonHovered, thm.with_alpha(p.accent, 0.26))
	im.PushStyleColorImVec4(im.Col.Border, thm.with_alpha(p.accent, 0.55))
	im.PushStyleVar(.FrameBorderSize, 1.0)
	if im.Button(fmt.ctprintf("%s   Add Component...", icons.ICON_MD_ADD), {add_btn_w, 32}) {
		_vi_add_comp_open = true
		_vi_add_comp_open_pending = true
		_vi_catalog_new_script_mode = false
		_vi_search_buf = {}
		_vi_cat_filter = 0
		_vi_highlight_idx = 0
	}
	im.PopStyleVar()
	im.PopStyleColor(3)
	widgets.tooltip("Search and attach any engine or custom gameplay component to this Node")

	im.SameLine(0, 6)
	im.PushStyleColorImVec4(im.Col.Button, p.bg_elevated)
	im.PushStyleColorImVec4(im.Col.ButtonHovered, p.bg_hover)
	if im.Button(fmt.ctprintf("%s New Script", icons.ICON_MD_CODE), {new_script_w, 32}) {
		_vi_inline_new_script_open = !_vi_inline_new_script_open
		if _vi_inline_new_script_open {
			_vi_prefill_new_script_buf(t.name)
			_vi_inline_new_script_focus = true
		}
	}
	im.PopStyleColor(2)
	widgets.tooltip("Create a new Odin @(component) script in your project and open it in your IDE")

	// ── Inline "Create New Odin Component (.odin)" drawer inside Inspector ──
	if _vi_inline_new_script_open {
		im.Spacing()
		im.PushStyleColorImVec4(.ChildBg, p.bg_elevated)
		if im.BeginChild("##VIInlineNewScriptBox", {0, 224}, {.Borders}) {
			im.TextColoredUnformatted(p.status_success, fmt.ctprintf("%s  Create New Odin Component (.odin)", icons.ICON_MD_CODE))
			im.SameLine(max(220.0, im.GetContentRegionAvail().x - 22.0))
			if im.SmallButton(fmt.ctprintf("%s##VICloseInlineScript", icons.ICON_MD_CLOSE)) {
				_vi_inline_new_script_open = false
			}

			im.TextDisabled("Component Struct Name (PascalCase):")
			if _vi_inline_new_script_focus {
				im.SetKeyboardFocusHere()
				_vi_inline_new_script_focus = false
			}
			im.SetNextItemWidth(-1)
			enter_pressed := im.InputTextWithHint(
				"##VIInlineCompNameInput",
				"Enter component struct name (e.g. CamPawn)...",
				cstring(raw_data(_vi_new_script_name_buf[:])),
				len(_vi_new_script_name_buf),
				{.EnterReturnsTrue},
			)

			raw_name := strings.trim_space(string(cstring(raw_data(_vi_new_script_name_buf[:]))))
			struct_name := _vh_sanitize_odin_identifier(raw_name)

			im.Spacing()
			clean_sub := _vh_draw_odin_folder_selector_and_preview("VIInline", &_vi_new_script_folder_buf, struct_name, -1)

			im.Spacing()
			can_create := len(struct_name) > 0
			if !can_create do im.BeginDisabled()
			im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_success, 0.22))
			im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.status_success, 0.34))
			if im.Button(fmt.ctprintf("%s  Create & Open in IDE", icons.ICON_MD_CHECK), {190, 28}) || (enter_pressed && can_create) {
				if created_path, ok := _vh_create_and_open_odin_component(struct_name, clean_sub); ok {
					_vi_record_created_script(struct_name, created_path)
					_vi_inline_new_script_open = false
				}
			}
			im.PopStyleColor(2)
			if !can_create do im.EndDisabled()

			im.SameLine(0, 8)
			if im.Button(fmt.ctprintf("%s  Cancel", icons.ICON_MD_CLOSE), {90, 28}) {
				_vi_inline_new_script_open = false
			}
		}
		im.EndChild()
		im.PopStyleColor(1)
	}

	// ── Confirmation banner after creating a script ──
	last_created_path := string(cstring(raw_data(_vi_last_created_script_path[:])))
	last_created_name := string(cstring(raw_data(_vi_last_created_script_name[:])))
	if len(last_created_path) > 0 {
		im.Spacing()
		im.PushStyleColorImVec4(.ChildBg, p.bg_elevated)
		if im.BeginChild("##VILastCreatedBanner", {0, 62}, {.Borders}) {
			im.TextColoredUnformatted(p.status_success, fmt.ctprintf("%s  Script Ready: component_%s.odin", icons.ICON_MD_CHECK, last_created_name))
			im.SameLine(max(200.0, im.GetContentRegionAvail().x - 22.0))
			if im.SmallButton(fmt.ctprintf("%s##VIDismissCreated", icons.ICON_MD_CLOSE)) {
				mem.zero(&_vi_last_created_script_path, len(_vi_last_created_script_path))
			}
			if im.SmallButton(fmt.ctprintf("%s  Open in IDE", icons.ICON_MD_CODE)) {
				file_exp.open_script_in_ide(last_created_path, 6)
			}
			im.SameLine(0, 6)
			if im.SmallButton(fmt.ctprintf("%s  Reveal in File Explorer", icons.ICON_MD_FOLDER)) {
				file_exp.reveal_in_os(last_created_path)
			}
			im.SameLine(0, 8)
			im.TextDisabled("(Rebuild / Hot-Reload to attach)")
		}
		im.EndChild()
		im.PopStyleColor(1)
	}

	if !_vi_add_comp_open do return

	if _vi_add_comp_open_pending || !im.IsPopupOpen("Add Component Catalog", {}) {
		im.OpenPopup("Add Component Catalog", {})
		_vi_add_comp_open_pending = false
	}
	widgets.center_next_window_on_active_monitor(.Appearing)
	im.SetNextWindowSize({480, 520}, .Appearing)

	if im.BeginPopupModal("Add Component Catalog", &_vi_add_comp_open, {}) {
		if _vi_catalog_new_script_mode {
			root_label := engine.has_active_project() ? engine.active_project_name() : "assets/scripts"
			im.TextColoredUnformatted({0.25, 0.95, 0.58, 1.0}, fmt.ctprintf("%s  Create New Odin Gameplay Component (.odin)", icons.ICON_MD_CODE))
			im.TextDisabled("%s", fmt.ctprintf("Creates a new @(component) struct in %s/ and opens it in your IDE.", root_label))
			im.Separator()
			im.Spacing()

			im.Text("Component Struct Name (PascalCase):")
			if _vi_catalog_new_script_focus {
				im.SetKeyboardFocusHere()
				_vi_catalog_new_script_focus = false
			}
			im.SetNextItemWidth(456)
			enter_pressed := im.InputTextWithHint(
				"##VICatalogNewCompName",
				"Enter component struct name (e.g. CamPawn)...",
				cstring(raw_data(_vi_new_script_name_buf[:])),
				len(_vi_new_script_name_buf),
				{.EnterReturnsTrue},
			)

			raw_name := strings.trim_space(string(cstring(raw_data(_vi_new_script_name_buf[:]))))
			struct_name := _vh_sanitize_odin_identifier(raw_name)

			im.Spacing()
			clean_sub := _vh_draw_odin_folder_selector_and_preview("VICatalog", &_vi_new_script_folder_buf, struct_name, 456)

			im.Spacing()
			im.Separator()
			im.Spacing()

			can_create := len(struct_name) > 0
			if !can_create do im.BeginDisabled()
			im.PushStyleColorImVec4(.Button, {0.16, 0.46, 0.32, 0.95})
			im.PushStyleColorImVec4(.ButtonHovered, {0.22, 0.58, 0.40, 1.0})
			if im.Button(fmt.ctprintf("%s  Create & Open in IDE", icons.ICON_MD_CHECK), {200, 32}) || (enter_pressed && can_create) {
				if created_path, ok := _vh_create_and_open_odin_component(struct_name, clean_sub); ok {
					_vi_record_created_script(struct_name, created_path)
					_vi_catalog_new_script_mode = false
					_vi_add_comp_open = false
					im.CloseCurrentPopup()
				}
			}
			im.PopStyleColor(2)
			if !can_create do im.EndDisabled()

			im.SameLine(0, 10)
			if im.Button(fmt.ctprintf("%s  Back to Catalog", icons.ICON_MD_WIDGETS), {150, 32}) {
				_vi_catalog_new_script_mode = false
			}
			im.EndPopup()
			return
		}

		im.TextColoredUnformatted(p.accent, fmt.ctprintf("%s  Attach Component to '%s'", icons.ICON_MD_WIDGETS, t.name))
		im.Separator()
		im.Spacing()

		sr := widgets.search_bar(_vi_search_buf[:], widgets.Search_Bar_Opts{
			id         = "##CompFilter",
			hint       = "Type to search components (e.g. SpringArm, Sphere, Camera, Custom)...",
			mode       = .Popup,
			width      = 460,
			auto_focus = im.IsWindowAppearing(),
		})
		if sr.changed || sr.cleared {
			_vi_highlight_idx = 0
		}
		filter_str := sr.query

		// Quick Category Filter Pills
		cat_labels := []string{"All", "Custom Scripts", "Physics 3D", "3D & Render", "Anim & Rig", "Audio", "2D & UI"}
		cat_targets := []string{"", "Custom Scripts", "Physics 3D", "3D & Rendering", "Animation & Control Rig", "Audio", "2D"}
		im.Spacing()
		for lbl, c_idx in cat_labels {
			if c_idx > 0 do im.SameLine(0, 4)
			is_active_cat := _vi_cat_filter == c_idx
			if is_active_cat {
				im.PushStyleColorImVec4(.Button, p.accent_soft)
			} else {
				im.PushStyleColorImVec4(.Button, p.bg_elevated)
			}
			if im.SmallButton(fmt.ctprintf("%s##VICat_%d", lbl, c_idx)) {
				_vi_cat_filter = c_idx
				_vi_highlight_idx = 0
			}
			im.PopStyleColor(1)
		}

		im.Spacing()

		filter_terms := widgets.search_terms(filter_str)
		VI_Comp_Item :: struct {
			key:         engine.TypeKey,
			name:        string,
			category:    string,
			src_path:    string,
			icon:        cstring,
			col:         im.Vec4,
			already_has: bool,
		}

		matches := make([dynamic]VI_Comp_Item, 0, 48, context.temp_allocator)
		for key in engine.TypeKey {
			if key == engine.INVALID_TYPE_KEY do continue
			src_path, _, is_comp := inspector.component_source_location(key)
			if !is_comp do continue
			comp_name := fmt.tprintf("%v", key)
			cat, icon, col := _vh_classify_component_key(key, src_path)

			if _vi_cat_filter > 0 && _vi_cat_filter < len(cat_targets) {
				target_cat := cat_targets[_vi_cat_filter]
				if target_cat == "2D" {
					if cat != "2D Nodes" && cat != "UI Controls" do continue
				} else if cat != target_cat {
					continue
				}
			}

			if len(filter_terms) > 0 {
				if !widgets.search_match(comp_name, filter_terms) && !widgets.search_match(cat, filter_terms) do continue
			}

			_, existing_idx := engine.transform_find_comp(t, key)
			append(&matches, VI_Comp_Item{
				key         = key,
				name        = comp_name,
				category    = cat,
				src_path    = src_path,
				icon        = icon,
				col         = col,
				already_has = existing_idx >= 0,
			})
		}

		// Keyboard navigation (Up / Down / Enter)
		if len(matches) > 0 {
			if im.IsKeyPressed(.DownArrow) do _vi_highlight_idx += 1
			if im.IsKeyPressed(.UpArrow) do _vi_highlight_idx -= 1
			_vi_highlight_idx = clamp(_vi_highlight_idx, 0, len(matches) - 1)
			if im.IsKeyPressed(.Enter, false) || im.IsKeyPressed(.KeypadEnter, false) {
				picked := matches[_vi_highlight_idx]
				if !picked.already_has {
					_vh_attach_component_to_node(tH, picked.key)
					_vi_add_comp_open = false
					im.CloseCurrentPopup()
				}
			}
		}

		if im.BeginChild("##CompList", {460, 345}, {.Borders}) {
			if len(matches) == 0 {
				im.TextDisabled("No matching components found.")
				if len(filter_str) > 0 {
					cand := _vh_sanitize_odin_identifier(filter_str)
					if len(cand) > 0 {
						im.Spacing()
						im.PushStyleColorImVec4(.Button, {0.16, 0.44, 0.30, 0.92})
						if im.Button(fmt.ctprintf("%s  Create New Odin Component '%s' (.odin)...", icons.ICON_MD_CODE, cand), {420, 28}) {
							_vi_prefill_new_script_buf(cand)
							_vi_catalog_new_script_mode = true
							_vi_catalog_new_script_focus = true
						}
						im.PopStyleColor(1)
					}
				}
			}
			for item, idx in matches {
				im.PushIDInt(i32(item.key))
				if item.already_has do im.BeginDisabled()
				im.PushStyleColorImVec4(.Text, thm.adapt_badge_color(item.col))
				line_lbl := fmt.ctprintf(
					"%s  %s%s   [%s]",
					item.icon,
					item.name,
					item.already_has ? " (Already Attached)" : "",
					item.category,
				)
				if im.Selectable(line_lbl, idx == _vi_highlight_idx, {}, {438, 22}) {
					if !item.already_has {
						_vh_attach_component_to_node(tH, item.key)
						_vi_add_comp_open = false
						im.CloseCurrentPopup()
					}
				}
				im.PopStyleColor(1)
				if item.already_has do im.EndDisabled()
				if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
					widgets.tooltip(fmt.ctprintf("Component: %s\nCategory:  %s\nSource:    %s", item.name, item.category, item.src_path))
				}
				im.PopID()
			}
		}
		im.EndChild()

		im.Spacing()
		im.PushStyleColorImVec4(.Button, thm.with_alpha(p.status_success, 0.20))
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(p.status_success, 0.32))
		if im.Button(fmt.ctprintf("%s  + Create New Odin Component (.odin)...", icons.ICON_MD_CODE), {280, 30}) {
			pref := len(filter_str) > 0 ? filter_str : t.name
			_vi_prefill_new_script_buf(pref)
			_vi_catalog_new_script_mode = true
			_vi_catalog_new_script_focus = true
		}
		im.PopStyleColor(2)

		im.SameLine(368.0)
		if im.Button(fmt.ctprintf("%s  Close", icons.ICON_MD_CLOSE), {100, 30}) || im.IsKeyPressed(.Escape, false) {
			_vi_add_comp_open = false
			im.CloseCurrentPopup()
		}

		im.EndPopup()
	}
}

// ─────────────────────────────────────────────────────────────
// BADGE STYLING HELPERS
// ─────────────────────────────────────────────────────────────

@(private = "file")
Component_Badge :: struct {
	icon:       cstring,
	text_color: im.Vec4,
	bg_color:   im.Vec4,
}

@(private = "file")
_get_component_badge :: proc(name: string) -> Component_Badge {
	p := thm.palette()
	name_lower := strings.to_lower(name, context.temp_allocator)

	make_badge :: proc(p: thm.Theme_Palette, icon: cstring, raw_hue: [4]f32) -> Component_Badge {
		fg := thm.adapt_badge_color(raw_hue)
		// Calm Antigravity tonal surface with a subtle 7% whisper of category hue
		bg := thm.lerp_col(p.bg_elevated, fg, p.is_light ? 0.06 : 0.08)
		return {icon, fg, bg}
	}

	if strings.contains(name_lower, "springarm") {
		return make_badge(p, icons.ICON_MD_OPEN_WITH, {0.95, 0.70, 0.26, 1.0})
	}
	if strings.contains(name_lower, "camera") {
		return make_badge(p, icons.ICON_MD_VIDEOCAM, {0.36, 0.78, 0.94, 1.0})
	}
	if strings.contains(name_lower, "spotlight") || (strings.contains(name_lower, "spot") && strings.contains(name_lower, "light")) {
		return make_badge(p, icons.ICON_MD_FLASHLIGHT_ON, {0.96, 0.80, 0.28, 1.0})
	}
	if strings.contains(name_lower, "directional") || strings.contains(name_lower, "sunlight") {
		return make_badge(p, icons.ICON_MD_WB_SUNNY, {0.98, 0.82, 0.32, 1.0})
	}
	if strings.contains(name_lower, "light") {
		return make_badge(p, icons.ICON_MD_LIGHTBULB, {0.96, 0.80, 0.28, 1.0})
	}
	if strings.contains(name_lower, "controlrig") || strings.contains(name_lower, "armature") || strings.contains(name_lower, "skeleton") {
		return make_badge(p, icons.ICON_MD_SKELETON, {0.72, 0.54, 0.98, 1.0})
	}
	if strings.contains(name_lower, "humanoid") || strings.contains(name_lower, "character") {
		return make_badge(p, icons.ICON_MD_DIRECTIONS_RUN, {0.62, 0.56, 0.98, 1.0})
	}
	if strings.contains(name_lower, "anim") || strings.contains(name_lower, "skinned") {
		return make_badge(p, icons.ICON_MD_ANIMATION, {0.72, 0.54, 0.98, 1.0})
	}
	if strings.contains(name_lower, "navmesh") || strings.contains(name_lower, "path") {
		return make_badge(p, icons.ICON_MD_ROUTE, {0.38, 0.84, 0.68, 1.0})
	}
	if strings.contains(name_lower, "agent") || strings.contains(name_lower, "ai") {
		return make_badge(p, icons.ICON_MD_SMART_TOY, {0.38, 0.84, 0.68, 1.0})
	}
	if strings.contains(name_lower, "mesh") || strings.contains(name_lower, "renderer") {
		return make_badge(p, icons.ICON_MD_DEPLOYED_CODE, {0.48, 0.66, 0.97, 1.0})
	}
	if strings.contains(name_lower, "csg") || strings.contains(name_lower, "brush") {
		return make_badge(p, icons.ICON_MD_JOIN_FULL, {0.42, 0.74, 0.96, 1.0})
	}
	if strings.contains(name_lower, "collider") || strings.contains(name_lower, "rigid") || strings.contains(name_lower, "physics") {
		return make_badge(p, icons.ICON_MD_WIDGETS, {0.94, 0.58, 0.26, 1.0})
	}
	if strings.contains(name_lower, "audio") {
		return make_badge(p, icons.ICON_MD_SPEAKER, {0.92, 0.46, 0.68, 1.0})
	}
	if strings.contains(name_lower, "visualscript") || strings.contains(name_lower, "blueprint") || strings.contains(name_lower, "graph") {
		return make_badge(p, icons.ICON_MD_SCHEMA, {0.44, 0.82, 0.96, 1.0})
	}
	if strings.contains(name_lower, "sprite") {
		return make_badge(p, icons.ICON_MD_IMAGE, {0.32, 0.78, 0.56, 1.0})
	}
	if strings.contains(name_lower, "text") || strings.contains(name_lower, "canvas") || strings.contains(name_lower, "rect") {
		return make_badge(p, icons.ICON_MD_DESCRIPTION, {0.72, 0.76, 0.84, 1.0})
	}

	return make_badge(p, icons.ICON_MD_CODE, {0.34, 0.82, 0.56, 1.0})
}

