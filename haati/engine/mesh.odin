package engine

// Mesh cache keyed by (guid, part), mirroring texture2d.odin. Unlike
// textures, the raw glTF is never loaded at runtime — the imported artifact
// IS the runtime format (see asset_importer_mesh.odin); a missing OR stale
// artifact (format bump, corruption) triggers an import-then-retry.
// part == 0 is the whole baked model; part == i+1 is glTF mesh i in
// node-local space (MeshFilter.part).

import gfx "gfx"
import "log"
import "base:runtime"
import "core:encoding/uuid"
import "core:strings"

Mesh :: struct {
    guid:      Asset_GUID,
    aabb_min:  [3]f32, // local-space bounds, for picking and selection outline
    aabb_max:  [3]f32,
    submeshes: []Mesh_Submesh, // per-material index ranges (owned, ≥1)
    gpu:       gfx.Mesh,

    // Skin, empty when the mesh is not skinned. All owned by the cache entry.
    //
    // `skin_gpu` is the bind pose and the per-vertex joints and weights on the
    // GPU, read by the skinning compute pass of every SkinnedMeshRenderer.
    // `skin`, `bind_vertices`, and `bind_indices` are also kept on the CPU for
    // ArmatureDeformedMesh weight painting, symmetry, and collider auto-fitting.
    skin_gpu:      gfx.Skin_Source,
    skin:          []Mesh_Skin_Vertex,       // parallel to bind_vertices
    bind_vertices: []gfx.Vertex,             // bind-pose positions and normals
    bind_indices:  []u32,                    // the skinned buffer draws these
    inverse_binds: []matrix[4, 4]f32,        // one per joint
    joint_names:   []string,                 // one per joint, for binding
}

mesh_is_skinned :: proc(m: ^Mesh) -> bool {
    return m != nil && len(m.joint_names) > 0
}

Mesh_Key :: struct {
    guid: Asset_GUID,
    part: i32,
}

mesh_cache: map[Mesh_Key]Mesh

// Loads that failed, so a broken asset is attempted ONCE rather than on every
// frame that draws it. A failing load re-imports from source, and re-importing
// a glTF several times a second floods the log and stalls the editor — the
// symptom that makes a missing artifact look like a performance bug rather than
// a missing artifact. Mirrors _shader_failed in shader.odin.
//
// Keyed by (guid, part): one unbuildable part must not stop the rest of the
// model loading. Cleared for an asset by mesh_unload, so a re-import or a
// changed file retries.
@(private = "file") _mesh_failed: map[Mesh_Key]bool

// Whether the parts and clips caches are live. A flag, not a nil check on the
// maps: an empty `make(map)` allocates nothing and compares equal to nil until
// its first insert, so a nil check reads "not initialised" forever and nothing
// is ever cached. Mirrors _animation_clip_cache_ready.
@(private = "file") _mesh_cache_ready: bool

mesh_cache_init :: proc() {
    // Cross-frame caches: never the caller's allocator. A test's tracking
    // allocator frees what the test leaves when it ends, which left the global
    // map pointing at freed memory for the next test.
    mesh_cache = make(map[Mesh_Key]Mesh, runtime.default_allocator())
    _mesh_failed = make(map[Mesh_Key]bool, runtime.default_allocator())
    _mesh_parts = make(map[Asset_GUID][]Mesh_Part, runtime.default_allocator())
    _mesh_clips = make(map[Asset_GUID][]Mesh_Clip, runtime.default_allocator())
    _mesh_cache_ready = true
    // A reimport rewrites the model's artifact and the parts and clips lists
    // in its meta, so both cached lists and every loaded part go with it.
    @(static) hooked := false
    if !hooked {
        hooked = true
        asset_pipeline_add_reimport_hook(mesh_unload)
    }
}

@(private = "file")
_mesh_destroy :: proc(mesh: ^Mesh) {
    prev_alloc := context.allocator
    context.allocator = mesh_cache.allocator if mesh_cache.allocator.procedure != nil else runtime.default_allocator()
    defer context.allocator = prev_alloc
    gfx.mesh_destroy(&mesh.gpu)
    delete(mesh.submeshes)
    gfx.skin_source_destroy(&mesh.skin_gpu)
    delete(mesh.skin)
    delete(mesh.bind_vertices)
    delete(mesh.bind_indices)
    delete(mesh.inverse_binds)
    for n in mesh.joint_names do delete(n)
    delete(mesh.joint_names)
}

