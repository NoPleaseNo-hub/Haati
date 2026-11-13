package control_rig_editor

// =============================================================================
// HAND POSE & DYNAMIC BOX COLLIDER WORKSPACE (Mode: Hand Poses)
// =============================================================================
// Provides:
// 1. Top-Bar Quick Controls: Left/Right/Mirror selector, dynamic folder-driven quick presets,
//    3D Hand Gizmos toggle, and Dynamic Hand BoxCollider visibility toggle.
// 2. Dynamic Folder-Driven Pose Library (plugins/control_rig/assets/hand_poses/*.mhpose):
//    - Automatically seeds the 8 starter poses as fast Odin packed binary .mhpose files on first run.
//    - Populates pose buttons and Blend A->B dropdowns dynamically from the folder on disk.
//    - 1-click Overwrite Selected Pose, Save New Pose, Delete Pose, and Restore Defaults.
// 3. Combinable Master Macro Drivers (Master Curl + Master Claw + Master Spread):
//    - Master Curl and Master Claw combine additively via delta vectors so they never
//      wipe each other out and preserve per-finger offsets.
// 4. Interactive 3D Viewport Hand Pose Slider Gizmos (scene view .Editor pass, selection independent):
//    - 4 Per-Finger 3D Curl Rails parented directly over each finger knuckle + per-joint rails for the active finger.
//    - Camera-facing (billboarded) 2D Thumb Aim Box anchored right next to the thumb base.
//    - 3 Hand-Level 3D Macro Rails (Fist, Claw, Spread) above the back of the wrist.
//    - Relative drag from a pose snapshot: click never jumps, dragging back restores exactly.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import "haati:engine/gizmos"
import "haati:editor/handles"
import icons "haati:editor/icons"
import widgets "haati:editor/widgets"
import undo "haati:editor/undo"
import crig "haati:packages/control_rig"
import physics3d "haati:packages/physics3d"

// Editor state for Mode: Hand Poses
hand_poses_active_left:        bool = true
hand_poses_show_box_collider:  bool = true
hand_poses_show_3d_gizmos:     bool = true
hand_poses_include_thumb_curl: bool = true

@(private = "file")
_hand_toolbar_scale: f32 = 1.0

// Dynamic Folder Library State
@(private = "file")
_pose_folder_buf:         [256]u8
@(private = "file")
_pose_folder_init:        bool = false
@(private = "file")
_selected_folder_idx:     int = 0
@(private = "file")
_blend_from_folder_idx:   int = 2 // Open_Palm
@(private = "file")
_blend_to_folder_idx:     int = 1 // Fist
@(private = "file")
_blend_scrubber_t:        f32 = 0.0
@(private = "file")
_save_pose_name_buf:      [64]u8
@(private = "file")
_save_name_init:          bool = false
@(private = "file")
_folder_status_msg:       [128]u8

// Undo session for 2D UI sliders
@(private = "file")
_hpd_undo_sess:   undo.Edit_Session
@(private = "file")
_hpd_undo_active: bool

// 3D Viewport Slider Drag State (relative drag + pose snapshot = reversible, no jump on click)
@(private = "file")
_h3d_drag_id:      u64 = 0
@(private = "file")
_h3d_start_val:    f32 = 0.0
@(private = "file")
_h3d_last_val:     f32 = 0.0
@(private = "file")
_h3d_start_mouse:  [2]f32
@(private = "file")
_h3d_start_side:   crig.Hand_Side_State // whole hand snapshot at grab: every drag frame re-applies from it
@(private = "file")
_h3d_drawn_frame:  i32 = -1 // sliders run once per frame even with several ArmatureDeformedMesh parts
@(private = "file")
_h3d_undo_sess:    undo.Edit_Session
@(private = "file")
_h3d_undo_active:  bool = false

// Currently selected digit in the 3D Viewport HUD (0=Thumb, 1=Index, 2=Middle, 3=Ring, 4=Pinky)
@(private = "file")
_active_3d_digit:  int = 1

// What a 3D slider rail drives on the edited Hand_Side_State.
@(private = "file")
_Slider_Kind :: enum u8 {
	Digit_Master, // 0=Thumb (Sweep+Mid+Tip curl), 1..4=Index..Pinky (MCP+PIP+DIP curl)
	Finger_Base,  // MCP joint (.x) for finger 1..4
	Finger_Mid,   // PIP joint (.y) for finger 1..4
	Finger_Tip,   // DIP joint (.z) for finger 1..4
	Finger_Splay, // Splay (.w) for finger 1..4
	Thumb_Sweep,  // CMC sweep for thumb
	Thumb_Roll,   // Axial opposition roll for thumb
	Thumb_Mid,    // MCP hinge for thumb
	Thumb_Tip,    // IP hinge for thumb
	Master_Curl,
	Master_Claw,
	Master_Spread,
}

// True while a 3D hand slider owns the mouse: the scene view then neither picks nor box-selects.
hand_pose_slider_dragging :: proc() -> bool {
	return _h3d_drag_id != 0
}

@(private = "file")
_set_cstr_buf :: proc(buf: []u8, str: string) {
	for i in 0 ..< len(buf) do buf[i] = 0
	n := min(len(str), len(buf) - 1)
	if n > 0 {
		copy(buf[:n], transmute([]u8)str[:n])
	}
}

@(private = "file")
_get_active_pose_folder :: proc() -> string {
	if !_pose_folder_init {
		_set_cstr_buf(_pose_folder_buf[:], crig.HAND_POSES_DIR)
		_pose_folder_init = true
	}
	s := strings.trim_space(string(cstring(&_pose_folder_buf[0])))
	if len(s) == 0 do return crig.HAND_POSES_DIR
	return s
}

@(private = "file")
_begin_hpd_undo :: proc(driver: ^crig.HandPoseDriver, label: string) {
	if driver == nil do return
	if im.IsItemActivated() {
		owned, _ := engine.transform_get_comp(driver.owner, crig.HandPoseDriver)
		if owned.handle != {} {
			_hpd_undo_sess = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, label)
			_hpd_undo_active = true
		}
	}
}

@(private = "file")
_end_hpd_undo :: proc() {
	if _hpd_undo_active && im.IsItemDeactivatedAfterEdit() {
		undo.edit_session_end(&_hpd_undo_sess)
		_hpd_undo_active = false
	}
}

// Resolves or auto-creates HandPoseDriver on the character owner
ensure_character_hand_pose_driver :: proc(target_owner: engine.Transform_Handle) -> ^crig.HandPoseDriver {
	if target_owner == {} do return nil
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(target_owner)) do return nil

	_, hpd := engine.transform_get_comp(target_owner, crig.HandPoseDriver)
	if hpd != nil do return hpd

	// Check parent or child if ArmatureDeformedMesh is on a child node
	if ot := engine.pool_get(&w.transforms, engine.Handle(target_owner)); ot != nil {
		if ot.parent.handle != {} {
			if _, phpd := engine.transform_get_comp(engine.Transform_Handle(ot.parent.handle), crig.HandPoseDriver); phpd != nil {
				return phpd
			}
		}
		for child in ot.children {
			if _, chpd := engine.transform_get_comp(engine.Transform_Handle(child.handle), crig.HandPoseDriver); chpd != nil {
				return chpd
			}
		}
	}

	// Auto-add HandPoseDriver to target_owner so Mode: Hand Poses works immediately with zero setup
	_, raw := engine.transform_add_comp(target_owner, .HandPoseDriver)
	hpd = cast(^crig.HandPoseDriver)raw
	if hpd != nil {
		crig.hand_pose_driver_ensure_bound(hpd)
		crig.hand_pose_driver_evaluate(hpd, 0.0)
	}
	return hpd
}

// =============================================================================
// TOP-BAR QUICK CONTROLS FOR MODE: HAND POSES
// =============================================================================

