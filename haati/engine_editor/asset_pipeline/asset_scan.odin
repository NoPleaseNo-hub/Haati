package asset_pipeline

// The AssetDB's scan/refresh machinery — editor-side, like the import
// drivers: a game binary runs the catalog pipeline only (app.odin boots from
// library/catalog.json or an export) and never scans assets/ or mints metas.
// Storage and lookups (guid<->path maps, root-info index, meta primitives)
// stay in the engine; this file is the driver that fills them from the tree.

import "core:encoding/uuid"
import "core:os"
import "core:path/filepath"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:sync"
import "haati:engine"
import "haati:engine/log"

@(private = "file")
_refresh_thread: ^thread.Thread
@(private = "file")
_async_walk: ^_Async_Walk
@(private = "file")
_async_done: bool

_Async_Walk :: struct {
	files:         map[string]engine.Asset_File_Stamp,
	metas:         [dynamic]string,
	package_roots: [dynamic]string,
	root_path:     string,
}

@(private = "file")
_free_async_walk :: proc(w: ^_Async_Walk) {
	if w == nil do return
	for k, _ in w.files {
		delete(k)
	}
	delete(w.files)
	for m in w.metas {
		delete(m)
	}
	delete(w.metas)
	for r in w.package_roots {
		delete(r)
	}
	delete(w.package_roots)
	delete(w.root_path)
}

@(private = "file")
_is_scene_or_level_tree :: proc(dir_path: string) -> bool {
	return strings.contains(dir_path, "/Scenes") || strings.contains(dir_path, "/Levels")
}

@(private = "file")
_is_scene_tree_asset :: proc(name: string) -> bool {
	return strings.has_suffix(name, ".scene") || strings.has_suffix(name, ".prefab") || strings.has_suffix(name, ".mat")
}

@(private = "file")
_async_db_walk :: proc(dir_path: string, walk: ^_Async_Walk) {
	handle, err := os.open(dir_path)
	if err != nil do return
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)

	scene_tree := _is_scene_or_level_tree(dir_path)
	metas_by_name := make(map[string]os.File_Info, context.allocator)
	defer delete(metas_by_name)
	for entry in entries {
		if strings.has_suffix(entry.name, ".meta") {
			metas_by_name[entry.name] = entry
		}
	}
	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue
		full_path := slashpath.join({dir_path, entry.name}, context.allocator)
		if entry.type == .Directory {
			if scene_tree {
				_async_db_walk(full_path, walk)
				delete(full_path)
			} else {
				walk.files[full_path] = {}
				_async_db_walk(full_path, walk)
			}
		} else if strings.has_suffix(entry.name, ".meta") {
			if scene_tree && !_is_scene_tree_asset(strings.trim_suffix(entry.name, ".meta")) {
				delete(full_path)
				continue
			}
			append(&walk.metas, full_path)
		} else {
			if scene_tree && !_is_scene_tree_asset(entry.name) {
				delete(full_path)
				continue
			}
			stamp := engine.Asset_File_Stamp{mtime = entry.modification_time, size = entry.size}
			meta_key := strings.concatenate({entry.name, ".meta"}, context.allocator)
			if m, has := metas_by_name[meta_key]; has {
				stamp.meta_mtime, stamp.meta_size = m.modification_time, m.size
			}
			delete(meta_key)
			walk.files[full_path] = stamp
		}
	}
}

@(private = "file")
_async_refresh_worker_proc :: proc(data: rawptr) {
	w := cast(^_Async_Walk)data
	if w == nil do return

	_async_db_walk(w.root_path, w)
	for root in w.package_roots {
		_async_db_walk(root, w)
	}

	sync.atomic_store(&_async_done, true)
}

// Asynchronously refreshes the asset database in a background worker thread.
// Used when the window regains focus so that disk scanning never pauses the main render loop.
asset_db_refresh_async :: proc() {
	if engine.asset_db.pipeline == .Catalog do return
	if _refresh_thread != nil do return // already running

	w := new(_Async_Walk)
	w.files = make(map[string]engine.Asset_File_Stamp)
	w.metas = make([dynamic]string)
	w.package_roots = make([dynamic]string)
	w.root_path = strings.clone(engine.asset_db.root_path)

	for root in engine.asset_db_package_roots() {
		append(&w.package_roots, strings.clone(root.assets_path))
	}

	_async_walk = w
	sync.atomic_store(&_async_done, false)
	_refresh_thread = thread.create_and_start_with_data(w, _async_refresh_worker_proc)
}