mesh_cache_shutdown :: proc() {
    prev_alloc := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev_alloc
    for _, &mesh in mesh_cache {
        _mesh_destroy(&mesh)
    }
    delete(mesh_cache)
    mesh_cache = nil
    delete(_mesh_failed)
    _mesh_failed = nil
    for guid in _mesh_parts do _mesh_parts_free(guid)
    delete(_mesh_parts)
    _mesh_parts = nil
    for guid in _mesh_clips do _mesh_clips_free(guid)
    delete(_mesh_clips)
    _mesh_clips = nil
    _mesh_cache_ready = false
}

// Part id table per model, from the import settings (sprites' Texture2D
// pattern: cache-owned clones on the process heap, evicted on reimport).
@(private = "file") _mesh_parts: map[Asset_GUID][]Mesh_Part

@(private = "file")
_mesh_parts_free :: proc(guid: Asset_GUID) {
    alloc := runtime.default_allocator()
    if parts, ok := _mesh_parts[guid]; ok {
        for p in parts do delete(p.name, alloc)
        delete(parts, alloc)
    }
}

// The model's part id table, cached from its import settings.
mesh_parts :: proc(guid: Asset_GUID) -> []Mesh_Part {
    if _mesh_cache_ready {
        if parts, ok := _mesh_parts[guid]; ok do return parts
    }

    // Headless contexts (tests, scene tooling) run without the cache — read
    // per call onto the temp allocator instead of caching.
    cached := _mesh_cache_ready
    alloc := cached ? runtime.default_allocator() : context.temp_allocator
    prev_alloc := context.allocator
    if cached do context.allocator = runtime.default_allocator()
    defer context.allocator = prev_alloc

    out: []Mesh_Part
    if path, pok := asset_db_get_path(uuid.Identifier(guid)); pok {
        if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
            if ms, is_mesh := settings.(MeshSettings); is_mesh && len(ms.parts) > 0 {
                out = make([]Mesh_Part, len(ms.parts), alloc)
                for p, i in ms.parts {
                    out[i] = Mesh_Part{id = p.id, name = strings.clone(p.name, alloc)}
                }
            }
        }
    }
    if cached do _mesh_parts[guid] = out // empty result caches too — no re-read per frame
    return out
}

// Resolves a part id to its FILE-ORDER index (the _m<i>.bin artifact).
mesh_part_index :: proc(guid: Asset_GUID, id: Local_ID) -> (i32, bool) {
    for p, i in mesh_parts(guid) {
        if p.id == id do return i32(i), true
    }
    return 0, false
}

// The model's clips, from its settings, cached the same way as parts.
@(private = "file") _mesh_clips: map[Asset_GUID][]Mesh_Clip

@(private = "file")
_mesh_clips_free :: proc(guid: Asset_GUID) {
    alloc := runtime.default_allocator()
    if clips, ok := _mesh_clips[guid]; ok {
        for c in clips do delete(c.name, alloc)
        delete(clips, alloc)
    }
}

mesh_clips :: proc(guid: Asset_GUID) -> []Mesh_Clip {
    if _mesh_cache_ready {
        if clips, ok := _mesh_clips[guid]; ok do return clips
    }
    cached := _mesh_cache_ready
    alloc := cached ? runtime.default_allocator() : context.temp_allocator
    prev_alloc := context.allocator
    if cached do context.allocator = runtime.default_allocator()
    defer context.allocator = prev_alloc

    out: []Mesh_Clip
    if path, pok := asset_db_get_path(uuid.Identifier(guid)); pok {
        if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
            if ms, is_mesh := settings.(MeshSettings); is_mesh && len(ms.clips) > 0 {
                out = make([]Mesh_Clip, len(ms.clips), alloc)
                for c, i in ms.clips {
                    // Settings stay in the meta. The cache carries identity only.
                    out[i] = Mesh_Clip{id = c.id, name = strings.clone(c.name, alloc), guid = c.guid, orphan = c.orphan}
                }
            }
        }
    }
    if cached do _mesh_clips[guid] = out
    return out
}

