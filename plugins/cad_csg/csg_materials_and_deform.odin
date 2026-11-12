package cad_csg

// ============================================================================
// PHYSICAL & DESTRUCTIBLE MATERIAL PROPERTIES DATATABLE,
// GODOT-STYLE PROCEDURAL TEXTURE & MATERIAL GENERATOR,
// AND SOFT DEFORMER COORDINATE-OFFSET PIPELINE (`p' = p + Δp(x, t)`)
// ============================================================================
//
// 1. Physical & Destructible Material Properties DataTable (`CSG_Material_Property_Row`):
//    - Defines how each material (`Concrete`, `Reinforced_Concrete`, `Brick_Masonry`,
//      `Tempered_Glass`, `Reinforced_Glass`, `Sheet_Ice`, `Wood_Plank`, `Steel_Plate`,
//      `Soft_Metal_Panel`, `Soft_Rubber_Gel`) breaks or deforms:
//      • `yield_blast_force`: minimum force/impulse required before boolean fracture occurs.
//      • `crater_radius_scale`: how large a crater a given force carves once yield is exceeded.
//      • `fracture_pattern`: Voronoi chunks, concentric spiderweb, crystalline shards, rebar cracks,
//        wired local hole, or plastic denting.
//      • `cascade_shatter_ratio`: fraction of broken glass/ice cells that triggers full-pane shatter.
//      • `deform_stiffness`, `deform_max_depth`, `elastic_recovery_rate`, `plastic_dent_ratio`:
//        govern soft-body vertex/texture coordinate-offset deformation (`p' = p + Δp`).
//
// 2. Godot-Style Procedural Texture & Material Generator (`CSG_Proc_Texture_Params`):
//    - Generates tileable RGBA8 GPU textures (`Glass_Frosted_Streaks`, `Glass_Wired_Reinforced`,
//      `Sheet_Ice_Crystalline`, `Concrete_Pitted`, `Brick_Masonry`, `Brushed_Metal_Panel`,
//      `Voronoi_Cracks`, `Gradient_Ramp_2D`, `UV_Checker_Grid`) and exports `.png` + `.mat` assets.
//
// 3. Soft Deformer Bodies via Coordinate-Offset Texture & Field Math (`CSG_Soft_Deform_Stamp`):
//    - Simulates soft/plastic/elastic mesh & surface deformation via vertex coordinate offsets
//      `p' = p + Δp(x, t)` and a 2D UV Deformation Offset Texture (`RGBA8` encoding `(Δx, Δy, Δz, strain)`)
//      while the underlying Jolt CSG collision bodies stay 100% unchanged!

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"
import engine "moonhug:engine"
import gfx "moonhug:engine/gfx"

// ============================================================================
// 1. PHYSICAL & DESTRUCTIBLE MATERIAL PROPERTIES DATATABLE
// ============================================================================

CSG_Material_Property_Row :: struct {
	preset:                CSG_Material_Preset,
	name:                  string,
	yield_blast_force:     f32, // Minimum blast impulse required before boolean fracture occurs
	tensile_strength_mpa:  f32, // Tensile strength in MPa (informational & structural scaling)
	crater_radius_scale:   f32, // Multiplier on crater/shatter radius once yield force is exceeded
	fracture_pattern:      CSG_Fracture_Pattern,
	blast_jaggedness:      f32, // 0.05 = clean cut, 0.25 = jagged Voronoi/splinter cleavage
	cascade_shatter_ratio: f32, // For 2D glass/ice panes: fraction of broken cells that triggers full cascade
	density_kg_m3:         f32,
	friction:              f32,
	restitution:           f32,
	opacity:               f32, // 0.0..1.0 (e.g. 0.26 for Tempered Glass, 0.36 for Reinforced Glass, 1.0 for solid)
	specular_sheen:        f32, // 0.0..1.0 (diagonal specular glint intensity on glass/ice/metal)
	base_color:            [4]u8,
	scorch_color:          [4]u8,

	// Soft Deformer Body / Coordinate-Offset Deformation Parameters
	deform_enabled:        bool,
	deform_stiffness:      f32, // Hooke spring stiffness k (higher = stiffer resistance & faster oscillation)
	deform_max_depth:      f32, // Maximum coordinate offset magnitude ||Δp|| in meters
	elastic_recovery_rate: f32, // Damping / elastic recovery speed (1/s)
	plastic_dent_ratio:    f32, // 0.0 = 100% elastic bounce-back (rubber/gel), 0.80 = 80% permanent plastic dent (metal)
}

@(private = "package")
_mat_table_initialized: bool

csg_material_datatable: [CSG_Material_Preset]CSG_Material_Property_Row

csg_init_material_datatable :: proc() {
	if _mat_table_initialized do return
	_mat_table_initialized = true
	csg_reset_material_datatable_defaults()
}