// Polled once per frame on the main thread. When the async worker finishes,
// diffs the file tree in-memory in fractions of a millisecond with zero frame hitch.
// Returns true if any files or directories were created, modified, or deleted.
asset_db_refresh_tick :: proc() -> bool {
	if _refresh_thread == nil do return false
	if !sync.atomic_load(&_async_done) do return false

	thread.join(_refresh_thread)
	thread.destroy(_refresh_thread)
	_refresh_thread = nil

	any_changes := false
	if _async_walk != nil {
		any_changes = _apply_walk_diff(_async_walk.files, _async_walk.metas[:])
		_free_async_walk(_async_walk)
		free(_async_walk)
		_async_walk = nil
	}
	sync.atomic_store(&_async_done, false)
	return any_changes
}

asset_db_refresh_shutdown :: proc() {
	if _refresh_thread != nil {
		thread.join(_refresh_thread)
		thread.destroy(_refresh_thread)
		_refresh_thread = nil
	}
	if _async_walk != nil {
		_free_async_walk(_async_walk)
		free(_async_walk)
		_async_walk = nil
	}
	sync.atomic_store(&_async_done, false)
}

// Incremental refresh (Unity model): enumerate the tree (stat only), diff
// against file_state, and process only the deltas — new assets get metas +
// registration, changed scene assets re-index, deleted assets unregister and
// their orphaned metas are removed. Renames arrive as delete+create; the meta
// travels with the file (project view moves it), so the guid stays stable.
asset_db_refresh :: proc() {
	if engine.asset_db.pipeline == .Catalog do return
	if _refresh_thread != nil {
		asset_db_refresh_tick()
		if _refresh_thread != nil {
			thread.join(_refresh_thread)
			asset_db_refresh_tick()
		}
		return
	}

	walk: _Db_Walk
	walk.files = make(map[string]engine.Asset_File_Stamp, context.temp_allocator)
	walk.metas = make([dynamic]string, context.temp_allocator)
	_db_walk(engine.asset_db.root_path, &walk)
	// Installed packages: each packages/<name>/assets is a further root,
	// scanned by the same machinery (docs/Plugins.md).
	for root in engine.asset_db_package_roots() {
		_db_walk(root.assets_path, &walk)
	}

	_apply_walk_diff(walk.files, walk.metas[:])
}

@(private = "file")
_apply_walk_diff :: proc(files: map[string]engine.Asset_File_Stamp, metas: []string) -> bool {
	created, modified, deleted: int
	before := make(map[string]engine.Asset_File_Stamp, len(engine.asset_db.file_state), context.temp_allocator)
	for path, stamp in engine.asset_db.file_state do before[path] = stamp

	// Deletions. Collect first — removing while iterating is unsafe.
	removed := make([dynamic]string, context.temp_allocator)
	for path in engine.asset_db.file_state {
		if path not_in files {
			append(&removed, path)
		}
	}
	// A rename arrives as a removal plus a creation under the same guid, so
	// whether an asset is really gone is only known after the creations below.
	Removed :: struct {
		guid: engine.Asset_GUID,
		path: string,
	}
	gone := make([dynamic]Removed, context.temp_allocator)
	for path in removed {
		if guid, ok := engine.asset_db.path_to_guid[path]; ok {
			append(&gone, Removed{engine.Asset_GUID(guid), strings.clone(path, context.temp_allocator)})
		}
		engine._asset_removed(path)
		old_key, _ := delete_key(&engine.asset_db.file_state, path)
		delete(old_key)
		deleted += 1
	}

	// Creations and modifications: REGISTER first, INDEX second. Indexing a
	// variant flattens it, which resolves its BASE by guid->path — if the base
	// hasn't been registered yet (map iteration order is random), the flatten
	// fails and the variant silently drops from the index for that run.
	changed := make([dynamic]string, context.temp_allocator)
	for path, stamp in files {
		old, existed := engine.asset_db.file_state[path]
		if !existed {
			_ensure_meta(path)
			engine.asset_db.file_state[strings.clone(path)] = _with_meta_stamp(path, stamp)
			append(&changed, path)
			created += 1
		} else if old != stamp {
			_ensure_meta(path) // re-reads the meta; guid stays stable
			engine.asset_db.file_state[path] = _with_meta_stamp(path, stamp) // key exists; stored key is reused
			append(&changed, path)
			modified += 1
		}
	}
	slice.sort(changed[:])
	for path in changed {
		engine._reindex_if_scene(path)
		engine.material_path_changed(path) // externally edited .mat: drop the cache entry
		engine.shader_path_changed(path)   // edited .glsl: evict (the hook below reimports)
		for hook in engine._path_changed_hooks do hook(path)
	}
	if len(changed) > 0 {
		engine.asset_db_clear_missing_cache()
	}
	if modified > 0 {
		engine._artifact_index_batch_set(true)
		for path in changed {
			if old, existed := before[path]; !existed || old == engine.asset_db.file_state[path] do continue
			if is_importable_extension(filepath.ext(path)) do _ = asset_pipeline_import_asset(path)
		}
		engine._artifact_index_batch_set(false)
		engine._artifact_index_save()
	}
	for r in gone {
		if uuid.Identifier(r.guid) in engine.asset_db.guid_to_path do continue // renamed or moved
		for hook in engine._asset_gone_hooks do hook(r.guid, r.path)
	}

	// Orphaned metas: a .meta whose asset (file or folder) is gone.
	for meta in metas {
		asset_path := strings.trim_suffix(meta, ".meta")
		if asset_path not_in files {
			os.remove(meta)
			log.infof("[AssetDB] Removed orphaned meta: %s", meta)
		}
	}

	if created + modified + deleted > 0 {
		// Through the log package: visible in the editor console/status bar,
		// not just the terminal.
		log.infof("[AssetDB] Refreshed: +%d ~%d -%d (%d assets)", created, modified, deleted, len(engine.asset_db.path_to_guid))
		// Keep the in-place catalog current (asset_catalog_auto): every app
		// run and every run config stages from it.
		engine._asset_catalog_auto_write()
		return true
	}
	return false
}

