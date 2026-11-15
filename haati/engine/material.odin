package engine

// Unity-style Material asset (docs/Materials.md): picks a shader (built-in
// enum or a custom .glsl asset) and supplies its property block — texture,
// color, and named properties for custom shaders. Materials are JSON files
// under assets/ ("Assets/Create/Material" writes New Material.mat) and
// cached by guid like textures/meshes. MeshRenderer references one by guid;
// no material = plain white, lit on a mesh and unlit on a quad (mirrors
// Unity's default material, lit, and its sprite default, unlit).

import gfx "gfx"
import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:math"
import "core:os"
import "core:strings"

// Built-in shaders — a fixed enum keeps the common case dropdown-simple.
// Custom .glsl shaders come in through Material.custom_shader instead.
Material_Shader :: enum u8 {
	Unlit,
	Lit,
}

// A named value for the custom shader's material UBO (set=3 binding=1).
// Stored as vec4; floats use .x, vec2 .xy, vec3 .xyz — matched to the
// shader's reflected member by name, extra/unknown names are ignored.
Material_Property :: struct {
	name:  string,
	value: [4]f32,
}

// A named texture for the custom shader's extra samplers (set=2, binding 1+;
// binding 0 is Material.texture). Matched to the shader's reflected sampler
// by name; an empty guid binds white.
Material_Texture :: struct {
	name:    string,
	texture: Asset_GUID `ext:"png,jpg,jpeg,bmp,dds"`,
}

@(typ_guid={guid = "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4", menu_assets_create = {menu_name = "Material", file_name = "New Material.mat", order = -6}})
Material :: struct {
	shader:             Material_Shader,
	custom_shader:      Asset_GUID `ext:"glsl"`, // user .glsl asset; overrides `shader` when set
	texture:            Asset_GUID `ext:"png,jpg,jpeg,bmp,dds"`,
	color:              [4]f32 `decor:color()`,
	double_sided:       bool,
	emission_color:     [3]f32 `decor:color()`,
	emission_intensity: f32 `decor:range(0, 64)`,
	properties:         [dynamic]Material_Property, // custom-shader property block values
	textures:           [dynamic]Material_Texture,  // custom-shader extra sampler assignments
	lit_ubo_bytes:      [16]u8 `json:"-" inspect:"-"`,
}

// A new material is Lit, like Unity's. `shader` is stored as a number and
// every saved material carries it, so this changes nothing already written.
reset_Material :: proc(m: ^Material) {
	cleanup_Material(m)
	m.shader = .Lit
	m.color = {1, 1, 1, 1}
	m.double_sided = false
	m.emission_color = {1, 1, 1}
	m.emission_intensity = 0
}

on_validate_Material :: proc(m: ^Material) {
	if m.emission_intensity < 0 {
		m.emission_intensity = 0
	}
}

// Converts sRGB emission tint into pre-multiplied linear HDR vec4 for LitMaterialUBO (set=3 binding=1).
material_pack_lit_emission :: proc(emission_color: [3]f32, emission_intensity: f32) -> [4]f32 {
	i := max(emission_intensity, f32(0.0))
	return {
		math.pow(max(emission_color.x, f32(0.0)), f32(2.2)) * i,
		math.pow(max(emission_color.y, f32(0.0)), f32(2.2)) * i,
		math.pow(max(emission_color.z, f32(0.0)), f32(2.2)) * i,
		i,
	}
}

// gfx shader-set name for draw_mesh. Returned strings are literals — safe to
// hold in draw commands across the frame.
material_shader_name :: proc(shader: Material_Shader) -> string {
	switch shader {
	case .Unlit: return "unlit"
	case .Lit:   return "lit"
	}
	return "unlit"
}

// Resolves a material guid to draw state for gfx.draw_mesh. Empty guid or
// any load failure falls back to plain white drawn with `fallback`: meshes
// pass Lit, so an unassigned slot is shaded like a default material, quads
// keep Unlit, so a sprite without a material stays flat. material_data (temp-allocated,
// nil when the shader has no property block) is the packed UBO for the
// custom shader's material block; extra_textures (temp-allocated, nil unless
// the custom shader declares samplers past binding 0) holds bindings 1..N —
// nil entries bind white.
// Public resolve for preview/tooling draws (the editor's thumbnails): the
// shader name, bound texture, tint, packed property block and extra textures
// one gfx.draw_quad call needs. The returned slices are cached by the material
// system — do not free.
material_resolve_draw :: proc(guid: Asset_GUID) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8, extra_textures: []^gfx.Texture) {
	s, t, c, d, e, _ := _resolve_material_ex(guid)
	return s, t, c, d, e
}

