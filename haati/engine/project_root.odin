package engine

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "log"

// Locating the engine root (Haati_Engine/ or pre-split moonhug-main/), active
// external game project root (<Parent>/<ProjectName>/), and managing the
// Project Hub launcher state (`<engine_root>/UserSettings/launcher.json`).
//
// Two-Root Design:
// - `engine_root()` ALWAYS resolves the Haati engine repository root (containing
//   `haati/` and `tools/mh/mh.odin`) so `tools/odin`, `plugins/`, `haati/packages/`,
//   `builds/`, and `EditorIcon.png` live cleanly inside `Haati_Engine/`.
// - `active_project_root()` holds the external user game project currently open
//   (when `has_active_project()` is true), and `cwd` is set to it so `"assets"`,
//   `"library"`, `"ProjectSettings"`, `"UserSettings"`, and `"imgui.ini"` stay
//   100% isolated inside the project folder with ZERO persistent junctions back
//   into `Haati_Engine/`.
// - When no `last_project_path` exists (or `--project-hub` / Shift on launch),
//   the editor enters Startup Project Hub mode with `cwd == engine_haati_dir()`.

@(private = "file")
_ROOT_MARKERS :: [?]string{"assets", "ProjectSettings"}

@(private = "file") _cached_engine_root: string
@(private = "file") _active_project_root: string
@(private = "file") _active_project_name: string
@(private = "file") _project_hub_startup_mode: bool

@(private = "file")
_norm_slashes :: proc(p: string, allocator := context.temp_allocator) -> string {
    if p == "" do return strings.clone("", allocator)
    s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
    for len(s) > 1 && strings.has_suffix(s, "/") {
        if len(s) == 3 && s[1] == ':' do break
        s = s[:len(s)-1]
    }
    res, _ := strings.clone(s, allocator)
    return res
}

// paths_equal compares two filesystem paths after cleaning/normalizing slashes
// (case-insensitive on Windows).
paths_equal :: proc(a, b: string) -> bool {
    if a == "" && b == "" do return true
    if a == "" || b == "" do return false
    ca, cb: string
    {
        context.allocator = context.temp_allocator
        ca, _ = filepath.clean(a, context.temp_allocator)
        cb, _ = filepath.clean(b, context.temp_allocator)
    }
    na := _norm_slashes(ca, context.temp_allocator)
    nb := _norm_slashes(cb, context.temp_allocator)
    when ODIN_OS == .Windows {
        return strings.equal_fold(na, nb)
    } else {
        return na == nb
    }
}

@(private = "file")
_is_project_root :: proc(dir: string) -> bool {
    for marker in _ROOT_MARKERS {
        p, err := filepath.join({dir, marker}, context.temp_allocator)
        if err != nil || !os.is_dir(p) do return false
    }
    return true
}

// project_root_find returns the haati/ directory at or above `start`.
project_root_find :: proc(start: string, allocator := context.temp_allocator) -> (root: string, ok: bool) {
    dir := start
    for {
        if _is_project_root(dir) {
            r, _ := strings.clone(dir, allocator)
            return r, true
        }
        for child_name in ([?]string{"haati", "moonhug"}) {
            if nested, jerr := filepath.join({dir, child_name}, context.temp_allocator); jerr == nil && _is_project_root(nested) {
                r, _ := strings.clone(nested, allocator)
                return r, true
            }
        }
        parent: string
        {
            context.allocator = context.temp_allocator
            parent = filepath.dir(dir)
        }
        if parent == dir do return "", false
        dir = parent
    }
}

// project_chdir_root anchors the process at the haati/ directory (used by headless
// tools/tests; the editor uses `editor_boot_resolve_roots` so missing projects
// open the Project Hub instead of panicking).
project_chdir_root :: proc() -> string {
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        panic("cannot read the working directory")
    }
    found, ok := project_root_find(cwd)
    if !ok {
        if exe_dir, eerr := os.get_executable_directory(context.temp_allocator); eerr == nil && exe_dir != "" {
            found, ok = project_root_find(exe_dir)
        }
    }
    if !ok {
        log.errorf(
            "cannot locate the haati project directory from cwd %q — looked for a directory containing both %q and %q, here and in every parent",
            cwd,
            _ROOT_MARKERS[0],
            _ROOT_MARKERS[1],
        )
        panic("no haati project directory found")
    }
    if found == cwd do return found
    if serr := os.set_working_directory(found); serr != nil {
        log.errorf("cannot enter the haati project directory %q: %v", found, serr)
        panic("cannot enter the haati project directory")
    }
    log.infof("[startup] working directory normalized: %q -> %q", cwd, found)
    return found
}

