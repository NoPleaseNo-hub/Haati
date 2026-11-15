package control_rig

// =============================================================================
// HAND POSE DRIVER & DYNAMIC HAND BOX COLLIDER SOLVER
// =============================================================================
// Data-oriented, auto-calibrated hand & finger rig solver.
//
// Key Architectural Improvements over the Godot C# Prototype:
// 1. Auto-Calibrated Anatomical Axes (Zero Hardcoded Bone Roll Assumptions):
//    At bind time, computes the true 3D palm basis (Distal Finger Dir, Radial Knuckle
//    Row Dir, and Palmar Inward Normal) directly from the bind-pose joint positions,
//    then projects the exact Curl, Splay, Abduction, and Axial Roll axes into each
//    phalanx's local rest space. Left and Right hands are 100% symmetrical regardless
//    of how Blender/glTF rolled the bones.
// 2. Vector4 Finger Controls + One-Way Master Macro Drivers:
//    Each of the 4 fingers (Index, Middle, Ring, Pinky) is a [4]f32:
//      .x = Base (MCP) Curl, .y = Mid (PIP) Curl, .z = Tip (DIP) Curl, .w = Lateral Splay.
//    Master Curl / Claw / Spread write directly into the 4 finger vectors so you can
//    dial a master fist and immediately open individual fingers (Point, Trigger, etc.).
// 3. Aligned Anatomical Thumb (2D Pad + Sweep + Roll + 1-DOF Hinges):
//    All 3 thumb segments (thumb_01, thumb_02, thumb_03) share the same calibrated
//    trans-palmar flexion plane so curling thumb_02 and thumb_03 never corkscrews.
// 4. Dynamic Morphing Hand BoxCollider:
//    Each Hand_Pose_Profile carries a fitted BoxCollider (size + center), and the
//    driver can both blend the collider smoothly between poses AND mathematically
//    fit the BoxCollider to the live posed finger joints every frame.

import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import cgltf "vendor:cgltf"
import engine "haati:engine"
import physics3d "haati:packages/physics3d"

Hand_Pose_Preset :: enum i32 {
	Relaxed        = 0,
	Fist           = 1,
	Open_Palm      = 2,
	Point_Trigger  = 3,
	Pistol_Grip    = 4,
	Rifle_Grip     = 5,
	Claw_Grip      = 6,
	Lightning_Cast = 7,
	Custom         = 8,
}

Hand_Collider_Mode :: enum i32 {
	Pose_And_Auto     = 0, // Blends per-pose custom box and adapts to live finger curl/spread
	Auto_From_Fingers = 1, // Pure mathematical OBB fit around wrist + all 15 posed finger joints
	Custom_Pose_Box   = 2, // Uses the exact per-pose custom collider_size and collider_center
	Disabled          = 3, // Does not modify the hand's BoxCollider
}

// Universal Hand Pose Profile: works identically on Left and Right hands.
Hand_Pose_Profile :: struct {
	name:            string `json:"-" inspect:"-"`,

	// Thumb Controls (2D Abduction/Elevation + Sweep + Axial Roll + 2 Hinges)
	thumb_pos_2d:    [2]f32, // .x = Abduct/Spread (-1..1), .y = Distal/Up along palm (-1..1)
	thumb_sweep:     f32,    // 0 = neutral at side, 1 = swept across palm toward pinky
	thumb_roll:      f32,    // 0 = neutral, 1 = rolled into opposition facing fingers
	thumb_mid_curl:  f32,    // thumb_02 MCP hinge (0 = straight, 1 = 75 deg curl)
	thumb_tip_curl:  f32,    // thumb_03 IP hinge  (0 = straight, 1 = 90 deg curl)

	// 4 Fingers ([4]f32: .x = Base MCP, .y = Mid PIP, .z = Tip DIP, .w = Lateral Splay)
	index_finger:    [4]f32,
	middle_finger:   [4]f32,
	ring_finger:     [4]f32,
	pinky_finger:    [4]f32,

	// Per-Pose Hand BoxCollider Shape (in Canonical Left-Hand Local Coordinates:
	//   .x = Palmar/Dorsal Thickness, .y = Distal Length along fingers, .z = Radial/Ulnar Width)
	collider_size:   [3]f32,
	collider_center: [3]f32,
}

// Per-Hand Runtime & Authoring State
Hand_Side_State :: struct {
	preset:         Hand_Pose_Preset,
	master_curl:    f32,
	master_claw:    f32,
	master_spread:  f32,
	pose:           Hand_Pose_Profile,

	// Runtime smooth transition state
	blend_start:    Hand_Pose_Profile `json:"-" inspect:"-"`,
	blend_target:   Hand_Pose_Profile `json:"-" inspect:"-"`,
	blend_time:     f32 `json:"-" inspect:"-"`,
	blend_duration: f32 `json:"-" inspect:"-"`,
	is_blending:    bool `json:"-" inspect:"-"`,
}

// Auto-Calibrated Anatomical Finger Bone Cache for one hand (15 phalanges + 5 leaf tips)
Hand_Calibrated_Bones :: struct {
	hand_bone:        engine.Transform_Handle,
	// [5 digits: 0=Thumb, 1=Index, 2=Middle, 3=Ring, 4=Pinky][3 phalanges: 0=Proximal, 1=Intermediate, 2=Distal]
	phalanges:        [5][3]engine.Transform_Handle,
	leaf_tips:        [5]engine.Transform_Handle,

	rest_local_pos:   [5][3][3]f32,
	rest_local_rot:   [5][3][4]f32,
	segment_length:   [5][3]f32,

	// Calibrated unit rotation axes in each phalanx's own local rest frame:
	// - curl_axis_local: positive angle curls phalanx into the palm (or across palm for thumb)
	// - splay_axis_local: positive angle fans finger toward ulnar/pinky side (or abducts thumb outward)
	// - thumb_up_axis_local: positive angle elevates thumb distally toward fingers
	// - thumb_roll_axis_local: positive angle rolls thumb into opposition around its own bone length
	curl_axis_local:       [5][3][3]f32,
	splay_axis_local:      [5][3]f32,
	thumb_up_axis_local:   [3]f32,
	thumb_roll_axis_local: [3]f32,

	// Calibrated canonical hand-space basis (in hand_bone's local space):
	// Used to transform canonical collider_center & collider_size and fit live finger AABBs.
	palm_inward_local: [3]f32, // Unit vector pointing out of the palm (anterior)
	distal_local:      [3]f32, // Unit vector pointing from wrist to middle knuckle
	radial_local:      [3]f32, // Unit vector pointing from pinky knuckle to index/thumb knuckle

	bound:             bool,
}

@(component={menu="Animation/HandPoseDriver"})
@(typ_guid={guid = "c48e912a-7b3d-4f16-9a52-1d8e6f0b3c74"})
HandPoseDriver :: struct {
	using base:        engine.CompData `inspect:"-"`,
	active:            bool,
	weight:            f32,
	mirror_hands:      bool,
	collider_mode:     Hand_Collider_Mode,

	left:              Hand_Side_State,
	right:             Hand_Side_State,

	// Runtime calibrated bone caches (never serialized to scene JSON)
	left_calib:        Hand_Calibrated_Bones `json:"-" inspect:"-"`,
	right_calib:       Hand_Calibrated_Bones `json:"-" inspect:"-"`,
}

// =============================================================================
// FOLDER-BACKED POSE PRESET LIBRARY (Seeded from Godot Assets/HandPoses)
// =============================================================================

hand_pose_preset_filename :: proc(preset: Hand_Pose_Preset) -> string {
	switch preset {
	case .Relaxed:        return "Relaxed.mhpose"
	case .Fist:           return "Fist.mhpose"
	case .Open_Palm:      return "Open_Palm.mhpose"
	case .Point_Trigger:  return "Point_Trigger.mhpose"
	case .Pistol_Grip:    return "Pistol_Grip.mhpose"
	case .Rifle_Grip:     return "Rifle_Grip.mhpose"
	case .Claw_Grip:      return "Claw_Grip.mhpose"
	case .Lightning_Cast: return "Lightning_Cast.mhpose"
	case .Custom:         return ""
	}
	return ""
}

