package tests

// Pure geometry tests for haati:editor/node_canvas tree layout & coordinate transforms.

import nc "haati:editor/node_canvas"
import "core:testing"

@(test)
test_tree_canvas_screen_round_trip :: proc(t: ^testing.T) {
	v := nc.Tree_View{pan = {37, -12}, zoom = 1.75, initialized = true}
	origin := [2]f32{100, 50}

	for p in ([][2]f32{{0, 0}, {10, 10}, {-250, 400}, {1e3, -1e3}}) {
		s := nc.tree_canvas_to_screen(&v, origin, p)
		back := nc.tree_screen_to_canvas(&v, origin, s)
		testing.expectf(t, abs(back.x - p.x) < 0.01 && abs(back.y - p.y) < 0.01,
			"round trip lost %v -> %v -> %v", p, s, back)
	}
}

@(test)
test_tree_canvas_zero_view_is_identity_zoom :: proc(t: ^testing.T) {
	v := nc.Tree_View{}
	testing.expect_value(t, nc.tree_view_zoom(&v), f32(1))
	p := nc.tree_canvas_to_screen(&v, {0, 0}, {5, 7})
	testing.expect_value(t, p, [2]f32{5, 7})
}

@(test)
test_tree_canvas_layout_separates_siblings :: proc(t: ^testing.T) {
	nodes := []nc.Tree_Node{
		{user_handle = 1, title = "Sequence", size = {100, 30}},
		{user_handle = 2, title = "Move", size = {100, 30}},
		{user_handle = 3, title = "Scale", size = {100, 30}},
	}
	links := []nc.Tree_Link{{from = 0, to = 1}, {from = 0, to = 2}}

	nc.tree_layout(nodes, links)

	testing.expect(t, nodes[1].position.y > nodes[0].position.y, "child 1 below parent")
	testing.expect(t, nodes[2].position.y > nodes[0].position.y, "child 2 below parent")

	testing.expect_value(t, nodes[1].position.y, nodes[2].position.y)
	left, right := nodes[1], nodes[2]
	if left.position.x > right.position.x do left, right = right, left
	testing.expectf(t, left.position.x + left.size.x <= right.position.x,
		"siblings overlap: %v..%v and %v..", left.position.x, left.position.x + left.size.x, right.position.x)
}

@(test)
test_tree_canvas_layout_survives_a_cycle :: proc(t: ^testing.T) {
	nodes := []nc.Tree_Node{
		{user_handle = 1, size = {80, 20}},
		{user_handle = 2, size = {80, 20}},
	}
	links := []nc.Tree_Link{{from = 0, to = 1}, {from = 1, to = 0}}

	nc.tree_layout(nodes, links)
	testing.expect(t, true, "layout returned rather than recursing forever")
}

@(test)
test_tree_canvas_layout_ignores_bad_indices :: proc(t: ^testing.T) {
	nodes := []nc.Tree_Node{{user_handle = 1, size = {80, 20}}}
	links := []nc.Tree_Link{{from = 0, to = 99}, {from = -3, to = 0}}

	nc.tree_layout(nodes, links)
	testing.expect_value(t, nodes[0].position, [2]f32{0, 0})
}

@(test)
test_tree_canvas_layout_centres_children_under_wide_parent :: proc(t: ^testing.T) {
	nodes := []nc.Tree_Node{
		{user_handle = 1, title = "Wide Parent", size = {400, 30}},
		{user_handle = 2, title = "a", size = {60, 30}},
		{user_handle = 3, title = "b", size = {60, 30}},
	}
	links := []nc.Tree_Link{{from = 0, to = 1}, {from = 0, to = 2}}

	nc.tree_layout(nodes, links)

	parent_mid := nodes[0].position.x + nodes[0].size.x * 0.5
	lo := min(nodes[1].position.x, nodes[2].position.x)
	hi := max(nodes[1].position.x + nodes[1].size.x, nodes[2].position.x + nodes[2].size.x)
	children_mid := (lo + hi) * 0.5

	testing.expectf(t, abs(parent_mid - children_mid) < 0.51,
		"parent centre %v vs children centre %v", parent_mid, children_mid)
}

@(test)
test_tree_canvas_path_round_trip :: proc(t: ^testing.T) {
	parents := []int{-1, 0, 1, 0, 3, 3}

	for i in 0 ..< len(parents) {
		path: [8]i32
		depth := nc.tree_path_of(parents, i, path[:])
		got := nc.tree_find_path(parents, 0, path[:depth])
		testing.expectf(t, got == i, "node %v -> path %v -> node %v", i, path[:depth], got)
	}
}

@(test)
test_tree_canvas_path_missing_shape_resolves_to_nothing :: proc(t: ^testing.T) {
	parents := []int{-1, 0}
	path := []i32{1}
	testing.expect_value(t, nc.tree_find_path(parents, 0, path), -1)

	deep := []i32{0, 0}
	testing.expect_value(t, nc.tree_find_path(parents, 0, deep), -1)
}

@(test)
test_tree_canvas_path_cycle_and_root :: proc(t: ^testing.T) {
	cyclic := []int{1, 0}
	out: [8]i32
	testing.expect_value(t, nc.tree_path_of(cyclic, 0, out[:]), 0)

	parents := []int{-1, 0}
	testing.expect_value(t, nc.tree_find_path(parents, 0, nil), 0)
	depth := nc.tree_path_of(parents, 0, out[:])
	testing.expect_value(t, depth, 0)
}
