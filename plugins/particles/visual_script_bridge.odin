package particles

import "base:runtime"
import "haati:engine"

@(init)
_install_vfx_vs_bridge :: proc "contextless" () {
	context = runtime.default_context()
	engine.visual_script_install_vfx_bridge(engine.Visual_Script_VFX_Bridge{
		emitter_spawn = _vs_emitter_spawn,
	})
}

_vs_emitter_spawn :: proc(target: engine.Transform_Handle, emitter_name: string, rate: f32, burst_count: i32) {
	_ = emitter_name
	_, ps, ok := engine.vs_resolve_entity_comp(engine.Handle(target), ParticleSystem)
	if !ok do return

	if rate >= 0 {
		ps.rate = rate
	}
	if burst_count > 0 {
		if len(ps.bursts) == 0 {
			append(&ps.bursts, Burst{
				time        = 0,
				count_min   = burst_count,
				count_max   = burst_count,
				cycles      = 1,
				probability = 1.0,
			})
		} else {
			ps.bursts[0].count_min   = burst_count
			ps.bursts[0].count_max   = burst_count
			ps.bursts[0].probability = 1.0
		}
	}
	system_play(ps)
}
