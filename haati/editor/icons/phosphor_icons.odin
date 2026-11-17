package icons

// Phosphor Regular icon codepoints (`haati/external/fonts/phosphor/Phosphor.ttf`, MIT license).
//
// Because Phosphor's Private Use Area codepoints overlap Material Symbols (`U+E000..U+F8FF`),
// wrap Phosphor glyph text/buttons inside `widgets.push_phosphor_font()` / `widgets.pop_phosphor_font()`
// or use `widgets.phosphor_icon_button()` / `widgets.phosphor_ghost_icon_button()`!

ICON_PH_MIN :: 0xe000
ICON_PH_MAX :: 0xf8ff

// 3D / CAD / CSG Geometry
ICON_PH_CUBE         :: "\ue1da" // cube
ICON_PH_CUBE_FOCUS   :: "\ued0a" // cube-focus
ICON_PH_BOUNDING_BOX :: "\ue6ce" // bounding-box
ICON_PH_VECTOR_THREE :: "\uee62" // vector-three
ICON_PH_VECTOR_TWO   :: "\uee64" // vector-two
ICON_PH_SPHERE       :: "\uee66" // sphere
ICON_PH_CYLINDER     :: "\ue8fc" // cylinder
ICON_PH_POLYGON      :: "\ue6d0" // polygon
ICON_PH_UNITE        :: "\ue87e" // unite (CSG Union)
ICON_PH_SUBTRACT     :: "\uebd6" // subtract (CSG Difference)
ICON_PH_INTERSECT    :: "\ue2d2" // intersect (CSG Intersect)
ICON_PH_EXCLUDE      :: "\ue882" // exclude (CSG XOR)
ICON_PH_COMPASS_TOOL :: "\uea0e" // compass-tool

// Scripting / Blueprints / IDE
ICON_PH_BLUEPRINT       :: "\ueda0" // blueprint (.bodin / Blueprint Studio)
ICON_PH_BRACKETS_CURLY  :: "\ue860" // brackets-curly (struct / block)
ICON_PH_CODE            :: "\ue1bc" // code (.odin source)
ICON_PH_FILE_CODE       :: "\ue914" // file-code
ICON_PH_TERMINAL_WINDOW :: "\ueae8" // terminal-window
ICON_PH_TREE_STRUCTURE  :: "\ue67c" // tree-structure (hierarchy / AST)
ICON_PH_GIT_BRANCH      :: "\ue278" // git-branch
ICON_PH_BUG             :: "\ue5f4" // bug (diagnostics / debugger)
ICON_PH_DATABASE        :: "\ue1de" // database
ICON_PH_PACKAGE         :: "\ue390" // package
ICON_PH_STACK           :: "\ue466" // stack (layers / scenes)

// Components / Rig / AI / VFX / Audio / Gameplay
ICON_PH_BONE               :: "\ue7f2" // bone (skeleton / ControlRig)
ICON_PH_PERSON_SIMPLE_RUN  :: "\ue730" // person-simple-run (character / humanoid)
ICON_PH_BRAIN              :: "\ue74e" // brain (AI / state machine)
ICON_PH_ROBOT              :: "\ue762" // robot (NavMeshAgent / bot)
ICON_PH_PATH               :: "\ue39c" // path (NavMesh / spline path)
ICON_PH_LIGHTNING          :: "\ue2de" // lightning (event / trigger / hot-reload)
ICON_PH_FLAME              :: "\ue624" // flame (VFX / fire / emitter)
ICON_PH_DROP               :: "\ue210" // drop (fluid / particle)
ICON_PH_WIND               :: "\ue5d2" // wind (airflow / force zone)
ICON_PH_SUN                :: "\ue472" // sun (DirectionalLight / sky)
ICON_PH_LIGHTBULB          :: "\ue2dc" // lightbulb (PointLight)
ICON_PH_FLASHLIGHT         :: "\ue246" // flashlight (SpotLight)
ICON_PH_CAMERA             :: "\ue10e" // camera
ICON_PH_VIDEO_CAMERA       :: "\ue4da" // video-camera
ICON_PH_SPEAKER_HIGH       :: "\ue44a" // speaker-high (AudioSource)
ICON_PH_WAVEFORM           :: "\ue802" // waveform (audio waveform)
ICON_PH_CROSSHAIR          :: "\ue1d6" // crosshair (aim / pick target)
ICON_PH_SWORD              :: "\ue5ba" // sword (combat / melee)
ICON_PH_SHIELD             :: "\ue40a" // shield (armor / collision guard)
ICON_PH_SHIELD_WARNING     :: "\ue412" // shield-warning (unsafe / sandbox guard)
ICON_PH_GAME_CONTROLLER    :: "\ue26e" // game-controller (input / play)
ICON_PH_WRENCH             :: "\ue5d4" // wrench (tools)
ICON_PH_HAMMER             :: "\ue80e" // hammer (build)
ICON_PH_GEAR               :: "\ue270" // gear (settings)
ICON_PH_SLIDERS_HORIZONTAL :: "\ue434" // sliders-horizontal (inspector / params)
ICON_PH_FADERS             :: "\ue228" // faders (audio / post-fx mixer)