// _resolve_repo_root_from walks upward from `start` checking for `tools/mh/mh.odin`
// or a `haati/` (legacy `moonhug/`) directory.
@(private = "file")
_resolve_repo_root_from :: proc(start: string, allocator := context.temp_allocator) -> (string, bool) {
    if start == "" do return "", false
    dir := start
    for {
        mh_probe, merr := filepath.join({dir, "tools", "mh", "mh.odin"}, context.temp_allocator)
        if merr == nil && os.exists(mh_probe) {
            return _norm_slashes(dir, allocator), true
        }
        for child_name in ([?]string{"haati", "moonhug"}) {
            child, jerr := filepath.join({dir, child_name}, context.temp_allocator)
            if jerr == nil && os.is_dir(child) {
                return _norm_slashes(dir, allocator), true
            }
        }
        parent: string
        {
            context.allocator = context.temp_allocator
            parent = filepath.dir(dir)
        }
        if parent == dir do break
        dir = parent
    }
    return "", false
}

// resolve_repo_root returns the cached engine root (or walks up from exe_dir,
// then cwd) containing `tools/mh/mh.odin` or `haati/`.
resolve_repo_root :: proc(allocator := context.temp_allocator) -> string {
    if _cached_engine_root != "" {
        r, _ := strings.clone(_cached_engine_root, allocator)
        return r
    }
    // Check executable directory FIRST so launching builds/Haati.exe against an
    // external project cwd still pins to this engine checkout.
    if exe_dir, eerr := os.get_executable_directory(context.temp_allocator); eerr == nil && exe_dir != "" {
        if root, ok := _resolve_repo_root_from(exe_dir, allocator); ok {
            return root
        }
    }
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        r, _ := strings.clone("..", allocator)
        return r
    }
    if root, ok := _resolve_repo_root_from(cwd, allocator); ok {
        return root
    }
    parent: string
    {
        context.allocator = context.temp_allocator
        parent = filepath.dir(cwd)
    }
    r, _ := strings.clone(parent, allocator)
    return r
}

// engine_root returns and caches the normalized engine root (`Haati_Engine` or repo root).
engine_root :: proc(allocator := context.temp_allocator) -> string {
    if _cached_engine_root == "" {
        resolved := resolve_repo_root(context.temp_allocator)
        if resolved != "" {
            _cached_engine_root = _norm_slashes(resolved, runtime.default_allocator())
        }
    }
    r, _ := strings.clone(_cached_engine_root, allocator)
    return r
}

engine_haati_dir :: proc(allocator := context.temp_allocator) -> string {
    p, _ := filepath.join({engine_root(context.temp_allocator), "haati"}, context.temp_allocator)
    return _norm_slashes(p, allocator)
}

engine_plugins_dir :: proc(allocator := context.temp_allocator) -> string {
    p, _ := filepath.join({engine_root(context.temp_allocator), "plugins"}, context.temp_allocator)
    return _norm_slashes(p, allocator)
}

// engine_packages_dir returns `"packages"` when cwd is `engine_haati_dir()`, else `<engine_root>/haati/packages`.
engine_packages_dir :: proc(allocator := context.temp_allocator) -> string {
    if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
        if paths_equal(cwd, engine_haati_dir(context.temp_allocator)) {
            r, _ := strings.clone("packages", allocator)
            return r
        }
    }
    p, _ := filepath.join({engine_root(context.temp_allocator), "haati", "packages"}, context.temp_allocator)
    return _norm_slashes(p, allocator)
}

engine_file_path :: proc(rel: string, allocator := context.temp_allocator) -> string {
    p, _ := filepath.join({engine_root(context.temp_allocator), rel}, context.temp_allocator)
    return _norm_slashes(p, allocator)
}

