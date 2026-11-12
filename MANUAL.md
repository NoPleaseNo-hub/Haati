# Haati Engine — Simplistic User & Game Construction Manual

> **Haati** (*Norse wolf Hati, the devourer that chases the Moon*) is a purpose-built **Destructive CSG, Faker Hybrid Physics & High-Speed Action Engine** forked from [MoonHug](https://github.com/MoonHug-Editor/moonhug) (`zlib` license).
>
> Open this manual directly inside the editor anytime by clicking **`[ ? ]`** in the top-right corner island or pressing **`F1`** (`Help -> Haati Engine & Game Manual`).

---

## 1. How a Game Is Constructed in Haati

Rather than trying to be a generic "jack-of-all-trades" engine, Haati is purpose-built around **fast arena construction, sub-millisecond CSG destruction, Severed-Steel / Titanfall kinetic movement, and zero-overhead Odin hot-reload**:

1. **Greybox & Carve the Arena (`CAD Mode`)**:
   - Click **`CAD Mode`** on `Scene3D`'s top bar.
   - Block out rooms, ramps, pillars, stairs, and arches with **`CSGVolume`** brushes (`Tools 1–7`).
   - Select 2+ CSG volumes with `Ctrl + Click` and **Right-Click anywhere in `Scene3D`** to **Join Brushes Non-Destructively**, **Union (`A + B`)**, **Subtract (`A - B`)**, or **Intersect (`A & B`)**.
2. **Author Hybrid Destruction (`Faker CSG System`)**:
   - Keep convex half-space `CSGVolume` hulls as your authoritative **Jolt Physics + Boolean Destruction Shell**, while dressing visual detail on top.
   - High-impulse explosions carve real physical holes through walls (`csg_op_boolean` / crater cuts); glancing hits write into the 64×64 RGBA8 **Soft Deformation Offset Map** (`0.00 ms` Jolt rebuild cost).
3. **Drop Gameplay Pawns & Plugins (`plugins/<your_game>`)**:
   - Keep your private game project inside its own plugin folder (`plugins/<your_game>/`, exempt in `.gitignore` when desired) and place custom `@(component)` pawns, spawners, and props into your scenes.
4. **Attach `.bodin` Blueprints or Pure `.odin` Systems**:
   - Add a **`VisualScriptRunner`** component to any entity and click **`+ New`** to create an event-driven **`.bodin`** ("Blueprint Odin") script, or write shared `@(hot_proc)` gameplay code in `moonhug/hot_scripts/*.odin`.
5. **Test & Hot-Swap in ~240 ms**:
   - Click **Play / Simulate** in the center toolbar to play immediately in-viewport.
   - Press **`F7`** inside **Blueprint Studio** or **Odin Micro-Studio** to recompile `hot_cartridge.dll` and hot-swap live gameplay code in **~240 ms** without restarting the editor!

---

## 2. CAD & Destructible CSG Blockout (`plugins/cad_csg`)

| Action | How to Use It |
| :--- | :--- |
| **Draw Primitives (`Tools 1–7`)** | Select **Box**, **Cylinder**, **Wedge/Ramp**, **Polygon Extrude** (angle-snaps cleanly from your previous segment), **Stairs**, or **Arch**. |
| **Right-Click CSG / Mesh Booleans** | Hold `Ctrl + Click` to select Target **A** and Tool **B** in `Scene3D`, then **Right-Click**: choose **Join Brushes into CSG A (Keep Editable Stack)**, **Union (`A + B`)**, **Subtract (`A - B`)**, or **Intersect (`A & B`)**. |
| **Delete vs Keep Tool B** | By default, Subtract/Union removes Tool **B** so carved doorways are immediately open. Need to stamp one cutter into 5 walls? Use **Right-Click -> Boolean & Keep Tool B Untouched** (or uncheck `Delete Tool B After Boolean` in Drawer 2). |
| **Brush Stack Ordering** | `.Subtract` (`-`) brushes carve `.Additive` (`+`) brushes above them in the stack. Use **`[▲]`**, **`[▼]`**, **`[Dup]`**, or **`[Move '-' Cuts Last]`** in Drawer 1 (`1. Brushes`). |
| **Pivot & Ground Alignment** | Right-click any single `CSGVolume` -> **`CSG Volume Quick Actions`** -> **`Center Pivot to Geometry`** (moves gizmo to center with zero world-space geometry shift!) or **`Drop Bottom to Ground (Y = 0)`**. |

---

## 3. How the In-Engine IDE Works: `.odin` vs `.bodin`

Haati ships two tightly connected programming surfaces that compile to the **exact same native x64 machine code**:

### A. Pure `.odin` Scripts (`Odin Micro-Studio`)
- Located in `moonhug/hot_scripts/*.odin` (for `F7` hot-swappable gameplay) or `plugins/*/*.odin` (engine/plugin packages).
- Edited directly in **Odin Micro-Studio** (`Window -> Odin Micro-Studio`), featuring:
  - **Async Smart Autocomplete** (`Ctrl + Space`, dot-completion, Blueprint variable & proc awareness, hover type peek).
  - **`Ctrl + MouseWheel` Vector Font Zoom** (`65%` – `240%`) + **`F11` Smart Enlarge**.
  - **`Using / Spaces` Selector** (`using math`, `using linalg`, `ease`, `rand`) so you never guess imports.
- **Does the IDE decompile arbitrary `.odin` files into visual node spaghetti?**
  - **No — on purpose!** Arbitrary loops and structs turned into visual wires become unreadable spaghetti. Instead, any `@(hot_proc)` procedure in `.odin` becomes a **clean callable node** inside Blueprints, and clicking it opens the **Scoped Popup Micro-IDE** focused on just that procedure!

### B. `.bodin` ("Blueprint Odin") Unified Visual + Code Files (`Blueprint Studio`)
- Stored in `assets/scripts/<name>.bodin` (legacy `.mhgraph` files also load seamlessly).
- **One Single Git-Friendly File**:
  1. **Top of `.bodin`**: 100% valid, human-readable Data-Oriented Odin code (`<Name>_BP_State` struct + `#force_inline` node procs + `@(hot_proc)` C-ABI entry points).
  2. **Bottom of `.bodin`**: A line-comment block `// @BODIN_GRAPH_V1 ... // @BODIN_GRAPH_END` storing the 3-column visual node positions, wires, categories, and slider metadata!
- When you press **`F7`** (`Bake & Hot-Swap`), Blueprint Studio updates `<name>.bodin` AND mirrors `moonhug/hot_scripts/<name>_mhgraph_generated.odin` (`*_generated.odin` is git-ignored) so `hot_cartridge.dll` compiles straight to native machine code!

---

## 4. Event-Driven Odin Delegates (`0.00 ms` Idle Blueprints)

Instead of Unreal's hidden per-actor Tick overhead, Haati Blueprints use **Odin-style explicit procedure delegates (`◇`)**:

1. **`Event_Tick` Is 100% Opt-In**: If you don't place an `Event_Tick` node, the transpiler emits **zero** tick function (`0.00 ns` idle CPU cost).
2. **Bind & Swap Procedures on Demand**:
   - Wire `Event_Init` (`▷`) -> **`Bind_Input_Action`** (e.g., `"Jump"`).
   - Connect a **`Custom_Proc_Entry`** node's cyan **`◇ Delegate`** pin (`On_Jump`) into `Bind_Input_Action`'s `Target` pin.
   - Want your character's `"Action"` button to switch from *Interact* to *Detonate* mid-mission? Run **`Unbind_Input_Action`** -> **`Bind_Input_Action`** wired to a second `◇` procedure!
3. **3-Column Blueprint Layout**:
   - **Left (*My Blueprint*)**: Events, Procedures (`◇`), Variables (click `👁` to expose per-entity sliders in the Scene Inspector!), and Custom Delegates.
   - **Center (*Graph*)**: Node canvas with 4 pin types: `▷` Exec, `◇` Delegate, `●` Copy (`T`), `◆` Mutable Pointer (`^T`).
   - **Right (*Details*)**: Rename, Category, Tooltip, Slider Min/Max, Input Action picker, and `[DEV]` Debug Key selector.

---

## 5. Overwatch Out-of-Process Flight Recorder (`[ ● ]` Corner Button)

A crash stack trace tells you *where* the engine died, not *what you just clicked or why frame time spiked*.
- Click the red **`[ ● ]` Record** button in the **top-right corner button island** (next to `[ ? ]` and `[ ↻ ]`).
- Haati extends zero-allocation telemetry hooks and launches **`builds/MoonHug_Overwatch.exe`** as a **separate OS process** reading lock-free Shared Memory.
- Even if the editor hard-crashes to desktop, `MoonHug_Overwatch.exe` survives and writes `moonhug/logs/overwatch/overwatch_latest.md` with your recent actions, selections, hot-swaps, and per-phase millisecond spikes.
- Clicking Stop retracts all hooks back to **`0 ns` overhead**.

---

## 6. Rubber-Duck Design Audit Log

While writing this manual and explaining every workflow out loud ("rubber-ducking"), four friction points stood out as unnecessarily awkward — and were simplified directly in code:

1. **Right-Click Multi-CSG Booleans**: Selecting two CSG objects and right-clicking in `Scene3D` previously didn't surface Boolean operations. *Fixed*: Right-clicking anywhere in `Scene3D` with 2+ CSGs/Meshes selected immediately shows **Join Brushes (Editable Stack)**, **Union**, **Subtract**, and **Intersect** at the top of the menu.
2. **Ghost Cutter Object After Subtract**: Subtracting `B` from `A` left `B` visible inside the new hole, making users think Subtract failed. *Fixed*: UI Booleans now consume/delete Tool `B` by default, with an explicit `Keep Tool B` submenu/checkbox for multi-stamp workflows.
3. **Two Files Per Blueprint (`.mhgraph` + `.odin`)**: Having separate graph JSON and Odin files felt redundant when both describe one script. *Fixed*: `.bodin` stores valid transpiled Odin code on top and `@BODIN_GRAPH_V1` layout metadata at the bottom of a single file.
4. **Un-Reorderable Subtract Brushes & Drifting Pivots**: Subtract brushes added early in a `CSGVolume` couldn't easily be moved after new additive brushes, and off-center CSG sketches had awkward gizmo pivots. *Fixed*: Added `[▲]`/`[▼]`/`[Dup]`/`[Move '-' Cuts Last]`, `Center Pivot to Geometry`, and `Drop Bottom to Y=0`.

---

## 7. Essential Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`F1`** | Open **Haati Engine & Game Manual** (or click `[ ? ]` in top-right toolbar) |
| **`F7`** | **Bake `.bodin` & Hot-Swap `hot_cartridge.dll`** (~240 ms live reload) |
| **`Q` / `W` / `E` / `R`** | Pick / Move / Rotate / Scale in `Scene3D` |
| **`F`** | Frame selected entity / CSG volume in `Scene3D` |
| **`Ctrl + Click`** | Multi-select CSG / Mesh objects for Right-Click Booleans |
| **`Ctrl + Z` / `Ctrl + Y`** | Undo / Redo (Scene & CAD CSG/Mesh history) |
| **`Ctrl + MouseWheel`** | Smooth vector font zoom (`65%`–`240%`) in Odin Micro-Studio & Popup IDE |
| **`F11`** | Smart Enlarge / Restore in Scoped Odin Popup IDE |
| **`Ctrl + Space`** | Trigger Async Smart Autocomplete in Odin Micro-Studio |