material_resolve_draw_ex :: proc(guid: Asset_GUID) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8, extra_textures: []^gfx.Texture, double_sided: bool) {
	return _resolve_material_ex(guid)
}

_resolve_material :: proc(guid: Asset_GUID, fallback := Material_Shader.Unlit) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8, extra_textures: []^gfx.Texture) {
	s, t, c, d, e, _ := _resolve_material_ex(guid, fallback)
	return s, t, c, d, e
}

_resolve_material_ex :: proc(guid: Asset_GUID, fallback := Material_Shader.Unlit) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8, extra_textures: []^gfx.Texture, double_sided: bool) {
	shader = material_shader_name(fallback)
	color = {1, 1, 1, 1}
	if guid == {} do return
	mat, ok := material_load(guid)
	if !ok do return
	shader = material_shader_name(mat.shader)
	double_sided = mat.double_sided
	used_custom := false
	if mat.custom_shader != {} {
		// Unresolvable custom shader (missing toolchain, compile error) keeps
		// the built-in fallback instead of dropping the draw.
		if sr, sr_ok := shader_load(mat.custom_shader); sr_ok {
			shader = sr.name
			material_data = _material_pack_properties(mat, sr)
			extra_textures = _material_resolve_textures(mat, sr)
			used_custom = true
		}
	}
	if !used_custom && shader == "lit" {
		em := material_pack_lit_emission(mat.emission_color, mat.emission_intensity)
		runtime.mem_copy_non_overlapping(raw_data(mat.lit_ubo_bytes[:]), &em, size_of([4]f32))
		material_data = mat.lit_ubo_bytes[:]
	}
	color = mat.color
	if mat.texture != {} {
		if t, t_ok := texture_load(mat.texture); t_ok {
			tex = t.gfx
		}
	}
	return
}

// Extra sampler bindings 1..num_samplers-1 for the custom shader
// (temp-allocated; nil when the shader only uses the main texture). Slot i
// holds binding i+1; unassigned/unloadable rows stay nil (white at bind).
_material_resolve_textures :: proc(mat: ^Material, sr: ^Shader_Runtime) -> []^gfx.Texture {
	if sr.num_samplers <= 1 do return nil
	extra := make([]^gfx.Texture, sr.num_samplers - 1, context.temp_allocator)
	for st in sr.textures {
		if st.binding == 0 || int(st.binding - 1) >= len(extra) do continue
		for &mt in mat.textures {
			if mt.name != st.name || mt.texture == {} do continue
			if t, t_ok := texture_load(mt.texture); t_ok {
				extra[st.binding - 1] = t.gfx
			}
			break
		}
	}
	return extra
}

// Packs Material.properties into the shader's reflected UBO layout
// (temp-allocated; zero-filled for properties the material doesn't set).
_material_pack_properties :: proc(mat: ^Material, sr: ^Shader_Runtime) -> []u8 {
	if sr.block_size == 0 do return nil
	data := make([]u8, sr.block_size, context.temp_allocator)
	for sp in sr.properties {
		for &mp in mat.properties {
			if mp.name != sp.name do continue
			value := mp.value
			value_bytes := (^[16]u8)(&value)
			copy_sz := min(u64(sp.size), 16)
			if u64(sp.offset) <= u64(len(data)) && copy_sz <= u64(len(data)) - u64(sp.offset) {
				copy(data[sp.offset:], value_bytes[:copy_sz])
			}
			break
		}
	}
	return data
}

