# 03 — 3D Physics, Collision Channels & SpringArm3D

---

## 1. Jolt Physics 3D Overview (`plugins/physics3d/`)

- **Core Files**:
  - [`physics3d.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/physics3d.odin): JoltC world lifecycle, body registration, contact listeners, raycasts, and collision channel filtering.
  - [`component_colliders.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/component_colliders.odin): `BoxCollider`, `SphereCollider`, `CapsuleCollider`, `Collision_Filter_Preset`, and project-wide channel names (`Physics3D_Settings`).
  - [`component_rigidbody.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/component_rigidbody.odin): `Rigidbody` component (`Static`, `Kinematic`, `Dynamic`).
  - [`component_SpringArm3D.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/component_SpringArm3D.odin): Godot 4 / UE5 style camera boom (`SpringArm3D`).
  - [`editor/physics3d_editor.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/editor/physics3d_editor.odin): Custom Inspector checkboxes for 8 collision channels and 3D viewport gizmos.

---

## 2. Generic 8-Channel Collision Bitmasks (`blocks_channels` & `collision_mask`)

### 2.1 How Collision Channels Work
- Every 3D collider (`BoxCollider`, `SphereCollider`, `CapsuleCollider`) has:
  - `filter_preset: Collision_Filter_Preset` (`Custom = 0` uses the explicit bitmasks below; `Default` / `Solid_World` / `Character` / `Hitbox_Sensor` / `Ragdoll` / `Debris` auto-syncs default masks when selected in the Inspector).
  - `blocks_channels: u32`: Bitmask (`1 << 0` .. `1 << 7`) of channels **this object occupies / blocks**.
  - `collision_mask: u32`: Bitmask (`1 << 0` .. `1 << 7`) of channels **this object tests against / collides with**.
- **Two-Way Body vs. Body Contact Rule** (in `on_contact_validate`):
  ```odin
  ((blocks_a & mask_b) != 0) && ((blocks_b & mask_a) != 0)
  ```
- **One-Way Raycast / Probe Rule** (in `raycast`, `raycast_all`, and `SpringArm3D`):
  ```odin
  (collider_blocks_channels & query_collision_mask) != 0
  ```
  - Example: `SpringArm3D` defaults to `collision_mask = 1` (Channel 1 only), so it only retracts against objects that have **Blocks Channel 1** enabled, plus it ignores any node in its `ignored_nodes` list (or any of that node's descendant colliders).

### 2.2 Project-Wide Customizable Channel Names
- Defined in [`Physics3D_Settings`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/component_colliders.odin#L26-L40) (`@(project_settings)`):
  - `channel_1_name` .. `channel_8_name` default to `"Channel 1"` .. `"Channel 8"` and can be renamed in **Project Settings -> Physics 3D**.
  - The custom `@(inspect_drawer)` in [`physics3d_editor.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/editor/physics3d_editor.odin#L23-L114) renders compact 2-column checkboxes (`[x] 1: Channel 1`, etc.) with `[All]`, `[None]`, and `[Ch 1 Only]` quick buttons.

---

## 3. `SpringArm3D` & `CamPawn` Hierarchy Pattern

### 3.1 How `SpringArm3D` Positions Children
- Unlike Godot (where children sit at local `(0,0,0)` and `SpringArm3D` mutates their local positions), Moonhug's [`SpringArm3D`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/physics3d/component_SpringArm3D.odin) offers two modes:
  1. **Explicit `tip_node: engine.Transform_PPtr` assigned**: Moves only that specific target node to `-Z * current_length`.
  2. **`tip_node` left empty (Godot-style automatic child mode)**: Automatically pushes all direct child nodes of the `SpringArm3D` node to local `(0, 0, -current_length)` every tick (and in the 3D editor viewport).

### 3.2 Recommended `CamPawn.scene` Hierarchy
```text
Root (CamPawn)
 └── Pivot (Node3D - receives Yaw/Pitch rotation)
      └── SpringArm3D (Node with SpringArm3D component, collision_mask = 1)
           └── SphereCollider (Node with SphereCollider, disabled by default; enabled only in Debug Fly Cam)
                └── Camera (Node with Camera component at local 0,0,0)
```

### 3.3 Delegate Math Block Architecture for `CamPawn`
- **No `enum` / `switch` camera state machine**:
  - `CamPawn` holds a function pointer (`active_cam_tick: #type proc(...)`) and writes look/aim/movement intent into a shared pawn input/state struct so `HumanoidPawn` can be driven identically by `CamPawn`, AI, or Hive-Mind AI.
  - Debug Fly Camera is a **separate drop-in component** that can be enabled/disabled or removed without modifying `CamPawn`.