csg_reset_material_datatable_defaults :: proc() {
	_mat_table_initialized = true

	csg_material_datatable[.Concrete] = CSG_Material_Property_Row{
		preset                = .Concrete,
		name                  = "Concrete (Standard)",
		yield_blast_force     = 4.0,
		tensile_strength_mpa  = 3.5,
		crater_radius_scale   = 1.00,
		fracture_pattern      = .Voronoi_Chunks,
		blast_jaggedness      = 0.16,
		cascade_shatter_ratio = 0.85,
		density_kg_m3         = 2400.0,
		friction              = 0.80,
		restitution           = 0.12,
		opacity               = 1.0,
		specular_sheen        = 0.10,
		base_color            = {192, 196, 202, 255},
		scorch_color          = {88, 82, 76, 255},
		deform_enabled        = false,
		deform_stiffness      = 25.0,
		deform_max_depth      = 0.12,
		elastic_recovery_rate = 4.0,
		plastic_dent_ratio    = 0.90,
	}

	csg_material_datatable[.Reinforced_Concrete] = CSG_Material_Property_Row{
		preset                = .Reinforced_Concrete,
		name                  = "Reinforced Concrete (Rebar)",
		yield_blast_force     = 11.0,
		tensile_strength_mpa  = 18.0,
		crater_radius_scale   = 0.52,
		fracture_pattern      = .Rebar_Held_Cracks,
		blast_jaggedness      = 0.09,
		cascade_shatter_ratio = 0.95,
		density_kg_m3         = 2550.0,
		friction              = 0.85,
		restitution           = 0.08,
		opacity               = 1.0,
		specular_sheen        = 0.15,
		base_color            = {156, 162, 170, 255},
		scorch_color          = {68, 66, 64, 255},
		deform_enabled        = true,
		deform_stiffness      = 30.0,
		deform_max_depth      = 0.18,
		elastic_recovery_rate = 5.0,
		plastic_dent_ratio    = 0.85,
	}

	csg_material_datatable[.Brick_Masonry] = CSG_Material_Property_Row{
		preset                = .Brick_Masonry,
		name                  = "Brick Masonry",
		yield_blast_force     = 2.6,
		tensile_strength_mpa  = 2.2,
		crater_radius_scale   = 1.22,
		fracture_pattern      = .Block_Masonry,
		blast_jaggedness      = 0.22,
		cascade_shatter_ratio = 0.78,
		density_kg_m3         = 1920.0,
		friction              = 0.82,
		restitution           = 0.10,
		opacity               = 1.0,
		specular_sheen        = 0.08,
		base_color            = {186, 102, 82, 255},
		scorch_color          = {96, 56, 46, 255},
		deform_enabled        = false,
		deform_stiffness      = 22.0,
		deform_max_depth      = 0.10,
		elastic_recovery_rate = 4.0,
		plastic_dent_ratio    = 0.95,
	}

	csg_material_datatable[.Tempered_Glass] = CSG_Material_Property_Row{
		preset                = .Tempered_Glass,
		name                  = "Tempered Glass (See-Through)",
		yield_blast_force     = 0.8,
		tensile_strength_mpa  = 1.2,
		crater_radius_scale   = 1.45,
		fracture_pattern      = .Concentric_Spiderweb,
		blast_jaggedness      = 0.24,
		cascade_shatter_ratio = 0.62,
		density_kg_m3         = 2500.0,
		friction              = 0.20,
		restitution           = 0.35,
		opacity               = 0.27, // 27% opacity -> genuinely see-through while visible as glass!
		specular_sheen        = 0.92,
		base_color            = {165, 232, 250, 70},
		scorch_color          = {220, 248, 255, 210},
		deform_enabled        = true,
		deform_stiffness      = 18.0,
		deform_max_depth      = 0.08,
		elastic_recovery_rate = 8.0,
		plastic_dent_ratio    = 0.05,
	}

	csg_material_datatable[.Reinforced_Glass] = CSG_Material_Property_Row{
		preset                = .Reinforced_Glass,
		name                  = "Reinforced Wired Glass",
		yield_blast_force     = 6.5,
		tensile_strength_mpa  = 9.5,
		crater_radius_scale   = 0.50,
		fracture_pattern      = .Wired_Local_Hole,
		blast_jaggedness      = 0.12,
		cascade_shatter_ratio = 0.92, // Resists full-pane cascade: punches local holes!
		density_kg_m3         = 2650.0,
		friction              = 0.25,
		restitution           = 0.28,
		opacity               = 0.36,
		specular_sheen        = 0.82,
		base_color            = {135, 208, 218, 92},
		scorch_color          = {200, 238, 242, 220},
		deform_enabled        = true,
		deform_stiffness      = 20.0,
		deform_max_depth      = 0.22,
		elastic_recovery_rate = 4.5,
		plastic_dent_ratio    = 0.55,
	}

	csg_material_datatable[.Sheet_Ice] = CSG_Material_Property_Row{
		preset                = .Sheet_Ice,
		name                  = "Sheet Ice (Brittle Crystal)",
		yield_blast_force     = 0.45,
		tensile_strength_mpa  = 0.7,
		crater_radius_scale   = 1.75,
		fracture_pattern      = .Crystalline_Shards,
		blast_jaggedness      = 0.28,
		cascade_shatter_ratio = 0.45, // Shatters across wide crystalline cleavage planes easily!
		density_kg_m3         = 917.0,
		friction              = 0.04,
		restitution           = 0.40,
		opacity               = 0.42,
		specular_sheen        = 0.96,
		base_color            = {185, 238, 255, 108},
		scorch_color          = {235, 250, 255, 230},
		deform_enabled        = false,
		deform_stiffness      = 24.0,
		deform_max_depth      = 0.05,
		elastic_recovery_rate = 6.0,
		plastic_dent_ratio    = 0.10,
	}

	csg_material_datatable[.Wood_Plank] = CSG_Material_Property_Row{
		preset                = .Wood_Plank,
		name                  = "Wood Plank / Timber",
		yield_blast_force     = 2.0,
		tensile_strength_mpa  = 4.0,
		crater_radius_scale   = 1.30,
		fracture_pattern      = .Splinter_Slabs,
		blast_jaggedness      = 0.25,
		cascade_shatter_ratio = 0.75,
		density_kg_m3         = 680.0,
		friction              = 0.65,
		restitution           = 0.22,
		opacity               = 1.0,
		specular_sheen        = 0.18,
		base_color            = {172, 128, 84, 255},
		scorch_color          = {72, 52, 36, 255},
		deform_enabled        = true,
		deform_stiffness      = 14.0,
		deform_max_depth      = 0.25,
		elastic_recovery_rate = 5.5,
		plastic_dent_ratio    = 0.40,
	}

	csg_material_datatable[.Steel_Plate] = CSG_Material_Property_Row{
		preset                = .Steel_Plate,
		name                  = "Heavy Steel Armor Plate",
		yield_blast_force     = 22.0,
		tensile_strength_mpa  = 420.0,
		crater_radius_scale   = 0.28,
		fracture_pattern      = .Plastic_Dent_Only,
		blast_jaggedness      = 0.06,
		cascade_shatter_ratio = 0.98,
		density_kg_m3         = 7850.0,
		friction              = 0.45,
		restitution           = 0.30,
		opacity               = 1.0,
		specular_sheen        = 0.75,
		base_color            = {132, 142, 154, 255},
		scorch_color          = {62, 68, 76, 255},
		deform_enabled        = true,
		deform_stiffness      = 22.0,
		deform_max_depth      = 0.45,
		elastic_recovery_rate = 3.2,
		plastic_dent_ratio    = 0.82,
	}

	csg_material_datatable[.Soft_Metal_Panel] = CSG_Material_Property_Row{
		preset                = .Soft_Metal_Panel,
		name                  = "Soft Deformable Metal Panel",
		yield_blast_force     = 14.5,
		tensile_strength_mpa  = 145.0,
		crater_radius_scale   = 0.42,
		fracture_pattern      = .Plastic_Dent_Only,
		blast_jaggedness      = 0.10,
		cascade_shatter_ratio = 0.95,
		density_kg_m3         = 2700.0,
		friction              = 0.50,
		restitution           = 0.25,
		opacity               = 1.0,
		specular_sheen        = 0.68,
		base_color            = {164, 178, 194, 255},
		scorch_color          = {92, 102, 116, 255},
		deform_enabled        = true,
		deform_stiffness      = 12.0,
		deform_max_depth      = 0.95,
		elastic_recovery_rate = 2.4,
		plastic_dent_ratio    = 0.72,
	}

	csg_material_datatable[.Soft_Rubber_Gel] = CSG_Material_Property_Row{
		preset                = .Soft_Rubber_Gel,
		name                  = "Soft Elastic Rubber / Gel Body",
		yield_blast_force     = 19.0,
		tensile_strength_mpa  = 25.0,
		crater_radius_scale   = 0.30,
		fracture_pattern      = .Plastic_Dent_Only,
		blast_jaggedness      = 0.08,
		cascade_shatter_ratio = 0.98,
		density_kg_m3         = 1150.0,
		friction              = 0.92,
		restitution           = 0.78,
		opacity               = 1.0,
		specular_sheen        = 0.45,
		base_color            = {86, 188, 148, 255},
		scorch_color          = {54, 128, 98, 255},
		deform_enabled        = true,
		deform_stiffness      = 16.0,
		deform_max_depth      = 1.25,
		elastic_recovery_rate = 1.8,
		plastic_dent_ratio    = 0.05, // Bounces right back via spring-damper ODE!
	}
}

csg_get_material_row :: proc(preset: CSG_Material_Preset) -> CSG_Material_Property_Row {
	csg_init_material_datatable()
	p := clamp(preset, min(CSG_Material_Preset), max(CSG_Material_Preset))
	return csg_material_datatable[p]
}

csg_set_material_row :: proc(preset: CSG_Material_Preset, row: CSG_Material_Property_Row) {
	csg_init_material_datatable()
	p := clamp(preset, min(CSG_Material_Preset), max(CSG_Material_Preset))
	csg_material_datatable[p] = row
	csg_material_datatable[p].preset = p
}

// Evaluates how a material in the DataTable responds to a blast / impact of `raw_radius` and `impulse`:
// - If `impulse < row.yield_blast_force`: `should_fracture = false` (material resists boolean destruction)
//   and computes `soft_dent_depth` so deformable materials (`Soft_Metal_Panel`, `Steel_Plate`, `Soft_Rubber_Gel`,
//   `Reinforced_Concrete`) dent via the Soft Deformer Coordinate-Offset pipeline!
// - If `impulse >= row.yield_blast_force`: `should_fracture = true` and scales `effective_radius` by
//   `row.crater_radius_scale` and excess force ratio.
csg_eval_blast_against_material :: proc(
	preset:     CSG_Material_Preset,
	raw_radius: f32,
	impulse:    f32,
) -> (
	should_fracture:  bool,
	effective_radius: f32,
	jaggedness:       f32,
	scorch_color:     [4]u8,
	soft_dent_depth:  f32,
) {
	row := csg_get_material_row(preset)
	jaggedness   = clamp(row.blast_jaggedness, 0.04, 0.35)
	scorch_color = row.scorch_color

	// Compute soft-body coordinate-offset dent depth proportional to impulse / stiffness
	if row.deform_enabled {
		force_ratio := clamp(impulse / max(row.deform_stiffness, 1.0), 0.05, 1.5)
		soft_dent_depth = clamp(raw_radius * 0.35 * force_ratio, 0.02, row.deform_max_depth)
	}

	if impulse < row.yield_blast_force {
		return false, 0.0, jaggedness, scorch_color, soft_dent_depth
	}

	// Force exceeds material yield threshold: scale crater radius by `crater_radius_scale` and force overmatch
	overmatch := clamp((impulse - row.yield_blast_force * 0.45) / max(row.yield_blast_force, 1.0), 0.45, 1.75)
	effective_radius = max(raw_radius * row.crater_radius_scale * math.sqrt(overmatch), 0.06)
	return true, effective_radius, jaggedness, scorch_color, soft_dent_depth
}