draw_hand_poses_top_bar :: proc(target_owner: engine.Transform_Handle, target_adm: ^crig.ArmatureDeformedMesh) {
	if target_owner == {} do return
	hpd := ensure_character_hand_pose_driver(target_owner)
	if hpd == nil do return

	// Left / Right / Mirror Quick Toggle
	is_left := hand_poses_active_left
	if is_left {
		im.PushStyleColorImVec4(.Button, {0.15, 0.55, 0.90, 0.90})
	}
	if im.Button("L Hand##TopBarL") {
		hand_poses_active_left = true
	}
	if is_left do im.PopStyleColor()
	widgets.tooltip("Edit Left Hand Pose")

	im.SameLine(0, 2)
	if !is_left {
		im.PushStyleColorImVec4(.Button, {0.90, 0.35, 0.25, 0.90})
	}
	if im.Button("R Hand##TopBarR") {
		hand_poses_active_left = false
	}
	if !is_left do im.PopStyleColor()
	widgets.tooltip("Edit Right Hand Pose")

	im.SameLine(0, 4)
	if im.Checkbox("Mirror##TopBarMirror", &hpd.mirror_hands) {
		crig.hand_pose_driver_evaluate(hpd, 0.0)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("When enabled, Left Hand pose & dynamic BoxCollider automatically mirror to Right Hand.")

	im.SameLine(0, 6)
	im.TextColored({0.5, 0.6, 0.7, 0.6}, "|")
	im.SameLine(0, 6)

	// Quick Folder Poses Dropdown in Top Bar
	folder_entries := crig.hand_pose_scan_folder(_get_active_pose_folder(), context.temp_allocator)
	side := &hpd.left if (hand_poses_active_left || hpd.mirror_hands) else &hpd.right

	if len(folder_entries) > 0 {
		if _selected_folder_idx < 0 || _selected_folder_idx >= len(folder_entries) {
			_selected_folder_idx = 0
		}
		cur_label := fmt.ctprintf("Pose: %s", folder_entries[_selected_folder_idx].display_name)
		im.SetNextItemWidth(145)
		if im.BeginCombo("##TopBarPoseFolderCombo", cur_label) {
			for entry, idx in folder_entries {
				is_sel := idx == _selected_folder_idx
				if im.Selectable(fmt.ctprintf("%s", entry.display_name), is_sel) {
					_selected_folder_idx = idx
					_set_cstr_buf(_save_pose_name_buf[:], entry.display_name)
					owned, _ := engine.transform_get_comp(hpd.owner, crig.HandPoseDriver)
					sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Apply Folder Hand Pose")
					crig.hand_side_apply_profile(side, entry.profile, .Custom)
					crig.hand_pose_driver_evaluate(hpd, 0.0)
					undo.edit_session_end(&sess)
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
			}
			im.EndCombo()
		}
		im.SameLine(0, 4)
	}

	// 3D Viewport Slider Gizmos Toggle
	pushed_3d := hand_poses_show_3d_gizmos
	if pushed_3d {
		im.PushStyleColorImVec4(.Button, {0.65, 0.35, 0.90, 0.90})
	}
	if im.Button(fmt.ctprintf("%s 3D Sliders", icons.ICON_MD_TUNE)) {
		hand_poses_show_3d_gizmos = !hand_poses_show_3d_gizmos
		if !hand_poses_show_3d_gizmos do _on_h3d_drag_lost(nil)
	}
	if pushed_3d do im.PopStyleColor()
	widgets.tooltip("Toggle Interactive 3D Hand Pose Slider Gizmos directly on the hand in the 3D Viewport.")

	im.SameLine(0, 4)

	// Show Dynamic Hand Box Collider Toggle
	pushed_box := hand_poses_show_box_collider
	if pushed_box {
		im.PushStyleColorImVec4(.Button, {0.20, 0.75, 0.45, 0.90})
	}
	if im.Button(fmt.ctprintf("%s Hand Collider", icons.ICON_MD_CROP_FREE)) {
		hand_poses_show_box_collider = !hand_poses_show_box_collider
	}
	if pushed_box do im.PopStyleColor()
	widgets.tooltip("Toggle visibility of the Dynamic Morphing Hand BoxCollider in the 3D Viewport.")
}

// =============================================================================
// 2D THUMB PAD WIDGET (Interactive Canvas for Thumb Abduction & Elevation)
// =============================================================================

@(private = "file")
_draw_thumb_2d_pad :: proc(driver: ^crig.HandPoseDriver, pos_2d: ^[2]f32) -> bool {
	changed := false
	pad_size := im.Vec2{112.0 * _hand_toolbar_scale, 112.0 * _hand_toolbar_scale}

	im.BeginGroup()
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x + pad_size.x, p0.y + pad_size.y}

	im.InvisibleButton("##Thumb2DPad", pad_size)
	_begin_hpd_undo(driver, "Adjust 2D Thumb Pad")
	is_active  := im.IsItemActive()
	is_hovered := im.IsItemHovered()

	if is_active && im.IsMouseDragging(.Left, 0.0) {
		mp := im.GetIO().MousePos
		nx := ((mp.x - p0.x) / pad_size.x) * 2.0 - 1.0
		ny := 1.0 - ((mp.y - p0.y) / pad_size.y) * 2.0
		pos_2d.x = math.clamp(nx, -1.0, 1.0)
		pos_2d.y = math.clamp(ny, -1.0, 1.0)
		changed = true
	}
	if is_hovered && im.IsMouseDoubleClicked(.Left) {
		pos_2d^ = {0.20, 0.15}
		changed = true
	}
	_end_hpd_undo()
	widgets.tooltip("2D Thumb Pad (Drag to Aim Base Thumb):\n- Horizontal (X): Spread Outward (+1) vs Tuck Inward (-1)\n- Vertical (Y): Elevate Over Fist (+1) vs Lower Toward Wrist (-1)\n(Double-click to reset)")

	dl := im.GetWindowDrawList()
	bg_col     := im.GetColorU32ImVec4({0.11, 0.13, 0.16, 0.95})
	border_col := im.GetColorU32ImVec4(is_active ? {0.30, 0.85, 1.0, 1.0} : (is_hovered ? {0.45, 0.65, 0.85, 0.9} : {0.28, 0.32, 0.38, 0.9}))
	grid_col   := im.GetColorU32ImVec4({0.25, 0.29, 0.35, 0.65})

	im.DrawList_AddRectFilled(dl, p0, p1, bg_col, 6.0)
	im.DrawList_AddRect(dl, p0, p1, border_col, 6.0)

	// Center crosshair lines
	cx := (p0.x + p1.x) * 0.5
	cy := (p0.y + p1.y) * 0.5
	im.DrawList_AddLine(dl, {p0.x + 4, cy}, {p1.x - 4, cy}, grid_col, 1.0)
	im.DrawList_AddLine(dl, {cx, p0.y + 4}, {cx, p1.y - 4}, grid_col, 1.0)

	// Map pos_2d [-1..1] to canvas pixel coordinates
	hx := p0.x + (math.clamp(pos_2d.x, -1.0, 1.0) * 0.5 + 0.5) * pad_size.x
	hy := p0.y + (1.0 - (math.clamp(pos_2d.y, -1.0, 1.0) * 0.5 + 0.5)) * pad_size.y

	line_col := im.GetColorU32ImVec4({0.25, 0.80, 1.0, 0.55})
	dot_col  := im.GetColorU32ImVec4(is_active ? {1.0, 0.90, 0.25, 1.0} : {0.25, 0.85, 1.0, 1.0})
	im.DrawList_AddLine(dl, {cx, cy}, {hx, hy}, line_col, 2.0)
	im.DrawList_AddCircleFilled(dl, {hx, hy}, 6.0 * _hand_toolbar_scale, dot_col)
	im.DrawList_AddCircle(dl, {hx, hy}, 6.0 * _hand_toolbar_scale, im.GetColorU32ImVec4({0.05, 0.05, 0.05, 0.9}), 12, 1.5)

	im.TextDisabled(fmt.ctprintf("X:%+.2f Y:%+.2f", pos_2d.x, pos_2d.y))
	im.EndGroup()
	return changed
}

// =============================================================================
// FLOATING HAND POSE & DYNAMIC BOX COLLIDER STUDIO WINDOW
// =============================================================================

draw_hand_poses_left_toolbar :: proc(target_owner: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh) {
	if target_owner == {} do return
	hpd := ensure_character_hand_pose_driver(target_owner)
	if hpd == nil do return

	if !_save_name_init {
		_set_cstr_buf(_save_pose_name_buf[:], "Relaxed")
		_save_name_init = true
	}

	vp := im.GetMainViewport()
	im.SetNextWindowViewport(vp.ID_)
	im.SetNextWindowBgAlpha(0.93)
	im.SetNextWindowSize({415, 720}, .FirstUseEver)
	im.SetNextWindowSizeConstraints({310, 260}, {920, 1600})
	im.SetNextWindowPos({vp.WorkPos.x + 68, vp.WorkPos.y + 44}, .FirstUseEver)
	flags := im.WindowFlags{.NoDocking, .NoCollapse, .NoFocusOnAppearing}

	if im.Begin("Hand Poses & Dynamic Collider###hand_pose_studio", nil, flags) {
		io := im.GetIO()
		if io.KeyCtrl && io.MouseWheel != 0 && im.IsWindowHovered(im.HoveredFlags_RootWindow | im.HoveredFlags_ChildWindows) {
			old_scale := _hand_toolbar_scale
			_hand_toolbar_scale = clamp(_hand_toolbar_scale + io.MouseWheel * 0.05, 0.65, 2.0)
			if abs(_hand_toolbar_scale - old_scale) > 0.001 {
				cur_sz := im.GetWindowSize()
				factor := _hand_toolbar_scale / old_scale
				im.SetWindowSize({cur_sz.x * factor, cur_sz.y * factor})
			}
		}

		st := im.GetStyle()
		has_scale := abs(_hand_toolbar_scale - 1.0) > 0.01
		if has_scale {
			im.PushFontFloat(nil, st.FontSizeBase * _hand_toolbar_scale)
			im.PushStyleVarImVec2(.FramePadding, {st.FramePadding.x * _hand_toolbar_scale, st.FramePadding.y * _hand_toolbar_scale})
			im.PushStyleVarImVec2(.ItemSpacing, {st.ItemSpacing.x * _hand_toolbar_scale, st.ItemSpacing.y * _hand_toolbar_scale})
			im.PushStyleVarImVec2(.ItemInnerSpacing, {st.ItemInnerSpacing.x * _hand_toolbar_scale, st.ItemInnerSpacing.y * _hand_toolbar_scale})
		}
		defer if has_scale {
			im.PopStyleVar(3)
			im.PopFont()
		}

		// Ensure calibrated hand bones are bound
		crig.hand_pose_driver_ensure_bound(hpd)

		// ---------------------------------------------------------------------
		// 1. HEADER, 3D GIZMO TOGGLE & ACTIVE HAND SELECTOR
		// ---------------------------------------------------------------------
		im.Checkbox("Active##HPDActive", &hpd.active)
		im.SameLine(0, 6)
		im.SetNextItemWidth(95 * _hand_toolbar_scale)
		if im.SliderFloat("Weight##HPDWeight", &hpd.weight, 0.0, 1.0, "%.2f") {
			crig.hand_pose_driver_evaluate(hpd, 0.0)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		im.SameLine(0, 6)
		if im.Button(fmt.ctprintf("%s Recalibrate", icons.ICON_MD_REFRESH)) {
			if adm != nil {
				crig.armature_deformed_mesh_reset_bind_pose(adm)
			}
			crig.hand_pose_driver_rebind(hpd)
			crig.hand_pose_driver_evaluate(hpd, 0.0)
		}
		widgets.tooltip("Restores bind pose and re-calibrates exact anatomical curl/splay/thumb axes from skeleton geometry.")

		// 3D Viewport Slider Gizmos & Collider Checkboxes right at the top
		im.Checkbox("3D Viewport Slider Gizmos (On-Hand Controls)", &hand_poses_show_3d_gizmos)
		widgets.tooltip("Displays interactive 3D slider rails directly around the hand and wrist in the 3D scene viewport!")

		im.Separator()

		// Hand Selection Tabs / Buttons
		is_left := hand_poses_active_left
		if is_left do im.PushStyleColorImVec4(.Button, {0.15, 0.55, 0.90, 0.95})
		if im.Button("Left Hand (L)", {118 * _hand_toolbar_scale, 0}) {
			hand_poses_active_left = true
		}
		if is_left do im.PopStyleColor()

		im.SameLine(0, 4)
		if !is_left do im.PushStyleColorImVec4(.Button, {0.90, 0.35, 0.25, 0.95})
		if im.Button("Right Hand (R)", {118 * _hand_toolbar_scale, 0}) {
			hand_poses_active_left = false
		}
		if !is_left do im.PopStyleColor()

		im.SameLine(0, 8)
		if im.Checkbox("Mirror Both", &hpd.mirror_hands) {
			if hpd.mirror_hands && !hand_poses_active_left {
				hpd.left = hpd.right
			}
			crig.hand_pose_driver_evaluate(hpd, 0.0)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

		// Copy Left <-> Right buttons
		if im.SmallButton("Copy L -> R") {
			owned, _ := engine.transform_get_comp(hpd.owner, crig.HandPoseDriver)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Copy Left Hand to Right Hand")
			hpd.right.preset        = hpd.left.preset
			hpd.right.master_curl   = hpd.left.master_curl
			hpd.right.master_claw   = hpd.left.master_claw
			hpd.right.master_spread = hpd.left.master_spread
			hpd.right.pose          = hpd.left.pose
			crig.hand_pose_driver_evaluate(hpd, 0.0)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		im.SameLine(0, 4)
		if im.SmallButton("Copy R -> L") {
			owned, _ := engine.transform_get_comp(hpd.owner, crig.HandPoseDriver)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Copy Right Hand to Left Hand")
			hpd.left.preset        = hpd.right.preset
			hpd.left.master_curl   = hpd.right.master_curl
			hpd.left.master_claw   = hpd.right.master_claw
			hpd.left.master_spread = hpd.right.master_spread
			hpd.left.pose          = hpd.right.pose
			crig.hand_pose_driver_evaluate(hpd, 0.0)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

		// Pointer to currently edited Hand_Side_State and Calibrated Bones
		edit_left := hand_poses_active_left || hpd.mirror_hands
		side  := &hpd.left if edit_left else &hpd.right
		calib := &hpd.left_calib if edit_left else &hpd.right_calib
		changed := false

		// ---------------------------------------------------------------------
		// 2. DYNAMIC FOLDER-DRIVEN HAND POSE LIBRARY (.mhpose)
		// ---------------------------------------------------------------------
		im.Separator()
		active_dir := _get_active_pose_folder()
		folder_entries := crig.hand_pose_scan_folder(active_dir, context.temp_allocator)

		im.TextColored({0.35, 0.85, 1.0, 1.0}, fmt.ctprintf("1. Folder Pose Library (%d files):", len(folder_entries)))

		if im.TreeNode("Folder Path & Library Management##PoseFolderCfg") {
			im.SetNextItemWidth(240 * _hand_toolbar_scale)
			im.InputText("Folder##PoseFolderPath", cstring(&_pose_folder_buf[0]), len(_pose_folder_buf))
			widgets.tooltip("Subfolder scanned dynamically for .mhpose binary pose files.")

			if im.SmallButton("Restore 8 Starter Poses") {
				crig.hand_pose_seed_default_folder(_get_active_pose_folder(), true)
				_set_cstr_buf(_folder_status_msg[:], "Restored 8 default .mhpose files!")
			}
			widgets.tooltip("Re-writes the 8 calibrated default poses to the folder.")
			im.TreePop()
		}

		// Dynamic Grid of Pose Buttons populated straight from the folder!
		if len(folder_entries) > 0 {
			if _selected_folder_idx < 0 || _selected_folder_idx >= len(folder_entries) {
				_selected_folder_idx = 0
			}
			btn_w := 88.0 * _hand_toolbar_scale
			for entry, idx in folder_entries {
				if idx > 0 && idx % 4 != 0 do im.SameLine(0, 4)
				is_sel := (idx == _selected_folder_idx) && (side.pose.name == entry.profile.name || side.pose.name == entry.display_name)
				if is_sel do im.PushStyleColorImVec4(.Button, {0.25, 0.70, 0.40, 0.92})
				if im.Button(fmt.ctprintf("%s##FolderPose_%d", entry.display_name, idx), {btn_w, 0}) {
					owned, _ := engine.transform_get_comp(hpd.owner, crig.HandPoseDriver)
					sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Select Folder Hand Pose")
					_selected_folder_idx = idx
					_set_cstr_buf(_save_pose_name_buf[:], entry.display_name)
					crig.hand_side_apply_profile(side, entry.profile, .Custom)
					changed = true
					undo.edit_session_end(&sess)
				}
				if is_sel do im.PopStyleColor()
				widgets.tooltip(fmt.ctprintf("Load %s\nBoxCollider Size: (%.3f, %.3f, %.3f)", entry.full_path, entry.profile.collider_size.x, entry.profile.collider_size.y, entry.profile.collider_size.z))
			}

			// Quick Save / Overwrite / New / Delete Bar right under the grid!
			im.Spacing()
			sel_entry := folder_entries[_selected_folder_idx]
			im.PushStyleColorImVec4(.Button, {0.18, 0.55, 0.32, 0.95})
			if im.Button(fmt.ctprintf("%s Update '%s'", icons.ICON_MD_SAVE, sel_entry.display_name)) {
				side.pose.name = sel_entry.display_name
				if crig.hand_pose_profile_save_to_folder(side.pose, sel_entry.filename, active_dir) {
					_set_cstr_buf(_folder_status_msg[:], fmt.tprintf("Updated %s", sel_entry.filename))
				}
			}
			im.PopStyleColor()
			widgets.tooltip("Overwrites the selected .mhpose binary file on disk with your current finger, thumb, and BoxCollider adjustments!")

			im.SameLine(0, 4)
			if im.Button(fmt.ctprintf("%s Delete", icons.ICON_MD_DELETE)) {
				if crig.hand_pose_delete_from_disk(sel_entry.full_path) {
					_set_cstr_buf(_folder_status_msg[:], fmt.tprintf("Deleted %s", sel_entry.filename))
					if _selected_folder_idx > 0 do _selected_folder_idx -= 1
				}
			}
			widgets.tooltip("Deletes the selected .mhpose file from the folder.")
		}

		// Save as New Pose input row
		im.SetNextItemWidth(165 * _hand_toolbar_scale)
		im.InputText("##NewPoseNameBuf", cstring(&_save_pose_name_buf[0]), len(_save_pose_name_buf))
		im.SameLine(0, 4)
		if im.Button("+ Save as New Pose") {
			name_str := strings.trim_space(strings.clone_from_cstring(cstring(&_save_pose_name_buf[0]), context.temp_allocator))
			if len(name_str) > 0 {
				side.pose.name = name_str
				if crig.hand_pose_profile_save_to_folder(side.pose, name_str, active_dir) {
					_set_cstr_buf(_folder_status_msg[:], fmt.tprintf("Saved %s.mhpose", name_str))
				}
			}
		}
		widgets.tooltip("Saves current hand pose & BoxCollider as a new .mhpose binary file in the folder.")

		if _folder_status_msg[0] != 0 {
			im.TextColored({0.40, 0.95, 0.55, 1.0}, "%s", cstring(&_folder_status_msg[0]))
		}

		// Live Pose-to-Pose Blend Scrubber (populated from the folder!)
		if len(folder_entries) >= 2 && im.TreeNode("Pose-to-Pose Blend Scrubber (Morph Preview)##BlendScrub") {
			if _blend_from_folder_idx < 0 || _blend_from_folder_idx >= len(folder_entries) do _blend_from_folder_idx = 0
			if _blend_to_folder_idx < 0 || _blend_to_folder_idx >= len(folder_entries) do _blend_to_folder_idx = min(1, len(folder_entries) - 1)

			im.SetNextItemWidth(135 * _hand_toolbar_scale)
			if im.BeginCombo("From##BlendA", fmt.ctprintf("%s", folder_entries[_blend_from_folder_idx].display_name)) {
				for e, i in folder_entries {
					if im.Selectable(fmt.ctprintf("%s##From_%d", e.display_name, i), i == _blend_from_folder_idx) {
						_blend_from_folder_idx = i
					}
				}
				im.EndCombo()
			}
			im.SameLine(0, 6)
			im.SetNextItemWidth(135 * _hand_toolbar_scale)
			if im.BeginCombo("To##BlendB", fmt.ctprintf("%s", folder_entries[_blend_to_folder_idx].display_name)) {
				for e, i in folder_entries {
					if im.Selectable(fmt.ctprintf("%s##To_%d", e.display_name, i), i == _blend_to_folder_idx) {
						_blend_to_folder_idx = i
					}
				}
				im.EndCombo()
			}

			c_scrub := im.SliderFloat("Blend Morph", &_blend_scrubber_t, 0.0, 1.0, "%.2f")
			_begin_hpd_undo(hpd, "Scrub Hand Pose Blend")
			if c_scrub {
				prof_a := folder_entries[_blend_from_folder_idx].profile
				prof_b := folder_entries[_blend_to_folder_idx].profile
				side.pose = crig.hand_pose_profile_lerp(prof_a, prof_b, _blend_scrubber_t)
				crig.hand_side_infer_macros_from_pose(side)
				side.preset = .Custom
				changed = true
			}
			_end_hpd_undo()
			widgets.tooltip("Scrub between Pose A and Pose B to watch both the fingers AND the Hand BoxCollider morph smoothly!")
			im.TreePop()
		}

		// ---------------------------------------------------------------------
		// 3. COMBINABLE MASTER MACRO DRIVERS (CURL + CLAW + SPREAD)
		// ---------------------------------------------------------------------
		im.Separator()
		im.TextColored({1.0, 0.85, 0.30, 1.0}, "2. Master Macro Drivers (Combinable):")
		im.Checkbox("Include Thumb in Master Curl", &hand_poses_include_thumb_curl)

		new_mcurl := side.master_curl
		c_mcurl := im.SliderFloat("Master Curl", &new_mcurl, -0.25, 1.25, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Master Curl")
		if c_mcurl {
			crig.hand_side_set_master_curl(side, new_mcurl, hand_poses_include_thumb_curl)
			changed = true
		}
		_end_hpd_undo()
		widgets.tooltip("Flexes all 3 finger knuckles forward. Combines additively with Master Claw and preserves per-finger offsets!")

		new_mclaw := side.master_claw
		c_mclaw := im.SliderFloat("Master Claw", &new_mclaw, 0.00, 1.20, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Master Claw")
		if c_mclaw {
			crig.hand_side_set_master_claw(side, new_mclaw)
			changed = true
		}
		_end_hpd_undo()
		widgets.tooltip("Extends base knuckles backward (-0.65) while hooking middle & tip knuckles (+0.85) ON TOP OF current Master Curl!")

		new_mspread := side.master_spread
		c_mspread := im.SliderFloat("Master Spread", &new_mspread, -1.00, 1.00, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Master Spread")
		if c_mspread {
			crig.hand_side_set_master_spread(side, new_mspread)
			changed = true
		}
		_end_hpd_undo()

		// ---------------------------------------------------------------------
		// 4. CALIBRATED ANATOMICAL THUMB (2D Pad + Hinges)
		// ---------------------------------------------------------------------
		im.Separator()
		im.TextColored({0.30, 0.95, 0.60, 1.0}, "3. Thumb (2D Pad + Aligned Hinges):")

		if _draw_thumb_2d_pad(hpd, &side.pose.thumb_pos_2d) {
			side.preset = .Custom
			changed = true
		}
		im.SameLine(0, 10)
		im.BeginGroup()
		im.PushItemWidth(145 * _hand_toolbar_scale)

		c_tsweep := im.SliderFloat("Sweep", &side.pose.thumb_sweep, -0.50, 1.40, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Thumb Sweep")
		if c_tsweep { side.preset = .Custom; changed = true }
		_end_hpd_undo()
		widgets.tooltip("Sweeps thumb across the palm toward the pinky.")

		c_troll := im.SliderFloat("Roll", &side.pose.thumb_roll, -1.00, 1.40, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Thumb Roll")
		if c_troll { side.preset = .Custom; changed = true }
		_end_hpd_undo()
		widgets.tooltip("Axial opposition roll along the thumb bone length.")

		c_tmid := im.SliderFloat("Mid Curl", &side.pose.thumb_mid_curl, -0.40, 1.30, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Thumb Mid Curl")
		if c_tmid { side.preset = .Custom; changed = true }
		_end_hpd_undo()

		c_ttip := im.SliderFloat("Tip Curl", &side.pose.thumb_tip_curl, -0.40, 1.30, "%.2f")
		_begin_hpd_undo(hpd, "Adjust Thumb Tip Curl")
		if c_ttip { side.preset = .Custom; changed = true }
		_end_hpd_undo()

		im.PopItemWidth()
		im.EndGroup()

		// ---------------------------------------------------------------------
		// 5. INDIVIDUAL FINGERS (Quick Single-Slider Curl + Expandable Phalanges)
		// ---------------------------------------------------------------------
		im.Separator()
		im.TextColored({0.40, 0.80, 1.00, 1.0}, "4. Individual Fingers (Quick Curl & Knuckles):")

		finger_ptrs  := [4]^[4]f32{&side.pose.index_finger, &side.pose.middle_finger, &side.pose.ring_finger, &side.pose.pinky_finger}
		finger_names := [4]cstring{"Index", "Middle", "Ring", "Pinky"}

		for f in 0 ..< 4 {
			fv := finger_ptrs[f]
			fname := finger_names[f]

			// 1-Line Quick Curl slider for the whole finger (preserves claw differential across x/y/z!)
			avg_curl := (fv.x + fv.y + fv.z) / 3.0
			new_avg  := avg_curl
			im.SetNextItemWidth(135 * _hand_toolbar_scale)
			c_fcurl := im.SliderFloat(fmt.ctprintf("%s##QuickCurl_%d", fname, f), &new_avg, -0.35, 1.25, "Curl %.2f")
			_begin_hpd_undo(hpd, "Curl Finger")
			if c_fcurl {
				diff := new_avg - avg_curl
				fv.x = math.clamp(fv.x + diff, -0.45, 1.30)
				fv.y = math.clamp(fv.y + diff, -0.45, 1.30)
				fv.z = math.clamp(fv.z + diff, -0.45, 1.30)
				side.preset = .Custom
				changed = true
			}
			_end_hpd_undo()

			im.SameLine(0, 6)
			im.SetNextItemWidth(95 * _hand_toolbar_scale)
			c_fsplay := im.SliderFloat(fmt.ctprintf("##QuickSpread_%d", f), &fv.w, -0.80, 0.80, "Spr %.2f")
			_begin_hpd_undo(hpd, "Spread Finger")
			if c_fsplay {
				side.preset = .Custom
				changed = true
			}
			_end_hpd_undo()

			im.SameLine(0, 4)
			if im.TreeNode(fmt.ctprintf("Knuckles##Knuck_%d", f)) {
				c_bx := im.SliderFloat(fmt.ctprintf("Base (MCP)##bx_%d", f), &fv.x, -0.45, 1.30, "%.2f")
				_begin_hpd_undo(hpd, "Adjust Finger Base")
				if c_bx { side.preset = .Custom; changed = true }
				_end_hpd_undo()

				c_my := im.SliderFloat(fmt.ctprintf("Mid (PIP)##my_%d", f), &fv.y, -0.35, 1.30, "%.2f")
				_begin_hpd_undo(hpd, "Adjust Finger Mid")
				if c_my { side.preset = .Custom; changed = true }
				_end_hpd_undo()

				c_tz := im.SliderFloat(fmt.ctprintf("Tip (DIP)##tz_%d", f), &fv.z, -0.35, 1.30, "%.2f")
				_begin_hpd_undo(hpd, "Adjust Finger Tip")
				if c_tz { side.preset = .Custom; changed = true }
				_end_hpd_undo()
				im.TreePop()
			}
		}

		// ---------------------------------------------------------------------
		// 6. DYNAMIC HAND BOX COLLIDER (Math Auto-Fit + Per-Pose Custom Box)
		// ---------------------------------------------------------------------
		im.Separator()
		im.TextColored({0.95, 0.65, 0.20, 1.0}, "5. Dynamic Hand BoxCollider:")
		im.Checkbox("Show Hand Collider in Viewport", &hand_poses_show_box_collider)

		cmode := i32(hpd.collider_mode)
		if im.Combo("Collider Mode", &cmode, "Per-Pose Blended + Auto-Fit\x00Pure Math (Live Finger AABB)\x00Custom Per-Pose Box\x00Disabled\x00") {
			hpd.collider_mode = crig.Hand_Collider_Mode(cmode)
			changed = true
		}
		widgets.tooltip(
			"How the Hand's BoxCollider adapts to hand poses:\n" +
			"- Per-Pose Blended + Auto-Fit: Blends custom pose boxes during transitions and auto-fits when tweaking fingers.\n" +
			"- Pure Math (Live Finger AABB): Computes exact bounding box around posed fingers every frame.\n" +
			"- Custom Per-Pose Box: Uses the custom Size & Center sliders below for this pose.",
		)

		if hpd.collider_mode != .Disabled {
			if im.Button(fmt.ctprintf("%s Auto-Fit Box from Current Fingers", icons.ICON_MD_CROP_FREE)) {
				owned, _ := engine.transform_get_comp(hpd.owner, crig.HandPoseDriver)
				sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Auto-Fit Hand BoxCollider")
				crig.hand_pose_driver_evaluate(hpd, 0.0)
				auto_sz, auto_ctr := crig.hand_pose_compute_auto_box(calib)
				side.pose.collider_size   = auto_sz
				side.pose.collider_center = auto_ctr
				changed = true
				undo.edit_session_end(&sess)
			}
			widgets.tooltip("Mathematically computes the exact oriented bounding box enclosing the wrist and all 5 posed fingers.")

			c_csz := im.DragFloat3("Box Size (Thick/Len/Wid)", &side.pose.collider_size, 0.002, 0.02, 0.35, "%.3f m")
			_begin_hpd_undo(hpd, "Adjust Hand Collider Size")
			if c_csz {
				hpd.collider_mode = .Custom_Pose_Box
				changed = true
			}
			_end_hpd_undo()

			c_cctr := im.DragFloat3("Box Center (Palm/Dist/Rad)", &side.pose.collider_center, 0.002, -0.25, 0.25, "%.3f m")
			_begin_hpd_undo(hpd, "Adjust Hand Collider Center")
			if c_cctr {
				hpd.collider_mode = .Custom_Pose_Box
				changed = true
			}
			_end_hpd_undo()
		}

		if changed {
			crig.hand_pose_driver_evaluate(hpd, 0.0)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
	}
	im.End()
}

// =============================================================================
// INTERACTIVE 3D VIEWPORT HAND POSE SLIDER GIZMOS
// =============================================================================

// Closes the open 3D slider drag (mouse up, toggle off, sliders hidden) and its undo step.
@(private = "file")
_on_h3d_drag_lost :: proc(user: rawptr) {
	if _h3d_undo_active {
		undo.edit_session_end(&_h3d_undo_sess)
		_h3d_undo_active = false
	}
	_h3d_drag_id = 0
}

// Grab: snapshot the whole hand and the mouse, open one undo step for the drag.
@(private = "file")
_h3d_begin :: proc(driver: ^crig.HandPoseDriver, side: ^crig.Hand_Side_State, id: u64, start_val: f32, label: string) {
	_h3d_drag_id     = id
	_h3d_start_val   = start_val
	_h3d_last_val    = start_val
	_h3d_start_mouse = handles.frame().input.mouse
	_h3d_start_side  = side^
	owned, _ := engine.transform_get_comp(driver.owner, crig.HandPoseDriver)
	if owned.handle != {} {
		_h3d_undo_sess   = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, label)
		_h3d_undo_active = true
	}
}

@(private = "file")
_finger_vec :: #force_inline proc(side: ^crig.Hand_Side_State, digit: int) -> ^[4]f32 {
	switch digit {
	case 1: return &side.pose.index_finger
	case 2: return &side.pose.middle_finger
	case 3: return &side.pose.ring_finger
	case 4: return &side.pose.pinky_finger
	}
	return &side.pose.index_finger
}

@(private = "file")
_slider_value :: proc(side: ^crig.Hand_Side_State, kind: _Slider_Kind, digit: int) -> f32 {
	switch kind {
	case .Digit_Master:
		if digit == 0 {
			return (side.pose.thumb_sweep + side.pose.thumb_mid_curl + side.pose.thumb_tip_curl) / 3.0
		}
		fv := _finger_vec(side, digit)
		return (fv.x + fv.y + fv.z) / 3.0
	case .Finger_Base:   return _finger_vec(side, digit).x
	case .Finger_Mid:    return _finger_vec(side, digit).y
	case .Finger_Tip:    return _finger_vec(side, digit).z
	case .Finger_Splay:  return _finger_vec(side, digit).w
	case .Thumb_Sweep:   return side.pose.thumb_sweep
	case .Thumb_Roll:    return side.pose.thumb_roll
	case .Thumb_Mid:     return side.pose.thumb_mid_curl
	case .Thumb_Tip:     return side.pose.thumb_tip_curl
	case .Master_Curl:   return side.master_curl
	case .Master_Claw:   return side.master_claw
	case .Master_Spread: return side.master_spread
	}
	return 0
}

// Applies `new_val` on top of the grab snapshot (the caller restores side^ from it first),
// so dragging back always lands on the exact starting pose, even after joints hit limits.
@(private = "file")
_slider_apply :: proc(side: ^crig.Hand_Side_State, kind: _Slider_Kind, digit: int, new_val: f32) {
	side.preset = .Custom
	switch kind {
	case .Digit_Master:
		d := new_val - _h3d_start_val
		if digit == 0 {
			side.pose.thumb_sweep    = math.clamp(side.pose.thumb_sweep + d, -0.50, 1.40)
			side.pose.thumb_mid_curl = math.clamp(side.pose.thumb_mid_curl + d, -0.40, 1.30)
			side.pose.thumb_tip_curl = math.clamp(side.pose.thumb_tip_curl + d, -0.40, 1.30)
		} else {
			fv := _finger_vec(side, digit)
			fv.x = math.clamp(fv.x + d, -0.45, 1.30)
			fv.y = math.clamp(fv.y + d, -0.45, 1.30)
			fv.z = math.clamp(fv.z + d, -0.45, 1.30)
		}
	case .Finger_Base:   _finger_vec(side, digit).x = new_val
	case .Finger_Mid:    _finger_vec(side, digit).y = new_val
	case .Finger_Tip:    _finger_vec(side, digit).z = new_val
	case .Finger_Splay:  _finger_vec(side, digit).w = new_val
	case .Thumb_Sweep:   side.pose.thumb_sweep    = new_val
	case .Thumb_Roll:    side.pose.thumb_roll     = new_val
	case .Thumb_Mid:     side.pose.thumb_mid_curl = new_val
	case .Thumb_Tip:     side.pose.thumb_tip_curl = new_val
	case .Master_Curl:   crig.hand_side_set_master_curl(side, new_val, hand_poses_include_thumb_curl)
	case .Master_Claw:   crig.hand_side_set_master_claw(side, new_val)
	case .Master_Spread: crig.hand_side_set_master_spread(side, new_val)
	}
}

// Draws a thick, screen-space-scaled 3D bar (solid + wire cylinder + center spine)
// so 3D slider rails and hand bone lines are bold and easy to see at any zoom distance.
// High-contrast visual styling: crisp white outline wrapped in an outer black shadow outline
// with a 5% thickness reduction to punch through any mesh surface or background.
@(private = "file")
_draw_thick_3d_bar :: proc(a, b: [3]f32, radius_px: f32, color: [4]f32, draw_caps := false) {
	if linalg.length(b - a) < 0.0005 do return
	// Sleek 5% slimming for crisp precision
	effective_px := radius_px * 0.95
	rad := math.clamp(handles.world_per_pixels((a + b) * 0.5, effective_px), 0.0004, 0.013)
	px1 := handles.world_per_pixels((a + b) * 0.5, 1.0)

	// 1. OUTER BLACK OUTLINE / SHADOW (halo wrapping the white outline)
	black_rad := rad + px1 * 1.5
	gizmos.with_color({0.02, 0.02, 0.03, 0.95})
	gizmos.wire_cylinder(a, b, black_rad, segments = 8)

	// 2. CRISP WHITE INNER OUTLINE
	white_rad := rad + px1 * 0.75
	gizmos.with_color({0.98, 0.98, 1.00, 0.92})
	gizmos.wire_cylinder(a, b, white_rad, segments = 8)

	// 3. VIBRANT SOLID COLORED CORE
	gizmos.with_color({color.r, color.g, color.b, math.clamp(color.a * 0.75, 0.50, 0.95)})
	gizmos.solid_cylinder(a, b, rad, segments = 8)

	// 4. COLORED WIRE CYLINDER & SPINE LINE
	gizmos.with_color(color)
	gizmos.wire_cylinder(a, b, rad, segments = 8)
	gizmos.line(a, b)

	if draw_caps {
		gizmos.with_color({0.02, 0.02, 0.03, 0.95})
		gizmos.solid_sphere(a, black_rad * 1.15, segments = 8)
		gizmos.solid_sphere(b, black_rad * 1.15, segments = 8)

		gizmos.with_color({0.98, 0.98, 1.00, 0.92})
		gizmos.wire_sphere(a, white_rad * 1.10, segments = 8)
		gizmos.wire_sphere(b, white_rad * 1.10, segments = 8)

		gizmos.with_color(color)
		gizmos.solid_sphere(a, rad * 1.05, segments = 8)
		gizmos.solid_sphere(b, rad * 1.05, segments = 8)
	}
}

// One 3D slider rail (Unreal Control Rig float-control style): grab anywhere on the rail or
// knob, then the value follows the mouse RELATIVE to the grab along the rail's screen direction.
// A click without moving changes nothing. Returns (changed, clicked).
@(private = "file")
_draw_3d_slider_rail :: proc(
	driver: ^crig.HandPoseDriver,
	side: ^crig.Hand_Side_State,
	id: u64,
	rail_a, rail_b: [3]f32,
	kind: _Slider_Kind,
	digit: int,
	val_min, val_max: f32,
	color: [4]f32,
	label: string,
	is_selected_digit := false,
) -> (changed: bool, clicked: bool) {
	rail_vec := rail_b - rail_a
	rail_len := linalg.length(rail_vec)
	if rail_len < 0.002 do return false, false
	rail_dir := rail_vec / rail_len

	v := handles.frame().view
	cam_dir: [3]f32
	if abs(v.proj[3, 3]) > 0.5 {
		cam_dir = linalg.normalize0([3]f32{v.view[2, 0], v.view[2, 1], v.view[2, 2]})
	} else {
		cam_dir = linalg.normalize0(v.cam_pos - (rail_a + rail_b) * 0.5)
	}
	if cam_dir == {} do cam_dir = {0, 0, 1}

	handles.with_snap(false)
	d := handles.segment(id, rail_a, rail_b, cam_dir, hover_px = 14.0, prio = 25)
	if d.started && _h3d_drag_id == 0 {
		_h3d_begin(driver, side, id, _slider_value(side, kind, digit), label)
		clicked = true
	}

	is_active := _h3d_drag_id == id
	if is_active {
		sa, oka := handles.project(rail_a)
		sb, okb := handles.project(rail_b)
		ab := sb - sa
		if l2 := linalg.dot(ab, ab); oka && okb && l2 > 4.0 {
			t := linalg.dot(handles.frame().input.mouse - _h3d_start_mouse, ab) / l2
			lo := math.min(val_min, _h3d_start_val)
			hi := math.max(val_max, _h3d_start_val)
			new_val := math.clamp(_h3d_start_val + t * (val_max - val_min), lo, hi)
			if abs(new_val - _h3d_last_val) > 0.0005 {
				_h3d_last_val = new_val
				side^ = _h3d_start_side
				_slider_apply(side, kind, digit, new_val)
				changed = true
			}
		}
		if !im.IsMouseDown(.Left) do _on_h3d_drag_lost(nil)
	}

	val := _h3d_last_val if is_active else _slider_value(side, kind, digit)
	t_norm := math.clamp((val - val_min) / math.max(val_max - val_min, 0.001), 0.0, 1.0)
	knob_pos := rail_a + rail_dir * (t_norm * rail_len)
	is_hot := d.hot || is_active

	// Track, filled part, knob (with 5% sleek slimming)
	track_alpha: f32 = 0.85 if (is_hot || is_selected_digit) else 0.60
	track_col := [4]f32{color.r * 0.45, color.g * 0.45, color.b * 0.45, track_alpha}
	_draw_thick_3d_bar(rail_a, rail_b, (2.8 if (is_hot || is_selected_digit) else 2.2) * 0.95, track_col, draw_caps = true)

	fill_col := handles.COLOR_HOT if is_hot else [4]f32{color.r, color.g, color.b, 0.98}
	if t_norm > 0.01 {
		_draw_thick_3d_bar(rail_a, knob_pos, (4.8 if is_hot else 3.8) * 0.95, fill_col)
	}

	knob_rad := handles.world_per_pixels(knob_pos, (7.5 if is_hot else (6.5 if is_selected_digit else 5.8)) * 0.95)
	px_k := handles.world_per_pixels(knob_pos, 1.1)

	// Outer black outline wrapping the white outline
	handles.dot_outlined(knob_pos, cam_dir, knob_rad + px_k * 1.5, {0.02, 0.02, 0.03, 0.95})
	handles.square_outline(knob_pos, (knob_rad + px_k * 1.5) * 1.15, {0.02, 0.02, 0.03, 0.95})

	// Crisp white outline
	handles.dot_outlined(knob_pos, cam_dir, knob_rad + px_k * 0.75, {1.0, 1.0, 1.0, 0.98})
	handles.square_outline(knob_pos, (knob_rad + px_k * 0.75) * 1.15, {1.0, 1.0, 1.0, 0.98})

	// Inner colored knob & hot accent
	handles.dot_outlined(knob_pos, cam_dir, knob_rad, fill_col)
	if is_hot || is_selected_digit {
		handles.square_outline(knob_pos, knob_rad * 1.15, handles.COLOR_HOT if is_hot else [4]f32{1, 1, 1, 0.98})
	}

	if is_hot {
		// Dark shadow backdrop for text
		gizmos.with_color({0.02, 0.02, 0.03, 0.95})
		gizmos.label(knob_pos, fmt.tprintf("%s: %d%%", label, int(math.round(val * 100.0))), align = {-0.5, 1.25}, offset_px = {1, -11}, scale = 0.92)
		gizmos.label(knob_pos, fmt.tprintf("%s: %d%%", label, int(math.round(val * 100.0))), align = {-0.5, 1.25}, offset_px = {-1, -13}, scale = 0.92)
		gizmos.with_color(handles.COLOR_HOT)
		gizmos.label(knob_pos, fmt.tprintf("%s: %d%%", label, int(math.round(val * 100.0))), align = {-0.5, 1.25}, offset_px = {0, -12}, scale = 0.92)
	} else {
		lbl_col := [4]f32{1.0, 1.0, 1.0, 1.0} if is_selected_digit else [4]f32{color.r, color.g, color.b, 0.95}
		gizmos.with_color({0.02, 0.02, 0.03, 0.92})
		gizmos.label(rail_a, label, align = {-0.5, 1.0}, offset_px = {1, -7}, scale = 0.78 if is_selected_digit else 0.74)
		gizmos.with_color(lbl_col)
		gizmos.label(rail_a, label, align = {-0.5, 1.0}, offset_px = {0, -8}, scale = 0.78 if is_selected_digit else 0.74)
	}
	return
}

@(private = "file")
_draw_hand_poses_3d_sliders :: proc(hpd: ^crig.HandPoseDriver) {
	if !hand_poses_show_3d_gizmos || hpd == nil || !hpd.enabled do return

	// Once per frame: a character with several ArmatureDeformedMesh parts calls in once per part.
	frame := im.GetFrameCount()
	if _h3d_drawn_frame == frame do return
	_h3d_drawn_frame = frame

	// A drag released while the sliders were hidden (mode switch) closes here.
	if _h3d_drag_id != 0 && !im.IsMouseDown(.Left) do _on_h3d_drag_lost(nil)

	w := engine.ctx_world()
	if w == nil do return

	edit_left := hand_poses_active_left || hpd.mirror_hands
	side  := &hpd.left if edit_left else &hpd.right
	calib := &hpd.left_calib if edit_left else &hpd.right_calib

	if !calib.bound || calib.hand_bone == {} || !engine.pool_valid(&w.transforms, engine.Handle(calib.hand_bone)) do return

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	hand_wpos := engine.transform_world_position(calib.hand_bone)
	hand_wrot := crig.safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(calib.hand_bone)))

	palmar_w := linalg.quaternion128_mul_vector3(hand_wrot, calib.palm_inward_local)
	distal_w := linalg.quaternion128_mul_vector3(hand_wrot, calib.distal_local)
	radial_w := linalg.quaternion128_mul_vector3(hand_wrot, calib.radial_local)

	changed := false

	// -------------------------------------------------------------------------
	// A. 4 PER-FINGER 3D CURL RAILS (Parented directly to each finger's base knuckle!)
	//    Rail start = finger open (above knuckle), rail end = curled toward palm.
	//    Clicking/dragging curls that finger AND selects it so its per-joint
	//    3D sliders appear directly on that finger's joints!
	// -------------------------------------------------------------------------
	finger_labels := [4]string{"Index", "Middle", "Ring", "Pinky"}
	finger_colors := [4][4]f32{
		{0.25, 0.88, 1.00, 1.0}, // Index: Cyan
		{0.30, 0.98, 0.55, 1.0}, // Middle: Mint Green
		{1.00, 0.78, 0.20, 1.0}, // Ring: Amber
		{1.00, 0.42, 0.82, 1.0}, // Pinky: Pink
	}

	for f in 0 ..< 4 {
		d := f + 1 // digit 1..4
		knuckle_h := calib.phalanges[d][0]
		if knuckle_h == {} do continue
		k_wpos := engine.transform_world_position(knuckle_h)
		is_sel := (_active_3d_digit == d)

		rail_a := k_wpos + distal_w * 0.095 - palmar_w * 0.032
		rail_b := k_wpos + distal_w * 0.015 + palmar_w * 0.055

		// Subtle leader line connecting the knuckle bone directly to its 3D rail with shadow
		col := finger_colors[f]
		gizmos.with_color({0.02, 0.02, 0.03, 0.85})
		gizmos.line(k_wpos, rail_a)
		gizmos.with_color({col.r, col.g, col.b, 0.75 if is_sel else 0.40})
		gizmos.line(k_wpos, rail_a)

		c, clicked := _draw_3d_slider_rail(
			hpd,
			side,
			handles.id_of(hpd.owner, u64(0x8800 + d)),
			rail_a,
			rail_b,
			.Digit_Master,
			d,
			-0.30,
			1.25,
			col,
			finger_labels[f],
			is_sel,
		)
		if clicked do _active_3d_digit = d
		if c do changed = true

		// Per-joint 3D sliders parented to each phalanx joint of the active selected finger!
		if is_sel {
			j_kinds  := [3]_Slider_Kind{.Finger_Base, .Finger_Mid, .Finger_Tip}
			j_labels := [3]string{"MCP", "PIP", "DIP"}
			j_mins   := [3]f32{-0.45, -0.35, -0.35}
			for p in 0 ..< 3 {
				jh := calib.phalanges[d][p]
				if jh == {} do continue
				j_wpos := engine.transform_world_position(jh)
				ja := j_wpos - palmar_w * 0.024
				jb := j_wpos + palmar_w * 0.026
				if cj, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, u64(0x8840 + d * 8 + p)), ja, jb, j_kinds[p], d, j_mins[p], 1.30, col, j_labels[p]); cj {
					changed = true
				}
			}
			// Splay rail across the base knuckle along the radial/ulnar axis
			sp_a := k_wpos + radial_w * 0.024 - palmar_w * 0.018
			sp_b := k_wpos - radial_w * 0.024 - palmar_w * 0.018
			if csp, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, u64(0x8840 + d * 8 + 3)), sp_a, sp_b, .Finger_Splay, d, -0.80, 0.80, col, "Splay"); csp {
				changed = true
			}
		}
	}

	// -------------------------------------------------------------------------
	// B. THUMB 3D SWEEP RAIL + CAMERA-FACING 2D THUMB AIM BOX (Anchored next to Thumb!)
	// -------------------------------------------------------------------------
	if calib.phalanges[0][0] != {} {
		t0_wpos := engine.transform_world_position(calib.phalanges[0][0])
		thumb_col := [4]f32{0.20, 1.00, 0.65, 1.0}
		is_thumb_sel := (_active_3d_digit == 0)

		t_rail_a := t0_wpos + radial_w * 0.065 - palmar_w * 0.015 + distal_w * 0.025
		t_rail_b := t0_wpos - radial_w * 0.015 + palmar_w * 0.060 + distal_w * 0.035
		c_tsw, clk_tsw := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8810), t_rail_a, t_rail_b, .Thumb_Sweep, 0, -0.40, 1.35, thumb_col, "Thumb Sweep", is_thumb_sel)
		if clk_tsw do _active_3d_digit = 0
		if c_tsw do changed = true

		// When the thumb is selected, show Roll, Mid, and Tip 3D sliders right on the thumb joints!
		if is_thumb_sel {
			// Roll rail at thumb base
			r_a := t0_wpos - palmar_w * 0.028
			r_b := t0_wpos + palmar_w * 0.028
			if cr, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8831), r_a, r_b, .Thumb_Roll, 0, -1.00, 1.40, thumb_col, "Roll"); cr {
				changed = true
			}
			if calib.phalanges[0][1] != {} {
				t1_wpos := engine.transform_world_position(calib.phalanges[0][1])
				m_a := t1_wpos + radial_w * 0.024 - palmar_w * 0.015
				m_b := t1_wpos - radial_w * 0.015 + palmar_w * 0.028
				if cm, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8832), m_a, m_b, .Thumb_Mid, 0, -0.40, 1.30, thumb_col, "Mid"); cm {
					changed = true
				}
			}
			if calib.phalanges[0][2] != {} {
				t2_wpos := engine.transform_world_position(calib.phalanges[0][2])
				tp_a := t2_wpos + radial_w * 0.022 - palmar_w * 0.015
				tp_b := t2_wpos - radial_w * 0.015 + palmar_w * 0.026
				if ct, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8833), tp_a, tp_b, .Thumb_Tip, 0, -0.40, 1.30, thumb_col, "Tip"); ct {
					changed = true
				}
			}
		}

		// Camera-Facing (Billboard) 2D Thumb Aim Box anchored right next to `thumb_01` (`t0_wpos`)!
		// Its center stays locked next to the thumb in 3D space, while its 2D square plane uses
		// `(cam_right, cam_up)` so it ALWAYS faces the camera from every angle!
		pad_center := t0_wpos + radial_w * 0.055 - distal_w * 0.015
		pad_radius: f32 = 0.030 * 0.95
		pad_id := handles.id_of(hpd.owner, 0x8811)

		vm := handles.frame().view.view
		cam_right := crig.safe_normalize([3]f32{vm[0, 0], vm[0, 1], vm[0, 2]}, {1, 0, 0})
		cam_up    := crig.safe_normalize([3]f32{vm[1, 0], vm[1, 1], vm[1, 2]}, {0, 1, 0})
		cam_fwd   := crig.safe_normalize([3]f32{vm[2, 0], vm[2, 1], vm[2, 2]}, {0, 0, 1})

		c0 := pad_center - cam_right * pad_radius - cam_up * pad_radius
		c1 := pad_center + cam_right * pad_radius - cam_up * pad_radius
		c2 := pad_center + cam_right * pad_radius + cam_up * pad_radius
		c3 := pad_center - cam_right * pad_radius + cam_up * pad_radius
		box_corners := [4][3]f32{c0, c1, c2, c3}

		// Leader line from thumb_01 to the 2D Thumb Box center with dark shadow
		gizmos.with_color({0.02, 0.02, 0.03, 0.85})
		gizmos.line(t0_wpos, pad_center)
		gizmos.with_color({0.25, 0.95, 0.88, 0.65})
		gizmos.line(t0_wpos, pad_center)

		handles.with_snap(false)
		d_pad := handles.area(pad_id, pad_center, cam_fwd, box_corners[:], prio = 26)
		if d_pad.started && _h3d_drag_id == 0 {
			_h3d_begin(hpd, side, pad_id, 0, "3D Thumb Aim Pad")
			_active_3d_digit = 0
		}

		is_pad_active := _h3d_drag_id == pad_id
		if is_pad_active {
			sc, okc := handles.project(pad_center)
			sx, okx := handles.project(pad_center + cam_right * pad_radius)
			sy, oky := handles.project(pad_center + cam_up * pad_radius)
			if okc && okx && oky {
				vx := sx - sc
				vy := sy - sc
				lx2 := linalg.dot(vx, vx)
				ly2 := linalg.dot(vy, vy)
				rel := handles.frame().input.mouse - _h3d_start_mouse
				start := _h3d_start_side.pose.thumb_pos_2d
				p := start
				if lx2 > 2.0 do p.x = math.clamp(start.x + linalg.dot(rel, vx) / lx2, -1.0, 1.0)
				if ly2 > 2.0 do p.y = math.clamp(start.y + linalg.dot(rel, vy) / ly2, -1.0, 1.0)
				if p != side.pose.thumb_pos_2d {
					side.pose.thumb_pos_2d = p
					side.preset = .Custom
					changed = true
				}
			}
			if !im.IsMouseDown(.Left) do _on_h3d_drag_lost(nil)
		}

		// Draw after the update so the dot sits under the cursor this frame.
		dot_wpos := pad_center + cam_right * (math.clamp(side.pose.thumb_pos_2d.x, -1.0, 1.0) * pad_radius) +
		                         cam_up    * (math.clamp(side.pose.thumb_pos_2d.y, -1.0, 1.0) * pad_radius)

		is_pad_hot := d_pad.hot || is_pad_active
		gizmos.with_color({0.04, 0.07, 0.10, 0.75 if is_pad_hot else 0.55})
		gizmos.solid_quad(box_corners)

		px_pad := handles.world_per_pixels(pad_center, 1.2)

		// Outer black border wrapping the white outline
		r_black := pad_radius + px_pad * 1.6
		b_black := [4][3]f32{
			pad_center - cam_right * r_black - cam_up * r_black,
			pad_center + cam_right * r_black - cam_up * r_black,
			pad_center + cam_right * r_black + cam_up * r_black,
			pad_center - cam_right * r_black + cam_up * r_black,
		}
		gizmos.with_color({0.02, 0.02, 0.03, 0.95})
		gizmos.wire_quad(b_black)

		// Crisp white border
		r_white := pad_radius + px_pad * 0.8
		b_white := [4][3]f32{
			pad_center - cam_right * r_white - cam_up * r_white,
			pad_center + cam_right * r_white - cam_up * r_white,
			pad_center + cam_right * r_white + cam_up * r_white,
			pad_center - cam_right * r_white + cam_up * r_white,
		}
		gizmos.with_color({0.98, 0.98, 1.00, 0.92})
		gizmos.wire_quad(b_white)

		// Center crosshairs inside the camera-facing 2D box
		gizmos.with_color({0.02, 0.02, 0.03, 0.75})
		gizmos.line(pad_center - cam_right * pad_radius + cam_up * px_pad, pad_center + cam_right * pad_radius + cam_up * px_pad)
		gizmos.line(pad_center - cam_up * pad_radius + cam_right * px_pad, pad_center + cam_up * pad_radius + cam_right * px_pad)
		gizmos.with_color({0.25, 0.95, 0.88, 0.65})
		gizmos.line(pad_center - cam_right * pad_radius, pad_center + cam_right * pad_radius)
		gizmos.line(pad_center - cam_up * pad_radius, pad_center + cam_up * pad_radius)

		handles.rect_outlined(box_corners, handles.COLOR_HOT if is_pad_hot else [4]f32{0.25, 0.95, 0.88, 0.95})
		_draw_thick_3d_bar(pad_center, dot_wpos, 2.2, {0.25, 0.95, 0.88, 0.90})

		// Knob dot: outer black + crisp white + colored center
		pad_col      := handles.COLOR_HOT if is_pad_hot else [4]f32{0.20, 0.95, 1.0, 1.0}
		pad_knob_rad := handles.world_per_pixels(dot_wpos, 7.8 if is_pad_hot else 6.2) * 0.95
		handles.dot_outlined(dot_wpos, cam_fwd, pad_knob_rad + px_pad * 1.5, {0.02, 0.02, 0.03, 0.95})
		handles.dot_outlined(dot_wpos, cam_fwd, pad_knob_rad + px_pad * 0.75, {1.0, 1.0, 1.0, 0.98})
		handles.dot_outlined(dot_wpos, cam_fwd, pad_knob_rad, pad_col)

		// Label with dark shadow
		gizmos.with_color({0.02, 0.02, 0.03, 0.92})
		gizmos.label(
			pad_center + cam_up * pad_radius,
			fmt.tprintf("Thumb 2D (%.2f, %.2f)", side.pose.thumb_pos_2d.x, side.pose.thumb_pos_2d.y) if is_pad_hot else "Thumb 2D",
			align = {-0.5, 1.15},
			offset_px = {1, -5},
			scale = 0.80,
		)
		gizmos.with_color(handles.COLOR_HOT if is_pad_hot else [4]f32{0.25, 0.98, 0.65, 0.95})
		gizmos.label(
			pad_center + cam_up * pad_radius,
			fmt.tprintf("Thumb 2D (%.2f, %.2f)", side.pose.thumb_pos_2d.x, side.pose.thumb_pos_2d.y) if is_pad_hot else "Thumb 2D",
			align = {-0.5, 1.15},
			offset_px = {0, -6},
			scale = 0.80,
		)
	}

	// -------------------------------------------------------------------------
	// C. HAND-LEVEL 3D MACRO RAILS ABOVE THE BACK OF THE WRIST (Fist, Claw, Spread)
	// -------------------------------------------------------------------------
	dorsal_base := hand_wpos - palmar_w * 0.055 - distal_w * 0.015

	mcurl_a := dorsal_base + radial_w * 0.040 - distal_w * 0.035
	mcurl_b := dorsal_base + radial_w * 0.040 + distal_w * 0.055
	if c, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8820), mcurl_a, mcurl_b, .Master_Curl, 0, -0.25, 1.25, {1.00, 0.85, 0.20, 1.0}, "Fist"); c {
		changed = true
	}

	mclaw_a := dorsal_base - radial_w * 0.005 - distal_w * 0.035
	mclaw_b := dorsal_base - radial_w * 0.005 + distal_w * 0.055
	if c, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8821), mclaw_a, mclaw_b, .Master_Claw, 0, 0.00, 1.20, {1.00, 0.50, 0.15, 1.0}, "Claw"); c {
		changed = true
	}

	mspr_a := dorsal_base - radial_w * 0.050 - distal_w * 0.055
	mspr_b := dorsal_base + radial_w * 0.050 - distal_w * 0.055
	if c, _ := _draw_3d_slider_rail(hpd, side, handles.id_of(hpd.owner, 0x8822), mspr_a, mspr_b, .Master_Spread, 0, -0.80, 1.00, {0.35, 0.95, 0.40, 1.0}, "Spread"); c {
		changed = true
	}

	if changed {
		crig.hand_pose_driver_evaluate(hpd, 0.0)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
}

