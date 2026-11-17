package tests

import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "../engine"

// HTSCN001 binary scene encoding, O(1) embedded UTF-8 summary (`deps:` + hierarchy),
// lossless round-trip decode, and CRC32 corruption / truncation rejection without leaking.
@(test)
test_htscn001_binary_scene_roundtrip_summary_and_corruption_guard :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	prefab_id, _ := uuid.read("11111111-2222-4333-8444-555555555555")
	prefab_guid := engine.Asset_GUID(prefab_id)

	sf: engine.SceneFile
	sf.schema_version = engine.SCENE_SCHEMA_VERSION
	sf.root = 100

	tr := engine.Transform{
		local_id     = 100,
		name         = strings.clone("WatchWolfRoot"),
		is_active    = true,
		position     = {1.5, 2.25, -3.5},
		rotation     = {0, 0, 0, 1},
		scale        = {1, 1, 1},
		render_layer = 3,
	}
	append(&tr.children, engine.Ref{pptr = engine.PPtr{local_id = 200}})
	append(&tr.components, engine.Owned{local_id = 300})
	append(&sf.transforms, tr)

	comp_obj := make(json.Object)
	comp_obj[strings.clone("__type")] = json.String(strings.clone("9f36ee91-34b6-4636-a360-ee872af0436b"))
	comp_base := make(json.Object)
	comp_base[strings.clone("local_id")] = json.Integer(300)
	comp_obj[strings.clone("base")] = comp_base
	comp_obj[strings.clone("intensity")] = json.Float(2.5)
	append(&sf.components, comp_obj)

	ns := engine.NestedScene{
		local_id           = 500,
		local_id_in_parent = 500,
		source_prefab      = prefab_guid,
		transform_parent   = 100,
		sibling_index      = 1,
	}
	append(&ns.overrides, engine.Override{
		target        = engine.PPtr{guid = prefab_guid, local_id = 42},
		property_path = strings.clone("speed"),
		value         = json.Float(9.25),
	})
	append(&sf.nested_scenes, ns)

	append(&sf.breadcrumbs, engine.Breadcrumb{
		local_id       = 700,
		scene_source   = engine.PPtr{guid = prefab_guid, local_id = 42},
		scene_instance = 500,
	})
	defer engine.scene_file_destroy(&sf)

	bin, bok := engine.scene_binary_encode(&sf)
	testing.expect(t, bok && len(bin) >= engine.SCENE_BINARY_HEADER_SIZE, "scene_binary_encode must succeed")
	if !bok do return
	defer delete(bin)

	testing.expect(t, engine.scene_bytes_is_binary(bin), "encoded buffer must carry HTSCN001 magic")

	summary, sok := engine.scene_extract_summary(bin, context.temp_allocator)
	testing.expect(t, sok, "scene_extract_summary must succeed on encoded HTSCN001")
	testing.expect(t, strings.contains(summary, "WatchWolfRoot"), "summary must list transform name")
	testing.expect(t, strings.contains(summary, "deps: 11111111-2222-4333-8444-555555555555"), "summary must emit deps: cross-asset prefab GUID")

	dec_sf: engine.SceneFile
	uerr := engine.scene_file_unmarshal(bin, &dec_sf)
	testing.expect(t, uerr == nil, "scene_file_unmarshal must decode HTSCN001 cleanly")
	if uerr != nil do return
	defer engine.scene_file_destroy(&dec_sf)

	testing.expect_value(t, dec_sf.schema_version, sf.schema_version)
	testing.expect_value(t, dec_sf.root, sf.root)
	testing.expect_value(t, len(dec_sf.transforms), 1)
	testing.expect_value(t, dec_sf.transforms[0].name, "WatchWolfRoot")
	testing.expect_value(t, len(dec_sf.nested_scenes), 1)
	testing.expect(t, dec_sf.nested_scenes[0].source_prefab == prefab_guid, "prefab GUID round-trips bit-exact")
	testing.expect_value(t, len(dec_sf.breadcrumbs), 1)
	testing.expect_value(t, len(dec_sf.components), 1)

	// Flip 1 byte in payload -> CRC32 guard must reject cleanly without leaking.
	corrupt := make([]u8, len(bin), context.temp_allocator)
	copy(corrupt, bin)
	corrupt[len(corrupt) - 1] ~= 0x55
	corrupt_sf: engine.SceneFile
	testing.expect(t, !engine.scene_binary_decode(corrupt, &corrupt_sf), "CRC32 must reject 1-bit payload corruption")
	trunc_sf: engine.SceneFile
	testing.expect(t, !engine.scene_binary_decode(bin[:len(bin) - 4], &trunc_sf), "truncated payload must be rejected cleanly")
}