active_project_root :: proc() -> string {
    return _active_project_root
}

has_active_project :: proc() -> bool {
    return _active_project_root != ""
}

is_project_hub_startup :: proc() -> bool {
    return _project_hub_startup_mode
}

active_project_name :: proc() -> string {
    if _active_project_name != "" do return _active_project_name
    return "Haati Engine"
}

// project_slug_from_name normalizes a folder/project name into a valid Odin package slug.
project_slug_from_name :: proc(name: string, allocator := context.temp_allocator) -> string {
    b := strings.builder_make(context.temp_allocator)
    for r in name {
        if r >= 'A' && r <= 'Z' {
            strings.write_byte(&b, u8(r) + 32)
        } else if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' {
            strings.write_byte(&b, u8(r))
        } else if r == '-' || r == ' ' {
            strings.write_byte(&b, '_')
        }
    }
    s := strings.trim(strings.to_string(b), "_")
    if s == "" {
        r, _ := strings.clone("project", allocator)
        return r
    }
    if s[0] >= '0' && s[0] <= '9' {
        pref := strings.concatenate({"p_", s}, context.temp_allocator)
        r, _ := strings.clone(pref, allocator)
        return r
    }
    r, _ := strings.clone(s, allocator)
    return r
}

active_project_slug :: proc(allocator := context.temp_allocator) -> string {
    if _active_project_root != "" {
        base: string
        {
            context.allocator = context.temp_allocator
            base = filepath.base(_active_project_root)
        }
        return project_slug_from_name(base, allocator)
    }
    r, _ := strings.clone("", allocator)
    return r
}

enter_project_hub_startup_mode :: proc() {
    if _active_project_root != "" {
        delete(_active_project_root, runtime.default_allocator())
        _active_project_root = ""
    }
    if _active_project_name != "" {
        delete(_active_project_name, runtime.default_allocator())
        _active_project_name = ""
    }
    _project_hub_startup_mode = true
    haati_dir := engine_haati_dir(context.temp_allocator)
    if haati_dir != "" && os.is_dir(haati_dir) {
        _ = os.set_working_directory(haati_dir)
    }
}

project_roots_shutdown :: proc() {
    if _cached_engine_root != "" {
        delete(_cached_engine_root, runtime.default_allocator())
        _cached_engine_root = ""
    }
    if _active_project_root != "" {
        delete(_active_project_root, runtime.default_allocator())
        _active_project_root = ""
    }
    if _active_project_name != "" {
        delete(_active_project_name, runtime.default_allocator())
        _active_project_name = ""
    }
    _project_hub_startup_mode = false
}

// --- Safe Directory Link Helpers (NTFS Junction on Windows) -----------------

os_create_dir_link :: proc(link_path, target_dir: string) -> bool {
    when ODIN_OS == .Windows {
        abs_target := target_dir
        if resolved, aerr := filepath.abs(target_dir, context.temp_allocator); aerr == nil {
            abs_target = resolved
        }
        win_link, _ := strings.replace_all(link_path, "/", "\\", context.temp_allocator)
        win_target, _ := strings.replace_all(abs_target, "/", "\\", context.temp_allocator)
        p, started := bg_process_start_to_file(".", {"cmd", "/C", "mklink", "/J", win_link, win_target}, nil, "")
        if !started do return false
        exited, code := bg_process_wait(&p, 5000)
        return exited && code == 0
    } else {
        return os.symlink(target_dir, link_path) == nil
    }
}

// os_remove_dir_link removes a junction/symlink WITHOUT traversing into its target.
os_remove_dir_link :: proc(link_path: string) -> bool {
    when ODIN_OS == .Windows {
        win_link, _ := strings.replace_all(link_path, "/", "\\", context.temp_allocator)
        p, started := bg_process_start_to_file(".", {"cmd", "/C", "rmdir", win_link}, nil, "")
        if !started do return false
        exited, code := bg_process_wait(&p, 5000)
        return exited && code == 0
    } else {
        return os.remove(link_path) == nil
    }
}

// --- Launcher Config (`<engine_root>/UserSettings/launcher.json`) -----------

Launcher_Recent_Entry :: struct {
    name:             string,
    path:             string,
    last_opened_unix: i64,
}