// Saves the entire Material Properties DataTable to disk as human-readable JSON (`assets/materials/physical_materials_datatable.json`).
csg_save_material_datatable_json :: proc(rel_path: string = "assets/materials/physical_materials_datatable.json") -> bool {
	csg_init_material_datatable()
	_ = os.make_directory("assets")
	_ = os.make_directory("assets/materials")

	rows := make([]CSG_Material_Property_Row, len(CSG_Material_Preset), context.temp_allocator)
	for p in CSG_Material_Preset {
		rows[int(p)] = csg_material_datatable[p]
	}
	bytes, err := json.marshal(rows, {pretty = true}, context.temp_allocator)
	if err != nil do return false
	return os.write_entire_file(rel_path, bytes) == nil
}

// Loads the Material Properties DataTable from JSON on disk if present.
csg_load_material_datatable_json :: proc(rel_path: string = "assets/materials/physical_materials_datatable.json") -> bool {
	csg_init_material_datatable()
	data, err := os.read_entire_file(rel_path, context.temp_allocator)
	if err != nil || len(data) == 0 do return false

	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	rows: []CSG_Material_Property_Row
	if json.unmarshal(data, &rows, allocator = context.temp_allocator) != nil do return false
	for r in rows {
		p := clamp(r.preset, min(CSG_Material_Preset), max(CSG_Material_Preset))
		row_copy := r
		row_copy.name = strings.clone(r.name)
		csg_material_datatable[p] = row_copy
	}
	return len(rows) > 0
}

csg_get_material_properties :: csg_get_material_row
MAX_SOFT_DEFORM_STAMPS :: 64

// ============================================================================
// 2. GODOT-STYLE PROCEDURAL TEXTURE & MATERIAL GENERATOR
//    (NoiseTexture2D / GradientTexture2D / Frosted & Wired Glass / Brick / Concrete)
// ============================================================================

CSG_Proc_Texture_Pattern :: enum u8 {
	Glass_Frosted_Streaks  = 0, // See-through translucent glass with diagonal specular streaks & subtle frost
	Glass_Wired_Reinforced = 1, // Security glass with Georgian diamond wire mesh & translucent tint
	Sheet_Ice_Crystalline  = 2, // Translucent ice with Voronoi crystal facets & frost veins
	Concrete_Pitted        = 3, // Multi-octave FBM noise concrete with aggregate pits & form lines
	Brick_Masonry          = 4, // Running-bond brickwork with mortar joints & per-brick variation
	Brushed_Metal_Panel    = 5, // Anisotropic brushed steel/aluminum panel with bevel border & rivets
	Voronoi_Cracks         = 6, // Cellular Voronoi stone/fracture pattern
	Gradient_Ramp_2D       = 7, // Godot GradientTexture2D linear/radial color + alpha ramp
	UV_Checker_Grid        = 8, // High-contrast metric UV calibration grid
}

CSG_Procedural_Tex_Pattern :: CSG_Proc_Texture_Pattern

CSG_Proc_Texture_Params :: struct {
	pattern:          CSG_Proc_Texture_Pattern,
	width:            i32,
	height:           i32,
	primary_color:    [4]f32, // RGBA in [0..1] (Alpha < 1.0 produces see-through glass/ice textures!)
	secondary_color:  [4]f32, // RGBA in [0..1] (Streaks / Mortar / Veins / Secondary stop)
	scale:            f32,    // Frequency / Tiling scale (default 4.0)
	octaves:          i32,    // FBM noise octaves (1..6)
	roughness_frost:  f32,    // Noise / Frost / Grit intensity (0.0..1.0)
	line_thickness:   f32,    // Mortar / Wire / Streak / Bevel width (0.01..0.25)
	radial_gradient:  bool,   // For Gradient_Ramp_2D: false = Linear, true = Radial
	seed:             u32,
}

csg_default_proc_texture_params :: proc(pattern: CSG_Proc_Texture_Pattern = .Glass_Frosted_Streaks) -> CSG_Proc_Texture_Params {
	p := CSG_Proc_Texture_Params{
		pattern         = pattern,
		width           = 128,
		height          = 128,
		scale           = 4.0,
		octaves         = 4,
		roughness_frost = 0.25,
		line_thickness  = 0.06,
		seed            = 1337,
	}
	switch pattern {
	case .Glass_Frosted_Streaks:
		p.primary_color   = {0.62, 0.90, 0.98, 0.28} // Translucent cyan-blue glass interior
		p.secondary_color = {0.96, 0.99, 1.00, 0.88} // Crisp bright specular diagonal sheen & frame rim
		p.roughness_frost = 0.18
		p.line_thickness  = 0.05
	case .Glass_Wired_Reinforced:
		p.primary_color   = {0.50, 0.82, 0.86, 0.35}
		p.secondary_color = {0.22, 0.26, 0.30, 0.92} // Embedded steel wire mesh
		p.scale           = 6.0
		p.line_thickness  = 0.045
	case .Sheet_Ice_Crystalline:
		p.primary_color   = {0.68, 0.92, 1.00, 0.42}
		p.secondary_color = {0.95, 0.99, 1.00, 0.92}
		p.scale           = 5.0
		p.roughness_frost = 0.35
	case .Concrete_Pitted:
		p.primary_color   = {0.74, 0.76, 0.78, 1.00}
		p.secondary_color = {0.50, 0.52, 0.55, 1.00}
		p.scale           = 6.0
		p.roughness_frost = 0.45
	case .Brick_Masonry:
		p.primary_color   = {0.72, 0.36, 0.28, 1.00}
		p.secondary_color = {0.82, 0.80, 0.76, 1.00}
		p.scale           = 4.0
		p.line_thickness  = 0.07
	case .Brushed_Metal_Panel:
		p.primary_color   = {0.66, 0.71, 0.76, 1.00}
		p.secondary_color = {0.32, 0.36, 0.40, 1.00}
		p.scale           = 8.0
		p.line_thickness  = 0.04
	case .Voronoi_Cracks:
		p.primary_color   = {0.68, 0.70, 0.74, 1.00}
		p.secondary_color = {0.20, 0.22, 0.25, 1.00}
		p.scale           = 5.0
		p.line_thickness  = 0.06
	case .Gradient_Ramp_2D:
		p.primary_color   = {0.18, 0.62, 0.92, 0.85}
		p.secondary_color = {0.98, 0.88, 0.25, 0.95}
	case .UV_Checker_Grid:
		p.primary_color   = {0.86, 0.88, 0.92, 1.00}
		p.secondary_color = {0.22, 0.26, 0.32, 1.00}
		p.scale           = 8.0
	}
	return p
}

@(private = "file")
_hash2d :: #force_inline proc(ix, iy: i32, seed: u32) -> f32 {
	h := u32(ix) * 374761393 + u32(iy) * 668265263 + seed * 1442695041
	h = (h ~ (h >> 13)) * 1274126177
	h = h ~ (h >> 16)
	return f32(h & 0xFFFF) / 65535.0
}

