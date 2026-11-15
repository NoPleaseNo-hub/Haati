package engine

import "base:runtime"
import "core:math/linalg"
import "core:strings"
import "core:fmt"


@(poolable)
@(typ_guid={guid = "312927b7-3c4a-4929-9807-8216baf26a68"})
Transform :: struct {
    local_id: Local_ID `inspect:"-"`,
    scene_asset_guid: Asset_GUID `json:"-"`,
    name: string,
    is_active: bool,
    destroy: bool `json:"-"`,
    nested_owned: bool `json:"-"`,
    position: [3]f32,
    rotation: [4]f32,
    scale:    [3]f32,
    render_layer: u32,
    scene: ^Scene `json:"-"`,
    parent:   Ref `inspect:"-"`,
    children: [dynamic]Ref `inspect:"-"`,
    components: [dynamic]Owned `inspect:"-"`,

    // Hierarchical world transform cache (`REV-11`): tracks local TRS + parent
    // generation so direct field writes (`t.position = ...`) automatically
    // invalidate the node and all its descendants without requiring setter calls.
    _world_ver:               u32             `json:"-" inspect:"-"`,
    _cached_parent_ver:       u32             `json:"-" inspect:"-"`,
    _cached_parent_raw:       u64             `json:"-" inspect:"-"`,
    _cached_local_pos:        [3]f32          `json:"-" inspect:"-"`,
    _cached_local_rot:        [4]f32          `json:"-" inspect:"-"`,
    _cached_local_scl:        [3]f32          `json:"-" inspect:"-"`,
    _cached_world:            Transform_World `json:"-" inspect:"-"`,

    // Hierarchical per-object time dilation (`Plan 4`): zero-initialized
    // `_has_custom_time_scale == false` evaluates to `1.0x` so existing scenes
    // and zeroed structs default to normal speed while still supporting `0.0x` stasis.
    _custom_time_scale:       f32             `json:"-" inspect:"-"`,
    _has_custom_time_scale:   bool            `json:"-" inspect:"-"`,
    _ignore_global_time_scale:bool            `json:"-" inspect:"-"`,
    _cached_local_time_scale: f32             `json:"-" inspect:"-"`,
    _cached_world_time_scale: f32             `json:"-" inspect:"-"`,
    _cached_local_ignore_ts:  bool            `json:"-" inspect:"-"`,
    _cached_ignore_global_ts: bool            `json:"-" inspect:"-"`,
}

make_transform_ref :: proc(tH: Transform_Handle) -> Ref {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    lid: Local_ID
    if t != nil do lid = t.local_id
    return Ref{ pptr = PPtr{local_id = lid}, handle = Handle(tH) }
}

transform_new :: proc(name: string, parentH: Transform_Handle = {}) -> Transform_Handle {
    w := ctx_world()
    // World-guarded: in a preview world the (global) active scene is the
    // LIVE one — stamping it would register this world's handle in the live
    // scene's bimap and tag the transform with a scene it can never reach.
    s := sm_scene_active_in_world(w)

    tHandle, t := pool_create(&w.transforms)
    tHandle.type_key = .Transform
    tH := Transform_Handle(tHandle)
    t.name = strings.clone(name)
    t.is_active = true
    t.rotation = QUAT_IDENTITY
    t.scale = {1, 1, 1}
    t.render_layer = 1

    if s != nil {
        t.local_id = scene_new_lid(s)
        t.scene = s
        t.scene_asset_guid = s.asset_guid
        // local_ids is the scene's LIVE lid index — created objects register
        // immediately (not just at load), so lid-based resolution (undo
        // payload rebinding, pickers) and the mint collision check see them.
        bimap_insert(&s.local_ids, t.local_id, Handle(tH))
    }
    else {
        t.local_id = 1
    }

    actual_parentH := parentH
    if !pool_valid(&w.transforms, Handle(actual_parentH)) &&
        s != nil && pool_valid(&w.transforms, s.root.handle)
    {
        actual_parentH = Transform_Handle(s.root.handle)
    }

    transform_set_parent(tH, actual_parentH)

    return tH
}