Launcher_Config :: struct {
    last_project_path: string,
    recent_projects:   [dynamic]Launcher_Recent_Entry,
}

@(private = "file")
_launcher_config_path :: proc(custom_config_path := "") -> string {
    if custom_config_path != "" do return _norm_slashes(custom_config_path, context.temp_allocator)
    return engine_file_path("UserSettings/launcher.json", context.temp_allocator)
}

launcher_free_config :: proc(cfg: ^Launcher_Config, allocator := context.allocator) {
    if cfg == nil do return
    if cfg.last_project_path != "" {
        delete(cfg.last_project_path, allocator)
    }
    for e in cfg.recent_projects {
        if e.name != "" do delete(e.name, allocator)
        if e.path != "" do delete(e.path, allocator)
    }
    delete(cfg.recent_projects)
    cfg^ = {}
}

launcher_load_config :: proc(custom_config_path := "", allocator := context.allocator) -> Launcher_Config {
    cfg: Launcher_Config
    cfg.recent_projects = make([dynamic]Launcher_Recent_Entry, allocator)
    path := _launcher_config_path(custom_config_path)
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil || len(data) == 0 do return cfg

    parsed: Launcher_Config
    if json.unmarshal(data, &parsed, allocator = context.temp_allocator) != nil {
        return cfg
    }
    if parsed.last_project_path != "" {
        cfg.last_project_path = _norm_slashes(parsed.last_project_path, allocator)
    }
    for entry in parsed.recent_projects {
        if entry.path == "" do continue
        norm_p := _norm_slashes(entry.path, context.temp_allocator)
        dup := false
        for ex in cfg.recent_projects {
            if paths_equal(ex.path, norm_p) {
                dup = true
                break
            }
        }
        if dup do continue
        disp := entry.name
        if disp == "" {
            context.allocator = context.temp_allocator
            disp = filepath.base(norm_p)
        }
        n_copy, _ := strings.clone(disp, allocator)
        p_copy, _ := strings.clone(norm_p, allocator)
        append(&cfg.recent_projects, Launcher_Recent_Entry{
            name             = n_copy,
            path             = p_copy,
            last_opened_unix = entry.last_opened_unix,
        })
    }
    return cfg
}

launcher_save_config :: proc(cfg: ^Launcher_Config, custom_config_path := "") -> bool {
    if cfg == nil do return false
    path := _launcher_config_path(custom_config_path)
    dir: string
    {
        context.allocator = context.temp_allocator
        dir = filepath.dir(path)
    }
    if dir != "" && dir != "." {
        _ = os.make_directory_all(dir)
    }
    opts := json.Marshal_Options{
        spec       = .JSON,
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
    }
    data, merr := json.marshal(cfg^, opts, context.temp_allocator)
    if merr != nil do return false
    return os.write_entire_file(path, data) == nil
}

launcher_record_open_project :: proc(project_dir: string, project_name := "", custom_config_path := "") -> bool {
    if project_dir == "" do return false
    abs_raw, aerr := filepath.abs(project_dir, context.temp_allocator)
    norm_dir := _norm_slashes(abs_raw if aerr == nil else project_dir, context.temp_allocator)

    disp := project_name
    if disp == "" {
        disp = project_read_display_name(norm_dir, context.temp_allocator)
    }
    if disp == "" {
        context.allocator = context.temp_allocator
        disp = filepath.base(norm_dir)
    }

    alloc := runtime.default_allocator()
    cfg := launcher_load_config(custom_config_path, alloc)
    defer launcher_free_config(&cfg, alloc)

    if cfg.last_project_path != "" {
        delete(cfg.last_project_path, alloc)
    }
    cfg.last_project_path, _ = strings.clone(norm_dir, alloc)

    for i := len(cfg.recent_projects) - 1; i >= 0; i -= 1 {
        if paths_equal(cfg.recent_projects[i].path, norm_dir) {
            if cfg.recent_projects[i].name != "" do delete(cfg.recent_projects[i].name, alloc)
            if cfg.recent_projects[i].path != "" do delete(cfg.recent_projects[i].path, alloc)
            ordered_remove(&cfg.recent_projects, i)
        }
    }

    now_unix := time.now()._nsec / 1_000_000_000
    n_copy, _ := strings.clone(disp, alloc)
    p_copy, _ := strings.clone(norm_dir, alloc)
    inject_at(&cfg.recent_projects, 0, Launcher_Recent_Entry{
        name             = n_copy,
        path             = p_copy,
        last_opened_unix = now_unix,
    })

    MAX_RECENTS :: 16
    for len(cfg.recent_projects) > MAX_RECENTS {
        last := pop(&cfg.recent_projects)
        if last.name != "" do delete(last.name, alloc)
        if last.path != "" do delete(last.path, alloc)
    }

    return launcher_save_config(&cfg, custom_config_path)
}