// Loads the pose from plugins/control_rig/assets/hand_poses/<Name>.mhpose if it exists on disk,
// falling back to the built-in calibrated defaults otherwise.
hand_pose_preset_get :: proc(preset: Hand_Pose_Preset, dir_path: string = HAND_POSES_DIR) -> Hand_Pose_Profile {
	fname := hand_pose_preset_filename(preset)
	if len(fname) > 0 && len(dir_path) > 0 {
		full_path := fmt.tprintf("%s/%s", dir_path, fname)
		if prof, ok := hand_pose_profile_load_from_disk(full_path); ok {
			prof.name = hand_pose_builtin_fallback_get(preset).name
			return prof
		}
	}
	return hand_pose_builtin_fallback_get(preset)
}

hand_pose_builtin_fallback_get :: proc(preset: Hand_Pose_Preset) -> Hand_Pose_Profile {
	switch preset {
	case .Relaxed:
		return Hand_Pose_Profile{
			name            = "Relaxed",
			thumb_pos_2d    = {0.20, 0.15},
			thumb_sweep     = 0.20,
			thumb_roll      = 0.15,
			thumb_mid_curl  = 0.20,
			thumb_tip_curl  = 0.20,
			index_finger    = {0.20, 0.22, 0.20, -0.08},
			middle_finger   = {0.26, 0.28, 0.25, -0.01},
			ring_finger     = {0.32, 0.34, 0.30,  0.04},
			pinky_finger    = {0.38, 0.40, 0.35,  0.10},
			collider_size   = {0.052, 0.175, 0.105},
			collider_center = {0.012, 0.088, 0.004},
		}

	case .Fist:
		return Hand_Pose_Profile{
			name            = "Fist",
			thumb_pos_2d    = {-0.10, 0.35},
			thumb_sweep     = 0.65,
			thumb_roll      = 0.55,
			thumb_mid_curl  = 0.65,
			thumb_tip_curl  = 0.85,
			index_finger    = {1.00, 1.00, 0.95, 0.00},
			middle_finger   = {1.00, 1.00, 0.95, 0.00},
			ring_finger     = {1.00, 1.00, 0.95, 0.00},
			pinky_finger    = {1.00, 1.00, 0.95, 0.00},
			collider_size   = {0.078, 0.118, 0.096},
			collider_center = {0.024, 0.062, 0.000},
		}

	case .Open_Palm:
		return Hand_Pose_Profile{
			name            = "Open Palm",
			thumb_pos_2d    = {0.60, 0.05},
			thumb_sweep     = 0.00,
			thumb_roll      = 0.00,
			thumb_mid_curl  = 0.00,
			thumb_tip_curl  = 0.00,
			index_finger    = {0.00, 0.00, 0.00, -0.25},
			middle_finger   = {0.00, 0.00, 0.00, -0.04},
			ring_finger     = {0.00, 0.00, 0.00,  0.12},
			pinky_finger    = {0.00, 0.00, 0.00,  0.30},
			collider_size   = {0.038, 0.195, 0.145},
			collider_center = {0.002, 0.098, 0.008},
		}

	case .Point_Trigger:
		return Hand_Pose_Profile{
			name            = "Point / Trigger",
			thumb_pos_2d    = {0.05, 0.25},
			thumb_sweep     = 0.45,
			thumb_roll      = 0.40,
			thumb_mid_curl  = 0.50,
			thumb_tip_curl  = 0.65,
			index_finger    = {0.00, 0.02, 0.02,  0.00},
			middle_finger   = {0.95, 0.98, 0.92,  0.00},
			ring_finger     = {0.98, 1.00, 0.95,  0.00},
			pinky_finger    = {1.00, 1.00, 0.95,  0.00},
			collider_size   = {0.065, 0.190, 0.096},
			collider_center = {0.016, 0.094, 0.004},
		}

	case .Pistol_Grip:
		return Hand_Pose_Profile{
			name            = "Pistol Grip",
			thumb_pos_2d    = {0.20, 0.10},
			thumb_sweep     = 0.30,
			thumb_roll      = 0.30,
			thumb_mid_curl  = 0.40,
			thumb_tip_curl  = 0.40,
			index_finger    = {0.05, 0.35, 0.30, -0.05},
			middle_finger   = {0.90, 0.90, 0.90,  0.00},
			ring_finger     = {0.90, 0.90, 0.90,  0.00},
			pinky_finger    = {0.90, 0.90, 0.90,  0.00},
			collider_size   = {0.072, 0.155, 0.096},
			collider_center = {0.022, 0.078, 0.002},
		}

	case .Rifle_Grip:
		return Hand_Pose_Profile{
			name            = "Rifle Grip",
			thumb_pos_2d    = {0.20, 0.05},
			thumb_sweep     = 0.75,
			thumb_roll      = 0.65,
			thumb_mid_curl  = 0.75,
			thumb_tip_curl  = 0.80,
			index_finger    = {0.75, 0.75, 0.75, -0.05},
			middle_finger   = {0.85, 0.85, 0.85,  0.00},
			ring_finger     = {0.90, 0.90, 0.90,  0.00},
			pinky_finger    = {0.90, 0.90, 0.90,  0.00},
			collider_size   = {0.076, 0.132, 0.098},
			collider_center = {0.024, 0.068, 0.000},
		}

	case .Claw_Grip:
		return Hand_Pose_Profile{
			name            = "Claw Grip",
			thumb_pos_2d    = {0.35, 0.10},
			thumb_sweep     = 0.55,
			thumb_roll      = 0.50,
			thumb_mid_curl  = 0.45,
			thumb_tip_curl  = 0.85,
			index_finger    = {-0.30, 0.95, 0.95, -0.22},
			middle_finger   = {-0.30, 0.95, 0.95, -0.04},
			ring_finger     = {-0.30, 0.95, 0.95,  0.12},
			pinky_finger    = {-0.30, 0.95, 0.95,  0.28},
			collider_size   = {0.074, 0.155, 0.132},
			collider_center = {0.020, 0.078, 0.004},
		}

	case .Lightning_Cast:
		return Hand_Pose_Profile{
			name            = "Lightning Cast",
			thumb_pos_2d    = {0.75, 0.35},
			thumb_sweep     = 0.20,
			thumb_roll      = 0.20,
			thumb_mid_curl  = 0.55,
			thumb_tip_curl  = -0.25,
			index_finger    = {-0.40, 0.75, -0.25, -0.45},
			middle_finger   = {-0.40, 0.75, -0.25, -0.07},
			ring_finger     = {-0.40, 0.75, -0.25,  0.24},
			pinky_finger    = {-0.40, 0.75, -0.25,  0.55},
			collider_size   = {0.070, 0.172, 0.155},
			collider_center = {0.015, 0.086, 0.008},
		}

	case .Custom:
		return hand_pose_preset_get(.Relaxed)
	}
	return hand_pose_preset_get(.Relaxed)
}

// Linearly interpolates both finger joint values AND the hand BoxCollider shape!
hand_pose_profile_lerp :: proc(a, b: Hand_Pose_Profile, t: f32) -> Hand_Pose_Profile {
	alpha := math.clamp(t, 0.0, 1.0)
	return Hand_Pose_Profile{
		name            = alpha < 0.5 ? a.name : b.name,
		thumb_pos_2d    = linalg.lerp(a.thumb_pos_2d, b.thumb_pos_2d, alpha),
		thumb_sweep     = math.lerp(a.thumb_sweep, b.thumb_sweep, alpha),
		thumb_roll      = math.lerp(a.thumb_roll, b.thumb_roll, alpha),
		thumb_mid_curl  = math.lerp(a.thumb_mid_curl, b.thumb_mid_curl, alpha),
		thumb_tip_curl  = math.lerp(a.thumb_tip_curl, b.thumb_tip_curl, alpha),
		index_finger    = linalg.lerp(a.index_finger, b.index_finger, alpha),
		middle_finger   = linalg.lerp(a.middle_finger, b.middle_finger, alpha),
		ring_finger     = linalg.lerp(a.ring_finger, b.ring_finger, alpha),
		pinky_finger    = linalg.lerp(a.pinky_finger, b.pinky_finger, alpha),
		collider_size   = linalg.lerp(a.collider_size, b.collider_size, alpha),
		collider_center = linalg.lerp(a.collider_center, b.collider_center, alpha),
	}
}

// =============================================================================
// COMBINABLE MACRO DRIVERS (CURL + CLAW + SPREAD) & PROFILE APPLICATION
// =============================================================================

// Computes the combined (Base MCP, Mid PIP, Tip DIP) knuckle vector from Master Curl and Master Claw.
// Master Curl flexes all 3 joints forward (+C), while Master Claw hyper-extends Base (-0.65*K)
// and tightly hooks Mid & Tip (+0.85*K), allowing full combination of both sliders!
@(private = "file")
_compute_curl_claw_vec :: #force_inline proc(curl, claw: f32) -> [3]f32 {
	return {
		curl - 0.65 * claw,
		curl + 0.85 * claw,
		curl + 0.85 * claw,
	}
}

