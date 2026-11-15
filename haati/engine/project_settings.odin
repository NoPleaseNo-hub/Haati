package engine

// Project settings persistence (docs/Plugins.md "Project settings").
//
// A project setting is a package-level struct var marked
// @(project_settings={name="Tab Name"}). The editor's Project Settings window
// lists every marked var as a tab (project_settings_gen), draws it through the
// inspector, and persists it to ProjectSettings/<slug>.json on change. The
// OWNING system loads its own file (these helpers) and consumes the var by
// polling, so an edit — typed, undone or redone — reaches the runtime without
// editor coupling, and the game binary reads the same files.

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core"

// Unified 3-Tier Settings Cascade:
//   Tier 1: Factory Defaults Backdrop (`<engine>/UserSettings/EngineSettings/_defaults_backdrop/<slug>.json`)
//   Tier 2: Engine Settings (default across all projects: `<engine>/UserSettings/EngineSettings/<slug>.json`)
//   Tier 3: Opt-in per-field Project Overrides (`<project>/ProjectSettings/project_overrides.json` +
//           resolved `<project>/ProjectSettings/<slug>.json` for standalone game binaries).
// In non-editor standalone binaries / unit tests without tiered mode enabled, `project_settings_load`
// and `project_settings_save` read/write `ProjectSettings/<slug>.json` directly.
PROJECT_SETTINGS_DIR     :: "ProjectSettings"
ENGINE_SETTINGS_DIR      :: "UserSettings/EngineSettings"
DEFAULTS_BACKDROP_SUBDIR :: "_defaults_backdrop"
PROJECT_OVERRIDES_FILE   :: "ProjectSettings/project_overrides.json"

@(private = "file") _tiers_force_enabled: bool
@(private = "file") _test_engine_dir: string
@(private = "file") _test_project_dir: string
@(private = "file") _factory_backdrop_json: map[string][]byte
@(private = "file") _engine_tier_json: map[string][]byte
@(private = "file") _project_overrides: map[string]map[string][]byte
@(private = "file") _overrides_loaded: bool

project_settings_set_tiered_mode :: proc(enabled: bool) {
    _tiers_force_enabled = enabled
}

// Configures isolated custom directories for unit testing the 3-tier cascade without
// touching real `Haati_Engine/UserSettings` or `ProjectSettings`. Pass `""` to reset.
project_settings_set_dirs_for_test :: proc(eng_dir, proj_dir: string) {
    prev := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev
    if _test_engine_dir != "" {
        delete(_test_engine_dir)
        _test_engine_dir = ""
    }
    if _test_project_dir != "" {
        delete(_test_project_dir)
        _test_project_dir = ""
    }
    if eng_dir != "" do _test_engine_dir = strings.clone(eng_dir)
    if proj_dir != "" do _test_project_dir = strings.clone(proj_dir)
}

project_settings_shutdown :: proc() {
    prev := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev
    for k, v in _factory_backdrop_json {
        delete(k)
        delete(v)
    }
    delete(_factory_backdrop_json)
    _factory_backdrop_json = nil

    for k, v in _engine_tier_json {
        delete(k)
        delete(v)
    }
    delete(_engine_tier_json)
    _engine_tier_json = nil

    for tab_k, fields in _project_overrides {
        for fk, fv in fields {
            delete(fk)
            delete(fv)
        }
        delete(fields)
        delete(tab_k)
    }
    delete(_project_overrides)
    _project_overrides = nil
    _overrides_loaded = false

    if _test_engine_dir != "" {
        delete(_test_engine_dir)
        _test_engine_dir = ""
    }
    if _test_project_dir != "" {
        delete(_test_project_dir)
        _test_project_dir = ""
    }
    _tiers_force_enabled = false
}

@(private = "file")
_use_tiers :: proc() -> bool {
    return _tiers_force_enabled || application_is_editor()
}