// =============================================================================
// 3D VIEWPORT VISUALIZER FOR MODE: HAND POSES
// =============================================================================

@(private = "file")
_draw_single_hand_gizmos :: proc(
	calib: ^crig.Hand_Calibrated_Bones,
	is_active_hand: bool,
	is_left: bool,
) {
	if !calib.bound || calib.hand_bone == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(calib.hand_bone)) do return

	base_col: [4]f32
	if is_active_hand {
		base_col = {0.20, 0.85, 1.00, 0.95} if is_left else {1.00, 0.45, 0.25, 0.95}
	} else {
		base_col = {0.20, 0.65, 0.80, 0.55} if is_left else {0.80, 0.40, 0.25, 0.55}
	}

	hand_wpos := engine.transform_world_position(calib.hand_bone)
	gizmos.with_color({0.02, 0.02, 0.03, 0.85})
	gizmos.wire_sphere(hand_wpos, 0.0135, segments = 10)
	gizmos.with_color({0.98, 0.98, 1.00, 0.85})
	gizmos.wire_sphere(hand_wpos, 0.0128, segments = 10)
	gizmos.with_color(base_col)
	gizmos.wire_sphere(hand_wpos, 0.0120, segments = 10)

	// Draw all 5 digits (Thumb + 4 Fingers) with thick 3D phalanx bars
	for d in 0 ..< 5 {
		p0_h := calib.phalanges[d][0]
		if p0_h == {} do continue

		p0_pos := engine.transform_world_position(p0_h)
		palm_col := base_col
		palm_col.a *= 0.55
		_draw_thick_3d_bar(hand_wpos, p0_pos, 1.6, palm_col)

		digit_col := [4]f32{0.30, 0.95, 0.60, base_col.a} if d == 0 else base_col
		gizmos.with_color(digit_col)

		for p in 0 ..< 3 {
			bh := calib.phalanges[d][p]
			if bh == {} do continue
			bpos := engine.transform_world_position(bh)
			// Knuckle joint sphere: outer black outline + white ring + colored sphere
			gizmos.with_color({0.02, 0.02, 0.03, 0.85})
			gizmos.wire_sphere(bpos, 0.0078, segments = 8)
			gizmos.with_color({0.98, 0.98, 1.00, 0.85})
			gizmos.wire_sphere(bpos, 0.0074, segments = 8)
			gizmos.with_color(digit_col)
			gizmos.wire_sphere(bpos, 0.0068, segments = 8)

			if p < 2 && calib.phalanges[d][p + 1] != {} {
				next_pos := engine.transform_world_position(calib.phalanges[d][p + 1])
				_draw_thick_3d_bar(bpos, next_pos, 2.2 if is_active_hand else 1.5, digit_col)
			} else if p == 2 {
				tip_pos: [3]f32
				has_tip := false
				if calib.leaf_tips[d] != {} {
					tip_pos = engine.transform_world_position(calib.leaf_tips[d])
					has_tip = true
				} else {
					brot := linalg.quaternion_normalize(engine.quat_to_native(engine.transform_world_rotation(bh)))
					tip_pos = bpos + linalg.quaternion128_mul_vector3(brot, [3]f32{0, calib.segment_length[d][2], 0})
					has_tip = true
				}
				if has_tip {
					_draw_thick_3d_bar(bpos, tip_pos, 2.0 if is_active_hand else 1.4, digit_col)
					gizmos.with_color({0.02, 0.02, 0.03, 0.85})
					gizmos.wire_sphere(tip_pos, 0.0062, segments = 8)
					gizmos.with_color({0.98, 0.98, 1.00, 0.85})
					gizmos.wire_sphere(tip_pos, 0.0058, segments = 8)
					gizmos.with_color(digit_col)
					gizmos.wire_sphere(tip_pos, 0.0055, segments = 8)
				}
			}
		}
	}

	// Draw the Dynamic Morphing Hand BoxCollider!
	if hand_poses_show_box_collider {
		_, box := engine.transform_get_comp(calib.hand_bone, physics3d.BoxCollider)
		if box != nil {
			wire_col  := [4]f32{0.25, 0.95, 0.45, 0.95} if is_active_hand else [4]f32{0.25, 0.85, 0.45, 0.55}
			solid_col := [4]f32{wire_col.r, wire_col.g, wire_col.b, 0.22 if is_active_hand else 0.12}
			physics3d.draw_box_collider_solid(box, solid_col)
			physics3d.draw_box_collider_wires(box, wire_col)
		}
	}
}

draw_hand_poses_viewport_gizmos :: proc(target_owner: engine.Transform_Handle) {
	if scene_viewport_mode != .Control_Rig || character_edit_mode != .Hand_Poses do return
	if target_owner == {} do return
	w := engine.ctx_world()
	if w == nil do return

	hpd := ensure_character_hand_pose_driver(target_owner)
	if hpd == nil do return

	crig.hand_pose_driver_ensure_bound(hpd)

	// Run interactive 3D hand slider handles during the Scene View pass (channel == .Editor)
	// so they work regardless of whether the character node is selected in the hierarchy!
	if gizmos.channel() == .Editor {
		_draw_hand_poses_3d_sliders(hpd)
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	left_active  := hand_poses_active_left || hpd.mirror_hands
	right_active := !hand_poses_active_left || hpd.mirror_hands

	_draw_single_hand_gizmos(&hpd.left_calib, left_active, true)
	_draw_single_hand_gizmos(&hpd.right_calib, right_active, false)
}
