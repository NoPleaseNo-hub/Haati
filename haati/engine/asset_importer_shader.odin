package engine

// User shader importer (docs/Materials.md). A `.glsl` asset is a FRAGMENT
// shader only — the vertex stage is always the built-in world vertex shader,
// since the vertex format and UBO layout are fixed engine contracts. Import
// shells out to the same toolchain as `mh shaders` (glslc → SPIR-V,
// spirv-cross → MSL + reflection) and caches both blobs in the artifact;
// contributors WITHOUT the toolchain can still open the project — only
// authoring/editing shaders needs `brew install shaderc spirv-cross`.
//
// The source must follow the built-in fragment conventions (see
// assets/shaders/normals.glsl): inputs frag_uv/frag_color/frag_normal,
// sampler2D at set=2 binding=0, optional LightUBO at set=3 binding=0, and
// optionally a MATERIAL PROPERTY BLOCK at set=3 binding=1 — its reflected
// std140 layout (member names/offsets/block size) is stored in the artifact
// and fed per-draw from Material.properties.

import "core:strings"

@(typ_guid={guid="fa4de399-c86a-47fa-821f-ddd6276562ad"})
ShaderSettings :: struct {
}

// Fragment UBO slot the property block binds to (slot 0 is the LightUBO).
SHADER_MATERIAL_UBO_BINDING :: 1

// One member of the shader's material property block: where Material
// property values land inside the pushed UBO bytes.
Shader_Property :: struct {
    name:   string,
    offset: u32,
    size:   u32, // float=4, vec2=8, vec3=12, vec4=16
}

// One reflected sampler2D (set=2). Binding 0 is the main texture (fed by
// Material.texture / the sprite's own texture); bindings 1+ become named
// texture rows on the Material, matched by name like properties.
Shader_Texture :: struct {
    name:    string,
    binding: u32,
}

// Fragment sampler slots the engine will bind per draw (SDL_GPU wants the
// exact count the pipeline declares). Shaders with more samplers fail import.
SHADER_MAX_SAMPLERS :: 8
SHADER_SHADOW_SAMPLER_BINDING :: 7

// Artifact layout (little-endian): header | spirv | msl | property table
// (per property: offset u32 | size u32 | name_len u32 | name bytes) |
// texture table (per texture: binding u32 | name_len u32 | name bytes).
// v2 added the property table + block_size; v3 fixed MSL buffer indices
// (--msl-decoration-binding); v4 added the texture table (multi-texture
// materials); v5 added shared shadow atlas binding (slot 7) & LightUBO v5.
// Stale artifacts fail the magic check and shader_load reimports from source.
SHADER_ARTIFACT_MAGIC :: "MHSHDR5\x00"

Shader_Artifact_Header :: struct #packed {
    magic:               [8]u8,
    spv_len:             u32,
    msl_len:             u32,
    num_samplers:        u32, // max binding + 1 (bindings may be sparse)
    num_uniform_buffers: u32, // max binding + 1 (bindings may be sparse)
    block_size:          u32, // material UBO byte size; 0 = no property block
    property_count:      u32,
    texture_count:       u32,
}


// Validates an artifact blob; spv/msl are views into it, property/texture
// names are CLONED with `allocator` (callers keep them past the blob).
// Shared by shader_load and tests.
_shader_artifact_parse :: proc(blob: []u8, allocator := context.allocator) -> (header: Shader_Artifact_Header, spv: []u8, msl: []u8, properties: []Shader_Property, textures: []Shader_Texture, ok: bool) {
    hdr_sz := u64(size_of(Shader_Artifact_Header))
    if u64(len(blob)) < hdr_sz do return
    header = (^Shader_Artifact_Header)(raw_data(blob))^
    if string(header.magic[:]) != SHADER_ARTIFACT_MAGIC do return
    payload_start := hdr_sz + u64(header.spv_len) + u64(header.msl_len)
    if payload_start > u64(len(blob)) do return

    spv = blob[hdr_sz : hdr_sz + u64(header.spv_len)]
    msl = blob[hdr_sz + u64(header.spv_len) : payload_start]

    props: [dynamic]Shader_Property
    texs:  [dynamic]Shader_Texture
    parsed_ok := false
    defer if !parsed_ok {
        for p in props do delete(p.name, allocator)
        delete(props)
        for t in texs do delete(t.name, allocator)
        delete(texs)
    }

    cursor := int(payload_start)
    rem_props := u64(len(blob) - cursor)
    if u64(header.property_count) > rem_props / 12 do return
    props = make([dynamic]Shader_Property, 0, int(header.property_count), allocator)
    for _ in 0 ..< header.property_count {
        if len(blob) - cursor < 12 do return
        offset := (^u32)(raw_data(blob[cursor:]))^
        size := (^u32)(raw_data(blob[cursor + 4:]))^
        name_len_u32 := (^u32)(raw_data(blob[cursor + 8:]))^
        cursor += 12
        if u64(name_len_u32) > u64(len(blob) - cursor) do return
        name_len := int(name_len_u32)
        name := strings.clone(string(blob[cursor:][:name_len]), allocator)
        cursor += name_len
        append(&props, Shader_Property{name = name, offset = offset, size = size})
    }

    rem_texs := u64(len(blob) - cursor)
    if u64(header.texture_count) > rem_texs / 8 do return
    texs = make([dynamic]Shader_Texture, 0, int(header.texture_count), allocator)
    for _ in 0 ..< header.texture_count {
        if len(blob) - cursor < 8 do return
        binding := (^u32)(raw_data(blob[cursor:]))^
        name_len_u32 := (^u32)(raw_data(blob[cursor + 4:]))^
        cursor += 8
        if u64(name_len_u32) > u64(len(blob) - cursor) do return
        name_len := int(name_len_u32)
        name := strings.clone(string(blob[cursor:][:name_len]), allocator)
        cursor += name_len
        append(&texs, Shader_Texture{name = name, binding = binding})
    }
    if cursor != len(blob) do return
    parsed_ok = true
    return header, spv, msl, props[:], texs[:], true
}
