# Haati Engine Manual

Welcome to **Haati** (*built on the MoonHug game engine*). This quick reference covers the core workflow for building levels, writing Odin / `.bodin` gameplay logic, debugging performance, and lighting your scenes.

## 1. Workspace Panels (Editor Workflow)

- **Hierarchy** (`Ctrl+4`): Scene entity tree, nesting, prefab instances, visibility toggles, and drag-and-drop parenting.
- **File Explorer** (`Ctrl+5`): Project & plugin asset browser (`assets/` and `plugins/*/assets/`) with live search, thumbnails, and context creation (`Assets/Create/*`).
- **Inspector** (`Ctrl+3`): Live property editor for transforms, components, materials, and assets.
- **Scene3D & Game** (`Ctrl+1` / `Ctrl+2`): 3D authoring viewport with CAD/CSG tools and `[Lit | Unlit]` inspection toggle, plus live Play preview.

## 2. How a Game Is Constructed

1. **Greybox & Carve Arena**: Enter CAD Mode in Scene3D (`Tools 1–7`) to sketch `CSGVolume` geometry; right-click multi-selected brushes for Union, Subtract, Intersect, or Join Brushes.
2. **Dress Visuals (Faker CSG Hybrid)**: Keep lightweight CSG hulls for Jolt physics and crater carving, and layer art meshes or procedural props on top.
3. **Gameplay Plugins**: Place game-specific components and assets in your own isolated plugin under `plugins/<your_plugin>/` — Haati preserves external plugin namespaces (`haati:` and legacy `moonhug:`).
4. **Unified Odin & Node Block Graph (`.bodin`)**:
   - All `.bodin` nodes belong to a single Data-Oriented Odin graph organized by Unreal-style **Namespaces** (`Event`, `Flow`, `Input`, `Math`, `Transform`, `Anim`, `VFX`, `Audio`, `AI`, `Delegate`, `Odin`) with zero separate VM overhead.
   - Use **Odin Micro-Studio** for pure `.odin` modules (`haati/hot_scripts/`) or `@(hot_proc)` script editing, complete with `Ctrl+Z` / `Ctrl+Y` persistent undo/redo, async autocomplete (`Ctrl+Space`), and font zoom (`Ctrl+Wheel`).
   - Material authoring automatically switches the Graph Studio to Fragment Shader node mode (`.mat` / `.glsl`).
5. **Fast Live Iteration**: Press **F7** (~200 ms) to hot-swap `hot_cartridge.dll` without tearing down the world; press **Relaunch** when core C-ABI component struct layouts change.

## 3. Lighting & Unified GPU Shadows

- Lights default to `ambient = 0.0` — rooms and surfaces with no active light or outside a Point/Spot light's range render **pitch black** in `Lit` mode (use the **Scene3D `[Unlit]`** toggle when editing dark interiors).
- All 3D meshes — CSG brushes, Faker meshes, static glTF meshes, and Control Rig `ArmatureDeformedMesh` characters — cast real-time hardware GPU shadows via the `4096x4096` 16-tile Shadow Atlas (3-cascade Directional CSM, Spot cone, and dual 360° 6-face Point Light cubemaps).
- Custom `.glsl` shaders can `#include "lighting_common.glsl"` and call `eval_light_shadow(...)` with `u_shadow_map` reserved at `set=2, binding=7`.

## 4. Overwatch & Build Tooling

- Toggle **Overwatch** from the top-right corner button to record live frame timings and crash breadcrumbs via `builds/Haati_Overwatch.exe` into `haati/logs/overwatch/`.
- CLI commands: `odin run tools/haati -- setup | run | check | hot | shaders | test | build | overwatch | package`.