transform_destroy :: proc(tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    if pool_valid(&w.transforms, t.parent.handle) {
        transform_unlink_from_parent(tH)
    } else {
        // Un-root through the transform's OWN scene, never the active one:
        // destroys run in preview/thumbnail worlds too, where a handle VALUE
        // can coincide with a live-world handle. Resolving through the
        // active scene let a preview teardown clear the LIVE scene's root on
        // such a collision — scene_destroy then found no root, leaked every
        // transform, and the next load showed the scene twice.
        if t.scene != nil && t.scene.root.handle == Handle(tH) do scene_clear_root(t.scene)
    }

    children_copy := make([]Ref, len(t.children), context.temp_allocator)
    copy(children_copy, t.children[:])
    for child in children_copy {
        ct := pool_get(&w.transforms, child.handle)
        if ct != nil {
            ct.parent = {}
            transform_destroy(Transform_Handle(child.handle))
        }
    }
    delete(t.children)

    transform_destroy_components(tH)
    // The scene's local_ids entry is deliberately NOT removed here. The
    // nested-resolve machinery is stale-tolerant by design — entries are
    // re-pointed on the next resolve/registration, and eager removal breaks
    // the peg-rebinding chain during instance teardown/rebuild. Dead entries
    // are repaired at the next load-time registration (overwrite-if-dead).
    delete(t.name)
    t^ = {}
    pool_destroy(&w.transforms, Handle(tH))
}

transform_unlink_from_parent :: proc(tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    if !pool_valid(&w.transforms, t.parent.handle) do return

    p := pool_get(&w.transforms, t.parent.handle)
    for i in 0 ..< len(p.children) {
        if p.children[i].handle == Handle(tH) {
            ordered_remove(&p.children, i)
            break
        }
    }
    t.parent = {}
}

_transform_remap_scene :: proc(tH: Transform_Handle, s: ^Scene) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    old_scene := t.scene
    t.scene = s
    if s != nil && !t.nested_owned {
        if old_scene != nil && t.local_id != 0 {
            bimap_remove_by_key(&old_scene.local_ids, t.local_id)
        }
        t.local_id = scene_new_lid(s)
        bimap_insert(&s.local_ids, t.local_id, Handle(tH))
        for &c in t.components {
            raw := world_pool_get(w, c.handle)
            if raw == nil do continue
            base := cast(^CompData)raw
            if old_scene != nil && base.local_id != 0 {
                bimap_remove_by_key(&old_scene.local_ids, base.local_id)
            }
            base.local_id = scene_new_lid(s)
            c.local_id = base.local_id
            bimap_insert(&s.local_ids, base.local_id, c.handle)
        }
    }
    for child in t.children {
        _transform_remap_scene(Transform_Handle(child.handle), s)
    }
}

// `keep_world` is Unity's SetParent worldPositionStays: locals are recomputed
// against the new parent so the object does not move. Default false — scene
// loading and instantiate set parents with AUTHORED locals. Non-uniform
// parent scale is approximated componentwise, like the TRS chain in
// transform_world.
transform_set_parent :: proc(tH: Transform_Handle, new_parent: Transform_Handle, index: int = -1, keep_world := false) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    tw: Transform_World
    if keep_world do tw = transform_world(tH)

    if pool_valid(&w.transforms, t.parent.handle) {
        transform_unlink_from_parent(tH)
    } else {
        // The transform's OWN scene — same cross-world collision hazard as
        // transform_destroy above.
        if t.scene != nil && t.scene.root.handle == Handle(tH) do scene_clear_root(t.scene)
    }

    new_scene: ^Scene
    if pool_valid(&w.transforms, Handle(new_parent)) {
        np := pool_get(&w.transforms, Handle(new_parent))
        new_scene = np.scene
    } else {
        new_scene = sm_scene_active_in_world(w)
    }

    if new_scene != t.scene {
        _transform_remap_scene(tH, new_scene)
    }

    t.parent = make_transform_ref(new_parent)
    if pool_valid(&w.transforms, Handle(new_parent)) {
        np := pool_get(&w.transforms, Handle(new_parent))
        child_ref := make_transform_ref(tH)
        if index >= 0 && index <= len(np.children) {
            inject_at(&np.children, index, child_ref)
        } else {
            append(&np.children, child_ref)
        }
    } else {
        if new_scene != nil {
            new_scene.root = make_transform_ref(tH)
        }
    }

    if keep_world {
        if pool_valid(&w.transforms, Handle(new_parent)) {
            p := transform_world(new_parent)
            safe := [3]f32{
                p.scale.x != 0 ? p.scale.x : 1,
                p.scale.y != 0 ? p.scale.y : 1,
                p.scale.z != 0 ? p.scale.z : 1,
            }
            inv_rot := linalg.quaternion_inverse(quat_to_native(p.rotation))
            t.position = linalg.quaternion128_mul_vector3(inv_rot, tw.position - p.position) / safe
            t.rotation = quat_from_native(inv_rot * quat_to_native(tw.rotation))
            t.scale = tw.scale / safe
        } else {
            t.position = tw.position
            t.rotation = tw.rotation
            t.scale = tw.scale
        }
    }
}

