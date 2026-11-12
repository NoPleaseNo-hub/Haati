# 02 — Engine ECS, Directory Map & Editor Core

---

## 1. Project Directory Map

```text
moonhug-main/
├── moonhug/                    # Core Moonhug Engine (Odin)
│   ├── engine/                 # ECS, Scene, Transform, Renderer (Vulkan/OpenGL/D3D), Asset DB, Audio
│   ├── editor/                 # ImGui Editor Framework, Viewports (Scene 2D / Scene 3D), Gizmos, Inspector
│   └── external/               # Third-party Odin bindings (odin-imgui, joltc, miniaudio, freetype, assimp)
├── plugins/                    # Modular Engine & Gameplay Plugins
│   ├── void_odin/              # Void Gameplay Plugin (Scenes, Pawns, Assets, Gameplay Components)
│   │   └── Scenes/             # Project .scene files (e.g., CamPawn/CamPawn.scene)
│   ├── physics3d/              # Jolt Physics 3D (Rigidbodies, Colliders, SpringArm3D, Collision Channels)
│   ├── physics2d/              # 2D Physics & Colliders
│   ├── control_rig/            # Procedural 3D Animation, Control Rig, Humanoid IK, Faker Body Harmonics, Ghoul Gore
│   ├── cad_csg/                # Non-Destructive Half-Space CSG, Faker CSG (.fmesh), Voxel SDF Destruction, Poly Edit
│   ├── file_explorer/          # Void File Explorer, Void Hierarchy, Void Inspector
│   ├── editor_visuals/         # Viewport Overlays, Icons, Component Gizmos, Theme Styling
│   ├── input_manager/          # Godot-style Input Map & Action Bindings
│   ├── sequencer/              # Timeline & Keyframe Animation Sequencer
│   ├── tween/                  # Procedural Tweening System
│   ├── sprites/                # 2D Sprite Renderer & Animation
│   ├── text/                   # Font & Text Rendering
│   ├── ui_canvas/              # Runtime UI Canvas
│   └── mhgui/                  # Immediate-Mode Runtime GUI
├── tools/
│   ├── mh/                     # Build CLI (`odin run tools/mh -- build`)
│   └── prebuild/               # AST Metaprogramming Codegen (generates `generated.odin`)
└── docs/
    ├── PROJECT_ARCHITECTURE_AND_NOTES.md  # Master Index
    └── instructions/                      # Modular Instruction & Architecture Docs
```

---

## 2. How to Create Nodes & Components in Moonhug + Odin

### 2.1 Nodes vs. Components
- Every **Node** in the Scene Hierarchy is an [`engine.Transform`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/moonhug/engine/transform.odin) with a name, local/world TRS (`position`, `rotation`, `scale`), parent/children handles, and a `components: [dynamic]CompRef` array.
- **Components** attach behavior or data to any Node.

### 2.2 Defining a New Odin Component (`@(component)`) & Subfolder Packages
You can place `.odin` component scripts either in the root `plugins/void_odin/` folder or inside any subfolder (such as `plugins/void_odin/Scenes/CamPawn/` right next to `CamPawn.scene`):