// Returns the slug filename stem for `name` (e.g. "Physics 2D" -> "physics_2d").
project_settings_slug :: proc(name: string, allocator := context.temp_allocator) -> string {
    slug, _ := strings.replace_all(strings.to_lower(name, context.temp_allocator), " ", "_", allocator)
    return slug
}

// "<dir>/<slug>.json". Temp-allocated.
_settings_file_in :: proc(dir, name: string) -> string {
    slug := project_settings_slug(name, context.temp_allocator)
    return strings.concatenate({dir, "/", slug, ".json"}, context.temp_allocator)
}

// Directory storing shared Tier 2 Engine Settings.
engine_settings_dir :: proc(allocator := context.temp_allocator) -> string {
    if _test_engine_dir != "" {
        return strings.clone(_test_engine_dir, allocator)
    }
    return engine_file_path(ENGINE_SETTINGS_DIR, allocator)
}

@(private = "file")
_project_dir_resolved :: proc(allocator := context.temp_allocator) -> string {
    if _test_project_dir != "" {
        return strings.clone(_test_project_dir, allocator)
    }
    return strings.clone(PROJECT_SETTINGS_DIR, allocator)
}

@(private = "file")
_overrides_file_path :: proc(allocator := context.temp_allocator) -> string {
    return strings.concatenate({_project_dir_resolved(context.temp_allocator), "/project_overrides.json"}, allocator)
}

@(private = "file")
_marshal_canonical_any :: proc(ptr: rawptr, tid: typeid, allocator := context.temp_allocator) -> ([]byte, bool) {
    if ptr == nil || tid == nil do return nil, false
    opts := json.Marshal_Options{
        spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
        sort_maps_by_key = true,
    }
    marshaled, merr := json.marshal(any{ptr, tid}, opts, context.temp_allocator)
    if merr != nil do return nil, false
    canon := json_canonicalize_floats(marshaled, context.temp_allocator)
    out := make([]byte, len(canon), allocator)
    copy(out, canon)
    return out, true
}

@(private = "file")
_marshal_json_obj_canonical :: proc(obj: json.Object, allocator := context.temp_allocator) -> ([]byte, bool) {
    opts := json.Marshal_Options{
        spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
        sort_maps_by_key = true,
    }
    marshaled, merr := json.marshal(json.Value(obj), opts, context.temp_allocator)
    if merr != nil do return nil, false
    canon := json_canonicalize_floats(marshaled, context.temp_allocator)
    out := make([]byte, len(canon), allocator)
    copy(out, canon)
    return out, true
}

@(private = "file")
_write_canonical_obj :: proc(path: string, obj: json.Object) -> bool {
    data, ok := _marshal_json_obj_canonical(obj, context.temp_allocator)
    if !ok do return false
    return os.write_entire_file(path, data) == nil
}

@(private = "file")
_parse_json_obj :: proc(bytes: []byte, allocator := context.temp_allocator) -> (json.Object, bool) {
    if len(bytes) == 0 do return nil, false
    prev := context.allocator
    context.allocator = allocator
    defer context.allocator = prev
    v, err := json.parse(bytes, .JSON, true)
    if err != nil do return nil, false
    obj, is_obj := v.(json.Object)
    return obj, is_obj
}

@(private = "file")
_set_cached_json :: proc(m: ^map[string][]byte, key: string, bytes: []byte) {
    prev := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev
    if m^ == nil {
        m^ = make(map[string][]byte)
    }
    cpy := make([]byte, len(bytes))
    copy(cpy, bytes)
    if existing, has := m^[key]; has {
        delete(existing)
        m^[key] = cpy
    } else {
        m^[strings.clone(key)] = cpy
    }
}

