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
# Typography scale (matches the sizes already in use: 10/12/14/16/20).
# ---------------------------------------------------------------------------
const FONT_XS := 10
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


## Raised card inside a panel (lighter bg, tighter margins).
static func card_style() -> StyleBoxFlat:
	var sb := panel_style(1.0, C_PANEL_RAISED)
	sb.set_content_margin_all(SPACE_SM)
	return sb


## Button stylebox. `state` is "normal", "hover", or "pressed".
static func button_style(state: String = "normal") -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	match state:
		"hover":
			sb.bg_color = C_PANEL_RAISED
			sb.border_color = C_PRIMARY
		"pressed":
			sb.bg_color = Color(C_PRIMARY, 0.25)
			sb.border_color = C_PRIMARY
		_:
			sb.bg_color = C_PANEL
			sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(CORNER_RADIUS)
	sb.set_content_margin_all(SPACE_SM)
	sb.content_margin_left = SPACE_MD
	sb.content_margin_right = SPACE_MD
	return sb


## Apply normal/hover/pressed styleboxes to a Button in one call.
static func style_button(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", button_style("normal"))
	btn.add_theme_stylebox_override("hover", button_style("hover"))
	btn.add_theme_stylebox_override("pressed", button_style("pressed"))


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
