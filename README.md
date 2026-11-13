# Haati Engine

**Haati** is a purpose-built, multicore 3D game engine and integrated Odin studio built on the [MoonHug](LICENSE) game engine (zlib License).

## Highlights

- **CAD & Destructible CSG Hybrid ("Faker CSG")**: Real-time CSG booleans, sub-millisecond Jolt collision hulls, surface stamps, and visual mesh deformation.
- **Control Rig & Procedural Character Motion**: Full humanoid IK/rigging, skeletal deformation, blend spaces, and spring bones (`Mannequin_F.glb` default mannequin in `plugins/control_rig/assets/meshes/characters/`).
- **Unified Graph & Odin Micro-Studio**: `.bodin` Visual Graphs compiled straight to native x64 machine code alongside Odin source editing, Unreal-style Namespace `BP_Node` Blocks (`Event`, `Flow`, `Input`, `Math`, `Transform`, `Anim`, `VFX`, `Audio`, `AI`, `Delegate`, `Odin`), Left/Right pin-drag context-sensitive spawner, inline `+ New Custom Event` wiring, and ~200 ms F7 Hot-Cartridge live swap.
- **Unified GPU Lighting & Shadow Atlas**: `4096x4096` 16-tile GPU depth atlas supporting 3-cascade Directional CSM, Spot shadows, and dual 6-face Point Light cubemap shadows, with true `0.0` ambient darkness and `[Lit | Unlit | FakeLight]` Scene 3D viewport modes.
- **Void Workflow**: Docked `Void Hierarchy`, `Void File Explorer`, and `Void Inspector` workspace.
- **Overwatch Flight Recorder**: Zero-overhead out-of-process Win32 crash and frame-spike autopsy (`builds/Haati_Overwatch.exe`).

## Platform Support (Windows x64 Only)

Haati targets **Windows x64** natively (producing `Haati_Editor.exe`, `builds/Haati.exe`, Win32 hot-reload `.dll` cartridges, and `builds/Haati_Overwatch.exe`). Linux and macOS builds are not currently maintained (neither platform runs Windows `.exe` binaries).

## How Haati Differs from Upstream MoonHug

Haati began on the MoonHug core (`LICENSE`) and diverges heavily across runtime, rendering, tooling, and editor UX:
- **Multicore Job-Dispatched Engine**: Worker job system driving parallel physics, culling, and scene work instead of single-core main-thread bottlenecks.
- **Shadow Atlas & Viewport Modes**: Replaced fake directional ambient with a unified `4096x4096` 16-tile GPU shadow atlas (`Directional` 3-cascade CSM, `Spot`, and dual `Point` 6-face cubemap shadows) plus Scene 3D `[Lit | Unlit | FakeLight]` inspection modes (`Game` views always stay true `Lit`).
- **CAD & Destructible "Faker CSG"**: Real-time CSG booleans, Jolt convex/compound hulls, surface stamps, and runtime mesh deformation.
- **Unified `BP_Node` Visual Scripting + Embedded Odin IDE**: Domain-unified `.bodin` graphs, Unreal-style `BP_Node` namespaces, Left/Right pin-drag context filtering, debounced read-only background `odin check` diagnostics, and sub-second F7 hot-reload.
- **Void Workspace & Overwatch**: Relocated Void docks, integrated Control Rig mannequin pipeline, and out-of-process Win32 crash/spike capture.

## Quick Start

```powershell
# First-time setup (builds vendored C libs & repairs plugin junctions in haati/packages/)
odin run tools/haati -- setup

# Build & launch the Haati Editor
odin run tools/haati -- run

# Run full automated test suite
odin run tools/haati -- test

# Build release executable + Overwatch without launching
odin run tools/haati -- build
```

> `tools/mh` and the `Makefile` forward identically to the same unified build system and pass both `-collection:haati=haati` and `-collection:moonhug=haati` so external plugins importing either collection name build seamlessly.

## Troubleshooting

- Troubleshooting: "It works on my machine."
- Source: "Trust me bro."
- Make sure you launch from `Haati_Editor.exe` (or run `odin run tools/haati -- run`) on **Windows x64** so runtime `.dll`s in `builds/` resolve properly and shader tools (`shadercross` / `dxc` / `spirv-cross`) are available when rebuilding shaders.

## License

Haati is distributed under the terms of the [LICENSE](LICENSE) (zlib License). All original MoonHug copyright and permission notices are preserved in full.
