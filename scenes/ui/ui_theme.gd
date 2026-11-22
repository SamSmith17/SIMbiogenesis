class_name UITheme
extends RefCounted

## Single source of truth for UI chrome: palette, status colors, StyleBox
## factories, font scale, spacing, and CanvasLayer z-order.
##
## All new UI styling goes through this class. Existing UIs migrate by
## redirecting their local palette consts (e.g. `const C_BG := UITheme.C_BG`)
## so call sites stay unchanged. Semantic color registries (graph PORT_COLORS,
## NODE_BORDER_COLORS, provenance band colors) are NOT chrome and stay local
## to their owners.

# ---------------------------------------------------------------------------
# Palette (canonical values from timeline_ui.gd, which mirrors the webapp
# css/variables.css set — e.g. C_PRIMARY is #22d3ee).
# Alpha variants: build in the consumer via Color(UITheme.C_BG, 0.97).
# ---------------------------------------------------------------------------
const C_BG           := Color(0.039, 0.055, 0.098, 1.0)   # --space-900 #0a0e1a
const C_PANEL        := Color(0.082, 0.114, 0.208, 1.0)   # --space-700 panel / sidebar
const C_PANEL_RAISED := Color(0.110, 0.145, 0.255, 1.0)   # --space-600 raised card
const C_BORDER       := Color(0.227, 0.290, 0.420, 1.0)   # --space-400
const C_PRIMARY      := Color(0.133, 0.827, 0.933, 1.0)   # --clr-primary cyan #22d3ee
const C_AMBER        := Color(0.961, 0.620, 0.043, 1.0)   # playhead / accent amber
const C_GOLD         := Color(1.000, 0.816, 0.310, 1.0)
const C_LAVENDER     := Color(0.686, 0.600, 1.000, 1.0)
const C_GREEN        := Color(0.149, 0.902, 0.467, 1.0)
const C_TEXT         := Color(0.886, 0.910, 0.941, 1.0)   # --text-primary
const C_TEXT_S       := Color(0.580, 0.639, 0.722, 1.0)   # --text-secondary
const C_TEXT_M       := Color(0.392, 0.447, 0.545, 1.0)   # --text-muted

# ---------------------------------------------------------------------------
# Status colors — ONE canonical value per meaning. Every UI that shows an
# ok/warn/error/info state uses these (battery low, destroyed controller,
# health critical, connection state, toasts, …).
# ---------------------------------------------------------------------------
const C_OK    := C_GREEN
const C_WARN  := C_AMBER
const C_ERROR := Color(0.937, 0.267, 0.267, 1.0)          # #ef4444
const C_INFO  := C_PRIMARY

# ---------------------------------------------------------------------------
# CanvasLayer z-order. Existing layers map onto these bands; new UIs pick the
# band, never an ad-hoc number.
#   crosshair/world hints (5) < HUD bars (10) < panels/docks (30)
#   < modals incl. save/load + interaction prompts (50) < toasts (90)
#   < load overlay / game over / calibration (100)
# ---------------------------------------------------------------------------
const LAYER_WORLD_HINT   := 5
const LAYER_HUD          := 10
const LAYER_PANEL        := 30
const LAYER_MODAL        := 50
const LAYER_TOAST        := 90
const LAYER_LOAD_OVERLAY := 100

# ---------------------------------------------------------------------------
# Typography scale. XS is 11 — the size 125 call sites already used as their
# "small" (the old 10 was below what reads at 1080p in Inter).
# ---------------------------------------------------------------------------
const FONT_XS := 11
const FONT_SM := 12
const FONT_MD := 14
const FONT_LG := 16
const FONT_XL := 20

# Spacing scale for separations / margins.
const SPACE_XS := 4
const SPACE_SM := 8
const SPACE_MD := 12
const SPACE_LG := 16

const CORNER_RADIUS := 6


## The project Theme (Inter, every stock control styled from this palette) —
## see UiThemeBuilder. Installed on the root window at boot by `install`.
static func build_theme() -> Theme:
	return UiThemeBuilder.build()


## Theme + UI scale on the root window (called once by the Services autoload).
static func install(root: Window) -> void:
	UiThemeBuilder.install(root)


## Theme + portrait-aware canvas scale on a secondary OS `Window`.
static func install_window(win: Window, portrait_override: int = 0, ui_scale_override: float = 0.0) -> void:
	UiThemeBuilder.install_window(win, portrait_override, ui_scale_override)


## Inter at a weight ("regular" | "medium" | "semibold"); tabular figures with
## `numeric` for readouts that change while you watch them.
static func font(weight: String = "regular", numeric: bool = false) -> Font:
	return UiThemeBuilder.numeric_font(weight) if numeric else UiThemeBuilder.font(weight)


