package theme

// =============================================================================
// UNIFIED STUDIO & BLUEPRINT SEMANTIC PALETTE + ICON SLOTS (`studio_palette.odin`)
// =============================================================================
// Centralizes ALL domain-specific visual tokens for:
//   - Odin/Blueprint variable & pin data types (colors + icon slots + picker list)
//   - Container & pass-mode semantics (`Scalar_Copy`, `^Ref`, `[N]`, `Bounded`, `Delegate`, `Exec`)
//   - Blueprint node namespaces (badges, icons, accent hues)
//   - Odin Micro-Studio syntax highlighting, completion kinds, outline symbols & diagnostics
//
// Zero hardcoded colors need to live in editor views: every table entry automatically
// adapts to dark and daylight Studio themes via `adapt_badge_color` and `palette()`.

import "core:math"
import "haati:editor/icons"
import hot "haati:engine/hot_api"
import im "haati:external/odin-imgui"

// =============================================================================
// 1. Blueprint Pin & Variable Type Visual Descriptors (`Hot_Pin_Type`)
// =============================================================================

Studio_Pin_Visual :: struct {
	odin_label: cstring, // Canonical display label ("bool", "u8", "f32", "Vec3", "Struct", ...)
	dark_color: [4]f32,  // Base hue calibrated for dark surfaces (auto-darkened on light themes)
	type_icon:  cstring, // Icon slot (Material glyph today; swap cleanly for custom icons later)
	in_picker:  bool,    // Exposed in variable/field/param type dropdowns
}

@(rodata)
STUDIO_PIN_TABLE := [hot.Hot_Pin_Type]Studio_Pin_Visual {
	.Exec       = {"Exec",     {0.95, 0.96, 0.98, 1.0}, icons.ICON_MD_PLAY_ARROW,    false},
	.Bool       = {"bool",     {0.92, 0.34, 0.34, 1.0}, icons.ICON_MD_CHECK,         true},
	.Int        = {"i32",      {0.28, 0.86, 0.76, 1.0}, icons.ICON_MD_PENTAGON,      true},
	.Float      = {"f32",      {0.38, 0.88, 0.48, 1.0}, icons.ICON_MD_SHOW_CHART,    true},
	.Vec3       = {"Vec3",     {0.98, 0.78, 0.26, 1.0}, icons.ICON_MD_OPEN_WITH,     true},
	.Quat       = {"Quat",     {0.94, 0.54, 0.86, 1.0}, icons.ICON_MD_3D_ROTATION,   true},
	.Entity     = {"Entity",   {0.48, 0.72, 1.00, 1.0}, icons.ICON_MD_DEPLOYED_CODE, true},
	.Delegate   = {"Delegate", {0.22, 0.94, 0.92, 1.0}, icons.ICON_MD_DIAMOND,       true},
	.Vec2       = {"Vec2",     {0.96, 0.64, 0.28, 1.0}, icons.ICON_MD_STRAIGHTEN,    true},
	.Vec4       = {"Vec4",     {0.94, 0.54, 0.86, 1.0}, icons.ICON_MD_VIEW_IN_AR,    true},
	.Int64      = {"i64",      {0.22, 0.68, 0.94, 1.0}, icons.ICON_MD_PENTAGON,      true},
	.String     = {"string",   {0.96, 0.46, 0.66, 1.0}, icons.ICON_MD_DESCRIPTION,   true},
	.Asset      = {"Asset",    {0.96, 0.46, 0.66, 1.0}, icons.ICON_MD_FOLDER,        true},
	.U8         = {"u8",       {0.26, 0.74, 0.86, 1.0}, icons.ICON_MD_HEXAGON,       true},
	.I8         = {"i8",       {0.26, 0.74, 0.86, 1.0}, icons.ICON_MD_HEXAGON,       true},
	.U16        = {"u16",      {0.30, 0.80, 0.80, 1.0}, icons.ICON_MD_HEXAGON,       true},
	.I16        = {"i16",      {0.30, 0.80, 0.80, 1.0}, icons.ICON_MD_HEXAGON,       true},
	.U32        = {"u32",      {0.28, 0.86, 0.76, 1.0}, icons.ICON_MD_PENTAGON,      true},
	.U64        = {"u64",      {0.22, 0.68, 0.94, 1.0}, icons.ICON_MD_PENTAGON,      true},
	.F64        = {"f64",      {0.22, 0.80, 0.42, 1.0}, icons.ICON_MD_SHOW_CHART,    true},
	.Enum_U8    = {"Enum(u8)", {0.96, 0.82, 0.28, 1.0}, icons.ICON_MD_LIST_ALT,      true},
	.BitSet_U8  = {"BitSet",   {0.98, 0.64, 0.24, 1.0}, icons.ICON_MD_TUNE,          true},
	.Struct_Val = {"Struct",   {0.32, 0.64, 0.98, 1.0}, icons.ICON_MD_DATA_OBJECT,   true},
	.Raw_Ptr    = {"rawptr",   {1.00, 0.40, 0.36, 1.0}, icons.ICON_MD_BOLT,          true},
}