// Resolves a clip id to its FILE-ORDER index (the _a<i>.bin artifact). Orphans
// have no artifact and sit after every real clip, so they never resolve.
mesh_clip_index :: proc(guid: Asset_GUID, id: Local_ID) -> (i32, bool) {
    for c, i in mesh_clips(guid) {
        if c.id == id do return i32(i), !c.orphan
    }
    return 0, false
}

// A MeshFilter's PPtr resolved for mesh_load: local_id 0 = the whole model
// (part 0), otherwise the id's part. ok=false when the id no longer exists
// in the model's table — the filter draws nothing, like a missing mesh.
mesh_filter_part :: proc(mf: ^MeshFilter) -> (part: i32, ok: bool) {
    if mf.mesh.local_id == 0 do return 0, true
    idx, found := mesh_part_index(mf.mesh.guid, mf.mesh.local_id)
    if !found do return 0, false
    return idx + 1, true
}

// Loads what a MeshFilter references — the whole model or its part.
mesh_load_filter :: proc(mf: ^MeshFilter) -> (^Mesh, bool) {
    part, ok := mesh_filter_part(mf)
    if !ok do return nil, false
    return mesh_load(mf.mesh.guid, part)
}

// Returns true if `(guid, part)` is currently resident in `mesh_cache` with a valid GPU buffer.
// Safe to call for procedural meshes without triggering disk artifact lookup or `_mesh_failed`.
mesh_is_cached :: proc(guid: Asset_GUID, part: i32 = 0) -> bool {
    if !_mesh_cache_ready && len(mesh_cache) == 0 do return false
    key := Mesh_Key{guid, part}
    if m, ok := &mesh_cache[key]; ok {
        return len(m.submeshes) > 0 && (gfx.device() == nil || m.gpu.index_count > 0)
    }
    return false
}

mesh_load :: proc(guid: Asset_GUID, part: i32 = 0) -> (^Mesh, bool) {
    key := Mesh_Key{guid, part}
    if mesh, ok := &mesh_cache[key]; ok {
        return mesh, true
    }
    // Known bad: do not re-import it again this session.
    if key in _mesh_failed do return nil, false
    // Headless contexts (tests, scene tooling) have no GPU device.
    if gfx.device() == nil do return nil, false

    prev_alloc := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev_alloc

    whole := _artifact_path(uuid.Identifier(guid))
    defer delete(whole)
    artifact := whole
    if part > 0 {
        artifact = mesh_part_artifact_path(whole, int(part - 1), context.temp_allocator)
    }

    header: Mesh_Artifact_Header
    vertices: []gfx.Vertex
    indices: []u32
    submeshes: []Mesh_Submesh
    parse_ok := false
    blob, read_err := vfs_read_entire_file(artifact, context.temp_allocator)
    if read_err == nil {
        header, vertices, indices, submeshes, parse_ok = _mesh_artifact_parse(blob)
    }
    if !parse_ok {
        // Artifact missing (fresh clone, cleaned library/) or stale (format
        // bump): import from source and retry once. Every exit below marks the
        // key failed — the retry is once per session, not once per frame.
        source_path, path_ok := asset_db_get_path(uuid.Identifier(guid))
        if !path_ok {
            _mesh_failed[key] = true
            return nil, false
        }
        if !asset_pipeline_request_import(source_path, force = true) {
            _mesh_failed[key] = true
            return nil, false
        }
        blob, read_err = vfs_read_entire_file(artifact, context.temp_allocator)
        if read_err != nil {
            log.errorf("[Mesh] artifact unreadable after re-import: %s (part %d)", artifact, part)
            _mesh_failed[key] = true
            return nil, false
        }
        header, vertices, indices, submeshes, parse_ok = _mesh_artifact_parse(blob)
        if !parse_ok {
            log.errorf("[Mesh] artifact unparseable after re-import: %s (part %d)", artifact, part)
            _mesh_failed[key] = true
            return nil, false
        }
    }

    gpu := gfx.mesh_create(vertices, indices)
    if gpu.index_count == 0 {
        log.errorf("[Mesh] GPU upload produced no indices: %s (part %d, %d verts)", artifact, part, len(vertices))
        _mesh_failed[key] = true
        return nil, false
    }

    owned_submeshes := make([]Mesh_Submesh, len(submeshes))
    copy(owned_submeshes, submeshes)
    m := Mesh{
        guid      = guid,
        aabb_min  = header.aabb_min,
        aabb_max  = header.aabb_max,
        submeshes = owned_submeshes,
        gpu       = gpu,
    }
    // A skinned mesh uploads its bind pose and skin data for the GPU compute
    // skinning pass, and keeps CPU slices for ArmatureDeformedMesh tools.
    if skin, inv, names, sok := _mesh_artifact_parse_skin(blob, header); sok {
        m.skin_gpu = gfx.skin_source_create(vertices, skin)
        m.skin = make([]Mesh_Skin_Vertex, len(skin))
        copy(m.skin, skin)
        m.bind_vertices = make([]gfx.Vertex, len(vertices))
        copy(m.bind_vertices, vertices)
        m.bind_indices = make([]u32, len(indices))
        copy(m.bind_indices, indices)
        m.inverse_binds = make([]matrix[4, 4]f32, len(inv))
        copy(m.inverse_binds, inv)
        split := mesh_joint_names(names, len(inv), context.temp_allocator)
        m.joint_names = make([]string, len(split))
        for n, i in split do m.joint_names[i] = strings.clone(n)
    }
    mesh_cache[key] = m
    return &mesh_cache[key], true
}

