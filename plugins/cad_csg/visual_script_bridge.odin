package cad_csg

import "base:runtime"
import "haati:engine"

@(init)
_install_csg_vs_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.visual_script_install_csg_bridge(engine.Visual_Script_CSG_Bridge{
		brush_stamp = _vs_brush_stamp,
	})
}

_vs_brush_stamp :: proc(world_pos: [3]f32, radius, impulse: f32, cut_mat_str: string) -> i32 {
	guid, _ := engine.asset_db_lookup_guid_any(cut_mat_str)
	return i32(csg_trigger_blast(world_pos, max(radius, 0.05), impulse, guid))
}