@(private = "file")
_ensure_overrides_loaded :: proc() {
    if _overrides_loaded do return
    _overrides_loaded = true

    prev := context.allocator
    context.allocator = runtime.default_allocator()
    defer context.allocator = prev
    if _project_overrides == nil {
        _project_overrides = make(map[string]map[string][]byte)
    }

    ovr_path := _overrides_file_path(context.temp_allocator)
    data, rerr := vfs_read_entire_file(ovr_path, context.temp_allocator)
    if rerr != nil || len(data) == 0 do return

    root_obj, ok := _parse_json_obj(data, context.temp_allocator)
    if !ok do return

    for tab_name, tab_val in root_obj {
        fields_obj, is_obj := tab_val.(json.Object)
        if !is_obj || len(fields_obj) == 0 do continue
        fmap := make(map[string][]byte)
        for fname, fval in fields_obj {
            opts := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}
            if raw_f, merr := json.marshal(fval, opts, context.temp_allocator); merr == nil {
                canon := json_canonicalize_floats(raw_f, context.temp_allocator)
                fc := make([]byte, len(canon))
                copy(fc, canon)
                fmap[strings.clone(fname)] = fc
            }
        }
        if len(fmap) > 0 {
            _project_overrides[strings.clone(tab_name)] = fmap
        } else {
            delete(fmap)
        }
    }
}

@(private = "file")
_save_overrides_file :: proc() -> bool {
    _ensure_overrides_loaded()
    pdir := _project_dir_resolved(context.temp_allocator)
    ovr_path := _overrides_file_path(context.temp_allocator)

    total_entries := 0
    for _, fields in _project_overrides {
        total_entries += len(fields)
    }
    if total_entries == 0 {
        if os.exists(ovr_path) {
            _ = os.remove(ovr_path)
        }
        return true
    }

    _ = os.make_directory_all(pdir)
    root_obj := make(json.Object, context.temp_allocator)
    for tab_name, fields in _project_overrides {
        if len(fields) == 0 do continue
        fobj := make(json.Object, context.temp_allocator)
        for fname, fbytes in fields {
            prev := context.allocator
            context.allocator = context.temp_allocator
            v, err := json.parse(fbytes, .JSON, true)
            context.allocator = prev
            if err == nil {
                fobj[fname] = v
            }
        }
        if len(fobj) > 0 {
            root_obj[tab_name] = fobj
        }
    }
    return _write_canonical_obj(ovr_path, root_obj)
}

// Captures the factory default JSON snapshot for `name` before any user/project files load.
project_settings_register_backdrop :: proc(name: string, ptr: rawptr, tid: typeid) {
    if name == "" || ptr == nil || tid == nil do return
    if _factory_backdrop_json != nil && (name in _factory_backdrop_json) do return

    bytes, ok := _marshal_canonical_any(ptr, tid, context.temp_allocator)
    if !ok do return
    _set_cached_json(&_factory_backdrop_json, name, bytes)

    if _use_tiers() {
        bdir := strings.concatenate({engine_settings_dir(context.temp_allocator), "/", DEFAULTS_BACKDROP_SUBDIR}, context.temp_allocator)
        _ = os.make_directory_all(bdir)
        bpath := _settings_file_in(bdir, name)
        _ = os.write_entire_file(bpath, bytes)
    }
}

_settings_load_in :: proc(dir, name: string, v: ^$T) -> bool {
    if v == nil do return false
    data, read_err := vfs_read_entire_file(_settings_file_in(dir, name), context.temp_allocator)
    if read_err != nil && has_active_project() {
        eng_dir := strings.concatenate({engine_haati_dir(context.temp_allocator), "/", dir}, context.temp_allocator)
        data, read_err = vfs_read_entire_file(_settings_file_in(eng_dir, name), context.temp_allocator)
    }
    if read_err != nil do return false
    return json.unmarshal(data, v) == nil
}

@(private = "file")
_apply_overrides_for_tab :: proc(name: string, v: ^$T) -> bool {
    _ensure_overrides_loaded()
    ovr_fields, has_ovr := _project_overrides[name]
    if !has_ovr || len(ovr_fields) == 0 do return false
    patch_obj := make(json.Object, context.temp_allocator)
    for fname, fbytes in ovr_fields {
        prev := context.allocator
        context.allocator = context.temp_allocator
        parsed_val, perr := json.parse(fbytes, .JSON, true)
        context.allocator = prev
        if perr == nil {
            patch_obj[fname] = parsed_val
        }
    }
    if len(patch_obj) > 0 {
        if patch_bytes, pok := _marshal_json_obj_canonical(patch_obj, context.temp_allocator); pok {
            if json.unmarshal(patch_bytes, v) == nil {
                return true
            }
        }
    }
    return false
}

