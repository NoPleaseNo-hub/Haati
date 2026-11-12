# 01 — Critical Behavioral, Architectural & Crash-Safety Rules

> **MANDATORY READING BEFORE WRITING CODE.**
> These rules apply across every plugin, editor tool, and runtime system in the Moonhug + Void Odin engine.

---

## 1. DO NOT HARDCODE CONVERSATIONAL EXAMPLES INTO CODE OR UI
- When the user mentions concrete examples to explain an abstract concept (e.g. *"concrete blocks solid and see-through, glass blocks solid, water blocks neither"*, or *"on this timeline frame spawn a flying dagger"*, or *"outdoor sun / indoor room scene"*), **those are explanatory examples of how a general system works — NEVER hardcode them as presets, buttons, enums, or templates!**
- Always build **generic, data-driven, user-configurable systems**:
  - **Scene Creation**: Create a clean, empty scene (`Root` transform only). Never inject hardcoded jokes, sample cubes, or hardcoded lighting presets.
  - **Animation Timeline Signals**: Provide a generic string event name + payload field. Never hardcode specific gameplay strings (`"spawn_flying_dagger"`, `"camera_shake"`, etc.) as quick-add buttons.
  - **Physics Collision Channels**: Provide 8 generic, user-renameable channels (`Channel 1`..`Channel 8` in `@(project_settings)`) and generic `blocks_channels` / `collision_mask` bitfield toggles (`u32`). Never hardcode material presets like `"Concrete"`, `"Glass"`, or `"Water"`.

---

## 2. DELEGATE MATH BLOCKS & FRAME-CADENCE AMORTIZATION (NO ENUM/SWITCH BLOAT)
- **Avoid `enum` state machines and `switch` / `if-else` trees in per-frame gameplay and camera ticks.**
  - Instead of switching on an enum every frame, store a **function pointer / delegate math block** (`#type proc(...)`) on the component or state struct and invoke it directly.
  - Swapping behavior (e.g., transitioning camera behavior, locomotion stage, or recovery state) is a single pointer assignment (`pawn.active_math_block = ...`).
- **Modular Drop-In Components**:
  - Debug tools (such as a Debug Fly Camera) must be **standalone components** that can be attached/enabled to override or write into a shared state resource and removed later with zero trace in the core pawn code.
- **High-Framerate Frame-Cadence Amortization**:
  - Spread expensive secondary math (e.g. secondary pose-matching queries, environmental look-at scanning, non-critical harmonic decay) across frames (`(frame_index + entity_id) & 1 == 0` or staggered ring buffers) rather than stalling a single CPU frame.
- **Fail-Fast Over Silent Safety Checks**:
  - For required scene node references and required sibling/child components (e.g., `Camera` on `camera_node` or `SpringArm3D` on `Pivot_Springarm_node` in `CamPawn`), **do NOT hide missing references behind silent `if ptr == nil do return` checks** that fail silently at runtime.
  - Use explicit **`assert(cond, "FAIL-FAST: ...")`** checks at initialization/resolution so missing node assignments or missing components are reported immediately and loudly.
- **Enum Inspector Selection -> Direct Lookup Table to Delegate Math Block**:
  - When a mode needs to be human-readable in the Inspector, expose an `enum` field for authoring readability and map it via a direct `O(1)` lookup table (`_MODE_TABLE[mode]`) to the active `#type proc(...)` delegate pointer — never `switch` on the enum in the per-frame update loop.

---

## 3. ENGINE CRASH-SAFETY RULES (MEMORY & I/O)

### 3.1 `filepath.dir()` Slice Allocation Trap
- In Odin's `core:path/filepath`, `filepath.dir(path, allocator)` **does NOT always allocate a fresh string**. For root-like or empty paths (`""`, `"."`), it returns a **sub-slice of the input string** (`"."`).
- **Rule**: **NEVER call `delete(dir)`** on a string returned by `filepath.dir(path)`. Calling `delete()` on a static literal slice or sub-slice corrupts the heap and crashes the engine.
- Always pass `context.temp_allocator` to `filepath.dir`, `filepath.join`, `filepath.clean`, and `strings.replace_all`.

### 3.2 Zero Per-Frame Disk I/O in ImGui Draw Loops
- **NEVER** call `os.read_dir`, `os.exists`, `os.stat`, `os.read_entire_file`, or `json.unmarshal` unconditionally inside an ImGui `draw()` procedure.
- Use event-driven dirty flags (`_needs_refresh = true`) or cache results per selection change.

### 3.3 Jolt Physics Contact Callback Lock Rule
- Inside Jolt `OnContactValidate`, `OnContactAdded`, `OnContactPersisted`, and `OnContactRemoved` callbacks, the physics body lock is **already held** by the solver thread.
- **Rule**: Always use `state.body_interface_no_lock` (`JPH_PhysicsSystem_GetBodyInterfaceNoLock`) inside contact callbacks. Using the locking `body_interface` deadlocks the engine immediately.

### 3.4 Multi-Viewport ImGui Popup Ownership Rule
- `wnd.draw_all()` iterates open editor windows in reverse order.
- **NEVER** call the same `im.BeginPopupModal("...")` helper from two different editor windows (e.g. both `Void Inspector` and `Void Hierarchy`) sharing a single static flag. Each popup modal must have a single owning window, or use inline drawers / in-modal views.

### 3.5 ImGui `#c_vararg` Odin `string` Crash Rule
- **NEVER** pass an Odin `string` directly into C variadic `#c_vararg` ImGui functions (`im.SetTooltip`, `im.Text`, `im.TextColored`, `im.TextDisabled`, `im.TextWrapped`, `im.BulletText`).
- In Odin, `string` is a 16-byte `{data: [^]u8, len: int}` struct, NOT a C `char*`. Passing an Odin `string` to C's `vsnprintf` (`%s`) shifts the variadic argument slots by 8 bytes so `len` (e.g. `9` = `0x0000000000000009`) is dereferenced as a `char*` pointer — causing an immediate Access Violation (`0xC0000005`).
- **Rule**: Always format in Odin first via `fmt.ctprintf(...)`, and always use `widgets.tooltip(fmt.ctprintf(...))` for tooltips.

---

## 4. ANTI-DUPLICATION & PRE-FLIGHT CHECKLIST
Before adding any struct, component, or editor window:
1. Check [`02_ENGINE_ECS_AND_EDITOR_CORE.md`](./02_ENGINE_ECS_AND_EDITOR_CORE.md) to verify whether a component or editor dock already exists.
2. Check if an existing component should be extended rather than creating a duplicate `TypeKey`.
3. After adding or modifying any `@(component)`, `@(window)`, `@(menu_item)`, or `@(project_settings)` annotation, run:
   ```powershell
   odin run tools/mh -- build
   ```
   Wait for the prebuild codegen (`generated.odin`) and compiler to finish with exit code `0`.