## Standard panel: dark bg, 1px border, rounded corners, content margins.
static func panel_style(alpha: float = 1.0, bg: Color = C_PANEL,
		border: Color = C_BORDER) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg, bg.a * alpha)
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(CORNER_RADIUS)
	sb.set_content_margin_all(SPACE_MD)
	return sb


## Elevated modal panel: crisp border, slightly larger corner radius, and soft drop shadow.
static func modal_panel_style(alpha: float = 0.99, bg: Color = C_PANEL,
		border: Color = C_BORDER) -> StyleBoxFlat:
	var sb := panel_style(alpha, bg, Color(border.lightened(0.08), 0.92))
	sb.set_corner_radius_all(CORNER_RADIUS + 2)
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.48)
	sb.shadow_size = 14
	sb.shadow_offset = Vector2(0.0, 4.0)
	return sb


## Floating tool dock panel: slightly tighter shadow and crisp border over the 3D scene.
static func dock_panel_style(alpha: float = 0.96, bg: Color = C_PANEL,
		border: Color = C_BORDER) -> StyleBoxFlat:
	var sb := panel_style(alpha, bg, Color(border.lightened(0.06), 0.90))
	sb.set_corner_radius_all(CORNER_RADIUS + 1)
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


## Raised card inside a panel (lighter bg, subtle border, tighter margins).
static func card_style() -> StyleBoxFlat:
	var sb := panel_style(1.0, C_PANEL_RAISED, Color(C_BORDER.lightened(0.06), 0.78))
	sb.set_content_margin_all(SPACE_SM)
	return sb


## Button stylebox. `state` is "normal", "hover", or "pressed".
static func button_style(state: String = "normal") -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	match state:
		"hover":
			sb.bg_color = C_PANEL_RAISED.lightened(0.05)
			sb.border_color = C_PRIMARY
		"pressed":
			sb.bg_color = Color(C_PRIMARY, 0.25)
			sb.border_color = C_PRIMARY
		"disabled":
			sb.bg_color = Color(C_PANEL, 0.5)
			sb.border_color = Color(C_BORDER, 0.45)
		_:
			sb.bg_color = C_PANEL.lightened(0.03)
			sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(CORNER_RADIUS)
	sb.set_content_margin_all(SPACE_SM)
	sb.content_margin_left = SPACE_MD
	sb.content_margin_right = SPACE_MD
	return sb


## Filled accent button stylebox for primary calls-to-action.
static func primary_button_style(state: String = "normal") -> StyleBoxFlat:
	var sb := button_style("normal")
	match state:
		"hover":
			sb.bg_color = Color(C_PRIMARY, 0.34)
			sb.border_color = C_PRIMARY.lightened(0.15)
		"pressed":
			sb.bg_color = Color(C_PRIMARY, 0.44)
			sb.border_color = C_PRIMARY.lightened(0.20)
		"disabled":
			sb.bg_color = Color(C_PANEL, 0.5)
			sb.border_color = Color(C_BORDER, 0.45)
		_:
			sb.bg_color = Color(C_PRIMARY, 0.22)
			sb.border_color = Color(C_PRIMARY, 0.90)
	return sb


## Tinted error button stylebox for destructive actions.
static func destructive_button_style(state: String = "normal") -> StyleBoxFlat:
	var sb := button_style("normal")
	match state:
		"hover":
			sb.bg_color = Color(C_ERROR, 0.26)
			sb.border_color = C_ERROR.lightened(0.12)
		"pressed":
			sb.bg_color = Color(C_ERROR, 0.36)
			sb.border_color = C_ERROR.lightened(0.18)
		"disabled":
			sb.bg_color = Color(C_PANEL, 0.5)
			sb.border_color = Color(C_BORDER, 0.45)
		_:
			sb.bg_color = Color(C_ERROR, 0.14)
			sb.border_color = Color(C_ERROR, 0.75)
	return sb


