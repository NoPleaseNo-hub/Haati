# Editor fonts

Fonts for the **editor UI chrome** (not app/game resources — those live in
`assets/`).

Text uses **Roboto Medium** (`haati/editor/Roboto-Medium.ttf`, Apache-2.0),
merged with two embedded vector icon sets via `#load` in `haati/editor/fonts.odin`
so the editor binary is self-contained with zero runtime working-directory coupling:

## `material/`

- `MaterialSymbolsOutlined.ttf` — primary inline UI icon font. **Apache-2.0**
  (`LICENSE-Material.txt`). Merged directly into the default font (`GlyphOffset`
  aligned to baseline) and used by `ICON_MD_*` in `haati/editor/icons/material_icons.odin`
  plus 3D scene icon gizmos (`haati/editor/handles/icons.odin`).
- `MaterialSymbolsOutlined.codepoints` — icon name → codepoint map (3,500+ icons).
- `LICENSE-Material.txt` — Apache-2.0 license text.

## `phosphor/`

- `Phosphor.ttf` — Phosphor Regular icon font (1,530 icons). **MIT**
  (`LICENSE-Phosphor.txt`). Loaded as a merged Roboto + Phosphor companion font
  (`editor_phosphor_font` / `widgets.phosphor_font`) and exposed as `ICON_PH_*` in
  `haati/editor/icons/phosphor_icons.odin` plus `widgets.phosphor_icon_button` /
  `widgets.push_phosphor_font` + `widgets.pop_phosphor_font`.
- `Phosphor.codepoints` — icon name → codepoint map generated from `Phosphor`.
- `LICENSE-Phosphor.txt` — MIT license text.

## External Game HUD Textures (`game-icons.net`)

- SVG packs from `game-icons.net` are **CC-BY 3.0** (some CC0) per contributor and
  require creator credit in a shipped game (`"Icons made by {author}"`). Keep any
  selected RPG/shooter HUD SVGs/PNGs per-game inside `<Project>/assets/icons/`
  alongside attribution rather than baking all 4,100+ SVGs into every binary.

## Notes

- imgui does NOT do ligatures — icons are addressed by raw PUA codepoint
  (`\uXXXX`), not name. See `material_icons.odin` and `phosphor_icons.odin`.
- Both Roboto Medium and the icon merges load at an explicit `FONT_SIZE` (15px)
  so each merge can nudge the icon baseline cleanly via `GlyphOffset`.
