package editor

// =============================================================================
// HAATI ENGINE & GAME CONSTRUCTION MANUAL (`view_manual.odin`)
// =============================================================================
// Built-in, searchable, low-friction user manual explaining how every major
// subsystem in Haati (purpose-built Destructive CSG & Action fork of MoonHug)
// is intended to work, how a game is constructed end-to-end, and the
// "Rubber-Duck Audit" simplifications baked directly into the workflow.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import cs "moonhug:editor/code_studio"
import "moonhug:editor/icons"
import thm "moonhug:editor/theme"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "../engine"
import im "moonhug:external/odin-imgui"

@(private = "file")
_Manual_Chapter :: struct {
	title:    string,
	subtitle: string,
	keywords: string,
	bullets:  []string,
	tip:      string,
}

@(private = "file")
_MANUAL_CHAPTERS := [7]_Manual_Chapter{
	{
		title    = "1. How a Game Is Constructed",
		subtitle = "Scenes, Entities, Purpose-Built Components, and Play vs Hot-Swap",
		keywords = "game architecture scene entity component pawn spawner play simulate f7 relaunch",
		bullets  = {
			"1. Greybox & Carve Arena: Enter CAD Mode on Scene3D's top strip and block out floors, ramps, and cover using Destructible CSGVolume brushes.",
			"2. Dress Visuals (Faker Hybrid): Keep lightweight CSGVolume hulls as the authoritative Jolt physics & destruction shell while attaching detailed visual meshes.",
			"3. Drop Gameplay Pawns & Plugins: Keep your game project in its own plugin folder (`plugins/<your_game>/`) and place custom @(component) pawns, spawners, and props.",
			"4. Wire Gameplay Logic: Attach a VisualScriptRunner (.bodin Blueprint) for event-driven switches/doors/abilities, or write pure .odin @(hot_proc) systems.",
			"5. Iterate Live: Press Play/Simulate in the center bar to test immediately; press F7 (~240 ms) to hot-swap gameplay logic without restarting!",
		},
		tip = "Rule of Thumb: F7 hot-swaps .bodin / @(hot_proc) gameplay logic in ~240 ms. Only use the far-right Relaunch button when you edit core engine struct layouts.",
	},
	{
		title    = "2. CAD & Destructible CSG Blockout",
		subtitle = "Tools 1-7, Right-Click Booleans, Editable Brush Stack, and Pivot Tools",
		keywords = "cad csg boolean union subtract intersect right click join brush stack pivot ground snap",
		bullets  = {
			"Tools 1-7: Switch to CAD Mode to draw Boxes, Cylinders, Wedges, Polygon Extrusions (angle-locked from your previous vertex!), Stairs, and Arches.",
			"Right-Click CSG & Mesh Booleans: Select 2+ CSG or Mesh objects with Ctrl+Click and Right-Click anywhere in Scene3D to Union (A+B), Subtract (A-B), Intersect (A&B), or Join Brushes Non-Destructively!",
			"No More 'Ghost Tool B': Subtract/Union automatically deletes Tool B by default so carved doorways are immediately open (uncheck 'Delete Tool B' or use 'Boolean & Keep Tool B' when stamping repeats).",
			"Brush Stack Order Matters: '-' Subtract brushes carve '+' Additive brushes above them in the stack. Use [Up]/[Down], [Dup], or [Move '-' Cuts Last] anytime.",
			"Pivot & Ground Utilities: Right-click any CSGVolume (or use Drawer 1) for 'Center Pivot to Geometry' (zero world drift!) and 'Drop Bottom to Y=0'.",
		},
		tip = "Want editable brushes after joining two CSG objects? Pick 'Join Brushes into CSG A (Keep Editable Stack)' in the Scene3D right-click menu!",
	},
	{
		title    = "3. The Faker CSG Hybrid System",
		subtitle = "Why Haati Splits Visual Art (Mesh A) from Destructible Physics (CSG B)",
		keywords = "faker csg hybrid destruction geomod crater deformation jolt physics ghoul",
		bullets  = {
			"Why Not Jack-of-All-Trades Mesh Destruction? Cutting arbitrary 50k-tri artist FBX meshes in real time causes non-manifold slivers and Jolt physics spikes.",
			"The Faker Solution: Convex half-space CSG hulls handle Jolt collision + sub-millisecond boolean craters cleanly, while visual meshes/stamps deform or swap on top.",
			"Soft Deformation Stamps: Non-penetrating impacts write into a 64x64 RGBA8 offset map (p' = p0 + delta_p) while static Jolt colliders stay 0.00 ms untouched.",
			"Skeletal / Ghoul Carve: Multi-CSG booleans also recognize character bone CSG hierarchies so high-caliber hits carve limb volumes cleanly.",
		},
		tip = "Use 'Smart Clean & Simplify' before 'Bake CSG -> Static Mesh' when retiring finished background architecture that never needs runtime destruction.",
	},
	{
		title    = "4. .bodin Blueprints & Odin Delegates",
		subtitle = "3-Column Unreal Layout + Zero-Overhead Odin Delegate Event Binding",
		keywords = "bodin mhgraph blueprint visual script delegate input bind unbind tick init variables",
		bullets  = {
			"What Is .bodin ('Blueprint Odin')? One unified file in assets/scripts/<name>.bodin containing valid Data-Oriented Odin code on top AND // @BODIN_GRAPH_V1 visual node layout at the bottom!",
			"Zero-Cost Idle (0.00 ms): Unlike traditional Blueprint VMs, Event_Tick is 100% opt-in. A Blueprint without Event_Tick emits zero per-frame tick code.",
			"Odin Delegate Workflow: Wire Event_Init -> Bind_Input_Action (or Bind_Debug_Key) and connect the cyan diamond Delegate pin from a Custom Procedure (e.g. On_Jump).",
			"Dynamic Rebinding: Because bindings are explicit nodes, you can Unbind_Input_Action and Bind_Input_Action to a different procedure mid-combat (e.g. Dash vs Grapple state)!",
			"3-Column Layout: Left = My Blueprint (Events, Variables with Eye icon for per-entity Inspector sliders, Delegates). Center = Graph. Right = Details Inspector.",
		},
		tip = "Click the '.bodin' button in Blueprint Studio's top bar to inspect the exact Odin struct & @(hot_proc) code inside Odin Micro-Studio!",
	},
	{
		title    = "5. Odin Micro-Studio & Using Spaces",
		subtitle = "Pure .odin vs .bodin, Scoped Popup IDE, Async Autocomplete, and Zoom",
		keywords = "odin micro studio ide autocomplete ctrl wheel zoom f11 using self math linalg hot_proc",
		bullets  = {
			"How .odin and .bodin Coexist: Write core math, AI, and shared helpers in pure .odin files (moonhug/hot_scripts/*.odin). Mark any C-ABI function @(hot_proc) and it becomes callable from .bodin graphs — no fragile reverse-decompilation into spaghetti wires!",
			"Scoped Popup IDE: Click any Odin Function Node in a Blueprint to edit just that function's body with locked Copy (T) vs ^Ref (^T) pin badges.",
			"Using / Spaces Selector: Click 'Using (N)' in Blueprint Studio or Odin Micro-Studio to toggle 'using self' (direct variable access without bp. prefix!), 'using math', 'using linalg', 'ease', or 'rand'.",
			"IDE Ergonomics: Ctrl + MouseWheel zooms vector fonts smoothly (65%-240%), F11 (or header button) toggles Zen Enlarge, Ctrl+Space opens async autocomplete, Ctrl+F opens Find/Replace.",
		},
		tip = "Both pure .odin and .bodin compile into the exact same native x64 machine code inside hot_cartridge.dll!",
	},
	{
		title    = "6. Overwatch Recorder & TimeScale",
		subtitle = "Out-of-Process Crash/Spike Flight Recorder & Harmonic Time Layers",
		keywords = "overwatch recorder crash spike performance corner button timescale slowmo",
		bullets  = {
			"Why Out-of-Process? A crash log only shows the final stack trace. Clicking the red [ Record ] dot in the top-right corner island launches builds/MoonHug_Overwatch.exe over OS Shared Memory.",
			"Zero Cost When Off: When stopped, engine telemetry hooks are retracted (0 ns overhead). When active, Overwatch records frame-phase spikes + what you clicked, selected, and hot-swapped right up to any freeze or crash!",
			"Right-Click the Record Dot: Drop manual bookmark markers or open moonhug/logs/overwatch/overwatch_latest.md directly in Odin Micro-Studio.",
			"Harmonic TimeScale: Gameplay scripts read api.get_object_dt(self, raw_dt) so player slow-mo / dive bullet-time scales world projectiles cleanly while keeping responsive player feel.",
		},
		tip = "Before reproducing a tricky physics spike or crash, click the red Record dot in the top-right corner island first!",
	},
	{
		title    = "7. Rubber-Duck Audit & Shortcuts",
		subtitle = "Workflows Simplified While Writing This Manual + Essential Keybindings",
		keywords = "rubber duck audit shortcuts hotkeys f1 f7 ctrl click undo",
		bullets  = {
			"Rubber-Duck Fix #1 (Right-Click Booleans): Selecting 2 CSGs and right-clicking previously showed no Boolean items. Fixed: Scene3D right-click now surfaces Join Brushes, Union, Subtract, and Intersect at the very top.",
			"Rubber-Duck Fix #2 (Ghost Cutter B): Subtracting B from A previously left B sitting inside the hole, making the cut look broken! Fixed: Booleans now consume Tool B by default (with a 'Keep Tool B' option).",
			"Rubber-Duck Fix #3 (Split .mhgraph + .odin): Explaining two separate files for one visual script felt redundant. Fixed: .bodin unifies native Odin source + @BODIN_GRAPH_V1 layout in one Git-friendly file.",
			"Rubber-Duck Fix #4 (Subtract Order & Off-Center Pivots): Added [Move '-' Cuts Last], [Up]/[Down]/[Dup] in the Brush Stack, 'Center Pivot to Geometry', and 'Drop Bottom to Y=0'.",
			"Essential Keys: [F1] Manual | [F7] Bake & Hot-Swap DLL | [Q/W/E/R] Pick/Move/Rotate/Scale | [F] Frame Selected | [Ctrl+Click] Multi-Select for Booleans | [Ctrl+Wheel] Code Zoom.",
		},
		tip = "If any workflow ever takes more than 2 clicks to explain out loud to a rubber duck, simplify the tool rather than lengthening the manual!",
	},
}