// Drops every cached part of the asset, and lets failed parts try again — this
// is the call a re-import makes, and the new artifact deserves a fresh attempt.
mesh_unload :: proc(guid: Asset_GUID) {
    prev_alloc := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev_alloc
    _mesh_parts_free(guid)
    delete_key(&_mesh_parts, guid)
    _mesh_clips_free(guid)
    delete_key(&_mesh_clips, guid)
    keys := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in mesh_cache {
        if key.guid == guid do append(&keys, key)
    }
    for key in keys {
        mesh := &mesh_cache[key]
        _mesh_destroy(mesh)
        delete_key(&mesh_cache, key)
    }

    failed := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in _mesh_failed {
        if key.guid == guid do append(&failed, key)
    }
    for key in failed {
        delete_key(&_mesh_failed, key)
    }
}

// Creates or updates an in-memory procedural/CSG mesh directly in `mesh_cache`
// under `(guid, 0)`. Allows runtime CSG chunks, CAD blockout brushes, and
// fractured debris to render with standard `MeshFilter` + `MeshRenderer`
// (inheriting full multi-light shading, materials, selection outlines, and picking).
mesh_upsert_procedural :: proc(
    guid:             Asset_GUID,
    vertices:         []gfx.Vertex,
    indices:          []u32,
    submeshes:        []Mesh_Submesh = nil,
    keep_cpu_buffers: bool = true,
) -> (^Mesh, bool) {
    if len(vertices) == 0 || len(indices) == 0 do return nil, false
    alloc := mesh_cache.allocator if mesh_cache.allocator.procedure != nil else runtime.default_allocator()
    prev_alloc := context.allocator
    context.allocator = alloc
    defer context.allocator = prev_alloc
    if mesh_cache == nil {
        mesh_cache = make(map[Mesh_Key]Mesh, alloc)
    }

    key := Mesh_Key{guid, 0}
    delete_key(&_mesh_failed, key)

    if existing, ok := &mesh_cache[key]; ok {
        _mesh_destroy(existing)
        delete_key(&mesh_cache, key)
    }

    aabb_min := vertices[0].position
    aabb_max := vertices[0].position
    for v in vertices[1:] {
        aabb_min.x = min(aabb_min.x, v.position.x)
        aabb_min.y = min(aabb_min.y, v.position.y)
        aabb_min.z = min(aabb_min.z, v.position.z)
        aabb_max.x = max(aabb_max.x, v.position.x)
        aabb_max.y = max(aabb_max.y, v.position.y)
        aabb_max.z = max(aabb_max.z, v.position.z)
    }

    gpu: gfx.Mesh
    if gfx.device() != nil {
        gpu = gfx.mesh_create(vertices, indices)
    }

    owned_submeshes: []Mesh_Submesh
    if len(submeshes) > 0 {
        owned_submeshes = make([]Mesh_Submesh, len(submeshes), alloc)
        copy(owned_submeshes, submeshes)
    } else {
        owned_submeshes = make([]Mesh_Submesh, 1, alloc)
        owned_submeshes[0] = Mesh_Submesh{
            first_index = 0,
            index_count = u32(len(indices)),
        }
    }

    m := Mesh{
        guid      = guid,
        aabb_min  = aabb_min,
        aabb_max  = aabb_max,
        submeshes = owned_submeshes,
        gpu       = gpu,
    }
    if keep_cpu_buffers {
        m.bind_vertices = make([]gfx.Vertex, len(vertices), alloc)
        copy(m.bind_vertices, vertices)
        m.bind_indices = make([]u32, len(indices), alloc)
        copy(m.bind_indices, indices)
    }
    mesh_cache[key] = m
    return &mesh_cache[key], true
}