_settings_save_in :: proc(dir, name: string, ptr: rawptr, tid: typeid) -> bool {
    if ptr == nil || tid == nil do return false
    os.make_directory_all(dir)
    data, ok := _marshal_canonical_any(ptr, tid, context.temp_allocator)
    if !ok do return false
    return os.write_entire_file(_settings_file_in(dir, name), data) == nil
}

// "Physics 2D" -> "ProjectSettings/physics_2d.json". Temp-allocated.
project_settings_file :: proc(name: string) -> string {
    return _settings_file_in(_project_dir_resolved(context.temp_allocator), name)
}

// Reads Tier 2 Engine Settings first, then overlays opt-in Tier 3 Project Overrides (when
// running inside the editor / tiered mode); standalone binaries load ProjectSettings/<slug>.json.
project_settings_load :: proc(name: string, v: ^$T) -> bool {
    if v == nil do return false
    {
        prev_alloc := context.allocator
        context.allocator = runtime.default_allocator()
        register_pointer_type(T)
        context.allocator = prev_alloc
    }
    if !_use_tiers() {
        loaded := _settings_load_in(_project_dir_resolved(context.temp_allocator), name, v)
        if _apply_overrides_for_tab(name, v) {
            loaded = true
        }
        return loaded
    }

    project_settings_register_backdrop(name, v, typeid_of(T))

    eng_dir := engine_settings_dir(context.temp_allocator)
    eng_file := _settings_file_in(eng_dir, name)
    pdir := _project_dir_resolved(context.temp_allocator)

    loaded_any := false
    tier2_bytes, rerr := os.read_entire_file(eng_file, context.temp_allocator)
    if rerr != nil {
        // Legacy migration fallback: seed Engine Settings from root ProjectSettings/<slug>.json
        // or <engine>/haati/ProjectSettings/<slug>.json when Engine Settings does not exist yet.
        legacy_candidates := [2]string{
            (!has_active_project() || _test_project_dir != "") ? _settings_file_in(pdir, name) : "",
            _test_engine_dir == "" ? _settings_file_in(strings.concatenate({engine_haati_dir(context.temp_allocator), "/", PROJECT_SETTINGS_DIR}, context.temp_allocator), name) : "",
        }
        for leg in legacy_candidates {
            if leg == "" do continue
            if lb, lerr := os.read_entire_file(leg, context.temp_allocator); lerr == nil && len(lb) > 0 {
                tier2_bytes = lb
                rerr = nil
                _ = os.make_directory_all(eng_dir)
                _ = os.write_entire_file(eng_file, tier2_bytes)
                break
            }
        }
    }

    if rerr == nil && len(tier2_bytes) > 0 {
        _set_cached_json(&_engine_tier_json, name, tier2_bytes)
        if json.unmarshal(tier2_bytes, v) == nil {
            loaded_any = true
        }
    }

    if _apply_overrides_for_tab(name, v) {
        loaded_any = true
    }
    return loaded_any
}