transform_active_in_hierarchy :: proc(tH: Transform_Handle) -> bool {
    w := ctx_world()
    current := tH
    for pool_valid(&w.transforms, Handle(current)) {
        t := pool_get(&w.transforms, Handle(current))
        if !t.is_active do return false
        current = Transform_Handle(t.parent.handle)
    }
    return true
}

Transform_World :: struct {
    position: [3]f32,
    rotation: [4]f32,
    scale:    [3]f32,
}

_vec3_safe :: proc(v: [3]f32) -> [3]f32 {
    if v.x != v.x || v.y != v.y || v.z != v.z do return {0, 0, 0}
    return v
}

_scale_safe :: proc(s: [3]f32) -> [3]f32 {
    if s.x != s.x || s.y != s.y || s.z != s.z do return {1, 1, 1}
    return s
}

_quat_safe :: proc(q: [4]f32) -> [4]f32 {
    if q.x != q.x || q.y != q.y || q.z != q.z || q.w != q.w do return QUAT_IDENTITY
    len2 := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
    if len2 < 1e-6 do return QUAT_IDENTITY
    return q
}

_transform_store_cache :: proc(
    t:               ^Transform,
    tw:              Transform_World,
    parent_raw:      u64,
    parent_ver:      u32,
    local_ts:        f32,
    world_ts:        f32,
    local_ignore:    bool,
    ignore_global:   bool,
) {
    t._cached_local_pos        = t.position
    t._cached_local_rot        = t.rotation
    t._cached_local_scl        = t.scale
    t._cached_local_time_scale = local_ts
    t._cached_world_time_scale = world_ts
    t._cached_local_ignore_ts  = local_ignore
    t._cached_ignore_global_ts = ignore_global
    t._cached_parent_raw       = parent_raw
    t._cached_parent_ver       = parent_ver
    t._cached_world            = tw
    t._world_ver              += 1
    if t._world_ver == 0 do t._world_ver = 1
}

_transform_world_with_ver :: proc(w: ^World, tH: Transform_Handle) -> (Transform_World, u32) {
    if w == nil do return {{}, QUAT_IDENTITY, {1, 1, 1}}, 0
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return {{}, QUAT_IDENTITY, {1, 1, 1}}, 0

    local_ts     := transform_local_time_scale(t)
    local_ignore := t._ignore_global_time_scale

    parent_h := t.parent.handle
    has_parent := pool_valid(&w.transforms, parent_h)

    if !has_parent {
        if t._world_ver != 0 &&
           t._cached_parent_raw == 0 &&
           t.position == t._cached_local_pos &&
           t.rotation == t._cached_local_rot &&
           t.scale == t._cached_local_scl &&
           local_ts == t._cached_local_time_scale &&
           local_ignore == t._cached_local_ignore_ts {
            return t._cached_world, t._world_ver
        }
        tw := Transform_World{_vec3_safe(t.position), _quat_safe(t.rotation), _scale_safe(t.scale)}
        _transform_store_cache(t, tw, 0, 0, local_ts, local_ts, local_ignore, local_ignore)
        return tw, t._world_ver
    }

    parent_raw := transmute(u64)parent_h
    p, p_ver := _transform_world_with_ver(w, Transform_Handle(parent_h))
    if t._world_ver != 0 &&
       t._cached_parent_raw == parent_raw &&
       t._cached_parent_ver == p_ver &&
       t.position == t._cached_local_pos &&
       t.rotation == t._cached_local_rot &&
       t.scale == t._cached_local_scl &&
       local_ts == t._cached_local_time_scale &&
       local_ignore == t._cached_local_ignore_ts {
        return t._cached_world, t._world_ver
    }

    pt := pool_get(&w.transforms, parent_h)
    parent_ts     := pt != nil ? pt._cached_world_time_scale : f32(1.0)
    parent_ignore := pt != nil ? pt._cached_ignore_global_ts : false

    pos := _vec3_safe(t.position)
    rot := _quat_safe(t.rotation)
    scl := _scale_safe(t.scale)

    p_quat := quat_to_native(p.rotation)
    world_scale := p.scale * scl
    world_rot   := _quat_safe(quat_from_native(p_quat * quat_to_native(rot)))
    world_pos   := _vec3_safe(p.position + linalg.quaternion128_mul_vector3(p_quat, pos * p.scale))
    tw := Transform_World{world_pos, world_rot, world_scale}

    _transform_store_cache(
        t,
        tw,
        parent_raw,
        p_ver,
        local_ts,
        clamp(parent_ts * local_ts, 0.0, TIME_SCALE_MAX),
        local_ignore,
        parent_ignore || local_ignore,
    )
    return tw, t._world_ver
}