// Infers master_curl, master_claw, and master_spread from a pose profile's finger vectors.
hand_side_infer_macros_from_pose :: proc(side: ^Hand_Side_State) {
	if side == nil do return
	avg_x  := (side.pose.index_finger.x + side.pose.middle_finger.x + side.pose.ring_finger.x + side.pose.pinky_finger.x) * 0.25
	avg_yz := (side.pose.index_finger.y + side.pose.middle_finger.y + side.pose.ring_finger.y + side.pose.pinky_finger.y +
	           side.pose.index_finger.z + side.pose.middle_finger.z + side.pose.ring_finger.z + side.pose.pinky_finger.z) * 0.125

	// Since avg_yz - avg_x = 1.50 * claw:
	inferred_claw := math.clamp((avg_yz - avg_x) / 1.50, 0.0, 1.0)
	inferred_curl := math.clamp(avg_x + 0.65 * inferred_claw, -0.35, 1.25)

	side.master_claw   = inferred_claw
	side.master_curl   = inferred_curl
	side.master_spread = math.clamp((side.pose.pinky_finger.w - side.pose.index_finger.w) / 1.55, -0.5, 1.0)
}

hand_side_apply_profile :: proc(side: ^Hand_Side_State, prof: Hand_Pose_Profile, preset: Hand_Pose_Preset = .Custom) {
	if side == nil do return
	side.preset = preset
	side.pose   = prof
	hand_side_infer_macros_from_pose(side)
	side.is_blending = false
}

hand_side_apply_preset :: proc(side: ^Hand_Side_State, preset: Hand_Pose_Preset) {
	if side == nil do return
	side.preset = preset
	if preset != .Custom {
		hand_side_apply_profile(side, hand_pose_preset_get(preset), preset)
	}
	side.is_blending = false
}

// Smoothly transitions a hand from its current pose to `target` over `duration` seconds.
hand_side_blend_to_profile :: proc(side: ^Hand_Side_State, target: Hand_Pose_Profile, duration: f32 = 0.20) {
	if side == nil do return
	if duration <= 0.001 {
		hand_side_apply_profile(side, target, .Custom)
		return
	}
	side.blend_start    = side.pose
	side.blend_target   = target
	side.blend_time     = 0.0
	side.blend_duration = duration
	side.is_blending    = true
}