- **Odin Subfolder Package Rule ([`packages_gen.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/moonhug/prebuild/packages_gen/packages_gen.odin#L65-L68))**:
  - In Odin, each directory is its own package.
  - Files in `plugins/void_odin/` declare `package void_odin`.
  - Files in a subfolder `plugins/void_odin/<Sub/Folder>` declare `package void_odin_<Sub_Folder>` (with slashes replaced by underscores, e.g., `package void_odin_Scenes_CamPawn` for `plugins/void_odin/Scenes/CamPawn/component_CamPawn.odin`).
  - `New Script` in Void Inspector, `Create New Odin Component (.odin)` in Void Hierarchy, and `Create New Odin Script` in Void File Explorer **automatically default to the active scene's subfolder** (with 1-click toggle pills between `[Scene Folder]` and `[Root]`, plus a custom subfolder input) and automatically write the matching `package ...` header!
  - `prebuild` recursively discovers all subfolders under `plugins/void_odin/`, generates `components_ext_generated.odin` inside each subfolder that has `@(component)` structs, and registers its `@(update)` / `@(fixed_update)` systems automatically.

```odin
package void_odin_Scenes_CamPawn

import "moonhug:engine"

@(component={menu="Void/CamPawn"})
@(typ_guid={guid = "3b8a9d24-6f11-48e2-9c77-52e1a40b91c3"})
CamPawn :: struct {
	using base: engine.CompData `inspect:"-"`,
	camera_node: engine.Ref_Local `ref:"Transform"`,
	move_speed:  f32,
	look_speed:  f32,
}

reset_CamPawn :: proc(c: ^CamPawn) {
	c.move_speed = 8.0
	c.look_speed = 0.15
}
```

- **Struct Tag Rules**:
  - `using base: engine.CompData \`inspect:"-"\`` is **required** as the first field of every component.
  - `@(typ_guid={guid = "..."})` is generated automatically by `New Script` / `Create New Odin Component` (and synthesized deterministically by `type_guid_gen` if omitted).
  - Cross-node references in scenes use `engine.Ref_Local \`ref:"Transform"\`` (or `engine.Ref_Local \`ref:"Camera"\`` to target a specific component; at runtime `c.camera_node.handle` holds the resolved `engine.Handle`).
  - Cross-asset references use `engine.PPtr` or `engine.Asset_GUID`.
  - After creating a new `@(component)` struct, run `odin run tools/mh -- build` so `prebuild` registers its `engine.TypeKey` and serialization reflection.

---

## 3. Core Editor Docks (`plugins/file_explorer/editor/`)

### 3.1 Void Hierarchy ([`void_hierarchy_editor.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/file_explorer/editor/void_hierarchy_editor.odin))
- **Quick Scene Navigator**: Top scene pill (`New_Level v`) opens a stable `460x360` popup listing all `.scene` files in the project with search and `+ New Empty Scene`.
- **`+ Add Node` / Right-Click -> `Add Child Node`**:
  - Instant search bar at the top filters all 3D/2D/UI/Physics/Void components and presets, with both **Click-to-Create-Child-Node** and **`[+Attach]`** onto the selected node.
  - Nested scene instantiation (`Instantiate Child Scene...`) embeds a `.scene` asset as a live child hierarchy (`prefab_scene` PPtr).

### 3.2 Void Inspector ([`void_inspector_editor.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/file_explorer/editor/void_inspector_editor.odin))
- **Identity Header**: Active checkbox, inline node rename, and quick actions.
- **Proportional Transform Card**: Local/World toggle, uniform scale lock, and `[R]` reset buttons.
- **Component Cards**: Category-colored headers, enable/disable toggle, and `...` menu (Reset, Copy/Paste, Move Up/Down, Open `.odin` Source in IDE, Remove).
- **`[+ Add Component...]` & `[<> New Script]`**:
  - `[+ Add Component...]` opens the searchable **`Add Component Catalog`** modal with category filter pills (`All`, `Void Scripts`, `Physics 3D`, `3D & Render`, `Anim & Rig`, `Audio`, `2D & UI`), keyboard navigation, and an in-modal **`+ Create New Odin Component (.odin)...`** form.
  - `[<> New Script]` opens an inline **`Create New Odin Component (.odin)`** card directly inside Void Inspector (auto-prefilled from the node/scene name) and shows a persistent confirmation banner with `[Open in IDE]` and `[Reveal in File Explorer]`.

### 3.3 Asset & Node Reference Pickers ([`inspector.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/moonhug/editor/inspector/inspector.odin))
- Clicking **anywhere** on the main body of a `Transform_PPtr` or `Asset_PPtr` select bar opens the searchable dropdown popup directly, even when an asset or node is already assigned (`[x]` clears, and right-clicking/double-clicking pings the asset).
- Searchable asset dropdowns render up to 500 matching assets with an item count badge.

### 3.4 Multi-Viewport Architecture ([`viewports.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/moonhug/editor/window/viewports.odin))
- **Scene 3D** and **Scene 2D** are independent dockable viewports with isolated camera states (`Viewport_Instance`), independent gizmo toolbars, and per-viewport MSAA/FBO render targets.
