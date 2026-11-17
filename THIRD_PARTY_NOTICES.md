# Third-party notices

Haati (a fork of MoonHug) is licensed under the zlib License (see `LICENSE`). It bundles
or links the software below. Each item says where it ends up: **runtime** means it is
linked into games built with Haati, so a shipped game inherits that license's notice
obligations; **editor** means it is only in the editor binary and never reaches a game.

| Component | License | Where | License text in this repo | Source |
|---|---|---|---|---|
| Odin core library | BSD-3-Clause | runtime + editor | `tools/odin/LICENSE` | https://github.com/odin-lang/Odin |
| SDL3, SDL3_mixer | zlib | runtime + editor | `tools/odin/vendor/sdl3/LICENSE.txt` | https://github.com/libsdl-org/SDL |
| stb (image, image_write, image_resize, truetype, vorbis) | MIT / public domain (dual) | runtime + editor | end of each header in `tools/odin/vendor/stb/src/*.h` | https://github.com/nothings/stb |
| cgltf | MIT | editor (glTF import) | `tools/odin/vendor/cgltf/LICENSE` | https://github.com/jkuhlmann/cgltf |
| Box2D | MIT | runtime, `physics2d` package only | `tools/odin/vendor/box2d/LICENSE` | https://github.com/erincatto/box2d |
| Jolt Physics | MIT, Jorrit Rouwe | runtime, `physics3d` + `cad_csg` (`joltc.dll`) | `haati/external/jolt/LICENSE-JoltPhysics.txt` | https://github.com/jrouwe/JoltPhysics |
| JoltC (C API + Odin bindings) | MIT, Amer Koleci and Contributors | runtime, `physics3d` + `cad_csg` | `haati/external/jolt/LICENSE-JoltC.txt` | https://github.com/amerkoleci/joltc |
| Dear ImGui | MIT, Omar Cornut | editor | `haati/external/odin-imgui/LICENSE-DearImGui.txt` | https://github.com/ocornut/imgui |
| odin-imgui (bindings) | MIT, Trevin Sorenson | editor | `haati/external/odin-imgui/LICENSE` | see `haati/external/odin-imgui/README.md` |
| Roboto Medium (UI text font) | Apache-2.0, Google | editor | `haati/editor/LICENSE-Roboto.txt` | https://github.com/googlefonts/roboto |
| Material Symbols Outlined (icon font) | Apache-2.0, Google | editor | `haati/external/fonts/material/LICENSE-Material.txt` | https://github.com/google/material-design-icons |
| Phosphor Icons (icon font) | MIT | editor | `haati/external/fonts/phosphor/LICENSE-Phosphor.txt` | https://github.com/phosphor-icons/core |
| Watch-Wolf emblem (`wolf-head` by Lorc, game-icons.net) | CC-BY 3.0 | editor | `haati/external/icons/LICENSE-GameIcons.txt` | https://game-icons.net |

> `tools/odin/...` paths belong to the bundled Odin toolchain, which is **not** committed to
> this repository; those license files appear once the toolchain is installed (they ship
> with Odin). Everything under `haati/` is committed, and the Jolt binaries
> (`haati/external/jolt/joltc.dll`, `joltc.lib`) are redistributed here, so their license
> texts are too.

## What a game built with Haati must include

- **zlib** (Haati/MoonHug, SDL3): nothing — zlib requires no notice in binary
  distributions.
- **BSD-3-Clause** (Odin core): the Odin copyright notice and license text
  in the game's documentation or credits.
- **MIT** (stb, Box2D when `physics2d` is used, Jolt Physics + JoltC when `physics3d` /
  `cad_csg` are used): the respective copyright notice and license text in the game's
  documentation or credits. In practice: if your game has 3D physics, ship
  `LICENSE-JoltPhysics.txt` and `LICENSE-JoltC.txt` with it.

Editor-only components (Dear ImGui, odin-imgui, Roboto, Material Symbols, Phosphor,
cgltf) and the CC0 assets impose nothing on shipped games. The CC-BY 3.0 Watch-Wolf
emblem is editor-only too, and is credited here: "Icons made by Lorc from
https://game-icons.net". If you put game-icons.net art in a shipped game, credit the
author in your game.
