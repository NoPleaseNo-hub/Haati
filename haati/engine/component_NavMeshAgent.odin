package engine

import "base:runtime"
import "core:math"
import "core:math/linalg"

// =============================================================================
// NavMeshAgent Component — A* Path Following & AI Steering
// =============================================================================

@(component={max=256, menu="AI/NavMeshAgent"})
@(typ_guid={guid = "7a4e91c2-5b8d-4f13-9c62-3d8a1e5b7f40"})
NavMeshAgent :: struct {
	using base: CompData `inspect:"-"`,

	speed:             f32,
	stopping_distance: f32,
	auto_orient:       bool,
	target_position:   [3]f32,
	has_destination:   bool,

	waypoints:    [dynamic][3]f32 `json:"-" inspect:"-"`,
	waypoint_idx: int `json:"-" inspect:"-"`,
	arrived:      bool `json:"-" inspect:"-"`,
}

reset_NavMeshAgent :: proc(comp: ^NavMeshAgent) {
	cleanup_NavMeshAgent(comp)
	comp.speed             = 4.5
	comp.stopping_distance = 0.25
	comp.auto_orient       = true
}

cleanup_NavMeshAgent :: proc(comp: ^NavMeshAgent) {
	if comp == nil do return
	if comp.waypoints != nil {
		delete(comp.waypoints)
		comp.waypoints = nil
	}
	comp_zero(comp)
}

on_destroy_NavMeshAgent :: proc(comp: ^NavMeshAgent) {
	if comp == nil do return
	if comp.waypoints != nil {
		delete(comp.waypoints)
		comp.waypoints = nil
	}
}

nav_agent_set_destination :: proc(w: ^World, tH: Transform_Handle, goal: [3]f32) -> bool {
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return false
	_, agent := transform_get_comp(tH, NavMeshAgent)
	if agent == nil do return false

	tw := transform_world(tH)
	context.allocator = runtime.default_allocator()
	if agent.waypoints == nil {
		agent.waypoints = make([dynamic][3]f32, 0, 8)
	} else {
		clear(&agent.waypoints)
	}
	agent.waypoint_idx    = 0
	agent.target_position = goal
	agent.has_destination = true
	agent.arrived         = false

	if nm := navmesh_get_active(); nm != nil {
		path, ok := navmesh_find_path(nm, tw.position, goal, context.temp_allocator)
		if !ok || len(path) == 0 {
			agent.has_destination = false
			return false
		}
		for pt in path {
			append(&agent.waypoints, pt)
		}
	} else {
		append(&agent.waypoints, goal)
	}
	return true
}

nav_agent_has_arrived :: proc(w: ^World, tH: Transform_Handle) -> bool {
	if w == nil || !pool_valid(&w.transforms, Handle(tH)) do return false
	_, agent := transform_get_comp(tH, NavMeshAgent)
	if agent == nil do return false
	return agent.arrived
}

@(update={order=50})
nav_agents_update :: proc(dt: f32) {
	w := ctx_world()
	if w == nil do return
	pool := nav_mesh_agents(w)
	if pool == nil do return

	it := pool_iterator(pool)
	for agent, _ in pool_next(&it) {
		if !agent.enabled || !agent.has_destination || agent.arrived do continue
		if !pool_valid(&w.transforms, Handle(agent.owner)) do continue
		if len(agent.waypoints) == 0 || agent.waypoint_idx >= len(agent.waypoints) {
			agent.arrived = true
			agent.has_destination = false
			continue
		}

		obj_dt := transform_dt(agent.owner, dt)
		if obj_dt <= 1e-6 do continue
		rem_move := max(agent.speed, 0.0) * obj_dt
		stop_d := max(agent.stopping_distance, 0.05)

		tw := transform_world(agent.owner)
		cur_pos := tw.position
		moved_dir: [3]f32

		for rem_move > 1e-6 && agent.waypoint_idx < len(agent.waypoints) {
			wp := agent.waypoints[agent.waypoint_idx]
			delta := wp - cur_pos
			dist := linalg.length(delta)
			is_last := agent.waypoint_idx == len(agent.waypoints) - 1
			if is_last && dist <= stop_d {
				agent.arrived = true
				agent.has_destination = false
				break
			}
			if dist <= 1e-4 {
				agent.waypoint_idx += 1
				continue
			}
			dir := delta / dist
			moved_dir = dir
			if !is_last && dist <= rem_move {
				cur_pos = wp
				rem_move -= dist
				agent.waypoint_idx += 1
			} else if is_last && (dist - stop_d) <= rem_move {
				advance := max(dist - stop_d, 0.0)
				cur_pos += dir * advance
				agent.arrived = true
				agent.has_destination = false
				break
			} else {
				cur_pos += dir * rem_move
				rem_move = 0
			}
		}

		transform_set_world_position(agent.owner, cur_pos)
		if agent.auto_orient {
			flat := [3]f32{moved_dir.x, 0, moved_dir.z}
			if linalg.length2(flat) > 1e-6 {
				yaw := math.atan2(flat.x, flat.z)
				q := quat_from_native(linalg.quaternion_angle_axis(yaw, [3]f32{0, 1, 0}))
				transform_set_world_rotation(agent.owner, q)
			}
		}
	}
}