@(private = "file")
_transform_update_node_from_parent :: proc(w: ^World, h: Handle) {
    t := pool_get(&w.transforms, h)
    if t == nil do return

    local_ts     := transform_local_time_scale(t)
    local_ignore := t._ignore_global_time_scale
    parent_h     := t.parent.handle
    has_parent   := pool_valid(&w.transforms, parent_h)

    if !has_parent {
        if t._world_ver != 0 &&
           t._cached_parent_raw == 0 &&
           t.position == t._cached_local_pos &&
           t.rotation == t._cached_local_rot &&
           t.scale == t._cached_local_scl &&
           local_ts == t._cached_local_time_scale &&
           local_ignore == t._cached_local_ignore_ts {
            return
        }
        tw := Transform_World{_vec3_safe(t.position), _quat_safe(t.rotation), _scale_safe(t.scale)}
        _transform_store_cache(t, tw, 0, 0, local_ts, local_ts, local_ignore, local_ignore)
        return
    }

    pt := pool_get(&w.transforms, parent_h)
    p := pt._cached_world
    p_ver := pt._world_ver
    parent_raw := transmute(u64)parent_h
    if t._world_ver != 0 &&
       t._cached_parent_raw == parent_raw &&
       t._cached_parent_ver == p_ver &&
       t.position == t._cached_local_pos &&
       t.rotation == t._cached_local_rot &&
       t.scale == t._cached_local_scl &&
       local_ts == t._cached_local_time_scale &&
       local_ignore == t._cached_local_ignore_ts {
        return
    }

    parent_ts     := pt._cached_world_time_scale
    parent_ignore := pt._cached_ignore_global_ts

    pos := _vec3_safe(t.position)
    rot := _quat_safe(t.rotation)
    scl := _scale_safe(t.scale)

    p_quat := quat_to_native(p.rotation)
    world_scale := p.scale * scl
    world_rot   := _quat_safe(quat_from_native(p_quat * quat_to_native(rot)))
    world_pos   := _vec3_safe(p.position + linalg.quaternion128_mul_vector3(p_quat, pos * p.scale))
    tw := Transform_World{world_pos, world_rot, world_scale}

    _transform_store_cache(
        t,
        tw,
        parent_raw,
        p_ver,
        local_ts,
        clamp(parent_ts * local_ts, 0.0, TIME_SCALE_MAX),
        local_ignore,
        parent_ignore || local_ignore,
    )
}

@(private = "file")
_Transform_Wave_Ctx :: struct {
    world: ^World,
    nodes: []Handle,
}

@(private = "file")
_transform_wave_worker :: proc(start_idx, end_idx: int, user_data: rawptr) {
    ctx := (^_Transform_Wave_Ctx)(user_data)
    for i in start_idx ..< end_idx {
        _transform_update_node_from_parent(ctx.world, ctx.nodes[i])
    }
}

