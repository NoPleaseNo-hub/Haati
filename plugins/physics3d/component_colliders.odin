package physics3d

// Unity-literal 3D colliders. A collider attaches to the nearest ancestor
// Rigidbody (its own transform included) as a shape — Unity's compound-body
// rule — or, with no rigidbody anywhere above, to its own implicit STATIC
// body. Sizes are in world units (1 unit = 1 m).
//
// Runtime ids are created by the fixed step and never serialized. Inspector
// edits don't live-sync (the editor doesn't simulate); runtime code mutates
// physics through body_of(tH) + moonhug:external/jolt.

import jolt "haati:external/jolt"
import "haati:engine"

@(component={menu="Physics/BoxCollider"})
@(typ_guid={guid = "13101cd5-e0a6-49d4-a310-953001ebae6b"})
BoxCollider :: struct {
	using base:      engine.CompData `inspect:"-"`,
	channel:         Collision_Channel,
	blocks_channels: Collision_Mask, // Bitmask (Channels 1..8) that this object BLOCKS; unchecked = IGNORES / passes through
	collision_mask:  Collision_Mask, // Bitmask (Channels 1..8) that this object collides against when moving
	size:            [3]f32,
	center:          [3]f32,
	rotation:        [4]f32, // local orientation offset relative to bone/transform
	density:         f32,
	friction:        f32,
	bounciness:      f32,
	is_trigger:      bool,

	shape:           ^jolt.Shape `json:"-" inspect:"-"`,
	static_body:     jolt.BodyID `json:"-" inspect:"-"`, // only when no ancestor RB
	last_sync_pos:   [3]f32      `json:"-" inspect:"-"`,
	last_sync_rot:   [4]f32      `json:"-" inspect:"-"`,
	last_size:       [3]f32      `json:"-" inspect:"-"`,
	last_scale:      [3]f32      `json:"-" inspect:"-"`,
}

reset_BoxCollider :: proc(comp: ^BoxCollider) {
	cleanup_BoxCollider(comp)
	comp.channel = .Solid_World
	comp.blocks_channels = CHANNEL_SOLID_WORLD
	comp.collision_mask  = Collision_Mask(0xFF)
	comp.size = {1, 1, 1}
	comp.rotation = {0, 0, 0, 1}
	comp.density = 1
	comp.friction = 0.6
}