// Reconciles the material's property AND texture rows with the shader's
// reflected members: missing rows are added (zero-valued/empty), rows whose
// name isn't in the shader are REMOVED — including all of them when
// custom_shader is cleared. The editor calls this for the open material
// every frame, so the inspector always shows exactly the shader's rows. A
// shader that fails to load (compile error, missing toolchain) leaves the
// rows untouched instead of destroying values. Returns true on change.
material_sync_properties :: proc(mat: ^Material) -> bool {
	changed := false
	if mat.custom_shader == {} {
		if len(mat.properties) > 0 {
			for &mp in mat.properties {
				delete(mp.name)
			}
			clear(&mat.properties)
			changed = true
		}
		if len(mat.textures) > 0 {
			for &mt in mat.textures {
				delete(mt.name)
			}
			clear(&mat.textures)
			changed = true
		}
		return changed
	}
	sr, ok := shader_load(mat.custom_shader)
	if !ok do return false

	for i := 0; i < len(mat.properties); {
		found := false
		for sp in sr.properties {
			if sp.name == mat.properties[i].name {
				found = true
				break
			}
		}
		if found {
			i += 1
			continue
		}
		delete(mat.properties[i].name)
		ordered_remove(&mat.properties, i)
		changed = true
	}
	outer: for sp in sr.properties {
		for &mp in mat.properties {
			if mp.name == sp.name do continue outer
		}
		append(&mat.properties, Material_Property{name = strings.clone(sp.name)})
		changed = true
	}

	// Texture rows: same reconcile against the reflected samplers, skipping
	// binding 0 (that's Material.texture / the sprite's own texture).
	for i := 0; i < len(mat.textures); {
		found := false
		for st in sr.textures {
			if st.binding != 0 && st.name == mat.textures[i].name {
				found = true
				break
			}
		}
		if found {
			i += 1
			continue
		}
		delete(mat.textures[i].name)
		ordered_remove(&mat.textures, i)
		changed = true
	}
	tex_outer: for st in sr.textures {
		if st.binding == 0 do continue
		for &mt in mat.textures {
			if mt.name == st.name do continue tex_outer
		}
		append(&mat.textures, Material_Texture{name = strings.clone(st.name)})
		changed = true
	}
	return changed
}

material_cache: map[Asset_GUID]Material
// Explicit flag: an empty map still compares equal to nil in Odin, so the
// map itself can't distinguish "initialized" from "headless context without
// a cache" (where loads must fail instead of inserting).
_material_cache_ready: bool

material_cache_init :: proc() {
	material_cache = make(map[Asset_GUID]Material, runtime.default_allocator())
	_material_cache_ready = true
}

material_cache_shutdown :: proc() {
	alloc := material_cache.allocator if material_cache.allocator.procedure != nil else runtime.default_allocator()
	for _, &mat in material_cache {
		_material_destroy_with(&mat, alloc)
	}
	delete(material_cache)
	material_cache = nil
	_material_cache_ready = false
}

// Materials hold no GPU resources, so unlike texture/mesh loads this works
// headless — but only in contexts that initialized the cache.
material_load :: proc(guid: Asset_GUID) -> (^Material, bool) {
	if mat, ok := &material_cache[guid]; ok {
		return mat, true
	}
	if !_material_cache_ready do return nil, false

	path, path_ok := asset_db_get_path(uuid.Identifier(guid))
	if !path_ok do return nil, false
	data, read_err := vfs_read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil, false

	alloc := material_cache.allocator if material_cache.allocator.procedure != nil else runtime.default_allocator()
	mat, parse_ok := _material_parse(data, alloc)
	if !parse_ok do return nil, false
	material_cache[guid] = mat
	return &material_cache[guid], true
}

material_unload :: proc(guid: Asset_GUID) {
	if mat, ok := &material_cache[guid]; ok {
		alloc := material_cache.allocator if material_cache.allocator.procedure != nil else runtime.default_allocator()
		_material_destroy_with(mat, alloc)
		delete_key(&material_cache, guid)
	}
}

// Editor hook: pushes (possibly unsaved) inspector values into the cache so
// material edits render live. Deep-cloned — the inspector owns its instance
// and may free it; skipped when the cache already matches (per-frame call).
material_preview :: proc(guid: Asset_GUID, mat: Material) {
	if !_material_cache_ready do return
	alloc := material_cache.allocator if material_cache.allocator.procedure != nil else runtime.default_allocator()
	if existing, ok := &material_cache[guid]; ok {
		if _material_equal(existing^, mat) do return
		_material_destroy_with(existing, alloc)
	}
	material_cache[guid] = _material_clone(mat, alloc)
}

// Cache invalidation for external file changes, called from asset_db_refresh
// (editor saves push values directly via material_preview).
material_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".mat") do return
	if guid, ok := asset_db_get_guid(path); ok {
		material_unload(Asset_GUID(guid))
	}
}

_material_destroy_with :: proc(mat: ^Material, alloc := context.allocator) {
	for &prop in mat.properties {
		delete(prop.name, alloc)
	}
	delete(mat.properties)
	for &tex in mat.textures {
		delete(tex.name, alloc)
	}
	delete(mat.textures)
	mat^ = {}
}