@(private = "file")
_value_noise2d :: proc(x, y: f32, seed: u32) -> f32 {
	ix := i32(math.floor(x))
	iy := i32(math.floor(y))
	fx := x - f32(ix)
	fy := y - f32(iy)
	ux := fx * fx * (3.0 - 2.0 * fx)
	uy := fy * fy * (3.0 - 2.0 * fy)

	v00 := _hash2d(ix,     iy,     seed)
	v10 := _hash2d(ix + 1, iy,     seed)
	v01 := _hash2d(ix,     iy + 1, seed)
	v11 := _hash2d(ix + 1, iy + 1, seed)
	return linalg.lerp(linalg.lerp(v00, v10, ux), linalg.lerp(v01, v11, ux), uy)
}

@(private = "file")
_fbm_noise2d :: proc(x, y: f32, octaves: i32, seed: u32) -> f32 {
	sum:  f32 = 0.0
	amp:  f32 = 0.5
	freq: f32 = 1.0
	norm: f32 = 0.0
	oct := clamp(octaves, 1, 6)
	for i in 0 ..< oct {
		sum  += amp * _value_noise2d(x * freq, y * freq, seed + u32(i) * 1013)
		norm += amp
		freq *= 2.02
		amp  *= 0.5
	}
	return sum / max(norm, 1e-4)
}

// Voronoi F1 & edge distance (F2 - F1) for cellular ice crystals & crack patterns
@(private = "file")
_voronoi_edge2d :: proc(x, y: f32, seed: u32) -> (f1, edge_dist, cell_id: f32) {
	ix := i32(math.floor(x))
	iy := i32(math.floor(y))
	d1: f32 = 1e9
	d2: f32 = 1e9
	best_id: f32 = 0.5
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			cx := ix + i32(dx)
			cy := iy + i32(dy)
			px := f32(cx) + _hash2d(cx, cy, seed + 17)
			py := f32(cy) + _hash2d(cx, cy, seed + 53)
			dist := math.sqrt((x - px) * (x - px) + (y - py) * (y - py))
			if dist < d1 {
				d2 = d1
				d1 = dist
				best_id = _hash2d(cx, cy, seed + 99)
			} else if dist < d2 {
				d2 = dist
			}
		}
	}
	return d1, max(d2 - d1, 0.0), best_id
}

// Generates an RGBA8 pixel buffer (`width * height * 4` bytes) from `params`.
csg_generate_procedural_texture_rgba :: proc(
	params: CSG_Proc_Texture_Params,
	alloc  := context.temp_allocator,
) -> []u8 {
	w := clamp(params.width, 16, 1024)
	h := clamp(params.height, 16, 1024)
	pixels := make([]u8, int(w * h * 4), alloc)

	c1 := params.primary_color
	c2 := params.secondary_color
	scale := max(params.scale, 0.25)
	thick := clamp(params.line_thickness, 0.005, 0.45)
	frost := clamp(params.roughness_frost, 0.0, 1.0)

	for iy in 0 ..< h {
		v := (f32(iy) + 0.5) / f32(h)
		for ix in 0 ..< w {
			u := (f32(ix) + 0.5) / f32(w)
			out_col := c1

			switch params.pattern {
			case .Glass_Frosted_Streaks:
				// 1. Smooth double-glazed architectural glass reflection ribbons + secondary refracted echo streak
				diag1 := u * 0.72 + v * 0.68 // Smooth non-wrapping diagonal coordinate across [0..1.4]
				// Primary wide sky reflection band + sharp specular core
				band_main := 0.55 * math.exp(-math.pow((diag1 - 0.52) / max(thick * 2.2, 0.08), 2.0))
				core_main := 0.90 * math.exp(-math.pow((diag1 - 0.49) / max(thick * 0.55, 0.018), 2.0))
				// Secondary double-pane refracted reflection band
				band_sec  := 0.65 * math.exp(-math.pow((diag1 - 0.68) / max(thick * 0.75, 0.025), 2.0))
				band_far  := 0.38 * math.exp(-math.pow((diag1 - 1.02) / max(thick * 1.4, 0.045), 2.0))
				sheen := clamp(band_main + core_main + band_sec + band_far, 0.0, 1.0)

				// 2. Subtle vertical sky-to-ground environment gradient (cooler cyan at top, deeper sea-green at bottom)
				sky_grad := clamp(1.0 - v * 0.65, 0.0, 1.0)

				// 3. Sea-green / cyan internal cut-glass refraction glow near the perimeter [0..1]
				border_d := min(min(u, 1.0 - u), min(v, 1.0 - v))
				edge_refract := clamp(1.0 - border_d / max(thick * 1.15, 0.045), 0.0, 1.0)
				edge_refract = edge_refract * edge_refract

				// 4. Optional subtle frost only when roughness_frost > 0.25
				frost_term: f32 = 0.0
				if frost > 0.22 {
					n_val := _fbm_noise2d(u * scale * 3.0, v * scale * 3.0, params.octaves, params.seed)
					frost_term = (n_val - 0.5) * (frost - 0.20) * 0.35
				}

				sea_green := [3]f32{0.22, 0.88, 0.82}
				base_rgb  := linalg.lerp(c1.rgb, sea_green, edge_refract * 0.55 + (1.0 - sky_grad) * 0.18)
				mix_t     := clamp(sheen * 0.82 + edge_refract * 0.38 + frost_term, 0.0, 1.0)
				out_col.rgb = linalg.clamp(linalg.lerp(base_rgb, c2.rgb, mix_t), [3]f32{0, 0, 0}, [3]f32{1, 1, 1})
				// Crystal-clear see-through interior (`c1.a ~ 0.22..0.30`), while specular streaks & refractive rim glint!
				out_col.a   = clamp(c1.a + sheen * 0.52 + edge_refract * 0.42 + abs(frost_term) * 0.15, 0.10, 0.94)

			case .Glass_Wired_Reinforced:
				// Georgian diamond wire mesh embedded inside translucent security glass
				du := math.abs(math.mod((u + v) * scale, 1.0) - 0.5)
				dv := math.abs(math.mod((u - v + 10.0) * scale, 1.0) - 0.5)
				wire_d := min(du, dv)
				is_wire := clamp(1.0 - wire_d / max(thick, 0.02), 0.0, 1.0)

				diag := math.mod(u + v * 0.8, 1.0)
				glint := 0.45 * math.exp(-math.pow((diag - 0.38) / 0.05, 2.0))
				out_col.rgb = linalg.lerp(c1.rgb + [3]f32{glint, glint, glint}, c2.rgb, is_wire)
				out_col.a   = clamp(linalg.lerp(c1.a + glint * 0.35, c2.a, is_wire), 0.12, 0.98)

			case .Sheet_Ice_Crystalline:
				_, edge_d, cell_v := _voronoi_edge2d(u * scale, v * scale, params.seed)
				vein := clamp(1.0 - edge_d / max(thick * 1.4, 0.03), 0.0, 1.0)
				n_val := _fbm_noise2d(u * scale * 2.5, v * scale * 2.5, params.octaves, params.seed + 7)
				facet_tint := (cell_v - 0.5) * 0.18 + (n_val - 0.5) * frost * 0.30
				out_col.rgb = linalg.clamp(linalg.lerp(c1.rgb + [3]f32{facet_tint, facet_tint, facet_tint}, c2.rgb, vein), [3]f32{0, 0, 0}, [3]f32{1, 1, 1})
				out_col.a   = clamp(c1.a + vein * 0.42 + facet_tint * 0.25, 0.15, 0.95)

			case .Concrete_Pitted:
				n_base := _fbm_noise2d(u * scale, v * scale, params.octaves, params.seed)
				n_fine := _value_noise2d(u * scale * 6.0, v * scale * 6.0, params.seed + 31)
				pit := f32(0.0)
				if n_fine < 0.16 {
					pit = (0.16 - n_fine) * 3.5 * frost
				}
				t_val := clamp((n_base - 0.5) * frost * 1.6 + 0.5 - pit, 0.0, 1.0)
				out_col = linalg.lerp(c2, c1, t_val)

			case .Brick_Masonry:
				rows_y := v * scale * 2.0
				row_i  := i32(math.floor(rows_y))
				brick_v := rows_y - f32(row_i)
				offset_u := f32(row_i & 1) * 0.5
				cols_x := u * scale + offset_u
				col_i  := i32(math.floor(cols_x))
				brick_u := cols_x - f32(col_i)

				mortar_u := min(brick_u, 1.0 - brick_u)
				mortar_v := min(brick_v, 1.0 - brick_v) * 0.5
				in_mortar := (mortar_u < thick * 0.5) || (mortar_v < thick * 0.5)
				if in_mortar {
					out_col = c2
				} else {
					b_var := (_hash2d(col_i, row_i, params.seed) - 0.5) * 0.22
					grit  := (_fbm_noise2d(u * scale * 3.0, v * scale * 3.0, 3, params.seed) - 0.5) * frost * 0.35
					delta_b := b_var + grit
					out_col.rgb = linalg.clamp(c1.rgb + [3]f32{delta_b, delta_b, delta_b}, [3]f32{0, 0, 0}, [3]f32{1, 1, 1})
					out_col.a   = c1.a
				}

			case .Brushed_Metal_Panel:
				// Horizontal high-frequency anisotropic brush streaks + panel bevel border
				aniso := _fbm_noise2d(u * scale * 0.5, v * scale * 18.0, 3, params.seed)
				spec  := 0.18 * math.sin((u + v * 0.35) * math.PI * 2.0)
				border_d := min(min(u, 1.0 - u), min(v, 1.0 - v))
				is_seam := border_d < thick * 0.45
				if is_seam {
					out_col = c2
				} else {
					delta := (aniso - 0.5) * frost * 0.45 + spec
					out_col.rgb = linalg.clamp(c1.rgb + [3]f32{delta, delta, delta}, [3]f32{0, 0, 0}, [3]f32{1, 1, 1})
					out_col.a   = c1.a
				}

			case .Voronoi_Cracks:
				_, edge_d, cell_v := _voronoi_edge2d(u * scale, v * scale, params.seed)
				crack := clamp(1.0 - edge_d / max(thick, 0.015), 0.0, 1.0)
				shade := (cell_v - 0.5) * frost * 0.35
				out_col = linalg.lerp(c1 + [4]f32{shade, shade, shade, 0}, c2, crack)

			case .Gradient_Ramp_2D:
				t_g := u
				if params.radial_gradient {
					du := u - 0.5
					dv := v - 0.5
					t_g = clamp(math.sqrt(du * du + dv * dv) * 2.0, 0.0, 1.0)
				}
				out_col = linalg.lerp(c1, c2, t_g)

			case .UV_Checker_Grid:
				cx := i32(math.floor(u * scale))
				cy := i32(math.floor(v * scale))
				is_even := ((cx + cy) & 1) == 0
				out_col = c1 if is_even else c2
			}

			base := (iy * w + ix) * 4
			pixels[base + 0] = u8(clamp(out_col.r * 255.0, 0.0, 255.0))
			pixels[base + 1] = u8(clamp(out_col.g * 255.0, 0.0, 255.0))
			pixels[base + 2] = u8(clamp(out_col.b * 255.0, 0.0, 255.0))
			pixels[base + 3] = u8(clamp(out_col.a * 255.0, 0.0, 255.0))
		}
	}
	return pixels
}