launcher_remove_recent_project :: proc(project_dir: string, custom_config_path := "") -> bool {
    if project_dir == "" do return false
    alloc := runtime.default_allocator()
    cfg := launcher_load_config(custom_config_path, alloc)
    defer launcher_free_config(&cfg, alloc)

    if cfg.last_project_path != "" && paths_equal(cfg.last_project_path, project_dir) {
        delete(cfg.last_project_path, alloc)
        cfg.last_project_path = ""
    }
    for i := len(cfg.recent_projects) - 1; i >= 0; i -= 1 {
        if paths_equal(cfg.recent_projects[i].path, project_dir) {
            if cfg.recent_projects[i].name != "" do delete(cfg.recent_projects[i].name, alloc)
            if cfg.recent_projects[i].path != "" do delete(cfg.recent_projects[i].path, alloc)
            ordered_remove(&cfg.recent_projects, i)
        }
    }
    return launcher_save_config(&cfg, custom_config_path)
}

launcher_clear_last_project :: proc(custom_config_path := "") -> bool {
    alloc := runtime.default_allocator()
    cfg := launcher_load_config(custom_config_path, alloc)
    defer launcher_free_config(&cfg, alloc)
    if cfg.last_project_path != "" {
        delete(cfg.last_project_path, alloc)
        cfg.last_project_path = ""
    }
    return launcher_save_config(&cfg, custom_config_path)
}

// --- Project Manifest (`haati.project`), Validation & Scaffolding ----------

PROJECT_MANIFEST_FILE :: "haati.project"

Project_Manifest :: struct {
    name:           string,
    engine_version: string,
    main_scene:     string,
    created_unix:   i64,
}

project_read_display_name :: proc(dir: string, allocator := context.temp_allocator) -> string {
    if dir == "" {
        r, _ := strings.clone("", allocator)
        return r
    }
    manifest_p, merr := filepath.join({dir, PROJECT_MANIFEST_FILE}, context.temp_allocator)
    if merr == nil {
        if data, rerr := os.read_entire_file(manifest_p, context.temp_allocator); rerr == nil && len(data) > 0 {
            m: Project_Manifest
            if json.unmarshal(data, &m, allocator = context.temp_allocator) == nil && m.name != "" {
                r, _ := strings.clone(m.name, allocator)
                return r
            }
        }
    }
    base: string
    {
        context.allocator = context.temp_allocator
        base = filepath.base(dir)
    }
    r, _ := strings.clone(base, allocator)
    return r
}

project_dir_has_odin_code :: proc(dir: string) -> bool {
    if dir == "" || !os.is_dir(dir) do return false
    _walk_odin :: proc(cur: string, depth: int) -> bool {
        if depth > 2 do return false
        h, err := os.open(cur)
        if err != nil do return false
        defer os.close(h)
        entries, rerr := os.read_dir(h, -1, context.temp_allocator)
        if rerr != nil do return false
        defer os.file_info_slice_delete(entries, context.temp_allocator)
        for e in entries {
            if strings.has_prefix(e.name, ".") do continue
            if e.type == .Directory {
                if e.name == "library" || e.name == "UserSettings" || e.name == "assets" || e.name == "builds" || e.name == "logs" {
                    continue
                }
                sub, jerr := filepath.join({cur, e.name}, context.temp_allocator)
                if jerr == nil && _walk_odin(sub, depth + 1) do return true
            } else if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".odin") {
                return true
            }
        }
        return false
    }
    return _walk_odin(dir, 0)
}