// Combinable Master Curl: updates master_curl and combines it with master_claw (plus any per-finger offsets!)
hand_side_set_master_curl :: proc(side: ^Hand_Side_State, curl: f32, include_thumb: bool = false) {
	if side == nil do return
	old_m := _compute_curl_claw_vec(side.master_curl, side.master_claw)
	side.master_curl = curl
	new_m := _compute_curl_claw_vec(side.master_curl, side.master_claw)
	delta := new_m - old_m

	side.preset = .Custom
	side.pose.index_finger.xyz  = linalg.clamp(side.pose.index_finger.xyz  + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
	side.pose.middle_finger.xyz = linalg.clamp(side.pose.middle_finger.xyz + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
	side.pose.ring_finger.xyz   = linalg.clamp(side.pose.ring_finger.xyz   + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
	side.pose.pinky_finger.xyz  = linalg.clamp(side.pose.pinky_finger.xyz  + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})

	if include_thumb {
		c := math.clamp(curl, 0.0, 1.0)
		side.pose.thumb_sweep    = math.lerp(f32(0.15), f32(0.65), c)
		side.pose.thumb_roll     = math.lerp(f32(0.10), f32(0.55), c)
		side.pose.thumb_mid_curl = math.lerp(f32(0.10), f32(0.65), c)
		side.pose.thumb_tip_curl = math.lerp(f32(0.10), f32(0.85), c)
	}
}

// Combinable Master Claw: extends MCP base while hooking PIP & DIP joints ON TOP OF current Master Curl!
hand_side_set_master_claw :: proc(side: ^Hand_Side_State, claw: f32) {
	if side == nil do return
	old_m := _compute_curl_claw_vec(side.master_curl, side.master_claw)
	side.master_claw = claw
	new_m := _compute_curl_claw_vec(side.master_curl, side.master_claw)
	delta := new_m - old_m

	side.preset = .Custom
	side.pose.index_finger.xyz  = linalg.clamp(side.pose.index_finger.xyz  + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
	side.pose.middle_finger.xyz = linalg.clamp(side.pose.middle_finger.xyz + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
	side.pose.ring_finger.xyz   = linalg.clamp(side.pose.ring_finger.xyz   + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
	side.pose.pinky_finger.xyz  = linalg.clamp(side.pose.pinky_finger.xyz  + delta, [3]f32{-0.45, -0.45, -0.45}, [3]f32{1.25, 1.25, 1.25})
}

// Combinable Master Spread: fans all 4 fingers apart (propagates into .w splay component)
hand_side_set_master_spread :: proc(side: ^Hand_Side_State, spread: f32) {
	if side == nil do return
	side.master_spread = spread
	side.preset = .Custom
	side.pose.index_finger.w  = -0.70 * spread
	side.pose.middle_finger.w = -0.10 * spread
	side.pose.ring_finger.w   =  0.35 * spread
	side.pose.pinky_finger.w  =  0.85 * spread
}

// =============================================================================
// COMPONENT LIFECYCLE
// =============================================================================

reset_HandPoseDriver :: proc(driver: ^HandPoseDriver) {
	driver.active = true
	driver.weight = 1.0
	driver.mirror_hands = false
	driver.collider_mode = .Pose_And_Auto
	hand_side_apply_preset(&driver.left, .Relaxed)
	hand_side_apply_preset(&driver.right, .Relaxed)
	driver.left_calib = {}
	driver.right_calib = {}
}

cleanup_HandPoseDriver :: proc(driver: ^HandPoseDriver) {
	engine.comp_zero(driver)
}

on_destroy_HandPoseDriver :: proc(driver: ^HandPoseDriver) {
	cleanup_HandPoseDriver(driver)
}

@(inspector_button={label="Rebind & Calibrate Hand Bones", row=-1})
hand_pose_driver_rebind :: proc(driver: ^HandPoseDriver) {
	if driver == nil do return
	driver.left_calib.bound = false
	driver.right_calib.bound = false
	hand_pose_driver_ensure_bound(driver)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

// =============================================================================
// AUTO-CALIBRATED HAND & FINGER BONE BINDING
// =============================================================================

@(private = "file")
_calib_alive :: proc(c: ^Hand_Calibrated_Bones) -> bool {
	if !c.bound || c.hand_bone == {} do return false
	w := engine.ctx_world()
	if w == nil do return false
	return engine.pool_valid(&w.transforms, engine.Handle(c.hand_bone))
}

@(private = "file")
_find_finger_bone :: proc(root: engine.Transform_Handle, digit_name: string, index: int, is_left: bool) -> engine.Transform_Handle {
	side_char := "l" if is_left else "r"
	side_word := "left" if is_left else "right"

	// Common naming conventions across Quaternius UAL, Unreal Mannequin, Mixamo, Rigify, Blender, VRM, CC4
	aliases := [10]string{
		fmt.tprintf("%s_0%d_%s", digit_name, index, side_char),
		fmt.tprintf("%s.0%d.%s", digit_name, index, side_char),
		fmt.tprintf("%s%d_%s", digit_name, index, side_char),
		fmt.tprintf("f_%s.0%d.%s", digit_name, index, side_char),
		fmt.tprintf("def-f_%s.0%d.%s", digit_name, index, side_char),
		fmt.tprintf("def-%s.0%d.%s", digit_name, index, side_char),
		fmt.tprintf("%shand%s%d", side_word, digit_name, index),
		fmt.tprintf("mixamorig:%shand%s%d", side_word, digit_name, index),
		fmt.tprintf("bip01_%s_finger%d", side_char, index),
		fmt.tprintf("%s_0%d.%s", digit_name, index, side_char),
	}
	return skeleton_find_bone_by_aliases(root, aliases[:])
}

@(private = "file")
_find_finger_leaf :: proc(root: engine.Transform_Handle, last_phalanx: engine.Transform_Handle, digit_name: string, is_left: bool) -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil do return {}
	// First check direct child of phalanx 03 (e.g. index_04_leaf_l or index_end)
	if last_phalanx != {} {
		if t := engine.pool_get(&w.transforms, engine.Handle(last_phalanx)); t != nil && len(t.children) > 0 {
			return engine.Transform_Handle(t.children[0].handle)
		}
	}
	side_char := "l" if is_left else "r"
	side_word := "left" if is_left else "right"
	aliases := [4]string{
		fmt.tprintf("%s_04_leaf_%s", digit_name, side_char),
		fmt.tprintf("%s_04_%s", digit_name, side_char),
		fmt.tprintf("%shand%s4", side_word, digit_name),
		fmt.tprintf("mixamorig:%shand%s4", side_word, digit_name),
	}
	return skeleton_find_bone_by_aliases(root, aliases[:])
}

safe_normalize :: #force_inline proc(v: [3]f32, fallback := [3]f32{0, 1, 0}) -> [3]f32 {
	len_sq := linalg.length2(v)
	if len_sq > 1e-8 && !math.is_nan(len_sq) && !math.is_inf(len_sq) {
		return v * (1.0 / math.sqrt(len_sq))
	}
	return fallback
}

@(private = "file")
_restore_hand_phalanges_to_bind_pose :: proc(owner: engine.Transform_Handle, search_root: engine.Transform_Handle, calib: ^Hand_Calibrated_Bones) {
	w := engine.ctx_world()
	if w == nil || owner == {} do return

	_, adm := engine.transform_get_comp(owner, ArmatureDeformedMesh)
	if adm == nil && search_root != {} && search_root != owner {
		_, adm = engine.transform_get_comp(search_root, ArmatureDeformedMesh)
	}
	if adm == nil {
		it := engine.pool_iterator(armature_deformed_meshes(w))
		for candidate, _ in engine.pool_next(&it) {
			if candidate.owner == owner || candidate.root_bone.handle == engine.Handle(search_root) {
				adm = candidate
				break
			}
		}
	}
	if adm == nil do return

	mesh_guid := adm.mesh
	if engine.asset_guid_is_empty(mesh_guid) {
		if _, mf := engine.transform_get_comp(engine.Transform_Handle(adm.owner), engine.MeshFilter); mf != nil {
			mesh_guid = mf.mesh.guid
		}
	}
	if engine.asset_guid_is_empty(mesh_guid) do return

	// 1. Primary path: Reconstruct exact bind-pose local position & rotation from the engine's
	//    imported binary mesh cache (`mesh.inverse_binds`).
	//    NOTE: Odin `matrix[4, 4]f32` is indexed `m[row, col]`:
	//    - Translation is in column 3 (`m[0, 3], m[1, 3], m[2, 3]`, i.e. `m[3].xyz`).
	//    - Rotation basis vectors are columns 0, 1, 2 (`m[0].xyz`, `m[1].xyz`, `m[2].xyz`).
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	if mok && mesh != nil && len(mesh.joint_names) > 0 && len(mesh.inverse_binds) > 0 {
		n_joints := min(len(mesh.joint_names), len(mesh.inverse_binds))
		bind_mats := make([]matrix[4, 4]f32, n_joints, context.temp_allocator)
		for i in 0 ..< n_joints {
			bind_mats[i] = linalg.inverse(mesh.inverse_binds[i])
		}

		_find_joint_idx :: proc(names: []string, count: int, target: string) -> int {
			for i in 0 ..< count {
				if strings.equal_fold(names[i], target) do return i
			}
			return -1
		}

		restored_any := false
		for d in 0 ..< 5 {
			for p in 0 ..< 3 {
				bh := calib.phalanges[d][p]
				if bh == {} do continue
				bt := engine.pool_get(&w.transforms, engine.Handle(bh))
				if bt == nil || bt.parent.handle == {} do continue

				b_idx := _find_joint_idx(mesh.joint_names, n_joints, bt.name)
				if b_idx < 0 do continue

				p_idx := -1
				if pt := engine.pool_get(&w.transforms, bt.parent.handle); pt != nil {
					p_idx = _find_joint_idx(mesh.joint_names, n_joints, pt.name)
				}

				m_parent := bind_mats[p_idx] if p_idx >= 0 else linalg.MATRIX4F32_IDENTITY
				m_bone   := bind_mats[b_idx]
				m_local  := linalg.inverse(m_parent) * m_bone

				// Column 3 of m_local holds translation (m_local[0, 3], m_local[1, 3], m_local[2, 3])
				local_pos := m_local[3].xyz
				if linalg.length2(local_pos) > 1e-10 {
					bt.position = local_pos
				}

				// Columns 0, 1, 2 of m_local hold the local X, Y, Z basis vectors
				c0 := safe_normalize(m_local[0].xyz, {1, 0, 0})
				c1 := safe_normalize(m_local[1].xyz, {0, 1, 0})
				c2 := safe_normalize(m_local[2].xyz, {0, 0, 1})
				// matrix[3, 3]f32 literal is row-by-row: row 0 = {c0.x, c1.x, c2.x}, etc.
				rot_mat := matrix[3, 3]f32{
					c0.x, c1.x, c2.x,
					c0.y, c1.y, c2.y,
					c0.z, c1.z, c2.z,
				}
				bt.rotation = safe_quat(engine.quat_from_native(linalg.quaternion_from_matrix3(rot_mat)))
				restored_any = true
			}
		}
		if restored_any do return
	}

	// 2. Headless / unit-test fallback (when gfx.device() == nil so mesh_load returns false):
	//    Read bind-pose node transforms directly from the source model file if available.
	if source_path, path_ok := engine.asset_db_get_path(uuid.Identifier(mesh_guid)); path_ok {
		path_c := strings.clone_to_cstring(source_path, context.temp_allocator)
		opts := cgltf.options{}
		if data, parse_res := cgltf.parse_file(opts, path_c); parse_res == .success {
			defer cgltf.free(data)
			for d in 0 ..< 5 {
				for p in 0 ..< 3 {
					bh := calib.phalanges[d][p]
					if bh == {} do continue
					bt := engine.pool_get(&w.transforms, engine.Handle(bh))
					if bt == nil || bt.parent.handle == {} do continue
					for &node in data.nodes {
						if node.name != nil && strings.equal_fold(string(node.name), bt.name) {
							if node.has_translation do bt.position = node.translation
							bt.rotation = node.rotation if node.has_rotation else [4]f32{0, 0, 0, 1}
							break
						}
					}
				}
			}
		}
	}
}

@(private = "file")
_calibrate_single_hand :: proc(calib: ^Hand_Calibrated_Bones, owner: engine.Transform_Handle, search_root: engine.Transform_Handle, hand_h: engine.Transform_Handle, is_left: bool) -> bool {
	w := engine.ctx_world()
	if w == nil || hand_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(hand_h)) do return false

	calib^ = {}
	calib.hand_bone = hand_h

	digit_names := [5]string{"thumb", "index", "middle", "ring", "pinky"}
	found_digits := 0

	// Search within the hand subtree first for speed and precision, falling back to search_root
	for d in 0 ..< 5 {
		for p in 0 ..< 3 {
			bh := _find_finger_bone(hand_h, digit_names[d], p + 1, is_left)
			if bh == {} do bh = _find_finger_bone(search_root, digit_names[d], p + 1, is_left)
			calib.phalanges[d][p] = bh
		}
		if calib.phalanges[d][0] != {} && calib.phalanges[d][1] != {} && calib.phalanges[d][2] != {} {
			found_digits += 1
		}
		calib.leaf_tips[d] = _find_finger_leaf(hand_h, calib.phalanges[d][2], digit_names[d], is_left)
	}

	if found_digits == 0 do return false

	// CRITICAL FIX: Ensure the 15 finger phalanges are in their authentic uncurled bind pose
	// before measuring rest_local_rot, joint_wpos, and curl/splay axes! Otherwise, if a scene
	// was saved while the character's hands were already curled into a Fist, calibrating from
	// the curled transforms corrupts the axes and double-curls the mesh on first interaction!
	_restore_hand_phalanges_to_bind_pose(owner, search_root, calib)

	// Capture rest local transforms and world positions of all joints
	joint_wpos: [5][4][3]f32
	joint_wrot: [5][3]quaternion128

	for d in 0 ..< 5 {
		for p in 0 ..< 3 {
			bh := calib.phalanges[d][p]
			if bh == {} do continue
			if bt := engine.pool_get(&w.transforms, engine.Handle(bh)); bt != nil {
				calib.rest_local_pos[d][p] = bt.position
				calib.rest_local_rot[d][p] = safe_quat(bt.rotation)
			}
			joint_wpos[d][p] = engine.transform_world_position(bh)
			joint_wrot[d][p] = safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(bh)))
		}
		// Tip position (04_leaf or extrapolated from 02 -> 03)
		if calib.leaf_tips[d] != {} {
			joint_wpos[d][3] = engine.transform_world_position(calib.leaf_tips[d])
		} else if calib.phalanges[d][1] != {} && calib.phalanges[d][2] != {} {
			dir_12 := joint_wpos[d][2] - joint_wpos[d][1]
			joint_wpos[d][3] = joint_wpos[d][2] + dir_12 * 0.85
		}
		for p in 0 ..< 3 {
			calib.segment_length[d][p] = linalg.distance(joint_wpos[d][p], joint_wpos[d][p + 1])
			if calib.segment_length[d][p] < 0.005 do calib.segment_length[d][p] = 0.030
		}
	}

	// -------------------------------------------------------------------------
	// 1. DERIVE TRUE ANATOMICAL PALM BASIS IN WORLD SPACE
	// -------------------------------------------------------------------------
	hand_wpos := engine.transform_world_position(hand_h)
	hand_wrot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(hand_h)))
	inv_hand_wrot := linalg.quaternion_inverse(hand_wrot)

	// Distal direction: wrist -> middle knuckle (or index knuckle fallback)
	mid_knuckle := joint_wpos[2][0] if calib.phalanges[2][0] != {} else joint_wpos[1][0]
	distal_w := safe_normalize(mid_knuckle - hand_wpos, {0, 1, 0})

	// Radial direction across knuckles: pinky_01 -> index_01 (orthogonalized against distal_w)
	across_raw := joint_wpos[1][0] - joint_wpos[4][0]
	across_ortho := across_raw - distal_w * linalg.dot(across_raw, distal_w)
	radial_w := safe_normalize(across_ortho, {0, 0, 1})

	// Palmar inward normal (pointing out of the palm):
	// By right-hand rule on human anatomy:
	// - Left hand:  distal_w x radial_w points out of the palm
	// - Right hand: radial_w x distal_w points out of the palm
	palmar_w := safe_normalize(
		linalg.cross(distal_w, radial_w) if is_left else linalg.cross(radial_w, distal_w),
		{1, 0, 0},
	)

	// Verify palmar_w using thumb_01 position (the thumb base always sits on the palmar-radial side of the hand)
	if calib.phalanges[0][0] != {} && calib.phalanges[1][0] != {} {
		thumb_offset := joint_wpos[0][0] - joint_wpos[1][0]
		if linalg.dot(thumb_offset, palmar_w) < -0.005 {
			palmar_w = -palmar_w
		}
	}

	// Store canonical basis in hand_bone's local space for dynamic BoxCollider fitting & mirroring
	calib.palm_inward_local = safe_normalize(linalg.quaternion128_mul_vector3(inv_hand_wrot, palmar_w), {1, 0, 0})
	calib.distal_local      = safe_normalize(linalg.quaternion128_mul_vector3(inv_hand_wrot, distal_w), {0, 1, 0})
	calib.radial_local      = safe_normalize(linalg.quaternion128_mul_vector3(inv_hand_wrot, radial_w), {0, 0, 1})

	// -------------------------------------------------------------------------
	// 2. CALIBRATE THE 4 FINGERS (Index=1, Middle=2, Ring=3, Pinky=4)
	// -------------------------------------------------------------------------
	for d in 1 ..= 4 {
		for p in 0 ..< 3 {
			if calib.phalanges[d][p] == {} do continue
			inv_q := linalg.quaternion_inverse(joint_wrot[d][p])

			// Bone length vector in world space
			bone_dir_w := safe_normalize(joint_wpos[d][p + 1] - joint_wpos[d][p], distal_w)

			// Positive Curl rotates bone_dir_w toward palmar_w: axis = normalize(bone_dir_w x palmar_w)
			curl_w := safe_normalize(linalg.cross(bone_dir_w, palmar_w), radial_w)
			calib.curl_axis_local[d][p] = safe_normalize(linalg.quaternion128_mul_vector3(inv_q, curl_w), {1, 0, 0})

			if p == 0 {
				// Positive Splay (.w > 0) rotates bone_dir_w toward ulnar/pinky side (-radial_w):
				// axis = normalize(bone_dir_w x (-radial_w))
				splay_w := safe_normalize(linalg.cross(bone_dir_w, -radial_w), palmar_w)
				calib.splay_axis_local[d] = safe_normalize(linalg.quaternion128_mul_vector3(inv_q, splay_w), {0, 0, 1})
			}
		}
	}

	// -------------------------------------------------------------------------
	// 3. CALIBRATE THE THUMB (d = 0: thumb_01, thumb_02, thumb_03)
	// -------------------------------------------------------------------------
	if calib.phalanges[0][0] != {} {
		thumb_base_w := joint_wpos[0][0]
		thumb_tip_w  := joint_wpos[0][3]
		thumb_dir_w  := safe_normalize(thumb_tip_w - thumb_base_w, safe_normalize(distal_w + radial_w, {0, 1, 0}))

		// Anatomical thumb sweep/flexion target: sweeps across the palm toward the ring/pinky knuckle on the palmar side
		pinch_target_w := joint_wpos[3][0] + palmar_w * 0.035
		inward_sweep_w := safe_normalize(pinch_target_w - thumb_base_w, palmar_w)

		// Shared anatomical thumb flexion hinge axis (rotates thumb_dir_w across palm toward pinch_target_w)
		thumb_flex_axis_w := safe_normalize(linalg.cross(thumb_dir_w, inward_sweep_w), distal_w)

		// Thumb abduction / spread axis (rotates thumb_dir_w outward away from palm/index toward +radial_w)
		outward_abduct_w := safe_normalize(radial_w * 0.80 - palmar_w * 0.40, radial_w)
		thumb_abduct_axis_w := safe_normalize(linalg.cross(thumb_dir_w, outward_abduct_w), palmar_w)

		// Thumb elevation axis (moves thumb distally up over curled fingers vs down toward wrist)
		thumb_up_axis_w := safe_normalize(linalg.cross(thumb_dir_w, distal_w), radial_w)

		inv_q0 := linalg.quaternion_inverse(joint_wrot[0][0])
		calib.splay_axis_local[0]    = safe_normalize(linalg.quaternion128_mul_vector3(inv_q0, thumb_abduct_axis_w), {0, 0, 1})
		calib.thumb_up_axis_local    = safe_normalize(linalg.quaternion128_mul_vector3(inv_q0, thumb_up_axis_w), {1, 0, 0})

		// Thumb axial roll axis (rotates around thumb_01's own bone length into opposition)
		d0_w := safe_normalize(joint_wpos[0][1] - joint_wpos[0][0], thumb_dir_w)
		// Ensure positive roll rotates thumb pad toward fingers (right-hand rule along +d0_w or -d0_w)
		roll_sign: f32 = -1.0 if is_left else 1.0
		calib.thumb_roll_axis_local = safe_normalize(linalg.quaternion128_mul_vector3(inv_q0, d0_w * roll_sign), {0, 1, 0})

		// Project the exact same anatomical flexion plane into thumb_01, thumb_02, and thumb_03!
		for p in 0 ..< 3 {
			if calib.phalanges[0][p] == {} do continue
			inv_qp := linalg.quaternion_inverse(joint_wrot[0][p])
			calib.curl_axis_local[0][p] = safe_normalize(linalg.quaternion128_mul_vector3(inv_qp, thumb_flex_axis_w), {1, 0, 0})
		}
	}

	calib.bound = true
	return true
}

