package control_rig_editor

import "core:fmt"
import "core:strings"
import im "haati:external/odin-imgui"
import wnd "haati:editor/window"
import "haati:editor/widgets"
import engine "haati:engine"
import physics3d "haati:packages/physics3d"
import crig "haati:packages/control_rig"

// =============================================================================
// CHARACTER COMPONENT POINTER RESOLVER
// =============================================================================
// Resolves pointers to the active character's ControlRig, ProceduralLocomotion,
// HumanoidIkSolver, and ArmatureDeformedMesh without copying component structs.
@(private = "file")
_resolve_active_character :: proc() -> (
	owner:  engine.Transform_Handle,
	adm:    ^crig.ArmatureDeformedMesh,
	rig:    ^crig.ControlRig,
	loco:   ^crig.ProceduralLocomotion,
	solver: ^crig.HumanoidIkSolver,
) {
	w := engine.ctx_world()
	if w == nil do return

	active_h := engine.inspector_active_selection()
	if active_h != {} {
		_, a := engine.transform_get_comp(active_h, crig.ArmatureDeformedMesh)
		_, r := engine.transform_get_comp(active_h, crig.ControlRig)
		if a != nil || r != nil {
			owner = active_h
		} else {
			it := engine.pool_iterator(crig.armature_deformed_meshes(w))
			for candidate, _ in engine.pool_next(&it) {
				for j in candidate.joints {
					if j == active_h {
						owner = engine.Transform_Handle(candidate.owner)
						break
					}
				}
				if owner != {} do break
			}
		}
	}

	if owner == {} {
		it_rig := engine.pool_iterator(crig.control_rigs(w))
		for candidate, _ in engine.pool_next(&it_rig) {
			cand_owner := engine.Transform_Handle(candidate.owner)
			if candidate.enabled && engine.transform_active_in_hierarchy(cand_owner) {
				owner = cand_owner
				break
			}
		}
	}
	if owner == {} {
		it_adm := engine.pool_iterator(crig.armature_deformed_meshes(w))
		for candidate, _ in engine.pool_next(&it_adm) {
			cand_owner := engine.Transform_Handle(candidate.owner)
			if candidate.enabled && engine.transform_active_in_hierarchy(cand_owner) {
				owner = cand_owner
				break
			}
		}
	}

	if owner != {} {
		_, adm    = engine.transform_get_comp(owner, crig.ArmatureDeformedMesh)
		_, rig    = engine.transform_get_comp(owner, crig.ControlRig)
		_, loco   = engine.transform_get_comp(owner, crig.ProceduralLocomotion)
		_, solver = engine.transform_get_comp(owner, crig.HumanoidIkSolver)
	}
	return
}