project_is_valid_dir :: proc(dir: string) -> bool {
    if dir == "" || !os.is_dir(dir) do return false
    er := engine_root(context.temp_allocator)
    eh := engine_haati_dir(context.temp_allocator)
    if er != "" && paths_equal(dir, er) do return false
    if eh != "" && paths_equal(dir, eh) do return false

    for marker in ([?]string{PROJECT_MANIFEST_FILE, "assets", "ProjectSettings", "Scenes", "Levels"}) {
        cand, jerr := filepath.join({dir, marker}, context.temp_allocator)
        if jerr == nil && os.exists(cand) do return true
    }
    return project_dir_has_odin_code(dir)
}

project_validate_new_name :: proc(name: string) -> (trimmed: string, err_msg: string, ok: bool) {
    trimmed = strings.trim_space(name)
    if trimmed == "" {
        return "", "Enter a project name.", false
    }
    if trimmed == "." || trimmed == ".." {
        return "", "Project name cannot be '.' or '..'.", false
    }
    for c in trimmed {
        switch c {
        case '<', '>', ':', '"', '/', '\\', '|', '?', '*':
            return "", "Project name cannot contain < > : \" / \\ | ? *", false
        }
        if c < 32 {
            return "", "Project name contains invalid control characters.", false
        }
    }
    upper := strings.to_upper(trimmed, context.temp_allocator)
    for reserved in ([?]string{"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2"}) {
        if upper == reserved {
            return "", "Project name uses a reserved system name.", false
        }
    }
    return trimmed, "", true
}