hand_pose_driver_ensure_bound :: proc(driver: ^HandPoseDriver) -> bool {
	if driver == nil || driver.owner == {} do return false
	if _calib_alive(&driver.left_calib) && _calib_alive(&driver.right_calib) {
		return true
	}

	w := engine.ctx_world()
	if w == nil do return false

	// Resolve Humanoid_Bones from sibling ControlRig pointer if available, else bind locally
	local_bones: Humanoid_Bones
	bones: ^Humanoid_Bones = nil
	if _, rig := engine.transform_get_comp(driver.owner, ControlRig); rig != nil {
		bones = control_rig_ensure_bones(rig)
	} else {
		skeleton_bind_humanoid(&local_bones, driver.owner)
		bones = &local_bones
	}
	if bones == nil || !bones.bound do return false

	search_root := bones.search_root != {} ? bones.search_root : driver.owner

	newly_calibrated := false
	if !_calib_alive(&driver.left_calib) && bones.left_hand != {} {
		if _calibrate_single_hand(&driver.left_calib, driver.owner, search_root, bones.left_hand, true) {
			newly_calibrated = true
		}
	}
	if !_calib_alive(&driver.right_calib) && bones.right_hand != {} {
		if _calibrate_single_hand(&driver.right_calib, driver.owner, search_root, bones.right_hand, false) {
			newly_calibrated = true
		}
	}

	// Re-apply the current hand pose immediately after bind-pose calibration so the fingers
	// seamlessly display their active Hand_Pose_Profile without waiting for a slider drag.
	if newly_calibrated && driver.enabled && driver.active && driver.weight > 0.001 {
		if driver.mirror_hands {
			driver.right.preset        = driver.left.preset
			driver.right.master_curl   = driver.left.master_curl
			driver.right.master_claw   = driver.left.master_claw
			driver.right.master_spread = driver.left.master_spread
			driver.right.pose          = driver.left.pose
		}
		_solve_single_hand(&driver.left_calib, &driver.left, driver.weight, driver.collider_mode)
		_solve_single_hand(&driver.right_calib, &driver.right, driver.weight, driver.collider_mode)
		if _, adm := engine.transform_get_comp(driver.owner, ArmatureDeformedMesh); adm != nil {
			adm.posed_frame = 0
		}
	}

	return driver.left_calib.bound || driver.right_calib.bound
}