// Saves non-overridden fields to Tier 2 Engine Settings, updates any opted-in fields in
// Tier 3 `project_overrides.json`, and mirrors resolved values to `ProjectSettings/<slug>.json`.
project_settings_save :: proc(name: string, ptr: rawptr, tid: typeid) -> bool {
    if ptr == nil || tid == nil do return false
    if !_use_tiers() {
        return _settings_save_in(_project_dir_resolved(context.temp_allocator), name, ptr, tid)
    }

    project_settings_register_backdrop(name, ptr, tid)
    _ensure_overrides_loaded()

    cur_bytes, ok := _marshal_canonical_any(ptr, tid, context.temp_allocator)
    if !ok do return false
    cur_obj, pok := _parse_json_obj(cur_bytes, context.temp_allocator)
    if !pok do return false

    eng_dir := engine_settings_dir(context.temp_allocator)
    _ = os.make_directory_all(eng_dir)
    eng_file := _settings_file_in(eng_dir, name)

    // Base Tier 2 object starts from prior Tier 2 (if any) or Factory Defaults Backdrop.
    tier2_obj := make(json.Object, context.temp_allocator)
    base_bytes: []byte
    if tb, has_t2 := _engine_tier_json[name]; has_t2 && len(tb) > 0 {
        base_bytes = tb
    } else if fb, has_fb := _factory_backdrop_json[name]; has_fb {
        base_bytes = fb
    }
    if base_obj, bok := _parse_json_obj(base_bytes, context.temp_allocator); bok {
        for k, v in base_obj do tier2_obj[k] = v
    }

    ovr_fields, has_ovr := &_project_overrides[name]
    ovr_dirty := false
    for fname, cur_val in cur_obj {
        if has_ovr && (fname in ovr_fields^) {
            opts := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}
            if raw_f, merr := json.marshal(cur_val, opts, context.temp_allocator); merr == nil {
                canon := json_canonicalize_floats(raw_f, context.temp_allocator)
                if existing, ok_e := ovr_fields^[fname]; !ok_e || !slice.equal(existing, canon) {
                    prev := context.allocator
                    context.allocator = runtime.default_allocator()
                    if ok_e do delete(existing)
                    ncpy := make([]byte, len(canon))
                    copy(ncpy, canon)
                    if !ok_e {
                        ovr_fields^[strings.clone(fname)] = ncpy
                    } else {
                        ovr_fields^[fname] = ncpy
                    }
                    context.allocator = prev
                    ovr_dirty = true
                }
            }
        } else {
            tier2_obj[fname] = cur_val
        }
    }

    if t2_bytes, t2_ok := _marshal_json_obj_canonical(tier2_obj, context.temp_allocator); t2_ok {
        _set_cached_json(&_engine_tier_json, name, t2_bytes)
        _ = os.write_entire_file(eng_file, t2_bytes)
    }

    if ovr_dirty {
        _ = _save_overrides_file()
    }

    // Always keep resolved ProjectSettings/<slug>.json up to date for standalone builds when
    // either ProjectSettings/ already exists, an active project is open, or test project dir is set.
    pdir := _project_dir_resolved(context.temp_allocator)
    if _test_project_dir != "" || has_active_project() || os.is_dir(pdir) {
        _ = os.make_directory_all(pdir)
        _ = os.write_entire_file(_settings_file_in(pdir, name), cur_bytes)
    }
    return true
}

project_settings_has_field_override :: proc(tab_name, field_name: string) -> bool {
    _ensure_overrides_loaded()
    fields, has := _project_overrides[tab_name]
    if !has do return false
    return field_name in fields
}

project_settings_tab_override_count :: proc(tab_name: string) -> int {
    _ensure_overrides_loaded()
    fields, has := _project_overrides[tab_name]
    if !has do return 0
    return len(fields)
}

project_settings_is_field_modified_from_default :: proc(tab_name, field_name: string, cur_tab_json: []byte) -> bool {
    fb, has_fb := _factory_backdrop_json[tab_name]
    if !has_fb || len(cur_tab_json) == 0 do return false
    def_obj, dok := _parse_json_obj(fb, context.temp_allocator)
    cur_obj, cok := _parse_json_obj(cur_tab_json, context.temp_allocator)
    if !dok || !cok do return false
    def_v, has_d := def_obj[field_name]
    cur_v, has_c := cur_obj[field_name]
    if !has_d || !has_c do return false
    opts := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}
    db, derr := json.marshal(def_v, opts, context.temp_allocator)
    cb, cerr := json.marshal(cur_v, opts, context.temp_allocator)
    if derr != nil || cerr != nil do return false
    return string(json_canonicalize_floats(db, context.temp_allocator)) != string(json_canonicalize_floats(cb, context.temp_allocator))
}