// Ordered list displayed in Blueprint type pickers (`Variables`, `Struct Fields`, `Proc Params`).
@(rodata)
STUDIO_PICKER_TYPES := [23]hot.Hot_Pin_Type {
	.Bool,
	.U8,
	.I8,
	.U16,
	.I16,
	.Int,
	.U32,
	.Int64,
	.U64,
	.Float,
	.F64,
	.Vec2,
	.Vec3,
	.Vec4,
	.Quat,
	.String,
	.Asset,
	.Entity,
	.Delegate,
	.Enum_U8,
	.BitSet_U8,
	.Struct_Val,
	.Raw_Ptr,
}

// =============================================================================
// 2. Container & Pass-Mode Visual Descriptors (Value / ^Ref / Array / Bounded)
// =============================================================================

Studio_Container_Kind :: enum u8 {
	Scalar_Copy   = 0,
	By_Ref_Ptr    = 1,
	Fixed_Array   = 2,
	Bounded_Array = 3,
	Delegate_Pin  = 4,
	Exec_Flow     = 5,
	Slice_View    = 6,
	Dynamic_Array = 7,
}

Studio_Container_Visual :: struct {
	icon:        cstring,
	short_badge: cstring,
	wire_badge:  cstring,
	dark_tint:   [4]f32,
}

@(rodata)
STUDIO_CONTAINER_TABLE := [Studio_Container_Kind]Studio_Container_Visual {
	.Scalar_Copy   = {icons.ICON_MD_CIRCLE,     "Copy",     icons.ICON_MD_CIRCLE + " Copy",         {0.42, 0.88, 0.54, 1.0}},
	.By_Ref_Ptr    = {icons.ICON_MD_DIAMOND,    "^Ref",     icons.ICON_MD_DIAMOND + " ^Ref",        {1.00, 0.46, 0.66, 1.0}},
	.Fixed_Array   = {icons.ICON_MD_GRID_4X4,   "[N]",      icons.ICON_MD_GRID_4X4 + " [N]",        {0.38, 0.82, 0.98, 1.0}},
	.Bounded_Array = {icons.ICON_MD_LAYERS,     "Bounded",  icons.ICON_MD_LAYERS + " Bounded",      {0.52, 0.76, 1.00, 1.0}},
	.Delegate_Pin  = {icons.ICON_MD_DIAMOND,    "Delegate", icons.ICON_MD_DIAMOND + " Delegate",    {0.22, 0.94, 0.92, 1.0}},
	.Exec_Flow     = {icons.ICON_MD_PLAY_ARROW, "Exec",     nil,                                    {0.95, 0.96, 0.98, 1.0}},
	.Slice_View    = {icons.ICON_MD_GRID_4X4,   "[]",       icons.ICON_MD_GRID_4X4 + " [] Slice",   {0.34, 0.90, 0.92, 1.0}},
	.Dynamic_Array = {icons.ICON_MD_LAYERS,     "[+]",      icons.ICON_MD_LAYERS + " [dynamic]",    {0.46, 0.84, 1.00, 1.0}},
}

studio_resolve_container :: proc(
	pt:         hot.Hot_Pin_Type,
	is_array:   bool = false,
	is_bounded: bool = false,
	by_ref:     bool = false,
) -> Studio_Container_Kind {
	if pt == .Exec     do return .Exec_Flow
	if pt == .Delegate do return .Delegate_Pin
	if is_array {
		return is_bounded ? .Bounded_Array : .Fixed_Array
	}
	if by_ref do return .By_Ref_Ptr
	return .Scalar_Copy
}