// =============================================================================
// REAL-TIME FINGER ARTICULATION & DYNAMIC HAND BOX COLLIDER SOLVER
// =============================================================================

@(private = "file")
_solve_single_hand :: proc(
	calib: ^Hand_Calibrated_Bones,
	side: ^Hand_Side_State,
	weight: f32,
	collider_mode: Hand_Collider_Mode,
) {
	if !calib.bound || calib.hand_bone == {} do return
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(calib.hand_bone)) do return

	pose := &side.pose
	eff_w := math.clamp(weight, 0.0, 1.0)

	// -------------------------------------------------------------------------
	// 1. SOLVE 4 FINGERS (Index, Middle, Ring, Pinky)
	// -------------------------------------------------------------------------
	digit_vecs := [4][4]f32{
		pose.index_finger,
		pose.middle_finger,
		pose.ring_finger,
		pose.pinky_finger,
	}

	for f in 0 ..< 4 {
		d := f + 1 // 1..4
		v := digit_vecs[f]

		// Phalanx curl angles in radians (Base=80 deg, Mid=90 deg, Tip=80 deg)
		curl_rad := [3]f32{
			linalg.to_radians(80.0 * v.x),
			linalg.to_radians(90.0 * v.y),
			linalg.to_radians(80.0 * v.z),
		}
		splay_rad := linalg.to_radians(45.0 * v.w)

		for p in 0 ..< 3 {
			bh := calib.phalanges[d][p]
			if bh == {} do continue
			bt := engine.pool_get(&w.transforms, engine.Handle(bh))
			if bt == nil do continue

			q_rest := safe_quat_native(engine.quat_to_native(calib.rest_local_rot[d][p]))
			q_curl := linalg.quaternion_angle_axis_f32(curl_rad[p], calib.curl_axis_local[d][p])

			q_target: quaternion128
			if p == 0 {
				q_splay := linalg.quaternion_angle_axis_f32(splay_rad, calib.splay_axis_local[d])
				q_target = safe_quat_native(q_rest * q_splay * q_curl)
			} else {
				q_target = safe_quat_native(q_rest * q_curl)
			}

			if eff_w < 0.999 {
				q_target = safe_quat_native(linalg.quaternion_slerp(q_rest, q_target, eff_w))
			}
			bt.rotation = engine.quat_from_native(q_target)
		}
	}

	// -------------------------------------------------------------------------
	// 2. SOLVE ALIGNED ANATOMICAL THUMB (thumb_01, thumb_02, thumb_03)
	// -------------------------------------------------------------------------
	if calib.phalanges[0][0] != {} {
		// Base CMC joint (thumb_01): 2D Abduction/Elevation + Sweep across palm + Axial Opposition Roll
		abduct_rad := linalg.to_radians(40.0 * pose.thumb_pos_2d.x)
		elev_rad   := linalg.to_radians(35.0 * pose.thumb_pos_2d.y)
		sweep_rad  := linalg.to_radians(50.0 * pose.thumb_sweep)
		roll_rad   := linalg.to_radians(65.0 * pose.thumb_roll)

		if bt0 := engine.pool_get(&w.transforms, engine.Handle(calib.phalanges[0][0])); bt0 != nil {
			q_rest0   := safe_quat_native(engine.quat_to_native(calib.rest_local_rot[0][0]))
			q_abduct  := linalg.quaternion_angle_axis_f32(abduct_rad, calib.splay_axis_local[0])
			q_elev    := linalg.quaternion_angle_axis_f32(elev_rad, calib.thumb_up_axis_local)
			q_sweep   := linalg.quaternion_angle_axis_f32(sweep_rad, calib.curl_axis_local[0][0])
			q_roll    := linalg.quaternion_angle_axis_f32(roll_rad, calib.thumb_roll_axis_local)

			q_target0 := safe_quat_native(q_rest0 * q_abduct * q_elev * q_sweep * q_roll)
			if eff_w < 0.999 {
				q_target0 = safe_quat_native(linalg.quaternion_slerp(q_rest0, q_target0, eff_w))
			}
			bt0.rotation = engine.quat_from_native(q_target0)
		}

		// Mid MCP hinge (thumb_02): 1-DOF flexion in the shared thumb flexion plane
		if calib.phalanges[0][1] != {} {
			if bt1 := engine.pool_get(&w.transforms, engine.Handle(calib.phalanges[0][1])); bt1 != nil {
				q_rest1   := safe_quat_native(engine.quat_to_native(calib.rest_local_rot[0][1]))
				mid_rad   := linalg.to_radians(75.0 * pose.thumb_mid_curl)
				q_hinge1  := linalg.quaternion_angle_axis_f32(mid_rad, calib.curl_axis_local[0][1])
				q_target1 := safe_quat_native(q_rest1 * q_hinge1)
				if eff_w < 0.999 {
					q_target1 = safe_quat_native(linalg.quaternion_slerp(q_rest1, q_target1, eff_w))
				}
				bt1.rotation = engine.quat_from_native(q_target1)
			}
		}

		// Tip IP hinge (thumb_03): 1-DOF flexion in the shared thumb flexion plane
		if calib.phalanges[0][2] != {} {
			if bt2 := engine.pool_get(&w.transforms, engine.Handle(calib.phalanges[0][2])); bt2 != nil {
				q_rest2   := safe_quat_native(engine.quat_to_native(calib.rest_local_rot[0][2]))
				tip_rad   := linalg.to_radians(90.0 * pose.thumb_tip_curl)
				q_hinge2  := linalg.quaternion_angle_axis_f32(tip_rad, calib.curl_axis_local[0][2])
				q_target2 := safe_quat_native(q_rest2 * q_hinge2)
				if eff_w < 0.999 {
					q_target2 = safe_quat_native(linalg.quaternion_slerp(q_rest2, q_target2, eff_w))
				}
				bt2.rotation = engine.quat_from_native(q_target2)
			}
		}
	}

	// -------------------------------------------------------------------------
	// 3. DYNAMIC HAND BOX COLLIDER UPDATE
	// -------------------------------------------------------------------------
	if collider_mode != .Disabled {
		_update_hand_box_collider(calib, side, collider_mode)
	}
}