@(private = "file")
_unmarshal_json_obj_into :: proc(ptr: rawptr, tid: typeid, obj: json.Object) -> bool {
    if ptr == nil || tid == nil do return false
    if ptr_tid, ptr_ok := core.get_pointer_typeid_by_typeid(tid); ptr_ok {
        bytes, ok := _marshal_json_obj_canonical(obj, context.temp_allocator)
        if !ok do return false
        pp := ptr
        return json.unmarshal_any(bytes, any{&pp, ptr_tid}, .JSON, context.allocator) == nil
    }
    return core.unmarshal_value_over_reset(json.Value(obj), ptr, tid, .JSON, context.allocator) == nil
}

@(private = "file")
_apply_single_field_json :: proc(ptr: rawptr, tid: typeid, field_name: string, val: json.Value) -> bool {
    patch_obj := make(json.Object, context.temp_allocator)
    patch_obj[field_name] = val
    return _unmarshal_json_obj_into(ptr, tid, patch_obj)
}

project_settings_set_field_override :: proc(tab_name, field_name: string, enabled: bool, ptr: rawptr, tid: typeid) -> bool {
    if tab_name == "" || field_name == "" || ptr == nil || tid == nil do return false
    project_settings_register_backdrop(tab_name, ptr, tid)
    _ensure_overrides_loaded()

    prev := context.allocator
    if enabled {
        cur_bytes, ok := _marshal_canonical_any(ptr, tid, context.temp_allocator)
        if !ok do return false
        cur_obj, cok := _parse_json_obj(cur_bytes, context.temp_allocator)
        if !cok do return false
        val, has_f := cur_obj[field_name]
        if !has_f do return false
        opts := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}
        raw_f, merr := json.marshal(val, opts, context.temp_allocator)
        if merr != nil do return false
        canon := json_canonicalize_floats(raw_f, context.temp_allocator)

        context.allocator = runtime.default_allocator()
        fmap, has_tab := _project_overrides[tab_name]
        if !has_tab {
            fmap = make(map[string][]byte)
        }
        if old_b, has_k := fmap[field_name]; has_k {
            delete(old_b)
        }
        fc := make([]byte, len(canon))
        copy(fc, canon)
        if field_name in fmap {
            fmap[field_name] = fc
        } else {
            fmap[strings.clone(field_name)] = fc
        }
        if has_tab {
            _project_overrides[tab_name] = fmap
        } else {
            _project_overrides[strings.clone(tab_name)] = fmap
        }
        context.allocator = prev

        _ = _save_overrides_file()
        pdir := _project_dir_resolved(context.temp_allocator)
        if _test_project_dir != "" || has_active_project() || os.is_dir(pdir) {
            _ = os.make_directory_all(pdir)
            _ = os.write_entire_file(_settings_file_in(pdir, tab_name), cur_bytes)
        }
        return true
    } else {
        context.allocator = runtime.default_allocator()
        if fmap, has_tab := &_project_overrides[tab_name]; has_tab {
            if field_name in fmap {
                old_k, old_v := delete_key(fmap, field_name)
                delete(old_k)
                delete(old_v)
            }
            if len(fmap^) == 0 {
                delete(fmap^)
                if tab_name in _project_overrides {
                    tk, _ := delete_key(&_project_overrides, tab_name)
                    delete(tk)
                }
            }
        }
        context.allocator = prev

        // Restore live struct field back to Tier 2 Engine Setting (or Factory Backdrop).
        base_bytes: []byte
        if tb, has_t2 := _engine_tier_json[tab_name]; has_t2 && len(tb) > 0 {
            base_bytes = tb
        } else if fb, has_fb := _factory_backdrop_json[tab_name]; has_fb {
            base_bytes = fb
        }
        if base_obj, bok := _parse_json_obj(base_bytes, context.temp_allocator); bok {
            if val, has_f := base_obj[field_name]; has_f {
                _ = _apply_single_field_json(ptr, tid, field_name, val)
            }
        }
        _ = _save_overrides_file()
        return project_settings_save(tab_name, ptr, tid)
    }
}