// project_scaffold_new creates `<parent_dir>/<project_name>` with `haati.project`,
// starter `assets/scenes/main.scene` (+ `.meta` UUID), folders, and initial `editor_settings.json`.
project_scaffold_new :: proc(parent_dir: string, project_name: string, allocator := context.temp_allocator) -> (created_dir: string, err_msg: string, ok: bool) {
    clean_name, v_err, v_ok := project_validate_new_name(project_name)
    if !v_ok {
        return "", v_err, false
    }
    clean_parent := _norm_slashes(strings.trim_space(parent_dir), context.temp_allocator)
    if clean_parent == "" || !os.is_dir(clean_parent) {
        return "", "Parent folder does not exist.", false
    }
    target_raw, jerr := filepath.join({clean_parent, clean_name}, context.temp_allocator)
    if jerr != nil {
        return "", "Invalid target folder path.", false
    }
    target := _norm_slashes(target_raw, context.temp_allocator)
    if os.exists(target) {
        if !os.is_dir(target) {
            return "", "A file with that name already exists at the target path.", false
        }
        if h, oerr := os.open(target); oerr == nil {
            entries, rerr := os.read_dir(h, -1, context.temp_allocator)
            os.close(h)
            if rerr == nil {
                defer os.file_info_slice_delete(entries, context.temp_allocator)
                if len(entries) > 0 {
                    return "", "Target project folder already exists and is not empty.", false
                }
            }
        }
    }

    subdirs := [?]string{
        "",
        "assets",
        "assets/scenes",
        "assets/materials",
        "assets/textures",
        "assets/models",
        "assets/audio",
        "assets/scripts",
        "ProjectSettings",
        "UserSettings",
        "library",
    }
    for sub in subdirs {
        dir_p := target
        if sub != "" {
            dir_p, _ = filepath.join({target, sub}, context.temp_allocator)
        }
        if os.make_directory_all(dir_p) != nil {
            return "", fmt.tprintf("Could not create directory %s", dir_p), false
        }
    }

    context.random_generator = crypto.random_generator()
    scene_guid := uuid.generate_v4()
    scene_guid_str := uuid.to_string(scene_guid, context.temp_allocator)

    meta_json := fmt.tprintf("{\n  \"guid\": %q\n}\n", scene_guid_str)
    meta_path, _ := filepath.join({target, "assets", "scenes", "main.scene.meta"}, context.temp_allocator)
    if os.write_entire_file(meta_path, transmute([]u8)meta_json) != nil {
        return "", "Failed to write main.scene.meta", false
    }

    starter_scene := `{
  "schema_version": 2,
  "root": 1,
  "transforms": [
    {
      "local_id": 1,
      "name": "Root",
      "is_active": true,
      "position": [0.0, 0.0, 0.0],
      "rotation": [0.0, 0.0, 0.0, 1.0],
      "scale": [1.0, 1.0, 1.0],
      "render_layer": 1,
      "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [
        {"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}},
        {"pptr": {"local_id": 4, "guid": "00000000-0000-0000-0000-000000000000"}}
      ],
      "components": []
    },
    {
      "local_id": 2,
      "name": "Main Camera",
      "is_active": true,
      "position": [0.0, 2.0, 8.0],
      "rotation": [0.0, 0.0, 0.0, 1.0],
      "scale": [1.0, 1.0, 1.0],
      "render_layer": 1,
      "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [],
      "components": [{"local_id": 3}]
    },
    {
      "local_id": 4,
      "name": "Directional Light",
      "is_active": true,
      "position": [0.0, 6.0, 0.0],
      "rotation": [-0.38268343, 0.0, 0.0, 0.92387953],
      "scale": [1.0, 1.0, 1.0],
      "render_layer": 1,
      "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
      "children": [],
      "components": [{"local_id": 5}]
    }
  ],
  "nested_scenes": [],
  "breadcrumbs": [],
  "components": [
    {
      "__type": "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d",
      "base": {"enabled": true, "local_id": 3},
      "order": 0,
      "projection": 0,
      "fov": 60.0,
      "orthographic_size": 5.0,
      "near_clip": 0.3,
      "far_clip": 1000.0,
      "clear_color": [0.19, 0.3, 0.47, 1.0],
      "render_layer_mask": 4294967295
    },
    {
      "__type": "9f36ee91-34b6-4636-a360-ee872af0436b",
      "base": {"enabled": true, "local_id": 5},
      "type": 0,
      "color": [1.0, 0.98, 0.92, 1.0],
      "intensity": 1.2,
      "range": 10.0,
      "spot_angle": 30.0,
      "inner_spot_angle": 21.8,
      "ambient": 0.15,
      "cast_shadows": true,
      "shadow_strength": 0.72,
      "shadow_ground_y": 0.0,
      "shadow_bias": 0.0015
    }
  ]
}
`
    scene_path, _ := filepath.join({target, "assets", "scenes", "main.scene"}, context.temp_allocator)
    if os.write_entire_file(scene_path, transmute([]u8)starter_scene) != nil {
        return "", "Failed to write starter assets/scenes/main.scene", false
    }

    init_ed_settings := fmt.tprintf("{\n  \"open_scene_guids\": [%q],\n  \"open_scene_paths\": [\"assets/scenes/main.scene\"]\n}\n", scene_guid_str)
    ed_settings_path, _ := filepath.join({target, "UserSettings", "editor_settings.json"}, context.temp_allocator)
    _ = os.write_entire_file(ed_settings_path, transmute([]u8)init_ed_settings)

    now_unix := time.now()._nsec / 1_000_000_000
    manifest := Project_Manifest{
        name           = clean_name,
        engine_version = "1.0.0",
        main_scene     = "assets/scenes/main.scene",
        created_unix   = now_unix,
    }
    m_opts := json.Marshal_Options{spec = .JSON, pretty = true, use_spaces = true, spaces = 2}
    if m_bytes, merr := json.marshal(manifest, m_opts, context.temp_allocator); merr == nil {
        m_path, _ := filepath.join({target, PROJECT_MANIFEST_FILE}, context.temp_allocator)
        if os.write_entire_file(m_path, m_bytes) != nil {
            return "", "Failed to write haati.project", false
        }
    }

    abs_target := target
    if resolved, aerr := filepath.abs(target, context.temp_allocator); aerr == nil {
        abs_target = _norm_slashes(resolved, context.temp_allocator)
    }
    out_dir, _ := strings.clone(abs_target, allocator)
    return out_dir, "", true
}

