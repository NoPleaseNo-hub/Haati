package engine

import "base:runtime"
import "core:encoding/json"
import "log"

// =============================================================================
// Versioned Scene Schema Migration Registry (`SCENE_SCHEMA_VERSION :: 2`)
// =============================================================================

SCENE_SCHEMA_VERSION :: 2

Scene_Migration_Fn :: #type proc(root_obj: ^json.Object, allocator: runtime.Allocator) -> bool

_Scene_Migration_Step :: struct {
	from_version: int,
	to_version:   int,
	fn:           Scene_Migration_Fn,
}

@(private = "file")
_scene_migrations: [dynamic]_Scene_Migration_Step

scene_register_migration :: proc(from_version, to_version: int, fn: Scene_Migration_Fn) {
	if fn == nil || to_version <= from_version do return
	context.allocator = runtime.default_allocator()
	for s in _scene_migrations {
		if s.from_version == from_version && s.to_version == to_version {
			return
		}
	}
	append(&_scene_migrations, _Scene_Migration_Step{
		from_version = from_version,
		to_version   = to_version,
		fn           = fn,
	})
}

@(private = "file")
_migrate_v1_to_v2 :: proc(root_obj: ^json.Object, allocator: runtime.Allocator) -> bool {
	_ = allocator
	if root_obj == nil do return false
	root_obj["schema_version"] = json.Integer(2)
	return true
}

@(private = "file")
_ensure_default_migrations :: proc() {
	scene_register_migration(0, 2, _migrate_v1_to_v2)
	scene_register_migration(1, 2, _migrate_v1_to_v2)
}

scene_migration_shutdown :: proc() {
	if _scene_migrations != nil {
		delete(_scene_migrations)
		_scene_migrations = nil
	}
}

// Migrates raw `.scene` JSON bytes forward to `SCENE_SCHEMA_VERSION`.
// Zero-copy fast path when `"schema_version"` is already >= `SCENE_SCHEMA_VERSION`.
scene_migrate_json_bytes :: proc(
	data:      []u8,
	allocator := context.temp_allocator,
) -> (migrated: []u8, from_ver: int, changed: bool, ok: bool) {
	if len(data) == 0 do return data, 0, false, false

	// Fast peek with temporary allocator to avoid copying or rebuilding current-version scenes.
	tmp_val, perr := json.parse(data, .JSON, false, context.temp_allocator)
	if perr != nil {
		return data, 0, false, false
	}
	root_obj, is_obj := tmp_val.(json.Object)
	if !is_obj {
		return data, 0, false, false
	}

	ver := 0
	if sv, has := root_obj["schema_version"]; has {
		#partial switch n in sv {
		case json.Integer:
			ver = int(n)
		case json.Float:
			ver = int(n)
		}
	}
	from_ver = ver

	if ver >= SCENE_SCHEMA_VERSION {
		return data, from_ver, false, true
	}

	_ensure_default_migrations()

	// Re-parse into caller's allocator when mutation is needed, or mutate temp tree & marshal.
	work_val, werr := json.parse(data, .JSON, false, context.temp_allocator)
	if werr != nil do return data, from_ver, false, false
	work_obj, work_is_obj := work_val.(json.Object)
	if !work_is_obj do return data, from_ver, false, false

	cur := ver
	steps := 0
	for cur < SCENE_SCHEMA_VERSION && steps < 16 {
		steps += 1
		advanced := false
		// Prefer registered step matching exact `cur`, choosing highest `to_version`.
		best_idx := -1
		for s, idx in _scene_migrations {
			if s.from_version == cur {
				if best_idx < 0 || s.to_version > _scene_migrations[best_idx].to_version {
					best_idx = idx
				}
			}
		}
		if best_idx >= 0 {
			step := _scene_migrations[best_idx]
			if step.fn(&work_obj, context.temp_allocator) {
				cur = step.to_version
				advanced = true
			}
		} else {
			// Generic forward step so older `.scene` files remain loadable.
			cur += 1
			work_obj["schema_version"] = json.Integer(cur)
			advanced = true
		}
		if !advanced do break
	}

	if cur < SCENE_SCHEMA_VERSION {
		cur = SCENE_SCHEMA_VERSION
		work_obj["schema_version"] = json.Integer(SCENE_SCHEMA_VERSION)
	}

	out, merr := json.marshal(json.Value(work_obj), {spec = .JSON, pretty = true, use_spaces = true, spaces = 2}, allocator)
	if merr != nil {
		log.errorf("[SceneMigration] failed to marshal migrated v%d->v%d scene: %v", from_ver, cur, merr)
		return data, from_ver, false, false
	}
	return out, from_ver, true, true
}