// Updates every dirty Transform world cache in depth-first waves across the
// multi-core job pool when `w.transforms.count >= 64`. Each parent wave completes
// before child waves start, eliminating parent-slot write races.
transform_update_world_parallel :: proc(w: ^World = nil) {
    world := w != nil ? w : ctx_world()
    if world == nil || world.transforms.count == 0 do return

    if world.transforms.count < 64 || job_system_worker_count() <= 1 {
        it := pool_iterator(&world.transforms)
        for _, h in pool_next(&it) {
            _transform_world_with_ver(world, Transform_Handle(h))
        }
        return
    }

    wave := make([dynamic]Handle, 0, min(world.transforms.count, 512), runtime.default_allocator())
    defer delete(wave)
    next_wave := make([dynamic]Handle, 0, 256, runtime.default_allocator())
    defer delete(next_wave)

    it := pool_iterator(&world.transforms)
    for t, h in pool_next(&it) {
        if !pool_valid(&world.transforms, t.parent.handle) {
            append(&wave, h)
        }
    }

    visited := 0
    for depth := 0; len(wave) > 0 && depth < 256; depth += 1 {
        visited += len(wave)
        if len(wave) >= 32 {
            wctx := _Transform_Wave_Ctx{
                world = world,
                nodes = wave[:],
            }
            job_parallel_for(len(wave), 16, _transform_wave_worker, &wctx)
        } else {
            for h in wave {
                _transform_update_node_from_parent(world, h)
            }
        }

        clear(&next_wave)
        for h in wave {
            pt := pool_get(&world.transforms, h)
            if pt == nil do continue
            for ch in pt.children {
                if pool_valid(&world.transforms, ch.handle) {
                    append(&next_wave, ch.handle)
                }
            }
        }
        wave, next_wave = next_wave, wave
    }

    // Fallback sweep in case any transform had a manual parent handle without children linkage.
    if visited != world.transforms.count {
        it2 := pool_iterator(&world.transforms)
        for _, h in pool_next(&it2) {
            _transform_world_with_ver(world, Transform_Handle(h))
        }
    }
}

transform_world :: proc(tH: Transform_Handle) -> Transform_World {
    tw, _ := _transform_world_with_ver(ctx_world(), tH)
    return tw
}

// A UI node (RectTransform under a Canvas) answers with its pivot on the
// canvas plane (ui_canvas.odin); everything else with its transform chain.
transform_world_position :: proc(tH: Transform_Handle) -> [3]f32 {
    if p, ok := rect_transform_world_position(tH); ok do return p
    return transform_world(tH).position
}
transform_world_rotation :: proc(tH: Transform_Handle) -> [4]f32 { return transform_world(tH).rotation }
transform_world_scale    :: proc(tH: Transform_Handle) -> [3]f32 { return transform_world(tH).scale }

// Writes a WORLD position into the parent-relative t.position (inverse of the
// parent chain in transform_world). Gizmos drag in world space; this keeps
// the drag correct for children of rotated/scaled parents.
transform_set_world_position :: proc(tH: Transform_Handle, world_pos: [3]f32) {
    if rect_transform_set_world_position(tH, world_pos) do return // UI: into anchored_position
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    if !pool_valid(&w.transforms, t.parent.handle) {
        t.position = world_pos
        return
    }

    p := transform_world(Transform_Handle(t.parent.handle))
    inv_rot := linalg.quaternion_inverse(quat_to_native(_quat_safe(p.rotation)))
    local := linalg.quaternion128_mul_vector3(inv_rot, world_pos - p.position)
    safe_scale := [3]f32{
        p.scale.x != 0 ? p.scale.x : 1,
        p.scale.y != 0 ? p.scale.y : 1,
        p.scale.z != 0 ? p.scale.z : 1,
    }
    t.position = local / safe_scale
}

// Writes a WORLD rotation into the parent-relative t.rotation:
// world = parent_world * local  =>  local = inverse(parent_world) * world.
transform_set_world_rotation :: proc(tH: Transform_Handle, world_rot: [4]f32) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    if !pool_valid(&w.transforms, t.parent.handle) {
        t.rotation = _quat_safe(world_rot)
        return
    }

    p := transform_world(Transform_Handle(t.parent.handle))
    inv_parent := linalg.quaternion_inverse(quat_to_native(_quat_safe(p.rotation)))
    local := inv_parent * quat_to_native(_quat_safe(world_rot))
    t.rotation = quat_from_native(linalg.quaternion_normalize(local))
}

_transform_append_name_suffix :: proc(tH: Transform_Handle, suffix: string) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    old := t.name
    t.name = strings.concatenate({old, suffix})
    delete(old)
    transform_ensure_unique_name(tH)
}