// Deterministic Asset_GUIDs for the built-in See-Through Glass Texture & Material.
// Note: `csg_glass_material_guid` starts with `0xFF, 0xFF, ...` so its `u128` sort key in `render_execute`
// is strictly greater than all opaque meshes (`ak == 0` or standard UUIDs), guaranteeing that transparent
// glass panes are ALWAYS rendered AFTER all opaque CSG chunks and scene objects behind them!
csg_glass_texture_guid :: #force_inline proc() -> engine.Asset_GUID {
	raw: [16]u8 = {0x47, 0x4C, 0x41, 0x53, 0x53, 0x5F, 0x54, 0x45, 0x58, 0x5F, 0x30, 0x31, 0x01, 0x02, 0x03, 0x04}
	return transmute(engine.Asset_GUID)raw
}

csg_glass_material_guid :: #force_inline proc() -> engine.Asset_GUID {
	raw: [16]u8 = {0xFF, 0xFF, 0x47, 0x4C, 0x41, 0x53, 0x53, 0x5F, 0x4D, 0x41, 0x54, 0x5F, 0x30, 0x31, 0xFF, 0xFF}
	return transmute(engine.Asset_GUID)raw
}

@(private = "file")
_glass_mat_uploaded: bool

// Ensures the built-in See-Through Glass procedural texture and material exist in `engine.texture_cache`
// and `engine.material_cache`.
csg_ensure_glass_material_ready :: proc(
	pattern:   CSG_Proc_Texture_Pattern = .Glass_Frosted_Streaks,
	col_a:     [4]f32 = {0.72, 0.95, 0.98, 0.58},
	col_b:     [4]f32 = {1.00, 1.00, 1.00, 1.00},
	scale:     f32 = 4.0,
	roughness: f32 = 0.10,
	force_refresh: bool = false,
) -> engine.Asset_GUID {
	mat_guid := csg_glass_material_guid()
	tex_guid := csg_glass_texture_guid()
	if (!_glass_mat_uploaded || force_refresh) && gfx.device() != nil {
		// Use a bright white/cyan sheen texture so per-vertex `gp.color.a` controls the exact translucency
		// of each glass preset (`Tempered_Glass`, `Reinforced_Glass`, `Sheet_Ice`) while adding crisp
		// diagonal reflection streaks and frame bevels!
		params := csg_default_proc_texture_params(pattern)
		params.width           = 128
		params.height          = 128
		params.primary_color   = col_a
		params.secondary_color = col_b
		params.scale           = scale
		params.roughness_frost = roughness
		params.line_thickness  = 0.055
		pixels := csg_generate_procedural_texture_rgba(params, context.temp_allocator)
		if _, ok := engine.texture_upsert_procedural(tex_guid, pixels, params.width, params.height); ok {
			_glass_mat_uploaded = true
		}
	}
	mat := engine.Material{
		shader  = .Unlit,
		texture = tex_guid if _glass_mat_uploaded else {},
		color   = {1.0, 1.0, 1.0, 1.0},
	}
	engine.material_preview(mat_guid, mat)
	return mat_guid
}

@(private = "file")
_png_write_cb :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	buf := cast(^[dynamic]u8)ctx
	context = runtime.default_context()
	slice_bytes := ([^]u8)(data)[:int(size)]
	append(buf, ..slice_bytes)
}