_Db_Walk :: struct {
	files: map[string]engine.Asset_File_Stamp, // temp; folders carry a zero stamp
	metas: [dynamic]string,                    // temp
}

_db_walk :: proc(dir_path: string, walk: ^_Db_Walk) {
	handle, err := os.open(dir_path)
	if err != nil do return
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	scene_tree := _is_scene_or_level_tree(dir_path)
	metas := make(map[string]os.File_Info, context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, ".meta") do metas[entry.name] = entry
	}
	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue
		full_path := slashpath.join({dir_path, entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			if !scene_tree {
				walk.files[full_path] = {}
			}
			_db_walk(full_path, walk)
		} else if strings.has_suffix(entry.name, ".meta") {
			if scene_tree && !_is_scene_tree_asset(strings.trim_suffix(entry.name, ".meta")) do continue
			append(&walk.metas, full_path)
		} else {
			if scene_tree && !_is_scene_tree_asset(entry.name) do continue
			stamp := engine.Asset_File_Stamp{mtime = entry.modification_time, size = entry.size}
			if meta, has := metas[strings.concatenate({entry.name, ".meta"}, context.temp_allocator)]; has {
				stamp.meta_mtime, stamp.meta_size = meta.modification_time, meta.size
			}
			walk.files[full_path] = stamp
		}
	}
}

@(private = "file")
_with_meta_stamp :: proc(path: string, stamp: engine.Asset_File_Stamp) -> engine.Asset_File_Stamp {
	out := stamp
	if info, err := os.stat(strings.concatenate({path, ".meta"}, context.temp_allocator), context.temp_allocator); err == nil {
		out.meta_mtime, out.meta_size = info.modification_time, info.size
	}
	return out
}

@(private = "file")
_ensure_meta :: proc(asset_path: string) {
	meta_path := strings.concatenate({asset_path, ".meta"})
	defer delete(meta_path)

	if guid, ok := engine._read_meta(meta_path); ok {
		engine._register_asset(asset_path, guid)
	} else {
		guid := engine._generate_guid()
		engine._write_meta(meta_path, guid)
		engine._register_asset(asset_path, guid)
	}

	// Upgrade to an importer meta (guid + importer + settings) — the import
	// driver is this same package now.
	asset_pipeline_ensure_import_meta(asset_path)
	// A model's clip guids come from its meta, so a fresh clone resolves clip
	// references from the scan alone, before any import runs.
	engine.asset_db_register_model_subs(asset_path)
}
