package engine

import "core:math"
import gfx "gfx"

// Light consumed by the built-in lit shader and custom lit shaders
// (docs/Materials.md). Directional, Point or Spot — Unity's Light.type model.
// Up to 8 enabled lights render per pass (the pool max). Directional light
// travels along the transform's forward (-Z), like a camera; point and spot
// sit at the transform's position, spot aiming along forward.
//
// The ambient floor comes from the FIRST enabled light (scene-wide ambient
// until a lighting settings asset exists).

Light_Type :: enum u8 {
    Directional,
    Point,
    Spot,
}

@(component={max=64, menu="Rendering/Light"})
@(typ_guid={guid = "9f36ee91-34b6-4636-a360-ee872af0436b"})
Light :: struct {
    using base: CompData `inspect:"-"`,
    type:             Light_Type,
    color:            [4]f32 `decor:color()`, // alpha unused
    intensity:        f32,
    range:            f32 `decor:min(0)`, // point/spot: falloff reaches zero here
    spot_angle:       f32 `decor:min(0)`, // spot: full cone angle, degrees (Unity spotAngle)
    inner_spot_angle: f32 `decor:min(0)`, // spot: full-brightness cone, degrees
    ambient:          f32 `decor:min(0)`, // unlit floor 0..1, first enabled light wins
    cast_shadows:     bool,               // cast real-time planar/atlas shadows
    shadow_strength:  f32 `decor:min(0)`, // shadow opacity 0..1
    shadow_ground_y:  f32,                // receiver plane Y height (default 0.0m)
    shadow_bias:      f32 `decor:min(0)`, // depth bias for shadow atlas sampling
}

reset_Light :: proc(l: ^Light) {
    l.type = .Directional
    l.color = {1, 1, 1, 1}
    l.intensity = 1
    l.range = 10
    l.spot_angle = 30
    l.inner_spot_angle = 21.8
    l.ambient = 0.0
    l.cast_shadows = true
    l.shadow_strength = 0.72
    l.shadow_ground_y = 0.0
    l.shadow_bias = 0.0015
}

// The gfx-facing description of one live Light: world transform applied,
// angles converted to half-angle cosines.
light_to_gfx :: proc(l: ^Light, tw: Transform_World) -> gfx.Light {
    rot := quat_to_matrix3(tw.rotation)
    forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]} // -Z, like cameras
    kind: gfx.Light_Kind
    switch l.type {
    case .Directional: kind = .Directional
    case .Point:       kind = .Point
    case .Spot:        kind = .Spot
    }
    return gfx.Light{
        kind            = kind,
        position        = tw.position,
        direction       = forward,
        color           = l.color.rgb,
        intensity       = l.intensity,
        range           = l.range,
        inner_cos       = math.cos(math.to_radians(l.inner_spot_angle) * 0.5),
        outer_cos       = math.cos(math.to_radians(max(l.spot_angle, l.inner_spot_angle)) * 0.5),
        cast_shadows    = l.cast_shadows,
        shadow_strength = l.shadow_strength,
        shadow_bias     = l.shadow_bias > 0 ? l.shadow_bias : 0.0015,
    }
}