studio_pin_color :: proc(pt: hot.Hot_Pin_Type, by_ref: bool = false) -> im.Vec4 {
	if pt == .Exec {
		p := palette()
		return p.is_light ? p.text_primary : adapt_badge_color(STUDIO_PIN_TABLE[.Exec].dark_color)
	}
	if pt == .Delegate {
		return adapt_badge_color(STUDIO_PIN_TABLE[.Delegate].dark_color)
	}
	if by_ref {
		return adapt_badge_color(STUDIO_CONTAINER_TABLE[.By_Ref_Ptr].dark_tint)
	}
	return adapt_badge_color(STUDIO_PIN_TABLE[pt].dark_color)
}

studio_var_icon_and_color :: proc(
	pt:         hot.Hot_Pin_Type,
	is_array:   bool = false,
	is_bounded: bool = false,
	by_ref:     bool = false,
) -> (container_icon: cstring, type_icon: cstring, col: im.Vec4) {
	ck := studio_resolve_container(pt, is_array, is_bounded, by_ref)
	return STUDIO_CONTAINER_TABLE[ck].icon, STUDIO_PIN_TABLE[pt].type_icon, studio_pin_color(pt, by_ref)
}

// =============================================================================
// 3. Unreal-Inspired Node Namespaces (Header Badge + Icon Slot + Accent Hue)
// =============================================================================

Studio_Namespace :: enum u8 {
	Event     = 0,
	Flow      = 1,
	Input     = 2,
	Math      = 3,
	Transform = 4,
	Anim      = 5,
	VFX       = 6,
	Audio     = 7,
	AI        = 8,
	Delegate  = 9,
	Odin      = 10,
	Variable  = 11,
}

Studio_Namespace_Visual :: struct {
	badge:      cstring,
	icon:       cstring,
	dark_color: [4]f32,
}

@(rodata)
STUDIO_NAMESPACE_TABLE := [Studio_Namespace]Studio_Namespace_Visual {
	.Event     = {"EVENT",     icons.ICON_MD_BOLT,         {0.84, 0.28, 0.30, 1.0}},
	.Flow      = {"FLOW",      icons.ICON_MD_CALL_SPLIT,   {0.58, 0.64, 0.78, 1.0}},
	.Input     = {"INPUT",     icons.ICON_MD_GAMEPAD,      {0.94, 0.56, 0.18, 1.0}},
	.Math      = {"MATH",      icons.ICON_MD_FUNCTIONS,    {0.26, 0.78, 0.48, 1.0}},
	.Transform = {"TRANSFORM", icons.ICON_MD_OPEN_WITH,    {0.88, 0.62, 0.20, 1.0}},
	.Anim      = {"ANIM",      icons.ICON_MD_ANIMATION,    {0.28, 0.72, 0.58, 1.0}},
	.VFX       = {"VFX",       icons.ICON_MD_AUTO_AWESOME, {0.94, 0.48, 0.24, 1.0}},
	.Audio     = {"AUDIO",     icons.ICON_MD_MUSIC_NOTE,   {0.28, 0.78, 0.88, 1.0}},
	.AI        = {"AI",        icons.ICON_MD_HUB,          {0.34, 0.84, 0.56, 1.0}},
	.Delegate  = {"DELEGATE",  icons.ICON_MD_DIAMOND,      {0.18, 0.82, 0.84, 1.0}},
	.Odin      = {"ODIN",      icons.ICON_MD_CODE,         {0.66, 0.38, 0.94, 1.0}},
	.Variable  = {"VARIABLE",  icons.ICON_MD_DATA_OBJECT,  {0.22, 0.66, 0.88, 1.0}},
}

studio_namespace_style :: proc(ns: Studio_Namespace) -> (badge: cstring, icon: cstring, accent: im.Vec4) {
	v := STUDIO_NAMESPACE_TABLE[ns]
	return v.badge, v.icon, adapt_badge_color(v.dark_color)
}

// =============================================================================
// 4. Odin Micro-Studio Syntax Roles & Symbol Visuals
// =============================================================================

Studio_Syntax_Role :: enum u8 {
	Plain     = 0,
	Keyword   = 1,
	Type      = 2,
	Attribute = 3,
	String    = 4,
	Number    = 5,
	Comment   = 6,
	Call      = 7,
	Operator  = 8,
	Pin_Ref   = 9,
}