mesh_remove_procedural :: proc(guid: Asset_GUID) {
    if !_mesh_cache_ready do return
    mesh_unload(guid)
}

mesh_local_bounds :: proc(guid: Asset_GUID, part: i32 = 0) -> (bmin, bmax: [3]f32, ok: bool) {
    if !_mesh_cache_ready && len(mesh_cache) == 0 do return {}, {}, false
    if m, mok := &mesh_cache[Mesh_Key{guid, part}]; mok {
        return m.aabb_min, m.aabb_max, true
    }
    return {}, {}, false
}

// Reads CPU vertices and triangle indices for any `MeshFilter` (both procedural in-memory meshes
// and disk-backed glTF mesh artifacts) so the CAD Mesh Editor and Mesh->CSG Compliance Checker
// can inspect, edit, and convert any mesh in the scene.
mesh_read_cpu_geometry :: proc(mf: ^MeshFilter, alloc := context.temp_allocator) -> (vertices: []gfx.Vertex, indices: []u32, ok: bool) {
    if mf == nil || asset_guid_is_empty(mf.mesh.guid) do return nil, nil, false
    part, pok := mesh_filter_part(mf)
    if !pok do return nil, nil, false

    key := Mesh_Key{mf.mesh.guid, part}
    if _mesh_cache_ready || len(mesh_cache) > 0 {
        if m, mok := &mesh_cache[key]; mok && len(m.bind_vertices) > 0 && len(m.bind_indices) > 0 {
            v_out := make([]gfx.Vertex, len(m.bind_vertices), alloc)
            copy(v_out, m.bind_vertices)
            i_out := make([]u32, len(m.bind_indices), alloc)
            copy(i_out, m.bind_indices)
            return v_out, i_out, true
        }
    }

    whole := _artifact_path(uuid.Identifier(mf.mesh.guid))
    defer delete(whole)
    artifact := whole
    if part > 0 {
        artifact = mesh_part_artifact_path(whole, int(part - 1), context.temp_allocator)
    }
    blob, read_err := vfs_read_entire_file(artifact, alloc)
    if read_err != nil do return nil, nil, false
    _, verts, inds, _, parse_ok := _mesh_artifact_parse(blob)
    if !parse_ok || len(verts) == 0 || len(inds) == 0 do return nil, nil, false

    // Cache CPU vertices/indices on the resident `Mesh` entry so repeated queries never hit disk
    if _mesh_cache_ready {
        if m, mok := &mesh_cache[key]; mok && len(m.bind_vertices) == 0 {
            c_alloc := mesh_cache.allocator if mesh_cache.allocator.procedure != nil else runtime.default_allocator()
            m.bind_vertices = make([]gfx.Vertex, len(verts), c_alloc)
            copy(m.bind_vertices, verts)
            m.bind_indices = make([]u32, len(inds), c_alloc)
            copy(m.bind_indices, inds)
        }
    }
    return verts, inds, true
}

