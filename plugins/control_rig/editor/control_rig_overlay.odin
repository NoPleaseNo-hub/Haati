package control_rig_editor

// Control Rig Scene Viewport Overlay & Mode Switcher.
// Provides Unreal Engine-style viewport top-bar mode switching and Control Rig on-scene toggles:
// 1. Mode Dropdown: Default Scene Mode vs Control Rig Mode.
// 2. Bone Editing: One-click toggle between Mesh Mode and Bone Mode.
// 3. Rig Controls: Toggle 3D interactive shapes representing Hands, Feet, Pelvis, and Pole vectors.
// 4. Collider Editing: View and adjust bone hitboxes and ragdoll colliders live.
// 5. Drive IK: One-click toggle to allow IK solvers to drive the skeleton.
// 6. Reset T-Pose: Restore authentic bind pose geometry for all humanoid bones.

import "core:fmt"
import "core:strings"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:encoding/uuid"
import im "haati:external/odin-imgui"
import engine "haati:engine"
import "haati:engine/gizmos"
import "haati:editor/handles"
import icons "haati:editor/icons"
import thm "haati:editor/theme"
import widgets "haati:editor/widgets"
import undo "haati:editor/undo"
import crig "haati:packages/control_rig"
import cad_csg "haati:packages/cad_csg"
import physics3d "haati:packages/physics3d"

@(private="file")
_slider_undo_sess:   undo.Edit_Session
@(private="file")
_slider_undo_active: bool

@(private="file")
_begin_slider_undo :: proc(rig: ^crig.ControlRig, label: string) {
	if im.IsItemActivated() {
		owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
		_slider_undo_sess = undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, label)
		_slider_undo_active = true
	}
}

@(private="file")
_end_slider_undo :: proc() {
	if _slider_undo_active && im.IsItemDeactivatedAfterEdit() {
		undo.edit_session_end(&_slider_undo_sess)
		_slider_undo_active = false
	}
}

@(private="file")
_bone_undo_sess:   undo.Edit_Session
@(private="file")
_bone_undo_active: bool

@(private="file")
_begin_slider_undo_bone :: proc(bone_h: engine.Transform_Handle, label: string) {
	if im.IsItemActivated() {
		w := engine.ctx_world()
		if w != nil && bone_h != {} && engine.pool_valid(&w.transforms, engine.Handle(bone_h)) {
			_bone_undo_sess = undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, label)
			_bone_undo_active = true
		}
	}
}

@(private="file")
_begin_slider_undo_comp :: proc(h: engine.Handle, label: string) {
	if im.IsItemActivated() {
		if h != {} {
			_bone_undo_sess = undo.edit_session_begin({undo.edit_target_whole(h)}, label)
			_bone_undo_active = true
		}
	}
}

@(private="file")
_end_slider_undo_bone :: proc() {
	if _bone_undo_active && im.IsItemDeactivatedAfterEdit() {
		undo.edit_session_end(&_bone_undo_sess)
		_bone_undo_active = false
	}
}

Scene_Viewport_Mode :: enum {
	Default,
	Control_Rig,
	UI_Canvas,
	CAD_Blockout,
}

scene_viewport_mode:     Scene_Viewport_Mode = .Default
request_frame_ui_canvas: bool = false

Character_Edit_Mode :: enum {
	Bone_Mode,     // Direct skeleton joint articulation & rest pose editing
	Rig_Controls,  // Posing with Control Rig IK handles (pelvis, hands, feet, look-at)
	Hand_Poses,    // Calibrated Hand Pose Driver & Dynamic Morphing Hand BoxCollider authoring
	Colliders,     // Physics hitbox & ragdoll collider generation, sizing, and editing
}

character_edit_mode: Character_Edit_Mode = .Rig_Controls

// Control Rig on-scene toggles
show_rig_controls:   bool = true
show_bone_colliders: bool = true
show_all_rig_labels: bool = false

// Synchronized viewport gizmo tool state (bridged cleanly with editor/gizmo.odin)
current_gizmo_tool: handles.Tool = .Translate
@(private = "file") _has_requested_gizmo_tool: bool = false
@(private = "file") _requested_gizmo_tool:     handles.Tool = .Translate

request_gizmo_tool :: proc(t: handles.Tool) {
	_requested_gizmo_tool = t
	_has_requested_gizmo_tool = true
	current_gizmo_tool = t
}

consume_requested_gizmo_tool :: proc() -> (handles.Tool, bool) {
	if _has_requested_gizmo_tool {
		_has_requested_gizmo_tool = false
		return _requested_gizmo_tool, true
	}
	return current_gizmo_tool, false
}

Collider_Shading_Mode :: enum {
	Semi_Transparent, // Translucent solid volume + crisp wireframe edges (Unreal PhAT style)
	Wireframe,        // Wireframe outline only
	Solid_Only,       // Translucent solid volume only
}

collider_shading_mode: Collider_Shading_Mode = .Semi_Transparent
collider_solid_alpha:  f32 = 0.35

// Bone Mode & Skinning Tool state
bone_falloff_radius:     f32 = 0.12
bone_falloff_max_weight: f32 = 0.85
spring_stiffness:        f32 = 45.0
spring_damping:          f32 = 8.0
spring_max_angle_deg:    f32 = 35.0
spring_gravity_y:        f32 = -2.5
new_bone_name_buf:       [64]u8
new_bone_offset:         [3]f32 = {0.0, 0.04, 0.08}
bone_rename_buf:         [64]u8
bone_rename_tracked_h:   engine.Transform_Handle = {}

@(private = "file")
_activate_rig_and_solver :: proc(rig: ^crig.ControlRig) {
	if rig == nil do return
	rig.active = true
	if _, s := engine.transform_get_comp(rig.owner, crig.HumanoidIkSolver); s != nil {
		s.active = true
	}
}

Active_Rig_Control :: enum {
	Pelvis,
	Spine,
	Chest,
	Head,
	Eye_Level_Socket,
	Look_At,
	Left_Foot,
	Right_Foot,
	Left_Toe,
	Right_Toe,
	Left_Knee_Pole,
	Right_Knee_Pole,
	Left_Hand,
	Right_Hand,
	Left_Elbow_Pole,
	Right_Elbow_Pole,
}

active_character_owner: engine.Transform_Handle = {}
selected_rig_owner:     engine.Transform_Handle = {}

get_active_character_owner :: proc() -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil do return {}
	if active_character_owner != {} &&
	   engine.pool_valid(&w.transforms, engine.Handle(active_character_owner)) &&
	   engine.transform_active_in_hierarchy(active_character_owner) {
		return active_character_owner
	}
	return {}
}

set_active_character_owner :: proc(owner_h: engine.Transform_Handle) {
	if active_character_owner != owner_h {
		active_character_owner = owner_h
		if selected_rig_owner != owner_h {
			clear_rig_selection()
		}
	}
}

selected_rig_controls: bit_set[Active_Rig_Control]
active_rig_control: Active_Rig_Control = .Pelvis

select_rig_control :: proc(owner_h: engine.Transform_Handle, ctrl: Active_Rig_Control, multi: bool) {
	if selected_rig_owner != owner_h {
		selected_rig_controls = {}
		selected_rig_owner = owner_h
		set_active_character_owner(owner_h)
	}
	if multi {
		if ctrl in selected_rig_controls {
			selected_rig_controls -= {ctrl}
		} else {
			selected_rig_controls += {ctrl}
		}
	} else {
		selected_rig_controls = {ctrl}
	}
	active_rig_control = ctrl
	if owner_h != {} && engine.inspector_active_selection() != owner_h {
		engine.inspector_request_select(owner_h)
	}
}

is_rig_control_selected :: proc(owner_h: engine.Transform_Handle, ctrl: Active_Rig_Control) -> bool {
	if selected_rig_owner != owner_h do return false
	return ctrl in selected_rig_controls
}

clear_rig_selection :: proc() {
	selected_rig_controls = {}
	selected_rig_owner = {}
}

active_rig_control_count :: proc(owner_h: engine.Transform_Handle) -> int {
	if selected_rig_owner != owner_h do return 0
	return card(selected_rig_controls)
}