Studio_Syntax_Visual :: struct {
	dark_color:  [4]f32,
	light_color: [4]f32,
}

@(rodata)
STUDIO_SYNTAX_TABLE := [Studio_Syntax_Role]Studio_Syntax_Visual {
	.Plain     = {{0.90, 0.92, 0.96, 1.0}, {0.10, 0.12, 0.16, 1.0}},
	.Keyword   = {{0.78, 0.52, 0.98, 1.0}, {0.62, 0.14, 0.72, 1.0}},
	.Type      = {{0.36, 0.84, 0.94, 1.0}, {0.05, 0.48, 0.58, 1.0}},
	.Attribute = {{0.98, 0.76, 0.32, 1.0}, {0.72, 0.42, 0.04, 1.0}},
	.String    = {{0.58, 0.88, 0.54, 1.0}, {0.14, 0.54, 0.22, 1.0}},
	.Number    = {{0.96, 0.64, 0.38, 1.0}, {0.76, 0.34, 0.08, 1.0}},
	.Comment   = {{0.55, 0.60, 0.68, 1.0}, {0.42, 0.46, 0.54, 1.0}},
	.Call      = {{0.46, 0.74, 1.00, 1.0}, {0.12, 0.38, 0.78, 1.0}},
	.Operator  = {{0.72, 0.76, 0.84, 1.0}, {0.28, 0.32, 0.40, 1.0}},
	.Pin_Ref   = {{1.00, 0.48, 0.62, 1.0}, {0.82, 0.22, 0.38, 1.0}},
}

studio_syntax_color :: proc(role: Studio_Syntax_Role, p: ^Theme_Palette) -> im.Vec4 {
	if p != nil {
		#partial switch role {
		case .Plain:    return p.text_primary
		case .Comment:  return p.text_muted
		case .Operator: return p.text_secondary
		}
	}
	v := STUDIO_SYNTAX_TABLE[role]
	c := p != nil && p.is_light ? v.light_color : v.dark_color
	return im.Vec4{c[0], c[1], c[2], c[3]}
}

Studio_Symbol_Kind :: enum u8 {
	Pin_Ref   = 0,
	Pin_Copy  = 1,
	Pin_Out   = 2,
	Local_Var = 3,
	Field     = 4,
	Hot_API   = 5,
	Procedure = 6,
	Hot_Proc  = 7,
	Struct    = 8,
	Enum      = 9,
	Type_Sym  = 10,
	Keyword   = 11,
}

Studio_Symbol_Visual :: struct {
	icon:       cstring,
	badge:      cstring,
	dark_color: [4]f32,
}

@(rodata)
STUDIO_SYMBOL_TABLE := [Studio_Symbol_Kind]Studio_Symbol_Visual {
	.Pin_Ref   = {icons.ICON_MD_DIAMOND,     "^Ref",   {1.00, 0.50, 0.66, 1.0}},
	.Pin_Copy  = {icons.ICON_MD_CIRCLE,      "Copy",   {0.48, 0.84, 1.00, 1.0}},
	.Pin_Out   = {icons.ICON_MD_ARROW_RIGHT, "-> Out", {0.46, 0.94, 0.62, 1.0}},
	.Local_Var = {icons.ICON_MD_CODE,        "local",  {0.92, 0.82, 0.48, 1.0}},
	.Field     = {icons.ICON_MD_TUNE,        "field",  {0.42, 0.88, 0.94, 1.0}},
	.Hot_API   = {icons.ICON_MD_BOLT,        "hot",    {0.40, 0.96, 0.68, 1.0}},
	.Procedure = {icons.ICON_MD_FUNCTIONS,   "proc",   {0.52, 0.78, 1.00, 1.0}},
	.Hot_Proc  = {icons.ICON_MD_BOLT,        "hot",    {0.40, 0.96, 0.68, 1.0}},
	.Struct    = {icons.ICON_MD_DATA_OBJECT, "struct", {0.42, 0.88, 0.94, 1.0}},
	.Enum      = {icons.ICON_MD_LIST_ALT,    "enum",   {0.94, 0.78, 0.42, 1.0}},
	.Type_Sym  = {icons.ICON_MD_CATEGORY,    "type",   {0.36, 0.84, 0.94, 1.0}},
	.Keyword   = {icons.ICON_MD_LOCK,        "kw",     {0.80, 0.56, 0.98, 1.0}},
}