// Writes an RGBA8 pixel buffer to disk as a `.png` file and paired `.mat` file under `assets/textures/` & `assets/materials/`,
// refreshes `asset_db_refresh()`, and upserts both into the runtime caches!
csg_export_procedural_texture_and_material :: proc(
	asset_name: string,
	params:     CSG_Proc_Texture_Params,
	unlit:      bool = false,
) -> (
	tex_guid: engine.Asset_GUID,
	mat_guid: engine.Asset_GUID,
	status:   string,
	ok:       bool,
) {
	clean_name := strings.trim_space(asset_name)
	if len(clean_name) == 0 do clean_name = "Proc_Texture"

	_ = os.make_directory("assets")
	_ = os.make_directory("assets/textures")
	_ = os.make_directory("assets/materials")

	rel_png := fmt.tprintf("assets/textures/%s.png", clean_name)
	rel_mat := fmt.tprintf("assets/materials/%s.mat", clean_name)
	full_png := rel_png
	full_mat := rel_mat

	w := clamp(params.width, 16, 1024)
	h := clamp(params.height, 16, 1024)
	pixels := csg_generate_procedural_texture_rgba(params, context.temp_allocator)

	png_bytes := make([dynamic]u8, 0, int(w * h), context.temp_allocator)
	if stbi.write_png_to_func(_png_write_cb, &png_bytes, c.int(w), c.int(h), 4, raw_data(pixels), c.int(w * 4)) == 0 {
		return {}, {}, "Failed to encode PNG", false
	}
	if os.write_entire_file(full_png, png_bytes[:]) != nil {
		return {}, {}, "Failed to write PNG file", false
	}

	engine.asset_db_request_refresh()
	if id, found := engine.asset_db_get_guid(rel_png); found {
		tex_guid = engine.Asset_GUID(id)
		_, _ = engine.texture_upsert_procedural(tex_guid, pixels, w, h)
	}

	// Write paired `.mat` file referencing `tex_guid`
	shader_int := 0 if unlit else 1
	mat_json := fmt.tprintf(
		"{{\n  \"shader\": %d,\n  \"texture\": \"%v\",\n  \"color\": [1.0, 1.0, 1.0, 1.0]\n}}\n",
		shader_int,
		tex_guid,
	)
	_ = os.write_entire_file(full_mat, transmute([]u8)mat_json)
	engine.asset_db_request_refresh()
	if mid, mfound := engine.asset_db_get_guid(rel_mat); mfound {
		mat_guid = engine.Asset_GUID(mid)
		mat_val := engine.Material{
			shader  = .Unlit if unlit else .Lit,
			texture = tex_guid,
			color   = {1, 1, 1, 1},
		}
		engine.material_preview(mat_guid, mat_val)
	}

	status = fmt.tprintf("Saved %s (%dx%d) & %s", rel_png, w, h, rel_mat)
	return tex_guid, mat_guid, status, true
}

// ============================================================================
// 3. SOFT DEFORMER BODIES VIA TEXTURE & VERTEX COORDINATE OFFSET
//    (`p' = p + Δp(x, t)` while CSG Collision stays 100% unchanged!)
// ============================================================================

// Applies a Soft Deformer coordinate-offset impulse (`Dent_Inward`, `Bulge_Outward`, `Shockwave_Ripple`, or `Twist_Shear`)
// at `world_pos` across any `CSGVolume` within `radius` (or specifically on `target_vol` if non-nil).
// Does NOT modify or re-cook Jolt CSG colliders — only the visual mesh & 2D Deformation Offset Texture deform!
csg_apply_soft_deform_impulse :: proc(
	world_pos:    [3]f32,
	world_normal: [3]f32,
	radius:       f32 = 1.4,
	depth:        f32 = 0.35,
	mode:         CSG_Soft_Deform_Mode = .Dent_Inward,
	target_vol:   ^CSGVolume = nil,
) -> int {
	w := engine.ctx_world()
	if w == nil do return 0

	rad := clamp(radius, 0.20, 8.0)
	applied := 0

	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || !vol.soft_deform_enabled do continue
		if target_vol != nil && vol != target_vol do continue

		tw := engine.transform_world(vol.owner)
		model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		inv_m := linalg.inverse(model)
		local_p := (inv_m * [4]f32{world_pos.x, world_pos.y, world_pos.z, 1.0}).xyz
		local_n := linalg.normalize0((inv_m * [4]f32{world_normal.x, world_normal.y, world_normal.z, 0.0}).xyz)
		if linalg.length2(local_n) < 1e-4 do local_n = {0, 1, 0}

		if vlo, vhi, vok := csg_volume_local_aabb(vol); vok {
			if !aabb_overlaps(vlo, vhi, local_p - [3]f32{rad, rad, rad}, local_p + [3]f32{rad, rad, rad}, 0.25) {
				continue
			}
		}

		row := csg_get_material_row(vol.material_preset)
		max_d := max(row.deform_max_depth, 0.25)
		clamped_depth := clamp(depth, -max_d, max_d)
		plastic_frac := clamp(row.plastic_dent_ratio, 0.0, 1.0)
		plastic_d := clamped_depth * plastic_frac
		elastic_d := clamped_depth * (1.0 - plastic_frac)

		prev_alloc := context.allocator
		context.allocator = runtime.default_allocator()
		if vol.soft_deform_stamps == nil {
			vol.soft_deform_stamps = make([dynamic]CSG_Soft_Deform_Stamp, 0, 16)
		}

		// Merge with an existing nearby stamp of the same mode if within 0.25m so brush dragging is smooth and bounded!
		merged := false
		for &st in vol.soft_deform_stamps {
			if st.mode == mode && linalg.length2(st.local_pos - local_p) <= 0.0625 {
				st.plastic_depth = clamp(st.plastic_depth + plastic_d * 0.45, -max_d, max_d)
				st.elastic_depth = clamp(st.elastic_depth + elastic_d * 0.55, -max_d, max_d)
				st.radius        = max(st.radius, rad)
				st.age           = 0.0
				merged = true
				break
			}
		}
		if !merged {
			if len(vol.soft_deform_stamps) >= 64 {
				ordered_remove(&vol.soft_deform_stamps, 0)
			}
			append(&vol.soft_deform_stamps, CSG_Soft_Deform_Stamp{
				local_pos     = local_p,
				local_normal  = local_n,
				radius        = rad,
				plastic_depth = plastic_d,
				elastic_depth = elastic_d,
				elastic_vel   = 0.0,
				stiffness     = max(row.deform_stiffness, 4.0),
				damping       = max(row.elastic_recovery_rate, 0.8),
				mode          = mode,
				age           = 0.0,
			})
		}
		context.allocator = prev_alloc

		vol.gpu_dirty = true
		for _, ch in vol.chunks {
			if ch != nil {
				ch.dirty_gpu = true
				ch.dirty_physics = true
			}
		}
		csg_volume_repack_gpu_mesh(vol)
		applied += 1
	}
	return applied
}

// Clears all runtime Soft Deformer coordinate-offset stamps on `vol`, restores undeformed CSG hulls, and re-syncs Jolt colliders.
csg_volume_reset_soft_deform :: proc(vol: ^CSGVolume) {
	if vol == nil do return
	if vol.soft_deform_stamps != nil {
		clear(&vol.soft_deform_stamps)
	}
	csg_volume_rebuild(vol)
	csg_volume_sync_colliders_only(vol)
}

// Steps the Hooke spring-damper ODE (`d²u/dt² = -k*u - c*du/dt`) for all active elastic Soft Deformer stamps
// across all `CSGVolume`s in the active world.
csg_tick_soft_deform_stamps :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	step_dt := clamp(dt, 0.001, 0.05)

	it := engine.pool_iterator(csg_volumes(w))
	for vol, _ in engine.pool_next(&it) {
		if !vol.enabled || len(vol.soft_deform_stamps) == 0 do continue
		any_elastic_active := false
		for &st in vol.soft_deform_stamps {
			st.age += step_dt
			if abs(st.elastic_depth) > 1e-4 || abs(st.elastic_vel) > 1e-4 {
				// Semi-implicit Euler integration of damped harmonic oscillator
				accel := -st.stiffness * st.elastic_depth - st.damping * st.elastic_vel
				st.elastic_vel   += accel * step_dt
				st.elastic_depth += st.elastic_vel * step_dt
				if abs(st.elastic_depth) < 1e-3 && abs(st.elastic_vel) < 1e-3 {
					st.elastic_depth = 0.0
					st.elastic_vel   = 0.0
				}
				any_elastic_active = true
			}
		}
		if any_elastic_active {
			vol.gpu_dirty = true
		}
	}
}