@(private = "file")
_manual_state: struct {
	selected_chapter: int,
	search_buf:       [128]byte,
}

@(toolbar={zone="right", order=19})
_toolbar_manual_button :: proc() {
	if im.Button(icons.ICON_MD_HELP + "###ToolbarManualBtn", _toolbar_button_size(BUTTON_PLAY_TEXT)) {
		wnd.open("engine_manual")
	}
	widgets.tooltip("Haati Engine & Game Manual (F1)\nQuick guide to CAD/CSG, Faker Hybrid Destruction, .bodin Blueprints, Odin Studio & Overwatch")
}

@(menu_item={path="Help/Haati Engine & Game Manual", order=0, shortcut="F1"})
menu_open_engine_manual :: proc() {
	wnd.open("engine_manual")
}

@(menu_item={path="Window/Haati Engine Manual", order=-10, shortcut=""})
menu_window_open_engine_manual :: proc() {
	wnd.open("engine_manual")
}

@(private = "file")
_chapter_matches_query :: proc(ch: _Manual_Chapter, q_lower: string) -> bool {
	if q_lower == "" do return true
	if strings.contains(strings.to_lower(ch.title, context.temp_allocator), q_lower)    do return true
	if strings.contains(strings.to_lower(ch.subtitle, context.temp_allocator), q_lower) do return true
	if strings.contains(strings.to_lower(ch.keywords, context.temp_allocator), q_lower) do return true
	for b in ch.bullets {
		if strings.contains(strings.to_lower(b, context.temp_allocator), q_lower) do return true
	}
	return false
}