// Frees what a material owns and leaves it zeroed (docs/Components.md,
// "Lifecycle procs").
cleanup_Material :: proc(mat: ^Material) {
	_material_destroy_with(mat, context.allocator)
}

_material_clone :: proc(mat: Material, alloc := context.allocator) -> Material {
	cloned := mat
	cloned.properties = make([dynamic]Material_Property, 0, len(mat.properties), alloc)
	for prop in mat.properties {
		append(&cloned.properties, Material_Property{name = strings.clone(prop.name, alloc), value = prop.value})
	}
	cloned.textures = make([dynamic]Material_Texture, 0, len(mat.textures), alloc)
	for tex in mat.textures {
		append(&cloned.textures, Material_Texture{name = strings.clone(tex.name, alloc), texture = tex.texture})
	}
	return cloned
}

_material_equal :: proc(a, b: Material) -> bool {
	if a.shader != b.shader || a.custom_shader != b.custom_shader || a.texture != b.texture || a.color != b.color do return false
	if a.double_sided != b.double_sided || a.emission_color != b.emission_color || a.emission_intensity != b.emission_intensity do return false
	if len(a.properties) != len(b.properties) do return false
	for prop, i in a.properties {
		if prop.name != b.properties[i].name || prop.value != b.properties[i].value do return false
	}
	if len(a.textures) != len(b.textures) do return false
	for tex, i in a.textures {
		if tex.name != b.textures[i].name || tex.texture != b.textures[i].texture do return false
	}
	return true
}

// Repairs legacy `.mat` JSON where `"texture"` was written as `"texture": ""` or `"texture": "[...]"`
// so both custom `asset_guid_unmarshal` and raw `[16]u8` unmarshalers succeed.
material_sanitize_legacy_json :: proc(data: []byte, alloc := context.temp_allocator) -> ([]byte, bool) {
	s := string(data)
	changed := false
	if strings.contains(s, "\"texture\": \"\"") {
		s, _ = strings.replace_all(s, "\"texture\": \"\"", "\"texture\": \"00000000-0000-0000-0000-000000000000\"", alloc)
		changed = true
	}
	if strings.contains(s, "\"texture\": \"[") {
		s, _ = strings.replace_all(s, "\"texture\": \"[", "\"texture\": [", alloc)
		s, _ = strings.replace_all(s, "]\",", "],", alloc)
		changed = true
	}
	return transmute([]byte)s, changed
}

// Writes a `Material` struct to `filepath` with the canonical `__type_guid` header and `json.marshal` format.
material_save_to_file :: proc(filepath: string, mat: Material) -> bool {
	if len(filepath) == 0 do return false
	opts := json.Marshal_Options{
		spec       = .JSON,
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	raw_bytes, err := json.marshal(mat, opts, context.temp_allocator)
	if err != nil || len(raw_bytes) < 2 do return false
	data_bytes := json_canonicalize_floats(raw_bytes, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n  \"__type_guid\": \"4d201ba5-2097-48bb-abd3-1a79e4f6f6f4\"")
	brace_idx := -1
	for bi := 0; bi < len(data_bytes); bi += 1 {
		if data_bytes[bi] == '{' {
			brace_idx = bi
			break
		}
	}
	tail := ""
	if brace_idx >= 0 {
		after_brace := strings.trim_left_space(string(data_bytes[brace_idx + 1:]))
		if len(after_brace) > 0 && after_brace != "}" {
			tail = after_brace
		}
	}
	if tail != "" {
		strings.write_string(&b, ",\n  ")
		strings.write_string(&b, tail)
	} else {
		strings.write_string(&b, "\n}")
	}
	full_str := strings.to_string(b)
	return os.write_entire_file(filepath, transmute([]byte)full_str) == nil
}

// The serializer writes {"__type_guid": ..., fields...}; unmarshal ignores
// the unknown key. Fields absent from the file keep the defaults set here.
_material_parse :: proc(data: []byte, alloc := context.allocator) -> (Material, bool) {
	// The same defaults as reset_Material, for a hand-written file that
	// leaves a field out.
	mat := Material{shader = .Lit, color = {1, 1, 1, 1}, emission_color = {1, 1, 1}}
	use_data, _ := material_sanitize_legacy_json(data, context.temp_allocator)
	if json.unmarshal(use_data, &mat, .JSON, alloc) != nil {
		_material_destroy_with(&mat, alloc)
		return {}, false
	}
	on_validate_Material(&mat)
	return mat, true
}