studio_symbol_visual :: proc(k: Studio_Symbol_Kind) -> (icon: cstring, badge: cstring, col: im.Vec4) {
	v := STUDIO_SYMBOL_TABLE[k]
	return v.icon, v.badge, adapt_badge_color(v.dark_color)
}

// =============================================================================
// 5. Semantic Studio Surface & Overlay Tokens (Derived From Active Palette)
// =============================================================================

Studio_Tokens :: struct {
	pin_socket_bg:          im.Vec4,
	domain_blueprint:       im.Vec4,
	domain_material:        im.Vec4,
	domain_odin:            im.Vec4,
	pill_active_text:       im.Vec4,
	subgraph_bp_tint:       im.Vec4,
	subgraph_odin_tint:     im.Vec4,
	scancode_badge_fg:      im.Vec4,
	node_meta_fg:           im.Vec4,
	node_code_preview_fg:   im.Vec4,
	code_child_bg:          im.Vec4,
	gutter_bg:              im.Vec4,
	active_line_tint:       im.Vec4,
	diag_err_row:           im.Vec4,
	diag_warn_row:          im.Vec4,
	diag_err_fg:            im.Vec4,
	diag_warn_fg:           im.Vec4,
	sig_call_fg:            im.Vec4,
	sig_active_param_fg:    im.Vec4,
	sig_return_fg:          im.Vec4,
	compile_btn_bg:         im.Vec4,
	compile_btn_fg:         im.Vec4,
}

studio_tokens :: proc() -> Studio_Tokens {
	p := palette()
	black := im.Vec4{0.0, 0.0, 0.0, 1.0}
	white := im.Vec4{1.0, 1.0, 1.0, 1.0}

	return Studio_Tokens{
		pin_socket_bg        = p.is_light ? p.bg_recessed : im.Vec4{0.07, 0.08, 0.10, 0.96},
		domain_blueprint     = adapt_badge_color({0.24, 0.78, 0.96, 1.0}),
		domain_material      = adapt_badge_color({0.92, 0.46, 0.84, 1.0}),
		domain_odin          = adapt_badge_color(STUDIO_NAMESPACE_TABLE[.Odin].dark_color),
		pill_active_text     = white,
		subgraph_bp_tint     = adapt_badge_color({0.16, 0.78, 0.82, 1.0}),
		subgraph_odin_tint   = adapt_badge_color({0.66, 0.42, 0.96, 1.0}),
		scancode_badge_fg    = adapt_badge_color({0.96, 0.56, 0.72, 1.0}),
		node_meta_fg         = adapt_badge_color({0.58, 0.84, 0.98, 1.0}),
		node_code_preview_fg = p.is_light ? p.text_secondary : im.Vec4{0.78, 0.86, 0.98, 1.0},
		code_child_bg        = p.is_light ? lerp_col(p.bg_canvas, white, 0.50) : lerp_col(p.bg_canvas, black, 0.28),
		gutter_bg            = p.is_light ? lerp_col(p.bg_canvas, black, 0.04) : lerp_col(p.bg_canvas, white, 0.03),
		active_line_tint     = p.is_light ? with_alpha(p.accent, 0.07) : with_alpha(white, 0.04),
		diag_err_row         = with_alpha(p.status_error, 0.16),
		diag_warn_row        = with_alpha(p.status_warning, 0.14),
		diag_err_fg          = p.status_error,
		diag_warn_fg         = p.status_warning,
		sig_call_fg          = studio_syntax_color(.Call, &p),
		sig_active_param_fg  = p.status_warning,
		sig_return_fg        = p.status_success,
		compile_btn_bg       = with_alpha(p.status_success, p.is_light ? 0.22 : 0.42),
		compile_btn_fg       = p.is_light ? p.text_primary : white,
	}
}

studio_exec_pulse_color :: proc(t_sec: f32) -> im.Vec4 {
	pulse := 0.5 + 0.5 * math.sin(t_sec * 8.0)
	return adapt_badge_color({0.28 + 0.72 * pulse, 0.92, 1.0 - 0.55 * pulse, 1.0})
}