// Computes the canonical BoxCollider size & center from the current posed finger joints!
// Canonical coordinates:
//   .x = Palmar/Dorsal thickness (along calib.palm_inward_local)
//   .y = Distal length from wrist to fingertips (along calib.distal_local)
//   .z = Radial/Ulnar width across knuckles/splayed fingers (along calib.radial_local)
hand_pose_compute_auto_box :: proc(calib: ^Hand_Calibrated_Bones) -> (canonical_size: [3]f32, canonical_center: [3]f32) {
	if !calib.bound || calib.hand_bone == {} {
		return {0.052, 0.175, 0.105}, {0.012, 0.088, 0.004}
	}

	hand_tw := engine.transform_world(calib.hand_bone)
	hand_pos := hand_tw.position
	hand_rot := safe_quat_native(engine.quat_to_native(hand_tw.rotation))
	inv_hand_rot := linalg.quaternion_inverse(hand_rot)

	// Start bounds at the wrist joint with anatomical wrist pad thickness
	b_min := [3]f32{-0.014, 0.000, -0.036}
	b_max := [3]f32{ 0.018, 0.040,  0.036}

	pad := [3]f32{0.011, 0.012, 0.011} // Finger flesh pad radius (~1.1 cm)

	for d in 0 ..< 5 {
		for p in 0 ..< 3 {
			bh := calib.phalanges[d][p]
			if bh == {} do continue
			wpos := engine.transform_world_position(bh)
			rel_local := linalg.quaternion128_mul_vector3(inv_hand_rot, wpos - hand_pos)

			// Project into canonical (palmar, distal, radial) coordinates
			cx := linalg.dot(rel_local, calib.palm_inward_local)
			cy := linalg.dot(rel_local, calib.distal_local)
			cz := linalg.dot(rel_local, calib.radial_local)

			b_min.x = math.min(b_min.x, cx - pad.x)
			b_max.x = math.max(b_max.x, cx + pad.x)
			b_min.y = math.min(b_min.y, cy - pad.y)
			b_max.y = math.max(b_max.y, cy + pad.y)
			b_min.z = math.min(b_min.z, cz - pad.z)
			b_max.z = math.max(b_max.z, cz + pad.z)
		}

		// Also include leaf fingertip if present, or extrapolate from distal phalanx
		tip_wpos: [3]f32
		has_tip := false
		if calib.leaf_tips[d] != {} {
			tip_wpos = engine.transform_world_position(calib.leaf_tips[d])
			has_tip = true
		} else if calib.phalanges[d][2] != {} {
			p2_wpos := engine.transform_world_position(calib.phalanges[d][2])
			p2_wrot := safe_quat_native(engine.quat_to_native(engine.transform_world_rotation(calib.phalanges[d][2])))
			tip_wpos = p2_wpos + linalg.quaternion128_mul_vector3(p2_wrot, [3]f32{0, calib.segment_length[d][2], 0})
			has_tip = true
		}
		if has_tip {
			rel_local := linalg.quaternion128_mul_vector3(inv_hand_rot, tip_wpos - hand_pos)
			cx := linalg.dot(rel_local, calib.palm_inward_local)
			cy := linalg.dot(rel_local, calib.distal_local)
			cz := linalg.dot(rel_local, calib.radial_local)

			b_min.x = math.min(b_min.x, cx - pad.x)
			b_max.x = math.max(b_max.x, cx + pad.x)
			b_min.y = math.min(b_min.y, cy - pad.y)
			b_max.y = math.max(b_max.y, cy + pad.y)
			b_min.z = math.min(b_min.z, cz - pad.z)
			b_max.z = math.max(b_max.z, cz + pad.z)
		}
	}

	canonical_size = {
		math.clamp(b_max.x - b_min.x, 0.025, 0.25),
		math.clamp(b_max.y - b_min.y, 0.060, 0.30),
		math.clamp(b_max.z - b_min.z, 0.050, 0.28),
	}
	canonical_center = (b_min + b_max) * 0.5
	return
}

@(private = "file")
_update_hand_box_collider :: proc(
	calib: ^Hand_Calibrated_Bones,
	side: ^Hand_Side_State,
	mode: Hand_Collider_Mode,
) {
	w := engine.ctx_world()
	if w == nil || calib.hand_bone == {} do return

	// Ensure a BoxCollider exists on the hand bone (replaces legacy static SphereCollider if present)
	if _, sph := engine.transform_get_comp(calib.hand_bone, physics3d.SphereCollider); sph != nil {
		engine.transform_destroy_comp(calib.hand_bone, physics3d.SphereCollider)
	}
	_, box := engine.transform_get_comp(calib.hand_bone, physics3d.BoxCollider)
	if box == nil {
		_, raw := engine.transform_add_comp(calib.hand_bone, .BoxCollider)
		box = cast(^physics3d.BoxCollider)raw
		if box != nil {
			box.rotation = {0, 0, 0, 1}
			box.density  = 1.0
			box.friction = 0.7
		}
	}
	if box == nil do return

	can_size   := side.pose.collider_size
	can_center := side.pose.collider_center

	switch mode {
	case .Auto_From_Fingers:
		can_size, can_center = hand_pose_compute_auto_box(calib)
		side.pose.collider_size   = can_size
		side.pose.collider_center = can_center

	case .Pose_And_Auto:
		// If user is in Custom mode (e.g. dragging Master Curl or individual fingers),
		// auto-fit from fingers; when using a preset or blending between presets, use the preset/blended box!
		if side.preset == .Custom && !side.is_blending {
			can_size, can_center = hand_pose_compute_auto_box(calib)
			side.pose.collider_size   = can_size
			side.pose.collider_center = can_center
		} else if can_size.x < 0.01 || can_size.y < 0.01 || can_size.z < 0.01 {
			can_size, can_center = hand_pose_compute_auto_box(calib)
			side.pose.collider_size   = can_size
			side.pose.collider_center = can_center
		}

	case .Custom_Pose_Box:
		if can_size.x < 0.01 || can_size.y < 0.01 || can_size.z < 0.01 {
			can_size   = {0.052, 0.175, 0.105}
			can_center = {0.012, 0.088, 0.004}
			side.pose.collider_size   = can_size
			side.pose.collider_center = can_center
		}

	case .Disabled:
		return
	}

	// Map canonical (Palmar, Distal, Radial) center & size into hand_bone's actual local axes!
	// This guarantees that even if hand_r has -X as palm_inward and hand_l has +X as palm_inward,
	// the BoxCollider center is automatically placed on the palm side of BOTH hands!
	local_center := calib.palm_inward_local * can_center.x +
	                calib.distal_local      * can_center.y +
	                calib.radial_local      * can_center.z

	local_size := [3]f32{
		abs(calib.palm_inward_local.x) * can_size.x + abs(calib.distal_local.x) * can_size.y + abs(calib.radial_local.x) * can_size.z,
		abs(calib.palm_inward_local.y) * can_size.x + abs(calib.distal_local.y) * can_size.y + abs(calib.radial_local.y) * can_size.z,
		abs(calib.palm_inward_local.z) * can_size.x + abs(calib.distal_local.z) * can_size.y + abs(calib.radial_local.z) * can_size.z,
	}

	box.size   = local_size
	box.center = local_center
}

// Evaluates a single HandPoseDriver immediately (called by tick and by editor sliders)
hand_pose_driver_evaluate :: proc(driver: ^HandPoseDriver, dt: f32 = 0.0) {
	if driver == nil || !driver.enabled || !driver.active || driver.weight <= 0.001 do return
	if !hand_pose_driver_ensure_bound(driver) do return

	// Advance runtime blends if active
	if dt > 0.0 {
		if driver.left.is_blending {
			driver.left.blend_time += dt
			t := math.clamp(driver.left.blend_time / math.max(driver.left.blend_duration, 0.001), 0.0, 1.0)
			driver.left.pose = hand_pose_profile_lerp(driver.left.blend_start, driver.left.blend_target, t)
			if t >= 1.0 do driver.left.is_blending = false
		}
		if driver.right.is_blending {
			driver.right.blend_time += dt
			t := math.clamp(driver.right.blend_time / math.max(driver.right.blend_duration, 0.001), 0.0, 1.0)
			driver.right.pose = hand_pose_profile_lerp(driver.right.blend_start, driver.right.blend_target, t)
			if t >= 1.0 do driver.right.is_blending = false
		}
	}

	if driver.mirror_hands {
		driver.right.preset        = driver.left.preset
		driver.right.master_curl   = driver.left.master_curl
		driver.right.master_claw   = driver.left.master_claw
		driver.right.master_spread = driver.left.master_spread
		driver.right.pose          = driver.left.pose
	}

	_solve_single_hand(&driver.left_calib, &driver.left, driver.weight, driver.collider_mode)
	_solve_single_hand(&driver.right_calib, &driver.right, driver.weight, driver.collider_mode)

	if _, adm := engine.transform_get_comp(driver.owner, ArmatureDeformedMesh); adm != nil {
		adm.posed_frame = 0
	}
}

@(update={order=4})
hand_pose_driver_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(hand_pose_drivers(w))
	for driver, _ in engine.pool_next(&it) {
		hand_pose_driver_evaluate(driver, dt)
	}
}

// =============================================================================
// ODIN FLAT BINARY HAND POSE LIBRARY (plugins/control_rig/assets/hand_poses/*.mhpose)
// =============================================================================
// Zero-allocation, zero-reflection, fixed-layout binary struct serialization.
// Odin writes and reads the entire Hand_Pose_Binary_Record in a single memory block!

