# Haati Engine

> *"It compiles. All 772 tests pass. That tells you the tests pass. It does not tell you the thing works."*
> — every engine programmer, eventually

**Haati** is a Windows-only 3D game engine and integrated Odin studio, forked from the
[MoonHug](LICENSE) engine (zlib). It has grown a lot of features in a short time. Read that
sentence again, slowly, because it is both the selling point and the warning label.

**In one line:** multicore Windows x64 game engine & integrated Odin studio (MoonHug fork):
Jolt physics, destructible CSG, `.bodin` visual scripting with F7 hot-reload, HDR bloom, tiled
async NavMesh, `.pak` packaging, and a crash watchdog because the rest of that list needs one.

---

## Where It Actually Stands (November 2026)

**Status: pre-alpha. Personal project. Not production-ready. Not close.**

What was verified on the last commit, on one Windows x64 machine:

| Check | Command | Result |
|---|---|---|
| Typecheck (`-vet-unused`) | `tools/haati -- check --project-hub` | exit 0 |
| Test suite | `tools/haati -- test` | 772 / 772 passed |
| Release build | `tools/haati -- build --project-hub` | `builds/Haati.exe` built |

What that does **not** cover: anyone actually building a game in it. The newest editor
features below are unit-tested, not battle-tested. The user project that was supposed to
battle-test them got scrapped and is being rebuilt from scratch, which tells you something.

---

## What's In The Box

### Editor & Odin Micro-Studio
- **Project Hub** — compact startup launcher (`--project-hub` or hold `Shift`), `Ctrl+Wheel`
  scales text *and* the window. It no longer overwrites your main editor window size on close.
  That was a bug. It shipped. It's fixed.
- **Embedded Odin IDE** — syntax highlighting, autocomplete, Find/Replace, background
  `odin check` diagnostics on a worker thread (in-RAM syntax pass first, real compiler second).
- **Full-declaration editing** — procedures are edited as complete `name :: proc(...) -> (...) { }`
  declarations. The old "LOCKED SIGNATURE" banner is gone. Locking the signature turned
  out to be the wrong answer to "what if the user breaks something": you just couldn't fix anything.
- **Signature-change call-site review** — change a proc's signature and, before anything hits
  disk, the IDE AST-scans writable scripts for callers, shows each one with the old line and a
  red underline, offers an auto-fill for an appended default argument, and commits everything
  atomically. Think "Rider refactor queue", minus a decade of JetBrains polish.
- **Read-only engine sources** — `haati/engine`, `haati/editor`, `haati/packages`, `plugins/`,
  `tools/` and the built-in hot scripts open read-only: look, copy, or clone into your own
  `.bodin`. You do not get to edit the engine from inside the engine while it's running.
  Ask me how we learned that.

### Blueprint Studio (`.bodin` visual scripting)
- `.bodin` = one file holding real Odin source (your "Zone 1") plus the generated graph code
  and layout. Graphs transpile to plain Odin and hot-swap as a `.dll` cartridge (`F7`).
- **`::` RAM scratchpad** — right-click the canvas (or drop a wire), type `::` first, and the
  search box turns into a small Odin editor. A `proc` becomes a node, a `struct`/`enum`/const
  goes into Zone 1, and `hp: f32` / `hp := 100` becomes a field on the **Active Struct**.
  Nothing touches disk until Bake/`F7`. The leading `::` is deliberate: hard to type by accident.
- **Structs & Fields** dock — Self State (component vars) and POD structs in one place, with an
  Active Struct selector.
- **Smart pin/wire remap** — edit a node's signature and existing wires are kept when the pin
  name+type still matches, or the same data slot keeps the same type; everything else is cut.
  It's a heuristic. Heuristics are wrong sometimes. Check your wires.
- **RAM Sandbox pill** (`Unsaved` + `Revert` vs `Disk Synced`) and a **Navigate / Usages** jump list.
- Built-in nodes open a read-only Odin preview. That preview is an *illustration* of what the
  node does, not the exact transpiler output. Don't paste it into prod and expect miracles.

### Runtime & Rendering
- **Physics: Jolt Physics via JoltC** (`haati/external/jolt`): rigidbodies, colliders, joints and
  the character controller in `physics3d`, plus the collision side of destructible CSG.
- Multicore job system for physics, culling and scene work.
- Shadow atlas (directional cascades, spot, point cubemaps), HDR bloom, `Lit / Unlit / FakeLight`
  viewport modes.