@(scene_overlay={id="Modes", order=-100})
draw_control_rig_mode_overlay :: proc(vertical: bool) {
	w := engine.ctx_world()
	if w == nil do return

	if crig.smart_rig_async_state.active {
		crig.smart_rig_async_tick(0.016)
	}

	// 1. Resolve active character actor or armature
	active_h := engine.inspector_active_selection()
	target_adm: ^crig.ArmatureDeformedMesh = nil
	target_rig: ^crig.ControlRig = nil
	target_owner: engine.Transform_Handle = {}

	if active_h != {} && engine.pool_valid(&w.transforms, engine.Handle(active_h)) && engine.transform_active_in_hierarchy(active_h) {
		_, adm := engine.transform_get_comp(active_h, crig.ArmatureDeformedMesh)
		_, rig := engine.transform_get_comp(active_h, crig.ControlRig)
		if adm != nil || rig != nil {
			set_active_character_owner(active_h)
		} else {
			// Check if active selection is a bone belonging to an ArmatureDeformedMesh
			it := engine.pool_iterator(crig.armature_deformed_meshes(w))
			for candidate, _ in engine.pool_next(&it) {
				cand_owner := engine.Transform_Handle(candidate.owner)
				if !engine.transform_active_in_hierarchy(cand_owner) do continue
				for j in candidate.joints {
					if j == active_h {
						set_active_character_owner(cand_owner)
						break
					}
				}
				if active_character_owner == cand_owner do break
			}
		}
	}

	// Use active character owner if valid
	active_owner := get_active_character_owner()
	if active_owner != {} {
		target_owner = active_owner
		_, target_adm = engine.transform_get_comp(target_owner, crig.ArmatureDeformedMesh)
		_, target_rig = engine.transform_get_comp(target_owner, crig.ControlRig)
	}

	// Fallback to first enabled AND active-in-hierarchy character in scene if none selected
	if target_owner == {} || (target_adm == nil && target_rig == nil) {
		it := engine.pool_iterator(crig.armature_deformed_meshes(w))
		for candidate, _ in engine.pool_next(&it) {
			cand_owner := engine.Transform_Handle(candidate.owner)
			if candidate.enabled && engine.transform_active_in_hierarchy(cand_owner) {
				target_adm = candidate
				target_owner = cand_owner
				_, r := engine.transform_get_comp(target_owner, crig.ControlRig)
				target_rig = r
				set_active_character_owner(target_owner)
				break
			}
		}
		if target_owner == {} {
			rit := engine.pool_iterator(crig.control_rigs(w))
			for candidate, _ in engine.pool_next(&rit) {
				cand_owner := engine.Transform_Handle(candidate.owner)
				if candidate.enabled && engine.transform_active_in_hierarchy(cand_owner) {
					target_rig = candidate
					target_owner = cand_owner
					_, adm := engine.transform_get_comp(target_owner, crig.ArmatureDeformedMesh)
					target_adm = adm
					set_active_character_owner(target_owner)
					break
				}
			}
		}
	}

	// -------------------------------------------------------------
	// UNREAL / GODOT-STYLE MODE DROPDOWN SELECTOR (ANTIGRAVITY STUDIO THEME)
	// -------------------------------------------------------------
	pal := thm.palette()
	if scene_viewport_mode == .UI_Canvas {
		scene_viewport_mode = .Default
	}
	mode_label: cstring = "Modes: Default Scene"
	if scene_viewport_mode == .Control_Rig {
		mode_label = "Modes: Control Rig"
	} else if scene_viewport_mode == .CAD_Blockout {
		mode_label = "Modes: CAD Blockout & CSG"
	}
	mode_active := (scene_viewport_mode != .Default)

	if scene_viewport_mode == .Control_Rig {
		im.PushStyleColorImVec4(.Button, thm.with_alpha(pal.accent, 0.24))
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(pal.accent, 0.36))
		im.PushStyleColorImVec4(.ButtonActive, thm.with_alpha(pal.accent, 0.48))
	} else if scene_viewport_mode == .CAD_Blockout {
		im.PushStyleColorImVec4(.Button, thm.with_alpha(pal.status_warning, 0.24))
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(pal.status_warning, 0.36))
		im.PushStyleColorImVec4(.ButtonActive, thm.with_alpha(pal.status_warning, 0.48))
	}

	if im.Button(fmt.ctprintf("%s %s ##ViewportModeBtn", icons.ICON_MD_EXPAND_MORE, mode_label)) {
		im.OpenPopup("##viewport_modes_popup")
	}
	modes_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
	widgets.tooltip("Viewport Interaction Mode (Unreal Style): Switch between Default 3D Scene, Control Rig character studio, and CAD Blockout & Destructible CSG Mode")

	if mode_active {
		im.PopStyleColor(3)
	}

	im.SetNextWindowPos(modes_popup_pos, .Appearing)
	if im.BeginPopup("##viewport_modes_popup") {
		if im.Selectable("Default Scene Mode (Actor Transform & Level Placement)", scene_viewport_mode == .Default) {
			scene_viewport_mode = .Default
			clear_rig_selection()
			if target_owner != {} && target_adm != nil && active_h != {} && active_h != target_owner {
				for j in target_adm.joints {
					if j == active_h {
						engine.inspector_request_select(target_owner)
						break
					}
				}
			}
		}
		if im.Selectable("Control Rig Mode (Character Posing, Animation & Rigging)", scene_viewport_mode == .Control_Rig) {
			scene_viewport_mode = .Control_Rig
		}
		if im.Selectable("CAD Blockout & CSG Mode (AutoCAD Precision Blockout & Red Faction CSG)", scene_viewport_mode == .CAD_Blockout) {
			scene_viewport_mode = .CAD_Blockout
			clear_rig_selection()
		}
		im.EndPopup()
	}

	// -------------------------------------------------------------
	// CONTROL RIG SUBSECTION (STRICTLY IN CONTROL RIG MODE ONLY!)
	// -------------------------------------------------------------
	if scene_viewport_mode == .Control_Rig {
		im.SameLine(0, 6)
		im.TextColored(pal.text_muted, "|")
		im.SameLine(0, 6)

		curr_char_name := "None"
		if target_owner != {} {
			if bt := engine.pool_get(&w.transforms, engine.Handle(target_owner)); bt != nil {
				curr_char_name = bt.name
			}
		}

		im.PushStyleColorImVec4(.Button, pal.bg_elevated)
		im.PushStyleColorImVec4(.ButtonHovered, pal.bg_hover)
		if im.Button(fmt.ctprintf("%s Active: %s %s ##ActiveCharBtn", icons.ICON_MD_ACCOUNT_TREE, curr_char_name, icons.ICON_MD_EXPAND_MORE)) {
			im.OpenPopup("##active_char_popup")
		}
		active_char_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
		im.PopStyleColor(2)
		widgets.tooltip("Active Character Mesh: Select which character is currently active for posing, bone editing, and physics colliders.\nOnly the active character mesh accepts rig controls and shows handles.")

		im.SetNextWindowPos(active_char_popup_pos, .Appearing)
		if im.BeginPopup("##active_char_popup") {
			Character_Entry :: struct {
				handle: engine.Transform_Handle,
				name:   string,
			}
			char_list := make([dynamic]Character_Entry, context.temp_allocator)

			it := engine.pool_iterator(crig.armature_deformed_meshes(w))
			for candidate, _ in engine.pool_next(&it) {
				h := engine.Transform_Handle(candidate.owner)
				if h != {} && engine.pool_valid(&w.transforms, engine.Handle(h)) {
					c_name := "Character"
					if bt := engine.pool_get(&w.transforms, engine.Handle(h)); bt != nil {
						c_name = bt.name
					}
					append(&char_list, Character_Entry{handle = h, name = c_name})
				}
			}
			rit := engine.pool_iterator(crig.control_rigs(w))
			for candidate, _ in engine.pool_next(&rit) {
				h := engine.Transform_Handle(candidate.owner)
				already := false
				for entry in char_list {
					if entry.handle == h { already = true; break }
				}
				if !already && h != {} && engine.pool_valid(&w.transforms, engine.Handle(h)) {
					c_name := "Rig Actor"
					if bt := engine.pool_get(&w.transforms, engine.Handle(h)); bt != nil {
						c_name = bt.name
					}
					append(&char_list, Character_Entry{handle = h, name = c_name})
				}
			}

			if len(char_list) == 0 {
				im.TextDisabled("No character meshes found in scene")
			} else {
				for entry in char_list {
					is_active := (entry.handle == target_owner)
					if im.Selectable(fmt.ctprintf("%s %s", icons.ICON_MD_ACCOUNT_TREE, entry.name), is_active) {
						set_active_character_owner(entry.handle)
						target_owner = entry.handle
						_, target_adm = engine.transform_get_comp(target_owner, crig.ArmatureDeformedMesh)
						_, target_rig = engine.transform_get_comp(target_owner, crig.ControlRig)
						engine.inspector_request_select(target_owner)
						clear_rig_selection()
						if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
					}
					if is_active do im.SetItemDefaultFocus()
				}
			}
			im.EndPopup()
		}

		im.SameLine(0, 4)

		// 1. Mutually Exclusive Character Edit Mode Dropdown Selector
		edit_mode_label: cstring = ""
		btn_tint: im.Vec4 = pal.bg_elevated
		switch character_edit_mode {
		case .Bone_Mode:
			edit_mode_label = fmt.ctprintf("%s Mode: Bones %s", icons.ICON_MD_ACCOUNT_TREE, icons.ICON_MD_EXPAND_MORE)
			btn_tint = thm.with_alpha(pal.status_success, 0.22)
		case .Rig_Controls:
			edit_mode_label = fmt.ctprintf("%s Mode: Rig Controls %s", icons.ICON_MD_WIDGETS, icons.ICON_MD_EXPAND_MORE)
			btn_tint = thm.with_alpha(pal.accent, 0.24)
		case .Hand_Poses:
			edit_mode_label = fmt.ctprintf("%s Mode: Hand Poses %s", icons.ICON_MD_TUNE, icons.ICON_MD_EXPAND_MORE)
			btn_tint = thm.with_alpha(pal.axis_w, 0.24)
		case .Colliders:
			edit_mode_label = fmt.ctprintf("%s Mode: Colliders %s", icons.ICON_MD_CROP_FREE, icons.ICON_MD_EXPAND_MORE)
			btn_tint = thm.with_alpha(pal.status_warning, 0.24)
		}

		im.PushStyleColorImVec4(.Button, btn_tint)
		im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(btn_tint, min(btn_tint.w + 0.14, 0.95)))
		if im.Button(edit_mode_label) {
			im.OpenPopup("##char_edit_mode_popup")
		}
		edit_mode_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
		im.PopStyleColor(2)
		widgets.tooltip("Switch Character Workspace Mode:\n- Bones: Articulate & view skeleton joints\n- Rig Controls: Pose using Control Rig IK handles\n- Hand Poses: Calibrated finger & thumb pose studio + Dynamic Hand BoxCollider\n- Colliders: PhAT-style hitbox & ragdoll authoring")

		im.SetNextWindowPos(edit_mode_popup_pos, .Appearing)
		if im.BeginPopup("##char_edit_mode_popup") {
			if im.Selectable(fmt.ctprintf("%s Bone Mode (Direct Skeleton Articulation)", icons.ICON_MD_ACCOUNT_TREE), character_edit_mode == .Bone_Mode) {
				character_edit_mode = .Bone_Mode
				show_rig_controls = false
				show_bone_colliders = false
				clear_rig_selection()
			}
			if im.Selectable(fmt.ctprintf("%s Rig Controls (IK Posing & Shape Styling)", icons.ICON_MD_WIDGETS), character_edit_mode == .Rig_Controls) {
				character_edit_mode = .Rig_Controls
				show_rig_controls = true
				show_bone_colliders = false
			}
			if im.Selectable(fmt.ctprintf("%s Hand Poses (Calibrated Fingers, Thumb Pad & Dynamic Hand BoxCollider)", icons.ICON_MD_TUNE), character_edit_mode == .Hand_Poses) {
				character_edit_mode = .Hand_Poses
				show_rig_controls = false
				show_bone_colliders = false
				clear_rig_selection()
			}
			if im.Selectable(fmt.ctprintf("%s Colliders (PhAT Ragdoll & Hitbox Setup)", icons.ICON_MD_CROP_FREE), character_edit_mode == .Colliders) {
				character_edit_mode = .Colliders
				show_rig_controls = false
				show_bone_colliders = true
				clear_rig_selection()
			}
			im.EndPopup()
		}

		im.SameLine(0, 6)

		// 2. Mode-Specific Top-Bar Tools
		switch character_edit_mode {
		case .Rig_Controls:
			// A. 1-Click Tool Mode Pills (Move / Rotate / Scale / Free Drag)
			_draw_rig_tool_pill :: proc(label: cstring, tip: cstring, tool_val: handles.Tool, is_active: bool, pal: thm.Theme_Palette) {
				if is_active {
					im.PushStyleColorImVec4(.Button, thm.with_alpha(pal.accent, 0.28))
					im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(pal.accent, 0.40))
					im.PushStyleColorImVec4(.Text, pal.text_primary)
				} else {
					im.PushStyleColorImVec4(.Button, pal.bg_elevated)
					im.PushStyleColorImVec4(.ButtonHovered, pal.bg_hover)
					im.PushStyleColorImVec4(.Text, pal.text_secondary)
				}
				if im.Button(label) {
					request_gizmo_tool(tool_val)
				}
				im.PopStyleColor(3)
				widgets.tooltip(tip)
				im.SameLine(0, 2)
			}

			eff_t := current_gizmo_tool
			if eff_t == .Picker do eff_t = .Translate
			_draw_rig_tool_pill("Move (W)##RigToolW", "Translate selected rig control(s) along 3D axes (Shortcut: W)", .Translate, eff_t == .Translate, pal)
			_draw_rig_tool_pill("Rotate (E)##RigToolE", "Rotate selected rig control(s) or roll toe hinge (Shortcut: E)", .Rotate, eff_t == .Rotate, pal)
			_draw_rig_tool_pill("Scale (R)##RigToolR", "Resize 3D visual control shape scale (Shortcut: R)", .Scale, eff_t == .Scale, pal)
			_draw_rig_tool_pill("Free Drag (T)##RigToolT", "Animator Screen-Plane Drag: Click and drag directly on any 3D control contour without axis arrows (Shortcut: T)", .Handles, eff_t == .Handles, pal)

			im.SameLine(0, 6)

			// B. Quick Rig Picker Dropdown (Select any control in 1 click even when occluded)
			if target_rig != nil {
				if im.Button(fmt.ctprintf("%s Controls %s##QuickRigPickBtn", icons.ICON_MD_WIDGETS, icons.ICON_MD_EXPAND_MORE)) {
					im.OpenPopup("##quick_rig_picker_popup")
				}
				pick_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
				widgets.tooltip("Quick Control Selector & Symmetry Tools: Select occluded rig controls in one click or mirror poses left/right.")
				im.SameLine(0, 4)

				im.SetNextWindowPos(pick_popup_pos, .Appearing)
				if im.BeginPopup("##quick_rig_picker_popup") {
					_draw_quick_rig_picker_popup_content(target_rig, pal)
					im.EndPopup()
				}
			}

			// C. Control Visuals & Shapes Dropdown Popup
			if im.Button(fmt.ctprintf("%s Visuals %s##RigVisualsBtn", icons.ICON_MD_PALETTE, icons.ICON_MD_EXPAND_MORE)) {
				im.OpenPopup("##control_visuals_popup")
			}
			ctrl_vis_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
			widgets.tooltip("Rig Control Visuals & Shapes: Customize shapes, colors, sizes, and 3D label visibility.")
			im.SameLine(0, 4)

			im.SetNextWindowPos(ctrl_vis_popup_pos, .Appearing)
			if im.BeginPopup("##control_visuals_popup") {
				if target_rig != nil {
					draw_control_visuals_popup_content(target_rig)
				} else {
					im.TextDisabled("No active character rig found in scene")
				}
				im.EndPopup()
			}

			// D. IK Active Toggle
			if target_rig != nil {
				_, target_solver := engine.transform_get_comp(target_rig.owner, crig.HumanoidIkSolver)
				is_act := target_solver != nil ? target_solver.active : target_rig.active
				pushed_act := is_act
				if pushed_act {
					im.PushStyleColorImVec4(.Button, thm.with_alpha(pal.status_success, 0.24))
					im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(pal.status_success, 0.36))
					im.PushStyleColorImVec4(.Text, pal.status_success)
				}
				if im.Button(fmt.ctprintf("%s IK Active", icons.ICON_MD_PLAY_ARROW if pushed_act else icons.ICON_MD_STOP)) {
					new_val := !is_act
					if target_solver != nil {
						target_solver.active = new_val
					}
					target_rig.active = new_val
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				widgets.tooltip("Toggle Rig & Solver Active: when active, IK solvers and rig controls actively pose the character.")
				if pushed_act {
					im.PopStyleColor(3)
				}
				im.SameLine(0, 4)
			}

			// E. Reset to Bind Pose (T-Pose) Button
			if target_adm != nil {
				if im.Button(fmt.ctprintf("%s Reset T-Pose", icons.ICON_MD_REFRESH)) {
					if target_rig != nil {
						owned, _ := engine.transform_get_comp(target_rig.owner, crig.ControlRig)
						sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Reset T-Pose")
						crig.armature_deformed_mesh_reset_bind_pose(target_adm)
						clear_rig_selection()
						undo.edit_session_end(&sess)
					} else {
						crig.armature_deformed_mesh_reset_bind_pose(target_adm)
						clear_rig_selection()
					}
				}
				widgets.tooltip("Restore authentic bind pose (T-Pose) for all bones and sync rig controls.")
			}

			// F. Active Rig Control Pill / Indicator
			sel_count := card(selected_rig_controls)
			if sel_count > 0 {
				im.SameLine(0, 6)
				im.TextColored(pal.text_muted, "|")
				im.SameLine(0, 6)

				if sel_count == 1 {
					for c in selected_rig_controls {
						im.TextColoredUnformatted(pal.accent, fmt.ctprintf("%s", _get_control_display_name(c)))
						break
					}
				} else {
					im.TextColoredUnformatted(pal.accent, fmt.ctprintf("%d Selected", sel_count))
				}

				im.SameLine(0, 4)
				if im.SmallButton(fmt.ctprintf("%s ##DeselectCtrl", icons.ICON_MD_CLOSE)) {
					clear_rig_selection()
				}
				widgets.tooltip("Deselect controls (or press Escape)")
			}

		case .Bone_Mode:
			// Reset to Bind Pose (T-Pose) Button
			if target_adm != nil {
				if im.Button(fmt.ctprintf("%s Reset T-Pose", icons.ICON_MD_REFRESH)) {
					if target_rig != nil {
						owned, _ := engine.transform_get_comp(target_rig.owner, crig.ControlRig)
						sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Reset T-Pose")
						crig.armature_deformed_mesh_reset_bind_pose(target_adm)
						clear_rig_selection()
						undo.edit_session_end(&sess)
					} else {
						crig.armature_deformed_mesh_reset_bind_pose(target_adm)
						clear_rig_selection()
					}
				}
				widgets.tooltip("Restore authentic bind pose (T-Pose) for all bones.")
				im.SameLine(0, 4)
			}

			// Vision Dropdown Menu (Show All Bone Names, Bone Shapes, Heatmap & Wireframe Overlays)
			vision_active := crig.skeleton_settings.show_bone_labels || crig.show_bone_weights_heatmap || crig.show_mesh_wireframe
			if vision_active {
				im.PushStyleColorImVec4(.Button, {0.15, 0.55, 0.78, 0.90})
				im.PushStyleColorImVec4(.ButtonHovered, {0.25, 0.65, 0.88, 1.00})
			}
			if im.Button(fmt.ctprintf("%s Vision %s##BoneVisionBtn", icons.ICON_MD_VISIBILITY, icons.ICON_MD_EXPAND_MORE)) {
				im.OpenPopup("##bone_vision_popup")
			}
			vision_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
			widgets.tooltip("Bone Mode Vision Options: Toggle 'Show All Bone Names', bone geometry style, weight heatmap, and mesh wireframe overlay.")
			if vision_active {
				im.PopStyleColor(2)
			}

			im.SetNextWindowPos(vision_popup_pos, .Appearing)
			if im.BeginPopup("##bone_vision_popup") {
				im.TextColoredUnformatted({0.25, 0.85, 0.95, 1.0}, fmt.ctprintf("%s Bone Mode Vision & Display", icons.ICON_MD_VISIBILITY))
				im.Separator()

				im.Checkbox("Show All Bone Names", &crig.skeleton_settings.show_bone_labels)
				widgets.tooltip("When unchecked, only the currently selected bone shows its name in the viewport. When checked, all skeleton bone names are shown.")
				if crig.skeleton_settings.show_bone_labels {
					im.SetNextItemWidth(150)
					im.SliderFloat("Name Scale", &crig.skeleton_settings.bone_label_scale, 0.4, 2.5, "%.2f")
				}

				im.Separator()
				bone_shape_names := [5]cstring{"Cylinder", "Capsule", "Box", "Stick", "Diamond"}
				cur_bshape := i32(crig.skeleton_settings.bone_solid_shape)
				im.SetNextItemWidth(150)
				if im.Combo("Bone Shape", &cur_bshape, "Cylinder\x00Capsule\x00Box\x00Stick\x00Diamond\x00") {
					crig.skeleton_settings.bone_solid_shape = crig.Bone_Solid_Shape(cur_bshape)
				}
				im.Checkbox("Solid 3D Bones", &crig.skeleton_settings.draw_solid_bones)
				im.SetNextItemWidth(150)
				im.SliderFloat("Bone Thickness", &crig.skeleton_settings.bone_thickness, 0.2, 3.0, "%.2f")

				im.Separator()
				if im.Checkbox("Show Weight Heatmap", &crig.show_bone_weights_heatmap) {
					if crig.show_bone_weights_heatmap {
						crig.active_heatmap_bone_h = active_h
						crig.active_heatmap_joint_idx = crig.armature_get_bone_joint_index(target_adm, active_h)
					}
					if target_adm != nil do target_adm.posed_frame = 0
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				if im.Checkbox("Unlit Heatmap Shading", &crig.heatmap_shading_unlit) {
					if target_adm != nil do target_adm.posed_frame = 0
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				if im.Checkbox("Mesh Wireframe Overlay", &crig.show_mesh_wireframe) {
					if target_adm != nil do target_adm.posed_frame = 0
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				if crig.show_mesh_wireframe {
					im.SetNextItemWidth(150)
					im.SliderFloat("Wireframe Opacity", &crig.wireframe_overlay_color.a, 0.05, 1.00, "%.2f")
				}
				im.Checkbox("Dim Other Bones in Paint Mode", &crig.skeleton_settings.dim_inactive_bones_in_paint_mode)
				let_unused := bone_shape_names
				_ = let_unused
				im.EndPopup()
			}

			im.SameLine(0, 4)

			// Quick Weight Heatmap Toggle
			heatmap_active := crig.show_bone_weights_heatmap
			if heatmap_active {
				im.PushStyleColorImVec4(.Button, {0.15, 0.65, 0.85, 0.90})
				im.PushStyleColorImVec4(.ButtonHovered, {0.25, 0.75, 0.95, 1.00})
			}
			if im.Button(fmt.ctprintf("%s Weight Heatmap", icons.ICON_MD_PALETTE)) {
				crig.show_bone_weights_heatmap = !crig.show_bone_weights_heatmap
				if crig.show_bone_weights_heatmap {
					crig.active_heatmap_bone_h = active_h
					crig.active_heatmap_joint_idx = crig.armature_get_bone_joint_index(target_adm, active_h)
				}
				if target_adm != nil do target_adm.posed_frame = 0
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			widgets.tooltip("Toggle vertex skin weight heatmap visualization in viewport (Cold blue = 0.0, Green = 0.5, Bright Red = 1.0)")
			if heatmap_active {
				im.PopStyleColor(2)
			}

			if active_h != {} && active_h != target_owner && target_adm != nil {
				for j in target_adm.joints {
					if j == active_h {
						bone_t := engine.pool_get(&w.transforms, engine.Handle(active_h))
						bone_name := bone_t != nil ? bone_t.name : "Bone"
						im.SameLine(0, 8)
						im.TextColored({0.5, 0.6, 0.7, 0.6}, "|")
						im.SameLine(0, 8)
						im.TextColoredUnformatted({0.20, 0.85, 0.40, 1.00}, fmt.ctprintf("Bone: %s", bone_name))
						break
					}
				}
			}

		case .Colliders:
			im.TextColoredUnformatted({0.95, 0.60, 0.20, 1.00}, fmt.ctprintf("%s PhAT Colliders", icons.ICON_MD_CROP_FREE))
			im.SameLine(0, 8)
			im.TextColored({0.5, 0.6, 0.7, 0.6}, "|")
			im.SameLine(0, 8)

			shading_label: cstring = "Shading: Semi-Transparent"
			switch collider_shading_mode {
			case .Semi_Transparent: shading_label = "Shading: Semi-Transparent"
			case .Wireframe:        shading_label = "Shading: Wireframe Only"
			case .Solid_Only:       shading_label = "Shading: Solid Only"
			}
			if im.Button(fmt.ctprintf("%s %s %s", icons.ICON_MD_PALETTE, shading_label, icons.ICON_MD_EXPAND_MORE)) {
				im.OpenPopup("##collider_shading_popup")
			}
			shading_popup_pos := im.Vec2{im.GetItemRectMin().x, im.GetItemRectMax().y + 2}
			widgets.tooltip("Choose how colliders are visualized in viewport: Semi-transparent volume + wireframe, Wireframe only, or Solid only")

			im.SetNextWindowPos(shading_popup_pos, .Appearing)
			if im.BeginPopup("##collider_shading_popup") {
				if im.Selectable("Semi-Transparent (Solid + Wireframe)", collider_shading_mode == .Semi_Transparent) {
					collider_shading_mode = .Semi_Transparent
				}
				if im.Selectable("Wireframe Only", collider_shading_mode == .Wireframe) {
					collider_shading_mode = .Wireframe
				}
				if im.Selectable("Solid Volume Only", collider_shading_mode == .Solid_Only) {
					collider_shading_mode = .Solid_Only
				}
				im.Separator()
				im.SliderFloat("Opacity", &collider_solid_alpha, 0.05, 0.90, "%.2f")
				im.EndPopup()
			}

		case .Hand_Poses:
			draw_hand_poses_top_bar(target_owner, target_adm)
		}

		// Keyboard Shortcuts (Escape for Deselect)
		if !im.GetIO().WantTextInput {
			if im.IsKeyPressed(im.Key.Escape) do clear_rig_selection()
		}

		// Render on-screen Control Inspector floating card when controls are selected in Rig_Controls mode
		if character_edit_mode == .Rig_Controls && target_rig != nil && card(selected_rig_controls) > 0 && selected_rig_owner == target_owner {
			draw_rig_control_inspector_floating(target_rig)
		}

		// Render on-screen Left Toolbar in Bone mode
		if character_edit_mode == .Bone_Mode && target_adm != nil {
			if (crig.show_bone_weights_heatmap || weight_painter.enabled) && active_h != crig.active_heatmap_bone_h {
				crig.active_heatmap_bone_h = active_h
				crig.active_heatmap_joint_idx = crig.armature_get_bone_joint_index(target_adm, active_h)
				target_adm.posed_frame = 0
			}
			_draw_bones_left_toolbar(target_owner, target_adm, active_h)
			weight_painter_frame(target_adm, crig.active_heatmap_joint_idx)
		}

		// Render on-screen Left Toolbar in Hand Poses mode
		if character_edit_mode == .Hand_Poses && target_adm != nil {
			draw_hand_poses_left_toolbar(target_owner, target_adm)
		}

		// Render on-screen Left Toolbar in Colliders mode
		if character_edit_mode == .Colliders && target_adm != nil {
			_draw_colliders_left_toolbar(target_owner, target_adm, active_h)
		}

		// Render on-screen Bone Collider Inspector floating card when a bone is selected in Colliders mode
		if character_edit_mode == .Colliders && target_adm != nil && active_h != {} && active_h != target_owner {
			is_bone := false
			for j in target_adm.joints {
				if j == active_h {
					is_bone = true
					break
				}
			}
			if is_bone {
				draw_bone_collider_inspector_floating(active_h, target_adm)
			}
		}
	}
}

@(private = "file")
rig_insp_scale: f32 = 1.0

Rig_Mirror_Mode :: enum {
	Left_To_Right,
	Right_To_Left,
	Swap_Left_Right,
}

@(private = "file")
_mirror_vec3_x :: proc(v: [3]f32) -> [3]f32 {
	return {-v.x, v.y, v.z}
}

@(private = "file")
_mirror_quat_x :: proc(q: [4]f32) -> [4]f32 {
	return {q.x, -q.y, -q.z, q.w}
}

@(private = "file")
_mirror_rig_pose :: proc(rig: ^crig.ControlRig, mode: Rig_Mirror_Mode) {
	if rig == nil do return
	switch mode {
	case .Left_To_Right:
		rig.right_foot.position          = _mirror_vec3_x(rig.left_foot.position)
		rig.right_foot.rotation          = _mirror_quat_x(rig.left_foot.rotation)
		rig.right_foot.relative_rotation = _mirror_quat_x(rig.left_foot.relative_rotation)
		rig.right_toe_pitch              = rig.left_toe_pitch
		rig.right_knee_pole              = _mirror_vec3_x(rig.left_knee_pole)
		rig.right_hand.position          = _mirror_vec3_x(rig.left_hand.position)
		rig.right_hand.rotation          = _mirror_quat_x(rig.left_hand.rotation)
		rig.right_hand.relative_rotation = _mirror_quat_x(rig.left_hand.relative_rotation)
		rig.right_elbow_pole             = _mirror_vec3_x(rig.left_elbow_pole)

	case .Right_To_Left:
		rig.left_foot.position          = _mirror_vec3_x(rig.right_foot.position)
		rig.left_foot.rotation          = _mirror_quat_x(rig.right_foot.rotation)
		rig.left_foot.relative_rotation = _mirror_quat_x(rig.right_foot.relative_rotation)
		rig.left_toe_pitch              = rig.right_toe_pitch
		rig.left_knee_pole              = _mirror_vec3_x(rig.right_knee_pole)
		rig.left_hand.position          = _mirror_vec3_x(rig.right_hand.position)
		rig.left_hand.rotation          = _mirror_quat_x(rig.right_hand.rotation)
		rig.left_hand.relative_rotation = _mirror_quat_x(rig.right_hand.relative_rotation)
		rig.left_elbow_pole             = _mirror_vec3_x(rig.right_elbow_pole)

	case .Swap_Left_Right:
		lf_p, lf_r, lf_rr := rig.left_foot.position, rig.left_foot.rotation, rig.left_foot.relative_rotation
		rig.left_foot.position           = _mirror_vec3_x(rig.right_foot.position)
		rig.left_foot.rotation           = _mirror_quat_x(rig.right_foot.rotation)
		rig.left_foot.relative_rotation  = _mirror_quat_x(rig.right_foot.relative_rotation)
		rig.right_foot.position          = _mirror_vec3_x(lf_p)
		rig.right_foot.rotation          = _mirror_quat_x(lf_r)
		rig.right_foot.relative_rotation = _mirror_quat_x(lf_rr)

		ltp := rig.left_toe_pitch
		rig.left_toe_pitch  = rig.right_toe_pitch
		rig.right_toe_pitch = ltp

		lkp := rig.left_knee_pole
		rig.left_knee_pole  = _mirror_vec3_x(rig.right_knee_pole)
		rig.right_knee_pole = _mirror_vec3_x(lkp)

		lh_p, lh_r, lh_rr := rig.left_hand.position, rig.left_hand.rotation, rig.left_hand.relative_rotation
		rig.left_hand.position           = _mirror_vec3_x(rig.right_hand.position)
		rig.left_hand.rotation           = _mirror_quat_x(rig.right_hand.rotation)
		rig.left_hand.relative_rotation  = _mirror_quat_x(rig.right_hand.relative_rotation)
		rig.right_hand.position          = _mirror_vec3_x(lh_p)
		rig.right_hand.rotation          = _mirror_quat_x(lh_r)
		rig.right_hand.relative_rotation = _mirror_quat_x(lh_rr)

		lep := rig.left_elbow_pole
		rig.left_elbow_pole  = _mirror_vec3_x(rig.right_elbow_pole)
		rig.right_elbow_pole = _mirror_vec3_x(lep)

		// Also reflect torso/head/look-at across sagittal YZ plane
		rig.pelvis.position = _mirror_vec3_x(rig.pelvis.position)
		rig.pelvis.rotation = _mirror_quat_x(rig.pelvis.rotation)
		rig.spine.position  = _mirror_vec3_x(rig.spine.position)
		rig.spine.rotation  = _mirror_quat_x(rig.spine.rotation)
		rig.chest.position  = _mirror_vec3_x(rig.chest.position)
		rig.chest.rotation  = _mirror_quat_x(rig.chest.rotation)
		rig.head.position   = _mirror_vec3_x(rig.head.position)
		rig.head.rotation   = _mirror_quat_x(rig.head.rotation)
		rig.look_at_target  = _mirror_vec3_x(rig.look_at_target)
	}
}

@(private = "file")
_draw_quick_rig_picker_popup_content :: proc(rig: ^crig.ControlRig, pal: thm.Theme_Palette) {
	if rig == nil do return
	owner_h := engine.Transform_Handle(rig.owner)
	ctrl_held := im.GetIO().KeyCtrl || im.GetIO().KeySuper

	im.TextColoredUnformatted(pal.accent, fmt.ctprintf("%s Quick Control Picker", icons.ICON_MD_WIDGETS))
	im.TextDisabled("Click to select (Ctrl+Click to multi-select)")
	im.Separator()

	_pick_btn :: proc(owner_h: engine.Transform_Handle, label: cstring, c: Active_Rig_Control, ctrl_held: bool, pal: thm.Theme_Palette, w: f32) {
		is_s := is_rig_control_selected(owner_h, c)
		if is_s {
			im.PushStyleColorImVec4(.Button, thm.with_alpha(pal.accent, 0.30))
			im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(pal.accent, 0.42))
		} else {
			im.PushStyleColorImVec4(.Button, pal.bg_elevated)
			im.PushStyleColorImVec4(.ButtonHovered, pal.bg_hover)
		}
		if im.Button(label, {w, 0}) {
			select_rig_control(owner_h, c, ctrl_held)
		}
		im.PopStyleColor(2)
	}

	ui_s := max(im.GetFontSize() / 14.0, 0.75)
	bw := 112.0 * ui_s
	bw_full := bw * 2.0 + 4.0 * ui_s

	im.TextDisabled("TORSO & HEAD")
	_pick_btn(owner_h, "Head", .Head, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "LookAt", .Look_At, ctrl_held, pal, bw)
	_pick_btn(owner_h, "Chest", .Chest, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "Eye Socket", .Eye_Level_Socket, ctrl_held, pal, bw)
	_pick_btn(owner_h, "Spine", .Spine, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "Pelvis", .Pelvis, ctrl_held, pal, bw)

	im.Spacing()
	im.TextDisabled("ARMS & HANDS")
	_pick_btn(owner_h, "L Hand", .Left_Hand, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "R Hand", .Right_Hand, ctrl_held, pal, bw)
	_pick_btn(owner_h, "L Elbow Pole", .Left_Elbow_Pole, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "R Elbow Pole", .Right_Elbow_Pole, ctrl_held, pal, bw)

	im.Spacing()
	im.TextDisabled("LEGS, FEET & TOES")
	_pick_btn(owner_h, "L Foot", .Left_Foot, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "R Foot", .Right_Foot, ctrl_held, pal, bw)
	_pick_btn(owner_h, "L Toe", .Left_Toe, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "R Toe", .Right_Toe, ctrl_held, pal, bw)
	_pick_btn(owner_h, "L Knee Pole", .Left_Knee_Pole, ctrl_held, pal, bw)
	im.SameLine(0, 4 * ui_s)
	_pick_btn(owner_h, "R Knee Pole", .Right_Knee_Pole, ctrl_held, pal, bw)

	im.Spacing()
	if im.Button("Select All Controls", {bw_full, 0}) {
		selected_rig_owner = owner_h
		set_active_character_owner(owner_h)
		selected_rig_controls = {.Pelvis, .Spine, .Chest, .Head, .Look_At, .Left_Foot, .Right_Foot, .Left_Hand, .Right_Hand, .Left_Knee_Pole, .Right_Knee_Pole, .Left_Elbow_Pole, .Right_Elbow_Pole}
		active_rig_control = .Pelvis
	}

	im.Separator()
	im.TextDisabled("POSE SYMMETRY")
	w3 := (bw_full - 8.0 * ui_s) / 3.0
	if im.Button("L -> R", {w3, 0}) {
		owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
		sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Mirror Rig Pose L -> R")
		_mirror_rig_pose(rig, .Left_To_Right)
		_activate_rig_and_solver(rig)
		undo.edit_session_end(&sess)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Copy Left limbs & poles symmetrically onto Right side")
	im.SameLine(0, 4 * ui_s)
	if im.Button("R -> L", {w3, 0}) {
		owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
		sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Mirror Rig Pose R -> L")
		_mirror_rig_pose(rig, .Right_To_Left)
		_activate_rig_and_solver(rig)
		undo.edit_session_end(&sess)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Copy Right limbs & poles symmetrically onto Left side")
	im.SameLine(0, 4 * ui_s)
	if im.Button("Flip Pose", {w3, 0}) {
		owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
		sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Flip Full Rig Pose L <-> R")
		_mirror_rig_pose(rig, .Swap_Left_Right)
		_activate_rig_and_solver(rig)
		undo.edit_session_end(&sess)
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	widgets.tooltip("Flip the entire pose across the character's sagittal plane (Left <-> Right + Spine/Pelvis)")
}

draw_rig_control_inspector_floating :: proc(rig: ^crig.ControlRig) {
	if rig == nil || card(selected_rig_controls) == 0 do return
	if selected_rig_owner != {} && selected_rig_owner != engine.Transform_Handle(rig.owner) do return

	if !rig.bones.bound || !crig.skeleton_bones_alive(&rig.bones) {
		crig.skeleton_bind_humanoid(&rig.bones, rig.owner)
	}

	pal := thm.palette()
	vp := im.GetMainViewport()
	im.SetNextWindowViewport(vp.ID_)
	im.SetNextWindowBgAlpha(0.95)
	im.SetNextWindowPos({vp.WorkPos.x + 68, vp.WorkPos.y + 84}, .FirstUseEver)
	im.SetNextWindowSizeConstraints({280 * rig_insp_scale, 120}, {520 * rig_insp_scale, 760 * rig_insp_scale})
	flags := im.WindowFlags{.AlwaysAutoResize, .NoDocking, .NoFocusOnAppearing}

	im.PushStyleColorImVec4(.WindowBg, pal.bg_panel)
	im.PushStyleColorImVec4(.Border, pal.border_strong)
	title: cstring = "Rig Control Studio###rig_ctrl_insp"
	if im.Begin(title, nil, flags) {
		io := im.GetIO()
		if io.KeyCtrl && io.MouseWheel != 0 && im.IsWindowHovered(im.HoveredFlags_RootWindow | im.HoveredFlags_ChildWindows) {
			rig_insp_scale = clamp(rig_insp_scale + io.MouseWheel * 0.08, 0.70, 1.85)
			io.MouseWheel = 0
		}

		st := im.GetStyle()
		has_scale := abs(rig_insp_scale - 1.0) > 0.01
		if has_scale {
			im.PushFontFloat(nil, st.FontSizeBase * rig_insp_scale)
			im.PushStyleVarImVec2(.FramePadding, {st.FramePadding.x * rig_insp_scale, st.FramePadding.y * rig_insp_scale})
			im.PushStyleVarImVec2(.ItemSpacing, {st.ItemSpacing.x * rig_insp_scale, st.ItemSpacing.y * rig_insp_scale})
			im.PushStyleVarImVec2(.ItemInnerSpacing, {st.ItemInnerSpacing.x * rig_insp_scale, st.ItemInnerSpacing.y * rig_insp_scale})
		}
		ui_s := max(im.GetFontSize() / 14.0, 0.70)

		count := card(selected_rig_controls)
		if count == 1 {
			for c in selected_rig_controls {
				im.TextColoredUnformatted(pal.accent, fmt.ctprintf("%s %s", icons.ICON_MD_TUNE, _get_control_display_name(c)))
				break
			}
		} else {
			im.TextColoredUnformatted(pal.accent, fmt.ctprintf("%s %d Controls Selected", icons.ICON_MD_TUNE, count))
		}
		im.Separator()

		// 1. 1-Click Tool Mode Strip
		eff_t := current_gizmo_tool
		if eff_t == .Picker do eff_t = .Translate
		tool_defs := [4]struct {
			label: cstring,
			tool:  handles.Tool,
			tip:   cstring,
		}{
			{"Move (W)", .Translate, "Axis Translate Gizmo (W)"},
			{"Rotate (E)", .Rotate, "Axis Rotate Gizmo (E)"},
			{"Scale (R)", .Scale, "Control Shape Scale (R)"},
			{"Free (T)", .Handles, "Direct Screen-Plane Contour Drag (T)"},
		}
		for td, ti in tool_defs {
			is_act := (eff_t == td.tool)
			if is_act {
				im.PushStyleColorImVec4(.Button, thm.with_alpha(pal.accent, 0.28))
				im.PushStyleColorImVec4(.ButtonHovered, thm.with_alpha(pal.accent, 0.40))
				im.PushStyleColorImVec4(.Text, pal.text_primary)
			} else {
				im.PushStyleColorImVec4(.Button, pal.bg_elevated)
				im.PushStyleColorImVec4(.ButtonHovered, pal.bg_hover)
				im.PushStyleColorImVec4(.Text, pal.text_secondary)
			}
			if im.SmallButton(td.label) {
				request_gizmo_tool(td.tool)
			}
			im.PopStyleColor(3)
			widgets.tooltip(td.tip)
			if ti < 3 do im.SameLine(0, 4 * ui_s)
		}
		im.Separator()

		// 2. Control Properties
		im.PushItemWidth(175.0 * ui_s)
		primary_rc := _get_primary_rig_control(rig)
		if primary_rc != nil {
			shape_names := [10]cstring{
				"Circle (XZ plane)",
				"Circle Normal (XY plane)",
				"Ring (Donut)",
				"Square (XZ plane)",
				"Square Normal (XY plane)",
				"Diamond (Rhombus)",
				"Cross (+)",
				"Arrow (Directional)",
				"Cube (Oriented Box)",
				"Sphere",
			}
			cur_shape_idx := clamp(int(primary_rc.shape), 0, 9)
			if im.BeginCombo("Shape", shape_names[cur_shape_idx], {}) {
				for name, idx in shape_names {
					is_sel := (idx == cur_shape_idx)
					if im.Selectable(name, is_sel) {
						chosen_shape := crig.Control_Shape_Type(idx)
						owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
						sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Change Rig Control Shape")
						_for_each_selected_rig_control(rig, proc(c: ^crig.Rig_Control, val: rawptr) {
							c.shape = (cast(^crig.Control_Shape_Type)val)^
						}, &chosen_shape)
						undo.edit_session_end(&sess)
						if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
					}
					if is_sel do im.SetItemDefaultFocus()
				}
				im.EndCombo()
			}

			col := primary_rc.color
			changed_col := im.ColorEdit4("Color", &col, {.NoAlpha})
			_begin_slider_undo(rig, "Change Rig Control Color")
			if changed_col {
				col.a = 0.96
				_for_each_selected_rig_control(rig, proc(c: ^crig.Rig_Control, val: rawptr) {
					c.color = (cast(^[4]f32)val)^
				}, &col)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo()

			scale := primary_rc.scale
			changed_scale := im.SliderFloat("Scale", &scale, 0.04, 1.5, "%.2f")
			_begin_slider_undo(rig, "Scale Rig Control")
			if changed_scale {
				_for_each_selected_rig_control(rig, proc(c: ^crig.Rig_Control, val: rawptr) {
					c.scale = (cast(^f32)val)^
				}, &scale)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo()

			weight := primary_rc.rotation_weight
			if weight < 0.01 do weight = 0.01
			changed_weight := im.SliderFloat("IK Rot Weight", &weight, 0.01, 1.0, "%.2f")
			_begin_slider_undo(rig, "Change IK Rotation Weight")
			if changed_weight {
				if weight < 0.01 do weight = 0.01
				_for_each_selected_rig_control(rig, proc(c: ^crig.Rig_Control, val: rawptr) {
					c.rotation_weight = (cast(^f32)val)^
				}, &weight)
				_activate_rig_and_solver(rig)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo()
			widgets.tooltip("0.01 = Natural anatomical dangle / IK flow, 1 = Full lock to control orientation")
		}

		// E. Eye Level Socket Offset Sliders
		if .Eye_Level_Socket in selected_rig_controls {
			im.Separator()
			im.TextColored(pal.status_info, "Eye Level Socket (Camera Mount)")
			eye_off := rig.eye_level_socket.position
			changed_eye := false

			c_y := im.SliderFloat("Eye Height (Y)", &eye_off.y, -0.10, 0.35, "%.3f m")
			_begin_slider_undo(rig, "Adjust Eye Level Height")
			if c_y do changed_eye = true
			_end_slider_undo()

			c_z := im.SliderFloat("Eye Forward (Z)", &eye_off.z, -0.10, 0.35, "%.3f m")
			_begin_slider_undo(rig, "Adjust Eye Level Forward")
			if c_z do changed_eye = true
			_end_slider_undo()

			c_x := im.SliderFloat("Eye Lateral (X)", &eye_off.x, -0.25, 0.25, "%.3f m")
			_begin_slider_undo(rig, "Adjust Eye Level Lateral")
			if c_x do changed_eye = true
			_end_slider_undo()

			if changed_eye {
				rig.eye_level_socket.position = eye_off
				_activate_rig_and_solver(rig)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			widgets.tooltip("Offset relative to head bone pivot (Y = Eye Level Height, Z = Forward Face Depth, X = Lateral Center)")
		}

		// F. Toe Pitch Slider
		if .Left_Foot in selected_rig_controls || .Left_Toe in selected_rig_controls {
			im.Separator()
			left_toe_deg := linalg.to_degrees(rig.left_toe_pitch)
			changed_l_toe := im.SliderFloat("L Toe Pitch", &left_toe_deg, -45.0, 70.0, "%.1f°")
			_begin_slider_undo(rig, "Adjust Left Toe Pitch")
			if changed_l_toe {
				rig.left_toe_pitch = linalg.to_radians(left_toe_deg)
				_activate_rig_and_solver(rig)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo()
			widgets.tooltip("Ball of foot / toe roll hinge angle along foot Right axis (also rotatable in 3D via L_Toe)")
		}

		if .Right_Foot in selected_rig_controls || .Right_Toe in selected_rig_controls {
			if !(.Left_Foot in selected_rig_controls || .Left_Toe in selected_rig_controls) {
				im.Separator()
			}
			right_toe_deg := linalg.to_degrees(rig.right_toe_pitch)
			changed_r_toe := im.SliderFloat("R Toe Pitch", &right_toe_deg, -45.0, 70.0, "%.1f°")
			_begin_slider_undo(rig, "Adjust Right Toe Pitch")
			if changed_r_toe {
				rig.right_toe_pitch = linalg.to_radians(right_toe_deg)
				_activate_rig_and_solver(rig)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo()
			widgets.tooltip("Ball of foot / toe roll hinge angle along foot Right axis (also rotatable in 3D via R_Toe)")
		}

		// G. Hand Relative Rotation
		if (.Left_Hand in selected_rig_controls || .Right_Hand in selected_rig_controls) && primary_rc != nil {
			im.Separator()
			im.TextColored(pal.status_warning, "Hand Relative / Weapon Posture")
			hand_rel := primary_rc.relative_rotation
			euler := engine.quat_to_euler_xyz(hand_rel)
			changed_h := false

			hx := im.SliderFloat("Wrist Pitch", &euler.x, -180.0, 180.0, "%.1f°")
			_begin_slider_undo(rig, "Adjust Hand Relative Pitch")
			if hx do changed_h = true
			_end_slider_undo()

			hy := im.SliderFloat("Wrist Yaw", &euler.y, -180.0, 180.0, "%.1f°")
			_begin_slider_undo(rig, "Adjust Hand Relative Yaw")
			if hy do changed_h = true
			_end_slider_undo()

			hz := im.SliderFloat("Wrist Roll", &euler.z, -180.0, 180.0, "%.1f°")
			_begin_slider_undo(rig, "Adjust Hand Relative Roll")
			if hz do changed_h = true
			_end_slider_undo()

			if changed_h {
				new_q := engine.quat_from_euler_xyz(euler.x, euler.y, euler.z)
				_for_each_selected_rig_control(rig, proc(c: ^crig.Rig_Control, val: rawptr) {
					c.relative_rotation = (cast(^[4]f32)val)^
				}, &new_q)
				_activate_rig_and_solver(rig)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			widgets.tooltip("Relaxed local hand offset (e.g. holding hammer/rifle, relaxed posture while running)")
		}
		im.PopItemWidth()

		im.Separator()

		// H. Pose Symmetry Row
		im.TextDisabled("POSE SYMMETRY")
		if im.SmallButton("Mirror L -> R") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Mirror Rig Pose L -> R")
			_mirror_rig_pose(rig, .Left_To_Right)
			_activate_rig_and_solver(rig)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		im.SameLine(0, 4 * ui_s)
		if im.SmallButton("Mirror R -> L") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Mirror Rig Pose R -> L")
			_mirror_rig_pose(rig, .Right_To_Left)
			_activate_rig_and_solver(rig)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		im.SameLine(0, 4 * ui_s)
		if im.SmallButton("Flip L <-> R") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Flip Rig Pose L <-> R")
			_mirror_rig_pose(rig, .Swap_Left_Right)
			_activate_rig_and_solver(rig)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}

		im.Separator()

		// I. Reset & Deselect Action Buttons
		if im.Button(fmt.ctprintf("%s Reset Pos", icons.ICON_MD_REFRESH)) {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Reset Rig Control Position")
			_reset_selected_positions(rig)
			_activate_rig_and_solver(rig)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Restore selected control(s) to their rest bind-pose positions")

		im.SameLine(0, 4 * ui_s)
		if im.Button("Reset Rot") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Reset Rig Control Rotation")
			_reset_selected_rotations(rig)
			_activate_rig_and_solver(rig)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Reset orientation of selected control(s) to identity")

		im.SameLine(0, 4 * ui_s)
		if im.Button("Reset Both") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Reset Rig Control Pos & Rot")
			_reset_selected_positions(rig)
			_reset_selected_rotations(rig)
			_activate_rig_and_solver(rig)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Restore both rest position and identity rotation on selected control(s)")

		im.SameLine(0, 6 * ui_s)
		if im.Button(fmt.ctprintf("%s##DeselectInsp", icons.ICON_MD_CLOSE)) {
			clear_rig_selection()
		}
		widgets.tooltip("Deselect (Escape)")

		if has_scale {
			im.PopStyleVar(3)
			im.PopFont()
		}
	}
	im.End()
	im.PopStyleColor(2)
}

_get_control_display_name :: proc(c: Active_Rig_Control) -> cstring {
	switch c {
	case .Pelvis:           return "Pelvis Control"
	case .Spine:            return "Mid Spine (Waist)"
	case .Chest:            return "Chest Control"
	case .Head:             return "Head Control"
	case .Eye_Level_Socket: return "Eye Level Socket"
	case .Look_At:          return "LookAt Target"
	case .Left_Foot:        return "Left Foot"
	case .Right_Foot:       return "Right Foot"
	case .Left_Toe:         return "Left Toe / Ball"
	case .Right_Toe:        return "Right Toe / Ball"
	case .Left_Knee_Pole:   return "L Knee Pole"
	case .Right_Knee_Pole:  return "R Knee Pole"
	case .Left_Hand:        return "Left Hand"
	case .Right_Hand:       return "Right Hand"
	case .Left_Elbow_Pole:  return "L Elbow Pole"
	case .Right_Elbow_Pole: return "R Elbow Pole"
	}
	return "Control"
}

_get_primary_rig_control :: proc(rig: ^crig.ControlRig) -> ^crig.Rig_Control {
	if rig == nil do return nil
	if .Pelvis in selected_rig_controls do return &rig.pelvis
	if .Spine in selected_rig_controls do return &rig.spine
	if .Chest in selected_rig_controls do return &rig.chest
	if .Head in selected_rig_controls do return &rig.head
	if .Eye_Level_Socket in selected_rig_controls do return &rig.eye_level_socket
	if .Left_Foot in selected_rig_controls do return &rig.left_foot
	if .Right_Foot in selected_rig_controls do return &rig.right_foot
	if .Left_Hand in selected_rig_controls do return &rig.left_hand
	if .Right_Hand in selected_rig_controls do return &rig.right_hand
	return nil
}

_for_each_selected_rig_control :: proc(rig: ^crig.ControlRig, fn: proc(c: ^crig.Rig_Control, user_data: rawptr), user_data: rawptr) {
	if rig == nil do return
	if .Pelvis in selected_rig_controls do fn(&rig.pelvis, user_data)
	if .Spine in selected_rig_controls do fn(&rig.spine, user_data)
	if .Chest in selected_rig_controls do fn(&rig.chest, user_data)
	if .Head in selected_rig_controls do fn(&rig.head, user_data)
	if .Eye_Level_Socket in selected_rig_controls do fn(&rig.eye_level_socket, user_data)
	if .Left_Foot in selected_rig_controls do fn(&rig.left_foot, user_data)
	if .Right_Foot in selected_rig_controls do fn(&rig.right_foot, user_data)
	if .Left_Hand in selected_rig_controls do fn(&rig.left_hand, user_data)
	if .Right_Hand in selected_rig_controls do fn(&rig.right_hand, user_data)
}

_reset_selected_positions :: proc(rig: ^crig.ControlRig) {
	if rig == nil do return
	bones := crig.control_rig_ensure_bones(rig)
	if bones == nil || !bones.bound do return

	if .Pelvis in selected_rig_controls && rig.bones.pelvis_rest.valid {
		rig.pelvis.position = rig.bones.pelvis_rest.pos
	}
	if .Spine in selected_rig_controls && rig.bones.spine_rest.valid {
		rig.spine.position = rig.bones.spine_rest.pos
	}
	if .Chest in selected_rig_controls && rig.bones.chest_rest.valid {
		rig.chest.position = rig.bones.chest_rest.pos
	}
	if .Head in selected_rig_controls && rig.bones.head_rest.valid {
		rig.head.position = rig.bones.head_rest.pos
	}
	if .Eye_Level_Socket in selected_rig_controls {
		rig.eye_level_socket.position = {0.0, 0.13, 0.14}
	}
	if .Look_At in selected_rig_controls {
		base_h := rig.bones.head_rest.pos if rig.bones.head_rest.valid else rig.head.position
		rig.look_at_target = base_h + {0.0, 0.0, 2.0}
	}
	if .Left_Foot in selected_rig_controls && rig.bones.left_leg_rest.valid {
		rig.left_foot.position = rig.bones.left_leg_rest.tip_pos
	}
	if .Right_Foot in selected_rig_controls && rig.bones.right_leg_rest.valid {
		rig.right_foot.position = rig.bones.right_leg_rest.tip_pos
	}
	if .Left_Knee_Pole in selected_rig_controls && rig.bones.left_leg_rest.valid {
		rig.left_knee_pole = {rig.bones.left_leg_rest.mid_pos.x, rig.bones.left_leg_rest.mid_pos.y, rig.bones.left_leg_rest.mid_pos.z + 0.55}
	}
	if .Right_Knee_Pole in selected_rig_controls && rig.bones.right_leg_rest.valid {
		rig.right_knee_pole = {rig.bones.right_leg_rest.mid_pos.x, rig.bones.right_leg_rest.mid_pos.y, rig.bones.right_leg_rest.mid_pos.z + 0.55}
	}
	if .Left_Hand in selected_rig_controls && rig.bones.left_arm_rest.valid {
		rig.left_hand.position = rig.bones.left_arm_rest.tip_pos
	}
	if .Right_Hand in selected_rig_controls && rig.bones.right_arm_rest.valid {
		rig.right_hand.position = rig.bones.right_arm_rest.tip_pos
	}
	if .Left_Elbow_Pole in selected_rig_controls && rig.bones.left_arm_rest.valid {
		rig.left_elbow_pole = {rig.bones.left_arm_rest.mid_pos.x, rig.bones.left_arm_rest.mid_pos.y, rig.bones.left_arm_rest.mid_pos.z - 0.45}
	}
	if .Right_Elbow_Pole in selected_rig_controls && rig.bones.right_arm_rest.valid {
		rig.right_elbow_pole = {rig.bones.right_arm_rest.mid_pos.x, rig.bones.right_arm_rest.mid_pos.y, rig.bones.right_arm_rest.mid_pos.z - 0.45}
	}
}

_reset_selected_rotations :: proc(rig: ^crig.ControlRig) {
	if rig == nil do return
	_for_each_selected_rig_control(rig, proc(c: ^crig.Rig_Control, _: rawptr) {
		c.rotation = engine.QUAT_IDENTITY
		c.relative_rotation = engine.QUAT_IDENTITY
	}, nil)
	if .Left_Toe in selected_rig_controls || .Left_Foot in selected_rig_controls do rig.left_toe_pitch = 0.0
	if .Right_Toe in selected_rig_controls || .Right_Foot in selected_rig_controls do rig.right_toe_pitch = 0.0
}

@(private = "file")
_attach_capsule_to_bone :: proc(bone_h: engine.Transform_Handle) {
	crig.smart_collider_add_bone_auto(bone_h)
}

@(private = "file")
_find_opposite_bone :: proc(bone_h: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh) -> (engine.Transform_Handle, bool) {
	if bone_h == {} || adm == nil do return {}, false
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return {}, false
	bone_t := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bone_t == nil do return {}, false
	name := bone_t.name

	target_name: string = ""
	if strings.ends_with(name, "_l") {
		target_name = fmt.tprintf("%s_r", name[:len(name)-2])
	} else if strings.ends_with(name, "_r") {
		target_name = fmt.tprintf("%s_l", name[:len(name)-2])
	} else if strings.ends_with(name, "_L") {
		target_name = fmt.tprintf("%s_R", name[:len(name)-2])
	} else if strings.ends_with(name, "_R") {
		target_name = fmt.tprintf("%s_L", name[:len(name)-2])
	} else if strings.ends_with(name, ".l") {
		target_name = fmt.tprintf("%s.r", name[:len(name)-2])
	} else if strings.ends_with(name, ".r") {
		target_name = fmt.tprintf("%s.l", name[:len(name)-2])
	} else if strings.ends_with(name, ".L") {
		target_name = fmt.tprintf("%s.R", name[:len(name)-2])
	} else if strings.ends_with(name, ".R") {
		target_name = fmt.tprintf("%s.L", name[:len(name)-2])
	} else if strings.starts_with(name, "Left") {
		target_name = fmt.tprintf("Right%s", name[4:])
	} else if strings.starts_with(name, "Right") {
		target_name = fmt.tprintf("Left%s", name[5:])
	} else if strings.starts_with(name, "left") {
		target_name = fmt.tprintf("right%s", name[4:])
	} else if strings.starts_with(name, "right") {
		target_name = fmt.tprintf("left%s", name[5:])
	} else if strings.contains(name, "_left_") {
		target_name, _ = strings.replace_all(name, "_left_", "_right_", context.temp_allocator)
	} else if strings.contains(name, "_right_") {
		target_name, _ = strings.replace_all(name, "_right_", "_left_", context.temp_allocator)
	} else if strings.contains(name, "_Left_") {
		target_name, _ = strings.replace_all(name, "_Left_", "_Right_", context.temp_allocator)
	} else if strings.contains(name, "_Right_") {
		target_name, _ = strings.replace_all(name, "_Right_", "_Left_", context.temp_allocator)
	} else {
		return {}, false
	}

	for j in adm.joints {
		if j == {} do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue
		jt := engine.pool_get(&w.transforms, engine.Handle(j))
		if jt != nil && jt.name == target_name {
			return j, true
		}
	}
	return {}, false
}

@(private = "file")
_mirror_bone_collider :: proc(bone_h: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh) -> bool {
	opp_h, ok := _find_opposite_bone(bone_h, adm)
	if !ok || opp_h == {} do return false

	w := engine.ctx_world()
	if w == nil do return false

	// Clean out any existing colliders on opposite bone
	crig.smart_collider_remove_from_bone(opp_h)

	_, cap := engine.transform_get_comp(bone_h, physics3d.CapsuleCollider)
	_, box := engine.transform_get_comp(bone_h, physics3d.BoxCollider)
	_, sph := engine.transform_get_comp(bone_h, physics3d.SphereCollider)

	if cap != nil {
		rot := cap.rotation
		if rot != {} && rot != {0, 0, 0, 1} {
			euler := engine.quat_to_euler_xyz(rot)
			mirrored_rot := engine.quat_from_euler_xyz(euler.x, -euler.y, -euler.z)
			crig.smart_collider_add_capsule(opp_h, cap.radius, cap.height, cap.direction, {-cap.center.x, cap.center.y, cap.center.z}, mirrored_rot)
		} else {
			crig.smart_collider_add_capsule(opp_h, cap.radius, cap.height, cap.direction, {-cap.center.x, cap.center.y, cap.center.z})
		}
	} else if box != nil {
		rot := box.rotation
		if rot != {} && rot != {0, 0, 0, 1} {
			euler := engine.quat_to_euler_xyz(rot)
			mirrored_rot := engine.quat_from_euler_xyz(euler.x, -euler.y, -euler.z)
			crig.smart_collider_add_box(opp_h, box.size, {-box.center.x, box.center.y, box.center.z}, mirrored_rot)
		} else {
			crig.smart_collider_add_box(opp_h, box.size, {-box.center.x, box.center.y, box.center.z})
		}
	} else if sph != nil {
		crig.smart_collider_add_sphere(opp_h, sph.radius, {-sph.center.x, sph.center.y, sph.center.z})
	} else {
		return false
	}

	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

@(private = "file")
bones_toolbar_scale: f32 = 1.0

@(private = "file")
colliders_toolbar_scale: f32 = 1.0

@(private = "file")
_draw_bones_left_toolbar :: proc(target_owner: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh, active_h: engine.Transform_Handle) {
	if adm == nil do return

	vp := im.GetMainViewport()
	im.SetNextWindowViewport(vp.ID_)
	im.SetNextWindowBgAlpha(0.92)
	im.SetNextWindowSize({380, 620}, .FirstUseEver)
	im.SetNextWindowSizeConstraints({260, 200}, {900, 1600})
	im.SetNextWindowPos({vp.WorkPos.x + 68, vp.WorkPos.y + 44}, .FirstUseEver)
	flags := im.WindowFlags{.NoDocking, .NoCollapse, .NoFocusOnAppearing}

	title: cstring = "Skeleton & Weight Tools###phat_bones_toolbar"
	if im.Begin(title, nil, flags) {
		io := im.GetIO()
		if io.KeyCtrl && io.MouseWheel != 0 && im.IsWindowHovered(im.HoveredFlags_RootWindow | im.HoveredFlags_ChildWindows) {
			old_scale := bones_toolbar_scale
			bones_toolbar_scale = clamp(bones_toolbar_scale + io.MouseWheel * 0.05, 0.65, 2.0)
			if abs(bones_toolbar_scale - old_scale) > 0.001 {
				cur_sz := im.GetWindowSize()
				factor := bones_toolbar_scale / old_scale
				im.SetWindowSize({cur_sz.x * factor, cur_sz.y * factor})
			}
		}

		st := im.GetStyle()
		has_scale := abs(bones_toolbar_scale - 1.0) > 0.01
		if has_scale {
			im.PushFontFloat(nil, st.FontSizeBase * bones_toolbar_scale)
			im.PushStyleVarImVec2(.FramePadding, {st.FramePadding.x * bones_toolbar_scale, st.FramePadding.y * bones_toolbar_scale})
			im.PushStyleVarImVec2(.ItemSpacing, {st.ItemSpacing.x * bones_toolbar_scale, st.ItemSpacing.y * bones_toolbar_scale})
			im.PushStyleVarImVec2(.ItemInnerSpacing, {st.ItemInnerSpacing.x * bones_toolbar_scale, st.ItemInnerSpacing.y * bones_toolbar_scale})
		}
		im.TextColoredUnformatted({0.20, 0.85, 0.35, 1.0}, fmt.ctprintf("%s Skeleton & Rig Tools", icons.ICON_MD_ACCOUNT_TREE))
		im.Separator()

		// 0. SKELETON MANAGEMENT
		im.TextDisabled("SKELETON MANAGEMENT")
		if im.Button(fmt.ctprintf("%s Spawn Skeleton Bones", icons.ICON_MD_ACCOUNT_TREE)) {
			sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(target_owner))}, "Spawn Skeleton Bones")
			crig.armature_deformed_mesh_spawn_skeleton(adm)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Reconstructs the authentic hierarchical bone tree transforms under this character actor.")

		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s Rebind", icons.ICON_MD_REFRESH)) {
			sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(target_owner))}, "Rebind Armature")
			crig.armature_deformed_mesh_rebind(adm)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Forces GPU dynamic mesh to rebind and re-find all bones in the hierarchy.")

		if im.Button(fmt.ctprintf("%s Reset T-Pose", icons.ICON_MD_REFRESH)) {
			sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(target_owner))}, "Reset T-Pose")
			crig.armature_deformed_mesh_reset_bind_pose(adm)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Restores authentic rest bind pose rotations and translations for all skeleton joints.")

		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s Purge Ghost Bones", icons.ICON_MD_DELETE)) {
			sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(target_owner))}, "Purge Ghost Bones")
			crig.armature_clean_ghost_bones(adm)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Scans and cleans up any phantom/ghost bones that were left without matching transform entities.")

		im.Separator()
		im.TextColoredUnformatted({0.95, 0.72, 0.25, 1.0}, fmt.ctprintf("%s Smart Anatomy Auto-Tools (Ray-Traced)", icons.ICON_MD_TUNE))
		im.Checkbox("Use Bone Heatmap Bounds##bone_hm_bounds", &crig.smart_rig_async_state.use_heatmap_bounds)
		widgets.tooltip("Uses each bone's vertex skin weight heatmap (w >= 0.25) to determine where its collider starts, ends, and centers in volume before ray-tracing.")
		im.Checkbox("Character Has Breasts", &crig.smart_rig_async_state.has_breasts)
		widgets.tooltip("Enable if this character mesh has breasts: flattens the main chest collider baseline to the ribcage and enables breast hill auto-rigging, recursive weight painting, and fitted breast SphereColliders.")

		if crig.smart_rig_async_state.has_breasts {
			rec_passes := i32(crig.smart_rig_async_state.recursion_passes)
			if im.SliderInt("Weight Smooth Passes", &rec_passes, 1, 6) {
				crig.smart_rig_async_state.recursion_passes = int(rec_passes)
			}
			widgets.tooltip("Number of recursive topological smoothing + hill-apex anchoring passes when auto-painting breast weights.")
			im.Checkbox("Attach Fitted Breast SphereColliders", &crig.smart_rig_async_state.attach_breast_colls)
			widgets.tooltip("Attaches fitted SphereColliders to breast_l / breast_r while keeping the main chest collider slim on the flattened ribcage.")

			if im.Button(fmt.ctprintf("%s Auto-Rig & Weight Breasts (Hill Trace)", icons.ICON_MD_TUNE)) {
				crig.smart_rig_async_start(target_owner, fit_colliders = false, rig_breasts = true)
			}
			widgets.tooltip("Virtually flattens the chest baseline via 2D front-to-back line traces, detects the Left & Right breast hills + gravity sag vectors, spawns breast_l & breast_r with SpringBone dynamics, and recursively paints smooth weights.")

			im.SameLine(0, 4)
		}

		if im.Button(fmt.ctprintf("%s Full Auto-Rig + Colliders", icons.ICON_MD_CROP_FREE)) {
			crig.smart_rig_async_start(target_owner, fit_colliders = true, rig_breasts = crig.smart_rig_async_state.has_breasts)
		}
		widgets.tooltip("Runs the async multi-pass ray-trace pipeline for spine, wrist-to-finger hand OBBs, and floor-planted foot boxes (plus breast hills if 'Character Has Breasts' is checked).")

		if crig.smart_rig_async_state.active {
			im.ProgressBar(crig.smart_rig_async_state.progress, {-70, 0}, strings.clone_to_cstring(crig.smart_rig_async_state.status_text, context.temp_allocator))
			im.SameLine(0, 4)
			if im.SmallButton("Cancel##cancel_async_bones") {
				crig.smart_rig_async_cancel()
			}
		} else if len(crig.smart_rig_async_state.last_summary) > 0 {
			im.TextColored({0.35, 0.92, 0.55, 1.0}, "%s", strings.clone_to_cstring(crig.smart_rig_async_state.last_summary, context.temp_allocator))
		}

		im.Separator()

		// 1. SELECTED BONE CONTEXT
		im.TextDisabled("SELECTED BONE")
		w := engine.ctx_world()
		is_bone := false
		is_custom := false
		bone_name := "None"
		if active_h != {} && active_h != target_owner && w != nil {
			for j in adm.joints {
				if j == active_h {
					is_bone = true
					break
				}
			}
			if is_bone {
				bt := engine.pool_get(&w.transforms, engine.Handle(active_h))
				if bt != nil {
					bone_name = bt.name
					for cn in adm.custom_joint_names {
						if cn == bone_name {
							is_custom = true
							break
						}
					}
					if !is_custom {
						mesh_guid := adm.mesh
						mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
						base_joints := mok && mesh != nil ? len(mesh.joint_names) : 0
						for j in 0 ..< len(adm.joints) {
							if adm.joints[j] == active_h && j >= base_joints {
								is_custom = true
								break
							}
						}
					}
				}
			}
		}

		// Quick Bone Selection Combo from joint hierarchy
		if len(adm.joints) > 0 {
			cur_bone_idx := -1
			for j, idx in adm.joints {
				if j == active_h {
					cur_bone_idx = idx
					break
				}
			}
			preview_str := cstring("Select bone to inspect...")
			if cur_bone_idx >= 0 && is_bone {
				preview_str = fmt.ctprintf("%s", bone_name)
			}
			if im.BeginCombo("##bone_selector_combo", preview_str) {
				for j, idx in adm.joints {
					if j == {} || !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue
					jt := engine.pool_get(&w.transforms, engine.Handle(j))
					if jt == nil do continue
					is_sel := (idx == cur_bone_idx)
					label := fmt.ctprintf("%s", jt.name)
					for cn in adm.custom_joint_names {
						if cn == jt.name {
							label = fmt.ctprintf("%s [Custom]", jt.name)
							break
						}
					}
					if im.Selectable(label, is_sel) {
						engine.inspector_request_select(j)
						crig.active_heatmap_bone_h = j
						crig.active_heatmap_joint_idx = idx
						adm.posed_frame = 0
						if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
					}
					if is_sel do im.SetItemDefaultFocus()
				}
				im.EndCombo()
			}
			widgets.tooltip("Choose which bone to inspect or paint weights for.")
		}

		if is_bone {
			im.TextColoredUnformatted({0.20, 0.85, 0.40, 1.0}, fmt.ctprintf("%s %s", icons.ICON_MD_ACCOUNT_TREE, bone_name))
			if is_custom {
				im.SameLine(0, 6)
				im.TextColored({0.25, 0.85, 0.95, 1.0}, "[Custom Bone]")
			}

			// Bone Rename Tool
			if bone_rename_tracked_h != active_h {
				bone_rename_tracked_h = active_h
				copy(bone_rename_buf[:], bone_name)
				bone_rename_buf[min(len(bone_name), len(bone_rename_buf)-1)] = 0
			}
			im.InputText("##rename_b_name", cstring(raw_data(bone_rename_buf[:])), len(bone_rename_buf))
			im.SameLine(0, 4)
			if im.Button(fmt.ctprintf("%s Rename", icons.ICON_MD_EDIT)) {
				raw_renamed := strings.string_from_null_terminated_ptr(raw_data(bone_rename_buf[:]), len(bone_rename_buf))
				cleaned := strings.trim_space(raw_renamed)
				if len(cleaned) > 0 && cleaned != bone_name {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Rename Bone")
					crig.armature_rename_bone(adm, active_h, cleaned)
					undo.edit_session_end(&sess)
				}
			}
			widgets.tooltip("Safely renames this bone transform and synchronizes all custom bone registrations so no ghost bones are created.")

			// Weight stats
			cnt, max_w, avg_w := crig.armature_get_bone_weight_stats(adm, active_h)
			im.TextColoredUnformatted({0.85, 0.85, 0.85, 1.0}, fmt.ctprintf("Influences %d vertices", cnt))
			im.TextDisabledUnformatted(fmt.ctprintf("Max Weight: %.2f | Avg: %.2f", max_w, avg_w))

			if im.Button(fmt.ctprintf("%s Reset Orientation", icons.ICON_MD_REFRESH)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Reset Bone Orientation")
				if bt := engine.pool_get(&w.transforms, engine.Handle(active_h)); bt != nil {
					bt.rotation = {0, 0, 0, 1}
				}
				undo.edit_session_end(&sess)
				if is_custom {
					crig.armature_set_bone_rest_pose(adm, active_h)
				}
				adm.posed_frame = 0
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			widgets.tooltip("Resets orientation of this bone back to rest orientation")

			if is_custom {
				im.SameLine(0, 4)
				if im.Button(fmt.ctprintf("%s Set as Rest Pose", icons.ICON_MD_CHECK)) {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Set Bone Rest Pose")
					crig.armature_set_bone_rest_pose(adm, active_h)
					undo.edit_session_end(&sess)
				}
				widgets.tooltip("Bakes this bone's current position and rotation as its rest/bind pose. Snaps jumped polygons back to their natural mesh position!")
			}

			if len(adm.custom_joint_names) > 0 {
				if im.Button(fmt.ctprintf("%s Set All Custom Bones as Rest Pose", icons.ICON_MD_SAVE)) {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Set All Custom Bones Rest Pose")
					crig.armature_set_all_custom_bones_rest_pose(adm)
					undo.edit_session_end(&sess)
				}
				widgets.tooltip("Updates rest/bind pose for all custom bones (e.g. l_breastBone, r_breastBone) to their current positions. Restores any deformed polygons back to the body!")
			}

			im.Spacing()

			// Add Child Bone under selected bone
			im.TextDisabled("ADD CHILD BONE")
			im.InputText("Name##new_b_name", cstring(raw_data(new_bone_name_buf[:])), len(new_bone_name_buf))
			im.DragFloat3("Offset##new_b_off", &new_bone_offset, 0.005, -1.0, 1.0, "%.3f m")
			if im.Button(fmt.ctprintf("%s Add Child Bone", icons.ICON_MD_ADD)) {
				raw_name := strings.string_from_null_terminated_ptr(raw_data(new_bone_name_buf[:]), len(new_bone_name_buf))
				cleaned := strings.trim_space(raw_name)
				if len(cleaned) == 0 do cleaned = fmt.tprintf("%s_child", bone_name)

				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Add Child Bone")
				new_h, ok := crig.armature_add_child_bone(adm, active_h, cleaned, new_bone_offset)
				undo.edit_session_end(&sess)
				if ok && new_h != {} {
					engine.inspector_request_select(new_h)
					crig.active_heatmap_bone_h = new_h
					crig.active_heatmap_joint_idx = crig.armature_get_bone_joint_index(adm, new_h)
					adm.posed_frame = 0
				}
			}
			widgets.tooltip("Spawns a new bone as a child of the selected bone, derives exact inverse bind matrix so no mesh popping occurs, and appends to armature joints.")

			if is_custom {
				im.SameLine(0, 4)
				if im.Button(fmt.ctprintf("%s Remove Bone", icons.ICON_MD_DELETE)) {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Remove Custom Bone")
					crig.armature_remove_custom_bone(adm, active_h)
					undo.edit_session_end(&sess)
					adm.posed_frame = 0
				}
				widgets.tooltip("Removes this custom bone, restores all stolen skin weights back to parent bone, and cleans up joint entries.")
			}

			im.Separator()

			// 2. SKIN WEIGHTS & FALLOFF
			im.TextDisabled("SKIN WEIGHT ADJUSTMENT")
			h_active := crig.show_bone_weights_heatmap
			if h_active {
				im.PushStyleColorImVec4(.Button, {0.15, 0.65, 0.85, 0.90})
				im.PushStyleColorImVec4(.ButtonHovered, {0.25, 0.75, 0.95, 1.00})
			}
			if im.Button(fmt.ctprintf("%s View Weights Heatmap", icons.ICON_MD_VISIBILITY)) {
				crig.show_bone_weights_heatmap = !crig.show_bone_weights_heatmap
				if crig.show_bone_weights_heatmap {
					crig.active_heatmap_bone_h = active_h
					crig.active_heatmap_joint_idx = crig.armature_get_bone_joint_index(adm, active_h)
				}
				adm.posed_frame = 0
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			if h_active do im.PopStyleColor(2)
			widgets.tooltip("Visualizes vertex skin weights for the selected bone (Cold Blue = 0, Green = 0.5, Bright Red = 1.0)")

			if crig.show_bone_weights_heatmap || weight_painter.enabled {
				if im.Checkbox("Unlit Shading (Vibrant Colors)", &crig.heatmap_shading_unlit) {
					adm.posed_frame = 0
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				widgets.tooltip("When checked (recommended), renders mesh in 100% emissive flat shading so bone heat colors are vibrant and not darkened by shadows, lighting, or character textures.")

				if im.Checkbox("Mesh Wireframe Overlay", &crig.show_mesh_wireframe) {
					adm.posed_frame = 0
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				widgets.tooltip("Displays geometric polygon wireframe of the skinned mesh so you can see exact triangles and vertices being painted.")

				if crig.show_mesh_wireframe {
					if im.SliderFloat("Wireframe Opacity", &crig.wireframe_overlay_color.a, 0.05, 1.00, "%.2f") {
						if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
					}
					widgets.tooltip("Adjusts opacity of the topological wireframe edges.")
				}

				im.Checkbox("Dim Other Bones", &crig.skeleton_settings.dim_inactive_bones_in_paint_mode)
				widgets.tooltip("Fades out non-selected bones while inspecting/painting weights so they don't block the mesh.")

				if crig.skeleton_settings.dim_inactive_bones_in_paint_mode {
					im.SliderFloat("Other Bones Opacity", &crig.skeleton_settings.inactive_bones_paint_alpha, 0.0, 0.40, "%.2f")
					widgets.tooltip("Opacity of non-selected bones in paint/heatmap mode.")
				}
			}

			// 2B. INTERACTIVE WEIGHT PAINT BRUSH (Blender-Inspired)
			im.Separator()
			im.TextDisabled("INTERACTIVE WEIGHT PAINT BRUSH")
			paint_active := weight_painter.enabled
			if paint_active {
				im.PushStyleColorImVec4(.Button, {0.90, 0.55, 0.15, 0.95})
				im.PushStyleColorImVec4(.ButtonHovered, {1.00, 0.65, 0.25, 1.00})
			}
			brush_btn_label := fmt.ctprintf("%s Weight Paint Brush: ON", icons.ICON_MD_EDIT) if paint_active else fmt.ctprintf("%s Weight Paint Brush: OFF", icons.ICON_MD_EDIT)
			if im.Button(brush_btn_label) {
				weight_painter.enabled = !weight_painter.enabled
				crig.weight_painting_active = weight_painter.enabled
				if weight_painter.enabled {
					crig.show_bone_weights_heatmap = true
					crig.show_mesh_wireframe = true
					crig.active_heatmap_bone_h = active_h
					crig.active_heatmap_joint_idx = crig.armature_get_bone_joint_index(adm, active_h)
				}
				adm.posed_frame = 0
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			if paint_active do im.PopStyleColor(2)
			widgets.tooltip("Toggle 3D interactive mesh surface weight brush. Drag with Left Mouse Button on the character mesh to paint live weights.")

			if weight_painter.enabled {
				mode_names := [4]cstring{"Paint (Target Weight)", "Add (+)", "Subtract (-)", "Smooth (Neighbor Blur)"}
				cur_m := int(weight_painter.mode)
				if im.BeginCombo("Brush Mode", mode_names[cur_m], {}) {
					for name, idx in mode_names {
						is_s := (idx == cur_m)
						if im.Selectable(name, is_s) {
							weight_painter.mode = Weight_Paint_Mode(idx)
						}
						if is_s do im.SetItemDefaultFocus()
					}
					im.EndCombo()
				}

				im.SliderFloat("Brush Radius", &weight_painter.radius, 0.002, 0.250, "%.3f m")
				widgets.tooltip("Radius of surface circle brush projected on character mesh (2mm to 25cm). Hotkeys: [ / ] or B + MouseWheel")
				im.SliderFloat("Brush Strength", &weight_painter.strength, 0.05, 1.00, "%.2f")
				widgets.tooltip("Stroke opacity per hit (0.05 to 1.00). Hotkeys: Shift + [ / ]")
				im.SliderFloat("Accumulation Speed", &weight_painter.flow_rate, 0.02, 1.00, "%.2f")
				widgets.tooltip("How rapidly weights accumulate when holding or tapping the mouse.")

				if weight_painter.mode != .Smooth {
					im.SliderFloat("Target Weight", &weight_painter.weight, 0.0, 1.0, "%.2f")
					widgets.tooltip("Target bone weight to paint towards (0.0 = completely erase / unpaint). Hotkeys: Ctrl + [ / ]")
					// Quick preset buttons for weight
					if im.Button("0.0 (Erase)") { weight_painter.weight = 0.0 }
					widgets.tooltip("Shortcut key: 0 or X")
					im.SameLine(0, 3)
					if im.Button("0.25") { weight_painter.weight = 0.25 }
					widgets.tooltip("Shortcut key: 1")
					im.SameLine(0, 3)
					if im.Button("0.50") { weight_painter.weight = 0.50 }
					widgets.tooltip("Shortcut key: 2")
					im.SameLine(0, 3)
					if im.Button("0.75") { weight_painter.weight = 0.75 }
					widgets.tooltip("Shortcut key: 3")
					im.SameLine(0, 3)
					if im.Button("1.0")  { weight_painter.weight = 1.0 }
					widgets.tooltip("Shortcut key: 4")

					im.TextDisabled("Hotkeys: [ / ] Radius | Shift+[] Strength | 0-4 Presets | X Erase")
				}
			}

			im.Separator()
			if im.Button(fmt.ctprintf("%s Mirror Bone & Weights (L <-> R)", icons.ICON_MD_CONTENT_COPY)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Mirror Bone & Weights")
				crig.armature_mirror_bone_and_weights(adm, active_h)
				undo.edit_session_end(&sess)
				adm.posed_frame = 0
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			widgets.tooltip("Symmetrically copies 1:1 vertex weights and SpringBone settings across the character's sagittal (lateral X) symmetry plane.")

			im.Separator()

			// 4. SECONDARY DYNAMICS (SPRING BONE)
			im.TextDisabled("SECONDARY DYNAMICS (SPRING BONE)")
			_, sb := engine.transform_get_comp(active_h, crig.SpringBone)
			if sb == nil {
				if im.Button(fmt.ctprintf("%s Add SpringBone Dynamics", icons.ICON_MD_ANIMATION)) {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Add SpringBone")
					_, raw := engine.transform_add_comp(active_h, .SpringBone)
					if raw != nil {
						sbc := cast(^crig.SpringBone)raw
						crig.reset_SpringBone(sbc)
						sbc.bone_length = 0.08
						sbc.forward_axis = {0, 0, 1}
						sbc.stiffness = spring_stiffness
						sbc.damping = spring_damping
						sbc.gravity = {0, spring_gravity_y, 0}
						sbc.max_angle_deg = spring_max_angle_deg
					}
					undo.edit_session_end(&sess)
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				widgets.tooltip("Attaches physical particle-tip spring dynamics to this bone for realistic jiggle and inertia.")
			} else {
				im.TextColored({0.20, 0.85, 0.95, 1.0}, "Active: Particle SpringBone")

				stiff := sb.stiffness
				changed_stiff := im.SliderFloat("Stiffness", &stiff, 1.0, 150.0, "%.1f")
				_begin_slider_undo_bone(active_h, "Adjust Spring Stiffness")
				if changed_stiff {
					sb.stiffness = stiff
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				_end_slider_undo_bone()

				damp := sb.damping
				changed_damp := im.SliderFloat("Damping", &damp, 0.05, 1.0, "%.2f")
				_begin_slider_undo_bone(active_h, "Adjust Spring Damping")
				if changed_damp {
					sb.damping = damp
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				_end_slider_undo_bone()

				cone_deg := sb.max_angle_deg
				changed_cone := im.SliderFloat("Max Cone Angle", &cone_deg, 5.0, 45.0, "%.1f°")
				_begin_slider_undo_bone(active_h, "Adjust Spring Safety Cone")
				if changed_cone {
					sb.max_angle_deg = cone_deg
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				_end_slider_undo_bone()

				grav_y := sb.gravity.y
				changed_grav := im.SliderFloat("Gravity Y", &grav_y, -20.0, 10.0, "%.1f m/s²")
				_begin_slider_undo_bone(active_h, "Adjust Spring Gravity")
				if changed_grav {
					sb.gravity.y = grav_y
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				_end_slider_undo_bone()

				bl := sb.bone_length
				changed_bl := im.SliderFloat("Bone Length", &bl, 0.02, 0.40, "%.3f m")
				_begin_slider_undo_bone(active_h, "Adjust Spring Bone Length")
				if changed_bl {
					sb.bone_length = max(0.01, bl)
					sb.initialized = false
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				_end_slider_undo_bone()

				if im.Button(fmt.ctprintf("%s Remove SpringBone", icons.ICON_MD_DELETE)) {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Remove SpringBone")
					owned, sb_comp := engine.transform_get_comp(active_h, crig.SpringBone)
					if sb_comp != nil do engine.transform_remove_comp(active_h, owned.handle)
					undo.edit_session_end(&sess)
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				widgets.tooltip("Removes spring physics simulation from this bone.")
			}
		} else {
			im.TextDisabled("Select any bone in the viewport\nto view weights, adjust falloff,\nadd child bones or apply SpringBone.")
		}

		// 4. OVERRIDES & ASSET PERSISTENCE
		im.Separator()
		im.TextDisabled("OVERRIDES & ASSET PERSISTENCE")
		cur_scene := engine.sm_scene_get_active()
		nested_inst := engine.scene_find_nested_scene_for_host(cur_scene, target_owner) if cur_scene != nil else nil
		if nested_inst != nil {
			ov_entries := engine.nested_scene_list_overrides(cur_scene, nested_inst)
			prefab_name := "Prefab"
			if p, pok := engine.asset_db_get_path(uuid.Identifier(nested_inst.source_prefab)); pok {
				prefab_name = filepath.base(p)
			}
			im.TextColoredUnformatted({0.20, 0.85, 0.95, 1.0}, fmt.ctprintf("Prefab: %s (%d Overrides)", prefab_name, len(ov_entries)))
			if len(ov_entries) > 0 {
				if im.Button(fmt.ctprintf("%s Save Overrides to Prefab", icons.ICON_MD_SAVE)) {
					undo.apply_to_prefab(cur_scene, target_owner, nested_inst.source_prefab, ov_entries, nil)
					if cur_scene != nil do cur_scene.dirty = true
				}
				widgets.tooltip("Applies all bone additions, skin weight edits, and collider changes back into the source prefab file.")

				im.SameLine(0, 4)
				if im.Button(fmt.ctprintf("%s Revert Overrides", icons.ICON_MD_REFRESH)) {
					for e in ov_entries {
						engine.nested_scene_revert_override(cur_scene, nested_inst, e.target, e.property_path)
					}
					adm.posed_frame = 0
					if cur_scene != nil do cur_scene.dirty = true
				}
				widgets.tooltip("Reverts all modifications back to the clean prefab state.")
			} else {
				im.TextDisabled("All overrides saved and up-to-date with Prefab.")
			}
		} else {
			im.TextDisabled("Actor: Scene Standalone Instance")
			if im.Button(fmt.ctprintf("%s Bake Mesh Rest Pose", icons.ICON_MD_SAVE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Bake Mesh Rest Pose")
				crig.armature_deformed_mesh_rebind(adm)
				undo.edit_session_end(&sess)
				adm.posed_frame = 0
				if cur_scene != nil do cur_scene.dirty = true
			}
			widgets.tooltip("Bakes current joint transforms into authentic bind matrices so current pose becomes the rest T-pose.")
		}
		// 5. SKELETON EDITS & PRESETS (FILE SAVE / LOAD / DELETE)
		im.Separator()
		_draw_skeleton_edits_file_ui(target_owner, adm)

		if has_scale {
			im.PopStyleVar(3)
			im.PopFont()
		}
	}
	im.End()
}

@(private = "file")
skeleton_preset_name_buf: [64]u8
@(private = "file")
selected_skel_file_idx:   int = -1
@(private = "file")
skeleton_status_msg:      string = ""
@(private = "file")
skeleton_status_is_err:   bool = false

@(private = "file")
cached_skel_files:       [dynamic]string
@(private = "file")
cached_skel_files_valid: bool = false

@(private = "file")
_refresh_skel_files_cache :: proc() {
	for s in cached_skel_files do delete(s)
	clear(&cached_skel_files)
	files := skeleton_edits_list_files(context.temp_allocator)
	for f in files {
		append(&cached_skel_files, strings.clone(f))
	}
	cached_skel_files_valid = true
}

@(private = "file")
_draw_skeleton_edits_file_ui :: proc(target_owner: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh) {
	if adm == nil do return
	w := engine.ctx_world()
	if w == nil do return

	if !cached_skel_files_valid {
		_refresh_skel_files_cache()
	}

	im.TextColoredUnformatted({0.20, 0.85, 0.95, 1.0}, fmt.ctprintf("%s Skeleton Presets (File Save / Load / Delete)", icons.ICON_MD_FOLDER_OPEN))
	widgets.tooltip("Direct file-based skeleton presets saved as flat binary in assets/skeleton_edits/*.mhskel.\nStores bone positions, rotations, scales, custom bones, SpringBone physics, and vertex skin weights.")

	mesh_name := "Mesh"
	if bt := engine.pool_get(&w.transforms, engine.Handle(target_owner)); bt != nil {
		mesh_name = bt.name
	}
	im.TextDisabledUnformatted(fmt.ctprintf("Target Mesh: %s", mesh_name))

	// Pre-fill default name if empty
	if skeleton_preset_name_buf[0] == 0 {
		def_name := fmt.tprintf("%s_edits", mesh_name)
		copy(skeleton_preset_name_buf[:], def_name)
		skeleton_preset_name_buf[min(len(def_name), len(skeleton_preset_name_buf)-1)] = 0
	}

	im.InputText("File Name##skel_preset_buf", cstring(raw_data(skeleton_preset_name_buf[:])), len(skeleton_preset_name_buf))
	widgets.tooltip("Name of the .mhskel binary file to save in assets/skeleton_edits/ (without extension).")

	raw_buf_name := strings.string_from_null_terminated_ptr(raw_data(skeleton_preset_name_buf[:]), len(skeleton_preset_name_buf))
	cleaned_buf_name := strings.trim_space(raw_buf_name)

	if im.Button(fmt.ctprintf("%s Save Skeleton Edits to File", icons.ICON_MD_SAVE)) {
		if len(cleaned_buf_name) == 0 {
			skeleton_status_msg = "Error: File name cannot be empty."
			skeleton_status_is_err = true
		} else {
			path, count, ok := skeleton_edits_save_to_file(adm, cleaned_buf_name)
			if ok {
				skeleton_status_msg = fmt.tprintf("Saved %d bones to %s", count, path)
				skeleton_status_is_err = false
				_refresh_skel_files_cache()
			} else {
				skeleton_status_msg = "Failed to save skeleton edits file."
				skeleton_status_is_err = true
			}
		}
	}
	widgets.tooltip("Saves bone transforms (pos, rot, scale), custom bones (with SpringBone dynamics), and custom skin weights directly to disk as flat Odin binary (.mhskel).")

	files := cached_skel_files[:]
	if len(files) == 0 {
		im.TextDisabled("No saved presets found in assets/skeleton_edits/")
		im.SameLine(0, 4)
		if im.SmallButton(fmt.ctprintf("%s##RefreshPresetsEmpty", icons.ICON_MD_REFRESH)) {
			_refresh_skel_files_cache()
		}
	} else {
		if selected_skel_file_idx < 0 || selected_skel_file_idx >= len(files) {
			selected_skel_file_idx = 0
		}
		curr_sel_file := files[selected_skel_file_idx]

		if im.BeginCombo("Saved Preset", fmt.ctprintf("%s.mhskel", curr_sel_file), {}) {
			for f, idx in files {
				is_s := (idx == selected_skel_file_idx)
				if im.Selectable(fmt.ctprintf("%s %s.mhskel", icons.ICON_MD_DESCRIPTION, f), is_s) {
					selected_skel_file_idx = idx
					copy(skeleton_preset_name_buf[:], f)
					skeleton_preset_name_buf[min(len(f), len(skeleton_preset_name_buf)-1)] = 0
				}
				if is_s do im.SetItemDefaultFocus()
			}
			im.EndCombo()
		}
		im.SameLine(0, 4)
		if im.SmallButton(fmt.ctprintf("%s##RefreshPresets", icons.ICON_MD_REFRESH)) {
			_refresh_skel_files_cache()
		}
		widgets.tooltip("Scan assets/skeleton_edits/ for newly added or renamed files")

		selected_preset := files[selected_skel_file_idx]

		if im.Button(fmt.ctprintf("%s Load Selected Preset", icons.ICON_MD_FOLDER_OPEN)) {
			sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(adm.owner))}, "Load Skeleton Edits")
			b_cnt, c_cnt, ok := skeleton_edits_load_from_file(adm, selected_preset)
			undo.edit_session_end(&sess)
			if ok {
				skeleton_status_msg = fmt.tprintf("Loaded %d bones (%d custom) from %s.mhskel", b_cnt, c_cnt, selected_preset)
				skeleton_status_is_err = false
			} else {
				skeleton_status_msg = fmt.tprintf("Failed to load %s.mhskel", selected_preset)
				skeleton_status_is_err = true
			}
		}
		widgets.tooltip("Loads bone transforms, custom bones, and skin weights from assets/skeleton_edits/<name>.mhskel and updates rest pose.")

		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s Delete File", icons.ICON_MD_DELETE)) {
			if skeleton_edits_delete_file(selected_preset) {
				skeleton_status_msg = fmt.tprintf("Deleted %s.mhskel", selected_preset)
				skeleton_status_is_err = false
				_refresh_skel_files_cache()
				if selected_skel_file_idx >= len(cached_skel_files) - 1 {
					selected_skel_file_idx = max(0, len(cached_skel_files) - 2)
				}
			} else {
				skeleton_status_msg = fmt.tprintf("Failed to delete %s.mhskel", selected_preset)
				skeleton_status_is_err = true
			}
		}
		widgets.tooltip("Permanently deletes the selected .mhskel preset file from assets/skeleton_edits/.")
	}

	if len(skeleton_status_msg) > 0 {
		col := [4]f32{0.95, 0.35, 0.35, 1.0} if skeleton_status_is_err else [4]f32{0.30, 0.90, 0.40, 1.0}
		im.TextColoredUnformatted(col, fmt.ctprintf("%s", skeleton_status_msg))
	}
}

@(private = "file")
_draw_colliders_left_toolbar :: proc(target_owner: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh, active_h: engine.Transform_Handle) {
	if adm == nil do return

	vp := im.GetMainViewport()
	im.SetNextWindowViewport(vp.ID_)
	im.SetNextWindowBgAlpha(0.92)
	im.SetNextWindowSize({340, 560}, .FirstUseEver)
	im.SetNextWindowSizeConstraints({240, 200}, {800, 1400})
	im.SetNextWindowPos({vp.WorkPos.x + 68, vp.WorkPos.y + 44}, .FirstUseEver)
	flags := im.WindowFlags{.NoDocking, .NoCollapse}

	title: cstring = "PhAT Collision Tools###phat_colliders_toolbar"
	if im.Begin(title, nil, flags) {
		io := im.GetIO()
		if io.KeyCtrl && io.MouseWheel != 0 && im.IsWindowHovered(im.HoveredFlags_RootWindow | im.HoveredFlags_ChildWindows) {
			old_scale := colliders_toolbar_scale
			colliders_toolbar_scale = clamp(colliders_toolbar_scale + io.MouseWheel * 0.05, 0.65, 2.0)
			if abs(colliders_toolbar_scale - old_scale) > 0.001 {
				cur_sz := im.GetWindowSize()
				factor := colliders_toolbar_scale / old_scale
				im.SetWindowSize({cur_sz.x * factor, cur_sz.y * factor})
			}
		}

		st := im.GetStyle()
		has_scale := abs(colliders_toolbar_scale - 1.0) > 0.01
		if has_scale {
			im.PushFontFloat(nil, st.FontSizeBase * colliders_toolbar_scale)
			im.PushStyleVarImVec2(.FramePadding, {st.FramePadding.x * colliders_toolbar_scale, st.FramePadding.y * colliders_toolbar_scale})
			im.PushStyleVarImVec2(.ItemSpacing, {st.ItemSpacing.x * colliders_toolbar_scale, st.ItemSpacing.y * colliders_toolbar_scale})
			im.PushStyleVarImVec2(.ItemInnerSpacing, {st.ItemInnerSpacing.x * colliders_toolbar_scale, st.ItemInnerSpacing.y * colliders_toolbar_scale})
		}
		im.TextColoredUnformatted({0.95, 0.60, 0.20, 1.0}, fmt.ctprintf("%s Collider Authoring", icons.ICON_MD_CROP_FREE))
		im.Separator()

		// 0. VIEW DISPLAY
		im.TextDisabled("VIEW DISPLAY")
		cur_s := i32(collider_shading_mode)
		if im.Combo("Shading", &cur_s, "Semi-Transparent\x00Wireframe Only\x00Solid Only\x00") {
			collider_shading_mode = Collider_Shading_Mode(cur_s)
		}
		if collider_shading_mode != .Wireframe {
			im.SliderFloat("Opacity", &collider_solid_alpha, 0.05, 0.90, "%.2f")
		}

		im.Separator()

		// 1. GLOBAL RIG TOOLS
		im.TextDisabled("GLOBAL RAY-TRACED RIG TOOLS")
		mp_cnt := i32(crig.smart_rig_async_state.multipass_count)
		if im.SliderInt("Ray-Trace Passes", &mp_cnt, 1, 4) {
			crig.smart_rig_async_state.multipass_count = int(mp_cnt)
		}
		widgets.tooltip("Number of multi-pass cross-section & OBB ray-trace slices per bone (higher = tighter fit on complex meshes).")

		im.Checkbox("Use Bone Heatmap Bounds##coll_hm_bounds", &crig.smart_rig_async_state.use_heatmap_bounds)
		widgets.tooltip("Uses each bone's vertex skin weight heatmap (w >= 0.25) to determine where its collider starts, ends, and centers in volume before ray-tracing.")

		im.Checkbox("Character Has Breasts##coll_has_breasts", &crig.smart_rig_async_state.has_breasts)
		widgets.tooltip("When checked: flattens the main chest collider to the ribcage baseline (so it doesn't oversize over the breasts) and fits dedicated SphereColliders to breast_l / breast_r.")

		if im.Button(fmt.ctprintf("%s Auto-Fit All (Async Ray-Trace)", icons.ICON_MD_REFRESH)) {
			crig.smart_rig_async_start(target_owner, fit_colliders = true, rig_breasts = crig.smart_rig_async_state.has_breasts)
		}
		widgets.tooltip("Asynchronously traces spine segments, wrist-to-fingertip hand OBBs, and floor-planted foot boxes (plus flattened ribcage & breast SphereColliders if 'Character Has Breasts' is checked).")

		im.SameLine(0, 4)
		if im.Button(fmt.ctprintf("%s Clear All", icons.ICON_MD_DELETE)) {
			sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(target_owner))}, "Clear All Colliders")
			crig.smart_collider_remove_humanoid(target_owner)
			undo.edit_session_end(&sess)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		widgets.tooltip("Removes all collider components across all bones of this character.")

		if crig.smart_rig_async_state.has_breasts {
			if im.Button(fmt.ctprintf("%s Auto-Rig Breasts + Colliders (Hill Trace)", icons.ICON_MD_TUNE)) {
				crig.smart_rig_async_state.attach_breast_colls = true
				crig.smart_rig_async_start(target_owner, fit_colliders = false, rig_breasts = true)
			}
			widgets.tooltip("Cuts a virtual flat chest baseline via line traces to detect breast hills, spawns breast_l/breast_r + SpringBone + fitted SphereColliders, and refits the chest collider to the ribcage.")
		}

		if crig.smart_rig_async_state.active {
			im.ProgressBar(crig.smart_rig_async_state.progress, {-70, 0}, strings.clone_to_cstring(crig.smart_rig_async_state.status_text, context.temp_allocator))
			im.SameLine(0, 4)
			if im.SmallButton("Cancel##cancel_async_colls") {
				crig.smart_rig_async_cancel()
			}
		} else if len(crig.smart_rig_async_state.last_summary) > 0 {
			im.TextColored({0.35, 0.92, 0.55, 1.0}, "%s", strings.clone_to_cstring(crig.smart_rig_async_state.last_summary, context.temp_allocator))
		}

		im.Separator()
		im.TextColored({0.95, 0.45, 0.35, 1.0}, "GHOUL CSG MODE (DISMEMBERMENT)")
		@(static) ghoul_tight_hm := true
		@(static) ghoul_test_rad: f32 = 0.14
		im.Checkbox("Tight Heatmap Hull Fit##ghoul_hm", &ghoul_tight_hm)
		widgets.tooltip("Blends your manually adjusted collider bounds with each bone's weighted vertex heatmap to build form-fitting Ghoul CSG volumes.")

		im.PushStyleColorImVec4(.Button, {0.68, 0.22, 0.20, 0.96})
		if im.Button(fmt.ctprintf("%s Build Ghoul CSG Colliders (All Bones)", icons.ICON_MD_WIDGETS)) {
			built := crig.smart_collider_build_ghoul_csg_humanoid(target_owner, ghoul_tight_hm)
			crig.smart_rig_async_state.last_summary = fmt.aprintf("Built %d Ghoul CSG Limb Volumes!", built)
		}
		im.PopStyleColor(1)
		widgets.tooltip("Converts all bone colliders on this character into destructible Ghoul CSGVolumes (keeps your Capsule/Box/Sphere colliders intact!). Shoot/blast limbs with the Geo-Mod Blast Tool or test below.")

		if im.SmallButton("Heal All Wounds") {
			_ = crig.smart_collider_reset_ghoul_wounds(target_owner)
		}
		widgets.tooltip("Resets all recorded Geo-Mod blasts on all bone Ghoul CSGVolumes and restores the character mesh to 100% pristine.")
		im.SameLine(0, 6)
		if im.SmallButton("Remove Ghoul CSG") {
			_ = crig.smart_collider_remove_ghoul_csg_humanoid(target_owner)
		}
		widgets.tooltip("Removes bone-attached CSGVolume components while keeping your Capsule/Box/Sphere colliders untouched.")

		im.Separator()

		// 2. SELECTED BONE CONTEXT
		im.TextDisabled("SELECTED BONE")
		is_bone := false
		if active_h != {} && active_h != target_owner {
			for j in adm.joints {
				if j == active_h {
					is_bone = true
					break
				}
			}
		}

		if is_bone {
			w := engine.ctx_world()
			bone_t := engine.pool_get(&w.transforms, engine.Handle(active_h))
			bone_name := bone_t != nil ? bone_t.name : "Bone"
			im.TextColoredUnformatted({0.20, 0.85, 1.00, 1.0}, fmt.ctprintf("%s %s", icons.ICON_MD_ACCOUNT_TREE, bone_name))

			_, cap := engine.transform_get_comp(active_h, physics3d.CapsuleCollider)
			_, box := engine.transform_get_comp(active_h, physics3d.BoxCollider)
			_, sph := engine.transform_get_comp(active_h, physics3d.SphereCollider)
			_, g_vol := engine.transform_get_comp(active_h, cad_csg.CSGVolume)

			if cap != nil {
				im.TextColored({0.30, 0.90, 0.40, 1.0}, "Active: Capsule Collider")
			} else if box != nil {
				im.TextColored({0.30, 0.90, 0.40, 1.0}, "Active: Box Collider")
			} else if sph != nil {
				im.TextColored({0.30, 0.90, 0.40, 1.0}, "Active: Sphere Collider")
			} else {
				im.TextDisabled("No collider on this bone")
			}
			if g_vol != nil {
				im.TextColoredUnformatted({1.0, 0.55, 0.25, 1.0}, fmt.ctprintf("Ghoul CSG Active (%d Wounds)", len(g_vol.recorded_blasts)))
			}

			im.Spacing()
			im.TextDisabled("CREATION & FITTING")

			if im.Button(fmt.ctprintf("%s Auto-Fit Bone", icons.ICON_MD_CROP_FREE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Auto-Fit Bone Collider")
				crig.smart_collider_add_bone_auto(active_h)
				undo.edit_session_end(&sess)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			widgets.tooltip("Measures vector to child bone and generates a perfectly oriented capsule.")

			im.SameLine(0, 4)
			if im.Button("+ Capsule") {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Attach Capsule Collider")
				crig.smart_collider_add_capsule(active_h)
				undo.edit_session_end(&sess)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}

			if im.Button("+ Box") {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Attach Box Collider")
				crig.smart_collider_add_box(active_h)
				undo.edit_session_end(&sess)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			im.SameLine(0, 4)
			if im.Button("+ Sphere") {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Attach Sphere Collider")
				crig.smart_collider_add_sphere(active_h)
				undo.edit_session_end(&sess)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}

			if cap != nil || box != nil || sph != nil {
				im.Separator()
				im.TextDisabled("SYMMETRY & REMOVAL")

				opp_h, has_opp := _find_opposite_bone(active_h, adm)
				if has_opp {
					im.Checkbox("Auto-Mirror 3D Gizmo (L <-> R)##col_auto_mir", &auto_mirror_collider_gizmo)
					widgets.tooltip("When enabled, moving/rotating/scaling a left or right collider with the 3D gizmo automatically mirrors to the opposite bone!")
					if im.Button(fmt.ctprintf("%s Mirror to Opposite Bone", icons.ICON_MD_CONTENT_COPY)) {
						sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(opp_h))}, "Mirror Bone Collider")
						_mirror_bone_collider(active_h, adm)
						undo.edit_session_end(&sess)
					}
					opp_t := engine.pool_get(&w.transforms, engine.Handle(opp_h))
					opp_name := opp_t != nil ? opp_t.name : "opposite"
					widgets.tooltip(fmt.ctprintf("Copies collider dimensions and inverts lateral offset to bone '%s'", opp_name))
				}

				if im.Button(fmt.ctprintf("%s Remove Collider", icons.ICON_MD_DELETE)) {
					sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(active_h))}, "Remove Bone Collider")
					crig.smart_collider_remove_from_bone(active_h)
					undo.edit_session_end(&sess)
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				widgets.tooltip("Removes collider component from this bone (bone entity is kept).")

				im.Spacing()
				im.SetNextItemWidth(130)
				im.SliderFloat("Blast Rad##ghoul_r", &ghoul_test_rad, 0.06, 0.35, "%.2f m")
				im.PushStyleColorImVec4(.Button, {0.75, 0.22, 0.22, 0.95})
				if im.Button("Test Ghoul Blast / Dismember Bone") {
					crig.smart_collider_test_ghoul_blast_on_bone(active_h, ghoul_test_rad)
				}
				im.PopStyleColor(1)
				widgets.tooltip("Fires a test Geo-Mod Ghoul blast at this bone's collider center (carves a wound if Blast Rad < bone thickness, or severs the limb & downstream bones if Blast Rad >= bone thickness!).")
			}
		} else {
			im.TextDisabled("Select any bone in the viewport\nto add, fit, mirror or edit colliders.")
		}
		if has_scale {
			im.PopStyleVar(3)
			im.PopFont()
		}
	}
	im.End()
}

draw_bone_collider_inspector_floating :: proc(bone_h: engine.Transform_Handle, adm: ^crig.ArmatureDeformedMesh) {
	if bone_h == {} || adm == nil do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return

	bone_t := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bone_t == nil do return

	owned_cap, cap := engine.transform_get_comp(bone_h, physics3d.CapsuleCollider)
	owned_box, box := engine.transform_get_comp(bone_h, physics3d.BoxCollider)
	owned_sph, sph := engine.transform_get_comp(bone_h, physics3d.SphereCollider)

	// In Control Rig mode, show if bone has a collider OR show_bone_colliders toggle is on
	if cap == nil && box == nil && sph == nil && !show_bone_colliders do return

	im.SetNextWindowViewport(im.GetMainViewport().ID_)
	im.SetNextWindowBgAlpha(0.92)
	im.SetNextWindowSizeConstraints({270, 120}, {390, 560})
	flags := im.WindowFlags{.AlwaysAutoResize, .NoDocking}

	title: cstring = "Bone Collider Inspector###bone_col_insp"
	if im.Begin(title, nil, flags) {
		im.TextColoredUnformatted({1.0, 0.85, 0.20, 1.0}, fmt.ctprintf("%s Bone: %s", icons.ICON_MD_CROP_FREE, bone_t.name))
		im.Separator()

		if cap != nil {
			im.TextColored({0.25, 0.85, 0.35, 1.0}, "Collider: Capsule")
			im.Spacing()

			// Radius
			r := cap.radius
			if math.is_nan(r) do r = 0.05
			changed_r := im.SliderFloat("Radius", &r, 0.01, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Collider Radius")
			if changed_r {
				cap.radius = max(0.005, r)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo_bone()

			// Height
			h := cap.height
			if math.is_nan(h) do h = 0.10
			changed_h := im.SliderFloat("Height", &h, 0.02, 1.50, "%.3f m")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Collider Height")
			if changed_h {
				cap.height = max(cap.radius * 2.0, h)
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo_bone()

			// Center Offset X, Y, Z
			c := cap.center
			if math.is_nan(c.x) do c.x = 0
			if math.is_nan(c.y) do c.y = 0
			if math.is_nan(c.z) do c.z = 0
			changed_cx := im.SliderFloat("Center X", &c.x, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Collider Center X")
			if changed_cx {
				cap.center.x = c.x
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo_bone()

			changed_cy := im.SliderFloat("Center Y", &c.y, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Collider Center Y")
			if changed_cy {
				cap.center.y = c.y
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo_bone()

			changed_cz := im.SliderFloat("Center Z", &c.z, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Collider Center Z")
			if changed_cz {
				cap.center.z = c.z
				if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
			}
			_end_slider_undo_bone()

			// Direction Axis
			dir_names := [3]cstring{"X Axis", "Y Axis", "Z Axis"}
			cur_dir := int(cap.direction)
			if cur_dir < 0 || cur_dir >= 3 do cur_dir = 1
			if im.BeginCombo("Axis", dir_names[cur_dir], {}) {
				for name, idx in dir_names {
					is_s := (idx == cur_dir)
					if im.Selectable(name, is_s) {
						sess := undo.edit_session_begin({undo.edit_target_whole(owned_cap.handle)}, "Change Collider Axis")
						cap.direction = physics3d.Capsule_Direction(idx)
						undo.edit_session_end(&sess)
						if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
					}
					if is_s do im.SetItemDefaultFocus()
				}
				im.EndCombo()
			}

			im.Separator()
			im.TextDisabled("ORIENTATION")
			if cap.rotation == {} || (cap.rotation.x*cap.rotation.x + cap.rotation.y*cap.rotation.y + cap.rotation.z*cap.rotation.z + cap.rotation.w*cap.rotation.w) < 1e-4 do cap.rotation = {0, 0, 0, 1}
			cap_euler := engine.quat_to_euler_xyz(cap.rotation)
			if math.is_nan(cap_euler.x) || math.is_nan(cap_euler.y) || math.is_nan(cap_euler.z) do cap_euler = {0, 0, 0}
			changed_crx := im.SliderFloat("Pitch (X)", &cap_euler.x, -180.0, 180.0, "%.1f°")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Capsule Pitch")
			if changed_crx {
				cap.rotation = engine.quat_from_euler_xyz(cap_euler.x, cap_euler.y, cap_euler.z)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			_end_slider_undo_bone()

			changed_cry := im.SliderFloat("Yaw (Y)", &cap_euler.y, -180.0, 180.0, "%.1f°")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Capsule Yaw")
			if changed_cry {
				cap.rotation = engine.quat_from_euler_xyz(cap_euler.x, cap_euler.y, cap_euler.z)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			_end_slider_undo_bone()

			changed_crz := im.SliderFloat("Roll (Z)", &cap_euler.z, -180.0, 180.0, "%.1f°")
			_begin_slider_undo_comp(owned_cap.handle, "Adjust Capsule Roll")
			if changed_crz {
				cap.rotation = engine.quat_from_euler_xyz(cap_euler.x, cap_euler.y, cap_euler.z)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			_end_slider_undo_bone()

			if im.Button(fmt.ctprintf("%s Reset Rot", icons.ICON_MD_REFRESH)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(owned_cap.handle)}, "Reset Capsule Rotation")
				cap.rotation = {0, 0, 0, 1}
				undo.edit_session_end(&sess)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			widgets.tooltip("Resets collider local rotation back to bone alignment")

			im.Separator()

			// Auto-Fit button
			if im.Button(fmt.ctprintf("%s Auto-Fit to Bone", icons.ICON_MD_CROP_FREE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Auto-Fit Bone Collider")
				crig.smart_collider_add_bone_auto(bone_h)
				undo.edit_session_end(&sess)
			}
			widgets.tooltip("Measures distance to child bone and automatically sizes radius, height, and axis")

			im.SameLine(0, 4)
			if im.Button(fmt.ctprintf("%s Remove", icons.ICON_MD_DELETE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Remove Bone Collider")
				crig.smart_collider_remove_from_bone(bone_h)
				undo.edit_session_end(&sess)
			}
			widgets.tooltip("Removes collider component (bone remains intact)")

			im.Spacing()
			im.TextDisabled("3D Handles: Press 'T' (left sidebar Handles tool) to drag bounds in viewport")
		} else if box != nil {
			im.TextColored({0.25, 0.85, 0.35, 1.0}, "Collider: Box")
			im.Spacing()

			s := box.size
			if math.is_nan(s.x) do s.x = 0.1
			if math.is_nan(s.y) do s.y = 0.1
			if math.is_nan(s.z) do s.z = 0.1
			c := box.center
			if math.is_nan(c.x) do c.x = 0
			if math.is_nan(c.y) do c.y = 0
			if math.is_nan(c.z) do c.z = 0

			changed_sx := im.SliderFloat("Size X", &s.x, 0.01, 0.80, "%.3f m")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Size X")
			if changed_sx { box.size.x = max(0.01, s.x); if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_sy := im.SliderFloat("Size Y", &s.y, 0.01, 0.80, "%.3f m")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Size Y")
			if changed_sy { box.size.y = max(0.01, s.y); if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_sz := im.SliderFloat("Size Z", &s.z, 0.01, 0.80, "%.3f m")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Size Z")
			if changed_sz { box.size.z = max(0.01, s.z); if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_cx := im.SliderFloat("Center X", &c.x, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Center X")
			if changed_cx { box.center.x = c.x; if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_cy := im.SliderFloat("Center Y", &c.y, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Center Y")
			if changed_cy { box.center.y = c.y; if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_cz := im.SliderFloat("Center Z", &c.z, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Center Z")
			if changed_cz { box.center.z = c.z; if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			im.Separator()
			im.TextDisabled("ORIENTATION")
			if box.rotation == {} || (box.rotation.x*box.rotation.x + box.rotation.y*box.rotation.y + box.rotation.z*box.rotation.z + box.rotation.w*box.rotation.w) < 1e-4 do box.rotation = {0, 0, 0, 1}
			box_euler := engine.quat_to_euler_xyz(box.rotation)
			if math.is_nan(box_euler.x) || math.is_nan(box_euler.y) || math.is_nan(box_euler.z) do box_euler = {0, 0, 0}
			changed_bx := im.SliderFloat("Pitch (X)", &box_euler.x, -180.0, 180.0, "%.1f°")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Pitch")
			if changed_bx {
				box.rotation = engine.quat_from_euler_xyz(box_euler.x, box_euler.y, box_euler.z)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			_end_slider_undo_bone()

			changed_by := im.SliderFloat("Yaw (Y)", &box_euler.y, -180.0, 180.0, "%.1f°")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Yaw")
			if changed_by {
				box.rotation = engine.quat_from_euler_xyz(box_euler.x, box_euler.y, box_euler.z)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			_end_slider_undo_bone()

			changed_bz := im.SliderFloat("Roll (Z)", &box_euler.z, -180.0, 180.0, "%.1f°")
			_begin_slider_undo_comp(owned_box.handle, "Adjust Box Roll")
			if changed_bz {
				box.rotation = engine.quat_from_euler_xyz(box_euler.x, box_euler.y, box_euler.z)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			_end_slider_undo_bone()

			if im.Button(fmt.ctprintf("%s Flatten to Floor", icons.ICON_MD_SNAP)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(owned_box.handle)}, "Flatten Box to Floor")
				flat_rot := crig.calculate_flat_floor_rotation(bone_h)
				if flat_rot != {} && (flat_rot.x*flat_rot.x + flat_rot.y*flat_rot.y + flat_rot.z*flat_rot.z + flat_rot.w*flat_rot.w) > 1e-4 {
					box.rotation = flat_rot
				}
				undo.edit_session_end(&sess)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			widgets.tooltip("Aligns the box collider bottom flat with the horizontal ground plane (XZ), compensating for ankle bone tilt")

			im.SameLine(0, 4)
			if im.Button(fmt.ctprintf("%s Reset Rot", icons.ICON_MD_REFRESH)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(owned_box.handle)}, "Reset Box Rotation")
				box.rotation = {0, 0, 0, 1}
				undo.edit_session_end(&sess)
				if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
			}
			widgets.tooltip("Resets collider local rotation back to bone alignment")

			im.Separator()
			if im.Button(fmt.ctprintf("%s Remove", icons.ICON_MD_DELETE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Remove Bone Collider")
				crig.smart_collider_remove_from_bone(bone_h)
				undo.edit_session_end(&sess)
			}
		} else if sph != nil {
			im.TextColored({0.25, 0.85, 0.35, 1.0}, "Collider: Sphere")
			im.Spacing()

			r := sph.radius
			if math.is_nan(r) do r = 0.05
			c := sph.center
			if math.is_nan(c.x) do c.x = 0
			if math.is_nan(c.y) do c.y = 0
			if math.is_nan(c.z) do c.z = 0

			changed_r := im.SliderFloat("Radius", &r, 0.01, 0.50, "%.3f m")
			_begin_slider_undo_comp(owned_sph.handle, "Adjust Sphere Radius")
			if changed_r { sph.radius = max(0.005, r); if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_cx := im.SliderFloat("Center X", &c.x, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_sph.handle, "Adjust Sphere Center X")
			if changed_cx { sph.center.x = c.x; if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_cy := im.SliderFloat("Center Y", &c.y, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_sph.handle, "Adjust Sphere Center Y")
			if changed_cy { sph.center.y = c.y; if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			changed_cz := im.SliderFloat("Center Z", &c.z, -0.40, 0.40, "%.3f m")
			_begin_slider_undo_comp(owned_sph.handle, "Adjust Sphere Center Z")
			if changed_cz { sph.center.z = c.z; if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true }
			_end_slider_undo_bone()

			im.Separator()
			if im.Button(fmt.ctprintf("%s Remove", icons.ICON_MD_DELETE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Remove Bone Collider")
				crig.smart_collider_remove_from_bone(bone_h)
				undo.edit_session_end(&sess)
			}
		} else {
			im.TextDisabled("No collider attached to this bone.")
			im.Spacing()
			if im.Button(fmt.ctprintf("%s Auto-Fit Capsule", icons.ICON_MD_CROP_FREE)) {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Attach Bone Collider")
				crig.smart_collider_add_bone_auto(bone_h)
				undo.edit_session_end(&sess)
			}
			widgets.tooltip("Measures distance to child bone and automatically sizes radius, height, and axis")

			im.SameLine(0, 4)
			if im.Button("+ Capsule") {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Attach Capsule Collider")
				crig.smart_collider_add_capsule(bone_h)
				undo.edit_session_end(&sess)
			}
			if im.Button("+ Box") {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Attach Box Collider")
				crig.smart_collider_add_box(bone_h)
				undo.edit_session_end(&sess)
			}
			im.SameLine(0, 4)
			if im.Button("+ Sphere") {
				sess := undo.edit_session_begin({undo.edit_target_whole(engine.Handle(bone_h))}, "Attach Sphere Collider")
				crig.smart_collider_add_sphere(bone_h)
				undo.edit_session_end(&sess)
			}
		}
	}
	im.End()
}

draw_control_visuals_popup_content :: proc(rig: ^crig.ControlRig) {
	if rig == nil do return
	pal := thm.palette()

	im.TextColoredUnformatted(pal.accent, fmt.ctprintf("%s Rig Control Shape & Visuals", icons.ICON_MD_PALETTE))
	im.Separator()

	im.Checkbox("Show All 3D Control Labels", &show_all_rig_labels)
	widgets.tooltip("When off (default), 3D labels only appear when hovering or selecting a control to keep the viewport clean.")
	im.Separator()

	control_names := [9]cstring{
		"Pelvis (Hips)",
		"Mid Spine (Waist)",
		"Upper Chest",
		"Head",
		"Eye Level Socket",
		"Left Foot",
		"Right Foot",
		"Left Hand",
		"Right Hand",
	}
	control_enums := [9]Active_Rig_Control{
		.Pelvis,
		.Spine,
		.Chest,
		.Head,
		.Eye_Level_Socket,
		.Left_Foot,
		.Right_Foot,
		.Left_Hand,
		.Right_Hand,
	}

	cur_idx := 0
	for c, i in control_enums {
		if c in selected_rig_controls || c == active_rig_control {
			cur_idx = i
			break
		}
	}

	if im.BeginCombo("Control", control_names[cur_idx], {}) {
		for name, i in control_names {
			is_sel := (i == cur_idx)
			if im.Selectable(name, is_sel) {
				cur_idx = i
				select_rig_control(engine.Transform_Handle(rig.owner), control_enums[i], false)
			}
			if is_sel do im.SetItemDefaultFocus()
		}
		im.EndCombo()
	}

	target_rc := _get_rig_control(rig, control_enums[cur_idx])
	if target_rc == nil do target_rc = &rig.pelvis

	if target_rc != nil {
		im.Spacing()

		shape_names := [10]cstring{
			"Circle (XZ horizontal)",
			"Circle Normal (XY facing)",
			"Ring (Double circle)",
			"Square (XZ horizontal)",
			"Square Normal (XY facing)",
			"Diamond (Rhombus)",
			"Cross (+)",
			"Arrow (Directional)",
			"Cube (Wire box)",
			"Sphere (Wire ball)",
		}
		cur_shape := int(target_rc.shape)
		if cur_shape < 0 || cur_shape >= 10 do cur_shape = 0
		if im.BeginCombo("Shape", shape_names[cur_shape], {}) {
			for name, idx in shape_names {
				is_s := (idx == cur_shape)
				if im.Selectable(name, is_s) {
					owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
					sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Change Rig Control Shape")
					target_rc.shape = crig.Control_Shape_Type(idx)
					undo.edit_session_end(&sess)
					if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
				}
				if is_s do im.SetItemDefaultFocus()
			}
			im.EndCombo()
		}

		col := target_rc.color
		if col.a < 0.1 do col = {1.0, 0.85, 0.20, 0.95}
		changed_col := im.ColorEdit4("Color", &col, {.NoAlpha})
		_begin_slider_undo(rig, "Change Rig Control Color")
		if changed_col {
			col.a = 0.95
			target_rc.color = col
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		_end_slider_undo()

		scale := target_rc.scale
		if scale < 0.02 do scale = 0.22
		changed_scale := im.SliderFloat("Scale", &scale, 0.04, 1.2, "%.2f")
		_begin_slider_undo(rig, "Scale Rig Control")
		if changed_scale {
			target_rc.scale = scale
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		_end_slider_undo()

		weight := target_rc.rotation_weight
		if weight < 0.01 do weight = 0.01
		changed_weight := im.SliderFloat("IK Rot Weight", &weight, 0.01, 1.0, "%.2f")
		_begin_slider_undo(rig, "Change IK Rotation Weight")
		if changed_weight {
			if weight < 0.01 do weight = 0.01
			target_rc.rotation_weight = weight
			_activate_rig_and_solver(rig)
			if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
		}
		_end_slider_undo()
		widgets.tooltip("0.01 = Natural anatomical dangle / IK flow, 1 = Full lock to control orientation")

		im.Separator()

		if im.SmallButton("Apply Shape to All") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Apply Shape to All Rig Controls")
			s := target_rc.shape
			rig.pelvis.shape = s
			rig.spine.shape = s
			rig.chest.shape = s
			rig.head.shape = s
			rig.eye_level_socket.shape = s
			rig.left_foot.shape = s
			rig.right_foot.shape = s
			rig.left_hand.shape = s
			rig.right_hand.shape = s
			undo.edit_session_end(&sess)
			if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
		}
		widgets.tooltip("Set this shape on all 9 main rig controls")

		im.SameLine(0, 4)
		if im.SmallButton("Reset to Defaults") {
			owned, _ := engine.transform_get_comp(rig.owner, crig.ControlRig)
			sess := undo.edit_session_begin({undo.edit_target_whole(owned.handle)}, "Reset Rig Control Visuals")
			rig.pelvis.shape = .Ring
			rig.pelvis.color = {0.96, 0.78, 0.28, 0.96}
			rig.pelvis.scale = 0.25

			rig.spine.shape = .Circle
			rig.spine.color = {0.96, 0.80, 0.32, 0.96}
			rig.spine.scale = 0.22

			rig.chest.shape = .Circle
			rig.chest.color = {0.98, 0.82, 0.34, 0.96}
			rig.chest.scale = 0.24

			rig.head.shape = .Sphere
			rig.head.color = {0.98, 0.88, 0.38, 0.96}
			rig.head.scale = 0.14

			rig.eye_level_socket.shape = .Sphere
			rig.eye_level_socket.color = {0.34, 0.82, 0.98, 0.96}
			rig.eye_level_socket.scale = 0.08

			rig.left_foot.shape = .Cube
			rig.left_foot.color = {0.96, 0.36, 0.38, 0.96}
			rig.left_foot.scale = 0.20

			rig.right_foot.shape = .Cube
			rig.right_foot.color = {0.26, 0.88, 0.54, 0.96}
			rig.right_foot.scale = 0.20

			rig.left_hand.shape = .Cube
			rig.left_hand.color = {0.96, 0.36, 0.38, 0.96}
			rig.left_hand.scale = 0.12

			rig.right_hand.shape = .Cube
			rig.right_hand.color = {0.26, 0.88, 0.54, 0.96}
			rig.right_hand.scale = 0.12
			undo.edit_session_end(&sess)

			if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
		}
		widgets.tooltip("Restore clean default shapes, colors, and scales for all controls")
	}
}

// =============================================================================
// COLLIDER MODE 3D TRANSFORM GIZMO (MOVES/ROTATES/SCALES ONLY COLLIDERS, NEVER BONES)
// =============================================================================

@(private = "file")
_col_gizmo_undo_sess:   undo.Edit_Session
@(private = "file")
_col_gizmo_undo_active: bool
auto_mirror_collider_gizmo: bool = false

end_collider_mode_gizmo_drag :: proc() {
	if _col_gizmo_undo_active {
		undo.edit_session_end(&_col_gizmo_undo_sess)
		_col_gizmo_undo_active = false
	}
}

draw_collider_mode_transform_gizmo :: proc(bone_h: engine.Transform_Handle, tool: handles.Tool) {
	w := engine.ctx_world()
	if w == nil || bone_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) {
		end_collider_mode_gizmo_drag()
		return
	}

	owned_cap, cap := engine.transform_get_comp(bone_h, physics3d.CapsuleCollider)
	owned_box, box := engine.transform_get_comp(bone_h, physics3d.BoxCollider)
	owned_sph, sph := engine.transform_get_comp(bone_h, physics3d.SphereCollider)
	if cap == nil && box == nil && sph == nil {
		end_collider_mode_gizmo_drag()
		return
	}

	if tool == .Picker || tool == .Handles {
		end_collider_mode_gizmo_drag()
		return
	}

	comp_h: engine.Handle = owned_cap.handle if cap != nil else (owned_box.handle if box != nil else owned_sph.handle)
	tw := engine.transform_world(bone_h)
	s  := [3]f32{max(abs(tw.scale.x), 1e-4), max(abs(tw.scale.y), 1e-4), max(abs(tw.scale.z), 1e-4)}

	pos_local: [3]f32
	rot_local := quaternion128(1)
	if cap != nil {
		pos_local = cap.center * s
		q := cap.rotation
		if q == {} || (q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w) < 1e-4 do q = {0, 0, 0, 1}
		rot_local = linalg.normalize(engine.quat_to_native(q))
	} else if box != nil {
		pos_local = box.center * s
		q := box.rotation
		if q == {} || (q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w) < 1e-4 do q = {0, 0, 0, 1}
		rot_local = linalg.normalize(engine.quat_to_native(q))
	} else if sph != nil {
		pos_local = sph.center * s
	}

	bone_mat := engine.trs_matrix(tw.position, tw.rotation, {1, 1, 1})
	world_c  := (bone_mat * [4]f32{pos_local.x, pos_local.y, pos_local.z, 1}).xyz

	v := handles.frame().view
	dist: f32
	if abs(v.proj[3, 3]) > 0.5 && abs(v.proj[1, 1]) > 1e-6 {
		half_h := 1.0 / abs(v.proj[1, 1])
		dist = half_h / math.tan(math.to_radians(f32(45.0)) * 0.5)
	} else {
		cam_fwd := [3]f32{-v.view[2, 0], -v.view[2, 1], -v.view[2, 2]}
		cam_depth := linalg.dot(world_c - v.cam_pos, cam_fwd)
		if cam_depth <= 0.01 && !_col_gizmo_undo_active {
			end_collider_mode_gizmo_drag()
			return
		}
		if abs(v.proj[1, 1]) > 1e-6 {
			half_h := max(cam_depth, 0.01) / abs(v.proj[1, 1])
			dist = half_h / math.tan(math.to_radians(f32(45.0)) * 0.5)
		} else {
			dist = max(cam_depth, 0.01)
		}
	}
	size := clamp(dist * 0.16, 0.002, 0.85)
	local_space := handles.is_local_space()

	gizmos.in_local_space(bone_h, use_scale = false)

	d: handles.Drag
	#partial switch tool {
	case .Translate:
		bone_rot_inv := linalg.quaternion_inverse(linalg.normalize(engine.quat_to_native(tw.rotation)))
		handle_rot   := rot_local if local_space else bone_rot_inv
		d = handles.position_handle(handles.id_of(bone_h, 0xC011_0001), &pos_local, handle_rot, size, prio = handles.PRIO_TOOL)
		if d.dragging || d.released {
			new_c := pos_local / s
			if cap != nil      do cap.center = new_c
			else if box != nil do box.center = new_c
			else if sph != nil do sph.center = new_c
		}

	case .Rotate:
		d = handles.rotation_handle(handles.id_of(bone_h, 0xC011_0002), &rot_local, pos_local, size, local = local_space, prio = handles.PRIO_TOOL)
		if d.dragging || d.released {
			new_q := engine.quat_from_native(linalg.normalize(rot_local))
			if cap != nil      do cap.rotation = new_q
			else if box != nil do box.rotation = new_q
		}

	case .Scale:
		if box != nil {
			cur_sz := box.size
			d = handles.scale_handle(handles.id_of(bone_h, 0xC011_0003), &cur_sz, pos_local, rot_local, size, prio = handles.PRIO_TOOL)
			if d.dragging || d.released {
				box.size = {max(cur_sz.x, 0.005), max(cur_sz.y, 0.005), max(cur_sz.z, 0.005)}
			}
		} else if cap != nil {
			old_r := cap.radius
			old_h := cap.height
			cap_dims: [3]f32
			switch cap.direction {
			case .X_Axis: cap_dims = {old_h, old_r, old_r}
			case .Y_Axis: cap_dims = {old_r, old_h, old_r}
			case .Z_Axis: cap_dims = {old_r, old_r, old_h}
			}
			d = handles.scale_handle(handles.id_of(bone_h, 0xC011_0003), &cap_dims, pos_local, rot_local, size, prio = handles.PRIO_TOOL)
			if d.dragging || d.released {
				new_r := old_r
				new_h := old_h
				switch cap.direction {
				case .X_Axis:
					new_h = cap_dims.x
					new_r = abs(cap_dims.y - old_r) >= abs(cap_dims.z - old_r) ? cap_dims.y : cap_dims.z
				case .Y_Axis:
					new_h = cap_dims.y
					new_r = abs(cap_dims.x - old_r) >= abs(cap_dims.z - old_r) ? cap_dims.x : cap_dims.z
				case .Z_Axis:
					new_h = cap_dims.z
					new_r = abs(cap_dims.x - old_r) >= abs(cap_dims.y - old_r) ? cap_dims.x : cap_dims.y
				}
				cap.radius = max(new_r, 0.005)
				cap.height = max(new_h, cap.radius * 2.0)
			}
		} else if sph != nil {
			old_r := sph.radius
			sph_dims := [3]f32{old_r, old_r, old_r}
			d = handles.scale_handle(handles.id_of(bone_h, 0xC011_0003), &sph_dims, pos_local, rot_local, size, prio = handles.PRIO_TOOL)
			if d.dragging || d.released {
				new_r := old_r
				if abs(sph_dims.x - old_r) >= abs(sph_dims.y - old_r) && abs(sph_dims.x - old_r) >= abs(sph_dims.z - old_r) {
					new_r = sph_dims.x
				} else if abs(sph_dims.y - old_r) >= abs(sph_dims.z - old_r) {
					new_r = sph_dims.y
				} else {
					new_r = sph_dims.z
				}
				sph.radius = max(new_r, 0.005)
			}
		}
	}

	if d.started {
		end_collider_mode_gizmo_drag()
		if comp_h != {} {
			_col_gizmo_undo_sess   = undo.edit_session_begin({undo.edit_target_whole(comp_h)}, "Transform Bone Collider")
			_col_gizmo_undo_active = true
		}
	}
	if d.dragging || d.released {
		if auto_mirror_collider_gizmo {
			owner_h := get_active_character_owner()
			if owner_h != {} {
				if _, adm := engine.transform_get_comp(owner_h, crig.ArmatureDeformedMesh); adm != nil {
					_mirror_bone_collider(bone_h, adm)
				}
			}
		}
		if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true
	}
	if d.released {
		end_collider_mode_gizmo_drag()
	}
}