## Apply normal/hover/pressed styleboxes to a Button in one call.
static func style_button(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", button_style("normal"))
	btn.add_theme_stylebox_override("hover", button_style("hover"))
	btn.add_theme_stylebox_override("pressed", button_style("pressed"))
	btn.add_theme_stylebox_override("hover_pressed", button_style("pressed"))
	btn.add_theme_stylebox_override("disabled", button_style("disabled"))


## Style a primary CTA button: filled cyan tint, crisp cyan border, semibold bright text.
static func style_primary_button(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", primary_button_style("normal"))
	btn.add_theme_stylebox_override("hover", primary_button_style("hover"))
	btn.add_theme_stylebox_override("pressed", primary_button_style("pressed"))
	btn.add_theme_stylebox_override("hover_pressed", primary_button_style("hover"))
	btn.add_theme_stylebox_override("disabled", primary_button_style("disabled"))
	var semi := font("semibold")
	if semi != null:
		btn.add_theme_font_override("font", semi)
	var ink := Color(0.93, 0.99, 1.0)
	btn.add_theme_color_override("font_color", ink)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_focus_color", ink)
	btn.add_theme_color_override("font_disabled_color", C_TEXT_M)
	btn.add_theme_color_override("icon_normal_color", C_PRIMARY.lightened(0.25))
	btn.add_theme_color_override("icon_hover_color", Color.WHITE)


## Style a destructive action button: tinted error surface and high-contrast rose text.
static func style_destructive_button(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", destructive_button_style("normal"))
	btn.add_theme_stylebox_override("hover", destructive_button_style("hover"))
	btn.add_theme_stylebox_override("pressed", destructive_button_style("pressed"))
	btn.add_theme_stylebox_override("hover_pressed", destructive_button_style("hover"))
	btn.add_theme_stylebox_override("disabled", destructive_button_style("disabled"))
	var ink := Color(1.0, 0.58, 0.58)
	btn.add_theme_color_override("font_color", ink)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.85, 0.85))
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_focus_color", ink)
	btn.add_theme_color_override("font_disabled_color", C_TEXT_M)


## Subtle 110 ms fade-in for modals, flyouts and docks during interactive play.
## Automatically skipped in headless runs and harness sandboxes so automated
## screenshot and UiAudit checks see final alpha immediately on frame 1.
static func animate_open(panel: CanvasItem, backdrop: CanvasItem = null) -> void:
	if panel == null or not panel.is_inside_tree():
		return
	if DisplayServer.get_name() == "headless" or FileAccess.file_exists("user://.harness_sandbox"):
		panel.modulate.a = 1.0
		if backdrop != null:
			backdrop.modulate.a = 1.0
		return
	var tree := panel.get_tree()
	if tree == null:
		return
	panel.modulate.a = 0.0
	var tw := panel.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "modulate:a", 1.0, 0.11)
	if backdrop != null:
		backdrop.modulate.a = 0.0
		tw.parallel().tween_property(backdrop, "modulate:a", 1.0, 0.11)


## Four-state toggle face for tool / mode buttons (tool strips, shape pickers,
## species families). The OFF+hover face is the whole point: a row of identical
## toggles otherwise gives no feedback about what is clickable — every one of
## the veg dock's 15 buttons used to render hover identically to normal. Lifted
## out of that dock so the unified edit toolbar and future strips share it.
static func toggle_style(on: bool, hover: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(CORNER_RADIUS)
	sb.set_border_width_all(1)
	if on:
		sb.bg_color = Color(C_PRIMARY, 0.30 if hover else 0.22)
		sb.border_color = C_PRIMARY
	elif hover:
		sb.bg_color = C_PANEL_RAISED
		sb.border_color = Color(C_PRIMARY, 0.75)
	else:
		sb.bg_color = C_PANEL
		sb.border_color = C_BORDER
	return sb


## Apply all four toggle faces plus the on/off font colour in one call.
## `hover_pressed` matters: without it Godot falls back to `hover`, so an
## ACTIVE button loses its highlight the moment the pointer touches it.
static func style_toggle(btn: Button, on: bool, font_size: int = FONT_SM) -> void:
	btn.add_theme_stylebox_override("normal", toggle_style(on, false))
	btn.add_theme_stylebox_override("hover", toggle_style(on, true))
	btn.add_theme_stylebox_override("pressed", toggle_style(true, false))
	btn.add_theme_stylebox_override("hover_pressed", toggle_style(true, true))
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", C_TEXT if on else C_TEXT_S)
	btn.add_theme_color_override("font_disabled_color", C_TEXT_M)


## Style a ProgressBar into the dark palette.
##
## Godot's stock ProgressBar is light grey, which on these panels is the one
## piece of un-themed chrome on screen — and progress bars are exactly what a
## work UI is made of. `fill` tints the filled portion so a bar can carry its
## own meaning (amber = in progress, green = done) without a second label.
static func style_progress(bar: ProgressBar, fill: Color = C_PRIMARY) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(C_BG, 0.75)
	bg.border_color = Color(C_BORDER, 0.8)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill
	fg.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)


## Capture a rebuilt list's scroll position; call the returned Callable after
## the rebuild to restore it (deferred — the new children need a layout pass
## before the old offset is reachable). Signature-gated panels rebuild whole
## row lists, and every one of them used to snap back to the top.
static func keep_scroll(rows_box: Control) -> Callable:
	var sc := rows_box.get_parent() as ScrollContainer
	if sc == null:
		return func() -> void: pass
	var v := sc.scroll_vertical
	return func() -> void: sc.set_deferred("scroll_vertical", v)


## Small pill/chip tinted by `color` (mode chips, data-source chips, badges).
static func chip_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color, 0.16)
	sb.border_color = Color(color, 0.65)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(CORNER_RADIUS + 4)
	sb.set_content_margin_all(SPACE_XS)
	sb.content_margin_left = SPACE_SM
	sb.content_margin_right = SPACE_SM
	return sb