@(editor_window={id="engine_manual", title="Haati Engine Manual", icon="MENU_BOOK", width=880, height=660})
engine_manual_window_draw :: proc() {
	p := thm.palette()

	// Header & Instant Filter Bar
	im.TextColored(p.accent, icons.ICON_MD_MENU_BOOK + "  Haati Engine — Simplistic User & Game Construction Manual")
	im.SameLine()
	avail_hdr := im.GetContentRegionAvail().x
	if avail_hdr > 170 {
		im.SetCursorPosX(im.GetCursorPosX() + avail_hdr - 165)
		if im.SmallButton(fmt.ctprintf("%s Open MANUAL.md", icons.ICON_MD_DESCRIPTION)) {
			repo_root := engine.resolve_repo_root(context.temp_allocator)
			md_abs, _ := filepath.join({repo_root, "MANUAL.md"}, context.temp_allocator)
			if os.exists(md_abs) {
				cs.open_file_in_studio(md_abs)
				wnd.open("odin_micro_studio")
			}
		}
		widgets.tooltip("Open the full Markdown MANUAL.md inside Odin Micro-Studio")
	}

	im.SetNextItemWidth(-1)
	im.InputTextWithHint(
		"##manual_search",
		"Filter manual topics (e.g. boolean, .bodin, delegate, using, overwatch, pivot)...",
		cstring(raw_data(_manual_state.search_buf[:])),
		len(_manual_state.search_buf),
	)
	raw_q := strings.trim_space(string(cstring(raw_data(_manual_state.search_buf[:]))))
	q_low := strings.to_lower(raw_q, context.temp_allocator)

	im.Separator()

	// 2-Column Layout: Chapter Rail (Left) | Clean Reader + 1-Click Tool Launchers (Right)
	if im.BeginTable("##haati_manual_layout", 2, im.TableFlags_Resizable | im.TableFlags_BordersInnerV) {
		im.TableSetupColumn("Chapters", {.WidthFixed}, 235.0)
		im.TableSetupColumn("Guide", {.WidthStretch})
		im.TableNextRow()

		// Left Column: Chapter List
		im.TableSetColumnIndex(0)
		if im.BeginChild("##manual_chapters_nav", {0, 0}, {}) {
			first_match := -1
			for ch, idx in _MANUAL_CHAPTERS {
				if !_chapter_matches_query(ch, q_low) do continue
				if first_match < 0 do first_match = idx
				is_sel := (_manual_state.selected_chapter == idx)
				if im.Selectable(fmt.ctprintf("%s", ch.title), is_sel) {
					_manual_state.selected_chapter = idx
				}
			}
			if first_match >= 0 && !_chapter_matches_query(_MANUAL_CHAPTERS[_manual_state.selected_chapter], q_low) {
				_manual_state.selected_chapter = first_match
			}
			if first_match < 0 {
				im.TextDisabled("No chapters match filter.")
			}
		}
		im.EndChild()

		// Right Column: Active Chapter Content & Interactive Quick-Launchers
		im.TableSetColumnIndex(1)
		if im.BeginChild("##manual_chapter_body", {0, 0}, {}) {
			ch_idx := clamp(_manual_state.selected_chapter, 0, len(_MANUAL_CHAPTERS) - 1)
			ch := _MANUAL_CHAPTERS[ch_idx]

			im.TextColored(p.accent, "%s", fmt.ctprintf("%s", ch.title))
			im.TextDisabled("%s", fmt.ctprintf("%s", ch.subtitle))
			im.Separator()
			im.Spacing()

			for bullet in ch.bullets {
				im.PushStyleColorImVec4(.Text, p.accent)
				im.Bullet()
				im.PopStyleColor()
				im.SameLine()
				im.TextWrapped("%s", fmt.ctprintf("%s", bullet))
				im.Spacing()
			}

			im.Spacing()
			im.Separator()
			im.TextColored({0.35, 0.94, 0.68, 1.0}, "%s", fmt.ctprintf("Tip: %s", ch.tip))

			// Contextual 1-Click Studio Launchers
			im.Spacing()
			im.Separator()
			im.TextDisabled("Quick Jump:")
			switch ch_idx {
			case 0, 1, 2:
				if im.Button(fmt.ctprintf("%s Open CAD & CSG Panel", icons.ICON_MD_ARCHITECTURE)) {
					wnd.open("cad_csg_panel")
				}
				im.SameLine()
				if im.Button(fmt.ctprintf("%s Open Blueprint Studio", icons.ICON_MD_ACCOUNT_TREE)) {
					wnd.open("mh_visual_script")
				}
			case 3:
				if im.Button(fmt.ctprintf("%s Open Blueprint Studio (.bodin)", icons.ICON_MD_ACCOUNT_TREE)) {
					wnd.open("mh_visual_script")
				}
				im.SameLine()
				if im.Button(fmt.ctprintf("%s Open Input Manager", icons.ICON_MD_KEYBOARD)) {
					wnd.open("input_manager")
				}
			case 4:
				if im.Button(fmt.ctprintf("%s Open Odin Micro-Studio", icons.ICON_MD_CODE)) {
					wnd.open("odin_micro_studio")
				}
				im.SameLine()
				if im.Button(fmt.ctprintf("%s Hot-Swap Cartridge (F7)", icons.ICON_MD_PLAY_ARROW)) {
					engine.hot_cartridge_trigger_async_build(true)
				}
			case 5, 6:
				if im.Button(fmt.ctprintf("%s Toggle Overwatch Recorder", icons.ICON_MD_RECORD)) {
					if overwatch_recorder_is_active() {
						overwatch_recorder_stop("Stopped from Haati Manual")
					} else {
						overwatch_recorder_start(false)
					}
				}
				im.SameLine()
				if im.Button(fmt.ctprintf("%s Open Blueprint Studio", icons.ICON_MD_ACCOUNT_TREE)) {
					wnd.open("mh_visual_script")
				}
			}
		}
		im.EndChild()

		im.EndTable()
	}
}
