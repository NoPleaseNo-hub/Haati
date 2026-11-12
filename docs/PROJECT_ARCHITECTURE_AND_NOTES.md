# Moonhug + Void Odin — Master Architecture Index

> **READ THIS FIRST.**
> To keep documentation fast to scan and prevent context bloat, detailed instructions and subsystem notes are organized into modular files inside [`docs/instructions/`](./instructions/).

---

## Top Non-Negotiable Rules (Always Active)

1. **DO NOT HARDCODE CONVERSATIONAL EXAMPLES INTO CODE OR UI**:
   - When the user gives concrete examples to explain how a system works (e.g., *"concrete vs. glass vs. water collision channels"*, *"spawn flying dagger timeline signal"*, *"outdoor sun / indoor room scene"*), **never hardcode those examples as presets, buttons, enums, or templates**. Build generic, user-configurable, data-driven tools.
2. **DELEGATE MATH BLOCKS OVER ENUMS / SWITCHES**:
   - Avoid `enum` state machines and `switch` / `if-else` trees in per-frame gameplay/camera ticks. Use function pointers / delegate math blocks (`#type proc(...)`) and amortize non-critical math across frames.
   - Debug modes (like Debug Fly Camera) must be standalone, drop-in components that can be added or removed cleanly without polluting core pawn code.
3. **NEVER MUTATE BONES DIRECTLY IN GAMEPLAY**:
   - Manipulate **Rig Controls** (`ControlRig`) across Stages 1–4; only Stage 5 (`HumanoidIkSolver`) solves Rig Controls into final bone matrices.
4. **CRASH-SAFETY**:
   - Never `delete()` the result of `filepath.dir()`.
   - Never run disk I/O (`os.read_dir`, `os.exists`) unconditionally per frame in ImGui `draw()`.
   - Always use `body_interface_no_lock` inside Jolt contact callbacks.
   - Never call the same `im.BeginPopupModal` across two different editor windows sharing one static flag.

---

## Modular Instructions Directory (`docs/instructions/`)

| File | Scope & When to Read |
| :--- | :--- |
| **[`01_CRITICAL_BEHAVIORAL_RULES.md`](./instructions/01_CRITICAL_BEHAVIORAL_RULES.md)** | Mandatory anti-hardcoding rule, delegate math blocks vs. enums, frame-cadence amortization, and crash-safety rules. |
| **[`02_ENGINE_ECS_AND_EDITOR_CORE.md`](./instructions/02_ENGINE_ECS_AND_EDITOR_CORE.md)** | Project directory map, how to author `@(component)` scripts, Void Hierarchy, Void Inspector, Reference Pickers, and Multi-Viewport rules. |
| **[`03_PHYSICS_AND_COLLISION_CHANNELS.md`](./instructions/03_PHYSICS_AND_COLLISION_CHANNELS.md)** | JoltC 3D physics, 8 customizable collision channels (`blocks_channels` & `collision_mask`), `SpringArm3D` child positioning, and `CamPawn` setup. |
| **[`04_CONTROL_RIG_AND_BODY_HARMONICS.md`](./instructions/04_CONTROL_RIG_AND_BODY_HARMONICS.md)** | 5-Stage Procedural Control Rig pipeline, Faker Body Harmonics (skeletal shock pulse + flesh oscillation), Per-Control Intent & Armor/Poise, Fake Ragdoll, and Ghoul Gore. |
| **[`05_CAD_CSG_AND_VOXEL_DESTRUCTION.md`](./instructions/05_CAD_CSG_AND_VOXEL_DESTRUCTION.md)** | Non-destructive Half-Space CSG (`CSGVolume`), `.fmesh` (`Faker CSG`), *Severed Steel* lazy chunked Voxel SDF destruction, and Poly Mesh editing. |

---

## Build & Verification Command

Whenever components, editor windows, or plugins are modified, run from the workspace root:
```powershell
odin run tools/mh -- build
```