transform_ensure_unique_name :: proc(tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return

    siblings := make([dynamic]Transform_Handle, context.temp_allocator)
    if pool_valid(&w.transforms, t.parent.handle) {
        p := pool_get(&w.transforms, t.parent.handle)
        for c in p.children {
            if c.handle != Handle(tH) && pool_valid(&w.transforms, c.handle) {
                append(&siblings, Transform_Handle(c.handle))
            }
        }
    } else if t.scene != nil && pool_valid(&w.transforms, t.scene.root.handle) {
        r := pool_get(&w.transforms, t.scene.root.handle)
        if r != nil && Handle(tH) != t.scene.root.handle {
            for c in r.children {
                if c.handle != Handle(tH) && pool_valid(&w.transforms, c.handle) {
                    append(&siblings, Transform_Handle(c.handle))
                }
            }
        }
    }

    name_exists :: proc(name: string, siblings: []Transform_Handle, w: ^World) -> bool {
        for sH in siblings {
            st := pool_get(&w.transforms, Handle(sH))
            if st != nil && st.name == name do return true
        }
        return false
    }

    if !name_exists(t.name, siblings[:], w) {
        return
    }

    // Name already exists among siblings! Generate unique name: "Base (1)", "Base (2)", etc.
    base := t.name
    if idx := strings.last_index(base, " ("); idx >= 0 && strings.has_suffix(base, ")") {
        base = base[:idx]
    }

    counter := 1
    new_name := ""
    for {
        candidate := fmt.tprintf("%s (%d)", base, counter)
        if !name_exists(candidate, siblings[:], w) {
            new_name = strings.clone(candidate)
            break
        }
        counter += 1
    }

    delete(t.name)
    t.name = new_name
    if t.scene != nil do t.scene.dirty = true
}

transform_get_sibling_index :: proc(tH: Transform_Handle) -> int {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return -1

    if pool_valid(&w.transforms, t.parent.handle) {
        p := pool_get(&w.transforms, t.parent.handle)
        for i in 0 ..< len(p.children) {
            if p.children[i].handle == Handle(tH) do return i
        }
    } else {
        if t.scene != nil && t.scene.root.handle == Handle(tH) do return 0
    }
    return -1
}

transform_tick_destroy :: proc() {
    w := ctx_world()
    to_destroy: [dynamic]Transform_Handle
    defer delete(to_destroy)
    it := pool_iterator(&w.transforms)
    for t, h in pool_next(&it) {
        if t.destroy {
            h := h
            h.type_key = .Transform
            append(&to_destroy, Transform_Handle(h))
        }
    }
    for tH in to_destroy {
        transform_destroy(tH)
    }
}

// ── Named Render Layers (Bitmask on Transform.render_layer & Camera.render_layer_mask) ──
RENDER_LAYER_DEFAULT        :: u32(1 << 0)
RENDER_LAYER_TRANSPARENT_FX :: u32(1 << 1)
RENDER_LAYER_IGNORE_RAYCAST :: u32(1 << 2)
RENDER_LAYER_WATER          :: u32(1 << 4)
RENDER_LAYER_UI             :: u32(1 << 5)
RENDER_LAYER_ENVIRONMENT    :: u32(1 << 6)
RENDER_LAYER_CHARACTERS     :: u32(1 << 7)
RENDER_LAYER_ALL            :: u32(0xFFFF_FFFF)

Render_Layer_Def :: struct {
    bit:  u32,
    mask: u32,
    name: string,
}

RENDER_LAYER_DEFS :: [7]Render_Layer_Def{
    {0, 1 << 0, "Default"},
    {1, 1 << 1, "TransparentFX"},
    {2, 1 << 2, "Ignore Raycast"},
    {4, 1 << 4, "Water"},
    {5, 1 << 5, "UI"},
    {6, 1 << 6, "Environment"},
    {7, 1 << 7, "Characters"},
}

render_layer_name :: proc(layer_mask: u32) -> string {
    if layer_mask == 0 do return "None"
    if layer_mask == RENDER_LAYER_ALL do return "Everything"
    for def in RENDER_LAYER_DEFS {
        if layer_mask == def.mask do return def.name
    }
    return "Mixed"
}

transform_set_render_layer_recursive :: proc(tH: Transform_Handle, layer_mask: u32) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return
    t.render_layer = layer_mask
    if t.scene != nil do t.scene.dirty = true
    for child in t.children {
        transform_set_render_layer_recursive(Transform_Handle(child.handle), layer_mask)
    }
}

// Depth-first walk over `root` and its descendants matching `name` (`==` or `strings.equal_fold`).
transform_find_descendant_by_name :: proc(root: Transform_Handle, name: string, case_insensitive := false) -> (Transform_Handle, bool) {
    if root == {} || name == "" do return {}, false
    w := ctx_world()
    if w == nil do return {}, false
    t := pool_get(&w.transforms, Handle(root))
    if t == nil do return {}, false
    matched := strings.equal_fold(t.name, name) if case_insensitive else (t.name == name)
    if matched do return root, true
    for ch in t.children {
        if got, ok := transform_find_descendant_by_name(Transform_Handle(ch.handle), name, case_insensitive); ok {
            return got, true
        }
    }
    return {}, false
}