// editor_boot_resolve_roots determines whether the editor opens `last_project_path`
// directly or starts in the Project Hub (`--project-hub` or missing/unset last project).
// Never panics on missing project folders.
editor_boot_resolve_roots :: proc(args: []string, custom_launcher_path := "") -> (active_proj: string, hub_mode: bool) {
    _ = engine_root(context.temp_allocator)

    force_hub := false
    cli_proj := ""
    for arg in args {
        if arg == "--project-hub" {
            force_hub = true
        } else if strings.has_prefix(arg, "--project=") {
            cli_proj = strings.trim_space(arg[len("--project="):])
        }
    }
    if force_hub {
        enter_project_hub_startup_mode()
        return "", true
    }

    candidate := cli_proj
    if candidate == "" {
        if env_p, ok := os.lookup_env("HAATI_PROJECT", context.temp_allocator); ok && env_p != "" {
            candidate = strings.trim_space(env_p)
        }
    }
    if candidate == "" {
        alloc := runtime.default_allocator()
        cfg := launcher_load_config(custom_launcher_path, alloc)
        if cfg.last_project_path != "" {
            candidate = strings.clone(cfg.last_project_path, context.temp_allocator)
        }
        launcher_free_config(&cfg, alloc)
    }

    if candidate != "" && os.is_dir(candidate) {
        abs_p := candidate
        if resolved, aerr := filepath.abs(candidate, context.temp_allocator); aerr == nil {
            abs_p = resolved
        }
        norm_p := _norm_slashes(abs_p, context.temp_allocator)
        if os.set_working_directory(norm_p) == nil {
            if _active_project_root != "" do delete(_active_project_root, runtime.default_allocator())
            if _active_project_name != "" do delete(_active_project_name, runtime.default_allocator())
            _active_project_root = strings.clone(norm_p, runtime.default_allocator())
            disp := project_read_display_name(norm_p, context.temp_allocator)
            _active_project_name = strings.clone(disp, runtime.default_allocator())
            _project_hub_startup_mode = false
            _ = launcher_record_open_project(norm_p, disp, custom_launcher_path)
            return _active_project_root, false
        }
    }

    enter_project_hub_startup_mode()
    return "", true
}

// resolve_host_tool locates a bundled/env/PATH CLI binary in deterministic priority order:
// `<repo_root>/<bundled_rel_dir>/<name>[.exe]` -> `$env_var/<name>[.exe]` -> `ODIN_ROOT` (for "odin") -> `PATH`.
resolve_host_tool :: proc(
    name: string,
    bundled_rel_dir: string,
    env_var := "",
    fallback_bare := true,
    allocator := context.temp_allocator,
) -> (string, bool) {
    exe_ext :: ".exe" when ODIN_OS == .Windows else ""
    bin_name := strings.concatenate({name, exe_ext}, context.temp_allocator)

    repo_root := resolve_repo_root(context.temp_allocator)
    if repo_root != "" && bundled_rel_dir != "" {
        bundled, berr := filepath.join({repo_root, bundled_rel_dir, bin_name}, context.temp_allocator)
        if berr == nil && os.exists(bundled) {
            r, _ := strings.clone(bundled, allocator)
            return r, true
        }
    }
    if env_var != "" {
        if custom_dir, custom_ok := os.lookup_env(env_var, context.temp_allocator); custom_ok && custom_dir != "" {
            cand, cerr := filepath.join({custom_dir, bin_name}, context.temp_allocator)
            if cerr == nil && os.exists(cand) {
                r, _ := strings.clone(cand, allocator)
                return r, true
            }
        }
    }
    if name == "odin" {
        root_odin, rerr := filepath.join({ODIN_ROOT, bin_name}, context.temp_allocator)
        if rerr == nil && os.exists(root_odin) {
            r, _ := strings.clone(root_odin, allocator)
            return r, true
        }
    }
    if path_env, found := os.lookup_env("PATH", context.temp_allocator); found {
        sep := ";" when ODIN_OS == .Windows else ":"
        for dir in strings.split(path_env, sep, context.temp_allocator) {
            if dir == "" do continue
            p, perr := filepath.join({dir, bin_name}, context.temp_allocator)
            if perr == nil && os.exists(p) {
                r, _ := strings.clone(p, allocator)
                return r, true
            }
        }
    }
    if fallback_bare {
        r, _ := strings.clone(name, allocator)
        return r, false
    }
    return "", false
}
