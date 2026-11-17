# Third-party notices

MoonHug is licensed under the zlib License (see `LICENSE`). It bundles or
links the software below. Each item says where it ends up: **runtime** means
it is linked into games built with MoonHug, so a shipped game inherits that
license's notice obligations; **editor** means it is only in the editor
binary and never reaches a game.

| Component | License | Where | Source |
|---|---|---|---|
| Odin core library | BSD-3-Clause | runtime + editor | https://github.com/odin-lang/Odin |
| SDL3, SDL3_mixer | zlib | runtime + editor | https://github.com/libsdl-org/SDL |
| stb (image, image_write, image_resize, truetype, vorbis) | MIT / public domain | runtime + editor | https://github.com/nothings/stb |
| cgltf | MIT | editor (glTF import) | https://github.com/jkuhlmann/cgltf |
| Box2D | MIT | runtime, `physics2d` package only | https://github.com/erincatto/box2d |
| Jolt Physics | MIT, Jorrit Rouwe | runtime, `physics3d` + `cad_csg` packages (`joltc.dll`) | https://github.com/jrouwe/JoltPhysics |
| JoltC (C API + Odin bindings) | MIT, Amer Koleci and Contributors | runtime, `physics3d` + `cad_csg` packages | https://github.com/amerkoleci/joltc |
| Dear ImGui | MIT | editor | https://github.com/ocornut/imgui |
| odin-imgui (bindings) | MIT, Trevin Sorenson | editor | `haati/external/odin-imgui/LICENSE` |
| Material Symbols Outlined (icon font) | Apache-2.0 | editor | `haati/external/fonts/material/LICENSE-Material.txt` |
| Phosphor Icons (icon font) | MIT | editor | `haati/external/fonts/phosphor/LICENSE-Phosphor.txt` |
| Watch-Wolf emblem (`wolf-head` by Lorc, game-icons.net) | CC-BY 3.0 | editor | `haati/external/icons/LICENSE-GameIcons.txt` |

## What a game built with MoonHug must include

- **zlib** (MoonHug, SDL3): nothing — zlib requires no notice in binary
  distributions.
- **BSD-3-Clause** (Odin core): the Odin copyright notice and license text
  in the game's documentation or credits.
- **MIT** (stb, Box2D, Jolt Physics + JoltC when `physics3d` / `cad_csg` are used): the
  respective copyright notice and license text in the game's documentation or credits.

Editor-only components (Dear ImGui, odin-imgui, Material Symbols, Phosphor, cgltf) and
the CC0 assets impose nothing on shipped games. The CC-BY 3.0 Watch-Wolf emblem is
editor-only too, and is credited here: "Icons made by Lorc from https://game-icons.net".
If you put game-icons.net art in a shipped game, credit the author in your game.

Full license texts live with each component in the Odin `vendor/` tree or
the paths listed above.