// Evaluates the net 3D coordinate offset `Δp(local_pos)` and normalized strain `strain_01` in `[0, 1]`
// at volume-local point `local_pos` from `stamps`.
// Mathematical formulation:
//   w(r) = (1 - (r / R)^2)^2  for r < R  (C^2 smooth Wendland-like radial basis kernel)
csg_eval_soft_deform_offset :: proc(
	stamps:    []CSG_Soft_Deform_Stamp,
	local_pos: [3]f32,
	local_n:   [3]f32 = {0, 1, 0},
) -> (
	delta_pos: [3]f32,
	strain_01: f32,
) {
	if len(stamps) == 0 do return {0, 0, 0}, 0.0
	for st in stamps {
		total_d := st.plastic_depth + st.elastic_depth
		if abs(total_d) < 1e-5 do continue
		rel := local_pos - st.local_pos
		r2  := linalg.length2(rel)
		R   := max(st.radius, 0.15)
		if r2 >= R * R do continue

		r := math.sqrt(r2)
		q := r / R
		one_minus_q2 := 1.0 - q * q
		w := one_minus_q2 * one_minus_q2 // Smooth C^2 radial weight in [0..1]

		n := st.local_normal
		switch st.mode {
		case .Dent_Inward:
			// Push inward along -normal at center + subtle outward volume-preserving rim bulge near q ~ 0.65
			rim_bulge := 0.22 * math.sin(q * math.PI) * w
			 tangent := rel - n * linalg.dot(rel, n)
			t_dir := linalg.normalize0(tangent) if linalg.length2(tangent) > 1e-5 else [3]f32{0, 0, 0}
			delta_pos += (-n * (total_d * w)) + t_dir * (total_d * rim_bulge)

		case .Bulge_Outward:
			delta_pos += n * (total_d * w)

		case .Shockwave_Ripple:
			wave := math.cos(q * math.PI * 3.0 - st.age * 8.0) * w
			delta_pos += n * (total_d * wave)

		case .Twist_Shear:
			swirl_dir := linalg.cross(n, rel)
			delta_pos += swirl_dir * (total_d * w * 1.35 / R)
		}
		strain_01 = max(strain_01, clamp((abs(total_d) * w) / max(R * 0.35, 0.08), 0.0, 1.0))
	}
	return delta_pos, strain_01
}

// Maps a normalized strain value `s in [0, 1]` to a vibrant scientific heatmap color:
// 0.0 = Deep Blue (zero offset) -> 0.25 = Cyan -> 0.50 = Green -> 0.75 = Yellow -> 1.0 = Bright Red (max strain)
csg_strain_to_heatmap_color :: proc(s: f32) -> [4]u8 {
	t := clamp(s, 0.0, 1.0)
	r, g, b: f32
	if t < 0.25 {
		k := t / 0.25
		r, g, b = 0.10 * (1.0 - k), 0.25 + 0.75 * k, 0.95
	} else if t < 0.50 {
		k := (t - 0.25) / 0.25
		r, g, b = 0.0, 1.0, 0.95 * (1.0 - k) + 0.15 * k
	} else if t < 0.75 {
		k := (t - 0.50) / 0.25
		r, g, b = k, 1.0, 0.15 * (1.0 - k)
	} else {
		k := (t - 0.75) / 0.25
		r, g, b = 1.0, 1.0 - 0.85 * k, 0.08 * k
	}
	return {
		u8(clamp(r * 255.0, 0, 255)),
		u8(clamp(g * 255.0, 0, 255)),
		u8(clamp(b * 255.0, 0, 255)),
		255,
	}
}

// Applies the Soft Deformer Coordinate-Offset math (`p' = p0 + Δp(p0, t)`) and finite-difference
// Jacobian normal perturbation (`n' = normalize(n0 - ∂Δp/∂u × t_v - t_u × ∂Δp/∂v)`) to a slice of `gfx.Vertex`!
// Returns a newly allocated slice on `alloc` (leaving the original chunk `ch.verts` untouched so Jolt physics
// and repeated elastic ticks always evaluate from the clean undeformed rest positions `p0`!).
csg_build_deformed_vertex_buffer :: proc(
	vol:        ^CSGVolume,
	rest_verts: []gfx.Vertex,
	alloc       := context.temp_allocator,
) -> (
	out_verts:  []gfx.Vertex,
	max_disp_m: f32,
	rms_strain: f32,
) {
	out_verts = make([]gfx.Vertex, len(rest_verts), alloc)
	copy(out_verts, rest_verts)
	if vol == nil || (!vol.soft_deform_enabled && !vol.deform_debug_heatmap) do return
	if len(vol.soft_deform_stamps) == 0 && !vol.deform_debug_heatmap do return

	stamps := vol.soft_deform_stamps[:]
	eps :: f32(0.04)
	strain_sum_sq: f32 = 0.0

	for &v, i in out_verts {
		p0 := rest_verts[i].position
		n0 := linalg.normalize0(rest_verts[i].normal)
		if linalg.length2(n0) < 1e-4 do n0 = {0, 1, 0}

		dp, strain := csg_eval_soft_deform_offset(stamps, p0, n0)
		disp_len := linalg.length(dp)
		if disp_len > max_disp_m do max_disp_m = disp_len
		strain_sum_sq += strain * strain

		if disp_len > 1e-5 {
			v.position = p0 + dp
			// Finite-difference tangent Jacobian to perturb normal `n'` for accurate dent shading!
			tu, tv := plane_tangent_basis(n0)
			dp_u, _ := csg_eval_soft_deform_offset(stamps, p0 + tu * eps, n0)
			dp_v, _ := csg_eval_soft_deform_offset(stamps, p0 + tv * eps, n0)
			du_vec := tu + (dp_u - dp) * (1.0 / eps)
			dv_vec := tv + (dp_v - dp) * (1.0 / eps)
			n_pert := linalg.normalize0(linalg.cross(du_vec, dv_vec))
			if linalg.length2(n_pert) > 0.5 {
				if linalg.dot(n_pert, n0) < 0 do n_pert = -n_pert
				v.normal = n_pert
			}
		}

		if vol.deform_debug_heatmap {
			v.color = csg_strain_to_heatmap_color(strain)
		} else if strain > 0.02 {
			// Subtle stress darkening/sheen in standard lit mode so dents have extra visual depth
			darken := clamp(1.0 - strain * 0.28, 0.65, 1.0)
			v.color.r = u8(clamp(f32(v.color.r) * darken, 0, 255))
			v.color.g = u8(clamp(f32(v.color.g) * darken, 0, 255))
			v.color.b = u8(clamp(f32(v.color.b) * darken, 0, 255))
		}
	}

	if len(rest_verts) > 0 {
		rms_strain = math.sqrt(strain_sum_sq / f32(len(rest_verts)))
	}
	return
}

@(private = "package")
_lerp_gfx_vertex :: #force_inline proc(a, b: gfx.Vertex, t: f32) -> gfx.Vertex {
	it := 1.0 - t
	n := linalg.normalize0(a.normal * it + b.normal * t)
	if linalg.length2(n) < 1e-4 do n = a.normal
	return gfx.Vertex{
		position = a.position * it + b.position * t,
		normal   = n,
		uv       = a.uv * it + b.uv * t,
		color    = {
			u8(clamp(f32(a.color.r) * it + f32(b.color.r) * t, 0, 255)),
			u8(clamp(f32(a.color.g) * it + f32(b.color.g) * t, 0, 255)),
			u8(clamp(f32(a.color.b) * it + f32(b.color.b) * t, 0, 255)),
			u8(clamp(f32(a.color.a) * it + f32(b.color.a) * t, 0, 255)),
		},
	}
}