cleanup_BoxCollider :: proc(comp: ^BoxCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

@(component={menu="Physics/SphereCollider"})
@(typ_guid={guid = "8295fbf3-a792-4f02-9bea-b63fc056b99f"})
SphereCollider :: struct {
	using base:      engine.CompData `inspect:"-"`,
	channel:         Collision_Channel,
	blocks_channels: Collision_Mask, // Bitmask (Channels 1..8) that this object BLOCKS; unchecked = IGNORES / passes through
	collision_mask:  Collision_Mask, // Bitmask (Channels 1..8) that this object collides against when moving
	radius:          f32,
	center:          [3]f32,
	density:         f32,
	friction:        f32,
	bounciness:      f32,
	is_trigger:      bool,

	shape:           ^jolt.Shape `json:"-" inspect:"-"`,
	static_body:     jolt.BodyID `json:"-" inspect:"-"`,
	last_sync_pos:   [3]f32      `json:"-" inspect:"-"`,
	last_sync_rot:   [4]f32      `json:"-" inspect:"-"`,
	last_radius:     f32         `json:"-" inspect:"-"`,
	last_scale:      [3]f32      `json:"-" inspect:"-"`,
}

reset_SphereCollider :: proc(comp: ^SphereCollider) {
	cleanup_SphereCollider(comp)
	comp.channel = .Solid_World
	comp.blocks_channels = CHANNEL_SOLID_WORLD
	comp.collision_mask  = Collision_Mask(0xFF)
	comp.radius = 0.5
	comp.density = 1
	comp.friction = 0.6
}

cleanup_SphereCollider :: proc(comp: ^SphereCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// Unity's capsule axis.
Capsule_Direction :: enum {
	X_Axis,
	Y_Axis,
	Z_Axis,
}

@(component={menu="Physics/CapsuleCollider"})
@(typ_guid={guid = "91ddc047-6a91-4142-bc9c-d219570192b6"})
CapsuleCollider :: struct {
	using base:      engine.CompData `inspect:"-"`,
	channel:         Collision_Channel,
	blocks_channels: Collision_Mask, // Bitmask (Channels 1..8) that this object BLOCKS; unchecked = IGNORES / passes through
	collision_mask:  Collision_Mask, // Bitmask (Channels 1..8) that this object collides against when moving
	radius:          f32,
	height:          f32, // total, caps included (Unity)
	direction:       Capsule_Direction,
	center:          [3]f32,
	rotation:        [4]f32, // local orientation offset relative to bone/transform
	density:         f32,
	friction:        f32,
	bounciness:      f32,
	is_trigger:      bool,

	shape:           ^jolt.Shape       `json:"-" inspect:"-"`,
	static_body:     jolt.BodyID       `json:"-" inspect:"-"`,
	last_sync_pos:   [3]f32            `json:"-" inspect:"-"`,
	last_sync_rot:   [4]f32            `json:"-" inspect:"-"`,
	last_radius:     f32               `json:"-" inspect:"-"`,
	last_height:     f32               `json:"-" inspect:"-"`,
	last_dir:        Capsule_Direction `json:"-" inspect:"-"`,
	last_scale:      [3]f32            `json:"-" inspect:"-"`,
}

reset_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	cleanup_CapsuleCollider(comp)
	comp.channel = .Solid_World
	comp.blocks_channels = CHANNEL_SOLID_WORLD
	comp.collision_mask  = Collision_Mask(0xFF)
	comp.radius = 0.5
	comp.height = 2
	comp.direction = .Y_Axis
	comp.rotation = {0, 0, 0, 1}
	comp.density = 1
	comp.friction = 0.6
}

cleanup_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

@(component={menu="Physics/MeshCollider"})
@(typ_guid={guid = "a4e8c912-5b3d-47f1-8e29-6c1d0f3a9b72"})
MeshCollider :: struct {
	using base:      engine.CompData `inspect:"-"`,
	channel:         Collision_Channel,
	blocks_channels: Collision_Mask, // Bitmask (Channels 1..8) that this object BLOCKS; unchecked = IGNORES / passes through
	collision_mask:  Collision_Mask, // Bitmask (Channels 1..8) that this object collides against when moving
	mesh:            engine.PPtr,    // Optional explicit mesh; when empty, automatically uses the owner's MeshFilter
	convex:          bool,           // True for Jolt ConvexHullShape (required on dynamic Rigidbodies); False for static triangle MeshShape
	center:          [3]f32,
	rotation:        [4]f32,
	density:         f32,
	friction:        f32,
	bounciness:      f32,
	is_trigger:      bool,

	shape:           ^jolt.Shape       `json:"-" inspect:"-"`,
	static_body:     jolt.BodyID       `json:"-" inspect:"-"`,
	last_sync_pos:   [3]f32            `json:"-" inspect:"-"`,
	last_sync_rot:   [4]f32            `json:"-" inspect:"-"`,
	last_scale:      [3]f32            `json:"-" inspect:"-"`,
	last_mesh_guid:  engine.Asset_GUID `json:"-" inspect:"-"`,
	last_convex:     bool              `json:"-" inspect:"-"`,
}

reset_MeshCollider :: proc(comp: ^MeshCollider) {
	cleanup_MeshCollider(comp)
	comp.channel = .Solid_World
	comp.blocks_channels = CHANNEL_SOLID_WORLD
	comp.collision_mask  = Collision_Mask(0xFF)
	comp.rotation = {0, 0, 0, 1}
	comp.density = 1
	comp.friction = 0.6
}

cleanup_MeshCollider :: proc(comp: ^MeshCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// Live destroys (transform_destroy_components) — shapes and implicit static
// bodies must die with their components or they keep colliding as ghosts.
on_destroy_BoxCollider :: proc(comp: ^BoxCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

on_destroy_SphereCollider :: proc(comp: ^SphereCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

on_destroy_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

on_destroy_MeshCollider :: proc(comp: ^MeshCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

@(inspector_button={label="Remove Collider", row=-1})
box_collider_remove_button :: proc(comp: ^BoxCollider) {
	if comp == nil || comp.owner == {} do return
	engine.transform_destroy_comp(comp.owner, BoxCollider)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(inspector_button={label="Remove Collider", row=-1})
sphere_collider_remove_button :: proc(comp: ^SphereCollider) {
	if comp == nil || comp.owner == {} do return
	engine.transform_destroy_comp(comp.owner, SphereCollider)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(inspector_button={label="Remove Collider", row=-1})
capsule_collider_remove_button :: proc(comp: ^CapsuleCollider) {
	if comp == nil || comp.owner == {} do return
	engine.transform_destroy_comp(comp.owner, CapsuleCollider)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}

@(inspector_button={label="Remove Collider", row=-1})
mesh_collider_remove_button :: proc(comp: ^MeshCollider) {
	if comp == nil || comp.owner == {} do return
	engine.transform_destroy_comp(comp.owner, MeshCollider)
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
}