- Destructible CSG ("Faker CSG"): runtime booleans, surface stamps, mesh deformation, and Jolt
  collision hulls.
- Control Rig / procedural character motion (IK, blend spaces, spring bones).
- Async tiled NavMesh, slow-mo time scale, read-only `.pak` VFS + external project packaging.

### Crash Survival (because it *will* crash)
- **Watchdog** — an out-of-process guardian that waits on the editor's process handle,
  keeps unsaved scene / camera / dirty code tabs in a 16 MB shared-memory vault, relaunches the
  editor after a crash and quarantines hot scripts so the same bad script doesn't take it down
  again. Mascot is a wolf. The wolf is not that smart; it restores state, it doesn't fix bugs.
- **Overwatch** (`builds/Haati_Overwatch.exe`) — out-of-process crash / frame-spike recorder.
- Hot scripts run behind a sandbox fault handler with `UNSAFE:` tooltips on raw pointers, slices
  and by-ref pins. We don't forbid the sharp tools. We label them and tell you how they'll cut you.

### Scene Format
- **`HTSCN001`** binary `.scene`: tagged binary payload, CRC32-checked, with an embedded
  plain-text summary (hierarchy + dependency GUIDs) at the front, so humans and tools can read
  what's in it without parsing everything:
  ```powershell
  .\tools\odin\odin.exe run tools/haati -- scene-info path\to\level.scene
  ```
  Legacy JSON scenes still load.

---

## Known Problems (the honest section)

- **Windows x64 only.** No Linux, no macOS. Win32 APIs are wired through the watchdog, vault and
  hot-reload path. Porting is a project, not a checkbox.
- **The IDE has a history.** Earlier builds crash-looped while typing, pointed at errors you
  couldn't jump to, and hitched every few seconds. Most of that has been fixed. "Most" is
  doing real work in that sentence.
- **The MoonHug → Haati rename isn't fully dead.** Old `moonhug:` imports in user scripts are
  linted and can be migrated, and the build still passes `-collection:moonhug=haati` for
  compatibility. A botched migration once left the editor stuck in a restart loop. Back up
  your project before running migration tools. Back up your project anyway.
- **The call-site scanner has a scope.** It checks open tabs, the active project,
  `assets/scripts` and `haati/hot_scripts`, about 4 directories deep, and skips protected engine
  paths. Callers outside that won't show up. Default-argument auto-fill only handles a new
  parameter appended at the end.
- **Visual scripting is young.** Pin remapping, Zone-1 RAM staging and the scratchpad all work
  in tests; real graphs will find edge cases. Save often. Bake often.
- **Feature count far ahead of hardening.** This README lists a lot of features. Every one is a
  surface for bugs. Treat it like a prototype, because it is one.

---

## Quick Start

Use the **bundled** Odin compiler. A different Odin on your `PATH` will eventually bite you with
a version mismatch at 2 AM.

```powershell
cd Haati_Engine
$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Odin' }) -join ';'

# First-time setup (vendored C libs, plugin junctions in haati/packages/)
.\tools\odin\odin.exe run tools/haati -- setup

# Build & launch the editor (add --project-hub to start in the Project Hub)
.\tools\odin\odin.exe run tools/haati -- run

# Typecheck / test / stress / release build
.\tools\odin\odin.exe run tools/haati -- check --project-hub
.\tools\odin\odin.exe run tools/haati -- test
.\tools\odin\odin.exe run tools/haati -- test --stress
.\tools\odin\odin.exe run tools/haati -- build --project-hub
```

> `tools/mh` and the `Makefile` forward to the same build system.
> On Windows, remove NTFS junctions with `cmd /c rmdir "<path>"`, **never** a recursive delete,
> unless you enjoy losing the folder the junction points at.

## Troubleshooting

- "It works on my machine." Correct. It is one machine.
- Launch `Haati_Editor.exe` or `tools/haati -- run` so the runtime `.dll`s in `builds/` resolve.
- Rebuilding shaders needs `shadercross` / `dxc` / `spirv-cross`.
- If the editor relaunches itself after a crash, that's the watchdog. If it keeps relaunching,
  it's the quarantine or a bad project: start with `Shift` held to get the Project Hub.

## License

zlib — see [LICENSE](LICENSE). All original MoonHug copyright notices are preserved.
Third-party components and icon/font licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