// Locally subdivides coarse triangles overlapping any `CSG_Soft_Deform_Stamp` on `vol` (up to 3 passes of 1-to-4
// midpoint tessellation in `alloc`), then applies `csg_build_deformed_vertex_buffer`.
// This gives flat 2-triangle CSG faces and cube meshes smooth interior vertices to dent/bulge/ripple/twist
// in < 0.15ms without expensive synchronous 3D boolean hull subtraction!
csg_tessellate_and_deform_mesh :: proc(
	vol:            ^CSGVolume,
	rest_verts:     []gfx.Vertex,
	rest_indices:   []u32,
	rest_submeshes: []engine.Mesh_Submesh = nil,
	alloc           := context.temp_allocator,
) -> (
	out_verts:     []gfx.Vertex,
	out_indices:   []u32,
	out_submeshes: []engine.Mesh_Submesh,
) {
	if vol == nil || len(rest_verts) == 0 || len(rest_indices) < 3 {
		return rest_verts, rest_indices, rest_submeshes
	}
	has_stamps := vol.soft_deform_enabled && len(vol.soft_deform_stamps) > 0
	if !has_stamps && !vol.deform_debug_heatmap {
		return rest_verts, rest_indices, rest_submeshes
	}
	if !has_stamps {
		def_v, _, _ := csg_build_deformed_vertex_buffer(vol, rest_verts, alloc)
		return def_v, rest_indices, rest_submeshes
	}

	stamps := vol.soft_deform_stamps[:]

	// Helper: check if triangle `(p0, p1, p2)` overlaps any stamp sphere and has an edge > threshold
	tri_needs_subdiv :: proc(p0, p1, p2: [3]f32, stamps: []CSG_Soft_Deform_Stamp) -> bool {
		e01 := linalg.length(p1 - p0)
		e12 := linalg.length(p2 - p1)
		e20 := linalg.length(p0 - p2)
		max_e := max(e01, max(e12, e20))
		if max_e <= 0.18 do return false

		t_min := linalg.min(p0, linalg.min(p1, p2))
		t_max := linalg.max(p0, linalg.max(p1, p2))
		for st in stamps {
			r := max(st.radius, 0.15) * 1.15
			if max_e <= max(r * 0.28, 0.18) do continue
			s_min := st.local_pos - [3]f32{r, r, r}
			s_max := st.local_pos + [3]f32{r, r, r}
			if aabb_overlaps(t_min, t_max, s_min, s_max, 0.02) {
				return true
			}
		}
		return false
	}

	curr_v := make([dynamic]gfx.Vertex, len(rest_verts), alloc)
	copy(curr_v[:], rest_verts)
	curr_i := make([dynamic]u32, len(rest_indices), alloc)
	copy(curr_i[:], rest_indices)

	has_subs := len(rest_submeshes) > 0
	curr_subs := make([dynamic]engine.Mesh_Submesh, max(len(rest_submeshes), 1), alloc)
	if has_subs {
		copy(curr_subs[:], rest_submeshes)
	} else {
		curr_subs[0] = engine.Mesh_Submesh{first_index = 0, index_count = u32(len(rest_indices))}
	}

	next_i    := make([dynamic]u32, 0, len(rest_indices) * 2, alloc)
	next_subs := make([dynamic]engine.Mesh_Submesh, 0, len(curr_subs), alloc)

	for _ in 0 ..< 3 {
		if len(curr_i) / 3 >= 3200 do break
		clear(&next_i)
		clear(&next_subs)
		any_split := false

		for sub in curr_subs {
			sub_start := u32(len(next_i))
			tri_n := int(sub.index_count) / 3
			for t in 0 ..< tri_n {
				base := int(sub.first_index) + t * 3
				if base + 2 >= len(curr_i) do break
				i0, i1, i2 := curr_i[base + 0], curr_i[base + 1], curr_i[base + 2]
				v0, v1, v2 := curr_v[i0], curr_v[i1], curr_v[i2]
				if len(next_i) / 3 < 3600 && tri_needs_subdiv(v0.position, v1.position, v2.position, stamps) {
					m01 := _lerp_gfx_vertex(v0, v1, 0.5)
					m12 := _lerp_gfx_vertex(v1, v2, 0.5)
					m20 := _lerp_gfx_vertex(v2, v0, 0.5)
					im01 := u32(len(curr_v)); append(&curr_v, m01)
					im12 := u32(len(curr_v)); append(&curr_v, m12)
					im20 := u32(len(curr_v)); append(&curr_v, m20)
					append(&next_i,
						i0,   im01, im20,
						im01, i1,   im12,
						im20, im12, i2,
						im01, im12, im20,
					)
					any_split = true
				} else {
					append(&next_i, i0, i1, i2)
				}
			}
			append(&next_subs, engine.Mesh_Submesh{
				first_index = sub_start,
				index_count = u32(len(next_i)) - sub_start,
			})
		}
		curr_i, next_i = next_i, curr_i
		curr_subs, next_subs = next_subs, curr_subs
		if !any_split do break
	}

	def_v, _, _ := csg_build_deformed_vertex_buffer(vol, curr_v[:], alloc)
	if has_subs {
		return def_v, curr_i[:], curr_subs[:]
	}
	return def_v, curr_i[:], nil
}

// Encodes a `CSGVolume`'s Soft Deformer Coordinate-Offset Field into a 2D `width x height` RGBA8
// Deformation Offset Texture (`(R, G, B) = (Δx, Δy, Δz)` mapped from `[-max_range, +max_range] -> [0, 255]`,
// where neutral `(128, 128, 128)` = zero displacement, and `A` = strain/heatmap intensity).
// Used both for instanced shader/texture coordinate-offset sampling AND the Renderer Math Debug Inspector!
csg_build_soft_deform_offset_texture_rgba8 :: proc(
	vol:          ^CSGVolume,
	width:        i32 = 64,
	height:       i32 = 64,
	visualize_hm: bool = false,
	alloc         := context.temp_allocator,
) -> []u8 {
	w := clamp(width, 16, 256)
	h := clamp(height, 16, 256)
	pixels := make([]u8, int(w * h * 4), alloc)

	lo := [3]f32{-4, 0, -4}
	hi := [3]f32{ 4, 4,  4}
	if vol != nil {
		if vlo, vhi, vok := csg_volume_local_aabb(vol); vok {
			lo = vlo
			hi = vhi
		}
	}
	span := linalg.max(hi - lo, [3]f32{1.0, 1.0, 1.0})
	max_range: f32 = 0.65
	if vol != nil {
		row := csg_get_material_row(vol.material_preset)
		max_range = max(row.deform_max_depth, 0.35)
	}

	stamps: []CSG_Soft_Deform_Stamp
	if vol != nil && len(vol.soft_deform_stamps) > 0 {
		stamps = vol.soft_deform_stamps[:]
	}

	for iy in 0 ..< h {
		v := (f32(iy) + 0.5) / f32(h)
		for ix in 0 ..< w {
			u := (f32(ix) + 0.5) / f32(w)
			// Sample across the volume's primary surface envelope
			sample_p := [3]f32{
				lo.x + u * span.x,
				lo.y + (1.0 - v) * span.y,
				(lo.z + hi.z) * 0.5,
			}
			// Also project to nearest stamp plane along Z so stamps at any Z depth appear clearly in the 2D UV map!
			if len(stamps) > 0 {
				best_d2: f32 = 1e18
				best_z := sample_p.z
				for st in stamps {
					dx := sample_p.x - st.local_pos.x
					dy := sample_p.y - st.local_pos.y
					d2 := dx * dx + dy * dy
					if d2 < best_d2 {
						best_d2 = d2
						best_z  = st.local_pos.z
					}
				}
				sample_p.z = best_z
			}

			dp, strain := csg_eval_soft_deform_offset(stamps, sample_p, {0, 0, 1})
			base := (iy * w + ix) * 4
			if visualize_hm {
				hm := csg_strain_to_heatmap_color(strain)
				pixels[base + 0] = hm.r
				pixels[base + 1] = hm.g
				pixels[base + 2] = hm.b
				pixels[base + 3] = 255
			} else {
				// Standard Vector Displacement Map encoding: R=ΔX, G=ΔY, B=ΔZ in [-max_range, +max_range] -> [0..255]
				nx := clamp(dp.x / (2.0 * max_range) + 0.5, 0.0, 1.0)
				ny := clamp(dp.y / (2.0 * max_range) + 0.5, 0.0, 1.0)
				nz := clamp(dp.z / (2.0 * max_range) + 0.5, 0.0, 1.0)
				pixels[base + 0] = u8(nx * 255.0)
				pixels[base + 1] = u8(ny * 255.0)
				pixels[base + 2] = u8(nz * 255.0)
				pixels[base + 3] = u8(clamp(180.0 + strain * 75.0, 180.0, 255.0))
			}
		}
	}
	return pixels
}
