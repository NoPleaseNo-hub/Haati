package control_rig

import engine "moonhug:engine"

// Skeleton & Bone Display project settings.
// Exposed in Edit -> Project Settings.
// Provides global visualization parameters for skeletal meshes, bone wireframes, and viewport picking.

@(phase={key=SerializationInit, order=10})
_register_control_rig_settings_types :: proc() {
	engine.register_pointer_type(Bone_Solid_Shape)
	engine.register_pointer_type(Skeleton_Settings)
	engine.register_pointer_type(Control_Shape_Type)
}

Bone_Solid_Shape :: enum {
	Cylinder,  // Uniform round cylinder (Blender/Unreal style, does not balloon with length or distance)
	Capsule,   // Smooth rounded capsule
	Box,       // Uniform rectangular bar/prism
	Stick,     // Slender solid rod (Blender stick mode)
	Diamond,   // Classic tapered octahedral diamond
}

Skeleton_Settings :: struct {
	bone_solid_shape:          Bone_Solid_Shape,                 // 3D solid bone geometry shape (Cylinder, Capsule, Box, Stick, Diamond)
	bone_thickness:            f32    `decor:range(0.1, 5.0)`,   // Visual width multiplier for bones
	bone_line_thickness:       f32    `decor:range(1.0, 10.0)`,  // Line thickness multiplier for wireframe bones
	joint_radius:              f32    `decor:range(0.005, 0.1)`, // Radius of joint spheres drawn at bone pivots
	bone_pick_radius:          f32    `decor:range(0.01, 0.2)`,  // Viewport raycast hit detection threshold for bone selection
	show_bone_labels:          bool,                             // Whether text labels (e.g. "Head", "Spine") appear on bones
	bone_label_scale:          f32    `decor:range(0.2, 5.0)`,   // Scale factor for bone text labels
	draw_diamond_bones:        bool,                             // If false, falls back to raw 1px wire lines; if true, draws selected bone_solid_shape
	draw_solid_bones:          bool,                             // If true, renders 3D shaded volume faces for bones (Unreal / Blender style)
	solid_bone_alpha:          f32    `decor:range(0.05, 1.0)`,  // Transparency for solid 3D bone volume faces
	bone_color_default:        [4]f32 `decor:color()`,           // Unselected bone wireframe color
	bone_color_selected:       [4]f32 `decor:color()`,           // Selected active bone highlight color
	bone_color_ambient:        [4]f32 `decor:color()`,           // Ambient/ghost bone color when actor is unselected
	bone_joint_color:          [4]f32 `decor:color()`,           // Joint sphere color
	bone_label_color:          [4]f32 `decor:color()`,           // Unselected bone label text color
	bone_label_color_selected: [4]f32 `decor:color()`,           // Selected active bone label text color
	dim_inactive_bones_in_paint_mode: bool,                      // Dim unselected bones while painting weights so they don't block the mesh
	inactive_bones_paint_alpha:       f32 `decor:range(0.0, 0.5)`, // Faded alpha transparency for unselected bones during weight painting
}

@(project_settings={name="Skeleton & Bones"})
skeleton_settings := Skeleton_Settings{
	bone_solid_shape          = .Cylinder,
	bone_thickness            = 1.0,
	bone_line_thickness       = 1.5,
	joint_radius              = 0.015,
	bone_pick_radius          = 0.04,
	show_bone_labels          = false,
	bone_label_scale          = 1.0,
	draw_diamond_bones        = true,
	draw_solid_bones          = true,
	solid_bone_alpha          = 0.35,
	bone_color_default        = {0.22, 0.78, 1.00, 0.85},   // Unreal ice-blue wire
	bone_color_selected       = {1.00, 0.85, 0.20, 1.00},   // Radiant gold for selected bone
	bone_color_ambient        = {0.25, 0.65, 0.85, 0.35},   // Subtle ghost overlay
	bone_joint_color          = {0.30, 0.88, 1.00, 0.90},   // Cyan joint sphere
	bone_label_color          = {0.90, 0.90, 0.95, 1.00},   // Crisp silver-white text
	bone_label_color_selected = {1.00, 0.88, 0.25, 1.00},   // Radiant gold selected text
	dim_inactive_bones_in_paint_mode = true,
	inactive_bones_paint_alpha       = 0.15,
}