HAND_POSES_DIR          :: "plugins/control_rig/assets/hand_poses"
HAND_POSE_BINARY_EXT    :: ".mhpose"
HAND_POSE_BINARY_MAGIC  :: [4]u8{'M', 'H', 'H', 'P'}
HAND_POSE_BINARY_VER    :: u32(1)

Hand_Pose_Binary_Record :: struct #packed {
	magic:           [4]u8,
	version:         u32,
	name_len:        u32,
	name_buf:        [64]u8,
	thumb_pos_2d:    [2]f32,
	thumb_sweep:     f32,
	thumb_roll:      f32,
	thumb_mid_curl:  f32,
	thumb_tip_curl:  f32,
	index_finger:    [4]f32,
	middle_finger:   [4]f32,
	ring_finger:     [4]f32,
	pinky_finger:    [4]f32,
	collider_size:   [3]f32,
	collider_center: [3]f32,
}

Hand_Pose_Folder_Entry :: struct {
	display_name: string,
	filename:     string,
	full_path:    string,
	profile:      Hand_Pose_Profile,
}

@(private = "file")
_ensure_dir_recursive :: proc(dir_path: string) {
	if len(dir_path) == 0 || os.is_dir(dir_path) do return
	parts := strings.split(dir_path, "/", context.temp_allocator)
	cur := ""
	for p, i in parts {
		if len(p) == 0 do continue
		cur = p if i == 0 else fmt.tprintf("%s/%s", cur, p)
		if !os.is_dir(cur) {
			_ = os.make_directory(cur)
		}
	}
}

// Seeds the 8 default hand poses into `dir_path` as fast binary .mhpose files.
// When `force_overwrite` is false, only missing files are written so user adjustments are preserved!
hand_pose_seed_default_folder :: proc(dir_path: string = HAND_POSES_DIR, force_overwrite: bool = false) {
	_ensure_dir_recursive(dir_path)

	presets := [8]Hand_Pose_Preset{
		.Relaxed,
		.Fist,
		.Open_Palm,
		.Point_Trigger,
		.Pistol_Grip,
		.Rifle_Grip,
		.Claw_Grip,
		.Lightning_Cast,
	}

	for p in presets {
		fname := hand_pose_preset_filename(p)
		if len(fname) == 0 do continue
		full_path := fmt.tprintf("%s/%s", dir_path, fname)
		if force_overwrite || !os.exists(full_path) {
			prof := hand_pose_builtin_fallback_get(p)
			_ = hand_pose_profile_save_to_folder(prof, fname, dir_path)
		}
	}
}

// Dynamically scans `dir_path` for all .mhpose binary files and returns them in sorted order.
// Automatically seeds the default 8 files on first run if the folder is empty.
hand_pose_scan_folder :: proc(dir_path: string = HAND_POSES_DIR, allocator := context.temp_allocator) -> [dynamic]Hand_Pose_Folder_Entry {
	entries := make([dynamic]Hand_Pose_Folder_Entry, allocator)
	if len(dir_path) == 0 do return entries

	if !engine.vfs_is_mounted() && !os.is_dir(dir_path) {
		hand_pose_seed_default_folder(dir_path, false)
	}

	_scan_into :: proc(dir_path: string, entries: ^[dynamic]Hand_Pose_Folder_Entry, allocator: mem.Allocator) {
		dir_h, oerr := os.open(dir_path)
		if oerr != nil do return
		defer os.close(dir_h)

		infos, rerr := os.read_dir(dir_h, -1, context.temp_allocator)
		if rerr != nil do return
		defer os.file_info_slice_delete(infos, context.temp_allocator)

		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
			return a.name < b.name
		})

		for fi in infos {
			if strings.has_suffix(fi.name, HAND_POSE_BINARY_EXT) {
				full_p := fmt.tprintf("%s/%s", dir_path, fi.name)
				if prof, ok := hand_pose_profile_load_from_disk(full_p); ok {
					disp := fi.name[:len(fi.name) - len(HAND_POSE_BINARY_EXT)]
					if len(prof.name) == 0 do prof.name = disp
					append(entries, Hand_Pose_Folder_Entry{
						display_name = strings.clone(disp, allocator),
						filename     = strings.clone(fi.name, allocator),
						full_path    = strings.clone(full_p, allocator),
						profile      = prof,
					})
				}
			}
		}
	}

	_scan_into(dir_path, &entries, allocator)
	if len(entries) == 0 && !engine.vfs_is_mounted() {
		hand_pose_seed_default_folder(dir_path, false)
		_scan_into(dir_path, &entries, allocator)
	}

	return entries
}

// Writes `profile` directly as a 188-byte packed binary struct (.mhpose) with zero heap allocations!
hand_pose_profile_save_to_folder :: proc(profile: Hand_Pose_Profile, filename: string, dir_path: string = HAND_POSES_DIR) -> bool {
	if len(filename) == 0 || len(dir_path) == 0 do return false
	_ensure_dir_recursive(dir_path)

	clean_name := strings.trim_space(filename)
	if !strings.has_suffix(clean_name, HAND_POSE_BINARY_EXT) {
		clean_name = fmt.tprintf("%s%s", clean_name, HAND_POSE_BINARY_EXT)
	}
	full_path := fmt.tprintf("%s/%s", dir_path, clean_name)

	disp_name := profile.name
	if len(disp_name) == 0 {
		disp_name = clean_name[:len(clean_name) - len(HAND_POSE_BINARY_EXT)]
	}

	rec := Hand_Pose_Binary_Record{
		magic           = HAND_POSE_BINARY_MAGIC,
		version         = HAND_POSE_BINARY_VER,
		thumb_pos_2d    = profile.thumb_pos_2d,
		thumb_sweep     = profile.thumb_sweep,
		thumb_roll      = profile.thumb_roll,
		thumb_mid_curl  = profile.thumb_mid_curl,
		thumb_tip_curl  = profile.thumb_tip_curl,
		index_finger    = profile.index_finger,
		middle_finger   = profile.middle_finger,
		ring_finger     = profile.ring_finger,
		pinky_finger    = profile.pinky_finger,
		collider_size   = profile.collider_size,
		collider_center = profile.collider_center,
	}

	nlen := min(len(disp_name), len(rec.name_buf) - 1)
	rec.name_len = u32(nlen)
	if nlen > 0 {
		copy(rec.name_buf[:nlen], transmute([]u8)disp_name[:nlen])
	}

	return os.write_entire_file(full_path, mem.ptr_to_bytes(&rec)) == nil
}

hand_pose_profile_save_to_disk :: proc(profile: Hand_Pose_Profile, filename: string) -> bool {
	return hand_pose_profile_save_to_folder(profile, filename, HAND_POSES_DIR)
}

// Reads a 188-byte .mhpose binary file directly into a Hand_Pose_Profile by pointer cast!
hand_pose_profile_load_from_disk :: proc(full_path: string) -> (Hand_Pose_Profile, bool) {
	data, rerr := engine.vfs_read_entire_file(full_path, context.temp_allocator)
	if rerr != nil do return {}, false
	if len(data) < size_of(Hand_Pose_Binary_Record) do return {}, false

	rec := (^Hand_Pose_Binary_Record)(raw_data(data))
	if rec.magic != HAND_POSE_BINARY_MAGIC || rec.version != HAND_POSE_BINARY_VER {
		return {}, false
	}

	nlen := min(int(rec.name_len), len(rec.name_buf) - 1)
	name_str := strings.clone(string(rec.name_buf[:nlen]), context.temp_allocator) if nlen > 0 else ""

	return Hand_Pose_Profile{
		name            = name_str,
		thumb_pos_2d    = rec.thumb_pos_2d,
		thumb_sweep     = rec.thumb_sweep,
		thumb_roll      = rec.thumb_roll,
		thumb_mid_curl  = rec.thumb_mid_curl,
		thumb_tip_curl  = rec.thumb_tip_curl,
		index_finger    = rec.index_finger,
		middle_finger   = rec.middle_finger,
		ring_finger     = rec.ring_finger,
		pinky_finger    = rec.pinky_finger,
		collider_size   = rec.collider_size,
		collider_center = rec.collider_center,
	}, true
}

hand_pose_delete_from_disk :: proc(full_path: string) -> bool {
	if len(full_path) == 0 || !os.exists(full_path) do return false
	return os.remove(full_path) == nil
}