// Deprecated standalone Control Rig window removed in favor of the unified
// Faker Body Harmonics & VM State Graph editor (faker_state_machine_editor.odin).
control_rig_window_draw :: proc() {
	if crig.smart_rig_async_state.active {
		crig.smart_rig_async_tick(0.016)
	}
	owner, target_adm, rig, loco, solver := _resolve_active_character()

	im.TextColored({0.3, 0.8, 1.0, 1.0}, "Procedural Animation & Control Rig Workspace")
	im.TextDisabled("Live pointer-bound controls for the active scene character: Locomotion, IK Solver, Dynamics, and Smart Colliders.")
	im.Spacing()

	if im.BeginTabBar("##ControlRigTabs", {}) {
		defer im.EndTabBar()

		// -------------------------------------------------------------
		// TAB 1: LOCOMOTION & GAIT (Bound directly to ^ProceduralLocomotion)
		// -------------------------------------------------------------
		if im.BeginTabItem("Locomotion", nil, {}) {
			defer im.EndTabItem()

			im.Spacing()
			if loco == nil {
				im.TextDisabled("No ProceduralLocomotion component on the active character.")
				if owner != {} && im.Button("+ Add ProceduralLocomotion Component") {
					engine.transform_add_comp(owner, .ProceduralLocomotion)
				}
			} else {
				im.Checkbox("Enable Procedural Locomotion", &loco.active)
				im.SameLine(0, 20)
				im.Checkbox("Drive ControlRig Controls", &loco.drive_skeleton)
				im.Separator()
				im.Columns(2, "gait_cols", false)
				im.SetColumnWidth(0, 370)

				mode_idx := i32(loco.mode)
				if im.Combo("Gait Mode", &mode_idx, "Idle (Breathing)\x00Walk Cycle\x00Custom Preset\x00") {
					loco.mode = crig.Gait_Mode(mode_idx)
				}
				im.SliderFloat("Move Speed", &loco.speed, 0.2, 6.0, "%.2f m/s")
				im.SliderFloat("Step Frequency", &loco.config.gait_frequency, 0.5, 5.0, "%.1f Hz")
				im.SliderFloat("Stride Length", &loco.config.stride_length, 0.1, 1.0, "%.2f m")
				im.SliderFloat("Step Height", &loco.config.step_height, 0.02, 0.35, "%.2f m")

				im.NextColumn()
				im.TextColored({1.0, 0.85, 0.4, 1.0}, "Pelvis & Body Harmonics:")
				im.SliderFloat("Pelvis Bounce", &loco.config.pelvis_bounce, 0.0, 0.10, "%.3f m")
				im.SliderFloat("Pelvis Sway", &loco.config.pelvis_sway, 0.0, 0.10, "%.3f m")
				im.SliderFloat("Arm Counter-Swing", &loco.config.arm_swing_amount, 0.0, 0.8, "%.2fx")
				im.SliderFloat("Breath Speed", &loco.config.breath_speed, 0.2, 4.0, "%.1fx")
				im.SliderFloat("Breath Amount", &loco.config.breath_amount, 0.002, 0.05, "%.3f m")
				im.Columns(1)
			}
		}

		// -------------------------------------------------------------
		// TAB 2: HUMANOID IK SOLVER & DYNAMICS (Bound to ^HumanoidIkSolver & ^ControlRig)
		// -------------------------------------------------------------
		if im.BeginTabItem("IK & Dynamics", nil, {}) {
			defer im.EndTabItem()

			im.Spacing()
			if rig == nil {
				im.TextDisabled("No ControlRig component on the active character.")
				if owner != {} && im.Button("+ Add ControlRig Component") {
					engine.transform_add_comp(owner, .ControlRig)
				}
			} else {
				im.Checkbox("Enable ControlRig", &rig.active)
				if solver != nil {
					im.SameLine(0, 20)
					im.Checkbox("Enable Humanoid IK Solver", &solver.active)
				} else if im.Button("+ Add HumanoidIkSolver Component") {
					engine.transform_add_comp(owner, .HumanoidIkSolver)
				}

				im.Separator()
				im.Columns(2, "ik_cols", false)
				im.SetColumnWidth(0, 370)
				im.TextColored({0.3, 0.9, 0.5, 1.0}, "Control Rig Rotation Weights & Solver Tuning:")
				im.SliderFloat("Pelvis Rot Weight", &rig.pelvis.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Spine Rot Weight", &rig.spine.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Chest Rot Weight", &rig.chest.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Head Rot Weight", &rig.head.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Left Foot Rot Weight", &rig.left_foot.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Right Foot Rot Weight", &rig.right_foot.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Left Hand Rot Weight", &rig.left_hand.rotation_weight, 0.01, 1.0, "%.2f")
				im.SliderFloat("Right Hand Rot Weight", &rig.right_hand.rotation_weight, 0.01, 1.0, "%.2f")
				if solver != nil {
					im.SliderFloat("Look-At Max Angle", &solver.look_at_max_angle, 10.0, 120.0, "%.1f deg")
					im.SliderFloat("Forearm Twist Ratio", &solver.wrist_twist_ratio, 0.0, 1.0, "%.2f")
				}

				im.NextColumn()
				im.TextColored({1.0, 0.4, 0.4, 1.0}, "Body Harmonics & Impulse Injector:")
				if loco != nil {
					im.Checkbox("Enable Dynamics", &loco.enable_dynamics)
					im.SliderFloat("Fatigue", &loco.fatigue, 0.0, 1.0, "%.2f")
					im.SliderFloat("Spring Stiffness", &loco.stiffness, 30.0, 400.0, "%.0f")
					im.SliderFloat("Spring Damping", &loco.damping, 5.0, 50.0, "%.1f")
					im.SliderFloat("Dynamic Lean", &loco.body_lean_strength, 0.0, 3.0, "%.2fx")
				}

				if im.Button("Test Recoil Shot") {
					crig.control_rig_add_body_impulse(rig, [3]f32{0, 2.0, -18.0})
				}
				im.SameLine()
				if im.Button("Reset Controls to Rest Pose") {
					crig.control_rig_sync_from_skeleton(rig)
				}
				im.Columns(1)
			}
		}

		// -------------------------------------------------------------
		// TAB 3: SMART COLLIDER PLACER & BONE COLLIDER MANAGER
		// -------------------------------------------------------------
		if im.BeginTabItem("Smart Colliders", nil, {}) {
			defer im.EndTabItem()

			im.Spacing()
			im.TextColored({0.3, 0.85, 1.0, 1.0}, "Smart Ragdoll & Hitbox Collider Placer (Unreal PhAT Style)")
			im.TextDisabled("Derives bone segment lengths and automatically attaches fitted CapsuleColliders, BoxColliders, and SphereColliders.")
			im.Spacing()

			w := engine.ctx_world()
			if w != nil {
				target_owner := owner
				if target_adm != nil {
					ot := engine.pool_get(&w.transforms, engine.Handle(target_owner))
					actor_name := ot != nil ? ot.name : "Character Actor"

					// Status header
					im.TextColoredUnformatted({1.0, 0.85, 0.2, 1.0}, fmt.ctprintf("Target Character: %s", actor_name))

					im.Spacing()
					// Row 1: Bind Pose Reset & Rebind
					if im.Button("Reset Skeleton to Bind Pose (T-Pose)") {
						crig.armature_deformed_mesh_reset_bind_pose(target_adm)
					}
					widgets.tooltip("Restores authentic glTF rest transforms for all bones and syncs rig controls to rest pose.")
					im.SameLine()
					if im.Button("Rebind Skeleton") {
						crig.armature_deformed_mesh_rebind(target_adm)
					}

					im.Spacing()
					im.Checkbox("Use Bone Heatmap Bounds", &crig.smart_rig_async_state.use_heatmap_bounds)
					widgets.tooltip("Uses each bone's vertex skin weight heatmap (w >= 0.25) to determine where its collider starts, ends, and centers in volume before ray-tracing.")
					im.SameLine(0, 20)
					im.Checkbox("Character Has Breasts", &crig.smart_rig_async_state.has_breasts)
					widgets.tooltip("When checked: flattens the main chest collider baseline to the ribcage (so it doesn't oversize over breasts) and automatically traces/fits breast_l & breast_r SphereColliders.")
					im.SameLine(0, 20)
					mp_cnt := i32(crig.smart_rig_async_state.multipass_count)
					im.SetNextItemWidth(120)
					if im.SliderInt("Ray-Trace Passes", &mp_cnt, 1, 4) {
						crig.smart_rig_async_state.multipass_count = int(mp_cnt)
					}

					// Row 2: Ray-Traced Ragdoll Generation, Breast Hill Auto-Rig & Removal
					if im.Button("Auto-Fit All Colliders (Async Ray-Trace)") {
						crig.smart_rig_async_start(target_owner, fit_colliders = true, rig_breasts = crig.smart_rig_async_state.has_breasts)
					}
					widgets.tooltip("Multi-pass ray-traced fitting: traces spinal chain, wrist-to-finger hand OBBs, and floor-planted foot boxes (plus flattened ribcage & breast SphereColliders if 'Character Has Breasts' is checked).")
					if crig.smart_rig_async_state.has_breasts {
						im.SameLine()
						if im.Button("Auto-Rig & Weight Breasts Only (Hill Trace)") {
							crig.smart_rig_async_start(target_owner, fit_colliders = false, rig_breasts = true)
						}
						widgets.tooltip("Cuts a virtual flat chest baseline via 2D front-to-back line traces, finds bilateral breast hills & gravity sag vectors, spawns breast_l/breast_r + SpringBone + SphereColliders, and runs recursive weight smoothing.")
					}
					im.SameLine()
					if im.Button("Remove All Colliders") {
						crig.smart_collider_remove_humanoid(target_owner)
					}

					if crig.smart_rig_async_state.active {
						im.ProgressBar(crig.smart_rig_async_state.progress, {-1, 0}, strings.clone_to_cstring(crig.smart_rig_async_state.status_text, context.temp_allocator))
					} else if len(crig.smart_rig_async_state.last_summary) > 0 {
						im.TextColored({0.35, 0.92, 0.55, 1.0}, "%s", strings.clone_to_cstring(crig.smart_rig_async_state.last_summary, context.temp_allocator))
					}

					im.Spacing()
					im.Separator()
					im.TextColored({0.4, 0.9, 1.0, 1.0}, "Humanoid Bone Colliders & Live Adjustments:")
					im.TextDisabled("Click any bone collider below or in the 3D viewport to adjust its dimensions live:")

					local_bones: crig.Humanoid_Bones
					bones: ^crig.Humanoid_Bones = nil
					if rig != nil {
						bones = crig.control_rig_ensure_bones(rig)
					} else {
						crig.skeleton_bind_humanoid(&local_bones, target_owner)
						bones = &local_bones
					}

					Humanoid_Slot :: struct {
						label:  string,
						handle: engine.Transform_Handle,
					}
					torso_bone := bones.chest != {} ? bones.chest : bones.spine
					breast_l_h, _ := crig.skeleton_find_bone_by_name(target_owner, "breast_l")
					breast_r_h, _ := crig.skeleton_find_bone_by_name(target_owner, "breast_r")
					slots := [17]Humanoid_Slot{
						{"Head", bones.head},
						{"Pelvis / Hips", bones.pelvis},
						{"Torso / Chest", torso_bone},
						{"Left Breast", breast_l_h},
						{"Right Breast", breast_r_h},
						{"Left Upper Arm", bones.left_upperarm},
						{"Left Lower Arm", bones.left_lowerarm},
						{"Left Hand", bones.left_hand},
						{"Right Upper Arm", bones.right_upperarm},
						{"Right Lower Arm", bones.right_lowerarm},
						{"Right Hand", bones.right_hand},
						{"Left Thigh", bones.left_thigh},
						{"Left Calf", bones.left_calf},
						{"Left Foot", bones.left_foot},
						{"Right Thigh", bones.right_thigh},
						{"Right Calf", bones.right_calf},
						{"Right Foot", bones.right_foot},
					}

					for slot, slot_idx in slots {
						if slot.handle == {} {
							if (slot_idx == 3 || slot_idx == 4) && !crig.smart_rig_async_state.has_breasts {
								continue
							}
							im.TextDisabledUnformatted(fmt.ctprintf("  - %s: (Not found in skeleton)", slot.label))
							continue
						}

						bt := engine.pool_get(&w.transforms, engine.Handle(slot.handle))
						bname := bt != nil ? bt.name : slot.label

						_, cap := engine.transform_get_comp(slot.handle, physics3d.CapsuleCollider)
						_, box := engine.transform_get_comp(slot.handle, physics3d.BoxCollider)
						_, sph := engine.transform_get_comp(slot.handle, physics3d.SphereCollider)

						tree_label: string
						if cap != nil {
							tree_label = fmt.tprintf("[Capsule] %s (%s)###slot_%d", slot.label, bname, slot_idx)
						} else if box != nil {
							tree_label = fmt.tprintf("[Box] %s (%s)###slot_%d", slot.label, bname, slot_idx)
						} else if sph != nil {
							tree_label = fmt.tprintf("[Sphere] %s (%s)###slot_%d", slot.label, bname, slot_idx)
						} else {
							tree_label = fmt.tprintf("[None] %s (%s)###slot_%d", slot.label, bname, slot_idx)
						}

						if im.TreeNode(strings.clone_to_cstring(tree_label, context.temp_allocator)) {
							if cap != nil {
								changed := false
								if im.DragFloat(fmt.ctprintf("Radius##cap_%d", slot_idx), &cap.radius, 0.002, 0.01, 1.0, "%.3f m") do changed = true
								if im.DragFloat(fmt.ctprintf("Height##cap_%d", slot_idx), &cap.height, 0.005, 0.02, 3.0, "%.3f m") do changed = true
								if im.DragFloat3(fmt.ctprintf("Center##cap_%d", slot_idx), &cap.center, 0.005) do changed = true

								dir_idx := i32(cap.direction)
								if im.Combo(fmt.ctprintf("Direction##cap_%d", slot_idx), &dir_idx, "X Axis\x00Y Axis\x00Z Axis\x00") {
									cap.direction = physics3d.Capsule_Direction(dir_idx)
									changed = true
								}
								if changed {
									if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
								}

								if im.Button(fmt.ctprintf("Select Bone in Viewport##cap_%d", slot_idx)) {
									engine.inspector_request_select(slot.handle)
								}
								im.SameLine()
								if im.Button(fmt.ctprintf("Delete Collider##cap_%d", slot_idx)) {
									crig.smart_collider_remove_from_bone(slot.handle)
								}
							} else if box != nil {
								changed := false
								if im.DragFloat3(fmt.ctprintf("Size##box_%d", slot_idx), &box.size, 0.005) do changed = true
								if im.DragFloat3(fmt.ctprintf("Center##box_%d", slot_idx), &box.center, 0.005) do changed = true
								if changed {
									if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
								}

								if im.Button(fmt.ctprintf("Select Bone in Viewport##box_%d", slot_idx)) {
									engine.inspector_request_select(slot.handle)
								}
								im.SameLine()
								if im.Button(fmt.ctprintf("Delete Collider##box_%d", slot_idx)) {
									crig.smart_collider_remove_from_bone(slot.handle)
								}
							} else if sph != nil {
								changed := false
								if im.DragFloat(fmt.ctprintf("Radius##sph_%d", slot_idx), &sph.radius, 0.002, 0.01, 1.0, "%.3f m") do changed = true
								if im.DragFloat3(fmt.ctprintf("Center##sph_%d", slot_idx), &sph.center, 0.005) do changed = true
								if changed {
									if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
								}

								if im.Button(fmt.ctprintf("Select Bone in Viewport##sph_%d", slot_idx)) {
									engine.inspector_request_select(slot.handle)
								}
								im.SameLine()
								if im.Button(fmt.ctprintf("Delete Collider##sph_%d", slot_idx)) {
									crig.smart_collider_remove_from_bone(slot.handle)
								}
							} else {
								im.TextDisabled("No collider attached to this bone.")
								if im.Button(fmt.ctprintf("+ Add Capsule##none_%d", slot_idx)) {
									crig.smart_collider_add_capsule(slot.handle)
								}
								im.SameLine()
								if im.Button(fmt.ctprintf("+ Add Box##none_%d", slot_idx)) {
									crig.smart_collider_add_box(slot.handle)
								}
								im.SameLine()
								if im.Button(fmt.ctprintf("+ Add Sphere##none_%d", slot_idx)) {
									crig.smart_collider_add_sphere(slot.handle)
								}
								im.SameLine()
								if im.Button(fmt.ctprintf("Select Bone##none_%d", slot_idx)) {
									engine.inspector_request_select(slot.handle)
								}
							}
							im.TreePop()
						}
					}

					// Custom Bone Section: Add collider to any joint in target_adm
					if len(target_adm.joints) > 0 {
						im.Spacing()
						im.Separator()
						im.TextColored({0.4, 0.9, 1.0, 1.0}, "Add Collider to Any Skeleton Bone:")
						@(static) custom_bone_idx: i32 = 0
						if custom_bone_idx >= i32(len(target_adm.joints)) do custom_bone_idx = 0

						selected_j := target_adm.joints[custom_bone_idx]
						jt := engine.pool_get(&w.transforms, engine.Handle(selected_j))
						cur_name := jt != nil ? jt.name : "(Unknown)"

						if im.BeginCombo("Bone Joint", strings.clone_to_cstring(cur_name, context.temp_allocator)) {
							for j, ji in target_adm.joints {
								if j == {} || !engine.pool_valid(&w.transforms, engine.Handle(j)) do continue
								t := engine.pool_get(&w.transforms, engine.Handle(j))
								name := t != nil && t.name != "" ? t.name : fmt.tprintf("Bone_%d", ji)
								is_selected := (i32(ji) == custom_bone_idx)
								if im.Selectable(fmt.ctprintf("%s##bone_%d", name, ji), is_selected) {
									custom_bone_idx = i32(ji)
								}
								if is_selected do im.SetItemDefaultFocus()
							}
							im.EndCombo()
						}

						if selected_j != {} {
							if im.Button("+ Add Capsule Collider") {
								crig.smart_collider_add_capsule(selected_j)
							}
							im.SameLine()
							if im.Button("+ Add Box Collider") {
								crig.smart_collider_add_box(selected_j)
							}
							im.SameLine()
							if im.Button("+ Add Sphere Collider") {
								crig.smart_collider_add_sphere(selected_j)
							}
							im.SameLine()
							if im.Button("Select Bone") {
								engine.inspector_request_select(selected_j)
							}
						}
					}
				} else {
					im.TextDisabled("Select a character actor or armature bone in the Hierarchy or Viewport to view colliders.")
				}
			}
		}
	}
}

control_rig_window_open :: proc() {
	wnd.open("faker_state_machine")
}