project_settings_reset_field_to_default :: proc(tab_name, field_name: string, ptr: rawptr, tid: typeid) -> bool {
    if ptr == nil || tid == nil do return false
    fb, has_fb := _factory_backdrop_json[tab_name]
    if !has_fb do return false
    def_obj, dok := _parse_json_obj(fb, context.temp_allocator)
    if !dok do return false
    val, has_f := def_obj[field_name]
    if !has_f do return false
    if !_apply_single_field_json(ptr, tid, field_name, val) do return false
    return project_settings_save(tab_name, ptr, tid)
}

project_settings_reset_tab_to_defaults :: proc(tab_name: string, ptr: rawptr, tid: typeid, clear_overrides: bool) -> bool {
    if ptr == nil || tid == nil do return false
    _ensure_overrides_loaded()
    if clear_overrides {
        prev := context.allocator
        context.allocator = runtime.default_allocator()
        if tab_name in _project_overrides {
            tk, fmap := delete_key(&_project_overrides, tab_name)
            for fk, fv in fmap {
                delete(fk)
                delete(fv)
            }
            delete(fmap)
            delete(tk)
        }
        context.allocator = prev
        _ = _save_overrides_file()
    }
    if fb, has_fb := _factory_backdrop_json[tab_name]; has_fb {
        if def_obj, dok := _parse_json_obj(fb, context.temp_allocator); dok {
            if !clear_overrides {
                if ovr_fields, has_ovr := _project_overrides[tab_name]; has_ovr {
                    for fname, fbytes in ovr_fields {
                        prev := context.allocator
                        context.allocator = context.temp_allocator
                        parsed_val, perr := json.parse(fbytes, .JSON, true)
                        context.allocator = prev
                        if perr == nil {
                            def_obj[fname] = parsed_val
                        }
                    }
                }
            }
            _ = _unmarshal_json_obj_into(ptr, tid, def_obj)
        }
    }
    return project_settings_save(tab_name, ptr, tid)
}

// --- Time -------------------------------------------------------------------

Time_Settings :: struct {
    fixed_rate: f32 `decor:min(1)`,       // fixed simulation ticks per second (docs/FixedTick.md)
    time_scale: f32 `decor:range(0, 10)`, // global time dilation (1.0 = normal, 0.0 = frozen, <1 = slow-mo, >1 = fast-forward)
}

@(project_settings={name="Time"})
time_settings := Time_Settings{fixed_rate = FIXED_RATE_DEFAULT, time_scale = 1.0}

// The editor's MCP bridge (docs/McpBridge.md): a single on/off switch for the
// whole endpoint. Off means the editor does not listen at all, so no agent can
// reach the editor by any tool — enforceable with no per-tool knowledge.
// There is deliberately no read/write split: a per-tool "does this mutate"
// flag would be hand-classified, and a mislabeled tool would sneak past it.
// Every tool mutation goes through the editor's undo stack, so agent edits are
// Ctrl+Z-able like manual ones.
Mcp_Settings :: struct {
    enabled: bool `decor:tooltip(desc="Let agent clients (Claude Code and other MCP clients) connect to this editor over a loopback socket: read scene state, take screenshots, and make undoable edits. Off stops the editor listening entirely. Takes effect on editor restart.")`,
}

@(project_settings={name="MCP"})
mcp_settings := Mcp_Settings{enabled = true}

@(private = "file")
_time_settings_loaded: bool

// Lazy so every binary that ticks (game, editor, tests) picks the file up on
// first use with no init wiring.
_ensure_time_settings :: proc() {
    if _time_settings_loaded do return
    _time_settings_loaded = true
    project_settings_load("Time", &time_settings)
}

// Loads ProjectSettings/serialization.json before anything is loaded from
// data. A missing file keeps the initializer above.
@(phase={key=SerializationInit, order=-300})
_serialization_settings_load :: proc() {
    project_settings_load("Serialization", &core.serialization_settings)
}

